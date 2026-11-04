#!/usr/bin/env bash
# lane-mail-lib.sh -- Shared constants and config readers for lane mail
#
# Usage: source "$script_dir/lane-mail-lib.sh"   (not run directly)
#
# Sourced by lane-mail.sh, lane-mail-serve and fork-sandbox-mail.sh, so the
# three agree on where lane mail lives, what a host name looks like, and
# which host this is. Defines no commands of its own.
#
# LANE_MAIL_ROOT is the fixed lane-mail store (see lane-mail.sh's header for
# why it is a constant and never a parameter). It lives here, once, so the
# client and the server can never disagree about it.
#
# Per-machine values are read at run time from the config dir
# ($FORK_SANDBOX_CONFIG_DIR, default ~/.config/fork-sandbox), never from this
# repo, and never `source`d -- a config file is not the place to accept shell:
#
#   lane-mail.env     one NAME=VALUE per line:
#       LANE_MAIL_PEER_NAME=  this host's peer name (lowercase alphanumeric,
#                             '-' and '.'). Default: the short hostname,
#                             lowercased.
#       LANE_MAIL_SSH=        the ssh client command (split on whitespace,
#                             no quoting). Default: ssh.
#       LANE_MAIL_SSH_TIMEOUT=  ssh ConnectTimeout in seconds. Default 10.
#   lane-mail-peers   one `<peer> <ssh destination>` per line, '#' comments:
#                     where an outgoing `@lane:<peer>` message is delivered.

# shellcheck disable=SC2034  # used by the scripts that source this file
LANE_MAIL_ROOT=/var/tmp/claude-scratch/lane-mail

# shellcheck disable=SC2034
LANE_MAIL_LANE_RE='^[a-z0-9][a-z0-9-]*$'
LANE_MAIL_HOST_RE='^[a-z0-9][a-z0-9.-]*$'

lane_mail_config_dir() {
    printf '%s' "${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
}

lane_mail_peers_file() {
    printf '%s/lane-mail-peers' "$(lane_mail_config_dir)"
}

