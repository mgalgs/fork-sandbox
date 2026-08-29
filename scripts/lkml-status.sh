#!/usr/bin/env bash
# lkml-status.sh — One screen: where an lkml-mode series stands
#
# Usage: lkml-status.sh <series>
#
# Prints: the current (highest) version and how many patches it has, the
# tally for that version, every open thread, the deepest thread in the
# whole series, and the running cost -- summed from summary.json of every
# run lkml-round.sh and lkml-revise.sh have launched for this series,
# recorded in a small ledger beside the mailbox
# ($LKML_MAILBOX_ROOT/<series>/runs.jsonl, default
# /var/tmp/claude-scratch/lkml/<series>/runs.jsonl) rather than as an
# 8th lkml-mailbox.sh verb. A run whose summary.json is missing (still in
# flight, or its run directory was already cleaned up) is counted in the
# run total but contributes nothing to the cost sum, and is named as
# "no summary" rather than silently treated as free.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"
LKML_ROOT="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
esac

series="${1:?Usage: lkml-status.sh <series>}"
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

tree_out="$("$mailbox" tree "$series" 2>&1)" || {
    echo "Error: series '$series' does not exist." >&2
    echo "$tree_out" >&2
    exit 1
}

version="$(printf '%s\n' "$tree_out" | sed -n 's/^=== v\([0-9]\+\) ===$/\1/p' | sort -n | tail -n1)"

tally_out="$("$mailbox" tally "$series" --version "$version" 2>/dev/null)"
# tally prints one "Patch N: ..." line per patch, N starting at 0 for the
# cover -- counting them (and subtracting the cover) beats grepping the
# tree's subjects, which a reply's default "Re: [PATCH ...]" Subject would
# double-count.
n_patches="$(printf '%s\n' "$tally_out" | grep -c '^Patch [0-9]\+:')"
(( n_patches > 0 )) && n_patches=$(( n_patches - 1 ))

# Indentation in `tree` is exactly 2 spaces per depth level (lkml_tree_print
# in lkml-mailbox.sh), so the deepest indent, halved, is the deepest depth.
deepest="$(printf '%s\n' "$tree_out" | sed -n 's/^\( *\)[0-9a-f]\{7\} .*/\1/p' | awk '{print length($0)/2}' | sort -n | tail -n1)"
[[ -n "$deepest" ]] || deepest=0

printf 'Series: %s\n' "$series"
printf 'Current version: v%s (%s patches)\n' "$version" "$n_patches"
printf 'Deepest thread: depth %s (of 30 max)\n' "$deepest"

printf '\n== Tally, v%s ==\n' "$version"
printf '%s\n' "$tally_out"

printf '\n== Open threads, v%s ==\n' "$version"
"$mailbox" open "$series" --version "$version"

printf '\n== Cost ==\n'
ledger="$LKML_ROOT/$series/runs.jsonl"
if [[ ! -f "$ledger" ]]; then
    echo "(no runs recorded)"
    exit 0
fi

total_runs=0
missing_summary=0
total_cost="0"
declare -A cost_by_persona=()
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    total_runs=$(( total_runs + 1 ))
    run_dir="$(printf '%s' "$line" | jq -r '.run_dir')"
    persona="$(printf '%s' "$line" | jq -r '.persona')"
    if [[ ! -f "$run_dir/summary.json" ]]; then
        missing_summary=$(( missing_summary + 1 ))
        continue
    fi
    cost="$(jq -r '.total_cost_usd // .cost_usd // 0' "$run_dir/summary.json")"
    [[ "$cost" == "null" ]] && cost=0
    total_cost="$(awk -v a="$total_cost" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')"
    prev="${cost_by_persona[$persona]:-0}"
    cost_by_persona[$persona]="$(awk -v a="$prev" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')"
done < "$ledger"

printf 'Runs launched: %s' "$total_runs"
if (( missing_summary > 0 )); then
    printf ' (%s with no summary.json yet -- in flight, or cleaned up)\n' "$missing_summary"
else
    printf '\n'
fi
printf 'Total cost so far: $%s\n' "$total_cost"
for persona in "${!cost_by_persona[@]}"; do
    printf '  %-14s $%s\n' "$persona" "${cost_by_persona[$persona]}"
done
