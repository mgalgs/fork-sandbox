#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/09-k8s-review.sh — fork-sandbox-postmaster.sh: backend: k8s
# seats -- argv, lineage, review targets, upstream heads.
#
# Usage: tests/postmaster/09-k8s-review.sh  (or all files at once:
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

# ---- case 1: a plain backend: k8s seat -- argv shape, harvest, .env ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

: > "$STUB_ARGV_LOG"
k1_mid="$(send_msg '@carol' '@karen' 'k8s topic' 'hello karen' 8)"
k1_tid="$(thread_of "$k1_mid")"
once
 k1_env="$(latest_env_for_agent karen)"
 k1_wake_dir="$(env_val "$k1_env" RUN_DIR)"
check "k8s case1: thread context in wake env" 1 \
    "$(tr '\0' '\n' < "$k1_wake_dir/env" | grep -c "^FS_BALANCE_THREAD=$k1_tid$")"
check "k8s case1: seat address in wake env" 1 \
    "$(tr '\0' '\n' < "$k1_wake_dir/env" | grep -c '^FS_BALANCE_AGENT=karen$')"
k1_headers="$(tr '\0' '\n' < "$k1_wake_dir/env" | sed -n 's/^FS_BALANCE_ROOT_HEADERS_FILE=//p')"
contains "k8s case1: root headers file is readable" "$(cat "$k1_headers")" "Subject: k8s topic"
check "k8s case1: --k8s is in argv" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case1: --outbox-dir is in argv" 1 "$(grep -c -- '^--outbox-dir$' "$STUB_ARGV_LOG")"
check "k8s case1: --thread-dir is in argv" 1 "$(grep -c -- '^--thread-dir$' "$STUB_ARGV_LOG")"
check "k8s case1: --timeout defaults to 14400" 14400 "$(argv_after --timeout "$STUB_ARGV_LOG")"
check "k8s case1: --clone-dir is absent (fork-sandbox.sh --k8s refuses it)" 0 \
    "$(grep -c -- '^--clone-dir$' "$STUB_ARGV_LOG")"
check "k8s case1: --refresh-at is absent for a seat that configures none" 0 \
    "$(grep -c -- '^--refresh-at$' "$STUB_ARGV_LOG")"
check "k8s case1: --session-state forwarded (k8s seats keep their session)" \
    "$PM_STATE_DIR/state/$k1_tid/karen" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "k8s case1: no --resume-session on a first wake (nothing to resume)" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "k8s case1: no --session-id (claude is discover-mode)" 0 \
    "$(grep -c -- '^--session-id$' "$STUB_ARGV_LOG")"
check "k8s case1: no --checkout on a first wake (no prior run to resolve)" 0 \
    "$(grep -c -- '^--checkout$' "$STUB_ARGV_LOG")"
check "k8s case1: no --services-trust-ref on a first wake (no lineage checkout to anchor)" 0 \
    "$(grep -c -- '^--services-trust-ref$' "$STUB_ARGV_LOG")"
check "k8s case1: a thread with no review target or head gets no --extra-ref" 0 \
    "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"
not_contains "k8s case1: and no review-history event" "$(cat "$work/once.out")" "review-history"
k1_env="$(latest_env_for_agent karen)"
check "k8s case1: .env BACKEND=k8s" k8s "$(env_val "$k1_env" BACKEND)"
check "k8s case1: .env RESUMED is empty" "" "$(env_val "$k1_env" RESUMED)"
k1_rendered="$("$MAIL_RENDER" --text --thread "$k1_tid" "$FORK_SANDBOX_MAIL_ROOT" 2>/dev/null)"
contains "k8s case1: the stub's k8s reply was harvested" "$k1_rendered" "hello from k8s stub"

