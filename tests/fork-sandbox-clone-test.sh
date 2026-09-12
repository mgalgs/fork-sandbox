#!/usr/bin/env bash
# fork-sandbox-clone-test.sh — Exercise fs_make_clone's git-identity seeding,
# and fs_reuse_clone's branch-start behavior
#
# Usage: tests/fork-sandbox-clone-test.sh
#
# Covers fs_make_clone in scripts/fork-sandbox-lib.sh: the clone it builds for
# a sandboxed run has to commit under the ORIGIN repository's identity, not the
# host's global one. `git clone` copies no repo-local config, so a repo whose
# user.email is a local override — the common shape when one machine holds two
# identities — used to yield a clone with no identity of its own, and every
# commit the sandbox made came back authored by whatever ~/.gitconfig said.
# Nothing downstream caught it: cherry-pick and rebase deliberately keep the
# author, so integration carried the wrong address into real history.
#
# Also covers fs_reuse_clone, fs_make_clone's counterpart for a --clone-dir
# target that already exists: it fetches the existing clone's origin remote
# and starts a new branch at the clone's own current HEAD -- the previous
# wake's branch tip -- instead of making a fresh clone. Identity seeding does
# not apply to it: a reused clone already has repo-local identity config from
# when fs_make_clone first created it.
#
# Every case runs against a throwaway global config (GIT_CONFIG_GLOBAL) with
# the system one switched off, so the identities are the test's own: the host's
# is neither read nor written, and the addresses here are under a reserved
# .invalid domain that cannot belong to anyone.
#
# It does NOT cover a sandboxed run end to end. bwrap does not nest, so a run
# cannot be launched from inside one; sourcing the library and calling
# fs_make_clone directly is the level at which the seeding is testable. The
# rest of that path — the global gitconfig copy bound inside the sandbox, the
# fetch back, the summary's author-email check — needs a real run on the host.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

GLOBAL_NAME="Global Identity"
GLOBAL_EMAIL="global@fork-sandbox.invalid"
LOCAL_NAME="Repo Identity"
LOCAL_EMAIL="repo-local@fork-sandbox.invalid"
SEED_EMAIL="seed@fork-sandbox.invalid"

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
# GIT_CONFIG_NOSYSTEM takes /etc out of the picture as well, so what the repo
# resolves to is decided entirely here. init.defaultBranch only silences git's
# hint, which would otherwise land in the output a case asserts is empty.
scratch="$(mktemp -d)"
tmpdirs+=("$scratch")
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
printf '[init]\n\tdefaultBranch = main\n[user]\n\tname = %s\n\temail = %s\n' \
    "$GLOBAL_NAME" "$GLOBAL_EMAIL" > "$GIT_CONFIG_GLOBAL"

# Commit with the identity in the environment rather than in config, so a repo
# can be built and extended even in the case where nothing is configured.
env_commit() {
    local dir="$1" msg="$2"
    (
        cd "$dir" || exit 1
        printf '%s\n' "$msg" >> log.txt
        git add log.txt || exit 1
        GIT_AUTHOR_NAME="Seed" GIT_AUTHOR_EMAIL="$SEED_EMAIL" \
        GIT_COMMITTER_NAME="Seed" GIT_COMMITTER_EMAIL="$SEED_EMAIL" \
            git commit -q -m "$msg" || exit 1
    )
}

# Commit the way a session inside the sandbox does: no identity in the
# environment, so git has to resolve one from config. This is the call that
# went wrong before the seeding existed.
config_commit() {
    local dir="$1" msg="$2"
    (
        cd "$dir" || exit 1
        printf '%s\n' "$msg" >> log.txt
        git add log.txt || exit 1
        git commit -q -m "$msg" || exit 1
    )
}

new_origin() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    (cd "$d" && git init -q .) || return 1
    env_commit "$d" seed || return 1
    printf '%s' "$d"
}

# A path that does not exist yet, which is what fs_make_clone is handed.
new_clone_path() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s/clone' "$d"
}

printf '== a repo-local identity override ==\n'

origin="$(new_origin)"
(cd "$origin" && git config user.name "$LOCAL_NAME" && git config user.email "$LOCAL_EMAIL")
clone="$(new_clone_path)"

out="$(fs_make_clone "$origin" "sandbox/one" "$clone" 2>&1)"
check "fs_make_clone succeeds" "0" "$?"
check "seeding a differing identity is silent" "" "$out"
check "the clone is on the requested branch" \
    "sandbox/one" "$(cd "$clone" && git rev-parse --abbrev-ref HEAD)"
check "the clone resolves the origin email, not the global one" \
    "$LOCAL_EMAIL" "$(cd "$clone" && git config --get user.email)"
check "the clone resolves the origin name, not the global one" \
    "$LOCAL_NAME" "$(cd "$clone" && git config --get user.name)"
# Repo-local scope specifically. A sandboxed run mounts a copy of the host's
# GLOBAL gitconfig at $HOME/.gitconfig inside, and only a local value outranks
# it — seeding at any other scope would be invisible where it has to count.
check "the email is seeded at repo-local scope" \
    "$LOCAL_EMAIL" "$(cd "$clone" && git config --local --get user.email)"

# The property that actually matters, and the one the bug broke: a commit made
# inside the clone, with a global identity in force exactly as there is inside
# the sandbox, is authored by the ORIGIN repository's address. Unseeded, this
# comes out as the global one.
commit_out="$(config_commit "$clone" work 2>&1)"
check "committing in the clone succeeds" "0" "$?"
[[ -z "$commit_out" ]] || printf '        %s\n' "$commit_out"
check "a commit made in the clone carries the origin identity" \
    "$LOCAL_NAME <$LOCAL_EMAIL>" "$(cd "$clone" && git log --format='%an <%ae>' -1)"

