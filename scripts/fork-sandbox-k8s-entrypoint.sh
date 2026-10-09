#!/usr/bin/env bash
# fork-sandbox-k8s-entrypoint.sh -- the agent pod's main container
#
# Shipped in via a ConfigMap rather than baked into the image, so iterating
# on it needs no rebuild and no registry push. Invoked as
# `bash fork-sandbox-k8s-entrypoint.sh`, after the egress-gate initContainer
# has already verified the pod's network is sealed the way the platform
# claims. Env is set by the Job spec fork-sandbox-k8s.sh renders.
#
# The repository arrives by PUSH, not by cloning a remote: the client pushes
# it into this pod over the same `kubectl exec` channel the work returns on
# (`git push "ext::kubectl exec -i POD -- git-receive-pack /work/repo.git"`).
# So this script never dials out for the repo, no git remote or credential
# is ever named inside the pod, and egress can stay sealed to the proxy and
# DNS alone.
#
# What follows is the two-phase start every gated input in this project
# uses: wait for a sentinel written LAST, fail closed on a deadline. A
# client that dies mid-push must not become an agent running with a
# half-received repository, so a missing sentinel by the deadline is a
# failure here, not a green light to proceed with whatever arrived.
#
# Env:
#   BRANCH          the branch name the agent's commits land on. Required.
#   EXTRA_REFS      optional, space-separated NAME=SHA pairs: extra branches
#                   the client pushed into the repository beside BRANCH
#                   (fork-sandbox-k8s.sh submit --extra-ref). After the
#                   clone each NAME becomes a LOCAL branch at origin/NAME,
#                   whose sha must equal SHA; BRANCH stays checked out and
#                   only BRANCH is ever fetched back.
#   HARNESS         "pi" or "claude", the coding leg's harness. Default
#                   "pi". The review loop, when it runs, always runs pi
#                   regardless of this -- see REVIEW_MODEL below.
#   MODEL           the model id the coding leg's harness should use: an
#                   OpenRouter id for pi, a Claude Code model name for
#                   claude. Required on a legacy K8S_PROXY_UPSTREAM
#                   install. On a K8S_PROXY_ENDPOINTS install submit may
#                   omit it, in which case discover_model_facts below
#                   resolves it from the proxy's /v1/models: exactly one
#                   model in the listing is used (and said so), zero or
#                   several is an error. When submit DID give one and the
#                   run's context length had to be GUESSED -- the id is
#                   absent from the listing, the catalog fetch itself
#                   failed or came back unparseable, or the entry carries
#                   no usable max_model_len -- that is an ERROR that
#                   refuses the run, at the single point the guess would
#                   be returned -- unless the host set ALLOW_UNLISTED_MODEL,
#                   in which case it is a warning that names the guessed
#                   value as a guess. The id comparison is
#                   case-insensitive (the gateway's lookup is); a
#                   case-variant configured id proceeds with the
#                   listing's canonical spelling.
#                   The same discovery reads the context window
#                   (max_model_len for the chosen model; a missing value
#                   reaches the guess described above, refused by
#                   default) and MAX_TOKENS (agent-sandboxed's rule: a
#                   32768 floor, capped at a quarter of the window). The
#                   review model gets the window discovered for ITS OWN
#                   id, not this model's -- on a --harness claude run this
#                   model is a Claude Code model name the listing never
#                   contains, and the review loop runs pi with
#                   REVIEW_MODEL. All of it feeds synthesize_pi_config
#                   below.
#                   On a legacy K8S_PROXY_UPSTREAM install, or for a
#                   --harness claude run with no --review-loop (no pi leg
#                   of that run talks to this proxy), the host does not
#                   set MODEL_DISCOVERY, so none of this discovery runs:
#                   synthesize_pi_config below gets the constants
#                   131072/32768 the pre-discovery config used.
#   PROXY_BASE_URL  the pi model proxy's base URL, e.g.
#                   http://fork-sandbox-proxy.NS.svc.cluster.local:8080/api/v1
#                   Required regardless of HARNESS -- the review loop
#                   always needs it, even on a claude coding leg.
#   MODEL_DISCOVERY  set to 1 by fork-sandbox-k8s.sh only for a
#                   K8S_PROXY_ENDPOINTS install (where PROXY_BASE_URL
#                   above is an /e/<name>/v1 location, whose render
#                   forwards /models as well as /chat/completions) in
#                   which this run will actually use the pi proxy -- a
#                   pi coding leg, or any run carrying a --review-loop
#                   (the loop always runs pi). Never set on a legacy
#                   K8S_PROXY_UPSTREAM install: that render forwards ONLY
#                   /api/v1/chat/completions, so a $PROXY_BASE_URL/models
#                   probe there would 403 with nginx's error page, and
#                   running discovery unconditionally would kill every
#                   legacy run at pod start. Also never set for a
#                   --harness claude run with no review loop: that leg
#                   talks to CLAUDE_PROXY_BASE_URL, not this proxy, and
#                   the run must not die at pod start because a
#                   workstation-class endpoint is down -- the expected,
#                   ordinary state. The host, which knows the install
#                   kind and the harness, gates the call on this
#                   variable instead of the pod guessing from the URL.
#   ALLOW_UNLISTED_MODEL
#                   set to 1 by fork-sandbox-k8s.sh when k8s.env carries
#                   K8S_ALLOW_UNLISTED_MODEL=1: it permits a launch whose
#                   context length had to be guessed -- the model id is
#                   absent from the listing, the catalog fetch failed or
#                   came back unparseable, or the entry carries no usable
#                   max_model_len -- turning the refusal in
#                   discover_model_facts below into a warning that names
#                   the guessed value as a guess. Unset (the default)
#                   means refuse.
#   PI_ARGS         extra arguments for the pi coding-leg invocation,
#                   verbatim from fork-sandbox-k8s.sh's --pi-args, e.g.
#                   "--thinking low". Rendered only when non-empty, so
#                   unset and empty both mean "no extra arguments" -- an
#                   empty string argument would be a positional pi
#                   rejects; see run_pi_coding_leg for how it is split
#                   into an argv and never evaluated.
#   CLAUDE_PROXY_BASE_URL
#                   the base URL of the per-run proxy that swaps the
#                   placeholder credential below for the operator's real
#                   token, a Service DNS name at port 8080. Required when
#                   HARNESS=claude; unused otherwise.
#   GIT_USER_NAME, GIT_USER_EMAIL
#                   the identity commits land under. Default to a fixed
#                   fork-sandbox identity when unset -- there is no host
#                   gitconfig to inherit inside a pod.
#   INPUTS_TIMEOUT  seconds to wait for the repository push. Default 300.
#   RUN_TTL         seconds to idle after the agent exits, so the clone is
#                   still there when the client fetches. Default 3600.
#   REVIEW_LOOP_CAP the maximum review-then-fix iterations to run after the
#                   coding leg, for fork-sandbox-k8s.sh's --review-loop.
#                   Default 0 (no loop). Set by fork-sandbox-k8s.sh's
#                   `submit` only when --review-loop was given.
#   BASE_SHA        the commit the branch is measured against, for the
#                   review loop's commit range. Required when
#                   REVIEW_LOOP_CAP is set; unused otherwise.
#   REVIEW_MODEL    the OpenRouter model id the review loop's pi runs
#                   should use, when it differs from MODEL. Required when
#                   HARNESS=claude and REVIEW_LOOP_CAP is set, since
#                   MODEL is then a Claude Code model name pi cannot use.
#                   Optional otherwise -- including for a pi coding leg,
#                   where it is folded into models.json alongside MODEL
#                   (see synthesize_pi_config) so the review loop can
#                   select either id; the review loop falls back to MODEL
#                   when unset.
#   OUTBOX_MAX_BYTES the outbox size cap, in bytes, for the end-of-run
#                   warning below. Default 67108864 (64 MiB) -- must match
#                   FS_OUTBOX_MAX_BYTES in fork-sandbox-lib.sh; nothing
#                   enforces the two staying equal, since this script does
#                   not source that file. Set by fork-sandbox-k8s.sh's
#                   `submit` to the effective value (default, or raised by
#                   --outbox-max).
#   SESSION_HARNESS_STORE
#                   set to 1 by fork-sandbox-k8s.sh's `submit` when it
#                   pushed a --session-state store into the pod at
#                   /work/session-store, so this script keeps one
#                   conversation across wakes the same way a local
#                   --session-state run does. Unset means today's
#                   behaviour: no seed, no resume, no snapshot.
#   RESUME_SESSION  the claude session id to resume, when HARNESS=claude
#                   and SESSION_HARNESS_STORE=1. Optional even then -- a
#                   first wake on a thread has no prior transcript to
#                   resume and starts fresh.
#   SESSION_ID      the pi session id for the coding leg's --session-id,
#                   when HARNESS=pi and SESSION_HARNESS_STORE=1. Optional
#                   even then, same reason as RESUME_SESSION.
#   REFRESH_THRESHOLD_TOKENS
#                   set by fork-sandbox-k8s.sh's `submit` when the run
#                   refreshes itself (--refresh-at, claude only): the
#                   context-token count past which the inbox hook nudges a
#                   leg to write a hand-off. Unset or empty means no
#                   refresh: no .refresh-config, no continuation legs.
#   REFRESH_MAX     the most continuation legs one run may chain. Default
#                   6, the same default the local runner uses.
#   REFRESH_CEILING_TOKENS
#                   floor(0.8 * the model's context window), resolved
#                   alongside REFRESH_THRESHOLD_TOKENS. Fed to the inbox
#                   hook as CEILING_TOKENS, so each leg gets its own
#                   working budget from where IT started rather than
#                   always nudging at the same absolute threshold.
#   REFRESH_CONTEXT_WINDOW
#                   the context window (tokens) REFRESH_THRESHOLD_TOKENS was
#                   computed against. Only used to warn when a leg reports a
#                   different one (fs_refresh_window_mismatch).
#   PROVISION_TIMEOUT
#                   seconds to let an image-supplied provisioning
#                   executable (PROVISION_EXE) run before the whole run
#                   fails. Default 300. A provisioner that ignores the
#                   TERM sent at that bound gets a further 10s grace
#                   period (timeout -k) before a KILL finishes the job --
#                   so PROVISION_TIMEOUT is a hard bound either way, not
#                   just a request. Not rendered by submit, so this is a
#                   fixed default this round, not a k8s.env key.
#   PROVISION_EXE   test seam: overrides the fixed, documented path a
#                   derived image may carry provisioning at
#                   (/opt/fork-sandbox/provision -- see "Provisioning the
#                   clone from the image" in docs/kubernetes-runs.md). Real
#                   runs never set this; a test cannot write to /opt, so it
#                   points this at a fixture executable instead.
#   RUN_DIR         runner mode: the absolute path (inside this pod) of a
#                   run directory fork-sandbox-k8s.sh submit/run --run-dir
#                   staged and pushed, holding run.sh and pipeline.json --
#                   the SAME walker a local run's own run.sh executes, not
#                   a second copy (see scripts/fork-sandbox-runner.sh).
#                   When set, this script runs `bash "$RUN_DIR/run.sh"`
#                   instead of the HARNESS-gated coding leg and
#                   REVIEW_LOOP_CAP review loop below -- see the first arm
#                   of the pi_rc=0 block. HARNESS/MODEL carry no leg of
#                   their own in this mode (pipeline.json's own steps do);
#                   they still arrive as plain record values, forwarded
#                   unused except where this script reads pipeline.json
#                   directly (model discovery, claude credential install).
#                   Unset means today's legacy behaviour, unchanged.
#   FORK_SANDBOX_LEG_HANDOFF_DIR
#                   runner mode only: set when fork-sandbox-k8s.sh's pod
#                   spec runs this run's legs in a SEPARATE container (see
#                   "Composed pipelines on --k8s" in
#                   docs/kubernetes-runs.md) rather than in this one. When
#                   set, this script relays the pi-model-discovery and
#                   claude-credential setup it just did to that container
#                   (fork-sandbox-k8s-leg-loop.sh) via $RUN_DIR/.leg-setup,
#                   instead of that container redoing the same network
#                   calls itself. This script never execs a leg directly
#                   in this mode -- see fork-sandbox-runner.sh's
#                   fs_run_leg_split for the request/response protocol
#                   `bash "$RUN_DIR/run.sh"` uses instead once this is set.
#                   Unset means every leg still runs in this same
#                   container, exactly as before this existed.
#

