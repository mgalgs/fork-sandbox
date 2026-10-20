#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/13-hooks.sh — fork-sandbox-postmaster.sh: hooks (runner,
# on-target, on-quiescent) and the wake gate.
#
# Usage: tests/postmaster/13-hooks.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

k8s_wake_fixture  # no wake may reach the real k8s wrapper; see lib.sh

# ============================================================
printf '\n== hooks: the detached runner, its timeout, its records and its event line ==\n'
# ============================================================

hk_lock_and_fire() { pm_lock_acquire && pm_hook_fire on-target "$HK_TID"; }
hk_lock_and_say() { pm_lock_acquire && echo locked; }

new_scratch_root HK_ROOT
export FORK_SANDBOX_MAIL_ROOT="$HK_ROOT"
new_root HK_DIR
HK_TID="aaaaaaaa-1111-4111-8111-000000000001"
HK_STATE="$HK_ROOT/.postmaster"

out="$(hk_call pm_hook_fire on-target "$HK_TID" 2>&1)"
check "hooks: no hook file, no event line" "" "$out"
check "hooks: no hook file, no record" "no" "$([[ -e "$HK_STATE/hooks" ]] && echo yes || echo no)"

printf '#!/usr/bin/env bash\nexit 0\n' > "$HK_DIR/on-target"
chmod -x "$HK_DIR/on-target"
out="$(hk_call pm_hook_fire on-target "$HK_TID" 2>&1)"
check "hooks: a non-executable hook is silent" "" "$out"
check "hooks: a non-executable hook leaves no record" "no" "$([[ -e "$HK_STATE/hooks" ]] && echo yes || echo no)"

printf '#!/usr/bin/env bash\necho "hook says hi"\nexit 3\n' > "$HK_DIR/on-target"
chmod +x "$HK_DIR/on-target"
export FORK_SANDBOX_POSTMASTER_HOOK_DETACH=inline
out="$(hk_call pm_hook_fire on-target "$HK_TID" 2>&1)"
check "hooks: an inline hook that exits 3 is reaped with its status" \
    "pm hook thread=aaaaaaaa hook=on-target file=on-target exit=3" "$out"
check "hooks: the record dir is gone after the reap" "0" \
    "$(find "$HK_STATE/hooks/run" -mindepth 1 -maxdepth 1 | wc -l)"
check "hooks: the log is kept under hooks/logs" "hook says hi" \
    "$(cat "$HK_STATE"/hooks/logs/*-on-target-aaaaaaaa-*.log)"

printf '#!/usr/bin/env bash\nsleep 20\n' > "$HK_DIR/on-target"
out="$(FORK_SANDBOX_HOOK_TIMEOUT=1 hk_call pm_hook_fire on-target "$HK_TID" 2>&1)"
check "hooks: a hook that outlives FORK_SANDBOX_HOOK_TIMEOUT reads exit=timeout" \
    "pm hook thread=aaaaaaaa hook=on-target file=on-target exit=timeout" "$out"

# Several files per event: on-<event> and on-<event>.<anything>, in name order.
rm -f "$HK_DIR"/on-target*
for hk_f in on-target.b on-target on-target.a; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HK_DIR/$hk_f"
    chmod +x "$HK_DIR/$hk_f"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$HK_DIR/on-targetx"; chmod +x "$HK_DIR/on-targetx"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HK_DIR/on-target.off"
out="$(hk_call pm_hook_fire on-target "$HK_TID" 2>&1)"
check "hooks: on-<event> and on-<event>.* fire in name order, one line each" \
    "pm hook thread=aaaaaaaa hook=on-target file=on-target exit=0
pm hook thread=aaaaaaaa hook=on-target file=on-target.a exit=0
pm hook thread=aaaaaaaa hook=on-target file=on-target.b exit=0" "$out"
unset FORK_SANDBOX_POSTMASTER_HOOK_DETACH

# Detached: returns at once, and the child holds no store lock.
rm -f "$HK_DIR"/on-target*
printf '#!/usr/bin/env bash\ntrap '"'"'kill $!'"'"' TERM\nsleep 20 &\nwait\n' > "$HK_DIR/on-target"
chmod +x "$HK_DIR/on-target"
hk_start="$(date +%s)"
hk_call hk_lock_and_fire >/dev/null 2>&1 || true
hk_took=$(( $(date +%s) - hk_start ))
check "hooks: a detached fire returns without waiting for the hook" "yes" "$( (( hk_took < 10 )) && echo yes)"
hk_rc2=0
hk_out2="$(hk_call hk_lock_and_say 2>&1)" || hk_rc2=$?
check "hooks: a running detached hook does not hold the store lock" "0:locked" "$hk_rc2:$hk_out2"
hk_recs="$(find "$HK_STATE/hooks/run" -mindepth 1 -maxdepth 1 | wc -l)"
check "hooks: the running detached hook has a record" "1" "$hk_recs"
pkill -f "$HK_DIR/on-target" 2>/dev/null || true
sleep 1
out="$(hk_call pm_hook_reap 2>&1)"
contains "hooks: a killed detached hook is reaped, not left behind" "$out" "hook=on-target file=on-target exit="
check "hooks: nothing is left in run/ after that reap" "0" \
    "$(find "$HK_STATE/hooks/run" -mindepth 1 -maxdepth 1 | wc -l)"

# A record whose process is gone and that never wrote exit.
hk_dead="$HK_STATE/hooks/run/1-on-quiescent-aaaaaaaa-1"
mkdir -p "$hk_dead"
printf 'on-quiescent\n' > "$hk_dead/event"
printf 'on-quiescent\n' > "$hk_dead/file"
printf '%s\n' "$HK_TID" > "$hk_dead/thread"
: > "$hk_dead/log"
sleep 0 & hk_pid=$!; wait "$hk_pid"
printf '%s\n' "$hk_pid" > "$hk_dead/pid"
out="$(hk_call pm_hook_reap 2>&1)"
check "hooks: a dead pid with no exit is reaped as lost" \
    "pm hook thread=aaaaaaaa hook=on-quiescent file=on-quiescent exit=lost" "$out"
check "hooks: the lost record's log is kept" "yes" \
    "$([[ -e "$HK_STATE/hooks/logs/1-on-quiescent-aaaaaaaa-1.log" ]] && echo yes || echo no)"

