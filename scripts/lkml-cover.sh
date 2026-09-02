#!/usr/bin/env bash
# lkml-cover.sh — Launch the author persona to write a cover letter for
# patches that already exist (e.g. lkml-series.sh's reconstruction), then
# post the version via lkml-mailbox.sh init.
#
# Usage: lkml-cover.sh <series> --project <path> --checkout <branch> --base <base>
#            --patches <dir> [--attach <file>]... [--smoke <file>] [--narrative <file>]
#            [--author <persona>] [--version <n>] [--personas-dir <dir>]
#            [--model-override <harness/model>] [--timeout <seconds>]
#
# <project>    the repo fork-sandbox.sh clones.
# --checkout   the branch the patches already live on -- e.g. the branch
#              lkml-series.sh's reconstruction landed on, or vN's branch
#              you are re-covering. This run makes NO commits, so nothing
#              is fetched back; --checkout only gives the author persona
#              something to read (git log/diff) while writing the cover
#              letter, and doubles as the version's branch recorded in
#              versions.jsonl (see below).
# --base       the base the patches were formatted against -- used both to
#              tell the author `git diff <base>...HEAD` and, on the host
#              side, to compute the `## Diffstat` section (see below).
# --patches    a `git format-patch` output directory, e.g. lkml-series.sh's
#              own patches-v1/. Its *.patch files are embedded as text
#              directly into the handoff -- NOT bound in with --context-ro
#              (which requires a directory under
#              /var/tmp/claude-scratch/forks/, which $LKML_MAILBOX_ROOT is
#              not by default) and not copied into .git/lkml-in/ (the
#              clone does not exist yet when this script builds the
#              handoff) -- same reasoning as lkml-round.sh embedding
#              `cover`/`tree` text straight into its own handoff.
# --attach     may repeat. Each file is passed through to `lkml-mailbox.sh
#              init --attach` AND described in a `## Attachments` section
#              this script appends to the cover letter itself (see below).
# --smoke      a file whose content becomes the cover's `## Test results`
#              section, appended by `lkml-mailbox.sh init --smoke`.
# --narrative  a file with the operator's own words for what this work is
#              for. Embedded verbatim into the handoff; the author is told
#              to open its cover with this, lightly edited, and never
#              contradict it.
# --author     which persona file speaks for the series. Defaults to
#              "author".
# --version    version to post as. Defaults to one past the series'
#              current highest version (the same default `lkml-mailbox.sh
#              init` applies on its own).
# --personas-dir defaults to skills/lkml-mode/personas beside this repo's
#              own scripts/ directory.
# --model-override <harness>[/<model>] overrides the author persona's own
#              harness/model for this run only. A BARE harness (no /model)
#              drops the persona's frontmatter model -- a model name belongs
#              to its harness (a bare pi-local resolves from the endpoint,
#              a bare claude takes the harness default); a combined
#              harness/model passes through verbatim. The frontmatter pins
#              are defaults, not policy: this machine's seats file
#              (LKML_SEATS_FILE, else ~/.config/fork-sandbox/lkml-seats.yaml)
#              may re-seat the persona, key by key -- precedence
#              --model-override > seats personas.<p> > seats default: >
#              frontmatter (a seats harness without a model drops the
#              frontmatter's model). A missing file means the pins stand;
#              an unreadable or unparseable one refuses the run before the
#              launch. A seat the seats file changes is announced on stderr,
#              e.g. `lkml-cover: seat author: pi-local (lkml-seats.yaml, was
#              claude/opus)`; --model-override wins over the seats file
#              silently.
# --timeout    seconds to wait for the run to finish. Default 3600.
#
# This run is NOT allowed to make commits -- same convention as
# lkml-round.sh's reviewer runs. The handoff hands it the patches (embedded
# as text) and the operator's narrative (if any), and asks for exactly
# three sections, written to .git/lkml-out/cover-letter.md: a narrative,
# an implementation overview (one paragraph per patch, in series order),
# and what to look at first (3 places the author is least sure of) --
# prefaced by an AI-attribution paragraph the author writes itself, in its
# own words (see SKILL.md's "Attribution is non-negotiable"). Under
# .git/, not the working tree, for the same "commit early and often
# cannot sweep it up" reason every other lkml-mode handoff uses this
# convention for.
#
# After the run: waits for summary.json, refuses clearly if no
# cover-letter.md was written, then:
#
#   1. Appends a `## Attachments` section (one `Attachment: attachments/
#      <basename> — <n> bytes` line per --attach file) onto a COPY of the
#      author's cover-letter.md -- never the clone's own file.
#   2. Calls `(cd "$project" && lkml-mailbox.sh init ... --diffstat
#      "$base..$checkout" ${smoke:+--smoke "$smoke"} --attach ...)`, which
#      appends `## Diffstat` and, if --smoke was given, `## Test results`
#      after that.
#
# Final section order is therefore: the author's 3 sections, then
# Attachments, then Diffstat, then Test results -- not the attachments/
# diffstat/test-results top-to-bottom order a reader might expect, a
# consequence of lkml-mailbox.sh init posting immediately rather than
# returning a body for further editing.
#
# On success, appends {"version": <n>, "branch": "<checkout>"} to
# <series>/versions.jsonl, the same ledger lkml-series.sh/lkml-revise.sh
# write -- the branch given via --checkout IS the version's branch here,
# since this run makes no commits and the branch already exists in the
# real repo from lkml-series.sh or lkml-revise.sh.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"
default_personas_dir="$(cd "$script_dir/.." && pwd)/skills/lkml-mode/personas"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

