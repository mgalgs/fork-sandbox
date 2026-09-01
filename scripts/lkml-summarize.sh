#!/usr/bin/env bash
# lkml-summarize.sh — Turn a finished lkml-mode review thread into
# condensed, actionable intelligence, written into the series dir.
#
# Usage: lkml-summarize.sh <series> --project <path> [--version <n>]
#            [--high <harness[/model]>] [--low <harness[/model]>]
#            [--timeout <seconds>]
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
#            harness a persona-style model name: that is the
#            lkml-round.sh --model-override 404 lesson. Without the
#            flag, each tier falls back to the machine default in
#            ~/.config/fork-sandbox/lkml-summarize.env (keys
#            LKML_SUMMARIZE_HIGH / LKML_SUMMARIZE_LOW, same form; the
#            file's path is overridable via LKML_SUMMARIZE_ENV_FILE),
#            then to the shipped defaults high=claude/opus,
#            low=claude/sonnet. Flags beat env, env beats default.
# --timeout  seconds to wait for each tier's run to finish. Default 3600.
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
# Re-summarizing a version overwrites both files; the written paths
# are the last stdout lines.
#
# results-v<N>.md is a FORMAT CONTRACT, not a free-form essay -- the
# lkml-render round renders it as a collapsed card:
#     # Summary
#     (1-2 short paragraphs, roughly the pixel height of the Reviewers
#      panel: ~120 words max; this script WARNS on stderr above ~200)
#     # Details
#     (free-form: defect list with severity/status and message-id
#      citations, per-patch disposition, recommended next actions)
# Message ids are cited as bare 7-hex tokens (e.g. 9d67f5e) -- no
# brackets, no anchors; the renderer autolinks ids that exist in the
# mailbox.

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
high_spec=""
low_spec=""
timeout=3600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="${2:?--project requires a path}"; shift 2 ;;
        --version) version="${2:?--version requires a number}"; shift 2 ;;
        --high) high_spec="${2:?--high requires a harness or harness/model}"; shift 2 ;;
        --low) low_spec="${2:?--low requires a harness or harness/model}"; shift 2 ;;
        --timeout) timeout="${2:?--timeout requires seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$project" ]] || { echo "Error: --project is required." >&2; exit 1; }
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
    local flag_value="$1" env_key="$2" default="$3" spec
    spec="$flag_value"
    if [[ -z "$spec" ]]; then
        spec="$(lkml_summarize_env_value "$env_file" "$env_key" || true)"
    fi
    if [[ -z "$spec" ]]; then
        spec="$default"
    fi
    spec="${spec#"${spec%%[![:space:]]*}"}"
    spec="${spec%"${spec##*[![:space:]]}"}"
    if [[ -z "$spec" || "$spec" == *[[:space:]]* ]]; then
        echo "Error: tier setting '$env_key' is empty or contains whitespace." >&2
        return 1
    fi
    if [[ ! "$spec" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]]; then
        echo "Error: tier setting '$env_key' is '$spec', not a harness or harness/model." >&2
        return 1
    fi
    printf '%s' "$spec"
}

high_spec="$(resolve_tier "$high_spec" LKML_SUMMARIZE_HIGH claude/opus)" || exit 1
low_spec="$(resolve_tier "$low_spec" LKML_SUMMARIZE_LOW claude/sonnet)" || exit 1

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

echo "fork-sandbox lkml-summarize: summarizing $series v$version (low: $low_spec, high: $high_spec)" >&2
echo "fork-sandbox lkml-summarize: launch pipeline not wired yet (see the next commit)." >&2
exit 1
