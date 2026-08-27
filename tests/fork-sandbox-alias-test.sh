#!/usr/bin/env bash
# fork-sandbox-alias-test.sh — Exercise early harness/model resolution
#
# Usage: tests/fork-sandbox-alias-test.sh

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

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export CODEX_HOME="$tmp/codex"
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
mkdir -p "$CODEX_HOME" "$FORK_SANDBOX_CONFIG_DIR"
cat > "$CODEX_HOME/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list"},
           {"slug":"gpt-5.6-terra","visibility":"list"},
           {"slug":"gpt-5.4","visibility":"list"},
           {"slug":"gpt-5.4-mini","visibility":"list"},
           {"slug":"internal-thing","visibility":"hide"}]}
JSON

run() {
    "$launcher" --dry-run "$@" unused-project unused-handoff
}

printf '== fork-sandbox harness/model resolution ==\n'

out="$(run --harness codex/sol 2>/dev/null)"
check "combined codex alias resolves" $'harness=codex\nmodel=gpt-5.6-sol' "$out"

out="$(run --harness pi/moonshotai/kimi-k3 2>/dev/null)"
check "combined pi id splits only its first slash" \
    $'harness=pi\nmodel=moonshotai/kimi-k3' "$out"

out="$(run --harness codex 2>/dev/null)"
check "harness alone leaves model empty" $'harness=codex\nmodel=' "$out"

out="$(run --harness codex --model sol 2>/dev/null)"
check "separate model alias resolves" $'harness=codex\nmodel=gpt-5.6-sol' "$out"

err="$tmp/err"
out="$(run --harness codex --model gpt-5.6-sol 2>"$err")"
check "exact slug passes through" $'harness=codex\nmodel=gpt-5.6-sol' "$out"
check "exact slug reports no rewrite" "" "$(cat "$err")"

out="$(run --harness codex/5.4 2>/dev/null)"
check "suffix match wins over substring match" $'harness=codex\nmodel=gpt-5.4' "$out"

if run --harness codex/5.6 > /dev/null 2>"$err"; then
    no "ambiguous model is refused"
else
    case "$(cat "$err")" in
        *gpt-5.6-sol*gpt-5.6-terra*) ok "ambiguity lists its candidates" ;;
        *) no "ambiguity lists its candidates" "$(cat "$err")" ;;
    esac
fi

if run --harness codex/thing > /dev/null 2>"$err"; then
    no "hidden slug is excluded from partial matching"
else
    ok "hidden slug is excluded from partial matching"
fi
out="$(run --harness codex/internal-thing 2>/dev/null)"
check "hidden slug is accepted when exact" \
    $'harness=codex\nmodel=internal-thing' "$out"

before="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
    -type d -name 'claude-fork-sandbox.*' | sort)"
if run --harness codex/sob > /dev/null 2>"$err"; then
    no "unknown codex model is refused"
else
    after="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
        -type d -name 'claude-fork-sandbox.*' | sort)"
    check "unknown model creates no run directory" "$before" "$after"
    case "$(cat "$err")" in
        *"no model matching 'sob'"*gpt-5.6-sol*gpt-5.4-mini*)
            ok "unknown model names known models" ;;
        *) no "unknown model names known models" "$(cat "$err")" ;;
    esac
fi

out="$(run --harness codex --model sob --model-unchecked 2>"$err")"
check "unchecked unknown model passes" $'harness=codex\nmodel=sob' "$out"
case "$(cat "$err")" in
    *"resolution and"*"validation were skipped"*) ok "unchecked mode warns" ;;
    *) no "unchecked mode warns" "$(cat "$err")" ;;
esac
if run --harness codex --model-unchecked > /dev/null 2>"$err"; then
    no "unchecked mode without model is refused"
else
    ok "unchecked mode without model is refused"
fi

out="$(run --harness codex/sob --model-unchecked 2>"$err")"
check "unchecked mode accepts the combined harness/model form" \
    $'harness=codex\nmodel=sob' "$out"

cat > "$FORK_SANDBOX_CONFIG_DIR/aliases.conf" <<'ALIASES'
# harness  alias  model-id
codex custom account-specific-model
pi sol provider/pi-sol
ALIASES
out="$(HOME="$tmp" run --harness codex/custom 2>"$err")"
check "user alias beats discovery" \
    $'harness=codex\nmodel=account-specific-model' "$out"
case "$(cat "$err")" in
    *aliases.conf*) ok "alias rewrite names its source" ;;
    *) no "alias rewrite names its source" "$(cat "$err")" ;;
esac
err_content="$(cat "$err")"
if [[ "$err_content" == *'~/'* && "$err_content" != *"$tmp"* ]]; then
    ok "alias source under \$HOME renders as ~/, not the raw path"
else
    no "alias source under \$HOME renders as ~/, not the raw path" "$err_content"
fi
out="$(run --harness pi/custom 2>/dev/null)"
check "alias for another harness does not match" $'harness=pi\nmodel=custom' "$out"

if run --harness codex/sol --model gpt-5.4 > /dev/null 2>"$err"; then
    no "combined and separate models conflict"
else
    case "$(cat "$err")" in
        *sol*gpt-5.4*"Drop one"*) ok "model conflict names both values" ;;
        *) no "model conflict names both values" "$(cat "$err")" ;;
    esac
fi

if run --harness mystery/sol > /dev/null 2>"$err"; then
    no "unknown combined harness is refused"
else
    case "$(cat "$err")" in
        *"not 'mystery'."*) ok "unknown harness error quotes only harness half" ;;
        *) no "unknown harness error quotes only harness half" "$(cat "$err")" ;;
    esac
fi

out="$(run --harness claude/fable 2>/dev/null)"
check "claude model passes through" $'harness=claude\nmodel=fable' "$out"
out="$(run --harness pi/vendor/model 2>/dev/null)"
check "pi model passes through" $'harness=pi\nmodel=vendor/model' "$out"
if run --harness pi > /dev/null 2>"$err"; then
    no "dry-run validates pi's required model"
else
    ok "dry-run validates pi's required model"
fi

printf '\n== --review-model resolution (same path as --model) ==\n'

out="$(run --harness codex --review-model sol 2>/dev/null)"
check "review-model alias resolves" \
    $'harness=codex\nmodel=\nreview_model=gpt-5.6-sol' "$out"

out="$(HOME="$tmp" run --harness codex --review-model custom 2>/dev/null)"
check "review-model user alias beats discovery" \
    $'harness=codex\nmodel=\nreview_model=account-specific-model' "$out"

if run --harness codex --review-model sob > /dev/null 2>"$err"; then
    no "unknown review-model is refused"
else
    case "$(cat "$err")" in
        *"no model matching 'sob'"*gpt-5.6-sol*gpt-5.4-mini*)
            ok "unknown review-model names known models" ;;
        *) no "unknown review-model names known models" "$(cat "$err")" ;;
    esac
fi

out="$(run --harness codex --model sob --review-model sob2 --model-unchecked 2>"$err")"
check "unchecked mode sends both model and review-model verbatim" \
    $'harness=codex\nmodel=sob\nreview_model=sob2' "$out"
case "$(cat "$err")" in
    *"model 'sob'"*"were skipped"*"model 'sob2'"*"were skipped"*)
        ok "unchecked mode warns for both model and review-model" ;;
    *) no "unchecked mode warns for both model and review-model" "$(cat "$err")" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
