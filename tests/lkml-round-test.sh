#!/usr/bin/env bash
# lkml-round-test.sh — Exercise lkml-round.sh's launch and harvest logic
# against a stub fork-sandbox.sh, the same "stub the external command on
# PATH" pattern tests/fork-sandbox-k8s-test.sh uses for pi; the --k8s
# mode is exercised the same way against a stub fork-sandbox-k8s.sh that
# records its verb calls in order.
#
# Usage: tests/lkml-round-test.sh
#
# No sandbox, no bwrap, no real agent: the stub fork-sandbox.sh captures its
# own --task-meta, fabricates a run directory whose outbox (and, for some
# seats, whose clone's .git/lkml-out) already holds *.msg replies, writes
# summary.json immediately (so lkml-round.sh's wait loop never actually
# sleeps), and prints the same "  run dir:  <path>" line the real launcher
# does. What is under test is entirely lkml-round.sh's own logic: parsing
# that line, waiting for summary.json, harvesting *.msg replies from the
# outbox (falling back to .git/lkml-out for a seat that wrote there
# instead), and posting them through lkml-mailbox.sh with the launching
# persona's own attribution.

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
# The launcher resolves its seats file from $HOME by default -- pin a
# controlled HOME and an empty LKML_SEATS_FILE so neither a real
# ~/.config/fork-sandbox/lkml-seats.yaml nor the machine's own HOME can
# leak in (tests/lkml-seats-test.sh does the same).
home_dir="$work/home"; mkdir -p -- "$home_dir"
export HOME="$home_dir" LKML_SEATS_FILE=''
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
# fabricates a run directory whose outbox -- and, per the persona below,
# whose clone's .git/lkml-out -- already holds replies that depend on
# which persona this launch was for, and writes summary.json before it
# ever prints anything -- so lkml-round.sh's wait loop sees summary.json
# on its very first check and never sleeps.
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
# fork-sandbox.sh creates the outbox for every run; mirror that here.
# Where each seat writes its replies decides which harvest path this
# launch exercises:
#   core     -> the outbox (the seat prompt's location)
#   security -> .git/lkml-out only (the fallback for a seat that
#               ignored the outbox instruction and used the old path)
#   codex    -> BOTH places, plus a handoff.md in the outbox: the outbox
#               must win (each reply posted exactly once, never twice) and
#               the handoff.md must be ignored (only *.msg is harvested)
#   pi-local -> nowhere (empty outbox, no fallback directory): the
#               "wrote no replies" warning path
mkdir -p "$run_dir/outbox"

case "$persona" in
    core)
        printf 'In-Reply-To: %s\nX-Tags: Reviewed-by\n\nLooks fine now.\n' "$STUB_REPLY_TO" \
            > "$run_dir/outbox/1.msg"
        printf 'Subject: a stray note\n\nThis one forgot In-Reply-To on purpose.\n' \
            > "$run_dir/outbox/2.msg"
        ;;
    security)
        # RFC-822 bracket form, not the bare id core's reply above uses --
        # exercises harvest_one's In-Reply-To stripping (lkml_round_strip_id).
        # Written to the OLD location on purpose: the fallback path.
        mkdir -p "$clone_dir/.git/lkml-out"
        printf 'In-Reply-To: %s\nX-Tags: Question\n\nWhat about the empty-input case?\n' "$STUB_REPLY_TO_BRACKETED" \
            > "$clone_dir/.git/lkml-out/1.msg"
        ;;
    codex)
        # One reply per location, with DISTINCT subject suffixes: whichever
        # directory the harvest picks, its copy is the one that posts, so
        # the test can pin the outbox-over-fallback direction (identical
        # bodies would pass no matter which directory won).
        mkdir -p "$clone_dir/.git/lkml-out"
        printf 'In-Reply-To: %s\nSubject: a both-places reply (outbox copy)\nX-Tags: Acked-by\n\nPosted from the outbox; must be the one that lands.\n' "$STUB_REPLY_TO" \
            > "$run_dir/outbox/1.msg"
        printf 'In-Reply-To: %s\nSubject: a both-places reply (fallback copy)\nX-Tags: Acked-by\n\nPosted from the fallback; must NOT land.\n' "$STUB_REPLY_TO" \
            > "$clone_dir/.git/lkml-out/1.msg"
        printf '# self-refresh handoff\n\nThis file must never be harvested.\n' \
            > "$run_dir/outbox/handoff.md"
        ;;
