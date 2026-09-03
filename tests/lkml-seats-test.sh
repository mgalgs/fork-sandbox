#!/usr/bin/env bash
# lkml-seats-test.sh — Exercise the lkml-mode machine seats file: the
# lkml-seats-resolve helper's precedence and refusal rules directly, and
# lkml-round.sh consuming them end to end against a stub fork-sandbox.sh,
# the same "stub the external command on PATH" pattern
# tests/lkml-round-test.sh uses.
#
# Usage: tests/lkml-seats-test.sh
#
# The helper tests call scripts/lkml-seats-resolve with LKML_SEATS_FILE
# pointed at fixtures (its documented test hook) and a controlled HOME,
# so neither a real ~/.config/fork-sandbox/lkml-seats.yaml nor the
# machine's own HOME can leak in. The integration tests launch the real
# lkml-round.sh against the stub and inspect the argv each persona was
# actually launched with, plus the stderr announcements.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
round="$repo_dir/scripts/lkml-round.sh"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"
resolver="$repo_dir/scripts/lkml-seats-resolve"

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
    echo "SKIP: jq not installed; lkml-round.sh needs it to build --task-meta."
    exit 0
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "SKIP: PyYAML not installed; the seats file parser needs it."
    exit 0
fi

work="$(mktemp -d)"; tmpdirs+=("$work")
home_dir="$work/home"; mkdir -p -- "$home_dir"
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
capture_dir="$(mktemp -d)"; tmpdirs+=("$capture_dir")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")
stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
project_dir="$(mktemp -d)"; tmpdirs+=("$project_dir")

# The personas directory the seats fixtures are checked against: the real
# shipped pins (core/author = claude/opus, ci = bare pi-local) plus one
# local persona with a thinking pin, so thinking inheritance is testable.
personas_test_dir="$work/personas"; mkdir -p -- "$personas_test_dir"
cp -- "$repo_dir/skills/lkml-mode/personas/core.md" "$personas_test_dir/"
cp -- "$repo_dir/skills/lkml-mode/personas/author.md" "$personas_test_dir/"
cp -- "$repo_dir/skills/lkml-mode/personas/ci.md" "$personas_test_dir/"
cat > "$personas_test_dir/thinky.md" <<'PERSONA'
---
persona: thinky
harness: pi-local
thinking: high
---
Local thinker.
PERSONA

# resolve_helper <seats-file | ABSENT> <persona> <fm-harness> <fm-model>
# <fm-thinking> — call the helper with a controlled HOME and seats file,
# capturing RES_OUT (stdout), RES_ERR (stderr) and RES_RC.
resolve_helper() {
    local file="$1"
    if [[ "$file" == ABSENT ]]; then
        RES_OUT="$(HOME="$home_dir" LKML_SEATS_FILE='' "$resolver" resolve \
            "$personas_test_dir" "${@:2}" 2>"$work/err")"; RES_RC=$?
    else
        RES_OUT="$(HOME="$home_dir" LKML_SEATS_FILE="$file" "$resolver" resolve \
            "$personas_test_dir" "${@:2}" 2>"$work/err")"; RES_RC=$?
    fi
    RES_ERR="$(cat "$work/err")"
}
# fields of the resolved output (one field per line): 1=harness 2=model
# 3=thinking 4=announce
resolved_field() { printf '%s\n' "$RES_OUT" | sed -n "${2}p"; }

printf '\n== no seats file: frontmatter pins verbatim (today%s behavior) ==\n' "'"
resolve_helper ABSENT core claude opus ""
check "absent file exits 0" "0" "$RES_RC"
check "absent file resolves the frontmatter harness" "claude" "$(resolved_field RES_OUT 1)"
check "absent file resolves the frontmatter model" "opus" "$(resolved_field RES_OUT 2)"
check "absent file keeps the frontmatter thinking" "" "$(resolved_field RES_OUT 3)"
check "absent file announces nothing" "" "$(resolved_field RES_OUT 4)"
check "absent file prints nothing to stderr" "" "$RES_ERR"

resolve_helper ABSENT thinky pi-local "" high
check "absent file keeps a persona's thinking pin" "high" "$(resolved_field RES_OUT 3)"

printf '\n== LKML_SEATS_FILE set to a missing path is an error ==\n'
resolve_helper "$work/does-not-exist.yaml" core claude opus ""
check "explicit missing seats file exits non-zero" "1" "$RES_RC"
contains "explicit missing seats file names the path" "$RES_ERR" "does-not-exist.yaml"

