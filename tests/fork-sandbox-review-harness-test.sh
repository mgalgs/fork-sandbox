#!/usr/bin/env bash
# fork-sandbox-review-harness-test.sh — Exercise --review-harness: parsing,
# validation, the pi-local networked-review warning, and the two sandbox_cmd
# builds it produces (one per harness) once past --dry-run.
#
# Usage: tests/fork-sandbox-review-harness-test.sh

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

review_dry() {
    "$launcher" --dry-run "$@" "$review_proj" unused-handoff
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
# --review-harness is accepted, but warns by name that the review leg sends
# the clone's contents to that harness's model provider. The reverse -- a
# networked implement harness reviewed by pi-local -- adds no exposure the
# run did not already have, so it is accepted silently (checked below).
for networked in claude "pi/some-model" codex; do
    if ! out="$(dry --harness pi-local --review-loop 2 \
        --review-harness "$networked" 2>"$err")"; then
        no "--harness pi-local + --review-harness $networked is accepted"
    else
        ok "--harness pi-local + --review-harness $networked is accepted"
    fi
    contains "--harness pi-local + --review-harness $networked warns of the exposure" \
        "seals the implement leg" "$(cat "$err")"
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

printf '\n== --review-only: validation and base resolution ==\n'

mkdir -p "$HOME/src"
review_proj="$(mktemp -d "$HOME/src/fs-review-only-test.XXXXXX")"; tmpdirs+=("$review_proj")
(
    cd "$review_proj" && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'base\n' > file.txt && git add file.txt \
        && git commit -q -m base \
        && printf 'head\n' >> file.txt && git commit -q -am head
) || exit 1
head_sha="$(git -C "$review_proj" rev-parse HEAD)"
git -C "$review_proj" switch -q -c review-branch HEAD~1
printf 'review\n' >> "$review_proj/file.txt"
git -C "$review_proj" add file.txt
git -C "$review_proj" -c user.email=t@fork-sandbox.invalid \
    -c user.name=Tester commit -q -m review
review_sha="$(git -C "$review_proj" rev-parse review-branch)"
git -C "$review_proj" switch -q master 2>/dev/null \
    || git -C "$review_proj" switch -q main
old_sha="$(git -C "$review_proj" rev-parse HEAD~1)"
git -C "$review_proj" switch -q --orphan review-unrelated
git -C "$review_proj" commit --allow-empty -q -m unrelated
unrelated_sha="$(git -C "$review_proj" rev-parse HEAD)"
git -C "$review_proj" switch -q master 2>/dev/null \
    || git -C "$review_proj" switch -q main

if review_dry --review-only --harness claude --model sonnet \
    >/dev/null 2>"$err"; then
    no "--review-only without --checkout is refused"
else
    contains "--review-only without --checkout is refused" \
        "requires --checkout" "$(cat "$err")"
fi

refuse_review_only() {
    local label="$1" needle="$2"
    shift 2
    if review_dry --review-only --checkout review-branch \
        --harness claude --model sonnet "$@" >/dev/null 2>"$err"; then
        no "--review-only refuses $label"
    else
        contains "--review-only refuses $label" "$needle" "$(cat "$err")"
    fi
}
refuse_review_only "--review-model" "one review leg" --review-model sonnet
refuse_review_only "--review-harness" "one review leg" --review-harness claude
refuse_review_only "--review-loop" "one review leg" --review-loop 1
refuse_review_only "--refresh-at" "not supported with --review-only" --refresh-at 0.3
refuse_review_only "--k8s" "not supported with --k8s" --k8s
if dry --harness claude --review-base HEAD >/dev/null 2>"$err"; then
    no "--review-base without --review-only is refused"
else
    contains "--review-base without --review-only is refused" \
        "--review-base" "$(cat "$err")"
fi

out="$(review_dry --review-only --checkout review-branch \
    --harness claude --model sonnet 2>/dev/null)"
contains "review-only dry-run prints its mode" "mode=review-only" "$out"
contains "review-only dry-run prints its checkout" "checkout=review-branch" "$out"
contains "default review base is the merge-base" "base_sha=$old_sha" "$out"
contains "review-only dry-run prints the review range" \
    "range=$old_sha...review-branch" "$out"

if review_dry --review-only --checkout review-branch \
    --review-base HEAD --harness claude --model sonnet \
    >/dev/null 2>"$err"; then
    no "a descendant --review-base is refused"
else
    contains "a descendant --review-base is refused" \
        "--review-base 'HEAD' must be an ancestor of --checkout 'review-branch'" \
        "$(tr '\n' ' ' <"$err")"
fi

if review_dry --review-only --checkout review-branch \
    --review-base review-unrelated --harness claude --model sonnet \
    >/dev/null 2>"$err"; then
    no "an unrelated --review-base is refused"
else
    contains "an unrelated --review-base is refused" \
        "--review-base 'review-unrelated' must be an ancestor of --checkout 'review-branch'" \
        "$(tr '\n' ' ' <"$err")"
fi

out="$(review_dry --review-only --checkout review-branch \
    --review-base HEAD~1 --harness claude --model sonnet 2>/dev/null)"
contains "a proper ancestor --review-base is accepted" "base_sha=$old_sha" "$out"

if review_dry --review-only --checkout review-branch \
    --review-base review-branch --harness claude --model sonnet \
    >/dev/null 2>"$err"; then
    no "an empty review range is refused"
else
    contains "an empty review range is refused" "nothing to review" "$(cat "$err")"
fi

plain_out="$(dry --harness claude 2>/dev/null)"
if [[ "$plain_out" != *"mode="* && "$plain_out" != *"range="* ]]; then
    ok "a plain dry-run has no review-only fields"
else
    no "a plain dry-run has no review-only fields" "$plain_out"
fi

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

review_only_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-only-stub.XXXXXX)"
tmpdirs+=("$review_only_stub")
cat > "$review_only_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir=""
for a in "$@"; do
    [[ -d "$a/.git" ]] && clone_dir="$a"
