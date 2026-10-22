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

# Reads lanes.json directly (never through lane-mail.sh), so write-path
# assertions do not depend on the lane-for lookup verb being present.
json_value() {  # json_value <file> <key>
    python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(3)
if not isinstance(data, dict) or key not in data:
    sys.exit(1)
print(data[key])
' "$1" "$2"
}

sid="lane-mail-test-$$-$RANDOM"
lanes_file="/tmp/claude-$(id -u)/lane-mail-lanes/$sid"
sid2="$sid-b"
lanes_file2="/tmp/claude-$(id -u)/lane-mail-lanes/$sid2"
scratch="$(mktemp -d)"
dir_sids=()   # extra session ids used by the lanes.json tests below
dir_homes=()  # scratch $HOME dirs used by the lanes.json tests below
cleanup() {
    rm -f -- "$lanes_file" "$lanes_file2"
    rm -rf -- "$scratch"
    local s h
    for s in "${dir_sids[@]:-}"; do
        [[ -n "$s" ]] && rm -f -- "/tmp/claude-$(id -u)/lane-mail-lanes/$s"
    done
    for h in "${dir_homes[@]:-}"; do
        [[ -n "$h" ]] && rm -rf -- "$h"
    done
}
trap cleanup EXIT

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

printf '== lanes.json: register --dir (write path) ==\n'

lanes_home="$(mktemp -d)"
dir_homes+=("$lanes_home")
lanes_json="$lanes_home/.local/state/fork-sandbox/lanes.json"

dir_sids+=("$sid-dir1")
out="$(HOME="$lanes_home" CLAUDE_CODE_SESSION_ID="$sid-dir1" "$lane_mail" register fe --dir /tmp/lane-mail-test-proj/a 2>&1)"; rc=$?
got="$(json_value "$lanes_json" /tmp/lane-mail-test-proj/a 2>&1)"
if (( rc == 0 )) && [[ "$got" == fe ]]; then
    ok "register --dir creates the file and parent directory and records the entry"
else
    no "register --dir creates the file and parent directory and records the entry" "rc=$rc out=$out got=$got"
fi

dir_sids+=("$sid-dir2")
HOME="$lanes_home" CLAUDE_CODE_SESSION_ID="$sid-dir2" "$lane_mail" register be --dir /tmp/lane-mail-test-proj/b >/dev/null 2>&1
got_a="$(json_value "$lanes_json" /tmp/lane-mail-test-proj/a 2>&1)"
got_b="$(json_value "$lanes_json" /tmp/lane-mail-test-proj/b 2>&1)"
if [[ "$got_a" == fe && "$got_b" == be ]]; then
    ok "registering a second directory leaves the first entry intact"
else
    no "registering a second directory leaves the first entry intact" "a=$got_a b=$got_b"
fi

# A trailing slash is not part of the key: "/c/" and "/c" write the same entry.
dir_sids+=("$sid-dir3")
HOME="$lanes_home" CLAUDE_CODE_SESSION_ID="$sid-dir3" "$lane_mail" register ce --dir /tmp/lane-mail-test-proj/c/ >/dev/null 2>&1
got="$(json_value "$lanes_json" /tmp/lane-mail-test-proj/c 2>&1)"
if [[ "$got" == ce ]] && ! grep -q '/c/"' "$lanes_json"; then
    ok "a trailing slash is dropped from the key on write"
else
    no "a trailing slash is dropped from the key on write" "got=$got"
fi

# A relative --dir is refused before anything -- the session registration
# included -- is written.
cp -- "$lanes_json" "$lanes_json.bak"
dir_sids+=("$sid-dir4")
out="$(HOME="$lanes_home" CLAUDE_CODE_SESSION_ID="$sid-dir4" "$lane_mail" register de --dir relative/path 2>&1)"; rc=$?
if (( rc != 0 )) && cmp -s -- "$lanes_json" "$lanes_json.bak" &&
    ! HOME="$lanes_home" CLAUDE_CODE_SESSION_ID="$sid-dir4" "$lane_mail" registration >/dev/null 2>&1; then
    ok "a relative --dir is refused, with lanes.json and the session unchanged"
else
    no "a relative --dir is refused, with lanes.json and the session unchanged" "rc=$rc: $out"
fi

# A malformed lanes.json is refused and left byte-identical. Uses its own
# scratch $HOME (not $lanes_home, which the lane-for tests below still need
# intact) since this deliberately corrupts the file.
malformed_home="$(mktemp -d)"
dir_homes+=("$malformed_home")
malformed_json="$malformed_home/.local/state/fork-sandbox/lanes.json"
mkdir -p -- "$(dirname -- "$malformed_json")"
printf 'not json' > "$malformed_json"
cp -- "$malformed_json" "$malformed_json.bak"
dir_sids+=("$sid-dir5")
out="$(HOME="$malformed_home" CLAUDE_CODE_SESSION_ID="$sid-dir5" "$lane_mail" register ee --dir /tmp/lane-mail-test-proj/e 2>&1)"; rc=$?
if (( rc != 0 )) && cmp -s -- "$malformed_json" "$malformed_json.bak" && [[ "$out" == *lanes.json* ]]; then
    ok "a malformed lanes.json is refused and left byte-identical"
else
    no "a malformed lanes.json is refused and left byte-identical" "rc=$rc: $out"
fi

printf '== lanes.json: register --dir failure handling ==\n'

# A flock that fails (e.g. an incompatible one earlier on PATH) must stop
# the update cold -- not fall through to an unlocked read-modify-write that
# exits 0 as if nothing were wrong.
fake_bin="$(mktemp -d)"
dir_homes+=("$fake_bin")
cat > "$fake_bin/flock" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fake_bin/flock"

