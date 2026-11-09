#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/23-timed-regate.sh — fork-sandbox-postmaster.sh: a
# wake-deferred line's due time and attempt count, the timed re-gate that
# reads them, and the quiescence flag that waits for those re-gates.
#
# Time is moved with FORK_SANDBOX_POSTMASTER_TEST_NOW (the re-gate clock's
# test seam), never by sleeping.
#
# Usage: tests/postmaster/23-timed-regate.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# tess is gated by wake-when: gate.
printf 'Timed re-gate fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/tess.md"
sed -i 's/^agents:$/agents:\n  tess:\n    wake-when: gate/' "$FORK_SANDBOX_FLEET_FILE"

new_root TR_HOOKS
new_root TR_OUT
# shellcheck disable=SC2031  # the subshell is hk_call's, not this scope
export TR_OUT FORK_SANDBOX_HOOKS_DIR="$TR_HOOKS"
# The gate logs each run and answers with $TR_OUT/verdict.
cat > "$TR_HOOKS/wake-when.gate" <<'GATE'
#!/usr/bin/env bash
echo "$FS_HOOK_AGENT $FS_HOOK_MESSAGE" >> "$TR_OUT/calls"
exit "$(cat "$TR_OUT/verdict")"
GATE
chmod +x "$TR_HOOKS/wake-when.gate"

T0=1800000000
export FORK_SANDBOX_POSTMASTER_TEST_NOW="$T0"
unset FORK_SANDBOX_WAKE_REGATE_BASE FORK_SANDBOX_WAKE_REGATE_ATTEMPTS

tr_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$TR_OUT/calls"
    : > "$STUB_ARGV_LOG"
    echo 1 > "$TR_OUT/verdict"
    FORK_SANDBOX_POSTMASTER_TEST_NOW="$T0"
}
tr_at() { FORK_SANDBOX_POSTMASTER_TEST_NOW="$1"; }
tr_calls() { wc -l < "$TR_OUT/calls"; }
tr_spawns() { grep -c -- "^sbx-mail-${tr_short}-$1-" "$STUB_ARGV_LOG" || true; }
tr_line() { cat "$PM_STATE_DIR/wake-deferred/$tr_tid" 2>/dev/null; }
tr_field() { tr_line | awk -v n="$1" '{print $n}'; }
tr_flag() { cat "$PM_STATE_DIR/needs-operator/$tr_tid" 2>/dev/null || true; }
tr_flags() {
    local n
    n="$(grep -c "	flag	" "$PM_STATE_DIR/needs-operator-journal/$tr_tid" 2>/dev/null || true)"
    echo "${n:-0}"
}
tr_send() {
    tr_mid="$(send_msg '@alice' "${1:-@tess}" "${2:-timed topic}" 'body' 8)"
    tr_tid="$(thread_of "$tr_mid")"; tr_short="${tr_tid:0:8}"
}

# ============================================================
printf '\n== deferral record: a defer writes its due time and attempt count ==\n'
# ============================================================

tr_store
tr_send
once
check "record: the line is <agent> <message-id> <due> <attempt>" "tess $tr_mid $(( T0 + 300 )) 0" "$(tr_line)"
check "record: status --json still lists the seat and message" "[{'agent': 'tess', 'message_id': '$tr_mid'}]" \
    "$(we_py "$(we_json "$tr_tid")" 'd["wake_deferred"]')"

tr_store
tr_send
FORK_SANDBOX_WAKE_REGATE_BASE=60 once
check "record: FORK_SANDBOX_WAKE_REGATE_BASE sets the first interval" "$(( T0 + 60 ))" "$(tr_field 3)"

for tr_bad in abc -5 1.5; do
    tr_store
    tr_send
    FORK_SANDBOX_WAKE_REGATE_BASE="$tr_bad" once
    check "record: BASE '$tr_bad' falls back to the default 300" "$(( T0 + 300 ))" "$(tr_field 3)"
done

# A defer on fresh information resets the count: a line three timed
# re-gates in is replaced, on a new message, by attempt 0 due one base
# interval out.
tr_store
tr_send
once
printf 'tess %s %s 3\n' "$tr_mid" "$(( T0 + 100 ))" > "$PM_STATE_DIR/wake-deferred/$tr_tid"
tr_at $(( T0 + 50 ))
tr_mid2="$(reply_msg '@alice' "$tr_mid" 'more' --to '@tess')"
once
check "record: a new message's defer resets the count" "tess $tr_mid2 $(( T0 + 350 )) 0" "$(tr_line)"

# ============================================================
printf '\n== deferral record: the older two-field line still parses ==\n'
# ============================================================

tr_store
tr_send
once
printf 'tess %s\n' "$tr_mid" > "$PM_STATE_DIR/wake-deferred/$tr_tid"
check "legacy: status --json reads the two-field line" "[{'agent': 'tess', 'message_id': '$tr_mid'}]" \
    "$(we_py "$(we_json "$tr_tid")" 'd["wake_deferred"]')"

