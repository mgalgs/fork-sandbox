#!/usr/bin/env bash
# fork-sandbox-format.sh — Render a fork-sandbox stream-json event log as readable lines
#
# Usage: fork-sandbox-format.sh [--result | --notable | --commit-count] [--tail N] [file]
#
# --result:        print only the final result event, which carries the
#                  session's own summary of what it did.
# --notable:       print only the lines worth waking someone for — commits,
#                  an operator addendum reaching the session, a --refresh-at
#                  continuation starting, and the final result.
#                  fork-sandbox-status.sh --monitor uses it.
# --commit-count:  print how many commits the session appears to have made.
#                  It counts `git commit` calls, so it is an estimate: a
#                  commit made by a script does not show, and a failed or
#                  amended commit still counts. It understands the claude and
#                  the pi event shapes; a log in a shape it does not know
#                  counts as zero. The exact number comes from git, in the
#                  run's summary.txt.
# --cost:          print what the session cost in dollars, from the result
#                  event, or nothing when there is no result to read. The
#                  figure is cumulative for the session, so a log holding
#                  more than one result — a resumed run — yields the last.
# --usage:         print the session's token counts as one JSON object:
#                  input, output, cache read, cache write and total. A
#                  count the result event does not carry comes out null,
#                  not zero, so "not reported" cannot be read as "none
#                  used". Nothing at all when there is no result event.
# --tail N:        print only the last N lines of output.
# -h, --help:      print this header and exit.
#
# With no file it reads stdin, which is how fork-sandbox.sh renders the live
# session in its tmux session. A line that is not JSON is dropped, so the
# sandbox's own messages can share the stream without breaking anything.
#
# This script only reads and formats. It is not blanket-approved, because it
# will format any file it is pointed at. fork-sandbox-status.sh is the
# approved entry point; it validates the path first and then calls this.

set -uo pipefail

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

mode="all"
tail_n=""
file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result) mode="result"; shift ;;
        --notable) mode="notable"; shift ;;
        --commit-count) mode="commit-count"; shift ;;
        --cost) mode="cost"; shift ;;
        --usage) mode="usage"; shift ;;
        --tail) tail_n="${2:?--tail requires a count}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
        *)
            if [[ -n "$file" ]]; then
                echo "Error: only one file may be given" >&2
                exit 1
            fi
            file="$1"
            shift
            ;;
    esac
done

if [[ -n "$tail_n" && ! "$tail_n" =~ ^[0-9]+$ ]]; then
    echo "Error: --tail takes a number" >&2
    exit 1
fi

