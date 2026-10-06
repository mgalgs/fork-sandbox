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
#
#   Real-mechanism regression coverage: the two halves above never drove a
#   fake runner that leads its own process group AND holds a child that
#   does not trap TERM itself, and never drove one whose pgid differs from
#   its pid -- so the group-signal path and the leadership guard were both
#   unproven by anything that would fail if either broke. This section
#   adds fixtures for both, plus exact-match tmux kill-session, the
#   return_base_sha commit count, a real-repo branch removal through the
#   stop verb's own code path, and a failed fetch.

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
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
# Every real launch below writes launcher_session_id/creates a by-session
# symlink from CLAUDE_CODE_SESSION_ID -- scoped here so a real session
# running this suite never has its own by-session index polluted with
# entries for these throwaway fixture runs.
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"
# The real fork-sandbox.sh fixtures below run under this scratch HOME, not
# the operator's: sandbox-run-log.py's archive dir and run log are
# deliberately hardcoded under ~/.claude (no flag can aim them elsewhere),
# so a fixture run under the real HOME appends handoff archives that are
# indistinguishable from an operator's real work -- the same leak
# fork-sandbox-k8s-test.sh isolates its record fixtures against. A scratch
# HOME also empties the launcher's ${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/
# fork-sandbox}, so machine config -- credential balancing above all --
# cannot route a fixture run, nor refuse it outright when the machine's
# live quota is tight. The guard near the end of this file holds the
# archive half of this.
launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
# The launcher's own security boundary requires the project to live under
# ~/src -- which it resolves against the scratch HOME above, so fixture
# projects must live there too (and the suite stops littering the real
# ~/src as a side effect). sandbox-run-log.py's record() opens its
# ~/.claude/sandbox-runs.jsonl in append mode and does not create the
# parent directory itself, so on a genuinely empty HOME (no prior real
# usage to have created it) record() fails outright -- pre-create it here
# rather than relying on an operator's real ~/.claude having always
# already existed. The scripts/fork-sandbox-stop.sh fixtures below, which
# run under this same scratch HOME, share this directory.
mkdir -p "$launcher_home/src" "$launcher_home/.claude"
operator_archive_dir="$HOME/.claude/sandbox-handoffs"
# Set only by the exact-match tmux test, to a dedicated -L server -- never
# the caller's own default one, per
# fork-sandbox-clone-dir-lock-lifetime-test.sh's header. Killed in the EXIT
# trap, not just inline, so an interrupted run cannot leave a real cc-sbx-*
# session alive on it.
tmux_socket=""

cleanup() {
    local d
    if [[ -n "$tmux_socket" ]]; then
        tmux -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
    fi
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

check_ge() {
    local label="$1" min="$2" actual="$3"
    if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual >= min )); then
        ok "$label"
    else
        no "$label" "expected >= $min, got '$actual'"
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
    d="$(mktemp -d "$launcher_home/src/fs-stop-test.XXXXXX")"
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

HOME="$launcher_home" PATH="$stub_bin:$PATH" \
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

# -- a TERM landing before the tidy leg ever starts means no tidy
# leg runs at all -- stop_requested is the FIRST thing the tidy
# eligibility check in fork-sandbox.sh reads (ahead of whether a maintain
# step even ran), so signaling during leg 1 of a maintainer-loop pipeline
# already proves this: by the time that check runs, stop_requested is set
# regardless of which leg was in flight when it was, and nothing resets
# it. The maintain leg itself never runs either, so this is also coverage
# for "no leg of this run ever reaches the tidy block after a stop".
count_file_tidy="$(mktemp)"; tmpdirs+=("$count_file_tidy")
out_file_tidy="$(mktemp)"; tmpdirs+=("$out_file_tidy")
HOME="$launcher_home" PATH="$stub_bin:$PATH" \
    FAKE_CLAUDE_COUNT_FILE="$count_file_tidy" \
    FAKE_SLEEP_SECONDS=3 \
    FAKE_HANDOFF_LEGS="" \
    "$launcher" --foreground --harness claude --maintainer-loop 1 \
    --maintainer-model sonnet \
    "$proj" "$handoff" > "$out_file_tidy" 2>&1 &
runner_pid_tidy=$!
rd_tidy_stop=""
for _ in $(seq 1 100); do
    rd_tidy_stop="$(sed -n 's/^  run dir:  *//p' "$out_file_tidy" 2>/dev/null | head -1)"
    [[ -n "$rd_tidy_stop" ]] && break
    sleep 0.1
done
if [[ -n "$rd_tidy_stop" ]]; then
    tmpdirs+=("$rd_tidy_stop")
    sleep 0.5
    kill -TERM "$runner_pid_tidy" 2>/dev/null
    wait "$runner_pid_tidy" 2>/dev/null
    rc_seen_tidy=0
    for _ in $(seq 1 100); do
        [[ -f "$rd_tidy_stop/exit-code" ]] && { rc_seen_tidy=1; break; }
        sleep 0.1
    done
    if (( rc_seen_tidy )); then
        check "stop-before-tidy: only leg 1 ran, the maintain leg never started" \
            "1" "$(cat "$count_file_tidy" 2>/dev/null)"
        check "stop-before-tidy: no tidy leg ran either (no events-tidy-1.jsonl)" \
            "0" "$([[ -e "$rd_tidy_stop/events-tidy-1.jsonl" ]] && echo 1 || echo 0)"
        check "stop-before-tidy: tidy.json still exists (this pipeline HAS a maintain step)" \
            "skipped" "$(jq -r '.ended // empty' "$rd_tidy_stop/tidy.json" 2>/dev/null)"
        contains "stop-before-tidy: the skip detail cites the stop request" \
            "stop requested" "$(jq -r '.detail // empty' "$rd_tidy_stop/tidy.json" 2>/dev/null)"
        check "stop-before-tidy: summary.json's tidy key is present, ended skipped" \
            "skipped" "$(jq -r '.tidy.ended // empty' "$rd_tidy_stop/summary.json" 2>/dev/null)"
    else
        no "stop-before-tidy: only leg 1 ran, the maintain leg never started" "no exit-code ever appeared"
        no "stop-before-tidy: no tidy leg ran either (no events-tidy-1.jsonl)" "no exit-code ever appeared"
        no "stop-before-tidy: tidy.json still exists (this pipeline HAS a maintain step)" "no exit-code ever appeared"
        no "stop-before-tidy: the skip detail cites the stop request" "no exit-code ever appeared"
        no "stop-before-tidy: summary.json's tidy key is present, ended skipped" "no exit-code ever appeared"
    fi
    branch_tidy_stop="$(sed -n 's/^branch=//p' "$rd_tidy_stop/run.env" 2>/dev/null | head -1)"
    [[ -n "$branch_tidy_stop" ]] && (cd "$proj" && git branch -q -D "$branch_tidy_stop" >/dev/null 2>&1) || true
else
    no "stop-before-tidy: only leg 1 ran, the maintain leg never started" "no run dir ever appeared: $(cat "$out_file_tidy")"
    no "stop-before-tidy: no tidy leg ran either (no events-tidy-1.jsonl)" "no run dir"
    no "stop-before-tidy: tidy.json still exists (this pipeline HAS a maintain step)" "no run dir"
    no "stop-before-tidy: the skip detail cites the stop request" "no run dir"
    no "stop-before-tidy: summary.json's tidy key is present, ended skipped" "no run dir"
fi

# -- a normal, unsignaled run's summary.json has no end_reason key at all.
count_file2="$(mktemp)"; tmpdirs+=("$count_file2")
out2="$(HOME="$launcher_home" PATH="$stub_bin:$PATH" \
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

# The merged run-log record for a run dir, by basename -- reuses
# sandbox-run-log.py's own "last run_end wins" merge instead of hand-rolling
# jq filtering over the raw jsonl.
run_log_show() {
    HOME="$launcher_home" "$repo_dir/scripts/sandbox-run-log.py" show "$(basename "$1")" 2>/dev/null
}

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
out_ended="$(HOME="$launcher_home" "$stop" "$rd_ended" 2>&1)"; rc_ended=$?
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
out_k8s="$(HOME="$launcher_home" "$stop" "$rd_k8s" 2>&1)"; rc_k8s=$?
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
# A progress.json left mid-run by a runner that died before it could
# finalize its own: one step still "running", the run still "running".
# complete_run_host_side is the only thing left that will ever touch this
# file, since the process that would have finalized it is already gone.
cat > "$rd_salvage/progress.json" <<'EOF'
{"schema":1,"label":"fs-stop-salvage","spec":null,"state":"running","updated":1,
 "steps":[{"action":"code","state":"running","i":1,"cap":1,"ended":null}]}
EOF
out_salvage="$(HOME="$launcher_home" "$stop" "$rd_salvage" 2>&1)"; rc_salvage=$?
check "salvage: exits 0" "0" "$rc_salvage"
contains "salvage: reports end_reason salvaged" "salvaged" "$out_salvage"
check "salvage: exit-code 143 written" "143" "$(cat "$rd_salvage/exit-code" 2>/dev/null)"
check "salvage: no summary.json fabricated" \
    "0" "$([[ -e "$rd_salvage/summary.json" ]] && echo 1 || echo 0)"
check "salvage: run-log end_reason is salvaged via --end-reason" \
    "salvaged" "$(run_log_show "$rd_salvage" | jq -r '.end_reason // empty')"
check "salvage: run-log marks summary_missing (no stub was fabricated)" \
    "true" "$(run_log_show "$rd_salvage" | jq -r '.summary_missing // false')"
check "salvage: branch fetched back with its commit" \
    "1" "$(cd "$salvage_origin" && git rev-list --count "$salvage_base_sha..fs-stop-salvage" 2>/dev/null)"
check "salvage: branch NOT removed (it has a real commit)" \
    "1" "$(cd "$salvage_origin" && git show-ref --quiet "refs/heads/fs-stop-salvage" && echo 1 || echo 0)"
check "salvage: progress.json finalized to stopped (never left 'running')" \
    "stopped" "$(jq -r '.state' "$rd_salvage/progress.json" 2>/dev/null)"
check "salvage: progress.json's in-flight step is skipped, not left running" \
    "skipped" "$(jq -r '.steps[0].state' "$rd_salvage/progress.json" 2>/dev/null)"
check "salvage: progress.json's in-flight step records why it stopped" \
    "stop-requested" "$(jq -r '.steps[0].ended' "$rd_salvage/progress.json" 2>/dev/null)"
check "salvage: no leftover progress.json.part" \
    "0" "$([[ -e "$rd_salvage/progress.json.part" ]] && echo 1 || echo 0)"

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
# appear well inside a generous timeout, and report success. A real
# origin+clone (zero commits past base) is needed here even though this
# fixture never adds work, because the graceful report now confirms the
# branch's fetched-back state by repeating the fetch itself -- a
# nonexistent origin/clone would make that confirmation fail and the test
# would wrongly look like a regression.
graceful_origin="$(new_project)"; tmpdirs+=("$graceful_origin")
graceful_base_sha="$(cd "$graceful_origin" && git rev-parse HEAD)"
graceful_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-graceful-clone.XXXXXX)"
tmpdirs+=("$graceful_clone")
(
    cd "$graceful_origin" && git clone -q . "$graceful_clone" \
        && cd "$graceful_clone" && git checkout -q -b fs-stop-graceful
) >/dev/null 2>&1
rd_graceful="$(new_run_dir)"
cat > "$rd_graceful/run.env" <<EOF
version=1
branch=fs-stop-graceful
origin_repo=$graceful_origin
clone_dir=$graceful_clone
base_sha=$graceful_base_sha
session=cc-sbx-fs-stop-graceful-does-not-exist
EOF
RUN_DIR="$rd_graceful" setsid --fork "$fake_runner_honors_term" \
    < /dev/null > "$rd_graceful/fake-runner.log" 2>&1 &
graceful_job=$!
if wait_for_file "$rd_graceful/pid"; then
    out_graceful="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_graceful" 2>&1)"; rc_graceful=$?
    check "graceful: exits 0" "0" "$rc_graceful"
    contains "graceful: reports stopped gracefully" "stopped gracefully" "$out_graceful"
    check "graceful: exit-code 0 as the fake runner wrote" "0" "$(cat "$rd_graceful/exit-code" 2>/dev/null)"
else
    no "graceful: exits 0" "fake runner never wrote a pid file"
    no "graceful: reports stopped gracefully" "fake runner never wrote a pid file"
    no "graceful: exit-code 0 as the fake runner wrote" "fake runner never wrote a pid file"
fi
wait "$graceful_job" 2>/dev/null || true

# -- graceful stop, delayed exit: the fake runner writes exit-code
# immediately on TERM but does not actually exit for a few seconds after --
# mirroring fork-sandbox.sh's own teardown, which writes exit-code BEFORE
# its fetch-back (README.md documents that ordering). Proves 3.6: the stop
# verb must wait for the runner PROCESS to exit, not merely for exit-code
# to appear, or "stopped gracefully" could print while the fetch-back is
# still in flight. Pre-3.6 code broke its wait as soon as exit-code
# existed, so it would return in well under a second here; the fix must
# take at least as long as the delay.
fake_runner_delayed_exit="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_delayed_exit")
cat > "$fake_runner_delayed_exit" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap 'printf "0\n" > "$RUN_DIR/exit-code"; sleep 3; exit 0' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_delayed_exit"

# A real origin+clone, same reason as the plain graceful fixture above: the
# graceful report now confirms the fetched-back state itself.
delayed_origin="$(new_project)"; tmpdirs+=("$delayed_origin")
delayed_base_sha="$(cd "$delayed_origin" && git rev-parse HEAD)"
delayed_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-delayed-clone.XXXXXX)"
tmpdirs+=("$delayed_clone")
(
    cd "$delayed_origin" && git clone -q . "$delayed_clone" \
        && cd "$delayed_clone" && git checkout -q -b fs-stop-delayed
) >/dev/null 2>&1

rd_delayed="$(new_run_dir)"
cat > "$rd_delayed/run.env" <<EOF
version=1
branch=fs-stop-delayed
origin_repo=$delayed_origin
clone_dir=$delayed_clone
base_sha=$delayed_base_sha
session=cc-sbx-fs-stop-delayed-does-not-exist
EOF
RUN_DIR="$rd_delayed" setsid --fork "$fake_runner_delayed_exit" \
    < /dev/null > "$rd_delayed/fake-runner.log" 2>&1 &
