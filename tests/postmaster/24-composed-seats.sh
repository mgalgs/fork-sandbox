#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/24-composed-seats.sh — fork-sandbox-postmaster.sh: seats
# with a fleet `pipelines:` table. The wake-when gate's size token picks the
# row (every fallback picks `default`), the choice survives retry, a held
# release and a superseded fetch-wait, a composed wake's argv is exactly
# decision 4's on both backends, a composed `sets` seat always starts from
# the review target, and seats without the key are untouched -- including
# the fetch-wait record a re-freeze queues for one beneath a composed wake.
#
# Usage: tests/postmaster/24-composed-seats.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== composed seats: fixtures ==\n'
# ============================================================

export FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline
new_root K8S_TEST_CONFIG_DIR
export FORK_SANDBOX_CONFIG_DIR="$K8S_TEST_CONFIG_DIR"
k8s_wake_fixture
export FORK_SANDBOX_POSTMASTER_K8S="$K8S_WAKE_BIN/fork-sandbox-k8s.sh"

for cs_seat in pat pam pak pag; do
    printf 'Composed fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/$cs_seat.md"
done
# Not .md: a .md here would also be a bare-persona agent.
printf 'Read the bridge twice.\n' > "$FORK_SANDBOX_PERSONAS_DIR/pat-brief.txt"
printf 'exit 0\n' > "$FORK_SANDBOX_PERSONAS_DIR/pat-finalize.sh"
# One `sets` seat per fleet: pat takes it from ken in this file.
sed -i '/^  ken:$/,/^  kai:$/{/review-target: sets/d}' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^agents:$/agents:\
  pat:\
    pipelines: {default: copus1-ropus1, xs: csonnet1-ropus1, l: pfable1-copus1-ropus3, cx: csol1-ropus1}\
    wake-when: gate\
    review-target: sets\
    refresh-at: 0.5\
    review-brief: pat-brief.txt\
    finalize: pat-finalize.sh\
  pam:\
    pipelines: {default: copus1-ropus1, plan: pfable1-copus1-ropus1}\
  pak:\
    backend: k8s\
    pipelines: {default: copus1-ropus1, xs: csonnet1-ropus1}\
    wake-when: gate\
    finalize: pat-finalize.sh\
  pag:\
    backend: k8s\
    grant: required\
    pipelines: {default: copus1-ropus1, l: pfable1-copus1-ropus3}\
    wake-when: gate/' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^  karen:$/  karen:\n    wake-when: gate/; s/^  alice: {}$/  alice:\n    wake-when: gate/' \
    "$FORK_SANDBOX_FLEET_FILE"
if "$FLEET" check >/dev/null 2>&1; then
    ok "composed fixture fleet passes fleet check"
else
    no "composed fixture fleet passes fleet check" "$("$FLEET" check 2>&1)"
fi

new_root CS_HOOKS
new_root CS_OUT
# shellcheck disable=SC2031  # the subshell is lib.sh's hk_call, not this scope
export CS_OUT FORK_SANDBOX_HOOKS_DIR="$CS_HOOKS"
# The gate wakes everyone; it writes $CS_OUT/size (and floor) into the
# files the postmaster named, when those exist, and records its env.
cat > "$CS_HOOKS/wake-when.gate" <<'GATE'
#!/usr/bin/env bash
echo "$FS_HOOK_AGENT" >> "$CS_OUT/calls"
env | grep '^FS_HOOK_' | sort > "$CS_OUT/env-$FS_HOOK_AGENT"
if [[ -n "${FS_HOOK_PIPELINE_SIZE_FILE:-}" && -f "$CS_OUT/size" ]]; then
    cat "$CS_OUT/size" > "$FS_HOOK_PIPELINE_SIZE_FILE"
fi
if [[ -n "${FS_HOOK_FINALIZE_FLOOR_FILE:-}" && -f "$CS_OUT/floor" ]]; then
    cat "$CS_OUT/floor" > "$FS_HOOK_FINALIZE_FLOOR_FILE"
fi
if [[ -n "${FS_HOOK_CHECKOUT_FILE:-}" && -f "$CS_OUT/checkout" ]]; then
    cat "$CS_OUT/checkout" > "$FS_HOOK_CHECKOUT_FILE"
fi
exit 0
GATE
chmod +x "$CS_HOOKS/wake-when.gate"

