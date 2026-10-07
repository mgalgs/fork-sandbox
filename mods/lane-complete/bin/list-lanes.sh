#!/usr/bin/env bash
# list-lanes.sh -- Print the lane-mail lanes the lane-complete mod can offer
#
# Usage: list-lanes.sh        (the mod runs it on a timer; --help prints this)
#
# One `<source><TAB><name>` line per candidate, most relevant source first:
#
#   live     a lane some session registered (`lane-mail.sh register`)
#   mailbox  a lane that only has a mailbox under the lane-mail root
#   remote   a lane on another host that has written to this one: the `From:`
#            address (`@lane:host`) of a message in the local thread store
#   peer     a peer host from the peers file (a lane on it is `@lane:<peer>`)
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

# A lane is listed once, under its most relevant source (live beats mailbox).
declare -A seen=()
emit() {
    local source="$1" name="$2" key="$1:$2"
    [[ "$source" == peer ]] || key="lane:$2"
    [[ -n "${seen[$key]:-}" ]] && return 0
    seen[$key]=1
    printf '%s\t%s\n' "$source" "$name"
}

if [[ -n "$LANES_DIR" && -d "$LANES_DIR" ]]; then
    for f in "$LANES_DIR"/*; do
        [[ -f "$f" ]] || continue
        lane=""
        IFS= read -r lane < "$f" || true
        [[ "$lane" =~ $LANE_MAIL_LANE_RE ]] && emit live "$lane"
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