delayed_job=$!
if wait_for_file "$rd_delayed/pid"; then
    delayed_pid="$(cat "$rd_delayed/pid")"
    start_ts="$(date +%s)"
    out_delayed="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_delayed" 2>&1)"; rc_delayed=$?
    elapsed_delayed=$(( $(date +%s) - start_ts ))
    check "graceful-with-delay: exits 0" "0" "$rc_delayed"
    contains "graceful-with-delay: reports stopped gracefully" "stopped gracefully" "$out_delayed"
    check "graceful-with-delay: exit-code 0 as the fake runner wrote" "0" "$(cat "$rd_delayed/exit-code" 2>/dev/null)"
    check_ge "graceful-with-delay: stop waited for the process to actually exit, not just exit-code to appear" \
        "2" "$elapsed_delayed"
    if kill -0 "$delayed_pid" 2>/dev/null; then
        no "graceful-with-delay: the runner process has actually exited" \
            "pid $delayed_pid is still alive after stop reported success"
        kill -9 "$delayed_pid" 2>/dev/null || true
    else
        ok "graceful-with-delay: the runner process has actually exited"
    fi
else
    no "graceful-with-delay: exits 0" "fake runner never wrote a pid file"
    no "graceful-with-delay: reports stopped gracefully" "fake runner never wrote a pid file"
    no "graceful-with-delay: exit-code 0 as the fake runner wrote" "fake runner never wrote a pid file"
    no "graceful-with-delay: stop waited for the process to actually exit, not just exit-code to appear" \
        "fake runner never wrote a pid file"
    no "graceful-with-delay: the runner process has actually exited" "fake runner never wrote a pid file"
fi
wait "$delayed_job" 2>/dev/null || true

# -- graceful stop, --keep-session shape: the fake runner honors TERM,
# writes exit-code and summary.json exactly like a real teardown, then
# `exec`s into something that keeps its pid alive forever -- the same
# shape fork-sandbox.sh's own --keep-session path ends in (`exec
# "$user_shell" -i"`, after exit-code, fetch-back and summary.json are all
# already written). kill -0 on this pid never fails, so a wait that only
# ever polls for process death would spin for the full --timeout and then
# WRONGLY force-complete a run that already finished perfectly cleanly --
# overwriting its real exit-code 0 with 143 and appending a second,
# contradictory run_end. The fix must instead notice summary.json and
# treat that as "teardown finished" on its own.
fake_runner_keep_session="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_keep_session")
cat > "$fake_runner_keep_session" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap '
    printf "0\n" > "$RUN_DIR/exit-code"
    printf "{}\n" > "$RUN_DIR/summary.json"
    exec sleep 300
' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_keep_session"

keepsession_origin="$(new_project)"; tmpdirs+=("$keepsession_origin")
keepsession_base_sha="$(cd "$keepsession_origin" && git rev-parse HEAD)"
keepsession_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-keepsession-clone.XXXXXX)"
tmpdirs+=("$keepsession_clone")
(
    cd "$keepsession_origin" && git clone -q . "$keepsession_clone" \
        && cd "$keepsession_clone" && git checkout -q -b fs-stop-keepsession
) >/dev/null 2>&1

rd_keepsession="$(new_run_dir)"
cat > "$rd_keepsession/run.env" <<EOF
version=1
branch=fs-stop-keepsession
origin_repo=$keepsession_origin
clone_dir=$keepsession_clone
base_sha=$keepsession_base_sha
session=cc-sbx-fs-stop-keepsession-does-not-exist
EOF
RUN_DIR="$rd_keepsession" setsid --fork "$fake_runner_keep_session" \
    < /dev/null > "$rd_keepsession/fake-runner.log" 2>&1 &
keepsession_job=$!
if wait_for_file "$rd_keepsession/pid"; then
    keepsession_pid="$(cat "$rd_keepsession/pid")"
    start_ts_keepsession="$(date +%s)"
    out_keepsession="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_keepsession" 2>&1)"; rc_keepsession=$?
    elapsed_keepsession=$(( $(date +%s) - start_ts_keepsession ))
    check "keep-session shape: exits 0" "0" "$rc_keepsession"
    contains "keep-session shape: reports stopped gracefully" "stopped gracefully" "$out_keepsession"
    not_contains "keep-session shape: does not force-complete a clean stop" "timed out" "$out_keepsession"
    check "keep-session shape: exit-code stays 0, not overwritten to 143" \
        "0" "$(cat "$rd_keepsession/exit-code" 2>/dev/null)"
    if (( elapsed_keepsession < 10 )); then
        ok "keep-session shape: noticed summary.json promptly, did not spin for the full timeout"
    else
        no "keep-session shape: noticed summary.json promptly, did not spin for the full timeout" \
            "took ${elapsed_keepsession}s against a 15s timeout"
    fi
    if kill -0 "$keepsession_pid" 2>/dev/null; then
        ok "keep-session shape: the kept-open pid is left alone"
    else
        no "keep-session shape: the kept-open pid is left alone" \
            "pid $keepsession_pid was killed; --keep-session must survive a graceful stop"
    fi
    kill -9 "$keepsession_pid" 2>/dev/null || true
else
    no "keep-session shape: exits 0" "fake runner never wrote a pid file"
    no "keep-session shape: reports stopped gracefully" "fake runner never wrote a pid file"
    no "keep-session shape: does not force-complete a clean stop" "fake runner never wrote a pid file"
    no "keep-session shape: exit-code stays 0, not overwritten to 143" "fake runner never wrote a pid file"
    no "keep-session shape: noticed summary.json promptly, did not spin for the full timeout" \
        "fake runner never wrote a pid file"
    no "keep-session shape: the kept-open pid is left alone" "fake runner never wrote a pid file"
fi
wait "$keepsession_job" 2>/dev/null || true

# -- graceful stop but the runner's own fetch-back silently failed: the
# fake runner honors TERM and writes exit-code 0 exactly like a real
# successful teardown, but clone_dir is not a git repository at all, so
# fetching it can never succeed. The graceful report must confirm the
# branch actually landed rather than trust exit-code alone -- a runner
# whose own internal fetch-back failed must not read as a clean "stopped
# gracefully" (the same reassuring-but-stranded outcome the failed-fetch
# test below forbids on the forced/salvage path).
fetchfail_origin="$(new_project)"; tmpdirs+=("$fetchfail_origin")
fetchfail_base_sha="$(cd "$fetchfail_origin" && git rev-parse HEAD)"
fetchfail_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-fetchfail-clone.XXXXXX)"
tmpdirs+=("$fetchfail_clone")
rd_fetchfail="$(new_run_dir)"
cat > "$rd_fetchfail/run.env" <<EOF
version=1
branch=fs-stop-fetchfail
origin_repo=$fetchfail_origin
clone_dir=$fetchfail_clone
base_sha=$fetchfail_base_sha
session=cc-sbx-fs-stop-fetchfail-does-not-exist
EOF
RUN_DIR="$rd_fetchfail" setsid --fork "$fake_runner_honors_term" \
    < /dev/null > "$rd_fetchfail/fake-runner.log" 2>&1 &
fetchfail_job=$!
if wait_for_file "$rd_fetchfail/pid"; then
    out_fetchfail="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_fetchfail" 2>&1)"; rc_fetchfail=$?
    if (( rc_fetchfail != 0 )); then
        ok "graceful with failed internal fetch: stop reports non-zero exit"
    else
        no "graceful with failed internal fetch: stop reports non-zero exit" "exited 0: $out_fetchfail"
    fi
    not_contains "graceful with failed internal fetch: does not claim a clean graceful stop" \
        "stopped gracefully" "$out_fetchfail"
else
    no "graceful with failed internal fetch: stop reports non-zero exit" "fake runner never wrote a pid file"
    no "graceful with failed internal fetch: does not claim a clean graceful stop" "fake runner never wrote a pid file"
fi
wait "$fetchfail_job" 2>/dev/null || true

# -- graceful stop must not resurrect a branch the runner's own teardown
# already removed: a fake runner shaped like the real one (fork-sandbox.sh's
# teardown, not this suite's other fixtures, none of which ever remove a
# branch) writes exit-code, then fetches the zero-commit branch back into
# the ORIGIN repo and deletes it there -- never touching the clone, which
# still holds the ref, exactly like the real teardown at
# fork-sandbox.sh:9039-9055. Before this fixture, the graceful path's
# confirmation re-ran 'git fetch clone branch:branch' unconditionally,
# which recreates the ref from the clone's still-live copy and undoes the
# runner's own removal -- a stray branch left in the user's real repo after
# an ordinary, went-nowhere run. Proves the confirmation now applies the
# same zero-commit removal the runner itself just applied, instead of
# blindly repeating only the fetch half of it.
resurrect_origin="$(new_project)"; tmpdirs+=("$resurrect_origin")
resurrect_base_sha="$(cd "$resurrect_origin" && git rev-parse HEAD)"
resurrect_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-resurrect-clone.XXXXXX)"
tmpdirs+=("$resurrect_clone")
(
    cd "$resurrect_origin" && git clone -q . "$resurrect_clone" \
        && cd "$resurrect_clone" && git checkout -q -b fs-stop-resurrect
    # The origin repo holds the branch too, same as a real --checkout run
    # (fork-sandbox.sh checks the branch out in the origin repo before
    # launching) -- this is the ref the fake teardown below removes.
    cd "$resurrect_origin" && git branch -q fs-stop-resurrect "$resurrect_base_sha"
) >/dev/null 2>&1

fake_runner_removes_branch="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_removes_branch")
cat > "$fake_runner_removes_branch" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap '
    printf "0\n" > "$RUN_DIR/exit-code"
    (cd "$ORIGIN_REPO" && git fetch --quiet "$CLONE_DIR" "$BRANCH:$BRANCH") >/dev/null 2>&1
    (cd "$ORIGIN_REPO" && git branch -q -D "$BRANCH") >/dev/null 2>&1
    exit 0
' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_removes_branch"

rd_resurrect="$(new_run_dir)"
cat > "$rd_resurrect/run.env" <<EOF
version=1
branch=fs-stop-resurrect
origin_repo=$resurrect_origin
clone_dir=$resurrect_clone
base_sha=$resurrect_base_sha
session=cc-sbx-fs-stop-resurrect-does-not-exist
EOF
RUN_DIR="$rd_resurrect" ORIGIN_REPO="$resurrect_origin" CLONE_DIR="$resurrect_clone" \
    BRANCH=fs-stop-resurrect \
    setsid --fork "$fake_runner_removes_branch" \
    < /dev/null > "$rd_resurrect/fake-runner.log" 2>&1 &
resurrect_job=$!
if wait_for_file "$rd_resurrect/pid"; then
    out_resurrect="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_resurrect" 2>&1)"; rc_resurrect=$?
    check "confirmation does not resurrect an already-removed branch: stop exits 0" \
        "0" "$rc_resurrect"
    contains "confirmation does not resurrect an already-removed branch: reports stopped gracefully" \
        "stopped gracefully" "$out_resurrect"
    branch_gone=0
    (cd "$resurrect_origin" \
        && ! git rev-parse --verify -q "refs/heads/fs-stop-resurrect" >/dev/null 2>&1) \
        && branch_gone=1
    check "confirmation does not resurrect an already-removed branch: branch stays gone from origin" \
        "1" "$branch_gone"
else
    no "confirmation does not resurrect an already-removed branch: stop exits 0" \
        "fake runner never wrote a pid file"
    no "confirmation does not resurrect an already-removed branch: reports stopped gracefully" \
        "fake runner never wrote a pid file"
    no "confirmation does not resurrect an already-removed branch: branch stays gone from origin" \
        "fake runner never wrote a pid file"
fi
wait "$resurrect_job" 2>/dev/null || true

# -- runner exited without completing its own teardown, e.g. killed
# externally while this verb was waiting (not by anything this verb did):
# nothing of its own teardown can be trusted, so this must not read as a
# clean "stopped gracefully" with the run left open forever. A fake runner
# that ignores TERM (so it never reaches its own exit-code write on its
# own) is SIGKILLed by this test shortly after stop's own TERM lands, well
# inside a generous --timeout. The forced completion must still run --
# fetch, exit-code 143, ledger record -- and promptly, not only once the
# full timeout window elapses.
extkill_origin="$(new_project)"; tmpdirs+=("$extkill_origin")
extkill_base_sha="$(cd "$extkill_origin" && git rev-parse HEAD)"
extkill_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-extkill-clone.XXXXXX)"
tmpdirs+=("$extkill_clone")
(
    cd "$extkill_origin" && git clone -q . "$extkill_clone" \
        && cd "$extkill_clone" \
        && git checkout -q -b fs-stop-extkill \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'work\n' > extkill-work.txt \
        && git add extkill-work.txt \
        && git commit -q -m 'in-flight work'
) >/dev/null 2>&1
rd_extkill="$(new_run_dir)"
cat > "$rd_extkill/run.env" <<EOF
version=1
branch=fs-stop-extkill
origin_repo=$extkill_origin
clone_dir=$extkill_clone
base_sha=$extkill_base_sha
session=cc-sbx-fs-stop-extkill-does-not-exist
EOF
RUN_DIR="$rd_extkill" setsid --fork "$fake_runner_ignores_term" \
    < /dev/null > "$rd_extkill/fake-runner.log" 2>&1 &
extkill_job=$!
if wait_for_file "$rd_extkill/pid"; then
    extkill_pid="$(cat "$rd_extkill/pid")"
    start_ts_extkill="$(date +%s)"
    ( sleep 1; kill -KILL "$extkill_pid" 2>/dev/null || true ) &
    killer_job=$!
    out_extkill="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_extkill" 2>&1)"; rc_extkill=$?
    elapsed_extkill=$(( $(date +%s) - start_ts_extkill ))
    wait "$killer_job" 2>/dev/null || true
    check "external kill mid-wait: stop exits 0 (completed host-side)" "0" "$rc_extkill"
    check "external kill mid-wait: exit-code 143 written" "143" "$(cat "$rd_extkill/exit-code" 2>/dev/null)"
    not_contains "external kill mid-wait: does not falsely claim a clean graceful stop" \
        "stopped gracefully" "$out_extkill"
    check "external kill mid-wait: branch fetched back with its commit" \
        "1" "$(cd "$extkill_origin" && git rev-list --count "$extkill_base_sha..fs-stop-extkill" 2>/dev/null)"
    check "external kill mid-wait: run-log end_reason recorded" \
        "stop-timeout" "$(run_log_show "$rd_extkill" | jq -r '.end_reason // empty')"
    if (( elapsed_extkill < 10 )); then
        ok "external kill mid-wait: noticed the death promptly, not only at the full timeout"
    else
        no "external kill mid-wait: noticed the death promptly, not only at the full timeout" \
            "took ${elapsed_extkill}s against a 15s timeout"
    fi
