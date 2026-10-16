#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/11-k8s-harvest.sh — fork-sandbox-postmaster.sh: backend:
# k8s seats -- upstream-head resets, prior heads, Version: harvest.
#
# Usage: tests/postmaster/11-k8s-harvest.sh  (or all files at once:
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

# ---- upstream-head case 8: a malformed value (only the store can produce
# one) is ignored and logged, and resets nothing ----
uh_kickoff ken; uh8_mid="$UH_MID"
uh8_tid="$(thread_of "$uh8_mid")"
uh8_short="${uh8_tid:0:8}"
uh8_reply="$(reply_msg '@ci-demo' "$uh8_mid" 'pushed' --to '@ken')"
uh8_file="$(grep -l "^Message-ID: $uh8_reply$" "$FORK_SANDBOX_MAIL_ROOT/threads/$uh8_tid"/*.msg)"
sed -i "s/^X-Hops: .*/&\nX-Upstream-Head: not-a-sha-pair/" "$uh8_file"
once
check "upstream-head case 8: a malformed value writes no state file" 0 \
    "$( [[ -e "$PM_STATE_DIR/upstream-head/$uh8_tid.env" ]] && echo 1 || echo 0 )"
contains "upstream-head case 8: the ignored header is logged" \
    "$(cat "$work/once.out")" "pm upstream-head-ignored thread=$uh8_short reason=malformed"

# ---- upstream-head case 9: a carry to @operator -- recorded, resets, wakes
# nobody ----
uh_kickoff ken; uh9_mid="$UH_MID"
uh9_tid="$(thread_of "$uh9_mid")"
"$postmaster" flag "$uh9_tid" "needs a human" >/dev/null 2>&1
seq 1 5 > "$PM_STATE_DIR/spawns/$uh9_tid"
reply_msg '@ci-demo' "$uh9_mid" 'carried' --to '@operator' --upstream-head "$uh_branch:$uh_sha" >/dev/null
once
check "upstream-head case 9: a carry to @operator records the head" 1 \
    "$( [[ -e "$PM_STATE_DIR/upstream-head/$uh9_tid.env" ]] && echo 1 || echo 0 )"
check "upstream-head case 9: it clears the needs-operator flag" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$uh9_tid" ]] && echo 1 || echo 0 )"
check "upstream-head case 9: it resets the spawn count" 0 "$(spawn_count_of "$uh9_tid")"
check "upstream-head case 9: it spawns no seat" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
not_contains "upstream-head case 9: no spawn event" "$(cat "$work/once.out")" "pm spawn"
not_contains "upstream-head case 9: no flag event" "$(cat "$work/once.out")" "pm flag"

# ---- a thread's own budget re-arms after an upstream-head reset ----
UH_BUDGET=2 uh_kickoff ken; uh10_mid="$UH_MID"; unset UH_BUDGET
uh10_tid="$(thread_of "$uh10_mid")"
check "thread budget re-arm: the kickoff spent the thread's budget of 2" 2 "$(spawn_count_of "$uh10_tid")"
printf '%s\n' 'one more' > "$work/body.tmp"
"$MAIL" reply --from '@carol' --reply-to "$uh10_mid" --to '@ken' --body "$work/body.tmp" >/dev/null 2>&1
once
check "thread budget re-arm: at its budget the thread refuses a wake" \
    "thread budget 2 exhausted" "$(cat "$PM_STATE_DIR/needs-operator/$uh10_tid" 2>/dev/null)"
reply_msg '@ci-demo' "$uh10_mid" 'carry' --to '@ken' --upstream-head "$uh_branch:$uh_sha" >/dev/null
once
check "thread budget re-arm: the carry resets the count and ken wakes" 1 "$(spawn_count_of "$uh10_tid")"
"$MAIL" reply --from '@carol' --reply-to "$uh10_mid" --to '@ken' --body "$work/body.tmp" >/dev/null 2>&1
once
check "thread budget re-arm: the thread then spends its own budget again" 2 "$(spawn_count_of "$uh10_tid")"
"$MAIL" reply --from '@carol' --reply-to "$uh10_mid" --to '@ken' --body "$work/body.tmp" >/dev/null 2>&1
once
check "thread budget re-arm: and is exhausted at 2, not at the global" \
    "thread budget 2 exhausted" "$(cat "$PM_STATE_DIR/needs-operator/$uh10_tid" 2>/dev/null)"
uh10_json="$("$postmaster" status --thread "$uh10_tid" --json)"
check "status: budget is the thread's own" 2 "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["budget"])' "$uh10_json")"
check "status: budget_source is thread" thread "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["budget_source"])' "$uh10_json")"
check "status: spawns is reset by the carry" 2 "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["spawns"])' "$uh10_json")"
check "status: spawns_total is not" 4 "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["spawns_total"])' "$uh10_json")"

