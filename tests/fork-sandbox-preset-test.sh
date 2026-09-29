#!/usr/bin/env bash
# fork-sandbox-preset-test.sh — Exercise --preset parsing, compilation, flag
# precedence, and the engine paths only presets reach (fix seats, repeat
# passes), the last with real stubbed --foreground runs.
#
# Usage: tests/fork-sandbox-preset-test.sh

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
run_log="$repo_dir/scripts/sandbox-run-log.py"

# Every run this suite launches is a fixture, not real work. Mark it so
# sandbox-run-log.py's list/stats exclude it by default: without this the
# operator's own log fills with synthetic runs, and the harness stats the
# sandbox-coder-mode skill tells orchestrators to consult become misleading.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
# Every real launch below writes launcher_session_id/creates a by-session
# symlink from CLAUDE_CODE_SESSION_ID -- scoped here so a real session
# running this suite never has its own by-session index polluted with
# entries for these throwaway fixture runs. The dedicated launcher_
# session_id/by-session tests further down set their own explicit
# FORK_SANDBOX_BY_SESSION_DIR per call instead, which overrides this
# default for that one command only.
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"

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
{"models":[{"slug":"gpt-5.6-sol","visibility":"list"},
           {"slug":"gpt-5.6-astra","visibility":"list"}]}
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

# network: sealed on the code seat must compile identically to the
# permanent harness: pi-local alias -- the central §5 parity case.
cat > "$presets_dir/sealed-alias.yaml" <<'EOF'
agents:
  coder:
    harness: pi-local
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
EOF
cat > "$presets_dir/sealed-explicit.yaml" <<'EOF'
agents:
  coder:
    harness: pi
    network: sealed
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
EOF
out_alias="$(run --preset sealed-alias 2>/dev/null | sed 's/^preset=.*/preset=X/')"
out_explicit="$(run --preset sealed-explicit 2>/dev/null | sed 's/^preset=.*/preset=X/')"
check "a code-seat network: sealed key compiles like harness: pi-local" \
    "$out_alias" "$out_explicit"

# The same equivalence on the review seat, the only route to a sealed
# review leg besides the undocumented --review-harness pi-local alias.
cat > "$presets_dir/rev-sealed-alias.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  reviewer:
    harness: pi-local
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
EOF
cat > "$presets_dir/rev-sealed-explicit.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  reviewer:
    harness: pi
    network: sealed
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
EOF
out_alias="$(run --preset rev-sealed-alias 2>/dev/null | sed 's/^preset=.*/preset=X/')"
out_explicit="$(run --preset rev-sealed-explicit 2>/dev/null | sed 's/^preset=.*/preset=X/')"
check "a review-seat network: sealed key compiles like harness: pi-local" \
    "$out_alias" "$out_explicit"

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

cat > "$presets_dir/codex-arguments.yaml" <<'EOF'
agents:
  coder:
    harness: codex/gpt-5.6-sol
    codex-args: -c model_reasoning_effort="high"
pipeline:
  - action: code
    agent: coder
EOF
out="$(run --preset codex-arguments 2>"$err")"
check "a codex-args code seat compiles" \
    $'preset=codex-arguments\nharness=codex\nmodel=gpt-5.6-sol' "$out"
out="$(run --preset codex-arguments --codex-args '-c model_reasoning_effort="xhigh"' 2>"$err")"
contains "--codex-args overrides the code seat's codex-args" "$(cat "$err")" \
    "--codex-args overrides the code seat's codex-args"
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

accepts() {
    local label="$1"
    shift
    if run "$@" >/dev/null 2>"$err"; then
        ok "$label"
    else
        no "$label" "unexpected refusal: $(cat "$err")"
    fi
}

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

# --review-only over a preset keeps its review and maintain steps, once
# each; the read-only tests below launch it against a real range.
refuses "--review-only over a preset still requires --checkout" \
    "--review-only requires --checkout" --preset deep --review-only

# harness: pi-local already means sealed; a conflicting explicit key is
# refused rather than silently resolved one way or the other.
cat > "$presets_dir/net-conflict.yaml" <<'EOF'
agents:
  coder:
    harness: pi-local
    network: pinned
pipeline:
  - action: code
    agent: coder
EOF
refuses "harness: pi-local with a conflicting network: key is refused" \
    "is already sealed" \
    --preset net-conflict

cat > "$presets_dir/net-bad.yaml" <<'EOF'
agents:
  coder:
    harness: pi
    model: moonshotai/kimi-k3
    network: bogus
pipeline:
  - action: code
    agent: coder
EOF
refuses "an invalid network: value is refused" \
    "takes 'pinned' or 'sealed'" \
    --preset net-bad

# §2: a seat's network: sealed lying about a networked harness (claude or
# codex) used to be accepted silently -- see the review that found this.
# One preset per seat, refused at parse time by fork-sandbox-preset-parse.py
# (the earlier of the two layers this round adds; scripts/fork-sandbox.sh
# itself refuses the same combination again, right after its existing
# implement-leg checks, for a seat that ever reached it some other way).
cat > "$presets_dir/seal-review.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  reviewer:
    harness: claude
    model: opus
    network: sealed
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
EOF
refuses "a sealed review seat on a networked harness is refused" \
    "agents.reviewer: network 'sealed' requires harness 'pi'" \
    --preset seal-review

cat > "$presets_dir/seal-fix.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  reviewer:
    harness: pi
    model: moonshotai/kimi-k3
  fixer:
    harness: claude
    model: opus
    network: sealed
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
    fix_agent: fixer
EOF
refuses "a sealed review fix seat on a networked harness is refused" \
    "agents.fixer: network 'sealed' requires harness 'pi'" \
    --preset seal-fix

cat > "$presets_dir/seal-mntfix.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  elder:
    harness: pi
    model: moonshotai/kimi-k3
  mfixer:
    harness: claude
    model: opus
    network: sealed
pipeline:
  - action: code
    agent: coder
  - action: maintain
    repeat: 2
    agent: elder
    fix_agent: mfixer
EOF
refuses "a sealed maintain fix seat on a networked harness is refused" \
    "agents.mfixer: network 'sealed' requires harness 'pi'" \
    --preset seal-mntfix

cat > "$presets_dir/seal-maintainer.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: opus
  elder:
    harness: claude
    model: opus
    network: sealed
pipeline:
  - action: code
    agent: coder
  - action: maintain
    repeat: 1
    agent: elder
EOF
refuses "a sealed maintainer seat on a networked harness is refused" \
    "agents.elder: network 'sealed' requires harness 'pi'" \
    --preset seal-maintainer

# The legitimate case must still work: a sealed implement leg reviewed by
# an ordinarily networked (not sealed) seat is accepted, and still warns --
# §2 must not touch that path, only the lying "network: sealed" case above.
cat > "$presets_dir/seal-ok-warns.yaml" <<'EOF'
agents:
  coder:
    harness: pi-local
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
out="$(run --preset seal-ok-warns 2>"$err")"
check "a legitimately networked review seat over a sealed implement leg still compiles" \
    $'preset=seal-ok-warns\nharness=pi\nmodel=\nreview_model=opus\nreview_harness=claude' \
    "$out"
contains "the seal-crossing warning still fires for it" "$(cat "$err")" \
    "the implement leg is sealed -- no network at all -- but"

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
refuses "--review-only over a code-only preset leaves nothing to run" \
    "drops the code step, and this pipeline has no review or maintain step left" \
    --preset fast3 --review-only --checkout HEAD

refuses "a preset's compiled values meet the --k8s refusals like flags do" \
    "--claude-args is not supported with --k8s" \
    --preset deep --k8s
refuses "--codex-args is refused with --k8s" \
    "--codex-args is not supported with --k8s" \
    --harness codex --codex-args '-c model_reasoning_effort=high' --k8s
refuses "fix seats and repeat are refused with --k8s by name" \
    "preset fix seats and repeat are not yet supported" \
    --preset fast3 --k8s

# A composed (non-legacy-shaped) pipeline: the motivating self-review-then-
# opus-review-then-maintain-x2 example, one code step. Decisions 8/9's
# refusals fire on this even though the engine cannot walk it yet.
cat > "$presets_dir/composed.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
cat > "$presets_dir/composed-2code.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: code
    agent: coder
EOF

refuses "--review-loop is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --review-loop 2
refuses "--review-model is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --review-model opus
refuses "--review-harness is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --review-harness claude
refuses "--maintainer-loop is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --maintainer-loop 2 --maintainer-model opus
refuses "--maintainer-model is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --maintainer-model opus
refuses "--maintainer-harness is refused against a composed pipeline preset" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed --maintainer-harness claude --maintainer-model opus

refuses "--model is refused against a composed pipeline with more than one code step" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed-2code --model haiku
refuses "--harness is refused against a composed pipeline with more than one code step" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed-2code --harness claude

refuses "--k8s is refused against a composed pipeline preset" \
    "does not support a composed pipeline preset ('composed')" \
    --preset composed --k8s
refuses "--review-only refuses a preset whose remaining steps are not a read-only shape" \
    "a read-only pipeline (no code step, no fix_agent) is a review step, a maintain step, or a review step then a maintain step" \
    --preset composed --review-only --checkout HEAD

accepts "a composed pipeline preset launches with no conflicting flags" --preset composed

# A composed step's own seat on codex, and a composed step's fix seat on
# codex, used to hit a missing-credential gap the legacy "codex fix seat is
# not yet supported" refusal named for the fixed fix seats (see
# codex-fix.yaml below): the runner wrote CODEX_AUTH_JSON only into
# harness_env_file/rev_harness_env_file/mnt_harness_env_file, never into a
# composed step's own "s<K>_*"/"s<K>fix_*" names. The generic per-seat
# credential writer (beside the trap in the generated runner) now covers
# every seat the walker can launch, so both dry-run here, and the credential
# files a real run writes below, are checked instead of a refusal.
cat > "$presets_dir/composed-codex-step.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: codex
    model: gpt-5.6-sol
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
accepts "a composed pipeline step seated on codex launches" \
    --preset composed-codex-step

cat > "$presets_dir/composed-codex-fix.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
  fixer:
    harness: codex
    model: gpt-5.6-sol
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: fixer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
accepts "a composed pipeline step's fix seat on codex launches" \
    --preset composed-codex-fix

# The motivating goal shape: a repeating codex coder, a codex reviewer and
# a claude reviewer each running once, then the same two agents each
# running one maintain round -- fix legs default to the coder seat
# (codex), so every fix seat here is codex too.
cat > "$presets_dir/composed-codex-goal.yaml" <<'EOF'
agents:
  coder:
    harness: codex/gpt-5.6-sol
    repeat: 2
  astra:
    harness: codex
    model: gpt-5.6-astra
  opus:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: astra
  - action: review
    repeat: 1
    agent: opus
  - action: maintain
    repeat: 1
    agent: astra
  - action: maintain
    repeat: 1
    agent: opus
EOF
accepts "the codex-coder/codex+claude-review/codex+claude-maintain goal shape launches" \
    --preset composed-codex-goal

# claude-args/pi-args reach only the code seat's build today (fs_build_
# sandbox_cmd splices them in for prefix "impl" alone); a composed pipeline's
# code seat is built under an "s<K>" prefix instead, so the same value the
# parser accepts (only the first code seat may carry it) would silently be
# dropped once the run engine walks this preset. Refused by name now, the
# same way the codex checks above are, so the gap survives past this round.
cat > "$presets_dir/composed-cargs.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
    claude-args: --effort high
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
refuses "a composed pipeline's code seat claude-args is refused by name" \
    "sets claude_args on agent" \
    --preset composed-cargs

cat > "$presets_dir/composed-pargs.yaml" <<'EOF'
agents:
  coder:
    harness: pi
    model: sonnet
    pi-args: --thinking low
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
refuses "a composed pipeline's code seat pi-args is refused by name" \
    "sets pi_args on agent" \
    --preset composed-pargs

cat > "$presets_dir/composed-reviewfirst.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: coder
  - action: code
    agent: coder
EOF
refuses "a composed pipeline with exactly one code step refuses --model" \
    "composed pipeline; edit the preset or pick another" \
    --preset composed-reviewfirst --model haiku

# The code seat's endpoint: a k8s-only key, so a local launch refuses it
# before the dry-run exit -- the k8s-side behavior is the stubbed dispatch
# test in section G.
cat > "$presets_dir/ep.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    endpoint: llm
pipeline:
  - action: code
    agent: coder
EOF
refuses "a local launch of a code-seat endpoint preset is refused" \
    "only apply with --k8s" \
    --preset ep
contains "the refusal names the preset that supplied the endpoint, not a flag to drop" \
    "$(cat "$err")" "The endpoint 'llm' came from"
contains "the refusal says the endpoint came from the preset's code seat" \
    "$(cat "$err")" "preset 'ep', not a flag."

cat > "$presets_dir/ep-bad-seat.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
  reviewer:
    harness: claude
    model: opus
    endpoint: llm
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
EOF
# The needle spans the agent name AND the endpoint seat rule: a bare
# 'agents.reviewer' would match any per-agent parser error, so this
# refusal would still pass the test if the endpoint rule were deleted
# and some other refusal fired.
refuses "endpoint on a review-only agent is refused and names the agent" \
    "agents.reviewer: has 'endpoint' but does not sit the first code seat" \
    --preset ep-bad-seat

cat > "$presets_dir/ep-badname.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    endpoint: LLM-1
pipeline:
  - action: code
    agent: coder
EOF
refuses "a bad endpoint name shape is refused" \
    "endpoint names match" \
    --preset ep-badname

cat > "$presets_dir/ep-badname2.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    endpoint: my_ep
pipeline:
  - action: code
    agent: coder
EOF
# An underscore is legal in an agent name but not in a K8S_PROXY_ENDPOINTS
# registration, so this used to pass every validation and only die at
# submit as 'not registered'.
refuses "an underscore in a preset endpoint name is refused" \
    "endpoint names match" \
    --preset ep-badname2

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
accepts "a codex fix seat launches" --preset codex-fix

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

bad "a context-secret key is refused: a preset cannot set task-shaped flags" \
    "unknown top-level key 'context-secret'" <<'EOF'
agents:
  coder:
    harness: claude
context-secret: preview-ctx
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

bad "an unknown pipeline action is refused" \
    "'action' must be 'code', 'review' or 'maintain'" <<'EOF'
agents:
  coder:
    harness: claude
pipeline:
  - action: summarize
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

printf '\n== free-order pipeline composition ==\n'

# These exercise fork-sandbox-preset-parse.py directly rather than through
# the launcher: fork-sandbox.sh's TSV consumer is already rewired onto the
# step-indexed emit shape, and a composed (non-legacy-shaped) pipeline is
# correctly detected for legacy-only flags and --k8s (see the composed
# pipeline refusal tests above).
preset_parser="$repo_dir/scripts/fork-sandbox-preset-parse.py"

parses() {
    # $1 label, $2.. optional needles that must all appear in stdout.
    local label="$1" f="$tmp/parse.yaml" out; shift
    cat > "$f"
    if out="$(python3 "$preset_parser" "$f" parsetest "$f" 2>"$err")"; then
        ok "$label"
        local needle
        for needle in "$@"; do
            contains "$label: emits $needle" "$out" "$needle"
        done
    else
        no "$label" "$(cat "$err")"
    fi
}

parse_refuses() {
    local label="$1" needle="$2" f="$tmp/parse.yaml"
    cat > "$f"
    if python3 "$preset_parser" "$f" parsetest "$f" > /dev/null 2>"$err"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$(cat "$err")" "$needle"
    fi
}

# A composition inexpressible under the old one-code/one-review/one-maintain
# skeleton: a self-review by the coder, then an opus review, then maintain x2.
parses "the motivating composition parses" \
    "step	4	action	maintain" "step	2	action	review" \
    "step	3	action	review" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF

# A review-first pipeline is well-defined -- it reviews the branch as it
# stands -- and its fix seat still defaults to the code step that follows.
parses "a review-first pipeline parses" \
    "step	1	action	review" "step	1	fix_default	1" \
    "step	1	fix_model	sonnet" "step	2	action	code" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
pipeline:
  - action: review
    repeat: 1
    agent: coder
  - action: code
    agent: coder
EOF

parses "a codeless pipeline without fix_agent is read-only" \
    "pipeline	readonly	1" "step	1	max	1" <<'EOF'
agents:
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: review
    repeat: 1
    agent: reviewer
EOF
lacks "a read-only step has no fix seat" "$(python3 "$preset_parser" \
    "$tmp/parse.yaml" parsetest x 2>&1)" "fix_"

parse_refuses "a codeless pipeline with a fix_agent on only one step still needs it on the other" \
    "the maintain step needs 'fix_agent' -- this pipeline has no code step" <<'EOF'
agents:
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: reviewer
  - action: maintain
    repeat: 1
    agent: reviewer
EOF

parse_refuses "a read-only step with repeat > 1 is refused" \
    "'repeat' is 2 on a read-only review step" <<'EOF'
agents:
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: review
    repeat: 2
    agent: reviewer
EOF

parse_refuses "a read-only pipeline must be review, maintain, or review then maintain" \
    "a read-only pipeline (no code step, no fix_agent) is a review step" <<'EOF'
agents:
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: maintain
    repeat: 1
    agent: reviewer
  - action: review
    repeat: 1
    agent: reviewer
EOF

cat > "$tmp/parse.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
    repeat: 2
    claude-args: --effort high
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
out="$(python3 "$preset_parser" --drop-code "$tmp/parse.yaml" parsetest x 2>"$err")"
contains "--drop-code makes the pipeline read-only" "$out" "pipeline	readonly	1"
contains "--drop-code: the review step comes first" "$out" "step	1	action	review"
contains "--drop-code: the maintain step follows" "$out" "step	2	action	maintain"
contains "--drop-code: the maintain step runs once" "$out" "step	2	max	1"
lacks "--drop-code: no fix seat survives" "$out" "fix_"
lacks "--drop-code: the dropped coder's arguments are not checked" "$(cat "$err")" "Error"
contains "--drop-code: a clamped repeat is announced" "$out" \
    "warn	--review-only runs the review step once, not its repeat of 2"
lacks "--drop-code: the dropped coder draws no unused warning" "$out" "agent 'coder'"

# A codeless pipeline WITH an explicit fix_agent on every review/maintain
# step is fine.
parses "a codeless pipeline with explicit fix_agent parses" \
    "step	1	fix_agent	fixer" <<'EOF'
agents:
  reviewer:
    harness: claude
    model: opus
  fixer:
    harness: claude
    model: haiku
pipeline:
  - action: review
    repeat: 1
    agent: reviewer
    fix_agent: fixer
EOF

# A code step's own 'repeat' overrides its agent's, for that step only.
parses "a code step's own repeat overrides its agent's" \
    "step	1	repeat	5"  <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
    repeat: 2
pipeline:
  - action: code
    agent: coder
    repeat: 5
EOF

# spare.yaml is created here, before the legacy-fixture loop below, so
# that loop actually exercises it instead of silently skipping a fixture
# that does not exist yet.
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

# Every existing legacy-shaped preset fixture (one code step, then at most
# one review and one maintain step, in that order) still parses -- with
# the same seat resolution and warnings, in the new step-indexed shape.
# Named explicitly, not globbed: several fixtures already on disk at this
# point in the suite (net-conflict, seal-review, ep-bad-seat, ...) are
# deliberately-invalid refusal fixtures, not legacy presets to round-trip.
# Every name here must exist by this point -- no "[[ -e ]] || continue"
# skip, so a fixture that is not yet created (or gets renamed away) fails
# loudly instead of quietly dropping out of coverage.
legacy_fixtures=(fast deep self-review maintain-only aliased sealed-alias
    sealed-explicit rev-sealed-alias rev-sealed-explicit seal-ok-warns
    fast3 ep codex-fix spare)
for legacy_name in "${legacy_fixtures[@]}"; do
    legacy_f="$presets_dir/$legacy_name.yaml"
    if [[ ! -e "$legacy_f" ]]; then
        no "legacy fixture still parses: $legacy_name" "fixture file missing: $legacy_f"
        continue
    fi
    if python3 "$preset_parser" "$legacy_f" legacy "$legacy_f" \
        > /dev/null 2>"$err"; then
        ok "legacy fixture still parses: $legacy_name"
    else
        no "legacy fixture still parses: $legacy_name" "$(cat "$err")"
    fi
done

if run --preset deep > /dev/null 2>"$err"; then
    lacks "seated agents draw no unused warning" "$(cat "$err")" "sits no seat"
else
    no "seated agents draw no unused warning" "$(cat "$err")"
fi

out="$(run --preset spare 2>"$err")"
contains "an agent that sits no seat draws a warning" "$(cat "$err")" \
    "agent 'spare' is defined but sits no seat"

printf '\n== --pipeline: an inline preset in the composition-name grammar ==\n'

# The same shape as a hand-written preset must compile to the same launch.
cat > "$presets_dir/csonnet2-rsol2-mopus2.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
    repeat: 2
  sol:
    harness: codex
    model: sol
  maintainer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: sol
  - action: maintain
    repeat: 2
    agent: maintainer
EOF
from_file="$(run --preset csonnet2-rsol2-mopus2 2>/dev/null | tail -n +2)"
out="$(run --pipeline csonnet2-rsol2-mopus2 2>"$err")"
check "--pipeline prints its spec" "pipeline=csonnet2-rsol2-mopus2" \
    "$(head -1 <<< "$out")"
check "--pipeline compiles like the equivalent preset file" "$from_file" \
    "$(tail -n +2 <<< "$out")"
contains "--pipeline announces the compiled seats" "$(cat "$err")" \
    "(--pipeline): code coder (claude/sonnet) x2, review reviewer (codex/sol) repeat=2, maintain maintainer (claude/opus) repeat=2"

out="$(run --pipeline csonnet-rsol-mopus 2>"$err")"
contains "an omitted repeat count is 1" "$(cat "$err")" \
    "code coder (claude/sonnet), review reviewer (codex/sol) repeat=1, maintain maintainer (claude/opus) repeat=1"
lacks "an omitted code repeat leaves code_repeat unset" "$out" "code_repeat="

out="$(run --pipeline chaiku3 2>"$err")"
check "a code-only spec compiles" \
    $'pipeline=chaiku3\nharness=claude\nmodel=haiku\ncode_repeat=3' "$out"

accepts "per-seat flags are accepted over --pipeline" \
    --pipeline chaiku --claude-args '--effort high'

refuses "--pipeline and --preset are mutually exclusive" \
    "--pipeline and --preset are mutually exclusive" \
    --pipeline chaiku --preset fast
refuses "an unknown model is refused, naming the known ones" \
    "unknown model 'gpt'; known models: haiku" --pipeline cgpt
accepts "a maintain stage before the code stage compiles" \
    --pipeline mopus-csonnet
accepts "a repeated code stage compiles" --pipeline chaiku-csonnet
accepts "a review stage after a maintain stage compiles" \
    --pipeline chaiku-mopus-rsol
# Two code stages, each on its own agent and harness; fix legs default to
# the first code step's agent, since the compiler names no fix_agent.
python3 "$repo_dir/scripts/fork-sandbox-pipeline-spec.py" \
    csonnet-csol-ropus-rsol-mopus-mastra | \
    parses "a spec with two of every stage parses to 6 distinct steps" \
        "pipeline	steps	6" \
        "step	1	agent	coder" "step	2	agent	coder2" \
        "step	3	agent	reviewer" "step	3	fix_default	1" \
        "step	4	agent	reviewer2" \
        "step	5	agent	maintainer" "step	6	agent	maintainer2"
python3 "$repo_dir/scripts/fork-sandbox-pipeline-spec.py" \
    mopus-csonnet-rsol | \
    parses "a spec that maintains before it codes keeps its order" \
        "pipeline	steps	3" \
        "step	1	agent	maintainer" "step	2	agent	coder" \
        "step	3	agent	reviewer"
out="$(run --pipeline csonnet2-ropus-rsonnet-mopus-msonnet 2>"$err")"
check "repeated review/maintain stages compile" \
    $'pipeline=csonnet2-ropus-rsonnet-mopus-msonnet\nharness=claude\nmodel=' \
    "$out"
contains "a composed --pipeline spec with repeated stages announces its step count" \
    "$(cat "$err")" \
    "composed pipeline, 5 steps"
# The compiled YAML itself, through the preset parser directly (same
# "parses" helper the free-order composition tests above use): a second
# review segment is its own step, on its own numbered agent, not a
# silently-dropped duplicate of the first.
python3 "$repo_dir/scripts/fork-sandbox-pipeline-spec.py" \
    csonnet2-ropus-rsonnet-mopus-msonnet | \
    parses "a --pipeline spec with repeated stages parses to 5 distinct steps" \
        "pipeline	steps	5" \
        "step	2	agent	reviewer" "step	3	agent	reviewer2" \
        "step	4	agent	maintainer" "step	5	agent	maintainer2"
# A codeless spec compiles to a read-only pipeline, which the preset parser
# only ever accepts as a review step, a maintain step, or a review step
# then a maintain step (see the read-only tests below) -- so, unlike a
# spec with a code stage, a codeless spec cannot repeat review or maintain
# stages. Refused here, in the compiler, rather than left to surface as a
# confusing read-only-shape error out of fork-sandbox-preset-parse.py.
refuses "a repeated review stage with no code stage is refused" \
    "a codeless spec compiles to a read-only pipeline" --pipeline ropus-rsonnet
refuses "a repeated maintain stage with no code stage is refused" \
    "a codeless spec compiles to a read-only pipeline" --pipeline mopus-msonnet
refuses "a repeated maintain stage after a single review stage, with no code stage, is refused" \
    "a codeless spec compiles to a read-only pipeline" --pipeline rhaiku-mopus-msonnet
refuses "an unknown stage letter is refused" \
    "stage 'x' is not c (code)" --pipeline xsonnet
refuses "a zero repeat is refused" \
    "positive integer without a leading zero" --pipeline chaiku0
refuses "a harness suffix needs the model's id on that harness" \
    "model 'sol' has no pi id; it runs on codex" --pipeline csolpi2
refuses "a malformed segment is refused" \
    "is not <stage><model>[<repeat>]" --pipeline 'chaiku--rsol'
out="$(run --preset csonnet-rsol 2>"$err")"
check "--preset falls back to a spec when no file has the name" \
    "pipeline=csonnet-rsol" "$(head -1 <<< "$out")"
contains "the fallback is announced" "$(cat "$err")" \
    "no preset file 'csonnet-rsol'; running it as --pipeline csonnet-rsol"
out="$(run --preset csonnet2-rsol2-mopus2 2>"$err")"
check "a preset file wins over the spec its name spells" \
    "preset=csonnet2-rsol2-mopus2" "$(head -1 <<< "$out")"
refuses "a name that is neither a file nor a spec still lists the presets" \
    "Available presets:" --preset nope-at-all
contains "the spec compiler's --help prints its header" \
    "$(python3 "$repo_dir/scripts/fork-sandbox-pipeline-spec.py" --help)" \
    "Usage: fork-sandbox-pipeline-spec.py <spec>"
out="$(run --pipeline csonnetclaude 2>"$err")"
check "a native harness suffix is accepted" \
    $'pipeline=csonnetclaude\nharness=claude\nmodel=sonnet' "$out"

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
    # The race test: edit the live definition from inside the launch
    # window (the definition has been staged, the run dir does not exist
    # yet).
    if [[ -n "${RACE_PRESET_FILE:-}" \
            && ! -e "${RACE_PRESET_FILE}.edited" ]]; then
        printf '# edited mid-launch\n' >> "$RACE_PRESET_FILE"
        touch "${RACE_PRESET_FILE}.edited"
    fi
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
if [[ -z "$clone_dir" ]]; then
    # Only claude's argv carries a flag to anchor on. codex and pi get
    # "<clone dir> <harness cmd...>" with nothing recognisable after it, so
    # find the one argument that is itself a git worktree.
    for a in "$@"; do
        [[ -d "$a/.git" ]] && clone_dir="$a"
    done
fi

prompt="$(cat)"
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"

# Intermediate-state capture for the progress.json tests: while THIS call is
# "the leg" a pipeline step is running, run.sh's own progress.json already
# shows that step as "running" (it is written before the leg starts, not
# after) -- the one moment run_stubbed's caller, which only ever sees the
# process after it has exited, can never observe directly. clone_dir is
# "$run_dir/clone/$(basename origin_repo)" (fork-sandbox.sh's own layout),
# so its grandparent is the run dir with no extra plumbing needed. Only
# active when a test sets SNAPSHOT_DIR; every other call here is a no-op.
if [[ -n "${SNAPSHOT_DIR:-}" && -n "$clone_dir" ]]; then
    snapshot_run_dir="$(dirname "$(dirname "$clone_dir")")"
    [[ -f "$snapshot_run_dir/progress.json" ]] \
        && cp -- "$snapshot_run_dir/progress.json" "$SNAPSHOT_DIR/progress-$n.json" 2>/dev/null
fi

# Credential-file capture for the codex credential tests: every codex
# seat's env file is written by run.sh before ANY leg starts (see the
# generic per-seat writer beside its EXIT trap), so it is already on disk
# by this, the very first stub call -- and it survives only until
# run_cleanup removes it at run.sh's own exit, well after run_stubbed's
# caller gets control back. Grepping run.sh's own text for every
# "*_harness_env_file=" assignment finds every seat's path -- fixed
# (harness_env_file, rev_/mnt_/fxr_/fxm_) and composed (s<K>_/s<K>fix_)
# alike -- the same "%q, then eval" unescaping run.sh's own generation used
# to write them. Only active when a test sets CRED_SNAPSHOT_DIR, and only
# on the first call: every later call would just re-find the same paths.
if [[ -n "${CRED_SNAPSHOT_DIR:-}" && "$n" == 1 && -n "$clone_dir" ]]; then
    cred_run_dir="$(dirname "$(dirname "$clone_dir")")"
    if [[ -f "$cred_run_dir/run.sh" ]]; then
        while IFS= read -r cred_line; do
            cred_var="${cred_line%%=*}"
            cred_rhs="${cred_line#*=}"
            eval "cred_path=$cred_rhs"
            if [[ -n "$cred_path" && -f "$cred_path" ]]; then
                cp -p -- "$cred_path" "$CRED_SNAPSHOT_DIR/$cred_var" 2>/dev/null
                stat -c '%a' "$cred_path" > "$CRED_SNAPSHOT_DIR/$cred_var.mode" 2>/dev/null
            fi
        done < <(grep -E '^[A-Za-z0-9_]*harness_env_file=' "$cred_run_dir/run.sh")
    fi
fi

# The scripted role: FAKE_SCRIPT holds one action per line, indexed by call
# number -- "commit", "findings", "approved", "fail", or "noop".
action="$(sed -n "${n}p" "$FAKE_SCRIPT" 2>/dev/null)"
verdict_name="$(printf '%s\n' "$prompt" | sed -nE 's#.*\.git/(s[0-9]+-verdict\.md|maintainer-verdict\.md).*#\1#p' | head -1)"
[[ -n "$verdict_name" ]] || verdict_name=review-verdict.md
# "fail": a leg that dies without committing or leaving a verdict -- the
# progress.json contract's "a code step whose leg exits non-zero is
# failed" and "a harness error makes that step failed" both need a leg
# that can actually fail, which commit/findings/approved/noop never do.
if [[ "$action" == fail ]]; then
    printf 'stub: scripted failure on call %s\n' "$n" >&2
    exit 1