series="${1:?Usage: lkml-cover.sh <series> --project <path> --checkout <branch> --base <base> --patches <dir>}"
shift

project=""
checkout_ref=""
base_ref=""
patches_dir=""
smoke_file=""
narrative_file=""
author_persona="author"
version=""
personas_dir="$default_personas_dir"
model_override=""
timeout=3600
attach_files=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --checkout) checkout_ref="${2:?--checkout requires a ref}"; shift 2 ;;
        --base) base_ref="${2:?--base requires a ref}"; shift 2 ;;
        --patches) patches_dir="${2:?--patches requires a directory}"; shift 2 ;;
        --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
        --smoke) smoke_file="${2:?--smoke requires a file}"; shift 2 ;;
        --narrative) narrative_file="${2:?--narrative requires a file}"; shift 2 ;;
        --author) author_persona="${2:?--author requires a persona name}"; shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --personas-dir) personas_dir="${2:?--personas-dir requires a directory}"; shift 2 ;;
        --model-override) model_override="${2:?--model-override requires harness or harness/model}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
[[ -n "$checkout_ref" ]] || { echo "Error: --checkout is required." >&2; exit 1; }
[[ -n "$base_ref" ]] || { echo "Error: --base is required." >&2; exit 1; }
[[ -n "$patches_dir" ]] || { echo "Error: --patches is required." >&2; exit 1; }
if [[ -n "$version" ]]; then
    [[ "$version" =~ ^[0-9]+$ ]] || { echo "Error: --version must be a plain integer." >&2; exit 1; }
fi
command -v fork-sandbox.sh >/dev/null 2>&1 || { echo "Error: fork-sandbox.sh not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

# Resolved up front, before the persona launch below, so a bad --base
# refuses in seconds instead of after an up-to-3600s run -- --base's only
# other use is inside the handoff text itself (a ref name, never resolved
# there), so nothing before this needs $real_repo.
real_repo="$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: '$project' is not inside a git repository." >&2
    exit 1
}
git -C "$real_repo" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null || {
    echo "Error: --base '$base_ref' does not name a commit in $real_repo." >&2
    exit 1
}

# Every path handed to the eventual `(cd "$real_repo" && "$mailbox" init
# ...)` call must already be absolute, since that call changes directory
# first -- resolved right after argument parsing, before anything else
# touches these paths, per the design note above.
patches_dir="$(readlink -f -- "$patches_dir" 2>/dev/null)" || { echo "Error: --patches directory not found." >&2; exit 1; }
[[ -d "$patches_dir" ]] || { echo "Error: --patches directory '$patches_dir' not found." >&2; exit 1; }
if [[ -n "$smoke_file" ]]; then
    smoke_file="$(readlink -f -- "$smoke_file" 2>/dev/null)" || { echo "Error: --smoke file not found." >&2; exit 1; }
    [[ -f "$smoke_file" ]] || { echo "Error: --smoke file '$smoke_file' not found." >&2; exit 1; }
