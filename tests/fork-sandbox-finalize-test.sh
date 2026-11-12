#!/usr/bin/env bash
# fork-sandbox-finalize-test.sh — Exercise fork-sandbox.sh --finalize-script
# and --finalize-floor: the history step the runner runs after a pipeline's
# last leg, and the checks the runner (not the script) makes on what it did.
#
# Section A: launch refusals and the prompt sentence, via --dry-run and
# stubbed runs. Section B: real --foreground runs, every wrapper stubbed,
# with an exec-ing fake sandbox backend so the finalize script really runs
# against the clone: a successful autosquash, a tree change, a re-rooted
# head, a failing and a hanging script, the skip on no commits, the
# script's environment, and the floor rules. Section C: --cover-only's
# refusals, its base and the guard that fails a leg that changes the branch.
#
# Usage: tests/fork-sandbox-finalize-test.sh

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FORK_SANDBOX_RUN_SOURCE=test

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"

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
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "expected to find '$needle' in: $haystack"
    fi
}

lacks() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "expected NOT to find '$needle' in: $haystack"
    fi
}

launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
mkdir -p "$launcher_home/src" "$launcher_home/.claude/skills/commit-then-review" \
    "$launcher_home/.claude/skills/code-review-portable"

real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-finalize-stub.XXXXXX)"
tmpdirs+=("$real_stub")
# Runs the command it is handed in the work dir: the finalize script and the
# runner's reset really act on the clone.
cat > "$real_stub/sandbox-backend-fake-exec" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
workdir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir) workdir="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
cd "$workdir" || exit 1
# Like the real backends, a banner on stderr before the command runs.
printf 'sandbox-backend-fake-exec: work dir %s\n' "$workdir" >&2
exec "$@"
STUB
# A call-scripted claude-sandboxed stub. Actions:
#   commit-file   one content change, committed as "stub leg <n>".
#   commit-fixup  a content change, then a second one committed as
#                 "fixup! stub leg <n>": what finalize should fold.
#   fixup-of      a content change committed as "fixup! $FAKE_FIXUP_OF".
#   reply         commit-file, plus mail-1.md in the run's outbox.
#   approved      writes the verdict the prompt named.
#   reply-only    mail-1.md in the run's outbox, nothing in the clone.
#   untracked     a new file in the clone, not committed.
#   anything else a plain success.
cat > "$real_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "$@"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done
prompt="$(cat)"
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
action="$(sed -n "${n}p" "$FAKE_SCRIPT" 2>/dev/null)"
verdict_name="$(printf '%s\n' "$prompt" | sed -nE 's#.*\.git/(s[0-9]+-verdict\.md|maintainer-verdict\.md|review-verdict\.md).*#\1#p' | head -1)"
[[ -n "$verdict_name" ]] || verdict_name=review-verdict.md
g() { git -c user.email=t@fork-sandbox.invalid -c user.name=Tester -C "$clone_dir" "$@"; }
case "$action" in
commit-file|reply)
    printf 'line-%s\n' "$n" >> "$clone_dir/file.txt"
    g add file.txt && g commit -q -m "stub leg $n"
    if [[ "$action" == reply ]]; then
        out="$(dirname "$(dirname "$clone_dir")")/outbox"
        mkdir -p "$out" && printf 'Subject: re\n\ndone\n' > "$out/mail-1.md"
    fi
    ;;
commit-fixup)
    printf 'line-%s\n' "$n" >> "$clone_dir/file.txt"
    g add file.txt && g commit -q -m "stub leg $n"
    printf 'fix-%s\n' "$n" >> "$clone_dir/file.txt"
    g add file.txt && g commit -q -m "fixup! stub leg $n"
    ;;
fixup-of)
    printf 'fix-%s\n' "$n" >> "$clone_dir/file.txt"
    g add file.txt && g commit -q -m "fixup! $FAKE_FIXUP_OF"
    ;;
approved)
    printf 'APPROVED\n\nChecked: everything.\n' > "$clone_dir/.git/$verdict_name"
    ;;
reply-only)
    out="$(dirname "$(dirname "$clone_dir")")/outbox"
    mkdir -p "$out" && printf 'Subject: re\n\nrewritten cover\n' > "$out/mail-1.md"
    ;;
untracked)
    printf 'stray\n' > "$clone_dir/stray.txt"
    ;;
