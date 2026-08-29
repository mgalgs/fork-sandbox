#!/usr/bin/env bash
# fork-sandbox-review-harness-test.sh — Exercise --review-harness: parsing,
# validation, the pi-local seal refusal, and the two sandbox_cmd builds it
# produces (one per harness) once past --dry-run.
#
# Usage: tests/fork-sandbox-review-harness-test.sh

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

# --dry-run resolves and validates the harness/model, then exits before the
# clone -- exactly what every check below except the "real runs" section
# needs, and none of it needs a real project or handoff.
dry() {
    "$launcher" --dry-run "$@" unused-project unused-handoff
}

printf '== --review-harness: parsing and validation (--dry-run) ==\n'

err="$(mktemp)"; tmpdirs+=("$err")

# 1. Requires --review-loop, same as --review-model.
if dry --harness claude --review-harness claude >/dev/null 2>"$err"; then
    no "--review-harness without --review-loop is refused"
else
    contains "--review-harness without --review-loop is refused" \
        "requires" "$(cat "$err")"
fi

# 2. The combined harness/model form preserves a slash-bearing OpenRouter
# id whole, exactly as --harness does, and conflicts with --review-model.
out="$(dry --harness claude --review-loop 2 \
    --review-harness pi/moonshotai/kimi-k3 2>/dev/null \
    | grep -E '^review_harness=|^review_model=')"
check "combined review-harness model preserves the full id" \
    $'review_model=moonshotai/kimi-k3\nreview_harness=pi' "$out"

if dry --harness claude --review-loop 2 \
    --review-harness pi/moonshotai/kimi-k3 --review-model something-else \
    >/dev/null 2>"$err"; then
    no "combined review-harness model conflicts with --review-model"
else
    contains "combined review-harness model conflicts with --review-model" \
        "conflicts with --review-model" "$(cat "$err")"
fi

# 3. An invalid harness name is refused the same way --harness refuses one.
if dry --harness claude --review-loop 2 --review-harness bogus \
    >/dev/null 2>"$err"; then
    no "an invalid --review-harness name is refused"
else
    contains "an invalid --review-harness name is refused" \
        "not 'bogus'" "$(cat "$err")"
fi

# 4. The seal: --harness pi-local (no network at all) with a networked
# --review-harness must be refused, by name, with the seal as the reason.
# The reverse -- a networked implement harness reviewed by pi-local -- adds
# no exposure the run did not already have, so it is accepted.
for networked in claude "pi/some-model" codex; do
    if dry --harness pi-local --review-loop 2 --review-harness "$networked" \
        >/dev/null 2>"$err"; then
        no "--harness pi-local + --review-harness $networked is refused"
    else
        contains "--harness pi-local + --review-harness $networked is refused" \
            "seals this run" "$(cat "$err")"
    fi
done
out="$(dry --harness claude --review-loop 2 --review-harness pi-local 2>"$err" \
    | grep -E '^review_harness=')"
check "--harness claude + --review-harness pi-local is accepted" \
    "review_harness=pi-local" "$out"
[[ -s "$err" ]] && no "--harness claude + --review-harness pi-local prints no error" "$(cat "$err")"

# 5. --k8s refuses --review-harness by name, alongside --review-model.
if dry --k8s --review-loop 2 --review-harness claude --model x \
    >/dev/null 2>"$err"; then
    no "--k8s --review-harness is refused"
else
    contains "--k8s --review-harness is refused" \
        "not supported with --k8s" "$(cat "$err")"
fi

# 6. --dry-run reports both the implement and review harness once both are
# resolved.
out="$(dry --harness claude --model sonnet --review-loop 2 \
    --review-harness pi --review-model moonshotai/kimi-k3 2>/dev/null \
    | grep -E '^harness=|^model=|^review_model=|^review_harness=')"
check "--dry-run shows both harnesses resolved" \
    $'harness=claude\nmodel=sonnet\nreview_model=moonshotai/kimi-k3\nreview_harness=pi' \
    "$out"

