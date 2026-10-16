#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/10-k8s-fetch-miss.sh — fork-sandbox-postmaster.sh: backend:
# k8s seats -- fetch-miss deferral and orphaned review targets.
#
# Usage: tests/postmaster/10-k8s-fetch-miss.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== backend: k8s seats ==\n'
# ============================================================

export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
new_root K8S_TEST_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR="$K8S_TEST_CONFIG_DIR"

k8s_wake_fixture
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"

k8s_rt1_seed
k8s_uh_seed
k8s_origin_mirror_seed

# ---- fetch-miss cases: the origin is a pull mirror that has not synced yet.
# A miss defers instead of flagging; each `once` is a fresh postmaster
# process, so a resolve on a later `once` is also a restart picking the wait
# up from disk. fw_set rewrites a key in a pending record (a clock stand-in:
# the cases never sleep). ----
export FORK_SANDBOX_POSTMASTER_FETCH_WINDOW=120
fw_file() { printf '%s/fetch-wait/%s/%s' "$PM_STATE_DIR" "$1" "$2"; }
fw_set() { sed -i "s/^$3=.*/$3=$4/" "$(fw_file "$1" "$2")"; }
fw_get() { sed -n "s/^$3=//p" "$(fw_file "$1" "$2")"; }
# fw_commit <branch>: a commit in the origin's source repo, NOT yet pushed.
fw_commit() {
    git -C "$UH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
        commit -q --allow-empty -m "mirror lag $1"
    git -C "$UH_ORIGIN_SRC" rev-parse HEAD
}
fw_sync() { git -C "$UH_ORIGIN_SRC" push -q -f "$UH_ORIGIN_BARE" "$2:refs/heads/$1"; }

# case 9: the sha is not on origin at first and arrives inside the window.
uh_kickoff ken; fw9_mid="$UH_MID"
fw9_tid="$(thread_of "$fw9_mid")"; fw9_short="${fw9_tid:0:8}"
fw9_sha="$(fw_commit feature/late)"
reply_msg '@ci-demo' "$fw9_mid" 'pushed' --to '@ken' --upstream-head "feature/late:$fw9_sha" >/dev/null
start=$SECONDS
once
check "fetch-miss case 9: the pass did not sleep on the miss" 1 "$(( SECONDS - start < 10 ))"
check "fetch-miss case 9: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$fw9_tid" ]] && echo 1 || echo 0 )"
contains "fetch-miss case 9: a deferral event with the attempt count" \
    "$(cat "$work/once.out")" "pm defer thread=$fw9_short agent=ken reason=fetch-miss attempt=1"
check "fetch-miss case 9: ken was not woken" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "fetch-miss case 9: the wait is recorded under the state dir" 1 \
    "$( [[ -f "$(fw_file "$fw9_tid" ken)" ]] && echo 1 || echo 0 )"
check "fetch-miss case 9: the record names the announced head" "feature/late $fw9_sha" "$(fw_get "$fw9_tid" ken KEY)"
once
check "fetch-miss case 9: not due yet -- the next pass does not fetch or defer again" 0 \
    "$(grep -c 'reason=fetch-miss' "$work/once.out")"
check "fetch-miss case 9: still one attempt on record" 1 "$(fw_get "$fw9_tid" ken ATTEMPTS)"
check "fetch-miss case 9: a pending wait keeps the thread from quiescence" 1 \
    "$( [[ -n "$(find "$PM_STATE_DIR/fetch-wait/$fw9_tid" -type f 2>/dev/null)" ]] && echo 1 || echo 0 )"
fw_set "$fw9_tid" ken NOT_BEFORE 0
once
contains "fetch-miss case 9: a due re-check that still misses defers again, attempt 2" \
    "$(cat "$work/once.out")" "pm defer thread=$fw9_short agent=ken reason=fetch-miss attempt=2"
check "fetch-miss case 9: the window is not restarted by a re-check" 1 \
    "$( [[ "$(fw_get "$fw9_tid" ken SINCE)" -le "$(date +%s)" ]] && echo 1 || echo 0 )"
fw_sync feature/late "$fw9_sha"
fw_set "$fw9_tid" ken NOT_BEFORE 0
once
contains "fetch-miss case 9: the mirror synced, the wait resolves" \
    "$(cat "$work/once.out")" "pm defer-resolved thread=$fw9_short agent=ken reason=fetch-miss attempts=2"
