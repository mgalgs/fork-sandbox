#!/usr/bin/env bash
# fork-sandbox-tidy-test.sh — Exercise the tidy-history leg: the maintain
# step's own history-cleanup pass that runs after the maintainer approves
# the branch, and the prompt wording that tells coding/fix legs who owns
# history cleanup in a given pipeline shape.
#
# It covers:
#   - Section A: fs_tidy_verify, called directly against small scratch
#     repos, with no fork-sandbox.sh launch at all.
#   - Section B: real --foreground launches, every wrapper stubbed, that
#     exercise the prompt wording (R4.x) a plain run and a maintainer-last
#     run give their coding, continuation and fix legs about who cleans up
#     history. The tidy leg itself does not exist yet at this commit, so
#     these runs never reach one.
#
# Usage: tests/fork-sandbox-tidy-test.sh

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

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

# Every real fork-sandbox.sh fixture below runs under this scratch HOME, not
# the operator's: sandbox-run-log.py's archive dir and run log are
# deliberately hardcoded under ~/.claude (no flag can aim them elsewhere),
# so a fixture run under the real HOME appends handoff archives that are
# indistinguishable from an operator's real work. A scratch HOME also
# empties the launcher's ${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/
# fork-sandbox}, so machine config cannot route a fixture run.
export FORK_SANDBOX_RUN_SOURCE=test

#############################################################################
# Section A: fs_tidy_verify, direct against scratch repos. Same level
# tests/fork-sandbox-authorship-normalize-test.sh exercises
# fs_normalize_authorship at: the function only ever runs host-side, never
# against a sandboxed clone, so no launcher or sandbox machinery is needed.
#############################################################################

printf '== fs_tidy_verify: direct ==\n'

tidy_verify_check() {
    # $1 label, $2 expected rc, $3 a substring the printed reason must
    # contain (empty when $2 is 0, where no reason is printed at all),
    # $4.. passed straight to fs_tidy_verify.
    local label="$1" expected_rc="$2" want_reason="$3"; shift 3
    local out rc
    out="$(fs_tidy_verify "$@")"; rc=$?
    if [[ "$rc" != "$expected_rc" ]]; then
        no "$label" "expected rc $expected_rc, got rc $rc (reason: $out)"
        return
    fi
    if [[ -n "$want_reason" ]]; then
        contains "$label" "$want_reason" "$out"
    else
        check "$label" "" "$out"
    fi
}

new_scratch_repo() {
    local d
    d="$(mktemp -d)"
    (cd "$d" && git init -q . && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester)
    printf '%s' "$d"
}

# A shared fixture for most of section A: a base commit, then two more
# commits on "approved", each with its own trailer -- the shape a tidy leg
# squashing a real two-commit branch would be handed.
tv_repo="$(new_scratch_repo)"; tmpdirs+=("$tv_repo")
printf 'base\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m base
tv_base="$(git -C "$tv_repo" rev-parse HEAD)"
printf 'base\nline1\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "c1" -m "" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
printf 'base\nline1\nline2\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "c2" -m "" -m "Some-Other: value"
git -C "$tv_repo" branch approved HEAD
tv_approved_tree="$(git -C "$tv_repo" rev-parse "approved^{tree}")"

# T-A1: a tidy leg that squashes the two commits into one, keeping the same
# tree and copying both trailers onto the single commit, is accepted.
git -C "$tv_repo" checkout -q -b candidate-squash "$tv_base"
git -C "$tv_repo" merge -q --squash approved >/dev/null
git -C "$tv_repo" commit -q -m squashed -m "" \
    -m "Co-Authored-By: Claude <noreply@anthropic.com>" -m "Some-Other: value"
tidy_verify_check "T-A1: a tree- and trailer-preserving squash is accepted" \
    0 "" "$tv_repo" "$tv_base" approved candidate-squash

# T-A2 (R1.4): same tree's content, but one file's mode changed -- the tree
# id covers modes, so this is caught as a tree mismatch, not ignored.
git -C "$tv_repo" checkout -q -b candidate-mode approved
chmod +x "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "mode change only"
tidy_verify_check "T-A2: a mode-only change is rejected as a tree mismatch" \
    1 "tree differs" "$tv_repo" "$tv_base" approved candidate-mode

# T-A3 (R1.5): a candidate with the right tree but no parent at all -- base
# is not an ancestor of it.
tv_rerooted="$(git -C "$tv_repo" commit-tree "$tv_approved_tree" -m reroot)"
git -C "$tv_repo" branch candidate-reroot "$tv_rerooted"
tidy_verify_check "T-A3: a rerooted candidate fails the ancestor check" \
    1 "base is not an ancestor" "$tv_repo" "$tv_base" approved candidate-reroot

# T-A4 (R1.6): a candidate whose tree matches but whose range contains a
# merge commit.
git -C "$tv_repo" checkout -q -b candidate-merge-main "$tv_base"
printf 'base\nline1\nline2\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "same final content"
git -C "$tv_repo" checkout -q -b candidate-merge-side "$tv_base"
git -C "$tv_repo" commit -q --allow-empty -m noop
git -C "$tv_repo" checkout -q candidate-merge-main
git -C "$tv_repo" merge -q candidate-merge-side -m merge --no-ff
tidy_verify_check "T-A4: a merge commit in the range is rejected" \
    1 "merge commit" "$tv_repo" "$tv_base" approved candidate-merge-main

# T-A5 (R2a.1): a candidate that adds a trailer line no approved commit had.
git -C "$tv_repo" checkout -q -b candidate-invented "$tv_base"
git -C "$tv_repo" merge -q --squash approved >/dev/null
git -C "$tv_repo" commit -q -m squashed -m "" \
    -m "Co-Authored-By: Claude <noreply@anthropic.com>" -m "Some-Other: value" \
    -m "Invented-By: nobody asked for this"
tidy_verify_check "T-A5: an invented trailer is rejected" \
    1 "invented trailer: Invented-By: nobody asked for this" \
    "$tv_repo" "$tv_base" approved candidate-invented

# T-A6 (R2a.2): accepted even when a trailer moves to a DIFFERENT commit
# than the one it started on, as long as it still appears somewhere in the
# range -- the check is "every trailer line exists somewhere", not "on the
# same commit".
git -C "$tv_repo" checkout -q -b candidate-swapped "$tv_base"
printf 'base\nline1\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "c1swap" -m "" -m "Some-Other: value"
printf 'base\nline1\nline2\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "c2swap" -m "" \
    -m "Co-Authored-By: Claude <noreply@anthropic.com>"
tidy_verify_check "T-A6: a trailer moved to a different commit is still accepted" \
    0 "" "$tv_repo" "$tv_base" approved candidate-swapped

# T-A7 (R2a.3): a ref that does not resolve returns 2 with a reason, never 0.
tidy_verify_check "T-A7: an unresolvable ref returns 2, not 0" \
    2 "could not resolve" "$tv_repo" "$tv_base" approved does-not-exist-ref

# A second fixture for the loose trailer-shaped-line check: a
# commit whose LAST paragraph mixes an ordinary prose line with a
# `Co-Authored-By` line, which git's own trailer parser skips entirely --
# `%(trailers:only,unfold)` prints nothing for it, so T-A5's check above
# would never see an invented line shaped exactly like this one.
git -C "$tv_repo" checkout -q -b approved-shaped "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome prose.\nCo-Authored-By: Invented <x@y>')"

# T-A8: that same shaped identity line, with no match anywhere in
# approved-shaped, is still caught as invented even though git's own
# parser would not call it a trailer at all.
git -C "$tv_repo" checkout -q -b candidate-shaped-invented "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome other prose.\nCo-Authored-By: Nobody <n@y>')"
tidy_verify_check "T-A8: a trailer-shaped line git's own parser skips is still caught as invented" \
    1 "invented trailer-shaped line: Co-Authored-By: Nobody <n@y>" \
    "$tv_repo" "$tv_base" approved-shaped candidate-shaped-invented