# Prints the value of one NAME=VALUE line of lane-mail.env (first match
# wins); returns 1 when the file or the key is absent.
lane_mail_env_value() {
    local key="$1" file line
    file="$(lane_mail_config_dir)/lane-mail.env"
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

# Prints this host's peer name; returns 1 (printing nothing) when the
# configured or derived name is not a valid one.
lane_mail_self_name() {
    local name
    name="$(lane_mail_env_value LANE_MAIL_PEER_NAME || true)"
    if [[ -z "$name" ]]; then
        name="${HOSTNAME:-}"
        [[ -n "$name" ]] || name="$(hostname 2>/dev/null || true)"
        name="${name%%.*}"
        name="${name,,}"
    fi
    [[ "$name" =~ $LANE_MAIL_HOST_RE ]] || return 1
    printf '%s' "$name"
}

# Prints the ssh destination the peers file gives for peer $1; returns 1
# when the file has no such peer. A destination that could be read by ssh as
# an option (leading '-') is never returned.
lane_mail_peer_dest() {
    local want="$1" file line name dest extra
    file="$(lane_mail_peers_file)"
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read -r name dest extra <<<"$line"
        [[ "$name" == "$want" && -n "$dest" && -z "$extra" ]] || continue
        [[ "$dest" == -* ]] && return 1
        printf '%s' "$dest"
        return 0
    done < "$file"
    return 1
}

# --- Session registrations and their liveness ------------------------------
#
# A registration (`lane-mail.sh register`, one file per Claude Code session
# in the per-user registry directory) holds the lane name on its first line;
# every reader takes that line and nothing else, so a file written before
# liveness existed (the lane name alone) reads the same. After it come
# `key=value` lines naming the session's owning process:
#
#   owner_pid=    the pid of the Claude Code CLI process that registered
#   owner_start=  that process's start time (field 22 of /proc/<pid>/stat),
#                 so a pid reused by another process does not read as alive
#   tmux_pane=    $TMUX_PANE at the time, when set; information only (a pane
#                 outlives its session, so it is never the liveness test)
#
# A registration is live when its owner_pid exists with the same start time;
# one with no owner recorded is not live. Its last-seen time is the file's
# mtime: the registration time, refreshed by the lane-mail hook on every turn
# of the session (lane-mail-hook.sh). Linux-only: liveness reads /proc.

# Sets lm_stat_ppid and lm_stat_start from /proc/<pid $1>/stat; returns 1
# when there is no such process. No subprocess: the hook runs every turn.
lane_mail_proc_stat() {
    local s
    local -a f
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
    { IFS= read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1
    # The command name (field 2) may hold spaces and parens; cut after it.
    read -ra f <<<"${s##*) }"
    lm_stat_ppid="${f[1]:-}" lm_stat_start="${f[19]:-}"
    [[ -n "$lm_stat_start" ]]
}

# True when pid $1 is the Claude Code CLI: the pid Claude Code exports to
# its children as CLAUDE_PID, a process named `claude`, the native binary
# (.../claude/versions/<version>), or node running the claude-code package.
lane_mail_is_claude() {
    local pid="$1" comm="" a0="" a1=""
    [[ -n "${CLAUDE_PID:-}" && "$pid" == "$CLAUDE_PID" ]] && return 0
    { IFS= read -r comm < "/proc/$pid/comm"; } 2>/dev/null || return 1
    [[ "$comm" == claude ]] && return 0
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$pid/cmdline" || true
    [[ "${a0##*/}" == claude || "$a0" == */claude/versions/* ]] && return 0
    [[ "$a1" == *claude-code/cli* ]]
}

# Sets lm_owner_pid and lm_owner_start to the nearest ancestor of this shell
# that is the Claude Code CLI; returns 1 when there is none. Pid 1 is a
# candidate too (a container or `bwrap --as-pid-1` can run claude as pid 1);
# the walk ends at its parent, pid 0.
lane_mail_claude_owner() {
    local pid="$$" depth=0
    lm_owner_pid="" lm_owner_start=""
    while (( depth++ < 64 )) && lane_mail_proc_stat "$pid"; do
        if lane_mail_is_claude "$pid"; then
            lm_owner_pid="$pid" lm_owner_start="$lm_stat_start"
            return 0
        fi
        [[ "$lm_stat_ppid" =~ ^[1-9][0-9]*$ ]] || return 1
        pid="$lm_stat_ppid"
    done
    return 1
}

# Reads registration file $1 into lm_reg_lane, lm_reg_pid, lm_reg_start and
# lm_reg_pane (empty when absent); returns 1 when the file cannot be read.
lane_mail_reg_read() {
    local line
    lm_reg_lane="" lm_reg_pid="" lm_reg_start="" lm_reg_pane=""
    {
        IFS= read -r lm_reg_lane || [[ -n "$lm_reg_lane" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                owner_pid=*) lm_reg_pid="${line#*=}" ;;
                owner_start=*) lm_reg_start="${line#*=}" ;;
                tmux_pane=*) lm_reg_pane="${line#*=}" ;;
            esac
        done
    } 2>/dev/null < "$1"
}

# True when the registration last read by lane_mail_reg_read is live.
lane_mail_reg_live() {
    [[ -n "$lm_reg_pid" && -n "$lm_reg_start" ]] || return 1
    lane_mail_proc_stat "$lm_reg_pid" || return 1
    [[ "$lm_stat_start" == "$lm_reg_start" ]]
}

# Writes registration file $1 for lane $2, owned by the nearest Claude Code
# ancestor of this shell (no owner lines when there is none), atomically: a
# reader never sees a half-written file. With $3 = existing, only a file
# that is still there is replaced (the hook must not resurrect a
# registration removed under it).
lane_mail_reg_write() {
    local file="$1" lane="$2" mode="${3:-}" tmp
    tmp="$(mktemp "$(dirname -- "$file")/.reg.XXXXXX")" || return 1
    {
        printf '%s\n' "$lane"
        if lane_mail_claude_owner; then
            printf 'owner_pid=%s\nowner_start=%s\n' "$lm_owner_pid" "$lm_owner_start"
        fi
        [[ -z "${TMUX_PANE:-}" ]] || printf 'tmux_pane=%s\n' "$TMUX_PANE"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    if [[ "$mode" == existing && ! -f "$file" ]]; then
        rm -f -- "$tmp"
        return 0
    fi
    mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

# Prints the mtime (epoch seconds) of file $1; returns 1 when it is gone.
lane_mail_mtime() {
    stat -c %Y -- "$1" 2>/dev/null
}

# Prints epoch $1 as local `YYYY-MM-DD HH:MM`; with $2 = age, followed by a
# relative age (", 3 h ago").
lane_mail_when() {
    local t="$1" now age
    printf '%(%Y-%m-%d %H:%M)T' "$t"
    [[ "${2:-}" == age ]] || return 0
    printf -v now '%(%s)T' -1
    age=$(( now - t ))
    if (( age < 60 )); then printf ', just now'
    elif (( age < 3600 )); then printf ', %d min ago' $(( age / 60 ))
    elif (( age < 172800 )); then printf ', %d h ago' $(( age / 3600 ))
    else printf ', %d d ago' $(( age / 86400 ))
    fi
}