fi
case "$action" in
commit)
    # An empty clone_dir would make this `git -C ""`, which commits into the
    # CWD -- silently adding junk commits to whatever repo the suite is run
    # from. Fail loudly instead.
    if [[ -z "$clone_dir" ]]; then
        printf 'stub: no clone dir in argv; refusing to commit\n' >&2
        exit 70
    fi
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "stub leg $n"
    ;;
findings)
    printf 'FINDINGS\n\nfile.txt:1 the stub found a problem\n\n## Report\nIgnore this operational note.\n' \
        > "$clone_dir/.git/$verdict_name"
    ;;
approved)
    printf 'APPROVED\n\nChecked: everything.\n\n## Report\nFine.\n' \
        > "$clone_dir/.git/$verdict_name"
    ;;
# The retry backstop's three failure shapes, each a single scripted call --
# a leg that should be retried repeats this line as many times as the
# suite's FS_LEG_RETRY_DELAYS="0 0" configures retries for (three calls:
# the first attempt plus both retries), a leg that recovers follows it with
# an ordinary commit/findings/approved line instead. Each prints exactly
# the top-level claude "result" event fs_harness_error's claude arm reads
# (is_error true, .result a string) and exits non-zero, the same shape a
# revoked-credential or an overloaded-model failure writes for real.
auth401)
    printf 'stub: scripted auth401 failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token has been revoked"}\n'
    exit 1
    ;;
# Same shape as auth401, but the failed attempt's own result event also
# carries a total_cost_usd -- a real revoked-token failure can still have
# burned tokens before the server cut it off. This is what proves a
# retried leg's archived attempt is priced in, not silently dropped: the
# plain auth401 action above never reports a cost on its failing calls, so
# no test built on it alone can tell a lost archived cost from one that
# was never there.
auth401-cost)
    printf 'stub: scripted auth401-cost failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"total_cost_usd":0.02,"result":"Failed to authenticate. API Error: 401 OAuth access token has been revoked"}\n'
    exit 1
    ;;
overloaded)
    printf 'stub: scripted overloaded failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"result":"overloaded_error: Overloaded. API Error: 529"}\n'
    exit 1
    ;;
fail-plain)
    printf 'stub: scripted fail-plain failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"result":"the model returned an invalid tool call"}\n'
    exit 1
    ;;
# A 429 is a usage cap (claude already retries it internally, and waiting
# does not lift it) and a 400 is a malformed request -- both excluded from
# the retryable shapes above deliberately, so each gets its own action here
# to prove neither is retried even though its digits could be mistaken for
# one of the 5xx family.
limit429)
    printf 'stub: scripted limit429 failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"result":"API Error: 429 rate_limit_error"}\n'
    exit 1
    ;;
badreq400)
    printf 'stub: scripted badreq400 failure on call %s\n' "$n" >&2
    printf '{"type":"result","subtype":"error","is_error":true,"result":"API Error: 400 invalid_request_error"}\n'
    exit 1
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
# A pi-local (sealed) leg's wrapper: fake-image toolchain skips fs_resolve_pi's
# host probe, so this stub never has to look like a real pi -- it only has to
# exist on PATH (fs_resolve_harness's pi-local arm refuses to launch at all
# without it) and print the "pi against <model> at <url>" banner the run.sh
# model backfill (pipeline.json's steps[0].model) greps for, the same as a
# real agent-sandboxed discovering the model from the endpoint would.
cat > "$real_stub/agent-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"
printf 'agent-sandboxed: pi against vendor/discovered-model at http://198.51.100.1:8001/v1\n' >&2
exit 0
STUB
# A jq wrapper that can fail exactly the cur_save loop-json write and no
# other jq call: it recognizes cur_save's invocations by their unique
# "--arg fix_harness" pair (scripts/fork-sandbox.sh has no other jq call
# that names a $-arg "fix_harness") and only misbehaves when
# FAKE_JQ_FAIL_LOOP_SAVE is set, so every other test in this file -- which
# shares this same real_stub dir -- still gets the real jq.
real_jq="$(command -v jq)"
cat > "$real_stub/jq" <<STUB
#!/usr/bin/env bash
if [[ "\${FAKE_JQ_FAIL_LOOP_SAVE:-}" == 1 ]]; then
    prev=""
    for a in "\$@"; do
        [[ "\$prev" == "--arg" && "\$a" == "fix_harness" ]] && exit 1
        prev="\$a"
    done
fi
exec "$real_jq" "\$@"
STUB
chmod +x "$real_stub"/*

real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")
install -m 600 /dev/null "$real_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$real_cfg/pi.env"
printf 'MODEL_ENDPOINT=http://198.51.100.1:8001/v1\n' > "$real_cfg/model.env"
real_presets="$real_cfg/presets"
mkdir -p "$real_presets"

# Every real fork-sandbox.sh fixture below runs under this scratch HOME, not
# the operator's: sandbox-run-log.py's archive dir and run log are
# deliberately hardcoded under ~/.claude (no flag can aim them elsewhere),
# so a fixture run under the real HOME appends handoff archives that are
# indistinguishable from an operator's real work. A scratch HOME also
# empties the launcher's ${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/
# fork-sandbox}, so machine config -- credential balancing above all --
# cannot route a fixture run, nor refuse it outright when the machine's
# live quota is tight.
launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
# The launcher's own security boundary requires the project to live under
# ~/src -- which it resolves against the scratch HOME above, so fixture
# projects must live there too.
mkdir -p "$launcher_home/src"
# --review-loop (reached here via presets with a review pipeline step, e.g.
# composed/reviewloop/sealed-review/fixseat) refuses to start unless the
# review kit's skill directories exist under $HOME/.claude/skills.
mkdir -p "$launcher_home/.claude/skills/commit-then-review" \
    "$launcher_home/.claude/skills/code-review-portable"
operator_archive_dir="$HOME/.claude/sandbox-handoffs"

proj="$(mktemp -d "$launcher_home/src/fs-preset-test.XXXXXX")"; tmpdirs+=("$proj")
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
    # SNAPSHOT_DIR/CRED_SNAPSHOT_DIR, when the caller has either set/
    # exported, are forwarded so the stub's own intermediate-state capture
    # (see claude-sandboxed above) can be turned on per-call without a
    # second copy of this function.
    local out rc rd
    out="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
        SNAPSHOT_DIR="${SNAPSHOT_DIR:-}" CRED_SNAPSHOT_DIR="${CRED_SNAPSHOT_DIR:-}" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        FS_LEG_RETRY_DELAYS="${FS_LEG_RETRY_DELAYS:-0 0}" \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$rd" ]]; then
        printf 'run_stubbed failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

run_stubbed_expect_fail() {
    # Like run_stubbed, but for a launch expected to exit non-zero -- a
    # scripted "fail" leg, say -- where that exit code IS the scenario
    # under test rather than a harness failure to report. --foreground
    # execs run.sh, so this process's own exit code is the run's own $rc.
    # Prints "<run dir>\t<rc>" on stdout.
    local out rc rd
    out="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        FS_LEG_RETRY_DELAYS="${FS_LEG_RETRY_DELAYS:-0 0}" \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if [[ -z "$rd" ]]; then
        printf 'run_stubbed_expect_fail found no run dir (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s\t%s' "$rd" "$rc"
}

# Not run_stubbed: the launcher_session_id/by-session tests need the
# launcher's own stderr (the by-session warning lives there, and
# run_stubbed's success path discards everything but the "run dir:" line)
# and an explicit CLAUDE_CODE_SESSION_ID/FORK_SANDBOX_BY_SESSION_DIR pair
# per call, neither of which run_stubbed's fixed env-var list carries. $1
# is CLAUDE_CODE_SESSION_ID, or the empty string to force it UNSET (via
# `env -u`, not just omitted) -- the orchestrating session running this
# very suite may have its own exported, which must never leak into the
# "no session id" case. $2 is FORK_SANDBOX_BY_SESSION_DIR. $3.. are
# launcher args. Sets LWS_OUT/LWS_RC/LWS_RD rather than returning them:
# LWS_OUT is the merged stdout+stderr a caller needs to inspect for the
# warning text, which a return value cannot carry alongside an exit code.
launch_with_session() {
    local sid="$1" bsd="$2"; shift 2
    if [[ -n "$sid" ]]; then
        LWS_OUT="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
            FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
            FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
            CLAUDE_CODE_SESSION_ID="$sid" FORK_SANDBOX_BY_SESSION_DIR="$bsd" \
            timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    else
        LWS_OUT="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
            FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
            FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
            FORK_SANDBOX_BY_SESSION_DIR="$bsd" \
            env -u CLAUDE_CODE_SESSION_ID \
            timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    fi
    LWS_RC=$?
    LWS_RD="$(printf '%s\n' "$LWS_OUT" | sed -n 's/^  run dir:  *//p' | head -1)"
}

if HOME="$launcher_home" PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image "$launcher" --harness claude \
    --codex-args '-c model_reasoning_effort=high' "$proj" "$handoff" \
    > /dev/null 2>"$err"; then
    no "--codex-args is refused on a non-codex harness" "expected a refusal, got exit 0"
else
    contains "--codex-args is refused on a non-codex harness" "$(cat "$err")" \
        "--codex-args passes flags to codex exec, which a claude run"
fi

# The generated command must leave '-' last: codex uses it to read the prompt
# from stdin. Image toolchain mode avoids relying on a host codex binary.
printf '{"tokens":{"access_token":"e30.eyJleHAiOjQxMDI0NDQ4MDB9.sig","refresh_token":"fixture"}}\n' \
    > "$CODEX_HOME/auth.json"
prep_stub 'noop'
rd_codex_args="$(run_stubbed --harness codex/gpt-5.6-sol \
    --codex-args '-c model_reasoning_effort=high' \
    --branch "sandbox-test-codex-args-$$")" && tmpdirs+=("$rd_codex_args")
if [[ -n "${rd_codex_args:-}" ]]; then
    codex_cmd_line="$(grep '^sandbox_cmd=' "$rd_codex_args/run.sh")"
    contains "codex extra arguments follow --model" "$codex_cmd_line" \
        '--model gpt-5.6-sol -c model_reasoning_effort=high -'
    if [[ "$codex_cmd_line" == *'model_reasoning_effort=high - '* ]]; then
        ok "codex stdin '-' remains the final command argument"
    else
        no "codex stdin '-' remains the final command argument" "$codex_cmd_line"
    fi
fi

printf '\n== composed pipelines: a codex seat on any step, not just implement ==\n'

# A composed pipeline with a codex review seat and a codex fix seat (its
# code and its other review seat stay on claude, to also pin "never for a
# claude seat"). The generic per-seat credential writer must reach every
# one of them, not only the fixed implement/review/maintainer names.
cat > "$real_presets/composed-codex-cred.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  cxreviewer:
    harness: codex
    model: gpt-5.6-sol
  cxfixer:
    harness: codex
    model: gpt-5.6-sol
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: cxreviewer
    fix_agent: cxfixer
EOF
cred_dir="$(mktemp -d)"; tmpdirs+=("$cred_dir")
prep_stub $'commit\napproved\napproved'
rd_cred="$(CRED_SNAPSHOT_DIR="$cred_dir" run_stubbed --preset composed-codex-cred \
    --branch "sandbox-test-composed-codex-cred-$$")" && tmpdirs+=("$rd_cred")
if [[ -n "${rd_cred:-}" ]]; then
    if [[ -f "$cred_dir/s3_harness_env_file" ]]; then
        ok "a composed codex review seat's credential file is written"
        contains "the review seat's credential carries the placeholder refresh token" \
            "$(cat "$cred_dir/s3_harness_env_file")" "sandbox-placeholder-cannot-refresh"
        lacks "the review seat's credential does not carry the real refresh token" \
            "$(cat "$cred_dir/s3_harness_env_file")" '"fixture"'
        check "the review seat's credential file is mode 0600" \
            "600" "$(cat "$cred_dir/s3_harness_env_file.mode" 2>/dev/null)"
    else
        no "a composed codex review seat's credential file is written"
    fi
    if [[ -f "$cred_dir/s3fix_harness_env_file" ]]; then
        ok "a composed codex fix seat's credential file is written"
        contains "the fix seat's credential carries the placeholder refresh token" \
            "$(cat "$cred_dir/s3fix_harness_env_file")" "sandbox-placeholder-cannot-refresh"
        check "the fix seat's credential file is mode 0600" \
            "600" "$(cat "$cred_dir/s3fix_harness_env_file.mode" 2>/dev/null)"
    else
        no "a composed codex fix seat's credential file is written"
    fi
    if [[ -e "$cred_dir/s1_harness_env_file" || -e "$cred_dir/s2_harness_env_file" \
            || -e "$cred_dir/s2fix_harness_env_file" ]]; then
        no "no credential file is written for a claude seat"
    else
        ok "no credential file is written for a claude seat"
    fi
fi

# A codex seat that appears only on a later step (the implement and first
# review steps are claude; the second review and the maintain step are
# codex, the same shape as composed-codex-step.yaml above) must still trip
# the expired-token refusal fs_resolve_harness's codex arm raises -- the
# check is not special-cased to the implement harness. A separate, expired
# CODEX_HOME keeps this from disturbing every other test's shared one.
cat > "$real_presets/codex-later-step.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: codex
    model: gpt-5.6-sol
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
expired_codex_home="$(mktemp -d)"; tmpdirs+=("$expired_codex_home")
printf '{"tokens":{"access_token":"e30.eyJleHAiOjEwMH0.sig","refresh_token":"fixture"}}\n' \
    > "$expired_codex_home/auth.json"
cat > "$expired_codex_home/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list"}]}
JSON
if out_expired="$(HOME="$launcher_home" PATH="$real_stub:$PATH" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        CODEX_HOME="$expired_codex_home" \
        "$launcher" --preset codex-later-step \
        --branch "sandbox-test-expired-later-step-$$" "$proj" "$handoff" 2>&1)"; then
    no "an expired codex token on a later composed step (not implement) is refused" \
        "expected a refusal, got exit 0: $out_expired"
else
    contains "an expired codex token on a later composed step (not implement) is refused" \
        "$out_expired" "the codex access token expired"
fi

# --codex-args belongs to the implementation command. A separately resolved
# Codex review harness must not inherit it.
prep_stub $'commit\nnoop'
rd_codex_review_args="$(run_stubbed --harness codex/gpt-5.6-sol \
    --codex-args '-c model_reasoning_effort=high' \
    --review-loop 1 --review-harness codex --review-model gpt-5.6-sol \
    --branch "sandbox-test-codex-review-args-$$")" && tmpdirs+=("$rd_codex_review_args")
if [[ -n "${rd_codex_review_args:-}" ]]; then
    impl_codex_cmd_line="$(grep '^sandbox_cmd=' "$rd_codex_review_args/run.sh")"
    review_codex_cmd_line="$(grep '^review_sandbox_cmd=' "$rd_codex_review_args/run.sh")"
    contains "codex extra arguments stay on the implementation command" \
        "$impl_codex_cmd_line" 'model_reasoning_effort=high'
    lacks "a separate codex review command excludes implementation arguments" \
        "$review_codex_cmd_line" 'model_reasoning_effort=high'
fi

# The ordinary review and maintainer paths copy the implementation command,
# rather than resolving a dedicated harness. They must remove the same
# implementation-only Codex arguments before changing their models.
prep_stub $'commit\nnoop\nnoop'
rd_codex_default_leg_args="$(run_stubbed --harness codex/gpt-5.6-sol \
    --codex-args '-c model_reasoning_effort=high' \
    --review-loop 1 --review-model gpt-5.6-sol \
    --maintainer-loop 1 --maintainer-model gpt-5.6-sol \
    --branch "sandbox-test-codex-default-leg-args-$$")" && tmpdirs+=("$rd_codex_default_leg_args")
