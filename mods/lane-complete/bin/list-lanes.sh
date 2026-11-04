#!/usr/bin/env bash
# list-lanes.sh -- Print the lane-mail lanes the lane-complete mod can offer
#
# Usage: list-lanes.sh        (the mod runs it on a timer; --help prints this)
#
# One `<source><TAB><name><TAB><description><TAB><last seen>` line per
# candidate, most relevant source first:
#
#   live     a lane registered (`lane-mail.sh register`) by a session whose
#            Claude Code process still runs (same pid and start time)
#   stale    a lane with registrations, none of them live; registrations are
#            never cleaned up, so this is a session that has gone
#   mailbox  a lane that only has a mailbox under the lane-mail root
#   remote   a lane on another host that has written to this one: the `From:`
#            address (`@lane:host`) of a message in the local thread store
#   peer     a peer host from the peers file (a lane on it is `@lane:<peer>`)
#
# The third column is the lane's description (`lane-mail.sh describe`, stored
# at <root>/agents/<lane>/about): its first line, empty when unset, and always
# empty for `remote` and `peer` rows. The fourth is when a `live` or `stale`
# lane was last seen (local `YYYY-MM-DD HH:MM`: the newest mtime among its
# registrations, which the lane-mail hook refreshes every turn), empty for
# the other sources. A lane with several registrations is live if any one
# is. A consumer that reads the first fields is unaffected. Registration
# format and liveness: "Session registrations" in lane-mail-lib.sh.
#
# Every path comes from the lane-mail scripts themselves, so this never holds
# a second copy of them: the root, the peers file and the name patterns from
# lane-mail-lib.sh (sourced), the per-user registry directory from the
# LANES_DIR line of lane-mail.sh (read, not run -- lane-mail.sh is a command,
# not a library, and that is the one place it keeps the path). The scripts
# directory is the checkout this mod sits in (mods/lane-complete/../../scripts)
# or, for a mod installed elsewhere, wherever lane-mail.sh is on PATH.
#
# The remote source reads only the header block (up to the first blank line)
# of each message under $LANE_MAIL_ROOT/threads, and only its `From:` line: a
# mistyped To:/Cc: nobody answered, or a body that quotes an address, never
# makes a candidate. Addresses on this host's own peer name are skipped. It is
# offline (no ssh, no peer query) -- a lane that has never written here is not
# offered, only reachable as `@lane:host` by typing.
#
# Read-only and quick (a few directory listings and one pass over the local
# message store); the mod calls it from a background timer, never per
# keystroke. Exits 1 with the reason on stderr
# when the lane-mail scripts cannot be found.

set -euo pipefail

case "${1:-}" in
    -h|--help) sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p }' "$0"; exit 0 ;;
    '') ;;
    *) echo "list-lanes: unknown argument '$1'" >&2; exit 1 ;;
esac

here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
scripts="$here/../../../scripts"
if [[ ! -f "$scripts/lane-mail-lib.sh" ]]; then
    mail="$(command -v lane-mail.sh 2>/dev/null || true)"
    [[ -n "$mail" ]] && scripts="$(dirname "$(readlink -f "$mail")")"
fi
if [[ ! -f "$scripts/lane-mail-lib.sh" || ! -f "$scripts/lane-mail.sh" ]]; then
    echo "list-lanes: lane-mail scripts not found (looked beside the mod and on PATH)" >&2
    exit 1
fi
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$scripts/lane-mail-lib.sh"

# LANES_DIR, from the one assignment lane-mail.sh makes. eval only a line of
# exactly the expected shape: the registry dir under /tmp/claude-<uid>.
line="$(grep -m1 '^LANES_DIR=' "$scripts/lane-mail.sh" || true)"
LANES_DIR=""
if [[ "$line" =~ ^LANES_DIR=\"/tmp/claude-\$\(id\ -u\)/[a-z0-9-]+\"$ ]]; then
    eval "$line"
fi

# The description of a local lane: first line of its `about` file, tabs made
# spaces and carriage returns dropped so the column format holds.
describe_of() {
    local line=""
    case "$1" in live|stale|mailbox) ;; *) return 0 ;; esac
    [[ -f "$LANE_MAIL_ROOT/agents/$2/about" ]] || return 0
    IFS= read -r line < "$LANE_MAIL_ROOT/agents/$2/about" || true
    line="${line//$'\t'/ }"
    printf '%s' "${line//$'\r'/}"
}

