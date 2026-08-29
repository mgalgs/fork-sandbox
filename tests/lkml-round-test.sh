#!/usr/bin/env bash
# lkml-round-test.sh — Exercise lkml-round.sh's launch and harvest logic
# against a stub fork-sandbox.sh, the same "stub the external command on
# PATH" pattern tests/fork-sandbox-k8s-test.sh uses for pi.
#
# Usage: tests/lkml-round-test.sh
#
# No sandbox, no bwrap, no real agent: the stub fork-sandbox.sh captures its
# own --task-meta, fabricates a run directory with a clone_dir already
# holding .lkml-out/*.msg replies, writes summary.json immediately (so
# lkml-round.sh's wait loop never actually sleeps), and prints the same
# "  run dir:  <path>" line the real launcher does. What is under test is
# entirely lkml-round.sh's own logic: parsing that line, waiting for
# summary.json, harvesting .lkml-out files, and posting them through
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

# The stub replaces fork-sandbox.sh entirely: no clone, no sandbox, no
# network. It reads its own --task-meta (captured for the test to inspect),
# fabricates a run directory holding a clone_dir with .lkml-out replies that
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

run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
clone_dir="$run_dir/clone/proj"
mkdir -p "$clone_dir/.lkml-out"

case "$persona" in
    linus)
        printf 'In-Reply-To: %s\nX-Tags: Reviewed-by\n\nLooks fine now.\n' "$STUB_REPLY_TO" \
            > "$clone_dir/.lkml-out/1.msg"
        printf 'Subject: a stray note\n\nThis one forgot In-Reply-To on purpose.\n' \
            > "$clone_dir/.lkml-out/2.msg"
        ;;
    security)
        # RFC-822 bracket form, not the bare id linus's reply above uses --
        # exercises harvest_one's In-Reply-To stripping (lkml_round_strip_id).
        printf 'In-Reply-To: %s\nX-Tags: Question\n\nWhat about the empty-input case?\n' "$STUB_REPLY_TO_BRACKETED" \
            > "$clone_dir/.lkml-out/1.msg"
        ;;
esac

printf '0\n' > "$run_dir/exit-code"
jq -n --arg clone_dir "$clone_dir" --arg branch "stub-branch" '{clone_dir: $clone_dir, branch: $branch, base_sha: "0000000000000000000000000000000000000000", commits: 0, fetched: false}' \
    > "$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  $run_dir"
STUB
chmod +x "$stub_bin/fork-sandbox.sh"

out="$(PATH="$stub_bin:$PATH" STUB_CAPTURE_DIR="$capture_dir" STUB_RUN_PREFIX="$run_prefix_dir" \
    STUB_REPLY_TO="$patch_id" STUB_REPLY_TO_BRACKETED="$patch_id_bracketed" \
    "$round" widget-frob --project /nonexistent/project --checkout somebranch \
    --personas linus,security --reply-to "$patch_id" 2>&1)"
rc=$?
check_rc() { if (( rc == 0 )); then ok "$1"; else no "$1" "exit $rc: $out"; fi; }
check_rc "lkml-round.sh exits 0 against the stub"

printf '\n== task-meta ==\n'
if [[ -f "$capture_dir/linus.task-meta.json" ]]; then
    ok "linus's launch captured a --task-meta"
    contains "linus's task-meta carries the persona tag" \
        "$(cat "$capture_dir/linus.task-meta.json")" '"linus"'
    contains "linus's task-meta carries the series tag" \
        "$(cat "$capture_dir/linus.task-meta.json")" '"widget-frob"'
    contains "linus's task-meta names kind review" \
        "$(cat "$capture_dir/linus.task-meta.json")" '"kind":"review"'
else
    no "linus's launch captured a --task-meta"
fi
if [[ -f "$capture_dir/security.task-meta.json" ]]; then
    ok "security's launch captured a --task-meta"
    contains "security's task-meta carries the persona tag" \
        "$(cat "$capture_dir/security.task-meta.json")" '"security"'
else
    no "security's launch captured a --task-meta"
fi

printf '\n== harvest ==\n'
tree_out="$("$mailbox" tree widget-frob)"
contains "linus's valid reply landed with its Reviewed-by tag" "$tree_out" "Reviewed-by"
contains "security's reply landed with its Question tag" "$tree_out" "Question"
contains "the reply carries linus's AI-persona attribution" \
    "$("$mailbox" show widget-frob "$(printf '%s\n' "$tree_out" | grep -m1 Reviewed-by | awk '{print $1}')")" \
    "(AI persona)"

n_msgs=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
# cover + patch + linus's good reply + security's reply = 4. The malformed
# second linus file must NOT have been posted.
check "exactly the well-formed replies were posted (4 messages total)" "4" "$n_msgs"

contains "a .lkml-out file with no In-Reply-To is refused with a clear line" \
    "$out" "has no In-Reply-To"
contains "the refusal names the file it skipped" "$out" "2.msg"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