esac
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$real_stub"/*

real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")

new_project() {
    local d
    d="$(mktemp -d "$launcher_home/src/fs-finalize-test.XXXXXX")"
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
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-finalize-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"
scripts_dir="$handoff_dir/scripts"
mkdir -p "$scripts_dir"

# The finalize scripts the scenarios run. FIN_MARK names a file the script
# touches, so a test can tell whether it ran at all.
cat > "$scripts_dir/autosquash.sh" <<'EOF'
printf '%s\n%s\n%s\n' "$FS_FINALIZE_BASE" "$FS_FINALIZE_FLOOR" "$FS_FINALIZE_REPLY" > "$FIN_MARK"
GIT_SEQUENCE_EDITOR=true git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    rebase -q -i --autosquash "$FS_FINALIZE_FLOOR"
EOF
# Folds into the commit below the base, whatever floor it was given: what
# the floor permits and descent-from-the-base forbids.
cat > "$scripts_dir/autosquash-below.sh" <<'EOF'
GIT_SEQUENCE_EDITOR=true git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    rebase -q -i --autosquash "$FS_FINALIZE_BASE~1"
EOF
cat > "$scripts_dir/edit.sh" <<'EOF'
printf 'an edit finalize must never make\n' >> file.txt
git add file.txt
git -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q --amend --no-edit
EOF
cat > "$scripts_dir/reroot.sh" <<'EOF'
new="$(git -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit-tree "HEAD^{tree}" -m rerooted)"
git reset -q --hard "$new"
EOF
cat > "$scripts_dir/exit2.sh" <<'EOF'
exit 2
EOF
# Delete the branch ref out from under the restore, with HEAD detached.
cat > "$scripts_dir/delete-ref.sh" <<'EOF'
b="$(git symbolic-ref --short HEAD)"
git checkout -q --detach
git update-ref -d "refs/heads/$b"
EOF
# Detach HEAD and move the branch somewhere else.
cat > "$scripts_dir/move-ref.sh" <<'EOF'
b="$(git symbolic-ref --short HEAD)"
git checkout -q --detach
git branch -f "$b" HEAD~1
EOF
cat > "$scripts_dir/exit124.sh" <<'EOF'
exit 124
EOF
cat > "$scripts_dir/exit137.sh" <<'EOF'
exit 137
EOF
cat > "$scripts_dir/hang.sh" <<'EOF'
sleep 30
EOF
cat > "$scripts_dir/mark.sh" <<'EOF'
: > "$FIN_MARK"
EOF
# The script's own refusal: its first stderr line is the reason.
cat > "$scripts_dir/stderr-refuse.sh" <<'EOF'
printf 'first\a line\nsecond line\n' >&2
exit 1
EOF
cat > "$scripts_dir/stderr-long.sh" <<'EOF'
head -c 600 /dev/zero | tr '\0' x >&2
printf '\n' >&2
exit 2
EOF
# Rewrites the floor commit itself (amends its message), then replays
# everything after it: same tree, but history below the floor changed.
cat > "$scripts_dir/rewrite-floor.sh" <<'EOF'
GIT_SEQUENCE_EDITOR='sed -i "1s/^pick/reword/"' GIT_EDITOR='sed -i "1s/$/ (rewritten)/"' \
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    rebase -q -i --root
EOF

# Launches a stubbed run; prints "<run dir>\t<rc>". $1 is the scripted leg
# actions, the rest launcher arguments.
fin_run() {
    local script_actions="$1"; shift
    local count script_file out rc rd
    count="$(mktemp)"; tmpdirs+=("$count"); rm -f "$count"
    script_file="$(mktemp)"; tmpdirs+=("$script_file")
    printf '%s\n' "$script_actions" > "$script_file"
    out="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_SCRIPT="$script_file" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
        FORK_SANDBOX_BACKEND=fake-exec FS_LEG_RETRY_DELAYS="0 0" \
        timeout 120 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    [[ -n "$rd" ]] && tmpdirs+=("$rd")
    [[ -n "$rd" ]] || printf 'fin_run: no run dir (rc=%s):\n%s\n' "$rc" "$out" >&2
    printf '%s\t%s' "$rd" "$rc"
}

fin_json() { jq -r "$2" "$1/summary.json" 2>/dev/null; }
fin_progress_last() {
    jq -r '.steps[-1] | "\(.action) \(.state) \(.ended)"' "$1/progress.json" 2>/dev/null
}
# Sets $br to a branch name no earlier scenario used (not a $(...) call:
# the counter would only advance in the subshell).
branch_n=0
next_branch() { branch_n=$(( branch_n + 1 )); br="fs-fin-$$-$branch_n"; }

#############################################################################
printf '== A: launch refusals and the prompt sentence ==\n'

dry() {
    HOME="$launcher_home" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
        "$launcher" --dry-run "$@" "$proj" "$handoff"
}
refuses() {
    local label="$1" needle="$2" out; shift 2
    if out="$(dry "$@" 2>&1)"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$out" "$needle"
    fi
}
s="$scripts_dir/mark.sh"
refuses "--finalize-floor without --finalize-script is refused" \
    "--finalize-floor only applies with --finalize-script" \
    --pipeline csonnet-ropus --finalize-floor "$(git -C "$proj" rev-parse HEAD)"
for bad_floor in abc "$(printf '%039d' 0)" "$(printf '%041d' 0)" \
    "$(git -C "$proj" rev-parse HEAD | tr a-f A-F)"; do
    refuses "--finalize-floor '$bad_floor' is refused by shape" \
        "--finalize-floor takes a full lowercase commit sha" \
        --pipeline csonnet-ropus --finalize-script "$s" --finalize-floor "$bad_floor"
done
refuses "a missing finalize script is refused" "is not a readable regular file" \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/nosuch.sh"
: > "$scripts_dir/empty.sh"
refuses "an empty finalize script is refused" "is empty" \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/empty.sh"
head -c 65537 /dev/zero | tr '\0' '#' > "$scripts_dir/big.sh"
refuses "a finalize script over 64 KiB is refused" "the limit is 65536" \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/big.sh"
refuses "--finalize-script on a pipeline with no code step is refused" \
    "--finalize-script needs a --pipeline or --preset run with a" \
    --pipeline ropus --finalize-script "$s" --checkout HEAD
refuses "--finalize-script on --review-only is refused" \
    "--finalize-script needs a --pipeline or --preset run with a" \
    --review-only --checkout HEAD --finalize-script "$s"
refuses "--finalize-script on a plain run with no pipeline is refused" \
    "--finalize-script needs a --pipeline or --preset run with a" \
    --finalize-script "$s"
if dry --pipeline csonnet-ropus --finalize-script "$s" >/dev/null 2>&1; then
    ok "--finalize-script on a code pipeline is accepted"
else
    no "--finalize-script on a code pipeline is accepted" "$(dry --pipeline csonnet-ropus --finalize-script "$s" 2>&1 | tail -3)"
fi
# The stale "--k8s accepts only a legacy-shaped pipeline" wording is gone.
if grep -q "is the one${IFS:0:1}*path that still only accepts a legacy-shaped" "$launcher" \
    || grep -q "Kubernetes still" "$repo_dir/docs/presets.md"; then
    no "the stale legacy-shaped-only --k8s wording is gone"
else
    ok "the stale legacy-shaped-only --k8s wording is gone"
fi

fin_sentence="A finalize step runs after the last leg. Do not rebase or rewrite any commit that existed when you started; make a fix to an existing commit a \`fixup!\` commit, and the finalize step folds it."
next_branch
IFS=$'\t' read -r rd_p _ < <(fin_run $'commit-file\napproved\napproved' \
    --pipeline csonnet-ropus-ropus --finalize-script "$s" --branch "$br")
if [[ -n "$rd_p" ]]; then
    check "addendum sentence: in exactly the code leg, its continuation and the fix headers" \
        "2-fix-prompt-header.md 3-fix-prompt-header.md continuation-prompt-header.md handoff.md " \
        "$(grep -l -F -- "$fin_sentence" "$rd_p"/*.md | xargs -r -n1 basename | sort | tr '\n' ' ')"
    check "--finalize-script is staged into the run dir byte for byte" \
        "$(cat "$s")" "$(cat "$rd_p/finalize.sh" 2>/dev/null)"
    contains "run.sh bakes the finalize script, floor and timeout" \
        "$(grep -E '^finalize_(script|floor|timeout_secs)=' "$rd_p/run.sh" | cut -d= -f1 | tr '\n' ' ')" \
        "finalize_script finalize_floor finalize_timeout_secs"
else
    no "a --finalize-script prompt run launches"
fi
next_branch
IFS=$'\t' read -r rd_np _ < <(fin_run $'commit-file\napproved\napproved' \
    --pipeline csonnet-ropus-ropus --wake-reply --branch "$br")
if [[ -n "$rd_np" ]]; then
    check "without --finalize-script no prompt carries the sentence, --wake-reply or not" "" \
        "$(grep -l -F -- "A finalize step runs after the last leg" "$rd_np"/*.md | tr '\n' ' ')"
    lacks "without --finalize-script run.sh carries no finalize key" \
        "$(cat "$rd_np/run.sh")" "finalize_script="
    check "without --finalize-script summary.json has no finalize key" "false" \
        "$(fin_json "$rd_np" 'has("finalize")')"
else
    no "a run without --finalize-script launches"
fi

#############################################################################
printf '\n== B: the finalize step at run time ==\n'

export FIN_MARK="$handoff_dir/fin-mark"
base="$(git -C "$proj" rev-parse HEAD)"

# A successful autosquash folds the fixup; the fetched-back branch has one
# commit above the base, with the reviewed tree.
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-fixup\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/autosquash.sh" --branch "$br")
check "autosquash: the run exits 0" "0" "$rc"
check "autosquash: summary records ran with exit 0" "ran 0" \
    "$(fin_json "$rd" '"\(.finalize.ended) \(.finalize.exit)"')"
check "autosquash: the published branch has one commit above the base" "1" \
    "$(git -C "$proj" rev-list --count "$base..$br" 2>/dev/null)"
check "autosquash: head_after is the published head" \
    "$(git -C "$proj" rev-parse "$br" 2>/dev/null)" "$(fin_json "$rd" '.finalize.head_after')"
check "autosquash: the tree is the reviewed one" \
    "$(git -C "$proj" rev-parse "$(fin_json "$rd" '.finalize.head_before')^{tree}" 2>/dev/null)" \
    "$(git -C "$proj" rev-parse "$br^{tree}" 2>/dev/null)"
check "autosquash: progress.json ends with a done finalize step" "finalize done ran" \
    "$(fin_progress_last "$rd")"
check "autosquash: finalize.log is kept" "yes" "$([[ -f "$rd/finalize.log" ]] && echo yes)"
check "env: FS_FINALIZE_BASE is the run's base" "$(fin_json "$rd" '.base_sha')" "$(sed -n 1p "$FIN_MARK")"
check "env: FS_FINALIZE_FLOOR is the base when no floor is given" "$base" "$(sed -n 2p "$FIN_MARK")"
check "env: FS_FINALIZE_REPLY is empty when the outbox has no reply" "" "$(sed -n 3p "$FIN_MARK")"
check "floor: absent floor is null in summary" "null" "$(fin_json "$rd" '.finalize.floor')"

rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'reply\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/autosquash.sh" --branch "$br")
check "env: FS_FINALIZE_REPLY names the outbox's reply" "$rd/outbox/mail-1.md" "$(sed -n 3p "$FIN_MARK")"

# A script that changes the tree is refused and the branch reset.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/edit.sh" --branch "$br")
check "tree change: the run fails" "1" "$rc"
check "tree change: summary records the reason, exit null, restored" "failed|tree differs|null|true" \
    "$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)|\(.finalize.exit)|\(.finalize.clone_restored)"')"
check "tree change: the branch is back at the reviewed head" \
    "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"
check "tree change: exit-code is 1" "1" "$(cat "$rd/exit-code" 2>/dev/null)"
check "tree change: progress.json's finalize step failed" "finalize failed tree differs" \
    "$(fin_progress_last "$rd")"

# A re-rooted head (same tree, no parent) fails descent from the base.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/reroot.sh" --branch "$br")
check "reroot: the run fails" "1" "$rc"
check "reroot: the reason is descent from the base" "head does not descend from the base" \
    "$(fin_json "$rd" '.finalize.detail')"
check "reroot: the branch is back at the reviewed head" \
    "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"

# No commits above the base: skipped, the script never runs.
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'noop\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/mark.sh" --branch "$br")
check "no commits: skipped" "skipped" "$(fin_json "$rd" '.finalize.ended')"
check "no commits: the script never ran" "no" "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"
check "no commits: progress.json's finalize step is skipped" "finalize skipped skipped" \
    "$(fin_progress_last "$rd")"
check "no commits: a review skipped on an empty range is not a dead step" "false" \
    "$(fin_json "$rd" 'has("dead_step")')"

# A nonzero exit fails with the script's own status.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/exit2.sh" --branch "$br")
check "exit 2: the run fails" "1" "$rc"
check "exit 2: summary carries the exit and reason" "failed|the script exited 2|2" \
    "$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)|\(.finalize.exit)"')"
check "exit 2: the branch is the reviewed head" \
    "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"

# A script that deletes the branch ref, or detaches and moves it, still
# ends with the branch at the reviewed head.
for ref_case in delete-ref move-ref; do
    next_branch
    IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
        --pipeline csonnet-ropus --finalize-script "$scripts_dir/$ref_case.sh" --branch "$br")
    check "$ref_case: the run fails, the clone restored" "1|failed|true" \
        "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.clone_restored)"')"
    check "$ref_case: head_after is the reviewed head" \
        "$(fin_json "$rd" '.finalize.head_before')" "$(fin_json "$rd" '.finalize.head_after')"
    check "$ref_case: the branch is the reviewed head" \
        "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"
