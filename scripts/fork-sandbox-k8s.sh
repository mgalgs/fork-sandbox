#!/usr/bin/env bash
# fork-sandbox-k8s.sh -- run a sandboxed agent as a Kubernetes Job
#
# Usage: fork-sandbox-k8s.sh install [--dry-run]
#        fork-sandbox-k8s.sh submit [--dry-run] --branch NAME --model MODEL
#                            <project-path> <handoff-file>
#        fork-sandbox-k8s.sh fetch --branch NAME <project-path>
#        fork-sandbox-k8s.sh rm --branch NAME
#
# The Kubernetes analogue of fork-sandbox.sh: submit a task from anywhere
# with cluster access, and a few minutes later fetch a branch. See
# docs/kubernetes-runs.md for the design and docs/k8s-platform.md for the
# pluggable layer this script talks to. This is a NEW script -- it does not
# touch fork-sandbox.sh, and there is no --k8s flag. Wiring the two together
# is a later round.
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
# fetch runs `git fetch` against the pod's clone, the same channel in
# reverse, landing the branch in your real repo. It also signals the pod
# that the run has been collected, so it does not idle out its full TTL.
#
# rm deletes the run's Job, its pod, and its ConfigMap.
#
# --dry-run (install, submit): print the rendered YAML and exit 0. Contacts
# nothing -- no kubectl, no git push, no cluster reachability check. This is
# how the rendering logic is tested without a cluster.
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
#                         Required for install.
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
    "$K8S_PROXY_UPSTREAM" "$K8S_DENIED_PROBE" "$GIT_USER_NAME" "$GIT_USER_EMAIL" \
    || exit 1

kubectl() {
    command kubectl --context="$K8S_CONTEXT" -n "$K8S_NAMESPACE" "$@"
}

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

# A Kubernetes object name: lowercase RFC 1123, <=63 chars. Branch names are
# freeform, so this derives a safe name rather than requiring the caller to
# pick one that already qualifies.
k8s_safe_name() {
    local prefix="$1" branch="$2" safe
    safe="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    safe="${safe##-}"
    safe="${safe%%-}"
    printf '%s-%s' "$prefix" "$safe" | cut -c1-63 | sed 's/-$//'
}

cmd_install() {
    local dry_run=false
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) echo "Error: unknown option '$1' for install." >&2; exit 1 ;;
        esac
    done

    if [[ -z "$K8S_PROXY_UPSTREAM" ]]; then
        echo "Error: K8S_PROXY_UPSTREAM is not set in $k8s_env." >&2
        echo "Add a line: K8S_PROXY_UPSTREAM=https://openrouter.ai" >&2
        exit 1
    fi
    if [[ "$K8S_PROXY_UPSTREAM" != https://* ]]; then
        echo "Error: K8S_PROXY_UPSTREAM must start with https://, got" >&2
        echo "'$K8S_PROXY_UPSTREAM'." >&2
        exit 1
    fi
    local upstream_host="${K8S_PROXY_UPSTREAM#https://}"
    upstream_host="${upstream_host%%/*}"

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
        local file_rendered
        file_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__PROXY_UPSTREAM_HOST__|$upstream_host|g" \
            -e "s|__PROXY_UPSTREAM__|$K8S_PROXY_UPSTREAM|g" \
            "$f")"
        if [[ "$(basename "$f")" == 30-proxy.yaml ]]; then
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

    echo "fork-sandbox-k8s: installed into namespace $K8S_NAMESPACE" >&2
}

cmd_submit() {
    local dry_run=false branch="" model=""
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --model) model="${2:?--model requires an OpenRouter model id}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for submit." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"
    local handoff_file="${2:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"

    [[ -n "$model" ]] || { echo "Error: submit requires --model. There is no default:" >&2
        echo "the model is an OpenRouter id, such as moonshotai/kimi-k3." >&2; exit 1; }
    branch="${branch:-k8s-$(date +%Y%m%d-%H%M%S)}"
    fs_reject_unsafe_chars "$branch" "$model" || exit 1

    if [[ ! -d "$project_path" ]]; then
        echo "Error: project path '$project_path' is not a directory." >&2
        exit 1
    fi
    local origin_repo
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1
    fs_check_branch_free "$origin_repo" "$branch" || exit 1

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

    local entrypoint_sh="$script_dir/fork-sandbox-k8s-entrypoint.sh"
    local gate_sh="$script_dir/fork-sandbox-k8s-egress-gate.sh"
    for f in "$entrypoint_sh" "$gate_sh"; do
        [[ -x "$f" ]] || { echo "Error: $f is missing or not executable." >&2; exit 1; }
    done

    local rendered
    rendered="$(cat <<EOF
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
  handoff.md: |
$(indent_block < "$handoff_file")
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
              value: "fork-sandbox-proxy.$K8S_NAMESPACE.svc.cluster.local"
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
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: home
          emptyDir: {}
EOF
)"

    if [[ "$dry_run" == true ]]; then
        printf '%s\n' "$rendered"
        exit 0
    fi

    printf '%s\n' "$rendered" | kubectl apply -f -

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
    # kubectl exec -i, never -t: a tty applies line-discipline translation
    # to what must stay a binary pack stream, and would corrupt it.
    (cd "$origin_repo" && git -c protocol.ext.allow=always push --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i $pod_name -- git-receive-pack /work/repo.git" \
        "HEAD:refs/heads/$branch")

    kubectl exec "$pod_name" -- sh -c 'touch /work/.inputs-complete'

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

    local safe_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(kubectl get pod -l "job-name=$safe_name" -o jsonpath='{.items[0].metadata.name}')"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    echo "fork-sandbox-k8s: fetching $branch from pod $pod_name" >&2
    # Same -c protocol.ext.allow=always and -i (never -t) as the push side
    # above, and for the same two reasons.
    (cd "$origin_repo" && git -c protocol.ext.allow=always fetch --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i $pod_name -- git-upload-pack /work/clone" \
        "refs/heads/$branch:refs/heads/$branch")

    kubectl exec "$pod_name" -- sh -c 'touch /work/.fetched' || true
    echo "fork-sandbox-k8s: fetched into $origin_repo as branch $branch" >&2
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

    local safe_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    kubectl delete job "$safe_name" --ignore-not-found
    kubectl delete configmap "$safe_name-scripts" --ignore-not-found
    echo "fork-sandbox-k8s: removed job and configmap for branch $branch" >&2
}

verb="${1-}"
[[ -n "$verb" ]] || { echo "Error: no command given. Run 'fork-sandbox-k8s.sh --help'." >&2; exit 1; }
shift

case "$verb" in
    install) cmd_install "$@" ;;
    submit) cmd_submit "$@" ;;
    fetch) cmd_fetch "$@" ;;
    rm) cmd_rm "$@" ;;
    *)
        echo "Error: unknown command '$verb'. Use install, submit, fetch or rm." >&2
        exit 1
        ;;
esac
