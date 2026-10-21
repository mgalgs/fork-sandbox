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
sid2="$sid-b"
lanes_file2="/tmp/claude-$(id -u)/lane-mail-lanes/$sid2"
scratch="$(mktemp -d)"
trap 'rm -f -- "$lanes_file" "$lanes_file2"; rm -rf -- "$scratch"' EXIT

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

printf '== lanes ==\n'

# The registration above is still in place, so the lister must show it.
lanes="$("$lane_mail" lanes 2>&1)"
rc=$?
if (( rc == 0 )); then ok "lanes succeeds"; else no "lanes succeeds" "rc=$rc: $lanes"; fi
if grep -qx $'live\ttestlane\t' <<<"$lanes"; then
    ok "lanes lists a registered lane as live"
else
    no "lanes lists a registered lane as live" "$lanes"
fi

printf '== descriptions ==\n'

# Descriptions live under the fixed lane-mail root, so these run against a
# scratch copy of the scripts with the root line pointed at a temp dir.
cp -r "$repo_dir/scripts" "$scratch/scripts"
mkdir -p "$scratch/mods/lane-complete" "$scratch/root"
cp -r "$repo_dir/mods/lane-complete/bin" "$scratch/mods/lane-complete/bin"
sed -i "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$scratch/root|" "$scratch/scripts/lane-mail-lib.sh"
sc="$scratch/scripts/lane-mail.sh"
about_file="$scratch/root/agents/alpha/about"

out="$("$sc" describe alpha "the alpha widget repo" 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$(cat "$about_file" 2>/dev/null)" == "the alpha widget repo" ]]; then
    ok "describe stores the text with the lane's mailbox"
else
    no "describe stores the text with the lane's mailbox" "rc=$rc: $out"
fi
"$sc" describe @alpha "the alpha widget repo, v2" >/dev/null 2>&1
if [[ "$(cat "$about_file" 2>/dev/null)" == "the alpha widget repo, v2" ]]; then
    ok "describe accepts a leading @ and replaces the text"
else
    no "describe accepts a leading @ and replaces the text"
fi

# Registration is per session; the description must outlive it.
CLAUDE_CODE_SESSION_ID="$sid" "$sc" register alpha >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID="$sid" "$sc" unregister >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID="$sid2" "$sc" register alpha >/dev/null 2>&1
if [[ "$(cat "$about_file" 2>/dev/null)" == "the alpha widget repo, v2" ]]; then
    ok "register without --about keeps the existing description"
else
    no "register without --about keeps the existing description"
fi

lanes="$("$sc" lanes 2>&1)"
if grep -qx $'live\talpha\tthe alpha widget repo, v2' <<<"$lanes"; then
    ok "lanes shows the description, and it outlived the first session"
else
    no "lanes shows the description, and it outlived the first session" "$lanes"
fi

out="$(CLAUDE_CODE_SESSION_ID="$sid2" "$sc" register beta --about "the beta gadget repo" 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$(cat "$scratch/root/agents/beta/about" 2>/dev/null)" == "the beta gadget repo" ]] &&
    [[ "$(CLAUDE_CODE_SESSION_ID="$sid2" "$sc" registration)" == beta ]]; then
    ok "register --about registers and describes"
else
    no "register --about registers and describes" "rc=$rc: $out"
fi
CLAUDE_CODE_SESSION_ID="$sid2" "$sc" register --about "the beta gadget repo, again" beta >/dev/null 2>&1
if [[ "$(cat "$scratch/root/agents/beta/about" 2>/dev/null)" == "the beta gadget repo, again" ]]; then
    ok "register takes --about before the lane too"
else
    no "register takes --about before the lane too"
fi

"$sc" describe beta "" >/dev/null 2>&1
if [[ ! -e "$scratch/root/agents/beta/about" ]]; then
    ok "describe with empty text clears the description"
else
    no "describe with empty text clears the description"
fi

refuses() {  # refuses <label> <lane> <text>
    local before
    before="$(cat "$about_file" 2>/dev/null)"
    if "$sc" describe "$2" "$3" >/dev/null 2>&1; then
        no "$1" "was accepted"
    elif [[ "$(cat "$about_file" 2>/dev/null)" != "$before" ]]; then
        no "$1" "the stored text changed"
    else
        ok "$1"
    fi
}
refuses "a newline in the text is refused" alpha $'one\ntwo'
refuses "a tab in the text is refused" alpha $'one\ttwo'
refuses "text over 200 characters is refused" alpha "$(printf 'x%.0s' {1..201})"
refuses "a remote lane is refused" alpha:somehost "the far alpha"
if "$sc" describe alpha "$(printf 'x%.0s' {1..200})" >/dev/null 2>&1; then
    ok "text of exactly 200 characters is accepted"
else
    no "text of exactly 200 characters is accepted"
fi
if printf 'one\0two' | "$sc" describe alpha - >/dev/null 2>&1; then
    no "a NUL in the text is refused" "was accepted"
else
    ok "a NUL in the text is refused"
fi
if printf 'from stdin\n' | "$sc" describe alpha - >/dev/null 2>&1 &&
    [[ "$(cat "$about_file")" == "from stdin" ]]; then
    ok "describe - reads one line from stdin"
else
    no "describe - reads one line from stdin"
fi
if printf 'a\nb\n' | "$sc" describe alpha - >/dev/null 2>&1; then
    no "multi-line stdin is refused" "was accepted"
else
    ok "multi-line stdin is refused"
fi
out="$(CLAUDE_CODE_SESSION_ID="$sid2" "$sc" register gamma --about $'a\tb' 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$(CLAUDE_CODE_SESSION_ID="$sid2" "$sc" registration)" == beta ]]; then
    ok "register --about with bad text refuses before registering"
else
    no "register --about with bad text refuses before registering" "rc=$rc: $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