# ---- case 1b: a second wake resumes the session and gets a --checkout ----
# Fixtures stand in for what a real harvest would have recorded after
# case1: a session id under sessions/ (pm_session_record's own format --
# see its header) and a branch that actually resolves in PROJECT_DIR
# (case1's own BRANCH, which the stub fork-sandbox.sh never really
# creates). A second wake for the same (thread, agent) must read the
# session id back as --resume-session, and pm_lineage_checkout must
# resolve karen's own prior BRANCH -- a real git rev-parse, not just a
# file read.
k1_branch="$(env_val "$k1_env" BRANCH)"
git -C "$PROJECT_DIR" branch "$k1_branch" >/dev/null 2>&1
k1_fixture_sid=aaaa1111-2222-3333-4444-555566667777
mkdir -p -- "$PM_STATE_DIR/sessions/$k1_tid"
printf '%s\n' "$k1_fixture_sid" > "$PM_STATE_DIR/sessions/$k1_tid/karen"
reply_msg '@carol' "$k1_mid" 'second' --to '@karen' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "k8s case1b: --resume-session forwarded from the recorded session" \
    "$k1_fixture_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "k8s case1b: --checkout forwarded (lineage from karen's own prior run)" \
    "$k1_branch" "$(argv_after --checkout "$STUB_ARGV_LOG")"
# A --checkout with no --services-trust-ref reads as untrusted to cmd_submit's
# own services-trust gate (fork-sandbox-k8s.sh), which would silently turn
# per-run services off for every wake past the first. pm_spawn_wake must
# anchor trust to the project's current HEAD alongside the lineage checkout.
check "k8s case1b: --services-trust-ref forwarded alongside the lineage checkout" \
    "$(git -C "$PROJECT_DIR" rev-parse HEAD)" "$(argv_after --services-trust-ref "$STUB_ARGV_LOG")"
# The wedge bound (pm_followup_wake's own accounting) counts a k8s wake
# via its .env RESUMED field, the same as a local wake's -- this run was
# launched with --resume-session above, so RESUMED must record that id,
# not be left empty the way case1's own FIRST wake (nothing to resume)
# correctly was.
k1b_env="$(latest_env_for_agent karen)"
check "k8s case1b: .env RESUMED records the resumed session id" \
    "$k1_fixture_sid" "$(env_val "$k1b_env" RESUMED)"

# Seat services override the postmaster's k8s.env default.
k_services_saved_fleet="$(cat "$FORK_SANDBOX_FLEET_FILE")"
sed -i '/^  karen:$/a\    services: false' "$FORK_SANDBOX_FLEET_FILE"
: > "$STUB_ARGV_LOG"
send_msg '@carol' '@karen' 'no services' 'review' 8
once
check "k8s services: per-seat false passes --no-services" 1 "$(grep -c '^--no-services$' "$STUB_ARGV_LOG")"
check "k8s services: per-seat false omits trust ref" 0 "$(grep -c '^--services-trust-ref$' "$STUB_ARGV_LOG")"
sed -i '/^  karen:$/,/^  karl:$/s/^    services: false$/    services: true/' "$FORK_SANDBOX_FLEET_FILE"
new_root K_SERVICES_CONFIG
printf 'K8S_POSTMASTER_SEAT_SERVICES=false\n' > "$K_SERVICES_CONFIG/k8s.env"
: > "$STUB_ARGV_LOG"
send_msg '@carol' '@karen' 'services override' 'review' 8
FORK_SANDBOX_CONFIG_DIR="$K_SERVICES_CONFIG" once
check "k8s services: per-seat true overrides env false" 0 "$(grep -c '^--no-services$' "$STUB_ARGV_LOG")"
printf '%s\n' "$k_services_saved_fleet" > "$FORK_SANDBOX_FLEET_FILE"
: > "$STUB_ARGV_LOG"
send_msg '@carol' '@karen' 'services env default' 'review' 8
FORK_SANDBOX_CONFIG_DIR="$K_SERVICES_CONFIG" once
check "k8s services: env false passes --no-services" 1 "$(grep -c '^--no-services$' "$STUB_ARGV_LOG")"

# ---- case 1c: lineage picks the newest RESOLVING branch, for the right
# agent, skipping a deleted one ----
# Hand-built RUNS/*.env + seq fixtures (marked harvested so the harvest
# pass and the live-run check both leave them alone) stand in for a
# longer history than a real sequence of wakes would be worth paying for
# here -- pm_lineage_checkout itself only ever reads AGENT/BRANCH off
# these files and walks $SEQ/$tid, so a hand-built history exercises it
# identically to a real one.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"

seed_lineage_run() {
    # $1=tid $2=rid $3=agent $4=branch $5=1 to actually create the branch
    # (a branch pm_lineage_checkout must find "deleted", i.e. never
    # resolve, is simply never created here).
    local tid="$1" rid="$2" agent="$3" branch="$4" real="${5:-0}"
    {
        printf 'AGENT=%s\n' "$agent"
        printf 'BRANCH=%s\n' "$branch"
    } > "$PM_STATE_DIR/runs/$rid.env"
    : > "$PM_STATE_DIR/harvested/$rid"
    (( real )) && git -C "$PROJECT_DIR" branch "$branch" >/dev/null 2>&1
    printf '%s\n' "$rid" >> "$PM_STATE_DIR/seq/$tid"
}

k1c_mid="$(send_msg '@carol' '@karen' 'lineage skip topic' 'hello karen' 8)"
k1c_tid="$(thread_of "$k1c_mid")"
# Oldest to newest: a resolving branch for karen (the expected answer),
# then a NEWER resolving branch for a different agent (dave -- must be
# skipped on agent alone), then a NEWER STILL branch for karen that was
# never created (must be skipped as unresolving). The walk is newest
# first, so this only lands on the right answer if both skips work.
seed_lineage_run "$k1c_tid" pm-lineage-skip-rid1 karen pm-lineage-test-fallback 1
seed_lineage_run "$k1c_tid" pm-lineage-skip-rid2 dave pm-lineage-test-dave 1
seed_lineage_run "$k1c_tid" pm-lineage-skip-rid3 karen pm-lineage-test-deleted 0
: > "$STUB_ARGV_LOG"
once
check "k8s case1c: --checkout skips another agent's and a deleted branch, falling back to the oldest resolving one" \
    "pm-lineage-test-fallback" "$(argv_after --checkout "$STUB_ARGV_LOG")"

# ---- case 1d: among two resolving branches for the SAME agent, lineage
# picks the newest, not the first found chronologically ----
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"

k1d_mid="$(send_msg '@carol' '@karen' 'lineage newest topic' 'hello karen' 8)"
k1d_tid="$(thread_of "$k1d_mid")"
seed_lineage_run "$k1d_tid" pm-lineage-newest-rid1 karen pm-lineage-test-older 1
seed_lineage_run "$k1d_tid" pm-lineage-newest-rid2 karen pm-lineage-test-newer 1
: > "$STUB_ARGV_LOG"
once
check "k8s case1d: --checkout picks the newest of two resolving branches for the same agent" \
    "pm-lineage-test-newer" "$(argv_after --checkout "$STUB_ARGV_LOG")"

# ---- case 1e: no resolving branch anywhere in the history -> no --checkout,
# start from HEAD as today ----
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"

k1e_mid="$(send_msg '@carol' '@karen' 'lineage none topic' 'hello karen' 8)"
k1e_tid="$(thread_of "$k1e_mid")"
seed_lineage_run "$k1e_tid" pm-lineage-none-rid1 karen pm-lineage-test-nonexistent 0
: > "$STUB_ARGV_LOG"
once
check "k8s case1e: no --checkout when nothing in the history resolves" \
    0 "$(grep -c -- '^--checkout$' "$STUB_ARGV_LOG")"

# ---- review-target case A1: a `follow` seat (kai) on a thread WITH a
# review target checks out the target's sha instead of doing lineage
# resolution, and --services-trust-ref still anchors to the project's own
# HEAD, never the target ----
# The target sha is a real commit in PROJECT_DIR (commit-tree + update-ref,
# so it lands without disturbing PROJECT_DIR's own current branch/HEAD,
# which other cases in this suite compare against) -- pm_spawn_wake does a
# real `git cat-file -e` against it.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k8s_rt1_seed

printf '%s\n' 'kick off review' > "$work/body.tmp"
rt1_mid="$("$MAIL" send --from '@carol' --to '@kai' --subject 'review target spawn topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
rt1_tid="$(thread_of "$rt1_mid")"
rt1_short="${rt1_tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "review-target case A1: follow seat spawns with --checkout at the target sha, not lineage" \
    "$rt1_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"
check "review-target case A1: --services-trust-ref is still the project's own HEAD, not the target" \
    "$(git -C "$PROJECT_DIR" rev-parse HEAD)" "$(argv_after --services-trust-ref "$STUB_ARGV_LOG")"
contains "review-target case A1: spawn event fires for kai" \
    "$(cat "$work/once.out")" "pm spawn thread=$rt1_short agent=kai"
rt1_env="$(latest_env_for_agent kai)"
check "review-target case A1: .env REVIEW_TARGET=follow" "follow" "$(env_val "$rt1_env" REVIEW_TARGET)"
check "review-target case A1: .env REVIEW_TARGET_BRANCH matches the state file" \
    "$rt1_branch" "$(env_val "$rt1_env" REVIEW_TARGET_BRANCH)"
check "review-target case A1: .env REVIEW_TARGET_SHA matches the state file" \
    "$rt1_sha" "$(env_val "$rt1_env" REVIEW_TARGET_SHA)"
check "review-target case A1: .env REVIEW_TARGET_VERSION matches the state file" \
    "1" "$(env_val "$rt1_env" REVIEW_TARGET_VERSION)"

# ---- review-target case A2: a `follow` seat on a thread with NO review
# target is unaffected -- ordinary lineage path, nothing forced ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

send_msg '@carol' '@kai' 'no review target topic' 'hello kai' 8 >/dev/null
: > "$STUB_ARGV_LOG"
once
check "review-target case A2: no --checkout when the thread has no review target" \
    0 "$(grep -c -- '^--checkout$' "$STUB_ARGV_LOG")"
rt2_env="$(latest_env_for_agent kai)"
check "review-target case A2: .env REVIEW_TARGET is still 'follow' (a seat property, stamped regardless)" \
    "follow" "$(env_val "$rt2_env" REVIEW_TARGET)"
check "review-target case A2: no REVIEW_TARGET_BRANCH written when there is no target" \
    0 "$(grep -c '^REVIEW_TARGET_BRANCH=' "$rt2_env")"
check "review-target case A2: no REVIEW_TARGET_SHA written when there is no target" \
    0 "$(grep -c '^REVIEW_TARGET_SHA=' "$rt2_env")"
check "review-target case A2: no REVIEW_TARGET_VERSION written when there is no target" \
    0 "$(grep -c '^REVIEW_TARGET_VERSION=' "$rt2_env")"

# ---- review-target case A5: the `sets` seat (ken) on a kickoff-opened
# thread spawns at the target until it has a lineage of its own, then
# keeps its lineage ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"

printf '%s\n' 'please revise' > "$work/body.tmp"
"$MAIL" send --from '@carol' --to '@ken' --subject 'review target author first wake' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "review-target case A5: sets seat with no lineage spawns with --checkout at the target sha" \
    "$rt1_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"

rt5b_mid="$("$MAIL" send --from '@carol' --to '@ken' --subject 'review target author later wake' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
rt5b_tid="$(thread_of "$rt5b_mid")"
seed_lineage_run "$rt5b_tid" pm-rt-author-rid1 ken pm-lineage-test-newer 1
: > "$STUB_ARGV_LOG"
once
check "review-target case A5: sets seat with a lineage keeps it, not the target" \
    "pm-lineage-test-newer" "$(argv_after --checkout "$STUB_ARGV_LOG")"

# ---- review-target case A3: a target sha absent from the project repo,
# with no `origin` remote configured, flags and refuses the wake instead of
# spawning ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt3_branch="pm-review-target-test-missing"
rt3_sha="$(printf 'a%.0s' {1..40})"
printf '%s\n' 'kick off review' > "$work/body.tmp"
rt3_mid="$("$MAIL" send --from '@carol' --to '@kai' --subject 'review target missing sha topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt3_branch:$rt3_sha" 2>/dev/null)"
rt3_tid="$(thread_of "$rt3_mid")"
rt3_short="${rt3_tid:0:8}"
: > "$STUB_ARGV_LOG"
once
rt3_flag="$(cat "$PM_STATE_DIR/needs-operator/$rt3_tid" 2>/dev/null)"
contains "review-target case A3: a missing target sha with no origin is flagged ('not found')" \
    "$rt3_flag" "not found"