done

# A script's own 124 or 137 is its exit status, not a timeout.
for own_rc in 124 137; do
    next_branch
    IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
        --pipeline csonnet-ropus --finalize-script "$scripts_dir/exit$own_rc.sh" --branch "$br")
    check "exit $own_rc: summary carries the script's own exit, not a timeout" \
        "1|failed|the script exited $own_rc|$own_rc" \
        "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)|\(.finalize.exit)"')"
done

# A hanging script is killed at the timeout.
start="$(date +%s)"
next_branch
IFS=$'\t' read -r rd rc < <(FORK_SANDBOX_FINALIZE_TIMEOUT_SECS=2 fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/hang.sh" --branch "$br")
check "timeout: the run fails" "1" "$rc"
check "timeout: the reason names the limit, exit null" "the script timed out after 2s|null" \
    "$(fin_json "$rd" '"\(.finalize.detail)|\(.finalize.exit)"')"
check "timeout: the run did not wait for the script" "1" "$(( $(date +%s) - start < 25 ))"

# The floor. The project grows a second commit; the run's base is it, the
# floor its parent. A fix folded into the base commit rewrites it -- below
# the base, above the floor -- and passes.
printf 'b2\n' > "$proj/b2.txt"
git -C "$proj" add b2.txt && git -C "$proj" commit -q -m "b2 work"
floor="$(git -C "$proj" rev-parse HEAD~1)"
base2="$(git -C "$proj" rev-parse HEAD)"
next_branch
rm -f "$FIN_MARK"
IFS=$'\t' read -r rd rc < <(FAKE_FIXUP_OF="b2 work" fin_run $'fixup-of\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/autosquash.sh" \
    --finalize-floor "$floor" --branch "$br")
check "floor: a fold below the base onto the floor passes" "0|ran" \
    "$rc|$(fin_json "$rd" '.finalize.ended')"
check "floor: FS_FINALIZE_FLOOR is the given floor" "$floor" "$(sed -n 2p "$FIN_MARK")"
check "floor: the folded head sits one commit above the floor" "1" \
    "$(git -C "$proj" rev-list --count "$floor..$br" 2>/dev/null)"
check "floor: summary records the floor" "$floor" "$(fin_json "$rd" '.finalize.floor')"

# Same fold with no floor: descent from the base fails, as before.
next_branch
IFS=$'\t' read -r rd rc < <(FAKE_FIXUP_OF="b2 work" fin_run $'fixup-of\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/autosquash-below.sh" --branch "$br")
check "no floor: folding into the base commit is refused" "1|head does not descend from the base" \
    "$rc|$(fin_json "$rd" '.finalize.detail')"
check "no floor: the branch is the reviewed head" "$base2" \
    "$(git -C "$proj" rev-parse "$br~1" 2>/dev/null)"

# Rewriting the floor itself is refused and reset.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/rewrite-floor.sh" \
    --finalize-floor "$floor" --branch "$br")
check "floor: a rewrite below the floor is refused" "1|head does not descend from the floor" \
    "$rc|$(fin_json "$rd" '.finalize.detail')"
check "floor: ... and the branch is reset" \
    "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"

# A floor that is not an ancestor of the base: refused before the script.
orphan="$(git -C "$proj" commit-tree "$(git -C "$proj" rev-parse "HEAD^{tree}")" -m orphan)"
git -C "$proj" update-ref refs/heads/fs-fin-orphan "$orphan"
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/mark.sh" \
    --finalize-floor "$orphan" --branch "$br")
check "floor-not-ancestor: refused with exit null" "1|floor-not-ancestor|null" \
    "$rc|$(fin_json "$rd" '.finalize.detail')|$(fin_json "$rd" '.finalize.exit')"
check "floor-not-ancestor: the script never ran" "no" "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"
check "floor-not-ancestor: the branch is the reviewed head" \
    "$(fin_json "$rd" '.finalize.head_before')" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"

# Finalize runs before the tidy leg snapshots the approved head.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-fixup\napproved\nnoop' \
    --pipeline csonnet-mopus --finalize-script "$scripts_dir/autosquash.sh" --branch "$br")
check "tidy: finalize ran on a maintainer-last run" "0|ran" "$rc|$(fin_json "$rd" '.finalize.ended')"
check "tidy: the tidy leg's approved head is finalize's head" \
    "$(fin_json "$rd" '.finalize.head_after')" "$(fin_json "$rd" '.tidy.head_approved')"

# --checkout makes the base: a composed wake whose gate picked a start sha
# checks it out, and the review range and FS_FINALIZE_BASE start there.
start_sha="$(git -C "$proj" rev-parse HEAD~1)"
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-fixup\napproved' \
    --pipeline csonnet-ropus --checkout "$start_sha" \
    --finalize-script "$scripts_dir/autosquash.sh" --branch "$br")
check "checkout: the run's base is the checked-out sha" "0|$start_sha" "$rc|$(fin_json "$rd" '.base_sha')"
check "checkout: FS_FINALIZE_BASE is the checked-out sha" "$start_sha" "$(sed -n 1p "$FIN_MARK")"
contains "checkout: the review leg reads <sha>...HEAD" \
    "$(cat "$rd"/step-2-prompt-1.md "$rd"/review-prompt-1.md 2>/dev/null)" "    $start_sha...HEAD"
check "checkout: the folded head sits one commit above the sha" "1" \
    "$(git -C "$proj" rev-list --count "$start_sha..$br" 2>/dev/null)"

# A floor that is an ancestor of origin's HEAD but not of the checked-out
# sha is refused by the existing check, against the checkout.
side="$(git -C "$proj" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    commit-tree "$(git -C "$proj" rev-parse "HEAD~1^{tree}")" -p "$(git -C "$proj" rev-parse HEAD~1)" -m side)"
git -C "$proj" update-ref refs/heads/fs-fin-side "$side"
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --checkout "$side" --finalize-script "$scripts_dir/mark.sh" \
    --finalize-floor "$base2" --branch "$br")
