#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/15-upstream-status.sh — fork-sandbox-postmaster.sh:
# X-Upstream-State, --help and dispatcher wiring, status views.
#
# Usage: tests/postmaster/15-upstream-status.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

k8s_wake_fixture  # no wake may reach the real k8s wrapper; see lib.sh

# ============================================================
printf '\n== upstream state: X-Upstream-State closed stops a thread waking its seats ==\n'
# ============================================================

# Nothing in this group may reach a real wake wrapper (a k8s seat is held
# before any launch, but a regression must not start tmux either).
export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT=/bin/true
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0

us_calls() { grep -c -- '----CALL----' "$STUB_ARGV_LOG"; }
us_has() { [[ -e "$1" ]] && echo 1 || echo 0; }
us_close() { reply_msg '@ci-demo' "$1" "${2:-the pull request was closed}" --to "${3:-@alice}" --upstream-state closed; }

# -- one thread through the whole life: running wake at close, a flag, a
# fleet sender's attempts, later mail, a hops-0 message, a restart --
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
hk_install on-quiescent on-harvest

: > "$STUB_ARGV_LOG"
us1_mid="$(send_msg '@carol' '@alice' 'closing topic' 'please review' 8)"
us1_tid="$(thread_of "$us1_mid")"
us1_short="${us1_tid:0:8}"
once
check "upstream-state: alice's wake spawned while the thread was open" 1 "$(us_calls)"
check "upstream-state: a thread that never saw the header has no state file" 0 \
    "$(us_has "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
check "upstream-state: an unseen thread has no upstream_state key in status --json" 0 \
    "$("$postmaster" status --thread "$us1_tid" --json | grep -c upstream_state)"

# A fleet seat can neither close nor reopen: delivered, header ignored.
reply_msg '@bob' "$us1_mid" 'bob tries to close it' --to '@carol' --upstream-state closed >/dev/null
: > "$work/once.out"
once
contains "upstream-state: a fleet sender's header is ignored and logged" "$(cat "$work/once.out")" \
    "pm upstream-state-ignored thread=$us1_short reason=fleet-sender"
check "upstream-state: a fleet sender writes no state file" 0 \
    "$(us_has "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
check "upstream-state: the fleet sender's message still woke its addressee" 2 "$(us_calls)"

# A flag present at close, and a message pending on the running wake.
mkdir -p -- "$PM_STATE_DIR/needs-operator"
printf 'something went wrong earlier\n' > "$PM_STATE_DIR/needs-operator/$us1_tid"
reply_msg '@carol' "$us1_mid" 'one more thing for alice' --to '@alice' >/dev/null
once
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
us_close "$us1_mid" >/dev/null
once
us1_close_mid="$(grep -l '^From: @ci-demo$' "$FORK_SANDBOX_MAIL_ROOT/threads/$us1_tid"/*.msg | xargs grep -l '^X-Upstream-State: closed$' | head -n1 | xargs sed -n 's/^Message-ID: //p')"
contains "upstream-state: closing emits an upstream-state event" "$(cat "$work/once.out")" \
    "pm upstream-state thread=$us1_short state=closed msg=${us1_close_mid:0:8}"
check "upstream-state: STATE=closed is persisted" "closed" \
    "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
check "upstream-state: the state records the closing message" "$us1_close_mid" \
    "$(sed -n 's/^MSGID=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
check "upstream-state: the closing message woke no one" 0 "$(us_calls)"
contains "upstream-state: the closing message's To: seat is refused" "$(cat "$work/once.out")" \
    "pm refuse thread=$us1_short agent=alice reason=upstream-closed"
check "upstream-state: a needs-operator flag present at close is cleared" 0 \
    "$(us_has "$PM_STATE_DIR/needs-operator/$us1_tid")"
check "upstream-state: the clear is journaled like an unflag" 1 \
    "$(awk -F'\t' '$2=="unflag"{c++} END{print c+0}' "$PM_STATE_DIR/needs-operator-journal/$us1_tid")"
