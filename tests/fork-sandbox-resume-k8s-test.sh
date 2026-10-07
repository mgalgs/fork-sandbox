#!/usr/bin/env bash
# fork-sandbox-resume-k8s-test.sh — --resume <state-dir> --k8s, driven for
# real against a stubbed git + kubectl
#
# Usage: tests/fork-sandbox-resume-k8s-test.sh
#
# tests/fork-sandbox-resume-orchestration-test.sh proves the LOCAL --resume
# path end to end, and says outright that its own --k8s cases are limited
# to flag-wiring, not a real submit against a stub cluster. But the client
# this feature was built for drives fork-sandbox from inside a Kubernetes
# pod, submitting --k8s runs exclusively -- so THIS path, not the local
# one, is the one the brief says must work end to end. This suite drives
# `fork-sandbox.sh --resume <state-dir> --k8s --base ...` itself (never
# fork-sandbox-k8s.sh directly) twice, against a stubbed git (no-op push,
# fetch that fast-forwards the real project repo's branch) and a stubbed
# kubectl (every call fork-sandbox-k8s-test.sh's own runstub_dir fixture
# already answers, plus a new case for the /work/session-store pull-back
# cmd_collect does -- not exercised by that file at all, since nothing
# there ever sets --session-state).
#
# It covers:
#   - a fresh state dir's first --k8s submit: returns well under the
#     launcher's own 60s budget, prints the run dir, and that run's
#     submit+wait+collect actually completes in the background, fetching
#     a real commit back into the project repo under a fresh branch name.
#   - a repeat submit of the SAME note: prints the same run dir, triggers
#     no second kubectl apply (no second Job).
#   - a second submit with --base <branch1>: reuses the exact branch name
#     (via --allow-existing-branch, forwarded through the real --k8s
#     dispatch), fast-forwards it (both commits reachable), and threads
#     the first run's discovered session id into the second run's own
#     run.env as resume_session -- proof fs_resume_prior_session_id and
#     --resume-session really make it through fork-sandbox.sh's --k8s
#     dispatch into fork-sandbox-k8s.sh's cmd_submit, not just reasoned
#     about.
#   - the client's own session.json, and fork-sandbox's own lock/runs.tsv/
#     last-run-dir bookkeeping, survive BOTH runs byte-identical --
#     cmd_collect's session-store pull-back does an atomic swap of
#     whatever directory --session-state named, and --resume historically
#     pointed that straight at the state dir itself.
#   - status --json reports state: replied with a reply_file once run 2
#     finishes.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# Restricted to system tool directories only, same as
# tests/fork-sandbox-k8s-test.sh's own header: a developer's workstation
# may have a real kubectl ahead of the stub, or (worse) a real `claude` in
# ~/.local/bin that cmd_wait's keeper falls back to by $HOME alone -- see
# k8s_claude_keeper_start. HOME is pinned to a fresh fixture directory
# below for the same reason.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
status_sh="$repo_dir/scripts/fork-sandbox-status.sh"
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
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

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

launcher_home="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-home.XXXXXX)"
mkdir -p "$launcher_home/.claude" "$launcher_home/src"
claude_future_ms=$(( ($(date +%s) + 10800) * 1000 ))
cat > "$launcher_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "fixture-token-do-not-leak", "refreshToken": "fixture-refresh", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON

config_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-cfg.XXXXXX)"
cat > "$config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
install -m 600 /dev/null "$config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$config_dir/pi.env"
chmod 600 "$config_dir/pi.env"

proj_dir="$(mktmp_dir "$launcher_home/src/proj.XXXXXX")"
git -C "$proj_dir" init -q
git -C "$proj_dir" config user.email t@fork-sandbox.invalid
git -C "$proj_dir" config user.name Tester
git -C "$proj_dir" commit -q --allow-empty -m init

notes_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-notes.XXXXXX)"
note1="$notes_dir/note1.md"; printf 'first note\n' > "$note1"
note2="$notes_dir/note2.md"; printf 'second note\n' > "$note2"

state_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-state.XXXXXX)"

