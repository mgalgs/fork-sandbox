#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/18-panel-stall.sh — fork-sandbox-postmaster.sh: the three
# fixes for a review panel that stalls after a reviewer's replies are all
# discarded: `on-silence: retry`, the re-gate of deferred seats after a
# zero-reply harvest, and the durable run record behind `status --json`.
#
# Usage: tests/postmaster/18-panel-stall.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# rita retries a discarded reply; wanda is gated by wake-when: gate.
for ps_seat in rita wanda; do
    printf 'Panel fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/$ps_seat.md"
done
sed -i 's/^agents:$/agents:\n  rita:\n    on-silence: retry\n  wanda:\n    wake-when: gate/' "$FORK_SANDBOX_FLEET_FILE"
"$FLEET" check >/dev/null 2>&1 || { echo "FATAL: panel fixture fleet fails check" >&2; exit 1; }

ps_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$STUB_ARGV_LOG"
}
# ps_bad <agent>: ends the live run cleanly with one unparseable reply file.
ps_bad() {
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "$(live_env_for_agent "$1")")"
    mkdir -p -- "$rd/outbox"
    printf 'this line is not a header\n\nbody\n' > "$rd/outbox/mail-1.md"
    printf '0\n' > "$rd/exit-code"
    printf '{}\n' > "$rd/summary.json"
}
ps_spawns() { grep -c -- "^sbx-mail-${ps_short}-$1-" "$STUB_ARGV_LOG" || true; }
ps_retry_file() { printf '%s' "$PM_STATE_DIR/retries/$ps_tid/$1"; }
# The newest run record of an agent on the thread, by spawn order.
ps_last_env() {
    local rid
    rid="$(while read -r r; do
        grep -q "^AGENT=$1\$" "$PM_STATE_DIR/runs/$r.env" && echo "$r"
    done < "$PM_STATE_DIR/seq/$ps_tid" | tail -n1)"
    printf '%s' "$PM_STATE_DIR/runs/$rid.env"
}
ps_handoff() { cat "$PM_STATE_DIR/handoffs/$(basename "$1" .env).md"; }

# ============================================================
printf '\n== on-silence: retry: a wake whose reply files were all discarded is re-woken once ==\n'
# ============================================================

ps_store
ps_mid="$(send_msg '@alice' '@rita' 'retry topic' 'please answer' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
ps_rid1="$(basename "$(live_env_for_agent rita)" .env)"
ps_bad rita
once
check "retry: the discarded wake schedules a retry (reason malformed)" malformed \
    "$(env_val "$(ps_retry_file rita)" REASON)"
check "retry: it is due on the next pass" pending "$(env_val "$(ps_retry_file rita)" STATE)"
check "retry: status retries[] carries reason malformed" malformed \
    "$(we_py "$(we_json "$ps_tid")" 'd["retries"][0]["reason"]')"
check "retry: the needs-operator flag for the malformed file stays" 1 \
    "$(grep -c 'malformed reply file mail-1.md' "$PM_STATE_DIR/needs-operator/$ps_tid")"
check "retry: no second spawn before the retry pass" 1 "$(ps_spawns rita)"
once
check "retry: the next pass re-wakes the seat" 2 "$(ps_spawns rita)"
ps_env2="$(live_env_for_agent rita)"
check "retry: on the same trigger" "$ps_mid" "$(env_val "$ps_env2" TRIGGER)"
check "retry: the run record names the run it retried" "$ps_rid1" "$(env_val "$ps_env2" RETRY_OF)"
check "retry: the run record carries the kind" malformed "$(env_val "$ps_env2" RETRY_KIND)"
ps_ho="$(ps_handoff "$ps_env2")"
contains "retry: handoff has the discarded-reply section" "$ps_ho" "## Your previous reply was discarded"
contains "retry: handoff quotes the discard reason verbatim" "$ps_ho" \
    "- malformed reply file mail-1.md: unparseable header stanza: this line is not a header"
not_contains "retry: handoff does not claim a crash" "$ps_ho" "## This is a retry"
not_contains "retry: handoff does not say nothing was posted" "$ps_ho" "posted nothing"
check "retry: the malformed schedule is spent, FAILS untouched" 0 \
    "$([[ -e "$(ps_retry_file rita)" ]] && echo 1 || echo 0)"
check "retry: the discard record is consumed by the handoff" 0 \
    "$([[ -e "$PM_STATE_DIR/discards/$ps_tid/rita" ]] && echo 1 || echo 0)"
