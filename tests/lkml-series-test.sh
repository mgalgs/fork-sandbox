#!/usr/bin/env bash
# lkml-series-test.sh — Exercise lkml-series.sh's host-side re-verification
# and format-patch logic against a stub fork-sandbox.sh and a real
# (throwaway) git repo.
#
# Usage: tests/lkml-series-test.sh
#
# Same "stub the external command on PATH" pattern tests/lkml-revise-test.sh
# uses. lkml-series.sh's whole point is that it never trusts a persona's own
# self-report of a tree match -- it re-diffs the fetched branch against the
# range's tip IN THE REAL REPO -- so the stub fabricates the branch directly
# in a real, throwaway repo rather than faking clone_dir contents.
#
# Covers:
#   - the happy path: a reconstruction whose tree matches the range's tip
#     exactly gets format-patched into patches-v1/ and versions.jsonl gets
#     {"version":1,...}.
#   - the mismatch-refusal path: a reconstruction that does NOT match the
#     tip's tree is refused outright -- no format-patch, no versions.jsonl
#     write.
#   - --range with no '..' is refused before any run is launched.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
series_script="$repo_dir/scripts/lkml-series.sh"

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
    echo "SKIP: jq not installed; lkml-series.sh needs it."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

# A real, throwaway repo standing in for the operator's actual project.
real_repo="$(mktemp -d)"; tmpdirs+=("$real_repo")
git -C "$real_repo" init -q
git -C "$real_repo" config user.email test@example.com
git -C "$real_repo" config user.name "Test"
printf 'trunk\n' > "$real_repo/base.txt"
git -C "$real_repo" add base.txt
git -C "$real_repo" commit -q -m "repo: base"
base_sha="$(git -C "$real_repo" rev-parse HEAD)"

# A messy "shipped" tip -- one commit, standing in for a pile of WIP commits
# that already landed on main.
printf 'int frob(void) { return 0; }\n' > "$real_repo/frob.c"
git -C "$real_repo" add frob.c
git -C "$real_repo" commit -q -m "WIP: frobnicator dump"
tip_sha="$(git -C "$real_repo" rev-parse HEAD)"
git -C "$real_repo" checkout -q "$base_sha"

stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")
# The launcher resolves its seats file from $HOME by default -- pin a
# controlled HOME and an empty LKML_SEATS_FILE so neither a real
# ~/.config/fork-sandbox/lkml-seats.yaml nor the machine's own HOME can
# leak in (tests/lkml-seats-test.sh does the same).
home_dir="$(mktemp -d)"; tmpdirs+=("$home_dir")
export HOME="$home_dir" LKML_SEATS_FILE=''

# Builds a stub fork-sandbox.sh that fabricates one run directory and, since
# it cannot really run a persona, creates the reconstruction branch directly
# in the real repo -- $1 controls whether that reconstruction's tree
# actually matches $tip_sha (1) or deliberately diverges from it (0).
write_stub() {
    local matches="$1"
    cat > "$stub_bin/fork-sandbox.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
run_dir="\$(mktemp -d "$run_prefix_dir/run.XXXXXX")"
branch=""
prev=""
while [[ \$# -gt 0 ]]; do
    case "\$prev" in
        --branch) branch="\$1" ;;
    esac
    prev="\$1"
    shift
done
git -C "$real_repo" branch "\$branch" $base_sha -q
git -C "$real_repo" checkout "\$branch" -q
printf 'int frob(void) { return 0; }\n' > "$real_repo/frob.c"
git -C "$real_repo" add frob.c
git -C "$real_repo" commit -q -m "frob: add core (reconstructed)"
STUB
    if [[ "$matches" != 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'int frob(void) { return 99; }\n' > "$real_repo/frob.c"
git -C "$real_repo" commit -q -am "frob: deliberately diverge from tip"
STUB
    fi
    cat >> "$stub_bin/fork-sandbox.sh" <<STUB
git -C "$real_repo" checkout -q "$base_sha"
jq -n --arg branch "\$branch" --argjson commits 1 --argjson fetched true \\
    '{clone_dir: "/nonexistent/clone", branch: \$branch, commits: \$commits, fetched: \$fetched}' \\
    > "\$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  \$run_dir"
STUB
    chmod +x "$stub_bin/fork-sandbox.sh"
}

export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")

printf '\n== argument parsing: --range with no .. is refused before any run is launched ==\n'
out="$(PATH="$stub_bin:$PATH" "$series_script" widget-frob --project "$real_repo" \
    --range "$base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero on a --range with no '..'"; else no "exits non-zero on a --range with no '..'" "exit 0"; fi
contains "names the '..' requirement" "$out" ".."
check "no run was launched (no runs.jsonl written)" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -name 'runs.jsonl' 2>/dev/null | wc -l)"

printf '\n== happy path: reconstruction matches the tip exactly ==\n'
write_stub 1
out="$(PATH="$stub_bin:$PATH" "$series_script" widget-frob --project "$real_repo" \
    --range "$base_sha..$tip_sha" 2>&1)"
rc=$?
check "exits 0" "0" "$rc"
contains "reports the reconstruction matches" "$out" "matches"

versions_file="$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"
check "versions.jsonl gets exactly one line" "1" "$(wc -l < "$versions_file" | tr -d '[:space:]')"
check "versions.jsonl records version 1" "1" "$(jq -r '.version' "$versions_file")"

patch_dir="$LKML_MAILBOX_ROOT/widget-frob/patches-v1"
n_patches="$(find "$patch_dir" -maxdepth 1 -name '*.patch' | wc -l | tr -d '[:space:]')"
check "exactly one patch lands in patches-v1/" "1" "$n_patches"
patch_subject="$(grep -m1 '^Subject:' "$patch_dir"/*.patch)"
contains "the patch carries the reconstruction's real commit message" "$patch_subject" "frob: add core"

printf '\n== mismatch refusal: reconstruction diverges from the tip ==\n'
# lkml-series.sh names its branch lkml/<series>-v1-$(date +%s) -- same-second
# reruns in this same real_repo would otherwise collide with the happy
# path's branch above ("a branch named ... already exists"), so clear it
# first rather than racing the clock.
git -C "$real_repo" branch -D "$(jq -r '.branch' "$versions_file")" -q
LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
export LKML_MAILBOX_ROOT
write_stub 0
out="$(PATH="$stub_bin:$PATH" "$series_script" widget-frob --project "$real_repo" \
    --range "$base_sha..$tip_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero on a mismatch"; else no "exits non-zero on a mismatch" "exit 0"; fi
contains "refusal names the mismatch" "$out" "does not match"

check "no patches-v1/ directory was created" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -maxdepth 1 -name 'patches-v1' 2>/dev/null | wc -l)"
check "versions.jsonl was never written" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -maxdepth 1 -name 'versions.jsonl' 2>/dev/null | wc -l)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