printf '\n== default: re-seats every persona, model dropped ==\n'
cat > "$work/seats-default.yaml" <<'YAML'
default:
  harness: pi-local
YAML
resolve_helper "$work/seats-default.yaml" core claude opus ""
check "default re-seats core on pi-local" "pi-local" "$(resolved_field RES_OUT 1)"
check "default's harness drops core's frontmatter model" "" "$(resolved_field RES_OUT 2)"
contains "default re-seat is announced" "$RES_OUT" "seat core: pi-local (seats-default.yaml, was claude/opus)"
resolve_helper "$work/seats-default.yaml" author claude opus ""
check "default re-seats author on pi-local" "pi-local" "$(resolved_field RES_OUT 1)"
check "default's harness drops author's frontmatter model" "" "$(resolved_field RES_OUT 2)"
resolve_helper "$work/seats-default.yaml" ci pi-local "" ""
check "a persona already at the default's seat stays put" "pi-local" "$(resolved_field RES_OUT 1)"
check "an unchanged seat is not announced" "" "$(resolved_field RES_OUT 4)"

printf '\n== per-persona entry beats default: ==\n'
cat > "$work/seats-perp.yaml" <<'YAML'
default:
  harness: pi-local
personas:
  author:
    harness: claude
    model: opus
YAML
resolve_helper "$work/seats-perp.yaml" author claude opus ""
check "per-persona entry keeps author on claude" "claude" "$(resolved_field RES_OUT 1)"
check "per-persona entry keeps author on opus" "opus" "$(resolved_field RES_OUT 2)"
check "an unchanged seat stays unannounced" "" "$(resolved_field RES_OUT 4)"
resolve_helper "$work/seats-perp.yaml" core claude opus ""
check "core still falls through to the default" "pi-local" "$(resolved_field RES_OUT 1)"

printf '\n== a seats harness without a model drops the frontmatter model ==\n'
cat > "$work/seats-harnonmodel.yaml" <<'YAML'
personas:
  core:
    harness: claude
YAML
resolve_helper "$work/seats-harnonmodel.yaml" core claude opus ""
check "harness-only entry keeps the same harness" "claude" "$(resolved_field RES_OUT 1)"
check "harness-only entry drops the frontmatter model" "" "$(resolved_field RES_OUT 2)"
contains "a model drop is announced" "$RES_OUT" "seat core: claude (seats-harnonmodel.yaml, was claude/opus)"
resolve_helper "$work/seats-harnonmodel.yaml" thinky pi-local "" high
check "personas without an entry keep their own seat" "pi-local" "$(resolved_field RES_OUT 1)"
check "personas without an entry keep their thinking" "high" "$(resolved_field RES_OUT 3)"

printf '\n== a personas.<p> harness drops EVERY lower-scope model ==\n'
cat > "$work/seats-pdrop.yaml" <<'YAML'
default:
  harness: claude
  model: sonnet
personas:
  core:
    harness: pi-local
YAML
resolve_helper "$work/seats-pdrop.yaml" core claude opus ""
check "persona harness overrides the default harness" "pi-local" "$(resolved_field RES_OUT 1)"
check "persona harness drops the default's model" "" "$(resolved_field RES_OUT 2)"
cat > "$work/seats-pdrop2.yaml" <<'YAML'
default:
  model: sonnet
personas:
  core:
    harness: pi-local
    model: tiny
YAML
resolve_helper "$work/seats-pdrop2.yaml" core claude opus ""
check "a same-scope model rides with its harness" "pi-local" "$(resolved_field RES_OUT 1)"
check "a same-scope model wins over the default's" "tiny" "$(resolved_field RES_OUT 2)"
cat > "$work/seats-pdefmodel.yaml" <<'YAML'
default:
  harness: claude
  model: sonnet
personas:
  author:
    model: opus
YAML
resolve_helper "$work/seats-pdefmodel.yaml" author claude opus ""
check "a higher-scope model rides a lower-scope harness" "claude" "$(resolved_field RES_OUT 1)"
check "the higher-scope model wins the model key" "opus" "$(resolved_field RES_OUT 2)"

printf '\n== a seats model without a harness keeps the frontmatter harness ==\n'
cat > "$work/seats-modelonly.yaml" <<'YAML'
personas:
  core:
    model: sonnet
