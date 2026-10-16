#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/03-dead-wakes.sh — fork-sandbox-postmaster.sh: dead-wake
# detection by pid, launcher resolution, silent wakes, session resume.
#
# Usage: tests/postmaster/03-dead-wakes.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== harvest: a wake that dies without exit-code is detected via its pid ==\n'
# ============================================================

# Every scenario below spawns with the DEFAULT grace in force (a fresh
# spawn's run dir has no pid file yet -- the stub does not write one -- and
# with 60s of grace that reads as "not dead yet", exactly as a real run's
# runner has not written its pid file in the first instant either).
# FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE is only lowered right before the harvest pass under
# test, never before the spawn, so the spawn itself never trips the check
# this section exists to exercise.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'dead pid, no grace' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/sessions/$tid"
printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
    > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/sessions/$tid/alice"
printf '%s\n' "$(dead_pid_of)" > "$run_dir/pid"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
contains "dead pid, no grace: thread is flagged with the wake-died reason" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" \
    "wake never produced summary.json"
check "dead pid, no grace: the run is marked harvested (agent unblocks)" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"
check "dead pid, no grace: the recorded session id is left standing (no summary.json is no evidence)" \
    'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/sessions/$tid/alice" 2>/dev/null || true)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'dead pid, reply already on disk' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
mkdir -p -- "$run_dir/outbox"
printf '\nGot it, working on it.\n' > "$run_dir/outbox/mail-1.md"
printf '%s\n' "$(dead_pid_of)" > "$run_dir/pid"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
reply_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'Got it, working on it.' "$f" && reply_posted=1
done
check "dead pid, reply on disk: the reply that finished composing before the runner died is posted" 1 "$reply_posted"
contains "dead pid, reply on disk: thread is still flagged (a died wake is not a healthy outcome)" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" \
    "wake never produced summary.json"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid1="$(send_msg '@carol' '@alice' 'dead pid, pending message queued' 'body' 8)"
tid="$(thread_of "$mid1")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
mid2="$(reply_msg '@carol' "$mid1" 'a second message while alice is still working' --to '@alice')"
: > "$STUB_ARGV_LOG"
once
contains "dead pid, pending: message id recorded as pending on the live run" \
    "$(cat "$run_env")" "PENDING_MSGS=$mid2"
printf '%s\n' "$(dead_pid_of)" > "$run_dir/pid"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
: > "$STUB_ARGV_LOG"
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
check "dead pid, pending: harvest still fires a follow-up wake for the pending message" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
contains "dead pid, pending: follow-up wake's TRIGGER is the pending message" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env)" "TRIGGER=$mid2"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'dead pid, within grace' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
printf '%s\n' "$(dead_pid_of)" > "$run_dir/pid"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=3600
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
check "dead pid, within grace: not yet flagged" 0 \
    "$( [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0 )"
check "dead pid, within grace: not yet harvested (still counts as live)" "0" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'missing pid file' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
# No pid file at all is written -- the stub fabricates a run dir with only
# outbox/ under it.
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
contains "missing pid file: flagged with the wake-died reason" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" \
    "wake never produced summary.json"
check "missing pid file: marked harvested" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'live pid untouched' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
printf '%s\n' "$$" > "$run_dir/pid"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
check "live pid: not flagged" 0 \
    "$( [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0 )"
check "live pid: not harvested (a genuinely running wake is left alone)" "0" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

# A pid file that predates the current boot names a pid from a process
# table that no longer exists -- even a live, unrelated pid recycled onto
# it by the new boot must not be read as this run's own process. Faked
# here with a fixture instead of an actual reboot: a real one would take
# the test host down too.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'pid file predates a reboot' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
printf '%s\n' "$$" > "$run_dir/pid"
touch -d '@1000000000' "$run_dir/pid"
fake_proc_stat="$FORK_SANDBOX_MAIL_ROOT/fake-proc-stat"
printf 'btime 1700000000\n' > "$fake_proc_stat"
export FORK_SANDBOX_POSTMASTER_PROC_STAT="$fake_proc_stat"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_PROC_STAT FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
contains "reboot: a live pid whose pid file predates the current boot is flagged" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" \
    "wake never produced summary.json"
check "reboot: a live pid whose pid file predates the current boot is harvested" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@alice' 'pid file postdates the boot' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
printf '%s\n' "$$" > "$run_dir/pid"
touch -d '@1700000000' "$run_dir/pid"
fake_proc_stat="$FORK_SANDBOX_MAIL_ROOT/fake-proc-stat"
printf 'btime 1000000000\n' > "$fake_proc_stat"
export FORK_SANDBOX_POSTMASTER_PROC_STAT="$fake_proc_stat"
export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
once
unset FORK_SANDBOX_POSTMASTER_PROC_STAT FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
check "same boot: a live pid whose pid file postdates the boot is left alone" 0 \
    "$( [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0 )"
check "same boot: not harvested (a genuinely running wake is left alone)" "0" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

