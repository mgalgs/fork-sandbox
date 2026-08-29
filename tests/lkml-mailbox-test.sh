#!/usr/bin/env bash
# lkml-mailbox-test.sh — Exercise lkml-mailbox.sh: init, post, tree, cover,
# show, open and tally, against a throwaway mailbox root.
#
# Usage: tests/lkml-mailbox-test.sh
#
# Runs entirely offline against a temp LKML_MAILBOX_ROOT -- no network, no
# sandbox, no fork-sandbox.sh invocation.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

new_root() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s' "$d"
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

fixture_cover() {
    printf 'Add the frobnicator\n\nThis series adds a frobnicator to the widget subsystem.\n' > "$1"
}

fixture_patches() {
    local dir="$1"
    mkdir -p "$dir"
    printf 'Subject: [PATCH 1/2] frob: add core\n\ndiff --git a/frob.c b/frob.c\n+int frob(void) { return 0; }\n' \
        > "$dir/0001-add-core.patch"
    printf 'Subject: [PATCH 2/2] frob: add tests\n\ndiff --git a/frob_test.c b/frob_test.c\n+void test_frob(void) {}\n' \
        > "$dir/0002-add-tests.patch"
}

printf '== init ==\n'

export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(new_root)"
fixture_cover cover.txt
fixture_patches patches

out="$("$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus 2>diag.txt)"
rc=$?
check "init exits 0" "0" "$rc"
cover_id="$out"
n=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
check "posts the cover plus two patches (3 files)" "3" "$n"

tree_out="$("$mailbox" tree widget-frob)"
contains "tree shows the AI-attributed harness/model column" "$tree_out" "(claude/opus)"
contains "tree groups by version" "$tree_out" "=== v1 ==="
contains "tree shows the cover subject" "$tree_out" "[PATCH v1 0/2]"
contains "tree shows patch 1/2" "$tree_out" "[PATCH v1 1/2] frob: add core"
contains "tree shows patch 2/2" "$tree_out" "[PATCH v1 2/2] frob: add tests"

cover_out="$("$mailbox" cover widget-frob)"
contains "cover prints the cover letter body" "$cover_out" "adds a frobnicator to the widget subsystem"

raw="$("$mailbox" show widget-frob "${cover_id:0:7}")"
contains "show: From always carries (AI persona)" "$raw" "(AI persona)"
contains "show: X-AI-Harness is stamped" "$raw" "X-AI-Harness: claude"
contains "show: X-AI-Model is stamped" "$raw" "X-AI-Model: opus"
contains "show: X-Depth 0 for the cover" "$raw" "X-Depth: 0"
case "$raw" in
    *"In-Reply-To:"*) no "cover has no In-Reply-To" ;;
    *) ok "cover has no In-Reply-To" ;;
esac

patch_id="$(printf '%s\n' "$tree_out" | awk 'NR==3{print $1}')"

printf '\n== post ==\n'

echo "why not use a linked list here?" > q.txt
r1="$("$mailbox" post widget-frob --from linus --display "Linus Torvalds" \
    --reply-to "$patch_id" --file q.txt --tags Question \
    --harness claude --model opus 2>diag.txt)"
rc=$?
check "post exits 0" "0" "$rc"

raw1="$("$mailbox" show widget-frob "${r1:0:7}")"
contains "reply: From carries display name and (AI persona)" "$raw1" "Linus Torvalds (AI persona)"
# tree only ever shows the short id7, so these checks match it as a prefix
# of the full uuid rather than expecting an exact match.
contains "reply: In-Reply-To names the parent" "$raw1" "In-Reply-To: <$patch_id"
contains "reply: References carries the whole chain" "$raw1" "$cover_id@lkml.local"
contains "reply: References carries the parent too" "$raw1" "$patch_id"
contains "reply: X-Depth is parent-depth + 1" "$raw1" "X-Depth: 2"
contains "reply: default subject prefixes Re:" "$raw1" "Subject: Re: [PATCH v1 1/2] frob: add core"
contains "reply: carries the requested tag" "$raw1" "X-Tags: Question"

printf '\n== open ==\n'

open_out="$("$mailbox" open widget-frob)"
contains "open: the unanswered Question shows up" "$open_out" "${r1:0:7}"

echo "arrays are faster for this access pattern" > a.txt
r2="$("$mailbox" post widget-frob --from author --reply-to "${r1:0:7}" --file a.txt \
    --harness claude --model opus 2>diag.txt)"

open_out2="$("$mailbox" open widget-frob)"
case "$open_out2" in
    *"${r1:0:7}"*) no "open: answered Question is no longer open" "$open_out2" ;;
    *) ok "open: answered Question is no longer open" ;;
esac

printf '\n== tally ==\n'

echo "looks fine now" > rb.txt
"$mailbox" post widget-frob --from linus --reply-to "${r2:0:7}" --file rb.txt \
    --tags Reviewed-by --harness claude --model opus >/dev/null 2>&1

tally_out="$("$mailbox" tally widget-frob --version 1)"
contains "tally: patch 1 shows linus's Reviewed-by" "$tally_out" "Reviewed-by"
contains "tally: names the reviewing persona" "$tally_out" "linus"