YAML
resolve_helper "$work/seats-modelonly.yaml" core claude opus ""
check "model-only entry keeps the frontmatter harness" "claude" "$(resolved_field RES_OUT 1)"
check "model-only entry wins the model key" "sonnet" "$(resolved_field RES_OUT 2)"

printf '\n== thinking inherits from frontmatter, seats overrides it ==\n'
resolve_helper "$work/seats-default.yaml" thinky pi-local "" high
check "thinking inherits from frontmatter when no seat sets it" "high" "$(resolved_field RES_OUT 3)"
check "an inherited thinking announces nothing" "" "$(resolved_field RES_OUT 4)"
cat > "$work/seats-thinking.yaml" <<'YAML'
default:
  harness: pi-local
  thinking: low
YAML
resolve_helper "$work/seats-thinking.yaml" thinky pi-local "" high
check "a seats thinking overrides the frontmatter thinking" "low" "$(resolved_field RES_OUT 3)"
contains "an overridden thinking is announced" "$RES_OUT" "thinking low, was high"
resolve_helper "$work/seats-thinking.yaml" core claude opus ""
check "a seats thinking applies to personas whose frontmatter has none" "low" "$(resolved_field RES_OUT 3)"

printf '\n== thinking on a non-pi seat: explicit refused, inherited dropped ==\n'
cat > "$work/seats-thinknopy.yaml" <<'YAML'
default:
  harness: claude
  thinking: low
YAML
resolve_helper "$work/seats-thinknopy.yaml" core claude opus ""
check "explicit seats thinking on a non-pi seat is refused" "1" "$RES_RC"
contains "the refusal names the persona" "$RES_ERR" "'core'"
contains "the refusal names the key" "$RES_ERR" "'thinking'"
contains "the refusal names the resolved harness" "$RES_ERR" "'claude'"
contains "the refusal names the file" "$RES_ERR" "seats-thinknopy.yaml"
cat > "$work/seats-thinknop2.yaml" <<'YAML'
personas:
  core:
    harness: claude
    thinking: low
YAML
resolve_helper "$work/seats-thinknop2.yaml" core claude opus ""
check "persona-level explicit thinking is refused too" "1" "$RES_RC"
resolve_helper "$work/seats-thinknop2.yaml" thinky pi-local "" high
check "the same file still re-seats a pi seat" "pi-local" "$(resolved_field RES_OUT 1)"
check "the pi seat keeps its own thinking" "high" "$(resolved_field RES_OUT 3)"
cat > "$work/seats-harnoffpi.yaml" <<'YAML'
default:
  harness: claude
YAML
resolve_helper "$work/seats-harnoffpi.yaml" thinky pi-local "" high
check "moving a seat off pi is not itself an error" "0" "$RES_RC"
check "the inherited frontmatter thinking is dropped" "" "$(resolved_field RES_OUT 3)"
contains "the harness move is still announced" "$RES_OUT" \
    "seat thinky: claude (seats-harnoffpi.yaml, was pi-local)"
case "$(resolved_field RES_OUT 4)" in
    *thinking*) no "the announce does not mention the dropped thinking" "$(resolved_field RES_OUT 4)" ;;
    *) ok "the announce does not mention the dropped thinking" ;;
esac

printf '\n== refusals name the file and the offending key ==\n'
bad() {  # bad <label> <yaml> <expected-needle>
    local file="$work/bad.yaml"
    printf '%s\n' "$2" > "$file"
    HOME="$home_dir" LKML_SEATS_FILE="$file" "$resolver" check "$personas_test_dir" >"$work/out" 2>"$work/err"
    local rc=$?
    if (( rc != 0 )); then ok "$1"; else no "$1" "exit 0: $(cat "$work/err")"; fi
    contains "$1 names the offending thing" "$(cat "$work/err")" "$3"
    contains "$1 names the file" "$(cat "$work/err")" "bad.yaml"
}
bad "an unknown top-level key is refused" \
    'defaults:
  harness: pi-local' \
    "unknown top-level key 'defaults'"
bad "an unknown entry key is refused" \
    'personas:
  core:
    harness: pi-local
    tokens: 4000' \
    "personas.core.tokens"
bad "a typo'd persona name is refused against the personas dir" \
    'personas:
  authr:
    harness: claude' \
    "personas.authr"
bad "an invalid harness value is refused" \
    'default:
  harness: pilocal' \
    "not 'pilocal'"
