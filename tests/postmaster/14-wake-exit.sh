#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/14-wake-exit.sh — fork-sandbox-postmaster.sh: wake-exit
# evidence and its clearing.
#
# Usage: tests/postmaster/14-wake-exit.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

k8s_wake_fixture  # no wake may reach the real k8s wrapper; see lib.sh

# ============================================================
printf '\n== wake-exit evidence: the log tail of a failed wake, in status --thread --json ==\n'
# ============================================================

# This section owns its k8s seams. The k8s section above unsets
# K8S_DETACH, K8S and CONFIG_DIR once it is done; without inline, a wake is
# detached into whatever tmux server the host runs, whose environment lacks
# this suite's STUB_* variables, so the stub dies and the harvest races it.
# Never start or kill a tmux server here: with $TMUX set, tmux ignores
# TMUX_TMPDIR and would act on the operator's own server.
export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"
new_root FORK_SANDBOX_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
we_log="$work/we-agent.log"

# Produce one surface fixture with the actual client wait path. Its kubectl
# answers describe a failed pod; the wake launcher below carries the client's
# saved snapshot through the wrapper into the postmaster record.
we_client_bin="$work/we-client-bin"
mkdir -p "$we_client_bin"
cat > "$we_client_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" get pod -l job-name="*) echo stub-pod ;;
    *" exec "*) exit 1 ;;
    *" get pod stub-pod -o jsonpath="*) echo Failed ;;
    *" get pod stub-pod -o json "*) cat "$WE_CLIENT_POD_JSON" ;;
    *" logs "*) echo 'secret-like-log-marker' ;;
esac
STUB
chmod +x "$we_client_bin/kubectl"
printf 'K8S_CONTEXT=stub-context\n' > "$FORK_SANDBOX_CONFIG_DIR/k8s.env"
we_client_rd="$work/we-client-run"
mkdir -p "$we_client_rd"
we_client_pod="$work/we-client-pod.json"
python3 - "$we_client_pod" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"status": {"phase": "Failed", "reason": "Evicted",
                          "message": "node low on ephemeral-storage " + "x" * 9000}}, f)
PY
we_client_rc=0
PATH="$we_client_bin:$PATH" WE_CLIENT_POD_JSON="$we_client_pod" \
    "$repo_dir/scripts/fork-sandbox-k8s.sh" wait --branch stub-evicted \
    --timeout 5 --run-dir "$we_client_rd" > "$work/we-client.out" 2> "$work/we-client.err" \
    || we_client_rc=$?
check "client-to-postmaster fixture: failed wait is terminal" 2 "$we_client_rc"
check "client-to-postmaster fixture: client captured Evicted" Evicted \
    "$(jq -r '.pod_reason' "$we_client_rd/terminal-status.json" 2>/dev/null)"

# Kubernetes status is captured by the client before the wrapper writes its
# run-dir pointer. Feed that status through the real wrapper and postmaster.
for we_case in evicted oom deadline plain; do
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    we_case_mid="$(send_msg '@carol' '@karen' "terminal $we_case" 'first' 8)"
    we_case_tid="$(thread_of "$we_case_mid")"
    we_status="$work/status-$we_case.json"
    case "$we_case" in
        evicted)
            cp -- "$we_client_rd/terminal-status.json" "$we_status"
            we_expected='pod Evicted: node low on ephemeral-storage' ;;
        oom)
            printf '%s\n' '{"container_reason":"OOMKilled","container_exit_code":137}' > "$we_status"
            we_expected='container OOMKilled exit 137' ;;
        deadline)
            printf '%s\n' '{"pod_phase":"Failed","pod_reason":"DeadlineExceeded","pod_message":"active deadline reached"}' > "$we_status"
            we_expected='pod DeadlineExceeded: active deadline reached' ;;
        plain)
            we_expected='wake for karen exited 1' ;;
    esac
    if [[ "$we_case" == plain ]]; then
        STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 once
    else
        STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_status" once
    fi
    we_case_json="$(we_json "$we_case_tid")"
    contains "$we_case: failure JSON has the cause" "$we_case_json" "$we_expected"
    case "$we_case" in
        evicted)
            check "evicted: JSON retains the pod reason" Evicted \
                "$(we_py "$we_case_json" 'd["wake_failures"][0]["kubernetes"]["pod_reason"]')"
            contains "evicted: JSON retains the pod message" \
                "$(we_py "$we_case_json" 'd["wake_failures"][0]["kubernetes"]["pod_message"]')" \
                'node low on ephemeral-storage'
            check "evicted: long source message remains inside snapshot limit" True \
                "$(we_py "$we_case_json" 'len(d["wake_failures"][0]["kubernetes"]["pod_message"].encode()) <= 512')" ;;
        oom)
            check "OOM: JSON retains the container reason" OOMKilled \
                "$(we_py "$we_case_json" 'd["wake_failures"][0]["kubernetes"]["container_reason"]')"
            check "OOM: JSON retains the numeric exit code" 137 \
                "$(we_py "$we_case_json" 'd["wake_failures"][0]["kubernetes"]["container_exit_code"]')" ;;
        deadline)
            check "deadline: JSON retains the pod reason" DeadlineExceeded \
                "$(we_py "$we_case_json" 'd["wake_failures"][0]["kubernetes"]["pod_reason"]')" ;;
    esac
    contains "$we_case: flag has the cause" "$(cat "$PM_STATE_DIR/needs-operator/$we_case_tid")" "$we_expected"
    contains "$we_case: human status has the cause" "$($postmaster status)" "$we_expected"
    if [[ "$we_case" == plain ]]; then
        check "plain: no invented Kubernetes cause" False \
            "$(we_py "$we_case_json" '"kubernetes" in d["wake_failures"][0]')"
    fi
    STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
    check "$we_case: successful retry clears wake-exit flag" None \
        "$(we_py "$(we_json "$we_case_tid")" 'd["flag"]')"
