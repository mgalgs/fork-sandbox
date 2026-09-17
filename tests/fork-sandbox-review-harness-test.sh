#!/usr/bin/env bash
# fork-sandbox-review-harness-test.sh — Exercise --review-harness: parsing,
# validation, the pi-local networked-review warning, and the two sandbox_cmd
# builds it produces (one per harness) once past --dry-run.
#
# Usage: tests/fork-sandbox-review-harness-test.sh

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
        "the implement leg is sealed" "$(cat "$err")"
done
out="$(dry --harness claude --review-loop 2 --review-harness pi-local 2>"$err" \
    | grep -E '^review_harness=')"
check "--harness claude + --review-harness pi-local is accepted" \
    "review_harness=pi" "$out"
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
git -C "$review_proj" switch -q -c review-branch HEAD~1
printf 'review\n' >> "$review_proj/file.txt"
git -C "$review_proj" add file.txt
git -C "$review_proj" -c user.email=t@fork-sandbox.invalid \
    -c user.name=Tester commit -q -m review
review_sha="$(git -C "$review_proj" rev-parse --verify --quiet review-branch)"
git -C "$review_proj" switch -q master 2>/dev/null \
    || git -C "$review_proj" switch -q main
old_sha="$(git -C "$review_proj" rev-parse --verify --quiet HEAD~1)"
git -C "$review_proj" switch -q --orphan review-unrelated
git -C "$review_proj" commit --allow-empty -q -m unrelated
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
printf 'do the task RH-BRIEF-SENTINEL-6b5e\n' > "$handoff"

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
real_codex_home="$(mktemp -d)"; tmpdirs+=("$real_codex_home")
printf '{"tokens":{"access_token":"e30.eyJleHAiOjQxMDI0NDQ4MDB9.sig","refresh_token":"fixture"}}\n' \
    > "$real_codex_home/auth.json"

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
    check "review-only has no coding leg, so coding_exit_code is null, not a forged 0" \
        "null" "$(jq -r '.coding_exit_code' "$approved_rd/review-loop.json")"
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
    # The review-only leg runs through the review loop, so its prompt is the
    # review prompt: the handoff it judges against must be embedded in it
    # (and exactly once -- the implement prompt is never a second copy).
    contains "the review-only prompt embeds the run's handoff" \
        "RH-BRIEF-SENTINEL-6b5e" \
        "$(cat "$findings_rd/review-prompt-1.md" 2>/dev/null)"
    check "the review-only prompt embeds the handoff exactly once" \
        "1" "$(grep -cF -- 'RH-BRIEF-SENTINEL-6b5e' "$findings_rd/review-prompt-1.md" 2>/dev/null)"
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
        CODEX_HOME="$real_codex_home" \
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
    lacks "a claude implement leg has no Codex sessions mount" \
        "codex-sessions" "$sandbox_line"
    lacks "a pi-local review leg has no Codex sessions mount" \
        "codex-sessions" "$review_line"
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

# A Codex implement leg persists its rollout logs in the run directory. A
# named Codex review leg gets the same mount without adding it to a non-Codex
# implement command.
rd_codex_impl="$(run_real --harness codex)"
if [[ -n "$rd_codex_impl" ]]; then
    tmpdirs+=("$rd_codex_impl")
    sandbox_codex_impl="$(grep '^sandbox_cmd=' "$rd_codex_impl/run.sh")"
    contains "a Codex implement leg mounts its per-run sessions directory" \
        "--bind-rw-at $rd_codex_impl/codex-sessions $HOME/.codex/sessions" \
        "$sandbox_codex_impl"
    if [[ -d "$rd_codex_impl/codex-sessions" ]]; then
        ok "a Codex implement run creates its sessions directory"
    else
        no "a Codex implement run creates its sessions directory"
    fi
else
    no "run_real produced a run directory for Codex" "run_real failed"
fi

rd_codex_review="$(run_real --harness claude --review-loop 1 \
    --review-harness codex)"
