#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/05-retry.sh — fork-sandbox-postmaster.sh: retries of failed
# wakes: scheduling, state file, attempt counts.
#
# Usage: tests/postmaster/05-retry.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== retry: a failed wake with no pending message is retried, bounded, then flagged ==\n'
# ============================================================

# 0,0: two retries, zero backoff -- the very next pass's retry check
# always finds NOT_BEFORE already due, so the test never has to sleep.
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rt_mid1="$(send_msg '@carol' '@alice' 'retry topic' 'first message' 8)"
rt_tid="$(thread_of "$rt_mid1")"
rt_short="${rt_tid:0:8}"

once
finish_run alice 1
: > "$STUB_ARGV_LOG"
once
check "retry: nothing spawns on the same pass the failure is harvested" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "retry: a failed wake with no pending message is re-spawned on the next pass" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
contains "retry: the retry event is emitted" "$(cat "$work/once.out")" \
    "pm retry thread=$rt_short agent=alice trigger=${rt_mid1:0:8} attempt=1"
contains "retry: the retry wake's trigger is the original message" \
    "$(cat "$(live_env_for_agent alice)")" "TRIGGER=$rt_mid1"

finish_run alice 1
: > "$STUB_ARGV_LOG"
once
check "retry: nothing spawns on the pass that harvests the 2nd failure" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "retry: a second failure is also re-spawned (2nd retry, cap 2)" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
contains "retry: the 2nd retry event names attempt=2" "$(cat "$work/once.out")" \
    "pm retry thread=$rt_short agent=alice trigger=${rt_mid1:0:8} attempt=2"

finish_run alice 1
: > "$STUB_ARGV_LOG"
once
check "retry: a third failure does NOT retry again (cap exhausted)" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
contains "retry: exhaustion flags the thread, naming the agent and trigger" \
    "$(cat "$PM_STATE_DIR/needs-operator/$rt_tid" 2>/dev/null)" \
    "wake for alice failed after 2 retries (trigger ${rt_mid1:0:8})"
contains "retry: the exhausted record names the trigger that exhausted (read contract)" \
    "$(cat "$PM_STATE_DIR/retries/$rt_tid/alice" 2>/dev/null)" "TRIGGER=$rt_mid1"
check "retry: the exhausted record carries no NOT_BEFORE (nothing left waiting)" 0 \
    "$( [[ -n "$(sed -n 's/^NOT_BEFORE=//p' "$PM_STATE_DIR/retries/$rt_tid/alice" 2>/dev/null)" ]] && echo 1 || echo 0 )"
contains "retry: exhaustion is a persistent STATE, not just a dropped file" \
    "$(cat "$PM_STATE_DIR/retries/$rt_tid/alice" 2>/dev/null)" "STATE=exhausted"
contains "retry: the exhausted record names the cap it hit" \
    "$(cat "$PM_STATE_DIR/retries/$rt_tid/alice" 2>/dev/null)" "MAX=2"
check "retry: the exhausted record names the run that last failed" 1 \
    "$( [[ -n "$(sed -n 's/^LAST_FAILED_RUN=//p' "$PM_STATE_DIR/retries/$rt_tid/alice" 2>/dev/null)" ]] && echo 1 || echo 0 )"

# ============================================================
printf '\n== retry: the state file is a read contract (pending, then recovered) ==\n'
# ============================================================
# STATE/MAX/LAST_FAILED_RUN/RECOVERED_AT let a tool other than the
# postmaster itself tell a pending retry from an exhausted one (above)
# from a recovered one (here), without guessing from which fields happen
# to still be on file.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

sc_mid1="$(send_msg '@carol' '@alice' 'schema topic' 'first message' 8)"
sc_tid="$(thread_of "$sc_mid1")"
sc_retries="$PM_STATE_DIR/retries/$sc_tid/alice"

once
finish_run alice 1
once
contains "schema: a scheduled retry's record is STATE=pending" \
    "$(cat "$sc_retries" 2>/dev/null)" "STATE=pending"
check "schema: a scheduled retry's record names the run that failed" 1 \
    "$( [[ -n "$(sed -n 's/^LAST_FAILED_RUN=//p' "$sc_retries" 2>/dev/null)" ]] && echo 1 || echo 0 )"
contains "schema: a scheduled retry's record carries the configured cap" \
    "$(cat "$sc_retries" 2>/dev/null)" "MAX=2"