check "upstream-state: the closing message is routed" 1 "$(us_has "$PM_STATE_DIR/routed/$us1_close_mid")"

# Redundant closed: no event, no change.
us_close "$us1_mid" 'closed again' >/dev/null
: > "$work/once.out"
once
not_contains "upstream-state: a redundant closed emits no state event" "$(cat "$work/once.out")" "pm upstream-state "

# The wake that was running at close fails: evidence kept, nothing else.
finish_run alice 1
: > "$work/once.out"
once
check "upstream-state: a running wake failing after close raises no flag" 0 \
    "$(us_has "$PM_STATE_DIR/needs-operator/$us1_tid")"
not_contains "upstream-state: ... and no flag event" "$(cat "$work/once.out")" "pm flag "
check "upstream-state: ... but its wake-exit record is still written" 1 \
    "$(find "$PM_STATE_DIR/wake-exits/$us1_tid/alice" -name "*.json" 2>/dev/null | wc -l)"
contains "upstream-state: ... and status --json serves it" \
    "$("$postmaster" status --thread "$us1_tid" --json)" '"wake_failures"'
check "upstream-state: ... no retry is scheduled" 0 \
    "$(grep -l 'STATE=pending' "$PM_STATE_DIR/retries/$us1_tid"/* 2>/dev/null | wc -l)"
contains "upstream-state: ... the pending message's follow-up wake is refused" "$(cat "$work/once.out")" \
    "pm refuse thread=$us1_short agent=alice reason=upstream-closed"
check "upstream-state: ... and spawned nothing" 0 "$(us_calls)"

# Later mail: archived, routed, no wake, no flag -- even a hops-0 message.
reply_msg '@carol' "$us1_mid" 'late mail' --to '@bob,@alice' >/dev/null
reply_msg '@carol' "$us1_mid" 'exhausted' --to '@bob' --hops 0 >/dev/null
: > "$work/once.out"
once
check "upstream-state: later mail wakes no one" 0 "$(us_calls)"
contains "upstream-state: later mail's refusals are named" "$(cat "$work/once.out")" \
    "pm refuse thread=$us1_short agent=bob reason=upstream-closed"
check "upstream-state: a hops-0 message on a closed thread flags nothing" 0 \
    "$(us_has "$PM_STATE_DIR/needs-operator/$us1_tid")"
check "upstream-state: no mail is left unrouted" 0 \
    "$("$postmaster" status --thread "$us1_tid" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["unrouted"])')"

# Visibility: status --json, the human status, hooks.
us1_json="$("$postmaster" status --thread "$us1_tid" --json)"
check "upstream-state: status --json shows closed, the closing message and a time" "closed $us1_close_mid 1" \
    "$(python3 -c 'import json,sys; u=json.loads(sys.argv[1])["upstream_state"]; print(u["state"], u["message_id"], int(bool(u["at"])))' "$us1_json")"
contains "upstream-state: the human status shows the thread as CLOSED" \
    "$("$postmaster" status 2>&1)" "$us1_tid: CLOSED"
finish_run carol 0
once
once
check "upstream-state: a closed thread fires on-quiescent" 1 "$([[ "$(hk_count on-quiescent)" -ge 1 ]] && echo 1 || echo 0)"
check "upstream-state: on-quiescent gets FS_HOOK_UPSTREAM_STATE=closed" "closed" "$(hk_env on-quiescent FS_HOOK_UPSTREAM_STATE)"
check "upstream-state: the thread is not flagged when it goes quiet" 0 \
    "$(us_has "$PM_STATE_DIR/needs-operator/$us1_tid")"

# Plain operator mail does NOT reopen; the state survives the restart (each
# `once` is a fresh process).
: > "$STUB_ARGV_LOG"
reply_msg '@ci-demo' "$us1_mid" 'a plain operator word' --to '@alice' >/dev/null
once
check "upstream-state: plain operator mail does not reopen a closed thread" "closed" \
    "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
check "upstream-state: ... and wakes no one" 0 "$(us_calls)"