done
cat >/dev/null
case "${REVIEW_VERDICT:-approved}" in
approved)
    printf 'APPROVED\n\nThe reviewed range is sound.\n\n## Report\nThe branch is sound.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
approved-no-report)
    printf 'APPROVED\n\nThe reviewed range is sound without an orchestrator report.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
findings)
    printf 'FINDINGS\n\nfile.txt:1 first issue\n\nfile.txt:2 second issue\n\n## Report\nThe review found two issues.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
findings-no-report)
    printf 'FINDINGS\n\nfile.txt:1 first issue\n\nfile.txt:2 second issue\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
approved-malformed-report)
    printf 'APPROVED\n\nChecked: useful evidence.\n\n## Report\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
approved-duplicate-report)
    printf 'APPROVED\n\nChecked: useful evidence.\n\n## Report\nFirst report.\n\n## Report\nSecond report.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
none) ;;
esac
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$review_only_stub/claude-sandboxed"

review_only_run() {
    local branch="$1" verdict="$2" out rc rd
    out="$(PATH="$review_only_stub:$real_stub:$PATH" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        REVIEW_VERDICT="$verdict" timeout 60 "$launcher" --foreground \
        --review-only --harness claude --model sonnet \
        --checkout review-branch --branch "$branch" \
        "$review_proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    printf '%s\n' "$rc" > "$review_proj/$branch.rc"
    printf '%s\n' "$rd" > "$review_proj/$branch.rd"
    [[ -n "$rd" ]] && tmpdirs+=("$rd")
    printf '%s\n' "$out"
}

printf '\n== --review-only: end-to-end verdicts ==\n'

