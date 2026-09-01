#!/usr/bin/env bash
# lkml-render-test.sh — render a real mailbox fixture and check the HTML.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"
renderer="$repo_dir/scripts/lkml-render.py"

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

contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found" ;;
    esac
}

work="$(mktemp -d)"
tmpdirs+=("$work")
export LKML_MAILBOX_ROOT="$work/mailbox"
mkdir -p "$work/patches"

printf '%s\n' '<script>alert(1)</script>' '' '```' 'fenced *markdown*' '```' > "$work/cover.txt"
printf '%s\n' \
    'Subject: [PATCH 1/2] demo: add one' '' \
    'From abcdef1234567890 Mon Sep 17 00:00:00 2001' \
    'Commit message for patch one.' '' '---' ' demo.c | 1 +' ' 1 file changed, 1 insertion(+)' '' \
    'diff --git a/demo.c b/demo.c' '+one' > "$work/patches/0001-one.patch"
printf '%s\n' \
    'Subject: [PATCH 2/2] demo: add two' '' \
    'From deadbeef1234567890 Mon Sep 17 00:00:00 2001' \
    'Commit message for patch two.' '' '---' ' demo.c | 1 +' ' 1 file changed, 1 insertion(+)' '' \
    'diff --git a/demo.c b/demo.c' '+two' > "$work/patches/0002-two.patch"

"$mailbox" init render-fixture --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness test --model fixture >/dev/null 2>/dev/null
tree="$($mailbox tree render-fixture)"
patch_id="$(printf '%s\n' "$tree" | awk '/\[PATCH v1 1\/2\]/{print $1}')"

printf '%s\n' 'Reviewed-by: The Reviewer' > "$work/review.txt"
printf 'not really a png, but safely embedded\n' > "$work/shot.png"
"$mailbox" post render-fixture --from core --reply-to "$patch_id" --file "$work/review.txt" \
    --tags Reviewed-by --attach "$work/shot.png" --harness test --model fixture >"$work/review-id" 2>/dev/null
review_id="$(<"$work/review-id")"
printf '%s\n' 'Tested-by: The CI Bot' > "$work/tested.txt"
"$mailbox" post render-fixture --from ci --reply-to "$patch_id" --file "$work/tested.txt" \
    --harness test --model fixture >/dev/null 2>/dev/null
printf '%s\n' 'orphan body' > "$work/orphan.txt"
"$mailbox" post render-fixture --from newcomer --reply-to does-not-exist --file "$work/orphan.txt" \
    --harness test --model fixture >/dev/null 2>/dev/null

stdout="$work/stdout.html"
custom="$work/custom.html"
default="$work/default.html"
if python3 "$renderer" render-fixture-dir-does-not-exist >/dev/null 2>"$work/bad"; then
    no "missing mailbox fails"
else
    ok "missing mailbox fails"
fi
python3 "$renderer" "$LKML_MAILBOX_ROOT/render-fixture" > "$default"
python3 "$renderer" --title 'Demo & Review' "$LKML_MAILBOX_ROOT/render-fixture" -o "$custom"
python3 "$renderer" --title 'Demo & Review' "$LKML_MAILBOX_ROOT/render-fixture" > "$stdout"
html="$(<"$default")"

if [[ "$(grep -o '<!doctype html>' "$stdout" | wc -l)" -eq 1 ]]; then ok "starts with doctype"; else no "starts with doctype"; fi
if [[ "$(grep -o '<title>' "$stdout" | wc -l)" -eq 1 ]]; then ok "has exactly one title"; else no "has exactly one title"; fi
contains "default title is generic" "$html" '<title>Review Threads</title>'
case "$html" in *fork-sandbox*) no "default has no fork-sandbox" ;; *) ok "default has no fork-sandbox" ;; esac
custom_html="$(<"$stdout")"
contains "custom title appears escaped" "$custom_html" '<title>Demo &amp; Review</title>'
contains "script payload is escaped" "$html" '&lt;script&gt;alert(1)&lt;/script&gt;'
case "$html" in *'<script>alert(1)</script>'*) no "script payload is never raw" ;; *) ok "script payload is never raw" ;; esac
if [[ "$(grep -o '<tr><th scope="row"' "$stdout" | wc -l)" -eq 3 ]]; then ok "tally has cover plus two patch rows"; else no "tally has cover plus two patch rows"; fi
if [[ "$(grep -o '<li style=' "$stdout" | wc -l)" -eq 6 ]]; then ok "thread index has one line per message"; else no "thread index has one line per message"; fi
contains "Tested-by has its own chip class" "$html" 'class="tag t-test"'
case "$html" in *'Tested-by</span>'*'t-q'*) no "Tested-by does not fall through to question" ;; *) ok "Tested-by does not fall through to question" ;; esac
contains "orphaned reply is rendered" "$html" 'orphan body'
contains "tally cell links to latest tagged reply" "$html" "href=\"#m-$review_id\" title=\"Reviewed-by\">R"
if python3 - "$stdout" <<'PY'
import re
import sys

