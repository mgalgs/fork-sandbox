#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/21-advisory-seats.sh — fork-sandbox-postmaster.sh: a
# seat with `on-failure: note` is advisory. Each failure the postmaster
# attributes to it notes (a `note` event and a "seat notes:" line in
# `status`) instead of flagging the thread needs-operator; the same failure
# of an `on-failure: flag` seat still flags. An existing flag reason
# survives a note, and operator mail clears the notes.
#
# Usage: tests/postmaster/21-advisory-seats.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# nora is advisory, fred is the same seat flagging; both retry a discarded
# reply. hank and hal are the handler pair, both exiting 1. kora is an
# advisory k8s seat (karen, from lib.sh, its flagging twin) and kody an
# advisory grant: required one (karl its twin).
for as_seat in nora fred kora kody; do
    printf 'Advisory fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/$as_seat.md"
done
new_root AS_HANDLERS_DIR
printf '#!/bin/sh\necho handler failed >&2\nexit 1\n' > "$AS_HANDLERS_DIR/failing-handler"
chmod +x "$AS_HANDLERS_DIR/failing-handler"
export FORK_SANDBOX_HANDLERS_DIR="$AS_HANDLERS_DIR"
sed -i 's/^agents:$/agents:\n  nora:\n    on-failure: note\n    on-silence: retry\n  fred:\n    on-failure: flag\n    on-silence: retry\n  hank:\n    handler: exec\n    command: failing-handler\n    on-failure: note\n  hal:\n    handler: exec\n    command: failing-handler\n  kora:\n    backend: k8s\n    on-failure: note\n  kody:\n    backend: k8s\n    grant: required\n    on-failure: note/' "$FORK_SANDBOX_FLEET_FILE"
"$FLEET" check >/dev/null 2>&1 || { echo "FATAL: advisory fixture fleet fails check" >&2; "$FLEET" check >&2; exit 1; }

as_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$STUB_ARGV_LOG"
    : > "$work/events.out"
}
# Every pass's events, kept across passes (once overwrites once.out).
as_once() { once; cat "$work/once.out" >> "$work/events.out"; }
as_flag() { cat "$PM_STATE_DIR/needs-operator/$1" 2>/dev/null || true; }
# as_start <seat>: a fresh store and a thread addressed to <seat>, one pass.
as_start() {
    as_store
    as_mid="$(send_msg '@dana' "@$1" 'advisory topic' 'please review' 8)"
    as_tid="$(thread_of "$as_mid")"
    as_once
}
# as_noted <label> <seat> <keyword>: no flag, exactly one note event with
# the keyword, and the note in `status`.
as_noted() {
    local label="$1" seat="$2" kw="$3"
    check "$label: the thread is not flagged" "" "$(as_flag "$as_tid")"
    check "$label: one note event with keyword $kw" 1 \
        "$(grep -c -- "^pm note thread=${as_tid:0:8} agent=$seat reason=$kw\$" "$work/events.out")"
    local st
    st="$("$postmaster" status 2>&1)"
    contains "$label: status has a seat notes section" "$st" $'\nseat notes:\n'
    contains "$label: status lists the note" "$st" "  $as_tid: $seat $kw at "
}
# as_notes_py <expr>: <expr> over `status --thread --json` (as d) for the
# current thread.
as_notes_py() { we_py "$("$postmaster" status --thread "$as_tid" --json)" "$1"; }
# as_flagged <label> <reason substring>: the flag seat's thread is flagged.
as_flagged() {
    contains "$1: the flag seat flags the thread" "$(as_flag "$as_tid")" "$2"
    not_contains "$1: the flag seat writes no note" "$(cat "$work/events.out")" "pm note "
}
as_ps_bad() {
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "$(live_env_for_agent "$1")")"
    mkdir -p -- "$rd/outbox"
    printf 'this line is not a header\n\nbody\n' > "$rd/outbox/mail-1.md"
    printf '0\n' > "$rd/exit-code"
    printf '{}\n' > "$rd/summary.json"
}
as_dead() {
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "$(live_env_for_agent "$1")")"
    printf '%s\n' "$(dead_pid_of)" > "$rd/pid"
    FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE=0 as_once
}

