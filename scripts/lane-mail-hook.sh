#!/bin/bash
# lane-mail-hook.sh -- Surface unread lane mail between turns
#
# Usage (as Claude Code hooks in settings.json, not run by hand):
#   lane-mail-hook.sh prompt    # UserPromptSubmit: print an unread banner
#   lane-mail-hook.sh stop      # Stop: block idling while unread mail sits
#
# Reads the hook JSON on stdin for session_id and looks up the lane that
# `lane-mail.sh register <lane>` recorded for it. Sessions with no
# registration exit silently -- the cost of these global hooks for an
# ordinary session is one file stat.
#
# prompt mode emits a short banner (message count plus one line per unread
# message) that Claude Code injects as context. Deliberately count+subjects
# only, never bodies: the session pulls a thread with `lane-mail.sh tree`
# when it decides to act, so mail volume cannot flood session context.
#
# stop mode blocks the stop (decision=block) so the session processes its
# inbox before going idle -- the interactive analog of a fleet wake. It
# never blocks when stop_hook_active is set, so one nudge per natural stop
# and no hook loop; a session that judges a message non-actionable must
# still `lane-mail.sh seen` it, or the next natural stop re-nudges.

set -euo pipefail

LANES_DIR="/tmp/claude-$(id -u)/lane-mail-lanes"

mode="${1:-}"
case "$mode" in
    prompt|stop) ;;
    *)
        echo "lane-mail-hook: mode must be 'prompt' or 'stop'" >&2
        exit 2
        ;;
esac

input="$(cat)"
sid="$(jq -r '.session_id // empty' <<<"$input")"
[[ -n "$sid" && -f "$LANES_DIR/$sid" ]] || exit 0
lane="$(<"$LANES_DIR/$sid")"
[[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]] || exit 0

# TSV per unread message: mid, thread, To|Cc, from, subject.
unread="$(lane-mail.sh inbox "$lane" 2>/dev/null || true)"
[[ -n "$unread" ]] || exit 0
count="$(wc -l <<<"$unread")"

summary=""
while IFS=$'\t' read -r mid _tid _pos from subject; do
    [[ -n "$mid" ]] || continue
    summary+="  ${from} -- ${subject} (id ${mid})"$'\n'
done <<<"$unread"

if [[ "$mode" == "prompt" ]]; then
    printf '[lane-mail] @%s: %s unread message(s):\n%s' "$lane" "$count" "$summary"
    printf 'Read with: lane-mail.sh tree <thread-id> (or show <id>); mark processed with: lane-mail.sh seen %s <id>...\n' "$lane"
    exit 0
fi

# stop mode: never block a continuation that a stop hook already produced.
active="$(jq -r '.stop_hook_active // false' <<<"$input")"
[[ "$active" == "true" ]] && exit 0

reason="@${lane} has ${count} unread lane-mail message(s):
${summary}Process them before idling: lane-mail.sh inbox ${lane} for the list, lane-mail.sh tree <thread-id> to read a thread, then lane-mail.sh seen ${lane} <id>... for every message you have handled (including ones needing no action). If a message needs the user, say so and stop after marking it seen."
jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
