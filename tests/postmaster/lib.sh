# shellcheck shell=bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/lib.sh — Fixtures and helpers shared by the
# fork-sandbox-postmaster.sh suite's files, tests/postmaster/NN-*.sh, which
# tests/fork-sandbox-postmaster-test.sh runs side by side. Sourced, never
# run: each file sources it first and so gets fixtures of its own -- work
# dir, stub argv log, run dirs, fleet and personas files, project repo.
#
# Real fork-sandbox-mail.sh and fork-sandbox-fleet.sh are used throughout
# (seeded with a small invented fleet); only fork-sandbox.sh is a stub
# resolved from PATH by bare name, matching how pm_spawn_wake invokes it.
# The stub records every invocation's argv (one arg per line, one
# "----CALL----" marker per call) and fabricates a run dir with an
# outbox/; tests control terminal state themselves by writing exit-code
# and outbox/mail-*.md files by hand, except where STUB_IMMEDIATE_EXIT is
# set.

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
postmaster="$repo_dir/scripts/fork-sandbox-postmaster.sh"
MAIL="$repo_dir/scripts/fork-sandbox-mail.sh"
FLEET="$repo_dir/scripts/fork-sandbox-fleet.sh"
# shellcheck disable=SC2034  # used by the test files
MAIL_RENDER="$repo_dir/scripts/fork-sandbox-mail-render.py"

pass=0
fail=0
tmpdirs=()

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
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' unexpectedly found in: $haystack" ;;
        *) ok "$label" ;;
    esac
}

refuses() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        no "$label" "it succeeded; output: $out"
    else
        ok "$label"
    fi
}

# Sets $1 to a fresh temp dir and registers it for cleanup -- a nameref
# out-param, same as fork-sandbox-fleet-test.sh's new_root.
new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

# Same as new_root, but under /var/tmp/claude-scratch: FORK_SANDBOX_MAIL_ROOT
# feeds fs_require_scratch_handoff via HANDOFFS at `deliver` startup (see
# fork-sandbox-postmaster.sh), so a bare mktemp -d root (usually under /tmp)
# would fail that check before ever reaching the routing logic under test.
new_scratch_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d /var/tmp/claude-scratch/fs-postmaster-test.XXXXXX)"
    tmpdirs+=("$out_ref")
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

# ---- shared fixtures: a small invented fleet, reused across most groups ----

new_root FORK_SANDBOX_FLEET_FILE_DIR
export FORK_SANDBOX_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE_DIR/fleet.yaml"
new_root FORK_SANDBOX_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR
new_root FORK_SANDBOX_PRESETS_DIR
export FORK_SANDBOX_PRESETS_DIR

# A real preset FILE (content is irrelevant -- `fleet check`'s preset
# check is existence-only, and this fixture's stub fork-sandbox.sh never
# actually compiles it) so the preset-seat fixture below passes `fleet
# check` at fixture-setup time.
cat > "$FORK_SANDBOX_PRESETS_DIR/solo.yaml" <<'EOF'
# stub preset for postmaster --preset passthrough tests
EOF

