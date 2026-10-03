#!/usr/bin/env bash
# fork-sandbox-refresh-test.sh — Exercise fork-sandbox.sh's --refresh-at
#
# Usage: tests/fork-sandbox-refresh-test.sh
#
# Two halves:
#
#   The hook's own threshold arithmetic, driven directly with fake hook JSON
#   and a fixture transcript on stdin against a temp inbox -- the same style
#   fork-sandbox-inbox-test.sh uses for the addendum half of this hook.
#
#   The outer loop, driven for real: fork-sandbox.sh --foreground with
#   claude-sandboxed stubbed out (the fork-sandbox-prompt-overlay-test.sh
#   style) so no bwrap/container backend is ever exercised. The stub bypasses
#   the real claude CLI and its hook engine entirely and simulates their
#   observable effect directly -- writing to the outbox, and emitting the
#   hook's own stderr tag -- since a nudge's actual DECISION logic is already
#   covered by the hook half above.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
hook="$repo_dir/scripts/fork-sandbox-inbox-hook.sh"

# Every run this suite launches is a fixture, not real work. Mark it so
# sandbox-run-log.py's list/stats exclude it by default: without this the
# operator's own log fills with synthetic runs, and the harness stats the
# sandbox-coder-mode skill tells orchestrators to consult become misleading.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
# Every real launch below writes launcher_session_id/creates a by-session
# symlink from CLAUDE_CODE_SESSION_ID -- scoped here so a real session
# running this suite never has its own by-session index polluted with
# entries for these throwaway fixture runs.
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "expected NOT to find '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

# $1 label  $2 path  $3 want ("yes" the file must exist, "no" it must not)
marker() {
    local label="$1" path="$2" want="$3" have="no"
    [[ -f "$path" ]] && have="yes"
    check "$label" "$want" "$have"
}

# =====================================================================
printf '== fork-sandbox-inbox-hook.sh: the threshold arithmetic ==\n'
# =====================================================================

# Command substitution runs a function in its own subshell, so an append to
# tmpdirs made INSIDE either of these would vanish with that subshell instead
# of reaching the array the EXIT trap actually reads (the same gotcha
# fork-sandbox-prompt-overlay-test.sh's new_project documents). Registering
# the result is the CALLER's job here.
new_inbox() {
    mktemp -d
}

# A transcript in the shape the hook reads: the last line is an assistant
# message carrying usage, the way Claude Code's own transcript does.
new_transcript() {
    local input="$1" cache_read="$2" cache_write="$3" dir f
    dir="$(mktemp -d)"
    f="$dir/transcript.jsonl"
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$f"
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
        "$input" "$cache_read" "$cache_write" >> "$f"
    printf '%s' "$f"
}

hook_run() {
    # The env prefix has to sit directly on "$hook", the SECOND command of
    # the pipe -- on jq, upstream of the pipe, it would only ever be seen by
    # jq itself. baseline_marker falls back to a per-call throwaway path
    # when a test never set one, so the cases above that predate
    # CEILING_TOKENS need no changes.
    local inbox="$1" event="$2" transcript="$3"
    jq -n --arg ev "$event" --arg t "$transcript" \
        '{hook_event_name: $ev, transcript_path: $t}' \
    | FORK_SANDBOX_INBOX="$inbox" \
        FORK_SANDBOX_INBOX_SEEN="$inbox/../seen-$$" \
        FORK_SANDBOX_NUDGE_MARKER="$nudge_marker" \
        FORK_SANDBOX_NUDGE_REMINDED="$nudge_reminded" \
        FORK_SANDBOX_STALE_REMINDED="$stale_reminded" \
        FORK_SANDBOX_NUDGE_BASELINE="${baseline_marker:-$(mktemp -u)}" \
        "$hook" 2>/dev/null
}

# Same call, but stderr (the nudge line, including the effective threshold
# it names) lands in $hook_stderr instead of being thrown away, without
# capturing it via a command substitution -- which would fork a subshell
# and lose the assignment the moment it returned (the same gotcha
# new_inbox's own comment documents). Redirecting straight to a file
# sidesteps that: nothing here relies on a variable assignment made inside
# the pipeline surviving past it, only the file's contents read back in
# this function's own frame.
hook_run_stderr() {
    local inbox="$1" event="$2" transcript="$3" err_file
    err_file="$(mktemp -u)"; tmpdirs+=("$err_file")
    jq -n --arg ev "$event" --arg t "$transcript" \
        '{hook_event_name: $ev, transcript_path: $t}' \
    | FORK_SANDBOX_INBOX="$inbox" \
        FORK_SANDBOX_INBOX_SEEN="$inbox/../seen-$$" \
        FORK_SANDBOX_NUDGE_MARKER="$nudge_marker" \
        FORK_SANDBOX_NUDGE_REMINDED="$nudge_reminded" \
        FORK_SANDBOX_STALE_REMINDED="$stale_reminded" \
        FORK_SANDBOX_NUDGE_BASELINE="${baseline_marker:-$(mktemp -u)}" \
        "$hook" > /dev/null 2> "$err_file"
    hook_stderr="$(cat "$err_file" 2>/dev/null)"
}

# Below the threshold: 100 total tokens against a 1000-token cap.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\n' "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
transcript="$(new_transcript 60 30 10)"; tmpdirs+=("$(dirname "$transcript")")
out="$(hook_run "$inbox" PostToolUse "$transcript")"
check "usage below threshold: no nudge" "" "$out"
marker "usage below threshold: no marker written" "$nudge_marker" no

# At the threshold: input + cache_read + cache_write sums to exactly 1000.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\n' "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
transcript="$(new_transcript 700 250 50)"; tmpdirs+=("$(dirname "$transcript")")
out="$(hook_run "$inbox" PostToolUse "$transcript")"
contains "usage at threshold: nudge fires as additionalContext" \
    "this run refreshes itself" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
contains "the nudge names the outbox hand-off path" \
    "$inbox/outbox/handoff.md" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
contains "the nudge says the hand-off must not restate the brief" \
    "must NOT restate the brief" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
contains "the nudge asks for a per-item list against the brief's own headings" \
    "item by item, using the brief's own numbering or headings" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
contains "the nudge forbids compressing remaining items into a summary" \
    "Never compress remaining items into" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
contains "the nudge asks for a rewrite if more work happens before the turn ends" \
    "rewrite it before you end your turn" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
marker "the nudge marker is written" "$nudge_marker" yes

# Delivered once: the marker means the next call, even well over threshold,
# does not measure again or nudge again.
out="$(hook_run "$inbox" PostToolUse "$transcript")"
check "a nudged leg is not nudged twice" "" "$out"

# The Stop reminder: nudged, no hand-off in the outbox yet.
out="$(hook_run "$inbox" Stop "$transcript")"
check "Stop after a nudge with no hand-off blocks" \
    "block" "$(printf '%s' "$out" | jq -r '.decision')"
contains "the reminder says it is the only one" \
    "only reminder" "$(printf '%s' "$out" | jq -r '.reason')"
marker "the reminder marker is written" "$nudge_reminded" yes

# A leg must never be trapped: the next Stop lets it through.
out="$(hook_run "$inbox" Stop "$transcript")"
check "a second Stop is not blocked again" "" "$out"

# Once a hand-off exists, Stop does not remind at all.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\n' "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
transcript="$(new_transcript 900 100 50)"; tmpdirs+=("$(dirname "$transcript")")
hook_run "$inbox" PostToolUse "$transcript" >/dev/null
printf 'the hand-off\n' > "$inbox/outbox/handoff.md"
out="$(hook_run "$inbox" Stop "$transcript")"
check "Stop with a hand-off already written does not block" "" "$out"

# --refresh-at Bug B: a hand-off older than the clone's last commit blocks
# the next Stop once, asking for a rewrite. touch -d gives deterministic
# mtimes rather than relying on sleeps.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
clone="$(mktemp -d)"; tmpdirs+=("$clone")
mkdir -p "$clone/.git/logs"
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\nCLONE_DIR=%s\n' "$inbox" "$clone" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
# Already nudged, so measure_usage is 0 and the hand-off already in the
# outbox keeps the nudged-but-not-reminded clause quiet too: the only thing
# left that can set need_work is the staleness check itself, which is the
# thing this block means to exercise.
: > "$nudge_marker"
transcript="$(new_transcript 60 30 10)"; tmpdirs+=("$(dirname "$transcript")")
printf 'the hand-off\n' > "$inbox/outbox/handoff.md"
touch -d '2026-01-01 00:00:00' "$inbox/outbox/handoff.md"
touch -d '2026-01-01 00:01:00' "$clone/.git/logs/HEAD"
out="$(hook_run "$inbox" Stop "$transcript")"
check "a hand-off older than the last commit blocks the Stop" \
    "block" "$(printf '%s' "$out" | jq -r '.decision')"
contains "the stale block names the hand-off path" \
    "$inbox/outbox/handoff.md" "$(printf '%s' "$out" | jq -r '.reason')"
contains "the stale block says it is the only one" \
    "only such reminder" "$(printf '%s' "$out" | jq -r '.reason')"
marker "the stale-reminded marker is written" "$stale_reminded" yes

# A leg must never be trapped: the next Stop lets it through.
out="$(hook_run "$inbox" Stop "$transcript")"
check "a second Stop after a stale block is not blocked again" "" "$out"

# A hand-off NEWER than the last commit is not stale: no block.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
clone="$(mktemp -d)"; tmpdirs+=("$clone")
mkdir -p "$clone/.git/logs"
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\nCLONE_DIR=%s\n' "$inbox" "$clone" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
touch -d '2026-01-01 00:00:00' "$clone/.git/logs/HEAD"
printf 'the hand-off\n' > "$inbox/outbox/handoff.md"
touch -d '2026-01-01 00:01:00' "$inbox/outbox/handoff.md"
out="$(hook_run "$inbox" Stop "$transcript")"
check "a hand-off newer than the last commit does not block" "" "$out"

# PostToolUse never blocks, and never mentions staleness, even when the
# hand-off IS stale -- only the actual end of turn is the boundary that
# matters.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
clone="$(mktemp -d)"; tmpdirs+=("$clone")
mkdir -p "$clone/.git/logs"
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\nCLONE_DIR=%s\n' "$inbox" "$clone" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
printf 'the hand-off\n' > "$inbox/outbox/handoff.md"
touch -d '2026-01-01 00:00:00' "$inbox/outbox/handoff.md"
touch -d '2026-01-01 00:01:00' "$clone/.git/logs/HEAD"
out="$(hook_run "$inbox" PostToolUse "$transcript")"
check "PostToolUse with a stale hand-off emits nothing about it" "" "$out"

# No .git/logs/HEAD at all (a clone that has never diverged): the check is
# skipped rather than treated as stale.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
clone="$(mktemp -d)"; tmpdirs+=("$clone")
printf 'THRESHOLD_TOKENS=1000\nOUTBOX_DIR=%s/outbox\nCLONE_DIR=%s\n' "$inbox" "$clone" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
printf 'the hand-off\n' > "$inbox/outbox/handoff.md"
out="$(hook_run "$inbox" Stop "$transcript")"
check "no .git/logs/HEAD at all means no stale block" "" "$out"

