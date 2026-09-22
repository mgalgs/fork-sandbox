#!/usr/bin/env bash
# fork-sandbox-stop-test.sh — Exercise the `fork-sandbox stop` verb and the
# runner's own TERM handling that backs it
#
# Usage: tests/fork-sandbox-stop-test.sh
#
# Two halves so far:
#
#   The runner's own TERM handling: a real fork-sandbox.sh --foreground run,
#   with claude-sandboxed stubbed out (the fork-sandbox-refresh-test.sh
#   style), signaled with TERM while its one real child sleeps. A bash TERM
#   trap does not fire until the foreground command it is waiting on
#   returns, so this proves the runner defers exactly that long, then lets
#   no further leg start and reaches its ordinary teardown -- fetch, branch
#   removal, exit-code, run-log record -- with end_reason: stopped. A
#   second scenario confirms a normal, unsignaled run's summary.json carries
#   no end_reason key at all.
#
#   The stop verb itself (scripts/fork-sandbox-stop.sh): TODO, next round of
#   work -- already-ended no-op, runner-dead salvage, graceful stop and
#   timeout fallback against a fake runner, and the k8s refusal.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work -- see
# fork-sandbox-refresh-test.sh's own header for why this matters to
# sandbox-run-log.py's default stats.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

not_contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect to find '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-stop-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# =====================================================================
printf '== the runner'"'"'s own TERM handling (real fork-sandbox.sh runs) ==\n'
# =====================================================================

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-stop-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely. Leg 1 sleeps for
# FAKE_SLEEP_SECONDS (default 0) before reporting success, so a caller
# signaling the runner's PID mid-sleep can prove the TERM trap really is
# deferred until this foreground child returns -- sending TERM to the
# runner's bash process never reaches this child directly, so it must run
# to completion on its own.
set -uo pipefail

outbox=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--bind-rw" ]] && outbox="$a"
    prev="$a"
done

cat >/dev/null

n=0
[[ -f "$FAKE_CLAUDE_COUNT_FILE" ]] && n="$(cat "$FAKE_CLAUDE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_CLAUDE_COUNT_FILE"

sleep "${FAKE_SLEEP_SECONDS:-0}"

if [[ -n "$outbox" && "${FAKE_HANDOFF_LEGS:-}" == *",$n,"* ]]; then
    printf 'HANDOFF from leg %s\n' "$n" > "$outbox/handoff.md"
fi

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

proj="$(new_project)"; tmpdirs+=("$proj")

# -- TERM sent while leg 1's child sleeps: leg 1 finishes on its own (the
# trap cannot reach it), the deferred trap then fires, and the refresh
# loop's own stop check (the one this round added) keeps a second leg --
# which the stub would otherwise write a hand-off for and start -- from
# ever running. The run reaches its ordinary teardown with end_reason:
# stopped, the branch fetched back into the origin repo.
count_file="$(mktemp)"; tmpdirs+=("$count_file")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-stop-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"
out_file="$(mktemp)"; tmpdirs+=("$out_file")

PATH="$stub_bin:$PATH" \
    FAKE_CLAUDE_COUNT_FILE="$count_file" \
    FAKE_SLEEP_SECONDS=3 \
    FAKE_HANDOFF_LEGS=",1," \
    "$launcher" --foreground --harness claude --refresh-at 0.5 \
    "$proj" "$handoff" > "$out_file" 2>&1 &
runner_pid=$!

rd=""
for _ in $(seq 1 100); do
    rd="$(sed -n 's/^  run dir:  *//p' "$out_file" 2>/dev/null | head -1)"
    [[ -n "$rd" ]] && break
    sleep 0.1
done
if [[ -n "$rd" ]]; then
    tmpdirs+=("$rd")
    # Give leg 1's stub a moment to actually start sleeping before signaling,
    # so the TERM lands mid-sleep rather than before the child even forked.
    sleep 0.5
    kill -TERM "$runner_pid" 2>/dev/null
    wait "$runner_pid" 2>/dev/null
    rc_seen=0
    for _ in $(seq 1 100); do
        [[ -f "$rd/exit-code" ]] && { rc_seen=1; break; }
        sleep 0.1
    done
    if (( rc_seen )); then
        check "signaled mid-leg: only leg 1 ran, no continuation started" \
            "1" "$(cat "$count_file" 2>/dev/null)"
        check "signaled mid-leg: summary.json's end_reason is stopped" \
            "stopped" "$(jq -r '.end_reason // empty' "$rd/summary.json" 2>/dev/null)"
        check "signaled mid-leg: refresh ended stop-requested" \
            "stop-requested" "$(jq -r '.refresh // empty' "$rd/summary.json" 2>/dev/null)"
        check "signaled mid-leg: the branch was fetched back" \
            "true" "$(jq -r '.fetched // empty' "$rd/summary.json" 2>/dev/null)"
        # The stub never commits anything, so the branch sits exactly at
        # base_sha after the fetch -- the existing teardown's zero-commit
        # rule removes it, same as it would for any run that produced no
        # commits. This proves the stop path reuses that rule rather than
        # bypassing it.
        check "signaled mid-leg: the fetched, commit-free branch was removed" \
            "true" "$(jq -r '.branch_removed // empty' "$rd/summary.json" 2>/dev/null)"
    else
        no "signaled mid-leg: only leg 1 ran, no continuation started" "no exit-code ever appeared"
        no "signaled mid-leg: summary.json's end_reason is stopped" "no exit-code ever appeared"
        no "signaled mid-leg: refresh ended stop-requested" "no exit-code ever appeared"
        no "signaled mid-leg: the branch was fetched back" "no exit-code ever appeared"
        no "signaled mid-leg: the fetched, commit-free branch was removed" "no exit-code ever appeared"
    fi
else
    no "signaled mid-leg: only leg 1 ran, no continuation started" "no run dir ever appeared: $(cat "$out_file")"
    no "signaled mid-leg: summary.json's end_reason is stopped" "no run dir"
    no "signaled mid-leg: refresh ended stop-requested" "no run dir"
    no "signaled mid-leg: the branch was fetched back" "no run dir"
    no "signaled mid-leg: the fetched, commit-free branch was removed" "no run dir"
fi

# -- a normal, unsignaled run's summary.json has no end_reason key at all.
count_file2="$(mktemp)"; tmpdirs+=("$count_file2")
out2="$(PATH="$stub_bin:$PATH" \
    FAKE_CLAUDE_COUNT_FILE="$count_file2" \
    FAKE_SLEEP_SECONDS=0 \
    FAKE_HANDOFF_LEGS="" \
    timeout 60 "$launcher" --foreground --harness claude \
    "$proj" "$handoff" 2>&1)"
rd2="$(printf '%s\n' "$out2" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rd2" ]]; then
    tmpdirs+=("$rd2")
    if [[ -f "$rd2/summary.json" ]]; then
        not_contains "a normal run's summary.json has no end_reason key" \
            "end_reason" "$(cat "$rd2/summary.json")"
    else
        no "a normal run's summary.json has no end_reason key" "no summary.json"
    fi
    branch2="$(sed -n 's/^branch=//p' "$rd2/run.env" 2>/dev/null | head -1)"
    [[ -n "$branch2" ]] && (cd "$proj" && git branch -q -D "$branch2" >/dev/null 2>&1) || true
else
    no "a normal run's summary.json has no end_reason key" "no run dir: $out2"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
