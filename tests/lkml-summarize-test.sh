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
# for a launcher that left the branch behind (a no-commit run's branch
# is deleted by the real launcher itself, and STUB_NO_BRANCH=1 models
# that: no branch created, matching a fetched commits:0 run).
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
#   - tier-setting errors name the source (flag vs env key) and echo
#     the offending value.
#   - an already-deleted throwaway branch (the no-commit case the real
#     launcher produces) warns nothing.
#   - a low run that leaves an empty intermediate is fatal, and a
#     failed high run leaves the previous results pair untouched.
#   - --series mode: the single synthesis run, its handoff (per-version
#     intermediates and tallies in version order, latest cover letter),
#     harvest to results-series.md only, the -series- throwaway branch
#     and the summarize-series cost-ledger persona; the refusals
#     (--series with --version, --series with --low, a missing
#     per-version intermediate) and the empty/whitespace-only outbox.
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
if [[ "${STUB_NO_BRANCH:-0}" == 1 ]]; then
    git -C "$project" branch -q -D "$branch"
fi
run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
mkdir -p "$run_dir/outbox"
case "$tier" in
    summarize-low)
        if [[ "${STUB_SKIP_JSON:-0}" == 1 ]]; then
            :
        elif [[ "${STUB_JSON_EMPTY:-0}" == 1 ]]; then
            # Whitespace only, as a low tier that died after touching
            # the file (not before creating it) would leave.
            printf ' \n' > "$run_dir/outbox/results.json"
        else
            # ${STUB_JSON:-{}} would NOT work: bash closes the expansion at
            # the first brace, appending a literal "}" to every write.
            stub_json_default="{}"
            printf '%s\n' "${STUB_JSON:-$stub_json_default}" > "$run_dir/outbox/results.json"
        fi
        ;;
    summarize-high)
        if [[ "${STUB_SKIP_MD:-0}" != 1 ]]; then
            printf '%s\n' "${STUB_MD:-}" > "$run_dir/outbox/results.md"
        fi
        ;;
    summarize-series)
        # The series run is synthesis-only: results.md in the outbox,
        # no json companion. STUB_MD_EMPTY models a run that died after
        # touching the file; STUB_SKIP_MD one that never got there.
        if [[ "${STUB_SKIP_MD:-0}" == 1 ]]; then
            :
        elif [[ "${STUB_MD_EMPTY:-0}" == 1 ]]; then
            printf ' \n' > "$run_dir/outbox/results.md"
        else
            printf '%s\n' "${STUB_MD:-}" > "$run_dir/outbox/results.md"
        fi
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
contains "the whitespace error names the flag the value came from" "$(cat "$out_file")" "--low"
contains "the whitespace error echoes the offending value" "$(cat "$out_file")" "claude /sonnet"
run "non-integer --timeout" 1 widget-frob --project "$project_dir" --timeout soon
contains "non-integer --timeout is refused" "$(cat "$out_file")" "--timeout must be a number"
if bash "$summarize" widget-frob -h > "$out_file" 2>&1; then
    ok "-h after the series prints usage and exits 0"
else
    no "-h after the series prints usage and exits 0" "exit $?"
fi
contains "the usage names the tier flags" "$(cat "$out_file")" "--high"

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

env_ws="$work/lkml-summarize-ws.env"
printf 'LKML_SUMMARIZE_LOW=claude /sonnet\n' > "$env_ws"
LKML_SUMMARIZE_ENV_FILE="$env_ws" run "whitespace tier spec from env" 1 widget-frob --project "$project_dir"
contains "an env-sourced whitespace error names the env key" "$(cat "$out_file")" "LKML_SUMMARIZE_LOW"
contains "the env error echoes the offending value too" "$(cat "$out_file")" "claude /sonnet"

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
# shellcheck disable=SC2016  # literal backtick in the needle
contains "the low handoff names the outbox the way the preamble does" \
    "$low_handoff" "results.json\` at the
root of the artifact outbox directory named in your prompt"
contains "the low handoff carries no commit permission" \
    "$low_handoff" "Make NO commits"

high_handoff="$(cat -- "$cap/summarize-high.handoff.md")"
contains "the high handoff carries the extraction intermediate inline, verbatim" \
    "$high_handoff" '"claim":"frob looks flaky under load"'