# No refresh config at all: the mechanism is fully inert, and an addendum
# still works exactly as it always did.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'do the other thing\n' > "$inbox/1724650001-01.md"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
out="$(hook_run "$inbox" PostToolUse "/nonexistent/transcript.jsonl")"
contains "with no refresh config, addenda still deliver" \
    "$inbox/1724650001-01.md" "$out"

# =====================================================================
printf '\n== fork-sandbox-inbox-hook.sh: the per-leg budget (CEILING_TOKENS) ==\n'
# =====================================================================
# eff = max(T, min(B + T, CEILING)), B being the first usage_tokens reading
# this leg ever took. Each case below drives the hook through a sequence of
# calls on the SAME leg (same marker files), each with a transcript naming
# that call's own usage, so B is set by the first call and every later
# call's nudge decision can be checked against the formula directly.

# No CEILING at all (an older launcher's config): the leg nudges at exactly
# T, same as before this feature existed, regardless of its own baseline.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=100000\nOUTBOX_DIR=%s/outbox\n' "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
baseline_marker="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded" "$baseline_marker")
t="$(new_transcript 60000 0 0)"; tmpdirs+=("$(dirname "$t")")
out="$(hook_run "$inbox" PostToolUse "$t")"
check "no CEILING, usage 60000 < T 100000: no nudge" "" "$out"
t="$(new_transcript 100000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run_stderr "$inbox" PostToolUse "$t"
contains "no CEILING: nudges at exactly T" \
    "nudged (usage >= 100000 tokens)" "$hook_stderr"

# B=55000, T=100000, C=160000: eff = min(55000+100000, 160000) = 155000.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=100000\nOUTBOX_DIR=%s/outbox\nCEILING_TOKENS=160000\n' \
    "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
baseline_marker="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded" "$baseline_marker")
t="$(new_transcript 55000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run "$inbox" PostToolUse "$t" >/dev/null
check "the first measurement writes the baseline" "55000" "$(cat "$baseline_marker" 2>/dev/null)"
t="$(new_transcript 120000 0 0)"; tmpdirs+=("$(dirname "$t")")
out="$(hook_run "$inbox" PostToolUse "$t")"
check "B=55000: usage 120000 < eff 155000: no nudge" "" "$out"
check "a later measurement does not overwrite the baseline" \
    "55000" "$(cat "$baseline_marker" 2>/dev/null)"
t="$(new_transcript 155000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run_stderr "$inbox" PostToolUse "$t"
contains "B=55000: nudges at eff 155000, not T alone" \
    "nudged (usage >= 155000 tokens)" "$hook_stderr"

# B=20000, T=100000, C=160000: eff = min(20000+100000, 160000) = 120000.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=100000\nOUTBOX_DIR=%s/outbox\nCEILING_TOKENS=160000\n' \
    "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
baseline_marker="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded" "$baseline_marker")
t="$(new_transcript 20000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run "$inbox" PostToolUse "$t" >/dev/null
t="$(new_transcript 120000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run_stderr "$inbox" PostToolUse "$t"
contains "B=20000: nudges at eff 120000" \
    "nudged (usage >= 120000 tokens)" "$hook_stderr"

# T=180000, C=160000: eff = max(180000, min(B+180000, 160000)) = 180000 --
# never lowered below the launcher's own explicit threshold.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=180000\nOUTBOX_DIR=%s/outbox\nCEILING_TOKENS=160000\n' \
    "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
baseline_marker="$(mktemp -u)"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded" "$baseline_marker")
t="$(new_transcript 50000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run "$inbox" PostToolUse "$t" >/dev/null
t="$(new_transcript 160000 0 0)"; tmpdirs+=("$(dirname "$t")")
out="$(hook_run "$inbox" PostToolUse "$t")"
check "T above C: usage at C alone (160000) does not nudge" "" "$out"
t="$(new_transcript 180000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run_stderr "$inbox" PostToolUse "$t"
contains "T above C: nudges at T (180000), never lowered to C" \
    "nudged (usage >= 180000 tokens)" "$hook_stderr"

# A baseline that cannot be written (its directory does not exist) must fall
# back to eff = T, not to "this call's own usage is B": with usage 110000 and
# T=100000, C=160000 the second reading would put eff at the ceiling and the
# nudge would silently wait for 160000 on every call.
inbox="$(new_inbox)"; tmpdirs+=("$inbox")
printf 'THRESHOLD_TOKENS=100000\nOUTBOX_DIR=%s/outbox\nCEILING_TOKENS=160000\n' \
    "$inbox" > "$inbox/.refresh-config"
mkdir -p "$inbox/outbox"
nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
baseline_marker="$inbox/no-such-dir/baseline"
tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded")
t="$(new_transcript 110000 0 0)"; tmpdirs+=("$(dirname "$t")")
hook_run_stderr "$inbox" PostToolUse "$t"
contains "an unwritable baseline falls back to T: first call nudges at 100000" \
    "nudged (usage >= 100000 tokens)" "$hook_stderr"
rm -f -- "$nudge_marker"
hook_run_stderr "$inbox" PostToolUse "$t"
contains "an unwritable baseline falls back to T: a later call nudges at 100000 too" \
    "nudged (usage >= 100000 tokens)" "$hook_stderr"
marker "an unwritable baseline leaves no stray .tmp behind" "$baseline_marker.tmp.$$" no
unset baseline_marker

# Concurrent first measurements: every racing call must end up using the ONE
# baseline that landed (110000 -> eff 160000), so none of them nudges at
# usage 110000. A loser that treated its failed publish as "unwritable"
# would fall back to T=100000 and nudge. Repeated rounds, since the race is
# timing-dependent.
race_nudges=0
for _ in 1 2 3 4 5 6; do
    inbox="$(new_inbox)"; tmpdirs+=("$inbox")
    printf 'THRESHOLD_TOKENS=100000\nOUTBOX_DIR=%s/outbox\nCEILING_TOKENS=160000\n' \
        "$inbox" > "$inbox/.refresh-config"
    mkdir -p "$inbox/outbox"
    nudge_marker="$(mktemp -u)"; nudge_reminded="$(mktemp -u)"; stale_reminded="$(mktemp -u)"
    baseline_marker="$(mktemp -u)"
    tmpdirs+=("$nudge_marker" "$nudge_reminded" "$stale_reminded" "$baseline_marker")
    t="$(new_transcript 110000 0 0)"; tmpdirs+=("$(dirname "$t")")
    race_dir="$(mktemp -d)"; tmpdirs+=("$race_dir")
    for i in 1 2 3 4 5 6 7 8; do
        jq -n --arg t "$t" '{hook_event_name: "PostToolUse", transcript_path: $t}' \
        | FORK_SANDBOX_INBOX="$inbox" \
            FORK_SANDBOX_INBOX_SEEN="$inbox/../seen-$$" \
            FORK_SANDBOX_NUDGE_MARKER="$nudge_marker" \
            FORK_SANDBOX_NUDGE_REMINDED="$nudge_reminded" \
            FORK_SANDBOX_STALE_REMINDED="$stale_reminded" \
            FORK_SANDBOX_NUDGE_BASELINE="$baseline_marker" \
            "$hook" > /dev/null 2> "$race_dir/err-$i" &
    done
    wait
    race_nudges=$(( race_nudges + $(cat "$race_dir"/err-* | grep -c 'nudged' || true) ))
done
check "racing first measurements: none falls back to T and nudges" "0" "$race_nudges"
unset baseline_marker

# =====================================================================
printf '\n== the outer loop: real fork-sandbox.sh runs, claude-sandboxed stubbed ==\n'
# =====================================================================

# Every real fork-sandbox.sh fixture below runs under this scratch HOME, not
# the operator's: sandbox-run-log.py's archive dir and run log are
# deliberately hardcoded under ~/.claude (no flag can aim them elsewhere),
# so a fixture run under the real HOME appends handoff archives that are
# indistinguishable from an operator's real work. A scratch HOME also
# empties the launcher's ${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/
# fork-sandbox}, so machine config -- credential balancing above all --
# cannot route a fixture run, nor refuse it outright when the machine's
# live quota is tight.
launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
# The launcher's own security boundary requires the project to live under
# ~/src -- which it resolves against the scratch HOME above, so fixture
# projects must live there too.
mkdir -p "$launcher_home/src"
# --review-loop (the fix-leg refresh scenario, below) refuses to start
# unless the review kit's skill directories exist under $HOME/.claude/
# skills -- real content is never read, only the path is quoted into the
# review prompt, so an empty directory satisfies it. Same fixture
# fork-sandbox-review-harness-test.sh and fork-sandbox-maintainer-test.sh
# already set up.
mkdir -p "$launcher_home/.claude/skills/commit-then-review" \
    "$launcher_home/.claude/skills/code-review-portable"
operator_archive_dir="$HOME/.claude/sandbox-handoffs"

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely and simulates a claude
# session's observable effect on the parts fork-sandbox.sh's outer refresh
# loop reacts to. Which invocation this is (1 = implement leg, 2 = first
# continuation, ...) comes from a counter file so a scenario can control each
# leg independently; FAKE_NUDGE_LEGS, FAKE_HANDOFF_LEGS, FAKE_SYMLINK_LEGS,
# FAKE_FAIL_LEGS, FAKE_STALE_LEGS, FAKE_ADDENDUM_LEGS, FAKE_MAIL_BANNER_LEGS
# and FAKE_NOCOMMIT_LEGS are comma lists of leg numbers (or the literal
# "all"), read fresh per call. A leg that writes a hand-off also commits a
# tiny change in the clone by default -- a real leg that hands off has
# almost always committed something first, and the stall-stop machinery
# needs a way to tell a leg that DIDN'T apart from one that did.
# FAKE_NOCOMMIT_LEGS opts a leg out of that default commit, to simulate a
# stall. FAKE_OUTBOX_LEGS makes a leg write reply-<n>.md into the outbox (the
# progress a seat that never commits makes), before its hand-off.
set -uo pipefail

outbox=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--bind-rw" ]] && outbox="$a"
    prev="$a"
done

# Captured, not drained: FAKE_VERDICT_*_LEGS (below) need the verdict path
# the real prompt names, the same way fork-sandbox-preset-test.sh's own
# stub reads it.
prompt="$(cat)"

n=0
[[ -f "$FAKE_CLAUDE_COUNT_FILE" ]] && n="$(cat "$FAKE_CLAUDE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_CLAUDE_COUNT_FILE"

