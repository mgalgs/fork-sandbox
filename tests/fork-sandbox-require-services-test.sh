#!/usr/bin/env bash
# fork-sandbox-require-services-test.sh -- required local services contract.
# Usage: tests/fork-sandbox-require-services-test.sh

set -euo pipefail
unset TMUX

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="${FS_TEST_LAUNCHER:-$repo_dir/scripts/fork-sandbox.sh}"
script_dir="$(dirname "$launcher")"
pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s: %s\n' "$1" "$2"; fail=$((fail + 1)); }

for conflicting_flag in --no-services --k8s; do
    set +e
    output="$("$launcher" --require-services "$conflicting_flag" 2>&1 </dev/null)"
    rc=$?
    set -e
    if (( rc != 0 )) && [[ "$output" == *"--require-services"* \
        && "$output" == *"$conflicting_flag"* \
        && "$(wc -l <<< "$output")" == 1 ]]; then
        ok "--require-services with $conflicting_flag is refused in one line"
    else
        no "--require-services with $conflicting_flag is refused in one line" "$output (exit $rc)"
    fi
done

scratch="$(mktemp -d "$repo_dir/.require-services.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
home="$scratch/home"
bin="$scratch/bin"
project="$scratch/project"
mkdir -p "$home" "$bin" "$project/.agents/sandbox-services"
mkdir -p "$scratch/config"
printf 'PROJECT_ROOTS=%s\n' "$project" > "$scratch/config/projects.env"
git -C "$project" init -q
git -C "$project" config user.name Tester
git -C "$project" config user.email tester@fork-sandbox.invalid
printf 'fixture\n' > "$project/file.txt"
cat > "$project/.agents/sandbox-services/sandbox-services.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FS_TEST_HOOK_CALLS"
if [[ "$1" == up && "${FS_TEST_FAIL_UP:-0}" == 1 ]]; then
    exit 1
fi
HOOK
chmod +x "$project/.agents/sandbox-services/sandbox-services.sh"
git -C "$project" add .
git -C "$project" commit -qm initial
cat > "$bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
touch "$FS_TEST_AGENT_MARKER"
cat >/dev/null
printf '{"type":"result","subtype":"success","result":"ok"}\n'
STUB
cat > "$bin/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$bin/sandbox-backend-fake-host" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --capabilities ]] && printf 'toolchain=host\n'
STUB
real_tmux="$(command -v tmux)"
cat > "$bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == new-session && -n "${FS_TEST_RACE_TMUX_STATE:-}" ]]; then
    "$FS_TEST_REAL_TMUX" "$@" || exit $?
    printf '%s\n' "$(dirname "${@: -1}")" > "$FS_TEST_RACE_TMUX_STATE"
    exit 0
fi
if [[ "${1:-}" == has-session && -s "${FS_TEST_RACE_TMUX_STATE:-/dev/null}" ]]; then
    read -r run_dir < "$FS_TEST_RACE_TMUX_STATE"
    for (( i=0; i<100; i++ )); do
        [[ -s "$run_dir/exit-code" ]] && break
        sleep 0.1
    done
    exit 1
fi
exec "$FS_TEST_REAL_TMUX" "$@"
STUB
chmod +x "$bin"/*
handoff="$(mktemp /var/tmp/claude-scratch/require-services-handoff.XXXXXX)"
trap 'rm -rf -- "$scratch"; rm -- "$handoff"' EXIT
printf 'Do the task.\n' > "$handoff"

run_case() {
    local label="$1"; shift
    local -a launch_mode=(--foreground)
    local case_tmux=""
    if [[ "$label" == detached || "$label" == race ]]; then
        launch_mode=()
        # The pane inherits the server's environment, so start a private
        # server with this case's fixture values.
        # tmux's Unix socket path has a tight length limit.
        case_tmux="$(mktemp -d /var/tmp/claude-scratch/rs-tmux.XXXXXX)"
    fi
    calls="$scratch/$label.calls"
    marker="$scratch/$label.agent"
    set +e
    output="$(HOME="$home" PATH="$bin:$script_dir:$PATH" \
        FORK_SANDBOX_CONFIG_DIR="$scratch/config" \
        FORK_SANDBOX_BACKEND=fake-host FORK_SANDBOX_RUN_SOURCE=test \
        FORK_SANDBOX_BY_SESSION_DIR="$scratch/by-session" \
        FS_TEST_HOOK_CALLS="$calls" FS_TEST_AGENT_MARKER="$marker" \
        FS_TEST_FAIL_UP="${fail_up:-0}" \
        FS_TEST_REAL_TMUX="$real_tmux" \
        FS_TEST_RACE_TMUX_STATE="$([[ "$label" == race ]] && printf '%s' "$scratch/race-tmux-state")" \
        TMUX_TMPDIR="$case_tmux" \
        "$launcher" "${launch_mode[@]}" --harness claude --model sonnet \
        --branch "require-$label" "$@" "$project" "$handoff" </dev/null 2>&1)"
    rc=$?
    set -e
    run_dir="$(sed -n 's/^  run dir:  *//p' <<< "$output" | head -1)"
    if [[ -z "$run_dir" ]]; then
        run_dir="$(sed -n 's@^fork-sandbox: required services .*; see \(/[^ ]*/sandbox.log\)\.$@\1@p' <<< "$output" | head -1)"
        run_dir="${run_dir%/sandbox.log}"
    fi
    if [[ -n "$case_tmux" ]]; then
        TMUX_TMPDIR="$case_tmux" tmux -L default kill-server >/dev/null 2>&1 || true
        rm -rf -- "$case_tmux"
    fi
}