# Reads from /mnt/fork-sandbox/ (the scripts ConfigMap, mounted read-only):
#   handoff.md              the run's whole prompt, on the coding harness's
#                           stdin.
#   refresh.sh, continuation-header.md, handoff-original.md
#                           only when REFRESH_THRESHOLD_TOKENS is set: the
#                           shared refresh logic (sourced), the continuation
#                           prompt's preamble, and the operator's own
#                           hand-off file, verbatim.
#   pi-agent-settings.json  optional; this repo's pi-agent/settings.json,
#                           the same file agent-sandboxed seeds a sealed
#                           local run's ~/.pi/agent from. Only the
#                           defaultProvider/defaultModel keys are generated
#                           fresh here; everything else in it survives.
#   claude-credentials.json, inbox-hook.sh
#                           present only when HARNESS=claude. The former is
#                           the operator's own credential with the access
#                           token replaced by a placeholder (the per-run
#                           proxy swaps in the real one); the latter is
#                           this repo's own operator-inbox hook, installed
#                           and registered exactly as a local claude run's
#                           --settings does.
#   review-prompt.md, fix-prompt-header.md, code-review-portable-skill.md,
#   review-loop.sh          present only when REVIEW_LOOP_CAP is set. The
#                           first two are the review and fix leg prompts,
#                           fully rendered on the HOST by
#                           fork-sandbox-k8s.sh (fs_emit_review_prompt_body /
#                           fs_emit_fix_prompt_body in fork-sandbox-lib.sh) --
#                           this script only composes prompt text of its own
#                           for one exception, the "coding session exited
#                           non-zero" note appended pod-side ahead of the
#                           review loop, since only this script knows the
#                           coding leg's exit code. review-loop.sh is the
#                           loop's own control flow; see its header for why
#                           it is a separate script.
#
# Creates /work/inbox: the operator inbox, written to from outside the pod
# by `fork-sandbox-k8s.sh say` over kubectl exec, and read by the agent per
# the preamble fs_emit_prompt_preamble renders into handoff.md. It is a
# sibling of clone_dir, never a descendant of it, so the `git add -A` this
# script runs at the bottom -- scoped to clone_dir, the repository it is run
# in -- can never sweep an addendum into a commit. /work/skills, created
# below when a review skill is shipped, is a sibling for the identical
# reason.
#
# Also creates /work/outbox: the artifact outbox, read back out of the pod
# by `fork-sandbox-k8s.sh run` over kubectl exec once the agent finishes.
# Same sibling-of-clone_dir reasoning as /work/inbox above.
#
# Provisioning: once the clone is checked out, run_image_provisioning runs
# PROVISION_EXE (real runs: the fixed path, see PROVISION_EXE above) when
# it exists and is executable, as this container's own user, with cwd set
# to the clone and FORK_SANDBOX_CLONE_DIR naming it. A non-zero exit or a
# PROVISION_TIMEOUT timeout fails the run before any leg. On success, every
# untracked path the run left behind is appended to .git/info/exclude (the
# same mechanism .env.sandbox above already uses), so it is never
# committed and never counts as uncommitted work; a TRACKED file the
# provisioner touched fails the run instead, naming the path -- silently
# committing an image's own edits into the agent's branch, with no author,
# is the worse outcome. The base image ships no such executable at all, so
# an unmodified install sees no change here whatsoever. See "Provisioning
# the clone from the image" in docs/kubernetes-runs.md for the full
# contract and the trust rationale (the image is the operator's own
# trust anchor; the repo, agent-editable, never chooses it or supplies
# code that runs outside the agent).

set -euo pipefail

: "${BRANCH:?BRANCH must be set to the branch the agent commits on}"
: "${HARNESS:=pi}"
case "$HARNESS" in
    pi|claude) ;;
    codex)
        # Only the composed runner has a Codex leg (and a Codex proxy).
        if [[ -z "${RUN_DIR:-}" ]]; then
            echo "Error: HARNESS=codex requires RUN_DIR (a composed run)." >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: HARNESS must be 'pi', 'claude' or 'codex', got '$HARNESS'." >&2
        exit 1
        ;;
