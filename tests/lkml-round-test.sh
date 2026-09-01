#!/usr/bin/env bash
# lkml-round-test.sh — Exercise lkml-round.sh's launch and harvest logic
# against a stub fork-sandbox.sh, the same "stub the external command on
# PATH" pattern tests/fork-sandbox-k8s-test.sh uses for pi.
#
# Usage: tests/lkml-round-test.sh
#
# No sandbox, no bwrap, no real agent: the stub fork-sandbox.sh captures its
# own --task-meta, fabricates a run directory with a clone_dir already
# holding .git/lkml-out/*.msg replies, writes summary.json immediately (so
# lkml-round.sh's wait loop never actually sleeps), and prints the same
# "  run dir:  <path>" line the real launcher does. What is under test is
# entirely lkml-round.sh's own logic: parsing that line, waiting for
# summary.json, harvesting .git/lkml-out files, and posting them through
# lkml-mailbox.sh with the launching persona's own attribution.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
round="$repo_dir/scripts/lkml-round.sh"
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
    echo "SKIP: jq not installed; lkml-round.sh needs it to build --task-meta."
    exit 0
fi

work="$(mktemp -d)"; tmpdirs+=("$work")
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
capture_dir="$(mktemp -d)"; tmpdirs+=("$capture_dir")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")
stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
project_dir="$(mktemp -d)"; tmpdirs+=("$project_dir")

git -C "$project_dir" init -q
git -C "$project_dir" config user.email test@example.invalid
git -C "$project_dir" config user.name Test
printf 'checkout tree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm base
git -C "$project_dir" branch somebranch
git -C "$project_dir" checkout -qb otherbranch
printf 'second checkout tree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm v2
git -C "$project_dir" branch unrecorded
git -C "$project_dir" checkout -q unrecorded
printf 'unrecorded checkout tree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm unrecorded
git -C "$project_dir" checkout -q somebranch

cd "$work" || exit 1

# A minimal series to reply into.
printf 'Add the frobnicator\n\nBody.\n' > cover.txt
mkdir patches
printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff\n' > patches/0001.patch
"$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus >/dev/null 2>&1
patch_id="$("$mailbox" tree widget-frob | awk 'NR==3{print $1}')"
# The full, un-truncated id in RFC-822 form -- what a persona sees in
# `Message-ID: <uuid@lkml.local>` when its handoff embeds `mailbox show`
# output for a --reply-to round, and may reasonably copy verbatim into its
# own In-Reply-To rather than the bare id `tree`/`show` display elsewhere.
patch_id_bracketed="<$("$mailbox" show widget-frob "$patch_id" \
    | sed -n 's/^Message-ID: <\(.*\)>$/\1/p')>"

# The version ledger is what ties the checkout to the cover and thread set.
printf '{"version":1,"branch":"somebranch"}\n' > "$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"

printf 'Add the second frobnicator\n\nV2 body.\n' > cover2.txt
mkdir patches2
printf 'Subject: [PATCH 1/1] frob: second\n\ndiff\n' > patches2/0001.patch
"$mailbox" init widget-frob --cover cover2.txt --patches patches2 --from author \
    --harness claude --model opus --version 2 >/dev/null 2>&1
patch2_id="$("$mailbox" tree widget-frob | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
printf '{"version":2,"branch":"otherbranch"}\n' >> "$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"

# The stub replaces fork-sandbox.sh entirely: no clone, no sandbox, no
# network. It reads its own --task-meta (captured for the test to inspect),
# fabricates a run directory holding a clone_dir with .git/lkml-out replies that
# depend on which persona this launch was for, and writes summary.json
# before it ever prints anything -- so lkml-round.sh's wait loop sees
# summary.json on its very first check and never sleeps.
cat > "$stub_bin/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
task_meta=""
i=0
while (( i < n )); do
    if [[ "${args[$i]}" == --task-meta ]]; then
        task_meta="${args[$((i+1))]}"
    fi
    i=$(( i + 1 ))
done
persona="$(printf '%s' "$task_meta" | jq -r '.tags[2]')"
printf '%s\n' "$task_meta" > "$STUB_CAPTURE_DIR/$persona.task-meta.json"
printf '%s\n' "${args[*]}" > "$STUB_CAPTURE_DIR/$persona.argv"
cp -- "${args[$((n-1))]}" "$STUB_CAPTURE_DIR/$persona.handoff.md"

run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
clone_dir="$run_dir/clone/proj"
mkdir -p "$clone_dir/.git/lkml-out"

case "$persona" in
    core)
        printf 'In-Reply-To: %s\nX-Tags: Reviewed-by\n\nLooks fine now.\n' "$STUB_REPLY_TO" \
            > "$clone_dir/.git/lkml-out/1.msg"
        printf 'Subject: a stray note\n\nThis one forgot In-Reply-To on purpose.\n' \
            > "$clone_dir/.git/lkml-out/2.msg"
        ;;
    security)
        # RFC-822 bracket form, not the bare id core's reply above uses --
        # exercises harvest_one's In-Reply-To stripping (lkml_round_strip_id).
        printf 'In-Reply-To: %s\nX-Tags: Question\n\nWhat about the empty-input case?\n' "$STUB_REPLY_TO_BRACKETED" \
            > "$clone_dir/.git/lkml-out/1.msg"
        ;;
