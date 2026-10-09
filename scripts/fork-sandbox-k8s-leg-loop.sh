#!/usr/bin/env bash
# fork-sandbox-k8s-leg-loop.sh -- the leg container's main loop, for a
# composed (--run-dir) pod run
#
# Shipped in via a ConfigMap, like every other pod-side script (see
# docs/kubernetes-runs.md's "The agent pod"). Invoked as `bash
# fork-sandbox-k8s-leg-loop.sh`, as the leg container's own command -- so
# this process is PID 1 of that container's pid namespace, which the
# process-group sweep below depends on.
#
# Why this exists: a composed run's walker, fork-sandbox-runner.sh, decides
# what a LATER leg runs and what the run reports -- so nothing a leg (an AI
# agent running arbitrary commands) does may be able to change that
# decision. The walker and every leg it starts used to share one container,
# one uid and one writable run directory, so a leg could rewrite the
# walker's own state. This script is the other half of the fix in
# fork-sandbox-k8s.sh's pod spec (see "Composed pipelines on --k8s" in
# docs/kubernetes-runs.md): the walker (fork-sandbox-runner.sh, run by
# fork-sandbox-k8s-entrypoint.sh) runs in a SEPARATE container, the
# "agent" container, which mounts the run directory read-write; THIS
# container mounts it read-only, and mounts the clone and a dedicated
# hand-off directory read-write instead. A leg running here cannot write
# the run directory no matter what it does -- the kernel's read-only bind
# mount enforces that, not this script -- so this script's only remaining
# job is to run exactly the leg it is asked to run, and to make sure
# nothing that leg leaves behind survives into the next one.
#
# Protocol: the agent container (fs_run_leg_split in fork-sandbox-
# runner.sh) asks for a leg by writing, under $RUN_DIR/.leg-req/<n>/
# (strictly increasing n, one leg in flight at a time, never two):
#   argv    NUL-separated argv for the leg's own command
#   stdin   the leg's stdin (its prompt), verbatim
#   token   a fresh random token fs_run_leg_split generated for request n
#   go      written LAST -- its mere existence is the request
# and reads the response back from $FORK_SANDBOX_LEG_HANDOFF_DIR/<n>-<token>/:
#   stdout, stderr   the leg's own output streams, captured whole
#   rc               its exit code
#   done             written LAST -- but NOT the signal the runner actually
#                    trusts (see $RUN_DIR/.leg-req/lock below): the whole
#                    hand-off volume is leg-writable, so a leg can write its
#                    own "<n>-<token>/done" itself, at any time, including
#                    before its real process exits. `done`'s only job is to
#                    name which response directory to read once the lock
#                    below says it is safe to.
# $RUN_DIR/.leg-req/lock -- a single file for the whole run, created empty
# by the agent container before it ever writes a "go" -- is what actually
# tells the runner a request is done. This script opens it read-only (the
# mount is read-only here, like the rest of $RUN_DIR, but flock's
# exclusive lock does not require the fd to be opened for writing) and
# holds `flock -x` on it from strictly before it spawns a leg's own
# process until strictly after that leg's sweep (below) and its "rc"/
# "done" write are both done. fs_run_leg_split's own wait is for "done" to
# exist AND for a non-blocking `flock -n` on its own fd to the same file
# to succeed -- a leg can forge "done"'s content at will, but it cannot
# make this script's exclusive hold let go early, and it cannot unlink or
# replace the lock file to start over on a fresh, unlocked inode (the
# mount is read-only). So a forged "done" written while the real leg, or
# anything it left behind, might still be running is simply ignored: the
# runner keeps waiting until the lock is actually free, at which point
# this script has already overwritten "rc" and "done" with the genuine
# values anyway. See fs_run_leg_split's own comment in fork-sandbox-
# runner.sh for the other half of this.
# The token, not just <n>, names the response directory because the whole
# hand-off volume -- not a per-request slice of it -- is read-write in
# this container: without the token, request n's own leg could pre-plant
# $FORK_SANDBOX_LEG_HANDOFF_DIR/<n+1>/done (predictable: n+1 is just this
# request's own number plus one) before request n+1's real leg has even
# started, forging its result. $RUN_DIR/.leg-req/<n+1>/token does not
# exist until the runner issues request n+1, which (via the lock above)
# only happens once request n's own lock is confirmed free -- so this
# container never has the token for a request it has not yet been asked
# to run, and cannot predict or pre-write the path a later response
# belongs at.
# A request numbered <n> is never reused, so there is no file to clear
# between legs on the response side, only the sweep below on the process
# side. $RUN_DIR/.leg-shutdown, checked for on the same poll, ends the loop
# once the runner is done starting legs -- it only ever appears after the
# last real request's lock was already released, so it never races one.
#
# The sweep: after the leg's own process exits, this script -- PID 1 of
# this container's pid namespace -- sends SIGKILL to every other process
# the kernel will let it reach: `kill -KILL -1`. On Linux that reaches
# every process in this pid namespace and in any pid namespace nested
# inside it (namespaces are hierarchical for signals), except PID 1 itself
# and the sender, neither of which this script ever is aside from itself.
# This holds against a leg that starts a background daemon with setsid or
# a double fork to outlive its own exit: a new session or a reparented
# orphan is still a process in this same pid namespace, and SIGKILL cannot
# be blocked, ignored or caught, so "ignores SIGTERM" is not a defense
# either. The one escape this could not close would be the leg creating
# its OWN pid namespace to hide a process from this sweep -- but doing
# that needs CAP_SYS_ADMIN (for unshare(CLONE_NEWPID)), and this pod's
# securityContext drops every capability (see "The agent pod" in
# docs/kubernetes-runs.md), so the syscall itself fails. Nothing here
# relies on process GROUPS or SESSIONS, which a leg can leave at will with
# its own call to setsid(2); it relies only on "this pid namespace has no
# capability to create a child namespace", which a leg cannot revoke or
# route around. Run exactly once per request, strictly after `wait` on the
# leg's own process returns and strictly before this script writes `rc` or
# `done` -- so by the time the runner is told a leg is done, every process
# that leg could have started is already gone, closing the race a
# leftover process would otherwise have against the NEXT leg's own
# request (which this loop has not even written `go` for yet at that
# point).
#
# Startup, before the loop: this container's own $HOME starts empty (a
# fresh emptyDir), so the pi/claude config the agent container assembled
# (model discovery against the pi proxy, the claude credential placeholder)
# is relayed in as plain files rather than redone here -- redoing it here
# would mean a second network round trip and a second place that result
# could disagree with the runner's own. The runner writes it to
# $RUN_DIR/.leg-setup/ (read-only to this container, like the rest of
# $RUN_DIR) and touches $RUN_DIR/.leg-setup/ready last; this script waits
# for that file, then copies what it finds into $HOME.
#
# Env:
#   RUN_DIR          the composed run's own directory, read-only here.
#                     Required.
#   FORK_SANDBOX_LEG_HANDOFF_DIR
#                     the hand-off directory, read-write here, read-only
#                     in the agent container. Required.
#   HOME             this container's own home, read-write, a fresh
#                     emptyDir. Required (fork-sandbox-k8s-leg.sh's claude
#                     and pi arms both need one).
#   FORK_SANDBOX_CLONE_DIR
#                     the clone's path, identical in this container and
#                     the agent container (the same volume, mounted at the
#                     same path in both -- see "A leg cannot write the
#                     runner's own state" in docs/kubernetes-runs.md).
#                     Required; see the safe.directory call below for why.
#   FORK_SANDBOX_LEG_LOOP_SWEEP_TARGET_FILE
#                     test seam -- see the sweep's own comment below.
#                     Never set on a real pod.
#   FORK_SANDBOX_LEG_LOOP_YAMA_PATH
#                     test seam -- see the Yama check below. Never set on
#                     a real pod.
#   FORK_SANDBOX_LEG_LOOP_RESET_MAX_PASSES
#                     test seam -- the $HOME/tmp reset's pass cap
#                     (default 1000). Never set on a real pod.
#   FORK_SANDBOX_LEG_LOOP_HEARTBEAT_INTERVAL
#                     seconds between heartbeat writes while a leg is
#                     running (default 5) -- see the heartbeat comment
#                     below. An operator may tune this; it is not a test
#                     seam.

