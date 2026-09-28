#!/usr/bin/env bash
# lane-mail-test.sh -- Exercise lane-mail.sh's session registration: the
# lane mapping it writes, and the hint it prints for arming a watch.
#
# Registration writes a per-session file under /tmp/claude-$UID; this uses
# an invented session id and removes the file it created.
#
# Usage: tests/lane-mail-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
lane_mail="$repo_dir/scripts/lane-mail.sh"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

sid="lane-mail-test-$$-$RANDOM"
lanes_file="/tmp/claude-$(id -u)/lane-mail-lanes/$sid"
trap 'rm -f -- "$lanes_file"' EXIT

printf '== register ==\n'

out="$(CLAUDE_CODE_SESSION_ID="$sid" "$lane_mail" register testlane 2>&1)"
rc=$?
if (( rc == 0 )); then ok "register succeeds"; else no "register succeeds" "rc=$rc: $out"; fi
if [[ "$out" == *"registered as @testlane"* ]]; then
    ok "register names the lane"
else
    no "register names the lane" "$out"
fi
if [[ "$out" == *"lane-mail-watch.sh testlane --wait"* ]]; then
    ok "register says how to arm a --wait watch for the lane"
else
    no "register says how to arm a --wait watch for the lane" "$out"
fi
if [[ "$out" == *"not a Monitor"* ]]; then
    ok "register steers away from a Monitor"
else
    no "register steers away from a Monitor" "$out"
fi

reg="$(CLAUDE_CODE_SESSION_ID="$sid" "$lane_mail" registration 2>&1)"
if [[ "$reg" == testlane ]]; then
    ok "registration reads the lane back"
else
    no "registration reads the lane back" "$reg"
fi

if CLAUDE_CODE_SESSION_ID="$sid" "$lane_mail" register @bad >/dev/null 2>&1; then
    no "a lane name with a leading @ is refused"
else
    ok "a lane name with a leading @ is refused"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