esac
: "${MODEL:=}"
: "${MODEL_DISCOVERY:=}"
: "${ALLOW_UNLISTED_MODEL:=}"
: "${PI_ARGS:=}"
: "${PROXY_BASE_URL:?PROXY_BASE_URL must be set to the pi model proxy base URL}"
: "${RUN_DIR:=}"
if [[ -n "$RUN_DIR" ]]; then
    if [[ "$RUN_DIR" != /* ]]; then
        echo "Error: RUN_DIR must be an absolute path, got '$RUN_DIR'." >&2
        exit 1
    fi
    # pipeline.json (and so whether this run needs CLAUDE_PROXY_BASE_URL at
    # all) is not readable yet -- RUN_DIR's own emptyDir is mounted, but its
    # contents arrive with every other input, after the wait below. See the
    # RUN_DIR arm of the pi_rc=0 block for that check, deferred to there.
    true
elif [[ "$HARNESS" == claude ]]; then
    : "${CLAUDE_PROXY_BASE_URL:?CLAUDE_PROXY_BASE_URL must be set when HARNESS=claude}"
fi
: "${GIT_USER_NAME:=fork-sandbox agent}"
: "${GIT_USER_EMAIL:=agent@fork-sandbox.invalid}"
: "${INPUTS_TIMEOUT:=300}"
: "${RUN_TTL:=3600}"
: "${REVIEW_LOOP_CAP:=0}"
: "${REVIEW_MODEL:=}"
: "${OUTBOX_MAX_BYTES:=67108864}"  # must match FS_OUTBOX_MAX_BYTES in fork-sandbox-lib.sh
: "${SESSION_HARNESS_STORE:=}"
: "${RESUME_SESSION:=}"
: "${SESSION_ID:=}"
: "${REFRESH_THRESHOLD_TOKENS:=}"
: "${REFRESH_MAX:=6}"
: "${REFRESH_CEILING_TOKENS:=}"
: "${REFRESH_CONTEXT_WINDOW:=}"
: "${PROVISION_TIMEOUT:=300}"
: "${PROVISION_EXE:=/opt/fork-sandbox/provision}"
if [[ "$REVIEW_LOOP_CAP" =~ ^[1-9][0-9]*$ ]]; then
    : "${BASE_SHA:?BASE_SHA must be set when REVIEW_LOOP_CAP is set}"
    if [[ "$HARNESS" == claude && -z "$REVIEW_MODEL" ]]; then
        echo "Error: REVIEW_MODEL must be set when HARNESS=claude and" >&2
        echo "REVIEW_LOOP_CAP is set -- the review loop always runs pi, and" >&2
        echo "MODEL is a Claude Code model name pi cannot use." >&2
        exit 1
    fi
elif [[ "$REVIEW_LOOP_CAP" != "0" ]]; then
    echo "Error: REVIEW_LOOP_CAP must be a non-negative integer, got '$REVIEW_LOOP_CAP'." >&2
    exit 1
fi

# Model discovery against the proxy, run once, early, BEFORE the
# repository-receive wait and AFTER the bare repository's git init --
# see the call site below for why each half of that ordering holds. A
# dead endpoint must fail in seconds with a clear message, not after the
# whole submit dance, but the host's repository push can land the moment
# this container starts, so /work/repo.git must already exist when it
# does. It doubles as the health check docs/kubernetes-runs.md's
# "direct" section records as a requirement -- satisfied here for the
# proxy path, where the endpoint is reachable only through the proxy's
# /e/<name>/v1/models location. curl and jq are both in the image (the
# review loop already uses curl); the function is self-contained so the
# test suite can exercise it by stubbing curl on PATH. Sets MODEL (when
# unset), CTX and MAX_TOKENS for the coding leg's model, and, when
# REVIEW_MODEL differs from MODEL, REVIEW_CTX and REVIEW_MAX_TOKENS for
# the review loop's model -- synthesize_pi_config below reads them.
# Run ONLY when the host set MODEL_DISCOVERY (a K8S_PROXY_ENDPOINTS
# install in which this run uses the pi proxy): on a legacy
# K8S_PROXY_UPSTREAM install the proxy's render forwards only
# /api/v1/chat/completions, so /api/v1/models would 403 and discovery
# would die every legacy run at pod start, and a --harness claude run
# with no review loop never talks to this proxy at all, so it must not
# die at pod start when the endpoint is down. The no-discovery branch
# keeps the constants synthesize_pi_config used before discovery
# existed.
discover_model_facts() {
    local url="$PROXY_BASE_URL/models" body probe_ids count curl_rc=0 fetch_note=""
    # A catalog that cannot be fetched or parsed does NOT die here: it
    # dies -- or warns -- at the single point where the context that
    # would have come from it gets guessed, in _model_context_facts
    # below. That is what makes every path to the guess one refusal.
    body="$(curl -sS --max-time 20 "$url" 2>&1)" || curl_rc=$?
    if (( curl_rc != 0 )); then
        fetch_note="$body"
        body=""
        probe_ids=""
    else
        probe_ids="$(jq -r '.data[].id' <<<"$body" 2>/dev/null || true)"
        if [[ -z "$probe_ids" ]]; then
            fetch_note="it answered with no model list: ${body:0:400}"
        fi
    fi
    if [[ -z "$MODEL" ]]; then
        if [[ -z "$probe_ids" ]]; then
            # No model can be resolved at all -- nothing to guess a
            # window for, so this one is a hard error either way.
            echo "Error: model discovery failed -- $url:" >&2
            printf '%s\n' "$fetch_note" >&2
            echo "A connection refusal here is an expected, ordinary state, not" >&2
            echo "a bug to chase: the endpoint is often a workstation-class" >&2
            echo "host, and this simply means it is not running right now." >&2
            echo "Start the endpoint and resubmit the run." >&2
            exit 1
        fi
        count="$(printf '%s\n' "$probe_ids" | wc -l)"
        if (( count > 1 )); then
            echo "Error: the endpoint serves more than one model, so one" >&2
            echo "has to be named. Resubmit with --model. It offers:" >&2
            printf '%s\n' "$probe_ids" | sed 's/^/  /' >&2
            exit 1
        fi
        MODEL="$probe_ids"
        echo "fork-sandbox-k8s-entrypoint: no --model given; the endpoint" >&2
        echo "serves exactly one model, so using $MODEL." >&2
    fi

    # The listing's canonical spelling for a case-variant id, or empty:
    # the gateway's own lookup is case-insensitive, but /v1/models reports
    # the canonical spelling, so a correctly-working, case-variant
    # configured id must not compare unequal -- and once it matches, the
    # LISTING's spelling is what the run and its record carry. The exact
    # jq lookup in _model_context_facts below needs this match to find
    # the entry at all.
    _listing_spelling() {
        local id
        while IFS= read -r id; do
            if [[ -n "$id" && "${id,,}" == "${1,,}" ]]; then
                printf '%s\n' "$id"
                return 0
            fi
        done <<< "$probe_ids"
        return 0
    }

    # (HARNESS=claude: MODEL is a Claude Code name this listing never
    # contains and no pi leg uses, so it is never checked or normalized
    # here.)
    if [[ "$HARNESS" != claude && -n "$MODEL" ]]; then
        local listed_id
        listed_id="$(_listing_spelling "$MODEL")"
        if [[ -n "$listed_id" && "$listed_id" != "$MODEL" ]]; then
            echo "fork-sandbox-k8s-entrypoint: the listing spells the model" >&2
            echo "'$listed_id', not the configured '$MODEL'; the gateway's" >&2
            echo "lookup is case-insensitive, so the run uses the listing's" >&2
            echo "spelling." >&2
            MODEL="$listed_id"
        fi
    fi

    # The context window, from the endpoint when it says so: too large and
    # the agent packs a request the server rejects, with the failure
    # arriving mid-run -- agent-sandboxed's rationale, applied verbatim.
    # The /props fallback agent-sandboxed tries for llama.cpp is
    # deliberately NOT probed here: the proxy forwards only the two paths
    # /chat/completions and /models, so /props would 403.
    #
    # One window PER MODEL ID, looked up separately for the coding leg's
    # model and the review loop's model: on a --harness claude run MODEL
    # is a Claude Code model name this listing never contains, and letting
    # its (absent) value stand in for REVIEW_MODEL's window would give the
    # review loop a quarter of the context it used to have. The helper is
    # nested in this function, not top-level, because the test suite
    # extracts exactly this function's source and runs it alone. Sets the
    # globals FACTS_CTX / FACTS_MAX / FACTS_SRC (reported or guessed, the
    # source of FACTS_CTX) for the id in $1.
    #
    # The refusal this design pivots on lives HERE, the single point a
    # guessed value would be returned: every path to the guess -- the id
    # is absent from a successfully fetched listing, the catalog fetch
    # itself failed, timed out or came back unparseable, or the entry was
    # found but carries no usable max_model_len -- funnels into this one
    # check, so a future fourth path to the guess fails closed by
    # construction. Refusing at pod start costs one launch; proceeding on
    # the guess lets a window that is four times off stand silently for
    # the real one, and that is what the renamed-catalog-entry incident
    # did to a whole round. The guess is still the right guess when the
    # endpoint simply reports no max_model_len -- but it must be named a
    # guess, and it proceeds only when ALLOW_UNLISTED_MODEL=1 (the host's
    # K8S_ALLOW_UNLISTED_MODEL in k8s.env) permits a launch whose context
    # had to be guessed.
    _model_context_facts() {
        local model="$1" len why kind
        FACTS_SRC=reported
        len="$(jq -r --arg m "$model" \
            'first(.data[] | select(.id == $m) | .max_model_len // empty) // empty' \
            <<<"$body" 2>/dev/null || true)"
        if [[ ! "$len" =~ ^[0-9]+$ ]]; then
            # Guess low: too small wastes context, while too large means a
            # rejection that arrives mid-run with the work half done.
            len=32768
            FACTS_SRC=guessed
            if [[ -z "$probe_ids" ]]; then
                kind=catalog
                why="the endpoint's model catalog could not be read ($url: $fetch_note)"
            elif ! printf '%s\n' "$probe_ids" | grep -qxF "$model"; then
                kind=unlisted
                why="the endpoint's listing does not contain that id"
            else
                kind=nolen
                why="its entry in the listing carries no usable max_model_len"
            fi
            if [[ "$ALLOW_UNLISTED_MODEL" == 1 ]]; then
                echo "Warning: the context length for '$model' is a GUESS of" >&2
                echo "$len tokens -- $why. Continuing because" >&2
                echo "ALLOW_UNLISTED_MODEL=1 permits a launch whose context" >&2
                echo "had to be guessed." >&2
                if [[ "$kind" == unlisted ]]; then
                    echo "The endpoint does not list that id; it offers:" >&2
                    printf '%s\n' "$probe_ids" | sed 's/^/  /' >&2
                fi
            else
                echo "Error: the context length for '$model' had to be" >&2
                echo "guessed: $why." >&2
                case "$kind" in
                    catalog)
                        echo "An unreachable or unhelpful endpoint is the" >&2
                        echo "expected, ordinary state here, not a bug to" >&2
                        echo "chase: the endpoint is often a workstation-class" >&2
                        echo "host, and this simply means it is not running" >&2
                        echo "right now. Start the endpoint and resubmit the" >&2
                        echo "run." >&2
                        ;;
                    unlisted)
                        echo "The endpoint offers:" >&2
                        printf '%s\n' "$probe_ids" | sed 's/^/  /' >&2
                        echo "A renamed or removed catalog entry is the usual" >&2
                        echo "cause: the configured id was right when written and" >&2
                        echo "the endpoint's catalog changed since (a case-only" >&2
                        echo "difference is not a miss -- the comparison above" >&2
                        echo "is case-insensitive). Fix the id -- most often" >&2
                        echo "K8S_DEFAULT_MODEL in k8s.env, the value submit fell" >&2
                        echo "back to when --model was omitted -- and resubmit. If" >&2
                        echo "the id is known good and the listing is stale," >&2
                        echo "K8S_ALLOW_UNLISTED_MODEL=1 in k8s.env permits a" >&2
                        echo "launch whose context had to be guessed." >&2
                        ;;
                    *)
                        echo "K8S_ALLOW_UNLISTED_MODEL=1 in k8s.env permits a" >&2
                        echo "launch whose context had to be guessed." >&2
                        ;;
                esac
                exit 1
            fi
        fi
        FACTS_CTX="$len"
        # MAX_TOKENS from CTX, the same rule agent-sandboxed applies: a
        # 32768 floor, capped at a quarter of the window.
        FACTS_MAX=32768
        if (( len / 4 < FACTS_MAX )); then
            FACTS_MAX=$(( len / 4 ))
        fi
    }
    if [[ "$HARNESS" == claude ]]; then
        # MODEL is a Claude Code model name: no pi leg of this run uses
        # it (the coding leg runs claude against CLAUDE_PROXY_BASE_URL,
        # the review loop runs REVIEW_MODEL), so it gets no per-model
        # lookup -- one would only print warnings about a name this
        # listing never contains. The values below stand in and are
        # never consumed: a claude run synthesizes pi config only for
        # the review model, whose window is looked up for its own id.
        CTX=32768
        MAX_TOKENS=8192
    else
        _model_context_facts "$MODEL"
        CTX="$FACTS_CTX"
        MAX_TOKENS="$FACTS_MAX"
        # MODEL's own facts, recorded in .fork-sandbox-model below
        # alongside MODEL's id -- only when they belong to that id (a
        # claude run's stand-in values do not).
        MODEL_CTX_SOURCE="$FACTS_SRC"
    fi
    if [[ -n "$REVIEW_MODEL" && "$REVIEW_MODEL" != "$MODEL" ]]; then
        # The same case-insensitive listing match as MODEL above, so a
        # case-variant --review-model is not a silent miss into the
        # guess either.
        local review_canonical
        review_canonical="$(_listing_spelling "$REVIEW_MODEL")"
        if [[ -n "$review_canonical" && "$review_canonical" != "$REVIEW_MODEL" ]]; then
            echo "fork-sandbox-k8s-entrypoint: the listing spells the review" >&2
            echo "model '$review_canonical', not the configured '$REVIEW_MODEL';" >&2
            echo "using the listing's spelling." >&2
            REVIEW_MODEL="$review_canonical"
        fi
        _model_context_facts "$REVIEW_MODEL"
        REVIEW_CTX="$FACTS_CTX"
        REVIEW_MAX_TOKENS="$FACTS_MAX"
    else
        # No separate review model (or the same one) -- the review loop
        # falls back to MODEL and gets MODEL's window with it.
        REVIEW_CTX="$CTX"
        REVIEW_MAX_TOKENS="$MAX_TOKENS"
    fi
    if [[ "$HARNESS" == claude ]]; then
        # REVIEW_MODEL is non-empty here (required at startup for a
        # claude coding leg with a loop). The summary names the review
        # model, which is the id this run actually uses through this
        # proxy -- not the coding leg's Claude Code name.
        echo "fork-sandbox-k8s-entrypoint: review model $REVIEW_MODEL at $PROXY_BASE_URL" >&2
        echo "(${REVIEW_CTX} token context, ${REVIEW_MAX_TOKENS} token reply room)" >&2
    else
        echo "fork-sandbox-k8s-entrypoint: model $MODEL at $PROXY_BASE_URL" >&2
        echo "(${CTX} token context, $MAX_TOKENS token reply room)" >&2
    fi
}

mounts_dir=/mnt/fork-sandbox
# shellcheck disable=SC1091  # generated ConfigMap key, not a source file
source "$mounts_dir/browser.sh"

# fork-sandbox-lib.sh, shipped in only for --harness claude (see
# render_claude_configmap_keys in fork-sandbox-k8s.sh): sourced here, before
# anything else, so fs_leg_error_retryable and fs_harness_error -- both used
# by the claude coding leg's retry wrapper below -- are the exact same
# functions fork-sandbox-runner.sh uses, never a second copy that could
# drift. Gated on HARNESS, not on the file's own
# existence: cmd_submit already refuses to render this pod's ConfigMap at
# all when fork-sandbox-lib.sh is unreadable on the host (see its own
# `[[ -r "$lib_sh" ]]` check), so a --harness claude pod that reaches this
# line and still finds no lib.sh has a broken ConfigMap mount -- a bug worth
# a loud, unguarded `source` failure under `set -e`, the same way the
# claude-credentials.json install and inbox-hook.sh install just below
# fail loudly rather than silently skipping. A pi run never reaches this at
# all, since it never calls either function.
if [[ "$HARNESS" == claude ]]; then
    # shellcheck source=/dev/null
    source "$mounts_dir/lib.sh"
fi

work_dir=/work
repo_bare="$work_dir/repo.git"
clone_dir="$work_dir/clone"
# Literal path, not a shared constant: this script and fork-sandbox-k8s.sh
# (where the host-side push/pull lives) have no constants file between
# them, so both sides simply agree on /work/session-store by convention.
session_store_dir="$work_dir/session-store"
inbox_dir="$work_dir/inbox"
outbox_dir="$work_dir/outbox"
skill_dir="$work_dir/skills/code-review-portable"
sentinel="$work_dir/.inputs-complete"
fetched_marker="$work_dir/.fetched"
run_complete="$work_dir/.run-complete"

if [[ -z "$RUN_DIR" ]]; then
    echo "fork-sandbox-k8s-entrypoint: creating $inbox_dir" >&2
    mkdir -p "$inbox_dir"
fi
# else: runner mode's inbox is staged by the launcher under RUN_DIR and
# arrives with the rest of the run directory -- linked at this fixed path
# once that push lands, below. Created here it would make RUN_DIR
# non-empty before the push, which the pod-side extractor refuses.
echo "fork-sandbox-k8s-entrypoint: creating $outbox_dir" >&2
mkdir -p "$outbox_dir"

# The review skill, staged only when this run carries one. A ConfigMap key
# cannot contain '/', so the skill arrives flattened at
# code-review-portable-skill.md and is placed here at the path the review
# prompt (rendered on the host, see fs_emit_review_prompt_body) names it at.
# /work/skills is a SIBLING of clone_dir, never a descendant of it -- the
# same structural reason /work/inbox above is a sibling -- so the
# `git add -A` this script runs at the bottom, scoped to clone_dir, can
# never sweep it into a commit.
if [[ -f "$mounts_dir/code-review-portable-skill.md" ]]; then
    echo "fork-sandbox-k8s-entrypoint: staging the review skill at $skill_dir" >&2
    mkdir -p "$skill_dir"
    cp "$mounts_dir/code-review-portable-skill.md" "$skill_dir/SKILL.md"
fi

echo "fork-sandbox-k8s-entrypoint: initializing $repo_bare" >&2
git init --quiet --bare "$repo_bare"

# Model discovery, deliberately placed AFTER the bare repository above
# and BEFORE the repository-receive wait below. The ordering is
# load-bearing in both directions: the agent container has no
# readinessProbe, so the host's repository push can land the moment this
# container starts -- a discovery that preceded `git init --bare` would
# race that push against a nonexistent /work/repo.git and fail a healthy
# run -- while a dead endpoint must still fail in seconds, well before
# the INPUTS_TIMEOUT deadline below, not after the whole submit dance.
if [[ -n "$RUN_DIR" ]]; then
    # A runner-mode pod carries no single MODEL to discover against --
    # every pipeline.json step and fix seat names its own, and distinct pi
    # ids get their own per-id lookup, pod-side, once RUN_DIR's contents
    # arrive and pipeline.json can actually be read (see the RUN_DIR arm
    # of the pi_rc=0 block, discover_pipeline_pi_facts). These globals are
    # never consumed in that path.
    CTX=0; MAX_TOKENS=0; REVIEW_CTX=0; REVIEW_MAX_TOKENS=0; MODEL_CTX_SOURCE=""
elif [[ -n "$MODEL_DISCOVERY" ]]; then
    discover_model_facts
else
    # No discovery: either a legacy K8S_PROXY_UPSTREAM install (whose
    # proxy forwards only /api/v1/chat/completions), or a --harness
    # claude run with no review loop on a K8S_PROXY_ENDPOINTS install
    # (no pi leg of that run talks to the proxy). In both cases MODEL
    # is set -- the host requires --model for either -- so the
    # pre-discovery constants stand in for the window
    # synthesize_pi_config's models.json entries carry (unused on a
    # claude run, which synthesizes pi config only for the review
    # model).
    if [[ -z "$MODEL" ]]; then
        echo "Error: MODEL must be set on a legacy K8S_PROXY_UPSTREAM" >&2
        echo "install -- there is no /v1/models location to discover it" >&2
        echo "from (that proxy forwards only /api/v1/chat/completions)." >&2
        exit 1
    fi
    CTX=131072
    MAX_TOKENS=32768
    REVIEW_CTX=131072
    REVIEW_MAX_TOKENS=32768
    # No discovery ran, so MODEL's context facts are not recorded: the
    # constants above are what the pre-discovery config used, not facts
    # the endpoint reported.
    MODEL_CTX_SOURCE=""
fi

# Harness metadata, not a reply: collect pulls this dotfile back with the
# outbox so cluster harvests can stamp replies from a discovered model.
# The outbox is seat-writable, so a seat could forge this value. That is
# ACCEPTED, deliberately: the stamp is bookkeeping on content the seat
# authors wholesale, for models this operator configured -- protecting it
# would mean a second container and a read-only volume in every cluster
# pod, real lifecycle complexity for a non-threat. Do not "harden" this
# without reopening that decision.
if [[ -n "$MODEL" ]]; then
    # Line 1 stays the bare model id, exactly as before: any existing
    # reader of the file keeps working unchanged. The context facts an
    # entrypoint that ran model discovery established for THAT id append
    # as key=value lines (absent on legacy-install and claude-harness
    # runs, where the values are stand-in constants, not facts).
    #
    # Why record them at all: max_tokens = min(32768, context/4), so
    # 32768 is BOTH the correct reply room on a healthy 131072 window
    # AND the broken fallback context -- a reader grepping for 32768
    # cannot tell the two apart. context=32768 with max_tokens=8192 is
    # the unambiguous signature of the fallback.
    {
        printf '%s\n' "$MODEL"
        if [[ -n "${MODEL_CTX_SOURCE:-}" ]]; then
            printf 'context=%s\nmax_tokens=%s\ncontext_source=%s\n' \
                "$CTX" "$MAX_TOKENS" "$MODEL_CTX_SOURCE"
        fi
    } > "$outbox_dir/.fork-sandbox-model"
fi

echo "fork-sandbox-k8s-entrypoint: waiting for $sentinel (deadline ${INPUTS_TIMEOUT}s)" >&2
deadline=$(( $(date +%s) + INPUTS_TIMEOUT ))
until [[ -f "$sentinel" ]]; do
    if (( $(date +%s) >= deadline )); then
        echo "Error: timed out waiting for the repository to arrive -- no" >&2
        echo "$sentinel after ${INPUTS_TIMEOUT}s. A client that died mid-push" >&2
        echo "must not become an agent running with its inputs missing, so" >&2
        echo "this run fails closed instead of proceeding on a partial repo." >&2
        exit 1
    fi
    sleep 1
done

if [[ -n "$RUN_DIR" ]]; then
    # The push that just arrived (RUN_DIR's own emptyDir had to stay empty
    # until now, see the mkdir this skipped above) already carries
    # RUN_DIR/inbox, staged and populated by the launcher exactly as a
    # local run's own inbox is. Link the fixed /work/inbox path to it so
    # `say` and every other verb that reaches into a running pod at
    # POD_INBOX_DIR keeps working unchanged.
    if [[ ! -d "$RUN_DIR/inbox" ]]; then
        echo "Error: RUN_DIR is set but $RUN_DIR/inbox is missing after the" >&2
        echo "push. The launcher should have staged it; check the run" >&2
        echo "directory it built." >&2
        exit 1
    fi
    ln -s "$RUN_DIR/inbox" "$inbox_dir"
fi

# Only refs/heads/$BRANCH (and any --extra-ref branches, see EXTRA_REFS) was
# ever pushed into this bare repo (cmd_submit pushes "HEAD:refs/heads/$branch"
# plus one refspec per extra ref), so the bare repo's default
# HEAD (refs/heads/main or master, set by git init --bare) dangles. Left
# alone, the clone below would print "warning: remote HEAD refers to
# nonexistent ref, unable to checkout" and check out nothing. Point HEAD at
# the branch that actually exists before cloning, so the clone lands
# directly on it.
git --git-dir="$repo_bare" symbolic-ref HEAD "refs/heads/$BRANCH"

# In the composed (RUN_DIR) pod shape, clone_dir is its OWN dedicated
# emptyDir volume (see "A leg cannot write the runner's own state" in
# docs/kubernetes-runs.md), not a subdirectory this container creates
# itself -- so its mount ROOT already exists, owned by whatever created
# the volume (the kubelet, as root) and group-owned by the pod's fsGroup,
# which is enough for this uid to WRITE into it but not enough to make
# this uid its OWNER. git's ownership check (the CVE-2022-24765 fix)
# refuses to operate in a directory it does not consider safely owned --
# "fatal: detected dubious ownership", confirmed on a real cluster at
# exactly this line. repo_bare needs no such exemption in the composed
# shape (it is a fresh subdirectory THIS container creates under the
# shared "work" volume, so it is always owned by this uid already), but
# exempting it here too costs nothing and keeps this script correct even
# if a future platform or volume layout changes that assumption.
#
# This trusts nothing about what either directory CONTAINS -- hooks,
# filters and attributes still apply exactly as before -- it only tells
# git that THIS uid, which the pod's securityContext already fixes for
# the whole container, may treat this ownership as expected, the same
# no-op the error message's own suggested command performs. --global, not
# --system: $HOME here is a per-container emptyDir no other pod or run
# ever shares.
git config --global --add safe.directory "$repo_bare"
git config --global --add safe.directory "$clone_dir"

echo "fork-sandbox-k8s-entrypoint: cloning to $clone_dir" >&2
git clone --quiet "$repo_bare" "$clone_dir"
cd "$clone_dir"
# The clone above already checked out $BRANCH as a local branch (HEAD now
# points there), so this only needs to switch onto it, not create it.
git checkout --quiet "$BRANCH"

# Extra refs (submit --extra-ref NAME=SHA): a LOCAL branch per name at
# origin/NAME, so an agent can `git checkout NAME` or reset onto it without
# knowing about remotes. Created, never checked out -- BRANCH stays the
# checked-out branch -- and the sha is verified against what submit said it
# pushed, so a ref that arrived as something else fails the run here rather
# than being read as the commit the caller meant. The end-of-leg fetch-back
# is unchanged: only BRANCH comes home.
for extra_ref in ${EXTRA_REFS:-}; do
    extra_ref_name="${extra_ref%%=*}"
    extra_ref_sha="${extra_ref#*=}"
    if [[ ! "$extra_ref_name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
        || [[ ! "$extra_ref_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
        || [[ "$extra_ref_name" == "$BRANCH" ]]; then
        echo "Error: malformed EXTRA_REFS entry '$extra_ref'." >&2
        exit 1
    fi
    git branch "$extra_ref_name" "origin/$extra_ref_name"
    if [[ "$(git rev-parse "refs/heads/$extra_ref_name")" != "$extra_ref_sha" ]]; then
        echo "Error: extra ref '$extra_ref_name' is not at $extra_ref_sha in the pod." >&2
        exit 1
    fi
    echo "fork-sandbox-k8s-entrypoint: local branch $extra_ref_name at $extra_ref_sha" >&2
done

# Per-run services' sandboxEnv, staged only when the submitted services
# spec carried one -- see render_services_env_configmap_key in
# fork-sandbox-k8s.sh. Same filename the local sandbox-services path
# writes, so a repo reads one file either way.
if [[ -f "$mounts_dir/sandbox-env" ]]; then
    if git ls-files --error-unmatch -- .env.sandbox >/dev/null 2>&1; then
        echo "Error: .env.sandbox is tracked in the submitted repository;" >&2
        echo "refusing to overwrite it with generated sandboxEnv content." >&2
        exit 1
    fi
    echo "fork-sandbox-k8s-entrypoint: writing $clone_dir/.env.sandbox" >&2
    cp "$mounts_dir/sandbox-env" "$clone_dir/.env.sandbox"
    # Keep the generated connection file clone-local so the end-of-leg
    # git add -A safety net never sweeps it into the repo's source commits.
    if ! grep -qxF '.env.sandbox' "$clone_dir/.git/info/exclude"; then
        printf '%s\n' '.env.sandbox' >> "$clone_dir/.git/info/exclude"
    fi
fi
git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
git config commit.gpgsign false
git config tag.gpgsign false

# After the provisioner exits 0, finds every path `git status --porcelain
# -z --untracked-files=normal` reports as untracked (??) and appends it to
# .git/info/exclude, anchored, guarded against a duplicate line exactly as
# .env.sandbox's own exclude entry above -- so a link or file provisioning
# created is never committed and never counts as uncommitted work. Any
# entry that is NOT untracked (the provisioner modified or deleted a
# TRACKED file) fails the run naming the paths: exclusion cannot hide
# that, and committing an image's own edits into the agent's branch, with
# no author, would be the worse outcome. An untracked path containing a
# gitignore metacharacter (anything outside [A-Za-z0-9._/-]) also fails the
# run, naming the path, rather than writing an exclude line that means
# something other than "this exact path".
run_image_provisioning_exclude() {
    local entry xy path
    local -a untracked=() tracked_changed=()
    while IFS= read -r -d '' entry; do
        [[ -z "$entry" ]] && continue
        xy="${entry:0:2}"
        path="${entry:3}"
        if [[ "$xy" == *R* ]]; then
            # A rename carries the old path as a second NUL-terminated
            # field -- consume it so the next read() stays aligned. Only
            # reachable for a TRACKED change (a rename never applies to an
            # untracked path), which already fails the run below.
            read -r -d '' _ || true
        fi
        if [[ "$xy" == "??" ]]; then
            untracked+=("$path")
        else
            tracked_changed+=("$path")
        fi
    done < <(git status --porcelain -z --untracked-files=normal)

    if (( ${#tracked_changed[@]} > 0 )); then
        echo "Error: fork-sandbox-k8s-entrypoint: provisioning modified or" >&2
        echo "deleted a tracked file -- refusing to let it ride into the" >&2
        echo "agent's own branch:" >&2
        printf '  %s\n' "${tracked_changed[@]}" >&2
        exit 1
    fi

    local -a bad=()
    for path in "${untracked[@]}"; do
        [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || bad+=("$path")
    done
    if (( ${#bad[@]} > 0 )); then
        echo "Error: fork-sandbox-k8s-entrypoint: provisioning created a path" >&2
        echo "with a character an exclude-file entry cannot safely name:" >&2
        printf '  %s\n' "${bad[@]}" >&2
        exit 1
    fi

    for path in "${untracked[@]}"; do
        if ! grep -qxF "/$path" .git/info/exclude 2>/dev/null; then
            printf '/%s\n' "$path" >> .git/info/exclude
        fi
    done
}

# Runs an image-supplied provisioning executable, if the image carries one
# -- see "Provisioning the clone from the image" in
# docs/kubernetes-runs.md for the full contract. Absent (the base image's
# own state, and PROVISION_EXE's default never exists there): returns 0
# with no log, no exclude edit and no output at all, so an unmodified
# install sees no change here whatsoever. Present but not executable
# (including a dangling symlink) is an operator build mistake, not "no
# provisioner" -- failing loudly here beats
# a silent no-op that only surfaces later as a confusing failure deep in the
# agent's own leg, with no `.venv` or seed links and nothing in the pod log
# saying why. Present and executable: narrates, runs it once with cwd set to
# the clone and FORK_SANDBOX_CLONE_DIR naming it, captures its combined
# output to $work_dir/provision.log, and on a non-zero exit (timeout
# included -- 124 or 137, see below) prints the last 40 lines of that
# log, prefixed, followed by the verdict, and fails the run before any leg --
# no .run-complete, no harness call. The verdict is printed AFTER the tail,
# not before: `wait` and the postmaster's wake record each keep only the
# last 40 lines of this same stream, and a provisioner that itself logs 40+
# lines would otherwise push the one line saying why the run failed out of
# every window that later reads it. On success, hands off to
# run_image_provisioning_exclude above.
run_image_provisioning() {
    [[ -e "$PROVISION_EXE" || -L "$PROVISION_EXE" ]] || return 0
    if [[ ! -x "$PROVISION_EXE" ]]; then
        echo "Error: fork-sandbox-k8s-entrypoint: provisioning executable" >&2
        echo "$PROVISION_EXE exists but is not executable (or is a dangling symlink)." >&2
        exit 1
    fi
    echo "fork-sandbox-k8s-entrypoint: provisioning with $PROVISION_EXE" >&2
    local provision_log="$work_dir/provision.log" provision_rc=0
    # Not `if ! cmd; then rc=$?`: under the negation, $? inside the then
    # branch is the status of `! cmd` itself (always 0 or 1), never cmd's
    # real exit code -- a classic bash trap that would always read a
    # timeout back as "exited 1". `cmd && rc=0 || rc=$?` keeps the real
    # code, and the whole line still exits 0 so `set -e` never fires on a
    # failing provisioner.
    # -k/--kill-after: plain `timeout N cmd` only sends TERM at N and then
    # waits however long the command keeps running -- a provisioner that
    # traps or ignores TERM would never actually be bounded by
    # PROVISION_TIMEOUT. The extra 10s grace period gives a well-behaved
    # provisioner a chance to clean up on TERM before KILL lands.
    (cd "$clone_dir" \
        && FORK_SANDBOX_CLONE_DIR="$clone_dir" \
        timeout -k 10 "$PROVISION_TIMEOUT" "$PROVISION_EXE") \
        > "$provision_log" 2>&1 && provision_rc=0 || provision_rc=$?
    if (( provision_rc != 0 )); then
        echo "fork-sandbox-k8s-entrypoint: provision: last 40 lines of its output:" >&2
        tail -n 40 -- "$provision_log" | sed 's/^/fork-sandbox-k8s-entrypoint: provision: /' >&2
        if (( provision_rc == 124 || provision_rc == 137 )); then
            # 124: timeout's own TERM killed it within the grace period.
            # 137 (128+SIGKILL): the provisioner ignored TERM and the -k
            # grace period's KILL finished the job instead -- still a
            # timeout, not an ordinary exit code.
            echo "Error: fork-sandbox-k8s-entrypoint: provision timed out after" >&2
            echo "${PROVISION_TIMEOUT}s (exit $provision_rc; a provisioner that itself" >&2
            echo "exits 124 or 137 reads the same way)." >&2
        else
            echo "Error: fork-sandbox-k8s-entrypoint: provision exited $provision_rc." >&2
        fi
        exit 1
    fi
    run_image_provisioning_exclude
}
run_image_provisioning

# Builds ~/.pi/agent/models.json + settings.json pointed at the pi proxy,
# for one primary model id and, optionally, a second (REVIEW_MODEL) --
# both land in models.json so pi can resolve either by --model, while
# defaultModel/defaultProvider still point at the primary one. Used for
# the pi harness's own coding leg below (both ids, up front), and again
# with just the review model right before the review loop when the
# coding leg ran claude instead, which never synthesized any config at
# all -- see that block for why a second call is needed there. baseUrl is
# the proxy Service, not a loopback bridge -- there is no socket bridge
# here, because network policy rather than a unix socket is what seals
# this pod. apiKey is a placeholder; the proxy replaces the header on the
# way past, so this value is never sent anywhere that checks it.
# contextWindow/maxTokens are the values discover_model_facts established
# from the endpoint's own /v1/models (or its documented fallbacks), one
# pair PER ID: $3/$4 for $model, $5/$6 for $extra_model -- on a
# --harness claude run $model is the review loop's REVIEW_MODEL and the
# coding leg's Claude Code model name never lands in models.json at all.
# A legacy K8S_PROXY_UPSTREAM install passes the pre-discovery constants
# instead (see the MODEL_DISCOVERY branch above).
synthesize_pi_config() {
    local model="$1"
    local extra_model="${2:-}"
    local ctx="$3" maxtok="$4" extra_ctx="${5:-$3}" extra_maxtok="${6:-$4}"
    echo "fork-sandbox-k8s-entrypoint: synthesizing pi config for $model" >&2
    mkdir -p "$HOME/.pi/agent"
    if [[ -f "$mounts_dir/pi-agent-settings.json" ]]; then
        cp "$mounts_dir/pi-agent-settings.json" "$HOME/.pi/agent/settings.json"
    fi

    jq -n --arg base "$PROXY_BASE_URL" --arg model "$model" --arg extra "$extra_model" \
        --argjson ctx "$ctx" --argjson maxtok "$maxtok" \
        --argjson extra_ctx "$extra_ctx" --argjson extra_maxtok "$extra_maxtok" '
        {
            providers: {
                proxy: {
                    baseUrl: $base,
                    api: "openai-completions",
                    apiKey: "sandbox",
                    models: ([$model, $extra] | map(select(. != "")) | unique | map(
                        . as $id | {
                            id: $id,
                            name: ($id + " (proxy)"),
                            reasoning: true,
                            input: ["text"],
                            contextWindow: (if $id == $model then $ctx else $extra_ctx end),
                            maxTokens: (if $id == $model then $maxtok else $extra_maxtok end),
                            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                        }
                    )),
                },
            },
        }' > "$HOME/.pi/agent/models.json"

    local settings_base='{}'
    if [[ -f "$HOME/.pi/agent/settings.json" ]]; then
        settings_base="$(cat "$HOME/.pi/agent/settings.json")"
    fi
    if ! jq -n --argjson base "$settings_base" --arg model "$model" \
        '$base * { defaultProvider: "proxy", defaultModel: $model }' \
        > "$HOME/.pi/agent/settings.json.new"; then
        echo "Error: pi-agent/settings.json is not valid JSON, so the generated" >&2
        echo "model defaults cannot be merged into it." >&2
        exit 1
    fi
    mv "$HOME/.pi/agent/settings.json.new" "$HOME/.pi/agent/settings.json"
}

# The pi coding leg's own invocation. The argv is built from MODEL and
# PI_ARGS: PI_ARGS is split on whitespace and appended as an array --
# splitting, never evaluation (no eval, no interpolation into a shell
# string), and submit already refused a single quote or newline in the
# value (fs_reject_unsafe_chars), plus a double quote or backslash
# because the rendered Job carries it as a double-quoted YAML scalar,
# before any Job, Secret or proxy Pod existed.
# An unset or empty PI_ARGS appends nothing: an empty string argument
# would be a positional pi rejects.
run_pi_coding_leg() {
    local -a pi_argv=(pi --provider proxy --model "$MODEL" --mode json -p)
    local -a pi_extra_argv=()
    # The durable session store, coding leg only -- matches the local
    # sandbox's own gate (only the coding/continuation leg binds
    # --session-state; review, fix and maintainer legs never do), so a pi
    # seat resumes the same conversation across wakes without a review
    # leg's own turns landing in it.
    if [[ "$SESSION_HARNESS_STORE" == 1 ]]; then
        pi_argv+=(--session-dir "$session_store_dir")
        if [[ -n "$SESSION_ID" ]]; then
            pi_argv+=(--session-id "$SESSION_ID")
        fi
    fi
    if [[ -n "$PI_ARGS" ]]; then
        read -r -a pi_extra_argv <<< "$PI_ARGS"
    fi
    if (( ${#pi_extra_argv[@]} )); then
        pi_argv+=("${pi_extra_argv[@]}")
    fi
    "${pi_argv[@]}" \
        < <(fs_expand_browser_prompt "$mounts_dir/handoff.md") \
        > "$work_dir/events.jsonl" \
        2> "$work_dir/pi-stderr.log"
}

# A safety net run after both the coding leg and (when there is one) the
# review loop: whichever left work uncommitted must not lose it. A single
# function rather than two copies, so the call at each site stays short --
# nesting three levels deep inside the review-loop block below is exactly
# where a repeated inline version would blow past this file's own line
# length.
commit_uncommitted_work() {
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "fork-sandbox-k8s-entrypoint: committing uncommitted work ($1)" >&2
        git add -A
        git commit --quiet -m "fork-sandbox: commit uncommitted work at run end"
    fi
}

# Per-leg state for the inbox hook. Locally every leg is a fresh tmpfs, so
# the hook's nudge markers and seen-list start empty; a pod's /tmp outlives
# every leg, so each leg gets its own directory instead (TMPDIR overrides
# the root, for tests).
claude_hook_leg() {
    claude_hook_dir="${TMPDIR:-/tmp}/fs-hook-leg-$1"
    rm -rf "$claude_hook_dir"
    mkdir -p "$claude_hook_dir"
}

# The continuation loop, the pod-side twin of the local runner's: while the
# leg that just ended left a hand-off in the outbox, start a FRESH claude
# session (never --resume) on the same clone with the original brief plus
# that hand-off. The pure logic is fs_refresh_* from refresh.sh, the same
# file the local runner sources. Records live in /work, not the outbox, so
# nothing here is harvested as mail. pi_rc ends as the LAST leg's exit.
# Ends with refresh.json: { ended, continuations }.
run_claude_continuations() {
    local log="$work_dir/refresh.log" ended="" n=0 leg_no next_n rec
    local stale rc prompt stale_json merged last_events="$work_dir/events.jsonl"
    local continuations='[]'
    # The branch head as of just before the most recently run leg (the
    # coding leg, for the first iteration, or a continuation): the pod owns
    # its clone, so this reads it directly, unlike the local runner's
    # ls-remote. Compared at the top of the next iteration to detect a
    # stall -- see fs_refresh_is_stall (refresh.sh). leg_outbox_before is the
    # outbox signature (fs_refresh_outbox_sig) captured at the same points.
    local leg_head_before="" leg_outbox_before=""
    leg_head_before="$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)"
    leg_outbox_before="$(fs_refresh_outbox_sig "$outbox_dir")"
    fs_refresh_window_mismatch "$work_dir/events.jsonl" \
        "${REFRESH_CONTEXT_WINDOW:-}" >&2
    if (( pi_rc == 0 )); then
        fs_refresh_archive_inbox "$inbox_dir" "$work_dir" 1 "$log"
    fi
    while :; do
        if [[ -f "$outbox_dir/handoff.md" ]]; then
            local now_head
            now_head="$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)"
            if fs_refresh_is_stall "$(( n + 1 ))" "$leg_head_before" "$now_head" \
                "$leg_outbox_before" "$(fs_refresh_outbox_sig "$outbox_dir")"; then
                ended=stalled
                mv -f -- "$outbox_dir/handoff.md" \
                    "$work_dir/handoff-stalled-$(( n + 1 )).md" 2>/dev/null
                echo "fork-sandbox-k8s-entrypoint: continuation leg $(( n + 1 ))" \
                    "stalled (hand-off waiting, branch head and outbox unchanged)" >&2
                break
            fi
            if (( n >= REFRESH_MAX )); then
                ended=cap
                break
            fi
            next_n=$(( n + 1 ))
            if ! fs_refresh_take_handoff "$outbox_dir" "$work_dir" \
                "$next_n" "$log" > /dev/null; then
                ended=no-handoff
                break
            fi
            n=$next_n
            leg_no=$(( n + 1 ))
            rec="handoff-$n.md"
            stale=0
            if fs_refresh_handoff_stale "$clone_dir" "$work_dir/$rec"; then
                stale=1
            fi
            prompt="$work_dir/continuation-prompt-$n.md"
            fs_refresh_build_prompt "$n" "$work_dir/$rec" "$prompt" "$stale" \
                "$mounts_dir/continuation-header.md" \
                "$mounts_dir/handoff-original.md" "$work_dir"
            claude_hook_leg "$leg_no"
            claude_argv=("${claude_argv_fresh[@]}")
            last_events="$work_dir/events-continuation-$n.jsonl"
            echo "fork-sandbox-k8s-entrypoint: continuation leg $leg_no" \
                "(from $rec)" >&2
            leg_head_before="$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)"
            leg_outbox_before="$(fs_refresh_outbox_sig "$outbox_dir")"
            rc=0
            run_claude_attempt "$prompt" "$last_events" \
                "$work_dir/claude-stderr-continuation-$n.log" || rc=$?
            pi_rc=$rc
            echo "fork-sandbox-k8s-entrypoint: claude exited $rc" >&2
            fs_refresh_window_mismatch "$last_events" \
                "${REFRESH_CONTEXT_WINDOW:-}" >&2
            if (( rc == 0 )); then
                fs_refresh_archive_inbox "$inbox_dir" "$work_dir" "$leg_no" "$log"
            fi
            stale_json=false
            if (( stale )); then
                stale_json=true
            fi
            merged="$(jq -c -n --argjson prev "$continuations" \
                --argjson leg "$leg_no" --argjson exit "$rc" \
                --arg handoff "$rec" --argjson stale "$stale_json" \
                '$prev + [{leg: $leg, exit: $exit, handoff: $handoff,
                    handoff_stale: $stale}]')"
            continuations="$merged"
            if (( rc != 0 )); then
                if [[ -f "$outbox_dir/handoff.md" && ! -L "$outbox_dir/handoff.md" ]]; then
                    mv -f -- "$outbox_dir/handoff.md" \
                        "$work_dir/handoff-leg-$leg_no-after-error.md"
                fi
                ended=leg-error
                break
            fi
            continue
        fi
        if fs_refresh_leg_was_nudged "$last_events"; then
            ended=no-handoff
        else
            ended=empty-outbox
        fi
        break
    done
    rm -f -- "$inbox_dir/.refresh-config"
    jq -n --arg ended "$ended" --argjson continuations "$continuations" \
        '{ended: $ended, continuations: $continuations}' \
        > "$work_dir/refresh.json.tmp"
    mv -f "$work_dir/refresh.json.tmp" "$work_dir/refresh.json"
    echo "fork-sandbox-k8s-entrypoint: refresh ended: $ended" \
        "($n continuation leg(s) ran)" >&2
}

# The refresh loop archives every addendum out of /work/inbox the moment a
# claude leg ends, so the review and fix legs that follow no longer find
# them in the live inbox. Like the local review walker, fold the archived
# ones into a copy of a review or fix prompt. $1 source prompt, $2 copy to
# write. Returns 1, writing nothing, when there are none (refresh off, or
# nothing was sent).
append_archived_addenda() {
    local list dir f
    declare -F fs_refresh_addenda_dirs > /dev/null || return 1
    list="$(fs_refresh_addenda_dirs "$work_dir")"
    [[ -n "$list" ]] || return 1
    {
        cat -- "$1"
        printf '\n---\n\n## Operator addenda delivered to earlier legs of this run\n\n'
        printf 'The operator sent the messages below to an earlier leg of this run,\n'
        printf 'oldest first. The live inbox no longer holds them -- the coding\n'
        printf 'session archived what it saw the moment each leg ended -- so this\n'
        printf 'is the only copy this leg will see. Check the work against each\n'
        printf 'one: an addendum the branch does not follow is a finding, citing\n'
        printf 'the message file itself.\n'
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            for f in "$dir"/*.md; do
                [[ -f "$f" ]] || continue
                printf '\n### %s\n\n' "${f##*/}"
                cat -- "$f"
            done
        done <<< "$list"
    } > "$2"
}

