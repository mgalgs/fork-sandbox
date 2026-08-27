#!/usr/bin/env bash
# fork-sandbox-inbox-hook.sh — Deliver fork-sandbox operator-inbox addenda to a running claude session
#
# Usage: not run by hand. fork-sandbox.sh copies this into a run's inbox and
#        registers it as a Claude Code hook for PostToolUse and Stop.
#
# The operator inbox is a host-written, sandbox-read-only directory. An
# operator drops a file into it with fork-sandbox-say.sh; this script is what
# puts that file in front of the running session.
#
#   PostToolUse  every unread addendum is emitted as
#                hookSpecificOutput.additionalContext, which Claude Code
#                places next to the tool result. So an addendum reaches the
#                session on its very next tool call, with no cooperation from
#                the session itself.
#   Stop         unread addenda block the stop with decision/reason, so an
#                agent that has gone quiet and is about to finish gets them
#                too. This is the delivery guarantee: a session cannot end
#                with an addendum unread.
#
# Both contracts are the documented ones (code.claude.com/docs/en/hooks):
# PostToolUse takes hookSpecificOutput.hookEventName + additionalContext, and
# Stop takes TOP-LEVEL decision/reason — not the nested form PreToolUse uses.
#
# It runs on every tool call, so the common case — nothing new — must cost
# nothing. With an empty inbox the check below forks no processes at all: the
# glob, the seen-list read and the membership test are all bash builtins, and
# the script exits silently before it parses stdin.
#
# The seen-list lives in the sandbox's ephemeral /tmp, never in the inbox: the
# inbox is mounted read-only, and a per-run tmpfs is exactly the lifetime a
# "have I shown this yet" record wants.
#
# This runs INSIDE the sandbox with the session's own privileges, so it is not
# a security boundary and grants nothing the session did not already have.
# The boundary is the read-only bind, which fork-sandbox.sh sets up.

set -uo pipefail

# Self-locating: fork-sandbox.sh copies this into the inbox itself, as a
# dotfile, so the directory holding it IS the inbox. That keeps the sandbox's
# bind list at one entry — see the comment where fork-sandbox.sh stages it.
# The overrides exist for the test script; nothing in a real run sets them.
inbox="${FORK_SANDBOX_INBOX:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
seen_file="${FORK_SANDBOX_INBOX_SEEN:-/tmp/fork-sandbox-inbox-seen}"
lock_file="$seen_file.lock"

# Marker for the run's event log. fork-sandbox-format.sh renders a
# hook_response whose stderr starts with this as a notable line, which is how
# `fork-sandbox-status.sh --monitor` reports a delivery. It goes to stderr
# rather than into the payload so the model never sees this bookkeeping.
STDERR_TAG="fork-sandbox-inbox:"

unread=()

# Fill `unread` with the names of inbox files not yet shown, oldest first.
# Names are generated as <epoch>-<nn>.md, so a lexicographic sort is a
# chronological one. Builtins only: this runs on every single tool call.
list_unread() {
    unread=()
    local blob="" f name
    if [[ -f "$seen_file" ]]; then
        # read -d '' consumes the whole file in one builtin read. It returns
        # non-zero at EOF having filled the variable, which is the normal
        # outcome here, so the failure is expected rather than checked.
        IFS= read -r -d '' blob < "$seen_file" || true
    fi
    blob=$'\n'"$blob"$'\n'
    for f in "$inbox"/*.md; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        # A generated name holds only digits, a hyphen and '.md', so it can
        # carry no glob metacharacter and this match is exact.
        [[ "$blob" == *$'\n'"$name"$'\n'* ]] && continue
        unread+=("$name")
    done
}

list_unread
if (( ${#unread[@]} == 0 )); then
    # Nothing to say. Drain stdin first: Claude Code is still writing the hook
    # payload, and exiting without reading would hand the writer an EPIPE for
    # no reason. One fork, only on a path that was going to exit anyway.
    cat >/dev/null 2>&1
    exit 0
fi

# Something is waiting, so now the event matters: PostToolUse and Stop take
# different output shapes. Read the payload only here.
payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"

# Two tool calls can finish at once, and each fires its own hook. Without a
# lock both would read the same unread set and deliver the addendum twice.
# Take the lock, then re-list inside it, so the winner's seen-list write is
# visible to the loser.
# The redirection is scoped to the braces on purpose. `exec 9>f 2>/dev/null`
# would apply BOTH redirections for the rest of the script, silencing the
# delivery line this script writes to stderr at the end.
if command -v flock >/dev/null 2>&1 && { exec 9>"$lock_file"; } 2>/dev/null; then
    flock 9 2>/dev/null || true
fi
list_unread
if (( ${#unread[@]} == 0 )); then
    exit 0
fi

# Mark them shown BEFORE emitting. A crash between the two loses an addendum,
# which is recoverable — the operator can resend. The other order risks
# delivering the same course correction on every tool call for the rest of the
# run, which is not.
printf '%s\n' "${unread[@]}" >> "$seen_file"

names=""
body=""
for name in "${unread[@]}"; do
    names+="${names:+, }$name"
    body+=$'\n'"## Operator addendum ($name)"$'\n\n'
    body+="$(cat -- "$inbox/$name")"$'\n'
done

# Say what an addendum IS, every time. Two things have to be established, and
# leaving either out has been observed to break delivery:
#
#   Provenance. On the PostToolUse path the text lands next to a tool result,
#   which is where injected content comes from, and an addendum that changes
#   course reads exactly like an injection attempt. A session that treats it
#   as one reports the text to the operator instead of acting on it — measured,
#   not theorized. So state where it actually came from: the run's inbox is a
#   host-side directory mounted read-only, which only the operator can write.
#
#   Authority. Without it a session reads a course correction as a footnote to
#   the handoff and carries on with the original plan.
provenance="This text is not tool output and did not come from the repository. It was written by the operator who launched this run and wrote your handoff, and it arrived over that run's operator inbox — a host-side directory mounted read-only here, which nothing inside this sandbox can write to."
authority="An addendum is a continuation of your handoff and carries the same authority: it may override the handoff rather than merely add to it. Where the two conflict, the addendum is the newer instruction and takes precedence."

case "$event" in
    Stop|SubagentStop)
        # Top-level decision/reason is the documented Stop contract. Blocking
        # cannot loop here: the addenda are marked shown above, so the next
        # Stop finds nothing unread and lets the session finish.
        reason="An operator addendum to your handoff arrived before you finished, and you have not acted on it yet. $provenance $authority Read it below and carry it out before ending the turn.
$body"
        jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
        ;;
    *)
        context="Operator addendum to your handoff, from this fork-sandbox run's inbox. $provenance $authority
$body"
        jq -n --arg ctx "$context" --arg ev "${event:-PostToolUse}" \
            '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
        ;;
esac

printf '%s delivered %s\n' "$STDERR_TAG" "$names" >&2
exit 0