check "checkout floor: a floor off the checkout's line is floor-not-ancestor" \
    "1|failed|floor-not-ancestor|null" \
    "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)|\(.finalize.exit)"')"
check "checkout floor: the script never ran" "no" "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"

# The script's first stderr line is recorded, sanitized, as stderr_line;
# finalize.log keeps everything.
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/stderr-refuse.sh" --branch "$br")
check "stderr: the first line, control characters removed" "1|the script exited 1|1|first line" \
    "$rc|$(fin_json "$rd" '"\(.finalize.detail)|\(.finalize.exit)|\(.finalize.stderr_line)"')"
contains "stderr: finalize.log still holds every line" "$(cat "$rd/finalize.log" 2>/dev/null)" "second line"
check "stderr: the capture file is not left behind" "no" \
    "$([[ -e "$rd/finalize-stderr.log" ]] && echo yes || echo no)"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/stderr-long.sh" --branch "$br")
check "stderr: a long line is capped at 500 bytes" "500" \
    "$(fin_json "$rd" '.finalize.stderr_line | length')"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/exit2.sh" --branch "$br")
check "stderr: a script that wrote nothing records null" "null" "$(fin_json "$rd" '.finalize.stderr_line')"
check "stderr: a run with no finalize script run records null" "null" \
    "$(fin_json "$rd_np" '.finalize.stderr_line')"