# The claude credential install + ~/.claude.json trust write, shared by
# the legacy HARNESS=claude arm below and the RUN_DIR arm just above it in
# control flow (see the pi_rc=0 block): the ONLY part of that arm's own
# setup a runner-mode run still needs pod-side. The inbox hook, the commit
# guard and inbox-settings.json are deliberately NOT part of this
# function -- in runner mode those are staged by the launcher under
# $RUN_DIR/inbox already (fs_stage_inbox, run on the host), and installing
# them again here would be a second, possibly-drifting copy of the same
# files, not a fix for anything.
claude_pod_credentials() {
    echo "fork-sandbox-k8s-entrypoint: installing the claude credential" >&2
    mkdir -p "$HOME/.claude"
    install -m 600 "$mounts_dir/claude-credentials.json" "$HOME/.claude/.credentials.json"
    # $HOME is a fresh tmpfs, so claude finds no config. Pre-accept
    # onboarding and trust for the clone dir, same jq claude-sandboxed
    # uses for a local sealed run, to keep this non-interactive run from
    # stalling on a dialog nothing can answer.
    jq -n --arg dir "$clone_dir" '{
        hasCompletedOnboarding: true,
        hasTrustDialogAccepted: true,
        projects: { ($dir): { hasTrustDialogAccepted: true } },
    }' > "$HOME/.claude.json"
}