check "fetch-miss case 9: ken then wakes carrying the extra ref" \
    "upstream=$fw9_sha" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "fetch-miss case 9: the record is gone" 0 "$(find "$PM_STATE_DIR/fetch-wait" -type f 2>/dev/null | wc -l)"
check "fetch-miss case 9: the thread was never flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$fw9_tid" ]] && echo 1 || echo 0 )"

# case 10: the sha never arrives -- flagged once the window has passed, not before.
uh_kickoff ken; fw10_mid="$UH_MID"
fw10_tid="$(thread_of "$fw10_mid")"; fw10_short="${fw10_tid:0:8}"
fw10_sha="$(fw_commit feature/never)"
reply_msg '@ci-demo' "$fw10_mid" 'pushed' --to '@ken' --upstream-head "feature/never:$fw10_sha" >/dev/null
once
now="$(date +%s)"
fw_set "$fw10_tid" ken SINCE "$(( now - 100 ))"
fw_set "$fw10_tid" ken NOT_BEFORE 0
once
check "fetch-miss case 10: 100s into a 120s window it still only defers" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$fw10_tid" ]] && echo 1 || echo 0 )"
contains "fetch-miss case 10: ... as attempt 2" "$(cat "$work/once.out")" "reason=fetch-miss attempt=2"
check "fetch-miss case 10: the last attempt is scheduled no later than the window's end" 1 \
    "$( [[ "$(fw_get "$fw10_tid" ken NOT_BEFORE)" -le "$(( $(fw_get "$fw10_tid" ken SINCE) + 120 ))" ]] && echo 1 || echo 0 )"
fw_set "$fw10_tid" ken SINCE "$(( now - 130 ))"
fw_set "$fw10_tid" ken NOT_BEFORE 0
once
contains "fetch-miss case 10: past the window the thread is flagged as before" \
    "$(cat "$PM_STATE_DIR/needs-operator/$fw10_tid" 2>/dev/null)" "upstream head feature/never $fw10_sha not found"
contains "fetch-miss case 10: with the upstream-head keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$fw10_short reason=upstream-head"
check "fetch-miss case 10: ken was never woken" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "fetch-miss case 10: the record is gone" 0 "$(find "$PM_STATE_DIR/fetch-wait" -type f 2>/dev/null | wc -l)"
once
check "fetch-miss case 10: a flagged thread is not re-dispatched" 0 "$(grep -c 'reason=fetch-miss' "$work/once.out")"

# case 11: a second announcement replaces the pending one, with a fresh window.
uh_kickoff ken; fw11_mid="$UH_MID"
fw11_tid="$(thread_of "$fw11_mid")"
fw11_a="$(fw_commit feature/v1)"
fw11_r="$(reply_msg '@ci-demo' "$fw11_mid" 'pushed' --to '@ken' --upstream-head "feature/v1:$fw11_a")"
once
fw_set "$fw11_tid" ken SINCE "$(( $(date +%s) - 110 ))"
fw_set "$fw11_tid" ken ATTEMPTS 5
fw11_b="$(fw_commit feature/v2)"
reply_msg '@ci-demo' "$fw11_r" 'force-pushed again' --to '@ken' --upstream-head "feature/v2:$fw11_b" >/dev/null
once
check "fetch-miss case 11: the pending wait now names the newest head" "feature/v2 $fw11_b" "$(fw_get "$fw11_tid" ken KEY)"
check "fetch-miss case 11: its window started fresh" 1 \
    "$( [[ "$(fw_get "$fw11_tid" ken SINCE)" -ge "$(( $(date +%s) - 20 ))" ]] && echo 1 || echo 0 )"
check "fetch-miss case 11: and its attempt count with it" 1 "$(fw_get "$fw11_tid" ken ATTEMPTS)"
check "fetch-miss case 11: still one record for the seat" 1 "$(find "$PM_STATE_DIR/fetch-wait" -type f | wc -l)"
check "fetch-miss case 11: no flag from the old window" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$fw11_tid" ]] && echo 1 || echo 0 )"
fw_sync feature/v2 "$fw11_b"
fw_set "$fw11_tid" ken NOT_BEFORE 0
once
check "fetch-miss case 11: the newest head is what the seat is handed" \
    "upstream=$fw11_b" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"