contains "the high handoff carries the tally section" \
    "$high_handoff" "Latest tag per reviewer per patch"
contains "the high handoff says the intermediate should spare a source-dive" \
    "$high_handoff" "should make a source-dive"
# shellcheck disable=SC2016  # literal backtick in the needle
contains "the high handoff names the outbox the way the preamble does" \
    "$high_handoff" "results.md\` at the root of the artifact outbox"
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

printf '\n== a low run that leaves unparseable JSON ==\n'
cap8="$(mktemp -d)"; tmpdirs+=("$cap8")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap8" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON='not json at all' STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc == 0 )); then ok "unparseable intermediate still exits 0 (warn, don't die)"; else no "unparseable intermediate still exits 0 (warn, don't die)" "exit $rc: $out_full"; fi
contains "the warning names the harvested file" "$out_full" "not parseable JSON"
contains "the high tier got the unparseable intermediate verbatim" \
    "$(cat "$cap8/summarize-high.handoff.md")" "not json at all"
if cmp -s <(printf '%s\n' 'not json at all') "$series_dir/results-v2.json"; then
    ok "the unparseable intermediate is still harvested verbatim"
else
    no "the unparseable intermediate is still harvested verbatim" "$(cat "$series_dir/results-v2.json")"
fi

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

printf '\n== a low run that leaves an empty intermediate ==\n'
# At this point results-v2.json holds cap8's unparseable text and
# results-v2.md holds DEFAULT_MD: a refused run must leave that pair
# as it found it.
cap9="$(mktemp -d)"; tmpdirs+=("$cap9")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap9" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON_EMPTY=1 STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "a whitespace-only intermediate exits non-zero (fatal, not a warning)"; else no "a whitespace-only intermediate exits non-zero (fatal, not a warning)" "exit 0: $out_full"; fi
contains "the failure names the empty outbox file" "$out_full" "outbox/results.json"
contains "the failure says there is nothing to synthesize" "$out_full" "nothing to synthesize"
check "the high tier was not launched on an empty intermediate" \
    "summarize-low" "$(tr -d '\r' < "$cap9/order")"
check "a refused empty intermediate did not clobber results-v2.json" \
    "not json at all" "$(cat "$series_dir/results-v2.json")"
check "a refused empty intermediate did not touch results-v2.md" \
    "$DEFAULT_MD" "$(cat "$series_dir/results-v2.md")"

printf '\n== a failed high run leaves the previous results pair ==\n'
cap10="$(mktemp -d)"; tmpdirs+=("$cap10")
before_md="$(cat "$series_dir/results-v2.md")"
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap10" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" STUB_SKIP_MD=1 \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "a high run that leaves no results.md exits non-zero"; else no "a high run that leaves no results.md exits non-zero" "exit 0: $out_full"; fi
contains "the failure names the missing outbox file" "$out_full" "outbox/results.md"
check "the previous results-v2.md survived the failed high run" \
    "$before_md" "$(cat "$series_dir/results-v2.md")"
check "the fresh intermediate was not landed beside the stale md" \
    "not json at all" "$(cat "$series_dir/results-v2.json")"
leftover="$(git -C "$project_dir" branch --list 'lkml/*' | tr -d '[:space:]')"
check "both throwaway branches are deleted when the high run leaves no md" "" "$leftover"

printf '\n== a no-commit run: the launcher already deleted the branch ==\n'
cap11="$(mktemp -d)"; tmpdirs+=("$cap11")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap11" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_NO_BRANCH=1 STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
    "$summarize" widget-frob --project "$project_dir" 2>&1)"
rc=$?
if (( rc == 0 )); then ok "an already-gone branch does not fail the run"; else no "an already-gone branch does not fail the run" "exit $rc: $out_full"; fi
case "$out_full" in
    *"delete it by hand"*) no "no hand-cleanup warning when the branch is already gone" ;;
    *) ok "no hand-cleanup warning when the branch is already gone" ;;
esac

printf '\n== --series mode: one synthesis run, series handoff, series harvest ==\n'
# widget-frob records v1 and v2 (both posted to the mailbox, both with
# their per-version intermediates on disk from the sections above), so
# the --series happy path can run against it: exactly one launch, the
# series handoff assembled from on-disk inputs, harvest to
# results-series.md only.
SERIES_MD='# Summary
The series adds the frobnicator across two versions; v2 stands with the v1 flakiness claim still open.

