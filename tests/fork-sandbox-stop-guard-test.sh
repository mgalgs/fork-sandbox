#!/usr/bin/env bash
# fork-sandbox-stop-guard-test.sh — the commit-guard Stop hook's decision logic
#
# Usage: tests/fork-sandbox-stop-guard-test.sh
#
# Drives scripts/fork-sandbox-stop-guard.sh directly with fake Stop-hook JSON
# on stdin, FORK_SANDBOX_INBOX pointed at a throwaway inbox holding
# .stop-guard-config, and FORK_SANDBOX_STOP_GUARD_STATE pointed at a
# throwaway refusal counter -- the same shape of fixture
# tests/fork-sandbox-inbox-test.sh uses for fork-sandbox-inbox-hook.sh. A real
# temp git repo stands in for the clone, with GIT_CONFIG_GLOBAL/
# GIT_CONFIG_SYSTEM pointed at /dev/null so the operator's own git config
# cannot skew what `git status` reports (tests/fork-sandbox-uncommitted-test.sh
# does the same).
#
# Does NOT cover the wiring into fork-sandbox.sh/fork-sandbox-k8s-entrypoint.sh
# (which settings file gets the guard, where its config is written) -- that is
# tests/fork-sandbox-maintainer-test.sh, tests/fork-sandbox-preset-test.sh and
# tests/fork-sandbox-k8s-test.sh, against the real launchers.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
guard="$repo_dir/scripts/fork-sandbox-stop-guard.sh"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
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

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

new_repo() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

new_inbox() {
    local clone="$1" d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    [[ -n "$clone" ]] && printf 'CLONE_DIR=%s\n' "$clone" > "$d/.stop-guard-config"
    printf '%s' "$d"
}

new_state_path() {
    local f
    f="$(mktemp -u)"
    tmpdirs+=("$f")
    printf '%s' "$f"
}

run_guard() {
    # $1 payload JSON, $2 inbox, $3 state file. Prints stdout; stderr lands
    # at "$state.stderr" for the caller to read back -- NOT a global
    # variable this function sets, since every caller invokes it as
    # "out=\"\$(run_guard ...)\"", a command substitution that forks a
    # subshell: an assignment made inside it never reaches the parent shell.
    local payload="$1" inbox="$2" state="$3"
    printf '%s' "$payload" \
        | FORK_SANDBOX_INBOX="$inbox" FORK_SANDBOX_STOP_GUARD_STATE="$state" \
            "$guard" 2> "$state.stderr"
}

last_stderr() {
    # $1 state file, the same one run_guard was called with.
    cat -- "$1.stderr" 2>/dev/null
}

printf '== pin: background tasks are no longer disabled anywhere in the repo ==\n'
# R1/T1d: the env key this hook's existence replaces must be gone from every
# script, doc and README this run touches -- a leftover reference would mean
# a leg still had its background tasks turned off even though this hook now
# exists to guard the alternative.
#
# fork-sandbox-k8s-entrypoint.sh keeps setting it until the k8s wiring
# commit lands the guard on that path too (same brief, a later commit) --
# excluded here for that one commit's span and folded back into this same
# grep once it does, so the pin stays comprehensive again rather than
# permanently carving out an exception.
if grep -rl 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' \
    "$repo_dir/scripts" "$repo_dir/docs" "$repo_dir/README.md" \
    "$repo_dir/skills" 2>/dev/null \
    | grep -v '/fork-sandbox-k8s-entrypoint\.sh$' | grep -q .; then
    no "no local script, doc or skill still disables background tasks" \
        "$(grep -rl 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' \
            "$repo_dir/scripts" "$repo_dir/docs" "$repo_dir/README.md" \
            "$repo_dir/skills" 2>/dev/null \
            | grep -v '/fork-sandbox-k8s-entrypoint\.sh$')"
else
    ok "no local script, doc or skill still disables background tasks"
fi

printf '\n== R2/T2a: a dirty clone blocks, naming both paths, refusal 1 of 3 ==\n'
repo="$(new_repo)"
printf 'changed\n' >> "$repo/file.txt"
printf 'new\n' > "$repo/untracked.txt"
inbox="$(new_inbox "$repo")"
state="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox" "$state")"
decision="$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"
check "decision is block" "block" "$decision"
contains "reason names the modified tracked file" "file.txt" "$reason"
contains "reason names the untracked file" "untracked.txt" "$reason"
contains "reason says this is refusal 1 of 3" "refusal 1 of 3" "$reason"
check "the state file now reads 1" "1" "$(cat "$state" 2>/dev/null)"

