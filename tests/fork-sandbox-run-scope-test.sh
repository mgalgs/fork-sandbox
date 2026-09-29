#!/usr/bin/env bash
# fork-sandbox-run-scope-test.sh — a local run launches inside its own
# transient systemd scope (OOMPolicy=continue) when the host can provide
# one, so a runaway tool OOM-killed inside the sandbox cannot take the
# whole runner down with it via tmux's own scope's default OOMPolicy=stop.
# See scripts/fork-sandbox.sh's own comment near session_name for the full
# story, and docs/configure.md for RUN_SCOPE/RUN_MEMORY_MAX.
#
# Usage: tests/fork-sandbox-run-scope-test.sh
#
# Covers: the wrapped tmux command (OOMPolicy=continue, a valid --unit, no
# MemoryMax when RUN_MEMORY_MAX is unset), RUN_MEMORY_MAX validation (valid
# absolute and percentage values add MemoryMax + MemorySwapMax=0; invalid
# ones are refused at launch before anything is created), the
# scope-unavailable fallback (silent without RUN_MEMORY_MAX, exactly one
# warning with it), RUN_SCOPE=off (systemd-run never invoked even where
# available, scope=none, silent alone / warns once with RUN_MEMORY_MAX) and
# unrecognized RUN_SCOPE values (refused at launch, same as RUN_MEMORY_MAX),
# the --foreground path getting the same wrapping, what lands in run.env and
# sandbox.log, and that the pane's bus env reaches it without relying on
# `tmux new-session -e` (tmux 3.2+ only -- see that test's own comment).
#
# systemd-run is stubbed on PATH throughout: this sandbox may well have a
# real binary by that name, but with no reachable --user manager (no
# DBUS_SESSION_BUS_ADDRESS) it cannot actually register a scope, so
# exercising the "available" path at all needs a stub regardless -- and a
# stub is also what keeps the "unavailable" path deterministic on a host
# that DOES have a working one. The "available" stub logs its own argv and
# then execs through to whatever follows '--' (or its own last argument,
# for the bare probe call, which has none), so the real runner keeps
# running underneath it and a test can check actual run.env, sandbox.log
# and exit-code, not just the argv fork-sandbox.sh built.
#
# tmux is real, pinned to a dedicated -L socket via a thin PATH wrapper --
# never the caller's own default server -- the same pattern
# tests/fork-sandbox-clone-dir-lock-lifetime-test.sh already uses.
#
# No real sandbox is ever built and no real claude runs.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

export FORK_SANDBOX_RUN_SOURCE=test

real_tmux="$(command -v tmux || true)"
if [[ -z "$real_tmux" ]]; then
    echo "tmux not found; skipping (nothing to test)."
    exit 0
fi

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
# Every real launch below writes launcher_session_id/creates a by-session
# symlink from CLAUDE_CODE_SESSION_ID -- scoped here so a real session
# running this suite never has its own by-session index polluted with
# entries for these throwaway fixture runs.
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"
tmux_sockets=()

cleanup() {
    local d s
    for s in "${tmux_sockets[@]-}"; do
        [[ -n "$s" ]] && "$real_tmux" -L "$s" kill-server >/dev/null 2>&1
    done
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "expected to find: $needle"
    fi
}
lacks() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "did not expect to find: $needle"
    fi
}

scratch="/var/tmp/claude-scratch"
mkdir -p "$scratch/forks"

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