# T-A9: the identical shaped line, verbatim, is accepted -- "appears
# somewhere in the range" is the same rule a real trailer gets.
git -C "$tv_repo" checkout -q -b candidate-shaped-ok "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome prose.\nCo-Authored-By: Invented <x@y>')"
tidy_verify_check "T-A9: the same shaped line already in the approved range is accepted" \
    0 "" "$tv_repo" "$tv_base" approved-shaped candidate-shaped-ok

# T-A10: an ordinary colon-bearing prose line, unique to the candidate side
# and absent from approved-shaped, is never flagged -- its key ("Note")
# does not end in "-by", so it never names an identity in the first place.
# A second prose line ahead of it keeps git's OWN trailer parser from
# treating it as a real trailer either (a lone "Key: value" last paragraph
# IS parsed as one regardless of the key, same as T-A5's "Some-Other:"
# above), so this isolates the new check rather than re-testing the old one.
git -C "$tv_repo" checkout -q -b candidate-prose-colon "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome prose.\nNote: see above.')"
tidy_verify_check "T-A10: an ordinary colon-bearing prose line is never flagged" \
    0 "" "$tv_repo" "$tv_base" approved-shaped candidate-prose-colon

# T-A11: an `Author:`/`Committer:` line is trailer-shaped and names
# an identity just as surely as a `-by` trailer does, but its key does not
# end in "-by" -- the shaped-key filter catches it anyway, alongside T-A8's
# `Co-Authored-By`. Mirrors T-A8's shape exactly, with "Author" as the key.
git -C "$tv_repo" checkout -q -b candidate-shaped-author "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome other prose.\nAuthor: Invented <x@y>')"
tidy_verify_check "T-A11: an Author: identity line git's own parser skips is still caught as invented" \
    1 "invented trailer-shaped line: Author: Invented <x@y>" \
    "$tv_repo" "$tv_base" approved-shaped candidate-shaped-author

# T-A12: `Co-Author:` (no `-by`) names a co-author just as plainly as
# `Co-Authored-By:` does, even though it is neither `-by`-suffixed nor
# exactly `Author`/`Committer`. Mirrors T-A8's shape, with "Co-Author" as
# the key.
git -C "$tv_repo" checkout -q -b candidate-shaped-coauthor "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome other prose.\nCo-Author: Invented <x@y>')"
tidy_verify_check "T-A12: a Co-Author: identity line is still caught as invented" \
    1 "invented trailer-shaped line: Co-Author: Invented <x@y>" \
    "$tv_repo" "$tv_base" approved-shaped candidate-shaped-coauthor

# T-A13: the shaped-line matcher no longer requires a space after the
# colon -- a key packed straight against its value is just as much an
# invented identity as one with the usual space.
git -C "$tv_repo" checkout -q -b candidate-shaped-nospace "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome other prose.\nCo-Authored-By:Invented <x@y>')"
tidy_verify_check "T-A13: a shaped line with no space after the colon is still caught" \
    1 "invented trailer-shaped line: Co-Authored-By:Invented <x@y>" \
    "$tv_repo" "$tv_base" approved-shaped candidate-shaped-nospace

# T-A14: likewise for a shaped line indented with leading whitespace.
git -C "$tv_repo" checkout -q -b candidate-shaped-indented "$tv_base"
printf 'base\nshaped\n' > "$tv_repo/f.txt"
git -C "$tv_repo" add f.txt
git -C "$tv_repo" commit -q -m "$(printf 'shaped change\n\nSome other prose.\n  Co-Authored-By: Invented <x@y>')"
tidy_verify_check "T-A14: an indented shaped line is still caught" \
    1 "invented trailer-shaped line:   Co-Authored-By: Invented <x@y>" \
    "$tv_repo" "$tv_base" approved-shaped candidate-shaped-indented

# T-A15/T-A16: a `git log` that fails outright (corrupt object, a transient
# filesystem error) must reject the rewrite, not read its empty output as
# "no trailers"/"no shaped lines" and pass. A PATH-stubbed git that fails
# only the one subcommand each check is about, otherwise passing straight
# through, exercises this without needing to actually corrupt a repo.
tv_stub_bin="$(mktemp -d)"; tmpdirs+=("$tv_stub_bin")
tv_real_git="$(command -v git)"
cat > "$tv_stub_bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == log ]]; then
    for a in "\$@"; do
        [[ "\$a" == *'trailers:only'* ]] && exit 1
    done
fi
exec "$tv_real_git" "\$@"
STUB
chmod +x "$tv_stub_bin/git"
out="$(PATH="$tv_stub_bin:$PATH" fs_tidy_verify "$tv_repo" "$tv_base" approved candidate-squash)"
rc=$?
check "T-A15: a failed trailer read rejects the rewrite (rc 2, not 0)" "2" "$rc"
contains "T-A15: the reason names the ref the read failed against" \
    "could not read the trailers of candidate-squash" "$out"

cat > "$tv_stub_bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == log ]]; then
    for a in "\$@"; do
        [[ "\$a" == '--format=%B' ]] && exit 1
    done
fi
exec "$tv_real_git" "\$@"
STUB
chmod +x "$tv_stub_bin/git"
out="$(PATH="$tv_stub_bin:$PATH" fs_tidy_verify "$tv_repo" "$tv_base" approved-shaped candidate-prose-colon)"
rc=$?
check "T-A16: a failed commit-body read rejects the rewrite (rc 2, not 0)" "2" "$rc"
contains "T-A16: the reason names the ref the read failed against" \
    "could not read the commit bodies of candidate-prose-colon" "$out"

#############################################################################
# Section A2: fs_tidy_publish, direct -- the create-only publish both the
# runner's own teardown and fork-sandbox-stop.sh's fetch_branch_back
# share, including the race between them: whichever loses must see its
# own work already done, not a false collision.
#############################################################################

printf '== fs_tidy_publish: direct ==\n'
tp_repo="$(new_scratch_repo)"; tmpdirs+=("$tp_repo")
printf 'base\n' > "$tp_repo/f.txt"
git -C "$tp_repo" add f.txt
git -C "$tp_repo" commit -q -m base
tp_sha1="$(git -C "$tp_repo" rev-parse HEAD)"
git -C "$tp_repo" commit -q --allow-empty -m second
tp_sha2="$(git -C "$tp_repo" rev-parse HEAD)"

if fs_tidy_publish "$tp_repo" tp-create "$tp_sha1"; then
    ok "T-A17: fs_tidy_publish creates the branch when it does not exist yet"
else
    no "T-A17: fs_tidy_publish creates the branch when it does not exist yet"
fi
check "T-A17: the branch now names the published sha" \
    "$tp_sha1" "$(git -C "$tp_repo" rev-parse -q --verify tp-create 2>/dev/null)"

# T-A18: the branch already sitting at exactly the sha being published --
# the race `fork-sandbox stop` and the runner's own publish can both land
# in -- is success, not a collision.
git -C "$tp_repo" branch tp-already "$tp_sha1" >/dev/null
if fs_tidy_publish "$tp_repo" tp-already "$tp_sha1"; then
    ok "T-A18: a branch already at exactly the target sha is treated as success"
else
    no "T-A18: a branch already at exactly the target sha is treated as success"
fi
check "T-A18: the branch is untouched" \
    "$tp_sha1" "$(git -C "$tp_repo" rev-parse tp-already)"

# T-A19: a branch that exists at a DIFFERENT sha is a genuine collision.
git -C "$tp_repo" branch tp-collide "$tp_sha2" >/dev/null
if fs_tidy_publish "$tp_repo" tp-collide "$tp_sha1" 2>/dev/null; then
    no "T-A19: a branch at a different sha is refused, not moved"
else
    ok "T-A19: a branch at a different sha is refused, not moved"
fi
check "T-A19: the branch is untouched" \
    "$tp_sha2" "$(git -C "$tp_repo" rev-parse tp-collide)"

#############################################################################
# Section B: real --foreground launches, every wrapper stubbed.
#############################################################################

