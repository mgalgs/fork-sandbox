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

printf '\n== --maintainer-loop: the built commands (--foreground, stubs) ==\n'

# Real foreground runs with every wrapper stubbed and the backend faked into
# image mode -- the same machinery fork-sandbox-review-harness-test.sh uses.
real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-real-stub.XXXXXX)"
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

new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-maintainer-test.XXXXXX")"
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

proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

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

# A default-harness run: the maintainer command reuses the implement command
# with the model substituted in; a no-maintainer run.sh stays free of the
# tier's variables altogether.
rd_d="$(run_real --harness claude --maintainer-loop 1 --maintainer-model sonnet)" \
    && tmpdirs+=("$rd_d")
if [[ -n "$rd_d" ]]; then
    mnt_line="$(grep '^maintainer_sandbox_cmd=' "$rd_d/run.sh")"
    contains "the default maintainer command reuses the implement wrapper" \
        "/claude-sandboxed " "$mnt_line"
    contains "the default maintainer command carries the maintainer model" \
        "--model sonnet" "$mnt_line"
    check "the runner state names the loop cap" "maintainer_loop_cap=1" \
        "$(grep '^maintainer_loop_cap=' "$rd_d/run.sh")"
fi
rd_nm="$(run_real --harness claude)" && tmpdirs+=("$rd_nm")
if [[ -n "$rd_nm" ]]; then
    # The static runner text mentions the tier (its loop is compiled in for
    # every run); what is emitted only when the loop is on is the STATE --
    # the launcher's column-0 variable assignments.
    if [[ "$(grep -cE '^(maintainer_|mnt_)[a-z_]+=' "$rd_nm/run.sh")" == "0" ]]; then
        ok "a plain run.sh emits no maintainer state"
    else
        no "a plain run.sh emits no maintainer state" \
            "$(grep -E '^(maintainer_|mnt_)[a-z_]+=' "$rd_nm/run.sh")"
    fi
fi

# A named pi-local maintainer harness: a different wrapper, its own model.
rd_p="$(run_real --harness claude --maintainer-loop 1 \
    --maintainer-harness pi-local --maintainer-model some-local-model)" \
    && tmpdirs+=("$rd_p")
if [[ -n "$rd_p" ]]; then
    mnt_line="$(grep '^maintainer_sandbox_cmd=' "$rd_p/run.sh")"
    contains "a pi-local maintainer command uses agent-sandboxed" \
        "/agent-sandboxed " "$mnt_line"
    contains "a pi-local maintainer command carries its own model" \
        "--model some-local-model" "$mnt_line"
fi

# The operator-inbox hook: installed for every claude leg the run has, and
# --maintainer-harness claude is a claude leg even when nothing else in the
# run is. The leg runs claude with the Stop hook that fs_archive_inbox's
# addendum archiving trusts, and its command carries --settings; a run with
# no claude leg anywhere gets neither file.
rd_mc="$(run_real --harness pi-local --model some-local-model \
    --maintainer-loop 1 --maintainer-harness claude --maintainer-model sonnet)" \
    && tmpdirs+=("$rd_mc")
if [[ -n "$rd_mc" ]]; then
    if [[ -f "$rd_mc/inbox/.inbox-hook.sh" && -f "$rd_mc/inbox/.settings.json" ]]; then
        ok "a claude maintainer leg gets the inbox hook and settings"
    else
        no "a claude maintainer leg gets the inbox hook and settings" \
            "$(ls -A "$rd_mc/inbox" 2>/dev/null | tr '\n' ' ')"
    fi
    contains "the maintainer settings file names the hook" \
        "$rd_mc/inbox/.inbox-hook.sh" "$(cat "$rd_mc/inbox/.settings.json" 2>/dev/null)"
    mnt_line="$(grep '^maintainer_sandbox_cmd=' "$rd_mc/run.sh")"
    contains "the claude maintainer command carries the inbox settings" \
        "--settings $rd_mc/inbox/.settings.json" "$mnt_line"
    contains "the claude maintainer command includes hook events" \
        "--include-hook-events" "$mnt_line"
else
    no "a pi-local/claude-maintainer run produced a run directory" "run_real failed"