printf '\n== a repo with no override ==\n'

# The common case: the repo takes the global identity, so seeding writes back
# the value that was already in force. It has to stay a silent no-op.
origin="$(new_origin)"
clone="$(new_clone_path)"
out="$(fs_make_clone "$origin" "sandbox/two" "$clone" 2>&1)"
check "fs_make_clone succeeds" "0" "$?"
check "the no-op case is silent" "" "$out"
check "the clone still resolves the global identity" \
    "$GLOBAL_EMAIL" "$(cd "$clone" && git config --get user.email)"
check "the global name comes through too" \
    "$GLOBAL_NAME" "$(cd "$clone" && git config --get user.name)"

printf '\n== a machine with no identity configured ==\n'

# git config --get exits non-zero here. Nothing may be written: an empty
# user.email in the clone makes every commit inside the sandbox fail outright,
# which is worse than the unset value git already knows how to complain about.
saved_global="$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_GLOBAL="$scratch/gitconfig-bare"
printf '[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
origin="$(new_origin)"
clone="$(new_clone_path)"
out="$(fs_make_clone "$origin" "sandbox/three" "$clone" 2>&1)"
check "fs_make_clone succeeds with no identity anywhere" "0" "$?"
check "the empty case is silent" "" "$out"
n="$( (cd "$clone" && git config --local --list) | grep -c '^user\.' )"
check "no user.* key is written at all" "0" "$n"
export GIT_CONFIG_GLOBAL="$saved_global"

printf '\n== the rest of the contract ==\n'

# A fourth argument still starts the branch at that commit, and the seeding
# runs on that path as well. Callers pass a sha for --checkout runs.
origin="$(new_origin)"
(cd "$origin" && git config user.email "$LOCAL_EMAIL")
first="$(git -C "$origin" rev-parse --verify --quiet HEAD)"
env_commit "$origin" second >/dev/null 2>&1
clone="$(new_clone_path)"
fs_make_clone "$origin" "sandbox/four" "$clone" "$first" >/dev/null 2>&1
check "a start sha still places the branch" \
    "$first" "$(git -C "$clone" rev-parse --verify --quiet HEAD)"
check "the identity is seeded on that path too" \
    "$LOCAL_EMAIL" "$(cd "$clone" && git config --local --get user.email)"

# Callers exit on a non-zero return, so the failure path must stay non-zero.
clone="$(new_clone_path)"
if fs_make_clone "$scratch/not-a-repo" "sandbox/five" "$clone" >/dev/null 2>&1; then
    no "an unclonable source still returns non-zero"
else
    ok "an unclonable source still returns non-zero"
fi

printf '\n== fs_reuse_clone: branch start point on an existing clone ==\n'

# A "prior wake's" clone: build it with fs_make_clone exactly as the launcher
# does, then commit something in it, the way a coding leg would.
origin="$(new_origin)"
prior_clone="$(new_clone_path)"
fs_make_clone "$origin" "prior-branch" "$prior_clone" >/dev/null 2>&1
config_commit "$prior_clone" "prior wake work" >/dev/null 2>&1
prior_commit="$(git -C "$prior_clone" rev-parse HEAD)"

reuse_out="$(fs_reuse_clone "$prior_clone" "next-branch" 2>&1)"
check "fs_reuse_clone succeeds" "0" "$?"
check "reuse is silent on success" "" "$reuse_out"
check "the new branch is checked out" \
    "next-branch" "$(git -C "$prior_clone" rev-parse --abbrev-ref HEAD)"
check "the new branch starts at the prior wake's own commit" \
    "$prior_commit" "$(git -C "$prior_clone" rev-parse HEAD)"
check "identity config is untouched by reuse (still the origin's)" \
    "$GLOBAL_EMAIL" "$(cd "$prior_clone" && git config --local --get user.email)"

# The fallback path: a --clone-dir target that is a valid git repo but has no
# commits at all (its own HEAD cannot be resolved), the one legitimate way a
# real reused clone could lack a branch tip to start from.
fallback_origin="$(new_origin)"
fallback_sha="$(git -C "$fallback_origin" rev-parse HEAD)"
empty_target="$(mktemp -d)"
tmpdirs+=("$empty_target")
(cd "$empty_target" && git init -q .) >/dev/null 2>&1
git -C "$empty_target" remote add origin "$fallback_origin" >/dev/null 2>&1

fs_reuse_clone "$empty_target" "fallback-branch" "$fallback_sha" >/dev/null 2>&1
check "fs_reuse_clone with an unresolvable HEAD still succeeds" "0" "$?"
check "the fallback sha places the branch" \
    "$fallback_sha" "$(git -C "$empty_target" rev-parse --verify --quiet HEAD)"

# Callers exit on a non-zero return, so a fetch failure (no such origin
# remote) must stay non-zero.
noorigin_target="$(mktemp -d)"
tmpdirs+=("$noorigin_target")
(cd "$noorigin_target" && git init -q .) >/dev/null 2>&1
if fs_reuse_clone "$noorigin_target" "doomed-branch" >/dev/null 2>&1; then
    no "a clone with no origin remote still returns non-zero"
else
    ok "a clone with no origin remote still returns non-zero"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