# case 12: while one thread waits on the mirror, others route normally.
uh_kickoff ken; fw12_mid="$UH_MID"
fw12_tid="$(thread_of "$fw12_mid")"
fw12_sha="$(fw_commit feature/slow)"
reply_msg '@ci-demo' "$fw12_mid" 'pushed' --to '@ken' --upstream-head "feature/slow:$fw12_sha" >/dev/null
once
check "fetch-miss case 12 setup: ken's thread is waiting" 1 "$( [[ -f "$(fw_file "$fw12_tid" ken)" ]] && echo 1 || echo 0 )"
send_msg '@carol' '@kai' 'another thread' 'hello kai' 8 >/dev/null
start=$SECONDS
once
check "fetch-miss case 12: the other thread's seat woke while ken waits" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "fetch-miss case 12: the pass did not sleep" 1 "$(( SECONDS - start < 10 ))"
check "fetch-miss case 12: ken is still waiting" 1 "$( [[ -f "$(fw_file "$fw12_tid" ken)" ]] && echo 1 || echo 0 )"

# case 13: the review target a `follow` seat is checked out at gets the same wait.
uh_kickoff ken
fw13_branch="feature/target-lag"
fw13_sha="$(fw_commit "$fw13_branch")"
printf '%s\n' 'review this' > "$work/body.tmp"
fw13_mid="$("$MAIL" send --from '@carol' --to '@kai' --subject 'review target lag' \
    --body "$work/body.tmp" --hops 8 --review-target "$fw13_branch:$fw13_sha" 2>/dev/null)"
fw13_tid="$(thread_of "$fw13_mid")"; fw13_short="${fw13_tid:0:8}"
: > "$STUB_ARGV_LOG"
once
contains "fetch-miss case 13: a review-target miss defers" \
    "$(cat "$work/once.out")" "pm defer thread=$fw13_short agent=kai reason=fetch-miss attempt=1"
check "fetch-miss case 13: kai is not woken and the thread not flagged" 0 \
    "$(( $(grep -c -- '^--k8s$' "$STUB_ARGV_LOG") + $( [[ -e "$PM_STATE_DIR/needs-operator/$fw13_tid" ]] && echo 1 || echo 0 ) ))"
fw_sync "$fw13_branch" "$fw13_sha"
fw_set "$fw13_tid" kai NOT_BEFORE 0
once
check "fetch-miss case 13: after the sync kai is checked out at the target" \
    "$fw13_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"
fw_gone="$(git -C "$PROJECT_DIR" cat-file -e "$fw13_sha^{commit}" 2>/dev/null && echo 1 || echo 0)"
check "fetch-miss case 13: the sha was fetched into the project repo" 1 "$fw_gone"

# ---- orphaned target: a force-push before the first review. The target sha
# is never fetchable; the branch is force-pushed to a commit with unrelated
# history. ----
# ot_unrelated <label>: a root commit in the origin's source repo, not pushed.
ot_unrelated() {
    local tree
    tree="$(git -C "$UH_ORIGIN_SRC" mktree < /dev/null)"
    git -C "$UH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
        commit-tree -m "unrelated $1" "$tree"
}
ot_kickoff() {
    printf '%s\n' 'review this' > "$work/body.tmp"
    OT_MID="$("$MAIL" send --from '@carol' --to '@kai' --subject "orphaned target $1" \
        --body "$work/body.tmp" --hops 8 --review-target "$1:$2" 2>/dev/null)"
    OT_TID="$(thread_of "$OT_MID")"
    : > "$STUB_ARGV_LOG"
    once
}

# case 14: nothing reviewed yet -- the version is re-frozen at the new head.
ot14_branch="feature/rebased"
ot14_old="$(fw_commit "$ot14_branch")"
ot_kickoff "$ot14_branch" "$ot14_old"; ot14_tid="$OT_TID"; ot14_short="${ot14_tid:0:8}"
contains "orphaned target case 14 setup: kai's wake waits on the target" \
    "$(cat "$work/once.out")" "pm defer thread=$ot14_short agent=kai reason=fetch-miss attempt=1"
ot14_new="$(ot_unrelated 14)"
fw_sync "$ot14_branch" "$ot14_new"
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$OT_MID" 'force-pushed' --to '@kai' --upstream-head "$ot14_branch:$ot14_new" >/dev/null
once
check "orphaned target case 14: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$ot14_tid" ]] && echo 1 || echo 0 )"
contains "orphaned target case 14: the re-freeze is logged" "$(cat "$work/once.out")" \
    "pm review-target-refrozen thread=$ot14_short version=1 from=${ot14_old:0:12} to=${ot14_new:0:12}"
