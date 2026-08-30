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

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
hook="$repo_dir/scripts/fork-sandbox-inbox-hook.sh"

pass=0
fail=0
tmpdirs=()

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
    # jq itself.
    local inbox="$1" event="$2" transcript="$3"
    jq -n --arg ev "$event" --arg t "$transcript" \
        '{hook_event_name: $ev, transcript_path: $t}' \
    | FORK_SANDBOX_INBOX="$inbox" \
        FORK_SANDBOX_INBOX_SEEN="$inbox/../seen-$$" \
        FORK_SANDBOX_NUDGE_MARKER="$nudge_marker" \
        FORK_SANDBOX_NUDGE_REMINDED="$nudge_reminded" \
        FORK_SANDBOX_STALE_REMINDED="$stale_reminded" \
        "$hook" 2>/dev/null
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
    "do the other thing" "$out"

# =====================================================================
printf '\n== the outer loop: real fork-sandbox.sh runs, claude-sandboxed stubbed ==\n'
# =====================================================================

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely and simulates a claude
# session's observable effect on the parts fork-sandbox.sh's outer refresh
# loop reacts to. Which invocation this is (1 = implement leg, 2 = first
# continuation, ...) comes from a counter file so a scenario can control each
# leg independently; FAKE_NUDGE_LEGS, FAKE_HANDOFF_LEGS, FAKE_SYMLINK_LEGS,
# FAKE_FAIL_LEGS and FAKE_STALE_LEGS are comma lists of leg numbers (or the
# literal "all"), read fresh per call.
set -uo pipefail

outbox=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--bind-rw" ]] && outbox="$a"
    prev="$a"
done

cat >/dev/null   # drain the prompt; its content is not needed by this stub

n=0
[[ -f "$FAKE_CLAUDE_COUNT_FILE" ]] && n="$(cat "$FAKE_CLAUDE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_CLAUDE_COUNT_FILE"

nudge_legs=",${FAKE_NUDGE_LEGS:-},"
handoff_legs=",${FAKE_HANDOFF_LEGS:-},"
symlink_legs=",${FAKE_SYMLINK_LEGS:-},"
fail_legs=",${FAKE_FAIL_LEGS:-},"
stale_legs=",${FAKE_STALE_LEGS:-},"

if [[ "${FAKE_NUDGE_LEGS:-}" == "all" || "$nudge_legs" == *",$n,"* ]]; then
    printf '{"type":"system","subtype":"hook_response","stderr":"fork-sandbox-refresh: nudged (usage >= 1 tokens)\\n"}\n'
fi
if [[ "${FAKE_SYMLINK_LEGS:-}" == "all" || "$symlink_legs" == *",$n,"* ]]; then
    [[ -n "$outbox" ]] && ln -sf "${FAKE_SYMLINK_TARGET:-/etc/hostname}" "$outbox/handoff.md"
elif [[ "${FAKE_HANDOFF_LEGS:-}" == "all" || "$handoff_legs" == *",$n,"* ]]; then
    if [[ -n "$outbox" ]]; then
        printf 'HANDOFF from leg %s\n' "$n" > "$outbox/handoff.md"
        # The host's stale-hand-off backstop compares this hand-off's mtime
        # against the clone's HEAD reflog. The clone is the run dir's own
        # "clone/<name>" sibling of this outbox -- touch its reflog into the
        # future, deterministically, rather than racing a real mtime.
        if [[ "${FAKE_STALE_LEGS:-}" == "all" || "$stale_legs" == *",$n,"* ]] \
            && [[ -n "$outbox" ]]; then
            run_dir="$(dirname "$outbox")"
            clone_dir="$(find "$run_dir/clone" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
            if [[ -n "$clone_dir" && -f "$clone_dir/.git/logs/HEAD" ]]; then
                touch -d '+1 hour' "$clone_dir/.git/logs/HEAD"
            fi
        fi
    fi
fi

if [[ "${FAKE_FAIL_LEGS:-}" == "all" || "$fail_legs" == *",$n,"* ]]; then
    printf '{"type":"result","subtype":"error_during_execution","total_cost_usd":0.0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    exit 1
fi

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-refresh-test.XXXXXX")"
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
    local handoff_dir handoff out rc rd
    handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-refresh-handoff.XXXXXX)"
    # Appending to tmpdirs here would land in this function's own frame, not
    # the EXIT trap's array -- run_real is always called as a command
    # substitution, which forks a subshell (see the new_inbox comment above).
    # This dir is only needed for the launcher call below, so it is cleaned
    # up on every return from this function instead of being registered.
    trap 'rm -rf -- "$handoff_dir"' RETURN
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    : > "$count_file"
    out="$(PATH="$stub_bin:$PATH" \
        FAKE_CLAUDE_COUNT_FILE="$count_file" \
        FAKE_NUDGE_LEGS="$nudge_legs" \
        FAKE_HANDOFF_LEGS="$handoff_legs" \
        FAKE_SYMLINK_LEGS="${FAKE_SYMLINK_LEGS:-}" \
        FAKE_SYMLINK_TARGET="${FAKE_SYMLINK_TARGET:-}" \
        FAKE_FAIL_LEGS="${FAKE_FAIL_LEGS:-}" \
        FAKE_STALE_LEGS="${FAKE_STALE_LEGS:-}" \
        timeout 60 "$launcher" --foreground --harness claude "$@" \
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

# -- harness refusal, no stub needed: fails during flag validation, before
# any clone or run directory exists.
if PATH="$stub_bin:$PATH" "$launcher" --harness pi --model demo/model \
    --refresh-at 0.5 "$proj" "$repo_dir/README.md" >/dev/null 2>"$stub_bin/err"; then
    no "--harness pi --refresh-at 0.5 is refused"
else
    contains "--harness pi --refresh-at 0.5 is refused" \
        "only works with --harness claude" "$(cat "$stub_bin/err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