approved_branch="review-only-approved-$$"
approved_out="$(review_only_run "$approved_branch" approved)"
approved_rc="$(cat "$review_proj/$approved_branch.rc")"
approved_rd="$(cat "$review_proj/$approved_branch.rd")"
if [[ "$approved_rc" == 0 && -n "$approved_rd" ]]; then
    ok "an APPROVED review-only run exits 0"
    contains "review-only launch report names the checkout SHA" \
        "start:    review-branch (${review_sha:0:12})" "$approved_out"
    if [[ "$approved_out" == *"start:    review-branch (${old_sha:0:12})"* ]]; then
        no "review-only launch report does not name the review base SHA"
    else
        ok "review-only launch report does not name the review base SHA"
    fi
    check "APPROVED review-only run ends approved" "approved" \
        "$(jq -r '.ended' "$approved_rd/review-loop.json")"
    check "APPROVED review-only summary has mode" "review-only" \
        "$(jq -r '.mode' "$approved_rd/summary.json")"
    check "APPROVED review-only summary has no commits" "0" \
        "$(jq -r '.commits' "$approved_rd/summary.json")"
    check "APPROVED review-only summary reports review provenance" "review" \
        "$(jq -r '.report_from' "$approved_rd/summary.json")"
    check "review-only defaults task metadata to review" '{"kind":"review"}' \
        "$(cat "$approved_rd/task-meta.json")"
    contains "review-only events.jsonl is the review leg's output" \
        '"subtype":"success"' "$(cat "$approved_rd/events.jsonl")"
    if [[ ! -e "$approved_rd/events-review-1.jsonl" ]]; then
        ok "review-only does not create a separate review events file"
    else
        no "review-only does not create a separate review events file"
    fi
    if git -C "$review_proj" show-ref --verify --quiet "refs/heads/$approved_branch"; then
        no "an APPROVED review-only run removes its branch"
    else
        ok "an APPROVED review-only run removes its branch"
    fi
    log_home="$(mktemp -d /var/tmp/claude-scratch/fs-review-only-log-home.XXXXXX)"
    tmpdirs+=("$log_home")
    mkdir -p "$log_home/.claude"
    if HOME="$log_home" "$run_log" record --run-dir "$approved_rd" \
        >/dev/null 2>&1; then
        ok "sandbox-run-log records a review-only run"
        check "the run-log record carries review-only mode" "review-only" \
            "$(HOME="$log_home" "$run_log" show "$(basename "$approved_rd")" \
                | jq -r '.mode')"
    else
        no "sandbox-run-log records a review-only run"
    fi
else
    no "an APPROVED review-only run exits 0" "rc=$approved_rc rd=$approved_rd $approved_out"
fi

approved_no_report_branch="review-only-approved-no-report-$$"
approved_no_report_out="$(review_only_run "$approved_no_report_branch" approved-no-report)"
approved_no_report_rc="$(cat "$review_proj/$approved_no_report_branch.rc")"
approved_no_report_rd="$(cat "$review_proj/$approved_no_report_branch.rd")"
if [[ "$approved_no_report_rc" == 0 && -n "$approved_no_report_rd" ]]; then
    ok "an APPROVED review-only verdict without a report exits 0"
    check "APPROVED without a report ends approved" "approved" \
        "$(jq -r '.ended' "$approved_no_report_rd/review-loop.json")"
    check "APPROVED without a report keeps session provenance" "session" \
        "$(jq -r '.report_from' "$approved_no_report_rd/summary.json")"
else
    no "an APPROVED review-only verdict without a report exits 0" \
        "rc=$approved_no_report_rc rd=$approved_no_report_rd $approved_no_report_out"
fi

findings_branch="review-only-findings-$$"
findings_out="$(review_only_run "$findings_branch" findings)"
findings_rc="$(cat "$review_proj/$findings_branch.rc")"
findings_rd="$(cat "$review_proj/$findings_branch.rd")"
if [[ "$findings_rc" == 0 && -n "$findings_rd" ]]; then
    ok "a FINDINGS review-only run exits 0"
    check "FINDINGS review-only run ends findings" "findings" \
        "$(jq -r '.ended' "$findings_rd/review-loop.json")"
    check "FINDINGS review-only counts two cited paragraphs" "2" \
        "$(jq -r '.iterations[0].findings' "$findings_rd/review-loop.json")"
    if [[ ! -e "$findings_rd/fix-prompt-1.md" ]]; then
        ok "FINDINGS review-only writes no fix prompt"
    else
        no "FINDINGS review-only writes no fix prompt"
    fi
else
    no "a FINDINGS review-only run exits 0" "rc=$findings_rc rd=$findings_rd $findings_out"
fi

