#!/usr/bin/env bash
# fork-sandbox-dispatcher-test.sh — Exercise the git-style fork-sandbox router
#
# Usage: tests/fork-sandbox-dispatcher-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
dispatcher="$repo_dir/scripts/fork-sandbox"

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

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
cp "$dispatcher" "$tmp/fork-sandbox"
chmod +x "$tmp/fork-sandbox"

for target in fork-sandbox.sh fork-sandbox-status.sh fork-sandbox-say.sh \
    fork-sandbox-k8s.sh sandbox-run-log.py; do
    cat > "$tmp/$target" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}"
for arg in "$@"; do printf '%s\n' "$arg"; done
STUB
    chmod +x "$tmp/$target"
done

run_case() {
    local label="$1" expected="$2"
    shift 2
    local actual status
    actual="$("$tmp/fork-sandbox" "$@" 2>"$tmp/err")"
    status=$?
    if ((status == 0)); then
        check "$label" "$expected" "$actual"
    else
        no "$label" "expected exit 0, got $status"
    fi
}

printf '== fork-sandbox dispatcher ==\n'
run_case 'run passes arguments' $'fork-sandbox.sh\nproj\nhandoff' run proj handoff
run_case 'run preserves option order' \
    $'fork-sandbox.sh\n--harness\ncodex\n--model\nluna\nproj\nhandoff' \
    run --harness codex --model luna proj handoff
run_case 'status passes arguments' $'fork-sandbox-status.sh\n--monitor\n/run/dir' \
    status --monitor /run/dir
run_case 'say preserves spaces' $'fork-sandbox-say.sh\n/run/dir\ntwo words' \
    say /run/dir 'two words'
"$tmp/fork-sandbox" say /run/dir '' > "$tmp/empty-actual" 2> "$tmp/err"
printf '%s\n%s\n%s\n' fork-sandbox-say.sh /run/dir '' > "$tmp/empty-expected"
if cmp -s "$tmp/empty-expected" "$tmp/empty-actual"; then
    ok 'empty argument survives'
else
    no 'empty argument survives'
fi
run_case 'k8s sub-verb passes through' \
    $'fork-sandbox-k8s.sh\nsubmit\n--branch\nx\nproj\nhandoff' \
    k8s submit --branch x proj handoff
run_case 'log passes arguments' $'sandbox-run-log.py\nlist\n--days\n14' \
    log list --days 14
run_case 'configure prepends configure' $'fork-sandbox.sh\nconfigure\n--dry-run' \
    configure --dry-run
run_case 'help after verb reaches target' $'fork-sandbox.sh\n--help' run --help

help="$("$tmp"/fork-sandbox --help)"
if [[ "$help" == *'run'* && "$help" == *'status'* && "$help" == *'say'* &&
    "$help" == *'configure'* && "$help" == *'k8s'* && "$help" == *'log'* ]]; then
    ok '--help names all verbs'
else
    no '--help names all verbs' "$help"
fi
check '-h matches --help' "$help" "$("$tmp"/fork-sandbox -h)"

if "$tmp/fork-sandbox" > "$tmp/no-args-out" 2> "$tmp/no-args-err"; then
    no 'no arguments exits 2'
else
    check 'no arguments exits 2' 2 "$?"
fi
check 'no arguments uses stderr' '' "$(cat "$tmp/no-args-out")"
if [[ -s "$tmp/no-args-err" ]]; then
    ok 'no arguments prints usage on stderr'
else
    no 'no arguments prints usage on stderr'
fi

if "$tmp/fork-sandbox" frobnicate > /dev/null 2> "$tmp/unknown-err"; then
    no 'unknown verb exits 2'
else
    check 'unknown verb exits 2' 2 "$?"
fi
if grep -Fq "unknown verb 'frobnicate'" "$tmp/unknown-err"; then
    ok 'unknown verb names offender'
else
    no 'unknown verb names offender' "$(cat "$tmp/unknown-err")"
fi

printf '#!/usr/bin/env bash\nexit 3\n' > "$tmp/fork-sandbox.sh"
chmod +x "$tmp/fork-sandbox.sh"
if "$tmp/fork-sandbox" run > /dev/null 2> "$tmp/err"; then
    no 'target exit code propagates'
else
    check 'target exit code propagates' 3 "$?"
fi

rm "$tmp/fork-sandbox-status.sh"
if "$tmp/fork-sandbox" status > /dev/null 2> "$tmp/missing-err"; then
    no 'missing target exits 127'
else
    check 'missing target exits 127' 127 "$?"
fi
if grep -Fq 'cannot execute fork-sandbox-status.sh' "$tmp/missing-err"; then
    ok 'missing target names script'
else
    no 'missing target names script' "$(cat "$tmp/missing-err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
