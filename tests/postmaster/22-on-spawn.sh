#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/22-on-spawn.sh — fork-sandbox-postmaster.sh: the on-spawn
# hook event, fired once per run record written.
#
# Usage: tests/postmaster/22-on-spawn.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

k8s_wake_fixture  # no wake may reach the real k8s wrapper; see lib.sh

export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0

# ============================================================
printf '\n== on-spawn: no hook file, no fire and no error ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
new_root HK_DIR
# shellcheck disable=SC2031  # lib.sh sets it only inside hk_call's subshell
export FORK_SANDBOX_HOOKS_DIR="$HK_DIR" FORK_SANDBOX_POSTMASTER_HOOK_DETACH=inline

os_mid="$(send_msg '@carol' '@alice' 'no hook topic' 'first' 8)"
check "no hook: deliver exits 0" 0 "$(once_rc)"
check "no hook: the wake still spawns" 1 "$([[ -n "$(live_env_for_agent alice)" ]] && echo 1 || echo 0)"
check "no hook: no hook event line" 0 "$(grep -c 'hook=on-spawn' "$work/once.out")"
check "no hook: no hook record" "no" "$([[ -e "$PM_STATE_DIR/hooks" ]] && echo yes || echo no)"
check "no hook: stderr is empty" "" "$(cat "$work/once.err")"

# ============================================================
printf '\n== on-spawn: a new message wakes a To: seat and a Cc: seat ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
new_root HK_OUT
export HK_OUT HK_PM="$postmaster"
# One env file per fire, keyed by run id, plus whether `status --json`
# already listed the run when the hook ran.
cat > "$HK_DIR/on-spawn" <<'HOOK'
#!/usr/bin/env bash
env | grep '^FS_' | sort > "$HK_OUT/$FS_HOOK_RUN.env"
"$HK_PM" status --thread "$FS_HOOK_THREAD" --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("visible" if any(r["run_id"] == sys.argv[1] for r in d["runs"]) else "missing")
' "$FS_HOOK_RUN" > "$HK_OUT/$FS_HOOK_RUN.status"
echo "$FS_HOOK_RUN" >> "$HK_OUT/fires"
HOOK
chmod +x "$HK_DIR/on-spawn"

os_fires() { [[ -f "$HK_OUT/fires" ]] && wc -l < "$HK_OUT/fires" || echo 0; }
os_env() { sed -n "s/^$2=//p" "$HK_OUT/$1.env" 2>/dev/null; }

os_mid="$(send_msg '@dana' '@alice' 'on-spawn topic' 'first' 8 '@carol')"
os_tid="$(thread_of "$os_mid")"
once
os_alice_env="$(live_env_for_agent alice)"
os_carol_env="$(live_env_for_agent carol)"
os_alice="$(basename -- "$os_alice_env" .env)"
os_carol="$(basename -- "$os_carol_env" .env)"
check "new message: one fire per spawn" 2 "$(os_fires)"
check "new message: one fire for alice's run" 1 "$(grep -cx -- "$os_alice" "$HK_OUT/fires")"
check "new message: one fire for carol's run" 1 "$(grep -cx -- "$os_carol" "$HK_OUT/fires")"
check "new message: FS_HOOK_EVENT" "on-spawn" "$(os_env "$os_alice" FS_HOOK_EVENT)"
check "new message: FS_HOOK_THREAD is the full thread id" "$os_tid" "$(os_env "$os_alice" FS_HOOK_THREAD)"
check "new message: FS_HOOK_RUN is the run id" "$os_alice" "$(os_env "$os_alice" FS_HOOK_RUN)"
check "new message: FS_HOOK_AGENT is the seat" "alice carol" \
    "$(os_env "$os_alice" FS_HOOK_AGENT) $(os_env "$os_carol" FS_HOOK_AGENT)"
check "new message: FS_HOOK_MESSAGE is the trigger" "$os_mid $os_mid" \
    "$(os_env "$os_alice" FS_HOOK_MESSAGE) $(os_env "$os_carol" FS_HOOK_MESSAGE)"
check "new message: FS_HOOK_VIA is to for the To: seat, cc for the Cc: seat" "to cc" \
    "$(os_env "$os_alice" FS_HOOK_VIA) $(os_env "$os_carol" FS_HOOK_VIA)"
check "new message: FS_HOOK_VIA matches the record's VIA" \
    "$(env_val "$os_alice_env" VIA) $(env_val "$os_carol_env" VIA)" \
    "$(os_env "$os_alice" FS_HOOK_VIA) $(os_env "$os_carol" FS_HOOK_VIA)"
check "new message: FS_HOOK_RETRY_OF is set and empty" "1:" \
    "$(grep -c '^FS_HOOK_RETRY_OF=$' "$HK_OUT/$os_alice.env"):$(os_env "$os_alice" FS_HOOK_RETRY_OF)"
check "new message: the standard hook set is there too" "$PROJECT_DIR" "$(os_env "$os_alice" FS_HOOK_REPO)"
check "new message: the run is in status --json when the hook runs" "visible visible" \
    "$(cat "$HK_OUT/$os_alice.status") $(cat "$HK_OUT/$os_carol.status")"
contains "new message: the event line carries the hook file" "$(cat "$work/once.out")" \
    "pm hook thread=${os_tid:0:8} hook=on-spawn file=on-spawn exit=0"

# ============================================================
printf '\n== on-spawn: a retry fires it again, with FS_HOOK_RETRY_OF ==\n'
# ============================================================

finish_run alice 1
once
check "retry: the harvest pass spawns nothing and fires nothing" 2 "$(os_fires)"
once
os_retry_env="$(live_env_for_agent alice)"
os_retry="$(basename -- "$os_retry_env" .env)"
check "retry: a retry wake spawned" 1 "$([[ -n "$os_retry" && "$os_retry" != "$os_alice" ]] && echo 1 || echo 0)"
check "retry: one more fire" 3 "$(os_fires)"
check "retry: for the retry run" "$os_retry" "$(tail -n1 "$HK_OUT/fires")"
check "retry: FS_HOOK_RETRY_OF is the retried run, as the record's RETRY_OF" \
    "$os_alice $os_alice" "$(os_env "$os_retry" FS_HOOK_RETRY_OF) $(env_val "$os_retry_env" RETRY_OF)"
check "retry: FS_HOOK_AGENT, FS_HOOK_MESSAGE, FS_HOOK_VIA" "alice $os_mid to" \
    "$(os_env "$os_retry" FS_HOOK_AGENT) $(os_env "$os_retry" FS_HOOK_MESSAGE) $(os_env "$os_retry" FS_HOOK_VIA)"
check "retry: the retry run is in status --json when the hook runs" "visible" "$(cat "$HK_OUT/$os_retry.status")"

finish_suite