# The log directory keeps the newest 100.
for (( hk_i = 0; hk_i < 105; hk_i++ )); do : > "$HK_STATE/hooks/logs/old-$hk_i.log"; done
hk_call pm_hook_reap >/dev/null 2>&1
check "hooks: hooks/logs keeps the newest 100 files" "100" \
    "$(find "$HK_STATE/hooks/logs" -type f | wc -l)"

# ============================================================
printf '\n== hooks: on-target and on-quiescent are detected, once per change ==\n'
# ============================================================

hk_finish_runs() {
    local f rd
    for f in "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env; do
        [[ -e "$f" ]] || continue
        [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested/$(basename "$f" .env)" ]] && continue
        rd="$(sed -n 's/^RUN_DIR=//p' "$f")"
        mkdir -p -- "$rd/outbox"
        printf '0\n' > "$rd/exit-code"
        printf '{}\n' > "$rd/summary.json"
    done
}
hk_target_sha="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
HK_ST="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
hk_install on-target on-quiescent
once
printf '%s\n' 'review this' > "$work/body.tmp"
hk_mid="$("$MAIL" send --from '@alice' --to '@carol' --subject 'hook detect' \
    --body "$work/body.tmp" --hops 8 --review-target "hk-branch:$hk_target_sha" 2>/dev/null)"
hk_tid="$(thread_of "$hk_mid")"
once
check "hooks: the kickoff's target fires on-target once" 1 "$(hk_count on-target)"
check "on-target: VERSION is 1" 1 "$(hk_env on-target FS_TARGET_VERSION)"
check "on-target: BRANCH" "hk-branch" "$(hk_env on-target FS_TARGET_BRANCH)"
check "on-target: SHA" "$hk_target_sha" "$(hk_env on-target FS_TARGET_SHA)"
check "on-target: SHA_PRESENT is 1 for a commit in the repo" 1 "$(hk_env on-target FS_TARGET_SHA_PRESENT)"
check "on-quiescent: not while a run is live" 0 "$(hk_count on-quiescent)"
once
check "on-target: the next pass does not fire it again" 1 "$(hk_count on-target)"
hk_finish_runs
once
check "on-quiescent: fires once the run is harvested" 1 "$(hk_count on-quiescent)"
check "on-quiescent: FS_HOOK_MESSAGE_COUNT" 1 "$(hk_env on-quiescent FS_HOOK_MESSAGE_COUNT)"
check "on-quiescent: FS_HOOK_FLAGGED is 0" 0 "$(hk_env on-quiescent FS_HOOK_FLAGGED)"
check "on-quiescent: the target env rides along on every event" 1 "$(hk_env on-quiescent FS_TARGET_VERSION)"
once
check "on-quiescent: not again on the next pass" 1 "$(hk_count on-quiescent)"

# A new message the debounce gate holds is unrouted: not quiescent.
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=300
reply_msg '@alice' "$hk_mid" 'more thoughts' --to '@carol' >/dev/null
once
check "on-quiescent: not while a message is unrouted (debounce)" 1 "$(hk_count on-quiescent)"
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0
once
check "on-quiescent: not while the woken run is live" 1 "$(hk_count on-quiescent)"
hk_finish_runs
once
check "on-quiescent: fires again after a new message cycle" 2 "$(hk_count on-quiescent)"
check "on-quiescent: the count moved to 2" 2 "$(hk_env on-quiescent FS_HOOK_MESSAGE_COUNT)"
check "on-target: no new target, no new on-target" 1 "$(hk_count on-target)"

# The blockers, asked directly.
hk_q() { pm_thread_is_quiescent "$hk_tid" && echo yes || echo no; }
check "quiescence: an idle thread is quiescent" yes "$(hk_call hk_q)"
mkdir -p "$HK_ST/retries/$hk_tid"; printf 'STATE=pending\n' > "$HK_ST/retries/$hk_tid/carol"
check "quiescence: a pending retry blocks it" no "$(hk_call hk_q)"
printf 'STATE=recovered\nTRIGGER=x\nATTEMPT=1\nRECOVERED_AT=1\n' > "$HK_ST/retries/$hk_tid/carol"
printf 'STATE=exhausted\nTRIGGER=x\nATTEMPT=3\n' > "$HK_ST/retries/$hk_tid/dave"
printf 'FAILS=2\n' > "$HK_ST/retries/$hk_tid/erin"
check "quiescence: recovered, exhausted and FAILS-only records do not block it" yes "$(hk_call hk_q)"
rm -rf "$HK_ST/retries/$hk_tid"
mkdir -p "$HK_ST/held/$hk_tid"; printf 'TRIGGER=x\n' > "$HK_ST/held/$hk_tid/carol"
check "quiescence: a held seat blocks it" no "$(hk_call hk_q)"
rm -rf "$HK_ST/held/$hk_tid"
check "quiescence: clear again" yes "$(hk_call hk_q)"

# A flagged thread can settle; the hook is told.
"$postmaster" flag "$hk_tid" "needs a human" >/dev/null 2>&1
rm -f "$HK_ST/hook-marks/quiescent/$hk_tid"
once
check "on-quiescent: a flagged thread that settles fires" 3 "$(hk_count on-quiescent)"
check "on-quiescent: FS_HOOK_FLAGGED is 1" 1 "$(hk_env on-quiescent FS_HOOK_FLAGGED)"
check "on-quiescent: FS_HOOK_FLAG_REASON is the flag's content" "needs a human" "$(hk_env on-quiescent FS_HOOK_FLAG_REASON)"

# Manual re-fire: same env, markers untouched, foreground, no lock, no record.
hk_mark_before="$(cat "$HK_ST/hook-marks/target/$hk_tid")"
hk_out="$("$postmaster" hook fire --thread "$hk_tid" --event on-target 2>/dev/null)"; hk_rc=$?
check "hook fire: on-target prints one file line" "file=on-target exit=0" "$hk_out"
check "hook fire: exit 0 when the hook succeeded" 0 "$hk_rc"
check "hook fire: the hook ran (count moved)" 2 "$(hk_count on-target)"
check "hook fire: SHA_PRESENT is computed (deliver recorded the project)" 1 "$(hk_env on-target FS_TARGET_SHA_PRESENT)"
check "hook fire: the target marker is untouched" "$hk_mark_before" "$(cat "$HK_ST/hook-marks/target/$hk_tid")"
check "hook fire: no hook record is written" 0 "$(find "$HK_ST/hooks/run" -mindepth 1 2>/dev/null | wc -l)"
hk_out="$("$postmaster" hook fire --thread "$hk_tid" --event on-quiescent 2>/dev/null)"
check "hook fire: on-quiescent prints one file line" "file=on-quiescent exit=0" "$hk_out"
check "hook fire: on-quiescent carries the current count" 2 "$(hk_env on-quiescent FS_HOOK_MESSAGE_COUNT)"
check "hook fire: on-quiescent carries the flag state" 1 "$(hk_env on-quiescent FS_HOOK_FLAGGED)"
printf '#!/usr/bin/env bash\nexit 3\n' > "$HK_DIR/on-target.zz-fail"; chmod +x "$HK_DIR/on-target.zz-fail"
hk_out="$("$postmaster" hook fire --thread "$hk_tid" --event on-target 2>/dev/null)"; hk_rc=$?
check "hook fire: one line per file, in order" "file=on-target exit=0
file=on-target.zz-fail exit=3" "$hk_out"
check "hook fire: non-zero when any hook failed" 1 "$hk_rc"
rm -f "$HK_DIR/on-target.zz-fail"
hk_rc=0; "$postmaster" hook fire --thread "$hk_tid" --event on-harvest >/dev/null 2>&1 || hk_rc=$?
check "hook fire: on-harvest is refused" 2 "$hk_rc"
hk_uninstall

# SHA_PRESENT is 0 for a sha that is not in the repo, and the hook still fires.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
hk_install on-target
once
hk_mid="$("$MAIL" send --from '@alice' --to '@carol' --subject 'hook missing sha' \
    --body "$work/body.tmp" --hops 8 --review-target "hk-missing:1111111111111111111111111111111111111111" 2>/dev/null)"
once
check "on-target: fires for a sha that is absent" 1 "$(hk_count on-target)"
check "on-target: SHA_PRESENT is 0 for it" 0 "$(hk_env on-target FS_TARGET_SHA_PRESENT)"
hk_uninstall

# Seeding: a store with a target and a finished thread before the first
# hook-aware pass fires nothing; later activity does.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
HK_ST="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
hk_mid="$("$MAIL" send --from '@alice' --to '@carol' --subject 'hook seed' \
    --body "$work/body.tmp" --hops 8 --review-target "hk-branch:$hk_target_sha" 2>/dev/null)"
hk_tid="$(thread_of "$hk_mid")"
once
hk_finish_runs
once
rm -rf "$HK_ST/hook-marks"
hk_install on-target on-quiescent
once
check "seeding: an old target fires nothing" 0 "$(hk_count on-target)"
check "seeding: an old finished thread fires nothing" 0 "$(hk_count on-quiescent)"
once
check "seeding: nor does the next pass" 0 "$(hk_count on-quiescent)"
reply_msg '@alice' "$hk_mid" 'fresh activity' --to '@carol' >/dev/null
once
hk_finish_runs
once
check "seeding: new activity then a harvest fires on-quiescent" 1 "$(hk_count on-quiescent)"
check "seeding: and still no on-target" 0 "$(hk_count on-target)"
hk_uninstall

# ============================================================
printf '\n== wake gate: wake-when.<suffix> guards a seat spawn ==\n'
# ============================================================

# Seats are added to the fleet for this group only (a bare persona file is
# an agent too, so those are removed again at the end).
wg_saved_fleet="$(cat "$FORK_SANDBOX_FLEET_FILE")"
for wg_seat in hana hugo hera; do
    printf 'Gate fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/$wg_seat.md"
done
sed -i 's/^agents:$/agents:\n  hana:\n    wake-when: gate\n  hugo:\n    wake-when: absent\n  hera:\n    wake-when: noexec/' \
    "$FORK_SANDBOX_FLEET_FILE"
new_root WG_HOOKS
new_root WG_OUT
# shellcheck disable=SC2031  # the subshell is hk_call's, not this scope
export WG_OUT FORK_SANDBOX_HOOKS_DIR="$WG_HOOKS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WG_HOOKS/wake-when.noexec"

# wg_gate <body>: installs wake-when.gate; every run is logged to $WG_OUT/calls.
wg_gate() {
    # shellcheck disable=SC2016  # expands in the gate, not here
    printf '#!/usr/bin/env bash\necho "$FS_HOOK_AGENT" >> "$WG_OUT/calls"\n%s\n' "$1" > "$WG_HOOKS/wake-when.gate"
    chmod +x "$WG_HOOKS/wake-when.gate"
}
wg_calls() { [[ -f "$WG_OUT/calls" ]] && wc -l < "$WG_OUT/calls" || echo 0; }
wg_spawns() { grep -c -- "^sbx-mail-${short}-$1-" "$STUB_ARGV_LOG" || true; }
wg_new_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    WG_STATE="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$WG_OUT/calls"
    : > "$STUB_ARGV_LOG"
}
wg_finish_run() {
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "$(env_file_for_agent "$1")")"
    mkdir -p -- "$rd/outbox"
    printf '0\n' > "$rd/exit-code"
    printf '{}\n' > "$rd/summary.json"
    printf '\nAcknowledged, thanks.\n' > "$rd/outbox/mail-1.md"
}