printf '\n== R2/T2b: 25 untracked files are capped at 20, "N more" named ==\n'
repo25="$(new_repo)"
for i in $(seq 1 25); do printf 'x\n' > "$repo25/untracked-$i.txt"; done
inbox25="$(new_inbox "$repo25")"
state25="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox25" "$state25")"
reason="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"
shown="$(printf '%s\n' "$reason" | grep -c '^?? untracked-')"
check "exactly 20 untracked paths are listed" "20" "$shown"
contains "the reason says 5 more" "and 5 more" "$reason"

printf '\n== R3/T3: a clean clone with no background tasks is silent ==\n'
repo_clean="$(new_repo)"
inbox_clean="$(new_inbox "$repo_clean")"
state_clean="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop","background_tasks":[]}' "$inbox_clean" "$state_clean")"
check "stdout is empty" "" "$out"
if [[ -f "$state_clean" ]]; then
    no "the state file is not created on a silent allow" "it exists"
else
    ok "the state file is not created on a silent allow"
fi

printf '\n== R4: excluded/.gitignored files are not uncommitted work ==\n'
repo_excl="$(new_repo)"
mkdir -p "$repo_excl/.git/info"
printf '.env.sandbox\n' > "$repo_excl/.git/info/exclude"
printf 'SOME_URL=unix:///tmp/does-not-matter.sock\n' > "$repo_excl/.env.sandbox"
printf 'ignored/\n' > "$repo_excl/.gitignore"
(cd "$repo_excl" && git add .gitignore && git commit -q -m gitignore) >/dev/null 2>&1
mkdir -p "$repo_excl/ignored"
printf 'x\n' > "$repo_excl/ignored/y.txt"
inbox_excl="$(new_inbox "$repo_excl")"
state_excl="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_excl" "$state_excl")"
check "excluded and ignored files alone do not block" "" "$out"

printf '\n== R5/T5a: a clean clone with a running background shell still blocks ==\n'
repo_shell="$(new_repo)"
inbox_shell="$(new_inbox "$repo_shell")"
state_shell="$(new_state_path)"
payload='{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"running","id":"task-1","command":"bash tests/x.sh"}]}'
out="$(run_guard "$payload" "$inbox_shell" "$state_shell")"
reason="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"
check "decision is block" "block" "$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null)"
contains "reason names the shell's id" "task-1" "$reason"
contains "reason names the shell's command" "bash tests/x.sh" "$reason"
contains "reason says ending the turn does not wait" "Ending your turn does NOT wait" "$reason"

printf '\n== R5/T5a2: a dirty clone alone says nothing about background shells ==\n'
repo_dirty_only="$(new_repo)"
printf 'changed\n' >> "$repo_dirty_only/file.txt"
state_dirty_only="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop","background_tasks":[]}' \
    "$(new_inbox "$repo_dirty_only")" "$state_dirty_only")"
check "the dirty clone blocks" "block" "$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null)"
lacks "no shell wait advice without a running shell" "Ending your turn does NOT wait" \
    "$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"

printf '\n== R5/T5b: the same shell, completed, allows ==\n'
state_shell2="$(new_state_path)"
payload='{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"completed","id":"task-1","command":"bash tests/x.sh"}]}'
out="$(run_guard "$payload" "$inbox_shell" "$state_shell2")"
check "a completed shell does not block" "" "$out"

printf '\n== R5/T5c: a running subagent (not a shell) does not block ==\n'
state_shell3="$(new_state_path)"
payload='{"hook_event_name":"Stop","background_tasks":[{"type":"subagent","status":"running","id":"a1"}]}'
out="$(run_guard "$payload" "$inbox_shell" "$state_shell3")"
check "a running subagent does not block" "" "$out"

printf '\n== R5/T5d: no background_tasks key at all does not block ==\n'
state_shell4="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_shell" "$state_shell4")"
check "a payload with no background_tasks key does not block" "" "$out"