# Details
v1: posted 1 patch, the panel raised 1, of which 0 were confirmed.

v2: posted 1 patch, the panel was quiet.

Open items
Flakiness under load (deadbee) still stands.

Recommended next actions
Author to address the flakiness claim and post v3.'

capS="$(mktemp -d)"; tmpdirs+=("$capS")
stdout="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capS" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$SERIES_MD" \
    "$summarize" widget-frob --project "$project_dir" --series 2>"$capS/err")"
rc=$?
if (( rc == 0 )); then ok "--series: exits 0 against the stub"; else no "--series: exits 0 against the stub" "exit $rc: $(cat "$capS/err")"; fi
check "--series stdout is exactly the written path (no json companion)" \
    "$series_dir/results-series.md" "$(tr -d '\r' <<< "$stdout")"
if [[ -e "$series_dir/results-series.json" ]]; then
    no "no results-series.json companion is written"
else
    ok "no results-series.json companion is written"
fi
if cmp -s <(printf '%s\n' "$SERIES_MD") "$series_dir/results-series.md"; then
    ok "results-series.md is the series run's outbox file, verbatim"
else
    no "results-series.md is the series run's outbox file, verbatim" "$(cat "$series_dir/results-series.md")"
fi
check "exactly one run launched, the series run" "summarize-series" "$(tr -d '\r' < "$capS/order")"
series_branch="$(sed -n 's/^BRANCH=//p' "$capS/summarize-series.argv")"
case "$series_branch" in
    lkml/widget-frob-v2-summarize-series-*) ok "the series run's branch carries the -series- token" ;;
    *) no "the series run's branch carries the -series- token" "$series_branch" ;;
esac
check "the series run checks out the LATEST version's recorded branch" \
    "main" "$(sed -n 's/^.*--checkout \([^ ]*\).*/\1/p' "$capS/summarize-series.argv" | head -n1)"
check "the series run runs on the high spec (shipped default claude/opus)" \
    "claude/opus" "$(sed -n 's/^.*--harness \([^ ]*\).*/\1/p' "$capS/summarize-series.argv" | head -n1)"
leftover="$(git -C "$project_dir" branch --list 'lkml/*' | tr -d '[:space:]')"
check "the series throwaway branch is deleted after the run returns" "" "$leftover"
check "the series run is logged with persona summarize-series and kind summarize" \
    "summarize-series" "$(jq -r 'select(.kind=="summarize") | select(.persona=="summarize-series") | .persona' "$series_dir/runs.jsonl" | tail -n1)"
check "the series run did not touch results-v1.md" \
    "$DEFAULT_MD" "$(cat "$series_dir/results-v1.md")"
check "the series run did not touch results-v2.json" \
    "$DEFAULT_JSON" "$(jq -c . "$series_dir/results-v2.json")"

shandoff="$(cat -- "$capS/summarize-series.handoff.md")"
contains "the series handoff spans the arc, first to latest version" "$shandoff" "versions 1 to 2"
contains "the series handoff carries v1's intermediate under its own heading" \
    "$shandoff" "## v1: the extraction intermediate (results-v1.json, verbatim)"
contains "the series handoff carries v2's intermediate under its own heading" \
    "$shandoff" "## v2: the extraction intermediate (results-v2.json, verbatim)"
contains "the series handoff carries the intermediate content verbatim" \
    "$shandoff" '"claim":"frob looks flaky under load"'
contains "the series handoff carries v1's tally section" "$shandoff" "widget-frob v1"
contains "the series handoff carries v2's tally section" "$shandoff" "frob: second"
contains "the series handoff carries the LATEST version's cover letter body" \
    "$shandoff" "  Add the second frobnicator"
contains "the series handoff carries the cover letter as a message (its header line)" \
    "$shandoff" "Subject: [PATCH v2 0/1] Add the second frobnicator"
contains "the series handoff pins the Summary register" "$shandoff" "hard cap 200"
contains "the series handoff pins ~150 words" "$shandoff" "about 150 words"
contains "the series handoff bans the mechanism explanation" \
    "$shandoff" "Do NOT explain the review mechanism"
contains "the series handoff demands per-version Details paragraphs" \
    "$shandoff" "one short paragraph per version, in version order"
