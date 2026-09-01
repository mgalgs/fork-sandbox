#!/usr/bin/env bash
# lkml-summarize-test.sh — Exercise lkml-summarize.sh's flag/env
# parsing, tier resolution and the sequential two-tier launch/harvest
# pipeline, against a stub fork-sandbox.sh and a real (throwaway)
# mailbox.
#
# Usage: tests/lkml-summarize-test.sh
#
# Same "stub the external command on PATH" pattern
# tests/lkml-revise-test.sh and tests/lkml-round-test.sh use: the stub
# records each launch's argv, --task-meta and handoff, fabricates a
# run directory whose OUTBOX holds the tier's output file, writes
# summary.json immediately (so the wait loop never actually sleeps)
# and prints the same "  run dir:  <path>" line the real launcher does.
# It also creates the run's branch in the "origin" repo, standing in
# for what the real launcher's clone/fetch cycle leaves behind, so the
# branch cleanup under test has something to delete.
#
# Covers:
#   - argument validation: unknown option, missing --project,
#     non-integer --version, whitespace in a tier spec.
#   - tier resolution order: flag beats env beats shipped default
#     (high=claude/opus, low=claude/sonnet), and what each tier's
#     launch actually gets: a bare harness (no /model) passes through
#     BARE, a combined harness/model passes through verbatim.
#   - sequential low-then-high launches, the extraction intermediate
#     inline in the high tier's handoff, the tally section inline too.
#   - outbox harvest to results-v<N>.{json,md}, latest-version default,
#     --version pin, overwrite behavior.
#   - the Summary-section length warning.
#   - loud failures: missing series, empty --text render, no version
#     ledger, unrecorded version, a low run that leaves no results.json.

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

# A throwaway repo for --project: the series' tip branch the ledger
# records.
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

# The stub replaces fork-sandbox.sh entirely: no clone, no sandbox, no
# agent. It captures each launch, fabricates a run dir with the tier's
# outbox output and a ready summary.json, and creates the run's branch
# in the origin repo (what the real clone/fetch cycle would leave).
stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")
cat > "$stub_bin/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
task_meta=""
branch=""
i=0
while (( i < n )); do
    case "${args[$i]}" in
        --task-meta) task_meta="${args[$((i+1))]}" ;;
        --branch) branch="${args[$((i+1))]}" ;;
    esac
    i=$(( i + 1 ))
done
project="${args[$((n-2))]}"
handoff="${args[$((n-1))]}"
tier="$(printf '%s' "$task_meta" | jq -r '.tags[2]')"
{
    printf '%s\n' "${args[*]}"
    printf 'BRANCH=%s\n' "$branch"
} > "$STUB_CAPTURE_DIR/$tier.argv"
cp -- "$handoff" "$STUB_CAPTURE_DIR/$tier.handoff.md"
printf '%s\n' "$tier" >> "$STUB_CAPTURE_DIR/order"
git -C "$project" branch -f "$branch"

run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
mkdir -p "$run_dir/outbox"
case "$tier" in
    summarize-low)
        if [[ "${STUB_SKIP_JSON:-0}" != 1 ]]; then
            # ${STUB_JSON:-{}} would NOT work: bash closes the expansion at
            # the first brace, appending a literal "}" to every write.
            stub_json_default="{}"
            printf '%s\n' "${STUB_JSON:-$stub_json_default}" > "$run_dir/outbox/results.json"
        fi
        ;;
    summarize-high)
        printf '%s\n' "${STUB_MD:-}" > "$run_dir/outbox/results.md"
        ;;
esac
jq -n --arg clone_dir "$run_dir/clone" --arg branch "$branch" \
    '{clone_dir: $clone_dir, branch: $branch, commits: 0, fetched: true}' \
    > "$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  $run_dir"
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

# What the tiers "write" to their outboxes.
DEFAULT_JSON='{"series":"widget-frob","version":1,"cover":{"verdicts":{},"duplicates":[]},"patches":[{"subject":"[PATCH v1 1/1] frob: add core","verdicts":{"core":{"latest":{"tags":["Changes-requested"],"id":"deadbee"},"superseded":[]}},"defects":[{"severity":"high","claim":"frob looks flaky under load","status":"asserted","id":"deadbee"}],"responses":[],"open_questions":[],"duplicates":[]}]}'
DEFAULT_MD='# Summary
Frobnicator v1 has one open defect: flakiness under load (deadbee).