printf '== prompt wording: who cleans up history (R4) ==\n'

launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
mkdir -p "$launcher_home/src"
# --review-loop/--pipeline with a review step refuses to start unless the
# review kit's skill directories exist under $HOME/.claude/skills.
mkdir -p "$launcher_home/.claude/skills/commit-then-review" \
    "$launcher_home/.claude/skills/code-review-portable"
operator_archive_dir="$HOME/.claude/sandbox-handoffs"

real_stub="$(mktemp -d /var/tmp/claude-scratch/fs-tidy-real-stub.XXXXXX)"
tmpdirs+=("$real_stub")
cat > "$real_stub/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
# A second backend, used for exactly one scenario (R1.9/T-B12a): unlike the
# no-op stub above, this one actually runs the command it is handed --
# standing in for a real bwrap/container backend that successfully resets
# the clone on a discard, same shape as
# tests/fork-sandbox-uncommitted-test.sh's own exec-ing fake backend.
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
exec "$@"
STUB
# A counting, call-scripted claude-sandboxed stub: each call plays the
# action named on the matching line of $FAKE_SCRIPT -- the same scripted-
# by-call-number shape tests/fork-sandbox-preset-test.sh's real_stub uses,
# extended with the tidy leg's own vocabulary:
#   commit        a plain empty commit (an implement/fix/mntfix leg).
#   commit-file   a real content change, committed with a trailer (so a
#                 later squash has an actual tree to preserve or break).
#   findings/approved   writes the verdict file the prompt named.
#   approved-clobber   approves, then -- standing in for an operator or a
#                 second run claiming the same branch name while this run is
#                 in flight -- commits directly onto $FAKE_ORIGIN_REPO's
#                 refs/heads/$FAKE_CLOBBER_BRANCH, so the origin's branch
#                 exists with unrelated content by the time this run tries
#                 to publish into it.
#   squash        resets to FAKE_COMMIT_COUNT commits back and recommits
#                 everything as one commit, copying the trailer forward --
#                 same tree, same trailer, fewer commits: accept.
#   squash-edit   squash, then change the file afterward: tree differs.
#   squash-trailer  squash, but add a trailer no original commit carried.
#   squash-mode   squash, but chmod +x the file afterward: tree differs
#                 (mode only).
#   reroot        commits the CURRENT tree with no parent at all: base is
#                 not an ancestor.
#   plan          a plan leg's own output: writes the run's outbox/plan.md
#                 rather than touching the clone, the same shape
#                 tests/fork-sandbox-preset-test.sh's own plan stub uses.
#   fail          exits 1.
#   hang          sleeps far longer than any --tidy-timeout a test gives
#                 it, so the GNU timeout wrap in run_leg's own tidy branch
#                 has something real to kill.
#   anything else (including unset/blank, i.e. "noop")  a plain success
#                 with no action -- the tidy leg's own escape hatch when
#                 the history already reads well.
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
verdict_name="$(printf '%s\n' "$prompt" | sed -nE 's#.*\.git/(s[0-9]+-verdict\.md|maintainer-verdict\.md).*#\1#p' | head -1)"
[[ -n "$verdict_name" ]] || verdict_name=review-verdict.md

if [[ "$action" == fail ]]; then
    printf 'stub: scripted failure on call %s\n' "$n" >&2
    exit 1
fi
case "$action" in
commit)
    if [[ -z "$clone_dir" ]]; then
        printf 'stub: no clone dir in argv; refusing to commit\n' >&2
        exit 70
    fi
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "stub leg $n"
    ;;
commit-file)
    cc=0
    [[ -f "$FAKE_COMMIT_COUNT" ]] && cc="$(cat "$FAKE_COMMIT_COUNT")"
    cc=$(( cc + 1 ))
    printf '%s' "$cc" > "$FAKE_COMMIT_COUNT"
    printf 'line-%s\n' "$n" >> "$clone_dir/file.txt"
    git -C "$clone_dir" add file.txt
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit -q -m "stub leg $n" -m "" \
        -m "Co-Authored-By: Claude <noreply@anthropic.com>"
    ;;
findings)
    printf 'FINDINGS\n\nfile.txt:1 the stub found a problem\n' \
        > "$clone_dir/.git/$verdict_name"
    ;;
approved)
    printf 'APPROVED\n\nChecked: everything.\n' \
        > "$clone_dir/.git/$verdict_name"
    ;;
approved-clobber)
    printf 'APPROVED\n\nChecked: everything.\n' \
        > "$clone_dir/.git/$verdict_name"
    if [[ -n "${FAKE_ORIGIN_REPO:-}" && -n "${FAKE_CLOBBER_BRANCH:-}" ]]; then
        clobber_tree="$(git -C "$FAKE_ORIGIN_REPO" rev-parse HEAD^{tree})"
        clobber_sha="$(git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            -C "$FAKE_ORIGIN_REPO" commit-tree "$clobber_tree" \
            -m "an unrelated commit that appeared on this branch name while the run was in flight")"
        git -C "$FAKE_ORIGIN_REPO" update-ref \
            "refs/heads/$FAKE_CLOBBER_BRANCH" "$clobber_sha"
    fi
    ;;
squash|squash-edit|squash-trailer|squash-mode)
    base_n="$(cat "$FAKE_COMMIT_COUNT" 2>/dev/null || printf 0)"
    squash_base="$(git -C "$clone_dir" rev-parse "HEAD~$base_n")"
    git -C "$clone_dir" reset -q --soft "$squash_base"
    if [[ "$action" == squash-edit ]]; then
        printf 'an edit the tidy leg should never make\n' >> "$clone_dir/file.txt"
        git -C "$clone_dir" add file.txt
    elif [[ "$action" == squash-mode ]]; then
        chmod +x "$clone_dir/file.txt"
        git -C "$clone_dir" add file.txt
    fi
    squash_msg_args=(-m "" -m "Co-Authored-By: Claude <noreply@anthropic.com>")
    if [[ "$action" == squash-trailer ]]; then
        squash_msg_args+=(-m "Invented-By: nobody asked for this")
    fi
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit -q -m "stub squashed" "${squash_msg_args[@]}"
    ;;
reroot)
    tree="$(git -C "$clone_dir" rev-parse HEAD^{tree})"
    newsha="$(git -C "$clone_dir" commit-tree "$tree" -m "stub reroot")"
    tidy_branch="$(git -C "$clone_dir" symbolic-ref --short HEAD)"
    git -C "$clone_dir" update-ref "refs/heads/$tidy_branch" "$newsha"
    ;;
plan)
    plan_run_dir="$(dirname "$(dirname "$clone_dir")")"
    mkdir -p "$plan_run_dir/outbox"
    printf '# Plan\n\n## Mechanism\n\nStub tidy-plan body.\n' \
        > "$plan_run_dir/outbox/plan.md"
    ;;
hang)
    sleep 600
    ;;
esac

printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$real_stub"/*

real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")
install -m 600 /dev/null "$real_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$real_cfg/pi.env"
printf 'MODEL_ENDPOINT=http://198.51.100.1:8001/v1\n' > "$real_cfg/model.env"