set -euo pipefail
if [[ -r /mnt/fork-sandbox/browser.sh ]]; then
    # shellcheck disable=SC1091  # generated ConfigMap key, not a source file
    source /mnt/fork-sandbox/browser.sh
else
    # Direct loop tests have no ConfigMap; their prompts carry no marker.
    fs_expand_browser_prompt() {
        if grep -q '%%FORK_SANDBOX_POD_BROWSER%%' "$1"; then
            echo "Error: browser.sh is missing from the pod ConfigMap." >&2
            return 1
        fi
        cat "$1"
    }
fi

: "${RUN_DIR:?RUN_DIR must be set}"
: "${FORK_SANDBOX_LEG_HANDOFF_DIR:?FORK_SANDBOX_LEG_HANDOFF_DIR must be set}"
: "${HOME:?HOME must be set}"
: "${FORK_SANDBOX_CLONE_DIR:?FORK_SANDBOX_CLONE_DIR must be set}"

# A non-interactive bash running as PID 1 and blocked in `wait` takes
# SIGINT's default action and exits -- even though HUP, TERM, USR1 and the
# rest are already survived with no trap at all, by the kernel's own "a
# default-disposition signal sent to a pid-namespace's PID 1 is discarded"
# rule. A leg is this loop's own descendant, same pid namespace, same uid,
# so it can send this loop any signal at will; losing the loop this way
# strands the run until FORK_SANDBOX_LEG_TIMEOUT (the heartbeat below is
# what shortens that). Ignore every externally sendable signal whose
# default action terminates the process; nothing in this script relies on
# catching any of them. KILL and STOP are omitted because they cannot be
# caught, and a leg inside this same pid namespace cannot send either to
# PID 1 anyway (see this script's own sweep comment below).
trap '' HUP INT QUIT USR1 USR2 PIPE ALRM TERM