if [[ -n "$rd_codex_review" ]]; then
    tmpdirs+=("$rd_codex_review")
    sandbox_codex_review="$(grep '^sandbox_cmd=' "$rd_codex_review/run.sh")"
    review_codex_review="$(grep '^review_sandbox_cmd=' "$rd_codex_review/run.sh")"
    lacks "a claude implement command does not inherit its Codex review mount" \
        "codex-sessions" "$sandbox_codex_review"
    contains "a named Codex review leg mounts its per-run sessions directory" \
        "--bind-rw-at $rd_codex_review/codex-sessions $HOME/.codex/sessions" \
        "$review_codex_review"
else
    no "run_real produced a run directory for a Codex review leg" \
        "run_real failed"
fi

# 9. --harness pi-local, --review-harness pi/some-model: the pair check 4
# above only exercises through --dry-run, which exits before
# fs_build_sandbox_cmd ever runs and before the launch report is printed.
# This is the run_real counterpart -- the implement leg must stay sealed
# (agent-sandboxed, no --env-file, no credential) while the review leg is
# a separate, networked sandbox that does carry one (claude-sandboxed
# --exec with --env-file pi.env, per the "pi" case in fs_build_sandbox_cmd
# above), and the launch report printed at the end must say so rather than
# claim the whole run "costs nothing".
out9pl="$(PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness pi-local --review-loop 1 \
    --review-harness pi/some-model "$proj" "$handoff" 2>&1)"
rc9pl=$?
rd9pl="$(printf '%s\n' "$out9pl" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rc9pl == 0 )) && [[ -n "$rd9pl" ]]; then
    tmpdirs+=("$rd9pl")
    sandbox_line9pl="$(grep '^sandbox_cmd=' "$rd9pl/run.sh")"
    review_line9pl="$(grep '^review_sandbox_cmd=' "$rd9pl/run.sh")"

    contains "the pi-local implement command uses agent-sandboxed" \
        "/agent-sandboxed " "$sandbox_line9pl"
    case "$sandbox_line9pl" in
        *--env-file*) no "the pi-local implement command carries no --env-file" "$sandbox_line9pl" ;;
        *) ok "the pi-local implement command carries no --env-file" ;;
    esac

    contains "the pi review command uses claude-sandboxed" \
        "/claude-sandboxed " "$review_line9pl"
    contains "the pi review command carries --exec" \
        "--exec" "$review_line9pl"
    contains "the pi review command carries the OpenRouter --env-file" \
        "--env-file $real_cfg/pi.env" "$review_line9pl"

    contains "the run's warning names the networked review harness" \
        "--review-harness pi is networked" "$out9pl"
    contains "the launch report warns the review leg does not share the seal" \
        "Its review leg does not share that seal" "$out9pl"
    case "$out9pl" in
        *"holds no credential and costs nothing"*"Its review leg does not share that seal"*)
            ok "the launch report qualifies its 'costs nothing' claim to the implement leg" ;;
        *)
            no "the launch report qualifies its 'costs nothing' claim to the implement leg" \
                "$out9pl" ;;
    esac
else
    no "run_real produced a run directory for the pi-local/pi pair" "rc=$rc9pl: $out9pl"
fi

# 10. Regression: --harness pi-local (no --review-harness given, so the
# review leg falls back to reusing the implement command) with
# --review-model must still patch the model into the review leg's
# agent-sandboxed command. This fallback branch used to key off the literal
# harness value "pi-local", which $harness can never hold once the
# --network split expands the alias to harness "pi" + network "sealed" --
# see the dead-arm regression this guards against.
rd10="$(run_real --harness pi-local --model some-local-model \
    --review-loop 1 --review-model other-local-model)"
if [[ -n "$rd10" ]]; then
    tmpdirs+=("$rd10")
    review_line10="$(grep '^review_sandbox_cmd=' "$rd10/run.sh")"
    contains "a pi-local review leg (no --review-harness) gets --review-model patched in" \
        "--model other-local-model" "$review_line10"