fi
rd_pl="$(run_real --harness pi-local --model some-local-model \
    --maintainer-loop 1 --maintainer-harness pi-local \
    --maintainer-model some-other-local-model)" \
    && tmpdirs+=("$rd_pl")
if [[ -n "$rd_pl" ]]; then
    if [[ ! -e "$rd_pl/inbox/.inbox-hook.sh" && ! -e "$rd_pl/inbox/.settings.json" ]]; then
        ok "an all-non-claude run installs no inbox hook"
    else
        no "an all-non-claude run installs no inbox hook" \
            "$(ls -A "$rd_pl/inbox" 2>/dev/null | tr '\n' ' ')"
    fi
else
    no "an all-non-claude run produced a run directory" "run_real failed"
fi

printf '\n== --maintainer-loop: the loop, end to end ==\n'

# A four-leg scenario under --maintainer-loop 2: the implement leg commits,
# the first maintainer leg finds problems, the fix leg commits, the second
# maintainer leg approves. The call counter plays the part the stub's
# harness/model split cannot.
mnt2_stub="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-loop2.XXXXXX)"
tmpdirs+=("$mnt2_stub")
cat > "$mnt2_stub/claude-sandboxed" <<'STUB'
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

case "$n" in
1)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "mnt2 implement"
    ;;
2)
    printf 'FINDINGS\n\nfile.txt:1 the new line breaks the invariant it sits next to\n' \
        > "$clone_dir/.git/maintainer-verdict.md"
    ;;
3)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "mnt2 fix"
    ;;
4)
    printf 'APPROVED\n\nChecked: the surrounding callers and the touched file.\n\n## Report\nAll five paragraphs.\n' \
        > "$clone_dir/.git/maintainer-verdict.md"
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$mnt2_stub/claude-sandboxed"

count2="$(mktemp)"; tmpdirs+=("$count2")
out2="$(PATH="$mnt2_stub:$real_stub:$PATH" FAKE_COUNT_FILE="$count2" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --maintainer-loop 2 --maintainer-model sonnet \
    --branch "sandbox-test-mnt2-$$" \
    "$proj" "$handoff" 2>&1)"
