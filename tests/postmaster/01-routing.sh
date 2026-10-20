#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/01-routing.sh — fork-sandbox-postmaster.sh: To/Cc/list
# routing, unresolvable names, @operator, launcher argv, hop and budget gates.
#
# Usage: tests/postmaster/01-routing.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== To wakes, Cc wakes by default; list wakes every member once; direct+list dedup ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

mid="$(send_msg '@alice' '@bob' 'cc test' 'body for cc test' 8 '@carol')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "To recipient (bob) spawns" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "Cc recipient (carol) spawns too (wake-on-cc default true)" 1 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"
run_env="$(env_file_for_agent carol)"
check "Cc wake: ledger records VIA=cc" "VIA=cc" "$(grep '^VIA=' "$run_env")"
run_env_bob="$(env_file_for_agent bob)"
check "To wake: ledger records VIA=to" "VIA=to" "$(grep '^VIA=' "$run_env_bob")"

# The ledger's VIA is computed for a reason -- it must also be legible
# to the woken agent itself, which has no fleet tooling and cannot
# re-derive it from a rendered To:/Cc: header once a list is involved.
handoff_carol="$(handoff_file_for_agent carol)"
contains "Cc wake: handoff states the computed via, not left for the agent to guess" \
    "$(cat "$handoff_carol")" "addressed to you via **Cc:**"
handoff_bob="$(handoff_file_for_agent bob)"
contains "To wake: handoff states the computed via, not left for the agent to guess" \
    "$(cat "$handoff_bob")" "addressed to you via **To:**"

run_dir_carol="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
run_dir_bob="$(sed -n 's/^RUN_DIR=//p' "$run_env_bob")"
contains "spawn event: To wake (bob) logged on stdout with via=to" \
    "$(cat "$work/once.out")" \
    "pm spawn thread=$short agent=bob run=$(basename -- "$run_dir_bob") via=to"
contains "spawn event: Cc wake (carol) logged on stdout with via=cc" \
    "$(cat "$work/once.out")" \
    "pm spawn thread=$short agent=carol run=$(basename -- "$run_dir_carol") via=cc"

# ============================================================
printf '\n== Route plan: a postmaster that dies mid-message leaves its unwoken seats to the next ==\n'
# ============================================================
# A three-seat message (@team: alice, bob, carol) whose route pass is cut
# off while waking bob. The routed marker is already written by then, so
# without a plan bob and carol would never be woken by anyone.

rp_spawns() { grep -c -- "^sbx-mail-${rp_short}-$1-" "$STUB_ARGV_LOG" || true; }
rp_runs() {
    local n=0 f
    for f in "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env; do
        [[ -e "$f" ]] || continue
        grep -q "^AGENT=$1\$" "$f" && grep -q "^THREAD=$rp_tid\$" "$f" && n=$(( n + 1 ))
    done
    echo "$n"
}
rp_new() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    rp_mid="$(send_msg '@dana' '@team' 'route plan topic' 'three seats' 8)"
    rp_tid="$(thread_of "$rp_mid")"
    rp_short="${rp_tid:0:8}"
    rp_plan="$PM_STATE_DIR/route-pending/$rp_mid"
    rp_counter="$(mktemp "$work/rp-counter.XXXXXX")"
}

rp_new
rp_rc=0
STUB_SIGNAL_PARENT="KILL 2 $rp_counter" once || rp_rc=$?
check "killed mid-message: the postmaster died (SIGKILL)" 137 "$rp_rc"
check "killed mid-message: the message is marked routed" 1 \
    "$( [[ -e "$PM_STATE_DIR/routed/$rp_mid" ]] && echo 1 || echo 0 )"
check "killed mid-message: alice was woken" 1 "$(rp_runs alice)"
check "killed mid-message: carol was never reached" 0 "$(rp_spawns carol)"
check "killed mid-message: the plan keeps bob and carol" "bob carol" \
    "$(tr '\n' ' ' < "$rp_plan/seats" | sed 's/ $//')"
check "killed mid-message: bob is the seat in hand, first attempt" "bob 1" \
    "$(cat "$rp_plan/inflight" 2>/dev/null)"

once
contains "resume: route-resume event names the message" "$(cat "$work/once.out")" \
    "pm route-resume thread=$rp_short msg=${rp_mid:0:8} seats=2"
check "resume: bob is woken" 1 "$(rp_runs bob)"
check "resume: carol is woken" 1 "$(rp_runs carol)"
check "resume: alice is not woken twice" 1 "$(rp_spawns alice)"
check "resume: the plan is gone" 0 "$( [[ -e "$rp_plan" ]] && echo 1 || echo 0 )"
once
check "a later pass wakes no one again" "1 1 1" \
    "$(rp_spawns alice) $(rp_runs bob) $(rp_runs carol)"