new_project() {
    local d
    d="$(mktemp -d "$launcher_home/src/fs-tidy-test.XXXXXX")"
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
# Always exported so the approved-clobber action can reach the origin repo;
# harmless to every other scenario, which never sets FAKE_CLOBBER_BRANCH and
# so never trips the action's own guard.
export FAKE_ORIGIN_REPO="$proj"
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-tidy-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task TIDY-BRIEF-SENTINEL-7f3a\n' > "$handoff"

prep_stub() {
    # $1 is the scripted actions, one per expected call.
    count="$(mktemp)"; tmpdirs+=("$count")
    script_file="$(mktemp)"; tmpdirs+=("$script_file")
    printf '%s\n' "$1" > "$script_file"
    # commit_count tracks how many commit-file actions a squash/reroot call
    # should measure back from -- allocated fresh per scenario so an
    # earlier scenario's count never leaks into a later one.
    commit_count="$(mktemp)"; tmpdirs+=("$commit_count")
    rm -f "$commit_count"
}

run_stubbed() {
    local out rc rd
    out="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_SCRIPT="$script_file" FAKE_COMMIT_COUNT="$commit_count" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
        FORK_SANDBOX_BACKEND="${FORK_SANDBOX_BACKEND:-fake-image}" \
        FS_LEG_RETRY_DELAYS="${FS_LEG_RETRY_DELAYS:-0 0}" \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$rd" ]]; then
        printf 'run_stubbed failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

# T-B1 (R4.1 only at this commit): a legacy pipeline whose last step is a
# maintain step that approves. --refresh-at builds continuation-prompt-
# header.md without any leg actually refreshing (refresh_enabled is set at
# parse time, the threshold here is never crossed by two cheap stub calls).
prep_stub $'commit\napproved'
if rd1="$(run_stubbed --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --refresh-at 1000 --branch "sandbox-test-tidy-r41-$$")"; then
    tmpdirs+=("$rd1")
    ok "R4.1 setup: a maintainer-last run with one approved iteration exits 0"
    contains "R4.1: handoff.md tells the coding leg to commit at natural points" \
        "Commit at natural points, as soon as that commit's tests pass" \
        "$(cat "$rd1/handoff.md")"
    contains "R4.1: handoff.md tells the coding leg not to curate history" \
        "do not re-split, squash, amend or rebase your own" \
        "$(cat "$rd1/handoff.md")"
    contains "R4.1: handoff.md names the tidy leg as history's owner" \
        "a tidy-history leg on
that step's seat rewrites the commits into logical ones." \
        "$(cat "$rd1/handoff.md")"
    contains "R4.1: continuation-prompt-header.md carries the same maintainer-owner wording" \
        "a tidy-history leg on
that step's seat rewrites the commits into logical ones." \
        "$(cat "$rd1/continuation-prompt-header.md")"
    contains "R4.1: fix-prompt-header.md carries the same maintainer-owner wording" \
        "a tidy-history leg on
that step's seat rewrites the commits into logical ones." \
        "$(cat "$rd1/fix-prompt-header.md")"
else
    no "R4.1 setup: a maintainer-last run with one approved iteration exits 0"
fi

# T-B8 (R2.2/R4.2 at this commit): a pipeline with no maintain step at all.
prep_stub $'commit\napproved'
if rd8="$(run_stubbed --harness claude --review-loop 1 --refresh-at 1000 \
    --branch "sandbox-test-tidy-r42a-$$")"; then
    tmpdirs+=("$rd8")
    ok "R4.2 setup: a review-only-tier run (no maintain step) exits 0"
    contains "R4.2 (no maintain step): handoff.md tells the coding leg the integrator reshapes later" \
        "Whoever integrates this branch squashes or reshapes it then; no leg of
this run will." \
        "$(cat "$rd8/handoff.md")"
    lacks "R4.2 (no maintain step): handoff.md never promises a tidy leg" \
        "tidy-history" "$(cat "$rd8/handoff.md")"
    contains "R4.2 (no maintain step): continuation-prompt-header.md says the same" \
        "Whoever integrates this branch squashes or reshapes it then; no leg of
this run will." \
        "$(cat "$rd8/continuation-prompt-header.md")"
    lacks "R4.2 (no maintain step): continuation-prompt-header.md never promises a tidy leg" \
        "tidy-history" "$(cat "$rd8/continuation-prompt-header.md")"
    contains "R4.2 (no maintain step): fix-prompt-header.md says the same" \
        "Whoever integrates this branch squashes or reshapes it then; no leg of
this run will." \
        "$(cat "$rd8/fix-prompt-header.md")"
    lacks "R4.2 (no maintain step): fix-prompt-header.md never promises a tidy leg" \
        "tidy-history" "$(cat "$rd8/fix-prompt-header.md")"
    # A pipeline with no maintain step at all leaves no tidy trace
    # anywhere -- no tidy.json, no "tidy" key in summary.json, not even a
    # "skipped" one.
    check "R5.1: a run with no maintain step writes no tidy.json" \
        "0" "$( [[ -e "$rd8/tidy.json" ]] && echo 1 || echo 0 )"
    check "R6.1: summary.txt carries no tidy: line at all" "" \
        "$(grep '^tidy:' "$rd8/summary.txt")"
    # Only the launcher's own conditional emission (tidy_sandbox_cmd/
    # tidy_prompt, built beside maintainer_sandbox_cmd/maintainer_prompt,
    # and tidy_timeout_secs, gated the same way) is at stake here -- not
    # the runner's own tidy_ended/tidy_detail/... locals, which are
    # unconditional fork-sandbox-runner.sh text present in every run.sh
    # regardless of pipeline shape, the same way "rc=" or "mode=" are.
    check "R6.1: run.sh carries no launcher-emitted tidy_sandbox_cmd/tidy_prompt/tidy_timeout_secs state" "0" \
        "$(grep -cE '^(tidy_sandbox_cmd|tidy_prompt|tidy_timeout_secs)=' "$rd8/run.sh")"
    check "R5.1: summary.json's tidy key is absent, not present" \
        "false" "$(jq -r 'has("tidy")' "$rd8/summary.json")"
else
    no "R4.2 setup: a review-only-tier run (no maintain step) exits 0"
fi

# T-B10 (R2.3/R4.2 at this commit): a composed pipeline whose maintain step
# is NOT last (a review step follows it) -- eligibility is "the pipeline's
# LAST step is a maintain step", so this run gets the integrator wording
# too, same as a run with no maintain step at all.
prep_stub $'commit\napproved\napproved'
if rd10="$(run_stubbed --pipeline csonnet-msonnet-rsonnet --refresh-at 1000 \
    --branch "sandbox-test-tidy-r42b-$$")"; then
    tmpdirs+=("$rd10")
    ok "R4.2 setup: a composed run whose maintain step is not last exits 0"
    contains "R4.2 (maintain step not last): handoff.md says the integrator reshapes later" \
        "Whoever integrates this branch squashes or reshapes it then; no leg of
this run will." \
        "$(cat "$rd10/handoff.md")"
    lacks "R4.2 (maintain step not last): handoff.md never promises a tidy leg" \
        "tidy-history" "$(cat "$rd10/handoff.md")"
    check "R2.3: the skip detail says the maintain step is not last" \
        "the maintain step is not the pipeline's last step" \
        "$(jq -r '.detail' "$rd10/tidy.json")"
    check "A12: this run DOES carry a tidy: line, since it has a maintain step" \
        "tidy:      skipped (the maintain step is not the pipeline's last step)" \
        "$(grep '^tidy:' "$rd10/summary.txt")"
else
    no "R4.2 setup: a composed run whose maintain step is not last exits 0"
fi

# T-B9 (R4.3 at this commit): a composed pipeline whose last step is maintain
# -- the composed fix header (the maintain step's own fix seat) must carry
# the same maintainer-owner wording as the legacy fix header does. Two code
# steps then maintain, not "code then maintain" alone: the launcher treats
# an exact code/maintain (or code/review/maintain) shape as the legacy fixed
# skeleton, with its own fixed-name files, so this shape is the smallest one
# that is genuinely composed and still ends on a maintain step.
prep_stub $'commit\ncommit\napproved'
if rd9="$(run_stubbed --pipeline csonnet-csonnet-msonnet --branch "sandbox-test-tidy-r43-$$")"; then
    tmpdirs+=("$rd9")
    ok "R4.3 setup: a composed run whose last step is maintain exits 0"
    if [[ -f "$rd9/3-fix-prompt-header.md" ]]; then
        contains "R4.3: the composed maintain step's fix header carries the maintainer-owner wording" \
            "a tidy-history leg on
that step's seat rewrites the commits into logical ones." \
            "$(cat "$rd9/3-fix-prompt-header.md")"
    else
        no "R4.3: the composed maintain step's fix header exists" \
            "$(find "$rd9" -maxdepth 1 -printf '%f ')"
    fi
    ok "R2b.1: the composed maintain step's own tidy command and prompt exist"
    if [[ -f "$rd9/step-3-tidy-prompt.md" ]]; then
        ok "R2b.1: the static composed tidy prompt file exists"
    else
        no "R2b.1: the static composed tidy prompt file exists"
    fi
    contains "R2b.1: run.sh carries the composed tidy command with the step's model" \
        "--model sonnet" "$(grep '^s3tidy_sandbox_cmd=' "$rd9/run.sh")"
    if [[ -f "$rd9/events-s3-tidy-1.jsonl" ]]; then
        ok "R2b.1: the composed tidy leg's own events file (events-s3-tidy-1.jsonl) exists"
    else
        no "R2b.1: the composed tidy leg's own events file (events-s3-tidy-1.jsonl) exists" \
            "$(find "$rd9" -maxdepth 1 -printf '%f ')"
    fi
    check "R2b.1: the composed tidy leg (a plain success, no squash) is recorded unchanged" \
        "unchanged" "$(jq -r '.ended' "$rd9/tidy.json" 2>/dev/null)"
    check "R5.4: fork-sandbox-status.sh's --json surfaces the composed tidy outcome" \
        "unchanged" "$("$repo_dir/scripts/fork-sandbox-status.sh" --json "$rd9" 2>/dev/null | jq -r '.tidy.ended')"
else
    no "R4.3 setup: a composed run whose last step is maintain exits 0"
fi

printf '\n== the tidy leg itself: accepted, discarded, skipped (R1/R2/R2a/R5/R6/R7) ==\n'

# T-B1 (R1.1/R1.2/R2a.2/R3.1/R5.1/R5.2/R5.4/R6.1/R6.2): a maintainer-last
# run whose coding leg makes two real commits, the maintainer approves, and
# the tidy leg squashes them into one, keeping the tree and moving both
# trailers onto the single commit -- accepted. --pipeline csonnet2-msonnet
# (repeat 2 on the code step, then maintain) is still the fixed legacy
# shape (shape classification keys on action/order, not repeat), so this
# gets two separate coding-leg calls -- the only way to get two commits
# out of the legacy code tier at all, with no bare --code-repeat flag.
prep_stub $'commit-file\ncommit-file\napproved\nsquash'
if rdb1="$(run_stubbed --pipeline csonnet2-msonnet \
    --branch "sandbox-test-tidy-b1-$$")"; then
    tmpdirs+=("$rdb1")
    ok "T-B1: a four-call accepted tidy run exits 0"
    check "R1.1/R1.2: the tidy leg is accepted" \
        "accepted" "$(jq -r '.ended' "$rdb1/tidy.json")"
    check "R6.1/R1.2: the tidied branch has exactly one commit" "1" \
        "$(grep '^commits:' "$rdb1/summary.txt" | awk '{print $2}')"
    check "R5.2: the summary prints the tidy line as accepted, at column 12" \
        "tidy:      accepted" "$(grep '^tidy:' "$rdb1/summary.txt")"
    check "R5.1: summary.json's tidy key reports accepted" \
        "accepted" "$(jq -r '.tidy.ended' "$rdb1/summary.json")"
    check "R5.1: summary.json's tidy key carries a head_approved sha" "40" \
        "$(jq -r '.tidy.head_approved | length' "$rdb1/summary.json")"
    check "R6.2: an accepted tidy run still reports zero uncommitted files" "0" \
        "$(jq -r '.uncommitted_files' "$rdb1/summary.json")"
    lacks "R6.2: an accepted tidy run prints no uncommitted-work warning" \
        "could not check the clone for uncommitted work" "$(cat "$rdb1/summary.txt")"
    contains "R3.1: the tidy prompt states one logical change per commit" \
        "One change per commit" "$(cat "$rdb1/tidy-prompt-1.md")"
    contains "R3.1: the tidy prompt forbids a 'fix review finding' message" \
        "fix review finding" "$(cat "$rdb1/tidy-prompt-1.md")"
    contains "R3.1: the tidy prompt forbids a 'per operator' message" \
        "per operator" "$(cat "$rdb1/tidy-prompt-1.md")"
    contains "R3.1: the tidy prompt says not to re-run the suite per commit" \
        "Do not run the project's test suite per commit" "$(cat "$rdb1/tidy-prompt-1.md")"
    contains "R3.1: the tidy prompt names the approved head's sha" \
        "$(jq -r '.tidy.head_approved' "$rdb1/summary.json")" "$(cat "$rdb1/tidy-prompt-1.md")"
else
    no "T-B1: a four-call accepted tidy run exits 0"
fi

# T-B1b: a --k8s pod run never runs the tidy leg. The exact same
# accepted-tidy shape as T-B1 above, but re-run with fetch_back flipped to
# 0 -- the seam a --k8s pod run's own preamble sets, which a local run
# never exercises on its own. Driven the same way the preset suite's own
# fetch_back=0 section does: generate a real run.sh the ordinary way
# (fetch_back=1), then flip that one line and run the SAME script a
# second time, exactly the shape a --k8s launch's preamble would have
# generated it in the first place.
tb1b_branch="sandbox-test-tidy-b1b-$$"
prep_stub $'commit-file\ncommit-file\napproved\nsquash'
if rdb1b="$(run_stubbed --pipeline csonnet2-msonnet --branch "$tb1b_branch")"; then
    tmpdirs+=("$rdb1b")
    check "T-B1b setup: the fetch_back=1 pass actually ran the tidy leg" \
        "accepted" "$(jq -r '.ended' "$rdb1b/tidy.json" 2>/dev/null)"
    sed -i 's/^fetch_back=1$/fetch_back=0/' "$rdb1b/run.sh"
    # Undo the fetch_back=1 pass's own fetch and ref cleanup: a pod's
    # run.sh always starts from a branch that has never reached
    # origin_repo, which this suite's $proj stands in for.
    git -C "$proj" branch -q -D "$tb1b_branch" 2>/dev/null || true
    prep_stub $'commit-file\ncommit-file\napproved\nsquash'
    # shellcheck disable=SC2034  # kept for a human rereading a failure, not asserted on
    rerun_out="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
        FAKE_SCRIPT="$script_file" FAKE_COMMIT_COUNT="$commit_count" \
        FORK_SANDBOX_CONFIG_DIR="$real_cfg" FORK_SANDBOX_BACKEND=fake-image \
        FS_LEG_RETRY_DELAYS="0 0" \
        timeout 60 bash "$rdb1b/run.sh" 2>&1)"
    rerun_rc=$?
    check "T-B1b: fetch_back=0 makes exactly 3 calls, not 4 -- no tidy leg runs" \
        "3" "$(cat "$count" 2>/dev/null)"
    check "T-B1b: summary.txt records the tidy leg as skipped, with the pod reason" \
        "tidy:      skipped (a --k8s pod run does not fetch back; the tidy-history leg's verification and publish are host-side only)" \
        "$(grep '^tidy:' "$rdb1b/summary.txt")"
    check "T-B1b: tidy.json records the skip, same as any other ineligible reason" \
        "skipped" "$(jq -r '.ended' "$rdb1b/tidy.json" 2>/dev/null)"
    check "T-B1b: tidy.json's detail names the pod reason" \
        "a --k8s pod run does not fetch back; the tidy-history leg's verification and publish are host-side only" \
        "$(jq -r '.detail' "$rdb1b/tidy.json" 2>/dev/null)"
    if git -C "$proj" rev-parse --verify -q "$tb1b_branch" >/dev/null 2>&1; then
        no "T-B1b: the branch never crosses into origin_repo on a --k8s pod run" \
            "found $tb1b_branch in $proj (rc=$rerun_rc)"
    else
        ok "T-B1b: the branch never crosses into origin_repo on a --k8s pod run"
    fi
    if [[ -n "$(git -C "$proj" for-each-ref 'refs/fork-sandbox/tidy/*' 2>/dev/null)" ]]; then
        no "T-B1b: no tidy holding ref is left in origin_repo on a --k8s pod run" \
            "$(git -C "$proj" for-each-ref 'refs/fork-sandbox/tidy/*')"
    else
        ok "T-B1b: no tidy holding ref is left in origin_repo on a --k8s pod run"
    fi
else
    no "T-B1b setup: the fetch_back=1 pass failed to launch"
fi

# T-B2 (R1.3): the tidy leg squashes but also edits the file afterward --
# the tree no longer matches the approved head, so the rewrite is
# discarded and the two original commits are restored.
prep_stub $'commit-file\ncommit-file\napproved\nsquash-edit'
if rdb2="$(run_stubbed --pipeline csonnet2-msonnet \
    --branch "sandbox-test-tidy-b2-$$")"; then
    tmpdirs+=("$rdb2")
    ok "T-B2: a tree-changing tidy run exits 0"
    check "R1.3: a tree-changing rewrite is discarded" \
        "discarded" "$(jq -r '.ended' "$rdb2/tidy.json")"
    contains "R1.3: the discard detail cites the tree difference" \
        "tree differs" "$(jq -r '.detail' "$rdb2/tidy.json")"
    contains "R1.3: the discard detail says the approved history was restored" \
        "the approved history was restored" "$(jq -r '.detail' "$rdb2/tidy.json")"
    check "R1.3: the approved two commits are restored, not the squash" "2" \
        "$(grep '^commits:' "$rdb2/summary.txt" | awk '{print $2}')"
    check "R1.9: a no-op backend cannot reset the clone, so clone_restored is false" \
        "false" "$(jq -r '.clone_restored' "$rdb2/tidy.json")"
else
    no "T-B2: a tree-changing tidy run exits 0"
fi

# T-B3 (R2a.1): the tidy leg squashes correctly but adds a trailer no
# original commit carried -- discarded, even though the tree is fine.
prep_stub $'commit-file\ncommit-file\napproved\nsquash-trailer'
if rdb3="$(run_stubbed --pipeline csonnet2-msonnet \
    --branch "sandbox-test-tidy-b3-$$")"; then
    tmpdirs+=("$rdb3")
    ok "T-B3: an invented-trailer tidy run exits 0"
    check "R2a.1: an invented trailer is discarded" \
        "discarded" "$(jq -r '.ended' "$rdb3/tidy.json")"
    contains "R2a.1: the discard detail names the invented trailer" \
        "invented trailer" "$(jq -r '.detail' "$rdb3/tidy.json")"
else
    no "T-B3: an invented-trailer tidy run exits 0"
fi

# T-B4 (R1.7/R7): the tidy leg itself exits non-zero -- discarded, and the
# run's own exit code is unaffected (it is still whatever the maintainer's
# approval left it at: 0).
prep_stub $'commit-file\napproved\nfail'
if rdb4="$(run_stubbed --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-tidy-b4-$$")"; then
    tmpdirs+=("$rdb4")
    ok "T-B4: a run whose tidy leg fails still exits 0"
    check "R1.7: a failed tidy leg is discarded" \
        "discarded" "$(jq -r '.ended' "$rdb4/tidy.json")"
    contains "R1.7: the discard detail names the exit code" \
        "the tidy leg exited 1" "$(jq -r '.detail' "$rdb4/tidy.json")"
    check "R7: the one original commit is restored" "1" \
        "$(grep '^commits:' "$rdb4/summary.txt" | awk '{print $2}')"
