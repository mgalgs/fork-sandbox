#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/25-fresh-per-version.sh — fork-sandbox-postmaster.sh: a
# `review-target: follow` seat starts a fresh session when the review
# target moves (a new version of the series under review), and is handed
# its previous version's transcript as /thread/previous-transcript.jsonl;
# on the same target it resumes as before. Local and k8s spawn branches,
# claude and pi seats, the `sets` seat, and a missing or oversized
# transcript.
#
# Usage: tests/postmaster/25-fresh-per-version.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# alice (local claude), frank (local pi), kai (k8s claude, already follow)
# and kim (k8s pi) follow the target; nora is a local claude `sets` seat.
sed -i 's/^  alice: {}$/  alice:\n    review-target: follow/' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^    model: vendor\/model$/    model: vendor\/model\n    review-target: follow/' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^    endpoint: kim-endpoint$/    endpoint: kim-endpoint\n    review-target: follow/' "$FORK_SANDBOX_FLEET_FILE"
# One sets seat per fleet: nora takes it over from ken (unused here).
sed -i '/^  ken:$/,/^  kai:$/{/review-target: sets/d}' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^agents:$/agents:\n  nora:\n    review-target: sets/' "$FORK_SANDBOX_FLEET_FILE"
printf 'Nora is the local review-target: sets seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/nora.md"
"$FLEET" check >/dev/null 2>&1 || { echo "FATAL: fleet check" >&2; "$FLEET" check >&2; exit 1; }

PI_NS='c9f5c6b0-6b1a-4b3e-9c2a-2e9f6b1c9a1e'
SECTION_HEAD='## Your previous review'

last_rid() { tail -n1 "$PM_STATE_DIR/seq/$1"; }
handoff_of() { cat -- "$PM_STATE_DIR/handoffs/$(last_rid "$1").md"; }
staged_of() { printf '%s' "$PM_STATE_DIR/wake-threads/$(last_rid "$1")/previous-transcript.jsonl"; }
calls() { grep -c -- '^----CALL----$' "${1:-$STUB_ARGV_LOG}"; }
# pm_call <fn> <args>: one postmaster function, sourced (the script runs
# nothing when sourced).
# shellcheck disable=SC1090
pm_call() { ( source "$postmaster"; "$@" ); }
uuid5() { python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' "$PI_NS" "$1"; }

# The section the handoff carries, verbatim, for <new-sha> <old-sha>.
section_of() {
    printf '%s\n\n' "$SECTION_HEAD"
    printf 'This is a fresh session for the new version of the series (review\n'
    printf 'target %s). Your own transcript from the previous version\n' "$1"
    printf '(review target %s) is staged read-only at\n' "$2"
    printf '/thread/previous-transcript.jsonl. Use it to re-check your own\n'
    printf 'earlier points against the new head. It is not a record to agree\n'
    printf 'with, and your verdict on this version is your own.\n'
}

# new_version <tid> <parent-sha> <version>: a new commit on the review
# branch, recorded as the thread's target; prints its sha.
new_version() {
    local tid="$1" parent="$2" version="$3" sha
    sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
        commit-tree "$rt1_tree" -p "$parent" -m "review target commit $version")"
    git -C "$PROJECT_DIR" update-ref "refs/heads/$rt1_branch" "$sha"
    printf 'BRANCH=%s\nSHA=%s\nVERSION=%s\nSET_BY=@carol\nSET_AT=2026-01-01T00:00:00Z\n' \
        "$rt1_branch" "$sha" "$version" > "$PM_STATE_DIR/review-target/$tid.env"
    printf '%s' "$sha"
}

# claude_transcript <tid> <agent> <sid> <content>: what claude leaves in
# the seat's store, ~/.claude/projects/<slug>/<sid>.jsonl.
claude_transcript() {
    mkdir -p -- "$PM_STATE_DIR/state/$1/$2/-work-project"
    printf '%s\n' "$4" > "$PM_STATE_DIR/state/$1/$2/-work-project/$3.jsonl"
}
# pi_transcript <tid> <agent> <sid> <content>: pi's <timestamp>_<id>.jsonl.
pi_transcript() {
    mkdir -p -- "$PM_STATE_DIR/state/$1/$2"
    printf '%s\n' "$4" > "$PM_STATE_DIR/state/$1/$2/2026-01-01T00-00-00-000Z_$3.jsonl"
}

new_root_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
}

k8s_rt1_seed

