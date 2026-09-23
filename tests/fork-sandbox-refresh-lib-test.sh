#!/usr/bin/env bash
# fork-sandbox-refresh-lib-test.sh — Direct cases for fork-sandbox-refresh.sh
#
# Usage: tests/fork-sandbox-refresh-lib-test.sh
#
# The shared --refresh-at helpers are sourced by the local runner and shipped
# to the pod as ConfigMap key refresh.sh. fork-sandbox-refresh-test.sh drives
# them end to end through the runner; this suite calls each function directly
# so a refusal path or an ordering rule is pinned without a whole run.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
lib="$repo_dir/scripts/fork-sandbox-refresh.sh"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        no "$1" "expected '$2', got '$3'"
    fi
}

contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) no "$1" "expected to find '$2' in: $3" ;;
    esac
}

lacks() {
    case "$3" in
        *"$2"*) no "$1" "did not expect '$2' in: $3" ;;
        *) ok "$1" ;;
    esac
}

# shellcheck source=../scripts/fork-sandbox-refresh.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib"

new_tmp() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s\n' "$d"
}

printf '== the file itself ==\n'
long="$(awk 'length > 96' "$lib" | wc -l)"
check "no line of fork-sandbox-refresh.sh exceeds 96 columns" "0" "$long"
if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck "$lib" > /dev/null 2>&1; then ok "shellcheck clean"; else no "shellcheck clean"; fi
fi

printf '\n== fs_refresh_leg_was_nudged ==\n'
t="$(new_tmp)"
printf '{"type":"system","stderr":"fork-sandbox-refresh: nudged"}\n' > "$t/nudged.jsonl"
printf '{"type":"result"}\n' > "$t/quiet.jsonl"
fs_refresh_leg_was_nudged "$t/nudged.jsonl" && r=yes || r=no
check "a nudged events file is recognised" yes "$r"
fs_refresh_leg_was_nudged "$t/quiet.jsonl" && r=yes || r=no
check "an un-nudged events file is not" no "$r"
fs_refresh_leg_was_nudged "$t/missing.jsonl" && r=yes || r=no
check "a missing events file is not" no "$r"

printf '\n== fs_refresh_take_handoff ==\n'
t="$(new_tmp)"; mkdir -p "$t/outbox" "$t/rec"; : > "$t/log"
printf 'work left: x\n' > "$t/outbox/handoff.md"
out="$(fs_refresh_take_handoff "$t/outbox" "$t/rec" 1 "$t/log")"; rc=$?
check "a normal hand-off is taken (rc)" 0 "$rc"
check "the taken path is printed" "$t/rec/handoff-1.md" "$out"
check "the record holds the hand-off" "work left: x" "$(cat "$t/rec/handoff-1.md")"
marker="no"; [[ -e "$t/outbox/handoff.md" ]] && marker=yes
check "the outbox no longer holds it" no "$marker"
check "a taken hand-off logs nothing" "" "$(cat "$t/log")"

t="$(new_tmp)"; mkdir -p "$t/outbox" "$t/rec"; : > "$t/log"
printf 'secret\n' > "$t/target"
ln -s "$t/target" "$t/outbox/handoff.md"
out="$(fs_refresh_take_handoff "$t/outbox" "$t/rec" 1 "$t/log")"; rc=$?
check "a symlink hand-off is refused (rc)" 1 "$rc"
check "a refusal prints no path" "" "$out"
contains "the symlink refusal is logged" "outbox handoff.md is a symlink; refusing it." "$(cat "$t/log")"
marker="no"; [[ -L "$t/outbox/handoff.md" || -e "$t/outbox/handoff.md" ]] && marker=yes
check "the symlink is removed" no "$marker"
check "the symlink target is untouched" "secret" "$(cat "$t/target")"

