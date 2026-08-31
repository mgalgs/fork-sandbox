#!/usr/bin/env bash
# fork-sandbox-k8s.sh -- run a sandboxed agent as a Kubernetes Job
#
# Usage: fork-sandbox-k8s.sh install [--dry-run]
#        fork-sandbox-k8s.sh submit [--dry-run] --branch NAME --model MODEL
#                            [--harness pi|claude]
#                            [--review-loop N] [--review-model MODEL]
#                            [--outbox-max SIZE]
#                            [--context-ro DIR]
#                            <project-path> <handoff-file>
#        fork-sandbox-k8s.sh run [--dry-run] [--timeout SECONDS] [--keep]
#                            --branch NAME --model MODEL [--harness pi|claude]
#                            [--review-loop N] [--review-model MODEL]
#                            [--outbox-dir DIR] [--outbox-max SIZE]
#                            [--context-ro DIR]
#                            <project-path> <handoff-file>
#        fork-sandbox-k8s.sh fetch --branch NAME <project-path>
#        fork-sandbox-k8s.sh say --branch NAME <text>
#        fork-sandbox-k8s.sh say --branch NAME -        # text from stdin
#        fork-sandbox-k8s.sh rm --branch NAME
#
# The Kubernetes analogue of fork-sandbox.sh: submit a task from anywhere
# with cluster access, and a few minutes later fetch a branch. See
# docs/kubernetes-runs.md for the design and docs/k8s-platform.md for the
# pluggable layer this script talks to. fork-sandbox.sh --k8s is a thin
# dispatcher onto the `run` verb below, for a caller already using
# fork-sandbox.sh; this script remains the direct entry point, and every
# verb below is unchanged by that dispatcher's existence.
#
# install renders manifests/k8s/ and this cluster's egress policy (from the
# platform plugin), applies both, and creates the Secret the model proxy
# reads its provider key from. Idempotent -- safe to run again after
# changing config.
#
# submit renders a Job for one run, applies it, pushes the project's repo
# into the pod over the same `kubectl exec` channel the work later returns
# on, and writes the sentinel that lets the pod's entrypoint proceed. The
# pod holds no git credential and never pushes anywhere; it only receives.
#
# run is submit, then wait, then fetch, then rm: the one-shot equivalent of
# a local fork-sandbox.sh launch, for anywhere with cluster access. submit
# and fetch remain available on their own for when you want to start a run
# from one place and collect it later from somewhere else, rather than
# block on it. The wait polls for a sentinel the pod's entrypoint writes
# after the agent exits (/work/.run-complete, holding the agent's own exit
# code) -- never pod phase, which stays Running while the pod idles for a
# later fetch even after the agent itself has finished. A run still going
# at --timeout is left in place, never fetched and never removed, and the
# error names the fetch command to run by hand once it completes.
#
# fetch runs `git fetch` against the pod's clone, the same channel in
# reverse, landing the branch in your real repo. It also signals the pod
# that the run has been collected, so it does not idle out its full TTL.
#
# say sends an operator addendum to a run that is already going -- the
# Kubernetes analogue of fork-sandbox-say.sh, over the same kubectl exec
# channel submit and fetch already use. It resolves the pod from --branch
# exactly as fetch does, then writes one generated filename
# (<epoch>-<nn>.md, never taken from an argument) into /work/inbox inside
# the pod. The pod runs pi, which has no hook system, so delivery is the
# same hookless contract every non-claude harness gets: the agent reads the
# inbox itself, on a tool-call floor and around long commands, commits and
# its final report -- see fs_emit_prompt_preamble in fork-sandbox-lib.sh.
# fork-sandbox-say.sh itself is not taught to reach into a pod: it is
# blanket-approved specifically because its write is bounded to one
# structurally constrained host directory, and kubectl exec would replace
# that argument with a far larger one. This is a separate command instead.
#
# rm deletes the run's Job, its pod, and its ConfigMap.
#
# --dry-run (install, submit, run): print the rendered YAML and exit 0.
# Contacts nothing -- no kubectl, no git push, no cluster reachability
# check. This is how the rendering logic is tested without a cluster.
#
# --timeout SECONDS (run): how long to wait for the agent before giving up.
# Defaults to 3600, matching the entrypoint's own RUN_TTL default --
# waiting longer than the pod itself will idle is pointless.
#
# --keep (run): skip the final rm, leaving the Job and pod in place after a
# successful fetch.
#
# --outbox-dir DIR (run): where to land the pod's /work/outbox after the
# agent finishes. Defaults to
# /var/tmp/claude-scratch/forks/k8s-<safe-branch>/outbox. Pulled back over
# the same kubectl exec channel fetch uses, through
# fork-sandbox-k8s-outbox-extract.sh, which refuses the whole archive if it
# is oversized or contains anything unsafe (absolute paths, `..` components,
# symlinks) -- see that script's own header. Best-effort: a failure here
# warns and falls through rather than failing the run, since retrieving
# artifacts must never cost the branch itself.
#
# --outbox-max SIZE (submit, run): raise the outbox size cap above the
# default 64 MiB (FS_OUTBOX_MAX_BYTES). Takes a plain byte count or a size
# with a K/M/G suffix (512K, 256M, 2G); no upper ceiling -- the operator
# raising it is the one accepting the extra disk cost. The effective value
# is threaded everywhere the cap matters: the rendered Job's
# OUTBOX_MAX_BYTES env var, the pod-side entrypoint check, the
# preamble text the agent reads, run's own pull-back head -c/stat guard,
# and the extractor's third argument -- so the pod, the client and the
# extractor can never disagree about the number.
#
# --review-loop N (submit, run): after the coding leg, run a fresh review
# session against the branch and, on findings, a fresh fix session, up to N
# times -- the cluster analogue of fork-sandbox.sh's own --review-loop. The
# loop runs POD-SIDE, in fork-sandbox-k8s-review-loop.sh, shipped in the
# same per-run ConfigMap as the entrypoint; the review and fix prompts
# themselves are rendered HOST-SIDE, by fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body in fork-sandbox-lib.sh -- the same functions the
# local loop uses -- and shipped in alongside handoff.md, never composed a
# second time inside the pod. The outcome lands in the pod at
# /work/review-loop.json; `run` reads it back and prints a summary before
# fetching (see cmd_run below), because the container's own exit code stays
# the CODING leg's regardless of how the loop ended -- see
# fork-sandbox-k8s-entrypoint.sh's comment on .run-complete for why. See
# docs/kubernetes-runs.md for the full design.
#
# --context-ro DIR (submit, run): push DIR into the pod at /work/context,
# read-only by convention, over the same gated kubectl-exec channel the
# repository push uses -- after the repository, before the
# .inputs-complete sentinel, so a failure here fails the run closed rather
# than leaving a half-received context directory for the agent to find.
# DIR must be a real directory under /var/tmp/claude-scratch/forks/, the
# same rule fork-sandbox.sh's own local --context-ro applies to its
# --bind-ro -- a blanket-approved script must not be pointable at an
# arbitrary host directory. DIR must not contain a symlink, refused on the
# host before anything is created or pushed -- tar cf's ordinary walk turns one into
# a link entry, which the pod-side extractor also refuses, but only after
# the Job exists, the pod is Ready and the repository has already been
# pushed. Capped at a fixed 256 MiB, checked twice,
# independently: spooled and checked on the host before anything is created
# or pushed
# (fork-sandbox-k8s.sh itself), and again pod-side by
# fork-sandbox-k8s-context-extract.sh before it extracts anything -- no
# --context-max flag, since a context directory is gathered notes and
# small caches, not a size nobody has needed to raise yet. Unlike the local
# flag's real --bind-ro, an emptyDir cannot be bound read-only per
# subdirectory, so read-only here is enforced by the prompt text the agent
# reads (a `## Gathered context` section appended to handoff.md), not by
# the filesystem.
#
# --harness pi|claude (submit): which coding harness the pod runs. Defaults
# to pi, which talks to the shared fork-sandbox-proxy over PROXY_BASE_URL,
# exactly as before this flag existed. claude runs Claude Code instead,
# against a PER-RUN proxy Pod (manifests/k8s/31-claude-proxy.yaml, rendered
# and applied alongside this run's Job) that carries the operator's own
# access token in a per-run Secret -- the pod itself still holds no
# credential. See docs/kubernetes-runs.md's "Model access" section for the
# full design.
#
# Cluster-specific settings are never taken from this repo -- a public repo
# must not carry a private hostname, a real cluster name or a registry
# address, and none of those belong hardcoded regardless. They are read at
# runtime from ~/.config/fork-sandbox/k8s.env, one NAME=VALUE per line,
# following the pattern fork-sandbox.sh already uses for pi.env and
# model.env:
#
#   K8S_CONTEXT=          kubectl --context value. REQUIRED, never
#                         defaulted -- a wrong-cluster write is the failure
#                         mode worth an error message.
#   K8S_NAMESPACE=        defaults to fork-sandbox.
#   K8S_IMAGE=            a fully qualified image ref. REQUIRED for submit,
#                         never defaulted -- this project ships a Dockerfile
#                         and a build script, and NEVER ships an image or a
#                         registry. A pod cannot use a local docker image,
#                         so a silent default would only produce a
#                         confusing ImagePullBackOff. Build with
#                         scripts/build-sandbox-image.sh and push it to a
#                         registry you control; see docs/kubernetes-runs.md
#                         for concrete options.
#   K8S_PROXY_UPSTREAM=   https://<provider host>, e.g. https://openrouter.ai.
#                         The legacy single, API-keyed upstream. install
#                         requires this or K8S_PROXY_ENDPOINTS, never both.
#   K8S_PROXY_ENDPOINTS=  <name>=<base-url>[,<name>=<base-url>...] -- one or
#                         more named, keyless, OpenAI-compatible endpoints
#                         (vLLM, Ollama, TGI), e.g.
#                         primary=http://10.0.0.5:8001/v1. Mutually
#                         exclusive with K8S_PROXY_UPSTREAM.
#   K8S_PROXY_ALLOW=      <cidr>:<port>[,<cidr>:<port>...] egress allowlist
#                         for K8S_PROXY_ENDPOINTS hosts. Unset keeps the
#                         default policy (any host except RFC1918, on 443).
#   K8S_DENIED_PROBE=     host:port the egress gate must NOT reach.
#                         Required for submit.
#   K8S_RUN_TTL=          seconds the pod idles after the agent exits.
#                         Defaults to 3600.
#   GIT_USER_NAME=, GIT_USER_EMAIL=
#                         identity the pod's commits land under. Optional;
#                         default to a fixed fork-sandbox identity.
#
# The provider key is NOT in this file. install reads it from
# ~/.config/fork-sandbox/pi.env (OPENROUTER_API_KEY=...), the same file a
# local --harness pi run reads, so there is one credential source shared
# between local and cluster runs. It never enters the agent pod: only the
# model proxy holds it, mounted from the Secret this creates.
#
# FORK_SANDBOX_K8S_PLATFORM names the platform plugin; default generic. See
# docs/k8s-platform.md.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

if [[ "${1-}" == -h || "${1-}" == --help ]]; then
    usage
    exit 0
fi

fs_require_gnu_tools || exit 1

config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
k8s_env="$config_dir/k8s.env"
pi_env="$config_dir/pi.env"

# Reads one NAME=VALUE line from an env file, first match wins. Never
# `source`d: these files are read by a script that goes on to build
# commands from other things too, and a config file is not the place to
# accept arbitrary shell.
read_env_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

if [[ ! -f "$k8s_env" ]]; then
    echo "Error: $k8s_env not found. A Kubernetes run reads cluster-specific" >&2
    echo "settings from that file, one NAME=VALUE per line:" >&2
    echo "  mkdir -p $config_dir" >&2
    echo "  cat > $k8s_env <<'CONF'" >&2
    echo "K8S_CONTEXT=your-cluster-context" >&2
    echo "K8S_NAMESPACE=fork-sandbox" >&2
    echo "K8S_IMAGE=registry.example/you/fork-sandbox:latest" >&2
    echo "K8S_PROXY_UPSTREAM=https://openrouter.ai" >&2
    echo "K8S_DENIED_PROBE=10.0.0.1:443" >&2
    echo "K8S_RUN_TTL=3600" >&2
    echo "CONF" >&2
    echo "See docs/kubernetes-runs.md for what each key means." >&2
    exit 1
