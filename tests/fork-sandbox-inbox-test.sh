#!/usr/bin/env bash
# fork-sandbox-inbox-test.sh — Exercise the fork-sandbox operator inbox
#
# Usage: tests/fork-sandbox-inbox-test.sh
#
# Covers the two host-side pieces of the operator inbox:
#
#   fork-sandbox-inbox-hook.sh   the delivery hook, driven with fake hook JSON
#                                on stdin against a temp inbox
#   fork-sandbox-say.sh          the operator command, against a fake run
#                                directory under the real run-dir prefix
#
# The rejection paths matter more than the happy path here: fork-sandbox-say.sh
# is blanket-approved, so every check that keeps it a bounded write gets a test
# that proves the check fires (docs/permissions.md).
#
# It does NOT cover the end-to-end run. bwrap does not nest, so a sandboxed
# session cannot be launched from inside one; the wiring in fork-sandbox.sh is
# exercised by launching a real run on the host.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
hook="$repo_dir/scripts/fork-sandbox-inbox-hook.sh"
say="$repo_dir/scripts/fork-sandbox-say.sh"

RUN_DIR_PREFIX="/var/tmp/claude-scratch/forks/claude-fork-sandbox."

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
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

# A throwaway inbox for the hook, with its seen-list beside it rather than in
# the shared /tmp path a real run uses.
new_inbox() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s' "$d"
}

# A fake run directory under the REAL prefix, which is what fork-sandbox-say.sh
# validates against. mktemp gives it the same shape a launcher would.
new_run_dir() {
    local d
    d="$(mktemp -d "${RUN_DIR_PREFIX}XXXXXX")"
    tmpdirs+=("$d")
    printf 'version=1\nharness=%s\nbranch=t\n' "${1:-claude}" > "$d/run.env"
    mkdir -p "$d/inbox"
    printf '%s' "$d"
}

printf '== fork-sandbox-inbox-hook.sh ==\n'

inbox="$(new_inbox)"
export FORK_SANDBOX_INBOX="$inbox"
export FORK_SANDBOX_INBOX_SEEN="$inbox/seen"

# An empty inbox is the common case and must be silent, on both events.
out="$(echo '{"hook_event_name":"PostToolUse"}' | "$hook" 2>/dev/null)"
check "empty inbox: PostToolUse is silent" "" "$out"
out="$(echo '{"hook_event_name":"Stop"}' | "$hook" 2>/dev/null)"
check "empty inbox: Stop is silent (session may finish)" "" "$out"

printf 'rename the flag to --foo\n' > "$inbox/1724650001-01.md"

out="$(echo '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | "$hook" 2>/dev/null)"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    ok "PostToolUse: emits valid JSON"
else
    no "PostToolUse: emits valid JSON" "$out"
fi
check "PostToolUse: hookEventName echoes the event" \
    "PostToolUse" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
case "$ctx" in
    *"rename the flag to --foo"*) ok "PostToolUse: carries the addendum body" ;;
    *) no "PostToolUse: carries the addendum body" "$ctx" ;;
esac
case "$ctx" in
    *"## Operator addendum (1724650001-01.md)"*) ok "PostToolUse: labels the addendum with its file name" ;;
    *) no "PostToolUse: labels the addendum with its file name" "$ctx" ;;
esac
case "$ctx" in
    *"override the handoff"*) ok "PostToolUse: states the addendum's authority" ;;
    *) no "PostToolUse: states the addendum's authority" "$ctx" ;;
esac

# Delivered once, never again: the point of the seen-list.
out="$(echo '{"hook_event_name":"PostToolUse"}' | "$hook" 2>/dev/null)"
check "PostToolUse: a delivered addendum is not repeated" "" "$out"

# ...and having been delivered, it must not block the stop.
out="$(echo '{"hook_event_name":"Stop"}' | "$hook" 2>/dev/null)"
check "Stop: nothing unread, so the session may finish" "" "$out"

# The Stop backstop: an addendum that arrives after the last tool call.
printf 'also add a regression test\n' > "$inbox/1724650300-01.md"
out="$(echo '{"hook_event_name":"Stop"}' | "$hook" 2>/dev/null)"
check "Stop: unread addendum blocks the stop" \
    "block" "$(printf '%s' "$out" | jq -r '.decision')"
case "$(printf '%s' "$out" | jq -r '.reason')" in
    *"also add a regression test"*) ok "Stop: reason carries the addendum body" ;;
    *) no "Stop: reason carries the addendum body" "$out" ;;