html = open(sys.argv[1], encoding="utf-8").read()
row = re.search(r'<tr><th scope="row"><a href="#[^"]*">cover</a>(.*?)</tr>', html).group(1)
raise SystemExit("cover row contains a patch reviewer" if "t-rev" in row else 0)
PY
then
    ok "cover tally excludes patch reviewer"
else
    no "cover tally excludes patch reviewer"
fi
contains "attachment reference is rendered" "$html" 'attachments/shot.png'
contains "attachment contents are embedded" "$html" 'data:image/png;base64,'
case "$html" in *fonts.googleapis.com*) no "output has no remote font dependency" ;; *) ok "output has no remote font dependency" ;; esac
if cmp -s "$stdout" "$custom"; then ok "output file matches stdout"; else no "output file matches stdout"; fi
if python3 -m py_compile "$renderer"; then ok "renderer compiles"; else no "renderer compiles"; fi

printf '\n== matrix row labels ==\n'
contains "patch row label is standard series numbering" "$html" '>Patch v1 1/2</a></th>'
contains "second patch row label is numbered too" "$html" '>Patch v1 2/2</a></th>'
contains "row label title carries the full subject" "$html" '<th scope="row" title="[PATCH v1 1/2] demo: add one">'
case "$html" in *'>demo: add one</a></th>'*|*'>demo: add two</a></th>'*) no "truncated subjects are no longer row labels" ;; *) ok "truncated subjects are no longer row labels" ;; esac

printf '\n== reviewers section (headers only, no persona files yet) ==\n'
if [[ "$(grep -o '<details class="reviewer"' "$stdout" | wc -l)" -eq 3 ]]; then ok "one expand-o per reviewer (core, ci, newcomer)"; else no "one expand-o per reviewer (core, ci, newcomer)"; fi
contains "reviewer summary carries display name and persona slug" "$html" '<span class="who">Core</span> <span class="slug mono">core</span>'
contains "reviewer rollup shows harness and model" "$html" 'test · fixture'
contains "reviewer rollup counts messages" "$html" '<span>1 message</span>'
contains "reviewer rollup counts Reviewed-by" "$html" '<span>1 Reviewed-by</span>'
contains "reviewer count matches the reviewers box" "$html" '<span>3 reviewers</span>'
# The header count, the matrix's reviewer columns and the box must
# describe the same set: newcomer commented but never tagged, and still
# gets a (dot) column rather than vanishing from the matrix.
if [[ "$(grep -o '<th title=' "$stdout" | wc -l)" -eq 3 ]]; then ok "matrix has a column per listed reviewer, tag or no tag"; else no "matrix has a column per listed reviewer, tag or no tag"; fi
contains "untagged reviewer's column is present" "$html" '<th title="test/fixture">newcomer</th>'
if python3 - "$stdout" <<'PY'
import re
import sys

html = open(sys.argv[1], encoding="utf-8").read()
thead = re.search(r'<thead><tr><th scope="col">patch</th>(.*?)</tr></thead>', html).group(1)
col_order = re.findall(r'<th title="[^"]*">([^<]+)</th>', thead)
box_order = re.findall(r'<span class="slug mono">([^<]+)</span>', html)
raise SystemExit("box order %s != column order %s" % (box_order, col_order) if box_order != col_order else 0)
PY
then
    ok "box lists reviewers in matrix column order"
else
    no "box lists reviewers in matrix column order"
fi
case "$html" in *'<span class="slug mono">author</span>'*) no "author persona is excluded from reviewers" ;; *) ok "author persona is excluded from reviewers" ;; esac
case "$html" in *'<pre class="persona-brief">'*) no "no persona brief when the file is absent" ;; *) ok "no persona brief when the file is absent" ;; esac

printf '\n== persona brief inlining ==\n'
mkdir -p "$LKML_MAILBOX_ROOT/render-fixture/personas"
# Frontmatter exactly as the shipped persona files carry it: its
# harness/model are the persona's defaults, which under --model-override
# are the WRONG harness/model for this version's messages, so the block
# must not be printed next to the message headers' line above it.
printf '%s\n' '---' 'persona: core' 'role: reviewer' 'harness: claude' 'model: opus' '---' '' \
    'Core reviewer brief.' '<script>alert(2)</script>' 'A & B' \
    > "$LKML_MAILBOX_ROOT/render-fixture/personas/core.md"
printf '%s\n' 'Not this time.' > "$work/nak.txt"
"$mailbox" post render-fixture --from core --reply-to "$patch_id" --file "$work/nak.txt" \
    --tags NAK --harness test --model fixture >/dev/null 2>/dev/null
