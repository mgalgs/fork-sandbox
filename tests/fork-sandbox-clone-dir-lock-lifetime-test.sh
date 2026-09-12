#!/usr/bin/env bash
# fork-sandbox-clone-dir-lock-lifetime-test.sh -- the --clone-dir workspace
# lock's lifetime must match the RUN, not the launcher and not tmux.
#
# Usage: tests/fork-sandbox-clone-dir-lock-lifetime-test.sh
#
# Every other --clone-dir test launches with --foreground, where the launcher
# process itself runs the whole session and a lock held in that process is,
# incidentally, held for the run's whole life. The default launch path is the
# opposite: without --foreground the launcher hands off to a detached tmux
# session and returns almost immediately, which is how the postmaster always
# calls it (see fork-sandbox-postmaster.sh). This suite covers exactly that
# path: it launches without --foreground, against a tmux server that already
# has an unrelated session on it (a fleet box's tmux server, awake past its
# first run) rather than the launcher's own, and checks the lock file's state
# from a THIRD process while the run is still in flight and again after it
# ends -- the same way a concurrent second launcher or `fleet teardown` would
# see it.
#
# tmux is driven on a dedicated, throwaway server (-L), never the caller's
# own default server, so this suite cannot disrupt a real tmux session on the
# machine it runs on.
#
# No real sandbox is ever built and no real claude is ever run.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

export FORK_SANDBOX_RUN_SOURCE=test

real_tmux="$(command -v tmux)"
if [[ -z "$real_tmux" ]]; then
    echo "tmux not found; skipping (nothing to test)."
    exit 0
fi

pass=0
fail=0
tmpdirs=()
tmux_socket=""

cleanup() {
    local d
    if [[ -n "$tmux_socket" ]]; then
        "$real_tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
    fi
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

scratch="/var/tmp/claude-scratch"
mkdir -p "$scratch/forks"

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

new_project() {
    local home="$1" d
    mkdir -p "$home/src"
    d="$(mktemp -d "$home/src/fs-locklife-test.XXXXXX")"
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

# A stub tmux that always runs on our own throwaway server, never the
# caller's default one: every real tmux argument is forwarded unchanged,
# with -L inserted first. FS_TEST_TMUX_SOCKET is read at call time, not
# baked in, so the launcher's own `tmux new-session -d` picks up whatever
# socket the test set for that particular launch.
stub_bin="$(mktmp_dir "$scratch/fs-locklife-stub.XXXXXX")"
cat > "$stub_bin/tmux" <<STUB
#!/usr/bin/env bash
exec "$real_tmux" -L "\${FS_TEST_TMUX_SOCKET:?}" "\$@"
STUB
chmod +x "$stub_bin/tmux"

# A stub claude-sandboxed that stays alive for a bit, so there is a window
# where the run is genuinely in flight to probe the lock during.
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 3
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --clone-dir lock lifetime, detached (tmux) launch ==\n'
# ---------------------------------------------------------------------------

tmux_socket="fs-locklife-$$"
export FS_TEST_TMUX_SOCKET="$tmux_socket"

# Simulate a fleet box's tmux server: already running, with an unrelated
# session on it, before this run's launcher ever calls tmux. A launcher that
# (mis)relies on the new session inheriting an fd from ITS OWN process,
# rather than acquiring the lock from inside the runner it hands off to,
# fails exactly in this configuration: the new session's processes are
# children of this older server, which never had that fd.
"$real_tmux" -L "$tmux_socket" new-session -d -s keepalive -- sleep 120

home="$(mktmp_dir "$scratch/fs-locklife-home.XXXXXX")"
proj="$(new_project "$home")"
clone="$(mktmp_dir "$scratch/fs-locklife-clone.XXXXXX")"
rmdir "$clone"
cfg="$(mktmp_dir "$scratch/fs-locklife-cfg.XXXXXX")"
handoff_dir="$(mktmp_dir "$scratch/fs-locklife-ho.XXXXXX")"
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

launch_out="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
    timeout 60 "$launcher" --harness claude --branch fs-locklife-b \
    --clone-dir "$clone" "$proj" "$handoff" 2>&1)"
launch_rc=$?

run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -1)"
lock_file="$clone/.git/fork-sandbox-lock"

if (( launch_rc == 0 )) && [[ -n "$run_dir" ]]; then
    ok "detached launch against a pre-existing tmux server returns"
else
    no "detached launch against a pre-existing tmux server returns" "$launch_out"
fi

if [[ -n "$run_dir" ]]; then
    # The launcher has already returned (that is what "detached" means), so
    # if anything still holds the lock, it can only be the runner it handed
    # off to -- never this now-dead launcher process.
    for _ in $(seq 1 50); do
        [[ -s "$run_dir/pid" ]] && break
        sleep 0.1
    done

    (
        exec {probe_fd}<>"$lock_file"
        if flock -n "$probe_fd"; then
            flock -u "$probe_fd"
            exit 1
        fi
        exit 0
    )
    if (( $? == 0 )); then
        ok "the workspace is locked while the run is in flight, after the launcher has already exited"
    else
        no "the workspace is locked while the run is in flight, after the launcher has already exited" \
            "flock -n succeeded; nothing holds the lock during a live run"
    fi

    for _ in $(seq 1 100); do
        [[ -s "$run_dir/exit-code" ]] && break
        sleep 0.1
    done
    if [[ -s "$run_dir/exit-code" ]]; then
        ok "the run finishes"
    else
        no "the run finishes" "no $run_dir/exit-code after waiting"
    fi

    # The pre-existing tmux server (and its unrelated 'keepalive' session)
    # is still up at this point -- exactly the configuration where a lock
    # tied to tmux's own lifetime, rather than the run's, would wedge this
    # seat for good.
    if "$real_tmux" -L "$tmux_socket" has-session -t keepalive 2>/dev/null; then
        ok "the tmux server outlives this run (unrelated session still up)"
    else
        no "the tmux server outlives this run (unrelated session still up)" \
            "expected the keepalive session to still be there"
    fi

    (
        exec {probe_fd}<>"$lock_file"
        flock -n "$probe_fd"
    )
    if (( $? == 0 )); then
        ok "the lock is free again once the run ends, even though the tmux server is still up"
    else
        no "the lock is free again once the run ends, even though the tmux server is still up" \
            "flock -n failed; the workspace is wedged"
    fi
else
    no "the workspace is locked while the run is in flight, after the launcher has already exited" \
        "no run dir to probe"
    no "the run finishes" "no run dir to probe"
    no "the tmux server outlives this run (unrelated session still up)" "no run dir to probe"
    no "the lock is free again once the run ends, even though the tmux server is still up" \
        "no run dir to probe"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
