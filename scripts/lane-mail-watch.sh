#!/bin/bash
# lane-mail-watch.sh -- :approved: Emit a line per new lane-mail message for a lane
#
# Usage: lane-mail-watch.sh <lane> [--interval SECS] [--once|--wait]
#
# The receiver half of lane-mail push: a lane's current session gets woken
# when mail lands, while senders keep addressing the lane name with no
# handle to any session.
#
# Streaming mode (default) scans the lane's unread inbox every --interval
# seconds (default 15) and prints one line per message id not yet printed,
# including anything already unread at startup -- an armed watch over a
# non-empty inbox must say so rather than sit silent. A message read and
# marked seen between scans is never printed, which is the point of
# scanning the unread view instead of the raw store. A scan failure prints
# one error line and keeps looping (the store may be mid-write); --once
# does a single scan and exits, for tests and ad-hoc checks. Arm streaming
# mode as a persistent Monitor:
#
#   Monitor({command: "lane-mail-watch.sh frontend",
#            description: "lane-mail for @frontend", persistent: true})
#
# --wait mode blocks until the lane's unread view is non-empty, prints one
# line per unread message in the same format, then exits 0 -- there is no
# timeout. Mail already unread at launch is printed at once. Run it as a
# background Bash command instead of a Monitor, since a Monitor wakes on a
# timer even when there is nothing to read, while --wait only wakes the
# session when mail actually lands:
#
#   Bash({command: "lane-mail-watch.sh frontend --wait",
#         run_in_background: true})
#
# Relaunch contract: mark the messages you handled `seen` BEFORE relaunching
# --wait, or it fires again at once on the same ids. And a trap to avoid:
# `lane-mail-watch.sh <lane> | head -1` is not a substitute for --wait --
# the streaming watcher prints nothing while no mail arrives, so head never
# takes SIGPIPE and the pipeline never ends.
#
# A scan failure in --wait mode counts toward a consecutive-failure limit:
# on the 5th failure in a row it prints the error line and exits 1, so a
# broken store wakes the session instead of hanging it silently. --wait
# combined with --once is refused (exit 2).

set -euo pipefail

lane="${1:?Usage: lane-mail-watch.sh <lane> [--interval SECS] [--once|--wait]}"
shift
interval=15
once=0
wait_mode=0
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
        --wait)
            wait_mode=1
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
if (( wait_mode )) && (( once )); then
    echo "lane-mail-watch: --wait and --once are mutually exclusive" >&2
    exit 2
fi

if (( wait_mode )); then
    fail_count=0
    while :; do
        if unread="$(lane-mail.sh inbox "$lane" 2>&1)"; then
            fail_count=0
            if [[ -n "$unread" ]]; then
                while IFS=$'\t' read -r mid _tid _pos from subject; do
                    [[ -n "$mid" ]] || continue
                    printf '[lane-mail] @%s new: %s -- %s (id %s)\n' "$lane" "$from" "$subject" "$mid"
                done <<<"$unread"
                exit 0
            fi
        else
            fail_count=$(( fail_count + 1 ))
            if (( fail_count >= 5 )); then
                printf '[lane-mail] @%s: inbox scan failed: %s\n' "$lane" "$unread"
                exit 1
            fi
        fi
        sleep "$interval"
    done
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
