#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/04-resume.sh — fork-sandbox-postmaster.sh: session resume:
# malformed ids and the wedge bound.
#
# Usage: tests/postmaster/04-resume.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== harvest: a malformed session_id leaves an earlier VALID id standing ==\n'
# ============================================================

# The tests above only ever check "not recorded" after $res_sessions was
# already cleared by an earlier step in this same run -- that proves
# nothing about the "leave standing" branch, since an absent file reads
# the same whether it was correctly left alone or never written. This
# block puts a real id on file FIRST, then feeds a malformed session_id
# and checks that id is untouched -- the only way to actually exercise
# "leave standing" rather than "was already absent".
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
ls_sid=99998888-7777-6666-5555-444433332211
ls_mid1="$(send_msg '@carol' '@alice' 'leave-standing topic' 'first message' 8)"
ls_tid="$(thread_of "$ls_mid1")"
ls_sessions="$PM_STATE_DIR/sessions/$ls_tid/alice"

: > "$STUB_ARGV_LOG"
once
finish_run alice 0 "$ls_sid"
once
check "leave-standing: a valid session id is recorded first" \
    "$ls_sid" "$(cat "$ls_sessions" 2>/dev/null)"

reply_msg '@carol' "$ls_mid1" 'second message' --to '@alice' >/dev/null
once
finish_run alice 0 'not a session id'
once
check "leave-standing: a malformed session id leaves the earlier VALID id standing" \
    "$ls_sid" "$(cat "$ls_sessions" 2>/dev/null)"

# pi is a "given" id-mode harness (fs_harness_session_caps): the postmaster
# derives its session id itself (pm_pi_session_id) and passes it as
# --session-id on EVERY wake, first included -- no sessions/ record is ever
# read or written for it. frank is the non-sealed pi seat.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
pi_mid1="$(send_msg '@carol' '@frank' 'pi seat resume' 'first message' 8)"
pi_tid="$(thread_of "$pi_mid1")"
pi_sessions="$PM_STATE_DIR/sessions/$pi_tid/frank"
: > "$STUB_ARGV_LOG"
once
check "resume: a pi seat gets --session-state" \
    "$PM_STATE_DIR/state/$pi_tid/frank" "$(argv_after --session-state "$STUB_ARGV_LOG")"
pi_sid1="$(argv_after --session-id "$STUB_ARGV_LOG")"
check "resume: a pi seat's first wake already gets a --session-id" 0 \
    "$( [[ -n "$pi_sid1" ]] && echo 0 || echo 1 )"
check "resume: a pi seat gets no --resume-session (create-if-missing, not discovered)" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "resume: a pi seat's session is never recorded under sessions/" 0 \
    "$( [[ -e "$pi_sessions" ]] && echo 1 || echo 0 )"

finish_run frank 0 "$pi_sid1"
once
check "resume: a pi seat's clean finish still writes nothing under sessions/" 0 \
    "$( [[ -e "$pi_sessions" ]] && echo 1 || echo 0 )"

reply_msg '@carol' "$pi_mid1" 'second message' --to '@frank' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: a pi seat's second wake gets the SAME --session-id" \
    "$pi_sid1" "$(argv_after --session-id "$STUB_ARGV_LOG")"

# A SEALED pi seat (bob) is wired the same as any other resumable harness
# now: it dispatches through agent-sandboxed instead of execing pi directly,
# but agent-sandboxed has its own --session-dir/--session-id, which bind the
# durable store into the sandbox and point pi at it there -- so the
# postmaster sends bob the same --session-state/--session-id pair it sends
# plain pi (frank, above), and bob's session is likewise never recorded
# under sessions/ (pi is a "given" id-mode harness regardless of network).
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
sealed_mid1="$(send_msg '@carol' '@bob' 'sealed pi seat resume' 'first message' 8)"
sealed_tid="$(thread_of "$sealed_mid1")"
sealed_sessions="$PM_STATE_DIR/sessions/$sealed_tid/bob"
: > "$STUB_ARGV_LOG"
once
check "resume: a sealed pi seat gets --session-state" \
    "$PM_STATE_DIR/state/$sealed_tid/bob" "$(argv_after --session-state "$STUB_ARGV_LOG")"