fi

K8S_CONTEXT="$(read_env_value "$k8s_env" K8S_CONTEXT || true)"
if [[ -z "$K8S_CONTEXT" ]]; then
    echo "Error: K8S_CONTEXT is not set in $k8s_env. This is never defaulted:" >&2
    echo "a wrong-cluster write is the failure mode worth an error message." >&2
    echo "Add a line: K8S_CONTEXT=your-cluster-context" >&2
    exit 1
fi
K8S_NAMESPACE="$(read_env_value "$k8s_env" K8S_NAMESPACE || true)"
K8S_NAMESPACE="${K8S_NAMESPACE:-fork-sandbox}"
K8S_IMAGE="$(read_env_value "$k8s_env" K8S_IMAGE || true)"
K8S_PROXY_UPSTREAM="$(read_env_value "$k8s_env" K8S_PROXY_UPSTREAM || true)"
K8S_PROXY_ENDPOINTS="$(read_env_value "$k8s_env" K8S_PROXY_ENDPOINTS || true)"
K8S_PROXY_ALLOW="$(read_env_value "$k8s_env" K8S_PROXY_ALLOW || true)"
K8S_DENIED_PROBE="$(read_env_value "$k8s_env" K8S_DENIED_PROBE || true)"
K8S_RUN_TTL="$(read_env_value "$k8s_env" K8S_RUN_TTL || true)"
K8S_RUN_TTL="${K8S_RUN_TTL:-3600}"
GIT_USER_NAME="$(read_env_value "$k8s_env" GIT_USER_NAME || true)"
GIT_USER_NAME="${GIT_USER_NAME:-fork-sandbox agent}"
GIT_USER_EMAIL="$(read_env_value "$k8s_env" GIT_USER_EMAIL || true)"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@fork-sandbox.invalid}"