wg_new_store
wg_gate 'exit 0'
mid="$(send_msg '@alice' '@hana' 'gate wakes' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: exit 0 wakes the seat" 1 "$(wg_spawns hana)"
check "wake gate: exit 0 spends a budget slot" 1 "$(spawn_count_of "$tid")"
check "wake gate: the gate ran once" 1 "$(wg_calls)"

wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@hana' 'gate defers' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: exit 1 defers (no spawn)" 0 "$(wg_spawns hana)"
check "wake gate: exit 1 spends no budget slot" 0 "$(spawn_count_of "$tid")"
contains "wake gate: exit 1 emits the defer event" "$(cat "$work/once.out")" \
    "pm defer thread=$short agent=hana reason=wake-when"
check "wake gate: a deferred message is routed, not retried every pass" 1 \
    "$( [[ -e "$WG_STATE/routed/$mid" ]] && echo 1 || echo 0 )"
check "wake gate: the gate's output is logged under hooks/logs" 1 \
    "$(find "$WG_STATE/hooks/logs" -name '*-wake-when-*' | wc -l)"

wg_new_store
wg_gate 'exit 3'
mid="$(send_msg '@alice' '@hana' 'gate errors' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: exit 3 fails open (spawns)" 1 "$(wg_spawns hana)"
contains "wake gate: exit 3 emits wake-gate-error" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$short agent=hana reason=exit-3"
not_contains "wake gate: exit 3 is not a defer" "$(cat "$work/once.out")" "pm defer"