once
finish_run alice 0 deadbeef-cafe-0000-1111-222233334444
once
contains "schema: a later success turns pending into a persistent recovered record" \
    "$(cat "$sc_retries" 2>/dev/null)" "STATE=recovered"
contains "schema: the recovered record still names the trigger it recovered from (read contract)" \
    "$(cat "$sc_retries" 2>/dev/null)" "TRIGGER=$sc_mid1"
check "schema: the recovered record carries no NOT_BEFORE (nothing left waiting)" 0 \
    "$( [[ -n "$(sed -n 's/^NOT_BEFORE=//p' "$sc_retries" 2>/dev/null)" ]] && echo 1 || echo 0 )"
contains "schema: the recovered record is timestamped" \
    "$(cat "$sc_retries" 2>/dev/null)" "RECOVERED_AT="

sc_recovered_at_1="$(sed -n 's/^RECOVERED_AT=//p' "$sc_retries" 2>/dev/null)"
sleep 1.1 # RECOVERED_AT is epoch seconds; force a distinguishable value if it moves
reply_msg '@carol' "$sc_mid1" 'schema follow-up' --to '@alice' >/dev/null
once
finish_run alice 0 deadbeef-cafe-0000-1111-222233334444
once
check "schema: a later unrelated clean harvest does not slide RECOVERED_AT forward" \
    "$sc_recovered_at_1" "$(sed -n 's/^RECOVERED_AT=//p' "$sc_retries" 2>/dev/null)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

nf_mid1="$(send_msg '@carol' '@alice' 'never failed topic' 'first message' 8)"
nf_tid="$(thread_of "$nf_mid1")"
once
finish_run alice 0 cafebabe-0000-1111-2222-333344445566
once
check "schema: a pair that never failed gets no retry file at all" 0 \
    "$( [[ -e "$PM_STATE_DIR/retries/$nf_tid/alice" ]] && echo 1 || echo 0 )"

# ============================================================
printf '\n== retry: a new trigger after an EXHAUSTED record starts its own attempt count ==\n'
# ============================================================
# Regression: pm_retry_schedule used to read ATTEMPT off whatever was on
# file without checking whose TRIGGER it belonged to. Once a pair's
# retries/ file held a terminal exhausted record, its stale ATTEMPT (at
# the cap) leaked into the very next trigger's failure, flagging that
# brand-new trigger exhausted with zero retries ever attempted -- and
# nothing ever respawned it.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

pe_mid1="$(send_msg '@carol' '@alice' 'post-exhaust topic' 'first message' 8)"
pe_tid="$(thread_of "$pe_mid1")"
pe_retries="$PM_STATE_DIR/retries/$pe_tid/alice"

once                # spawn
finish_run alice 1
once                # harvest -> schedule pending, attempt 0
once                # retry pass fires attempt 1's dispatch
finish_run alice 1
once                # harvest -> still pending, attempt 1 (below cap 2)
once                # retry pass fires attempt 2's dispatch
finish_run alice 1
once                # harvest -> attempt 2 >= cap 2: exhausted
contains "post-exhaust setup: the first trigger is exhausted (STATE=exhausted)" \
    "$(cat "$pe_retries" 2>/dev/null)" "STATE=exhausted"
contains "post-exhaust setup: exhaustion names the first trigger" \
    "$(cat "$pe_retries" 2>/dev/null)" "TRIGGER=$pe_mid1"

pe_mid2="$(reply_msg '@carol' "$pe_mid1" 'post-exhaust followup' --to '@alice')"
: > "$STUB_ARGV_LOG"
once
check "post-exhaust: the new message's wake still spawns despite the exhausted record" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

finish_run alice 1
once
contains "post-exhaust: the new trigger's failure schedules a fresh retry, not exhaustion" \
    "$(cat "$pe_retries" 2>/dev/null)" "STATE=pending"
contains "post-exhaust: the pending record names the NEW trigger" \
    "$(cat "$pe_retries" 2>/dev/null)" "TRIGGER=$pe_mid2"
check "post-exhaust: the new trigger's attempt count starts at 0, not carried over from the old exhaustion" 1 \
    "$(grep -c -- '^ATTEMPT=0$' "$pe_retries" 2>/dev/null)"

