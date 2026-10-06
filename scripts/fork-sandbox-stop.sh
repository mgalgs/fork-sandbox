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
#   already ended       nothing to do -- says so and exits 0, UNLESS this
#                         run's own tidy-history leg snapshotted an
#                         approved head and has not yet published it (the
#                         runner writes exit-code well before it reaches
#                         its own tidy-aware publish -- see
#                         resolve_tidy_safe_sha's own header), in which
#                         case this confirms the approved or verified
#                         history actually reached the branch, publishing
#                         it by sha if not. Once that publish has landed,
#                         this stays the pure no-op above even if the
#                         branch has since moved -- that is the
#                         integrator's business, not this verb's.
#   runner running       a detached-tmux run (pgid == pid, the normal case)
#                         gets TERM'd as a group so the harness leg's
#                         foreground child dies and the runner's own
#                         deferred trap can run; a --foreground run (pgid
#                         != pid, no group of its own to signal) gets its
#                         pid TERM'd alone so the caller's shell and its
#                         siblings are never touched. Either way, the tidy
#                         leg's own process group (kill_tidy_leg_pgid,
#                         below) is TERM'd too, verified against the pid
#                         and start time fork-sandbox.sh recorded for it --
#                         GNU timeout (the tidy leg's wall-clock limit)
#                         puts that leg in a group the runner's own TERM
#                         never reaches on its own. A trap in fork-sandbox.sh
#                         sets a flag on TERM and lets the run's own
#                         teardown finish normally: fetch, zero-commit
#                         branch cleanup,
#                         summary.json, exit-code, run-log record. Waits
#                         (polling for the runner
#                         process to actually exit -- or, since a
#                         --keep-session run's teardown ends in `exec
#                         "$user_shell"`, which keeps its pid alive under a
#                         new image forever, for its summary.json to appear
#                         instead, the same "teardown truly finished" signal
#                         without needing the pid to ever exit) up to
#                         --timeout for that teardown to finish. Once it
#                         has, the branch's fetched-back state is confirmed
#                         by repeating the runner's own fetch rather than
#                         trusting exit-code alone -- a runner whose own
#                         internal fetch-back silently failed must not read
#                         as a clean stop. The repeat is NOT idempotent on
#                         its own once the runner has already removed a
#                         zero-commit branch from the origin repo (the
#                         clone still holds the ref, so re-fetching it would
#                         resurrect exactly what the runner just deleted),
#                         so the same zero-commit removal the forced path
#                         applies is applied again here too. When this run's
#                         tidy-history leg ever touched the branch, "repeat
#                         the runner's own fetch" never means a plain
#                         `git fetch` from the clone: see fetch_branch_back's
#                         own header comment for why and how the approved or
#                         verified history is published by sha instead.
#                         end_reason: stopped.
#   runner dies mid-wait   without ever writing exit-code (e.g. an
#                         external kill this verb did not itself perform)
#                         -- none of its own teardown can be trusted to
#                         have run. Falls through to the same forced
#                         completion as a timeout, promptly rather than
#                         waiting out the rest of --timeout.
#                         end_reason: stop-timeout.
#   timeout expires       falls back to the same forced completion below.
#                         end_reason: stop-timeout.
#   runner already dead   (e.g. someone ran 'tmux kill-session' directly)
#                         nothing to signal -- goes straight to the forced
#                         completion, closing the run this verb exists for.
#                         end_reason: salvaged.
#
# The forced completion is host-side: exact-match kill the tmux session
# (timeout path only -- a dead runner has none), then KILL the runner
# outright (group or pid, whichever it leads) if it is still alive so the
# rest of this does not race a still-writing process, TERM-then-KILL the
# tidy leg's own group the same way the graceful path does
# (kill_tidy_leg_pgid), bring the branch back into the origin repo -- the
# tidy-aware way, same as the graceful path above, never a blind fetch
# from the clone when this run's tidy leg might have left it holding a
# still-in-progress or rejected rewrite -- remove the branch if that added
# no commits, write exit-code 143, pass --end-reason to the run-log
# record so its own
# no-summary fallback fills in harness/model/exit_code (no summary.json is
# fabricated here), and append that record -- the same shape
# fork-sandbox.sh's own teardown produces, so the ledger cannot tell a
# deliberate stop from a crash.
#
# A --k8s run is refused: this verb is local-run machinery only. Stop one
# with 'fork-sandbox k8s rm' instead.
#
# Why this is safe to blanket-approve. Every mutation it makes is one this
# tool already makes on every ordinary run: it fetches the clone's branch
# into the origin repo (the one config-safe way in -- see the comment above
# this script's own fetch, and fork-sandbox.sh's near its own) UNLESS this
# run's tidy leg means that would be the wrong thing to fetch, in which
# case it publishes the approved or verified history by sha instead
# (fetch_branch_back) -- never anything this run's own maintainer did not
# already approve. It deletes the branch only when nothing landed past
# its own commits, and signals only processes descended from the pid this
# run's own pid file names, an exact-match tmux session, and the tidy
# leg's own process group -- and that only once its recorded start time
# and comm are confirmed still live, never a bystander whose pid was
# merely reused. It never runs git inside the clone, never reads stdin, and
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

