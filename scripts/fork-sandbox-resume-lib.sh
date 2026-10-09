#!/usr/bin/env bash
# fork-sandbox-resume-lib.sh -- --resume <state-dir> orchestration for fork-sandbox.sh
#
# Sourced by fork-sandbox.sh ONLY when --resume is present on its own argv,
# intercepted before any of that script's own flag parsing runs (see the
# comment beside the source line, in fork-sandbox.sh). Not meant to be run
# standalone, and not installed as its own CLI entry point.
#
# The contract this implements (README.md's "Driving fork-sandbox from
# another program" section) is:
#
#   fork-sandbox run --resume <state-dir> [--base <draft>] [extra_args...] <project> <note.md>
#
# -- submits, prints exactly the run dir on stdout, returns in well under
# 60s, detaches on --k8s instead of blocking for the run's whole length,
# is idempotent by note.md's resolved path, takes one state dir's worth of
# runs at a time (a second note while one is active is refused, never
# raced), and, with --base, fast-forwards one moving branch instead of
# minting a fresh one per run. Scope: the default (single implement leg)
# pipeline, local or --k8s; a composed preset/review-loop is not refused,
# but is not what this was built or tested against.
#
# fork-sandbox's own bookkeeping for a state dir lives under
# <state-dir>/.fork-sandbox/ -- never session.json, which is the client's
# own file at <state-dir>'s own top level and is never read or written
# here:
#   .fork-sandbox/lock           flock target; held for one run's ENTIRE
#                                lifetime by a detached worker, not just
#                                while this command is submitting it.
#   .fork-sandbox/runs.tsv       append-only "<note-abs-path>\t<run-dir>"
#                                map, the idempotency record.
#   .fork-sandbox/last-run-dir   the most recent run's directory, read to
#                                find the previous turn's session id.
#   .fork-sandbox/session-store  the harness's own --session-state
#                                directory (a --k8s collect's session
#                                pull-back atomically swaps this whole
#                                leaf -- see fs_resume_main's own comment
#                                on why it is never $resume_state_real
#                                itself).
#
# How the lock outlives this process: fork-sandbox.sh's own clone-dir lock
# (fs_lock_clone_dir) is released by the launcher and reacquired fresh by
# the generated runner, which works for a single process tree but leaves a
# gap between the two acquisitions. That gap is exactly what "never races
# the session store" rules out here, so this takes a different shape
# instead: the SAME flock fd, opened once in the detached background
# worker below, is held from before the inner run is even started through
# to the moment it finishes (wait on an exit-code file, locally; wait on
# the inner `fork-sandbox.sh --k8s` invocation, which blocks for the
# submit+wait+collect of its own accord, for --k8s) -- continuously, with
# no release-and-reacquire gap, and released by the kernel automatically
# even if this whole process tree is killed.

# The idempotency map is a flat, lock-free-readable text file: appends are
# the only writes (never rewritten, per the house ledger convention this
# mirrors -- see the outbox's own test-runs.jsonl rule), so a lookup never
# needs the lock to be safe, only to be race-free against a second run
# being CREATED for the same note (closed by the re-check inside the lock,
# below). Prints the matching run dir and returns 0, or returns 1 with
# nothing printed.
fs_resume_lookup() {
    local mapfile="$1" note="$2" l_note l_rd
    [[ -f "$mapfile" ]] || return 1
    while IFS=$'\t' read -r l_note l_rd; do
        [[ "$l_note" == "$note" ]] || continue
        printf '%s' "$l_rd"
        return 0
    done < "$mapfile"
    return 1
}

# Records a newly-started run: appends the idempotency row and moves the
# "last run" pointer forward. Called only by the lock holder, after it has
# confirmed (under the lock) that no row for this note exists yet.
fs_resume_record() {
    local mapfile="$1" lastfile="$2" note="$3" run_dir="$4"
    printf '%s\t%s\n' "$note" "$run_dir" >> "$mapfile"
    printf '%s\n' "$run_dir" > "$lastfile"
}