ps_bad rita
once
once
check "retry: a second all-malformed wake is not retried again" 2 "$(ps_spawns rita)"
check "retry: and leaves no retry file" 0 "$([[ -e "$(ps_retry_file rita)" ]] && echo 1 || echo 0)"

printf '\n== on-silence: retry: a wake that wrote no reply file is flagged, not retried ==\n'
ps_store
ps_mid="$(send_msg '@alice' '@rita' 'quiet topic' 'maybe answer' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
ps_rid1="$(basename "$(live_env_for_agent rita)" .env)"
finish_run rita 0
once
once
check "retry: a no-file wake spawns nothing more" 1 "$(ps_spawns rita)"
check "retry: a no-file wake is flagged as on-silence: flag is" \
    "wake for rita posted no reply (run $ps_rid1)" "$(cat "$PM_STATE_DIR/needs-operator/$ps_tid")"

printf '\n== on-silence: retry: no retry when a newer message is pending ==\n'
ps_store
ps_mid="$(send_msg '@alice' '@rita' 'busy topic' 'first' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
reply_msg '@alice' "$ps_mid" 'second, while you work' --to '@rita' >/dev/null
once
ps_bad rita
once
once
check "retry: the follow-up on the newer message is the only extra wake" 2 "$(ps_spawns rita)"
check "retry: no malformed schedule was kept" 0 "$([[ -e "$(ps_retry_file rita)" ]] && echo 1 || echo 0)"
not_contains "retry: the follow-up handoff is not a discard retry" \
    "$(ps_handoff "$(live_env_for_agent rita)")" "## Your previous reply was discarded"

printf '\n== on-silence: retry: no retry on a closed thread ==\n'
ps_store
ps_mid="$(send_msg '@alice' '@rita' 'closing topic' 'first' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
reply_msg '@ci-demo' "$ps_mid" 'closed' --to '@alice' --upstream-state closed >/dev/null
ps_bad rita
once
once
check "retry: a closed thread schedules no retry" 1 "$(ps_spawns rita)"
check "retry: and no retry file" 0 "$([[ -e "$(ps_retry_file rita)" ]] && echo 1 || echo 0)"

printf '\n== crash retries: reason failed, and no shared budget with a malformed retry ==\n'
ps_store
ps_mid="$(send_msg '@alice' '@rita' 'crash topic' 'go' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
ps_rid1="$(basename "$(live_env_for_agent rita)" .env)"
finish_run rita 1
once
check "crash retry: reason is failed" failed "$(env_val "$(ps_retry_file rita)" REASON)"
check "crash retry: status retries[] reason is failed" failed \
    "$(we_py "$(we_json "$ps_tid")" 'd["retries"][0]["reason"]')"
check "crash retry: FAILS is not the malformed marker" "" "$(env_val "$(ps_retry_file rita)" FAILS)"
sed -i 's/^NOT_BEFORE=.*/NOT_BEFORE=1/' "$(ps_retry_file rita)"
once
ps_env2="$(live_env_for_agent rita)"
check "crash retry: the retry run is kind failed" failed "$(env_val "$ps_env2" RETRY_KIND)"
check "crash retry: and names the failed run" "$ps_rid1" "$(env_val "$ps_env2" RETRY_OF)"
contains "crash retry: its handoff is the crash text" "$(ps_handoff "$ps_env2")" "## This is a retry"
ps_bad rita
once
check "crash then discard: the crash-retry run itself still gets its one malformed retry" malformed \
    "$(env_val "$(ps_retry_file rita)" REASON)"
check "crash then discard: ATTEMPT starts at 0, apart from the crash budget" 0 \
    "$(env_val "$(ps_retry_file rita)" ATTEMPT)"
once
check "crash then discard: the malformed retry fires" malformed "$(env_val "$(live_env_for_agent rita | xargs)" RETRY_KIND)"
check "crash then discard: the recovered crash record is put back" recovered \
    "$(env_val "$(ps_retry_file rita)" STATE)"
check "crash then discard: with its ATTEMPT" 1 "$(env_val "$(ps_retry_file rita)" ATTEMPT)"
finish_run rita 1
once
check "crash after the malformed retry continues the crash backoff, not attempt 0" 1 \
    "$(env_val "$(ps_retry_file rita)" ATTEMPT)"
check "crash after the malformed retry: reason failed" failed "$(env_val "$(ps_retry_file rita)" REASON)"
sed -i 's/^NOT_BEFORE=.*/NOT_BEFORE=1/' "$(ps_retry_file rita)"
once
ps_n="$(ps_spawns rita)"
ps_bad rita
once
once
check "the (seat, trigger) malformed retry is spent even across a crash in between" "$ps_n" "$(ps_spawns rita)"