else
    no "external kill mid-wait: stop exits 0 (completed host-side)" "fake runner never wrote a pid file"
    no "external kill mid-wait: exit-code 143 written" "fake runner never wrote a pid file"
    no "external kill mid-wait: does not falsely claim a clean graceful stop" "fake runner never wrote a pid file"
    no "external kill mid-wait: branch fetched back with its commit" "fake runner never wrote a pid file"
    no "external kill mid-wait: run-log end_reason recorded" "fake runner never wrote a pid file"
    no "external kill mid-wait: noticed the death promptly, not only at the full timeout" \
        "fake runner never wrote a pid file"
fi
wait "$extkill_job" 2>/dev/null || true

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
# Same mid-run progress.json as the salvage fixture above: the fake runner
# never writes one itself, so this stands in for whatever the real runner's
# last rewrite would have left behind before the forced KILL path took over.
cat > "$rd_timeout/progress.json" <<'EOF'
{"schema":1,"label":"fs-stop-timeout","spec":null,"state":"running","updated":1,
 "steps":[{"action":"code","state":"running","i":1,"cap":1,"ended":null}]}
EOF
RUN_DIR="$rd_timeout" setsid --fork "$fake_runner_ignores_term" \
    < /dev/null > "$rd_timeout/fake-runner.log" 2>&1 &
timeout_job=$!
if wait_for_file "$rd_timeout/pid"; then
    out_timeout="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 2 "$rd_timeout" 2>&1)"; rc_timeout=$?
    check "timeout: exits 0 (completed host-side)" "0" "$rc_timeout"
    contains "timeout: reports stop-timeout" "stop-timeout" "$out_timeout"
    check "timeout: exit-code 143 written" "143" "$(cat "$rd_timeout/exit-code" 2>/dev/null)"
    check "timeout: no summary.json fabricated" \
        "0" "$([[ -e "$rd_timeout/summary.json" ]] && echo 1 || echo 0)"
    check "timeout: run-log end_reason is stop-timeout via --end-reason" \
        "stop-timeout" "$(run_log_show "$rd_timeout" | jq -r '.end_reason // empty')"
    check "timeout: run-log marks summary_missing" \
        "true" "$(run_log_show "$rd_timeout" | jq -r '.summary_missing // false')"
    check "timeout: branch fetched back with its commit" \
        "1" "$(cd "$timeout_origin" && git rev-list --count "$timeout_base_sha..fs-stop-timeout" 2>/dev/null)"
    check "timeout: branch NOT removed (it has a real commit)" \
        "1" "$(cd "$timeout_origin" && git show-ref --quiet "refs/heads/fs-stop-timeout" && echo 1 || echo 0)"
    check "timeout: progress.json finalized to stopped (never left 'running')" \
        "stopped" "$(jq -r '.state' "$rd_timeout/progress.json" 2>/dev/null)"
    check "timeout: progress.json's in-flight step is skipped, not left running" \
        "skipped" "$(jq -r '.steps[0].state' "$rd_timeout/progress.json" 2>/dev/null)"
    check "timeout: progress.json's in-flight step records why it stopped" \
        "stop-requested" "$(jq -r '.steps[0].ended' "$rd_timeout/progress.json" 2>/dev/null)"
    check "timeout: no leftover progress.json.part" \
        "0" "$([[ -e "$rd_timeout/progress.json.part" ]] && echo 1 || echo 0)"
    fake_pid="$(cat "$rd_timeout/pid" 2>/dev/null)"
    # The fake runner ignores TERM by design AND there is no real tmux
    # session for this fixture's name, so tmux kill-session is a no-op --
    # only 3.7's KILL fallback in complete_run_host_side can end it. This
    # is the assertion that proves the forced path actually kills a
    # sessionless runner rather than just completing the host-side work
    # around a still-running process.
    if [[ -n "$fake_pid" ]]; then
        if kill -0 "$fake_pid" 2>/dev/null; then
            no "timeout: the forced path actually kills the sessionless runner" \
                "pid $fake_pid is still alive after stop returned; kill-session is a no-op here, so only the KILL fallback could end it"
        else
            ok "timeout: the forced path actually kills the sessionless runner"
        fi
    else
        no "timeout: the forced path actually kills the sessionless runner" "no pid file"
    fi
    # Safety net only: the assertion above is what proves 3.7, and this
    # must already be a no-op by the time it runs.
    [[ -n "$fake_pid" ]] && kill -9 "$fake_pid" 2>/dev/null || true
else
    no "timeout: exits 0 (completed host-side)" "fake runner never wrote a pid file"
    no "timeout: reports stop-timeout" "fake runner never wrote a pid file"
    no "timeout: exit-code 143 written" "fake runner never wrote a pid file"
    no "timeout: no summary.json fabricated" "fake runner never wrote a pid file"
    no "timeout: run-log end_reason is stop-timeout via --end-reason" "fake runner never wrote a pid file"
    no "timeout: run-log marks summary_missing" "fake runner never wrote a pid file"
    no "timeout: branch fetched back with its commit" "fake runner never wrote a pid file"
    no "timeout: branch NOT removed (it has a real commit)" "fake runner never wrote a pid file"
    no "timeout: progress.json finalized to stopped (never left 'running')" "fake runner never wrote a pid file"
    no "timeout: progress.json's in-flight step is skipped, not left running" "fake runner never wrote a pid file"
    no "timeout: progress.json's in-flight step records why it stopped" "fake runner never wrote a pid file"
    no "timeout: no leftover progress.json.part" "fake runner never wrote a pid file"
    no "timeout: the forced path actually kills the sessionless runner" "fake runner never wrote a pid file"
fi
wait "$timeout_job" 2>/dev/null || true

# =====================================================================
printf '\n== real mechanisms: group signal, leadership, exact-match, bases ==\n'
# =====================================================================

# -- group signal reaches a child a pid-only signal would miss: the fake
# runner leads its own process group (same setsid --fork isolation as the
# other fake runners) and traps TERM itself, but also backgrounds a
# sleep(1) child that does NOT trap TERM. Only a group signal -- not
# "kill -TERM $pid" alone -- reaches that child.
#
# This is coverage, not a regression test for 3.1: pre-fix
# (822cc2d35b) already sent the group signal unconditionally, so a
# runner that DOES lead its own group behaves the same before and after
# the fix (confirmed by reading 66005050b7's diff -- 3.1's bug was the
# OPPOSITE case, signaling a group the runner does not lead, covered
# separately below). Kept anyway because nothing else in this suite
# proves the group-signal mechanism reaches an untrapped child at all.
fake_runner_with_child="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_with_child")
cat > "$fake_runner_with_child" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
sleep 300 &
printf '%s\n' "$!" > "$RUN_DIR/child-pid"
trap 'printf "0\n" > "$RUN_DIR/exit-code"; exit 0' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_with_child"

# A real origin+clone: the graceful report now confirms the fetched-back
# state itself, which a nonexistent origin/clone would fail.
group_origin="$(new_project)"; tmpdirs+=("$group_origin")
group_base_sha="$(cd "$group_origin" && git rev-parse HEAD)"
group_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-group-clone.XXXXXX)"
tmpdirs+=("$group_clone")
(
    cd "$group_origin" && git clone -q . "$group_clone" \
        && cd "$group_clone" && git checkout -q -b fs-stop-group
) >/dev/null 2>&1

rd_group="$(new_run_dir)"
cat > "$rd_group/run.env" <<EOF
version=1
branch=fs-stop-group
origin_repo=$group_origin
clone_dir=$group_clone
base_sha=$group_base_sha
session=cc-sbx-fs-stop-group-does-not-exist
EOF
RUN_DIR="$rd_group" setsid --fork "$fake_runner_with_child" \
    < /dev/null > "$rd_group/fake-runner.log" 2>&1 &
group_job=$!
if wait_for_file "$rd_group/pid" && wait_for_file "$rd_group/child-pid"; then
    child_pid="$(cat "$rd_group/child-pid")"
    HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_group" >/dev/null 2>&1; rc_group=$?
    check "group signal: stop exits 0" "0" "$rc_group"
    if kill -0 "$child_pid" 2>/dev/null; then
        no "group signal: the untrapped child is also dead" \
            "child pid $child_pid is still alive; only the runner's own pid was signaled"
        kill -9 "$child_pid" 2>/dev/null || true
    else
        ok "group signal: the untrapped child is also dead"
    fi
else
    no "group signal: stop exits 0" "fake runner never wrote pid/child-pid"
    no "group signal: the untrapped child is also dead" "fake runner never wrote pid/child-pid"
fi
wait "$group_job" 2>/dev/null || true

# -- leadership guard: a fake "foreground" runner whose pgid != pid (it
# and a sibling are backgrounded jobs of a setsid --fork wrapper, which
# leads the shared group itself -- the same shape a --foreground run's
# inline launch gives the real runner, inheriting its caller's group).
# stop must signal the runner's pid alone and leave the sibling alive --
# the group-signal branch would kill the sibling too.
leader_wrapper="$(mktemp /var/tmp/claude-scratch/fs-stop-leader-wrapper.XXXXXX)"
tmpdirs+=("$leader_wrapper")
cat > "$leader_wrapper" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# setsid --fork makes THIS process (the wrapper) the group leader; the
# sibling and the fake runner below are plain background jobs, so they
# inherit this group without leading it -- exactly the shape a
# --foreground run's inline launch gives the real runner.
sleep 300 &
printf '%s\n' "$!" > "$SIBLING_PID_FILE"
"$FAKE_RUNNER_SCRIPT" &
wait
EOF
chmod +x "$leader_wrapper"

# A real origin+clone, same reason as the group-signal fixture above.
leader_origin="$(new_project)"; tmpdirs+=("$leader_origin")
leader_base_sha="$(cd "$leader_origin" && git rev-parse HEAD)"
leader_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-leader-clone.XXXXXX)"
tmpdirs+=("$leader_clone")
(
    cd "$leader_origin" && git clone -q . "$leader_clone" \
        && cd "$leader_clone" && git checkout -q -b fs-stop-leader
) >/dev/null 2>&1

rd_leader="$(new_run_dir)"
cat > "$rd_leader/run.env" <<EOF
version=1
branch=fs-stop-leader
origin_repo=$leader_origin
clone_dir=$leader_clone
base_sha=$leader_base_sha
session=cc-sbx-fs-stop-leader-does-not-exist
EOF
sibling_pid_file="$(mktemp)"; tmpdirs+=("$sibling_pid_file")
RUN_DIR="$rd_leader" SIBLING_PID_FILE="$sibling_pid_file" \
    FAKE_RUNNER_SCRIPT="$fake_runner_honors_term" \
    setsid --fork "$leader_wrapper" \
    < /dev/null > "$rd_leader/fake-runner.log" 2>&1 &
leader_job=$!
if wait_for_file "$rd_leader/pid" && wait_for_file "$sibling_pid_file"; then
    sibling_pid="$(cat "$sibling_pid_file")"
    runner_pid="$(cat "$rd_leader/pid")"
    pgid_seen="$(ps -o pgid= -p "$runner_pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$pgid_seen" && "$pgid_seen" != "$runner_pid" ]]; then
        out_leader="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 15 "$rd_leader" 2>&1)"; rc_leader=$?
        check "leadership guard: stop exits 0" "0" "$rc_leader"
        contains "leadership guard: reports stopped gracefully" "stopped gracefully" "$out_leader"
        if kill -0 "$sibling_pid" 2>/dev/null; then
            ok "leadership guard: the group's other member survives"
        else
            no "leadership guard: the group's other member survives" \
                "sibling pid $sibling_pid is dead; the group was signaled, not just the runner"
        fi
    else
        no "leadership guard: stop exits 0" "runner's pgid ($pgid_seen) equalled its pid ($runner_pid); fixture did not set up pgid != pid"
        no "leadership guard: reports stopped gracefully" "fixture setup failed"
        no "leadership guard: the group's other member survives" "fixture setup failed"
    fi
    kill -9 "$sibling_pid" 2>/dev/null || true
else
    no "leadership guard: stop exits 0" "fake runner/sibling never wrote their pid files"
    no "leadership guard: reports stopped gracefully" "fake runner/sibling never wrote their pid files"
    no "leadership guard: the group's other member survives" "fake runner/sibling never wrote their pid files"
fi
wait "$leader_job" 2>/dev/null || true

# -- forced stop of the same foreground shape: the runner ignores TERM
# (forcing the violent fallback) and, like a --foreground leg's own
# direct child, backgrounds a sleep without ever getting a process group
# of its own -- it shares the wrapper's group, same as the runner itself.
# kill_other_groups will not touch that shared group (it would also take
# down the sibling, standing in for the launching shell), so the forced
# path has to reach the child individually by pid.
fake_runner_ignores_term_with_child="$(mktemp /var/tmp/claude-scratch/fs-stop-fake-runner.XXXXXX)"
tmpdirs+=("$fake_runner_ignores_term_with_child")
cat > "$fake_runner_ignores_term_with_child" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$$" > "$RUN_DIR/pid"
trap '' TERM
sleep 300 &
printf '%s\n' "$!" > "$RUN_DIR/runner-child-pid"
while :; do sleep 0.2; done
EOF
chmod +x "$fake_runner_ignores_term_with_child"

leaderforced_origin="$(new_project)"; tmpdirs+=("$leaderforced_origin")
leaderforced_base_sha="$(cd "$leaderforced_origin" && git rev-parse HEAD)"
leaderforced_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-leaderforced-clone.XXXXXX)"
tmpdirs+=("$leaderforced_clone")
(
    cd "$leaderforced_origin" && git clone -q . "$leaderforced_clone" \
        && cd "$leaderforced_clone" && git checkout -q -b fs-stop-leaderforced
) >/dev/null 2>&1