: > "$STUB_ARGV_LOG"
once
check "post-exhaust: the new trigger's first retry actually fires" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== retry: a new trigger after a RECOVERED record starts its own attempt count ==\n'
# ============================================================
# Same regression as above, for the other terminal STATE the read
# contract defines: a pair that recovered after spending its full retry
# budget must not have that spent-budget ATTEMPT carried into the next,
# unrelated trigger's failure either.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

pr_mid1="$(send_msg '@carol' '@alice' 'post-recover topic' 'first message' 8)"
pr_tid="$(thread_of "$pr_mid1")"
pr_retries="$PM_STATE_DIR/retries/$pr_tid/alice"

once                # spawn
finish_run alice 1
once                # harvest -> schedule pending, attempt 0
once                # retry pass fires attempt 1's dispatch
finish_run alice 1
once                # harvest -> still pending, attempt 1 (below cap 2)
once                # retry pass fires attempt 2's dispatch
finish_run alice 0 deadbeef-1111-2222-3333-444455556666
once                # harvest of a clean exit-0 at the cap -> recovered, attempt 2
contains "post-recover setup: the first trigger recovered at the retry cap (STATE=recovered)" \
    "$(cat "$pr_retries" 2>/dev/null)" "STATE=recovered"
contains "post-recover setup: recovery names the first trigger" \
    "$(cat "$pr_retries" 2>/dev/null)" "TRIGGER=$pr_mid1"
contains "post-recover setup: recovery happened at the cap (ATTEMPT=2)" \
    "$(cat "$pr_retries" 2>/dev/null)" "ATTEMPT=2"

pr_mid2="$(reply_msg '@carol' "$pr_mid1" 'post-recover followup' --to '@alice')"
: > "$STUB_ARGV_LOG"
once
check "post-recover: the new message's wake still spawns despite the recovered record" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

finish_run alice 1
once
contains "post-recover: the new trigger's failure schedules a fresh retry, not immediate exhaustion" \
    "$(cat "$pr_retries" 2>/dev/null)" "STATE=pending"
contains "post-recover: the pending record names the NEW trigger" \
    "$(cat "$pr_retries" 2>/dev/null)" "TRIGGER=$pr_mid2"
check "post-recover: the new trigger's attempt count starts at 0, not carried over from the old recovery" 1 \
    "$(grep -c -- '^ATTEMPT=0$' "$pr_retries" 2>/dev/null)"

: > "$STUB_ARGV_LOG"
once
check "post-recover: the new trigger's first retry actually fires" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== session resume: a wedge trip coinciding with the retry cap does not grant an extra retry ==\n'
# ============================================================

# Regression: the wedge bound's own FAILS-reset-to-0 used to go through
# the same fails=0-clears-everything path a clean exit-0 harvest uses,
# wiping the in-flight retry's own ATTEMPT/MAX along with it. When the
# wedge's 3rd-in-a-row trip landed on the exact wake that also spent the
# retry cap's last attempt, pm_retry_schedule (called right after, in the
# same harvest) then read attempt=0 off the just-wiped file and happily
# scheduled one more retry than $FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF's
# length allows.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

wr_sid=01234567-89ab-cdef-0123-456789abcdef
wr_mid1="$(send_msg '@carol' '@alice' 'wedge+retry topic' 'first message' 8)"
wr_tid="$(thread_of "$wr_mid1")"
wr_sessions="$PM_STATE_DIR/sessions/$wr_tid/alice"
wr_retries="$PM_STATE_DIR/retries/$wr_tid/alice"

once
finish_run alice 0 "$wr_sid"
once

wr_mid2="$(reply_msg '@carol' "$wr_mid1" 'wr msg 2' --to '@alice')"
once
finish_run alice 1
once
once
finish_run alice 1
once
once
finish_run alice 1
once

check "wedge+retry cap: the session is cleared (wedge tripped at 3)" 0 \
    "$( [[ -e "$wr_sessions" ]] && echo 1 || echo 0 )"
contains "wedge+retry cap: the cap is exhausted, not silently extended by the wedge trip" \
    "$(cat "$PM_STATE_DIR/needs-operator/$wr_tid" 2>/dev/null)" \
    "wake for alice failed after 2 retries (trigger ${wr_mid2:0:8})"
contains "wedge+retry cap: the exhausted record still names the trigger (read contract)" \
    "$(cat "$wr_retries" 2>/dev/null)" "TRIGGER=$wr_mid2"
check "wedge+retry cap: no pending schedule remains (no NOT_BEFORE)" 0 \
    "$( [[ -n "$(sed -n 's/^NOT_BEFORE=//p' "$wr_retries" 2>/dev/null)" ]] && echo 1 || echo 0 )"