# The seat in hand already has a run for this trigger (the death came after
# its spawn was recorded): resume pops it rather than waking it again.
rp_new
STUB_SIGNAL_PARENT="KILL 2 $rp_counter" once || true
printf 'alice 1\n' > "$rp_plan/inflight"
printf 'alice\nbob\ncarol\n' > "$rp_plan/seats"
once
check "in-hand seat with a run for the trigger: not woken again" 1 "$(rp_spawns alice)"
check "in-hand seat with a run for the trigger: the rest still wake" "1 1" \
    "$(rp_runs bob) $(rp_runs carol)"

# A seat that a second process also died on is flagged and dropped, not
# retried forever.
rp_new
STUB_SIGNAL_PARENT="KILL 2 $rp_counter" once || true
STUB_SIGNAL_PARENT="KILL 3 $rp_counter" once || true
check "second death on the same seat: it is still in hand, attempt 2" "bob 2" \
    "$(cat "$rp_plan/inflight" 2>/dev/null)"
once
check "second death on the same seat: bob is not tried a third time" 2 "$(rp_spawns bob)"
check "second death on the same seat: carol still wakes" 1 "$(rp_runs carol)"
contains "second death on the same seat: the thread is flagged" \
    "$(cat "$PM_STATE_DIR/needs-operator/$rp_tid" 2>/dev/null)" \
    "routing interrupted: woke no run for bob on $rp_mid after 2 attempts"
check "second death on the same seat: journal keyword route-interrupted" 1 \
    "$(awk -F'\t' '$2=="flag" && $3=="route-interrupted"' "$PM_STATE_DIR/needs-operator-journal/$rp_tid" | wc -l)"

# A plan whose message never got its routed marker is the message's own
# business: it is dropped, and the message routes again as a whole.
rp_new
mkdir -p -- "$rp_plan"
printf '%s\n' "$rp_tid" > "$rp_plan/thread"
printf '0\n' > "$rp_plan/band"
printf 'carol\n' > "$rp_plan/seats"
once
check "plan for an unrouted message: every seat wakes once" "1 1 1" \
    "$(rp_runs alice) $(rp_runs bob) $(rp_runs carol)"

# SIGTERM (a rollout's first signal) mid-message: the seat in hand finishes,
# nothing more is woken, the plan holds the rest, and the next process
# wakes them.
rp_new
rp_log="$work/rp-deliver.log"
STUB_SIGNAL_PARENT="TERM 1 $rp_counter" FORK_SANDBOX_POSTMASTER_INTERVAL=1 \
    FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT=0 \
    "$postmaster" deliver --project "$PROJECT_DIR" > "$rp_log" 2>&1 &
rp_pid=$!
for _ in $(seq 1 100); do kill -0 "$rp_pid" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$rp_pid" 2>/dev/null
rp_rc=0; wait "$rp_pid" || rp_rc=$?
check "SIGTERM mid-message: the loop exits 0" 0 "$rp_rc"
check "SIGTERM mid-message: the seat in hand was woken" 1 "$(rp_runs alice)"
check "SIGTERM mid-message: no further seat was launched" "0 0" "$(rp_spawns bob) $(rp_spawns carol)"
contains "SIGTERM mid-message: route-paused event" "$(cat "$rp_log")" \
    "pm route-paused thread=$rp_short msg=${rp_mid:0:8} seats=2"
once
check "SIGTERM mid-message: the next process wakes the rest" "1 1 1" \
    "$(rp_spawns alice) $(rp_runs bob) $(rp_runs carol)"

