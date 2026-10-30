#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/12-k8s-wakes.sh — fork-sandbox-postmaster.sh: backend: k8s
# seats -- grants, exit codes, holds, adoption, shutdown drain, cluster mode.
#
# Usage: tests/postmaster/12-k8s-wakes.sh  (or all files at once:
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

# ---- case 2: a local seat on the same fleet spawns exactly as before ----

# Fresh root: case1's k8s reply (no explicit To:, so reply-all to its
# trigger's sender) is still an unrouted message at this point -- routing
# it here, in the same MAIL_ROOT, would wake @carol too and pollute this
# case's --clone-dir count with a spawn this case never asked for.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

: > "$STUB_ARGV_LOG"
send_msg '@carol' '@alice' 'local topic' 'hello alice' 8 >/dev/null
once
check "k8s case2: a local seat still gets --clone-dir" 1 "$(grep -c -- '^--clone-dir$' "$STUB_ARGV_LOG")"
check "k8s case2: a local seat carries no --k8s" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"

# ---- case 3: grant forwarding, in file order ----

k3_ctx_dir="$(mktemp -d /var/tmp/claude-scratch/forks/pm-k8s-test-ctx.XXXXXX)"
tmpdirs+=("$k3_ctx_dir")
printf '%s\n' 'grant body' > "$work/body.tmp"
"$MAIL" send --from '@carol' --to '@karen' --subject 'grant topic' \
    --body "$work/body.tmp" --hops 8 \
    --allow-namespace ns-one --allow-namespace ns-two \
    --reach-probe svc.ns-one:80 --reach-probe svc.ns-two:443 \
    --host-alias 192.0.2.1=a.example.com,b.example.com --host-alias 192.0.2.2=c.example.com \
    --context-ro "$k3_ctx_dir" >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
k3_joined="$(tr '\n' $'\x01' < "$STUB_ARGV_LOG")"
k3_expected="--allow-namespace"$'\x01'"ns-one"$'\x01'"--allow-namespace"$'\x01'"ns-two"$'\x01'"--reach-probe"$'\x01'"svc.ns-one:80"$'\x01'"--reach-probe"$'\x01'"svc.ns-two:443"$'\x01'"--host-alias"$'\x01'"192.0.2.1=a.example.com,b.example.com"$'\x01'"--host-alias"$'\x01'"192.0.2.2=c.example.com"$'\x01'"--context-ro"$'\x01'"$k3_ctx_dir"
contains "k8s case3: grant flags forwarded in file order" "$k3_joined" "$k3_expected"

# ---- case 3b: a grant's context Secret is forwarded as --context-secret ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

"$MAIL" send --from '@carol' --to '@karen' --subject 'secret grant topic' \
    --body "$work/body.tmp" --hops 8 --context-secret preview-ctx >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "k8s case3b: --context-secret forwarded with the grant's Secret name" preview-ctx \
    "$(argv_after --context-secret "$STUB_ARGV_LOG")"
check "k8s case3b: the k8s seat also carries --k8s" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case3b: no --context-ro is forwarded" 0 "$(grep -c -- '^--context-ro$' "$STUB_ARGV_LOG")"

# ---- case 3c: SEAT_RESOURCES= reaches only the seat it names ----
# The grant names two k8s seats (karen, kara). Karen's wake gets karen's
# cpu/memory, alone, as --agent-resources; kim, a k8s seat the grant does
# not name, woken on a thread carrying the same two lines, gets none.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

"$MAIL" send --from '@carol' --to '@karen' --subject 'seat resources topic' \
    --body "$work/body.tmp" --hops 8 --host-alias 192.0.2.1=a.example.com \
    --seat-resources kara=cpu=500m --seat-resources karen=cpu=2,memory=4Gi >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "k8s case3c: the named seat gets exactly one --agent-resources" 1 \
    "$(grep -c -- '^--agent-resources$' "$STUB_ARGV_LOG")"
check "k8s case3c: the named seat's --agent-resources is its own cpu/memory, seat stripped" \
    cpu=2,memory=4Gi "$(argv_after --agent-resources "$STUB_ARGV_LOG")"
check "k8s case3c: the thread's other grant flags still reach the named seat" \
    192.0.2.1=a.example.com "$(argv_after --host-alias "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

"$MAIL" send --from '@carol' --to '@kim' --subject 'other seat resources topic' \
    --body "$work/body.tmp" --hops 8 --host-alias 192.0.2.1=a.example.com \
    --seat-resources kara=cpu=500m --seat-resources karen=cpu=2,memory=4Gi >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "k8s case3c: a k8s seat the grant does not name is still woken on k8s" 1 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case3c: a k8s seat the grant does not name gets no --agent-resources" 0 \
    "$(grep -c -- '^--agent-resources$' "$STUB_ARGV_LOG")"
check "k8s case3c: the unnamed seat still gets the thread-wide --host-alias" \
    192.0.2.1=a.example.com "$(argv_after --host-alias "$STUB_ARGV_LOG")"

# ---- case 4: endpoint -> --endpoint; a pi seat's thinking -> --pi-args ----

# Fresh root: case3's own grant-topic reply (no explicit To:, so
# reply-all to carol) is still an unrouted message at this point -- left
# in place, this case's own `once` would route it too and wake carol (a
# real local fleet seat) alongside kim, doubling counts like
# --session-state's in the exact-count checks below.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

: > "$STUB_ARGV_LOG"
send_msg '@carol' '@kim' 'endpoint topic' 'hello kim' 8 >/dev/null
once
check "k8s case4: --endpoint forwarded" kim-endpoint "$(argv_after --endpoint "$STUB_ARGV_LOG")"
check "k8s case4: pi thinking forwarded as --pi-args" '--thinking medium' \
    "$(argv_after --pi-args "$STUB_ARGV_LOG")"
check "k8s case4: a pi seat gets no --effort" 0 "$(grep -c -- '^--effort$' "$STUB_ARGV_LOG")"
# A pi seat is given-mode (fs_harness_session_caps): --session-id is
# derived, not discovered, so it arrives on the very first wake -- unlike
# karen's (claude, discover-mode) case1 above, which gets no --session-id
# until a prior wake's transcript has been found.
check "k8s case4: a pi seat gets --session-state" \
    1 "$(grep -c -- '^--session-state$' "$STUB_ARGV_LOG")"
check "k8s case4: a pi seat gets --session-id on its first wake" \
    1 "$(grep -c -- '^--session-id$' "$STUB_ARGV_LOG")"
check "k8s case4: a pi seat gets no --resume-session (create-if-missing, not discovered)" \
    0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"

# ---- case 4b: --refresh-at is forwarded for a claude k8s seat, not a pi one ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

: > "$STUB_ARGV_LOG"
send_msg '@carol' '@kara' 'refresh topic' 'hello kara' 8 >/dev/null
once
check "k8s case4b: a claude k8s seat gets --refresh-at" 0.4 \
    "$(argv_after --refresh-at "$STUB_ARGV_LOG")"
check "k8s case4b: --clone-dir stays absent" 0 "$(grep -c -- '^--clone-dir$' "$STUB_ARGV_LOG")"
check "k8s case4b: a claude k8s seat's thinking is forwarded as --effort" xhigh \
    "$(argv_after --effort "$STUB_ARGV_LOG")"
check "k8s case4b: a claude seat gets no --pi-args" 0 "$(grep -c -- '^--pi-args$' "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

: > "$STUB_ARGV_LOG"
send_msg '@carol' '@kim' 'refresh pi topic' 'hello kim again' 8 >/dev/null
once
check "k8s case4b: a pi k8s seat with refresh-at gets no --refresh-at" 0 \
    "$(grep -c -- '^--refresh-at$' "$STUB_ARGV_LOG")"

# ---- case 5: rc 2 (dead pod), no k8s summary -> flagged, retried, retry handoff ----

export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k5_mid="$(send_msg '@carol' '@karen' 'k8s crash topic' 'first' 8)"
k5_tid="$(thread_of "$k5_mid")"
export STUB_K8S_EXIT=2 STUB_K8S_NO_SUMMARY=1
once
contains "k8s case5: thread flagged wake exited 2" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5_tid" 2>/dev/null)" "wake for karen exited 2"
contains "k8s case5: a retry was scheduled" \
    "$(cat "$PM_STATE_DIR/retries/$k5_tid/karen" 2>/dev/null)" "STATE=pending"

: > "$STUB_ARGV_LOG"
once
k5_retry_run_id="$(basename "$(latest_env_for_agent karen)" .env)"
k5_retry_handoff="$PM_STATE_DIR/handoffs/$k5_retry_run_id.md"
# --k8s count, not a raw CALL count: the first crash's outbox reply is
# harvested (and posted/routed) exactly like any local wake's crash-time
# reply (see "dead pid, reply already on disk" above) -- it reply-alls to
# @carol, a real local fleet seat, who is legitimately woken by THIS
# pass's own route step alongside karen's retry. Same pattern case7 uses
# to tell a k8s wake apart from a co-occurring local one.
check "k8s case5: the retry actually fired" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case5: retry handoff carries the retry section" 1 \
    "$(grep -c -- '^## This is a retry$' "$k5_retry_handoff")"
unset STUB_K8S_EXIT STUB_K8S_NO_SUMMARY

# ---- case 5b: rc 1 (wait timeout, pod still running) is not a crash ----
# fork-sandbox-k8s.sh run's own rc 1 means the wait deadline passed with
# the pod still running, holding its work -- not a dead pod (rc 2). Feeding
# it into the same crash-retry path as case 5 would spawn a second Job for
# this seat while the first is still live (the bug this case guards
# against): no retry may be scheduled, and the flag must name the timeout
# specifically rather than the generic "exited N" crash message.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k5b_mid="$(send_msg '@carol' '@karen' 'k8s timeout topic' 'first' 8)"
k5b_tid="$(thread_of "$k5b_mid")"
export STUB_K8S_EXIT=1 STUB_K8S_NO_SUMMARY=1 STUB_K8S_NO_REPLY=1 STUB_K8S_TIMEOUT_MSG=1
once
unset STUB_K8S_EXIT STUB_K8S_NO_SUMMARY STUB_K8S_NO_REPLY STUB_K8S_TIMEOUT_MSG
contains "k8s case5b: thread flagged as a timeout, not a generic exit" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5b_tid" 2>/dev/null)" "timed out waiting on its Job"
contains "k8s case5b: the flag says the cluster stops the Job past its TIMEOUT" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5b_tid" 2>/dev/null)" "the cluster stops it about 600s past the run's TIMEOUT"
check "k8s case5b: no retry scheduled -- a live Job is not a crash" 0 \
    "$( [[ -e "$PM_STATE_DIR/retries/$k5b_tid/karen" ]] && echo 1 || echo 0 )"

: > "$STUB_ARGV_LOG"
once
check "k8s case5b: no second Job launched behind the still-running one" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"