wg_new_store
wg_gate 'sleep 30'
mid="$(send_msg '@alice' '@hana' 'gate hangs' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_t0="$(date +%s)"
FORK_SANDBOX_WAKE_GATE_TIMEOUT=1 once
wg_took=$(( $(date +%s) - wg_t0 ))
check "wake gate: a timeout fails open (spawns)" 1 "$(wg_spawns hana)"
contains "wake gate: a timeout emits wake-gate-error" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$short agent=hana reason=timeout"
check "wake gate: a hung gate does not wedge the postmaster" yes "$( (( wg_took < 15 )) && echo yes)"
check "wake gate: the context dir is gone after a timeout" 0 \
    "$(find "$WG_STATE" -maxdepth 1 -name 'wake-gate.*' | wc -l)"

wg_new_store
mid="$(send_msg '@alice' '@hugo' 'gate missing' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: a missing hook fails open (spawns)" 1 "$(wg_spawns hugo)"
contains "wake gate: a missing hook emits wake-gate-error" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$short agent=hugo reason=missing"
wg_new_store
mid="$(send_msg '@alice' '@hera' 'gate not executable' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: a non-executable hook fails open (spawns)" 1 "$(wg_spawns hera)"
contains "wake gate: a non-executable hook reports missing" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$short agent=hera reason=missing"

wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@operator' '@hana' 'operator mail' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: operator mail bypasses the gate (spawns)" 1 "$(wg_spawns hana)"
check "wake gate: operator mail never ran the gate" 0 "$(wg_calls)"

wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@carol' 'ungated seat' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: a seat without wake-when spawns as before" 1 "$(wg_spawns carol)"
check "wake gate: a seat without wake-when never runs a gate" 0 "$(wg_calls)"

wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@hana' 'retry bypass' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: the retry's first wake was deferred" 0 "$(wg_spawns hana)"
mkdir -p -- "$WG_STATE/retries/$tid"
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$mid" > "$WG_STATE/retries/$tid/hana"
once
check "wake gate: a retry of a failed wake is not gated" 1 "$(wg_spawns hana)"
check "wake gate: the retry never ran the gate" 1 "$(wg_calls)"

wg_new_store
wg_gate 'exit 0'
mid="$(send_msg '@alice' '@hana' 'live seat' 'first' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: live-run setup spawned" 1 "$(wg_spawns hana)"
wg_gate 'exit 1'
: > "$WG_OUT/calls"
mid2="$(reply_msg '@alice' "$mid" 'second' --to '@hana')"
: > "$STUB_ARGV_LOG"
once
check "wake gate: a seat with a live run gets no second spawn" 0 "$(wg_spawns hana)"
check "wake gate: delivery to a live run never runs the gate" 0 "$(wg_calls)"
contains "wake gate: the message is pended on the live run" \
    "$(cat "$(env_file_for_agent hana)")" "PENDING_MSGS=$mid2"
wg_finish_run hana
: > "$STUB_ARGV_LOG"
once
check "wake gate: the pending follow-up wake is gated" 1 "$(wg_calls)"
check "wake gate: a deferred follow-up does not spawn" 0 "$(wg_spawns hana)"
contains "wake gate: a deferred follow-up emits defer" "$(cat "$work/once.out")" \
    "pm defer thread=$short agent=hana reason=wake-when"
: > "$STUB_ARGV_LOG"
once
check "wake gate: the dropped pending message is not woken later" 0 "$(wg_spawns hana)"

wg_new_store
wg_gate 'exit 0'
mid="$(send_msg '@alice' '@hana' 'live seat allowed' 'first' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
mid2="$(reply_msg '@alice' "$mid" 'second' --to '@hana')"
once
wg_finish_run hana
: > "$STUB_ARGV_LOG"
: > "$WG_OUT/calls"
once
check "wake gate: an allowed follow-up wake runs the gate" 1 "$(wg_calls)"
check "wake gate: an allowed follow-up wake spawns" 1 "$(wg_spawns hana)"