# A review leg that leaves no verdict ends its step harness-error: finalize
# does not run, as a skip (not a failure), summary.json names the dead step,
# and the run's exit status is what it was.
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\nnoop' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/mark.sh" --branch "$br")
check "dead review: finalize is skipped, naming the dead step" \
    "skipped|step 2 (review) died: harness-error" \
    "$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)"')"
check "dead review: the script never ran" "no" "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"
check "dead review: summary.json records the dead step" "2|review|harness-error" \
    "$(fin_json "$rd" '"\(.dead_step.step)|\(.dead_step.action)|\(.dead_step.ended)"')"
check "dead review: ... with its detail" "true" "$(fin_json "$rd" '.dead_step.detail | type == "string"')"
check "dead review: the run's exit status is unchanged" "0|0" "$rc|$(fin_json "$rd" '.exit_code')"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\nnoop' --pipeline csonnet-mopus --branch "$br")
check "dead maintain: recorded as a maintain step, no finalize key without a script" "2|maintain|false" \
    "$(fin_json "$rd" '"\(.dead_step.step)|\(.dead_step.action)|\(has("finalize"))"')"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run $'commit-file\napproved' \
    --pipeline csonnet-ropus --finalize-script "$scripts_dir/mark.sh" --branch "$br")
check "an approved review records no dead step" "false" "$(fin_json "$rd" 'has("dead_step")')"