esac

printf '0\n' > "$run_dir/exit-code"
jq -n --arg clone_dir "$clone_dir" --arg branch "stub-branch" '{clone_dir: $clone_dir, branch: $branch, base_sha: "0000000000000000000000000000000000000000", commits: 0, fetched: false}' \
    > "$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  $run_dir"
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

# The stub lkml-summarize.sh records its own argv to a file the test can
# read, the same "stub the external command on PATH" pattern as above --
# lkml-round.sh invokes it by bare name, resolved from PATH. STUB_SUMMARIZE_FAIL
# makes it fail so the test can check a failed summary does not fail the
# round.
cat > "$stub_bin/lkml-summarize.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STUB_SUMMARIZE_FAIL:-}" ]]; then
    echo "stub lkml-summarize: forced failure" >&2
    exit 1
fi
printf '%s\n' "$*" > "$STUB_CAPTURE_DIR/lkml-summarize.argv"
echo "stub lkml-summarize: summarized $*"
STUB
chmod +x "$stub_bin/lkml-summarize.sh"

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
contains "core's valid outbox reply landed with its Reviewed-by tag" "$tree_out" "Reviewed-by"
contains "security's fallback-directory reply landed with its Question tag" "$tree_out" "Question"
check "codex's both-places reply landed exactly once (outbox wins)" "1" \
    "$(printf '%s\n' "$tree_out" | grep -c 'a both-places reply')"
contains "the outbox copy of codex's both-places reply is the one that posted" \
    "$tree_out" "a both-places reply (outbox copy)"
case "$tree_out" in
    *"a both-places reply (fallback copy)"*) no "codex's fallback copy posted; the outbox must win when it holds a reply" ;;
    *) ok "codex's fallback copy did not post" ;;
esac
case "$tree_out" in
    *"self-refresh"*) no "the outbox handoff.md alongside 1.msg was not harvested" ;;
    *) ok "the outbox handoff.md alongside 1.msg was not harvested" ;;
esac
contains "the reply carries core's AI-persona attribution" \
    "$("$mailbox" show widget-frob "$(printf '%s\n' "$tree_out" | grep -m1 Reviewed-by | awk '{print $1}')")" \
    "(AI persona)"

n_msgs=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
# two versions (cover + patch each) + core's good outbox reply +
# security's fallback reply + codex's both-places reply posted ONCE
# (the outbox wins; a second harvest of the fallback copy would make
# this 8) = 7. The malformed second core file must NOT have been
# posted, and codex's handoff.md must not be either.
check "exactly the well-formed replies were posted, once each (7 messages total)" "7" "$n_msgs"

contains "a reply file with no In-Reply-To is refused with a clear line" \
    "$out" "has no In-Reply-To"
contains "the refusal names the file it skipped" "$out" "2.msg"
contains "an empty outbox with no fallback directory warns of no replies" \
    "$out" "pi-local wrote no replies"
contains "the no-replies warning names the outbox it checked" "$out" "/outbox, and"
contains "the no-replies warning names the fallback it checked" "$out" ".git/lkml-out as a fallback"

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

printf '\n== post-round summarize ==\n'
# The default-on round at the top harvested core's and security's replies,
# so the stub summarizer must have been invoked with the round's own facts.
if [[ -f "$capture_dir/lkml-summarize.argv" ]]; then
    ok "a harvested round invokes the summarizer by default"
    sum_argv="$(cat "$capture_dir/lkml-summarize.argv")"
    contains "summarizer argv carries the series" "$sum_argv" "widget-frob"
    contains "summarizer argv carries --project" "$sum_argv" "--project $project_dir"
    contains "summarizer argv carries the round's resolved version" "$sum_argv" "--version 1"
    contains "summarizer argv carries the round's --timeout" "$sum_argv" "--timeout 3600"
else
    no "a harvested round invokes the summarizer by default" "no argv capture file"
