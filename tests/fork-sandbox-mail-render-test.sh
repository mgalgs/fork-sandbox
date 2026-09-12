#!/usr/bin/env bash
# fork-sandbox-mail-render-test.sh — Exercise fork-sandbox-mail-render.py
# against real fork-sandbox-mail.sh fixtures: threading shape, escaping,
# both HTML themes, attachment names, --thread selection, --text mode,
# and defensive handling of malformed messages / dot-dirs.
#
# Usage: tests/fork-sandbox-mail-render-test.sh
#
# Runs entirely offline against a temp FORK_SANDBOX_MAIL_ROOT -- never the
# real default path.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
mail="$repo_dir/scripts/fork-sandbox-mail.sh"
renderer="$repo_dir/scripts/fork-sandbox-mail-render.py"

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

not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' unexpectedly found" ;;
        *) ok "$label" ;;
    esac
}

count_of() {
    local label="$1" haystack="$2" needle="$3" expected="$4" got
    got="$(grep -o -F -- "$needle" <<< "$haystack" | wc -l)"
    if [[ "$got" -eq "$expected" ]]; then
        ok "$label"
    else
        no "$label" "expected $expected occurrence(s) of '$needle', got $got"
    fi
}

new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT

printf '\n== fixture setup ==\n'

root_id="$("$mail" send --from @alice --to @bob --subject 'Hello & welcome' \
    --body - <<< 'root body text' 2>/dev/null)"
check_rc=$?
if [[ -n "$root_id" && $check_rc -eq 0 ]]; then ok "fixture: root message sent"; else no "fixture: root message sent"; fi

reply1_id="$("$mail" reply --from @bob --reply-to "$root_id" \
    --body - <<< $'a script payload: <script>alert(1)</script>' 2>/dev/null)"
if [[ -n "$reply1_id" ]]; then ok "fixture: first reply sent"; else no "fixture: first reply sent"; fi

printf 'attachment bytes, never rendered\n' > attach.txt
reply2_id="$("$mail" reply --from @alice --reply-to "$reply1_id" --attach attach.txt \
    --body - <<< 'nested reply body' 2>/dev/null)"
if [[ -n "$reply2_id" ]]; then ok "fixture: nested reply sent"; else no "fixture: nested reply sent"; fi

other_id="$("$mail" send --from @carol --to @dave --subject 'Second thread' \
    --body - <<< 'unrelated thread body' 2>/dev/null)"
if [[ -n "$other_id" ]]; then ok "fixture: second thread sent"; else no "fixture: second thread sent"; fi

thread_dir="$FORK_SANDBOX_MAIL_ROOT/threads/$root_id"

# A hand-crafted orphan: fork-sandbox-mail.sh refuses --reply-to a
# nonexistent id, so the only way to get an orphan into the real store's
# shape is to write one directly, following the exact header block the
# store itself writes (see fork-sandbox-mail.sh's cmd_reply).
orphan_id="11111111-1111-1111-1111-111111111111"
cat > "$thread_dir/004-$orphan_id.msg" <<EOF
Message-ID: $orphan_id
Thread-ID: $root_id
Date: Mon, 01 Jan 2024 00:00:00 +0000
From: @newcomer
To: @alice
Subject: Re: Hello & welcome
In-Reply-To: 22222222-2222-2222-2222-222222222222
References: 22222222-2222-2222-2222-222222222222
X-Hops: 8

an orphaned reply
EOF
ok "fixture: hand-crafted orphan message written"

# A malformed .msg: no blank line separating headers from body at all.
printf 'not a valid mail message, no header block here\n' > "$thread_dir/005-badfile.msg"
ok "fixture: malformed message written"

# A dot-dir under threads/ must be ignored entirely, like .postmaster/.
mkdir -p "$FORK_SANDBOX_MAIL_ROOT/threads/.postmaster"
printf 'router state, not mail\n' > "$FORK_SANDBOX_MAIL_ROOT/threads/.postmaster/state.txt"
ok "fixture: dot-dir under threads/ written"

printf '\n== html: all threads ==\n'
html_all="$work/all.html"
if python3 "$renderer" "$FORK_SANDBOX_MAIL_ROOT" -o "$html_all" 2>"$work/render.err"; then
    ok "renders all threads exit 0"