flock_fail_home="$(mktemp -d)"
dir_homes+=("$flock_fail_home")
flock_fail_json="$flock_fail_home/.local/state/fork-sandbox/lanes.json"
dir_sids+=("$sid-dir6")
out="$(PATH="$fake_bin:$PATH" HOME="$flock_fail_home" CLAUDE_CODE_SESSION_ID="$sid-dir6" \
    "$lane_mail" register ff --dir /tmp/lane-mail-test-proj/f 2>&1)"; rc=$?
if (( rc != 0 )) && ! json_value "$flock_fail_json" /tmp/lane-mail-test-proj/f >/dev/null 2>&1; then
    ok "a flock failure refuses the write instead of racing unlocked"
else
    no "a flock failure refuses the write instead of racing unlocked" "rc=$rc out=$out"
fi

# A failing rename (e.g. the target filesystem is full or read-only) must
# also be reported, not silently swallowed with the entry never recorded
# and a stray temp file left behind.
fake_bin2="$(mktemp -d)"
dir_homes+=("$fake_bin2")
cat > "$fake_bin2/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fake_bin2/mv"

mv_fail_home="$(mktemp -d)"
dir_homes+=("$mv_fail_home")
mv_fail_json="$mv_fail_home/.local/state/fork-sandbox/lanes.json"
mv_fail_dir="$mv_fail_home/.local/state/fork-sandbox"
dir_sids+=("$sid-dir7")
out="$(PATH="$fake_bin2:$PATH" HOME="$mv_fail_home" CLAUDE_CODE_SESSION_ID="$sid-dir7" \
    "$lane_mail" register gg --dir /tmp/lane-mail-test-proj/g 2>&1)"; rc=$?
leftover="$(find "$mv_fail_dir" -maxdepth 1 -name '.lanes.json.*' 2>/dev/null)"
if (( rc != 0 )) && ! json_value "$mv_fail_json" /tmp/lane-mail-test-proj/g >/dev/null 2>&1 &&
    [[ -z "$leftover" ]]; then
    ok "a failing rename refuses the write and leaves no temp file behind"
else
    no "a failing rename refuses the write and leaves no temp file behind" "rc=$rc out=$out leftover=$leftover"
fi

printf '== lanes.json: register --dir concurrency ==\n'

conc_home="$(mktemp -d)"
dir_homes+=("$conc_home")
conc_json="$conc_home/.local/state/fork-sandbox/lanes.json"
n=24
conc_pids=()
for i in $(seq 1 "$n"); do
    dir_sids+=("$sid-conc-$i")
    ( HOME="$conc_home" CLAUDE_CODE_SESSION_ID="$sid-conc-$i" \
        "$lane_mail" register "lane$i" --dir "/tmp/lane-mail-test-proj/conc/$i" >/dev/null 2>&1 ) &
    conc_pids+=("$!")
done
for pid in "${conc_pids[@]}"; do wait "$pid" || true; done

missing=0
for i in $(seq 1 "$n"); do
    got="$(json_value "$conc_json" "/tmp/lane-mail-test-proj/conc/$i" 2>/dev/null)"
    [[ "$got" == "lane$i" ]] || missing=$(( missing + 1 ))
done
if (( missing == 0 )); then
    ok "$n parallel register --dir calls (distinct directories) all land in lanes.json"
else
    no "$n parallel register --dir calls (distinct directories) all land in lanes.json" "$missing of $n missing or wrong"
fi

printf '== lanes.json: lane-for (lookup verb) ==\n'

got="$(HOME="$lanes_home" "$lane_mail" lane-for /tmp/lane-mail-test-proj/a 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$got" == fe ]]; then
    ok "lane-for hits a known directory"
else
    no "lane-for hits a known directory" "rc=$rc: $got"
fi

# The lookup side normalizes a trailing slash too, independent of the write
# side's own normalization (exercised above with a different directory).
got="$(HOME="$lanes_home" "$lane_mail" lane-for /tmp/lane-mail-test-proj/a/ 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$got" == fe ]]; then
    ok "a trailing slash is dropped from the key on lookup"
else
    no "a trailing slash is dropped from the key on lookup" "rc=$rc: $got"
fi

out="$(HOME="$lanes_home" "$lane_mail" lane-for /tmp/lane-mail-test-proj/nope 2>&1)"; rc=$?
if (( rc == 1 )) && [[ -z "$out" ]]; then
    ok "lane-for misses an unknown directory with exit 1 and no output"
else
    no "lane-for misses an unknown directory with exit 1 and no output" "rc=$rc: $out"
fi

empty_home="$(mktemp -d)"
dir_homes+=("$empty_home")
out="$(HOME="$empty_home" "$lane_mail" lane-for /tmp/lane-mail-test-proj/a 2>&1)"; rc=$?
if (( rc == 1 )) && [[ -z "$out" ]]; then
    ok "lane-for with no lanes.json yet exits 1 with no output"
else
    no "lane-for with no lanes.json yet exits 1 with no output" "rc=$rc: $out"
fi

out="$(HOME="$lanes_home" "$lane_mail" lane-for 2>&1)"; rc=$?
if (( rc == 2 )); then
    ok "lane-for with no argument is a usage error"
else
    no "lane-for with no argument is a usage error" "rc=$rc: $out"
fi

out="$(HOME="$malformed_home" "$lane_mail" lane-for /tmp/lane-mail-test-proj/a 2>&1)"; rc=$?
if (( rc != 0 )) && [[ -n "$out" ]]; then
    ok "lane-for on a malformed lanes.json is an error on stderr, non-zero"
else
    no "lane-for on a malformed lanes.json is an error on stderr, non-zero" "rc=$rc: $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