printf '\n== malformed schedule ended early: the crash record comes back ==\n'
for ps_end in newer closed; do
    ps_store
    ps_mid="$(send_msg '@alice' '@rita' "early $ps_end" 'go' 8)"
    ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
    once
    finish_run rita 1
    once
    sed -i 's/^NOT_BEFORE=.*/NOT_BEFORE=1/' "$(ps_retry_file rita)"
    once
    ps_bad rita
    once
    check "early $ps_end: the malformed schedule is pending" malformed "$(env_val "$(ps_retry_file rita)" REASON)"
    if [[ "$ps_end" == newer ]]; then
        reply_msg '@alice' "$ps_mid" 'newer message' --to '@rita' >/dev/null
    else
        reply_msg '@ci-demo' "$ps_mid" 'closed' --to '@alice' --upstream-state closed >/dev/null
    fi
    once
    once
    check "early $ps_end: retries/ shows recovered again" recovered "$(env_val "$(ps_retry_file rita)" STATE)"
    check "early $ps_end: with its ATTEMPT" 1 "$(env_val "$(ps_retry_file rita)" ATTEMPT)"
    check "early $ps_end: reason failed" failed "$(env_val "$(ps_retry_file rita)" REASON)"
    check "early $ps_end: no stale .prior" 0 "$([[ -e "$PM_STATE_DIR/discards/$ps_tid/rita.prior" ]] && echo 1 || echo 0)"
done

# ============================================================
printf '\n== re-gate: a zero-reply harvest re-runs the gate of a deferred seat ==\n'
# ============================================================

new_root PS_HOOKS
new_root PS_OUT
# shellcheck disable=SC2031  # the subshell is hk_call's, not this scope
export PS_OUT FORK_SANDBOX_HOOKS_DIR="$PS_HOOKS"
# The gate records the status it was handed and defers on its first run
# (when the message arrives) and then per $PS_OUT/verdict.
cat > "$PS_HOOKS/wake-when.gate" <<'GATE'
#!/usr/bin/env bash
echo "$FS_HOOK_AGENT $FS_HOOK_MESSAGE" >> "$PS_OUT/calls"
cp "$FS_HOOK_STATUS_FILE" "$PS_OUT/status.$(wc -l < "$PS_OUT/calls")"
exit "$(cat "$PS_OUT/verdict")"
GATE
chmod +x "$PS_HOOKS/wake-when.gate"

ps_store
: > "$PS_OUT/calls"
echo 1 > "$PS_OUT/verdict"
ps_mid="$(send_msg '@alice' '@wanda, @rita' 'panel topic' 'review please' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
check "re-gate: the gate deferred wanda on arrival" "wanda $ps_mid" "$(cat "$PM_STATE_DIR/wake-deferred/$ps_tid")"
check "re-gate: status wake_deferred lists the deferral" "[{'agent': 'wanda', 'message_id': '$ps_mid'}]" \
    "$(we_py "$(we_json "$ps_tid")" 'd["wake_deferred"]')"
check "re-gate: rita (no gate) spawned" 1 "$(ps_spawns rita)"
check "re-gate: one gate run so far" 1 "$(wc -l < "$PS_OUT/calls")"
ps_rita_rid="$(basename "$(live_env_for_agent rita)" .env)"
echo 0 > "$PS_OUT/verdict"
ps_bad rita
once
contains "re-gate: the event names thread, agent and the harvested run" "$(cat "$work/once.out")" \
    "pm regate thread=$ps_short agent=wanda run=$ps_rita_rid"
check "re-gate: the gate ran again, on the deferred message" "wanda $ps_mid" "$(tail -n1 "$PS_OUT/calls")"
check "re-gate: exit 0 woke the seat" 1 "$(ps_spawns wanda)"
check "re-gate: the deferral record is gone" 0 "$([[ -s "$PM_STATE_DIR/wake-deferred/$ps_tid" ]] && echo 1 || echo 0)"
check "re-gate: the gate saw the harvested run with replies 0 and harvested_at" "[0, True, 'clean']" \
    "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = [r for r in d["runs"] if r["run_id"] == sys.argv[2]][0]
print([r["replies"], bool(r["harvested_at"]), r["outcome"]])' "$PS_OUT/status.2" "$ps_rita_rid")"