new_project() {
    local home="$1" d
    mkdir -p "$home/src"
    d="$(mktemp -d "$home/src/fs-runscope-test.XXXXXX")"
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

read_env_field() {
    # First match, same convention fs_read_env_value itself follows -- fine
    # here since every fixture run.env this suite produces sets each key once.
    sed -n "s/^$2=//p" "$1/run.env" 2>/dev/null | head -1
}

wait_for_exit_code() {
    local rd="$1"
    for _ in $(seq 1 100); do
        [[ -s "$rd/exit-code" ]] && return 0
        sleep 0.1
    done
    return 1
}

stub_bin="$(mktmp_dir "$scratch/fs-runscope-stub.XXXXXX")"

# Real tmux, pinned to whatever dedicated socket the caller names in
# FS_TEST_TMUX_SOCKET at call time -- so the launcher's own `tmux
# new-session -d` never touches a real default server.
cat > "$stub_bin/tmux" <<STUB
#!/usr/bin/env bash
exec "$real_tmux" -L "\${FS_TEST_TMUX_SOCKET:?}" "\$@"
STUB
chmod +x "$stub_bin/tmux"

cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# The "systemd-run is available" PATH entry: regenerated per test below with
# write_scope_stub, which bakes the log path directly into the stub's own
# source (the same trick tests/fork-sandbox-clone-dir-lock-lifetime-test.sh
# uses for leak_log) rather than an env var -- a var set on the launcher
# invocation is not guaranteed to reach a pane tmux's SERVER spawns later,
# since that pane is not a direct child of this test's own process chain,
# but text baked into the file on disk reaches it unconditionally.
scope_avail_bin="$(mktmp_dir "$scratch/fs-runscope-scope.XXXXXX")"
write_scope_stub() {
    local log="$1"
    cat > "$scope_avail_bin/systemd-run" <<STUB
#!/usr/bin/env bash
: > "$log"
for a in "\$@"; do printf '%s\n' "\$a" >> "$log"; done
args=("\$@")
for i in "\${!args[@]}"; do
    if [[ "\${args[\$i]}" == "--" ]]; then
        exec "\${args[@]:\$((i+1))}"
    fi
done
exec "\${args[-1]}"
STUB
    chmod +x "$scope_avail_bin/systemd-run"
}

# The "systemd-run is unavailable" PATH entry: a fixed failing stub, first in
# PATH, so `command -v systemd-run` finds THIS rather than whatever the host
# may or may not have further down PATH -- unavailability stays deterministic
# either way, and the "invocation exists but there is no usable --user
# manager" branch is the more realistic shape for a real host anyway.
scope_unavail_bin="$(mktmp_dir "$scratch/fs-runscope-noscope.XXXXXX")"
cat > "$scope_unavail_bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$scope_unavail_bin/systemd-run"

logs_dir="$(mktmp_dir "$scratch/fs-runscope-logs.XXXXXX")"

# do_launch PATH SOCKET CFG_DIR BRANCH [extra fork-sandbox.sh args...]
#
# Sets last_out/last_rc/last_run_dir. A fresh project, clone target and
# handoff are built for every call, so runs never share a workspace.
# FS_TEST_TMUX_SOCKET is set directly on this command, a plain parent/child
# env inheritance down to the tmux wrapper script above -- unlike
# FS_SCOPE_STUB_LOG, this one IS a direct child of this exact invocation, so
# passing it as a var is fine here.
last_out=""
last_rc=0
last_run_dir=""
# Extra VAR=value pairs to inject into the launcher's own environment for the
# NEXT do_launch call only -- used by the bus-env regression test below to
# hand the launcher (and its probe) XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS
# without changing every other call site. Reset after each use.
extra_launch_env=()
do_launch() {
    local path_val="$1" socket="$2" cfg="$3" branch="$4"
    shift 4
    local home proj clone handoff_dir handoff
    home="$(mktmp_dir "$scratch/fs-runscope-home.XXXXXX")"
    proj="$(new_project "$home")"
    clone="$(mktmp_dir "$scratch/fs-runscope-clone.XXXXXX")"
    rmdir "$clone"
    handoff_dir="$(mktmp_dir "$scratch/fs-runscope-ho.XXXXXX")"
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    last_out="$(env HOME="$home" PATH="$path_val" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FS_TEST_TMUX_SOCKET="$socket" "${extra_launch_env[@]}" \
        timeout 60 "$launcher" --harness claude --branch "$branch" \
        --clone-dir "$clone" "$@" "$proj" "$handoff" 2>&1)"
    last_rc=$?
    last_run_dir="$(printf '%s\n' "$last_out" | sed -n 's/^  run dir:  *//p' | head -1)"
    extra_launch_env=()
}

path_avail="$scope_avail_bin:$stub_bin:$PATH"
path_unavail="$scope_unavail_bin:$stub_bin:$PATH"

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: scope available, no RUN_MEMORY_MAX ==\n'
# ---------------------------------------------------------------------------

scope_log1="$logs_dir/scope1.log"
write_scope_stub "$scope_log1"
cfg1="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
socket1="fs-runscope-1-$$"
tmux_sockets+=("$socket1")

do_launch "$path_avail" "$socket1" "$cfg1" fs-runscope-b1
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "launch succeeds with a wrapped scope available"
    wait_for_exit_code "$last_run_dir" \
        || no "the run finishes" "no $last_run_dir/exit-code after waiting"

    scope_env="$(read_env_field "$last_run_dir" scope)"
    case "$scope_env" in
        fork-sandbox-run-*) ok "run.env records the scope unit, not 'none'" ;;
        *) no "run.env records the scope unit, not 'none'" "scope=$scope_env" ;;
    esac

    log1="$(cat "$scope_log1" 2>/dev/null || true)"
    contains "the wrapped command carries OOMPolicy=continue" "OOMPolicy=continue" "$log1"
    contains "the wrapped command carries --collect" "--collect" "$log1"
    if grep -q -- '--unit=fork-sandbox-run-' <<< "$log1"; then
        ok "the wrapped command carries a deterministic, valid --unit"
    else
        no "the wrapped command carries a deterministic, valid --unit" "$log1"
    fi
    lacks "no MemoryMax when RUN_MEMORY_MAX is unset" "MemoryMax" "$log1"
    if [[ "$(tail -n1 <<< "$log1")" == "$last_run_dir/run.sh" ]]; then
        ok "the wrapped command still execs the real runner after '--'"
    else
        no "the wrapped command still execs the real runner after '--'" \
            "last line: $(tail -n1 <<< "$log1")"
    fi

    sandbox_log_content="$(cat "$last_run_dir/sandbox.log" 2>/dev/null || true)"
    contains "sandbox.log records the scope note" \
        "running inside systemd scope fork-sandbox-run-" "$sandbox_log_content"
    lacks "sandbox.log's scope note omits MemoryMax when unset" \
        "MemoryMax" "$sandbox_log_content"