sealed_sid1="$(argv_after --session-id "$STUB_ARGV_LOG")"
check "resume: a sealed pi seat's first wake already gets a --session-id" 0 \
    "$( [[ -n "$sealed_sid1" ]] && echo 0 || echo 1 )"
check "resume: a sealed pi seat gets no --resume-session (create-if-missing, not discovered)" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "resume: a sealed pi seat's session is never recorded under sessions/" 0 \
    "$( [[ -e "$sealed_sessions" ]] && echo 1 || echo 0 )"

finish_run bob 0 "$sealed_sid1"
once
check "resume: a sealed pi seat's clean finish still writes nothing under sessions/" 0 \
    "$( [[ -e "$sealed_sessions" ]] && echo 1 || echo 0 )"

reply_msg '@carol' "$sealed_mid1" 'second message' --to '@bob' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: a sealed pi seat's second wake gets the SAME --session-id" \
    "$sealed_sid1" "$(argv_after --session-id "$STUB_ARGV_LOG")"

# codex is a "discover" id-mode harness, same as claude: the recorded id (if
# any) resumes via --resume-session, and a failed wake clears it. eve is the
# codex seat.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
codex_sid=aaaa1111-bbbb-2222-cccc-333344445555
codex_mid1="$(send_msg '@carol' '@eve' 'codex seat resume' 'first message' 8)"
codex_tid="$(thread_of "$codex_mid1")"
codex_sessions="$PM_STATE_DIR/sessions/$codex_tid/eve"

: > "$STUB_ARGV_LOG"
once
check "resume: a codex seat's first wake binds --session-state" \
    "$PM_STATE_DIR/state/$codex_tid/eve" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "resume: a codex seat's first wake passes no --resume-session" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"

finish_run eve 0 "$codex_sid"
once
check "resume: harvest records a codex seat's session id" \
    "$codex_sid" "$(cat "$codex_sessions" 2>/dev/null)"

reply_msg '@carol' "$codex_mid1" 'second message' --to '@eve' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: a codex seat's second wake resumes the recorded session" \
    "$codex_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"

# A broken (failed) resumed wake leaves the session standing, for every
# resumable harness -- codex here, claude already covered above.
finish_run eve 1
once
check "resume: a codex seat's failed wake leaves the recorded session id standing" \
    "$codex_sid" "$(cat "$codex_sessions" 2>/dev/null)"

# ============================================================
printf '\n== session resume: wedge bound -- 3 consecutive failed resumed wakes clear it ==\n'
# ============================================================

# "Keep across a failure" (above) must not wedge a seat on a genuinely
# broken session forever: 3 consecutive failed harvests of a RESUMED wake
# for the same pair clear the recorded id, and a clean exit-0 anywhere in
# that run resets the count back to 0.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

wb_sid=deadbeef-0000-1111-2222-333344445566
wb_mid1="$(send_msg '@carol' '@alice' 'wedge bound topic' 'first message' 8)"
wb_tid="$(thread_of "$wb_mid1")"
wb_sessions="$PM_STATE_DIR/sessions/$wb_tid/alice"

once
finish_run alice 0 "$wb_sid"
once
check "wedge bound: healthy session recorded to start" \
    "$wb_sid" "$(cat "$wb_sessions" 2>/dev/null)"

# Failure 1 of 3: still standing.
reply_msg '@carol' "$wb_mid1" 'wb msg 2' --to '@alice' >/dev/null
once
finish_run alice 1
once
check "wedge bound: 1st consecutive failed resumed wake leaves it standing" \
    "$wb_sid" "$(cat "$wb_sessions" 2>/dev/null)"

# Failure 2 of 3: still standing, and the retry actually resumed the
# ORIGINAL id -- proving "keep across failures" is what let 2 failures
# accumulate against the one resumed session.
reply_msg '@carol' "$wb_mid1" 'wb msg 3' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "wedge bound: the 2nd resumed wake resumed the original id" \
    "$wb_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
