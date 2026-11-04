#!/usr/bin/env bash
# fork-sandbox-prune.sh — Reclaim the clones of finished local fork-sandbox runs
#
# Usage: fork-sandbox-prune.sh [--dry-run] [--older-than DAYS]
#        fork-sandbox-prune.sh --auto
#
# Nothing else ever deletes a finished run's directory, and almost all of
# its size is the run's clone/. This removes that clone/ and nothing else:
# summary.json, events, exit-code, outbox/, run.env, handoffs, logs and
# scripts/ all stay, so `fork-sandbox status`, `status --result`,
# `status --json` and `fork-sandbox log` keep working on the run dir. A
# pruned run dir gets a clone-pruned marker (pruned_at=<epoch>, bytes=<n>),
# and `fork-sandbox status` says "pruned" on its clone: line rather than
# naming a directory that is gone.
#
# --dry-run          list what would be pruned, with sizes; delete nothing.
# --older-than DAYS  retention age, a whole number of days from 0 to 36500,
#                    measured from the run's own ended_at in summary.json
#                    (never the run dir's mtime). Default: the configured
#                    retention below when it is a positive number, else 14;
#                    a configured value that is not a whole number from 0
#                    to 36500 is refused rather than replaced by 14.
# --auto             what `fork-sandbox run` starts, detached, at every
#                    launch: prune with the configured retention, print
#                    nothing, and append one summary line to
#                    <forks-root>/.fork-sandbox-prune.log. A retention of 0
#                    makes it do nothing at all.
#                    The launcher starts it only when its config dir is
#                    the login user's own ~/.config/fork-sandbox, so a
#                    test's temporary config never prunes the real root.
# -h, --help         print this header and exit.
#
# Output: one line per run dir pruned (or, with --dry-run, that would be),
# with the bytes its clone held; then a total; then how many run dirs were
# skipped, by reason.
#
# A run dir's clone is pruned only when ALL of these hold:
#   - it is a directory directly under the forks root
#     (/var/tmp/claude-scratch/forks), named claude-fork-sandbox.*, that is
#     not a symlink and resolves to exactly that path, and its run.env is
#     the launcher's: a regular file with version= and a run_dir= naming
#     this same directory. Anything else is "not-a-run" or "unsafe-path"
#     and is never touched; other tools' dirs under the root are not even
#     looked at.
#   - it is a local run: a --k8s run (network=cluster) is "k8s-run".
#   - it has a clone/ that is a real directory, not a symlink, resolving
#     inside the run dir ("no-clone", "already-pruned", "unsafe-path").
#   - it is not live: its recorded pid is not a live process (the same
#     zombie-aware test `fork-sandbox status` uses) and no tmux session of
#     its recorded name exists ("live").
#   - it has ended: summary.json and exit-code are both present, regular
#     files ("not-ended"; the runner writes summary.json last, so a run
#     that crashed before it also lands here).
#   - its branch came home: summary.json has fetched: true ("not-fetched")
#     and uncommitted_files: 0 ("uncommitted-work" when it is more,
#     "uncommitted-unknown" when null or absent). Such a run may still need
#     its clone for the rescue procedure, so it is never pruned.
#   - it ended more than DAYS days ago, per summary.json's ended_at
#     ("too-recent"; "no-end-time" when ended_at is missing).
#
# Safety. It never follows a symlink and never deletes outside the forks
# root (every path is checked after resolving it). It runs no git at all:
# a clone's git config is sandbox-writable, and a git command run inside it
# executes on the host. Deletion stays on one filesystem. Two prunes never
# overlap: each holds an flock on <forks-root>/.fork-sandbox-prune.lock, and
# a second one exits 0 at once (silently under --auto).
#
# Configuration. FORK_SANDBOX_RUN_RETENTION_DAYS in
# ~/.config/fork-sandbox/runs.env (FORK_SANDBOX_CONFIG_DIR overrides the
# directory): the retention, in days, for --auto and the default for the
# verb. Default 14; 0 turns the automatic prune off but not this verb.
#
# FORK_SANDBOX_PRUNE_ROOT overrides the forks root, for tests only.
#
# See docs/prune.md.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