#############################################################################
printf '\n== C: --cover-only ==\n'

# A held wake: its base, a reviewed commit above it on a branch, the floor.
cover_base="$(git -C "$proj" rev-parse HEAD)"
cover_floor="$(git -C "$proj" rev-parse HEAD~1)"
printf 'held\n' > "$proj/held.txt"
git -C "$proj" checkout -q -b fs-fin-held
git -C "$proj" add held.txt && git -C "$proj" commit -q -m "held work"
cover_head="$(git -C "$proj" rev-parse HEAD)"
git -C "$proj" checkout -q -
cover_args=(--pipeline csonnet --checkout "$cover_head" --cover-only "$cover_base"
    --finalize-script "$scripts_dir/autosquash.sh" --finalize-floor "$cover_floor")

refuses "--cover-only takes a full sha" "--cover-only takes a full lowercase commit sha" \
    --pipeline csonnet --checkout "$cover_head" --cover-only abc --finalize-script "$s"
refuses "--cover-only needs --checkout" "--cover-only needs --checkout" \
    --pipeline csonnet --cover-only "$cover_base" --finalize-script "$s"
refuses "--cover-only needs --finalize-script" "--cover-only needs --checkout" \
    --pipeline csonnet --checkout "$cover_head" --cover-only "$cover_base"