# discover_pipeline_pi_facts/synthesize_pi_config_list: the RUN_DIR arm's
# counterpart to discover_model_facts/synthesize_pi_config above -- a
# runner-mode run carries no single MODEL, so every DISTINCT pi model id
# pipeline.json's steps and fix seats name (newline-separated in $1) gets
# its own lookup against the same catalog fetch, one fetch for the whole
# run rather than one per id. Applies the identical refusal rule
# discover_model_facts documents at length: a guessed context length --
# the id absent from the listing, the fetch itself failing, or an entry
# with no usable max_model_len -- is an ERROR unless ALLOW_UNLISTED_MODEL=1,
# in which case it is a warning naming the guess. Sets PIPELINE_PI_FACTS to
# newline-separated "id ctx maxtok" triples, the listing's own spelling
# when it differs case-only from the configured id, and PIPELINE_PI_REWRITE
# to a JSON object {"configured-id": "listing-id", ...} with one entry per
# id actually rewritten -- the map fork-sandbox-k8s-leg.sh's pi arm reads
# back (written to /work/pi-model-map.json by the caller below) so each
# leg sends the proxy the spelling models.json was synthesized under.
# Never run when MODEL_DISCOVERY is unset: every id then gets the
# pre-discovery constants 131072/32768, same as discover_model_facts' own
# no-discovery branch -- and PIPELINE_PI_REWRITE stays empty, since no
# listing was ever consulted.
discover_pipeline_pi_facts() {
    local ids="$1" url="$PROXY_BASE_URL/models" body="" probe_ids="" \
        curl_rc=0 fetch_note="" id
    PIPELINE_PI_FACTS=""
    PIPELINE_PI_REWRITE="{}"
    if [[ -z "$MODEL_DISCOVERY" ]]; then
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            PIPELINE_PI_FACTS+="$id 131072 32768"$'\n'
        done <<< "$ids"
        return 0
    fi
    body="$(curl -sS --max-time 20 "$url" 2>&1)" || curl_rc=$?
    if (( curl_rc != 0 )); then
        fetch_note="$body"
        body=""
    else
        probe_ids="$(jq -r '.data[].id' <<<"$body" 2>/dev/null || true)"
        if [[ -z "$probe_ids" ]]; then
            fetch_note="it answered with no model list: ${body:0:400}"
        fi
    fi
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        local configured_id="$id" listed="" cand len why kind maxtok
        while IFS= read -r cand; do
            if [[ -n "$cand" && "${cand,,}" == "${id,,}" ]]; then listed="$cand"; break; fi
        done <<< "$probe_ids"
        if [[ -n "$listed" && "$listed" != "$id" ]]; then
            echo "fork-sandbox-k8s-entrypoint: the listing spells model" \
                "'$listed', not the configured '$id'; using the listing's" \
                "spelling." >&2
            id="$listed"
            PIPELINE_PI_REWRITE="$(jq -c --arg from "$configured_id" --arg to "$id" \
                '. + {($from): $to}' <<< "$PIPELINE_PI_REWRITE")"
        fi
        len="$(jq -r --arg m "$id" \
            'first(.data[] | select(.id == $m) | .max_model_len // empty) // empty' \
            <<<"$body" 2>/dev/null || true)"
        if [[ ! "$len" =~ ^[0-9]+$ ]]; then
            len=32768
            if [[ -z "$probe_ids" ]]; then
                kind=catalog
                why="the endpoint's model catalog could not be read ($url: $fetch_note)"
            elif ! printf '%s\n' "$probe_ids" | grep -qxF "$id"; then
                kind=unlisted
                why="the endpoint's listing does not contain that id"
            else
                kind=nolen
                why="its entry in the listing carries no usable max_model_len"
            fi
            if [[ "$ALLOW_UNLISTED_MODEL" == 1 ]]; then
                echo "Warning: the context length for '$id' is a GUESS of" >&2
                echo "$len tokens -- $why. Continuing because" >&2
                echo "ALLOW_UNLISTED_MODEL=1 permits a launch whose context" >&2
                echo "had to be guessed." >&2
            else
                echo "Error: the context length for '$id' had to be" >&2
                echo "guessed: $why." >&2
                echo "K8S_ALLOW_UNLISTED_MODEL=1 in k8s.env permits a launch" >&2
                echo "whose context had to be guessed." >&2
                exit 1
            fi
            unset kind
        fi
        maxtok=32768
        if (( len / 4 < maxtok )); then maxtok=$(( len / 4 )); fi
        PIPELINE_PI_FACTS+="$id $len $maxtok"$'\n'
    done <<< "$ids"
}

