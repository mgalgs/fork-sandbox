#!/usr/bin/env bash
# lkml-round.sh — Launch one fork-sandbox run per persona, in parallel, to
# review (or reply within) an lkml-mode series, then harvest their replies
# back into the mailbox.
#
# Usage: lkml-round.sh <series> --project <path> --checkout <ref> --base <ref>
#            --personas <p1,p2,...> [--reply-to <id>]... [--personas-dir <dir>]
#            [--version <n>] [--timeout <seconds>] [--model-override <harness/model>]
#            [--services-trust-ref <ref>] [--no-summarize]
#
# <project>  the repo fork-sandbox.sh clones -- same argument it takes.
# --checkout the ref each persona's clone starts at: the series' tip, with
#            the patches under review already applied.
# --base     the commit the patches are applied on top of. Told to a
#            reviewer with no --reply-to, so it can `git diff <base>...HEAD`
#            in its own clone instead of guessing the range.
# --personas comma-separated persona slugs, each naming a file
#            <personas-dir>/<persona>.md. Every persona in the list gets
#            launched, whatever the task -- see the lkml-mode skill for why
#            "core" belongs on every panel. A persona file's frontmatter
#            may carry `thinking: <level>` (pi's --thinking values); it is
#            passed to that seat's pi via --pi-args on the pi and pi-local
#            harnesses and ignored on the others.
# --reply-to may repeat. With none given, every launched persona reviews the
#            WHOLE series fresh. With one or more given, every launched
#            persona is told to reply ONLY to those specific threads --
#            this is how a round answers open questions rather than
#            re-reviewing everything.
# --personas-dir defaults to skills/lkml-mode/personas beside this repo's
#            own scripts/ directory.
# --version  which version of the series this round is about. Defaults to
#            the version of the first --reply-to id, or the series' current
#            (highest) version when reviewing fresh.
# --timeout  seconds to wait for every launched run to finish before giving
#            up on harvesting the stragglers. Default 3600. Also the value
#            passed to the post-round summarizer: a round the operator
#            tightened for is a tail the operator tightened for.
# --no-summarize skip the automatic post-round summary. By default, once
#            the harvest is done and harvested at least one reply, the round
#            runs lkml-summarize.sh (resolved from PATH) with the series,
#            --project, the round's own resolved --version and --timeout,
#            so the operator sees where the thread stands after every round
#            instead of at the end. A summary skipped because nothing was
#            harvested costs nothing; a FAILED summary never fails the round
#            -- the replies are already posted to the mailbox, and the
#            summary can be re-run by hand. Refused at startup if
#            lkml-summarize.sh is not on PATH.
# --model-override <harness>[/<model>] overrides every persona's own
#            harness/model for this round only -- useful for a cheap
#            smoke-test round before spending on the real panel. A BARE
#            harness (no /model) drops each persona's frontmatter model --
#            a model name belongs to its harness, the same rule as a
#            seats-file harness without a model: composing it onto the bare
#            harness would ask the endpoint for e.g. 'opus' on pi-local
#            and the leg dies with zero replies (the --model-override 404
#            lesson); a bare pi-local resolves its model from the endpoint,
#            a bare claude takes the harness default. A combined
#            harness/model passes through verbatim. The
#            persona frontmatter pins are defaults, not policy: this
#            machine's seats file (LKML_SEATS_FILE, else
#            ~/.config/fork-sandbox/lkml-seats.yaml) may re-seat any
#            persona, per persona, key by key -- precedence
#            --model-override > seats personas.<p> > seats default: >
#            frontmatter (lkml-seats-resolve owns the rules; a seats
#            harness without a model drops the frontmatter's model). A
#            missing file means the pins stand; an unreadable or
#            unparseable one refuses the whole round before any launch.
#            Every seat the seats file changes is announced on stderr,
#            e.g. `lkml-round: seat core: pi-local (lkml-seats.yaml, was
#            claude/opus)`; --model-override wins over the seats file
#            silently -- it flattens the whole roster, so per-persona
#            seat announcements would be noise.
# --services-trust-ref <ref> is passed through to every seat's
#            fork-sandbox.sh launch. Without it, fork-sandbox.sh disables
#            the repo's .agents/sandbox-services hook on a --checkout run
#            (its warning lands in the captured launch output, unseen), so
#            seats get no per-run services and no provision-ro binds. Pass
#            the trusted base the series came from (e.g. the --base ref);
#            each seat's hook then runs iff its checkout did not change the
#            sandbox-services contract relative to that ref.
#
# What this launches, per persona: a fork-sandbox.sh run, --checkout at the
# series' tip, with a handoff built from the persona file, the mailbox's
# `cover` and `tree` output, and (with --reply-to) the specific threads to
# answer. The secretary seat additionally gets the whole thread's message
# bodies, as a `lkml-render.py --text` render: it summarizes the
# discussion rather than reviewing the diff, and its sandbox cannot read
# the mailbox, so the handoff itself must carry the thread. The run
# makes NO commits -- it writes its replies as
# .git/lkml-out/<n>.msg files in its own clone -- .git/ rather than the
# working tree because git tracks nothing under it, so this project's
# "commit early and often" instinct cannot sweep it into a commit by
# accident (see fork-sandbox.sh's own review-verdict.md and pi-session
# for the same convention). Launches are started back to
# back rather than backgrounded with `&`: each fork-sandbox.sh call returns
# as soon as its own detached tmux session exists, so by the time the last
# one is launched every session is already running concurrently -- the same
# "launch them back to back" idiom the fork-sandbox skill's own Parallelism
# section documents for fanning out several runs.
#
# After every launched run has written summary.json -- fork-sandbox.sh's
# own signal that the run is fully over, including its (possibly empty)
# fetch back into the real repo, written strictly after exit-code -- each
# run's clone is read directly -- `cat`, never git -- for .git/lkml-out/*.msg
# files, which are posted into the mailbox via lkml-mailbox.sh post,
# stamped with that persona's own harness/model and display name. A
# .git/lkml-out file with no In-Reply-To header is skipped with a clear
# warning; the rest of that run's replies still land.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"
default_personas_dir="$(cd "$script_dir/.." && pwd)/skills/lkml-mode/personas"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