rc2=$?
rd2="$(printf '%s\n' "$out2" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rc2 == 0 )) && [[ -n "$rd2" ]]; then
    tmpdirs+=("$rd2")
    ok "the four-leg maintainer run exits 0"
    check "four legs ran: implement, maintainer, fix, maintainer" "4" \
        "$(cat "$count2")"
    check "the loop ended approved" "approved" \
        "$(jq -r '.ended' "$rd2/maintainer-loop.json")"
    check "the record names the cap" "2" \
        "$(jq -r '.cap' "$rd2/maintainer-loop.json")"
    check "the record names the model" "sonnet" \
        "$(jq -r '.maintainer_model' "$rd2/maintainer-loop.json")"
    check "the record names the (defaulted) harness" "claude" \
        "$(jq -r '.maintainer_harness' "$rd2/maintainer-loop.json")"
    check "the loop finished two iterations" "2" \
        "$(jq -r '.iterations | length' "$rd2/maintainer-loop.json")"
    check "iteration 1 counted the one cited finding" "1" \
        "$(jq -r '.iterations[0].findings' "$rd2/maintainer-loop.json")"
    check "iteration 1's maintainer leg exited 0" "0" \
        "$(jq -r '.iterations[0].maintainer_exit' "$rd2/maintainer-loop.json")"
    check "iteration 1's fix leg exited 0" "0" \
        "$(jq -r '.iterations[0].fix_exit' "$rd2/maintainer-loop.json")"
    check "iteration 2 approved with no findings" "0" \
        "$(jq -r '.iterations[1].findings' "$rd2/maintainer-loop.json")"
    check "iteration 1's fix added exactly one commit" "1" \
        "$(jq -r '.iterations[0].commits_added' "$rd2/maintainer-loop.json")"
    check "iteration 2 added nothing" "null" \
        "$(jq -r '.iterations[1].commits_added' "$rd2/maintainer-loop.json")"
    for f in maintainer-prompt.md maintainer-prompt-1.md \
        maintainer-prompt-2.md maintainer-verdict-1.md \
        maintainer-verdict-2.md maintainer-fix-prompt-1.md \
        events-maintainer-1.jsonl events-maintainer-2.jsonl \
        events-mntfix-1.jsonl; do
        if [[ -f "$rd2/$f" ]]; then
            ok "run dir holds $f"
        else
            no "run dir holds $f"
        fi
    done
    contains "the maintainer prompt takes the maintainer framing" \
        "the way a maintainer would" "$(cat "$rd2/maintainer-prompt.md")"
    contains "the maintainer prompt names the verdict path" \
        ".git/maintainer-verdict.md" "$(cat "$rd2/maintainer-prompt.md")"
    # This run has no --review-loop, so the prompt must NOT claim an inner
    # review read the diff: the maintainer is the branch's only review.
    contains "a no-review-loop prompt says the maintainer is the first review" \
        "no review has read that diff yet" \
        "$(cat "$rd2/maintainer-prompt.md")"
    contains "a no-review-loop prompt tells the leg to read the diff close" \
        "read the diff close" \
        "$(cat "$rd2/maintainer-prompt.md")"
    if ! grep -q "The inner review" "$rd2/maintainer-prompt-1.md" 2>/dev/null; then
        ok "a no-review-loop prompt embeds no inner-review verdict"
    else
        no "a no-review-loop prompt embeds no inner-review verdict" \
            "$(grep 'The inner review' "$rd2/maintainer-prompt-1.md")"
    fi
    # Iteration 2 must not be handed the static prompt's "no review has
    # read that diff yet -- you are the first review it gets" uncorrected:
    # the first iteration's own verdict is embedded, and only from the
    # second iteration on.
    contains "the second iteration's prompt embeds the first verdict" \
        "## The previous maintainer iteration's verdict" \
        "$(cat "$rd2/maintainer-prompt-2.md")"
    contains "the embedded predecessor verdict is iteration 1's" \
        "file.txt:1 the new line breaks the invariant it sits next to" \
        "$(cat "$rd2/maintainer-prompt-2.md")"
    if ! grep -q "The previous maintainer iteration" "$rd2/maintainer-prompt-1.md" 2>/dev/null; then
        ok "the first iteration's prompt embeds no predecessor verdict"
    else
        no "the first iteration's prompt embeds no predecessor verdict" \
            "$(grep 'The previous maintainer iteration' "$rd2/maintainer-prompt-1.md")"
    fi
    contains "the fix prompt carries the verdict body" \
        "file.txt:1 the new line breaks the invariant it sits next to" \
        "$(cat "$rd2/maintainer-fix-prompt-1.md")"
    # The total now spends maintainer-tier money too, so the line that
    # explains it names that tier, and the summary's value column stays
    # aligned even though 'maintainer:' is the longest label.
    contains "the summary's total names the tiers it includes" \
        "(the session and every review-, maintainer- or continuation leg)" \
        "$(cat "$rd2/summary.txt")"
    # Every label line of the summary header block puts its value at
    # column 12 -- including 'maintainer:', the longest label, which is
    # why it carries no padding at all (and the 'fetched:' wrap
    # continuation below it, at eleven spaces, keeps it).
    misaligned=""
    while IFS= read -r sline; do
        [[ "$sline" =~ ^([a-z]+):(.*)$ ]] || continue
        srest="${BASH_REMATCH[2]}"
        snospace="${srest#"${srest%%[![:space:]]*}"}"
        scol=$(( ${#BASH_REMATCH[1]} + 1 + ${#srest} - ${#snospace} + 1 ))
        (( scol == 12 )) || misaligned+="$sline;"
    done < <(sed -n '/^== fork-sandbox summary ==$/,/^$/p' "$rd2/summary.txt")
    check "the summary's value column aligns at 12 across all labels" \
        "" "$misaligned"    contains "events.jsonl still shows the coding session" \
        '"subtype":"success"' "$(cat "$rd2/events.jsonl")"
    if [[ -f "$rd2/exit-code" ]]; then
        ok "the exit code was published"
    else
        no "the exit code was published"
    fi
else
    no "the four-leg maintainer run exits 0" "rc=$rc2 rd=$rd2: $out2"
fi

# --review-loop and --maintainer-loop together: the static prompt may claim
# the inner review read the diff, and the "findings to build on" it promises
# exist only if the runner carries the review loop's final verdict into the
# per-iteration prompt -- the run dir is never bound into a leg's sandbox.
loop3_stub="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-loop3.XXXXXX)"
tmpdirs+=("$loop3_stub")
cat > "$loop3_stub/claude-sandboxed" <<'STUB'
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

case "$n" in
1)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "loop3 implement"
    ;;
2)
    printf 'FINDINGS\n\nfile.txt:1 the review found a problem\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
3)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "loop3 review fix"
    ;;