cat > "$FORK_SANDBOX_PERSONAS_DIR/alice.md" <<'EOF'
---
model: opus
---
Alice reviews code carefully, flagging subtle bugs before they ship.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/bob.md" <<'EOF'
---
thinking: medium
---
Bob thinks slowly and precisely about edge cases.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/carol.md" <<'EOF'
Carol keeps her replies short.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/dana.md" <<'EOF'
Dana opts out of Cc wakes; only a direct To wakes her.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/eve.md" <<'EOF'
Eve is the codex seat used by the session-resume tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/frank.md" <<'EOF'
Frank is the non-sealed pi seat used by the session-resume tests -- bob is
the sealed sibling, wired the same way (see the "sealed pi seat" resume
group): agent-sandboxed's own --session-dir/--session-id carry it through.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/gina.md" <<'EOF'
Gina is the preset seat used by the --preset passthrough tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/sam.md" <<'EOF'
Sam always owes a reply (on-silence: flag), used by the silent-wake tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/karen.md" <<'EOF'
Karen is a plain backend: k8s seat with no grant requirement.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/karl.md" <<'EOF'
Karl is a backend: k8s seat with grant: required, used by the hold tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/kara.md" <<'EOF'
Kara is a claude backend: k8s seat with refresh-at, used by the refresh-at tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/kim.md" <<'EOF'
---
thinking: medium
---
Kim is a pi/k8s seat with an endpoint, used by the endpoint/pi-args tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/ken.md" <<'EOF'
Ken is the review-target: sets backend: k8s seat, used by the review-target tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/kai.md" <<'EOF'
Kai is the review-target: follow backend: k8s seat, used by the review-target tests.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/kye.md" <<'EOF'
Kye is kai's fellow review-target: follow seat, so a panel has two followers.
EOF

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  alice: {}
  bob:
    harness: pi
    network: sealed
  carol: {}
  eve:
    harness: codex
  frank:
    harness: pi
    model: vendor/model
  dana:
    wake-on-cc: false
  sam:
    on-silence: flag
  gina:
    harness: pi
    model: vendor/ginamodel
    preset: solo
  karen:
    backend: k8s
  karl:
    backend: k8s
    grant: required
  kim:
    harness: pi
    model: vendor/kimmodel
    backend: k8s
    endpoint: kim-endpoint
    refresh-at: 0.4
  kara:
    harness: claude
    backend: k8s
    refresh-at: 0.4
  ken:
    backend: k8s
    review-target: sets
  kai:
    backend: k8s
    review-target: follow
  kye:
    backend: k8s
    review-target: follow
lists:
  team:
    members: [alice, bob, carol]
  panel:
    members: [kai, kye]
EOF

if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

# ---- stub fork-sandbox.sh, resolved via FORK_SANDBOX_POSTMASTER_LAUNCHER
# (pm_spawn_wake resolves the real thing through script_dir, not PATH, so
# a plain PATH stub would be shadowed by the checkout's own scripts/) ----

new_root STUB_BIN
new_root STUB_RUN_PREFIX
export STUB_RUN_PREFIX
STUB_ARGV_LOG="$work/argv.log"
export STUB_ARGV_LOG
: > "$STUB_ARGV_LOG"

cat > "$STUB_BIN/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf -- '----CALL----\n' >> "$STUB_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_ARGV_LOG"; done
if [[ -n "${STUB_BALANCE_LOG:-}" ]]; then
    printf 'thread=%s agent=%s headers=%s\n' "${FS_BALANCE_THREAD:-}" \
        "${FS_BALANCE_AGENT:-}" "${FS_BALANCE_ROOT_HEADERS_FILE:-}" >> "$STUB_BALANCE_LOG"
    [[ -f "${FS_BALANCE_ROOT_HEADERS_FILE:-}" ]] && \
        cat "$FS_BALANCE_ROOT_HEADERS_FILE" >> "$STUB_BALANCE_LOG"
fi
# STUB_SIGNAL_PARENT ("<signal> <n> <counter-file>"): the n-th call counted
# in <counter-file> sends <signal> to the postmaster that launched it -- a
# pod replaced mid-pass. KILL dies before launching; TERM launches normally.
if [[ -n "${STUB_SIGNAL_PARENT:-}" ]]; then
    read -r _sig _n _counter <<< "$STUB_SIGNAL_PARENT"
    echo x >> "$_counter"
    if (( $(wc -l < "$_counter") == _n )); then
        # The launch runs inside a command substitution, so the parent may
        # be a subshell: signal the outermost postmaster ancestor.
        _p="$PPID" _target=""
        while [[ "$_p" -gt 1 ]] && tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null \
                | grep -q 'fork-sandbox-postmaster\.sh'; do
            _target="$_p"
            _p="$(awk '{print $4}' "/proc/$_p/stat")"
        done
        kill "-$_sig" "${_target:-$PPID}"
        [[ "$_sig" != KILL ]] || exit 1
    fi
fi
run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"

