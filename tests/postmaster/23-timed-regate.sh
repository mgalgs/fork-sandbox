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

finish_suite
