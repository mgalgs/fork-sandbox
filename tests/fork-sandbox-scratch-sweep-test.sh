#!/usr/bin/env bash
# fork-sandbox-scratch-sweep-test.sh — Direct cases for fs_sweep_stale_scratch_roots
#
# Usage: tests/fork-sandbox-scratch-sweep-test.sh
#
# sandbox-backend-bwrap and sandbox-backend-container each call this sweep
# (fork-sandbox-lib.sh) before creating their own disk-backed scratch root,
# to reclaim one a SIGKILLed backend left behind. It used to gate on the
# root directory's own mtime alone -- but the root only ever holds tmp/ and
# home/, created once at launch and never touched again no matter how busy
# the sandbox inside it is, so an ordinary long-lived interactive session
# (the default for claude-sandboxed/agent-sandboxed; --exec is what opts
# out) looked exactly like a leak once it crossed FS_SCRATCH_STALE_SEC. This
# suite drives the sweep directly against fabricated roots so that
# regression does not need a real multi-hour sandbox to catch.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
lib="$repo_dir/scripts/fork-sandbox-lib.sh"
work="$(mktemp -d)"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}

# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib"

roots=(); holder_pid=""
cleanup() {
    [[ -n "$holder_pid" ]] && { kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null; }
    rm -rf -- "${roots[@]-}" "$work"
}
trap cleanup EXIT

# FS_SCRATCH_ROOT is computed once, at source time, from a fixed /var/tmp
# path -- not something a test can point elsewhere -- so these fabricated
# roots live in the same forks/ directory a real invocation would use,
# named so they cannot collide with one. A plain function, not run via
# "$(mkroot ...)" for its `roots` bookkeeping -- command substitution forks
# a subshell, so an append there would vanish with it; only the printed path
# is meant to cross that boundary, tracking is the caller's own job.
mkroot() {
    local name="$1" root
    root="$FS_SCRATCH_ROOT/forks/sandbox-scratch.sweep-test-$name-$$"
    mkdir -m 0700 "$root"
    mkdir "$root/tmp" "$root/home"
    printf '%s' "$root"
}

# A live owner's lock -- held by a still-running process, the same way each
# backend's SCRATCH_LOCK_FD holds it for its own lifetime -- must save the
# root regardless of age.
live_root="$(mkroot live)"; roots+=("$live_root" "$live_root.lock")
touch -d '7 hours ago' "$live_root"
ready_file="$work/lock-holder-ready"
flock "$live_root.lock" -c "touch '$ready_file'; sleep 5" &
holder_pid=$!
for _ in $(seq 1 50); do [[ -e "$ready_file" ]] && break; sleep 0.1; done
FS_SCRATCH_STALE_SEC=1 fs_sweep_stale_scratch_roots
check "a live-locked root survives the sweep even when old" "yes" \
    "$([[ -d "$live_root" ]] && echo yes || echo no)"
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null; holder_pid=""

# An orphaned lock file -- present, but nothing holds it, the state left by
# a backend that exited (cleanly or via SIGKILL) -- is reclaimed even
# though it is fresh: a live owner would already hold it.
orphan_root="$(mkroot orphan)"; roots+=("$orphan_root" "$orphan_root.lock")
: > "$orphan_root.lock"
FS_SCRATCH_STALE_SEC=999999 fs_sweep_stale_scratch_roots
check "a lock file with no live owner is reclaimed regardless of age" "no" \
    "$([[ -e "$orphan_root" ]] && echo yes || echo no)"

# No lock file at all -- the fallback for a root this fix predates -- still
# honors the old age-only rule.
old_nolock="$(mkroot old-nolock)"; roots+=("$old_nolock" "$old_nolock.lock")
touch -d '7 hours ago' "$old_nolock"
FS_SCRATCH_STALE_SEC=21600 fs_sweep_stale_scratch_roots
check "an old root with no lock file is reclaimed (fallback)" "no" \
    "$([[ -e "$old_nolock" ]] && echo yes || echo no)"

fresh_nolock="$(mkroot fresh-nolock)"; roots+=("$fresh_nolock" "$fresh_nolock.lock")
FS_SCRATCH_STALE_SEC=21600 fs_sweep_stale_scratch_roots
check "a fresh root with no lock file survives (fallback)" "yes" \
    "$([[ -d "$fresh_nolock" ]] && echo yes || echo no)"

# A lock file with no live owner still reclaims a read-only subtree under
# it -- the same chmod-before-rm fix each backend's own cleanup uses.
ro_root="$(mkroot readonly)"; roots+=("$ro_root" "$ro_root.lock")
mkdir -p "$ro_root/home/go/pkg/mod/x"
echo f > "$ro_root/home/go/pkg/mod/x/f"
chmod -R a-w "$ro_root/home/go/pkg/mod"
: > "$ro_root.lock"
FS_SCRATCH_STALE_SEC=999999 fs_sweep_stale_scratch_roots
check "a reclaimed root's read-only subtree is removed too" "no" \
    "$([[ -e "$ro_root" ]] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