# --harness pi and --review-harness pi both need a model; neither has a
# default. (Mirrors the existing --harness pi check, one flag over.)
if dry --harness claude --review-loop 2 --review-harness pi >/dev/null 2>"$err"; then
    no "--review-harness pi without a model is refused"
else
    contains "--review-harness pi without a model is refused" \
        "needs a model" "$(cat "$err")"
fi

# Regression: --review-model alone, with no --review-harness, is untouched.
# fork-sandbox-alias-test.sh already covers this path in depth; this is a
# narrow confirmation that adding --review-harness did not disturb it.
out="$(dry --harness claude --review-loop 2 --review-model sonnet 2>/dev/null \
    | grep -E '^harness=|^review_model=|^review_harness=')"
check "--review-model alone still resolves as before (no review_harness line)" \
    $'harness=claude\nreview_model=sonnet' "$out"

printf '\n== --review-harness: credentials checked before the clone ==\n'

# claude-sandboxed only, no pi.env: the IMPLEMENT harness (claude) needs no
# credential file, so this fails on the REVIEW harness's (pi) missing key --
# proving both harnesses' requirements are checked, not just the implement
# one, and that the failure happens before anything is cloned.
cred_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-cred-stub.XXXXXX)"
tmpdirs+=("$cred_stub")
cat > "$cred_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
chmod +x "$cred_stub/claude-sandboxed"

new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-review-harness-test.XXXXXX")"
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

cred_cfg="$(mktemp -d)"; tmpdirs+=("$cred_cfg")
proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

before="$(find /var/tmp/claude-scratch/forks -maxdepth 1 -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
out="$(PATH="$cred_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$cred_cfg" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 1 \
    --review-harness pi/some-model "$proj" "$handoff" 2>&1)"
rc=$?
after="$(find /var/tmp/claude-scratch/forks -maxdepth 1 -name 'claude-fork-sandbox.*' 2>/dev/null | wc -l)"
if (( rc == 0 )); then
    no "a missing review-harness credential fails the run" "exited 0: $out"
else
    contains "a missing review-harness credential fails the run" \
        "pi.env not found" "$out"
fi
check "a missing review-harness credential leaves no run directory behind" \
    "$before" "$after"

printf '\n== --review-harness: the two built commands ==\n'

# claude-sandboxed and agent-sandboxed are stubbed, as above; pi and codex
# resolution is steered past needing a REAL pi/codex install by faking the
# sandbox backend's --capabilities output as "image" (the same toolchain a
# container backend reports) -- fs_resolve_pi and the codex arm both take
# the short "nothing to find on this host" path in that mode, which
# fork-sandbox-toolchain-test.sh's own fs_resolve_pi tests already rely on
# for the identical reason.
real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-real-stub.XXXXXX)"
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

real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")
install -m 600 /dev/null "$real_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$real_cfg/pi.env"
printf 'MODEL_ENDPOINT=http://localhost:1/v1\n' > "$real_cfg/model.env"