fi
contains "the summary is announced on stderr before it starts" "$out" "summarizing widget-frob v1"

# All rounds below use the v2 checkout and its v2 reply-to id. The ledger
# matches the checkout's commit against every recorded version's branch,
# and v2's otherbranch commit is recorded only under v2: the ambiguous-ref
# section's v3 "release" branch points at v1's somebranch commit, not at
# otherbranch's, so v2 resolves without any shared-commit tie-break.
cap_ns="$(mktemp -d)"; tmpdirs+=("$cap_ns")
out_ns="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_ns" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core,security,pi-local,codex --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize 2>&1)"
rc_ns=$?
if (( rc_ns == 0 )); then ok "--no-summarize round exits 0"; else no "--no-summarize round exits 0" "exit $rc_ns: $out_ns"; fi
if [[ ! -f "$cap_ns/lkml-summarize.argv" ]]; then
    ok "--no-summarize round does not invoke the summarizer"
else
    no "--no-summarize round does not invoke the summarizer" "argv capture file exists"
fi

cap_zero="$(mktemp -d)"; tmpdirs+=("$cap_zero")
# pi-local's stub run writes no replies at all (empty outbox, no fallback
# directory), so this round harvests nothing: the summary must be skipped
# and announced on stderr.
out_zero="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_zero" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas pi-local --personas-dir "$work" \
    --reply-to "$patch2_id" 2>&1)"
rc_zero=$?
if (( rc_zero == 0 )); then ok "nothing-harvested round still exits 0"; else no "nothing-harvested round still exits 0" "exit $rc_zero: $out_zero"; fi
contains "nothing harvested announces the skipped summary" "$out_zero" "skipping the summary for widget-frob v2"
contains "the empty seat's no-replies warning fired in this round too" "$out_zero" "pi-local wrote no replies"
if [[ ! -f "$cap_zero/lkml-summarize.argv" ]]; then
    ok "nothing-harvested round does not invoke the summarizer"
else
    no "nothing-harvested round does not invoke the summarizer" "argv capture file exists"
fi

cap_fail="$(mktemp -d)"; tmpdirs+=("$cap_fail")
# A failed summary must warn, not fail the round: the replies are already
# posted and the round's exit status stays what launch_failed says.
out_fail="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_fail" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    STUB_SUMMARIZE_FAIL=1 \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core,security --personas-dir "$work" \
    --reply-to "$patch2_id" 2>&1)"
rc_fail=$?
if (( rc_fail == 0 )); then ok "a failing summarizer does not fail the round"; else no "a failing summarizer does not fail the round" "exit $rc_fail: $out_fail"; fi
contains "the failing summarizer warns that the replies are already posted" "$out_fail" "already posted to the mailbox"

cap_missing="$(mktemp -d)"; tmpdirs+=("$cap_missing")
no_sum_bin="$(mktemp -d)"; tmpdirs+=("$no_sum_bin")
cp -- "$stub_bin/fork-sandbox.sh" "$no_sum_bin/"
# A controlled PATH, not "$no_sum_bin:$PATH": this case asserts that
# lkml-summarize.sh does NOT resolve, so it must not be able to resolve
# anywhere in the ambient PATH -- on an installed machine (install.sh
# symlinks scripts/ onto PATH) the ambient lookup would find the real
# two-tier summarizer and drag it into the suite, the same class of
# ambient leakage the pinned HOME / LKML_SEATS_FILE / LKML_MAILBOX_ROOT
# above avoid. Symlink only the tools the refusal path itself needs.
missing_path_bin="$(mktemp -d)"; tmpdirs+=("$missing_path_bin")
for tool in bash readlink dirname sed git jq python3; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -s -- "$tool_path" "$missing_path_bin/$tool"
done
out_missing="$(PATH="$no_sum_bin:$missing_path_bin" STUB_CAPTURE_DIR="$cap_missing" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core --personas-dir "$work" \
    --reply-to "$patch2_id" 2>&1)"