findings_no_report_branch="review-only-findings-no-report-$$"
findings_no_report_out="$(review_only_run "$findings_no_report_branch" findings-no-report)"
findings_no_report_rc="$(cat "$review_proj/$findings_no_report_branch.rc")"
findings_no_report_rd="$(cat "$review_proj/$findings_no_report_branch.rd")"
if [[ "$findings_no_report_rc" == 0 && -n "$findings_no_report_rd" ]]; then
    ok "a FINDINGS review-only verdict without a report exits 0"
    check "FINDINGS without a report counts two cited paragraphs" "2" \
        "$(jq -r '.iterations[0].findings' "$findings_no_report_rd/review-loop.json")"
else
    no "a FINDINGS review-only verdict without a report exits 0" \
        "rc=$findings_no_report_rc rd=$findings_no_report_rd $findings_no_report_out"
fi

malformed_report_branch="review-only-malformed-report-$$"
malformed_report_out="$(review_only_run "$malformed_report_branch" approved-malformed-report)"
malformed_report_rc="$(cat "$review_proj/$malformed_report_branch.rc")"
malformed_report_rd="$(cat "$review_proj/$malformed_report_branch.rd")"
if [[ "$malformed_report_rc" == 0 && -n "$malformed_report_rd" ]]; then
    ok "a verdict with an empty report section still exits 0"
    check "an empty report section does not fail the verdict" "approved" \
        "$(jq -r '.ended' "$malformed_report_rd/review-loop.json")"
else
    no "a verdict with an empty report section still exits 0" \
        "rc=$malformed_report_rc rd=$malformed_report_rd $malformed_report_out"
fi

duplicate_report_branch="review-only-duplicate-report-$$"
duplicate_report_out="$(review_only_run "$duplicate_report_branch" approved-duplicate-report)"
duplicate_report_rc="$(cat "$review_proj/$duplicate_report_branch.rc")"
duplicate_report_rd="$(cat "$review_proj/$duplicate_report_branch.rd")"
if [[ "$duplicate_report_rc" == 0 && -n "$duplicate_report_rd" ]]; then
    ok "a verdict with duplicate report headings still exits 0"
    check "duplicate report headings do not fail the verdict" "approved" \
        "$(jq -r '.ended' "$duplicate_report_rd/review-loop.json")"
else
    no "a verdict with duplicate report headings still exits 0" \
        "rc=$duplicate_report_rc rd=$duplicate_report_rd $duplicate_report_out"
fi

missing_branch="review-only-missing-$$"
missing_out="$(review_only_run "$missing_branch" none)"
missing_rc="$(cat "$review_proj/$missing_branch.rc")"
missing_rd="$(cat "$review_proj/$missing_branch.rd")"
if [[ "$missing_rc" == 1 && -n "$missing_rd" ]]; then
    ok "a review leg with no verdict exits 1"
    check "a missing verdict ends with harness-error" "harness-error" \
        "$(jq -r '.ended' "$missing_rd/review-loop.json")"
else
    no "a review leg with no verdict exits 1" "rc=$missing_rc rd=$missing_rd $missing_out"
fi

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
# refresh. The artifact outbox is a separate, unconditional bind (see
# fork-sandbox.sh's own "Created and bound on every run, whether or not
# refresh is enabled" comment) -- it must still appear in both commands
# here even though refresh itself stays off.
rd8="$(run_real --harness pi/some-model --review-loop 1 --review-harness claude)"
if [[ -n "$rd8" ]]; then
    tmpdirs+=("$rd8")
    check "--refresh-at is not enabled when the implement harness is pi" \
        "0" "$(sed -n 's/^refresh_enabled=//p' "$rd8/run.sh")"
    sandbox_line8="$(grep '^sandbox_cmd=' "$rd8/run.sh")"
    review_line8="$(grep '^review_sandbox_cmd=' "$rd8/run.sh")"
    contains "the outbox is bound into the implement command regardless of refresh" \
        "--bind-rw $rd8/outbox" "$sandbox_line8"
    contains "the outbox is bound into the review command regardless of refresh" \
        "--bind-rw $rd8/outbox" "$review_line8"
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

printf '\n== --review-loop: review and fix legs start with an empty inbox ==\n'