t="$(new_tmp)"; mkdir -p "$t/outbox" "$t/rec"; : > "$t/log"
head -c 65537 /dev/zero | tr '\0' 'a' > "$t/outbox/handoff.md"
out="$(fs_refresh_take_handoff "$t/outbox" "$t/rec" 1 "$t/log")"; rc=$?
check "an oversized hand-off is refused (rc)" 1 "$rc"
contains "the size refusal is logged" \
    "outbox handoff.md is 65537 bytes, over the 64 KiB cap; refusing it." "$(cat "$t/log")"
marker="no"; [[ -f "$t/rec/handoff-refused-too-large.md" ]] && marker=yes
check "the oversized hand-off is moved aside" yes "$marker"
head -c 65536 /dev/zero | tr '\0' 'a' > "$t/outbox/handoff.md"
fs_refresh_take_handoff "$t/outbox" "$t/rec" 1 "$t/log" > /dev/null; rc=$?
check "exactly 64 KiB is accepted" 0 "$rc"

t="$(new_tmp)"; mkdir -p "$t/outbox" "$t/rec"; : > "$t/log"
: > "$t/outbox/handoff.md"
out="$(fs_refresh_take_handoff "$t/outbox" "$t/rec" 1 "$t/log")"; rc=$?
check "an empty hand-off is refused (rc)" 1 "$rc"
contains "the empty refusal is logged" "outbox handoff.md is empty; refusing it." "$(cat "$t/log")"
marker="no"; [[ -f "$t/rec/handoff-refused-empty.md" ]] && marker=yes
check "the empty hand-off is moved aside" yes "$marker"

t="$(new_tmp)"; mkdir -p "$t/outbox" "$t/rec"; : > "$t/log"
printf 'again\n' > "$t/outbox/handoff.md"
out="$(fs_refresh_take_handoff "$t/outbox" "$t/rec" 7 "$t/log")"
check "the number names the record" "$t/rec/handoff-7.md" "$out"

printf '\n== fs_refresh_handoff_stale ==\n'
t="$(new_tmp)"; mkdir -p "$t/clone/.git/logs"
printf 'h\n' > "$t/handoff.md"
touch -d '2001-01-01 00:00:00' "$t/handoff.md"
touch -d '2002-01-01 00:00:00' "$t/clone/.git/logs/HEAD"
fs_refresh_handoff_stale "$t/clone" "$t/handoff.md" && r=yes || r=no
check "a hand-off older than the last commit is stale" yes "$r"
touch -d '2003-01-01 00:00:00' "$t/handoff.md"
fs_refresh_handoff_stale "$t/clone" "$t/handoff.md" && r=yes || r=no
check "a hand-off newer than the last commit is fresh" no "$r"
rm -f "$t/clone/.git/logs/HEAD"
fs_refresh_handoff_stale "$t/clone" "$t/handoff.md" && r=yes || r=no
check "no commit log is never stale" no "$r"

printf '\n== fs_refresh_addenda_dirs ==\n'
t="$(new_tmp)"
mkdir -p "$t/inbox-delivered/leg-2" "$t/inbox-delivered/leg-10" "$t/inbox-delivered/leg-3"
got="$(fs_refresh_addenda_dirs "$t" | sed "s|$t/||" | tr '\n' ' ')"
check "leg-10 sorts after leg-2 and leg-3" \
    "inbox-delivered/leg-2 inbox-delivered/leg-3 inbox-delivered/leg-10 " "$got"
check "no archive dir, no output" "" "$(fs_refresh_addenda_dirs "$(new_tmp)")"

