#!/bin/bash
# lane-mail-watch.sh -- :approved: Emit a line per new lane-mail message for a lane
#
# Usage: lane-mail-watch.sh <lane> [--interval SECS] [--once]
#
# The receiver half of lane-mail push: a lane's current session arms this as
# a persistent Monitor and gets woken when mail lands, while senders keep
# addressing the lane name with no handle to any session --
#
#   Monitor({command: "lane-mail-watch.sh frontend",
#            description: "lane-mail for @frontend", persistent: true})
#
# Scans the lane's unread inbox every --interval seconds (default 15) and
# prints one line per message id not yet printed, including anything already
# unread at startup -- an armed watch over a non-empty inbox must say so
# rather than sit silent. A message read and marked seen between scans is
# never printed, which is the point of scanning the unread view instead of
# the raw store. A scan failure prints one error line and keeps looping
# (the store may be mid-write); --once does a single scan and exits, for
# tests and ad-hoc checks.

set -euo pipefail

lane="${1:?Usage: lane-mail-watch.sh <lane> [--interval SECS] [--once]}"
shift
interval=15
once=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            interval="${2:?--interval requires seconds}"
            shift 2
            ;;
        --once)
            once=1
            shift
            ;;
        *)
            echo "lane-mail-watch: unknown option '$1'" >&2
            exit 2
            ;;
    esac
done
if [[ ! "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "lane-mail-watch: bad lane name '$lane'" >&2
    exit 2
fi

declare -A printed=()
while :; do
    if unread="$(lane-mail.sh inbox "$lane" 2>&1)"; then
        while IFS=$'\t' read -r mid _tid _pos from subject; do
            [[ -n "$mid" ]] || continue
            [[ -n "${printed[$mid]:-}" ]] && continue
            printed[$mid]=1
            printf '[lane-mail] @%s new: %s -- %s (id %s)\n' "$lane" "$from" "$subject" "$mid"
        done <<<"$unread"
    else
        printf '[lane-mail] @%s: inbox scan failed: %s\n' "$lane" "$unread"
    fi
    (( once )) && exit 0
    sleep "$interval"
done
