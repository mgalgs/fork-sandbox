# fork-sandbox-runner.sh -- the body of every generated run.sh, local or pod.
#
# Expects the preamble variables that fork-sandbox.sh's --k8s dispatch and
# its local launch path both emit before this file's bytes (see
# fs_emit_run_sh_preamble in fork-sandbox.sh). Not executable on its own --
# it is `cat`-ed onto the end of a generated run.sh, never sourced or run
# directly, so invariant checks can compare these bytes verbatim against
# whatever run.sh ends up with, on either path.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC1091,SC2100,SC2329,SC2015,SC2016,SC2004,SC1010
# Load shared predicates used by the status script as well as this runner, so
# report display and summary provenance cannot drift between processes.
source "$script_dir/fork-sandbox-lib.sh"
# The --refresh-at loop's pure logic, shared with the pod (ConfigMap key refresh.sh).
source "$script_dir/fork-sandbox-refresh.sh"

# This run's own id for its tidy holding refs (refs/fork-sandbox/tidy/
# <run_id>/approved|candidate) -- fork-sandbox-stop.sh derives the same id
# the same way, from the same run_dir, so the two agree on where this
# run's snapshots live without either reading the other's state. Resolved
# here, before anything else, so the guard right below can use it.
run_id="$(basename -- "$run_dir")"

# A manual re-run in this same run dir must not pick up the previous
# invocation's tidy.json/tidy.pgid, nor race a 'fork-sandbox stop' that is
# still confirming the previous invocation's own publish against these
# same refs (resolve_tidy_safe_sha, fetch_branch_back) -- refuse outright
# instead, rather than silently delete a ref stop still needs or publish
# by a run_id that is no longer this invocation's own.
#
# Only meaningful when fetch_back=1: a --k8s pod run's origin_repo is a
# host path recorded for display only (this runner never crosses into it,
# fetched or not), so there is no ref in it to be stale in the first
# place, and asking would just run git against a path this process cannot
# reach.
if (( fetch_back )); then
    tidy_stale_refs=()
    for tidy_stale_ref in "refs/fork-sandbox/tidy/$run_id/approved" "refs/fork-sandbox/tidy/$run_id/candidate"; do
        if (cd "$origin_repo" && git rev-parse --verify -q "$tidy_stale_ref") >/dev/null 2>&1; then
            tidy_stale_refs+=("$tidy_stale_ref")
        fi
    done
    if (( ${#tidy_stale_refs[@]} )); then
        printf 'fork-sandbox: refusing to start: %s still exist in %s, left by an earlier run in this directory.\n' \
            "$(IFS=', '; echo "${tidy_stale_refs[*]}")" "$origin_repo" >&2
        printf 'Confirm the earlier run is really over (fork-sandbox stop on its run dir), or delete them by hand once you are sure they are not needed:\n' >&2
        for tidy_stale_ref in "${tidy_stale_refs[@]}"; do
            printf '  (cd %q && git update-ref -d %q)\n' "$origin_repo" "$tidy_stale_ref" >&2
        done
        exit 1
    fi
fi
rm -f -- "$run_dir/tidy.json" "$run_dir/tidy.pgid"

# FORK_SANDBOX_LEG_HANDOFF_DIR is set only pod-side, only for a composed
# (--run-dir) run, by fork-sandbox-k8s.sh's pod spec -- never for a local
# run, and never for a single-leg or legacy-review-loop pod, both of which
# keep running every leg in-process exactly as before. When it is set, this
# run's own leg container (fork-sandbox-k8s-leg-loop.sh) holds the actual
# harness invocations, reached over the request/response protocol
# fs_run_leg_split below implements; see that function's own comment, and
# "Composed pipelines on --k8s" in docs/kubernetes-runs.md, for why this
# split exists and what it closes. Request numbers under $run_dir/.leg-req
# must start fresh for THIS invocation of run.sh -- a manual re-run in the
# same run dir (the same case the tidy-state guard above and the retry
# accounting elsewhere in this file already guard against) must not resume
# numbering a previous invocation's leg container could still be replying
# to, nor reuse a number whose hand-off directory already holds a previous
# invocation's response.
if [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]]; then
    rm -rf -- "$run_dir/.leg-req"
fi

# fork-sandbox-stop.sh's graceful path signals this runner's whole process
# GROUP with TERM (a bash trap does not fire while a foreground child is
# running, so the leg's own child gets the signal directly and dies first).
# The trap only records that a stop was requested -- no work runs inside a
# trap -- and every loop below that could start another leg checks the flag
# once its current leg returns, so control falls through to the ordinary
# teardown near the end of this file instead of starting anything new.
stop_requested=0
trap 'stop_requested=1' TERM

# The launcher held this same workspace's lock while it set up the clone and
# provisioned it, but released it just before starting this runner (see the
# release beside where this file was generated). From here the lock's
# lifetime has to match THIS run's, not the launcher's (already gone by the
# time this line runs) and not tmux's (whose server outlives every run and
# must never be the one holding it) -- so this process reacquires it fresh,
# as close to its own first line as sourcing fork-sandbox-lib.sh above
# allows. clone_lock_path is empty for a fresh clone under run_dir (no
# --clone-dir), which nothing else can ever reach and so needs no lock.
if [[ -n "${clone_lock_path:-}" ]]; then
    fs_lock_clone_dir "$clone_dir"
fi

# `exec {clone_lock_fd}<>...` above has no close-on-exec, so every harness
# invocation below would otherwise hand its whole process tree an open,
# locked fd on this workspace's lock file -- a claude-sandboxed/bwrap
# descendant that outlives this runner (a wedged sandbox, an orphaned
# `setsid` child) then keeps the flock held forever, which is exactly the
# permanently wedged seat `fleet teardown` cannot reclaim (see
# fs_lock_clone_dir's comment). Every sandbox invocation below runs through
# this wrapper instead of calling its argv directly. A subshell, not a
# close-then-reopen around the call: closing happens only in the forked copy
# that is about to exec the harness, so this runner's own fd is untouched
# afterwards. Harmless when clone_lock_fd is empty (no --clone-dir): the
# close then targets an unset fd, errors internally and is swallowed, and
# "$@" still runs.
fs_run_lock_closed() {
    if [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]]; then
        fs_run_leg_split "$@"
        return
    fi
    ( { exec {clone_lock_fd}>&-; } 2>/dev/null; "$@" )
}

# fs_run_leg_split: fs_run_lock_closed's pod-side counterpart, used
# whenever FORK_SANDBOX_LEG_HANDOFF_DIR is set (a composed --run-dir pod
# run -- see the setup above). "$@" is a leg's own argv, exactly as
# fs_run_lock_closed would otherwise exec it directly; here it is instead
# handed to fork-sandbox-k8s-leg-loop.sh, running as PID 1 of a SEPARATE
# container that mounts $run_dir read-only and the clone read-write (the
# reverse of this container's own mounts) -- so nothing this leg does can
# write run.sh, pipeline.json, progress.json, a later leg's prompt, or any
# other file this runner reads to decide what happens next, no matter what
# the leg runs. The request/response protocol is the full contract; see
# fork-sandbox-k8s-leg-loop.sh's own header for the other half, including
# why the leg container is safe to trust once it reports a request "done".
#
# Every caller already does `fs_run_lock_closed "${cmd[@]}" < "$prompt"
# ... | tee ... | formatter`, piped, which runs this function in a forked
# subshell -- so neither this function nor its caller may rely on an
# in-process variable surviving between calls (one would silently reset to
# empty on every single call). The request number is instead derived from
# a counter FILE under $run_dir (one writer at a time, by this run's own
# "never two legs in flight" rule -- see "Out of scope" in the handoff this
# implements), which is ordinary persistent state, not shell state, so it
# survives the subshell exactly like any other file write would.
#
# $@ becomes the request's argv verbatim; this function's own stdin (the
# prompt file every caller already redirects onto fd 0) is drained into
# the request's "stdin" file byte for byte, so the leg loop does not need
# to know the prompt's path, only that a file with this exact content is
# what the leg should read as ITS stdin -- this works identically whether
# the caller's redirect was a real file or something else seekable, and
# avoids ever having to resolve a pod-side path across the two containers.
# The response's stdout/stderr are read back and written to this
# function's own fd 1/fd 2, which is exactly what the direct-exec branch
# above would have left them connected to -- so every caller's own
# tee/formatter pipeline around this call needs no changes at all.
#
# The response directory name is $n PLUS a token this call generates
# fresh, never $n alone: the whole hand-off volume is read-write in the
# leg container (one dedicated volume, not split per-request -- a kernel
# mount cannot be scoped that finely), so request n's own leg, while it
# is still running, could otherwise `mkdir`/`touch` a "done" for request
# n+1 (or any n+k) under a path it can predict just by reading this
# counter file -- forging a later step's result before that step's real
# leg has even started. The token is generated here, in this (trusted)
# container, and handed to the leg loop only via $reqdir/token, which is
# part of $run_dir -- read-only in the leg container, so a leg can read
# the token for a request already issued to it but can never learn, let
# alone write, the token for a request not yet issued. That makes every
# future response path unguessable from inside a leg, which is the
# property this exists for.
#
# A forged "done" needs no such guess, though: the whole hand-off volume
# is leg-writable, so request n's own leg can write its OWN "<n>-<token>/
# done" itself, at any time, including long before its real process
# exits -- "done"'s mere existence proves nothing. $run_dir/.leg-req/lock,
# created empty here (idempotent -- every call after the first just finds
# it already there) before this request's "go" is ever written, is the
# signal this function actually trusts: fork-sandbox-k8s-leg-loop.sh
# opens the same file and holds `flock -x` on it from strictly before it
# spawns the leg's own process until strictly after that leg's sweep and
# its own "rc"/"done" write are both done (see that script's header for
# why the sweep itself closes every OTHER way a leg could outlive its
# exit). A leg cannot shorten that hold or unlink the file to start over
# on a fresh, unlocked inode ($run_dir is read-only in the leg container),
# so the wait below requires "done" to exist AND a non-blocking `flock -n`
# acquire on this function's own fd to the same file to succeed, in that
# order: "done" is checked first so this function never even attempts the
# lock while the request has not been picked up yet (the lock starts
# free, same as it looks once a genuine answer has landed, so checking it
# alone, before any request has even been issued, would prove nothing).
# Once both hold, the lock is released immediately, so the next request's
# own call can use the same file. That also closes "a leg can read a
# later request's token": the `agent` container never writes request
# n+1's "go" until request n's lock is confirmed free, which cannot
# happen while request n's own leg, or anything it started, is still
# alive to read that token once it appears.
fs_run_leg_split() {
    (
        local seq_file="$run_dir/.leg-req-seq" n reqdir token leg_handoff_dir deadline leg_rc
        local lockfile="$run_dir/.leg-req/lock" reqlockfd
        local heartbeat_file="$FORK_SANDBOX_LEG_HANDOFF_DIR/heartbeat" now
        local hb_grace_deadline hb_timeout hb_seen=0 hb_last_value="" hb_last_seen_at=0 hb_value
        n=$(( $(cat "$seq_file" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$n" > "$seq_file"
        reqdir="$run_dir/.leg-req/$n"
        token="$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n')"
        [[ -n "$token" ]] || token="fallback-$$-$RANDOM-$(date +%s%N)"
        leg_handoff_dir="$FORK_SANDBOX_LEG_HANDOFF_DIR/$n-$token"
        mkdir -p "$reqdir"
        [[ -e "$lockfile" ]] || : > "$lockfile"
        printf '%s' "$token" > "$reqdir/token"
        printf '%s\0' "$@" > "$reqdir/argv"
        cat <&0 > "$reqdir/stdin"
        touch "$reqdir/go"

        exec {reqlockfd}<"$lockfile"

        # A dead or wedged leg container (OOM, a node problem -- not a
        # leg's own doing, which the sweep, the signal traps and the
        # response-directory recovery in fork-sandbox-k8s-leg-loop.sh keep
        # from ever reaching this state) would otherwise only be noticed
        # at FORK_SANDBOX_LEG_TIMEOUT (six hours), since "done" never
        # appearing is the only signal this wait had. The loop writes a
        # heartbeat -- a fresh timestamp under $FORK_SANDBOX_LEG_HANDOFF_DIR,
        # independent of any single request -- on an interval far shorter
        # than this grace/timeout pair; as long as it keeps advancing, the
        # loop is alive, no matter how long the CURRENT leg has
        # legitimately been running (legs run for hours; this must never
        # cap that). Two separate bounds, because "never started" and
        # "stopped mid-run" need different grace: FORK_SANDBOX_LEG_LOOP_HEARTBEAT_GRACE
        # (default 300s) covers the loop's own startup (waiting on
        # .leg-setup/ready, image pull, scheduling) before any heartbeat
        # need exist yet; FORK_SANDBOX_LEG_LOOP_HEARTBEAT_TIMEOUT (default
        # 90s) is how long a heartbeat may go stale, once seen, before
        # this gives up on it -- comfortably above the writer's own
        # interval (default 5s) so ordinary scheduling jitter is never
        # mistaken for death.
        hb_grace_deadline=$(( $(date +%s) + ${FORK_SANDBOX_LEG_LOOP_HEARTBEAT_GRACE:-300} ))
        hb_timeout="${FORK_SANDBOX_LEG_LOOP_HEARTBEAT_TIMEOUT:-90}"
        deadline=$(( $(date +%s) + ${FORK_SANDBOX_LEG_TIMEOUT:-21600} ))
        until [[ -f "$leg_handoff_dir/done" ]] && flock -n "$reqlockfd"; do
            now="$(date +%s)"
            if (( now >= deadline )); then
                printf 'fork-sandbox: the leg container never answered request %s (no %s/done within %ss); treating this leg as failed\n' \
                    "$n" "$leg_handoff_dir" "${FORK_SANDBOX_LEG_TIMEOUT:-21600}" >&2
                exit 1
            fi
            # A "done" the loop could not turn back into a regular file
            # would never satisfy the -f above; fail now instead of at the
            # six-hour deadline.
            if [[ -e "$leg_handoff_dir/done" || -L "$leg_handoff_dir/done" ]] \
                && { [[ -L "$leg_handoff_dir/done" ]] || [[ ! -f "$leg_handoff_dir/done" ]]; } \
                && flock -n "$reqlockfd"; then
                printf 'fork-sandbox: request %s answered with a %s/done that is not a regular file; treating this leg as failed\n' \
                    "$n" "$leg_handoff_dir" >&2
                exit 1
            fi
            # The heartbeat file lives in the leg-writable hand-off
            # volume, so a leg can replace it with a FIFO (a plain,
            # unbounded `cat` of that with no reader blocks this wait
            # forever instead of ever reaching the deadline checks below)
            # or leave malformed text in it after a genuine heartbeat was
            # already seen. fs_leg_handoff_read's bounded, regular-file-
            # only read (see its own comment below) refuses both without
            # blocking, returning empty; empty or malformed is handled the
            # same as "no fresh heartbeat this tick", below.
            hb_value="$(fs_leg_handoff_read "$heartbeat_file" 2>/dev/null)"
            if [[ "$hb_value" =~ ^[0-9]+$ ]] && { (( hb_seen == 0 )) || [[ "$hb_value" != "$hb_last_value" ]]; }; then
                hb_last_value="$hb_value"; hb_last_seen_at="$now"; hb_seen=1
            elif (( hb_seen == 0 )); then
                if (( now >= hb_grace_deadline )); then
                    printf 'fork-sandbox: leg container never started answering (%ss); request %s failed\n' \
                        "${FORK_SANDBOX_LEG_LOOP_HEARTBEAT_GRACE:-300}" "$n" >&2
                    exit 1
                fi
            # A heartbeat already seen once that then stops advancing --
            # whether because the loop died, or because a leg corrupted
            # the file -- must still be caught here; it is not enough to
            # only catch it while the file reads back as a fresh, valid
            # timestamp.
            elif (( now - hb_last_seen_at >= hb_timeout )); then
                printf 'fork-sandbox: leg container heartbeat stale %ss; request %s failed\n' \
                    "$hb_timeout" "$n" >&2
                exit 1
            fi
            sleep 1
        done
        flock -u "$reqlockfd" 2>/dev/null || true
        exec {reqlockfd}<&-

        leg_rc="$(fs_leg_handoff_read "$leg_handoff_dir/rc" 2>/dev/null)"
        [[ "$leg_rc" =~ ^-?[0-9]+$ ]] || leg_rc=1
        fs_leg_handoff_read "$leg_handoff_dir/stdout" || leg_rc=1
        fs_leg_handoff_read "$leg_handoff_dir/stderr" >&2 || leg_rc=1
        exit "$leg_rc"
    )
}

# fs_leg_handoff_read PATH: writes PATH's content to this function's own
# stdout, bounded in both size and time, and refuses outright -- writing
# nothing, returning nonzero -- unless PATH is a plain regular file no
# larger than the configured cap.
#
# Why: a leg can see the whole hand-off volume while it runs (see
# fs_run_leg_split's own comment on the token), and before it exits it can
# replace its own stdout or stderr file with a FIFO or a symlink. That is a
# filesystem change, not a process, so fork-sandbox-k8s-leg-loop.sh's own
# sweep -- which kills every process the exiting leg could have started --
# does not undo it. A plain, unbounded `cat` of a FIFO with no writer left
# blocks forever: the run never reports approved, but the pod hangs until
# its deadline instead of failing within it. The time cap is defense in
# depth against a read that blocks for some other reason even once the
# type and size checks above have passed.
#
# The size check is a separate `stat`, not "read up to the cap and call it
# done": `head -c N` exits 0 whether or not the file actually had more than
# N bytes, so reading through it alone cannot tell a file that fits from
# one truncated at the cap -- it would make a leg's oversized regular file
# succeed with silently truncated content instead of failing the request,
# the same hole a FIFO or symlink closes by failing instead of hanging.
# `stat` reads metadata only, so checking size first, before ever reading
# the content, costs nothing extra against a file sized up to the leg-
# writable volumes' own sizeLimit (K8S_LEG_VOLUME_SIZE_LIMIT in
# fork-sandbox-k8s.sh).
#
# No TOCTOU window worth closing: by the time fs_run_leg_split calls this,
# it has already seen $leg_handoff_dir/done, which the leg loop writes only
# once its sweep confirms every process that request's leg could have
# started is dead -- so nothing is left alive to swap PATH out between the
# checks below and the read.
fs_leg_handoff_read() {
    local path="$1" max="${FORK_SANDBOX_LEG_OUTPUT_MAX_BYTES:-16777216}" size
    if [[ -L "$path" ]] || [[ ! -f "$path" ]]; then
        printf 'fork-sandbox: refusing to read %s: not a plain regular file\n' "$path" >&2
        return 1
    fi
    size="$("$FS_TIMEOUT" "${FORK_SANDBOX_LEG_OUTPUT_TIMEOUT:-20}" stat -c '%s' -- "$path" 2>/dev/null)"
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        printf 'fork-sandbox: refusing to read %s: could not determine its size\n' "$path" >&2
        return 1
    fi
    if (( size > max )); then
        printf 'fork-sandbox: refusing to read %s: %s bytes over the %s-byte cap\n' \
            "$path" "$size" "$max" >&2
        return 1
    fi
    "$FS_TIMEOUT" "${FORK_SANDBOX_LEG_OUTPUT_TIMEOUT:-20}" head -c "$max" -- "$path"
}

# The tidy leg's own variant: same lock-fd close, but records this
# subshell's pid and start time into $1 (fs_record_tidy_leg_pgid, in the
# lib) and THEN `exec`s the rest of argv (GNU timeout, per the leg's own
# wrap -- see run_leg's tidy block) rather than merely running it. `exec`
# keeps the subshell's pid rather than forking a new one, and since
# timeout runs without --foreground it becomes that pid's own process
# group leader the moment it starts -- so the pid recorded here, before
# the leg it names even exists, is exactly the group fork-sandbox-stop.sh
# must later find and signal.
fs_run_tidy_leg() {
    local pgid_file="$1"; shift
    ( { exec {clone_lock_fd}>&-; } 2>/dev/null
      fs_record_tidy_leg_pgid "$pgid_file"
      exec "$@" )
}

# --------------------------------------------------------- claude retry ----
# The backstop for a claude leg that dies on the provider's own auth or
# transient failure rather than on anything this run did: the host refreshing
# its shared OAuth credential revokes the sandbox's copy mid-run, and a
# 5xx/overloaded response is nobody's fault either. Every claude leg this
# runner starts -- the implement leg below, a --refresh-at continuation, and
# every review/fix/maintainer/composed leg through run_leg -- runs through
# fs_run_claude_leg_with_retry, which restarts a leg that fails this way
# fresh (never a resume) up to once per entry of FS_LEG_RETRY_DELAYS_ARR,
# with the wait between attempts interruptible by a stop request. codex and
# pi legs are untouched: this whole mechanism is gated on the harness being
# claude, and neither its own resume-retry (codex) nor its retry-exhaustion
# accounting (pi) is disturbed.
IFS=' ' read -r -a FS_LEG_RETRY_DELAYS_ARR <<< "${FS_LEG_RETRY_DELAYS:-30 120}"
# The run-wide total, folded into summary.json's own leg_retries -- a status
# line's one-glyph way to notice a flaky credential without reading every
# leg's own record.
total_leg_retries=0

# fs_leg_error_retryable is in fork-sandbox-lib.sh, shared with the k8s
# entrypoint's own claude-leg retry.

# fs_leg_retry_wait <seconds>: sleep, but in chunks of at most 5s so a stop
# request lands within that long rather than waiting out the whole backoff --
# up to 120s by default. Returns 1 (and stops waiting) the moment
# stop_requested is set, whether that happens between chunks or was already
# true going in; 0 once the full wait elapsed with no stop seen.
fs_leg_retry_wait() {
    local total="${1:-0}" waited=0 chunk
    while (( waited < total )); do
        if [[ "${stop_requested:-0}" == 1 ]]; then
            return 1
        fi
        chunk=5
        (( total - waited < chunk )) && chunk=$(( total - waited ))
        sleep "$chunk"
        waited=$(( waited + chunk ))
    done
    [[ "${stop_requested:-0}" == 1 ]] && return 1
    return 0
}

# fs_run_claude_leg_with_retry <harness> <events-file> <sandbox-log> \
#     <description> <attempt-fn> <formatter>
#
# <attempt-fn> is a zero-argument function that runs one attempt at the leg
# -- exactly the invocation a caller ran unconditionally before this existed
# -- and sets _fs_leg_attempt_rc to its exit code; it must write this
# attempt's own events into <events-file> (and may also tee into any other,
# cumulative file of the caller's own -- this driver never touches those,
# only <events-file> itself). The first attempt always runs. When the
# harness is claude and it failed on a fs_leg_error_retryable error, the
# leg is restarted, fresh, once per entry of FS_LEG_RETRY_DELAYS_ARR, unless
# a stop was requested during the backoff -- which ends the leg on the
# attempt already made, with no further attempt, exactly as the failure
# would have ended it without this mechanism at all. Before each retry, the
# attempt that just failed has its events file moved aside to
# "<events-file>.attempt<k>" and <events-file> itself truncated, so the file
# left at that name after the LAST attempt -- success or exhaustion -- is
# always that attempt's own, which is what fork-sandbox-status.sh,
# fs_harness_error and every formatter already expect to read.
#
# Sets fs_retry_rc (the final attempt's exit code), fs_retry_error (its own
# provider error, or empty), fs_retry_records (a JSON array of
# {attempt, error, delay_s}, "[]" when nothing was retried), fs_retry_count
# (how many retries actually ran), fs_retry_extra_cost (the summed --cost of
# every archived attempt that priced, via <formatter>, when at least one
# retry ran; empty otherwise) and fs_retry_cost_unknown (1 when at least one
# archived attempt ran but did not price, which makes fs_retry_extra_cost a
# partial sum rather than a complete one; 0 otherwise). The caller's own
# cost for <events-file> still has to be added to fs_retry_extra_cost
# separately, since this driver never reads the caller's cost convention --
# but a caller MUST treat the combined leg cost as unknown, not as
# fs_retry_extra_cost alone, whenever fs_retry_cost_unknown is 1 or its own
# final-attempt cost is itself unpriced: a sum is only honest when every
# part is a number.
fs_run_claude_leg_with_retry() {
    local harness="$1" events_file="$2" sandbox_log="$3" desc="$4" \
        attempt_fn="$5" fmt="$6"
    local rc err attempt=0 delay num_delays="${#FS_LEG_RETRY_DELAYS_ARR[@]}"
    fs_retry_records='[]'
    fs_retry_count=0
    fs_retry_extra_cost=""
    fs_retry_cost_unknown=0
    # A runner re-run by hand in the same run dir (see the pi-session-copy
    # precedent above, in run_leg) is the case that leaves a stale
    # "<events_file>.attemptN" from an earlier invocation lying around; the
    # cost walk below globs every such file, so an old one left in place
    # would bill this invocation for usage it never spent. This leg has not
    # made its first attempt yet, so any archive already at this name belongs
    # to a previous invocation, never this one.
    rm -f -- "$events_file".attempt* 2>/dev/null
    "$attempt_fn"
    rc="$_fs_leg_attempt_rc"
    err=""
    [[ "$rc" != 0 ]] && err="$(fs_harness_error "$harness" "$events_file")"
    fs_retry_rc="$rc"
    fs_retry_error="$err"
    if [[ "$harness" == claude ]] && fs_leg_error_retryable "$harness" "$err"; then
        for delay in "${FS_LEG_RETRY_DELAYS_ARR[@]}"; do
            (( attempt++ ))
            printf 'fork-sandbox: %s failed on a transient error (%s); retry %s/%s in %ss\n' \
                "$desc" "$err" "$attempt" "$num_delays" "$delay" >> "$sandbox_log"
            if ! fs_leg_retry_wait "$delay"; then
                printf 'fork-sandbox: %s: stop requested during the retry backoff; retry %s/%s cancelled\n' \
                    "$desc" "$attempt" "$num_delays" >> "$sandbox_log"
                attempt=$(( attempt - 1 ))
                break
            fi
            mv -f -- "$events_file" "${events_file}.attempt${attempt}" 2>/dev/null
            : > "$events_file"
            fs_retry_records="$(jq -cn --argjson old "$fs_retry_records" \
                --argjson attempt "$attempt" --arg error "$err" --argjson delay "$delay" \
                '$old + [{attempt: $attempt, error: $error, delay_s: $delay}]' 2>/dev/null)"
            [[ -n "$fs_retry_records" ]] || fs_retry_records='[]'
            "$attempt_fn"
            rc="$_fs_leg_attempt_rc"
            err=""
            [[ "$rc" != 0 ]] && err="$(fs_harness_error "$harness" "$events_file")"
            fs_retry_rc="$rc"
            fs_retry_error="$err"
            if [[ "$rc" == 0 ]]; then
                printf 'fork-sandbox: %s succeeded on retry %s\n' "$desc" "$attempt" >> "$sandbox_log"
                break
            fi
            fs_leg_error_retryable "$harness" "$err" || break
        done
        fs_retry_count="$attempt"
        if [[ "$rc" != 0 && "$attempt" == "$num_delays" ]]; then
            printf 'fork-sandbox: %s failed after %s retries\n' "$desc" "$num_delays" >> "$sandbox_log"
        fi
    fi
    if (( fs_retry_count > 0 )) && [[ -n "$fmt" ]]; then
        local f cost_i
        for f in "$events_file".attempt*; do
            [[ -f "$f" ]] || continue
            cost_i="$("$fmt" --cost "$f" 2>/dev/null)"
            if [[ "$cost_i" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                if [[ -n "$fs_retry_extra_cost" ]]; then
                    fs_retry_extra_cost="$(jq -n --argjson a "$fs_retry_extra_cost" --argjson b "$cost_i" \
                        '$a + $b' 2>/dev/null)"
                else
                    fs_retry_extra_cost="$cost_i"
                fi
            else
                # This archived attempt ran (it left an events file) but did
                # not price. fs_retry_extra_cost above is still only the sum
                # of the OTHER attempts, so it must not be mistaken for the
                # complete archived cost -- tell the caller so.
                fs_retry_cost_unknown=1
            fi
        done
    fi
}

# A short, human-readable clause naming how many retries a leg burned before
# it finally failed -- appended to a harness-error detail so "it failed after
# 2 retries" is not left only to sandbox.log's own line for the last one.
# Silent (prints nothing) when n is 0, so appending it to every harness-error
# detail unconditionally is always safe.
fs_leg_retry_suffix() {
    local n="${1:-0}"
    (( n > 0 )) || return 0
    if (( n == 1 )); then
        printf ' (failed after 1 retry)'
    else
        printf ' (failed after %s retries)' "$n"
    fi
}

# The first code step retains the historical top-level implementation leg
# (and therefore events.jsonl). Its composed seat nevertheless owns the
# command; later code steps run through run_leg below. This has to run here,
# inside the runner, not in the launcher: composed_pipeline and run_step_*
# are runner-only values, printed into this file as literal assignments
# above -- the launcher process itself never has them.
if [[ "${composed_pipeline:-0}" == 1 ]]; then
    for (( _fs_step = 1; _fs_step <= run_step_count; _fs_step++ )); do
        if [[ "${run_step_kind[$_fs_step]}" == code ]]; then
            declare -n _fs_first_cmd="${run_step_idx[$_fs_step]}_sandbox_cmd"
            impl_sandbox_cmd=("${_fs_first_cmd[@]}")
            sandbox_cmd=("${_fs_first_cmd[@]}")
            unset -n _fs_first_cmd
            break
        fi
    done
fi

# The two coding-leg argvs. The launcher emits them only on a
# --session-state run, where the coding legs differ from every other leg by
# the transcript-store bind; with no such flag there is nothing to differ by
# and both are sandbox_cmd itself. Defaulted here rather than always emitted,
# so a run without the flag carries no state for a feature it never used.
impl_sandbox_cmd=("${impl_sandbox_cmd[@]-${sandbox_cmd[@]}}")
cont_sandbox_cmd=("${cont_sandbox_cmd[@]-${sandbox_cmd[@]}}")

events="$run_dir/events.jsonl"
sandbox_log="$run_dir/sandbox.log"

printf '%s\n' "$$" > "$run_dir/pid"
# Drop the previous run's exit code, so a manual re-run reads as running
# rather than as already finished.
rm -f "$run_dir/exit-code"
: > "$events"
: > "$sandbox_log"
if [[ -n "$brief_warning" ]]; then
    printf '%s\n' "$brief_warning" >> "$sandbox_log"
fi
if [[ -n "$run_scope_note" ]]; then
    printf '%s\n' "$run_scope_note" >> "$sandbox_log"
fi

# progress.json: a live, one-glyph-per-step status file a status line (or
# any other reader outside this run) can poll without shelling into tmux or
# reading the event log. Rewritten atomically -- build beside the
# destination and rename -- at every step/leg/run transition below.
# progress_state/progress_i/progress_ended are 1-indexed, parallel to
# run_step_kind/idx/cap: "pending" until a step's first leg starts,
# "running" while it is the active step, then "done", "failed" or
# "skipped". Writing this file must never fail the run, so every jq call
# below is best-effort and every write falls back to removing its own
# .part rather than leaving a half-written file behind.
declare -a progress_state=() progress_i=() progress_ended=() progress_continuation=()
for (( _pg_k = 1; _pg_k <= run_step_count; _pg_k++ )); do
    progress_state[_pg_k]="pending"
    progress_i[_pg_k]=0
    progress_ended[_pg_k]=""
    progress_continuation[_pg_k]=0
done
# Set the moment any step's state becomes "failed" -- a harness error in a
# review/maintainer loop does not by itself change $rc (see the walker's own
# comment on that below), so the run-level state this writes has to track
# failure independently of $rc rather than only at the very end.
progress_any_step_failed=0
# Set the first time a write below actually fails, so the one diagnostic
# line this can leave in sandbox_log never repeats across dozens of later
# writes in the same run.
progress_write_failure_logged=0

progress_write() {
    local run_state="$1" _pg_j action ended_val step_json steps_ndjson="" \
        pg_active="run" pg_err pg_rc
    for (( _pg_j = 1; _pg_j <= run_step_count; _pg_j++ )); do
        action="${run_step_kind[_pg_j]}"
        [[ "$action" == maintainer ]] && action="maintain"
        [[ "${progress_state[_pg_j]}" == running ]] && pg_active="step $_pg_j ($action)"
        ended_val="${progress_ended[_pg_j]:-}"
        step_json="$(jq -cn \
            --arg action "$action" \
            --arg state "${progress_state[_pg_j]}" \
            --argjson i "${progress_i[_pg_j]:-0}" \
            --argjson cap "${run_step_cap[_pg_j]}" \
            --arg ended "$ended_val" \
            --argjson continuation "${progress_continuation[_pg_j]:-0}" \
            '{action:$action, state:$state, i:$i, cap:$cap,
              ended:(if $ended == "" then null else $ended end),
              continuation:$continuation}' \
            2>/dev/null)" || step_json=""
        [[ -n "$step_json" ]] && steps_ndjson+="$step_json"$'\n'
    done
    # stderr first, so the redirect below only moves jq's stdout -- the
    # JSON itself -- to the .part file; pg_err keeps whatever jq wrote to
    # its own stderr, read back below only on failure.
    pg_err="$(jq -n \
        --arg run_label "$progress_label" \
        --arg spec "$progress_spec" \
        --arg state "$run_state" \
        --argjson updated "$(date +%s)" \
        --argjson steps "$(printf '%s' "$steps_ndjson" | jq -cs '.' 2>/dev/null || printf '[]')" \
        '{schema:1, "label":$run_label,
          spec:(if $spec == "" then null else $spec end),
          state:$state, updated:$updated, steps:$steps}' \
        2>&1 > "$run_dir/progress.json.part")"
    pg_rc=$?
    if (( pg_rc == 0 )) && mv -f "$run_dir/progress.json.part" "$run_dir/progress.json" 2>/dev/null; then
        return 0
    fi
    rm -f "$run_dir/progress.json.part" 2>/dev/null
    if (( ! progress_write_failure_logged )); then
        progress_write_failure_logged=1
        printf 'fork-sandbox: progress.json write failed on %s (run state %s): %s\n' \
            "$pg_active" "$run_state" "${pg_err:-progress.json.part could not be renamed}" \
            >> "$sandbox_log" 2>/dev/null
    fi
}
progress_write running

# Every later leg of this run -- a --refresh-at continuation, a review leg, a
# fix leg -- is a fresh sandbox with a fresh /tmp, bound to this same inbox
# directory. fork-sandbox-inbox-hook.sh's seen-list lives in that ephemeral
# /tmp, so without this, a later leg would re-read every addendum ever sent
# to the run, with no memory of anyone acting on it. The hook's Stop contract
# guarantees a session cannot end with an addendum unread, so at the moment a
# leg ends, every '*.md' in the inbox has already been delivered to it: move
# each one out into that leg's own record. $1 is the leg number the console
# log and --monitor use -- the implement leg is 1, and continuation, review
# and fix legs continue the count in the order they ran. $2 is the harness
# THAT LEG actually ran on: the Stop-contract guarantee above only holds on
# claude, which is the only harness the hook is installed for (see the
# harness check above the inbox_hook/inbox_settings block) -- every other
# harness only asks the session in its prompt to go look, and cannot enforce
# it, so a leg that ran pi/pi-local/codex may end with an addendum it never
# read. Archiving that file anyway would not just mislabel it: it moves the
# addendum out of the live inbox path the NEXT leg's own prompt names, into
# a numbered directory nothing but a --refresh-at continuation ever reads
# back, so it would never reach any session at all. Skip the move on any
# non-claude leg and leave the file where every leg's prompt already tells
# the agent to look. $3 is that leg's own exit code: the Stop hook only runs
# as part of the model ending its turn, so a leg that was killed, timed out,
# or otherwise exited non-zero never ran it, and any addendum sitting in the
# inbox at that point was never subject to the "cannot end with it unread"
# guarantee either -- skip the move for the same reason a non-claude leg
# does, and leave it for a later leg to actually see. This does not close
# the narrower race where a write lands after the Stop hook already let a
# clean-exit leg go but before this function runs (the pipeline still
# draining through tee) -- that is a pre-existing property of any Stop-hook-
# guarded workflow, not something archiving introduced, and closing it needs
# the hook to record which files it actually marked seen, not a leg-level
# rc check. The path is built from run_dir, the same fixed-name discipline
# fork-sandbox-status.sh's resolve_run_subdir uses, rather than threaded in
# as its own variable: this runner is a generated, standalone script, and
# run_dir is the one thing about the inbox it already carries. The dotfiles
# the hook and --refresh-at share the inbox with (.inbox-hook.sh,
# .settings.json, .refresh-config) are untouched by the '*.md' glob already.
# A symlink is refused rather than followed -- the inbox is host-written and
# nothing should ever put one there, but archiving is a move, and following
# a link out of the inbox is not a mistake worth making possible.
#
# 'mail-banner-*.md' (fork-sandbox-postmaster.sh's pm_deliver_live) is moved
# too, but into a SEPARATE destination, mail-delivered/leg-<N>/ rather than
# inbox-delivered/leg-<N>/: it must leave the live inbox exactly like an
# addendum does -- this run's inbox_dir is the same read-only bind every leg's
# sandbox gets, so a banner left behind would sit there for the next leg's
# fresh /tmp (a fresh seen-list) to re-read and re-deliver, unread, through
# the hook all over again. But it must NOT come back through
# fs_addenda_dirs/refresh_build_prompt (or the review/maintainer loops' own
# copies of that logic), which reads every '*.md' under inbox-delivered/ back
# as an "operator addendum ... carries the same authority as the brief and
# outranks it" -- true of an addendum, false of a mail banner, which is new
# thread information from the postmaster, not an operator instruction, and
# which this same leg's Stop hook already confirmed was delivered before this
# function ever runs. A separate directory nothing reads back satisfies both:
# gone from the live inbox, and never re-surfaced under the wrong authority.
fs_archive_inbox() {
    local leg_no="$1" leg_harness="$2" leg_rc="$3"
    [[ "$leg_harness" == "claude" && "$leg_rc" == "0" ]] || return 0
    fs_refresh_archive_inbox "$run_dir/inbox" "$run_dir" "$leg_no" "$sandbox_log"
}

# Every addendum fs_archive_inbox has moved out of a strictly earlier leg of
# THIS run, oldest first: sorted by leg number rather than by directory name,
# since "leg-10" must not sort before "leg-2". One line per inbox-delivered
# leg directory. Shared by refresh_build_prompt below and the review loop
# further down -- both need "every earlier leg's addenda, in order", not
# just what happens to still be sitting in the live inbox this leg's own
# sandbox has bound.
fs_addenda_dirs() {
    fs_refresh_addenda_dirs "$run_dir"
}

printf '== fork-sandbox ==\n'
printf 'harness: %s\n' "$harness"
printf 'branch:  %s\n' "$branch"
printf 'origin:  %s\n' "$origin_repo"
printf 'clone:   %s\n' "$clone_dir"
printf 'log:     %s\n' "$events"
printf '\nHeadless. Nothing here needs a keypress; the session exits on its own.\n\n'

# codex's credential is built here, when the run starts, rather than by the
# launcher — a run that sits in a queue would otherwise carry a token that
# aged while it waited. The refresh token is replaced by a placeholder: the
# real one is single-use, so a sandbox that spent it would silently log the
# host out of codex. codex only refreshes when the access token has
# expired, so this run works and simply cannot rotate the host's
# credential. The file is 0600 and goes, with its directory, when this
# script does. Up to three legs (implement, review, maintainer) each
# resolved their own codex harness, so codex_auth_dirs holds every such
# directory the launcher made.
# The lock is released separately, by release_clone_lock below, not here:
# this function runs as soon as the harness session ends, but the workspace
# is still in use well past that point -- the branch fetch-back, the 0-commit
# branch removal, and the summary all still read it, and every one of those
# needs the lock held. Releasing it here would open the workspace to a
# concurrent run (or `fleet teardown`) while this run's most consequential
# work was still ahead of it.
#
# Cleanup that must run however this session ends — a normal exit, an error, or
# a kill. It removes every codex credential directory and tears the per-run
# services down.
# It runs its body once (a --keep-session run calls it inline before the exec,
# which never reaches an EXIT trap; the trap catches every other ending).
run_cleanup() {
    [[ -n "${_cleanup_done:-}" ]] && return 0
    _cleanup_done=1
    if [[ "${#codex_auth_dirs[@]}" -gt 0 ]]; then
        for codex_auth_dir in "${codex_auth_dirs[@]}"; do
            rm -rf "$codex_auth_dir"
        done
    fi
    if [[ "$services_enabled" == "1" && -n "$services_script" ]]; then
        # timeout on every docker-touching command here: this function is the
        # EXIT trap, and a wedged docker daemon must not hang the run forever
        # with the output hidden in sandbox.log.
        "$FS_TIMEOUT" 120 "$services_script" down "$services_project" \
            >> "$sandbox_log" 2>&1 || true
        # Opportunistic sweep: remove any claude-* compose project whose run
        # dir is gone. A session killed before this ran can leak one; catch it
        # on the next run's teardown. Best-effort, never fatal.
        if command -v docker >/dev/null 2>&1; then
            local live=" " d bn p orphan
            for d in /var/tmp/claude-scratch/forks/claude-fork-sandbox.*/; do
                [[ -d "$d" ]] || continue
                # Both name forms per run dir: with the cksum suffix (what the
                # launcher derives now) and without it (what runs launched
                # before the suffix existed still use). Dropping the old form
                # would sweep a live old-format run's services out from under
                # it during the transition.
                bn="$(basename "$d")"; p="${bn,,}"; p="${p//[^a-z0-9-]/-}"
                live+="$p $p-$(printf '%s' "$bn" | cksum | cut -d' ' -f1) "
            done
            while IFS= read -r orphan; do
                # Only projects this script creates: the run-dir basename,
                # sanitized. A bare claude-* would sweep unrelated user projects.
                case "$orphan" in claude-fork-sandbox-*) ;; *) continue ;; esac
                [[ "$live" == *" $orphan "* ]] && continue
                # The run dir is gone, so its compose file is too. Remove the
                # project's resources by their compose label rather than through
                # a compose file that no longer exists.
                # `xargs -r` would be the natural way to skip an empty list,
                # but BSD xargs rejects the flag rather than ignoring it, so
                # the whole sweep would fail on a Mac. Collect and test here,
                # which needs no flag at all.
                for what in ps network volume; do
                    case "$what" in
                        ps)      ids="$("$FS_TIMEOUT" 60 docker ps -aq --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                        network) ids="$("$FS_TIMEOUT" 60 docker network ls -q --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                        volume)  ids="$("$FS_TIMEOUT" 60 docker volume ls -q --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                    esac
                    [[ -n "$ids" ]] || continue
                    case "$what" in
                        ps)      printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker rm -f >> "$sandbox_log" 2>&1 || true ;;
                        network) printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker network rm >> "$sandbox_log" 2>&1 || true ;;
                        volume)  printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker volume rm >> "$sandbox_log" 2>&1 || true ;;
                    esac
                done
            done < <("$FS_TIMEOUT" 60 docker compose ls -a --format json 2>/dev/null \
                     | jq -r 'if type == "array" then .[] else . end
                              | .Name' 2>/dev/null || true)
            # The jq filter takes both shapes compose emits: one JSON array
            # (current `compose ls`) and NDJSON, one object per line (what
            # `compose ps` moved to in v2.21) — assuming one shape makes the
            # sweep a silent permanent no-op on the other.
        fi
    fi
}
# The lock's own release, kept separate from run_cleanup so that function's
# early, inline call (once the harness session ends) cannot let it go before
# the fetch-back, branch removal and summary near the end of this script are
# done with the workspace. Guarded the same way, so calling it again from the
# EXIT trap after this script's own explicit call, near the very end, is a
# no-op rather than a second close of an already-closed fd.
release_clone_lock() {
    [[ -n "${_lock_released:-}" ]] && return 0
    _lock_released=1
    if [[ -n "${clone_lock_fd:-}" ]]; then
        flock -u "$clone_lock_fd" 2>/dev/null || true
        # Braces scope the redirect to just this close: a bare
        # `exec {fd}>&- 2>/dev/null` has no command for exec to run, so its
        # `2>/dev/null` would apply to the whole rest of this script instead
        # of just this one open, silently swallowing every later stderr.
        { exec {clone_lock_fd}>&-; } 2>/dev/null || true
    fi
}
# Tells the leg container (fork-sandbox-k8s-leg-loop.sh) this runner is
# done starting legs, so its own loop -- polling $run_dir/.leg-req for a
# request that will never come once this process is gone -- can exit
# instead of running forever and leaving the pod's Job unable to reach
# Complete. A no-op when FORK_SANDBOX_LEG_HANDOFF_DIR is unset (every run
# but a composed pod one). In the EXIT trap, like run_cleanup and
# release_clone_lock beside it, because this runner can end on success,
# on failure, on a stop request or on an error nobody anticipated, and
# the leg container needs to hear about every one of those, not just the
# happy path. Safe to fire after any point in the run: every request this
# runner issued has already been answered (fs_run_leg_split blocks on
# exactly that) by the time this process is about to exit, so there is no
# in-flight request this could race.
fs_signal_leg_shutdown() {
    [[ -n "${_leg_shutdown_signaled:-}" ]] && return 0
    _leg_shutdown_signaled=1
    [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]] || return 0
    touch "$run_dir/.leg-shutdown" 2>/dev/null || true
}
trap 'fs_signal_leg_shutdown; run_cleanup; release_clone_lock' EXIT
# Every codex seat's credential file, written once here instead of the
# three copy-pasted blocks this replaced (one each for the implement,
# review and maintainer seats, none of which could reach a composed
# step's "s<K>_*"/"s<K>fix_*" names or the legacy fix seats' own
# "fxr_*"/"fxm_*" ones). $codex_auth_src -- the host auth.json read at
# launch -- is the same for every seat; only the refresh token is ever
# replaced, with a placeholder the sandbox cannot use to log the host out.
# The dedupe list keeps a seat whose env file is the very same path as one
# already written (the "rev_*"/"mnt_*" fallback-to-implement case) from
# being rewritten a second time.
_fs_codex_cred_written=()
_fs_write_codex_cred() {
    local ch="$1" cf="$2" p
    [[ "${k8s_runner_mode:-false}" == true ]] && return 0
    [[ "$ch" == codex && -n "$cf" ]] || return 0
    for p in "${_fs_codex_cred_written[@]}"; do
        [[ "$p" == "$cf" ]] && return 0
    done
    install -m 600 /dev/null "$cf"
    {
        printf 'CODEX_AUTH_JSON='
        jq -c '.tokens.refresh_token = "sandbox-placeholder-cannot-refresh"' \
            "$codex_auth_src"
    } > "$cf"
    _fs_codex_cred_written+=("$cf")
}
_fs_write_codex_cred "$harness" "$harness_env_file"
# review_harness is empty without --review-harness, in which case
# rev_harness_env_file already equals harness_env_file (fs_resolve_harness
# was never called a second time -- see the "rev_*" fallback beside
# review_sandbox_cmd, above) and the dedupe above skips the duplicate write.
review_codex_harness="$harness"
[[ -n "$review_harness" ]] && review_codex_harness="$review_harness"
_fs_write_codex_cred "$review_codex_harness" "$rev_harness_env_file"
# maintainer_harness and mnt_harness_env_file are unset entirely in a
# no-maintainer run.sh, so both reads carry defaults.
_fs_write_codex_cred "${maintainer_harness:-$harness}" "${mnt_harness_env_file:-}"
# The legacy fix seats: fix_harness/mntfix_harness and their env-file
# counterparts are unset entirely in a run.sh with no such fix seat.
_fs_write_codex_cred "${fix_harness:-}" "${fxr_harness_env_file:-}"
_fs_write_codex_cred "${mntfix_harness:-}" "${fxm_harness_env_file:-}"
# A composed pipeline's own per-step seats. run_step_idx/run_step_kind are
# always populated -- legacy-translated or not, see their own comment
# above -- so this loop is a no-op for a legacy-shaped or preset-less run,
# where every run_step_idx entry is empty. A step's fix seat is skipped
# for kind "code", which never has one.
for ((_fs_cred_k = 1; _fs_cred_k <= run_step_count; _fs_cred_k++)); do
    _fs_cred_idx="${run_step_idx[_fs_cred_k]}"
    [[ -n "$_fs_cred_idx" ]] || continue
    _fs_cred_hvar="${_fs_cred_idx}_harness"
    _fs_cred_evar="${_fs_cred_idx}_harness_env_file"
    _fs_write_codex_cred "${!_fs_cred_hvar}" "${!_fs_cred_evar}"
    if [[ "${run_step_kind[_fs_cred_k]}" != code ]]; then
        _fs_cred_hvar="${_fs_cred_idx}fix_harness"
        _fs_cred_evar="${_fs_cred_idx}fix_harness_env_file"
        _fs_write_codex_cred "${!_fs_cred_hvar:-}" "${!_fs_cred_evar:-}"
    fi