esac
# Top-level decision/reason, NOT the nested hookSpecificOutput form PreToolUse
# uses. Getting this wrong is a silently dead feature.
check "Stop: decision is top-level, not nested" \
    "null" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.decision // "null"')"
out="$(echo '{"hook_event_name":"Stop"}' | "$hook" 2>/dev/null)"
check "Stop: blocking marks them seen, so it cannot loop" "" "$out"

# Several at once, oldest first.
inbox="$(new_inbox)"
export FORK_SANDBOX_INBOX="$inbox"
export FORK_SANDBOX_INBOX_SEEN="$inbox/seen"
printf 'FIRST\n' > "$inbox/1724650001-01.md"
printf 'SECOND\n' > "$inbox/1724650002-01.md"
out="$(echo '{"hook_event_name":"PostToolUse"}' | "$hook" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext')"
if [[ "$out" == *FIRST*SECOND* ]]; then
    ok "several unread are delivered together, oldest first"
else
    no "several unread are delivered together, oldest first" "$out"
fi

# The delivery marker the monitor renders.
inbox="$(new_inbox)"
export FORK_SANDBOX_INBOX="$inbox"
export FORK_SANDBOX_INBOX_SEEN="$inbox/seen"
printf 'x\n' > "$inbox/1724650001-01.md"
err="$(echo '{"hook_event_name":"PostToolUse"}' | "$hook" 2>&1 >/dev/null)"
case "$err" in
    "fork-sandbox-inbox: delivered 1724650001-01.md"*) ok "delivery is tagged on stderr for the monitor" ;;
    *) no "delivery is tagged on stderr for the monitor" "$err" ;;
esac

# A dotfile is machinery (the hook and its settings live in the inbox), never
# an addendum.
inbox="$(new_inbox)"
export FORK_SANDBOX_INBOX="$inbox"
export FORK_SANDBOX_INBOX_SEEN="$inbox/seen"
printf '{}\n' > "$inbox/.settings.json"
cp "$hook" "$inbox/.inbox-hook.sh"
out="$(echo '{"hook_event_name":"PostToolUse"}' | "$hook" 2>/dev/null)"
check "dotfiles in the inbox are not addenda" "" "$out"

unset FORK_SANDBOX_INBOX FORK_SANDBOX_INBOX_SEEN

printf '\n== fork-sandbox-say.sh ==\n'

run_dir="$(new_run_dir claude)"
out="$("$say" "$run_dir" 'tighten the error message' 2>&1)"
rc=$?
check "writes an addendum (exit 0)" "0" "$rc"
n=$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' | wc -l)
check "exactly one addendum landed" "1" "$n"
f="$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' -print -quit)"
check "the body is the text given" "tighten the error message" "$(cat "$f")"
case "$(basename "$f")" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9].md)
        ok "the file name is generated as <epoch>-<nn>.md" ;;
    *) no "the file name is generated as <epoch>-<nn>.md" "$(basename "$f")" ;;
esac
case "$out" in
    *"next tool call"*) ok "reports claude delivery timing" ;;
    *) no "reports claude delivery timing" "$out" ;;
esac
n=$(find "$run_dir/inbox" -maxdepth 1 -name '*.part' | wc -l)
check "no .part file is left behind" "0" "$n"

# An addendum can be archived at a leg boundary before the operator sends the
# next one. Keep date fixed so this reproduces the old same-second collision,
# then prove the sender's run-scoped allocation record survives the archive.
fixed_date_dir="$(mktemp -d)"; tmpdirs+=("$fixed_date_dir")
fixed_epoch=1724650400
cat > "$fixed_date_dir/date" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "+%s" ]]; then
    printf '%s\\n' '$fixed_epoch'
else
    exec /usr/bin/date "\$@"
fi
STUB
chmod +x "$fixed_date_dir/date"
run_dir="$(new_run_dir claude)"
export FORK_SANDBOX_INBOX="$run_dir/inbox"
export FORK_SANDBOX_INBOX_SEEN="$run_dir/inbox-seen"
PATH="$fixed_date_dir:$PATH" "$say" "$run_dir" 'archive this one' >/dev/null 2>&1
first_file="$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' -print -quit)"
first_name="$(basename "$first_file")"
printf '%s\n' '{"hook_event_name":"PostToolUse"}' | "$hook" >/dev/null 2>&1
mkdir -p "$run_dir/inbox-delivered/leg-1"
mv -- "$first_file" "$run_dir/inbox-delivered/leg-1/"
PATH="$fixed_date_dir:$PATH" "$say" "$run_dir" 'deliver this replacement' >/dev/null 2>&1
second_file="$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' -print -quit)"
second_name="$(basename "$second_file")"
if [[ "$second_name" != "$first_name" ]]; then
    ok "an archived addendum name is not recycled in the same second"
