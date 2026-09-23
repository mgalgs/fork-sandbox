#!/usr/bin/env bash
# fork-sandbox-harness-session-caps-test.sh — Exercise fs_harness_session_caps
#
# Usage: tests/fork-sandbox-harness-session-caps-test.sh
#
# fs_harness_session_caps is the one place that knows which harnesses can
# resume a session, where their in-sandbox transcript store lives, and how a
# caller learns the session id afterward. fork-sandbox.sh and the postmaster
# consult it instead of testing a harness name themselves; this suite is the
# guard against a harness-name check creeping back in as a substitute for it.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

pass=0
fail=0

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

echo "== claude =="
fs_harness_session_caps claude
check "claude is resumable" "true" "$FS_HARNESS_RESUMABLE"
# shellcheck disable=SC2016  # comparing against a literal unexpanded $HOME token
check "claude's session root" '$HOME/.claude/projects' "$FS_HARNESS_SESSION_ROOT"
check "claude discovers its id" "discover" "$FS_HARNESS_ID_MODE"

echo ""
echo "== codex =="
fs_harness_session_caps codex
check "codex is resumable" "true" "$FS_HARNESS_RESUMABLE"
# shellcheck disable=SC2016  # comparing against a literal unexpanded $HOME token
check "codex's session root" '$HOME/.codex/sessions' "$FS_HARNESS_SESSION_ROOT"
check "codex discovers its id" "discover" "$FS_HARNESS_ID_MODE"

echo ""
echo "== pi =="
fs_harness_session_caps pi
check "pi is resumable" "true" "$FS_HARNESS_RESUMABLE"
# shellcheck disable=SC2016  # comparing against a literal unexpanded $HOME token
check "pi's session root" '$HOME/.pi/sessions' "$FS_HARNESS_SESSION_ROOT"
check "pi's id is given, not discovered" "given" "$FS_HARNESS_ID_MODE"

echo ""
echo "== pi-local (the sealed-network dispatch key for pi) =="
fs_harness_session_caps pi-local
check "pi-local is resumable" "true" "$FS_HARNESS_RESUMABLE"
# shellcheck disable=SC2016  # comparing against a literal unexpanded $HOME token
check "pi-local's session root matches pi's" '$HOME/.pi/sessions' "$FS_HARNESS_SESSION_ROOT"
check "pi-local's id is given, not discovered" "given" "$FS_HARNESS_ID_MODE"

echo ""
echo "== an unknown harness =="
fs_harness_session_caps some-future-harness
check "an unknown harness is not resumable" "false" "$FS_HARNESS_RESUMABLE"
check "an unknown harness has no session root" "" "$FS_HARNESS_SESSION_ROOT"
check "an unknown harness has no id mode" "" "$FS_HARNESS_ID_MODE"

echo ""
echo "== a stale result does not leak across calls =="
fs_harness_session_caps claude
fs_harness_session_caps some-future-harness
check "resumable resets to false" "false" "$FS_HARNESS_RESUMABLE"
check "session root resets to empty" "" "$FS_HARNESS_SESSION_ROOT"
check "id mode resets to empty" "" "$FS_HARNESS_ID_MODE"

echo ""
echo "== fs_session_discover_id: given mode echoes =="
check "pi given mode echoes the supplied id" "abc-123" \
    "$(fs_session_discover_id pi "" "abc-123")"

echo ""
echo "== fs_session_discover_id: discover mode, empty/missing dir =="
discover_tmp="$(mktemp -d)"
trap 'rm -rf -- "$discover_tmp"' EXIT
check "no store dir yields empty" "" \
    "$(fs_session_discover_id claude "$discover_tmp/does-not-exist" "")"
mkdir -p "$discover_tmp/empty-project"
check "an empty store dir yields empty" "" \
    "$(fs_session_discover_id claude "$discover_tmp/empty-project" "")"

echo ""
echo "== fs_session_discover_id: discover mode, newest mtime wins =="
mkdir -p "$discover_tmp/proj/sub"
touch -d '2024-01-01 00:00:00' "$discover_tmp/proj/older-session.jsonl"
touch -d '2024-01-02 00:00:00' "$discover_tmp/proj/sub/newer-session.jsonl"
check "the newest transcript's stem wins" "newer-session" \
    "$(fs_session_discover_id claude "$discover_tmp/proj" "")"

rm -rf -- "$discover_tmp"
trap - EXIT

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
