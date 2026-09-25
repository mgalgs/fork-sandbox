#!/usr/bin/env bash
# statusline-stash.sh -- Stash the status line's context-window reading, then run the display command
#
# Usage: statusline-stash.sh [<display-command> [args...]]
#
# Claude Code invokes exactly one statusLine command and hands it JSON on
# stdin with session_id, model.id (carries the true window -- e.g. the
# "[1m]" suffix on a 1M-context session), model.display_name,
# context_window.context_window_size and context_window.used_percentage.
# That JSON is the only place those numbers are visible -- hooks and
# transcripts both lack them -- so this stashes the four fields under
# /tmp/claude-<uid>/context-nudge/ctx-<session-id>.json, where
# context-usage.sh and context-nudge.py read them back. Written atomically
# (temp file, then `mv -f`) so a reader never sees a half-written file.
#
# There is only one statusLine slot, so this wraps a display command instead
# of replacing it: pass your own display script's path and arguments as
# ARGUMENTS and it receives the exact original stdin bytes, and this script
# exits with its exit status. The display command is never read from an
# environment variable, and never run through eval or sh -c. With no
# display command, this prints a plain one-line summary itself.
#
# CONTEXT_NUDGE_DIR overrides the stash directory. Test-only -- leave it
# unset in real use so this, context-usage.sh and context-nudge.py agree on
# where to look.
#
# Not `set -e`: a status line must print something even when a step here
# fails, so every stash-writing step below swallows its own errors instead
# of aborting the script.
set -uo pipefail

data="$(cat)"

dir="${CONTEXT_NUDGE_DIR:-/tmp/claude-$(id -u)/context-nudge}"
sid="$(printf '%s' "$data" | jq -r '.session_id // empty' 2>/dev/null)"
if [[ -n "$sid" ]]; then
    if mkdir -p "$dir" 2>/dev/null; then
        state_file="$dir/ctx-$sid.json"
        tmp_file="$state_file.tmp"
        if printf '%s' "$data" | jq -c '{
                session_id,
                model: .model.id,
                context_window_size: .context_window.context_window_size,
                used_percentage: .context_window.used_percentage
            }' >"$tmp_file" 2>/dev/null; then
            mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
        else
            rm -f "$tmp_file" 2>/dev/null
        fi
    fi
fi

if [[ $# -gt 0 ]]; then
    printf '%s' "$data" | "$@"
    exit "${PIPESTATUS[1]}"
fi

model="$(printf '%s' "$data" | jq -r '.model.display_name // .model.id // "?"' 2>/dev/null)"
[[ -n "$model" ]] || model="?"
window="$(printf '%s' "$data" | jq -r '.context_window.context_window_size // 200000' 2>/dev/null)"
[[ -n "$window" && "$window" != "null" ]] || window=200000
pct="$(printf '%s' "$data" | jq -r 'if .context_window.used_percentage == null then 0 else (.context_window.used_percentage | round) end' 2>/dev/null)"
[[ -n "$pct" ]] || pct=0
window_k=$(( window / 1000 ))
printf '%s | %s%% of %sk\n' "$model" "$pct" "$window_k"
