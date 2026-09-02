#!/usr/bin/env bash
# fork-sandbox-preset-test.sh — Exercise --preset parsing, compilation, flag
# precedence, and the engine paths only presets reach (fix seats, repeat
# passes), the last with real stubbed --foreground runs.
#
# Usage: tests/fork-sandbox-preset-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
run_log="$repo_dir/scripts/sandbox-run-log.py"

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
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "expected to find '$needle' in: $haystack"
    fi
}

lacks() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "expected NOT to find '$needle' in: $haystack"
    fi
}

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export CODEX_HOME="$tmp/codex"
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
presets_dir="$FORK_SANDBOX_CONFIG_DIR/presets"
mkdir -p "$CODEX_HOME" "$presets_dir"
cat > "$CODEX_HOME/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list"}]}
JSON

run() {
    # Scoped to what presets compile: the preset line, the harness/model
    # pair, the review/maintainer values and the preset-only knobs. The rest
    # of --dry-run's output has tests of its own.
    "$launcher" --dry-run "$@" unused-project unused-handoff \
        | grep -v -e '^prompt_overlay_' -e '^refresh_' -e '^outbox_max_bytes='
}

run_refresh() {
    # The refresh keys, for the tests about them.
    "$launcher" --dry-run "$@" unused-project unused-handoff \
        | grep -e '^refresh_at=' -e '^refresh_max='
}

err="$tmp/err"

printf '== compiling a preset onto the launch configuration ==\n'

cat > "$presets_dir/fast.yaml" <<'EOF'
# One cheap code leg, nothing else.
agents:
  coder:
    harness: claude
    model: haiku
pipeline:
  - action: code
    agent: coder
EOF

out="$(run --preset fast 2>"$err")"
check "code-only preset compiles" \
    $'preset=fast\nharness=claude\nmodel=haiku' "$out"
contains "launch announces the preset and its seats" "$(cat "$err")" \
    "preset 'fast'"
contains "the announcement names the code seat" "$(cat "$err")" \
    "code coder (claude/haiku)"

cat > "$presets_dir/deep.yaml" <<'EOF'
agents:
  haiku-coder:
    harness: claude
    model: haiku
    repeat: 3
    refresh-at: 0.6
    claude-args: --effort high
  reviewer:
    harness: pi/moonshotai/kimi-k3
  coder:
    harness: claude
    model: fable
  elder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: haiku-coder
  - action: review
    repeat: 3
    agent: reviewer
    fix_agent: haiku-coder
  - action: maintain
    repeat: 2
    agent: elder
    fix_agent: coder
EOF

out="$(run --preset deep 2>"$err")"
check "fix seats and repeats compile" \
    $'preset=deep\nharness=claude\nmodel=haiku\nreview_model=moonshotai/kimi-k3\nreview_harness=pi\nmaintainer_loop=2\nmaintainer_model=opus\nmaintainer_harness=claude\ncode_repeat=3\nfix_harness=claude\nfix_model=haiku\nfix_repeat=3\nmaintainer_fix_harness=claude\nmaintainer_fix_model=fable' \
    "$out"
contains "the announcement shows the repeat and the fix seats" \
    "$(cat "$err")" \
    "code haiku-coder (claude/haiku) x3, review reviewer (pi/moonshotai/kimi-k3) repeat=3 fix=haiku-coder, maintain elder (claude/opus) repeat=2 fix=coder"

out="$(run_refresh --preset deep 2>/dev/null | grep '^refresh_at=')"
check "refresh keys ride the code agent" "refresh_at=0.6" "$out"

cat > "$presets_dir/self-review.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: fable
    repeat: 2
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: coder
EOF

out="$(run --preset self-review 2>/dev/null)"
check "a defaulted fix seat carries the code agent's repeat, builds no seat" \
    $'preset=self-review\nharness=claude\nmodel=fable\nreview_model=fable\nreview_harness=claude\ncode_repeat=2\nfix_repeat=2' \
    "$out"

cat > "$presets_dir/maintain-only.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: fable
  elder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: maintain
    repeat: 1
    agent: elder
EOF

out="$(run --preset maintain-only 2>/dev/null)"
check "a maintain step without a review step is a valid pipeline" \
    $'preset=maintain-only\nharness=claude\nmodel=fable\nmaintainer_loop=1\nmaintainer_model=opus\nmaintainer_harness=claude' \
    "$out"

cat > "$presets_dir/aliased.yaml" <<'EOF'
agents:
  coder:
    harness: codex
    model: sol
