#!/usr/bin/env bash
# fork-task-ack-test.sh — Exercise fork-task-ack.sh: token validation,
# the child-side ack, idempotence, and the parent-side --wait verb.
#
# Usage: tests/fork-task-ack-test.sh
#
# The script's ack directory is fixed (it takes no environment inputs), so
# the tests create uniquely named tokens there and remove them on exit.

# shellcheck disable=SC2015  # A && ok || no: ok never fails
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ack="$repo_dir/scripts/fork-task-ack.sh"
ack_dir="/var/tmp/claude-scratch/forks/acks"
mkdir -p "$ack_dir"

pass=0
fail=0
tokens=()
cleanup() { local t; for t in "${tokens[@]-}"; do [[ -n "$t" ]] && rm -f -- "$ack_dir/$t"; done; }
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

new_token() {
    local t="test-$$-$RANDOM$RANDOM"
    tokens+=("$t")
    printf 'pending\n' > "$ack_dir/$t"
    printf '%s' "$t"
}

printf '== fork-task-ack.sh ==\n'

for bad in '../x' '' 'a/b' '-abcdefgh' 'short' '..' 'x y zzzzzzzz'; do
    if "$ack" "$bad" >/dev/null 2>&1; then
        no "malformed token '$bad' is refused (ack)"
    else
        ok "malformed token '$bad' is refused (ack)"
    fi
    if "$ack" --wait "$bad" --timeout 1 >/dev/null 2>&1; then
        no "malformed token '$bad' is refused (wait)"
    else
        ok "malformed token '$bad' is refused (wait)"
    fi
done

"$ack" "nosuchtoken-$$" >/dev/null 2>&1; rc=$?
[[ $rc == 1 ]] && ok "unknown token: exit 1 (ack)" || no "unknown token: exit 1 (ack)" "rc=$rc"
"$ack" --wait "nosuchtoken-$$" --timeout 1 >/dev/null 2>&1; rc=$?
[[ $rc == 1 ]] && ok "unknown token: exit 1 (wait)" || no "unknown token: exit 1 (wait)" "rc=$rc"

t="$(new_token)"
"$ack" --wait "$t" --timeout 1 >/dev/null 2>&1; rc=$?
[[ $rc == 3 ]] && ok "--wait on an un-acked token times out with 3" || no "--wait on an un-acked token times out with 3" "rc=$rc"

CLAUDE_CODE_SESSION_ID=sess-abc "$ack" "$t" >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "ack succeeds" || no "ack succeeds" "rc=$rc"
case "$(cat "$ack_dir/$t")" in
    "acked "*" sess-abc") ok "ack records time and session id" ;;
    *) no "ack records time and session id" "$(cat "$ack_dir/$t")" ;;
esac
first="$(cat "$ack_dir/$t")"
CLAUDE_CODE_SESSION_ID=other "$ack" "$t" >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$ack_dir/$t")" == "$first" ]] && ok "ack is idempotent" || no "ack is idempotent" "rc=$rc"
"$ack" --wait "$t" --timeout 5 >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "--wait on an acked token returns 0" || no "--wait on an acked token returns 0" "rc=$rc"

# A wait already blocking is released by a later ack.
t="$(new_token)"
( sleep 1; "$ack" "$t" >/dev/null 2>&1 ) &
"$ack" --wait "$t" --timeout 10 >/dev/null 2>&1; rc=$?
wait
[[ $rc == 0 ]] && ok "--wait is released by a later ack" || no "--wait is released by a later ack" "rc=$rc"

"$ack" --help | grep -q 'Usage:' && ok "--help prints usage" || no "--help prints usage"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