printf '\n== re-gate: exit 1 re-defers, and the quiescence flag still fires ==\n'
ps_store
: > "$PS_OUT/calls"
echo 1 > "$PS_OUT/verdict"
ps_mid="$(send_msg '@alice' '@wanda, @rita' 'panel topic two' 'review please' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
finish_run rita 0
once
check "re-gate: the gate ran a second time" 2 "$(wc -l < "$PS_OUT/calls")"
check "re-gate: exit 1 left no wanda spawn" 0 "$(ps_spawns wanda)"
check "re-gate: and the same deferral line" "wanda $ps_mid" "$(cat "$PM_STATE_DIR/wake-deferred/$ps_tid")"
contains "re-gate: the quiescence flag fires as before" "$(cat "$PM_STATE_DIR/needs-operator/$ps_tid")" \
    "wake deferred: @wanda at $ps_mid and nothing woke it"

printf '\n== re-gate: a closed thread is skipped ==\n'
ps_store
: > "$PS_OUT/calls"
echo 1 > "$PS_OUT/verdict"
ps_mid="$(send_msg '@alice' '@wanda, @rita' 'panel topic three' 'review please' 8)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
reply_msg '@ci-demo' "$ps_mid" 'closed' --to '@alice' --upstream-state closed >/dev/null
finish_run rita 0
once
check "re-gate: no gate run on a closed thread" 1 "$(wc -l < "$PS_OUT/calls")"
unset FORK_SANDBOX_HOOKS_DIR

# ============================================================
printf '\n== durable run record and status --json runs[] ==\n'
# ============================================================

ps_store
k8s_rt1_seed
printf '%s\n' 'kick off' > "$work/body.tmp"
ps_mid="$("$MAIL" send --from '@dana' --to '@carol' --subject 'record topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
ps_tid="$(thread_of "$ps_mid")"; ps_short="${ps_tid:0:8}"
once
ps_env="$(live_env_for_agent carol)"
check "record: a non-follow seat gets WOKEN_AT_SHA" "$rt1_sha" "$(env_val "$ps_env" WOKEN_AT_SHA)"
check "record: while REVIEW_TARGET_SHA keeps its follow-only meaning" "" "$(env_val "$ps_env" REVIEW_TARGET_SHA)"
ps_live="$(we_json "$ps_tid")"
check "record: live run has null harvest fields" "[None, None, None, None]" \
    "$(we_py "$ps_live" '[d["runs"][0][k] for k in ("harvested_at","replies","reply_files","outcome")]')"
check "record: live run carries trigger and target" "['$ps_mid', '$rt1_sha']" \
    "$(we_py "$ps_live" '[d["runs"][0]["trigger"], d["runs"][0]["review_target_sha"]]')"
rd="$(env_val "$ps_env" RUN_DIR)"
printf '0\n' > "$rd/exit-code"; printf '{}\n' > "$rd/summary.json"
printf 'Subject: ok\n\nfine\n' > "$rd/outbox/mail-1.md"
printf 'junk\n\nbody\n' > "$rd/outbox/mail-2.md"
once
ps_done="$(we_json "$ps_tid")"
check "record: harvested run shows replies, reply_files, outcome" "[1, 2, 'clean', None]" \
    "$(we_py "$ps_done" '[d["runs"][0]["replies"], d["runs"][0]["reply_files"], d["runs"][0]["outcome"], d["runs"][0]["retry_of"]]')"
check "record: harvested_at is ISO-8601 UTC" 1 \
    "$(we_py "$ps_done" '1 if __import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["runs"][0]["harvested_at"]) else 0')"
check "record: review_target_version is an integer" "<class 'int'>" \
    "$(we_py "$ps_done" 'type(d["runs"][0]["review_target_version"])')"
check "record: wake_deferred is an empty list" "[]" "$(we_py "$ps_done" 'd["wake_deferred"]')"

# An old record (pre-change keys only): falls back to REVIEW_TARGET_SHA, nulls elsewhere.
printf 'AGENT=carol\nTHREAD=%s\nRUN_DIR=/runs/old\nREVIEW_TARGET_SHA=abc123\nREVIEW_TARGET_VERSION=4\n' "$ps_tid" \
    > "$PM_STATE_DIR/runs/old-run.env"
: > "$PM_STATE_DIR/harvested/old-run"
check "record: an old run falls back to REVIEW_TARGET_SHA/VERSION, nulls elsewhere" \
    "['abc123', 4, None, None, None, None, None]" \
    "$(we_py "$(we_json "$ps_tid")" '[ [r for r in d["runs"] if r["run_id"]=="old-run"][0][k] for k in ("review_target_sha","review_target_version","trigger","harvested_at","replies","outcome","retry_of")]')"

finish_suite