rc_missing=$?
if (( rc_missing != 0 )); then ok "a missing lkml-summarize.sh refuses the round at startup"; else no "a missing lkml-summarize.sh refuses the round at startup" "exit 0: $out_missing"; fi
contains "the missing-summarizer error names --no-summarize" "$out_missing" "--no-summarize"
n_launches=$(find "$cap_missing" -name '*.task-meta.json' | wc -l)
check "a missing summarizer launches no personas" "0" "$n_launches"

printf '\n== --k8s: the panel runs as cluster jobs ==\n'
# The stub replaces fork-sandbox-k8s.sh entirely, the same "stub the
# external command on PATH" pattern as fork-sandbox.sh above. It records
# every verb call in order (call-order -- the submit-before-wait and
# collect-ordering assertions read it), captures each seat's argv, and
# models the pod: a seat's wait succeeds once it has been probed the
# number of times STUB_K8S_DONE_AFTER names for it (persona:N pairs,
# space-separated; default 1). collect fabricates the pulled-back
# outbox, with a DISTINCT reply per seat, so a cross-seat mix-up is
# visible in the mailbox.
cat > "$stub_bin/fork-sandbox-k8s.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
verb="$1"; shift
args=("$@")
branch=""
outbox_dir=""
i=0; n=${#args[@]}
while (( i < n )); do
    case "${args[$i]}" in
        --branch) branch="${args[$((i+1))]}" ;;
        --outbox-dir) outbox_dir="${args[$((i+1))]}" ;;
    esac
    i=$(( i + 1 ))
done
# The branch is lkml/<series>-v<N>-round-<persona>-<epoch>: the persona is
# the part between the last "-round-" and the trailing epoch.
persona="$(printf '%s' "${branch##*/}" | sed -e 's/.*-round-//' -e 's/-[0-9]*$//')"
capture_dir="$STUB_K8S_CAPTURE_DIR"
state_dir="$STUB_K8S_STATE_DIR"
printf '%s %s\n' "$verb" "$persona" >> "$capture_dir/call-order"
printf '%s\n' "${args[*]}" > "$capture_dir/$persona.$verb.argv"
case "$verb" in
    submit)
        echo "stub fork-sandbox-k8s: submitted $branch" >&2
        ;;
    wait)
        for dead in ${STUB_K8S_DEAD:-}; do
            if [[ "$dead" == "$persona" ]]; then
                # The real wait exits 2 (not 1) when the run can never
                # complete again: pod Failed/Succeeded, job Failed,
                # pod gone, malformed sentinel. A dead seat is not
                # "still running".
                echo "stub fork-sandbox-k8s: pod for $branch is Succeeded -- the run completed and its container has since exited" >&2
                exit 2
            fi
        done
        counter_file="$state_dir/$persona.wait-count"
        c=0
        [[ -f "$counter_file" ]] && c="$(cat "$counter_file")"
        c=$(( c + 1 ))
        printf '%s\n' "$c" > "$counter_file"
        after=1
        for pair in ${STUB_K8S_DONE_AFTER:-}; do
            [[ "${pair%%:*}" == "$persona" ]] && after="${pair#*:}"
        done
        if (( c >= after )); then
            # The real wait prints the agent's exit code ALONE on stdout
            # and exits 0; an agent that exited 3 is a successful wait
            # printing 3. This stub's agents all exit 0.
            printf '0\n'
            exit 0
        fi
        # Still running at the probe timeout: the wait itself failed.
        exit 1
        ;;
    collect)
        mkdir -p -- "$outbox_dir"
        case "$persona" in
            core)
                printf 'In-Reply-To: %s\nSubject: k8s core reply\nX-Tags: Reviewed-by\n\nCluster reply from core.\n' "$STUB_REPLY_TO" \
                    > "$outbox_dir/1.msg"
                ;;
            security)
                printf 'In-Reply-To: %s\nSubject: k8s security reply\nX-Tags: Acked-by\n\nCluster reply from security.\n' "$STUB_REPLY_TO" \
                    > "$outbox_dir/1.msg"
                ;;
            pi-local)
                printf 'In-Reply-To: %s\nSubject: k8s pi-local reply\n\nCluster reply from the translated pi seat.\n' "$STUB_REPLY_TO" \
                    > "$outbox_dir/1.msg"
                ;;
        esac
        echo "stub fork-sandbox-k8s: collected $branch" >&2
        ;;