RUN_DIR_PREFIX="$FS_SCRATCH_ROOT/forks/claude-fork-sandbox."
# The pre-consolidation location, still accepted so an old run dir can still
# be stopped. New runs never land here.
RUN_DIR_PREFIX_LEGACY="$("$FS_REALPATH" -m /var/tmp)/claude-fork-sandbox."

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

# This run's own id for its tidy holding refs (refs/fork-sandbox/tidy/
# <run_id>/approved|candidate) -- fork-sandbox.sh's own runner derives the
# same id the same way, from the same run_dir, so the two agree on where
# this run's snapshots live without either reading the other's state.
run_id="$(basename -- "$run_dir")"

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
# A run.env written before this field existed has none -- fs_apply_upstream
# treats an empty upstream/reason the same as "no upstream resolved" and
# just says so, same as any other run this happens on.
upstream="$(fs_read_env_value "$run_env" upstream || true)"
upstream_reason="$(fs_read_env_value "$run_env" upstream_reason || true)"
session="$(fs_read_env_value "$run_env" session || true)"
[[ -n "$branch" && -n "$origin_repo" && -n "$clone_dir" && -n "$base_sha" ]] \
    || die "'$run_dir' has an incomplete run.env (missing branch/origin_repo/clone_dir/base_sha)"

exit_code_file="$run_dir/exit-code"
pid_file="$run_dir/pid"

# Shared by both places that must tell a fetch failure from a clean "0 new
# commits": the work is still in the clone, not lost, just not yet in the
# origin repo.
warn_fetch_failed() {
    printf 'fork-sandbox-stop: could not fetch branch %s back from %s into %s -- the work is still there, not lost, but NOT yet in your repo. Retry by hand once the problem is fixed:\n  (cd %q && git fetch %q %q:%q)\n' \
        "$branch" "$clone_dir" "$origin_repo" "$origin_repo" "$clone_dir" "$branch" "$branch" >&2
}

# Shared by both places that fetch the branch back and then must decide
# whether to remove it: the runner's own teardown already deletes a
# zero-commit branch from the origin repo (never from the clone, which
# still holds the ref), so re-fetching branch:branch after that deletion
# recreates exactly the ref the runner just removed unless this same
# zero-commit check is applied again here. Sets reconcile_n_commits and
# reconcile_removed for the caller to report.
reconcile_n_commits=0
reconcile_removed=0
reconcile_branch_after_fetch() {
    reconcile_n_commits=0
    reconcile_removed=0
    local head_now=""
    reconcile_n_commits="$( (cd "$origin_repo" && git rev-list --count "$return_base_sha..$branch") 2>/dev/null || printf 0 )"
    if [[ "$reconcile_n_commits" == "0" ]]; then
        head_now="$( (cd "$origin_repo" && git rev-parse "$branch") 2>/dev/null || true )"
        if [[ "$head_now" == "$return_base_sha" ]] \
            && (cd "$origin_repo" && git branch -q -D "$branch") >/dev/null 2>&1; then
            reconcile_removed=1
        fi
    fi
}

