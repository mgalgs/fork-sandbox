#!/usr/bin/env bash
# lkml-series.sh — Re-roll an already-merged range into a reviewable series
#
# Usage: lkml-series.sh <series> --project <path> --range <base>..<tip>
#            [--author <persona>] [--parts <n>] [--hint <file>]
#            [--personas-dir <dir>] [--model-override <harness/model>]
#            [--timeout <seconds>]
#
# For post-hoc review of shipped work: <base>..<tip> already landed on
# main (or wherever), often as one merge commit or a pile of WIP commits
# that are not fit to post as a patch series. This launches the author
# persona once to recreate the SAME end state as thematic, individually
# reviewable commits, then format-patches that reconstruction as v1.
#
# --range     split on the FIRST ".." into <base> and <tip>. <base> is what
#             the reconstruction is diffed against and formatted from;
#             <tip> is the end state it must reproduce exactly.
# --parts     how many commits to split the range into. Optional -- the
#             author persona picks a sensible split (6-10) when omitted.
# --hint      a file with the operator's own suggested split (prose, a list
#             of themes, whatever) -- embedded in the handoff verbatim as a
#             suggestion, not a requirement the author must follow exactly.
# --author    which persona file speaks for the series. Defaults to
#             "author" -- see skills/lkml-mode/personas/author.md.
# --model-override <harness>[/<model>] overrides the author persona's own
#             harness/model for this run only. A BARE harness (no /model)
#             drops the persona's frontmatter model -- a model name belongs
#             to its harness (a bare pi-local resolves from the endpoint,
#             a bare claude takes the harness default); a combined
#             harness/model passes through verbatim. The frontmatter pins
#             are defaults, not policy: this machine's seats file
#             (LKML_SEATS_FILE, else ~/.config/fork-sandbox/lkml-seats.yaml)
#             may re-seat the persona, key by key -- precedence
#             --model-override > seats personas.<p> > seats default: >
#             frontmatter (a seats harness without a model drops the
#             frontmatter's model). A missing file means the pins stand;
#             an unreadable or unparseable one refuses the run before the
#             launch. A seat the seats file changes is announced on stderr,
#             e.g. `lkml-series: seat author: pi-local (lkml-seats.yaml,
#             was claude/opus)`; --model-override wins over the seats file
#             silently.
# --timeout   seconds to wait for the run to finish. Default 3600.
#
# Launches ONE fork-sandbox.sh run, --checkout at <tip>, on a new branch
# named lkml/<series>-v1-<timestamp>. The persona's clone has full history
# (fork-sandbox.sh clones with --shared, never shallow), so <base> is
# reachable there even though the run starts checked out at <tip>. The
# handoff tells it to reset the branch to start at <base> and recreate the
# full <base>..<tip> diff as --parts (or its own judgement) thematic
# commits, each a real commit message -- then verify itself with
# `git diff <tip> HEAD`, which must print nothing.
#
# After the run: waits for summary.json, then verifies IN THE REAL REPO
# (never trusting the persona's own self-report) that the fetched branch's
# tree is byte-identical to <tip>'s -- `git diff --quiet <tip> <branch>`.
# A mismatch refuses outright and names the branch for manual inspection;
# nothing is format-patched. A match is `git format-patch <base>..<branch>`
# into <series>/patches-v1/, ready for `lkml-cover.sh` to post as v1 (this
# script does not call `lkml-mailbox.sh init` itself -- writing the cover
# letter is lkml-cover.sh's job).
#
# On success, appends {"version": 1, "branch": "<branch>"} to
# <series>/versions.jsonl -- the version-to-branch ledger lkml-forklift.sh
# reads to find a version's branch without guessing its timestamp.
# lkml-revise.sh appends the same shape for vN+1 after its own successful
# post.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
default_personas_dir="$(cd "$script_dir/.." && pwd)/skills/lkml-mode/personas"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

series="${1:?Usage: lkml-series.sh <series> --project <path> --range <base>..<tip>}"
shift

project=""
range=""
author_persona="author"
parts=""
hint_file=""
personas_dir="$default_personas_dir"
model_override=""
timeout=3600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --range) range="${2:?--range requires <base>..<tip>}"; shift 2 ;;
        --author) author_persona="${2:?--author requires a persona name}"; shift 2 ;;
        --parts) parts="${2:?--parts requires a number}"; shift 2 ;;
        --hint) hint_file="${2:?--hint requires a file}"; shift 2 ;;
        --personas-dir) personas_dir="${2:?--personas-dir requires a directory}"; shift 2 ;;
        --model-override) model_override="${2:?--model-override requires harness or harness/model}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
