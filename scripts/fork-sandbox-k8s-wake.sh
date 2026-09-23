#!/usr/bin/env bash
# fork-sandbox-k8s-wake.sh -- runs one `fork-sandbox.sh --k8s` launch to
# completion and normalizes its result into the same shape a local
# tmux-detached wake leaves behind, so the postmaster's harvester
# (pm_harvest_run, pm_wake_is_dead) can read a k8s wake exactly like a
# local one: pid, exit-code, summary.json, all in one directory.
#
# This is internal plumbing fork-sandbox-postmaster.sh calls -- not a
# user-facing tool. It never talks to a cluster itself; it drives
# fork-sandbox.sh --k8s (which execs into fork-sandbox-k8s.sh run and
# blocks in the foreground until the Job ends) and reshapes what that run
# leaves behind.
#
# Usage: fork-sandbox-k8s-wake.sh <wake-dir>
#        fork-sandbox-k8s-wake.sh --detach <wake-dir>
#        fork-sandbox-k8s-wake.sh --adopt <wake-dir>
#        fork-sandbox-k8s-wake.sh --adopt --detach <wake-dir>
#        fork-sandbox-k8s-wake.sh --detach --detach-mode setsid <wake-dir>
#
# <wake-dir> is prepared by the caller with:
#   fs-argv   NUL-delimited argv; element 0 is the launcher to run (the
#             postmaster's own launcher, usually fork-sandbox.sh), the
#             rest its arguments.
#   env       NUL-delimited KEY=VALUE records to export before running.
#             Parsed strictly: a record is honored only when KEY matches
#             ^[A-Za-z_][A-Za-z0-9_]*$ -- never sourced or eval'd. Every
#             inherited FORK_SANDBOX_* variable is unset first, so a value
#             left over in a long-lived tmux server's own environment can
#             never outlive the postmaster that used to set it.
#
# Foreground mode (no --detach) blocks until the launch finishes and
# leaves, in <wake-dir>:
#   pid          this wrapper's own pid, written first, before the launch
#   pid-identity `<pid namespace> <boot id>` the pid was written under; the
#                postmaster trusts the pid only in that same namespace and
#                boot (a restarted pod's pids are unrelated to the old ones)
#   launch.log   the launch's combined stdout+stderr
#   k8s-run-dir  the k8s run directory scraped from launch.log (may be
#                empty: a refusal before submit)
#   k8s-timeout  1 when the launch ended in run's wait timeout -- the Job
#                is still running, holding its work -- else 0. rc 1 alone
#                cannot say so: run also exits 1 for an agent that exited
#                1, and for a collect failure, and neither leaves a live Job
#   exit-code    the launch's exit code (rc 3, a zero-harvest run, is
#                normalized to 0 -- see below)
#   summary.json written LAST (its presence is what marks the wake done):
#                a copy of k8s-run-dir/summary.json when that exists and
#                is valid JSON, else a synthesized {"exit_code": <rc>}
#
# rc 3 means fork-sandbox-k8s.sh's own run verb decided the wake produced
# nothing worth keeping (agent exited 0, no commits, empty outbox) and
# kept the Job for inspection -- a valid mail outcome ("no reply"), not a
# failure, so this script normalizes the recorded exit code to 0 and reaps
# that kept Job itself with `fork-sandbox-k8s.sh rm --branch <branch>`
# (branch parsed out of fs-argv), logging the reap to launch.log; a failed
# reap does not change the recorded rc. Every other nonzero rc is left
# exactly as fork-sandbox.sh reported it, and the Job is left in place --
# that is the k8s path's own evidence policy for a real failure, not this
# wrapper's to override.
#
# --adopt <wake-dir> takes over a wake whose wrapper died (a postmaster
# host restart, a pod eviction) while its Job kept running: it writes pid
# and pid-identity, applies `env`, finds the k8s run directory (the
# k8s-run-dir file when it names an existing directory, else the
# "  run dir:" line in launch.log), appends
# `--- fork-sandbox-k8s-wake: adopting <branch> (attempt <n>) ---` to
# launch.log (never truncating it), runs
# `fork-sandbox-k8s.sh resume --run-dir <dir>` with its output appended
# there, and then normalizes the result exactly as above. No run
# directory is a failure: exit-code 1 and a synthesized summary.json.
# <n> is <wake-dir>/adopt-count, an integer the CALLER (the postmaster)
# increments atomically before each adoption; this script never writes it.
#
# --detach <wake-dir> starts this same script on <wake-dir>, in the
# foreground mode above, inside a detached tmux session named
# cc-k8s-<branch, sanitized to [A-Za-z0-9_-]>, and returns 0 -- or exits 1
# if tmux cannot start one. Named cc-k8s-*, not cc-sbx-* (fork-sandbox.sh's
# own local-wake prefix): operators treat a live cc-sbx-* session as
# local-run machinery in flight, and a k8s wake is not that. With --adopt
# the run.sh it writes execs `--adopt <wake-dir>`.
#
# --detach-mode setsid|tmux (default tmux) picks how --detach detaches. With
# setsid (a postmaster running in a pod has no tmux) the same run.sh is
# started under `setsid --fork`, stdin from /dev/null and stdout/stderr to
# <wake-dir>/wake.out; --detach returns 0 once setsid has forked, or exits 1
# if it could not. The pid the wake records is its own either way.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