esac
exit 0
STUB
chmod +x "$stub_bin/fork-sandbox-k8s.sh"

cap_k8s="$(mktemp -d)"; tmpdirs+=("$cap_k8s")
k8s_state="$(mktemp -d)"; tmpdirs+=("$k8s_state")
# Submission order is the CSV order: core, pi-local, security. Completion
# order is deliberately the reverse (core:3, pi-local:2, security:1), so
# security was submitted last and must be collected first -- the
# data-loss guard the whole submit-then-probe shape exists for. The CSV
# entries carry spaces after their commas on purpose: the map keys the
# collect loop looks up (branch_of & co) are built from TRIMMED names, so
# any loop that iterates the raw, un-trimmed CSV silently skips every
# seat but the first.
out_k8s="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_k8s" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_K8S_CAPTURE_DIR="$cap_k8s" STUB_K8S_STATE_DIR="$k8s_state" \
    STUB_K8S_DONE_AFTER="core:3 pi-local:2 security:1" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas "core, pi-local, security" --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize --timeout 10 \
    --k8s --endpoint test-endpoint 2>&1)"
rc_k8s=$?
if (( rc_k8s == 0 )); then ok "--k8s round exits 0 against the k8s stub"; else no "--k8s round exits 0 against the k8s stub" "exit $rc_k8s: $out_k8s"; fi

k8s_order="$cap_k8s/call-order"
n_submits="$(grep -c '^submit ' "$k8s_order" 2>/dev/null)"; n_submits="${n_submits:-0}"
check "every seat got exactly one submit" "3" "$n_submits"
n_collects="$(grep -c '^collect ' "$k8s_order" 2>/dev/null)"; n_collects="${n_collects:-0}"
check "every completed seat was collected" "3" "$n_collects"
first_wait_line="$(grep -n '^wait ' "$k8s_order" | head -n1 | cut -d: -f1)"
submits_before_first_wait="$(head -n "$(( first_wait_line - 1 ))" "$k8s_order" | grep -c '^submit ' || true)"
check "all submits precede the first wait" "3" "$submits_before_first_wait"
collect_security_ln="$(grep -n '^collect security' "$k8s_order" | head -n1 | cut -d: -f1)"
collect_pilocal_ln="$(grep -n '^collect pi-local' "$k8s_order" | head -n1 | cut -d: -f1)"
collect_core_ln="$(grep -n '^collect core' "$k8s_order" | head -n1 | cut -d: -f1)"
if [[ -n "$collect_security_ln" && -n "$collect_pilocal_ln" && -n "$collect_core_ln" \
      && "$collect_security_ln" -lt "$collect_pilocal_ln" \
      && "$collect_pilocal_ln" -lt "$collect_core_ln" ]]; then
    ok "seats are collected in completion order; the seat submitted last was collected first"
else
    no "seats are collected in completion order; the seat submitted last was collected first" \
        "call order: $(tr '\n' ' ' < "$k8s_order")"
fi

k8s_outbox_of() { awk '{ for (i = 1; i < NF; i++) if ($i == "--outbox-dir") print $(i+1) }' "$1"; }
core_outbox_dir="$(k8s_outbox_of "$cap_k8s/core.collect.argv")"
pi_outbox_dir="$(k8s_outbox_of "$cap_k8s/pi-local.collect.argv")"
sec_outbox_dir="$(k8s_outbox_of "$cap_k8s/security.collect.argv")"
if [[ -n "$core_outbox_dir" && -n "$pi_outbox_dir" && -n "$sec_outbox_dir" \
      && "$core_outbox_dir" != "$pi_outbox_dir" && "$pi_outbox_dir" != "$sec_outbox_dir" \
      && "$core_outbox_dir" != "$sec_outbox_dir" ]]; then
    ok "each seat was collected into its own --outbox-dir"
else
    no "each seat was collected into its own --outbox-dir" \
        "core=$core_outbox_dir pi-local=$pi_outbox_dir security=$sec_outbox_dir"