# Details
## Defects
- high: frob looks flaky under load (deadbee) -- asserted, unanswered.

## Next
Author to address the flakiness claim.'
capture_dir="$(mktemp -d)"; tmpdirs+=("$capture_dir")

# run <label> <expect_zero:0|1> <args...> ; runs the script with the
# stub defaults and leaves the combined output in $out_file. Env
# overrides (e.g. LKML_SUMMARIZE_ENV_FILE) are passed by the caller as
# `VAR=value run ...`, so they reach the script as environment.
out_file="$work/last-output"
run() {
    local label="$1" expect_zero="$2" rc=0
    shift 2
    PATH="$stub_bin:$PATH" \
        STUB_CAPTURE_DIR="$capture_dir" STUB_RUN_PREFIX="$run_prefix_dir" \
        STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
        "$summarize" "$@" > "$out_file" 2>&1 || rc=$?
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

run "shipped defaults" 0 widget-frob --project "$project_dir"
contains "default high tier is claude/opus" "$(cat "$out_file")" "high: claude/opus"
contains "default low tier is claude/sonnet" "$(cat "$out_file")" "low: claude/sonnet"
check "high launch gets the default combined harness/model verbatim" \
    "claude/opus" "$(sed -n 's/^.*--harness \([^ ]*\).*/\1/p' "$capture_dir/summarize-high.argv" | head -n1)"
check "low launch gets the default combined harness/model verbatim" \
    "claude/sonnet" "$(sed -n 's/^.*--harness \([^ ]*\).*/\1/p' "$capture_dir/summarize-low.argv" | head -n1)"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "env file, no flags" 0 widget-frob --project "$project_dir"
contains "env high tier: a bare harness passes through bare, not expanded" \
    "$(cat "$out_file")" "high: pi-local)"
contains "a bare pi-local reaches the launcher bare (no model invented)" \
    "$(cat "$capture_dir/summarize-high.argv")" "--harness pi-local --checkout"
case "$(cat "$capture_dir/summarize-high.argv")" in
    *--model*) no "a bare pi-local launch gets no --model" ;;
    *) ok "a bare pi-local launch gets no --model" ;;
esac
contains "a combined env harness/model reaches the launcher verbatim" \
    "$(cat "$capture_dir/summarize-low.argv")" "--harness pi-local/nano-local --checkout"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "both flags beat env" 0 widget-frob --project "$project_dir" \
    --high codex/fast --low claude/haiku
contains "flag --high wins over the env file" "$(cat "$out_file")" "high: codex/fast"
contains "flag --low wins over the env file" "$(cat "$out_file")" "low: claude/haiku"
contains "flag --high reaches the launcher verbatim" \
    "$(cat "$capture_dir/summarize-high.argv")" "--harness codex/fast --checkout"
contains "flag --low reaches the launcher verbatim" \
    "$(cat "$capture_dir/summarize-low.argv")" "--harness claude/haiku --checkout"

LKML_SUMMARIZE_ENV_FILE="$env_file" run "one flag, one env" 0 widget-frob --project "$project_dir" \
    --high codex/fast
contains "a flagged tier comes from the flag" "$(cat "$out_file")" "high: codex/fast"
contains "an unflagged tier comes from the env file" "$(cat "$out_file")" "low: pi-local/nano-local,"

printf '\n== the pipeline: sequential low-then-high, harvest, cleanup ==\n'
series_dir="$LKML_MAILBOX_ROOT/widget-frob"
# The tier-resolution section above already ran the full pipeline a few
# times; start the cost-ledger assertions from a clean slate.
: > "$series_dir/runs.jsonl"
cap="$(mktemp -d)"; tmpdirs+=("$cap")
stdout="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>"$cap/err")"
rc=$?
stderr="$(cat "$cap/err")"
if (( rc == 0 )); then ok "the full pipeline exits 0 against the stub"; else no "the full pipeline exits 0 against the stub" "exit $rc: $stderr"; fi

check "the two written paths are the last stdout lines" \
    "$series_dir/results-v1.json
$series_dir/results-v1.md" \
    "$(tail -n 2 <<< "$stdout" | tr -d '\r')"