series="${1:?Usage: lkml-round.sh <series> --project <path> --checkout <ref> --base <ref> --personas <p1,p2,...>}"
shift

project=""
checkout_ref=""
base_ref=""
personas_csv=""
personas_dir="$default_personas_dir"
version=""
timeout=3600
model_override=""
services_trust_ref=""
summarize=1
reply_to_ids=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --checkout) checkout_ref="${2:?--checkout requires a ref}"; shift 2 ;;
        --base) base_ref="${2:?--base requires a ref}"; shift 2 ;;
        --personas) personas_csv="${2:?--personas requires a comma-separated list}"; shift 2 ;;
        --personas-dir) personas_dir="${2:?--personas-dir requires a directory}"; shift 2 ;;
        --reply-to) reply_to_ids+=("${2:?--reply-to requires an id}"); shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        --model-override) model_override="${2:?--model-override requires harness or harness/model}"; shift 2 ;;
        --services-trust-ref) services_trust_ref="${2:?--services-trust-ref requires a ref}"; shift 2 ;;
        --no-summarize) summarize=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
[[ -n "$checkout_ref" ]] || { echo "Error: --checkout is required." >&2; exit 1; }
[[ -n "$personas_csv" ]] || { echo "Error: --personas is required." >&2; exit 1; }
if (( ${#reply_to_ids[@]} == 0 )); then
    [[ -n "$base_ref" ]] || { echo "Error: --base is required for a fresh-review round (no --reply-to)." >&2; exit 1; }
fi
[[ -d "$personas_dir" ]] || { echo "Error: --personas-dir '$personas_dir' not found." >&2; exit 1; }
command -v fork-sandbox.sh >/dev/null 2>&1 || { echo "Error: fork-sandbox.sh not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }
# Refused at startup, before any persona launches: a panel that spends real
# cost and only then discovers it cannot deliver the summary is the wrong
# failure. Skipped when --no-summarize, which means no summary is owed.
if (( summarize )); then
    command -v lkml-summarize.sh >/dev/null 2>&1 || {
        echo "Error: lkml-summarize.sh not found on PATH (pass --no-summarize to skip the post-round summary)." >&2
        exit 1
    }
fi

seats_active=0
if [[ -z "$model_override" ]]; then
    # Validated once, before ANY persona launches: the launcher below is
    # launch-as-you-go, so a typo in the seats file must refuse the whole
    # round, not half a panel. --model-override flattens the roster
    # regardless, so the seats file is not consulted at all.
    "$script_dir/lkml-seats-resolve" check "$personas_dir" || exit 1
    # Whether a seats file is in effect (and where) is owned by the
    # resolver, the single owner of the LKML_SEATS_FILE default path and
    # its set-but-empty-means-unset semantics: if this launcher
    # re-derived the path and drifted, it would silently launch the
    # whole panel on the frontmatter pins, the fallback the seats file
    # exists to prevent.
    "$script_dir/lkml-seats-resolve" active "$personas_dir" && seats_active=1
fi

trust_args=()
[[ -n "$services_trust_ref" ]] && trust_args=(--services-trust-ref "$services_trust_ref")

if [[ -z "$version" ]]; then
    if (( ${#reply_to_ids[@]} > 0 )); then
        raw="$("$mailbox" show "$series" "${reply_to_ids[0]}" 2>/dev/null)" || {
            echo "Error: --reply-to '${reply_to_ids[0]}' does not resolve in series '$series'." >&2
            exit 1
        }
        version="$(printf '%s\n' "$raw" | sed -n 's/^X-Version: //p')"
    else
        tree_out="$("$mailbox" tree "$series" 2>/dev/null)" || {
            echo "Error: series '$series' does not exist. Run lkml-mailbox.sh init first." >&2
            exit 1
        }
        version="$(printf '%s\n' "$tree_out" | sed -n 's/^=== v\([0-9]\+\) ===$/\1/p' | sort -n | tail -n1)"
    fi
fi
[[ -n "$version" ]] || { echo "Error: could not determine which version this round is about." >&2; exit 1; }

# The checkout and the mailbox version are a single review unit. Resolve the
# checkout against the version-to-branch ledger before building any handoff;
# accepting the branch's commit also supports detached checkouts. Resolve
# recorded branch names explicitly under refs/heads: a short name can be
# ambiguous with a tag, and the checkout must point at the recorded branch's
# commit before the ledger accepts it. When more than one recorded version
# points at that commit, the newest matching entry is the one the ledger
# treats as current.
ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
versions_file="$ledger_root/$series/versions.jsonl"
[[ -f "$versions_file" ]] || {
    echo "Error: no recorded checkout branches for series '$series' in $versions_file." >&2
    exit 1
}
checkout_sha="$(git -C "$project" rev-parse --verify --quiet "$checkout_ref^{commit}" 2>/dev/null)" || {
    echo "Error: checkout '$checkout_ref' does not resolve in $project." >&2
    exit 1
}
matched_version=""
while IFS=$'\t' read -r recorded_version recorded_branch; do
    [[ -n "$recorded_version" && -n "$recorded_branch" ]] || continue
    branch_sha="$(git -C "$project" rev-parse --verify --quiet "refs/heads/$recorded_branch^{commit}" 2>/dev/null || true)"
    if [[ "$checkout_sha" == "$branch_sha" ]] \
            && { [[ -z "$matched_version" ]] || (( recorded_version > matched_version )); }; then
        matched_version="$recorded_version"
    fi
done < <(jq -r 'select((.version|type)=="number" and (.branch|type)=="string") | [.version,.branch] | @tsv' "$versions_file")
if [[ -z "$matched_version" ]]; then
    recorded_branches="$(jq -r 'select(.branch|type=="string") | .branch' "$versions_file" | paste -sd ', ' -)"
    echo "Error: checkout '$checkout_ref' matches no recorded version branch for series '$series'." >&2
    echo "Recorded branches: ${recorded_branches:-<none>.}" >&2
    exit 1
fi
if [[ -n "$version" && "$version" != "$matched_version" ]]; then
    echo "Error: checkout '$checkout_ref' is recorded as v$matched_version, not v$version." >&2
    exit 1
fi
version="$matched_version"

# Every --reply-to id must resolve before ANY persona is launched -- a
# typo'd id would otherwise only be caught when build_handoff calls
# `mailbox show` per-persona, and under `set -uo pipefail` (no `-e`) that
# failure is silent: the command substitution just yields an empty string,
# so the persona is launched -- at real cost -- with a "### Thread <id>"
# section with nothing to reply to. Checking here catches it before any
# run starts, for one `show` per id instead of one per persona per id.
if (( ${#reply_to_ids[@]} > 0 )); then
    for id in "${reply_to_ids[@]}"; do
        raw="$($mailbox show "$series" "$id" 2>/dev/null)" || {
            echo "Error: --reply-to '$id' does not resolve in series '$series'." >&2
            exit 1
        }
        reply_version="$(printf '%s\n' "$raw" | sed -n 's/^X-Version: //p')"
        if [[ "$reply_version" != "$version" ]]; then
            echo "Error: --reply-to '$id' belongs to v${reply_version:-unknown}, not v$version." >&2
            exit 1
        fi
    done
fi

lkml_persona_field() {
    local file="$1" key="$2"
    awk -v k="$key" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { exit }
        infm && $0 ~ "^"k": " { sub("^"k": *", ""); print; exit }
    ' "$file"
}

# Builds one persona's handoff on stdout: the persona file verbatim, the
# series' cover letter and full thread tree, (for the secretary seat)
# the whole thread's message bodies, then either the specific threads to
# answer or instructions to review the whole diff, then the fixed rules
# for writing .git/lkml-out replies.
build_handoff() {
    local persona_file="$1" cover="$2" tree="$3" thread="${4:-}"
    cat -- "$persona_file"
    printf '\n---\n\n# The series you are reviewing: %s, v%s\n\n%s\n' "$series" "$version" "$cover"
    printf '\n## The full thread tree so far\n\n%s\n' "$tree"
    if [[ -n "$thread" ]]; then
        printf "\n## The thread's messages, bodies included\n\n"
        printf 'The tree above is one line per message: id, persona, harness/model,\n'
        printf 'tags and subject. This is the same thread with every message body,\n'
        printf 'in thread order -- [PATCH] bodies keep the commit message and the\n'
        printf 'diffstat, their diff is omitted (the patches are applied in this\n'
        printf 'clone). This round is about v%s -- the section headed \"%s v%s\";\n' "$version" "$series" "$version"
        printf 'earlier versions are there as context.\n\n%s\n' "$thread"
    fi
    if (( ${#reply_to_ids[@]} > 0 )); then
        printf '\n## What to do this round\n\n'
        printf 'Only reply to the specific thread(s) below. Another round already\n'
        printf 'covers reviewing the rest of the series -- do not repeat that here.\n'
        local id
        for id in "${reply_to_ids[@]}"; do
            printf '\n### Thread %s\n\n%s\n' "$id" "$("$mailbox" show "$series" "$id")"
        done
    else
        printf '\n## What to do this round\n\n'
        printf 'Review the whole series. The patches are already applied to this\n'
        printf 'clone, on top of the base commit named below -- read the actual\n'
        printf 'diff in your own clone, not just the cover letter:\n\n'
        printf '    git log %s..HEAD\n    git diff %s...HEAD\n\n' "$base_ref" "$base_ref"
        printf 'Match what you find against the thread tree above, and reply to the\n'
        printf 'existing message it is actually about (usually one of the [PATCH ...] posts).\n'
    fi
    cat <<'RULES'

## How to reply

Write each thing you have to say as its own file under `.git/lkml-out/` in
this clone (create the directory if it does not exist), named `1.msg`,
`2.msg`, `3.msg` ... Under `.git/`, not the working tree: git tracks
nothing there, so it cannot end up staged or committed by accident. Each
file looks like:

    In-Reply-To: <id>
    Subject: <optional -- default is "Re: <the parent's subject>">
    X-Tags: <optional, comma-separated: Reviewed-by, Acked-by, NAK, Changes-requested, Question>

    <your message body>

Rules, all load-bearing:

- **One message per distinct thing you have to say.** Do not bundle several
  separate review comments into one file.
- **`In-Reply-To` must name a message id that already exists** in the
  thread tree above (the full id or any unambiguous prefix of it). That id
  comes from the mailbox and from nowhere else. **A git commit sha is not a
  message id**, however much the short form looks like one -- if you have
  been reading git history, do not reach for what you found there. (The
  mailbox will map a sha to the [PATCH] message that carries it when it
  can, but that is a safety net, not the address.) You cannot reply to a file from
  earlier in this same batch either -- ids are only assigned once your
  reply is posted to the mailbox, which happens after this run ends, so
  nothing you write in this round has an id of its own yet.
- **Tag only when you mean it.** `Reviewed-by` means you would put your
  name on the patch as committed. `Acked-by` means the approach is right
  but you have not verified every line. `NAK` means this must not be
  merged as it stands. `Changes-requested` and `Question` are for exactly
  what they say.
- **Quote what you are responding to**, with `> ` at the start of each
  quoted line, the way an email reply does.
- **Ask a question rather than guess** when you are not sure.
- **Make no commits and no other repository changes.** Do not edit, stage
  or commit anything. Writing `.git/lkml-out/*.msg` files is the whole
  job this round.
- In your final report, say how many `.git/lkml-out/*.msg` files you wrote and,
  in one line each, what each one says.
RULES
    # The persona is the first thing in this handoff and the thread is the
    # last, and the thread can be long. A small model anchors on what it
    # read last: handed another reviewer's eleven confident acks, one seat
    # adopted that reviewer's rubric, its verdicts and its signature. Say
    # who they are once more, after everything else.
    local who slug
    who="$(lkml_persona_field "$persona_file" display)"
    slug="$(lkml_persona_field "$persona_file" persona)"
    [[ -n "$who" ]] || who="$slug"
    printf '\n## Who you are, once more\n\n'
    # shellcheck disable=SC2016  # the backticks are markdown, not a command
    printf 'You are %s (`%s`). The persona text at the top of this document is\n' "$who" "$slug"
    printf 'your brief; the thread is other people'"'"'s work. Review through your own\n'
    printf 'focus list, not another reviewer'"'"'s rubric or section headings, and sign\n'
    printf 'any trailer as %s -- never as another persona. Another\n' "$who"
    printf 'reviewer'"'"'s tag is not evidence for yours; where you can disagree with\n'
    printf 'one, that reply is worth more than one more agreement.\n'
}

cover_text="$("$mailbox" cover "$series" --version "$version" 2>/dev/null)" || cover_text="(no cover letter found)"
tree_text="$("$mailbox" tree "$series" --version "$version" 2>/dev/null)" || tree_text="(no messages yet)"

IFS=',' read -ra personas <<< "$personas_csv"

declare -A run_dir_of=() harness_of=() model_of=() display_of=()
launch_failed=0

# Resolve every seat before ANY launch, and let the launch loop below
# reuse the results. `check` above catches the seats file's parse and
# schema errors; the remaining refusal class is persona-scoped -- an
# explicit seats `thinking:` on a seat that resolves to a non-pi
# harness -- and it is only checkable once that persona's resolved
# harness is known, i.e. per persona, which is why it lives in `resolve`
# rather than in the parser. Resolving inside the launch loop would turn
# that refusal into a per-persona skip, with the rest of the panel
# launched at real cost first; resolving here keeps the same whole-round
# guarantee `check` has for parse errors. (A missing persona FILE stays
# a per-persona skip in the launch loop: a roster typo the operator can
# re-run without touching the seats file.)
declare -A seat_harness=() seat_model=() seat_thinking=() seat_display=()
for persona in "${personas[@]}"; do
    persona="${persona#"${persona%%[![:space:]]*}"}"
    persona="${persona%"${persona##*[![:space:]]}"}"
    [[ -n "$persona" ]] || continue
    persona_file="$personas_dir/$persona.md"
    [[ -f "$persona_file" ]] || continue

    harness="$(lkml_persona_field "$persona_file" harness)"
    model="$(lkml_persona_field "$persona_file" model)"
    display="$(lkml_persona_field "$persona_file" display)"
    thinking="$(lkml_persona_field "$persona_file" thinking)"
    [[ -n "$harness" ]] || harness="claude"
    [[ -n "$display" ]] || display="$persona"
    if [[ -n "$model_override" ]]; then
        if [[ "$model_override" == */* ]]; then
            harness="${model_override%%/*}"
            model="${model_override#*/}"
        else
            # Bare harness: the persona's frontmatter model is DROPPED, not
            # composed onto the bare harness -- pi-local/opus asks the
            # endpoint for a model named 'opus' and the leg dies with zero
            # replies (the --model-override 404 lesson; a seats-file
            # harness without a model drops it the same way).
            harness="$model_override"
            model=""
        fi
    elif (( seats_active )); then
        # The seats file re-seats this persona, key by key; the frontmatter
        # values are the lowest-priority inputs (lkml-seats-resolve owns
        # the precedence). seat_note is non-empty iff the seat changed, in
        # which case the launch must be auditable.
        # { read; ... } rather than `read -r a b c d` from one line: the
        # fields may be empty, and a whitespace IFS would collapse them.
        {
            read -r harness
            read -r model
            read -r thinking
            read -r seat_note
        } < <(
            "$script_dir/lkml-seats-resolve" resolve "$personas_dir" "$persona" \
                "$harness" "$model" "$thinking")
        [[ -n "$harness" ]] || {
            # The resolver already printed the refusal with the persona,
            # key and file named; this refuses the WHOLE round, not just
            # this seat -- the loop below launches as it goes, so a
            # failure there would mean the rest of the panel spends real
            # cost before the round fails.
            echo "Error: seats resolution for $persona failed; no persona was launched." >&2
            exit 1
        }
        [[ -n "$seat_note" ]] && echo "fork-sandbox lkml-round: $seat_note" >&2
    fi
    seat_harness["$persona"]="$harness"
    seat_model["$persona"]="$model"
    seat_thinking["$persona"]="$thinking"
    seat_display["$persona"]="$display"
done

for persona in "${personas[@]}"; do
    persona="${persona#"${persona%%[![:space:]]*}"}"
    persona="${persona%"${persona##*[![:space:]]}"}"
    [[ -n "$persona" ]] || continue

    persona_file="$personas_dir/$persona.md"
    if [[ ! -f "$persona_file" ]]; then
        echo "Error: no persona file '$persona_file' for persona '$persona'." >&2
        launch_failed=1
        continue
    fi

    # Archive a copy of the persona file in the series mailbox so the
    # render can inline each reviewer's brief. Overwrite is intentional:
    # personas rarely change mid-series, and the latest wins.
    archive_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}/$series"
    mkdir -p -- "$archive_root/personas"
    cp -f -- "$persona_file" "$archive_root/personas/$persona.md"

    # Seat facts resolved for the whole roster before any launch (the
    # pre-pass above); this loop is launch-as-you-go, so nothing here may
    # newly refuse a seat.
    harness="${seat_harness[$persona]}"
    model="${seat_model[$persona]}"
    display="${seat_display[$persona]}"
    thinking="${seat_thinking[$persona]}"

    mkdir -p -- /var/tmp/claude-scratch
    handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-round-XXXXXX.md)" || {
        echo "Error: mktemp failed for $persona's handoff file." >&2
        launch_failed=1
        continue
    }
    # The secretary summarizes the discussion instead of reviewing the
    # diff, so unlike the reviewer seats it needs the message bodies.
    # Its sandbox cannot read the mailbox (fork-sandbox.sh binds only
    # its own run dir under /var/tmp/claude-scratch/forks/), so the
    # handoff carries the thread: the --text render of the mailbox,
    # which the seat would otherwise have no way to obtain.
    thread_text=""
    if [[ "$persona" == "secretary" ]]; then
        thread_text="$(python3 "$script_dir/lkml-render.py" --text "$ledger_root/$series" 2>/dev/null)" || thread_text=""
    fi
    build_handoff "$persona_file" "$cover_text" "$tree_text" "$thread_text" > "$handoff_file"

    branch="lkml/${series}-v${version}-round-${persona}-$(date +%s)"
    task_meta="$(jq -nc --arg series "$series" --arg persona "$persona" \
        '{kind:"review", tags:["lkml", $series, $persona]}')"

    harness_spec="$harness"
    [[ -n "$model" ]] && harness_spec="$harness/$model"

    # A persona's `thinking:` field sets pi's reasoning level for its seat.
    # It only means something on a harness that starts pi; fork-sandbox.sh
    # refuses --pi-args elsewhere, so it is dropped for claude and codex --
    # and so is its launch-line mention, which would announce a no-op.
    # A small local thinking model left at its default has been measured
    # spending its whole reply budget reasoning (stop=length, repeatedly)
    # and writing no .git/lkml-out file at all — a reviewer that says
    # nothing. `thinking: low` is the fix for that seat, not a smaller panel.
    pi_args=()
    thinking_note=""
    if [[ -n "$thinking" && ( "$harness" == "pi" || "$harness" == "pi-local" ) ]]; then
        pi_args=(--pi-args "--thinking $thinking")
        thinking_note=", thinking $thinking"
    fi

    echo "fork-sandbox lkml-round: launching $persona ($harness_spec$thinking_note)..." >&2
    launch_out="$(fork-sandbox.sh --harness "$harness_spec" --checkout "$checkout_ref" \
        "${pi_args[@]}" "${trust_args[@]}" \
        --branch "$branch" --task-meta "$task_meta" "$project" "$handoff_file" 2>&1)"
    rc=$?
    run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
    if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
        echo "Error: launching $persona failed:" >&2
        printf '%s\n' "$launch_out" >&2
        launch_failed=1
        continue
    fi
    echo "fork-sandbox lkml-round: $persona -> $run_dir" >&2
    run_dir_of["$persona"]="$run_dir"
    harness_of["$persona"]="$harness"
    model_of["$persona"]="$model"
    display_of["$persona"]="$display"

    # A cost ledger for lkml-status.sh, kept beside the mailbox rather than
    # as an 8th mailbox verb: one JSON line per launched run, so cost can be
    # summed later from each run's own summary.json without lkml-status.sh
    # having to know how a run was launched.
    ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
    mkdir -p -- "$ledger_root/$series"
    jq -nc --arg persona "$persona" --arg run_dir "$run_dir" --arg kind review \
        '{persona:$persona, run_dir:$run_dir, kind:$kind}' >> "$ledger_root/$series/runs.jsonl"
done

if (( ${#run_dir_of[@]} == 0 )); then
    echo "Error: no persona was launched successfully." >&2
    exit 1
fi

echo "fork-sandbox lkml-round: waiting up to ${timeout}s for ${#run_dir_of[@]} run(s)..." >&2
waited=0
while true; do
    all_done=1
    for persona in "${!run_dir_of[@]}"; do
        [[ -f "${run_dir_of[$persona]}/summary.json" ]] || all_done=0
    done
    (( all_done )) && break
    if (( waited >= timeout )); then
        echo "Warning: timed out after ${timeout}s waiting for every run; harvesting" >&2
        echo "whatever has finished so far." >&2
        break
    fi
    sleep 10
    waited=$(( waited + 10 ))
done

# Strips optional angle brackets and the @lkml.local suffix from an
# In-Reply-To value, mirroring lkml-mailbox.sh's own lkml_strip_id --
# duplicated here because this script only invokes the mailbox as a
# subprocess, never sources it. A persona shown `Message-ID: <uuid@lkml.local>`
# in its handoff (every --reply-to round embeds `mailbox show` output) may
# reasonably copy that RFC-822 form verbatim into its own In-Reply-To, and
# `post --reply-to` only resolves bare ids.
lkml_round_strip_id() {
    local v="$1"
    v="${v#<}"
    v="${v%>}"
    v="${v%%@*}"
    printf '%s' "$v"
}

harvest_one() {
    local persona="$1" display="$2" harness="$3" model="$4" msgfile="$5"
    local reply_to="" subject="" tags="" body_file in_headers=1 line
    body_file="$(mktemp)"
    : > "$body_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( in_headers )); then
            if [[ -z "$line" ]]; then
                in_headers=0
                continue
            fi
            case "$line" in
                In-Reply-To:*) reply_to="${line#In-Reply-To: }" ;;
                Subject:*) subject="${line#Subject: }" ;;
                X-Tags:*) tags="${line#X-Tags: }" ;;
            esac
        else
            printf '%s\n' "$line" >> "$body_file"
        fi
    done < "$msgfile"
    reply_to="$(lkml_round_strip_id "$reply_to")"

    if [[ -z "$reply_to" ]]; then
        echo "Warning: lkml-round: $msgfile (persona $persona) has no In-Reply-To" >&2
        echo "header; skipping it." >&2
        rm -f "$body_file"
        return 1
    fi

    local -a extra=()
    [[ -n "$subject" ]] && extra=(--subject "$subject")
    [[ -n "$tags" ]] && extra+=(--tags "$tags")

    local id rc=0
    id="$("$mailbox" post "$series" --from "$persona" --display "$display" \
        --reply-to "$reply_to" --file "$body_file" --harness "$harness" --model "$model" \
        "${extra[@]}")" || rc=$?
    rm -f "$body_file"
    if (( rc != 0 )); then
        echo "Warning: lkml-round: failed to post $msgfile (persona $persona)." >&2
        return 1
    fi
    echo "fork-sandbox lkml-round: harvested $(basename -- "$msgfile") from $persona as ${id:0:7}" >&2
    return 0
}

harvested=0
for persona in "${!run_dir_of[@]}"; do
    run_dir="${run_dir_of[$persona]}"
    if [[ ! -f "$run_dir/summary.json" ]]; then
        echo "Warning: $persona's run never finished; nothing harvested from it." >&2
        continue
    fi
    clone_dir="$(jq -r '.clone_dir' "$run_dir/summary.json")"
    out_dir="$clone_dir/.git/lkml-out"
    # A pi-local persona names no model -- the endpoint picks one -- and
    # `post` refuses an empty --model. The run's summary records what the
    # endpoint actually served; stamp that.
    model="${model_of[$persona]}"
    if [[ -z "$model" ]]; then
        model="$(jq -r '.model // empty' "$run_dir/summary.json" 2>/dev/null || true)"
    fi
    [[ -n "$model" ]] || model="unknown"
    if [[ ! -d "$out_dir" ]]; then
        echo "fork-sandbox lkml-round: $persona wrote no .git/lkml-out replies." >&2
        continue
    fi
    while IFS= read -r msgfile; do
        [[ -e "$msgfile" ]] || continue
        harvest_one "$persona" "${display_of[$persona]}" "${harness_of[$persona]}" \
            "$model" "$msgfile" && harvested=$(( harvested + 1 ))
    done < <(find "$out_dir" -maxdepth 1 -name '*.msg' | sort -V)
done

echo "fork-sandbox lkml-round: harvested $harvested repl$( (( harvested == 1 )) && echo y || echo ies )." >&2

# The per-round summary: it takes as long as two sequential sandbox runs, so
# the operator watching stderr must not think the round hung.
if (( summarize )); then
    if (( harvested == 0 )); then
        # Zero replies means the thread is unchanged: re-deriving the same
        # document at the cost of two sandbox runs would be pure waste.
        echo "fork-sandbox lkml-round: nothing harvested; skipping the summary for $series v$version." >&2
    else
        # A launch failure does NOT suppress the summary: if two of five
        # personas launched and both replied, the thread changed and the
        # summary should reflect it. Only harvested == 0 suppresses.
        echo "fork-sandbox lkml-round: summarizing $series v$version (two sequential sandbox runs)..." >&2
        # Bare name, resolved from PATH, like the fork-sandbox.sh launcher
        # above -- it is a launcher-orchestrator, not a shipped helper.
        # lkml-summarize.env owns the tier selection, so no tier is passed.
        # A failure must NOT fail the round: the replies are already posted
        # and that work is durable; the round's exit status stays exactly
        # what launch_failed says.
        if ! lkml-summarize.sh "$series" --project "$project" --version "$version" --timeout "$timeout"; then
            echo "Warning: lkml-round: summarizing $series v$version failed; the replies are already posted to the mailbox -- re-run lkml-summarize.sh by hand." >&2
        fi
    fi
fi
(( launch_failed == 0 ))
