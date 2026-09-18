#!/usr/bin/env bash
# fork-sandbox-claude-credentials-test.sh -- --claude-credentials and
# CLAUDE_CREDENTIALS on fork-sandbox.sh itself: the precedence rule
# (--claude-credentials beats claude.env beats the default), the --k8s
# refusal, and forwarding into every claude leg's sandbox_cmd.
#
# fork-sandbox-lib.sh's own override plumbing is covered by
# fork-sandbox-toolchain-test.sh, the client end by
# claude-sandboxed-credentials-test.sh, and the cluster entry point by
# fork-sandbox-k8s-test.sh -- this file is the fourth surface: fork-sandbox.sh
# resolving the override and threading it into the local sandbox_cmd(s) it
# builds.
#
# Usage: tests/fork-sandbox-claude-credentials-test.sh

# shellcheck disable=SC2016  # literal shell snippets handed to fake_hook are intentional
set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work -- see
# fork-sandbox-review-harness-test.sh's identical export for why.
export FORK_SANDBOX_RUN_SOURCE=test

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

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
mkdir -p "$FORK_SANDBOX_CONFIG_DIR"

# --dry-run resolves and validates flags, including the --k8s refusals,
# before it clones anything -- exactly what the refusal check below needs,
# and none of it needs a real project or handoff.
dry() {
    "$launcher" --dry-run "$@" unused-project unused-handoff
}

printf '== --k8s forwards --claude-credentials instead of refusing it ==\n'
# The refusal this section used to assert was lifted: fork-sandbox.sh --k8s
# now resolves --claude-credentials itself (same precedence chain as the
# local path) and forwards the result into fork-sandbox-k8s.sh run's own
# --claude-credentials, rather than pointing the operator at CLAUDE_CREDENTIALS
# as the only escape hatch. Full precedence and hook-contract coverage lives
# in fork-sandbox-balance-test.sh (the lib) and fork-sandbox-k8s-test.sh (the
# fork-sandbox-k8s.sh cmd_submit call site); this file only needs to confirm
# fork-sandbox.sh's own --k8s dispatch resolves and forwards, one
# representative case each for the happy path and the missing-file refusal.

k8s_cred_valid="$(mktemp)"; tmpdirs+=("$k8s_cred_valid")
printf '{"claudeAiOauth":{"accessToken":"k8s-flag-tok"}}\n' > "$k8s_cred_valid"

err="$(mktemp)"; tmpdirs+=("$err")
if dry --k8s --harness claude --model sonnet \
    --claude-credentials "$k8s_cred_valid" \
    >/dev/null 2>"$err"; then
    no "--k8s --claude-credentials naming an existing file is no longer refused" \
        "$(cat "$err")"
else
    lacks "--k8s --claude-credentials naming an existing file is no longer refused" \
        "not supported with --k8s" "$(cat "$err")"
fi

k8s_cred_missing="/tmp/fs-claude-credentials-test-unused.json"
err2="$(mktemp)"; tmpdirs+=("$err2")
if dry --k8s --harness claude --model sonnet \
    --claude-credentials "$k8s_cred_missing" \
    >/dev/null 2>"$err2"; then
    no "--k8s --claude-credentials naming a missing file is refused"
else
    contains "--k8s --claude-credentials naming a missing file is refused" \
        "--claude-credentials names '$k8s_cred_missing'" "$(cat "$err2")"
fi
lacks "the missing-file refusal is fork-sandbox.sh's own message, not the old --k8s refusal" \
    "not supported with --k8s" "$(cat "$err2")"

printf '\n== --claude-credentials precedence, forwarded into sandbox_cmd ==\n'