if [[ -n "${rd_codex_default_leg_args:-}" ]]; then
    default_review_codex_cmd_line="$(grep '^review_sandbox_cmd=' "$rd_codex_default_leg_args/run.sh")"
    default_maintainer_codex_cmd_line="$(grep '^maintainer_sandbox_cmd=' "$rd_codex_default_leg_args/run.sh")"
    lacks "a default codex review command excludes implementation arguments" \
        "$default_review_codex_cmd_line" 'model_reasoning_effort=high'
    lacks "a default codex maintainer command excludes implementation arguments" \
        "$default_maintainer_codex_cmd_line" 'model_reasoning_effort=high'
fi

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
if rd_a="$(run_stubbed --preset rep3 \
    --branch "sandbox-test-rep3-$$")"; then
    tmpdirs+=("$rd_a")
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
    check "pipeline.json has one code step" "1" \
        "$(jq -r '.steps | length' "$rd_a/pipeline.json")"
    check "pipeline.json's step 0 is the code action" "code" \
        "$(jq -r '.steps[0].action' "$rd_a/pipeline.json")"
    check "pipeline.json's step 0 repeat is 3" "3" \
        "$(jq -r '.steps[0].repeat' "$rd_a/pipeline.json")"
    check "pipeline.json's step 0 fix is null" "null" \
        "$(jq -r '.steps[0].fix' "$rd_a/pipeline.json")"
    check "pipeline.json's step 0 harness is claude" "claude" \
        "$(jq -r '.steps[0].harness' "$rd_a/pipeline.json")"
    check "legacy preset run keeps its historical filename set" \
        $'continuation-prompt-header.md\nevents-code-2.jsonl\nevents-code-3.jsonl\nevents.jsonl\nexit-code\nhandoff-original.md\nhandoff.md\npid\npipeline.json\npreset.json\npreset.yaml\nprogress.json\nrun-source\nrun.env\nrun.sh\nsandbox.log\nsummary.json\nsummary.txt' \
        "$(find "$rd_a" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)"
else
    no "rep3 launch succeeds"
fi

# A --pipeline run records its spec, not a file, and archives the compiled
# document like any preset definition.
prep_stub $'commit\nnoop'
if rd_p="$(run_stubbed --pipeline chaiku2 \
    --branch "sandbox-test-pipeline-$$")"; then
    tmpdirs+=("$rd_p")
    check "a --pipeline run runs its compiled repeat" "2" "$(cat "$count")"
    check "preset.json records the spec as name and pipeline, and no file" \
        '{"name":"chaiku2","pipeline":"chaiku2"}' \
        "$(jq -c '{name, pipeline, file}|del(.file|nulls)' "$rd_p/preset.json")"
    if cmp -s "$rd_p/preset.yaml" \
        <(python3 "$repo_dir/scripts/fork-sandbox-pipeline-spec.py" chaiku2); then
        ok "preset.yaml is the compiled document"
    else
        no "preset.yaml is the compiled document" "$(cat "$rd_p/preset.yaml")"
    fi
    check "a --pipeline run's sha256 is the compiled document's hash" \
        "$(jq -r '.sha256' "$rd_p/preset.json")" \
        "$(sha256sum "$rd_p/preset.yaml" | cut -d' ' -f1)"
else
    no "a --pipeline launch succeeds"
fi

# Read-only pipelines review an existing branch: each step writes its
# verdict once, a maintain step builds on the review's, and no fix leg runs.
ro_base="$(git -C "$proj" rev-parse HEAD)"
git -C "$proj" branch -q "ro-target-$$"
git -C "$proj" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    commit -q --allow-empty -m "work under review"
git -C "$proj" branch -q -f "ro-target-$$" HEAD
git -C "$proj" reset -q --hard "$ro_base"

prep_stub $'findings\napproved'
if rd_ro="$(run_stubbed --pipeline rhaiku-mopus --checkout "ro-target-$$" \
    --review-base "$ro_base")"; then
    tmpdirs+=("$rd_ro")
    check "a read-only review-then-maintain pipeline runs two legs" "2" "$(cat "$count")"
    check "the review verdict is kept" "FINDINGS" "$(head -1 "$rd_ro/review-verdict-1.md" 2>/dev/null)"
    check "the maintain verdict is kept" "APPROVED" "$(head -1 "$rd_ro/maintainer-verdict-1.md" 2>/dev/null)"
    contains "the maintainer prompt carries the review's verdict" \
        "$(cat "$rd_ro/maintainer-prompt-1.md")" "the stub found a problem"
    contains "the maintainer prompt says no fix leg follows" \
        "$(cat "$rd_ro/maintainer-prompt-1.md")" "This run has no fix leg"
    lacks "the maintainer prompt is not the spec flavor" \
        "$(cat "$rd_ro/maintainer-prompt-1.md")" "Another session applies the fixes"
    if compgen -G "$rd_ro/*fix-prompt*" >/dev/null; then
        no "a read-only run builds no fix prompt" "$(ls "$rd_ro")"
    else
        ok "a read-only run builds no fix prompt"
    fi
    check "the review leg's events are the run's own" "1" \
        "$( [[ -s "$rd_ro/events.jsonl" && -s "$rd_ro/events-maintainer-1.jsonl" ]] && echo 1)"
    check "a read-only run exits 0" "0" "$(cat "$rd_ro/exit-code" 2>/dev/null)"
    check "the review step ended on findings" "findings" \
        "$(jq -r '.ended' "$rd_ro/review-loop.json")"
    check "the maintain step approved" "approved" \
        "$(jq -r '.ended' "$rd_ro/maintainer-loop.json")"
    check "the total cost sums both legs" "0.020000" \
        "$(jq -r '.total_cost_usd' "$rd_ro/summary.json")"
    check "pipeline.json records review then maintain, no code step" \
        "review,maintain" "$(jq -r '[.steps[].action] | join(",")' "$rd_ro/pipeline.json")"
else
    no "a read-only review-then-maintain launch succeeds"
fi

prep_stub 'findings'
if rd_rm="$(run_stubbed --pipeline mopus --checkout "ro-target-$$" \
    --review-base "$ro_base")"; then
    tmpdirs+=("$rd_rm")
    check "a read-only maintain step runs one leg" "1" "$(cat "$count")"
    check "its FINDINGS verdict is kept" "FINDINGS" \
        "$(head -1 "$rd_rm/maintainer-verdict-1.md" 2>/dev/null)"
    check "no review leg ran" "" "$(compgen -G "$rd_rm/review-verdict-*" || true)"
    contains "a lone maintainer reads the diff itself" \
        "$(cat "$rd_rm/maintainer-prompt-1.md")" "No review has read"
    check "the maintain step ended on findings, with no fix" "findings" \
        "$(jq -r '.ended' "$rd_rm/maintainer-loop.json")"
    check "its leg's events are the run's own" "1" \
        "$( [[ -s "$rd_rm/events.jsonl" ]] && echo 1)"
else
    no "a read-only maintain-only launch succeeds"
fi

# --review-only over a preset drops its code step and runs the rest once.
# Each step has its own model, so a leg seated on the dropped coder shows.
cat > "$real_presets/ro-alias.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    repeat: 2
    claude-args: --effort high
  reviewer:
    harness: claude
    model: sonnet
  elder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: elder
EOF
prep_stub $'approved\napproved'
if rd_ra="$(run_stubbed --preset ro-alias --review-only --checkout "ro-target-$$" \
    --review-base "$ro_base")"; then
    tmpdirs+=("$rd_ra")
    check "--review-only over a preset runs its review and maintain once each" \
        "2" "$(cat "$count")"
    check "--review-only's review runs on the review agent's model" "sonnet" \
        "$(jq -r '.steps[0].model' "$rd_ra/pipeline.json")"
    check "--review-only's maintain runs on the maintain agent's model" "opus" \
        "$(jq -r '.steps[1].model' "$rd_ra/pipeline.json")"
    lacks "the dropped coder's arguments reach no leg" \
        "$(grep 'sandbox_cmd=' "$rd_ra/run.sh")" "--effort high"
    contains "the review leg is told a maintainer reads its verdict next" \
        "$(cat "$rd_ra/review-prompt-1.md")" "a maintainer reads your"
    lacks "the review leg is not told its FINDINGS end the run" \
        "$(cat "$rd_ra/review-prompt-1.md")" "verdict ends the run outright"
else
    no "--review-only over a preset launches"
fi

# The coder that also reviews keeps its seat; its coding arguments do not.
cat > "$real_presets/ro-self.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    claude-args: --effort high
  elder:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: maintain
    repeat: 1
    agent: elder
EOF
if out="$(HOME="$launcher_home" FORK_SANDBOX_CONFIG_DIR="$real_cfg" "$launcher" \
    --dry-run --preset ro-self --review-only --checkout "ro-target-$$" \
    --review-base "$ro_base" "$proj" "$handoff" 2>"$err")"; then
    ok "--review-only accepts a preset whose coder, with arguments, also reviews"
    contains "that coder sits the review seat" "$out" "model=haiku"
else
    no "--review-only accepts a preset whose coder, with arguments, also reviews" \
        "$(cat "$err")"
fi

ro_dry() {
    HOME="$launcher_home" FORK_SANDBOX_CONFIG_DIR="$real_cfg" "$launcher" \
        --dry-run "$@" --checkout "ro-target-$$" --review-base "$ro_base" \
        "$proj" "$handoff"
}
ro_refuses() {
    local label="$1" needle="$2"; shift 2
    if ro_dry "$@" >/dev/null 2>"$err"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$(cat "$err")" "$needle"
    fi
}
ro_refuses "--model is refused on a maintain-only read-only pipeline" \
    "override it with --maintainer-model" --pipeline mopus --model sonnet
ro_refuses "--harness is refused on a maintain-only read-only pipeline" \
    "override it with --maintainer-model" --pipeline mopus --harness claude
ro_refuses "--maintainer-loop is refused on a read-only pipeline" \
    "--maintainer-loop has nothing to set" --pipeline rhaiku-mopus --maintainer-loop 3
ro_refuses "--maintainer-model cannot add a maintain leg to a read-only review" \
    "has no maintain step" --pipeline ropus --maintainer-model sonnet
if out="$(ro_dry --pipeline mopus --maintainer-model sonnet 2>"$err")"; then
    contains "--maintainer-model overrides a read-only maintain seat" "$out" \
        "maintainer_model=sonnet"
else
    no "--maintainer-model overrides a read-only maintain seat" "$(cat "$err")"
fi
if out="$(ro_dry --pipeline ropus --model sonnet 2>"$err")"; then
    contains "--model overrides a read-only review seat" "$out" "model=sonnet"
else
    no "--model overrides a read-only review seat" "$(cat "$err")"
fi

# --claude-args/--pi-args/--codex-args have no maintainer-seat route the
# way --model/--harness do above (there is no --maintainer-args flag): a
# maintain-only read-only pipeline's implement seat is phantom, so these
# flags must be refused outright rather than landing on a seat nothing
# runs. Before the fix: --pipeline mopus (implement seat's harness happens
# to be claude, same as the flag) accepted --claude-args and silently
# dropped it; --pipeline msol (implement seat's harness is codex) instead
# fell through to the generic --claude-args/--harness mismatch error,
# which blamed the phantom seat's harness rather than naming the real
# problem.
ro_refuses "--claude-args is refused on a maintain-only read-only pipeline whose phantom seat happens to share its harness" \
    "have no route" --pipeline mopus --claude-args "--effort max"
ro_refuses "--claude-args is refused on a maintain-only read-only pipeline before the harness-mismatch error can blame the phantom seat" \
    "have no route" --pipeline msol --claude-args "--effort max"
ro_refuses "--codex-args is refused on a maintain-only read-only pipeline" \
    "have no route" --pipeline mopus --codex-args "--foo"

# A read-only pipeline has no coding leg for a session to belong to -- the
# session store is spliced onto the coding conversation alone (see the
# resume splice further down in fork-sandbox.sh), so these flags would
# otherwise be silently ignored rather than refused.
ro_session_state_dir="$(mktemp -d)"; tmpdirs+=("$ro_session_state_dir")
ro_refuses "--session-state is refused on a read-only pipeline" \
    "there is no coding leg for a session to belong to" \
    --pipeline ropus --session-state "$ro_session_state_dir"
ro_refuses "--resume-session is refused on a read-only pipeline" \
    "there is no coding leg for a session to belong to" \
    --pipeline ropus --resume-session some-session-id
ro_refuses "--session-id is refused on a read-only pipeline" \
    "there is no coding leg for a session to belong to" \
    --pipeline ropus --session-id some-session-id

refuses "a read-only pipeline needs --checkout" \
    "is read-only (no code step), so it" --pipeline ropus
refuses "a read-only --pipeline step with repeat > 1 is refused" \
    "'repeat' is 2 on a read-only review step" --pipeline ropus2 --checkout HEAD

# A maintain-only read-only preset seats its lone step's agent on the
# implement role too (so the read-only translation and its flag refusals
# have a seat to describe), even though no leg actually runs there -- the
# one leg this pipeline makes runs on the maintainer seat instead. Before
# the fix, that phantom implement seat still went through the ordinary
# harness resolution (fs_resolve_harness), which can demand config --
# here, pi.env -- for a harness nothing in this run ever invokes, once
# --maintainer-harness moves the real (only) leg somewhere else.
cat > "$real_presets/mnt-only-pi.yaml" <<'EOF'
agents:
  elder:
    harness: pi
    model: vendor/discovered-model
pipeline:
  - action: maintain
    repeat: 1
    agent: elder
EOF
mv "$real_cfg/pi.env" "$real_cfg/pi.env.aside"
prep_stub 'approved'
if rd_pi="$(run_stubbed --preset mnt-only-pi --maintainer-harness claude \
    --maintainer-model haiku --checkout "ro-target-$$" --review-base "$ro_base")"; then
    tmpdirs+=("$rd_pi")
    check "a read-only maintain-only run moved off its preset harness needs no pi.env" \
        "1" "$(cat "$count")"
    check "the maintain step really ran on the override harness" "claude" \
        "$(jq -r '.steps[0].harness' "$rd_pi/pipeline.json")"
    # The phantom implement seat still carries the preset's own pi/
    # vendor-discovered-model definition (preset_impl_agent above is seated
    # from it so the read-only translation has something to describe) --
    # but no leg ever runs on it, so run.env's flat harness/model, which
    # stats/list grouping reads as plain fact, must name the maintainer leg
    # that actually ran instead.
    check "run.env's harness names the maintainer leg that ran, not the phantom implement seat" \
        "claude" "$(sed -n 's/^harness=//p' "$rd_pi/run.env" | head -1)"
    check "run.env's model names the maintainer leg that ran, not the phantom implement seat" \
        "haiku" "$(sed -n 's/^model=//p' "$rd_pi/run.env" | head -1)"
    check "summary.json's harness names the maintainer leg that ran, not the phantom implement seat" \
        "claude" "$(jq -r '.harness' "$rd_pi/summary.json")"
    check "summary.json's model names the maintainer leg that ran, not the phantom implement seat" \
        "haiku" "$(jq -r '.model' "$rd_pi/summary.json")"
else
    no "a read-only maintain-only run moved off its preset harness needs no pi.env"
fi
mv "$real_cfg/pi.env.aside" "$real_cfg/pi.env"

# --pipeline has no model that natively seats pi (see MODELS in
# fork-sandbox-pipeline-spec.py), so this case needs a hand-written preset
# -- the same mnt-only-pi fixture used above, whose lone step runs on pi.
ro_refuses "--pi-args is refused on a maintain-only read-only preset" \
    "have no route" --preset mnt-only-pi --pi-args "--foo"

# The round-one composed shape exercises consecutive review steps, a finding
# and fix round, and the preceding-verdict handoff to maintain.
cat > "$real_presets/composed.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 2
    agent: reviewer