# Writes ~/.pi/agent/models.json with one entry per pi model id a
# runner-mode run carries, each with its OWN context window from $1 (the
# discover_pipeline_pi_facts "id ctx maxtok" lines) -- the runner-mode
# counterpart to synthesize_pi_config above, which only ever handles one
# or two ids sharing one pair of windows. $2 is the default model (the
# first pi seat's own id in pipeline.json step order).
synthesize_pi_config_list() {
    local facts="$1" default_model="$2" id ctx maxtok
    echo "fork-sandbox-k8s-entrypoint: synthesizing pi config for a runner-mode run" >&2
    mkdir -p "$HOME/.pi/agent"
    if [[ -f "$mounts_dir/pi-agent-settings.json" ]]; then
        cp "$mounts_dir/pi-agent-settings.json" "$HOME/.pi/agent/settings.json"
    fi
    local models_json='[]'
    while IFS=' ' read -r id ctx maxtok; do
        [[ -n "$id" ]] || continue
        models_json="$(jq -c -n --argjson prev "$models_json" --arg id "$id" \
            --argjson ctx "$ctx" --argjson maxtok "$maxtok" \
            '$prev + [{id: $id, name: ($id + " (proxy)"), reasoning: true,
                input: ["text"], contextWindow: $ctx, maxTokens: $maxtok,
                cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}}]')"
    done <<< "$facts"
    jq -n --arg base "$PROXY_BASE_URL" --argjson models "$models_json" '{
        providers: {
            proxy: { baseUrl: $base, api: "openai-completions", apiKey: "sandbox",
                models: $models },
        },
    }' > "$HOME/.pi/agent/models.json"
    local settings_base='{}'
    if [[ -f "$HOME/.pi/agent/settings.json" ]]; then
        settings_base="$(cat "$HOME/.pi/agent/settings.json")"
    fi
    if ! jq -n --argjson base "$settings_base" --arg model "$default_model" \
        '$base * { defaultProvider: "proxy", defaultModel: $model }' \
        > "$HOME/.pi/agent/settings.json.new"; then
        echo "Error: pi-agent/settings.json is not valid JSON, so the generated" >&2
        echo "model defaults cannot be merged into it." >&2
        exit 1
    fi
    mv "$HOME/.pi/agent/settings.json.new" "$HOME/.pi/agent/settings.json"
}