# Both places that bring the branch back (complete_run_host_side's
# forced/salvage fetch, and the graceful path's own re-fetch-to-confirm
# below) used to do it with one unconditional
# `git fetch "$clone_dir" "$branch:$branch"`. That is wrong whenever this
# run's tidy leg (fork-sandbox.sh's "The tidy leg") ever touched the
# branch: the clone can hold a rewrite still in progress when the runner
# died mid-leg, or -- when the runner discarded it but its own best-effort
# clone reset failed -- the REJECTED rewrite, sitting right where the
# approved history used to be. Either way, fetching it is the one thing
# that must never happen; the runner already published the right history
# (or is about to, and this is a race this verb must not win).
#
# $run_dir/tidy.json is the source of truth once the leg has returned (it
# is written right after the leg ends, long before the runner's own
# fetch-back -- see fork-sandbox.sh's tidy block): "accepted" means its
# own head_after is the verified rewrite fs_tidy_verify already checked;
# any other ended value with a head_approved names the history the
# maintainer actually approved, which is what every other outcome
# (unchanged, discarded, or a "skipped" that still got as far as
# snapshotting one) publishes. Both shas were fetched into host-side
# holding refs keyed by $run_id during the run, so the objects are still
# in $origin_repo's ODB even once those refs are deleted -- resolving by
# sha, not by ref, is what makes this safe to use after the runner's own
# cleanup has already run.
#
# Once those two refs are BOTH gone, this run's own publish has already
# landed (the runner deletes them only once its own fetched=1 -- see
# fork-sandbox.sh's teardown): there is nothing left to confirm, and
# whatever has happened to the branch since -- the integrator deleted it,
# moved it, anything -- is their business, not this verb's. Trying to
# republish here would either resurrect a branch they deleted on purpose
# or report a collision because they moved it, both wrong once a real
# publish has already happened. tidy_safe_already_published signals
# exactly this case; the caller must do nothing further when it is set.
#
# When tidy.json does not exist yet, the leg itself never returned (the
# runner died while it was still running, or before writing the file) --
# the live holding ref refs/fork-sandbox/tidy/$run_id/approved,
# snapshotted host-side before the leg ever launched, is the only thing
# this verb can trust in that window, and it names the approved (pre-leg)
# head, never the leg's own in-progress, unverified work. Keyed by
# $run_id, derived the same way fork-sandbox.sh's own runner derives it
# (this run's own run_dir, nothing else), so looking it up needs no gate
# on whether this run's pipeline could possibly have made one -- no OTHER
# run could ever have created a ref under this exact id.
#
# Neither case applies to a run with no maintain step, or whose tidy leg
# was skipped before ever snapshotting anything (head_approved stays
# empty) -- there is nothing to protect, and the clone fetch below is
# exactly correct for it, same as before this existed.
#
# Sets tidy_safe_sha (empty when nothing to protect, OR already
# published -- see tidy_safe_already_published), tidy_safe_note (a
# human-readable clause for the caller's own messaging), tidy_safe_ref
# (the live holding ref backing tidy_safe_sha, when there is one still to
# name -- only the tidy.json-less, leg-still-in-flight case has one by
# construction) and tidy_safe_already_published (1 when this run's own
# tidy publish has already landed; the caller must treat this as a pure
# no-op, never fetch, never compare, never republish).
tidy_safe_sha=""
tidy_safe_note=""
tidy_safe_ref=""
tidy_safe_already_published=0
resolve_tidy_safe_sha() {
    tidy_safe_sha=""
    tidy_safe_note=""
    tidy_safe_ref=""
    tidy_safe_already_published=0
    local tidy_json="$run_dir/tidy.json" ended="" head_approved="" head_after=""
    local approved_ref="refs/fork-sandbox/tidy/$run_id/approved"
    local candidate_ref="refs/fork-sandbox/tidy/$run_id/candidate"
    if [[ -f "$tidy_json" && ! -L "$tidy_json" ]]; then
        ended="$(jq -r '.ended // ""' -- "$tidy_json" 2>/dev/null)"
        head_approved="$(jq -r '.head_approved // ""' -- "$tidy_json" 2>/dev/null)"
        head_after="$(jq -r '.head_after // ""' -- "$tidy_json" 2>/dev/null)"
        [[ -n "$head_approved" ]] || return 0
        if [[ -z "$( (cd "$origin_repo" && git rev-parse --verify -q "$approved_ref") 2>/dev/null )" ]] \
            && [[ -z "$( (cd "$origin_repo" && git rev-parse --verify -q "$candidate_ref") 2>/dev/null )" ]]; then
            tidy_safe_already_published=1
            return 0
        fi
        if [[ "$ended" == "accepted" && -n "$head_after" ]]; then
            tidy_safe_sha="$head_after"
            tidy_safe_note="the tidy leg's verified rewrite (tidy ended: accepted)"
        else
            tidy_safe_sha="$head_approved"
            tidy_safe_note="the maintainer-approved history (tidy ended: ${ended:-unknown})"
        fi
    else
        local approved_sha
        approved_sha="$( (cd "$origin_repo" && git rev-parse --verify -q "$approved_ref") 2>/dev/null )" || true
        if [[ -n "$approved_sha" ]]; then
            tidy_safe_sha="$approved_sha"
            tidy_safe_note="the maintainer-approved history (the tidy leg was still in flight)"
            tidy_safe_ref="$approved_ref"
        fi
    fi
}

