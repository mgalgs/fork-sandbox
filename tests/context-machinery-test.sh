#!/usr/bin/env bash
# context-machinery-test.sh -- Exercise statusline-stash.sh, context-usage.sh
# and context-nudge.py: the stash writer Claude Code's statusLine slot
# invokes, and the two readers (a manual check, a UserPromptSubmit hook)
# that depend on it agreeing where to look.
#
# Usage: tests/context-machinery-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
stash="$repo_dir/scripts/statusline-stash.sh"
usage="$repo_dir/scripts/context-usage.sh"
nudge="$repo_dir/scripts/context-nudge.py"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

# Every case gets its own stash dir, never the real /tmp/claude-$UID.
new_dir() { mktemp -d "$scratch/nudge-dir.XXXXXX"; }

# --- statusline-stash.sh: the stash write ------------------------------------

echo "== the stash is written with all four fields, [1m] survives =="
dir1="$(new_dir)"
payload1='{"session_id":"sid-1m","model":{"id":"claude-opus-5-5[1m]","display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000,"used_percentage":42.7}}'
printf '%s' "$payload1" | CONTEXT_NUDGE_DIR="$dir1" "$stash" >/dev/null; rc1=$?
if (( rc1 == 0 )); then ok "exits 0"; else no "exits 0" "rc=$rc1"; fi
stashed1="$dir1/ctx-sid-1m.json"
if [[ -f "$stashed1" ]]; then
    ok "stash file exists"
    got="$(jq -c . "$stashed1")"
    want='{"session_id":"sid-1m","model":"claude-opus-5-5[1m]","context_window_size":1000000,"used_percentage":42.7}'
    if [[ "$got" == "$want" ]]; then
        ok "stash has exactly the four fields, [1m] intact"
    else
        no "stash has exactly the four fields, [1m] intact" "got: $got"
    fi
else
    no "stash file exists" "$stashed1 missing"
fi

echo "== no session_id: no stash file, but a line is still printed =="
dir2="$(new_dir)"
payload2='{"model":{"id":"claude-sonnet-5"},"context_window":{"context_window_size":200000,"used_percentage":10}}'
out2="$(printf '%s' "$payload2" | CONTEXT_NUDGE_DIR="$dir2" "$stash")"; rc2=$?
if (( rc2 == 0 )) && [[ -n "$out2" ]]; then ok "exits 0 and prints a line"; else no "exits 0 and prints a line" "rc=$rc2 out=$out2"; fi
if [[ -z "$(ls -A "$dir2" 2>/dev/null)" ]]; then
    ok "no stash file was written"
else
    no "no stash file was written" "found $(ls -A "$dir2")"
fi

echo "== default line's format =="
dir3="$(new_dir)"
payload3='{"session_id":"sid-3","model":{"id":"claude-sonnet-5","display_name":"Sonnet 5"},"context_window":{"context_window_size":200000,"used_percentage":12.4}}'
out3="$(printf '%s' "$payload3" | CONTEXT_NUDGE_DIR="$dir3" "$stash")"
if [[ "$out3" == "Sonnet 5 | 12% of 200k" ]]; then
    ok "default line, with a percentage"
else
    no "default line, with a percentage" "got: $out3"
fi

dir4="$(new_dir)"
payload4='{"session_id":"sid-4","model":{"id":"claude-sonnet-5"},"context_window":{"context_window_size":200000,"used_percentage":null}}'
out4="$(printf '%s' "$payload4" | CONTEXT_NUDGE_DIR="$dir4" "$stash")"
if [[ "$out4" == "claude-sonnet-5 | 0% of 200k" ]]; then
    ok "default line, with a null percentage"
else
    no "default line, with a null percentage" "got: $out4"
fi

dir4b="$(new_dir)"
payload4b='{"session_id":"sid-4b","model":{"id":"claude-sonnet-5"},"context_window":{}}'
out4b="$(printf '%s' "$payload4b" | CONTEXT_NUDGE_DIR="$dir4b" "$stash")"
if [[ "$out4b" == "claude-sonnet-5 | 0% of 200k" ]]; then
    ok "default line, with an absent window, defaults to 200000"
else
    no "default line, with an absent window, defaults to 200000" "got: $out4b"
fi

echo "== a display command receives the exact stdin bytes, exit status passed through =="
dir5="$(new_dir)"
stub="$scratch/cat-stub.sh"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
cat >"$1"
exit 7
STUB
chmod +x "$stub"
payload5='{"session_id":"sid-5","model":{"id":"m"},"context_window":{}}'
captured="$scratch/captured.json"
printf '%s' "$payload5" | CONTEXT_NUDGE_DIR="$dir5" "$stash" "$stub" "$captured"
rc5=$?
if (( rc5 == 7 )); then ok "exit status of the display command is passed through"; else no "exit status of the display command is passed through" "rc=$rc5"; fi
if [[ "$(cat "$captured" 2>/dev/null)" == "$payload5" ]]; then
    ok "the display command receives the exact stdin bytes"
else
    no "the display command receives the exact stdin bytes" "got: $(cat "$captured" 2>/dev/null)"
fi
if [[ -f "$dir5/ctx-sid-5.json" ]]; then
    ok "the stash still gets written when a display command is given"