else
    no "T-B4: a run whose tidy leg fails still exits 0"
fi

# T-B5 (R1.5): the tidy leg commits the approved tree but with no parent at
# all -- base is not an ancestor of the result, so the rewrite is discarded
# and the two original commits are restored, exercised at the runner level
# (T-A3 above covers the same check directly against fs_tidy_verify).
prep_stub $'commit-file\ncommit-file\napproved\nreroot'
if rdb5="$(run_stubbed --pipeline csonnet2-msonnet \
    --branch "sandbox-test-tidy-b5-$$")"; then
    tmpdirs+=("$rdb5")
    ok "T-B5: a rerooted tidy run exits 0"
    check "R1.5: a rerooted rewrite is discarded" \
        "discarded" "$(jq -r '.ended' "$rdb5/tidy.json")"
    contains "R1.5: the discard detail cites the ancestor check" \
        "base is not an ancestor" "$(jq -r '.detail' "$rdb5/tidy.json")"
    check "R1.5: the approved two commits are restored, not the reroot" "2" \
        "$(grep '^commits:' "$rdb5/summary.txt" | awk '{print $2}')"
else
    no "T-B5: a rerooted tidy run exits 0"
fi

# T-B6 (R1.8): the tidy leg exits 0 and leaves the branch exactly as the
# maintainer approved it (the "history already reads well" escape hatch).
prep_stub $'commit-file\napproved\nnoop'
if rdb6="$(run_stubbed --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-tidy-b6-$$")"; then
    tmpdirs+=("$rdb6")
    ok "T-B6: a no-op tidy run exits 0"
    check "R1.8: a no-op tidy leg is recorded unchanged, not accepted or discarded" \
        "unchanged" "$(jq -r '.ended' "$rdb6/tidy.json")"
    check "R5.2: the summary prints the tidy line as unchanged" \
        "tidy:      unchanged" "$(grep '^tidy:' "$rdb6/summary.txt")"