# Reads a NUL-delimited file into the named array, one element per record.
# Bash's own `read -d ''` (a builtin, not a GNU coreutils flag) rather than
# `mapfile -d ''`, which needs bash >= 4.4 -- kept consistent with the
# `while IFS= read -r -d ''` idiom already used elsewhere in this repo.
fs_k8s_wake_read_nul() {
    local -n _fs_k8s_wake_out="$1"
    local file="$2" chunk
    _fs_k8s_wake_out=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r -d '' chunk; do
        _fs_k8s_wake_out+=("$chunk")
    done < "$file"
}

# Writes $content to $dest via mktemp+mv in the same directory, so a
# reader never observes a partially-written file.
fs_k8s_wake_write_atomic() {
    local dest="$1" content="$2" tmp
    tmp="$(mktemp "$dest.XXXXXX")"
    printf '%s' "$content" > "$tmp"
    mv -f -- "$tmp" "$dest"
}

# `<pidns> <boot_id>`: the identity the recorded pid is only valid under.
# The postmaster's pm_pid_identity reads the same two sources, with the
# same overrides.
fs_k8s_wake_pid_identity() {
    local ns boot
    ns="$(readlink -- "${FORK_SANDBOX_POSTMASTER_PROC_PIDNS:-/proc/self/ns/pid}" 2>/dev/null)" || ns=""
    boot="$(cat -- "${FORK_SANDBOX_POSTMASTER_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)" || boot=""
    printf '%s %s' "$ns" "$boot"
}