# The previous run's session id, for --resume-session on this one -- empty
# (meaning: start fresh, bound into the same --session-state store but not
# resumed) when there is no previous run, it never wrote a summary.json, or
# that summary carries no session_id. Resume is a continuity and cost
# optimization, never a correctness guarantee, so a missing id here is a
# degraded conversation, not a refused one.
fs_resume_prior_session_id() {
    local lastfile="$1" prior_run_dir
    [[ -f "$lastfile" ]] || return 0
    prior_run_dir="$(cat -- "$lastfile" 2>/dev/null || true)"
    [[ -n "$prior_run_dir" && -f "$prior_run_dir/summary.json" ]] || return 0
    jq -r '.session_id // empty' -- "$prior_run_dir/summary.json" 2>/dev/null || true
}

# The whole --resume command. $1 = --resume's own argument (the state
# dir), $2 = --base's argument (empty if not given), $3.. = every other
# argument the caller gave fork-sandbox.sh, in its original order --
# including <project-path> <note.md>, which the contract puts last, so
# they are simply this array's final two elements; nothing here parses
# them out by flag.
fs_resume_main() {
    # shellcheck disable=SC2154  # set by fork-sandbox.sh just before it sources this file
    : "${self:?fs_resume_main must be sourced from fork-sandbox.sh, which sets self}"
    local resume_state_dir="$1" resume_base="$2"
    shift 2
    local -a fwd=("$@")
    local n=${#fwd[@]}
    if (( n < 2 )); then
        echo "Error: --resume needs <project-path> <note.md> at the end of the" >&2
        echo "command line, same as any other fork-sandbox run." >&2
        exit 1
    fi
    local handoff_file="${fwd[$((n-1))]}"
    local project_path="${fwd[$((n-2))]}"
    [[ -n "$project_path" ]] || { echo "Error: --resume needs <project-path> before <note.md>." >&2; exit 1; }

    # --resume computes --session-state, --resume-session and the branch's
    # starting point itself; a caller handing those over directly would
    # either be overridden silently or fight this orchestration's own
    # choices, so it is refused outright instead, with --base named as the
    # one flag that DOES belong here.
    local a
    for a in "${fwd[@]}"; do
        case "$a" in
            --session-state|--resume-session|--session-id|--clone-dir|--branch)
                echo "Error: --resume manages --session-state, --resume-session and the" >&2
                echo "branch's starting point itself; '$a' is not accepted alongside it." >&2
                echo "Use --base <branch> to choose which branch is continued." >&2
                exit 1
                ;;
        esac
    done

    # These runs use no refresh legs: a refresh starts a fresh continuation
    # session mid-run, which breaks the one-conversation guarantee --base's
    # fast-forward and the idempotency map both depend on. fs_refresh_resolve
    # defaults an un-forwarded --refresh-at to 0.5 (claude harness), so this
    # forces it to 0 itself rather than relying on the caller to remember;
    # an explicit positive value from the caller is a contradiction of that
    # guarantee, not a preference, so it is refused rather than honored.
    local refresh_at_fwd="" i
    for ((i = 0; i < ${#fwd[@]}; i++)); do
        if [[ "${fwd[$i]}" == --refresh-at ]]; then
            refresh_at_fwd="${fwd[$((i+1))]:-}"
        fi
    done
    local force_refresh_zero=false
    if [[ -n "$refresh_at_fwd" ]]; then
        if awk -v v="$refresh_at_fwd" 'BEGIN{exit !(v>0)}' 2>/dev/null; then
            echo "Error: --resume runs use no refresh legs (--refresh-at 0); a refresh" >&2
            echo "starts a fresh continuation session mid-run, which breaks the single" >&2
            echo "conversation --resume guarantees. Omit --refresh-at or pass '--refresh-at 0'." >&2
            exit 1
        fi
    else
        force_refresh_zero=true
    fi

    [[ -n "$resume_state_dir" ]] || { echo "Error: --resume requires a directory." >&2; exit 1; }
    local resume_state_real
    resume_state_real="$(fs_validate_scratch_dir "$resume_state_dir" --resume)" || exit 1
    mkdir -p -- "$resume_state_real" \
        || { echo "Error: could not create $resume_state_real." >&2; exit 1; }

    local bookdir="$resume_state_real/.fork-sandbox"
    mkdir -p -- "$bookdir" \
        || { echo "Error: could not create $bookdir." >&2; exit 1; }
    local mapfile_path="$bookdir/runs.tsv" lastfile_path="$bookdir/last-run-dir"
    local lockfile_path="$bookdir/lock"
    touch -- "$mapfile_path" 2>/dev/null || true

    if [[ -n "$resume_base" ]]; then
        fs_reject_unsafe_chars "$resume_base" || exit 1
    fi

    # fs_require_scratch_handoff already runs inside the inner invocation
    # (same as any ordinary run); resolving the note path here is purely
    # for the idempotency key -- a relative and an absolute spelling of the
    # same file must look like the same note.
    local note_abs
    note_abs="$("$FS_REALPATH" -m -- "$handoff_file" 2>/dev/null)"
    [[ -n "$note_abs" ]] || note_abs="$handoff_file"

    # Idempotency fast path: lock-free, so a repeat submit of a note whose
    # run already finished (or is still going) costs nothing but a read.
    local existing
    existing="$(fs_resume_lookup "$mapfile_path" "$note_abs" || true)"
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing"
        exit 0
    fi

    local lock_fd
    exec {lock_fd}<>"$lockfile_path"
    if ! flock -n "$lock_fd"; then
        echo "Error: a run is already active for $resume_state_real; this note" >&2
        echo "was not submitted. Poll the active run with 'fork-sandbox status" >&2
        echo "--json', and retry this note once it replies." >&2
        exit 1
    fi

    # Re-check under the lock: closes the race between the lookup above
    # and here, where a second submit of the SAME note could otherwise
    # both see "not found" and both try to become the one that starts it.
    existing="$(fs_resume_lookup "$mapfile_path" "$note_abs" || true)"
    if [[ -n "$existing" ]]; then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&- 2>/dev/null || true
        printf '%s\n' "$existing"
        exit 0
    fi

    local prior_session_id
    prior_session_id="$(fs_resume_prior_session_id "$lastfile_path")"

    # --session-state names a directory of its OWN here, inside
    # .fork-sandbox/ -- never $resume_state_real itself. A --k8s collect
    # pulls the session store back with an atomic swap (cmd_collect:
    # move the current store aside, move the pulled one into place,
    # remove the old one) -- fine for a directory that holds nothing but
    # that store, but handed $resume_state_real directly it would move
    # the client's session.json and this very file's own runs.tsv/lock/
    # last-run-dir aside with it and then rm -rf the lot the moment the
    # pulled store lands, mid-run, out from under the still-running
    # worker below. Nothing about the client contract requires the store
    # to live at the state dir's own top level -- only that session.json
    # is left alone -- so it gets a leaf of its own instead.
    local session_store_dir="$bookdir/session-store"
    local -a inner=(--session-state "$session_store_dir")
    [[ -n "$prior_session_id" ]] && inner+=(--resume-session "$prior_session_id")
    if [[ -n "$resume_base" ]]; then
        inner+=(--branch "$resume_base" --checkout "$resume_base" --allow-existing-branch)
    fi
    [[ "$force_refresh_zero" == true ]] && inner+=(--refresh-at 0)
    inner+=("${fwd[@]}")

    local is_k8s=false x
    for x in "${fwd[@]}"; do
        [[ "$x" == --k8s ]] && is_k8s=true
    done

    local ready_file
    ready_file="$bookdir/.ready.$$.$(date +%s%N 2>/dev/null || date +%s)"
    rm -f -- "$ready_file" "$ready_file.failed"
    local worker_log="$ready_file.log"

    # The detached worker: holds $lock_fd (inherited by this fork, never
    # by anything it execs -- see this file's header) for as long as the
    # run takes, local or --k8s, and releases it on ANY exit from this
    # subshell, including a crash. `disown` and the stdio redirection
    # below keep it from being tied to this terminal/session; it is a
    # plain background fork, not setsid --fork, specifically so $lock_fd
    # survives into it (setsid's own exec would lose a bash-allocated {fd}
    # the same way any other exec does).
    (
        trap 'flock -u "$lock_fd" 2>/dev/null; exec {lock_fd}>&- 2>/dev/null' EXIT
        local rd=""
        if [[ "$is_k8s" == true ]]; then
            FORK_SANDBOX_RESUME_NOTE=1 "$self" "${inner[@]}" > "$worker_log" 2>&1 &
            local worker_pid=$!
            local tries=0
            while (( tries < 220 )); do
                rd="$(sed -n 's/^  run dir:  *//p' "$worker_log" 2>/dev/null | head -1)"
                [[ -n "$rd" ]] && break
                kill -0 "$worker_pid" 2>/dev/null || break
                sleep 0.25
                tries=$(( tries + 1 ))
            done
            if [[ -z "$rd" ]]; then
                : > "$ready_file.failed"
                wait "$worker_pid" 2>/dev/null || true
                exit 1
            fi
            fs_resume_record "$mapfile_path" "$lastfile_path" "$note_abs" "$rd"
            printf '%s\n' "$rd" > "$ready_file"
            # cmd_run (what a plain `--k8s` invocation blocks on) does the
            # submit+wait+collect itself; holding $lock_fd across this
            # wait is the whole point -- see this file's header. A failed
            # submit must leave a terminal marker after its run directory
            # has been reported, even when it never reached collect.
            if ! wait "$worker_pid" 2>/dev/null; then
                [[ -z "$rd" || -e "$rd/exit-code" || -e "$rd/summary.json" ]] \
                    || printf '1\n' > "$rd/exit-code"
                [[ -z "$rd" ]] || cp -- "$worker_log" "$rd/resume-client.log" 2>/dev/null || true
            fi
        else
            # `|| true`: under set -e, the inner run exiting nonzero (a
            # validation refusal, or just "done" when a run can legitimately
            # also fail) would otherwise kill this subshell on this exact
            # line, before the next line even runs -- silently losing the
            # chance to write $ready_file.failed below, which is the ONLY
            # thing that saves the foreground caller from waiting out its
            # full timeout for a signal that was never coming. The
            # `rd`-empty check right after is what actually distinguishes
            # "failed to submit" from "submitted fine, but a FRESH LOCAL run
            # legitimately prints its block and exits 0 regardless" -- this
            # command's own exit status is not that signal either way.
            "$self" "${inner[@]}" > "$worker_log" 2>&1 || true
            rd="$(sed -n 's/^  run dir:  *//p' "$worker_log" 2>/dev/null | head -1)"
            if [[ -z "$rd" ]]; then
                : > "$ready_file.failed"
                exit 1
            fi
            fs_resume_record "$mapfile_path" "$lastfile_path" "$note_abs" "$rd"
            printf '%s\n' "$rd" > "$ready_file"
            # A local run returns as soon as its tmux session is up (it
            # never blocks the way --k8s's cmd_run does), so the lock must
            # be held here, separately, until the run is actually over.
            # exit-code alone is not that signal for a plain single-leg run:
            # fork-sandbox-runner.sh writes it early, deliberately, BEFORE
            # the fetch-back and the summary/session-id discovery that
            # follow it in that same process (see that script's own comment
            # beside its early exit-code write) -- so stopping here would
            # release the lock while the runner is still finalizing the very
            # session store and branch state this lock protects. Wait for
            # that marker AND for the runner process named in its pid file
            # to actually be gone, which the runner holds open across the
            # fetch-back and every write that follows.
            local runner_pid
            local started_wait proc_state
            started_wait="$(date +%s)"
            while :; do
                runner_pid="$(tr -dc '0-9' < "$rd/pid" 2>/dev/null || true)"
                if [[ -n "$runner_pid" ]]; then
                    proc_state="$(ps -o stat= -p "$runner_pid" 2>/dev/null || true)"
                    if [[ -z "$proc_state" || "$proc_state" == Z* ]]; then
                        [[ -e "$rd/exit-code" ]] || printf '1\n' > "$rd/exit-code"
                        break
                    fi
                elif (( $(date +%s) - started_wait >= 60 )); then
                    [[ -e "$rd/exit-code" ]] || printf '1\n' > "$rd/exit-code"
                    break
                fi
                sleep 2
            done
        fi
        rm -f -- "$worker_log"
    ) < /dev/null > /dev/null 2>&1 &
    disown

    local waited=0
    while (( waited < 550 )); do
        [[ -s "$ready_file" ]] && break
        [[ -e "$ready_file.failed" ]] && break
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    if [[ -e "$ready_file.failed" ]]; then
        echo "Error: the run could not be started." >&2
        [[ -s "$worker_log" ]] && tail -n 40 -- "$worker_log" >&2
        rm -f -- "$ready_file.failed" "$worker_log"
        exit 1
    fi
    if [[ ! -s "$ready_file" ]]; then
        echo "Error: timed out waiting for the run to start." >&2
        exit 1
    fi
    cat -- "$ready_file"
    rm -f -- "$ready_file"
}
