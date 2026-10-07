#!/usr/bin/env bash
# lane-complete-list-lanes-test.sh -- Exercise mods/lane-complete/bin/list-lanes.sh,
# the lane list the lane-complete mod refreshes in the background.
#
# No real lane-mail root, config dir or registry. The script is copied beside
# a scratch copy of the two lane-mail files it reads (mods/lane-complete/bin
# next to scripts/), with the fixed root line in lane-mail-lib.sh pointed at
# a temp dir and the registry directory name in lane-mail.sh made unique; the
# scripts themselves gain no override. The registry lives under the user's
# /tmp/claude-<uid>, so the test removes its own directory on exit.
#
# Usage: tests/lane-complete-list-lanes-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}

scratch="$(mktemp -d)"
reg_name="lane-complete-test-$$"
reg_dir="/tmp/claude-$(id -u)/$reg_name"
trap 'rm -rf -- "$scratch" "$reg_dir"' EXIT

mkdir -p "$scratch/scripts" "$scratch/mods/lane-complete/bin" \
    "$scratch/root/agents" "$scratch/config" "$reg_dir"
cp "$repo_dir/mods/lane-complete/bin/list-lanes.sh" "$scratch/mods/lane-complete/bin/"
sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$scratch/root|" \
    "$repo_dir/scripts/lane-mail-lib.sh" > "$scratch/scripts/lane-mail-lib.sh"
sed "s|^LANES_DIR=.*|LANES_DIR=\"/tmp/claude-\$(id -u)/$reg_name\"|" \
    "$repo_dir/scripts/lane-mail.sh" > "$scratch/scripts/lane-mail.sh"
if grep -q "^LANES_DIR=\"/tmp/claude-\\\$(id -u)/$reg_name\"\$" "$scratch/scripts/lane-mail.sh"; then
    ok "scratch lane-mail.sh carries the test registry dir"
else
    no "scratch lane-mail.sh carries the test registry dir"
fi
printf 'LANE_MAIL_PEER_NAME=selfhost\n' > "$scratch/config/lane-mail.env"

list() {
    FORK_SANDBOX_CONFIG_DIR="$scratch/config" "$scratch/mods/lane-complete/bin/list-lanes.sh" "$@"
}
tab=$'\t'

check "nothing known prints nothing" "" "$(list)"

printf 'alpha\n' > "$reg_dir/sess-1"
printf 'alpha\n' > "$reg_dir/sess-2"
printf 'Bad Lane\n' > "$reg_dir/sess-3"
mkdir -p "$scratch/root/agents/alpha" "$scratch/root/agents/beta" "$scratch/root/agents/-bad"
printf '# peers\nhostone ssh.example.test\nselfhost ssh.example.test\nBAD host\n' \
    > "$scratch/config/lane-mail-peers"

want="live${tab}alpha
mailbox${tab}beta
peer${tab}hostone"
check "live first, then mailbox-only, then peers; deduped; invalid and self dropped" \
    "$want" "$(list)"

check "--help prints the header" "list-lanes.sh -- Print the lane-mail lanes the lane-complete mod can offer" \
    "$(list --help | head -1)"
list --bogus >/dev/null 2>&1; check "unknown argument exits 1" "1" "$?"

# No lane-mail scripts beside the mod and none on PATH: fail with a reason.
mkdir -p "$scratch/lone/mods/lane-complete/bin"
cp "$repo_dir/mods/lane-complete/bin/list-lanes.sh" "$scratch/lone/mods/lane-complete/bin/"
err="$(PATH=/usr/bin:/bin "$scratch/lone/mods/lane-complete/bin/list-lanes.sh" 2>&1 >/dev/null)"
check "missing scripts exits 1" "1" "$?"
case "$err" in *"lane-mail scripts not found"*) ok "missing scripts says so" ;; *) no "missing scripts says so" "$err" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