else
    no "launch succeeds with a wrapped scope available" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: pane systemd-run gets the bus env even when the tmux server predates it ==\n'
# ---------------------------------------------------------------------------

# The launcher-side probe runs in the launcher's OWN environment, but the
# wrapped systemd-run that actually matters runs as the tmux PANE's command
# instead, and a pane does not inherit the client's environment -- only
# whatever the tmux SERVER itself started with (see the comment beside
# run_scope_pane_env in scripts/fork-sandbox.sh). A tmux server that has been
# running since before this login, or one started by cron/ssh without
# pam_systemd, can predate XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS entirely
# even on a host where the launcher itself has both and the probe passes.
#
# This stub mimics real systemd-run --user's dependency on those two
# variables: it fails outright when either is unset, and execs through to
# whatever follows '--' when both are set -- so it fails exactly when a real
# systemd-run would fail to connect to the user bus.
scope_busaware_bin="$(mktmp_dir "$scratch/fs-runscope-busaware.XXXXXX")"
cat > "$scope_busaware_bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
if [[ -z "${XDG_RUNTIME_DIR:-}" || -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    echo "systemd-run: Failed to connect to bus: No such file or directory" >&2
    exit 1
fi
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
        exec "${args[@]:$((i+1))}"
    fi
done
exec "${args[-1]}"
STUB
chmod +x "$scope_busaware_bin/systemd-run"
path_busaware="$scope_busaware_bin:$stub_bin:$PATH"

cfg_bus="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
socket_bus="fs-runscope-bus-$$"
tmux_sockets+=("$socket_bus")
fake_xdg="$(mktmp_dir "$scratch/fs-runscope-xdg.XXXXXX")"
fake_dbus="unix:path=$fake_xdg/bus"

# Start this socket's tmux SERVER first, deliberately without the bus vars,
# and keep it alive with a long-running warmup session -- a bare
# `start-server` exits again immediately once it sees no sessions exist, which
# would let the launcher's own call below start a FRESH server (with the
# launcher's environment, vars and all) and defeat the whole point. This is
# the server the launcher's own `tmux new-session -d` below finds already
# running, and whose pane inherits ITS environment, not the launcher's.
env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
    "$real_tmux" -L "$socket_bus" new-session -d -s warmup -n warmup 'sleep 6000'

# The launcher itself DOES have both vars (so its own probe passes) --
# they're injected here, into the launcher's environment only, not the
# server's.
extra_launch_env=(
    "XDG_RUNTIME_DIR=$fake_xdg"
    "DBUS_SESSION_BUS_ADDRESS=$fake_dbus"
)
do_launch "$path_busaware" "$socket_bus" "$cfg_bus" fs-runscope-bus
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "launch succeeds when the tmux server predates the bus vars"
    if wait_for_exit_code "$last_run_dir"; then
        ok "the run actually starts and finishes (the pane's systemd-run reached the bus)"
    else
        no "the run actually starts and finishes (the pane's systemd-run reached the bus)" \
            "no $last_run_dir/exit-code after waiting -- the pane's systemd-run likely failed to connect to the bus and the session died silently"
    fi
else
    no "launch succeeds when the tmux server predates the bus vars" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: bus env reaches the pane without tmux new-session -e ==\n'
# ---------------------------------------------------------------------------

# `new-session -e` only exists from tmux 3.2 on (upstream tmux's CHANGES,
# "CHANGES FROM 3.1c TO 3.2") -- RHEL/Rocky/Alma 8 (2.7), Debian 11 (3.1c)
# and Ubuntu 20.04 (3.0a) all predate it. This sandbox's own real tmux is
# 3.7b regardless of host, so the only way to catch a regression back to
# `-e` is a stub that rejects it outright, the same way an old tmux would
# with "unknown option -- e".
tmux_no_e_bin="$(mktmp_dir "$scratch/fs-runscope-tmux-no-e.XXXXXX")"
cat > "$tmux_no_e_bin/tmux" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "-e" ]]; then
        echo "tmux: unknown option -- e" >&2
        exit 1
    fi