# The harvest re-gate (another seat's zero-reply run) reads a legacy line
# and a deferral it records again starts at attempt 0.
tr_store
tr_send '@tess, @carol'
once
printf 'tess %s\n' "$tr_mid" > "$PM_STATE_DIR/wake-deferred/$tr_tid"
tr_at $(( T0 + 10 ))
finish_run carol 0
once
contains "legacy: the harvest re-gate ran on the two-field line" "$(cat "$work/once.out")" \
    "pm regate thread=$tr_short agent=tess run="
check "legacy: the gate was asked about the deferred message" "tess $tr_mid" "$(tail -n1 "$TR_OUT/calls")"
check "legacy: the harvest re-gate's defer rewrites it at attempt 0" "tess $tr_mid $(( T0 + 310 )) 0" "$(tr_line)"

# ============================================================
printf '\n== timed re-gate: a deferred seat on a quiet thread is asked again ==\n'
# ============================================================

tr_store
tr_send
once
check "timer: one gate run on arrival" 1 "$(tr_calls)"
tr_at $(( T0 + 299 ))
once
check "timer: nothing is re-gated before the due time" 1 "$(tr_calls)"
not_contains "timer: no regate event before the due time" "$(cat "$work/once.out")" "pm regate"
echo 0 > "$TR_OUT/verdict"
tr_at $(( T0 + 300 ))
once
contains "timer: the regate event names thread, seat, timer and attempt" "$(cat "$work/once.out")" \
    "pm regate thread=$tr_short agent=tess source=timer attempt=1"
check "timer: the gate was asked about the deferred message" "tess $tr_mid" "$(tail -n1 "$TR_OUT/calls")"
check "timer: exit 0 wakes the seat" 1 "$(tr_spawns tess)"
check "timer: and the deferral line is gone" "" "$(tr_line)"
check "timer: the wake's trigger is the deferred message" "$tr_mid" \
    "$(env_val "$(env_file_for_agent tess)" TRIGGER)"

# ============================================================
printf '\n== timed re-gate: a gate that keeps deferring is asked ATTEMPTS times ==\n'
# ============================================================

tr_store
tr_send
once
# Due times: T0+300, then each defer pushes the next out by base * 2^n.
tr_dues=()
for tr_n in 1 2 3 4; do
    tr_due="$(tr_field 3)"
    tr_dues+=("$tr_due")
    tr_at $(( tr_due - 1 ))
    once
    check "repeat: re-gate $tr_n not asked a second early" "$tr_n" "$(tr_calls)"
    tr_at "$tr_due"
    once
    check "repeat: re-gate $tr_n asked at its due time" "$(( tr_n + 1 ))" "$(tr_calls)"
    contains "repeat: re-gate $tr_n carries its attempt number" "$(cat "$work/once.out")" \
        "agent=tess source=timer attempt=$tr_n"
    check "repeat: the line records attempt $tr_n" "$tr_n" "$(tr_field 4)"
done
check "repeat: due at 5, 15, 35 and 75 minutes after the first defer" \
    "$(( T0 + 300 )) $(( T0 + 900 )) $(( T0 + 2100 )) $(( T0 + 4500 ))" "${tr_dues[*]}"
tr_at $(( T0 + 1000000 ))
once
once
check "repeat: never asked again once the attempts are spent" 5 "$(tr_calls)"
check "repeat: the spent line stays on disk" "tess $tr_mid" "$(deferral_seats "$PM_STATE_DIR/wake-deferred/$tr_tid")"
check "repeat: and nothing spawned" 0 "$(tr_spawns tess)"

tr_store
FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=2 FORK_SANDBOX_WAKE_REGATE_BASE=10 tr_send
FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=2 FORK_SANDBOX_WAKE_REGATE_BASE=10 once
for tr_n in 1 2 3; do
    tr_at $(( T0 + 1000 * tr_n ))
    FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=2 FORK_SANDBOX_WAKE_REGATE_BASE=10 once
done
check "repeat: FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=2 asks twice" 3 "$(tr_calls)"

# ============================================================
printf '\n== timed re-gate: exit 3 drops the line, an unknown exit fails open ==\n'
# ============================================================

tr_store
tr_send
once
echo 3 > "$TR_OUT/verdict"
tr_at $(( T0 + 300 ))
once
contains "exit 3: the skip event" "$(cat "$work/once.out")" "pm skip thread=$tr_short agent=tess reason=wake-when"
check "exit 3: drops the line" 0 "$([[ -e "$PM_STATE_DIR/wake-deferred/$tr_tid" ]] && echo 1 || echo 0)"
check "exit 3: spawns nothing" 0 "$(tr_spawns tess)"

tr_store
tr_send
once
echo 2 > "$TR_OUT/verdict"
tr_at $(( T0 + 300 ))
once
contains "unknown exit: wake-gate-error" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$tr_short agent=tess reason=exit-2"
check "unknown exit: fails open and wakes the seat" 1 "$(tr_spawns tess)"
check "unknown exit: the line is gone" "" "$(tr_line)"

