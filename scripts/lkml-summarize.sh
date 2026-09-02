#!/usr/bin/env bash
# lkml-summarize.sh — Turn a finished lkml-mode review thread into
# condensed, actionable intelligence, written into the series dir.
#
# Usage: lkml-summarize.sh <series> --project <path> [--version <n>]
#            [--high <harness[/model]>] [--low <harness[/model]>]
#            [--timeout <seconds>] [--series]
#
# <series>   the mailbox series; its dir is $LKML_MAILBOX_ROOT/<series>.
# --project  the repo fork-sandbox.sh clones. Both tiers start at the
#            series' tip -- the branch recorded for the summarized
#            version in <series>/versions.jsonl -- on their own
#            throwaway branches, deleted again when the run returns
#            (the tiers make no commits, so the branches carry none).
# --version  which version to summarize (a plain integer N). Defaults
#            to the latest recorded version.
# --high     which harness[/model] the synthesis tier runs on.
# --low      which harness[/model] the extraction tier runs on.
#            A BARE harness (no /model) is passed to fork-sandbox.sh
#            bare, and nothing is expanded here -- pi-local resolves
#            its model from the endpoint itself. A combined
#            harness/model passes through verbatim. Do NOT hand a bare
#            harness a persona-style model name: the endpoint is asked
#            for it verbatim and the leg dies with zero replies -- what
#            the lkml-round.sh --model-override 404 lesson was about. Without the
#            flag, each tier falls back to the machine default in
#            ~/.config/fork-sandbox/lkml-summarize.env (keys
#            LKML_SUMMARIZE_HIGH / LKML_SUMMARIZE_LOW, same form; the
#            file's path is overridable via LKML_SUMMARIZE_ENV_FILE),
#            then to the shipped defaults high=claude/opus,
#            low=claude/sonnet. Flags beat env, env beats default.
# --timeout  seconds to wait for each tier's run to finish. Default 3600.
# --series   synthesize the WHOLE series instead of one version: a
#            single synthesis run, no extraction tier. Its handoff
#            carries, inline, every recorded version's results-v<N>.
#            json intermediate (which must all exist already) verbatim
#            in version order, every version's tally section, and the
#            latest version's cover letter; it writes the whole-series
#            narrative to <series>/results-series.md -- what the series
#            does, the review arc v1 to vN, where it stands, what
#            happens next. Refuses --version ("pick one") and --low
#            (there is no extraction tier; --high still selects the
#            synthesis model), and refuses when any recorded version
#            lacks its results-v<N>.json.
#
# Input is `lkml-render.py --text <series-dir>` output ONLY -- never
# the HTML view. The render is carried inline in each tier's handoff
# because a sandboxed run cannot read the mailbox (the same lesson as
# lkml-round.sh's secretary seat, whose handoff carries the thread
# for exactly this reason).
#
# The pipeline is sequential, one sandboxed run per tier:
#   1. LOW tier (extraction): reads the whole --text thread and writes
#      a structured intermediate to its run's OUTBOX. This script
#      harvests it VERBATIM as <series>/results-v<N>.json and feeds it,
#      plus the render's tally section for this version, inline to
#   2. HIGH tier (synthesis): which writes the results document to its
#      run's OUTBOX, harvested as <series>/results-v<N>.md.
# Re-summarizing a version overwrites both files once both tiers have
# delivered their outbox files (a failed high tier leaves the previous
# pair untouched); the written paths are the last stdout lines.
#
# results-v<N>.md is a FORMAT CONTRACT, not a free-form essay -- a
# render round is meant to show # Summary as a small collapsed card
# (nothing in the tree depends on that yet):
#     # Summary
#     (1-2 short paragraphs: ~120 words; this script WARNS on stderr
#      above ~200)
#     # Details
#     (free-form: defect list with severity/status and message-id
#      citations, per-patch disposition, recommended next actions)
# Message ids are cited as bare 7-hex tokens (e.g. 9d67f5e) -- no
# brackets, no anchors: a plain convention that keeps the id greppable
# against the --text render.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
render_py="$script_dir/lkml-render.py"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

series="${1:?Usage: lkml-summarize.sh <series> --project <path> [--version <n>] [--high <harness[/model]>] [--low <harness[/model]>] [--timeout <seconds>]}"
shift