rd_leaderforced="$(new_run_dir)"
cat > "$rd_leaderforced/run.env" <<EOF
version=1
branch=fs-stop-leaderforced
origin_repo=$leaderforced_origin
clone_dir=$leaderforced_clone
base_sha=$leaderforced_base_sha
session=cc-sbx-fs-stop-leaderforced-does-not-exist
EOF
leaderforced_sibling_pid_file="$(mktemp)"; tmpdirs+=("$leaderforced_sibling_pid_file")
RUN_DIR="$rd_leaderforced" SIBLING_PID_FILE="$leaderforced_sibling_pid_file" \
    FAKE_RUNNER_SCRIPT="$fake_runner_ignores_term_with_child" \
    setsid --fork "$leader_wrapper" \
    < /dev/null > "$rd_leaderforced/fake-runner.log" 2>&1 &
leaderforced_job=$!
if wait_for_file "$rd_leaderforced/pid" && wait_for_file "$leaderforced_sibling_pid_file" \
    && wait_for_file "$rd_leaderforced/runner-child-pid"; then
    leaderforced_sibling_pid="$(cat "$leaderforced_sibling_pid_file")"
    leaderforced_runner_pid="$(cat "$rd_leaderforced/pid")"
    leaderforced_child_pid="$(cat "$rd_leaderforced/runner-child-pid")"
    leaderforced_pgid_seen="$(ps -o pgid= -p "$leaderforced_runner_pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$leaderforced_pgid_seen" && "$leaderforced_pgid_seen" != "$leaderforced_runner_pid" ]]; then
        out_leaderforced="$(HOME="$launcher_home" timeout 20 "$stop" --timeout 2 "$rd_leaderforced" 2>&1)"; rc_leaderforced=$?
        check "forced leadership: stop exits 0" "0" "$rc_leaderforced"
        contains "forced leadership: reports stop-timeout" "stop-timeout" "$out_leaderforced"
        if kill -0 "$leaderforced_sibling_pid" 2>/dev/null; then
            ok "forced leadership: the group's other member survives"
        else
            no "forced leadership: the group's other member survives" \
                "sibling pid $leaderforced_sibling_pid is dead; the forced path signaled the whole shared group"
        fi
        if kill -0 "$leaderforced_child_pid" 2>/dev/null; then
            no "forced leadership: the runner's own child in the shared group is also dead" \
                "child pid $leaderforced_child_pid is still alive after a forced stop"
        else
            ok "forced leadership: the runner's own child in the shared group is also dead"
        fi
    else
        no "forced leadership: stop exits 0" "runner's pgid ($leaderforced_pgid_seen) equalled its pid ($leaderforced_runner_pid); fixture did not set up pgid != pid"
        no "forced leadership: reports stop-timeout" "fixture setup failed"
        no "forced leadership: the group's other member survives" "fixture setup failed"
        no "forced leadership: the runner's own child in the shared group is also dead" "fixture setup failed"
    fi
    kill -9 "$leaderforced_sibling_pid" "$leaderforced_child_pid" 2>/dev/null || true
else
    no "forced leadership: stop exits 0" "fake runner/sibling/child never wrote their pid files"
    no "forced leadership: reports stop-timeout" "fake runner/sibling/child never wrote their pid files"
    no "forced leadership: the group's other member survives" "fake runner/sibling/child never wrote their pid files"
    no "forced leadership: the runner's own child in the shared group is also dead" "fake runner/sibling/child never wrote their pid files"
fi
wait "$leaderforced_job" 2>/dev/null || true

# -- exact-match tmux kill-session: run.env names a session that is a
# strict PREFIX of the only session actually alive, and does not itself
# exist. With two sessions both alive under their real, distinct names
# (the brief's literal wording), this tmux build (3.7c) already resolves
# the exact one and never reaches the ambiguous prefix path at all --
# confirmed by hand: "tmux kill-session -t cc-sbx-x" with both "cc-sbx-x"
# and "cc-sbx-x-2" alive kills only "cc-sbx-x". The prefix match tmux
# actually performs only kicks in when no session has the exact target
# name: "tmux kill-session -t cc-sbx-mybranch" against a lone session
# named "cc-sbx-mybranch-a1b2c3" DOES kill it, silently, no error -- the
# exact scenario this finding described reproducing. Model that: the
# recorded session= is stale/prefix-only, the real live session is the
# suffixed one, and only the '=' exact-match form can tell "no such
# session" apart from "kill this different one". Uses the ignores-TERM
# fake runner with a short --timeout so the FORCED path (the one that
# calls tmux kill-session) actually runs -- the graceful path never
# touches tmux.
#
# This test creates and kills real tmux sessions, so -- unlike the rest of
# this suite, which only ever names sessions that do not exist -- it must
# run on a dedicated, throwaway server (-L), never the caller's own
# default one, exactly the convention
# fork-sandbox-clone-dir-lock-lifetime-test.sh's header states and this
# suite did not previously follow here. A PATH-shimmed tmux (real tmux
# with -L inserted first) makes both this script's own tmux calls and the
# stop verb's land on that socket. Skips cleanly, not just on tmux being
# absent but also if the dedicated server itself cannot be started, so an
# environment that cannot run tmux at all is never misreported as the verb
# failing (do not silently pass either way).
if ! command -v tmux >/dev/null 2>&1; then
    printf '  SKIP  exact-match tmux kill-session: tmux not installed\n'
else
    real_tmux="$(command -v tmux)"
    tmux_socket="fs-stop-exact-$$"
    tmux_stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-stop-tmux-stub.XXXXXX)"
    tmpdirs+=("$tmux_stub_bin")
    cat > "$tmux_stub_bin/tmux" <<STUB
#!/usr/bin/env bash
exec "$real_tmux" -L "$tmux_socket" "\$@"
STUB
    chmod +x "$tmux_stub_bin/tmux"

    tmux_a="cc-sbx-fs-stop-exact"
    tmux_b="cc-sbx-fs-stop-exact-2"
    # Only the suffixed session is ever actually created; $tmux_a is a
    # prefix of it and never exists under its own exact name.
    if ! PATH="$tmux_stub_bin:$PATH" tmux new-session -d -s "$tmux_b" 'sleep 300' 2>/dev/null; then
        printf '  SKIP  exact-match tmux kill-session: could not start a dedicated tmux server\n'
        tmux_socket=""
    else
        exact_origin="$(new_project)"; tmpdirs+=("$exact_origin")
        exact_base_sha="$(cd "$exact_origin" && git rev-parse HEAD)"
        exact_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-exact-clone.XXXXXX)"
        tmpdirs+=("$exact_clone")
        (
            cd "$exact_origin" && git clone -q . "$exact_clone" \
                && cd "$exact_clone" && git checkout -q -b fs-stop-exact \
                && git config user.email t@fork-sandbox.invalid \
                && git config user.name Tester \
                && printf 'work\n' > exact-work.txt \
                && git add exact-work.txt \
                && git commit -q -m 'exact-match fixture work'
        ) >/dev/null 2>&1

        rd_exact="$(new_run_dir)"
        cat > "$rd_exact/run.env" <<EOF
version=1
branch=fs-stop-exact
origin_repo=$exact_origin
clone_dir=$exact_clone
base_sha=$exact_base_sha
session=$tmux_a
EOF
        RUN_DIR="$rd_exact" setsid --fork "$fake_runner_ignores_term" \
            < /dev/null > "$rd_exact/fake-runner.log" 2>&1 &
        exact_job=$!
        if wait_for_file "$rd_exact/pid"; then
            HOME="$launcher_home" PATH="$tmux_stub_bin:$PATH" timeout 20 "$stop" --timeout 2 "$rd_exact" \
                >/dev/null 2>&1; rc_exact=$?
            check "exact-match tmux: stop exits 0" "0" "$rc_exact"
            # $tmux_a never existed under its own exact name -- the only
            # correct outcome is that kill-session finds nothing and the
            # real, differently-named session is left untouched. A bare (no
            # '=') kill-session would prefix-match it and kill it instead.
            if PATH="$tmux_stub_bin:$PATH" tmux has-session -t "=$tmux_b" 2>/dev/null; then
                ok "exact-match tmux: the real, differently-named session survives"
            else
                no "exact-match tmux: the real, differently-named session survives" \
                    "$tmux_b was killed by a prefix match on the nonexistent '$tmux_a'"
            fi
            fake_pid_exact="$(cat "$rd_exact/pid" 2>/dev/null)"
            [[ -n "$fake_pid_exact" ]] && kill -9 "$fake_pid_exact" 2>/dev/null || true
        else
            no "exact-match tmux: stop exits 0" "fake runner never wrote a pid file"
            no "exact-match tmux: the real, differently-named session survives" "fake runner never wrote a pid file"
        fi
        wait "$exact_job" 2>/dev/null || true
        "$real_tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
        tmux_socket=""
    fi
fi

# -- branch-removal path with a real origin+clone (zero commits removed).
# Coverage-only, same caveat as above: "kept" is already proven by the
# salvage/timeout tests, but "removed" was never proven through the stop
# verb's own complete_run_host_side -- only through the RUNNER's own
# teardown, a different code path, in the first section of this file.
zero_origin="$(new_project)"; tmpdirs+=("$zero_origin")
zero_base_sha="$(cd "$zero_origin" && git rev-parse HEAD)"
zero_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-zero-clone.XXXXXX)"
tmpdirs+=("$zero_clone")
(
    cd "$zero_origin" && git clone -q . "$zero_clone" \
        && cd "$zero_clone" && git checkout -q -b fs-stop-zero
) >/dev/null 2>&1
rd_zero="$(new_run_dir)"
cat > "$rd_zero/run.env" <<EOF
version=1
branch=fs-stop-zero
origin_repo=$zero_origin
clone_dir=$zero_clone
base_sha=$zero_base_sha
session=cc-sbx-fs-stop-zero-does-not-exist
EOF
( : ) & dead_pid_zero=$!
wait "$dead_pid_zero" 2>/dev/null || true
printf '%s\n' "$dead_pid_zero" > "$rd_zero/pid"
out_zero="$(HOME="$launcher_home" "$stop" "$rd_zero" 2>&1)"; rc_zero=$?
check "zero commits: stop exits 0" "0" "$rc_zero"
contains "zero commits: reports 0 new commits" "0 new commit" "$out_zero"
check "zero commits: branch removed" \
    "0" "$(cd "$zero_origin" && git show-ref --quiet refs/heads/fs-stop-zero && echo 1 || echo 0)"

# -- --checkout base: return_base_sha != base_sha (proves 3.3). base_sha
# is left behind at an older commit while return_base_sha (and the
# fixture branch) sit at a newer one, with nothing added past it. Reading
# base_sha (the bug) would count one commit and keep the branch; reading
# return_base_sha (the fix) sees zero and removes it.
checkout_origin="$(new_project)"; tmpdirs+=("$checkout_origin")
checkout_base_sha="$(cd "$checkout_origin" && git rev-parse HEAD)"
# Advance the origin by one more commit -- simulates history that landed
# between the merge-base (base_sha) and the ref this run actually checked
# out (return_base_sha). base_sha stays behind at the old commit; the
# fixture's branch will sit at the NEW one with nothing further added.
(
    cd "$checkout_origin" && printf 'more\n' > more.txt \
        && git add more.txt && git commit -q -m 'advance past base_sha'
) >/dev/null 2>&1
checkout_return_base_sha="$(cd "$checkout_origin" && git rev-parse HEAD)"

checkout_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-checkout-clone.XXXXXX)"
tmpdirs+=("$checkout_clone")
(
    cd "$checkout_origin" && git clone -q . "$checkout_clone" \
        && cd "$checkout_clone" && git checkout -q -b fs-stop-checkout-base
) >/dev/null 2>&1

rd_checkout="$(new_run_dir)"
cat > "$rd_checkout/run.env" <<EOF
version=1
branch=fs-stop-checkout-base
origin_repo=$checkout_origin
clone_dir=$checkout_clone
base_sha=$checkout_base_sha
return_base_sha=$checkout_return_base_sha
session=cc-sbx-fs-stop-checkout-does-not-exist
EOF
( : ) & dead_pid_checkout=$!
wait "$dead_pid_checkout" 2>/dev/null || true
printf '%s\n' "$dead_pid_checkout" > "$rd_checkout/pid"
out_checkout="$(HOME="$launcher_home" "$stop" "$rd_checkout" 2>&1)"; rc_checkout=$?
check "checkout-base: stop exits 0" "0" "$rc_checkout"
contains "checkout-base: reports 0 new commits from return_base_sha" "0 new commit" "$out_checkout"
check "checkout-base: branch removed (zero commits past return_base_sha)" \
    "0" "$(cd "$checkout_origin" && git show-ref --quiet refs/heads/fs-stop-checkout-base && echo 1 || echo 0)"

