#!/usr/bin/env bash
# lkml-forklift.sh — Fold a reviewed version's delta back onto a real branch
#
# Usage: lkml-forklift.sh <series> --project <path> --version <n> --onto <ref> [--dry-run]
#
# <series>    the lkml-mode series whose reviewed version is being folded in.
# --project   the operator's real repo (not a persona's clone -- this script
#             never launches fork-sandbox.sh, runs no persona, and touches
#             ONLY --project's own git state).
# --version   which version's branch (looked up from <series>/versions.jsonl,
#             the LAST entry for that version wins) to fold onto --onto.
# --onto      a LOCAL branch name in --project ("refs/heads/<onto>" must
#             already exist) -- forklift moves this branch's ref forward by
#             one commit; it never floats on a bare ref/tag/sha.
# --dry-run   compute and print everything (diffstat, commit message) but
#             create no commit and move no ref.
#
# Refuses outright, before touching anything, if: --project has a dirty
# working tree (git status --porcelain is non-empty); --onto does not name
# a local branch; the version's branch does not resolve, either because
# versions.jsonl has no entry for it or because the branch itself no longer
# exists in --project.
#
# The fold is computed via plumbing, not `git cherry-pick`/`git rebase`,
# because the version's branch is NOT based on --onto's CURRENT tip -- it is
# a series reviewed on top of whatever --project looked like when
# lkml-series.sh (or an earlier lkml-forklift.sh run) branched it off, which
# can be arbitrarily far from --onto's current tip by the time review
# converges. Folding must therefore apply only the version's OWN delta (what
# changed between where it forked and its own tip), not the whole
# onto-vs-branch diff -- the latter would also include, in reverse, whatever
# --onto picked up on its own since the fork point:
#
#   1. `git merge-base <onto> <branch>` -- the commit the version's branch
#      actually forked from, however far back that is.
#   2. `git merge-tree --write-tree --merge-base=<that commit> <onto>
#      <branch>` -- a real three-way merge of --onto's CURRENT tip with the
#      version's tip, computed entirely in-memory (no index, no working
#      tree touched). Exit 0 means a clean merge and its tree is the fold
#      result; any change --onto picked up since the fork point survives
#      alongside the version's own changes. Exit nonzero means the two
#      genuinely conflict -- something --onto did since the fork point
#      touches the same lines the version touched -- and this refuses
#      outright ("has moved too far for a clean fold") with `git
#      merge-tree`'s own conflict markers/messages, leaving nothing applied
#      and moving no ref.
#   3. On success: commit-tree the merged tree with <onto>'s ORIGINAL commit
#      as the sole parent, and move refs/heads/<onto> to the new commit with
#      a compare-and-swap update-ref (so a concurrent mutation of <onto>
#      between steps 1 and 3 is caught, not silently overwritten). If
#      --project's HEAD is <onto>, also `reset --hard` the working tree to
#      match -- this script does not push, and does not run the tests on
#      the result; the operator does both by hand.
#
# The commit message: a subject naming the series/version/onto, the
# version's own cover letter's first line, `lkml-mailbox.sh tally --version
# <n>` verbatim under a "Tally (vN):" heading, and -- for v2 and later -- a
# "Changelog:" section concatenating every respin's own Changelog section
# (v2..vN), each labelled "vK:", extracted from that version's cover letter
# (case-insensitively matched "## Changelog" or similar, up to but not
# including the next heading line -- so a cover letter's own "## Diffstat"/
# "## Test results" sections, appended by `lkml-mailbox.sh init
# --diffstat`/`--smoke`, never get swallowed into the changelog; a cover
# with no Changelog heading at all contributes its whole body instead, with
# a warning on stderr -- this script only ever WARNS about a missing
# changelog, it never refuses over one).

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

# --help must be scanned over "$@" before the positional <series> is
# consumed: a bare `--help` would otherwise bind to <series> and die on
# the required-flag validation before the flag loop ever sees it.
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

series="${1:?Usage: lkml-forklift.sh <series> --project <path> --version <n> --onto <ref>}"
shift

project=""
version=""
onto=""
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --onto) onto="${2:?--onto requires a ref}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
[[ -n "$version" ]] || { echo "Error: --version is required." >&2; exit 1; }
[[ "$version" =~ ^[0-9]+$ ]] || { echo "Error: --version must be a plain integer." >&2; exit 1; }
[[ -n "$onto" ]] || { echo "Error: --onto is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

real_repo="$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: '$project' is not inside a git repository." >&2
    exit 1
}

if [[ -n "$(git -C "$real_repo" status --porcelain)" ]]; then
    echo "Error: '$real_repo' has a dirty working tree. Commit or stash first." >&2
    exit 1
fi

git -C "$real_repo" show-ref --verify --quiet "refs/heads/$onto" || {
    echo "Error: --onto '$onto' does not name a local branch in $real_repo." >&2
    exit 1
}
onto_sha="$(git -C "$real_repo" rev-parse --verify --quiet "$onto^{commit}")" || {
    echo "Error: --onto '$onto' does not resolve to a commit." >&2
    exit 1
}

ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
versions_file="$ledger_root/$series/versions.jsonl"
[[ -f "$versions_file" ]] || {
    echo "Error: no $versions_file -- run lkml-series.sh or lkml-revise.sh first." >&2
    exit 1
}
branch="$(jq -rs --argjson v "$version" \
    'map(select(.version==$v)) | if length==0 then empty else last.branch end' \
    "$versions_file")"