fi
contains "core's outbox dir is named after its own branch" "$core_outbox_dir" "round-core-"
contains "pi-local's outbox dir is named after its own branch" "$pi_outbox_dir" "round-pi-local-"
contains "security's outbox dir is named after its own branch" "$sec_outbox_dir" "round-security-"

pi_submit_argv="$(cat "$cap_k8s/pi-local.submit.argv")"
case "$pi_submit_argv" in
    *"--harness pi-local"*) no "pi-local is translated to pi on the cluster path" "$pi_submit_argv" ;;
    *) ok "pi-local is translated to pi on the cluster path" ;;
esac
contains "the translated pi seat is wired to the endpoint" "$pi_submit_argv" "--endpoint test-endpoint"
# `submit` has no --pi-args option, so the persona's thinking: cannot be
# forwarded to the cluster: the seat must be submitted WITHOUT it (the old
# code appended it and submit hard-refused the whole submit) and the drop
# must be announced instead of silent.
case "$pi_submit_argv" in
    *"--pi-args"*) no "the cluster submit carries no --pi-args (submit has no such option)" "$pi_submit_argv" ;;
    *) ok "the cluster submit carries no --pi-args (submit has no such option)" ;;
esac
contains "the dropped thinking is announced for the cluster seat" "$out_k8s" \
    "seat pi-local: thinking low cannot be expressed on the cluster"
case "$out_k8s" in
    *"submitting pi-local (pi, thinking low)"*) no "the submit line does not claim a thinking the seat does not run with" ;;
    *) ok "the submit line does not claim a thinking the seat does not run with" ;;
esac
case "$pi_submit_argv" in
    *"--model"*) no "the translated pi seat carries no model" "$pi_submit_argv" ;;
    *) ok "the translated pi seat carries no model" ;;
esac
contains "the same seat is still pi-local on the local path" \
    "$(cat "$capture_dir/pi-local.argv")" "--harness pi-local"
core_submit_argv="$(cat "$cap_k8s/core.submit.argv")"
contains "a claude seat is submitted unchanged, with its model" "$core_submit_argv" "--harness claude"
contains "a claude seat keeps its model" "$core_submit_argv" "--model opus"
case "$core_submit_argv" in
    *"--endpoint"*) no "a claude seat is not wired to the pi endpoint" "$core_submit_argv" ;;
    *) ok "a claude seat is not wired to the pi endpoint" ;;
esac

k8s_tree_out="$("$mailbox" tree widget-frob)"
check "core's cluster reply landed exactly once" "1" \
    "$(printf '%s\n' "$k8s_tree_out" | grep -c 'k8s core reply')"
check "pi-local's cluster reply landed exactly once" "1" \
    "$(printf '%s\n' "$k8s_tree_out" | grep -c 'k8s pi-local reply')"
check "security's cluster reply landed exactly once" "1" \
    "$(printf '%s\n' "$k8s_tree_out" | grep -c 'k8s security reply')"
core_reply_line="$(printf '%s\n' "$k8s_tree_out" | grep 'k8s core reply')"
check "core's reply is posted under core's persona, not another seat's" "core" \
    "$(awk '{print $2}' <<<"$core_reply_line")"
check "core's reply is stamped with core's own harness/model" "(claude/opus)" \
    "$(awk '{print $3}' <<<"$core_reply_line")"
pi_reply_line="$(printf '%s\n' "$k8s_tree_out" | grep 'k8s pi-local reply')"
check "pi-local's reply is posted under pi-local's persona, not another seat's" "pi-local" \
    "$(awk '{print $2}' <<<"$pi_reply_line")"
check "pi-local's reply is stamped pi/unknown -- no summary.json to consult" "(pi/unknown)" \
    "$(awk '{print $3}' <<<"$pi_reply_line")"
sec_reply_line="$(printf '%s\n' "$k8s_tree_out" | grep 'k8s security reply')"
check "security's reply is posted under security's persona, not another seat's" "security" \
    "$(awk '{print $2}' <<<"$sec_reply_line")"
check "security's reply is stamped with its own harness/model" "(claude/opus)" \
    "$(awk '{print $3}' <<<"$sec_reply_line")"