# Shared by both places that print a hand-run recovery command when the
# tidy-safe publish below loses a collision: never suggests fetching the
# clone. Names $tidy_safe_ref too, when there is one still live, alongside
# the sha-based recovery command that works either way (the one thing
# this must always be able to give: by the time tidy.json exists, the
# ref it came from may already be gone -- the runner's own cleanup
# deletes it once ITS OWN publish lands, which this verb's own failure
# here has nothing to do with).
warn_tidy_publish_failed() {
    printf 'fork-sandbox-stop: branch %s already exists in %s with a different history -- could not publish %s (%s). The work is safe, not lost%s; recover it by hand once the collision is resolved:\n  (cd %q && git update-ref refs/heads/%s %s "")\n' \
        "$branch" "$origin_repo" "$tidy_safe_note" "$tidy_safe_sha" \
        "${tidy_safe_ref:+, held at $tidy_safe_ref}" \
        "$origin_repo" "$branch" "$tidy_safe_sha" >&2
}

# Brings the branch back the tidy-safe way (see resolve_tidy_safe_sha
# above) when there is something to protect, or the plain fetch from the
# clone otherwise -- the ONE place either call site should reach into the
# clone from here on. Sets fetched (0/1) and tidy_safe_used (1 when the
# safe path was taken, win or lose, so the caller's own messaging and
# warning choice can key off it without re-deriving it). On a successful
# tidy-safe publish, also clears the holding refs it protected -- they
# may already be gone (the runner's own cleanup runs first in the
# ordinary case this verb is racing), but a stale one left over from a
# run this verb salvaged must not confuse a later --clone-dir reuse.
fetched=0
tidy_safe_used=0
fetch_branch_back() {
    fetched=0
    tidy_safe_used=0
    resolve_tidy_safe_sha
    if (( tidy_safe_already_published )); then
        # Nothing to do: this run's own publish already landed, and the
        # branch is the integrator's business from here, not this verb's.
        fetched=1
        return 0
    fi
    if [[ -n "$tidy_safe_sha" ]]; then
        tidy_safe_used=1
        if fs_tidy_publish "$origin_repo" "$branch" "$tidy_safe_sha"; then
            fetched=1
        else
            return 1
        fi
        (cd "$origin_repo" && git update-ref -d "refs/fork-sandbox/tidy/$run_id/approved") 2>/dev/null || true
        (cd "$origin_repo" && git update-ref -d "refs/fork-sandbox/tidy/$run_id/candidate") 2>/dev/null || true
        return 0
    fi
    if (cd "$origin_repo" && git fetch --quiet "$clone_dir" "$branch:$branch") 2>/dev/null; then
        fetched=1
        return 0
    fi
    return 1
}

