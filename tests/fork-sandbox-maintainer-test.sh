#!/usr/bin/env bash
# fork-sandbox-maintainer-test.sh — Exercise the maintainer tier:
# --maintainer-loop with its --maintainer-harness and --maintainer-model,
# the parsing and validation rules, the pi-local seal warning, and the loop's
# own execution and records once past --dry-run.
#
# Usage: tests/fork-sandbox-maintainer-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

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
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
mkdir -p "$FORK_SANDBOX_CONFIG_DIR"

# --dry-run resolves and validates the flags, then exits before the clone --
# exactly what every parsing/validation check needs, and none of it needs a
# real project or handoff.
dry() {
    "$launcher" --dry-run "$@" unused-project unused-handoff
}

printf '== --maintainer-loop: parsing and validation (--dry-run) ==\n'

err="$(mktemp)"; tmpdirs+=("$err")

# 1. --maintainer-loop's model has no default: without a named model the
# combination is refused, with a message that says so.
if dry --harness claude --maintainer-loop 2 >/dev/null 2>"$err"; then
    no "--maintainer-loop without a model is refused"
else
    contains "--maintainer-loop without a model is refused" \
        "no default" "$(cat "$err")"
fi

# 2. --maintainer-model requires --maintainer-loop, same as --review-model.
if dry --harness claude --maintainer-model sonnet >/dev/null 2>"$err"; then
    no "--maintainer-model without --maintainer-loop is refused"
else
    contains "--maintainer-model without --maintainer-loop is refused" \
        "requires" "$(cat "$err")"
fi

# 3. --maintainer-harness requires --maintainer-loop, same as --review-harness.
if dry --harness claude --maintainer-harness claude >/dev/null 2>"$err"; then
    no "--maintainer-harness without --maintainer-loop is refused"
else
    contains "--maintainer-harness without --maintainer-loop is refused" \
        "requires" "$(cat "$err")"
fi

# 4. N must be a positive integer.
for bad in 0 -1 abc 1.5; do
    if dry --harness claude --maintainer-loop "$bad" --maintainer-model sonnet \
        >/dev/null 2>"$err"; then
        no "--maintainer-loop $bad is refused"
    else
        contains "--maintainer-loop $bad is refused" "positive integer" \
            "$(cat "$err")"
    fi
done

# 5. An invalid harness name is refused the same way --harness refuses one.
if dry --harness claude --maintainer-loop 2 --maintainer-model sonnet \
    --maintainer-harness bogus >/dev/null 2>"$err"; then
    no "an invalid --maintainer-harness name is refused"
else
    contains "an invalid --maintainer-harness name is refused" \
        "not 'bogus'" "$(cat "$err")"
fi

# 6. The combined harness/model form preserves a slash-bearing OpenRouter
# id whole, exactly as --harness and --review-harness do, and conflicts
# with --maintainer-model.
out="$(dry --harness claude --maintainer-loop 2 \
    --maintainer-harness pi/moonshotai/kimi-k3 2>/dev/null \
    | grep -E '^maintainer_model=|^maintainer_harness=|^maintainer_loop=')"
check "combined maintainer-harness model preserves the full id" \
    $'maintainer_loop=2\nmaintainer_model=moonshotai/kimi-k3\nmaintainer_harness=pi' \
    "$out"

if dry --harness claude --maintainer-loop 2 \
    --maintainer-harness pi/moonshotai/kimi-k3 --maintainer-model something-else \
    >/dev/null 2>"$err"; then
    no "combined maintainer-harness model conflicts with --maintainer-model"
else
    contains "combined maintainer-harness model conflicts with --maintainer-model" \
        "conflicts with --maintainer-model" "$(cat "$err")"
fi

# 7. --maintainer-harness pi without a model anywhere is refused: the model
# is required, and pi has no default of its own either.
if dry --harness claude --maintainer-loop 2 --maintainer-harness pi \
    >/dev/null 2>"$err"; then
    no "--maintainer-harness pi without a model is refused"
else
    contains "--maintainer-harness pi without a model is refused" \
        "needs a model" "$(cat "$err")"
fi

# 8. --dry-run reports the maintainer tier once it is resolved, and only
# then: harness is printed only when explicitly given (otherwise it
# defaults to the implement harness), the model always, the cap always.
out="$(dry --harness claude --model sonnet --maintainer-loop 2 \
    --maintainer-model fable 2>/dev/null \
    | grep -E '^harness=|^model=|^maintainer_loop=|^maintainer_model=|^maintainer_harness=')"
check "--dry-run shows the maintainer tier resolved (default harness)" \
    $'harness=claude\nmodel=sonnet\nmaintainer_loop=2\nmaintainer_model=fable' \
    "$out"