# A later NAK from the same reviewer supersedes the earlier Reviewed-by --
# tally reports the LATEST tag per persona per patch, not every tag ever
# applied. Asserting "NAK" merely appears somewhere in the whole tally
# output would also pass if the superseded Reviewed-by were still counted
# alongside it (both tags surviving would make convergence look stuck
# forever, the exact bug this rule exists to prevent) -- so pull out
# linus's own tally line for patch 1 and check it is EXACTLY "NAK".
echo "actually this leaks the buffer on the error path" > nak.txt
"$mailbox" post widget-frob --from linus --reply-to "${r2:0:7}" --file nak.txt \
    --tags NAK --harness claude --model opus >/dev/null 2>&1
tally_out2="$("$mailbox" tally widget-frob --version 1)"
# Scoped to the "Patch 1:" block specifically, not because patch 0 would
# roll it up (a bare "line starting with linus" grep over the whole tally
# is exactly the bug the next check guards against) but to pin the format.
linus_tag="$(printf '%s\n' "$tally_out2" | awk '/^Patch 1:/{f=1;next} /^Patch [0-9]+:/{f=0} f && $1=="linus"{print $2}')"
check "tally: a later NAK supersedes an earlier Reviewed-by (not both)" "NAK" "$linus_tag"

# Nobody has said a word about the cover itself -- every tag so far landed
# on patch 1 or patch 2's own threads. Patch 0's subtree walk used to reach
# every patch's descendants too (the cover is their common ancestor), so
# this exact scenario used to print "Patch 0: (cover) ... linus NAK" for a
# NAK that was actually about patch 1.
contains "tally: patch 0 (cover) is NOT contaminated by patch 1's NAK" \
    "$tally_out2" "Patch 0: (cover)"
cover_block="$(printf '%s\n' "$tally_out2" | awk '/^Patch 0:/{f=1;next} /^Patch [0-9]+:/{f=0} f')"
check "tally: patch 0's block has no tags of its own yet" "  no tags" "$cover_block"

printf '\n== tally: direct replies to the cover ==\n'

# A direct reply to the cover letter is depth 1, same as a real patch, and
# its default subject is "Re: [PATCH v1 0/2] ..." -- which an unanchored
# "patch number" regex would match as patch 0 and use to overwrite the
# cover's own tally entry with the reply's id, silently dropping every
# OTHER direct reply to the cover from the count.
echo "the changelog checks out" > ack.txt
"$mailbox" post widget-frob --from linus --reply-to "${cover_id:0:7}" --file ack.txt \
    --tags Acked-by --harness claude --model opus >/dev/null 2>&1
echo "please split patch 2 first" > cr.txt
"$mailbox" post widget-frob --from security --reply-to "${cover_id:0:7}" --file cr.txt \
    --tags Changes-requested --harness claude --model opus >/dev/null 2>&1

tally_cover="$("$mailbox" tally widget-frob --version 1)"
contains "tally: patch 0 is still the cover, not the reply that clobbered it" \
    "$tally_cover" "Patch 0: (cover)"
contains "tally: patch 0 shows linus's Acked-by" "$tally_cover" "Acked-by"
contains "tally: patch 0 also shows security's Changes-requested (not dropped)" \
    "$tally_cover" "Changes-requested"

printf '\n== depth cap ==\n'

echo "msg" > m.txt
cur="$patch_id"
for _ in $(seq 1 29); do
    cur="$("$mailbox" post widget-frob --from bot --reply-to "$cur" --file m.txt 2>/dev/null)"
done
raw_deep="$("$mailbox" show widget-frob "${cur:0:7}")"
contains "a 30-deep chain (patch is depth 1, plus 29 replies) reaches depth 30" "$raw_deep" "X-Depth: 30"

out="$("$mailbox" post widget-frob --from bot --reply-to "$cur" --file m.txt 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses a reply that would exceed depth 30"
else
    no "refuses a reply that would exceed depth 30" "it succeeded"
fi
contains "the depth refusal names the limit" "$out" "30"

printf '\n== rejections ==\n'

out="$("$mailbox" post widget-frob --from bot --reply-to deadbeef1234 --file m.txt 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses an unknown parent id"
else
    no "refuses an unknown parent id" "it succeeded"
fi

out="$("$mailbox" post widget-frob --from bot --reply-to "${patch_id:0:7}" --file m.txt --tags Bogus 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses an unknown tag"
else
    no "refuses an unknown tag" "it succeeded"
fi

out="$("$mailbox" show widget-frob nosuchid 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "show refuses an id that matches nothing"
else
    no "show refuses an id that matches nothing" "it succeeded"
fi

printf '\n== concurrent posts ==\n'