# ---- case 5b2: a pending message must not wake behind a still-running Job ----
# was_failure is deliberately left 0 by the rc-1 branch above (no
# crash-retry), but the pending-message follow-up used to fire regardless
# of was_failure: pm_mail_delivered_live has no events.jsonl to check for
# a k8s run (there is no inbox hook to log into), so it always fell
# through to pm_followup_wake and spawned a second Job for the same seat
# and thread while the first one was still running -- fs_pm_find_live_run
# stops treating a run as live the instant this harvest marks it
# $HARVESTED, whether or not the k8s Job itself is done. A second message
# on the same thread, sent before the first wake is harvested, reproduces
# the window: route_pass processes both in one pass (debounce is off for
# this whole file), so the second one pends against the still-unharvested
# run, and only then does harvest_pass run.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k5b2_mid1="$(send_msg '@carol' '@karen' 'k8s timeout pending topic' 'first' 8)"
k5b2_mid2="$(reply_msg '@carol' "$k5b2_mid1" 'second' --to '@karen')"
export STUB_K8S_EXIT=1 STUB_K8S_NO_SUMMARY=1 STUB_K8S_NO_REPLY=1 STUB_K8S_TIMEOUT_MSG=1
: > "$STUB_ARGV_LOG"
once
unset STUB_K8S_EXIT STUB_K8S_NO_SUMMARY STUB_K8S_NO_REPLY STUB_K8S_TIMEOUT_MSG
check "k8s case5b2: only one Job launched, not a second behind it" 1 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
k5b2_env="$(latest_env_for_agent karen)"
contains "k8s case5b2: the second message was still recorded as pending" \
    "$(cat "$k5b2_env" 2>/dev/null)" "PENDING_MSGS=$k5b2_mid2"

# ---- case 5c: rc 1 with no run dir recorded is an ordinary failure ----
# fork-sandbox.sh's and fork-sandbox-k8s.sh's own argument-check refusals
# also exit 1, before any Job is ever submitted. fork-sandbox-k8s-wake.sh's
# own k8s-run-dir file is empty in that case (see its step 3), unlike a
# genuine wait timeout where a Job exists -- confusing the two flagged a
# refusal as "the Job is still running -- fetch/rm it" (a Job that never
# existed) and, since was_failure stayed 0, never scheduled the retry a
# plain failure gets everywhere else.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k5c_mid="$(send_msg '@carol' '@karen' 'k8s refusal topic' 'first' 8)"
k5c_tid="$(thread_of "$k5c_mid")"
export STUB_K8S_EXIT=1 STUB_K8S_NO_RUNDIR=1 STUB_K8S_NO_REPLY=1
once
unset STUB_K8S_EXIT STUB_K8S_NO_RUNDIR STUB_K8S_NO_REPLY
contains "k8s case5c: flagged as an ordinary exit, not a Job timeout" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5c_tid" 2>/dev/null)" "wake for karen exited 1"
check "k8s case5c: no Job-timeout wording without a Job" 0 \
    "$( [[ "$(cat "$PM_STATE_DIR/needs-operator/$k5c_tid" 2>/dev/null)" == *"timed out waiting on its Job"* ]] && echo 1 || echo 0 )"
contains "k8s case5c: a retry was scheduled, same as any other failure" \
    "$(cat "$PM_STATE_DIR/retries/$k5c_tid/karen" 2>/dev/null)" "STATE=pending"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
k5head_mid="$(send_msg '@carol' '@karen' 'low pool topic' 'first' 8)"
k5head_tid="$(thread_of "$k5head_mid")"
STUB_K8S_EXIT=1 STUB_K8S_NO_RUNDIR=1 STUB_K8S_NO_REPLY=1 \
    STUB_K8S_NO_CANDIDATE=1 once
contains "k8s headroom: no candidate is named in the wake flag" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5head_tid" 2>/dev/null)" \
    'headroom: no candidate'
contains "k8s headroom: failure follows the retry path" \
    "$(cat "$PM_STATE_DIR/retries/$k5head_tid/karen" 2>/dev/null)" 'STATE=pending'

# ---- case 5d: rc 1 after a completed run (the agent's own exit 1) ----
# fork-sandbox-k8s.sh run exits with the agent's code once collect has
# run, so a claude seat that died on a 401 also lands here as rc 1 with
# a run dir and a summary -- a crash to retry, not a live Job.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k5d_mid="$(send_msg '@carol' '@karen' 'k8s agent exit topic' 'first' 8)"
k5d_tid="$(thread_of "$k5d_mid")"
export STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1
once
unset STUB_K8S_EXIT STUB_K8S_NO_REPLY
contains "k8s case5d: flagged as an ordinary exit" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k5d_tid" 2>/dev/null)" "wake for karen exited 1"
check "k8s case5d: no Job-timeout wording for a finished run" 0 \
    "$( [[ "$(cat "$PM_STATE_DIR/needs-operator/$k5d_tid" 2>/dev/null)" == *"timed out waiting on its Job"* ]] && echo 1 || echo 0 )"
contains "k8s case5d: a retry was scheduled" \
    "$(cat "$PM_STATE_DIR/retries/$k5d_tid/karen" 2>/dev/null)" "STATE=pending"

# ---- case 6: rc 3 zero-harvest -> harvested clean, kept Job reaped ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k6_mid="$(send_msg '@carol' '@karen' 'k8s zero harvest topic' 'first' 8)"
k6_tid="$(thread_of "$k6_mid")"
export STUB_K8S_EXIT=3 STUB_K8S_NO_REPLY=1 STUB_K8S_SUMMARY_EXIT=0
once
unset STUB_K8S_EXIT STUB_K8S_NO_REPLY STUB_K8S_SUMMARY_EXIT
check "k8s case6: no flag on a zero-harvest exit" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$k6_tid" ]] && echo 1 || echo 0 )"
check "k8s case6: no retry schedule (a clean exit)" 0 \
    "$( [[ -e "$PM_STATE_DIR/retries/$k6_tid/karen" ]] && echo 1 || echo 0 )"
k6_env="$(latest_env_for_agent karen)"
k6_rundir="$(env_val "$k6_env" RUN_DIR)"
k6_branch="$(env_val "$k6_env" BRANCH)"
check "k8s case6: recorded exit-code normalized to 0" 0 "$(cat "$k6_rundir/exit-code" 2>/dev/null)"
check "k8s case6: the stub fork-sandbox-k8s.sh was called with rm --branch" \
    "rm --branch $k6_branch" "$(cat "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
contains "k8s case6: the wrapper attempted to reap the kept Job" \
    "$(cat "$k6_rundir/launch.log" 2>/dev/null)" "reaping zero-harvest Job for branch"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ---- case 7: grant: required hold ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

k7_mid="$(send_msg '@carol' '@karl,@alice' 'hold topic' 'first' 8)"
k7_tid="$(thread_of "$k7_mid")"
k7_short="${k7_tid:0:8}"
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "k8s case7: the local seat (alice) WAS woken" 1 "$(grep -c -- '^--clone-dir$' "$STUB_ARGV_LOG")"
check "k8s case7: the held seat (karl) was NOT launched" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
contains "k8s case7: a no-grant refuse event fired" "$(cat "$work/once.out")" \
    "pm refuse thread=$k7_short agent=karl reason=no-grant"
contains "k8s case7: the thread is flagged no-grant" \
    "$(cat "$PM_STATE_DIR/needs-operator/$k7_tid" 2>/dev/null)" "no grant for k8s seat karl"
check "k8s case7: a held record exists" 1 \
    "$( [[ -f "$PM_STATE_DIR/held/$k7_tid/karl" ]] && echo 1 || echo 0 )"
contains "k8s case7: the held record's TRIGGER is the message" \
    "$(cat "$PM_STATE_DIR/held/$k7_tid/karl")" "TRIGGER=$k7_mid"

: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "k8s case7: second pass -- still not launched" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
not_contains "k8s case7: second pass -- no new no-grant event" \
    "$(cat "$work/once.out")" "reason=no-grant"

"$MAIL" grant "$k7_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
contains "k8s case7: a held-release event fired" "$(cat "$work/once.out")" \
    "pm held-release thread=$k7_short agent=karl trigger=${k7_mid:0:8}"
check "k8s case7: karl now spawns with --k8s" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case7: karl's argv carries the grant flag" 1 \
    "$(grep -c -- '^--allow-namespace$' "$STUB_ARGV_LOG")"
check "k8s case7: the held record is gone after release" 0 \
    "$( [[ -f "$PM_STATE_DIR/held/$k7_tid/karl" ]] && echo 1 || echo 0 )"

k7b_mid="$(send_msg '@carol' '@karl' 'hold clear topic' 'first' 8)"
k7b_tid="$(thread_of "$k7b_mid")"
once
"$MAIL" grant "$k7b_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
"$MAIL" grant "$k7b_tid" --clear >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "k8s case7: grant --clear before release -- still held" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case7: still holding a record" 1 \
    "$( [[ -f "$PM_STATE_DIR/held/$k7b_tid/karl" ]] && echo 1 || echo 0 )"

# ---- case 8: hold supersede -- a second message while held ----

k8a_mid="$(send_msg '@carol' '@karl' 'supersede topic' 'first' 8)"
k8_tid="$(thread_of "$k8a_mid")"
once
k8_since_before="$(env_val "$PM_STATE_DIR/held/$k8_tid/karl" SINCE)"
sleep 1
k8b_mid="$(reply_msg '@carol' "$k8a_mid" 'second message')"
once
contains "k8s case8: the held record's TRIGGER moved to the new mid" \
    "$(cat "$PM_STATE_DIR/held/$k8_tid/karl" 2>/dev/null)" "TRIGGER=$k8b_mid"
check "k8s case8: the held record's SINCE survives the supersede" \
    "$k8_since_before" "$(env_val "$PM_STATE_DIR/held/$k8_tid/karl" SINCE)"

"$MAIL" grant "$k8_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
k8_env="$(latest_env_for_agent karl)"
check "k8s case8: release wakes on the NEW mid" "$k8b_mid" "$(env_val "$k8_env" TRIGGER)"

# ---- case 9: a retry that fires into a hold ----

export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

printf '%s\n' 'grant body' > "$work/body.tmp"
k9_mid="$("$MAIL" send --from '@carol' --to '@karl' --subject 'retry-into-hold topic' \
    --body "$work/body.tmp" --hops 8 --allow-namespace ns-a --reach-probe svc.ns-a:80 2>/dev/null)"
k9_tid="$(thread_of "$k9_mid")"
export STUB_K8S_EXIT=2 STUB_K8S_NO_SUMMARY=1
once
contains "k8s case9: the real run failed and scheduled a retry" \
    "$(cat "$PM_STATE_DIR/retries/$k9_tid/karl" 2>/dev/null)" "STATE=pending"

"$MAIL" grant "$k9_tid" --clear >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
unset STUB_K8S_EXIT STUB_K8S_NO_SUMMARY
# --k8s count, not a raw CALL count: same reasoning as case5 above -- the
# first run's crash-time outbox reply is harvested and reply-alls to
# @carol, a real local fleet seat, who is legitimately woken by this
# pass's own route step even though karl's retry itself falls into the
# hold and never reaches the launcher.
check "k8s case9: no launcher call -- the retry fell into a hold" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case9: the retry schedule was dropped" "" \
    "$(sed -n 's/^TRIGGER=//p' "$PM_STATE_DIR/retries/$k9_tid/karl" 2>/dev/null)"
contains "k8s case9: the held record carries RETRY=1" \
    "$(cat "$PM_STATE_DIR/held/$k9_tid/karl" 2>/dev/null)" "RETRY=1"

"$MAIL" grant "$k9_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
k9_run_id="$(basename "$(latest_env_for_agent karl)" .env)"
check "k8s case9: the released wake's handoff carries the retry section" 1 \
    "$(grep -c -- '^## This is a retry$' "$PM_STATE_DIR/handoffs/$k9_run_id.md")"