out="$(dry --harness claude --model sonnet --maintainer-loop 2 \
    --maintainer-harness pi --maintainer-model moonshotai/kimi-k3 2>/dev/null \
    | grep -E '^maintainer_')"
check "--dry-run shows an explicit maintainer harness" \
    $'maintainer_loop=2\nmaintainer_model=moonshotai/kimi-k3\nmaintainer_harness=pi' \
    "$out"

# 9. A plain run -- and even a --review-loop run -- has no maintainer lines.
out="$(dry --harness claude --model sonnet 2>/dev/null)"
if [[ "$out" != *"maintainer"* ]]; then
    ok "a plain dry-run has no maintainer fields"
else
    no "a plain dry-run has no maintainer fields" "$out"
fi
out="$(dry --harness claude --model sonnet --review-loop 2 --review-model fable 2>/dev/null)"
if [[ "$out" != *"maintainer"* ]]; then
    ok "a --review-loop dry-run has no maintainer fields"
else
    no "a --review-loop dry-run has no maintainer fields" "$out"
fi

# 10. The two loops compose: both caps are reported.
out="$(dry --harness claude --model sonnet --review-loop 2 \
    --review-model fable --maintainer-loop 3 --maintainer-model opus 2>/dev/null \
    | grep -E '^review_model=|^maintainer_')"
check "review loop and maintainer loop compose" \
    $'review_model=fable\nmaintainer_loop=3\nmaintainer_model=opus' "$out"

# 11. The seal: --harness pi-local (no network at all) with a networked
# --maintainer-harness is accepted, but warns by name that the maintainer
# legs send the clone's contents to that harness's model provider. The
# reverse -- a networked implement harness with a pi-local maintainer --
# adds no exposure the run did not already have, so it is accepted
# silently.
for networked in claude "pi/some-model" codex; do
    # A combined harness/model form already carries the model; a bare
    # harness name needs --maintainer-model on top.
    if [[ "$networked" == */* ]]; then
        mnt_args=(--maintainer-harness "$networked")
    else
        mnt_args=(--maintainer-harness "$networked" --maintainer-model some-other-model)
    fi
    if ! out="$(dry --harness pi-local --maintainer-loop 2 \
        "${mnt_args[@]}" 2>"$err")"; then
        no "--harness pi-local + --maintainer-harness $networked is accepted"
    else
        ok "--harness pi-local + --maintainer-harness $networked is accepted"
    fi
    contains "--harness pi-local + --maintainer-harness $networked warns of the exposure" \
        "seals the implement leg" "$(cat "$err")"
done
out="$(dry --harness claude --maintainer-loop 2 \
    --maintainer-harness pi-local --maintainer-model some-local-model 2>"$err" \
    | grep -E '^maintainer_harness=')"
check "--harness claude + --maintainer-harness pi-local is accepted" \
    "maintainer_harness=pi-local" "$out"
[[ -s "$err" ]] && no "--harness claude + --maintainer-harness pi-local prints no error" "$(cat "$err")"

# 12. --k8s refuses the maintainer tier by name, all three flags at once.
# --k8s defaults --harness to pi, which needs its own model, so give it one
# -- the refusal under test is the maintainer one, reached after that.
for flags in \
    "--maintainer-loop 2 --maintainer-model x" \
    "--maintainer-harness claude --maintainer-model x" \
    "--maintainer-model x"
do
    # shellcheck disable=SC2086  # deliberate word splitting: a flag pair
    if dry --k8s --model x $flags >/dev/null 2>"$err"; then
        no "--k8s $flags is refused"
    else
        contains "--k8s $flags is refused" \
            "not yet supported with --k8s" "$(cat "$err")"
    fi
done

printf '\n== --maintainer-loop: --review-only is refused ==\n'

# The refusals fire at flag validation, before the project or handoff is
# touched, so the unused placeholders from dry() stand in for both.
refuse_review_only() {
    local label="$1" needle="$2"
    shift 2
    if dry --review-only --checkout HEAD \
        --harness claude --model sonnet "$@" >/dev/null 2>"$err"; then
        no "--review-only refuses $label"
    else
        contains "--review-only refuses $label" "$needle" "$(cat "$err")"
    fi
}
refuse_review_only "--maintainer-loop" "not supported with --review-only" \
    --maintainer-loop 2 --maintainer-model sonnet
refuse_review_only "--maintainer-model" "not supported with --review-only" \
    --maintainer-model sonnet
refuse_review_only "--maintainer-harness" "not supported with --review-only" \
    --maintainer-harness claude --maintainer-model sonnet

# Regression: --review-only still refuses the review flags with its own,
# pre-maintainer message.
refuse_review_only "--review-loop" "one review leg" --review-loop 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
