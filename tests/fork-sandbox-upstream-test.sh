#!/usr/bin/env bash
# fork-sandbox-upstream-test.sh — fs_resolve_upstream and fs_apply_upstream
#
# Usage: tests/fork-sandbox-upstream-test.sh
#
# Covers the two shared helpers in fork-sandbox-lib.sh that let fetch-back set
# the upstream on the branch it creates: fs_resolve_upstream decides which
# remote-tracking ref a --checkout (or the caller's own HEAD, or the remote's
# default branch) should hand a fetched branch, and fs_apply_upstream applies
# that decision once the branch has actually landed in the origin repo.
#
# Every case builds its own throwaway bare "remote" and a clone of it, under a
# reserved .invalid identity, so nothing here touches the host's real git
# config or repos.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

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
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) no "$1" "expected to find '$2' in: $3" ;;
    esac
}

scratch="$(mktemp -d)"
tmpdirs+=("$scratch")
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
printf '[init]\n\tdefaultBranch = main\n[user]\n\tname = Test\n\temail = test@fork-sandbox.invalid\n' \
    > "$GIT_CONFIG_GLOBAL"

# A bare "remote" seeded with a commit on main and a branch dev, plus a clone
# of it. The clone is what plays the part of "the origin repo" fork-sandbox
# runs against everywhere else -- it has refs/remotes/origin/{main,dev} and
# refs/remotes/origin/HEAD, and its checked-out main already tracks
# origin/main, exactly as a plain `git clone` leaves it.
new_origin_repo() {
    local remote seed clone
    remote="$(mktemp -d)"; tmpdirs+=("$remote")
    git init -q --bare "$remote" >/dev/null

    seed="$(mktemp -d)"; tmpdirs+=("$seed")
    git clone -q "$remote" "$seed" >/dev/null
    (
        cd "$seed" || exit 1
        echo a > f.txt
        git add f.txt
        git commit -q -m init
        git branch dev
        git push -q origin main dev
    ) || return 1

    clone="$(mktemp -d)"; tmpdirs+=("$clone")
    git clone -q "$remote" "$clone" >/dev/null
    printf '%s\n' "$clone"
}

# fs_resolve_upstream "$repo" "$ref" -> "rc<TAB>stdout<TAB>stderr"
resolve() {
    local repo="$1" ref="$2" errf out rc err
    errf="$(mktemp)"; tmpdirs+=("$errf")
    out="$(fs_resolve_upstream "$repo" "$ref" 2>"$errf")"; rc=$?
    err="$(cat "$errf")"
    printf '%s\t%s\t%s' "$rc" "$out" "$err"
}

printf '== case 1: --checkout resolves to a remote-tracking ref ==\n'
repo="$(new_origin_repo)"
res="$(resolve "$repo" "origin/dev")"
check "rc is 0" "0" "$(cut -f1 <<< "$res")"
check "the remote-tracking ref itself is the upstream" "origin/dev" "$(cut -f2 <<< "$res")"
check "no reason is printed" "" "$(cut -f3 <<< "$res")"

printf '\n== case 2: --checkout resolves to a local branch with an upstream ==\n'
repo="$(new_origin_repo)"
# Not checked out, and not the current HEAD (which is main, tracking
# origin/main): proves this is X's own upstream, not a fallback to HEAD's.
git -C "$repo" branch --track sbx-foo origin/dev >/dev/null
res="$(resolve "$repo" "sbx-foo")"
check "the local branch's own upstream is inherited" "origin/dev" "$(cut -f2 <<< "$res")"

printf '\n== a checkout ref with @ in its name parses correctly ==\n'
repo="$(new_origin_repo)"
git -C "$repo" branch --track 'weird@name' origin/dev >/dev/null
res="$(resolve "$repo" 'weird@name')"
check "the @{upstream} parse is not confused by an @ in the branch name" \
    "origin/dev" "$(cut -f2 <<< "$res")"

printf '\n== case 3: falls through to HEAD'"'"'s own upstream ==\n'
repo="$(new_origin_repo)"
git -C "$repo" branch lonely >/dev/null
res="$(resolve "$repo" "lonely")"
check "a local branch with no upstream of its own falls through" \
    "origin/main" "$(cut -f2 <<< "$res")"

repo="$(new_origin_repo)"
git -C "$repo" tag mytag >/dev/null
res="$(resolve "$repo" "mytag")"
check "a tag falls through to HEAD's upstream" "origin/main" "$(cut -f2 <<< "$res")"

