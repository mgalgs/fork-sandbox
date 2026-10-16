#!/usr/bin/env bash
# fork-sandbox-postmaster-test.sh — Exercise fork-sandbox-postmaster.sh's
# routing rules, wake spawning, and reply harvest against throwaway
# fixtures, stubbing fork-sandbox.sh the same way tests/lkml-round-test.sh
# stubbed it for lkml-round.sh.
#
# Usage: tests/fork-sandbox-postmaster-test.sh [-j JOBS] [FILE...]
#
# The checks live in tests/postmaster/NN-*.sh and share their fixtures
# through tests/postmaster/lib.sh (see its header for the stub and the
# invented fleet). This runner runs those files side by side, at most JOBS
# at once (default: nproc), prints each file's output in file order as soon
# as it and every file before it have finished, then one combined
# "N passed, M failed" line. It exits non-zero when any check failed or any
# file died before printing its own summary line.
#
# FILE picks files to run instead of all of them, by name prefix: `05` or
# `05-retry` runs tests/postmaster/05-retry.sh. Each file also runs alone,
# directly: tests/postmaster/05-retry.sh.
#
# Each file builds its own fixtures from lib.sh -- work dir, stub argv log,
# run dirs, fleet and personas -- so two files never share mutable state.
# Within a file, groups run in order and some continue the state the group
# before them left (a mail store, an exported variable): when moving a
# group to another file, take the groups it leans on with it.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
chunk_dir="$repo_dir/tests/postmaster"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

jobs_max="$(nproc 2>/dev/null || echo 4)"
picks=()
while (( $# )); do
    case "$1" in
        -j) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "-j needs a positive integer" >&2; exit 2; }
            jobs_max="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) picks+=("$1"); shift ;;
    esac
done

chunks=()
if (( ${#picks[@]} )); then
    for p in "${picks[@]}"; do
        matched=0
        for f in "$chunk_dir/$p"*.sh; do
            [[ -e "$f" && "$f" != */lib.sh ]] || continue
            chunks+=("$f"); matched=1
        done
        (( matched )) || { echo "no file in tests/postmaster matches '$p'" >&2; exit 2; }
    done
else
    for f in "$chunk_dir"/[0-9]*.sh; do chunks+=("$f"); done
fi

out_dir="$(mktemp -d)"
trap 'rm -rf -- "$out_dir"' EXIT
trap 'kill $(jobs -p) 2>/dev/null; exit 130' INT TERM

pass=0 fail=0 broken=0 next=0

# Prints, in order, every finished file whose predecessors have all been
# printed, and adds its summary line to the totals.
emit_ready() {
    local name summary
    while (( next < ${#chunks[@]} )) && [[ -e "$out_dir/$next.rc" ]]; do
        name="${chunks[$next]#"$repo_dir/"}"
        printf '\n######## %s (%ss)\n' "$name" "$(cat "$out_dir/$next.secs")"
        cat -- "$out_dir/$next.out"
        summary="$(tail -n1 "$out_dir/$next.out")"
        if [[ "$summary" =~ ^([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
            pass=$(( pass + BASH_REMATCH[1] ))
            fail=$(( fail + BASH_REMATCH[2] ))
        else
            printf '  FAIL  %s exited %s without its summary line\n' \
                "$name" "$(cat "$out_dir/$next.rc")"
            broken=$(( broken + 1 ))
        fi
        next=$(( next + 1 ))
    done
}

running=0
for i in "${!chunks[@]}"; do
    while (( running >= jobs_max )); do
        wait -n; running=$(( running - 1 )); emit_ready
    done
    (
        start=$SECONDS
        "${chunks[$i]}" > "$out_dir/$i.out" 2>&1
        rc=$?
        echo $(( SECONDS - start )) > "$out_dir/$i.secs"
        echo "$rc" > "$out_dir/$i.rc"
    ) &
    running=$(( running + 1 ))
done
while (( running > 0 )); do
    wait -n; running=$(( running - 1 )); emit_ready
done
emit_ready

printf '\n%s passed, %s failed\n' "$pass" "$(( fail + broken ))"
(( fail + broken == 0 )) || exit 1