# -- forced stop while the tidy leg is still mid-flight (stub harness).
# The runner snapshots the approved head into a holding ref BEFORE
# launching the leg (fork-sandbox.sh's own fetch into
# refs/fork-sandbox/tidy/<run-id>/approved, keyed by this run's own run
# dir, read back here the same way); dying before the leg ever finishes,
# the same dead-pid salvage shape "failed fetch"/"zero commits" below
# use, leaves no tidy.json behind at all. The clone's branch holds
# whatever the still-running leg had committed so far -- unverified, never
# approved -- which must never reach the origin; only the snapshot may.
midflight_origin="$(new_project)"; tmpdirs+=("$midflight_origin")
midflight_base_sha="$(cd "$midflight_origin" && git rev-parse HEAD)"
midflight_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-midflight-clone.XXXXXX)"
tmpdirs+=("$midflight_clone")
(
    cd "$midflight_origin" && git clone -q . "$midflight_clone" \
        && cd "$midflight_clone" && git checkout -q -b fs-stop-midflight \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
midflight_approved_sha="$(cd "$midflight_clone" && git rev-parse fs-stop-midflight)"
rd_midflight="$(new_run_dir)"
midflight_run_id="$(basename "$rd_midflight")"
(cd "$midflight_origin" && git fetch -q "$midflight_clone" \
    "+refs/heads/fs-stop-midflight:refs/fork-sandbox/tidy/$midflight_run_id/approved")
(
    cd "$midflight_clone" \
        && git commit -q --allow-empty -m 'unverified work-in-progress from a still-running tidy leg'
) >/dev/null 2>&1
cat > "$rd_midflight/run.env" <<EOF
version=1
branch=fs-stop-midflight
origin_repo=$midflight_origin
clone_dir=$midflight_clone
base_sha=$midflight_base_sha
session=cc-sbx-fs-stop-midflight-does-not-exist
EOF
( : ) & dead_pid_midflight=$!
wait "$dead_pid_midflight" 2>/dev/null || true
printf '%s\n' "$dead_pid_midflight" > "$rd_midflight/pid"
out_midflight="$(HOME="$launcher_home" "$stop" "$rd_midflight" 2>&1)"; rc_midflight=$?
check "mid-flight tidy leg: stop exits 0" "0" "$rc_midflight"
check "mid-flight tidy leg: the published branch is the approved head, not the clone's WIP" \
    "$midflight_approved_sha" "$(cd "$midflight_origin" && git rev-parse fs-stop-midflight 2>/dev/null)"
contains "mid-flight tidy leg: says it published the approved history, not the clone" \
    "published the maintainer-approved history" "$out_midflight"
check "mid-flight tidy leg: the holding ref is cleaned up after a successful publish" \
    "" "$(cd "$midflight_origin" && git for-each-ref "refs/fork-sandbox/tidy/$midflight_run_id")"

# -- the same mid-flight scenario, but the publish itself loses a
# collision -- the ONE case that still has a live holding ref to name
# (tidy.json never got written), so this is the one path that can prove
# the recovery message names the ref, not just the sha.
midflight2_origin="$(new_project)"; tmpdirs+=("$midflight2_origin")
midflight2_base_sha="$(cd "$midflight2_origin" && git rev-parse HEAD)"
midflight2_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-midflight2-clone.XXXXXX)"
tmpdirs+=("$midflight2_clone")
(
    cd "$midflight2_origin" && git clone -q . "$midflight2_clone" \
        && cd "$midflight2_clone" && git checkout -q -b fs-stop-midflight2 \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
midflight2_approved_sha="$(cd "$midflight2_clone" && git rev-parse fs-stop-midflight2)"
rd_midflight2="$(new_run_dir)"
midflight2_run_id="$(basename "$rd_midflight2")"
(cd "$midflight2_origin" && git fetch -q "$midflight2_clone" \
    "+refs/heads/fs-stop-midflight2:refs/fork-sandbox/tidy/$midflight2_run_id/approved")
(
    cd "$midflight2_origin" && git checkout -q -b fs-stop-midflight2 \
        && printf "someone else's work\n" > other.txt \
        && git add other.txt && git commit -q -m 'an unrelated commit' \
        && git checkout -q -
) >/dev/null 2>&1
cat > "$rd_midflight2/run.env" <<EOF
version=1
branch=fs-stop-midflight2
origin_repo=$midflight2_origin
clone_dir=$midflight2_clone
base_sha=$midflight2_base_sha
session=cc-sbx-fs-stop-midflight2-does-not-exist
EOF
( : ) & dead_pid_midflight2=$!
wait "$dead_pid_midflight2" 2>/dev/null || true
printf '%s\n' "$dead_pid_midflight2" > "$rd_midflight2/pid"
out_midflight2="$(HOME="$launcher_home" "$stop" "$rd_midflight2" 2>&1)"; rc_midflight2=$?
if (( rc_midflight2 != 0 )); then
    ok "mid-flight collision: stop reports non-zero exit"
else
    no "mid-flight collision: stop reports non-zero exit" "exited 0: $out_midflight2"
fi
not_contains "mid-flight collision: never suggests fetching the clone" \
    "git fetch $midflight2_clone" "$out_midflight2"
contains "mid-flight collision: names the still-live holding ref" \
    "refs/fork-sandbox/tidy/$midflight2_run_id/approved" "$out_midflight2"
contains "mid-flight collision: names the by-hand recovery command against the approved sha" \
    "git update-ref refs/heads/fs-stop-midflight2 $midflight2_approved_sha" "$out_midflight2"
check "mid-flight collision: the holding ref survives, not deleted" \
    "$midflight2_approved_sha" \
    "$(cd "$midflight2_origin" && git rev-parse -q --verify "refs/fork-sandbox/tidy/$midflight2_run_id/approved" 2>/dev/null)"

# -- a live holding ref belonging to a DIFFERENT run (its own run id, not
# this run's) that happens to share this run's branch name must never be
# trusted as this run's own in-flight snapshot: refs are keyed by run id
# precisely so two runs can share a branch name without either reading
# or clearing the other's refs, and nothing here needs a gate on whether
# THIS run's own pipeline could ever have made one -- no other run could
# ever create a ref under this exact id. This run has no maintain step
# at all and no tidy.json, the exact tidy.json-less shape
# resolve_tidy_safe_sha's live-ref lookup reads -- reproduced with a dead
# pid and no exit-code, same as the real report.
otherrun_origin="$(new_project)"; tmpdirs+=("$otherrun_origin")
otherrun_base_sha="$(cd "$otherrun_origin" && git rev-parse HEAD)"
otherrun_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-otherrun-clone.XXXXXX)"
tmpdirs+=("$otherrun_clone")
(
    cd "$otherrun_origin" && git clone -q . "$otherrun_clone" \
        && cd "$otherrun_clone" && git checkout -q -b fs-stop-otherrun \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'other run work\n' > other.txt \
        && git add other.txt \
        && git commit -q -m 'other run: approved work'
) >/dev/null 2>&1
otherrun_prior_sha="$(cd "$otherrun_clone" && git rev-parse fs-stop-otherrun)"
# A DIFFERENT run's own holding ref, under ITS OWN run id -- modeling a
# run that lost a publish collision and left this ref behind for later
# recovery (nothing here or in the real runner deletes it on its own).
rd_otherrun_prior="$(new_run_dir)"; tmpdirs+=("$rd_otherrun_prior")
otherrun_prior_run_id="$(basename "$rd_otherrun_prior")"
(cd "$otherrun_origin" && git fetch -q "$otherrun_clone" \
    "+refs/heads/fs-stop-otherrun:refs/fork-sandbox/tidy/$otherrun_prior_run_id/approved")
(cd "$otherrun_origin" && git branch -q -D fs-stop-otherrun 2>/dev/null) || true
# THIS run reuses the now-free branch name, commits its own work in the
# clone, and (no maintain step) never touches any holding ref at all.
(
    cd "$otherrun_clone" \
        && git commit -q --allow-empty -m 'this run: new work, no maintain step'
) >/dev/null 2>&1
otherrun_new_sha="$(cd "$otherrun_clone" && git rev-parse fs-stop-otherrun)"
rd_otherrun="$(new_run_dir)"
cat > "$rd_otherrun/run.env" <<EOF
version=1
branch=fs-stop-otherrun
origin_repo=$otherrun_origin
clone_dir=$otherrun_clone
base_sha=$otherrun_base_sha
session=cc-sbx-fs-stop-otherrun-does-not-exist
EOF
( : ) & dead_pid_otherrun=$!
wait "$dead_pid_otherrun" 2>/dev/null || true
printf '%s\n' "$dead_pid_otherrun" > "$rd_otherrun/pid"
out_otherrun="$(HOME="$launcher_home" "$stop" "$rd_otherrun" 2>&1)"; rc_otherrun=$?
check "other run's holding ref, no maintain step: stop exits 0" "0" "$rc_otherrun"
check "other run's holding ref, no maintain step: publishes the clone's own work, not the other run's sha" \
    "$otherrun_new_sha" "$(cd "$otherrun_origin" && git rev-parse fs-stop-otherrun 2>/dev/null)"
if [[ "$(cd "$otherrun_origin" && git rev-parse fs-stop-otherrun 2>/dev/null)" != "$otherrun_prior_sha" ]]; then
    ok "other run's holding ref, no maintain step: the other run's sha is not what landed"
else
    no "other run's holding ref, no maintain step: the other run's sha is not what landed" \
        "the origin branch is at the OTHER run's sha"
fi
not_contains "other run's holding ref, no maintain step: never claims to have published the maintainer-approved history" \
    "published the maintainer-approved history" "$out_otherrun"
check "other run's holding ref, no maintain step: the other run's ref survives untouched" \
    "$otherrun_prior_sha" \
    "$(cd "$otherrun_origin" && git rev-parse -q --verify "refs/fork-sandbox/tidy/$otherrun_prior_run_id/approved" 2>/dev/null)"

# -- forced stop after a discard whose own clone reset failed (stub
# harness). The runner recorded the discard in tidy.json (head_approved,
# clone_restored: false) before dying -- its own fetch-back into the
# origin never ran. The clone's branch still holds the REJECTED rewrite;
# only head_approved may ever reach the origin.
discard_origin="$(new_project)"; tmpdirs+=("$discard_origin")
discard_base_sha="$(cd "$discard_origin" && git rev-parse HEAD)"
discard_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-discard-clone.XXXXXX)"
tmpdirs+=("$discard_clone")
(
    cd "$discard_origin" && git clone -q . "$discard_clone" \
        && cd "$discard_clone" && git checkout -q -b fs-stop-discard \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
discard_approved_sha="$(cd "$discard_clone" && git rev-parse fs-stop-discard)"
rd_discard="$(new_run_dir)"
discard_run_id="$(basename "$rd_discard")"
# The runner's own pre-leg snapshot: the approved object has to actually
# be in the origin repo's ODB for a by-sha publish to work at all, same as
# the mid-flight fixture's explicit fetch above.
(cd "$discard_origin" && git fetch -q "$discard_clone" \
    "+refs/heads/fs-stop-discard:refs/fork-sandbox/tidy/$discard_run_id/approved")
(
    cd "$discard_clone" && git reset -q --soft "$discard_base_sha" \
        && printf 'an edit the tidy leg should never have made\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'rejected rewrite, still sitting in the clone'
) >/dev/null 2>&1
cat > "$rd_discard/run.env" <<EOF
version=1
branch=fs-stop-discard
origin_repo=$discard_origin
clone_dir=$discard_clone
base_sha=$discard_base_sha
session=cc-sbx-fs-stop-discard-does-not-exist
EOF
jq -n --arg head_approved "$discard_approved_sha" '{
    ended: "discarded", detail: "the tree differs; the approved history was restored",
    head_approved: $head_approved, head_after: null, exit: 1, cost_usd: null,
    usage: null, retries: [], clone_restored: false
}' > "$rd_discard/tidy.json"
( : ) & dead_pid_discard=$!
wait "$dead_pid_discard" 2>/dev/null || true
printf '%s\n' "$dead_pid_discard" > "$rd_discard/pid"
out_discard="$(HOME="$launcher_home" "$stop" "$rd_discard" 2>&1)"; rc_discard=$?
check "discard with failed clone reset: stop exits 0" "0" "$rc_discard"
check "discard with failed clone reset: the published branch is head_approved, not the clone's rejected rewrite" \
    "$discard_approved_sha" "$(cd "$discard_origin" && git rev-parse fs-stop-discard 2>/dev/null)"
contains "discard with failed clone reset: says it published the approved history, not the clone" \
    "published the maintainer-approved history" "$out_discard"

# -- the tidy-safe publish can itself lose a collision (an operator or
# another run claimed the branch name while this one was down) -- the
# recovery command printed must still never suggest fetching the clone,
# which here holds the SAME rejected rewrite as the fixture above.
collide_origin="$(new_project)"; tmpdirs+=("$collide_origin")
collide_base_sha="$(cd "$collide_origin" && git rev-parse HEAD)"
collide_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-collide-clone.XXXXXX)"
tmpdirs+=("$collide_clone")
(
    cd "$collide_origin" && git clone -q . "$collide_clone" \
        && cd "$collide_clone" && git checkout -q -b fs-stop-collide \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
collide_approved_sha="$(cd "$collide_clone" && git rev-parse fs-stop-collide)"
rd_collide="$(new_run_dir)"
collide_run_id="$(basename "$rd_collide")"
(cd "$collide_origin" && git fetch -q "$collide_clone" \
    "+refs/heads/fs-stop-collide:refs/fork-sandbox/tidy/$collide_run_id/approved")
(
    cd "$collide_clone" && git reset -q --soft "$collide_base_sha" \
        && printf 'rejected\n' > work.txt && git add work.txt \
        && git commit -q -m 'rejected rewrite'
) >/dev/null 2>&1
(
    cd "$collide_origin" && git checkout -q -b fs-stop-collide \
        && printf "someone else's work\n" > other.txt \
        && git add other.txt && git commit -q -m 'an unrelated commit' \
        && git checkout -q -
) >/dev/null 2>&1
cat > "$rd_collide/run.env" <<EOF
version=1
branch=fs-stop-collide
origin_repo=$collide_origin
clone_dir=$collide_clone
base_sha=$collide_base_sha
session=cc-sbx-fs-stop-collide-does-not-exist
EOF
jq -n --arg head_approved "$collide_approved_sha" '{
    ended: "discarded", detail: "the tree differs; the approved history was restored",
    head_approved: $head_approved, head_after: null, exit: 1, cost_usd: null,
    usage: null, retries: [], clone_restored: false
}' > "$rd_collide/tidy.json"
( : ) & dead_pid_collide=$!
wait "$dead_pid_collide" 2>/dev/null || true
printf '%s\n' "$dead_pid_collide" > "$rd_collide/pid"
out_collide="$(HOME="$launcher_home" "$stop" "$rd_collide" 2>&1)"; rc_collide=$?
if (( rc_collide != 0 )); then
    ok "tidy-safe collision: stop reports non-zero exit"
else
    no "tidy-safe collision: stop reports non-zero exit" "exited 0: $out_collide"
fi
not_contains "tidy-safe collision: never suggests fetching the clone" \
    "git fetch $collide_clone" "$out_collide"
contains "tidy-safe collision: names the by-hand recovery command against the approved sha" \
    "git update-ref refs/heads/fs-stop-collide $collide_approved_sha" "$out_collide"
