#!/usr/bin/env bash
# fork-sandbox-stop.sh — :approved: Abandon a local fork-sandbox run, with a ledger trail
#
# Usage: fork-sandbox-stop.sh [--timeout SECS] <run-dir>
#
# <run-dir> is the run directory fork-sandbox.sh printed when it launched.
# --timeout: seconds to wait for a graceful stop before falling back to a
#            forced one. Default 60.
#
# Before this verb existed, the only way to abandon a run was
# 'tmux kill-session', which leaves no run_end record (a deliberate abandon
# reads exactly like a crash), can strand verified commits in the clone with
# nothing fetched, and has to be typed by hand because the dispatcher has no
# stop verb at all. This closes all three gaps.
#
# What it does depends on the run's own state, read from <run-dir>/pid and
# <run-dir>/exit-code:
#
#   already ended       nothing to do -- says so and exits 0.
#   runner running       sends TERM to the runner's whole process group (a
#                         trap in fork-sandbox.sh sets a flag on TERM and lets
#                         the run's own teardown finish normally: fetch,
#                         zero-commit branch cleanup, summary.json, exit-code,
#                         run-log record). Waits up to --timeout for that
#                         teardown to finish. end_reason: stopped.
#   timeout expires       falls back to the same forced completion below.
#                         end_reason: stop-timeout.
#   runner already dead   (e.g. someone ran 'tmux kill-session' directly)
#                         nothing to signal -- goes straight to the forced
#                         completion, closing the run this verb exists for.
#                         end_reason: salvaged.
#
# The forced completion is host-side: kill the tmux session (timeout path
# only -- a dead runner has none), fetch the branch back into the origin
# repo, remove it if the fetch added no commits, write exit-code 143, write
# a minimal summary.json if the runner never got to write one, and append
# the run-log record -- the same shape fork-sandbox.sh's own teardown
# produces, so the ledger cannot tell a deliberate stop from a crash.
#
# A --k8s run is refused: this verb is local-run machinery only. Stop one
# with 'fork-sandbox k8s rm' instead.
#
# Why this is safe to blanket-approve. Every mutation it makes is one this
# tool already makes on every ordinary run: it fetches the clone's branch
# into the origin repo (the one config-safe way in -- see the comment above
# this script's own fetch, and fork-sandbox.sh's near its own), deletes that
# branch only when the fetch added nothing, and signals a process this same
# tool started. It never runs git inside the clone, never reads stdin, and
# refuses a run directory that is not a real fork-sandbox run (resolved
# first, checked against the run-dir prefix, must hold a run.env).

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

# The GNU flags these scripts use (realpath -e, stat -c) do not exist on the
# BSD tools of the same name. Say so here, before anything is signaled.
fs_require_gnu_tools || exit 1

RUN_DIR_PREFIX="/var/tmp/claude-scratch/forks/claude-fork-sandbox."
# The pre-consolidation location, still accepted so an old run dir can still
# be stopped. New runs never land here.
RUN_DIR_PREFIX_LEGACY="/var/tmp/claude-fork-sandbox."

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

timeout_secs=60
run_dir_arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout needs a value"
            timeout_secs="$2"
            shift 2
            ;;
        --timeout=*)
            timeout_secs="${1#*=}"
            shift
            ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            [[ -z "$run_dir_arg" ]] || die "only one run directory may be given"
            run_dir_arg="$1"
            shift
            ;;
    esac
done

[[ -n "$run_dir_arg" ]] \
    || die "usage: fork-sandbox-stop.sh [--timeout SECS] <run-dir>"
[[ "$timeout_secs" =~ ^[0-9]+$ ]] \
    || die "--timeout must be a non-negative integer number of seconds, got '$timeout_secs'"

# Resolve first, then check the prefix, so a symlink cannot point this at
# something that is not a run directory.
run_dir="$("$FS_REALPATH" -e -- "$run_dir_arg" 2>/dev/null)" \
    || die "'$run_dir_arg' does not exist"
[[ -d "$run_dir" ]] || die "'$run_dir' is not a directory"
[[ "$run_dir" == "$RUN_DIR_PREFIX"* || "$run_dir" == "$RUN_DIR_PREFIX_LEGACY"* ]] \
    || die "'$run_dir' is not a fork-sandbox run directory (expected $RUN_DIR_PREFIX*)"

run_env="$run_dir/run.env"
[[ -L "$run_env" ]] && die "'$run_env' is a symlink; refusing to read it"
[[ -f "$run_env" ]] \
    || die "'$run_dir' has no run.env; it is not a fork-sandbox run directory"

[[ -n "$(fs_read_env_value "$run_env" version || true)" ]] \
    || die "'$run_dir' has no run.env version; it is not a fork-sandbox run directory"