printf '\n== fs_refresh_archive_inbox ==\n'
t="$(new_tmp)"; mkdir -p "$t/inbox" "$t/rec"; : > "$t/log"
printf 'a\n' > "$t/inbox/addendum-1.md"
printf 'b\n' > "$t/inbox/mail-banner-1.md"
printf 'dot\n' > "$t/inbox/.refresh-config"
printf 'x\n' > "$t/real.md"; ln -s "$t/real.md" "$t/inbox/link.md"
fs_refresh_archive_inbox "$t/inbox" "$t/rec" 2 "$t/log"
check "an addendum moves to inbox-delivered/leg-N" a "$(cat "$t/rec/inbox-delivered/leg-2/addendum-1.md")"
check "a mail banner moves to mail-delivered/leg-N" b "$(cat "$t/rec/mail-delivered/leg-2/mail-banner-1.md")"
marker="no"; [[ -e "$t/rec/inbox-delivered/leg-2/mail-banner-1.md" ]] && marker=yes
check "a mail banner is not archived as an addendum" no "$marker"
contains "a symlink is refused and logged" "link.md is a symlink; refusing to archive it." "$(cat "$t/log")"
marker="no"; [[ -L "$t/inbox/link.md" ]] && marker=yes
check "the symlink stays where it was" yes "$marker"
marker="no"; [[ -f "$t/inbox/.refresh-config" ]] && marker=yes
check "dotfiles are left in the inbox" yes "$marker"
t="$(new_tmp)"; mkdir -p "$t/inbox" "$t/rec"
fs_refresh_archive_inbox "$t/inbox" "$t/rec" 2 "$t/log"
marker="no"; [[ -e "$t/rec/inbox-delivered" ]] && marker=yes
check "an empty inbox creates no archive dir" no "$marker"

printf '\n== fs_refresh_build_prompt ==\n'
t="$(new_tmp)"; mkdir -p "$t/rec"
printf 'HEADER\n' > "$t/header.md"
printf 'ORIGINAL BRIEF\n' > "$t/brief.md"
printf 'HANDOFF BODY\n' > "$t/rec/handoff-1.md"
fs_refresh_build_prompt 1 "$t/rec/handoff-1.md" "$t/p1.md" 0 "$t/header.md" "$t/brief.md" "$t/rec"
p="$(cat "$t/p1.md")"
marker="no"; [[ -e "$t/p1.md.part" ]] && marker=yes
check "no .part file is left behind" no "$marker"
contains "the header leads" "HEADER" "$p"
contains "the continuation number is named" "# This is continuation 1 of a run" "$p"
contains "no addenda: two documents" "Two documents follow" "$p"
lacks "no addenda: no addenda section" "Operator addenda delivered" "$p"
lacks "not stale: no warning" "this hand-off is stale" "$p"
contains "the brief follows" "## The original brief" "$p"
contains "the hand-off closes" "## Hand-off from the previous leg" "$p"
check "the prompt ends with the hand-off" "HANDOFF BODY" "$(tail -n 1 "$t/p1.md")"

mkdir -p "$t/rec/inbox-delivered/leg-2" "$t/rec/inbox-delivered/leg-10"
printf 'ADD TWO\n' > "$t/rec/inbox-delivered/leg-2/one.md"
printf 'ADD TEN\n' > "$t/rec/inbox-delivered/leg-10/two.md"
fs_refresh_build_prompt 2 "$t/rec/handoff-1.md" "$t/p2.md" 1 "$t/header.md" "$t/brief.md" "$t/rec"
p="$(cat "$t/p2.md")"
contains "addenda: three documents" "Three documents follow" "$p"
contains "addenda section present" "## Operator addenda delivered to earlier legs" "$p"
contains "addendum file names are headed" "### one.md" "$p"
before="${p%%ADD TEN*}"
contains "leg-2's addendum precedes leg-10's" "ADD TWO" "$before"
contains "stale: warning present" "## Warning: this hand-off is stale" "$p"
order="$(grep -n '^## ' "$t/p2.md" | sed 's/^[0-9]*:## //' | tr '\n' '|')"
check "section order: brief, addenda, stale, hand-off" \
    "The original brief|Operator addenda delivered to earlier legs|Warning: this hand-off is stale|Hand-off from the previous leg|" \
    "$order"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