# A fleet seat cannot reopen either.
reply_msg '@bob' "$us1_mid" 'bob tries to reopen' --to '@carol' --upstream-state open >/dev/null
once
check "upstream-state: a fleet sender cannot reopen" "closed" \
    "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"

# open reopens; routing is as before, rule 1's reset applies.
: > "$work/once.out"
reply_msg '@ci-demo' "$us1_mid" 'reopened' --to '@alice' --upstream-state open >/dev/null
once
contains "upstream-state: open emits an upstream-state event" "$(cat "$work/once.out")" \
    "pm upstream-state thread=$us1_short state=open msg="
check "upstream-state: open woke the addressed seat again" 1 "$(us_calls)"
check "upstream-state: status --json shows open once reopened" "open" \
    "$("$postmaster" status --thread "$us1_tid" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["upstream_state"]["state"])')"
check "upstream-state: the human status no longer lists it as CLOSED" 0 \
    "$("$postmaster" status 2>&1 | grep -c "$us1_tid: CLOSED")"

# -- a non-fleet X-Upstream-Head reopens; both flags on one reply: state wins --
us_head_sha="$(printf 'a%.0s' {1..40})"
us_close "$us1_mid" 'closed once more' >/dev/null
once
check "upstream-state: closed again" "closed" "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
: > "$work/once.out"
reply_msg '@ci-demo' "$us1_mid" 'pushed after reopen' --to '@alice' --upstream-head "feature/y:$us_head_sha" >/dev/null
once
check "upstream-state: a non-fleet X-Upstream-Head reopens a closed thread" "open" \
    "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
contains "upstream-state: ... with the state event" "$(cat "$work/once.out")" "pm upstream-state thread=$us1_short state=open"
reply_msg '@ci-demo' "$us1_mid" 'closed and pushed' --to '@alice' \
    --upstream-head "feature/y:$us_head_sha" --upstream-state closed >/dev/null
once
check "upstream-state: both flags on one reply: the explicit state wins" "closed" \
    "$(sed -n 's/^STATE=//p' "$PM_STATE_DIR/upstream-state/$us1_tid.env")"
hk_uninstall

# -- a closed thread's retry is refused and dropped when it comes due --
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
us2_mid="$(send_msg '@carol' '@alice' 'retry then close' 'first' 8)"
us2_tid="$(thread_of "$us2_mid")"
us2_short="${us2_tid:0:8}"
once
finish_run alice 1
once
check "upstream-state retry: the failure scheduled a pending retry" 1 \
    "$(grep -l 'STATE=pending' "$PM_STATE_DIR/retries/$us2_tid"/* 2>/dev/null | wc -l)"
us_close "$us2_mid" >/dev/null
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "upstream-state retry: the due retry spawned nothing" 0 "$(us_calls)"
contains "upstream-state retry: the retry is refused with the closed reason" "$(cat "$work/once.out")" \
    "pm refuse thread=$us2_short agent=alice reason=upstream-closed"
not_contains "upstream-state retry: no retry event is emitted" "$(cat "$work/once.out")" "pm retry "
check "upstream-state retry: the schedule is dropped" 0 \
    "$(grep -l 'STATE=pending' "$PM_STATE_DIR/retries/$us2_tid"/* 2>/dev/null | wc -l)"
check "upstream-state retry: the thread is not flagged" 0 "$(us_has "$PM_STATE_DIR/needs-operator/$us2_tid")"

# -- a clean wake that finishes after the close: its mail is archived, wakes no one --
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
us3_mid="$(send_msg '@carol' '@alice' 'harvest after close' 'first' 8)"
us3_tid="$(thread_of "$us3_mid")"
once
us_close "$us3_mid" >/dev/null
once
finish_run alice 0
printf 'To: @bob\nSubject: late finding\n\nfound it\n' > "$(sed -n 's/^RUN_DIR=//p' "$(env_file_for_agent alice)")/outbox/mail-1.md"
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
once
check "upstream-state harvest: the late reply is archived" 1 \
    "$(grep -l '^Subject: late finding' "$FORK_SANDBOX_MAIL_ROOT/threads/$us3_tid"/*.msg 2>/dev/null | wc -l)"