# A restarted pod has a fresh pid namespace on the SAME boot, so the pid a
# wake recorded can name a live, unrelated process in the new pod. The
# wake records `<pidns> <boot_id>` beside its pid; a pid is trusted only
# under the identity it was written in. The test's own $$ is the live pid.
pid_identity_case() {
    local label="$1" identity="$2" want_dead="$3" fake_ns="$4"
    local mid tid run_env run_dir
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    mid="$(send_msg '@carol' '@alice' "pid identity: $label" 'body' 8)"
    tid="$(thread_of "$mid")"
    : > "$STUB_ARGV_LOG"
    once
    run_env="$(env_file_for_agent alice)"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
    printf '%s\n' "$$" > "$run_dir/pid"
    [[ -z "$identity" ]] || printf '%s' "$identity" > "$run_dir/pid-identity"
    ln -sfn "$fake_ns" "$FORK_SANDBOX_MAIL_ROOT/fake-pidns"
    printf 'boot-aaaa\n' > "$FORK_SANDBOX_MAIL_ROOT/fake-boot-id"
    export FORK_SANDBOX_POSTMASTER_PROC_PIDNS="$FORK_SANDBOX_MAIL_ROOT/fake-pidns"
    export FORK_SANDBOX_POSTMASTER_BOOT_ID="$FORK_SANDBOX_MAIL_ROOT/fake-boot-id"
    export FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0
    once
    unset FORK_SANDBOX_POSTMASTER_PROC_PIDNS FORK_SANDBOX_POSTMASTER_BOOT_ID \
        FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE
    check "pid identity, $label: flagged as dead" "$want_dead" \
        "$( [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0 )"
    check "pid identity, $label: harvested" "$want_dead" \
        "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"
}
pid_identity_case "other pid namespace, live pid" 'pid:[4026531111] boot-aaaa' 1 'pid:[4026532222]'
pid_identity_case "other boot id, live pid" 'pid:[4026532222] boot-zzzz' 1 'pid:[4026532222]'
pid_identity_case "matching identity, live pid" 'pid:[4026532222] boot-aaaa' 0 'pid:[4026532222]'
pid_identity_case "no identity file, live pid" '' 0 'pid:[4026532222]'

# ============================================================
printf '\n== spawn launcher is resolved independent of PATH ==\n'
# ============================================================

# FORK_SANDBOX_POSTMASTER_LAUNCHER (exported in the fixture setup above)
# points straight at the stub via script_dir-style resolution, never via
# PATH -- true whether or not some OTHER fork-sandbox.sh happens to be on
# PATH too (e.g. this machine's own install). Proof: the stub is the one
# that's called.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
send_msg '@alice' '@bob' 'path independence' 'body' 8 >/dev/null
: > "$STUB_ARGV_LOG"
rc="$(once_rc)"
check "launcher: deliver spawns" "0" "$rc"
check "launcher: the stub, not any fork-sandbox.sh found via PATH, received the call" 1 \
    "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== session resume: state dir on every claude wake, id across wakes ==\n'
# ============================================================

# An agent woken repeatedly on one thread is one continuing claude
# conversation: --session-state binds a per-(thread, agent) transcript
# store into every wake, and the id harvest read out of the last wake's
# summary.json resumes it on the next.

PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

# ============================================================
printf '\n== Silent wake: an on-silence: flag seat that exits 0 having posted nothing flags ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
sw_mid="$(send_msg '@dana' '@sam, @carol' 'silent topic' 'answer me' 8)"
sw_tid="$(thread_of "$sw_mid")"
sw_flag() { cat "$PM_STATE_DIR/needs-operator/$sw_tid" 2>/dev/null || true; }
sw_val() { sed -n "s/^$2=//p" "$1" | tail -n1; }
once
sw_env="$(live_env_for_agent sam)"
sw_rid="$(basename "$sw_env" .env)"
check "silent wake: the run record carries ON_SILENCE=flag" "flag" "$(sw_val "$sw_env" ON_SILENCE)"
check "silent wake: a seat without the key records it empty" "" \
    "$(sw_val "$(live_env_for_agent carol)" ON_SILENCE)"
finish_run carol 0
once
check "silent wake: carol (no on-silence) exiting 0 with nothing is not flagged" "" "$(sw_flag)"
finish_run sam 0
once
check "silent wake: sam exiting 0 with nothing flags the thread" \
    "wake for sam posted no reply (run $sw_rid)" "$(sw_flag)"
contains "silent wake: flag event keyword silent-wake" "$(cat "$work/once.out")" \
    "pm flag thread=${sw_tid:0:8} reason=silent-wake"

# The seat's next wake replies: that answers the silence, as a clean exit
# answers a wake-exit.
reply_msg '@dana' "$sw_mid" 'still waiting' --to '@sam' >/dev/null
once
sw_env2="$(live_env_for_agent sam)"
sw_rid2="$(basename "$sw_env2" .env)"
finish_run sam 0
printf 'Subject: answer\n\nhere it is\n' > "$(sw_val "$sw_env2" RUN_DIR)/outbox/mail-1.md"
once
check "silent wake: the seat's next reply clears the flag" "" "$(sw_flag)"
contains "silent wake: flag-clear event names the silent run" "$(cat "$work/once.out")" \
    "pm flag-clear thread=${sw_tid:0:8} agent=sam reason=silent-wake run=$sw_rid by=$sw_rid2 flagged=no"
