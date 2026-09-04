#!/usr/bin/env bash
# lkml-cover-test.sh — Exercise lkml-cover.sh's "launch the author to write a
# cover letter for patches that already exist" flow against a stub
# fork-sandbox.sh and a real (throwaway) git repo.
#
# Usage: tests/lkml-cover-test.sh
#
# Same "stub fork-sandbox.sh on PATH" pattern tests/lkml-revise-test.sh uses,
# combined with tests/lkml-series-test.sh's "the --checkout ref already
# exists in a real repo" shape -- lkml-cover.sh makes NO commits and fetches
# nothing back, so the branch it reads from just needs to already exist
# before the script runs; the stub only has to fabricate a clone_dir with (or
# without) a cover-letter.md.
#
# Covers:
#   - the happy path: a cover letter plus --smoke/--attach posts a version
#     whose body carries the author's three sections, a host-appended
#     Attachments section, a real Diffstat, and the smoke file's Test
#     results verbatim -- and records {version, branch} in versions.jsonl.
#   - no cover-letter.md written: refused, names the run dir, nothing posted.
#   - --version passed explicitly: posted as that exact version, recorded as
#     that exact version (not autocomputed).
#   - an --attach file over the mailbox's 4 MiB cap is refused.
#   - a bad --base is refused BEFORE the persona launches (no run dir
#     created), not after an up-to-timeout wait.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cover="$repo_dir/scripts/lkml-cover.sh"
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
    echo "SKIP: jq not installed; lkml-cover.sh needs it."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

# A real, throwaway repo standing in for the operator's actual project. The
# "cover-branch" ref stands in for what lkml-series.sh's reconstruction (or
# an earlier version's respin) would have already landed -- lkml-cover.sh
# makes no commits and fetches nothing back, so this just needs to exist.
real_repo="$(mktemp -d)"; tmpdirs+=("$real_repo")
git -C "$real_repo" init -q
git -C "$real_repo" config user.email test@example.com
git -C "$real_repo" config user.name "Test"
printf 'trunk\n' > "$real_repo/base.txt"
git -C "$real_repo" add base.txt
git -C "$real_repo" commit -q -m "repo: base"
base_sha="$(git -C "$real_repo" rev-parse HEAD)"

printf 'int frob(void) { return 0; }\n' > "$real_repo/frob.c"
git -C "$real_repo" add frob.c
git -C "$real_repo" commit -q -m "frob: add core"
git -C "$real_repo" branch cover-branch -q

work="$(mktemp -d)"; tmpdirs+=("$work")
# The launcher resolves its seats file from $HOME by default -- pin a
# controlled HOME and an empty LKML_SEATS_FILE so neither a real
# ~/.config/fork-sandbox/lkml-seats.yaml nor the machine's own HOME can
# leak in (tests/lkml-seats-test.sh does the same).
home_dir="$work/home"; mkdir -p -- "$home_dir"
export HOME="$home_dir" LKML_SEATS_FILE=''
patches_dir="$work/patches"; mkdir -p "$patches_dir"
git -C "$real_repo" format-patch -q --output-directory "$patches_dir" "$base_sha..cover-branch" >/dev/null

printf 'all tests passed: 7/7\n' > "$work/smoke.txt"
printf 'a screenshot, pretend\n' > "$work/shot.png"

stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")