done
unset _fs_cred_k _fs_cred_idx _fs_cred_hvar _fs_cred_evar

# Per-run services: stand them up before the session and point the project's
# config at the sockets. The teardown is already armed, so a failure here still
# cleans up. A services failure is a warning, not fatal — the session runs, it
# just cannot reach the services.
if [[ "$services_enabled" == "1" && -n "$services_script" ]]; then
    printf 'fork-sandbox: starting per-run services (%s)...\n' "$services_project" >&2
    if ! "$services_script" up "$sockets_dir" "$clone_dir" "$services_project" \
        >> "$sandbox_log" 2>&1; then
        printf 'fork-sandbox: WARNING: services failed to start; see %s.\n' \
            "$sandbox_log" >&2
        printf 'The session runs without them.\n' >&2
        # The prompt's preamble already says the services are up — it was
        # written at launch, before this could fail. Correct it, or the
        # session burns its run debugging sockets that never existed. The
        # prompt is read below, after this block, so both prompt paths see
        # the correction.
        cat >> "$handoff" <<'NOSVC'

---

## Correction: the per-run services FAILED to start

Ignore the "Per-run services are up" section at the top of this prompt.
`docker compose up` failed on the host after that text was written, so there
is no `.env.sandbox` and no socket under the sockets directory works. Treat
the environment as committed state only, and report "the per-run services
failed to start" instead of debugging the missing sockets.
NOSVC
    fi
fi

# The handoff document is the prompt, and every harness reads it on stdin —
# never as an argument. Linux caps one argv string at 128KB (MAX_ARG_STRLEN),
# so an argv prompt makes a big handoff die as exit 126 before the tool even
# starts; stdin has no such cap. pi treats piped stdin as a prompt and forces
# print mode on it; claude and codex read stdin natively. The redirect opens
# the file at exec time, after the services block above, so a failure
# correction appended there still lands in the prompt.

# With --session-state, pi_run_session_dir is the durable cross-wake store
# (see where it is set, above), not a fresh per-run directory -- it already
# holds every earlier wake's turns before this one starts. Snapshot each
# transcript's current line count now, so the accounting below can take
# only what THIS run appends, not the whole store's history.
declare -A pi_run_session_baseline_lines=()
if [[ -n "$pi_run_session_dir" && -d "$pi_run_session_dir" ]]; then
    while IFS= read -r -d '' pi_baseline_file; do
        pi_run_session_baseline_lines["$pi_baseline_file"]="$(wc -l < "$pi_baseline_file" 2>/dev/null || echo 0)"
    done < <(find "$pi_run_session_dir" -name '*.jsonl' -type f -print0 2>/dev/null)
fi

# stdout is the session's output: tee keeps the raw copy in the event log,
# and the formatter renders it live when there is one to render. The
# sandbox's own messages go to stderr, which is copied to the log and shown
# here too.
rc=0
# 0 when step 1 is not code: the first code leg then runs in the walker,
# and the refresh loop and the total cost must not count an implement leg.
fs_impl_leg_ran_at_step1=0
if [[ "$mode" != "review-only" ]] && { [[ "${composed_pipeline:-0}" != 1 ]] || [[ "${run_step_kind[1]}" == code ]]; }; then
fs_impl_leg_ran_at_step1=1
# This block is always step 1's own pass 1 -- see the condition just above,
# which only ever runs when run_step_kind[1] is code. The walker below
# finalizes this step (to done or failed) once it knows there are no more
# repeat passes or --refresh-at continuations coming; here it only becomes
# the active step.
progress_state[1]="running"
progress_i[1]=1
progress_write running
# stderr goes through a real pipeline into $sandbox_log, not a `2> >(tee)`
# process substitution: bash does not wait on the latter (claude-sandboxed's
# own RESUME_FAIL_RE names this exact hazard beside its ERR_CAPTURE), so
# $sandbox_log could still be unwritten when the codex retry check below
# greps it. fd 3 carries this attempt's own stdout past the inner pipe
# untouched, into the same $events/$formatter tee the process substitution
# form used to feed directly; the trailing `exit` makes the group's own
# exit code the command's, not tee's, since PIPESTATUS[0] below reads the
# group as a single pipeline stage.
_fs_impl_attempt_n=0
_fs_impl_attempt() {
    # The first attempt is the caller's own coding session -- --resume-session
    # asked for, if any -- but a retry must never replay that: the handoff's
    # "restart fresh" rule applies here exactly as it does to the codex
    # resume-retry below, so every attempt after the first runs
    # cont_sandbox_cmd instead, the same fresh, never-resumed command a
    # --refresh-at continuation uses.
    local _fs_impl_cmd=("${impl_sandbox_cmd[@]}")
    (( _fs_impl_attempt_n > 0 )) && _fs_impl_cmd=("${cont_sandbox_cmd[@]}")
    (( _fs_impl_attempt_n++ ))
    if [[ -n "$formatter" ]]; then
        { fs_run_lock_closed "${_fs_impl_cmd[@]}" < "$handoff" \
            2>&1 1>&3 | tee -a "$sandbox_log" >&2
          exit "${PIPESTATUS[0]}"
        } 3>&1 \
            | tee -a "$events" \
            | "$formatter"
    else
        { fs_run_lock_closed "${_fs_impl_cmd[@]}" < "$handoff" \
            2>&1 1>&3 | tee -a "$sandbox_log" >&2
          exit "${PIPESTATUS[0]}"
        } 3>&1 \
            | tee -a "$events"
    fi
    _fs_leg_attempt_rc="${PIPESTATUS[0]:-1}"
}
fs_run_claude_leg_with_retry "$harness" "$events" "$sandbox_log" \
    "the implement leg" _fs_impl_attempt "$formatter"
rc="$fs_retry_rc"
impl_leg_retries_count="$fs_retry_count"
impl_leg_retries_json="$fs_retry_records"
total_leg_retries=$(( total_leg_retries + impl_leg_retries_count ))
# Folded into run_cost once that is computed, below, the same way a
# retried review/fix/maintainer leg's archived cost joins its own leg_cost:
# this is the implement leg's OWN price, not the loop's, so it belongs in
# cost_usd, not loop_cost_sum.
impl_leg_retry_extra_cost="$fs_retry_extra_cost"
impl_leg_retry_cost_unknown="$fs_retry_cost_unknown"
# Resume is a continuity optimization for codex too (see claude-sandboxed's
# own RESUME_FAIL_RE for the analogous claude case, unreachable here because
# codex runs through claude-sandboxed's --exec mode, which claude-sandboxed
# itself refuses to combine with --session-state/--resume-session). A codex
# resume that fails on a missing rollout must not cost the caller the wake:
# retry ONCE, fresh -- cont_sandbox_cmd, never spliced with `resume`, already
# binds the same durable session store (see fs_build_sandbox_cmd's codex
# arm) -- a second failure is the run's own. Host-verified: `codex exec
# --json resume <bad-id> -` prints exactly this text to STDERR and exits 1;
# the match is deliberately narrower than codex's full wording
# ("thread/resume: thread/resume failed: ...") since only the
# rollout-not-found fragment is the actual failure signature -- a false
# positive here reruns a session that already did its work, at full price.
# Neither $sandbox_log nor $events is truncated before the retry: both are
# real, user-facing artifacts (accounting below reads $events in full, and a
# human debugging a double-failure needs both attempts' stderr), and there
# is no second grep of either after this one retry.
CODEX_RESUME_FAIL_RE='no rollout found for thread id .* \(code -32600\)'
if [[ "$rc" != "0" && "$harness" == codex && -n "$session_state" \
    && -n "$resume_session" ]] \
    && grep -qiE "$CODEX_RESUME_FAIL_RE" "$sandbox_log"; then
    echo "fork-sandbox: codex resume failed, retrying fresh (session $resume_session)" >&2
    if [[ -n "$formatter" ]]; then
        fs_run_lock_closed "${cont_sandbox_cmd[@]}" < "$handoff" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$events" \
            | "$formatter"
    else
        fs_run_lock_closed "${cont_sandbox_cmd[@]}" < "$handoff" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$events"
    fi
    rc="${PIPESTATUS[0]:-1}"
fi
# The implement leg is leg 1. Archive right after its exit code is known,
# same as every later leg below.
fs_archive_inbox 1 "$harness" "$rc"
progress_write running
# exit-code is what fork-sandbox-status.sh reads as "this run is over": it
# reports the run finished the moment the file exists, and --monitor fires its
# one terminal event there. With a review loop still to come that would be a
# lie -- the branch has not been fetched, the summary is not written, and the
# loop is about to move the head under whoever just read "finished". So for a
# --review-loop run the exit code is published after the loop instead, where
# the run really does end; the pid file keeps the state honest as "running"
# until then. A run without the flag is untouched and writes it here as
# always. --refresh-at defers the same way, and for the same reason: a
# continuation leg can still change $rc below.
if [[ "$refresh_enabled" == "0" && "${composed_pipeline:-0}" != 1 \
    && "$run_step_count" == "1" && "${run_step_kind[1]}" == code \
    && "${run_step_cap[1]}" == "1" ]]; then
    printf '%s\n' "$rc" > "$run_dir/exit-code"
fi
fi

# The credential and the services are NOT cleaned up here. --review-loop can
# start further sessions below, in the same sandbox, on the same harness: a
# codex leg needs the credential this run wrote, and a fix leg may run the
# suite, which needs the services. run_cleanup happens once the loop is done,
# before the fetch. The EXIT trap is the backstop for every path that never
# reaches it.

# A pi-local run usually carries no --model: agent-sandboxed discovers the
# model from the endpoint, so this script never saw it and the run record
# would say null. Recover it from the banner agent-sandboxed prints into the
# log. The model id is the one whitespace-free token between "pi against " and
# " at ", so match a run of non-space characters. Take the first banner only.
if [[ -z "$model" && -s "$sandbox_log" ]]; then
    model="$(sed -n 's/^agent-sandboxed: pi against \([^ ]*\) at .*/\1/p' \
        "$sandbox_log" | head -n1)"
fi

# run.env/summary.json's flat harness/harness_version/model fields, same
# exception as the launcher's own $record_harness/$record_model (which wrote
# run.env's first copy of these three): a maintain-only read-only pipeline's
# implement seat is phantom and never runs a leg, so $harness/$model/
# $harness_version here still name that seat's own definition, not the
# maintainer leg that actually ran. mode == review-only with review_loop_cap
# left at its default 0 is exactly that shape -- every other review-only run
# forces review_loop_cap to 1 (see the launcher's own forcing beside
# "A read-only pipeline of one maintain step has no review leg."), so this
# reads back the same fact the launcher decided from, without needing a new
# variable threaded through just to carry it.
record_harness="$harness"
record_harness_version="$harness_version"
record_model="$model"
if [[ "$mode" == "review-only" && "$review_loop_cap" == "0" \
    && "${composed_pipeline:-0}" != 1 ]]; then
    record_harness="$maintainer_harness"
    record_harness_version="$mnt_harness_version"
    record_model="$maintainer_model"
fi
# A composed pipeline's $harness/$model name the phantom "impl" seat; record
# step 1 instead. s1_model is empty for a pi-local step 1 with no model (it
# is discovered at run time), so fall back to $model, banner-recovered above.
if [[ "${composed_pipeline:-0}" == 1 ]]; then
    record_harness="$s1_harness"
    [[ "$record_harness" == "pi-local" ]] && record_harness="pi"
    record_harness_version="$s1_harness_version"
    record_model="${s1_model:-$model}"
fi

# Every pi-local seat in this run -- any step (code, review or maintain)
# whose harness/network pair reads "pi"/"sealed" with no model yet, and any
# fix seat whose harness reads the literal "pi-local" -- owes the reader the
# same backfill: config_dir/model.env is one file per machine, not one per
# seat, so every pi-local seat in a single run necessarily discovers the
# same model. Leaving one null would give the identical physical seat two
# encodings in one file. This is true whether or not that seat's own leg
# ever actually runs (a later step can be skipped, or a fix seat never
# triggered) -- it will discover the identical model the moment it does,
# so there is nothing to lose by writing it in now.
#
# This script is the generated run.sh, a separate program from the launcher
# that wrote pipeline.json -- run_step_kind is a launcher-only array that
# never reaches here, so this has to read the fact back out of pipeline.json
# itself rather than out of that array. -s guards a run that never wrote
# pipeline.json at all (no preset, or --review-only, whose step 0 is review
# and so the harness/network check leaves it untouched regardless).
#
# A step's own harness/network pair already reads "pi"/"sealed" only after
# the compile-time pi-local expansion (see pipeline.json's own emission
# block above); a fix seat's harness keeps the literal "pi-local" spelling
# instead, because the fix schema carries no network field to say "sealed"
# any other way -- so the two seat flavors need two different match
# conditions in the filter below, not one.
if [[ -n "$model" && -s "$run_dir/pipeline.json" ]]; then
    if jq --arg model "$model" \
        '.steps |= map(
             if .harness == "pi" and .network == "sealed" and .model == null
             then .model = $model
             else . end)
         | .steps |= map(
             if .fix != null and .fix.harness == "pi-local" and .fix.model == null
             then .fix.model = $model
             else . end)' \
        "$run_dir/pipeline.json" > "$run_dir/pipeline.json.part" 2>/dev/null; then
        mv -f "$run_dir/pipeline.json.part" "$run_dir/pipeline.json"
    else
        rm -f "$run_dir/pipeline.json.part"
    fi
fi