else
    no "T-B6: a no-op tidy run exits 0"
fi

# T-B7 (R2.1/R7): the maintainer's last iteration ends in FINDINGS (capped,
# never approved) -- no tidy leg runs at all, not even a failing one.
prep_stub $'commit\nfindings'
if rdb7="$(run_stubbed --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-tidy-b7-$$")"; then
    tmpdirs+=("$rdb7")
    ok "T-B7: a capped (never-approved) maintainer run exits 0"
    check "R2.1: a never-approved maintainer loop skips the tidy leg" \
        "skipped" "$(jq -r '.ended' "$rdb7/tidy.json")"
    contains "R2.1: the skip detail cites the loop's own ending" \
        "did not approve" "$(jq -r '.detail' "$rdb7/tidy.json")"
    if [[ -e "$rdb7/events-tidy-1.jsonl" ]]; then
        no "R2.1: no tidy leg (no events-tidy-1.jsonl) actually ran"
    else
        ok "R2.1: no tidy leg (no events-tidy-1.jsonl) actually ran"
    fi
else
    no "T-B7: a capped (never-approved) maintainer run exits 0"
fi

# T-B11 (R2.5): a read-only pipeline (no code leg, an existing ref reviewed
# in place) whose single maintain step approves -- the tidy leg never runs,
# even though the pipeline's last step is a maintain step that approved,
# because the run itself is read-only. Same ro_base/ro-target setup
# tests/fork-sandbox-preset-test.sh's own read-only cases use, scoped to
# this file's own $proj.
ro_base_tidy="$(git -C "$proj" rev-parse HEAD)"
git -C "$proj" branch -q "ro-target-tidy-$$"
git -C "$proj" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    commit -q --allow-empty -m "work under review"
git -C "$proj" branch -q -f "ro-target-tidy-$$" HEAD
git -C "$proj" reset -q --hard "$ro_base_tidy"
prep_stub 'approved'
if rdb11="$(run_stubbed --pipeline mopus --checkout "ro-target-tidy-$$" \
    --review-base "$ro_base_tidy")"; then
    tmpdirs+=("$rdb11")
    ok "T-B11: a read-only maintain-only run exits 0"
    check "R2.5: the tidy leg is skipped for a read-only run" \
        "skipped" "$(jq -r '.ended' "$rdb11/tidy.json")"
    contains "R2.5: the skip detail says so" \
        "read-only run" "$(jq -r '.detail' "$rdb11/tidy.json")"
    check "A12: the summary still prints a tidy: line (the pipeline has a maintain step)" \
        "tidy:      skipped (read-only run)" "$(grep '^tidy:' "$rdb11/summary.txt")"
