#!/usr/bin/env bash
# lkml-revise.sh — Launch the author persona to answer review and produce
# the next version of an lkml-mode series.
#
# Usage: lkml-revise.sh <series> --project <path> --checkout <ref> --version <n> --base <ref>
#            [--personas-dir <dir>] [--author <persona>] [--model-override <harness/model>]
#            [--timeout <seconds>] [--services-trust-ref <ref>]
#
# <project>   the repo fork-sandbox.sh clones.
# --checkout  the ref to revise from -- normally the branch vN was posted
#             from, so the author's clone already holds vN's commits.
# --services-trust-ref <ref> is passed through to the author's
#             fork-sandbox.sh launch. Without it, fork-sandbox.sh disables
#             the repo's .agents/sandbox-services hook on a --checkout run
#             (its warning lands in the captured launch output, unseen), so
#             the author gets no per-run services and cannot run suites
#             that need them. Pass the trusted base the series came from.
# --version   the CURRENT version being revised (an integer N). This launch
#             produces vN+1, posted under that version by lkml-mailbox.sh
#             init; the branch is named lkml/<series>-vN+1-<timestamp> (see
#             the launch report for the exact name -- the timestamp is
#             there so a retry after this script refuses downstream, e.g.
#             "committed but left no cover letter" below, does not collide
#             with the branch the failed attempt already fetched).
# --base      the series' ORIGINAL base -- the same ref v1's patches were
#             formatted against (SKILL.md step 1's <base-ref>), NOT vN's
#             tip. The author's commits land on top of vN, so formatting
#             vN's tip..vN+1 would post only this round's fixups as if they
#             were the whole series; formatting the ORIGINAL base..vN+1
#             posts the complete series every time.
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
#             e.g. `lkml-revise: seat author: pi-local (lkml-seats.yaml,
#             was claude/opus)`; --model-override wins over the seats file
#             silently.
# --timeout   seconds to wait for the run to finish. Default 3600.
#
# Unlike lkml-round.sh, this run is allowed to commit -- that is the whole
# point. The handoff hands the author the full thread tree and everything
# `lkml-mailbox.sh open` flags, and asks it to, for each open item, either
# fix the code (and commit, one logical change per commit rather than one
# squash) or reply on-thread explaining why not, then write the new cover
# letter to `.git/lkml-out/cover-letter.md` before finishing -- under
# .git/, not the working tree, so the "commit early and often" advice
# below cannot sweep it into a commit by accident (git tracks nothing
# under .git/; same convention fork-sandbox.sh itself uses for
# review-verdict.md and pi's session dir).
#
# After the run: this waits for summary.json (fork-sandbox.sh's own signal
# that the run -- and its fetch back into the real repo -- is fully over),
# then:
#
#   - Harvests any `.git/lkml-out/*.msg` reply files into the CURRENT threads,
#     exactly as lkml-round.sh does, whether or not any commits landed --
#     a reply explaining a disagreement is still worth posting even on a
#     round that changes no code.
#   - If, and only if, the run committed at least one commit AND left a
#     `.git/lkml-out/cover-letter.md`, runs `git format-patch` in the REAL repo
#     (never the clone) over the fetched branch, and posts the result as
#     the new version with `lkml-mailbox.sh init`.
#
# Exits non-zero, after still harvesting replies, when the run made no
# commits: that is this project's "a version changes nothing" stop
# condition (see skills/lkml-mode/SKILL.md), and it is the orchestrator's
# call whether to end the series there -- this script only reports it
# plainly rather than silently posting an unchanged version, and rather
# than deciding on its own that the series is done.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"
default_personas_dir="$(cd "$script_dir/.." && pwd)/skills/lkml-mode/personas"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

series="${1:?Usage: lkml-revise.sh <series> --project <path> --checkout <ref> --version <n>}"
shift