else
    no "an archived addendum name is not recycled in the same second" "$second_name"
fi
hook_out="$(printf '%s\n' '{"hook_event_name":"PostToolUse"}' | "$hook" 2>/dev/null)"
case "$hook_out" in
    *"deliver this replacement"*) ok "the replacement addendum is delivered after archiving" ;;
    *) no "the replacement addendum is delivered after archiving" "$hook_out" ;;
esac
unset FORK_SANDBOX_INBOX FORK_SANDBOX_INBOX_SEEN

# Two in the same second must not collide.
"$say" "$run_dir" 'one' >/dev/null 2>&1
"$say" "$run_dir" 'two' >/dev/null 2>&1
n=$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' | wc -l)
check "successive addenda get distinct names" "3" "$n"

# stdin mode.
run_dir="$(new_run_dir claude)"
printf 'from stdin\n' | "$say" "$run_dir" - >/dev/null 2>&1
f="$(find "$run_dir/inbox" -maxdepth 1 -name '*.md' -print -quit)"
check "reads the text from stdin with '-'" "from stdin" "$(cat "$f")"

# A pi run is told the slower truth.
run_dir="$(new_run_dir pi)"
out="$("$say" "$run_dir" 'switch to the other approach' 2>&1)"
case "$out" in
    *"within ~25 tool calls"*) ok "reports pi delivery timing" ;;
    *) no "reports pi delivery timing" "$out" ;;
esac

printf '\n-- rejections --\n'

# Each of these is a property the blanket approval depends on.
refuses() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        no "$label" "it succeeded; output: $out"
    else
        ok "$label"
    fi
}

outside="$(mktemp -d)"; tmpdirs+=("$outside")
printf 'version=1\n' > "$outside/run.env"
mkdir -p "$outside/inbox"
refuses "refuses a directory outside the run-dir prefix" "$say" "$outside" 'x'

refuses "refuses a path that does not exist" \
    "$say" "${RUN_DIR_PREFIX}definitely-not-there" 'x'

no_env="$(mktemp -d "${RUN_DIR_PREFIX}XXXXXX")"; tmpdirs+=("$no_env")
mkdir -p "$no_env/inbox"
refuses "refuses a run directory with no run.env" "$say" "$no_env" 'x'

ended="$(new_run_dir claude)"
printf '0\n' > "$ended/exit-code"
refuses "refuses a run that has ended" "$say" "$ended" 'x'
out="$("$say" "$ended" 'x' 2>&1)"
case "$out" in
    *"nothing is listening"*) ok "an ended run says nothing is listening" ;;
    *) no "an ended run says nothing is listening" "$out" ;;
esac

abandoned="$(new_run_dir claude)"
# A pid that has certainly exited: reap it first, then record it.
bash -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf '%s\n' "$dead_pid" > "$abandoned/pid"
refuses "refuses a run whose runner process is gone" "$say" "$abandoned" 'x'

# A live pid must still be accepted, or the check above would reject every
# healthy run.
alive="$(new_run_dir claude)"
printf '%s\n' "$$" > "$alive/pid"
if "$say" "$alive" 'still going' >/dev/null 2>&1; then
    ok "accepts a run whose runner is alive"
else
    no "accepts a run whose runner is alive"
fi

symlinked="$(new_run_dir claude)"
elsewhere="$(mktemp -d)"; tmpdirs+=("$elsewhere")
rmdir "$symlinked/inbox"
ln -s "$elsewhere" "$symlinked/inbox"
refuses "refuses a symlinked inbox" "$say" "$symlinked" 'x'
n=$(find "$elsewhere" -maxdepth 1 -name '*.md' | wc -l)
check "nothing was written through the symlink" "0" "$n"

no_inbox="$(new_run_dir claude)"
rmdir "$no_inbox/inbox"
refuses "refuses a run directory with no inbox" "$say" "$no_inbox" 'x'

run_dir="$(new_run_dir claude)"
refuses "refuses a missing message" "$say" "$run_dir"
refuses "refuses an all-whitespace message" "$say" "$run_dir" '   '
refuses "refuses two messages" "$say" "$run_dir" 'a' 'b'
refuses "refuses an unknown option" "$say" "$run_dir" --wat
n=$(find "$run_dir/inbox" -maxdepth 1 -name '*' -type f | wc -l)
check "no rejected call wrote anything" "0" "$n"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
