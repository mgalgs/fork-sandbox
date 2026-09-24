#!/usr/bin/env bash
# fork-sandbox-lib.sh — Shared clone and sandbox helpers (sourced library, not a command)
#
# Usage: source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fork-sandbox-lib.sh"
#
# fork-task.sh --sandboxed and fork-sandbox.sh both run a Claude session in a
# throwaway `git clone --shared` of the user's repo, inside claude-sandboxed.
# The clone, the alternates walk and the argument guard are the same for both,
# and each one is load-bearing for the security design, so they live here
# instead of in two copies that would drift apart.
#
# Every function writes its own error message to stderr and returns non-zero.
# The caller decides whether to exit.

# GNU coreutils, under whatever name this machine has for it.
#
# Everything above the sandbox is bash, and it uses GNU flags that BSD userland
# does not have: `realpath -m` (canonicalize a path whose tail need not exist),
# `realpath -s` (normalize without resolving symlinks), `stat -c` (a format
# string BSD spells with -f, and differently), `sort -V` (version ordering),
# and `timeout`, which macOS does not ship at all. On Linux the GNU tool simply
# has its bare name. Under Homebrew on macOS, coreutils installs it with a `g`
# prefix and is keg-only, so the plain name still resolves to BSD's.
#
# Resolving the name once, here, lets every call site keep its GNU flags
# instead of growing a second BSD spelling that nobody on Linux would ever
# exercise -- and an unexercised portability branch is a bug waiting for the
# one person who runs it.
#
# The bare name is the last resort, so Linux is unaffected and a macOS box
# without coreutils fails at fs_require_gnu_tools with a sentence rather than
# at a call site with "illegal option -- m".
FS_REALPATH="realpath"
FS_SORT="sort"
FS_STAT="stat"
FS_TIMEOUT="timeout"

_fs_resolve_gnu_tool() {
    local name="$1" cand out
    for cand in "g$name" "$name"; do
        command -v "$cand" >/dev/null 2>&1 || continue
        # Capture rather than pipe: `--version | grep -q` gives the producer
        # SIGPIPE, and pipefail would then report a match as a failure.
        out="$("$cand" --version 2>/dev/null)" || out=""
        case "$out" in
            *"GNU coreutils"*) printf '%s\n' "$cand"; return 0 ;;
        esac
    done
    return 1
}

# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_REALPATH="$(_fs_resolve_gnu_tool realpath || echo realpath)"
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_SORT="$(_fs_resolve_gnu_tool sort || echo sort)"
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_STAT="$(_fs_resolve_gnu_tool stat || echo stat)"
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_TIMEOUT="$(_fs_resolve_gnu_tool timeout || echo timeout)"