else
    no "run_real produced a run directory for the pi-local review-model regression" "run_real failed"
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

printf '\n== a non-zero coding-leg exit does not skip a branch that holds work ==\n'

# Whether the branch holds commits off base_sha decides whether the review
# loop runs -- not the coding leg's exit code. A leg that fails on something
# AFTER committing real work (the reported case: a harness guard refusing an
# rm -rf during its own scratch-dir cleanup) must not have that work skipped
# over unreviewed.
nz_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-nonzero.XXXXXX)"
tmpdirs+=("$nz_stub")
cat > "$nz_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "$@"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"

case "$n" in
1)
    if [[ "${NZ_COMMIT:-1}" == "1" ]]; then
        git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            -C "$clone_dir" commit --allow-empty -q -m "nonzero-exit implement"
    fi
    printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    exit "${NZ_EXIT:-3}"
    ;;
2)
    printf 'APPROVED\n\nChecked: the diff, despite the failed coding leg.\n\n## Report\nThe branch is sound.\n' \
        > "$clone_dir/.git/review-verdict.md"
    printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    exit 0
    ;;
esac
STUB
chmod +x "$nz_stub/claude-sandboxed"

# A: non-zero exit, WITH commits off base -- the loop now runs (and approves)
# despite the coding leg's failure, and the run's own exit code still
# reports the coding leg's failure: a review must never launder it green.
count_nzA="$(mktemp)"; tmpdirs+=("$count_nzA")
outA_nz="$(PATH="$nz_stub:$PATH" NZ_COMMIT=1 NZ_EXIT=3 FAKE_COUNT_FILE="$count_nzA" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 1 \
    --branch "sandbox-test-nonzero-commit-$$" \
    "$proj" "$handoff" 2>&1)"
rcA_nz=$?
rdA_nz="$(printf '%s\n' "$outA_nz" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rdA_nz" ]]; then
    tmpdirs+=("$rdA_nz")
    check "a failed coding leg that committed work still runs both legs" "2" \
        "$(cat "$count_nzA")"
    check "the review leg approves the branch despite the failed coding leg" \
        "approved" "$(jq -r '.ended' "$rdA_nz/review-loop.json")"
    check "the coding leg's exit code is recorded in the loop record" "3" \
        "$(jq -r '.coding_exit_code' "$rdA_nz/review-loop.json")"
    check "an approved loop's detail is not left carrying how the loop started" \
        "null" "$(jq -r '.detail' "$rdA_nz/review-loop.json")"
    contains "the review leg's own prompt is told the coding leg failed" \
        "exited with" "$(cat "$rdA_nz/review-prompt-1.md" 2>/dev/null)"
    check "the run's own exit code stays the coding leg's, not laundered by the review" \
        "3" "$rcA_nz"
    check "exit-code on disk agrees" "3" "$(cat "$rdA_nz/exit-code" 2>/dev/null)"
else
    no "a failed coding leg that committed work produced a run directory" \
        "rc=$rcA_nz: $outA_nz"
fi

# B: non-zero exit, with NO commits -- still skips, because there is nothing
# to review, not because of the exit code.
count_nzB="$(mktemp)"; tmpdirs+=("$count_nzB")
outB_nz="$(PATH="$nz_stub:$PATH" NZ_COMMIT=0 NZ_EXIT=3 FAKE_COUNT_FILE="$count_nzB" \
    timeout 60 "$launcher" --foreground --harness claude --review-loop 1 \
    --branch "sandbox-test-nonzero-nocommit-$$" \
    "$proj" "$handoff" 2>&1)"