else
    no "renders all threads exit 0" "$(cat "$work/render.err")"
fi
html="$(<"$html_all")"

if [[ "$(grep -c -o '<!doctype html>' "$html_all")" -eq 1 ]]; then ok "starts with doctype"; else no "starts with doctype"; fi
contains "index has a row for the first thread" "$html" "Hello &amp; welcome"
contains "index has a row for the second thread" "$html" "Second thread"
count_of "index has exactly one row per thread (thread-id anchors)" "$html" 'id="thread-' 2
contains "ampersand subject is escaped" "$html" 'Hello &amp; welcome'
not_contains "raw ampersand-subject never appears unescaped" "$html" '<h2>Hello & welcome</h2>'
contains "script payload is escaped" "$html" '&lt;script&gt;alert(1)&lt;/script&gt;'
not_contains "script payload is never raw" "$html" '<script>alert(1)</script>'
contains "light/dark tokens declared" "$html" '--ground:'
contains "dark theme via prefers-color-scheme" "$html" '@media (prefers-color-scheme: dark)'
contains "orphan marker rendered" "$html" '<span class="badge orphan">orphaned</span>'
count_of "orphan marker appears exactly once" "$html" 'class="badge orphan"' 1
contains "attachment name is listed" "$html" 'attachments/attach.txt'
not_contains "attachment bytes are never embedded" "$html" 'attachment bytes, never rendered'
not_contains "no data: URI is ever embedded" "$html" 'data:'
contains "malformed message renders an error card" "$html" 'class="msg error"'
contains "malformed message error names the file" "$html" '005-badfile.msg'
not_contains "dot-dir under threads/ is not rendered as a thread" "$html" 'router state, not mail'
not_contains "dot-dir under threads/ leaves no stray index row" "$html" '.postmaster'

printf '\n== html: --thread selects one ==\n'
html_one="$work/one.html"
python3 "$renderer" "$FORK_SANDBOX_MAIL_ROOT" --thread "$other_id" -o "$html_one" 2>/dev/null
html_one_content="$(<"$html_one")"
contains "--thread renders the selected thread" "$html_one_content" "Second thread"
not_contains "--thread omits the other thread" "$html_one_content" "Hello &amp; welcome"

printf '\n== --text mode ==\n'
text_all="$(python3 "$renderer" --text "$FORK_SANDBOX_MAIL_ROOT" 2>"$work/text.err")"
text_rc=$?
if [[ $text_rc -eq 0 ]]; then ok "--text exits cleanly"; else no "--text exits cleanly" "$(cat "$work/text.err")"; fi
contains "--text: verbatim body present" "$text_all" 'root body text'
contains "--text: script payload is verbatim, not escaped" "$text_all" '<script>alert(1)</script>'
contains "--text: separator between messages" "$text_all" $'\n---\n'
contains "--text: nested reply is indented" "$text_all" $'\n    From: @alice'
contains "--text: orphan marker present" "$text_all" '[orphaned]'
not_contains "--text: no Date header (token budget)" "$text_all" $'\nDate:'
contains "--text: Hops header present" "$text_all" 'Hops: 8'
contains "--text: malformed message reported, not silently dropped" "$text_all" '[error:'

if python3 "$renderer" --text "$FORK_SANDBOX_MAIL_ROOT" -o "$work/should-fail.html" 2>/dev/null; then
    no "--text refuses -o/--output"
else
    ok "--text refuses -o/--output"
fi

printf '\n== exit codes ==\n'
if python3 "$renderer" "$work/no-such-root" >/dev/null 2>"$work/missing.err"; then
    no "missing mail root fails"
else
    ok "missing mail root fails"
fi
if [[ -s "$work/missing.err" ]]; then ok "missing mail root prints a diagnostic"; else no "missing mail root prints a diagnostic"; fi

if python3 "$renderer" "$FORK_SANDBOX_MAIL_ROOT" --thread does-not-exist >/dev/null 2>"$work/unknown.err"; then
    no "unknown thread id fails"
else
    ok "unknown thread id fails"
fi
if [[ -s "$work/unknown.err" ]]; then ok "unknown thread id prints a diagnostic"; else no "unknown thread id prints a diagnostic"; fi

printf '\n== misc ==\n'
if python3 -m py_compile "$renderer"; then ok "renderer compiles"; else no "renderer compiles"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
