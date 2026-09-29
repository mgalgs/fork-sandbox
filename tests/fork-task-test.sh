#!/usr/bin/env bash
# fork-task-test.sh — Exercise fork-task.sh's --sol shorthand, which reads
# its model id from aliases.conf rather than a hardcoded slug, and its
# session-lineage recording in the agent registry (session_id,
# parent_session_id, relation).
#
# Usage: tests/fork-task-test.sh
#
# fork-task.sh launches a real tmux window/pane once its flags and paths
# validate. The --sol tests stay scoped to what happens before that: --sol's
# aliases.conf lookup runs during flag parsing, before project-path or
# handoff-file are even checked, so a refusal or a successful resolution
# both surface without needing a tmux server or a real project. The
# session-lineage tests need to reach the launch itself, so they stub tmux
# (and claude/codex) on PATH and point the registry at a scratch file via
# $FORK_TASK_REGISTRY -- never a real tmux server or the real registry.

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

# --help must win over --sol's own refusal, regardless of where it falls in
# the argument list -- a user asking for usage should see it even with no
# codex sol line in aliases.conf, and even before --help is reached in the
# option loop.
if out="$("$launcher" --sol --help 2>"$err")"; then
    case "$out" in
        *"Usage: fork-task.sh"*)
            ok "--sol --help shows usage instead of refusing on the missing alias" ;;
        *) no "--sol --help shows usage instead of refusing on the missing alias" "$out" ;;
    esac
else
    no "--sol --help shows usage instead of refusing on the missing alias" \
        "$(cat "$err")"
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

printf '\n== fork-task.sh: session lineage recorded in the agent registry ==\n'

# These tests reach the tmux launch itself, unlike the --sol tests above, so
# tmux (and claude/codex, for good measure) are stubbed on PATH. The tmux
# stub never runs the assembled command -- it just logs every argument it
# was given (one per line, so the final argument, the full launch command,
# is the log's last line) and prints a fixed pane id, exactly like a real
# `tmux new-window -P -F '#{pane_id}' ...` would without actually opening
# anything.
stub_bin="$tmp/stubbin"
mkdir -p "$stub_bin"
tmux_log="$tmp/tmux.log"

cat > "$stub_bin/tmux" <<'STUB'
#!/usr/bin/env bash
: > "${TMUX_STUB_LOG:?TMUX_STUB_LOG must be set}"
for a in "$@"; do printf '%s\n' "$a" >> "$TMUX_STUB_LOG"; done
case "$1" in
    has-session) exit 1 ;;
    list-sessions) echo "  (none)" ;;
    *) echo "%99" ;;
esac
STUB
chmod +x "$stub_bin/tmux"

for stub_prog in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/$stub_prog"
    chmod +x "$stub_bin/$stub_prog"
done

export PATH="$stub_bin:$PATH"
export TMUX_STUB_LOG="$tmux_log"

lineage_project="$tmp/lineage-project"
mkdir -p "$lineage_project"
lineage_handoff="$tmp/lineage-handoff.md"
printf 'handoff\n' > "$lineage_handoff"

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# A plain claude launch: the registry's session_id is a fresh, valid UUID,
# and it is the very same UUID the stubbed launch command received via
# --session-id -- not a second, unrelated one.
reg="$tmp/registry-session-id.jsonl"
: > "$tmux_log"
if ! out="$(env -u CLAUDE_CODE_SESSION_ID FORK_TASK_REGISTRY="$reg" "$launcher" "$lineage_project" "$lineage_handoff" 2>&1)"; then
    no "a claude launch's registry line has session_id matching the launch command" "$out"