rcB_nz=$?
rdB_nz="$(printf '%s\n' "$outB_nz" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rdB_nz" ]]; then
    tmpdirs+=("$rdB_nz")
    check "a failed coding leg with no commits runs only the coding leg" "1" \
        "$(cat "$count_nzB")"
    check "a failed, commitless coding leg still skips the review loop" \
        "skipped" "$(jq -r '.ended' "$rdB_nz/review-loop.json")"
    contains "the skip says there is nothing to review, not that the exit code was the reason" \
        "committed nothing" "$(jq -r '.detail' "$rdB_nz/review-loop.json")"
    check "the coding leg's exit code is still recorded even on a skip" "3" \
        "$(jq -r '.coding_exit_code' "$rdB_nz/review-loop.json")"
    check "the run's own exit code is unaffected by the skip" "3" "$rcB_nz"
else
    no "a failed, commitless coding leg produced a run directory" \
        "rc=$rcB_nz: $outB_nz"
fi

printf '\n== a pi coding leg that ends in a model error (rc 0 -> 1) defers\n   exit-code the same as any other pending review loop ==\n'

# pi exits 0 even when its last turn ended in a provider error; fork-sandbox.sh
# recovers that from the session file and turns rc 0 into rc 1 itself (see the
# "pi exits 0 even when its final turn ended in a provider error" comment
# above pi_error in fork-sandbox.sh). That correction has its own exit-code
# write, separate from the deferred write every other coding-leg path uses,
# and it must defer the same way: with a review loop still to come, exit-code
# must not exist yet when the review leg starts, only after the loop ends.
#
# The review leg's own stub below checks for exit-code's existence itself,
# the moment it starts -- no polling or timing needed, since fork-sandbox.sh
# runs every leg of a --foreground run strictly in sequence: if the pi
# accounting step wrote exit-code early, it is already on disk by the time
# this stub is invoked; if it deferred correctly, it is not.
# A --harness pi (networked, not pi-local) implement leg and a
# --review-harness claude review leg are BOTH wrapped by claude-sandboxed --
# only the sealed pi-local harness gets its own agent-sandboxed wrapper (see
# fs_build_sandbox_cmd's "A harness may bring its own wrapper" comment) --
# so one stub plays both roles here, told apart by --exec: only the pi
# implement leg's command carries it (pi itself runs inside via --exec,
# claude never does).
pi_err_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-pi-error.XXXXXX)"
tmpdirs+=("$pi_err_stub")
pi_err_marker="$(mktemp)"; tmpdirs+=("$pi_err_marker")
cat > "$pi_err_stub/claude-sandboxed" <<STUB
#!/usr/bin/env bash
set -uo pipefail
is_pi_leg=0
for a in "\$@"; do
    [[ "\$a" == "--exec" ]] && is_pi_leg=1
done
clone_dir=""
for a in "\$@"; do
    [[ -d "\$a/.git" ]] && clone_dir="\$a"
done
cat >/dev/null
if (( is_pi_leg )); then
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "\$clone_dir" commit --allow-empty -q -m "pi model-error implement"
    mkdir -p "\$clone_dir/.git/pi-session"
    {
        printf '{"role":"assistant","stopReason":"stop"}\n'
        printf '{"role":"assistant","stopReason":"error",'
        printf '"errorMessage":"context length exceeded",'
        printf '"usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,'
        printf '"totalTokens":110,"cost":{"total":0.001}}}\n'
    } > "\$clone_dir/.git/pi-session/session.jsonl"
    exit 0
fi
run_dir_seen="\$(cd "\$clone_dir/../.." && pwd)"
if [[ -f "\$run_dir_seen/exit-code" ]]; then
    printf 'exists\n' > "$pi_err_marker"
else
    printf 'absent\n' > "$pi_err_marker"
fi
printf 'APPROVED\n\nChecked: the diff, despite the failed coding leg.\n\n## Report\nThe branch is sound.\n' \
    > "\$clone_dir/.git/review-verdict.md"
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$pi_err_stub/claude-sandboxed"

