#!/usr/bin/env bash
# fork-sandbox-authorship-normalize-test.sh — Exercise fs_normalize_authorship,
# the fetch-time authorship rewrite in scripts/fork-sandbox-lib.sh
#
# Usage: tests/fork-sandbox-authorship-normalize-test.sh
#
# fork-sandbox.sh seeds every clone with the origin repo's effective identity
# (see fork-sandbox-clone-test.sh for that half of the contract) and, at fetch
# time, compares each returned commit's author email against that identity
# (grep "unexpected address" in scripts/fork-sandbox.sh). The seeding has
# regressed at least once in the wild, so a mismatch is no longer only
# reported: fs_normalize_authorship rewrites base..branch host-side with
# plumbing only (rev-list, cat-file, commit-tree, update-ref) so the branch
# carries the expected identity before the run's summary renders.
#
# This calls fs_normalize_authorship directly against scratch repos, the same
# level fork-sandbox-clone-test.sh tests fs_make_clone at: the function only
# ever runs against a host-side repo, never a sandboxed clone, so no sandbox
# or fetch machinery is needed to exercise it.
#
# Every case runs against a throwaway global config (GIT_CONFIG_GLOBAL) with
# the system one switched off, so the host's own identity is neither read nor
# written, and the addresses here are under a reserved .invalid domain that
# cannot belong to anyone.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

WANT_NAME="Right Name"
WANT_EMAIL="right@fork-sandbox.invalid"
WRONG_NAME="Wrong Name"
WRONG_EMAIL="wrong@fork-sandbox.invalid"

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

# A global config of the test's own making, standing in for ~/.gitconfig.
# GIT_CONFIG_NOSYSTEM takes /etc out of the picture as well.
scratch="$(mktemp -d)"
tmpdirs+=("$scratch")
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
printf '[init]\n\tdefaultBranch = main\n[user]\n\tname = %s\n\temail = %s\n' \
    "$WANT_NAME" "$WANT_EMAIL" > "$GIT_CONFIG_GLOBAL"

# A fresh repo with one commit (the "base", authored under the expected
# identity — base itself is never in the range fs_normalize_authorship walks,
# so its own authorship never matters, but keeping it correct avoids a red
# herring if a case's mismatch check is ever widened by mistake).
new_repo() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    (cd "$d" && git init -q .) || return 1
    printf 'base\n' > "$d/file.txt"
    (cd "$d" && git add file.txt \
        && git -c user.name="$WANT_NAME" -c user.email="$WANT_EMAIL" \
            commit -q -m base) || return 1
    printf '%s' "$d"
}

# A commit under a specific author identity, with unique content so its tree
# differs from any sibling commit. Prints the new commit's sha.
commit_as() {
    local dir="$1" name="$2" email="$3" msg="$4"
    (
        cd "$dir" || exit 1
        printf '%s %s\n' "$msg" "$RANDOM$RANDOM" >> file.txt
        git add file.txt || exit 1
        git -c user.name="$name" -c user.email="$email" commit -q -m "$msg" || exit 1
    ) || return 1
    (cd "$dir" && git rev-parse HEAD)
}

is_ancestor() {
    git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null
}

printf '== a single mismatched commit, with a Co-Authored-By trailer ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
msg=$'Add awesome feature\n\nThis explains what changed and why, spanning\nmore than one line of body text.\n\nCo-Authored-By: Helper Person <helper@fork-sandbox.invalid>'
old_tip="$(commit_as "$repo" "$WRONG_NAME" "$WRONG_EMAIL" "$msg")"
check "the wrong-author commit was created" "0" "$?"
pre_tree="$(cd "$repo" && git rev-parse "$old_tip^{tree}")"
pre_date="$(cd "$repo" && git log -1 --format=%ad --date=raw "$old_tip")"
pre_body="$(cd "$repo" && git log -1 --format=%B "$old_tip")"

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "one commit rewritten" "1" "$out"
check "the function returns 0" "0" "$rc"

check "the rewritten commit's author email is the expected one" \
    "$WANT_EMAIL" "$(cd "$repo" && git log -1 --format=%ae main)"
check "the rewritten commit's author name is the expected one" \
    "$WANT_NAME" "$(cd "$repo" && git log -1 --format=%an main)"
check "the message body, including the trailer, survives verbatim" \
    "$pre_body" "$(cd "$repo" && git log -1 --format=%B main)"
check "the tree is unchanged" "$pre_tree" "$(cd "$repo" && git rev-parse "main^{tree}")"
check "the author date is unchanged" \
    "$pre_date" "$(cd "$repo" && git log -1 --format=%ad --date=raw main)"
if is_ancestor "$repo" "$old_tip" main; then
    no "the old tip is not an ancestor of the rewritten branch" \
        "$old_tip is still an ancestor of main"
