#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/17-local-review-target.sh — fork-sandbox-postmaster.sh: a
# local `review-target: follow` seat moves its persistent clone to the
# thread's review target when the target is new to it, and only then.
#
# Usage: tests/postmaster/17-local-review-target.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== review target: local seats ==\n'
# ============================================================

sed -i 's/^  alice: {}$/  alice:\n    review-target: follow/' "$FORK_SANDBOX_FLEET_FILE"
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
head_sha="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

# The newest run record on the thread, by spawn order rather than mtime.
last_env() { printf '%s' "$PM_STATE_DIR/runs/$(tail -n1 "$PM_STATE_DIR/seq/$1").env"; }
# Ends alice's live run, harvests it, and wakes her again on the thread.
next_wake() {
    finish_run alice 0
    once
    reply_msg '@carol' "$lr_mid" "$1" --to '@alice' >/dev/null
    : > "$STUB_ARGV_LOG"
    once
}

k8s_rt1_seed
printf '%s\n' 'kick off review' > "$work/body.tmp"
lr_mid="$("$MAIL" send --from '@carol' --to '@alice' --subject 'local review target' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
lr_tid="$(thread_of "$lr_mid")"
lr_ws="$PM_STATE_DIR/workspaces/$lr_tid/alice"
: > "$STUB_ARGV_LOG"
once
check "local follow: the first wake checks out the target" \
    "$rt1_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"
check "local follow: the trust ref is the project's HEAD, not the target" \
    "$head_sha" "$(argv_after --services-trust-ref "$STUB_ARGV_LOG")"
check "local follow: the clone is still the seat's persistent one" \
    "$lr_ws" "$(argv_after --clone-dir "$STUB_ARGV_LOG")"
check "local follow: .env records the target sha" \
    "$rt1_sha" "$(env_val "$(last_env "$lr_tid")" REVIEW_TARGET_SHA)"

# What the first wake's fork-sandbox.sh would have left behind.
mkdir -p -- "$lr_ws/.git"
next_wake 'same target'
check "local follow: the seat woke again" 1 "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"
check "local follow: an unchanged target keeps the clone's own lineage" 0 \
    "$(grep -c -- '^--checkout$' "$STUB_ARGV_LOG")"
check "local follow: and passes no trust ref" 0 \
    "$(grep -c -- '^--services-trust-ref$' "$STUB_ARGV_LOG")"
check "local follow: .env still records the target sha" \
    "$rt1_sha" "$(env_val "$(last_env "$lr_tid")" REVIEW_TARGET_SHA)"

rt2_sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree "$rt1_tree" -p "$rt1_sha" -m 'review target commit 2')"
git -C "$PROJECT_DIR" update-ref "refs/heads/$rt1_branch" "$rt2_sha"
printf 'BRANCH=%s\nSHA=%s\nVERSION=2\nSET_BY=@carol\nSET_AT=2026-01-01T00:00:00Z\n' \
    "$rt1_branch" "$rt2_sha" > "$PM_STATE_DIR/review-target/$lr_tid.env"
next_wake 'version 2'
check "local follow: a moved target checks out the new sha" \
    "$rt2_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"

rm -rf -- "$lr_ws"
next_wake 'workspace gone'
check "local follow: a missing workspace checks out the target again" \
    "$rt2_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"

mkdir -p -- "$lr_ws/.git"
sed -i 's/^  alice:$/  alice:\n    services: false/' "$FORK_SANDBOX_FLEET_FILE"
rt3_sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree "$rt1_tree" -p "$rt2_sha" -m 'review target commit 3')"
git -C "$PROJECT_DIR" update-ref "refs/heads/$rt1_branch" "$rt3_sha"
printf 'BRANCH=%s\nSHA=%s\nVERSION=3\nSET_BY=@carol\nSET_AT=2026-01-01T00:00:00Z\n' \
    "$rt1_branch" "$rt3_sha" > "$PM_STATE_DIR/review-target/$lr_tid.env"
next_wake 'no services'
check "local follow: services false still checks out a moved target" \
    "$rt3_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"
check "local follow: services false passes no trust ref" 0 \
    "$(grep -c -- '^--services-trust-ref$' "$STUB_ARGV_LOG")"

finish_suite