pipeline:
  - action: code
    agent: coder
EOF

out="$(run --preset aliased 2>"$err")"
check "a preset model goes through alias resolution" \
    $'preset=aliased\nharness=codex\nmodel=gpt-5.6-sol' "$out"

printf '\n== flags override their preset counterparts ==\n'

out="$(run --preset deep --model opus 2>"$err")"
contains "--model overrides the code seat's model" "$(cat "$err")" \
    "--model overrides the code seat's model"
contains "the compiled model is the flag's" "$out" $'\nmodel=opus'

out="$(run --preset deep --review-loop 5 2>"$err")"
contains "--review-loop overrides the review loop's repeat" "$(cat "$err")" \
    "--review-loop overrides the review loop's repeat"

out="$(run --preset deep --harness codex 2>"$err")"
contains "the seat override drops model, args and repeat, said out loud" \
    "$(cat "$err")" \
    "--harness overrides the code seat; the preset's model, arguments and repeat for it are not applied"
lacks "an overridden code seat compiles no repeat" "$out" "code_repeat="
contains "an explicit fix seat survives a code-seat override" "$out" \
    $'fix_harness=claude\nfix_model=haiku\nfix_repeat=3'

cat > "$presets_dir/default-fix-repeat.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    repeat: 2
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
EOF
out="$(run --preset default-fix-repeat --harness codex 2>"$err")"
contains "a defaulted fix seat's repeat is dropped with the overridden code seat" \
    "$(cat "$err")" \
    "so its repeat is not applied to review fix legs"
lacks "the dropped default fix repeat compiles nothing" "$out" "fix_repeat="

out="$(run --preset deep --review-harness codex --review-model sol 2>"$err")"
contains "--review-harness overrides the review seat" "$(cat "$err")" \
    "--review-harness overrides the review seat"
contains "the fix seat is not the review seat and survives" "$out" \
    $'fix_harness=claude\nfix_model=haiku'

printf '\n== refusals ==\n'

refuses() {
    local label="$1" needle="$2"; shift 2
    if run "$@" > /dev/null 2>"$err"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$(cat "$err")" "$needle"
    fi
}

refuses "an unknown preset is refused and the listing names the rest" \
    "Available presets:" --preset nope
refuses "a path-shaped preset name is refused" \
    "never" --preset ../evil

refuses "a preset with loops is refused with --review-only" \
    "--review-only runs one review leg" \
    --preset deep --review-only --checkout HEAD

cat > "$presets_dir/fast3.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    repeat: 3
pipeline:
  - action: code
    agent: coder
EOF
refuses "a repeating code seat is refused with --review-only" \
    "nothing to repeat" \
    --preset fast3 --review-only --checkout HEAD

refuses "a preset's compiled values meet the --k8s refusals like flags do" \
    "--claude-args is not supported with --k8s" \
    --preset deep --k8s
refuses "fix seats and repeat are refused with --k8s by name" \
    "preset fix seats and repeat are not yet supported" \
    --preset fast3 --k8s

cat > "$presets_dir/codex-fix.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: fable
  fixer:
    harness: codex
    model: gpt-5.6-sol
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: fixer
EOF
refuses "a codex fix seat is refused by name" \
    "codex fix seat is not yet supported" --preset codex-fix

bad() {
    # Write a preset named bad, expect a parse refusal containing $2 (and
    # $3, when given -- usually the path that addresses the error).
    local label="$1" needle="$2" needle2="${3:-}"
    cat > "$presets_dir/bad.yaml"
    if run --preset bad > /dev/null 2>"$err"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$(cat "$err")" "$needle"
        [[ -z "$needle2" ]] || contains "$label (addressed by path)" \
            "$(cat "$err")" "$needle2"
    fi
}

bad "an unknown top-level key is refused" "unknown top-level key 'jobs'" <<'EOF'
agents:
  coder:
    harness: claude
jobs: []
pipeline:
  - action: code
    agent: coder
EOF

bad "an empty file is refused" "must be a mapping" </dev/null