# ============================================================
printf '\n== fresh per version: local claude follow seat ==\n'
# ============================================================

new_root_store
printf '%s\n' 'kick off review' > "$work/body.tmp"
lc_mid="$("$MAIL" send --from '@carol' --to '@alice' --subject 'local claude versions' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
lc_tid="$(thread_of "$lc_mid")"
lc_store="$PM_STATE_DIR/state/$lc_tid/alice"
: > "$STUB_ARGV_LOG"
once
check "local claude: a first wake passes --session-state" \
    "$lc_store" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "local claude: a first wake resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude: a first wake stages no transcript" 1 "$([[ -e "$(staged_of "$lc_tid")" ]]; echo $?)"
not_contains "local claude: a first wake's handoff has no previous-review section" \
    "$(handoff_of "$lc_tid")" "$SECTION_HEAD"

lc_s1=aaaa1111-0000-4000-8000-000000000001
finish_run alice 0 "$lc_s1"
claude_transcript "$lc_tid" alice "$lc_s1" '{"v":1}'
once
lc_next() {
    reply_msg '@carol' "$lc_mid" "$1" --to '@alice' >/dev/null
    : > "$STUB_ARGV_LOG"
    once
}
lc_next 'same target'
check "local claude: the same target resumes the recorded session" \
    "$lc_s1" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "local claude: the same target stages no transcript" 1 "$([[ -e "$(staged_of "$lc_tid")" ]]; echo $?)"
not_contains "local claude: the same target's handoff has no previous-review section" \
    "$(handoff_of "$lc_tid")" "$SECTION_HEAD"

finish_run alice 0 "$lc_s1"
once
lc_rt2="$(new_version "$lc_tid" "$rt1_sha" 2)"
lc_next 'version 2'
check "local claude: a new target resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude: a new target still passes --session-state" \
    "$lc_store" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "local claude: a new target records RESUMED empty" "" \
    "$(env_val "$PM_STATE_DIR/runs/$(last_rid "$lc_tid").env" RESUMED)"
check "local claude: a new target stages the previous session's transcript as-is" \
    '{"v":1}' "$(cat -- "$(staged_of "$lc_tid")" 2>/dev/null)"
check "local claude: the staged transcript sits in the dir passed as --thread-dir" \
    '{"v":1}' "$(cat -- "$(argv_after --thread-dir "$STUB_ARGV_LOG")/previous-transcript.jsonl" 2>/dev/null)"
contains "local claude: a new target's handoff carries the previous-review section verbatim" \
    "$(handoff_of "$lc_tid")" "$(section_of "$lc_rt2" "$rt1_sha")"
lc_ho="$(handoff_of "$lc_tid")"
lc_trig_line="$(grep -n '^The triggering message for this wake is: ' <<< "$lc_ho" | cut -d: -f1)"
lc_sect_line="$(grep -n "^$SECTION_HEAD\$" <<< "$lc_ho" | cut -d: -f1)"
check "local claude: the section follows the thread/trigger block" 1 \
    "$(( lc_sect_line > lc_trig_line ))"
contains "local claude: staging is reported as an event" \
    "$(cat "$work/once.out")" "pm previous-transcript thread=${lc_tid:0:8} agent=alice staged=yes"

lc_s2=aaaa1111-0000-4000-8000-000000000002
finish_run alice 0 "$lc_s2"
claude_transcript "$lc_tid" alice "$lc_s2" '{"v":2}'
once
lc_next 'version 2 again'
check "local claude: later wakes on the new target resume the new session" \
    "$lc_s2" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "local claude: and stage nothing" 1 "$([[ -e "$(staged_of "$lc_tid")" ]]; echo $?)"

# The session the pointer names has no transcript in the store.
finish_run alice 0 "$lc_s2"
once
rm -f -- "$lc_store/-work-project/$lc_s2.jsonl"
lc_rt3="$(new_version "$lc_tid" "$lc_rt2" 3)"
lc_next 'version 3'
check "local claude: a missing transcript still wakes the seat" 1 "$(calls)"
check "local claude: a missing transcript still starts fresh" 0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude: a missing transcript stages nothing" 1 "$([[ -e "$(staged_of "$lc_tid")" ]]; echo $?)"
not_contains "local claude: a missing transcript emits no section" "$(handoff_of "$lc_tid")" "$SECTION_HEAD"
contains "local claude: a missing transcript is reported as an event" \
    "$(cat "$work/once.out")" "pm previous-transcript thread=${lc_tid:0:8} agent=alice staged=no reason=missing"