wg_new_store
# shellcheck disable=SC2016  # expands in the gate, not here
wg_gate 'env | grep "^FS_" | sort > "$WG_OUT/env"
cp "$FS_HOOK_EXPORT_FILE" "$WG_OUT/export.json"
cp "$FS_HOOK_STATUS_FILE" "$WG_OUT/status.json"
cp "$FS_HOOK_MESSAGE_FILE" "$WG_OUT/message.msg"
dirname "$FS_HOOK_EXPORT_FILE" > "$WG_OUT/ctxdir"
exit 1'
# carol spawns first and stays live, so the thread is not quiescent and the
# post-defer state (no flag) is the state the gate saw.
mid="$(send_msg '@alice' '@carol,@hana' 'gate context' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
wg_env() { sed -n "s/^$1=//p" "$WG_OUT/env"; }
check "wake gate env: FS_HOOK_EVENT" "wake-when" "$(wg_env FS_HOOK_EVENT)"
check "wake gate env: FS_HOOK_THREAD" "$tid" "$(wg_env FS_HOOK_THREAD)"
check "wake gate env: FS_HOOK_AGENT" "hana" "$(wg_env FS_HOOK_AGENT)"
check "wake gate env: FS_HOOK_MESSAGE" "$mid" "$(wg_env FS_HOOK_MESSAGE)"
check "wake gate env: FS_HOOK_MAIL_ROOT" "$FORK_SANDBOX_MAIL_ROOT" "$(wg_env FS_HOOK_MAIL_ROOT)"
check "wake gate env: FS_HOOK_REPO" "$PROJECT_DIR" "$(wg_env FS_HOOK_REPO)"
case "$(wg_env FS_HOOK_MESSAGE_FILE)" in
    /*) ok "wake gate env: FS_HOOK_MESSAGE_FILE is absolute" ;;
    *) no "wake gate env: FS_HOOK_MESSAGE_FILE is absolute" "got '$(wg_env FS_HOOK_MESSAGE_FILE)'" ;;
esac
check "wake gate: FS_HOOK_MESSAGE_FILE was a readable copy of the trigger" "$mid" \
    "$(sed -n 's/^Message-ID: //p' "$WG_OUT/message.msg")"
check "wake gate: the export file is what mail export --json prints" same \
    "$("$MAIL" export "$tid" --json > "$work/export.cmp" 2>/dev/null; cmp -s "$work/export.cmp" "$WG_OUT/export.json" && echo same || echo differ)"
check "wake gate: the export file is not empty" yes "$( [[ -s "$WG_OUT/export.json" ]] && echo yes)"
# The gate's own defer is recorded after it answers, so only wake_deferred
# (which lists it) may differ between what the gate saw and what status prints.
wg_status_norm() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("wake_deferred"); print(json.dumps(d, sort_keys=True))' "$1"; }
"$postmaster" status --thread "$tid" --json > "$work/status.cmp" 2>/dev/null
check "wake gate: the status file is what status --thread --json prints" same \
    "$([[ "$(wg_status_norm "$work/status.cmp")" == "$(wg_status_norm "$WG_OUT/status.json")" ]] && echo same || echo differ)"
check "wake gate: the status file shows no deferral yet, status shows the new one" "[] 1" \
    "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["wake_deferred"]), len(json.load(open(sys.argv[2]))["wake_deferred"]))' "$WG_OUT/status.json" "$work/status.cmp" | sed 's/^0/[]/')"
check "wake gate: the status file is not empty" yes "$( [[ -s "$WG_OUT/status.json" ]] && echo yes)"
check "wake gate: the context dir is gone after the gate" 0 \
    "$(find "$WG_STATE" -maxdepth 1 -name 'wake-gate.*' | wc -l)"
check "wake gate: the context dir was under the state dir" "$WG_STATE" "$(dirname "$(cat "$WG_OUT/ctxdir")")"

# The gate must not inherit the store lock fd: a child it leaves behind
# would hold the lock past the postmaster's own death. (flock -u on exit
# releases it for every sharer, so the fd table is what has to be checked.)
wg_new_store
# shellcheck disable=SC2016  # expands in the gate, not here
wg_gate 'for fd in /proc/$$/fd/*; do readlink "$fd"; done > "$WG_OUT/fds"
exit 0'
mid="$(send_msg '@alice' '@hana' 'gate fd table' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake gate: the gate ran for the fd check" 1 "$(wg_calls)"
check "wake gate: the gate's fd table was captured" yes "$( [[ -s "$WG_OUT/fds" ]] && echo yes)"
check "wake gate: the gate inherits no fd on the store lock" 0 \
    "$(grep -c -- "$WG_STATE/lock" "$WG_OUT/fds" || true)"

# Forced failure to build the context: fail open, gate never run.
wg_new_store
wg_gate 'exit 1'
new_root WG_CTX_DIR
cp "$postmaster" "$WG_CTX_DIR/postmaster"
sed -i "s|^REPO_FLEET_KIT=.*|REPO_FLEET_KIT=\"$repo_dir/share/fleet-kit.md\"|" "$WG_CTX_DIR/postmaster"
for wg_f in fork-sandbox-mail.sh fork-sandbox-fleet.sh fork-sandbox-fleet-parse.py fork-sandbox-lib.sh; do
    ln -s "$repo_dir/scripts/$wg_f" "$WG_CTX_DIR/$wg_f"
done
cat > "$WG_CTX_DIR/fork-sandbox-mail-render.py" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --json ]] && exit 1; done
exec python3 "$repo_dir/scripts/fork-sandbox-mail-render.py" "\$@"
EOF
chmod +x "$WG_CTX_DIR/fork-sandbox-mail-render.py"
mid="$(send_msg '@alice' '@hana' 'gate context fails' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
postmaster="$WG_CTX_DIR/postmaster"
once
postmaster="$repo_dir/scripts/fork-sandbox-postmaster.sh"
check "wake gate: a context failure fails open (spawns)" 1 "$(wg_spawns hana)"
contains "wake gate: a context failure emits wake-gate-error" "$(cat "$work/once.out")" \
    "pm wake-gate-error thread=$short agent=hana reason=context"
check "wake gate: a context failure never runs the gate" 0 "$(wg_calls)"
check "wake gate: a context failure leaves no temp dir" 0 \
    "$(find "$WG_STATE" -maxdepth 1 -name 'wake-gate.*' | wc -l)"

# ---- the durable deferral record and its quiescent flag ----
wg_flag_file() { cat "$WG_STATE/needs-operator/$tid" 2>/dev/null || true; }
wg_flags() {
    local n
    n="$(grep -c "	flag	" "$WG_STATE/needs-operator-journal/$tid" 2>/dev/null || true)"
    echo "${n:-0}"
}

wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@hana' 'deferral record' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake-deferred: a defer writes the seat's record" "hana $mid" \
    "$(cat "$WG_STATE/wake-deferred/$tid" 2>/dev/null)"
check "wake-deferred: a quiescent thread with an outstanding defer is flagged" \
    "wake deferred: @hana at $mid and nothing woke it" "$(wg_flag_file)"
contains "wake-deferred: the flag event carries the fixed keyword" "$(cat "$work/once.out")" \
    "pm flag thread=$short reason=wake-deferred"
check "wake-deferred: flagged once" 1 "$(wg_flags)"
once
check "wake-deferred: not flagged again on the next pass" 1 "$(wg_flags)"
not_contains "wake-deferred: no repeat flag event" "$(cat "$work/once.out")" "reason=wake-deferred"
mid2="$(reply_msg '@alice' "$mid" 'again' --to '@hana')"
once
check "wake-deferred: a later defer replaces the seat's line" "hana $mid2" \
    "$(cat "$WG_STATE/wake-deferred/$tid" 2>/dev/null)"
check "wake-deferred: a new message re-arms the flag" 2 "$(wg_flags)"
contains "wake-deferred: the re-flag names the newer message" "$(wg_flag_file)" "@hana at $mid2"
wg_gate 'exit 0'
reply_msg '@alice' "$mid2" 'third' --to '@hana' >/dev/null
once
check "wake-deferred: the seat then spawns" 1 "$(wg_spawns hana)"
check "wake-deferred: a spawn of the seat clears its record" 0 \
    "$( [[ -e "$WG_STATE/wake-deferred/$tid" ]] && echo 1 || echo 0 )"

# A thread that is still busy is not flagged, and a seat that spawns before
# the thread goes quiet is not flagged at all.
wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@hana,@carol' 'busy thread' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake-deferred: the busy thread's deferral is recorded" "hana $mid" \
    "$(cat "$WG_STATE/wake-deferred/$tid" 2>/dev/null)"
check "wake-deferred: a thread with a live run is not flagged" "" "$(wg_flag_file)"
wg_gate 'exit 0'
mid2="$(reply_msg '@alice' "$mid" 'now' --to '@hana')"
once
check "wake-deferred: the deferred seat spawned on a later message" 1 "$(wg_spawns hana)"
wg_finish_run carol
wg_finish_run hana
once
once
check "wake-deferred: a seat that spawned afterwards is never flagged" 0 "$(wg_flags)"

# Operator mail and a retry spawn the seat too, and clear its line.
wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@alice' '@hana' 'cleared by operator' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
mid2="$(reply_msg '@operator' "$mid" 'wake up' --to '@hana')"
once
check "wake-deferred: operator mail spawns the gated seat" 1 "$(wg_spawns hana)"
check "wake-deferred: and clears its record" 0 \
    "$( [[ -e "$WG_STATE/wake-deferred/$tid" ]] && echo 1 || echo 0 )"
wg_new_store
mid="$(send_msg '@alice' '@hana' 'cleared by retry' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "wake-deferred: the retry thread's deferral is recorded" "hana $mid" \
    "$(cat "$WG_STATE/wake-deferred/$tid" 2>/dev/null)"
mkdir -p -- "$WG_STATE/retries/$tid"
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$mid" > "$WG_STATE/retries/$tid/hana"
once
check "wake-deferred: a retry spawns the seat" 1 "$(wg_spawns hana)"
check "wake-deferred: and clears its record" 0 \
    "$( [[ -e "$WG_STATE/wake-deferred/$tid" ]] && echo 1 || echo 0 )"

# ---- the per-thread budget (X-Thread-Budget on the root) ----
# bt_send <budget> <to> <subject>: a root carrying `send --budget`.
bt_send() {
    printf 'body\n' > "$work/body.tmp"
    "$MAIL" send --from @dana --to "$2" --subject "$3" --body "$work/body.tmp" --budget "$1" 2>/dev/null
}
bt_root() { printf '%s' "$FORK_SANDBOX_MAIL_ROOT/threads/$1/"*-"$1".msg; }
bt_status() { FORK_SANDBOX_THREAD_BUDGET=10 "$postmaster" status --thread "$1" --json; }
bt_key() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
wg_seed() { mkdir -p -- "$WG_STATE/spawns"; seq 1 "$1" > "$WG_STATE/spawns/$tid"; }
wg_finish_quiet() {
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "$(env_file_for_agent "$1")")"
    mkdir -p -- "$rd/outbox"
    printf '0\n' > "$rd/exit-code"
    printf '{}\n' > "$rd/summary.json"
}

wg_new_store
for bt_case in "5 5 thread" "10 10 thread" "11 10 global" "9223372036854775808 10 global" "99999999999999999999999 10 global" "50 10 global" "0 10 global" "007 10 global" "abc 10 global"; do
    read -r bt_hdr bt_want bt_src <<< "$bt_case"
    mid="$(bt_send 5 '@bob' "budget $bt_hdr")"
    tid="$(thread_of "$mid")"
    sed -i "s/^X-Thread-Budget: .*/X-Thread-Budget: $bt_hdr/" "$(bt_root "$tid")"
    bt_json="$(bt_status "$tid")"
    check "per-thread budget: header $bt_hdr gives budget $bt_want" "$bt_want" "$(bt_key "$bt_json" budget)"
    check "per-thread budget: header $bt_hdr gives source $bt_src" "$bt_src" "$(bt_key "$bt_json" budget_source)"