# ---- prior heads survive a deleted branch and a gc: the pin keeps them ----
ph_gc_branch="feature/gone-after-pin"
ph_gc_sha="$(uh_commit "$ph_gc_branch")"
uh_kickoff karen; ph_mid="$UH_MID"
ph_tid="$(thread_of "$ph_mid")"
ph_reply="$(reply_msg '@ci-demo' "$ph_mid" 'pushed a branch' --to '@karen' --upstream-head "$ph_gc_branch:$ph_gc_sha")"
once
check "prior heads: a non-sets seat gets the head ref" "head-$(head_id "$ph_reply")=$ph_gc_sha" "$(extra_refs)"
check "prior heads: the head was pinned" "$ph_gc_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$ph_tid/head-$(head_id "$ph_reply")" 2>/dev/null)"
git -C "$PROJECT_DIR" update-ref -d "refs/heads/$ph_gc_branch"
git -C "$PROJECT_DIR" reflog expire --expire=now --all
git -C "$PROJECT_DIR" gc --prune=now -q 2>/dev/null
check "prior heads: the pinned commit survives the branch's deletion and a gc" 0 \
    "$(git -C "$PROJECT_DIR" cat-file -e "$ph_gc_sha^{commit}" 2>/dev/null; echo $?)"
: > "$STUB_ARGV_LOG"
reply_msg '@carol' "$ph_reply" 'next wake' --to '@karen' >/dev/null
once
check "prior heads: the next wake still carries the head ref" "head-$(head_id "$ph_reply")=$ph_gc_sha" "$(extra_refs)"
not_contains "prior heads: and nothing is reported missing" "$(cat "$work/once.out")" "review-history-missing"

# ---- a prior head the repo does not hold is skipped, never fatal ----
ph_gone="$(printf 'c%.0s' {1..40})"
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
printf '%s\n' 'old thread' > "$work/body.tmp"
ph2_mid="$("$MAIL" send --from '@carol' --to '@karen' --subject 'old thread topic' \
    --body "$work/body.tmp" --hops 8 --review-target "pm-old-branch:$ph_gone" 2>/dev/null)"
ph2_tid="$(thread_of "$ph2_mid")"; ph2_short="${ph2_tid:0:8}"
once
printf 'BRANCH=pm-old-branch\nSHA=%s\nVERSION=2\nSET_BY=@ken\nSET_AT=2026-01-01T00:00:00Z\n' "$rt1_sha" \
    > "$PM_STATE_DIR/review-target/$ph2_tid.env"
ph2_reply="$(reply_msg '@ci-demo' "$ph2_mid" 'pushed a lost branch' --to '@karen' --upstream-head "feature/lost:$ph_gone")"
: > "$STUB_ARGV_LOG"
once
check "prior heads: a missing sha does not stop the wake" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "prior heads: nothing is handed over for the missing shas" 0 "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"
contains "prior heads: the missing review version is reported" "$(cat "$work/once.out")" \
    "pm review-history-missing thread=$ph2_short ref=review-v1"
contains "prior heads: the missing head is reported" "$(cat "$work/once.out")" \
    "pm review-history-missing thread=$ph2_short ref=head-$(head_id "$ph2_reply")"
check "prior heads: the missing shas are not pinned" 0 \
    "$(git -C "$PROJECT_DIR" for-each-ref "refs/fork-sandbox/review/$ph2_tid" | grep -cv '/review-v2$' || true)"
check "prior heads: the current version is pinned from the state file" "$rt1_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$ph2_tid/review-v2" 2>/dev/null)"
check "prior heads: and the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$ph2_tid" ]] && echo 1 || echo 0 )"

# ---- an announced head only on origin is fetched and pinned at announcement,
# so a force-push before any seat wakes cannot lose it ----
new_root PH_ORIGIN_BARE
git init -q --bare "$PH_ORIGIN_BARE"
new_root PH_ORIGIN_SRC
git -C "$PH_ORIGIN_SRC" init -q
git -C "$PH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m 'first head'
ph3_branch="feature/force-pushed"
ph3_sha="$(git -C "$PH_ORIGIN_SRC" rev-parse HEAD)"
git -C "$PH_ORIGIN_SRC" push -q "$PH_ORIGIN_BARE" "HEAD:refs/heads/$ph3_branch"
git -C "$PROJECT_DIR" remote add origin "$PH_ORIGIN_BARE"
uh_kickoff karen; ph3_mid="$UH_MID"
ph3_tid="$(thread_of "$ph3_mid")"
check "prior heads origin-only: the sha is not local before the announcement" 1 \
    "$(git -C "$PROJECT_DIR" cat-file -e "$ph3_sha^{commit}" >/dev/null 2>&1 && echo 0 || echo 1)"