pi_err_cfg="$(mktemp -d)"; tmpdirs+=("$pi_err_cfg")
install -m 600 /dev/null "$pi_err_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_err_cfg/pi.env"

pi_err_out="$(PATH="$pi_err_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$pi_err_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness pi/some-model --review-loop 1 \
    --review-harness claude --branch "sandbox-test-pi-model-error-$$" \
    "$proj" "$handoff" 2>&1)"
pi_err_rc=$?
pi_err_rd="$(printf '%s\n' "$pi_err_out" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$pi_err_rd" ]]; then
    tmpdirs+=("$pi_err_rd")
    check "the review leg saw no exit-code file yet when it started" \
        "absent" "$(cat "$pi_err_marker")"
    check "the review leg still ran and approved the branch" \
        "approved" "$(jq -r '.ended' "$pi_err_rd/review-loop.json")"
    check "the coding leg's model-error correction is recorded in the loop record" \
        "1" "$(jq -r '.coding_exit_code' "$pi_err_rd/review-loop.json")"
    check "the run's own exit code reflects the corrected rc" "1" "$pi_err_rc"
    check "exit-code on disk agrees, published only after the loop ended" \
        "1" "$(cat "$pi_err_rd/exit-code" 2>/dev/null)"
else
    no "the pi model-error scenario produced a run directory" \
        "rc=$pi_err_rc: $pi_err_out"
fi

printf '\n== pi retry exhaustion: rc 0 -> 1 only when nothing was committed ==\n'

# pi exits 0 when its automatic retries run out -- the stream ends in
# auto_retry_end success=false, the session settles, and no turn in the
# session file is left with stopReason "error", so the stopReason check
# above (the other failure detection a pi run has) never fires. The
# accounting turns rc 0 into rc 1 when BOTH the last auto_retry_end is a
# failure AND the branch holds no commits off base (see the pi_retry_error
# block in fork-sandbox.sh). One stub plays the pi implement leg (the
# --exec argument is pi's tell), parameterized per scenario: RE_STREAM is
# the stream shape (exhausted | recovered | none), RE_COMMIT whether the
# leg commits, RE_EXIT the process exit, RE_STOP the session file's last
# turn's stopReason. The stub's stdout IS the run's events.jsonl, so the
# retry events it prints are what the check reads.
retry_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-pi-retry.XXXXXX)"
tmpdirs+=("$retry_stub")
cat > "$retry_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
is_pi_leg=0
for a in "$@"; do
    [[ "$a" == "--exec" ]] && is_pi_leg=1
done
clone_dir=""
for a in "$@"; do
    [[ -d "$a/.git" ]] && clone_dir="$a"
done
cat >/dev/null
if (( is_pi_leg )); then
    if [[ "${RE_COMMIT:-0}" == "1" ]]; then
        git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            -C "$clone_dir" commit --allow-empty -q -m "pi retry implement"
    fi
    mkdir -p "$clone_dir/.git/pi-session"
    printf '{"role":"assistant","stopReason":"stop","usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"total":0.001}}}\n' \
        > "$clone_dir/.git/pi-session/session.jsonl"
    case "${RE_STREAM:-exhausted}" in
    exhausted)
        printf '{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}\n'
        printf '{"type":"auto_retry_end","success":false,"attempt":3,"finalError":"529 overloaded_error: Overloaded"}\n'
        ;;
    recovered)
        printf '{"type":"auto_retry_end","success":false,"attempt":1}\n'
        printf '{"type":"auto_retry_end","success":true,"attempt":2}\n'
        ;;
    esac
    if [[ "${RE_STOP:-stop}" == "error" ]]; then
        printf '{"role":"assistant","stopReason":"error","errorMessage":"context length exceeded"}\n' \
            >> "$clone_dir/.git/pi-session/session.jsonl"
    fi
    exit "${RE_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$retry_stub/claude-sandboxed"

retry_cfg="$(mktemp -d)"; tmpdirs+=("$retry_cfg")
install -m 600 /dev/null "$retry_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$retry_cfg/pi.env"