# fs_archive_inbox (fork-sandbox.sh) moves every addendum out of the inbox
# the moment the leg that saw it ends, so a later leg's fresh sandbox --
# fresh /tmp, same read-only inbox bind -- never re-reads it. Drive a real,
# full --harness claude --review-loop 1 run (implement, review and fix legs
# all on this one stub) and have each leg record which '*.md' names it saw
# in the inbox the moment it started, so the review and fix legs' own
# records can be checked against the implement leg's.
seen_dir="$(mktemp -d)"; tmpdirs+=("$seen_dir")
inbox_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-inbox-stub.XXXXXX)"
tmpdirs+=("$inbox_stub")
cat > "$inbox_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely, so it reads and writes the
# clone and the inbox directly, the way the fork-sandbox-refresh-test.sh
# stub does. Which invocation this is comes from a counter file: 1 is the
# implement leg, 2 the review leg, 3 the fix leg (--review-loop 1 with a
# FINDINGS verdict runs exactly those three).
set -uo pipefail

outbox="" clone_dir="" prev=""
for a in "$@"; do
    [[ "$prev" == "--bind-rw" ]] && outbox="$a"
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done

cat >/dev/null   # drain the prompt; its content is not needed by this stub

n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"

run_dir="$(dirname "$outbox")"
inbox_dir="$run_dir/inbox"

# What this leg's own inbox bind held the moment it started -- the record
# the test compares leg by leg.
seen=""
for f in "$inbox_dir"/*.md; do
    [[ -f "$f" ]] || continue
    seen="$seen${f##*/}"$'\n'
done
printf '%s' "$seen" > "$FAKE_SEEN_DIR/leg-$n"

case "$n" in
1)
    # The implement leg: an operator addendum lands mid-leg, and the leg
    # commits so the review loop has something to review.
    printf 'do this too\n' > "$inbox_dir/9999999900-01.md"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    ;;
2)
    # The review leg: an addendum lands mid-leg here too, so next_leg_no's
    # arithmetic (leg_no + 1, continued across the loop) is exercised against
    # a leg other than the implement one -- a wrong starting value or a
    # missing increment would otherwise never be exercised, since the only
    # addendum in this scenario used to be the implement leg's. Findings, so
    # a fix leg follows.
    printf 'a message sent while the review leg ran\n' > "$inbox_dir/9999999900-02.md"
    printf 'FINDINGS\n\nfile.txt:1 not quite right\n\n## Report\nThe report cites report.md:99.\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
*)
    # The fix leg: an addendum lands mid-leg here too, for the same reason.
    # Commit again, so the loop does not read as no-progress.
    printf 'a message sent while the fix leg ran\n' > "$inbox_dir/9999999900-03.md"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$inbox_stub/claude-sandboxed"

count_file9="$(mktemp)"; tmpdirs+=("$count_file9")
out9="$(PATH="$inbox_stub:$PATH" \
    FAKE_COUNT_FILE="$count_file9" FAKE_SEEN_DIR="$seen_dir" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 1 \
    "$proj" "$handoff" 2>&1)"