bad "invalid YAML surfaces as a parse error" "not valid YAML" <<'EOF'
agents: [
EOF

bad "a duplicate agent is refused" "duplicate key 'coder'" <<'EOF'
agents:
  coder:
    harness: claude
  coder:
    harness: codex
pipeline:
  - action: code
    agent: coder
EOF

bad "an unknown agent property is refused" \
    "unknown agent property" "agents.coder.temperature" <<'EOF'
agents:
  coder:
    harness: claude
    temperature: 0.2
pipeline:
  - action: code
    agent: coder
EOF

bad "an unknown harness is refused" "not 'claud'" <<'EOF'
agents:
  coder:
    harness: claud
pipeline:
  - action: code
    agent: coder
EOF

bad "an agent without a harness is refused" "has no harness" <<'EOF'
agents:
  coder:
    model: fable
pipeline:
  - action: code
    agent: coder
EOF

bad "an undefined agent in the pipeline is refused" \
    "undefined agent 'ghost'" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: ghost
EOF

bad "an undefined fix agent is refused" \
    "undefined agent 'ghost'" "pipeline[1].fix_agent" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
    fix_agent: ghost
EOF

bad "the pipeline must start with the code step" \
    "starts with the code step" "pipeline[0]" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: review
    repeat: 1
    agent: coder
EOF

bad "refresh keys on the code step point at the agent" \
    "agent property now" "pipeline[0].refresh-at" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
    refresh-at: 0.6
EOF

bad "a second code step is refused" \
    "the agent's 'repeat' property" "pipeline[1]" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: code
    agent: coder
EOF

bad "a review step without repeat is refused" \
    "needs 'repeat', its loop cap" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: review
    agent: coder
EOF

bad "a non-integer repeat is refused" "positive integer" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: lots
    agent: coder
EOF

bad "an unknown step key is refused" \
    "unknown review-step key" "pipeline[1].on_approved" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
    on_approved: break
EOF

bad "a second review step is refused" "at most one review step" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: coder
EOF

bad "a maintain step before the review step is refused" \
    "the review step comes before the maintain step" <<'EOF'
agents:
  coder:
    harness: claude
  elder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: maintain
    repeat: 1
    agent: elder
  - action: review
    repeat: 1
    agent: coder
EOF

bad "repeat on an agent that never codes is refused" \
    "never codes" "agents.reviewer" <<'EOF'
agents:
  coder:
    harness: claude
  reviewer:
    harness: claude
    model: opus
    repeat: 3
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
EOF

bad "args on an agent off the first code seat are refused" \
    "reach only that seat's legs" <<'EOF'
agents:
  coder:
    harness: claude
  fixer:
    harness: claude
    model: haiku
    claude-args: --effort high
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
    fix_agent: fixer
EOF

bad "refresh keys on an agent off the first code seat are refused" \
    "context refresh reaches only" <<'EOF'
agents:
  coder:
    harness: claude
  fixer:
    harness: claude
    model: haiku
    refresh-at: 0.6
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
    fix_agent: fixer
EOF

bad "refresh keys on a non-claude code seat are refused" \
    "claude-only" <<'EOF'
agents:
  coder:
    harness: pi
    model: moonshotai/kimi-k3
    refresh-at: 0.6
pipeline:
  - action: code
    agent: coder
EOF

bad "a seated pi agent without a model is refused" \
    "harness pi needs a model" "agents.fixer" <<'EOF'
agents:
  coder:
    harness: claude
  fixer:
    harness: pi
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
    fix_agent: fixer
EOF

if run --preset deep > /dev/null 2>"$err"; then
    lacks "seated agents draw no unused warning" "$(cat "$err")" "sits no seat"
else
    no "seated agents draw no unused warning" "$(cat "$err")"
fi

cat > "$presets_dir/spare.yaml" <<'EOF'
agents:
  coder:
    harness: claude
  spare:
    harness: codex
pipeline:
  - action: code
    agent: coder
EOF
out="$(run --preset spare 2>"$err")"
contains "an agent that sits no seat draws a warning" "$(cat "$err")" \
    "agent 'spare' is defined but sits no seat"

printf '\n== the presets directory ==\n'

alt="$tmp/alt-presets"
mkdir -p "$alt"
cat > "$alt/only-here.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
EOF
out="$(FORK_SANDBOX_PRESETS_DIR="$alt" run --preset only-here 2>/dev/null)"
check "FORK_SANDBOX_PRESETS_DIR moves the presets directory" \
    $'preset=only-here\nharness=claude\nmodel=opus' "$out"

if FORK_SANDBOX_PRESETS_DIR="$tmp/no-such-dir" run --preset anything \
    > /dev/null 2>"$err"; then
    no "a missing presets directory is refused, not silence"
else
    contains "a missing presets directory is refused, not silence" \
        "$(cat "$err")" "no presets directory yet"
fi

out="$(run --harness claude --model opus 2>/dev/null)"
check "no --preset means no preset line and no preset machinery" \
    $'harness=claude\nmodel=opus' "$out"

printf '\n== the engine: repeat passes and fix seats (--foreground, stubs) ==\n'

# Real foreground runs with every wrapper stubbed and the backend faked into
# image mode -- the same machinery the maintainer and review-harness tests
# use. The stub logs each call's argv and plays a scripted role by call
# number.
real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-preset-real-stub.XXXXXX)"
tmpdirs+=("$real_stub")
cat > "$real_stub/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
cat > "$real_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

