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
#   The stop verb itself (scripts/fork-sandbox-stop.sh): already-ended
#   no-op, runner-dead salvage (a fake run dir plus a real clone with a
#   commit still to fetch), a graceful stop and a timeout fallback each
#   against a fake runner script (no real harness needed), and the k8s
#   refusal.

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

# =====================================================================
printf '\n== the stop verb (scripts/fork-sandbox-stop.sh) ==\n'
# =====================================================================

stop="$repo_dir/scripts/fork-sandbox-stop.sh"

new_run_dir() {
    local d
    d="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.stopXXXXXX)"
    tmpdirs+=("$d")
    # Marks every fixture as a test run, the same way the real launcher's
    # FORK_SANDBOX_RUN_SOURCE does, so these hand-built runs never skew
    # sandbox-run-log.py's default stats.
    printf 'test\n' > "$d/run-source"
    printf '%s' "$d"
}

# -- already-ended: idempotent no-op, not an error, nothing rewritten.
rd_ended="$(new_run_dir)"
cat > "$rd_ended/run.env" <<EOF
version=1
branch=fs-stop-ended
origin_repo=/tmp/nonexistent-origin
clone_dir=/tmp/nonexistent-clone
base_sha=0000000000000000000000000000000000000000
session=cc-sbx-fs-stop-ended
EOF
printf '0\n' > "$rd_ended/exit-code"
out_ended="$("$stop" "$rd_ended" 2>&1)"; rc_ended=$?
check "already-ended: exits 0" "0" "$rc_ended"
contains "already-ended: says nothing to stop" "already ended" "$out_ended"
check "already-ended: exit-code file untouched" "0" "$(cat "$rd_ended/exit-code")"
check "already-ended: no summary.json written" "0" "$([[ -e "$rd_ended/summary.json" ]] && echo 1 || echo 0)"

# -- k8s refusal: a run.env marking network=cluster is refused, naming
# 'fork-sandbox-k8s.sh rm' rather than touching anything.
rd_k8s="$(new_run_dir)"
cat > "$rd_k8s/run.env" <<EOF
version=1
branch=fs-stop-k8s
origin_repo=/tmp/nonexistent-origin
clone_dir=/tmp/nonexistent-clone
base_sha=0000000000000000000000000000000000000000
network=cluster
session=cc-sbx-fs-stop-k8s
EOF
out_k8s="$("$stop" "$rd_k8s" 2>&1)"; rc_k8s=$?
if (( rc_k8s != 0 )); then
    ok "k8s run: refused (non-zero exit)"
else
    no "k8s run: refused (non-zero exit)" "exited 0: $out_k8s"
fi
contains "k8s run: names fork-sandbox-k8s.sh rm" "fork-sandbox-k8s.sh rm" "$out_k8s"
check "k8s run: no exit-code written" "0" "$([[ -e "$rd_k8s/exit-code" ]] && echo 1 || echo 0)"