# The branch head, read from the clone the one way anything here may read it:
# over upload-pack from outside, exactly like the fetch below. Nothing runs git
# INSIDE the clone -- the sandbox can write its config, and a key such as
# core.fsmonitor runs on the HOST. Run from run_dir, not origin_repo: this
# helper needs nowhere in particular to stand, only somewhere outside the
# clone, and run_dir is the one directory both a local run and a pod run
# always have.
clone_branch_head() {
    (cd "$run_dir" && git ls-remote "$clone_dir" "refs/heads/$branch" \
        2>/dev/null) | awk 'NR == 1 { print $1 }'
}

# What the run cost, in one place for both harnesses. Either way a missing
# or unreadable source leaves it unreported rather than wrong.
#
# claude says so itself: the result event carries the session total, and
# the formatter reads it out. pi does not say it anywhere in its output,
# but records the token cost of every message in its session file — so
# rescue that file first, before anything else touches the clone. It is
# worth keeping for its own sake, being the whole transcript.
#
# Not a plain cp -a: with --session-state, pi_run_session_dir is the durable
# cross-wake store, so it already holds every earlier wake's turns, and a
# straight copy would fold their cost, usage and last stopReason into this
# run's. pi_run_session_baseline_lines, snapshotted just before the run
# above, is empty for every file here without --session-state (a fresh
# per-run directory starts with nothing, so this is the same full copy cp -a
# was) and the pre-run line count of each transcript otherwise; take only
# what comes after it. Symlinks are skipped rather than followed, the same
# protection cp -a's own symlink-preserving behavior gave against anything
# the sandbox left behind redirecting this write.
run_cost=""
run_usage=""
run_error=""
if [[ -n "$pi_run_session_dir" && -d "$pi_run_session_dir" ]]; then
    mkdir -p "$run_dir/pi-session"
    while IFS= read -r -d '' pi_copy_file; do
        pi_copy_rel="${pi_copy_file#"$pi_run_session_dir"/}"
        pi_copy_dest="$run_dir/pi-session/$pi_copy_rel"
        mkdir -p "$(dirname "$pi_copy_dest")"
        pi_copy_base="${pi_run_session_baseline_lines[$pi_copy_file]:-0}"
        tail -n "+$(( pi_copy_base + 1 ))" "$pi_copy_file" > "$pi_copy_dest" 2>/dev/null
    done < <(find "$pi_run_session_dir" -name '*.jsonl' -type f -print0 2>/dev/null)

    # pi exits 0 even when its final turn ended in a provider error -- a
    # context-length 400, a refused request, a dropped endpoint -- because the
    # process itself ran fine; the failure was in the last response it read.
    # The run then reports "done, exit 0" having written nothing, which is the
    # one outcome a watcher cannot tell apart from success. Observed: a review
    # that spent 23 minutes reading, overflowed the window by a single token on
    # its final call, and was reported as a clean run.
    #
    # The session file is the only place that error is recorded, so take the
    # last turn's stopReason from it. The LAST one specifically: pi retries, and
    # an error it recovered from is not a failed run.
    pi_error="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -rs '[.. | objects | select(has("stopReason"))] | last // empty
                  | select(.stopReason == "error")
                  | .errorMessage // "the model reported an error"' \
             2>/dev/null || true)"
    if [[ -z "$pi_error" ]]; then
        # The retry-exhaustion backstop. pi also exits 0 when its
        # automatic retries run out, the stream then ending in
        # auto_retry_end success=false. The installed pi (0.84.3) does
        # not leave that uncaught: it appends the failed turn to the
        # session file before its retry bookkeeping, so the LAST turn
        # there has stopReason "error" and the check above fires for a
        # real exhaustion first -- the run fails as a model error and
        # this block never runs. It covers the exhaustion shape with no
        # error turn last in the session: a pi whose retry path leaves
        # the session clean, or the durable --session-state store, where
        # the check above reads the last turn across every wake's
        # transcript in find|cat order, which need not be the current
        # wake's final turn. It cannot report a success as failed: a
        # run that finished cleanly ends without a failing
        # auto_retry_end, and a run that committed work is excluded by
        # condition 2 below.
        #
        # Two conditions, in that order, short-circuiting:
        #   1. the LAST auto_retry_end in the run's own event stream is a
        #      failure. A success=true after a false is a recovered retry, and
        #      the last one is the one that stands -- the same LAST-is-truth
        #      rule the stopReason check applies to its own shape, so a
        #      session that exhausted retries on an earlier turn and then
        #      recovered reads as success.
        #   2. the branch holds no commits off base -- the review-loop
        #      gate's own read (clone_branch_head), reused rather than
        #      duplicated. This is what protects a run that exhausted
        #      retries mid-way and still committed work: it is a success.
        #      A head that cannot be read at all is treated as holding
        #      nothing: the branch is the run's one observable output, and a
        #      run whose retries ran out and whose work no one can see must
        #      not read as success.
        pi_retry_error="$(jq -rs \
            '[.[] | select(.type == "auto_retry_end")]
             | last // empty
             | select(.success == false)
             | .finalError // "the model reported an error"' \
            "$events" 2>/dev/null || true)"
        if [[ -n "$pi_retry_error" ]]; then
            retry_head="$(clone_branch_head)"
            if [[ -z "$retry_head" || "$retry_head" == "$base_sha" ]]; then
                run_error="pi exhausted its automatic retries and committed nothing: $pi_retry_error"
                printf 'fork-sandbox: pi exhausted its automatic retries and committed nothing: %s\n' \
                    "$pi_retry_error" >> "$sandbox_log"
                # rc=1 like the model-error branch below, with its same two
                # guards: never turn a non-zero exit into a different
                # non-zero one, and the same exit-code deferral -- with a
                # review loop, a maintainer loop, a pending refresh or repeat
                # passes still to come, the run is not over, and the leg that
                # is actually last writes the final exit code.
                if [[ "$rc" == "0" ]]; then
                    rc=1
                    if [[ "$refresh_enabled" == "0" && "${composed_pipeline:-0}" != 1 \
                        && "$run_step_count" == "1" && "${run_step_kind[1]}" == code \
                        && "${run_step_cap[1]}" == "1" ]]; then
                        printf '%s\n' "$rc" > "$run_dir/exit-code"
                    fi
                fi
            fi
        fi
    fi
    if [[ -n "$pi_error" ]]; then
        run_error="$pi_error"
        printf 'fork-sandbox: the session ended in a model error: %s\n' \
            "$pi_error" >> "$sandbox_log"
        # Never turn a non-zero exit into a different non-zero one: the
        # process's own code is the better diagnosis when it has one.
        if [[ "$rc" == "0" ]]; then
            rc=1
            # Same deferral as the write above: with a review loop, a
            # maintainer loop, a pending refresh or repeat passes still to
            # come, the run is not over, and exit-code must stay unwritten
            # (or, if the gate above already wrote the stale rc=0, stay
            # unwritten by this branch) until whichever of those legs is
            # actually last updates it with the final $rc.
            if [[ "$refresh_enabled" == "0" && "${composed_pipeline:-0}" != 1 \
                && "$run_step_count" == "1" && "${run_step_kind[1]}" == code \
                && "${run_step_cap[1]}" == "1" ]]; then
                printf '%s\n' "$rc" > "$run_dir/exit-code"
            fi
        fi
    fi

    # Round to millionths. Adding floats leaves noise a dollar figure
    # should not carry, and a cheap run costs well under a cent, so
    # rounding to cents would report every one of them as zero.
    run_cost="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -s '[.. | objects | select(has("usage")) | .usage.cost.total? // empty]
                 | add
                 | if . == null then empty else (. * 1000000 | round) / 1000000 end' \
             2>/dev/null)"
    # The same walk, for the counts behind that figure. pi names them
    # differently from claude; this is where they are made to agree.
    run_usage="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -s -c '[.. | objects | select(has("usage")) | .usage]
                    | if length == 0 then empty else
                        {
                          input_tokens: ([.[].input // empty] | add),
                          output_tokens: ([.[].output // empty] | add),
                          cache_read_tokens: ([.[].cacheRead // empty] | add),
                          cache_write_tokens: ([.[].cacheWrite // empty] | add),
                          reasoning_output_tokens: null,
                          total_tokens: ([.[].totalTokens // empty] | add),
                        }
                      end' 2>/dev/null)"
elif [[ "$usage_source" == "codex" && -s "$events" ]]; then
    # codex reports tokens in its turn.completed events and a price
    # nowhere, so cost stays null and the counts carry the run.
    #
    # Note what total_tokens must NOT be here. codex's
    # cached_input_tokens is part of input_tokens, not a figure beside
    # it — 9600 cached of 12217 input — so adding the two double-counts
    # the cache. claude reports its cache separately and does add up.
    # That is what usage_source is for: the shape is common, the
    # convention behind it is not.
    run_usage="$(jq -R -s -c '
        [ split("\n")[] | fromjson? // empty
          | select(.type == "turn.completed") | .usage // empty ]
        | if length == 0 then empty else
            {
              input_tokens: ([.[].input_tokens // empty] | add),
              output_tokens: ([.[].output_tokens // empty] | add),
              cache_read_tokens: ([.[].cached_input_tokens // empty] | add),
              cache_write_tokens: null,
              reasoning_output_tokens: ([.[].reasoning_output_tokens // empty] | add),
              total_tokens: (([.[].input_tokens // empty] | add)
                             + ([.[].output_tokens // empty] | add)),
            }
          end' "$events" 2>/dev/null)"
elif [[ -n "$formatter" && -s "$events" ]]; then
    run_cost="$("$formatter" --cost "$events" 2>/dev/null)"
    run_usage="$("$formatter" --usage "$events" 2>/dev/null)"
fi
# A reader should not have to tell "no tokens" from "tokens not reported".
[[ -n "$run_usage" ]] || run_usage=null

# codex and claude record a failure only in their own event stream (pi's is
# read from its session file above, so a pi error is already in run_error).
# Read it here so a leg that died in seconds on a provider error says why,
# rather than the summary saying only that the session wrote no result.
if [[ -z "$run_error" ]]; then
    run_error="$(fs_harness_error "$harness" "$events")"
fi
if [[ "$rc" != "0" ]]; then
    run_error+="$(fs_leg_retry_suffix "${impl_leg_retries_count:-0}")"
fi

# run_cost above reads only the final attempt (the file left at $events);
# a retried implement leg's earlier, archived attempts join it here, the
# same way a retried review/fix/maintainer leg's archived cost joins its
# own leg_cost below -- so a leg that burned a retry is not billed as if
# it had not.
if [[ ! "$run_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    run_cost=""
fi
# A sum is only honest when every part is a number: an unpriced final
# attempt, or an unpriced archived attempt (impl_leg_retry_cost_unknown),
# makes the whole implement-leg cost unknown rather than just the retry's
# own share of it.
if [[ "${impl_leg_retry_cost_unknown:-0}" == 1 ]]; then
    run_cost=""
elif [[ -n "$run_cost" && -n "${impl_leg_retry_extra_cost:-}" ]]; then
    run_cost="$(jq -n --argjson a "$run_cost" --argjson b "$impl_leg_retry_extra_cost" \
        '$a + $b' 2>/dev/null)"
fi

# Format once, here, and record it where a caller can read it without
# parsing prose. %.6f rather than the raw number: a sum of floats carries
# noise, and a cheap run is small enough that jq hands back scientific
# notation, which is no way to write a price. Millionths, because a run
# can honestly cost less than a cent. run.env is the run's machine-readable
# record and fork-sandbox-status.sh already reads it key by key, so the
# value goes there as well as into the summary. Check it is a number
# first: this block writes into the summary with stderr folded in, so a
# printf that rejects its argument would land its complaint in the report.
run_cost_fmt=""
if [[ "$run_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    run_cost_fmt="$(printf '%.6f' "$run_cost")"
    # Replace the line rather than append one. This script can be re-run by
    # hand, which is why everything else it writes is truncated first, and
    # a reader takes the FIRST match for a key — so a second cost= line
    # would hide the new figure behind the old one. Build the replacement
    # beside the file and rename, which is atomic, so a reader watching the
    # run sees one version or the other and never a half-written record.
    # Rewrite nothing if the record cannot be read: an empty run.env would
    # lose the whole run rather than one line.
    if [[ -s "$run_dir/run.env" ]] \
        && grep -v '^cost=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
        printf 'cost=%s\n' "$run_cost_fmt" >> "$run_dir/run.env.part"
        mv -f "$run_dir/run.env.part" "$run_dir/run.env"
    else
        rm -f "$run_dir/run.env.part"
    fi
fi
# The run.env written at start carries model= empty for a run whose model the
# endpoint discovered. Refresh that one line the same way: replace rather
# than append, because a reader takes the first match, and build the
# replacement beside the file and rename, which is atomic.
if [[ -n "$model" ]] \
    && [[ -s "$run_dir/run.env" ]] \
    && grep -v '^model=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'model=%s\n' "$record_model" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi

# Shared with the walker below: the running total of every extra session
# this run pays for beyond the implement leg, and whether that total is
# still honest. A continuation leg's cost lands here first; a review or
# maintainer step's leg cost lands here too, once the walker runs -- one
# accumulator, so total_cost_usd at the very end is never short a leg.
loop_cost_sum=0
loop_cost_unknown=0
# The implement leg's own retried attempts do NOT join this accumulator:
# their cost is already folded into run_cost above, and total_cost_usd
# below adds run_cost_fmt and loop_cost_sum together, so counting them
# here too would bill the run twice for the same retry.

# ---------------------------------------------------------------- refresh --
# --refresh-at: when a coding leg's own context crossed the threshold,
# fork-sandbox-inbox-hook.sh nudged it, once, to write a hand-off to
# $outbox_dir/handoff.md and end its turn. If it did, this loop moves that
# file to $run_dir/handoff-N.md (the record) and runs continuation N: a
# fresh session, same clone, same branch, with that hand-off as its whole
# prompt. It keeps going -- checking the outbox again, running another
# continuation -- until a leg ends with nothing waiting there, which is the
# ordinary way this ends.
#
# $rc is OVERWRITTEN by each continuation's own exit code, deliberately: the
# walker below (and the final exit code) must judge the run by its LAST
# coding leg, not its first. It sits here, after the implement leg's own
# run_cost/run_usage accounting above, so that accounting keeps meaning the
# implement leg alone -- exactly as it did before this feature existed --
# while every continuation's cost instead joins loop_cost_sum, the same
# accumulator the walker below adds its own legs to.
refresh_ended=""
continuations_json='[]'
refresh_leg_n=0
# Every OTHER leg's own refresh chain -- a code step's pass 2+, a code step
# that is not step 1, a fix or mntfix leg -- lands here instead of in
# refresh_ended/continuations_json above, which stay the step-1 implement
# leg's own fields exactly as they always have (decision 6: existing field
# meanings do not change). See fs_refresh_chain, below run_leg.
leg_refreshes_json='[]'
# The events slice to check for a nudge marker once no hand-off is waiting:
# starts as the implement leg's own events.jsonl (nothing else has been
# appended to it yet at this point), and becomes each continuation's own
# events-continuation-N.jsonl in turn.
refresh_last_events="$events"
# The branch head as of just before the most recently run continuation (or
# the implement leg, for the first iteration): captured right before that
# leg's own fs_run_lock_closed call, below. Compared against the current
# head at the top of the next iteration to detect a stall -- see
# fs_refresh_is_stall (fork-sandbox-refresh.sh). refresh_leg_outbox_before is
# the outbox signature (fs_refresh_outbox_sig) captured at the same point.
refresh_leg_head_before=""
refresh_leg_outbox_before=""

# Continuation legs share fork-sandbox-inbox-hook.sh's own tag rather than
# invent a second one: that hook already writes it to stderr, which
# --include-hook-events folds into this leg's own event stream as a
# hook_response event, so it is right there in whichever file this leg wrote.
refresh_leg_was_nudged() {
    fs_refresh_leg_was_nudged "$1"
}

# $1 continuation number (1 for the first continuation -- the same count
# named in handoff-N.md, continuation-prompt-N.md and README/SKILL.md, NOT
# the leg number the console log and --monitor use, which counts the
# implement leg as 1). $2 the hand-off file, already moved to its $run_dir
# record. $3 the destination path. $4 (optional, default 0) whether the host-
# side backstop found this hand-off older than the clone's last commit -- see
# its check above. The static preamble, then the original brief
# ($handoff_original, snapshotted once at launch -- see above), any operator
# addenda archived from earlier legs of this run, a warning block when $4 is
# set, and finally the previous leg's own hand-off -- there is no
# verdict-style body to append here, unlike the fix leg's prompt.
refresh_build_prompt() {
    fs_refresh_build_prompt "$1" "$2" "$3" "${4:-0}" "$continuation_prompt_header" \
        "$handoff_original" "$run_dir" "$plan_file"
}

if [[ "$refresh_enabled" == "1" && "$fs_impl_leg_ran_at_step1" == 1 ]]; then
    fs_refresh_window_mismatch "$events" "$refresh_context_window" \
        | tee -a "$sandbox_log"
    while :; do
        if [[ "${stop_requested:-0}" == 1 ]]; then
            refresh_ended="stop-requested"
            break
        fi
        if [[ -f "$outbox_dir/handoff.md" ]]; then
            # A stall: the leg that just ran (numbered refresh_leg_n + 1 in
            # the same "handoff-N.md is leg N's own" scheme as everywhere
            # else here) left a hand-off without moving the branch or writing
            # to its outbox. Checked
            # before the cap below, so a stalled chain that also happens to
            # be at the cap reports "stalled", the more specific diagnosis.
            if fs_refresh_is_stall "$(( refresh_leg_n + 1 ))" \
                "$refresh_leg_head_before" "$(clone_branch_head)" \
                "$refresh_leg_outbox_before" "$(fs_refresh_outbox_sig "$outbox_dir")"; then
                refresh_ended="stalled"
                mv -f -- "$outbox_dir/handoff.md" \
                    "$run_dir/handoff-stalled-$(( refresh_leg_n + 1 )).md" 2>/dev/null
                printf 'fork-sandbox: continuation leg %s stalled (hand-off waiting, branch head and outbox unchanged); ending the refresh chain\n' \
                    "$(( refresh_leg_n + 1 ))" | tee -a "$sandbox_log"
                break
            fi
            if (( refresh_leg_n >= refresh_max )); then
                refresh_ended="cap"
                break
            fi
            # fs_refresh_take_handoff refuses a symlink, an oversized or an
            # empty hand-off (logging why) and otherwise moves it to its
            # $run_dir record, checked to be a plain file.
            refresh_next_n=$(( refresh_leg_n + 1 ))
            if ! fs_refresh_take_handoff "$outbox_dir" "$run_dir" \
                "$refresh_next_n" "$sandbox_log" > /dev/null; then
                refresh_ended="no-handoff"
                break
            fi
            refresh_leg_n="$refresh_next_n"
            leg_no=$(( refresh_leg_n + 1 ))
            record_name="handoff-$refresh_leg_n.md"
            progress_continuation[1]="$refresh_leg_n"

            # Bug B's host-side backstop: the sandbox-side Stop check cannot
            # help a leg that died (quota, crash, timeout) right after
            # writing an early hand-off. mv above preserves mtime, so this
            # compares the RECORD, not the outbox path it came from. This
            # reads an mtime only -- it does NOT run git in the clone, which
            # stays forbidden on the host (see the review-loop commit count
            # below, "nothing may run git in the clone to count them there").
            handoff_stale=0
            if fs_refresh_handoff_stale "$clone_dir" "$run_dir/$record_name"; then
                handoff_stale=1
                printf "fork-sandbox: %s predates the clone's last commit; continuation leg %s is warned\n" \
                    "$record_name" "$leg_no" | tee -a "$sandbox_log"
            fi

            cont_prompt="$run_dir/continuation-prompt-$refresh_leg_n.md"
            refresh_build_prompt "$refresh_leg_n" "$run_dir/$record_name" "$cont_prompt" "$handoff_stale"

            # A synthetic marker event, so --monitor and --follow notice a
            # continuation starting without waiting for that leg's own first
            # event -- see fork-sandbox-format.sh's rendering of it.
            jq -c -n --argjson leg "$leg_no" --arg handoff "$record_name" \
                '{type: "system", subtype: "fork_sandbox_continuation", leg: $leg, handoff: $handoff}' \
                >> "$events" 2>/dev/null
            printf '\n== fork-sandbox: continuation leg %s (from %s) ==\n' "$leg_no" "$record_name"

            cont_events="$run_dir/events-continuation-$refresh_leg_n.jsonl"
            : > "$cont_events"
            # Both files: events.jsonl so --result, --follow and --monitor
            # keep showing the whole coding phase as it happens (JQ_RESULT's
            # "last result wins" is exactly "the LAST coding leg's result"),
            # and this leg's own file so its cost and usage can be read in
            # isolation below, the same way a review-loop leg's can.
            # cont_sandbox_cmd, not sandbox_cmd: identical but for the
            # transcript-store flags, where a continuation leg writes into
            # the store and never resumes out of it -- see where the array
            # is built, in the launcher above.
            # Recorded just before this leg runs, for the stall check at the
            # top of the next iteration (fs_refresh_is_stall above).
            refresh_leg_head_before="$(clone_branch_head)"
            refresh_leg_outbox_before="$(fs_refresh_outbox_sig "$outbox_dir")"
            _fs_cont_attempt() {
                if [[ -n "$formatter" ]]; then
                    fs_run_lock_closed "${cont_sandbox_cmd[@]}" < "$cont_prompt" \
                        2> >(tee -a "$sandbox_log" >&2) \
                        | tee -a "$events" -a "$cont_events" \
                        | "$formatter"
                else
                    fs_run_lock_closed "${cont_sandbox_cmd[@]}" < "$cont_prompt" \
                        2> >(tee -a "$sandbox_log" >&2) \
                        | tee -a "$events" -a "$cont_events"
                fi
                _fs_leg_attempt_rc="${PIPESTATUS[0]:-1}"
            }
            # events.jsonl (the run's own cumulative log, appended by every
            # attempt in turn) is never archived or truncated here -- only
            # cont_events, this continuation's own isolated file, is what the
            # retry driver moves aside between attempts and what its cost
            # accounting below reads.
            fs_run_claude_leg_with_retry "$harness" "$cont_events" "$sandbox_log" \
                "continuation leg $leg_no" _fs_cont_attempt "$formatter"
            rc="$fs_retry_rc"
            total_leg_retries=$(( total_leg_retries + fs_retry_count ))
            fs_archive_inbox "$leg_no" "$harness" "$rc"
            # A continuation is the same conversation as step 1's pass 1,
            # not a new pass -- see progress_i[1]'s own comment where pass 1
            # begins, above -- so this is a leg-end transition only: the
            # step stays running and i stays at 1 until the chain ends.
            progress_write running
            refresh_last_events="$cont_events"
            fs_refresh_window_mismatch "$cont_events" "$refresh_context_window" \
                | tee -a "$sandbox_log"

            cont_cost="$("$formatter" --cost "$cont_events" 2>/dev/null)"
            cont_usage="$("$formatter" --usage "$cont_events" 2>/dev/null)"
            [[ -n "$cont_usage" ]] || cont_usage=null
            # Retries: keep leg_usage-style, this leg's usage stays the final
            # attempt's own (cont_usage above already reads only cont_events,
            # the final attempt), but cont_cost is summed across every
            # attempt this leg made -- and only when every one of them
            # priced (fs_retry_cost_unknown flags an archived attempt that
            # did not); a sum is only honest when every part is a number.
            if [[ "$fs_retry_cost_unknown" == 1 ]]; then
                cont_cost=""
            elif [[ -n "$fs_retry_extra_cost" ]]; then
                if [[ "$cont_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                    cont_cost="$(jq -n --argjson a "$cont_cost" --argjson b "$fs_retry_extra_cost" \
                        '$a + $b' 2>/dev/null)"
                else
                    cont_cost=""
                fi
            fi
            if [[ "$cont_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                summed="$(jq -n --argjson a "$loop_cost_sum" --argjson b "$cont_cost" \
                    '$a + $b' 2>/dev/null)"
                if [[ -n "$summed" ]]; then
                    loop_cost_sum="$summed"
                else
                    loop_cost_unknown=1
                fi
            else
                cont_cost=null
                loop_cost_unknown=1
            fi

            handoff_stale_json=false
            (( handoff_stale )) && handoff_stale_json=true
            merged="$(jq -c -n \
                --argjson prev "$continuations_json" \
                --argjson leg "$leg_no" \
                --argjson exit "$rc" \
                --argjson cost "$cont_cost" \
                --argjson usage "$cont_usage" \
                --arg handoff "$record_name" \
                --argjson handoff_stale "$handoff_stale_json" \
                --argjson retries "$fs_retry_records" \
                '$prev + [{leg: $leg, exit: $exit, cost_usd: $cost, usage: $usage, handoff: $handoff, handoff_stale: $handoff_stale, retries: $retries}]' \
                2>/dev/null)"
            [[ -n "$merged" ]] && continuations_json="$merged"

            if [[ "$rc" != "0" ]]; then
                # A crashed leg is not the ordinary ending: it gets its own
                # terminal value rather than being folded into empty-outbox,
                # which readers (including `stats --by refresh`) treat as
                # success. A hand-off the leg managed to write just before
                # dying is worth keeping as part of the record even though
                # this run is not going to act on it.
                if [[ -f "$outbox_dir/handoff.md" && ! -L "$outbox_dir/handoff.md" ]]; then
                    mv -f -- "$outbox_dir/handoff.md" \
                        "$run_dir/handoff-leg-$leg_no-after-error.md" 2>/dev/null
                fi
                refresh_ended="leg-error"
                break
            fi
            continue
        fi

        # No hand-off is waiting. The leg that just finished -- the implement
        # leg, the first time through -- is the run's last coding leg, unless
        # it was nudged and still left nothing there, which is worth telling
        # apart from a run that simply never needed to refresh at all.
        if refresh_leg_was_nudged "$refresh_last_events"; then
            refresh_ended="no-handoff"
        else
            refresh_ended="empty-outbox"
        fi
        break
    done
fi
[[ -n "$refresh_ended" ]] || refresh_ended="none"
if [[ "$refresh_enabled" == "1" ]]; then
    printf 'fork-sandbox: refresh ended: %s (%s continuation leg(s) ran)\n' \
        "$refresh_ended" "$refresh_leg_n"
    # sandbox_cmd (and review_sandbox_cmd, derived from it below) still has
    # the outbox bind and the hook settings baked in, but the review and fix
    # legs that reuse it have no loop watching the outbox any more -- this
    # loop just broke out of the only code that does. Remove the config the
    # hook gates the whole nudge mechanism on so those legs' sandboxes see an
    # inbox with no .refresh-config and never get told to hand off to nobody.
    if [[ -n "$refresh_config" ]]; then
        rm -f -- "$refresh_config" 2>/dev/null
    fi
fi

# ----------------------------------------------------------------- walker --
# run_leg (below) and the cur_* walker further down are the one driver for
# every run's review/maintain/fix legs, legacy-translated or composed alike
# (see the run_step_* compile point and the walker's own header comment).
# For a legacy run -- --review-loop N and/or --maintainer-loop N -- this
# plays out exactly as before: review (or maintain) the commits the coding
# leg just made in a FRESH session of the same harness and (when supplied)
# --review-model/--maintainer-model, and when that review reports problems,
# hand them to a fresh session that fixes them. Repeat until the review
# approves, until a fix leg stops making progress, or until N iterations have
# run. A composed preset's own review/maintain/fix steps walk the same code
# path with their own per-step seats (see the compile point above).
#
# It sits here on purpose: everything above is the implement leg's accounting
# and, when --refresh-at ran any continuations, the refresh loop's -- including
# the pi stopReason and retry-exhaustion checks, the only failure detection a
# pi run has. A coding leg that died of a model error must never be reviewed as if it had
# worked, so the loop runs downstream of the checks that catch it, and $rc by
# now names the LAST coding leg's exit, not necessarily the implement leg's.
#
# The legs reuse this run's sandbox command, so they get the same harness, the
# same clone and the same binds. Review legs may override the model; fix legs
# retain the implementation model. They differ in the prompt on stdin and in
# where their output goes: each leg has its own events file and never touches
# events.jsonl, so it keeps showing the coding phase -- implement leg plus any
# continuations -- and --result keeps showing the work rather than the review
# of it. loop_cost_sum and loop_cost_unknown are shared with the refresh loop
# above, so this section only ADDS to them.
#
# Review and fix legs continue the same leg count the refresh loop above left
# off at, for fs_archive_inbox: leg_no is the implement leg's own number (1)
# when no continuation ran, or the last continuation's number otherwise.
next_leg_no=$(( ${leg_no:-1} + 1 ))
leg_cost=""
leg_usage=null
leg_error=""
leg_harness_error=""
# The summary block's review line gates on this being non-empty, unguarded
# (the maintainer line's sibling carries its own ${...:-} default instead,
# since a no-maintainer run.sh never emits maintainer_loop_ended at all) --
# so this default must exist for every run shape, composed and legacy alike,
# not just the ones that end up assigning it a real value.
review_loop_ended=""
review_loop_detail=""

# Run one leg: kind (review or fix), iteration number, prompt file. Sets
# leg_rc, leg_cost (a number, or empty when the harness does not report one),
# leg_usage (a JSON object, or null), leg_error (a model-error or
# retry-exhaustion message, or empty) and leg_harness_error (the provider's
# error from a codex or claude leg's own event stream, or empty; see
# fs_harness_error).
run_leg() {
    local kind="$1" n="$2" prompt="$3" step_idx="${4:-}"
    # A legacy-shaped run never passes step_idx, so leg_tag is exactly
    # today's "$kind-$n"; a composed run's own step-indexed tag (decision 4)
    # unifies "fix" and "mntfix" onto one "-fix-" segment, since a composed
    # pipeline never distinguishes which tier's fix seat this is the way the
    # fixed fxr_*/fxm_* split does -- the step index already says which step.
    # This same tag also disambiguates the pi-session directory names below:
    # two composed steps of the same kind (e.g. two review steps) would
    # otherwise both claim "pi-session-review-1" for their own iteration 1
    # and share a session the cost walk would double-bill, exactly the
    # collision the surrounding comment there already warns about for the
    # fixed tiers.
    # leg_tag is deliberately NOT local: fs_refresh_chain, called by the
    # caller right after run_leg returns for a "code"/"fix"/"mntfix" leg,
    # reads it back to name that leg's OWN refresh chain's artifacts, the
    # same "public output" convention leg_rc/leg_cost/leg_usage already use.
    leg_tag=""
    if [[ -n "$step_idx" ]]; then
        case "$kind" in
        fix | mntfix) leg_tag="${step_idx}-fix-$n" ;;
        # run_leg's own kind vocabulary says "maintainer" (the accounting
        # semantics decision 3 keeps); decision 4's composed artifact names
        # spell the parser's action word instead ("maintain"), matching the
        # status-allowlist globs written against that spelling.
        maintainer) leg_tag="${step_idx}-maintain-$n" ;;
        *) leg_tag="${step_idx}-$kind-$n" ;;
        esac
    else
        leg_tag="$kind-$n"
    fi
    legs_run=$(( ${legs_run:-0} + 1 ))
    # Also not local, for the same reason as leg_tag: fs_refresh_chain checks
    # THIS leg's own events for a nudge marker before it decides there is no
    # hand-off to chase.
    leg_events="$run_dir/events-$leg_tag.jsonl"
    # A review-only run has no implement leg, so its first leg's events are
    # the run's own; a read-only maintain leg after it keeps its own file. A
    # composed read-only step (it has a step_idx) always keeps its own file.
    if [[ "$mode" == "review-only" && -z "$step_idx" && "${ro_events_claimed:-0}" != 1 ]]; then
        leg_events="$run_dir/events.jsonl"
        ro_events_claimed=1
    fi
    local leg_session="" leg_session_copy="" idx
    local leg_retry_error="" leg_head_before="" leg_head_after="" leg_failed_retry=""
    local -a cmd=("${sandbox_cmd[@]}")
    # A review leg's own harness (--review-harness, when given -- the
    # "rev_*" values, which fall back to the implement ones otherwise, see
    # where they are set above) decides its accounting, not the implement
    # harness's: a different harness means a different session-dir marker
    # to substitute, a different usage reader, and a different formatter
    # for its own output stream. A fix leg stays on the implement harness
    # throughout, by the existing rule that --review-model never changed.
    local leg_pi_session_dir="$pi_session_dir"
    local leg_usage_source="$usage_source"
    # leg_formatter is not local -- same "public output" reason as leg_tag
    # above: fs_refresh_chain reuses THIS leg's own formatter for every
    # continuation in its chain.
    leg_formatter="$formatter"
    # The harness THIS leg actually runs on -- $review_preamble_harness for a
    # review leg (set above beside the review preamble: $review_harness when
    # --review-harness was given, $harness otherwise), $harness for a fix
    # leg, which never overrides it. fs_archive_inbox's Stop-contract
    # invariant only holds for whichever harness this is, not for the
    # implement harness unconditionally. Not local, for the same reason:
    # fs_refresh_chain gates a leg's whole chain on this being "claude".
    leg_harness="$harness"
    if [[ "$kind" == "tidy" ]]; then
        # The tidy leg runs on the maintain SEAT's accounting (pi session
        # dir, usage source, formatter, harness) but its own command: the
        # editing-settings swap of that seat's own sandbox_cmd (built
        # beside it at launch, see tidy_sandbox_cmd/s<K>tidy_sandbox_cmd),
        # never the seat's fix command. A composed step's maintain fields
        # are its own "s<K>_*" (not "s<K>fix_*" -- there is no fix-seat
        # accounting to borrow here); the legacy fields are "mnt_*", the
        # same ones the "maintainer" arm below reads.
        if [[ -n "$step_idx" ]]; then
            local -n leg_cmd_ref="${step_idx}tidy_sandbox_cmd"
            cmd=("${leg_cmd_ref[@]}")
            local step_field
            step_field="${step_idx}_pi_session_dir"
            leg_pi_session_dir="${!step_field}"
            step_field="${step_idx}_usage_source"
            leg_usage_source="${!step_field}"
            step_field="${step_idx}_formatter"
            leg_formatter="${!step_field}"
            step_field="${step_idx}_harness"
            leg_harness="${!step_field}"
        else
            cmd=("${tidy_sandbox_cmd[@]}")
            leg_pi_session_dir="$mnt_pi_session_dir"
            leg_usage_source="$mnt_usage_source"
            leg_formatter="$mnt_formatter"
            leg_harness="$maintainer_preamble_harness"
        fi
    elif [[ -n "$step_idx" ]]; then
        # A composed step's own seat: resolved by the seat-resolution loop
        # into "s<K>_*"/"s<K>fix_*" and serialized into this same run.sh's
        # text by the loops beside the fixed rev_*/mnt_*/fxr_*/fxm_*
        # emission above (see their own comments). No separate "preamble"
        # fallback is needed the way review/maintainer's is: a composed
        # step's harness always comes straight from the parser, never a
        # --review-harness-style fallback.
        local step_prefix="$step_idx"
        [[ "$kind" == "fix" || "$kind" == "mntfix" ]] && step_prefix="${step_idx}fix"
        local -n leg_cmd_ref="${step_prefix}_sandbox_cmd"
        cmd=("${leg_cmd_ref[@]}")
        local step_field
        step_field="${step_prefix}_pi_session_dir"
        leg_pi_session_dir="${!step_field}"
        step_field="${step_prefix}_usage_source"
        leg_usage_source="${!step_field}"
        step_field="${step_prefix}_formatter"
        leg_formatter="${!step_field}"
        step_field="${step_prefix}_harness"
        leg_harness="${!step_field}"
    elif [[ "$kind" == "review" ]]; then
        cmd=("${review_sandbox_cmd[@]}")
        leg_pi_session_dir="$rev_pi_session_dir"
        leg_usage_source="$rev_usage_source"
        leg_formatter="$rev_formatter"
        leg_harness="$review_preamble_harness"
    elif [[ "$kind" == "maintainer" ]]; then
        # Only ever reached when --maintainer-loop is on, which is what made
        # the launcher emit maintainer_sandbox_cmd and the "mnt_*" state.
        cmd=("${maintainer_sandbox_cmd[@]}")
        leg_pi_session_dir="$mnt_pi_session_dir"
        leg_usage_source="$mnt_usage_source"
        leg_formatter="$mnt_formatter"
        leg_harness="$maintainer_preamble_harness"
    elif [[ "$kind" == "fix" && -n "${fix_harness:-}" ]]; then
        # A preset seated its own review-tier fix agent; the launcher
        # emitted its command and "fxr_*" state. Without one this branch is
        # never taken and fix falls through to the implement defaults.
        cmd=("${fix_sandbox_cmd[@]}")
        leg_pi_session_dir="${fxr_pi_session_dir:-}"
        leg_usage_source="${fxr_usage_source:-}"
        leg_formatter="${fxr_formatter:-}"
        leg_harness="$fix_harness"
    elif [[ "$kind" == "mntfix" && -n "${mntfix_harness:-}" ]]; then
        cmd=("${mntfix_sandbox_cmd[@]}")
        leg_pi_session_dir="${fxm_pi_session_dir:-}"
        leg_usage_source="${fxm_usage_source:-}"
        leg_formatter="${fxm_formatter:-}"
        leg_harness="$mntfix_harness"
    fi
    # The tidy leg's own wall-clock limit: nothing else watches this leg the
    # way the review/maintainer loops watch theirs, so a leg that hangs
    # would otherwise hold an already-approved branch back indefinitely.
    # GNU timeout's own 124 exit is read below (see tidy_detail's own
    # "timed out" branch), distinct from whatever this harness's own exit
    # codes mean, since this wrap is the only thing that can ever produce
    # it for this leg. --kill-after backs the TERM with a SIGKILL: a
    # harness that traps or ignores TERM would otherwise hang past
    # $tidy_timeout_secs with timeout itself just waiting on it, which
    # defeats the whole bound this wrap exists to enforce. No --foreground:
    # timeout's own new process group is what lets ITS OWN TERM/KILL reach
    # every descendant a sandboxed backend forks, not just its direct
    # child -- a backend that waits on a foreground grandchild under its
    # own EXIT trap (every bundled backend does) would otherwise defer
    # that signal until the grandchild returns on its own, which can be
    # indefinitely. fork-sandbox-stop.sh does not rely on this leg sharing
    # the runner's own process group either; see its own comment on
    # signaling every process group among the run's descendants.
    if [[ "$kind" == "tidy" ]]; then
        cmd=("$FS_TIMEOUT" "--kill-after=60" "$tidy_timeout_secs" "${cmd[@]}")
    fi
    # "fix" and "mntfix" without a preset fix seat, and "code" (a repeat
    # pass of the coding leg), all fall through to the implement defaults
    # above: those legs run the implement harness and model. Note what they
    # do NOT inherit: sandbox_cmd carries no --session-state, so none of
    # them writes into the transcript store. That is deliberate -- each is
    # its own conversation with its own prompt, and the store's newest
    # transcript is what summary.json offers the next wake to resume (see
    # impl_sandbox_cmd/cont_sandbox_cmd in the launcher).
    leg_rc=1
    leg_cost=""
    leg_usage=""
    leg_error=""
    leg_harness_error=""
    leg_retries_count=0
    leg_retries_json='[]'
    : > "$leg_events"

    # pi records its transcript, and the tokens with it, in a session
    # directory. Two legs must not share one, or the cost walk below bills
    # each leg for every leg before it. The sandbox command is exact
    # strings, so give this leg its own by substituting the one element
    # that is this leg's harness's session dir -- the review harness's
    # marker for a review leg, the implement harness's for anything else,
    # so a review leg under an independent harness is not searched for a
    # marker that was never in its own command in the first place, which
    # would silently leave it sharing the implement leg's session
    # directory and billing every leg for every leg before it.
    if [[ -n "$leg_pi_session_dir" ]]; then
        leg_session="$clone_dir/.git/pi-session-$leg_tag"
        for idx in "${!cmd[@]}"; do
            if [[ "${cmd[$idx]}" == "$leg_pi_session_dir" ]]; then
                cmd[$idx]="$leg_session"
            fi
        done
    fi
    # The fully-resolved argv this leg actually runs, in a global (not
    # local) array: fs_refresh_chain reuses it unchanged for every
    # continuation in this leg's own chain -- a "code"/"fix"/"mntfix" leg
    # never carries --session-state (see the comment below on what these
    # legs do NOT inherit), so a continuation is just another fresh,
    # never-resumed run of this same argv against a different prompt file,
    # with no "cont_sandbox_cmd" distinction to make the way the top-level
    # implement leg needs one.
    leg_seat_cmd=("${cmd[@]}")

    # The branch head as of just before the leg, for the retry-exhaustion
    # check in this leg's accounting: for a code, fix or mntfix leg, "the leg
    # committed nothing" is the head not moving from where it stood just
    # before this leg ran (a review or maintainer leg is never checked -- see
    # that check). A repeat code pass sits on top of an earlier pass's
    # commits exactly as a fix leg sits on top of the coding leg's, so it is
    # measured the same way, against its own pre-leg head rather than the
    # run's base -- run_leg's "code" kind is only ever called for pass 2+ of
    # the repeat loop (pass 1 is the top-level implement leg, accounted for
    # separately, outside run_leg), so this pre-leg head is always the
    # previous pass's head, and a pass that starts already ahead of base is
    # measured correctly instead of against base directly. It is read
    # before the leg runs, and the one way anything here may read the head
    # (clone_branch_head).
    if [[ "$kind" == "code" || "$kind" == "fix" || "$kind" == "mntfix" ]]; then
        leg_head_before="$(clone_branch_head)"
    fi

    printf '\n== fork-sandbox: %s leg, iteration %s ==\n' "$kind" "$n"
    # The prompt is a FILE on stdin, never an argument -- see the implement
    # leg's redirect for why (MAX_ARG_STRLEN), and note that the fix prompt
    # carries verdict text of no fixed size.
    _fs_leg_attempt() {
        # The tidy leg runs under GNU timeout in its own process group (see
        # the leg's own wrap above); fs_run_tidy_leg records that group
        # (pid and start time, in "$run_dir/tidy.pgid") from inside the
        # subshell that becomes it, before the exec that starts it, so
        # fork-sandbox-stop.sh can verify and signal it even once this
        # runner is gone. Removed once this attempt returns, so a retry's
        # fresh timeout wrap is never confused with the one before it, and
        # stop never finds a leg that already ended.
        local -a _fs_run=(fs_run_lock_closed)
        if [[ "$kind" == "tidy" ]]; then
            rm -f -- "$run_dir/tidy.pgid" 2>/dev/null
            _fs_run=(fs_run_tidy_leg "$run_dir/tidy.pgid")
        fi
        if [[ -n "$leg_formatter" ]]; then
            "${_fs_run[@]}" "${cmd[@]}" < "$prompt" \
                2> >(tee -a "$sandbox_log" >&2) \
                | tee -a "$leg_events" \
                | "$leg_formatter"
        else
            "${_fs_run[@]}" "${cmd[@]}" < "$prompt" \
                2> >(tee -a "$sandbox_log" >&2) \
                | tee -a "$leg_events"
        fi
        _fs_leg_attempt_rc="${PIPESTATUS[0]:-1}"
        [[ "$kind" == "tidy" ]] && rm -f -- "$run_dir/tidy.pgid" 2>/dev/null
    }
    fs_run_claude_leg_with_retry "$leg_harness" "$leg_events" "$sandbox_log" \
        "the $kind leg of iteration $n" _fs_leg_attempt "$leg_formatter"
    leg_rc="$fs_retry_rc"
    leg_retries_count="$fs_retry_count"
    leg_retries_json="$fs_retry_records"
    total_leg_retries=$(( total_leg_retries + leg_retries_count ))
    fs_archive_inbox "$next_leg_no" "$leg_harness" "$leg_rc"
    next_leg_no=$(( next_leg_no + 1 ))

    # The same three readers the implement leg's accounting uses, applied per
    # leg, plus the same two failure checks (stopReason and retry
    # exhaustion). Deliberately a copy of those walks rather than a refactor
    # of them: they are not worth disturbing to save thirty lines here.
    if [[ -n "$leg_session" && -d "$leg_session" ]]; then
        leg_session_copy="$run_dir/pi-session-$leg_tag"
        # Take any earlier copy out first: cp -a onto an existing directory
        # nests one inside it, and the cost walk below would then sum both.
        # A runner re-run by hand in the same run dir is the case that does it.
        rm -rf "$leg_session_copy"
        cp -a "$leg_session" "$leg_session_copy" 2>/dev/null
        # pi exits 0 when its final turn ended in a provider error, so the
        # session file is the only place that failure is recorded. Take the
        # LAST turn's stopReason: an error pi retried past is not a failed leg.
        leg_error="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -rs '[.. | objects | select(has("stopReason"))] | last // empty
                      | select(.stopReason == "error")
                      | .errorMessage // "the model reported an error"' \
                 2>/dev/null || true)"
        # The same exhaustion backstop the implement leg's accounting
        # checks (see pi_retry_error there): the LAST auto_retry_end in
        # this leg's own stream is a failure; a later success=true is a
        # recovered retry and stands instead, the same LAST-is-truth
        # rule. As there, it is gated on leg_error being empty: the
        # installed pi leaves the failed turn as the session's last, so
        # a real exhausted leg is already caught by the stopReason
        # check above, and this engages only for an exhausted stream
        # whose session ends clean. The committed-nothing half of the
        # test needs the head read after the leg ran, so it comes at the
        # end of the accounting, beside the stopReason result.
        leg_retry_error="$(jq -rs \
            '[.[] | select(.type == "auto_retry_end")]
             | last // empty
             | select(.success == false)
             | .finalError // "the model reported an error"' \
            "$leg_events" 2>/dev/null || true)"
        leg_cost="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -s '[.. | objects | select(has("usage")) | .usage.cost.total? // empty]
                     | add
                     | if . == null then empty else (. * 1000000 | round) / 1000000 end' \
                 2>/dev/null)"
        leg_usage="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -s -c '[.. | objects | select(has("usage")) | .usage]
                        | if length == 0 then empty else
                            {
                              input_tokens: ([.[].input // empty] | add),
                              output_tokens: ([.[].output // empty] | add),
                              cache_read_tokens: ([.[].cacheRead // empty] | add),
                              cache_write_tokens: ([.[].cacheWrite // empty] | add),
                              reasoning_output_tokens: null,
                              total_tokens: ([.[].totalTokens // empty] | add),
                            }
                          end' 2>/dev/null)"
    elif [[ "$leg_usage_source" == "codex" && -s "$leg_events" ]]; then
        # codex reports tokens and no price, so a codex leg has counts and a
        # null cost. cached_input_tokens is part of input_tokens here, which
        # is why total_tokens is not a sum of all three.
        leg_usage="$(jq -R -s -c '
            [ split("\n")[] | fromjson? // empty
              | select(.type == "turn.completed") | .usage // empty ]
            | if length == 0 then empty else
                {
                  input_tokens: ([.[].input_tokens // empty] | add),
                  output_tokens: ([.[].output_tokens // empty] | add),
                  cache_read_tokens: ([.[].cached_input_tokens // empty] | add),
                  cache_write_tokens: null,
                  reasoning_output_tokens: ([.[].reasoning_output_tokens // empty] | add),
                  total_tokens: (([.[].input_tokens // empty] | add)
                                 + ([.[].output_tokens // empty] | add)),
                }
              end' "$leg_events" 2>/dev/null)"
    elif [[ -n "$leg_formatter" && -s "$leg_events" ]]; then
        leg_cost="$("$leg_formatter" --cost "$leg_events" 2>/dev/null)"
        leg_usage="$("$leg_formatter" --usage "$leg_events" 2>/dev/null)"
    fi
    [[ -n "$leg_usage" ]] || leg_usage=null
    if [[ ! "$leg_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        leg_cost=""
    fi
    # A retried leg's own cost above reads only the final attempt (the file
    # left at $leg_events); every earlier, archived attempt's own price joins
    # it here, so a leg that burned a retry is not billed as if it had not.
    # But a sum is only honest when every part is a number: an unpriced
    # final attempt, or an unpriced archived attempt (fs_retry_cost_unknown),
    # makes the whole leg cost unknown rather than just the retry's share.
    if [[ "$fs_retry_cost_unknown" == 1 ]]; then
        leg_cost=""
    elif [[ -n "$leg_cost" && -n "$fs_retry_extra_cost" ]]; then
        leg_cost="$(jq -n --argjson a "$leg_cost" --argjson b "$fs_retry_extra_cost" \
            '$a + $b' 2>/dev/null)"
    fi
    leg_harness_error="$(fs_harness_error "$leg_harness" "$leg_events")"
    if [[ -n "$leg_harness_error" && "$leg_rc" != "0" ]]; then
        printf 'fork-sandbox: the %s leg of iteration %s exited %s: %s\n' \
            "$kind" "$n" "$leg_rc" "$leg_harness_error" >> "$sandbox_log"
    fi
    if [[ -n "$leg_error" && "$leg_rc" == "0" ]]; then
        # Never turn a non-zero exit into a different one: the process's own
        # code is the better diagnosis when it has one.
        leg_rc=1
        printf 'fork-sandbox: the %s leg of iteration %s ended in a model error: %s\n' \
            "$kind" "$n" "$leg_error" >> "$sandbox_log"
    fi
    # The second half of the exhaustion backstop, for the leg kinds that
    # can leave work behind: within the backstop's shape, a leg that ran
    # out of retries and still committed is a success, exactly as the
    # implement leg's own check says of a run. Every one of those legs --
    # code, fix and mntfix alike -- measures against its OWN pre-leg head
    # (the head did not move); an unreadable head, before or after, is
    # treated as holding nothing, the same rule. run_leg's "code" kind is
    # only ever called for pass 2+ of the repeat loop -- the top-level
    # implement leg (pass 1) is accounted for separately, outside run_leg --
    # so a pass that starts already ahead of base is now measured against
    # its own pre-leg head instead of always reading as having committed. A
    # review or maintainer leg is not checked
    # this way: it commits nothing by design, and one that ran out of
    # retries left no verdict, which the loop already ends over as a
    # harness error. Note what the leg_error gate does NOT protect against:
    # on the installed pi an exhausted leg -- committed or not -- ends its
    # session in an error turn, so it is already failed above, and a
    # committing-but-exhausted fix leg ends the loop as a harness error the
    # same way any leg that ends in a model error does.
    if [[ -z "$leg_error" && -n "$leg_retry_error" ]]; then
        case "$kind" in
        code|fix|mntfix)
            leg_head_after="$(clone_branch_head)"
            if [[ -z "$leg_head_before" || -z "$leg_head_after" \
                || "$leg_head_after" == "$leg_head_before" ]]; then
                leg_failed_retry=1
            fi
            ;;
        esac
        if [[ -n "$leg_failed_retry" ]]; then
            leg_error="pi exhausted its automatic retries and committed nothing: $leg_retry_error"
            # The model-error line above, not a new code: the leg failed,
            # and how it failed is the reason, not the number; and the same
            # never-overwrite-a-nonzero-rc guard.
            if [[ "$leg_rc" == "0" ]]; then
                leg_rc=1
            fi
            printf 'fork-sandbox: the %s leg of iteration %s exhausted its automatic retries and committed nothing: %s\n' \
                "$kind" "$n" "$leg_retry_error" >> "$sandbox_log"
        fi
    fi
    # The run's total cost is the implement leg plus every loop leg, and a sum
    # is only honest when every part is known. One leg the harness priced
    # nowhere makes the total unknown rather than low.
    if [[ -n "$leg_cost" ]]; then
        loop_cost_sum="$(jq -n --argjson a "$loop_cost_sum" --argjson b "$leg_cost" \
            '$a + $b' 2>/dev/null)"
        if [[ -z "$loop_cost_sum" ]]; then
            loop_cost_sum=0
            loop_cost_unknown=1
        fi
    else
        loop_cost_unknown=1
    fi
}

# ------------------------------------------------------ per-leg refresh --
# Every code and fix leg refreshes the same way the step-1 implement leg
# above always has; plan, review and maintain legs never do. run_leg (above)
# runs a leg's own first attempt; arming the nudge before that call, and
# draining whatever hand-off chain follows it, is the caller's job -- see
# fs_refresh_arm/fs_refresh_chain below and the three call sites further
# down (a code step's own pass loop, and the legacy and composed fix loops)
# that use them. The step-1 implement leg's own chain, above, is untouched
# by any of this: refresh_ended/continuations_json keep meaning exactly what
# they always have.

# Arm the inbox hook's nudge for the NEXT leg this sandbox launches, sized to
# THAT leg's own model -- "each leg's threshold is computed against that
# leg's own model's context window." $1 the model. A no-op when refresh is
# disabled for the run. Must run BEFORE that leg's own run_leg call: the
# hook reads this file from the very first turn of that leg's sandbox, not
# only its continuations -- a leg nudged on pass 1 is exactly how the step-1
# implement leg's own chain, above, already works.
fs_refresh_arm() {
    local model="$1"
    [[ "$refresh_enabled" == "1" && -n "$refresh_config" ]] || return 0
    local refresh_context_window refresh_threshold_tokens refresh_ceiling_tokens
    # A hand-off still waiting in the shared outbox (the step-1 chain leaves
    # its capped one there) belongs to an earlier leg; this leg's chain would
    # otherwise take it as its own first continuation.
    if [[ -e "$outbox_dir/handoff.md" || -L "$outbox_dir/handoff.md" ]]; then
        fs_refresh_unclaimed_n=$(( ${fs_refresh_unclaimed_n:-0} + 1 ))
        mv -f -- "$outbox_dir/handoff.md" \
            "$run_dir/handoff-unclaimed-$fs_refresh_unclaimed_n.md" 2>/dev/null
    fi
    fs_refresh_window_for_model "$refresh_at" "$model"
    {
        printf 'THRESHOLD_TOKENS=%s\n' "$refresh_threshold_tokens"
        printf 'OUTBOX_DIR=%s\n' "$outbox_dir"
        printf 'CLONE_DIR=%s\n' "$clone_dir"
        printf 'CEILING_TOKENS=%s\n' "$refresh_ceiling_tokens"
    } > "$refresh_config"
    fs_reject_unsafe_chars "$refresh_config"
}

# Disarm the nudge: no leg between this call and the next fs_refresh_arm may
# be told to hand off. Every plan, review and maintain leg runs with this
# disarmed, and every eligible leg's own chain disarms again the moment its
# chain ends (fs_refresh_chain's own last act, below), so the window where
# it is armed is never wider than one leg's own run_leg call plus its chain.
fs_refresh_disarm() {
    [[ -n "$refresh_config" ]] && rm -f -- "$refresh_config" 2>/dev/null
    return 0
}

# Drain whatever hand-off chain follows a "code"/"fix"/"mntfix" leg that
# run_leg (above) just ran, the same stall/cap/stale/nudge logic the step-1
# implement leg's own chain uses, scoped to THIS leg instead of the whole
# run: every artifact name carries $1, the leg's own tag (run_leg's own
# $leg_tag, read back from the caller -- never "code-1"/"fix-1" bare, which
# stay reserved for the step-1 implement leg's flat numbering so the two
# schemes can never collide), so two legs that both refresh never overwrite
# each other's hand-offs, prompts or event files.
#
# $1 leg tag, $2 kind (for log lines and the leg_refreshes_json record), $3
# the model (for this leg's own window), $4 the original brief, $5 (optional)
# a findings file -- a fix leg's own verdict text, so ITS chain carries what
# that leg was asked to fix, not just the brief (decision: "a fix leg's
# continuation still carries ... the findings it was given").
#
# A no-op when refresh is disabled, or this leg's own harness (run_leg's
# $leg_harness, read back the same way) is not claude -- "a leg seated on a
# non-claude harness simply does not refresh." On return: $leg_rc, $leg_cost
# and $leg_usage are overwritten to describe the chain's LAST leg, the same
# "judged by its last coding leg" rule the implement leg's own chain
# applies -- so every existing caller that reads run_leg's own output
# variables right after calling it keeps working unchanged merely by
# calling this in between; $loop_cost_sum gains each continuation's own
# cost, same accumulator every other leg already adds to; $next_leg_no
# advances by one per continuation, so fs_archive_inbox's addenda ordering
# stays one flat, run-wide sequence across every leg kind.
fs_refresh_chain() {
    local chain_tag="$1" chain_kind="$2" chain_model="$3" chain_brief="$4" \
        chain_findings="${5:-}"
    [[ "$refresh_enabled" == "1" && "$leg_harness" == "claude" ]] || return 0
    local refresh_context_window refresh_threshold_tokens refresh_ceiling_tokens
    fs_refresh_window_for_model "$refresh_at" "$chain_model"
    fs_refresh_window_mismatch "$leg_events" "$refresh_context_window" \
        | tee -a "$sandbox_log"

    local chain_n=0 chain_ended="" chain_last_events="$leg_events" \
        chain_head_before="" chain_outbox_before="" chain_next_n="" \
        chain_record_name="" chain_cont_prompt="" chain_cont_events="" \
        chain_leg_no="" chain_stale=0 chain_stale_json=false \
        chain_summary_arr='[]' chain_cost_known=1 chain_cost_sum="${leg_cost:-0}" \
        cont_cost="" cont_usage="" summed="" merged=""
    [[ -n "$leg_cost" ]] || chain_cost_known=0
    while :; do
        if [[ "${stop_requested:-0}" == 1 ]]; then
            chain_ended="stop-requested"
            break
        fi
        if [[ -f "$outbox_dir/handoff.md" ]]; then
            if fs_refresh_is_stall "$(( chain_n + 1 ))" \
                "$chain_head_before" "$(clone_branch_head)" \
                "$chain_outbox_before" "$(fs_refresh_outbox_sig "$outbox_dir")"; then
                chain_ended="stalled"
                mv -f -- "$outbox_dir/handoff.md" \
                    "$run_dir/handoff-stalled-$chain_tag-$(( chain_n + 1 )).md" 2>/dev/null
                printf 'fork-sandbox: %s leg %s continuation %s stalled (hand-off waiting, branch head and outbox unchanged); ending its refresh chain\n' \
                    "$chain_kind" "$chain_tag" "$(( chain_n + 1 ))" | tee -a "$sandbox_log"
                break
            fi
            if (( chain_n >= refresh_max )); then
                chain_ended="cap"
                # Same reason as the step-1 chain's own cap branch above:
                # a hand-off left waiting here would be mistaken for the
                # NEXT leg's own first continuation once fs_refresh_arm
                # rearms, and would read as stale to the inbox hook once
                # that leg commits.
                mv -f -- "$outbox_dir/handoff.md" \
                    "$run_dir/handoff-capped-$chain_tag-$(( chain_n + 1 )).md" 2>/dev/null
                break
            fi
            chain_next_n=$(( chain_n + 1 ))
            if ! fs_refresh_take_handoff "$outbox_dir" "$run_dir" \
                "$chain_tag-c$chain_next_n" "$sandbox_log" > /dev/null; then
                chain_ended="no-handoff"
                break
            fi
            chain_n="$chain_next_n"
            chain_leg_no="$next_leg_no"
            next_leg_no=$(( next_leg_no + 1 ))
            chain_record_name="handoff-$chain_tag-c$chain_n.md"
            progress_continuation[cur_step_no]="$chain_n"

            chain_stale=0
            if fs_refresh_handoff_stale "$clone_dir" "$run_dir/$chain_record_name"; then
                chain_stale=1
                printf "fork-sandbox: %s predates the clone's last commit; %s leg %s continuation %s is warned\n" \
                    "$chain_record_name" "$chain_kind" "$chain_tag" "$chain_n" | tee -a "$sandbox_log"
            fi
            chain_stale_json=false; (( chain_stale )) && chain_stale_json=true

            chain_cont_prompt="$run_dir/continuation-prompt-$chain_tag-c$chain_n.md"
            fs_refresh_build_prompt "$chain_n" "$run_dir/$chain_record_name" \
                "$chain_cont_prompt" "$chain_stale" "$continuation_prompt_header" \
                "$chain_brief" "$run_dir" "$plan_file" "$chain_findings"

            jq -c -n --arg leg "$chain_tag" --argjson c "$chain_n" --arg handoff "$chain_record_name" \
                '{type: "system", subtype: "fork_sandbox_continuation", leg: $leg, continuation: $c, handoff: $handoff}' \
                >> "$leg_events" 2>/dev/null
            printf '\n== fork-sandbox: %s leg %s, continuation %s (from %s) ==\n' \
                "$chain_kind" "$chain_tag" "$chain_n" "$chain_record_name"

            chain_cont_events="$run_dir/events-$chain_tag-continuation-$chain_n.jsonl"
            : > "$chain_cont_events"
            chain_head_before="$(clone_branch_head)"
            chain_outbox_before="$(fs_refresh_outbox_sig "$outbox_dir")"
            _fs_chain_attempt() {
                if [[ -n "$leg_formatter" ]]; then
                    fs_run_lock_closed "${leg_seat_cmd[@]}" < "$chain_cont_prompt" \
                        2> >(tee -a "$sandbox_log" >&2) \
                        | tee -a "$leg_events" -a "$chain_cont_events" \
                        | "$leg_formatter"
                else
                    fs_run_lock_closed "${leg_seat_cmd[@]}" < "$chain_cont_prompt" \
                        2> >(tee -a "$sandbox_log" >&2) \
                        | tee -a "$leg_events" -a "$chain_cont_events"
                fi
                _fs_leg_attempt_rc="${PIPESTATUS[0]:-1}"
            }
            fs_run_claude_leg_with_retry "$leg_harness" "$chain_cont_events" "$sandbox_log" \
                "the $chain_kind leg $chain_tag's continuation $chain_n" _fs_chain_attempt "$leg_formatter"
            leg_rc="$fs_retry_rc"
            total_leg_retries=$(( total_leg_retries + fs_retry_count ))
            fs_archive_inbox "$chain_leg_no" "$leg_harness" "$leg_rc"
            progress_write running
            chain_last_events="$chain_cont_events"
            fs_refresh_window_mismatch "$chain_cont_events" "$refresh_context_window" \
                | tee -a "$sandbox_log"

            cont_cost="$("$leg_formatter" --cost "$chain_cont_events" 2>/dev/null)"
            cont_usage="$("$leg_formatter" --usage "$chain_cont_events" 2>/dev/null)"
            [[ -n "$cont_usage" ]] || cont_usage=null
            if [[ "$fs_retry_cost_unknown" == 1 ]]; then
                cont_cost=""
            elif [[ -n "$fs_retry_extra_cost" ]]; then
                if [[ "$cont_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                    cont_cost="$(jq -n --argjson a "$cont_cost" --argjson b "$fs_retry_extra_cost" \
                        '$a + $b' 2>/dev/null)"
                else
                    cont_cost=""
                fi
            fi
            if [[ "$cont_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                chain_cost_sum="$(jq -n --argjson a "$chain_cost_sum" --argjson b "$cont_cost" \
                    '$a + $b' 2>/dev/null)"
                [[ -n "$chain_cost_sum" ]] || { chain_cost_sum=0; chain_cost_known=0; }
                summed="$(jq -n --argjson a "$loop_cost_sum" --argjson b "$cont_cost" \
                    '$a + $b' 2>/dev/null)"
                if [[ -n "$summed" ]]; then
                    loop_cost_sum="$summed"
                else
                    loop_cost_unknown=1
                fi
            else
                cont_cost=null
                chain_cost_known=0
                loop_cost_unknown=1
            fi

            merged="$(jq -c -n --argjson prev "$chain_summary_arr" --argjson c "$chain_n" \
                --argjson exit "$leg_rc" --argjson cost "$cont_cost" --argjson usage "$cont_usage" \
                --arg handoff "$chain_record_name" --argjson handoff_stale "$chain_stale_json" \
                --argjson retries "$fs_retry_records" \
                '$prev + [{continuation: $c, exit: $exit, cost_usd: $cost, usage: $usage, handoff: $handoff, handoff_stale: $handoff_stale, retries: $retries}]' \
                2>/dev/null)"
            [[ -n "$merged" ]] && chain_summary_arr="$merged"

            if [[ "$leg_rc" != "0" ]]; then
                if [[ -f "$outbox_dir/handoff.md" && ! -L "$outbox_dir/handoff.md" ]]; then
                    mv -f -- "$outbox_dir/handoff.md" \
                        "$run_dir/handoff-$chain_tag-after-error.md" 2>/dev/null
                fi
                chain_ended="leg-error"
                break
            fi
            continue
        fi
        if fs_refresh_leg_was_nudged "$chain_last_events"; then
            chain_ended="no-handoff"
        else
            chain_ended="empty-outbox"
        fi
        break
    done
    [[ -n "$chain_ended" ]] || chain_ended="none"
    if (( chain_cost_known )); then
        leg_cost="$chain_cost_sum"
    else
        leg_cost=""
    fi
    # A single leg's whole chain is one conversation per sub-leg, not one --
    # usage is only meaningful when there is exactly one to report, same
    # rule the fix loops below already apply to a multi-pass fix round.
    (( chain_n > 0 )) && leg_usage=null
    merged="$(jq -c -n --argjson prev "$leg_refreshes_json" --arg leg "$chain_tag" \
        --arg kind "$chain_kind" --arg ended "$chain_ended" \
        --argjson continuations "$chain_summary_arr" \
        '$prev + [{leg: $leg, kind: $kind, ended: $ended, continuations: $continuations}]' \
        2>/dev/null)"
    [[ -n "$merged" ]] && leg_refreshes_json="$merged"
    printf 'fork-sandbox: %s leg %s: refresh ended %s (%s continuation leg(s) ran)\n' \
        "$chain_kind" "$chain_tag" "$chain_ended" "$chain_n"
    fs_refresh_disarm
}

# Walk every run's steps -- composed and legacy-translated alike -- after
# the first code leg. Both step flavors share this same run_leg
# accounting primitive; cur_legacy (set per-step below) branches the
# handful of places their record names, field-name flavor and artifact
# paths still differ. Composed records always use review field names for
# both review and maintain steps, per the pipeline schema; legacy
# records use maintainer-flavored names only for a legacy maintainer
# step (see the loop-json writer's own flavor branch, further down).
cur_first_code=0
cur_first_code_ran=0
for ((cur_scan = 1; cur_scan <= run_step_count; cur_scan++)); do
    [[ "${run_step_kind[$cur_scan]}" == code ]] && { cur_first_code="$cur_scan"; break; }
done
[[ "$cur_first_code" == 1 && "${run_step_kind[1]}" == code ]] && cur_first_code_ran=1
cur_has_review=0
for ((cur_scan = 1; cur_scan <= run_step_count; cur_scan++)); do
    [[ "${run_step_kind[$cur_scan]}" == review ]] && { cur_has_review=1; break; }
done
for ((cur_step_no = 1; cur_step_no <= run_step_count && stop_requested != 1; cur_step_no++)); do
    cur_kind="${run_step_kind[$cur_step_no]}"
    cur_step_idx="${run_step_idx[$cur_step_no]}"
    cur_cap="${run_step_cap[$cur_step_no]}"
    cur_prompt="${run_step_prompt[$cur_step_no]}"
    cur_legacy=0; [[ -z "$cur_step_idx" ]] && cur_legacy=1
    if [[ "$cur_legacy" == 1 ]]; then
        cur_inner_prompt=""
        if [[ "$cur_kind" == maintainer ]]; then
            cur_model="${maintainer_model:-}"; cur_harness="${maintainer_harness:-}"
            cur_fix_model="${mntfix_model:-}"; cur_fix_harness="${mntfix_harness:-}"
            cur_fix_repeat="${mntfix_repeat:-1}"
            cur_verdict_file="${maintainer_verdict_file:-}"
        else
            cur_model="$review_model"; cur_harness="$review_harness"
            cur_fix_model="${fix_model:-}"; cur_fix_harness="${fix_harness:-}"
            cur_fix_repeat="${fix_repeat:-1}"
            cur_verdict_file="$review_verdict_file"
        fi
    else
        cur_model_var="${cur_step_idx}_model"; cur_model="${!cur_model_var}"
        cur_harness_var="${cur_step_idx}_harness"; cur_harness="${!cur_harness_var}"
        cur_inner_prompt_var="${cur_step_idx}_prompt_inner_review"; cur_inner_prompt="${!cur_inner_prompt_var:-}"
        cur_fix_model_var="${cur_step_idx}fix_model"; cur_fix_model="${!cur_fix_model_var:-}"
        cur_fix_harness_var="${cur_step_idx}fix_harness"; cur_fix_harness="${!cur_fix_harness_var:-}"
        cur_fix_repeat_var="${cur_step_idx}fix_repeat"; cur_fix_repeat="${!cur_fix_repeat_var:-1}"
        cur_verdict_file="$clone_dir/.git/${cur_step_idx}-verdict.md"
    fi
    cur_fix_kind=fix
    [[ "$cur_legacy" == 1 && "$cur_kind" == maintainer ]] && cur_fix_kind=mntfix
    cur_coding_rc="$rc"
    [[ "$cur_legacy" == 1 && "$mode" == "review-only" ]] && cur_coding_rc=""
    # The first code pass is the historical implementation invocation.
    if [[ "$cur_kind" == code ]]; then
        cur_pass=1
        cur_code_already_ran=0
        if (( cur_step_no == cur_first_code && cur_first_code_ran )); then
            cur_pass=2
            cur_code_already_ran=1
        fi
        # Only the step whose own pass 1 already ran (above, outside this
        # walker) owns whatever $rc/stop_requested it finds here -- that is
        # ITS OWN pass 1 result. Every other code step is seeing $rc/
        # stop_requested left behind by an EARLIER step or leg; if either
        # is already set, this step's own leg never gets to run, so it is
        # "skipped", not "failed" -- failed is reserved for the leg that
        # actually ran and lost.
        if [[ "$cur_code_already_ran" == 0 ]]; then
            if [[ "${stop_requested:-0}" == 1 ]]; then
                progress_state[cur_step_no]="skipped"
                progress_ended[cur_step_no]="stop-requested"
                progress_write running
                continue
            fi
            if [[ "$rc" != "0" ]]; then
                progress_state[cur_step_no]="skipped"
                progress_ended[cur_step_no]="skipped"
                progress_write running
                continue
            fi
        fi
        # Already "running" (from pass 1, above) for the first code step;
        # for any other code step this is where it becomes the active one.
        # progress_i starts at the passes already run outside this loop
        # (1 for the first code step, 0 for any other).
        progress_state[cur_step_no]="running"
        progress_i[cur_step_no]=$(( cur_pass - 1 ))
        progress_write running
        for ((; cur_pass <= cur_cap && rc == 0 && stop_requested != 1; cur_pass++)); do
            # i counts passes BEGUN, so this counts before the leg runs --
            # the same rule the review/maintain loop below applies to its
            # own cur_i.
            progress_i[cur_step_no]="$cur_pass"
            progress_continuation[cur_step_no]=0
            progress_write running
            # Built fresh for every pass, like the fix prompt below, so an
            # addendum archived by an earlier pass reaches this one. With
            # none archived, and no plan to embed either, the prompt is the
            # handoff itself, no copy.
            cur_code_prompt="$handoff"
            cur_code_addenda="$(fs_refresh_emit_addenda "$run_dir")"
            if [[ -n "$cur_code_addenda" || -n "$plan_file" ]]; then
                cur_code_prompt="$run_dir/code-prompt-$cur_step_no-$cur_pass.md"
                { cat -- "$handoff"; fs_emit_plan_section "$plan_file" code || exit 1; \
                  printf '%s\n' "$cur_code_addenda"; } > "$cur_code_prompt.part"
                mv -f "$cur_code_prompt.part" "$cur_code_prompt"
            fi
            # A legacy code step has no per-step seat of its own -- every
            # pass runs the implement model/harness, $model/$harness, the
            # same as run_leg's own fallback for a "code" kind leg with no
            # step_idx. A composed step's own seat, cur_model/cur_harness
            # (resolved once per step above), applies to its code passes
            # too -- the branch above that sets them does not gate on
            # cur_kind.
            cur_code_model="$cur_model"; cur_code_harness="$cur_harness"
            [[ "$cur_legacy" == 1 ]] && { cur_code_model="$model"; cur_code_harness="$harness"; }
            if [[ "$refresh_enabled" == "1" && "$cur_code_harness" == "claude" ]]; then
                fs_refresh_arm "$cur_code_model"
            else
                fs_refresh_disarm
            fi
            run_leg code "$cur_pass" "$cur_code_prompt" "$cur_step_idx"
            fs_refresh_chain "$leg_tag" code "$cur_code_model" "$handoff_original" ""
            rc="$leg_rc"
            progress_write running
        done
        # stop_requested outranks $rc here the same way it does in the
        # final sweep below: a leg killed by a TERM-driven stop usually
        # exits nonzero too, and that nonzero is the stop, not a genuine
        # failure of this step's own leg.
        if [[ "${stop_requested:-0}" == 1 ]]; then
            progress_state[cur_step_no]="skipped"
            progress_ended[cur_step_no]="stop-requested"
        elif [[ "$rc" == "0" ]]; then
            progress_state[cur_step_no]="done"
        else
            progress_state[cur_step_no]="failed"
            progress_any_step_failed=1
        fi
        progress_write running
        continue
    fi
    # A plan step: one leg, no loop. It writes the outbox plan and commits
    # nothing; setting $rc on any failure is what skips every later step.
    if [[ "$cur_kind" == plan ]]; then
        if [[ "${stop_requested:-0}" == 1 ]]; then
            progress_state[cur_step_no]="skipped"
            progress_ended[cur_step_no]="stop-requested"
            progress_write running
            continue
        fi
        if [[ "$rc" != "0" ]]; then
            progress_state[cur_step_no]="skipped"
            progress_ended[cur_step_no]="skipped"
            progress_write running
            continue
        fi
        progress_state[cur_step_no]="running"
        progress_i[cur_step_no]=1
        progress_write running
        cur_plan_outbox_file="$outbox_dir/plan.md"
        rm -f -- "$cur_plan_outbox_file"
        cur_plan_head_before="$(clone_branch_head)"
        # A plan leg never refreshes -- it is a short read-and-verdict leg,
        # same as review and maintain, below.
        fs_refresh_disarm
        run_leg plan 1 "$cur_prompt" "$cur_step_idx"
        rc="$leg_rc"
        cur_plan_head_after="$(clone_branch_head)"
        cur_plan_ended="" cur_plan_detail=""
        if [[ "$rc" != "0" ]]; then
            cur_plan_ended="harness-error"
            cur_plan_detail="the plan leg exited $rc${leg_error:+ ($leg_error)}${leg_harness_error:+: $leg_harness_error}$(fs_leg_retry_suffix "${leg_retries_count:-0}")"
        elif [[ -z "$cur_plan_head_before" || -z "$cur_plan_head_after" \
            || "$cur_plan_head_after" != "$cur_plan_head_before" ]]; then
            cur_plan_ended="committed"
            cur_plan_detail="the plan leg committed to the branch -- a plan leg writes its plan to the outbox and commits nothing"
            rc=1
        elif [[ -L "$cur_plan_outbox_file" || ! -s "$cur_plan_outbox_file" ]]; then
            cur_plan_ended="harness-error"
            cur_plan_detail="the plan leg left no plan at $cur_plan_outbox_file"
            rc=1
        else
            cp -- "$cur_plan_outbox_file" "$plan_file.part" 2>/dev/null \
                && mv -f "$plan_file.part" "$plan_file"
            if [[ ! -s "$plan_file" ]]; then
                cur_plan_ended="harness-error"
                cur_plan_detail="the plan could not be copied from $cur_plan_outbox_file"
                rc=1
            else
                # A missed BLOCKED runs a code leg against a plan that says
                # not to, so match loosely: the first non-blank line, past
                # any heading marker or emphasis, starting with the word
                # ("# **BLOCKED**", "BLOCKED: <reason>").
                cur_plan_first_line="$(awk 'NF { print; exit }' "$plan_file" \
                    | tr -d '\000-\037\177' \
                    | sed -E 's/^[[:space:]]*//; s/^#+[[:space:]]*//; s/^[*_`]+//')"
                if [[ "$cur_plan_first_line" =~ ^BLOCKED([^[:alnum:]_]|$) ]]; then
                    cur_plan_ended="blocked"
                    cur_plan_detail="the plan is BLOCKED"
                    rc=1
                else
                    cur_plan_ended="done"
                fi
            fi
        fi
        jq -n --argjson cap 1 \
            --arg ended "$cur_plan_ended" --arg detail "$cur_plan_detail" \
            --argjson cost "${leg_cost:-null}" --argjson usage "${leg_usage:-null}" \
            --argjson retries "${leg_retries_json:-[]}" \
            '{cap:$cap,
              ended:(if $ended=="" then null else $ended end),
              detail:(if $detail=="" then null else $detail end),
              cost_usd:$cost, usage:$usage, retries:$retries}' \
            > "$run_dir/step-${cur_step_no}-loop.json.part" 2>/dev/null \
            && mv -f "$run_dir/step-${cur_step_no}-loop.json.part" \
                "$run_dir/step-${cur_step_no}-loop.json"
        # run_leg already folded this leg's cost into loop_cost_sum.
        if [[ "$cur_plan_ended" == done ]]; then
            progress_state[cur_step_no]="done"
            printf 'fork-sandbox: plan: done\n'
        else
            progress_state[cur_step_no]="failed"
            progress_any_step_failed=1
            printf 'fork-sandbox: plan: %s%s\n' "$cur_plan_ended" \
                "${cur_plan_detail:+ ($cur_plan_detail)}"
            # BLOCKED ends the run before any code leg; the plan's own text,
            # not just its outcome, is what the operator needs to see, so it
            # is printed here rather than left to be found in the run dir.
            if [[ "$cur_plan_ended" == blocked && -s "$plan_file" ]]; then
                printf '\n'
                cat -- "$plan_file"
                printf '\n'
            fi
        fi
        progress_ended[cur_step_no]="$cur_plan_ended"
        progress_write running
        continue
    fi
    if [[ "$cur_legacy" == 1 ]]; then
        if [[ "$cur_kind" == maintainer ]]; then
            cur_loop_json="$run_dir/maintainer-loop.json"
        else
            cur_loop_json="$run_dir/review-loop.json"
        fi
    else
        cur_loop_json="$run_dir/step-${cur_step_no}-loop.json"
    fi
    progress_state[cur_step_no]="running"
    progress_i[cur_step_no]=0
    progress_write running
    cur_ended=""; cur_detail=""; cur_iters='[]'
    cur_head="$(clone_branch_head)"
    if [[ -z "$cur_head" ]]; then
        cur_ended=skipped; cur_detail="branch $branch could not be read from the clone"
    elif [[ "$cur_head" == "$base_sha" ]]; then
        cur_ended=skipped
        if [[ "$cur_legacy" == 1 && "$cur_kind" == review ]]; then
            cur_detail="the session committed nothing, so there is nothing to review"
        else
            cur_detail="the branch holds no commits, so there is nothing to review"
        fi
    fi
    cur_save() {
        if [[ "$cur_legacy" == 1 && "$cur_kind" == maintainer ]]; then
            jq -n --argjson cap "$cur_cap" --arg maintainer_model "$cur_model" --arg maintainer_harness "$cur_harness" \
                --arg fix_harness "$cur_fix_harness" --arg fix_model "$cur_fix_model" --argjson fix_repeat "$cur_fix_repeat" \
                --arg ended "$cur_ended" --arg detail "$cur_detail" --argjson coding_exit_code "${cur_coding_rc:-null}" --argjson iterations "$cur_iters" \
                '{cap:$cap,maintainer_model:(if $maintainer_model=="" then null else $maintainer_model end),maintainer_harness:(if $maintainer_harness=="" then null else $maintainer_harness end),fix_harness:(if $fix_harness=="" then null else $fix_harness end),fix_model:(if $fix_model=="" then null else $fix_model end),fix_repeat:(if $fix_repeat==1 then null else $fix_repeat end),ended:(if $ended=="" then null else $ended end),detail:(if $detail=="" then null else $detail end),coding_exit_code:$coding_exit_code,iterations:$iterations}' > "$cur_loop_json.part" 2>/dev/null && mv -f "$cur_loop_json.part" "$cur_loop_json" || rm -f "$cur_loop_json.part"
        else
            jq -n --argjson cap "$cur_cap" --arg review_model "$cur_model" --arg review_harness "$cur_harness" \
                --arg fix_harness "$cur_fix_harness" --arg fix_model "$cur_fix_model" --argjson fix_repeat "$cur_fix_repeat" \
                --arg ended "$cur_ended" --arg detail "$cur_detail" --argjson coding_exit_code "${cur_coding_rc:-null}" --argjson iterations "$cur_iters" \
                '{cap:$cap,review_model:(if $review_model=="" then null else $review_model end),review_harness:(if $review_harness=="" then null else $review_harness end),fix_harness:(if $fix_harness=="" then null else $fix_harness end),fix_model:(if $fix_model=="" then null else $fix_model end),fix_repeat:(if $fix_repeat==1 then null else $fix_repeat end),ended:(if $ended=="" then null else $ended end),detail:(if $detail=="" then null else $detail end),coding_exit_code:$coding_exit_code,iterations:$iterations}' > "$cur_loop_json.part" 2>/dev/null && mv -f "$cur_loop_json.part" "$cur_loop_json" || rm -f "$cur_loop_json.part"
        fi
    }
    # The current iteration as a one-element JSON array, built from whatever
    # of cur_review_exit/cur_fix_exit/cur_findings/cur_before/cur_after is
    # known right now -- unfinished fields read null, the same rule the
    # legacy loops' own iter_json followed. Shared by cur_save_live (a
    # snapshot that is NOT folded into cur_iters) and the end-of-iteration
    # block (which folds it in for good).
    cur_iter_record() {
        if [[ "$cur_legacy" == 1 && "$cur_kind" == maintainer ]]; then
            jq -cn --argjson i "$cur_i" --argjson findings "$cur_findings" --argjson maintainer_exit "${cur_review_exit:-null}" --argjson fix_exit "${cur_fix_exit:-null}" --argjson maintainer_cost "${cur_review_cost:-null}" --argjson fix_cost "${cur_fix_cost:-null}" --argjson maintainer_usage "${cur_review_usage:-null}" --argjson fix_usage "${cur_fix_usage:-null}" --arg before "${cur_before:-}" --arg after "${cur_after:-}" --argjson retries "${cur_retries:-[]}" \
                '[{i:$i,findings:$findings,maintainer_exit:$maintainer_exit,fix_exit:$fix_exit,head_before:(if $before=="" then null else $before end),head_after:(if $after=="" then null else $after end),commits_added:null,maintainer_cost_usd:$maintainer_cost,fix_cost_usd:$fix_cost,maintainer_usage:$maintainer_usage,fix_usage:$fix_usage,retries:$retries}]'
        else
            jq -cn --argjson i "$cur_i" --argjson findings "$cur_findings" --argjson review_exit "${cur_review_exit:-null}" --argjson fix_exit "${cur_fix_exit:-null}" --argjson review_cost "${cur_review_cost:-null}" --argjson fix_cost "${cur_fix_cost:-null}" --argjson review_usage "${cur_review_usage:-null}" --argjson fix_usage "${cur_fix_usage:-null}" --arg before "${cur_before:-}" --arg after "${cur_after:-}" --argjson retries "${cur_retries:-[]}" \
                '[{i:$i,findings:$findings,review_exit:$review_exit,fix_exit:$fix_exit,head_before:(if $before=="" then null else $before end),head_after:(if $after=="" then null else $after end),commits_added:null,review_cost_usd:$review_cost,fix_cost_usd:$fix_cost,review_usage:$review_usage,fix_usage:$fix_usage,retries:$retries}]'
        fi
    }
    # Write cur_loop_json with the in-progress iteration folded in WITHOUT
    # committing it to cur_iters -- a runner killed mid-leg leaves behind
    # every iteration that finished plus a partial record of the one that
    # did not, the same promise the deleted save_review_loop/
    # save_maintainer_loop made ("called after every leg"). Legacy only:
    # composed step-N-loop.json never had this promise to keep.
    cur_save_live() {
        local cur_rec cur_live
        cur_rec="$(cur_iter_record 2>/dev/null)" || cur_rec='[]'
        [[ -n "$cur_rec" ]] || cur_rec='[]'
        cur_live="$(jq -cn --argjson old "$cur_iters" --argjson cur "$cur_rec" '$old + $cur' 2>/dev/null)" || cur_live="$cur_iters"
        local cur_iters_before_live="$cur_iters"
        cur_iters="$cur_live"
        cur_save
        cur_iters="$cur_iters_before_live"
    }
    for ((cur_i = 1; cur_i <= cur_cap; cur_i++)); do
        if [[ -n "$cur_ended" ]]; then break; fi
        if [[ "${stop_requested:-0}" == 1 ]]; then cur_ended=stop-requested; break; fi
        # i counts iterations BEGUN, so this counts before the leg runs --
        # the step's own state/ended are finalized once, after this whole
        # loop ends, below.
        progress_i[cur_step_no]="$cur_i"
        # The review/maintain leg in flight never refreshes; the last fix
        # leg's count must not linger through it.
        progress_continuation[cur_step_no]=0
        progress_write running
        rm -f "$cur_verdict_file"
        if [[ "$cur_legacy" == 1 ]]; then
            if [[ "$cur_kind" == maintainer ]]; then
                cur_prompt_iter="$run_dir/maintainer-prompt-$cur_i.md"
            else
                cur_prompt_iter="$run_dir/review-prompt-$cur_i.md"
            fi
        else
            cur_prompt_iter="$run_dir/step-${cur_step_no}-prompt-${cur_i}.md"
        fi
        # A maintain step's first pass receives the nearest preceding
        # verdict of either review-flavored kind; later passes receive
        # its own previous verdict.  Select the matching static prompt
        # base before writing it, so its role paragraph is truthful.
        cur_prev=""
        if [[ "$cur_legacy" != 1 && "$cur_kind" == maintainer ]]; then
            if (( cur_i > 1 )); then cur_prev="$run_dir/${cur_step_idx}-maintain-verdict-$((cur_i-1)).md"
            else
                for ((cur_j = cur_step_no - 1; cur_j >= 1; cur_j--)); do
                    cur_prev="$(find "$run_dir" -maxdepth 1 -type f \( -name "s${cur_j}-review-verdict-*.md" -o -name "s${cur_j}-maintain-verdict-*.md" \) -print 2>/dev/null | sed -nE 's!.*/!!;s/.*-([0-9]+)\.md$/\1 &/p' | sort -n | tail -n1 | cut -d' ' -f2-)"
                    [[ -n "$cur_prev" ]] && cur_prev="$run_dir/$cur_prev"
                    [[ -n "$cur_prev" ]] && break
                done
            fi
        fi
        # The inner-review wording claims a review leg already read the diff,
        # so a first pass takes it only when an earlier review step ran, not
        # merely an earlier maintain step.
        cur_prev_reviewed=1
        if [[ "$cur_legacy" != 1 && "$cur_kind" == maintainer ]] && (( cur_i == 1 )); then
            cur_prev_reviewed=0
            for ((cur_j = 1; cur_j < cur_step_no; cur_j++)); do
                compgen -G "$run_dir/s${cur_j}-review-verdict-*.md" >/dev/null && { cur_prev_reviewed=1; break; }
            done
        fi
        cur_prompt_base="$cur_prompt"
        [[ "$cur_prev_reviewed" == 1 && -n "$cur_prev" && -f "$cur_prev" && -n "$cur_inner_prompt" ]] && cur_prompt_base="$cur_inner_prompt"
        # A legacy iteration's prompt is rebuilt every pass -- a maintainer
        # pass concatenates a whole review verdict into it -- so it keeps the
        # deleted loops' build-then-rename discipline (see review_prompt's
        # own .part+mv above): build beside the destination and rename, so a
        # reader never sees a half-assembled file. A composed step's prompt
        # was already written directly before this walker existed; that is
        # unchanged here.
        cur_prompt_iter_out="$cur_prompt_iter"
        [[ "$cur_legacy" == 1 ]] && cur_prompt_iter_out="$cur_prompt_iter.part"
        {
            cat -- "$cur_prompt_base"
            fs_emit_plan_section "$plan_file" || exit 1
            if [[ "$cur_legacy" == 1 && -n "$cur_coding_rc" && "$cur_coding_rc" != "0" ]]; then
                fs_emit_coding_exit_note "$cur_coding_rc"
            fi
            # Suite runs earlier legs recorded against exactly this HEAD,
            # read fresh each pass: a fix leg's commit moves it, and the
            # earlier record then stops matching. Untrusted text from the
            # sandbox's outbox; the emitter never fails the run.
            fs_emit_test_record_section "$outbox_dir/$FS_TEST_LEDGER_NAME" \
                "$(clone_branch_head)" review
            cur_addenda_list="$(fs_addenda_dirs)"
            if [[ -n "$cur_addenda_list" ]]; then
                printf '\n---\n\n## Operator addenda delivered to earlier legs of this run\n\n'
                if [[ "$cur_legacy" == 1 ]]; then
                    printf 'The operator sent the messages below to an earlier leg of this run,\n'
                    printf 'oldest first. The live inbox bound into this sandbox no longer holds\n'
                    printf 'them -- a claude leg archives what it saw the moment it ends -- so\n'
                    printf 'this is the only copy this leg will see. Check the commit range\n'
                    printf 'under review against each one: if it asks for work the commits do\n'
                    printf 'not contain, that is a finding under "An unfollowed addendum is a\n'
                    printf 'finding" above, citing the message file itself.\n'
                fi
                while IFS= read -r cur_addenda_dir; do
                    [[ -n "$cur_addenda_dir" ]] || continue
                    for cur_addenda_file in "$cur_addenda_dir"/*.md; do
                        [[ -f "$cur_addenda_file" ]] || continue
                        printf '\n### %s\n\n' "${cur_addenda_file##*/}"
                        cat -- "$cur_addenda_file"
                    done
                done <<< "$cur_addenda_list"
            fi
            if [[ "$cur_legacy" == 1 && "$cur_kind" == maintainer ]]; then
                if [[ "$cur_has_review" == 1 ]]; then
                    cur_mp_verdict=""
                    cur_mp_n=0
                    for cur_mp_v in "$run_dir"/review-verdict-*.md; do
                        [[ -f "$cur_mp_v" ]] || continue
                        cur_mp_v_n="${cur_mp_v##*/review-verdict-}"
                        cur_mp_v_n="${cur_mp_v_n%.md}"
                        [[ "$cur_mp_v_n" =~ ^[0-9]+$ ]] || continue
                        if (( cur_mp_v_n > cur_mp_n )); then
                            cur_mp_n="$cur_mp_v_n"
                            cur_mp_verdict="$cur_mp_v"
                        fi
                    done
                    if [[ -n "$cur_mp_verdict" ]]; then
                        printf '\n---\n\n## The inner review'\''s final verdict\n\n'
                        printf 'The review loop read the diff line by line before this loop\n'
                        printf 'started. Its verdict from iteration %s is below, in full: this\n' "$cur_mp_n"
                        printf 'is the "findings to build on" the prompt above names. Build on\n'
                        printf 'it rather than re-review what the loop already reviewed'
                        if [[ "$mode" == "review-only" ]]; then
                            printf '. This run\nhas no fix leg, so the branch is unchanged since it was written.\n\n'
                        else
                            printf ' -- but\n'
                            printf 'it is the loop'\''s account of the branch as it stood when the\n'
                            printf 'loop ended, and the fix legs have committed since, so check\n'
                            printf 'each finding against what is there now.\n\n'
                        fi
                        cat -- "$cur_mp_verdict"
                    else
                        printf '\n---\n\n## The inner review left no verdict\n\n'
                        printf 'The review loop was requested, but it ended (%s) without\n' \
                            "${review_loop_ended:-unknown}"
                        printf 'leaving a usable verdict, so there are no findings to build\n'
                        printf 'on despite what the prompt above says: read the diff\n'
                        printf 'yourself.\n'
                    fi
                fi
                if (( cur_i > 1 )); then
                    cur_mp_mnt_prev="$run_dir/maintainer-verdict-$(( cur_i - 1 )).md"
                    if [[ -f "$cur_mp_mnt_prev" ]]; then
                        printf '\n---\n\n## The previous maintainer iteration'\''s verdict\n\n'
                        printf 'The prompt above was written for this loop'\''s first pass, and its\n'
                        printf 'account of what has already been read is stale now: maintainer\n'
                        printf 'iteration %s has already reviewed this branch, and its\n' "$(( cur_i - 1 ))"
                        printf 'verdict, in full, is below. It is a FINDINGS verdict -- had it\n'
                        printf 'approved, the loop would have ended -- and the fix leg that has\n'
                        printf 'committed since was handed exactly those findings. It is the\n'
                        printf 'most recent review this branch has had, ahead of the review\n'
                        printf 'loop'\''s verdict above where one was appended. Read it to know\n'
                        printf 'which of the problems you find were already seen, and what was\n'
                        printf 'committed in answer, then review the branch as it stands now.\n\n'
                        cat -- "$cur_mp_mnt_prev"
                    fi
                fi
            fi
        } > "$cur_prompt_iter_out"
        if [[ "$cur_legacy" == 1 ]]; then
            mv -- "$cur_prompt_iter_out" "$cur_prompt_iter"
        fi
        if [[ "$cur_legacy" != 1 && "$mode" == "review-only" ]]; then
            # A composed read-only step builds on every earlier leg of the
            # run, not just the nearest: each verdict in full, oldest first,
            # labeled by its step, action and seat.
            cur_ro_head_done=0
            for ((cur_j = 1; cur_j < cur_step_no; cur_j++)); do
                cur_ro_action=review
                [[ "${run_step_kind[$cur_j]}" == maintainer ]] && cur_ro_action=maintain
                cur_ro_verdict="$run_dir/s${cur_j}-${cur_ro_action}-verdict-1.md"
                [[ -f "$cur_ro_verdict" ]] || continue
                if (( ! cur_ro_head_done )); then
                    {
                        printf '\n---\n\n## Verdicts of the earlier legs of this run\n\n'
                        printf 'Each earlier leg of this run wrote the verdict below, in full,\n'
                        printf 'oldest first. This run has no fix leg, so the branch is unchanged\n'
                        printf 'since each was written. Build on them rather than redo what they\n'
                        printf 'covered.\n'
                    } >> "$cur_prompt_iter"
                    cur_ro_head_done=1
                fi
                cur_ro_h_var="s${cur_j}_harness"; cur_ro_m_var="s${cur_j}_model"
                printf '\n### Step %s: %s (%s%s)\n\n' "$cur_j" "$cur_ro_action" \
                    "${!cur_ro_h_var}" "${!cur_ro_m_var:+/${!cur_ro_m_var}}" >> "$cur_prompt_iter"
                cat -- "$cur_ro_verdict" >> "$cur_prompt_iter"
            done
        elif [[ "$cur_legacy" != 1 && "$cur_kind" == maintainer ]]; then
            if [[ -n "$cur_prev" && -f "$cur_prev" ]]; then
                printf '\n---\n\n## The previous verdict\n\n' >> "$cur_prompt_iter"
                cat -- "$cur_prev" >> "$cur_prompt_iter"
            fi
        fi
        cur_retries='[]'
        if [[ "$cur_legacy" == 1 ]]; then
            cur_review_exit=null; cur_review_cost=null; cur_review_usage=null; cur_fix_exit=null; cur_fix_cost=null; cur_fix_usage=null; cur_findings=null; cur_before="$cur_head"; cur_after=""
            cur_save_live
        fi
        # A review/maintainer leg never refreshes -- it is a short
        # read-and-verdict leg; the fix leg its FINDINGS verdict may spawn,
        # below, is the one that does.
        fs_refresh_disarm
        run_leg "$cur_kind" "$cur_i" "$cur_prompt_iter" "$cur_step_idx"
        # Tag with which leg retried: the review/maintainer leg and the fix
        # leg(s) below both fold their own retries into this one array, and
        # without a label a reader cannot tell a review retry's {attempt: 1}
        # from a fix retry's own {attempt: 1} in the same iteration.
        cur_retries="$(jq -cn --argjson a "${leg_retries_json:-[]}" --arg leg "$cur_kind" \
            '$a | map(. + {leg: $leg})' 2>/dev/null)"
        [[ -n "$cur_retries" ]] || cur_retries='[]'
        cur_review_exit="$leg_rc"; cur_review_cost="${leg_cost:-null}"; cur_review_usage="${leg_usage:-null}"; cur_fix_exit=null; cur_fix_cost=null; cur_fix_usage=null; cur_findings=null; cur_before="$cur_head"; cur_after=""
        [[ "$cur_legacy" == 1 ]] && cur_save_live
        if [[ "$cur_legacy" == 1 ]]; then
            if [[ "$leg_rc" != 0 ]]; then
                cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i exited $leg_rc${leg_error:+ ($leg_error)}${leg_harness_error:+: $leg_harness_error}$(fs_leg_retry_suffix "${leg_retries_count:-0}")"
            # The verdict is DATA. It is copied, counted and concatenated
            # into a prompt file -- never sourced, never evaluated, never
            # put on a command line. It is also written by a session, so
            # a symlink at that path is not a verdict: refuse it rather
            # than follow it out of the clone.
            elif [[ -L "$cur_verdict_file" || ! -f "$cur_verdict_file" ]]; then
                cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i left no verdict at $cur_verdict_file"
            else
                if [[ "$cur_kind" == maintainer ]]; then
                    cur_copy="$run_dir/maintainer-verdict-$cur_i.md"
                else
                    cur_copy="$run_dir/review-verdict-$cur_i.md"
                fi
                # The run dir outlives the clone, so the copy is the
                # record. Take the original away in the same breath, so
                # iteration i+1 cannot re-read it.
                #
                # On a composed --k8s pod, the clone is leg-writable, so
                # the leg controls this file's size and type too. Bounded
                # the same way a leg's own hand-off files already are
                # (fs_leg_handoff_read): regular file only, capped in size
                # and time, so an oversized verdict cannot exhaust this
                # container's memory or run-volume, and a FIFO cannot
                # hang it. A read that fails this leaves no $cur_copy,
                # which the empty-verdict check right below already
                # treats as a harness error -- the same outcome the
                # pre-existing -L/!-f check above already gives a plain
                # missing or symlinked file.
                fs_leg_handoff_read "$cur_verdict_file" > "$cur_copy.part" 2>/dev/null \
                    && mv -f "$cur_copy.part" "$cur_copy" \
                    || rm -f "$cur_copy.part"
                rm -f "$cur_verdict_file"
                if [[ ! -s "$cur_copy" ]]; then
                    cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i wrote an empty verdict"
                else
                    # Untrusted text on its way to a terminal: strip control
                    # characters so an ESC or a CR in the verdict cannot
                    # spoof the pane or the monitor.
                    cur_line="$(head -n1 "$cur_copy" | tr -d '\000-\037\177' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    # Deliberately nothing here checks the "## Report"
                    # section. The first line is the contract; the report
                    # is a courtesy to the orchestrator, and an absent,
                    # empty or duplicated one must never turn a valid
                    # verdict into a failed loop -- fork-sandbox-status.sh
                    # falls back to printing the whole verdict when the
                    # section is not usable.
                    if [[ "$cur_line" == APPROVED ]]; then
                        cur_findings=0; cur_ended=approved
                        printf 'fork-sandbox: %s iteration %s: APPROVED\n' "$cur_kind" "$cur_i"
                    elif [[ "$cur_line" == FINDINGS ]]; then
                        # One finding per paragraph, each citing file:line --
                        # so count the paragraphs that carry a citation.
                        # That is what the prompt asks for and all that can
                        # be counted without reading the prose.
                        cur_findings="$(awk 'NR == 1 { next } /^## Report$/ { exit } /^[[:space:]]*$/ { if (hit) n++; hit = 0; next } /[^[:space:]:]+:[0-9]+/ { hit = 1 } END { if (hit) n++; print n + 0 }' "$cur_copy" 2>/dev/null)"
                        [[ "$cur_findings" =~ ^[0-9]+$ ]] || cur_findings=null
                        printf 'fork-sandbox: %s iteration %s: FINDINGS (%s cited)\n' "$cur_kind" "$cur_i" "$cur_findings"
                        cur_save_live
                        if [[ "$mode" == "review-only" ]]; then
                            cur_ended=findings
                        else
                            # The fix leg's prompt: the generated header
                            # (the fix seat's own, when a preset seated
                            # one), then the verdict. The base name, unchanged
                            # from before per-pass addenda existed; a repeat
                            # pass N > 1 gets its own "$cur_fix_base-pN.md".
                            if [[ "$cur_kind" == maintainer ]]; then
                                cur_fix_base="$run_dir/maintainer-fix-prompt-${cur_i}"
                                cur_fix_header="$fix_prompt_header"
                                [[ -n "${fxm_fix_prompt_header:-}" ]] && cur_fix_header="$fxm_fix_prompt_header"
                            else
                                cur_fix_base="$run_dir/fix-prompt-${cur_i}"
                                cur_fix_header="$fix_prompt_header"
                                [[ -n "${fxr_fix_prompt_header:-}" ]] && cur_fix_header="$fxr_fix_prompt_header"
                            fi
                            cur_fix_cost=null; cur_fix_known=1
                            # A fix leg stays on the implement harness/model
                            # throughout UNLESS a preset seated its own fix
                            # agent (cur_fix_harness/cur_fix_model, resolved
                            # above) -- the same fallback run_leg itself
                            # applies when it picks this leg's own cmd/model.
                            cur_fix_refresh_model="${cur_fix_model:-$model}"
                            cur_fix_refresh_harness="${cur_fix_harness:-$harness}"
                            # The findings this fix leg (every pass of it) was
                            # asked to fix, stripped of the verdict's own
                            # "## Report" section the same way the fix prompt
                            # itself is -- a refresh chain on any pass carries
                            # exactly what that pass's prompt carried, not the
                            # whole verdict. The path is fixed up front, but
                            # the file itself is only written once a pass
                            # actually leaves a hand-off waiting for
                            # fs_refresh_chain to read (below, right after
                            # each pass's own run_leg) -- refresh defaults ON
                            # for a claude seat, so "armed" alone is true on
                            # almost every run; only a hand-off means the
                            # chain will ever open this file, and a run that
                            # never produces one must not leave it behind
                            # (it isn't part of the legacy filename set).
                            cur_fix_findings="$cur_fix_base-findings.md"
                            # A fix agent with repeat: N runs the fix as N
                            # passes -- distrust of a cheap model's premature
                            # "done": there is no early exit on a pass that
                            # looks finished; only a harness error stops the
                            # passes. The header and verdict are the same
                            # every pass, but the prompt is BUILT fresh each
                            # time (not once, reused): fs_refresh_emit_addenda
                            # picks up whatever this run has archived as of
                            # THIS pass, so an addendum the operator sends
                            # mid-repeat reaches every pass after it arrived,
                            # not just the immediate next one. The iteration
                            # records the LAST pass's exit, the SUM of the
                            # passes' costs (null when any pass went
                            # unpriced), and -- for a single pass -- its
                            # usage; multi-pass usage stays null, each pass's
                            # own events file carrying the detail.
                            for ((cur_fix_pass = 1; cur_fix_pass <= cur_fix_repeat; cur_fix_pass++)); do
                                cur_fix_leg="$cur_i"; (( cur_fix_pass > 1 )) && cur_fix_leg="$cur_i-p$cur_fix_pass"
                                cur_fix_prompt="$cur_fix_base.md"
                                (( cur_fix_pass > 1 )) && cur_fix_prompt="$cur_fix_base-p$cur_fix_pass.md"
                                { cat -- "$cur_fix_header"; fs_emit_plan_section "$plan_file" code || exit 1; \
                                  printf '\n---\n\n'; \
                                  awk '/^## Report$/ { exit } { print }' "$cur_copy"; \
                                  fs_emit_test_record_section "$outbox_dir/$FS_TEST_LEDGER_NAME" \
                                      "$(clone_branch_head)" fix; \
                                  fs_refresh_emit_addenda "$run_dir"; } > "$cur_fix_prompt.part"
                                mv -f "$cur_fix_prompt.part" "$cur_fix_prompt"
                                # Leg-start/leg-end transitions for this fix pass --
                                # a repeated or long-running fix leg must not leave
                                # $updated stuck at the preceding review leg's write.
                                progress_continuation[cur_step_no]=0
                                progress_write running
                                if [[ "$refresh_enabled" == "1" && "$cur_fix_refresh_harness" == "claude" ]]; then
                                    fs_refresh_arm "$cur_fix_refresh_model"
                                else
                                    fs_refresh_disarm
                                fi
                                run_leg "$cur_fix_kind" "$cur_fix_leg" "$cur_fix_prompt"
                                # Captured before fs_refresh_chain overwrites leg_cost with
                                # the chain's total: fix_cost_usd keeps meaning this pass's
                                # own leg, same as the implement leg's cost_usd field: a
                                # continuation's cost lives only in leg_refreshes_json, never
                                # folded in here too (decision 6: add fields, don't redefine).
                                # Same reason for usage: fs_refresh_chain nulls leg_usage once
                                # the chain has any continuation, so the base leg's own usage
                                # has to be captured here or it is lost everywhere.
                                cur_fix_pass_cost="$leg_cost"
                                cur_fix_pass_usage="$leg_usage"
                                # Write the findings file now, not before this pass ran: a
                                # hand-off waiting in the outbox is exactly the condition
                                # fs_refresh_chain's own loop checks first, so this is the
                                # earliest point that is also never too late.
                                if [[ "$refresh_enabled" == "1" && "$cur_fix_refresh_harness" == "claude" \
                                    && -f "$outbox_dir/handoff.md" ]]; then
                                    awk '/^## Report$/ { exit } { print }' "$cur_copy" \
                                        > "$cur_fix_findings.part" \
                                        && mv -f "$cur_fix_findings.part" "$cur_fix_findings"
                                fi
                                fs_refresh_chain "$leg_tag" "$cur_fix_kind" "$cur_fix_refresh_model" \
                                    "$handoff_original" "$cur_fix_findings"
                                # Tag this pass's own retries "fix" (never
                                # $cur_fix_kind's internal mntfix spelling,
                                # to match the shape documented at the
                                # review/maintainer leg's own tag above) plus,
                                # when there is more than one pass to tell
                                # apart, which pass -- see docs/presets.md's
                                # own "when the fix seat's repeat ran more
                                # than one" and the header comment above.
                                cur_retries="$(jq -cn --argjson a "$cur_retries" --argjson b "${leg_retries_json:-[]}" \
                                    --argjson pass "$cur_fix_pass" --argjson multi "$(( cur_fix_repeat > 1 ? 1 : 0 ))" \
                                    '$a + ($b | map(. + {leg: "fix"} + (if $multi == 1 then {pass: $pass} else {} end)))' 2>/dev/null)"
                                [[ -n "$cur_retries" ]] || cur_retries='[]'
                                cur_fix_exit="$leg_rc"
                                progress_write running
                                if [[ -n "$cur_fix_pass_cost" ]]; then
                                    [[ "$cur_fix_cost" != null ]] && cur_fix_cost="$(jq -n --argjson a "$cur_fix_cost" --argjson b "$cur_fix_pass_cost" '$a + $b')" || cur_fix_cost="$cur_fix_pass_cost"
                                else cur_fix_known=0; fi
                                [[ "$leg_rc" == 0 ]] || break
                            done
                            (( cur_fix_known )) || cur_fix_cost=null
                            (( cur_fix_repeat == 1 )) && cur_fix_usage="${cur_fix_pass_usage:-null}"
                            cur_after="$(clone_branch_head)"
                            if [[ "$leg_rc" != 0 ]]; then
                                cur_ended=harness-error; cur_detail="the fix leg of iteration $cur_i exited $leg_rc${leg_error:+ ($leg_error)}${leg_harness_error:+: $leg_harness_error}$(fs_leg_retry_suffix "${leg_retries_count:-0}")"
                            elif [[ -z "$cur_after" ]]; then
                                cur_ended=harness-error; cur_detail="branch $branch could not be read from the clone after the fix leg of iteration $cur_i"
                            elif [[ "$cur_after" == "$cur_before" ]]; then
                                cur_ended=no-progress
                                printf 'fork-sandbox: %s iteration %s: the fix leg committed nothing\n' "$cur_kind" "$cur_i"
                            else
                                cur_head="$cur_after"
                            fi
                        fi
                    else
                        cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i wrote a first line that is neither APPROVED nor FINDINGS"
                    fi
                fi
            fi
        else
            if [[ "$leg_rc" != 0 || ! -s "$cur_verdict_file" || -L "$cur_verdict_file" ]]; then cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i left no usable verdict"
                [[ "$leg_rc" != 0 && -n "$leg_harness_error" ]] && cur_detail+=": $leg_harness_error"
                [[ "$leg_rc" != 0 ]] && cur_detail+="$(fs_leg_retry_suffix "${leg_retries_count:-0}")"
            else
                cur_copy="$run_dir/${cur_step_idx}-$([[ "$cur_kind" == maintainer ]] && echo maintain || echo review)-verdict-${cur_i}.md"
                # See the matching comment on the legacy copy above --
                # same bound, same reason: the clone is leg-writable on a
                # composed --k8s pod, so the leg controls this file's
                # size and type too. A refused read leaves no $cur_copy,
                # so `head -n1` below reads nothing and this iteration
                # ends as harness-error, never as an approval it never
                # earned.
                fs_leg_handoff_read "$cur_verdict_file" > "$cur_copy.part" 2>/dev/null \
                    && mv -f "$cur_copy.part" "$cur_copy" \
                    || rm -f "$cur_copy.part"
                rm -f "$cur_verdict_file"
                cur_line="$(head -n1 "$cur_copy" | tr -d '\000-\037\177' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                if [[ "$cur_line" == APPROVED ]]; then cur_findings=0; cur_ended=approved
                elif [[ "$cur_line" == FINDINGS ]]; then
                    cur_findings="$(awk 'NR == 1 { next } /^## Report$/ { exit } /^[[:space:]]*$/ { if (hit) n++; hit = 0; next } /[^[:space:]:]+:[0-9]+/ { hit = 1 } END { if (hit) n++; print n + 0 }' "$cur_copy" 2>/dev/null)"
                    [[ "$cur_findings" =~ ^[0-9]+$ ]] || cur_findings=null
                    if [[ "$mode" == "review-only" ]]; then
                        # No fix leg: the verdict is the step's whole output.
                        cur_ended=findings
                    else
                    # Base name unchanged; built fresh per pass, same reason
                    # and same fs_refresh_emit_addenda call as the legacy
                    # fix/maintainer-fix block above.
                    cur_fix_base="$run_dir/${cur_step_idx}-fix-prompt-${cur_i}"; cur_fix_header_var="${cur_step_idx}fix_prompt_header"
                    cur_fix_cost=null; cur_fix_known=1
                    cur_fix_refresh_model="${cur_fix_model:-$model}"
                    cur_fix_refresh_harness="${cur_fix_harness:-$harness}"
                    # Same deferred findings-file write as the legacy fix
                    # block above: the path is fixed here, the file itself
                    # only written once a pass actually leaves a hand-off
                    # waiting (below, right after each pass's own run_leg).
                    cur_fix_findings="$cur_fix_base-findings.md"
                    for ((cur_fix_pass = 1; cur_fix_pass <= cur_fix_repeat; cur_fix_pass++)); do
                        cur_fix_leg="$cur_i"; (( cur_fix_pass > 1 )) && cur_fix_leg="$cur_i-p$cur_fix_pass"
                        cur_fix_prompt="$cur_fix_base.md"
                        (( cur_fix_pass > 1 )) && cur_fix_prompt="$cur_fix_base-p$cur_fix_pass.md"
                        { cat -- "${!cur_fix_header_var}"; fs_emit_plan_section "$plan_file" code || exit 1; \
                          printf '\n---\n\n'; \
                          awk '/^## Report$/ { exit } { print }' "$cur_copy"; \
                          fs_emit_test_record_section "$outbox_dir/$FS_TEST_LEDGER_NAME" \
                              "$(clone_branch_head)" fix; \
                          fs_refresh_emit_addenda "$run_dir"; } > "$cur_fix_prompt"
                        # Leg-start/leg-end transitions for this fix pass, same
                        # reason as the legacy fix block above.
                        progress_continuation[cur_step_no]=0
                        progress_write running
                        if [[ "$refresh_enabled" == "1" && "$cur_fix_refresh_harness" == "claude" ]]; then
                            fs_refresh_arm "$cur_fix_refresh_model"
                        else
                            fs_refresh_disarm
                        fi
                        run_leg fix "$cur_fix_leg" "$cur_fix_prompt" "$cur_step_idx"
                        # Same reason as the legacy fix block above: capture this pass's
                        # own cost before fs_refresh_chain folds its continuations into
                        # leg_cost, so fix_cost_usd does not double-count what
                        # leg_refreshes_json already records per continuation. Same for
                        # usage, which fs_refresh_chain nulls once the chain continues.
                        cur_fix_pass_cost="$leg_cost"
                        cur_fix_pass_usage="$leg_usage"
                        # Same deferred write as the legacy fix block above: only once
                        # this pass actually left a hand-off for fs_refresh_chain to read.
                        if [[ "$refresh_enabled" == "1" && "$cur_fix_refresh_harness" == "claude" \
                            && -f "$outbox_dir/handoff.md" ]]; then
                            awk '/^## Report$/ { exit } { print }' "$cur_copy" \
                                > "$cur_fix_findings.part" \
                                && mv -f "$cur_fix_findings.part" "$cur_fix_findings"
                        fi
                        fs_refresh_chain "$leg_tag" fix "$cur_fix_refresh_model" \
                            "$handoff_original" "$cur_fix_findings"
                        cur_fix_exit="$leg_rc"
                        # Same tag as the legacy fix block above: "fix" plus,
                        # when there is more than one pass, which pass, so
                        # this leg's retries never collide with the
                        # review/maintainer leg's in the same iteration
                        # record.
                        cur_retries="$(jq -cn --argjson a "$cur_retries" --argjson b "${leg_retries_json:-[]}" \
                            --argjson pass "$cur_fix_pass" --argjson multi "$(( cur_fix_repeat > 1 ? 1 : 0 ))" \
                            '$a + ($b | map(. + {leg: "fix"} + (if $multi == 1 then {pass: $pass} else {} end)))' 2>/dev/null)"
                        [[ -n "$cur_retries" ]] || cur_retries='[]'
                        progress_write running
                        if [[ -n "$cur_fix_pass_cost" ]]; then
                            [[ "$cur_fix_cost" != null ]] && cur_fix_cost="$(jq -n --argjson a "$cur_fix_cost" --argjson b "$cur_fix_pass_cost" '$a + $b')" || cur_fix_cost="$cur_fix_pass_cost"
                        else cur_fix_known=0; fi
                        [[ "$leg_rc" == 0 ]] || break
                    done
                    (( cur_fix_known )) || cur_fix_cost=null
                    (( cur_fix_repeat == 1 )) && cur_fix_usage="${cur_fix_pass_usage:-null}"
                    cur_after="$(clone_branch_head)"
                    if [[ "$leg_rc" != 0 ]]; then cur_ended=harness-error; cur_detail="the fix leg of iteration $cur_i exited $leg_rc${leg_error:+ ($leg_error)}${leg_harness_error:+: $leg_harness_error}$(fs_leg_retry_suffix "${leg_retries_count:-0}")"
                    elif [[ -z "$cur_after" ]]; then cur_ended=harness-error; cur_detail="branch $branch could not be read from the clone after the fix leg of iteration $cur_i"
                    elif [[ "$cur_after" == "$cur_before" ]]; then cur_ended=no-progress
                    else cur_head="$cur_after"; fi
                    fi
                else cur_ended=harness-error; cur_detail="the $cur_kind leg of iteration $cur_i wrote an invalid verdict"; fi
            fi
        fi
        cur_iters="$(jq -cn --argjson old "$cur_iters" --argjson cur "$(cur_iter_record)" '$old + $cur')"
        cur_save
        # Leg-end transition for this iteration. state/ended stay as they
        # are until the loop as a whole ends, below -- cur_ended may
        # already be set here (approved, findings, harness-error, ...), but
        # the contract is "done/failed/skipped once the loop is over", not
        # mid-iteration.
        progress_write running
    done
    [[ -n "$cur_ended" ]] || cur_ended=cap
    cur_save
    # This step's own final state, from the walker's own cur_ended
    # vocabulary: skipped (nothing to review, or a stop caught it before any
    # iteration ran), failed (a harness error -- see progress_any_step_failed's
    # own comment, above, for why the run's own state must track this
    # independently of $rc), or done for every other reason a loop ends
    # (approved, findings, no-progress, cap).
    case "$cur_ended" in
        skipped|stop-requested)
            progress_state[cur_step_no]="skipped"
            ;;
        harness-error)
            progress_state[cur_step_no]="failed"
            progress_any_step_failed=1
            ;;
        *)
            progress_state[cur_step_no]="done"
            ;;
    esac
    progress_ended[cur_step_no]="$cur_ended"
    progress_write running
    if [[ "$cur_legacy" == 1 ]]; then
        if [[ "$cur_kind" == maintainer ]]; then
            maintainer_loop_ended="$cur_ended"
            maintainer_loop_detail="$cur_detail"
            printf 'fork-sandbox: maintainer loop ended: %s\n' "$cur_ended"
        else
            review_loop_ended="$cur_ended"
            review_loop_detail="$cur_detail"
            printf 'fork-sandbox: review loop ended: %s\n' "$cur_ended"
        fi
    fi
    # Every leg of a review-only run (--review-only, or a read-only pipeline
    # of any shape) reports here and republishes the run's cost so far, so a
    # stop between legs keeps it.
    if [[ "$mode" == "review-only" ]]; then
        cur_ro_what="review"
        [[ "$cur_kind" == maintainer ]] && cur_ro_what="maintainer"
        cur_ro_tag="review-only"
        [[ "$cur_kind" == maintainer ]] && cur_ro_tag="review-only maintainer"
        cur_ro_file="$run_dir/$cur_ro_what-verdict-1.md"
        if [[ "$cur_legacy" != 1 ]]; then
            # A composed read-only step names itself by its number.
            cur_ro_tag="review-only step $cur_step_no ($cur_ro_what)"
            cur_ro_file="$run_dir/${cur_step_idx}-${cur_ro_what/maintainer/maintain}-verdict-1.md"
        fi
        case "$cur_ended" in
            approved) printf 'fork-sandbox: %s: APPROVED\n' "$cur_ro_tag" ;;
            findings) printf 'fork-sandbox: %s: FINDINGS (%s cited)\n' "$cur_ro_tag" "$cur_findings" ;;
        esac
        printf 'fork-sandbox: %s verdict: %s\n' "$cur_ro_what" "$cur_ro_file"
        [[ -n "${run_error:-}" ]] || run_error="${leg_error:-$leg_harness_error}"
        [[ "$cur_ended" == "harness-error" ]] && rc=1
        if (( run_step_count == 1 )); then
            run_cost="$leg_cost"
            run_usage="$leg_usage"
        else
            # No leg run means no cost known, not a cost of zero.
            run_cost=""
            (( ${legs_run:-0} > 0 )) && [[ "$loop_cost_unknown" != 1 ]] \
                && run_cost="$loop_cost_sum"
            run_usage=null
        fi
        if [[ "$run_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
            run_cost_fmt="$(printf '%.6f' "$run_cost")"
        else
            run_cost_fmt=""
        fi
    fi
done

# The tidy-history leg: when this run's last pipeline step is a maintain
# step and it just approved, one more leg rewrites the branch's commits
# into logical ones -- see "The tidy leg" in this script's own header
# comment for the full contract (eligibility, the three invariants
# enforced below, and the restore on discard). It runs here, after every
# other leg but before $rc is published and before run_cleanup revokes
# this run's credential, and it never changes $rc itself: accepted,
# unchanged, discarded and skipped are all still a successful run of
# whatever the maintainer approved.
tidy_ended="skipped"
tidy_detail="no maintain step"
tidy_approved_sha=""
tidy_head_after=""
tidy_restore=0
tidy_exit_json=null
tidy_cost_json=null
tidy_usage_json=null
tidy_retries_json='[]'
clone_restored_json=null

# run_id (this run's own holding refs live under it, never under the
# branch name) was resolved near the top of this file, before the
# stale-tidy-state startup guard.

tidy_step_idx="${run_step_idx[run_step_count]:-}"
# Whether the pipeline has a maintain step ANYWHERE, not just last -- read
# by the summary below to decide whether this run prints a tidy: line at
# all (A run with no maintain step reads exactly as it did before this
# feature existed; a run whose maintain step is not last still gets a
# line, since it does have one, just not in the one position that runs a
# tidy leg).
tidy_has_maintain_step=0
for (( _tk = 1; _tk <= run_step_count; _tk++ )); do
    [[ "${run_step_kind[_tk]}" == "maintainer" ]] && tidy_has_maintain_step=1
done
tidy_eligible=0
if [[ "${stop_requested:-0}" == 1 ]]; then
    tidy_detail="stop requested"
elif [[ "$mode" == "review-only" ]]; then
    tidy_detail="read-only run"
elif (( ! fetch_back )); then
    # A --k8s pod run: the tidy-history leg's verification and publish are
    # host-side only (fs_tidy_verify/fs_tidy_publish run against
    # origin_repo, which is a host path a pod cannot reach), and this
    # runner's own fetch-back is skipped in pod mode in the first place --
    # see the seam comments above. Recorded as skipped, same as every
    # other ineligible reason, never refused by name: a composed preset
    # ending in an approving maintain step is exactly the goal shape for
    # --k8s, and refusing it here would make that shape unrunnable there.
    tidy_detail="a --k8s pod run does not fetch back; the tidy-history leg's verification and publish are host-side only"
elif (( run_step_count == 0 )) || [[ "${run_step_kind[run_step_count]:-}" != "maintainer" ]]; then
    if (( tidy_has_maintain_step )); then
        tidy_detail="the maintain step is not the pipeline's last step"
    else
        tidy_detail="no maintain step"
    fi
elif [[ "${progress_ended[run_step_count]:-}" != "approved" ]]; then
    tidy_detail="the maintainer did not approve (${progress_ended[run_step_count]:-unknown})"
else
    tidy_eligible=1
fi

if (( tidy_eligible )); then
    # The approved head is snapshotted into a holding ref in the ORIGIN
    # repo before this leg runs, host-side -- the one safe way across the
    # sandbox boundary (see the fetch-back comment below for why nothing
    # here ever runs git inside the clone). Everything this leg's
    # verification reads is read from these refs, never from the clone
    # directly. tidy_approved_sha is re-resolved from the ref actually
    # fetched, below, not trusted from this ls-remote: the two are separate
    # round trips to the clone, and only the ref's own sha is what every
    # later check (fs_tidy_verify, the publish at the end of this run) is
    # actually pinned to.
    if [[ -n "$(clone_branch_head)" ]] \
        && (cd "$origin_repo" && git fetch --quiet "$clone_dir" \
            "+refs/heads/$branch:refs/fork-sandbox/tidy/$run_id/approved"); then
        tidy_approved_sha="$(cd "$origin_repo" && git rev-parse --verify -q \
            "refs/fork-sandbox/tidy/$run_id/approved" 2>/dev/null)"
    fi
    if [[ -z "$tidy_approved_sha" ]]; then
        tidy_ended="skipped"
        tidy_detail="could not snapshot the approved history"
    else
        if [[ -n "$tidy_step_idx" ]]; then
            tidy_static_prompt_var="${tidy_step_idx}_tidy_prompt"
            tidy_static_prompt="${!tidy_static_prompt_var}"
            tidy_runtime_prompt="$run_dir/step-${run_step_count}-tidy-prompt-1.md"
        else
            tidy_static_prompt="$tidy_prompt"
            tidy_runtime_prompt="$run_dir/tidy-prompt-1.md"
        fi
        if { cat -- "$tidy_static_prompt"
             printf '\n## The approved head\n\n'
             printf 'The approved head -- what your rewrite is checked against once you\n'
             printf 'finish -- is:\n\n    %s\n\n' "$tidy_approved_sha"
             printf 'The base this range starts from is:\n\n    %s\n' "$base_sha"
             fs_emit_plan_section "$plan_file" tidy
           } > "$tidy_runtime_prompt.part" 2>/dev/null; then
            mv -- "$tidy_runtime_prompt.part" "$tidy_runtime_prompt"
            # A tidy leg never refreshes -- like plan/review/maintain, it is
            # not the long-running leg --refresh-at exists for.
            fs_refresh_disarm
            run_leg tidy 1 "$tidy_runtime_prompt" "$tidy_step_idx"
            tidy_exit_json="$leg_rc"
            tidy_cost_json="${leg_cost:-null}"
            tidy_usage_json="${leg_usage:-null}"
            tidy_retries_json="${leg_retries_json:-[]}"
            tidy_head_after="$(clone_branch_head)"
            if [[ "$leg_rc" != 0 ]]; then
                tidy_ended="discarded"
                if [[ "$leg_rc" == 124 ]]; then
                    # The GNU timeout wrap above (never the harness itself,
                    # which this leg's own cmd never ran without it) -- a
                    # hung leg is a discard, same as any other tidy
                    # failure, not left to hold the approved branch back.
                    tidy_detail="the tidy leg timed out after ${tidy_timeout_secs}s; the approved history was restored"
                else
                    tidy_detail="the tidy leg exited $leg_rc${leg_error:+ ($leg_error)}${leg_harness_error:+: $leg_harness_error}$(fs_leg_retry_suffix "${leg_retries_count:-0}"); the approved history was restored"
                fi
                tidy_restore=1
            elif [[ -z "$tidy_head_after" ]]; then
                tidy_ended="discarded"
                tidy_detail="branch $branch could not be read from the clone after the tidy leg; the approved history was restored"
                tidy_restore=1
            elif [[ "$tidy_head_after" == "$tidy_approved_sha" ]]; then
                tidy_ended="unchanged"
                tidy_detail=""
            elif ! (cd "$origin_repo" && git fetch --quiet "$clone_dir" \
                "+refs/heads/$branch:refs/fork-sandbox/tidy/$run_id/candidate"); then
                tidy_ended="discarded"
                tidy_detail="the tidied branch could not be fetched; the approved history was restored"
                tidy_restore=1
            else
                # Re-resolve from the candidate ref just fetched, not the
                # earlier clone_branch_head() read above: that read and this
                # fetch are two separate trips to the clone, and if its
                # branch moved between them, head_after must still name
                # exactly what fs_tidy_verify is about to check below --
                # never an earlier, unverified commit -- since tidy.json's
                # head_after is what fork-sandbox-stop.sh's salvage path
                # trusts for an "accepted" outcome (see its
                # resolve_tidy_safe_sha).
                tidy_head_after="$(cd "$origin_repo" && git rev-parse --verify -q \
                    "refs/fork-sandbox/tidy/$run_id/candidate" 2>/dev/null)"
                tidy_verify_reason="$(fs_tidy_verify "$origin_repo" "$base_sha" \
                    "refs/fork-sandbox/tidy/$run_id/approved" \
                    "refs/fork-sandbox/tidy/$run_id/candidate")"
                tidy_verify_rc=$?
                if (( tidy_verify_rc == 0 )); then
                    tidy_ended="accepted"
                    tidy_detail=""
                else
                    tidy_ended="discarded"
                    tidy_detail="$tidy_verify_reason; the approved history was restored"
                    tidy_restore=1
                fi
            fi
        else
            rm -f -- "$tidy_runtime_prompt.part"
            tidy_ended="skipped"
            tidy_detail="could not build the tidy leg's prompt"
        fi
    fi
fi

# On a discard, the clone is reset back to the approved head, best-effort,
# through the sandbox backend -- the same confinement every other git
# command against the clone runs under in this runner (nothing runs git
# INSIDE the clone directly: the sandbox could write its config, and a key
# such as core.fsmonitor runs on the HOST). Whether it worked is read back
# with clone_branch_head and recorded, not assumed: a --clone-dir reuse
# continues from whatever the clone actually ends up holding.
if [[ "$tidy_restore" == 1 ]]; then
    tidy_restore_bind_flags=()
    if [[ "${#fs_alternates[@]}" -gt 0 ]]; then
        for tidy_alt in "${fs_alternates[@]}"; do
            tidy_restore_bind_flags+=(--bind-ro "$tidy_alt")
        done
    fi
    if fs_resolve_backend "$script_dir"; then
        "$FS_TIMEOUT" 60 "$FS_BACKEND_BIN" --workdir "$clone_dir" \
            "${tidy_restore_bind_flags[@]}" --net sealed \
            --hostname fork-sandbox-tidy-restore -- \
            sh -c 'git rebase --abort >/dev/null 2>&1
git checkout -q -f "$1" && git reset -q --hard "$2"' \
            sh "$branch" "$tidy_approved_sha" \
            > "$run_dir/tidy-restore.log" 2>&1
    else
        printf 'fork-sandbox: could not resolve the sandbox backend for the ' \
            > "$run_dir/tidy-restore.log"
        printf 'tidy restore.\n' >> "$run_dir/tidy-restore.log"
    fi
    if [[ "$(clone_branch_head)" == "$tidy_approved_sha" ]]; then
        clone_restored_json=true
    else
        clone_restored_json=false
    fi
fi

# Both the artifact and this line are written only when the pipeline has a
# maintain step at all -- same gate as the summary.txt line below -- so a
# pipeline with none (the common case before this feature existed) leaves
# no tidy trace anywhere in a run's output or artifacts, not even a
# "skipped" one.
if (( tidy_has_maintain_step )); then
    jq -n \
        --arg ended "$tidy_ended" --arg detail "$tidy_detail" \
        --arg head_approved "$tidy_approved_sha" --arg head_after "$tidy_head_after" \
        --argjson exit "$tidy_exit_json" --argjson cost_usd "$tidy_cost_json" \
        --argjson usage "$tidy_usage_json" --argjson retries "$tidy_retries_json" \
        --argjson clone_restored "$clone_restored_json" \
        '{ended: $ended,
          detail: (if $detail == "" then null else $detail end),
          head_approved: (if $head_approved == "" then null else $head_approved end),
          head_after: (if $head_after == "" then null else $head_after end),
          exit: $exit, cost_usd: $cost_usd, usage: $usage, retries: $retries,
          clone_restored: $clone_restored}' \
        > "$run_dir/tidy.json.part" 2>/dev/null \
        && mv -f "$run_dir/tidy.json.part" "$run_dir/tidy.json"
    printf 'fork-sandbox: tidy: %s%s\n' "$tidy_ended" "${tidy_detail:+ ($tidy_detail)}"
fi

# The other half of the deferral above: for a --review-loop or --refresh-at
# run the run is over here -- every loop ran, or was skipped and said why --
# so this is where its exit code is published, which is what puts a
# watcher's terminal event after the last leg rather than in the middle of
# either loop. The pi check above may have written the same value already;
# writing it again costs nothing and keeps this the one place that ends a
# loop run.
printf '%s\n' "$rc" > "$run_dir/exit-code"

# progress.json's own final write. This is the one place every run reaches,
# whatever shape it was -- a plain single-code run whose exit-code write
# above is early and this one merely repeats, a review/maintainer loop, a
# read-only pipeline, or a stop -- so it is where any step this runner's own
# steps above never got to finalize is swept to a terminal state: "pending"
# means the outer walker loop above never reached it at all (only
# stop_requested can do that -- see its own gate on that loop), and
# "running" means a step was the active one when a stop's TERM killed its
# leg out from under it (harness-error and every other ending finalize
# their own step inline, above, so a step already "done"/"failed"/"skipped"
# here is untouched). Either way that step becomes "skipped" ("stop
# requested" is a known reason to record) unless the run is failing for a
# reason that has nothing to do with a stop, in which case the step that was
# actually running becomes "failed" instead, so the one step that was in
# flight when things went wrong is not reported as having never run.
for (( _pg_k = 1; _pg_k <= run_step_count; _pg_k++ )); do
    case "${progress_state[_pg_k]}" in
        pending|running)
            if [[ "${stop_requested:-0}" == 1 ]]; then
                progress_state[_pg_k]="skipped"
                progress_ended[_pg_k]="stop-requested"
            elif [[ "$rc" != "0" ]] || (( progress_any_step_failed )); then
                progress_state[_pg_k]="failed"
                progress_any_step_failed=1
            else
                progress_state[_pg_k]="skipped"
                progress_ended[_pg_k]="skipped"
            fi
            ;;
    esac
done
progress_final_state="done"
if [[ "${stop_requested:-0}" == 1 ]]; then
    progress_final_state="stopped"
elif [[ "$rc" != "0" ]] || (( progress_any_step_failed )); then
    progress_final_state="failed"
fi
progress_write "$progress_final_state"

# Absent (empty here becomes an absent key below) unless a stop request
# actually reached one of the loop checks above -- "stopped" is the only
# value this runner ever writes itself; fork-sandbox-stop.sh's own timeout
# and salvage paths write "stop-timeout"/"salvaged" host-side, after this
# process is gone or unreachable.
end_reason=""
[[ "${stop_requested:-0}" == 1 ]] && end_reason="stopped"

# The session and every loop leg are done with the credential and the
# services. Clean both up now rather than lean on the trap, which a
# --keep-session run never reaches: that path ends in exec. run_cleanup runs
# its body once, so the EXIT trap is a no-op after this.
run_cleanup

printf '\n'
if [[ "$rc" != "0" ]]; then
    printf 'fork-sandbox: the session exited %s\n' "$rc"
fi

# Does the clone still hold uncommitted work -- modified, staged, or
# untracked-and-not-ignored files the session never committed? Checked
# INSIDE the sandbox, under the same confinement the harness itself ran
# under, for the same reason nothing below runs git against the clone on
# the HOST: the clone's .git/config is writable by the sandbox, and a key
# such as core.fsmonitor runs on the HOST the next time anything there
# executes git. A composed (--run-dir) pod takes this further still: the
# "sandbox" there is a SEPARATE container (see the leg-split branch
# below), not merely a confined process in this one, because a leg's own
# hooks/filters are not fully disable-able by any `-c` switch (confirmed
# by experiment) -- the fix is to make it not matter where they run, not
# to keep chasing which switch suppresses them. Most of
# what fork-sandbox itself writes into the clone
# lives under .git (fs_lock_clone_dir's own comment says why), never the
# working tree. The one working-tree exception, a services hook's
# <clone-dir>/.env.sandbox (docs/sandbox-services.md), is listed in
# .git/info/exclude by fs_make_clone, so git status --porcelain treats it
# like any other ignored file and this still reflects the session's own
# files only. git status --porcelain's own untrusted stdout goes straight
# to a file; nothing here parses it as anything but text, and nothing
# re-runs git on it.
# Best-effort: a backend that fails to even run this -- as opposed to
# running it and finding nothing -- leaves the fact unknown rather than
# guessed at zero (see uncommitted_files below). The timeout is short
# because it runs before the fetch, and a hung check must not hold that up.
#
# Resolved fresh here rather than carried from the launcher: this runner
# starts in tmux's own environment (see FORK_SANDBOX_BACKEND's own comment
# above, where claude-sandboxed resolves it again for the same reason), so
# a value baked in at generation time could name a different backend than
# the one actually on PATH when this process runs.
#
# The clone itself is bound by --workdir, but a --shared clone
# (fs_make_clone) carries no objects of its own: it reads its history
# through .git/objects/info/alternates, pointing at the origin's (and, for
# a --shared origin, on down the chain). Without those stores bound too,
# git sees the refs but not the objects behind them -- "bad object HEAD" --
# so every ordinary run would report the check as failed rather than
# clean. fs_alternates is fs_collect_alternates's own answer for this
# clone, frozen into run.sh at generation time (see its own comment there).
uncommitted_bind_flags=()
if [[ "${#fs_alternates[@]}" -gt 0 ]]; then
    for uncommitted_alt in "${fs_alternates[@]}"; do
        uncommitted_bind_flags+=(--bind-ro "$uncommitted_alt")
    done
fi
if [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]]; then
    # Composed (--run-dir) pod: relayed to the LEG container over the same
    # request/response protocol every other leg uses (fs_run_leg_split),
    # never run directly in this (agent) container. The clone is
    # read-write in both containers, so a leg can plant a
    # .git/hooks/post-index-change hook, or a filter.<x>.clean
    # entry plus a matching .gitattributes line, either of which fires on a
    # plain `git status` with nothing uncommitted -- no `-c` switch turns
    # off an attribute-driven filter, so core.fsmonitor=/core.hooksPath=
    # cannot close this on their own. Running the check here instead of
    # disabling what it might trigger: whatever a leg-planted hook or
    # filter does, it does it in the leg container, which holds no
    # run-directory write access and is swept (fork-sandbox-k8s-
    # leg-loop.sh's own sweep) before this call's response is trusted. Its
    # stdout is read back the same untrusted way any other leg's output
    # already is -- bounded in size and time, refused outright if it is
    # not a plain regular file, never parsed as anything but text -- see
    # fs_leg_handoff_read.
    fs_run_leg_split git -C "$clone_dir" status --porcelain --untracked-files=all < /dev/null > "$run_dir/git-status.txt" 2> "$run_dir/git-status.log"  # relayed to the leg container, never executed here
    uncommitted_status_rc=$?
elif (( runner_in_sandbox )); then
    # runner_in_sandbox, no leg split: the legacy single-container pod
    # shape (no --run-dir), which never gained the agent/leg split above --
    # see "The legacy cluster review loop" in docs/kubernetes-runs.md. This
    # runner is already running unconfined relative to the clone (a pod leg
    # ran with no bwrap layer between it and the clone in the first place,
    # see the pod leg wrapper, fork-sandbox-k8s-leg.sh), so there is no
    # separate sandbox backend to ask, and no second container to relay to
    # either: the harness and this check share the one container that
    # shape has. -c core.fsmonitor= still
    # disables a leg-planted fsmonitor hook on the command line, which
    # outranks the clone's own config -- this is the known, accepted
    # advisory-only posture that shape keeps; the uncommitted-test.sh pin
    # that forbids a host-side git command against the clone excludes this
    # one line by the trailing marker comment below.
    "$FS_TIMEOUT" 20 git -c core.fsmonitor= -C "$clone_dir" status --porcelain --untracked-files=all > "$run_dir/git-status.txt" 2> "$run_dir/git-status.log"  # the one allowed exception
    uncommitted_status_rc=$?
elif fs_resolve_backend "$script_dir"; then
    "$FS_TIMEOUT" 20 "$FS_BACKEND_BIN" --workdir "$clone_dir" \
        "${uncommitted_bind_flags[@]}" --net sealed \
        --hostname fork-sandbox-status -- git status --porcelain \
        --untracked-files=all \
        > "$run_dir/git-status.txt" 2> "$run_dir/git-status.log"
    uncommitted_status_rc=$?
else
    : > "$run_dir/git-status.txt"
    printf 'fork-sandbox: could not resolve the sandbox backend for the ' \
        > "$run_dir/git-status.log"
    printf 'uncommitted-work check.\n' >> "$run_dir/git-status.log"
    uncommitted_status_rc=1
fi
uncommitted_files=""
uncommitted_paths=()
if (( uncommitted_status_rc == 0 )); then
    while IFS= read -r uncommitted_line; do
        [[ -n "$uncommitted_line" ]] || continue
        uncommitted_paths+=("$uncommitted_line")
    done < <(tr -d '\000-\010\013-\037\177' < "$run_dir/git-status.txt")
    uncommitted_files="${#uncommitted_paths[@]}"
fi
uncommitted_paths_capped=("${uncommitted_paths[@]:0:20}")

# A pod's emptyDir goes away with the pod, so a leg that is killed or
# crashes mid-edit, leaving uncommitted work, has no backstop once this
# runner exits -- unlike a local run, whose clone sits on the operator's
# own disk regardless. Local behaviour (check and report, never commit --
# the uncommitted_files*/summary.txt fields above and below) stays the
# rule even here: this still never runs git commit. Instead, the
# leftover work is saved as a patch file collect brings back as an
# allowlisted artifact, so it is recoverable from the host afterward.
# runner_in_sandbox-gated, same as the status check above: only a pod
# leg's emptyDir is ever at risk of disappearing with nothing read it.
if (( runner_in_sandbox )) && (( uncommitted_status_rc == 0 )) && (( uncommitted_files > 0 )); then
    # `add -A`, not `-N`: intent-to-add alone would leave a new file's
    # own content out of `diff --cached`. `--binary` makes the patch
    # safe for a binary file, the same guarantee a plain `git diff`
    # does not have. The index is reset right after, so this leaves no
    # trace in the clone's own state for anything later in this same
    # run that might read it.
    if [[ -n "${FORK_SANDBOX_LEG_HANDOFF_DIR:-}" ]]; then
        # Composed pod: same relay as the status check above, same reason
        # -- see its comment. core.fsmonitor=/--no-ext-diff are omitted
        # here on purpose, not merely dropped: this runs in the leg
        # container, where a leg-planted hook or filter firing changes
        # nothing it did not already have the run of, so disabling them
        # would protect nothing.
        fs_run_leg_split bash -c '
            git -C "$1" add -A
            git -C "$1" diff --cached --binary --no-ext-diff
            git -C "$1" reset --quiet
        ' _ "$clone_dir" < /dev/null > "$run_dir/uncommitted.patch" 2>> "$run_dir/git-status.log"  # relayed to the leg container, never executed here
    else
        # runner_in_sandbox, no leg split: same legacy, advisory-only
        # posture as the status check's own "no leg split" branch above.
        git -c core.fsmonitor= -C "$clone_dir" add -A  # the one allowed exception
        "$FS_TIMEOUT" 20 git -c core.fsmonitor= -C "$clone_dir" diff --cached --binary --no-ext-diff > "$run_dir/uncommitted.patch" 2>> "$run_dir/git-status.log"  # the one allowed exception
        git -c core.fsmonitor= -C "$clone_dir" reset --quiet  # the one allowed exception
    fi
    [[ -s "$run_dir/uncommitted.patch" ]] || rm -f "$run_dir/uncommitted.patch"
fi

# Bring the work back. Fetching is the one way into the real repo that cannot
# be turned into code execution by the clone's config, so the work crosses
# back as objects and nothing else. Nothing below runs git inside the clone:
# the sandbox could write its config, and a key such as core.fsmonitor runs
# on the HOST. Every git command here runs in the origin repo, which is the
# user's own.
#
# fetch_back=0 (a --k8s pod run) skips this crossing entirely: the pod's own
# run.sh has no origin repo of the user's to fetch into -- the k8s client
# does that transfer itself, separately, once this runner has exited (see
# docs/kubernetes-runs.md). branch_repo is where the branch's commit
# history can actually be read from for the rest of this section: the
# origin repo once the fetch below lands it there, or the clone directly
# when there was never going to be a fetch.
fetched=0
# Named only when a create-only publish below loses its collision -- the
# approved or candidate holding ref that still names the history this run
# actually produced, for the cleanup block and the summary further down to
# point at instead of either deleting it or claiming "the work is in the
# clone only" (that clone-only framing is actively wrong for a discard,
# where the clone may hold the REJECTED rewrite, not this run's approved
# work). Declared here, unconditionally, so a fetch_back=0 run (which never
# enters the tidy arms below, since tidy is never eligible there -- see the
# tidy gate above) still has them defined under `set -u`.
tidy_kept_ref=""
tidy_kept_sha=""
if (( fetch_back )); then
    if [[ "$tidy_restore" == 1 ]]; then
        # The tidy leg was discarded: the clone was reset best-effort above, but
        # the origin branch comes from the approved-head holding ref, never from
        # the clone -- if the sandboxed reset above failed, an unchanged fetch
        # here would otherwise bring the REJECTED history home instead. The
        # object is already in $origin_repo (fetched into that ref before the
        # tidy leg ran), so fs_tidy_publish is a ref update, not a fetch, and
        # create-only: the same refusal the plain fetch below gives a branch
        # that sprang up in the origin while the run was in flight
        # (fs_check_branch_free only proved it free at launch) -- except a
        # branch already sitting at exactly this sha (fork-sandbox-stop.sh
        # published it first) counts as success, not a collision.
        if fs_tidy_publish "$origin_repo" "$branch" "$tidy_approved_sha"; then
            fetched=1
        else
            tidy_kept_ref="refs/fork-sandbox/tidy/$run_id/approved"
            tidy_kept_sha="$tidy_approved_sha"
        fi
    elif [[ "$tidy_ended" == "accepted" ]]; then
        # Publish exactly what fs_tidy_verify checked, not a fresh read of the
        # clone's branch: re-fetching here would re-open the gap between
        # verification and publication that the holding ref exists to close.
        # Create-only for the same reason as the tidy_restore case above.
        tidy_candidate_sha="$(cd "$origin_repo" && git rev-parse --verify -q \
            "refs/fork-sandbox/tidy/$run_id/candidate" 2>/dev/null)"
        if [[ -n "$tidy_candidate_sha" ]] \
            && fs_tidy_publish "$origin_repo" "$branch" "$tidy_candidate_sha"; then
            fetched=1
        else
            tidy_kept_ref="refs/fork-sandbox/tidy/$run_id/candidate"
            tidy_kept_sha="$tidy_candidate_sha"
        fi
    elif [[ "$tidy_ended" == "unchanged" ]]; then
        # Nothing changed, so the already-fetched approved head is what gets
        # published -- again, no new read of the clone's branch. Create-only
        # for the same reason as the tidy_restore case above.
        if fs_tidy_publish "$origin_repo" "$branch" "$tidy_approved_sha"; then
            fetched=1
        else
            tidy_kept_ref="refs/fork-sandbox/tidy/$run_id/approved"
            tidy_kept_sha="$tidy_approved_sha"
        fi
    elif (cd "$origin_repo" && git fetch --quiet "$clone_dir" "$branch:$branch"); then
        fetched=1
    fi
    branch_repo="$origin_repo"
else
    branch_repo="$clone_dir"
fi

# True whenever branch_repo actually holds the branch's history: either the
# fetch above landed it in origin_repo, or fetch_back=0 means branch_repo
# is clone_dir itself, which always holds whatever the branch currently is.
stats_ready=0
(( fetched )) && stats_ready=1
(( fetch_back )) || stats_ready=1

n_commits=0
removed=0
if (( stats_ready )); then
    n_commits="$( (cd "$branch_repo" && git rev-list --count "$return_base_sha..$branch") 2>/dev/null || printf 0 )"
fi
if (( fetched )) && [[ "$n_commits" == "0" ]]; then
    # The branch is exactly where it started, so removing it leaves the
    # repo as it was. Compare the sha rather than trust the count. Never
    # reached when fetch_back=0: fetched stays 0, so there is no branch in
    # origin_repo to remove in the first place.
    head_now="$( (cd "$origin_repo" && git rev-parse "$branch") 2>/dev/null || true )"
    if [[ "$head_now" == "$return_base_sha" ]] \
        && (cd "$origin_repo" && git branch -q -D "$branch") >/dev/null 2>&1; then
        removed=1
    fi
fi

# The upstream is a convenience for `git status`/`git branch -vv`, applied
# only after a fetch actually landed the branch -- fs_apply_upstream's own
# check covers the 0-commit path above deleting it again. Also never
# reached when fetch_back=0: an upstream only means anything in the user's
# own origin repo.
upstream_line=""
if (( fetched )); then
    upstream_line="$(fs_apply_upstream "$origin_repo" "$branch" "$upstream" "$upstream_reason")"
fi

# A plain (non-tidy) fetch that did not land -- most commonly a
# non-fast-forward, from a branch moved or re-pointed in $origin_repo while
# this run was in flight -- fails the run: its work is reachable only in the
# clone. The tidy_kept_ref cases above are excluded: a tidy discard/collision
# has its own "kept at this holding ref" reporting (fs_tidy_publish is
# create-only by design) and stays "fetched: false, exit 0". Only overridden
# when rc is still 0: a run that already failed keeps its own failure.
if (( fetch_back )) && (( ! fetched )) && [[ -z "$tidy_kept_ref" ]] && (( rc == 0 )); then
    rc=1
    # exit-code was already written above, before this fetch ever ran (see
    # that write's own comment) -- overwritten here too, so a reader of the
    # file (fork-sandbox-status.sh's run_state, polling right now) and a
    # reader of summary.json's exit_code (written later, from this same
    # $rc) agree, instead of the file alone still claiming success.
    printf '%s\n' "$rc" > "$run_dir/exit-code"
fi

# The two holding refs the tidy block above may have used to snapshot the
# approved and candidate heads host-side are cleaned up now -- but ONLY
# once the branch they protect actually reached the origin (fetched=1):
# $tidy_kept_ref above means the publish lost a collision, and deleting
# its ref here would leave the approved history this run actually
# produced unreachable from anything, with no way back short of the
# object falling out of the ODB on a future gc. A repeat run (a
# --clone-dir reuse, say) finding a stale ref from an earlier SUCCESSFUL
# publish is the only case this cleanup exists to prevent, and that case
# always has fetched=1.
if (( fetched )); then
    (cd "$origin_repo" && git update-ref -d "refs/fork-sandbox/tidy/$run_id/approved") 2>/dev/null || true
    (cd "$origin_repo" && git update-ref -d "refs/fork-sandbox/tidy/$run_id/candidate") 2>/dev/null || true
fi

# Now that branch_repo holds the objects (the origin repo once fetched
# back, or the clone directly when fetch_back=0), each loop iteration's
# commits_added can be counted. It could not be taken while the loop ran:
# counting needs the commits locally, and nothing may run git in the clone
# on the host to count them there. A run killed mid-loop keeps its
# iterations and leaves this field null, which is the same "not
# established" the rest of the record uses.
if (( stats_ready )) && [[ -s "$run_dir/review-loop.json" ]]; then
    loop_counts=""
    while IFS="$(printf '\t')" read -r hb ha; do
        c=null
        if [[ -n "$hb" && -n "$ha" ]]; then
            c="$( (cd "$branch_repo" && git rev-list --count "$hb..$ha") 2>/dev/null || printf null )"
            [[ "$c" =~ ^[0-9]+$ ]] || c=null
        fi
        loop_counts+="$c"$'\n'
    done < <(jq -r '.iterations[]? | [(.head_before // ""), (.head_after // "")] | @tsv' \
                "$run_dir/review-loop.json" 2>/dev/null)
    loop_counts_json="$(printf '%s' "$loop_counts" | jq -R -s -c \
        'split("\n") | map(select(length > 0) | fromjson)' 2>/dev/null)"
    if [[ -n "$loop_counts_json" ]] \
        && jq --argjson c "$loop_counts_json" \
            '.iterations |= [range(0; length) as $i | .[$i] + {commits_added: $c[$i]}]' \
            "$run_dir/review-loop.json" > "$run_dir/review-loop.json.part" 2>/dev/null; then
        mv -f "$run_dir/review-loop.json.part" "$run_dir/review-loop.json"
    else
        rm -f "$run_dir/review-loop.json.part"
    fi
fi

# The same backfill for the maintainer loop's record: the same rule, the same
# reason, applied to maintainer-loop.json.
if (( stats_ready )) && [[ -s "$run_dir/maintainer-loop.json" ]]; then
    mnt_counts=""
    while IFS="$(printf '\t')" read -r hb ha; do
        c=null
        if [[ -n "$hb" && -n "$ha" ]]; then
            c="$( (cd "$branch_repo" && git rev-list --count "$hb..$ha") 2>/dev/null || printf null )"
            [[ "$c" =~ ^[0-9]+$ ]] || c=null
        fi
        mnt_counts+="$c"$'\n'
    done < <(jq -r '.iterations[]? | [(.head_before // ""), (.head_after // "")] | @tsv' \
                "$run_dir/maintainer-loop.json" 2>/dev/null)
    mnt_counts_json="$(printf '%s' "$mnt_counts" | jq -R -s -c \
        'split("\n") | map(select(length > 0) | fromjson)' 2>/dev/null)"
    if [[ -n "$mnt_counts_json" ]] \
        && jq --argjson c "$mnt_counts_json" \
            '.iterations |= [range(0; length) as $i | .[$i] + {commits_added: $c[$i]}]' \
            "$run_dir/maintainer-loop.json" > "$run_dir/maintainer-loop.json.part" 2>/dev/null; then
        mv -f "$run_dir/maintainer-loop.json.part" "$run_dir/maintainer-loop.json"
    else
        rm -f "$run_dir/maintainer-loop.json.part"
    fi
fi

# Composed records use the review-loop shape too, so give them the same
# post-fetch commit-count backfill as the fixed review and maintainer tiers.
if (( stats_ready )) && [[ "${composed_pipeline:-0}" == 1 ]]; then
    for composed_loop in "$run_dir"/step-[0-9]*-loop.json; do
        [[ -s "$composed_loop" ]] || continue
        composed_counts=""
        while IFS="$(printf '\t')" read -r hb ha; do
            c=null
            if [[ -n "$hb" && -n "$ha" ]]; then
                c="$( (cd "$branch_repo" && git rev-list --count "$hb..$ha") 2>/dev/null || printf null )"
                [[ "$c" =~ ^[0-9]+$ ]] || c=null
            fi
            composed_counts+="$c"$'\n'
        done < <(jq -r '.iterations[]? | [(.head_before // ""), (.head_after // "")] | @tsv' "$composed_loop" 2>/dev/null)
        composed_counts_json="$(printf '%s' "$composed_counts" | jq -R -s -c 'split("\n") | map(select(length > 0) | fromjson)' 2>/dev/null)"
        if [[ -n "$composed_counts_json" ]] && jq --argjson c "$composed_counts_json" \
            '.iterations |= [range(0; length) as $i | .[$i] + {commits_added: $c[$i]}]' \
            "$composed_loop" > "$composed_loop.part" 2>/dev/null; then
            mv -f "$composed_loop.part" "$composed_loop"
        else
            rm -f "$composed_loop.part"
        fi
    done
fi

# What the whole run cost: the implement leg plus every loop leg. A sum is
# only honest when every part is a number, so one leg the harness priced
# nowhere -- codex prices none of them -- leaves the total null rather than
# low. cost_usd keeps meaning the implement leg alone. A pipeline whose
# step 1 is not code has no implement leg: every leg it ran went through
# run_leg, so loop_cost_sum alone is the total.
total_cost_fmt=""
total_cost_impl=""
if [[ "$fs_impl_leg_ran_at_step1" == 1 ]]; then
    total_cost_impl="$run_cost_fmt"
elif (( ${legs_run:-0} > 0 )); then
    total_cost_impl=0
fi
if [[ "$mode" == "review-only" ]]; then
    total_cost_fmt="$run_cost_fmt"
elif [[ -n "$total_cost_impl" && "$loop_cost_unknown" != "1" ]]; then
    total_cost_raw="$(jq -n --argjson a "$total_cost_impl" --argjson b "$loop_cost_sum" \
        '(($a + $b) * 1000000 | round) / 1000000' 2>/dev/null)"
    if [[ "$total_cost_raw" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        total_cost_fmt="$(printf '%.6f' "$total_cost_raw")"
    fi
fi

report_from="session"
latest_report_verdict=""
latest_report_n=""
for report_verdict in "$run_dir"/review-verdict-*.md; do
    [[ -f "$report_verdict" ]] || continue
    report_n="${report_verdict##*/review-verdict-}"
    report_n="${report_n%.md}"
    [[ "$report_n" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$latest_report_n" || "$report_n" -gt "$latest_report_n" ]]; then
        latest_report_n="$report_n"
        latest_report_verdict="$report_verdict"
    fi
done
if [[ -n "$latest_report_verdict" ]] \
    && fs_verdict_has_usable_report "$latest_report_verdict"; then
    report_from="review"
fi
# The maintainer's verdict outranks the review's: it read the branch after
# the review loop ended, including everything the review's fix legs
# committed, so when it has a usable report that is the account a reader
# wants in place of the session's.
latest_maintainer_report_verdict=""
latest_maintainer_report_n=""
for report_verdict in "$run_dir"/maintainer-verdict-*.md; do
    [[ -f "$report_verdict" ]] || continue
    report_n="${report_verdict##*/maintainer-verdict-}"
    report_n="${report_n%.md}"
    [[ "$report_n" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$latest_maintainer_report_n" || "$report_n" -gt "$latest_maintainer_report_n" ]]; then
        latest_maintainer_report_n="$report_n"
        latest_maintainer_report_verdict="$report_verdict"
    fi
done
if [[ -n "$latest_maintainer_report_verdict" ]] \
    && fs_verdict_has_usable_report "$latest_maintainer_report_verdict"; then
    report_from="maintainer"
fi

# A multi-step read-only run keeps its verdicts as sK-<action>-verdict-1.md
# and has no review-verdict-N / maintainer-verdict-N files, so its account
# is the last step, in step order, whose verdict carries a usable report.
ro_steps_json='[]'
if [[ "${ro_multi:-0}" == 1 ]]; then
    for ((_k = run_step_count; _k >= 1; _k--)); do
        _a=review
        [[ "${run_step_kind[$_k]}" == maintainer ]] && _a=maintain
        _v="$run_dir/s${_k}-${_a}-verdict-1.md"
        if [[ -f "$_v" ]] && fs_verdict_has_usable_report "$_v"; then
            report_from=review
            [[ "$_a" == maintain ]] && report_from=maintainer
            break
        fi
    done
    ro_steps_ndjson=""
    for ((_k = 1; _k <= run_step_count; _k++)); do
        _a=review
        [[ "${run_step_kind[$_k]}" == maintainer ]] && _a=maintain
        _h_var="s${_k}_harness"; _m_var="s${_k}_model"
        _f=""
        [[ -s "$run_dir/step-${_k}-loop.json" ]] && _f="$(jq -r '[.iterations[].findings | if . == null then "?" else tostring end] | join(",")' "$run_dir/step-${_k}-loop.json" 2>/dev/null || true)"
        ro_steps_ndjson+="$(jq -cn --argjson step "$_k" --arg action "$_a" \
            --arg harness "${!_h_var}" --arg model "${!_m_var:-}" \
            --arg ended "${progress_ended[$_k]:-}" --arg findings "$_f" \
            --arg verdict "$run_dir/s${_k}-${_a}-verdict-1.md" \
            '{step:$step, action:$action, harness:$harness,
              model:(if $model == "" then null else $model end),
              ended:(if $ended == "" then null else $ended end),
              findings:(if $findings == "" then null else $findings end),
              verdict:$verdict}' 2>/dev/null)"$'\n'
    done
    ro_steps_json="$(printf '%s' "$ro_steps_ndjson" | jq -cs '.' 2>/dev/null || printf '[]')"
fi

# Did the work come back authored by this repo's own identity? The clone is
# seeded with the origin's effective user.email (fs_make_clone in the lib says
# why), so it should. Before that seeding existed a repo whose identity was a
# local override got commits authored by whatever ~/.gitconfig held, and
# nothing downstream noticed: integration re-creates the commits on the host,
# and cherry-pick and rebase deliberately keep the author. Silent misattribution
# is how that survived, so the run checks itself rather than wait for someone to
# look. When a mismatch turns up, fs_normalize_authorship rewrites the branch
# host-side to the identity below rather than only reporting it -- the summary
# turns the warning into a notice for that case (grep "NOTICE: authorship
# normalized" below). When the seeding works nothing here fires and the
# summary reads exactly as before, so silence is still the pass signal.
#
# The addresses come from the session's commits and are untrusted text, so
# control characters go the same way they do for the subjects below.
author_email_want=""
author_email_bad=""
authorship_normalized=0
authorship_normalized_from=""
authorship_skip_nonlinear=0
authorship_normalize_failed=0
authorship_normalize_log="$run_dir/authorship-normalize.log"
if (( fetched )) && [[ "$n_commits" != "0" ]]; then
    author_email_want="$( (cd "$origin_repo" && git config --get user.email) 2>/dev/null || true )"
    if [[ -n "$author_email_want" ]]; then
        author_email_bad="$( (cd "$origin_repo" \
            && git log --format='%ae' "$return_base_sha..$branch") 2>/dev/null \
            | tr -d '\000-\010\013-\037\177' \
            | grep -vxF -- "$author_email_want" | sort -u || true )"
        if [[ -n "$author_email_bad" ]]; then
            author_name_want="$( (cd "$origin_repo" && git config --get user.name) 2>/dev/null || true )"
            # fs_normalize_authorship lets its plumbing calls write stderr
            # normally (see its own comment for why), so capturing this
            # call's stderr into a file under run_dir is what actually puts
            # the git error somewhere the failure message below can point
            # to -- sandbox.log never sees it, since this call is not part
            # of the tee'd harness pipeline.
            if authorship_normalized_out="$(fs_normalize_authorship "$origin_repo" "$branch" \
                "$return_base_sha" "$author_name_want" "$author_email_want" \
                2> "$authorship_normalize_log")"; then
                authorship_normalize_rc=0
            else
                authorship_normalize_rc=$?
            fi
            # A successful rewrite clears author_email_bad back to empty --
            # that variable is the pass/fail signal everything below this
            # point (the summary's WARNING branch, summary.json's
            # author_email_unexpected field) already keys off, and after a
            # rewrite the branch genuinely does carry the expected identity
            # now. The address(es) found are kept in
            # authorship_normalized_from instead, since the notice below
            # still needs to say what was wrong before the fix.
            if [[ "$authorship_normalized_out" =~ ^[0-9]+$ ]] \
                && (( authorship_normalize_rc == 0 && authorship_normalized_out > 0 )); then
                authorship_normalized="$authorship_normalized_out"
                authorship_normalized_from="$author_email_bad"
                author_email_bad=""
            elif (( authorship_normalize_rc == 2 )); then
                authorship_skip_nonlinear=1
            elif (( authorship_normalize_rc != 0 )); then
                # mktemp, or any of the rev-parse/git log/cat-file/commit-tree/
                # update-ref calls inside the rewrite, failed. The branch is
                # left exactly as fetched (fs_normalize_authorship makes no
                # git writes on this path), but without this flag the summary
                # below falls through to the plain WARNING with nothing to
                # say a rewrite was even attempted.
                authorship_normalize_failed=1
            fi
        fi
    fi
fi

# The outbox is measured here, at the end of the run, rather than checked
# live as the agent writes to it: a local run has nothing to "pull" the way
# a k8s run's client does, so there is no point to enforce and nothing to
# refuse -- only a heads-up if the agent left more there than the cap allows.
# Nothing is deleted either way; the files stay on disk for the operator to
# look at and clean up themselves.
outbox_bytes="$(du -sb -- "$outbox_dir" 2>/dev/null | cut -f1)"
[[ -n "$outbox_bytes" ]] || outbox_bytes=0
if (( outbox_bytes > outbox_max_bytes )); then
    printf 'fork-sandbox: WARNING: outbox is %s bytes, over the %s byte cap.\n' \
        "$outbox_bytes" "$outbox_max_bytes" >&2
    printf 'fork-sandbox: files are still on disk at %s -- nothing was deleted.\n' \
        "$outbox_dir" >&2
fi
# Recorded in run.env the same way cost= and model= are refreshed above:
# replace rather than append, since a reader takes the first match, and
# build the replacement beside the file and rename, which is atomic.
if [[ -s "$run_dir/run.env" ]] \
    && grep -v '^outbox_bytes=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'outbox_bytes=%s\n' "$outbox_bytes" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi
if [[ -s "$run_dir/run.env" ]] \
    && grep -v '^outbox_max_bytes=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'outbox_max_bytes=%s\n' "$outbox_max_bytes" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi

# The loop record's per-iteration findings counts, comma-joined. An
# iteration whose count is unknown (null in the record) renders as '?',
# the suite's established "cannot read it" mark -- it must never render
# as 0, which would read as a clean review. Empty, and so the findings
# clause is dropped, when the record cannot be read at all.
loop_findings() {
    jq -r '[.iterations[].findings
           | if . == null then "?" else tostring end] | join(",")' \
        "$1" 2>/dev/null || true
}

{
    # The value column is 12, not 10: 'maintainer:' is 11 characters, the
    # longest label in the block, and the block reads as two aligned
    # columns only if the whole block shares its width.
    printf '== fork-sandbox summary ==\n'
    printf 'branch:    %s\n' "$branch"
    printf 'mode:      %s\n' "$mode"
    printf 'origin:    %s\n' "$origin_repo"
    printf 'clone:     %s\n' "$clone_dir"
    printf 'exit:      %s\n' "$rc"
    if [[ -n "$run_error" ]]; then
        printf 'error:     %s\n' "$run_error"
    fi
    printf 'commits:   %s\n' "$n_commits"
    if [[ -n "$run_cost_fmt" ]]; then
        printf 'cost:      $%s\n' "$run_cost_fmt"
    fi
    # One line for the review loop when it ran at all, including the case
    # where it was skipped and why.
    if [[ -n "$review_loop_ended" ]]; then
        if [[ "$review_loop_ended" == "skipped" ]]; then
            printf 'review:    skipped -- %s\n' "$review_loop_detail"
        else
            # Findings first, exit labelled as the loop's: "approved" after
            # one clean iteration and after a loop that stopped early must
            # not read the same, and neither is a judgement on the branch.
            _n="$(jq '.iterations | length' "$run_dir/review-loop.json" 2>/dev/null || printf '?')"
            _f="$(loop_findings "$run_dir/review-loop.json")"
            if [[ -n "$_f" ]]; then
                printf 'review:    %s iteration(s), findings %s; loop exit: %s\n' \
                    "$_n" "$_f" "$review_loop_ended"
            else
                printf 'review:    %s iteration(s); loop exit: %s\n' \
                    "$_n" "$review_loop_ended"
            fi
        fi
    fi
    # The maintainer loop's line, the review line's sibling and the run's
    # last word on the branch. Its variables exist only in a run.sh that
    # emitted them, so the test carries a default.
    if [[ -n "${maintainer_loop_ended:-}" ]]; then
        if [[ "${maintainer_loop_ended}" == "skipped" ]]; then
            printf 'maintainer:skipped -- %s\n' "${maintainer_loop_detail:-}"
        else
            # Same shape as the review line: findings first, exit labelled
            # as the loop's, never the branch's.
            _n="$(jq '.iterations | length' "$run_dir/maintainer-loop.json" 2>/dev/null || printf '?')"
            _f="$(loop_findings "$run_dir/maintainer-loop.json")"
            if [[ -n "$_f" ]]; then
                printf 'maintainer:%s iteration(s), findings %s; loop exit: %s\n' \
                    "$_n" "$_f" "${maintainer_loop_ended}"
            else
                printf 'maintainer:%s iteration(s); loop exit: %s\n' \
                    "$_n" "${maintainer_loop_ended}"
            fi
        fi
    fi
    # The tidy leg's own line, printed only when the pipeline has a
    # maintain step at all (not just when one ran last and approved): a
    # pipeline with none reads exactly as it did before this feature
    # existed, matching maintainer:/review: above, each printed only when
    # that tier exists in this run.
    if (( tidy_has_maintain_step )); then
        printf 'tidy:      %s%s\n' "$tidy_ended" "${tidy_detail:+ ($tidy_detail)}"
    fi
    # A multi-step read-only run lists every leg and how it ended.
    if [[ "${ro_multi:-0}" == 1 ]]; then
        jq -r '.[] | "step \(.step):   \(.action) (\(.harness)\(if .model then "/" + .model else "" end)): \(.ended // "not run")\(if .findings then ", findings " + .findings else "" end)"' \
            <<<"$ro_steps_json" 2>/dev/null || true
    fi
    # Its sibling for --refresh-at, printed only when something happened --
    # either a continuation actually ran, or a leg was nudged and never wrote
    # one, both of which are worth a line. A run that never came near its
    # threshold (the common case, since the flag is on by default) reads
    # exactly as it did before this feature existed.
    if [[ "$refresh_leg_n" -gt 0 || "$refresh_ended" == "no-handoff" ]]; then
        printf 'refresh:   %s continuation leg(s), ended %s\n' \
            "$refresh_leg_n" "$refresh_ended"
    fi
    # One line per OTHER leg whose own chain ran at least one continuation,
    # or was nudged and never wrote one -- the same "worth a line" rule as
    # the step-1 implement leg's own refresh line above. A run with no code
    # step past step 1 and no fix leg that ever refreshed reads exactly as
    # it did before this feature existed.
    jq -r '.[] | select((.continuations | length) > 0 or .ended == "no-handoff") |
        "refresh:   \(.leg) (\(.kind)): \(.continuations | length) continuation leg(s), ended \(.ended)"' \
        <<<"$leg_refreshes_json" 2>/dev/null || true
    # The total is printed only when it actually spent something beyond the
    # coding session's own cost, so a run with neither flag -- or with
    # neither ever doing anything -- reads exactly as it did before either
    # feature existed.
    if [[ -n "$total_cost_fmt" && "$total_cost_fmt" != "$run_cost_fmt" ]]; then
        printf 'total:     $%s  (the session and every review-, maintainer-, tidy- or continuation leg)\n' \
            "$total_cost_fmt"
    fi
    if [[ -d "$run_dir/pi-session" ]]; then
        printf 'session:   %s\n' "$run_dir/pi-session"
    fi
    if (( ! fetched )); then
        if [[ -n "$tidy_kept_ref" ]]; then
            # The clone is NOT a safe fallback here -- for a discard
            # it may hold the rejected rewrite, not this run's approved
            # work -- so this names the holding ref fetch-back kept instead
            # of claiming the usual "the work is in the clone only".
            printf 'fetched:   NO -- branch %s already exists in %s with a\n' \
                "$branch" "$origin_repo"
            printf '           different history. This run'"'"'s own history is safe at\n'
            printf '           %s (%s); recover it by hand once the\n' \
                "$tidy_kept_ref" "$tidy_kept_sha"
            printf '           collision is resolved:\n'
            printf '             (cd %q && git update-ref refs/heads/%s %s "")\n' \
                "$origin_repo" "$branch" "$tidy_kept_sha"
        else
            printf 'fetched:   NO -- the work is in the clone only\n'
        fi
    elif (( removed )); then
        printf 'fetched:   nothing. The session made no commits, so branch %s\n' "$branch"
        printf '           was removed again and %s is unchanged.\n' "$origin_repo"
    else
        printf 'fetched:   yes. Branch %s is now in %s\n' "$branch" "$origin_repo"
    fi
    [[ -n "$upstream_line" ]] && printf '%s\n' "$upstream_line"
    if (( stats_ready )) && [[ "$n_commits" != "0" ]]; then
        # The commits are untrusted, and git passes a subject through
        # verbatim when stdout is not a tty. Strip control characters so an
        # ESC or CR planted in a commit message cannot spoof this summary in
        # the pane or the monitor stream. Tab and newline stay.
        printf '\n'
        (cd "$branch_repo" && git log --oneline --no-decorate "$return_base_sha..$branch") \
            | tr -d '\000-\010\013-\037\177'
        printf '\n'
        (cd "$branch_repo" && git diff --stat "$return_base_sha" "$branch") \
            | tr -d '\000-\010\013-\037\177'
    fi
    if (( fetched )) && [[ "$n_commits" != "0" ]]; then
        printf '\nReview the branch before you build it. It is agent-written code,\n'
        printf 'and a Makefile or package.json script in it runs on the host.\n'
    else
        printf '\nNothing landed in %s. Whatever the session wrote is still\n' "$origin_repo"
        printf 'in the clone at %s\n' "$clone_dir"
    fi
    # Second-to-last -- the uncommitted-files warning below is what is now
    # last, and the hardest line in the summary to skim past.
    if [[ -n "$author_email_bad" ]]; then
        printf '\nWARNING: a returned commit was authored by an unexpected address.\n'
        printf '  expected: %s   (the user.email %s resolves to)\n' \
            "$author_email_want" "$origin_repo"
        printf '%s\n' "$author_email_bad" | sed 's/^/  found:    /'
        printf 'The clone is seeded with the repo user.email, so a mismatch means\n'
        printf 'that seeding regressed. Fix authorship before you integrate: rebase\n'
        printf 'and cherry-pick both keep the author, so it lands as-is otherwise.\n'
        if (( authorship_skip_nonlinear )); then
            printf 'Normalization was skipped: the range contains a merge commit, or\n'
            printf 'does not descend from the run'"'"'s own base commit, and this\n'
            printf 'rewrite only knows how to walk a single line of history from it.\n'
        elif (( authorship_normalize_failed )); then
            printf 'Normalization was attempted and failed -- the branch is\n'
            printf 'unchanged from what fetch brought in. See %s\n' \
                "$authorship_normalize_log"
            printf 'for the git error.\n'
        fi
    elif (( authorship_normalized > 0 )); then
        printf '\nNOTICE: authorship normalized -- %s commit(s) rewritten from\n' \
            "$authorship_normalized"
        printf '%s\n' "$authorship_normalized_from" | sed 's/^/  found:    /'
        printf 'to %s   (the user.email %s resolves to).\n' \
            "$author_email_want" "$origin_repo"
        printf 'The clone is seeded with the repo user.email, so this means seeding\n'
        printf 'regressed for this run. Keep %s around for diagnosis.\n' "$run_dir"
        printf 'This rewrite only touched %s in %s; every sha this\n' "$branch" "$origin_repo"
        printf 'run recorded before now (review-loop.json, maintainer-loop.json\n'
        printf 'head_before/head_after) still names the pre-rewrite commits, which\n'
        printf 'are no longer reachable from the branch.\n'
        # clone_lock_path is only ever set for a --clone-dir seat (see its
        # own comment in the RUNNER above) -- a fresh clone under run_dir is
        # a throwaway nothing else can reach and gets no later wake, so the
        # reuse hazard below does not apply to it.
        if [[ -n "${clone_lock_path:-}" ]]; then
            printf 'The persistent clone at\n'
            printf '%s still carries them too, under the regressed identity --\n' "$clone_dir"
            printf 'if that workspace is reused for a later wake, its next branch will\n'
            printf 'start from those commits and carry the bad authorship forward\n'
            printf 'unflagged, since the check only ever looks at its own base..branch.\n'
        fi
    fi
    # Last, so it is the hardest line in the summary to skim past: shown
    # whether or not the run also committed something, since a leg can
    # leave files uncommitted even on a branch that otherwise landed, and
    # an uncommitted file is not fetched back -- review and maintainer
    # never see it, and it does not leave the sandbox at all.
    if [[ -z "$uncommitted_files" ]]; then
        printf '\nWARNING: could not check the clone for uncommitted work.\n'
        printf 'See %s for the sandboxed git status error.\n' "$run_dir/git-status.log"
    elif (( uncommitted_files > 0 )); then
        printf '\nWARNING: the clone holds %s uncommitted file(s) the session never\n' \
            "$uncommitted_files"
        printf 'committed. Review and maintainer legs never saw them, and they do\n'
        printf 'not leave the sandbox:\n'
        printf '%s\n' "${uncommitted_paths_capped[@]}" | sed 's/^/  /'
        if (( uncommitted_files > ${#uncommitted_paths_capped[@]} )); then
            printf '  ... and %s more\n' \
                "$(( uncommitted_files - ${#uncommitted_paths_capped[@]} ))"
        fi
        printf 'The clone is at %s\n' "$clone_dir"
    fi
} > "$run_dir/summary.txt" 2>&1

# The same facts, structured, so a caller never has to parse the prose
# above — a decimal cost especially, which the obvious grep-and-strip
# mangles. jq builds it, so every value is escaped properly: commit
# subjects come from the session and are untrusted text. A jq that fails
# leaves no file, and summary.txt, which is what a person reads, stands.
commit_list="$( (cd "$branch_repo" && git log --format='%H %s' "$return_base_sha..$branch") 2>/dev/null \
    | jq -R -s 'split("\n") | map(select(length > 0))
                | map({sha: .[0:40], subject: .[41:]})' 2>/dev/null )"
[[ -n "$commit_list" ]] || commit_list='[]'
# The identity check, structured: the address the commits should carry, and
# every other one they actually do. An empty array is the pass, and it is the
# array a caller can assert on without parsing the warning prose above.
author_email_bad_json="$(printf '%s' "$author_email_bad" \
    | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)"
[[ -n "$author_email_bad_json" ]] || author_email_bad_json='[]'
# uncommitted_files: null when the sandboxed check itself could not run
# (unknown, never guessed at zero), otherwise the true count -- not capped,
# unlike the list, which the summary.txt WARNING above caps the same way.
uncommitted_files_json='null'
[[ -n "$uncommitted_files" ]] && uncommitted_files_json="$uncommitted_files"
uncommitted_files_list_json='null'
if [[ -n "$uncommitted_files" ]]; then
    uncommitted_files_list_json="$(printf '%s\n' "${uncommitted_paths_capped[@]}" \
        | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)"
    [[ -n "$uncommitted_files_list_json" ]] || uncommitted_files_list_json='[]'
fi
# Presence, not content: the patch itself (uncommitted.patch, saved above
# when runner_in_sandbox and there was something to save) travels back as
# its own artifact. This just tells a reader it exists, without having to
# stat the run dir separately.
uncommitted_patch_json=false
[[ -s "$run_dir/uncommitted.patch" ]] && uncommitted_patch_json=true
fetched_json=false
(( fetched )) && fetched_json=true
removed_json=false
(( removed )) && removed_json=true
session_dir_json=""
[[ -d "$run_dir/pi-session" ]] && session_dir_json="$run_dir/pi-session"
# With --session-state, name the session a later run could resume. See
# fs_session_discover_id in fork-sandbox-lib.sh for the discovery rules.
# Empty when the flag was not given, or when the store has no transcript --
# a session that died before writing one.
session_id_json=""
if [[ -n "$session_state" ]]; then
    session_id_json="$(fs_session_discover_id "$harness" "$session_state" "$session_id_given")"
fi

# outbox/reply.md: use the agent's own reply when it wrote one; otherwise
# render the session account as a fallback. Written BEFORE summary.json:
# --json calls a run "replied" once summary.json exists, so reply.md must
# already be there. A render that fails fails the run (below), the same way
# a lost fetch-back race does, rather than report success with nothing to
# read. Never runs
# at all for a pod leg (fetch_back=0) -- $script_dir there is the pod's
# own staged copy of scripts/, which is not guaranteed to carry
# fork-sandbox-status.sh, and the host-side cmd_collect writes this same
# file for a --k8s run instead, once the branch is actually back in the
# user's own repo.
reply_rendered=true
if (( fetch_back )) && [[ -x "$script_dir/fork-sandbox-status.sh" ]]; then
    # The agent can write here: anything but a regular file (a FIFO would
    # block the write below forever) is refused, never opened.
    if [[ -L "$run_dir/outbox/reply.md" ]] \
        || { [[ -e "$run_dir/outbox/reply.md" ]] && [[ ! -f "$run_dir/outbox/reply.md" ]]; }; then
        reply_rendered=false
    elif [[ ! -f "$run_dir/outbox/reply.md" ]] \
        && ! { mkdir -p -- "$run_dir/outbox" 2>/dev/null \
            && "$script_dir/fork-sandbox-status.sh" --result "$run_dir" \
                > "$run_dir/outbox/reply.md" 2>/dev/null; }; then
        reply_rendered=false
    fi
fi
# Same "only overridden when rc is still 0" rule the fetch-back override
# above uses: a run that already failed on its own terms keeps reporting
# that failure, not this one. exit-code is rewritten too, for the same
# reason that override rewrites it -- a reader polling it right now must
# not see success for a run whose reply this very check just found missing.
if [[ "$reply_rendered" != true ]] && (( rc == 0 )); then
    rc=1
    printf '%s\n' "$rc" > "$run_dir/exit-code"
fi

ended_at="$(date +%s)"

# Present whenever the pipeline has a maintain step anywhere (tidy.json
# itself is only written then, by the tidy block above -- see its own
# comment); absent, not null, on a run with no maintain step at all, the
# same convention session_state/claude_credentials_via below use, so a
# pipeline that never had this leg to begin with leaves no "tidy" key for
# a reader to puzzle over.
tidy_summary_json="$(cat "$run_dir/tidy.json" 2>/dev/null)"
[[ -n "$tidy_summary_json" ]] || tidy_summary_json=null

jq -n \
    --argjson version 1 \
    --arg mode "$mode" \
    --arg harness "$record_harness" \
    --arg harness_version "$record_harness_version" \
    --arg network "$network" \
    --arg usage_source "$usage_source" \
    --argjson usage "$run_usage" \
    --arg model "$record_model" \
    --arg branch "$branch" \
    --arg origin_repo "$origin_repo" \
    --arg clone_dir "$clone_dir" \
    --arg run_dir "$run_dir" \
    --arg base_sha "$base_sha" \
    --arg session_dir "$session_dir_json" \
    --arg harness_error "$run_error" \
    --argjson exit_code "$rc" \
    --argjson commits "$n_commits" \
    --argjson fetched "$fetched_json" \
    --argjson branch_removed "$removed_json" \
    --argjson cost_usd "${run_cost_fmt:-null}" \
    --argjson total_cost_usd "${total_cost_fmt:-null}" \
    --argjson started_at "$started_at" \
    --argjson ended_at "$ended_at" \
    --argjson commits_list "$commit_list" \
    --arg author_email "$author_email_want" \
    --argjson author_email_unexpected "$author_email_bad_json" \
    --argjson authorship_normalized "$authorship_normalized" \
    --arg refresh "$refresh_ended" \
    --arg report_from "$report_from" \
    --argjson ro_steps "$ro_steps_json" \
    --argjson continuations "$continuations_json" \
    --argjson leg_refreshes "$leg_refreshes_json" \
    --argjson outbox_bytes "$outbox_bytes" \
    --argjson outbox_max_bytes "$outbox_max_bytes" \
    --arg session_state "$session_state" \
    --arg session_id "$session_id_json" \
    --arg claude_credentials_source "$claude_credentials_source" \
    --arg claude_credentials_via "$claude_credentials_via" \
    --arg end_reason "${end_reason:-}" \
    --arg agent_kit "$agent_kit" \
    --argjson leg_retries "${total_leg_retries:-0}" \
    --argjson implement_retries "${impl_leg_retries_json:-[]}" \
    --argjson uncommitted_files "$uncommitted_files_json" \
    --argjson uncommitted_files_list "$uncommitted_files_list_json" \
    --argjson uncommitted_patch "$uncommitted_patch_json" \
    --argjson tidy "$tidy_summary_json" \
    --argjson tidy_has_maintain_step "$( (( tidy_has_maintain_step )) && echo true || echo false )" \
    '{
        version: $version,
        mode: $mode,
        harness: $harness,
        harness_version: (if $harness_version == "" then null else $harness_version end),
        network: $network,
        model: (if $model == "" then null else $model end),
        branch: $branch,
        origin_repo: $origin_repo,
        clone_dir: $clone_dir,
        run_dir: $run_dir,
        base_sha: $base_sha,
        agent_kit: ($agent_kit | split(" ") | map(select(. != ""))),
        exit_code: $exit_code,
        harness_error: (if $harness_error == "" then null else $harness_error end),
        commits: $commits,
        commits_list: $commits_list,
        author_email: (if $author_email == "" then null else $author_email end),
        author_email_unexpected: $author_email_unexpected,
        authorship_normalized: $authorship_normalized,
        fetched: $fetched,
        branch_removed: $branch_removed,
        cost_usd: $cost_usd,
        total_cost_usd: $total_cost_usd,
        refresh: $refresh,
        report_from: $report_from,
        continuations: $continuations,
        leg_refreshes: $leg_refreshes,
        outbox_bytes: $outbox_bytes,
        outbox_max_bytes: $outbox_max_bytes,
        usage: $usage,
        usage_source: (if $usage == null then null else $usage_source end),
        session_dir: (if $session_dir == "" then null else $session_dir end),
        started_at: $started_at,
        ended_at: $ended_at,
        duration_seconds: ($ended_at - $started_at),
        leg_retries: $leg_retries,
        implement_retries: $implement_retries,
        uncommitted_files: $uncommitted_files,
        uncommitted_files_list: $uncommitted_files_list,
        uncommitted_patch: $uncommitted_patch,
    }
    # Both keys are absent, not null, on a run without --session-state:
    # their presence is how a caller tells a resumable run from one whose
    # transcript died with the sandbox.
    + (if $session_state == "" then {} else {
        session_state: $session_state,
        session_id: (if $session_id == "" then null else $session_id end),
    } end)
    # Same absent-not-null shape, gated on whether this run had a claude
    # leg at all -- mirrors the claude_credentials_* convention already
    # used for run.env, so sandbox-run-log.py SUMMARY_FIELDS lift and its
    # run.env fallback agree on when the pair exists.
    + (if $claude_credentials_via == "" then {} else {
        claude_credentials_source: $claude_credentials_source,
        claude_credentials_via: $claude_credentials_via,
    } end)
    # Absent, not null, on every normal run -- same convention as the pair
    # above. fork-sandbox-status.sh treats presence as the signal that this
    # run ended other than on its own.
    + (if $end_reason == "" then {} else {end_reason: $end_reason} end)
    # Present only on a multi-step read-only run, one record per leg.
    + (if ($ro_steps | length) == 0 then {} else {steps: $ro_steps} end)
    # Absent, not null, on a pipeline with no maintain step anywhere -- the
    # tidy leg never exists to have an outcome there, so there is nothing
    # for this key to report (see the tidy block comment above).
    + (if $tidy_has_maintain_step then {tidy: $tidy} else {} end)' \
    > "$run_dir/summary.json" 2>/dev/null \
    || rm -f "$run_dir/summary.json"

# Append this run to the durable run log (~/.claude/sandbox-runs.jsonl),
# however it ended. The tool owns the record shape and reads summary.json,
# task-meta.json and the handoff out of the run dir itself. Best-effort: a
# failed append must not fail the run.
if [[ -n "$run_log_bin" && -x "$run_log_bin" ]]; then
    "$run_log_bin" record --run-dir "$run_dir" >> "$sandbox_log" 2>&1 \
        || printf 'fork-sandbox: run-log append failed; see %s\n' \
            "$sandbox_log" >&2
fi

# Everything above that touches this workspace's git state is done, so the
# lock's job is done too. Released explicitly here rather than left to the
# EXIT trap: the --keep-session path below ends in exec, which replaces this
# process without running the trap, so a run started with that flag would
# hold the lock for as long as the interactive shell stays open otherwise.
release_clone_lock

cat "$run_dir/summary.txt"

if [[ "$keep_open" == "1" ]]; then
    cd "$origin_repo" 2>/dev/null || cd /
    exec "$user_shell" -i
fi
exit "$rc"