clone_dir="" prev=""
for a in "$@"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done

cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"

# The scripted role: FAKE_SCRIPT holds one action per line, indexed by call
# number -- "commit", "findings", "approved", or "noop".
action="$(sed -n "${n}p" "$FAKE_SCRIPT" 2>/dev/null)"
case "$action" in
commit)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "stub leg $n"
    ;;
findings)
    printf 'FINDINGS\n\nfile.txt:1 the stub found a problem\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
approved)
    printf 'APPROVED\n\nChecked: everything.\n\n## Report\nFine.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$real_stub"/*

real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")
install -m 600 /dev/null "$real_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$real_cfg/pi.env"
real_presets="$real_cfg/presets"
mkdir -p "$real_presets"

proj="$(mktemp -d "$HOME/src/fs-preset-test.XXXXXX")"; tmpdirs+=("$proj")
(
    cd "$proj" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'hello\n' > file.txt \
        && git add file.txt \
        && git commit -q -m init
) >/dev/null 2>&1
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-preset-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

prep_stub() {
    # Allocate the stub's files in THIS shell -- run_stubbed itself runs in
    # a command substitution, where an assignment would die with the
    # subshell. $1 is the scripted actions, one per expected call.
    count="$(mktemp)"; tmpdirs+=("$count")
    argv_log="$(mktemp)"; tmpdirs+=("$argv_log")
    script_file="$(mktemp)"; tmpdirs+=("$script_file")
    printf '%s\n' "$1" > "$script_file"
}

run_stubbed() {
    # Launcher args only; prep_stub ran first. Prints the run dir.
    local out rc rd
    out="$(PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$rd" ]]; then
        printf 'run_stubbed failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

# A. Repeat passes: repeat: 3 on the code agent runs three coding legs on
# the same prompt, unconditionally, and the run ends after the last.
cat > "$real_presets/rep3.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    repeat: 3
pipeline:
  - action: code
    agent: coder
EOF
prep_stub $'commit\nnoop\ncommit'
rd_a="$(run_stubbed --preset rep3 \
    --branch "sandbox-test-rep3-$$")" && tmpdirs+=("$rd_a")
if [[ -n "${rd_a:-}" ]]; then
    check "repeat: 3 runs three coding legs" "3" "$(cat "$count")"
    check "the run's exit code is published after the last pass" "0" \
        "$(cat "$rd_a/exit-code" 2>/dev/null)"
    if [[ -s "$rd_a/events-code-2.jsonl" && -s "$rd_a/events-code-3.jsonl" ]]; then
        ok "repeat passes get their own events files"
    else
        no "repeat passes get their own events files" \
            "$(find "$rd_a" -maxdepth 1 -name 'events-*' 2>/dev/null | tr '\n' ' ')"
    fi
    contains "run.env records the repeat" "$(cat "$rd_a/run.env")" \
        "code_repeat=3"
    if cmp -s "$rd_a/preset.yaml" "$real_presets/rep3.yaml"; then
        ok "a --preset launch leaves the definition in the run dir, byte-identical"
    else
        no "a --preset launch leaves the definition in the run dir, byte-identical" \
            "$rd_a/preset.yaml differs from $real_presets/rep3.yaml"
    fi
    check "preset.json's sha256 is the run-dir copy's hash" \
        "$(jq -r '.sha256' "$rd_a/preset.json")" \
        "$(sha256sum "$rd_a/preset.yaml" | cut -d' ' -f1)"
    check "a noop middle pass does not stop the passes" "3" "$(cat "$count")"
fi

# B. A fix seat of its own, with repeat: the review loop's fix legs run the
# fix agent's model, twice per iteration.
cat > "$real_presets/fixseat.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: fable
  fixer:
    harness: claude
    model: haiku
    repeat: 2
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
    fix_agent: fixer