else
    no "T-B11: a read-only maintain-only run exits 0"
fi

# T-B12a (R1.9): when the sandbox backend can actually run git (an exec-ing
# stub, standing in for a working bwrap/container backend), a discard's
# clone reset really happens and clone_restored is true. T-B2 above already
# covers the false case, under the suite's ordinary no-op backend.
prep_stub $'commit-file\ncommit-file\napproved\nsquash-edit'
if rdb12a="$(FORK_SANDBOX_BACKEND=fake-exec run_stubbed --pipeline csonnet2-msonnet \
    --branch "sandbox-test-tidy-b12a-$$")"; then
    tmpdirs+=("$rdb12a")
    ok "T-B12a: a discard with a working backend still exits 0"
    check "R1.9: a working backend actually resets the clone, so clone_restored is true" \
        "true" "$(jq -r '.clone_restored' "$rdb12a/tidy.json")"
else
    no "T-B12a: a discard with a working backend still exits 0"
fi

# T-B13 (R1.10): the runner cannot even snapshot the approved history --
# modeled by making the origin repo's own refs/fork-sandbox/tidy directory
# unwritable, so the snapshot fetch fails before any leg is launched. This
# $proj is shared with every other case in this file, so the directory is
# made writable again immediately, whichever way the run went.
mkdir -p "$proj/.git/refs/fork-sandbox/tidy"
chmod a-w "$proj/.git/refs/fork-sandbox/tidy"
prep_stub $'commit-file\napproved'
rdb13_rc=1
if rdb13="$(run_stubbed --harness claude --maintainer-loop 1 --maintainer-model sonnet \
    --branch "sandbox-test-tidy-b13-$$")"; then
    rdb13_rc=0
fi
chmod u+w "$proj/.git/refs/fork-sandbox/tidy"
if (( rdb13_rc == 0 )); then
    tmpdirs+=("$rdb13")
    ok "T-B13: a run whose tidy snapshot cannot be written still exits 0"
    check "R1.10: the tidy leg is skipped when it cannot snapshot the approved history" \
        "skipped" "$(jq -r '.ended' "$rdb13/tidy.json")"
    contains "R1.10: the skip detail says so" \
        "could not snapshot" "$(jq -r '.detail' "$rdb13/tidy.json")"
    check "R1.10: no tidy leg actually ran (the call count stays at 2)" "2" \
        "$(cat "$count")"
else
    no "T-B13: a run whose tidy snapshot cannot be written still exits 0"
fi

# T-B15 (R3.1): when the run has a plan, the tidy leg's own prompt carries
# it under the "tidy" flavor's wording (A14), not the "code" or "review"
# one, plus the plan's own text.
prep_stub $'plan\ncommit\napproved'
if rdb15="$(run_stubbed --pipeline pfable-csonnet-msonnet \
    --branch "sandbox-test-tidy-b15-$$")"; then
    tmpdirs+=("$rdb15")
    ok "T-B15: a plan-then-code-then-maintain run reaches a tidy leg"
    contains "R3.1: the tidy prompt carries the plan's own text" \
        "Stub tidy-plan body" "$(cat "$rdb15/step-3-tidy-prompt-1.md")"
    contains "R3.1: the tidy prompt's plan section uses the tidy flavor's own wording" \
        "is the target shape for this rewrite" "$(cat "$rdb15/step-3-tidy-prompt-1.md")"
else
    no "T-B15: a plan-then-code-then-maintain run reaches a tidy leg"
fi

# T-B16 (finding: the tidy publish must not overwrite a branch that appeared
# in the origin while the run was in flight). fs_check_branch_free only
# proves the branch is free at launch; the approved-clobber action commits
# directly onto the origin's branch name, host-side, during the maintainer's
# own call -- modeling an operator or a second run claiming that name before
# this run gets to publish. The tidy leg itself is unaffected (it only reads
# the clone and the holding refs) and still ends unchanged; it is the
# create-only update-ref at publish time that must refuse to move the ref.
clobber_branch_u="sandbox-test-tidy-clobber-u-$$"
prep_stub $'commit\napproved-clobber\nnoop'
if rdb16="$(FAKE_CLOBBER_BRANCH="$clobber_branch_u" run_stubbed --harness claude \
    --maintainer-loop 1 --maintainer-model sonnet --branch "$clobber_branch_u")"; then
    tmpdirs+=("$rdb16")
    rdb16_run_id="$(basename "$rdb16")"
    ok "T-B16: a run whose branch name collides mid-run still exits 0"
    check "the tidy leg itself still ends unchanged (the collision is a publish-time race, not a tidy verdict)" \
        "unchanged" "$(jq -r '.ended' "$rdb16/tidy.json")"
    # The clone is not a safe fallback to point at here (nothing wrong
    # with it in THIS scenario, but the message has to be right for the
    # discard case too, where it would be) -- summary.txt instead names
    # the still-live holding ref and a recovery command, and that ref is
    # kept, not deleted, precisely because nothing was published.
    lacks "summary.txt no longer claims the work is in the clone only" \
        "the work is in the clone only" "$(cat "$rdb16/summary.txt")"
    contains "summary.txt names the approved holding ref fetch-back kept" \
        "refs/fork-sandbox/tidy/$rdb16_run_id/approved" "$(cat "$rdb16/summary.txt")"
    contains "summary.txt gives a by-hand recovery command against that ref's sha" \
        "git update-ref refs/heads/$clobber_branch_u" "$(cat "$rdb16/summary.txt")"
    check "summary.json.fetched is false" "false" "$(jq -r '.fetched' "$rdb16/summary.json")"
    check "summary.json.commits stays 0 (nothing from this run was published)" "0" \
        "$(jq -r '.commits' "$rdb16/summary.json")"
    check "the origin branch still holds the colliding commit, not this run's work" \
        "an unrelated commit that appeared on this branch name while the run was in flight" \
        "$(git -C "$proj" log -1 --format=%s "refs/heads/$clobber_branch_u")"
    check "the tidy holding ref for this run is KEPT, not deleted" \
        "$(jq -r '.head_approved' "$rdb16/tidy.json")" \
        "$(git -C "$proj" rev-parse -q --verify "refs/fork-sandbox/tidy/$rdb16_run_id/approved" 2>/dev/null)"
else
    no "T-B16: a run whose branch name collides mid-run still exits 0"
fi

# T-P1 (not a tidy case at all: a PLAIN pipeline, no maintain/tidy step,
# whose target branch collides mid-run the same way T-B16's does). Before
# this fix, a plain fetch that lost this race left fetched: false in
# summary.json but exit-code/rc at whatever the agent itself exited with --
# a run that silently "succeeded" with its work stranded in the clone only.
# approved-clobber's own verdict-file write is inert here (no review/
# maintain loop reads it); only its origin-clobbering side effect matters.
# run_stubbed itself is not reusable for this one: it treats the launch's
# own nonzero exit as a setup failure and prints no run dir -- exactly the
# outcome this case means to produce on purpose -- so this calls $launcher
# directly and scrapes the run dir from its output regardless of rc, the
# same "  run dir:  " pattern run_stubbed's own sed uses.
clobber_branch_p="sandbox-test-tidy-plain-clobber-$$"
prep_stub 'approved-clobber'
outp1="$(HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count" \
    FAKE_SCRIPT="$script_file" FAKE_COMMIT_COUNT="$commit_count" \
    FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND="${FORK_SANDBOX_BACKEND:-fake-image}" \
    FS_LEG_RETRY_DELAYS="${FS_LEG_RETRY_DELAYS:-0 0}" \
    FAKE_CLOBBER_BRANCH="$clobber_branch_p" \
    timeout 60 "$launcher" --foreground --harness claude \
        --branch "$clobber_branch_p" "$proj" "$handoff" 2>&1)"