check "orphaned target case 14: kai spawned at the new head" "$ot14_new" "$(argv_after --checkout "$STUB_ARGV_LOG")"
ot14_rt="$(cat "$PM_STATE_DIR/review-target/$ot14_tid.env")"
contains "orphaned target case 14: the target file holds the new head" "$ot14_rt" "SHA=$ot14_new"
contains "orphaned target case 14: at the same version" "$ot14_rt" "VERSION=1"
contains "orphaned target case 14: set by the postmaster" "$ot14_rt" "SET_BY=@postmaster"
check "orphaned target case 14: the version's history pin is the new head" "$ot14_new" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$ot14_tid/review-v1" 2>/dev/null)"
check "orphaned target case 14: no fetch-wait record is left" 0 \
    "$(find "$PM_STATE_DIR/fetch-wait/$ot14_tid" -type f 2>/dev/null | wc -l)"

# case 15: a seat already replied on the version -- flag at once, keep the target.
ot15_branch="feature/rebased-after-review"
ot15_old="$(fw_commit "$ot15_branch")"
ot_kickoff "$ot15_branch" "$ot15_old"; ot15_tid="$OT_TID"; ot15_short="${ot15_tid:0:8}"
ot15_reply="$(reply_msg '@kai' "$OT_MID" 'my review' --to '@carol')"
ot15_file="$(grep -l "^Message-ID: $ot15_reply$" "$FORK_SANDBOX_MAIL_ROOT/threads/$ot15_tid"/*.msg)"
sed -i "s/^X-Hops: .*/&\nX-AI-Persona: kai\nX-Version: 1/" "$ot15_file"
ot15_new="$(ot_unrelated 15)"
fw_sync "$ot15_branch" "$ot15_new"
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$OT_MID" 'force-pushed' --to '@kai' --upstream-head "$ot15_branch:$ot15_new" >/dev/null
once
contains "orphaned target case 15: flagged at once, naming the orphan and the newest head" \
    "$(cat "$PM_STATE_DIR/needs-operator/$ot15_tid" 2>/dev/null)" \
    "review target $ot15_branch $ot15_old orphaned by a force-push (newest head $ot15_branch $ot15_new)"
contains "orphaned target case 15: with the review-target keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$ot15_short reason=review-target"
check "orphaned target case 15: kai was not woken" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
contains "orphaned target case 15: the target is not moved" \
    "$(cat "$PM_STATE_DIR/review-target/$ot15_tid.env")" "SHA=$ot15_old"
check "orphaned target case 15: no fetch-wait record is left" 0 \
    "$(find "$PM_STATE_DIR/fetch-wait/$ot15_tid" -type f 2>/dev/null | wc -l)"

# case 16: a target that is merely lagging, with no newer head, still waits.
ot16_branch="feature/just-lagging"
ot16_sha="$(fw_commit "$ot16_branch")"
ot_kickoff "$ot16_branch" "$ot16_sha"; ot16_tid="$OT_TID"
not_contains "orphaned target case 16: no re-freeze without an upstream head" \
    "$(cat "$work/once.out")" "review-target-refrozen"
check "orphaned target case 16: the wait is pending, the thread unflagged" 1 \
    "$( [[ -f "$(fw_file "$ot16_tid" kai)" && ! -e "$PM_STATE_DIR/needs-operator/$ot16_tid" ]] && echo 1 || echo 0 )"

# ot_panel_v1 <branch> <sha>: a v1 To the two-follower panel, routed once.
ot_panel_v1() {
    printf '%s\n' 'v1' > "$work/body.tmp"
    OT_MID="$("$MAIL" send --from '@carol' --to '@panel' --subject "panel v1 $1" \
        --body "$work/body.tmp" --hops 8 --review-target "$1:$2" 2>/dev/null)"
    OT_TID="$(thread_of "$OT_MID")"
    : > "$STUB_ARGV_LOG"
    once
}
# The distinct --checkout shas in the argv log.
ot_checkouts() { awk '$0=="--checkout"{getline; print}' "$STUB_ARGV_LOG" | sort -u; }

# case 17: a replay of a real panel that stalled. v1 is posted To the panel
# at a head a force-push had already orphaned; both seats' windows lapse and
# flag the thread; the new head is then announced To the `sets` seat only.
# The re-freeze must wake the whole panel at the new head and clear the
# flag, with no operator mail.
ot17_branch="feature/replay-stall"
ot17_old="$(fw_commit "$ot17_branch")"
ot_panel_v1 "$ot17_branch" "$ot17_old"; ot17_tid="$OT_TID"; ot17_short="${ot17_tid:0:8}"
for s in kai kye; do
    contains "orphaned target case 17 setup: $s waits on the orphaned v1" \
        "$(cat "$work/once.out")" "pm defer thread=$ot17_short agent=$s reason=fetch-miss attempt=1"
    fw_set "$ot17_tid" "$s" SINCE "$(( $(date +%s) - 130 ))"
    fw_set "$ot17_tid" "$s" NOT_BEFORE 0