# A leg runs as this process's own uid, as a descendant of this loop (PID
# 1 of this container's own pid namespace). With no Yama restriction,
# same-uid ptrace is unconditional: a leg could PTRACE_ATTACH to this
# loop, or write /proc/1/mem, and from there release
# $RUN_DIR/.leg-req/lock early, skip the sweep, or forge "done" while the
# real leg (or anything it started) is still alive -- reopening every
# hole the lock and the sweep exist to close. kernel.yama.ptrace_scope >=
# 1 ("restricted ptrace") denies that unconditionally: it permits
# PTRACE_ATTACH only onto a process's own DESCENDANTS (or a process that
# named it via PR_SET_PTRACER), never onto an ancestor -- and this loop
# is the leg's ancestor, never its descendant, so no leg can ever declare
# itself an allowed tracer of it either. A node with no Yama LSM compiled
# in at all, or with ptrace_scope=0 ("classic": any same-uid process may
# PTRACE_ATTACH to any other, ancestry irrelevant), cannot prove that
# property, so this loop refuses to start on one rather than run
# unprotected -- see "A leg can never tamper with the loop's process" in
# docs/kubernetes-runs.md for the node requirement this imposes on every
# cluster that runs a composed pipeline.
yama_path="${FORK_SANDBOX_LEG_LOOP_YAMA_PATH:-/proc/sys/kernel/yama/ptrace_scope}"
yama_scope="$(cat -- "$yama_path" 2>/dev/null || true)"
if [[ ! "$yama_scope" =~ ^[1-3]$ ]]; then
    echo "Error: fork-sandbox-k8s-leg-loop: refusing to start: $yama_path" >&2
    echo "reads '${yama_scope:-<absent>}', not a Yama ptrace_scope of 1, 2 or 3." >&2
    echo "On this node a leg could PTRACE_ATTACH to this loop's own process" >&2
    echo "and tamper with the completion lock. Set" >&2
    echo "kernel.yama.ptrace_scope >= 1 on every node that runs a composed" >&2
    echo "--k8s pipeline (see docs/kubernetes-runs.md, \"A leg can never" >&2
    echo "tamper with the loop's process\")." >&2
    exit 1
fi