# Entry state 1: the run is already over, per its own exit-code file. For a
# run whose tidy leg never touched the branch, that alone has always been
# enough: idempotent no-op, nothing rewritten, not an error. But
# fork-sandbox.sh writes exit-code (its own teardown) well before it
# reaches its own tidy-aware publish further down the same function -- a
# crash in that window (a kill -9, an OOM, a host reboot; nothing this
# script's TERM handling can catch) would otherwise have this verb declare
# success while the approved or verified history never reached the origin
# branch, with no recovery hint given. fetch_branch_back is safe to call
# here even if the runner is still alive and mid-publish itself: it is a
# no-op once the branch already holds the safe sha, and refuses (rather
# than clobbers) a genuine collision, so confirming costs nothing.
#
# The confirm-publish check below is gated on resolve_tidy_safe_sha's own
# tidy_safe_already_published signal, not on summary.json's absence:
# summary.json is also absent when jq failed to write it, or the runner
# crashed after publishing but before (or while) writing it, and either
# way a gate on its mere absence would re-run this check on a run whose
# publish already succeeded -- exactly the case tidy_safe_already_published
# exists to recognize and skip (see resolve_tidy_safe_sha's own comment).
# A run with no maintain step, or whose tidy leg never snapshotted
# anything, resolves an empty tidy_safe_sha here regardless of
# summary.json, so this costs it nothing either.
if [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]]; then
    rc="$(tr -dc '0-9-' < "$exit_code_file")"
    resolve_tidy_safe_sha || true
    if (( ! tidy_safe_already_published )) && [[ -n "$tidy_safe_sha" ]]; then
        have_sha="$( (cd "$origin_repo" && git rev-parse --verify -q "refs/heads/$branch") 2>/dev/null )" || true
        if [[ "$have_sha" != "$tidy_safe_sha" ]]; then
            if fetch_branch_back; then
                reconcile_branch_after_fetch
                printf 'run has already ended (exit %s); published %s, not the clone; branch %s, %s new commit(s)%s.\n' \
                    "$rc" "$tidy_safe_note" "$branch" "$reconcile_n_commits" \
                    "$( (( reconcile_removed )) && printf ', branch removed (no new commits)' || true )"
                exit 0
            else
                printf 'fork-sandbox-stop: run has already ended (exit %s), but %s was never confirmed on branch %s.\n' \
                    "$rc" "$tidy_safe_note" "$branch" >&2
                warn_tidy_publish_failed
                exit 1
            fi
        fi
    fi
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