retry_run() {  # $1 branch, $2 optional --review-loop count; sets retry_rc / retry_rd / retry_out
    local extra=()
    [[ -n "${2:-}" ]] && extra=(--review-loop "$2")
    retry_out="$(RE_STREAM="${RE_STREAM:-}" RE_COMMIT="${RE_COMMIT:-0}" \
        RE_EXIT="${RE_EXIT:-0}" RE_STOP="${RE_STOP:-stop}" \
        PATH="$retry_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$retry_cfg" \
        FORK_SANDBOX_BACKEND=fake-image \
        timeout 60 "$launcher" --foreground --harness pi/some-model \
        --branch "$1" ${extra[@]+"${extra[@]}"} "$proj" "$handoff" 2>&1)"
    retry_rc=$?
    retry_rd="$(printf '%s\n' "$retry_out" | sed -n 's/^  run dir:  *//p' | head -1)"
    [[ -n "$retry_rd" ]] && tmpdirs+=("$retry_rd")
}

# 1. Exhausted retries, no commits: the run must fail and say why.
RE_STREAM=exhausted RE_COMMIT=0 \
    retry_run "sandbox-test-pi-retry-exhausted-$$"
if [[ -n "$retry_rd" ]]; then
    check "an exhausted-retries, commitless pi run exits 1" "1" "$retry_rc"
    check "exit-code on disk agrees" "1" "$(cat "$retry_rd/exit-code" 2>/dev/null)"
    contains "the failure is named in the sandbox log" \
        "exhausted its automatic retries" "$(cat "$retry_rd/sandbox.log" 2>/dev/null)"
    contains "the reason reaches the summary as harness_error" \
        "exhausted its automatic retries" \
        "$(jq -r '.harness_error // empty' "$retry_rd/summary.json" 2>/dev/null)"
else
    no "an exhausted-retries, commitless pi run produced a run directory" \
        "rc=$retry_rc: $retry_out"
fi

# 2. An auto_retry_end failure that a LATER success=true supersedes is a
#    recovered retry: with work committed, the run stays green.
RE_STREAM=recovered RE_COMMIT=1 \
    retry_run "sandbox-test-pi-retry-recovered-$$"
if [[ -n "$retry_rd" ]]; then
    check "a recovered retry with committed work exits 0" "0" "$retry_rc"
    check "exit-code on disk agrees" "0" "$(cat "$retry_rd/exit-code" 2>/dev/null)"
    lacks "a recovered retry is not reported as exhaustion" \
        "exhausted" "$(cat "$retry_rd/sandbox.log" 2>/dev/null)"
else
    no "a recovered-retry pi run produced a run directory" \
        "rc=$retry_rc: $retry_out"
fi

# 3. Regression guard on the pre-existing path, without a review loop:
#    the last stopReason "error" still turns rc 0 into rc 1.
RE_STREAM=none RE_STOP=error \
    retry_run "sandbox-test-pi-retry-stoperror-$$"
if [[ -n "$retry_rd" ]]; then
    check "a final-turn stopReason error still exits 1" "1" "$retry_rc"
    check "exit-code on disk agrees" "1" "$(cat "$retry_rd/exit-code" 2>/dev/null)"
    contains "the model-error line, not the retry line, names this failure" \
        "the session ended in a model error" "$(cat "$retry_rd/sandbox.log" 2>/dev/null)"
else
    no "a stopReason-error pi run produced a run directory" \
        "rc=$retry_rc: $retry_out"
fi

# 4. The process's own non-zero exit is never overwritten: exhausted
#    retries and no commits on top of exit 5 still exit 5.
RE_STREAM=exhausted RE_COMMIT=0 RE_EXIT=5 \
    retry_run "sandbox-test-pi-retry-nonzero-$$"