fail_up=1
run_case failed-up --require-services
if (( rc != 0 )) && [[ -n "$run_dir" && ! -e "$marker" ]] \
    && [[ "$(cat "$calls" 2>/dev/null)" == $'up\ndown' ]] \
    && [[ "$(cat "$run_dir/exit-code" 2>/dev/null)" == 1 ]]; then
    ok "failed up aborts before the agent and runs down"
else
    no "failed up aborts before the agent and runs down" "$output"
fi
if [[ -n "$run_dir" ]]; then
    monitor="$(HOME="$home" timeout 5 "$script_dir/fork-sandbox-status.sh" --monitor-terminal "$run_dir" 2>&1 || true)"
    if [[ "$monitor" == *"required services failed to start"* \
        && "$monitor" != *"No summary was written"* \
        && -s "$run_dir/summary.txt" && ! -e "$run_dir/summary.json" \
        && -s "$run_dir/services-startup" ]]; then
        ok "required-services failure has a local monitor summary"
    else
        no "required-services failure has a local monitor summary" "$monitor"
    fi
fi
if [[ -n "$run_dir" ]]; then
    status_json="$(HOME="$home" "$script_dir/fork-sandbox-status.sh" --json "$run_dir" 2>/dev/null || true)"
    if [[ "$(jq -r '.state' <<< "$status_json")" == failed \
        && "$(jq -r 'has("end_reason")' <<< "$status_json")" == false \
        && "$output" == *"required services failed to start; see $run_dir/sandbox.log."* \
        && "$(grep -cF "required services failed to start; see $run_dir/sandbox.log." "$run_dir/sandbox.log")" == 1 \
        && "$(HOME="$home" "$script_dir/fork-sandbox-status.sh" "$run_dir")" == *'required services failed to start'* ]]; then
        ok "failed up is reported by launcher, log and JSON status"
    else
        no "failed up is reported by launcher, log and JSON status" "$status_json"
    fi
    log_json="$(HOME="$home" "$script_dir/sandbox-run-log.py" show "$(basename "$run_dir")")"
    if [[ "$(jq -r '.end_reason' <<< "$log_json")" == services-failed \
        && "$(jq -r '.summary_missing' <<< "$log_json")" == true \
        && "$(jq -r '.harness' <<< "$log_json")" == claude \
        && "$(jq -r '.model' <<< "$log_json")" == sonnet \
        && "$(jq -r '.exit_code' <<< "$log_json")" == 1 ]]; then
        ok "failed up records token and run.env fallback fields"
    else
        no "failed up records token and run.env fallback fields" "$log_json"
    fi
fi

run_case untrusted --require-services --checkout HEAD
if (( rc != 0 )) && [[ -n "$run_dir" && ! -e "$marker" ]] \
    && [[ ! -e "$run_dir/summary.json" && -s "$run_dir/summary.txt" \
        && -s "$run_dir/services-startup" \
        && "$(cat "$run_dir/exit-code")" == 1 \
        && "$(HOME="$home" "$script_dir/sandbox-run-log.py" show "$(basename "$run_dir")" \
            | jq -r '.end_reason')" == services-unavailable \
        && "$(HOME="$home" "$script_dir/fork-sandbox-status.sh" "$run_dir")" == *'required services were not available'* ]]; then
    ok "untrusted checkout disables services and aborts"
else
    no "untrusted checkout disables services and aborts" "$output"
fi

git -C "$project" rm -q .agents/sandbox-services/sandbox-services.sh
git -C "$project" commit -qm 'remove hook'
fail_up=0
run_case no-hook --require-services
if (( rc != 0 )) && [[ -n "$run_dir" && ! -e "$marker" ]] \
    && [[ ! -e "$run_dir/summary.json" \
        && "$(HOME="$home" "$script_dir/sandbox-run-log.py" show "$(basename "$run_dir")" \
            | jq -r '.end_reason')" == services-unavailable ]]; then
    ok "missing hook aborts with unavailable cause"
else
    no "missing hook aborts with unavailable cause" "$output"
fi

git -C "$project" restore --source=HEAD^ --staged --worktree .agents/sandbox-services/sandbox-services.sh
git -C "$project" commit -qm 'restore hook'
run_case working --require-services
if (( rc == 0 )) && [[ -e "$marker" && "$(cat "$calls")" == $'up\ndown' ]]; then
    ok "working hook starts the agent and runs down"
else
    no "working hook starts the agent and runs down" "$output"
fi

fail_up=1
run_case detached --require-services
if (( rc != 0 )) && [[ -n "$run_dir" && ! -e "$marker" ]] \
    && [[ "$(cat "$run_dir/exit-code" 2>/dev/null)" == 1 ]] \
    && [[ "$(cat "$calls" 2>/dev/null)" == $'up\ndown' ]] \
    && [[ "$output" == *"required services failed to start; see $run_dir/sandbox.log."* ]]; then
    ok "detached launch returns failure for required services"
else
    no "detached launch returns failure for required services" "$output"
fi

fail_up=0
run_case race --require-services
if (( rc == 0 )) && [[ -n "$run_dir" && -e "$marker" ]] \
    && [[ "$(cat "$run_dir/services-startup" 2>/dev/null)" == ok ]] \
    && [[ "$(cat "$run_dir/exit-code" 2>/dev/null)" == 0 ]]; then
    ok "completed detached run keeps its successful startup result"
else
    no "completed detached run keeps its successful startup result" "$output"
fi

fail_up=1
run_case default
if (( rc == 0 )) && [[ -e "$marker" ]] \
    && [[ "$(cat "$run_dir/handoff.md")" == *'Correction: the per-run services FAILED to start'* ]]; then
    ok "default failed up still starts the agent with correction"
else
    no "default failed up still starts the agent with correction" "$output"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