# Optional, same shape as fork-sandbox-preset-test.sh's own stub: one line
# of "$*" per call, for scenarios that need to see a leg's actual argv
# (a seat's own extra arguments, say) rather than just its count and effect.
[[ -n "${FAKE_ARGV_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"

# The stub runs on the bare host, not inside bwrap, so it can read the
# inbox's own .refresh-config directly -- fs_refresh_arm writes it before
# EVERY armed leg and fs_refresh_disarm removes it right after, so a
# snapshot taken here, mid-leg, is the only way a test gets to see what
# THIS leg was actually armed with (property 3: each leg's own model's
# window). Harmless when unarmed: the file is simply absent then.
if [[ -n "$outbox" ]]; then
    snapshot_run_dir="$(dirname "$outbox")"
    if [[ -f "$snapshot_run_dir/inbox/.refresh-config" ]]; then
        cp -f "$snapshot_run_dir/inbox/.refresh-config" \
            "$snapshot_run_dir/refresh-config-snapshot-$n" 2>/dev/null
    fi
fi

nudge_legs=",${FAKE_NUDGE_LEGS:-},"
handoff_legs=",${FAKE_HANDOFF_LEGS:-},"
symlink_legs=",${FAKE_SYMLINK_LEGS:-},"
fail_legs=",${FAKE_FAIL_LEGS:-},"
stale_legs=",${FAKE_STALE_LEGS:-},"
addendum_legs=",${FAKE_ADDENDUM_LEGS:-},"
nocommit_legs=",${FAKE_NOCOMMIT_LEGS:-},"
# Composed-pipeline fixtures (the per-leg refresh tests, below): a plan
# leg's own output (no commit -- a plan leg that commits fails the run);
# a review/maintain leg's verdict, FINDINGS or APPROVED, written to
# whichever path the prompt itself names (same grep
# fork-sandbox-preset-test.sh's own stub uses); a plain commit with no
# hand-off, for an implement/code leg this scenario does not want to
# refresh.
plan_legs=",${FAKE_PLAN_LEGS:-},"
verdict_findings_legs=",${FAKE_VERDICT_FINDINGS_LEGS:-},"
verdict_approved_legs=",${FAKE_VERDICT_APPROVED_LEGS:-},"
commit_legs=",${FAKE_COMMIT_LEGS:-},"

# The stub bypasses bwrap and its --bind-ro entirely, so it can write into
# the inbox the same way a real fork-sandbox-say.sh would -- found the same
# way the outbox already is here, as the run dir's own "inbox" sibling.
if [[ -n "$outbox" ]] \
    && { [[ "${FAKE_ADDENDUM_LEGS:-}" == "all" ]] || [[ "$addendum_legs" == *",$n,"* ]]; }; then
    run_dir_for_addendum="$(dirname "$outbox")"
    if [[ -d "$run_dir_for_addendum/inbox" ]]; then
        printf 'operator addendum for leg %s\n' "$n" \
            > "$run_dir_for_addendum/inbox/9999999900-0$n.md"
    fi
fi

# Same trick for a mail banner: fork-sandbox-postmaster.sh's pm_deliver_live
# writes 'mail-banner-<nnn>-<shortid>.md' into a live run's own inbox, so the
# stub drops one in the same shape to exercise fs_archive_inbox's separate
# handling of it.
mail_banner_legs=",${FAKE_MAIL_BANNER_LEGS:-},"
if [[ -n "$outbox" ]] \
    && { [[ "${FAKE_MAIL_BANNER_LEGS:-}" == "all" ]] || [[ "$mail_banner_legs" == *",$n,"* ]]; }; then
    run_dir_for_banner="$(dirname "$outbox")"
    if [[ -d "$run_dir_for_banner/inbox" ]]; then
        printf 'mail banner for leg %s\n' "$n" \
            > "$run_dir_for_banner/inbox/mail-banner-00$n-deadbeef.md"
    fi
fi

if [[ "${FAKE_NUDGE_LEGS:-}" == "all" || "$nudge_legs" == *",$n,"* ]]; then
    printf '{"type":"system","subtype":"hook_response","stderr":"fork-sandbox-refresh: nudged (usage >= 1 tokens)\\n"}\n'
fi
if [[ -n "$outbox" ]] \
    && { [[ "${FAKE_PLAN_LEGS:-}" == "all" ]] || [[ "$plan_legs" == *",$n,"* ]]; }; then
    plan_run_dir="$(dirname "$outbox")"
    mkdir -p "$plan_run_dir/outbox"
    printf '# Plan\n\n## Mechanism\n\nStub plan body from call %s.\n' "$n" \
        > "$plan_run_dir/outbox/plan.md"
elif { [[ "${FAKE_VERDICT_FINDINGS_LEGS:-}" == "all" ]] || [[ "$verdict_findings_legs" == *",$n,"* ]]; } \
    || { [[ "${FAKE_VERDICT_APPROVED_LEGS:-}" == "all" ]] || [[ "$verdict_approved_legs" == *",$n,"* ]]; }; then
    verdict_clone_dir=""
    for a in "$@"; do
        [[ -d "$a/.git" ]] && verdict_clone_dir="$a"
    done
    verdict_name="$(printf '%s\n' "$prompt" \
        | sed -nE 's#.*\.git/(s[0-9]+-verdict\.md|maintainer-verdict\.md|review-verdict\.md).*#\1#p' \
        | head -1)"
    [[ -n "$verdict_name" ]] || verdict_name=review-verdict.md
    if [[ -n "$verdict_clone_dir" ]]; then
        if [[ "${FAKE_VERDICT_FINDINGS_LEGS:-}" == "all" ]] || [[ "$verdict_findings_legs" == *",$n,"* ]]; then
            printf 'FINDINGS\n\nfile.txt:1 the stub found a problem on call %s\n\n## Report\nIgnore this.\n' "$n" \
                > "$verdict_clone_dir/.git/$verdict_name"
        else
            printf 'APPROVED\n\nChecked: everything on call %s.\n\n## Report\nFine.\n' "$n" \
                > "$verdict_clone_dir/.git/$verdict_name"
        fi
    fi
elif [[ "${FAKE_COMMIT_LEGS:-}" == "all" || "$commit_legs" == *",$n,"* ]]; then
    commit_clone_dir=""
    for a in "$@"; do
        [[ -d "$a/.git" ]] && commit_clone_dir="$a"
    done
    if [[ -n "$commit_clone_dir" ]]; then
        git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            -C "$commit_clone_dir" commit --allow-empty -q -m "stub commit from leg $n"
    fi
elif [[ "${FAKE_SYMLINK_LEGS:-}" == "all" || "$symlink_legs" == *",$n,"* ]]; then
    [[ -n "$outbox" ]] && ln -sf "${FAKE_SYMLINK_TARGET:-/etc/hostname}" "$outbox/handoff.md"
elif [[ "${FAKE_HANDOFF_LEGS:-}" == "all" || "$handoff_legs" == *",$n,"* ]]; then
    if [[ -n "$outbox" ]]; then
        # The clone is the run dir's own "clone/<name>" sibling of this
        # outbox.
        run_dir="$(dirname "$outbox")"
        clone_dir="$(find "$run_dir/clone" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
        # A leg that hands off has, in real use, almost always committed
        # something first -- so commit a tiny change by default, BEFORE the
        # hand-off is written (an on-time hand-off always postdates the
        # work it describes; writing it first would make every default
        # commit look stale to the host's own check), unless this leg
        # opted out (FAKE_NOCOMMIT_LEGS), which is how a scenario
        # simulates the stall the host-side loop is meant to catch: a leg
        # that leaves a hand-off without moving the branch.
        if [[ -n "$clone_dir" ]] \
            && ! { [[ "${FAKE_NOCOMMIT_LEGS:-}" == "all" ]] || [[ "$nocommit_legs" == *",$n,"* ]]; }; then
            ( cd "$clone_dir" \
                && printf 'leg %s\n' "$n" >> fake-refresh-progress.txt \
                && git add fake-refresh-progress.txt \
                && git commit -q -m "fake progress from leg $n" ) >/dev/null 2>&1
        fi
        if [[ "${FAKE_OUTBOX_LEGS:-}" == "all" ]] || [[ ",${FAKE_OUTBOX_LEGS:-}," == *",$n,"* ]]; then
            printf 'reply from leg %s\n' "$n" > "$outbox/reply-$n.md"
        fi
        printf 'HANDOFF from leg %s\n' "$n" > "$outbox/handoff.md"
        # The host's stale-hand-off backstop compares this hand-off's mtime
        # against the clone's HEAD reflog -- touch its reflog into the
        # future, deterministically, rather than racing a real mtime.
        if [[ "${FAKE_STALE_LEGS:-}" == "all" || "$stale_legs" == *",$n,"* ]] \
            && [[ -n "$clone_dir" && -f "$clone_dir/.git/logs/HEAD" ]]; then
            touch -d '+1 hour' "$clone_dir/.git/logs/HEAD"
        fi
    fi
fi

if [[ "${FAKE_FAIL_LEGS:-}" == "all" || "$fail_legs" == *",$n,"* ]]; then
    printf '{"type":"result","subtype":"error_during_execution","total_cost_usd":0.0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    exit 1
fi

if [[ -n "${FAKE_CONTEXT_WINDOW:-}" ]]; then
    printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"modelUsage":{"fake-model":{"contextWindow":%s}}}\n' "$FAKE_CONTEXT_WINDOW"
    exit 0
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

new_project() {
    local d
    d="$(mktemp -d "$launcher_home/src/fs-refresh-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# $1 project  $2 count-file  $3 nudge-legs  $4 handoff-legs  rest: extra launcher args
run_real() {
    local proj="$1" count_file="$2" nudge_legs="$3" handoff_legs="$4"
    shift 4
    local handoff_dir handoff out rc rd branch_name
    handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-handoff.XXXXXX)"
    # Appending to tmpdirs here would land in this function's own frame, not
    # the EXIT trap's array -- run_real is always called as a command
    # substitution, which forks a subshell (see the new_inbox comment above).
    # This dir is only needed for the launcher call below, so it is cleaned
    # up on every return from this function instead of being registered.
    trap 'rm -rf -- "$handoff_dir"' RETURN
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    # FAKE_BRIEF_PAD_BYTES: pad the brief to at least this many bytes, to
    # exercise the launch warning for a large brief.
    if [[ -n "${FAKE_BRIEF_PAD_BYTES:-}" ]]; then
        head -c "$FAKE_BRIEF_PAD_BYTES" /dev/zero | tr '\0' 'x' >> "$handoff"
        printf '\n' >> "$handoff"
    fi
    : > "$count_file"
    # A leg that writes a hand-off now also commits by default (the stub's
    # own doc comment explains why), so a run that used to leave the
    # default timestamped branch name unclaimed (removed at the end for
    # having zero commits) now often keeps it -- and the default name's
    # second resolution collides across this suite's own rapid-fire calls.
    # An explicit, unique name per call sidesteps that instead of relying
    # on wall-clock spacing.
    branch_name="fs-refresh-test-$(date +%s%N)-$RANDOM"
    # A composed pipeline (--pipeline) or a composed preset (--preset) names
    # its own per-step harness in each segment and refuses an explicit
    # --harness entirely -- so this scans the extra args for either rather
    # than hardcoding --harness claude unconditionally the way every other
    # scenario here wants.
    local -a harness_flag=(--harness claude) extra_arg
    for extra_arg in "$@"; do
        [[ "$extra_arg" == "--pipeline" || "$extra_arg" == "--preset" ]] && harness_flag=()
    done
    out="$(HOME="$launcher_home" PATH="$stub_bin:$PATH" \
        FAKE_CLAUDE_COUNT_FILE="$count_file" \
        FAKE_NUDGE_LEGS="$nudge_legs" \
        FAKE_HANDOFF_LEGS="$handoff_legs" \
        FAKE_SYMLINK_LEGS="${FAKE_SYMLINK_LEGS:-}" \
        FAKE_SYMLINK_TARGET="${FAKE_SYMLINK_TARGET:-}" \
        FAKE_FAIL_LEGS="${FAKE_FAIL_LEGS:-}" \
        FAKE_STALE_LEGS="${FAKE_STALE_LEGS:-}" \
        FAKE_ADDENDUM_LEGS="${FAKE_ADDENDUM_LEGS:-}" \
        FAKE_MAIL_BANNER_LEGS="${FAKE_MAIL_BANNER_LEGS:-}" \
        FAKE_NOCOMMIT_LEGS="${FAKE_NOCOMMIT_LEGS:-}" \
        FAKE_OUTBOX_LEGS="${FAKE_OUTBOX_LEGS:-}" \
        FAKE_CONTEXT_WINDOW="${FAKE_CONTEXT_WINDOW:-}" \
        FAKE_PLAN_LEGS="${FAKE_PLAN_LEGS:-}" \
        FAKE_VERDICT_FINDINGS_LEGS="${FAKE_VERDICT_FINDINGS_LEGS:-}" \
        FAKE_VERDICT_APPROVED_LEGS="${FAKE_VERDICT_APPROVED_LEGS:-}" \
        FAKE_COMMIT_LEGS="${FAKE_COMMIT_LEGS:-}" \
        FAKE_ARGV_LOG="${FAKE_ARGV_LOG:-}" \
        timeout 60 "$launcher" --foreground "${harness_flag[@]}" --branch "$branch_name" "$@" \
        "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    # A non-zero $rc is not itself a failure of the harness under test here:
    # the launcher's own exit mirrors a crashed leg's, which is exactly what
    # the leg-error scenario means to produce. Only a missing run dir means
    # this call never got far enough to be worth inspecting.
    if [[ -z "$rd" ]]; then
        printf 'run_real failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

proj="$(new_project)"; tmpdirs+=("$proj")

# -- the happy path: leg 1 is nudged and writes a hand-off, leg 2 finishes
# comfortably on its own. Two legs total, ended empty-outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "two legs ran (implement + one continuation)" \
        "2" "$(cat "$count_file")"
    check "handoff-1.md is the record" \
        "HANDOFF from leg 1" "$(cat "$rd/handoff-1.md" 2>/dev/null)"
    cont_prompt="$rd/continuation-prompt-1.md"
    if [[ -f "$cont_prompt" ]]; then
        ok "the continuation prompt file exists"
        contains "leg 2's prompt carries the continuation line" \
            "This is continuation 1 of a run that refreshed its context" \
            "$(cat "$cont_prompt")"
        contains "leg 2's prompt carries the hand-off text" \
            "HANDOFF from leg 1" "$(cat "$cont_prompt")"
        contains "leg 2's prompt carries the original brief's text" \
            "do the task" "$(cat "$cont_prompt")"
        contains "leg 2's prompt has the original-brief heading" \
            "## The original brief" "$(cat "$cont_prompt")"
        contains "leg 2's prompt has the hand-off heading" \
            "## Hand-off from the previous leg" "$(cat "$cont_prompt")"
        # The continuation header carries the same headless-turn warning as
        # the leg-1 coding prompt: a continuation is still a leg that edits,
        # with no verdict file to fall back on.
        contains "leg 2's prompt warns nothing wakes it for a background result" \
            "wakes you later to deliver a background command's result" \
            "$(cat "$cont_prompt")"
        contains "leg 2's prompt says only committed work leaves the sandbox" \
            "Only committed work leaves the sandbox" "$(cat "$cont_prompt")"
        if grep -q '## Warning: this hand-off is stale' "$cont_prompt"; then
            no "an on-time hand-off's prompt carries no stale warning"
        else
            ok "an on-time hand-off's prompt carries no stale warning"
        fi
        brief_at="$(grep -n '## The original brief' "$cont_prompt" | head -1 | cut -d: -f1)"
        handoff_at="$(grep -n '## Hand-off from the previous leg' "$cont_prompt" | head -1 | cut -d: -f1)"
        if [[ -n "$brief_at" && -n "$handoff_at" && "$brief_at" -lt "$handoff_at" ]]; then
            ok "the brief heading appears before the hand-off heading"
        else
            no "the brief heading appears before the hand-off heading" \
                "brief at line $brief_at, hand-off at line $handoff_at"
        fi
    else
        no "the continuation prompt file exists"
        no "leg 2's prompt carries the continuation line"
        no "leg 2's prompt carries the hand-off text"
        no "leg 2's prompt carries the original brief's text"
        no "leg 2's prompt has the original-brief heading"
        no "leg 2's prompt has the hand-off heading"
        no "leg 2's prompt warns nothing wakes it for a background result"
        no "leg 2's prompt says only committed work leaves the sandbox"
        no "an on-time hand-off's prompt carries no stale warning"
        no "the brief heading appears before the hand-off heading"
    fi
    check "handoff-original.md is the raw handoff, byte for byte" \
        "do the task" "$(cat "$rd/handoff-original.md" 2>/dev/null)"
    if [[ -f "$rd/summary.json" ]]; then
        check "summary.json has one continuation" \
            "1" "$(jq '.continuations | length' "$rd/summary.json")"
        check "summary.json's refresh field is empty-outbox" \
            "empty-outbox" "$(jq -r '.refresh' "$rd/summary.json")"
        check "the continuation's leg number is 2" \
            "2" "$(jq -r '.continuations[0].leg' "$rd/summary.json")"
        check "an on-time hand-off is not marked stale in summary.json" \
            "false" "$(jq -r '.continuations[0].handoff_stale' "$rd/summary.json")"
    else
        no "summary.json has one continuation" "no summary.json"
        no "summary.json's refresh field is empty-outbox" "no summary.json"
        no "the continuation's leg number is 2" "no summary.json"
        no "an on-time hand-off is not marked stale in summary.json" "no summary.json"
    fi
fi

# -- a large brief: the launch warning goes to the launching terminal (the
# captured output run_real parses) AND, exactly once, into the run's own
# sandbox.log -- which is created after the warning is computed, so it has to
# be carried there rather than appended early.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_BRIEF_PAD_BYTES=5000
rd="$(run_real "$proj" "$count_file" "" "" --refresh-at 1000)"
FAKE_BRIEF_PAD_BYTES=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -f "$rd/sandbox.log" ]]; then
    check "a large brief's launch warning is in sandbox.log exactly once" \
        "1" "$(grep -c 'this brief is [0-9]* bytes' "$rd/sandbox.log")"