finish_run alice 1
once
check "wedge bound: 2nd consecutive failed resumed wake still leaves it standing" \
    "$wb_sid" "$(cat "$wb_sessions" 2>/dev/null)"

# Failure 3 of 3: this is the one that clears it.
reply_msg '@carol' "$wb_mid1" 'wb msg 4' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "wedge bound: the 3rd resumed wake also resumed the original id" \
    "$wb_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
finish_run alice 1
once
check "wedge bound: 3rd consecutive failed resumed wake clears it" 0 \
    "$( [[ -e "$wb_sessions" ]] && echo 1 || echo 0 )"

# ============================================================
printf '\n== session resume: the wedge bound never counts a given-mode (pi) harness ==\n'
# ============================================================

# pi (frank) derives --session-id fresh on every spawn and never reads
# sessions/ back (sessions_tracked is false for it -- FS_HARNESS_ID_MODE
# is "given"), so RESUMED is non-empty on every pi wake same as a
# discover-mode harness's. The FAILS counter must still never count a pi
# failure: clearing sessions/ can never help a pair that never reads it
# back, and docs/agent-mail.md promises a pi pair's retries/ file never
# carries a FAILS value.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

pw_mid1="$(send_msg '@carol' '@frank' 'pi wedge topic' 'first message' 8)"
pw_tid="$(thread_of "$pw_mid1")"
pw_retries="$PM_STATE_DIR/retries/$pw_tid/frank"

once
finish_run frank 1
once
check "pi wedge: 1st consecutive failed pi wake writes no FAILS" 0 \
    "$(if [[ -e "$pw_retries" ]]; then grep -c '^FAILS=' "$pw_retries"; else echo 0; fi)"

reply_msg '@carol' "$pw_mid1" 'pw msg 2' --to '@frank' >/dev/null
once
finish_run frank 1
once
check "pi wedge: 2nd consecutive failed pi wake writes no FAILS" 0 \
    "$(if [[ -e "$pw_retries" ]]; then grep -c '^FAILS=' "$pw_retries"; else echo 0; fi)"

reply_msg '@carol' "$pw_mid1" 'pw msg 3' --to '@frank' >/dev/null
once
finish_run frank 1
once
check "pi wedge: 3rd consecutive failed pi wake still writes no FAILS (never wedges)" 0 \
    "$(if [[ -e "$pw_retries" ]]; then grep -c '^FAILS=' "$pw_retries"; else echo 0; fi)"

# ============================================================
printf '\n== session resume: an exit-0 harvest in between resets the wedge count ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

rs_sid=facefeed-0000-1111-2222-333344445577
rs_mid1="$(send_msg '@carol' '@alice' 'reset count topic' 'first message' 8)"
rs_tid="$(thread_of "$rs_mid1")"
rs_sessions="$PM_STATE_DIR/sessions/$rs_tid/alice"

once
finish_run alice 0 "$rs_sid"
once

# Fail once (count=1).
reply_msg '@carol' "$rs_mid1" 'rs msg 2' --to '@alice' >/dev/null
once
finish_run alice 1
once

# Succeed once: resets the count to 0.
reply_msg '@carol' "$rs_mid1" 'rs msg 3' --to '@alice' >/dev/null
once
finish_run alice 0 "$rs_sid"
once

# Fail twice more: only 2 since the reset, so NOT cleared yet.
reply_msg '@carol' "$rs_mid1" 'rs msg 4' --to '@alice' >/dev/null
once
finish_run alice 1
once
reply_msg '@carol' "$rs_mid1" 'rs msg 5' --to '@alice' >/dev/null
once
finish_run alice 1
once
check "reset count: 2 failures since the exit-0 reset do not clear it" \
    "$rs_sid" "$(cat "$rs_sessions" 2>/dev/null)"

# One more failure is the 3rd since the reset: this one clears it.
reply_msg '@carol' "$rs_mid1" 'rs msg 6' --to '@alice' >/dev/null
once
finish_run alice 1
once
check "reset count: the 3rd failure since the reset clears it" 0 \
    "$( [[ -e "$rs_sessions" ]] && echo 1 || echo 0 )"

finish_suite