# ============================================================
printf '\n== Cc wakes: wake-on-cc:false suppresses, sender-in-cc never wakes, both-headers dedup ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'cc opt-out test' 'body' 8 '@dana')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "wake-on-cc:false suppresses the Cc wake (dana)" 0 "$(grep -c -- "^sbx-mail-$short-dana-" "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'sender in cc via list' 'body' 8 '@team')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "sender named in Cc (via a list) never wakes (alice)" 0 "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"
check "other Cc'd list member (carol) still wakes" 1 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'both headers dedup' 'body' 8 '@bob')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "agent named in both To and Cc wakes exactly once (bob)" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
run_env="$(env_file_for_agent bob)"
check "both-headers dedup: To wins for VIA (bob)" "VIA=to" "$(grep '^VIA=' "$run_env")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'cc hops gate' 'body' 0 '@carol')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "X-Hops 0 gates a Cc wake too (carol)" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'cc budget gate' 'body' 8 '@carol')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns"
seq 1 96 > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
: > "$STUB_ARGV_LOG"
once
check "thread budget exhausted gates a Cc wake too (carol)" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid1="$(send_msg '@alice' '@bob' 'cc live delivery' 'first message' 8 '@carol')"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
once
check "cc live delivery setup: carol's first cc wake spawns" 1 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"
run_env="$(env_file_for_agent carol)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
mid2="$(reply_msg '@alice' "$mid1" 'second message' --cc '@carol' --to '@bob')"
short2="${mid2:0:8}"
: > "$STUB_ARGV_LOG"
once
check "live run + new Cc message: no second spawn (carol)" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"
banner2=$(find "$run_dir/inbox" -maxdepth 1 -name 'mail-banner-*' -print -quit)
check "live run + new Cc message: live delivery banner written instead" \
    "mail-banner-001-$short2.md" "$(basename -- "$banner2" 2>/dev/null)"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@bob,@team' 'list dedup test' 'body for list dedup' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "list member alice wakes" 1 "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"
check "direct+list bob wakes exactly once" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "sender carol does not wake on her own message" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== a list member never wakes on a message they sent themselves ==\n'
# ============================================================

# Operator-seeded shape: @operator mails @team (alice/bob/carol), one of
# whom (bob) reply-alls. mail.sh's reply-all keeps @team in the parent's
# To: verbatim (it only strips the literal sender address, not list
# membership), so bob's reply is still addressed to a list he belongs to.
# Without the sender exclusion in pm_process_message, that would wake bob
# on his own reply -- and self-sustainingly so, since his next reply-all
# would be byte-for-byte the same shape. All three first runs are
# harvested before bob replies so the busy-run dedup (rule 4) can't be
# what's suppressing his second wake -- only the sender exclusion can,
# and alice/carol waking as usual on the same message shows it's not
# some other rule blocking everyone.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid1="$(send_msg '@operator' '@team' 'self-wake regression' 'body from operator' 8)"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
once
check "operator mail wakes all three team members" 3 \
    "$(grep -c -- "^sbx-mail-$short-\(alice\|bob\|carol\)-" "$STUB_ARGV_LOG")"

for a in alice bob carol; do
    run_env="$(env_file_for_agent "$a")"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
    mkdir -p -- "$run_dir/outbox"
    printf '0\n' > "$run_dir/exit-code"
    printf '{}\n' > "$run_dir/summary.json"
done
once

mid2="$(reply_msg '@bob' "$mid1" 'reply from bob')"
contains "bob's reply-all still addresses the team list" \
    "$("$MAIL" show "$mid2" 2>/dev/null | sed -n 's/^To: //p')" '@team'
: > "$STUB_ARGV_LOG"
once
check "bob does not wake on the message he just sent" 0 \
    "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "alice still wakes on bob's reply" 1 \
    "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"
check "carol still wakes on bob's reply" 1 \
    "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== unresolvable To: @name is flagged, known recipients still wake ==\n'
# ============================================================
# @nobody is @-shaped (agents are always addressed "@name") but not a
# registered fleet agent -- exactly the typo/missing-fleet-file case this
# feature exists to surface, so it is no longer silent.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob,@nobody' 'unknown to test' 'body' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
rc="$(once_rc)"
check "unresolvable To: deliver still exits 0" "0" "$rc"
check "unresolvable To: known recipient still wakes" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "unresolvable To: message is still marked routed" 0 \
    "$([[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/routed/$mid" ]] && echo 0 || echo 1)"
flag_content="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)"
contains "unresolvable To: flag reason names the typo'd address" \
    "$flag_content" "unresolvable To: @nobody at $mid"
if [[ "$flag_content" == *"@bob"* ]]; then
    no "unresolvable To: flag does not name the resolved address" "$flag_content"
else
    ok "unresolvable To: flag does not name the resolved address"
fi
contains "unresolvable To: events log carries route-dead with the unresolved count" \
    "$(cat "$work/once.out")" "pm route-dead thread=$short unresolved=1"
contains "unresolvable To: flag event uses the fixed unresolvable-to keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$short reason=unresolvable-to"

# `mail reply`'s default reply-all copies the parent's From+To+Cc into the
# new message's own To:, so @nobody (still unresolved) rides along into
# every later reply on this thread -- exactly like a real reply-all would.
# Before pm_flag stopped re-firing for an already-flagged name, this
# second pass re-flagged the thread with THIS message's id and clobbered
# whatever the flag said before (pm_flag overwrites, not appends).
reply_msg '@bob' "$mid" 'a reply-all reply' >/dev/null
: > "$STUB_ARGV_LOG"
once
flag_content2="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)"
check "unresolvable To: a reply-all reply carrying the SAME unresolved name does not re-flag" \
    "$flag_content" "$flag_content2"