# Over the 32 MiB cap.
lc_s3=aaaa1111-0000-4000-8000-000000000003
finish_run alice 0 "$lc_s3"
mkdir -p -- "$lc_store/-work-project"
truncate -s $(( 32 * 1024 * 1024 + 1 )) "$lc_store/-work-project/$lc_s3.jsonl"
once
new_version "$lc_tid" "$lc_rt3" 4 >/dev/null
lc_next 'version 4'
check "local claude: an oversized transcript still wakes the seat" 1 "$(calls)"
check "local claude: an oversized transcript stages nothing" 1 "$([[ -e "$(staged_of "$lc_tid")" ]]; echo $?)"
not_contains "local claude: an oversized transcript emits no section" "$(handoff_of "$lc_tid")" "$SECTION_HEAD"
contains "local claude: an oversized transcript is reported as an event" \
    "$(cat "$work/once.out")" "pm previous-transcript thread=${lc_tid:0:8} agent=alice staged=no reason=oversized"

# The size check goes through the resolved GNU stat ($FS_STAT), not the
# bare name: on a host whose bare `stat` is BSD stat and GNU stat is
# `gstat`, a present transcript must still be staged.
bsd_bin="$work/bsd-stat-bin"
mkdir -p -- "$bsd_bin" "$work/bsd-stat/sessions/t1" "$work/bsd-stat/state/t1/alice/-p" "$work/bsd-stat/snap"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v stat)" > "$bsd_bin/gstat"
printf '#!/bin/sh\necho "stat: illegal option -- c" >&2\nexit 1\n' > "$bsd_bin/stat"
chmod +x -- "$bsd_bin/gstat" "$bsd_bin/stat"
printf '%s\n' aaaa3333-0000-4000-8000-000000000001 > "$work/bsd-stat/sessions/t1/alice"
printf '%s\n' '{"bsd":1}' > "$work/bsd-stat/state/t1/alice/-p/aaaa3333-0000-4000-8000-000000000001.jsonl"
# shellcheck disable=SC1090,SC2030,SC2031,SC2034
check "local claude: staging sizes the transcript with GNU stat when bare stat is BSD's" \
    '{"bsd":1}' "$( PATH="$bsd_bin:$PATH"; source "$postmaster"
        PM_SESSIONS="$work/bsd-stat/sessions" PM_SESSION_STATE="$work/bsd-stat/state"
        pm_event() { :; }
        pm_stage_previous_transcript claude t1 alice "$rt1_sha" "$work/bsd-stat/snap" \
            && cat -- "$work/bsd-stat/snap/previous-transcript.jsonl" )"

# A first wake on a new target that dies before its own session exists:
# the launcher's discovery falls back to the previous version's transcript
# and reports its id. The retry on that same new target must still start
# fresh and stage the previous transcript -- never resume the old session.
new_root_store
lf_mid="$("$MAIL" send --from '@carol' --to '@alice' --subject 'local claude failed fresh wake' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
lf_tid="$(thread_of "$lf_mid")"
: > "$STUB_ARGV_LOG"
once
lf_s1=aaaa2222-0000-4000-8000-000000000001
finish_run alice 0 "$lf_s1"
claude_transcript "$lf_tid" alice "$lf_s1" '{"lf":1}'
once
lf_rt2="$(new_version "$lf_tid" "$rt1_sha" 2)"
reply_msg '@carol' "$lf_mid" 'version 2' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "local claude failed fresh wake: the first wake on v2 resumes nothing" \
    0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
finish_run alice 2 "$lf_s1"
: > "$STUB_ARGV_LOG"
once
check "local claude failed fresh wake: the harvest keeps the old session's v1 label" \
    "$lf_s1 $rt1_sha" "$(cat "$PM_STATE_DIR/sessions/$lf_tid/alice" 2>/dev/null) $(cat "$PM_STATE_DIR/sessions/$lf_tid/.targets/alice" 2>/dev/null)"
contains "local claude failed fresh wake: the kept pointer is reported as an event" \
    "$(cat "$work/once.out")" "pm session thread=${lf_tid:0:8} agent=alice kept=$lf_s1 reason=not-created-by-wake"
if (( $(calls) == 0 )); then
    reply_msg '@carol' "$lf_mid" 'version 2 retry' --to '@alice' >/dev/null
    once
