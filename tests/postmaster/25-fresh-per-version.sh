#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/25-fresh-per-version.sh — fork-sandbox-postmaster.sh: a
# `review-target: follow` seat starts a fresh session when the review
# target moves (a new version of the series under review); on the same
# target it resumes as before. Local and k8s spawn branches, and the
# `sets` seat.
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

finish_run alice 0 "$lc_s1"
once
new_version "$lc_tid" "$rt1_sha" 2 >/dev/null
lc_next 'version 2'
check "local claude: a new target resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "local claude: a new target still passes --session-state" \
    "$lc_store" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "local claude: a new target records RESUMED empty" "" \
    "$(env_val "$PM_STATE_DIR/runs/$(last_rid "$lc_tid").env" RESUMED)"

lc_s2=aaaa1111-0000-4000-8000-000000000002
finish_run alice 0 "$lc_s2"
claude_transcript "$lc_tid" alice "$lc_s2" '{"v":2}'
once
lc_next 'version 2 again'
check "local claude: later wakes on the new target resume the new session" \
    "$lc_s2" "$(argv_after --resume-session "$STUB_ARGV_LOG")"

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
finish_run frank 0 "$lp_id1"
pi_transcript "$lp_tid" frank "$lp_id1" '{"pi":1}'
once
reply_msg '@carol' "$lp_mid" 'same target' --to '@frank' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "local pi: the same target keeps the same session id" \
    "$lp_id1" "$(argv_after --session-id "$STUB_ARGV_LOG")"
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
# Run against an installed pi's own session code, when there is one.
pi_bin="$(command -v pi 2>/dev/null || true)"
pi_pkg=""
if [[ -n "$pi_bin" ]]; then
    pi_pkg="$(dirname -- "$(dirname -- "$(readlink -f -- "$pi_bin")")")"
fi
if [[ -n "$pi_pkg" && -f "$pi_pkg/dist/core/session-manager.js" ]] && command -v node >/dev/null 2>&1; then
    new_root PI_STORE
    cat > "$work/pi-probe.mjs" <<'EOF'
const [, , pkg, dir] = process.argv;
const { SessionManager } = await import(pkg + "/dist/core/session-manager.js");
const cwd = "/tmp";
// What pi's main.js does with --session-id.
const open = (id) => {
  const p = SessionManager.findById(cwd, id, dir);
  return p ? SessionManager.open(p, dir) : SessionManager.create(cwd, dir, { id });
};
const a = open("11111111-1111-5111-8111-111111111111");
a.appendMessage({ role: "user", content: "previous version", timestamp: Date.now() });
a.appendMessage({ role: "assistant", content: [{ type: "text", text: "ok" }], timestamp: Date.now(),
  api: "x", provider: "x", model: "x", stopReason: "stop",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
           cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
const b = open("22222222-2222-5222-8222-222222222222");
console.log(b.getSessionId(), b.getEntries().length, open("11111111-1111-5111-8111-111111111111").getEntries().length);
EOF
    check "pi: a new --session-id in a used store is a new, empty session" \
        "22222222-2222-5222-8222-222222222222 0 2" \
        "$(node "$work/pi-probe.mjs" "$pi_pkg" "$PI_STORE" 2>&1 | tail -n1)"
else
    printf '  skip  pi: no installed pi to check --session-id against\n'
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
check "k8s claude: the harvest recorded the session" "$kc_s1" "$(cat "$PM_STATE_DIR/sessions/$kc_tid/kai" 2>/dev/null)"
claude_transcript "$kc_tid" kai "$kc_s1" '{"k8s":1}'

reply_msg '@carol' "$kc_mid" 'same target' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: the same target resumes the recorded session" \
    "$kc_s1" "$(argv_after --resume-session "$work/k8s.argv")"

new_version "$kc_tid" "$rt1_sha" 2 >/dev/null
kc_s2=cccc1111-0000-4000-8000-000000000002
k8s_summary "$kc_s2"
reply_msg '@carol' "$kc_mid" 'version 2' --to '@kai' >/dev/null
: > "$STUB_ARGV_LOG"
once
k8s_argv
check "k8s claude: a new target resumes nothing" 0 "$(grep -c -- '^--resume-session$' "$work/k8s.argv")"
check "k8s claude: a new target still passes --session-state" \
    "$kc_store" "$(argv_after --session-state "$work/k8s.argv")"

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

finish_suite