# ============================================================
printf '\n== timed re-gate: a two-field legacy line is re-gated ==\n'
# ============================================================

tr_store
tr_send
once
printf 'tess %s\n' "$tr_mid" > "$PM_STATE_DIR/wake-deferred/$tr_tid"
once
contains "legacy: due now, re-gated as attempt 1" "$(cat "$work/once.out")" \
    "pm regate thread=$tr_short agent=tess source=timer attempt=1"
check "legacy: rewritten with the next due time" "tess $tr_mid $(( T0 + 600 )) 1" "$(tr_line)"

# ============================================================
printf '\n== timed re-gate: closed threads and refused spawns ==\n'
# ============================================================

tr_store
tr_send
once
reply_msg '@ci-demo' "$tr_mid" 'closed' --to '@alice' --upstream-state closed >/dev/null
once
tr_at $(( T0 + 300 ))
: > "$TR_OUT/calls"
once
not_contains "closed: no timed re-gate on a closed thread" "$(cat "$work/once.out")" "pm regate"
check "closed: the gate was not asked" 0 "$(tr_calls)"

# A refused spawn leaves the line standing as the harvest re-gate does, but
# the attempt is spent, so it is not re-gated (and refused) on every pass.
tr_store
printf 'body\n' > "$work/body.tmp"
tr_mid="$("$MAIL" send --from @alice --to '@carol, @tess' --subject 'tight budget' --body "$work/body.tmp" --budget 1 2>/dev/null)"
tr_tid="$(thread_of "$tr_mid")"; tr_short="${tr_tid:0:8}"
once
check "refused: carol spent the thread's one spawn" 1 "$(spawn_count_of "$tr_tid")"
echo 0 > "$TR_OUT/verdict"
tr_at $(( T0 + 300 ))
once
contains "refused: the timed re-gate ran" "$(cat "$work/once.out")" "agent=tess source=timer attempt=1"
contains "refused: the spawn was refused on budget" "$(cat "$work/once.out")" \
    "pm refuse thread=$tr_short agent=tess reason=budget"
check "refused: the line stands, its attempt spent" "tess $tr_mid $(( T0 + 900 )) 1" "$(tr_line)"
once
not_contains "refused: not re-gated again before the next due time" "$(cat "$work/once.out")" "pm regate"

# ============================================================
printf '\n== timed re-gate: FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=0 turns it off ==\n'
# ============================================================

tr_store
tr_send
FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=0 once
tr_at $(( T0 + 1000000 ))
FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=0 once
check "off: the gate ran only on arrival" 1 "$(tr_calls)"
not_contains "off: no regate event" "$(cat "$work/once.out")" "pm regate"

tr_store
tr_send
FORK_SANDBOX_WAKE_REGATE_ATTEMPTS=0 once
check "off: the quiescence flag fires at once" "wake deferred: @tess at $tr_mid and nothing woke it" "$(tr_flag)"

# ============================================================
printf '\n== quiescence flag: waits until the timed re-gates are spent ==\n'
# ============================================================

tr_store
tr_send
once
check "wait: a quiet thread with attempts left is not flagged" "" "$(tr_flag)"
for tr_n in 1 2 3; do
    tr_at "$(tr_field 3)"
    once
    check "wait: still not flagged after re-gate $tr_n" 0 "$(tr_flags)"
done
tr_at "$(tr_field 3)"
once
check "wait: flagged once the last attempt is spent" "wake deferred: @tess at $tr_mid and nothing woke it" "$(tr_flag)"
contains "wait: with the unchanged keyword" "$(cat "$work/once.out")" "pm flag thread=$tr_short reason=wake-deferred"
check "wait: flagged once" 1 "$(tr_flags)"
tr_at $(( T0 + 1000000 ))
once
check "wait: not flagged again" 1 "$(tr_flags)"
check "wait: the spent line still shows in status --json" "[{'agent': 'tess', 'message_id': '$tr_mid'}]" \
    "$(we_py "$(we_json "$tr_tid")" 'd["wake_deferred"]')"

# A fresh defer after the flag starts the count again.
tr_mid2="$(reply_msg '@alice' "$tr_mid" 'again' --to '@tess')"
once
check "wait: a new message's defer resets the spent line" "tess $tr_mid2 $(( T0 + 1000300 )) 0" "$(tr_line)"
check "wait: and the new count is not flagged yet" 1 "$(tr_flags)"

# A legacy line has no attempt spent, so it waits too.
tr_store
tr_send
once
printf 'tess %s\n' "$tr_mid" > "$PM_STATE_DIR/wake-deferred/$tr_tid"
once
check "wait: the legacy line is re-gated, not flagged" "" "$(tr_flag)"
check "wait: and now records attempt 1" 1 "$(tr_field 4)"

finish_suite