persona_html="$work/persona.html"
python3 "$renderer" "$LKML_MAILBOX_ROOT/render-fixture" -o "$persona_html"
phtml="$(<"$persona_html")"
contains "persona brief is inlined" "$phtml" '<pre class="persona-brief">Core reviewer brief.'
case "$phtml" in *'<pre class="persona-brief">---'*) no "frontmatter is not inlined verbatim" ;; *) ok "frontmatter is not inlined verbatim" ;; esac
case "$phtml" in *'persona: core'*) no "frontmatter persona field is stripped" ;; *) ok "frontmatter persona field is stripped" ;; esac
case "$phtml" in *'harness: claude'*) no "frontmatter harness field is stripped" ;; *) ok "frontmatter harness field is stripped" ;; esac
case "$phtml" in *'model: opus'*) no "frontmatter model field is stripped" ;; *) ok "frontmatter model field is stripped" ;; esac
contains "persona brief is html-escaped (script)" "$phtml" '&lt;script&gt;alert(2)&lt;/script&gt;'
contains "persona brief is html-escaped (ampersand)" "$phtml" 'A &amp; B'
case "$phtml" in *'<script>alert(2)</script>'*) no "persona brief script payload is never raw" ;; *) ok "persona brief script payload is never raw" ;; esac
contains "reviewer rollup counts NAK" "$phtml" '<span>1 NAK</span>'
# The reviewer's reproduction: the same persona then signs off the same
# patch. The matrix cell already rendered R; the rollup must stop
# reporting the withdrawn NAK as outstanding.
printf '%s\n' 'Reviewed-by: The Reviewer' > "$work/review2.txt"
"$mailbox" post render-fixture --from core --reply-to "$patch_id" --file "$work/review2.txt" \
    --tags Reviewed-by --harness test --model fixture >/dev/null 2>/dev/null
after_html="$work/after.html"
python3 "$renderer" "$LKML_MAILBOX_ROOT/render-fixture" -o "$after_html"
ahtml="$(<"$after_html")"
contains "message count keeps counting every post" "$ahtml" '<span>3 messages</span>'
contains "superseding Reviewed-by is counted" "$ahtml" '<span>1 Reviewed-by</span>'
case "$ahtml" in *'<span>1 NAK</span>'*) no "withdrawn NAK is not reported as open" ;; *) ok "withdrawn NAK is not reported as open" ;; esac

printf '\n== persona brief containment ==\n'
# The persona header comes verbatim out of the .msg file; a hand-written
# message can set it to a traversal or absolute path. Neither may pull a
# file outside <series>/personas/ into the page.
printf '%s\n' 'TRAVERSAL LEAK CANARY' > "$LKML_MAILBOX_ROOT/traversal.md"
printf '%s\n' 'ABSOLUTE LEAK CANARY' > "$work/absolute.md"
"$mailbox" post render-fixture --from "../../traversal" --reply-to "$patch_id" \
    --file "$work/review.txt" --harness test --model fixture >/dev/null 2>/dev/null
"$mailbox" post render-fixture --from "$work/absolute" --reply-to "$patch_id" \
    --file "$work/review.txt" --harness test --model fixture >/dev/null 2>/dev/null
contain_html="$work/contain.html"
python3 "$renderer" "$LKML_MAILBOX_ROOT/render-fixture" -o "$contain_html"
chtml="$(<"$contain_html")"
case "$chtml" in *'TRAVERSAL LEAK CANARY'*) no "traversal persona does not leak a brief" ;; *) ok "traversal persona does not leak a brief" ;; esac
case "$chtml" in *'ABSOLUTE LEAK CANARY'*) no "absolute-path persona does not leak a brief" ;; *) ok "absolute-path persona does not leak a brief" ;; esac
contains "legit brief still inlined alongside" "$chtml" '<pre class="persona-brief">Core reviewer brief.'

printf '\n== reviewers box is omitted when empty ==\n'
# A freshly init-ed series (no replies yet) must not render an empty
# labelled box.
"$mailbox" init render-empty --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness test --model fixture >/dev/null 2>/dev/null
empty_html="$work/empty.html"
python3 "$renderer" "$LKML_MAILBOX_ROOT/render-empty" -o "$empty_html"
ehtml="$(<"$empty_html")"
case "$ehtml" in *'<div class="reviewers"'*) no "no reviewers box on a fresh series" ;; *) ok "no reviewers box on a fresh series" ;; esac
contains "fresh series still reports zero reviewers" "$ehtml" '<span>0 reviewers</span>'
# .reviewers .counts{display:flex;gap:1rem} restated only what the global
# .counts rule already sets; make sure it does not come back.
case "$html" in *'.reviewers .counts'*) no "no dead .reviewers .counts rule" ;; *) ok "no dead .reviewers .counts rule" ;; esac

