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

printf '== --k8s refuses --claude-credentials ==\n'

err="$(mktemp)"; tmpdirs+=("$err")
if dry --k8s --harness claude --model sonnet \
    --claude-credentials /tmp/fs-claude-credentials-test-unused.json \
    >/dev/null 2>"$err"; then
    no "--k8s --claude-credentials is refused"
else
    contains "--k8s --claude-credentials is refused" \
        "not supported with --k8s" "$(cat "$err")"
fi
contains "--k8s --claude-credentials names CLAUDE_CREDENTIALS as the alternative" \
    "CLAUDE_CREDENTIALS in" "$(cat "$err")"

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

printf '\n== the existence check is gated on this run actually using claude ==\n'

# A --harness pi run never reads a Claude credential, so a claude.env whose
# CLAUDE_CREDENTIALS names a path that has since moved must not abort it --
# only a claude leg (implement, review, maintainer, or either fix seat)
# makes the path relevant enough to check for existence.
pi_cfg="$(mktemp -d)"; tmpdirs+=("$pi_cfg")
install -m 600 /dev/null "$pi_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_cfg/pi.env"
pi_rd="$(run_real "$pi_cfg" --harness pi --model moonshotai/kimi-k3 \
    --claude-credentials "$missing_path")"
if [[ -n "$pi_rd" ]]; then
    tmpdirs+=("$pi_rd")
    ok "a --harness pi run is not refused by a nonexistent --claude-credentials path"
else
    no "a --harness pi run is not refused by a nonexistent --claude-credentials path" \
        "run_real failed"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