else
    no "a large brief's launch warning is in sandbox.log exactly once" "no sandbox.log"
fi

# -- an addendum delivered to leg 1: archived out of inbox/ into its own
# inbox-delivered/leg-1 record the moment that leg ends, rather than sitting
# there for leg 2's fresh sandbox (fresh /tmp, same inbox bind) to re-read.
# fork-sandbox-status.sh's addenda count still sees it, from the archive.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_ADDENDUM_LEGS=1
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
FAKE_ADDENDUM_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    leftover="$(find "$rd/inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "the addendum is archived out of inbox/ once leg 1 ends" "0" "$leftover"
    archived="$(find "$rd/inbox-delivered/leg-1" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived" ]]; then
        ok "inbox-delivered/leg-1 holds the addendum"
        contains "the archived addendum keeps its text" \
            "operator addendum for leg 1" "$(cat "$archived")"
    else
        no "inbox-delivered/leg-1 holds the addendum"
        no "the archived addendum keeps its text"
    fi
    status_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd" 2>/dev/null)"
    contains "fork-sandbox-status.sh still counts the archived addendum" \
        "inbox:    1 addenda" "$status_out"

    # leg 1's addendum is archived before the continuation loop builds leg
    # 2's prompt, so it is already there to embed.
    cont_prompt="$rd/continuation-prompt-1.md"
    if [[ -f "$cont_prompt" ]]; then
        contains "the continuation prompt has the addenda heading" \
            "## Operator addenda delivered to earlier legs" "$(cat "$cont_prompt")"
        contains "the continuation prompt carries the addendum's own file name" \
            "9999999900-01.md" "$(cat "$cont_prompt")"
        contains "the continuation prompt carries the addendum's text" \
            "operator addendum for leg 1" "$(cat "$cont_prompt")"
        brief_at="$(grep -n '## The original brief' "$cont_prompt" | head -1 | cut -d: -f1)"
        addenda_at="$(grep -n '## Operator addenda delivered to earlier legs' "$cont_prompt" | head -1 | cut -d: -f1)"
        handoff_at="$(grep -n '## Hand-off from the previous leg' "$cont_prompt" | head -1 | cut -d: -f1)"
        if [[ -n "$brief_at" && -n "$addenda_at" && -n "$handoff_at" \
            && "$brief_at" -lt "$addenda_at" && "$addenda_at" -lt "$handoff_at" ]]; then
            ok "the addenda heading sits between the brief and the hand-off"
        else
            no "the addenda heading sits between the brief and the hand-off" \
                "brief at $brief_at, addenda at $addenda_at, hand-off at $handoff_at"
        fi
    else
        no "the continuation prompt has the addenda heading" "no continuation prompt"
        no "the continuation prompt carries the addendum's own file name" "no continuation prompt"
        no "the continuation prompt carries the addendum's text" "no continuation prompt"
        no "the addenda heading sits between the brief and the hand-off" "no continuation prompt"
    fi
fi

# -- a mail banner delivered to leg 1 alongside an addendum: both must leave
# inbox/ once leg 1 ends (a fresh leg-2 sandbox binds the same inbox_dir with
# a fresh, empty seen-list, so anything left behind is re-delivered from
# scratch), but only the addendum may come back as an "operator addendum"
# in leg 2's continuation prompt -- the banner is new thread information
# from the postmaster, not an operator instruction, and by the time
# fs_archive_inbox runs the Stop hook has already confirmed it was shown to
# leg 1 once, so it needs no re-surfacing at all.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_ADDENDUM_LEGS=1
FAKE_MAIL_BANNER_LEGS=1
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
FAKE_ADDENDUM_LEGS=""
FAKE_MAIL_BANNER_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    leftover="$(find "$rd/inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "the mail banner and the addendum both leave inbox/ once leg 1 ends" \
        "0" "$leftover"
    banner_archived="$(find "$rd/mail-delivered/leg-1" -maxdepth 1 \
        -name 'mail-banner-*' 2>/dev/null | head -1)"
    if [[ -n "$banner_archived" ]]; then
        ok "mail-delivered/leg-1 holds the banner"
        contains "the archived banner keeps its text" \
            "mail banner for leg 1" "$(cat "$banner_archived")"
    else
        no "mail-delivered/leg-1 holds the banner"
        no "the archived banner keeps its text"
    fi
    banner_in_inbox_delivered="$(find "$rd/inbox-delivered/leg-1" -maxdepth 1 \
        -name 'mail-banner-*' 2>/dev/null | head -1)"
    check "the banner is not archived under inbox-delivered/leg-1 too" \
        "" "$banner_in_inbox_delivered"
    status_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd" 2>/dev/null)"
    contains "fork-sandbox-status.sh counts the addendum but not the banner" \
        "inbox:    1 addenda" "$status_out"
    cont_prompt="$rd/continuation-prompt-1.md"
    if [[ -f "$cont_prompt" ]]; then
        contains "the continuation prompt still carries the addendum" \
            "operator addendum for leg 1" "$(cat "$cont_prompt")"
        # The static header's generic "a file named mail-banner-* ..."
        # sentence is expected in every continuation prompt -- this checks
        # for THIS banner's own file name and body text, not that mention.
        if grep -q 'mail-banner-001-deadbeef\.md\|mail banner for leg 1' "$cont_prompt"; then
            no "the continuation prompt carries no trace of the mail banner"
        else
            ok "the continuation prompt carries no trace of the mail banner"
        fi
    else
        no "the continuation prompt still carries the addendum" "no continuation prompt"
        no "the continuation prompt carries no trace of the mail banner" "no continuation prompt"
    fi