check "silent wake: the journal records the clear" 1 \
    "$(awk -F'\t' '$2=="clear" && $3=="silent-wake"' "$PM_STATE_DIR/needs-operator-journal/$sw_tid" | wc -l)"

# A failed wake is a wake-exit, never also a silence.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
sw_mid="$(send_msg '@dana' '@sam' 'silent topic 2' 'answer me' 8)"
sw_tid="$(thread_of "$sw_mid")"
once
finish_run sam 3
once
contains "silent wake: a non-zero exit flags wake-exit" "$(sw_flag)" "wake for sam exited 3"
check "silent wake: ... and no silent-wake line is journaled" 0 \
    "$(awk -F'\t' '$3=="silent-wake"' "$PM_STATE_DIR/needs-operator-journal/$sw_tid" | wc -l)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

res_sid=11112222-3333-4444-5555-666677778888
res_mid1="$(send_msg '@carol' '@alice' 'resume topic' 'first message' 8)"
res_tid="$(thread_of "$res_mid1")"
res_state="$PM_STATE_DIR/state/$res_tid/alice"
res_sessions="$PM_STATE_DIR/sessions/$res_tid/alice"

: > "$STUB_ARGV_LOG"
once
check "resume: first wake binds the per-(thread, agent) state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "resume: first wake passes no --resume-session" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "resume: first wake's .env records it as fresh" "RESUMED=" \
    "$(grep '^RESUMED=' "$(live_env_for_agent alice)")"
contains "resume: status marks a fresh wake" \
    "$("$postmaster" status 2>&1)" "session=fresh"

finish_run alice 0 "$res_sid"
once
check "resume: harvest records the session id from summary.json" \
    "$res_sid" "$(cat "$res_sessions" 2>/dev/null)"

res_mid2="$(reply_msg '@carol' "$res_mid1" 'second message' --to '@alice')"
: > "$STUB_ARGV_LOG"
once
check "resume: second wake resumes the recorded session" \
    "$res_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "resume: second wake binds the same state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"
contains "resume: status marks a resumed wake" \
    "$("$postmaster" status 2>&1)" "resumed=$res_sid"

# A resumed wake that fails outright KEEPS the recorded session now: its
# summary.json here names no usable id (finish_run's default is a null
# session_id), which is weak evidence either way, so the prior id is left
# standing rather than cleared -- a mid-wake credential rollover or crash
# must not wipe the seat's persona. The wedge bound that eventually clears
# a session stuck failing across three consecutive resumed wakes is its
# own section below.
finish_run alice 1
once
check "resume: a failed wake with no usable session_id in summary.json leaves the recorded id standing" \
    "$res_sid" "$(cat "$res_sessions" 2>/dev/null)"

reply_msg '@carol' "$res_mid2" 'third message' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: the wake after a failure still resumes (session was not cleared)" \
    "$res_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "resume: ...and still binds the state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"

# A crash whose summary.json DOES name a real (id-shaped) session_id is
# recorded exactly like a success -- it may be the id a --refresh-at
# mid-run credential rollover resumed onto.
new_crash_sid=cafefeed-1111-2222-3333-444455556666
finish_run alice 1 "$new_crash_sid"
once
check "resume: a failed wake with an id-shaped summary session_id records THAT id" \
    "$new_crash_sid" "$(cat "$res_sessions" 2>/dev/null)"

reply_msg '@carol' "$res_mid1" 'fourth message' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: the next wake resumes the id recorded from the crash" \
    "$new_crash_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
finish_run alice 0 "$new_crash_sid"
once

# A summary.json that names nothing usable leaves the store's own history
# alone rather than recording a value the launcher would refuse -- a bad
# id there would wedge every later wake of this seat.
reply_msg '@carol' "$res_mid1" 'fifth message' --to '@alice' >/dev/null
once
finish_run alice 0 'not a session id'
once
check "resume: a malformed session id leaves the earlier valid id standing" \
    "$new_crash_sid" "$(cat "$res_sessions" 2>/dev/null)"

# A session-state directory bound rw into the sandbox can end up with a
# transcript named with a leading hyphen; fork-sandbox.sh's own
# --resume-session gate refuses that shape (a resumed value with a
# leading hyphen would be misread as another flag), so PM_SESSION_ID_RE
# must reject it too, or this seat records an id the launcher then
# refuses on every later wake.
reply_msg '@carol' "$res_mid1" 'sixth message' --to '@alice' >/dev/null
once
finish_run alice 0 '-abcdef12'
once
check "resume: a session id with a leading hyphen leaves the earlier valid id standing" \
    "$new_crash_sid" "$(cat "$res_sessions" 2>/dev/null)"

finish_suite