EOF
prep_stub $'commit\nfindings\ncommit\napproved\napproved'
if rd_composed="$(run_stubbed --preset composed --branch "sandbox-test-composed-$$-$RANDOM")"; then
    tmpdirs+=("$rd_composed")
    check "composed walk runs every step and its finding fix" "5" "$(cat "$count")"
    contains "the first code leg runs its own seat's model, not the default seat's" \
        "$(sed -n 1p "$argv_log")" "--model sonnet"
    if [[ -s "$rd_composed/step-2-loop.json" && -s "$rd_composed/step-3-loop.json" \
        && -s "$rd_composed/step-4-loop.json" && -s "$rd_composed/s4-maintain-verdict-1.md" ]]; then
        ok "composed walk writes step-indexed artifacts"
    else
        no "composed walk writes step-indexed artifacts" \
            "$(find "$rd_composed" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')"
    fi
    check "composed walk writes pipeline.json" "4" "$(jq -r '.steps | length' "$rd_composed/pipeline.json")"
    contains "maintain receives the preceding verdict's inner-review role" \
        "$(cat "$rd_composed/step-4-prompt-1.md")" "inner review loop has already read that diff"
    lacks "maintain does not receive the contradictory first-review role" \
        "$(cat "$rd_composed/step-4-prompt-1.md")" "no review has read that diff yet"
    lacks "composed fix prompt excludes the verdict report" \
        "$(cat "$rd_composed/s2-fix-prompt-1.md")" "Ignore this operational note"
else
    no "composed walk launch succeeds"
fi

# A1b. cur_save's jq write is `... > "$f.part" && mv ... "$f.part" "$f"` --
# on a jq failure the redirection still creates the .part file, and without
# a cleanup on the failed branch it is stranded in the run dir forever,
# tripping the pinned filename-set contract other tests here rely on. Force
# every cur_save jq call in a one-step review composed run to fail (the jq
# wrapper above only misbehaves for cur_save's own "--arg fix_harness"
# signature) and confirm no .part file survives the run.
cat > "$real_presets/jqfail.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: coder
EOF
prep_stub $'commit\napproved'
if rd_jqfail="$(FAKE_JQ_FAIL_LOOP_SAVE=1 run_stubbed --preset jqfail \
    --branch "sandbox-test-jqfail-$$")"; then
    tmpdirs+=("$rd_jqfail")
    check "the forced jq failure kept step-2-loop.json from ever being written" \
        "" "$(cat "$rd_jqfail/step-2-loop.json" 2>/dev/null)"
    if [[ -z "$(find "$rd_jqfail" -maxdepth 1 -name '*.part' 2>/dev/null)" ]]; then
        ok "cur_save cleans up its .part file when jq fails"
    else
        no "cur_save cleans up its .part file when jq fails" \
            "$(find "$rd_jqfail" -maxdepth 1 -name '*.part' -exec basename {} \; | tr '\n' ' ')"
    fi
else
    no "jqfail launch succeeds"
fi

# A2. A bare --review-loop with no --review-model/--review-harness: the
# review leg actually runs the implement harness AND model (review_sandbox_cmd
# copies sandbox_cmd verbatim when review_harness_given is false), so
# pipeline.json's review step must say so too, not "model": null.
cat > "$real_presets/reviewloop.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
pipeline:
  - action: code
    agent: coder
EOF
prep_stub $'commit\napproved'
if rd_a2="$(run_stubbed --preset reviewloop --review-loop 1 \
    --branch "sandbox-test-reviewloop-$$")"; then
    tmpdirs+=("$rd_a2")
    check "a bare --review-loop's step harness is the implement seat's" \
        "claude" "$(jq -r '.steps[1].harness' "$rd_a2/pipeline.json")"
    check "a bare --review-loop's step model is the implement seat's, not null" \
        "haiku" "$(jq -r '.steps[1].model' "$rd_a2/pipeline.json")"
    check "a bare --review-loop's step network is null (unsealed)" \
        "null" "$(jq -r '.steps[1].network' "$rd_a2/pipeline.json")"
else
    no "reviewloop launch succeeds"
fi

# A3. A sealed (pi-local) coder with an unsealed, explicitly-named reviewer:
# the review step's network must not inherit the coder's "sealed" just
# because review_network itself is unset -- and the coder's own default fix
# seat (repeat: 2 triggers a fix record with no fix_agent named) must not
# serialize its undiscovered model as "" where the rest of the file uses
# null, and must keep the "pi-local" spelling (the fix schema has no
# network field to say "sealed" any other way) rather than collapsing into
# the ambiguous "pi" an OpenRouter fix seat would also show. The coder's
# repeat: 2 leg also exercises run.sh's pipeline.json model backfill, since
# agent-sandboxed never gets a --model flag here -- and that backfill must
# reach the fix seat's model too, since it is the same sealed endpoint.
cat > "$real_presets/sealed-review.yaml" <<'EOF'
agents:
  coder:
    harness: pi-local
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
prep_stub 'noop'
if rd_a3="$(run_stubbed --preset sealed-review \
    --branch "sandbox-test-sealed-review-$$")"; then
    tmpdirs+=("$rd_a3")
    check "the sealed coder's step harness is pi (pi-local, expanded)" \
        "pi" "$(jq -r '.steps[0].harness' "$rd_a3/pipeline.json")"
    check "the sealed coder's step network is sealed" \
        "sealed" "$(jq -r '.steps[0].network' "$rd_a3/pipeline.json")"
    check "the sealed coder's step model is backfilled from the sandbox log" \
        "vendor/discovered-model" "$(jq -r '.steps[0].model' "$rd_a3/pipeline.json")"
    check "the unsealed, named reviewer's step harness is its own" \
        "claude" "$(jq -r '.steps[1].harness' "$rd_a3/pipeline.json")"
    check "the unsealed, named reviewer's step network is null, not the sealed coder's" \
        "null" "$(jq -r '.steps[1].network' "$rd_a3/pipeline.json")"
    check "the unsealed, named reviewer's step model is its own" \
        "opus" "$(jq -r '.steps[1].model' "$rd_a3/pipeline.json")"
    check "the review step's default fix seat inherits the coder's harness, sealed" \
        "pi-local" "$(jq -r '.steps[1].fix.harness' "$rd_a3/pipeline.json")"
    check "the review step's default fix seat's model is backfilled too, same sealed seat" \
        "vendor/discovered-model" "$(jq -r '.steps[1].fix.model' "$rd_a3/pipeline.json")"
    check "the review step's default fix seat's repeat is the coder's own" \
        "2" "$(jq -r '.steps[1].fix.repeat' "$rd_a3/pipeline.json")"
else
    no "sealed-review launch succeeds"
fi

# A4. A pi-local review STEP itself (not the code seat, not a fix seat) --
# the case round 3 closes. The reviewer agent is pi-local at a review step,
# whose own leg never runs at all (the coder's pi-local pass is a "noop",
# so the branch never moves past base_sha and the review step is marked
# skipped before run_leg is ever called for it) -- proving the backfill
# does not depend on the seat's own leg having executed, only on some
# pi-local leg in the run (here, the code seat) having discovered the
# model first.
cat > "$real_presets/sealed-review-step.yaml" <<'EOF'
agents:
  coder:
    harness: pi-local
  reviewer:
    harness: pi-local
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
EOF
prep_stub 'noop'
if rd_a4="$(run_stubbed --preset sealed-review-step \
    --branch "sandbox-test-sealed-review-step-$$")"; then
    tmpdirs+=("$rd_a4")
    check "the sealed review step's harness is pi (pi-local, expanded)" \
        "pi" "$(jq -r '.steps[1].harness' "$rd_a4/pipeline.json")"
    check "the sealed review step's network is sealed" \
        "sealed" "$(jq -r '.steps[1].network' "$rd_a4/pipeline.json")"
    check "the sealed review step's own model is backfilled, not left null" \
        "vendor/discovered-model" "$(jq -r '.steps[1].model' "$rd_a4/pipeline.json")"
else
    no "sealed-review-step launch succeeds"
fi

# D. A definition edited between the staging and the run dir -- the race the
# provenance exists around: the recorded sha256 must identify the staged
# bytes, not the edit, and the run-dir copy must be those bytes.
# The fake backend's --capabilities probe runs inside that window, so it
# performs the edit when RACE_PRESET_FILE names the live file.
race_live="$real_presets/race.yaml"
cat > "$race_live" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
pipeline:
  - action: code
    agent: coder
EOF
race_orig="$tmp/race.orig"
cp -- "$race_live" "$race_orig"
prep_stub 'commit'
if rd_d="$(RACE_PRESET_FILE="$race_live" run_stubbed \
    --preset race --branch "sandbox-test-race-$$")"; then
    tmpdirs+=("$rd_d")
    contains "the test's race actually happened" \
        "$(cat "$race_live")" "edited mid-launch"
    check "the recorded sha256 is the staged bytes' hash, not the edit's" \
        "$(sha256sum "$race_orig" | cut -d' ' -f1)" \
        "$(jq -r '.sha256' "$rd_d/preset.json")"
    if cmp -s "$rd_d/preset.yaml" "$race_orig"; then
        ok "the run-dir copy is the pre-edit definition"
    else
        no "the run-dir copy is the pre-edit definition" \
            "$rd_d/preset.yaml differs from $race_orig"
    fi
    check "the run still compiled the pre-edit document" \
        "0" "$(cat "$rd_d/exit-code" 2>/dev/null)"
    contains "run.env carries the pre-edit harness" \
        "$(cat "$rd_d/run.env")" "harness=claude"
    contains "run.env carries the pre-edit model" \
        "$(cat "$rd_d/run.env")" "model=haiku"
else
    no "race launch succeeds"
fi

# E. A launch that fails after staging the bytes (this one at the handoff
# boundary, between the parse and the run dir) leaves no staged file in
# its TMPDIR behind.
stage_tmp="$(mktemp -d)"; tmpdirs+=("$stage_tmp")
err_stage="$tmp/err-stage"
bad_handoff="$tmp/not-a-scratch-handoff.md"
printf 'do the task\n' > "$bad_handoff"
out="$(HOME="$launcher_home" TMPDIR="$stage_tmp" PATH="$real_stub:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --preset race "$proj" \
    "$bad_handoff" 2>"$err_stage")"
rc_stage=$?
if (( rc_stage != 0 )) && [[ -n "$out" || -s "$err_stage" ]]; then
    if [[ -z "$(find "$stage_tmp" -name 'claude-fork-sandbox-preset.*')" ]]; then
        ok "a failed launch cleans up the staged preset bytes"
    else
        no "a failed launch cleans up the staged preset bytes" \
            "$(find "$stage_tmp" -name 'claude-fork-sandbox-preset.*')"
    fi
    contains "the failure is the handoff boundary, not the preset" \
        "$(cat "$err_stage")" "handoff files must live under"
else
    no "the handoff-boundary launch fails, as the test needs"
fi

# F. The --k8s dispatch ends in exec, which discards the EXIT trap the
# preset staging set: a --preset --k8s launch must still leave no staged
# file in its TMPDIR. The scripts dir is copied with its
# fork-sandbox-k8s.sh replaced by a stub, so the exec lands somewhere the
# test controls.
k8s_scripts="$tmp/k8s-scripts"
cp -r "$repo_dir/scripts" "$k8s_scripts"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "k8s-stub %s\n" "$@"' \
    > "$k8s_scripts/fork-sandbox-k8s.sh"
chmod +x "$k8s_scripts/fork-sandbox-k8s.sh"
stage_tmp_k8s="$(mktemp -d)"; tmpdirs+=("$stage_tmp_k8s")
err_k8s="$tmp/err-k8s"
out="$(HOME="$launcher_home" TMPDIR="$stage_tmp_k8s" PATH="$real_stub:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$k8s_scripts/fork-sandbox.sh" --preset race \
    --k8s "$proj" "$handoff" 2>"$err_k8s")"
rc_k8s=$?
if (( rc_k8s == 0 )) && [[ "$out" == *k8s-stub* ]]; then
    if [[ -z "$(find "$stage_tmp_k8s" -name 'claude-fork-sandbox-preset.*')" ]]; then
        ok "a --preset --k8s launch cleans up the staged preset bytes"
    else
        no "a --preset --k8s launch cleans up the staged preset bytes" \
            "$(find "$stage_tmp_k8s" -name 'claude-fork-sandbox-preset.*')"
    fi
else
    no "the --k8s launch reaches the stubbed fork-sandbox-k8s.sh, as the test needs" \
        "rc=$rc_k8s out=$(printf '%s' "$out" | head -3) err=$(head -3 "$err_k8s")"
fi

# G. The code seat's endpoint key compiles onto the --endpoint value the
# k8s dispatch forwards, and an explicit --endpoint beats the key key by
# key, announced on stderr. Reuses F's stubbed fork-sandbox-k8s.sh and
# asserts on the argv the stub prints.
cat > "$real_presets/ep.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
    endpoint: llm
pipeline:
  - action: code
    agent: coder
EOF
err_ep="$tmp/err-ep"
out_ep="$(HOME="$launcher_home" TMPDIR="$stage_tmp_k8s" PATH="$real_stub:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$k8s_scripts/fork-sandbox.sh" --preset ep \
    --k8s "$proj" "$handoff" 2>"$err_ep")"
rc_ep=$?
# The stub prints one argument per line; strip its prefix and join, then
# match the flag and its value as one string.
ep_argv="$(printf '%s\n' "$out_ep" | sed 's/^k8s-stub //' | tr '\n' ' ')"
if (( rc_ep == 0 )) && [[ "$ep_argv" == *"--endpoint llm"* ]]; then
    ok "a --k8s launch of a code-seat endpoint preset forwards it to fork-sandbox-k8s.sh"
else
    no "a --k8s launch of a code-seat endpoint preset forwards it to fork-sandbox-k8s.sh" \
        "rc=$rc_ep out=$(printf '%s' "$out_ep" | head -3) err=$(head -3 "$err_ep")"
fi
err_ep2="$tmp/err-ep2"
out_ep2="$(HOME="$launcher_home" TMPDIR="$stage_tmp_k8s" PATH="$real_stub:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$k8s_scripts/fork-sandbox.sh" --preset ep \
    --endpoint other --k8s "$proj" "$handoff" 2>"$err_ep2")"
rc_ep2=$?
ep_argv2="$(printf '%s\n' "$out_ep2" | sed 's/^k8s-stub //' | tr '\n' ' ')"
if (( rc_ep2 == 0 )) && [[ "$ep_argv2" == *"--endpoint other"* ]]; then
    ok "--endpoint beats the preset's endpoint and forwards the flag"
else
    no "--endpoint beats the preset's endpoint and forwards the flag" \
        "rc=$rc_ep2 out=$(printf '%s' "$out_ep2" | head -3) err=$(head -3 "$err_ep2")"
fi
contains "the --endpoint override is announced on stderr" \
    "$(cat "$err_ep2")" "--endpoint overrides the code seat's endpoint"

# A --harness override moves the code seat but does NOT drop the seat's
# endpoint key (unlike model/args/repeat): the k8s dispatch still
# forwards it, and the seat-override note never claims it was dropped.
err_ep3="$tmp/err-ep3"
out_ep3="$(HOME="$launcher_home" TMPDIR="$stage_tmp_k8s" PATH="$real_stub:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$k8s_scripts/fork-sandbox.sh" --preset ep \
    --harness pi --model moonshotai/kimi-k3 --k8s "$proj" "$handoff" 2>"$err_ep3")"
rc_ep3=$?
ep_argv3="$(printf '%s\n' "$out_ep3" | sed 's/^k8s-stub //' | tr '\n' ' ')"
if (( rc_ep3 == 0 )) && [[ "$ep_argv3" == *"--endpoint llm"* ]]; then
    ok "a --harness override keeps the code seat's endpoint"
else
    no "a --harness override keeps the code seat's endpoint" \
        "rc=$rc_ep3 out=$(printf '%s' "$out_ep3" | head -3) err=$(head -3 "$err_ep3")"
fi
contains "the seat override fires for the moved seat" \
    "$(cat "$err_ep3")" "--harness overrides the code seat"