contains "review-target case A3: flag event uses the review-target keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$rt3_short reason=review-target"
check "review-target case A3: no --checkout was ever forwarded" 0 \
    "$(grep -c -- '^--checkout$' "$STUB_ARGV_LOG")"
check "review-target case A3: no k8s launch at all -- the wake was refused before spawning" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "review-target case A3: no run record for kai was ever written" \
    "1" "$(latest_env_for_agent kai >/dev/null 2>&1; echo $?)"

# ---- review-target case A4: a target sha absent locally but present on an
# `origin` remote is fetched on demand, and the spawn then proceeds ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

new_root RT_ORIGIN_BARE
git init -q --bare "$RT_ORIGIN_BARE"
new_root RT_ORIGIN_SRC
git -C "$RT_ORIGIN_SRC" init -q
git -C "$RT_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m 'origin target commit'
rt4_branch="pm-review-target-test-origin"
rt4_sha="$(git -C "$RT_ORIGIN_SRC" rev-parse HEAD)"
git -C "$RT_ORIGIN_SRC" push -q "$RT_ORIGIN_BARE" "HEAD:refs/heads/$rt4_branch"
git -C "$PROJECT_DIR" remote add origin "$RT_ORIGIN_BARE"
check "review-target case A4 setup: the target sha is not yet present locally" \
    "1" "$(git -C "$PROJECT_DIR" cat-file -e "$rt4_sha^{commit}" >/dev/null 2>&1 && echo 0 || echo 1)"