# -- runner-dead salvage: a fake run dir with a dead pid and no exit-code,
# pointed at a real origin repo and a real clone that holds one unpushed
# commit on the run's branch. The stop verb must fetch it back, remove
# nothing (there IS a commit), write exit-code 143, and record end_reason:
# salvaged -- exactly the filed incident's after-state, closed
# retroactively.
salvage_origin="$(new_project)"; tmpdirs+=("$salvage_origin")
salvage_base_sha="$(cd "$salvage_origin" && git rev-parse HEAD)"
salvage_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-salvage-clone.XXXXXX)"
tmpdirs+=("$salvage_clone")
(
    cd "$salvage_origin" && git clone -q . "$salvage_clone" \
        && cd "$salvage_clone" \
        && git checkout -q -b fs-stop-salvage \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'work\n' > salvage.txt \
        && git add salvage.txt \
        && git commit -q -m 'salvaged work'
) >/dev/null 2>&1
rd_salvage="$(new_run_dir)"
cat > "$rd_salvage/run.env" <<EOF
version=1
branch=fs-stop-salvage
origin_repo=$salvage_origin
clone_dir=$salvage_clone
base_sha=$salvage_base_sha
session=cc-sbx-fs-stop-salvage-does-not-exist
EOF
# A pid that is guaranteed dead: start a subshell and wait for it, so by
# the time its number is written the kernel has already reaped it and
# kill -0 on it can never succeed.
( : ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n' "$dead_pid" > "$rd_salvage/pid"
out_salvage="$("$stop" "$rd_salvage" 2>&1)"; rc_salvage=$?
check "salvage: exits 0" "0" "$rc_salvage"
contains "salvage: reports end_reason salvaged" "salvaged" "$out_salvage"
check "salvage: exit-code 143 written" "143" "$(cat "$rd_salvage/exit-code" 2>/dev/null)"
check "salvage: summary.json end_reason is salvaged" \
    "salvaged" "$(jq -r '.end_reason // empty' "$rd_salvage/summary.json" 2>/dev/null)"
check "salvage: branch fetched back with its commit" \
    "1" "$(cd "$salvage_origin" && git rev-list --count "$salvage_base_sha..fs-stop-salvage" 2>/dev/null)"
check "salvage: branch NOT removed (it has a real commit)" \
    "1" "$(cd "$salvage_origin" && git show-ref --quiet "refs/heads/fs-stop-salvage" && echo 1 || echo 0)"
if grep -q "\"run_id\":\"$(basename "$rd_salvage")\"" "$HOME/.claude/sandbox-runs.jsonl" 2>/dev/null \
    || grep -F "$(basename "$rd_salvage")" "$HOME/.claude/sandbox-runs.jsonl" 2>/dev/null | grep -q '"end_reason":"salvaged"'; then
    ok "salvage: run-log record appended with end_reason salvaged"
else
    no "salvage: run-log record appended with end_reason salvaged" \
        "no matching run_end line in ~/.claude/sandbox-runs.jsonl"
fi

# A fake runner: writes its own pid as its first act (mirroring the real
# runner), then either honors or ignores TERM depending on which script is
# used below. Runs under setsid --fork so it gets its own session and
# process group -- exactly the isolation a tmux pane's top process has --
# so the stop verb's group-signal can be exercised without touching this
# test script's own process group.
fake_runner_honors_term="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_honors_term")
cat > "$fake_runner_honors_term" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap 'printf "0\n" > "$RUN_DIR/exit-code"; exit 0' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_honors_term"

fake_runner_ignores_term="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_ignores_term")
cat > "$fake_runner_ignores_term" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap '' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_ignores_term"

wait_for_file() {
    local f="$1" _n
    for _n in $(seq 1 100); do
        [[ -e "$f" ]] && return 0
        sleep 0.1
    done
    return 1
}

# -- graceful stop: the fake runner honors TERM and writes exit-code
# itself, the same as fork-sandbox.sh's own teardown would after its
# deferred trap runs. The stop verb must signal it, notice the exit-code
# appear well inside a generous timeout, and report success without ever
# falling back to the violent path (no fetch, no kill-session needed since
# the run never named a real branch here).
rd_graceful="$(new_run_dir)"
cat > "$rd_graceful/run.env" <<EOF
version=1
branch=fs-stop-graceful
origin_repo=/tmp/nonexistent-origin
clone_dir=/tmp/nonexistent-clone
base_sha=0000000000000000000000000000000000000000
session=cc-sbx-fs-stop-graceful-does-not-exist
EOF
RUN_DIR="$rd_graceful" setsid --fork "$fake_runner_honors_term" \
    < /dev/null > "$rd_graceful/fake-runner.log" 2>&1 &
graceful_job=$!
if wait_for_file "$rd_graceful/pid"; then
    out_graceful="$(timeout 20 "$stop" --timeout 15 "$rd_graceful" 2>&1)"; rc_graceful=$?
    check "graceful: exits 0" "0" "$rc_graceful"
    contains "graceful: reports stopped gracefully" "stopped gracefully" "$out_graceful"
    check "graceful: exit-code 0 as the fake runner wrote" "0" "$(cat "$rd_graceful/exit-code" 2>/dev/null)"