# A `--k8s` invocation stands in for the whole `fork-sandbox-k8s.sh run`
# verb (see fork-sandbox-k8s-wake.sh, which execs this stub as its own
# fs-argv element 0): print the run-dir line, write that dir's
# summary.json, write a reply into --outbox-dir, exit $STUB_K8S_EXIT.
is_k8s=0
outbox=""
args=("$@")
for (( _i = 0; _i < ${#args[@]}; _i++ )); do
    case "${args[$_i]}" in
        --k8s) is_k8s=1 ;;
        --outbox-dir) outbox="${args[$(( _i + 1 ))]}" ;;
    esac
done

if (( is_k8s )); then
    rc="${STUB_K8S_EXIT:-0}"
    [[ -z "${STUB_K8S_NO_CANDIDATE:-}" ]] || echo 'Error: headroom: no candidate' >&2
    # STUB_K8S_EXIT_MAP ("agent=rc agent=rc") overrides rc per seat, keyed
    # on the agent name inside the wake's --branch.
    for _i in "${!args[@]}"; do
        [[ "${args[$_i]}" == --branch ]] && branch="${args[$(( _i + 1 ))]}"
    done
    for _pair in ${STUB_K8S_EXIT_MAP:-}; do
        [[ "${branch:-}" == *"-${_pair%%=*}-"* ]] && rc="${_pair#*=}"
    done
    if [[ -z "${STUB_K8S_NO_RUNDIR:-}" ]]; then
        printf '  run dir:  %s\n' "$run_dir" >&2
        if [[ -z "${STUB_K8S_NO_SUMMARY:-}" ]]; then
            printf '{"exit_code": %s}' "${STUB_K8S_SUMMARY_EXIT:-$rc}" > "$run_dir/summary.json"
        fi
    fi
    # STUB_K8S_AGENT_LOG: a file whose content becomes the run's saved
    # agent-container log, where fork-sandbox-k8s.sh collect leaves it.
    if [[ -n "${STUB_K8S_AGENT_LOG:-}" && -z "${STUB_K8S_NO_RUNDIR:-}" ]]; then
        mkdir -p -- "$run_dir/evidence"
        if [[ -n "${STUB_K8S_AGENT_LOG_SYMLINK:-}" ]]; then
            ln -s -- "$STUB_K8S_AGENT_LOG" "$run_dir/evidence/pod-log-agent.log"
        else
            cp -- "$STUB_K8S_AGENT_LOG" "$run_dir/evidence/pod-log-agent.log"
        fi
    fi
    if [[ -n "${STUB_K8S_TERMINAL_JSON:-}" && -z "${STUB_K8S_NO_RUNDIR:-}" ]]; then
        cp -- "$STUB_K8S_TERMINAL_JSON" "$run_dir/terminal-status.json"
    fi
    if [[ -n "${STUB_K8S_TIMEOUT_MSG:-}" ]]; then
        printf 'Error: timed out after 60s waiting for branch\n' >&2
    fi
    if [[ -n "$outbox" && -z "${STUB_K8S_NO_REPLY:-}" ]]; then
        mkdir -p -- "$outbox"
        printf 'Subject: stub k8s reply\n\nhello from k8s stub\n' > "$outbox/mail-1.md"
    fi
    exit "$rc"
fi

mkdir -p -- "$run_dir/outbox" "$run_dir/inbox"
if [[ -n "${STUB_IMMEDIATE_EXIT:-}" ]]; then
    printf '%s\n' "${STUB_IMMEDIATE_EXIT}" > "$run_dir/exit-code"
fi
echo "fork-sandbox: launched in a stub"
printf '  run dir:  %s\n' "$run_dir"
STUB
chmod +x "$STUB_BIN/fork-sandbox.sh"
export FORK_SANDBOX_POSTMASTER_LAUNCHER="$STUB_BIN/fork-sandbox.sh"

# The router now defers routing a message until its thread is quiescent
# (see FORK_SANDBOX_POSTMASTER_DEBOUNCE). Every existing test here posts
# mail and immediately runs `deliver --once`, so the suite-wide default
# is off; the debounce tests below set a nonzero value on their own
# invocations and restore this afterward.
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0

new_root PROJECT_DIR
# A real (throwaway) git repo, not just a directory: pm_lineage_checkout
# (k8s --checkout forwarding, exercised far below) does a real read-only
# git rev-parse against this path, and the stub fork-sandbox.sh never
# touches git itself, so nothing else in this suite needs it to be one.
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m init

# ---- test helpers ----

send_msg() {
    local from="$1" to="$2" subject="$3" body="$4" hops="${5:-8}" cc="${6:-}"
    printf '%s\n' "$body" > "$work/body.tmp"
    local -a extra=()
    [[ -n "$cc" ]] && extra=(--cc "$cc")
    "$MAIL" send --from "$from" --to "$to" --subject "$subject" \
        --body "$work/body.tmp" --hops "$hops" "${extra[@]}" 2>/dev/null
}

reply_msg() {
    local from="$1" reply_to="$2" body="$3"; shift 3
    printf '%s\n' "$body" > "$work/body.tmp"
    "$MAIL" reply --from "$from" --reply-to "$reply_to" --body "$work/body.tmp" "$@" 2>/dev/null
}

thread_of() { "$MAIL" show "$1" 2>/dev/null | sed -n 's/^Thread-ID: //p'; }
hops_of_mid() { "$MAIL" show "$1" 2>/dev/null | sed -n 's/^X-Hops: //p'; }
header_of_file() { sed -n "s/^$2: //p" "$1" | head -n1; }

once() {
    "$postmaster" deliver --project "$PROJECT_DIR" --once >"$work/once.out" 2>"$work/once.err"
}

once_rc() {
    "$postmaster" deliver --project "$PROJECT_DIR" --once >"$work/once.out" 2>"$work/once.err"
    echo $?
}

argv_after() {
    local flag="$1" file="$2"
    awk -v f="$flag" 'found{print; exit} $0==f{found=1}' "$file"
}

# Line number of the LAST occurrence of a flag in the argv log -- used to
# check --preset lands before --harness, not just that both are present.
argv_line_of() {
    local flag="$1" file="$2"
    awk -v f="$flag" '$0==f{n=NR} END{print n+0}' "$file"
}

env_file_for_agent() {
    local agent="$1" f
    for f in "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env; do
        [[ -e "$f" ]] || continue
        grep -q "^AGENT=$agent\$" "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

spawn_count_of() {
    local tid="$1"
    local f="$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
    [[ -f "$f" ]] && wc -l < "$f" || printf '0'
}

handoff_file_for_agent() {
    local agent="$1" f run_id
    f="$(env_file_for_agent "$agent")" || return 1
    run_id="$(basename "$f" .env)"
    printf '%s' "$FORK_SANDBOX_MAIL_ROOT/.postmaster/handoffs/$run_id.md"
}

# env_file_for_agent above returns the FIRST match, which after a harvest
# is a dead run. A wake that follows the last one's harvest wants the live
# one.
live_env_for_agent() {
    local agent="$1" f rid
    for f in "$PM_STATE_DIR/runs"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$PM_STATE_DIR/harvested/$rid" ]] && continue
        grep -q "^AGENT=$agent\$" "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Most recent runs/<run-id>.env for $1, regardless of harvested state -- a
# k8s wake finishes synchronously (FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline)
# within the SAME `once` pass that spawned it, so by the time `once`
# returns it is often already harvested, unlike a local wake (live_env_for_agent
# only ever finds an UNharvested one, which a k8s wake in this test
# mode never stays for long).
latest_env_for_agent() {
    local agent="$1" f
    while IFS= read -r f; do
        grep -q "^AGENT=$agent\$" "$f" && { printf '%s' "$f"; return 0; }
    done < <(for f in "$PM_STATE_DIR/runs"/*.env; do
        [[ -e "$f" ]] && printf '%s %s\n' "$(stat -c %Y -- "$f")" "$f"
    done | sort -rn | cut -d' ' -f2-)
    return 1
}

env_val() { sed -n "s/^$2=//p" "$1" | tail -n1; }

# Ends the live run for $1: exit code $2, then a summary.json naming
# session $3 (or carrying a null session_id when $3 is omitted) -- exit-code
# before summary.json, matching fork-sandbox.sh's own write order (exit-code
# right after the coding leg, summary.json only after run_cleanup and the
# branch fetch-back).
finish_run() {
    local agent="$1" code="$2" sid="${3:-}" env_f run_dir
    env_f="$(live_env_for_agent "$agent")"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$env_f")"
    mkdir -p -- "$run_dir/outbox"
    printf '%s\n' "$code" > "$run_dir/exit-code"
    if [[ -n "$sid" ]]; then
        printf '{"session_id":"%s","session_state":"x"}\n' "$sid" \
            > "$run_dir/summary.json"
    else
        printf '{"session_id":null,"session_state":"x"}\n' > "$run_dir/summary.json"
    fi
}

msg_file_of() {
    local mid="$1" f
    for f in "$FORK_SANDBOX_MAIL_ROOT"/threads/*/*.msg; do
        [[ -e "$f" ]] || continue
        grep -q "^Message-ID: $mid\$" "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# A dead, already-reaped pid: kill -0 on it fails unconditionally, unlike a
# live process the test could accidentally collide with.
dead_pid_of() {
    ( exit 0 ) &
    local p=$!
    wait "$p" 2>/dev/null || true
    printf '%s' "$p"
}

we_json() { "$postmaster" status --thread "$1" --json; }
# we_py <json> <python expr over d>: prints the expression's value.
we_py() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

# The k8s wake seams: a throwaway copy of the wake wrapper next to a stub
# fork-sandbox-k8s.sh, and a wake root under this suite's scratch. Every
# file that wakes a k8s seat calls this first: without it the postmaster
# runs the real wrapper, which reaps through the real fork-sandbox-k8s.sh.
# The wrapper resolves its reap target (`fork-sandbox-k8s.sh rm`) from its
# own script_dir, hence the copy.
k8s_wake_fixture() {
    new_root K8S_WAKE_BIN
    cp -- "$repo_dir/scripts/fork-sandbox-k8s-wake.sh" "$K8S_WAKE_BIN/fork-sandbox-k8s-wake.sh"
    chmod +x -- "$K8S_WAKE_BIN/fork-sandbox-k8s-wake.sh"
    cat > "$K8S_WAKE_BIN/fork-sandbox-k8s.sh" <<STUB
#!/usr/bin/env bash
# Stands in for the real fork-sandbox-k8s.sh's \`rm\`, \`wait\` (the
# adoption probe: exit code read from probe-rc, default 2) and \`resume\`
# verbs: this suite must never shell out to the real cluster script (let
# alone a cluster).
set -uo pipefail
case "\${1:-}" in
    wait)
        printf '%s\n' "\$*" >> "$K8S_WAKE_BIN/probe-calls.log"
        rc=2
        [[ -f "$K8S_WAKE_BIN/probe-rc" ]] && rc="\$(cat "$K8S_WAKE_BIN/probe-rc")"
        exit "\$rc" ;;
    resume)
        printf '%s\n' "\$*" >> "$K8S_WAKE_BIN/resume-calls.log"
        exit 0 ;;
esac
printf '%s\n' "\$*" >> "$K8S_WAKE_BIN/rm-calls.log"
[[ -f "$K8S_WAKE_BIN/rm-rc" ]] && exit "\$(cat "$K8S_WAKE_BIN/rm-rc")"
exit 0
STUB
    chmod +x -- "$K8S_WAKE_BIN/fork-sandbox-k8s.sh"
    export FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT="$K8S_WAKE_BIN/fork-sandbox-k8s-wake.sh"
    new_root K8S_WAKE_ROOT
    export FORK_SANDBOX_POSTMASTER_K8S_WAKE_ROOT="$K8S_WAKE_ROOT"
}

# ---- hook fixtures shared by the on-harvest / on-target / on-quiescent tests ----
# Every hook writes the FS_* part of its environment to <event>.last and one
# line to <event>.count in $HK_OUT; the tests read those back.
hk_install() {
    local ev
    new_root HK_DIR
    new_root HK_OUT
    export HK_OUT FORK_SANDBOX_HOOKS_DIR="$HK_DIR" FORK_SANDBOX_POSTMASTER_HOOK_DETACH=inline
    for ev in "$@"; do
        cat > "$HK_DIR/$ev" <<'HOOK'
#!/usr/bin/env bash
env | grep '^FS_' | sort > "$HK_OUT/$FS_HOOK_EVENT.last"
echo x >> "$HK_OUT/$FS_HOOK_EVENT.count"
HOOK
        chmod +x "$HK_DIR/$ev"
    done
}
hk_uninstall() { unset FORK_SANDBOX_HOOKS_DIR FORK_SANDBOX_POSTMASTER_HOOK_DETACH HK_OUT; }
hk_count() { [[ -f "$HK_OUT/$1.count" ]] && wc -l < "$HK_OUT/$1.count" || echo 0; }
hk_env() { sed -n "s/^$2=//p" "$HK_OUT/$1.last" 2>/dev/null; }

# Direct calls: the script defines everything and runs nothing when sourced.
hk_call() {
    (
        # shellcheck disable=SC2030  # deliberately subshell-local
        export FORK_SANDBOX_HOOKS_DIR="$HK_DIR"
        # shellcheck disable=SC1090
        source "$postmaster"
        # shellcheck disable=SC2034  # read by the sourced functions
        PM_EVENTS_ENABLED=1
        # shellcheck disable=SC2034  # read by the sourced functions
        PM_PROJECT="$PROJECT_DIR"
        "$@"
    )
}

# ---- review-target and upstream-head seeds shared by the k8s files ----
# The review target: a real commit in PROJECT_DIR (commit-tree + update-ref,
# so it lands without disturbing PROJECT_DIR's own current branch/HEAD).
k8s_rt1_seed() {
    rt1_branch="pm-review-target-test-1"
    rt1_tree="$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')"
    rt1_parent="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    rt1_sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
        commit-tree "$rt1_tree" -p "$rt1_parent" -m 'review target commit 1')"
    git -C "$PROJECT_DIR" update-ref "refs/heads/$rt1_branch" "$rt1_sha"
}

# uh_commit <branch>: a commit in PROJECT_DIR (commit-tree + update-ref, so
# PROJECT_DIR's own HEAD is undisturbed), on <branch>; prints its sha.
uh_commit() {
    local branch="$1" tree parent sha
    tree="$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')"
    parent="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    sha="$(git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
        commit-tree "$tree" -p "$parent" -m "upstream head commit $branch")"
    git -C "$PROJECT_DIR" update-ref "refs/heads/$branch" "$sha"
    printf '%s' "$sha"
}

# extra_refs: every --extra-ref value in the argv log, one per line;
# head_id <message-id>: the postmaster's name suffix for an announcement.
extra_refs() { awk '$0=="--extra-ref"{getline; print}' "$STUB_ARGV_LOG"; }
head_id() { local id="$1"; id="${id//-/}"; printf '%s' "${id:0:12}"; }

# The announcer is '@ci-demo', a name that is not in the fleet: only a
# non-fleet sender's header is acted on.
# uh_kickoff <to>: opens a review thread (target = the rt1 commit) addressed
# to <to>, lets that seat's first wake run and its reply route, and sets
# UH_MID to the thread's root message id. The argv log is emptied afterward.
# Not called in a $( ) -- it re-roots the mail store in the CALLER's shell.
uh_kickoff() {
    local to="$1"
    local -a budget_args=()
    [[ -z "${UH_BUDGET:-}" ]] || budget_args=(--budget "$UH_BUDGET")
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    printf '%s\n' 'please revise' > "$work/body.tmp"
    # shellcheck disable=SC2034  # used by the test files
    UH_MID="$("$MAIL" send --from '@carol' --to "@$to" --subject 'upstream head topic' \
        --body "$work/body.tmp" --hops 8 --review-target "$rt1_branch:$rt1_sha" "${budget_args[@]}" 2>/dev/null)"
    once
    once
    : > "$STUB_ARGV_LOG"
}

# The upstream head every upstream-head case announces.
k8s_uh_seed() {
    uh_branch="feature/x"
    # shellcheck disable=SC2034  # used by the test files
    uh_sha="$(uh_commit "$uh_branch")"
}

# An origin for PROJECT_DIR: a bare repo fed from a source repo, with
# feature/pushed on it, and uh_origin_sha naming that commit.
k8s_origin_mirror_seed() {
    new_root UH_ORIGIN_BARE
    git init -q --bare "$UH_ORIGIN_BARE"
    new_root UH_ORIGIN_SRC
    git -C "$UH_ORIGIN_SRC" init -q
    git -C "$UH_ORIGIN_SRC" -c user.email=test@example.com -c user.name=test \
        commit -q --allow-empty -m 'origin upstream commit'
    # shellcheck disable=SC2034  # used by the test files
    uh_origin_sha="$(git -C "$UH_ORIGIN_SRC" rev-parse HEAD)"
    git -C "$UH_ORIGIN_SRC" push -q "$UH_ORIGIN_BARE" "HEAD:refs/heads/feature/pushed"
    git -C "$PROJECT_DIR" remote add origin "$UH_ORIGIN_BARE"
}

# The last line of every test file: its summary, which the runner parses.
finish_suite() {
    printf '\n%s passed, %s failed\n' "$pass" "$fail"
    (( fail == 0 )) || exit 1
}
