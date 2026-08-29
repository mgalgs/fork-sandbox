#!/usr/bin/env bash
# lkml-forklift-test.sh — Exercise lkml-forklift.sh's fold logic against a
# real (throwaway) git repo. No fork-sandbox.sh stub is needed here:
# lkml-forklift.sh never launches a persona, it only reads a version's
# branch (already sitting in the real repo) and a cover letter already
# posted via lkml-mailbox.sh init.
#
# Usage: tests/lkml-forklift-test.sh
#
# Covers:
#   - the happy path: --onto has moved (gained a commit of its own, on a
#     file the version never touched) since the version's branch forked off
#     it. The fold must carry BOTH --onto's own new commit AND the version's
#     own change into the result -- not silently drop --onto's work by
#     resetting to the version branch's tree wholesale.
#   - the divergence guard: --onto and the version's branch both edit the
#     SAME line. This must refuse outright, move no ref, and leave --onto's
#     working tree untouched.
#   - --dry-run: prints the commit message and moves no ref.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
forklift="$repo_dir/scripts/lkml-forklift.sh"
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
    echo "SKIP: jq not installed; lkml-forklift.sh needs it."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

# Posts a one-patch cover letter for $1=series --version $2, on top of
# $3=base_sha..$4=branch, into the shared mailbox root -- and appends the
# {version, branch} ledger entry lkml-series.sh/lkml-revise.sh would have
# written.
post_version() {
    local series="$1" version="$2" base_sha="$3" branch="$4" real_repo="$5"
    local patch_dir; patch_dir="$(mktemp -d)"; tmpdirs+=("$patch_dir")
    git -C "$real_repo" format-patch --quiet -o "$patch_dir" "$base_sha..$branch"
    local cover_file; cover_file="$(mktemp)"; tmpdirs+=("$cover_file")
    printf 'v%s cover for %s\n' "$version" "$series" > "$cover_file"
    (cd "$real_repo" && "$mailbox" init "$series" --cover "$cover_file" --patches "$patch_dir" \
        --from author --version "$version" >/dev/null)
    jq -nc --argjson version "$version" --arg branch "$branch" \
        '{version:$version, branch:$branch}' >> "$LKML_MAILBOX_ROOT/$series/versions.jsonl"
}

export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")

# --- happy path: --onto moves on a file the version never touched -------
real_repo="$(mktemp -d)"; tmpdirs+=("$real_repo")
git -C "$real_repo" init -q
git -C "$real_repo" config user.email test@example.com
git -C "$real_repo" config user.name "Test"
printf 'l1\nl2\nl3\n' > "$real_repo/a.txt"
printf 'unrelated\n' > "$real_repo/b.txt"
git -C "$real_repo" add a.txt b.txt
git -C "$real_repo" commit -q -m "repo: base"
base_sha="$(git -C "$real_repo" rev-parse HEAD)"

git -C "$real_repo" checkout -q -b main
printf 'l1\nl2\nl3\nmain moves\n' > "$real_repo/a.txt"
git -C "$real_repo" commit -q -am "main: moves on"

git -C "$real_repo" checkout -q "$base_sha"
git -C "$real_repo" checkout -q -b lkml/happy-v1
printf 'feature stuff\n' > "$real_repo/b.txt"
git -C "$real_repo" commit -q -am "feature: change to b.txt"

post_version happy 1 "$base_sha" lkml/happy-v1 "$real_repo"

git -C "$real_repo" checkout -q main
onto_before="$(git -C "$real_repo" rev-parse main)"
out="$("$forklift" happy --project "$real_repo" --version 1 --onto main 2>&1)"
rc=$?
check "happy path: exits 0" "0" "$rc"
onto_after="$(git -C "$real_repo" rev-parse main)"
if [[ "$onto_after" != "$onto_before" ]]; then ok "main moved forward"; else no "main moved forward" "still at $onto_before"; fi
check "main:a.txt keeps main's OWN change" "l1
l2
l3
main moves" "$(git -C "$real_repo" show main:a.txt)"
check "main:b.txt gets the version's change" "feature stuff" "$(git -C "$real_repo" show main:b.txt)"
check "fold commit has main's original tip as its sole parent" "$onto_before" \
    "$(git -C "$real_repo" rev-parse "main^")"
check "working tree was reset to the new commit (HEAD was main)" "$onto_after" \
    "$(git -C "$real_repo" rev-parse HEAD)"
contains "reports the fold" "$out" "now at $onto_after"

# --- divergence guard: main and the version touch the SAME line ---------
real_repo2="$(mktemp -d)"; tmpdirs+=("$real_repo2")
git -C "$real_repo2" init -q
git -C "$real_repo2" config user.email test@example.com
git -C "$real_repo2" config user.name "Test"
printf 'l1\nl2\nl3\n' > "$real_repo2/a.txt"
git -C "$real_repo2" add a.txt
git -C "$real_repo2" commit -q -m "repo: base"
base_sha2="$(git -C "$real_repo2" rev-parse HEAD)"

git -C "$real_repo2" checkout -q -b main
printf 'l1\nCHANGED-BY-MAIN\nl3\n' > "$real_repo2/a.txt"
git -C "$real_repo2" commit -q -am "main: conflicting change"

git -C "$real_repo2" checkout -q "$base_sha2"
git -C "$real_repo2" checkout -q -b lkml/conflict-v1
printf 'l1\nCHANGED-BY-FEATURE\nl3\n' > "$real_repo2/a.txt"
git -C "$real_repo2" commit -q -am "feature: conflicting change"

post_version conflict 1 "$base_sha2" lkml/conflict-v1 "$real_repo2"

git -C "$real_repo2" checkout -q main
onto_before2="$(git -C "$real_repo2" rev-parse main)"
out2="$("$forklift" conflict --project "$real_repo2" --version 1 --onto main 2>&1)"
rc2=$?
if (( rc2 != 0 )); then ok "divergence: exits non-zero"; else no "divergence: exits non-zero" "exit 0"; fi
contains "divergence: names the refusal" "$out2" "too far"
onto_after2="$(git -C "$real_repo2" rev-parse main)"
check "divergence: main's ref never moved" "$onto_before2" "$onto_after2"
check "divergence: main:a.txt is untouched" "l1
CHANGED-BY-MAIN
l3" "$(git -C "$real_repo2" show main:a.txt)"

# --- --dry-run: prints the message, moves no ref -------------------------
git -C "$real_repo" checkout -q main
onto_before3="$(git -C "$real_repo" rev-parse main)"
post_version happy 2 "$base_sha" lkml/happy-v1 "$real_repo"
out3="$("$forklift" happy --project "$real_repo" --version 2 --onto main --dry-run 2>&1)"
rc3=$?
check "dry-run: exits 0" "0" "$rc3"
contains "dry-run: says no commit created" "$out3" "no commit created"
onto_after3="$(git -C "$real_repo" rev-parse main)"
check "dry-run: main's ref never moved" "$onto_before3" "$onto_after3"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