else
    no "the stash still gets written when a display command is given" "$dir5/ctx-sid-5.json missing"
fi

echo "== an unwritable stash dir still prints the line and exits 0 =="
parent="$scratch/locked-parent"
mkdir -p "$parent"
chmod 500 "$parent"
unwritable_dir="$parent/nudge"
payload6='{"session_id":"sid-6","model":{"id":"m"},"context_window":{"context_window_size":200000,"used_percentage":5}}'
out6="$(printf '%s' "$payload6" | CONTEXT_NUDGE_DIR="$unwritable_dir" "$stash")"; rc6=$?
chmod 700 "$parent"
if (( rc6 == 0 )) && [[ -n "$out6" ]]; then
    ok "unwritable stash dir: still exits 0 and prints a line"
else
    no "unwritable stash dir: still exits 0 and prints a line" "rc=$rc6 out=$out6"
fi

# --- context-usage.sh ---------------------------------------------------------

echo "== context-usage.sh reads a stash and formats it =="
dir7="$(new_dir)"
payload7='{"session_id":"sid-7","model":{"id":"claude-sonnet-5"},"context_window":{"context_window_size":200000,"used_percentage":33.3}}'
printf '%s' "$payload7" | CONTEXT_NUDGE_DIR="$dir7" "$stash" >/dev/null
out7="$(CONTEXT_NUDGE_DIR="$dir7" "$usage" sid-7)"; rc7=$?
if (( rc7 == 0 )) && [[ "$out7" == "33.3% of 200000 (claude-sonnet-5)" ]]; then
    ok "context-usage.sh prints <pct>% of <window> (<model>)"
else
    no "context-usage.sh prints <pct>% of <window> (<model>)" "rc=$rc7 out=$out7"
fi

echo "== context-usage.sh with no reading exits 1 with a note =="
dir8="$(new_dir)"
out8="$(CONTEXT_NUDGE_DIR="$dir8" "$usage" sid-does-not-exist 2>&1)"; rc8=$?
if (( rc8 == 1 )) && [[ -n "$out8" ]]; then
    ok "context-usage.sh with no reading exits 1 with a note"
else
    no "context-usage.sh with no reading exits 1 with a note" "rc=$rc8 out=$out8"
fi

# --- context-nudge.py ---------------------------------------------------------

hook_json() {
    local sid="$1" pct="$2" transcript="${3:-/dev/null}"
    printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$transcript"
}

write_reading() {
    local dir="$1" sid="$2" pct="$3"
    local payload
    payload=$(printf '{"session_id":"%s","model":{"id":"claude-sonnet-5"},"context_window":{"context_window_size":200000,"used_percentage":%s}}' "$sid" "$pct")
    printf '%s' "$payload" | CONTEXT_NUDGE_DIR="$dir" "$stash" >/dev/null
}

echo "== context-nudge.py: silent below 35% =="
dir9="$(new_dir)"
write_reading "$dir9" sid-9 20
out9="$(hook_json sid-9 20 | CONTEXT_NUDGE_DIR="$dir9" python3 "$nudge")"
if [[ -z "$out9" ]]; then ok "silent below 35%"; else no "silent below 35%" "got: $out9"; fi

echo "== context-nudge.py: fires at 40% =="
dir10="$(new_dir)"
write_reading "$dir10" sid-10 40
out10="$(hook_json sid-10 40 | CONTEXT_NUDGE_DIR="$dir10" python3 "$nudge")"
if echo "$out10" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1; then
    ok "emits hookSpecificOutput.additionalContext at 40%"
else
    no "emits hookSpecificOutput.additionalContext at 40%" "got: $out10"
fi

echo "== context-nudge.py: silent on a second call at 40% (rate limit) =="
out10b="$(hook_json sid-10 40 | CONTEXT_NUDGE_DIR="$dir10" python3 "$nudge")"
if [[ -z "$out10b" ]]; then
    ok "silent on a second call at the same step"
else
    no "silent on a second call at the same step" "got: $out10b"
fi

echo "== context-nudge.py: fires again at 85% =="
write_reading "$dir10" sid-10 85
out10c="$(hook_json sid-10 85 | CONTEXT_NUDGE_DIR="$dir10" python3 "$nudge")"
if echo "$out10c" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1; then
    ok "fires again at a higher step (85%)"
else
    no "fires again at a higher step (85%)" "got: $out10c"
fi

echo "== context-nudge.py: re-arms after a reading under 30% =="
write_reading "$dir10" sid-10 20
out10d="$(hook_json sid-10 20 | CONTEXT_NUDGE_DIR="$dir10" python3 "$nudge")"
if [[ -z "$out10d" ]]; then
    ok "still silent right at the re-arm reading itself"
else
    no "still silent right at the re-arm reading itself" "got: $out10d"
fi
write_reading "$dir10" sid-10 40
out10e="$(hook_json sid-10 40 | CONTEXT_NUDGE_DIR="$dir10" python3 "$nudge")"
if echo "$out10e" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1; then
    ok "re-armed: fires again at 40% after dropping under 30%"
else
    no "re-armed: fires again at 40% after dropping under 30%" "got: $out10e"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