done
mid="$(send_msg '@dana' '@bob' 'no budget header' 'body' 8)"
tid="$(thread_of "$mid")"
bt_json="$(bt_status "$tid")"
check "per-thread budget: no header gives the global budget" "10" "$(bt_key "$bt_json" budget)"
check "per-thread budget: no header gives source global" "global" "$(bt_key "$bt_json" budget_source)"

# Absent header: exhaustion at the global budget, as always.
wg_new_store
mid="$(send_msg '@dana' '@bob' 'global exhaustion' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
FORK_SANDBOX_THREAD_BUDGET=10 wg_seed 9
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: no header, 9 of 10 spawns still wakes" 1 "$(wg_spawns bob)"
wg_finish_quiet bob
mid2="$(reply_msg '@dana' "$mid" 'again' --to '@bob')"
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: no header, exhausted at the global 10" "thread budget 10 exhausted" "$(wg_flag_file)"

# A header lower than the global exhausts the thread early.
wg_new_store
mid="$(bt_send 2 '@bob' 'own budget 2')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: the first message wakes" 1 "$(wg_spawns bob)"
wg_finish_quiet bob
reply_msg '@dana' "$mid" 'two' --to '@bob' > /dev/null
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: the second message wakes" 2 "$(wg_spawns bob)"
wg_finish_quiet bob
reply_msg '@dana' "$mid" 'three' --to '@bob' > /dev/null
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: the third is refused" 2 "$(wg_spawns bob)"
check "per-thread budget: the flag names the thread's own budget" "thread budget 2 exhausted" "$(wg_flag_file)"
contains "per-thread budget: the refusal is reason=budget" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=budget"

# A header above the global is clamped to it.
wg_new_store
mid="$(bt_send 50 '@bob' 'clamped')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
FORK_SANDBOX_THREAD_BUDGET=10 wg_seed 10
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: a header above the global is clamped" "thread budget 10 exhausted" "$(wg_flag_file)"

# A follow-up wake and a retry both honor the thread's own budget.
wg_new_store
mid="$(bt_send 2 '@carol' 'follow-up')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
FORK_SANDBOX_THREAD_BUDGET=10 once
reply_msg '@dana' "$mid" 'second' --to '@carol' > /dev/null
FORK_SANDBOX_THREAD_BUDGET=10 once
wg_seed 2
wg_finish_quiet carol
: > "$STUB_ARGV_LOG"
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: a follow-up wake at the thread's budget is refused" 0 "$(wg_spawns carol)"
contains "per-thread budget: the follow-up refusal is reason=budget" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=carol reason=budget"
check "per-thread budget: the follow-up flag names the budget" "thread budget 2 exhausted" "$(wg_flag_file)"