if cmp -s <(printf '%s\n' "$DEFAULT_JSON") "$series_dir/results-v1.json"; then
    ok "results-v1.json is the low tier's outbox file, verbatim"
else
    no "results-v1.json is the low tier's outbox file, verbatim" "$(cat "$series_dir/results-v1.json")"
fi
if cmp -s <(printf '%s\n' "$DEFAULT_MD") "$series_dir/results-v1.md"; then
    ok "results-v1.md is the high tier's outbox file, verbatim"
else
    no "results-v1.md is the high tier's outbox file, verbatim" "$(cat "$series_dir/results-v1.md")"
fi

check "the low tier launches first, the high tier second" \
    "summarize-low
summarize-high" \
    "$(tr -d '\r' < "$cap/order")"
check "low launch checks out the series' recorded tip branch" \
    "main" "$(sed -n 's/^.*--checkout \([^ ]*\).*/\1/p' "$cap/summarize-low.argv" | head -n1)"
low_branch="$(sed -n 's/^BRANCH=//p' "$cap/summarize-low.argv")"
high_branch="$(sed -n 's/^BRANCH=//p' "$cap/summarize-high.argv")"
case "$low_branch" in
    lkml/widget-frob-v1-summarize-low-*) ok "the low run's branch is a throwaway named for series/version/tier" ;;
    *) no "the low run's branch is a throwaway named for series/version/tier" "$low_branch" ;;
esac
case "$high_branch" in
    lkml/widget-frob-v1-summarize-high-*) ok "the high run's branch is a throwaway named for series/version/tier" ;;
    *) no "the high run's branch is a throwaway named for series/version/tier" "$high_branch" ;;
esac
if [[ "$low_branch" != "$high_branch" ]]; then
    ok "the two tiers run on distinct branches"
else
    no "the two tiers run on distinct branches" "$low_branch"
fi
leftover="$(git -C "$project_dir" branch --list 'lkml/*' | tr -d '[:space:]')"
check "both throwaway branches are deleted after the runs return" "" "$leftover"
check "both tiers are logged in the series cost ledger with kind summarize" \
    "2" "$(jq -r 'select(.kind=="summarize") | .persona' "$series_dir/runs.jsonl" 2>/dev/null | wc -l | tr -d '[:space:]')"

low_handoff="$(cat -- "$cap/summarize-low.handoff.md")"
contains "the low handoff carries the full --text render (a reply body, not just the tree)" \
    "$low_handoff" "the frob looks flaky under load"
contains "the low handoff names the version the summary is about" \
    "$low_handoff" '"widget-frob v1"'
# shellcheck disable=SC2016  # literal $, not a variable
contains "the low handoff names its outbox output file" \
    "$low_handoff" '$OUTBOX_DIR/results.json'
contains "the low handoff carries no commit permission" \
    "$low_handoff" "Make NO commits"

high_handoff="$(cat -- "$cap/summarize-high.handoff.md")"
contains "the high handoff carries the extraction intermediate inline, verbatim" \
    "$high_handoff" '"claim":"frob looks flaky under load"'
contains "the high handoff carries the tally section" \
    "$high_handoff" "Latest tag per reviewer per patch"
contains "the high handoff says the intermediate should spare a source-dive" \
    "$high_handoff" "should make a source-dive"
# shellcheck disable=SC2016  # literal $, not a variable
contains "the high handoff names its outbox output file" \
    "$high_handoff" '$OUTBOX_DIR/results.md'
contains "the high handoff fixes the Summary word budget" \
    "$high_handoff" "hard-capped at 200"

printf '\n== version selection: latest default and --version pin ==\n'
printf 'Add the second frobnicator\n\nV2 body.\n' > cover3.txt
mkdir patches3
printf 'Subject: [PATCH 1/1] frob: second\n\ndiff\n' > patches3/0001.patch
"$mailbox" init widget-frob --cover cover3.txt --patches patches3 --from author \
    --harness claude --model opus --version 2 >/dev/null 2>&1
printf '{"version":2,"branch":"main"}\n' >> "$series_dir/versions.jsonl"