# Builds a stub fork-sandbox.sh that fabricates one run directory with a
# clone_dir, writing (or, if $1 is 0, deliberately not writing) a
# cover-letter.md with the three sections lkml-cover.sh's handoff asks for.
write_stub() {
    local write_cover="$1"
    cat > "$stub_bin/fork-sandbox.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
run_dir="\$(mktemp -d "$run_prefix_dir/run.XXXXXX")"
clone_dir="\$run_dir/clone/proj"
mkdir -p "\$clone_dir/.git/lkml-out"
STUB
    if [[ "$write_cover" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
cat > "\$clone_dir/.git/lkml-out/cover-letter.md" <<'COVER'
Add the frobnicator, reviewed post-hoc

As an AI persona running in a sandbox, I wrote this cover letter after the
work already shipped, not before it.

## Narrative

This adds a frobnicator to the widget subsystem, reconstructed from
already-shipped work.

## Implementation overview

Patch 1 adds the core frob() function.

## What to look at first

1. The return value convention in frob.c.
COVER
STUB
    fi
    cat >> "$stub_bin/fork-sandbox.sh" <<STUB
jq -n --arg clone_dir "\$clone_dir" '{clone_dir: \$clone_dir}' > "\$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  \$run_dir"
STUB
    chmod +x "$stub_bin/fork-sandbox.sh"
}

printf '\n== happy path: cover letter + smoke + attachment ==\n'
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
write_stub 1
out="$(PATH="$stub_bin:$PATH" "$cover" widget-frob --project "$real_repo" \
    --checkout cover-branch --base "$base_sha" --patches "$patches_dir" \
    --smoke "$work/smoke.txt" --attach "$work/shot.png" 2>&1)"
rc=$?
check "exits 0" "0" "$rc"
contains "reports the posted version" "$out" "posted v1"

tree_out="$("$mailbox" tree widget-frob)"
contains "v1 shows up in the tree" "$tree_out" "=== v1 ==="
contains "the cover carries the attachment marker" \
    "$(printf '%s\n' "$tree_out" | awk 'NR==2')" "📎"

cover_id="$(printf '%s\n' "$tree_out" | awk 'NR==2{print $1}')"
raw="$("$mailbox" show widget-frob "$cover_id")"
contains "body carries the author's narrative section" "$raw" "## Narrative"
contains "body carries the author's implementation overview" "$raw" "## Implementation overview"
contains "body carries the author's what-to-look-at-first section" "$raw" "## What to look at first"
contains "body carries the host-appended Attachments section" "$raw" "## Attachments"
contains "the Attachments section names the right file and size" "$raw" \
    "Attachment: attachments/shot.png — $(wc -c < "$work/shot.png" | tr -d '[:space:]') bytes"
contains "body carries a real Diffstat section" "$raw" "## Diffstat"
contains "the diffstat names the changed file" "$raw" "frob.c"
contains "body carries the Test results section" "$raw" "## Test results"
contains "the Test results section carries the smoke file verbatim" "$raw" "all tests passed: 7/7"

versions_file="$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"
check "versions.jsonl gets exactly one line" "1" "$(wc -l < "$versions_file" | tr -d '[:space:]')"
check "versions.jsonl records version 1" "1" "$(jq -r '.version' "$versions_file")"
check "versions.jsonl records the --checkout branch" "cover-branch" "$(jq -r '.branch' "$versions_file")"

printf '\n== refusal: no cover letter was written ==\n'
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
write_stub 0
out="$(PATH="$stub_bin:$PATH" "$cover" widget-frob --project "$real_repo" \
    --checkout cover-branch --base "$base_sha" --patches "$patches_dir" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero with no cover letter"; else no "exits non-zero with no cover letter" "exit 0"; fi
contains "refusal names a run dir to read by hand" "$out" "$run_prefix_dir"
check "no message was posted" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -name '*.msg' 2>/dev/null | wc -l)"
check "versions.jsonl was never written" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -maxdepth 1 -name 'versions.jsonl' 2>/dev/null | wc -l)"

printf '\n== --version passed explicitly ==\n'
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
write_stub 1
out="$(PATH="$stub_bin:$PATH" "$cover" widget-frob --project "$real_repo" \
    --checkout cover-branch --base "$base_sha" --patches "$patches_dir" --version 5 2>&1)"
rc=$?
check "exits 0" "0" "$rc"
contains "reports the explicit version" "$out" "posted v5"

tree_out5="$("$mailbox" tree widget-frob)"
contains "v5 shows up in the tree (not v1)" "$tree_out5" "=== v5 ==="
cover_id5="$(printf '%s\n' "$tree_out5" | awk 'NR==2{print $1}')"
raw5="$("$mailbox" show widget-frob "$cover_id5")"
contains "X-Version matches the explicit --version" "$raw5" "X-Version: 5"

versions_file5="$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"
check "versions.jsonl records version 5, not an autocomputed one" "5" "$(jq -r '.version' "$versions_file5")"

printf '\n== an over-cap attachment is refused ==\n'
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
write_stub 1
big="$(mktemp)"; tmpdirs+=("$big")
dd if=/dev/zero of="$big" bs=1M count=5 >/dev/null 2>&1
out="$(PATH="$stub_bin:$PATH" "$cover" widget-frob --project "$real_repo" \
    --checkout cover-branch --base "$base_sha" --patches "$patches_dir" --attach "$big" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses an attachment over the 4 MiB cap"; else no "refuses an attachment over the 4 MiB cap" "exit 0"; fi
contains "names the mailbox init failure" "$out" "lkml-mailbox.sh init failed"
check "versions.jsonl was never written" "0" \
    "$(find "$LKML_MAILBOX_ROOT/widget-frob" -maxdepth 1 -name 'versions.jsonl' 2>/dev/null | wc -l)"

printf '\n== a bad --base is refused before the persona launches ==\n'
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
write_stub 1
n_runs_before=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
out="$(PATH="$stub_bin:$PATH" "$cover" widget-frob --project "$real_repo" \
    --checkout cover-branch --base no-such-ref --patches "$patches_dir" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero on a bad --base"; else no "exits non-zero on a bad --base" "exit 0"; fi
contains "names the bad --base" "$out" "no-such-ref"
n_runs_after=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
check "no run was launched" "$n_runs_before" "$n_runs_after"

printf '\n== --help ==\n'
h_out="$("$cover" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "lkml-cover.sh — Launch the author persona to write a cover letter for"
h2_out="$("$cover" -h 2>&1)"; h2_rc=$?
if (( h2_rc == 0 )); then ok "-h alone exits 0"; else no "-h alone exits 0" "exit $h2_rc: $h2_out"; fi
contains "-h prints the header usage" "$h2_out" "lkml-cover.sh — Launch the author persona to write a cover letter for"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