rc_p1=$?
rdp1="$(printf '%s\n' "$outp1" | sed -n 's/^  run dir:  *//p' | head -1)"
if [[ -n "$rdp1" ]]; then
    tmpdirs+=("$rdp1")
    check "T-P1: a plain run whose branch name collides mid-run exits nonzero" \
        "1" "$rc_p1"
    check "T-P1: exit-code file reports failure, not the agent's own 0" \
        "1" "$(cat "$rdp1/exit-code" 2>/dev/null)"
    check "T-P1: summary.json.exit_code agrees with exit-code" \
        "1" "$(jq -r '.exit_code' "$rdp1/summary.json" 2>/dev/null)"
    check "T-P1: summary.json.fetched is false" \
        "false" "$(jq -r '.fetched' "$rdp1/summary.json" 2>/dev/null)"
    check "T-P1: the origin branch still holds the colliding commit, not this run's work" \
        "an unrelated commit that appeared on this branch name while the run was in flight" \
        "$(git -C "$proj" log -1 --format=%s "refs/heads/$clobber_branch_p")"
else
    no "T-P1: a plain run whose branch name collides mid-run exits nonzero" \
        "no run dir in output (rc=$rc_p1): $outp1"
fi

# T-B17 (finding, restore path): the same collision, but this time the tidy
# leg itself is discarded (a tree-changing squash), so publish goes through
# the tidy_restore branch instead -- the one that republishes the approved
# head from its own holding ref. That path must refuse the collision too,
# the same way T-B16 pins the accepted/unchanged one.
clobber_branch_d="sandbox-test-tidy-clobber-d-$$"
prep_stub $'commit-file\ncommit-file\napproved-clobber\nsquash-edit'
if rdb17="$(FAKE_CLOBBER_BRANCH="$clobber_branch_d" run_stubbed --pipeline csonnet2-msonnet \
    --branch "$clobber_branch_d")"; then
    tmpdirs+=("$rdb17")
    rdb17_run_id="$(basename "$rdb17")"
    ok "T-B17: a discarded tidy run whose branch name also collides still exits 0"
    check "the tidy leg is still discarded for its own reason (the tree differs)" \
        "discarded" "$(jq -r '.ended' "$rdb17/tidy.json")"
    # This is exactly the case the old "the work is in the clone only"
    # message got actively wrong -- the clone holds the REJECTED squash
    # here, not the approved history, so the message must point at the
    # holding ref instead, and that ref must survive, not be deleted.
    lacks "summary.txt no longer claims the work is in the clone only" \
        "the work is in the clone only" "$(cat "$rdb17/summary.txt")"
    contains "summary.txt names the approved holding ref fetch-back kept" \
        "refs/fork-sandbox/tidy/$rdb17_run_id/approved" "$(cat "$rdb17/summary.txt")"
    contains "summary.txt gives a by-hand recovery command against that ref's sha" \
        "git update-ref refs/heads/$clobber_branch_d" "$(cat "$rdb17/summary.txt")"
    check "summary.json.fetched is false" "false" "$(jq -r '.fetched' "$rdb17/summary.json")"
    check "the origin branch still holds the colliding commit, not the restored approved history" \
        "an unrelated commit that appeared on this branch name while the run was in flight" \
        "$(git -C "$proj" log -1 --format=%s "refs/heads/$clobber_branch_d")"
    check "the tidy holding ref for this run is KEPT, not deleted" \
        "$(jq -r '.head_approved' "$rdb17/tidy.json")" \
        "$(git -C "$proj" rev-parse -q --verify "refs/fork-sandbox/tidy/$rdb17_run_id/approved" 2>/dev/null)"
else
    no "T-B17: a discarded tidy run whose branch name also collides still exits 0"
fi

# T-B18: the tidy leg's own wall-clock limit. The leg hangs
# forever; --tidy-timeout 2 means the GNU timeout wrap in run_leg's tidy
# branch kills it well inside this test's own 60s outer bound. A timed-out
# leg is a discard, same as any other tidy failure: the approved history
# is restored and published, and the run itself still exits 0.
prep_stub $'commit\napproved\nhang'
if rdb18="$(FS_LEG_RETRY_DELAYS="0 0" run_stubbed --harness claude \
    --maintainer-loop 1 --maintainer-model sonnet --tidy-timeout 2 \
    --branch "sandbox-test-tidy-timeout-$$")"; then
    tmpdirs+=("$rdb18")
    ok "T-B18: a run whose tidy leg hangs past --tidy-timeout still exits 0"
    check "the tidy leg is discarded for timing out" \
        "discarded" "$(jq -r '.ended' "$rdb18/tidy.json")"
    contains "the discard detail names the timeout, not a generic exit code" \
        "the tidy leg timed out after 2s" "$(jq -r '.detail' "$rdb18/tidy.json")"
    contains "the discard detail still says the approved history was restored" \
        "the approved history was restored" "$(jq -r '.detail' "$rdb18/tidy.json")"
    check "the tidy leg's own exit code is GNU timeout's 124, not the harness's" \
        "124" "$(jq -r '.exit' "$rdb18/tidy.json")"
    check "the run still fetched back (the approved history, not a timed-out rewrite)" \
        "true" "$(jq -r '.fetched' "$rdb18/summary.json")"
else
    no "T-B18: a run whose tidy leg hangs past --tidy-timeout still exits 0"
fi

# T-B19: a manual re-run in the same run dir, after an earlier invocation
# left a tidy holding ref behind (a lost publish collision, say) --
# re-executing that same run dir's own run.sh must refuse outright, name
# the ref and a by-hand recovery command, and touch nothing: not the ref
# itself, not the first invocation's own exit-code file. rd1 (T-B1) is
# reused here only as a finished run dir with a real run.sh to
# re-execute; the ref it is given below is this test's own, not anything
# rd1's own run actually left behind.
if [[ -n "${rd1:-}" ]]; then
    tb19_run_id="$(basename -- "$rd1")"
    tb19_stale_sha="$(cd "$proj" && git rev-parse HEAD)"
    (cd "$proj" && git update-ref "refs/fork-sandbox/tidy/$tb19_run_id/approved" "$tb19_stale_sha")
    tb19_exit_code_before="$(cat "$rd1/exit-code" 2>/dev/null)"
    out_tb19="$("$rd1/run.sh" 2>&1)"; rc_tb19=$?
    check "T-B19: a re-run refuses outright when its own tidy refs still exist" \
        "1" "$rc_tb19"
    contains "T-B19: names the stale ref" \
        "refs/fork-sandbox/tidy/$tb19_run_id/approved" "$out_tb19"
    contains "T-B19: gives a by-hand recovery command" \
        "git update-ref -d refs/fork-sandbox/tidy/$tb19_run_id/approved" "$out_tb19"
    check "T-B19: the stale ref is left untouched, not deleted or moved" \
        "$tb19_stale_sha" \
        "$(cd "$proj" && git rev-parse -q --verify "refs/fork-sandbox/tidy/$tb19_run_id/approved" 2>/dev/null)"
    check "T-B19: the first invocation's exit-code file is untouched" \
        "$tb19_exit_code_before" "$(cat "$rd1/exit-code" 2>/dev/null)"
    (cd "$proj" && git update-ref -d "refs/fork-sandbox/tidy/$tb19_run_id/approved") 2>/dev/null || true
else
    no "T-B19: a re-run refuses outright when its own tidy refs still exist" "rd1 setup failed"
    no "T-B19: names the stale ref" "rd1 setup failed"
    no "T-B19: gives a by-hand recovery command" "rd1 setup failed"
    no "T-B19: the stale ref is left untouched, not deleted or moved" "rd1 setup failed"
    no "T-B19: the first invocation's exit-code file is untouched" "rd1 setup failed"
fi

printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# Own-run-ids shape, not a before/after snapshot diff -- see the identical
# check in tests/fork-sandbox-maintainer-test.sh for why.
leaked=""
for d in "${tmpdirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    cand="$operator_archive_dir/$(basename -- "$d").md"
    [[ -f "$cand" ]] && leaked+="$cand "
done
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$leaked"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