else
    reg_id="$(jq -r '.session_id' "$reg")"
    # The logged command is %q-shell-quoted, so plain spaces may appear as
    # backslash-space; strip backslashes first so a plain-space match works.
    cmd_line="$(cat "$tmux_log")"
    cmd_id="$(printf '%s\n' "${cmd_line//\\/}" | grep -oE -- '--session-id [0-9a-f-]+' | tail -n1 | awk '{print $2}')"
    if [[ "$reg_id" =~ $uuid_re ]] && [[ "$reg_id" == "$cmd_id" ]]; then
        ok "a claude launch's registry line has session_id matching the launch command"
    else
        no "a claude launch's registry line has session_id matching the launch command" \
            "registry session_id='$reg_id' launch command session_id='$cmd_id'"
    fi
fi

# parent_session_id mirrors $CLAUDE_CODE_SESSION_ID when the launcher has one...
reg="$tmp/registry-parent-set.jsonl"
CLAUDE_CODE_SESSION_ID="parent-xyz-123" FORK_TASK_REGISTRY="$reg" \
    "$launcher" "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
parent_id="$(jq -r '.parent_session_id' "$reg" 2>/dev/null)"
if [[ "$parent_id" == "parent-xyz-123" ]]; then
    ok "parent_session_id equals CLAUDE_CODE_SESSION_ID when set"
else
    no "parent_session_id equals CLAUDE_CODE_SESSION_ID when set" "got '$parent_id': $(cat "$err")"
fi

# ...and is null, not empty-string, when the launcher has none.
reg="$tmp/registry-parent-unset.jsonl"
env -u CLAUDE_CODE_SESSION_ID FORK_TASK_REGISTRY="$reg" \
    "$launcher" "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
parent_id="$(jq -r '.parent_session_id' "$reg" 2>/dev/null)"
if [[ "$parent_id" == "null" ]]; then
    ok "parent_session_id is null when CLAUDE_CODE_SESSION_ID is unset"
else
    no "parent_session_id is null when CLAUDE_CODE_SESSION_ID is unset" "got '$parent_id': $(cat "$err")"
fi

# relation defaults to delegation...
reg="$tmp/registry-relation-default.jsonl"
FORK_TASK_REGISTRY="$reg" "$launcher" "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
relation_val="$(jq -r '.relation' "$reg" 2>/dev/null)"
if [[ "$relation_val" == "delegation" ]]; then
    ok "relation defaults to delegation"
else
    no "relation defaults to delegation" "got '$relation_val': $(cat "$err")"
fi

# ...and --relation continuation records continuation.
reg="$tmp/registry-relation-continuation.jsonl"
FORK_TASK_REGISTRY="$reg" "$launcher" --relation continuation "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
relation_val="$(jq -r '.relation' "$reg" 2>/dev/null)"
if [[ "$relation_val" == "continuation" ]]; then
    ok "--relation continuation records relation: continuation"
else
    no "--relation continuation records relation: continuation" "got '$relation_val': $(cat "$err")"
fi

# --relation bogus is refused before anything launches: no tmux call, no
# registry line, and a clear error naming the allowed values.
reg="$tmp/registry-relation-bogus.jsonl"
: > "$tmux_log"
if "$launcher" --relation bogus "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"; then
    no "--relation bogus is refused, with nothing launched and no registry line"
elif [[ -s "$tmux_log" || -e "$reg" ]]; then
    no "--relation bogus is refused, with nothing launched and no registry line" \
        "tmux_log or registry file was written: $(cat "$err")"
else
    case "$(cat "$err")" in
        *"continuation or delegation"*)
            ok "--relation bogus is refused, with nothing launched and no registry line" ;;
        *) no "--relation bogus is refused, with nothing launched and no registry line" "$(cat "$err")" ;;
    esac
fi

# A codex launch has no --session-id flag to give, so it always records null.
reg="$tmp/registry-codex.jsonl"
FORK_TASK_REGISTRY="$reg" "$launcher" --harness codex "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
reg_id="$(jq -r '.session_id' "$reg" 2>/dev/null)"
if [[ "$reg_id" == "null" ]]; then
    ok "a codex launch records session_id: null"
else
    no "a codex launch records session_id: null" "got '$reg_id': $(cat "$err")"
fi

# A caller-supplied --session-id inside --claude-args is recorded as-is and
# not duplicated by a second, generated --session-id.
reg="$tmp/registry-caller-session-id.jsonl"
: > "$tmux_log"
caller_uuid="11111111-1111-1111-1111-111111111111"
FORK_TASK_REGISTRY="$reg" "$launcher" --claude-args "--session-id $caller_uuid" \
    "$lineage_project" "$lineage_handoff" > /dev/null 2>"$err"
occurrences="$(grep -o -- '--session-id' "$tmux_log" | wc -l | tr -d ' ')"
reg_id="$(jq -r '.session_id' "$reg" 2>/dev/null)"
if [[ "$occurrences" == "1" && "$reg_id" == "$caller_uuid" ]]; then
    ok "a caller-supplied --session-id in --claude-args is recorded, not duplicated"
else
    no "a caller-supplied --session-id in --claude-args is recorded, not duplicated" \
        "occurrences=$occurrences registry session_id='$reg_id': $(cat "$err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