# ============================================================
printf '\n== advisory seat: a wake that exits non-zero ==\n'
# ============================================================

as_start nora
check "seat_notes: an empty list on a thread with no notes" '[]' \
    "$(as_notes_py 'json.dumps(d["seat_notes"])')"
as_rid="$(basename -- "$(env_file_for_agent nora)" .env)"
finish_run nora 1
as_once
as_noted "wake exit" nora wake-exit
check "seat_notes: one note after the failed wake" 1 "$(as_notes_py 'len(d["seat_notes"])')"
check "seat_notes: the note names the bare seat" nora "$(as_notes_py 'd["seat_notes"][0]["agent"]')"
check "seat_notes: the note's reason is its keyword" wake-exit "$(as_notes_py 'd["seat_notes"][0]["reason"]')"
check "seat_notes: a harvest-path note carries the failed run's id" "$as_rid" \
    "$(as_notes_py 'd["seat_notes"][0]["run_id"]')"
check "seat_notes: at is the stored time" "$(cut -f1 "$PM_STATE_DIR/seat-notes/$as_tid/nora")" \
    "$(as_notes_py 'd["seat_notes"][0]["at"]')"
contains "seat_notes: the text status shows no run id" "$("$postmaster" status 2>&1)" \
    $'  '"$as_tid: nora wake-exit at $(cut -f1 "$PM_STATE_DIR/seat-notes/$as_tid/nora")"$'\n'
check "wake exit: the crash retry is still scheduled" pending \
    "$(env_val "$PM_STATE_DIR/retries/$as_tid/nora" STATE)"
check "wake exit: the wake-exit record is still kept" 1 \
    "$(find "$PM_STATE_DIR/wake-exits/$as_tid/nora" -name '*.json' | wc -l)"

as_start fred
finish_run fred 1
as_once
as_flagged "wake exit" "wake for fred exited 1"

# ============================================================
printf '\n== advisory seat: a wake that never produced summary.json ==\n'
# ============================================================

as_start nora
as_dead nora
as_noted "no summary" nora no-summary

as_start fred
as_dead fred
as_flagged "no summary" "wake never produced summary.json"

# ============================================================
printf '\n== advisory seat: a silent wake under on-silence ==\n'
# ============================================================

as_start nora
finish_run nora 0
as_once
as_noted "silent wake" nora silent-wake

as_start fred
finish_run fred 0
as_once
as_flagged "silent wake" "wake for fred posted no reply"

# ============================================================
printf '\n== advisory seat: a discarded reply (harvest check) ==\n'
# ============================================================

as_start nora
as_ps_bad nora
as_once
as_noted "discarded reply" nora malformed-reply
check "discarded reply: on-silence: retry still re-wakes the seat" malformed \
    "$(env_val "$PM_STATE_DIR/retries/$as_tid/nora" REASON)"

as_start fred
as_ps_bad fred
as_once
as_flagged "discarded reply" "malformed reply file mail-1.md"

# ============================================================
printf '\n== advisory seat: crash-retry exhaustion ==\n'
# ============================================================

# An empty backoff list is a cap of 0: the first failure exhausts.
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=
as_start nora
finish_run nora 1
as_once
as_noted "retry exhaustion" nora retry-exhausted
check "retry exhaustion: the retry record is still exhausted" exhausted \
    "$(env_val "$PM_STATE_DIR/retries/$as_tid/nora" STATE)"

as_start fred
finish_run fred 1
as_once
as_flagged "retry exhaustion" "wake for fred failed after 0 retries"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ============================================================
printf '\n== advisory seat: any other failure on the seat'"'"'s behalf (spawn, handler) ==\n'
# ============================================================