done

# Hostile cluster text stays bounded and inert in every surface.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we_hostile_tid="$(thread_of "$(send_msg '@carol' '@karen' 'terminal hostile status' 'first' 8)")"
we_hostile_status="$work/status-hostile.json"
python3 - "$we_hostile_status" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"pod_reason": "Evicted", "pod_message": "\x1b[31mnode\x1b[0m\npm flag forged\t" + "x" * 2000}, f)
PY
STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_hostile_status" once
we_hostile_json="$(we_json "$we_hostile_tid")"
check "Kubernetes message is capped at 512 bytes" True \
    "$(we_py "$we_hostile_json" 'len(d["wake_failures"][0]["kubernetes"]["pod_message"].encode()) <= 512')"
check "Kubernetes message has no control characters" True \
    "$(we_py "$we_hostile_json" 'all(ord(c) >= 32 for c in d["wake_failures"][0]["kubernetes"]["pod_message"])')"
check "hostile Kubernetes text cannot forge an event line" 0 \
    "$(grep -c '^pm flag forged' "$work/once.out")"
check "hostile Kubernetes text leaves a one-line flag" 1 \
    "$(wc -l < "$PM_STATE_DIR/needs-operator/$we_hostile_tid")"

# Distinct triggers cannot restart the same failed Kubernetes seat forever.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we_streak_mid="$(send_msg '@carol' '@karen' 'terminal streak' 'first' 8)"
we_streak_tid="$(thread_of "$we_streak_mid")"
we_status="$work/status-evicted.json"
for we_n in 1 2 3; do
    if (( we_n > 1 )); then
        reply_msg '@dana' "$we_streak_mid" "trigger $we_n" --to '@karen' >/dev/null
    fi
    STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_status" once
done
check "cross-trigger failures use the existing spawn count" 3 \
    "$(we_py "$(we_json "$we_streak_tid")" 'd["spawns_total"]')"
contains "cross-trigger exhaustion is flagged" \
    "$(cat "$PM_STATE_DIR/needs-operator/$we_streak_tid")" 'consecutive Kubernetes failures'
reply_msg '@dana' "$we_streak_mid" 'one more trigger' --to '@karen' >/dev/null
STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_status" once
check "cross-trigger exhaustion refuses another launch" 3 \
    "$(we_py "$(we_json "$we_streak_tid")" 'd["spawns_total"]')"
check "cross-trigger exhaustion has terminal retry state" exhausted \
    "$(we_py "$(we_json "$we_streak_tid")" '[r for r in d["retries"] if r["agent"]=="karen"][0]["state"]')"
reply_msg '@operator' "$we_streak_mid" 'operator reauthorizes the seat' --to '@karen' >/dev/null
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "operator mail resets the Kubernetes streak" 4 \
    "$(we_py "$(we_json "$we_streak_tid")" 'd["spawns_total"]')"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we_same_tid="$(thread_of "$(send_msg '@carol' '@karen' 'same trigger failure' 'first' 8)")"
for we_n in 1 2 3; do
    STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_status" once
done
check "same-trigger Kubernetes failures spend two retries" 3 \
    "$(we_py "$(we_json "$we_same_tid")" 'd["spawns_total"]')"
contains "same-trigger exhaustion keeps the existing flag reason" \
    "$(cat "$PM_STATE_DIR/needs-operator/$we_same_tid")" 'failed after 2 retries'
STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 STUB_K8S_TERMINAL_JSON="$we_status" once
check "same-trigger exhaustion does not launch again" 3 \
    "$(we_py "$(we_json "$we_same_tid")" 'd["spawns_total"]')"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we_zero_tid="$(thread_of "$(send_msg '@carol' '@karen' 'no retry budget' 'first' 8)")"
FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF='' STUB_K8S_EXIT=2 STUB_K8S_NO_REPLY=1 \
    STUB_K8S_TERMINAL_JSON="$we_status" once
check "empty retry list exhausts on the initial failure" 1 \
    "$(we_py "$(we_json "$we_zero_tid")" 'd["spawns_total"]')"
contains "empty retry list keeps the existing per-trigger flag" \
    "$(cat "$PM_STATE_DIR/needs-operator/$we_zero_tid")" 'failed after 0 retries'

# --- a k8s seat fails twice: both attempts stay, each with its own tail ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we1_mid="$(send_msg '@carol' '@karen' 'wake exit evidence' 'first' 8)"
we1_tid="$(thread_of "$we1_mid")"
seq 1 60 | sed 's/^/first attempt line /' > "$we_log"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
we1_rid1="$(basename "$(latest_env_for_agent karen)" .env)"
we1_json="$(we_json "$we1_tid")"
check "wake-exit event: the flag line names the run whose log to look up" \
    "pm flag thread=${we1_tid:0:8} reason=wake-exit log=$we1_rid1" \
    "$(grep '^pm flag ' "$work/once.out")"
check "wake-exit event: still exactly one flag line, one line per event" 1 \
    "$(grep -c '^pm flag ' "$work/once.out")"
check "wake-exit event: every stdout line is a pm event" 0 \
    "$(grep -vc '^pm ' "$work/once.out")"
check "wake-exit: one failure record after the first failed wake" 1 "$(we_py "$we1_json" 'len(d["wake_failures"])')"
check "wake-exit: the record names the agent" karen "$(we_py "$we1_json" 'd["wake_failures"][0]["agent"]')"
check "wake-exit: the record names the run id" "$we1_rid1" "$(we_py "$we1_json" 'd["wake_failures"][0]["run_id"]')"
check "wake-exit: the record carries the exit code" 1 "$(we_py "$we1_json" 'd["wake_failures"][0]["exit_code"]')"
check "wake-exit: the log was captured" captured "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["state"]')"
check "wake-exit: the log source is the agent container's" pod-log-agent.log \
    "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["source"]')"
check "wake-exit: the tail is the last 40 lines" 40 "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["lines"]')"
check "wake-exit: the tail ends at the log's last line" "first attempt line 60" \
    "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[-1]')"
check "wake-exit: the tail starts 40 lines back" "first attempt line 21" \
    "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[0]')"
check "wake-exit: a cut tail says so" True "$(we_py "$we1_json" 'd["wake_failures"][0]["log"]["truncated"]')"
check "wake-exit: not cleared" None "$(we_py "$we1_json" 'd["wake_failures"][0]["cleared"]')"
contains "wake-exit: the thread is still flagged as before" \
    "$(we_py "$we1_json" 'd["flag"]["reason"]')" "wake for karen exited 1 (run $we1_rid1)"

seq 1 5 | sed 's/^/second attempt line /' > "$we_log"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
we1_json="$(we_json "$we1_tid")"
check "wake-exit: the retry's failure is a second record" 2 "$(we_py "$we1_json" 'len(d["wake_failures"])')"
check "wake-exit: the two attempts have distinct run ids" 2 "$(we_py "$we1_json" 'len({r["run_id"] for r in d["wake_failures"]})')"
check "wake-exit: the first attempt's tail survived the retry" "first attempt line 60" \
    "$(we_py "$we1_json" '[r for r in d["wake_failures"] if r["run_id"]=="'"$we1_rid1"'"][0]["log"]["tail"].split("\n")[-1]')"
check "wake-exit: the retry's own tail is its own" "second attempt line 5" \
    "$(we_py "$we1_json" '[r for r in d["wake_failures"] if r["run_id"]!="'"$we1_rid1"'"][0]["log"]["tail"].split("\n")[-1]')"
check "wake-exit: the short tail is not marked cut" False \
    "$(we_py "$we1_json" '[r for r in d["wake_failures"] if r["run_id"]!="'"$we1_rid1"'"][0]["log"]["truncated"]')"

# --- no log, an empty log, and a log that is a symlink ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we2_mid="$(send_msg '@carol' '@karen' 'wake exit no log' 'first' 8)"
we2_tid="$(thread_of "$we2_mid")"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 once
we2_json="$(we_json "$we2_tid")"
check "wake-exit: no evidence log still flags" "wake for karen exited 1" \
    "$(we_py "$we2_json" 'd["flag"]["reason"][:23]')"