else
    ok "the old tip is not an ancestor of the rewritten branch"
fi

printf '\n== a clean run (already the expected author) ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
commit_as "$repo" "$WANT_NAME" "$WANT_EMAIL" "already correct" >/dev/null
before="$(cd "$repo" && git rev-parse main)"
before_count="$(cd "$repo" && git rev-list --count "$base..main")"

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "no commit is reported as rewritten" "0" "$out"
check "the function returns 0" "0" "$rc"
after="$(cd "$repo" && git rev-parse main)"
check "the branch tip is byte-identical (no rewrite happened)" "$before" "$after"
check "the commit count in range is unchanged" \
    "$before_count" "$(cd "$repo" && git rev-list --count "$base..main")"

printf '\n== a mixed range (one right author, one wrong), right first ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
# "right" here uses a different NAME but the expected email, to prove only
# the email is compared: a correct-email commit must keep its own author
# name verbatim, not get forced to want_name.
commit_as "$repo" "Custom Name" "$WANT_EMAIL" "right change" >/dev/null
commit_as "$repo" "$WRONG_NAME" "$WRONG_EMAIL" "wrong change" >/dev/null

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "exactly one commit rewritten" "1" "$out"
check "the function returns 0" "0" "$rc"
check "subjects survive in the same order" \
    "right change
wrong change" "$(cd "$repo" && git log --reverse --format=%s "$base..main")"
check "the right commit keeps its own author name" \
    "Custom Name" "$(cd "$repo" && git log --reverse --format=%an "$base..main" | head -1)"
check "the right commit keeps the expected email" \
    "$WANT_EMAIL" "$(cd "$repo" && git log --reverse --format=%ae "$base..main" | head -1)"
check "the wrong commit is forced to the expected name" \
    "$WANT_NAME" "$(cd "$repo" && git log --reverse --format=%an "$base..main" | tail -1)"
check "the wrong commit is forced to the expected email" \
    "$WANT_EMAIL" "$(cd "$repo" && git log --reverse --format=%ae "$base..main" | tail -1)"

printf '\n== a mixed range (one right author, one wrong), wrong first ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
commit_as "$repo" "$WRONG_NAME" "$WRONG_EMAIL" "wrong change" >/dev/null
commit_as "$repo" "Custom Name" "$WANT_EMAIL" "right change" >/dev/null

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "exactly one commit rewritten" "1" "$out"
check "the function returns 0" "0" "$rc"
check "subjects survive in the same order" \
    "wrong change
right change" "$(cd "$repo" && git log --reverse --format=%s "$base..main")"
check "the wrong commit is forced to the expected name" \
    "$WANT_NAME" "$(cd "$repo" && git log --reverse --format=%an "$base..main" | head -1)"
check "the wrong commit is forced to the expected email" \
    "$WANT_EMAIL" "$(cd "$repo" && git log --reverse --format=%ae "$base..main" | head -1)"
check "the right commit keeps its own author name" \
    "Custom Name" "$(cd "$repo" && git log --reverse --format=%an "$base..main" | tail -1)"

printf '\n== a range containing a merge commit ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
(cd "$repo" && git checkout -q -b side)
commit_as "$repo" "$WRONG_NAME" "$WRONG_EMAIL" "side change" >/dev/null
(cd "$repo" && git checkout -q main)
(cd "$repo" && git -c user.name="$WANT_NAME" -c user.email="$WANT_EMAIL" \
    merge --no-ff -q -m "Merge side into main" side)
before="$(cd "$repo" && git rev-parse main)"

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "nothing is printed" "" "$out"
check "the function returns 2 (skipped, non-linear)" "2" "$rc"
check "the branch tip is unchanged" "$before" "$(cd "$repo" && git rev-parse main)"

printf '\n== a host with commit.gpgsign enabled ==\n'

repo="$(new_repo)"
base="$(cd "$repo" && git rev-parse HEAD)"
commit_as "$repo" "$WRONG_NAME" "$WRONG_EMAIL" "needs signing off" >/dev/null
# Set gpgsign only after the fixture's own commits exist: unlike commit-tree,
# `git commit` DOES honor commit.gpgsign, so setting this first would make
# fixture setup itself fail (no secret key) before the function under test
# ever runs.
(cd "$repo" && git config commit.gpgsign true)

out="$(fs_normalize_authorship "$repo" main "$base" "$WANT_NAME" "$WANT_EMAIL")"
rc=$?
check "one commit rewritten" "1" "$out"
check "the function returns 0 (commit-tree ignores commit.gpgsign)" "0" "$rc"
tip="$(cd "$repo" && git rev-parse main)"
gpgsig_lines="$(cd "$repo" && git cat-file commit "$tip" | grep -c '^gpgsig ')"
check "the resulting commit carries no gpgsig header" "0" "$gpgsig_lines"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