# ---- case 9b: a discarded-reply (malformed) retry that fires into a hold ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
printf '%s\n' 'grant body' > "$work/body.tmp"
k9b_mid="$("$MAIL" send --from '@carol' --to '@karl' --subject 'malformed-into-hold topic' \
    --body "$work/body.tmp" --hops 8 --allow-namespace ns-a --reach-probe svc.ns-a:80 2>/dev/null)"
k9b_tid="$(thread_of "$k9b_mid")"
"$MAIL" grant "$k9b_tid" --clear >/dev/null 2>&1
# The state a harvest leaves for an `on-silence: retry` seat whose reply files
# were all discarded: a due-now malformed schedule and the discard reasons.
mkdir -p "$PM_STATE_DIR/retries/$k9b_tid" "$PM_STATE_DIR/discards/$k9b_tid"
printf 'STATE=pending\nREASON=malformed\nTRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=1\n' "$k9b_mid" \
    > "$PM_STATE_DIR/retries/$k9b_tid/karl"
printf '%s\n' 'malformed reply file mail-1.md: invented reason' > "$PM_STATE_DIR/discards/$k9b_tid/karl"
: > "$STUB_ARGV_LOG"
once
check "k8s case9b: no launcher call -- the malformed retry fell into a hold" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
contains "k8s case9b: the held record carries RETRY=malformed" \
    "$(cat "$PM_STATE_DIR/held/$k9b_tid/karl" 2>/dev/null)" "RETRY=malformed"
"$MAIL" grant "$k9b_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
k9b_run_id="$(basename "$(latest_env_for_agent karl)" .env)"
k9b_ho="$(cat "$PM_STATE_DIR/handoffs/$k9b_run_id.md" 2>/dev/null)"
contains "k8s case9b: the released wake's handoff has the discarded-reply section" \
    "$k9b_ho" "## Your previous reply was discarded"
contains "k8s case9b: with the reason verbatim" "$k9b_ho" "- malformed reply file mail-1.md: invented reason"
not_contains "k8s case9b: and not the crash text" "$k9b_ho" "## This is a retry"

unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ---- no-grant threads: X-Grant: none on the root ----
ng_flags_in_argv() {
    grep -c -e '^--allow-namespace$' -e '^--reach-probe$' -e '^--context-ro$' -e '^--context-secret$' "$STUB_ARGV_LOG" || true
}
ng_key() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

printf '%s\n' 'no env body' > "$work/body.tmp"
ng1_mid="$("$MAIL" send --from '@carol' --to '@karl' --subject 'no env topic' \
    --body "$work/body.tmp" --hops 8 --no-grant 2>/dev/null)"
ng1_tid="$(thread_of "$ng1_mid")"; ng1_short="${ng1_tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "no-grant thread: a grant: required seat spawns at once with --k8s" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "no-grant thread: and carries no grant flag" 0 "$(ng_flags_in_argv)"
not_contains "no-grant thread: no no-grant refusal" "$(cat "$work/once.out")" "reason=no-grant"
check "no-grant thread: no held record" 0 "$( [[ -e "$PM_STATE_DIR/held/$ng1_tid/karl" ]] && echo 1 || echo 0 )"
check "no-grant thread: no flag" 0 "$( [[ -e "$PM_STATE_DIR/needs-operator/$ng1_tid" ]] && echo 1 || echo 0 )"
ng1_json="$("$postmaster" status --thread "$ng1_tid" --json)"
check "no-grant thread: status grant_mode is none" none "$(ng_key "$ng1_json" grant_mode)"
check "no-grant thread: status grant stays false" False "$(ng_key "$ng1_json" grant)"

# A grant file placed by hand is ignored for every k8s seat.
mkdir -p -- "$PM_STATE_DIR/grants"
printf 'ALLOW_NAMESPACE=ns-a\nREACH_PROBE=svc.ns-a:80\nCONTEXT_SECRET=ctx\n' > "$PM_STATE_DIR/grants/$ng1_tid.env"
ng1_json="$("$postmaster" status --thread "$ng1_tid" --json)"
check "no-grant thread: grant_mode is none even with a file" none "$(ng_key "$ng1_json" grant_mode)"
check "no-grant thread: grant stays true with a file" True "$(ng_key "$ng1_json" grant)"
for ng_seat in karl karen; do
    : > "$STUB_ARGV_LOG"
    reply_msg '@carol' "$ng1_mid" "again $ng_seat" --to "@$ng_seat" >/dev/null
    once
    check "no-grant thread: $ng_seat spawns with a stray grant file" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
    check "no-grant thread: $ng_seat forwards none of it" 0 "$(ng_flags_in_argv)"
    contains "no-grant thread: $ng_seat emits grant-ignored" "$(cat "$work/once.out")" \
        "pm grant-ignored thread=$ng1_short"
done

# No header: a grant: required seat holds, a grant file is forwarded.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
ng2_mid="$(send_msg '@carol' '@karl' 'no header topic' 'first' 8)"
ng2_tid="$(thread_of "$ng2_mid")"; ng2_short="${ng2_tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "no header: a grant: required seat holds" 0 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
contains "no header: with the no-grant refusal" "$(cat "$work/once.out")" \
    "pm refuse thread=$ng2_short agent=karl reason=no-grant"
contains "no header: and the no-grant flag" "$(cat "$PM_STATE_DIR/needs-operator/$ng2_tid" 2>/dev/null)" "no grant for k8s seat karl"
ng2_json="$("$postmaster" status --thread "$ng2_tid" --json)"
check "no header: status grant_mode is missing" missing "$(ng_key "$ng2_json" grant_mode)"
"$MAIL" grant "$ng2_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
ng2_json="$("$postmaster" status --thread "$ng2_tid" --json)"
check "no header: status grant_mode is file once granted" file "$(ng_key "$ng2_json" grant_mode)"
check "no header: status grant is true" True "$(ng_key "$ng2_json" grant)"
: > "$STUB_ARGV_LOG"
once
check "no header: the grant file is forwarded to the released seat" 1 \
    "$(grep -c -- '^--allow-namespace$' "$STUB_ARGV_LOG")"
not_contains "no header: no grant-ignored event" "$(cat "$work/once.out")" "grant-ignored"

# ---- case 10: a malformed K8S_TIMEOUT refuses deliver at startup ----

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

FORK_SANDBOX_POSTMASTER_K8S_TIMEOUT=abc refuses \
    "k8s case10: a non-numeric K8S_TIMEOUT refuses deliver" \
    "$postmaster" deliver --project "$PROJECT_DIR" --once

# ---- case 11: a busy backend: k8s seat gets no live delivery; the second
#      message pends and rides the follow-up wake after harvest (Section 3) ----

# Every case above drives the wrapper with
# FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline, which runs it to completion
# synchronously inside the very pm_route_pass call that spawned it (see
# latest_env_for_agent's comment) -- so by the time a second message could
# route, the first run is already harvested and pm_wake_or_pend's
# BACKEND=k8s check never actually gets exercised against a still-live run.
# This fabricates that live run by hand instead (the same technique the
# "delivered-live" harness group above uses for events.jsonl), with a real,
# writable INBOX dir: if the backend gate in pm_wake_or_pend were missing
# or wrong, pm_deliver_live would actually succeed in writing a banner
# there, and this test would catch it.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

kb_mid1="$(send_msg '@carol' '@karen' 'busy k8s topic' 'first' 8)"
kb_tid="$(thread_of "$kb_mid1")"
kb_run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
mkdir -p -- "$kb_run_dir/inbox"
mkdir -p -- "$PM_STATE_DIR/runs"
{
    printf 'AGENT=karen\n'
    printf 'THREAD=%s\n' "$kb_tid"
    printf 'TRIGGER=%s\n' "$kb_mid1"
    printf 'RUN_DIR=%s\n' "$kb_run_dir"
    printf 'INBOX=%s\n' "$kb_run_dir/inbox"
    printf 'HARNESS=claude\n'
    printf 'MODEL=sonnet\n'
    printf 'NETWORK=\n'
    printf 'BRANCH=sbx-mail-fakebusy-karen-1\n'
    printf 'RESUMED=\n'
    printf 'PENDING_MSGS=\n'
    printf 'VIA=to\n'
    printf 'BACKEND=k8s\n'
} > "$PM_STATE_DIR/runs/fake-busy-run.env"
# kb_mid1 stands in for the trigger of the (fabricated) already-running
# wake above -- mark it routed by hand, the same as a real pm_process_message
# would have before ever reaching pm_wake_or_pend, so the next route pass
# doesn't treat it as a fresh, still-unrouted message and pend it too.
mkdir -p -- "$PM_STATE_DIR/routed"
: > "$PM_STATE_DIR/routed/$kb_mid1"

kb_mid2="$(reply_msg '@carol' "$kb_mid1" 'second message' --to '@karen')"
: > "$STUB_ARGV_LOG"
once
check "k8s case11: busy backend:k8s seat gets no second spawn" 0 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s case11: no live-delivery banner written into the run's inbox" 0 \
    "$(find "$kb_run_dir/inbox" -type f | wc -l)"
contains "k8s case11: the second message recorded as pending on the live run" \
    "$(cat "$PM_STATE_DIR/runs/fake-busy-run.env")" "PENDING_MSGS=$kb_mid2"