rc9=$?
rd9="$(printf '%s\n' "$out9" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rc9 == 0 )) && [[ -n "$rd9" ]]; then
    tmpdirs+=("$rd9")
    check "three legs ran (implement, review, fix)" "3" "$(cat "$count_file9")"
    check "report citations do not inflate findings" "1" \
        "$(jq -r '.iterations[0].findings' "$rd9/review-loop.json")"
    if ! grep -qF 'report.md:99' "$rd9/fix-prompt-1.md" 2>/dev/null; then
        ok "fix prompt excludes the review report"
    else
        no "fix prompt excludes the review report"
    fi
    check "review-loop summary reports review provenance" "review" \
        "$(jq -r '.report_from' "$rd9/summary.json")"
    check "the implement leg's inbox holds nothing yet (nothing sent before it started)" \
        "" "$(cat "$seen_dir/leg-1" 2>/dev/null)"
    check "the review leg's inbox is empty: the implement leg's addendum was archived" \
        "" "$(cat "$seen_dir/leg-2" 2>/dev/null)"
    check "the fix leg's inbox is empty too" \
        "" "$(cat "$seen_dir/leg-3" 2>/dev/null)"
    archived9="$(find "$rd9/inbox-delivered/leg-1" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived9" ]]; then
        ok "the addendum the implement leg saw is archived under inbox-delivered/leg-1"
    else
        no "the addendum the implement leg saw is archived under inbox-delivered/leg-1"
    fi
    # The review leg's own inbox bind is empty (checked above), so the only
    # way it can see the implement leg's addendum at all -- and meet its own
    # prompt's "an unfollowed addendum is a finding" contract -- is if the
    # per-iteration review prompt embeds it, the way a continuation prompt
    # embeds every earlier leg's archived addenda.
    contains "the review leg's own prompt carries the implement leg's archived addendum" \
        "do this too" "$(cat "$rd9/review-prompt-1.md" 2>/dev/null)"

    # next_leg_no starts at the implement leg's own number + 1 and advances
    # once per review/fix leg -- unverified until now, since the only
    # addendum in this scenario used to be the implement leg's, so the
    # review and fix legs' own fs_archive_inbox calls were always exercised
    # against an already-empty inbox. A wrong starting value or a missing
    # increment would collide two of these three legs' archives into one
    # directory; distinct, correctly-numbered directories rule that out.
    archived_review9="$(find "$rd9/inbox-delivered/leg-2" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived_review9" ]]; then
        ok "the addendum sent to the review leg is archived under inbox-delivered/leg-2"
        contains "the review leg's archived addendum keeps its own text" \
            "a message sent while the review leg ran" "$(cat "$archived_review9")"
    else
        no "the addendum sent to the review leg is archived under inbox-delivered/leg-2"
        no "the review leg's archived addendum keeps its own text" "no archived file"
    fi
    archived_fix9="$(find "$rd9/inbox-delivered/leg-3" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived_fix9" ]]; then
        ok "the addendum sent to the fix leg is archived under inbox-delivered/leg-3"
        contains "the fix leg's archived addendum keeps its own text" \
            "a message sent while the fix leg ran" "$(cat "$archived_fix9")"
    else
        no "the addendum sent to the fix leg is archived under inbox-delivered/leg-3"
        no "the fix leg's archived addendum keeps its own text" "no archived file"
    fi
    review_count9="$(find "$rd9/inbox-delivered/leg-2" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    fix_count9="$(find "$rd9/inbox-delivered/leg-3" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "the review and fix legs' archives are separate, one file each, not merged" \
        "1 1" "$review_count9 $fix_count9"
else
    no "run_real produced a run directory for the review/fix-inbox scenario" \
        "rc=$rc9: $out9"
fi

printf '\n== --review-loop 2: archived addenda reach the second review ==\n'

# A first review can find work, causing a fix leg and a second review. Keep
# this separate from the loop-1 coverage above: a prompt builder that only
# refreshed addenda for iteration 1 would still pass that scenario.
loop2_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-loop2.XXXXXX)"
tmpdirs+=("$loop2_stub")
cat > "$loop2_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

outbox="" clone_dir="" prev=""
for a in "$@"; do
    [[ "$prev" == "--bind-rw" ]] && outbox="$a"
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done

cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
run_dir="$(dirname "$outbox")"
inbox_dir="$run_dir/inbox"

case "$n" in
1)
    # This is archived when the implement leg ends, before either review.
    printf 'carry this through both reviews\n' > "$inbox_dir/9999999800-01.md"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "loop2 implement"
    ;;
2)
    printf 'FINDINGS\n\nfile.txt:1 still needs work\n' > "$clone_dir/.git/review-verdict.md"
    ;;
3)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "loop2 fix"
    ;;
4)
    printf 'APPROVED\n' > "$clone_dir/.git/review-verdict.md"
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$loop2_stub/claude-sandboxed"

count10="$(mktemp)"; tmpdirs+=("$count10")
out10="$(PATH="$loop2_stub:$PATH" FAKE_COUNT_FILE="$count10" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 2 \
    --branch "sandbox-test-loop2-$$" \
    "$proj" "$handoff" 2>&1)"