fi
check "local claude failed fresh wake: the next v2 wake runs" 1 "$(calls)"
check "local claude failed fresh wake: the next v2 wake does not resume the v1 session" \
    0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude failed fresh wake: the next v2 wake stages the v1 transcript" \
    '{"lf":1}' "$(cat -- "$(staged_of "$lf_tid")" 2>/dev/null)"
contains "local claude failed fresh wake: the next v2 wake carries the section" \
    "$(handoff_of "$lf_tid")" "$(section_of "$lf_rt2" "$rt1_sha")"
lf_s2=aaaa2222-0000-4000-8000-000000000002
finish_run alice 0 "$lf_s2"
once
reply_msg '@carol' "$lf_mid" 'version 2 again' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "local claude failed fresh wake: once v2 has its own session, v2 resumes it" \
    "$lf_s2" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "local claude failed fresh wake: and stages nothing" 1 "$([[ -e "$(staged_of "$lf_tid")" ]]; echo $?)"

# A pointer recorded before session targets were (no label beside it)
# falls back to the last wake's target, and is labelled with it the first
# time that fires, so a failed first wake leaves the same trail.
lf_s3=aaaa2222-0000-4000-8000-000000000003
finish_run alice 0 "$lf_s3"
once
rm -f -- "$PM_STATE_DIR/sessions/$lf_tid/.targets/alice"
claude_transcript "$lf_tid" alice "$lf_s3" '{"lf":3}'
lf_rt3="$(new_version "$lf_tid" "$lf_rt2" 3)"
reply_msg '@carol' "$lf_mid" 'version 3' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "local claude legacy pointer: a new target starts fresh" 0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude legacy pointer: and labels the old session with the last wake's target" \
    "$lf_rt2" "$(cat "$PM_STATE_DIR/sessions/$lf_tid/.targets/alice" 2>/dev/null)"
contains "local claude legacy pointer: the section names that target" \
    "$(handoff_of "$lf_tid")" "$(section_of "$lf_rt3" "$lf_rt2")"

# ============================================================
printf '\n== fresh per version: the sets seat is unchanged ==\n'
# ============================================================

new_root_store
ns_mid="$("$MAIL" send --from '@carol' --to '@nora' --subject 'author versions' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
ns_tid="$(thread_of "$ns_mid")"
once
ns_s1=bbbb1111-0000-4000-8000-000000000001
finish_run nora 0 "$ns_s1"
claude_transcript "$ns_tid" nora "$ns_s1" '{"author":1}'
once
new_version "$ns_tid" "$rt1_sha" 2 >/dev/null
reply_msg '@carol' "$ns_mid" 'version 2' --to '@nora' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "sets seat: a new target still resumes the recorded session" \
    "$ns_s1" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "sets seat: and stages nothing" 1 "$([[ -e "$(staged_of "$ns_tid")" ]]; echo $?)"
not_contains "sets seat: and emits no section" "$(handoff_of "$ns_tid")" "$SECTION_HEAD"

# ============================================================
printf '\n== fresh per version: local pi follow seat ==\n'
# ============================================================

new_root_store
lp_mid="$("$MAIL" send --from '@carol' --to '@frank' --subject 'local pi versions' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
lp_tid="$(thread_of "$lp_mid")"
: > "$STUB_ARGV_LOG"
once
lp_id1="$(argv_after --session-id "$STUB_ARGV_LOG")"
check "local pi: the session id is derived from the thread, the agent and the target" \
    "$(uuid5 "$lp_tid/frank@$rt1_sha")" "$lp_id1"
check "local pi: a first wake stages no transcript" 1 "$([[ -e "$(staged_of "$lp_tid")" ]]; echo $?)"
finish_run frank 0 "$lp_id1"
pi_transcript "$lp_tid" frank "$lp_id1" '{"pi":1}'
once
reply_msg '@carol' "$lp_mid" 'same target' --to '@frank' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "local pi: the same target keeps the same session id" \
    "$lp_id1" "$(argv_after --session-id "$STUB_ARGV_LOG")"