fi
if [[ -n "$narrative_file" ]]; then
    narrative_file="$(readlink -f -- "$narrative_file" 2>/dev/null)" || { echo "Error: --narrative file not found." >&2; exit 1; }
    [[ -f "$narrative_file" ]] || { echo "Error: --narrative file '$narrative_file' not found." >&2; exit 1; }
fi
if (( ${#attach_files[@]} > 0 )); then
    resolved=()
    for f in "${attach_files[@]}"; do
        rf="$(readlink -f -- "$f" 2>/dev/null)" || { echo "Error: --attach file '$f' not found." >&2; exit 1; }
        [[ -f "$rf" ]] || { echo "Error: --attach file '$f' not found." >&2; exit 1; }
        resolved+=("$rf")
    done
    attach_files=("${resolved[@]}")
fi

[[ -d "$personas_dir" ]] || { echo "Error: --personas-dir '$personas_dir' not found." >&2; exit 1; }
persona_file="$personas_dir/$author_persona.md"
[[ -f "$persona_file" ]] || { echo "Error: no persona file '$persona_file'." >&2; exit 1; }

# Identical convention to lkml-round.sh's/lkml-revise.sh's/lkml-series.sh's
# own copies -- see lkml-revise.sh's comment for why this stays duplicated
# rather than sourced.
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
    [[ -n "$seat_note" ]] && echo "fork-sandbox lkml-cover: $seat_note" >&2
fi

patch_files=()
while IFS= read -r f; do
    patch_files+=("$f")
done < <(find "$patches_dir" -maxdepth 1 -type f -name '*.patch' | sort)
(( ${#patch_files[@]} > 0 )) || { echo "Error: no *.patch files found in '$patches_dir'." >&2; exit 1; }

mkdir -p -- /var/tmp/claude-scratch
handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-cover-XXXXXX.md)" || {
    echo "Error: mktemp failed for the handoff file." >&2
    exit 1
}
{
    cat -- "$persona_file"
    printf '\n---\n\n# You are writing the cover letter for %s\n\n' "$series"
    printf 'This run makes NO commits -- writing the cover letter is the whole\n'
    printf 'job. Your checkout is already at %s, with the patches below applied\n' "$checkout_ref"
    printf 'on top of %s -- read the actual diff in your own clone if you want\n' "$base_ref"
    printf 'more context than the embedded patches give you:\n\n'
    printf '    git log %s..HEAD\n    git diff %s...HEAD\n\n' "$base_ref" "$base_ref"
    printf '## The patches, already applied to your checkout\n\n'
    for pf in "${patch_files[@]}"; do
        # shellcheck disable=SC2016  # literal markdown code-fence backticks, not command substitution
        printf '### %s\n\n```\n%s\n```\n\n' "$(basename -- "$pf")" "$(cat -- "$pf")"
    done
    if [[ -n "$narrative_file" ]]; then
        printf '## The operator'"'"'s own words for what this is for\n\n'
        printf 'Open your cover with this, lightly edited -- never contradict it:\n\n'
        printf '%s\n\n' "$(cat -- "$narrative_file")"
    fi
    cat <<'RULES'
## What to write

Write exactly three sections, after an AI-attribution paragraph you write
yourself, in your own words, stating plainly that every participant in
this series' review is an AI persona run in a sandbox:

1. **Narrative** -- what this is and why it exists (informed by the
   operator's own words above, when given).
2. **Implementation overview** -- one paragraph per patch, in series
   order.
3. **What to look at first** -- the 3 places you are least sure of.

Write it to:

    .git/lkml-out/cover-letter.md

Under `.git/`, not the working tree: git tracks nothing there, so it
cannot end up staged or committed by accident.

The FIRST LINE becomes the mailbox Subject verbatim, so write it as a
plain, short sentence -- no markdown heading marker.

Make no commits and no other repository changes. Writing
`.git/lkml-out/cover-letter.md` is the whole job this run.
RULES
} > "$handoff_file"

branch="lkml/${series}-cover-$(date +%s)"
task_meta="$(jq -nc --arg series "$series" --arg persona "$author_persona" \
    '{kind:"docs", tags:["lkml", $series, $persona]}')"

harness_spec="$harness"
[[ -n "$model" ]] && harness_spec="$harness/$model"

# Same rule as lkml-round.sh: the `thinking:` seat fact only means
# something on a harness that starts pi; fork-sandbox.sh refuses
# --pi-args elsewhere, so it is dropped for claude and codex.
pi_args=()
if [[ -n "$thinking" && ( "$harness" == "pi" || "$harness" == "pi-local" ) ]]; then
    pi_args=(--pi-args "--thinking $thinking")
fi

echo "fork-sandbox lkml-cover: launching $author_persona ($harness_spec${thinking:+, thinking $thinking})..." >&2
launch_out="$(fork-sandbox.sh --harness "$harness_spec" --checkout "$checkout_ref" \
    "${pi_args[@]}" \
    --branch "$branch" --task-meta "$task_meta" "$project" "$handoff_file" 2>&1)"
rc=$?
run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
    echo "Error: launch failed:" >&2
    printf '%s\n' "$launch_out" >&2
    exit 1
fi
echo "fork-sandbox lkml-cover: $run_dir" >&2

ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
mkdir -p -- "$ledger_root/$series"
jq -nc --arg persona "$author_persona" --arg run_dir "$run_dir" --arg kind docs \
    '{persona:$persona, run_dir:$run_dir, kind:$kind}' >> "$ledger_root/$series/runs.jsonl"

echo "fork-sandbox lkml-cover: waiting up to ${timeout}s..." >&2
waited=0
while [[ ! -f "$run_dir/summary.json" ]]; do
    if (( waited >= timeout )); then
        echo "Error: timed out after ${timeout}s waiting for the run to finish." >&2
        exit 1
    fi
    sleep 10
    waited=$(( waited + 10 ))
done

clone_dir="$(jq -r '.clone_dir' "$run_dir/summary.json")"
cover_file="$clone_dir/.git/lkml-out/cover-letter.md"
if [[ ! -f "$cover_file" ]]; then
    echo "Error: the run left no $cover_file -- refusing to post with no" >&2
    echo "cover letter. Read the run's own report by hand: $run_dir" >&2
    exit 1
fi

completed_dir="$(mktemp -d /var/tmp/claude-scratch/lkml-cover-completed-XXXXXX)" || {
    echo "Error: mktemp -d failed for the completed cover letter." >&2
    exit 1
}
completed_cover="$completed_dir/cover-letter.md"
cp -- "$cover_file" "$completed_cover"

if (( ${#attach_files[@]} > 0 )); then
    {
        printf '\n## Attachments\n\n'
        for f in "${attach_files[@]}"; do
            size="$(wc -c < "$f" | tr -d '[:space:]')"
            printf 'Attachment: attachments/%s — %s bytes\n' "$(basename -- "$f")" "$size"
        done
    } >> "$completed_cover"
fi

# A bare pi-local seat names no model -- the endpoint picks one -- and
# the posted cover would otherwise be stamped with an empty model: the
# run's summary records what the endpoint actually served (same fallback
# as lkml-round.sh's harvest).
[[ -n "$model" ]] || model="$(jq -r '.model // empty' "$run_dir/summary.json" 2>/dev/null || true)"
[[ -n "$model" ]] || model="unknown"

init_args=(init "$series" --cover "$completed_cover" --patches "$patches_dir" \
    --from "$author_persona" --display "$display" --harness "$harness" --model "$model" \
    --diffstat "$base_ref..$checkout_ref")
[[ -n "$version" ]] && init_args+=(--version "$version")
[[ -n "$smoke_file" ]] && init_args+=(--smoke "$smoke_file")
for f in "${attach_files[@]}"; do
    init_args+=(--attach "$f")
done

cover_id="$(cd "$real_repo" && "$mailbox" "${init_args[@]}")" || {
    echo "Error: lkml-mailbox.sh init failed. The cover letter it would have" >&2
    echo "posted is still at $completed_cover (run dir: $run_dir, clone:" >&2
    echo "$clone_dir) -- salvage it by hand." >&2
    exit 1
}
rm -rf -- "$completed_dir"

posted_version="$version"
if [[ -z "$posted_version" ]]; then
    posted_version="$("$mailbox" show "$series" "$cover_id" 2>/dev/null | sed -n 's/^X-Version: //p')"
fi
echo "fork-sandbox lkml-cover: posted v$posted_version, cover ${cover_id:0:7}." >&2

jq -nc --argjson version "$posted_version" --arg branch "$checkout_ref" \
    '{version:$version, branch:$branch}' >> "$ledger_root/$series/versions.jsonl"