rc10=$?
rd10="$(printf '%s\n' "$out10" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rc10 == 0 )) && [[ -n "$rd10" ]]; then
    tmpdirs+=("$rd10")
    check "four legs ran across two review iterations" "4" "$(cat "$count10")"
    check "the second review approved after the fix" "approved" \
        "$(jq -r '.ended' "$rd10/review-loop.json")"
    if [[ -f "$rd10/review-prompt-2.md" ]]; then
        ok "review-prompt-2.md exists"
        contains "the second review prompt carries the archived implement addendum" \
            "carry this through both reviews" "$(cat "$rd10/review-prompt-2.md")"
    else
        no "review-prompt-2.md exists"
    fi
else
    no "run_real produced a run directory for the two-iteration addenda scenario" \
        "rc=$rc10: $out10"
fi

printf '\n== --review-loop: archiving follows the leg'"'"'s OWN harness, not the implement one ==\n'

# fs_archive_inbox is gated on the harness the ENDING leg actually ran, not
# on $harness (the implement harness) -- run_leg passes it
# review_preamble_harness for a review leg. The scenario above never
# exercises that: --harness claude with no --review-harness makes every
# leg's own harness "claude" too, so leg_harness == $harness always and a
# revert to leg_harness="$harness" would still pass every check above. The
# two mixed pairs below -- claude/pi-local and pi/claude -- are the cases
# that tell the two apart, since only in a mixed pair can $harness and a
# leg's own harness disagree.

# Scenario A: --harness claude --review-harness pi-local. The implement and
# fix legs run on claude-sandboxed; the review leg alone runs on
# agent-sandboxed, since --review-harness only overrides the review leg (a
# fix leg "stays on the implement harness throughout", per fs_archive_inbox's
# own comment). An addendum sent while the review leg runs must NOT be
# archived at ITS boundary -- pi-local has no Stop hook, so archiving there
# would risk losing a message nobody can prove was read -- and must instead
# still be sitting in the live inbox for the fix leg to sweep up under its
# own number when IT ends, since the fix leg is back on claude.
mixed_a_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-mixed-a.XXXXXX)"
tmpdirs+=("$mixed_a_stub")
# Both stubs bypass bwrap and locate the clone/outbox by content rather than
# by argv position, since claude-sandboxed and agent-sandboxed do not agree
# on where the clone dir falls in argv -- the clone dir is the one argument
# that is a real directory with a .git inside it, and the outbox is the one
# that is a real directory named "outbox". Legs are told apart by a shared
# counter file, the same protocol the single-harness scenario above uses.
cat > "$mixed_a_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" outbox=""
for a in "$@"; do
    if [[ -d "$a/.git" ]]; then
        clone_dir="$a"
    elif [[ -d "$a" && "$(basename -- "$a")" == "outbox" ]]; then
        outbox="$a"
    fi
done
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
inbox_dir="$(dirname "$outbox")/inbox"
case "$n" in
1)
    printf 'implement addendum\n' > "$inbox_dir/9999999900-01.md"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    ;;
3)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    ;;
esac
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
cat > "$mixed_a_stub/agent-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" outbox=""
for a in "$@"; do
    if [[ -d "$a/.git" ]]; then
        clone_dir="$a"
    elif [[ -d "$a" && "$(basename -- "$a")" == "outbox" ]]; then
        outbox="$a"
    fi
done
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
inbox_dir="$(dirname "$outbox")/inbox"
printf 'a message sent while the pi-local review leg ran\n' > "$inbox_dir/9999999900-02.md"
printf 'FINDINGS\n\nfile.txt:1 not quite right\n\n## Report\nThe review found one issue.\n' > "$clone_dir/.git/review-verdict.md"
exit 0
STUB
chmod +x "$mixed_a_stub/claude-sandboxed" "$mixed_a_stub/agent-sandboxed"

count_a="$(mktemp)"; tmpdirs+=("$count_a")
outA="$(PATH="$mixed_a_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FAKE_COUNT_FILE="$count_a" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 1 \
    --review-harness pi-local --branch "sandbox-test-mixed-a-$$" \
    "$proj" "$handoff" 2>&1)"