fi

# -- a mail banner delivered to leg 1 with no addendum at all: still leaves
# inbox/ (so it cannot be re-delivered to leg 2), and the continuation
# prompt gets no addenda heading at all, since there is nothing to embed.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_MAIL_BANNER_LEGS=1
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
FAKE_MAIL_BANNER_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    leftover="$(find "$rd/inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "a lone mail banner still leaves inbox/ once leg 1 ends" "0" "$leftover"
    cont_prompt="$rd/continuation-prompt-1.md"
    if [[ -f "$cont_prompt" ]]; then
        if grep -q '## Operator addenda delivered to earlier legs' "$cont_prompt"; then
            no "a lone mail banner adds no addenda heading to the continuation prompt"
        else
            ok "a lone mail banner adds no addenda heading to the continuation prompt"
        fi
    else
        no "a lone mail banner adds no addenda heading to the continuation prompt" \
            "no continuation prompt"
    fi
fi

# -- no addenda at all: a continuation prompt carries no addenda heading.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" && -f "$rd/continuation-prompt-1.md" ]]; then
    if grep -q '## Operator addenda delivered to earlier legs' "$rd/continuation-prompt-1.md"; then
        no "a run with no addenda has no addenda heading in its continuation prompt"
    else
        ok "a run with no addenda has no addenda heading in its continuation prompt"
    fi
else
    no "a run with no addenda has no addenda heading in its continuation prompt" \
        "no continuation prompt"
fi

# -- a hand-off that predates the clone's last commit by the time the host
# picks it up (the leg kept working after writing it and never rewrote it,
# or died before it could): the continuation prompt gets a warning block and
# summary.json's continuation entry is marked handoff_stale.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_STALE_LEGS=1
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
FAKE_STALE_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    cont_prompt="$rd/continuation-prompt-1.md"
    if [[ -f "$cont_prompt" ]]; then
        contains "a stale hand-off's continuation prompt carries the warning heading" \
            "## Warning: this hand-off is stale" "$(cat "$cont_prompt")"
    else
        no "a stale hand-off's continuation prompt carries the warning heading" \
            "no continuation prompt"
    fi
    check "summary.json marks the continuation's hand-off stale" \
        "true" "$(jq -r '.continuations[0].handoff_stale' "$rd/summary.json" 2>/dev/null)"
fi

# -- --refresh-max 0: the implement leg is nudged and writes a hand-off, but
# the cap is already exhausted, so no second leg ever runs.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5 --refresh-max 0)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "--refresh-max 0: only the implement leg ran" \
        "1" "$(cat "$count_file")"
    check "--refresh-max 0: summary.json has no continuations" \
        "0" "$(jq '.continuations | length' "$rd/summary.json" 2>/dev/null)"
    check "--refresh-max 0: refresh ended at the cap" \
        "cap" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
fi

# -- a stub that always writes a hand-off: the loop stops at the default cap
# (6), never running a 7th (uncapped) leg.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" all all --refresh-at 0.5)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "an always-refreshing run stops at 7 legs (1 + 6 continuations)" \
        "7" "$(cat "$count_file")"
    check "summary.json has six continuations" \
        "6" "$(jq '.continuations | length' "$rd/summary.json" 2>/dev/null)"
    check "refresh ended at the cap" \
        "cap" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
fi

# -- every leg sent its own addendum, over enough legs to reach a two-digit
# leg number: the central claim of "carry every earlier leg's addenda, not
# just the immediate predecessor's, oldest first" is otherwise never
# exercised -- the single-leg addendum scenario above only ever has ONE
# archived leg directory to embed, so an implementation that kept only the
# immediate predecessor's addenda (instead of all of them) or that sorted
# archive directories lexically instead of numerically ("leg-10" before
# "leg-2") would pass every other check in this file unchanged.
# --refresh-max 10 pushes the chain to 11 legs so a leg-10 exists to
# mis-sort against leg-2 if the numeric sort regressed to a lexical one.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_ADDENDUM_LEGS=all
rd="$(run_real "$proj" "$count_file" all all --refresh-at 0.5 --refresh-max 10)"
FAKE_ADDENDUM_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "an always-addending run still stops at 11 legs (1 + 10 continuations)" \
        "11" "$(cat "$count_file")"
    last_prompt="$rd/continuation-prompt-10.md"
    if [[ -f "$last_prompt" ]]; then
        # Anchored, not the substring-matching `contains` helper: "operator
        # addendum for leg 1" is itself a substring of "...leg 10", so a
        # plain `contains` for leg 1 would pass even if leg 1's own line
        # were missing and only leg 10's survived.
        if grep -q 'operator addendum for leg 1$' "$last_prompt"; then
            ok "leg 11's continuation prompt carries leg 1's addendum"
        else
            no "leg 11's continuation prompt carries leg 1's addendum"
        fi
        contains "leg 11's continuation prompt carries leg 9's addendum, not just leg 10's" \
            "operator addendum for leg 9" "$(cat "$last_prompt")"
        contains "leg 11's continuation prompt carries leg 10's own addendum" \
            "operator addendum for leg 10" "$(cat "$last_prompt")"
        leg2_at="$(grep -n 'operator addendum for leg 2$' "$last_prompt" | head -1 | cut -d: -f1)"
        leg10_at="$(grep -n 'operator addendum for leg 10$' "$last_prompt" | head -1 | cut -d: -f1)"
        if [[ -n "$leg2_at" && -n "$leg10_at" && "$leg2_at" -lt "$leg10_at" ]]; then
            ok "leg 2's addendum sorts before leg 10's (numeric, not lexical, leg order)"
        else
            no "leg 2's addendum sorts before leg 10's (numeric, not lexical, leg order)" \
                "leg 2 at $leg2_at, leg 10 at $leg10_at"
        fi
    else
        no "leg 11's continuation prompt carries leg 1's addendum" "no continuation prompt"
        no "leg 11's continuation prompt carries leg 9's addendum, not just leg 10's" "no continuation prompt"
        no "leg 11's continuation prompt carries leg 10's own addendum" "no continuation prompt"
        no "leg 2's addendum sorts before leg 10's (numeric, not lexical, leg order)" "no continuation prompt"
    fi
    if [[ -d "$rd/inbox-delivered/leg-10" && -d "$rd/inbox-delivered/leg-2" ]]; then
        ok "both leg-2 and leg-10 archive directories exist"
    else
        no "both leg-2 and leg-10 archive directories exist"
    fi
fi

# -- a nudge with no hand-off: the implement leg is nudged but never writes
# to the outbox, so the chain never starts and says why.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" 1 "" --refresh-at 0.5)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a nudge with no hand-off: only one leg ran" \
        "1" "$(cat "$count_file")"
    check "a nudge with no hand-off: no continuations" \
        "0" "$(jq '.continuations | length' "$rd/summary.json" 2>/dev/null)"
    check "a nudge with no hand-off logs no-handoff" \
        "no-handoff" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
fi

# -- a symlinked hand-off is refused, not followed: the leg is treated as
# having written nothing, and the secret the symlink points at never reaches
# any file this run produces (not the run-dir record, not the continuation
# prompt a later leg would have read).
secret_file="$(mktemp)"; tmpdirs+=("$secret_file")
printf 'TOP SECRET CONTENT\n' > "$secret_file"
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_SYMLINK_LEGS=1 FAKE_SYMLINK_TARGET="$secret_file"
rd="$(run_real "$proj" "$count_file" 1 "" --refresh-at 0.5)"
FAKE_SYMLINK_LEGS="" FAKE_SYMLINK_TARGET=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a symlinked hand-off: only one leg ran" "1" "$(cat "$count_file")"
    check "a symlinked hand-off: no continuations" \
        "0" "$(jq '.continuations | length' "$rd/summary.json" 2>/dev/null)"
    check "a symlinked hand-off: refresh ends no-handoff, not followed" \
        "no-handoff" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    if grep -rq 'TOP SECRET CONTENT' "$rd" 2>/dev/null; then
        no "a symlinked hand-off: the secret never appears in the run dir"
    else
        ok "a symlinked hand-off: the secret never appears in the run dir"
    fi
fi

# -- a continuation leg crashes: the chain reports leg-error rather than
# empty-outbox (which readers, including `stats --by refresh`, treat as a
# success), and a hand-off it wrote just before dying is recovered into the
# run dir rather than left sitting unmoved in the outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_FAIL_LEGS=2
rd="$(run_real "$proj" "$count_file" 1 "1,2" --refresh-at 0.5)"
FAKE_FAIL_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a crashed continuation: two legs ran" "2" "$(cat "$count_file")"
    check "a crashed continuation: refresh ends leg-error" \
        "leg-error" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    check "a crashed continuation: its non-zero exit is recorded" \
        "1" "$(jq -r '.continuations[0].exit' "$rd/summary.json" 2>/dev/null)"
    check "a crashed continuation: its hand-off is recovered into the run dir" \
        "HANDOFF from leg 2" "$(cat "$rd/handoff-leg-2-after-error.md" 2>/dev/null)"
fi

# -- a stall: a continuation leg (leg 2, the first one) leaves a hand-off
# without committing anything. The chain must end rather than fork a third
# leg from a hand-off that describes no real progress, and the stalled
# hand-off is kept as its own record rather than silently dropped.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_NOCOMMIT_LEGS=2
rd="$(run_real "$proj" "$count_file" "1,2" "1,2" --refresh-at 0.5)"
FAKE_NOCOMMIT_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a stalled continuation: only two legs ran" "2" "$(cat "$count_file")"
    check "a stalled continuation: refresh ends stalled" \
        "stalled" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    check "a stalled continuation: its hand-off is kept at handoff-stalled-2.md" \
        "HANDOFF from leg 2" "$(cat "$rd/handoff-stalled-2.md" 2>/dev/null)"
    check "a stalled continuation: no third leg's record exists" \
        "no" "$([[ -f "$rd/handoff-2.md" ]] && echo yes || echo no)"
fi

# -- the mirror: a continuation leg that commits nothing but writes a file
# into the outbox (a review or reply seat's kind of work) is progress, not a
# stall -- the chain goes on to leg 3, which hands off nothing.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_NOCOMMIT_LEGS=2
FAKE_OUTBOX_LEGS=2
rd="$(run_real "$proj" "$count_file" "1,2" "1,2" --refresh-at 0.5)"
FAKE_NOCOMMIT_LEGS=""
FAKE_OUTBOX_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "an outbox-writing continuation: a third leg ran" "3" "$(cat "$count_file")"
    check "an outbox-writing continuation: not ended as stalled" \
        "empty-outbox" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    check "an outbox-writing continuation: no stalled record exists" \
        "no" "$([[ -f "$rd/handoff-stalled-2.md" ]] && echo yes || echo no)"
