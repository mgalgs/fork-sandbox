#!/usr/bin/env bash
# lkml-revise-test.sh — Exercise lkml-revise.sh's harvest/post-v(N+1) logic
# and its three quiet decision points, against a stub fork-sandbox.sh and a
# real (throwaway) git repo.
#
# Usage: tests/lkml-revise-test.sh
#
# Same "stub the external command on PATH" pattern tests/lkml-round-test.sh
# uses, but lkml-revise.sh is the one script in lkml-mode that runs `git
# format-patch` against the REAL repo (never the persona's clone), so this
# test gives it a real, throwaway git repo rather than /nonexistent/project
# -- there is no clone_dir git history to fake around.
#
# Covers:
#   - the happy path: a run that committed, fetched, and left a cover
#     letter posts vN+1 with the real repo's own format-patch output, and
#     harvests the run's reply alongside it -- as the WHOLE series (format-
#     patch'd from the original --base, not vN's tip), not just this
#     round's fixup commits.
#   - commits == 0: the "a version changes nothing" stop condition exits
#     non-zero but still harvests any reply.
#   - fetched != true: same stop condition, the other way it can trip.
#   - commits > 0 but no cover-letter.md: refuses to post, names the
#     branch to read by hand, exits non-zero.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
revise="$repo_dir/scripts/lkml-revise.sh"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed; lkml-revise.sh needs it to read summary.json."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

# A real, throwaway repo for `git format-patch` to run against -- this is
# what --project points at, standing in for the operator's actual repo. It
# has a pre-series base commit distinct from v1's tip, so a test that
# passes the ORIGINAL base as --base (as SKILL.md's step 4 now requires)
# and one that mistakenly passed vN's tip instead would disagree about how
# many patches v2 contains -- see the "whole series" assertion below.
real_repo="$(mktemp -d)"; tmpdirs+=("$real_repo")
git -C "$real_repo" init -q
git -C "$real_repo" config user.email test@example.com
git -C "$real_repo" config user.name "Test"
printf 'this is the trunk the series branches from\n' > "$real_repo/base.txt"
git -C "$real_repo" add base.txt
git -C "$real_repo" commit -q -m "repo: pre-series base"
series_base_sha="$(git -C "$real_repo" rev-parse HEAD)"

printf 'int frob(void) { return 0; }\n' > "$real_repo/frob.c"
git -C "$real_repo" add frob.c
git -C "$real_repo" commit -q -m "frob: add core"

# The branch a persona's run would have fetched back into the real repo --
# built here directly, standing in for what fork-sandbox.sh's own fetch
# step does after a real sandboxed run.
git -C "$real_repo" branch v2-branch -q
git -C "$real_repo" checkout v2-branch -q
printf 'int frob(void) { return 1; }\n' > "$real_repo/frob.c"
git -C "$real_repo" commit -q -am "frob: fix return value"
git -C "$real_repo" checkout - -q

# A minimal v1 series to revise.
work="$(mktemp -d)"; tmpdirs+=("$work")
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
cd "$work" || exit 1
printf 'Add the frobnicator\n\nBody.\n' > cover.txt
mkdir patches
printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff\n' > patches/0001.patch
"$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus >/dev/null 2>&1
patch_id="$("$mailbox" tree widget-frob | awk 'NR==3{print $1}')"
echo "please fix the return value" > q.txt
r1="$("$mailbox" post widget-frob --from linus --reply-to "$patch_id" --file q.txt \
    --tags Changes-requested --harness claude --model opus 2>/dev/null)"

stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")

# Builds a stub fork-sandbox.sh that fabricates one run directory with the
# given summary.json fields and clone_dir contents. Each scenario below
# writes its own stub so commits/fetched/cover-letter can vary.
write_stub() {
    local commits="$1" fetched="$2" write_cover="$3" write_reply="$4"
    cat > "$stub_bin/fork-sandbox.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
run_dir="\$(mktemp -d "$run_prefix_dir/run.XXXXXX")"
clone_dir="\$run_dir/clone/proj"
mkdir -p "\$clone_dir/.git/lkml-out"
STUB
    if [[ "$write_cover" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'Add the return-value fix\n\nv2: fixed frob per linus.\n' > "\$clone_dir/.git/lkml-out/cover-letter.md"
STUB
    fi
    if [[ "$write_reply" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'In-Reply-To: $r1\nX-Tags: Reviewed-by\n\nFixed, see v2.\n' > "\$clone_dir/.git/lkml-out/1.msg"
STUB
    fi
    cat >> "$stub_bin/fork-sandbox.sh" <<STUB
jq -n --arg clone_dir "\$clone_dir" --arg branch "v2-branch" \\
    --argjson commits $commits --argjson fetched $fetched \\
    '{clone_dir: \$clone_dir, branch: \$branch, commits: \$commits, fetched: \$fetched}' \\
    > "\$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  \$run_dir"
STUB
    chmod +x "$stub_bin/fork-sandbox.sh"
}

printf '\n== happy path: commits + fetched + cover letter ==\n'
write_stub 1 true 1 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
check "exits 0 and posts v2" "0" "$rc"
contains "reports harvesting the reply" "$out" "harvested 1 repl"
contains "reports posting v2" "$out" "posted v2"

tree_out="$("$mailbox" tree widget-frob)"
contains "v2 shows up in the tree" "$tree_out" "=== v2 ==="
contains "v2's patch carries the real repo's commit message" "$tree_out" "frob: fix return value"
contains "v2 is posted as the whole series (v1's commit plus this round's fixup), not just the fixup alone" \
    "$tree_out" "PATCH v2 2/2"
contains "linus's Changes-requested was answered with Reviewed-by" \
    "$("$mailbox" tree widget-frob)" "Reviewed-by"

printf '\n== stop condition: commits == 0 ==\n'
write_stub 0 true 0 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero when commits == 0"; else no "exits non-zero when commits == 0" "exit 0"; fi
contains "names the 'changes nothing' stop condition" "$out" "changes nothing"
contains "still harvests the reply even with no commits" "$out" "harvested 1 repl"

printf '\n== stop condition: fetched != true ==\n'
write_stub 1 false 1 0
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero when fetched != true"; else no "exits non-zero when fetched != true" "exit 0"; fi
contains "names the 'changes nothing' stop condition (fetched case)" "$out" "changes nothing"

printf '\n== refusal: commits but no cover letter ==\n'
write_stub 1 true 0 0
n_before=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero with commits but no cover letter"; else no "exits non-zero with commits but no cover letter" "exit 0"; fi
contains "refusal names the branch to read by hand" "$out" "v2-branch"
n_after=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
check "no new version was posted (message count unchanged)" "$n_before" "$n_after"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