die() {
    echo "fork-sandbox-prune: $*" >&2
    exit 2
}

# True when $1 is a whole number of days from 0 to MAX_DAYS. Leading zeros
# are stripped before the length check, so no arithmetic ever sees a value
# long enough to overflow.
valid_days() {
    local d="$1"
    [[ "$d" =~ ^[0-9]+$ ]] || return 1
    d="${d#"${d%%[!0]*}"}"
    (( ${#d} <= ${#MAX_DAYS} )) && (( 10#${d:-0} <= MAX_DAYS ))
}

fs_require_gnu_tools || exit 1

DEFAULT_DAYS=14
# The largest retention accepted, about a century. Beyond it DAYS * 86400
# would soon overflow bash arithmetic and wrap the cutoff into the future,
# turning "keep for a very long time" into "prune everything that ended".
MAX_DAYS=36500
LOCK_NAME='.fork-sandbox-prune.lock'
LOG_NAME='.fork-sandbox-prune.log'
MARKER_NAME='clone-pruned'
# Every reason a run dir can be skipped for, in the order they are reported.
SKIP_REASONS=(live not-ended not-fetched uncommitted-work uncommitted-unknown
    too-recent no-end-time unreadable-summary already-pruned no-clone k8s-run
    not-a-run unsafe-path)

dry_run=0
auto=0
older_than=""
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) dry_run=1; shift ;;
        --auto) auto=1; shift ;;
        --older-than)
            (($# >= 2)) || die "--older-than needs a number of days"
            older_than="$2"; shift 2 ;;
        --older-than=*) older_than="${1#*=}"; shift ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

if (( auto )) && { (( dry_run )) || [[ -n "$older_than" ]]; }; then
    die "--auto takes no other option; it reads its retention from the config"
fi
if [[ -n "$older_than" ]] && ! valid_days "$older_than"; then
    die "--older-than must be a whole number of days from 0 to $MAX_DAYS, got '$older_than'"
fi

config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
runs_env="$config_dir/runs.env"
configured_days="$(fs_read_env_value "$runs_env" FORK_SANDBOX_RUN_RETENTION_DAYS 2>/dev/null)" \
    || configured_days=""

forks_root="${FORK_SANDBOX_PRUNE_ROOT:-$FS_SCRATCH_ROOT/forks}"
# No forks root yet means no runs yet: nothing to do.
[[ -d "$forks_root" ]] || exit 0
root_real="$("$FS_REALPATH" -e -- "$forks_root")"

auto_log() {
    local log="$root_real/$LOG_NAME"
    [[ -L "$log" ]] && return 0
    # Keep the log from growing without bound: one line per launch adds up.
    if [[ -f "$log" ]] && (( $("$FS_STAT" -c %s -- "$log" 2>/dev/null || echo 0) > 262144 )); then
        tail -n 1000 -- "$log" > "$log.tmp" 2>/dev/null && mv -f -- "$log.tmp" "$log"
    fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log"
}

if (( auto )); then
    days="${configured_days:-$DEFAULT_DAYS}"
    if ! valid_days "$days"; then
        auto_log "prune --auto: $runs_env sets FORK_SANDBOX_RUN_RETENTION_DAYS='$days', not a whole number of days from 0 to $MAX_DAYS; nothing pruned"
        exit 0
    fi
    days=$((10#$days))
    (( days > 0 )) || exit 0
elif [[ -n "$older_than" ]]; then
    days=$((10#$older_than))
elif [[ -n "$configured_days" ]] && ! valid_days "$configured_days"; then
    # Falling back to 14 here would prune far sooner than whatever an
    # operator who wrote, say, a huge number meant.
    die "$runs_env sets FORK_SANDBOX_RUN_RETENTION_DAYS='$configured_days', not a whole number of days from 0 to $MAX_DAYS; fix it or pass --older-than"
elif [[ -n "$configured_days" ]] && (( 10#$configured_days > 0 )); then
    days=$((10#$configured_days))
else
    days=$DEFAULT_DAYS
fi

lock_file="$root_real/$LOCK_NAME"
[[ -L "$lock_file" ]] && die "$lock_file is a symlink; refusing to use it"
exec {lock_fd}>>"$lock_file"
if ! flock -n "$lock_fd"; then
    (( auto )) || echo "fork-sandbox-prune: another prune is running; nothing done" >&2
    exit 0
fi

# Sizes for people: whole bytes below 1 KiB, one decimal above.
human() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# Bytes on disk under a directory, one filesystem, symlinks not followed.
disk_bytes() {
    local out
    out="$(du -s -x -B1 -- "$1" 2>/dev/null | cut -f1)" || true
    [[ "$out" =~ ^[0-9]+$ ]] || out=0
    printf '%s' "$out"
}

declare -A live_sessions=()
if command -v tmux >/dev/null 2>&1; then
    while IFS= read -r s; do
        [[ -n "$s" ]] && live_sessions["$s"]=1
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
fi

# The liveness test fork-sandbox-status.sh's run_state() applies -- the
# recorded runner pid, zombie-aware -- plus the run's own tmux session,
# which a --keep-session run keeps open after its runner is gone.
run_is_live() {
    local rd="$1" pid session
    if [[ -f "$rd/pid" && ! -L "$rd/pid" ]]; then
        pid="$(tr -dc '0-9' < "$rd/pid")"
        if [[ -n "$pid" ]] && fs_status_pid_alive "$pid"; then
            return 0
        fi
    fi
    session="$(fs_read_env_value "$rd/run.env" session 2>/dev/null)" || session=""
    [[ -n "$session" && -n "${live_sessions[$session]-}" ]]
}

# Sets skip_reason to one of SKIP_REASONS, or to "" when the run dir's
# clone may be pruned.
classify() {
    local rd="$1" name real clone_real env_run_dir network fields
    local fetched uncommitted ended_at
    name="${rd##*/}"
    skip_reason=unsafe-path
    [[ -L "$rd" ]] && return 0
    skip_reason=not-a-run
    [[ -d "$rd" ]] || return 0
    skip_reason=unsafe-path
    real="$("$FS_REALPATH" -e -- "$rd" 2>/dev/null)" || return 0
    [[ "$real" == "$root_real/$name" ]] || return 0
    [[ -L "$rd/run.env" ]] && return 0
    skip_reason=not-a-run
    [[ -f "$rd/run.env" ]] || return 0
    fs_read_env_value "$rd/run.env" version >/dev/null 2>&1 || return 0
    env_run_dir="$(fs_read_env_value "$rd/run.env" run_dir 2>/dev/null)" || return 0
    [[ "${env_run_dir%/}" == */"$name" ]] || return 0

    network="$(fs_read_env_value "$rd/run.env" network 2>/dev/null)" || network=""
    skip_reason=k8s-run
    [[ "$network" == cluster ]] && return 0

    skip_reason=unsafe-path
    [[ -L "$rd/clone" || -L "$rd/$MARKER_NAME" ]] && return 0
    if [[ ! -e "$rd/clone" ]]; then
        skip_reason=no-clone
        [[ -f "$rd/$MARKER_NAME" ]] && skip_reason=already-pruned
        return 0
    fi
    [[ -d "$rd/clone" ]] || return 0
    clone_real="$("$FS_REALPATH" -e -- "$rd/clone" 2>/dev/null)" || return 0
    [[ "$clone_real" == "$root_real/$name/clone" ]] || return 0

    skip_reason=live
    run_is_live "$rd" && return 0

    skip_reason=unsafe-path
    [[ -L "$rd/summary.json" || -L "$rd/exit-code" ]] && return 0
    skip_reason=not-ended
    [[ -f "$rd/summary.json" && -f "$rd/exit-code" ]] || return 0

    skip_reason=unreadable-summary
    fields="$(jq -r '[
            (if .fetched == true then "true" else "false" end),
            (if .uncommitted_files == 0 then "0"
             elif .uncommitted_files == null then "null" else "some" end),
            (if (.ended_at | type) == "number" then (.ended_at | floor | tostring) else "-" end)
        ] | join(" ")' -- "$rd/summary.json" 2>/dev/null)" || return 0
    read -r fetched uncommitted ended_at <<<"$fields" || return 0

    skip_reason=not-fetched
    [[ "$fetched" == true ]] || return 0
    case "$uncommitted" in
        0) ;;
        null) skip_reason='uncommitted-unknown'; return 0 ;;
        *) skip_reason='uncommitted-work'; return 0 ;;
    esac
    skip_reason=no-end-time
    [[ "$ended_at" =~ ^[0-9]+$ ]] || return 0
    skip_reason=too-recent
    (( ended_at < cutoff )) || return 0
    skip_reason=""
}

# Removes RUN_DIR/clone, after recording that it did. The marker goes first
# so a removal that fails part-way still reads as pruned (partially) rather
# than as an intact clone; a later prune finds the clone still there and
# tries again. Returns non-zero when something could not be removed.
prune_clone() {
    local rd="$1" bytes="$2" tmp
    tmp="$(mktemp -- "$rd/.$MARKER_NAME.XXXXXX")" || return 1
    printf 'pruned_at=%s\nbytes=%s\n' "$(date +%s)" "$bytes" > "$tmp"
    mv -f -T -- "$tmp" "$rd/$MARKER_NAME" || { rm -f -- "$tmp"; return 1; }
    # A sandboxed tool can leave directories without owner write or search
    # permission (a Go module cache, for one), and rm cannot empty those.
    # find does not follow symlinks and -xdev keeps it on this filesystem.
    find "$rd/clone" -xdev -type d ! -perm -u=wx -exec chmod u+wx -- {} + 2>/dev/null || true
    rm -rf --one-file-system -- "$rd/clone"
}

now="$(date +%s)"
cutoff=$(( now - days * 86400 ))

declare -A skipped=()
pruned=0 failed=0 total_bytes=0
shopt -s nullglob
for rd in "$root_real"/claude-fork-sandbox.*; do
    classify "$rd"
    if [[ -n "$skip_reason" ]]; then
        skipped[$skip_reason]=$(( ${skipped[$skip_reason]-0} + 1 ))
        continue
    fi
    bytes="$(disk_bytes "$rd/clone")"
    if (( dry_run )); then
        (( auto )) || printf 'would prune  %s  %s\n' "$rd" "$(human "$bytes")"
    elif prune_clone "$rd" "$bytes"; then
        (( auto )) || printf 'pruned  %s  %s\n' "$rd" "$(human "$bytes")"
    else
        left=0
        [[ -e "$rd/clone" ]] && left="$(disk_bytes "$rd/clone")"
        failed=$(( failed + 1 ))
        bytes=$(( bytes > left ? bytes - left : 0 ))
        (( auto )) || printf 'PARTIAL  %s  %s freed, %s could not be removed\n' \
            "$rd" "$(human "$bytes")" "$(human "$left")"
    fi
    pruned=$(( pruned + 1 ))
    total_bytes=$(( total_bytes + bytes ))
done

skip_total=0
skip_detail=""
for reason in "${SKIP_REASONS[@]}"; do
    n="${skipped[$reason]-0}"
    (( n > 0 )) || continue
    skip_total=$(( skip_total + n ))
    skip_detail+="${skip_detail:+, }$reason $n"
done

if (( auto )); then
    line="prune --auto (retention $days days): pruned $pruned run(s), freed $(human "$total_bytes")"
    (( failed == 0 )) || line+=" ($failed only partially)"
    line+="; skipped $skip_total${skip_detail:+ ($skip_detail)}"
    auto_log "$line"
    exit 0
fi

if (( dry_run )); then
    printf 'total: would prune %d run(s) older than %d days, freeing %s\n' \
        "$pruned" "$days" "$(human "$total_bytes")"
else
    printf 'total: pruned %d run(s) older than %d days, freed %s\n' \
        "$pruned" "$days" "$(human "$total_bytes")"
fi
printf 'skipped: %d\n' "$skip_total"
for reason in "${SKIP_REASONS[@]}"; do
    n="${skipped[$reason]-0}"
    if (( n > 0 )); then printf '  %-20s %d\n' "$reason" "$n"; fi
done
if (( failed )); then
    printf '%d clone(s) could not be removed completely; see the PARTIAL lines above\n' "$failed" >&2
    exit 1
fi
exit 0