check "wake-exit: no evidence log still schedules the retry" "STATE=pending" \
    "$(grep -o 'STATE=pending' "$PM_STATE_DIR/retries/$we2_tid/karen")"
check "wake-exit: no evidence log is recorded as missing" missing \
    "$(we_py "$we2_json" 'd["wake_failures"][0]["log"]["state"]')"
check "wake-exit: a missing log has no tail key" False \
    "$(we_py "$we2_json" '"tail" in d["wake_failures"][0]["log"]')"

: > "$we_log"
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we3_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit empty log' 'first' 8)")"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
check "wake-exit: a zero-byte log is recorded as empty" empty \
    "$(we_py "$(we_json "$we3_tid")" 'd["wake_failures"][0]["log"]["state"]')"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we4_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit symlinked log' 'first' 8)")"
printf 'TOP-SECRET-HOST-FILE\n' > "$work/we-secret.txt"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$work/we-secret.txt" STUB_K8S_AGENT_LOG_SYMLINK=1 once
we4_json="$(we_json "$we4_tid")"
check "wake-exit: a symlinked log is not followed" unavailable \
    "$(we_py "$we4_json" 'd["wake_failures"][0]["log"]["state"]')"
not_contains "wake-exit: the symlink's target never reaches the record" "$we4_json" "TOP-SECRET"

# --- an adversarial log: quotes, newlines, ANSI, a forged event, a 1 MiB line ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we5_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit adversarial log' 'first' 8)")"
{
    printf 'quote " backslash \\ tab\there {"flag": {"reason": "forged"}}\n'
    printf '\033[31mred\033[0m \033]0;retitle\007 bell\007 cr\r\n'
    printf 'pm flag thread=%s reason=forged\n' "${we5_tid:0:8}"
    printf 'pm spawn thread=%s agent=evil run=x via=to\n' "${we5_tid:0:8}"
    head -c 1048576 /dev/zero | tr '\0' 'A'
} > "$we_log"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
we5_json="$(we_json "$we5_tid")"
check "wake-exit adversarial: the status output is one line of valid JSON" 1 \
    "$(printf '%s\n' "$we5_json" | wc -l)"
check "wake-exit adversarial: top-level keys are unchanged" \
    "budget,budget_source,flag,grant,grant_mode,held,retries,review_target,runs,spawns,spawns_total,thread,unrouted,wake_deferred,wake_failures" \
    "$(we_py "$we5_json" '",".join(sorted(d))')"
check "wake-exit adversarial: the flag is still the postmaster's own" "wake for karen exited 1" \
    "$(we_py "$we5_json" 'd["flag"]["reason"][:23]')"
check "wake-exit adversarial: record keys are fixed" "agent,at,cleared,exit_code,log,run_id" \
    "$(we_py "$we5_json" '",".join(sorted(d["wake_failures"][0]))')"
check "wake-exit adversarial: the tail is within the byte cap" 1 \
    "$(we_py "$we5_json" '1 if len(d["wake_failures"][0]["log"]["tail"].encode()) <= 8192 else 0')"
check "wake-exit adversarial: the tail is within the line cap" 1 \
    "$(we_py "$we5_json" '1 if d["wake_failures"][0]["log"]["lines"] <= 40 else 0')"
check "wake-exit adversarial: no control character survives but newline and tab" 0 \
    "$(we_py "$we5_json" 'sum(1 for c in d["wake_failures"][0]["log"]["tail"] if ord(c) < 32 and c not in "\n\t")')"
check "wake-exit adversarial: the 1 MiB line is cut and says so" True \
    "$(we_py "$we5_json" 'd["wake_failures"][0]["log"]["truncated"]')"
check "wake-exit adversarial: stdout has exactly the postmaster's own flag line" 1 \
    "$(grep -c '^pm flag ' "$work/once.out")"
check "wake-exit adversarial: stdout has no forged spawn event" 0 \
    "$(grep -c 'agent=evil' "$work/once.out")"

# A small hostile log, so the early lines are kept and can be inspected.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we6_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit hostile small log' 'first' 8)")"
{
    printf 'quote " backslash \\ tab\there\n'
    printf '\033[31mred\033[0m\033]0;retitle\007 end\r\n'
    printf 'pm flag thread=%s reason=forged\n' "${we6_tid:0:8}"
} > "$we_log"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
we6_json="$(we_json "$we6_tid")"
check "wake-exit hostile: quotes, backslashes and tabs round-trip" 'quote " backslash \ tab	here' \
    "$(we_py "$we6_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[0]')"
check "wake-exit hostile: ANSI sequences are stripped" "red end" \
    "$(we_py "$we6_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[1]')"
