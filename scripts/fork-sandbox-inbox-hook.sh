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
# a fresh session from it. A session can keep working and committing for a
# long time after writing that hand-off without ever rewriting it, so this
# script also sends a Stop back once, at most, if the hand-off already
# sitting in the outbox predates the clone's last commit — see the staleness
# check below. That machinery is inert — no config file, no extra work on the
# common path — unless the launcher wrote <inbox>/.refresh-config, which only
# a --refresh-at run (the claude harness only, and not with --refresh-at 0)
# does.
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
# The seen-list and the three refresh markers live in the sandbox's ephemeral
# /tmp, never in the inbox: the inbox is mounted read-only, and a per-run
# tmpfs is exactly the lifetime a "have I shown this yet" record wants. A
# fresh sandbox means a fresh tmpfs, so all three refresh markers reset on
# their own between legs — nothing here has to know a continuation started.
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
clone_dir=""
if [[ -f "$refresh_config" ]]; then
    while IFS='=' read -r _rk _rv || [[ -n "$_rk" ]]; do
        case "$_rk" in
            THRESHOLD_TOKENS) refresh_threshold="$_rv" ;;
            OUTBOX_DIR) outbox_dir="$_rv" ;;
            CLONE_DIR) clone_dir="$_rv" ;;
        esac
    done < "$refresh_config"
fi

# Three per-leg markers, all in the ephemeral tmpfs (see the header comment
# above): one for "this leg has been nudged, do not measure again", one for
# "this leg has already been reminded once, at Stop, that no hand-off showed
# up", one for "this leg has already been sent back once, at Stop, because
# its hand-off predated its last commit". Overridable for the test script,
# matching FORK_SANDBOX_INBOX_SEEN.
nudge_marker="${FORK_SANDBOX_NUDGE_MARKER:-/tmp/fork-sandbox-nudged}"
nudge_reminded_marker="${FORK_SANDBOX_NUDGE_REMINDED:-/tmp/fork-sandbox-nudge-reminded}"
stale_reminded_marker="${FORK_SANDBOX_STALE_REMINDED:-/tmp/fork-sandbox-stale-reminded}"

nudged=0
[[ -f "$nudge_marker" ]] && nudged=1
reminded=0
[[ -f "$nudge_reminded_marker" ]] && reminded=1
stale_reminded=0
[[ -f "$stale_reminded_marker" ]] && stale_reminded=1

# Whether this call might need to MEASURE usage at all: only when refresh is
# configured and this leg has not been nudged yet. This is the gate on the
# expensive part (reading the transcript), not on reading the hook payload —
# see need_work below.
measure_usage=0
[[ -n "$refresh_threshold" && "$nudged" == 0 ]] && measure_usage=1

# --refresh-at Bug B: a session can be nudged (or nudge itself early) mid-
# read, write a hand-off, then keep working and commit for many more
# minutes without ever rewriting it -- the next leg would then start from a
# hand-off that misdescribes reality. Staleness test, builtins only ([[ -nt
# ]] is a bash test, not a fork): the hand-off is stale when the clone's HEAD
# reflog is newer than it. The reflog, not .git/index -- `git status`
# opportunistically rewrites the index on a harmless status check, which
# would flag a hand-off as stale for no reason; the reflog changes only on
# commit, reset or checkout. No reflog file at all (a fresh clone that has
# never diverged) means the check is skipped rather than treated as stale.
handoff_stale=0
if [[ -n "$refresh_threshold" && -n "$clone_dir" && "$stale_reminded" == 0 \
    && -n "$outbox_dir" && -f "$outbox_dir/handoff.md" \
    && -f "$clone_dir/.git/logs/HEAD" ]]; then
    [[ "$clone_dir/.git/logs/HEAD" -nt "$outbox_dir/handoff.md" ]] && handoff_stale=1