esac

printf '0\n' > "$run_dir/exit-code"
jq -n --arg clone_dir "$clone_dir" --arg branch "stub-branch" '{clone_dir: $clone_dir, branch: $branch, base_sha: "0000000000000000000000000000000000000000", commits: 0, fetched: false}' \
    > "$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  $run_dir"
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

cat > "$work/pi-local.md" <<'PERSONA'
---
persona: pi-local
harness: pi-local
thinking: low
---
Local reviewer.
PERSONA
cat > "$work/codex.md" <<'PERSONA'
---
persona: codex
harness: codex
thinking: low
---
Codex reviewer.
PERSONA
cp -- "$repo_dir/skills/lkml-mode/personas/core.md" "$work/core.md"
cp -- "$repo_dir/skills/lkml-mode/personas/security.md" "$work/security.md"

out="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout somebranch \
    --personas core,security,pi-local,codex --personas-dir "$work" \
    --reply-to "$patch_id" 2>&1)"
rc=$?
check_rc() { if (( rc == 0 )); then ok "$1"; else no "$1" "exit $rc: $out"; fi; }
check_rc "lkml-round.sh exits 0 against the stub"

printf '\n== task-meta ==\n'
if [[ -f "$capture_dir/core.task-meta.json" ]]; then
    ok "core's launch captured a --task-meta"
    contains "core's task-meta carries the persona tag" \
        "$(cat "$capture_dir/core.task-meta.json")" '"core"'
    contains "core's task-meta carries the series tag" \
        "$(cat "$capture_dir/core.task-meta.json")" '"widget-frob"'
    contains "core's task-meta names kind review" \
        "$(cat "$capture_dir/core.task-meta.json")" '"kind":"review"'
else
    no "core's launch captured a --task-meta"
fi
if [[ -f "$capture_dir/security.task-meta.json" ]]; then
    ok "security's launch captured a --task-meta"
    contains "security's task-meta carries the persona tag" \
        "$(cat "$capture_dir/security.task-meta.json")" '"security"'
else
    no "security's launch captured a --task-meta"
fi

printf '\n== passthrough, handoff identity, and version pin ==\n'
contains "pi-local forwards thinking to pi" "$(cat "$capture_dir/pi-local.argv")" "--pi-args --thinking low"
check "pi-local has exactly one pi-args option" "1" "$(grep -o -- '--pi-args' "$capture_dir/pi-local.argv" | wc -l | tr -d '[:space:]')"
case "$(cat "$capture_dir/codex.argv")" in
    *"--pi-args"*) no "codex drops thinking instead of passing pi args" ;;
    *) ok "codex drops thinking instead of passing pi args" ;;
esac
handoff_text="$(cat "$capture_dir/pi-local.handoff.md")"
footer_identity="You are pi-local (\`pi-local\`)."
contains "handoff footer uses fallback display" "$handoff_text" "$footer_identity"
contains "handoff footer signs as the fallback persona" "$handoff_text" $'sign\nany trailer as pi-local'
contains "v1 checkout gets v1 cover" "$handoff_text" "Add the frobnicator"
case "$handoff_text" in
    *"Add the second frobnicator"*) no "v1 checkout handoff excludes v2 cover" ;;
    *) ok "v1 checkout handoff excludes v2 cover" ;;
esac

printf '\n== harvest ==\n'
tree_out="$("$mailbox" tree widget-frob)"
contains "core's valid reply landed with its Reviewed-by tag" "$tree_out" "Reviewed-by"
contains "security's reply landed with its Question tag" "$tree_out" "Question"
contains "the reply carries core's AI-persona attribution" \
    "$("$mailbox" show widget-frob "$(printf '%s\n' "$tree_out" | grep -m1 Reviewed-by | awk '{print $1}')")" \
    "(AI persona)"

n_msgs=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
# two versions (cover + patch each) + core's good reply + security's reply = 6.
# The malformed second core file must NOT have been posted.
check "exactly the well-formed replies were posted (6 messages total)" "6" "$n_msgs"

contains "a .git/lkml-out file with no In-Reply-To is refused with a clear line" \
    "$out" "has no In-Reply-To"
contains "the refusal names the file it skipped" "$out" "2.msg"

printf '\n== persona archiving ==\n'
for p in core security pi-local codex; do
    if cmp -s "$work/$p.md" "$LKML_MAILBOX_ROOT/widget-frob/personas/$p.md"; then
        ok "persona $p archived into the series mailbox"
    else
        no "persona $p archived into the series mailbox" "missing or differs"
    fi
done

printf '\n== bad --reply-to id is caught before any persona launches ==\n'