not_contains "unresolvable To: a reply-all reply carrying the SAME unresolved name emits no route-dead event" \
    "$(cat "$work/once.out")" "route-dead"

# Rule 1: operator mail resets the flag, and the operator's own mail
# reply is a reply-all too -- it must not immediately re-flag the thread
# it just re-armed just because @nobody is still riding along in the
# propagated To:.
reply_msg '@operator' "$mid" 'operator re-arms the thread' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "unresolvable To: an operator reply-all carrying the SAME unresolved name clears the flag and it stays cleared" \
    "" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)"

# A single message that trips BOTH the unresolvable-To check and the
# hops gate must leave the more specific hops reason standing, not get
# silently overwritten by the unresolvable-To reason written moments
# earlier in the same pm_process_message call.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_gate="$(send_msg '@alice' '@bob,@nobody' 'unresolvable plus exhausted hops' 'body' 0)"
tid_gate="$(thread_of "$mid_gate")"
short_gate="${tid_gate:0:8}"
: > "$STUB_ARGV_LOG"
once
check "unresolvable+hops: the hops reason wins, not clobbered by unresolvable-To" \
    "hops exhausted at $mid_gate" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_gate" 2>/dev/null)"
check "unresolvable+hops: exactly one flag event for the message, not two" 1 \
    "$(grep -c -- "^pm flag thread=$short_gate " "$work/once.out")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

# A non-@-shaped To: (not something fork-sandbox-mail.sh's own send
# validation can ever produce -- every address it accepts matches
# @[a-z0-9-]+ -- so this patches the stored .msg file directly, the same
# technique the corrupted-Thread-ID fixture above uses) is still silently
# skipped, unflagged: this pins that one hypothetical raw-message shape,
# nothing more. It is NOT evidence that rule 0's original "external
# senders are silently skipped" promise holds for a real external
# correspondent, because every address this store actually accepts is
# @-shaped, making a real external address indistinguishable from a
# typo'd seat name -- and the @-shaped case flags (see "unresolvable To:
# @name is flagged" above), the opposite of "silently skipped".
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_ext="$(send_msg '@alice' '@bob' 'external to test' 'body' 8)"
tid_ext="$(thread_of "$mid_ext")"
short_ext="${tid_ext:0:8}"
ext_msg_file=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid_ext"/*.msg; do
    [[ -e "$f" ]] || continue
    grep -q "^Message-ID: $mid_ext\$" "$f" && ext_msg_file="$f"
done
sed -i "s/^To: .*/To: @bob, someone@example.com/" "$ext_msg_file"
: > "$STUB_ARGV_LOG"
once
check "external To: known recipient still wakes" 1 "$(grep -c -- "^sbx-mail-$short_ext-bob-" "$STUB_ARGV_LOG")"
check "external To: no flag raised (non-@-shaped address, an unreachable shape via the CLI)" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_ext" 2>/dev/null || true)"
if grep -qF -- "route-dead thread=$short_ext" "$work/once.out"; then
    no "external To: no route-dead event (rule 0 regression pin)"
else
    ok "external To: no route-dead event (rule 0 regression pin)"
fi

# A mix of one good seat and one typo'd seat in the same To: -- the good
# seat still wakes, and the flag names only the typo, not the seat that
# resolved fine.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_mix="$(send_msg '@alice' '@bob,@typo' 'mixed to test' 'body' 8)"
tid_mix="$(thread_of "$mid_mix")"
short_mix="${tid_mix:0:8}"
: > "$STUB_ARGV_LOG"
once
check "mixed To: good seat still wakes" 1 "$(grep -c -- "^sbx-mail-$short_mix-bob-" "$STUB_ARGV_LOG")"
flag_mix="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_mix" 2>/dev/null)"
contains "mixed To: flag names the typo'd address" "$flag_mix" "@typo"
if [[ "$flag_mix" == *"@bob"* ]]; then
    no "mixed To: flag does not name the good address" "$flag_mix"
else
    ok "mixed To: flag does not name the good address"
fi