network="$(fs_read_env_value "$run_env" network || true)"
[[ "$network" == "cluster" ]] \
    && die "'$run_dir' is a --k8s run. Stop it with 'fork-sandbox-k8s.sh rm', not this verb."

branch="$(fs_read_env_value "$run_env" branch || true)"
origin_repo="$(fs_read_env_value "$run_env" origin_repo || true)"
clone_dir="$(fs_read_env_value "$run_env" clone_dir || true)"
base_sha="$(fs_read_env_value "$run_env" base_sha || true)"
return_base_sha="$(fs_read_env_value "$run_env" return_base_sha || true)"
# A run.env written before this field existed has none -- fall back to
# base_sha so an old run dir can still be stopped, at the cost of the
# miscount this field exists to fix (identical to base_sha on every run
# except --review-only with a review-base older than the checkout).
[[ -n "$return_base_sha" ]] || return_base_sha="$base_sha"
session="$(fs_read_env_value "$run_env" session || true)"
[[ -n "$branch" && -n "$origin_repo" && -n "$clone_dir" && -n "$base_sha" ]] \
    || die "'$run_dir' has an incomplete run.env (missing branch/origin_repo/clone_dir/base_sha)"

exit_code_file="$run_dir/exit-code"
pid_file="$run_dir/pid"

# Entry state 1: the run is already over. Idempotent no-op, per the brief --
# nothing is rewritten, this is not an error.
if [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]]; then
    rc="$(tr -dc '0-9-' < "$exit_code_file")"
    printf 'run has already ended (exit %s); nothing to stop.\n' "$rc"
    exit 0
fi

[[ -f "$pid_file" && ! -L "$pid_file" ]] \
    || die "'$run_dir' has no pid file yet; the run is still starting. Try again shortly."
pid="$(tr -dc '0-9' < "$pid_file")"
[[ -n "$pid" ]] || die "'$pid_file' does not name a process id"

runner_alive=0
if kill -0 "$pid" 2>/dev/null; then
    runner_alive=1
fi

# Bring the work back and close the ledger, host-side. Shared by the timeout
# fallback and the runner-dead salvage path: both complete a run that will
# never reach its own teardown again.
#
# The fetch is fork-sandbox.sh's own idiom, verbatim -- see its "Bring the
# work back." comment near its teardown's fetch-back block for why fetch is
# the one way into the real repo that cannot be turned into code execution
# by the clone's config: the clone's git config is sandbox-writable, and a
# key like core.fsmonitor runs on the HOST, so nothing here ever runs git
# inside the clone. Every git command below runs in the origin repo.
complete_run_host_side() {
    local reason="$1" kill_tmux="$2"
    local fetched=0 n_commits=0 removed=0 head_now="" fetch_failed=0

    if [[ "$kill_tmux" == 1 && -n "$session" ]]; then
        # Exact-match: without the '=' prefix tmux prefix/fnmatch-matches
        # the target, and can kill a DIFFERENT session whose name happens
        # to start with this one (e.g. "cc-sbx-x" matching "cc-sbx-x-2").
        # fork-sandbox.sh's own has-session check uses the same "=$name"
        # idiom (see fork-sandbox.sh's session-existence check).
        tmux kill-session -t "=$session" 2>/dev/null || true
    fi

    if (cd "$origin_repo" && git fetch --quiet "$clone_dir" "$branch:$branch") 2>/dev/null; then
        fetched=1
    else
        fetch_failed=1
        printf 'fork-sandbox-stop: could not fetch branch %s back from %s into %s -- the work is still there, not lost, but NOT yet in your repo. Retry by hand once the problem is fixed:\n  (cd %q && git fetch %q %q:%q)\n' \
            "$branch" "$clone_dir" "$origin_repo" "$origin_repo" "$clone_dir" "$branch" "$branch" >&2
    fi

    if (( fetched )); then
        n_commits="$( (cd "$origin_repo" && git rev-list --count "$return_base_sha..$branch") 2>/dev/null || printf 0 )"
        if [[ "$n_commits" == "0" ]]; then
            head_now="$( (cd "$origin_repo" && git rev-parse "$branch") 2>/dev/null || true )"
            if [[ "$head_now" == "$return_base_sha" ]] \
                && (cd "$origin_repo" && git branch -q -D "$branch") >/dev/null 2>&1; then
                removed=1
            fi
        fi
    fi

    if [[ -L "$exit_code_file" ]]; then
        printf 'fork-sandbox-stop: refusing to write exit-code through a symlink at %s\n' "$exit_code_file" >&2
    else
        printf '143\n' > "$exit_code_file"
    fi

    # No stub summary.json is fabricated here: a fabricated one holding only
    # end_reason/ended_at/branch would suppress sandbox-run-log.py record's
    # own no-summary fallback (which fills in harness/model/exit_code from
    # run.env + the exit-code file), producing a WORSE record than writing
    # nothing. Pass --end-reason instead, which record uses only when the
    # run truly left no summary.json to read one from.
    #
    # Best-effort, same as the runner's own call: a failed append must not
    # fail the stop.
    "$script_dir/sandbox-run-log.py" record --run-dir "$run_dir" --end-reason "$reason" \
        >/dev/null 2>&1 \
        || printf 'fork-sandbox-stop: run-log append failed\n' >&2

    if (( fetch_failed )); then
        printf 'end_reason: %s; branch %s NOT fetched back -- see the fetch failure above.\n' \
            "$reason" "$branch"
        return 1
    fi

    printf 'end_reason: %s; branch %s, %s new commit(s)%s.\n' \
        "$reason" "$branch" "$n_commits" \
        "$( (( removed )) && printf ', branch removed (no new commits)' || true )"
    return 0
}

