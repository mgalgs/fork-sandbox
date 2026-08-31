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
"$mailbox" post render-fixture --from core --reply-to "$patch_id" --file "$work/review.txt" \
    --tags Reviewed-by --harness test --model fixture >/dev/null 2>/dev/null
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
if cmp -s "$stdout" "$custom"; then ok "output file matches stdout"; else no "output file matches stdout"; fi
if python3 -m py_compile "$renderer"; then ok "renderer compiles"; else no "renderer compiles"; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