# The runner's own progress.json finalization (fork-sandbox.sh, right after
# it writes exit-code) never runs on either path that reaches
# complete_run_host_side: a salvaged run's process is already gone, and a
# timed-out run gets KILLed before it can get there. Both leave
# progress.json exactly as its last mid-run rewrite left it -- some step
# "running", top-level state "running" -- forever, since nothing else ever
# rewrites the file again. This closes it the same way the runner's own
# final write would for a stop: top-level "running" becomes "stopped", and
# any step still "pending" or "running" becomes "skipped" with ended
# "stop-requested". A state that is not "running" (the run already reached
# its own terminal write by the time this runs) is left untouched rather
# than overwritten with a host-side guess. Best-effort, like the runner's
# own writes: this must never fail the stop, so any jq error just leaves
# progress.json as it was.
finalize_progress_host_side() {
    local progress_file="$run_dir/progress.json" updated
    [[ -L "$progress_file" || ! -f "$progress_file" ]] && return 0
    updated="$(date +%s)"
    if jq --argjson updated "$updated" '
        if .state == "running" then
            .state = "stopped"
            | .updated = $updated
            | .steps = [ .steps[]? |
                if (.state == "pending" or .state == "running")
                then .state = "skipped" | .ended = "stop-requested"
                else . end ]
        else . end
    ' -- "$progress_file" > "$progress_file.part" 2>/dev/null; then
        mv -f "$progress_file.part" "$progress_file"
    else
        rm -f "$progress_file.part" 2>/dev/null
    fi
}