jq_expect() { # label, filter, json
    if jq -e "$2" >/dev/null <<<"$3"; then ok "$1"; else no "$1" "filter '$2' failed on: $3"; fi
}
k8s_ledger_file="$LKML_MAILBOX_ROOT/widget-frob/runs.jsonl"
check "the k8s round wrote one ledger line per submitted seat" "3" \
    "$(jq -c 'select(.cluster == true)' "$k8s_ledger_file" | wc -l | tr -d '[:space:]')"
core_k8s_ledger_line="$(jq -c 'select(.persona == "core" and .cluster == true)' "$k8s_ledger_file" | head -n1)"
if [[ -n "$core_k8s_ledger_line" ]]; then
    ok "core's k8s ledger line exists"
    jq_expect "the k8s ledger line records the seat's branch" '.branch | type == "string" and test("round-core-")' "$core_k8s_ledger_line"
    jq_expect "the k8s ledger line carries the cluster marker" '.cluster == true' "$core_k8s_ledger_line"
    jq_expect "the k8s ledger line keeps kind review" '.kind == "review"' "$core_k8s_ledger_line"
    jq_expect "the k8s ledger line has no run_dir" 'has("run_dir") | not' "$core_k8s_ledger_line"
    jq_expect "the k8s ledger line sets no cost to zero" 'has("cost") | not' "$core_k8s_ledger_line"
else
    no "core's k8s ledger line exists" "no cluster:true line for core in $k8s_ledger_file"
fi

n_local_launches="$(find "$cap_k8s" -name '*.task-meta.json' | wc -l | tr -d '[:space:]')"
check "the k8s round never touches the local launcher" "0" "$n_local_launches"
contains "the pi-local translation is announced on stderr" "$out_k8s" \
    "seat pi-local: pi-local runs as pi via endpoint 'test-endpoint' on the cluster"

printf '\n== --k8s: a dead pod is marked lost, not re-probed ==\n'
# A seat whose pod died (or Succeeded and exited past its TTL): the
# real wait exits 2, the terminal code, and the round must mark the
# seat lost and STOP probing it -- not re-probe a corpse to the deadline
# and then call it "still running" and advise a collect that cannot
# work. core completes normally in the same round, so the round must
# still harvest what it can and fail on the lost seat. (This run also
# uses spaces in the CSV, the same shape the main k8s run above uses.)
cap_k8s_dead="$(mktemp -d)"; tmpdirs+=("$cap_k8s_dead")
k8s_state_dead="$(mktemp -d)"; tmpdirs+=("$k8s_state_dead")
out_k8s_dead="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_k8s_dead" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_K8S_CAPTURE_DIR="$cap_k8s_dead" STUB_K8S_STATE_DIR="$k8s_state_dead" \
    STUB_K8S_DONE_AFTER="core:1" STUB_K8S_DEAD="security" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas "core, security" --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize --timeout 10 \
    --k8s --endpoint test-endpoint 2>&1)"
rc_k8s_dead=$?
if (( rc_k8s_dead != 0 )); then ok "a dead seat fails the round"; else no "a dead seat fails the round" "exit 0: $out_k8s_dead"; fi
contains "the dead seat is named in the round's error" "$out_k8s_dead" "security's job"
contains "the dead seat's loss is stated" "$out_k8s_dead" "will not be harvested"
n_waits_dead="$(grep -c '^wait security' "$cap_k8s_dead/call-order" 2>/dev/null)"; n_waits_dead="${n_waits_dead:-0}"
check "the dead seat was probed exactly once, then dropped" "1" "$n_waits_dead"
n_collects_dead="$(grep -c '^collect security' "$cap_k8s_dead/call-order" 2>/dev/null)"; n_collects_dead="${n_collects_dead:-0}"
check "the dead seat was never collected" "0" "$n_collects_dead"
n_collects_live="$(grep -c '^collect core' "$cap_k8s_dead/call-order" 2>/dev/null)"; n_collects_live="${n_collects_live:-0}"
check "the live seat in the same round was still collected" "1" "$n_collects_live"
case "$out_k8s_dead" in
    *"is still running"*) no "the dead seat is not reported as still running at the deadline" "$(grep 'still running' <<<"$out_k8s_dead")" ;;
    *) ok "the dead seat is not reported as still running at the deadline" ;;