if [[ -n "$retry_rd" ]]; then
    check "the process's own exit 5 is kept, not turned into 1" "5" "$retry_rc"
    check "exit-code on disk agrees" "5" "$(cat "$retry_rd/exit-code" 2>/dev/null)"
else
    no "an exhausted-retry, exit-5 pi run produced a run directory" \
        "rc=$retry_rc: $retry_out"
fi

# 5. Exhausted retries with work committed: condition 2 is what keeps a
#    recovered run green, so the run stays 0.
RE_STREAM=exhausted RE_COMMIT=1 \
    retry_run "sandbox-test-pi-retry-committed-$$"
if [[ -n "$retry_rd" ]]; then
    check "exhausted retries with committed work exits 0" "0" "$retry_rc"
    check "exit-code on disk agrees" "0" "$(cat "$retry_rd/exit-code" 2>/dev/null)"
    lacks "a run that committed work is not reported as exhaustion" \
        "exhausted" "$(cat "$retry_rd/sandbox.log" 2>/dev/null)"
else
    no "an exhausted-retry, committed pi run produced a run directory" \
        "rc=$retry_rc: $retry_out"
fi

# 6. The review legs gate on commits off base, not the exit code: a
#    retry-exhausted run has zero commits, so the loop still skips with
#    its work-based detail and records the corrected coding exit -- no
#    special-casing of the new failure shape.
RE_STREAM=exhausted RE_COMMIT=0 \
    retry_run "sandbox-test-pi-retry-loop-skip-$$" 1
if [[ -n "$retry_rd" && -f "$retry_rd/review-loop.json" ]]; then
    check "an exhausted, commitless run's review loop skips on work, not exit code" \
        "skipped" "$(jq -r '.ended' "$retry_rd/review-loop.json" 2>/dev/null)"
    contains "the skip says there is nothing to review" \
        "committed nothing" "$(jq -r '.detail' "$retry_rd/review-loop.json" 2>/dev/null)"
    check "the corrected coding exit is recorded in the loop record" \
        "1" "$(jq -r '.coding_exit_code' "$retry_rd/review-loop.json" 2>/dev/null)"
else
    no "an exhausted, commitless run with a review loop produced its record" \
        "rc=$retry_rc: $retry_out"
fi

printf '\n== a pi fix leg that exhausts its retries and commits nothing ==\n'

# The census sibling of the implement-leg check: run_leg\'s accounting reads
# the same session stream with the same last-stopReason check, and the same
# exhaustion shape was invisible to it. A fix leg that ran out of retries
# and committed nothing used to read as a clean exit-0 leg that made no
# progress; it now reads as a failed leg (leg_rc 1), which the loop records
# as a harness error with the reason. A fix leg that exhausted retries but
# still committed is a success, the same condition-2 rule as the implement
# leg\'s check. The loop\'s failure does not rewrite the RUN\'s exit code,
# which stays the coding leg\'s -- the existing harness-error semantics --
# so the observable is the loop record, not the run\'s rc.
fixex_stub="$(mktemp -d /var/tmp/claude-scratch/fs-review-fix-exhausted.XXXXXX)"
tmpdirs+=("$fixex_stub")
cat > "$fixex_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
is_pi_leg=0
session_dir=""
prev=""
for a in "$@"; do
    [[ "$a" == "--exec" ]] && is_pi_leg=1
    [[ "$prev" == "--session-dir" ]] && session_dir="$a"
    prev="$a"
done
clone_dir=""
for a in "$@"; do
    [[ -d "$a/.git" ]] && clone_dir="$a"
done
cat >/dev/null
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
case "$n" in
1)
    # implement leg (pi): commit the work under review
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "fix-exhaust implement"
    ;;
2|4)
    # review legs (claude): findings first, then approval of the fix
    if (( n == 2 )); then
        printf 'FINDINGS\n\nfile.txt:1 not quite right\n\n## Report\nThe review found one issue.\n' \
            > "$clone_dir/.git/review-verdict.md"
    else
        printf 'APPROVED\n\nChecked: the fix.\n\n## Report\nThe branch is sound.\n' \
            > "$clone_dir/.git/review-verdict.md"
    fi
    printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    ;;