done
once
contains "orphaned target case 17 setup: the lapsed windows flag the thread" \
    "$(cat "$PM_STATE_DIR/needs-operator/$ot17_tid" 2>/dev/null)" \
    "review target $ot17_branch $ot17_old not found in the project repo"
check "orphaned target case 17 setup: no seat is left waiting" 0 \
    "$(find "$PM_STATE_DIR/fetch-wait/$ot17_tid" -type f 2>/dev/null | wc -l)"
ot17_new="$(ot_unrelated 17)"
fw_sync "$ot17_branch" "$ot17_new"
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$OT_MID" 'force-pushed' --to '@ken' --upstream-head "$ot17_branch:$ot17_new" >/dev/null
once
contains "orphaned target case 17: v1 is re-frozen at the new head" "$(cat "$work/once.out")" \
    "pm review-target-refrozen thread=$ot17_short version=1 from=${ot17_old:0:12} to=${ot17_new:0:12}"
contains "orphaned target case 17: both followers are queued" "$(cat "$work/once.out")" \
    "pm review-target-refrozen-wake thread=$ot17_short agents=kai,kye"
for s in ken kai kye; do
    check "orphaned target case 17: $s spawns exactly once, in the same pass" 1 \
        "$(grep -c "^pm spawn thread=$ot17_short agent=$s " "$work/once.out")"
done
contains "orphaned target case 17: the panel is at the new head" "$(ot_checkouts)" "$ot17_new"
not_contains "orphaned target case 17: no seat at the orphaned head" "$(ot_checkouts)" "$ot17_old"
# The announcement itself clears the lapsed wait's flag (an upstream head
# resets the thread), so no operator mail is needed for that either.
check "orphaned target case 17: the flag is cleared without an operator" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$ot17_tid" ]] && echo 1 || echo 0 )"
check "orphaned target case 17: no fetch-wait record is left" 0 \
    "$(find "$PM_STATE_DIR/fetch-wait/$ot17_tid" -type f 2>/dev/null | wc -l)"
once
not_contains "orphaned target case 17: a later pass re-freezes and queues nothing" \
    "$(cat "$work/once.out")" "review-target-refrozen"

# case 18: the same, but the head is announced while both seats still wait:
# never flagged, and each seat wakes exactly once.
ot18_branch="feature/replay-in-window"
ot18_old="$(fw_commit "$ot18_branch")"
ot_panel_v1 "$ot18_branch" "$ot18_old"; ot18_tid="$OT_TID"; ot18_short="${ot18_tid:0:8}"
ot18_new="$(ot_unrelated 18)"
fw_sync "$ot18_branch" "$ot18_new"
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$OT_MID" 'force-pushed' --to '@ken' --upstream-head "$ot18_branch:$ot18_new" >/dev/null
once
not_contains "orphaned target case 18: waiting seats are not queued twice" \
    "$(cat "$work/once.out")" "review-target-refrozen-wake"
# Counted from this thread's events: other threads' stub replies wake seats
# in the same pass.
for s in ken kai kye; do
    check "orphaned target case 18: $s spawns exactly once" 1 \
        "$(grep -c "^pm spawn thread=$ot18_short agent=$s " "$work/once.out")"
done
contains "orphaned target case 18: the panel is at the new head" "$(ot_checkouts)" "$ot18_new"
not_contains "orphaned target case 18: no seat at the orphaned head" "$(ot_checkouts)" "$ot18_old"
check "orphaned target case 18: the thread was never flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator-journal/$ot18_tid" ]] && echo 1 || echo 0 )"
unset FORK_SANDBOX_POSTMASTER_FETCH_WINDOW

refuses "fetch-miss: a non-numeric FETCH_WINDOW refuses deliver" \
    env FORK_SANDBOX_POSTMASTER_FETCH_WINDOW=soon "$postmaster" deliver --project "$PROJECT_DIR" --once
refuses "fetch-miss: a negative FETCH_WINDOW refuses deliver" \
    env FORK_SANDBOX_POSTMASTER_FETCH_WINDOW=-5 "$postmaster" deliver --project "$PROJECT_DIR" --once
git -C "$PROJECT_DIR" remote remove origin

finish_suite