fi

# -- a leg that reports a different context window than --refresh-at assumed:
# warn (once per leg, in the run's sandbox.log), and change nothing else.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_CONTEXT_WINDOW=200000
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5 --model claude-opus-5-5)"
FAKE_CONTEXT_WINDOW=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a window mismatch: both legs still ran" "2" "$(cat "$count_file")"
    check "a window mismatch: each leg is warned about in sandbox.log" "2" \
        "$(grep -c 'ran with a 200000-token context window, but --refresh-at assumed 1000000' \
            "$rd/sandbox.log" 2>/dev/null)"
fi
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_CONTEXT_WINDOW=1000000
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5 --model claude-opus-5-5)"
FAKE_CONTEXT_WINDOW=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "a matching window: no warning in sandbox.log" "0" \
        "$(grep -c 'token context window' "$rd/sandbox.log" 2>/dev/null)"
fi

# -- leg 1 (the implement leg) hands off without committing: leg 1 is
# exempt from the stall check (a survey leg may legitimately hand off
# without committing once), so a second leg still runs from it.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_NOCOMMIT_LEGS=1
rd="$(run_real "$proj" "$count_file" 1 1 --refresh-at 0.5)"
FAKE_NOCOMMIT_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "leg 1 hands off without committing: leg 2 still runs" \
        "2" "$(cat "$count_file")"
    check "leg 1 hands off without committing: not treated as a stall" \
        "empty-outbox" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
fi

# -- --refresh-at 0: never nudges, never binds an outbox, so even a stub
# willing to write one has nowhere to put it.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" all all --refresh-at 0)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "--refresh-at 0: only one leg ran" "1" "$(cat "$count_file")"
    check "--refresh-at 0: refresh field is none" \
        "none" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    check "--refresh-at 0: no continuations" \
        "0" "$(jq '.continuations | length' "$rd/summary.json" 2>/dev/null)"
fi

# -- a large brief warns at launch, before any leg runs: byte count >= the
# token threshold (roughly a quarter of it or more, at ~4 bytes/token).
# --refresh-at 100 (above 1, so an absolute token count, not a fraction)
# keeps the fixture brief small. Not run through run_real: that helper
# always writes its own fixed 'do the task' handoff, too small to trigger
# this, so this launches directly with a custom one instead.
big_handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-warn.XXXXXX)"; tmpdirs+=("$big_handoff_dir")
big_handoff="$big_handoff_dir/handoff.md"
head -c 200 /dev/zero | tr '\0' 'x' > "$big_handoff"
count_file="$(mktemp)"; tmpdirs+=("$count_file")
out="$(HOME="$launcher_home" PATH="$stub_bin:$PATH" \
    FAKE_CLAUDE_COUNT_FILE="$count_file" \
    timeout 60 "$launcher" --foreground --harness claude --refresh-at 100 \
    "$proj" "$big_handoff" 2>&1)"
rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
contains "a large brief warns at launch" "this brief is 200 bytes" "$out"
contains "the launch warning names the threshold" \
    "100-token --refresh-at threshold" "$out"

# -- a small brief, same threshold: no warning at all.
small_handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-warn.XXXXXX)"; tmpdirs+=("$small_handoff_dir")
small_handoff="$small_handoff_dir/handoff.md"
printf 'do the task\n' > "$small_handoff"
count_file="$(mktemp)"; tmpdirs+=("$count_file")
out="$(HOME="$launcher_home" PATH="$stub_bin:$PATH" \
    FAKE_CLAUDE_COUNT_FILE="$count_file" \
    timeout 60 "$launcher" --foreground --harness claude --refresh-at 100 \
    "$proj" "$small_handoff" 2>&1)"
rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if grep -q 'this brief is' <<< "$out"; then
    no "a small brief triggers no launch warning"
else
    ok "a small brief triggers no launch warning"
fi

# -- harness refusal, no stub needed: fails during flag validation, before
# any clone or run directory exists.
if HOME="$launcher_home" PATH="$stub_bin:$PATH" "$launcher" --harness pi --model demo/model \
    --refresh-at 0.5 "$proj" "$repo_dir/README.md" >/dev/null 2>"$stub_bin/err"; then
    no "--harness pi --refresh-at 0.5 is refused"
else
    contains "--harness pi --refresh-at 0.5 is refused" \
        "only works with --harness claude" "$(cat "$stub_bin/err")"
fi

# =====================================================================
printf '\n== every code leg refreshes, not just step 1: a plan-then-code pipeline ==\n'
# =====================================================================
# invocation 1: the plan leg (no refresh -- plan legs never refresh).
# invocation 2: the code step's own pass 1, nudged, hands off.
# invocation 3: that leg's own continuation, ends empty-outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_PLAN_LEGS=1
rd="$(run_real "$proj" "$count_file" 2 2 --pipeline pfable-csonnet --refresh-at 0.5)"
FAKE_PLAN_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "three legs ran (plan + the code step's pass 1 + its own continuation)" \
        "3" "$(cat "$count_file")"
    cont_prompt="$rd/continuation-prompt-s2-code-1-c1.md"
    if [[ -f "$cont_prompt" ]]; then
        ok "the code step's own continuation prompt exists, named by its leg tag"
        contains "it carries the original brief" "do the task" "$(cat "$cont_prompt")"
        contains "it carries the plan section" "## The plan" "$(cat "$cont_prompt")"
        contains "it carries the plan's own body" \
            "Stub plan body from call 1" "$(cat "$cont_prompt")"
        contains "it still carries the hand-off" \
            "## Hand-off from the previous leg" "$(cat "$cont_prompt")"
        brief_at="$(grep -n '## The original brief' "$cont_prompt" | head -1 | cut -d: -f1)"
        plan_at="$(grep -n '## The plan' "$cont_prompt" | head -1 | cut -d: -f1)"
        handoff_at="$(grep -n '## Hand-off from the previous leg' "$cont_prompt" | head -1 | cut -d: -f1)"
        if [[ -n "$brief_at" && -n "$plan_at" && -n "$handoff_at" \
            && "$brief_at" -lt "$plan_at" && "$plan_at" -lt "$handoff_at" ]]; then
            ok "the plan sits between the brief and the hand-off"
        else
            no "the plan sits between the brief and the hand-off" \
                "brief at $brief_at, plan at $plan_at, hand-off at $handoff_at"
        fi
    else
        no "the code step's own continuation prompt exists, named by its leg tag"
        no "it carries the original brief"
        no "it carries the plan section"
        no "it carries the plan's own body"
        no "it still carries the hand-off"
        no "the plan sits between the brief and the hand-off"
    fi
    if [[ -f "$rd/summary.json" ]]; then
        check "summary.json's step-1 refresh field stays none (no implement leg ran)" \
            "none" "$(jq -r '.refresh' "$rd/summary.json")"
        check "summary.json's leg_refreshes has exactly one entry" \
            "1" "$(jq '.leg_refreshes | length' "$rd/summary.json")"
        check "the entry names the code step's own leg tag" \
            "s2-code-1" "$(jq -r '.leg_refreshes[0].leg' "$rd/summary.json")"
        check "the entry's kind is code" \
            "code" "$(jq -r '.leg_refreshes[0].kind' "$rd/summary.json")"
        check "the entry ran exactly one continuation" \
            "1" "$(jq '.leg_refreshes[0].continuations | length' "$rd/summary.json")"
        check "the entry ended empty-outbox" \
            "empty-outbox" "$(jq -r '.leg_refreshes[0].ended' "$rd/summary.json")"
    else
        no "summary.json's leg_refreshes has exactly one entry" "no summary.json"
    fi
    status_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd" 2>/dev/null)"
    contains "fork-sandbox-status.sh reads the run without choking on the new continuation file" \
        "mode:" "$status_out"
fi

# =====================================================================
printf '\n== a per-leg chain records each continuation'"'"'s OWN handoff_stale, not the previous one'"'"'s ==\n'
# =====================================================================
# invocation 1: the plan leg. invocation 2: the code step's own pass 1,
# nudged, hands off a STALE hand-off (FAKE_STALE_LEGS=2) -- so continuation
# 1 reads a stale hand-off. invocation 3: continuation 1, nudged, hands off
# a CLEAN hand-off -- so continuation 2 reads a clean one. invocation 4:
# continuation 2, ends empty-outbox. If fs_refresh_chain records
# handoff_stale from the previous iteration's value (the bug this
# reproduces), continuations[0] reads false (leg 2's own staleness,
# computed but not yet stored) and continuations[1] reads true (leg 2's
# staleness, carried over instead of leg 3's).
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_PLAN_LEGS=1
FAKE_STALE_LEGS=2
rd="$(run_real "$proj" "$count_file" "2,3" "2,3" --pipeline pfable-csonnet --refresh-at 0.5)"
FAKE_PLAN_LEGS=""
FAKE_STALE_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "four legs ran (plan + the code step's pass 1 + two continuations)" \
        "4" "$(cat "$count_file")"
    if [[ -f "$rd/summary.json" ]]; then
        check "the chain ran exactly two continuations" \
            "2" "$(jq '.leg_refreshes[0].continuations | length' "$rd/summary.json")"
        check "continuation 1 (reading leg 2's stale hand-off) is marked stale" \
            "true" "$(jq -r '.leg_refreshes[0].continuations[0].handoff_stale' "$rd/summary.json")"
        check "continuation 2 (reading leg 3's clean hand-off) is not marked stale" \
            "false" "$(jq -r '.leg_refreshes[0].continuations[1].handoff_stale' "$rd/summary.json")"
    else
        no "the chain ran exactly two continuations" "no summary.json"
        no "continuation 1 (reading leg 2's stale hand-off) is marked stale" "no summary.json"
        no "continuation 2 (reading leg 3's clean hand-off) is not marked stale" "no summary.json"
    fi
    # progress.json's own additive field (decision 4: report every leg's
    # continuations, without redefining what "i" means): the code step's
    # entry carries the chain's final continuation count.
    if [[ -f "$rd/progress.json" ]]; then
        check "progress.json's code step reports two continuations ran" \
            "2" "$(jq -r '.steps[1].continuation' "$rd/progress.json")"
        check "progress.json's code step still reports i unchanged (pass 1, not redefined)" \
            "1" "$(jq -r '.steps[1].i' "$rd/progress.json")"
    else
        no "progress.json's code step reports two continuations ran" "no progress.json"
        no "progress.json's code step still reports i unchanged (pass 1, not redefined)" "no progress.json"
    fi
fi

# =====================================================================
printf '\n== progress.json does not carry a fix chain'"'"'s count into the next review leg ==\n'
# =====================================================================
# invocation 1: implement, commits. 2: review, FINDINGS. 3: fix, nudged,
# hands off. 4: the fix leg's continuation. 5: review, approves.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_COMMIT_LEGS=1 FAKE_VERDICT_FINDINGS_LEGS=2
rd="$(run_real "$proj" "$count_file" 3 3 --review-loop 2 --refresh-at 0.5)"
FAKE_COMMIT_LEGS="" FAKE_VERDICT_FINDINGS_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "five legs ran (implement, review, fix, its continuation, review)" \
        "5" "$(cat "$count_file")"
    check "the review step's continuation count is back to 0 after the last review leg" \
        "0" "$(jq -r '.steps[1].continuation' "$rd/progress.json" 2>/dev/null)"