ph3_reply="$(reply_msg '@ci-demo' "$ph3_mid" 'carry' --to '@operator' --upstream-head "$ph3_branch:$ph3_sha")"
once
check "prior heads origin-only: a carry that wakes nobody still pinned the head" "$ph3_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$ph3_tid/head-$(head_id "$ph3_reply")" 2>/dev/null)"
git -C "$PH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test commit -q --amend --allow-empty -m 'rewritten'
git -C "$PH_ORIGIN_SRC" push -q -f "$PH_ORIGIN_BARE" "HEAD:refs/heads/$ph3_branch"
git -C "$PH_ORIGIN_BARE" reflog expire --expire=now --all
git -C "$PH_ORIGIN_BARE" gc --prune=now -q 2>/dev/null
reply_msg '@carol' "$ph3_reply" 'next wake' --to '@karen' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "prior heads origin-only: the force-pushed-away head is still handed over" \
    "head-$(head_id "$ph3_reply")=$ph3_sha" "$(extra_refs)"
not_contains "prior heads origin-only: and nothing is reported missing" "$(cat "$work/once.out")" "review-history-missing"
git -C "$PROJECT_DIR" remote remove origin

# ---- review-target harvest: a `sets` seat's (ken) Version: header, and a
# `follow` seat's (kai) spawn-time header stamping ----
# review-target: sets/follow are k8s-only fleet keys, so hand-writing
# outbox reply files against a k8s-stub-spawned run (as every case above
# does) is the natural way to drive pm_harvest_one_file's review-target
# branch -- the harvest logic itself runs identically for a local wake.

# ---- review-target case B1: ken's (sets) Version: 2 reply on a thread at
# VERSION=1 advances the target: X-Review-Target-Set/X-Review-Target/
# X-Version are stamped, and the state file is updated only after the post
# succeeds ----
# Version:'s new sha comes from resolving the WAKE's OWN branch in the
# project repo (the agent's real work landing there), not the review
# target's own branch -- same fixture technique as k8s case1b above.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

# A real commit: the sets seat's first wake spawns at the kickoff target.
rt5_seed_sha="$rt1_sha"
printf '%s\n' 'kick off review' > "$work/body.tmp"
rt5_mid="$("$MAIL" send --from '@carol' --to '@ken' --subject 'review target advance topic' \
    --body "$work/body.tmp" --hops 8 --review-target "pm-review-target-test-seed5:$rt5_seed_sha" 2>/dev/null)"
rt5_tid="$(thread_of "$rt5_mid")"
# A single `once` under this suite's FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
# both spawns AND harvests synchronously -- fork-sandbox-k8s-wake.sh's
# fs_k8s_wake_finish always writes its own wake_dir/summary.json as its last
# step (synthesizing one even when the raw stub wrote none), so this spawn
# is harvested immediately with the stub's own canned "hello from k8s stub"
# reply. The harvested marker and that run's summary.json/exit-code are
# cleared below -- the same technique adopt_case (above) uses to make a
# completed run look still-live -- before this case writes its real
# Version: content and re-harvests.
once

rt5_env="$(latest_env_for_agent ken)"
rt5_run_dir="$(env_val "$rt5_env" RUN_DIR)"
rt5_branch="$(env_val "$rt5_env" BRANCH)"
git -C "$PROJECT_DIR" branch "$rt5_branch" >/dev/null 2>&1
rt5_branch_sha="$(git -C "$PROJECT_DIR" rev-parse "$rt5_branch")"

rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt5_env" .env)" \
    "$rt5_run_dir/summary.json" "$rt5_run_dir/exit-code"
mkdir -p -- "$rt5_run_dir/outbox"
printf 'Version: 2\n\nBumping the review target to v2.\n' > "$rt5_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt5_run_dir/exit-code"
printf '{}\n' > "$rt5_run_dir/summary.json"
once

rt5_posted=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$rt5_tid"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'Bumping the review target to v2.' "$f" && rt5_posted="$f"
done
if [[ -n "$rt5_posted" ]]; then
    ok "review-target case B1: sets seat's advancing Version: reply was posted"
    check "review-target case B1: X-Review-Target-Set names the wake's own branch/sha" \
        "$rt5_branch $rt5_branch_sha" "$(header_of_file "$rt5_posted" X-Review-Target-Set)"
    check "review-target case B1: X-Review-Target carries the same value as X-Review-Target-Set" \
        "$rt5_branch $rt5_branch_sha" "$(header_of_file "$rt5_posted" X-Review-Target)"
    check "review-target case B1: X-Version is the new version" "2" \
        "$(header_of_file "$rt5_posted" X-Version)"
else
    no "review-target case B1: sets seat's advancing Version: reply was posted"
fi
rt5_state="$(cat "$PM_STATE_DIR/review-target/$rt5_tid.env" 2>/dev/null)"
contains "review-target case B1: state file VERSION advanced to 2" "$rt5_state" "VERSION=2"
contains "review-target case B1: state file BRANCH updated to the wake's branch" "$rt5_state" "BRANCH=$rt5_branch"
contains "review-target case B1: state file SHA updated to the wake's resolved sha" "$rt5_state" "SHA=$rt5_branch_sha"
check "review-target case B1: the harvested version is pinned before any later wake" "$rt5_branch_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$rt5_tid/review-v2" 2>/dev/null)"