[[ -n "$range" ]] || { echo "Error: --range is required, e.g. --range main~20..main." >&2; exit 1; }
[[ "$range" == *..* ]] || { echo "Error: --range must contain '..', e.g. <base>..<tip>." >&2; exit 1; }
base_ref="${range%%..*}"
tip_ref="${range#*..}"
[[ -n "$base_ref" ]] || { echo "Error: --range '$range' has an empty base before '..'." >&2; exit 1; }
[[ -n "$tip_ref" ]] || { echo "Error: --range '$range' has an empty tip after '..'." >&2; exit 1; }
if [[ -n "$parts" ]]; then
    [[ "$parts" =~ ^[0-9]+$ && "$parts" -gt 0 ]] || { echo "Error: --parts must be a positive integer." >&2; exit 1; }
fi
if [[ -n "$hint_file" ]]; then
    [[ -f "$hint_file" ]] || { echo "Error: --hint file '$hint_file' not found." >&2; exit 1; }
fi
[[ -d "$personas_dir" ]] || { echo "Error: --personas-dir '$personas_dir' not found." >&2; exit 1; }
command -v fork-sandbox.sh >/dev/null 2>&1 || { echo "Error: fork-sandbox.sh not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

persona_file="$personas_dir/$author_persona.md"
[[ -f "$persona_file" ]] || { echo "Error: no persona file '$persona_file'." >&2; exit 1; }

# Identical convention to lkml-round.sh's and lkml-revise.sh's own copies --
# see lkml-revise.sh's comment for why this stays duplicated rather than
# sourced.
lkml_persona_field() {
    local file="$1" key="$2"
    awk -v k="$key" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { exit }
        infm && $0 ~ "^"k": " { sub("^"k": *", ""); print; exit }
    ' "$file"
}

harness="$(lkml_persona_field "$persona_file" harness)"
model="$(lkml_persona_field "$persona_file" model)"
thinking="$(lkml_persona_field "$persona_file" thinking)"
display="$(lkml_persona_field "$persona_file" display)"
[[ -n "$harness" ]] || harness="claude"
[[ -n "$display" ]] || display="$author_persona"
if [[ -n "$model_override" ]]; then
    if [[ "$model_override" == */* ]]; then
        harness="${model_override%%/*}"
        model="${model_override#*/}"
    else
        # Bare harness: the persona's frontmatter model is DROPPED, not
        # composed onto the bare harness -- pi-local/opus asks the endpoint
        # for a model named 'opus' and the leg dies with zero replies (the
        # --model-override 404 lesson; a seats-file harness without a model
        # drops it the same way).
        harness="$model_override"
        model=""
    fi
else
    # The seats file re-seats this persona, key by key; the frontmatter
    # values are the lowest-priority inputs (lkml-seats-resolve owns the
    # precedence). Single launch, no prior work to protect, so a bad seats
    # file refuses here rather than in a pre-check.
    {
        read -r harness
        read -r model
        read -r thinking
        read -r seat_note
    } < <(
        "$script_dir/lkml-seats-resolve" resolve "$personas_dir" "$author_persona" \
            "$harness" "$model" "$thinking")
    [[ -n "$harness" ]] || {
        echo "Error: seats resolution for $author_persona failed." >&2
        exit 1
    }
    [[ -n "$seat_note" ]] && echo "fork-sandbox lkml-series: $seat_note" >&2
fi

parts_text="your own call -- a sensible split is usually 6 to 10 commits"
[[ -n "$parts" ]] && parts_text="exactly $parts commits"

mkdir -p -- /var/tmp/claude-scratch
handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-series-XXXXXX.md)" || {
    echo "Error: mktemp failed for the handoff file." >&2
    exit 1
}
{
    cat -- "$persona_file"
    printf '\n---\n\n# You are re-rolling %s into a reviewable series\n\n' "$series"
    cat <<TASK
This range already shipped -- it is being reviewed AFTER THE FACT, not
before merge. Your job is not to change what it does; it is to recreate
the SAME end state as a sequence of thematic, individually reviewable
commits, so a panel can review it the way it would have before merge.

Your clone is checked out on a new branch that currently starts at the
range's TIP ($tip_ref), with full history, so the range's BASE
($base_ref) is reachable in this same clone.

1. Reset this branch to start at the base:

       git reset --hard $base_ref

   (or any equivalent that leaves this branch's tip at $base_ref with a
   clean working tree).

2. Recreate the full diff between $base_ref and $tip_ref
   (\`git diff $base_ref $tip_ref\` in this same clone -- both are
   reachable here) as $parts_text, each with a real, honest commit
   message describing that piece alone.

3. Before you finish, verify yourself:

       git diff $tip_ref HEAD

   This MUST print nothing -- your reconstruction must be byte-identical
   to the original tip's tree, just split into a better commit history.
   If it prints anything, fix your commits until it does not. The host
   side of this script re-checks this same thing in the real repo and
   refuses to post anything if it disagrees with you.

Do not use this as a chance to fix bugs, refactor further, or otherwise
change behavior -- that is what the review round after this is for. This
step is purely about presenting the same change as a better history.
TASK
    if [[ -n "$hint_file" ]]; then
        printf '\n## The operator'"'"'s suggested split\n\n%s\n' "$(cat -- "$hint_file")"
        printf '\nTreat this as a suggestion, not a requirement -- deviate if the\n'
        printf 'actual diff splits more naturally some other way.\n'
    fi
} > "$handoff_file"

branch="lkml/${series}-v1-$(date +%s)"
task_meta="$(jq -nc --arg series "$series" --arg persona "$author_persona" \
    '{kind:"implement", tags:["lkml", $series, $persona]}')"

harness_spec="$harness"
[[ -n "$model" ]] && harness_spec="$harness/$model"

# Same rule as lkml-round.sh: the `thinking:` seat fact only means
# something on a harness that starts pi; fork-sandbox.sh refuses
# --pi-args elsewhere, so it is dropped for claude and codex -- and so
# is its launch-line mention, which would announce a no-op.
pi_args=()
thinking_note=""
if [[ -n "$thinking" && ( "$harness" == "pi" || "$harness" == "pi-local" ) ]]; then
    pi_args=(--pi-args "--thinking $thinking")
    thinking_note=", thinking $thinking"
fi

echo "fork-sandbox lkml-series: launching $author_persona ($harness_spec$thinking_note) for v1..." >&2
launch_out="$(fork-sandbox.sh --harness "$harness_spec" --checkout "$tip_ref" \
    "${pi_args[@]}" \
    --branch "$branch" --task-meta "$task_meta" "$project" "$handoff_file" 2>&1)"
rc=$?
run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
    echo "Error: launch failed:" >&2
    printf '%s\n' "$launch_out" >&2
    exit 1
fi
echo "fork-sandbox lkml-series: $run_dir" >&2

ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
mkdir -p -- "$ledger_root/$series"
jq -nc --arg persona "$author_persona" --arg run_dir "$run_dir" --arg kind implement \
    '{persona:$persona, run_dir:$run_dir, kind:$kind}' >> "$ledger_root/$series/runs.jsonl"

echo "fork-sandbox lkml-series: waiting up to ${timeout}s..." >&2
waited=0
while [[ ! -f "$run_dir/summary.json" ]]; do
    if (( waited >= timeout )); then
        echo "Error: timed out after ${timeout}s waiting for the run to finish." >&2
        exit 1
    fi
    sleep 10
    waited=$(( waited + 10 ))
done

real_branch="$(jq -r '.branch' "$run_dir/summary.json")"
commits="$(jq -r '.commits' "$run_dir/summary.json")"
fetched="$(jq -r '.fetched' "$run_dir/summary.json")"

if [[ "$commits" == "0" || "$fetched" != "true" ]]; then
    echo "Error: the run made no commits (or was not fetched back) -- there is" >&2
    echo "nothing to format-patch. Read the run's own report by hand." >&2
    exit 1
fi

real_repo="$(git -C "$project" rev-parse --show-toplevel)"
tip_sha="$(cd "$real_repo" && git rev-parse --verify --quiet "${tip_ref}^{commit}")" || {
    echo "Error: --range's tip '$tip_ref' does not name a commit in $real_repo." >&2
    exit 1
}
base_sha="$(cd "$real_repo" && git rev-parse --verify --quiet "${base_ref}^{commit}")" || {
    echo "Error: --range's base '$base_ref' does not name a commit in $real_repo." >&2
    exit 1
}

if ! (cd "$real_repo" && git diff --quiet "$tip_sha" "$real_branch"); then
    echo "Error: the reconstruction on branch '$real_branch' does not match" >&2
    echo "$tip_ref's tree. Refusing to format-patch a series that changes" >&2
    echo "behavior from what actually shipped. Inspect the branch by hand:" >&2
    echo "  git diff $tip_ref $real_branch" >&2
    exit 1
fi
echo "fork-sandbox lkml-series: reconstruction on '$real_branch' matches $tip_ref exactly." >&2

patch_dir="$ledger_root/$series/patches-v1"
mkdir -p -- "$patch_dir"
rm -f -- "$patch_dir"/*.patch
if ! (cd "$real_repo" && git format-patch --quiet -o "$patch_dir" "$base_sha..$real_branch") >/dev/null; then
    echo "Error: git format-patch failed for $base_sha..$real_branch in $real_repo." >&2
    exit 1
fi
n_patches="$(find "$patch_dir" -maxdepth 1 -name '*.patch' | wc -l | tr -d '[:space:]')"

jq -nc --argjson version 1 --arg branch "$real_branch" '{version:$version, branch:$branch}' \
    >> "$ledger_root/$series/versions.jsonl"

echo "fork-sandbox lkml-series: branch '$real_branch', $n_patches patch(es) in $patch_dir" >&2