setup_dir="$RUN_DIR/.leg-setup"
setup_deadline=$(( $(date +%s) + 300 ))
echo "fork-sandbox-k8s-leg-loop: waiting for $setup_dir/ready" >&2
until [[ -f "$setup_dir/ready" ]]; do
    if (( $(date +%s) >= setup_deadline )); then
        echo "Error: fork-sandbox-k8s-leg-loop: timed out waiting for" >&2
        echo "$setup_dir/ready -- the agent container never finished its" >&2
        echo "own model-discovery/credential setup." >&2
        exit 1
    fi
    sleep 1
done

# $HOME and /tmp are this container's own emptyDirs, shared by every leg
# in the pod, so a leg could plant ~/.gitconfig (core.fsmonitor,
# core.hooksPath), ~/.claude/settings.json hooks, ~/.pi/agent extensions,
# or an arbitrary /tmp file, and have it run inside a LATER leg's own
# lifetime, before that leg's own sweep -- including overwriting a later
# reviewer's verdict after the reviewer wrote it. A local composed run
# gives every leg a fresh, ephemeral home and /tmp; this is this shape's
# equivalent: wipe both and rebuild $HOME from scratch from $setup_dir,
# which is read-only here and owned by the agent container, so nothing a
# leg did can be in it. Called once before the loop starts (so leg 1 gets
# the same guarantee as every leg after it) and again at the top of
# every iteration, before that iteration's leg can run a single
# instruction.
leg_reset_home_and_tmp() {
    local tmp_dir="${TMPDIR:-/tmp}" dir tries
    for dir in "$HOME" "$tmp_dir"; do
        # A leg can leave a directory with no read permission (e.g.
        # `chmod 100 ~/.claude`) in its own tree; `find -delete` cannot
        # enumerate, and so cannot remove, what is INSIDE a directory it
        # cannot read. Ownership, not the current mode bits, governs
        # chmod, so this loop can always widen a directory it owns back to
        # rwx without needing read access on it first -- it just cannot
        # discover a grandchild hidden behind a still-unreadable child
        # until that child's own chmod has already run. Alternate "widen
        # whatever this pass can already see" and "delete" until a delete
        # pass leaves nothing behind, which happens at the planted tree's
        # own depth. Hitting the pass cap means leftovers survive, so the
        # loop exits rather than run a leg on them; the walker then fails
        # the run on the stale heartbeat.
        tries=0
        until find "$dir" -mindepth 1 -delete 2>/dev/null; do
            tries=$(( tries + 1 ))
            if (( tries >= ${FORK_SANDBOX_LEG_LOOP_RESET_MAX_PASSES:-1000} )); then
                echo "Error: fork-sandbox-k8s-leg-loop: could not empty $dir" >&2
                echo "after $tries passes; refusing to run another leg on it." >&2
                [[ -n "${hb_pid:-}" ]] && kill -KILL "$hb_pid" 2>/dev/null
                exit 1
            fi
            # Under `set -e`, this failing (it does, every time it still has
            # a not-yet-widened directory left to hit permission denied on)
            # would otherwise kill this script outright, same as every
            # other `|| true` in this function.
            find "$dir" -mindepth 1 -type d -exec chmod u+rwx -- {} + 2>/dev/null || true
        done
    done

    # The clone's mount ROOT is a dedicated emptyDir volume, owned by
    # whatever created it (the kubelet, as root), not by this container's
    # own uid -- so git's ownership check refuses every leg's git
    # invocation against it ("fatal: detected dubious ownership") unless
    # this uid's OWN $HOME/.gitconfig says otherwise first. Reinstalled
    # here, every time $HOME is wiped, for the same reason the matching
    # call in fork-sandbox-k8s-entrypoint.sh exists.
    git config --global --add safe.directory "$FORK_SANDBOX_CLONE_DIR"

    if [[ -d "$setup_dir/pi-agent" ]]; then
        mkdir -p "$HOME/.pi"
        rm -rf "$HOME/.pi/agent"
        cp -a "$setup_dir/pi-agent" "$HOME/.pi/agent"
    fi
    if [[ -f "$setup_dir/claude-credentials.json" ]]; then
        mkdir -p "$HOME/.claude"
        install -m 600 "$setup_dir/claude-credentials.json" "$HOME/.claude/.credentials.json"
    fi
    if [[ -f "$setup_dir/claude.json" ]]; then
        cp "$setup_dir/claude.json" "$HOME/.claude.json"
    fi
}
leg_reset_home_and_tmp
# fork-sandbox-k8s-leg.sh's pi arm reads this back under the same name; the
# file lives on $RUN_DIR (read-only here), so no copy is needed -- unlike
# the three above, which have to land at a $HOME-relative path a config
# file cannot be redirected from.
export FORK_SANDBOX_K8S_PI_MODEL_MAP="$setup_dir/pi-model-map.json"