4)
    printf 'APPROVED\nChecked: the whole diff line by line.\n\n## Report\nreview report\n' \
        > "$clone_dir/.git/review-verdict.md"
    ;;
5)
    printf 'APPROVED\n\nChecked: the surrounding callers.\n\n## Report\nAll five paragraphs.\n' \
        > "$clone_dir/.git/maintainer-verdict.md"
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$loop3_stub/claude-sandboxed"

count3="$(mktemp)"; tmpdirs+=("$count3")
out3="$(PATH="$loop3_stub:$real_stub:$PATH" FAKE_COUNT_FILE="$count3" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --review-loop 2 --review-model sonnet \
    --maintainer-loop 1 --maintainer-model opus \
    --branch "sandbox-test-loop3-$$" \
    "$proj" "$handoff" 2>&1)"
rc3=$?
rd3="$(printf '%s\n' "$out3" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rc3 == 0 )) && [[ -n "$rd3" ]]; then
    tmpdirs+=("$rd3")
    ok "the five-leg combined run exits 0"
    check "five legs ran: impl, review, fix, review, maintainer" "5" \
        "$(cat "$count3")"
    contains "a review-looped prompt claims the inner review" \
        "an inner review loop has already read that diff line by line" \
        "$(cat "$rd3/maintainer-prompt.md")"
    contains "that prompt names the verdict it will be given" \
        "verdict is appended to this prompt" \
        "$(cat "$rd3/maintainer-prompt.md")"
    contains "the per-iter prompt embeds the inner review's verdict" \
        "## The inner review's final verdict" \
        "$(cat "$rd3/maintainer-prompt-1.md")"
    contains "the embedded verdict is the loop's final one" \
        "Its verdict from iteration 2 is below" \
        "$(cat "$rd3/maintainer-prompt-1.md")"
    contains "the embedded verdict carries the review leg's account" \
        "Checked: the whole diff line by line." \
        "$(cat "$rd3/maintainer-prompt-1.md")"
else
    no "the five-leg combined run exits 0" "rc=$rc3 rd=$rd3: $out3"
fi

# A branch with no commits skips the loop, and says why.
rd_s="$(run_real --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-mnt-skip-$$")" && tmpdirs+=("$rd_s")
if [[ -n "$rd_s" ]]; then
    check "a commitless branch skips the maintainer loop" "skipped" \
        "$(jq -r '.ended' "$rd_s/maintainer-loop.json")"
    contains "the skip says why" "holds no commits" \
        "$(jq -r '.detail' "$rd_s/maintainer-loop.json")"
    if [[ ! -e "$rd_s/events-maintainer-1.jsonl" ]]; then
        ok "a skipped loop runs no maintainer leg"
    else
        no "a skipped loop runs no maintainer leg"
    fi
    check "a skipped loop has no iterations" "0" \
        "$(jq -r '.iterations | length' "$rd_s/maintainer-loop.json")"
fi

# A fix leg that commits nothing ends the loop with no-progress: the
# maintainer would only reread the same branch.
mntnp_stub="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-noprog.XXXXXX)"
tmpdirs+=("$mntnp_stub")
cat > "$mntnp_stub/claude-sandboxed" <<'STUB'
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

case "$n" in
1)
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "noprog implement"
    ;;
2)
    printf 'FINDINGS\n\nfile.txt:2 a finding the fix leg will ignore\n' \
        > "$clone_dir/.git/maintainer-verdict.md"
    ;;
3)
    # The fix leg commits nothing.
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$mntnp_stub/claude-sandboxed"

countnp="$(mktemp)"; tmpdirs+=("$countnp")
outnp="$(PATH="$mntnp_stub:$real_stub:$PATH" FAKE_COUNT_FILE="$countnp" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --maintainer-loop 3 --maintainer-model sonnet \
    --branch "sandbox-test-mnt-noprog-$$" \
    "$proj" "$handoff" 2>&1)"