EOF
# Call order: implement, review (findings), fix pass 1, fix pass 2,
# review (approved).
prep_stub $'commit\nfindings\ncommit\ncommit\napproved'
rd_b="$(run_stubbed \
    --preset fixseat --branch "sandbox-test-fixseat-$$")" && tmpdirs+=("$rd_b")
if [[ -n "${rd_b:-}" ]]; then
    check "the five legs ran: code, review, fix x2, review" "5" "$(cat "$count")"
    contains "the implement leg ran the code seat's model" \
        "$(sed -n 1p "$argv_log")" "--model fable"
    contains "the review legs ran the reviewer's model" \
        "$(sed -n 2p "$argv_log")" "--model opus"
    contains "fix pass 1 ran the fix agent's model" \
        "$(sed -n 3p "$argv_log")" "--model haiku"
    contains "fix pass 2 ran the fix agent's model" \
        "$(sed -n 4p "$argv_log")" "--model haiku"
    check "the loop ended approved" "approved" \
        "$(jq -r '.ended' "$rd_b/review-loop.json" 2>/dev/null)"
    check "the record names the fix seat" "claude/haiku/2" \
        "$(jq -r '"\(.fix_harness)/\(.fix_model)/\(.fix_repeat)"' \
            "$rd_b/review-loop.json" 2>/dev/null)"
    check "iteration 1's fix exit is the last pass's" "0" \
        "$(jq -r '.iterations[0].fix_exit' "$rd_b/review-loop.json" 2>/dev/null)"
    if [[ -s "$rd_b/events-fix-1.jsonl" && -s "$rd_b/events-fix-1-p2.jsonl" ]]; then
        ok "fix passes get their own events files"
    else
        no "fix passes get their own events files" \
            "$(find "$rd_b" -maxdepth 1 -name 'events-*' 2>/dev/null | tr '\n' ' ')"
    fi
    contains "run.sh froze the fix seat's own command" \
        "$(grep '^fix_sandbox_cmd=' "$rd_b/run.sh")" "--model haiku"
fi

# C. A run with no preset emits none of the new state: run.sh and run.env
# stay byte-compatible with what they were before fix seats existed.
prep_stub 'commit'
rd_c="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox-test-plain-$$")" && tmpdirs+=("$rd_c")
if [[ -n "${rd_c:-}" ]]; then
    if [[ "$(grep -cE '^(fix_harness|fix_model|fix_repeat|fix_sandbox_cmd|fxr_|fxm_|mntfix_|code_repeat)' "$rd_c/run.sh")" == "0" ]]; then
        ok "a plain run.sh emits no fix-seat or repeat state"
    else
        no "a plain run.sh emits no fix-seat or repeat state" \
            "$(grep -E '^(fix_harness|fix_model|fix_repeat|fix_sandbox_cmd|fxr_|fxm_|mntfix_|code_repeat)' "$rd_c/run.sh")"
    fi
    if [[ "$(grep -cE '^(fix_|maintainer_fix_|code_repeat)' "$rd_c/run.env")" == "0" ]]; then
        ok "a plain run.env records none of the preset-only knobs"
    else
        no "a plain run.env records none of the preset-only knobs" \
            "$(grep -E '^(fix_|maintainer_fix_|code_repeat)' "$rd_c/run.env")"
    fi
fi

printf '\n== sandbox-run-log.py: the preset definition in the archive ==\n'