fi

# =====================================================================
printf '\n== fix legs refresh too, and their continuation carries the findings ==\n'
# =====================================================================
# invocation 1: the implement leg, a plain commit (this scenario is about
# the FIX leg's own chain, so the implement leg itself must not refresh).
# invocation 2: the review leg, FINDINGS, and delivers an operator
# addendum -- so this chain can prove decision 7, that addenda keep
# reaching every leg including a LATER leg's own continuation, not just
# the step-1 implement leg's.
# invocation 3: the fix leg, nudged, hands off.
# invocation 4: the fix leg's own continuation, ends empty-outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_COMMIT_LEGS=1 FAKE_VERDICT_FINDINGS_LEGS=2 FAKE_ADDENDUM_LEGS=2
rd="$(run_real "$proj" "$count_file" 3 3 --review-loop 1 --refresh-at 0.5)"
FAKE_COMMIT_LEGS="" FAKE_VERDICT_FINDINGS_LEGS="" FAKE_ADDENDUM_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "four legs ran (implement + review + fix + the fix leg's own continuation)" \
        "4" "$(cat "$count_file")"
    cont_prompt="$rd/continuation-prompt-fix-1-c1.md"
    if [[ -f "$cont_prompt" ]]; then
        ok "the fix leg's own continuation prompt exists, named by its leg tag"
        contains "it carries the original brief" "do the task" "$(cat "$cont_prompt")"
        contains "it carries the findings section heading" \
            "## The findings this leg was asked to fix" "$(cat "$cont_prompt")"
        contains "it carries the finding text itself" \
            "the stub found a problem on call 2" "$(cat "$cont_prompt")"
        if grep -q 'Ignore this' "$cont_prompt"; then
            no "the findings exclude the verdict's own Report section"
        else
            ok "the findings exclude the verdict's own Report section"
        fi
        contains "it carries the addendum delivered to the earlier review leg" \
            "operator addendum for leg 2" "$(cat "$cont_prompt")"
        contains "it still carries the hand-off" \
            "## Hand-off from the previous leg" "$(cat "$cont_prompt")"
        brief_at="$(grep -n '## The original brief' "$cont_prompt" | head -1 | cut -d: -f1)"
        findings_at="$(grep -n '## The findings this leg was asked to fix' "$cont_prompt" | head -1 | cut -d: -f1)"
        handoff_at="$(grep -n '## Hand-off from the previous leg' "$cont_prompt" | head -1 | cut -d: -f1)"
        if [[ -n "$brief_at" && -n "$findings_at" && -n "$handoff_at" \
            && "$brief_at" -lt "$findings_at" && "$findings_at" -lt "$handoff_at" ]]; then
            ok "the findings section sits between the brief and the hand-off"
        else
            no "the findings section sits between the brief and the hand-off" \
                "brief at $brief_at, findings at $findings_at, hand-off at $handoff_at"
        fi
    else
        no "the fix leg's own continuation prompt exists, named by its leg tag"
        no "it carries the original brief"
        no "it carries the findings section heading"
        no "it carries the finding text itself"
        no "the findings exclude the verdict's own Report section"
        no "it carries the addendum delivered to the earlier review leg"
        no "it still carries the hand-off"
        no "the findings section sits between the brief and the hand-off"
    fi
    if [[ -f "$rd/summary.json" ]]; then
        # step 1 IS code here (a plain --review-loop run always has an
        # implement leg) -- refresh runs for it exactly as it always has
        # and ends empty-outbox (active, but never nudged), not "none"
        # (which means refresh never ran for it at all -- see the
        # plan-then-code scenario above, where step 1 truly has no
        # implement leg).
        check "summary.json's step-1 refresh field is empty-outbox (never nudged)" \
            "empty-outbox" "$(jq -r '.refresh' "$rd/summary.json")"
        check "summary.json has no step-1 continuations (only the fix leg's own chain ran)" \
            "0" "$(jq '.continuations | length' "$rd/summary.json")"
        check "summary.json's leg_refreshes has exactly one entry" \
            "1" "$(jq '.leg_refreshes | length' "$rd/summary.json")"
        check "the entry names the fix leg's own tag" \
            "fix-1" "$(jq -r '.leg_refreshes[0].leg' "$rd/summary.json")"
        check "the entry's kind is fix" \
            "fix" "$(jq -r '.leg_refreshes[0].kind' "$rd/summary.json")"
    else
        no "summary.json's leg_refreshes has exactly one entry" "no summary.json"
    fi
    # review-loop.json's fix_cost_usd keeps meaning the fix leg's own pass
    # alone (decision 6: existing field meanings do not change) -- the
    # stub always prices a call at 0.01, so a chain-inclusive fix_cost_usd
    # would read 0.02 here, double-counting the same continuation cost
    # leg_refreshes[0].continuations[0].cost_usd already carries.
    if [[ -f "$rd/review-loop.json" ]]; then
        check "review-loop.json's fix_cost_usd is this pass's own leg, not the chain total" \
            "0.01" "$(jq -r '.iterations[0].fix_cost_usd' "$rd/review-loop.json")"
        # Same decision-6 rule applies to fix_usage: fs_refresh_chain nulls
        # leg_usage once the chain has run any continuation (a single
        # leg's chain is one conversation per sub-leg, so "the usage"
        # stops being single-valued), but the base fix leg's OWN usage was
        # known and must not be thrown away just because its chain
        # continued -- it has to be captured before the chain call, the
        # same way fix_cost_usd already is.
        check "review-loop.json's fix_usage is the base fix leg's own usage, not null" \
            "100" "$(jq -r '.iterations[0].fix_usage.input_tokens' "$rd/review-loop.json")"
    else
        no "review-loop.json's fix_cost_usd is this pass's own leg, not the chain total" \
            "no review-loop.json"
        no "review-loop.json's fix_usage is the base fix leg's own usage, not null" \
            "no review-loop.json"
    fi
fi

# =====================================================================
printf '\n== a repeat code pass refreshes too, in a legacy-shaped (non-composed) run ==\n'
# =====================================================================
# --pipeline chaiku2 compiles to plain legacy flags (harness/model/
# code_repeat=2), not a composed pipeline: two legacy artifact-naming
# claims this scenario checks that the step-1 claims above cannot --
# "code-2" (no step index at all) and the LEGACY event-file regex in
# fork-sandbox-status.sh, not the composed s<K>- one.
# invocation 1: pass 1 (the implement leg), a plain commit, no refresh.
# invocation 2: pass 2, nudged, hands off.
# invocation 3: pass 2's own continuation, ends empty-outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_COMMIT_LEGS=1
rd="$(run_real "$proj" "$count_file" 2 2 --pipeline chaiku2 --refresh-at 0.5)"
FAKE_COMMIT_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "three legs ran (pass 1 + pass 2 + pass 2's own continuation)" \
        "3" "$(cat "$count_file")"
    cont_events="$rd/events-code-2-continuation-1.jsonl"
    marker "pass 2's own continuation events file exists, flat-named (no step index)" \
        "$cont_events" yes
    cont_prompt="$rd/continuation-prompt-code-2-c1.md"
    marker "pass 2's own continuation prompt exists, flat-named (no step index)" \
        "$cont_prompt" yes
    if [[ -f "$rd/summary.json" ]]; then
        check "the entry names the repeat pass's own leg tag" \
            "code-2" "$(jq -r '.leg_refreshes[0].leg' "$rd/summary.json")"
        check "the entry's kind is code" \
            "code" "$(jq -r '.leg_refreshes[0].kind' "$rd/summary.json")"
        check "the entry ran exactly one continuation" \
            "1" "$(jq '.leg_refreshes[0].continuations | length' "$rd/summary.json")"
    else
        no "the entry names the repeat pass's own leg tag" "no summary.json"
    fi
    status_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd" 2>/dev/null)"
    contains "fork-sandbox-status.sh reads the legacy-shaped run without choking" \
        "mode:" "$status_out"
fi

# =====================================================================
printf '\n== a composed pipeline'"'"'s own fix leg refreshes too (not just its code leg) ==\n'
# =====================================================================
# pfable-csonnet-rsonnet: plan, code, review -- composed (a plan step
# always makes a pipeline composed), unlike the plain --review-loop
# scenario above, which is legacy-shaped. The composed fix loop (a
# DIFFERENT call site in the walker from the legacy one just exercised)
# rides the review step's own step_idx, so its leg tag is "s3-fix-1", not
# "fix-1".
# invocation 1: the plan leg.
# invocation 2: the code step's own pass 1, a plain commit (this scenario
# is about the FIX leg's own chain).
# invocation 3: the review leg, FINDINGS.
# invocation 4: the fix leg, nudged, hands off.
# invocation 5: the fix leg's own continuation, ends empty-outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_PLAN_LEGS=1 FAKE_COMMIT_LEGS=2 FAKE_VERDICT_FINDINGS_LEGS=3
rd="$(run_real "$proj" "$count_file" 4 4 --pipeline pfable-csonnet-rsonnet --refresh-at 0.5)"
FAKE_PLAN_LEGS="" FAKE_COMMIT_LEGS="" FAKE_VERDICT_FINDINGS_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "five legs ran (plan + code + review + fix + the fix leg's own continuation)" \
        "5" "$(cat "$count_file")"
    cont_prompt="$rd/continuation-prompt-s3-fix-1-c1.md"
    if [[ -f "$cont_prompt" ]]; then
        ok "the composed fix leg's own continuation prompt exists, named by its leg tag"
        contains "it carries the findings section heading" \
            "## The findings this leg was asked to fix" "$(cat "$cont_prompt")"
        contains "it carries the finding text itself" \
            "the stub found a problem on call 3" "$(cat "$cont_prompt")"
    else
        no "the composed fix leg's own continuation prompt exists, named by its leg tag"
        no "it carries the findings section heading"
        no "it carries the finding text itself"
    fi
    if [[ -f "$rd/summary.json" ]]; then
        # Two entries now: the code step's own (eligible, but never nudged
        # -- FAKE_COMMIT_LEGS, not FAKE_NUDGE_LEGS, isolates this scenario
        # to the fix leg's own chain) and the fix leg's own, found by kind
        # rather than assumed at index 0.
        check "two leg_refreshes entries (the code step's own, and the fix leg's)" \
            "2" "$(jq '.leg_refreshes | length' "$rd/summary.json")"
        check "the fix entry names the composed fix leg's own tag" \
            "s3-fix-1" "$(jq -r '.leg_refreshes[] | select(.kind == "fix") | .leg' "$rd/summary.json")"
        check "the fix entry ran exactly one continuation" \
            "1" "$(jq -r '.leg_refreshes[] | select(.kind == "fix") | .continuations | length' "$rd/summary.json")"
        check "the code entry ran zero continuations (never nudged)" \
            "0" "$(jq -r '.leg_refreshes[] | select(.kind == "code") | .continuations | length' "$rd/summary.json")"
    else
        no "the fix entry names the composed fix leg's own tag" "no summary.json"
    fi
    status_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd" 2>/dev/null)"
    contains "fork-sandbox-status.sh reads the composed fix-leg run without choking" \
        "mode:" "$status_out"