check "tidy-safe collision: the colliding commit in the origin is untouched" \
    "an unrelated commit" "$(cd "$collide_origin" && git log -1 --format=%s fs-stop-collide)"

# -- failed fetch is reported as a failure, not a clean "0 new commits"
# (proves 3.5). clone_dir is a plain empty directory, not a git repo at
# all, so the fetch fails cleanly without needing to fabricate corruption.
fail_origin="$(new_project)"; tmpdirs+=("$fail_origin")
fail_base_sha="$(cd "$fail_origin" && git rev-parse HEAD)"
fail_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-failclone.XXXXXX)"
tmpdirs+=("$fail_clone")
rd_fail="$(new_run_dir)"
cat > "$rd_fail/run.env" <<EOF
version=1
branch=fs-stop-failfetch
origin_repo=$fail_origin
clone_dir=$fail_clone
base_sha=$fail_base_sha
session=cc-sbx-fs-stop-failfetch-does-not-exist
EOF
( : ) & dead_pid_fail=$!
wait "$dead_pid_fail" 2>/dev/null || true
printf '%s\n' "$dead_pid_fail" > "$rd_fail/pid"
out_fail="$(HOME="$launcher_home" "$stop" "$rd_fail" 2>&1)"; rc_fail=$?
if (( rc_fail != 0 )); then
    ok "failed fetch: stop reports non-zero exit"
else
    no "failed fetch: stop reports non-zero exit" "exited 0: $out_fail"
fi
not_contains "failed fetch: does not claim 0 new commits" "0 new commit" "$out_fail"
contains "failed fetch: names the clone as the rescue path" "$fail_clone" "$out_fail"

# -- exit-code already exists, but the runner never reached its own
# publish: fork-sandbox.sh writes exit-code (its teardown) strictly before
# its tidy-aware fetch-back runs, and strictly before summary.json, which
# it writes only after that fetch-back lands. A fixture with exit-code but
# no summary.json is exactly the window a kill -9/OOM/host-reboot between
# those two writes would leave behind. Entry state 1 used to trust
# exit-code alone and declare "nothing to stop" here, silently leaving the
# tidy leg's verified rewrite unpublished with no recovery hint -- this
# proves the fix confirms (and if needed completes) the publish instead.
unconfirmed_origin="$(new_project)"; tmpdirs+=("$unconfirmed_origin")
unconfirmed_base_sha="$(cd "$unconfirmed_origin" && git rev-parse HEAD)"
unconfirmed_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-unconfirmed-clone.XXXXXX)"
tmpdirs+=("$unconfirmed_clone")
(
    cd "$unconfirmed_origin" && git clone -q . "$unconfirmed_clone" \
        && cd "$unconfirmed_clone" && git checkout -q -b fs-stop-unconfirmed \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
unconfirmed_approved_sha="$(cd "$unconfirmed_clone" && git rev-parse fs-stop-unconfirmed)"
unconfirmed_candidate_sha="$(
    cd "$unconfirmed_clone" && git commit-tree "fs-stop-unconfirmed^{tree}" \
        -p "$unconfirmed_approved_sha" -m 'tidied: approved work'
)"
# refs/heads/fs-stop-unconfirmed is never created in the origin repo at
# all -- fs_check_branch_free only proves it free at launch, and nothing
# creates it in the real flow until the runner's own create-only publish
# (fork-sandbox.sh's tidy block uses the same empty-old-value update-ref
# fetch_branch_back does), so this fixture's whole point is that publish
# never happened. Both holding refs, though, are already in the origin
# repo under this run's own id -- fetched in by the runner's own pre-leg
# and post-leg snapshots, same as the real tidy block creates both before
# fs_tidy_verify ever runs, well before exit-code is written.
rd_unconfirmed="$(new_run_dir)"
unconfirmed_run_id="$(basename "$rd_unconfirmed")"
(cd "$unconfirmed_origin" && git fetch -q "$unconfirmed_clone" \
    "+refs/heads/fs-stop-unconfirmed:refs/fork-sandbox/tidy/$unconfirmed_run_id/approved")
(
    cd "$unconfirmed_clone" \
        && git update-ref refs/fs-stop-unconfirmed-candidate-scratch "$unconfirmed_candidate_sha"
)
(cd "$unconfirmed_origin" && git fetch -q "$unconfirmed_clone" \
    "+refs/fs-stop-unconfirmed-candidate-scratch:refs/fork-sandbox/tidy/$unconfirmed_run_id/candidate")
(cd "$unconfirmed_clone" && git update-ref -d refs/fs-stop-unconfirmed-candidate-scratch) >/dev/null 2>&1
cat > "$rd_unconfirmed/run.env" <<EOF
version=1
branch=fs-stop-unconfirmed
origin_repo=$unconfirmed_origin
clone_dir=$unconfirmed_clone
base_sha=$unconfirmed_base_sha
session=cc-sbx-fs-stop-unconfirmed-does-not-exist
EOF
printf '0\n' > "$rd_unconfirmed/exit-code"
jq -n --arg head_approved "$unconfirmed_approved_sha" \
    --arg head_after "$unconfirmed_candidate_sha" '{
    ended: "accepted", detail: null,
    head_approved: $head_approved, head_after: $head_after, exit: 0, cost_usd: null,
    usage: null, retries: [], clone_restored: null
}' > "$rd_unconfirmed/tidy.json"
out_unconfirmed="$(HOME="$launcher_home" "$stop" "$rd_unconfirmed" 2>&1)"; rc_unconfirmed=$?
check "unconfirmed publish: stop exits 0" "0" "$rc_unconfirmed"
check "unconfirmed publish: the branch is moved to the verified candidate, not left at approved" \
    "$unconfirmed_candidate_sha" "$(cd "$unconfirmed_origin" && git rev-parse fs-stop-unconfirmed 2>/dev/null)"
contains "unconfirmed publish: says it published, not that there was nothing to stop" \
    "published" "$out_unconfirmed"
check "unconfirmed publish: the holding refs are cleaned up after the publish lands" \
    "" "$(cd "$unconfirmed_origin" && git for-each-ref "refs/fork-sandbox/tidy/$unconfirmed_run_id")"

# -- the same unconfirmed-publish window, but the publish itself loses a
# collision: something else already moved the branch, so stop must report
# failure and a by-hand recovery command rather than silently exit 0.
collide2_origin="$(new_project)"; tmpdirs+=("$collide2_origin")
collide2_base_sha="$(cd "$collide2_origin" && git rev-parse HEAD)"
collide2_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-unconfirmed-collide-clone.XXXXXX)"
tmpdirs+=("$collide2_clone")
(
    cd "$collide2_origin" && git clone -q . "$collide2_clone" \
        && cd "$collide2_clone" && git checkout -q -b fs-stop-unconfirmed-collide \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
collide2_approved_sha="$(cd "$collide2_clone" && git rev-parse fs-stop-unconfirmed-collide)"
collide2_candidate_sha="$(
    cd "$collide2_clone" && git commit-tree "fs-stop-unconfirmed-collide^{tree}" \
        -p "$collide2_approved_sha" -m 'tidied: approved work'
)"
(
    cd "$collide2_origin" && git fetch -q "$collide2_clone" \
        "+refs/heads/fs-stop-unconfirmed-collide:refs/heads/fs-stop-unconfirmed-collide" \
        && git checkout -q fs-stop-unconfirmed-collide \
        && git commit -q --allow-empty -m 'an unrelated commit' \
        && git checkout -q -
) >/dev/null 2>&1
# Both holding refs, keyed by this run's own id -- same reasoning as the
# unconfirmed-publish fixture above -- so the collision below is the one
# and only reason the publish fails, not a missing object or a missing ref.
rd_collide2="$(new_run_dir)"
collide2_run_id="$(basename "$rd_collide2")"
(cd "$collide2_origin" && git fetch -q "$collide2_clone" \
    "+refs/heads/fs-stop-unconfirmed-collide:refs/fork-sandbox/tidy/$collide2_run_id/approved")
(
    cd "$collide2_clone" \
        && git update-ref refs/fs-stop-unconfirmed-collide-candidate-scratch "$collide2_candidate_sha"
)
(cd "$collide2_origin" && git fetch -q "$collide2_clone" \
    "+refs/fs-stop-unconfirmed-collide-candidate-scratch:refs/fork-sandbox/tidy/$collide2_run_id/candidate")
(cd "$collide2_clone" && git update-ref -d refs/fs-stop-unconfirmed-collide-candidate-scratch) >/dev/null 2>&1
collide2_unrelated_sha="$(cd "$collide2_origin" && git rev-parse fs-stop-unconfirmed-collide)"
cat > "$rd_collide2/run.env" <<EOF
version=1
branch=fs-stop-unconfirmed-collide
origin_repo=$collide2_origin
clone_dir=$collide2_clone
base_sha=$collide2_base_sha
session=cc-sbx-fs-stop-unconfirmed-collide-does-not-exist
EOF
printf '0\n' > "$rd_collide2/exit-code"
jq -n --arg head_approved "$collide2_approved_sha" \
    --arg head_after "$collide2_candidate_sha" '{
    ended: "accepted", detail: null,
    head_approved: $head_approved, head_after: $head_after, exit: 0, cost_usd: null,
    usage: null, retries: [], clone_restored: null
}' > "$rd_collide2/tidy.json"
out_collide2="$(HOME="$launcher_home" "$stop" "$rd_collide2" 2>&1)"; rc_collide2=$?
if (( rc_collide2 != 0 )); then
    ok "unconfirmed publish, collision: stop reports non-zero exit"
else
    no "unconfirmed publish, collision: stop reports non-zero exit" "exited 0: $out_collide2"
fi
not_contains "unconfirmed publish, collision: never suggests fetching the clone" \
    "git fetch" "$out_collide2"
contains "unconfirmed publish, collision: names the by-hand recovery command against the candidate sha" \
    "git update-ref refs/heads/fs-stop-unconfirmed-collide $collide2_candidate_sha" "$out_collide2"
check "unconfirmed publish, collision: the colliding commit in the origin is untouched" \
    "$collide2_unrelated_sha" "$(cd "$collide2_origin" && git rev-parse fs-stop-unconfirmed-collide)"
check "unconfirmed publish, collision: the candidate holding ref survives, not deleted" \
    "$collide2_candidate_sha" \
    "$(cd "$collide2_origin" && git rev-parse -q --verify "refs/fork-sandbox/tidy/$collide2_run_id/candidate" 2>/dev/null)"

# -- once this run's own tidy publish has already landed (both holding
# refs gone, the one signal that means so -- see resolve_tidy_safe_sha's
# own header), stop must treat the "already ended" check as a pure no-op,
# never re-create a branch the integrator deleted on purpose and never
# report a collision because they moved it. tidy.json still carries
# head_approved/head_after (that never changes once written), and
# exit-code exists with no summary.json -- the same crash/jq-failure
# window the unconfirmed-publish fixtures above model -- but here the
# publish already succeeded before that window opened.
published_origin="$(new_project)"; tmpdirs+=("$published_origin")
published_base_sha="$(cd "$published_origin" && git rev-parse HEAD)"
published_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-published-clone.XXXXXX)"
tmpdirs+=("$published_clone")
(
    cd "$published_origin" && git clone -q . "$published_clone" \
        && cd "$published_clone" && git checkout -q -b fs-stop-published \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'approved work\n' > work.txt \
        && git add work.txt \
        && git commit -q -m 'approved work'
) >/dev/null 2>&1
published_approved_sha="$(cd "$published_clone" && git rev-parse fs-stop-published)"
published_candidate_sha="$(
    cd "$published_clone" && git commit-tree "fs-stop-published^{tree}" \
        -p "$published_approved_sha" -m 'tidied: approved work'
)"
# commit-tree leaves the candidate dangling in the clone (no ref points at
# it) -- fetching refs/heads/fs-stop-published would only bring over the
# approved commit it names, not the candidate. Name it with a scratch ref
# in the clone first, same as the unconfirmed-publish fixtures above, then
# fetch that.
(cd "$published_clone" \
    && git update-ref refs/fs-stop-published-candidate-scratch "$published_candidate_sha")
(cd "$published_origin" && git fetch -q "$published_clone" \
    "+refs/fs-stop-published-candidate-scratch:refs/fs-stop-published-candidate-scratch")
(cd "$published_clone" && git update-ref -d refs/fs-stop-published-candidate-scratch) >/dev/null 2>&1
# The runner's own successful publish, already landed -- create-only,
# same as fs_tidy_publish -- with NO run-id holding refs left behind
# (the runner deletes both only once fetched=1, which this models).
published_setup_ok=0
if (cd "$published_origin" \
    && git update-ref refs/heads/fs-stop-published "$published_candidate_sha" "" \
    && git update-ref -d refs/fs-stop-published-candidate-scratch); then
    published_setup_ok=1
fi
rd_published="$(new_run_dir)"
cat > "$rd_published/run.env" <<EOF
version=1
branch=fs-stop-published
origin_repo=$published_origin
clone_dir=$published_clone
base_sha=$published_base_sha
session=cc-sbx-fs-stop-published-does-not-exist
EOF
printf '0\n' > "$rd_published/exit-code"
jq -n --arg head_approved "$published_approved_sha" \
    --arg head_after "$published_candidate_sha" '{
    ended: "accepted", detail: null,
    head_approved: $head_approved, head_after: $head_after, exit: 0, cost_usd: null,
    usage: null, retries: [], clone_restored: null
}' > "$rd_published/tidy.json"
# The integrator deleted the branch after the publish landed -- ordinary
# post-run cleanup, not this verb's business to undo.
(cd "$published_origin" && git branch -q -D fs-stop-published) >/dev/null 2>&1
if (( published_setup_ok )); then
    out_published="$(HOME="$launcher_home" "$stop" "$rd_published" 2>&1)"; rc_published=$?
    check "already published, integrator deleted it: stop exits 0" "0" "$rc_published"
    contains "already published, integrator deleted it: reports nothing to stop" \
        "nothing to stop" "$out_published"
    check "already published, integrator deleted it: branch stays deleted, not recreated" \
        "0" "$(cd "$published_origin" && git show-ref --quiet refs/heads/fs-stop-published && echo 1 || echo 0)"