done
exec "$real_tmux" -L "\${FS_TEST_TMUX_SOCKET:?}" "\$@"
STUB
chmod +x "$tmux_no_e_bin/tmux"
path_busaware_no_e="$tmux_no_e_bin:$scope_busaware_bin:$stub_bin:$PATH"

cfg_bus_no_e="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
socket_bus_no_e="fs-runscope-bus-noe-$$"
tmux_sockets+=("$socket_bus_no_e")
fake_xdg_no_e="$(mktmp_dir "$scratch/fs-runscope-xdg.XXXXXX")"
fake_dbus_no_e="unix:path=$fake_xdg_no_e/bus"

env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
    "$real_tmux" -L "$socket_bus_no_e" new-session -d -s warmup -n warmup 'sleep 6000'

extra_launch_env=(
    "XDG_RUNTIME_DIR=$fake_xdg_no_e"
    "DBUS_SESSION_BUS_ADDRESS=$fake_dbus_no_e"
)
do_launch "$path_busaware_no_e" "$socket_bus_no_e" "$cfg_bus_no_e" fs-runscope-bus-noe
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "launch succeeds on a tmux that rejects -e"
    if wait_for_exit_code "$last_run_dir"; then
        ok "the run finishes (bus env reached the pane via the command line, not -e)"
    else
        no "the run finishes (bus env reached the pane via the command line, not -e)" \
            "no $last_run_dir/exit-code after waiting -- the pane's systemd-run likely failed to connect to the bus"
    fi
else
    no "launch succeeds on a tmux that rejects -e" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: RUN_MEMORY_MAX adds MemoryMax + MemorySwapMax=0 ==\n'
# ---------------------------------------------------------------------------