# A lane is listed once, under its most relevant source (live or stale beats
# mailbox). $3 is the last-seen column, for registered lanes.
declare -A seen=()
emit() {
    local source="$1" name="$2" key="$1:$2"
    [[ "$source" == peer ]] || key="lane:$2"
    [[ -n "${seen[$key]:-}" ]] && return 0
    seen[$key]=1
    printf '%s\t%s\t%s\t%s\n' "$source" "$name" "$(describe_of "$source" "$name")" "${3:-}"
}

# Registered lanes: live when any of a lane's registrations is, else stale;
# last seen is the most recent of them (each file's mtime).
if [[ -n "$LANES_DIR" && -d "$LANES_DIR" ]]; then
    declare -A reg_live=() reg_seen=()
    reg_order=()
    for f in "$LANES_DIR"/*; do
        [[ -f "$f" ]] || continue
        lane_mail_reg_read "$f" || continue
        # shellcheck disable=SC2154  # set by lane_mail_reg_read (lane-mail-lib.sh)
        lane="$lm_reg_lane"
        [[ "$lane" =~ $LANE_MAIL_LANE_RE ]] || continue
        t="$(lane_mail_mtime "$f")" || continue
        if [[ -z "${reg_seen[$lane]:-}" ]]; then
            reg_order+=("$lane")
            reg_live[$lane]=0 reg_seen[$lane]=0
        fi
        lane_mail_reg_live && reg_live[$lane]=1
        (( t > reg_seen[$lane] )) && reg_seen[$lane]=$t
    done
    for lane in "${reg_order[@]:-}"; do
        [[ -n "$lane" ]] || continue
        source=stale
        (( reg_live[$lane] )) && source=live
        emit "$source" "$lane" "$(lane_mail_when "${reg_seen[$lane]}")"
    done
fi

for d in "$LANE_MAIL_ROOT"/agents/*/; do
    [[ -d "$d" ]] || continue
    lane="$(basename "$d")"
    [[ "$lane" =~ $LANE_MAIL_LANE_RE ]] && emit mailbox "$lane"
done

self="$(lane_mail_self_name || true)"

# Senders: the From: of every stored message, headers only. awk prints each
# distinct value once; the names are validated here, as for the other sources.
# shellcheck disable=SC2016  # the awk program is meant to be literal
if [[ -d "$LANE_MAIL_ROOT/threads" ]]; then
    while IFS= read -r from; do
        [[ "$from" =~ ^@([^:]+):([^:]+)$ ]] || continue
        lane="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}"
        [[ "$lane" =~ $LANE_MAIL_LANE_RE && "$host" =~ $LANE_MAIL_HOST_RE ]] || continue
        [[ "$host" == "$self" ]] && continue
        emit remote "$lane:$host"
    done < <(find "$LANE_MAIL_ROOT/threads" -mindepth 2 -maxdepth 2 -name '*.msg' -type f -print0 2>/dev/null |
        xargs -0 -r awk '
            FNR == 1 { head = 1 }
            head && /^[ \t\r]*$/ { head = 0 }
            head && /^From:/ {
                v = substr($0, 6); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
                if (!(v in got)) { got[v] = 1; print v }
            }' | sort -u)
fi

peers="$(lane_mail_peers_file)"
if [[ -f "$peers" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do
        [[ -z "$row" || "$row" == \#* ]] && continue
        read -r peer _ <<<"$row"
        [[ "$peer" =~ $LANE_MAIL_HOST_RE && "$peer" != "$self" ]] && emit peer "$peer"
    done < "$peers"
fi
exit 0