check "local pi: the same target stages no transcript" 1 "$([[ -e "$(staged_of "$lp_tid")" ]]; echo $?)"
not_contains "local pi: the same target emits no section" "$(handoff_of "$lp_tid")" "$SECTION_HEAD"
finish_run frank 0 "$lp_id1"
once
lp_rt2="$(new_version "$lp_tid" "$rt1_sha" 2)"
reply_msg '@carol' "$lp_mid" 'version 2' --to '@frank' >/dev/null
: > "$STUB_ARGV_LOG"
once
lp_id2="$(argv_after --session-id "$STUB_ARGV_LOG")"
check "local pi: a new target gets a different session id" 1 "$([[ "$lp_id2" != "$lp_id1" && -n "$lp_id2" ]] && echo 1 || echo 0)"
check "local pi: the new id names the new target" "$(uuid5 "$lp_tid/frank@$lp_rt2")" "$lp_id2"
check "local pi: a new target keeps the seat's store" \
    "$PM_STATE_DIR/state/$lp_tid/frank" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "local pi: a new target stages the previous version's session file" \
    '{"pi":1}' "$(cat -- "$(staged_of "$lp_tid")" 2>/dev/null)"
contains "local pi: a new target's handoff carries the section" \
    "$(handoff_of "$lp_tid")" "$(section_of "$lp_rt2" "$rt1_sha")"

# A pi seat on a thread with no review target keeps the pre-change id.
new_root_store
np_mid="$(send_msg '@carol' '@frank' 'pi no target' 'hello' 8)"
np_tid="$(thread_of "$np_mid")"
: > "$STUB_ARGV_LOG"
once
check "pi no target: the id is still uuid5 over <tid>/<agent>" \
    "$(uuid5 "$np_tid/frank")" "$(argv_after --session-id "$STUB_ARGV_LOG")"
check "pi no target: the derivation is byte-for-byte the pre-change one" \
    8b9742c3-ca7c-5fc4-8e71-fbf777e29ae5 \
    "$(pm_call pm_pi_session_id 0f1e2d3c4b5a69788796a5b4c3d2e1f0 frank)"
check "pi no target: a follow seat with an empty target sha keeps it too" \
    "--session-id 8b9742c3-ca7c-5fc4-8e71-fbf777e29ae5" \
    "$(pm_call pm_session_spawn_args pi 0f1e2d3c4b5a69788796a5b4c3d2e1f0 frank follow '' \
        | grep -A1 -x -- --session-id | paste -sd' ')"

# pi itself: a new --session-id in a store that already holds another
# session opens a new, empty session; it never continues the newest one.
# Run against an installed pi's own CLI session selection -- the exported
# createSessionManager its main() calls with the parsed argv -- when there
# is one. The package root is found by walking up from the resolved `pi`
# executable to its package.json (the bin may sit in dist/, dist/bundle/,
# ...). An installed pi whose package cannot be found, or lacks that entry
# point, FAILS here rather than skipping: a silent skip is how this check
# stopped running once.
pi_bin="$(command -v pi 2>/dev/null || true)"
pi_pkg=""
if [[ -n "$pi_bin" ]]; then
    pi_pkg="$(dirname -- "$(readlink -f -- "$pi_bin")")"
    while [[ "$pi_pkg" != / && ! -f "$pi_pkg/package.json" ]]; do
        pi_pkg="$(dirname -- "$pi_pkg")"
    done
    [[ -f "$pi_pkg/package.json" ]] || pi_pkg=""
fi
if [[ -z "$pi_bin" ]]; then
    printf '  skip  pi: no installed pi to check --session-id against\n'
elif ! command -v node >/dev/null 2>&1; then
    printf '  skip  pi: no node to load the installed pi with\n'
else
    new_root PI_STORE
    cat > "$work/pi-probe.mjs" <<'EOF'