# shellcheck disable=SC2016  # literal backtick in the needle
contains "the series handoff names the outbox the way the preamble does" \
    "$shandoff" "results.md\` at the root of the artifact outbox"
contains "the series handoff carries no commit permission" "$shandoff" "Make NO commits"
if python3 - "$capS/summarize-series.handoff.md" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
i1 = text.index("## v1: the extraction intermediate")
i2 = text.index("## v2: the extraction intermediate")
j1 = text.index("## v1: the tally section")
j2 = text.index("## v2: the tally section")
k = text.index("## v2: the cover letter")
errors = []
if not i1 < i2:
    errors.append("v1's intermediate does not precede v2's")
if not j1 < j2:
    errors.append("v1's tally does not precede v2's")
if not (i1 < j1 and i2 < j2):
    errors.append("intermediates are not in front of the tallies")
if not j2 < k:
    errors.append("the cover letter is not last")
for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY
then
    ok "the series handoff orders the inputs: intermediates, tallies, cover"
else
    no "the series handoff orders the inputs: intermediates, tallies, cover"
fi

# The version ledger is append-only, so a version can appear in it
# twice; --series must feed the handoff that version ONCE, not pay
# double tokens for the same intermediate and tally.
printf '{"version":2,"branch":"main"}\n' >> "$series_dir/versions.jsonl"
capD="$(mktemp -d)"; tmpdirs+=("$capD")
dup_rc=0
PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capD" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$SERIES_MD" \
    "$summarize" widget-frob --project "$project_dir" --series >/dev/null 2>"$capD/err" || dup_rc=$?
if (( dup_rc == 0 )); then ok "--series with a duplicated ledger entry exits 0"; else no "--series with a duplicated ledger entry exits 0" "exit $dup_rc: $(cat "$capD/err")"; fi
dup_handoff="$(cat -- "$capD/summarize-series.handoff.md")"
check "a duplicated ledger entry feeds v2's intermediate once" \
    "1" "$(grep -c -- '## v2: the extraction intermediate' <<< "$dup_handoff")"
check "a duplicated ledger entry feeds v2's tally once" \
    "1" "$(grep -c -- '## v2: the tally section' <<< "$dup_handoff")"
# Restore the ledger for the sections below (the run above left
# results-series.md with identical content, so only the ledger needs
# the duplicate line back off).
head -n -1 -- "$series_dir/versions.jsonl" > "$series_dir/versions.jsonl.tmp"
mv -- "$series_dir/versions.jsonl.tmp" "$series_dir/versions.jsonl"

printf '\n== --series mode: refusals ==\n'
capR="$(mktemp -d)"; tmpdirs+=("$capR")
run "series with --version is refused" 1 widget-frob --project "$project_dir" --series --version 2
contains "the --series + --version refusal says pick one" "$(cat "$out_file")" "pick one"
run "series with --low is refused" 1 widget-frob --project "$project_dir" --series --low claude/sonnet
contains "the --series + --low refusal says there is no extraction tier" \
    "$(cat "$out_file")" "no extraction tier"
contains "the --series + --low refusal points at --high" "$(cat "$out_file")" "--high"
if [[ -e "$capR/order" ]]; then
    no "a refused --series run launches nothing" "$(cat "$capR/order")"
else
    ok "a refused --series run launches nothing"
fi

mv "$series_dir/results-v2.json" "$capR/hidden-v2.json"
mv "$series_dir/results-v1.json" "$capR/hidden-v1.json"
run "missing per-version intermediates are refused" 1 widget-frob --project "$project_dir" --series
contains "the refusal names both missing versions' files" "$(cat "$out_file")" "missing for: 1 2"
contains "the refusal gives the remedial command for v1" \
    "$(cat "$out_file")" "run lkml-summarize.sh widget-frob --project $project_dir --version 1 first"
contains "the refusal gives the remedial command for v2" \
    "$(cat "$out_file")" "run lkml-summarize.sh widget-frob --project $project_dir --version 2 first"
mv "$capR/hidden-v1.json" "$series_dir/results-v1.json"
run "a single missing intermediate names just that version" 1 widget-frob --project "$project_dir" --series
contains "a single missing version is named" "$(cat "$out_file")" "missing for: 2"
case "$(cat "$out_file")" in
    *"--version 1 first"*) no "the remedial command list covers only the missing versions" ;;
    *) ok "the remedial command list covers only the missing versions" ;;
