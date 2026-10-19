#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/16-k8s-retention.sh — fork-sandbox-postmaster.sh: a
# harvested k8s wake's leftover cluster objects are removed after the
# retention window, and nothing else is.
#
# Usage: tests/postmaster/16-k8s-retention.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

k8s_wake_fixture
export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"
new_root FORK_SANDBOX_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR
# Most cases want every pass to sweep; the throttle case sets its own.
export FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY=0

day=86400

# A fresh mail root and empty stub logs, so each case sees only its own runs.
kr_reset() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    KR_STATE="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    mkdir -p "$KR_STATE/runs" "$KR_STATE/harvested"
    rm -f "$K8S_WAKE_BIN"/{rm-calls,probe-calls}.log "$K8S_WAKE_BIN"/{probe-rc,rm-rc}
}

# kr_run <rid> <branch> <seconds since harvest> [backend]; omit the age to
# leave the run unharvested.
kr_run() {
    local rid="$1" branch="$2" age="${3-}" backend="${4:-k8s}"
    printf 'AGENT=tests\nTHREAD=0123abcd-0000-0000-0000-000000000000\nBACKEND=%s\nBRANCH=%s\nRUN_DIR=%s\n' \
        "$backend" "$branch" "$work/kr-$rid" > "$KR_STATE/runs/$rid.env"
    [[ -n "$age" ]] || return 0
    : > "$KR_STATE/harvested/$rid"
    touch -d "@$(( $(date +%s) - age ))" "$KR_STATE/harvested/$rid"
}

kr_rm_calls() { cat "$K8S_WAKE_BIN/rm-calls.log" 2>/dev/null; }
kr_probe_count() { [[ -f "$K8S_WAKE_BIN/probe-calls.log" ]] && wc -l < "$K8S_WAKE_BIN/probe-calls.log" || echo 0; }

# ============================================================
printf '\n== k8s retention: which runs are reaped ==\n'
# ============================================================

kr_reset
kr_run r-old sbx-mail-0123abcd-tests-6 $(( 4 * day ))
kr_run r-new sbx-mail-0123abcd-tests-7 $(( 1 * day ))
kr_run r-unharvested sbx-mail-0123abcd-tests-8
kr_run r-local sbx-mail-0123abcd-tests-9 $(( 4 * day )) local
kr_run r-forged fork-sandbox-agent-live $(( 4 * day ))
once
check "retention: only the old harvested k8s run is removed, by its branch" \
    "rm --branch sbx-mail-0123abcd-tests-6" "$(kr_rm_calls)"
check "retention: the reap is recorded" yes "$([[ -e "$KR_STATE/k8s-reaped/r-old" ]] && echo yes || echo no)"
contains "retention: the reap emits a k8s-reaped event" \
    "$(cat "$work/once.out")" "pm k8s-reaped run=r-old branch=sbx-mail-0123abcd-tests-6"
check "retention: a branch the postmaster never mints is never probed or removed" \
    1 "$(kr_probe_count)"
check "retention: ...and is not looked at again" yes \
    "$([[ -e "$KR_STATE/k8s-reaped/r-forged" ]] && echo yes || echo no)"
once
check "retention: a reaped run is not removed twice" 1 "$(kr_rm_calls | wc -l)"

# ============================================================
printf '\n== k8s retention: never a live Job ==\n'
# ============================================================

kr_reset
kr_run r-running sbx-mail-0123abcd-tests-6 $(( 4 * day ))
echo 1 > "$K8S_WAKE_BIN/probe-rc"
once
check "retention: probe exit 1 (still running) removes nothing" "" "$(kr_rm_calls)"
echo 4 > "$K8S_WAKE_BIN/probe-rc"
once
check "retention: probe exit 4 (cluster unreachable) removes nothing" "" "$(kr_rm_calls)"
check "retention: an unreaped run carries no reaped marker" no \
    "$([[ -e "$KR_STATE/k8s-reaped/r-running" ]] && echo yes || echo no)"
echo 0 > "$K8S_WAKE_BIN/probe-rc"
once
check "retention: once the Job has finished (probe exit 0) it is removed" \
    "rm --branch sbx-mail-0123abcd-tests-6" "$(kr_rm_calls)"

# ============================================================
printf '\n== k8s retention: a failed rm is retried ==\n'
# ============================================================

kr_reset
kr_run r-old sbx-mail-0123abcd-tests-6 $(( 4 * day ))
echo 1 > "$K8S_WAKE_BIN/rm-rc"
once
check "retention: a failed rm records nothing" no \
    "$([[ -e "$KR_STATE/k8s-reaped/r-old" ]] && echo yes || echo no)"
rm -f "$K8S_WAKE_BIN/rm-rc"
once
check "retention: ...and is tried again next pass" 2 "$(kr_rm_calls | wc -l)"
check "retention: ...which records it" yes \
    "$([[ -e "$KR_STATE/k8s-reaped/r-old" ]] && echo yes || echo no)"

# ============================================================
printf '\n== k8s retention: bounds and settings ==\n'
# ============================================================

kr_reset
for n in 1 2 3 4 5 6 7; do kr_run "r-$n" "sbx-mail-0123abcd-tests-$n" $(( 4 * day )); done
once
check "retention: at most 5 runs probed per pass" 5 "$(kr_probe_count)"
once
check "retention: the rest go next pass" 7 "$(kr_rm_calls | wc -l)"

kr_reset
kr_run r-old sbx-mail-0123abcd-tests-6 $(( 4 * day ))
FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY=600 once
kr_run r-old2 sbx-mail-0123abcd-tests-7 $(( 4 * day ))
FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY=600 once
check "retention: a second pass inside the interval does not sweep" 1 "$(kr_rm_calls | wc -l)"

kr_reset
kr_run r-old sbx-mail-0123abcd-tests-6 $(( 1 * day + 60 ))
FORK_SANDBOX_POSTMASTER_K8S_RETENTION=$day once
check "retention: FORK_SANDBOX_POSTMASTER_K8S_RETENTION sets the window" 1 "$(kr_rm_calls | wc -l)"

kr_reset
kr_run r-old sbx-mail-0123abcd-tests-6 $(( 400 * day ))
FORK_SANDBOX_POSTMASTER_K8S_RETENTION=0 once
check "retention: 0 disables it" "" "$(kr_rm_calls)"

for bad in FORK_SANDBOX_POSTMASTER_K8S_RETENTION FORK_SANDBOX_POSTMASTER_K8S_RETENTION_EVERY; do
    rc=0
    env "$bad=3d" "$postmaster" deliver --project "$PROJECT_DIR" --once >"$work/once.out" 2>"$work/once.err" || rc=$?
    if (( rc != 0 )) && grep -qF "\$$bad '3d' is not a non-negative integer" "$work/once.err"; then
        ok "retention: a malformed $bad refuses deliver"
    else
        no "retention: a malformed $bad refuses deliver" "rc=$rc $(cat "$work/once.err")"
    fi
done

finish_suite