const [, , pkg, dir] = process.argv;
const { createSessionManager } = await import(pkg + "/dist/main.js");
const { parseArgs } = await import(pkg + "/dist/cli/args.js");
if (typeof createSessionManager !== "function" || typeof parseArgs !== "function") {
  console.log("pi package has no createSessionManager/parseArgs entry point");
  process.exit(0);
}
const cwd = "/tmp";
// Exactly what pi's main() does with `--session-id <id> --session-dir <dir>`.
const open = (id) => createSessionManager(parseArgs(["--session-id", id, "--session-dir", dir]), cwd, dir);
const a = await open("11111111-1111-5111-8111-111111111111");
a.appendMessage({ role: "user", content: "previous version", timestamp: Date.now() });
a.appendMessage({ role: "assistant", content: [{ type: "text", text: "ok" }], timestamp: Date.now(),
  api: "x", provider: "x", model: "x", stopReason: "stop",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
           cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
const b = await open("22222222-2222-5222-8222-222222222222");
const again = await open("11111111-1111-5111-8111-111111111111");
console.log(b.getSessionId(), b.getEntries().length, again.getSessionId(), again.getEntries().length);
EOF
    check "pi: a new --session-id in a used store is a new, empty session (package: ${pi_pkg:-not found})" \
        "22222222-2222-5222-8222-222222222222 0 11111111-1111-5111-8111-111111111111 2" \
        "$( [[ -n "$pi_pkg" ]] || { echo "no package.json above $pi_bin"; exit 0; }
            if out="$(node "$work/pi-probe.mjs" "$pi_pkg" "$PI_STORE" 2>&1)"; then
                tail -n1 <<< "$out"
            else
                grep -m1 -i error <<< "$out" || tail -n1 <<< "$out"
            fi )"
fi

# ============================================================
printf '\n== fresh per version: k8s follow seats ==\n'
# ============================================================

export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
new_root K8S_TEST_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR="$K8S_TEST_CONFIG_DIR"
k8s_wake_fixture
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"
export STUB_K8S_SUMMARY_JSON="$work/k8s-summary.json"
k8s_summary() { printf '{"exit_code": 0, "session_id": "%s", "session_state": "x"}' "$1" > "$STUB_K8S_SUMMARY_JSON"; }

# The argv of the newest --k8s call in the log (the stub reply wakes
# carol, a local seat, in the same pass).
k8s_argv() {
    awk '$0=="----CALL----"{n++} {print n"\t"$0}' "$STUB_ARGV_LOG" \
        | awk -F'\t' '$2=="--k8s"{k=$1} {line[NR]=$0} END{for(i=1;i<=NR;i++){split(line[i],a,"\t"); if(a[1]==k && a[2]!="----CALL----") print a[2]}}' \
        > "$work/k8s.argv"
}

new_root_store
kc_mid="$("$MAIL" send --from '@carol' --to '@kai' --subject 'k8s claude versions' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
kc_tid="$(thread_of "$kc_mid")"
kc_store="$PM_STATE_DIR/state/$kc_tid/kai"
kc_s1=cccc1111-0000-4000-8000-000000000001
k8s_summary "$kc_s1"
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: a first wake passes --session-state" "$kc_store" "$(argv_after --session-state "$work/k8s.argv")"
check "k8s claude: a first wake resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$work/k8s.argv")"
check "k8s claude: a first wake stages no transcript" 1 "$([[ -e "$(staged_of "$kc_tid")" ]]; echo $?)"
not_contains "k8s claude: a first wake emits no section" "$(handoff_of "$kc_tid")" "$SECTION_HEAD"
check "k8s claude: the harvest recorded the session" "$kc_s1" "$(cat "$PM_STATE_DIR/sessions/$kc_tid/kai" 2>/dev/null)"
claude_transcript "$kc_tid" kai "$kc_s1" '{"k8s":1}'

reply_msg '@carol' "$kc_mid" 'same target' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: the same target resumes the recorded session" \
    "$kc_s1" "$(argv_after --resume-session "$work/k8s.argv")"
check "k8s claude: the same target stages no transcript" 1 "$([[ -e "$(staged_of "$kc_tid")" ]]; echo $?)"
not_contains "k8s claude: the same target emits no section" "$(handoff_of "$kc_tid")" "$SECTION_HEAD"

kc_rt2="$(new_version "$kc_tid" "$rt1_sha" 2)"
kc_s2=cccc1111-0000-4000-8000-000000000002
k8s_summary "$kc_s2"
reply_msg '@carol' "$kc_mid" 'version 2' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: a new target resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$work/k8s.argv")"
check "k8s claude: a new target still passes --session-state" \
    "$kc_store" "$(argv_after --session-state "$work/k8s.argv")"
check "k8s claude: a new target stages the previous session's transcript" \
    '{"k8s":1}' "$(cat -- "$(staged_of "$kc_tid")" 2>/dev/null)"
check "k8s claude: the staged transcript is in the dir pushed to /thread" \
    '{"k8s":1}' "$(cat -- "$(argv_after --thread-dir "$work/k8s.argv")/previous-transcript.jsonl" 2>/dev/null)"
contains "k8s claude: a new target's handoff carries the section" \
    "$(handoff_of "$kc_tid")" "$(section_of "$kc_rt2" "$rt1_sha")"

