#!/usr/bin/env bash
# :approved: Print this session's context-window usage, from the status line's own numbers
#
# Usage: context-usage.sh [session-id]
#
# statusline-stash.sh is handed the authoritative window size and used
# percentage by Claude Code and stashes them per session under
# /tmp/claude-<uid>/context-nudge/ctx-<session-id>.json (context-nudge.py
# reads the same file). This prints that reading for the CURRENT session --
# the Bash tool exports CLAUDE_CODE_SESSION_ID -- so a session can check
# itself before deciding whether to hand off (/freshly-forked), instead of
# guessing from its transcript's size. Pass a session id to read another's.
#
# Prints one line, "<used>% of <window> (<model>)", and exits 1 with a note
# when no reading exists yet (statusline-stash.sh has not run for that
# session).
#
# CONTEXT_NUDGE_DIR overrides the stash directory. Test-only -- leave it
# unset in real use so this, statusline-stash.sh and context-nudge.py agree
# on where to look.
set -euo pipefail

sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ -z "$sid" ]]; then
    echo "context-usage: no session id (CLAUDE_CODE_SESSION_ID is unset; pass one)" >&2
    exit 1
fi
dir="${CONTEXT_NUDGE_DIR:-/tmp/claude-$(id -u)/context-nudge}"
f="$dir/ctx-$sid.json"
if [[ ! -r "$f" ]]; then
    echo "context-usage: no reading yet for $sid (statusline-stash.sh has not stashed one)" >&2
    exit 1
fi
jq -r '"\(.used_percentage)% of \(.context_window_size) (\(.model))"' "$f"