for spec in 8G 60%; do
    scope_log="$logs_dir/scope-mem-$spec.log"
    write_scope_stub "$scope_log"
    cfg="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
    printf 'RUN_MEMORY_MAX=%s\n' "$spec" > "$cfg/limits.env"
    socket="fs-runscope-mem-$spec-$$"
    tmux_sockets+=("$socket")

    do_launch "$path_avail" "$socket" "$cfg" "fs-runscope-mem-$spec"
    if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
        wait_for_exit_code "$last_run_dir" \
            || no "RUN_MEMORY_MAX=$spec: the run finishes" \
                "no $last_run_dir/exit-code after waiting"
        log="$(cat "$scope_log" 2>/dev/null || true)"
        contains "RUN_MEMORY_MAX=$spec: MemoryMax=$spec is set" "MemoryMax=$spec" "$log"
        contains "RUN_MEMORY_MAX=$spec: MemorySwapMax=0 is set" "MemorySwapMax=0" "$log"
        mem_env="$(read_env_field "$last_run_dir" memory_max)"
        check_label="RUN_MEMORY_MAX=$spec: run.env records memory_max"
        if [[ "$mem_env" == "$spec" ]]; then ok "$check_label"; else no "$check_label" "memory_max=$mem_env"; fi
    else
        no "RUN_MEMORY_MAX=$spec: launch succeeds" "$last_out"
    fi
done

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: invalid RUN_MEMORY_MAX values are refused ==\n'
# ---------------------------------------------------------------------------

# These are refused before anything is created (well before the tmux/scope
# code runs at all -- before mktemp -d even makes the run dir, same as
# fork-sandbox-review-harness-test.sh's own before/after run-dir-count
# check for a missing credential), so the plain stub PATH -- no scope stub
# needed either way -- and no waiting for a run to finish.
plain_path="$stub_bin:$PATH"
for bad in "8GB" "8G;true" "" "-1" "150%" "0" "0%"; do
    cfg="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
    printf 'RUN_MEMORY_MAX=%s\n' "$bad" > "$cfg/limits.env"
    label="RUN_MEMORY_MAX='$bad' is refused at launch"
    before="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
        -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
    do_launch "$plain_path" "fs-runscope-bad-$$" "$cfg" "fs-runscope-bad"
    after="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
        -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
    if (( last_rc != 0 )); then
        ok "$label"
    else
        no "$label" "expected a non-zero exit; got 0"
    fi
    contains "$label: names the key and the file" "RUN_MEMORY_MAX" "$last_out"
    contains "$label: names limits.env" "limits.env" "$last_out"
    if [[ "$before" == "$after" ]]; then
        ok "$label: no run dir left behind"
    else
        no "$label: no run dir left behind" "run dir count $before -> $after"
    fi
done

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: scope unavailable, silent without RUN_MEMORY_MAX ==\n'
# ---------------------------------------------------------------------------

cfg_u1="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
socket_u1="fs-runscope-u1-$$"
tmux_sockets+=("$socket_u1")

do_launch "$path_unavail" "$socket_u1" "$cfg_u1" fs-runscope-u1
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "launch succeeds even with no usable systemd scope"
    wait_for_exit_code "$last_run_dir" \
        || no "the run finishes" "no $last_run_dir/exit-code after waiting"
    scope_env="$(read_env_field "$last_run_dir" scope)"
    if [[ "$scope_env" == "none" ]]; then
        ok "run.env records scope=none"
    else
        no "run.env records scope=none" "scope=$scope_env"
    fi
    lacks "no warning is printed when RUN_MEMORY_MAX was never set" "Warning:" "$last_out"
else
    no "launch succeeds even with no usable systemd scope" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: scope unavailable + RUN_MEMORY_MAX warns exactly once ==\n'
# ---------------------------------------------------------------------------

cfg_u2="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
printf 'RUN_MEMORY_MAX=8G\n' > "$cfg_u2/limits.env"
socket_u2="fs-runscope-u2-$$"
tmux_sockets+=("$socket_u2")

do_launch "$path_unavail" "$socket_u2" "$cfg_u2" fs-runscope-u2
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "a memory cap that cannot be applied does not fail the launch"
    wait_for_exit_code "$last_run_dir" \
        || no "the run finishes" "no $last_run_dir/exit-code after waiting"
    warn_count="$(grep -c '^Warning:' <<< "$last_out" || true)"
    if [[ "$warn_count" == "1" ]]; then
        ok "exactly one warning is printed"
    else
        no "exactly one warning is printed" "saw $warn_count 'Warning:' line(s)"
    fi
    contains "the warning names RUN_MEMORY_MAX and its value" "RUN_MEMORY_MAX=8G" "$last_out"
    contains "the warning says the cap was NOT applied" "NOT applied" "$last_out"
    scope_env="$(read_env_field "$last_run_dir" scope)"
    if [[ "$scope_env" == "none" ]]; then
        ok "run.env still records scope=none"
    else
        no "run.env still records scope=none" "scope=$scope_env"
    fi