[[ -n "$branch" ]] || {
    echo "Error: no entry for version $version in $versions_file." >&2
    exit 1
}
git -C "$real_repo" rev-parse --verify --quiet "${branch}^{commit}" >/dev/null || {
    echo "Error: version $version's branch '$branch' does not resolve in $real_repo." >&2
    exit 1
}

echo "fork-sandbox lkml-forklift: folding v$version ($branch) onto $onto..." >&2
git -C "$real_repo" diff --stat "$onto" "$branch"

fork_point="$(git -C "$real_repo" merge-base "$onto" "$branch")" || {
    echo "Error: $onto and v$version's branch '$branch' share no common history." >&2
    exit 1
}

merge_out="$(git -C "$real_repo" merge-tree --write-tree --merge-base="$fork_point" "$onto" "$branch" 2>&1)"
merge_rc=$?
if (( merge_rc != 0 )); then
    echo "Error: v$version's branch '$branch' conflicts with $onto -- $onto has" >&2
    echo "moved too far (or touches the same lines the version touched) for a" >&2
    echo "clean fold. git merge-tree said:" >&2
    printf '%s\n' "$merge_out" >&2
    echo "Inspect by hand: git merge-tree --merge-base=$fork_point $onto $branch" >&2
    exit 1
fi
new_tree="$(printf '%s\n' "$merge_out" | head -n1)"

# Same convention every other lkml-mode script uses for the persona
# frontmatter fields -- see lkml-revise.sh's comment for why this stays
# duplicated rather than sourced. Here it walks `tree`'s own text output
# instead of a persona file: the cover's 7-char id is the first
# non-indented (depth-0) line right after that version's "=== vK ==="
# header.
cover_id_for_version() {
    local v="$1"
    "$mailbox" tree "$series" | awk -v hdr="=== v$v ===" '
        $0 == hdr { found = 1; next }
        found && /^=== / { exit }
        found && /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]  / { print $1; exit }
    '
}

this_cover_id="$(cover_id_for_version "$version")"
[[ -n "$this_cover_id" ]] || {
    echo "Error: no cover letter found for v$version in the '$series' mailbox." >&2
    exit 1
}
this_body="$("$mailbox" show "$series" "$this_cover_id" | awk 'f{print} /^$/{f=1}')"
first_line="$(printf '%s\n' "$this_body" | head -n1)"

tally_out="$("$mailbox" tally "$series" --version "$version")"

entries=()
if (( version >= 2 )); then
    for (( k = 2; k <= version; k++ )); do
        k_cover_id="$(cover_id_for_version "$k")"
        if [[ -z "$k_cover_id" ]]; then
            echo "Warning: no cover letter found for v$k; skipping its changelog." >&2
            continue
        fi
        k_body="$("$mailbox" show "$series" "$k_cover_id" | awk 'f{print} /^$/{f=1}')"
        # Portable POSIX awk, not gawk's IGNORECASE -- matches "## Changelog",
        # "### changelog", etc. Stops at the next heading line so it does not
        # swallow whatever lkml-mailbox.sh init --diffstat/--smoke appended
        # after the author's own Changelog section (## Diffstat, ## Test
        # results).
        k_changelog="$(printf '%s\n' "$k_body" | awk '
            BEGIN { found = 0 }
            found && /^#+[[:space:]]/ { exit }
            !found && tolower($0) ~ /^#+[[:space:]]*changelog/ { found = 1 }
            found { print }
        ')"
        if [[ -z "$k_changelog" ]]; then
            echo "Warning: v$k's cover letter has no Changelog heading; using its whole body." >&2
            k_changelog="$k_body"
        fi
        entries+=("$(printf 'v%s:\n%s' "$k" "$k_changelog")")
    done
fi

changelog=""
if (( ${#entries[@]} > 0 )); then
    changelog="$(printf '%s\n\n' "${entries[@]}")"
fi

commit_msg="$(printf '%s: forklift v%s onto %s\n\n%s\n\nTally (v%s):\n%s\n' \
    "$series" "$version" "$onto" "$first_line" "$version" "$tally_out")"
if [[ -n "$changelog" ]]; then
    commit_msg="$(printf '%s\nChangelog:\n\n%s' "$commit_msg" "$changelog")"
fi

if (( dry_run )); then
    printf '%s\n' "$commit_msg"
    echo "(dry run: no commit created)"
    exit 0
fi

new_commit="$(git -C "$real_repo" commit-tree "$new_tree" -p "$onto_sha" -m "$commit_msg")"
if ! git -C "$real_repo" update-ref "refs/heads/$onto" "$new_commit" "$onto_sha"; then
    echo "Error: refs/heads/$onto moved since this run started -- refusing to" >&2
    echo "overwrite a concurrent change. Nothing was committed to $onto." >&2
    exit 1
fi
if [[ "$(git -C "$real_repo" symbolic-ref -q HEAD 2>/dev/null)" == "refs/heads/$onto" ]]; then
    git -C "$real_repo" reset --hard "$new_commit"
fi
echo "fork-sandbox lkml-forklift: $onto now at $new_commit." >&2