rcA=$?
rdA="$(printf '%s\n' "$outA" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rcA == 0 )) && [[ -n "$rdA" ]]; then
    tmpdirs+=("$rdA")
    check "all three legs ran" "3" "$(cat "$count_a")"
    archived_implA="$(find "$rdA/inbox-delivered/leg-1" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived_implA" ]]; then
        ok "the claude implement leg's addendum is archived under leg-1"
    else
        no "the claude implement leg's addendum is archived under leg-1"
    fi
    check "the pi-local review leg does NOT archive at its own boundary" \
        "0" "$(find "$rdA/inbox-delivered/leg-2" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    archived_fixA="$(find "$rdA/inbox-delivered/leg-3" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)"
    if [[ -n "$archived_fixA" ]]; then
        ok "the claude fix leg sweeps up the review leg's leftover addendum under leg-3"
        contains "the swept-up addendum keeps its own text" \
            "a message sent while the pi-local review leg ran" "$(cat "$archived_fixA")"
    else
        no "the claude fix leg sweeps up the review leg's leftover addendum under leg-3"
        no "the swept-up addendum keeps its own text" "no archived file"
    fi
else
    no "run_real produced a run directory for the claude/pi-local archiving scenario" \
        "rc=$rcA: $outA"
fi

# Scenario B: --harness pi/some-model --review-harness claude. pi (not
# pi-local) also runs through claude-sandboxed, via --exec, so this whole
# scenario is one stub: the implement and fix legs run pi's argv under
# --exec, and the review leg runs claude's own plain argv, and both shapes
# are told apart by leg number, same as above. The implement leg's own
# harness is pi, so its addendum must NOT be archived when IT ends, even
# though the RUN's implement harness -- $harness -- is the same "pi" a
# reverted leg_harness="$harness" would also use for the review leg. The
# review leg's own harness is claude, so when it ends it must archive BOTH
# its own addendum and the implement leg's leftover one, under leg-2 -- the
# one outcome a reverted leg_harness="$harness" (which would evaluate to
# "pi/some-model", not claude, for this leg) could not produce.
mixed_b_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-harness-mixed-b.XXXXXX)"
tmpdirs+=("$mixed_b_stub")
cat > "$mixed_b_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" outbox=""
for a in "$@"; do
    if [[ -d "$a/.git" ]]; then
        clone_dir="$a"
    elif [[ -d "$a" && "$(basename -- "$a")" == "outbox" ]]; then
        outbox="$a"
    fi
done
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
inbox_dir="$(dirname "$outbox")/inbox"
case "$n" in
1)
    printf 'pi implement addendum\n' > "$inbox_dir/9999999900-01.md"
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    printf 'pi text output, no JSON\n'
    ;;
2)
    printf 'a message sent while the claude review leg ran\n' > "$inbox_dir/9999999900-02.md"
    printf 'FINDINGS\n\nfile.txt:1 not quite right\n\n## Report\nThe review found one issue.\n' > "$clone_dir/.git/review-verdict.md"
    printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    ;;
3)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "leg $n"
    printf 'pi text output, no JSON\n'
    ;;
esac
exit 0
STUB
chmod +x "$mixed_b_stub/claude-sandboxed"

count_b="$(mktemp)"; tmpdirs+=("$count_b")
outB="$(PATH="$mixed_b_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FAKE_COUNT_FILE="$count_b" \
    timeout 60 "$launcher" --foreground --harness pi/some-model --review-loop 1 \
    --review-harness claude --branch "sandbox-test-mixed-b-$$" \
    "$proj" "$handoff" 2>&1)"
rcB=$?
rdB="$(printf '%s\n' "$outB" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rcB == 0 )) && [[ -n "$rdB" ]]; then
    tmpdirs+=("$rdB")
    check "all three legs ran" "3" "$(cat "$count_b")"
    check "the pi implement leg does NOT archive at its own boundary" \
        "0" "$(find "$rdB/inbox-delivered/leg-1" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "the claude review leg archives both its own and the implement leg's leftover addendum" \
        "2" "$(find "$rdB/inbox-delivered/leg-2" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    check "the pi fix leg does NOT archive at its own boundary either" \
        "0" "$(find "$rdB/inbox-delivered/leg-3" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
else
    no "run_real produced a run directory for the pi/claude archiving scenario" \
        "rc=$rcB: $outB"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