mkdir -p -- "$kb_run_dir/outbox"
printf '0\n' > "$kb_run_dir/exit-code"
printf '{}\n' > "$kb_run_dir/summary.json"
printf '\nAcknowledged, thanks.\n' > "$kb_run_dir/outbox/mail-1.md"
: > "$STUB_ARGV_LOG"
once
check "k8s case11: harvest fires a follow-up wake for the pending message" 1 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
kb_followup_env=""
for kb_f in "$PM_STATE_DIR/runs"/*.env; do
    [[ -e "$kb_f" ]] || continue
    kb_rid="$(basename "$kb_f" .env)"
    [[ -e "$PM_STATE_DIR/harvested/$kb_rid" ]] && continue
    grep -q '^AGENT=karen$' "$kb_f" && kb_followup_env="$kb_f"
done
contains "k8s case11: follow-up wake's TRIGGER is the pending message" \
    "$(cat "$kb_followup_env")" "TRIGGER=$kb_mid2"

# ---- status shows grants and held seats ----

k11_mid="$(send_msg '@carol' '@karl' 'status topic' 'first' 8)"
k11_tid="$(thread_of "$k11_mid")"
once
k11_grant_mid="$("$MAIL" send --from '@carol' --to '@karen' --subject 'status grant topic' \
    --body "$work/body.tmp" --hops 8 --allow-namespace ns-a --reach-probe svc.ns-a:80 2>/dev/null)"
k11_grant_tid="$(thread_of "$k11_grant_mid")"
k11_status="$("$postmaster" status 2>&1)"
contains "k8s status: grants section header" "$k11_status" "grants:"
contains "k8s status: held section header" "$k11_status" "held:"
contains "k8s status: grant entry names the thread and key count" "$k11_status" \
    "${k11_grant_tid:0:8}: 2 keys"
contains "k8s status: held section names the thread and agent" "$k11_status" "${k11_tid:0:8}: agent=karl"

# ---- adoption: a k8s wake whose wrapper died is asked about, not assumed dead ----
# A real spawn (inline wake, no reply, so nothing to re-post) builds the run
# env, wake dir and thread; the wake is then made to LOOK orphaned -- its
# summary.json/exit-code gone, its harvested marker cleared, its pid a
# process that has exited -- which is what a postmaster host restart leaves.
# $1 label, $2 probe exit code, $3 adopt-count on file ("" = none),
# $4 backend override for the run env ("" = leave k8s), $5 "handed-off" to
# leave the shutdown drain's marker in the wake dir.
adopt_case() {
    local label="$1" probe_rc="$2" count="$3" backend="${4:-}" handed_off="${5:-}"
    local mid tid env rid wake_dir
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
    mid="$(send_msg '@carol' '@karen' "adopt topic: $label" 'first' 8)"
    tid="$(thread_of "$mid")"
    STUB_K8S_NO_REPLY=1 once
    env="$(latest_env_for_agent karen)"
    rid="$(basename "$env" .env)"
    wake_dir="$(env_val "$env" RUN_DIR)"
    rm -f -- "$PM_STATE_DIR/harvested/$rid" "$wake_dir/summary.json" "$wake_dir/exit-code" \
        "$wake_dir/k8s-run-dir" "$wake_dir/k8s-timeout" "$wake_dir/pid-identity"
    dead_pid_of > "$wake_dir/pid"
    [[ -z "$count" ]] || printf '%s\n' "$count" > "$wake_dir/adopt-count"
    [[ -z "$handed_off" ]] || : > "$wake_dir/handed-off"
    [[ -z "$backend" ]] || sed -i "s/^BACKEND=.*/BACKEND=$backend/" "$env"
    printf '%s\n' "$probe_rc" > "$K8S_WAKE_BIN/probe-rc"
    rm -f -- "$K8S_WAKE_BIN/probe-calls.log" "$K8S_WAKE_BIN/resume-calls.log" "$K8S_WAKE_BIN/rm-calls.log"
    FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
    ADOPT_TID="$tid" ADOPT_RID="$rid" ADOPT_WAKE_DIR="$wake_dir"
    ADOPT_BRANCH="$(env_val "$env" BRANCH)"
    ADOPT_RMS="$(adopt_rm_count)"
    ADOPT_FLAG="$( [[ -e "$PM_STATE_DIR/needs-operator/$tid" ]] && echo 1 || echo 0 )"
    ADOPT_HARVESTED="$( [[ -e "$PM_STATE_DIR/harvested/$rid" ]] && echo 1 || echo 0 )"
    ADOPT_PROBES="$(wc -l < "$K8S_WAKE_BIN/probe-calls.log" 2>/dev/null || echo 0)"
    ADOPT_RESUMES="$(wc -l < "$K8S_WAKE_BIN/resume-calls.log" 2>/dev/null || echo 0)"
    unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF
}