refuses "--cover-only refuses a pipeline with a review step" "exactly one code step" \
    --pipeline csonnet-ropus --checkout "$cover_head" --cover-only "$cover_base" --finalize-script "$s"
refuses "--cover-only refuses --wake-reply" "exactly one code step" \
    "${cover_args[@]}" --wake-reply
next_branch
cover_refusal="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-exec timeout 120 "$launcher" --foreground --pipeline csonnet \
    --checkout "$cover_head" --cover-only "$orphan" --finalize-script "$s" --branch "$br" \
    "$proj" "$handoff" 2>&1)" && cover_refusal_rc=0 || cover_refusal_rc=$?
check "--cover-only refuses a base the checkout does not descend from" "1" "$cover_refusal_rc"
contains "... and says why" "$cover_refusal" "that the checkout ($cover_head) descends from"

# A leg that only rewrites the reply: finalize runs with the held wake's
# base and floor, on the reviewed head.
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run reply-only "${cover_args[@]}" --branch "$br")
check "cover: a reply-only leg passes and finalize runs" "0|ran" "$rc|$(fin_json "$rd" '.finalize.ended')"
check "cover: FS_FINALIZE_BASE is the held wake's base" "$cover_base" "$(sed -n 1p "$FIN_MARK" 2>/dev/null)"
check "cover: FS_FINALIZE_FLOOR is the held wake's floor" "$cover_floor" "$(sed -n 2p "$FIN_MARK" 2>/dev/null)"
check "cover: FS_FINALIZE_REPLY is the rewritten reply" "$rd/outbox/mail-1.md" "$(sed -n 3p "$FIN_MARK" 2>/dev/null)"
check "cover: the branch is the reviewed head" "$cover_head" "$(git -C "$proj" rev-parse "$br" 2>/dev/null)"
check "cover: summary's base_sha is the held wake's base" "$cover_base" "$(fin_json "$rd" '.base_sha')"
check "cover: run.sh records the start point" "cover_only_start=$cover_head" \
    "$(grep -E '^cover_only_start=' "$rd/run.sh" 2>/dev/null)"