: > "$STUB_ARGV_LOG"
once
check "wedge+retry cap: no further retry fires past the cap" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== retry: a retried wake'"'"'s own pending message clears its stale schedule ==\n'
# ============================================================

# Regression: a wake dispatched BY the retry pass itself (already
# resuming an older trigger) that received a new message while live, and
# then also failed, answered that new message with a follow-up wake of
# its own -- but never cleared the OLDER trigger's still-pending retry
# schedule first. Left lying around, a stale schedule like that could
# fire again later against a trigger the conversation had already moved
# past.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

sr_mid1="$(send_msg '@carol' '@alice' 'stale retry topic' 'first message' 8)"
sr_tid="$(thread_of "$sr_mid1")"
sr_retries="$PM_STATE_DIR/retries/$sr_tid/alice"

once
finish_run alice 1
once
once

sr_mid2="$(reply_msg '@carol' "$sr_mid1" 'second message' --to '@alice')"
once
finish_run alice 1
once

contains "stale retry: the pending message's own follow-up wake fired" \
    "$(cat "$(live_env_for_agent alice)")" "TRIGGER=$sr_mid2"
check "stale retry: the stale older-trigger schedule was cleared, not left lying around" 0 \
    "$( [[ -n "$(sed -n 's/^TRIGGER=//p' "$sr_retries" 2>/dev/null)" ]] && echo 1 || echo 0 )"

# ============================================================
printf '\n== retry: a retried wake'"'"'s handoff warns against duplicate replies ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

send_msg '@carol' '@alice' 'handoff retry topic' 'first message' 8 >/dev/null

once
hf_first_run_id="$(basename "$(live_env_for_agent alice)" .env)"
hf_first_handoff="$PM_STATE_DIR/handoffs/$hf_first_run_id.md"
check "handoff: a normal (non-retry) wake's handoff carries no retry section" 0 \
    "$(grep -c -- '^## This is a retry$' "$hf_first_handoff")"

finish_run alice 1
once
once
hf_retry_run_id="$(basename "$(live_env_for_agent alice)" .env)"
hf_retry_handoff="$PM_STATE_DIR/handoffs/$hf_retry_run_id.md"
check "handoff: a retried wake's handoff DOES carry the retry section" 1 \
    "$(grep -c -- '^## This is a retry$' "$hf_retry_handoff")"
contains "handoff: the retry section warns against resending an already-posted reply" \
    "$(cat "$hf_retry_handoff")" "do not send it again"
# This handoff is the ordinary trigger-only form (the thread snapshot
# mount succeeds in this test), which renders only the triggering message
# -- so an already-posted reply is not "above" at all, and the retry
# section must send the agent to /thread/thread.txt instead of claiming
# otherwise (see the P1 finding this pins).
contains "handoff: a trigger-only retry points at /thread/thread.txt, not a false 'above'" \
    "$(cat "$hf_retry_handoff")" "read
/thread/thread.txt first"

# ============================================================
printf '\n== retry: a failed wake WITH a pending message schedules no retry ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

fp_mid1="$(send_msg '@carol' '@alice' 'failed with pending' 'first message' 8)"
fp_tid="$(thread_of "$fp_mid1")"
once
fp_run_env="$(live_env_for_agent alice)"

fp_mid2="$(reply_msg '@carol' "$fp_mid1" 'second message' --to '@alice')"
once
contains "retry+pending: the new message is recorded as pending on the live run" \
    "$(cat "$fp_run_env")" "PENDING_MSGS=$fp_mid2"

finish_run alice 1
: > "$STUB_ARGV_LOG"
once
check "retry+pending: harvest fires exactly one wake (the pending follow-up)" 1 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
contains "retry+pending: the follow-up wake's trigger is the pending message, not a retry" \
    "$(cat "$(live_env_for_agent alice)")" "TRIGGER=$fp_mid2"
check "retry+pending: no retry was scheduled for the failed trigger" 0 \
    "$( [[ -e "$PM_STATE_DIR/retries/$fp_tid/alice" ]] && echo 1 || echo 0 )"

: > "$STUB_ARGV_LOG"
once
check "retry+pending: a later pass spawns nothing extra (no retry lying in wait)" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== retry: a FAILS-only file (failure superseded by a pending message) never becomes recovered ==\n'
# ============================================================

