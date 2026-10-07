#!/usr/bin/env bash
# fork-sandbox-k8s-leg.sh -- one leg's harness invocation, inside the pod
#
# The pod's counterpart of claude-sandboxed/pi-sandboxed: the thing a
# *_sandbox_cmd array in a generated run.sh actually execs. There is no
# sandbox backend here -- the pod's own confinement (NetworkPolicy, no
# bwrap) already does what claude-sandboxed/pi-sandboxed's bwrap layer
# does locally -- so this script is a thin, unconfined translation from
# "harness, model, clone, extra args" into the right argv and env, then
# an `exec` into it: stdin/stdout/stderr pass through exactly as the
# caller (fork-sandbox-runner.sh's own leg-running machinery, which tees
# and classifies output the same way for every leg, local or pod) set
# them up, and the exit code is the harness's own, never this script's.
#
# Usage: fork-sandbox-k8s-leg.sh --harness claude|pi --model MODEL \
#     --clone DIR -- [EXTRA_ARG...]
#
# The prompt arrives on this script's own stdin, unread here -- `exec`
# hands the harness the same file descriptor unchanged.
#
# EXTRA_ARG carries whatever the leg's own seat needs that is not
# harness/model: --settings PATH for a claude leg (rendered by the
# launcher's fs_leg_settings_for_prefix, the same inbox-hook/stop-guard
# settings file every local claude leg gets), --session-dir/--session-id
# for a pi leg's --session-state continuity, --resume for a claude
# implement leg resuming a prior session. These ride verbatim into the
# harness's own argv, in the position each harness expects them (see
# below); this script does not interpret any of them.

set -euo pipefail

usage() {
    echo "Usage: fork-sandbox-k8s-leg.sh --harness claude|pi --model MODEL --clone DIR -- [EXTRA_ARG...]" >&2
}

harness="" model="" clone_dir=""
while (( $# )); do
    case "$1" in
        --harness) harness="${2:?--harness requires claude or pi}"; shift 2 ;;
        --model) model="${2:?--model requires a model id}"; shift 2 ;;
        --clone) clone_dir="${2:?--clone requires a directory}"; shift 2 ;;
        --) shift; break ;;
        *) echo "Error: unknown option '$1'." >&2; usage; exit 1 ;;
    esac
done

[[ -n "$harness" ]] || { echo "Error: --harness is required." >&2; usage; exit 1; }
[[ -n "$model" ]] || { echo "Error: --model is required." >&2; usage; exit 1; }
[[ -n "$clone_dir" ]] || { echo "Error: --clone is required." >&2; usage; exit 1; }
cd -- "$clone_dir"

case "$harness" in
    claude)
        : "${CLAUDE_PROXY_BASE_URL:?CLAUDE_PROXY_BASE_URL must be set for a claude leg}"
        # Same alias rule as the single-leg entrypoint's own claude
        # invocation (run_claude_attempt): the CLI grants a model its
        # native 1M window only when ANTHROPIC_BASE_URL is unset or
        # api.anthropic.com -- behind this leg's proxy it falls back to
        # 200k unless the id carries the CLI's own [1m] alias.
        claude_model="$model"
        case "$claude_model" in
            opus|sonnet|fable) claude_model+="[1m]" ;;
        esac
        # A fresh per-leg state directory, the same mechanism
        # claude_hook_leg gives each continuation locally -- a composed
        # pipeline's legs share this pod's one /tmp, so without a fresh
        # directory per leg, the commit guard's refusal count and the
        # inbox hook's nudge/seen markers would carry over from one
        # leg's conversation into the next's, which never happens
        # locally (each leg there is its own fresh invocation too).
        hook_dir="$(mktemp -d -- "${TMPDIR:-/tmp}/fs-leg-hook.XXXXXX")"
        guard_state="$hook_dir/stop-guard-refusals"
        claude_argv=(claude --dangerously-skip-permissions --print --verbose
            --output-format stream-json --model "$claude_model"
            --include-hook-events "$@")
        exec env \
            ANTHROPIC_BASE_URL="$CLAUDE_PROXY_BASE_URL" \
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
            DISABLE_AUTOUPDATER=1 \
            BASH_MAX_TIMEOUT_MS=3600000 \
            TERM=dumb \
            FORK_SANDBOX_STOP_GUARD_STATE="$guard_state" \
            FORK_SANDBOX_NUDGE_MARKER="$hook_dir/nudged" \
            FORK_SANDBOX_NUDGE_REMINDED="$hook_dir/nudge-reminded" \
            FORK_SANDBOX_STALE_REMINDED="$hook_dir/stale-reminded" \
            FORK_SANDBOX_INBOX_SEEN="$hook_dir/inbox-seen" \
            FORK_SANDBOX_NUDGE_BASELINE="$hook_dir/nudge-baseline" \
            "${claude_argv[@]}"
        ;;
    pi)
        # The listing-spelling rewrite: a pi model id a run was launched
        # with may differ, case-only, from the proxy's own catalog
        # spelling (see discover_pipeline_pi_facts), and ~/.pi/agent's
        # models.json is written under the LISTING's spelling -- so a
        # mismatched MODEL here would name an id pi's own config does
        # not carry. The map is JSON {"configured-id": "listing-id",
        # ...}; absent file or absent key both mean "no rewrite needed".
        pi_model="$model"
        pi_model_map="${FORK_SANDBOX_K8S_PI_MODEL_MAP:-/work/pi-model-map.json}"
        if [[ -f "$pi_model_map" ]]; then
            mapped="$(jq -r --arg id "$model" '.[$id] // empty' "$pi_model_map" 2>/dev/null || true)"
            [[ -n "$mapped" ]] && pi_model="$mapped"
        fi
        # Same order run_pi_coding_leg already uses, pod-side: --mode
        # json -p right after --model, extra args (--session-dir et al.)
        # after that. This is the entrypoint's own single-leg order, not
        # fork-sandbox.sh's local harness_cmd order (--mode json -p
        # last) -- a CLI's own flag order has no behavioral meaning, and
        # matching the pod's own proven invocation here is narrower than
        # reconciling it with the host's.
        exec pi --provider proxy --model "$pi_model" --mode json -p "$@"
        ;;
    *)
        echo "Error: --harness must be 'claude' or 'pi', got '$harness'." >&2
        exit 1
        ;;
esac