# Runs fork-sandbox.sh for real, foreground, with every wrapper stubbed and
# the backend faked into image mode, and echoes the run directory
# (registered with tmpdirs by the caller, the same discipline
# fork-sandbox-prompt-overlay-test.sh's run_real uses and for the same
# reason: an append inside this function's own command-substitution
# subshell never reaches the trap).
run_real() {
    local out rc rd
    out="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
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

# 7. --harness claude, --review-harness pi-local: the two built commands
# must differ only in the wrapper (claude-sandboxed vs. agent-sandboxed)
# and each harness's own tail, and must agree, argv-for-argv, on every
# shared bind -- the alternates, the review kit, the inbox, the outbox.
# This is the test that would catch the two builds drifting apart if
# fs_build_sandbox_cmd's shared-flags section were ever edited for one
# call and not the other.
rd7="$(run_real --harness claude --review-loop 1 --review-harness pi-local)"
if [[ -n "$rd7" ]]; then
    tmpdirs+=("$rd7")
    sandbox_line="$(grep '^sandbox_cmd=' "$rd7/run.sh")"
    review_line="$(grep '^review_sandbox_cmd=' "$rd7/run.sh")"

    contains "the implement command uses claude-sandboxed" \
        "/claude-sandboxed " "$sandbox_line"
    contains "the review command uses agent-sandboxed" \
        "/agent-sandboxed " "$review_line"
    contains "the review command carries pi-local's --skill flags" \
        "--skill" "$review_line"
    contains "the review command carries pi-local's --no-git-warning" \
        "--no-git-warning" "$review_line"
    contains "the implement command carries claude's --dangerously-skip-permissions" \
        "--dangerously-skip-permissions" "$sandbox_line"

    # Every shared bind flag from fs_build_sandbox_cmd, in the fixed order
    # it emits them, must appear in both commands: only the wrapper and each
    # harness's own tail may differ. Read straight out of run.env / the run
    # dir layout rather than duplicating fork-sandbox.sh's own path
    # construction by hand.
    clone_dir7="$rd7/clone/$(ls "$rd7/clone")"
    inbox_dir7="$rd7/inbox"
    skill_dir7="$HOME/.claude/skills/commit-then-review"
    shared_ok=true
    for frag in \
        "--bind-ro $skill_dir7" \
        "--bind-ro $inbox_dir7" \
        "--bind-rw $rd7/outbox"
    do
        case "$sandbox_line" in *"$frag"*) ;; *) shared_ok=false ;; esac
        case "$review_line" in *"$frag"*) ;; *) shared_ok=false ;; esac
    done
    if $shared_ok; then
        ok "the shared binds (review kit, inbox, outbox) appear in both commands"
    else
        no "the shared binds (review kit, inbox, outbox) appear in both commands" \
            "sandbox_cmd: $sandbox_line"$'\n'"        review_sandbox_cmd: $review_line"
    fi

    contains "the implement command names this run's clone dir" \
        "$clone_dir7" "$sandbox_line"
    contains "the review command names the same clone dir" \
        "$clone_dir7" "$review_line"
else
    no "run_real produced a run directory for the claude/pi-local pair" "run_real failed"
fi

# 8. --refresh-at is claude-only, tied to the IMPLEMENT harness alone: a
# --harness pi run reviewed by --review-harness claude must not enable
# refresh, and the refresh outbox bind must not appear in either built
# command -- not the implement one (pi never gets it, refresh or not) and
# not the review one either, since it is inert without refresh_enabled.
rd8="$(run_real --harness pi/some-model --review-loop 1 --review-harness claude)"
if [[ -n "$rd8" ]]; then
    tmpdirs+=("$rd8")
    check "--refresh-at is not enabled when the implement harness is pi" \
        "0" "$(sed -n 's/^refresh_enabled=//p' "$rd8/run.sh")"
    sandbox_line8="$(grep '^sandbox_cmd=' "$rd8/run.sh")"
    review_line8="$(grep '^review_sandbox_cmd=' "$rd8/run.sh")"
    case "$sandbox_line8" in
        *"--bind-rw"*"/outbox"*) no "the outbox is not bound into the implement command" "$sandbox_line8" ;;
        *) ok "the outbox is not bound into the implement command" ;;
    esac
    case "$review_line8" in
        *"--bind-rw"*"/outbox"*) no "the outbox is not bound into the review command" "$review_line8" ;;
        *) ok "the outbox is not bound into the review command" ;;
    esac
    # The claude review leg still gets the operator-inbox delivery hook,
    # even though the implement harness (pi) is the one that decided
    # refresh is off: the inbox mechanism and refresh are independent, and
    # a claude leg under a non-claude implement harness still needs
    # addenda delivered the way its own prompt says they will be.
    contains "the claude review leg still gets the inbox-delivery hook" \
        "--settings" "$review_line8"
else
    no "run_real produced a run directory for the pi/claude pair" "run_real failed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