printf '%s\n' 'kick off review' > "$work/body.tmp"
rt4_mid="$("$MAIL" send --from '@carol' --to '@kai' --subject 'review target origin fetch topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt4_branch:$rt4_sha" 2>/dev/null)"
rt4_tid="$(thread_of "$rt4_mid")"
: > "$STUB_ARGV_LOG"
once
check "review-target case A4: the sha is fetched from origin and the spawn proceeds with --checkout" \
    "$rt4_sha" "$(argv_after --checkout "$STUB_ARGV_LOG")"
check "review-target case A4: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$rt4_tid" ]] && echo 1 || echo 0 )"
git -C "$PROJECT_DIR" remote remove origin

# ---- upstream-head: `mail reply --upstream-head` delivers a human's push
# to the thread's `sets` seat (ken) as --extra-ref upstream=<sha> ----
k8s_uh_seed

# ---- upstream-head case 1: a non-fleet sender's announcement is recorded,
# and the sets seat's wake carries --extra-ref upstream=<sha> beside its
# unchanged --checkout ----
uh_kickoff ken; uh1_mid="$UH_MID"
uh1_tid="$(thread_of "$uh1_mid")"
uh1_short="${uh1_tid:0:8}"
uh1_file="$PM_STATE_DIR/upstream-head/$uh1_tid.env"
check "upstream-head case 1 setup: no state file before any announcement" 0 \
    "$( [[ -e "$uh1_file" ]] && echo 1 || echo 0 )"