printf '\n== R6/T6: the refusal cap -- three blocks, then silence ==\n'
repo_cap="$(new_repo)"
printf 'changed\n' >> "$repo_cap/file.txt"
inbox_cap="$(new_inbox "$repo_cap")"
state_cap="$(new_state_path)"
for i in 1 2 3; do
    out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_cap" "$state_cap")"
    reason="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"
    contains "attempt $i: reason says refusal $i of 3" "refusal $i of 3" "$reason"
done
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_cap" "$state_cap")"
check "the fourth attempt is silent" "" "$out"
check "the state stays at 3, not incremented past the cap" "3" "$(cat "$state_cap" 2>/dev/null)"
contains "the fourth attempt's stderr announces the cap" \
    "fork-sandbox-stop-guard: cap reached" "$(last_stderr "$state_cap")"

printf '\n== R7/T7a: no config file at all allows, tagged on stderr ==\n'
inbox_noconf="$(mktemp -d)"; tmpdirs+=("$inbox_noconf")
state_noconf="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_noconf" "$state_noconf")"
check "no config: stdout is empty" "" "$out"
contains "no config: stderr says so" "no config" "$(last_stderr "$state_noconf")"

printf '\n== R7/T7b: CLONE_DIR names an empty, non-repo directory: git fails, allow ==\n'
not_a_repo="$(mktemp -d)"; tmpdirs+=("$not_a_repo")
inbox_badrepo="$(new_inbox "$not_a_repo")"
state_badrepo="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_badrepo" "$state_badrepo")"
check "a failed git status: stdout is empty" "" "$out"
contains "a failed git status: stderr says so" "git status failed" "$(last_stderr "$state_badrepo")"

printf '\n== R8/T8: a non-Stop event is always silent, even on a dirty clone ==\n'
repo_other="$(new_repo)"
printf 'changed\n' >> "$repo_other/file.txt"
inbox_other="$(new_inbox "$repo_other")"
state_other="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"PostToolUse"}' "$inbox_other" "$state_other")"
check "PostToolUse: stdout is empty" "" "$out"
if [[ -f "$state_other" ]]; then
    no "PostToolUse never touches the state file" "it exists"
else
    ok "PostToolUse never touches the state file"
fi

printf '\n== R9/T9a: a refusal always tags stderr with the documented prefix ==\n'
repo_tag="$(new_repo)"
printf 'changed\n' >> "$repo_tag/file.txt"
inbox_tag="$(new_inbox "$repo_tag")"
state_tag="$(new_state_path)"
run_guard '{"hook_event_name":"Stop"}' "$inbox_tag" "$state_tag" >/dev/null
tag_stderr="$(last_stderr "$state_tag")"
case "$tag_stderr" in
    "fork-sandbox-stop-guard: refused"*) ok "stderr starts with the documented tag" ;;
    *) no "stderr starts with the documented tag" "$tag_stderr" ;;
esac

printf '\n== R17/T17: a corrupt state file is treated as 0, not as trapped or freed ==\n'
repo_garbage="$(new_repo)"
printf 'changed\n' >> "$repo_garbage/file.txt"
inbox_garbage="$(new_inbox "$repo_garbage")"
state_garbage="$(new_state_path)"
printf 'abc' > "$state_garbage"
out="$(run_guard '{"hook_event_name":"Stop"}' "$inbox_garbage" "$state_garbage")"
reason="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)"
contains "a garbage state file is read as 0: refusal 1 of 3" "refusal 1 of 3" "$reason"
check "the state file is rewritten to 1" "1" "$(cat "$state_garbage" 2>/dev/null)"

printf '\n== R18/T18: a clean clone with a hand-off sitting in a sibling outbox allows ==\n'
repo_handoff="$(new_repo)"
sibling_outbox="$(mktemp -d)"; tmpdirs+=("$sibling_outbox")
printf '# done\n' > "$sibling_outbox/handoff.md"
inbox_handoff="$(new_inbox "$repo_handoff")"
state_handoff="$(new_state_path)"
out="$(run_guard '{"hook_event_name":"Stop","background_tasks":[]}' "$inbox_handoff" "$state_handoff")"
check "a clean clone with an out-of-clone hand-off allows" "" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
