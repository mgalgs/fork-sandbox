#!/usr/bin/env bash
# lkml-round.sh — Launch one fork-sandbox run per persona, in parallel, to
# review (or reply within) an lkml-mode series, then harvest their replies
# back into the mailbox.
#
# Usage: lkml-round.sh <series> --project <path> --checkout <ref> --base <ref>
#            --personas <p1,p2,...> [--reply-to <id>]... [--personas-dir <dir>]
#            [--version <n>] [--timeout <seconds>] [--model-override <harness/model>]
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
#            "linus" belongs on every panel.
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
#            up on harvesting the stragglers. Default 3600.
# --model-override <harness>[/<model>] overrides every persona's own
#            harness/model for this round only -- useful for a cheap
#            smoke-test round before spending on the real panel.
#
# What this launches, per persona: a fork-sandbox.sh run, --checkout at the
# series' tip, with a handoff built from the persona file, the mailbox's
# `cover` and `tree` output, and (with --reply-to) the specific threads to
# answer. The run makes NO commits -- it writes its replies as
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

# Every --reply-to id must resolve before ANY persona is launched -- a
# typo'd id would otherwise only be caught when build_handoff calls
# `mailbox show` per-persona, and under `set -uo pipefail` (no `-e`) that
# failure is silent: the command substitution just yields an empty string,
# so the persona is launched -- at real cost -- with a "### Thread <id>"
# section with nothing to reply to. Checking here catches it before any
# run starts, for one `show` per id instead of one per persona per id.
if (( ${#reply_to_ids[@]} > 0 )); then
    for id in "${reply_to_ids[@]}"; do
        "$mailbox" show "$series" "$id" >/dev/null 2>&1 || {
            echo "Error: --reply-to '$id' does not resolve in series '$series'." >&2
            exit 1
        }
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
# series' cover letter and full thread tree, then either the specific
# threads to answer or instructions to review the whole diff, then the
# fixed rules for writing .git/lkml-out replies.
build_handoff() {
    local persona_file="$1" cover="$2" tree="$3"
    cat -- "$persona_file"
    printf '\n---\n\n# The series you are reviewing: %s, v%s\n\n%s\n' "$series" "$version" "$cover"
    printf '\n## The full thread tree so far\n\n%s\n' "$tree"
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
  message id**, however much the short form looks like one, and a reply
  naming one is rejected outright -- if you have been reading git history,
  do not reach for what you found there. You cannot reply to a file from
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
}

cover_text="$("$mailbox" cover "$series" 2>/dev/null)" || cover_text="(no cover letter found)"
tree_text="$("$mailbox" tree "$series" 2>/dev/null)" || tree_text="(no messages yet)"

IFS=',' read -ra personas <<< "$personas_csv"

declare -A run_dir_of=() harness_of=() model_of=() display_of=()
launch_failed=0

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

    harness="$(lkml_persona_field "$persona_file" harness)"
    model="$(lkml_persona_field "$persona_file" model)"
    display="$(lkml_persona_field "$persona_file" display)"
    [[ -n "$harness" ]] || harness="claude"
    [[ -n "$display" ]] || display="$persona"
    if [[ -n "$model_override" ]]; then
        if [[ "$model_override" == */* ]]; then
            harness="${model_override%%/*}"
            model="${model_override#*/}"
        else
            harness="$model_override"
        fi
    fi

    mkdir -p -- /var/tmp/claude-scratch
    handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-round-XXXXXX.md)" || {
        echo "Error: mktemp failed for $persona's handoff file." >&2
        launch_failed=1
        continue
    }
    build_handoff "$persona_file" "$cover_text" "$tree_text" > "$handoff_file"

    branch="lkml/${series}-v${version}-round-${persona}-$(date +%s)"
    task_meta="$(jq -nc --arg series "$series" --arg persona "$persona" \
        '{kind:"review", tags:["lkml", $series, $persona]}')"

    harness_spec="$harness"
    [[ -n "$model" ]] && harness_spec="$harness/$model"

    echo "fork-sandbox lkml-round: launching $persona ($harness_spec)..." >&2
    launch_out="$(fork-sandbox.sh --harness "$harness_spec" --checkout "$checkout_ref" \
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
    if [[ ! -d "$out_dir" ]]; then
        echo "fork-sandbox lkml-round: $persona wrote no .git/lkml-out replies." >&2
        continue
    fi
    while IFS= read -r msgfile; do
        [[ -e "$msgfile" ]] || continue
        harvest_one "$persona" "${display_of[$persona]}" "${harness_of[$persona]}" \
            "${model_of[$persona]}" "$msgfile" && harvested=$(( harvested + 1 ))
    done < <(find "$out_dir" -maxdepth 1 -name '*.msg' | sort -V)
done

echo "fork-sandbox lkml-round: harvested $harvested repl$( (( harvested == 1 )) && echo y || echo ies )." >&2
(( launch_failed == 0 ))