if (( ! runner_alive )); then
    # Entry state 3: the runner is gone and never wrote an exit code -- an
    # abandoned run, e.g. someone already ran 'tmux kill-session' by hand.
    # Nothing to signal; go straight to the same completion the timeout path
    # uses, minus the kill-session (there is no session left to kill, or one
    # this run never touched).
    if complete_run_host_side salvaged 0; then
        exit 0
    else
        exit 1
    fi
fi

# Entry state 2: the runner is alive. Whether to signal its process GROUP or
# just the runner's own pid depends on whether the runner LEADS that group --
# see the leadership branch below.
pgid="$( { ps -o pgid= -p "$pid" 2>/dev/null || true; } | tr -d '[:space:]')"
[[ -n "$pgid" ]] \
    || die "the runner process ($pid) vanished before it could be signaled. Nothing was sent; run 'fork-sandbox stop' again to check its new state."
# Re-verify immediately before signaling, rather than trust the read above:
# refuse if the pid is gone, do not guess.
if ! kill -0 "$pid" 2>/dev/null; then
    die "the runner process ($pid) vanished before it could be signaled. Nothing was sent; run 'fork-sandbox stop' again to check its new state."
fi
pgid_now="$( { ps -o pgid= -p "$pid" 2>/dev/null || true; } | tr -d '[:space:]')"
[[ -n "$pgid_now" && "$pgid_now" == "$pgid" ]] \
    || die "the runner process ($pid)'s process group changed while stopping; refusing to guess which group to signal. Run 'fork-sandbox stop' again."

if [[ "$pgid_now" == "$pid" ]]; then
    # The runner leads its own process group -- the normal case, a detached
    # tmux session's foreground command. A bash TERM trap does not fire
    # while a foreground child runs, so signaling only the runner's own pid
    # would do nothing until whichever harness leg is running happens to
    # return -- which can be an hour away. Signal the whole group instead:
    # the harness leg's child gets TERM directly and dies, the foreground
    # command returns, and the runner's own deferred trap
    # (fork-sandbox.sh's `trap 'stop_requested=1' TERM`) then runs and lets
    # its existing teardown finish normally.
    kill -TERM -- "-$pgid_now" 2>/dev/null \
        || die "could not signal process group $pgid_now"
else
    # A --foreground run inherits its CALLER's process group instead of
    # leading its own -- there is no group here that belongs to the runner
    # alone, so a group signal would TERM the launching shell and its
    # siblings too. Signal the runner's own pid instead. Its TERM trap will
    # not fire until the current foreground leg returns on its own (a bash
    # trap cannot interrupt a running foreground child), so a foreground
    # stop is best-effort-prompt rather than immediate -- correct behaviour
    # here, not a bug, and far better than killing the caller.
    kill -TERM "$pid" 2>/dev/null \
        || die "could not signal the runner ($pid)"
fi

waited=0
while (( waited < timeout_secs )); do
    [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]] && break
    sleep 1
    waited=$(( waited + 1 ))
done

if [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]]; then
    rc="$(tr -dc '0-9-' < "$exit_code_file")"
    printf 'stopped gracefully (exit %s) after %ss.\n' "$rc" "$waited"
    exit 0
fi

# Timeout expired: fall back to the violent path that exists today, but
# still owe a run_end -- distinguishable from a clean stop -- instead of
# leaving the gap this verb exists to close merely relocated.
printf 'timed out after %ss waiting for a graceful stop; forcing it.\n' "$timeout_secs" >&2
if complete_run_host_side stop-timeout 1; then
    exit 0
else
    exit 1
fi