echo "fork-sandbox-k8s-leg-loop: ready, waiting for requests under $RUN_DIR/.leg-req" >&2

# A heartbeat this loop itself writes, independent of any in-flight
# request, so fs_run_leg_split can tell "the loop died or wedged" apart
# from "a leg is legitimately still running" --
# see that function's own comment in fork-sandbox-runner.sh for the other
# half. Written here directly (this is PID 1's own code, never a
# background child the sweep could kill) on every poll of the "waiting
# for the next request" loop below; a background writer covers the
# longer stretch where this process is itself blocked in `wait` on a
# leg's own process, further down.
#
# Unlike each request's own response directory, "heartbeat.tmp" is never
# given a fresh path between legs, so a leg can replace it with a FIFO
# (`rm -f heartbeat.tmp; mkfifo heartbeat.tmp`) and exit. A plain `date
# +%s > …` against that does not fail, it BLOCKS -- open() waits for a
# reader that will never come -- and since this function also runs
# directly in this script's own PID-1 code (not just the killable
# background writer), that would wedge the loop itself. Clear anything
# other than a plain regular file first, the same never-block-on-a-leg-
# planted-type treatment "rc" gets below, so the write can only ever
# create a fresh regular file, never reopen a planted one.
# "heartbeat" itself gets the same check: left as a directory, `mv` would
# move the fresh file into it and the heartbeat would never advance again.
heartbeat_file="$FORK_SANDBOX_LEG_HANDOFF_DIR/heartbeat"
leg_write_heartbeat() {
    local f
    for f in "$heartbeat_file.tmp" "$heartbeat_file"; do
        if [[ -e "$f" || -L "$f" ]] && { [[ -L "$f" ]] || [[ ! -f "$f" ]]; }; then
            rm -rf -- "$f" 2>/dev/null || true
        fi
    done
    date +%s > "$heartbeat_file.tmp" 2>/dev/null \
        && mv -f "$heartbeat_file.tmp" "$heartbeat_file" 2>/dev/null
    return 0
}
leg_write_heartbeat