contains "cover: the leg is told to change nothing but the reply" "$(cat "$rd/handoff.md" 2>/dev/null)" \
    "This run is a cover-only retry: the branch is reviewed and final."
lacks "cover: ... and is not told to commit" "$(cat "$rd/handoff.md" 2>/dev/null)" \
    "commit before you end your turn"
lacks "cover: ... nor the fixup sentence" "$(cat "$rd/handoff.md" 2>/dev/null)" \
    "A finalize step runs after the last leg."
check "a run without --cover-only records an empty start" "cover_only_start=''" \
    "$(grep -E '^cover_only_start=' "$rd_np/run.sh" 2>/dev/null)"

# The guard: a leg that commits, or leaves anything in the tree, fails the
# run and finalize never runs.
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run commit-file "${cover_args[@]}" --branch "$br")
check "cover guard: a leg that commits fails the run, finalize skipped" \
    "1|skipped|cover-only: the leg moved HEAD" \
    "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)"')"
check "cover guard: ... and the finalize script never ran" "no" \
    "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"
check "cover guard: ... exit-code is 1" "1" "$(cat "$rd/exit-code" 2>/dev/null)"
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run untracked "${cover_args[@]}" --branch "$br")
check "cover guard: a leg that leaves a file fails the run, finalize skipped" \
    "1|skipped|cover-only: the leg left changes in the tree" \
    "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)"')"
check "cover guard: ... and the finalize script never ran" "no" \
    "$([[ -e "$FIN_MARK" ]] && echo yes || echo no)"

# A persistent seat clone (--clone-dir) keeps what earlier wakes left
# untracked; a cover-only run starts its leg from a clean tree, so a
# leftover does not fail its guard, an ignored file survives, and a file
# the leg itself leaves still fails it.
seat_root="$(mktemp -d /var/tmp/claude-scratch/fs-finalize-seat.XXXXXX)"; tmpdirs+=("$seat_root")
seat_clone="$seat_root/clone"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run reply-only "${cover_args[@]}" --clone-dir "$seat_clone" --branch "$br")
check "cover (seat clone): the first wake makes the clone" "0|ran" "$rc|$(fin_json "$rd" '.finalize.ended')"
printf 'left by an earlier wake\n' > "$seat_clone/leftover.txt"
mkdir -p "$seat_clone/leftover-dir" && printf 'x\n' > "$seat_clone/leftover-dir/f.txt"
printf 'seat-cache.bin\n' >> "$seat_clone/.git/info/exclude"
printf 'cache\n' > "$seat_clone/seat-cache.bin"
rm -f "$FIN_MARK"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run reply-only "${cover_args[@]}" --clone-dir "$seat_clone" --branch "$br")
check "cover (seat clone): untracked leftovers do not fail the guard" "0|ran" \
    "$rc|$(fin_json "$rd" '.finalize.ended')"
check "cover (seat clone): ... they are removed before the leg" "no|no" \
    "$([[ -e "$seat_clone/leftover.txt" ]] && echo yes || echo no)|$([[ -e "$seat_clone/leftover-dir" ]] && echo yes || echo no)"
check "cover (seat clone): ... an ignored file is kept" "cache" "$(cat "$seat_clone/seat-cache.bin" 2>/dev/null)"
printf 'left again\n' > "$seat_clone/leftover.txt"
next_branch
IFS=$'\t' read -r rd rc < <(fin_run untracked "${cover_args[@]}" --clone-dir "$seat_clone" --branch "$br")
check "cover (seat clone): a file the leg leaves still fails the guard" \
    "1|skipped|cover-only: the leg left changes in the tree" \
    "$rc|$(fin_json "$rd" '"\(.finalize.ended)|\(.finalize.detail)"')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