# ============================================================
printf '\n== unresolvable Cc: @name is flagged, distinct from an unresolvable To: ==\n'
# ============================================================
# Same machinery as the unresolvable-To: flag above, extended to Cc: an
# @-shaped Cc name that never resolves means an intended OBSERVER, not an
# addressee, silently never sees the thread -- field evidence (a Cc'd
# typo) motivated this. The reason says "via Cc" so the operator can tell
# an observer, not an addressee, went missing.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_cc="$(send_msg '@alice' '@bob' 'unresolvable cc test' 'body' 8 '@nonexistent')"
tid_cc="$(thread_of "$mid_cc")"
short_cc="${tid_cc:0:8}"
: > "$STUB_ARGV_LOG"
once
check "unresolvable Cc: known To recipient still wakes" 1 "$(grep -c -- "^sbx-mail-$short_cc-bob-" "$STUB_ARGV_LOG")"
cc_flag_content="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_cc" 2>/dev/null)"
contains "unresolvable Cc: flag reason names the typo'd address and marks it as Cc" \
    "$cc_flag_content" "unresolvable Cc: @nonexistent at $mid_cc"
contains "unresolvable Cc: flag event uses the unresolvable-cc keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$short_cc reason=unresolvable-cc"

# A reply carrying the same unresolved name AGAIN in its own Cc: must not
# re-flag (per-thread dedup, exactly like To:'s UNRESOLVED_TO record). Uses
# an explicit --cc rather than default reply-all: reply-all folds the
# parent's To+Cc together into the REPLY'S To: (see the reply-all comment
# below), which would move @nonexistent into To and test the wrong path.
reply_msg '@bob' "$mid_cc" 'a reply, still cc-ing the unresolved name' --to '@alice' --cc '@nonexistent' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "unresolvable Cc: a reply-all reply carrying the SAME unresolved name does not re-flag" \
    "$cc_flag_content" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_cc" 2>/dev/null)"

# Field scenario, not the hypothetical above: the operator's own re-arming
# reply is normally a PLAIN reply with no --to/--cc, i.e. reply-all, the
# default -- and reply-all folds the parent's To+Cc together into the
# reply's own To: (fork-sandbox-mail.sh's cmd_reply), so @nonexistent
# (still unresolved, still only ever seen via Cc so far) rides into this
# message's To: instead. UNRESOLVED_TO is one record shared between To:
# and Cc: exactly so this does not look like a fresh To: name: if it did,
# rule 1's own reset (fired by this same operator message, above) would be
# undone in the very same pass by the To: block re-flagging the thread.
reply_msg '@operator' "$mid_cc" 'operator re-arms the thread with a plain reply-all' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "unresolvable Cc: an operator reply-all that folds the Cc name into To clears the flag and it stays cleared" \
    "" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_cc" 2>/dev/null || true)"
not_contains "unresolvable Cc: the folded name does not emit a fresh route-dead event" \
    "$(cat "$work/once.out")" "route-dead"

# @operator in Cc: is exempt exactly like @operator in To:, never treated
# as unresolvable (fleet expand's @operator sink covers both paths: it
# succeeds with zero candidates, so pm_expand_to never sees it fail).
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_op_cc="$(send_msg '@alice' '@bob' 'operator cc test' 'body' 8 '@operator')"
tid_op_cc="$(thread_of "$mid_op_cc")"
once
check "@operator in Cc: is never treated as unresolvable" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_op_cc" 2>/dev/null || true)"

# A resolvable seat with wake-on-cc: false (dana, shared fixture) is
# suppressed-by-config, not unresolvable -- it must never flag.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_dana="$(send_msg '@alice' '@bob' 'wake-on-cc false cc test' 'body' 8 '@dana')"
tid_dana="$(thread_of "$mid_dana")"
: > "$STUB_ARGV_LOG"
once
check "wake-on-cc:false Cc candidate does not wake" 0 "$(grep -c -- "^sbx-mail-${tid_dana:0:8}-dana-" "$STUB_ARGV_LOG")"
check "wake-on-cc:false Cc candidate is not flagged as unresolvable" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_dana" 2>/dev/null || true)"

# Gate reason wins: a message that both gates (hops exhausted) AND has an
# unresolvable Cc name flags with the gate reason, never the Cc reason --
# gate_reason short-circuits Cc resolution entirely before it is ever
# computed, so there is no unresolvable-Cc flag call to even race against
# the gate's.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_gate_cc="$(send_msg '@alice' '@bob' 'unresolvable cc plus exhausted hops' 'body' 0 '@nonexistent')"
tid_gate_cc="$(thread_of "$mid_gate_cc")"
short_gate_cc="${tid_gate_cc:0:8}"
: > "$STUB_ARGV_LOG"
once
check "unresolvable-Cc+hops: the hops reason wins, not the Cc reason" \
    "hops exhausted at $mid_gate_cc" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_gate_cc" 2>/dev/null)"