# claude-sandboxed and agent-sandboxed are stubbed exactly as
# fork-sandbox-review-harness-test.sh's own real-run section stubs them:
# fork-sandbox.sh only needs them to exit 0 after consuming stdin, since
# what is under test is the argv fork-sandbox.sh BUILDS, not what a real
# claude CLI does with it. sandbox-backend-fake-image steers harness
# resolution past needing a real pi/codex install, for the same reason
# fork-sandbox-review-harness-test.sh's real-run section fakes it.
real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-claude-credentials-real-stub.XXXXXX)"
tmpdirs+=("$real_stub")
cat > "$real_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
cat > "$real_stub/agent-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
cat > "$real_stub/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
chmod +x "$real_stub"/*

new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-claude-credentials-test.XXXXXX")"
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

mkdir -p "$HOME/src"
proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-claude-credentials-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

env_cred="$tmp/env-credentials.json"
printf '{"claudeAiOauth":{"accessToken":"env-tok"}}\n' > "$env_cred"
flag_cred="$tmp/flag-credentials.json"
printf '{"claudeAiOauth":{"accessToken":"flag-tok"}}\n' > "$flag_cred"

# Runs fork-sandbox.sh for real, foreground, with every wrapper stubbed and
# the backend faked into image mode -- the same run_real pattern
# fork-sandbox-review-harness-test.sh uses, parameterized on config dir
# since precedence is exactly what varies between calls here.
run_real() {
    local cfg="$1"; shift
    local out rc rd
    out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FORK_SANDBOX_BACKEND=fake-image \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$rd" ]]; then
        printf 'run_real failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

# Neither claude.env nor --claude-credentials: the default account, nothing
# forwarded.
none_cfg="$(mktemp -d)"; tmpdirs+=("$none_cfg")
rd_none="$(run_real "$none_cfg" --harness claude)"
if [[ -n "$rd_none" ]]; then
    tmpdirs+=("$rd_none")
    lacks "no override: sandbox_cmd carries no --claude-credentials" \
        "--claude-credentials" "$(grep '^sandbox_cmd=' "$rd_none/run.sh")"
else
    no "no override: run_real produced a run directory" "run_real failed"
fi

# CLAUDE_CREDENTIALS in claude.env alone: forwarded.
env_cfg="$(mktemp -d)"; tmpdirs+=("$env_cfg")
printf 'CLAUDE_CREDENTIALS=%s\n' "$env_cred" > "$env_cfg/claude.env"
rd_env="$(run_real "$env_cfg" --harness claude)"
if [[ -n "$rd_env" ]]; then
    tmpdirs+=("$rd_env")
    contains "claude.env alone: sandbox_cmd carries its CLAUDE_CREDENTIALS path" \
        "--claude-credentials $env_cred" "$(grep '^sandbox_cmd=' "$rd_env/run.sh")"
else
    no "claude.env alone: run_real produced a run directory" "run_real failed"
fi

# --claude-credentials alone: forwarded.
flag_cfg="$(mktemp -d)"; tmpdirs+=("$flag_cfg")
rd_flag="$(run_real "$flag_cfg" --harness claude --claude-credentials "$flag_cred")"
if [[ -n "$rd_flag" ]]; then
    tmpdirs+=("$rd_flag")
    contains "--claude-credentials alone: sandbox_cmd carries the flag's path" \
        "--claude-credentials $flag_cred" "$(grep '^sandbox_cmd=' "$rd_flag/run.sh")"
else
    no "--claude-credentials alone: run_real produced a run directory" "run_real failed"
fi

# Both set: the flag wins, and claude.env's path does not leak in alongside it.
both_cfg="$(mktemp -d)"; tmpdirs+=("$both_cfg")
printf 'CLAUDE_CREDENTIALS=%s\n' "$env_cred" > "$both_cfg/claude.env"
rd_both="$(run_real "$both_cfg" --harness claude --claude-credentials "$flag_cred")"
if [[ -n "$rd_both" ]]; then
    tmpdirs+=("$rd_both")
    sandbox_line_both="$(grep '^sandbox_cmd=' "$rd_both/run.sh")"
    contains "both set: sandbox_cmd carries the flag's path" \
        "--claude-credentials $flag_cred" "$sandbox_line_both"
    lacks "both set: sandbox_cmd does not carry claude.env's path" \
        "$env_cred" "$sandbox_line_both"
else
    no "both set: run_real produced a run directory" "run_real failed"
fi

# Forwarded into EVERY claude leg, not just implement: a claude review leg
# gets it too, proving the resolve-once/thread-everywhere design the code
# comment above claude_credentials_resolved describes.
review_cfg="$(mktemp -d)"; tmpdirs+=("$review_cfg")
printf 'CLAUDE_CREDENTIALS=%s\n' "$env_cred" > "$review_cfg/claude.env"
rd_review="$(run_real "$review_cfg" --harness claude --review-loop 1 --review-harness claude)"
if [[ -n "$rd_review" ]]; then
    tmpdirs+=("$rd_review")
    contains "review leg: implement sandbox_cmd carries the override" \
        "--claude-credentials $env_cred" "$(grep '^sandbox_cmd=' "$rd_review/run.sh")"
    contains "review leg: review_sandbox_cmd carries the override too" \
        "--claude-credentials $env_cred" "$(grep '^review_sandbox_cmd=' "$rd_review/run.sh")"
else
    no "review leg: run_real produced a run directory" "run_real failed"
fi

printf '\n== --claude-credentials/CLAUDE_CREDENTIALS resolved to an absolute\n   path, checked to exist, before anything is created ==\n'

# A nonexistent path fails at launch with a clear error -- not deep inside
# fs_read_claude_credential after the clone, the branch and (in a detached
# run) the tmux session already exist.
missing_cfg="$(mktemp -d)"; tmpdirs+=("$missing_cfg")
missing_path="$tmp/does-not-exist-credentials.json"
missing_out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$missing_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --claude-credentials "$missing_path" "$proj" "$handoff" 2>&1)"
missing_rc=$?
if (( missing_rc == 0 )); then
    no "missing path: fork-sandbox.sh exited 0" "$missing_out"
else
    ok "missing path: fork-sandbox.sh refuses to launch"
fi
contains "missing path: the error names the path" "$missing_path" "$missing_out"
lacks "missing path: no run directory was created" "run dir:" "$missing_out"

# A path relative to the launcher's own cwd resolves to the same absolute
# file a detached run's tmux -c "$origin_repo" and a --foreground exec from
# the operator's own shell would otherwise disagree about.
rel_cfg="$(mktemp -d)"; tmpdirs+=("$rel_cfg")
rel_out="$(cd "$tmp" && PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$rel_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --claude-credentials flag-credentials.json "$proj" "$handoff" 2>&1)"
rel_rd="$(printf '%s\n' "$rel_out" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rel_rd" ]]; then
    tmpdirs+=("$rel_rd")
    contains "relative path: sandbox_cmd carries the resolved absolute path" \
        "--claude-credentials $flag_cred" "$(grep '^sandbox_cmd=' "$rel_rd/run.sh")"
else
    no "relative path: run_real produced a run directory" "$rel_out"
fi

printf '\n== the existence check on CLAUDE_CREDENTIALS is gated on this run\n   actually using claude; an explicit --claude-credentials is not ==\n'

# A --harness pi run never reads a Claude credential, so CLAUDE_CREDENTIALS
# in claude.env -- a machine-wide default this run never asked for by name
# -- naming a path that has since moved must not abort it. Only a claude
# leg (implement, review, maintainer, or either fix seat) makes the path
# relevant enough to check for existence.
pi_cfg="$(mktemp -d)"; tmpdirs+=("$pi_cfg")
install -m 600 /dev/null "$pi_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_cfg/pi.env"
printf 'CLAUDE_CREDENTIALS=%s\n' "$missing_path" > "$pi_cfg/claude.env"
pi_rd="$(run_real "$pi_cfg" --harness pi --model moonshotai/kimi-k3)"
if [[ -n "$pi_rd" ]]; then
    tmpdirs+=("$pi_rd")
    ok "a --harness pi run is not refused by claude.env naming a missing path"
else
    no "a --harness pi run is not refused by claude.env naming a missing path" \
        "run_real failed"
fi

# An explicit --claude-credentials is different: the operator named that
# file by hand, on this invocation, so it is checked unconditionally, the
# same as --claude-args or --pi-args naming a CLI a run never starts fails
# loud rather than being silently dropped. A --harness pi run that passes
# the flag anyway is still refused.
pi_flag_cfg="$(mktemp -d)"; tmpdirs+=("$pi_flag_cfg")
install -m 600 /dev/null "$pi_flag_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_flag_cfg/pi.env"
pi_flag_out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$pi_flag_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness pi --model moonshotai/kimi-k3 \
    --claude-credentials "$missing_path" "$proj" "$handoff" 2>&1)"
pi_flag_rc=$?
if (( pi_flag_rc == 0 )); then
    no "a --harness pi run is still refused by an explicit --claude-credentials naming a missing path" \
        "$pi_flag_out"
else
    contains "a --harness pi run is still refused by an explicit --claude-credentials naming a missing path" \
        "$missing_path" "$pi_flag_out"
fi

# The same nonexistent path still fails a --harness claude run (the
# existing "missing path" case above already covers --claude-credentials
# directly; this repeats it via CLAUDE_CREDENTIALS in claude.env to prove
# the gate condition, not just the flag, is exercised).
claude_env_cfg="$(mktemp -d)"; tmpdirs+=("$claude_env_cfg")
mkdir -p "$claude_env_cfg"
printf 'CLAUDE_CREDENTIALS=%s\n' "$missing_path" > "$claude_env_cfg/claude.env"
claude_env_out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$claude_env_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
claude_env_rc=$?
if (( claude_env_rc == 0 )); then
    no "a --harness claude run is still refused by CLAUDE_CREDENTIALS naming a missing path" \
        "$claude_env_out"
else
    contains "a --harness claude run is still refused by CLAUDE_CREDENTIALS naming a missing path" \
        "$missing_path" "$claude_env_out"
fi

printf '\n== credential balancing: precedence, run.env recording, pure-pi gate ==\n'

# A fake hook executable named fork-sandbox-headroom-<name>, staged in its
# own PATH dir -- same shape as fork-sandbox-balance-test.sh's fake_hook,
# duplicated here since this suite drives the real launcher rather than
# calling fs_balance_claude_credential directly.
fake_hook() {
    local name="$1" body="$2" bindir
    bindir="$(mktemp -d)"
    tmpdirs+=("$bindir")
    cat > "$bindir/fork-sandbox-headroom-$name" <<HOOK
#!/usr/bin/env bash
$body
HOOK
    chmod +x "$bindir/fork-sandbox-headroom-$name"
    printf '%s' "$bindir"
}

pool_a="$tmp/pool-a-credentials.json"
printf '{"claudeAiOauth":{"accessToken":"pool-a-tok"}}\n' > "$pool_a"
pool_b="$tmp/pool-b-credentials.json"
printf '{"claudeAiOauth":{"accessToken":"pool-b-tok"}}\n' > "$pool_b"

# The flag beats a configured pool: the hook must never be invoked.
flag_marker="$tmp/hook-invoked-flag-wins"
rm -f "$flag_marker"
hook_dir_flagwins="$(fake_hook flagwins "touch $flag_marker; printf '%s\n' \"\$1\"")"
flagwins_cfg="$(mktemp -d)"; tmpdirs+=("$flagwins_cfg")
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$pool_a" "$pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=flagwins\n'
} > "$flagwins_cfg/claude.env"
old_path="$PATH"
export PATH="$hook_dir_flagwins:$PATH"
rd_flagwins="$(run_real "$flagwins_cfg" --harness claude --claude-credentials "$flag_cred")"
export PATH="$old_path"
if [[ -n "$rd_flagwins" ]]; then
    tmpdirs+=("$rd_flagwins")
    contains "flag beats a configured pool: sandbox_cmd carries the flag's path" \
        "--claude-credentials $flag_cred" "$(grep '^sandbox_cmd=' "$rd_flagwins/run.sh")"
    if [[ -f "$flag_marker" ]]; then
        no "flag beats a configured pool: the hook is not invoked" "marker file exists"
    else
        ok "flag beats a configured pool: the hook is not invoked"
    fi
    contains "flag beats a configured pool: run.env records via=flag" \
        "claude_credentials_via=flag" "$(cat "$rd_flagwins/run.env")"
else
    no "flag beats a configured pool: run_real produced a run directory" "run_real failed"
fi

# Happy path: the hook's choice is used, and run.env records it.
hook_dir_happy="$(fake_hook happy2 'printf "%s\n" "$2"')"
happy_cfg="$(mktemp -d)"; tmpdirs+=("$happy_cfg")
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$pool_a" "$pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=happy2\n'
} > "$happy_cfg/claude.env"
old_path="$PATH"
export PATH="$hook_dir_happy:$PATH"
rd_happy="$(run_real "$happy_cfg" --harness claude)"
export PATH="$old_path"
if [[ -n "$rd_happy" ]]; then
    tmpdirs+=("$rd_happy")
    contains "balance happy path: sandbox_cmd carries the hook's choice" \
        "--claude-credentials $pool_b" "$(grep '^sandbox_cmd=' "$rd_happy/run.sh")"
    happy_env="$(cat "$rd_happy/run.env")"
    contains "balance happy path: run.env records via=balance" \
        "claude_credentials_via=balance" "$happy_env"
    contains "balance happy path: run.env records the hook's choice as the source" \
        "claude_credentials_source=$pool_b" "$happy_env"
    # summary.json is the JSONL record's real source (sandbox-run-log.py's
    # SUMMARY_FIELDS lift), not just run.env's fallback path -- assert the
    # field lands there directly, not only in run.env.
    contains "balance happy path: summary.json records via=balance" \
        "balance" "$(jq -r '.claude_credentials_via' "$rd_happy/summary.json")"
    contains "balance happy path: summary.json records the hook's choice as the source" \
        "$pool_b" "$(jq -r '.claude_credentials_source' "$rd_happy/summary.json")"
else
    no "balance happy path: run_real produced a run directory" "run_real failed"
fi

# The balancer's choice naming a missing file is a hard error, the same
# rule as an explicit --claude-credentials or CLAUDE_CREDENTIALS naming one
# (asserted directly above/below via the flag and claude.env cases) -- the
# pool is operator-authored, so a bad entry is this run's problem to raise,
# not to swallow. The pool entry here is syntactically valid (absolute, no
# whitespace or colon) but does not exist on disk.
pool_missing="$tmp/pool-missing-credentials.json"
hook_dir_missing="$(fake_hook missing2 'printf "%s\n" "$2"')"
missing_cfg="$(mktemp -d)"; tmpdirs+=("$missing_cfg")
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$pool_a" "$pool_missing"
    printf 'CLAUDE_HEADROOM_HOOK=missing2\n'
} > "$missing_cfg/claude.env"
missing_out="$(PATH="$hook_dir_missing:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$missing_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
missing_rc=$?
if (( missing_rc == 0 )); then
    no "the balancer choosing a missing file is refused" "$missing_out"
else
    contains "the balancer choosing a missing file is refused" \
        "the credential balancer chose '$pool_missing'" "$missing_out"
    contains "the balancer-chose-missing-file error names the --claude-credentials escape hatch" \
        "--claude-credentials" "$missing_out"
fi

# A pure --harness pi run must never invoke the hook, even with a valid pool
# and hook configured -- hook invocation is observable and this run has no
# claude leg to balance a credential for.
pi_marker="$tmp/hook-invoked-pure-pi"
rm -f "$pi_marker"
hook_dir_pi="$(fake_hook pimarker "touch $pi_marker; printf '%s\n' \"\$1\"")"
pi_balance_cfg="$(mktemp -d)"; tmpdirs+=("$pi_balance_cfg")
install -m 600 /dev/null "$pi_balance_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_balance_cfg/pi.env"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$pool_a" "$pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=pimarker\n'
} > "$pi_balance_cfg/claude.env"
old_path="$PATH"
export PATH="$hook_dir_pi:$PATH"
rd_pi_balance="$(run_real "$pi_balance_cfg" --harness pi --model moonshotai/kimi-k3)"
export PATH="$old_path"
if [[ -n "$rd_pi_balance" ]]; then
    tmpdirs+=("$rd_pi_balance")
    if [[ -f "$pi_marker" ]]; then
        no "a pure pi run never invokes the headroom hook" "marker file exists"
    else
        ok "a pure pi run never invokes the headroom hook"
    fi
    lacks "a pure pi run's run.env has no claude_credentials_via key" \
        "claude_credentials_via" "$(cat "$rd_pi_balance/run.env")"
    lacks "a pure pi run's summary.json has no claude_credentials_via key" \
        "claude_credentials_via" "$(cat "$rd_pi_balance/summary.json")"
else
    no "a pure pi run never invokes the headroom hook" "run_real failed"
fi

# The default chain (no flag, no claude.env, no pool) still records itself
# in run.env, so a reader can tell "nothing configured" from "configured and
# resolved to this path" without inferring it from key absence.
contains "no override: run.env records via=default" \
    "claude_credentials_via=default" "$(cat "$rd_none/run.env")"
contains "no override: run.env records source=default" \
    "claude_credentials_source=default" "$(cat "$rd_none/run.env")"

# CLAUDE_CREDENTIALS in claude.env alone: run.env records via=claude-env and
# the resolved path as the source.
contains "claude.env alone: run.env records via=claude-env" \
    "claude_credentials_via=claude-env" "$(cat "$rd_env/run.env")"
contains "claude.env alone: run.env records its path as the source" \
    "claude_credentials_source=$env_cred" "$(cat "$rd_env/run.env")"

printf '\n== credential balancing: config errors and hook exit codes surface through the real launcher ==\n'

# A pool without a hook is refused loudly at launch, the same as any other
# config error -- one representative case proves the wiring surfaces
# fs_balance_claude_credential's own error rather than swallowing it;
# fork-sandbox-balance-test.sh covers every config-error shape directly.
pool_no_hook_cfg="$(mktemp -d)"; tmpdirs+=("$pool_no_hook_cfg")
printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$pool_a" > "$pool_no_hook_cfg/claude.env"
pool_no_hook_out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$pool_no_hook_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
pool_no_hook_rc=$?
if (( pool_no_hook_rc == 0 )); then
    no "pool without hook is refused at launch" "$pool_no_hook_out"
else
    contains "pool without hook is refused at launch" "without" "$pool_no_hook_out"
fi

# Exit 2 (the hook's own "no routable candidate" answer) is a hard error
# naming the --claude-credentials pin as the escape hatch.
hook_dir_noroute="$(fake_hook noroute2 'exit 2')"
noroute_cfg="$(mktemp -d)"; tmpdirs+=("$noroute_cfg")
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$pool_a"
    printf 'CLAUDE_HEADROOM_HOOK=noroute2\n'
} > "$noroute_cfg/claude.env"
noroute_out="$(PATH="$hook_dir_noroute:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$noroute_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
noroute_rc=$?
if (( noroute_rc == 0 )); then
    no "exit 2 (no routable candidate) is a hard error at launch" "$noroute_out"
else
    contains "exit 2 (no routable candidate) is a hard error at launch" \
        "no routable credential" "$noroute_out"
    contains "exit 2's error at launch names the --claude-credentials override" \
        "--claude-credentials" "$noroute_out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
