#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/20-run-index.sh — the run store's hot-path readers:
# fs_pm_env_get (fork-sandbox-lib.sh) answers exactly as the `sed | tail` it
# replaced did, and every lookup the run index serves agrees with a full
# scan of the store -- on a legacy store with no index, once it is built,
# once it is deleted, half-built or made stale by a write that did not keep
# it, and across the postmaster's own spawn and harvest writes.
#
# Usage: tests/postmaster/20-run-index.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../scripts/fork-sandbox-lib.sh
source "$repo_dir/scripts/fork-sandbox-lib.sh"

echo "== fs_pm_env_get: same output as sed | tail =="

# The implementation fs_pm_env_get replaced, kept here as the oracle.
old_env_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n1
}

eg_dir="$work/env-get"
mkdir -p "$eg_dir"
printf 'A=1\nB=x=y=z\nEMPTY=\nA=2\nAA=nope\n aA=no\nSP= lead and trail \nBS=a\\nb\\\\c\nGLOB=*?[x]\n' \
    > "$eg_dir/rec.env"
printf 'A=1\nLAST=unterminated' > "$eg_dir/noeol.env"
printf 'LAST=first\nLAST=second' > "$eg_dir/noeol-dup.env"
printf 'LAST=only\n' > "$eg_dir/eol.env"
: > "$eg_dir/empty.env"
mkdir -p "$eg_dir/dir.env"

for case in rec:A rec:B rec:EMPTY rec:AA rec:aA rec:SP rec:BS rec:GLOB rec:MISSING \
            noeol:A noeol:LAST noeol-dup:LAST eol:LAST empty:A dir:A nofile:A; do
    file="$eg_dir/${case%%:*}.env" key="${case#*:}"
    # Raw bytes, trailing newline included: od shows what $(...) would hide.
    want="$(old_env_get "$file" "$key" | od -An -c)"
    got="$(fs_pm_env_get "$file" "$key" | od -An -c)"
    check "fs_pm_env_get $case: same bytes as sed | tail" "$want" "$got"
    want="$(old_env_get "$file" "$key")"
    fs_pm_env_read got "$file" "$key"
    check "fs_pm_env_read $case: same value as sed | tail" "$want" "$got"
done

echo "== run index: indexed lookups agree with the full scan =="

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
ri_st="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
ri_idx="$ri_st/run-index"
mkdir -p "$ri_st/runs" "$ri_st/harvested"
T1=aaaa1111-0000-0000-0000-000000000001
T2=bbbb2222-0000-0000-0000-000000000002
T3=cccc3333-0000-0000-0000-000000000003
T4=dddd4444-0000-0000-0000-000000000004
ri_agents=(alice bob carol dave erin zed)
ri_tids=("$T1" "$T2" "$T3" "$T4" "../evil" "")

# ri_rec <rid> <harvested 0|1> <record line>...: a record written straight
# into the store, the way a postmaster that predates the index left it.
ri_rec() {
    local rid="$1" harvested="$2"; shift 2
    printf '%s\n' "$@" > "$ri_st/runs/$rid.env"
    (( harvested )) && : > "$ri_st/harvested/$rid"
    return 0
}
ri_rec r-100-a   0 AGENT=alice "THREAD=$T1" BACKEND=local
# Same seat, a second live run whose name sorts around r-100-a's.
ri_rec r-100-a-2 0 AGENT=alice "THREAD=$T1" BACKEND=local
ri_rec r-101-b   1 AGENT=bob "THREAD=$T1" REPLIES=1 OUTCOME=clean
# Appended keys: the last AGENT and THREAD are the current ones.
ri_rec r-102-c   0 AGENT=carol "THREAD=$T1" RUN_DIR=/nowhere AGENT=bob "THREAD=$T2"
ri_rec r-103-d   1 AGENT=alice "THREAD=$T2" HARVESTED_AT=2026-01-01T00:00:00Z
ri_rec r-104-e   1 AGENT=dave "THREAD=$T3"
ri_rec r-105-f   0 AGENT=erin "THREAD=../evil"
ri_rec r-106-g   0 AGENT=erin
ri_rec r-107-h   0 AGENT=carol "THREAD=$T2" WOKEN_AT_SHA=abc WOKEN_AT_VERSION=2
printf 'AGENT=dave\nTHREAD=%s' "$T3" > "$ri_st/runs/r-109-noeol.env"