check "unresolvable-Cc+hops: exactly one flag event for the message, not two" 1 \
    "$(grep -c -- "^pm flag thread=$short_gate_cc " "$work/once.out")"

# A single message with BOTH an unresolvable To: name and an unresolvable
# Cc: name must not let the Cc flag call silently erase the To: reason --
# pm_flag overwrites, and UNRESOLVED_TO dedup means a clobbered reason can
# never come back on a later message either. Both reasons must survive in
# the one flag call this message produces, AND the keyword must say both:
# docs/agent-mail.md promises an operator can find a missing Cc observer
# by grepping for keyword unresolvable-cc, and a compound reason must not
# make that grep silently miss this thread just because the To: miss on
# the same message would otherwise win the keyword outright.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_both="$(send_msg '@alice' '@bob,@notoname' 'both to and cc unresolvable' 'body' 8 '@noccname')"
tid_both="$(thread_of "$mid_both")"
short_both="${tid_both:0:8}"
: > "$STUB_ARGV_LOG"
once
check "both To+Cc unresolvable: the good To seat still wakes" 1 \
    "$(grep -c -- "^sbx-mail-$short_both-bob-" "$STUB_ARGV_LOG")"
both_flag="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_both" 2>/dev/null)"
contains "both To+Cc unresolvable: flag reason keeps the To: reason" \
    "$both_flag" "unresolvable To: @notoname at $mid_both"
contains "both To+Cc unresolvable: flag reason keeps the Cc: reason" \
    "$both_flag" "unresolvable Cc: @noccname at $mid_both"
check "both To+Cc unresolvable: exactly one flag event for the message, not two" 1 \
    "$(grep -c -- "^pm flag thread=$short_both " "$work/once.out")"
contains "both To+Cc unresolvable: the flag event keyword is still greppable for unresolvable-to" \
    "$(cat "$work/once.out")" "unresolvable-to"
contains "both To+Cc unresolvable: the flag event keyword is still greppable for unresolvable-cc" \
    "$(cat "$work/once.out")" "unresolvable-cc"

# ============================================================
printf '\n== the SAME unresolvable @name on both To: and Cc: still flags as To: ==\n'
# UNRESOLVED_TO is one dedup record shared between To: and Cc: (see its own
# comment). When the SAME @-shaped name is unresolvable on both headers of
# one message, the To: block must claim it, not the Cc: block: To: is the
# addressee line and route-dead is stable porcelain a monitor greps to
# learn an addressee is unreachable -- it must not silently disappear just
# because Cc: resolution happened to record the name first.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_same="$(send_msg '@alice' '@bob,@ghostname' 'same unresolvable name on to and cc' 'body' 8 '@ghostname')"
tid_same="$(thread_of "$mid_same")"
short_same="${tid_same:0:8}"
: > "$STUB_ARGV_LOG"
once
check "same name To+Cc: the good To seat still wakes" 1 \
    "$(grep -c -- "^sbx-mail-$short_same-bob-" "$STUB_ARGV_LOG")"
contains "same name To+Cc: route-dead event still fires for the addressee miss" \
    "$(cat "$work/once.out")" "pm route-dead thread=$short_same unresolved=1"
same_flag="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_same" 2>/dev/null)"
contains "same name To+Cc: flag reason names it as unresolvable To:" \
    "$same_flag" "unresolvable To: @ghostname at $mid_same"
not_contains "same name To+Cc: flag reason does not also claim it as unresolvable Cc:" \
    "$same_flag" "unresolvable Cc:"
check "same name To+Cc: exactly one flag event for the message, not two" 1 \
    "$(grep -c -- "^pm flag thread=$short_same " "$work/once.out")"
contains "same name To+Cc: flag event keyword is unresolvable-to" \
    "$(cat "$work/once.out")" "pm flag thread=$short_same reason=unresolvable-to"

# ============================================================
printf '\n== @operator in To: is never treated as unresolvable (rule 0) ==\n'
# ============================================================
# Every documented `mail send`/`mail reply` sends operator mail as the
# literal address @operator, and reply-all puts the parent's From in the
# reply's own To: -- so a reply-all on an operator-started thread always
# carries "@operator" in its To:. Rule 0 already says an address that
# does not resolve, e.g. the operator's own, is skipped silently; @operator
# must get that same silent skip, not the unresolvable-To: flag, since
# pm_flag OVERWRITES (not appends) a thread's flag reason -- treating it
# as a typo would clobber a real flag reason on every single reply.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_op="$(send_msg '@operator' '@team' 'operator thread' 'body from operator' 8)"
tid_op="$(thread_of "$mid_op")"
short_op="${tid_op:0:8}"
once
for a in alice bob carol; do
    run_env="$(env_file_for_agent "$a")"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
    mkdir -p -- "$run_dir/outbox"
    printf '0\n' > "$run_dir/exit-code"
    printf '{}\n' > "$run_dir/summary.json"
