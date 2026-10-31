#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/20-run-index.sh — the run store's hot-path readers:
# fs_pm_env_get (fork-sandbox-lib.sh) answers exactly as the `sed | tail` it
# replaced did.
#
# Usage: tests/postmaster/20-run-index.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../scripts/fork-sandbox-lib.sh
source "$repo_dir/scripts/fork-sandbox-lib.sh"

echo "== fs_pm_env_get: same output as sed | tail =="

# The implementation fs_pm_env_get replaced, kept here as the oracle.
old_env_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n1
}

eg_dir="$work/env-get"
mkdir -p "$eg_dir"
printf 'A=1\nB=x=y=z\nEMPTY=\nA=2\nAA=nope\n aA=no\nSP= lead and trail \nBS=a\\nb\\\\c\nGLOB=*?[x]\n' \
    > "$eg_dir/rec.env"
printf 'A=1\nLAST=unterminated' > "$eg_dir/noeol.env"
printf 'LAST=first\nLAST=second' > "$eg_dir/noeol-dup.env"
printf 'LAST=only\n' > "$eg_dir/eol.env"
: > "$eg_dir/empty.env"
mkdir -p "$eg_dir/dir.env"

for case in rec:A rec:B rec:EMPTY rec:AA rec:aA rec:SP rec:BS rec:GLOB rec:MISSING \
            noeol:A noeol:LAST noeol-dup:LAST eol:LAST empty:A dir:A nofile:A; do
    file="$eg_dir/${case%%:*}.env" key="${case#*:}"
    # Raw bytes, trailing newline included: od shows what $(...) would hide.
    want="$(old_env_get "$file" "$key" | od -An -c)"
    got="$(fs_pm_env_get "$file" "$key" | od -An -c)"
    check "fs_pm_env_get $case: same bytes as sed | tail" "$want" "$got"
    want="$(old_env_get "$file" "$key")"
    fs_pm_env_read got "$file" "$key"
    check "fs_pm_env_read $case: same value as sed | tail" "$want" "$got"
done

finish_suite