check "upstream-state harvest: ... and wakes no one" 0 "$(us_calls)"
check "upstream-state harvest: ... and flags nothing" 0 "$(us_has "$PM_STATE_DIR/needs-operator/$us3_tid")"

# -- a held seat's release is refused, and the held record goes --
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
us4_mid="$(send_msg '@carol' '@karl' 'held then close' 'first' 8)"
us4_tid="$(thread_of "$us4_mid")"
us4_short="${us4_tid:0:8}"
once
check "upstream-state held: the seat is held awaiting a grant" 1 "$(us_has "$PM_STATE_DIR/held/$us4_tid/karl")"
us_close "$us4_mid" 'closed' '@karl' >/dev/null
once
"$MAIL" grant "$us4_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "upstream-state held: the granted seat is not launched" 0 "$(us_calls)"
contains "upstream-state held: the release is refused with the closed reason" "$(cat "$work/once.out")" \
    "pm refuse thread=$us4_short agent=karl reason=upstream-closed"
not_contains "upstream-state held: no held-release event" "$(cat "$work/once.out")" "pm held-release"
check "upstream-state held: the held record is removed" 0 "$(us_has "$PM_STATE_DIR/held/$us4_tid/karl")"

unset FORK_SANDBOX_POSTMASTER_K8S_DETACH FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

# ============================================================
printf '\n== --help and dispatcher wiring ==\n'
# ============================================================

help_out="$("$postmaster" --help 2>&1)"
contains "--help prints usage naming deliver" "$help_out" "deliver"
contains "--help documents the routing rules" "$help_out" "ROUTING RULES"
contains "--help documents handler:exec seats" "$help_out" "handler: exec"
contains "--help documents FORK_SANDBOX_HANDLERS_DIR" "$help_out" "FORK_SANDBOX_HANDLERS_DIR"
contains "--help documents FORK_SANDBOX_HANDLER_TIMEOUT" "$help_out" "FORK_SANDBOX_HANDLER_TIMEOUT"

dispatcher="$repo_dir/scripts/fork-sandbox"
if [[ -x "$dispatcher" ]]; then
    disp_help="$("$dispatcher" postmaster --help 2>&1)"
    contains "fork-sandbox postmaster --help reaches the postmaster script" "$disp_help" "fork-sandbox-postmaster.sh"
else
    no "dispatcher wiring" "scripts/fork-sandbox is not executable"
fi

# ============================================================
printf '\n== status: plain text unchanged; --thread --json per-thread view ==\n'
# ============================================================

# BEGIN status-fixture
# A hand-written, fully deterministic postmaster state: fixed ids, and every
# time-derived value pinned by the stub `date` below, so the plain `status`
# text can be compared byte for byte against a golden file.
SFX_T1="aaaaaaaa-1111-4111-8111-000000000001"
SFX_T2="bbbbbbbb-2222-4222-8222-000000000002"
SFX_T3="cccccccc-3333-4333-8333-000000000003"
SFX_NOW=1700000000

sfx_msg() {
    local root="$1" tid="$2" seq="$3" mid="$4" from="$5"
    mkdir -p -- "$root/threads/$tid"
    printf 'Message-ID: %s\nThread-ID: %s\nDate: Tue, 14 Nov 2023 22:13:20 +0000\nFrom: %s\nTo: @bob\nSubject: fixture\nX-Hops: 8\n\nbody\n' \
        "$mid" "$tid" "$from" > "$root/threads/$tid/$seq-$mid.msg"
}

