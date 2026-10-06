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