else
    no "already published, integrator deleted it: stop exits 0" "fixture setup failed"
    no "already published, integrator deleted it: reports nothing to stop" "fixture setup failed"
    no "already published, integrator deleted it: branch stays deleted, not recreated" "fixture setup failed"
fi

# -- the same already-published run, but the integrator MOVED the branch
# instead of deleting it: stop must not report a collision, and must
# leave the integrator's own commit alone.
rd_published2="$(new_run_dir)"
cat > "$rd_published2/run.env" <<EOF
version=1
branch=fs-stop-published
origin_repo=$published_origin
clone_dir=$published_clone
base_sha=$published_base_sha
session=cc-sbx-fs-stop-published2-does-not-exist
EOF
printf '0\n' > "$rd_published2/exit-code"
jq -n --arg head_approved "$published_approved_sha" \
    --arg head_after "$published_candidate_sha" '{
    ended: "accepted", detail: null,
    head_approved: $head_approved, head_after: $head_after, exit: 0, cost_usd: null,
    usage: null, retries: [], clone_restored: null
}' > "$rd_published2/tidy.json"
published2_setup_ok=0
if (
    cd "$published_origin" && git update-ref refs/heads/fs-stop-published "$published_candidate_sha" "" \
        && git checkout -q fs-stop-published \
        && git commit -q --allow-empty -m 'the integrator amended this after the publish' \
        && git checkout -q -
) >/dev/null 2>&1; then
    published2_setup_ok=1
fi
if (( published2_setup_ok )); then
    published_moved_sha="$(cd "$published_origin" && git rev-parse fs-stop-published)"
    out_published2="$(HOME="$launcher_home" "$stop" "$rd_published2" 2>&1)"; rc_published2=$?
    check "already published, integrator moved it: stop exits 0" "0" "$rc_published2"
    contains "already published, integrator moved it: reports nothing to stop" \
        "nothing to stop" "$out_published2"
    not_contains "already published, integrator moved it: never claims a collision" \
        "different history" "$out_published2"
    check "already published, integrator moved it: the integrator's own commit is untouched" \
        "$published_moved_sha" "$(cd "$published_origin" && git rev-parse fs-stop-published)"
else
    no "already published, integrator moved it: stop exits 0" "fixture setup failed"
    no "already published, integrator moved it: reports nothing to stop" "fixture setup failed"
    no "already published, integrator moved it: never claims a collision" "fixture setup failed"
    no "already published, integrator moved it: the integrator's own commit is untouched" "fixture setup failed"
fi

# -- the real launcher, the real fork-sandbox-stop.sh, a run.env and
# run.sh fork-sandbox.sh itself generated (not hand-built), stopped while
# the tidy leg is actually running. Every other fixture in this file
# hand-builds run.env/run.sh, which cannot exercise anything the launcher
# itself writes into them. The maintain leg commits once and approves;
# the tidy leg's own stub rewrites the clone once more -- its own
# "approved" snapshot, taken just before, is what a correct stop must
# publish instead -- then sleeps far longer than this test waits, tagged
# with a sleep duration unique to this process tree so it can be told
# apart from any other sleep on the machine.
midtidy_stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-stop-midtidy-stub.XXXXXX)"
tmpdirs+=("$midtidy_stub_bin")
midtidy_hang_seconds=619
cat > "$midtidy_stub_bin/claude-sandboxed" <<STUB
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "\$@"; do
    [[ "\$a" == "--dangerously-skip-permissions" ]] && clone_dir="\$prev"
    prev="\$a"
done
prompt="\$(cat)"
n=0
[[ -f "\$FAKE_MIDTIDY_COUNT_FILE" ]] && n="\$(cat "\$FAKE_MIDTIDY_COUNT_FILE")"
n=\$(( n + 1 ))
printf '%s' "\$n" > "\$FAKE_MIDTIDY_COUNT_FILE"
if (( n == 1 )); then
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \\
        -C "\$clone_dir" commit --allow-empty -q -m "stub leg \$n"
elif (( n == 2 )); then
    verdict_name="\$(printf '%s\\n' "\$prompt" \\
        | sed -nE 's#.*\\.git/(maintainer-verdict\\.md)#\\1#p' | head -1)"
    [[ -n "\$verdict_name" ]] || verdict_name=maintainer-verdict.md
    printf 'APPROVED\\n\\nChecked: everything.\\n' > "\$clone_dir/.git/\$verdict_name"
else
    # Snapshot the approved head before rewriting it, so the test can
    # tell "stop published the approved history" apart from "stop
    # published whatever this leg left in the clone" -- a plain clone
    # fetch and the tidy-safe publish would otherwise land on the exact
    # same sha, since nothing used to change the clone here at all.
    git -C "\$clone_dir" rev-parse HEAD > "\$FAKE_MIDTIDY_APPROVED_FILE"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \\
        -C "\$clone_dir" commit --allow-empty -q -m "tidy leg's in-progress rewrite"
    sleep $midtidy_hang_seconds
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$midtidy_stub_bin/claude-sandboxed"

midtidy_count_file="$(mktemp)"; tmpdirs+=("$midtidy_count_file")
midtidy_approved_file="$(mktemp)"; tmpdirs+=("$midtidy_approved_file")
midtidy_out="$(mktemp)"; tmpdirs+=("$midtidy_out")
midtidy_branch="sandbox-test-stop-midtidy-$$"
HOME="$launcher_home" PATH="$midtidy_stub_bin:$PATH" \
    FAKE_MIDTIDY_COUNT_FILE="$midtidy_count_file" \
    FAKE_MIDTIDY_APPROVED_FILE="$midtidy_approved_file" \
    "$launcher" --foreground --harness claude --maintainer-loop 1 \
    --maintainer-model sonnet --tidy-timeout 1800 --branch "$midtidy_branch" \
    "$proj" "$handoff" > "$midtidy_out" 2>&1 &
midtidy_runner_pid=$!

midtidy_rd=""
for _ in $(seq 1 100); do
    midtidy_rd="$(sed -n 's/^  run dir:  *//p' "$midtidy_out" 2>/dev/null | head -1)"
    [[ -n "$midtidy_rd" ]] && break
    sleep 0.1
done
if [[ -n "$midtidy_rd" ]]; then
    tmpdirs+=("$midtidy_rd")
    midtidy_leg_seen=0
    for _ in $(seq 1 150); do
        [[ -e "$midtidy_rd/events-tidy-1.jsonl" ]] && { midtidy_leg_seen=1; break; }
        sleep 0.1
    done
    # The stub's own sleep, tagged with its unique duration, confirms the
    # tidy leg's agent is actually alive before this proves anything about
    # killing it.
    midtidy_hang_alive=0
    for _ in $(seq 1 50); do
        pgrep -f "sleep $midtidy_hang_seconds" >/dev/null 2>&1 && { midtidy_hang_alive=1; break; }
        sleep 0.1
    done
    if (( midtidy_leg_seen )) && (( midtidy_hang_alive )); then
        ok "mid-tidy-leg real stop: the tidy leg's agent is actually running"
        midtidy_clone_dir="$(sed -n 's/^clone_dir=//p' "$midtidy_rd/run.env" | head -1)"
        # Read off the stub's own snapshot, taken before it rewrote the
        # clone -- not the clone's current head, which by now is the
        # leg's in-progress rewrite, exactly the thing a correct stop
        # must never publish.
        midtidy_approved_sha="$(cat "$midtidy_approved_file" 2>/dev/null)"
        midtidy_wip_sha="$(git -C "$midtidy_clone_dir" rev-parse "$midtidy_branch" 2>/dev/null)"
        check "mid-tidy-leg real stop: the clone's own head is the leg's WIP, not the approved sha" \
            "1" "$( [[ -n "$midtidy_approved_sha" && "$midtidy_wip_sha" != "$midtidy_approved_sha" ]] && echo 1 || echo 0 )"
        out_midtidy="$(HOME="$launcher_home" "$stop" --timeout 5 "$midtidy_rd" 2>&1)"
        rc_midtidy=$?
        check "mid-tidy-leg real stop: stop exits 0" "0" "$rc_midtidy"
        # Whether this reads "published the maintainer-approved history,
        # not the clone" (stop itself completed the publish) or a plain
        # "stopped gracefully"/"end_reason: ..." (the runner's own
        # teardown, now that the group signal actually reaches the tidy
        # leg, won the race and published it first) depends on timing, not
        # correctness -- either way this must never report the one
        # outcome that would mean the fetch-back failed.
        not_contains "mid-tidy-leg real stop: never reports a failed fetch-back" \
            "NOT fetched back" "$out_midtidy"
        midtidy_hang_gone=1
        for _ in $(seq 1 50); do
            pgrep -f "sleep $midtidy_hang_seconds" >/dev/null 2>&1 || { midtidy_hang_gone=1; break; }
            midtidy_hang_gone=0
            sleep 0.1
        done
        check "mid-tidy-leg real stop: no process from the run survives" "1" "$midtidy_hang_gone"
        check "mid-tidy-leg real stop: the published branch is the approved head, not a WIP" \
            "$midtidy_approved_sha" "$(git -C "$proj" rev-parse "$midtidy_branch" 2>/dev/null)"
        check "mid-tidy-leg real stop: the tidy leg's own holding refs are gone once published" \
            "" "$(git -C "$proj" for-each-ref "refs/fork-sandbox/tidy/$(basename "$midtidy_rd")")"
    else
        no "mid-tidy-leg real stop: the tidy leg's agent is actually running" \
            "events-tidy-1.jsonl seen: $midtidy_leg_seen, hang stub alive: $midtidy_hang_alive"
        no "mid-tidy-leg real stop: the clone's own head is the leg's WIP, not the approved sha" \
            "tidy leg never started"
        no "mid-tidy-leg real stop: stop exits 0" "tidy leg never started"
        no "mid-tidy-leg real stop: never reports a failed fetch-back" \
            "tidy leg never started"
        no "mid-tidy-leg real stop: no process from the run survives" "tidy leg never started"
        no "mid-tidy-leg real stop: the published branch is the approved head, not a WIP" \
            "tidy leg never started"
        no "mid-tidy-leg real stop: the tidy leg's own holding refs are gone once published" \
            "tidy leg never started"
    fi
    kill -KILL "$midtidy_runner_pid" 2>/dev/null || true
    wait "$midtidy_runner_pid" 2>/dev/null || true
    pkill -9 -f "sleep $midtidy_hang_seconds" >/dev/null 2>&1 || true
    (cd "$proj" && git branch -q -D "$midtidy_branch" >/dev/null 2>&1) || true
else
    no "mid-tidy-leg real stop: the tidy leg's agent is actually running" \
        "no run dir ever appeared: $(cat "$midtidy_out")"
    no "mid-tidy-leg real stop: the clone's own head is the leg's WIP, not the approved sha" \
        "no run dir"
    no "mid-tidy-leg real stop: stop exits 0" "no run dir"
    no "mid-tidy-leg real stop: never reports a failed fetch-back" "no run dir"
    no "mid-tidy-leg real stop: no process from the run survives" "no run dir"
    no "mid-tidy-leg real stop: the published branch is the approved head, not a WIP" "no run dir"
    no "mid-tidy-leg real stop: the tidy leg's own holding refs are gone once published" "no run dir"
fi

# -- same shape as the mid-tidy-leg test above, but the runner is killed
# outright (SIGKILL on its own pid, never the tidy leg's own group) before
# stop is ever called, the way a crash or an external kill -9 would leave
# things -- stop can only take the salvage path here, with no runner left
# alive to walk descendants down from. The tidy leg's own GNU-timeout group
# is a separate group from the runner's, so killing the runner alone leaves
# it a live orphan, exactly the case the recorded pgid file exists for.
deadrunner_stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-stop-deadrunner-stub.XXXXXX)"
tmpdirs+=("$deadrunner_stub_bin")
deadrunner_hang_seconds=631
cat > "$deadrunner_stub_bin/claude-sandboxed" <<STUB
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "\$@"; do
    [[ "\$a" == "--dangerously-skip-permissions" ]] && clone_dir="\$prev"
    prev="\$a"
done
prompt="\$(cat)"
n=0
[[ -f "\$FAKE_DEADRUNNER_COUNT_FILE" ]] && n="\$(cat "\$FAKE_DEADRUNNER_COUNT_FILE")"
n=\$(( n + 1 ))
printf '%s' "\$n" > "\$FAKE_DEADRUNNER_COUNT_FILE"
if (( n == 1 )); then
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \\
        -C "\$clone_dir" commit --allow-empty -q -m "stub leg \$n"
elif (( n == 2 )); then
    verdict_name="\$(printf '%s\\n' "\$prompt" \\
        | sed -nE 's#.*\\.git/(maintainer-verdict\\.md)#\\1#p' | head -1)"
    [[ -n "\$verdict_name" ]] || verdict_name=maintainer-verdict.md
    printf 'APPROVED\\n\\nChecked: everything.\\n' > "\$clone_dir/.git/\$verdict_name"
else
    git -C "\$clone_dir" rev-parse HEAD > "\$FAKE_DEADRUNNER_APPROVED_FILE"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \\
        -C "\$clone_dir" commit --allow-empty -q -m "tidy leg's in-progress rewrite"
    sleep $deadrunner_hang_seconds
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$deadrunner_stub_bin/claude-sandboxed"

deadrunner_count_file="$(mktemp)"; tmpdirs+=("$deadrunner_count_file")
deadrunner_approved_file="$(mktemp)"; tmpdirs+=("$deadrunner_approved_file")
deadrunner_out="$(mktemp)"; tmpdirs+=("$deadrunner_out")
deadrunner_branch="sandbox-test-stop-deadrunner-$$"
HOME="$launcher_home" PATH="$deadrunner_stub_bin:$PATH" \
    FAKE_DEADRUNNER_COUNT_FILE="$deadrunner_count_file" \
    FAKE_DEADRUNNER_APPROVED_FILE="$deadrunner_approved_file" \
    "$launcher" --foreground --harness claude --maintainer-loop 1 \
    --maintainer-model sonnet --tidy-timeout 1800 --branch "$deadrunner_branch" \
    "$proj" "$handoff" > "$deadrunner_out" 2>&1 &
deadrunner_launcher_pid=$!