else
    no "a memory cap that cannot be applied does not fail the launch" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: a user manager that refuses MemoryMax falls back at the probe ==\n'
# ---------------------------------------------------------------------------
# The probe must carry the same properties as the real call: a manager that
# accepts a bare scope but refuses MemoryMax would otherwise pass the probe
# and fail inside the pane, where the run would vanish without an exit-code.

scope_nomem_bin="$(mktmp_dir "$scratch/fs-runscope-nomem.XXXXXX")"
cat > "$scope_nomem_bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for a in "${args[@]}"; do
    [[ "$a" == MemoryMax=* ]] && { echo "systemd-run: Unit has no memory controller" >&2; exit 1; }
done
for i in "${!args[@]}"; do
    [[ "${args[$i]}" == "--" ]] && exec "${args[@]:$((i+1))}"
done
exec "${args[-1]}"
STUB
chmod +x "$scope_nomem_bin/systemd-run"
cfg_nm="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
printf 'RUN_MEMORY_MAX=8G\n' > "$cfg_nm/limits.env"
socket_nm="fs-runscope-nm-$$"
tmux_sockets+=("$socket_nm")

do_launch "$scope_nomem_bin:$stub_bin:$PATH" "$socket_nm" "$cfg_nm" fs-runscope-nm
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "a refused MemoryMax does not fail the launch"
    if wait_for_exit_code "$last_run_dir"; then
        ok "the run still starts and finishes"
    else
        no "the run still starts and finishes" "no $last_run_dir/exit-code after waiting"
    fi
    contains "the warning says the cap was NOT applied" "NOT applied" "$last_out"
    scope_env="$(read_env_field "$last_run_dir" scope)"
    if [[ "$scope_env" == "none" ]]; then
        ok "run.env records scope=none"
    else
        no "run.env records scope=none" "scope=$scope_env"
    fi
else
    no "a refused MemoryMax does not fail the launch" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --foreground gets the same wrapping ==\n'
# ---------------------------------------------------------------------------

scope_log_fg="$logs_dir/scope-fg.log"
write_scope_stub "$scope_log_fg"
cfg_fg="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"

# No tmux involved on this path at all -- the socket is irrelevant, but
# do_launch always sets it, harmlessly.
do_launch "$path_avail" "fs-runscope-fg-unused-$$" "$cfg_fg" fs-runscope-fg --foreground
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "--foreground launch completes"
    log_fg="$(cat "$scope_log_fg" 2>/dev/null || true)"
    contains "--foreground: the exec is wrapped with OOMPolicy=continue" \
        "OOMPolicy=continue" "$log_fg"
    if grep -q -- '--unit=fork-sandbox-run-' <<< "$log_fg"; then
        ok "--foreground: the wrapped exec carries a valid --unit"
    else
        no "--foreground: the wrapped exec carries a valid --unit" "$log_fg"
    fi
    if [[ "$(tail -n1 <<< "$log_fg")" == "$last_run_dir/run.sh" ]]; then
        ok "--foreground: the wrapped exec still runs the real runner"
    else
        no "--foreground: the wrapped exec still runs the real runner" \
            "last line: $(tail -n1 <<< "$log_fg")"
    fi
    scope_env="$(read_env_field "$last_run_dir" scope)"
    case "$scope_env" in
        fork-sandbox-run-*) ok "--foreground: run.env still records the scope unit" ;;
        *) no "--foreground: run.env still records the scope unit" "scope=$scope_env" ;;
    esac
else
    no "--foreground launch completes" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: RUN_SCOPE=off disables the scope outright ==\n'
# ---------------------------------------------------------------------------