# The client's own file, at the state dir's own top level -- fork-sandbox
# never reads or writes it (see fork-sandbox-resume-lib.sh's header), and
# the whole point of this fixture is to prove that claim: a prior bug had
# cmd_collect's session-store pull-back swap (move aside, install the
# pulled store, rm -rf the old one) pointed straight at the state dir
# itself, which would have deleted this exact file mid-run. Written before
# either submit below, and compared byte-for-byte after each.
session_json="$state_dir/session.json"
printf '{"client-owned":true,"do-not-touch":"fork-sandbox never reads or writes this"}\n' > "$session_json"
session_json_sha() { sha256sum -- "$session_json" 2>/dev/null | cut -d' ' -f1; }
session_json_sha_orig="$(session_json_sha)"

# A canned per-project session-store transcript directory, one per run, so
# fs_session_discover_id (maxdepth 2, newest *.jsonl wins) has something
# real to discover after each collect's session-store pull-back. Session
# ids are deliberately distinct strings, not timestamps: the test asserts
# on the id's own text, not on "whichever file is newest".
session_fixture_1="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-sess1.XXXXXX)"
mkdir -p "$session_fixture_1/proj-enc"
printf '{"type":"summary"}\n' > "$session_fixture_1/proj-enc/aaaa1111aaaa1111aaaa1111aaaa1111.jsonl"

session_fixture_2="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-sess2.XXXXXX)"
mkdir -p "$session_fixture_2/proj-enc"
printf '{"type":"summary"}\n' > "$session_fixture_2/proj-enc/bbbb2222bbbb2222bbbb2222bbbb2222.jsonl"

# ---------------------------------------------------------------------------
# Stubbed git + kubectl -- the same fixture shape as
# tests/fork-sandbox-k8s-test.sh's own runstub_dir, plus a new case for the
# /work/session-store pull-back cmd_collect does (never exercised there,
# since nothing in that file's runstub_run ever sets --session-state).
# ---------------------------------------------------------------------------