deadrunner_rd=""
for _ in $(seq 1 100); do
    deadrunner_rd="$(sed -n 's/^  run dir:  *//p' "$deadrunner_out" 2>/dev/null | head -1)"
    [[ -n "$deadrunner_rd" ]] && break
    sleep 0.1
done
if [[ -n "$deadrunner_rd" ]]; then
    tmpdirs+=("$deadrunner_rd")
    deadrunner_leg_seen=0
    for _ in $(seq 1 150); do
        [[ -e "$deadrunner_rd/events-tidy-1.jsonl" ]] && { deadrunner_leg_seen=1; break; }
        sleep 0.1
    done
    deadrunner_hang_alive=0
    for _ in $(seq 1 50); do
        pgrep -f "sleep $deadrunner_hang_seconds" >/dev/null 2>&1 && { deadrunner_hang_alive=1; break; }
        sleep 0.1
    done
    if (( deadrunner_leg_seen )) && (( deadrunner_hang_alive )); then
        ok "dead-runner real stop: the tidy leg's agent is actually running"
        deadrunner_pid="$(tr -dc '0-9' < "$deadrunner_rd/pid")"
        # SIGKILL the runner's own pid alone -- never a group, never the
        # tidy leg's own separate group -- so the leg's agent is left a
        # live orphan, same as a crash or a bare 'kill -9' would.
        kill -KILL "$deadrunner_pid" 2>/dev/null || true
        deadrunner_runner_dead=0
        for _ in $(seq 1 50); do
            kill -0 "$deadrunner_pid" 2>/dev/null || { deadrunner_runner_dead=1; break; }
            sleep 0.1
        done
        check "dead-runner real stop: the runner is actually dead before stop is called" \
            "1" "$deadrunner_runner_dead"
        deadrunner_approved_sha="$(cat "$deadrunner_approved_file" 2>/dev/null)"
        out_deadrunner="$(HOME="$launcher_home" "$stop" "$deadrunner_rd" 2>&1)"
        rc_deadrunner=$?
        check "dead-runner real stop: stop exits 0" "0" "$rc_deadrunner"
        contains "dead-runner real stop: reports a salvage, not a graceful stop" \
            "end_reason: salvaged" "$out_deadrunner"
        not_contains "dead-runner real stop: never reports a failed fetch-back" \
            "NOT fetched back" "$out_deadrunner"
        deadrunner_hang_gone=1
        for _ in $(seq 1 50); do
            pgrep -f "sleep $deadrunner_hang_seconds" >/dev/null 2>&1 || { deadrunner_hang_gone=1; break; }
            deadrunner_hang_gone=0
            sleep 0.1
        done
        check "dead-runner real stop: no process from the run survives" "1" "$deadrunner_hang_gone"
        check "dead-runner real stop: the published branch is the approved head, not the orphaned WIP" \
            "$deadrunner_approved_sha" "$(git -C "$proj" rev-parse "$deadrunner_branch" 2>/dev/null)"
        check "dead-runner real stop: the tidy leg's own holding refs are gone once published" \
            "" "$(git -C "$proj" for-each-ref "refs/fork-sandbox/tidy/$(basename "$deadrunner_rd")")"
    else
        no "dead-runner real stop: the tidy leg's agent is actually running" \
            "events-tidy-1.jsonl seen: $deadrunner_leg_seen, hang stub alive: $deadrunner_hang_alive"
        no "dead-runner real stop: the runner is actually dead before stop is called" "tidy leg never started"
        no "dead-runner real stop: stop exits 0" "tidy leg never started"
        no "dead-runner real stop: reports a salvage, not a graceful stop" "tidy leg never started"
        no "dead-runner real stop: never reports a failed fetch-back" "tidy leg never started"
        no "dead-runner real stop: no process from the run survives" "tidy leg never started"
        no "dead-runner real stop: the published branch is the approved head, not the orphaned WIP" \
            "tidy leg never started"
        no "dead-runner real stop: the tidy leg's own holding refs are gone once published" \
            "tidy leg never started"
    fi
    kill -KILL "$deadrunner_launcher_pid" 2>/dev/null || true
    wait "$deadrunner_launcher_pid" 2>/dev/null || true
    pkill -9 -f "sleep $deadrunner_hang_seconds" >/dev/null 2>&1 || true
    (cd "$proj" && git branch -q -D "$deadrunner_branch" >/dev/null 2>&1) || true
else
    no "dead-runner real stop: the tidy leg's agent is actually running" \
        "no run dir ever appeared: $(cat "$deadrunner_out")"
    no "dead-runner real stop: the runner is actually dead before stop is called" "no run dir"
    no "dead-runner real stop: stop exits 0" "no run dir"
    no "dead-runner real stop: reports a salvage, not a graceful stop" "no run dir"
    no "dead-runner real stop: never reports a failed fetch-back" "no run dir"
    no "dead-runner real stop: no process from the run survives" "no run dir"
    no "dead-runner real stop: the published branch is the approved head, not the orphaned WIP" "no run dir"
    no "dead-runner real stop: the tidy leg's own holding refs are gone once published" "no run dir"
fi

# -- stale tidy.pgid: the recorded start time does not match the pid's
# CURRENT one, because its number was reused by an unrelated process after
# the leg that originally held it ended. A hand-built fixture, not a real
# launcher run: the bystander here is a genuine GNU `timeout` (so its comm
# really is "timeout", isolating the start-time check from the comm check)
# started independently of this run, with a deliberately wrong recorded
# start time standing in for "pid reused". fork-sandbox-stop.sh must never
# signal it.
staletidy_origin="$(new_project)"; tmpdirs+=("$staletidy_origin")
staletidy_base_sha="$(cd "$staletidy_origin" && git rev-parse HEAD)"
staletidy_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-staletidy-clone.XXXXXX)"
tmpdirs+=("$staletidy_clone")
(
    cd "$staletidy_origin" && git clone -q . "$staletidy_clone" \
        && cd "$staletidy_clone" \
        && git checkout -q -b fs-stop-staletidy \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'work\n' > staletidy.txt \
        && git add staletidy.txt \
        && git commit -q -m 'salvaged work'
) >/dev/null 2>&1
rd_staletidy="$(new_run_dir)"
cat > "$rd_staletidy/run.env" <<EOF
version=1
branch=fs-stop-staletidy
origin_repo=$staletidy_origin
clone_dir=$staletidy_clone
base_sha=$staletidy_base_sha
session=cc-sbx-fs-stop-staletidy-does-not-exist
EOF
( : ) & staletidy_dead_pid=$!
wait "$staletidy_dead_pid" 2>/dev/null || true
printf '%s\n' "$staletidy_dead_pid" > "$rd_staletidy/pid"

staletidy_hang_seconds=653
timeout "$staletidy_hang_seconds" sleep "$staletidy_hang_seconds" &
staletidy_bystander_pid=$!
staletidy_bystander_alive=0
for _ in $(seq 1 50); do
    kill -0 "$staletidy_bystander_pid" 2>/dev/null && { staletidy_bystander_alive=1; break; }
    sleep 0.1
done
# The recorded pid is real and its comm really is "timeout" -- only the
# start time (decades in the past) cannot match, isolating exactly that
# check.
printf '%s\n%s\n' "$staletidy_bystander_pid" "Thu Jan  1 00:00:00 1970" \
    > "$rd_staletidy/tidy.pgid"

if (( staletidy_bystander_alive )); then
    ok "stale tidy.pgid: the bystander process is actually running"
    out_staletidy="$(HOME="$launcher_home" "$stop" "$rd_staletidy" 2>&1)"
    rc_staletidy=$?
    check "stale tidy.pgid: stop exits 0" "0" "$rc_staletidy"
    contains "stale tidy.pgid: reports end_reason salvaged" "salvaged" "$out_staletidy"
    check "stale tidy.pgid: the bystander process is never signaled" \
        "1" "$(kill -0 "$staletidy_bystander_pid" 2>/dev/null && echo 1 || echo 0)"
    check "stale tidy.pgid: the branch is still fetched back normally" \
        "$(cd "$staletidy_clone" && git rev-parse fs-stop-staletidy)" \
        "$(cd "$staletidy_origin" && git rev-parse fs-stop-staletidy 2>/dev/null)"
else
    no "stale tidy.pgid: the bystander process is actually running" "timeout never started"
    no "stale tidy.pgid: stop exits 0" "bystander never started"
    no "stale tidy.pgid: reports end_reason salvaged" "bystander never started"
    no "stale tidy.pgid: the bystander process is never signaled" "bystander never started"
    no "stale tidy.pgid: the branch is still fetched back normally" "bystander never started"
fi
kill -KILL "$staletidy_bystander_pid" 2>/dev/null || true
wait "$staletidy_bystander_pid" 2>/dev/null || true
pkill -9 -f "sleep $staletidy_hang_seconds" >/dev/null 2>&1 || true

# -- macOS-named tidy leg: FS_TIMEOUT resolves to "gtimeout" (the name
# Homebrew's coreutils gives GNU timeout on macOS), not "timeout". A real
# leg started under that name, with its real pid and start time recorded
# in tidy.pgid exactly as fs_record_tidy_leg_pgid would, must still be
# recognized and signaled: the comm check has to follow $FS_TIMEOUT's own
# resolved name rather than a hardcoded "timeout". The shim is a bare
# symlink to the real `timeout`, not a wrapper script that execs it --
# a wrapper's own exec would replace its image with the real binary's,
# whose comm is "timeout" again, defeating the point.
gtimeout_shim_bin="$(mktemp -d /var/tmp/claude-scratch/fs-stop-gtimeout-shim.XXXXXX)"
tmpdirs+=("$gtimeout_shim_bin")
ln -s "$(command -v timeout)" "$gtimeout_shim_bin/gtimeout"

gtimeout_origin="$(new_project)"; tmpdirs+=("$gtimeout_origin")
gtimeout_base_sha="$(cd "$gtimeout_origin" && git rev-parse HEAD)"
gtimeout_clone="$(mktemp -d /var/tmp/claude-scratch/fs-stop-gtimeout-clone.XXXXXX)"
tmpdirs+=("$gtimeout_clone")
(
    cd "$gtimeout_origin" && git clone -q . "$gtimeout_clone" \
        && cd "$gtimeout_clone" \
        && git checkout -q -b fs-stop-gtimeout \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'work\n' > gtimeout.txt \
        && git add gtimeout.txt \
        && git commit -q -m 'salvaged work'
) >/dev/null 2>&1
rd_gtimeout="$(new_run_dir)"
cat > "$rd_gtimeout/run.env" <<EOF
version=1
branch=fs-stop-gtimeout
origin_repo=$gtimeout_origin
clone_dir=$gtimeout_clone
base_sha=$gtimeout_base_sha
session=cc-sbx-fs-stop-gtimeout-does-not-exist
EOF
( : ) & gtimeout_dead_pid=$!
wait "$gtimeout_dead_pid" 2>/dev/null || true
printf '%s\n' "$gtimeout_dead_pid" > "$rd_gtimeout/pid"

gtimeout_hang_seconds=653
PATH="$gtimeout_shim_bin:$PATH" gtimeout "$gtimeout_hang_seconds" sleep "$gtimeout_hang_seconds" &
gtimeout_leg_pid=$!
gtimeout_leg_alive=0
for _ in $(seq 1 50); do
    kill -0 "$gtimeout_leg_pid" 2>/dev/null && { gtimeout_leg_alive=1; break; }
    sleep 0.1
done

if (( gtimeout_leg_alive )); then
    ok "gtimeout tidy leg: the leg process is actually running"
    # Recorded the same way fs_record_tidy_leg_pgid does, through the real
    # lib function, so this exercises the actual identity check rather
    # than a hand-guessed start time.
    gtimeout_start="$(bash -c 'source "$1"; fs_proc_start_time "$2"' _ \
        "$repo_dir/scripts/fork-sandbox-lib.sh" "$gtimeout_leg_pid")"
    printf '%s\n%s\n' "$gtimeout_leg_pid" "$gtimeout_start" > "$rd_gtimeout/tidy.pgid"

    out_gtimeout="$(HOME="$launcher_home" PATH="$gtimeout_shim_bin:$PATH" "$stop" "$rd_gtimeout" 2>&1)"
    rc_gtimeout=$?
    check "gtimeout tidy leg: stop exits 0" "0" "$rc_gtimeout"
    contains "gtimeout tidy leg: reports end_reason salvaged" "salvaged" "$out_gtimeout"
    gtimeout_leg_gone=0
    for _ in $(seq 1 50); do
        kill -0 "$gtimeout_leg_pid" 2>/dev/null || { gtimeout_leg_gone=1; break; }
        sleep 0.1
    done
    check "gtimeout tidy leg: the leg is signaled and gone, not left as a bystander" \
        "1" "$gtimeout_leg_gone"
else
    no "gtimeout tidy leg: the leg process is actually running" "gtimeout never started"
    no "gtimeout tidy leg: stop exits 0" "leg never started"
    no "gtimeout tidy leg: reports end_reason salvaged" "leg never started"
    no "gtimeout tidy leg: the leg is signaled and gone, not left as a bystander" "leg never started"
fi
kill -KILL "$gtimeout_leg_pid" 2>/dev/null || true
wait "$gtimeout_leg_pid" 2>/dev/null || true
pkill -9 -f "sleep $gtimeout_hang_seconds" >/dev/null 2>&1 || true

printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# Same guard as fork-sandbox-k8s-test.sh's: archives carry no source
# marker, so a leaked fixture archive is indistinguishable from an
# operator's real work. Ownership, not a global snapshot diff -- a
# snapshot diff would fail this suite over an unrelated concurrent run's
# archive landing during this suite's window even when this suite leaked
# nothing (row 72). record() only ever archives a run dir's handoff.md
# (sandbox-run-log.py), and $rd/$rd2 -- this suite's two real-launcher run
# dirs -- are the only run dirs this suite ever gives one; every other
# fixture run dir here is hand-built by new_run_dir() with no handoff.md
# inside it, so it can never produce an archive. A leaked archive is
# always named <run-dir-basename>.md.
new_operator_archives=""
for owned_rd in "$rd" "$rd2"; do
    [[ -z "$owned_rd" ]] && continue
    archive_path="$operator_archive_dir/$(basename "$owned_rd").md"
    [[ -e "$archive_path" ]] && new_operator_archives+="$archive_path "
done
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$new_operator_archives"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