esac
mv "$capR/hidden-v2.json" "$series_dir/results-v2.json"

printf '\n== --series mode: outbox failures ==\n'
capE="$(mktemp -d)"; tmpdirs+=("$capE")
before_series_md="$(cat "$series_dir/results-series.md")"
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capE" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$SERIES_MD" STUB_MD_EMPTY=1 \
    "$summarize" widget-frob --project "$project_dir" --series 2>&1)"
rc=$?
if (( rc != 0 )); then ok "a whitespace-only series outbox exits non-zero (fatal, not a warning)"; else no "a whitespace-only series outbox exits non-zero (fatal, not a warning)" "exit 0: $out_full"; fi
contains "the failure names the empty outbox file" "$out_full" "outbox/results.md"
contains "the failure says there is nothing to synthesize" "$out_full" "nothing to synthesize"
check "a refused empty outbox did not clobber results-series.md" \
    "$before_series_md" "$(cat "$series_dir/results-series.md")"
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capE" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$SERIES_MD" STUB_SKIP_MD=1 \
    "$summarize" widget-frob --project "$project_dir" --series 2>&1)"
rc=$?
if (( rc != 0 )); then ok "a series run that leaves no results.md exits non-zero"; else no "a series run that leaves no results.md exits non-zero" "exit 0: $out_full"; fi
contains "the failure names the missing outbox file" "$out_full" "outbox/results.md"
leftover="$(git -C "$project_dir" branch --list 'lkml/*' | tr -d '[:space:]')"
check "the series throwaway branch is deleted when the outbox is empty" "" "$leftover"
# The word-count warning applies exactly as in the per-version path.
capW="$(mktemp -d)"; tmpdirs+=("$capW")
out_full="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capW" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_JSON="$DEFAULT_JSON" STUB_MD="$LONG_MD" \
    "$summarize" widget-frob --project "$project_dir" --series 2>&1)"
rc=$?
if (( rc == 0 )); then ok "an over-long series Summary still exits 0"; else no "an over-long series Summary still exits 0" "exit $rc: $out_full"; fi
contains "an over-long series Summary warns on stderr with the word count" "$out_full" "210 words"
contains "the series warning aims for ~150" "$out_full" "aim for ~150"

printf '\n== --help ==\n'
h_out="$("$summarize" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "lkml-summarize.sh — Turn a finished lkml-mode review thread into"
h2_out="$("$summarize" -h 2>&1)"; h2_rc=$?
if (( h2_rc == 0 )); then ok "-h alone exits 0"; else no "-h alone exits 0" "exit $h2_rc: $h2_out"; fi
contains "-h prints the header usage" "$h2_out" "lkml-summarize.sh — Turn a finished lkml-mode review thread into"

printf '\n== large render performance ==\n'
# The emptiness check on $render_text once ran a whole-string glob
# substitution, which walks the string per multibyte character under a UTF-8
# locale. Measured on this machine: 7.5s at 64KB, 33s at 128KB, 139s at
# 256KB -- quadratic, and $render_text is the WHOLE thread, so a real series
# stalled here for over half an hour before the first tier ever launched,
# with no output to say so. The regex find-one-non-space form is 6ms at
# 256KB. This posts a large multibyte reply, which lands in the render, and
# bounds the whole stubbed pipeline at 25s.
big_reply="$(mktemp)"
printf 'große Antwort mit Umlauten — %d\n' $(seq 6000) > "$big_reply"
"$mailbox" post widget-frob --from core --reply-to "$patch_id" --file "$big_reply" \
    --tags Changes-requested --harness claude --model opus >/dev/null 2>&1
capP="$(mktemp -d)"; tmpdirs+=("$capP")
if LC_ALL=C.UTF-8 timeout 25 env PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capP" \
        STUB_RUN_PREFIX="$run_prefix_dir" STUB_JSON="$DEFAULT_JSON" STUB_MD="$DEFAULT_MD" \
        "$summarize" widget-frob --project "$project_dir" >/dev/null 2>&1; then
    ok "a large multibyte thread render summarizes promptly"
else
    no "a large multibyte thread render summarizes promptly" \
        "timed out or failed -- the emptiness check may have regressed to a glob substitution"
fi
rm -f -- "$big_reply"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