as_saved_launcher="$FORK_SANDBOX_POSTMASTER_LAUNCHER"
printf '#!/bin/sh\necho launch refused >&2\nexit 1\n' > "$STUB_BIN/failing-launcher"
chmod +x "$STUB_BIN/failing-launcher"
export FORK_SANDBOX_POSTMASTER_LAUNCHER="$STUB_BIN/failing-launcher"
as_start nora
as_noted "spawn failure" nora spawn-failed
as_start fred
as_flagged "spawn failure" "spawn failed for fred"
export FORK_SANDBOX_POSTMASTER_LAUNCHER="$as_saved_launcher"

as_start hank
as_noted "handler exit" hank handler-exit
as_start hal
as_flagged "handler exit" "handler 'failing-handler' for hal exited 1"

# ============================================================
printf '\n== advisory seat: a run dir that vanishes ==\n'
# ============================================================

as_rm_rundir() { rm -rf -- "$(sed -n 's/^RUN_DIR=//p' "$(env_file_for_agent "$1")")"; }

as_start nora
as_rm_rundir nora
as_once
as_noted "run vanished" nora run-vanished

as_start fred
as_rm_rundir fred
as_once
as_flagged "run vanished" "run dir for fred vanished"

# ---- the k8s seats: this section owns its k8s seams, as 14-wake-exit.sh does ----
k8s_wake_fixture
export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"
new_root FORK_SANDBOX_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR

# ============================================================
printf '\n== advisory seat: a k8s wake that timed out on its Job ==\n'
# ============================================================

as_timeout() {
    STUB_K8S_EXIT=1 STUB_K8S_NO_SUMMARY=1 STUB_K8S_NO_REPLY=1 STUB_K8S_TIMEOUT_MSG=1 as_start "$1"
}
as_timeout kora
as_noted "k8s timeout" kora k8s-timeout
as_timeout karen
as_flagged "k8s timeout" "k8s wake for karen timed out waiting on its Job"

# ============================================================
printf '\n== advisory seat: a k8s seat stopped after a failure streak ==\n'
# ============================================================

# Each failure carries Kubernetes evidence, and each lands on a new
# trigger, so the per-trigger retry cap (2) never stops the seat: the
# streak does, on the third. The two passes after it re-run the streak
# check before a spawn that never happens, and must not note again.
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
as_k8s_status="$work/as-status-evicted.json"
printf '%s\n' '{"pod_phase":"Failed","pod_reason":"Evicted","pod_message":"node low on ephemeral-storage"}' > "$as_k8s_status"
as_streak() {
    local seat="$1" n
    as_store
    as_mid="$(send_msg '@dana' "@$seat" 'advisory streak' 'first' 8)"
    as_tid="$(thread_of "$as_mid")"
    for n in 1 2 3 4 5; do
        (( n == 1 )) || reply_msg '@dana' "$as_mid" "trigger $n" --to "@$seat" >/dev/null
        STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$as_k8s_status" as_once
    done
}
as_streak kora
as_noted "k8s streak" kora k8s-failure-streak
check "k8s streak: the seat is still stopped (retry state exhausted)" exhausted \
    "$(env_val "$PM_STATE_DIR/retries/$as_tid/kora" STATE)"
check "k8s streak: no launch past the streak" 3 \
    "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
as_streak karen
as_flagged "k8s streak" "wake for karen stopped after 3 consecutive Kubernetes failures"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ============================================================
printf '\n== advisory seat: a grant: required k8s seat with no grant ==\n'
# ============================================================

as_start kody
as_noted "no grant" kody no-grant
check "seat_notes: a note from a non-run path has run_id null" None \
    "$(as_notes_py 'd["seat_notes"][0]["run_id"]')"
check "no grant: the seat is still held" 1 \
    "$([[ -f "$PM_STATE_DIR/held/$as_tid/kody" ]] && echo 1 || echo 0)"
as_once
check "no grant: a second pass notes nothing more" 1 \
    "$(grep -c -- "^pm note thread=${as_tid:0:8} agent=kody reason=no-grant\$" "$work/events.out")"