wg_new_store
mid="$(bt_send 2 '@dana' 'retry')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
FORK_SANDBOX_THREAD_BUDGET=10 once
wg_seed 1
mkdir -p -- "$WG_STATE/retries/$tid"
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$mid" > "$WG_STATE/retries/$tid/carol"
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: a retry below the budget spawns" 1 "$(wg_spawns carol)"
wg_seed 2
printf 'TRIGGER=%s\nATTEMPT=0\nNOT_BEFORE=0\n' "$mid" > "$WG_STATE/retries/$tid/bob"
FORK_SANDBOX_THREAD_BUDGET=10 once
check "per-thread budget: a retry at the budget is refused" 0 "$(wg_spawns bob)"
contains "per-thread budget: the retry refusal is reason=budget" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=budget"

# ---- the budget reserve: the last spawns of a thread's budget ----
# Budget 10 with 3 reserved: the band is 7 <= spawns so far < 10. carol and
# hana may spawn inside it; alice, bob and dana may not.
sed -i '1i budget-reserve:\n  spawns: 3\n  agents: [carol, hana]' "$FORK_SANDBOX_FLEET_FILE"
export FORK_SANDBOX_THREAD_BUDGET=10
wg_record() { cat "$WG_STATE/budget-reserved/$tid" 2>/dev/null || true; }

wg_new_store
mid="$(send_msg '@dana' '@bob,@carol' 'in the band' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 7
once
check "reserve: in the band, the reserved seat spawns" 1 "$(wg_spawns carol)"
check "reserve: in the band, the other seat is refused" 0 "$(wg_spawns bob)"
contains "reserve: the refusal event names the reason" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=budget-reserved"
check "reserve: only the reserved seat spent a slot" 8 "$(spawn_count_of "$tid")"
check "reserve: the refusal is recorded" "bob $mid" "$(wg_record)"
check "reserve: the refusal does not flag the thread" "" "$(wg_flag_file)"
not_contains "reserve: no flag event at refusal" "$(cat "$work/once.out")" "pm flag"
wg_finish_quiet carol
once
check "reserve: a quiescent thread with a standing refusal is flagged" \
    "thread budget 10: @bob refused at $mid (last 3 spawns reserved for @carol, @hana) and nothing woke it" \
    "$(wg_flag_file)"
contains "reserve: the flag event carries the fixed keyword" "$(cat "$work/once.out")" \
    "pm flag thread=$short reason=budget-reserved"
check "reserve: flagged exactly once" 1 "$(wg_flags)"
once
check "reserve: not flagged again on the next pass" 1 "$(wg_flags)"

# A refused seat that then spawns (here via the operator's rule-1 reset) is
# never flagged.
wg_new_store
mid="$(send_msg '@dana' '@bob,@carol' 'refused then woken' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 7
once
check "reserve: the refusal is recorded before the reset" "bob $mid" "$(wg_record)"
mid2="$(reply_msg '@operator' "$mid" 'carry on' --to '@bob')"
once
check "reserve: the refused seat spawns after the reset" 1 "$(wg_spawns bob)"
check "reserve: and its record is cleared" "" "$(wg_record)"
wg_finish_quiet carol
wg_finish_quiet bob
once
once
check "reserve: a thread whose refused seat later spawned is not flagged" 0 "$(wg_flags)"
check "reserve: and carries no flag" "" "$(wg_flag_file)"

# Below the band nothing changes: both candidates spawn.
wg_new_store
mid="$(send_msg '@dana' '@bob,@carol' 'below the band' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 6
once
check "reserve: below the band the non-reserved seat spawns" 1 "$(wg_spawns bob)"
check "reserve: below the band the reserved seat spawns" 1 "$(wg_spawns carol)"
not_contains "reserve: below the band nothing is refused" "$(cat "$work/once.out")" "pm refuse"

# At the budget the exhausted gate is unchanged, reserved seats included.
wg_new_store
mid="$(send_msg '@dana' '@bob,@carol' 'exhausted' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 10
once
check "reserve: at the budget the reserved seat is refused too" 0 "$(wg_spawns carol)"
check "reserve: at the budget the other seat is refused" 0 "$(wg_spawns bob)"
contains "reserve: at the budget the refusal reason is budget" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=carol reason=budget"
not_contains "reserve: at the budget nothing is budget-reserved" "$(cat "$work/once.out")" "budget-reserved"
check "reserve: at the budget the flag is immediate and unchanged" "thread budget 10 exhausted" "$(wg_flag_file)"
contains "reserve: at the budget the keyword is budget-exhausted" "$(cat "$work/once.out")" \
    "pm flag thread=$short reason=budget-exhausted"

# A follow-up wake honors the band.
wg_new_store
mid="$(send_msg '@dana' '@bob' 'follow-up in the band' 'first' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
mid2="$(reply_msg '@dana' "$mid" 'second' --to '@bob')"
once
check "reserve: the follow-up message is pended below the band" yes \
    "$(grep -q "PENDING_MSGS=$mid2" "$(env_file_for_agent bob)" && echo yes)"
wg_seed 7
wg_finish_quiet bob
: > "$STUB_ARGV_LOG"
once
check "reserve: a follow-up wake of a non-reserved seat is refused in the band" 0 "$(wg_spawns bob)"
contains "reserve: and says so" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=budget-reserved"
check "reserve: and records it" "bob $mid2" "$(wg_record)"
wg_new_store
mid="$(send_msg '@dana' '@carol' 'follow-up reserved' 'first' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
mid2="$(reply_msg '@dana' "$mid" 'second' --to '@carol')"
once
wg_seed 7
wg_finish_quiet carol
: > "$STUB_ARGV_LOG"
once
check "reserve: a follow-up wake of a reserved seat spawns in the band" 1 "$(wg_spawns carol)"

# Both records on one thread: one flag, reasons joined, keyword from the
# two booleans.
wg_new_store
wg_gate 'exit 1'
mid="$(send_msg '@dana' '@bob,@hana' 'both records' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 7
once
check "reserve: both records standing give one combined flag" \
    "wake deferred: @hana at $mid and nothing woke it; thread budget 10: @bob refused at $mid (last 3 spawns reserved for @carol, @hana) and nothing woke it" \
    "$(wg_flag_file)"
contains "reserve: the combined keyword lists both" "$(cat "$work/once.out")" \
    "pm flag thread=$short reason=wake-deferred,budget-reserved"
check "reserve: combined, flagged once" 1 "$(wg_flags)"