project=""
version=""
series_mode=""
high_spec=""
low_spec=""
timeout=3600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --series) series_mode=1; shift ;;
        --high) high_spec="${2:?--high requires a harness or harness/model}"; shift 2 ;;
        --low) low_spec="${2:?--low requires a harness or harness/model}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
if [[ -n "$series_mode" ]]; then
    if [[ -n "$version" ]]; then
        echo "Error: --series summarizes the whole series and --version picks one; pick one." >&2
        exit 1
    fi
    if [[ -n "$low_spec" ]]; then
        echo "Error: --series takes no --low: the series run is a single synthesis run with no extraction tier (--high still selects its model)." >&2
        exit 1
    fi
fi
[[ "$timeout" =~ ^[0-9]+$ ]] || { echo "Error: --timeout must be a number of seconds." >&2; exit 1; }
if [[ -n "$version" ]]; then
    [[ "$version" =~ ^[0-9]+$ ]] || { echo "Error: --version must be a plain integer." >&2; exit 1; }
fi
command -v fork-sandbox.sh >/dev/null 2>&1 || { echo "Error: fork-sandbox.sh not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found on PATH; lkml-render.py needs it." >&2; exit 1; }

# Reads one NAME=VALUE line from an env file, first match wins, never
# sourced. Identical to fork-sandbox-lib.sh's own fs_read_env_value and
# fork-sandbox-k8s.sh's read_env_value -- kept apart on purpose, the
# way lkml-round.sh keeps its own copy of lkml_persona_field: if one
# changes, check the other.
lkml_summarize_env_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

env_file="${LKML_SUMMARIZE_ENV_FILE:-$HOME/.config/fork-sandbox/lkml-summarize.env}"