# How many `rm --branch` calls the stub saw since the last adopt_case reset.
adopt_rm_count() { cat -- "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null | grep -c '^rm --branch '; }

for adopt_probe_rc in 1 0; do
    adopt_case "probe exit $adopt_probe_rc" "$adopt_probe_rc" ""
    check "k8s adopt (probe $adopt_probe_rc): not flagged" 0 "$ADOPT_FLAG"
    check "k8s adopt (probe $adopt_probe_rc): not harvested" 0 "$ADOPT_HARVESTED"
    check "k8s adopt (probe $adopt_probe_rc): adopt-count is 1" 1 \
        "$(cat "$ADOPT_WAKE_DIR/adopt-count" 2>/dev/null)"
    check "k8s adopt (probe $adopt_probe_rc): the probe named the branch, --probe, --timeout 5" 1 \
        "$(grep -c -- '^wait --branch .* --probe --timeout 5$' "$K8S_WAKE_BIN/probe-calls.log")"
    check "k8s adopt (probe $adopt_probe_rc): the wake was launched with --adopt (resume ran)" 1 "$ADOPT_RESUMES"
    contains "k8s adopt (probe $adopt_probe_rc): pm adopt event" "$(cat "$work/once.out")" \
        "pm adopt thread=${ADOPT_TID:0:8} agent=karen run=$ADOPT_RID attempt=1"
    check "k8s adopt (probe $adopt_probe_rc): no retry scheduled" 0 \
        "$( [[ -e "$PM_STATE_DIR/retries/$ADOPT_TID/karen" ]] && echo 1 || echo 0 )"
    check "k8s adopt (probe $adopt_probe_rc): an adoptable seat's cluster objects are not removed" 0 "$ADOPT_RMS"
    check "k8s adopt (probe $adopt_probe_rc): ...nor marked for teardown" 0 \
        "$( [[ -e "$PM_STATE_DIR/k8s-dead-reap/$ADOPT_RID" ]] && echo 1 || echo 0 )"
done

adopt_case "probe exit 2" 2 ""
check "k8s adopt (probe 2): flagged as before" 1 "$ADOPT_FLAG"
contains "k8s adopt (probe 2): flag reason is the dead-wake one" \
    "$(cat "$PM_STATE_DIR/needs-operator/$ADOPT_TID")" "wake never produced summary.json"
check "k8s adopt (probe 2): harvested as before" 1 "$ADOPT_HARVESTED"
check "k8s adopt (probe 2): the seat was probed once" 1 "$ADOPT_PROBES"
check "k8s adopt (probe 2): nothing adopted" 0 "$ADOPT_RESUMES"
check "k8s adopt (probe 2): no adopt-count written" 0 \
    "$( [[ -e "$ADOPT_WAKE_DIR/adopt-count" ]] && echo 1 || echo 0 )"
contains "k8s adopt (probe 2): a retry was scheduled as before" \
    "$(cat "$PM_STATE_DIR/retries/$ADOPT_TID/karen" 2>/dev/null)" "STATE=pending"
check "k8s dead teardown (probe 2): the dead seat's cluster objects are removed by its branch" \
    "rm --branch $ADOPT_BRANCH" "$(grep '^rm --branch ' "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
contains "k8s dead teardown (probe 2): k8s-dead-reaped event names the run" "$(cat "$work/once.out")" \
    "pm k8s-dead-reaped run=$ADOPT_RID branch=$ADOPT_BRANCH"
check "k8s dead teardown (probe 2): the marker is consumed" 0 \
    "$( [[ -e "$PM_STATE_DIR/k8s-dead-reap/$ADOPT_RID" ]] && echo 1 || echo 0 )"
check "k8s dead teardown (probe 2): retention will not remove it again" 1 \
    "$( [[ -e "$PM_STATE_DIR/k8s-reaped/$ADOPT_RID" ]] && echo 1 || echo 0 )"
check "k8s dead teardown (probe 2): the wake dir stays as evidence" 1 \
    "$( [[ -d "$ADOPT_WAKE_DIR" ]] && echo 1 || echo 0 )"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
check "k8s dead teardown (probe 2): a later pass does not remove it again" 1 "$(adopt_rm_count)"

# The incident shape: the driver died mid-collect after writing
# .reap-pending, and the pod then exited Succeeded, so the probe says dead
# and no adopt ever comes to honour the mark.
adopt_reap_pending_case() {
    local mid tid env rid wake_dir k8s_run_dir
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
    mid="$(send_msg '@carol' '@karen' 'adopt topic: reap pending' 'first' 8)"
    tid="$(thread_of "$mid")"
    STUB_K8S_NO_REPLY=1 once
    env="$(latest_env_for_agent karen)"
    rid="$(basename "$env" .env)"
    wake_dir="$(env_val "$env" RUN_DIR)"
    new_root k8s_run_dir
    printf 'credentials\n' > "$k8s_run_dir/.reap-pending"
    printf '%s\n' "$k8s_run_dir" > "$wake_dir/k8s-run-dir"
    rm -f -- "$PM_STATE_DIR/harvested/$rid" "$wake_dir/summary.json" "$wake_dir/exit-code" \
        "$wake_dir/k8s-timeout" "$wake_dir/pid-identity"
    dead_pid_of > "$wake_dir/pid"
    printf '2\n' > "$K8S_WAKE_BIN/probe-rc"
    rm -f -- "$K8S_WAKE_BIN/rm-calls.log"
    FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
    check "k8s dead teardown (.reap-pending): removed by its branch" \
        "rm --branch $(env_val "$env" BRANCH)" "$(grep '^rm --branch ' "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
    contains "k8s dead teardown (.reap-pending): the harvest still records no-summary" \
        "$(cat "$PM_STATE_DIR/needs-operator/$tid" 2>/dev/null)" "wake never produced summary.json: $rid"
    check "k8s dead teardown (.reap-pending): harvested" 1 \
        "$( [[ -e "$PM_STATE_DIR/harvested/$rid" ]] && echo 1 || echo 0 )"
    unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF
}
adopt_reap_pending_case

# A teardown that fails never blocks the harvest, is logged naming the run,
# and is retried next pass until it succeeds.
printf '1\n' > "$K8S_WAKE_BIN/rm-rc"
adopt_case "teardown fails" 2 ""
rm -f -- "$K8S_WAKE_BIN/rm-rc"
check "k8s dead teardown (rm fails): harvested regardless" 1 "$ADOPT_HARVESTED"
check "k8s dead teardown (rm fails): flagged regardless" 1 "$ADOPT_FLAG"
contains "k8s dead teardown (rm fails): k8s-dead-reap-failed event names the run" "$(cat "$work/once.out")" \
    "pm k8s-dead-reap-failed run=$ADOPT_RID branch=$ADOPT_BRANCH rc=1"
check "k8s dead teardown (rm fails): the marker stays" 1 \
    "$( [[ -e "$PM_STATE_DIR/k8s-dead-reap/$ADOPT_RID" ]] && echo 1 || echo 0 )"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
check "k8s dead teardown (rm fails): retried next pass" 2 "$(adopt_rm_count)"
contains "k8s dead teardown (rm fails): ...which succeeds" "$(cat "$work/once.out")" \
    "pm k8s-dead-reaped run=$ADOPT_RID branch=$ADOPT_BRANCH"
check "k8s dead teardown (rm fails): ...and consumes the marker" 0 \
    "$( [[ -e "$PM_STATE_DIR/k8s-dead-reap/$ADOPT_RID" ]] && echo 1 || echo 0 )"

adopt_case "adoptions used up" 1 2
check "k8s adopt (count 2): flagged as before" 1 "$ADOPT_FLAG"
check "k8s adopt (count 2): harvested as before" 1 "$ADOPT_HARVESTED"
check "k8s adopt (count 2): the cluster is not even probed" 0 "$ADOPT_PROBES"
check "k8s adopt (count 2): nothing adopted" 0 "$ADOPT_RESUMES"
check "k8s adopt (count 2): adopt-count left at 2" 2 "$(cat "$ADOPT_WAKE_DIR/adopt-count")"
check "k8s dead teardown (count 2): the still-running Job is removed (stopped) by its branch" \
    "rm --branch $ADOPT_BRANCH" "$(grep '^rm --branch ' "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
contains "k8s dead teardown (count 2): k8s-dead-reaped event names the run" "$(cat "$work/once.out")" \
    "pm k8s-dead-reaped run=$ADOPT_RID branch=$ADOPT_BRANCH"

# A wake the previous postmaster handed off on a clean shutdown is adopted
# even with its adoptions used up, and spends none: a rollout is not a death.
adopt_case "handed off, adoptions used up" 1 2 "" handed-off
check "k8s adopt (handed off, count 2): not flagged" 0 "$ADOPT_FLAG"
check "k8s adopt (handed off, count 2): not harvested" 0 "$ADOPT_HARVESTED"
check "k8s adopt (handed off, count 2): adopted (resume ran)" 1 "$ADOPT_RESUMES"
check "k8s adopt (handed off, count 2): adopt-count left at 2" 2 "$(cat "$ADOPT_WAKE_DIR/adopt-count")"
check "k8s adopt (handed off, count 2): the marker is consumed" 0 \
    "$( [[ -e "$ADOPT_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
contains "k8s adopt (handed off, count 2): pm adopt event says handed-off" "$(cat "$work/once.out")" \
    "pm adopt thread=${ADOPT_TID:0:8} agent=karen run=$ADOPT_RID attempt=2 handed-off"
check "k8s adopt (handed off, count 2): nothing removed" 0 "$ADOPT_RMS"

adopt_case "handed off, first adoption" 1 "" "" handed-off
check "k8s adopt (handed off, first): adopted (resume ran)" 1 "$ADOPT_RESUMES"
check "k8s adopt (handed off, first): no adopt-count written" 0 \
    "$( [[ -e "$ADOPT_WAKE_DIR/adopt-count" ]] && echo 1 || echo 0 )"

# The marker never revives a seat the cluster says is gone.
adopt_case "handed off, pod gone" 2 "" "" handed-off
check "k8s adopt (handed off, probe 2): flagged as before" 1 "$ADOPT_FLAG"
check "k8s adopt (handed off, probe 2): nothing adopted" 0 "$ADOPT_RESUMES"

adopt_case "local wake" 1 "" local
check "k8s adopt (local backend): flagged as before" 1 "$ADOPT_FLAG"
check "k8s adopt (local backend): the cluster is not probed" 0 "$ADOPT_PROBES"
check "k8s adopt (local backend): nothing adopted" 0 "$ADOPT_RESUMES"
check "k8s adopt (local backend): no cluster teardown" 0 "$ADOPT_RMS"

# A failed adoption launch is a dead seat, and the flag says why.
adopt_launch_fail_case() {
    local mid tid env rid wake_dir save_detach="$FORK_SANDBOX_POSTMASTER_K8S_DETACH"
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    mid="$(send_msg '@carol' '@karen' 'adopt topic: launch fails' 'first' 8)"
    tid="$(thread_of "$mid")"
    STUB_K8S_NO_REPLY=1 once
    env="$(latest_env_for_agent karen)"
    rid="$(basename "$env" .env)"
    wake_dir="$(env_val "$env" RUN_DIR)"
    rm -f -- "$PM_STATE_DIR/harvested/$rid" "$wake_dir/summary.json" "$wake_dir/exit-code"
    dead_pid_of > "$wake_dir/pid"
    printf '1\n' > "$K8S_WAKE_BIN/probe-rc"
    rm -f -- "$K8S_WAKE_BIN/rm-calls.log"
    # A wrapper that cannot start a detached session (no tmux on PATH to
    # find): the non-inline path, with tmux absent from a minimal PATH.
    local fake_bin
    new_root fake_bin
    printf '#!/bin/sh\nexit 1\n' > "$fake_bin/tmux"
    chmod +x -- "$fake_bin/tmux"
    export FORK_SANDBOX_POSTMASTER_K8S_DETACH=
    PATH="$fake_bin:$PATH" FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
    export FORK_SANDBOX_POSTMASTER_K8S_DETACH="$save_detach"
    contains "k8s adopt (launch fails): flag names the adoption failure" \
        "$(cat "$PM_STATE_DIR/needs-operator/$tid" 2>/dev/null)" "adopting its still-live Job failed"
    check "k8s adopt (launch fails): harvested (dead as before)" 1 \
        "$( [[ -e "$PM_STATE_DIR/harvested/$rid" ]] && echo 1 || echo 0 )"
    check "k8s dead teardown (launch fails): the live Job nobody will adopt is removed" \
        "rm --branch $(env_val "$env" BRANCH)" "$(grep '^rm --branch ' "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
}
adopt_launch_fail_case

# ---- adoption: a probe that cannot reach the cluster (exit 4, or any code
# outside the probe's 0/1/2 contract) defers instead of declaring the seat
# dead, and only flags after 20 such passes ----
adopt_deferred_setup() {
    local mid
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
    mid="$(send_msg '@carol' '@karen' 'adopt topic: deferred' 'first' 8)"
    AD_TID="$(thread_of "$mid")"
    STUB_K8S_NO_REPLY=1 once
    AD_ENV="$(latest_env_for_agent karen)"
    AD_RID="$(basename "$AD_ENV" .env)"
    AD_WAKE_DIR="$(env_val "$AD_ENV" RUN_DIR)"
    rm -f -- "$PM_STATE_DIR/harvested/$AD_RID" "$AD_WAKE_DIR/summary.json" "$AD_WAKE_DIR/exit-code" \
        "$AD_WAKE_DIR/k8s-run-dir" "$AD_WAKE_DIR/k8s-timeout" "$AD_WAKE_DIR/pid-identity"
    dead_pid_of > "$AD_WAKE_DIR/pid"
    rm -f -- "$K8S_WAKE_BIN/probe-calls.log" "$K8S_WAKE_BIN/resume-calls.log" "$K8S_WAKE_BIN/rm-calls.log"
}
adopt_deferred_setup

printf '4\n' > "$K8S_WAKE_BIN/probe-rc"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
check "k8s adopt-deferred (probe 4): not flagged" 0 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$AD_TID" ]] && echo 1 || echo 0 )"
check "k8s adopt-deferred (probe 4): run still live (not harvested)" 0 \
    "$( [[ -e "$PM_STATE_DIR/harvested/$AD_RID" ]] && echo 1 || echo 0 )"
check "k8s adopt-deferred (probe 4): no adopt-count written" 0 \
    "$( [[ -e "$AD_WAKE_DIR/adopt-count" ]] && echo 1 || echo 0 )"
check "k8s adopt-deferred (probe 4): probe-fail-count is 1" 1 \
    "$(cat "$AD_WAKE_DIR/probe-fail-count" 2>/dev/null)"
check "k8s adopt-deferred (probe 4): nothing adopted" 0 \
    "$(wc -l < "$K8S_WAKE_BIN/resume-calls.log" 2>/dev/null || echo 0)"
check "k8s adopt-deferred (probe 4): no retry scheduled" 0 \
    "$( [[ -e "$PM_STATE_DIR/retries/$AD_TID/karen" ]] && echo 1 || echo 0 )"
check "k8s adopt-deferred (probe 4): nothing removed from the cluster" 0 \
    "$(adopt_rm_count)"
contains "k8s adopt-deferred (probe 4): pm adopt-deferred event" "$(cat "$work/once.out")" \
    "pm adopt-deferred thread=${AD_TID:0:8} agent=karen run=$AD_RID probe_rc=4"

for _ in $(seq 2 20); do
    FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
done
check "k8s adopt-deferred (20 passes): probe-fail-count is 20" 20 \
    "$(cat "$AD_WAKE_DIR/probe-fail-count" 2>/dev/null)"
check "k8s adopt-deferred (20 passes): flagged" 1 \
    "$( [[ -e "$PM_STATE_DIR/needs-operator/$AD_TID" ]] && echo 1 || echo 0 )"
contains "k8s adopt-deferred (20 passes): flag reason names the run" \
    "$(cat "$PM_STATE_DIR/needs-operator/$AD_TID" 2>/dev/null)" "cannot probe the cluster for $AD_RID"
check "k8s adopt-deferred (20 passes): flagged exactly once" 1 \
    "$(grep -c -- $'\tflag\t' "$PM_STATE_DIR/needs-operator-journal/$AD_TID" 2>/dev/null || echo 0)"
check "k8s adopt-deferred (20 passes): still not harvested (never declared dead)" 0 \
    "$( [[ -e "$PM_STATE_DIR/harvested/$AD_RID" ]] && echo 1 || echo 0 )"

# A 21st deferred pass keeps deferring and does not re-flag.
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
check "k8s adopt-deferred (21st pass): probe-fail-count is 21" 21 \
    "$(cat "$AD_WAKE_DIR/probe-fail-count" 2>/dev/null)"
check "k8s adopt-deferred (21st pass): still flagged exactly once" 1 \
    "$(grep -c -- $'\tflag\t' "$PM_STATE_DIR/needs-operator-journal/$AD_TID" 2>/dev/null || echo 0)"

# A subsequent determinate probe (exit 1) adopts, as if this were the
# first probe, and removes the probe-fail-count.
printf '1\n' > "$K8S_WAKE_BIN/probe-rc"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once
check "k8s adopt-deferred: a later determinate probe adopts" 1 \
    "$(cat "$AD_WAKE_DIR/adopt-count" 2>/dev/null)"
check "k8s adopt-deferred: probe-fail-count is removed on adoption" 0 \
    "$( [[ -e "$AD_WAKE_DIR/probe-fail-count" ]] && echo 1 || echo 0 )"
check "k8s adopt-deferred: still not harvested" 0 \
    "$( [[ -e "$PM_STATE_DIR/harvested/$AD_RID" ]] && echo 1 || echo 0 )"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ---- shutdown drain: SIGTERM waits for wakes still submitting and hooks
# still running, so a restart never cuts one off ----
# A real spawn builds the run env and wake dir; the wake is then made to look
# live and mid-submit: no summary.json, a live pid, and a k8s run.env that
# expects an inputs push but has not recorded it. A hook record with a live
# pid and no exit file stands in for a running hook, unless $1 is "nohook".
drain_setup() {
    local mid env rid k8s_run with_hook=1
    [[ "${1:-}" != nohook ]] || with_hook=0
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    mid="$(send_msg '@carol' '@karen' 'drain topic' 'first' 8)"
    STUB_K8S_NO_REPLY=1 once
    env="$(latest_env_for_agent karen)"
    rid="$(basename "$env" .env)"
    DR_WAKE_DIR="$(env_val "$env" RUN_DIR)"
    rm -f -- "$PM_STATE_DIR/harvested/$rid" "$DR_WAKE_DIR/summary.json" "$DR_WAKE_DIR/exit-code" \
        "$DR_WAKE_DIR/pid-identity"
    sleep 300 & DR_WAKE_PID=$!
    printf '%s\n' "$DR_WAKE_PID" > "$DR_WAKE_DIR/pid"
    new_root k8s_run
    printf 'INPUTS_PUSH_EXPECTED=true\n' > "$k8s_run/run.env"
    printf '%s' "$k8s_run" > "$DR_WAKE_DIR/k8s-run-dir"
    DR_K8S_ENV="$k8s_run/run.env"
    DR_LOG="$work/drain-deliver.log"
    (( with_hook )) || return 0
    DR_HOOK_REC="$PM_STATE_DIR/hooks/run/drain-hook"
    mkdir -p -- "$DR_HOOK_REC"
    printf 'on-harvest\n' > "$DR_HOOK_REC/event"
    sleep 300 & DR_HOOK_PID=$!
    printf '%s\n' "$DR_HOOK_PID" > "$DR_HOOK_REC/pid"
}

# Starts the loop (pass interval $DR_INTERVAL, default 1), waits for its
# first pass, then sends SIGTERM.
drain_start_and_term() {
    FORK_SANDBOX_POSTMASTER_INTERVAL="${DR_INTERVAL:-1}" FORK_SANDBOX_POSTMASTER_DRAIN_POLL=0.2 \
        "$postmaster" deliver --project "$PROJECT_DIR" > "$DR_LOG" 2>&1 &
    DR_PID=$!
    for _ in $(seq 1 100); do [[ -e "$PM_STATE_DIR/project" ]] && break; sleep 0.1; done
    sleep 1
    kill -TERM "$DR_PID"
}

# 1 while $DR_PID still runs after up to $1 tenths of a second, else 0.
drain_alive_after() {
    local _
    for _ in $(seq 1 "$1"); do kill -0 "$DR_PID" 2>/dev/null || { echo 0; return; }; sleep 0.1; done
    kill -0 "$DR_PID" 2>/dev/null && echo 1 || echo 0
}

drain_setup
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 drain_start_and_term
check "drain: SIGTERM with a wake submitting and a hook running does not exit" 1 \
    "$(drain_alive_after 20)"
contains "drain: pm drain event counts both" "$(cat "$DR_LOG")" "pm drain busy=2 timeout=60s"
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
check "drain: still waiting on the running hook once the wake has its inputs" 1 \
    "$(drain_alive_after 10)"
kill "$DR_HOOK_PID" 2>/dev/null; wait "$DR_HOOK_PID" 2>/dev/null
check "drain: exits once nothing is submitting or running" 0 "$(drain_alive_after 50)"
dr_rc=0; wait "$DR_PID" || dr_rc=$?
check "drain: exit status 0" 0 "$dr_rc"
contains "drain: pm drain done event, nothing cut off" "$(cat "$DR_LOG")" "pm drain done busy=0"
check "drain: the wake was not harvested (the next postmaster adopts it)" 0 \
    "$( [[ -n "$(ls -A "$PM_STATE_DIR/harvested" 2>/dev/null)" ]] && echo 1 || echo 0 )"
check "drain: the live wake past submit is marked handed-off" 1 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
contains "drain: pm handed-off event" "$(cat "$DR_LOG")" "pm handed-off thread="
kill "$DR_WAKE_PID" 2>/dev/null; wait "$DR_WAKE_PID" 2>/dev/null

# The bound: a wake that never finishes submitting is cut off at the timeout.
drain_setup nohook
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=1 drain_start_and_term
check "drain timeout: exits once the bound is spent" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
contains "drain timeout: pm drain done names what was cut off" "$(cat "$DR_LOG")" "pm drain done busy=1"
check "drain timeout: a wake cut off mid-submit is not marked handed-off" 0 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
kill "$DR_WAKE_PID" 2>/dev/null; wait "$DR_WAKE_PID" 2>/dev/null

# Kills the wake and hook drain_setup left running.
drain_cleanup() {
    kill "$DR_WAKE_PID" "${DR_HOOK_PID:-}" 2>/dev/null
    wait "$DR_WAKE_PID" "${DR_HOOK_PID:-}" 2>/dev/null
    DR_HOOK_PID=""
}

# Runs "$@" with the postmaster sourced, as the drain would (events on).
dr_call() {
    (
        # shellcheck disable=SC1090
        source "$postmaster"
        # shellcheck disable=SC2034  # read by the sourced functions
        PM_EVENTS_ENABLED=1
        "$@"
    )
}

# Hand off first: the kubelet SIGKILLs pid 1 once the grace period is spent,
# and a drain still waiting then must already have marked every live wake
# past submit, or the next postmaster spends an adoption on each.
drain_setup
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 drain_start_and_term
check "drain mark-first: still waiting on the running hook" 1 "$(drain_alive_after 20)"
kill -KILL "$DR_PID" 2>/dev/null; wait "$DR_PID" 2>/dev/null
check "drain mark-first: SIGKILL mid-wait leaves handed-off on the live wake past submit" 1 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
contains "drain mark-first: pm handed-off event before the wait ended" "$(cat "$DR_LOG")" \
    "pm handed-off thread="
drain_cleanup

# A wake that finishes submitting during the drain is marked when the wait
# ends.
drain_setup
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 drain_start_and_term
check "drain re-mark: waiting on the submitting wake" 1 "$(drain_alive_after 20)"
check "drain re-mark: a wake still submitting is not marked at drain start" 0 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
kill "$DR_HOOK_PID" 2>/dev/null; wait "$DR_HOOK_PID" 2>/dev/null
check "drain re-mark: exits once nothing is busy" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
check "drain re-mark: the wake that finished submitting mid-drain is marked" 1 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
check "drain re-mark: ...with one handed-off event" 1 "$(grep -c '^pm handed-off thread=' "$DR_LOG")"
drain_cleanup

# The second hypothesis behind a missing mark: a wake that was itself
# adopted (pid file dropped by pm_try_adopt, rewritten by the adopting
# wrapper, no k8s-run-dir until it finishes) must still read as live and
# past submit at the next drain.
adopt_drain_case() {
    local mid env rid wake_dir k8s_run_dir bg _
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    mid="$(send_msg '@carol' '@karen' 'drain topic: adopted' 'first' 8)"
    STUB_K8S_NO_REPLY=1 once
    env="$(latest_env_for_agent karen)"
    rid="$(basename "$env" .env)"
    wake_dir="$(env_val "$env" RUN_DIR)"
    k8s_run_dir="$(sed -n 's/^  run dir:  *//p' "$wake_dir/launch.log" | head -n1)"
    printf 'INPUTS_PUSH_EXPECTED=true\nINPUTS_PUSH_COMPLETE=true\n' > "$k8s_run_dir/run.env"
    rm -f -- "$PM_STATE_DIR/harvested/$rid" "$wake_dir/summary.json" "$wake_dir/exit-code" \
        "$wake_dir/k8s-run-dir" "$wake_dir/k8s-timeout" "$wake_dir/pid-identity"
    dead_pid_of > "$wake_dir/pid"
    printf '1\n' > "$K8S_WAKE_BIN/probe-rc"
    rm -f -- "$K8S_WAKE_BIN/resume-calls.log"
    : > "$K8S_WAKE_BIN/resume-hold"
    FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 once &
    bg=$!
    for _ in $(seq 1 100); do [[ -s "$K8S_WAKE_BIN/resume-calls.log" ]] && break; sleep 0.1; done
    check "drain adopted: the adopting wrapper is running" 1 \
        "$(wc -l < "$K8S_WAKE_BIN/resume-calls.log" 2>/dev/null || echo 0)"
    check "drain adopted: one adoption spent" 1 "$(cat "$wake_dir/adopt-count" 2>/dev/null)"
    FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=5 dr_call pm_drain > "$work/adopt-drain.out" 2>&1
    check "drain adopted: the adopted live wake is marked handed-off at the next drain" 1 \
        "$( [[ -e "$wake_dir/handed-off" ]] && echo 1 || echo 0 )"
    contains "drain adopted: pm handed-off event names the run" "$(cat "$work/adopt-drain.out")" \
        "agent=karen run=$rid"
    rm -f -- "$K8S_WAKE_BIN/resume-hold" "$K8S_WAKE_BIN/probe-rc"
    wait "$bg" 2>/dev/null
}
adopt_drain_case

# The drain's bound counts from SIGTERM, not from the drain's own start, so
# the pass in progress when it arrived comes out of the same budget.
drain_setup nohook
dr_start=$(( $(date +%s) - 4 ))
SECONDS=0
PM_TERM_AT="$dr_start" FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=5 FORK_SANDBOX_POSTMASTER_DRAIN_POLL=0.2 \
    dr_call pm_drain > "$work/term-drain.out" 2>&1
check "drain from SIGTERM: 4s already spent of a 5s bound leaves at most ~1s to wait" 1 \
    "$(( SECONDS <= 2 ))"
contains "drain from SIGTERM: still cut off the submitting wake" "$(cat "$work/term-drain.out")" \
    "pm drain done busy=1"
drain_cleanup

# ...and SIGTERM during the loop's sleep between passes is acted on at once,
# not when the sleep would have ended.
drain_setup nohook
DR_INTERVAL=30 FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=2 drain_start_and_term
check "drain from SIGTERM: exits within the bound though the pass interval is longer" 0 \
    "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
drain_cleanup

# A long-lived store holds thousands of run records, nearly all harvested;
# the drain walks them on every poll, so that walk must stay cheap.
drain_setup nohook
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
for dr_i in $(seq 1 5000); do
    : > "$PM_STATE_DIR/runs/old-$dr_i.env"
    : > "$PM_STATE_DIR/harvested/old-$dr_i"
done
SECONDS=0
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=0 dr_call pm_drain > "$work/many-drain.out" 2>&1
check "drain over 5000 harvested records: done within 2s" 1 "$(( SECONDS <= 2 ))"
check "drain over 5000 harvested records: the live wake is still marked" 1 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
drain_cleanup

# A wake mid-collect -- its agent finished, its wrapper fetching the branch,
# writing the summary and reaping (cmd_collect's .reap-pending in the k8s
# run dir) -- keeps the drain busy until it is done, and is never marked:
# it finishes within the drain, and a rollout there would lose its result.
drain_setup nohook
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
printf 'credentials\n' > "${DR_K8S_ENV%/run.env}/.reap-pending"
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 drain_start_and_term
check "drain collect: a wake mid-collect keeps the drain busy" 1 "$(drain_alive_after 20)"
contains "drain collect: pm drain event counts it" "$(cat "$DR_LOG")" "pm drain busy=1 timeout=60s"
check "drain collect: a wake mid-collect is not marked handed-off" 0 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
# Reaped, exit-code written; the wrapper has yet to copy summary.json.
rm -f -- "${DR_K8S_ENV%/run.env}/.reap-pending"
printf '0\n' > "${DR_K8S_ENV%/run.env}/exit-code"
check "drain collect: still busy after the reap, until the wake's summary.json" 1 \
    "$(drain_alive_after 10)"
printf '{"exit_code": 0}' > "$DR_WAKE_DIR/summary.json"
kill "$DR_WAKE_PID" 2>/dev/null; wait "$DR_WAKE_PID" 2>/dev/null
check "drain collect: exits once the collect is done" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
contains "drain collect: nothing cut off" "$(cat "$DR_LOG")" "pm drain done busy=0"
check "drain collect: the collected wake was never marked" 0 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
drain_cleanup

# Cut off at the timeout, a wake mid-collect is still not marked: the
# dead-seat path takes it from there.
drain_setup nohook
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
printf 'full\n' > "${DR_K8S_ENV%/run.env}/.reap-pending"
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=1 drain_start_and_term
check "drain collect timeout: exits once the bound is spent" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
contains "drain collect timeout: pm drain done names it" "$(cat "$DR_LOG")" "pm drain done busy=1"
check "drain collect timeout: the wake cut off mid-collect is not marked" 0 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
drain_cleanup

# SIGTERM during a teardown stage cuts it short: the rm in flight is
# stopped and the stage's remaining runs are left for the next postmaster,
# so the drain's marks land at once instead of after up to five
# black-holed rm calls (each 60s+). $1 is "dead-reap" (markers) or
# "retention" (runs past the window).
drain_teardown_case() {
    local kind="$1" i rid
    drain_setup nohook
    printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
    mkdir -p -- "$PM_STATE_DIR/k8s-dead-reap"
    for i in 1 2 3; do
        rid="9999999999-teardown-$i"
        printf 'AGENT=tests\nBACKEND=k8s\nBRANCH=sbx-mail-0123abcd-tests-%s\nRUN_DIR=%s\n' \
            "$i" "$work/no-such-$rid" > "$PM_STATE_DIR/runs/$rid.env"
        : > "$PM_STATE_DIR/harvested/$rid"
        if [[ "$kind" == dead-reap ]]; then
            : > "$PM_STATE_DIR/k8s-dead-reap/$rid"
        else
            touch -d "@$(( $(date +%s) - 4 * 86400 ))" "$PM_STATE_DIR/harvested/$rid"
        fi
    done
    rm -f -- "$K8S_WAKE_BIN/rm-calls.log"
    : > "$K8S_WAKE_BIN/rm-hold"
    FORK_SANDBOX_POSTMASTER_INTERVAL=1 FORK_SANDBOX_POSTMASTER_DRAIN_POLL=0.2 \
        FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY=0 \
        "$postmaster" deliver --project "$PROJECT_DIR" > "$DR_LOG" 2>&1 &
    DR_PID=$!
    for _ in $(seq 1 100); do [[ -s "$K8S_WAKE_BIN/rm-calls.log" ]] && break; sleep 0.1; done
    check "drain mid-$kind: an rm is in flight when SIGTERM lands" 1 \
        "$(wc -l < "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null || echo 0)"
    kill -TERM "$DR_PID"
    check "drain mid-$kind: exits promptly despite the black-holed rm" 0 "$(drain_alive_after 50)"
    wait "$DR_PID" 2>/dev/null || true
    check "drain mid-$kind: the live wake past submit is marked handed-off" 1 \
        "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
    check "drain mid-$kind: no further rm after the signal" 1 \
        "$(wc -l < "$K8S_WAKE_BIN/rm-calls.log")"
    check "drain mid-$kind: nothing recorded as reaped" 0 \
        "$(find "$PM_STATE_DIR/k8s-reaped" -type f 2>/dev/null | wc -l)"
    if [[ "$kind" == dead-reap ]]; then
        check "drain mid-dead-reap: every marker stays for the next postmaster" 3 \
            "$(find "$PM_STATE_DIR/k8s-dead-reap" -type f | wc -l)"
    fi
    rm -f -- "$K8S_WAKE_BIN/rm-hold"
    drain_cleanup
}
FORK_SANDBOX_POSTMASTER_K8S_RETENTION=0 drain_teardown_case dead-reap
FORK_SANDBOX_POSTMASTER_K8S_RETENTION=86400 drain_teardown_case retention