# Say so once, early, in words. Call this from an entry script before anything
# is created; the failure otherwise lands mid-run as an unknown-option error
# from a tool the reader has no reason to suspect.
fs_require_gnu_tools() {
    local tool missing=()
    for tool in realpath sort stat timeout; do
        _fs_resolve_gnu_tool "$tool" >/dev/null || missing+=("$tool")
    done
    if (( ${#missing[@]} )); then
        echo "Error: no GNU ${missing[*]} on PATH. These scripts use GNU flags" >&2
        echo "(realpath -m, sort -V, stat -c) that the BSD tools of the same" >&2
        echo "name do not have, and timeout, which macOS does not ship. All four" >&2
        echo "come from one package. On macOS: brew install coreutils" >&2
        return 1
    fi
    return 0
}

# A report is usable only when the verdict has exactly one Report heading and
# non-whitespace content after it. Keep this decision in one place because
# status display and summary provenance must describe the same report.
fs_verdict_has_usable_report() {
    local verdict="$1"
    awk '
        $0 == "## Report" { headings++; in_report = 1; next }
        in_report && /[^[:space:]]/ { usable = 1 }
        END { exit !(headings == 1 && usable) }' "$verdict" 2>/dev/null
}

# The artifact outbox's size budget, shared by every path that enforces or
# reports it: fork-sandbox-k8s.sh's own pull-back cap, the default handed to
# fork-sandbox-k8s-outbox-extract.sh when it is invoked without an explicit
# third argument, the local run's end-of-run check in fork-sandbox.sh, and
# the number fs_emit_prompt_preamble tells the agent about below. One
# constant, so the four of them cannot drift apart.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_OUTBOX_MAX_BYTES=$((64 * 1024 * 1024))   # 64 MiB

# Parses a --outbox-max argument into a byte count on stdout: bare digits
# mean bytes, and a K/M/G suffix means that many KiB/MiB/GiB, consistent
# with the 1024-based arithmetic FS_OUTBOX_MAX_BYTES above already uses.
# Rejects everything else -- decimals, negatives, a bare suffix, empty, and
# 0 (with or without a suffix), all with a message naming what was given --
# so a typo is caught here, before --outbox-max's caller creates anything,
# rather than surfacing later as a cap silently equal to 0.
fs_parse_size_bytes() {
    local input="$1" digits suffix
    if [[ "$input" =~ ^([0-9]+)([KkMmGg])$ ]]; then
        digits="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        digits="$input"
        suffix=""
    else
        echo "Error: invalid size '$input' -- expected a byte count or a" >&2
        echo "number followed by K, M or G, e.g. 512K, 256M, 2G, 1048576" >&2
        return 1
    fi
    if (( 10#$digits == 0 )); then
        echo "Error: size '$input' must be greater than zero" >&2
        return 1
    fi
    case "$suffix" in
        K|k) echo $(( 10#$digits * 1024 )) ;;
        M|m) echo $(( 10#$digits * 1024 * 1024 )) ;;
        G|g) echo $(( 10#$digits * 1024 * 1024 * 1024 )) ;;
        *)   echo $(( 10#$digits )) ;;
    esac
}

# claude-sandboxed must exist before anything is created. Resolve it here
# rather than let it fail inside a tmux pane: the pane closes when its
# command exits, so the error would flash past and the fork would look like
# it silently did nothing.
fs_require_sandbox_wrapper() {
    if command -v claude-sandboxed >/dev/null; then
        return 0
    fi
    if [[ -x "$HOME/.claude/scripts/claude-sandboxed" ]]; then
        return 0
    fi
    echo "Error: this needs claude-sandboxed on PATH." >&2
    echo "Run install.sh in the fork-sandbox repo." >&2
    return 1
}

# Refuse a value that would break out of a generated command or a key=value
# record. A single quote ends the shell string these scripts build, and a
# newline ends a line in the run record that fork-sandbox-status.sh reads
# back. Check the inputs rather than the built string, which quotes on
# purpose. Check before anything is created, so a bad name cannot leave a
# clone behind on the way out.
fs_reject_unsafe_chars() {
    local v
    for v in "$@"; do
        if [[ "$v" == *"'"* ]]; then
            echo "Error: a path or argument contains a single quote, which would" >&2
            echo "break out of the shell command this script builds. Rename it." >&2
            return 1
        fi
        if [[ "$v" == *$'\n'* ]]; then
            echo "Error: a path or argument contains a newline, which would break" >&2
            echo "the run record this script writes. Rename it." >&2
            return 1
        fi
    done
    return 0
}

# Reads one NAME=VALUE line from an env file, first match wins. This is the
# same first-match, never-`source`d contract fork-sandbox-k8s.sh's own
# read_env_value applies to k8s.env and pi.env -- kept as a second, identical
# copy rather than a shared call, because fork-sandbox-configure's target
# table (fork-sandbox.sh) and the Kubernetes run path (fork-sandbox-k8s.sh)
# are reviewed as separate surfaces, and this repo does not import behavior
# across that boundary. If one changes, check the other.
fs_read_env_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

# Masks a secret down to its last 4 characters, for display anywhere a value
# might otherwise leak: a TUI listing, a --dry-run render, a --remove
# confirmation. `fork-sandbox.sh configure`'s discoverer protocol (see
# docs/configure.md) requires every discoverer to mask a secret candidate's
# `display` field with exactly this shape before it is ever printed, so the
# format is fixed here rather than left to each discoverer to invent.
fs_mask_secret() {
    local v="$1"
    if (( ${#v} <= 4 )); then
        printf '…%s' "$v"
    else
        printf '…%s' "${v: -4}"
    fi
}

# Print the top level of the repository holding a path.
fs_repo_toplevel() {
    local path="$1"
    if ! (cd "$path" && git rev-parse --show-toplevel) 2>/dev/null; then
        echo "Error: '$path' is not in a git repository." >&2
        echo "A sandboxed fork works in a clone, so the target must be a repo." >&2
        return 1
    fi
    return 0
}

# The branch has to be new. An existing one fails twice over: the clone
# already carries it, so creating it there dies immediately, and git refuses
# to fetch into a branch that is checked out. Catching it here beats catching
# it when the session ends, hours later, with nowhere to put the work.
fs_check_branch_free() {
    local repo="$1" branch="$2"
    if (cd "$repo" && git show-ref --verify --quiet "refs/heads/$branch"); then
        echo "Error: branch '$branch' already exists in $repo." >&2
        echo "Sandboxed forks commit on a new branch and fetch it back, so pick" >&2
        echo "a name that is free." >&2
        return 1
    fi
    return 0
}

# The two path constraints that let fork-sandbox.sh be blanket-approved as
# its own security boundary: the handoff becomes the prompt of a session with
# internet access, and the project is what gets cloned or pushed into a run,
# so neither is trusted as given -- both are checked against a fixed root.
# Shared so that every entry point fork-sandbox.sh grows for starting a run
# (a local sandboxed session, a --k8s dispatch) enforces the same rule rather
# than drifting: a second copy of a security check is exactly the kind of
# duplication that silently stops matching the first one.
fs_require_scratch_handoff() {
    local handoff_file="$1" real
    real="$("$FS_REALPATH" -m "$handoff_file")"
    if [[ "$real" != /var/tmp/claude-scratch/* && "$real" != /tmp/claude-scratch/* ]]; then
        echo "Error: handoff files must live under /var/tmp/claude-scratch/ (or the" >&2
        echo "/tmp/claude-scratch compat symlink) — got '$real'. The handoff" >&2
        echo "becomes the prompt of a session with internet access, so this path is a" >&2
        echo "security boundary, not a tidiness rule. Stage the document there and" >&2
        echo "rerun." >&2
        return 1
    fi
    # forks/ is excluded: it holds what approved scripts mktemp -- run dirs,
    # stage dirs, and the codex credential staging dir. A handoff there would
    # read a file the machinery wrote (the credential above all) into the
    # prompt of a session with internet access. Handoffs go in the scratch root.
    if [[ "$real" == /var/tmp/claude-scratch/forks/* || "$real" == /tmp/claude-scratch/forks/* ]]; then
        echo "Error: handoff files must not live under the forks/ machinery" >&2
        echo "directory — got '$real'. forks/ holds run dirs, staging" >&2
        echo "dirs and credential files that approved scripts create; reading one" >&2
        echo "into an internet-connected prompt is the exfiltration this check" >&2
        echo "exists to stop. Stage the handoff in the scratch root itself." >&2
        return 1
    fi
    return 0
}

# Validate a directory that will be bound or persisted read-write into an
# unattended sandbox: refuse a symlink (a symlink checked here and resolved
# later is a different directory from the one that gets used), require it to
# resolve under /var/tmp/claude-scratch/ or the /tmp/claude-scratch compat
# path (both spellings, for the same reason fs_require_scratch_handoff and
# the mail root's own startup check accept both), and refuse a path that
# exists as something other than a directory. Prints the resolved realpath on
# success. Shared by --session-state and --clone-dir, which both hand an
# unattended session a directory to write into, so where either may point is
# the same security boundary.
fs_validate_scratch_dir() {
    local path="$1" flag="$2" real
    if [[ -L "$path" ]]; then
        echo "Error: $flag '$path' is a symlink. Name the directory itself:" >&2
        echo "a symlink checked here and resolved later is a different" >&2
        echo "directory from the one that gets used." >&2
        return 1
    fi
    real="$("$FS_REALPATH" -m "$path")"
    if [[ "$real" != /var/tmp/claude-scratch/* && "$real" != /tmp/claude-scratch/* ]]; then
        echo "Error: $flag must name a directory under" >&2
        echo "/var/tmp/claude-scratch/ (or the /tmp/claude-scratch compat" >&2
        echo "path) — got '$real'. The directory is written to from inside an" >&2
        echo "unattended session, so which paths may be handed over is a" >&2
        echo "security boundary, not a tidiness rule." >&2
        return 1
    fi
    if [[ -e "$real" && ! -d "$real" ]]; then
        echo "Error: $flag '$real' exists and is not a directory." >&2
        return 1
    fi
    printf '%s\n' "$real"
    return 0
}

# Validate --session-state, --resume-session and --session-id together, the
# same rules regardless of whether the run ends up local or on --k8s: a
# caller asking what a run would do (--dry-run, or a --k8s submit that fails
# before a Job exists) must be told the flag is refused with the identical
# message either path would give. Nothing is CREATED here -- the mkdir
# waits until after the caller's own dry-run exit, if it has one.
#
# Which harnesses accept these at all, and which of --resume-session /
# --session-id apply, comes from the capability table rather than a
# harness-name check here: fs_harness_session_caps is the one place that
# knows claude and codex discover their id at run end while pi's is given up
# front.
#
# Prints the resolved --session-state directory (via fs_validate_scratch_dir)
# on success, empty when --session-state was not given. Returns 1 on any
# refusal, having already printed the error.
fs_validate_session_flags() {
    local harness="$1" session_state="$2" resume_session="$3" session_id_arg="$4"

    fs_harness_session_caps "$harness"
    if [[ -n "$session_state" || -n "$resume_session" || -n "$session_id_arg" ]]; then
        if [[ "$FS_HARNESS_RESUMABLE" != true ]]; then
            echo "Error: --session-state, --resume-session and --session-id all need" >&2
            echo "a harness with a session-resume capability; this run's harness is" >&2
            echo "'$harness', which has none." >&2
            return 1
        fi
    fi
    if [[ -n "$resume_session" && "$FS_HARNESS_ID_MODE" != discover ]]; then
        echo "Error: --resume-session names a session id to discover-then-resume," >&2
        echo "which harness '$harness' does not do. Use --session-id instead if" >&2
        echo "the harness takes one." >&2
        return 1
    fi
    if [[ -n "$session_id_arg" && "$FS_HARNESS_ID_MODE" != given ]]; then
        echo "Error: --session-id supplies an id for a harness with nothing to" >&2
        echo "discover; harness '$harness' discovers its id instead. Use" >&2
        echo "--resume-session instead if the harness takes one." >&2
        return 1
    fi
    if [[ -n "$resume_session" && -z "$session_state" ]]; then
        echo "Error: --resume-session requires --session-state. The session to be" >&2
        echo "resumed is read out of that directory; with no bind there is no" >&2
        echo "transcript inside the sandbox to resume from." >&2
        return 1
    fi
    if [[ -n "$session_id_arg" && -z "$session_state" ]]; then
        echo "Error: --session-id requires --session-state. The id names a session" >&2
        echo "inside that directory; with no bind there is nowhere for it to live." >&2
        return 1
    fi
    if [[ -n "$resume_session" && ! "$resume_session" =~ ^[0-9a-f][0-9a-f-]{7,63}$ ]]; then
        echo "Error: --resume-session '$resume_session' is not a session id. It is" >&2
        echo "used as a transcript filename stem, so it must match" >&2
        echo "^[0-9a-f][0-9a-f-]{7,63}\$ — no slashes, no dots, no leading hyphen," >&2
        echo "no other characters." >&2
        return 1
    fi
    if [[ -n "$session_id_arg" && ! "$session_id_arg" =~ ^[0-9a-f][0-9a-f-]{7,63}$ ]]; then
        echo "Error: --session-id '$session_id_arg' is not a session id. It is" >&2
        echo "used as a directory/filename component, so it must match" >&2
        echo "^[0-9a-f][0-9a-f-]{7,63}\$ — no slashes, no dots, no leading hyphen," >&2
        echo "no other characters." >&2
        return 1
    fi
    if [[ -n "$session_state" ]]; then
        # The bind is read-WRITE and the sandbox is unattended, so where it
        # may point is a security boundary of the same kind --context-ro
        # enforces — and a wider one, because this one grants write. The
        # prefix is the scratch root rather than forks/: callers that keep
        # durable per-agent state (the postmaster, under the mail root) live
        # beside forks/, not in it. Shared with --clone-dir, which grants the
        # same kind of write access for a different directory.
        session_state="$(fs_validate_scratch_dir "$session_state" --session-state)" || return 1
    fi
    printf '%s' "$session_state"
    return 0
}

# Reuse an existing --clone-dir clone for a new wake instead of making a
# fresh one: fetch from its origin remote (named 'origin' -- fs_make_clone
# never passes git clone a -o, so this is git's own default), then start a
# new branch there.
#
# checkout_ref, when non-empty, PINS the start point at checkout_sha,
# exactly as a fresh fs_make_clone would -- the caller asked for that
# specific ref, and a reused clone's own history does not get to override
# that just because it happens to have one. Without --checkout, the new
# branch starts at the clone's own current HEAD -- the previous wake's
# branch tip -- so commits made on earlier wakes are reachable from the new
# branch's history directly, not just as a remote-tracking ref. A clone with
# no commits at all (HEAD unresolvable -- in practice only a --clone-dir
# target the caller `git init`'d empty, since every real prior wake leaves
# at least the origin's own history) falls back to checkout_sha too, exactly
# as a fresh fs_make_clone would.
#
# Prints the sha the branch actually started from on success, so the caller
# can rebase its own commit accounting and loop guards on the commit this
# wake's branch really started at, rather than on whatever base_sha meant
# before it was known this clone would be reused.
#
# No identity-seeding here, unlike fs_make_clone: a reused clone already has
# repo-local user.name/user.email from when it was first created.
fs_reuse_clone() {
    local dest="$1" branch="$2" checkout_ref="$3" checkout_sha="${4:-}" start_sha
    git -C "$dest" fetch origin --quiet || return 1
    if [[ -n "$checkout_ref" ]]; then
        start_sha="$checkout_sha"
    elif ! start_sha="$(git -C "$dest" rev-parse --verify --quiet HEAD)"; then
        start_sha="$checkout_sha"
    fi
    git -C "$dest" checkout --quiet -b "$branch" ${start_sha:+"$start_sha"} || return 1
    # A workspace created before dissociate-on-create existed (or otherwise
    # still --shared) reads its history through objects/info/alternates for
    # as long as it persists, which is exactly the corruption hazard
    # fs_make_clone's own "true" branch exists to close off: the operator can
    # delete a landed wake branch and its origin ref, `git gc --prune=now`
    # the origin, and strand this workspace's history with no way back. Close
    # it here too, the first time a pre-existing workspace is reused, rather
    # than only on workspaces fs_make_clone dissociated at creation.
    if [[ -e "$dest/.git/objects/info/alternates" ]]; then
        git -C "$dest" repack -a -d --quiet || return 1
        rm -f "$dest/.git/objects/info/alternates"
    fi
    printf '%s\n' "$start_sha"
    return 0
}

# Acquire the persistent-workspace lock at $1/.git/fork-sandbox-lock and set
# the global clone_lock_fd, or print the standard refusal and exit. Under
# .git, not the working tree: the pi session dir, the review verdict and
# .env.sandbox all live under .git for the same reason -- git tracks nothing
# there, so a leg running `git add -A` cannot commit the lock file onto the
# branch that gets fetched home, and a `git clean -fdx` cannot unlink it out
# from under a still-live holder. Shared by the launcher (fork-sandbox.sh),
# which holds it only while it sets up the workspace, and the generated
# runner, which reacquires it fresh as its own first action so the lock's
# lifetime matches the run rather than the launcher or tmux -- see both
# call sites for why a single acquisition cannot simply be handed down.
fs_lock_clone_dir() {
    local dir="$1"
    exec {clone_lock_fd}<>"$dir/.git/fork-sandbox-lock"
    if ! flock -n "$clone_lock_fd"; then
        echo "Error: workspace '$dir' is locked by another run --" >&2
        echo "refusing to start." >&2
        exit 1
    fi
}

# ---- postmaster state shared with fork-sandbox-fleet.sh's teardown verb ----
#
# fork-sandbox-postmaster.sh and fleet.sh's `teardown` both need the
# postmaster's on-disk layout and its "is a (thread, agent) seat live"
# predicate. teardown deliberately does not source the postmaster script
# itself (that would also pull in its usage()/dispatch), so the pieces both
# sides need live here instead, as the one shared surface. They started out
# as verbatim copies in both scripts, and copies of a liveness rule that
# guards an rm -rf are exactly the kind that must not drift apart.

# Sets the postmaster's on-disk state paths as globals: MAIL_ROOT, STATE,
# LOCK_FILE, RUNS, HARVESTED, PM_SESSION_STATE, PM_SESSIONS, PM_WORKSPACES.
# A caller with its own additional paths under STATE (fork-sandbox-postmaster.sh
# has several) sets those itself, after calling this.
fs_pm_state_paths() {
    MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"
    STATE="$MAIL_ROOT/.postmaster"
    # shellcheck disable=SC2034  # written here, read by the sourcing scripts
    LOCK_FILE="$STATE/lock"
    RUNS="$STATE/runs"
    HARVESTED="$STATE/harvested"
    # shellcheck disable=SC2034  # written here, read by the sourcing scripts
    PM_SESSION_STATE="$STATE/state"
    # shellcheck disable=SC2034  # written here, read by the sourcing scripts
    PM_SESSIONS="$STATE/sessions"
    # shellcheck disable=SC2034  # written here, read by the sourcing scripts
    PM_WORKSPACES="$STATE/workspaces"
}

# Reads one NAME=VALUE line from a run's *.env file, last match wins (a
# record is appended to, never rewritten in place, so the last line is the
# current value). Deliberately not fs_read_env_value above: that helper is
# first-match-wins and is its own copy for a different, unrelated surface
# (fork-sandbox-configure's target table and the Kubernetes run path) — this
# one is the postmaster's run-record format specifically.
fs_pm_env_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n1
}

# Prints a live run's id for (agent, tid) against $RUNS/$HARVESTED (set by
# fs_pm_state_paths) and returns 0, or returns 1.
fs_pm_find_live_run() {
    local agent="$1" tid="$2" f rid a t
    for f in "$RUNS"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$HARVESTED/$rid" ]] && continue
        a="$(fs_pm_env_get "$f" AGENT)"
        t="$(fs_pm_env_get "$f" THREAD)"
        if [[ "$a" == "$agent" && "$t" == "$tid" ]]; then
            printf '%s' "$rid"
            return 0
        fi
    done
    return 1
}

fs_require_src_project() {
    local project_path="$1" real
    real="$("$FS_REALPATH" -m "$project_path")"
    if [[ "$real" != "$HOME"/src/* && "$real" != "$HOME/src" ]]; then
        echo "Error: the project must live under ~/src — got '$real'." >&2
        echo "An unattended agent gets the whole clone, and for most harnesses it" >&2
        echo "gets internet too, so which repos may be handed over is a security" >&2
        echo "boundary. Work from a checkout under ~/src, or launch" >&2
        echo "claude-sandboxed by hand for something else." >&2
        return 1
    fi
    return 0
}

fs_warn_if_dirty() {
    local path="$1" repo="$2"
    if [[ -n "$(cd "$path" && git status --porcelain)" ]]; then
        echo "Warning: '$repo' has uncommitted changes. A clone carries" >&2
        echo "committed state only, so the session will not see them." >&2
    fi
}

# --shared keeps this cheap on a large repo: the clone stores no objects of
# its own and reads history through objects/info/alternates. Never let git
# use its default local clone, which hardlinks the object files — the sandbox
# could then corrupt the real repo's objects by writing through a link.
# Clone the top level, not a subdirectory: git clone rejects a path that is
# merely inside a repository.
#
# A fourth argument starts the branch at that commit instead of at the clone's
# HEAD. Pass a full sha, not a ref name: a clone copies refs/heads and
# refs/tags only, so a commit the source repo keeps under its own ref
# namespace — a fetched pull request head, say — has no name here. The object
# is still readable through the alternates, so a sha resolves.
#
# A fifth argument, "true", dissociates the clone from the origin's object
# store right after creation: `git repack -a -d` pulls every reachable object
# (including everything read through alternates so far) into a pack local to
# this clone, then the alternates file is removed so nothing here can read
# the origin's store again. --shared is free speed for a clone that dies with
# the run, but a persistent --clone-dir workspace lives for as long as its
# seat does — long enough for the operator to delete a landed wake branch in
# the origin and `git gc` to prune the objects behind it, which would leave
# this workspace's history dangling with no way back. The caller passes true
# only when creating a NEW persistent workspace (never on the throwaway path;
# a --clone-dir reuse does not go through fs_make_clone at all, so this flag
# does not apply there -- see fs_reuse_clone, which does its own equivalent
# dissociation for a workspace that predates this check); disk cost per seat
# is accepted.
fs_make_clone() {
    local repo="$1" branch="$2" dest="$3" start_sha="${4:-}" dissociate="${5:-false}" key value
    git clone --shared --quiet "$repo" "$dest" || return 1
    (cd "$dest" && git checkout --quiet -b "$branch" ${start_sha:+"$start_sha"}) || return 1
    if [[ "$dissociate" == true ]]; then
        git -C "$dest" repack -a -d --quiet || return 1
        rm -f "$dest/.git/objects/info/alternates"
    fi
    # Carry the origin's identity across. git clone copies no repo-local
    # config, so a repo whose user.email is a local override — a work address
    # on a machine whose ~/.gitconfig holds a personal one — leaves the clone
    # with no identity of its own, and every commit the sandbox makes is
    # authored by the global address fs_gitconfig_bind mounts inside. Nothing
    # downstream catches that: integration re-creates the commits on the host,
    # and cherry-pick and rebase deliberately KEEP the author while making a
    # new committer, so the wrong name survives all the way in. Signing does
    # self-heal that way; authorship does not.
    #
    # --get reads the value git would actually use, so this is right whether
    # the override is repo-local, per-worktree, or an includeIf conditional
    # include — reading --global, or a config file by hand, would miss exactly
    # the case this fixes. It lands in the clone's own repo-local config,
    # which outranks the global copy bound at $HOME/.gitconfig inside. Name
    # and address only: signing keys stay out, because the sandbox holds no
    # ssh key to sign with and fs_gitconfig_bind switches signing off for
    # that reason. A repo with no override seeds the value the global copy
    # already carries, and a machine with no identity configured seeds
    # nothing — both silent, both no-ops.
    #
    # Running git in the clone is safe HERE, though the fork-sandbox and
    # sandbox-coder-mode skills tell callers never to do it: that rule guards
    # against a clone the sandbox has written, which can carry a
    # core.fsmonitor that then executes on the host. This is creation time.
    # The sandbox has not started, and the config is still only ours.
    for key in user.name user.email; do
        value="$( (cd "$repo" && git config --get "$key") 2>/dev/null || true )"
        [[ -n "$value" ]] || continue
        (cd "$dest" && git config "$key" "$value") || true
    done
    # claude-sandboxed rescues its transcript to claude-session/ in the work
    # dir on exit (see its own cleanup trap) -- in the working tree, not
    # under .git, because it is written from outside this repo's knowledge
    # entirely. A leg that runs `git add -A` would otherwise commit another
    # leg's full transcript onto the branch that gets fetched into the
    # user's own repo. .git/info/exclude is local to this clone and never
    # committed itself, unlike a tracked .gitignore would be, and it is
    # written once here rather than by claude-sandboxed itself so it is in
    # place before the first sandbox ever runs.
    if ! grep -qxF 'claude-session/' "$dest/.git/info/exclude" 2>/dev/null; then
        printf 'claude-session/\n' >> "$dest/.git/info/exclude"
    fi
    return 0
}

# Provision a node project into the clone, so the suites a handoff asks
# for can actually run. Committed state has no node_modules, and the
# sandbox's $HOME is a fresh tmpfs, so nvm's node is invisible there —
# without this a node repo gets /usr/bin/node at whatever version the host
# package manager last installed, and no npm at all.
#   - .nvmrc names the version; FS_NODE_FLAGS asks claude-sandboxed to
#     bind that exact install read-only and put its bin first on PATH.
#     Only a plain dotted version is accepted: an alias such as lts/iron
#     has no directory under ~/.nvm/versions, and the value ends up inside
#     a generated shell command, so anything else is refused, not quoted.
#   - node_modules is COPIED, never hardlinked: the clone is writable and
#     hardlinks share inodes, so cp -al would hand the sandbox write
#     access to the host's own files.
# Both halves are no-ops in a repo without them. Fills FS_NODE_FLAGS; the
# caller formats it for its own use, like FS_ALTERNATES.
#
# A fourth argument, "true" on a reused --clone-dir workspace, says the
# destination may already hold a PREVIOUS wake's node_modules. `cp -a` into
# an existing directory copies the source inside it rather than replacing
# it, so without this a reused clone keeps wake 1's tree forever, nested
# one level deeper on every later wake, however much origin's own
# node_modules moved on in between. A fresh clone never has one at this
# point, so the reused tree is removed first to put both paths at parity.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_NODE_FLAGS=()

fs_node_provision() {
    local origin_repo="$1" clone_dir="$2" reused="${3:-false}" ver dir native count nm
    local path base rel selected_nvmrc="" selected_rel="" candidate_ver idx
    local -a shown project_paths project_rels matching_installs
    FS_NODE_FLAGS=()
    # A reused clone can retain an untracked dependency tree after the new
    # checkout removes that project's package.json (or all its tracked files).
    # Clean the bounded set of locations we provision before discovering the
    # projects that exist in the origin now.
    if [[ "$reused" == true ]]; then
        [[ ! -e "$clone_dir/node_modules" ]] || rm -rf "$clone_dir/node_modules"
        for dir in "$clone_dir"/*/node_modules; do
            [[ -e "$dir" ]] || continue
            rm -rf "$dir"
        done
    fi
    project_paths=("$origin_repo")
    project_rels=("")
    # A node project is commonly one layer below a non-node backend. Keep the
    # search deliberately bounded: root plus non-hidden immediate children.
    for path in "$origin_repo"/*; do
        [[ -d "$path" && -f "$path/package.json" ]] || continue
        base="${path##*/}"
        [[ "$base" == node_modules || "$base" == .git || "$base" == .* ]] && continue
        project_paths+=("$path")
        project_rels+=("$base")
    done

    if [[ -f "$origin_repo/.nvmrc" ]]; then
        selected_nvmrc="$origin_repo/.nvmrc"
    else
        for (( idx = 1; idx < ${#project_paths[@]}; idx++ )); do
            path="${project_paths[$idx]}"
            [[ -f "$path/.nvmrc" ]] || continue
            candidate_ver="$(tr -d 'v[:space:]' < "$path/.nvmrc")"
            if [[ -z "$selected_nvmrc" ]]; then
                selected_nvmrc="$path/.nvmrc"
                selected_rel="${project_rels[$idx]}"
                ver="$candidate_ver"
            elif [[ "$candidate_ver" != "$ver" ]]; then
                echo "Warning: node subprojects '$selected_rel' (v$ver) and" >&2
                echo "'${project_rels[$idx]}' (v$candidate_ver) request different node versions; using '$selected_rel' (v$ver)." >&2
            fi
        done
    fi
    if [[ -n "$selected_nvmrc" ]]; then
        ver="$(tr -d 'v[:space:]' < "$selected_nvmrc")"
        dir="$HOME/.nvm/versions/node/v$ver"
        if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
            # The bind names a host node install, and the sandbox's userland
            # is the image's. Say which version was asked for and not honoured
            # rather than let a version mismatch surface as a mystery later.
            echo "Note: .nvmrc asks for node v$ver, but this backend brings its" >&2
            echo "own userland, so the image's node is what the run gets." >&2
        elif [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo "Warning: .nvmrc says '$ver', which is not a plain version" >&2
            echo "number. The sandbox falls back to system node." >&2
        else
            if [[ ! -d "$dir" ]]; then
                matching_installs=()
                for path in "$HOME/.nvm/versions/node/v$ver".*; do
                    base="${path##*/}"
                    [[ -d "$path" && "$base" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || continue
                    matching_installs+=("$path")
                done
                if (( ${#matching_installs[@]} > 0 )); then
                    dir="$(printf '%s\n' "${matching_installs[@]}" | "$FS_SORT" -V | tail -n 1)"
                fi
            fi
            if [[ -d "$dir" ]]; then
                # shellcheck disable=SC2034  # read by the sourcing scripts
                FS_NODE_FLAGS=(--bind-ro "$dir" --prepend-path "$dir/bin")
            else
                echo "Warning: .nvmrc wants node v$ver, which is not installed" >&2
                echo "under ~/.nvm. The sandbox falls back to system node." >&2
            fi
        fi
    fi
    for (( idx = 0; idx < ${#project_paths[@]}; idx++ )); do
        path="${project_paths[$idx]}"
        rel="${project_rels[$idx]}"
        if [[ -n "$rel" ]]; then
            dir="$clone_dir/$rel/node_modules"
        else
            dir="$clone_dir/node_modules"
        fi
        [[ -d "$path/node_modules" ]] || continue
        # The origin working tree can differ from the ref checked out in the
        # clone. Do not recreate a subproject that the requested ref removed.
        [[ -z "$rel" || -f "$clone_dir/$rel/package.json" ]] || continue
        echo "Copying node_modules into the clone..." >&2
        cp -a "$path/node_modules" "$dir"
        # Nearly all of that tree is JavaScript and runs anywhere. A few
        # packages also carry a compiled .node, built for one OS and one CPU.
        # Under a host toolchain those are the right binaries. Under an image
        # they are not -- a different Linux, or on a Mac a different operating
        # system -- and the failure is a throw from deep inside node with
        # nothing to say the platform is the reason. So name them here.
        # Collect the whole list before counting: `find | head` would take
        # SIGPIPE, and pipefail would turn that into a failed provision.
        if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
            native="$(find "$dir" -type f -name '*.node' 2>/dev/null || true)"
            if [[ -n "$native" ]]; then
                count=0
                shown=()
                while IFS= read -r nm; do
                    count=$(( count + 1 ))
                    (( count <= 3 )) && shown+=("${nm#"$clone_dir/"}")
                done <<< "$native"
                echo "Warning: node_modules holds $count compiled native module(s)," >&2
                echo "built for THIS host. The sandbox's userland comes from its" >&2
                echo "image, so requiring one of these fails inside node:" >&2
                printf '  %s\n' "${shown[@]}" >&2
                (( count > 3 )) && echo "  ... and $(( count - 3 )) more" >&2
                echo "Run 'npm rebuild' (or 'npm ci') inside the sandbox to fix it." >&2
            fi
        fi
    done
    return 0
}

# Provision the untracked paths a repo names in its sandbox-services provision-ro
# (.agents/sandbox-services/, or the legacy .claude/sandbox-services/), so a
# copied clone can still run the
# suites that need them. A clone carries committed state only: no .venv, no
# untracked build output. Each line of provision-ro is a repo-relative path;
# it is bound READ-ONLY from the origin repo into the clone at the same
# relative path, so tools find it where they expect it. Read-only because the
# sandbox must never write back into the user's real checkout. A relocated
# virtualenv still runs — .venv/bin/python is a symlink and sys.prefix follows
# the binary's own path.
#
# Each entry is bound a SECOND time, at the origin's own absolute path, because
# a relocated venv's console scripts are not relocatable: pip writes the origin
# interpreter into every shebang, so .venv/bin/black starts
# '#!/home/you/src/proj/.venv/bin/python' and dies with "bad interpreter" in a
# sandbox that only has the clone's copy. The second mount makes that literal
# path resolve, so `.venv/bin/<tool>` works without every project having to
# teach its agents to say `.venv/bin/python -m <tool>` instead. It costs no new
# exposure: same bytes, same read-only flag, a second mountpoint on content the
# sandbox can already read at the clone path.
#
# This is a security boundary, not a convenience. The provision-ro file is
# committed content, and for a pull-request review it can be attacker-authored.
# A malicious entry must not turn into an arbitrary host-file read: the bind
# rides into a sandbox with internet access. So every entry is checked — no
# absolute path, no '..', and both the resolved source and the resolved
# destination must stay inside the repo they belong to. A symlink that escapes
# is refused, not followed. Fills FS_PROVISION_RO_FLAGS with claude-sandboxed
# flags — --bind-ro-at pairs, plus a --prepend-path for a venv's bin; a repo
# without the file leaves it empty.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PROVISION_RO_FLAGS=()

# The sandbox-services contract lives in one directory per repo. Prefer the
# agent-neutral .agents/sandbox-services (the current location, shared by every
# agent that runs a sealed session); fall back to .claude/sandbox-services (the
# original path, still used by repos not yet migrated). The choice is by which
# directory actually HOLDS a contract file — the sandbox-services.sh hook or a
# provision-ro list — not by mere directory existence: an empty or partial
# .agents/sandbox-services left by a half-finished migration must not shadow a
# real .claude/sandbox-services. .agents still wins when both hold one. (Both
# files are checked, not just the hook, because a Level-1 repo ships only
# provision-ro and no hook.) When neither directory holds a contract, echo the
# .agents path — the current location — so the caller's own -d/-f guard reports
# "no contract" and any error names where to put one. Callers must source this
# library first, which fork-sandbox.sh and agent-sandboxed both do.
fs_services_dir() {
    local root="$1" d
    for d in "$root/.agents/sandbox-services" "$root/.claude/sandbox-services"; do
        if [[ -f "$d/sandbox-services.sh" || -f "$d/provision-ro" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    printf '%s\n' "$root/.agents/sandbox-services"
}

fs_provision_ro() {
    local origin_repo="$1" clone_dir="$2" list rel src dest src_real dest_real
    local origin_real clone_real
    FS_PROVISION_RO_FLAGS=()
    list="$(fs_services_dir "$clone_dir")/provision-ro"
    [[ -f "$list" ]] || return 0
    origin_real="$("$FS_REALPATH" -m "$origin_repo")"
    clone_real="$("$FS_REALPATH" -m "$clone_dir")"
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        # Trim surrounding whitespace. A line whose first non-blank character
        # is '#' is a comment; a '#' anywhere else is part of the path — an
        # inline-comment rule would silently truncate a path that contains one.
        rel="${rel#"${rel%%[![:space:]]*}"}"
        rel="${rel%"${rel##*[![:space:]]}"}"
        [[ -n "$rel" ]] || continue
        [[ "$rel" == \#* ]] && continue
        # Syntactic refusals first: an absolute path or a '..' component would
        # name something outside the repo before any symlink is even resolved.
        # Wrapping in slashes makes the match component-accurate, so a name
        # that merely starts with '..' ('..store', say) is not refused.
        if [[ "$rel" == /* || "/$rel/" == *"/../"* ]]; then
            echo "Warning: provision-ro entry '$rel' is not a repo-relative path" >&2
            echo "inside the repo; skipping it." >&2
            continue
        fi
        src="$origin_repo/$rel"
        dest="$clone_dir/$rel"
        if [[ ! -e "$src" ]]; then
            echo "Warning: provision-ro wants '$rel', which is not in the origin" >&2
            echo "repo. The session runs without it." >&2
            continue
        fi
        # Resolve symlinks and confirm both ends stay inside their repo. A
        # committed symlink pointing at /etc or ~/.ssh is refused here, so it
        # can never reach --bind-ro-at.
        src_real="$("$FS_REALPATH" -m "$src")"
        dest_real="$("$FS_REALPATH" -m "$dest")"
        if [[ "$src_real" != "$origin_real"/* ]]; then
            echo "Warning: provision-ro entry '$rel' resolves outside the repo" >&2
            echo "($src_real); refusing it." >&2
            continue
        fi
        if [[ "$dest_real" != "$clone_real"/* ]]; then
            echo "Warning: provision-ro entry '$rel' would mount outside the clone" >&2
            echo "($dest_real); refusing it." >&2
            continue
        fi
        # Pass the resolved source, so claude-sandboxed binds exactly what was
        # checked and not a symlink that could differ.
        FS_PROVISION_RO_FLAGS+=(--bind-ro-at "$src_real" "$dest_real")
        # The same content again at its origin path, so hardcoded console-script
        # shebangs resolve. Guarded on the two paths differing: a caller whose
        # clone IS the origin would otherwise emit a self-bind.
        if [[ "$src_real" != "$dest_real" ]]; then
            FS_PROVISION_RO_FLAGS+=(--bind-ro-at "$src_real" "$src_real")
        fi
        fs_venv_interpreter_bind "$src_real"
        fs_venv_bin_on_path "$src_real"
    done < "$list"
    return 0
}

# A provisioned virtualenv only runs if its interpreter is reachable inside
# the sandbox. A venv on the system python needs nothing (/usr is mounted),
# but uv and pyenv install interpreters under $HOME, which is a tmpfs inside:
# .venv/bin/python dangles, and every compiled extension in the venv is dead
# weight behind it. pyvenv.cfg names the interpreter's bin directory in
# `home =`; bind the interpreter prefix read-only at its own path when it
# lives in a recognized store.
#
# The store allowlist is deliberate. This is the one bind derived from
# UNTRACKED content (the venv is the user's working tree, not the repo's), so
# it must not become an arbitrary host-path read: only strict subdirectories
# of known interpreter stores qualify, checked after realpath so a symlink
# cannot point the bind elsewhere.
fs_venv_interpreter_bind() {
    local venv="$1" cfg home prefix store
    cfg="$venv/pyvenv.cfg"
    [[ -f "$cfg" ]] || return 0
    # An interpreter is an executable, so it can only be carried in when the
    # sandbox runs the host's userland. Under an image backend the bind would
    # deliver something the sandbox cannot execute; say so once, here, rather
    # than let .venv/bin/python fail as a format error.
    if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
        echo "Warning: the venv at '$venv' needs a host interpreter, which this" >&2
        echo "backend's sandbox cannot execute -- its userland comes from an" >&2
        echo "image. The venv will not run; the image must supply python." >&2
        return 0
    fi
    home="$(sed -nE 's/^home[[:space:]]*=[[:space:]]*//p' "$cfg" | head -n1)"
    [[ -n "$home" ]] || return 0
    home="$("$FS_REALPATH" -m "$home")"
    if [[ ! -d "$home" ]]; then
        echo "Warning: the venv at '$venv' names an interpreter home that does" >&2
        echo "not exist ($home). The venv will not run in the sandbox." >&2
        return 0
    fi
    case "$home" in
        /usr/*) return 0 ;;  # the system toolchain is already mounted
    esac
    prefix="$(dirname "$home")"
    for store in "$HOME/.local/share/uv/python" "$HOME/.pyenv/versions"; do
        if [[ "$prefix" == "$store"/* ]]; then
            echo "Binding the venv's interpreter read-only: $prefix" >&2
            FS_PROVISION_RO_FLAGS+=(--bind-ro-at "$prefix" "$prefix")
            return 0
        fi
    done
    echo "Warning: the venv at '$venv' runs an interpreter the sandbox cannot" >&2
    echo "see ($home), and it is not under a recognized interpreter store, so" >&2
    echo "it is NOT bound. The venv will not run in the sandbox." >&2
    return 0
}

# A provisioned venv is only useful if its tools can be FOUND, not just run.
# Nothing activates a venv inside the sandbox — $HOME is a tmpfs, so there is
# no shell profile and no VIRTUAL_ENV — which leaves bare `python` as the
# system interpreter and bare `black` as nothing at all. An agent then either
# rediscovers the venv and hand-prefixes .venv/bin/ onto every command, or
# concludes the tool is unavailable and skips the check.
#
# So put the venv's bin first on PATH, which is what activation does and all
# it needs to do here. The effect is that a sandbox looks like the activated
# shell the project's own docs are written for, and no repo has to spell out
# interpreter paths for the sandbox's benefit. This mirrors the node bin dir
# fork-sandbox.sh already prepends so a repo with no .nvmrc still has a node.
#
# The path prepended is the venv's own, on the host — not the clone's copy of
# it. claude-sandboxed checks every --prepend-path against the host filesystem,
# and a clone's .venv/bin does not exist there: it comes into being only when
# the bind lands, inside. The origin path passes that check, and the bind at
# the origin path — the one that makes console-script shebangs resolve — is
# exactly what makes it resolve inside too. The two travel together.
#
# The entry has to actually be a venv (pyvenv.cfg) with a bin dir. Host
# toolchain only: under an image backend the venv cannot execute at all —
# fs_venv_interpreter_bind has already warned — and putting its bin first
# would shadow the image's working python with a broken one.
fs_venv_bin_on_path() {
    local venv="$1"
    [[ -f "$venv/pyvenv.cfg" && -d "$venv/bin" ]] || return 0
    [[ "$FS_BACKEND_TOOLCHAIN" == host ]] || return 0
    FS_PROVISION_RO_FLAGS+=(--prepend-path "$venv/bin")
}

# The venv-interpreter binds for a REAL checkout, as agent-sandboxed needs them.
# fs_provision_ro exists for a CLONE, which carries committed state only, so it
# binds every untracked path provision-ro names from the origin into the clone.
# agent-sandboxed has no clone: its work dir is the user's own tree, so those
# untracked paths are already there and binding them again is at best redundant
# and at worst flips a writable one read-only. The one thing that is still
# missing is what lives OUTSIDE the tree — a uv or pyenv virtualenv's
# interpreter, since .venv/bin/python is a symlink into an interpreter store
# under $HOME and $HOME is a tmpfs in the sandbox. So read the same provision-ro
# list, but for each entry that is a venv do only the two things a present-but-
# inert venv still needs: bind its interpreter, and put its bin on PATH, since
# no more here than in a clone does anything activate it. A non-venv entry adds
# nothing. fs_venv_interpreter_bind keeps the store allowlist that makes this
# safe from an untracked source. Fills FS_PROVISION_RO_FLAGS; a repo without
# the file leaves it empty.
fs_workdir_venv_binds() {
    local work_dir="$1" list rel
    FS_PROVISION_RO_FLAGS=()
    list="$(fs_services_dir "$work_dir")/provision-ro"
    [[ -f "$list" ]] || return 0
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        # Same trim-and-comment handling as fs_provision_ro: a '#' only starts a
        # comment as the first non-blank character, so a path with a '#' in it
        # is not truncated.
        rel="${rel#"${rel%%[![:space:]]*}"}"
        rel="${rel%"${rel##*[![:space:]]}"}"
        [[ -n "$rel" ]] || continue
        [[ "$rel" == \#* ]] && continue
        # Keep the entry inside the tree. The interpreter bind itself is guarded
        # by fs_venv_interpreter_bind's store allowlist, but an entry that named
        # an absolute path or climbed out with '..' has no business here.
        if [[ "$rel" == /* || "/$rel/" == *"/../"* ]]; then
            echo "Warning: provision-ro entry '$rel' is not a repo-relative path;" >&2
            echo "skipping it." >&2
            continue
        fi
        [[ -e "$work_dir/$rel" ]] || continue
        fs_venv_interpreter_bind "$work_dir/$rel"
        # The tree's own venv is already at this path; it still needs to be on
        # PATH, for the same reason a clone's does — nothing activates it here.
        fs_venv_bin_on_path "$work_dir/$rel"
    done < "$list"
    return 0
}

# Collect the object stores the clone reads through, so they can be bound
# read-only. An alternates file names its stores directly, not transitively,
# so follow the chain: when the source repo is itself a --shared clone its
# store points on to another, and binding only the first leaves git in the
# sandbox with "bad object HEAD".
#
# Fills the FS_ALTERNATES array. The caller formats it for its own use.
FS_ALTERNATES=()

_fs_walk_alternates() {
    local objdir="$1" file line alt
    file="$objdir/info/alternates"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # An entry may be relative to the objects dir holding the file.
        [[ "$line" == /* ]] || line="$objdir/$line"
        alt="$("$FS_REALPATH" -m "$line")"
        [[ -d "$alt" ]] || continue
        # Stop on a repeat, so a cycle cannot spin forever.
        case " ${FS_ALTERNATES[*]-} " in *" $alt "*) continue ;; esac
        FS_ALTERNATES+=("$alt")
        _fs_walk_alternates "$alt"
    done < "$file"
}

fs_collect_alternates() {
    local clone="$1"
    FS_ALTERNATES=()
    _fs_walk_alternates "$clone/.git/objects"
}

# Find pi and the node that must run it, and work out what to bind so it
# still has its dependencies inside a sandbox. Two callers need this — the
# pi harnesses of fork-sandbox.sh and agent-sandboxed — and every step of it
# is a lesson already learned, so it lives here rather than in two copies.
#
# nvm is a shell function, so a non-interactive PATH usually has no node and
# no pi. Fall back to where a global npm install under nvm puts them; the
# last match of the glob wins, which is the newest version for the v1x/v2x
# names nvm creates.
#
# Resolve every part through symlinks before it becomes a mount. ~/.nvm/current
# is a symlink to the version directory, and pi's entry script resolves out of
# bin/ and into lib/node_modules — so a bin dir taken as written and a script
# taken as resolved name two different trees, and binding only what the first
# covers leaves node unable to find pi's dependencies.
#
# Under a backend that brings its own userland none of that applies: the host's
# pi and node cannot execute inside, the image supplies both, and pi is found
# on the sandbox's own PATH. That case fills the same variables with the
# nothing-to-bind answer, so a caller needs one branch and not five.
#
# Fills FS_PI_NODE (the interpreter), FS_PI_REAL (the entry script), FS_PI_ROOT
# (the one tree to bind), FS_PI_BIN_DIR (the directory for PATH), and
# FS_PI_ARGV0 (the words that start pi, whichever case applies). FS_PI_ROOT and
# FS_PI_BIN_DIR are EMPTY when there is nothing to bind or prepend; callers
# test that rather than testing the backend again.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_NODE=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_REAL=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_ROOT=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_BIN_DIR=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_ARGV0=()

fs_resolve_pi() {
    local pi_bin cand
    FS_PI_NODE=""; FS_PI_REAL=""; FS_PI_ROOT=""; FS_PI_BIN_DIR=""; FS_PI_ARGV0=()

    if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
        # Nothing to find, nothing to bind, nothing to put on PATH. pi is a
        # name the image resolves. Naming its node would be wrong here too:
        # the image's pi runs on the image's node, by its own shebang.
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_PI_REAL="pi"
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_PI_ARGV0=(pi)
        return 0
    fi

    pi_bin="$(command -v pi 2>/dev/null || true)"
    if [[ -z "$pi_bin" ]]; then
        for cand in "$HOME"/.nvm/versions/node/*/bin/pi; do
            [[ -x "$cand" ]] && pi_bin="$cand"
        done
    fi
    if [[ -z "$pi_bin" ]]; then
        echo "Error: cannot find pi. Install it with:" >&2
        echo "  npm install -g @earendil-works/pi-coding-agent" >&2
        return 1
    fi

    FS_PI_REAL="$(readlink -f "$pi_bin")"
    FS_PI_BIN_DIR="$(readlink -f "$(dirname "$pi_bin")")"
    FS_PI_ROOT="$(dirname "$FS_PI_BIN_DIR")"

    # pi is a node script whose shebang is `env node`, so running it by name
    # would take whatever node the sandbox PATH happens to offer — the
    # project's pinned one, from a different major version. Name its own node
    # instead, and let PATH stay the project's business.
    FS_PI_NODE="$FS_PI_BIN_DIR/node"
    if [[ ! -x "$FS_PI_NODE" ]]; then
        FS_PI_NODE="$(command -v node 2>/dev/null || true)"
    fi
    if [[ -z "$FS_PI_NODE" || ! -x "$FS_PI_NODE" ]]; then
        echo "Error: found pi at $pi_bin but no node to run it with." >&2
        return 1
    fi

    # One bind covers the lot: under nvm, bin/node and lib/node_modules/... are
    # both inside the version directory, so binding it carries pi's
    # dependencies too. Refuse the case it does not cover rather than guess at
    # a second mount — a guess that binds too little fails deep inside node, as
    # a missing package.
    if [[ "$FS_PI_REAL" != "$FS_PI_ROOT"/* ]]; then
        echo "Error: pi resolves to $FS_PI_REAL, which is outside its node" >&2
        echo "install at $FS_PI_ROOT. This binds that one tree into the" >&2
        echo "sandbox, so an install split across two would lose its" >&2
        echo "dependencies. Install pi with npm -g under nvm." >&2
        return 1
    fi
    # Every later use is the same words, so settle them once.
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_PI_ARGV0=("$FS_PI_NODE" "$FS_PI_REAL")
    return 0
}

# Per-harness session-resume capabilities, as a table rather than a scatter of
# harness-name checks: fork-sandbox.sh and the postmaster both consult this
# instead of ever testing a harness name themselves for session-resume logic.
# $1 is the harness name -- "claude", "codex" or "pi". "pi-local" (the
# sealed-network dispatch key fs_resolve_harness derives from harness "pi") is
# accepted too and treated identically to "pi", since it is the same CLI and
# the same --session-dir/--session-id contract, reached through
# agent-sandboxed's own --session-dir/--session-id wiring (see its header)
# instead of a direct exec -- the alias means a caller checking a harness it
# already has as "pi-local" gets the same answer "pi" would without
# re-deriving it first.
#
# Fills three globals rather than printing to stdout, exactly like
# FS_PI_ROOT/FS_PI_ARGV0 above -- a caller wants several of them at once, and
# command substitution cannot hand back an array.
#
#   FS_HARNESS_RESUMABLE  true or false.
#   FS_HARNESS_SESSION_ROOT
#                         the in-sandbox bind destination, as a literal
#                         string with an UNEXPANDED "$HOME" token -- e.g.
#                         '$HOME/.claude/projects', not the expansion of any
#                         particular $HOME. No caller expands it today --
#                         fork-sandbox.sh's own fs_build_sandbox_cmd hardcodes
#                         the same paths directly for codex and pi, the way
#                         claude-sandboxed hardcodes claude's -- so this is
#                         documentation of what those hardcoded paths must
#                         agree with, not a value read back at run time yet.
#                         Should a caller ever expand it: sandbox-backend-bwrap
#                         sets the sandboxed process's HOME to the exact value
#                         of the invoking script's own $HOME (--setenv HOME
#                         "$HOME", see sandbox-backend-bwrap), so expanding
#                         the literal "$HOME" against THAT script's own $HOME
#                         reaches the same path the sandboxed process sees.
#                         It may not be expanded here: this function may be
#                         called from a context whose $HOME is irrelevant to
#                         the sandbox (there is none today,
#                         but nothing pins that). Empty when not resumable.
#   FS_HARNESS_ID_MODE    "discover" -- the id is read back out of the bound
#                         directory at run end (claude: newest transcript's
#                         stem; codex: the uuid suffix of the newest rollout
#                         file's name) -- or "given" -- the caller supplies
#                         the id up front and the CLI's own create-if-missing
#                         behavior makes resume implicit, so there is nothing
#                         to discover (pi only). Empty when not resumable.
fs_harness_session_caps() {
    local harness="$1"
    [[ "$harness" == pi-local ]] && harness=pi

    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_HARNESS_RESUMABLE=false
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_HARNESS_SESSION_ROOT=""
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_HARNESS_ID_MODE=""
    case "$harness" in
    claude)
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_RESUMABLE=true
        # shellcheck disable=SC2034,SC2016  # literal $HOME token, see header above
        FS_HARNESS_SESSION_ROOT='$HOME/.claude/projects'
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_ID_MODE="discover"
        ;;
    codex)
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_RESUMABLE=true
        # shellcheck disable=SC2034,SC2016  # literal $HOME token, see header above
        FS_HARNESS_SESSION_ROOT='$HOME/.codex/sessions'
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_ID_MODE="discover"
        ;;
    pi)
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_RESUMABLE=true
        # shellcheck disable=SC2034,SC2016  # literal $HOME token, see header above
        FS_HARNESS_SESSION_ROOT='$HOME/.pi/sessions'
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_HARNESS_ID_MODE="given"
        ;;
    *)
        # Not resumable -- e.g. a future harness this table has no entry for
        # yet. Leave the false/empty defaults set above.
        ;;
    esac
}

# Discover which session id a --session-state run should be reported as
# resumable under. Which harnesses get here at all, and whether the id is
# discovered or was given up front, comes from fs_harness_session_caps
# (FS_HARNESS_ID_MODE), not a harness-name check.
#
# For "discover" harnesses (claude, codex): the CLI files each transcript
# under a per-project directory of the store, keyed by its own session id,
# and records nowhere which one is this run's, so this is a documented
# heuristic: the newest by mtime. A --refresh-at chain writes one transcript
# per leg and the newest is the leg a resume should continue; only the
# coding legs are bound at all, so no review or maintainer conversation
# competes for newest (see --session-state in fork-sandbox.sh's header).
# Empty when the store has no transcript -- a session that died before
# writing one.
#
# For "given" harnesses (pi): the id was supplied by the caller via
# --session-id and pi's own create-if-missing behavior makes resume
# implicit, so it is simply echoed back -- there is nothing to discover.
#
# The mtimes come from GNU stat ($FS_STAT), which fs_require_gnu_tools has
# already proven is on PATH, and not from `find -printf`: that flag is GNU
# findutils only, and `brew install coreutils` does not supply find. On
# macOS -- a platform the container backend supports -- BSD find would
# reject it, and with its error swallowed this would report session_id as
# null on every single run, which is a silent no-op rather than a failure
# anyone can see. find itself is given only -maxdepth/-name/-print0, which
# BSD find has.
#
# Args: harness, session_state dir (may not exist), the given session id
# (used only in "given" mode). Prints the discovered/given id, or nothing.
fs_session_discover_id() {
    local harness="$1" session_state="$2" session_id_given="$3"
    local transcripts=() transcript_file find_maxdepth
    local newest_transcript stem

    fs_harness_session_caps "$harness"
    case "$FS_HARNESS_ID_MODE" in
    given)
        # pi: create-if-missing means the id is meaningful the moment
        # --session-id was passed, whether or not the sandbox ever actually
        # started -- there is nothing to discover.
        printf '%s' "$session_id_given"
        ;;
    discover)
        [[ -d "$session_state" ]] || return 0
        case "$harness" in
        codex) find_maxdepth=5 ;;
        *) find_maxdepth=2 ;;
        esac
        while IFS= read -r -d '' transcript_file; do
            transcripts+=("$transcript_file")
        done < <(find "$session_state" -maxdepth "$find_maxdepth" \
            -name '*.jsonl' -type f -print0 2>/dev/null)
        (( ${#transcripts[@]} )) || return 0
        newest_transcript="$("$FS_STAT" -c '%Y %n' -- "${transcripts[@]}" \
            | sort -rn | head -1)"
        [[ -n "$newest_transcript" ]] || return 0
        stem="$(basename "${newest_transcript#* }" .jsonl)"
        if [[ "$harness" == codex ]]; then
            # codex rollout filenames are rollout-<timestamp>-<uuid>.jsonl; a
            # UUID is always exactly 36 characters, so take the last 36
            # rather than stripping a timestamp prefix whose format is not
            # this script's contract to track.
            printf '%s' "${stem: -36}"
        else
            printf '%s' "$stem"
        fi
        ;;
    esac
}

# The sandbox backend: the executable that actually isolates a run.
# FORK_SANDBOX_BACKEND names it and defaults to bwrap, so the resolved name is
# sandbox-backend-$FORK_SANDBOX_BACKEND. PATH comes first, which is how a
# backend that does not live in this repository gets used; a sibling of the
# calling script is the fallback, so a checkout works before install.sh has run.
# The contract every backend implements is docs/sandbox-backend.md.
#
# Takes the calling script's own directory, because the sibling lookup has to
# be relative to the CLIENT, not to this library. Fills FS_BACKEND_BIN.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_BIN=""

fs_resolve_backend() {
    local script_dir="$1" name bin
    name="${FORK_SANDBOX_BACKEND:-bwrap}"
    FS_BACKEND_BIN=""
    # The name becomes part of a command name, so keep it to something that
    # can only ever be one: no slash, no shell metacharacter, no leading dash.
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: FORK_SANDBOX_BACKEND='$name' is not a backend name." >&2
        echo "It becomes 'sandbox-backend-$name', so it must be lowercase" >&2
        echo "alphanumerics, hyphens and underscores." >&2
        return 1
    fi
    bin="$(command -v "sandbox-backend-$name" 2>/dev/null || true)"
    if [[ -z "$bin" && -x "$script_dir/sandbox-backend-$name" ]]; then
        bin="$script_dir/sandbox-backend-$name"
    fi
    if [[ -z "$bin" ]]; then
        echo "Error: cannot find sandbox-backend-$name, which is the sandbox" >&2
        echo "this runs in. It is named by FORK_SANDBOX_BACKEND (default" >&2
        echo "bwrap) and looked up on PATH and beside this script. Run" >&2
        echo "install.sh in the fork-sandbox repo." >&2
        return 1
    fi
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_BACKEND_BIN="$bin"
    return 0
}

# What the resolved backend says about itself. One property matters so far:
# whether the sandbox inherits the host's userland or brings its own.
#
# bwrap mounts the host's /usr, so the agent CLI, node and a venv interpreter
# can be bound in from the host and will run. A container gets its userland
# from its image, and a host binary bound into that has neither its
# interpreter nor its shared libraries. On a Mac that is Mach-O against Linux;
# on Linux it is the host's glibc against the image's. One property, two
# symptoms -- which is why this is asked of the BACKEND and never derived from
# `uname`. Deriving it from the host would leave Linux-plus-container broken
# and, worse, untestable: asking the backend means the image path can be
# exercised on Linux, where it is the same code path a Mac takes.
#
# A backend written before this option exists refuses it and exits nonzero.
# That reads as `host`, the status quo, so such a backend keeps behaving
# exactly as it does today rather than silently changing.
#
# Takes FS_BACKEND_BIN, or any backend path. Fills FS_BACKEND_TOOLCHAIN and
# FS_BACKEND_HOSTS_ALIAS.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_TOOLCHAIN=host
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_HOSTS_ALIAS=0
# Whether chromium's own inner sandbox (nested user namespaces) works under
# this backend, so a caller never has to pass --no-sandbox to find out. See
# docs/sandbox-backend.md's capabilities table.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_CHROMIUM_OWN_SANDBOX=1

fs_backend_capabilities() {
    local bin="$1" out line key value chromium_own_sandbox_seen=0
    FS_BACKEND_TOOLCHAIN=host
    FS_BACKEND_HOSTS_ALIAS=0
    FS_BACKEND_CHROMIUM_OWN_SANDBOX=1
    # Parse only a clean exit. A backend that refuses the option may still
    # print its usage, and a usage line can hold an '=' -- reading that as a
    # capability would be inventing an answer out of an error message.
    out="$("$bin" --capabilities 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
        toolchain)
            case "$value" in
            host|image)
                # shellcheck disable=SC2034  # read by the sourcing scripts
                FS_BACKEND_TOOLCHAIN="$value"
                ;;
            *)
                echo "Warning: the backend reports toolchain='$value', which is" >&2
                echo "not 'host' or 'image'. Assuming host, which is what every" >&2
                echo "backend did before the property existed." >&2
                ;;
            esac
            ;;
        hosts_alias)
            # shellcheck disable=SC2034  # read by scripts sourcing this library
            [[ "$value" == 1 ]] && FS_BACKEND_HOSTS_ALIAS=1
            ;;
        chromium_own_sandbox)
            case "$value" in
            0|1)
                # shellcheck disable=SC2034  # read by the sourcing scripts
                FS_BACKEND_CHROMIUM_OWN_SANDBOX="$value"
                chromium_own_sandbox_seen=1
                ;;
            *)
                echo "Warning: the backend reports chromium_own_sandbox='$value'," >&2
                echo "which is not '0' or '1'. Defaulting by toolchain instead." >&2
                ;;
            esac
            ;;
        esac
        # An unknown key is ignored on purpose: a newer backend may declare
        # properties this caller has never heard of.
    done <<< "$out"
    # A backend written before this key existed declares neither value, so
    # default by toolchain rather than leave the older, safer assumption
    # (host, i.e. 1) in place unconditionally -- an older container-style
    # backend would otherwise be told its chromium sandbox works when its
    # toolchain=image already says the userland is not the host's.
    if (( ! chromium_own_sandbox_seen )); then
        if [[ "$FS_BACKEND_TOOLCHAIN" == host ]]; then
            # shellcheck disable=SC2034  # read by the sourcing scripts
            FS_BACKEND_CHROMIUM_OWN_SANDBOX=1
        else
            # shellcheck disable=SC2034  # read by the sourcing scripts
            FS_BACKEND_CHROMIUM_OWN_SANDBOX=0
        fi
    fi
    return 0
}

# Carry the git identity into a sandbox, but switch commit signing off. The
# host config here signs with an SSH key under ~/.ssh, and ~/.ssh is masked on
# purpose, so every commit inside the sandbox would fail. Appending the
# overrides at the end beats anything set earlier, includes included.
#
# Writes the copy into the caller's per-run state dir, which the caller's own
# cleanup removes, and fills FS_GITCONFIG_FLAGS with the backend flags that
# mount it at $HOME/.gitconfig inside. Both clients need this: a sealed pi run
# commits in the sandbox exactly as a claude run does.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_GITCONFIG_FLAGS=()

fs_gitconfig_bind() {
    local state_dir="$1"
    FS_GITCONFIG_FLAGS=()
    if [[ -r "$HOME/.gitconfig" ]]; then
        cat "$HOME/.gitconfig" > "$state_dir/gitconfig"
    else
        : > "$state_dir/gitconfig"
    fi
    printf '\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' \
        >> "$state_dir/gitconfig"
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_GITCONFIG_FLAGS=(--bind-ro-at "$state_dir/gitconfig" "$HOME/.gitconfig")
    return 0
}

# The Claude OAuth credential, as JSON on stdout.
#
# On Linux the CLI keeps it in ~/.claude/.credentials.json. On macOS it keeps
# it in the login Keychain instead and that file does not exist, so a Mac fails
# the file check and never reaches the sandbox at all. Reading it here rather
# than at two later jq call sites also means the Keychain is touched exactly
# once: it can prompt for access the first time, and a prompt is a foreground
# interaction in a tool built to run unattended, so it belongs at launch on the
# host and nowhere else.
#
# The value never reaches an argv. Callers hold it in a variable and pipe it
# with printf, a builtin, so `ps` never shows it.
#
# Prints the JSON on success; writes its own error and returns non-zero
# otherwise. It reports WHERE it came from through fs_claude_credential_source
# rather than through a variable of its own: a caller can only take the JSON
# through a command substitution, and a subshell cannot set a variable in the
# shell that started it -- so such a variable would read empty at exactly the
# moment an error message wanted it.
#
# The Keychain service name Claude Code stores the credential under. It is a
# list because the name is the CLI's business and could change; each is tried
# in turn, and the error below says how to look it up by hand.
FS_CLAUDE_KEYCHAIN_SERVICES=("Claude Code-credentials")

# A human name for where the credential comes from, for error messages. Reads
# nothing and holds no secret, so it is safe to call from anywhere, as often as
# a message needs it.
fs_claude_credential_source() {
    local override="${1:-}"
    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    local file="$HOME/.claude/.credentials.json"
    if [[ ! -f "$file" && "$(uname -s)" == Darwin ]]; then
        printf '%s\n' "the login Keychain"
    else
        printf '%s\n' "$file"
    fi
}

fs_read_claude_credential() {
    local override="${1:-}"
    local file="${override:-$HOME/.claude/.credentials.json}" svc out

    if [[ ! -f "$file" ]]; then
        if [[ -n "$override" ]]; then
            echo "Error: $override not found. --claude-credentials (or" >&2
            echo "CLAUDE_CREDENTIALS in claude.env) named this path explicitly," >&2
            echo "so it is not falling back to the default credential file or" >&2
            echo "Keychain." >&2
            return 1
        fi
        if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null 2>&1; then
            for svc in "${FS_CLAUDE_KEYCHAIN_SERVICES[@]}"; do
                out="$(security find-generic-password -s "$svc" -w 2>/dev/null)" || continue
                # A wrong item would otherwise become a silently broken credential
                # inside the sandbox, which fails as a 401 an hour later. Check the
                # shape here, where the error can still say what is wrong.
                printf '%s' "$out" | jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1 || continue
                printf '%s' "$out"
                return 0
            done
            echo "Error: no Claude credential found. $file does not exist, which is" >&2
            echo "expected on macOS -- the CLI keeps it in the login Keychain -- but" >&2
            echo "no usable item was there either. Tried: ${FS_CLAUDE_KEYCHAIN_SERVICES[*]}" >&2
            echo "Log in with claude first. If you are already logged in, the service" >&2
            echo "name may have changed; find it with:" >&2
            echo "  security dump-keychain | grep -i claude" >&2
            return 1
        fi
        echo "Error: $file not found. Log in with claude first." >&2
        return 1
    fi

    # `-f` proves it is a regular file, not that it can be read. Check the
    # read itself: an unreadable credential used to abort loudly, when jq
    # opened the file directly, and returning 0 with no output here would
    # instead be diagnosed downstream as an EXPIRED token -- sending the
    # user to re-log-in, which rewrites a file they still cannot read.
    if ! cat -- "$file"; then
        echo "Error: $file exists but could not be read. Check its owner" >&2
        echo "and mode -- a credential written under sudo is the usual" >&2
        echo "cause. This is not an expired token; logging in again would" >&2
        echo "rewrite a file you still cannot read." >&2
        return 1
    fi
    return 0
}

# Picks a Claude credential from an operator-configured pool when neither
# --claude-credentials nor CLAUDE_CREDENTIALS pinned one, so a run does not
# default to an account that may be nearly exhausted. The pool
# (CLAUDE_CREDENTIAL_POOL, colon-separated absolute paths) and the health
# policy (CLAUDE_HEADROOM_HOOK, a plugin name) both live in claude.env; this
# repo carries only the mechanism -- which account is healthy is answered
# entirely by the operator's own hook, kept outside this repo so no real
# quota tool or account name is ever named here (see CLAUDE.md).
#
# A lib function rather than code inlined at a call site because a Claude
# credential is read at TWO independent places -- fork-sandbox.sh's local
# path and fork-sandbox-k8s.sh's direct entry point -- and this repo has
# shipped a fix that covered only one of a pair of call sites before. One
# function means the config-error checks and the hook contract cannot
# drift between the two.
#
# Takes the config dir (claude.env lives under it) and the calling script's
# own directory, and resolves the hook the identical way
# fork-sandbox-k8s.sh's resolve_platform() resolves a k8s platform plugin:
# PATH first (so a checkout works before install.sh has run), then beside
# the calling script.
#
# Config errors -- CLAUDE_CREDENTIALS set alongside CLAUDE_CREDENTIAL_POOL,
# only one of POOL/HOOK set, a malformed pool entry, a malformed hook name
# -- are refused loudly here, never resolved silently: two sources for one
# fact, or half a mechanism, is a setup mistake the operator needs to see,
# not code guessing which half was meant. A pool entry is a path, but the
# hook is a NAME rather than a path for the same reason a `configure`
# discoverer cannot name a path (docs/configure.md, "The allowlist"): config
# a blanket-approved script trusts unconditionally must not be able to
# point it at an arbitrary executable outside the plugin convention.
#
# Prints the chosen path on stdout and returns 0 when the pool picked one.
# Prints nothing and returns 0 when there is no pool configured, or when the
# hook itself failed (a warning is printed to stderr in that case) -- either
# way the caller falls through to today's default chain, because a crashed
# plugin must not brick every launch on the machine. Returns 1, with the
# error already on stderr, on any config error, on a hook exit-0 contract
# violation, or when the hook reports "no routable candidate" (exit 2) --
# all three are hard errors, because a balanced choice is as
# operator-authored as the explicit flag, and a broken contract must be
# loud rather than silently falling back.
#
# The chosen path is NOT validated here beyond the hook's own contract
# (member of the pool, exactly one line) -- it flows back through the
# caller's existing $FS_REALPATH -m / fs_reject_unsafe_chars / fail-loud
# existence check, the same path an explicit --claude-credentials or
# CLAUDE_CREDENTIALS takes, so there is exactly one place that decides what
# makes a credential path acceptable.
fs_balance_claude_credential() {
    local config_dir="$1" script_dir="$2"
    local claude_env="$config_dir/claude.env"
    local pinned pool_raw hook_name
    pinned="$(fs_read_env_value "$claude_env" CLAUDE_CREDENTIALS || true)"
    pool_raw="$(fs_read_env_value "$claude_env" CLAUDE_CREDENTIAL_POOL || true)"
    hook_name="$(fs_read_env_value "$claude_env" CLAUDE_HEADROOM_HOOK || true)"

    if [[ -n "$pinned" && -n "$pool_raw" ]]; then
        echo "Error: claude.env sets both CLAUDE_CREDENTIALS and" >&2
        echo "CLAUDE_CREDENTIAL_POOL. Two sources for one credential --" >&2
        echo "pin one account with CLAUDE_CREDENTIALS, or let the pool" >&2
        echo "balance between several, not both." >&2
        return 1
    fi
    if [[ -n "$pool_raw" && -z "$hook_name" ]]; then
        echo "Error: claude.env sets CLAUDE_CREDENTIAL_POOL without" >&2
        echo "CLAUDE_HEADROOM_HOOK. A pool with no hook to ask has no way" >&2
        echo "to pick a candidate -- set both, or neither." >&2
        return 1
    fi
    if [[ -z "$pool_raw" && -n "$hook_name" ]]; then
        echo "Error: claude.env sets CLAUDE_HEADROOM_HOOK without" >&2
        echo "CLAUDE_CREDENTIAL_POOL. A hook with no candidates to judge" >&2
        echo "has nothing to pick from -- set both, or neither." >&2
        return 1
    fi
    if [[ -z "$pool_raw" ]]; then
        # Not configured at all -- not an error, just nothing for this
        # function to do. The caller falls through to CLAUDE_CREDENTIALS
        # (already confirmed unset above, or this is unreachable) or
        # today's default.
        return 0
    fi

    if [[ ! "$hook_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "Error: CLAUDE_HEADROOM_HOOK='$hook_name' is not a plugin" >&2
        echo "name. It becomes fork-sandbox-headroom-$hook_name, so it" >&2
        echo "must be lowercase alphanumerics and hyphens, starting with" >&2
        echo "an alphanumeric." >&2
        return 1
    fi

    if [[ "$pool_raw" == :* || "$pool_raw" == *: || "$pool_raw" == *::* ]]; then
        echo "Error: CLAUDE_CREDENTIAL_POOL has an empty entry (check for" >&2
        echo "a leading, trailing or doubled ':')." >&2
        return 1
    fi

    local -a pool=()
    local entry
    IFS=':' read -r -a pool <<< "$pool_raw"
    for entry in "${pool[@]}"; do
        if [[ "$entry" != /* ]]; then
            echo "Error: CLAUDE_CREDENTIAL_POOL entry '$entry' is not an" >&2
            echo "absolute path. Every pool candidate must be, so it names" >&2
            echo "the same file regardless of the launcher's cwd." >&2
            return 1
        fi
        if [[ "$entry" =~ [[:space:]] ]]; then
            echo "Error: CLAUDE_CREDENTIAL_POOL entry '$entry' contains" >&2
            echo "whitespace, which is not supported in a colon-separated" >&2
            echo "list entry." >&2
            return 1
        fi
        fs_reject_unsafe_chars "$entry" || return 1
    done

    local hook_bin
    hook_bin="$(command -v "fork-sandbox-headroom-$hook_name" 2>/dev/null || true)"
    if [[ -z "$hook_bin" && -x "$script_dir/fork-sandbox-headroom-$hook_name" ]]; then
        hook_bin="$script_dir/fork-sandbox-headroom-$hook_name"
    fi
    if [[ -z "$hook_bin" ]]; then
        echo "Error: cannot find fork-sandbox-headroom-$hook_name, which" >&2
        echo "CLAUDE_HEADROOM_HOOK names. Looked on PATH and beside" >&2
        echo "$script_dir. Install the hook, or unset CLAUDE_HEADROOM_HOOK" >&2
        echo "and CLAUDE_CREDENTIAL_POOL." >&2
        return 1
    fi

    local hook_out hook_rc
    hook_out="$("$hook_bin" "${pool[@]}")"
    hook_rc=$?
    if (( hook_rc == 0 )); then
        if [[ -z "$hook_out" ]]; then
            echo "Error: $hook_bin printed nothing on stdout. Its contract" >&2
            echo "is exit 0 with exactly one of the candidate paths on" >&2
            echo "stdout." >&2
            return 1
        fi
        if [[ "$hook_out" == *$'\n'* ]]; then
            echo "Error: $hook_bin printed more than one line:" >&2
            echo "$hook_out" >&2
            echo "Its contract is exit 0 with exactly one of the candidate" >&2
            echo "paths on stdout." >&2
            return 1
        fi
        local is_member=false
        for entry in "${pool[@]}"; do
            [[ "$hook_out" == "$entry" ]] && is_member=true && break
        done
        if [[ "$is_member" != true ]]; then
            echo "Error: $hook_bin printed '$hook_out', which is not one" >&2
            echo "of the candidates it was given. Its contract is to print" >&2
            echo "exactly one of them." >&2
            return 1
        fi
        printf '%s\n' "$hook_out"
        return 0
    elif (( hook_rc == 2 )); then
        echo "Error: $hook_bin found no routable credential (its" >&2
        echo "considered answer, exit 2) -- every candidate in the pool" >&2
        echo "looked unhealthy. Pin one by hand with --claude-credentials" >&2
        echo "to override, or fix the accounts and retry." >&2
        return 1
    else
        echo "Warning: $hook_bin exited $hook_rc. Falling back to today's" >&2
        echo "default credential chain for this launch -- fix the hook" >&2
        echo "when you get a chance." >&2
        return 0
    fi
}

# The host's model and browser caches, read-only, when the host has them.
# Both clients want them, and neither wants the surgery to be repeated.
# Fills FS_CACHE_FLAGS with backend flags; empty when the host has no cache.
#
# The Hugging Face model cache:
#
# An ML project's settings import commonly reaches transformers, and
# from_pretrained() is a local-disk read when the snapshot is already cached and
# a network call when it is not. In a sandbox that call is doomed: a sealed one
# has no network at all, a pinned one has no HF token, and a gated repo needs
# one. Binding the cache turns the common case back into the read it should be.
#
# Only the content subdirectories, and NEVER the parent ~/.cache/huggingface:
# that is where huggingface_hub writes `token` and `stored_tokens`. Read-only is
# enough to authenticate with, and this sandbox is built to hold no credential,
# so binding the parent would quietly hand an HF token to every session from the
# day the user first logs in. The subdirectories hold model content and nothing
# else.
#
# Read-only in the other direction too: sandboxed code cannot poison a cache the
# host later loads models from.
#
# HF_HUB_OFFLINE goes in only alongside the cache bind, never on its own. With a
# cache mounted it turns a doomed fetch into the local read it should be. With
# no cache there is nothing to read locally, and forcing offline would break a
# public download that a pinned-egress run could still have made.
#
# The Playwright browser cache:
#
# Playwright hardcodes ~/.cache/ms-playwright as its default browsers path, so
# a run that launches Chromium finds the build there or dies with "Executable
# doesn't exist" — and `playwright install` cannot fix it in a sandbox.
#
# Unlike the Hugging Face cache the WHOLE directory is bound: it holds browser
# builds (chromium-*, ffmpeg-*) and nothing else — no token, no config — so it
# needs none of the subdirectory surgery the HF bind does. Read-only in both
# directions, so a run cannot poison a browser the host later launches.
# Chromium's own inner sandbox keeps working: bwrap leaves nested user
# namespaces available, so callers need no --no-sandbox.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_CACHE_FLAGS=()

fs_cache_binds() {
    local hf_root="$HOME/.cache/huggingface" pw_root="$HOME/.cache/ms-playwright"
    local hf_sub hf_bound=0
    FS_CACHE_FLAGS=()
    for hf_sub in hub xet; do
        [[ -d "$hf_root/$hf_sub" ]] || continue
        FS_CACHE_FLAGS+=(--bind-ro "$hf_root/$hf_sub")
        hf_bound=1
    done
    if (( hf_bound )); then
        FS_CACHE_FLAGS+=(--setenv HF_HUB_OFFLINE=1)
    fi
    # The Hugging Face bind above is model DATA and travels to any sandbox.
    # This one is browser BINARIES, so it is host-toolchain only: an image's
    # userland cannot execute the host's Chromium build, and an image that
    # needs a browser has to carry its own.
    if [[ -d "$pw_root" && "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        FS_CACHE_FLAGS+=(--bind-ro "$pw_root")
    fi
    return 0
}

# Candidate binary names for a system chromium, tried in order with
# `command -v`. A list rather than one name because distros disagree:
# Debian/Ubuntu ships chromium or chromium-browser, Arch ships chromium, and
# Google's own package is google-chrome-stable (google-chrome on older
# installs). A variable, not a literal in fs_detect_browser, so a test can
# point it at fake names without installing a real browser.
FS_BROWSER_CHROMIUM_CANDIDATES=(chromium chromium-browser google-chrome-stable google-chrome)

# The path prefixes a resolved chromium must live under to be trusted. These
# are the read-only binds a host-toolchain sandbox backend carries in --
# bwrap's --ro-bind /usr and --ro-bind-try /opt /nix/store (see
# scripts/sandbox-backend-bwrap) -- so a binary resolved anywhere else (a
# user's ~/bin shim, say) is not actually there at run time even though
# `command -v` finds it on the host doing the detecting. A variable, not a
# literal, so a test can point this at a temp tree instead of requiring a
# real chromium under one of these paths.
FS_BROWSER_TRUSTED_PREFIXES=("/usr/" "/opt/" "/nix/store/")

# G1 detect: whether a usable browser exists for THIS sandbox run, mirroring
# fs_cache_binds' own Playwright condition exactly -- a mismatch here would
# have the prompt announce a cache that was never bound, or stay silent about
# one that was. Fills, empty string meaning absent:
#
#   FS_BROWSER_CHROMIUM     resolved path to a system chromium
#   FS_BROWSER_PLAYWRIGHT   $HOME/.cache/ms-playwright, when that dir exists
#
# Both are forced empty when the backend's toolchain is not `host`: an image
# toolchain's userland is the image's, not the host's, and the default image
# ships no browser (images/sandbox/Dockerfile). Both are also forced empty
# when FORK_SANDBOX_BROWSER is `0` or `none` -- an operator's explicit "there
# is no usable browser here" (or "don't bother," e.g. a flaky host chromium),
# taken at its word rather than second-guessed by detection. Unset or `auto`
# (the default) detects normally.
fs_detect_browser() {
    FS_BROWSER_CHROMIUM=""
    FS_BROWSER_PLAYWRIGHT=""

    case "${FORK_SANDBOX_BROWSER:-auto}" in
    0 | none) return 0 ;;
    esac
    [[ "$FS_BACKEND_TOOLCHAIN" == host ]] || return 0

    local name resolved prefix trusted
    for name in "${FS_BROWSER_CHROMIUM_CANDIDATES[@]}"; do
        resolved="$(command -v -- "$name" 2>/dev/null)" || continue
        trusted=0
        for prefix in "${FS_BROWSER_TRUSTED_PREFIXES[@]}"; do
            case "$resolved" in
            "$prefix"*) trusted=1; break ;;
            esac
        done
        if (( trusted )); then
            # shellcheck disable=SC2034  # read by the sourcing scripts
            FS_BROWSER_CHROMIUM="$resolved"
            break
        fi
    done

    local pw_root="$HOME/.cache/ms-playwright"
    if [[ -d "$pw_root" ]]; then
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_BROWSER_PLAYWRIGHT="$pw_root"
    fi
    return 0
}

# Renders the handoff prompt's "## Browser" section from fs_detect_browser's
# output and the backend's sandbox capability, so a test can exercise the
# rendering directly by setting the three globals below and capturing this
# function's stdout -- without shelling out to a whole fork-sandbox.sh run,
# which cannot make FS_BROWSER_CHROMIUM/FS_BROWSER_PLAYWRIGHT deterministic
# from outside (they depend on what is actually installed on the host
# running the test).
#
# Reads (never args, so it stays a drop-in call at the prompt-assembly site
# where these are already in scope):
#   FS_BROWSER_CHROMIUM           set by fs_detect_browser
#   FS_BROWSER_PLAYWRIGHT         set by fs_detect_browser
#   FS_BACKEND_CHROMIUM_OWN_SANDBOX  set by fs_backend_capabilities
fs_emit_browser_section() {
    if [[ -n "$FS_BROWSER_CHROMIUM" || -n "$FS_BROWSER_PLAYWRIGHT" ]]; then
        local no_sandbox_line="Chromium's own sandbox works here; do not pass --no-sandbox."
        if [[ "$FS_BACKEND_CHROMIUM_OWN_SANDBOX" != 1 ]]; then
            no_sandbox_line="Chromium's own sandbox does not work here; pass --no-sandbox."
        fi
        if [[ -n "$FS_BROWSER_CHROMIUM" ]]; then
            cat <<EOF

## Browser

A browser is available inside this sandbox:

- chromium: $FS_BROWSER_CHROMIUM
EOF
            if [[ -n "$FS_BROWSER_PLAYWRIGHT" ]]; then
                cat <<EOF
- playwright browser cache: ~/.cache/ms-playwright (bound read-only)
EOF
            fi
            cat <<EOF

One-shot screenshot recipe known to work in this sandbox:

    $FS_BROWSER_CHROMIUM --headless=new --disable-gpu --disable-dev-shm-usage \\
        --screenshot=<out.png> --window-size=1280,2000 <url>

$no_sandbox_line
Write screenshots into the clone or the outbox. If you can Read
images, read the PNG to check the render; otherwise save it to the
outbox for the orchestrator to judge.
EOF
        else
            cat <<EOF

## Browser

A browser is available inside this sandbox, though not on PATH: the
Playwright browser cache at ~/.cache/ms-playwright is bound read-only.
Find the chromium build under it, e.g.:

    find ~/.cache/ms-playwright -maxdepth 3 -type f \\
        \( -name chrome -o -name headless_shell \)

and drive that binary directly; it takes the same flags as chromium
(--headless=new --disable-gpu --disable-dev-shm-usage --screenshot=<out.png>
--window-size=1280,2000 <url>).

$no_sandbox_line
Write screenshots into the clone or the outbox. If you can Read
images, read the PNG to check the render; otherwise save it to the
outbox for the orchestrator to judge.
EOF
        fi
    else
        cat <<EOF

## Browser

No browser is available in this sandbox. Do not spend tool calls
looking for one; if the task needs rendering, say so in your report.
EOF
    fi
}

# The preamble every generated prompt starts with: where the clone is,
# where the operator inbox is (if this run has one), how addenda reach this
# harness, and what the network situation is. fork-sandbox.sh's handoff
# needs it, so do its --review-loop review and fix prompts -- separate
# sessions in the same sandbox, knowing none of it either -- and so does
# fork-sandbox-k8s.sh's pod handoff. Written once here, shared, rather than
# pasted into more than one script.
#
# $1  clone_dir  absolute path to the clone. Always required.
# $2  inbox_dir  absolute path to the operator inbox, or "" if this run has
#                none. Empty omits the whole "Operator inbox" section rather
#                than naming a directory that does not exist -- a
#                Kubernetes run has no inbox yet.
# $3  harness    selects how the "read the inbox" instructions are worded:
#                "claude" is told addenda are pushed to it; every other
#                value is told to poll. Unused when $2 is empty.
# $4  network    selects the network block, if any: "sealed" for a
#                pi-local run (no network at all), "gated" for a Kubernetes
#                pod (egress allowed only to DNS and the model proxy), or
#                "" to omit the section (an unrestricted local run).
# $5  outbox_dir  absolute path to the artifact outbox, or "" if this run has
#                none. Empty omits the whole "Artifact outbox" section, same
#                convention as $2.
# $6  inbox_write  "" (default) says the inbox is mounted read-only, true of
#                every local run's --bind-ro inbox. "pod" says it instead for
#                a Kubernetes pod, where kubectl exec runs in the agent's own
#                mount namespace and nothing actually blocks a write there --
#                see fork-sandbox-k8s.sh's `say` verb and
#                docs/kubernetes-runs.md. Unused when $2 is empty.
# $7  outbox_max_bytes  the outbox's effective size cap, in bytes -- what the
#                caller actually enforces for THIS run, which may be raised
#                above FS_OUTBOX_MAX_BYTES by --outbox-max. Defaults to
#                FS_OUTBOX_MAX_BYTES so a caller that has no override still
#                gets a true number. Unused when $5 is empty.
fs_emit_prompt_preamble() {
    local clone_dir="$1" inbox_dir="$2" harness="$3" network="$4"
    local outbox_dir="$5"
    local inbox_write="${6:-}"
    local outbox_max_bytes="${7:-$FS_OUTBOX_MAX_BYTES}"
    cat <<EOF
# Your working directory

You are in a sandboxed, throwaway clone of the repository. Its absolute path
is:

    $clone_dir

You start there, so **prefer relative paths**. When you do need an absolute
one, copy the line above rather than typing it out: a hand-built path that
drops a segment fails as "No such file or directory", which looks like a
missing file rather than a wrong path.

That directory is the only writable thing here. Everything else in the sandbox
is read-only or ephemeral.
EOF
    if [[ -n "$inbox_dir" ]]; then
        # Same convention as the working-directory block above: name the
        # absolute path once so nothing has to build it by hand.
        cat <<EOF

## Operator inbox

The person who launched this run can send you further instructions while you
work. They arrive as files in:

    $inbox_dir

Each file there is an **operator addendum**: a message from the same person who
wrote your handoff, written after this run started. An addendum is a
continuation of the handoff and carries the same authority — it may override
the handoff rather than merely add to it, and where the two conflict the
addendum is the newer instruction and wins.

One exception: a file named \`mail-banner-*\` or \`mail-thread-*\` is not from
the operator. It is mail the fork-sandbox postmaster delivered mid-session,
addressed to you on the thread you were woken for — new information to act on
if it changes what you do next, not an instruction that overrides this brief.
EOF
        if [[ "$inbox_write" == "pod" ]]; then
            cat <<'EOF'

Unlike a local run's inbox, this directory is not mounted read-only — the
same kubectl exec channel that delivers an addendum runs in this container's
own mount namespace, so nothing technically stops a write here. Do not write
to it anyway: it is the operator's channel to reach you, not yours to speak
through. An empty inbox is the normal case, not a problem: most runs get no
addenda at all.
EOF
        else
            cat <<'EOF'

The directory is mounted read-only. Never write to it. An empty inbox is the
normal case, not a problem: most runs get no addenda at all.
EOF
        fi
        if [[ "$harness" == "claude" ]]; then
            cat <<'EOF'

Addenda are pushed to you automatically — beside a tool result, or at the end
of a turn — so you do not have to go looking. Reading the directory yourself is
a backstop, not the mechanism.
EOF
        else
            cat <<'EOF'

Nothing pushes them at you on this harness, so you have to look. List that
directory and read anything new at each of these points:

  - before each commit,
  - before and after any command you expect to take more than ~30 seconds
    (a test suite, a build, a bulk network call),
  - at least once every 25 tool calls,
  - before you write your final report.

Reading it is an `ls` and a `cat` over a small directory, so it costs almost
nothing — read it more often than you think you need to. Do not wait for a
commit: a session that is stuck, off-scope, or grinding through a long build
is the one most likely to be sent a correction and the least likely to reach
a commit. An addendum you never read is an instruction you never followed.
EOF
        fi
    fi
    if [[ -n "$outbox_dir" ]]; then
        # Same convention as the inbox block above: name the absolute path
        # once so nothing has to build it by hand.
        cat <<EOF

## Artifact outbox

Files written here come back to the person who launched this run; everything
else outside the clone is discarded when the sandbox is torn down. Its
absolute path is:

    $outbox_dir

This is for artifacts a human will look at -- screenshots, reports,
generated images, coverage output, anything that is not source. Source
changes belong in commits, not here.

**\`handoff.md\` at the root of this directory is reserved** for this run's
own self-refresh protocol. Do not write anything named that.

The whole directory has a $((outbox_max_bytes / 1024 / 1024)) MiB budget.
Go over it and the outbox is refused **as a whole, not truncated** -- one
oversized artifact means everything in here is lost, not just the large
file. If you are about to write something big, downscale a screenshot or
write one image instead of forty rather than risk the rest.
EOF
    fi
    case "$network" in
        sealed)
            cat <<'EOF'

## This sandbox has no network

There is no internet here, no LAN, and no DNS. The model you are running on is
reached over a socket and is the only thing outside this machine you can talk
to. Nothing else will answer.

So do not try to install anything — no `npm install`, no `pip install`, no
`apt-get`, no `git fetch`, no documentation lookup. Those fail, and the failure
is the sandbox working as intended rather than a problem to debug or work
around.

Everything the work needs is already here: the clone, whatever dependencies
were provisioned into it, and any per-run services. If something genuinely
necessary is missing, say so in your final report instead of trying to fetch
it.
EOF
            ;;
        gated)
            cat <<'EOF'

## This sandbox's egress is gated to the model proxy

This pod's network policy allows exactly two destinations: DNS, and the model
proxy that carries the requests you make as this agent. Nothing else answers
— not the open internet, not a LAN, not a git host.

So do not try to install anything — no `npm install`, no `pip install`, no
`apt-get`, no `git fetch`, no documentation lookup. Those fail, and the
failure is the sandbox working as intended rather than a problem to debug or
work around.

Everything the work needs is already here: the clone, and whatever
dependencies were provisioned into it. If something genuinely necessary is
missing, say so in your final report instead of trying to fetch it.
EOF
            ;;
    esac
}

# Appended to a review, maintainer or fix prompt: the caller's original
# handoff, verbatim, under a fixed heading. The whole file is carried, not
# an extracted "out of scope" slice: in a real handoff the fence on work is
# distributed through the document -- scope sections, trap notes, "decided,
# do not revisit" lines, and commit conventions no extractor would classify
# as scope at all -- so a slice structurally under-delivers, and a missed
# parse fails silently. The hazards are handled in the framing the callers
# emit before this, not in a filter.
#
# $1  handoff_file  the caller's ORIGINAL handoff path, not a rendered copy
#                   of it: the copy has the implement leg's preamble
#                   prepended, which is not part of the spec. Required and
#                   non-empty; the callers have already validated the path
#                   at launch, so any failure here is a bug that must be
#                   visible at prompt-build time (before any model runs),
#                   not a silently missing section.
# $2  flavor        "spec" (default) or "review-only" -- see
#                   fs_emit_handoff_spec_section. The heading above the
#                   embedded text and the wording of the fail-on-missing/
#                   empty/unreadable checks below both change with it: the
#                   review-only file is a review brief, not the branch's
#                   spec, and the failure text should not call it one.
fs_append_handoff_brief() {
    local handoff_file="$1" flavor="${2:-spec}"
    local doc_desc build_desc
    if [[ "$flavor" == "review-only" ]]; then
        doc_desc="review brief"
        build_desc="the review brief for this run"
    else
        doc_desc="handoff"
        build_desc="the handoff the branch was built against"
    fi
    if [[ -z "$handoff_file" ]]; then
        printf 'Error: fs_append_handoff_brief: the handoff path is empty. ' >&2
        printf 'A review, maintainer or fix prompt must embed %s,' "$build_desc" >&2
        printf ' and there is none to name.\n' >&2
        return 1
    fi
    if [[ ! -f "$handoff_file" || ! -r "$handoff_file" ]]; then
        printf 'Error: %s file %q is missing or unreadable at' "$doc_desc" "$handoff_file" >&2
        printf ' prompt-build time. The %s cannot be embedded into' "$build_desc" >&2
        printf ' the prompt, so the prompt is not built rather than built' >&2
        printf ' without it.\n' >&2
        return 1
    fi
    if [[ ! -s "$handoff_file" ]]; then
        printf 'Error: %s file %q is empty at prompt-build time. An empty' "$doc_desc" "$handoff_file" >&2
        printf ' %s is not usable; the prompt is not built rather than' "$doc_desc" >&2
        printf ' built without its section.\n' >&2
        return 1
    fi
    if [[ "$flavor" == "review-only" ]]; then
        printf '\n## The review brief\n\n'
    else
        printf '\n## The handoff this branch was built against\n\n'
    fi
    cat -- "$handoff_file"
}

# The review and maintainer legs' shared section: normally, the handoff is
# the spec the branch was built against, and the three rules the leg holds
# it to. The rules sit immediately before the handoff they govern, which
# fs_append_handoff_brief appends after them. Shared for the same reason as
# the bodies that call it -- one emitter, multiple callers, so the wordings
# can never drift. Rule 3 is load-bearing: without it the section swaps one
# failure for a worse one, a reviewer deferring to the handoff and stopping
# flagging decided designs that are themselves wrong.
#
# The "review-only" flavor is the exception: fork-sandbox.sh --review-only
# reviews a branch this run did not build, so what the caller passes as
# "the handoff" is a review brief the operator wrote FOR THIS REVIEW RUN,
# not the spec the branch was built against -- this sandbox never had that
# spec. Rules 1 and 2 above assume the handoff IS the branch's spec (a gap
# against it is a finding); asserted against a review brief instead, they
# would make the reviewer invent findings out of "the branch does not
# contain what the brief asked for", which is true of every review-only
# branch by construction. So that flavor drops rules 1 and 2 and keeps only
# the rule that survives being pointed at a brief instead of a spec: the
# text handed to the reviewer can itself be wrong, and saying so is a
# finding.
#
# $1  handoff_file  see fs_append_handoff_brief.
# $2  flavor        "spec" (default) or "review-only", see above. Only the
#                   local --review-only render site passes "review-only";
#                   every other caller must keep rendering byte-identical
#                   to the "spec" flavor.
fs_emit_handoff_spec_section() {
    local handoff_file="$1" flavor="${2:-spec}"
    if [[ "$flavor" == "review-only" ]]; then
        cat <<'EOF'

---

## The review brief for this run

The text appended below is the brief the operator wrote for this review run
specifically. This branch was not built in this sandbox -- it was built
elsewhere, against a spec this sandbox never had. So the brief is not a spec
to diff the branch against: it steers where to look and what to weigh, not
what the branch is required to contain. Work the brief mentions that the
branch's commits do not contain is not a finding -- the brief did not
commission this branch, so its absence proves nothing.

The brief can still be wrong: a request that will not work, a premise the
branch's own code contradicts, an emphasis that misses the real risk. If you
believe it is, say so and say why — that IS a finding, and it is the most
valuable one you can report. Never withhold it because the brief sounds
decided.
EOF
    else
        cat <<'EOF'

---

## The handoff is the spec — read it, and judge it

The brief the implementing session was given is appended below, in full. It
is the spec this branch was built against, and nothing else in this sandbox
tells you what was asked for.

Read it before you read the diff, and hold it to three rules.

1. **Work the handoff deliberately excludes is not a finding.** Where the
   handoff fences something out of scope, a branch that leaves it undone is
   correct, not deficient. Do not report it. The code-review skill compares
   the diff against the conventions of this repository, where a deliberate
   omission and an oversight look identical — the handoff is the only thing
   here that tells them apart.

2. **Work the handoff asked for that the branch does not contain IS a
   finding.** Report it the way you would report a bug, quoting the line of
   the handoff that asked for it. This is the rule from "An unfollowed
   addendum is a finding" above, applied to the original brief.

3. **A decision being written down does not make it right.** The handoff
   can be wrong: a plan that cannot work, a constraint that defeats its own
   goal, an approach that breaks something it did not consider. If you
   believe it is, say so and say why — that IS a finding, and it is the
   most valuable one you can report. Rules 1 and 2 ask whether the branch
   matches the spec; this one asks whether the spec is sound. Never
   withhold it because the handoff sounds decided.
EOF
    fi
    fs_append_handoff_brief "$handoff_file" "$flavor"
}

# The review leg's task text, for fork-sandbox.sh's --review-loop: read the
# branch under the given commit range, run the code-review-portable skill
# against it, and write a verdict to a fixed path in the fixed
# APPROVED/FINDINGS format the runner parses back. The caller composes the
# full prompt as fs_emit_prompt_preamble, then fs_emit_prompt_overlay, then
# this -- the same order fs_emit_prompt_preamble itself is composed in, and
# for the same reason: fork-sandbox-k8s.sh's own review loop needs this exact
# text next, and the one thing it must not do is grow a second copy.
#
# The body ends with the handoff section (fs_emit_handoff_spec_section):
# without it the reviewer can never tell a deliberate omission from an
# oversight, because the only document that says what was asked for is the
# brief the implementing session got. That is true of the default "spec"
# flavor; the caller passes "review-only" instead when $handoff_file is not
# the branch's spec but a review brief written for this run (see
# fs_emit_handoff_spec_section) -- fork-sandbox.sh's --review-only render
# site is the only caller that ever does.
#
# The "An unfollowed addendum is a finding" section is flavor-aware for the
# same reason: its "spec" wording tells the reviewer to report the gap "so
# the fix leg can carry it out", which is false in review-only mode -- a
# FINDINGS verdict there ends the run with no fix leg ever built (see
# fork-sandbox.sh's review-only loop). The review-only wording keeps the
# rule (an unfollowed addendum is still a finding) and drops only the claim
# that something downstream will act on it.
#
# Three more clauses carry the same downstream-session premise and are
# flavored the same way, for the same reason: the hands-off rule ("Do not
# touch the code"), whose "spec" wording gives "another session applies the
# fixes" as the reason not to edit; the `APPROVED` definition ("nothing
# worth another session's time"); and the invented-finding warning ("costs
# a whole extra session"). In review-only mode no session applies anything,
# so each of those premises is false. The hands-off rule in particular has
# to keep working with a true premise -- a reviewer who checks it, finds no
# downstream session, and concludes it had better fix things itself would
# edit a clone whose changes are discarded -- so its review-only wording
# keeps the rule and replaces the reason: the verdict is the run's whole
# output and edits here are thrown away. The other two are rescaled to what
# a review-only finding actually costs, the operator's time.
#
# $1  branch              the branch under review.
# $2  base_sha            the commit the branch is compared against; the
#                         range reviewed is $base_sha...HEAD.
# $3  review_skill_dir    absolute path, inside the sandbox, where
#                         code-review-portable is bound.
# $4  review_verdict_file absolute path the verdict must be written to.
# $5  inbox_dir           absolute path to the operator inbox, so an
#                         addendum-sourced finding can cite it.
# $6  handoff_file        the caller's original handoff, embedded at the end
#                         of the body; see fs_append_handoff_brief.
# $7  flavor              "spec" (default) or "review-only", forwarded to
#                         fs_emit_handoff_spec_section verbatim.
fs_emit_review_prompt_body() {
    local branch="$1" base_sha="$2" review_skill_dir="$3"
    local review_verdict_file="$4" inbox_dir="$5"
    local handoff_file="$6" flavor="${7:-spec}"
    local review_role_para addendum_para hands_off_para approved_clause
    local invented_para
    if [[ "$flavor" == "review-only" ]]; then
        review_role_para="This branch was not built in this sandbox -- it was built elsewhere,
against a spec this sandbox never had. You are reviewing it cold, with none
of the implementing session's reasoning and none of its attachment to the
result. Read what it committed and say what is wrong with it."
    else
        review_role_para="Another session worked in this same clone and committed to the branch
\`$branch\`. You are a different session, with none of its reasoning and none
of its attachment to the result. Read what it committed and say what is wrong
with it."
    fi
    if [[ "$flavor" == "review-only" ]]; then
        addendum_para="You read the operator inbox as part of every session; this leg is where that
reading has to show up in the verdict. If an addendum asks for work that the
commits under review do not contain, that is a finding. Report it as one,
with the addendum quoted. A --review-only run has no fix leg -- a FINDINGS
verdict ends the run outright -- so reporting the gap is all this leg can do
about it; do not withhold it on the assumption something downstream will act
on it instead. Do not approve a branch that leaves an operator instruction
unfollowed. You are reporting the gap here, not closing it — the next
section still applies."
    else
        addendum_para="You read the operator inbox as part of every session; this leg is where that
reading has to show up in the verdict. If an addendum asks for work that the
commits under review do not contain, that is a finding. Report it as one,
with the addendum quoted, so the fix leg can carry it out. Do not approve a
branch that leaves an operator instruction unfollowed. You are reporting the
gap here, not closing it — the next section still applies."
    fi
    if [[ "$flavor" == "review-only" ]]; then
        hands_off_para="Do not fix anything. Do not edit, stage, commit, amend, rebase or revert.
Your verdict is this run's whole output: nothing downstream applies fixes, and
every change you make in this clone is thrown away with the sandbox. Touching
the code is not someone else's job here, it is pure waste. Reading, building
and running the tests is fine — changing tracked files is not."
        approved_clause="  - \`APPROVED\` means you found nothing worth reporting to the operator. Only"
        invented_para="Say \`APPROVED\` when you mean it. An invented finding costs the operator real
time chasing it, and can talk a working branch into a change it did not need."
    else
        hands_off_para="Do not fix anything. Do not edit, stage, commit, amend, rebase or revert.
Another session applies the fixes; a review that quietly repaired what it
found leaves nobody able to tell the two apart. Reading, building and running
the tests is fine — changing tracked files is not."
        approved_clause="  - \`APPROVED\` means you found nothing worth another session's time. Only"
        invented_para="Say \`APPROVED\` when you mean it. An invented finding costs a whole extra
session and can talk a working branch into a change it did not need."
    fi
    cat <<EOF

---

# Your task: review this branch, and only review it

$review_role_para

The change is the commit range:

    $base_sha...HEAD

## Method

Follow the code-review-portable skill. It is bound into this sandbox at:

    $review_skill_dir

Read its \`SKILL.md\` and do what it says, at effort level \`high\`, for the
range above. Use the range exactly as written — three dots, base first.

## An unfollowed addendum is a finding

$addendum_para

## Do not touch the code

$hands_off_para

## Your verdict is a file

Write it to exactly this path:

    $review_verdict_file

That file is the only thing read back. A report written anywhere else — your
final message included — is discarded, so put the whole verdict in the file.

Its format is fixed, because a program reads the first line:

  - **The first line is exactly \`APPROVED\` or \`FINDINGS\`**, one word, alone
    on the line, in capitals, with no punctuation, no bullet and no heading
    marker.
$approved_clause
    the first line is parsed, so nothing after it changes what happens next
    -- but a person, or the session that launched this run, reads the file
    to decide how far to trust the approval. So after \`APPROVED\`, add a
    short paragraph beginning \`Checked:\` -- what you read, what you ran,
    and what you tried to refute and could not. The verdict should then end
    with the \`## Report\` section described below. When present, the
    orchestrator reads that report instead of the author's account; if it is
    omitted, the verdict body remains the available review account.
  - \`FINDINGS\` means you found problems. After it, write **one finding per
    paragraph**, paragraphs separated by a blank line, and **cite
    \`file:line\` in each one** — the path relative to the clone, and the line
    the problem is at. A finding with no such citation is not counted as one.
    A finding built from an addendum rather than the diff can cite the
    addendum file itself — its path under \`$inbox_dir\`, plus \`:1\` — since
    that file, not a line of code, is what the finding is about.

Order the findings worst first, and write each as a sentence or two of what is
wrong and what it breaks, not as a patch.

$invented_para

## Report

After the verdict body, you may add a \`## Report\` heading and five short
paragraphs for the orchestrator, in this order: (1) files touched; (2) tests
— what you RAN and observed, \`N ok / M fail\`, not what the author claimed;
(3) decisions visible in the diff that a reader would not guess, one line
each; (4) what is left open — on a FINDINGS verdict, include the findings
above; (5) what you are unsure of. If you include a report, use exactly one
heading and write this account from the branch and the diff, never from the
author's message. The orchestrator reads this report instead of the author's
own account. Keep the \`Checked:\` paragraph where it is, in the verdict body,
before this heading.
EOF
    fs_emit_handoff_spec_section "$handoff_file" "$flavor"
}

# inner_review is "yes" when a --review-loop ran before this one and "no"
# otherwise: the two wordings are the difference between "the diff was
# already read line by line, read around it" and "you are the branch's only
# review, so read the diff too". --maintainer-loop is supported without
# --review-loop, where the maintainer is the first and last review the
# branch gets, and the "no" wording is the one that has to be true there.
# In the "yes" case the runner appends the inner review's final verdict to
# the per-iteration prompt (or a correction when it left none), the way it
# embeds the earlier legs' addenda — the run dir is never bound into the
# sandbox, so the static prompt alone could not promise the leg a file it
# can read.
#
# As with the review body, this one ends with the same handoff section
# (fs_emit_handoff_spec_section): the maintainer decides whether the branch
# is ready to land, and a branch that was not built for what the handoff
# asked for is not ready.
#
# $6  handoff_file  the caller's original handoff, embedded at the end of
#                   the body; see fs_append_handoff_brief.
fs_emit_maintainer_prompt_body() {
    local branch="$1" base_sha="$2"
    local maintainer_verdict_file="$3" inbox_dir="$4"
    local inner_review="$5"
    local handoff_file="$6"
    local mnt_role_para
    if [[ "$inner_review" == "yes" ]]; then
        mnt_role_para="Another session worked in this same clone and committed to the branch
\`$branch\`, and an inner review loop has already read that diff line by line
— bugs, broken tests, style. That pass is done. You are the MAINTAINER, a
different session deciding whether the branch is ready to land. So read the
surrounding code, not the diff: the callers of what the change touches, the
conventions the touched files follow, the invariants the area holds, and how
this change interacts with what already exists. The inner review's final
verdict is appended to this prompt, so you have its findings to build on,
not to redo — a line-by-line reread of the diff is not the job here."
    else
        mnt_role_para="Another session worked in this same clone and committed to the branch
\`$branch\`, and no review has read that diff yet — you are the first review
it gets, and the last. You are the MAINTAINER, deciding whether the branch
is ready to land, so your review covers both sides: read the diff close —
bugs, broken tests, style — and read the surrounding code too: the callers
of what the change touches, the conventions the touched files follow, the
invariants the area holds, and how this change interacts with what already
exists."
    fi
    cat <<EOF

---

# Your task: review this branch the way a maintainer would, and only review it

$mnt_role_para

The change is the commit range:

    $base_sha...HEAD

## Method

Start from the diff, then leave it. For each file the range touches, read
the code around it: who calls it, who it calls, what the neighbouring code
looks like, what the area's invariants are. Judge the branch the way a
maintainer judging a pull request does — does it fit the codebase, does it
hold up against the code it changes, is the whole thing worth landing — not
the way a line-by-line checker does.

## An unfollowed addendum is a finding

You read the operator inbox as part of every session; this leg is where that
reading has to show up in the verdict. If an addendum asks for work that the
commits under review do not contain, that is a finding. Report it as one,
with the addendum quoted, so the fix leg can carry it out. Do not approve a
branch that leaves an operator instruction unfollowed. You are reporting the
gap here, not closing it — the next section still applies.

## Do not touch the code

Do not fix anything. Do not edit, stage, commit, amend, rebase or revert.
Another session applies the fixes; a review that quietly repaired what it
found leaves nobody able to tell the two apart. Reading, building and running
the tests is fine — changing tracked files is not.

## Your verdict is a file

Write it to exactly this path:

    $maintainer_verdict_file

That file is the only thing read back. A report written anywhere else — your
final message included — is discarded, so put the whole verdict in the file.

Its format is fixed, because a program reads the first line:

  - **The first line is exactly \`APPROVED\` or \`FINDINGS\`**, one word, alone
    on the line, in capitals, with no punctuation, no bullet and no heading
    marker.
  - \`APPROVED\` means you would land this branch. Only the first line is
    parsed, so nothing after it changes what happens next -- but this
    verdict is the run's last word on the branch, so make it count: after
    \`APPROVED\`, add a short paragraph beginning \`Checked:\` -- what you read
    around the diff, what you ran, and what you tried to refute and could
    not. The verdict should then end with the \`## Report\` section described
    below. When present, the orchestrator reads that report instead of the
    author's account; if it is omitted, the verdict body remains the
    available review account.
  - \`FINDINGS\` means the branch is not ready to land as it stands. After it,
    write **one finding per paragraph**, paragraphs separated by a blank
    line, and **cite \`file:line\` in each one** — the path relative to the
    clone, and the line the problem is at. A finding with no such citation
    is not counted as one. A finding built from an addendum rather than the
    diff can cite the addendum file itself — its path under \`$inbox_dir\`,
    plus \`:1\` — since that file, not a line of code, is what the finding is
    about.

Order the findings worst first, and write each as a sentence or two of what
is wrong and what it breaks, not as a patch.

Say \`APPROVED\` when you mean it. An invented finding costs a whole extra
fix session and can talk a working branch into a change it did not need —
and there is no inner review left behind you to catch it.

## Report

After the verdict body, you may add a \`## Report\` heading and five short
paragraphs for the orchestrator, in this order: (1) files touched; (2) tests
— what you RAN and observed, \`N ok / M fail\`, not what the author claimed;
(3) decisions visible in the diff that a reader would not guess, one line
each; (4) what is left open — on a FINDINGS verdict, include the findings
above; (5) what you are unsure of. If you include a report, use exactly one
heading and write this account from the branch and the diff, never from the
author's message. The orchestrator reads this report instead of the
author's own account. Keep the \`Checked:\` paragraph where it is, in the
verdict body, before this heading.
EOF
    fs_emit_handoff_spec_section "$handoff_file"
}

# The fix leg's task text, for fork-sandbox.sh's --review-loop and the
# maintainer loop's fix legs (same harness, same job, same text): apply the
# reviewer's findings against the same branch and commit range, on the
# understanding that an addendum-sourced finding is carried out rather than
# weighed like an ordinary one. The runner appends the verdict's FINDINGS
# body after this. Shared for the same reason as fs_emit_review_prompt_body
# above -- see its comment.
#
# The body ends with the handoff section (fs_emit_handoff_spec_fix_section)
# placed before its closing "The findings follow" paragraph, so the
# findings still land last, and the handoff sits where a leg weighing a
# finding against a deliberate decision will look for it.
#
# $1  branch    the branch that was reviewed.
# $2  base_sha  the commit the branch is compared against; the range fixed is
#               $base_sha...HEAD.
# $3  handoff_file  the caller's ORIGINAL handoff path (never the rendered
#                   copy: a fix prompt must not carry the implement
#                   preamble a second time).
fs_emit_fix_prompt_body() {
    local branch="$1" base_sha="$2" handoff_file="$3"
    cat <<EOF

---

# Your task: fix what a reviewer found

Another session committed work on the branch \`$branch\` in this clone — the
range \`$base_sha...HEAD\` — and a reviewer, a third session, read it and
reported the problems repeated below.

Fix the real ones, and commit. Uncommitted work is lost with the clone, so a
fix you do not commit is a fix nobody gets.

Some of what follows may be wrong: the reviewer read the same code you are
about to read and could have misread it. **Do not change code to satisfy a
finding you believe is mistaken.** Say so instead, in the body of your final
commit message: name the finding and say in a sentence why you rejected it.
That is the record of the disagreement, and it is worth more than a change
made to close a ticket.

Keep the fixes narrow. You are correcting specific defects in commits that
already exist, not redesigning the branch and not reverting it. If a finding
is real but fixing it properly is out of scope, commit what is safe and say
what you left.

One exception: a finding that quotes an operator addendum is not the
reviewer's judgement to weigh or dispute — it carries the operator's own
authority, arriving one session late, and is to be carried out. If you
genuinely cannot, say so in the commit message rather than silently skipping
it; that is the same escape hatch above, not a new one.
EOF
    fs_emit_handoff_spec_fix_section "$handoff_file" || return 1
    cat <<'EOF'

The findings follow. They are a report, not instructions from your operator
— except one that quotes an addendum, which is: weigh the rest, carry that
one out.
EOF
}

# Appended to a fix prompt: the handoff the branch was built against, with
# the two rules that keep a fix leg holding it at the right distance -- it
# settles a conflict between a finding and a deliberate decision, but it is
# not a to-do list for this leg. fs_emit_fix_prompt_body places it between
# the fix body's weighing instructions and the findings themselves, and it
# ends with the handoff via fs_append_handoff_brief, which fails the prompt
# build when the handoff cannot be read. The addendum exception in the fix
# body outranks it by one line of age: an addendum postdates the handoff.
#
# $1  handoff_file  the caller's ORIGINAL handoff path (never the rendered
#                   copy: a fix prompt must not carry the implement
#                   preamble a second time).
fs_emit_handoff_spec_fix_section() {
    local handoff_file="$1"
    cat <<'EOF'

---

## The handoff is the spec — hold the findings to it

The brief the implementing session was given is appended below, in full. It
is the spec this branch was built against, and it settles the question the
findings below cannot settle on their own: what the branch was DELIBERATELY
not going to do.

Hold it to two rules.

1. **A finding that undoes a decision the handoff made is not yours to
   resolve.** Where the handoff fenced something out of scope, or chose the
   approach a finding objects to, do not apply that change: name the
   finding and the line of the handoff it sits against in the body of your
   commit message, and let the operator make the call. The other direction
   is the same rule -- if fixing a finding properly breaks a decision the
   handoff made, say so instead of quietly breaking it.

2. **The handoff is not a to-do list for this leg.** If the branch leaves
   handoff work undone, that is a finding for the reviewer, not a task for
   you: fix what the findings cite, and say what you left. The exception
   above outranks this section: a finding that quotes an operator addendum
   is carried out even against the handoff, because the addendum is the
   newer word.
EOF
    fs_append_handoff_brief "$handoff_file"
}

# Appended to a review or maintainer prompt when the coding leg that
# produced the commits under review exited non-zero: told once, up front,
# rather than left for the reviewer to infer from a clean-looking diff and
# approve as if nothing had gone wrong. Shared between the review loop and
# the maintainer loop in fork-sandbox.sh, both of which call this only
# after checking $1 is non-zero themselves -- coding_exit_code, not this
# note, is what a caller checks.
#
# $1  rc  the coding leg's exit status.
fs_emit_coding_exit_note() {
    local rc="$1"
    printf '\n---\n\n## The coding session exited non-zero\n\n'
    printf 'The session that produced the commits under review exited with\n'
    printf 'status %s. Its work may be incomplete or partially applied -- read\n' \
        "$rc"
    printf 'the branch and flag anything that looks unfinished as a finding,\n'
    printf 'the same as any other defect.\n'
}

# Rewrites base..branch host-side, in $repo, so every commit's author
# identity matches want_name/want_email -- called by fork-sandbox.sh's own
# fetch-time identity check (grep "unexpected address") only after THAT
# check has already found a commit authored under some other address. This
# function re-checks the same thing itself, cheaply, before touching
# anything: it prints "0" and returns 0 with NO git writes at all -- no
# update-ref, no reflog entry -- when it finds no mismatch, which is what
# keeps a clean run's branch byte-identical to what fetch brought in. A
# caller that ran this unconditionally on every fetch would still be
# correct, just wasteful; it is written this way so a clean run costs one
# git-log more, not a rewrite.
#
# Every plumbing call on the rewrite path (merges/commits/tree/name/email/
# date lookups, cat-file, commit-tree, update-ref) is left to write its
# stderr wherever the caller's stderr goes, deliberately: a `return 1` here
# means one of those calls failed, and the caller's only way to learn why
# is whatever that command printed. Only the two calls whose failure is an
# expected, silent "no" -- the initial mismatch scan and the ancestor check
# below -- are run with stderr discarded.
#
# The rewrite is linear-only: every commit in base..branch is walked oldest
# first with rev-list --reverse and re-created with commit-tree, chained
# onto the REWRITTEN parent -- so even a commit whose author was already
# correct still gets a new SHA, because its parent's SHA changed underneath
# it. Only a commit whose author email does not already equal want_email
# has its author name and email overwritten; a correctly-authored commit
# keeps its own author name and email verbatim (just not its own SHA). A
# merge commit in range has no single "rewritten parent" to chain onto, so
# rather than guess which side wins, this returns 2 and does nothing --
# the caller keeps today's plain warning for that case instead. The same
# skip applies when $base is not even an ancestor of $branch (an amend or
# reset/rebase that dropped the starting commit from the branch's own
# history): chaining oldest..branch onto $base would otherwise splice in a
# parent the branch never actually descended from.
#
# The message body is read with cat-file + awk rather than
# `git log --format=%B`, which appends a trailing newline the raw commit
# object does not have. Byte-fidelity matters here (a Co-Authored-By
# trailer has to survive exactly), and the first WHOLLY empty line in a
# commit object's raw bytes is always the true header/body separator: git
# prefixes every continuation line of a multi-line header value (a gpgsig
# block, say) with a single space, so a genuinely empty line can never
# appear inside a header.
#
# The committer email is deliberately left unset here (no
# GIT_COMMITTER_EMAIL), so it resolves from config exactly the way an
# interactive rebase would -- this runs against $repo, the operator's own
# host-side checkout, never the clone, so that resolves to the operator's
# own identity, applied as if they had rebased the branch by hand. The
# committer NAME is pinned explicitly, though: want_name comes from a
# `git config --get user.name` in this same repo (fork-sandbox.sh reads it
# right before calling in), which is exactly what git would resolve the
# committer name to anyway when it is non-empty, so pinning it changes
# nothing observable on a normally-configured host. It matters on a host
# whose git config carries no name at all: committer resolution reads that
# same empty value, and unlike the author (which this function can always
# fall back to the commit's own existing name for) commit-tree has no
# comparable fallback of its own, so a plain, unset GIT_COMMITTER_NAME
# would turn every rewrite on such a host into the exact "empty ident
# name" fatal this function exists to get past. Falling back to this
# commit's own (already non-empty) author name keeps that host's rewrite
# working instead. commit-tree ignores commit.gpgsign entirely (it only
# signs when -S is passed, which this never does), so a host with commit
# signing configured on still gets a plain, unsigned, successful rewrite.
#
# $1  repo        the host-side repo the branch lives in (origin_repo,
#                  never the clone -- this must never run against a
#                  sandbox-writable checkout).
# $2  branch      the branch to rewrite in place, via update-ref.
# $3  base        the commit before the fetched range; base itself is
#                  never touched, only base..branch.
# $4  want_name   author name forced onto a mismatched commit. May be
#                  empty -- an origin can have user.email configured with
#                  no user.name (fs_make_clone seeds the two independently
#                  and tolerates either being unset) -- in which case a
#                  mismatched commit keeps its own author name and only
#                  its email is forced; commit-tree refuses an empty ident
#                  name outright, so forcing it through unconditionally
#                  would turn this into a guaranteed failure for exactly
#                  the configuration this feature exists to repair.
# $5  want_email  author email forced onto a mismatched commit, and the
#                  value every commit's author email is compared against.
fs_normalize_authorship() {
    local repo="$1" branch="$2" base="$3" want_name="$4" want_email="$5"
    local mismatched merges commits sha parent tree aname aemail adate msgfile n=0

    mismatched="$( (cd "$repo" && git log --format='%ae' "$base..$branch") 2>/dev/null \
        | grep -vxF -- "$want_email" )" || true
    [[ -n "$mismatched" ]] || { printf '0'; return 0; }

    merges="$( (cd "$repo" && git rev-list --min-parents=2 --count "$base..$branch") )" \
        || return 1
    [[ "$merges" == "0" ]] || return 2
    (cd "$repo" && git merge-base --is-ancestor "$base" "$branch") 2>/dev/null || return 2

    # Captured up front, not read straight from the process substitution the
    # loop used to run against: that discarded a rev-list failure silently,
    # leaving $parent at $base and the update-ref below free to rewind the
    # branch to $base -- deleting every commit in range -- while reporting
    # success. Requiring this to succeed and be non-empty (mismatched above
    # already proved the range holds at least one commit) means a rev-list
    # failure returns 1 here instead of reaching update-ref at all.
    commits="$( (cd "$repo" && git rev-list --reverse "$base..$branch") )" || return 1
    [[ -n "$commits" ]] || return 1

    msgfile="$(mktemp)" || return 1

    parent="$base"
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        tree="$( (cd "$repo" && git rev-parse "$sha^{tree}") )" \
            || { rm -f "$msgfile"; return 1; }
        aname="$( (cd "$repo" && git log -1 --format='%an' "$sha") )" \
            || { rm -f "$msgfile"; return 1; }
        aemail="$( (cd "$repo" && git log -1 --format='%ae' "$sha") )" \
            || { rm -f "$msgfile"; return 1; }
        adate="$( (cd "$repo" && git log -1 --format='%ad' --date=raw "$sha") )" \
            || { rm -f "$msgfile"; return 1; }
        if [[ "$aemail" != "$want_email" ]]; then
            [[ -n "$want_name" ]] && aname="$want_name"
            aemail="$want_email"
            n=$(( n + 1 ))
        fi
        (cd "$repo" && git cat-file commit "$sha") \
            | awk 'body{print} !body && $0==""{body=1}' > "$msgfile" \
            || { rm -f "$msgfile"; return 1; }
        parent="$(cd "$repo" \
            && GIT_AUTHOR_NAME="$aname" GIT_AUTHOR_EMAIL="$aemail" GIT_AUTHOR_DATE="$adate" \
               GIT_COMMITTER_NAME="${want_name:-$aname}" \
               git commit-tree "$tree" -p "$parent" -F "$msgfile")" \
            || { rm -f "$msgfile"; return 1; }
    done <<< "$commits"

    rm -f "$msgfile"
    # Belt-and-suspenders: refuse to move the ref at all unless the loop
    # above actually advanced $parent past $base, however that could happen.
    [[ "$parent" != "$base" ]] || return 1
    (cd "$repo" && git update-ref "refs/heads/$branch" "$parent") || return 1
    printf '%s' "$n"
    return 0
}

# --refresh-at / --refresh-max resolution, shared by fork-sandbox.sh (local)
# and fork-sandbox-k8s.sh (submit), so both apply one set of defaults and one
# set of refusals.
#
# Usage: fs_refresh_resolve <harness> <refresh_at_arg> <refresh_at_given>
#                           <refresh_max_arg> <model>
#
# <refresh_at_given> is "true" when --refresh-at was passed explicitly. It is
# refused outright on every harness but claude (the threshold is measured by
# a hook installed into the claude session), and only when GIVEN, so the 0.5
# default stays silent on a plain pi run. On success it sets, in the caller's
# scope, refresh_at, refresh_enabled (0|1), refresh_max, refresh_context_window,
# refresh_threshold_tokens and refresh_ceiling_tokens (the last three empty
# when disabled). Returns 1 after printing the reason on refusal.
# shellcheck disable=SC2034  # the results are read by the caller
fs_refresh_resolve() {
    local harness="$1" refresh_at_arg="$2" refresh_at_given="$3" \
        refresh_max_arg="$4" model="$5"
    if [[ "$refresh_at_given" == true && "$harness" != "claude" ]]; then
        echo "Error: --refresh-at only works with --harness claude. The context" >&2
        echo "threshold is measured by a hook installed into the claude session;" >&2
        echo "the other harnesses have no hook system to measure with, and this" >&2
        echo "is not built for them yet." >&2
        return 1
    fi
    if [[ -n "$refresh_max_arg" && "$harness" != "claude" ]]; then
        echo "Error: --refresh-max only applies with --harness claude, alongside" >&2
        echo "--refresh-at." >&2
        return 1
    fi
    refresh_at="0"
    [[ "$harness" == "claude" ]] && refresh_at="${refresh_at_arg:-0.5}"
    if [[ ! "$refresh_at" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: --refresh-at takes a fraction (0-1) of the context window, an" >&2
        echo "absolute token count above 1, or 0 to disable it -- not '$refresh_at'." >&2
        return 1
    fi
    # awk, not bash arithmetic, for the ">0" test: $refresh_at can be a
    # fraction ("0.5"), and bash's (( )) only understands integers.
    refresh_enabled=0
    awk -v v="$refresh_at" 'BEGIN{exit !(v>0)}' && refresh_enabled=1
    if [[ -n "$refresh_max_arg" && "$refresh_enabled" == "0" ]]; then
        echo "Error: --refresh-max requires --refresh-at (which is on by default," >&2
        echo "so this only happens with an explicit --refresh-at 0). With refresh" >&2
        echo "disabled there is no continuation loop for it to cap." >&2
        return 1
    fi
    refresh_max=6
    if [[ -n "$refresh_max_arg" ]]; then
        if [[ ! "$refresh_max_arg" =~ ^[0-9]+$ ]]; then
            echo "Error: --refresh-max takes a non-negative integer -- the number of" >&2
            echo "continuation legs that may follow the first -- not '$refresh_max_arg'." >&2
            return 1
        fi
        refresh_max="$refresh_max_arg"
    fi
    refresh_context_window=""
    refresh_threshold_tokens=""
    refresh_ceiling_tokens=""
    if (( refresh_enabled )); then
        # A one-line, one-place guess: a model whose name carries "[1m]" gets
        # the 1,000,000-token beta window; everything else gets the standard
        # 200,000. FORK_SANDBOX_CONTEXT_WINDOW overrides the guess outright,
        # and --refresh-at <tokens> (an absolute count above 1) sidesteps it,
        # since the comparison then needs no window at all.
        refresh_context_window="${FORK_SANDBOX_CONTEXT_WINDOW:-}"
        if [[ -z "$refresh_context_window" ]]; then
            case "${model,,}" in
                *'[1m]'*) refresh_context_window=1000000 ;;
                *)        refresh_context_window=200000 ;;
            esac
        fi
        if awk -v v="$refresh_at" 'BEGIN{exit !(v<=1)}'; then
            refresh_threshold_tokens="$(awk -v f="$refresh_at" \
                -v w="$refresh_context_window" 'BEGIN{printf "%d", f*w}')"
        else
            refresh_threshold_tokens="$(awk -v f="$refresh_at" 'BEGIN{printf "%d", f}')"
        fi
        # The per-leg working-room ceiling the inbox hook measures a leg's
        # OWN usage against, floor(0.8 * window): high enough to leave a
        # leg real room to work before the harness's own compaction, low
        # enough that a leg's nudge always fires before that compaction
        # would. See the hook's own comment on the B + T formula this feeds.
        refresh_ceiling_tokens="$(awk -v w="$refresh_context_window" \
            'BEGIN{printf "%d", 0.8*w}')"
    fi
    return 0
}

# Usage: fs_refresh_warn_brief <brief-file> <threshold-tokens>
#
# A large brief eats most of a leg's own working budget before it does any
# work at all: a 188 KB (~47k-token) brief against a 100k-token threshold
# left six continuations in a row spending most of their budget on setup and
# nudging with zero commits made. Advisory only -- never refuses the run.
#
# Prints ONE multi-line warning to STDOUT (not stderr: the caller decides
# where the text goes -- a terminal, a log, both) when the brief alone is
# already roughly a quarter or more of the threshold, at ~4 bytes per token
# -- i.e. its byte count is >= the token threshold itself, so no fraction
# math is needed to test it. Prints nothing and returns 0 when the brief is
# missing, the threshold is not a plain integer, or the brief is small
# enough that this does not apply.
fs_refresh_warn_brief() {
    local brief_file="$1" threshold_tokens="$2" bytes approx_tokens
    [[ -f "$brief_file" && "$threshold_tokens" =~ ^[0-9]+$ ]] || return 0
    bytes="$(wc -c < "$brief_file" 2>/dev/null || printf 0)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
    (( bytes >= threshold_tokens )) || return 0
    approx_tokens=$(( bytes / 4 ))
    printf 'fork-sandbox: this brief is %s bytes (roughly %s tokens), already a\n' \
        "$bytes" "$approx_tokens"
    printf 'quarter or more of the %s-token --refresh-at threshold -- every leg\n' \
        "$threshold_tokens"
    printf 'will spend a large share of its own budget just reading it. Consider\n'
    printf 'a "[1m]" model for a bigger context window, or a larger\n'
    printf '"--refresh-at <tokens>" given as an absolute token count.\n'
}

# fs_resolve_upstream <origin-repo> <checkout-ref-or-empty>
#
# Decides what the fetched-back branch's upstream should be, so the caller can
# set it once fetch-back has actually happened -- see fs_apply_upstream below.
# Resolved HERE, at launch, rather than at fetch time: a long run's HEAD can
# move while the sandbox works, and the upstream that made sense when the
# session was launched is the one the caller decided on, not whatever HEAD
# happens to be pointing at hours later.
#
# First match wins:
#
#   1. checkout-ref is given, and resolves (git rev-parse --symbolic-full-name)
#      to a remote-tracking ref (refs/remotes/...): that ref.
#   2. checkout-ref resolves to a local branch (refs/heads/X) that itself has
#      an upstream: X's upstream. This is what makes a second round on
#      --checkout sbx-foo inherit sbx-foo's own upstream.
#   3. Otherwise -- no checkout-ref, a local branch with no upstream, a tag, a
#      bare sha: if HEAD is on a branch that has an upstream, that upstream.
#   4. Otherwise: the remote's default branch (refs/remotes/origin/HEAD).
#   5. Otherwise: no upstream. Not an error -- plenty of repos have no remote,
#      or a remote with no default branch configured.
#
# Prints the upstream as a short ref name (e.g. "origin/dev") on stdout and
# returns 0. When there is none (case 5), prints nothing on stdout, a one-line
# reason on stderr, and still returns 0: every git call here is guarded, so a
# caller running under `set -euo pipefail` is never taken down by this
# resolution alone, which matters because losing the upstream note is a much
# smaller problem than losing the run's actual work over it.
fs_resolve_upstream() {
    local origin_repo="$1" checkout_ref="${2:-}"
    local symbolic branch_name upstream

    if [[ -n "$checkout_ref" ]]; then
        symbolic="$(cd "$origin_repo" \
            && git rev-parse --symbolic-full-name --quiet "$checkout_ref" 2>/dev/null)" \
            || symbolic=""
        if [[ "$symbolic" == refs/remotes/* ]]; then
            printf '%s\n' "${symbolic#refs/remotes/}"
            return 0
        fi
        if [[ "$symbolic" == refs/heads/* ]]; then
            branch_name="${symbolic#refs/heads/}"
            upstream="$(cd "$origin_repo" \
                && git rev-parse --abbrev-ref --symbolic-full-name \
                    "$branch_name@{upstream}" 2>/dev/null)" || upstream=""
            if [[ -n "$upstream" ]]; then
                printf '%s\n' "$upstream"
                return 0
            fi
        fi
    fi

    upstream="$(cd "$origin_repo" \
        && git rev-parse --abbrev-ref --symbolic-full-name 'HEAD@{upstream}' 2>/dev/null)" \
        || upstream=""
    if [[ -n "$upstream" ]]; then
        printf '%s\n' "$upstream"
        return 0
    fi

    symbolic="$(cd "$origin_repo" \
        && git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || symbolic=""
    if [[ -n "$symbolic" ]]; then
        printf '%s\n' "${symbolic#refs/remotes/}"
        return 0
    fi

    echo "no remote-tracking --checkout, no upstream to inherit, HEAD has none, and origin has no default branch" >&2
    return 0
}

# fs_apply_upstream <origin-repo> <branch> <upstream-or-empty> <reason-if-empty>
#
# Applies the upstream fs_resolve_upstream decided on, once the branch has
# actually landed in the origin repo by a fetch. Never fails the caller: every
# outcome, including every reason this does nothing, is a single line on
# stdout (the caller routes it wherever its own summary goes -- a terminal, a
# run's summary.txt, a k8s fetch's stderr), and the return value is always 0.
# An upstream is a convenience for `git status`/`git branch -vv`; it must
# never be the thing that makes a fetch-back look like it failed.
#
# In order:
#   - the branch does not exist in the origin repo (the 0-commit path deletes
#     it before this runs): skip.
#   - the branch already has an upstream: leave it alone. A re-fetch of a
#     branch the caller has already pointed somewhere must not clobber that
#     choice.
#   - no upstream was resolved: skip, with the reason fs_resolve_upstream gave
#     on its stderr, passed through here as the 4th argument.
#   - the resolved upstream ref no longer exists in the origin repo (deleted
#     or never fetched between launch and now): skip.
#   - otherwise, set it, with hooks disabled: this is bookkeeping on a branch
#     that already exists, not an event any hook needs to see.
fs_apply_upstream() {
    local origin_repo="$1" branch="$2" upstream="$3" reason="${4:-}"
    local existing

    if ! (cd "$origin_repo" \
        && git rev-parse --verify --quiet "refs/heads/$branch") >/dev/null 2>&1; then
        printf 'fork-sandbox: upstream not set on %s: branch not found\n' "$branch"
        return 0
    fi

    existing="$(cd "$origin_repo" \
        && git rev-parse --abbrev-ref --symbolic-full-name \
            "$branch@{upstream}" 2>/dev/null)" || existing=""
    if [[ -n "$existing" ]]; then
        printf 'fork-sandbox: upstream not set on %s: already tracks %s\n' \
            "$branch" "$existing"
        return 0
    fi

    if [[ -z "$upstream" ]]; then
        printf 'fork-sandbox: upstream not set on %s: %s\n' \
            "$branch" "${reason:-no upstream resolved}"
        return 0
    fi

    if ! (cd "$origin_repo" \
        && git rev-parse --verify --quiet "refs/remotes/$upstream") >/dev/null 2>&1; then
        printf 'fork-sandbox: upstream not set on %s: %s no longer exists\n' \
            "$branch" "$upstream"
        return 0
    fi

    if (cd "$origin_repo" && git -c core.hooksPath=/dev/null \
        branch --set-upstream-to="$upstream" "$branch") >/dev/null 2>&1; then
        printf 'fork-sandbox: upstream of %s set to %s\n' "$branch" "$upstream"
    else
        printf 'fork-sandbox: upstream not set on %s: git branch --set-upstream-to failed\n' \
            "$branch"
    fi
    return 0
}