esac
k8s_tree_dead="$("$mailbox" tree widget-frob)"
check "the live seat's reply still landed alongside the dead seat" "2" \
    "$(printf '%s\n' "$k8s_tree_dead" | grep -c 'k8s core reply')"

printf '\n== --k8s validation ==\n'
cap_k8s_noe="$(mktemp -d)"; tmpdirs+=("$cap_k8s_noe")
k8s_state_noe="$(mktemp -d)"; tmpdirs+=("$k8s_state_noe")
out_k8s_noe="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_k8s_noe" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_K8S_CAPTURE_DIR="$cap_k8s_noe" STUB_K8S_STATE_DIR="$k8s_state_noe" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize --k8s 2>&1)"
rc_k8s_noe=$?
if (( rc_k8s_noe != 0 )); then ok "--k8s without --endpoint is refused"; else no "--k8s without --endpoint is refused" "exit 0: $out_k8s_noe"; fi
contains "the --k8s-without-endpoint refusal names --endpoint" "$out_k8s_noe" "--endpoint"
n_k8s_calls="$(find "$cap_k8s_noe" -name '*.argv' | wc -l | tr -d '[:space:]')"
check "a refused --k8s round makes no k8s call" "0" "$n_k8s_calls"

cap_k8s_ep="$(mktemp -d)"; tmpdirs+=("$cap_k8s_ep")
out_k8s_ep="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_k8s_ep" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_K8S_CAPTURE_DIR="$cap_k8s_ep" STUB_K8S_STATE_DIR="$k8s_state_noe" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize --endpoint test-endpoint 2>&1)"
rc_k8s_ep=$?
if (( rc_k8s_ep != 0 )); then ok "--endpoint without --k8s is refused"; else no "--endpoint without --k8s is refused" "exit 0: $out_k8s_ep"; fi
contains "the --endpoint-without-k8s refusal names --k8s" "$out_k8s_ep" "--k8s"

cap_k8s_bad="$(mktemp -d)"; tmpdirs+=("$cap_k8s_bad")
k8s_state_bad="$(mktemp -d)"; tmpdirs+=("$k8s_state_bad")
out_k8s_bad="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$cap_k8s_bad" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_K8S_CAPTURE_DIR="$cap_k8s_bad" STUB_K8S_STATE_DIR="$k8s_state_bad" \
    STUB_REPLY_TO="$patch2_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project "$project_dir" --checkout otherbranch \
    --personas core,codex --personas-dir "$work" \
    --reply-to "$patch2_id" --no-summarize --k8s --endpoint test-endpoint 2>&1)"
rc_k8s_bad=$?
if (( rc_k8s_bad != 0 )); then ok "a cluster-unsupported harness refuses the round"; else no "a cluster-unsupported harness refuses the round" "exit 0: $out_k8s_bad"; fi
contains "the refusal names the seat" "$out_k8s_bad" "seat codex"
contains "the refusal names the harness" "$out_k8s_bad" "'codex'"
contains "the refusal states that nothing was launched" "$out_k8s_bad" "no persona was launched"
n_submits_bad="$(grep -c '^submit ' "$cap_k8s_bad/call-order" 2>/dev/null)"; n_submits_bad="${n_submits_bad:-0}"
check "an unsupported harness submits nothing at all" "0" "$n_submits_bad"
n_local_launches_bad="$(find "$cap_k8s_bad" -name '*.task-meta.json' | wc -l | tr -d '[:space:]')"
check "an unsupported harness launches nothing locally either" "0" "$n_local_launches_bad"

printf '\n== --help ==\n'
h_out="$("$round" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "lkml-round.sh — Launch one fork-sandbox run per persona"
h2_out="$("$round" -h 2>&1)"; h2_rc=$?
if (( h2_rc == 0 )); then ok "-h alone exits 0"; else no "-h alone exits 0" "exit $h2_rc: $h2_out"; fi
contains "-h prints the header usage" "$h2_out" "lkml-round.sh — Launch one fork-sandbox run per persona"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