else
    no "graceful: exits 0" "fake runner never wrote a pid file"
    no "graceful: reports stopped gracefully" "fake runner never wrote a pid file"
    no "graceful: exit-code 0 as the fake runner wrote" "fake runner never wrote a pid file"
fi
wait "$graceful_job" 2>/dev/null || true

# -- timeout fallback: the fake runner ignores TERM entirely, so the
# graceful wait must expire and the stop verb must fall back to the
# violent path: fetch the branch back (there is a real commit waiting in
# a real clone), leave it in place (it has a commit, so the zero-commit
# removal rule must not touch it), write exit-code 143, and record
# end_reason: stop-timeout -- distinguishable from both a clean stop and a
# salvage.
timeout_origin="$(new_project)"; tmpdirs+=("$timeout_origin")
timeout_base_sha="$(cd "$timeout_origin" && git rev-parse HEAD)"
timeout_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-timeout-clone.XXXXXX)"
tmpdirs+=("$timeout_clone")
(
    cd "$timeout_origin" && git clone -q . "$timeout_clone" \
        && cd "$timeout_clone" \
        && git checkout -q -b fs-stop-timeout \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'work\n' > timeout-work.txt \
        && git add timeout-work.txt \
        && git commit -q -m 'in-flight work'
) >/dev/null 2>&1
rd_timeout="$(new_run_dir)"
cat > "$rd_timeout/run.env" <<EOF
version=1
branch=fs-stop-timeout
origin_repo=$timeout_origin
clone_dir=$timeout_clone
base_sha=$timeout_base_sha
session=cc-sbx-fs-stop-timeout-does-not-exist
EOF
RUN_DIR="$rd_timeout" setsid --fork "$fake_runner_ignores_term" \
    < /dev/null > "$rd_timeout/fake-runner.log" 2>&1 &
timeout_job=$!
if wait_for_file "$rd_timeout/pid"; then
    out_timeout="$(timeout 20 "$stop" --timeout 2 "$rd_timeout" 2>&1)"; rc_timeout=$?
    check "timeout: exits 0 (completed host-side)" "0" "$rc_timeout"
    contains "timeout: reports stop-timeout" "stop-timeout" "$out_timeout"
    check "timeout: exit-code 143 written" "143" "$(cat "$rd_timeout/exit-code" 2>/dev/null)"
    check "timeout: summary.json end_reason is stop-timeout" \
        "stop-timeout" "$(jq -r '.end_reason // empty' "$rd_timeout/summary.json" 2>/dev/null)"
    check "timeout: branch fetched back with its commit" \
        "1" "$(cd "$timeout_origin" && git rev-list --count "$timeout_base_sha..fs-stop-timeout" 2>/dev/null)"
    check "timeout: branch NOT removed (it has a real commit)" \
        "1" "$(cd "$timeout_origin" && git show-ref --quiet "refs/heads/fs-stop-timeout" && echo 1 || echo 0)"
    fake_pid="$(cat "$rd_timeout/pid" 2>/dev/null)"
    # The fake runner ignores TERM by design, so it is still alive here --
    # a real tmux pane's kill-session would take it down; kill it directly
    # so the test does not leak a process that outlives it.
    [[ -n "$fake_pid" ]] && kill -9 "$fake_pid" 2>/dev/null || true
else
    no "timeout: exits 0 (completed host-side)" "fake runner never wrote a pid file"
    no "timeout: reports stop-timeout" "fake runner never wrote a pid file"
    no "timeout: exit-code 143 written" "fake runner never wrote a pid file"
    no "timeout: summary.json end_reason is stop-timeout" "fake runner never wrote a pid file"
    no "timeout: branch fetched back with its commit" "fake runner never wrote a pid file"
    no "timeout: branch NOT removed (it has a real commit)" "fake runner never wrote a pid file"
fi
wait "$timeout_job" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