# on-quiescent reads the flag the deferral pass sets on the same pass. The
# first pass on an empty store seeds the hook marks so the next one fires.
wg_qhook() {
    # shellcheck disable=SC2016  # expands in the hook, not here
    printf '#!/usr/bin/env bash\nprintf "%%s\\n%%s\\n" "$FS_HOOK_FLAGGED" "$FS_HOOK_FLAG_REASON" > "$WG_OUT/quiescent"\n' \
        > "$WG_HOOKS/on-quiescent"
    chmod +x "$WG_HOOKS/on-quiescent"
    rm -f "$WG_OUT/quiescent"
}
wg_qseen() { sed -n "$1p" "$WG_OUT/quiescent" 2>/dev/null || true; }
export FORK_SANDBOX_POSTMASTER_HOOK_DETACH=inline

wg_new_store
wg_gate 'exit 1'
wg_qhook
once
mid="$(send_msg '@dana' '@hana' 'quiescent sees defer' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
check "quiescent hook: sees FS_HOOK_FLAGGED=1 for a standing defer" 1 "$(wg_qseen 1)"
check "quiescent hook: sees the wake-deferred reason" \
    "wake deferred: @hana at $mid and nothing woke it" "$(wg_qseen 2)"

wg_new_store
wg_gate 'exit 0'
wg_qhook
once
mid="$(send_msg '@dana' '@bob,@carol' 'quiescent sees reserve' 'body' 8)"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 7
once
wg_finish_quiet carol
once
check "quiescent hook: sees FS_HOOK_FLAGGED=1 for a standing refusal" 1 "$(wg_qseen 1)"
contains "quiescent hook: sees the budget-reserved reason" "$(wg_qseen 2)" "@bob refused at $mid"
rm -f "$WG_HOOKS/on-quiescent"
unset FORK_SANDBOX_POSTMASTER_HOOK_DETACH

# The reserve inside a thread's own budget: band = [budget - reserve, budget).
wg_new_store
mid="$(bt_send 6 '@bob,@carol' 'own band')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 3
once
check "thread band: inside [3, 6) the reserved seat spawns" 1 "$(wg_spawns carol)"
check "thread band: inside [3, 6) the other seat is refused" 0 "$(wg_spawns bob)"
contains "thread band: the refusal is budget-reserved" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=budget-reserved"
wg_finish_quiet carol
once
check "thread band: the quiescent flag names the thread's budget" \
    "thread budget 6: @bob refused at $mid (last 3 spawns reserved for @carol, @hana) and nothing woke it" \
    "$(wg_flag_file)"
wg_new_store
mid="$(bt_send 6 '@bob,@carol' 'below own band')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
wg_seed 2
once
check "thread band: below it the non-reserved seat spawns" 1 "$(wg_spawns bob)"
check "thread band: below it the reserved seat spawns" 1 "$(wg_spawns carol)"

# A budget within the reserve wakes nobody and is flagged once.
for bt_b in 3 2; do
    wg_new_store
    mid="$(bt_send "$bt_b" '@bob,@carol' "within reserve $bt_b")"
    tid="$(thread_of "$mid")"; short="${tid:0:8}"
    once
    check "within reserve ($bt_b): a non-reserved seat does not wake" 0 "$(wg_spawns bob)"
    check "within reserve ($bt_b): a reserved seat does not wake" 0 "$(wg_spawns carol)"
    contains "within reserve ($bt_b): each candidate is refused" "$(cat "$work/once.out")" \
        "pm refuse thread=$short agent=carol reason=budget"
    check "within reserve ($bt_b): the reason names both numbers" \
        "thread budget $bt_b is within the fleet's budget-reserve spawns (3)" "$(wg_flag_file)"
    contains "within reserve ($bt_b): the keyword is budget-reserve" "$(cat "$work/once.out")" \
        "pm flag thread=$short reason=budget-reserve"
    check "within reserve ($bt_b): flagged once" 1 "$(wg_flags)"
done
reply_msg '@dana' "$mid" 'again' --to '@bob' > /dev/null
once
check "within reserve: a second message while flagged adds no flag" 1 "$(wg_flags)"
check "within reserve: it still wakes nobody" 0 "$(wg_spawns bob)"
reply_msg '@operator' "$mid" 'carry on' --to '@operator' > /dev/null
once
check "within reserve: operator mail clears the flag and the standing condition re-raises it" 2 "$(wg_flags)"
reply_msg '@dana' "$mid" 'and again' --to '@bob' > /dev/null
once
check "within reserve: the re-raised flag is not raised again" 2 "$(wg_flags)"

# A follow-up wake is refused the same way.
wg_new_store
mid="$(bt_send 6 '@carol' 'within reserve follow-up')"
tid="$(thread_of "$mid")"; short="${tid:0:8}"
once
reply_msg '@dana' "$mid" 'second' --to '@carol' > /dev/null
once
sed -i "s/^X-Thread-Budget: .*/X-Thread-Budget: 2/" "$(bt_root "$tid")"
wg_finish_quiet carol
: > "$STUB_ARGV_LOG"
once
check "within reserve: a follow-up wake is refused" 0 "$(wg_spawns carol)"
check "within reserve: and flagged with the reserve reason" \
    "thread budget 2 is within the fleet's budget-reserve spawns (3)" "$(wg_flag_file)"

# Startup: a reserve that is not smaller than the budget refuses to start.
wg_new_store
wg_rc="$(FORK_SANDBOX_THREAD_BUDGET=3 once_rc)"
check "reserve: spawns >= budget refuses startup with exit 2" 2 "$wg_rc"
contains "reserve: the refusal names the reserve" "$(cat "$work/once.err")" "budget-reserve spawns (3)"
contains "reserve: the refusal names the budget" "$(cat "$work/once.err")" "thread budget (3)"
wg_rc="$(FORK_SANDBOX_THREAD_BUDGET=2 once_rc)"
check "reserve: spawns > budget refuses startup too" 2 "$wg_rc"
wg_rc="$(FORK_SANDBOX_THREAD_BUDGET=4 once_rc)"
check "reserve: spawns < budget starts" 0 "$wg_rc"
unset FORK_SANDBOX_THREAD_BUDGET

unset FORK_SANDBOX_HOOKS_DIR WG_OUT
printf '%s\n' "$wg_saved_fleet" > "$FORK_SANDBOX_FLEET_FILE"
rm -f -- "$FORK_SANDBOX_PERSONAS_DIR/hana.md" "$FORK_SANDBOX_PERSONAS_DIR/hugo.md" "$FORK_SANDBOX_PERSONAS_DIR/hera.md"

finish_suite