done
once

# Pre-flag the thread with a real reason, the way a genuine spawn failure
# would -- to prove @operator's silent-skip does not clobber it.
"$postmaster" flag "$tid_op" "spawn failed for alice: $mid_op" >/dev/null 2>&1

mid_reply="$(reply_msg '@bob' "$mid_op" 'reply from bob')"
contains "bob's reply-all addresses the operator" \
    "$("$MAIL" show "$mid_reply" 2>/dev/null | sed -n 's/^To: //p')" "@operator"
: > "$STUB_ARGV_LOG"
once
if grep -qF -- "route-dead thread=$short_op" "$work/once.out"; then
    no "@operator in To: does not produce a route-dead event"
else
    ok "@operator in To: does not produce a route-dead event"
fi
check "@operator in To: does not clobber a real flag reason" \
    "spawn failed for alice: $mid_op" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_op" 2>/dev/null)"

# ============================================================
printf '\n== @operator sink: zero wake candidates, never unresolvable ==\n'
# ============================================================
# fleet expand's @operator sink (see docs/agent-mail.md, "Routing
# rules") succeeds for @operator with zero candidates -- so it wakes
# nobody by itself, composes with a real seat address without changing
# that seat's wake, and never lands in a route-dead event or an
# unresolvable flag, since it was never unresolved to begin with.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_op_bob="$(send_msg '@alice' '@operator,@bob' 'operator sink plus a real seat' 'body' 8)"
tid_op_bob="$(thread_of "$mid_op_bob")"
short_op_bob="${tid_op_bob:0:8}"
: > "$STUB_ARGV_LOG"
once
check "@operator,@bob: bob wakes" 1 \
    "$(grep -c -- "^sbx-mail-$short_op_bob-bob-" "$STUB_ARGV_LOG")"
check "@operator,@bob: carol does not wake" 0 \
    "$(grep -c -- "^sbx-mail-$short_op_bob-carol-" "$STUB_ARGV_LOG")"
check "@operator,@bob: exactly one seat spawned" 1 \
    "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"
check "@operator,@bob: thread is not flagged needs-operator" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_op_bob" 2>/dev/null || true)"
not_contains "@operator,@bob: no route-dead event fires" \
    "$(cat "$work/once.out")" "route-dead"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid_op_only="$(send_msg '@alice' '@operator' 'operator sink alone' 'body' 8)"
tid_op_only="$(thread_of "$mid_op_only")"
: > "$STUB_ARGV_LOG"
rc="$(once_rc)"
check "@operator alone: deliver --once still exits 0" "0" "$rc"
check "@operator alone: nobody wakes" 0 \
    "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"
check "@operator alone: thread is not flagged needs-operator" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid_op_only" 2>/dev/null || true)"

# ============================================================
printf '\n== seat resolution reaches launcher argv ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

: > "$STUB_ARGV_LOG"
send_msg '@bob' '@alice' 'seat alice' 'body' 8 >/dev/null
once
check "seat alice: harness falls back to default (unset anywhere but frontmatter)" "claude" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
check "seat alice: model from persona frontmatter" "opus" "$(argv_after '--model' "$STUB_ARGV_LOG")"
check "seat alice: network defaults to pinned" "pinned" "$(argv_after '--network' "$STUB_ARGV_LOG")"
if grep -qF -- '--pi-args' "$STUB_ARGV_LOG"; then
    no "seat alice: no --pi-args on a claude harness"
else
    ok "seat alice: no --pi-args on a claude harness"
fi
check "seat alice: thinking passed as --effort on a claude harness" "high" "$(argv_after '--effort' "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
send_msg '@alice' '@bob' 'seat bob' 'body' 8 >/dev/null
once
check "seat bob: harness from fleet.yaml" "pi" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
if grep -qF -- '--model' "$STUB_ARGV_LOG"; then
    no "seat bob: no --model on a pi harness with no configured model (sonnet is a claude alias)" \
        "$(argv_after '--model' "$STUB_ARGV_LOG")"
else
    ok "seat bob: no --model on a pi harness with no configured model (sonnet is a claude alias)"
