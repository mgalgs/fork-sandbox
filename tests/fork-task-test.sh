#!/usr/bin/env bash
# fork-task-test.sh — Exercise fork-task.sh's --sol shorthand, which reads
# its model id from aliases.conf rather than a hardcoded slug.
#
# Usage: tests/fork-task-test.sh
#
# fork-task.sh launches a real tmux window/pane once its flags and paths
# validate, so this suite stays scoped to what happens before that: --sol's
# aliases.conf lookup runs during flag parsing, before project-path or
# handoff-file are even checked, so a refusal or a successful resolution
# both surface without needing a tmux server or a real project.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-task.sh"

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

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
mkdir -p "$FORK_SANDBOX_CONFIG_DIR"

printf '== fork-task.sh --sol: reads its model from aliases.conf ==\n'

err="$tmp/err"
if "$launcher" --sol /no/such/project /no/such/handoff > /dev/null 2>"$err"; then
    no "--sol without a codex sol line is refused"
else
    case "$(cat "$err")" in
        *"aliases.conf"*"codex sol"*)
            ok "--sol without a codex sol line names the file and the line to add" ;;
        *) no "--sol without a codex sol line names the file and the line to add" \
            "$(cat "$err")" ;;
    esac
fi

cat > "$FORK_SANDBOX_CONFIG_DIR/aliases.conf" <<'ALIASES'
# harness  alias  model-id
codex sol gpt-6-sol
ALIASES

# With the line present, --sol resolves during flag parsing and the run
# proceeds to the next validation step (the project path) instead of
# refusing on --sol itself -- the one observable difference that does not
# require a real tmux server.
out="$("$launcher" --sol /no/such/project /no/such/handoff 2>&1)"
case "$out" in
    *"project path '/no/such/project' is not a directory"*)
        ok "--sol with a codex sol line resolves and falls through to the next check" ;;
    *"aliases.conf"*)
        no "--sol with a codex sol line resolves and falls through to the next check" \
            "still refused on --sol: $out" ;;
    *) no "--sol with a codex sol line resolves and falls through to the next check" "$out" ;;
esac

# A codex sol line for a DIFFERENT harness must not satisfy --sol -- the
# lookup is harness-scoped, exactly like resolve_model's own aliases.conf
# lookup in fork-sandbox.sh.
cat > "$FORK_SANDBOX_CONFIG_DIR/aliases.conf" <<'ALIASES'
pi sol provider/pi-sol
ALIASES
if "$launcher" --sol /no/such/project /no/such/handoff > /dev/null 2>"$err"; then
    no "a codex sol line is required, not just any harness's sol line"
else
    case "$(cat "$err")" in
        *"aliases.conf"*"codex sol"*)
            ok "a codex sol line is required, not just any harness's sol line" ;;
        *) no "a codex sol line is required, not just any harness's sol line" \
            "$(cat "$err")" ;;
    esac
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