cs_calls() { [[ -f "$CS_OUT/calls" ]] && wc -l < "$CS_OUT/calls" || echo 0; }
# The newest stub call's argv, one arg per line.
last_call() { awk '/^----CALL----$/{buf=""; next} {buf = buf $0 "\n"} END{printf "%s", buf}' "$STUB_ARGV_LOG"; }
flag_count() { last_call | grep -cxF -- "$1"; }
flag_value() { last_call | awk -v f="$1" 'found{print; exit} $0==f{found=1}'; }
cs_new_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$STUB_ARGV_LOG"
    rm -f -- "$CS_OUT/calls" "$CS_OUT/size" "$CS_OUT/floor" "$CS_OUT/checkout" "$CS_OUT"/env-*
}
# cs_wake <agent> [size-token]: a fresh store, one message to <agent>, one pass.
cs_wake() {
    cs_new_store
    [[ $# -lt 2 ]] || printf '%s' "$2" > "$CS_OUT/size"
    cs_mid="$(send_msg '@carol' "@$1" 'composed topic' 'please fix' 8)"
    cs_tid="$(thread_of "$cs_mid")"
    once
}
pipeline_events() { grep -F 'pm pipeline ' "$work/once.out" || true; }

# ============================================================
printf '\n== composed seats: the gate picks the row ==\n'
# ============================================================

cs_wake pat xs
check "size: the gate's xs token runs the xs row" "csonnet1-ropus1" "$(flag_value --pipeline)"
contains "size: the pipeline event names the choice, the raw token and the spec" \
    "$(pipeline_events)" "agent=pat size=xs requested=xs spec=csonnet1-ropus1 floor=-"
check "size: one pipeline event per wake" 1 "$(pipeline_events | wc -l)"

for cs_case in "none:" "empty:" "upper:XS" "spaced:x y" "unknown:nosuch" "two-lines:xs
l"; do
    cs_label="${cs_case%%:*}" cs_tok="${cs_case#*:}"
    if [[ "$cs_label" == none ]]; then cs_wake pat; else cs_wake pat "$cs_tok"; fi
    check "fallback ($cs_label): the default row runs" "copus1-ropus1" "$(flag_value --pipeline)"
    contains "fallback ($cs_label): the event says size=default" "$(pipeline_events)" \
        "agent=pat size=default requested="
done
cs_wake pat "XS"
contains "fallback: the raw token is shown as written" "$(pipeline_events)" "requested=XS spec="
cs_wake pat
contains "fallback: no token shows requested=-" "$(pipeline_events)" "requested=- spec=copus1-ropus1"

cs_wake pam
check "no gate: the default row runs" "copus1-ropus1" "$(flag_value --pipeline)"
contains "no gate: the event says requested=-" "$(pipeline_events)" \
    "agent=pam size=default requested=- spec=copus1-ropus1 floor=-"

cs_new_store
printf 'l' > "$CS_OUT/size"
printf 'do it\n' > "$work/body.tmp"
cs_mid="$("$MAIL" send --from '@operator' --to '@pat' --subject 'operator topic' \
    --body "$work/body.tmp" --hops 8 2>/dev/null)"
once
check "operator mail: the gate does not run" 0 "$(cs_calls)"
check "operator mail: the default row runs" "copus1-ropus1" "$(flag_value --pipeline)"

# ============================================================
printf '\n== composed seats: spawn args ==\n'
# ============================================================

cs_wake pat xs
for cs_flag in --pipeline --branch --network --clone-dir --wake-reply --review-brief \
    --finalize-script --thread-dir; do
    check "local args: $cs_flag is passed" 1 "$(flag_count "$cs_flag")"
done
check "local args: --review-brief names the seat's brief" \
    "$FORK_SANDBOX_PERSONAS_DIR/pat-brief.txt" "$(flag_value --review-brief)"
check "local args: --finalize-script names the seat's script" \
    "$FORK_SANDBOX_PERSONAS_DIR/pat-finalize.sh" "$(flag_value --finalize-script)"
for cs_flag in --harness --model --effort --pi-args --preset --timeout; do
    check "local args: no $cs_flag" 0 "$(flag_count "$cs_flag")"
done
cs_env="$(latest_env_for_agent pat)"
check "record: PIPELINE_SIZE" "xs" "$(env_val "$cs_env" PIPELINE_SIZE)"
check "record: PIPELINE_SPEC" "csonnet1-ropus1" "$(env_val "$cs_env" PIPELINE_SPEC)"
check "record: FINALIZE_FLOOR empty without a floor" "" "$(env_val "$cs_env" FINALIZE_FLOOR)"
check "record: HARNESS/MODEL are step 1's seat" "claude sonnet" \
    "$(env_val "$cs_env" HARNESS) $(env_val "$cs_env" MODEL)"

cs_wake pak xs
for cs_flag in --pipeline --k8s --outbox-dir --network --wake-reply --finalize-script; do
    check "k8s args: $cs_flag is passed" 1 "$(flag_count "$cs_flag")"
done
check "k8s args: the xs row" "csonnet1-ropus1" "$(flag_value --pipeline)"
for cs_flag in --timeout --harness --model --effort --pi-args --preset --review-brief; do
    check "k8s args: no $cs_flag" 0 "$(flag_count "$cs_flag")"
done

# Session args follow step 1: kept for a claude code step, dropped for a
# plan-first or codex-first row; --refresh-at follows the same rule.
cs_wake pat
check "session: a claude-code-first row passes --session-state" 1 "$(flag_count --session-state)"
check "session: ... and --refresh-at" "0.5" "$(flag_value --refresh-at)"
finish_run pat 0 11111111-2222-3333-4444-555555555555
once
printf 'xs' > "$CS_OUT/size"
: > "$STUB_ARGV_LOG"
reply_msg '@carol' "$cs_mid" 'more please' >/dev/null
once
once
check "session: a later claude-code-first wake resumes the recorded session" \
    "11111111-2222-3333-4444-555555555555" "$(flag_value --resume-session)"
for cs_row in l cx; do
    cs_wake pat "$cs_row"
    for cs_flag in --session-state --resume-session --session-id --refresh-at; do
        check "session: the $cs_row row passes no $cs_flag" 0 "$(flag_count "$cs_flag")"
    done
done
cs_wake pam
check "session: pam's claude-code-first default keeps --session-state" 1 "$(flag_count --session-state)"

# ============================================================
printf '\n== composed seats: size survives admission ==\n'
# ============================================================

export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
cs_wake pat xs
cs_calls_before="$(cs_calls)"
finish_run pat 1
once
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "retry: the retry wake reuses the admitted xs row" "csonnet1-ropus1" "$(flag_value --pipeline)"
check "retry: the gate is not asked again" "$cs_calls_before" "$(cs_calls)"
contains "retry: the event says requested=-" "$(pipeline_events)" "size=xs requested=- spec=csonnet1-ropus1"

cs_wake pat xs
finish_run pat 1
sed -i '/^PIPELINE_SIZE=/d' "$(latest_env_for_agent pat)"
once
: > "$STUB_ARGV_LOG"
once
check "retry: a run record with no size retries on default" "copus1-ropus1" "$(flag_value --pipeline)"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

cs_wake pag l
check "held: no spawn before the grant" 0 "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
check "held: the held record carries the admitted size" "l" \
    "$(env_val "$PM_STATE_DIR/held/$cs_tid/pag" SIZE)"
cs_calls_before="$(cs_calls)"
"$MAIL" grant "$cs_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "held: the release runs the admitted l row" "pfable1-copus1-ropus3" "$(flag_value --pipeline)"
check "held: the release does not ask the gate" "$cs_calls_before" "$(cs_calls)"

cs_wake pag l
sed -i '/^SIZE=/d' "$PM_STATE_DIR/held/$cs_tid/pag"
"$MAIL" grant "$cs_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "held: a held record with no size releases on default" "copus1-ropus1" "$(flag_value --pipeline)"

# ============================================================
printf '\n== composed seats: the finalize floor ==\n'
# ============================================================

cs_floor="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
cs_new_store
printf 'xs' > "$CS_OUT/size"
printf '%s\n' "$cs_floor" > "$CS_OUT/floor"
cs_mid="$(send_msg '@carol' '@pat' 'floor topic' 'fold it' 8)"
cs_tid="$(thread_of "$cs_mid")"
once
check "floor: a valid floor is passed" "$cs_floor" "$(flag_value --finalize-floor)"
contains "floor: the event names it" "$(pipeline_events)" "spec=csonnet1-ropus1 floor=$cs_floor"
check "floor: the run record keeps it" "$cs_floor" \
    "$(env_val "$(latest_env_for_agent pat)" FINALIZE_FLOOR)"
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
finish_run pat 1
once
: > "$STUB_ARGV_LOG"
once
check "floor: a retry reuses the admitted floor" "$cs_floor" "$(flag_value --finalize-floor)"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF
for cs_bad in abc "${cs_floor:0:39}"; do
    cs_new_store
    printf '%s' "$cs_bad" > "$CS_OUT/floor"
    send_msg '@carol' '@pat' 'bad floor' 'x' 8 >/dev/null
    once
    check "floor: malformed '$cs_bad' passes no --finalize-floor" 0 "$(flag_count --finalize-floor)"
    contains "floor: ... and the event says floor=-" "$(pipeline_events)" "floor=-"
done
cs_wake pat
check "floor: no floor file, no --finalize-floor" 0 "$(flag_count --finalize-floor)"
contains "gate env: a pipelines seat gets the size file" "$(cat "$CS_OUT/env-pat")" \
    "FS_HOOK_PIPELINE_SIZE_FILE="
contains "gate env: a finalize seat gets the floor file" "$(cat "$CS_OUT/env-pat")" \
    "FS_HOOK_FINALIZE_FLOOR_FILE="
cs_wake pak
cs_new_store
send_msg '@carol' '@pag' 'gate env' 'x' 8 >/dev/null
once
not_contains "gate env: a seat without finalize gets no floor file" "$(cat "$CS_OUT/env-pag")" \
    "FS_HOOK_FINALIZE_FLOOR_FILE"

# ============================================================
printf '\n== composed seats: the gate picks the start sha ==\n'
# ============================================================

# A commit in the project repo that is not HEAD (nor on any branch), the
# shape of a pushed integration head the seat has not seen yet.
cs_start="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree -p "$(git -C "$PROJECT_DIR" rev-parse HEAD)" -m 'pushed head' \
    "$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')")"
# cs_start_wake <agent> <checkout-token> [floor]: one gated wake.
cs_start_wake() {
    cs_new_store
    printf '%s' "$2" > "$CS_OUT/checkout"
    [[ $# -lt 3 ]] || printf '%s\n' "$3" > "$CS_OUT/floor"
    cs_mid="$(send_msg '@carol' "@$1" 'start topic' 'carry it' 8)"
    cs_tid="$(thread_of "$cs_mid")"
    once
}
cs_start_wake pat "$cs_start"
check "start (local): the gate's sha is the one --checkout" "1 $cs_start" \
    "$(flag_count --checkout) $(flag_value --checkout)"
check "start (local): the run record keeps it" "$cs_start" \
    "$(env_val "$(latest_env_for_agent pat)" CHECKOUT)"
contains "start (local): the pipeline event names it" "$(pipeline_events)" \
    "spec=copus1-ropus1 floor=- checkout=$cs_start"
not_contains "start (local): ... and refuses nothing" "$(pipeline_events)" "checkout_requested="
contains "gate env: a pipelines seat gets the checkout file" "$(cat "$CS_OUT/env-pat")" \
    "FS_HOOK_CHECKOUT_FILE=$PM_STATE_DIR/wake-gate."
cs_start_wake pak "$cs_start"
check "start (k8s): the gate's sha is the one --checkout" "1 $cs_start" \
    "$(flag_count --checkout) $(flag_value --checkout)"
check "start (k8s): the run record keeps it" "$cs_start" \
    "$(env_val "$(latest_env_for_agent pak)" CHECKOUT)"
cs_start_wake pam "$cs_start"
check "start (no gate): pam takes no --checkout" 0 "$(flag_count --checkout)"
contains "start (no gate): the event says checkout=-" "$(pipeline_events)" "floor=- checkout=-"

# Every fallback keeps today's checkout (pat, `sets` with no target and
# no lineage: none), and the event shows what was refused.
cs_absent="$(printf 'deadbeef%.0s' 1 2 3 4 5)"
for cs_case in "none:" "empty:" "short:abc" "39-hex:${cs_start:0:39}" "two-lines:$cs_start
$cs_start" "absent:$cs_absent" "upper:${cs_start^^}"; do
    cs_label="${cs_case%%:*}" cs_tok="${cs_case#*:}"
    if [[ "$cs_label" == none ]]; then
        cs_wake pat
    else
        cs_start_wake pat "$cs_tok"
    fi
    check "start fallback ($cs_label): no --checkout, as without a gate sha" 0 "$(flag_count --checkout)"
    contains "start fallback ($cs_label): the event says checkout=-" "$(pipeline_events)" "checkout=-"
    check "start fallback ($cs_label): the record's CHECKOUT is empty" "" \
        "$(env_val "$(latest_env_for_agent pat)" CHECKOUT)"
    case "$cs_label" in
        none|empty) not_contains "start fallback ($cs_label): nothing shown as refused" \
            "$(pipeline_events)" "checkout_requested=" ;;
        *) contains "start fallback ($cs_label): the raw token is shown as refused" \
            "$(pipeline_events)" "checkout=- checkout_requested=$(printf '%s' "$cs_tok" | tr -d ' \n' | head -c 64)" ;;
    esac
done
# A sets seat with a review target: a refused sha keeps the target.
k8s_rt1_seed
cs_new_store
printf 'abc' > "$CS_OUT/checkout"
printf 'revise\n' > "$work/body.tmp"
cs_mid="$("$MAIL" send --from '@carol' --to '@pat' --subject 'target start' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
once
check "start fallback (target): a refused sha keeps the review target" "$rt1_sha" "$(flag_value --checkout)"
cs_new_store
printf '%s' "$cs_start" > "$CS_OUT/checkout"
cs_mid="$("$MAIL" send --from '@carol' --to '@pat' --subject 'target start' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
cs_tid="$(thread_of "$cs_mid")"
once
check "start (target): a valid sha wins over the review target" "1 $cs_start" \
    "$(flag_count --checkout) $(flag_value --checkout)"
check "start (target): the review-target records are still written" "$rt1_sha $rt1_sha" \
    "$(env_val "$(latest_env_for_agent pat)" WOKEN_AT_SHA) $(env_val "$(latest_env_for_agent pat)" REVIEW_TARGET_SHA)"

# Admission: a retry, a held release and a fetch-wait re-dispatch reuse it.
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
cs_start_wake pat "$cs_start"
cs_calls_before="$(cs_calls)"
rm -f -- "$CS_OUT/checkout"
finish_run pat 1
once
: > "$STUB_ARGV_LOG"
: > "$work/once.out"
once
check "start retry: the retry reuses the admitted sha" "1 $cs_start" \
    "$(flag_count --checkout) $(flag_value --checkout)"
check "start retry: the gate is not asked again" "$cs_calls_before" "$(cs_calls)"
contains "start retry: the event names it" "$(pipeline_events)" "checkout=$cs_start"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF
cs_start_wake pag "$cs_start"
check "start held: the held record carries the admitted sha" "$cs_start" \
    "$(env_val "$PM_STATE_DIR/held/$cs_tid/pag" CHECKOUT)"
rm -f -- "$CS_OUT/checkout"
cs_calls_before="$(cs_calls)"
"$MAIL" grant "$cs_tid" --allow-namespace ns-a --reach-probe svc.ns-a:80 >/dev/null 2>&1
: > "$STUB_ARGV_LOG"
once
check "start held: the release checks out the admitted sha" "1 $cs_start" \
    "$(flag_count --checkout) $(flag_value --checkout)"
check "start held: the release does not ask the gate" "$cs_calls_before" "$(cs_calls)"

# A gate floor reaches the runner unchanged beside the gate's sha; whether
# it is an ancestor is the runner's existing floor-not-ancestor check (the
# finalize suite proves that against the checkout).
cs_floor_side="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree -p "$(git -C "$PROJECT_DIR" rev-parse HEAD)" -m 'side floor' \
    "$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')")"
cs_start_wake pat "$cs_start" "$cs_floor_side"
check "start floor: both flags reach the runner as written" "$cs_start $cs_floor_side" \
    "$(flag_value --checkout) $(flag_value --finalize-floor)"

# ============================================================
printf '\n== composed seats: seats without pipelines are unchanged ==\n'
# ============================================================

# The whole argv, the gate env's FS_HOOK_ keys and the run record's keys of
# a plain local and a plain k8s seat, exactly (the variable values masked).
cs_argv_shape() {
    last_call | sed -E "s#^$CS_SHAPE_STATE.*#<state>#; s#^/.*/pm-k8s-wake\.[^/]*/#<wake>/#; s#^sbx-mail-[0-9a-f]{8}-#sbx-mail-<t>-#; s#^$PROJECT_DIR\$#<project>#; s#^$FORK_SANDBOX_MAIL_ROOT/#<root>/#"
}
cs_env_keys() { sed 's/=.*//' "$1" | tr '\n' ' '; }

cs_wake alice xs
printf '%s' "$cs_start" > "$CS_OUT/checkout"
CS_SHAPE_STATE="$PM_STATE_DIR"
check "plain local seat: the argv is exactly as before" \
"--branch
sbx-mail-<t>-alice-1
--harness
claude
--network
pinned
--model
opus
--effort
high
--clone-dir
<state>
--thread-dir
<state>
--session-state
<state>
<project>
<state>" "$(cs_argv_shape)"
check "plain local seat: the gate env's keys are exactly as before" \
    "FS_HOOK_AGENT FS_HOOK_EVENT FS_HOOK_EXPORT_FILE FS_HOOK_MAIL_ROOT FS_HOOK_MESSAGE FS_HOOK_MESSAGE_FILE FS_HOOK_REPO FS_HOOK_STATUS_FILE FS_HOOK_THREAD FS_HOOK_UPSTREAM_STATE " \
    "$(cs_env_keys "$CS_OUT/env-alice")"
check "plain local seat: the run record's keys are exactly as before" \
    "AGENT THREAD TRIGGER RUN_DIR INBOX HARNESS MODEL NETWORK BRANCH RESUMED PENDING_MSGS VIA SPAWNED_AT BACKEND REVIEW_TARGET ON_SILENCE " \
    "$(cs_env_keys "$(latest_env_for_agent alice)")"
not_contains "plain seat: its gate env has no size file" "$(cat "$CS_OUT/env-alice")" \
    "FS_HOOK_PIPELINE_SIZE_FILE"
not_contains "plain seat: ... and no floor file" "$(cat "$CS_OUT/env-alice")" \
    "FS_HOOK_FINALIZE_FLOOR_FILE"
check "plain seat: no pipeline event" "" "$(pipeline_events)"
for cs_flag in --harness --model --clone-dir; do
    check "plain local seat: $cs_flag is still passed" 1 "$(flag_count "$cs_flag")"
done
for cs_flag in --pipeline --wake-reply --review-brief --finalize-script; do
    check "plain local seat: no $cs_flag" 0 "$(flag_count "$cs_flag")"
done
check "plain local seat: no PIPELINE_SIZE in its record" "" \
    "$(env_val "$(latest_env_for_agent alice)" PIPELINE_SIZE)"
cs_wake karen xs
CS_SHAPE_STATE="$PM_STATE_DIR"
check "plain k8s seat: the argv is exactly as before" \
"--branch
sbx-mail-<t>-karen-1
--harness
claude
--network
pinned
--model
sonnet
--thread-dir
<state>
--k8s
--timeout
14400
--session-state
<state>
--outbox-dir
<wake>/outbox
<project>
<state>" "$(cs_argv_shape)"
check "plain k8s seat: the gate env's keys are exactly as before" \
    "FS_HOOK_AGENT FS_HOOK_EVENT FS_HOOK_EXPORT_FILE FS_HOOK_MAIL_ROOT FS_HOOK_MESSAGE FS_HOOK_MESSAGE_FILE FS_HOOK_REPO FS_HOOK_STATUS_FILE FS_HOOK_THREAD FS_HOOK_UPSTREAM_STATE " \
    "$(cs_env_keys "$CS_OUT/env-karen")"
not_contains "plain k8s seat: its gate env has no size file" "$(cat "$CS_OUT/env-karen")" \
    "FS_HOOK_PIPELINE_SIZE_FILE"
check "plain k8s seat: no pipeline event" "" "$(pipeline_events)"
check "plain k8s seat: --timeout 14400 as before" "14400" "$(flag_value --timeout)"
for cs_flag in --harness --k8s; do
    check "plain k8s seat: $cs_flag is still passed" 1 "$(flag_count "$cs_flag")"
done
for cs_flag in --pipeline --wake-reply; do
    check "plain k8s seat: no $cs_flag" 0 "$(flag_count "$cs_flag")"
done

# ============================================================
printf '\n== composed seats: a sets seat starts from the target ==\n'
# ============================================================

k8s_rt1_seed
cs_seed_lineage() {
    # $1=agent: a harvested earlier run of the seat on this thread whose
    # branch resolves, so a non-composed `sets` seat would take lineage.
    local rid="cs-lineage-$1-$RANDOM" branch="cs-lineage-$1-$RANDOM"
    mkdir -p -- "$PM_STATE_DIR/runs" "$PM_STATE_DIR/harvested" "$PM_STATE_DIR/seq"
    printf 'AGENT=%s\nBRANCH=%s\nREVIEW_TARGET_SHA=%s\n' "$1" "$branch" "$rt1_sha" \
        > "$PM_STATE_DIR/runs/$rid.env"
    : > "$PM_STATE_DIR/harvested/$rid"
    git -C "$PROJECT_DIR" branch "$branch" >/dev/null 2>&1
    printf '%s\n' "$rid" >> "$PM_STATE_DIR/seq/$cs_tid"
    mkdir -p -- "$PM_STATE_DIR/workspaces/$cs_tid/$1/.git"
}
cs_target_wake() {
    # $1=agent: a fresh thread with a review target and a lineage, then a wake.
    cs_new_store
    printf 'revise\n' > "$work/body.tmp"
    cs_mid="$("$MAIL" send --from '@carol' --to "@$1" --subject 'target topic' \
        --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
    cs_tid="$(thread_of "$cs_mid")"
    cs_seed_lineage "$1"
    once
}
cs_target_wake pat
check "sets (local): a composed seat with a lineage checks out the target" \
    "$rt1_sha" "$(flag_value --checkout)"
# The same seat with no target recorded falls back to lineage (k8s seats
# check out lineage by branch; a local seat keeps its clone, so no flag).
cs_new_store
cs_mid="$(send_msg '@carol' '@pat' 'no target' 'x' 8)"
cs_tid="$(thread_of "$cs_mid")"
cs_seed_lineage pat
once
check "sets (local): with no target recorded there is no --checkout" 0 "$(flag_count --checkout)"

# k8s: move `sets` from pat to pak for this case.
sed -i '/^  pat:$/,/^  pam:$/{/review-target: sets/d}' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^  pak:$/  pak:\n    review-target: sets/' "$FORK_SANDBOX_FLEET_FILE"
cs_target_wake pak
check "sets (k8s): a composed seat with a lineage checks out the target" \
    "$rt1_sha" "$(flag_value --checkout)"
cs_new_store
cs_mid="$(send_msg '@carol' '@pak' 'no target' 'x' 8)"
cs_tid="$(thread_of "$cs_mid")"
cs_seed_lineage pak
cs_lineage_branch="$(sed -n 's/^BRANCH=//p' "$PM_STATE_DIR"/runs/cs-lineage-pak-*.env)"
once
check "sets (k8s): with no target recorded, lineage" "$cs_lineage_branch" "$(flag_value --checkout)"

# ============================================================
printf '\n== composed seats: a refused finalize holds the wake ==\n'
# ============================================================

# `sets` back on pat (local) for the harvest cases.
sed -i '/^  pak:$/,/^  pag:$/{/review-target: sets/d}' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^  pat:$/  pat:\n    review-target: sets/' "$FORK_SANDBOX_FLEET_FILE"
msg_count() { find "$FORK_SANDBOX_MAIL_ROOT/threads/$1" -name '*.msg' | wc -l; }
# fin_wake <summary-json>: a pat wake that ends with exit-code 1 (0 when
# the summary's finalize did not fail), a reply in its outbox and the
# given summary.json, then one harvest pass.
fin_wake() {
    cs_new_store
    cs_mid="$(send_msg '@carol' '@pat' 'finalize topic' 'fold it' 8)"
    cs_tid="$(thread_of "$cs_mid")"
    once
    fin_env="$(live_env_for_agent pat)"
    fin_rid="$(basename -- "$fin_env" .env)"
    fin_run_dir="$(env_val "$fin_env" RUN_DIR)"
    mkdir -p -- "$fin_run_dir/outbox"
    printf '\nFolded and ready.\n' > "$fin_run_dir/outbox/mail-1.md"
    printf '%s\n' "$2" > "$fin_run_dir/exit-code"
    printf '%s\n' "$1" > "$fin_run_dir/summary.json"
    fin_msgs_before="$(msg_count "$cs_tid")"
    : > "$work/once.out"
    : > "$STUB_ARGV_LOG"
    once
}
fin_wake '{"finalize":{"ended":"failed","detail":"the script exited 2","exit":2}}' 1
check "refused: no reply is posted" "$fin_msgs_before" "$(msg_count "$cs_tid")"
check "refused: the reply stays in the outbox" "yes" \
    "$([[ -f "$fin_run_dir/outbox/mail-1.md" ]] && echo yes)"
check "refused: no retry is scheduled" "no" \
    "$([[ -e "$PM_STATE_DIR/retries/$cs_tid/pat" ]] && echo yes || echo no)"
check "refused: the run is harvested" "yes" \
    "$([[ -e "$PM_STATE_DIR/harvested/$fin_rid" ]] && echo yes)"
check "refused: the thread is flagged with exit and reason" \
    "finalize refused for pat (run $fin_rid): exit=2 the script exited 2" \
    "$(cat "$PM_STATE_DIR/needs-operator/$cs_tid" 2>/dev/null)"
contains "refused: the flag journal records the finalize-refused keyword" \
    "$(cat "$PM_STATE_DIR/needs-operator-journal/$cs_tid" 2>/dev/null)" "finalize-refused"
contains "refused: the finalize event carries exit and reason" "$(cat "$work/once.out")" \
    "pm finalize thread=${cs_tid:0:8} agent=pat run=$fin_rid outcome=refused exit=2 reason=the script exited 2"
export FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF=0,0
once
once
check "refused: no later pass wakes the seat" 0 "$(grep -c -- '----CALL----' "$STUB_ARGV_LOG")"
unset FORK_SANDBOX_POSTMASTER_RETRY_BACKOFF

fin_wake '{"finalize":{"ended":"failed","detail":"tree differs","exit":null}}' 1
check "refused (runner): exit=- in the flag" \
    "finalize refused for pat (run $fin_rid): exit=- tree differs" \
    "$(cat "$PM_STATE_DIR/needs-operator/$cs_tid" 2>/dev/null)"
contains "refused (runner): exit=- in the event" "$(cat "$work/once.out")" \
    "outcome=refused exit=- reason=tree differs"

fin_wake '{"finalize":{"ended":"skipped","detail":"no commits above the base","exit":null}}' 0
check "skipped: the reply is posted as usual" "$(( fin_msgs_before + 1 ))" "$(msg_count "$cs_tid")"
not_contains "skipped: no finalize event" "$(cat "$work/once.out")" "pm finalize "

# A finalize that ran: the published head is the squashed one, and a sets
# seat's Version: reply stamps it as the target.
cs_new_store
printf 'revise\n' > "$work/body.tmp"
cs_mid="$("$MAIL" send --from '@carol' --to '@pat' --subject 'squash topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
cs_tid="$(thread_of "$cs_mid")"
once
fin_env="$(live_env_for_agent pat)"
fin_run_dir="$(env_val "$fin_env" RUN_DIR)"
fin_branch="$(env_val "$fin_env" BRANCH)"
fin_sq="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit-tree "$(git -C "$PROJECT_DIR" rev-parse "$rt1_sha^{tree}")" -p "$rt1_sha" -m 'squashed fix')"
git -C "$PROJECT_DIR" update-ref "refs/heads/$fin_branch" "$fin_sq"
mkdir -p -- "$fin_run_dir/outbox"
printf 'Version: 2\n\nSquashed and ready.\n' > "$fin_run_dir/outbox/mail-1.md"
printf '0\n' > "$fin_run_dir/exit-code"
printf '{"finalize":{"ended":"ran","detail":null,"exit":0,"head_after":"%s"}}\n' "$fin_sq" \
    > "$fin_run_dir/summary.json"
once
fin_posted=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$cs_tid"/*.msg; do
    grep -qF 'Squashed and ready.' "$f" && fin_posted="$f"
done
check "ran: the reply is posted" "yes" "$([[ -n "$fin_posted" ]] && echo yes)"
check "ran: X-Review-Target-Set names the squashed head" "$fin_branch $fin_sq" \
    "$( [[ -n "$fin_posted" ]] && header_of_file "$fin_posted" X-Review-Target-Set)"
check "ran: the thread's review target moves to it" "$fin_sq" \
    "$(env_val "$PM_STATE_DIR/review-target/$cs_tid.env" SHA)"

# ============================================================
printf '\n== composed seats: a fetch-wait record keeps its own size and floor ==\n'
# ============================================================

# pak (k8s, gated, with a finalize script) takes `sets` again: the
# upstream-head wait and the re-freeze are k8s `sets` paths.
sed -i '/^  pat:$/,/^  pam:$/{/review-target: sets/d}' "$FORK_SANDBOX_FLEET_FILE"
sed -i 's/^  pak:$/  pak:\n    review-target: sets/' "$FORK_SANDBOX_FLEET_FILE"
k8s_origin_mirror_seed
export FORK_SANDBOX_POSTMASTER_FETCH_WINDOW=120
cs_fw_file() { printf '%s/fetch-wait/%s/%s' "$PM_STATE_DIR" "$1" "$2"; }
cs_fw_set() { sed -i "s/^$3=.*/$3=$4/" "$(cs_fw_file "$1" "$2")"; }
# A commit in the origin's source repo, not yet pushed; then pushed.
cs_fw_commit() {
    git -C "$UH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
        commit -q --allow-empty -m "mirror lag $1"
    git -C "$UH_ORIGIN_SRC" rev-parse HEAD
}
cs_fw_sync() { git -C "$UH_ORIGIN_SRC" push -q -f "$UH_ORIGIN_BARE" "$2:refs/heads/$1"; }
cs_fw_floor="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

# Admitted into fetch-wait with the gate's xs row and a floor; a newer
# announcement To the operator supersedes the wait outside any wake, and
# the re-dispatch must still run what was admitted.
cs_new_store
printf 'revise\n' > "$work/body.tmp"
cs_mid="$("$MAIL" send --from '@carol' --to '@pak' --subject 'supersede topic' \
    --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" 2>/dev/null)"
cs_tid="$(thread_of "$cs_mid")"
once
once
# The announcement goes To the operator; carol's mail is the gated wake
# that admits pak (a non-fleet sender's wake skips the gate).
cs_fw_a="$(cs_fw_commit feature/cs-late)"
cs_fw_r="$(reply_msg '@ci-demo' "$cs_mid" 'pushed' --to '@operator' --upstream-head "feature/cs-late:$cs_fw_a")"
once
printf 'xs' > "$CS_OUT/size"
printf '%s\n' "$cs_fw_floor" > "$CS_OUT/floor"
printf '%s\n' "$cs_start" > "$CS_OUT/checkout"
reply_msg '@carol' "$cs_fw_r" 'review the push' --to '@pak' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "supersede setup: pak waits on the announced head" "xs $cs_fw_floor $cs_start" \
    "$(env_val "$(cs_fw_file "$cs_tid" pak)" SIZE) $(env_val "$(cs_fw_file "$cs_tid" pak)" FLOOR) $(env_val "$(cs_fw_file "$cs_tid" pak)" CHECKOUT)"
rm -f -- "$CS_OUT/size" "$CS_OUT/floor" "$CS_OUT/checkout"
cs_fw_b="$(cs_fw_commit feature/cs-late-2)"
cs_fw_sync feature/cs-late-2 "$cs_fw_b"
reply_msg '@ci-demo' "$cs_fw_r" 'pushed again' --to '@operator' \
    --upstream-head "feature/cs-late-2:$cs_fw_b" >/dev/null
once
[[ -s "$STUB_ARGV_LOG" ]] || once
check "supersede: the re-dispatch runs the admitted xs row" "csonnet1-ropus1" "$(flag_value --pipeline)"
check "supersede: ... with the admitted floor" "$cs_fw_floor" "$(flag_value --finalize-floor)"
check "supersede: ... and the admitted start sha" "$cs_start" "$(flag_value --checkout)"
check "supersede: ... at the newest head" "upstream=$cs_fw_b" "$(flag_value --extra-ref)"

# A re-freeze beneath pak's own xs/floor wake queues the panel's follow
# seats; their records are written in pak's wake but are not pak's. The
# launcher wrapper snapshots fetch-wait/ at pak's spawn, before the same
# pass re-dispatches (and so removes) the followers' records.
cs_real_launcher="$FORK_SANDBOX_POSTMASTER_LAUNCHER"
cs_snap_launcher="$CS_OUT/launcher-snap.sh"
cat > "$cs_snap_launcher" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CS_FW_SNAP:-}" && ! -e "$CS_FW_SNAP" ]]; then
    mkdir -p -- "$CS_FW_SNAP"
    cp -R -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/fetch-wait/." "$CS_FW_SNAP/" 2>/dev/null