uh1_reply="$(reply_msg '@ci-demo' "$uh1_mid" 'pushed' --to '@ken' --upstream-head "$uh_branch:$uh_sha")"
once
uh1_state="$(cat "$uh1_file" 2>/dev/null)"
contains "upstream-head case 1: state file BRANCH" "$uh1_state" "BRANCH=$uh_branch"
contains "upstream-head case 1: state file SHA" "$uh1_state" "SHA=$uh_sha"
contains "upstream-head case 1: state file MSGID is the announcing message" "$uh1_state" "MSGID=$uh1_reply"
contains "upstream-head case 1: state file SET_AT" "$uh1_state" "SET_AT="
check "upstream-head case 1: state file has exactly four keys" 4 "$(grep -c '=' "$uh1_file")"
contains "upstream-head case 1: the event names the thread and short sha" \
    "$(cat "$work/once.out")" "pm upstream-head thread=$uh1_short sha=${uh_sha:0:12}"
check "upstream-head case 1: ken's wake passes --extra-ref upstream=<sha>" \
    "upstream=$uh_sha" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "upstream-head case 1: ken also gets the announcing message's head ref, after upstream" \
    "upstream=$uh_sha head-$(head_id "$uh1_reply")=$uh_sha" "$(extra_refs | paste -sd' ')"