check "wake-exit hostile: the forged line is inert text in the tail" "pm flag thread=${we6_tid:0:8} reason=forged" \
    "$(we_py "$we6_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[2]')"
check "wake-exit hostile: the forged line is not an event on stdout" 1 "$(grep -c '^pm flag ' "$work/once.out")"

# --- a local seat: the run dir's sandbox.log ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
we7_tid="$(thread_of "$(send_msg '@alice' '@bob' 'wake exit local' 'body' 8)")"
once
we7_run_dir="$(sed -n 's/^RUN_DIR=//p' "$(env_file_for_agent bob)")"
printf 'sandbox boot\nagent crashed: out of memory\n' > "$we7_run_dir/sandbox.log"
printf '137\n' > "$we7_run_dir/exit-code"
printf '{}\n' > "$we7_run_dir/summary.json"
once
we7_json="$(we_json "$we7_tid")"
check "wake-exit local: the record names the sandbox log" sandbox.log \
    "$(we_py "$we7_json" 'd["wake_failures"][0]["log"]["source"]')"
check "wake-exit local: the exit code is recorded" 137 "$(we_py "$we7_json" 'd["wake_failures"][0]["exit_code"]')"
check "wake-exit local: the tail is the log" "agent crashed: out of memory" \
    "$(we_py "$we7_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[-1]')"

# --- failing to write the record is not an error path ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we9_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit unwritable' 'first' 8)")"
mkdir -p "$PM_STATE_DIR"
: > "$PM_STATE_DIR/wake-exits"   # a file where the directory must go
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
check "wake-exit unwritable: the flag event is the old one, without log=" \
    "pm flag thread=${we9_tid:0:8} reason=wake-exit" "$(grep '^pm flag ' "$work/once.out")"
contains "wake-exit unwritable: the thread is still flagged" \
    "$(cat "$PM_STATE_DIR/needs-operator/$we9_tid" 2>/dev/null)" "wake for karen exited 1"
contains "wake-exit unwritable: the retry is still scheduled" \
    "$(cat "$PM_STATE_DIR/retries/$we9_tid/karen" 2>/dev/null)" "STATE=pending"
check "wake-exit unwritable: the run is still harvested" 1 \
    "$(find "$PM_STATE_DIR/harvested" -type f | wc -l)"
check "wake-exit unwritable: status has no wake_failures key" False \
    "$(we_py "$(we_json "$we9_tid")" '"wake_failures" in d')"

# --- a clean wake leaves the status output without the new key ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
we8_tid="$(thread_of "$(send_msg '@carol' '@karen' 'wake exit clean' 'first' 8)")"
once
check "wake-exit: a clean wake adds no wake_failures key" "budget,budget_source,flag,grant,grant_mode,held,retries,review_target,runs,spawns,spawns_total,thread,unrouted,wake_deferred" \
    "$(we_py "$(we_json "$we8_tid")" '",".join(sorted(d))')"
check "wake-exit: a clean wake writes no wake-exits state" 0 \
    "$([[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/wake-exits" ]] && echo 1 || echo 0)"

# ============================================================
printf '\n== wake-exit clear: a successful retry clears its own wake-exit flag ==\n'
# ============================================================