# The oracle: the full scans fs_pm_find_live_run and pm_thread_is_quiescent
# ran before the index, over old_env_get.
ri_old_find() {
    local f rid
    for f in "$ri_st/runs"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$ri_st/harvested/$rid" ]] && continue
        if [[ "$(old_env_get "$f" AGENT)" == "$1" && "$(old_env_get "$f" THREAD)" == "$2" ]]; then
            printf '%s' "$rid"; return 0
        fi
    done
    return 1
}
ri_old_quiescent() {
    local f
    for f in "$ri_st/runs"/*.env; do
        [[ -e "$f" ]] || continue
        [[ "$(old_env_get "$f" THREAD)" == "$1" ]] || continue
        [[ -e "$ri_st/harvested/$(basename -- "$f" .env)" ]] || return 1
    done
    return 0
}
ri_oracle() {
    local a t
    for a in "${ri_agents[@]}"; do
        for t in "${ri_tids[@]}"; do
            printf 'find %s %s = %s\n' "$a" "$t" "$(ri_old_find "$a" "$t" || echo -)"
        done
    done
    for t in "${ri_tids[@]}"; do
        printf 'quiescent %s = %s\n' "$t" "$(ri_old_quiescent "$t" && echo yes || echo no)"
    done
}

# The same questions through the postmaster's own code, sourced.
# shellcheck disable=SC1090
ri_pm() { ( source "$postmaster"; "$@" ); }
ri_answers() {
    local a t
    for a in "${ri_agents[@]}"; do
        for t in "${ri_tids[@]}"; do
            printf 'find %s %s = %s\n' "$a" "$t" "$(fs_pm_find_live_run "$a" "$t" || echo -)"
        done
    done
    for t in "${ri_tids[@]}"; do
        printf 'quiescent %s = %s\n' "$t" "$(pm_thread_is_quiescent "$t" && echo yes || echo no)"
    done
}
ri_status() {
    local t
    for t in "$T1" "$T2" "$T3" "$T4"; do cmd_status_json "$t"; echo; done
}
ri_fresh() { ri_pm fs_pm_index_gen g && echo fresh || echo stale; }
ri_live_entries() {
    local f out=""
    for f in "$ri_idx/live"/*.env; do [[ -e "$f" ]] && out+="${f##*/} "; done
    printf '%s' "$out"
}
ri_unharvested() {
    local f rid out=""
    for f in "$ri_st/runs"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$ri_st/harvested/$rid" ]] || out+="$rid.env "
    done
    printf '%s' "$out"
}

# 1. A legacy store: no index at all.
check "legacy store: no index yet" stale "$(ri_fresh)"
oracle="$(ri_oracle)"
check "legacy store: lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
status_scan="$(ri_pm ri_status)"
contains "legacy store: status --json lists a thread's runs" "$status_scan" r-100-a-2

# 2. Backfilled.
ri_pm fs_pm_index_ensure
check "backfill: the index is complete and fresh" fresh "$(ri_fresh)"
check "backfill: live entries are exactly the unharvested runs" "$(ri_unharvested)" "$(ri_live_entries)"
check "backfill: indexed lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
check "backfill: status --json is byte-identical to the full scan's" "$status_scan" "$(ri_pm ri_status)"
check "backfill: no entry for a THREAD that is not a safe name" "" \
    "$(find "$ri_idx/thread" -mindepth 1 -maxdepth 1 ! -name '????????-*' -printf '%f ')"