bad "an empty file is refused" '' \
    "empty"
bad "an empty entry is refused" \
    'personas:
  core: {}' \
    "personas.core"
bad "a duplicate key is refused" \
    'default:
  harness: pi-local
  harness: claude' \
    "duplicate key 'harness'"
printf 'default:
  harness: [unclosed' > "$work/bad.yaml"
if HOME="$home_dir" LKML_SEATS_FILE="$work/bad.yaml" "$resolver" check "$personas_test_dir" >"$work/out" 2>"$work/err"; then
    no "unparseable YAML is refused" "exit 0"
else
    ok "unparseable YAML is refused"
fi
contains "unparseable YAML is named as such" "$(cat "$work/err")" "not valid YAML"

printf '\n== -h and --help print the header to stdout and exit 0 ==\n'
help_out="$(HOME="$home_dir" "$resolver" -h 2>"$work/err")"; help_rc=$?
check "-h exits 0" "0" "$help_rc"
contains "-h prints the usage to stdout" "$help_out" "Usage: lkml-seats-resolve check"
check "-h prints nothing to stderr" "" "$(cat "$work/err")"
help_out="$(HOME="$home_dir" "$resolver" --help 2>"$work/err")"; help_rc=$?
check "--help exits 0" "0" "$help_rc"
contains "--help prints the usage to stdout" "$help_out" "lkml-seats-resolve active"

printf '\n== active: the seats-file path rule lives in the resolver ==\n'
HOME="$home_dir" LKML_SEATS_FILE='' "$resolver" active "$personas_test_dir"
check "active: no file anywhere is inactive" "1" "$?"
mkdir -p -- "$home_dir/.config/fork-sandbox"
printf 'default:\n  harness: pi-local\n' > "$home_dir/.config/fork-sandbox/lkml-seats.yaml"
HOME="$home_dir" LKML_SEATS_FILE='' "$resolver" active "$personas_test_dir"
check "active: the default path is honored" "0" "$?"
res_out="$(HOME="$home_dir" LKML_SEATS_FILE='' "$resolver" resolve "$personas_test_dir" core claude opus "")"
check "set-but-empty LKML_SEATS_FILE consults the default path" "pi-local" "$(printf '%s\n' "$res_out" | sed -n 1p)"
rm -f -- "$home_dir/.config/fork-sandbox/lkml-seats.yaml"
HOME="$home_dir" LKML_SEATS_FILE="$work/nope.yaml" "$resolver" active "$personas_test_dir" 2>"$work/err"
check "active: an explicit missing path errors, not just inactivates" "1" "$?"
contains "active: the error names the path" "$(cat "$work/err")" "nope.yaml"

printf '\n== integration: lkml-round.sh against the stub ==\n'

# A minimal series to round on, same shape as tests/lkml-round-test.sh.
git -C "$project_dir" init -q
git -C "$project_dir" config user.email test@example.invalid
git -C "$project_dir" config user.name Test
printf 'checkout tree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm base
git -C "$project_dir" branch somebranch
cd "$work" || exit 1
printf 'Add the seats fixture\n\nBody.\n' > cover.txt
mkdir patches
printf 'Subject: [PATCH 1/1] seats: fixture\n\ndiff\n' > patches/0001.patch
"$mailbox" init widget-seats --cover cover.txt --patches patches --from author \
    --harness claude --model opus >/dev/null 2>&1
printf '{"version":1,"branch":"somebranch"}\n' > "$LKML_MAILBOX_ROOT/widget-seats/versions.jsonl"

# The stub replaces fork-sandbox.sh entirely: no clone, no sandbox, no
# network. It captures its own argv for the test to inspect and writes
# summary.json immediately (so lkml-round.sh's wait loop never sleeps);
# the clone_dir it names holds no .git/lkml-out, so the harvest finds
# nothing to post.
cat > "$stub_bin/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
task_meta=""
i=0
while (( i < n )); do
    if [[ "${args[$i]}" == --task-meta ]]; then
        task_meta="${args[$((i+1))]}"
    fi
    i=$(( i + 1 ))
done
persona="$(printf '%s' "$task_meta" | jq -r '.tags[2]')"
printf '%s\n' "${args[*]}" > "$STUB_CAPTURE_DIR/$persona.argv"
run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
printf '0\n' > "$run_dir/exit-code"
jq -n --arg clone_dir "$run_dir/clone/proj" --arg branch "stub-branch" \
    '{clone_dir: $clone_dir, branch: $branch, base_sha: "0000000000000000000000000000000000000000", commits: 0, fetched: false}' \
    > "$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  $run_dir"
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

launch_round() {  # launch_round <seats-file | ABSENT> <personas-csv> [extra round args...] -> OUT/RC
    local file="$1" personas_csv="$2"; shift 2
    local env_seats=ABSENT
    [[ "$file" != ABSENT ]] && env_seats="$file"
    local env=()
    if [[ "$env_seats" == ABSENT ]]; then
        env=(HOME="$home_dir" LKML_SEATS_FILE='')
    else
        env=(HOME="$home_dir" LKML_SEATS_FILE="$env_seats")
    fi
    OUT="$(env "${env[@]}" PATH="$stub_bin:$PATH" \
        STUB_CAPTURE_DIR="$capture_dir" STUB_RUN_PREFIX="$run_prefix_dir" \
        "$round" widget-seats --project "$project_dir" --checkout somebranch \
        --base somebranch --personas "$personas_csv" --personas-dir "$personas_test_dir" \
        "$@" 2>&1)"
    RC=$?
}
argv_of() { cat "$capture_dir/$1.argv" 2>/dev/null; }
# harness_of <persona> — the exact value of the stub's --harness argument,
# i.e. the full harness/model token. Substring matches on the flag (e.g.
# "--harness pi-local") also match the wrong composition "--harness
# pi-local/opus"; the cross-scope model drop survived the suite exactly
# that way, so every harness assertion below checks the whole token.
harness_of() {
    local prev="" a
    for a in $(argv_of "$1"); do
        if [[ "$prev" == "--harness" ]]; then printf '%s' "$a"; return 0; fi
        prev="$a"
    done
    return 1
}

printf '\n== seats file absent: today%s behavior, no announcements ==\n' "'"
rm -f -- "$capture_dir"/*.argv
launch_round ABSENT core,author,ci
check "absent seats file: round exits 0" "0" "$RC"
contains "absent seats file: core launches with its frontmatter pin" "$(argv_of core)" "--harness claude/opus"
contains "absent seats file: author launches with its frontmatter pin" "$(argv_of author)" "--harness claude/opus"
check "absent seats file: ci launches with its frontmatter pin" "pi-local" "$(harness_of ci)"
case "$OUT" in
    *"seat "*) no "absent seats file announces nothing" "$OUT" ;;
    *) ok "absent seats file announces nothing" ;;
esac

printf '\n== seats default: re-seats every launched persona, loudly ==\n'
cat > "$work/seats-round.yaml" <<'YAML'
default:
  harness: pi-local
YAML
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round.yaml" core,author,ci
check "seats default: round exits 0" "0" "$RC"
check "seats default: core is launched on pi-local" "pi-local" "$(harness_of core)"
check "seats default: author is launched on pi-local" "pi-local" "$(harness_of author)"
check "seats default: ci is launched on pi-local" "pi-local" "$(harness_of ci)"
contains "core's moved seat is announced" "$OUT" \
    "lkml-round: seat core: pi-local (seats-round.yaml, was claude/opus)"
contains "author's moved seat is announced" "$OUT" \
    "lkml-round: seat author: pi-local (seats-round.yaml, was claude/opus)"
case "$OUT" in
    *"seat ci: "*) no "ci's unchanged seat is not announced" "$OUT" ;;
    *) ok "ci's unchanged seat is not announced" ;;
esac

printf '\n== per-persona entry beats the default, in the round ==\n'
cat > "$work/seats-round-perp.yaml" <<'YAML'
default:
  harness: pi-local
personas:
  author:
    harness: claude
    model: opus
YAML
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round-perp.yaml" core,author,ci
check "per-persona round exits 0" "0" "$RC"
contains "per-persona entry: author stays on claude/opus" "$(argv_of author)" "--harness claude/opus"
check "per-persona entry: core still goes to pi-local" "pi-local" "$(harness_of core)"

printf '\n== a personas.<p> harness drops the default%s model, in the round ==\n' "'"
cat > "$work/seats-round-pdrop.yaml" <<'YAML'
default:
  harness: claude
  model: sonnet
personas:
  core:
    harness: pi-local
YAML
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round-pdrop.yaml" core,author,ci
check "persona-harness round exits 0" "0" "$RC"
check "core's persona harness is the bare harness" "pi-local" "$(harness_of core)"
check "author takes the default's model" "claude/sonnet" "$(harness_of author)"
check "ci takes the default's model" "claude/sonnet" "$(harness_of ci)"
contains "core's re-seat to the bare harness is announced" "$OUT" \
    "lkml-round: seat core: pi-local (seats-round-pdrop.yaml, was claude/opus)"

printf '\n== a seats thinking reaches the seat via --pi-args ==\n'
cat > "$work/seats-round-thinking.yaml" <<'YAML'
default:
  harness: pi-local
  thinking: low
YAML
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round-thinking.yaml" core,author,ci
contains "seats thinking is passed to a pi-local seat via --pi-args" \
    "$(argv_of core)" "--pi-args --thinking low"

printf '\n== a seats thinking that cannot apply refuses the round ==\n'
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-thinknopy.yaml" core,author,ci
if (( RC != 0 )); then ok "explicit thinking on a non-pi seat refuses the round"; else no "explicit thinking on a non-pi seat refuses the round" "exit 0: $OUT"; fi
contains "the round prints the refusal" "$OUT" "not a pi flavor"
n_launches=$(find "$capture_dir" -name '*.argv' | wc -l | tr -d '[:space:]')
check "the refusal launches no persona" "0" "$n_launches"

printf '\n== a seat moved off pi drops the launch line%s thinking ==\n' "'"
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-harnoffpi.yaml" core,thinky
check "off-pi round exits 0" "0" "$RC"
contains "the launch line does not mention the dropped thinking" "$OUT" \
    "launching thinky (claude)..."
case "$(argv_of thinky)" in
    *--pi-args*) no "no --pi-args reaches a claude seat" "$(argv_of thinky)" ;;
    *) ok "no --pi-args reaches a claude seat" ;;
esac
rm -f -- "$capture_dir"/*.argv
launch_round ABSENT thinky --model-override claude
contains "a bare override off pi drops the launch line thinking" "$OUT" \
    "launching thinky (claude)..."
case "$(argv_of thinky)" in
    *--pi-args*) no "a bare override off pi passes no --pi-args" "$(argv_of thinky)" ;;
    *) ok "a bare override off pi passes no --pi-args" ;;
esac

printf '\n== --model-override still beats the seats file, and stays quiet ==\n'
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round.yaml" core,author,ci --model-override pi-local
check "bare override beats seats: round exits 0" "0" "$RC"
check "bare override wins: core launches on the bare harness" "pi-local" "$(harness_of core)"
check "bare override wins: author launches on the bare harness" "pi-local" "$(harness_of author)"
check "bare override wins: ci launches on the bare harness" "pi-local" "$(harness_of ci)"
case "$(argv_of core)" in
    *"pi-local/opus"*) no "bare override drops the persona's frontmatter model" "$(argv_of core)" ;;
    *) ok "bare override drops the persona's frontmatter model" ;;
esac
case "$OUT" in
    *"seat "*) no "bare override does not double-announce the seats file" "$OUT" ;;
    *) ok "bare override does not double-announce the seats file" ;;
esac
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-round.yaml" core,author,ci --model-override claude/sonnet
check "combined override wins: round exits 0" "0" "$RC"
contains "combined override wins: core launches on the override verbatim" "$(argv_of core)" "--harness claude/sonnet"
contains "combined override wins: author launches on the override verbatim" "$(argv_of author)" "--harness claude/sonnet"
contains "combined override wins: ci launches on the override verbatim" "$(argv_of ci)" "--harness claude/sonnet"
case "$OUT" in
    *"seat "*) no "combined override does not double-announce the seats file" "$OUT" ;;
    *) ok "combined override does not double-announce the seats file" ;;
esac

printf '\n== a bad seats file refuses the round before any launch ==\n'
printf 'defaults:\n  harness: pi-local\n' > "$work/seats-bad.yaml"
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-bad.yaml" core,author,ci
if (( RC != 0 )); then ok "bad seats file exits non-zero"; else no "bad seats file exits non-zero" "exit 0: $OUT"; fi
contains "bad seats file refusal names the key" "$OUT" "unknown top-level key 'defaults'"
n_launches=$(find "$capture_dir" -name '*.argv' | wc -l | tr -d '[:space:]')
check "bad seats file launches no persona" "0" "$n_launches"
printf 'personas:\n  corr:\n    harness: claude\n' > "$work/seats-bad.yaml"
rm -f -- "$capture_dir"/*.argv
launch_round "$work/seats-bad.yaml" core,author,ci
if (( RC != 0 )); then ok "a typo'd persona name exits non-zero"; else no "a typo'd persona name exits non-zero" "exit 0: $OUT"; fi
contains "typo'd persona name is named" "$OUT" "personas.corr"
n_launches=$(find "$capture_dir" -name '*.argv' | wc -l | tr -d '[:space:]')
check "typo'd persona name launches no persona" "0" "$n_launches"

printf '\n== round consults the default seats path without the env hook ==\n'
# The seats file sits at the resolver's owned default path under the
# controlled HOME and no LKML_SEATS_FILE is set: the round must find
# and announce it, proving the launcher did not re-derive the path.
cat > "$home_dir/.config/fork-sandbox/lkml-seats.yaml" <<'YAML'
default:
  harness: pi-local
YAML
rm -f -- "$capture_dir"/*.argv
OUT="$(env HOME="$home_dir" PATH="$stub_bin:$PATH" \
    STUB_CAPTURE_DIR="$capture_dir" STUB_RUN_PREFIX="$run_prefix_dir" \
    "$round" widget-seats --project "$project_dir" --checkout somebranch \
    --base somebranch --personas core,author,ci --personas-dir "$personas_test_dir" \
    2>&1)"
RC=$?
check "default-path round exits 0" "0" "$RC"
contains "default-path round re-seats the panel and announces it" "$OUT" \
    "lkml-round: seat core: pi-local (lkml-seats.yaml, was claude/opus)"
rm -f -- "$home_dir/.config/fork-sandbox/lkml-seats.yaml"

printf '\n== the author scripts consume the same seats resolution ==\n'
# Same seats file for all three: the author persona (claude/opus in
# frontmatter) moves to a pi-local seat with a thinking level, so the
# launch line shows harness, model drop and thinking in one string.
cat > "$work/seats-author.yaml" <<'YAML'
default:
  harness: pi-local
  thinking: low
YAML

launch_author() {  # launch_author <script> <seats-file | ABSENT> [script args...]
    local script="$1" file="$2"; shift 2
    local env=()
    if [[ "$file" == ABSENT ]]; then
        env=(HOME="$home_dir" LKML_SEATS_FILE='')
    else
        env=(HOME="$home_dir" LKML_SEATS_FILE="$file")
    fi
    OUT="$(env "${env[@]}" PATH="$stub_bin:$PATH" "$script" "$@" 2>&1)"
    RC=$?
}

# The stub's commits-0 summary takes each script to its own downstream
# stop condition (no commits / no cover letter), exit 1 -- the launch
# lines under test print before the wait, and a seats file must not
# change how a run that produced nothing is refused.
printf '\n-- revise --\n'
launch_author "$repo_dir/scripts/lkml-revise.sh" "$work/seats-author.yaml" \
    widget-seats --project "$project_dir" --checkout somebranch --version 1 \
    --base somebranch --personas-dir "$personas_test_dir"
contains "revise: the seats file re-seats the author" "$OUT" \
    "launching author (pi-local, thinking low) for v2"
contains "revise: the moved seat is announced" "$OUT" \
    "lkml-revise: seat author: pi-local (seats-author.yaml, was claude/opus)"
launch_author "$repo_dir/scripts/lkml-revise.sh" "$work/seats-harnoffpi.yaml" \
    widget-seats --project "$project_dir" --checkout somebranch --version 1 \
    --base somebranch --personas-dir "$personas_test_dir" --author thinky
contains "revise: a seat moved off pi keeps the launch line clean" "$OUT" \
    "launching thinky (claude) for v2"
launch_author "$repo_dir/scripts/lkml-revise.sh" "$work/seats-thinknopy.yaml" \
    widget-seats --project "$project_dir" --checkout somebranch --version 1 \
    --base somebranch --personas-dir "$personas_test_dir" --author thinky
if (( RC != 0 )); then ok "revise: explicit thinking on a non-pi seat refuses"; else no "revise: explicit thinking on a non-pi seat refuses" "exit 0: $OUT"; fi
contains "revise: the refusal names the persona" "$OUT" "'thinky'"
launch_author "$repo_dir/scripts/lkml-revise.sh" ABSENT \
    widget-seats --project "$project_dir" --checkout somebranch --version 1 \
    --base somebranch --personas-dir "$personas_test_dir" --model-override pi-local
contains "revise: bare override drops the persona model" "$OUT" \
    "launching author (pi-local) for v2"
case "$OUT" in
    *"pi-local/opus"*) no "revise: bare override never composes the frontmatter model" "$OUT" ;;
    *) ok "revise: bare override never composes the frontmatter model" ;;
esac
launch_author "$repo_dir/scripts/lkml-revise.sh" ABSENT \
    widget-seats --project "$project_dir" --checkout somebranch --version 1 \
    --base somebranch --personas-dir "$personas_test_dir" --model-override claude/sonnet
contains "revise: combined override passes through verbatim" "$OUT" \
    "launching author (claude/sonnet) for v2"

printf '\n-- cover --\n'
launch_author "$repo_dir/scripts/lkml-cover.sh" "$work/seats-author.yaml" \
    widget-seats --project "$project_dir" --checkout somebranch --base somebranch \
    --patches "$work/patches" --personas-dir "$personas_test_dir"
contains "cover: the seats file re-seats the author" "$OUT" \
    "launching author (pi-local, thinking low)"
contains "cover: the moved seat is announced" "$OUT" \
    "lkml-cover: seat author: pi-local (seats-author.yaml, was claude/opus)"
launch_author "$repo_dir/scripts/lkml-cover.sh" "$work/seats-harnoffpi.yaml" \
    widget-seats --project "$project_dir" --checkout somebranch --base somebranch \
    --patches "$work/patches" --personas-dir "$personas_test_dir" --author thinky
contains "cover: a seat moved off pi keeps the launch line clean" "$OUT" \
    "launching thinky (claude)"
launch_author "$repo_dir/scripts/lkml-cover.sh" ABSENT \
    widget-seats --project "$project_dir" --checkout somebranch --base somebranch \
    --patches "$work/patches" --personas-dir "$personas_test_dir" --model-override pi-local
contains "cover: bare override drops the persona model" "$OUT" \
    "launching author (pi-local)"
case "$OUT" in
    *"pi-local/opus"*) no "cover: bare override never composes the frontmatter model" "$OUT" ;;
    *) ok "cover: bare override never composes the frontmatter model" ;;
esac
launch_author "$repo_dir/scripts/lkml-cover.sh" ABSENT \
    widget-seats --project "$project_dir" --checkout somebranch --base somebranch \
    --patches "$work/patches" --personas-dir "$personas_test_dir" --model-override claude/sonnet
contains "cover: combined override passes through verbatim" "$OUT" \
    "launching author (claude/sonnet)"

printf '\n-- series --\n'
launch_author "$repo_dir/scripts/lkml-series.sh" "$work/seats-author.yaml" \
    widget-seats --project "$project_dir" --range "HEAD..somebranch" \
    --personas-dir "$personas_test_dir"
contains "series: the seats file re-seats the author" "$OUT" \
    "launching author (pi-local, thinking low) for v1"
contains "series: the moved seat is announced" "$OUT" \
    "lkml-series: seat author: pi-local (seats-author.yaml, was claude/opus)"
launch_author "$repo_dir/scripts/lkml-series.sh" "$work/seats-harnoffpi.yaml" \
    widget-seats --project "$project_dir" --range "HEAD..somebranch" \
    --personas-dir "$personas_test_dir" --author thinky
contains "series: a seat moved off pi keeps the launch line clean" "$OUT" \
    "launching thinky (claude) for v1"
launch_author "$repo_dir/scripts/lkml-series.sh" ABSENT \
    widget-seats --project "$project_dir" --range "HEAD..somebranch" \
    --personas-dir "$personas_test_dir" --model-override pi-local
contains "series: bare override drops the persona model" "$OUT" \
    "launching author (pi-local) for v1"
case "$OUT" in
    *"pi-local/opus"*) no "series: bare override never composes the frontmatter model" "$OUT" ;;
    *) ok "series: bare override never composes the frontmatter model" ;;
esac
launch_author "$repo_dir/scripts/lkml-series.sh" ABSENT \
    widget-seats --project "$project_dir" --range "HEAD..somebranch" \
    --personas-dir "$personas_test_dir" --model-override claude/sonnet
contains "series: combined override passes through verbatim" "$OUT" \
    "launching author (claude/sonnet) for v1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