# TERMs then KILLs the tidy leg's own process group -- the one other group
# a run's process tree can split into (GNU timeout, without --foreground,
# leads the tidy leg's wall-clock wrap in a group of its own; see run_leg's
# tidy wrap in fork-sandbox.sh). fs_tidy_leg_live_pgid (in the lib) is what
# makes this safe to call unconditionally: it only returns a pid from
# "$run_dir/tidy.pgid" (fs_record_tidy_leg_pgid's own file, written by the
# runner before the leg it names exists) when that pid is still live with
# the same start time and comm it was recorded with, so a stale file --
# the leg already ended and its number since reused -- signals nothing.
# Works whether or not the runner itself is still alive: unlike every other
# way this script reaches a run's descendants, it never walks ppid links
# down from the runner's own pid, which a dead runner (salvage, or one that
# died mid-wait after only delivering a TERM) gives nothing to walk from.
# The wait before KILL is long enough for the container backend's own
# cleanup (its EXIT trap's `<cli> rm -f`, which on podman stops the
# container first and can take close to 10s) to finish once TERM reaches
# it, rather than being KILLed out from under that removal and leaving the
# container itself running. Best-effort: no file (the leg never started,
# or a run with no maintain step) or an already-gone pid costs this
# nothing.
kill_tidy_leg_pgid() {
    local pgid_file="$run_dir/tidy.pgid" tidy_pgid waited=0 still_pgid
    tidy_pgid="$(fs_tidy_leg_live_pgid "$pgid_file")"
    [[ -n "$tidy_pgid" ]] || return 0
    kill -TERM -- "-$tidy_pgid" 2>/dev/null || return 0
    while kill -0 -- "-$tidy_pgid" 2>/dev/null && (( waited < 15 )); do
        sleep 1
        waited=$(( waited + 1 ))
    done
    # Re-validate right before the KILL rather than trusting the number
    # from before the wait: the leader checked above can have exited and
    # had this same pgid reused by an unrelated group during the 15s wait.
    still_pgid="$(fs_tidy_leg_live_pgid "$pgid_file")"
    [[ "$still_pgid" == "$tidy_pgid" ]] && kill -KILL -- "-$tidy_pgid" 2>/dev/null
    return 0
}

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
    local fetched=0 n_commits=0 removed=0 fetch_failed=0 upstream_line=""

    if [[ "$kill_tmux" == 1 ]]; then
        if [[ -n "$session" ]]; then
            # Exact-match: without the '=' prefix tmux prefix/fnmatch-matches
            # the target, and can kill a DIFFERENT session whose name
            # happens to start with this one (e.g. "cc-sbx-x" matching
            # "cc-sbx-x-2"). fork-sandbox.sh's own has-session check uses
            # the same "=$name" idiom (see fork-sandbox.sh's
            # session-existence check).
            tmux kill-session -t "=$session" 2>/dev/null || true
        fi

        # A --foreground run has no tmux session (the block above is a
        # no-op for it), and even a real session's kill-session can race
        # the runner's own teardown -- either way, do not trust the
        # session kill alone to mean the runner is dead. Re-check and, if
        # it is still alive, KILL it directly before touching the clone or
        # the ledger, so the completion below is not racing a
        # still-writing process.
        if kill -0 "$pid" 2>/dev/null; then
            local force_pgid force_shared_group_pids dp
            force_pgid="$( { ps -o pgid= -p "$pid" 2>/dev/null || true; } | tr -d '[:space:]')"
            if [[ -n "$force_pgid" && "$force_pgid" == "$pid" ]]; then
                kill -KILL -- "-$force_pgid" 2>/dev/null || true
            else
                # The runner does not lead this group (a --foreground run,
                # sharing its caller's) -- a group signal here would also
                # take down the launching shell. Any of the run's own
                # descendants still sitting in that shared group (a
                # foreground leg's direct child that never got a group of
                # its own) would otherwise never be signaled at all; reach
                # those individually by pid instead.
                force_shared_group_pids="$(fs_descendant_pids_in_pgid "$pid" "$force_pgid")"
                kill -KILL "$pid" 2>/dev/null || true
                while IFS= read -r dp; do
                    [[ -n "$dp" ]] && kill -KILL "$dp" 2>/dev/null
                done <<<"$force_shared_group_pids"
            fi
            local kill_wait=0
            while kill -0 "$pid" 2>/dev/null && (( kill_wait < 5 )); do
                sleep 1
                kill_wait=$(( kill_wait + 1 ))
            done
        fi
    fi

    # Independent of the block above and its runner-alive gate: a
    # GNU-timeout-wrapped tidy leg can be orphaned (salvage) or merely
    # TERM'd without a KILL follow-up (runner died mid-wait) by the time
    # either reaches here. See kill_tidy_leg_pgid's own header comment.
    kill_tidy_leg_pgid

    # fetch_branch_back is tidy-aware -- it refuses to touch the
    # clone at all when this run's tidy leg might have left it holding a
    # still-in-progress or rejected rewrite, publishing the approved (or
    # verified) history by sha instead. See its own header comment.
    if fetch_branch_back; then
        :
    else
        fetch_failed=1
        if (( tidy_safe_used )); then
            warn_tidy_publish_failed
        else
            warn_fetch_failed
        fi
    fi

    if (( fetched )); then
        reconcile_branch_after_fetch
        n_commits="$reconcile_n_commits"
        removed="$reconcile_removed"
        upstream_line="$(fs_apply_upstream "$origin_repo" "$branch" "$upstream" "$upstream_reason")"
    fi

    if [[ -L "$exit_code_file" ]]; then
        printf 'fork-sandbox-stop: refusing to write exit-code through a symlink at %s\n' "$exit_code_file" >&2
    else
        printf '143\n' > "$exit_code_file"
    fi

    finalize_progress_host_side

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
    # Say so -- this did not just fetch whatever the clone held.
    (( tidy_safe_used )) && printf 'published %s, not the clone.\n' "$tidy_safe_note"
    [[ -n "$upstream_line" ]] && printf '%s\n' "$upstream_line"
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
# The tidy leg's own process group (GNU timeout, without --foreground,
# leads it) is never part of $pgid_now -- see kill_tidy_leg_pgid's own
# header comment for how this reaches it safely.
kill_tidy_leg_pgid