fi
check "seat bob: network from fleet.yaml" "sealed" "$(argv_after '--network' "$STUB_ARGV_LOG")"
check "seat bob: thinking passed as --pi-args on a pi harness" "--thinking medium" "$(argv_after '--pi-args' "$STUB_ARGV_LOG")"
check "seat bob: no --effort on a pi harness" 0 "$(grep -c -- '^--effort$' "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
send_msg '@alice' '@carol' 'seat carol' 'body' 8 >/dev/null
once
check "seat carol: harness defaults to claude (all-empty agent)" "claude" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
check "seat carol: model defaults to sonnet (all-empty agent)" "sonnet" "$(argv_after '--model' "$STUB_ARGV_LOG")"
check "seat carol: network defaults to pinned (all-empty agent)" "pinned" "$(argv_after '--network' "$STUB_ARGV_LOG")"
if grep -qF -- '--pi-args' "$STUB_ARGV_LOG"; then
    no "seat carol: no --pi-args on a claude harness"
else
    ok "seat carol: no --pi-args on a claude harness"
fi
check "seat carol: no --effort without thinking" 0 "$(grep -c -- '^--effort$' "$STUB_ARGV_LOG")"
if grep -qF -- '--preset' "$STUB_ARGV_LOG"; then
    no "seat carol: no --preset flag on a presetless seat (regression guard)"
else
    ok "seat carol: no --preset flag on a presetless seat (regression guard)"
fi

: > "$STUB_ARGV_LOG"
send_msg '@alice' '@gina' 'seat gina' 'body' 8 >/dev/null
once
check "seat gina: --preset carries the fleet.yaml preset name" "solo" \
    "$(argv_after '--preset' "$STUB_ARGV_LOG")"
check "seat gina: --harness still passed, unchanged by the preset" "pi" \
    "$(argv_after '--harness' "$STUB_ARGV_LOG")"
check "seat gina: --model still passed, unchanged by the preset" "vendor/ginamodel" \
    "$(argv_after '--model' "$STUB_ARGV_LOG")"
if (( $(argv_line_of '--preset' "$STUB_ARGV_LOG") < $(argv_line_of '--harness' "$STUB_ARGV_LOG") )); then
    ok "seat gina: --preset positioned before --harness in argv"
else
    no "seat gina: --preset positioned before --harness in argv"
fi

# ============================================================
printf '\n== spawn: INBOX recorded in the run env file ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

STUB_BALANCE_LOG="$work/balance-local.log"
export STUB_BALANCE_LOG
send_msg '@bob' '@alice' 'inbox key' 'body' 8 >/dev/null
once
run_env="$(env_file_for_agent alice)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
check "spawn: INBOX recorded in the run's env file" "INBOX=$run_dir/inbox" \
    "$(grep '^INBOX=' "$run_env")"
contains "spawn: thread context reaches local launcher" "$(cat "$STUB_BALANCE_LOG")" "agent=alice"
contains "spawn: root headers reach local launcher" "$(cat "$STUB_BALANCE_LOG")" "Subject: inbox key"
unset STUB_BALANCE_LOG

# ============================================================
printf '\n== X-Hops 0 gate: no spawn, thread flagged ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'hops zero' 'body' 0)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "X-Hops 0: no spawn" 0 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "X-Hops 0: flag names the message id" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "$mid"
contains "X-Hops 0: flag reason says hops exhausted" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "hops exhausted"
contains "X-Hops 0: refuse event names bob" "$(cat "$work/once.out")" \
    "pm refuse thread=$short agent=bob reason=hops"
contains "X-Hops 0: flag event uses the fixed hops-exhausted keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$short reason=hops-exhausted"

# ============================================================
printf '\n== thread budget: default 96, env override, flag on exhaust ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'budget default' 'body' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns"
seq 1 96 > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
: > "$STUB_ARGV_LOG"
once
check "budget default 96: no spawn once exhausted" 0 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "budget default 96: flag names the limit" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "thread budget 96 exhausted"
contains "budget default 96: refuse event names bob" \
    "$(cat "$work/once.out")" "pm refuse thread=$short agent=bob reason=budget"
contains "budget default 96: flag event uses the fixed budget-exhausted keyword" \
    "$(cat "$work/once.out")" "pm flag thread=$short reason=budget-exhausted"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_THREAD_BUDGET=1
mid1="$(send_msg '@alice' '@bob' 'budget override' 'body one' 8)"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "budget override 1: first message spawns" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "budget override 1: spawn count is 1" "1" "$(spawn_count_of "$tid")"
mid2="$(reply_msg '@alice' "$mid1" 'body two' --to '@carol')"
: > "$STUB_ARGV_LOG"
once
check "budget override 1: second message (different agent) still blocked" 0 \
    "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"
contains "budget override 1: flag names the override value" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "thread budget 1 exhausted"
unset FORK_SANDBOX_THREAD_BUDGET

finish_suite
