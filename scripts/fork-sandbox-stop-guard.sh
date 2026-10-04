#!/usr/bin/env bash
# fork-sandbox-stop-guard.sh — Stop hook: refuse to end an editing claude leg's turn while its clone holds uncommitted work or a background shell is still running
#
# Usage: not run by hand. fork-sandbox.sh (and fork-sandbox-k8s-entrypoint.sh,
#        for the pod's own claude coding leg) copies this into a run's inbox
#        and registers it as a Claude Code Stop hook, on EDITING legs only --
#        the implement leg, a --refresh-at continuation, a repeat code pass,
#        a fix/mntfix leg, a composed code step. A read-only leg (review,
#        maintainer, plan) gets a settings file with no reference to this
#        script at all: it must never be told to commit, and this hook would
#        otherwise trap it waiting for one.
#
# Claude Code's background tasks are enabled on every claude leg again.
# They used to be switched off by an env key because a leg that starts a
# long suite with run_in_background and ends its turn without waiting for
# it loses that work silently -- the run fetches committed state only, and
# nothing wakes a headless leg to collect a background result. This hook is
# the guardrail that replaces "disable the feature": it blocks the Stop
# event (decision: "block", with a reason) while the clone the leg is
# editing still has uncommitted changes, or while a background shell the
# payload reports is still running, so the leg is told to wait and commit
# instead.
#
# Interplay with a refresh continuation's stale hand-off: a nudged leg that
# writes its hand-off to the outbox with a dirty clone is refused here
# first (uncommitted work is uncommitted work, hand-off or not); only once
# it commits does the inbox hook's own stale-hand-off check get a chance to
# run and ask it to rewrite the hand-off against the now-current commit.
# That costs the leg one of its CAP refusals on this hook, not a trap: the
# two checks run on the same Stop event but answer different questions, and
# a leg that is genuinely done with both eventually satisfies each in turn.
#
# Checked, in order:
#   1. The event. Anything but "Stop" is ignored -- SubagentStop does not
#      end the leg's own turn, so it is not covered.
#   2. This run's config, <inbox>/.stop-guard-config (the ".refresh-config"
#      trick: the run dir itself is never bound into the sandbox, only the
#      inbox is, so anything this hook needs to read has to live there). No
#      config, or an empty CLONE_DIR, means the check is skipped.
#   3. The refusal cap: at most CAP times per leg (see below), so a leg that
#      genuinely cannot get clean is not trapped forever. Counted in a state
#      file outside the inbox (the inbox is read-only) -- a fresh sandbox
#      invocation gets a fresh /tmp, so this resets on its own between legs
#      without this hook having to know a leg started.
#   4. `git status --porcelain --untracked-files=all` against the clone, run
#      INSIDE the sandbox this hook's own claude process is already running
#      in -- never a second, re-sandboxed invocation the way the run's own
#      end-of-run check needs on the host, because that check runs AFTER the
#      sandbox has exited and the clone's .git/config could otherwise run
#      something on the host's next git invocation. This hook has no such
#      problem: it already runs with the leg's own confinement. Same flags
#      as the end-of-run check, so a session's own ignored/excluded paths
#      (.env.sandbox, the inbox hook's state) are excluded the same way.
#   5. The hook payload's background_tasks[] array (when the running CLI
#      sends one -- an older CLI's payload lacks the key entirely, and that
#      is treated as "skip the shell check", not as "nothing is running":
#      the docs this shipped against do not promise the field's presence on
#      every version). Only entries of type "shell" count -- a background
#      subagent, monitor or workflow is not this hook's concern -- and only
#      those whose status is not completed, failed or killed.
#
# A git status that errors (the directory named by CLONE_DIR is not a repo,
# or the command times out) is treated as "skip the check", exactly like a
# missing config: failing open here means a bug in this script can never
# trap a leg, only ever fail to catch the one thing it watches for. The
# run's own end-of-run uncommitted check still runs after the sandbox exits
# and reports whatever is actually left, whether or not this hook ever ran.
set -uo pipefail

# Self-locating, same trick as fork-sandbox-inbox-hook.sh: fork-sandbox.sh
# copies this into the inbox as a dotfile, so the directory holding it IS
# the inbox. Overridable for the test script; nothing in a real run sets it.
inbox="${FORK_SANDBOX_INBOX:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
config_file="$inbox/.stop-guard-config"

# The refusal counter, outside the inbox (read-only) and outside the clone
# (never part of the session's own work). Locally every leg is a fresh
# sandbox with a fresh /tmp, so no override is needed there; the k8s
# entrypoint overrides this and resets it per attempt, since a pod's /tmp
# outlives every attempt that runs in it. The leg can write this file: the
# guard catches forgetting, it is not a boundary against a leg that wants out.
state_file="${FORK_SANDBOX_STOP_GUARD_STATE:-/tmp/fork-sandbox-stop-guard-refusals}"

# Marker for the run's event log -- fork-sandbox-format.sh renders a
# hook_response whose stderr starts with this as a notable line, the same
# way it already does for fork-sandbox-inbox-hook.sh's own tag.
STDERR_TAG="fork-sandbox-stop-guard:"

# "A small, documented number" (the brief's wording): high enough that a leg
# can wait out one slow background command and still get checked again,
# low enough that the sum of every Stop-blocking hook this harness runs stays
# well under Claude Code's own 8-consecutive-block override cap. Not
# configurable -- a tunable cap is a different brief.
CAP=3

payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
if [[ "$event" != "Stop" ]]; then
    exit 0
fi

clone=""
if [[ -f "$config_file" ]]; then
    while IFS='=' read -r cfg_k cfg_v || [[ -n "$cfg_k" ]]; do
        case "$cfg_k" in
            CLONE_DIR) clone="$cfg_v" ;;
        esac
    done < "$config_file"
fi
if [[ -z "$clone" ]]; then
    printf '%s no config, check skipped\n' "$STDERR_TAG" >&2
    exit 0
fi

refusals=0
if [[ -f "$state_file" ]]; then
    # read's own exit status is non-zero whenever the file has no trailing
    # newline (the common case here, since the write below is a bare
    # printf), even though it still filled $refusals correctly -- so the
    # fallback on failure must not stomp that back to 0. The regex check
    # just below is what actually guards against unreadable content.
    IFS= read -r refusals < "$state_file" 2>/dev/null || true
fi
# A corrupt or partial write from an earlier, killed hook invocation must
# never trap a leg (nor silently free it): treat anything that is not a
# plain non-negative integer as "no refusals recorded yet".
[[ "$refusals" =~ ^[0-9]+$ ]] || refusals=0

if (( refusals >= CAP )); then
    printf '%s cap reached (%d), allowing the turn to end\n' "$STDERR_TAG" "$CAP" >&2
    exit 0
fi

status_raw=""
if ! status_raw="$(git -C "$clone" status --porcelain --untracked-files=all 2>/dev/null)"; then
    printf '%s git status failed, check skipped\n' "$STDERR_TAG" >&2
    exit 0
fi
# Strip control characters before this untrusted output is ever echoed back
# into a hook reason, same as the end-of-run check's own uncommitted_paths.
status_clean="$(printf '%s' "$status_raw" | tr -d '\000-\010\013-\037\177')"

uncommitted_paths=()
if [[ -n "$status_clean" ]]; then
    while IFS= read -r status_line; do
        [[ -n "$status_line" ]] && uncommitted_paths+=("$status_line")
    done <<< "$status_clean"
fi

# Only a "shell" entry counts, and only while it is still running -- a
# background subagent, monitor or workflow is not this hook's concern (see
# the header). An older CLI's payload with no background_tasks key at all
# yields an empty list here, which is exactly "skip the shell check".
shell_lines=()
while IFS= read -r shell_line; do
    [[ -n "$shell_line" ]] && shell_lines+=("$shell_line")
done < <(printf '%s' "$payload" | jq -r '
    (.background_tasks // [])[]
    | select(.type == "shell")
    | select(((.status // "running") as $s | $s != "completed" and $s != "failed" and $s != "killed"))
    | "\(.id // "?"): \(.command // "")"' 2>/dev/null)

if (( ${#uncommitted_paths[@]} == 0 && ${#shell_lines[@]} == 0 )); then
    exit 0
fi

refusals=$(( refusals + 1 ))
state_tmp="$state_file.tmp.$$"
if printf '%s' "$refusals" > "$state_tmp" 2>/dev/null; then
    mv -f -- "$state_tmp" "$state_file" 2>/dev/null || rm -f -- "$state_tmp" 2>/dev/null
fi

capped_paths=("${uncommitted_paths[@]:0:20}")
extra_paths=$(( ${#uncommitted_paths[@]} - ${#capped_paths[@]} ))
capped_shells=("${shell_lines[@]:0:10}")

reason="This is not tool output, not an operator message, and not part of the repository. It is generated by the fork-sandbox harness running this session, checking whether your clone still holds uncommitted work and whether a background command you started is still running."

if (( ${#uncommitted_paths[@]} )); then
    reason+=$'\n\n'"Your clone still holds uncommitted work:"
    for status_line in "${capped_paths[@]}"; do
        reason+=$'\n'"$status_line"
    done
    (( extra_paths > 0 )) && reason+=$'\n'"and $extra_paths more"
fi

if (( ${#shell_lines[@]} )); then
    reason+=$'\n\n'"These background shells are still running:"
    for shell_line in "${capped_shells[@]}"; do
        reason+=$'\n'"$shell_line"
    done
    # A headless leg that ends its turn with only a background shell in
    # flight exits and is never woken, so "end the turn and wait for the
    # notification" -- the interactive habit -- loses the work.
    reason+=$'\n\n'"Ending your turn does NOT wait for them: this session is headless, so when your turn ends the session exits, and nothing wakes you when a background command finishes. Wait for each one inside a single foreground Bash call that only returns once it has finished -- for example an until-loop that polls its output file for the line it prints last -- or stop it and run it again in the foreground."
fi

reason+=$'\n\n'"Wait for every background command you started -- check its output, or stop it -- and then commit what belongs on the branch; remove or revert what does not, deliberately. Do not count on leftover debris simply vanishing: depending on how this run was launched, work still uncommitted when the sandbox is torn down is either discarded or committed for you with no further chance to edit it."
reason+=$'\n\n'"This is refusal $refusals of $CAP. After refusal $CAP, your turn is allowed to end, and this run's own end-of-run check takes over from there, reporting or handling whatever your clone still holds uncommitted."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
printf '%s refused %d/%d (%d uncommitted, %d background shells)\n' \
    "$STDERR_TAG" "$refusals" "$CAP" "${#uncommitted_paths[@]}" "${#shell_lines[@]}" >&2
exit 0