# ---- prior heads: B1's thread is at VERSION 2, so every k8s seat gets the
# VERSION 1 target as review-v1 and no review-v2 ----
for ph_seat in kai ken; do
    : > "$STUB_ARGV_LOG"
    reply_msg '@carol' "$rt5_mid" "plain message for $ph_seat" --to "@$ph_seat" >/dev/null
    once
    check "prior heads: $ph_seat was woken" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
    contains "prior heads: $ph_seat gets review-v1 at the first target's sha" \
        "$(extra_refs)" "review-v1=$rt5_seed_sha"
    not_contains "prior heads: $ph_seat gets no review-v2" "$(extra_refs)" "review-v2"
done
check "prior heads: review-v1 is pinned in the project repo" "$rt5_seed_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$rt5_tid/review-v1" 2>/dev/null)"
check "prior heads: the current target is pinned too, but not handed out" "$rt5_branch_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$rt5_tid/review-v2" 2>/dev/null)"
check "prior heads: without an announcement no seat gets an upstream ref" 0 \
    "$(extra_refs | grep -c '^upstream=' || true)"

# A later announcement appears after the VERSION 1 target in the archive;
# review-version refs precede head refs regardless of archive interleaving.
: > "$STUB_ARGV_LOG"
rt5_announcement="$(reply_msg '@ci-demo' "$rt5_mid" 'new upstream head' \
    --to '@kai' --upstream-head "$rt5_branch:$rt5_branch_sha")"
once
check "prior heads: review versions precede announced heads" \
    "review-v1=$rt5_seed_sha head-$(head_id "$rt5_announcement")=$rt5_branch_sha" \
    "$(extra_refs | paste -sd' ')"

# ---- review-target case B1b: a Version: reply whose branch tip is NOT a
# descendant of the old target is accepted and recorded -- the human
# rebased or squashed, and the persona resets its wake branch to `upstream`
# ----
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

printf '%s\n' 'kick off review' > "$work/body.tmp"
rtn_mid="$("$MAIL" send --from '@carol' --to '@ken' --subject 'review target rebase topic' \
    --body "$work/body.tmp" --hops 8 --review-target "pm-review-target-test-seedn:$rt1_sha" 2>/dev/null)"
rtn_tid="$(thread_of "$rtn_mid")"
once
rtn_env="$(latest_env_for_agent ken)"
rtn_run_dir="$(env_val "$rtn_env" RUN_DIR)"
rtn_branch="$(env_val "$rtn_env" BRANCH)"
# A sibling of the old target (same parent, different commit): neither is
# an ancestor of the other, as after a rebase or squash.
rtn_new_sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree "$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')" \
    -p "$(git -C "$PROJECT_DIR" rev-parse HEAD)" -m 'rebased sibling of the target')"
git -C "$PROJECT_DIR" update-ref "refs/heads/$rtn_branch" "$rtn_new_sha"
check "review-target case B1b setup: the new tip is not a descendant of the old target" 1 \
    "$(git -C "$PROJECT_DIR" merge-base --is-ancestor "$rt1_sha" "$rtn_new_sha" && echo 0 || echo 1)"
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rtn_env" .env)" \
    "$rtn_run_dir/summary.json" "$rtn_run_dir/exit-code"