sfx_build() {
    local root="$1" st="$1/.postmaster"
    sfx_msg "$root" "$SFX_T1" 001 "$SFX_T1" @alice
    sfx_msg "$root" "$SFX_T1" 002 "dddddddd-0000-4000-8000-000000000004" @bob
    sfx_msg "$root" "$SFX_T1" 003 "eeeeeeee-0000-4000-8000-000000000005" @alice
    sfx_msg "$root" "$SFX_T2" 001 "$SFX_T2" @alice
    sfx_msg "$root" "$SFX_T3" 001 "$SFX_T3" @carol
    mkdir -p "$st"/{routed,runs,harvested,needs-operator,needs-operator-journal,spawns,retries/"$SFX_T1",held/"$SFX_T1",grants}
    : > "$st/routed/$SFX_T1"
    : > "$st/routed/dddddddd-0000-4000-8000-000000000004"
    printf 'hops exhausted at %s\n' "$SFX_T1" > "$st/needs-operator/$SFX_T1"
    printf '2023-11-14T22:00:00Z\tflag\thops-exhausted\thops exhausted\n2023-11-14T22:05:00Z\tunflag\t\t\n2023-11-14T22:10:00Z\tflag\thops-exhausted\thops exhausted again\n' \
        > "$st/needs-operator-journal/$SFX_T1"
    printf 'flagged before the journal existed\n' > "$st/needs-operator/$SFX_T2"
    printf 'ALLOW_NAMESPACE=ns-a\nREACH_PROBE=svc.ns-a:80\n' > "$st/grants/$SFX_T1.env"
    printf 'one\ntwo\nthree\n' > "$st/spawns/$SFX_T1"
    printf 'AGENT=bob\nTHREAD=%s\nRUN_DIR=/runs/one\nRESUMED=sess-1234abcd\n' "$SFX_T1" > "$st/runs/run-live.env"
    printf 'AGENT=carol\nTHREAD=%s\nRUN_DIR=/runs/two\n' "$SFX_T1" > "$st/runs/run-done.env"
    : > "$st/harvested/run-done"
    printf 'AGENT=dana\nTHREAD=%s\nRUN_DIR=/runs/three\n' "$SFX_T3" > "$st/runs/run-other.env"
    printf 'FAILS=1\nSTATE=pending\nTRIGGER=dddddddd-0000-4000-8000-000000000004\nATTEMPT=1\nNOT_BEFORE=%s\n' \
        "$(( SFX_NOW + 30 ))" > "$st/retries/$SFX_T1/bob"
    printf 'STATE=exhausted\nTRIGGER=eeeeeeee-0000-4000-8000-000000000005\nATTEMPT=3\n' > "$st/retries/$SFX_T1/carol"
    printf 'TRIGGER=eeeeeeee-0000-4000-8000-000000000005\nSINCE=%s\nRETRY=0\n' "$(( SFX_NOW - 12 ))" \
        > "$st/held/$SFX_T1/karl"
}

# Puts a `date` on PATH that answers `+%s` with SFX_NOW and defers to the
# real one for everything else; prints the directory.
sfx_date_stub_dir() {
    local dir real
    dir="$(mktemp -d)"; tmpdirs+=("$dir")
    real="$(command -v date)"
    # shellcheck disable=SC2016  # the stub's own $1/$@ must stay literal
    printf '#!/bin/sh\nif [ "$1" = "+%%s" ]; then echo %s; else exec %s "$@"; fi\n' "$SFX_NOW" "$real" > "$dir/date"
    chmod +x "$dir/date"
    printf '%s' "$dir"
}
# END status-fixture

sfx_root="$(mktemp -d)"; tmpdirs+=("$sfx_root")
sfx_build "$sfx_root"
sfx_stub="$(sfx_date_stub_dir)"
sfx_pm() { FORK_SANDBOX_MAIL_ROOT="$sfx_root" PATH="$sfx_stub:$PATH" "$postmaster" "$@"; }

sfx_pm status > "$work/status-plain.out" 2>&1
if cmp -s "$work/status-plain.out" "$repo_dir/tests/fixtures/postmaster-status-plain.txt"; then
    ok "status: plain output is byte-identical to the golden captured before --json existed"
else
    no "status: plain output is byte-identical to the golden" "$(diff "$repo_dir/tests/fixtures/postmaster-status-plain.txt" "$work/status-plain.out" | head -5)"
fi