lacks "the seat-override note does not claim the endpoint was dropped" \
    "$(cat "$err_ep3")" "endpoint"

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
if rd_b="$(run_stubbed \
    --preset fixseat --branch "sandbox-test-fixseat-$$")"; then
    tmpdirs+=("$rd_b")
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
    check "pipeline.json's step 0 is the code action with the coder's model" \
        "code/fable" \
        "$(jq -r '.steps[0] | "\(.action)/\(.model)"' "$rd_b/pipeline.json")"
    check "pipeline.json's step 1 is the review action with the reviewer's model" \
        "review/opus" \
        "$(jq -r '.steps[1] | "\(.action)/\(.model)"' "$rd_b/pipeline.json")"
    check "pipeline.json's step 1 repeat is the loop cap" "2" \
        "$(jq -r '.steps[1].repeat' "$rd_b/pipeline.json")"
    check "pipeline.json's step 1 fix names the fix seat, distinct from both" \
        "claude/haiku/2" \
        "$(jq -r '.steps[1].fix | "\(.harness)/\(.model)/\(.repeat)"' "$rd_b/pipeline.json")"
else
    no "fixseat launch succeeds"
fi

# C. A run with no preset emits none of the fix-seat-era state: run.sh and
# run.env stay byte-compatible with what they were before fix seats existed,
# on every knob but the run_step_* walker state below, which is serialized
# for every run regardless of preset (a later round's prerequisite -- see
# the run_step_count pin below).
prep_stub 'commit'
if rd_c="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox-test-plain-$$")"; then
    tmpdirs+=("$rd_c")
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
    # preset_stage_cleanup is a launcher-only function (the launcher's own
    # EXIT trap); a run.sh that calls it hits "command not found" in every
    # teardown, since the generated runner never defines it.
    if ! grep -q 'preset_stage_cleanup' "$rd_c/run.sh"; then
        ok "run.sh never references the launcher-only preset_stage_cleanup"
    else
        no "run.sh never references the launcher-only preset_stage_cleanup" \
            "$(grep -n 'preset_stage_cleanup' "$rd_c/run.sh")"
    fi
    # A plain run has one step: the code leg. This is the shape a unified
    # walker will drive for every no-loop run once it becomes the only
    # driver; pin it now so that migration is checked against today's
    # single-step serialization, not a guess at what it should be.
    check "a plain run.sh serializes run_step_count as a single code step" "1" \
        "$(grep -o '^run_step_count=.*' "$rd_c/run.sh" | sed 's/run_step_count=//')"
    contains "a plain run.sh's run_step_kind names that one step code" \
        "$(grep '^run_step_kind=' "$rd_c/run.sh")" '[1]=code'
else
    no "plain launch succeeds"
fi

# H. R9e decision (b): pipeline selection is mechanical, not a classifier --
# fork-sandbox.sh's review loop already skips when the code leg's commit
# range is empty, so a preset's review leg costs nothing on a wake that
# committed nothing, and runs in full on one that did. This is the
# fork-sandbox.sh-level test the brief's Section 3 calls for when the
# postmaster-level stub cannot express whether a leg actually ran (see the
# final report: postmaster backgrounds every spawn into tmux with no
# --foreground seam, so a literal through-postmaster run cannot observe
# this).
cat > "$real_presets/skiptest.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: haiku
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

# H1: the code leg commits nothing -> the review leg never runs at all.
prep_stub 'noop'
if rd_h1="$(run_stubbed --preset skiptest \
    --branch "sandbox-test-skiptest-noop-$$")"; then
    tmpdirs+=("$rd_h1")
    check "no-commit preset wake: only the code leg ran" "1" "$(cat "$count")"
    if [[ -e "$rd_h1/events-review-1.jsonl" ]]; then
        no "no-commit preset wake: no review-leg events file" \
            "$(find "$rd_h1" -maxdepth 1 -name 'events-*' 2>/dev/null | tr '\n' ' ')"
    else
        ok "no-commit preset wake: no review-leg events file"
    fi
    contains "no-commit preset wake: summary records the skip and why" \
        "$(cat "$rd_h1/summary.txt")" \
        "review:    skipped -- the session committed nothing, so there is nothing to review"
else
    no "skiptest (noop) launch succeeds"
fi

# H2: the code leg commits -> the review leg runs (approved, one iteration).
prep_stub $'commit\napproved'
if rd_h2="$(run_stubbed --preset skiptest \
    --branch "sandbox-test-skiptest-commit-$$")"; then
    tmpdirs+=("$rd_h2")
    check "committing preset wake: code and review legs both ran" "2" \
        "$(cat "$count")"
    if [[ -s "$rd_h2/events-review-1.jsonl" ]]; then
        ok "committing preset wake: review-leg events file exists"
    else
        no "committing preset wake: review-leg events file exists" \
            "$(find "$rd_h2" -maxdepth 1 -name 'events-*' 2>/dev/null | tr '\n' ' ')"
    fi
    contains "committing preset wake: summary records the approved loop" \
        "$(cat "$rd_h2/summary.txt")" \
        "review:    1 iteration(s), findings 0; loop exit: approved"
else
    no "skiptest (commit) launch succeeds"
fi

printf '\n== progress.json: a live per-step status file ==\n'

# One entry per pipeline step, in order, as "<action>/<state>/<i>/<cap>/<ended>"
# (ended reads the literal string "null" through jq -r, not empty) -- the
# compact shape every check below reduces a run's progress.json to.
progress_steps() {
    jq -r '[.steps[] | "\(.action)/\(.state)/\(.i)/\(.cap)/\(.ended)"] | join(" ")' \
        "$1/progress.json" 2>/dev/null
}

# Same reduction as progress_steps, but for a snapshot file's own exact
# path rather than a run dir's progress.json -- the mid-run captures below
# are named "progress-<call number>.json" beside each other, not one per
# directory.
snapshot_steps() {
    jq -r '[.steps[] | "\(.action)/\(.state)/\(.i)/\(.cap)/\(.ended)"] | join(" ")' \
        "$1" 2>/dev/null
}

# Spot-check three shapes already built above, rather than launching them
# again: a composed multi-review-then-maintain pipeline that ends approved
# (rd_composed), a read-only review-then-maintain pipeline with no code
# step at all (rd_ro), and a code leg that commits nothing, skipping its
# review step (rd_h1).
if [[ -n "${rd_composed:-}" ]]; then
    check "composed run's progress.json exists, not a symlink" "1" \
        "$( [[ -f "$rd_composed/progress.json" && ! -L "$rd_composed/progress.json" ]] && echo 1)"
    check "composed run's progress.json spec is the preset name" \
        "composed" "$(jq -r '.spec' "$rd_composed/progress.json")"
    check "composed run's progress.json state is done" \
        "done" "$(jq -r '.state' "$rd_composed/progress.json")"
    check "composed run's progress.json updated is an integer" "true" \
        "$(jq -r '(.updated | type == "number") and (.updated == (.updated | floor))' \
            "$rd_composed/progress.json")"
    check "composed run's progress.json has one entry per pipeline step" \
        "4" "$(jq -r '.steps | length' "$rd_composed/progress.json")"
    check "composed run's progress.json steps, in pipeline order" \
        "code/done/1/1/null review/done/1/1/cap review/done/1/1/approved maintain/done/1/2/approved" \
        "$(progress_steps "$rd_composed")"
    check "composed run's progress.json .part file is gone" "0" \
        "$(find "$rd_composed" -maxdepth 1 -name 'progress.json.part' | wc -l)"
else
    no "rd_composed unavailable for progress.json checks"
fi

if [[ -n "${rd_ro:-}" ]]; then
    check "a read-only pipeline's progress.json spec is the pipeline string" \
        "rhaiku-mopus" "$(jq -r '.spec' "$rd_ro/progress.json")"
    check "a read-only pipeline's progress.json state is done" \
        "done" "$(jq -r '.state' "$rd_ro/progress.json")"
    check "a read-only pipeline's progress.json has no code step" \
        "review/done/1/1/findings maintain/done/1/1/approved" \
        "$(progress_steps "$rd_ro")"
else
    no "rd_ro unavailable for progress.json checks"
fi

if [[ -n "${rd_h1:-}" ]]; then
    check "a coder that commits nothing: the review step is skipped" \
        "code/done/1/1/null review/skipped/0/1/skipped" \
        "$(progress_steps "$rd_h1")"
    check "a coder that commits nothing: the run itself is still done" \
        "done" "$(jq -r '.state' "$rd_h1/progress.json")"
else
    no "rd_h1 unavailable for progress.json checks"
fi

# label strips a leading sandbox/-style prefix (one path segment); spec is
# null for a plain-flags run with neither --preset nor --pipeline.
prep_stub 'commit'
if rd_prog_plain="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox/prog-plain-$$")"; then
    tmpdirs+=("$rd_prog_plain")
    check "a plain run's progress.json label strips the sandbox/ prefix" \
        "prog-plain-$$" "$(jq -r '.label' "$rd_prog_plain/progress.json")"
    check "a plain run's progress.json spec is null" \
        "null" "$(jq -r '.spec' "$rd_prog_plain/progress.json")"
    check "a plain run's progress.json state is done" \
        "done" "$(jq -r '.state' "$rd_prog_plain/progress.json")"
    check "a plain run's progress.json has one code step" \
        "code/done/1/1/null" "$(progress_steps "$rd_prog_plain")"
else
    no "progress.json plain-run launch succeeds"
fi

# A --pipeline run with a code, a review and a maintain step, the review
# approving on its first pass: spec is the raw spec string, not a preset
# name, and action "maintain" (not run_leg's own "maintainer" vocabulary).
prep_stub $'commit\napproved\napproved'
if rd_prog_pipeline="$(run_stubbed --pipeline csonnet-rsonnet-msonnet \
    --branch "sandbox-test-prog-pipeline-$$")"; then
    tmpdirs+=("$rd_prog_pipeline")
    check "a --pipeline run's progress.json spec is the spec string" \
        "csonnet-rsonnet-msonnet" "$(jq -r '.spec' "$rd_prog_pipeline/progress.json")"
    check "a --pipeline code+review+maintain run's progress.json steps" \
        "code/done/1/1/null review/done/1/1/approved maintain/done/1/1/approved" \
        "$(progress_steps "$rd_prog_pipeline")"
    check "a --pipeline code+review+maintain run's state is done" \
        "done" "$(jq -r '.state' "$rd_prog_pipeline/progress.json")"
else
    no "progress.json --pipeline launch succeeds"
fi

# A review loop that never approves runs to its cap: the fix leg commits
# each time (so the loop never ends early on no-progress), and the loop
# entry itself is done, ended "cap" -- a harness error, not a stop.
prep_stub $'commit\nfindings\ncommit\nfindings\ncommit'
if rd_prog_cap="$(run_stubbed --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-prog-cap-$$")"; then
    tmpdirs+=("$rd_prog_cap")
    check "a review loop exhausting its cap: the step ends cap, at cap/cap" \
        "code/done/1/1/null review/done/2/2/cap" "$(progress_steps "$rd_prog_cap")"
    check "a review loop exhausting its cap: the run itself is still done" \
        "done" "$(jq -r '.state' "$rd_prog_cap/progress.json")"
else
    no "progress.json review-loop-cap launch succeeds"
fi

# Intermediate state, not just the terminal file: progress.json is rewritten
# BEFORE each leg starts (fork-sandbox.sh's progress_write call precedes the
# harness invocation), so while a call to the claude-sandboxed stub is in
# flight, the file on disk already reflects that leg as the active one. The
# stub's own SNAPSHOT_DIR capture (see claude-sandboxed above) copies
# progress.json aside on every call, keyed by call number, so this is the
# one place this suite can see a state the terminal file below always
# overwrites: "running" with the right i, not yet finalized.
#
# A code step with repeat 3: each of the three snapshots must show the step
# already "running" at that pass's own i, not the one before it -- an
# undercount a terminal-only check cannot see.
snapshot_dir_repeat="$(mktemp -d)"; tmpdirs+=("$snapshot_dir_repeat")
prep_stub $'commit\nnoop\ncommit'
if rd_prog_repeat="$(SNAPSHOT_DIR="$snapshot_dir_repeat" run_stubbed --preset rep3 \
    --branch "sandbox-test-prog-repeat-$$")"; then
    tmpdirs+=("$rd_prog_repeat")
    check "repeat-code pass 1: snapshot shows the step running at i=1" \
        "code/running/1/3/null" "$(snapshot_steps "$snapshot_dir_repeat/progress-1.json")"
    check "repeat-code pass 2: snapshot shows the step running at i=2" \
        "code/running/2/3/null" "$(snapshot_steps "$snapshot_dir_repeat/progress-2.json")"
    check "repeat-code pass 3: snapshot shows the step running at i=3" \
        "code/running/3/3/null" "$(snapshot_steps "$snapshot_dir_repeat/progress-3.json")"
else
    no "progress.json repeat-code snapshot launch succeeds"
fi

# A review loop iteration: each review leg (the odd-numbered calls below)
# must see the review step already "running" at that iteration's own i,
# the same off-by-one the repeat-pass check above guards against, for the
# loop walker's cur_i instead of the repeat counter.
snapshot_dir_review="$(mktemp -d)"; tmpdirs+=("$snapshot_dir_review")
prep_stub $'commit\nfindings\ncommit\nfindings\ncommit'
if rd_prog_review_snap="$(SNAPSHOT_DIR="$snapshot_dir_review" run_stubbed \
    --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-prog-review-snap-$$")"; then
    tmpdirs+=("$rd_prog_review_snap")
    check "review iteration 1: snapshot shows the step running at i=1" \
        "code/done/1/1/null review/running/1/2/null" \
        "$(snapshot_steps "$snapshot_dir_review/progress-2.json")"
    check "review iteration 2: snapshot shows the step running at i=2" \
        "code/done/1/1/null review/running/2/2/null" \
        "$(snapshot_steps "$snapshot_dir_review/progress-4.json")"
else
    no "progress.json review-loop snapshot launch succeeds"
fi

# A failing leg: the coding leg itself exits non-zero, --foreground execs
# run.sh, so this run's own exit code IS that leg's. The step is failed,
# and so -- unlike a review-loop harness error, which never touches $rc in
# an ordinary run -- is the run itself.
prep_stub 'fail'
if rd_prog_fail_rc="$(run_stubbed_expect_fail --harness claude --model haiku \
    --branch "sandbox-test-prog-fail-$$")"; then
    rd_prog_fail="${rd_prog_fail_rc%%$'\t'*}"
    prog_fail_rc="${rd_prog_fail_rc##*$'\t'}"
    tmpdirs+=("$rd_prog_fail")
    check "a failing code leg's own exit code is non-zero" "1" "$prog_fail_rc"
    check "a failing code leg's exit-code file agrees" "1" \
        "$(cat "$rd_prog_fail/exit-code" 2>/dev/null)"
    check "a failing code leg's progress.json step is failed" \
        "code/failed/1/1/null" "$(progress_steps "$rd_prog_fail")"
    check "a failing code leg's progress.json run state is failed" \
        "failed" "$(jq -r '.state' "$rd_prog_fail/progress.json")"
else
    no "progress.json failing-leg launch produced a run dir"
fi

# A composed pipeline with a SECOND code step (code, review, code): the
# first code leg fails, so $rc is non-zero before either later step's own
# leg ever runs. Neither the review step nor the second code step gets to
# run its own leg -- only the leg that actually failed may be "failed"; a
# step an earlier failure prevented from running must read "skipped", not
# "failed" (see the code-step branch's own cur_code_already_ran gate for
# why this is not just $rc == 0).
cat > "$real_presets/composed-2code.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: code
    agent: coder