3)
    # fix leg (pi): exhausted retries, no commit unless FIX_COMMIT=1
    if [[ "${FIX_COMMIT:-0}" == "1" ]]; then
        git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            -C "$clone_dir" commit --allow-empty -q -m "fix-exhaust fix"
    fi
    printf '{"type":"auto_retry_end","success":false,"attempt":3,"finalError":"529 overloaded_error: Overloaded"}\n'
    ;;
esac
if (( is_pi_leg )); then
    mkdir -p "$session_dir"
    printf '{"role":"assistant","stopReason":"stop","usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"total":0.001}}}\n' \
        > "$session_dir/session.jsonl"
fi
exit 0
STUB
chmod +x "$fixex_stub/claude-sandboxed"

fixex_run() {  # $1 branch; sets fixex_rc / fixex_rd / fixex_out
    fixex_out="$(FIX_COMMIT="${FIX_COMMIT:-0}" \
        PATH="$fixex_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$retry_cfg" \
        FORK_SANDBOX_BACKEND=fake-image FAKE_COUNT_FILE="$1" \
        timeout 60 "$launcher" --foreground --harness pi/some-model \
        --review-loop 2 --review-harness claude \
        --branch "$2" "$proj" "$handoff" 2>&1)"
    fixex_rc=$?
    fixex_rd="$(printf '%s\n' "$fixex_out" | sed -n 's/^  run dir:  *//p' | head -1)"
    [[ -n "$fixex_rd" ]] && tmpdirs+=("$fixex_rd")
}

fixex_countA="$(mktemp)"; tmpdirs+=("$fixex_countA")
fixex_run "$fixex_countA" "sandbox-test-fix-exhausted-$$"
if [[ -n "$fixex_rd" ]]; then
    check "an exhausted, commitless fix leg fails the loop as a harness error" \
        "harness-error" "$(jq -r '.ended' "$fixex_rd/review-loop.json" 2>/dev/null)"
    check "the fix leg's exit in the loop record is 1, not the process's 0" \
        "1" "$(jq -r '.iterations[0].fix_exit' "$fixex_rd/review-loop.json" 2>/dev/null)"
    contains "the loop's detail names the retry exhaustion" \
        "exhausted its automatic retries" \
        "$(jq -r '.detail' "$fixex_rd/review-loop.json" 2>/dev/null)"
    contains "the sandbox log names it too" \
        "the fix leg of iteration 1 exhausted its automatic retries" \
        "$(cat "$fixex_rd/sandbox.log" 2>/dev/null)"
    check "the run's own exit code stays the coding leg's (the existing harness-error rule)" \
        "0" "$fixex_rc"
else
    no "an exhausted fix leg produced a run directory" \
        "rc=$fixex_rc: $fixex_out"
fi

fixex_countB="$(mktemp)"; tmpdirs+=("$fixex_countB")
FIX_COMMIT=1 fixex_run "$fixex_countB" "sandbox-test-fix-recovered-$$"
if [[ -n "$fixex_rd" ]]; then
    check "an exhausted fix leg that committed work still gets reviewed and approved" \
        "approved" "$(jq -r '.ended' "$fixex_rd/review-loop.json" 2>/dev/null)"
    check "the committing fix leg's exit in the loop record stays 0" \
        "0" "$(jq -r '.iterations[0].fix_exit' "$fixex_rd/review-loop.json" 2>/dev/null)"
    check "the run exits 0" "0" "$fixex_rc"
    lacks "a committing fix leg is not reported as exhaustion" \
        "exhausted" "$(cat "$fixex_rd/sandbox.log" 2>/dev/null)"
else
    no "a committing, exhausted fix leg produced a run directory" \
        "rc=$fixex_rc: $fixex_out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