fs_k8s_wake_branch_from_argv() {
    local -n _fs_k8s_wake_argv="$1"
    local i
    for (( i = 0; i < ${#_fs_k8s_wake_argv[@]}; i++ )); do
        if [[ "${_fs_k8s_wake_argv[$i]}" == --branch ]]; then
            printf '%s' "${_fs_k8s_wake_argv[$((i + 1))]:-}"
            return 0
        fi
    done
}

# Clears every inherited FORK_SANDBOX_* variable, then exports the wake
# dir's own `env` records. tmux's detached session inherits whatever the
# tmux SERVER's own environment was when it first started -- not this
# process's current one -- so a long-lived server can still be carrying a
# FORK_SANDBOX_* value a later postmaster no longer sets (or sets
# differently). Clearing first means a stale value can never leak through
# unnoticed.
fs_k8s_wake_apply_env() {
    local wake_dir="$1" stale_var
    for stale_var in "${!FORK_SANDBOX_@}"; do
        unset "$stale_var"
    done

    local -a env_records
    fs_k8s_wake_read_nul env_records "$wake_dir/env"
    local rec key
    for rec in "${env_records[@]}"; do
        [[ "$rec" == *=* ]] || continue
        key="${rec%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "$key=${rec#*=}"
    done
}

# The normalization tail both paths share: k8s-run-dir, k8s-timeout, the
# rc 3 -> 0 normalization with its reap, exit-code, and summary.json last.
# Args: wake_dir rc branch [run_dir_hint] [log_offset]. run_dir_hint, when
# non-empty, is used instead of scraping launch.log (the adopt path already
# resolved it); log_offset is the byte size launch.log had before this
# attempt's own output began, so a timeout message left by an EARLIER
# attempt is never mistaken for this one's. Exits with the final rc.
fs_k8s_wake_finish() {
    local wake_dir="$1" rc="$2" branch="$3" run_dir_hint="${4-}" log_offset="${5-0}"

    local k8s_run_dir="$run_dir_hint"
    if [[ -z "$k8s_run_dir" ]]; then
        k8s_run_dir="$(sed -n 's/^  run dir:  *//p' "$wake_dir/launch.log" | head -n1)"
    fi
    fs_k8s_wake_write_atomic "$wake_dir/k8s-run-dir" "$k8s_run_dir"

    # A timeout is the one rc 1 that writes no summary.json (collect never
    # ran) and prints cmd_wait's own message; requiring both keeps an
    # agent's exit 1 on the ordinary failure-and-retry path.
    local timed_out=0
    if (( rc == 1 )) && [[ -n "$k8s_run_dir" && ! -e "$k8s_run_dir/summary.json" ]] \
        && tail -c "+$((log_offset + 1))" "$wake_dir/launch.log" \
            | grep -q '^Error: timed out after [0-9]*s waiting for branch'; then
        timed_out=1
    fi
    fs_k8s_wake_write_atomic "$wake_dir/k8s-timeout" "$timed_out"

    if (( rc == 3 )); then
        rc=0
        if [[ -n "$branch" ]]; then
            {
                echo "--- fork-sandbox-k8s-wake: reaping zero-harvest Job for branch $branch ---"
                "$script_dir/fork-sandbox-k8s.sh" rm --branch "$branch"
            } >> "$wake_dir/launch.log" 2>&1 || true
        fi
    fi

    fs_k8s_wake_write_atomic "$wake_dir/exit-code" "$rc"

    # summary.json is the LAST artifact written -- its presence is what
    # tells the harvester this wake is done. A k8s summary is copied
    # through only when it exists and parses; anything else (refusal
    # before submit, a dead pod, a timeout) gets a synthesized stand-in
    # carrying just the exit code, same as a local wake's own fallback.
    local tmp_summary
    tmp_summary="$(mktemp "$wake_dir/summary.json.XXXXXX")"
    if [[ -n "$k8s_run_dir" ]] && jq empty -- "$k8s_run_dir/summary.json" >/dev/null 2>&1; then
        cp -f -- "$k8s_run_dir/summary.json" "$tmp_summary"
    else
        printf '{"exit_code": %s}' "$rc" > "$tmp_summary"
    fi
    mv -f -- "$tmp_summary" "$wake_dir/summary.json"

    exit "$rc"
}

fs_k8s_wake_run() {
    local wake_dir="$1"
    [[ -d "$wake_dir" ]] || {
        echo "Error: fork-sandbox-k8s-wake: no such wake directory: $wake_dir" >&2
        exit 1
    }

    # Written first, before the launch even starts: this is what lets a
    # caller (fs_pm_env_get/pm_wake_is_dead's pid-file check) tell "this
    # wrapper is alive" apart from "nothing has run yet" the same way a
    # local wake's own pid file does.
    fs_k8s_wake_write_atomic "$wake_dir/pid" "$$"
    fs_k8s_wake_write_atomic "$wake_dir/pid-identity" "$(fs_k8s_wake_pid_identity)"

    local -a fs_argv
    fs_k8s_wake_read_nul fs_argv "$wake_dir/fs-argv"
    if (( ${#fs_argv[@]} == 0 )); then
        echo "Error: fork-sandbox-k8s-wake: $wake_dir/fs-argv is empty or missing." >&2
        exit 1
    fi

    fs_k8s_wake_apply_env "$wake_dir"

    local branch
    branch="$(fs_k8s_wake_branch_from_argv fs_argv)"

    # `set -e` must never kill this wrapper before summary.json/exit-code
    # are written below -- a wrapper that dies here leaves the harvester
    # with neither, wedged exactly like the crash this file exists to make
    # visible instead of hidden.
    local rc=0
    set +e
    "${fs_argv[@]}" > "$wake_dir/launch.log" 2>&1
    rc=$?
    set -e

    fs_k8s_wake_finish "$wake_dir" "$rc" "$branch"
}

# Picks the run dir an adopted wake resumes: k8s-run-dir when it names an
# existing directory, else the "  run dir:" line submit left in launch.log.
fs_k8s_wake_find_run_dir() {
    local wake_dir="$1" cand
    if cand="$(cat -- "$wake_dir/k8s-run-dir" 2>/dev/null)" \
        && [[ -n "$cand" && -d "$cand" ]]; then
        printf '%s' "$cand"
        return 0
    fi
    cand="$(sed -n 's/^  run dir:  *//p' "$wake_dir/launch.log" 2>/dev/null | head -n1)"
    if [[ -n "$cand" && -d "$cand" ]]; then
        printf '%s' "$cand"
        return 0
    fi
    return 1
}

# Takes over a wake whose original wrapper died while its Job kept going:
# skips submit, resumes wait + collect into the same directories, and
# normalizes the result exactly as the normal path does.
fs_k8s_wake_adopt() {
    local wake_dir="$1"
    [[ -d "$wake_dir" ]] || {
        echo "Error: fork-sandbox-k8s-wake: no such wake directory: $wake_dir" >&2
        exit 1
    }

    fs_k8s_wake_write_atomic "$wake_dir/pid" "$$"
    fs_k8s_wake_write_atomic "$wake_dir/pid-identity" "$(fs_k8s_wake_pid_identity)"

    fs_k8s_wake_apply_env "$wake_dir"

    local -a fs_argv
    fs_k8s_wake_read_nul fs_argv "$wake_dir/fs-argv"
    local branch attempt
    branch="$(fs_k8s_wake_branch_from_argv fs_argv)"
    attempt="$(cat -- "$wake_dir/adopt-count" 2>/dev/null || true)"
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1

    local log_offset=0
    [[ -f "$wake_dir/launch.log" ]] && log_offset="$(wc -c < "$wake_dir/launch.log")"
    log_offset="${log_offset//[[:space:]]/}"

    local run_dir="" rc=0
    if ! run_dir="$(fs_k8s_wake_find_run_dir "$wake_dir")"; then
        run_dir=""
        {
            echo "--- fork-sandbox-k8s-wake: adopting $branch (attempt $attempt) ---"
            echo "Error: fork-sandbox-k8s-wake: cannot adopt: no k8s run directory recorded for this wake."
        } >> "$wake_dir/launch.log"
        rc=1
    else
        echo "--- fork-sandbox-k8s-wake: adopting $branch (attempt $attempt) ---" >> "$wake_dir/launch.log"
        set +e
        "$script_dir/fork-sandbox-k8s.sh" resume --run-dir "$run_dir" >> "$wake_dir/launch.log" 2>&1
        rc=$?
        set -e
    fi

    fs_k8s_wake_finish "$wake_dir" "$rc" "$branch" "$run_dir" "$log_offset"
}

fs_k8s_wake_detach() {
    local wake_dir="$1" adopt="$2"
    [[ -d "$wake_dir" ]] || {
        echo "Error: fork-sandbox-k8s-wake: no such wake directory: $wake_dir" >&2
        exit 1
    }

    local -a fs_argv
    fs_k8s_wake_read_nul fs_argv "$wake_dir/fs-argv"
    local branch
    branch="$(fs_k8s_wake_branch_from_argv fs_argv)"
    local session_name
    session_name="cc-k8s-$(printf '%s' "$branch" | tr -c 'A-Za-z0-9_-' '-')"

    local -a self=("$script_dir/fork-sandbox-k8s-wake.sh")
    (( adopt )) && self+=(--adopt)
    self+=("$wake_dir")

    # tmux's own multi-argv command handling is not to be relied on (see
    # header) -- write a tiny run.sh, the same shape fork-sandbox.sh's own
    # tmux launch uses, and pass tmux that ONE path as its command.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec'
        printf ' %q' "${self[@]}"
        printf '\n'
    } > "$wake_dir/run.sh"
    chmod +x -- "$wake_dir/run.sh"

    if [[ "$detach_mode" == setsid ]]; then
        if ! setsid --fork "$wake_dir/run.sh" </dev/null >"$wake_dir/wake.out" 2>&1; then
            echo "Error: fork-sandbox-k8s-wake: setsid could not start the wake." >&2
            exit 1
        fi
        exit 0
    fi
    if ! tmux new-session -d -s "$session_name" -n "$session_name" \
        "$wake_dir/run.sh"; then
        echo "Error: fork-sandbox-k8s-wake: tmux could not start a detached session." >&2
        exit 1
    fi
    exit 0
}

adopt=0 detach=0 detach_mode=tmux wake_dir=""
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --adopt) adopt=1; shift ;;
        --detach) detach=1; shift ;;
        --detach-mode)
            detach_mode="${2:?--detach-mode requires setsid or tmux}"
            case "$detach_mode" in
                setsid|tmux) ;;
                *) echo "Error: fork-sandbox-k8s-wake: --detach-mode takes setsid or tmux, not '$detach_mode'." >&2; exit 1 ;;
            esac
            shift 2 ;;
        -*) echo "Error: fork-sandbox-k8s-wake: unknown option '$1'." >&2; exit 1 ;;
        *) wake_dir="$1"; shift ;;
    esac
done
[[ -n "$wake_dir" ]] || {
    echo "Usage: fork-sandbox-k8s-wake.sh [--adopt] [--detach [--detach-mode setsid|tmux]] <wake-dir>" >&2
    exit 1
}

if (( detach )); then
    fs_k8s_wake_detach "$wake_dir" "$adopt"
elif (( adopt )); then
    fs_k8s_wake_adopt "$wake_dir"
else
    fs_k8s_wake_run "$wake_dir"
fi