# Version 3 with no transcript behind the pointer (kc_s2 never written).
new_version "$kc_tid" "$kc_rt2" 3 >/dev/null
reply_msg '@carol' "$kc_mid" 'version 3' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: a missing transcript still wakes the seat" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s claude: a missing transcript stages nothing" 1 "$([[ -e "$(staged_of "$kc_tid")" ]]; echo $?)"
not_contains "k8s claude: a missing transcript emits no section" "$(handoff_of "$kc_tid")" "$SECTION_HEAD"

# A first wake on a new target that dies before its own session exists
# reports the previous version's id (discovery's fallback); the retry on
# that target still starts fresh. kc_s2 was never written, so the pointer
# is relabelled to a known session first.
kf_rt4="$(new_version "$kc_tid" "$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$rt1_branch")" 4)"
kc_s3=cccc1111-0000-4000-8000-000000000003
k8s_summary "$kc_s3"
reply_msg '@carol' "$kc_mid" 'version 4' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
claude_transcript "$kc_tid" kai "$kc_s3" '{"k8s":3}'
kf_rt5="$(new_version "$kc_tid" "$kf_rt4" 5)"
printf '{"exit_code": 2, "session_id": "%s", "session_state": "x"}' "$kc_s3" > "$STUB_K8S_SUMMARY_JSON"
reply_msg '@carol' "$kc_mid" 'version 5' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude failed fresh wake: the first wake on v5 resumes nothing" \
    0 "$(grep -c -- '^--resume-session$' "$work/k8s.argv")"
check "k8s claude failed fresh wake: the harvest keeps the old session's v4 label" \
    "$kc_s3 $kf_rt4" "$(cat "$PM_STATE_DIR/sessions/$kc_tid/kai" 2>/dev/null) $(cat "$PM_STATE_DIR/sessions/$kc_tid/.targets/kai" 2>/dev/null)"
kc_s4=cccc1111-0000-4000-8000-000000000004
k8s_summary "$kc_s4"
reply_msg '@carol' "$kc_mid" 'version 5 retry' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude failed fresh wake: the next v5 wake runs" 1 "$(grep -c -- '^--k8s$' "$STUB_ARGV_LOG")"
check "k8s claude failed fresh wake: the next v5 wake does not resume the v4 session" \
    0 "$(grep -c -- '^--resume-session$' "$work/k8s.argv")"
check "k8s claude failed fresh wake: the next v5 wake stages the v4 transcript" \
    '{"k8s":3}' "$(cat -- "$(staged_of "$kc_tid")" 2>/dev/null)"
contains "k8s claude failed fresh wake: the next v5 wake carries the section" \
    "$(handoff_of "$kc_tid")" "$(section_of "$kf_rt5" "$kf_rt4")"
reply_msg '@carol' "$kc_mid" 'version 5 again' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude failed fresh wake: once v5 has its own session, v5 resumes it" \
    "$kc_s4" "$(argv_after --resume-session "$work/k8s.argv")"

new_root_store
kp_mid="$("$MAIL" send --from '@carol' --to '@kim' --subject 'k8s pi versions' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
kp_tid="$(thread_of "$kp_mid")"
: > "$STUB_ARGV_LOG"
once
k8s_argv
kp_id1="$(argv_after --session-id "$work/k8s.argv")"
check "k8s pi: the session id names the target" "$(uuid5 "$kp_tid/kim@$rt1_sha")" "$kp_id1"
pi_transcript "$kp_tid" kim "$kp_id1" '{"kpi":1}'
reply_msg '@carol' "$kp_mid" 'same target' --to '@kim' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s pi: the same target keeps the same session id" "$kp_id1" "$(argv_after --session-id "$work/k8s.argv")"
kp_rt2="$(new_version "$kp_tid" "$rt1_sha" 2)"
reply_msg '@carol' "$kp_mid" 'version 2' --to '@kim' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s pi: a new target gets the new target's session id" \
    "$(uuid5 "$kp_tid/kim@$kp_rt2")" "$(argv_after --session-id "$work/k8s.argv")"
check "k8s pi: a new target stages the previous version's session file" \
    '{"kpi":1}' "$(cat -- "$(staged_of "$kp_tid")" 2>/dev/null)"
contains "k8s pi: a new target's handoff carries the section" \
    "$(handoff_of "$kp_tid")" "$(section_of "$kp_rt2" "$rt1_sha")"

finish_suite