# Shared helpers. `flat` collapses the whitespace a tool input or an assistant
# paragraph carries, so one event stays on one line. `clean` strips the other
# control characters: the session's text is untrusted, and a raw ESC or CR
# reaching the pane, the summary or the monitor stream could spoof what the
# observer sees. Tab and newline stay.
# shellcheck disable=SC2016  # these are jq programs, not shell strings
JQ_PRELUDE='
def clip($n): if (. | length) > $n then (.[0:$n] + "…") else . end;
def clean: gsub("[\u0000-\u0008\u000B-\u001F\u007F]"; "");
def flat: clean | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def toolarg:
  (.input // {})
  | (.command // .file_path // .pattern // .path // .url // .description // "")
  | if type == "string" then . else tojson end;
def inboxline:
  # The operator-inbox hook writes one tagged line to stderr when it hands
  # addenda to the session, and --include-hook-events puts that stderr in the
  # stream. It is the only evidence a delivery happened, so both the full
  # render and the notable filter report it. Everything else about a hook
  # firing is noise here.
  select(.type == "system" and .subtype == "hook_response")
  | ((.stderr // "") | flat)
  | select(startswith("fork-sandbox-inbox:") or startswith("fork-sandbox-refresh:"))
  | "◆ \(.)";
def refreshline:
  # --refresh-at own marker, written directly into events.jsonl by
  # fork-sandbox.sh runner (not by a hook) the moment it starts a
  # continuation leg -- see the refresh loops own comment for why. This is
  # the only line --monitor gets to announce one starting, since a legs own
  # first event is otherwise indistinguishable from the implement legs.
  select(.type == "system" and .subtype == "fork_sandbox_continuation")
  | "◆ fork-sandbox-refresh: leg \(.leg) from \(.handoff)";
def resulthead:
  "== result: \(.subtype // "?")\(if .is_error then " (ERROR)" else "" end)"
  + " · \(.num_turns // 0) turns"
  + " · \(((.duration_ms // 0) / 1000) | floor)s"
  + " · $\(((.total_cost_usd // 0) * 100 | round) / 100) ==";
'

JQ_ALL="$JQ_PRELUDE"'
fromjson? // empty
| if .type == "system" and .subtype == "init" then
    "· model \(.model // "?")  cwd \(.cwd // "?")"
  elif .type == "assistant" then
    ((.message.content // [])[]
     | if .type == "text" then
         ((.text // "") | flat | clip(300)) | select(. != "")
       elif .type == "tool_use" then
         ("→ \(.name // "?") \(toolarg)" | flat | clip(140))
       else empty end)
  elif .type == "user" then
    ((.message.content // [])[]
     | select((.type == "tool_result") and (.is_error == true))
     | ((.content
         | if type == "array" then (map(.text // "") | join(" "))
           else (. // "" | tostring) end)
        | flat | clip(160))
     | "  ⚠ tool error: \(.)")
  elif .type == "system" and .subtype == "hook_response" then
    inboxline
  elif .type == "system" and .subtype == "fork_sandbox_continuation" then
    refreshline
  elif .type == "result" then
    "\n\(resulthead)\n\((.result // .error // "(no text)") | clean)"
  else empty end
'

JQ_RESULT="$JQ_PRELUDE"'
fromjson? // empty
| select(.type == "result")
| "\(resulthead)\n\((.result // .error // "(no text)") | clean)"
'

# A commit is the progress signal worth reporting while the work runs. The
# final result event is the terminal one. Nothing else earns a notification.
#
# The commit line comes from the Bash call, because that is where the message
# is. A commit made some other way — a wrapper script, a Makefile target —
# shows no line. The count below is the same heuristic, on both harness
# shapes: claude carries the call in an assistant message's tool_use, pi in a
# tool_execution_start's args. The line is an estimate while the work runs;
# the real number comes from git, in the summary the runner writes after it
# fetches the branch.
JQ_NOTABLE="$JQ_PRELUDE"'
fromjson? // empty
| if .type == "assistant" then
    ((.message.content // [])[]
     | select(.type == "tool_use" and .name == "Bash")
     | (.input.command // "")
     | select(test("\\bgit\\b[^|;&]*\\bcommit\\b"))
     | "commit: \(. | flat | clip(140))")
  elif .type == "tool_execution_start" then
    (select(.toolName == "bash")
     | (.args // {} | if type == "object" then (.command // "") else "" end)
     | select(test("\\bgit\\b[^|;&]*\\bcommit\\b"))
     | "commit: \(. | flat | clip(140))")
  elif .type == "system" and .subtype == "hook_response" then
    inboxline
  elif .type == "system" and .subtype == "fork_sandbox_continuation" then
    refreshline
  elif .type == "result" then
    "\(resulthead)\n\((.result // .error // "(no text)") | clean)"
  else empty end
'

# The same heuristic as the notable commit line, per harness: claude carries
# the call in an assistant message's tool_use content, pi in a
# tool_execution_start's args — pi's tool_execution_end carries the result
# but not the arguments, so the start is the record that has the command.
# A log in any other shape (codex's, today) matches neither and counts as
# zero; the exact number still comes from git, in the summary the runner
# writes after it fetches the branch.
JQ_COMMIT_COUNT='
[ inputs
  | fromjson? // empty
  | ( (select(.type == "assistant")
       | (.message.content // [])[]
       | select(.type == "tool_use" and .name == "Bash")
       | (.input.command // "")),
      (select(.type == "tool_execution_start")
       | select(.toolName == "bash")
       | (.args // {} | if type == "object" then (.command // "") else "" end)) )
  | select(type == "string" and . != "")
  | select(test("\\bgit\\b[^|;&]*\\bcommit\\b")) ]
| length
'

# total_cost_usd is cumulative for the session, so the last result event
# is the answer rather than the sum. A log with no result — a session that
# was killed — prints nothing, and the caller reports no cost rather than
# a wrong one.
JQ_COST='
[ inputs
  | fromjson? // empty
  | select(.type == "result")
  | .total_cost_usd // empty ]
| last // empty
'

# Token counts, in the shape every harness reports through: whatever the
# result event does not carry comes out null rather than zero, because a
# zero would read as "none used" instead of "not reported". Cumulative
# for the session, like the cost, so the last result event wins.
JQ_USAGE='
[ inputs
  | fromjson? // empty
  | select(.type == "result")
  | .usage // empty ]
| last
| if . == null then empty else
    {
      input_tokens: (.input_tokens // null),
      output_tokens: (.output_tokens // null),
      cache_read_tokens: (.cache_read_input_tokens // null),
      cache_write_tokens: (.cache_creation_input_tokens // null),
      reasoning_output_tokens: null,
      total_tokens: (
        [ .input_tokens, .output_tokens,
          .cache_read_input_tokens, .cache_creation_input_tokens ]
        | map(select(type == "number"))
        | if length == 0 then null else add end
      ),
    }
  end
'

jq_args=()
case "$mode" in
    all) program="$JQ_ALL" ;;
    result) program="$JQ_RESULT" ;;
    notable) program="$JQ_NOTABLE" ;;
    commit-count) program="$JQ_COMMIT_COUNT"; jq_args=(-n) ;;
    cost) program="$JQ_COST"; jq_args=(-n) ;;
    usage) program="$JQ_USAGE"; jq_args=(-n -c) ;;
    *) echo "Error: unknown mode" >&2; exit 1 ;;
esac

# -R reads each line as a string so `fromjson?` can drop the ones that are not
# JSON. --unbuffered keeps the live tmux window moving event by event.
render() {
    if [[ -n "$file" ]]; then
        jq -R -r --unbuffered "${jq_args[@]}" "$program" < "$file"
    else
        jq -R -r --unbuffered "${jq_args[@]}" "$program"
    fi
}

if [[ "$mode" == "result" ]]; then
    # A resumed or restarted run can hold more than one result event. The last
    # one is the outcome.
    # No result event means the session never reached the end. Say nothing and
    # let the caller decide what that means; fork-sandbox-status.sh points at
    # the sandbox log instead.
    out="$(render)"
    if [[ -z "$out" ]]; then
        exit 0
    fi
    # Each result is a header line followed by its text. Keep the last block.
    printf '%s\n' "$out" | awk '
        /^== result: / { buf = $0; next }
        { buf = buf "\n" $0 }
        END { if (length(buf)) print buf }'
elif [[ -n "$tail_n" ]]; then
    render | tail -n "$tail_n"
else
    render
fi