check "prior heads: the head ref is pinned in the project repo" "$uh_sha" \
    "$(git -C "$PROJECT_DIR" rev-parse "refs/fork-sandbox/review/$uh1_tid/head-$(head_id "$uh1_reply")" 2>/dev/null)"
check "upstream-head case 1: --checkout is unchanged (ken's lineage, not the upstream sha)" \
    "1" "$( [[ -n "$(argv_after --checkout "$STUB_ARGV_LOG")" && "$(argv_after --checkout "$STUB_ARGV_LOG")" != "$uh_sha" ]] && echo 1 || echo 0 )"
check "upstream-head case 1: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$uh1_tid" ]] && echo 1 || echo 0 )"

# Every sets-seat wake while the file exists carries it -- no "answered" state.
: > "$STUB_ARGV_LOG"
reply_msg '@carol' "$uh1_reply" 'and another thing' --to '@ken' >/dev/null
once
check "upstream-head case 1b: a later ordinary wake of ken still passes --extra-ref" \
    "upstream=$uh_sha" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "upstream-head case 1b: the file is unchanged by an ordinary message" "$uh1_state" \
    "$(cat "$uh1_file")"
check "prior heads: an ordinary wake still carries the same two refs" \
    "upstream=$uh_sha head-$(head_id "$uh1_reply")=$uh_sha" "$(extra_refs | paste -sd' ')"

# The newest announcement replaces the file wholesale.
uh_sha2="$(uh_commit "$uh_branch-2")"
: > "$STUB_ARGV_LOG"
uh1_reply2="$(reply_msg '@ci-demo' "$uh1_reply" 'pushed again' --to '@ken' --upstream-head "$uh_branch-2:$uh_sha2")"
once
uh1_state2="$(cat "$uh1_file")"
contains "upstream-head case 1c: the newest announcement's branch wins" "$uh1_state2" "BRANCH=$uh_branch-2"
contains "upstream-head case 1c: the newest announcement's sha wins" "$uh1_state2" "SHA=$uh_sha2"
contains "upstream-head case 1c: MSGID moves to the newest message" "$uh1_state2" "MSGID=$uh1_reply2"
check "upstream-head case 1c: still four keys (replaced, not appended)" 4 "$(grep -c '=' "$uh1_file")"
check "upstream-head case 1c: the wake carries the newest sha" \
    "upstream=$uh_sha2" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "prior heads: every announcement's head ref rides along, latest included" \
    "upstream=$uh_sha2 head-$(head_id "$uh1_reply")=$uh_sha head-$(head_id "$uh1_reply2")=$uh_sha2" \
    "$(extra_refs | paste -sd' ')"