repo="$(new_origin_repo)"
sha="$(git -C "$repo" rev-parse HEAD)"
res="$(resolve "$repo" "$sha")"
check "a bare sha falls through to HEAD's upstream" "origin/main" "$(cut -f2 <<< "$res")"

repo="$(new_origin_repo)"
res="$(resolve "$repo" "")"
check "no --checkout at all uses HEAD's own upstream" "origin/main" "$(cut -f2 <<< "$res")"

printf '\n== case 4: falls through to the remote default branch ==\n'
# The default branch (dev) differs from HEAD's own would-be upstream (main),
# so a hit here cannot be mistaken for case 3 firing instead.
repo="$(new_origin_repo)"
git -C "$repo" checkout -q -b no-upstream-branch >/dev/null
git -C "$repo" remote set-head origin dev >/dev/null
res="$(resolve "$repo" "")"
check "a branch with no upstream falls through to the remote default" \
    "origin/dev" "$(cut -f2 <<< "$res")"

repo="$(new_origin_repo)"
git -C "$repo" checkout -q --detach main >/dev/null
git -C "$repo" remote set-head origin dev >/dev/null
res="$(resolve "$repo" "")"
check "a detached HEAD falls through to the remote default" \
    "origin/dev" "$(cut -f2 <<< "$res")"

printf '\n== case 5: no upstream at all ==\n'
lonely_repo="$(mktemp -d)"; tmpdirs+=("$lonely_repo")
git init -q "$lonely_repo" >/dev/null
(cd "$lonely_repo" && echo a > f.txt && git add f.txt && git commit -q -m init) >/dev/null
res="$(resolve "$lonely_repo" "")"
check "rc is still 0" "0" "$(cut -f1 <<< "$res")"
check "nothing is printed on stdout" "" "$(cut -f2 <<< "$res")"
contains "a one-line reason is printed on stderr" "no" "$(cut -f3 <<< "$res")"

repo="$(new_origin_repo)"
git -C "$repo" checkout -q -b no-upstream-branch >/dev/null
git -C "$repo" remote set-head origin --delete >/dev/null
res="$(resolve "$repo" "")"
check "no default branch either: still no upstream" "" "$(cut -f2 <<< "$res")"
contains "the reason is on stderr" "no" "$(cut -f3 <<< "$res")"

printf '\n== fs_apply_upstream ==\n'

printf -- '-- set --\n'
repo="$(new_origin_repo)"
git -C "$repo" branch target >/dev/null
out="$(fs_apply_upstream "$repo" target origin/dev "")"; rc=$?
check "rc is 0" "0" "$rc"
contains "the success line names the branch and the ref" \
    "upstream of target set to origin/dev" "$out"
check "the upstream is actually set" "origin/dev" \
    "$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name "target@{upstream}")"

printf -- '-- already set: left alone --\n'
repo="$(new_origin_repo)"
git -C "$repo" branch --track target origin/main >/dev/null
out="$(fs_apply_upstream "$repo" target origin/dev "")"; rc=$?
check "rc is 0" "0" "$rc"
contains "the skip line names the existing upstream" "already tracks origin/main" "$out"
check "the original upstream survives, not the proposed one" "origin/main" \
    "$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name "target@{upstream}")"

printf -- '-- the resolved ref has vanished by apply time --\n'
repo="$(new_origin_repo)"
git -C "$repo" branch target >/dev/null
out="$(fs_apply_upstream "$repo" target origin/ghost "")"; rc=$?
check "rc is 0" "0" "$rc"
contains "the skip line names the vanished ref" "origin/ghost no longer exists" "$out"
git -C "$repo" rev-parse --verify --quiet "target@{upstream}" >/dev/null 2>&1 && r=yes || r=no
check "no upstream was set" "no" "$r"

printf -- '-- the branch itself is gone (0-commit removal) --\n'
repo="$(new_origin_repo)"
out="$(fs_apply_upstream "$repo" never-existed origin/dev "")"; rc=$?
check "rc is 0" "0" "$rc"
contains "the skip line says the branch was not found" "branch not found" "$out"

printf -- '-- no upstream was resolved --\n'
repo="$(new_origin_repo)"
git -C "$repo" branch target >/dev/null
out="$(fs_apply_upstream "$repo" target "" "no remote at all")"; rc=$?
check "rc is 0" "0" "$rc"
contains "the skip line carries the reason through" "no remote at all" "$out"
git -C "$repo" rev-parse --verify --quiet "target@{upstream}" >/dev/null 2>&1 && r=yes || r=no
check "no upstream was set" "no" "$r"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