# A shutdown signal also ends the pass in progress at its next stage: a
# signal landing in the dead-reap stage must not let retention (the stage
# after it) start, and the drain then proceeds. Retention writes its stamp
# before it looks at a single run, so a missing stamp means it never ran;
# nothing before this pass had run it either.
drain_setup nohook
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
mkdir -p -- "$PM_STATE_DIR/k8s-dead-reap"
dr_stage_rid="9999999999-stage-1"
printf 'AGENT=tests\nBACKEND=k8s\nBRANCH=sbx-mail-0123abcd-tests-1\nRUN_DIR=%s\n' \
    "$work/no-such-$dr_stage_rid" > "$PM_STATE_DIR/runs/$dr_stage_rid.env"
: > "$PM_STATE_DIR/harvested/$dr_stage_rid"
: > "$PM_STATE_DIR/k8s-dead-reap/$dr_stage_rid"
rm -f -- "$K8S_WAKE_BIN/rm-calls.log" "$PM_STATE_DIR/k8s-retention-last"
: > "$K8S_WAKE_BIN/rm-hold"
FORK_SANDBOX_POSTMASTER_INTERVAL=1 FORK_SANDBOX_POSTMASTER_DRAIN_POLL=0.2 \
    FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 FORK_SANDBOX_POSTMASTER_K8S_RETENTION=86400 \
    FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY=0 \
    "$postmaster" deliver --project "$PROJECT_DIR" > "$DR_LOG" 2>&1 &