if [[ ! "$K8S_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: K8S_NAMESPACE='$K8S_NAMESPACE' is not a valid namespace name." >&2
    exit 1
fi
if [[ -n "$K8S_RUN_TTL" && ! "$K8S_RUN_TTL" =~ ^[0-9]+$ ]]; then
    echo "Error: K8S_RUN_TTL must be a number of seconds, got '$K8S_RUN_TTL'." >&2
    exit 1
fi

fs_reject_unsafe_chars "$K8S_CONTEXT" "$K8S_NAMESPACE" "$K8S_IMAGE" \
    "$K8S_PROXY_UPSTREAM" "$K8S_PROXY_ENDPOINTS" "$K8S_PROXY_ALLOW" \
    "$K8S_DENIED_PROBE" "$GIT_USER_NAME" "$GIT_USER_EMAIL" \
    || exit 1

kubectl() {
    command kubectl --context="$K8S_CONTEXT" -n "$K8S_NAMESPACE" "$@"
}

# The pod's operator inbox. Must track fork-sandbox-k8s-entrypoint.sh's own
# work_dir/inbox_dir, for the same reason cmd_submit's pod_clone_dir must
# track its work_dir/clone_dir: this script renders and writes before the
# pod's own shell ever runs, so there is nowhere to read the path back from.
# A sibling of /work/clone, never a descendant -- the entrypoint's
# `git add -A` at run end is scoped to the clone it runs in, so a path
# outside it can never be swept into a commit. Read by cmd_submit (to tell
# the preamble where to point the agent) and cmd_say (to know where to
# write).
POD_INBOX_DIR=/work/inbox

# The pod's artifact outbox. Same tracking requirement and sibling-of-clone
# reasoning as POD_INBOX_DIR above, mirrored on fork-sandbox-k8s-entrypoint.sh's
# own outbox_dir. Read by cmd_submit (to tell the preamble where to point the
# agent) and cmd_run (to know where to pull artifacts back from).
POD_OUTBOX_DIR=/work/outbox

# The pod's gathered-context directory, populated from a --context-ro
# push. Same sibling-of-clone reasoning as POD_INBOX_DIR and POD_OUTBOX_DIR
# above -- it lives in the `work` emptyDir but must stay outside the clone
# so the entrypoint's `git add -A` never sweeps it into a commit. Unlike
# those two, read only by cmd_submit -- to tell the preamble where to point
# the agent, and to push into -- since nothing else (cmd_say, cmd_run) ever
# touches it.
POD_CONTEXT_DIR=/work/context

# The pod-side context-extract.sh cap: 256 MiB, fixed. A context directory
# is gathered notes and small caches, not build artifacts or datasets, so
# this has no --context-max flag -- see docs/kubernetes-runs.md. A second,
# independent literal lives in fork-sandbox-k8s-context-extract.sh's own
# body, the same way FS_OUTBOX_MAX_BYTES and outbox-extract.sh's default
# are two literals rather than one threaded value: this script and the pod
# script never share a sourced constant.
CONTEXT_MAX_BYTES=$((256 * 1024 * 1024))

# The identical resolution rule fs_resolve_backend uses for
# sandbox-backend-<name>, applied to the platform plugin: PATH first, then
# beside this script, so a checkout works before install.sh has run.
resolve_platform() {
    local name bin
    name="${FORK_SANDBOX_K8S_PLATFORM:-generic}"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: FORK_SANDBOX_K8S_PLATFORM='$name' is not a platform name." >&2
        echo "It becomes 'fork-sandbox-k8s-platform-$name', so it must be" >&2
        echo "lowercase alphanumerics, hyphens and underscores." >&2
        return 1
    fi
    bin="$(command -v "fork-sandbox-k8s-platform-$name" 2>/dev/null || true)"
    if [[ -z "$bin" && -x "$script_dir/fork-sandbox-k8s-platform-$name" ]]; then
        bin="$script_dir/fork-sandbox-k8s-platform-$name"
    fi
    if [[ -z "$bin" ]]; then
        echo "Error: cannot find fork-sandbox-k8s-platform-$name, which renders" >&2
        echo "this cluster's egress policy. It is named by" >&2
        echo "FORK_SANDBOX_K8S_PLATFORM (default generic) and looked up on PATH" >&2
        echo "and beside this script. Run install.sh in the fork-sandbox repo," >&2
        echo "or set FORK_SANDBOX_K8S_PLATFORM to a platform that is installed." >&2
        return 1
    fi
    K8S_PLATFORM_BIN="$bin"
    return 0
}

# Prints one capability value, or the conservative default when the
# platform's --capabilities did not declare it -- the same forward-
# compatibility rule docs/k8s-platform.md defines.
platform_capability() {
    local key="$1" default="$2" out
    out="$("$K8S_PLATFORM_BIN" --capabilities 2>/dev/null | awk -F= -v k="$key" '$1 == k { print $2; exit }')"
    printf '%s' "${out:-$default}"
}

# Reads a file that holds a secret: not a symlink, owned by the invoking
# user, mode 0600 or stricter. The same check claude-sandboxed applies to
# --env-file, applied here to pi.env before its key is read.
require_secret_file() {
    local file="$1" stat_out owner perms
    if [[ -L "$file" ]]; then
        echo "Error: '$file' is a symlink. Name the file itself." >&2
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "Error: '$file' not found." >&2
        return 1
    fi
    stat_out="$("$FS_STAT" -c '%u %a' -- "$file")"
    owner="${stat_out%% *}"
    perms="${stat_out##* }"
    if [[ "$owner" != "$UID" ]]; then
        echo "Error: '$file' is owned by uid $owner, not by you." >&2
        return 1
    fi
    if (( 8#$perms & 0077 )); then
        echo "Error: '$file' is mode $perms. It holds a secret, so it must" >&2
        echo "be 0600 or stricter. Run: chmod 600 '$file'" >&2
        return 1
    fi
    return 0
}

# Indents a file's content for embedding under a YAML block scalar (`key:
# |`), 4 spaces to match this script's ConfigMap templates. Blank lines are
# left empty rather than padded, so a generated ConfigMap has no trailing
# whitespace for yamllint to flag.
indent_block() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            printf '\n'
        else
            printf '    %s\n' "$line"
        fi
    done
}

# Extracts the `nginx.conf` key from a rendered proxy ConfigMap's block
# scalar (`nginx.conf: |`), reversing indent_block's 4-space indent. A blank
# line in the block carries no indent of its own, so it is matched too.
k8s_extract_nginx_conf() {
    awk '
        /^  nginx\.conf: \|$/ { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    '
}

# A hex sha256 of stdin, for the proxy config-change annotation below.
# sha256sum and openssl are not both guaranteed on every machine this might
# run on (sha256sum is missing without GNU coreutils, openssl is missing on
# a minimal install) -- try the GNU tool, then two portable fallbacks,
# before giving up.
k8s_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | sed 's/^.* //'
    else
        echo "Error: none of sha256sum, shasum or openssl found. One is" >&2
        echo "needed to hash the proxy ConfigMap's content, so a config" >&2
        echo "change can roll the proxy Deployment -- see" >&2
        echo "docs/kubernetes-runs.md." >&2
        return 1
    fi
}

# The sanitising half of k8s_safe_name below, factored out so a filesystem
# path (which has no 63-char Kubernetes object-name limit) can reuse it
# without the truncation that would otherwise chop it.
k8s_safe_name_component() {
    local branch="$1" safe
    safe="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    safe="${safe##-}"
    safe="${safe%%-}"
    printf '%s' "$safe"
}

# A Kubernetes object name: lowercase RFC 1123, <=63 chars. Branch names are
# freeform, so this derives a safe name rather than requiring the caller to
# pick one that already qualifies. Capped at 50, not 63: this name is also
# used as the base of the per-run claude-proxy Service, with a
# "-claude-proxy" suffix appended (13 chars), and a Service name is itself
# capped at 63 -- so the base must leave room for that suffix or a long
# branch renders a Service name the API server rejects, aborting submit
# after the Secret, ConfigMap and Pod for that run already exist.
# A normalized branch gets a digest too, even when it fits: otherwise refs
# such as feature/foo and feature-foo (or Feature/foo and feature-foo) share
# one set of Kubernetes objects.
k8s_safe_name() {
    local prefix="$1" branch="$2" component candidate digest base
    component="$(k8s_safe_name_component "$branch")"
    candidate="$prefix-$component"
    if [[ "$component" == "$branch" ]] && (( ${#candidate} <= 50 )); then
        printf '%s' "$candidate"
        return
    fi
    digest="$(printf '%s' "$branch" | k8s_sha256_stdin | cut -c1-8)"
    base="${candidate:0:41}"
    base="${base%-}"
    printf '%s-%s' "$base" "$digest"
}

# The object-name derivation used before k8s_safe_name added digests. Keep it
# for management commands so runs submitted by that version remain fetchable,
# sayable, and removable after this script is updated. Submit must continue to
# use k8s_safe_name: unlike this legacy form, it distinguishes names that
# sanitize to the same component.
k8s_legacy_safe_name() {
    local prefix="$1" branch="$2"
    printf '%s-%s' "$prefix" "$(k8s_safe_name_component "$branch")" \
        | cut -c1-50 | sed 's/-$//'
}

# Prefer the current name, then look for an object created with the legacy
# name. The fallback is intentionally limited to management commands; a
# submit never reuses a possibly colliding legacy name.
k8s_find_pod() {
    local safe_name="$1" legacy_name="$2" pod_name
    pod_name="$(kubectl get pod -l "job-name=$safe_name" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$pod_name" && "$legacy_name" != "$safe_name" ]]; then
        pod_name="$(kubectl get pod -l "job-name=$legacy_name" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    printf '%s' "$pod_name"
}

# Renders the four --review-loop-only ConfigMap keys: the review and fix
# prompts, the flattened review skill, and the loop script itself. The
# prompts are composed the same way handoff.md itself is -- preamble, then
# body -- except with NO overlay in between: --prompts-dir is refused on
# this path (see fork-sandbox.sh's --k8s flag refusals), so there is no
# overlay to layer on. The body text comes from fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body in fork-sandbox-lib.sh, the exact functions
# fork-sandbox.sh's own local --review-loop uses -- this function renders
# no prompt prose of its own, only concatenates what those functions emit.
# Indented 2 spaces to sit beside handoff.md as ConfigMap data keys.
render_review_loop_configmap_keys() {
    local pod_clone_dir="$1" pod_inbox_dir="$2" pod_skill_dir="$3" pod_verdict_file="$4"
    local branch="$5" base_sha="$6" review_skill_src="$7" review_loop_sh="$8"
    local pod_outbox_dir="$9" outbox_max_bytes="${10}"
    cat <<KEYS
  review-prompt.md: |
$({ fs_emit_prompt_preamble "$pod_clone_dir" "$pod_inbox_dir" pi gated "$pod_outbox_dir" pod \
       "$outbox_max_bytes"
   fs_emit_review_prompt_body "$branch" "$base_sha" "$pod_skill_dir" \
       "$pod_verdict_file" "$pod_inbox_dir"; } | indent_block)
  fix-prompt-header.md: |
$({ fs_emit_prompt_preamble "$pod_clone_dir" "$pod_inbox_dir" pi gated "$pod_outbox_dir" pod \
       "$outbox_max_bytes"
   fs_emit_fix_prompt_body "$branch" "$base_sha"; } | indent_block)
  code-review-portable-skill.md: |
$(indent_block < "$review_skill_src")
  review-loop.sh: |
$(indent_block < "$review_loop_sh")
KEYS
}

# The two --review-loop-only env vars the agent container needs --
# REVIEW_LOOP_CAP (so the entrypoint knows to run the loop) and BASE_SHA
# (the commit review-loop.sh measures the branch against). Indented to
# match the other env entries in the rendered Job spec.
render_review_loop_env() {
    local cap="$1" base_sha="$2"
    cat <<ENV
            - name: REVIEW_LOOP_CAP
              value: "$cap"
            - name: BASE_SHA
              value: "$base_sha"
ENV
}

# The two --harness claude-only ConfigMap keys: the placeholder credential
# (already sanitized by the caller -- see cmd_submit's credential preflight)
# and the operator-inbox hook, shipped in so the entrypoint can copy it to
# /work/inbox/.inbox-hook.sh and register it exactly like a local claude
# run's --settings does (fork-sandbox.sh's own inbox-hook install, around
# its own harness == claude guard). Indented 2 spaces to sit beside the
# other ConfigMap data keys.
render_claude_configmap_keys() {
    local configmap_cred="$1" inbox_hook_src="$2"
    cat <<KEYS
  claude-credentials.json: |
$(printf '%s\n' "$configmap_cred" | indent_block)
  inbox-hook.sh: |
$(indent_block < "$inbox_hook_src")
KEYS
}

# The --context-ro-only handoff.md section, appended after the shared
# preamble and before the operator's own handoff text -- see cmd_submit's
# handoff.md rendering below. Not folded into fs_emit_prompt_preamble
# itself: that function is shared with the local --context-ro flag, which
# binds the directory at its own host path and needs no section like this
# one, since the handoff author already knows that path. A pod's path
# differs from the host path the caller named, so this names it instead.
render_context_section() {
    local pod_context_dir="$1"
    cat <<EOF

## Gathered context

The directory named with \`--context-ro\` on the host is at:

    $pod_context_dir

here, read-only by convention. Do not write to it and do not copy it into
the clone.
EOF
}

# Validates an upstream base URL -- K8S_PROXY_UPSTREAM, or one
# K8S_PROXY_ENDPOINTS entry's URL. https:// is accepted for any host,
# unchanged from before this function existed. http:// is accepted ONLY
# when its host is a private address (RFC1918, loopback, or link-local) --
# plain http:// to a public host would put a request on the open internet
# in cleartext, which stays refused. TLS and authentication are
# independent properties: whether an upstream needs a key is never
# inferred from its scheme, so this checks the URL alone and nothing about
# K8S_PROXY_UPSTREAM vs K8S_PROXY_ENDPOINTS. A hostname (anything that
# doesn't parse as a literal IPv4 address) on http:// is refused too --
# this script has no network access to resolve one, so its privateness
# can never be verified.
#
# On success, prints the bare host (scheme stripped, path cut at the first
# /, port kept) on stdout -- the same value proxy_ssl_name/Host has always
# used -- and returns 0. On failure, prints nothing to stdout, an
# explanatory message to stderr, and returns non-zero. $2, when given,
# names the setting in error messages (defaults to "URL").
validate_upstream_url() {
    local url="$1" label="${2:-URL}" scheme host host_only octet o1 o2

    case "$url" in
        https://*) scheme=https ;;
        http://*) scheme=http ;;
        *)
            echo "Error: $label must start with https:// or http://, got" >&2
            echo "'$url'." >&2
            return 1
            ;;
    esac

    host="${url#*://}"
    host="${host%%/*}"
    if [[ "$scheme" == https ]]; then
        printf '%s' "$host"
        return 0
    fi

    # ${host%:*} is a no-op when there is no ':' to split on, which is
    # exactly right for a bare IPv4 host with no port.
    host_only="${host%:*}"
    if [[ ! "$host_only" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        echo "Error: $label uses http://, which this repo only accepts to a" >&2
        echo "private address (RFC1918, loopback, or link-local) --" >&2
        echo "'$host_only' is not a literal IPv4 address, so it cannot be" >&2
        echo "verified as private without DNS. Use https://, or a literal" >&2
        echo "private IP." >&2
        return 1
    fi
    for octet in "${BASH_REMATCH[@]:1}"; do
        if (( octet > 255 )); then
            echo "Error: $label's host '$host_only' is not a valid IPv4" >&2
            echo "address." >&2
            return 1
        fi
    done
    o1="${BASH_REMATCH[1]}"
    o2="${BASH_REMATCH[2]}"
    if ! { (( o1 == 10 )) \
        || (( o1 == 172 && o2 >= 16 && o2 <= 31 )) \
        || (( o1 == 192 && o2 == 168 )) \
        || (( o1 == 127 )) \
        || (( o1 == 169 && o2 == 254 )); }; then
        echo "Error: $label uses http:// to '$host_only', which is not a" >&2
        echo "private address (RFC1918 10.0.0.0/8, 172.16.0.0/12," >&2
        echo "192.168.0.0/16, loopback 127.0.0.0/8, or link-local" >&2
        echo "169.254.0.0/16). Plain http:// to a public address would put" >&2
        echo "a request on the open internet in cleartext -- use https://" >&2
        echo "instead." >&2
        return 1
    fi

    printf '%s' "$host"
    return 0
}

# Parses K8S_PROXY_ENDPOINTS ("name=url,name=url,...") into the
# PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS arrays (module-global, not
# local -- callers read them back after this returns). An empty spec is not
# an error here; cmd_install is what decides whether an empty registry is
# acceptable, since that depends on K8S_PROXY_UPSTREAM too. Each name
# becomes a path segment (/e/<name>/v1/...) on the rendered proxy, so it is
# validated against the same RFC1123-label shape K8S_NAMESPACE already
# uses above -- one registry entry, one deliberate config roll; the model
# behind it is free to change without touching this.
parse_proxy_endpoints() {
    local spec="$1" entry name url seen=","
    PROXY_ENDPOINT_NAMES=()
    PROXY_ENDPOINT_URLS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *=* ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$entry' is not" >&2
            echo "<logical-name>=<base-url>." >&2
            return 1
        fi
        name="${entry%%=*}"
        url="${entry#*=}"
        if [[ -z "$name" ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$entry' has an empty" >&2
            echo "name." >&2
            return 1
        fi
        if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS name '$name' is not valid -- it" >&2
            echo "becomes a path segment (/e/$name/v1/...) and must match" >&2
            echo '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$.' >&2
            return 1
        fi
        if [[ -z "$url" ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$name' has an empty" >&2
            echo "base URL." >&2
            return 1
        fi
        validate_upstream_url "$url" "K8S_PROXY_ENDPOINTS entry '$name'" >/dev/null || return 1
        if [[ "$seen" == *",$name,"* ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS name '$name' is registered more" >&2
            echo "than once. Each logical name must be unique." >&2
            return 1
        fi
        seen+="$name,"
        PROXY_ENDPOINT_NAMES+=("$name")
        PROXY_ENDPOINT_URLS+=("$url")
    done
    return 0
}

# Parses K8S_PROXY_ALLOW ("<cidr>:<port>,<cidr>:<port>,...") into the
# PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS arrays (module-global). An empty spec
# is not an error -- cmd_install renders today's default RFC1918-except
# egress block when it's unset, unchanged. NetworkPolicy has no hostname
# field, so a name here (anything that doesn't parse as an IPv4 CIDR) is
# refused outright rather than silently accepted and never matching
# anything -- see the ipBlock section of the NetworkPolicy API: it takes a
# CIDR, never a DNS name.
parse_proxy_allow() {
    local spec="$1" entry cidr port
    PROXY_ALLOW_CIDRS=()
    PROXY_ALLOW_PORTS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *:* ]]; then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' is not <cidr>:<port>." >&2
            return 1
        fi
        cidr="${entry%:*}"
        port="${entry##*:}"
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' does not name a valid" >&2
            echo "IPv4 CIDR ('$cidr'). NetworkPolicy has no hostname field --" >&2
            echo "an egress rule can only ever match an ipBlock, never a DNS" >&2
            echo "name, so a hostname cannot be accepted here." >&2
            return 1
        fi
        if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' has an invalid port" >&2
            echo "'$port' -- must be 1-65535." >&2
            return 1
        fi
        PROXY_ALLOW_CIDRS+=("$cidr")
        PROXY_ALLOW_PORTS+=("$port")
    done
    return 0
}

# The NetworkPolicy egress rule(s) allowing whichever hosts model access
# needs -- replaces the whole `- to: []  # __PROXY_EGRESS_RULES__` /
# `ports: []` placeholder stanza in manifests/k8s/30-proxy.yaml (see
# render_proxy_egress_rules_sub below for why a whole-stanza replacement,
# rather than a bare token, is what keeps the raw template parseable YAML).
# Unset K8S_PROXY_ALLOW renders exactly what this repo has always rendered
# here (byte-for-byte): any host except RFC1918/loopback/link-local/CGNAT, on
# 443. A set K8S_PROXY_ALLOW replaces that block with exactly the given
# <cidr>:<port> entries (from the PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS
# arrays parse_proxy_allow filled in) and nothing else -- explicit egress,
# for whatever private (or public) addresses K8S_PROXY_ENDPOINTS names.
render_proxy_egress_rules() {
    if [[ ${#PROXY_ALLOW_CIDRS[@]} -eq 0 ]]; then
        cat <<'EOF'
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
              - 100.64.0.0/10
      ports:
        - protocol: TCP
          port: 443
EOF
        return 0
    fi

    local i cidr port
    for (( i = 0; i < ${#PROXY_ALLOW_CIDRS[@]}; i++ )); do
        cidr="${PROXY_ALLOW_CIDRS[$i]}"
        port="${PROXY_ALLOW_PORTS[$i]}"
        cat <<EOF
    - to:
        - ipBlock:
            cidr: $cidr
      ports:
        - protocol: TCP
          port: $port
EOF
    done
}

# manifests/k8s/30-proxy.yaml's own __PROXY_EGRESS_RULES__ marker sits on a
# placeholder stanza that is, by itself, valid YAML (`- to: []` / `ports:
# []`) -- unlike __PROXY_LOCATIONS__, this one lives in a real parsed
# NetworkPolicy list, not inside an nginx.conf block scalar, so a bare
# dedented token here is a syntax error rather than harmless block-scalar
# text. This substitutes the WHOLE two-line stanza (matched literally, not
# as a token) for render_proxy_egress_rules's output, which supplies its own
# 4-space list-item indent on every line since nothing in the template
# indents it for us this time. No trailing newline on either side of this
# substitution: $1 already had its own trailing newline stripped by the
# $(sed ...) capture that produced it (this stanza is the file's last
# line), the same convention the untouched original template's last line
# always rendered under -- see cmd_install's own `rendered+="$file_rendered"$'\n'`
# for where that newline comes back.
render_proxy_egress_rules_sub() {
    local text="$1" stanza stripped
    stanza=$'    - to: []  # __PROXY_EGRESS_RULES__\n      ports: []'
    stripped="${text/"$stanza"/$(render_proxy_egress_rules)}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the __PROXY_EGRESS_RULES__ placeholder" >&2
        echo "stanza in the rendered proxy NetworkPolicy --" >&2
        echo "manifests/k8s/30-proxy.yaml and render_proxy_egress_rules_sub" >&2
        echo "in this script have drifted apart." >&2
        return 1
    fi
    printf '%s' "$stripped"
}

# The nginx location block(s) inside the proxy's server {} -- fills
# __PROXY_LOCATIONS__ in manifests/k8s/30-proxy.yaml. Built fully-resolved in
# bash, rather than left as sed tokens for the per-file substitution pass in
# cmd_install to fill in later, because a K8S_PROXY_ENDPOINTS registry can
# name the same base URL more than once under different logical names, and a
# global sed token has only one value per render.
#
# Legacy K8S_PROXY_UPSTREAM (upstream_host given as $1) renders exactly what
# this repo has always rendered here -- byte-for-byte, Authorization header
# included -- to hold the backward-compatibility guarantee: an existing
# install using K8S_PROXY_UPSTREAM must render identically after this
# function existed as after it didn't.
#
# K8S_PROXY_ENDPOINTS (read from the PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS
# arrays parse_proxy_endpoints filled in) renders two EXACT-match locations
# per registered name -- /e/<name>/v1/chat/completions and
# /e/<name>/v1/models -- never a regex or prefix match: N endpoints must
# widen the surface by exactly 2N known paths and nothing else. Neither
# carries an Authorization header -- a registered endpoint is keyless by
# construction in this round; see cmd_install's Secret/include handling for
# the other half of that. Preserves the same $upstream variable-in-proxy_pass
# trick and resolver the legacy block uses (see manifests/k8s/30-proxy.yaml's
# own comment on it) so nginx resolves each endpoint's host at request time
# rather than pinning a DNS answer at startup.
#
# manifests/k8s/30-proxy.yaml's own __PROXY_LOCATIONS__ placeholder line
# carries the block's 12-space indent already, so the raw template stays
# valid YAML block-scalar content before substitution -- a token dedented to
# column 0 ends the block scalar as far as a YAML parser is concerned, even
# though nothing downstream of that indentation actually needs it (the
# rendered, fully-substituted output is valid either way). This wrapper
# strips that same 12-space indent from just the first line of
# render_proxy_locations_body's output, so it isn't doubled up; every other
# line supplies its own indent, since nothing in the template indents them.
render_proxy_locations() {
    local body
    body="$(render_proxy_locations_body "$@")" || return 1
    printf '%s' "${body/#            /}"
}

# The server-level `include /etc/nginx/upstream-key.conf;` block (plus its
# leading comment and the one blank line that follows it), verbatim from
# manifests/k8s/30-proxy.yaml -- kept as a STATIC block in that file, never a
# placeholder token, specifically so the legacy K8S_PROXY_UPSTREAM path needs
# no substitution machinery here at all and its bytes cannot drift. A
# K8S_PROXY_ENDPOINTS install strips this exact block out of the rendered
# text instead (see strip_proxy_key_include below): a registered endpoint is
# keyless by construction in this round, so it must create no Secret and
# include no such file -- see cmd_install's own Secret-creation guard for the
# other half of that.
proxy_key_include_block() {
    local block
    # $() strips ALL trailing newlines, not just one, so the heredoc's own
    # trailing newline cannot be relied on to produce the block's trailing
    # blank line. A trailing sentinel (X) protects the two newlines this
    # prints from being stripped a SECOND time by strip_proxy_key_include's
    # own $(proxy_key_include_block) capture -- the sentinel is removed there
    # with a parameter expansion, which does not touch trailing whitespace.
    block="$(cat <<'BLOCK'
            # Defines $upstream_key. Mounted from the Secret, never from this
            # ConfigMap -- see the header above.
            #
            # This include sits in `server`, NOT in `http`, and that is
            # load-bearing: the file it pulls in is a `set` directive, and
            # nginx allows `set` only in server, location and if. At http
            # level nginx refuses to start with
            #   "set" directive is not allowed here
            # which crashloops the proxy. Measured against a live cluster.
            include /etc/nginx/upstream-key.conf;
BLOCK
)"
    printf '%s\n\nX' "$block"
}

# Removes proxy_key_include_block's exact text (plus the one blank line that
# follows it in the template) from $1, for a K8S_PROXY_ENDPOINTS
# (keyless) render. Errors out rather than silently no-op'ing if the block
# is not found -- a mismatch here means manifests/k8s/30-proxy.yaml's static
# text and this function's copy of it have drifted apart, and applying a
# keyless render that still includes upstream-key.conf would be a Secret
# dependency this mode promises never to have.
strip_proxy_key_include() {
    local text="$1" block stripped
    block="$(proxy_key_include_block)"
    block="${block%X}"
    stripped="${text/"$block"/}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the upstream-key include block in the" >&2
        echo "rendered proxy ConfigMap -- manifests/k8s/30-proxy.yaml and" >&2
        echo "proxy_key_include_block in this script have drifted apart." >&2
        return 1
    fi
    printf '%s' "$stripped"
}

render_proxy_locations_body() {
    local upstream_host="$1"

    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        cat <<EOF
            location = /api/v1/chat/completions {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$K8S_PROXY_UPSTREAM";
                proxy_pass \$upstream/api/v1/chat/completions;

                # A variable in proxy_pass makes nginx resolve at request
                # time through the resolver above, rather than once at
                # startup -- so the upstream's DNS record can rotate
                # without a restart here.
                # proxy_ssl_verify without a trusted certificate is a
                # startup error, not a silent downgrade -- nginx refuses
                # with "no proxy_ssl_trusted_certificate for
                # proxy_ssl_verify". The path is the CA bundle shipped in
                # the nginx alpine image. Measured against a live cluster.
                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$upstream_host";
                proxy_set_header Host "$upstream_host";

                proxy_set_header Authorization "Bearer \$upstream_key";
                proxy_hide_header Authorization;
            }
EOF
        return 0
    fi

    local i name base host
    for (( i = 0; i < ${#PROXY_ENDPOINT_NAMES[@]}; i++ )); do
        name="${PROXY_ENDPOINT_NAMES[$i]}"
        base="${PROXY_ENDPOINT_URLS[$i]}"
        host="${base#*://}"
        host="${host%%/*}"
        (( i > 0 )) && printf '\n'
        cat <<EOF
            location = /e/$name/v1/chat/completions {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$base";
                proxy_pass \$upstream/chat/completions;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";
            }

            location = /e/$name/v1/models {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$base";
                proxy_pass \$upstream/models;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";
            }
EOF
    done
}

cmd_install() {
    local dry_run=false
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) echo "Error: unknown option '$1' for install." >&2; exit 1 ;;
        esac
    done

    if [[ -n "$K8S_PROXY_UPSTREAM" && -n "$K8S_PROXY_ENDPOINTS" ]]; then
        echo "Error: K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS are mutually" >&2
        echo "exclusive -- set one or the other, never both. K8S_PROXY_UPSTREAM" >&2
        echo "is the legacy single API-keyed upstream; K8S_PROXY_ENDPOINTS" >&2
        echo "registers one or more named, keyless endpoints instead." >&2
        exit 1
    fi
    if [[ -z "$K8S_PROXY_UPSTREAM" && -z "$K8S_PROXY_ENDPOINTS" ]]; then
        echo "Error: neither K8S_PROXY_UPSTREAM nor K8S_PROXY_ENDPOINTS is set" >&2
        echo "in $k8s_env. Add one of:" >&2
        echo "  K8S_PROXY_UPSTREAM=https://openrouter.ai" >&2
        echo "  K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1" >&2
        exit 1
    fi

    local upstream_host=""
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        upstream_host="$(validate_upstream_url "$K8S_PROXY_UPSTREAM" K8S_PROXY_UPSTREAM)" || exit 1
    fi

    # Fills the module-global PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS
    # arrays render_proxy_locations reads below. Validated here, before
    # anything is rendered or applied, same as every other check in this
    # function.
    parse_proxy_endpoints "$K8S_PROXY_ENDPOINTS" || exit 1

    # Fills the module-global PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS arrays
    # render_proxy_egress_rules reads below. K8S_PROXY_ALLOW is independent
    # of which upstream mode is active -- nothing here requires
    # K8S_PROXY_ENDPOINTS, since a legacy install could in principle want an
    # explicit allowlist too.
    parse_proxy_allow "$K8S_PROXY_ALLOW" || exit 1

    resolve_platform || exit 1

    local manifests_dir
    manifests_dir="$(dirname "$script_dir")/manifests/k8s"
    if [[ ! -d "$manifests_dir" ]]; then
        echo "Error: $manifests_dir not found. Run this from a fork-sandbox" >&2
        echo "checkout." >&2
        exit 1
    fi

    local rendered f
    rendered=""
    for f in "$manifests_dir"/*.yaml; do
        # 31-claude-proxy.yaml is rendered per-run by cmd_submit, keyed on
        # that run's own __RUN_NAME__ -- a value install has no run to take
        # it from. Applying it here would apply a broken manifest with a
        # literal, unsubstituted __RUN_NAME__ in it.
        [[ "$(basename "$f")" == 31-claude-proxy.yaml ]] && continue
        local file_rendered
        file_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__PROXY_UPSTREAM_HOST__|$upstream_host|g" \
            -e "s|__PROXY_UPSTREAM__|$K8S_PROXY_UPSTREAM|g" \
            "$f")"
        if [[ "$(basename "$f")" == 30-proxy.yaml ]]; then
            # The nginx location block(s) for whichever upstream mode is
            # active -- built fully-resolved (see render_proxy_locations's
            # own header for why), never left as a token for a later sed
            # pass to fill in.
            file_rendered="${file_rendered//__PROXY_LOCATIONS__/$(render_proxy_locations "$upstream_host")}"

            # The proxy's own NetworkPolicy egress rule(s) -- see
            # render_proxy_egress_rules's own header for why unset
            # K8S_PROXY_ALLOW must render byte-identical to today's default.
            file_rendered="$(render_proxy_egress_rules_sub "$file_rendered")" || exit 1

            # A K8S_PROXY_ENDPOINTS (keyless) install creates no
            # fork-sandbox-upstream-key Secret below, so it must not include
            # a file that Secret is the only thing that ever mounts --
            # nginx would otherwise crashloop on a missing include. The
            # legacy K8S_PROXY_UPSTREAM path leaves this block in place
            # untouched, which is what keeps its render byte-identical.
            if [[ -z "$K8S_PROXY_UPSTREAM" ]]; then
                file_rendered="$(strip_proxy_key_include "$file_rendered")" || exit 1
            fi

            # A hash of the rendered nginx.conf, filled into the proxy
            # Deployment's pod-template annotation so a config change rolls
            # the proxy by itself -- see the annotation's own comment in
            # manifests/k8s/30-proxy.yaml for why the template, not the
            # Deployment's own metadata, has to carry it.
            local conf_checksum
            conf_checksum="$(k8s_extract_nginx_conf <<< "$file_rendered" | k8s_sha256_stdin)" || exit 1
            file_rendered="${file_rendered//__PROXY_CONF_CHECKSUM__/$conf_checksum}"
        fi
        rendered+="$file_rendered"$'\n'
    done
    rendered+="$("$K8S_PLATFORM_BIN" render-policy --namespace "$K8S_NAMESPACE" \
        --agent-label app=fork-sandbox-agent \
        --proxy-label app=fork-sandbox-proxy --proxy-port 8080)"

    if [[ "$dry_run" == true ]]; then
        printf '%s\n' "$rendered"
        exit 0
    fi

    printf '%s\n' "$rendered" | kubectl apply -f -

    # OPENROUTER_API_KEY is required, and this Secret is created, ONLY on
    # the legacy K8S_PROXY_UPSTREAM path -- a K8S_PROXY_ENDPOINTS install is
    # keyless by construction (see proxy_key_include_block/
    # strip_proxy_key_include above for the other half of that) and reads no
    # credential from pi.env at all.
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        require_secret_file "$pi_env" || exit 1
        local api_key
        api_key="$(read_env_value "$pi_env" OPENROUTER_API_KEY || true)"
        if [[ -z "$api_key" ]]; then
            echo "Error: OPENROUTER_API_KEY not found in $pi_env. install reads" >&2
            echo "the model proxy's key from the same file a local --harness pi" >&2
            echo "run uses." >&2
            exit 1
        fi
        fs_reject_unsafe_chars "$api_key" || exit 1
        kubectl create secret generic fork-sandbox-upstream-key \
            --from-literal="upstream-key.conf=set \$upstream_key \"$api_key\";" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    echo "fork-sandbox-k8s: installed into namespace $K8S_NAMESPACE" >&2
}

cmd_submit() {
    local dry_run=false branch="" model="" review_loop_cap="" outbox_max_arg=""
    local context_ro="" harness="pi" review_model=""
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --model) model="${2:?--model requires an OpenRouter model id}"; shift 2 ;;
            --harness) harness="${2:?--harness requires 'pi' or 'claude'}"; shift 2 ;;
            --review-loop) review_loop_cap="${2:?--review-loop requires a positive integer}"; shift 2 ;;
            --review-model) review_model="${2:?--review-model requires a model id}"; shift 2 ;;
            --outbox-max) outbox_max_arg="${2:?--outbox-max requires a size}"; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for submit." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"
    local handoff_file="${2:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"

    case "$harness" in
        pi|claude) ;;
        *)
            echo "Error: --harness takes 'pi' or 'claude', not '$harness'." >&2
            exit 1
            ;;
    esac

    [[ -n "$model" ]] || { echo "Error: submit requires --model. There is no default:" >&2
        echo "the model is an OpenRouter id, such as moonshotai/kimi-k3." >&2; exit 1; }
    branch="${branch:-k8s-$(date +%Y%m%d-%H%M%S)}"
    fs_reject_unsafe_chars "$branch" "$model" || exit 1

    # --review-loop takes a positive integer, the same shape and the same
    # message fork-sandbox.sh's own local flag uses, so a bad value reads
    # the same regardless of which path a caller is on. review_loop_cap
    # starts empty (flag not given) rather than "0", so that "--review-loop
    # 0" -- a real value, not the same thing as omitting the flag -- is
    # caught here instead of silently collapsing into "no loop".
    if [[ -n "$review_loop_cap" && ! "$review_loop_cap" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: --review-loop takes a positive integer — the maximum" >&2
        echo "number of review-then-fix iterations — not '$review_loop_cap'." >&2
        exit 1
    fi
    review_loop_cap="${review_loop_cap:-0}"

    # Resolved here, before anything is created, same as the checks above --
    # fs_parse_size_bytes already prints its own error naming what was given.
    local outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    if [[ -n "$outbox_max_arg" ]]; then
        outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
    fi

    [[ -n "$review_model" ]] && { fs_reject_unsafe_chars "$review_model" || exit 1; }

    # The same cross-check fork-sandbox-k8s-entrypoint.sh enforces pod-side
    # (HARNESS=claude and REVIEW_LOOP_CAP set but REVIEW_MODEL empty),
    # checked here too so a caller of this direct entry point -- not just
    # fork-sandbox.sh --k8s, which already guarantees it -- fails before the
    # proxy Pod, the token Secret, the Job and a full repository push all
    # happen for a run that can only fail once the pod starts.
    if [[ "$harness" == claude && $review_loop_cap -gt 0 && -z "$review_model" ]]; then
        echo "Error: --review-model is required with --harness claude" >&2
        echo "--review-loop -- the review loop always runs pi, and --model" >&2
        echo "is a Claude Code model name pi cannot use." >&2
        exit 1
    fi

    # The operator's own OAuth credential, for --harness claude only --
    # read and validated here, before anything is created, the same rule
    # every other pre-creation check in this function follows. Read once;
    # both the per-run Secret below (the real access token, for the proxy)
    # and the ConfigMap's placeholder credential (the sanitized JSON, for
    # the pod's claude CLI) come from this single read. This is a local
    # file read (or, on macOS, a Keychain read), so it runs even under
    # --dry-run -- no cluster is contacted, exactly like every other
    # validation in this function that --dry-run is meant to exercise.
    local claude_cred_json="" claude_access_token="" claude_configmap_cred=""
    if [[ "$harness" == claude ]]; then
        claude_cred_json="$(fs_read_claude_credential)" || exit 1

        # The pod cannot refresh the token, so a run that outlives it dies
        # -- the same lifetime caveat a local claude-sandboxed session has.
        # Same two messages, adapted from "the sandbox session" to "the
        # pod's session".
        # Piped with printf, never a here-string: on bash before 5.1 a
        # here-string spills its value to a temp file, and this one holds
        # the live token. Same rule as fs_read_claude_credential's header.
        local claude_expires_at_ms claude_mins_left
        claude_expires_at_ms="$(printf '%s' "$claude_cred_json" | jq -r '.claudeAiOauth.expiresAt // 0')"
        claude_mins_left=$(( claude_expires_at_ms / 60000 - $(date +%s) / 60 ))
        if (( claude_mins_left <= 0 )); then
            echo "Error: the access token in $(fs_claude_credential_source) has expired." >&2
            echo "Log in with claude on the host, then retry." >&2
            exit 1
        elif (( claude_mins_left < 60 )); then
            echo "Warning: the access token expires in ${claude_mins_left}m; the pod's session dies then." >&2
        fi

        claude_access_token="$(printf '%s' "$claude_cred_json" | jq -r '.claudeAiOauth.accessToken // empty')"
        if [[ -z "$claude_access_token" ]]; then
            echo "Error: $(fs_claude_credential_source) has no claudeAiOauth.accessToken." >&2
            exit 1
        fi
        fs_reject_unsafe_chars "$claude_access_token" || exit 1

        # The placeholder credential shipped into the pod's ConfigMap: the
        # same sanitizing jq claude-sandboxed applies to a local sandbox's
        # copy (drop mcpOAuth, and the refresh token and its expiry -- the
        # pod needs and may hold neither), plus one substitution unique to
        # this path -- the real access token becomes the literal string
        # "sandbox", since Claude Code accepts any placeholder locally and
        # the proxy supplies the real bearer on the way past. After this
        # substitution the file holds no secret (just scopes, subscription
        # type, expiry), which is what makes a ConfigMap -- not a Secret --
        # the right place for it.
        claude_configmap_cred="$(printf '%s' "$claude_cred_json" | jq '
            del(.mcpOAuth)
            | del(.claudeAiOauth.refreshToken, .claudeAiOauth.refreshTokenExpiresAt)
            | .claudeAiOauth.accessToken = "sandbox"
        ')"
    fi

    # The same rule fork-sandbox.sh's own local --context-ro flag applies to
    # its --bind-ro (scripts/fork-sandbox.sh, around the FS_REALPATH check
    # near its argument validation): the directory's real path must be
    # under /var/tmp/claude-scratch/forks/, and it must exist. A
    # blanket-approved script must not be pointable at an arbitrary host
    # directory (~/.ssh, say) to ship it into a pod. Checked here, ahead of
    # --dry-run's early exit below, so a bad path is refused with no
    # cluster involved -- the size cap, which needs an actual tar of the
    # directory, is checked later, alongside the real push, which --dry-run
    # never reaches.
    if [[ -n "$context_ro" ]]; then
        local context_ro_real
        context_ro_real="$("$FS_REALPATH" -m "$context_ro")"
        if [[ "$context_ro_real" != /var/tmp/claude-scratch/forks/* ]]; then
            echo "Error: --context-ro must name a directory under" >&2
            echo "/var/tmp/claude-scratch/forks/ — got '$context_ro_real'. The" >&2
            echo "pod reads it after it is pushed, so which paths may be" >&2
            echo "handed to a pod this way is a security boundary. Stage the" >&2
            echo "context in a mktemp directory there and rerun." >&2
            exit 1
        fi
        if [[ ! -d "$context_ro_real" ]]; then
            echo "Error: --context-ro directory '$context_ro_real' does not exist." >&2
            exit 1
        fi
        # tar cf's ordinary (non -h) walk turns a symlink into a link
        # entry, which fork-sandbox-k8s-context-extract.sh refuses -- but
        # only after the Job exists, the pod is Ready and the repository
        # has already been pushed. Catching it here refuses before
        # any of that happens. A hard link gets the same "link entry"
        # treatment from tar (it sees the same device+inode a second time
        # under a different name), so it needs its own check here too --
        # `find -type l` only ever matches symlinks.
        local context_ro_symlink
        context_ro_symlink="$(find "$context_ro_real" -type l -print -quit)"
        if [[ -n "$context_ro_symlink" ]]; then
            echo "Error: --context-ro directory '$context_ro_real' contains a symlink" >&2
            echo "('$context_ro_symlink'); links are not allowed in a pushed context" >&2
            echo "directory." >&2
            exit 1
        fi
        # Any link count above one is enough to refuse the file. Looking only
        # for an inode seen twice inside this tree misses the dangerous case
        # where the other name is outside the context directory.
        local context_ro_hardlink
        context_ro_hardlink="$(find "$context_ro_real" -type f -links +1 -print -quit)"
        if [[ -n "$context_ro_hardlink" ]]; then
            echo "Error: --context-ro directory '$context_ro_real' contains a hard-linked file" >&2
            echo "('$context_ro_hardlink'); links are not allowed in a pushed context" >&2
            echo "directory." >&2
            exit 1
        fi
        context_ro="$context_ro_real"
    fi

    if [[ ! -d "$project_path" ]]; then
        echo "Error: project path '$project_path' is not a directory." >&2
        exit 1
    fi
    local origin_repo
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1
    fs_check_branch_free "$origin_repo" "$branch" || exit 1

    # base_sha, the review skill and the loop script itself are only needed
    # under --review-loop, but resolved here, before anything is created,
    # so a missing one fails now rather than after the pod is up.
    local base_sha="" review_skill_src="" review_loop_sh="$script_dir/fork-sandbox-k8s-review-loop.sh"
    if (( review_loop_cap > 0 )); then
        # submit pushes this repo's current HEAD as the branch's starting
        # point (see the push below), so that HEAD is the base the review
        # leg's commit range is measured from.
        if ! base_sha="$(cd "$origin_repo" && git rev-parse HEAD 2>/dev/null)"; then
            echo "Error: could not read HEAD in $origin_repo. --review-loop" >&2
            echo "needs the commit the branch is measured against, and submit" >&2
            echo "pushes this repo's current HEAD as that base." >&2
            exit 1
        fi

        # The review leg's method. Read from this repo's own skills/, never
        # from ~/.claude/skills/ -- that path is a symlink into this repo on
        # a machine that has run install.sh, and would not exist elsewhere.
        review_skill_src="$(dirname "$script_dir")/skills/code-review-portable/SKILL.md"
        if [[ ! -f "$review_skill_src" ]]; then
            echo "Error: --review-loop needs the code-review-portable skill, which" >&2
            echo "is the review leg's method, and $review_skill_src" >&2
            echo "is not there. Run this from a fork-sandbox checkout." >&2
            exit 1
        fi
    fi

    if [[ ! -f "$handoff_file" ]]; then
        echo "Error: handoff file '$handoff_file' not found." >&2
        exit 1
    fi
    if [[ ! -s "$handoff_file" ]]; then
        echo "Error: handoff file '$handoff_file' is empty. It is the run's" >&2
        echo "whole prompt." >&2
        exit 1
    fi

    if [[ -z "$K8S_IMAGE" ]]; then
        echo "Error: K8S_IMAGE is not set in $k8s_env. This project ships a" >&2
        echo "Dockerfile and a build script, and never ships an image or a" >&2
        echo "registry -- you build it and push it to a registry you control." >&2
        echo "There is no default: a pod cannot use a local docker image, so" >&2
        echo "a silent default would only produce a confusing" >&2
        echo "ImagePullBackOff. Add a line:" >&2
        echo "  K8S_IMAGE=registry.example/you/fork-sandbox:latest" >&2
        echo "See docs/kubernetes-runs.md for registry options." >&2
        exit 1
    fi
    if [[ -z "$K8S_DENIED_PROBE" ]]; then
        echo "Error: K8S_DENIED_PROBE is not set in $k8s_env. The egress gate" >&2
        echo "needs a host:port the policy must deny, to prove the pin holds" >&2
        echo "before anything untrusted runs. Add a line:" >&2
        echo "  K8S_DENIED_PROBE=10.0.0.1:443" >&2
        exit 1
    fi

    resolve_platform || exit 1
    local icmp_check=0
    [[ "$(platform_capability icmp unfiltered)" == filtered ]] && icmp_check=1

    local safe_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    local proxy_base_url="http://fork-sandbox-proxy.$K8S_NAMESPACE.svc.cluster.local:8080/api/v1"

    # The egress-gate initContainer's own proxy probe: the shared pi proxy
    # for a pi run, this run's own per-run proxy for a claude run -- see
    # the Job env below, which is what actually needs this value.
    local egress_proxy_host="fork-sandbox-proxy.$K8S_NAMESPACE.svc.cluster.local"
    [[ "$harness" == claude ]] && egress_proxy_host="$safe_name-claude-proxy.$K8S_NAMESPACE.svc.cluster.local"

    # The per-run Claude Code proxy manifest (ConfigMap + Pod + Service),
    # rendered here -- ahead of the ConfigMap+Job below, in the SAME
    # `kubectl apply` stream -- for --harness claude only. See
    # manifests/k8s/31-claude-proxy.yaml's own header for why this is a
    # separate per-run Pod rather than a sidecar or the shared proxy.
    # __RUN_NAME__ is this run's own $safe_name, the same object-name
    # component the agent Job and its ConfigMap use.
    local claude_proxy_rendered=""
    if [[ "$harness" == claude ]]; then
        local claude_proxy_template
        claude_proxy_template="$(dirname "$script_dir")/manifests/k8s/31-claude-proxy.yaml"
        if [[ ! -f "$claude_proxy_template" ]]; then
            echo "Error: $claude_proxy_template not found. Run this from a" >&2
            echo "fork-sandbox checkout." >&2
            exit 1
        fi
        claude_proxy_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__RUN_NAME__|$safe_name|g" \
            "$claude_proxy_template")"$'\n'
    fi

    local entrypoint_sh="$script_dir/fork-sandbox-k8s-entrypoint.sh"
    local gate_sh="$script_dir/fork-sandbox-k8s-egress-gate.sh"
    local inbox_write_sh="$script_dir/fork-sandbox-k8s-inbox-write.sh"
    local context_extract_sh="$script_dir/fork-sandbox-k8s-context-extract.sh"
    local inbox_hook_sh="$script_dir/fork-sandbox-inbox-hook.sh"
    for f in "$entrypoint_sh" "$gate_sh" "$inbox_write_sh" "$review_loop_sh" "$context_extract_sh"; do
        [[ -x "$f" ]] || { echo "Error: $f is missing or not executable." >&2; exit 1; }
    done

    # The two --harness claude-only ConfigMap keys: the placeholder
    # credential and the operator-inbox hook -- see
    # render_claude_configmap_keys's own header. Same newline-prefix
    # convention as review_loop_configmap_keys below, so an empty string
    # here changes nothing about the no-claude render.
    local claude_configmap_keys=""
    if [[ "$harness" == claude ]]; then
        [[ -x "$inbox_hook_sh" ]] \
            || { echo "Error: $inbox_hook_sh is missing or not executable." >&2; exit 1; }
        claude_configmap_keys=$'\n'"$(render_claude_configmap_keys \
            "$claude_configmap_cred" "$inbox_hook_sh")"
    fi

    # Must track fork-sandbox-k8s-entrypoint.sh's own work_dir/clone_dir --
    # this script renders the ConfigMap before the pod exists, so there is
    # nowhere to read the value back from. POD_SKILL_DIR and
    # POD_VERDICT_FILE are the same kind of pod-path knowledge, for the two
    # more paths the review prompt has to name.
    local pod_clone_dir=/work/clone
    local POD_SKILL_DIR=/work/skills/code-review-portable
    local POD_VERDICT_FILE="$pod_clone_dir/.git/review-verdict.md"

    # The four --review-loop-only ConfigMap keys and the two env vars they
    # need, rendered only when this run carries a loop. Prefixed with a
    # newline so embedding an EMPTY string here changes nothing about the
    # no-review-loop render below -- see render_review_loop_configmap_keys's
    # own header for why the keys carry no prompt prose of their own.
    local review_loop_configmap_keys="" review_loop_env=""
    if (( review_loop_cap > 0 )); then
        review_loop_configmap_keys=$'\n'"$(render_review_loop_configmap_keys \
            "$pod_clone_dir" "$POD_INBOX_DIR" "$POD_SKILL_DIR" "$POD_VERDICT_FILE" \
            "$branch" "$base_sha" "$review_skill_src" "$review_loop_sh" "$POD_OUTBOX_DIR" \
            "$outbox_max_bytes")"
        review_loop_env=$'\n'"$(render_review_loop_env "$review_loop_cap" "$base_sha")"
    fi

    # CLAUDE_PROXY_BASE_URL, for --harness claude only -- the per-run
    # proxy Service a claude coding leg needs; a pi coding leg talks to
    # the shared proxy via PROXY_BASE_URL instead, set unconditionally
    # above.
    local claude_env=""
    if [[ "$harness" == claude ]]; then
        claude_env=$'\n'"$(cat <<CENV
            - name: CLAUDE_PROXY_BASE_URL
              value: "http://$safe_name-claude-proxy.$K8S_NAMESPACE.svc.cluster.local:8080"
CENV
)"
    fi

    # REVIEW_MODEL, whenever --review-model was given -- regardless of
    # harness. The review loop always runs pi, so this is the id its
    # models.json should carry alongside (pi) or instead of (claude) the
    # coding leg's own MODEL; see synthesize_pi_config in the entrypoint.
    local review_model_env=""
    if [[ -n "$review_model" ]]; then
        review_model_env=$'\n'"$(cat <<CENV
            - name: REVIEW_MODEL
              value: "$review_model"
CENV
)"
    fi

    local job_rendered rendered
    job_rendered="$(cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $safe_name-scripts
  namespace: $K8S_NAMESPACE
  labels:
    app: fork-sandbox-agent
    fork-sandbox/branch: $safe_name
data:
  entrypoint.sh: |
$(indent_block < "$entrypoint_sh")
  egress-gate.sh: |
$(indent_block < "$gate_sh")
  inbox-write.sh: |
$(indent_block < "$inbox_write_sh")
  context-extract.sh: |
$(indent_block < "$context_extract_sh")
  handoff.md: |
$({ fs_emit_prompt_preamble "$pod_clone_dir" "$POD_INBOX_DIR" "$harness" gated "$POD_OUTBOX_DIR" pod \
       "$outbox_max_bytes"
   [[ -n "$context_ro" ]] && render_context_section "$POD_CONTEXT_DIR"
   printf '\n---\n\n'
   cat -- "$handoff_file"; } | indent_block)${review_loop_configmap_keys}${claude_configmap_keys}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $safe_name
  namespace: $K8S_NAMESPACE
  labels:
    app: fork-sandbox-agent
    fork-sandbox/branch: $safe_name
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: fork-sandbox-agent
        fork-sandbox/branch: $safe_name
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: egress-gate
          image: $K8S_IMAGE
          command: ["bash", "/mnt/fork-sandbox/egress-gate.sh"]
          env:
            - name: DENIED_PROBE
              value: "$K8S_DENIED_PROBE"
            - name: PROXY_HOST
              value: "$egress_proxy_host"
            - name: PROXY_PORT
              value: "8080"
            - name: ICMP_CHECK
              value: "$icmp_check"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
      containers:
        - name: agent
          image: $K8S_IMAGE
          command: ["bash", "/mnt/fork-sandbox/entrypoint.sh"]
          env:
            - name: HOME
              value: /home/agent
            - name: BRANCH
              value: "$branch"
            - name: HARNESS
              value: "$harness"
            - name: MODEL
              value: "$model"
            - name: PROXY_BASE_URL
              value: "$proxy_base_url"
            - name: GIT_USER_NAME
              value: "$GIT_USER_NAME"
            - name: GIT_USER_EMAIL
              value: "$GIT_USER_EMAIL"
            - name: RUN_TTL
              value: "$K8S_RUN_TTL"
            - name: OUTBOX_MAX_BYTES
              value: "$outbox_max_bytes"${review_loop_env}${claude_env}${review_model_env}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            - name: home
              mountPath: /home/agent
      volumes:
        - name: scripts
          configMap:
            name: $safe_name-scripts
        - name: work
          # Deliberately no sizeLimit here. /work holds the outbox this
          # file's own OUTBOX_MAX_BYTES budgets -- but an emptyDir sizeLimit
          # is enforced by the kubelet EVICTING THE WHOLE POD the moment
          # it's crossed, which would destroy the clone and the branch along
          # with the oversized outbox. A refused pull-back (the outcome
          # OUTBOX_MAX_BYTES actually produces, via cmd_run's pull-back guard
          # and the pod-side warning in fork-sandbox-k8s-entrypoint.sh) is
          # far cheaper than losing the whole run to eviction. If you're
          # about to add one back: don't -- the cap already has an
          # enforcement point, and it isn't this.
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: home
          emptyDir: {}
EOF
)"
    rendered="${claude_proxy_rendered}${job_rendered}"

    if [[ "$dry_run" == true ]]; then
        printf '%s\n' "$rendered"
        if [[ "$harness" == claude ]]; then
            printf '# (dry-run) would create Secret %s-claude-token here, holding the operator access token -- not shown.\n' \
                "$safe_name"
        fi
        exit 0
    fi

    # Spool and size the context before creating anything in the cluster or
    # pushing the repository. The EXIT trap covers tar/stat failures and
    # later submit failures, so a large temporary archive cannot leak.
    local context_tar="" context_size=""
    K8S_SUBMIT_CONTEXT_TAR=""
    if [[ -n "$context_ro" ]]; then
        context_tar="$(mktemp)"
        K8S_SUBMIT_CONTEXT_TAR="$context_tar"
        trap 'rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}"' EXIT
        tar cf "$context_tar" -C "$context_ro" .
        context_size="$(stat -c '%s' -- "$context_tar")"
        if (( context_size > CONTEXT_MAX_BYTES )); then
            echo "Error: --context-ro directory '$context_ro' tars to" >&2
            echo "$context_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap." >&2
            exit 1
        fi
    fi

    if [[ "$harness" == claude ]]; then
        # The per-run Secret carrying the REAL operator access token, read
        # by the per-run proxy below -- created here, as the LAST step
        # before any cluster object for this run exists, so that every
        # check above (executable checks, ConfigMap key rendering, YAML
        # substitution) has already run and cannot abort submit with a
        # bare token Secret left behind. Created the same way cmd_install
        # creates fork-sandbox-upstream-key -- kubectl create secret
        # generic --dry-run=client -o yaml | kubectl apply -f -, so the
        # token never appears on any argv beyond that one --from-literal --
        # then labeled in a SEPARATE command, since `kubectl create secret`
        # has no --overwrite of its own and this keeps the token off that
        # second command's argv too. Install the trap BEFORE the create
        # command, so a failure in that command or its pipeline still cleans
        # up. The trap covers the gap between
        # the two commands: if the label call itself is what fails, the
        # Secret it leaves behind carries no fork-sandbox/branch label, so
        # the trap's own by-label delete would miss it too -- which is why
        # the trap also deletes this Secret by name. It also removes the
        # pre-sized context archive, if this run has one.
        K8S_SUBMIT_SAFE_NAME="$safe_name"
        K8S_SUBMIT_BRANCH="$branch"
        trap '
            rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}"
            kubectl delete secret "$K8S_SUBMIT_SAFE_NAME-claude-token" --ignore-not-found >&2
            kubectl delete pod,service,secret,configmap,networkpolicy \
                -l fork-sandbox/branch="$K8S_SUBMIT_SAFE_NAME" --ignore-not-found >&2
            echo "fork-sandbox-k8s: submit failed -- removed this run'"'"'s per-run" >&2
            echo "proxy Pod/Service and token Secret (branch $K8S_SUBMIT_BRANCH)." >&2
            echo "fork-sandbox-k8s: if a Job for this branch was also created," >&2
            echo "finish cleanup with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $K8S_SUBMIT_BRANCH" >&2
        ' EXIT
        kubectl create secret generic "$safe_name-claude-token" \
            --from-literal="upstream-key.conf=set \$upstream_key \"$claude_access_token\";" \
            --dry-run=client -o yaml | kubectl apply -f -
        kubectl label secret "$safe_name-claude-token" \
            fork-sandbox/branch="$safe_name" --overwrite

        # Applied, and waited on, BEFORE the Job below: the egress-gate
        # initContainer probes this proxy the moment the Job's pod starts,
        # and if both went into one `kubectl apply` stream that start could
        # race the proxy's own image pull and readiness, failing the gate
        # closed on a cold node well within its default 60s GATE_TIMEOUT.
        printf '%s\n' "$claude_proxy_rendered" | kubectl apply -f -
        echo "fork-sandbox-k8s: waiting for proxy pod ($safe_name-claude-proxy) to be ready" >&2
        kubectl wait --for=condition=Ready "pod/$safe_name-claude-proxy" --timeout=120s
    fi

    printf '%s\n' "$job_rendered" | kubectl apply -f -

    echo "fork-sandbox-k8s: waiting for pod (job $safe_name) to be ready" >&2
    kubectl wait --for=condition=Ready "pod" -l "job-name=$safe_name" --timeout=180s

    local pod_name
    pod_name="$(kubectl get pod -l "job-name=$safe_name" -o jsonpath='{.items[0].metadata.name}')"
    if [[ -z "$pod_name" ]]; then
        echo "Error: could not find the pod for job $safe_name." >&2
        exit 1
    fi

    echo "fork-sandbox-k8s: pushing $origin_repo to pod $pod_name" >&2
    # -c protocol.ext.allow=always: git disables the ext:: transport by
    # default (post-CVE-2017-1000117 hardening), so an unadorned push here
    # fails with 'fatal: transport "ext" not allowed'. Scoped to this one
    # invocation with git -c, never to global config or GIT_ALLOW_PROTOCOL --
    # this is a real hardening measure, relaxed for exactly one command.
    # -c core.hooksPath=/dev/null: this push runs ON THE HOST, in the repo
    # named on the command line -- and git would otherwise run that repo's
    # own pre-push hook. project_path is caller-supplied, so this script must
    # not trust hooks in a repo it was merely pointed at. Scoped with git -c
    # to this one invocation, never set globally.
    # kubectl exec -i, never -t: a tty applies line-discipline translation
    # to what must stay a binary pack stream, and would corrupt it.
    (cd "$origin_repo" && git -c protocol.ext.allow=always -c core.hooksPath=/dev/null push --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i $pod_name -- git-receive-pack /work/repo.git" \
        "HEAD:refs/heads/$branch")

    # Pushed after the repository, before the sentinel below -- a failure
    # here fails submit before /work/.inputs-complete exists, so the pod
    # fails closed on its INPUTS_TIMEOUT exactly as it does for a client
    # that died mid-push. Spooled to a temp file first (rather than piping
    # `tar cf -` straight into the exec) so the cap below is checked before
    # any of it reaches the pod; kubectl exec -i, never -t, for the same
    # binary-stream reason as the repository push above.
    if [[ -n "$context_ro" ]]; then
        echo "fork-sandbox-k8s: pushing context ($context_ro) to pod $pod_name" >&2
        kubectl exec -i "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$POD_CONTEXT_DIR" "$CONTEXT_MAX_BYTES" context < "$context_tar"
        rm -f -- "$context_tar"
    fi

    kubectl exec "$pod_name" -- sh -c 'touch /work/.inputs-complete'

    # Everything this run needs now exists and is up -- nothing left for
    # the cleanup trap above to protect.
    [[ "$harness" == claude ]] && trap - EXIT

    echo "fork-sandbox-k8s: submitted. branch=$branch pod=$pod_name" >&2
    echo "fork-sandbox-k8s: fetch with: fork-sandbox-k8s.sh fetch --branch $branch $project_path" >&2
}

cmd_fetch() {
    local branch=""
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for fetch." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh fetch --branch NAME <project-path>}"
    [[ -n "$branch" ]] || { echo "Error: fetch requires --branch." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1

    local origin_repo
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1

    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    echo "fork-sandbox-k8s: fetching $branch from pod $pod_name" >&2
    # Same -c protocol.ext.allow=always and -i (never -t) as the push side
    # above, and for the same two reasons. core.hooksPath=/dev/null is
    # load-bearing here too, not just on push: this fetch writes straight
    # into refs/heads/$branch in the caller's real repo rather than a
    # remote-tracking ref, and githooks(5) documents reference-transaction as
    # firing on any Git command that performs reference updates, fetch
    # included -- so a hook in project_path's repo would otherwise run here
    # as well.
    (cd "$origin_repo" && git -c protocol.ext.allow=always -c core.hooksPath=/dev/null fetch --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i $pod_name -- git-upload-pack /work/clone" \
        "refs/heads/$branch:refs/heads/$branch")

    kubectl exec "$pod_name" -- sh -c 'touch /work/.fetched' || true
    echo "fork-sandbox-k8s: fetched into $origin_repo as branch $branch" >&2
}

cmd_say() {
    local branch="" text="" have_text=0
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            -)
                # The stdin sentinel, not an option -- same convention
                # fork-sandbox-say.sh uses for "read the message from stdin".
                [[ -n "$branch" ]] \
                    || { echo "Error: the branch comes first: fork-sandbox-k8s.sh say --branch NAME -" >&2; exit 1; }
                (( have_text )) && { echo "Error: only one message may be given" >&2; exit 1; }
                text="$(cat)"
                have_text=1
                shift
                ;;
            -*) echo "Error: unknown option '$1' for say." >&2; exit 1 ;;
            *)
                if (( ! have_text )); then
                    text="$1"
                    have_text=1
                else
                    echo "Error: only one message may be given; quote it as a single argument" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    [[ -n "$branch" ]] || { echo "Error: say requires --branch." >&2; exit 1; }
    (( have_text )) \
        || { echo "Error: nothing to say. Give the message as one quoted argument, or '-' to read it from stdin." >&2; exit 1; }
    [[ -n "${text//[[:space:]]/}" ]] \
        || { echo "Error: the message is empty. A blank addendum tells the session nothing." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1

    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    # The search-and-write loop lives in fork-sandbox-k8s-inbox-write.sh,
    # mounted into the pod at /mnt/fork-sandbox/ from the same per-run
    # ConfigMap entrypoint.sh and egress-gate.sh already ride in on -- see
    # that script's own header for why the name is always generated and
    # never taken from an argument, and why the final rename is atomic. It
    # runs as the single command this kubectl exec -i carries on its stdio.
    # kubectl exec -i, never -t: a tty would apply line-discipline
    # translation to the message bytes on their way to `cat`.
    local epoch write_out
    epoch="$(date +%s)"
    if ! write_out="$(printf '%s\n' "$text" | kubectl exec -i "$pod_name" -- \
        sh /mnt/fork-sandbox/inbox-write.sh "$epoch" "$POD_INBOX_DIR" 2>&1)"; then
        echo "Error: could not write the addendum into pod $pod_name: $write_out" >&2
        exit 1
    fi

    printf 'wrote %s\n' "$write_out"
    # The delivery contract differs by harness: a pi pod has no hook system
    # and only ever polls the inbox itself, but a claude pod installs
    # fork-sandbox-inbox-hook.sh into PostToolUse/Stop (see
    # fork-sandbox-k8s-entrypoint.sh), so delivery is on the very next tool
    # call and a Stop is blocked while the addendum is unread. Read back off
    # the pod's own HARNESS env rather than assumed, since this command has
    # no other record of which harness this run picked.
    local say_harness
    say_harness="$(kubectl get pod "$pod_name" \
        -o jsonpath='{.spec.containers[?(@.name=="agent")].env[?(@.name=="HARNESS")].value}')"
    if [[ "$say_harness" == claude ]]; then
        printf 'delivery: on the next tool call. The pod runs claude, which\n'
        printf 'installs the operator-inbox hook into PostToolUse and Stop --\n'
        printf 'the agent reads the addendum right after its next tool call,\n'
        printf 'and a Stop is blocked while it is still unread.\n'
    else
        printf 'delivery: within ~25 tool calls. The pod runs pi, which has no\n'
        printf 'hook system, so the agent reads the inbox itself -- on a\n'
        printf 'tool-call floor, around long commands, before each commit, and\n'
        printf 'before its final report.\n'
    fi
}

cmd_rm() {
    local branch=""
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            *) echo "Error: unknown option '$1' for rm." >&2; exit 1 ;;
        esac
    done
    [[ -n "$branch" ]] || { echo "Error: rm requires --branch." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1

    local safe_name legacy_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    kubectl delete job "$safe_name" --ignore-not-found
    kubectl delete configmap "$safe_name-scripts" --ignore-not-found
    if [[ "$legacy_name" != "$safe_name" ]]; then
        kubectl delete job "$legacy_name" --ignore-not-found
        kubectl delete configmap "$legacy_name-scripts" --ignore-not-found
    fi
    # Additionally, by label: the claude-proxy Pod, Service, ConfigMap,
    # Secret and NetworkPolicy, none of which the two deletes above name --
    # harmless on a pi run, which never created anything carrying this
    # label beyond the scripts ConfigMap already deleted above.
    kubectl delete pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch="$safe_name" --ignore-not-found
    if [[ "$legacy_name" != "$safe_name" ]]; then
        kubectl delete pod,service,secret,configmap,networkpolicy \
            -l fork-sandbox/branch="$legacy_name" --ignore-not-found
    fi
    echo "fork-sandbox-k8s: removed job and configmap for branch $branch" >&2
}

# submit, then wait, then fetch, then rm -- see the header comment above for
# why. Reuses cmd_submit/cmd_fetch/cmd_rm rather than growing a second copy
# of any of their bodies; the only new logic here is the poll loop and its
# failure handling.
cmd_run() {
    local dry_run=false keep=false timeout=3600 branch="" model="" review_loop_cap=""
    local outbox_dir="" outbox_max_arg="" context_ro="" harness="" review_model=""
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --keep) keep=true; shift ;;
            --timeout) timeout="${2:?--timeout requires a number of seconds}"; shift 2 ;;
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --model) model="${2:?--model requires an OpenRouter model id}"; shift 2 ;;
            --harness) harness="${2:?--harness requires 'pi' or 'claude'}"; shift 2 ;;
            --review-loop) review_loop_cap="${2:?--review-loop requires a positive integer}"; shift 2 ;;
            --review-model) review_model="${2:?--review-model requires a model id}"; shift 2 ;;
            --outbox-dir) outbox_dir="${2:?--outbox-dir requires a path}"; shift 2 ;;
            --outbox-max) outbox_max_arg="${2:?--outbox-max requires a size}"; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for run." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh run [options] --branch NAME --model MODEL <project-path> <handoff-file>}"
    local handoff_file="${2:?Usage: fork-sandbox-k8s.sh run [options] --branch NAME --model MODEL <project-path> <handoff-file>}"

    # Unlike submit, run has no auto-generated branch name: it needs to know
    # the name up front so the same name can be used to poll, fetch and
    # clean up this one run.
    [[ -n "$branch" ]] || { echo "Error: run requires --branch." >&2; exit 1; }
    [[ -n "$model" ]] || { echo "Error: run requires --model. There is no default:" >&2
        echo "the model is an OpenRouter id, such as moonshotai/kimi-k3." >&2; exit 1; }
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "Error: --timeout must be a whole number of seconds, got '$timeout'." >&2
        exit 1
    fi

    # Resolved here, before anything is created, for run's own pull-back
    # check below -- and forwarded to cmd_submit as a raw string beneath,
    # which parses its own copy for the Job spec. Same value either way;
    # fs_parse_size_bytes already prints its own error naming what was given.
    local outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    if [[ -n "$outbox_max_arg" ]]; then
        outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
    fi

    local -a submit_argv=(--branch "$branch" --model "$model")
    [[ -n "$harness" ]] && submit_argv+=(--harness "$harness")
    # Passed through whenever the flag was given at all, "0" included --
    # cmd_submit does the actual positive-integer validation below, and a
    # bad value here must reach that error rather than silently collapse
    # into "no loop" the way an `(( review_loop_cap > 0 ))` gate would.
    [[ -n "$review_loop_cap" ]] && submit_argv+=(--review-loop "$review_loop_cap")
    [[ -n "$review_model" ]] && submit_argv+=(--review-model "$review_model")
    [[ -n "$outbox_max_arg" ]] && submit_argv+=(--outbox-max "$outbox_max_arg")
    [[ -n "$context_ro" ]] && submit_argv+=(--context-ro "$context_ro")
    submit_argv+=("$project_path" "$handoff_file")

    # cmd_submit does its own full validation (K8S_IMAGE, K8S_DENIED_PROBE,
    # branch freedom, handoff contents...) and, under --dry-run, exits the
    # whole process itself with the rendered YAML -- run never reaches the
    # wait/fetch/rm steps below in that case, and touches no kubectl either.
    if [[ "$dry_run" == true ]]; then
        cmd_submit --dry-run "${submit_argv[@]}"
        exit 0
    fi
    cmd_submit "${submit_argv[@]}"

    local safe_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(kubectl get pod -l "job-name=$safe_name" -o jsonpath='{.items[0].metadata.name}')"
    if [[ -z "$pod_name" ]]; then
        echo "Error: could not find the pod for job $safe_name right after submit." >&2
        exit 1
    fi

    echo "fork-sandbox-k8s: waiting for branch $branch to finish (polling" >&2
    echo "every 10s, timeout ${timeout}s)" >&2

    local start_ts now elapsed last_report_ts run_complete phase job_failed
    start_ts=$(date +%s)
    last_report_ts=$start_ts
    run_complete=""
    while true; do
        # One kubectl exec per probe, as the header comment promises -- this
        # single call both checks for the sentinel and reads it, so a
        # completed run needs no second round trip.
        if run_complete="$(kubectl exec "$pod_name" -- cat /work/.run-complete 2>/dev/null)"; then
            break
        fi

        # A pod that dies before writing the sentinel (OOM, crash, image
        # pull failure, node eviction) must not be polled for the full
        # timeout -- check its state every iteration and stop as soon as it
        # is clearly dead, rather than waiting out the deadline on a corpse.
        phase="$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "$phase" == Failed ]]; then
            echo "Error: pod $pod_name is Failed -- it died before writing" >&2
            echo "/work/.run-complete. Inspect it with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe pod $pod_name" >&2
            echo "fork-sandbox-k8s: the job and pod are left in place for" >&2
            echo "inspection. Remove them with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            exit 1
        fi
        job_failed="$(kubectl get job "$safe_name" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
        if [[ "$job_failed" == True ]]; then
            echo "Error: job $safe_name reports a Failed condition -- it" >&2
            echo "died before /work/.run-complete appeared. Inspect it with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe job $safe_name" >&2
            echo "fork-sandbox-k8s: the job and pod are left in place for" >&2
            echo "inspection. Remove them with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            exit 1
        fi

        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        if (( elapsed >= timeout )); then
            echo "Error: timed out after ${timeout}s waiting for branch" >&2
            echo "$branch to finish. The pod is still running, holding its" >&2
            echo "work -- run does not fetch a half-finished branch and does" >&2
            echo "not remove a still-running pod. Fetch by hand once it" >&2
            echo "completes:" >&2
            echo "  fork-sandbox-k8s.sh fetch --branch $branch $project_path" >&2
            echo "and clean up afterwards with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            exit 1
        fi
        if (( now - last_report_ts >= 60 )); then
            echo "fork-sandbox-k8s: still waiting on branch $branch (${elapsed}s elapsed)" >&2
            last_report_ts=$now
        fi
        sleep 10
    done

    if [[ ! "$run_complete" =~ ^[0-9]+$ ]]; then
        echo "Error: /work/.run-complete on pod $pod_name does not hold an" >&2
        echo "integer exit code (got: '$run_complete'). Treating this as a" >&2
        echo "malformed run rather than guessing at an exit code." >&2
        echo "Inspect it, then fetch by hand if there is anything worth" >&2
        echo "keeping:" >&2
        echo "  fork-sandbox-k8s.sh fetch --branch $branch $project_path" >&2
        echo "and clean up afterwards with:" >&2
        echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
        exit 1
    fi
    local agent_rc="$run_complete"

    echo "fork-sandbox-k8s: agent finished (exit $agent_rc)" >&2

    # The review loop's outcome, when this run carried one. This is the
    # ONLY place a bad loop outcome ever surfaces: agent_rc below stays the
    # CODING leg's exit code (see fork-sandbox-k8s-entrypoint.sh's own
    # comment on .run-complete for why), so a `--k8s --review-loop` run
    # that hit its cap with findings still open would otherwise report
    # success and say nothing about it. Read before cmd_fetch, so this
    # prints even if the fetch itself fails partway through.
    if (( review_loop_cap > 0 )); then
        local loop_json
        if loop_json="$(kubectl exec "$pod_name" -- cat /work/review-loop.json 2>/dev/null)" \
            && jq -e . >/dev/null 2>&1 <<< "$loop_json"; then
            local loop_ended loop_detail loop_iters loop_last_findings
            loop_ended="$(jq -r '.ended // "unknown"' <<< "$loop_json")"
            loop_detail="$(jq -r '.detail // empty' <<< "$loop_json")"
            loop_iters="$(jq -r '.iterations | length' <<< "$loop_json")"
            loop_last_findings="$(jq -r '.iterations[-1].findings // "unknown"' <<< "$loop_json")"
            case "$loop_ended" in
                approved)
                    echo "fork-sandbox-k8s: review loop: APPROVED after $loop_iters iteration(s)" >&2
                    ;;
                cap|no-progress)
                    echo "fork-sandbox-k8s: ################################################" >&2
                    echo "fork-sandbox-k8s: *** review loop ended '$loop_ended' after" >&2
                    echo "fork-sandbox-k8s: *** $loop_iters iteration(s) -- the branch was NOT" >&2
                    echo "fork-sandbox-k8s: *** approved, with $loop_last_findings finding(s)" >&2
                    echo "fork-sandbox-k8s: *** outstanding as of the last iteration." >&2
                    echo "fork-sandbox-k8s: ################################################" >&2
                    ;;
                skipped)
                    echo "fork-sandbox-k8s: review loop skipped${loop_detail:+: $loop_detail}" >&2
                    ;;
                *)
                    echo "fork-sandbox-k8s: ################################################" >&2
                    echo "fork-sandbox-k8s: *** review loop ended '$loop_ended'${loop_detail:+: $loop_detail}" >&2
                    echo "fork-sandbox-k8s: ################################################" >&2
                    ;;
            esac
        else
            echo "fork-sandbox-k8s: warning: could not read /work/review-loop.json" >&2
            echo "from pod $pod_name -- the branch is still worth fetching." >&2
        fi
    fi

    echo "fork-sandbox-k8s: fetching branch $branch" >&2
    cmd_fetch --branch "$branch" "$project_path"

    # Pull /work/outbox back, symmetric with the local path's run_dir/outbox
    # (see fs_emit_prompt_preamble's "## Artifact outbox" section). This is
    # best-effort: retrieving artifacts must never cost the branch just
    # fetched, or block the --keep/rm step below, so every failure here
    # warns and falls through rather than exiting.
    local outbox_dest="$outbox_dir"
    [[ -n "$outbox_dest" ]] \
        || outbox_dest="/var/tmp/claude-scratch/forks/k8s-$(k8s_safe_name_component "$branch")/outbox"
    local outbox_tar outbox_ok=true
    outbox_tar="$(mktemp)"
    if ! kubectl exec "$pod_name" -- tar cf - -C /work/outbox . 2>/dev/null \
            | head -c "$((outbox_max_bytes + 1))" > "$outbox_tar"; then
        echo "fork-sandbox-k8s: warning: could not read the outbox from pod $pod_name; nothing pulled back." >&2
        outbox_ok=false
    fi
    if [[ "$outbox_ok" == true ]] && (( $(stat -c '%s' -- "$outbox_tar") > outbox_max_bytes )); then
        echo "fork-sandbox-k8s: warning: pod $pod_name's outbox is over the $outbox_max_bytes byte cap; refusing to pull it back." >&2
        outbox_ok=false
    fi
    if [[ "$outbox_ok" == true ]] && ! mkdir -p -- "$(dirname -- "$outbox_dest")"; then
        echo "fork-sandbox-k8s: warning: could not create $(dirname -- "$outbox_dest"); outbox not pulled back." >&2
        outbox_ok=false
    fi
    if [[ "$outbox_ok" == true ]]; then
        if "$script_dir/fork-sandbox-k8s-outbox-extract.sh" "$outbox_tar" "$outbox_dest" "$outbox_max_bytes"; then
            local outbox_count
            outbox_count="$(find "$outbox_dest" -type f | wc -l)"
            if (( outbox_count > 0 )); then
                echo "fork-sandbox-k8s: outbox: $outbox_count file(s) at $outbox_dest" >&2
            else
                echo "fork-sandbox-k8s: outbox: empty (nothing written)" >&2
            fi
        else
            echo "fork-sandbox-k8s: warning: could not extract the outbox tarball; nothing pulled back to $outbox_dest" >&2
        fi
    fi
    rm -f -- "$outbox_tar"

    if [[ "$keep" == true ]]; then
        echo "fork-sandbox-k8s: --keep set; leaving job and pod for branch $branch in place" >&2
    else
        cmd_rm --branch "$branch"
    fi

    echo "fork-sandbox-k8s: run complete. branch=$branch agent_exit=$agent_rc landed_in=$project_path" >&2
    exit "$agent_rc"
}

verb="${1-}"
[[ -n "$verb" ]] || { echo "Error: no command given. Run 'fork-sandbox-k8s.sh --help'." >&2; exit 1; }
shift

case "$verb" in
    install) cmd_install "$@" ;;
    submit) cmd_submit "$@" ;;
    run) cmd_run "$@" ;;
    fetch) cmd_fetch "$@" ;;
    say) cmd_say "$@" ;;
    rm) cmd_rm "$@" ;;
    *)
        echo "Error: unknown command '$verb'. Use install, submit, run, fetch, say or rm." >&2
        exit 1
        ;;
esac