fi

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
# that case can only be resolved for certain once we know whether THIS call
# is a Stop, which needs the payload — but a hand-off already sitting in the
# outbox settles it without one, and that check is a builtin, so it is worth
# doing here rather than paying the payload read on every remaining tool call
# of a leg that has already written its hand-off and moved on. A leg settles
# into the fully-silent fast path once it is both nudged and reminded, or
# once it has a hand-off waiting that has not gone stale. A stale hand-off
# still costs a payload read and an event check on each remaining PostToolUse
# call -- there is no way to tell those apart from the Stop that matters
# without reading the payload -- but not the lock beyond that; see the exit
# before it below.
need_work=0
(( ${#unread[@]} > 0 )) && need_work=1
(( measure_usage )) && need_work=1
if [[ -n "$refresh_threshold" && "$nudged" == 1 && "$reminded" == 0 ]]; then
    [[ -z "$outbox_dir" || ! -f "$outbox_dir/handoff.md" ]] && need_work=1
fi
(( handoff_stale )) && need_work=1

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

# The threshold check: the last assistant message's own usage, summed the way
# the Claude API names it (input + cache read + cache write), against the
# threshold the launcher already resolved from the model's context window.
# `tail` bounds the read to the last few messages regardless of how long the
# transcript has grown, so the cost stays "a few KB parsed", not "the whole
# conversation so far read again on every tool call".
#
# Deliberately done BEFORE the lock below: this only reads the transcript,
# which no other hook invocation writes to, so it needs no exclusivity, and
# holding the lock across it would serialise every concurrent tool call for
# as long as refresh stays armed. The re-check after the lock below catches
# the case where a racing call already won the nudge while this one was
# reading.
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

# handoff_missing and stale_block -- the only things below worth taking the
# lock for besides a fresh nudge -- are both Stop/SubagentStop-only (see each
# below). A PostToolUse call with nothing unread and no nudge of its own has
# nothing left to decide, so it exits here rather than pay the lock (and the
# race it guards against) for the rest of a leg whose hand-off is sitting
# stale in the outbox waiting for that leg's own Stop to send it back.
if (( ${#unread[@]} == 0 && ! nudge_now )) \
    && [[ "$event" != "Stop" && "$event" != "SubagentStop" ]]; then
    exit 0
fi

# Two tool calls can finish at once, and each fires its own hook. Without a
# lock two could each think they are the one to nudge, or deliver the same
# addendum twice. Take the lock, then re-decide the check-and-write state
# inside it, so the winner's marker writes are visible to the loser. This is
# only the re-check and the marker writes further down -- the measurement
# above is a pure read and stays outside it.
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
stale_reminded=0
[[ -f "$stale_reminded_marker" ]] && stale_reminded=1
# A racing call may have already won the nudge (or the leg may already have
# been nudged before this call started) while this call was reading the
# transcript, unlocked. Its own marker write below is what makes a nudge
# final for the leg, so a nudge decided against stale state must not stand.
(( nudged )) && nudge_now=0
# Same idea for the stale-hand-off check: a racing call may have already sent
# the leg back once for this same hand-off.
(( stale_reminded )) && handoff_stale=0

# The Stop-only reminder: this leg was nudged on an EARLIER tool call, has
# not been reminded yet, and no hand-off has shown up in the outbox. Gated on
# "$nudge_now" == 0 as well as "$nudged" == 1 so the first crossing of the
# threshold -- when it happens to land on a Stop rather than a PostToolUse --
# gets the nudge itself instead of the reminder; without that, "you were
# already told on an earlier tool call" would go out on the very call that
# told it, which is false, and the leg's one real reminder would be spent
# before it ever had a chance to act on the nudge.
handoff_missing=0
if [[ ( "$event" == "Stop" || "$event" == "SubagentStop" ) \
    && -n "$refresh_threshold" && "$reminded" == 0 \
    && "$nudged" == 1 && "$nudge_now" == 0 ]]; then
    if [[ -z "$outbox_dir" || ! -f "$outbox_dir/handoff.md" ]]; then
        handoff_missing=1
    fi
fi

# The stale-hand-off block, Stop/SubagentStop only: a session may
# legitimately commit after writing its hand-off and then rewrite it before
# ending its turn, so only the actual end of the turn is the boundary that
# matters — PostToolUse never blocks on this and must not mention it.
stale_block=0
if [[ ( "$event" == "Stop" || "$event" == "SubagentStop" ) ]] && (( handoff_stale )); then
    stale_block=1
fi

if (( ${#unread[@]} == 0 && ! nudge_now && ! handoff_missing && ! stale_block )); then
    exit 0
fi

# Mark BEFORE emitting, for addenda and for the nudge, the reminder and the
# stale block alike: a crash between the two loses this call's delivery,
# which is recoverable here exactly as it is for an addendum — the next tool
# call re-measures (or, for the reminder and the stale block, the next Stop
# re-checks) and tries again. The other order risks nudging, reminding,
# re-blocking or re-delivering on every remaining tool call of the leg if
# something goes wrong mid-emit, which is the outcome this ordering exists to
# avoid.
(( ${#unread[@]} )) && printf '%s\n' "${unread[@]}" >> "$seen_file"
(( nudge_now )) && : > "$nudge_marker"
(( handoff_missing )) && : > "$nudge_reminded_marker"
(( stale_block )) && : > "$stale_reminded_marker"

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
    nudge_text="This is not tool output, not an operator message, and not part of the repository. It is generated by the fork-sandbox harness running this session, measuring your own context usage. Your context is now at or past the point where this run refreshes itself: finish the step you are on and commit. Then write a hand-off for a FRESH session to \`$outbox_dir/handoff.md\` and end your turn.

The fresh session will receive your original brief verbatim alongside this hand-off, so the hand-off must NOT restate the brief. Instead, item by item, using the brief's own numbering or headings, say which items are done (with the commit shas) and which remain, in order, plus anything you learned along the way that the brief did not know. Never compress remaining items into \"see prior hand-off\" or a summary — a future leg cannot read this hand-off once its own is written, and a summarised list is how items get lost. Also carry over the exact verify commands and anything unresolved.

If you do any more work after writing the hand-off, rewrite it before you end your turn so it matches reality: the harness checks, at the end of your turn, that the hand-off is newer than the clone's last commit, and sends you back once if it is not.

Do not start new work after that. End your turn: the run will continue from your hand-off automatically."
fi

reminder_text=""
if (( handoff_missing )); then
    reminder_text="You were already told, on an earlier tool call, that your context was near the point this run refreshes itself, and asked to write a hand-off to \`$outbox_dir/handoff.md\` before ending your turn. No hand-off is there yet. Write one now, in the shape already described, before you finish. This is the only reminder — if you still end your turn without one, the run ends here and nothing continues from this leg."
fi

# Not from the repository or the operator either, same as the nudge and the
# reminder above.
stale_text=""
if (( stale_block )); then
    stale_text="This is not tool output, not an operator message, and not part of the repository. It is generated by the fork-sandbox harness running this session. The hand-off at \`$outbox_dir/handoff.md\` was written before the most recent commit on this branch, so it describes a state that no longer exists. Rewrite it now from \`git log --oneline\` and \`git status\` so it lists what is actually committed and what actually remains, then end the turn. This is the only such reminder."
fi

case "$event" in
    Stop|SubagentStop)
        # Top-level decision/reason is the documented Stop contract. Blocking
        # cannot loop here: unread addenda are marked shown above and the
        # reminder and the stale block each mark themselves handled, so the
        # next Stop finds nothing left to say and lets the session finish —
        # a leg is never trapped.
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
        if [[ -n "$stale_text" ]]; then
            reason+=$'\n\n'"$stale_text"
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
if (( stale_block )); then
    printf '%s stale hand-off, asked for a rewrite\n' "$STDERR_TAG_REFRESH" >&2
fi
exit 0
