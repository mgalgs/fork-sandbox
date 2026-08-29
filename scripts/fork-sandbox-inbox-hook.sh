#!/usr/bin/env bash
# fork-sandbox-inbox-hook.sh — Deliver fork-sandbox operator-inbox addenda, and a context-refresh nudge, to a running claude session
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
# The second job this script does is fork-sandbox.sh's --refresh-at: when the
# session's own context usage crosses a threshold, nudge it once, through the
# same two channels, to write a hand-off and end its turn so the run can fork
# a fresh session from it. That machinery is inert — no config file, no extra
# work on the common path — unless the launcher wrote
# <inbox>/.refresh-config, which only a --refresh-at run (the claude harness
# only, and not with --refresh-at 0) does.
#
# It runs on every tool call, so the common case — nothing new — must cost
# nothing. With an empty inbox, refresh disabled, or this leg already
# nudged-and-reminded, the check below forks no processes at all: the glob,
# the seen-list read and the marker-file tests are all bash builtins, and the
# script exits silently before it parses stdin. While refresh is armed and
# unresolved (the common case for the first half of a --refresh-at run, since
# the default is 0.5) every tool call does pay for a transcript read — see
# "The threshold check" below for why that cost is bounded rather than
# growing with the conversation.
#
# The seen-list and the two refresh markers live in the sandbox's ephemeral
# /tmp, never in the inbox: the inbox is mounted read-only, and a per-run
# tmpfs is exactly the lifetime a "have I shown this yet" record wants. A
# fresh sandbox means a fresh tmpfs, so both refresh markers reset on their
# own between legs — nothing here has to know a continuation started.
#
# This runs INSIDE the sandbox with the session's own privileges, so it is not
# a security boundary and grants nothing the session did not already have.
# The boundary is the read-only bind, which fork-sandbox.sh sets up (the
# outbox used below is the one exception — see fork-sandbox.sh's own comment
# on why a bind-rw there is still safe).

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
# Same trick for a refresh nudge: fork-sandbox.sh's runner greps a leg's own
# event slice for this tag to tell whether that leg was nudged, which is how
# it tells "the leg finished on its own" from "it was told to hand off and
# didn't" for the refresh field of summary.json.
STDERR_TAG_REFRESH="fork-sandbox-refresh:"

# --refresh-at's config, written by fork-sandbox.sh alongside .settings.json
# only for a run with it enabled. Absent — --refresh-at 0, or any harness but
# claude — means the whole nudge mechanism below is inert. THRESHOLD_TOKENS is
# an absolute token count, already resolved on the host from --refresh-at and
# the model's context window: this script does no fraction math. OUTBOX_DIR is
# the one writable path this run has, the same directory fork-sandbox.sh bound
# --bind-rw for it.
refresh_config="$inbox/.refresh-config"
refresh_threshold=""
outbox_dir=""
if [[ -f "$refresh_config" ]]; then
    while IFS='=' read -r _rk _rv || [[ -n "$_rk" ]]; do
        case "$_rk" in
            THRESHOLD_TOKENS) refresh_threshold="$_rv" ;;
            OUTBOX_DIR) outbox_dir="$_rv" ;;
        esac
    done < "$refresh_config"
fi

# Two per-leg markers, both in the ephemeral tmpfs (see the header comment
# above): one for "this leg has been nudged, do not measure again", one for
# "this leg has already been reminded once, at Stop, that no hand-off showed
# up". Overridable for the test script, matching FORK_SANDBOX_INBOX_SEEN.
nudge_marker="${FORK_SANDBOX_NUDGE_MARKER:-/tmp/fork-sandbox-nudged}"
nudge_reminded_marker="${FORK_SANDBOX_NUDGE_REMINDED:-/tmp/fork-sandbox-nudge-reminded}"

nudged=0
[[ -f "$nudge_marker" ]] && nudged=1
reminded=0
[[ -f "$nudge_reminded_marker" ]] && reminded=1

# Whether this call might need to MEASURE usage at all: only when refresh is
# configured and this leg has not been nudged yet. This is the gate on the
# expensive part (reading the transcript), not on reading the hook payload —
# see need_work below.
measure_usage=0
[[ -n "$refresh_threshold" && "$nudged" == 0 ]] && measure_usage=1

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