# Flag beats env beats shipped default. The value is either a bare
# harness or a combined harness/model, and passes through to
# fork-sandbox.sh UNCHANGED: a bare pi-local (no /model) expands by
# asking nothing -- fork-sandbox.sh resolves a pi-local model from the
# endpoint itself. See the usage header for the --model-override 404
# lesson this refusal to invent names protects against.
resolve_tier() {
    local flag_name="$1" flag_value="$2" env_key="$3" default="$4" spec source raw
    if [[ -n "$flag_value" ]]; then
        spec="$flag_value"
        source="the $flag_name flag"
    else
        spec="$(lkml_summarize_env_value "$env_file" "$env_key" || true)"
        source="the $env_key env key"
        if [[ -z "$spec" ]]; then
            spec="$default"
            source="the shipped default"
        fi
    fi
    raw="$spec"
    spec="${spec#"${spec%%[![:space:]]*}"}"
    spec="${spec%"${spec##*[![:space:]]}"}"
    if [[ -z "$spec" || "$spec" == *[[:space:]]* ]]; then
        echo "Error: tier setting '$source' is '${raw}' -- empty or contains whitespace; expected a harness or harness/model." >&2
        return 1
    fi
    if [[ ! "$spec" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]]; then
        echo "Error: tier setting '$source' is '$spec', not a harness or harness/model." >&2
        return 1
    fi
    printf '%s' "$spec"
}

high_spec="$(resolve_tier --high "$high_spec" LKML_SUMMARIZE_HIGH claude/opus)" || exit 1
# --low is meaningless in series mode (refused above); its env key is
# likewise unused there, so do not resolve it.
if [[ -z "$series_mode" ]]; then
    low_spec="$(resolve_tier --low "$low_spec" LKML_SUMMARIZE_LOW claude/sonnet)" || exit 1
fi

ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
series_dir="$ledger_root/$series"
[[ -d "$series_dir/cur" ]] || {
    echo "Error: series '$series' does not exist under $ledger_root. Run lkml-mailbox.sh init first." >&2
    exit 1
}

# The input is the --text render of the mailbox, and ONLY that. It is
# carried inline in the tiers' handoffs because their sandboxes cannot
# read the mailbox -- the same reason lkml-round.sh hands its secretary
# seat the whole thread. An empty render means an empty mailbox, and
# summing nothing is not a summary.
render_text="$(python3 "$render_py" --text "$series_dir" 2>/dev/null)"
render_rc=$?
if (( render_rc != 0 )); then
    echo "Error: lkml-render.py --text $series_dir failed (exit $render_rc)." >&2
    exit 1
fi
if [[ -z "${render_text//[[:space:]]/}" ]]; then
    echo "Error: the --text render of series '$series' is empty; there is no thread to summarize." >&2
    exit 1
fi

# The version-to-branch ledger ties the summarized version to the
# branch the tiers check out: the series' tip for that version. Same
# ledger lkml-round.sh validates its --checkout against and
# lkml-forklift.sh reads; the last recorded entry for a version wins
# (versions are only ever posted forward, so this is a formality).
versions_file="$series_dir/versions.jsonl"
if [[ ! -f "$versions_file" ]]; then
    echo "Error: no recorded checkout branches for series '$series' in $versions_file." >&2
    exit 1
fi
if [[ -z "$version" ]]; then
    version="$(jq -r 'select((.version|type)=="number") | .version' "$versions_file" | sort -n | tail -n1)"
fi
[[ -n "$version" ]] || {
    echo "Error: $versions_file records no versions for series '$series'." >&2
    exit 1
}
checkout_branch="$(jq -r --argjson v "$version" \
    'select((.version|type)=="number" and (.branch|type)=="string") | select(.version==$v) | .branch' \
    "$versions_file" | tail -n1)"
if [[ -z "$checkout_branch" ]]; then
    recorded_versions="$(jq -r 'select((.version|type)=="number") | .version' "$versions_file" | sort -n | paste -sd ', ' -)"
    echo "Error: v$version has no recorded branch in $versions_file." >&2
    echo "Recorded versions: ${recorded_versions:-<none>}." >&2
    exit 1
fi

# The tally section of the --text render for <version>: the section
# header line through the first 72-dash message separator -- the
# counts, the latest-tag-per-reviewer-per-patch table and the reviewer
# block. The synthesis tier gets THIS instead of the whole thread: the
# extraction intermediate already carries the message-level detail.
extract_tally() {
    local v="$1" t="" in_section=0 ln
    while IFS= read -r ln; do
        if (( in_section )) && [[ "$ln" =~ ^-{72}$ ]]; then
            in_section=0
            break
        fi
        [[ "$ln" == "$series v$v" ]] && in_section=1
        (( in_section )) && t+="$ln"$'\n'
    done <<< "$render_text"
    printf '%s' "$t"
}

# The cover letter of the --text render's <version> section: from the
# section's first message (its 72-dash separator) through the
# separator that opens the section's second message -- the cover is
# the first message of the section. An all-remaining section (no
# other messages) runs to the end of the render.
extract_cover() {
    local v="$1" t="" in_section=0 in_cover=0 ln
    while IFS= read -r ln; do
        [[ "$ln" == "$series v$v" ]] && in_section=1
        (( in_section )) || continue
        if [[ "$ln" =~ ^-{72}$ ]]; then
            if (( in_cover )); then
                in_cover=0
                break
            fi
            in_cover=1
        fi
        (( in_cover )) && t+="$ln"$'\n'
    done <<< "$render_text"
    printf '%s' "$t"
}

if [[ -n "$series_mode" ]]; then
    # Series mode: version is already the latest recorded one. The
    # inputs are the per-version intermediates already on disk, every
    # version's tally section and the latest version's cover letter --
    # the per-version pipeline's own loud checks above all still apply.
    recorded_versions=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && recorded_versions+=("$v")
    # -u: the version ledger is append-only, so a version can carry
    # two entries; the newest one already won every per-version run,
    # and feeding the same version into the handoff twice would pay
    # double tokens for the same section.
    done < <(jq -r 'select((.version|type)=="number") | .version' "$versions_file" | sort -n -u)
    missing=()
    for v in "${recorded_versions[@]}"; do
        [[ -f "$series_dir/results-v${v}.json" ]] || missing+=("$v")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Error: --series needs every recorded version's results-v<N>.json intermediate; missing for: ${missing[*]}." >&2
        for v in "${missing[@]}"; do
            echo "  run lkml-summarize.sh $series --project $project --version $v first." >&2
        done
        exit 1
    fi
    tallies=()
    for v in "${recorded_versions[@]}"; do
        t="$(extract_tally "$v")"
        if [[ -z "$t" ]]; then
            echo "Error: the --text render has no section for '$series v$v'; the version ledger and the mailbox disagree." >&2
            exit 1
        fi
        tallies+=("$t")
    done
    cover_text="$(extract_cover "$version")"
    if [[ -z "$cover_text" ]]; then
        echo "Error: the --text render's '$series v$version' section has no cover letter; the version ledger and the mailbox disagree." >&2
        exit 1
    fi
    echo "fork-sandbox lkml-summarize: summarizing $series, whole series (v${recorded_versions[0]} to v$version; high: $high_spec)" >&2
else
    echo "fork-sandbox lkml-summarize: summarizing $series v$version (low: $low_spec, high: $high_spec)" >&2
fi

# Per-version mode only: in --series mode every recorded version's tally
# was already extracted and checked in the loop above, and the series
# handoff carries them from $tallies, so the latest one would be read
# twice for no consumer.
if [[ -z "$series_mode" ]]; then
    tally_text="$(extract_tally "$version")"
    if [[ -z "$tally_text" ]]; then
        echo "Error: the --text render has no section for '$series v$version'; the version ledger and the mailbox disagree." >&2
        exit 1
    fi
fi


# The throwaway branches carry no commits (the tiers are forbidden to
# make any), and fork-sandbox.sh already deletes such a branch itself
# the moment its fetch finds none: on a normal run "the branch is
# gone" is the expected outcome, not a failure. A branch survives only
# if a tier disobeyed and committed, and branch -D is how that one goes
# away; warn only when the branch is still there AND the delete fails.
delete_branch() {
    local branch="$1"
    if ! git -C "$project" show-ref --verify -q "refs/heads/$branch"; then
        return 0
    fi
    if git -C "$project" branch -D "$branch" >/dev/null 2>&1; then
        echo "fork-sandbox lkml-summarize: deleted throwaway branch $branch." >&2
    else
        echo "Warning: throwaway branch '$branch' is still in $project and could not be deleted; delete it by hand." >&2
    fi
}

# launch_tier <tier> <spec> <handoff_file>: launches one tier on its
# own throwaway branch at the series' tip, waits for its summary.json
# (fork-sandbox.sh's own "the run, including its fetch, is fully over"
# signal), and leaves the run dir in $tier_run_dir.
launch_tier() {
    local tier="$1" spec="$2" handoff_file="$3"
    local branch task_meta launch_out rc run_dir waited
    branch="lkml/${series}-v${version}-summarize-${tier}-$(date +%s)"
    task_meta="$(jq -nc --arg series "$series" --arg tier "summarize-$tier" \
        '{kind:"summarize", tags:["lkml", $series, $tier]}')"
    echo "fork-sandbox lkml-summarize: launching $tier tier ($spec) on $branch..." >&2
    launch_out="$(fork-sandbox.sh --harness "$spec" --checkout "$checkout_branch" \
        --branch "$branch" --task-meta "$task_meta" "$project" "$handoff_file" 2>&1)"
    rc=$?
    run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
    if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
        echo "Error: launching the $tier tier failed:" >&2
        printf '%s\n' "$launch_out" >&2
        delete_branch "$branch"
        return 1
    fi
    echo "fork-sandbox lkml-summarize: $tier tier -> $run_dir" >&2
    # The same cost ledger lkml-round.sh and lkml-revise.sh append to,
    # so a series' summarize runs price into the same totals.
    jq -nc --arg persona "summarize-$tier" --arg run_dir "$run_dir" --arg kind summarize \
        '{persona:$persona, run_dir:$run_dir, kind:$kind}' >> "$series_dir/runs.jsonl"

    echo "fork-sandbox lkml-summarize: waiting up to ${timeout}s for the $tier tier's run to finish..." >&2
    waited=0
    while [[ ! -f "$run_dir/summary.json" ]]; do
        if (( waited >= timeout )); then
            echo "Error: timed out after ${timeout}s waiting for the $tier tier's run to finish." >&2
            delete_branch "$branch"
            return 1
        fi
        sleep 10
        waited=$(( waited + 10 ))
    done
    delete_branch "$branch"
    tier_run_dir="$run_dir"
    return 0
}

# The LOW tier's handoff: a persona-style brief, then the whole --text
# render inline -- the sandbox cannot read the mailbox, the same reason
# lkml-round.sh hands its secretary seat the thread.
build_low_handoff() {
    cat <<BRIEF
You are the EXTRACTION tier of a two-tier summary of the lkml-mode
review series $series, version $version.

You are handed the whole thread below, as the mailbox's own --text
render, inlined: this sandbox cannot read the mailbox. It covers every
posted version; THIS summary is about the section headed
"$series v$version" -- earlier versions are there as context for what
changed.

Read the whole thread, then write ONE file: \`results.json\` at the
root of the artifact outbox directory named in your prompt, shaped
like this:

    {
      "series": "$series",
      "version": $version,
      "cover": {
        "verdicts": {
          "<reviewer>": {
            "latest": { "tags": ["Reviewed-by"], "id": "9d67f5e" },
            "superseded": [ { "tags": ["NAK"], "id": "a1b2c3d" } ]
          }
        },
        "duplicates": [ { "ids": ["9d67f5e", "a1b2c3d"], "note": "same point raised twice" } ]
      },
      "patches": [
        {
          "subject": "[PATCH v$version 1/2] ...",
          "verdicts": { "...": "same shape as cover" },
          "defects": [
            { "severity": "high", "claim": "...", "file": "path", "line": 123,
              "status": "confirmed", "id": "9d67f5e" }
          ],
          "responses": [
            { "to": "9d67f5e", "stance": "accepted", "id": "b4c5d6e" }
          ],
          "open_questions": [
            { "question": "...", "asked_by": "core", "id": "9d67f5e" }
          ],
          "duplicates": [ "...same shape as cover" ]
        }
      ]
    }

The shape is a contract: a synthesis tier and a later render step
consume this JSON verbatim, so it must parse with jq and every field
must mean exactly what its name says:

- verdicts: per reviewer, the LATEST tag on this target is the current
  verdict; the tags its earlier messages on the same target carried,
  in thread order, go under superseded. Omit reviewers who never
  tagged.
- defects: every defect a reviewer claimed: severity (your read of its
  weight: high/medium/low), the claim in one sentence, file and line
  ONLY when the thread states them (omit otherwise), and status
  "confirmed" (someone verified it in the clone or by running the
  code) or "asserted" (claimed only, not verified).
- responses: for each defect or question the author answered, the
  stance "accepted" (fixed or conceded) or "pushed-back" (contested,
  with or without the reviewer's concession). A claim nobody answered
  gets stance "unanswered" and id null.
- open_questions: questions still standing -- tagged Question or
  simply never answered.
- duplicates: the same defect or question raised in more than one
  place (two reviewers, or one reviewer across versions).

Every single item carries the 7-hex message id(s) it comes from -- the
ids the render prints for each message. Record ONLY what the thread
states: do not review the code and do not invent findings.

Make NO commits and no other changes to the clone: writing
results.json to the outbox is the whole job. In your final report,
say how many patches you covered and how many defects you recorded.
BRIEF
    printf '\n## The thread (the mailbox --text render, all versions)\n\n'
    printf '%s\n' "$render_text"
}

# The HIGH tier's handoff: a persona-style brief, then the extraction
# intermediate verbatim and the tally section for this version.
build_high_handoff() {
    cat <<BRIEF
You are the SYNTHESIS tier of a two-tier summary of the lkml-mode
review series $series, version $version.

You are handed (1) the structured intermediate the extraction tier
pulled from the whole thread, verbatim, and (2) the thread's tally
section for v$version. The intermediate was built from the entire
--text render of the mailbox, and it should make a source-dive
unnecessary: you MAY read this clone to chase a lead, but start from
the intermediate, not from the code.

Write ONE file: \`results.md\` at the root of the artifact outbox
directory named in your prompt, EXACTLY this shape:

    # Summary
    <one or two short paragraphs>

    # Details
    <free-form subsections>

The # Summary section is a small collapsed card in the intended final
layout: at most about 120 words, hard-capped at 200. One or two short
paragraphs: the state of the series (how the tally stands), the
defects that still matter, and what happens next. Nothing else.

# Details is free-form subsections: a defect list with severity,
status and its message-id citation, a per-patch disposition, and
recommended next actions.

Cite message ids as BARE 7-hex tokens, for example 9d67f5e -- no
brackets, no anchors, no <id@lkml.local>: a plain convention, and it
keeps the id greppable against the thread.

Make NO commits and no other changes to the clone: writing
results.md to the outbox is the whole job. In your final report, say
how many words the Summary section is.
BRIEF
    printf '\n## The extraction intermediate (results-v%s.json, verbatim)\n\n' "$version"
    printf '%s\n' "$low_intermediate"
    printf '\n## The tally for v%s (from the --text render)\n\n' "$version"
    printf '%s\n' "$tally_text"
}

# The series run's handoff: a persona-style brief, then, in version
# order, each recorded version's extraction intermediate verbatim and
# its tally section, then the latest version's cover letter. The
# per-version intermediates are the message-level detail: the series
# run synthesizes the arc from them, not from the raw thread.
build_series_handoff() {
    local v i=0
    cat <<BRIEF
You are the SYNTHESIS run of a whole-series summary of the lkml-mode
review series $series, versions ${recorded_versions[0]} to $version.

You are handed (1) each recorded version's extraction intermediate
(results-v<N>.json), verbatim, in version order, (2) each version's
tally section from the thread's --text render, and (3) the cover
letter of the LATEST version (v$version), verbatim. The
intermediates were built from the entire --text render of the
mailbox, and they are the message-level detail: you MAY read this
clone to chase a lead, but start from them, not from the code.

Write ONE file: \`results.md\` at the root of the artifact outbox
directory named in your prompt, EXACTLY this shape:

    # Summary
    <two to three short paragraphs>

    # Details
    <one short paragraph per version, in version order>
    Open items
    <the latest version's standing items>
    Recommended next actions
    <for the latest version>

The # Summary is the deliverable: two to three short paragraphs,
about 150 words, hard cap 200, written as a brief to a maintainer
deciding whether to read further. Plain declarative sentences, no
bullet lists. It carries the whole story: what the series does (one
sentence, from the cover letter), the review arc (how many versions
were posted, what the review panel found at each version, what the
author changed in response -- from the intermediates and the
tallies), where the series stands now (the latest version's tally
state), and what happens next. Do NOT explain the review mechanism
(AI personas, sandboxes, how the review was run) -- the rendered
page's footer already carries that disclosure.

# Details is one short paragraph per version, in version order (v1:
posted N patches, the panel raised X, of which Y were confirmed; v2:
...), then "Open items" and "Recommended next actions" subsections
for the latest version.

Cite message ids as BARE 7-hex tokens, for example 9d67f5e -- no
brackets, no anchors, no <id@lkml.local>: a plain convention, and it
keeps the id greppable against the thread.

Make NO commits and no other changes to the clone: writing
results.md to the outbox is the whole job. In your final report, say
how many words the Summary section is.
BRIEF
    for v in "${recorded_versions[@]}"; do
        printf '\n## v%s: the extraction intermediate (results-v%s.json, verbatim)\n\n' "$v" "$v"
        cat -- "$series_dir/results-v${v}.json"
    done
    for v in "${recorded_versions[@]}"; do
        printf '\n## v%s: the tally section (from the --text render)\n\n' "$v"
        printf '%s\n' "${tallies[$i]}"
        i=$(( i + 1 ))
    done
    printf "\n## v%s: the cover letter (the section's first message, verbatim)\n\n" "$version"
    printf '%s\n' "$cover_text"
}

# The Summary section is a small collapsed card in the intended final
# layout, so an over-long Summary is worth a warning even though the
# file is written anyway.
warn_summary_length() {
    local path="$1" aim="$2" words
    words="$(awk '/^# Summary/ { f = 1; next } f && /^# / { exit } f' "$path" | wc -w | tr -d '[:space:]')"
    if [[ -n "$words" && "$words" -gt 200 ]]; then
        echo "Warning: the Summary section of $path is $words words; the Summary cap is ~200 (aim for ~$aim)." >&2
    fi
}

if [[ -n "$series_mode" ]]; then
    # One synthesis run, no extraction tier: the inputs are already on
    # disk per version, and the outbox's results.md is harvested as
    # results-series.md ONLY -- there is no json companion, the
    # per-version json/md pairs stay as they are.
    mkdir -p -- /var/tmp/claude-scratch
    series_handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-summarize-series-XXXXXX.md)" || {
        echo "Error: mktemp failed for the series run's handoff file." >&2
        exit 1
    }
    build_series_handoff > "$series_handoff_file"

    if ! launch_tier series "$high_spec" "$series_handoff_file"; then
        rm -f -- "$series_handoff_file"
        exit 1
    fi
    series_run_dir="$tier_run_dir"
    rm -f -- "$series_handoff_file"

    series_outbox_md="$series_run_dir/outbox/results.md"
    if [[ ! -f "$series_outbox_md" ]]; then
        echo "Error: the series run left no $series_outbox_md." >&2
        exit 1
    fi
    # Same empty/whitespace-only refusal as the per-version path: a run
    # that died after touching the outbox file leaves nothing to
    # harvest, and summing nothing is not a summary.
    if [[ -z "$(tr -d '[:space:]' < "$series_outbox_md")" ]]; then
        echo "Error: the series run left $series_outbox_md empty (or whitespace only); there is nothing to synthesize." >&2
        exit 1
    fi
    md_path="$series_dir/results-series.md"
    cp -f -- "$series_outbox_md" "$md_path"
    echo "fork-sandbox lkml-summarize: harvested $md_path" >&2
    warn_summary_length "$md_path" 150

    # The written path is the whole stdout of this script; everything
    # else went to stderr.
    printf '%s\n' "$md_path"
    exit 0
fi

json_path="$series_dir/results-v${version}.json"
md_path="$series_dir/results-v${version}.md"

mkdir -p -- /var/tmp/claude-scratch
low_handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-summarize-low-XXXXXX.md)" || {
    echo "Error: mktemp failed for the low tier's handoff file." >&2
    exit 1
}
build_low_handoff > "$low_handoff_file"

if ! launch_tier low "$low_spec" "$low_handoff_file"; then
    rm -f -- "$low_handoff_file"
    exit 1
fi
low_run_dir="$tier_run_dir"
rm -f -- "$low_handoff_file"

low_outbox_json="$low_run_dir/outbox/results.json"
if [[ ! -f "$low_outbox_json" ]]; then
    echo "Error: the low tier's run left no $low_outbox_json; there is no intermediate to synthesize." >&2
    exit 1
fi
# Empty (or whitespace only) is fatal, not a warning: a low tier that
# died after touching the outbox file leaves nothing to synthesize, and
# summing nothing is not a summary, so the expensive tier must not run
# on an empty intermediate. Unparseable-but-non-empty is a warning
# instead -- the synthesis tier reads it as text either way, and it is
# carried verbatim by contract.
if [[ -z "$(tr -d '[:space:]' < "$low_outbox_json")" ]]; then
    echo "Error: the low tier's run left $low_outbox_json empty (or whitespace only); there is nothing to synthesize." >&2
    exit 1
fi
if ! jq -e . "$low_outbox_json" >/dev/null 2>&1; then
    echo "Warning: $low_outbox_json is not parseable JSON; it will be harvested as $json_path and the synthesis tier will get it verbatim anyway." >&2
fi
low_intermediate="$(cat -- "$low_outbox_json")"

high_handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-summarize-high-XXXXXX.md)" || {
    echo "Error: mktemp failed for the high tier's handoff file." >&2
    exit 1
}
build_high_handoff > "$high_handoff_file"

if ! launch_tier high "$high_spec" "$high_handoff_file"; then
    rm -f -- "$high_handoff_file"
    exit 1
fi
high_run_dir="$tier_run_dir"
rm -f -- "$high_handoff_file"

high_outbox_md="$high_run_dir/outbox/results.md"
if [[ ! -f "$high_outbox_md" ]]; then
    echo "Error: the high tier's run left no $high_outbox_md." >&2
    exit 1
fi
# The json and md are a pair for THIS run: land the json only now,
# once the md is in hand, so a failed high run leaves the previous
# run's pair untouched instead of a fresh intermediate beside a stale
# md.
cp -f -- "$low_outbox_json" "$json_path"
echo "fork-sandbox lkml-summarize: harvested $json_path" >&2
cp -f -- "$high_outbox_md" "$md_path"
echo "fork-sandbox lkml-summarize: harvested $md_path" >&2
warn_summary_length "$md_path" 120

# The written paths are the whole stdout of this script; everything
# else went to stderr.
printf '%s\n' "$json_path" "$md_path"