pi_rc=0
if [[ -n "$RUN_DIR" ]]; then
    # The push landed everything .inputs-complete gates on, including
    # RUN_DIR's own contents (see fork-sandbox-k8s.sh's --run-dir doc
    # comment on cmd_submit) -- so run.sh and pipeline.json are readable
    # by now, unlike at the RUN_DIR validation near the top of this
    # script.
    for f in "$RUN_DIR/run.sh" "$RUN_DIR/pipeline.json"; do
        if [[ ! -r "$f" ]]; then
            echo "Error: RUN_DIR is set but $f is missing or unreadable. The" >&2
            echo "launcher should have staged it, and the push should have" >&2
            echo "delivered it, before this run started." >&2
            exit 1
        fi
    done
    # The CLAUDE_PROXY_BASE_URL requirement deferred from the top of this
    # script (see RUN_DIR's own doc comment there): pipeline.json is only
    # readable now, after the push, so this is the first point this check
    # can run.
    pipeline_has_claude=0
    if jq -e '
        ([.steps[] | select(.harness == "claude")]
         + [.steps[] | select(.fix != null and .fix.harness == "claude")])
        | length > 0' "$RUN_DIR/pipeline.json" > /dev/null; then
        pipeline_has_claude=1
    fi
    if (( pipeline_has_claude )); then
        : "${CLAUDE_PROXY_BASE_URL:?must be set: a pipeline.json seat is claude}"
    fi
    pipeline_pi_models="$(jq -r '
        [.steps[] | select(.harness == "pi") | .model] +
        [.steps[] | select(.fix != null and .fix.harness == "pi") | .fix.model]
        | unique | .[]' "$RUN_DIR/pipeline.json")"
    if [[ -n "$pipeline_pi_models" ]]; then
        echo "fork-sandbox-k8s-entrypoint: discovering pi model facts for a" \
            "runner-mode run" >&2
        discover_pipeline_pi_facts "$pipeline_pi_models"
        default_pi_model="$(head -n1 <<< "$pipeline_pi_models")"
        synthesize_pi_config_list "$PIPELINE_PI_FACTS" "$default_pi_model"
        # fork-sandbox-k8s-leg.sh's pi arm reads this back under the
        # SAME override variable, so the two always agree on where it
        # lives: ${FORK_SANDBOX_K8S_PI_MODEL_MAP:-/work/pi-model-map.json}.
        printf '%s\n' "$PIPELINE_PI_REWRITE" \
            > "${FORK_SANDBOX_K8S_PI_MODEL_MAP:-/work/pi-model-map.json}"
    fi
    if (( pipeline_has_claude )); then
        claude_pod_credentials
    fi
    # FORK_SANDBOX_LEG_HANDOFF_DIR is set only when fork-sandbox-k8s.sh's
    # pod spec split this run across a runner and a leg container (see
    # "Composed pipelines on --k8s" in docs/kubernetes-runs.md) -- which is
    # every composed run now, but the check stays explicit rather than
    # assuming RUN_DIR implies it, so a pod built from an older ConfigMap
    # that still runs everything in one container (no leg-loop.sh, no
    # second container to relay to) is not left waiting on a hand-off that
    # will never arrive. This container just finished the ONLY
    # network-touching setup a leg needs (the pi proxy's model discovery
    # above, the claude credential placeholder just above this) -- relay
    # the result to the leg container's own $HOME instead of redoing it
    # there, which would mean a second discovery round that could
    # disagree with this one. See fork-sandbox-k8s-leg-loop.sh's own
    # header for the read side of this hand-off.
    if [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]]; then
        leg_setup_dir="$RUN_DIR/.leg-setup"
        mkdir -p "$leg_setup_dir"
        if [[ -d "$HOME/.pi/agent" ]]; then
            rm -rf "$leg_setup_dir/pi-agent"
            cp -a "$HOME/.pi/agent" "$leg_setup_dir/pi-agent"
        fi
        if [[ -f "$HOME/.claude/.credentials.json" ]]; then
            cp "$HOME/.claude/.credentials.json" "$leg_setup_dir/claude-credentials.json"
        fi
        if [[ -f "$HOME/.claude.json" ]]; then
            cp "$HOME/.claude.json" "$leg_setup_dir/claude.json"
        fi
        if [[ -f "${FORK_SANDBOX_K8S_PI_MODEL_MAP:-/work/pi-model-map.json}" ]]; then
            cp "${FORK_SANDBOX_K8S_PI_MODEL_MAP:-/work/pi-model-map.json}" \
                "$leg_setup_dir/pi-model-map.json"
        fi
        touch "$leg_setup_dir/ready"
    fi
    # The entire leg walk -- code, review, fix, maintain, in whatever
    # order pipeline.json names -- happens inside run.sh, through the
    # SAME runner scripts/fork-sandbox-runner.sh (see its own header) a
    # local run executes. Nothing else in this script runs a leg of its
    # own in this mode: not the HARNESS-gated coding leg below, not the
    # REVIEW_LOOP_CAP review loop further down (see its own RUN_DIR
    # exclusion), not commit_uncommitted_work -- run.sh's own end-of-run
    # check already covers it, and also saves any leftover work as a
    # patch file (see fork-sandbox-runner.sh's own uncommitted-work
    # check), since a pod's emptyDir has no backstop commit_uncommitted_
    # work would otherwise be the only one to give it.
    echo "fork-sandbox-k8s-entrypoint: running the shared runner" >&2
    ( cd "$clone_dir" && bash "$RUN_DIR/run.sh" ) || pi_rc=$?
    echo "fork-sandbox-k8s-entrypoint: runner exited $pi_rc" >&2
elif [[ "$HARNESS" == pi ]]; then
    # REVIEW_MODEL, when set, is folded in up front so the review loop
    # below never needs a second synthesize_pi_config call for a pi
    # coding leg -- only a claude coding leg (which skips this branch
    # entirely) still needs one, right before the loop runs.
    synthesize_pi_config "$MODEL" "$REVIEW_MODEL" \
        "$CTX" "$MAX_TOKENS" "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"

    echo "fork-sandbox-k8s-entrypoint: running pi" >&2
    run_pi_coding_leg || pi_rc=$?
    echo "fork-sandbox-k8s-entrypoint: pi exited $pi_rc" >&2