# path_avail is used here on purpose: a working scope stub is on PATH, so
# this only passes if RUN_SCOPE=off is actually short-circuiting the probe,
# not merely riding on an unavailable systemd-run.
scope_log_off="$logs_dir/scope-off.log"
cfg_off="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
printf 'RUN_SCOPE=off\n' > "$cfg_off/limits.env"
socket_off="fs-runscope-off-$$"
tmux_sockets+=("$socket_off")

do_launch "$path_avail" "$socket_off" "$cfg_off" fs-runscope-off
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    ok "launch succeeds with RUN_SCOPE=off"
    wait_for_exit_code "$last_run_dir" \
        || no "the run finishes" "no $last_run_dir/exit-code after waiting"
    if [[ -e "$scope_log_off" ]]; then
        no "RUN_SCOPE=off: systemd-run is never invoked" \
            "stub log exists: $(cat "$scope_log_off")"
    else
        ok "RUN_SCOPE=off: systemd-run is never invoked"
    fi
    scope_env="$(read_env_field "$last_run_dir" scope)"
    if [[ "$scope_env" == "none" ]]; then
        ok "RUN_SCOPE=off: run.env records scope=none"
    else
        no "RUN_SCOPE=off: run.env records scope=none" "scope=$scope_env"
    fi
    lacks "RUN_SCOPE=off alone prints no warning" "Warning:" "$last_out"
else
    no "launch succeeds with RUN_SCOPE=off" "$last_out"
fi

cfg_off_mem="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
printf 'RUN_SCOPE=off\nRUN_MEMORY_MAX=8G\n' > "$cfg_off_mem/limits.env"
socket_off_mem="fs-runscope-offmem-$$"
tmux_sockets+=("$socket_off_mem")

do_launch "$path_avail" "$socket_off_mem" "$cfg_off_mem" fs-runscope-offmem
if (( last_rc == 0 )) && [[ -n "$last_run_dir" ]]; then
    wait_for_exit_code "$last_run_dir" \
        || no "RUN_SCOPE=off + RUN_MEMORY_MAX: the run finishes" \
            "no $last_run_dir/exit-code after waiting"
    warn_count="$(grep -c '^Warning:' <<< "$last_out" || true)"
    if [[ "$warn_count" == "1" ]]; then
        ok "RUN_SCOPE=off + RUN_MEMORY_MAX warns exactly once"
    else
        no "RUN_SCOPE=off + RUN_MEMORY_MAX warns exactly once" \
            "saw $warn_count 'Warning:' line(s)"
    fi
    contains "RUN_SCOPE=off warning names RUN_MEMORY_MAX and its value" \
        "RUN_MEMORY_MAX=8G" "$last_out"
    scope_env="$(read_env_field "$last_run_dir" scope)"
    if [[ "$scope_env" == "none" ]]; then
        ok "RUN_SCOPE=off + RUN_MEMORY_MAX: run.env still records scope=none"
    else
        no "RUN_SCOPE=off + RUN_MEMORY_MAX: run.env still records scope=none" \
            "scope=$scope_env"
    fi
else
    no "RUN_SCOPE=off + RUN_MEMORY_MAX: launch succeeds" "$last_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: unrecognized RUN_SCOPE values are refused ==\n'
# ---------------------------------------------------------------------------

for bad in "OFF" "0" "false" "on" ""; do
    cfg="$(mktmp_dir "$scratch/fs-runscope-cfg.XXXXXX")"
    printf 'RUN_SCOPE=%s\n' "$bad" > "$cfg/limits.env"
    label="RUN_SCOPE='$bad' is refused at launch"
    before="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
        -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
    do_launch "$plain_path" "fs-runscope-badscope-$$" "$cfg" "fs-runscope-badscope"
    after="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
        -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
    if (( last_rc != 0 )); then
        ok "$label"
    else
        no "$label" "expected a non-zero exit; got 0"
    fi
    contains "$label: names the key and the file" "RUN_SCOPE" "$last_out"
    contains "$label: names limits.env" "limits.env" "$last_out"
    if [[ "$before" == "$after" ]]; then
        ok "$label: no run dir left behind"
    else
        no "$label: no run dir left behind" "run dir count $before -> $after"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