# A resumed wake that fails WITH a pending message never reaches
# pm_retry_schedule (the pending follow-up supersedes it -- see
# pm_retry_clear_schedule's call site), so the wedge bound's FAILS bump is
# the only thing that ever touches its retries/ file: no TRIGGER, no
# STATE. pm_retry_recover must treat that the same as no retry history at
# all, not as something to declare "recovered" -- the read contract's
# STATE is either absent, pending, exhausted, or recovered, and a
# FAILS-only file matches the first, never the last.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

fo_sid=cafebeef-1111-2222-3333-444455556666
fo_mid1="$(send_msg '@carol' '@alice' 'fails-only recover topic' 'first message' 8)"
fo_tid="$(thread_of "$fo_mid1")"
fo_retries="$PM_STATE_DIR/retries/$fo_tid/alice"

once
finish_run alice 0 "$fo_sid"
once

fo_mid2="$(reply_msg '@carol' "$fo_mid1" 'second message' --to '@alice')"
once
contains "fails-only: the 2nd wake resumes the recorded session" \
    "$(cat "$(live_env_for_agent alice)")" "TRIGGER=$fo_mid2"

fo_mid3="$(reply_msg '@carol' "$fo_mid1" 'third message' --to '@alice')"
once
contains "fails-only: the third message is recorded as pending on the resumed (2nd) run" \
    "$(cat "$(live_env_for_agent alice)")" "PENDING_MSGS=$fo_mid3"

finish_run alice 1
: > "$STUB_ARGV_LOG"
once
check "fails-only: the resumed wake's failure bumps FAILS to 1" \
    1 "$(sed -n 's/^FAILS=//p' "$fo_retries" 2>/dev/null)"
check "fails-only: no STATE is written for a failure the pending message superseded" 0 \
    "$(grep -c -- '^STATE=' "$fo_retries" 2>/dev/null)"

finish_run alice 0 "$fo_sid"
once
# The FAILS-only file has nothing left to reset FAILS from and no retry
# history to recover, so the exit-0 harvest removes it outright -- absent
# is the correct way to observe "no STATE, no RECOVERED_AT" here.
check "fails-only: an exit-0 harvest of the superseding wake does not fabricate STATE=recovered" 0 \
    "$(if [[ -e "$fo_retries" ]]; then grep -c -- '^STATE=' "$fo_retries"; else echo 0; fi)"
check "fails-only: RECOVERED_AT is not written either" 0 \
    "$(if [[ -e "$fo_retries" ]]; then grep -c -- '^RECOVERED_AT=' "$fo_retries"; else echo 0; fi)"

# ============================================================
printf '\n== retry: hops-0 and budget-exhausted triggers are refused by the existing gates ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

hz_mid="$(send_msg '@carol' '@alice' 'hops zero retry' 'body' 0)"
hz_tid="$(thread_of "$hz_mid")"
mkdir -p -- "$PM_STATE_DIR/retries/$hz_tid"
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$hz_mid" > "$PM_STATE_DIR/retries/$hz_tid/alice"
: > "$STUB_ARGV_LOG"
once
check "retry: a hops-0 trigger is refused, not spawned" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
check "retry: the hops-0 schedule is dropped after refusal (no infinite loop)" 0 \
    "$( [[ -n "$(sed -n 's/^TRIGGER=//p' "$PM_STATE_DIR/retries/$hz_tid/alice" 2>/dev/null)" ]] && echo 1 || echo 0 )"

bg_mid="$(send_msg '@carol' '@alice' 'budget exhausted retry' 'body' 8)"
bg_tid="$(thread_of "$bg_mid")"
mkdir -p -- "$PM_STATE_DIR/spawns"
seq 1 96 > "$PM_STATE_DIR/spawns/$bg_tid"
mkdir -p -- "$PM_STATE_DIR/retries/$bg_tid"
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$bg_mid" > "$PM_STATE_DIR/retries/$bg_tid/alice"
: > "$STUB_ARGV_LOG"
once
check "retry: a budget-exhausted trigger is refused, not spawned" 0 \
    "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
check "retry: the budget-exhausted schedule is dropped after refusal" 0 \
    "$( [[ -n "$(sed -n 's/^TRIGGER=//p' "$PM_STATE_DIR/retries/$bg_tid/alice" 2>/dev/null)" ]] && echo 1 || echo 0 )"

finish_suite