rcnp=$?
rdnp="$(printf '%s\n' "$outnp" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( rcnp == 0 )) && [[ -n "$rdnp" ]]; then
    tmpdirs+=("$rdnp")
    ok "the no-progress run exits 0"
    check "no-progress stopped the loop at one iteration" "1" \
        "$(jq -r '.iterations | length' "$rdnp/maintainer-loop.json")"
    check "no-progress is recorded as the end" "no-progress" \
        "$(jq -r '.ended' "$rdnp/maintainer-loop.json")"
    check "three legs ran: implement, maintainer, fix" "3" "$(cat "$countnp")"
else
    no "the no-progress run exits 0" "rc=$rcnp rd=$rdnp: $outnp"
fi

# A failed session is not reviewed: the loop is skipped, and the session's
# exit code is the run's.
mntfail_stub="$(mktemp -d /var/tmp/claude-scratch/fs-maintainer-fail.XXXXXX)"
tmpdirs+=("$mntfail_stub")
cat > "$mntfail_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 3
STUB
chmod +x "$mntfail_stub/claude-sandboxed"

outf="$(PATH="$mntfail_stub:$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image \
    timeout 60 "$launcher" --foreground --harness claude \
    --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-mnt-fail-$$" \
    "$proj" "$handoff" 2>&1)"
rcf=$?
rdf="$(printf '%s\n' "$outf" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rdf" ]]; then
    tmpdirs+=("$rdf")
    check "a failed session is reported as the run's exit code" "3" \
        "$(cat "$rdf/exit-code")"
    check "a failed session skips the maintainer loop" "skipped" \
        "$(jq -r '.ended' "$rdf/maintainer-loop.json")"
    contains "the skip says the session failed" "exited 3" \
        "$(jq -r '.detail' "$rdf/maintainer-loop.json")"
else
    no "a failed session leaves a run dir" "rc=$rcf: $outf"
fi

printf '\n== maintainer surfacing: summary, run.env, status, run log ==\n'

if [[ -n "$rd2" && -d "$rd2" ]]; then
    contains "run.env records the maintainer harness" \
        "maintainer_harness=claude" "$(cat "$rd2/run.env")"
    contains "run.env records the maintainer model" \
        "maintainer_model=sonnet" "$(cat "$rd2/run.env")"
    contains "run.env records the maintainer cap" \
        "maintainer_loop=2" "$(cat "$rd2/run.env")"
    contains "the summary has the maintainer line" \
        "maintainer:2 iteration(s), ended approved" \
        "$(cat "$rd2/summary.txt")"
    check "summary.json takes the report from the maintainer" "maintainer" \
        "$(jq -r '.report_from' "$rd2/summary.json" 2>/dev/null)"
    st_out="$("$repo_dir/scripts/fork-sandbox-status.sh" "$rd2" 2>&1)"
    contains "status prints the maintainer line" \
        "maintainer:2 iteration(s), ended approved" "$st_out"
    contains "status prints the maintainer report" \
        "== report: maintainer leg 2 (APPROVED) ==" "$st_out"
    contains "status prints the maintainer report body" \
        "All five paragraphs." "$st_out"
    res_out="$("$repo_dir/scripts/fork-sandbox-status.sh" --result "$rd2" 2>&1)"
    contains "--result prints the maintainer report" \
        "== report: maintainer leg 2 (APPROVED) ==" "$res_out"
    check "--json reports the maintainer as report source" "maintainer" \
        "$("$repo_dir/scripts/fork-sandbox-status.sh" --json "$rd2" 2>/dev/null | jq -r '.report_from')"
    mon_out="$(timeout 30 "$repo_dir/scripts/fork-sandbox-status.sh" --monitor "$rd2" 2>&1)"
    contains "--monitor ends with the maintainer marker" \
        "report: maintainer leg 2 (APPROVED)" "$mon_out"
fi

if [[ -n "$rd_s" && -d "$rd_s" ]]; then
    contains "a skipped loop gets its summary line" \
        "maintainer:skipped -- " "$(cat "$rd_s/summary.txt")"
fi