mkdir -p -- "$rtn_run_dir/outbox"
rm -f -- "$rtn_run_dir/outbox"/*
printf 'Version: 2\n\nPosting the human push as v2.\n' > "$rtn_run_dir/outbox/mail-1.md"
printf '0\n' > "$rtn_run_dir/exit-code"
printf '{}\n' > "$rtn_run_dir/summary.json"
once
rtn_posted=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$rtn_tid"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'Posting the human push as v2.' "$f" && rtn_posted="$f"
done
check "review-target case B1b: the non-descendant Version: reply was posted" 1 \
    "$( [[ -n "$rtn_posted" ]] && echo 1 || echo 0 )"
check "review-target case B1b: X-Review-Target-Set carries the non-descendant sha" \
    "$rtn_branch $rtn_new_sha" "$( [[ -n "$rtn_posted" ]] && header_of_file "$rtn_posted" X-Review-Target-Set )"
rtn_state="$(cat "$PM_STATE_DIR/review-target/$rtn_tid.env" 2>/dev/null)"
contains "review-target case B1b: state file records VERSION=2" "$rtn_state" "VERSION=2"
contains "review-target case B1b: state file records the non-descendant sha" "$rtn_state" "SHA=$rtn_new_sha"
check "review-target case B1b: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$rtn_tid" ]] && echo 1 || echo 0 )"

# ---- review-target case Bunch: a Version: reply whose wake branch never came
# back (the human pushed the target's own tip unchanged, the seat's reset
# was a no-op, its empty branch was deleted) ----
# rtu_run <announce-sha|""> <label>: opens a thread targeting the rt1
# commit, optionally announces <announce-sha> as the upstream head from a
# non-fleet sender, lets ken wake, then harvests a `Version: 2` reply while
# the wake branch does NOT exist in the project repo. Leaves RTU_TID,
# RTU_POSTED (the posted message file, or "") for the caller.
rtu_run() {
    local announce_sha="$1" label="$2" mid env run_dir branch f
    uh_kickoff ken; mid="$UH_MID"
    RTU_TID="$(thread_of "$mid")"
    if [[ -n "$announce_sha" ]]; then
        reply_msg '@ci-demo' "$mid" 'pushed' --to '@ken' --upstream-head "$rt1_branch:$announce_sha" >/dev/null
    else
        reply_msg '@carol' "$mid" 'nothing pushed' --to '@ken' >/dev/null
    fi
    once
    env="$(latest_env_for_agent ken)"
    run_dir="$(env_val "$env" RUN_DIR)"
    branch="$(env_val "$env" BRANCH)"
    git -C "$PROJECT_DIR" update-ref -d "refs/heads/$branch" 2>/dev/null || true
    check "$label setup: the wake branch does not exist" 0 \
        "$(git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && echo 1 || echo 0)"
    rm -f -- "$PM_STATE_DIR/harvested/$(basename "$env" .env)" \
        "$run_dir/summary.json" "$run_dir/exit-code"
    mkdir -p -- "$run_dir/outbox"
    rm -f -- "$run_dir/outbox"/*
    printf 'To: @carol\nVersion: 2\n\nThe push is unchanged, posting it as v2.\n' > "$run_dir/outbox/mail-1.md"
    printf '0\n' > "$run_dir/exit-code"
    printf '{}\n' > "$run_dir/summary.json"
    once
    RTU_POSTED=""
    for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$RTU_TID"/*.msg; do
        [[ -e "$f" ]] || continue
        grep -qF 'posting it as v2.' "$f" && RTU_POSTED="$f"
    done
    return 0
}

# Accepted: the upstream-head file records exactly the current target's sha.
rtu_run "$rt1_sha" "review-target case Bunch"
check "review-target case Bunch: the Version: reply was posted" 1 \
    "$( [[ -n "$RTU_POSTED" ]] && echo 1 || echo 0 )"
check "review-target case Bunch: X-Review-Target-Set carries the CURRENT target" \
    "$rt1_branch $rt1_sha" "$( [[ -n "$RTU_POSTED" ]] && header_of_file "$RTU_POSTED" X-Review-Target-Set )"
check "review-target case Bunch: X-Review-Target carries the CURRENT target" \
    "$rt1_branch $rt1_sha" "$( [[ -n "$RTU_POSTED" ]] && header_of_file "$RTU_POSTED" X-Review-Target )"
check "review-target case Bunch: X-Version is the new version" 2 \
    "$( [[ -n "$RTU_POSTED" ]] && header_of_file "$RTU_POSTED" X-Version )"
rtu_state="$(cat "$PM_STATE_DIR/review-target/$RTU_TID.env" 2>/dev/null)"
contains "review-target case Bunch: state file VERSION moves to 2" "$rtu_state" "VERSION=2"
contains "review-target case Bunch: state file keeps the same sha" "$rtu_state" "SHA=$rt1_sha"
contains "review-target case Bunch: state file keeps the same branch" "$rtu_state" "BRANCH=$rt1_branch"
# (The stub seat's own answer to the non-fleet announcer routes as an
# unresolvable To: and flags the thread; that is unrelated to the Version:
# reply, so only a review-target flag counts here.)
not_contains "review-target case Bunch: not flagged 'did not come back'" \
    "$(cat "$PM_STATE_DIR/needs-operator/$RTU_TID" 2>/dev/null)" "did not come back"

# Still flagged: no upstream-head file at all.
rtu_run "" "review-target case Bunchb"
check "review-target case Bunchb: no Version: reply is posted" 0 "$( [[ -n "$RTU_POSTED" ]] && echo 1 || echo 0 )"
contains "review-target case Bunchb: flagged 'did not come back'" \
    "$(cat "$PM_STATE_DIR/needs-operator/$RTU_TID" 2>/dev/null)" "did not come back"
contains "review-target case Bunchb: the target is not moved" \
    "$(cat "$PM_STATE_DIR/review-target/$RTU_TID.env" 2>/dev/null)" "VERSION=1"

# Still flagged: the announced head is a different commit than the target.
rtu_run "$uh_sha" "review-target case Bunchc"
check "review-target case Bunchc: no Version: reply is posted" 0 "$( [[ -n "$RTU_POSTED" ]] && echo 1 || echo 0 )"
contains "review-target case Bunchc: flagged 'did not come back'" \
    "$(cat "$PM_STATE_DIR/needs-operator/$RTU_TID" 2>/dev/null)" "did not come back"
contains "review-target case Bunchc: the target is not moved" \
    "$(cat "$PM_STATE_DIR/review-target/$RTU_TID.env" 2>/dev/null)" "SHA=$rt1_sha"

# ---- on-harvest: a sets seat's two-reply harvest, the second carrying Version: 2 ----
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
hk_install on-harvest on-target
once
printf '%s\n' 'kick off review' > "$work/body.tmp"
hkh_mid="$("$MAIL" send --from '@carol' --to '@ken' --subject 'hook harvest topic' \
    --body "$work/body.tmp" --hops 8 --review-target "pm-review-target-test-seed5:$rt5_seed_sha" 2>/dev/null)"
hkh_tid="$(thread_of "$hkh_mid")"
once
check "on-harvest: the first harvest (the stub's one reply) fires once" 1 "$(hk_count on-harvest)"
check "on-harvest: FS_TARGET_VERSION is 1 before the target moves" 1 "$(hk_env on-harvest FS_TARGET_VERSION)"
check "on-target: the kickoff (version 1) fired it once" 1 "$(hk_count on-target)"
check "on-target: the kickoff's version is 1" 1 "$(hk_env on-target FS_TARGET_VERSION)"
check "on-target: the kickoff's branch" "pm-review-target-test-seed5" "$(hk_env on-target FS_TARGET_BRANCH)"
check "on-target: the kickoff's sha" "$rt5_seed_sha" "$(hk_env on-target FS_TARGET_SHA)"
check "on-target: the sha is in the repo" 1 "$(hk_env on-target FS_TARGET_SHA_PRESENT)"
check "on-target: the event names the thread" "$hkh_tid" "$(hk_env on-target FS_HOOK_THREAD)"
hkh_env="$(latest_env_for_agent ken)"
hkh_run_dir="$(env_val "$hkh_env" RUN_DIR)"
hkh_branch="$(env_val "$hkh_env" BRANCH)"
git -C "$PROJECT_DIR" branch "$hkh_branch" >/dev/null 2>&1
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$hkh_env" .env)" "$hkh_run_dir/summary.json" "$hkh_run_dir/exit-code"
mkdir -p -- "$hkh_run_dir/outbox"
rm -f -- "$hkh_run_dir/outbox"/*
printf 'Version: 2\n\nHook harvest first reply.\n' > "$hkh_run_dir/outbox/mail-1.md"
printf '\nHook harvest second reply.\n' > "$hkh_run_dir/outbox/mail-2.md"
printf '0\n' > "$hkh_run_dir/exit-code"
printf '{}\n' > "$hkh_run_dir/summary.json"
once
check "on-harvest: a harvest posting two replies fires once more, not twice" 2 "$(hk_count on-harvest)"
hkh_ids=()
for hkh_body in 'Hook harvest first reply.' 'Hook harvest second reply.'; do
    for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$hkh_tid"/*.msg; do
        grep -qF "$hkh_body" "$f" && hkh_ids+=("$(header_of_file "$f" Message-ID)")
    done
done
check "on-harvest: FS_HOOK_MESSAGES is both ids, in posting order" "${hkh_ids[*]}" "$(hk_env on-harvest FS_HOOK_MESSAGES)"
check "on-harvest: FS_HOOK_RUN is the run id" "$(basename "$hkh_env" .env)" "$(hk_env on-harvest FS_HOOK_RUN)"
check "on-harvest: FS_HOOK_BRANCH is the wake's branch" "$hkh_branch" "$(hk_env on-harvest FS_HOOK_BRANCH)"
check "on-harvest: FS_HOOK_AGENT is the resolved seat" "ken" "$(hk_env on-harvest FS_HOOK_AGENT)"
check "on-harvest: the hook sees the moved target (FS_TARGET_VERSION=2)" 2 "$(hk_env on-harvest FS_TARGET_VERSION)"
check "on-target: a sets seat's Version: 2 fires it again" 2 "$(hk_count on-target)"
check "on-target: the moved target is version 2" 2 "$(hk_env on-target FS_TARGET_VERSION)"
check "on-target: the moved target's setter" "@ken" "$(hk_env on-target FS_TARGET_SET_BY)"
check "on-harvest: FS_TARGET_BRANCH is the moved branch" "$hkh_branch" "$(hk_env on-harvest FS_TARGET_BRANCH)"
check "on-harvest: FS_TARGET_SET_BY names the setter" "@ken" "$(hk_env on-harvest FS_TARGET_SET_BY)"
check "on-harvest: FS_TARGET_REPO is the deliver --project path" "$PROJECT_DIR" "$(hk_env on-harvest FS_TARGET_REPO)"
check "on-harvest: FS_HOOK_MAIL_ROOT is the mail root" "$FORK_SANDBOX_MAIL_ROOT" "$(hk_env on-harvest FS_HOOK_MAIL_ROOT)"

# A harvest that posts nothing fires nothing.
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$hkh_env" .env)" "$hkh_run_dir/summary.json" "$hkh_run_dir/exit-code"
rm -f -- "$hkh_run_dir/outbox"/*
printf '0\n' > "$hkh_run_dir/exit-code"
printf '{}\n' > "$hkh_run_dir/summary.json"
once
check "on-harvest: a harvest that posted nothing fires nothing" 2 "$(hk_count on-harvest)"
check "on-target: a harvest that moved nothing does not fire it again" 2 "$(hk_count on-target)"
hk_uninstall

# ---- review-target case B2: Version: 1 on a thread already at VERSION=1
# does not advance -- flagged, not posted, state unchanged ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt6_seed_sha="$rt1_sha"
printf '%s\n' 'kick off review' > "$work/body.tmp"
rt6_mid="$("$MAIL" send --from '@carol' --to '@ken' --subject 'review target non-advance topic' \
    --body "$work/body.tmp" --hops 8 --review-target "pm-review-target-test-seed6:$rt6_seed_sha" 2>/dev/null)"
rt6_tid="$(thread_of "$rt6_mid")"
rt6_short="${rt6_tid:0:8}"
# See case B1's comment: the initial spawn is harvested inline with the
# stub's own canned reply; clear it before writing Version: 1 below.
once

rt6_env="$(latest_env_for_agent ken)"
rt6_run_dir="$(env_val "$rt6_env" RUN_DIR)"
rt6_branch="$(env_val "$rt6_env" BRANCH)"
git -C "$PROJECT_DIR" branch "$rt6_branch" >/dev/null 2>&1

rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt6_env" .env)" \
    "$rt6_run_dir/summary.json" "$rt6_run_dir/exit-code"
mkdir -p -- "$rt6_run_dir/outbox"
printf 'Version: 1\n\nThis should not advance anything.\n' > "$rt6_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt6_run_dir/exit-code"
printf '{}\n' > "$rt6_run_dir/summary.json"
once

rt6_flag="$(cat "$PM_STATE_DIR/needs-operator/$rt6_tid" 2>/dev/null)"
contains "review-target case B2: a non-advancing Version: is flagged ('does not advance')" \
    "$rt6_flag" "does not advance"
contains "review-target case B2: flag event uses the review-target keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$rt6_short reason=review-target"
rt6_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$rt6_tid"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'This should not advance anything.' "$f" && rt6_posted=1
done
check "review-target case B2: the non-advancing reply was never posted" 0 "$rt6_posted"
rt6_state="$(cat "$PM_STATE_DIR/review-target/$rt6_tid.env" 2>/dev/null)"
contains "review-target case B2: state file VERSION is unchanged" "$rt6_state" "VERSION=1"
contains "review-target case B2: state file SHA is unchanged" "$rt6_state" "SHA=$rt6_seed_sha"

# ---- review-target case B3: a Version: header from a seat that is NOT
# review-target: sets (karen, a plain backend: k8s seat) is flagged on the
# existing malformed-reply path, not the review-target one ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt7_mid="$(send_msg '@carol' '@karen' 'not a sets seat topic' 'hello karen' 8)"
rt7_tid="$(thread_of "$rt7_mid")"
rt7_short="${rt7_tid:0:8}"
# See case B1's comment: the initial spawn is harvested inline with the
# stub's own canned reply; clear it before writing Version: 3 below.
once
rt7_env="$(latest_env_for_agent karen)"
rt7_run_dir="$(env_val "$rt7_env" RUN_DIR)"
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt7_env" .env)" \
    "$rt7_run_dir/summary.json" "$rt7_run_dir/exit-code"
mkdir -p -- "$rt7_run_dir/outbox"
printf 'Version: 3\n\nI am not the sets seat.\n' > "$rt7_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt7_run_dir/exit-code"
printf '{}\n' > "$rt7_run_dir/summary.json"
once
rt7_flag="$(cat "$PM_STATE_DIR/needs-operator/$rt7_tid" 2>/dev/null)"
contains "review-target case B3: Version: from a non-sets seat is flagged malformed" \
    "$rt7_flag" "Version: header from a seat without review-target: sets"
contains "review-target case B3: flag event stays on the existing malformed-reply keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$rt7_short reason=malformed-reply"
check "review-target case B3: no state file was created" 0 \
    "$( [[ -e "$PM_STATE_DIR/review-target/$rt7_tid.env" ]] && echo 1 || echo 0 )"

# ---- review-target case B4: a `follow` seat's (kai) harvested reply
# stamps the target it was SPAWNED at, even after the state file moves
# between his spawn and his own harvest -- the trickiest invariant (a
# stale spawn-time value, never a fresh read of current state) ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt8_branch="pm-review-target-test-8"
rt8_tree="$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')"
rt8_parent="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
rt8_sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree "$rt8_tree" -p "$rt8_parent" -m 'review target commit 8')"
git -C "$PROJECT_DIR" update-ref "refs/heads/$rt8_branch" "$rt8_sha"

printf '%s\n' 'kick off review, both reviewers' > "$work/body.tmp"
rt8_mid="$("$MAIL" send --from '@carol' --to '@kai,@ken' --subject 'review target stale spawn topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt8_branch:$rt8_sha" 2>/dev/null)"
rt8_tid="$(thread_of "$rt8_mid")"
# See case B1's comment: the initial spawn harvests BOTH kai's and ken's
# runs inline with the stub's own canned reply. Both are cleared below (kai's
# left cleared, i.e. pending, until after the move; ken's immediately
# rewritten) so this case can move the target via ken's harvest first, then
# harvest kai's separately, further down.
once

rt8_kai_env="$(latest_env_for_agent kai)"
rt8_kai_run_dir="$(env_val "$rt8_kai_env" RUN_DIR)"
check "review-target case B4 setup: kai spawned at the review target sha" \
    "$rt8_sha" "$(env_val "$rt8_kai_env" REVIEW_TARGET_SHA)"

rt8_ken_env="$(latest_env_for_agent ken)"
rt8_ken_run_dir="$(env_val "$rt8_ken_env" RUN_DIR)"
rt8_ken_branch="$(env_val "$rt8_ken_env" BRANCH)"
git -C "$PROJECT_DIR" branch "$rt8_ken_branch" >/dev/null 2>&1

# Move the target out from under kai BEFORE his own reply is ever harvested:
# ken's Version: 2 harvest goes first, in its own pass, while kai's run is
# left live (summary.json/exit-code cleared, same as case B1) so this pass
# cannot harvest kai too.
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt8_kai_env" .env)" \
    "$rt8_kai_run_dir/summary.json" "$rt8_kai_run_dir/exit-code"
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt8_ken_env" .env)" \
    "$rt8_ken_run_dir/summary.json" "$rt8_ken_run_dir/exit-code"
mkdir -p -- "$rt8_ken_run_dir/outbox"
printf 'Version: 2\n\nMoving the target.\n' > "$rt8_ken_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt8_ken_run_dir/exit-code"
printf '{}\n' > "$rt8_ken_run_dir/summary.json"
once
rt8_state_after_move="$(cat "$PM_STATE_DIR/review-target/$rt8_tid.env" 2>/dev/null)"
contains "review-target case B4 setup: the state file actually moved to VERSION=2" \
    "$rt8_state_after_move" "VERSION=2"

mkdir -p -- "$rt8_kai_run_dir/outbox"
printf '\nAcknowledged, reviewing the target I was spawned at.\n' > "$rt8_kai_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt8_kai_run_dir/exit-code"
printf '{}\n' > "$rt8_kai_run_dir/summary.json"
once

rt8_kai_posted=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$rt8_tid"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'Acknowledged, reviewing the target I was spawned at.' "$f" && rt8_kai_posted="$f"
done
if [[ -n "$rt8_kai_posted" ]]; then
    ok "review-target case B4: kai's reply was posted"
    check "review-target case B4: X-Review-Target stamps the target kai was SPAWNED at, not the now-current one" \
        "$rt8_branch $rt8_sha" "$(header_of_file "$rt8_kai_posted" X-Review-Target)"
    check "review-target case B4: X-Version is kai's spawn-time version, not the state file's current one" \
        "1" "$(header_of_file "$rt8_kai_posted" X-Version)"
else
    no "review-target case B4: kai's reply was posted"
fi

# ---- review-target case B5: a Version: reply whose wake's own branch never
# landed in the project repo (never created here, mirroring k8s case1c's
# "deleted" branch fixture above) is flagged, not treated as advancing or
# non-advancing ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt9_mid="$(send_msg '@carol' '@ken' 'branch never came back topic' 'hello ken' 8)"
rt9_tid="$(thread_of "$rt9_mid")"
# See case B1's comment: the initial spawn is harvested inline with the
# stub's own canned reply; clear it before writing Version: 1 below.
once
rt9_env="$(latest_env_for_agent ken)"
rt9_run_dir="$(env_val "$rt9_env" RUN_DIR)"
rm -f -- "$PM_STATE_DIR/harvested/$(basename "$rt9_env" .env)" \
    "$rt9_run_dir/summary.json" "$rt9_run_dir/exit-code"
mkdir -p -- "$rt9_run_dir/outbox"
printf 'Version: 1\n\nThe branch never landed.\n' > "$rt9_run_dir/outbox/mail-1.md"
printf '0\n' > "$rt9_run_dir/exit-code"
printf '{}\n' > "$rt9_run_dir/summary.json"
once
rt9_flag="$(cat "$PM_STATE_DIR/needs-operator/$rt9_tid" 2>/dev/null)"
contains "review-target case B5: a Version: reply whose wake branch never landed is flagged ('did not come back')" \
    "$rt9_flag" "did not come back"
check "review-target case B5: no state file was written" 0 \
    "$( [[ -e "$PM_STATE_DIR/review-target/$rt9_tid.env" ]] && echo 1 || echo 0 )"

finish_suite