check "prior heads: every name is well formed with a full sha" 0 \
    "$(extra_refs | grep -cv -E '^[a-z][a-z0-9-]{0,30}=[0-9a-f]{40}$' || true)"
check "prior heads: names are unique within a wake" "" "$(extra_refs | cut -d= -f1 | sort | uniq -d)"

# A local seat on the same thread gets no extra ref.
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$uh1_reply" 'for alice' --to '@alice' >/dev/null
once
check "prior heads: a local seat woke" 1 "$(grep -c -- '^--clone-dir$' "$STUB_ARGV_LOG")"
check "prior heads: a local seat gets no --extra-ref" 0 "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"

# ---- upstream-head case 2: a `follow` seat (kai) gets no extra ref, though
# the thread's state file is written ----
uh_kickoff kai; uh2_mid="$UH_MID"
uh2_tid="$(thread_of "$uh2_mid")"
reply_msg '@ci-demo' "$uh2_mid" 'pushed' --to '@kai' --upstream-head "$uh_branch:$uh_sha" >/dev/null
once
check "upstream-head case 2: the state file is written for the thread" 1 \
    "$( [[ -e "$PM_STATE_DIR/upstream-head/$uh2_tid.env" ]] && echo 1 || echo 0 )"
check "upstream-head case 2: kai was woken" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "upstream-head case 2: a follow seat gets no upstream ref, only the thread's head ref" 1 \
    "$(extra_refs | grep -c '^head-')"
check "upstream-head case 2: and exactly one ref" 1 "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"

# ---- upstream-head case 3: a fleet sender's header is ignored and logged ----
uh_kickoff ken; uh3_mid="$UH_MID"
uh3_tid="$(thread_of "$uh3_mid")"
uh3_short="${uh3_tid:0:8}"
pm_flag_file="$PM_STATE_DIR/needs-operator/$uh3_tid"
mkdir -p -- "$PM_STATE_DIR/needs-operator" "$PM_STATE_DIR/spawns"
printf 'pre-existing flag\n' > "$pm_flag_file"
seq 1 5 > "$PM_STATE_DIR/spawns/$uh3_tid"
reply_msg '@ken' "$uh3_mid" 'i moved it myself' --to '@carol' --upstream-head "$uh_branch:$uh_sha" >/dev/null
once
check "upstream-head case 3: no state file for a fleet sender" 0 \
    "$( [[ -e "$PM_STATE_DIR/upstream-head/$uh3_tid.env" ]] && echo 1 || echo 0 )"
contains "upstream-head case 3: the ignored header is logged" \
    "$(cat "$work/once.out")" "pm upstream-head-ignored thread=$uh3_short reason=fleet-sender"
check "upstream-head case 3: the flag was not cleared" 1 "$( [[ -e "$pm_flag_file" ]] && echo 1 || echo 0 )"
check "upstream-head case 3: the spawn count was not reset" "1" \
    "$( [[ "$(wc -l < "$PM_STATE_DIR/spawns/$uh3_tid")" -ge 5 ]] && echo 1 || echo 0 )"
reply_msg '@carol' "$uh3_mid" 'plain follow-up' --to '@ken' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "upstream-head case 3: a later ken wake carries no --extra-ref" 0 "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"