# Before the fix this required for two things to line up to go unchecked:
# a bad id past the first --reply-to (only index 0 was ever resolved), and
# --version passed explicitly (the only path that skipped resolving index 0
# too, since that resolution was a side effect of INFERRING the version).
# Cover both by passing --version explicitly and putting the bad id second.
capture_dir2="$(mktemp -d)"; tmpdirs+=("$capture_dir2")
out2="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir2" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout somebranch \
    --personas core,security --version 1 \
    --reply-to "$patch_id" --reply-to deadbeefbad 2>&1)"
rc2=$?
if (( rc2 != 0 )); then ok "exits non-zero on an unresolvable --reply-to id"; else no "exits non-zero on an unresolvable --reply-to id" "exit 0: $out2"; fi
contains "names the bad id" "$out2" "deadbeefbad"
n_launches=$(find "$capture_dir2" -name '*.task-meta.json' | wc -l)
check "no persona was launched (caught before the launch loop)" "0" "$n_launches"

printf '\n== mixed-version --reply-to ids are refused ==\n'
out_mixed="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir2" STUB_RUN_PREFIX="$run_prefix_dir" \
    "$round" widget-frob --project "$project_dir" --checkout somebranch \
    --personas core --version 1 --reply-to "$patch_id" --reply-to "$patch2_id" 2>&1)"
rc_mixed=$?
if (( rc_mixed != 0 )); then ok "mixed-version --reply-to ids exit non-zero"; else no "mixed-version --reply-to ids exit non-zero"; fi
contains "mixed-version error names the mismatched id" "$out_mixed" "$patch2_id"
contains "mixed-version error names both versions" "$out_mixed" "v2, not v1"
n_launches=$(find "$capture_dir2" -name '*.task-meta.json' | wc -l)
check "mixed-version ids launch no personas" "0" "$n_launches"

printf '\n== an unrecorded checkout is refused ==\n'
out3="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir2" STUB_RUN_PREFIX="$run_prefix_dir" \
    "$round" widget-frob --project "$project_dir" --checkout unrecorded \
    --personas core --personas-dir "$work" --reply-to "$patch_id" 2>&1)"
rc3=$?
if (( rc3 != 0 )); then ok "unrecorded checkout exits non-zero"; else no "unrecorded checkout exits non-zero"; fi
contains "unrecorded checkout error names recorded branches" "$out3" "somebranch"

printf '\n== an ambiguous checkout ref cannot bypass the branch SHA check ==\n'
git -C "$project_dir" branch release somebranch
git -C "$project_dir" tag release unrecorded
printf '{"version":3,"branch":"release"}\n' >> "$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"
out4="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir2" STUB_RUN_PREFIX="$run_prefix_dir" \
    "$round" widget-frob --project "$project_dir" --checkout release \
    --personas core --version 3 --reply-to "$patch_id" 2>&1)"
rc4=$?
if (( rc4 != 0 )); then ok "ambiguous checkout ref exits non-zero"; else no "ambiguous checkout ref exits non-zero"; fi
contains "ambiguous checkout ref is rejected as a mismatched commit" "$out4" \
    "matches no recorded version branch"

printf '\n== secretary handoff carries the whole thread ==\n'
# The secretary summarizes the discussion instead of reviewing the diff,
# and its sandbox cannot read the mailbox, so its handoff must carry the
# thread's message bodies (the --text render). Reviewer seats do not get
# it: their handoff is cover + tree and they read the diff in the clone.
cp -- "$repo_dir/skills/lkml-mode/personas/secretary.md" "$work/secretary.md"
cap_sec="$(mktemp -d)"; tmpdirs+=("$cap_sec")
out_sec="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_sec" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch --base otherbranch \
    --personas core,secretary --personas-dir "$work" 2>&1)"
rc_sec=$?
if (( rc_sec == 0 )); then ok "secretary round exits 0 against the stub"; else no "secretary round exits 0 against the stub" "exit $rc_sec: $out_sec"; fi
sec_handoff="$cap_sec/secretary.handoff.md"
if [[ -f "$sec_handoff" ]]; then ok "secretary's launch captured a handoff"; else no "secretary's launch captured a handoff"; fi
sec_text="$(cat -- "$sec_handoff" 2>/dev/null)"
contains "secretary handoff has the thread section" "$sec_text" "## The thread's messages, bodies included"
# core's reply body landed in the mailbox during the harvest section:
# it is not in the tree (subjects only) or the cover, so its presence
# means the handoff carries message bodies, not just the tree.
contains "secretary handoff carries a reply body, not just the tree" "$sec_text" "Looks fine now."
contains "secretary handoff names the version the round is about" "$sec_text" 'widget-frob v1'
contains "secretary handoff carries the other version as context" "$sec_text" 'widget-frob v2'
core_handoff="$(cat -- "$cap_sec/core.handoff.md" 2>/dev/null)"
contains "reviewer handoff still has the tree" "$core_handoff" "## The full thread tree so far"
case "$core_handoff" in
    *"Looks fine now."*) no "reviewer handoff does not carry message bodies" ;;
    *) ok "reviewer handoff does not carry message bodies" ;;
esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