project=""
checkout_ref=""
version=""
base_ref=""
personas_dir="$default_personas_dir"
author_persona="author"
model_override=""
timeout=3600
services_trust_ref=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --checkout) checkout_ref="${2:?--checkout requires a ref}"; shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --base) base_ref="${2:?--base requires a ref}"; shift 2 ;;
        --personas-dir) personas_dir="${2:?--personas-dir requires a directory}"; shift 2 ;;
        --author) author_persona="${2:?--author requires a persona name}"; shift 2 ;;
        --model-override) model_override="${2:?--model-override requires harness or harness/model}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        --services-trust-ref) services_trust_ref="${2:?--services-trust-ref requires a ref}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
[[ -n "$checkout_ref" ]] || { echo "Error: --checkout is required." >&2; exit 1; }

trust_args=()
[[ -n "$services_trust_ref" ]] && trust_args=(--services-trust-ref "$services_trust_ref")
[[ -n "$version" ]] || { echo "Error: --version is required (the version being revised)." >&2; exit 1; }
[[ "$version" =~ ^[0-9]+$ ]] || { echo "Error: --version must be a plain integer." >&2; exit 1; }
[[ -n "$base_ref" ]] || { echo "Error: --base is required (the series' original base, the same ref v1 was formatted against)." >&2; exit 1; }
command -v fork-sandbox.sh >/dev/null 2>&1 || { echo "Error: fork-sandbox.sh not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

persona_file="$personas_dir/$author_persona.md"
[[ -f "$persona_file" ]] || { echo "Error: no persona file '$persona_file'." >&2; exit 1; }

# Identical to lkml-round.sh's own copy: two small, separately-reviewed
# surfaces reading the same three-line frontmatter convention, kept apart
# on purpose the way fork-sandbox-lib.sh's own header explains for
# fs_read_env_value -- if one changes, check the other.
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
    [[ -n "$seat_note" ]] && echo "fork-sandbox lkml-revise: $seat_note" >&2
fi

next_version=$(( version + 1 ))

cover_text="$("$mailbox" cover "$series" 2>/dev/null)" || cover_text="(no cover letter found)"
tree_text="$("$mailbox" tree "$series" 2>/dev/null)" || {
    echo "Error: series '$series' does not exist. Run lkml-mailbox.sh init first." >&2
    exit 1
}
open_text="$("$mailbox" open "$series" --version "$version" 2>/dev/null)"

mkdir -p -- /var/tmp/claude-scratch
handoff_file="$(mktemp /var/tmp/claude-scratch/lkml-revise-XXXXXX.md)" || {
    echo "Error: mktemp failed for the handoff file." >&2
    exit 1
}
{
    cat -- "$persona_file"
    printf '\n---\n\n# You are revising %s, currently at v%s\n\n%s\n' "$series" "$version" "$cover_text"
    printf '\n## The full thread tree\n\n%s\n' "$tree_text"
    printf '\n## Open items -- these are what review has not resolved yet\n\n%s\n' "$open_text"
    cat <<RULES

## What to do

For every open item above (and anything else tagged Question,
Changes-requested or NAK anywhere in the tree, even if it also shows up as
open), either fix the code and commit, or reply explaining why not -- see
"How to reply" below. An item you say nothing about is indistinguishable
from one you ignored.

Commit as you address each item, one logical change per commit -- not one
squash at the end. Uncommitted work is lost when this run ends, so commit
early and often rather than saving it all for a final commit.

When you are done, write the new cover letter, including a section headed
exactly \`## Changelog\` that says what changed because of which reviewer's
comment, to:

    .git/lkml-out/cover-letter.md

Under \`.git/\`, not the working tree: git tracks nothing there, so it
cannot end up staged or committed by the "commit early and often" habit
above.

The cover letter's FIRST LINE becomes the mailbox Subject verbatim, so
write it as a plain, short sentence -- no markdown heading marker, and no
"v2:" prefix (the mailbox already adds the version and patch numbering).

That file's presence is how the next step knows a new version is ready to
post. If you end this run having made no commits at all, still say so
plainly in your final report and do not fabricate a cover letter for a
version that changes nothing.

## How to reply

For anything you are answering with words rather than a code change,
write it as its own file under \`.git/lkml-out/\`, named \`1.msg\`, \`2.msg\`, ...
(not \`cover-letter.md\`, which is reserved for the new cover letter):

    In-Reply-To: <id>
    Subject: <optional -- default is "Re: <the parent's subject>">
    X-Tags: <optional, comma-separated: Reviewed-by, Acked-by, NAK, Changes-requested, Question>

    <your reply, quoting what you are answering with "> ">

\`In-Reply-To\` must name a message id that already exists in the thread
tree above (the full id or any unambiguous prefix). Ask a question rather
than guess when a comment itself is unclear.
RULES
} > "$handoff_file"

# Timestamped like lkml-round.sh's own per-round branches, and for the same
# reason: fork-sandbox.sh refuses to launch onto a branch that already
# exists, so a deterministic name would permanently wedge this series the
# first time a run fetches its branch and then this script refuses
# downstream (no commits, or commits with no cover letter) -- the next
# attempt at vN+1 would collide with the failed one's branch until an
# operator deletes it by hand.
branch="lkml/${series}-v${next_version}-$(date +%s)"
task_meta="$(jq -nc --arg series "$series" --arg persona "$author_persona" \
    '{kind:"implement", tags:["lkml", $series, $persona]}')"

harness_spec="$harness"
[[ -n "$model" ]] && harness_spec="$harness/$model"

# Same rule as lkml-round.sh: the `thinking:` seat fact only means
# something on a harness that starts pi; fork-sandbox.sh refuses
# --pi-args elsewhere, so it is dropped for claude and codex.
pi_args=()
if [[ -n "$thinking" && ( "$harness" == "pi" || "$harness" == "pi-local" ) ]]; then
    pi_args=(--pi-args "--thinking $thinking")
fi

echo "fork-sandbox lkml-revise: launching $author_persona ($harness_spec${thinking:+, thinking $thinking}) for v$next_version..." >&2
launch_out="$(fork-sandbox.sh --harness "$harness_spec" --checkout "$checkout_ref" \
    "${pi_args[@]}" "${trust_args[@]}" \
    --branch "$branch" --task-meta "$task_meta" "$project" "$handoff_file" 2>&1)"
rc=$?
run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
    echo "Error: launch failed:" >&2
    printf '%s\n' "$launch_out" >&2
    exit 1
fi
echo "fork-sandbox lkml-revise: $run_dir" >&2

# Same cost ledger lkml-round.sh appends to -- see its comment.
ledger_root="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
mkdir -p -- "$ledger_root/$series"
jq -nc --arg persona "$author_persona" --arg run_dir "$run_dir" --arg kind implement \
    '{persona:$persona, run_dir:$run_dir, kind:$kind}' >> "$ledger_root/$series/runs.jsonl"

echo "fork-sandbox lkml-revise: waiting up to ${timeout}s..." >&2
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
real_branch="$(jq -r '.branch' "$run_dir/summary.json")"
commits="$(jq -r '.commits' "$run_dir/summary.json")"
fetched="$(jq -r '.fetched' "$run_dir/summary.json")"

# A bare pi-local seat names no model -- the endpoint picks one -- and
# `post`/`init` refuse an empty --model. The run's summary records what
# the endpoint actually served; stamp that (same fallback as
# lkml-round.sh's harvest and lkml-cover.sh's init).
if [[ -z "$model" ]]; then
    model="$(jq -r '.model // empty' "$run_dir/summary.json" 2>/dev/null || true)"
fi
[[ -n "$model" ]] || model="unknown"

# Harvest one .git/lkml-out/*.msg file as a reply from the author persona.
# Kept as a function, not inline, specifically so its per-message state
# (reply_to, subject, tags, in_headers) is `local` and cannot leak between
# iterations of the loop below -- a message with no X-Tags must not inherit
# the previous message's tags.
# Strips optional angle brackets and the @lkml.local suffix from an
# In-Reply-To value -- same duplication of lkml-mailbox.sh's own
# lkml_strip_id, and for the same reason, as lkml-round.sh's copy.
lkml_revise_strip_id() {
    local v="$1"
    v="${v#<}"
    v="${v%>}"
    v="${v%%@*}"
    printf '%s' "$v"
}

harvest_reply() {
    local msgfile="$1"
    local reply_to="" subject="" tags="" in_headers=1 line body_file
    body_file="$(mktemp)"
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
    reply_to="$(lkml_revise_strip_id "$reply_to")"
    if [[ -z "$reply_to" ]]; then
        echo "Warning: lkml-revise: $msgfile has no In-Reply-To header; skipping it." >&2
        rm -f "$body_file"
        return 1
    fi
    local -a extra=()
    [[ -n "$subject" ]] && extra=(--subject "$subject")
    [[ -n "$tags" ]] && extra+=(--tags "$tags")
    local id rc=0
    id="$("$mailbox" post "$series" --from "$author_persona" --display "$display" \
        --reply-to "$reply_to" --file "$body_file" --harness "$harness" --model "$model" \
        "${extra[@]}")" || rc=$?
    rm -f "$body_file"
    if (( rc != 0 )); then
        echo "Warning: lkml-revise: failed to post $msgfile." >&2
        return 1
    fi
    echo "fork-sandbox lkml-revise: harvested $(basename -- "$msgfile") as ${id:0:7}" >&2
    return 0
}

# Harvest replies first, regardless of whether any commits landed -- a
# disagreement explained on-thread is worth having even on a round that
# changes no code.
harvested=0
out_dir="$clone_dir/.git/lkml-out"
if [[ -d "$out_dir" ]]; then
    while IFS= read -r msgfile; do
        [[ -e "$msgfile" ]] || continue
        harvest_reply "$msgfile" && harvested=$(( harvested + 1 ))
    done < <(find "$out_dir" -maxdepth 1 -name '*.msg' | sort -V)
fi
echo "fork-sandbox lkml-revise: harvested $harvested reply/replies onto the current version." >&2

if [[ "$commits" == "0" || "$fetched" != "true" ]]; then
    echo "fork-sandbox lkml-revise: the author made no commits this round --" >&2
    echo "no v$next_version to post. This is the 'a version changes nothing'" >&2
    echo "stop condition; deciding whether to end the series here is the" >&2
    echo "orchestrator's call." >&2
    exit 1
fi

cover_file="$out_dir/cover-letter.md"
if [[ ! -f "$cover_file" ]]; then
    echo "Error: the run committed $commits commit(s) but left no" >&2
    echo "$cover_file -- refusing to post v$next_version with no cover" >&2
    echo "letter. Read the branch $real_branch by hand." >&2
    exit 1
fi

patch_dir="$(mktemp -d /var/tmp/claude-scratch/lkml-revise-patches-XXXXXX)" || {
    echo "Error: mktemp -d failed for the format-patch output directory." >&2
    exit 1
}
real_repo="$(git -C "$project" rev-parse --show-toplevel)"
series_base_sha="$(cd "$real_repo" && git rev-parse --verify --quiet "${base_ref}^{commit}")" || {
    echo "Error: --base '$base_ref' does not name a commit in $real_repo." >&2
    exit 1
}
if ! (cd "$real_repo" && git format-patch --quiet -o "$patch_dir" "$series_base_sha..$real_branch") >/dev/null; then
    echo "Error: git format-patch failed for $series_base_sha..$real_branch in $real_repo." >&2
    exit 1
fi

new_cover_id="$(cd "$real_repo" && "$mailbox" init "$series" --cover "$cover_file" --patches "$patch_dir" \
    --from "$author_persona" --display "$display" --version "$next_version" \
    --harness "$harness" --model "$model" --diffstat "$series_base_sha..$real_branch")" || {
    echo "Error: lkml-mailbox.sh init failed -- v$next_version was not posted." >&2
    echo "Patches are sitting at $patch_dir; branch $real_branch was not" >&2
    echo "recorded in $ledger_root/$series/versions.jsonl." >&2
    exit 1
}
echo "fork-sandbox lkml-revise: posted v$next_version, cover ${new_cover_id:0:7}." >&2

# Same version-to-branch ledger lkml-series.sh writes for v1 -- lets
# lkml-forklift.sh find a version's branch without guessing its timestamp.
jq -nc --argjson version "$next_version" --arg branch "$real_branch" \
    '{version:$version, branch:$branch}' >> "$ledger_root/$series/versions.jsonl"

rm -rf -- "$patch_dir"