sfx_json="$(sfx_pm status --thread "$SFX_T1" --json 2>"$work/sfx.err")"
check "status --json: exits 0 and prints one line" "1" "$(printf '%s\n' "$sfx_json" | wc -l)"
sfx_check="$(python3 - "$sfx_json" "$SFX_T1" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); t = sys.argv[2]
bad = []
def want(label, got, exp):
    if got != exp:
        bad.append(f"{label}: expected {exp!r}, got {got!r}")
want("keys", sorted(d), ["budget", "budget_source", "flag", "grant", "grant_mode", "held", "retries", "review_target", "runs", "spawns", "spawns_total", "thread", "unrouted"])
want("budget", [d["budget"], d["budget_source"], d["spawns_total"]], [96, "global", 0])
want("grant_mode", d["grant_mode"], "file")
want("thread", d["thread"], t)
want("unrouted counts this thread only, keyed on Message-ID", d["unrouted"], 1)
want("flag", d["flag"], {"reason": "hops exhausted at " + t, "events": 2})
want("grant", d["grant"], True)
want("review_target absent for a thread with no target", d["review_target"], None)
want("spawns", d["spawns"], 3)
runs = {r["run_id"]: r for r in d["runs"]}
want("run ids: the other thread's run is excluded", sorted(runs), ["run-done", "run-live"])
want("live run", runs["run-live"], {"run_id": "run-live", "agent": "bob", "state": "live",
                                     "run_dir": "/runs/one", "resumed": "sess-1234abcd"})
want("harvested run", runs["run-done"], {"run_id": "run-done", "agent": "carol", "state": "harvested",
                                          "run_dir": "/runs/two", "resumed": None})
rt = {r["agent"]: r for r in d["retries"]}
want("pending retry", rt["bob"], {"agent": "bob", "state": "pending", "attempt": 1, "due_s": 30})
want("exhausted retry is listed too", rt["carol"], {"agent": "carol", "state": "exhausted", "attempt": 3, "due_s": 0})
want("held (full trigger id)", d["held"], [{"agent": "karl", "trigger": "eeeeeeee-0000-4000-8000-000000000005", "age_s": 12}])
print("\n".join(bad) if bad else "ALL-OK")
PY
)"
check "status --json: every field of a fully populated thread" "ALL-OK" "$sfx_check"

sfx_nojournal="$(sfx_pm status --thread "$SFX_T2" --json)"
check "status --json: a flag without its journal has events null" \
    '{"reason": "flagged before the journal existed", "events": null}' \
    "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["flag"]))' "$sfx_nojournal")"

sfx_empty="$(sfx_pm status --thread "ffffffff-4444-4444-8444-000000000009" --json)"
check "status --json: a thread with no state is all empty or zero" \
    '{"thread": "ffffffff-4444-4444-8444-000000000009", "unrouted": 0, "flag": null, "grant": false, "review_target": null, "spawns": 0, "runs": [], "retries": [], "held": [], "budget": 96, "budget_source": "global", "spawns_total": 0, "grant_mode": "missing"}' \
    "$sfx_empty"

sfx_rc=0; sfx_out="$(sfx_pm status --json 2>&1)" || sfx_rc=$?
check "status --json alone exits 2" "2" "$sfx_rc"
contains "status --json alone says the flags go together" "$sfx_out" "--thread and --json go together"
sfx_rc=0; sfx_out="$(sfx_pm status --thread "$SFX_T1" 2>&1)" || sfx_rc=$?
check "status --thread alone exits 2" "2" "$sfx_rc"
check "status --thread alone is a one-line error" "1" "$(printf '%s\n' "$sfx_out" | wc -l)"
sfx_rc=0; sfx_out="$(sfx_pm status --thread '../x' --json 2>&1)" || sfx_rc=$?
check "status --json with a bad thread-id shape exits 2" "2" "$sfx_rc"
contains "status --json names the bad thread id" "$sfx_out" "not a valid thread id"
sfx_rc=0; sfx_out="$(sfx_pm status --thread 2>&1)" || sfx_rc=$?
check "status --thread with no value exits 2" "2" "$sfx_rc"

finish_suite