cap2="$(mktemp -d)"; tmpdirs+=("$cap2")
stdout="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap2" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>"$cap2/err")"
rc=$?
if (( rc == 0 )); then ok "no --version: exits 0"; else no "no --version: exits 0" "exit $rc: $(cat "$cap2/err")"; fi
check "no --version summarizes the latest recorded version (v2)" \
    "$series_dir/results-v2.json
$series_dir/results-v2.md" \
    "$(tail -n 2 <<< "$stdout" | tr -d '\r')"
contains "the v2 low handoff is about the section headed widget-frob v2" \
    "$(cat "$cap2/summarize-low.handoff.md")" '"widget-frob v2"'
contains "the v2 low handoff carries v1 as context" \
    "$(cat "$cap2/summarize-low.handoff.md")" "Add the frobnicator"
contains "the v2 tally section is inline for the high tier" \
    "$(cat "$cap2/summarize-high.handoff.md")" "frob: second"
if cmp -s <(printf '%s\n' "$DEFAULT_MD") "$series_dir/results-v1.md"; then
    ok "summarizing v2 did not touch results-v1.md"
else
    no "summarizing v2 did not touch results-v1.md"
fi

cap3="$(mktemp -d)"; tmpdirs+=("$cap3")
stdout="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap3" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" --version 1 2>"$cap3/err")"
rc=$?
if (( rc == 0 )); then ok "--version 1: exits 0"; else no "--version 1: exits 0" "exit $rc: $(cat "$cap3/err")"; fi
check "--version 1 writes results-v1, not the latest" \
    "$series_dir/results-v1.json
$series_dir/results-v1.md" \
    "$(tail -n 2 <<< "$stdout" | tr -d '\r')"

printf '\n== re-summarizing overwrites in place ==\n'
OVERWRITE_MD='# Summary
Second pass: same series, different words.'$'\n\n'"# Details
rewritten"
cap4="$(mktemp -d)"; tmpdirs+=("$cap4")
stdout="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap4" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$OVERWRITE_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>"$cap4/err")"
rc=$?
if (( rc == 0 )); then ok "re-summarize exits 0"; else no "re-summarize exits 0" "exit $rc: $(cat "$cap4/err")"; fi
if cmp -s <(printf '%s\n' "$OVERWRITE_MD") "$series_dir/results-v2.md"; then
    ok "the re-summarized version's md is overwritten, not appended"
else
    no "the re-summarized version's md is overwritten, not appended" "$(cat "$series_dir/results-v2.md")"
fi
check "no stray per-run result files accumulate in the series dir" \
    "4" "$(find "$series_dir" -maxdepth 1 -name 'results-v*' | wc -l | tr -d '[:space:]')"

printf '\n== Summary section length warning ==\n'
long_summary="$(awk 'BEGIN { for (i = 0; i < 210; i++) printf "word%d ", i }')"
LONG_MD="# Summary
$long_summary

# Details
fine"
cap5="$(mktemp -d)"; tmpdirs+=("$cap5")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap5" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$LONG_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc == 0 )); then ok "an over-long Summary still exits 0"; else no "an over-long Summary still exits 0" "exit $rc: $out_full"; fi
contains "an over-long Summary warns on stderr with the word count" "$out_full" "210 words"
contains "the warning names the ~200 cap" "$out_full" "~200"
cap6="$(mktemp -d)"; tmpdirs+=("$cap6")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap6" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
case "$out_full" in
    *200\ words*) no "a short Summary does not warn" ;;
    *) ok "a short Summary does not warn" ;;
esac

printf '\n== a low run that leaves no intermediate ==\n'
cap7="$(mktemp -d)"; tmpdirs+=("$cap7")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap7" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_SKIP_JSON=1 STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "missing outbox results.json exits non-zero"; else no "missing outbox results.json exits non-zero" "exit 0"; fi
contains "the failure names the missing outbox file" "$out_full" "outbox/results.json"
check "the high tier was not launched without the intermediate" \
    "summarize-low" "$(tr -d '\r' < "$cap7/order")"
leftover="$(git -C "$project_dir" branch --list 'lkml/*' | tr -d '[:space:]')"
check "the low run's throwaway branch is still deleted on failure" "" "$leftover"
check "no partial results-v1.json was harvested from a failed low run" \
    "$DEFAULT_JSON" "$(jq -c . "$series_dir/results-v1.json" 2>/dev/null)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