if [[ -n "$rd_nm" && -d "$rd_nm" ]]; then
    # The test project's own name contains "maintainer", so grep the
    # specific line shapes, not the word.
    if [[ "$(grep -c '^maintainer:' "$rd_nm/summary.txt" 2>/dev/null)" == "0"
        && "$(grep -c '^maintainer_' "$rd_nm/run.env" 2>/dev/null)" == "0" ]]; then
        ok "a no-maintainer summary and run.env name no maintainer"
    else
        no "a no-maintainer summary and run.env name no maintainer" \
            "$(grep -h '^maintainer' "$rd_nm/summary.txt" "$rd_nm/run.env" 2>/dev/null)"
    fi
fi

# The durable run log: the maintainer tier is on the record when the run had
# one, and absent when it did not. A scratch HOME keeps the test out of the
# operator's own log.
log_home="$tmp/log-home"
mkdir -p "$log_home"
if [[ -n "$rd2" && -d "$rd2" ]]; then
    HOME="$log_home" python3 "$repo_dir/scripts/sandbox-run-log.py" \
        record --run-dir "$rd2" >/dev/null 2>&1
    check "the run log carries the maintainer loop" "approved" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" 2>/dev/null | jq -r '.maintainer_loop.ended')"
fi
if [[ -n "$rd_nm" && -d "$rd_nm" ]]; then
    HOME="$log_home" python3 "$repo_dir/scripts/sandbox-run-log.py" \
        record --run-dir "$rd_nm" >/dev/null 2>&1
    check "a no-maintainer record has no maintainer key" "null" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" 2>/dev/null | jq -r '.maintainer_loop // null')"
fi

# status.sh on a synthetic run dir: the maintainer report, the review
# report, and their order. The maintainer's verdict outranks the review's
# in the monitor marker; in a finished status both print, maintainer first.
status="$repo_dir/scripts/fork-sandbox-status.sh"
rd_m="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.statusm.XXXXXX)"
tmpdirs+=("$rd_m")
cat > "$rd_m/run.env" <<EOF
version=1
branch=test
origin_repo=/tmp/origin
clone_dir=/tmp/clone
started_at=$(date +%s)
session=sess
EOF
cat > "$rd_m/review-loop.json" <<'EOF'
{"ended":"approved","iterations":[]}
EOF
cat > "$rd_m/maintainer-loop.json" <<'EOF'
{"ended":"approved","iterations":[]}
EOF
printf 'APPROVED\nChecked: the diff.\n\n## Report\nreview body\n' > "$rd_m/review-verdict-1.md"
printf 'APPROVED\nChecked: the branch.\n\n## Report\nmaintainer body\n' > "$rd_m/maintainer-verdict-1.md"
printf 'done\n' > "$rd_m/summary.txt"
printf '0\n' > "$rd_m/exit-code"

out="$("$status" "$rd_m" 2>&1)"
contains "status prints the maintainer report" \
    "== report: maintainer leg 1 (APPROVED) ==" "$out"
contains "status prints the maintainer report body" "maintainer body" "$out"
contains "status still prints the review report" \
    "== report: review leg 1 (APPROVED) ==" "$out"
if [[ "${out%%'== report: maintainer'*}" != "$out" \
    && "${out%%'== report: review leg'*}" == *"maintainer body"* ]]; then
    ok "the maintainer report precedes the review report"
else
    no "the maintainer report precedes the review report" "$out"
fi

out="$("$status" --result "$rd_m" 2>&1)"
if [[ "${out%%'== report: maintainer'*}" != "$out" \
    && "${out%%'== report: review leg'*}" == *"maintainer body"* ]]; then
    ok "--result prints maintainer before review"
else
    no "--result prints maintainer before review" "$out"
fi

mon_out="$(timeout 30 "$status" --monitor "$rd_m" 2>&1)"
contains "the monitor marker prefers the maintainer verdict" \
    "report: maintainer leg 1 (APPROVED)" "$mon_out"

# And a run with only a review loop still reports exactly as before.
rm -f "$rd_m/maintainer-loop.json" "$rd_m"/maintainer-verdict-*.md
out="$("$status" "$rd_m" 2>&1)"
if [[ "$out" == *"== report: review leg 1 (APPROVED) =="* \
    && "$out" != *"maintainer"* ]]; then
    ok "a review-only run prints no maintainer report"
else
    no "a review-only run prints no maintainer report" "$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
