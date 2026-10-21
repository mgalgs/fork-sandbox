#!/usr/bin/env bash
# tmux-reap.sh — Retire the caller's tmux pane, and close retired panes
# once they are old enough.
#
# Usage:
#   tmux-reap.sh                          reap $TMUX_PANE, then sweep
#   tmux-reap.sh --sweep [--grace SECS]   sweep only
#   tmux-reap.sh -h | --help
#
# Options:
#   --grace SECS      for --sweep: close panes reaped at least SECS ago
#                     (default 86400, 24h).
#   --term-wait SECS  for --sweep: how long to wait after SIGTERM before
#                     falling back to kill-pane (default 30).
#
# Reaping moves the caller's own pane ($TMUX_PANE, nothing else) into the
# tmux session `reaped` as a window of its own (`tmux break-pane -d`, the
# session is created detached on first use), and stamps the pane with the
# user option @reaped_at = the reap epoch time. The session keeps running
# in the background; nothing is closed yet. Every reap then runs a sweep,
# so no timer is needed.
#
# The sweep considers ONLY panes in session `reaped` that carry a numeric
# @reaped_at older than the grace. A pane outside `reaped`, or in it
# without a stamp (someone moved it there by hand), is never touched: this
# script kills processes on the host, so that is the safety property. For
# each such pane it sends SIGTERM to the pane's foreground process group
# (the claude/codex process, not just the shell), waits up to --term-wait
# seconds for it to exit, then kill-pane if the pane still exists, and
# reports what it closed. SIGTERM because Claude Code has no documented way
# to ask an interactive session to exit from outside; its transcript is
# saved continuously, so a signal loses nothing already shown.
#
# It never sends keys into any pane.

set -euo pipefail

session=reaped
grace=86400
term_wait=30
mode=reap

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^$/d'; }

num() {
    if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        echo "Error: $1 needs whole seconds" >&2
        exit 1
    fi
}

while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --sweep) mode=sweep; shift ;;
        --grace) num --grace "${2:-}"; grace="$2"; shift 2 ;;
        --term-wait) num --term-wait "${2:-}"; term_wait="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Session name of a pane id, empty if the pane is gone. (display-message -t
# on a vanished id falls back to some current pane, so look the id up.)
pane_session() {
    tmux list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null |
        awk -v p="$1" '$1 == p { print $2; exit }'
}

reap() {
    local pane="${TMUX_PANE:?TMUX_PANE must be set: this reaps the calling pane}"
    if [[ ! "$pane" =~ ^%[0-9]+$ ]]; then
        echo "Error: unexpected TMUX_PANE '$pane'" >&2
        exit 1
    fi
    if [[ "$(pane_session "$pane")" != "$session" ]]; then
        local placeholder=""
        if ! tmux has-session -t "=$session" 2>/dev/null; then
            placeholder=$(tmux new-session -d -s "$session" -P -F '#{window_id}')
        fi
        tmux break-pane -d -s "$pane" -t "=$session:"
        tmux set-option -p -t "$pane" @reaped_at "$(date +%s)"
        [[ -z "$placeholder" ]] || tmux kill-window -t "$placeholder"
        echo "Reaped $pane into session $session."
    fi
}

sweep() {
    tmux has-session -t "=$session" 2>/dev/null || return 0
    local now pane pid stamp pgid i closed=0
    now=$(date +%s)
    while read -r pane pid stamp; do
        [[ "$stamp" =~ ^[0-9]+$ ]] || continue
        (( now - stamp >= grace )) || continue
        # Ids are server-wide: confirm the pane is still in `reaped`.
        [[ "$(pane_session "$pane")" == "$session" ]] || continue
        pgid=$(ps -o tpgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        if [[ "$pgid" =~ ^[0-9]+$ ]] && (( pgid > 1 )); then
            kill -TERM -- "-$pgid" 2>/dev/null || true
            for (( i = 0; i < term_wait; i++ )); do
                [[ -n "$(pane_session "$pane")" ]] || break
                kill -0 -- "-$pgid" 2>/dev/null || break
                sleep 1
            done
        fi
        if [[ "$(pane_session "$pane")" == "$session" ]]; then
            tmux kill-pane -t "$pane" 2>/dev/null || true
        fi
        echo "Closed $pane (reaped $(( now - stamp ))s ago)."
        closed=$(( closed + 1 ))
    done < <(tmux list-panes -s -t "=$session" -F '#{pane_id} #{pane_pid} #{@reaped_at}' 2>/dev/null)
    (( closed > 0 )) || echo "Nothing to close in session $session."
}

[[ "$mode" == sweep ]] || reap
sweep