n=0
while true; do
    n=$(( n + 1 ))
    reqdir="$RUN_DIR/.leg-req/$n"
    shutdown_marker="$RUN_DIR/.leg-shutdown"
    while [[ ! -f "$reqdir/go" ]]; do
        if [[ -f "$shutdown_marker" ]]; then
            echo "fork-sandbox-k8s-leg-loop: shutdown requested, exiting" >&2
            exit 0
        fi
        leg_write_heartbeat
        sleep 0.5
    done

    # A leg can legitimately run for hours, during which this process is
    # blocked in `wait` below and cannot write its own heartbeat -- so a
    # background child does it instead, from before the reset (which a
    # leg can make slow by leaving a huge tree behind) until `wait`
    # returns. It is killed strictly before the sweep -- which would kill
    # it anyway -- so it can never linger into the next leg.
    hb_interval="${FORK_SANDBOX_LEG_LOOP_HEARTBEAT_INTERVAL:-5}"
    ( while true; do leg_write_heartbeat; sleep "$hb_interval"; done ) &
    hb_pid=$!

    # Every leg gets a $HOME/tmp equivalent to a fresh one -- see the
    # function's own comment above.
    leg_reset_home_and_tmp

    echo "fork-sandbox-k8s-leg-loop: running request $n" >&2
    argv=()
    while IFS= read -r -d '' arg; do
        argv+=("$arg")
    done < "$reqdir/argv"
    token="$(cat -- "$reqdir/token" 2>/dev/null)"

    handoff="$FORK_SANDBOX_LEG_HANDOFF_DIR/$n-$token"
    mkdir -p "$handoff"

    # Held from here -- strictly before the leg's own process can run a
    # single instruction -- until after the sweep and the rc/done write
    # below. See this script's own header and fs_run_leg_split's comment
    # in fork-sandbox-runner.sh for why this, not "done", is what the
    # runner actually trusts.
    exec {reqlockfd}<"$RUN_DIR/.leg-req/lock"
    flock -x "$reqlockfd"

    leg_rc=0
    # The leg must not inherit the lock fd: it shares this open file
    # description, so a `flock -u` on it would release our hold. Nor the
    # loop's ignored signals, which survive exec: a leg would otherwise
    # ignore SIGTERM and SIGPIPE, and `timeout` could never stop it.
    ( trap - HUP INT QUIT USR1 USR2 PIPE ALRM TERM; exec "${argv[@]}" ) \
        {reqlockfd}<&- < <(fs_expand_browser_prompt "$reqdir/stdin") \
        > "$handoff/stdout" 2> "$handoff/stderr" &
    child_pid=$!
    wait "$child_pid" && leg_rc=0 || leg_rc=$?
    kill -KILL "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true

    # The sweep -- see the header comment above for why this holds against
    # a leg that tried to outlive its own exit. Must run before anything
    # below, which is what the runner waits on.
    #
    # FORK_SANDBOX_LEG_LOOP_SWEEP_TARGET_FILE names a file to re-read at
    # every sweep (never once at startup -- the whole point is that the
    # target is not known until the leg being tested has already started
    # whatever it is going to start) whose content overrides the signal's
    # target; default, and every real pod, -1 (every process this pid
    # namespace will let the sender reach). A real pod never sets this --
    # its leg container has no other process tree to protect, which is
    # the whole point of running it in its own container. A test driving
    # this script directly on a shared host, with no pid namespace of its
    # own to blast, cannot safely send -1 (every process the test's own
    # user owns, including the test harness itself, is as reachable as
    # the leg's) -- it has the leg under test report the one process
    # group it wants swept into this file before this script's `wait`
    # below returns, and scopes the sweep to exactly that instead. That
    # still proves the thing worth proving: the sweep runs, and runs
    # before `done`, killing every process that group holds, no matter
    # how it tried to outlive its own exit.
    sweep_target=-1
    if [[ -n "${FORK_SANDBOX_LEG_LOOP_SWEEP_TARGET_FILE:-}" \
        && -s "$FORK_SANDBOX_LEG_LOOP_SWEEP_TARGET_FILE" ]]; then
        sweep_target="$(cat -- "$FORK_SANDBOX_LEG_LOOP_SWEEP_TARGET_FILE")"
    fi
    # Outside its own pid namespace, -1 reaches every process this user
    # owns on the host, the caller included. Refuse, and never write done:
    # the runner then fails the run on its leg timeout.
    if [[ "$sweep_target" == -1 ]] && (( $$ != 1 )); then
        echo "Error: fork-sandbox-k8s-leg-loop: not PID 1 of its own pid" >&2
        echo "namespace (pid $$); refusing the kill -1 sweep." >&2
        exit 1
    fi
    kill -KILL "$sweep_target" 2>/dev/null || true

    # Written here, not right after `wait` above, so that a leg which
    # started a background daemon to keep replacing "heartbeat.tmp" with
    # a fresh FIFO has already been swept away by the time this runs --
    # otherwise the type-check inside leg_write_heartbeat could lose a
    # race against that daemon recreating the FIFO between the check and
    # the write. By now the sweep has already killed everything the leg
    # could have left running, so nothing is left to race.
    leg_write_heartbeat

    # $handoff is owned by this same uid (this loop created it, above,
    # before the leg ever ran), so the leg -- same uid, same pid
    # namespace -- can chmod it unwritable, or unlink "rc" and replace it
    # with a FIFO, a directory, or a symlink, before it exits. By now the
    # leg and everything it started are dead (the sweep above already
    # ran), so nothing is left to race the check below against. A FIFO
    # left in "rc"'s place is the dangerous case: a plain
    # `printf > "$handoff/rc"` against it does not fail, it BLOCKS --
    # open() waits for a reader that will never come -- which would
    # strand this loop, and the run, until FORK_SANDBOX_LEG_TIMEOUT. `rm`,
    # unlike `open`, never blocks on what it removes, so clear "rc" first
    # whenever it is anything other than a plain regular file, before
    # ever opening it for write.
    # Clearing a bad type, above, would otherwise make the ordinary write
    # below SUCCEED against the now-plain "rc" it just created -- losing
    # the one signal that the leg tampered with it at all. Note the
    # tamper now, before that write ever runs, so a leg that damaged this
    # directory and then exited 0 is never reported as having succeeded
    # merely because the clear made the write possible again.
    rc_type_tampered=0
    # The same holds one level up and for "done": $handoff swapped for a
    # symlink would carry rc and done somewhere the agent container never
    # looks, and a non-file "done" never satisfies the walker's -f test.
    # A regular "done" a leg wrote itself is harmless: the walker also
    # waits for the lock.
    if [[ -L "$handoff" || ! -d "$handoff" ]]; then
        rc_type_tampered=1
        rm -rf -- "$handoff" 2>/dev/null || true
        mkdir -p -- "$handoff" 2>/dev/null || true
    fi
    if [[ -L "$handoff/done" ]] \
        || { [[ -e "$handoff/done" ]] && [[ ! -f "$handoff/done" ]]; }; then
        rc_type_tampered=1
        chmod u+rwx -- "$handoff" 2>/dev/null || true
        rm -rf -- "$handoff/done" 2>/dev/null || true
    fi
    if [[ -e "$handoff/rc" ]] && { [[ -L "$handoff/rc" ]] || [[ ! -f "$handoff/rc" ]]; }; then
        rc_type_tampered=1
        rm -rf -- "$handoff/rc" 2>/dev/null || true
    fi
    # Under `set -e`, a plain write failing against a mode-only problem
    # (chmod 500 on $handoff) would also kill this loop outright, so still
    # try the ordinary write first whenever the type above was clean: if
    # the leg did nothing to $handoff, this is the only branch that ever
    # runs, and the leg's own real exit code is reported exactly as
    # before. Only a write failure here, or the type tamper already noted
    # above, proves damage, and once either has, the leg must be reported
    # as failed regardless of whether recovery below manages to write
    # anything at all.
    if (( rc_type_tampered )) || ! printf '%s' "$leg_rc" > "$handoff/rc" 2>/dev/null; then
        echo "fork-sandbox-k8s-leg-loop: request $n's own response directory" >&2
        echo "was damaged by the leg; recovering and reporting the leg as" >&2
        echo "failed." >&2
        leg_rc=1
        # chmod and rm always succeed here regardless of what mode or
        # type the leg left behind, because ownership (not the current
        # mode bits) is what governs both, and rm -- like the clear above
        # -- removes whatever type is there without opening it. Only if
        # even THAT fails (replaced by something stranger than a mode or
        # type change) is $handoff recreated from nothing -- whatever it
        # held is lost, but the leg is already marked failed above either
        # way.
        chmod u+rwx -- "$handoff" 2>/dev/null || true
        rm -rf -- "$handoff/rc" 2>/dev/null || true
        if ! printf '%s' "$leg_rc" > "$handoff/rc" 2>/dev/null; then
            rm -rf -- "$handoff" 2>/dev/null || true
            mkdir -p -- "$handoff" 2>/dev/null || true
            printf '%s' "$leg_rc" > "$handoff/rc" 2>/dev/null || true
        fi
    fi
    touch "$handoff/done" 2>/dev/null || true
    # Release only now: fs_run_leg_split's own flock -n on this same file
    # cannot succeed before this line runs, no matter what a leg wrote to
    # "done" above or earlier.
    flock -u "$reqlockfd"
    exec {reqlockfd}<&-
    echo "fork-sandbox-k8s-leg-loop: request $n done, rc=$leg_rc" >&2
done
