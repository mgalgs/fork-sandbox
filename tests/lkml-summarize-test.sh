#!/usr/bin/env bash
# lkml-summarize-test.sh — Exercise lkml-summarize.sh's flag/env parsing
# and tier resolution against a real (throwaway) mailbox, before the
# launch pipeline lands.
#
# Usage: tests/lkml-summarize-test.sh
#
# No sandbox, no bwrap, no real agent: the "stub the external command on
# PATH" pattern tests/lkml-revise-test.sh uses is not needed yet --
# this slice exercises everything up to the launch, and the resolved
# tier specs are asserted on the script's own stderr line naming them.
#
# Covers:
#   - argument validation: unknown option, missing --project,
#     non-integer --version, whitespace in a tier spec.
#   - tier resolution order: flag beats env beats shipped default
#     (high=claude/opus, low=claude/sonnet), read from the env file the
#     same way fork-sandbox.sh reads its ~/.config env files.
#   - a bare harness (no /model) is passed through BARE, and a combined
#     harness/model passes through verbatim.
#   - loud failures: missing series, empty mailbox, no version ledger,
#     a version with no recorded branch.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
summarize="$repo_dir/scripts/lkml-summarize.sh"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed; lkml-summarize.sh needs it to read the version ledger."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

work="$(mktemp -d)"; tmpdirs+=("$work")
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
cd "$work" || exit 1

# A trivial stub: this slice exercises everything BEFORE the launch, so
# the stub only has to exist on PATH. The pipeline commit replaces it
# with the fabricating stub tests/lkml-round-test.sh uses.
stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
cat > "$stub_bin/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub fork-sandbox.sh: not expected to be called in this slice" >&2
exit 1
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

# A throwaway repo for --project: the series' tip branch the ledger will
# record. The launch pipeline (next commit) is what would check it out.
project_dir="$(mktemp -d)"; tmpdirs+=("$project_dir")
git -C "$project_dir" init -q
git -C "$project_dir" config user.email test@example.invalid
git -C "$project_dir" config user.name Test
printf 'series tip tree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm "series tip"
git -C "$project_dir" branch -m main 2>/dev/null || true

# A minimal series with a real thread to summarize.
printf 'Add the frobnicator\n\nBody.\n' > cover.txt
mkdir patches
printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff\n' > patches/0001.patch
"$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus >/dev/null 2>&1
patch_id="$("$mailbox" tree widget-frob | awk 'NR==3{print $1}')"
printf 'the frob looks flaky under load\n' > r.txt
"$mailbox" post widget-frob --from core --reply-to "$patch_id" --file r.txt \
    --tags Changes-requested --harness claude --model opus >/dev/null 2>&1
printf '{"version":1,"branch":"main"}\n' > "$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"

# run <label> <expect_zero:0|1> <args...> ; runs the script, records the
# exit-code check, and leaves the combined output in $out_file. Env
# overrides (e.g. LKML_SUMMARIZE_ENV_FILE) are passed by the caller as
# `VAR=value run ...`, so they reach the script as environment.
out_file="$work/last-output"
run() {
    local label="$1" expect_zero="$2" rc=0
    shift 2
    PATH="$stub_bin:$PATH" "$summarize" "$@" > "$out_file" 2>&1 || rc=$?
    if [[ "$expect_zero" == 0 ]]; then
        if (( rc == 0 )); then ok "$label: exits 0"; else no "$label: exits 0" "exit $rc: $(cat "$out_file")"; fi
    else
        if (( rc != 0 )); then ok "$label: exits non-zero"; else no "$label: exits non-zero" "exit 0: $(cat "$out_file")"; fi
    fi
}

printf '\n== argument validation ==\n'
run "unknown option" 1 widget-frob --project "$project_dir" --bogus x
contains "unknown option is refused and named" "$(cat "$out_file")" "--bogus"
run "missing --project" 1 widget-frob
contains "missing --project is refused and named" "$(cat "$out_file")" "--project"
run "non-integer --version" 1 widget-frob --project "$project_dir" --version v1
contains "non-integer --version is refused" "$(cat "$out_file")" "plain integer"
run "whitespace tier spec" 1 widget-frob --project "$project_dir" --low "claude /sonnet"
contains "whitespace in a tier spec is refused" "$(cat "$out_file")" "whitespace"

printf '\n== loud failures before any launch ==\n'
run "missing series" 1 nosuchseries --project "$project_dir"
contains "missing series fails loudly and is named" "$(cat "$out_file")" "nosuchseries"
mkdir -p "$LKML_MAILBOX_ROOT/empty-series/cur"
run "empty mailbox" 1 empty-series --project "$project_dir"
contains "an empty --text render fails loudly" "$(cat "$out_file")" "empty"
mkdir patches2
printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff\n' > patches2/0001.patch
printf 'Add the noledger thing\n\nBody.\n' > cover2.txt
"$mailbox" init nolegacy --cover cover2.txt --patches patches2 --from author \
    --harness claude --model opus >/dev/null 2>&1
run "no version ledger" 1 nolegacy --project "$project_dir"
contains "no version ledger fails loudly and names the file" "$(cat "$out_file")" "versions.jsonl"
run "unrecorded version" 1 widget-frob --project "$project_dir" --version 3
contains "unrecorded version fails loudly and is named" "$(cat "$out_file")" "v3"
contains "the recorded versions are listed" "$(cat "$out_file")" "Recorded versions: 1"

printf '\n== tier resolution: flag > env > default ==\n'
env_file="$work/lkml-summarize.env"
printf 'LKML_SUMMARIZE_HIGH=pi-local\nLKML_SUMMARIZE_LOW=pi-local/nano-local\n' > "$env_file"

run "shipped defaults" 1 widget-frob --project "$project_dir"
contains "default high tier is claude/opus" "$(cat "$out_file")" "high: claude/opus"
contains "default low tier is claude/sonnet" "$(cat "$out_file")" "low: claude/sonnet"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "env file, no flags" 1 widget-frob --project "$project_dir"
contains "env high tier: a bare harness passes through bare, not expanded" \
    "$(cat "$out_file")" "high: pi-local)"
contains "env low tier: a combined harness/model passes through verbatim" \
    "$(cat "$out_file")" "low: pi-local/nano-local,"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "both flags beat env" 1 widget-frob --project "$project_dir" \
    --high codex/fast --low claude/haiku
contains "flag --high wins over the env file" "$(cat "$out_file")" "high: codex/fast"
contains "flag --low wins over the env file" "$(cat "$out_file")" "low: claude/haiku"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "one flag, one env" 1 widget-frob --project "$project_dir" \
    --high codex/fast
contains "a flagged tier comes from the flag" "$(cat "$out_file")" "high: codex/fast"
contains "an unflagged tier comes from the env file" "$(cat "$out_file")" "low: pi-local/nano-local,"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