before=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
pids=()
for _ in 1 2 3 4 5 6; do
    ( "$mailbox" post widget-frob --from bot --reply-to "$patch_id" --file m.txt >/dev/null 2>&1 ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
after=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
check "six concurrent posts all land as distinct files" "$(( before + 6 ))" "$after"

printf '\n== a second version ==\n'

# Deliberately distinct from fixture_cover's text (not just a second copy
# of it) -- v1's cover already contains "widget subsystem", so asserting
# that string alone would pass whether `cover` picked the highest version
# or the lowest, and prove nothing about which one it actually returned.
printf 'Add frobnicator locking\n\nThis v2 adds a mutex around the frobnicator.\n' > cover2.txt
fixture_patches patches2
"$mailbox" init widget-frob --cover cover2.txt --patches patches2 --from author \
    --harness claude --model opus >/dev/null 2>diag.txt

tree_out2="$("$mailbox" tree widget-frob)"
contains "tree still shows v1" "$tree_out2" "=== v1 ==="
contains "a bare init with no --version posts v2" "$tree_out2" "=== v2 ==="

cover_out2="$("$mailbox" cover widget-frob)"
contains "cover now returns the LATEST version's letter, not v1's" "$cover_out2" "adds a mutex around the frobnicator"

out="$("$mailbox" init widget-frob --cover cover2.txt --patches patches2 --from author --version 1 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses --version 1 a second time"
else
    no "refuses --version 1 a second time" "it succeeded"
fi

printf '\n== attachments ==\n'

printf 'a screenshot, pretend\n' > shot.png
out="$("$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus --attach shot.png 2>diag.txt)"
rc=$?
check "init --attach exits 0" "0" "$rc"
attach_cover_id="$out"
check "the attachment is copied into <series>/attachments/" "1" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob/attachments" -name 'shot.png' | wc -l)"

raw_att="$("$mailbox" show widget-frob "${attach_cover_id:0:7}")"
contains "show prints the X-Attachment header" "$raw_att" "X-Attachment: attachments/shot.png"

tree_att="$("$mailbox" tree widget-frob)"
contains "tree marks the attachment-carrying cover with 📎" \
    "$(printf '%s\n' "$tree_att" | grep "${attach_cover_id:0:7}")" "📎"

echo "see the attached log" > note.txt
r_att="$("$mailbox" post widget-frob --from linus --reply-to "${attach_cover_id:0:7}" \
    --file note.txt --attach shot.png --harness claude --model opus 2>diag.txt)"
rc=$?
check "post --attach exits 0" "0" "$rc"
raw_reply_att="$("$mailbox" show widget-frob "${r_att:0:7}")"
contains "a reply's attachment also gets an X-Attachment header" "$raw_reply_att" "X-Attachment: attachments/shot.png"

big="$(mktemp)"; tmpdirs+=("$big")
dd if=/dev/zero of="$big" bs=1M count=5 >/dev/null 2>&1
out="$("$mailbox" post widget-frob --from linus --reply-to "${attach_cover_id:0:7}" \
    --file note.txt --attach "$big" --harness claude --model opus 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses an attachment over the 4 MiB cap"; else no "refuses an attachment over the 4 MiB cap" "it succeeded"; fi
contains "the cap refusal names the byte cap" "$out" "4194304"

printf '\n== init --diffstat / --smoke ==\n'

diffstat_repo="$(mktemp -d)"; tmpdirs+=("$diffstat_repo")
git -C "$diffstat_repo" init -q
git -C "$diffstat_repo" config user.email test@example.com
git -C "$diffstat_repo" config user.name "Test"
printf 'base\n' > "$diffstat_repo/file.txt"
git -C "$diffstat_repo" add file.txt
git -C "$diffstat_repo" commit -q -m "base"
base_sha="$(git -C "$diffstat_repo" rev-parse HEAD)"
printf 'base\nmore\n' > "$diffstat_repo/file.txt"
git -C "$diffstat_repo" commit -q -am "add a line"
tip_sha="$(git -C "$diffstat_repo" rev-parse HEAD)"

printf 'all tests passed: 42/42\n' > smoke.txt

out="$(cd "$diffstat_repo" && "$mailbox" init widget-frob --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --diffstat "$base_sha..$tip_sha" --smoke "$work/smoke.txt" 2>diag.txt)"
rc=$?
check "init --diffstat/--smoke exits 0" "0" "$rc"
diffstat_cover_id="$out"
raw_diffstat="$("$mailbox" show widget-frob "${diffstat_cover_id:0:7}")"
contains "cover body gets a Diffstat section" "$raw_diffstat" "## Diffstat"
contains "the diffstat section carries git's own output" "$raw_diffstat" "file.txt"
contains "cover body gets a Test results section" "$raw_diffstat" "## Test results"
contains "the Test results section carries the smoke file verbatim" "$raw_diffstat" "all tests passed: 42/42"

out="$(cd "$diffstat_repo" && "$mailbox" init widget-frob --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --smoke "$work/nosuchfile.txt" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses a --smoke file that does not exist"; else no "refuses a --smoke file that does not exist" "it succeeded"; fi

out="$(cd "$diffstat_repo" && "$mailbox" init widget-frob --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --diffstat "nonsense..alsobogus" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses a --diffstat range that fails to diff"; else no "refuses a --diffstat range that fails to diff" "it succeeded"; fi

out="$("$mailbox" init widget-frob --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --diffstat "$base_sha..$tip_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses a --diffstat range when cwd is not a git repo"; else no "refuses a --diffstat range when cwd is not a git repo" "it succeeded"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