DR_PID=$!
for _ in $(seq 1 100); do [[ -s "$K8S_WAKE_BIN/rm-calls.log" ]] && break; sleep 0.1; done
check "drain mid-pass: the pass is held in the dead-reap stage when SIGTERM lands" 1 \
    "$(wc -l < "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null || echo 0)"
kill -TERM "$DR_PID"
check "drain mid-pass: exits promptly" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
check "drain mid-pass: the retention stage after it never ran" 0 \
    "$( [[ -e "$PM_STATE_DIR/k8s-retention-last" ]] && echo 1 || echo 0 )"
contains "drain mid-pass: the drain then proceeds" "$(cat "$DR_LOG")" "pm drain busy="
check "drain mid-pass: ...and marks the live wake handed-off" 1 \
    "$( [[ -e "$DR_WAKE_DIR/handed-off" ]] && echo 1 || echo 0 )"
rm -f -- "$K8S_WAKE_BIN/rm-hold"
drain_cleanup

# The drain's events also go to $STATE/drain-record on the store, which
# outlives the pod's stdout: start, each handed-off, done.
drain_setup
printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$DR_K8S_ENV"
dr_rec="$PM_STATE_DIR/drain-record"
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=1 FORK_SANDBOX_POSTMASTER_DRAIN_POLL=0.2 \
    dr_call pm_drain > /dev/null 2>&1
contains "drain record: start with its busy count" "$(cat "$dr_rec" 2>/dev/null)" "Z drain busy=1 timeout=1s"
contains "drain record: the handed-off wake" "$(cat "$dr_rec" 2>/dev/null)" \
    "Z handed-off thread="
contains "drain record: done with the time waited" "$(cat "$dr_rec" 2>/dev/null)" "Z drain done busy=1 waited="
for _ in 1 2 3 4 5 6 7; do
    FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=0 dr_call pm_drain > /dev/null 2>&1
done
check "drain record: bounded to the last 5 drains" 5 "$(grep -c 'Z drain busy=' "$dr_rec" 2>/dev/null)"
check "drain record: ...each with its done line" 5 "$(grep -c 'Z drain done busy=' "$dr_rec" 2>/dev/null)"
# A drain SIGKILLed mid-wait leaves its start and marks but no done line,
# and the next postmaster reports that drain at startup.
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=60 drain_start_and_term
check "drain record: the drain is waiting on the hook" 1 "$(drain_alive_after 20)"
kill -KILL "$DR_PID" 2>/dev/null; wait "$DR_PID" 2>/dev/null
check "drain record: the killed drain left its start" 1 \
    "$(tail -n1 "$dr_rec" | grep -c 'Z drain busy=1 timeout=60s')"
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=0 drain_start_and_term
check "drain record: the next postmaster exits" 0 "$(drain_alive_after 50)"
wait "$DR_PID" 2>/dev/null || true
contains "drain record: startup logs the last drain" "$(cat "$DR_LOG")" \
    "Z drain busy=1 timeout=60s"
contains "drain record: ...as a last-drain event" "$(cat "$DR_LOG")" "pm last-drain "
contains "drain record: ...and says it never finished" "$(cat "$DR_LOG")" "pm last-drain-unfinished"
check "drain record: only the last drain is logged" 1 "$(grep -c '^pm last-drain .* drain busy=' "$DR_LOG")"
drain_cleanup

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=soon refuses \
    "drain: a non-numeric DRAIN_TIMEOUT refuses deliver" \
    "$postmaster" deliver --project "$PROJECT_DIR" --once

# ---- cluster mode: deliver --cluster ----

# The suite's shared fleet holds local seats, which a cluster postmaster
# cannot run: startup refuses before anything is routed or spawned.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
: > "$STUB_ARGV_LOG"
send_msg '@carol' '@karen' 'cluster refusal topic' 'hello' 8 >/dev/null
cl_rc=0
"$postmaster" deliver --project "$PROJECT_DIR" --cluster --once \
    >"$work/cl.out" 2>"$work/cl.err" || cl_rc=$?
check "cluster: deliver --cluster --once refuses a fleet with local seats" 1 "$cl_rc"
contains "cluster: the refusal names the reason" "$(cat "$work/cl.err")" \
    "a cluster postmaster cannot run local seats (they need bwrap)"
check "cluster: nothing was spawned" 0 "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"
check "cluster: nothing was routed" 0 \
    "$(find "$PM_STATE_DIR/routed" -type f 2>/dev/null | wc -l)"
cl_rc=0
"$postmaster" deliver --project "$PROJECT_DIR" --once >/dev/null 2>&1 || cl_rc=$?
check "cluster: the same fleet delivers without --cluster" 0 "$cl_rc"

# An all-pi k8s fleet: a spawned wake (and an adopted one) is launched
# under setsid, and tmux is never touched.
cl_fleet_dir=""; new_root cl_fleet_dir
cl_personas=""; new_root cl_personas
cp -- "$FORK_SANDBOX_PERSONAS_DIR/kim.md" "$cl_personas/kim.md"
cat > "$cl_fleet_dir/fleet.yaml" <<'EOF'
agents:
  kim:
    harness: pi
    model: vendor/kimmodel
    backend: k8s
EOF
cl_bin=""; new_root cl_bin
cat > "$cl_bin/setsid" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cl_bin/setsid-argv.log"
exit 0
STUB
cat > "$cl_bin/tmux" <<STUB
#!/usr/bin/env bash
printf 'called\n' >> "$cl_bin/tmux-called.log"
exit 1
STUB
chmod +x -- "$cl_bin/setsid" "$cl_bin/tmux"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
send_msg '@carol' '@kim' 'cluster setsid topic' 'hello' 8 >/dev/null
cl_pass() {
    env -u FORK_SANDBOX_POSTMASTER_K8S_DETACH \
        FORK_SANDBOX_FLEET_FILE="$cl_fleet_dir/fleet.yaml" \
        FORK_SANDBOX_PERSONAS_DIR="$cl_personas" \
        PATH="$cl_bin:$PATH" \
        "$postmaster" deliver --project "$PROJECT_DIR" --cluster --once \
        >"$work/cl.out" 2>"$work/cl.err"
}
cl_pass
cl_rc=$?
check "cluster: an all-pi k8s fleet starts" 0 "$cl_rc"
check "cluster: the k8s wake was launched with setsid" 1 \
    "$(grep -c -- 'run.sh$' "$cl_bin/setsid-argv.log" 2>/dev/null)"
contains "cluster: setsid detaches with --fork" "$(cat "$cl_bin/setsid-argv.log")" "--fork"
check "cluster: tmux is never called" 0 "$( [[ -e "$cl_bin/tmux-called.log" ]] && echo 1 || echo 0 )"
cl_env="$(latest_env_for_agent kim)"
cl_wake_dir="$(env_val "$cl_env" RUN_DIR)"
check "cluster: wake.out is the setsid output target" 1 "$( [[ -e "$cl_wake_dir/wake.out" ]] && echo 1 || echo 0 )"

# The setsid stub never ran the wake, so its pid never appeared: with no
# grace left it reads as a dead wake, whose Job the probe finds running.
printf '1\n' > "$K8S_WAKE_BIN/probe-rc"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 cl_pass
check "cluster: the adoption launch also used setsid" 2 \
    "$(grep -c -- 'run.sh$' "$cl_bin/setsid-argv.log" 2>/dev/null)"