else
    claude_pod_credentials

    # The operator-inbox hook, exactly as a local claude run's --settings
    # installs it, so `fork-sandbox-k8s.sh say` addenda are delivered on
    # the next tool call and block a Stop while unread.
    install -m 755 "$mounts_dir/inbox-hook.sh" "$inbox_dir/.inbox-hook.sh"

    # The commit guard, as a local EDITING leg gets it. Always installed:
    # the review loop below runs pi regardless of HARNESS, so this pod's
    # only claude leg is the coding leg.
    install -m 755 "$mounts_dir/stop-guard.sh" "$inbox_dir/.stop-guard.sh"
    printf 'CLONE_DIR=%s\n' "$clone_dir" > "$inbox_dir/.stop-guard-config"
    jq -n --arg hook "$inbox_dir/.inbox-hook.sh" --arg guard "$inbox_dir/.stop-guard.sh" '{
        hooks: {
            PostToolUse: [ { matcher: "*",
                             hooks: [ { type: "command", command: $hook, timeout: 20 } ] } ],
            Stop: [ { hooks: [ { type: "command", command: $hook, timeout: 20 },
                               { type: "command", command: $guard, timeout: 30 } ] } ],
        },
    }' > "$work_dir/inbox-settings.json"

    # The durable session store, seeded into this pod's own ~/.claude
    # before the claude call so --resume below can find the transcript it
    # names. Pulled in whole (every project's transcripts, not just this
    # one) because the pod's own cwd-derived slug may not be the slug the
    # transcript was written under on a PRIOR pod -- see the flatten step
    # right after.
    # The CLI grants a model its native 1M window only when
    # ANTHROPIC_BASE_URL is unset or api.anthropic.com; behind the seat's
    # proxy it falls back to 200k. The [1m] alias restores 1M. Only the
    # CLI's own [1m] aliases get it: on any other id it would claim a window
    # the model may not have.
    claude_model="$MODEL"
    case "$claude_model" in
        opus|sonnet|fable) claude_model+="[1m]" ;;
    esac
    claude_argv=(claude --dangerously-skip-permissions --print --verbose
        --output-format stream-json --model "$claude_model"
        --settings "$work_dir/inbox-settings.json" --include-hook-events)
    if [[ "$SESSION_HARNESS_STORE" == 1 ]]; then
        echo "fork-sandbox-k8s-entrypoint: seeding the claude session store" >&2
        mkdir -p "$HOME/.claude/projects"
        if [[ -d "$session_store_dir" ]]; then
            cp -a "$session_store_dir/." "$HOME/.claude/projects/"
        fi
        # claude looks up a --resume id inside the CURRENT project's own
        # slug directory (cwd with every "/" replaced by "-"), so a
        # transcript that landed here under a different cwd's slug would
        # not be found. Flatten every transcript into this run's slug
        # directory too, keeping the original in place -- cp -p keeps its
        # mtime, which fs_session_discover_id's newest-mtime rule depends
        # on to find the right one back on the host.
        pod_slug="${clone_dir//\//-}"
        mkdir -p "$HOME/.claude/projects/$pod_slug"
        while IFS= read -r -d '' transcript_file; do
            case "$transcript_file" in
                "$HOME/.claude/projects/$pod_slug/"*) continue ;;
            esac
            cp -p "$transcript_file" "$HOME/.claude/projects/$pod_slug/"
        done < <(find "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl' \
            -type f -print0 2>/dev/null)
    fi

    # The fresh form is kept whether or not a resume was asked for: it is
    # what the retry below falls back to. Built the same way
    # claude-sandboxed builds its own TARGET_CMD/TARGET_CMD_FRESH pair.
    claude_argv_fresh=("${claude_argv[@]}")
    if [[ -n "$RESUME_SESSION" ]]; then
        claude_argv=("${claude_argv[0]}" --resume "$RESUME_SESSION" "${claude_argv[@]:1}")
    fi

    # $1 stdin, $2 events, $3 stderr: leg 1's own files unless a
    # continuation names its own. The inbox hook's state paths are set
    # only while a refreshing run has a per-leg directory (claude_hook_dir).
    run_claude_attempt() {
        # A raised Bash timeout cap, same as the env block in
        # fork-sandbox.sh's own inbox settings file.
        local -a leg_env=(ANTHROPIC_BASE_URL="$CLAUDE_PROXY_BASE_URL"
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
            BASH_MAX_TIMEOUT_MS=3600000
            TERM=dumb)
        # The pod's /tmp outlives every attempt, so each attempt (a retry
        # included) starts the commit guard's refusal count from zero.
        local guard_state="${claude_hook_dir:-${TMPDIR:-/tmp}}/stop-guard-refusals"
        rm -f "$guard_state"
        leg_env+=("FORK_SANDBOX_STOP_GUARD_STATE=$guard_state")
        if [[ -n "${claude_hook_dir:-}" ]]; then
            leg_env+=("FORK_SANDBOX_NUDGE_MARKER=$claude_hook_dir/nudged"
                "FORK_SANDBOX_NUDGE_REMINDED=$claude_hook_dir/nudge-reminded"
                "FORK_SANDBOX_STALE_REMINDED=$claude_hook_dir/stale-reminded"
                "FORK_SANDBOX_INBOX_SEEN=$claude_hook_dir/inbox-seen"
                "FORK_SANDBOX_NUDGE_BASELINE=$claude_hook_dir/nudge-baseline")
        fi
        env "${leg_env[@]}" "${claude_argv[@]}" \
            < <(fs_expand_browser_prompt "${1:-$mounts_dir/handoff.md}") \
            > "${2:-$work_dir/events.jsonl}" \
            2> "${3:-$work_dir/claude-stderr.log}"
    }

    if [[ -n "${REFRESH_THRESHOLD_TOKENS:-}" ]]; then
        # shellcheck source=/dev/null
        source "$mounts_dir/refresh.sh"
        printf '%s\n' "THRESHOLD_TOKENS=$REFRESH_THRESHOLD_TOKENS" \
            "OUTBOX_DIR=$outbox_dir" "CLONE_DIR=$clone_dir" \
            "CEILING_TOKENS=$REFRESH_CEILING_TOKENS" \
            > "$inbox_dir/.refresh-config"
        claude_hook_leg 1
    fi

    echo "fork-sandbox-k8s-entrypoint: running claude" >&2
    run_claude_attempt || pi_rc=$?
    echo "fork-sandbox-k8s-entrypoint: claude exited $pi_rc" >&2

    # What stderr has to say for a failure to count as "the resume did not
    # work" rather than "the work did not work" -- must match
    # claude-sandboxed RESUME_FAIL_RE literally, copied from there.
    # Deliberately narrow: a false positive here reruns a session that
    # already did its work, at full price.
    RESUME_FAIL_RE='no conversation found with session id:'
    RESUME_FAIL_RE+='|corrupt.*(session|transcript|conversation)'
    RESUME_FAIL_RE+='|failed to (load|parse|read).*(session|transcript|conversation)'
    if [[ -n "$RESUME_SESSION" ]] && (( pi_rc != 0 )) \
        && grep -qiE "$RESUME_FAIL_RE" "$work_dir/claude-stderr.log"; then
        echo "fork-sandbox-k8s-entrypoint: resume failed, retrying fresh" \
            "(session $RESUME_SESSION)" >&2
        claude_argv=("${claude_argv_fresh[@]}")
        pi_rc=0
        run_claude_attempt || pi_rc=$?
        echo "fork-sandbox-k8s-entrypoint: claude exited $pi_rc" >&2
    fi

    # A claude leg that STILL fails, on an auth or transient provider error
    # (a revoked/expired OAuth token, an overloaded/5xx model) rather than
    # the run's own doing, is restarted fresh -- never resumed, the resume
    # itself already had its one chance above, which is a different trigger
    # -- up to once per entry of FS_LEG_RETRY_DELAYS (default "30 120", a
    # test hook exactly like the local runner's own FS_LEG_RETRY_DELAYS --
    # see fs_run_claude_leg_with_retry in fork-sandbox-runner.sh).
    # fs_leg_error_retryable and fs_harness_error are the exact same
    # functions that backstop uses, sourced from fork-sandbox-lib.sh above
    # unconditionally for HARNESS=claude (this whole block runs only in
    # that branch), so no existence guard is needed here -- a missing
    # lib.sh already failed the source above loudly, before reaching this
    # point. Simpler than the local runner's own driver: one leg, no
    # per-attempt archiving (this pod's events.jsonl is simply overwritten
    # by the next attempt) and no cost accounting (the host reads this
    # run's cost from the pod's own outbox/evidence afterwards, not from
    # anything this loop tracks).
    IFS=' ' read -r -a claude_retry_delays <<< "${FS_LEG_RETRY_DELAYS:-30 120}"
    claude_retry_attempt=0
    for claude_retry_delay in "${claude_retry_delays[@]}"; do
        (( pi_rc != 0 )) || break
        claude_retry_err="$(fs_harness_error claude "$work_dir/events.jsonl")"
        fs_leg_error_retryable claude "$claude_retry_err" || break
        # Pre-increment: this runs under set -e, and a POST-increment
        # from 0 evaluates the arithmetic command's own result to 0
        # (the OLD value), which set -e reads as a failing command and
        # aborts the whole leg right here on the very first retry.
        (( ++claude_retry_attempt ))
        echo "fork-sandbox-k8s-entrypoint: claude failed on a transient error" \
            "($claude_retry_err); retry $claude_retry_attempt/${#claude_retry_delays[@]}" \
            "in ${claude_retry_delay}s" >&2
        sleep "$claude_retry_delay"
        claude_argv=("${claude_argv_fresh[@]}")
        pi_rc=0
        run_claude_attempt || pi_rc=$?
        echo "fork-sandbox-k8s-entrypoint: claude exited $pi_rc" >&2
        if (( pi_rc == 0 )); then
            echo "fork-sandbox-k8s-entrypoint: claude succeeded on retry" \
                "$claude_retry_attempt" >&2
        fi
    done

    if [[ -n "${REFRESH_THRESHOLD_TOKENS:-}" ]]; then
        run_claude_continuations
    fi

    if [[ "$SESSION_HARNESS_STORE" == 1 ]]; then
        # THE TRAP THIS DESIGN EXISTS FOR: the review loop below, when
        # there is one, shares this same $HOME, so its own claude/pi legs
        # would write newer transcripts into ~/.claude/projects. Snapshot
        # right after the coding leg -- before commit_uncommitted_work and
        # before the review loop -- so cmd_collect's pull (which reads
        # only /work/session-store) carries the CODING leg's conversation,
        # never a reviewer's.
        # Staged, then swapped: a partial copy (a full emptyDir) must never
        # replace the pushed store, since cmd_collect would pull it back
        # over the host's complete one. On failure the pushed store stays.
        echo "fork-sandbox-k8s-entrypoint: snapshotting the claude session store" >&2
        rm -rf "$session_store_dir.new"
        if cp -a "$HOME/.claude/projects" "$session_store_dir.new"; then
            rm -rf "$session_store_dir"
            mv "$session_store_dir.new" "$session_store_dir"
        else
            rm -rf "$session_store_dir.new"
            echo "fork-sandbox-k8s-entrypoint: warning: session store" \
                "snapshot failed; keeping the store this wake started from" >&2
        fi
    fi
fi

# Not run in RUN_DIR mode: run.sh's own end-of-run uncommitted check
# (runner_in_sandbox, see fork-sandbox-runner.sh) already ran, inside
# run.sh, before control returned here -- and it CHECKS and RECORDS
# uncommitted work (saving it as a patch file, since a pod's emptyDir
# has no other backstop), it never commits it, exactly like a local run.
# Calling this here too would silently commit, under an agent-less
# message, work the record just reported as left uncommitted -- a
# divergence from local behaviour no local run has, not a fix.
if [[ -z "$RUN_DIR" ]]; then
    commit_uncommitted_work "coding leg"
fi

# The --review-loop pass, when this run carries one. Runs pod-side -- the
# pod owns the clone, so a fresh review/fix session per iteration costs no
# kubectl round trip. See review-loop.sh's own header for the control flow;
# this block decides whether the branch holds anything to hand it at all,
# not whether pi succeeded -- review-loop.sh already skips on its own when
# the branch head equals BASE_SHA, so a non-zero pi exit is folded into the
# review prompt and recorded in review-loop.json, not used to preempt the
# loop. Only an unreadable branch head is this block's own call, since
# review-loop.sh treats that as a hard failure rather than a graceful skip.
# Not run in RUN_DIR mode either: a runner-mode pipeline that wants a
# review/fix loop gets it from pipeline.json's own steps, walked inside
# run.sh -- this is the legacy single-leg path's own loop, and RUN_DIR
# should never carry a positive REVIEW_LOOP_CAP alongside it (the client
# does not render both), but the guard is explicit here rather than
# implicit in that absence.
if [[ -z "$RUN_DIR" ]] && [[ "$REVIEW_LOOP_CAP" =~ ^[1-9][0-9]*$ ]]; then
    coding_head="$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$coding_head" ]]; then
        echo "fork-sandbox-k8s-entrypoint: branch $BRANCH could not be read;" >&2
        echo "fork-sandbox-k8s-entrypoint: skipping the review loop" >&2
        jq -n --argjson cap "$REVIEW_LOOP_CAP" --argjson rc "$pi_rc" --arg branch "$BRANCH" '{
            cap: $cap,
            ended: "skipped",
            detail: ("branch " + $branch + " could not be read from the clone"),
            coding_exit_code: $rc,
            iterations: [],
        }' > "$work_dir/review-loop.json"
    else
        review_prompt_path="$mounts_dir/review-prompt.md"
        if [[ "$pi_rc" != "0" ]]; then
            # The session may have failed partway through -- reviewed
            # anyway (review-loop.sh decides for itself whether the branch
            # holds any commits worth it), but told so it can judge the
            # branch as a possibly-incomplete implementation rather than a
            # finished one. $mounts_dir is a read-only mount, so the
            # annotated copy is written to $work_dir instead.
            echo "fork-sandbox-k8s-entrypoint: pi exited $pi_rc; reviewing what it landed" >&2
            review_prompt_path="$work_dir/review-prompt-annotated.md"
            {
                cat -- "$mounts_dir/review-prompt.md"
                printf '\n---\n\n## The coding session exited non-zero\n\n'
                printf 'The session that produced the commits under review exited with\n'
                printf 'status %s. Its work may be incomplete or partially\n' "$pi_rc"
                printf 'applied -- read the branch and flag anything that looks\n'
                printf 'unfinished as a finding, the same as any other defect.\n'
            } > "$review_prompt_path"
        else
            echo "fork-sandbox-k8s-entrypoint: running the review loop" >&2
        fi
        fix_header_path="$mounts_dir/fix-prompt-header.md"
        if append_archived_addenda "$review_prompt_path" \
            "$work_dir/review-prompt-addenda.md"; then
            review_prompt_path="$work_dir/review-prompt-addenda.md"
            append_archived_addenda "$fix_header_path" \
                "$work_dir/fix-prompt-header-addenda.md"
            fix_header_path="$work_dir/fix-prompt-header-addenda.md"
        fi
        # The review loop always runs pi, regardless of the coding leg's
        # harness, and always prefers REVIEW_MODEL over MODEL when set --
        # required at startup when HARNESS=claude, see the validation
        # above; optional for a pi coding leg, which already folded both
        # ids into models.json (synthesize_pi_config above), so no
        # override here just changes which of the two ids pi is told to
        # use. A claude coding leg never synthesized pi config at all
        # (MODEL is a Claude Code model name pi cannot use), so it is
        # synthesized here, for the first time.
        review_loop_model="${REVIEW_MODEL:-$MODEL}"
        if [[ "$HARNESS" == claude ]]; then
            # $review_loop_model is REVIEW_MODEL here (required at startup
            # for a claude coding leg), so it gets the window discovered
            # for its own id -- never MODEL's, which is a Claude Code
            # model name the pi endpoint's listing never contains.
            synthesize_pi_config "$review_loop_model" "" \
                "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"
        fi
        loop_rc=0
        MODEL="$review_loop_model" bash "$mounts_dir/review-loop.sh" \
            --clone "$clone_dir" \
            --cap "$REVIEW_LOOP_CAP" \
            --base-sha "$BASE_SHA" \
            --review-prompt "$review_prompt_path" \
            --fix-header "$fix_header_path" \
            --verdict "$clone_dir/.git/review-verdict.md" \
            --work-dir "$work_dir" \
            --out "$work_dir/review-loop.json" \
            || loop_rc=$?
        if [[ "$loop_rc" != "0" ]]; then
            # Not propagated to this container's own exit status -- see the
            # comment on run_complete below. review-loop.json is where the
            # loop's outcome actually lives.
            echo "fork-sandbox-k8s-entrypoint: review-loop.sh exited $loop_rc" >&2
        fi

        # review-loop.sh regenerates review-loop.json from scratch and has
        # no way to know pi's exit code (only this script does), so the
        # field is folded in here after the fact rather than threaded
        # through the loop script's interface.
        if [[ -f "$work_dir/review-loop.json" ]]; then
            jq --argjson rc "$pi_rc" '. + {coding_exit_code: $rc}' \
                "$work_dir/review-loop.json" > "$work_dir/review-loop.json.tmp" \
                && mv -f "$work_dir/review-loop.json.tmp" "$work_dir/review-loop.json"
        fi

        # Deliberately NOT run between iterations -- review-loop.sh's own
        # no-progress detection reads the branch head, and auto-committing
        # mid-loop would make "a fix leg committed nothing" undetectable
        # from inside it.
        commit_uncommitted_work "review loop"
    fi
fi

# Measured here, at the end of the run, same as the local path's own
# end-of-run check in fork-sandbox.sh -- this is a heads-up only, never
# enforced: the client's own pull-back (fork-sandbox-k8s.sh run) applies the
# real refusal against the same cap once it has the tarball in hand, and
# deleting anything here would destroy work the operator might still want to
# inspect with `kubectl exec` before that pull-back runs.
outbox_bytes="$(du -sb -- "$outbox_dir" 2>/dev/null | cut -f1)"
[[ -n "$outbox_bytes" ]] || outbox_bytes=0
if (( outbox_bytes > OUTBOX_MAX_BYTES )); then
    echo "fork-sandbox-k8s-entrypoint: WARNING: outbox is $outbox_bytes bytes," >&2
    echo "fork-sandbox-k8s-entrypoint: over the $OUTBOX_MAX_BYTES byte cap --" >&2
    echo "fork-sandbox-k8s-entrypoint: the client will refuse to pull it back." >&2
fi

# .run-complete holds the CODING leg's exit code, never the review loop's --
# even when a loop ran and even if it ended in harness-error. This mirrors
# fork-sandbox.sh's own local loop, where `rc` stays the implement leg's
# code and the loop never reassigns it: the loop's outcome travels in
# review-loop.json instead, and cmd_run reports it separately (see
# fork-sandbox-k8s.sh). Do not "fix" this to propagate the loop's result
# into the process exit code -- that would collapse two different signals
# (did the AGENT'S work run, did the REVIEW judge it clean) into one.
printf '%s\n' "$pi_rc" > "$run_complete"

echo "fork-sandbox-k8s-entrypoint: idling up to ${RUN_TTL}s for the fetch" >&2
idle_deadline=$(( $(date +%s) + RUN_TTL ))
while [[ ! -f "$fetched_marker" ]] && (( $(date +%s) < idle_deadline )); do
    sleep 5
done

exit "$pi_rc"