# The lookups really read the index: drop one entry behind its back (the
# stamp stays fresh) and the answer moves. Then put it back.
rm -f -- "$ri_idx/thread/$T1/r-100-a.env"
check "backfill: lookups are served from the index" "r-100-a-2" "$(ri_pm fs_pm_find_live_run alice "$T1")"
not_contains "backfill: status --json is served from the index" "$(ri_pm cmd_status_json "$T1")" '"r-100-a"'
rm -f -- "$ri_idx/thread/$T1/r-100-a-2.env"
check "backfill: quiescence is served from the index" yes \
    "$(ri_pm pm_thread_is_quiescent "$T1" && echo yes || echo no)"
: > "$ri_idx/thread/$T1/r-100-a.env"
: > "$ri_idx/thread/$T1/r-100-a-2.env"
check "backfill: entries put back, the answers are the full scan's again" "$oracle" "$(ri_pm ri_answers)"

# 3. Deleted (or its completion stamp lost): readers fall back, the next
# pass rebuilds it.
rm -f -- "$ri_idx/complete"
check "no stamp: the index is not trusted" stale "$(ri_fresh)"
check "no stamp: lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
ri_pm fs_pm_index_ensure
check "no stamp: rebuilt" fresh "$(ri_fresh)"
check "no stamp: rebuilt lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
rm -rf -- "$ri_idx"
ri_pm fs_pm_index_ensure
check "deleted: rebuilt from nothing" fresh "$(ri_fresh)"
check "deleted: rebuilt lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"

# 4. Half-built: a crash mid-backfill leaves entries missing, the next
# generation's stamp unrenamed and no `complete`.
rm -f -- "$ri_idx/complete" "$ri_idx/live/r-100-a.env" "$ri_idx/thread/$T2"/*
printf 'half\n' > "$ri_idx/complete.new"
check "half-built: not trusted" stale "$(ri_fresh)"
check "half-built: lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
ri_pm fs_pm_index_ensure
check "half-built: rebuilt" fresh "$(ri_fresh)"
check "half-built: rebuilt live entries are exactly the unharvested runs" "$(ri_unharvested)" "$(ri_live_entries)"
check "half-built: rebuilt lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
check "half-built: rebuilt status --json is byte-identical" "$status_scan" "$(ri_pm ri_status)"

# 5. Writes that do not keep the index (an older postmaster, a hand edit):
# a new record, and a harvested marker taken away.
sleep 0.01
ri_rec r-108-new 0 AGENT=zed "THREAD=$T4"
rm -f -- "$ri_st/harvested/r-101-b"
oracle="$(ri_oracle)"
contains "foreign writes: the oracle sees the new live run" "$oracle" "find zed $T4 = r-108-new"
check "foreign writes: the index is stale" stale "$(ri_fresh)"
check "foreign writes: lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
status_scan="$(ri_pm ri_status)"
ri_pm fs_pm_index_ensure
check "foreign writes: rebuilt" fresh "$(ri_fresh)"
check "foreign writes: rebuilt lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"
check "foreign writes: rebuilt status --json is byte-identical" "$status_scan" "$(ri_pm ri_status)"

# 6. The postmaster's own record and marker writes keep the index fresh.
ri_spawn() {
    local ig
    pm_run_record_begin ig r-110-own "$T4"
    printf 'AGENT=zed\nTHREAD=%s\n' "$T4" > "$RUNS/r-110-own.env"
    fs_pm_index_settle "$ig"
}
ri_pm ri_spawn
check "own spawn: still fresh" fresh "$(ri_fresh)"
check "own spawn: live entry written" "$(ri_unharvested)" "$(ri_live_entries)"
ri_pm pm_run_env_set "$ri_st/runs/r-110-own.env" PENDING_MSGS m1
check "own field write: still fresh" fresh "$(ri_fresh)"
ri_pm pm_mark_harvested r-110-own
check "own harvest: still fresh" fresh "$(ri_fresh)"
check "own harvest: no stale live entry" "$(ri_unharvested)" "$(ri_live_entries)"
oracle="$(ri_oracle)"
check "own writes: lookups agree with the full scan" "$oracle" "$(ri_pm ri_answers)"

finish_suite