fi

# =====================================================================
printf '\n== each leg is armed against its OWN model'"'"'s window, and continuation costs are counted once ==\n'
# =====================================================================
# --pipeline's grammar has no fix_agent syntax, so every scenario above
# that exercises a composed fix leg rides the code seat's own model --
# never proving decision 3 ("each leg's threshold is computed against
# that leg's own model's context window") against a leg whose model
# actually differs from the run's. A preset can seat a fix_agent of its
# own, so this one puts the code step on sonnet (a 1,000,000-token window)
# and the review step's fix seat on haiku (the 200,000-token exception),
# both armed by the same run-level --refresh-at 0.5.
#
# invocation 1: the plan leg (never armed).
# invocation 2: the code leg (sonnet), nudged, hands off.
# invocation 3: the code leg's own continuation, ends empty-outbox.
# invocation 4: the review leg (never armed), FINDINGS.
# invocation 5: the fix leg (haiku), nudged, hands off.
# invocation 6: the fix leg's own continuation, ends empty-outbox.
#
# The stub prices every leg at 0.01 regardless of model, so six legs --
# two of them (2 and 5) not at step 1 -- give an exact total_cost_usd of
# 0.06, proving decision 5 (a continuation's cost is counted in the run's
# total exactly once) without rounding or an inequality to hide a
# double-count or a drop behind.
preset_cfg_dir="$(mktemp -d)"; tmpdirs+=("$preset_cfg_dir")
mkdir -p "$preset_cfg_dir/presets"
cat > "$preset_cfg_dir/presets/fs-refresh-leg-model-test.yaml" <<'EOF'
agents:
  planner:
    harness: claude
    model: fable
  coder:
    harness: claude
    model: sonnet
    claude-args: --effort high
  reviewer:
    harness: claude
    model: opus
  haikufix:
    harness: claude
    model: haiku
    claude-args: --effort low

pipeline:
  - action: plan
    agent: planner
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: haikufix
EOF
count_file="$(mktemp)"; tmpdirs+=("$count_file")
argv_log="$(mktemp)"; tmpdirs+=("$argv_log")
FAKE_PLAN_LEGS=1 FAKE_VERDICT_FINDINGS_LEGS=4
export FORK_SANDBOX_CONFIG_DIR="$preset_cfg_dir" FAKE_ARGV_LOG="$argv_log"
rd="$(run_real "$proj" "$count_file" "2,5" "2,5" --preset fs-refresh-leg-model-test --refresh-at 0.5)"
unset FORK_SANDBOX_CONFIG_DIR FAKE_ARGV_LOG
FAKE_PLAN_LEGS="" FAKE_VERDICT_FINDINGS_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    # The code seat's own claude-args reach both its own leg AND its
    # --refresh-at continuation leg; the fix seat's own (different)
    # claude-args reach its leg and ITS continuation -- never each other's,
    # and never the plan or review legs', which carry none.
    contains "the code leg carries the code seat's own arguments" \
        "--effort high" "$(sed -n 2p "$argv_log")"
    contains "the code leg's continuation carries the same arguments" \
        "--effort high" "$(sed -n 3p "$argv_log")"
    contains "the fix leg carries the fix seat's own (different) arguments" \
        "--effort low" "$(sed -n 5p "$argv_log")"
    contains "the fix leg's continuation carries the same arguments" \
        "--effort low" "$(sed -n 6p "$argv_log")"
    lacks "the fix leg does not carry the code seat's arguments" \
        "--effort high" "$(sed -n 5p "$argv_log")"
    lacks "the code leg does not carry the fix seat's arguments" \
        "--effort low" "$(sed -n 2p "$argv_log")"
    lacks "the plan leg carries no arguments" "--effort" "$(sed -n 1p "$argv_log")"
    lacks "the review leg carries no arguments" "--effort" "$(sed -n 4p "$argv_log")"
    check "six legs ran (plan + code pass 1 + its continuation + review + fix pass 1 + its continuation)" \
        "6" "$(cat "$count_file")"
    check "the code leg (sonnet) is armed at half of its 1,000,000-token window" \
        "THRESHOLD_TOKENS=500000" \
        "$(grep '^THRESHOLD_TOKENS=' "$rd/refresh-config-snapshot-2" 2>/dev/null)"
    check "the code leg's continuation stays armed the same way" \
        "THRESHOLD_TOKENS=500000" \
        "$(grep '^THRESHOLD_TOKENS=' "$rd/refresh-config-snapshot-3" 2>/dev/null)"
    check "the fix leg (haiku) is armed at half of ITS OWN, smaller window -- not the code leg's" \
        "THRESHOLD_TOKENS=100000" \
        "$(grep '^THRESHOLD_TOKENS=' "$rd/refresh-config-snapshot-5" 2>/dev/null)"
    check "the fix leg's continuation stays armed the same way" \
        "THRESHOLD_TOKENS=100000" \
        "$(grep '^THRESHOLD_TOKENS=' "$rd/refresh-config-snapshot-6" 2>/dev/null)"
    marker "the plan leg is never armed" "$rd/refresh-config-snapshot-1" no
    marker "the review leg is never armed" "$rd/refresh-config-snapshot-4" no
    if [[ -f "$rd/summary.json" ]]; then
        check "total_cost_usd sums all six legs exactly once, not approximately" \
            "0.060000" "$(jq -r '.total_cost_usd' "$rd/summary.json")"
        check "the code leg's own chain is recorded under its leg tag" \
            "1" "$(jq '[.leg_refreshes[] | select(.leg == "s2-code-1")] | length' "$rd/summary.json")"
        check "the fix leg's own chain is recorded under its leg tag, a non-step-1 leg that refreshed" \
            "1" "$(jq '[.leg_refreshes[] | select(.leg == "s3-fix-1")] | length' "$rd/summary.json")"
    else
        no "total_cost_usd sums all six legs exactly once, not approximately" "no summary.json"
    fi
fi

# =====================================================================
printf '\n== a chain that ends on the cap leaves nothing for the next leg to misread ==\n'
# =====================================================================
# Two review-loop iterations, --refresh-max 1: iteration 1's fix leg's own
# chain is capped after exactly one continuation, which (before the fix)
# left outbox/handoff.md behind for fs_refresh_arm to re-arm into iteration
# 2's own fix leg -- whose fs_refresh_chain call would then find that
# leftover hand-off waiting before it had even run itself, and launch a
# bogus, paid continuation seeded with iteration 1's hand-off instead of
# its own.
# invocation 1: the implement leg, a plain commit.
# invocation 2: review leg 1, FINDINGS.
# invocation 3: fix leg 1 pass 1, nudged, hands off.
# invocation 4: fix leg 1's own continuation, nudged, hands off again --
# chain_n reaches 1 == --refresh-max, so the chain ends on the cap here.
# invocation 5: review leg 2, FINDINGS.
# invocation 6: fix leg 2 pass 1, a plain commit, never nudged -- its own
# chain must find nothing waiting and end empty-outbox with zero
# continuations. A leftover hand-off from iteration 1 would instead launch
# an invocation 7 here.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_COMMIT_LEGS="1,6" FAKE_VERDICT_FINDINGS_LEGS="2,5"
rd="$(run_real "$proj" "$count_file" "3,4" "3,4" --review-loop 2 --refresh-at 0.5 --refresh-max 1)"
FAKE_COMMIT_LEGS="" FAKE_VERDICT_FINDINGS_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "six legs ran (no bogus continuation seeded from iteration 1's hand-off)" \
        "6" "$(cat "$count_file")"
    if [[ -f "$rd/summary.json" ]]; then
        check "two leg_refreshes entries (one fix chain per iteration)" \
            "2" "$(jq '.leg_refreshes | length' "$rd/summary.json")"
        check "iteration 1's fix chain ran exactly one continuation" \
            "1" "$(jq -r '.leg_refreshes[0].continuations | length' "$rd/summary.json")"
        check "iteration 1's fix chain ended at the cap" \
            "cap" "$(jq -r '.leg_refreshes[0].ended' "$rd/summary.json")"
        check "iteration 2's fix chain ran zero continuations" \
            "0" "$(jq -r '.leg_refreshes[1].continuations | length' "$rd/summary.json")"
        check "iteration 2's fix chain ended empty-outbox, not seeded from leftovers" \
            "empty-outbox" "$(jq -r '.leg_refreshes[1].ended' "$rd/summary.json")"
    else
        no "two leg_refreshes entries (one fix chain per iteration)" "no summary.json"
    fi
    if [[ -f "$rd/handoff-capped-fix-1-2.md" ]]; then
        ok "the capped hand-off was moved aside into the run dir"
    else
        no "the capped hand-off was moved aside into the run dir" \
            "no handoff-capped-fix-1-2.md"
    fi
    check "the capped hand-off was moved out of the outbox" \
        "0" "$([[ -f "$rd/outbox/handoff.md" ]] && echo 1 || echo 0)"
fi

# =====================================================================
printf '\n== the step-1 chain'"'"'s capped hand-off stays put unless a later leg is armed ==\n'
# =====================================================================
# No later leg: invocation 1 implement and 2 its continuation both hand
# off; the cap ends the chain and the hand-off stays in the outbox.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
rd="$(run_real "$proj" "$count_file" "1,2" "1,2" --refresh-at 0.5 --refresh-max 1)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "step-1 alone: the chain ended at the cap" \
        "cap" "$(jq -r '.refresh' "$rd/summary.json" 2>/dev/null)"
    check "step-1 alone: the capped hand-off is still in the outbox" \
        "1" "$([[ -f "$rd/outbox/handoff.md" ]] && echo 1 || echo 0)"
fi
# A later fix leg: 3 review FINDINGS, 4 fix commits, never nudged. Its
# chain must not take step 1's leftover as its own (no invocation 5).
count_file="$(mktemp)"; tmpdirs+=("$count_file")
FAKE_COMMIT_LEGS=4 FAKE_VERDICT_FINDINGS_LEGS=3
rd="$(run_real "$proj" "$count_file" "1,2" "1,2" --review-loop 1 --refresh-at 0.5 --refresh-max 1)"
FAKE_COMMIT_LEGS="" FAKE_VERDICT_FINDINGS_LEGS=""
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    check "with a fix leg: four legs ran, no continuation seeded from step 1" \
        "4" "$(cat "$count_file")"
    check "with a fix leg: its chain ended empty-outbox" \
        "empty-outbox" "$(jq -r '.leg_refreshes[0].ended' "$rd/summary.json" 2>/dev/null)"
    check "with a fix leg: step 1's hand-off was moved aside before it armed" \
        "1" "$([[ -f "$rd/handoff-unclaimed-1.md" ]] && echo 1 || echo 0)"
fi

printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# Own-run-ids shape, not a before/after snapshot diff: a snapshot diff would
# also catch a concurrent real run or another suite's fixtures archiving
# during this suite's own window, which is not this suite's leak to report.
# Every run dir this suite creates is already in tmpdirs (appended right
# after each launcher call), so that is the complete own-run-ids list; a
# leaked fixture archive is always named "<run-dir-basename>.md".
leaked=""
for d in "${tmpdirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    cand="$operator_archive_dir/$(basename -- "$d").md"
    [[ -f "$cand" ]] && leaked+="$cand "
done
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$leaked"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