EOF
prep_stub 'fail'
if rd_prog_2code_fail="$(run_stubbed_expect_fail --preset composed-2code \
    --branch "sandbox-test-prog-2code-fail-$$")"; then
    rd_prog_2code="${rd_prog_2code_fail%%$'\t'*}"
    prog_2code_rc="${rd_prog_2code_fail##*$'\t'}"
    tmpdirs+=("$rd_prog_2code")
    check "a composed pipeline's first code leg fails: run exit code is non-zero" \
        "1" "$prog_2code_rc"
    check "a composed pipeline's first code leg fails: only that step is failed" \
        "code/failed/1/1/null review/skipped/0/1/skipped code/skipped/0/1/skipped" \
        "$(progress_steps "$rd_prog_2code")"
    check "a composed pipeline's first code leg fails: run state is failed" \
        "failed" "$(jq -r '.state' "$rd_prog_2code/progress.json")"
else
    no "progress.json composed-2code failing-first-leg launch produced a run dir"
fi

printf '\n== launcher_session_id and the by-session symlink ==\n'

by_session_tmp="$(mktemp -d)"; tmpdirs+=("$by_session_tmp")

# A valid session id: run.env records it, and the run dir is linked under
# <by-session-root>/<id>/<run-dir-basename>.
prep_stub 'commit'
launch_with_session "fixture-session-$$" "$by_session_tmp/valid" \
    --harness claude --model haiku --branch "sandbox-test-session-ok-$$"
if [[ "$LWS_RC" -eq 0 && -n "$LWS_RD" ]]; then
    rd_sess_ok="$LWS_RD"; tmpdirs+=("$rd_sess_ok")
    contains "run.env records the launching session id" \
        "$(cat "$rd_sess_ok/run.env")" "launcher_session_id=fixture-session-$$"
    link_path="$by_session_tmp/valid/fixture-session-$$/$(basename "$rd_sess_ok")"
    check "the by-session symlink exists" "1" \
        "$( [[ -L "$link_path" ]] && echo 1)"
    check "the by-session symlink resolves to the run dir" "$rd_sess_ok" \
        "$(readlink -f "$link_path" 2>/dev/null)"
else
    no "session-id launch succeeds" "$LWS_OUT"
fi

# An unsafe session id (not a single safe path component): run.env still
# records the raw value, exactly what CLAUDE_CODE_SESSION_ID held, but no
# symlink is attempted -- in particular "../x" must never be allowed to
# turn into a path one level outside the by-session root.
prep_stub 'commit'
launch_with_session "../x" "$by_session_tmp/unsafe" \
    --harness claude --model haiku --branch "sandbox-test-session-unsafe-$$"
if [[ "$LWS_RC" -eq 0 && -n "$LWS_RD" ]]; then
    rd_sess_unsafe="$LWS_RD"; tmpdirs+=("$rd_sess_unsafe")
    contains "run.env records the unsafe session id verbatim" \
        "$(cat "$rd_sess_unsafe/run.env")" "launcher_session_id=../x"
    contains "an unsafe session id is warned about, not silently dropped" \
        "$LWS_OUT" "is not a safe"
    check "an unsafe session id creates no by-session directory at all" "0" \
        "$(find "$by_session_tmp/unsafe" -mindepth 0 2>/dev/null | wc -l)"
    check "an unsafe session id never escapes the by-session root" "0" \
        "$( [[ -e "$by_session_tmp/x" ]] && echo 1 || echo 0)"
else
    no "unsafe-session-id launch succeeds" "$LWS_OUT"
fi

# No session id at all (the ordinary terminal-launch case): run.env records
# an empty value, and no by-session directory is created. CLAUDE_CODE_
# SESSION_ID is force-unset by launch_with_session itself here, not just
# omitted -- the session running this very suite may have its own exported.
prep_stub 'commit'
launch_with_session "" "$by_session_tmp/none" \
    --harness claude --model haiku --branch "sandbox-test-session-none-$$"
if [[ "$LWS_RC" -eq 0 && -n "$LWS_RD" ]]; then
    rd_sess_none="$LWS_RD"; tmpdirs+=("$rd_sess_none")
    contains "run.env records an empty session id when none was given" \
        "$(cat "$rd_sess_none/run.env")" $'launcher_session_id=\n'
    check "no session id means no by-session directory is created" "0" \
        "$( [[ -e "$by_session_tmp/none" ]] && echo 1 || echo 0)"
else
    no "no-session-id launch succeeds" "$LWS_OUT"
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
            no "a second record of the same preset does not rewrite the archive" \
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

printf '\n== the claude leg retry backstop: fs_leg_error_retryable ==\n'
# A table-driven unit test of the classifier itself, extracted verbatim from
# fork-sandbox-lib.sh (never hand-copied, so this cannot drift from what a
# real run.sh, and fork-sandbox-k8s-entrypoint.sh's own retry, actually
# carry -- both share this one function). Self-contained: no other function
# or runtime state is needed to call it.
extract_runner_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^}$/ { exit }
    ' "$launcher"
}
extract_lib_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^}$/ { exit }
    ' "$repo_dir/scripts/fork-sandbox-lib.sh"
}
classifier_src="$(mktemp)"; tmpdirs+=("$classifier_src")
extract_lib_fn fs_leg_error_retryable > "$classifier_src"
if [[ -s "$classifier_src" ]]; then
    # shellcheck source=/dev/null
    source "$classifier_src"
    # harness|text|1 if NOT retryable (fs_leg_error_retryable returns 1), 0 if retryable
    retry_cases=(
        'claude|Failed to authenticate. API Error: 401 OAuth access token has been revoked|0'
        'claude|api error: 401, token EXPIRED|0'
        'claude|API Error: 401 -- OAuth token invalid|0'
        'claude|the session ended in an error (401)|1'
        'claude|API Error: 529 {"type":"overloaded_error"}|0'
        'claude|Internal Server Error|0'
        'claude|overloaded_error: the model is overloaded, try again|0'
        'claude|API Error: 429 {"type":"rate_limit_error"}|1'
        'claude|API Error: 400 {"type":"invalid_request_error"}|1'
        'claude|API Error: 403 forbidden|1'
        'claude|API Error: 404 not found|1'
        'claude|API Error: 413 request too large|1'
        'claude|API Error: 429 overloaded_error|1'
        'claude||1'
        'codex|Failed to authenticate. API Error: 401 OAuth access token has been revoked|1'
        'pi|overloaded_error|1'
    )
    for rc_case in "${retry_cases[@]}"; do
        IFS='|' read -r rc_harness rc_text rc_want <<< "$rc_case"
        if fs_leg_error_retryable "$rc_harness" "$rc_text"; then rc_got=0; else rc_got=1; fi
        check "fs_leg_error_retryable($rc_harness, ${rc_text:-<empty>})" "$rc_want" "$rc_got"
    done
else
    no "fs_leg_error_retryable extracted from scripts/fork-sandbox-lib.sh" \
        "extraction found nothing -- has the function been renamed?"
fi

# A manual rerun of run.sh in the same run dir (the same scenario run_leg's
# own pi-session-copy comment names, "A runner re-run by hand in the same
# run dir is the case that does it") must not let a stale
# "<events>.attemptN" left over from an EARLIER invocation bleed into THIS
# invocation's retry-cost sum. Exercised directly against the extracted
# driver, with a fake --cost formatter, rather than through the stubbed
# engine: the scenario is "a file already existed before this call", which
# only a fresh temp dir seeded by hand can set up.
retry_fn_src="$(mktemp)"; tmpdirs+=("$retry_fn_src")
{
    extract_runner_fn fs_leg_retry_wait
    extract_runner_fn fs_run_claude_leg_with_retry
} > "$retry_fn_src"
if [[ -s "$retry_fn_src" ]]; then
    # fs_leg_error_retryable, which fs_run_claude_leg_with_retry (extracted
    # above) calls, now lives in fork-sandbox-lib.sh -- sourced before the
    # extracted fragment so the call below resolves.
    # shellcheck source=/dev/null
    source "$repo_dir/scripts/fork-sandbox-lib.sh"
    # shellcheck source=/dev/null
    source "$retry_fn_src"
    stale_dir="$(mktemp -d)"; tmpdirs+=("$stale_dir")
    stale_events="$stale_dir/events.jsonl"
    : > "$stale_events"
    # A stale archive from an earlier invocation of this same run dir, with
    # a cost that would be impossible to miss in the total below if it
    # survived into this invocation's own sum.
    printf '{"type":"result","subtype":"error","is_error":true,"result":"stale"}\n' \
        > "${stale_events}.attempt7"
    fake_fmt="$(mktemp)"; tmpdirs+=("$fake_fmt")
    cat > "$fake_fmt" <<'FMT'
#!/usr/bin/env bash
[[ "$1" == "--cost" ]] || exit 0
case "$2" in
    *.attempt7) printf '999\n' ;;
    *) printf '0.5\n' ;;
esac
FMT
    chmod +x "$fake_fmt"
    # Both read by fs_run_claude_leg_with_retry, sourced above from a
    # dynamically extracted fragment shellcheck cannot trace the use through.
    # shellcheck disable=SC2034
    FS_LEG_RETRY_DELAYS_ARR=(0 0)
    # shellcheck disable=SC2034
    stop_requested=0
    _stale_attempt_n=0
    _stale_attempt() {
        (( ++_stale_attempt_n ))
        if (( _stale_attempt_n == 1 )); then
            printf '{"type":"result","subtype":"error","is_error":true,"result":"API Error: 401 OAuth access token has been revoked"}\n' \
                > "$stale_events"
            _fs_leg_attempt_rc=1
        else
            printf '{"type":"result","subtype":"success"}\n' > "$stale_events"
            _fs_leg_attempt_rc=0
        fi
    }
    fs_run_claude_leg_with_retry claude "$stale_events" "$stale_dir/sandbox.log" \
        "the stale-archive leg" _stale_attempt "$fake_fmt"
    check "a stale .attempt archive from an earlier invocation is gone once this one starts" \
        "gone" "$([[ -e "${stale_events}.attempt7" ]] && echo present || echo gone)"
    # shellcheck disable=SC2154  # set by the sourced fragment above
    check "this invocation's own retry cost excludes the stale archive's inflated cost" \
        "0.5" "$fs_retry_extra_cost"
else
    no "fs_run_claude_leg_with_retry extracted from scripts/fork-sandbox.sh" \
        "extraction found nothing -- has the function been renamed?"
fi

printf '\n== the claude leg retry backstop: end-to-end (stubbed engine) ==\n'

# B1. A fix leg that hits a revoked-credential error once is retried, fresh,
# and the review loop continues to a second, approving iteration. Also pins
# the archived-attempt file contract: the failed attempt's own events land
# at events-fix-1.jsonl.attempt1, and the file left at events-fix-1.jsonl is
# the retry's own (no trace of the failure that preceded it).
prep_stub $'commit\nfindings\nauth401\ncommit\napproved'
if rd_retry1="$(run_stubbed --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-retry-fix-$$")"; then
    tmpdirs+=("$rd_retry1")
    check "a fix leg retried on a 401 lets the review loop reach a second iteration" \
        "approved" "$(jq -r '.ended' "$rd_retry1/review-loop.json" 2>/dev/null)"
    check "the retried iteration's own record carries one retry" \
        "1" "$(jq -r '.iterations[0].retries | length' "$rd_retry1/review-loop.json" 2>/dev/null)"
    check "the retry record names the attempt, delay and provider error" \
        "1 0" "$(jq -r '.iterations[0].retries[0] | "\(.attempt) \(.delay_s)"' \
            "$rd_retry1/review-loop.json" 2>/dev/null)"
    contains "the retry record's error names the revoked credential" \
        "$(jq -r '.iterations[0].retries[0].error' "$rd_retry1/review-loop.json" 2>/dev/null)" \
        "revoked"
    check "the retry record is labeled as the fix leg's own" \
        "fix" "$(jq -r '.iterations[0].retries[0].leg' "$rd_retry1/review-loop.json" 2>/dev/null)"
    # docs/presets.md and the header comment near :650 both say a fix
    # element carries `pass` only when the fix seat's repeat ran more than
    # one -- this seat's repeat is the default (1), so `pass` must be
    # absent here, not present as 1.
    check "a single-pass fix seat's retry record carries no pass key" \
        "false" "$(jq -r '.iterations[0].retries[0] | has("pass")' \
            "$rd_retry1/review-loop.json" 2>/dev/null)"
    contains "sandbox.log announces the retry" \
        "$(cat "$rd_retry1/sandbox.log" 2>/dev/null)" \
        "the fix leg of iteration 1 failed on a transient error"
    contains "sandbox.log confirms the retry succeeded" \
        "$(cat "$rd_retry1/sandbox.log" 2>/dev/null)" \
        "the fix leg of iteration 1 succeeded on retry 1"
    check "summary.json's leg_retries counts the one retry" \
        "1" "$(jq -r '.leg_retries' "$rd_retry1/summary.json" 2>/dev/null)"
    check "every scripted call actually ran (impl, review, fix x2, review)" \
        "5" "$(cat "$count" 2>/dev/null)"
    if [[ -s "$rd_retry1/events-fix-1.jsonl.attempt1" ]]; then
        ok "the failed attempt's events are archived to events-fix-1.jsonl.attempt1"
    else
        no "the failed attempt's events are archived to events-fix-1.jsonl.attempt1" \
            "$(find "$rd_retry1" -maxdepth 1 -name 'events-fix-1*' -exec basename {} \; | tr '\n' ' ')"
    fi
    contains "the archived attempt holds the failed attempt's own error" \
        "$(cat "$rd_retry1/events-fix-1.jsonl.attempt1" 2>/dev/null)" "revoked"
    lacks "the final events-fix-1.jsonl holds only the retry's own attempt" \
        "$(cat "$rd_retry1/events-fix-1.jsonl" 2>/dev/null)" "revoked"
else
    no "a fix leg retried on a 401 lets the review loop reach a second iteration" \
        "launch failed"
fi

# B1-cost. Same as B3-cost above, but for a run_leg leg rather than the
# implement leg: a retried fix leg's own archived attempt ($0.02) must join
# its own leg_cost, which is what feeds both fix_cost_usd and, through
# loop_cost_sum, total_cost_usd -- so neither loses the archived attempt's
# price nor counts it twice.
prep_stub $'commit\nfindings\nauth401-cost\ncommit\napproved'
if rd_retry1c="$(run_stubbed --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-retry-fix-cost-$$")"; then
    tmpdirs+=("$rd_retry1c")
    check "a retried fix leg's fix_cost_usd includes the archived attempt" \
        "0.03" "$(jq -r '.iterations[0].fix_cost_usd' "$rd_retry1c/review-loop.json" 2>/dev/null)"
    check "total_cost_usd counts the retried fix leg's archived attempt once" \
        "0.060000" "$(jq -r '.total_cost_usd' "$rd_retry1c/summary.json" 2>/dev/null)"
else
    no "a retried fix leg's fix_cost_usd includes the archived attempt" \
        "launch failed"
fi

# B1-cost-unknown. Same idea as B3-cost-unknown above, but for a run_leg
# leg: the fix leg's first archived attempt prices (auth401-cost, $0.02),
# its second (auth401) does not, and only the third attempt (commit)
# succeeds -- burning both of this suite's configured retries. fix_cost_usd
# and total_cost_usd must both be null, not a sum that silently drops the
# unpriced attempt.
prep_stub $'commit\nfindings\nauth401-cost\nauth401\ncommit\napproved'
if rd_retry1u="$(run_stubbed --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-retry-fix-cost-unknown-$$")"; then
    tmpdirs+=("$rd_retry1u")
    check "a fix leg with an unpriced archived attempt gets a null fix_cost_usd" \
        "null" "$(jq -r '.iterations[0].fix_cost_usd' "$rd_retry1u/review-loop.json" 2>/dev/null)"
    check "total_cost_usd is null too, not a partial sum" \
        "null" "$(jq -r '.total_cost_usd' "$rd_retry1u/summary.json" 2>/dev/null)"
else
    no "a fix leg with an unpriced archived attempt gets a null fix_cost_usd" \
        "launch failed"
fi