# ---- upstream-head case 4: the announcing message re-arms the thread ----
uh_kickoff ken; uh4_mid="$UH_MID"
uh4_tid="$(thread_of "$uh4_mid")"
mkdir -p -- "$PM_STATE_DIR/needs-operator" "$PM_STATE_DIR/spawns"
printf 'thread budget 96 exhausted\n' > "$PM_STATE_DIR/needs-operator/$uh4_tid"
seq 1 96 > "$PM_STATE_DIR/spawns/$uh4_tid"
uh4_seq_before="$(wc -l < "$PM_STATE_DIR/seq/$uh4_tid")"
reply_msg '@ci-demo' "$uh4_mid" 'pushed' --to '@ken' --upstream-head "$uh_branch:$uh_sha" >/dev/null
once
check "upstream-head case 4: ken woke despite the exhausted budget" \
    "upstream=$uh_sha" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "upstream-head case 4: the flag was cleared" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$uh4_tid" ]] && echo 1 || echo 0 )"
check "upstream-head case 4: the spawn count restarted (one spawn since the reset)" 1 \
    "$(wc -l < "$PM_STATE_DIR/spawns/$uh4_tid")"
check "upstream-head case 4: the sequence counter was NOT reset" "1" \
    "$( [[ "$(wc -l < "$PM_STATE_DIR/seq/$uh4_tid")" -gt "$uh4_seq_before" ]] && echo 1 || echo 0 )"

# ---- upstream-head case 5: a sha that is not in the project repo flags the
# thread and does not wake -- and a branch that origin can supply is fetched ----
uh_kickoff ken; uh5_mid="$UH_MID"
uh5_tid="$(thread_of "$uh5_mid")"
uh5_short="${uh5_tid:0:8}"
uh5_missing="$(printf 'c%.0s' {1..40})"
reply_msg '@ci-demo' "$uh5_mid" 'pushed' --to '@ken' --upstream-head "feature/gone:$uh5_missing" >/dev/null
once
contains "upstream-head case 5: a missing sha is flagged" \
    "$(cat "$PM_STATE_DIR/needs-operator/$uh5_tid" 2>/dev/null)" "upstream head feature/gone $uh5_missing not found"
contains "upstream-head case 5: the flag event uses the upstream-head keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$uh5_short reason=upstream-head"
check "upstream-head case 5: ken was not woken" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "upstream-head case 5: no --extra-ref was forwarded" 0 "$(grep -c -- '^--extra-ref$' "$STUB_ARGV_LOG")"

k8s_origin_mirror_seed

uh_kickoff ken; uh6_mid="$UH_MID"
uh6_tid="$(thread_of "$uh6_mid")"
reply_msg '@ci-demo' "$uh6_mid" 'pushed' --to '@ken' --upstream-head "feature/pushed:$uh_origin_sha" >/dev/null
once
check "upstream-head case 6: a sha only on origin's branch is fetched and the wake proceeds" \
    "upstream=$uh_origin_sha" "$(argv_after --extra-ref "$STUB_ARGV_LOG")"
check "upstream-head case 6: the thread is not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$uh6_tid" ]] && echo 1 || echo 0 )"

# The branch moved on again: origin has the branch, but not the announced sha.
uh_kickoff ken; uh7_mid="$UH_MID"
uh7_tid="$(thread_of "$uh7_mid")"
reply_msg '@ci-demo' "$uh7_mid" 'pushed' --to '@ken' --upstream-head "feature/pushed:$uh5_missing" >/dev/null
FORK_SANDBOX_POSTMASTER_FETCH_WINDOW=0 once
contains "upstream-head case 7: with the fetch window at 0 a sha the fetched branch does not hold is flagged at once" \
    "$(cat "$PM_STATE_DIR/needs-operator/$uh7_tid" 2>/dev/null)" "upstream head feature/pushed $uh5_missing not found"
check "upstream-head case 7: ken was not woken" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "upstream-head case 7: nothing was deferred" 0 "$(grep -c 'reason=fetch-miss' "$work/once.out")"
check "upstream-head case 7: no fetch-wait record" 0 "$(find "$PM_STATE_DIR/fetch-wait" -type f 2>/dev/null | wc -l)"

finish_suite