stub_bin="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-stub.XXXXXX)"
cat > "$stub_bin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*)
        base="${K8S_STUB_BASE_SHA:-$(git -C . rev-parse -q --verify HEAD 2>/dev/null || true)}"
        for arg in "$@"; do
            case "$arg" in
                refs/heads/*:refs/heads/*)
                    tip="$base"
                    if [[ -n "${K8S_STUB_FETCH_REF:-}" ]]; then
                        parent="$(git -C . rev-parse -q --verify "$base" 2>/dev/null || true)"
                        if [[ -n "$parent" ]]; then
                            tip="$(GIT_AUTHOR_NAME=stub-fetch GIT_AUTHOR_EMAIL=stub-fetch@fork-sandbox.invalid \
                                GIT_COMMITTER_NAME=stub-fetch GIT_COMMITTER_EMAIL=stub-fetch@fork-sandbox.invalid \
                                git -C . commit-tree "$(git -C . hash-object -t tree /dev/null)" -p "$parent" -m "stub: fetched commit")"
                        fi
                    fi
                    [[ -n "$tip" ]] && git -C . update-ref "${arg#*:}" "$tip"
                    ;;
            esac
        done
        exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
chmod +x "$stub_bin/git"

outbox_fixture="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-outbox.XXXXXX)"
printf 'an artifact\n' > "$outbox_fixture/hello.txt"
printf 'first agent reply\n' > "$outbox_fixture/reply.md"
evidence_fixture="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-evidence.XXXXXX)"
printf 'first run event\n' > "$evidence_fixture/events.jsonl"

cat > "$stub_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${K8S_STUB_LOG:-/dev/null}"
case " $* " in
    *"context-extract.sh /work/session-store "*) cat >/dev/null; exit 0 ;;
    *"context-extract.sh "*) cat >/dev/null; exit 0 ;;
    *"--field-manager=fork-sandbox-k8s-claude-token"*) cat >/dev/null; exit "${K8S_STUB_APPLY_RC:-0}" ;;
    *" apply -f - --server-side "*)
        # The bare Job apply (never the field-managered secret applies
        # above, which already matched): a configurable stall here, with
        # nothing else, lands squarely in the window run.env's
        # INPUTS_PUSH_EXPECTED=true already covers but INPUTS_PUSH_COMPLETE
        # does not yet -- see the "status --json during a live submit"
        # case below.
        cat >/dev/null; sleep "${K8S_STUB_JOB_APPLY_SLEEP:-0}"; exit "${K8S_STUB_APPLY_RC:-0}" ;;
    *" apply -f -"*) cat >/dev/null; exit "${K8S_STUB_APPLY_RC:-0}" ;;
    *" wait "*) exit 0 ;;
    *" get pod -l job-name="*) printf 'stub-pod\n'; exit 0 ;;
    *" -o jsonpath={.status.phase} "*) printf '%s\n' "${K8S_STUB_POD_PHASE:-Running}"; exit 0 ;;
    *" get pod "*)
        printf '%s\n' '{"spec":{"containers":[{"name":"agent"}]}}' ;;
    *" get "*) printf 'stub-pod\n' ;;
    *" /work/repo.git rev-parse "*) printf '%s\n' "${K8S_STUB_BASE_SHA:-}"; exit 0 ;;
    *" delete "*) exit 0 ;;
    *" logs "*) printf 'stub pod log\n'; exit 0 ;;
    *" tar cf - -C /work/session-store "*)
        if [[ -n "${K8S_STUB_SESSION_DIR:-}" ]]; then
            ( cd "$K8S_STUB_SESSION_DIR" && tar cf - . ) || true
        else
            tar cf - --files-from /dev/null 2>/dev/null || true
        fi
        exit 0 ;;
    *" tar cf - -C /work/outbox "*)
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        exit "${K8S_STUB_OUTBOX_RC:-0}" ;;
    *"cd /work && find . "*)
        ( cd "$K8S_STUB_EVIDENCE_DIR" && tar cf - ./events.jsonl ) ; exit 0 ;;
    *" cat /work/.run-complete "*) printf '%s\n' "${K8S_STUB_RUN_COMPLETE_VALUE:-0}" ;;
esac
exit 0
STUB
chmod +x "$stub_bin/kubectl"

run_fs() {
    HOME="$launcher_home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    K8S_STUB_FETCH_REF=1 K8S_STUB_OUTBOX_DIR="$outbox_fixture" \
    K8S_STUB_EVIDENCE_DIR="$evidence_fixture" \
    timeout 60 "$launcher" "$@"
}

wait_for_summary() {
    local rd="$1"
    for _ in $(seq 1 150); do
        [[ -s "$rd/summary.json" ]] && return 0
        sleep 0.2
    done
    return 1
}

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s: first submit starts a fresh conversation ==\n'
# ---------------------------------------------------------------------------
proj_head="$(git -C "$proj_dir" rev-parse HEAD)"
export K8S_STUB_SESSION_DIR="$session_fixture_1" K8S_STUB_BASE_SHA="$proj_head"
rd1="$(run_fs --resume "$state_dir" --k8s --harness claude --model claude-sonnet-5 "$proj_dir" "$note1")"
rc1=$?
check "submit 1: exits 0" "0" "$rc1"
if [[ -n "$rd1" && -d "$rd1" ]]; then
    ok "submit 1: printed a real run dir"
else
    no "submit 1: printed a real run dir" "got: '$rd1'"
fi
if [[ -s "$rd1/run.env" ]]; then
    ok "submit 1: run.env exists as soon as the run dir is returned"
else
    no "submit 1: run.env exists as soon as the run dir is returned"
fi

if wait_for_summary "$rd1"; then
    ok "submit 1: the backgrounded submit+wait+collect actually finished"
else
    no "submit 1: the backgrounded submit+wait+collect actually finished" "no summary.json after 30s"
fi
check "submit 1: summary.json exit_code" "0" "$(jq -r '.exit_code' "$rd1/summary.json" 2>/dev/null)"
check "submit 1: client's session.json is untouched, byte-identical" \
    "$session_json_sha_orig" "$(session_json_sha)"

branch1="$(sed -n 's/^branch=//p' "$rd1/run.env" 2>/dev/null | head -1)"
if [[ -n "$branch1" ]]; then
    ok "submit 1: a fresh branch was minted"
else
    no "submit 1: a fresh branch was minted" "no branch= in run.env"
fi
check "submit 1: the branch landed exactly one new commit (init + fetched)" \
    "2" "$(git -C "$proj_dir" rev-list --count "$branch1" 2>/dev/null)"
check "submit 1: summary.json's session_id is the fixture's discovered id" \
    "aaaa1111aaaa1111aaaa1111aaaa1111" "$(jq -r '.session_id' "$rd1/summary.json" 2>/dev/null)"

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s: a repeat submit of the SAME note is idempotent ==\n'
# ---------------------------------------------------------------------------
rd1b="$(run_fs --resume "$state_dir" --k8s --harness claude --model claude-sonnet-5 "$proj_dir" "$note1")"
check "repeat submit: prints the same run dir" "$rd1" "$rd1b"

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s --base: continues the SAME branch, fast-forwarded,\n   and threads run 1'"'"'s session id into run 2 ==\n'
# ---------------------------------------------------------------------------
branch1_tip="$(git -C "$proj_dir" rev-parse "$branch1")"
printf 'second agent reply\n' > "$outbox_fixture/reply.md"
printf 'second run event\n' > "$evidence_fixture/events.jsonl"
export K8S_STUB_SESSION_DIR="$session_fixture_2" K8S_STUB_BASE_SHA="$branch1_tip"
rd2="$(run_fs --resume "$state_dir" --base "$branch1" --k8s --harness claude --model claude-sonnet-5 \
    "$proj_dir" "$note2")"
rc2=$?
check "submit 2 (--base): exits 0" "0" "$rc2"
if wait_for_summary "$rd2"; then
    ok "submit 2: the backgrounded submit+wait+collect actually finished"
else
    no "submit 2: the backgrounded submit+wait+collect actually finished" "no summary.json after 30s"
fi
check "submit 2: summary.json exit_code" "0" "$(jq -r '.exit_code' "$rd2/summary.json" 2>/dev/null)"
check "submit 2: client's session.json is STILL untouched, byte-identical" \
    "$session_json_sha_orig" "$(session_json_sha)"

branch2="$(sed -n 's/^branch=//p' "$rd2/run.env" 2>/dev/null | head -1)"
check "submit 2: reuses the exact same branch name" "$branch1" "$branch2"
check "submit 2: the branch now carries BOTH fetched commits (fast-forwarded)" \
    "3" "$(git -C "$proj_dir" rev-list --count "$branch1" 2>/dev/null)"
check "submit 2: run.env carries resume_session with run 1's own discovered id" \
    "resume_session=aaaa1111aaaa1111aaaa1111aaaa1111" "$(grep '^resume_session=' "$rd2/run.env" 2>/dev/null)"
check "submit 2: summary.json's session_id moved on to the newly-discovered one" \
    "bbbb2222bbbb2222bbbb2222bbbb2222" "$(jq -r '.session_id' "$rd2/summary.json" 2>/dev/null)"
check "submit 1: agent reply remains its own" "first agent reply" "$(cat "$rd1/outbox/reply.md" 2>/dev/null)"
check "submit 2: agent reply belongs to this run" "second agent reply" "$(cat "$rd2/outbox/reply.md" 2>/dev/null)"
check "submit 1: evidence remains its own" "first run event" "$(cat "$rd1/evidence/events.jsonl" 2>/dev/null)"
check "submit 2: evidence belongs to this run" "second run event" "$(cat "$rd2/evidence/events.jsonl" 2>/dev/null)"

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s: fork-sandbox'"'"'s own bookkeeping survived both runs ==\n'
# ---------------------------------------------------------------------------
# The client's own session.json was already checked byte-for-byte after
# each submit above, right where each collect's session-store pull-back
# swap would have clobbered it under the prior bug (--session-state
# pointed at the state dir itself, so cmd_collect's atomic swap deleted
# session.json along with everything else here the moment a collect ran).
# What is left to check here is fork-sandbox's OWN bookkeeping, which --
# unlike session.json -- this project does read and write, and must still
# find intact after both collects.
if [[ -f "$state_dir/.fork-sandbox/runs.tsv" ]]; then
    ok "the idempotency map survived both collects"
else
    no "the idempotency map survived both collects" "$(ls -la "$state_dir" "$state_dir/.fork-sandbox" 2>&1)"
fi
if [[ -f "$state_dir/.fork-sandbox/last-run-dir" ]]; then
    ok "the last-run-dir pointer survived both collects"
else
    no "the last-run-dir pointer survived both collects" "$(ls -la "$state_dir/.fork-sandbox" 2>&1)"
fi
check "the idempotency map still has exactly 2 rows (note1 once, note2 once)" \
    "2" "$(wc -l < "$state_dir/.fork-sandbox/runs.tsv" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s: status --json reports state: replied with a reply_file ==\n'
# ---------------------------------------------------------------------------
json2="$("$status_sh" --json "$rd2" 2>&1)"
check "status --json: state is replied" "replied" "$(jq -r '.state' <<< "$json2" 2>/dev/null)"
check "status --json: reply_file is the run dir's outbox/reply.md" \
    "$rd2/outbox/reply.md" "$(jq -r '.reply_file' <<< "$json2" 2>/dev/null)"
if [[ -s "$rd2/outbox/reply.md" ]]; then
    ok "status --json: reply_file actually exists once replied"
else
    no "status --json: reply_file actually exists once replied" "$(ls -la "$rd2/outbox" 2>&1)"
fi

# ---------------------------------------------------------------------------
printf '\n== --resume --k8s: status --json never reports failed for a live submit ==\n'
# ---------------------------------------------------------------------------
# A real submit's run.env gets its INPUTS_PUSH_EXPECTED=true marker (and a
# version=, started_at=...) well before kubectl ever applies the Job, and
# k8s_record_client_pid (cmd_run's only writer of k8s_client_pid) does not
# run until cmd_submit has returned -- after the Job apply, the pod-ready
# wait and every context push. --resume's own worker returns the run dir
# to this test the moment "run dir:" is scraped from its log, which is
# earlier still. So right after run_fs below returns, the submit it just
# started is almost certainly still in flight: exactly the window a prior
# bug reported as terminally "failed" (run_state saw network=cluster, no
# pid file, no k8s_client_pid yet, and called that "abandoned") even
# though the submit was very much alive and would go on to reply. The Job
# apply's stub sleep below widens that window enough to poll it for real
# instead of relying on it happening to still be open.
note3="$notes_dir/note3.md"; printf 'third note\n' > "$note3"
rm -f -- "$outbox_fixture/reply.md"
branch2_tip="$(git -C "$proj_dir" rev-parse "$branch2")"
export K8S_STUB_SESSION_DIR="$session_fixture_2" K8S_STUB_BASE_SHA="$branch2_tip"
rd3="$(K8S_STUB_JOB_APPLY_SLEEP=3 run_fs --resume "$state_dir" --base "$branch2" --k8s \
    --harness claude --model claude-sonnet-5 "$proj_dir" "$note3")"
rc3=$?
check "submit 3: exits 0" "0" "$rc3"

saw_non_terminal=false
saw_failed=false
for _ in $(seq 1 40); do
    [[ -f "$rd3/summary.json" ]] && break
    state3="$(jq -r '.state // empty' <<< "$("$status_sh" --json "$rd3" 2>/dev/null)" 2>/dev/null)"
    case "$state3" in
        queued|working) saw_non_terminal=true ;;
        failed) saw_failed=true ;;
    esac
    sleep 0.1
done
if "$saw_failed"; then
    no "submit 3: status --json never reports failed while the submit is still in flight" \
        "saw state: failed before the run finished"
else
    ok "submit 3: status --json never reports failed while the submit is still in flight"
fi
if "$saw_non_terminal"; then
    ok "submit 3: status --json reported queued/working during the live submit"
else
    no "submit 3: status --json reported queued/working during the live submit" \
        "never observed queued or working -- the poll loop may have missed the window"
fi
if wait_for_summary "$rd3"; then
    ok "submit 3: finished after the live poll"
else
    no "submit 3: finished after the live poll"
fi
if [[ -s "$rd3/outbox/reply.md" ]] \
    && [[ "$(cat "$rd3/outbox/reply.md")" != 'second agent reply' ]]; then
    ok "submit 3: missing agent reply falls back to this run's rendered account"
else
    no "submit 3: missing agent reply falls back to this run's rendered account"
fi

printf '\n== --resume --k8s: failed submit and stale push are terminal ==\n'
note4="$notes_dir/note4.md"; printf 'fourth note\n' > "$note4"
branch3_tip="$(git -C "$proj_dir" rev-parse "$branch2")"
export K8S_STUB_BASE_SHA="$branch3_tip"
rd4="$(K8S_STUB_APPLY_RC=1 run_fs --resume "$state_dir" --base "$branch2" --k8s \
    --harness claude --model claude-sonnet-5 "$proj_dir" "$note4")"
for _ in $(seq 1 100); do
    [[ "$("$status_sh" --json "$rd4" 2>/dev/null | jq -r '.state' 2>/dev/null)" == failed ]] && break
    sleep 0.2
done
check "failed submit: status reaches failed" "failed" \
    "$("$status_sh" --json "$rd4" 2>/dev/null | jq -r '.state' 2>/dev/null)"

stale_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
tmpdirs+=("$stale_dir")
printf 'version=1\nnetwork=cluster\nbranch=stale\nINPUTS_PUSH_EXPECTED=true\nSUBMITTED_AT=1\n' > "$stale_dir/run.env"
check "abandoned push: status is failed after the staleness bound" "failed" \
    "$("$status_sh" --json "$stale_dir" 2>/dev/null | jq -r '.state' 2>/dev/null)"

if wait_for_summary "$rd3"; then
    ok "submit 3: the backgrounded submit+wait+collect actually finished"
else
    no "submit 3: the backgrounded submit+wait+collect actually finished" "no summary.json after 30s"
fi
check "submit 3: status --json settles on replied once done" \
    "replied" "$(jq -r '.state' <<< "$("$status_sh" --json "$rd3" 2>/dev/null)" 2>/dev/null)"

printf '\n== --resume --k8s: an occupied explicit outbox cannot supply a later reply ==\n'
shared_state="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-shared-state.XXXXXX)"
shared_root="$(mktmp_dir /var/tmp/claude-scratch/fs-resumek8s-shared.XXXXXX)"
printf 'first shared reply\n' > "$outbox_fixture/reply.md"
printf 'first shared event\n' > "$evidence_fixture/events.jsonl"
shared_rd1="$(run_fs --resume "$shared_state" --k8s --harness claude --model claude-sonnet-5 \
    --outbox-dir "$shared_root/outbox" "$proj_dir" "$note1")"
wait_for_summary "$shared_rd1" || no "shared outbox: first run completed"
check "shared outbox: first reply extracted" "first shared reply" \
    "$(cat "$shared_rd1/outbox/reply.md" 2>/dev/null)"
shared_branch="$(sed -n 's/^branch=//p' "$shared_rd1/run.env" | head -1)"
shared_tip="$(git -C "$proj_dir" rev-parse "$shared_branch")"
printf 'second shared reply\n' > "$outbox_fixture/reply.md"
printf 'second shared event\n' > "$evidence_fixture/events.jsonl"
shared_rd2="$(K8S_STUB_BASE_SHA="$shared_tip" run_fs --resume "$shared_state" --base "$shared_branch" \
    --k8s --harness claude --model claude-sonnet-5 --outbox-dir "$shared_root/outbox" "$proj_dir" "$note2")"
wait_for_summary "$shared_rd2" || no "shared outbox: second run completed"
if [[ -s "$shared_rd2/outbox/reply.md" ]] \
    && [[ "$(cat "$shared_rd2/outbox/reply.md")" != 'first shared reply' ]]; then
    ok "shared outbox: refused extraction uses this run's rendered reply"
else
    no "shared outbox: refused extraction reused the earlier reply"
fi
check "shared outbox: a refused extraction still replies, with the rendered account" "replied" \
    "$("$status_sh" --json "$shared_rd2" 2>/dev/null | jq -r '.state' 2>/dev/null)"
if [[ ! -e "$shared_rd2/events.jsonl" ]]; then
    ok "shared evidence: refused extraction is not mirrored into this run"
else
    no "shared evidence: refused extraction was mirrored into this run"
fi

tmpdirs+=("$rd1" "$rd2" "$rd3" "$shared_rd1" "$shared_rd2")

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