fi
exec "$CS_REAL_LAUNCHER" "$@"
EOF
chmod +x "$cs_snap_launcher"
cs_new_store
cs_fw_old="$(cs_fw_commit feature/cs-replay)"
printf 'v1\n' > "$work/body.tmp"
cs_mid="$("$MAIL" send --from '@carol' --to '@panel' --subject 'panel v1 replay' \
    --body "$work/body.tmp" --hops 8 --review-target "feature/cs-replay:$cs_fw_old" 2>/dev/null)"
cs_tid="$(thread_of "$cs_mid")"
once
for cs_s in kai kye; do
    cs_fw_set "$cs_tid" "$cs_s" SINCE "$(( $(date +%s) - 130 ))"
    cs_fw_set "$cs_tid" "$cs_s" NOT_BEFORE 0
done
once
cs_fw_new="$(git -C "$UH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
    commit-tree -m "unrelated replay" "$(git -C "$UH_ORIGIN_SRC" mktree < /dev/null)")"
cs_fw_sync feature/cs-replay "$cs_fw_new"
cs_fw_r="$(reply_msg '@ci-demo' "$cs_mid" 'force-pushed' --to '@operator' \
    --upstream-head "feature/cs-replay:$cs_fw_new")"
once
printf 'xs' > "$CS_OUT/size"
printf '%s\n' "$cs_fw_floor" > "$CS_OUT/floor"
cs_snap="$CS_OUT/fw-snap"
rm -rf -- "$cs_snap"
: > "$STUB_ARGV_LOG"
reply_msg '@carol' "$cs_fw_r" 'review the new head' --to '@pak' >/dev/null
FORK_SANDBOX_POSTMASTER_LAUNCHER="$cs_snap_launcher" CS_FW_SNAP="$cs_snap" \
    CS_REAL_LAUNCHER="$cs_real_launcher" once
contains "followers setup: the re-freeze queued the panel" "$(cat "$work/once.out")" \
    "pm review-target-refrozen-wake thread=${cs_tid:0:8} agents=kai,kye"
contains "followers setup: beneath pak's own xs wake" "$(pipeline_events)" \
    "agent=pak size=xs requested=xs spec=csonnet1-ropus1 floor=$cs_fw_floor"
for cs_s in kai kye; do
    check "followers: $cs_s's record is byte-identical to a plain seat's" \
        "$(printf 'TRIGGER=%s\nRETRY=0\nKIND=review-target\nKEY=\nSINCE=0\nATTEMPTS=0\nNOT_BEFORE=0\n' "$cs_mid")" \
        "$(cat "$cs_snap/$cs_tid/$cs_s" 2>/dev/null)"
done
unset FORK_SANDBOX_POSTMASTER_FETCH_WINDOW

finish_suite