as_start karl
as_flagged "no grant" "no grant for k8s seat karl"

# ============================================================
printf '\n== advisory seat: thread-level flags stay flags ==\n'
# ============================================================

as_store
as_mid="$(send_msg '@dana' '@nora' 'advisory topic' 'no hops left' 0)"
as_tid="$(thread_of "$as_mid")"
as_once
contains "hops: a thread-level flag still flags on an advisory seat's wake" \
    "$(as_flag "$as_tid")" "hops exhausted"

# ============================================================
printf '\n== advisory seat: an existing flag reason survives a note ==\n'
# ============================================================

as_start nora
"$postmaster" flag "$as_tid" "held by the operator" >/dev/null 2>&1
finish_run nora 1
as_once
check "existing flag: the reason is untouched by the seat's failure" \
    "held by the operator" "$(as_flag "$as_tid")"
check "existing flag: the failure is noted" 1 \
    "$(grep -c -- "^pm note thread=${as_tid:0:8} agent=nora reason=wake-exit\$" "$work/events.out")"
check "existing flag: nothing new is journaled as a flag" 1 \
    "$(awk -F'\t' '$2=="flag"' "$PM_STATE_DIR/needs-operator-journal/$as_tid" | wc -l)"

# ============================================================
printf '\n== advisory seat: operator mail clears the notes ==\n'
# ============================================================

as_start nora
finish_run nora 1
as_once
check "operator mail: the note is there first" 1 \
    "$(wc -l < "$PM_STATE_DIR/seat-notes/$as_tid/nora")"
reply_msg '@operator' "$as_mid" 'seen it' --to '@operator' >/dev/null
as_once
check "operator mail: seat_notes is empty again" '[]' \
    "$(as_notes_py 'json.dumps(d["seat_notes"])')"
check "operator mail: the thread's notes are gone" no \
    "$([[ -e "$PM_STATE_DIR/seat-notes/$as_tid" ]] && echo yes || echo no)"
not_contains "operator mail: status lists no seat notes" "$("$postmaster" status 2>&1)" "seat notes:"

as_start nora
finish_run nora 1
as_once
"$postmaster" unflag "$as_tid" >/dev/null 2>&1
check "unflag: the operator verb clears the notes too" no \
    "$([[ -e "$PM_STATE_DIR/seat-notes/$as_tid" ]] && echo yes || echo no)"

# ============================================================
printf '\n== advisory seat: seat_notes order and the two-column line ==\n'
# ============================================================

# Hand-written lines: the seat whose file globs first holds the newer note,
# and one line is the two-column shape written before notes carried a run id.
as_start nora
mkdir -p -- "$PM_STATE_DIR/seat-notes/$as_tid"
printf '2026-01-02T00:00:00Z\tspawn-failed\n' > "$PM_STATE_DIR/seat-notes/$as_tid/aria"
printf '2026-01-01T00:00:00Z\twake-exit\trun-older\n2026-01-03T00:00:00Z\tno-summary\trun-newer\n' \
    > "$PM_STATE_DIR/seat-notes/$as_tid/zed"
check "seat_notes: oldest first across seats" "zed aria zed" \
    "$(as_notes_py '" ".join(n["agent"] for n in d["seat_notes"])')"
check "seat_notes: a two-column line reads with run_id null" None \
    "$(as_notes_py 'd["seat_notes"][1]["run_id"]')"
check "seat_notes: three-column lines keep their run ids" "run-older run-newer" \
    "$(as_notes_py '" ".join(d["seat_notes"][i]["run_id"] for i in (0, 2))')"
check "seat_notes: exactly the agreed keys" "agent at reason run_id" \
    "$(as_notes_py '" ".join(sorted(d["seat_notes"][0]))')"
contains "seat_notes: the text status reads the three-column line unchanged" \
    "$("$postmaster" status 2>&1)" "  $as_tid: zed no-summary at 2026-01-03T00:00:00Z"$'\n'

finish_suite