contains "cluster: the adoption run.sh execs --adopt" "$(cat "$cl_wake_dir/run.sh")" "--adopt"
check "cluster: adoption never touched tmux" 0 "$( [[ -e "$cl_bin/tmux-called.log" ]] && echo 1 || echo 0 )"
contains "cluster: pm adopt event" "$(cat "$work/cl.out")" "pm adopt thread="

# A run record can be rewritten by the mail API container (it writes under
# .postmaster), so a cluster adoption only execs a wake dir this postmaster
# made: a RUN_DIR pointed anywhere else is refused, never launched.
cl_tid2="$(send_msg '@carol' '@kim' 'cluster planted run dir topic' 'hello' 8)"
cl_pass
# By thread, not latest_env_for_agent: its one-second mtime can tie with the
# first thread's run, whose wake dir already carries an adopt-count.
cl_env2="$(grep -l -- "^THREAD=$cl_tid2\$" "$PM_STATE_DIR/runs"/*.env | head -n 1)"
cl_rid2="$(basename "$cl_env2" .env)"
cl_decoy=""; new_root cl_decoy
cp -a -- "$(env_val "$cl_env2" RUN_DIR)/." "$cl_decoy/"
sed -i "s|^RUN_DIR=.*|RUN_DIR=$cl_decoy|" "$cl_env2"
dead_pid_of > "$cl_decoy/pid"
rm -f -- "$cl_decoy/summary.json" "$cl_decoy/exit-code" "$cl_decoy/pid-identity"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 cl_pass
check "cluster: a RUN_DIR outside the wake root is never launched" 0 \
    "$(grep -cF -- "$cl_decoy" "$cl_bin/setsid-argv.log" 2>/dev/null)"
check "cluster: the refused adoption wrote no adopt-count" 0 \
    "$( [[ -e "$cl_decoy/adopt-count" ]] && echo 1 || echo 0 )"
contains "cluster: pm adopt-refused event" "$(cat "$work/cl.out")" "pm adopt-refused thread="
contains "cluster: the refused run is named" "$(cat "$work/cl.out")" "run=$cl_rid2"
check "cluster: a refused adoption's planted RUN_DIR gets no teardown" 0 \
    "$(cat -- "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null | grep -cF -- "rm --branch $(env_val "$cl_env2" BRANCH)")"
contains "cluster: ...the marker is refused, naming the run" "$(cat "$work/cl.out")" \
    "pm k8s-dead-reap-refused run=$cl_rid2"

# Run records and markers are writable from the mail API container, and
# the dead-seat teardown's `rm --branch` probes nothing: a forged record
# naming another seat's branch must never stop that seat's Job, whether
# its RUN_DIR is missing or is one of this postmaster's own wake dirs.
cl_victim_branch="$(env_val "$cl_env" BRANCH)"
rm -f -- "$K8S_WAKE_BIN/rm-calls.log"
printf 'AGENT=kim\nTHREAD=%s\nBACKEND=k8s\nBRANCH=%s\nRUN_DIR=%s\n' \
    "$cl_tid2" "$cl_victim_branch" "$FORK_SANDBOX_POSTMASTER_K8S_WAKE_ROOT/pm-k8s-wake.gone" \
    > "$PM_STATE_DIR/runs/9999999999-forged-1.env"
cl_other_dir=""; cl_other_dir="$(mktemp -d "$FORK_SANDBOX_POSTMASTER_K8S_WAKE_ROOT/pm-k8s-wake.XXXXXX")"
printf '%s\0' launcher --branch sbx-mail-0123abcd-other-1 > "$cl_other_dir/fs-argv"
printf 'AGENT=kim\nTHREAD=%s\nBACKEND=k8s\nBRANCH=%s\nRUN_DIR=%s\n' \
    "$cl_tid2" "$cl_victim_branch" "$cl_other_dir" > "$PM_STATE_DIR/runs/9999999999-forged-2.env"
mkdir -p -- "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/k8s-dead-reap"
: > "$PM_STATE_DIR/harvested/9999999999-forged-2"
: > "$PM_STATE_DIR/k8s-dead-reap/9999999999-forged-2"
cl_pass
check "cluster: a forged dead run never removes another seat's branch" 0 \
    "$(cat -- "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null | grep -cF -- "rm --branch $cl_victim_branch")"
contains "cluster: ...a vanished RUN_DIR is refused" "$(cat "$work/cl.out")" \
    "pm k8s-dead-reap-refused run=9999999999-forged-1 branch=$cl_victim_branch"
contains "cluster: ...a wake dir spawned with another branch is refused" "$(cat "$work/cl.out")" \
    "pm k8s-dead-reap-refused run=9999999999-forged-2 branch=$cl_victim_branch"

# The real seat, once declared dead, is still torn down on a cluster: its
# wake dir is ours and was spawned with its record's branch.
dead_pid_of > "$cl_wake_dir/pid"
rm -f -- "$cl_wake_dir/summary.json" "$cl_wake_dir/exit-code" "$cl_wake_dir/pid-identity"
printf '2\n' > "$K8S_WAKE_BIN/probe-rc"
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 cl_pass
check "cluster: a dead seat's own wake dir still gets its teardown" \
    "rm --branch $cl_victim_branch" "$(grep '^rm --branch ' "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null)"
printf '1\n' > "$K8S_WAKE_BIN/probe-rc"

# ---- cluster mode: the operator list carries rule-1 authority ----

# Under --cluster only a From on $FORK_SANDBOX_OPERATORS (default
# @operator) clears a flag and resets a thread's budget; any other
# non-fleet sender routes like fleet mail. The laptop keeps giving every
# non-fleet sender that authority. cl_fleet_dir/cl_personas/cl_bin are the
# all-pi k8s fleet built above.
op_pass() {
    env -u FORK_SANDBOX_POSTMASTER_K8S_DETACH \
        FORK_SANDBOX_FLEET_FILE="$cl_fleet_dir/fleet.yaml" \
        FORK_SANDBOX_PERSONAS_DIR="$cl_personas" \
        PATH="$cl_bin:$PATH" \
        "$postmaster" deliver --project "$PROJECT_DIR" "$@" --once \
        >"$work/op.out" 2>"$work/op.err"
}
# A thread with one routed root message from @operator to @kim (so a
# reply-all's To resolves, never tripping the unresolvable-To flag), a
# flag and a spent budget; sets op_tid/op_root/op_short.
op_fixture() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    op_root="$(send_msg '@operator' '@kim' 'operator list topic' 'first' 8)"
    op_tid="$(thread_of "$op_root")"
    op_short="${op_tid:0:8}"
    op_pass --cluster
    "$postmaster" flag "$op_tid" "stale reason" >/dev/null 2>&1
    printf 'stale-1\nstale-2\nstale-3\n' > "$PM_STATE_DIR/spawns/$op_tid"
}
op_flag_present() { [[ -e "$PM_STATE_DIR/needs-operator/$op_tid" ]] && echo 1 || echo 0; }

op_fixture
reply_msg '@ci-kickoff' "$op_root" 'ci posts into a flagged thread' >/dev/null
op_pass --cluster
check "cluster operators: a non-operator non-fleet reply leaves the flag" 1 "$(op_flag_present)"
check "cluster operators: it does not reset the spawn budget" 3 \
    "$(grep -c -- '^stale-' "$PM_STATE_DIR/spawns/$op_tid")"
contains "cluster operators: it emits external-mail" "$(cat "$work/op.out")" \
    "pm external-mail thread=$op_short"
not_contains "cluster operators: the event does not name the sender" "$(cat "$work/op.out")" "ci-kickoff"

op_fixture
reply_msg '@operator' "$op_root" 'operator re-arms the thread' >/dev/null
op_pass --cluster
check "cluster operators: @operator (default list) clears the flag" 0 "$(op_flag_present)"
check "cluster operators: @operator resets the budget" 0 "$(spawn_count_of "$op_tid")"
not_contains "cluster operators: @operator emits no external-mail" "$(cat "$work/op.out")" "external-mail"

op_fixture
reply_msg '@alice' "$op_root" 'alice is on the list' >/dev/null
FORK_SANDBOX_OPERATORS=@alice,@operator op_pass --cluster
check "cluster operators: a listed name (@alice) clears the flag" 0 "$(op_flag_present)"
op_fixture
reply_msg '@bob' "$op_root" 'bob is not on the list' >/dev/null
FORK_SANDBOX_OPERATORS=@alice,@operator op_pass --cluster
check "cluster operators: an unlisted name (@bob) does not clear it" 1 "$(op_flag_present)"

# A sender with no authority still wakes the seat it addresses.
op_fixture
"$postmaster" unflag "$op_tid" >/dev/null 2>&1
printf 'one\n' > "$PM_STATE_DIR/spawns/$op_tid"
rm -f -- "$PM_STATE_DIR/runs"/*.env
send_msg '@ci-kickoff' '@kim' 'fresh ci thread' 'wake kim' 8 >/dev/null
fresh_before="$(grep -c -- 'run.sh$' "$cl_bin/setsid-argv.log")"
op_pass --cluster
check "cluster operators: a non-operator sender's mail still wakes the addressed seat" 1 \
    "$(( $(grep -c -- 'run.sh$' "$cl_bin/setsid-argv.log") - fresh_before ))"

for op_bad in '@a,,@b' 'Bad' '@a,' ',@a' '@a, @b'; do
    op_rc=0
    FORK_SANDBOX_OPERATORS="$op_bad" op_pass --cluster || op_rc=$?
    check "cluster operators: FORK_SANDBOX_OPERATORS='$op_bad' exits 2" 2 "$op_rc"
    check "cluster operators: '$op_bad' refusal is one line" 1 "$(wc -l < "$work/op.err")"
done
FORK_SANDBOX_OPERATORS='@a,,@b' op_pass --cluster
contains "cluster operators: the empty element is named" "$(cat "$work/op.err")" "element ''"
FORK_SANDBOX_OPERATORS='Bad' op_pass --cluster
contains "cluster operators: a bad name is named" "$(cat "$work/op.err")" "'Bad'"
op_rc=0
FORK_SANDBOX_OPERATORS='@operator,@kim' op_pass --cluster || op_rc=$?
check "cluster operators: a list naming a fleet agent exits 2" 2 "$op_rc"
contains "cluster operators: the fleet agent is named" "$(cat "$work/op.err")" "'@kim'"
contains "cluster operators: the refusal says why" "$(cat "$work/op.err")" "must not be a fleet agent"

# The laptop ignores the variable: every non-fleet sender clears the flag.
op_fixture
reply_msg '@ci-kickoff' "$op_root" 'ci posts on the laptop' >/dev/null
FORK_SANDBOX_OPERATORS=@alice op_pass
check "laptop: FORK_SANDBOX_OPERATORS is ignored, a non-fleet sender clears the flag" 0 "$(op_flag_present)"
not_contains "laptop: no external-mail event" "$(cat "$work/op.out")" "external-mail"
op_rc=0
FORK_SANDBOX_OPERATORS='@a,,@b' op_pass || op_rc=$?
check "laptop: a malformed FORK_SANDBOX_OPERATORS does not refuse startup" 0 "$op_rc"

unset FORK_SANDBOX_POSTMASTER_K8S_DETACH
unset FORK_SANDBOX_POSTMASTER_K8S
unset FORK_SANDBOX_CONFIG_DIR

finish_suite