# we_seed <thread> <agent> <run-id>: a failed attempt's record, as the
# postmaster's own recorder would have left it.
we_seed() {
    local tid="$1" agent="$2" run="$3" dir="$FORK_SANDBOX_MAIL_ROOT/.postmaster/wake-exits/$1/$2"
    mkdir -p -- "$dir"
    printf '{"run_id": "%s", "agent": "%s", "exit_code": 1, "at": "2026-01-01T00:00:00Z", "log": {"state": "captured", "source": "pod-log-agent.log", "lines": 1, "truncated": false, "tail": "boom %s"}}\n' \
        "$run" "$agent" "$run" > "$dir/$run.json"
}
# we_jline <thread> <kind> <keyword> <reason>
we_jline() {
    local jd="$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator-journal"
    mkdir -p -- "$jd"
    printf '2026-01-01T00:00:00Z\t%s\t%s\t%s\n' "$2" "$3" "$4" >> "$jd/$1"
}
# we_other_run <agent> <run-id>: the id of a run of <agent> that is not
# <run-id>. For a thread with exactly two runs of a seat this names the
# second without latest_env_for_agent's mtime ordering, whose one-second
# resolution ties when both wakes land in the same second (and then orders
# by the random run id).
we_other_run() {
    local f rid
    for f in "$PM_STATE_DIR/runs"/*.env; do
        [[ -e "$f" ]] || continue
        grep -q "^AGENT=$1\$" "$f" || continue
        rid="$(basename -- "$f" .env)"
        [[ "$rid" == "$2" ]] || { printf '%s' "$rid"; return 0; }
    done
    return 1
}
we_exit_reason() { printf 'wake for %s exited 1 (run %s); outbox may be incomplete' "$1" "$2"; }
we_cur() { cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$1" 2>/dev/null || true; }
we_set_cur() { mkdir -p "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator"; printf '%s\n' "$2" > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$1"; }
# we_fresh <subject>: a fresh root and a thread with one unrouted message to karen.
we_fresh() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    we_mid="$(send_msg '@carol' '@karen' "$1" 'first' 8)"
    we_tid="$(thread_of "$we_mid")"
}

# --- seat A fails, A's retry exits 0 (the whole path, nothing seeded) ---
we_fresh 'clear: natural retry'
seq 1 3 | sed 's/^/boom line /' > "$we_log"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
c1_rid1="$(basename "$(latest_env_for_agent karen)" .env)"
check "clear: the failed wake flagged the thread" "1" "$([[ -e "$PM_STATE_DIR/needs-operator/$we_tid" ]] && echo 1 || echo 0)"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
c1_rid2="$(we_other_run karen "$c1_rid1")"
[[ "$c1_rid1" != "$c1_rid2" ]] || no "clear fixture: the retry ran as a second run" "$c1_rid1"
c1_json="$(we_json "$we_tid")"
check "clear: the thread is no longer flagged" None "$(we_py "$c1_json" 'd["flag"]')"
check "clear: a clear event was emitted, one line, naming both runs" \
    "pm flag-clear thread=${we_tid:0:8} agent=karen reason=wake-exit run=$c1_rid1 by=$c1_rid2 flagged=no" \
    "$(grep '^pm flag-clear ' "$work/once.out")"
check "clear: the failure is still in the record" "$c1_rid1" "$(we_py "$c1_json" 'd["wake_failures"][0]["run_id"]')"
check "clear: the log tail is still in the record" "boom line 3" \
    "$(we_py "$c1_json" 'd["wake_failures"][0]["log"]["tail"].split("\n")[-1]')"
check "clear: the record says which run cleared it" "$c1_rid2" "$(we_py "$c1_json" 'd["wake_failures"][0]["cleared"]["by"]')"
check "clear: the journal still has the original failure" 1 \
    "$(grep -c "	flag	wake-exit	wake for karen exited 1 (run $c1_rid1)" "$PM_STATE_DIR/needs-operator-journal/$we_tid")"
check "clear: the journal records the clear and the run that did it" 1 \
    "$(grep -c "	clear	wake-exit	wake for karen exited 1 (run $c1_rid1).* cleared by run $c1_rid2\$" "$PM_STATE_DIR/needs-operator-journal/$we_tid")"
reply_msg '@carol' "$we_mid" 'once more' --to '@karen' >/dev/null
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear: a later clean wake emits no further clear event" 0 "$(grep -c '^pm flag-clear ' "$work/once.out")"

# --- A and B both failed; only A recovers: the thread stays flagged for B ---
we_fresh 'clear: two seats, A recovers'
we_seed "$we_tid" karen ra1; we_seed "$we_tid" kara rb1
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"
we_jline "$we_tid" flag wake-exit "$(we_exit_reason kara rb1)"
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"   # the file's own: A failed last
we_set_cur "$we_tid" "$(we_exit_reason karen ra1)"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear 2seat: still flagged, now for B" "$(we_exit_reason kara rb1)" "$(we_cur "$we_tid")"
check "clear 2seat: the event says the thread is still flagged" 1 \
    "$(grep -c "^pm flag-clear thread=${we_tid:0:8} agent=karen reason=wake-exit run=ra1 by=.* flagged=yes\$" "$work/once.out")"
c2_json="$(we_json "$we_tid")"
check "clear 2seat: B's record is still open" None \
    "$(we_py "$c2_json" '[r for r in d["wake_failures"] if r["agent"]=="kara"][0]["cleared"]')"
check "clear 2seat: A's record is cleared" True \
    "$(we_py "$c2_json" '[r for r in d["wake_failures"] if r["agent"]=="karen"][0]["cleared"] is not None')"

we_fresh 'clear: two seats, B failed last'
we_seed "$we_tid" karen ra1; we_seed "$we_tid" kara rb1
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"
we_jline "$we_tid" flag wake-exit "$(we_exit_reason kara rb1)"
we_set_cur "$we_tid" "$(we_exit_reason kara rb1)"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear 2seat: B's reason, already in the file, is untouched" "$(we_exit_reason kara rb1)" "$(we_cur "$we_tid")"

# --- a wake-exit plus an unrelated reason: only the unrelated one remains ---
we_fresh 'clear: unrelated reason that A overwrote'
we_seed "$we_tid" karen ra1
we_jline "$we_tid" flag budget-exhausted "thread budget 96 exhausted"
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"
we_set_cur "$we_tid" "$(we_exit_reason karen ra1)"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear unrelated-first: the older unrelated reason is back in the file" "thread budget 96 exhausted" "$(we_cur "$we_tid")"
check "clear unrelated-first: the flag event count is unchanged" 2 \
    "$(we_py "$(we_json "$we_tid")" 'd["flag"]["events"]')"

we_fresh 'clear: unrelated reason that overwrote A'
we_seed "$we_tid" karen ra1
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"
we_jline "$we_tid" flag budget-exhausted "thread budget 96 exhausted"
we_set_cur "$we_tid" "thread budget 96 exhausted"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear unrelated-last: the unrelated reason stays" "thread budget 96 exhausted" "$(we_cur "$we_tid")"
check "clear unrelated-last: A's failure is cleared anyway" True \
    "$(we_py "$(we_json "$we_tid")" 'd["wake_failures"][0]["cleared"] is not None')"

# --- retries exhausted: a success is not a wake-exit and never clears it ---
we_fresh 'clear: retry exhaustion'
we_seed "$we_tid" karen ra1
we_jline "$we_tid" flag wake-exit "$(we_exit_reason karen ra1)"
we_jline "$we_tid" flag retry-exhausted "wake for karen failed after 3 retries (trigger abcd1234)"
we_set_cur "$we_tid" "wake for karen failed after 3 retries (trigger abcd1234)"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear exhausted: the thread stays flagged for the exhausted retries" \
    "wake for karen failed after 3 retries (trigger abcd1234)" "$(we_cur "$we_tid")"

# --- an operator's unflag closes open records, and a later success is silent ---
we_fresh 'clear: operator unflag'
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
"$postmaster" unflag "$we_tid" >/dev/null 2>&1
c6_json="$(we_json "$we_tid")"
check "clear operator: the record is marked cleared by the operator" operator \
    "$(we_py "$c6_json" 'd["wake_failures"][0]["cleared"]["by"]')"
check "clear operator: the record keeps its tail" captured "$(we_py "$c6_json" 'd["wake_failures"][0]["log"]["state"]')"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear operator: a later clean wake emits no clear event" 0 "$(grep -c '^pm flag-clear ' "$work/once.out")"
check "clear operator: and the thread stays unflagged" None "$(we_py "$(we_json "$we_tid")" 'd["flag"]')"

# --- two real seats fail on one thread; only one recovers ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
we_tid="$(thread_of "$(send_msg '@carol' '@karen,@kara' 'clear: two real seats' 'first' 8)")"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
check "clear real: both seats' failures are recorded" 2 "$(we_py "$(we_json "$we_tid")" 'len(d["wake_failures"])')"
STUB_K8S_EXIT_MAP="karen=0 kara=1" STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_AGENT_LOG="$we_log" once
c7_json="$(we_json "$we_tid")"
contains "clear real: still flagged, and for the seat that did not recover" \
    "$(we_py "$c7_json" 'd["flag"]["reason"]')" "wake for kara exited 1"
check "clear real: the recovered seat's earlier failure is cleared" True \
    "$(we_py "$c7_json" 'all(r["cleared"] is not None for r in d["wake_failures"] if r["agent"]=="karen")')"
check "clear real: the other seat has an open failure" True \
    "$(we_py "$c7_json" 'any(r["cleared"] is None for r in d["wake_failures"] if r["agent"]=="kara")')"

# --- a clean wake on a never-failed thread touches nothing ---
we_fresh 'clear: never failed'
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "clear: a thread that never failed has no clear event" 0 "$(grep -c '^pm flag-clear ' "$work/once.out")"
check "clear: and no journal" 0 "$([[ -e "$PM_STATE_DIR/needs-operator-journal/$we_tid" ]] && echo 1 || echo 0)"

# ============================================================
printf '\n== wake-exit output: a k8s wake that dies fast says why in its flag ==\n'
# ============================================================

# wo_flag <tid>: the thread's current flag reason.
wo_flag() { cat "$PM_STATE_DIR/needs-operator/$1" 2>/dev/null || true; }
wo_out="$work/wo-stderr.txt"

we_fresh 'output: quota'
printf 'fork-sandbox: submitting the Job\nError: model quota exhausted for this account\n' > "$wo_out"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_STDERR="$wo_out" once
wo_rid="$(basename "$(latest_env_for_agent karen)" .env)"
wo_reason="$(wo_flag "$we_tid")"
check "output: no agent log for the fast failure" missing \
    "$(we_py "$(we_json "$we_tid")" 'd["wake_failures"][0]["log"]["state"]')"
contains "output: the flag reason carries the wake's last output" "$wo_reason" \
    "; output: "
contains "output: including the error that says why" "$wo_reason" \
    "fork-sandbox: submitting the Job | Error: model quota exhausted for this account"
check "output: the reason still starts as a wake-exit reason does" \
    "wake for karen exited 1 (run $wo_rid); outbox may be incomplete; output: " \
    "${wo_reason%%; output: *}; output: "
check "output: the keyword is unchanged" "pm flag thread=${we_tid:0:8} reason=wake-exit log=$wo_rid" \
    "$(grep '^pm flag ' "$work/once.out")"
check "output: the reason is one line" 1 "$(wc -l < "$PM_STATE_DIR/needs-operator/$we_tid")"
STUB_K8S_EXIT=0 STUB_K8S_NO_REPLY=1 once
check "output: a clean retry still clears the flag" "" "$(wo_flag "$we_tid")"
contains "output: with the ordinary clear event" "$(cat "$work/once.out")" \
    "pm flag-clear thread=${we_tid:0:8} agent=karen reason=wake-exit run=$wo_rid"

# Capped: the last 3 lines at most, then 300 bytes, on one line, control
# characters gone.
we_fresh 'output: capped'
{
    seq 1 50 | sed 's/^/noise line /'
    printf 'tab\there \033[31mred\033[0m bell\007 cr\r\n'
    head -c 2000 /dev/zero | tr '\0' 'x'; printf '\n'
    printf 'Error: the very last line\n'
} > "$wo_out"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_STDERR="$wo_out" once
wo_tail="$(wo_flag "$we_tid")"; wo_tail="${wo_tail#*; output: }"
check "output: the tail is capped at 300 bytes" 1 "$(( $(printf '%s' "$wo_tail" | wc -c) <= 300 ))"
contains "output: and keeps the end" "$wo_tail" "Error: the very last line"
not_contains "output: older lines are cut" "$wo_tail" "noise line"
check "output: no control character survives" 0 \
    "$(printf '%s' "$wo_tail" | LC_ALL=C grep -c '[[:cntrl:]]' || true)"
check "output: the flag file is one line" 1 "$(wc -l < "$PM_STATE_DIR/needs-operator/$we_tid")"
check "output: the journal line is one tab-separated record" 4 \
    "$(awk -F'\t' '$2=="flag"{print NF}' "$PM_STATE_DIR/needs-operator-journal/$we_tid" | tail -n1)"

# A token-shaped string in the output never reaches the flag.
we_fresh 'output: secrets'
printf 'Error: credential refresh failed: sk-ant-oat01-Zq9x8Wv7Ut6Sr5Qp4On3Ml2Kj1\nAuthorization: Bearer abcdef0123456789secret token=hunter2hunter2 "accessToken":"q1w2e3r4t5"\njwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZ2VudCJ9.c2lnbmF0dXJl ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 Zm9yay1zYW5kYm94LXNlY3JldC0xMjM0NTY3ODkw\n' > "$wo_out"
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_STDERR="$wo_out" once
wo_all="$(wo_flag "$we_tid") $(cat "$PM_STATE_DIR/needs-operator-journal/$we_tid") $(we_json "$we_tid")"
for wo_secret in Zq9x8Wv7Ut6Sr5Qp4On3Ml2Kj1 abcdef0123456789secret hunter2hunter2 q1w2e3r4t5 \
        eyJzdWIiOiJhZ2VudCJ9 ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 Zm9yay1zYW5kYm94LXNlY3JldC0xMjM0NTY3ODkw; do
    not_contains "output: a secret-shaped ${wo_secret:0:6}... never reaches the flag" "$wo_all" "$wo_secret"
done
contains "output: what was redacted says so" "$(wo_flag "$we_tid")" "[redacted]"
contains "output: the error text around it survives" "$(wo_flag "$we_tid")" "Error: credential refresh failed:"

# No output at all: the reason is exactly what it always was.
we_fresh 'output: none'
STUB_K8S_EXIT=1 STUB_K8S_NO_REPLY=1 STUB_K8S_NO_RUNDIR=1 once
wo_rid="$(basename "$(latest_env_for_agent karen)" .env)"
check "output: a wake that printed nothing keeps the old reason" \
    "wake for karen exited 1 (run $wo_rid); outbox may be incomplete" "$(wo_flag "$we_tid")"

# Leave nothing exported for the sections after these two.
unset FORK_SANDBOX_POSTMASTER_K8S_DETACH FORK_SANDBOX_POSTMASTER_K8S \
    FORK_SANDBOX_CONFIG_DIR FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

finish_suite