if [[ -n "${rd_a:-}" && -x "$run_log" ]]; then
    # HOME redirection moves both the ledger and ARCHIVE_DIR, the same
    # way the prompt-overlay test records into a fake home.
    fakehome="$(mktemp -d /var/tmp/claude-scratch/fs-preset-fakehome.XXXXXX)"
    tmpdirs+=("$fakehome")
    mkdir -p "$fakehome/.claude"
    psha="$(jq -r '.sha256' "$rd_a/preset.json")"
    arch_dir="$fakehome/.claude/sandbox-handoffs/presets"

    if HOME="$fakehome" "$run_log" record --run-dir "$rd_a" >/dev/null 2>&1; then
        ok "sandbox-run-log.py record archives the preset definition"
        if cmp -s "$arch_dir/$psha.yaml" "$rd_a/preset.yaml"; then
            ok "the archive holds the definition bytes, keyed by the record's sha256"
        else
            no "the archive holds the definition bytes, keyed by the record's sha256" \
                "missing or wrong $arch_dir/$psha.yaml"
        fi
        rec="$(HOME="$fakehome" "$run_log" show "$(basename "$rd_a")")"
        check "the ledger entry carries preset.archive" \
            "$arch_dir/$psha.yaml" \
            "$(printf '%s' "$rec" | jq -r '.preset.archive')"

        # Same definition, second record: the existing archive must not
        # be rewritten (dedup is free because the key is the hash).
        before="$(stat -c %y "$arch_dir/$psha.yaml")"
        sleep 1
        if HOME="$fakehome" "$run_log" record --run-dir "$rd_a" >/dev/null 2>&1; then
            after="$(stat -c %y "$arch_dir/$psha.yaml")"
            check "a second record of the same preset does not rewrite the archive" \
                "$before" "$after"
        else
            no "a second record of the same preset does not rewrite the archive"
            "second record failed"
        fi
    else
        no "sandbox-run-log.py record archives the preset definition"
    fi

    # A run dir with preset.json but no preset.yaml (an older run):
    # records fine, warns, and the entry has no archive key.
    rd_old="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
    tmpdirs+=("$rd_old")
    cp -a -- "$rd_a/". "$rd_old/"
    rm -- "$rd_old/preset.yaml"
    err_old="$tmp/err-preset-old"
    if HOME="$fakehome" "$run_log" record --run-dir "$rd_old" \
        >/dev/null 2>"$err_old"; then
        ok "a run dir without preset.yaml still records"
        contains "its missing archive is warned on stderr" \
            "$(cat "$err_old")" "preset not archived"
        rec_old="$(HOME="$fakehome" "$run_log" show "$(basename "$rd_old")")"
        check "the entry keeps the provenance but has no preset.archive" \
            'rep3/null' \
            "$(printf '%s' "$rec_old" | jq -r '.preset.name + "/" + (.preset.archive // "null")')"
    else
        no "a run dir without preset.yaml still records"
    fi

    # A hand-crafted preset.json whose sha256 is missing must skip the
    # archive, not the record: the whole run_end entry survives, with no
    # archive key. (The same guard also covers a non-string sha256, which
    # raises TypeError.)
    rd_bad="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
    tmpdirs+=("$rd_bad")
    cp -a -- "$rd_a/". "$rd_bad/"
    printf '%s\n' '{"name":"rep3","file":"/nonexistent/presets/rep3.yaml"}' \
        > "$rd_bad/preset.json"
    err_bad="$tmp/err-preset-bad"
    if HOME="$fakehome" "$run_log" record --run-dir "$rd_bad" \
        >/dev/null 2>"$err_bad"; then
        ok "a preset.json without a sha256 still records"
        contains "its missing archive is warned on stderr" \
            "$(cat "$err_bad")" "preset not archived"
        rec_bad="$(HOME="$fakehome" "$run_log" show "$(basename "$rd_bad")")"
        check "the entry keeps the run but has no preset.archive" \
            'rep3/null' \
            "$(printf '%s' "$rec_bad" | jq -r '.preset.name + "/" + (.preset.archive // "null")')"
    else
        no "a preset.json without a sha256 still records"
    fi

    # A hand-crafted run dir whose preset.json sha256 does not match
    # preset.yaml's bytes must skip the archive, not the record: the
    # entry survives with provenance but no archive key, so a ledger
    # entry's preset.sha256 always identifies its archived bytes.
    rd_mm="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
    tmpdirs+=("$rd_mm")
    cp -a -- "$rd_a/". "$rd_mm/"
    jq '.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
        "$rd_mm/preset.json" > "$rd_mm/preset.json.tmp" \
        && mv "$rd_mm/preset.json.tmp" "$rd_mm/preset.json"
    err_mm="$tmp/err-preset-mismatch"
    if HOME="$fakehome" "$run_log" record --run-dir "$rd_mm" \
        >/dev/null 2>"$err_mm"; then
        ok "a preset.json sha256 that does not match preset.yaml still records"
        contains "its mismatched archive is warned on stderr" \
            "$(cat "$err_mm")" "preset not archived"
        rec_mm="$(HOME="$fakehome" "$run_log" show "$(basename "$rd_mm")")"
        check "the entry keeps the run but has no preset.archive" \
            'rep3/null' \
            "$(printf '%s' "$rec_mm" | jq -r '.preset.name + "/" + (.preset.archive // "null")')"
    else
        no "a preset.json sha256 that does not match preset.yaml still records"
    fi
else
    no "sandbox-run-log.py record archives the preset definition" \
        "prior stubbed run failed, or $run_log is not executable"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