# Wait for the runner PROCESS to exit, not for exit-code to appear: the
# runner writes exit-code strictly before its own fetch-back (see
# fork-sandbox.sh's teardown), so breaking on the file's mere existence can
# report "stopped gracefully" before the branch is actually back in the
# origin repo. The process only exits once its full teardown -- fetch-back
# included -- has completed.
#
# A --keep-session run is the one case where the process never exits at
# all: its teardown ends in `exec "$user_shell" -i` (fork-sandbox.sh's own
# comment on that exec explains why), which replaces the process image
# without ending the pid, so kill -0 would keep succeeding forever for a
# run that finished perfectly cleanly. Its summary.json is written
# strictly AFTER the fetch-back (fork-sandbox.sh's teardown), so treat its
# appearance as the same "teardown truly finished" signal a normal run's
# process exit gives -- the one case a still-alive pid cannot give it.
waited=0
teardown_done=0
while (( waited < timeout_secs )); do
    if ! kill -0 "$pid" 2>/dev/null; then
        teardown_done=1
        break
    fi
    if [[ -e "$run_dir/summary.json" ]]; then
        teardown_done=1
        break
    fi
    sleep 1
    waited=$(( waited + 1 ))
done

if (( teardown_done )); then
    if [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]]; then
        rc="$(tr -dc '0-9-' < "$exit_code_file")"
        # exit-code existing means the runner's own teardown at least
        # reached that point, but not that its own fetch-back afterward
        # succeeded -- repeat it here so "stopped gracefully" actually
        # means the branch is back, not just that exit-code was written.
        # NOT idempotent on its own: see reconcile_branch_after_fetch below.
        #
        # A bare re-fetch is exactly the thing this must not do when
        # a tidy leg ran -- the runner's own teardown may have already
        # published the right history by sha (see fork-sandbox.sh's tidy
        # block), and a plain `git fetch` here would re-read the CLONE,
        # which a discard whose best-effort reset failed can still leave
        # holding the rejected rewrite. fetch_branch_back is tidy-aware for
        # exactly this; see its own header comment.
        if fetch_branch_back; then
            # The clone still holds the branch ref even after the runner's
            # own teardown deletes a zero-commit branch from the ORIGIN repo
            # only (fork-sandbox.sh's teardown never touches the clone), so
            # a plain re-fetch can resurrect exactly the ref the runner just
            # removed. Apply the same zero-commit removal here so a
            # confirmed-clean stop leaves the origin repo the way the
            # runner's own teardown left it, not the way a bare re-fetch
            # would.
            reconcile_branch_after_fetch
            printf 'stopped gracefully (exit %s) after %ss; branch %s, %s new commit(s)%s.\n' \
                "$rc" "$waited" "$branch" "$reconcile_n_commits" \
                "$( (( reconcile_removed )) && printf ', branch removed (no new commits)' || true )"
            (( tidy_safe_used )) && printf 'published %s, not the clone.\n' "$tidy_safe_note"
            exit 0
        else
            printf 'fork-sandbox-stop: the runner exited (exit %s) but its own fetch-back could not be confirmed.\n' "$rc" >&2
            if (( tidy_safe_used )); then
                warn_tidy_publish_failed
            else
                warn_fetch_failed
            fi
            exit 1
        fi
    fi
    # The process is gone (this is unreachable via the summary.json branch
    # above, since summary.json never exists without exit-code already
    # existing) but exit-code never got written -- the runner died without
    # completing its own teardown, e.g. an external kill this verb did not
    # itself perform while it was waiting. Nothing of its own can be
    # trusted; close the run the same way a timed-out one is closed,
    # rather than claim a graceful stop that never actually happened.
    printf 'fork-sandbox-stop: the runner exited without completing its own teardown (no exit-code was written); completing the stop host-side.\n' >&2
    if complete_run_host_side stop-timeout 1; then
        exit 0
    else
        exit 1
    fi
fi

# Timeout expired while the runner was still alive and had not finished:
# fall back to the violent path that exists today, but still owe a
# run_end -- distinguishable from a clean stop -- instead of leaving the
# gap this verb exists to close merely relocated.
printf 'timed out after %ss waiting for a graceful stop; forcing it.\n' "$timeout_secs" >&2
if complete_run_host_side stop-timeout 1; then
    exit 0
else
    exit 1
fi