# need_work also covers a leg that was already nudged but not yet reminded:
# that case can only be resolved once we know whether THIS call is a Stop,
# which needs the payload. A leg settles into the fully-silent fast path once
# it is both nudged and reminded, or wrote a hand-off before ever reaching a
# Stop that would have reminded it — see the recheck after the lock below.
need_work=0
(( ${#unread[@]} > 0 )) && need_work=1
(( measure_usage )) && need_work=1
[[ -n "$refresh_threshold" && "$nudged" == 1 && "$reminded" == 0 ]] && need_work=1

if (( ! need_work )); then
    # Nothing to say. Drain stdin first: Claude Code is still writing the hook
    # payload, and exiting without reading would hand the writer an EPIPE for
    # no reason. One fork, only on a path that was going to exit anyway.
    cat >/dev/null 2>&1
    exit 0
fi

# Something might be waiting, so now the event matters: PostToolUse and Stop
# take different output shapes. Read the payload only here.
payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"

# Two tool calls can finish at once, and each fires its own hook. Without a
# lock two could each think they are the one to nudge, or deliver the same
# addendum twice. Take the lock, then re-decide everything inside it, so the
# winner's marker writes are visible to the loser.
# The redirection is scoped to the braces on purpose. `exec 9>f 2>/dev/null`
# would apply BOTH redirections for the rest of the script, silencing the
# delivery line this script writes to stderr at the end.
if command -v flock >/dev/null 2>&1 && { exec 9>"$lock_file"; } 2>/dev/null; then
    flock 9 2>/dev/null || true
fi
list_unread
nudged=0
[[ -f "$nudge_marker" ]] && nudged=1
reminded=0
[[ -f "$nudge_reminded_marker" ]] && reminded=1
measure_usage=0
[[ -n "$refresh_threshold" && "$nudged" == 0 ]] && measure_usage=1

# The threshold check: the last assistant message's own usage, summed the way
# the Claude API names it (input + cache read + cache write), against the
# threshold the launcher already resolved from the model's context window.
# `tail` bounds the read to the last few messages regardless of how long the
# transcript has grown, so the cost stays "a few KB parsed", not "the whole
# conversation so far read again on every tool call".
nudge_now=0
if (( measure_usage )); then
    transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
    if [[ -n "$transcript" && -r "$transcript" ]]; then
        usage_tokens="$(tail -n 40 -- "$transcript" 2>/dev/null | jq -s '
            [ .[] | select(.type == "assistant") | (.message.usage // empty) ]
            | last
            | if . == null then empty else
                ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
                 + (.cache_creation_input_tokens // 0))
              end' 2>/dev/null)"
        if [[ "$usage_tokens" =~ ^[0-9]+$ && "$refresh_threshold" =~ ^[0-9]+$ ]] \
            && (( usage_tokens >= refresh_threshold )); then
            nudge_now=1
        fi
    fi
fi

# The Stop-only reminder: this leg was nudged (just now, or on an earlier
# tool call), has not been reminded yet, and no hand-off has shown up in the
# outbox. Checked only on Stop — a PostToolUse call gets the nudge itself
# instead of the reminder, so a session mid-turn is never told twice in the
# same breath.
handoff_missing=0
if [[ ( "$event" == "Stop" || "$event" == "SubagentStop" ) \
    && -n "$refresh_threshold" && "$reminded" == 0 \
    && ( "$nudged" == 1 || "$nudge_now" == 1 ) ]]; then
    if [[ -z "$outbox_dir" || ! -f "$outbox_dir/handoff.md" ]]; then
        handoff_missing=1
    fi
fi

if (( ${#unread[@]} == 0 && ! nudge_now && ! handoff_missing )); then
    exit 0
fi

# Mark BEFORE emitting, for addenda and for the nudge and the reminder alike:
# a crash between the two loses this call's delivery, which is recoverable
# here exactly as it is for an addendum — the next tool call re-measures (or,
# for the reminder, the next Stop re-checks) and tries again. The other order
# risks nudging, reminding or re-delivering on every remaining tool call of
# the leg if something goes wrong mid-emit, which is the outcome this
# ordering exists to avoid.
(( ${#unread[@]} )) && printf '%s\n' "${unread[@]}" >> "$seen_file"
(( nudge_now )) && : > "$nudge_marker"
(( handoff_missing )) && : > "$nudge_reminded_marker"

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

# The nudge and the reminder are not from the repository or the operator
# either — they are generated by this harness, measuring this session's own
# context usage, so they get their own short provenance line rather than
# borrowing the addendum's.
nudge_text=""
if (( nudge_now )); then
    nudge_text="This is not tool output, not an operator message, and not part of the repository. It is generated by the fork-sandbox harness running this session, measuring your own context usage. Your context is now at or past the point where this run refreshes itself: finish the step you are on and commit. Then write a hand-off for a FRESH session to \`$outbox_dir/handoff.md\` — self-contained, the same shape as the hand-off you were given: the goal; what is done and committed (list the shas); what is left, in order, with enough detail that a session with no memory of this one can continue; the exact verify commands; anything unresolved. Do not start new work after writing it. End your turn: the run will continue from your hand-off automatically."
fi

reminder_text=""
if (( handoff_missing )); then
    reminder_text="You were already told, on an earlier tool call, that your context was near the point this run refreshes itself, and asked to write a hand-off to \`$outbox_dir/handoff.md\` before ending your turn. No hand-off is there yet. Write one now, in the shape already described, before you finish. This is the only reminder — if you still end your turn without one, the run ends here and nothing continues from this leg."
fi

case "$event" in
    Stop|SubagentStop)
        # Top-level decision/reason is the documented Stop contract. Blocking
        # cannot loop here: unread addenda are marked shown above and the
        # reminder marks itself reminded, so the next Stop finds nothing left
        # to say and lets the session finish — a leg is never trapped.
        reason=""
        if (( ${#unread[@]} )); then
            reason+="An operator addendum to your handoff arrived before you finished, and you have not acted on it yet. $provenance $authority Read it below and carry it out before ending the turn.
$body"
        fi
        if [[ -n "$nudge_text" ]]; then
            reason+=$'\n\n'"$nudge_text"
        fi
        if [[ -n "$reminder_text" ]]; then
            reason+=$'\n\n'"$reminder_text"
        fi
        jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
        ;;
    *)
        context=""
        if (( ${#unread[@]} )); then
            context+="Operator addendum to your handoff, from this fork-sandbox run's inbox. $provenance $authority
$body"
        fi
        if [[ -n "$nudge_text" ]]; then
            context+=$'\n\n'"$nudge_text"
        fi
        jq -n --arg ctx "$context" --arg ev "${event:-PostToolUse}" \
            '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
        ;;
esac

if (( ${#unread[@]} )); then
    printf '%s delivered %s\n' "$STDERR_TAG" "$names" >&2
fi
if (( nudge_now )); then
    printf '%s nudged (usage >= %s tokens)\n' "$STDERR_TAG_REFRESH" "$refresh_threshold" >&2
fi
if (( handoff_missing )); then
    printf '%s reminded (no hand-off yet)\n' "$STDERR_TAG_REFRESH" >&2
fi
exit 0