# B1b. When the review leg AND the fix leg of the SAME iteration both
# retry, their retry records must not be indistinguishable {attempt: 1,
# ...} entries in the shared iteration record -- each carries its own
# `leg` label.
prep_stub $'commit\nauth401\nfindings\nauth401\ncommit\napproved'
if rd_retry1d="$(run_stubbed --preset reviewloop --review-loop 2 \
    --branch "sandbox-test-retry-both-$$")"; then
    tmpdirs+=("$rd_retry1d")
    check "the shared iteration record carries both legs' retries" \
        "2" "$(jq -r '.iterations[0].retries | length' "$rd_retry1d/review-loop.json" 2>/dev/null)"
    check "the review leg's retry is labeled review" \
        "review" "$(jq -r '.iterations[0].retries[0].leg' "$rd_retry1d/review-loop.json" 2>/dev/null)"
    check "the fix leg's retry is labeled fix" \
        "fix" "$(jq -r '.iterations[0].retries[1].leg' "$rd_retry1d/review-loop.json" 2>/dev/null)"
else
    no "the shared iteration record carries both legs' retries" "launch failed"
fi

# B2. A review leg and a maintainer leg (a composed pipeline's own step
# kinds) are each retried the same way.
cat > "$real_presets/retry-review-maintain.yaml" <<'EOF'
agents:
  coder:
    harness: claude
    model: sonnet
  reviewer:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: maintain
    repeat: 1
    agent: reviewer
EOF
prep_stub $'commit\nauth401\napproved\nauth401\napproved'
if rd_retry2="$(run_stubbed --preset retry-review-maintain \
    --branch "sandbox-test-retry-revmnt-$$")"; then
    tmpdirs+=("$rd_retry2")
    # A bare code+review+maintain pipeline compiles to the legacy-shaped
    # tiers (preset_is_legacy_shaped), not step-indexed records -- so this
    # reads review-loop.json/maintainer-loop.json, the same files a
    # --review-loop/--maintainer-loop run would write, not step-N-loop.json.
    check "a composed review step's leg is retried and ends approved" \
        "approved" "$(jq -r '.ended' "$rd_retry2/review-loop.json" 2>/dev/null)"
    check "a composed maintain step's leg is retried and ends approved" \
        "approved" "$(jq -r '.ended' "$rd_retry2/maintainer-loop.json" 2>/dev/null)"
    check "the review step's iteration carries one retry" \
        "1" "$(jq -r '.iterations[0].retries | length' "$rd_retry2/review-loop.json" 2>/dev/null)"
    check "the maintain step's iteration carries one retry" \
        "1" "$(jq -r '.iterations[0].retries | length' "$rd_retry2/maintainer-loop.json" 2>/dev/null)"
    check "summary.json's leg_retries counts both legs' retries" \
        "2" "$(jq -r '.leg_retries' "$rd_retry2/summary.json" 2>/dev/null)"
    check "sandbox.log announces both retries" \
        "2" "$(grep -c 'failed on a transient error' "$rd_retry2/sandbox.log" 2>/dev/null)"
    check "sandbox.log confirms both retries succeeded" \
        "2" "$(grep -c 'succeeded on retry 1' "$rd_retry2/sandbox.log" 2>/dev/null)"
else
    no "a composed review step's leg is retried and ends approved" "launch failed"
fi

# B2b. A GENUINELY composed pipeline (four steps -- code, review, review,
# maintain -- too many review/maintain steps for the legacy-shape check
# above to recognize, see preset_is_legacy_shaped's own comment) retries a
# step-indexed leg the same way, writing to that step's own
# step-<N>-loop.json rather than review-loop.json/maintainer-loop.json.
prep_stub $'commit\nfindings\ncommit\nauth401\napproved\napproved'
if rd_retry2b="$(run_stubbed --preset composed \
    --branch "sandbox-test-retry-composed-$$")"; then
    tmpdirs+=("$rd_retry2b")
    check "a composed (step-indexed) review leg is retried and ends approved" \
        "approved" "$(jq -r '.ended' "$rd_retry2b/step-3-loop.json" 2>/dev/null)"
    check "the composed step's iteration carries one retry" \
        "1" "$(jq -r '.iterations[0].retries | length' "$rd_retry2b/step-3-loop.json" 2>/dev/null)"
    check "summary.json's leg_retries counts the composed step's retry" \
        "1" "$(jq -r '.leg_retries' "$rd_retry2b/summary.json" 2>/dev/null)"
else
    no "a composed (step-indexed) review leg is retried and ends approved" "launch failed"
fi

# B3. The top-level implement leg is retried too.
prep_stub $'auth401\ncommit'
if rd_retry3="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox-test-retry-impl-$$")"; then
    tmpdirs+=("$rd_retry3")
    check "a retried implement leg's run still exits clean" \
        "0" "$(cat "$rd_retry3/exit-code" 2>/dev/null)"
    contains "sandbox.log announces the implement leg's retry" \
        "$(cat "$rd_retry3/sandbox.log" 2>/dev/null)" \
        "the implement leg failed on a transient error"
    contains "sandbox.log confirms the implement leg's retry succeeded" \
        "$(cat "$rd_retry3/sandbox.log" 2>/dev/null)" \
        "the implement leg succeeded on retry 1"
    check "summary.json's leg_retries counts the implement leg's retry" \
        "1" "$(jq -r '.leg_retries' "$rd_retry3/summary.json" 2>/dev/null)"
    check "summary.json's harness_error is null once the retry succeeded" \
        "null" "$(jq -r '.harness_error' "$rd_retry3/summary.json" 2>/dev/null)"
else
    no "a retried implement leg's run still exits clean" "launch failed"
fi

# B3-cost. A retried implement leg's failed attempt was not free: its own
# priced attempt (auth401-cost, $0.02) must join the successful retry's own
# price ($0.01, the stub's fixed success cost) into cost_usd -- the coding
# session's own price, which the handoff's "sum leg_cost across all
# attempts" and "cost is neither lost nor double-counted" both apply to
# here just as much as to a review/fix leg. total_cost_usd must count the
# same $0.03 exactly once, since a lone implement leg run has no other leg
# to add.
prep_stub $'auth401-cost\ncommit'
if rd_retry3c="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox-test-retry-impl-cost-$$")"; then
    tmpdirs+=("$rd_retry3c")
    check "the retried implement leg's cost_usd includes the archived attempt" \
        "0.030000" "$(jq -r '.cost_usd' "$rd_retry3c/summary.json" 2>/dev/null)"
    check "total_cost_usd counts the archived attempt exactly once" \
        "0.030000" "$(jq -r '.total_cost_usd' "$rd_retry3c/summary.json" 2>/dev/null)"
else
    no "the retried implement leg's cost_usd includes the archived attempt" \
        "launch failed"
fi

# B3-cost-unknown. One archived attempt priced (auth401-cost, $0.02) and the
# NEXT one (auth401, still retryable but reports no total_cost_usd -- a real
# revoked-token failure that never got billed) is not: a sum across
# attempts is only honest when every attempt priced, so cost_usd and
# total_cost_usd must both come out null, not the $0.03 a walk that silently
# skips the unpriced attempt would report.
prep_stub $'auth401-cost\nauth401\ncommit'
if rd_retry3u="$(run_stubbed --harness claude --model haiku \
    --branch "sandbox-test-retry-impl-cost-unknown-$$")"; then
    tmpdirs+=("$rd_retry3u")
    check "an unpriced archived attempt makes cost_usd null, not a partial sum" \
        "null" "$(jq -r '.cost_usd' "$rd_retry3u/summary.json" 2>/dev/null)"
    check "an unpriced archived attempt makes total_cost_usd null too" \
        "null" "$(jq -r '.total_cost_usd' "$rd_retry3u/summary.json" 2>/dev/null)"
else
    no "an unpriced archived attempt makes cost_usd null, not a partial sum" \
        "launch failed"
fi

# B3b. When the implement leg was launched with --session-state and
# --resume-session, a retry must not replay --resume-session: resuming the
# very session that just failed on a transient error would reload its
# broken state instead of restarting fresh, exactly the hazard
# impl_sandbox_cmd/cont_sandbox_cmd's own comment (above, near
# fs_build_sandbox_cmd) already documents for a --refresh-at continuation.
rd_retry3b_state="$(mktemp -d /var/tmp/claude-scratch/fs-preset-session-state.XXXXXX)"
tmpdirs+=("$rd_retry3b_state")
prep_stub $'auth401\ncommit'
if rd_retry3b="$(run_stubbed --harness claude --model haiku \
    --session-state "$rd_retry3b_state" --resume-session deadbeef01 \
    --branch "sandbox-test-retry-impl-resume-$$")"; then
    tmpdirs+=("$rd_retry3b")
    check "a retried implement leg's run with --resume-session still exits clean" \
        "0" "$(cat "$rd_retry3b/exit-code" 2>/dev/null)"
    contains "the implement leg's first attempt resumes the caller's session" \
        "$(sed -n 1p "$argv_log")" "--resume-session deadbeef01"
    lacks "the implement leg's retry does not replay --resume-session" \
        "$(sed -n 2p "$argv_log")" "--resume-session"
else
    no "a retried implement leg's run with --resume-session still exits clean" \
        "launch failed"
fi

# B4. A leg that keeps failing on the same transient error exhausts exactly
# its configured retries (2, from this suite's FS_LEG_RETRY_DELAYS="0 0")
# and only then ends the loop as harness-error, saying so.
prep_stub $'commit\nauth401\nauth401\nauth401'
if rd_retry4="$(run_stubbed --preset reviewloop --review-loop 1 \
    --branch "sandbox-test-retry-exhaust-$$")"; then
    tmpdirs+=("$rd_retry4")
    check "a persistently-failing leg ends the loop as harness-error" \
        "harness-error" "$(jq -r '.ended' "$rd_retry4/review-loop.json" 2>/dev/null)"
    check "it made exactly 2 retries" \
        "2" "$(jq -r '.iterations[0].retries | length' "$rd_retry4/review-loop.json" 2>/dev/null)"
    contains "its detail says it failed after 2 retries" \
        "$(jq -r '.detail' "$rd_retry4/review-loop.json" 2>/dev/null)" \
        "failed after 2 retries"
    contains "sandbox.log says the leg failed after its retries" \
        "$(cat "$rd_retry4/sandbox.log" 2>/dev/null)" \
        "failed after 2 retries"
    check "summary.json's leg_retries counts both exhausted retries" \
        "2" "$(jq -r '.leg_retries' "$rd_retry4/summary.json" 2>/dev/null)"
    # A review-loop harness-error never touches the run's own exit code (see
    # the composed-2code test's own comment on this, above).
    check "the run's own exit code is untouched by the review loop's harness-error" \
        "0" "$(cat "$rd_retry4/exit-code" 2>/dev/null)"
else
    no "a persistently-failing leg ends the loop as harness-error" "launch failed"
fi

# B5. A leg that fails on its own merits -- no provider error at all, or one
# whose code (429, 400) this backstop deliberately excludes -- is never
# retried: exactly one call is made, and sandbox.log has no retry line.
for na_action in fail-plain limit429 badreq400; do
    prep_stub "$na_action"
    if rd_na="$(run_stubbed_expect_fail --harness claude --model haiku \
        --branch "sandbox-test-noretry-$na_action-$$")"; then
        rd_na_dir="${rd_na%%$'\t'*}"
        tmpdirs+=("$rd_na_dir")
        check "a $na_action failure makes exactly one attempt" \
            "1" "$(cat "$count" 2>/dev/null)"
        lacks "a $na_action failure logs no retry" \
            "$(cat "$rd_na_dir/sandbox.log" 2>/dev/null)" "retry"
    else
        no "a $na_action failure makes exactly one attempt" "launch produced no run dir"
    fi
done

# B6. codex has its own retry behavior (a one-shot fresh-resume retry, kept
# untouched above) -- a 401-shaped provider error must never also trigger
# THIS backstop for it.
prep_stub 'auth401'
if rd_codex401="$(run_stubbed_expect_fail --harness codex/gpt-5.6-sol \
    --branch "sandbox-test-codex401-$$")"; then
    rd_codex401_dir="${rd_codex401%%$'\t'*}"
    tmpdirs+=("$rd_codex401_dir")
    check "a codex leg with a 401-shaped error makes exactly one attempt" \
        "1" "$(cat "$count" 2>/dev/null)"
    lacks "a codex leg with a 401-shaped error logs no retry" \
        "$(cat "$rd_codex401_dir/sandbox.log" 2>/dev/null)" "retry"
else
    no "a codex leg with a 401-shaped error makes exactly one attempt" \
        "launch produced no run dir"
fi

# B7. A stop requested while a retry is backing off ends the leg on the
# attempt already made -- no further attempt starts. Needs a real (if
# short) delay to have a window to signal into, so this bypasses
# run_stubbed's fixed "0 0" and launches directly, in the background, the
# same way tests/fork-sandbox-stop-test.sh signals a real runner.
prep_stub 'auth401'
stop_out="$(mktemp)"; tmpdirs+=("$stop_out")
HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
    FAKE_ARGV_LOG="$argv_log" FAKE_SCRIPT="$script_file" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    FS_LEG_RETRY_DELAYS="3 3" \
    "$launcher" --foreground --harness claude --model haiku \
    --branch "sandbox-test-retrystop-$$" "$proj" "$handoff" \
    > "$stop_out" 2>&1 &
retrystop_pid=$!
rd_retrystop=""
for _ in $(seq 1 100); do
    rd_retrystop="$(sed -n 's/^  run dir:  *//p' "$stop_out" 2>/dev/null | head -1)"
    [[ -n "$rd_retrystop" ]] && break
    sleep 0.1
done
if [[ -n "$rd_retrystop" ]]; then
    tmpdirs+=("$rd_retrystop")
    retry_seen=0
    for _ in $(seq 1 100); do
        grep -q 'retry 1/2 in 3s' "$rd_retrystop/sandbox.log" 2>/dev/null \
            && { retry_seen=1; break; }
        sleep 0.1
    done
    if (( retry_seen )); then
        kill -TERM "$retrystop_pid" 2>/dev/null
        wait "$retrystop_pid" 2>/dev/null
        rc_seen=0
        for _ in $(seq 1 100); do
            [[ -f "$rd_retrystop/exit-code" ]] && { rc_seen=1; break; }
            sleep 0.1
        done
        if (( rc_seen )); then
            check "a stop during the retry backoff makes no further attempt" \
                "1" "$(cat "$count" 2>/dev/null)"
            lacks "a stop during the retry backoff never logs a successful retry" \
                "$(cat "$rd_retrystop/sandbox.log" 2>/dev/null)" "succeeded on retry"
            contains "a stop during the retry backoff logs the cancelled retry" \
                "$(cat "$rd_retrystop/sandbox.log" 2>/dev/null)" \
                "the implement leg: stop requested during the retry backoff; retry 1/2 cancelled"
        else
            no "a stop during the retry backoff makes no further attempt" \
                "no exit-code ever appeared"
        fi
    else
        no "a stop during the retry backoff makes no further attempt" \
            "no retry-announcement line ever appeared: $(cat "$rd_retrystop/sandbox.log" 2>/dev/null)"
    fi
else
    no "a stop during the retry backoff makes no further attempt" \
        "no run dir ever appeared: $(cat "$stop_out")"
fi

printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# Own-run-ids shape, not a before/after snapshot diff: a snapshot diff would
# also catch a concurrent real run or another suite's fixtures archiving
# during this suite's own window, which is not this suite's leak to report.
# Every run dir this suite creates is already in tmpdirs (appended right
# after each launcher call), so that is the complete own-run-ids list; a
# leaked fixture archive is always named "<run-dir-basename>.md".
leaked=""
for d in "${tmpdirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    cand="$operator_archive_dir/$(basename -- "$d").md"
    [[ -f "$cand" ]] && leaked+="$cand "
done
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$leaked"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
