#!/usr/bin/env bash
# lane-jump.sh -- fzf switcher: jump tmux to the pane owning a lane-mail lane
#
# Usage: lane-jump.sh [--list] [<lane>]
#
#   (no args)   interactive fzf picker over every live lane pane
#   <lane>      jump straight there if exactly one @<lane> pane is live
#               (leading @ optional); else fzf pre-filtered to that lane
#   --list      print the rows (tab-separated: lane, target, window, cwd,
#               pane_id) and exit -- no fzf, for scripting and tests
#
# Meant to be bound to a key as a display-popup, e.g.:
#   bind @ display-popup -E -w 80% -h 50% "~/.claude/scripts/lane-jump.sh"
#
# Joins two independently-written, independently-stale /tmp registries:
#   lane registry  /tmp/claude-<uid>/lane-mail-lanes/<session-id> -> lane
#                  written by `lane-mail.sh register`; a session that ends
#                  without `unregister` leaves its file behind, and several
#                  sessions (an old and new roll of one chain) can share a
#                  lane -- both show up here.
#   pane map       /tmp/claude-tmux-panes-<uid>/<pane-key> -> transcript path
#                  written by tmux-map-claude-session.sh on every
#                  SessionStart (including resume/clear), so it always names
#                  whatever session is CURRENTLY in that pane; a dead pane's
#                  file just lingers.
# Only panes tmux reports as live are trusted, so stale entries on either
# side are silently dropped rather than shown as ghosts.
#
# tmux-map-claude-session.sh is NOT part of this repo. Without a SessionStart
# hook that writes the pane map above, this always sees zero panes and reads
# exactly like "no live lane sessions" -- not a crash, just an empty picker.
# Supply that hook yourself (keyed as `pane_key` below expects) before
# binding this script to a key.
#
# Overridable for tests: LANE_JUMP_LANES_DIR, LANE_JUMP_PANES_DIR,
# LANE_JUMP_TMUX (path to a stand-in for the tmux binary).

set -euo pipefail

LANES_DIR="${LANE_JUMP_LANES_DIR:-/tmp/claude-$(id -u)/lane-mail-lanes}"
PANES_DIR="${LANE_JUMP_PANES_DIR:-/tmp/claude-tmux-panes-$(id -u)}"
TMUX_BIN="${LANE_JUMP_TMUX:-tmux}"

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

# Keyed by pane_id with every non-alphanumeric char turned into '_' -- must
# stay in sync with the same substitution in tmux-map-claude-session.sh,
# which writes the files this reads.
pane_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'
}

# Prints one row per live pane whose session is registered to a lane:
# @lane<TAB>session:window.pane<TAB>window_name<TAB>cwd<TAB>pane_id -- sorted
# by lane. pane_id is the stable switch-client target (trailing, hidden from
# the fzf display); window/pane indexes can be renumbered by tmux when an
# earlier pane closes, so they are shown but never used to switch.
# Silent (empty output) if tmux has no server running.
build_rows() {
    local fmt pane_id session window_index pane_index window_name cwd
    local key transcript sid lane_file lane cwd_disp

    # \x01 (not tab) delimits tmux's own output: tab is IFS whitespace, so
    # `read` would collapse an empty field (e.g. an unnamed window) into its
    # neighbor instead of preserving it.
    fmt=$(printf '#{pane_id}\x01#{session_name}\x01#{window_index}\x01#{pane_index}\x01#{window_name}\x01#{pane_current_path}')
    while IFS=$'\x01' read -r pane_id session window_index pane_index window_name cwd; do
        [ -n "$pane_id" ] || continue
        key=$(pane_key "$pane_id")
        [ -f "$PANES_DIR/$key" ] || continue
        transcript=$(<"$PANES_DIR/$key")
        sid=$(basename "$transcript" .jsonl)
        lane_file="$LANES_DIR/$sid"
        [ -f "$lane_file" ] || continue
        lane=$(<"$lane_file")
        case "$cwd" in
            "$HOME") cwd_disp="~" ;;
            "$HOME"/*) cwd_disp="~${cwd#"$HOME"}" ;;
            *) cwd_disp="$cwd" ;;
        esac
        printf '@%s\t%s:%s.%s\t%s\t%s\t%s\n' \
            "$lane" "$session" "$window_index" "$pane_index" "$window_name" "$cwd_disp" "$pane_id"
    done < <("$TMUX_BIN" list-panes -a -F "$fmt" 2>/dev/null || true) | sort -t $'\t' -k1,1
}

require_tmux_client() {
    if [ -z "${TMUX:-}" ]; then
        echo "lane-jump: not running inside tmux" >&2
        exit 1
    fi
}

require_fzf() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "lane-jump: fzf is not installed" >&2
        exit 1
    fi
}

# Shows "no live lane sessions" for at least a moment even when invoked from
# a display-popup with no controlling terminal to read a keypress from --
# otherwise the popup opens and closes before the message can be read.
announce_empty() {
    echo "lane-jump: no live lane sessions" >&2
    if [ -t 0 ]; then
        read -r -t 3 -p "(press enter) " _ || true
    else
        sleep 2
    fi
}

pick_with_fzf() {
    local query="${1:-}"
    local fzf_args=(--delimiter '\t' '--with-nth=1,2,3,4')
    [ -n "$query" ] && fzf_args+=(--query "$query")
    fzf "${fzf_args[@]}"
}

switch_to() {
    local target="$1"
    "$TMUX_BIN" switch-client -t "$target"
}

cmd="${1:-}"
case "$cmd" in
    -h|--help)
        usage
        exit 0
        ;;
    --list)
        rows="$(build_rows)"
        if [ -z "$rows" ]; then
            echo "lane-jump: no live lane sessions" >&2
            exit 1
        fi
        printf '%s\n' "$rows"
        exit 0
        ;;
esac

rows="$(build_rows)"
if [ -z "$rows" ]; then
    require_tmux_client
    announce_empty
    exit 1
fi

if [ -n "$cmd" ]; then
    lane="${cmd#@}"
    matches="$(printf '%s\n' "$rows" | awk -F'\t' -v l="@$lane" '$1 == l')"
    if [ -z "$matches" ]; then
        echo "lane-jump: no live pane registered to @$lane" >&2
        exit 1
    fi
    require_tmux_client
    count="$(printf '%s\n' "$matches" | wc -l)"
    if [ "$count" -eq 1 ]; then
        switch_to "$(printf '%s' "$matches" | cut -f5)"
        exit 0
    fi
    require_fzf
    selection="$(printf '%s\n' "$matches" | pick_with_fzf "@$lane")" || exit 1
    [ -n "$selection" ] || exit 1
    switch_to "$(printf '%s' "$selection" | cut -f5)"
    exit 0
fi

require_tmux_client
require_fzf
selection="$(printf '%s\n' "$rows" | pick_with_fzf)" || exit 1
[ -n "$selection" ] || exit 1
switch_to "$(printf '%s' "$selection" | cut -f5)"
