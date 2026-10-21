#!/usr/bin/env bash
# fork-task-ack.sh — Child/parent halves of the fork-task.sh --ack handshake.
#
# Usage:
#   fork-task-ack.sh <token>
#   fork-task-ack.sh --wait <token> [--timeout SECS]
#   fork-task-ack.sh -h | --help
#
# fork-task.sh --ack creates a pending ack file for a fresh token under
# /var/tmp/claude-scratch/forks/acks/ and tells the launched session to run
# `fork-task-ack.sh <token>` before anything else. A file needs no session
# addressing, and a session that ran an approved command is provably past
# the trust prompt and executing turns.
#
#   <token>            child side: mark the ack, recording the time and
#                      $CLAUDE_CODE_SESSION_ID when set. Idempotent: a second
#                      call keeps the first ack's record. Unknown token:
#                      error, exit 1.
#   --wait <token>     parent side: block until the token is acked. Exit 0
#                      when acked, 3 on timeout, 1 on an unknown token. This
#                      is the wait verb; never hand-roll a poll loop.
#   --timeout SECS     for --wait: give up after SECS (default 600).
#
# Tokens are validated to [A-Za-z0-9][A-Za-z0-9-]{7,63} before they touch a
# path, so nothing can traverse out of the ack directory. The script takes
# arguments only (no environment inputs beyond the informational session
# id), because it is meant to be blanket-allowlisted.

set -euo pipefail

ack_dir="/var/tmp/claude-scratch/forks/acks"

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^$/d'; }

check_token() {
    if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,63}$ ]]; then
        echo "Error: malformed ack token" >&2
        exit 1
    fi
}

mode=ack
timeout=600
token=""
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --wait) mode="wait"; shift ;;
        --timeout)
            timeout="${2:?--timeout requires seconds}"
            shift 2
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            [[ -z "$token" ]] || { echo "Error: one token only" >&2; exit 1; }
            token="$1"
            shift
            ;;
    esac
done

check_token "$token"
if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    echo "Error: --timeout must be whole seconds" >&2
    exit 1
fi

file="$ack_dir/$token"
if [[ ! -f "$file" ]]; then
    echo "Error: unknown ack token" >&2
    exit 1
fi

if [[ "$mode" == ack ]]; then
    if [[ "$(head -c 5 "$file")" == "acked" ]]; then
        exit 0
    fi
    tmpf="$(mktemp "$ack_dir/.ack-XXXXXX")"
    printf 'acked %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CLAUDE_CODE_SESSION_ID:-}" > "$tmpf"
    mv -f -- "$tmpf" "$file"
    echo "Acked."
    exit 0
fi

deadline=$(( SECONDS + timeout ))
while :; do
    if [[ "$(head -c 5 "$file" 2>/dev/null)" == "acked" ]]; then
        echo "Acked."
        exit 0
    fi
    (( SECONDS < deadline )) || break
    sleep 1
done
echo "Timed out waiting for the ack." >&2
exit 3