printf '\n== text mode: thread walk and message rendering ==\n'
# The agent view: same thread selection and ordering as the HTML render,
# as plain text on stdout.
text_out="$work/text.txt"
python3 "$renderer" --text "$LKML_MAILBOX_ROOT/render-fixture" > "$text_out"
ttext="$(<"$text_out")"
contains "text: series header is name and version" "$ttext" 'render-fixture v1'
contains "text: header shows the same counts as the HTML header" "$ttext" '2 patches · 9 replies'
contains "text: cover is message #1 at depth 0" "$ttext" '== #1 · depth 0'
contains "text: patch is numbered and links its parent" "$ttext" '== #2 · reply to #1 · depth 1'
contains "text: reply carries its number, parent and depth" "$ttext" '== #3 · reply to #2 · depth 2'
contains "text: From line carries persona, harness and model" "$ttext" '[persona: core · harness: test · model: fixture]'
contains "text: tags line is plain text" "$ttext" 'Tags: Reviewed-by'
contains "text: cover letter body is verbatim" "$ttext" 'fenced *markdown*'
contains "text: reply body is verbatim, in full" "$ttext" 'Reviewed-by: The Reviewer'
contains "text: orphan reply is in the thread too" "$ttext" 'orphan body'
contains "text: patch keeps its commit message" "$ttext" 'Commit message for patch one.'
contains "text: patch diff is summarized, not inlined" "$ttext" '[diff omitted: 6 lines -- see the series branch]'
case "$ttext" in *'+one'*) no "patch diff lines are not inlined in text mode" ;; *) ok "patch diff lines are not inlined in text mode" ;; esac
# The fixture's cover subject and body deliberately carry a <script>
# payload, so a whole-output check would false-positive. Check the lines
# that carry markup in HTML mode: the header and each message header.
if grep -F 'render-fixture v1' "$text_out" | grep -q '<'; then no "header line has no HTML tags"; else ok "header line has no HTML tags"; fi
if grep -F '== #' "$text_out" | grep -q '<'; then no "message headers have no HTML tags"; else ok "message headers have no HTML tags"; fi
case "$ttext" in *'<article'*|*'<table'*|*'<html'*) no "no HTML structure in the text output" ;; *) ok "no HTML structure in the text output" ;; esac
if python3 "$renderer" --text render-fixture-dir-does-not-exist >/dev/null 2>/dev/null; then
    no "missing mailbox fails in text mode"
else
    ok "missing mailbox fails in text mode"
fi

printf '\n== text mode: tally and reviewers ==\n'
contains "text: header count line includes reviewers" "$ttext" '2 patches · 9 replies · 5 reviewers'
contains "text: tally legend is plain text" "$ttext" 'Latest tag per reviewer per patch. R reviewed, A acked, C changes requested, ? question, N nak.'
contains "text: patch rows use the HTML row labels" "$ttext" 'Patch v1 1/2'
contains "text: second patch row is labeled too" "$ttext" 'Patch v1 2/2'
# The tagged patch's row carries the latest tag per reviewer: R for
# core's superseding Reviewed-by, T for the CI bot, · where untagged.
patch_row="$(grep -F 'Patch v1 1/2' "$text_out" | head -1)"
contains "text: tally row carries per-reviewer letters" "$patch_row" 'R'
contains "text: tally row carries the Tested-by letter" "$patch_row" 'T'
contains "text: untagged reviewer is a dot in the row" "$patch_row" '·'
contains "text: untagged reviewer still gets a column" "$ttext" 'newcomer'
contains "text: reviewers section is present" "$ttext" 'reviewers'
contains "text: reviewer block has display name and slug" "$ttext" 'Core (core)'
contains "text: reviewer block carries harness and model" "$ttext" 'test · fixture'
contains "text: reviewer block counts messages" "$ttext" '3 messages'
contains "text: reviewer block counts open Reviewed-by" "$ttext" '1 Reviewed-by'
case "$ttext" in *'1 NAK'*) no "withdrawn NAK is not reported open in text mode" ;; *) ok "withdrawn NAK is not reported open in text mode" ;; esac
contains "text: brief is a pointer, not inlined" "$ttext" 'brief: render-fixture/personas/core.md'
case "$ttext" in *'Core reviewer brief.'*) no "persona brief is not inlined in text mode" ;; *) ok "persona brief is not inlined in text mode" ;; esac
# The same line-level markup check for the tally table's rows, which
# carry the most markup in HTML mode.
if grep -F 'Patch v1 1/2' "$text_out" | grep -q '<'; then no "tally rows have no HTML tags"; else ok "tally rows have no HTML tags"; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
