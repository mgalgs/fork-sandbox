#!/usr/bin/env bash
# fork-sandbox-k8s-wake-test.sh -- Exercise fork-sandbox-k8s-wake.sh's
# foreground run (pid/launch.log/k8s-run-dir/exit-code/summary.json
# normalization) and its --detach entry point, against a stub launcher
# and a stub fork-sandbox-k8s.sh, never a real cluster.
#
# Usage: tests/fork-sandbox-k8s-wake-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
wrapper_src="$repo_dir/scripts/fork-sandbox-k8s-wake.sh"

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

new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

# NUL-delimited argv/env file writer -- one record per argument.
write_nul() {
    local file="$1"; shift
    : > "$file"
    local a
    for a in "$@"; do
        printf '%s\0' "$a" >> "$file"
    done
}

# Every test gets its own root with:
#   $root/bin/fork-sandbox-k8s-wake.sh   a COPY of the real wrapper, so its
#                                         own script_dir resolves to $root/bin
#   $root/bin/launcher.sh                the stub standing in for
#                                         `fork-sandbox.sh --k8s`
#   $root/bin/fork-sandbox-k8s.sh        the stub `rm --branch` target
#   $root/wake                           the wake dir under test
setup_root() {
    local -n root_ref="$1"
    new_root root_ref
    mkdir -p -- "$root_ref/bin" "$root_ref/wake"
    cp -- "$wrapper_src" "$root_ref/bin/fork-sandbox-k8s-wake.sh"
    chmod +x -- "$root_ref/bin/fork-sandbox-k8s-wake.sh"

    cat > "$root_ref/bin/launcher.sh" <<'STUB'
#!/usr/bin/env bash
# Stands in for `fork-sandbox.sh --k8s`: prints the run-dir line the real
# launcher prints (unless STUB_K8S_NO_RUN_DIR is set), writes a
# summary.json into it (unless STUB_K8S_NO_SUMMARY is set), writes a
# mail-*.md into whatever --outbox-dir it was given, and exits
# STUB_K8S_LAUNCH_RC (default 0).
set -uo pipefail
rc="${STUB_K8S_LAUNCH_RC:-0}"
run_dir="${STUB_K8S_RUN_DIR:-}"
if [[ -n "$run_dir" && -z "${STUB_K8S_NO_RUN_DIR:-}" ]]; then
    mkdir -p -- "$run_dir"
    printf '  run dir:  %s\n' "$run_dir" >&2
    if [[ -z "${STUB_K8S_NO_SUMMARY:-}" ]]; then
        printf '{"exit_code": %s}' "${STUB_K8S_SUMMARY_EXIT_CODE:-$rc}" > "$run_dir/summary.json"
    fi
fi
if [[ -n "${STUB_K8S_TIMEOUT_MSG:-}" ]]; then
    printf 'Error: timed out after 60s waiting for branch\n' >&2
fi
outbox=""
while (( $# )); do
    case "$1" in
        --outbox-dir) outbox="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -n "$outbox" ]]; then
    mkdir -p -- "$outbox"
    printf 'To: @operator\n\nstub reply\n' > "$outbox/mail-1.md"
fi
if [[ -n "${STUB_ENV_DUMP:-}" ]]; then
    env > "$STUB_ENV_DUMP"
fi
exit "$rc"
STUB
    chmod +x -- "$root_ref/bin/launcher.sh"

    cat > "$root_ref/bin/fork-sandbox-k8s.sh" <<STUB
#!/usr/bin/env bash
# Stands in for the real fork-sandbox-k8s.sh's \`rm --branch\` and
# \`resume --run-dir DIR\` verbs. resume logs its argv, prints a line (and
# a wait-timeout message when STUB_K8S_TIMEOUT_MSG is set), writes a
# summary.json into DIR unless STUB_K8S_NO_SUMMARY is set, and exits
# STUB_K8S_RESUME_RC (default 0); it dumps its env to STUB_ENV_DUMP when set.
set -uo pipefail
if [[ "\${1:-}" == resume ]]; then
    printf '%s\n' "\$*" >> "$root_ref/resume-calls.log"
    echo "stub resume output"
    [[ -z "\${STUB_ENV_DUMP:-}" ]] || env > "\$STUB_ENV_DUMP"
    if [[ -n "\${STUB_K8S_TIMEOUT_MSG:-}" ]]; then
        printf 'Error: timed out after 60s waiting for branch\n' >&2
    fi
    if [[ -z "\${STUB_K8S_NO_SUMMARY:-}" ]]; then
        printf '{"exit_code": %s}' "\${STUB_K8S_SUMMARY_EXIT_CODE:-\${STUB_K8S_RESUME_RC:-0}}" > "\$3/summary.json"
    fi
    exit "\${STUB_K8S_RESUME_RC:-0}"
fi
printf '%s\n' "\$*" >> "$root_ref/rm-calls.log"
exit "\${STUB_K8S_RM_RC:-0}"
STUB
    chmod +x -- "$root_ref/bin/fork-sandbox-k8s.sh"
}

# ---- case: rc 0, a real reply ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-1" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    run_dir="$root/k8srun"
    ( STUB_K8S_RUN_DIR="$run_dir" STUB_K8S_LAUNCH_RC=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "rc 0: wrapper itself exits 0" 0 "$rc"
    check "rc 0: exit-code file is 0" 0 "$(cat -- "$root/wake/exit-code")"
    if [[ -s "$root/wake/pid" ]]; then ok "rc 0: pid file present"; else no "rc 0: pid file present"; fi
    check "rc 0: k8s-run-dir scraped" "$run_dir" "$(cat -- "$root/wake/k8s-run-dir")"
    check "rc 0: summary.json copied through" \
        '{"exit_code": 0}' "$(cat -- "$root/wake/summary.json")"
}

# ---- case: rc 3, zero-harvest -- normalized to 0, kept Job reaped ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-3" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    run_dir="$root/k8srun"
    ( STUB_K8S_RUN_DIR="$run_dir" STUB_K8S_LAUNCH_RC=3 STUB_K8S_SUMMARY_EXIT_CODE=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "rc 3: wrapper exits 0 (normalized)" 0 "$rc"
    check "rc 3: exit-code file is 0" 0 "$(cat -- "$root/wake/exit-code")"
    check "rc 3: summary exit_code stays 0" \
        '{"exit_code": 0}' "$(cat -- "$root/wake/summary.json")"
    if [[ -f "$root/rm-calls.log" ]]; then
        contains "rc 3: stub rm --branch was called" \
            "$(cat -- "$root/rm-calls.log")" "--branch test-branch-3"
    else
        no "rc 3: stub rm --branch was called" "rm-calls.log never written"
    fi
}

# ---- case: rc 2 (dead pod), no k8s summary ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-2" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    run_dir="$root/k8srun"
    ( STUB_K8S_RUN_DIR="$run_dir" STUB_K8S_LAUNCH_RC=2 STUB_K8S_NO_SUMMARY=1 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "rc 2: wrapper propagates rc 2" 2 "$rc"
    check "rc 2: exit-code file is 2" 2 "$(cat -- "$root/wake/exit-code")"
    check "rc 2: summary.json synthesized" \
        '{"exit_code": 2}' "$(cat -- "$root/wake/summary.json")"
    if [[ -f "$root/rm-calls.log" ]]; then
        no "rc 2: rm not called" "rm-calls.log unexpectedly written"
    else
        ok "rc 2: rm not called"
    fi
}

# ---- case: launcher refuses before submit -- no run dir line at all ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-refuse" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    ( STUB_K8S_LAUNCH_RC=1 STUB_K8S_NO_RUN_DIR=1 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "refusal: wrapper propagates rc 1" 1 "$rc"
    check "refusal: k8s-run-dir is empty" "" "$(cat -- "$root/wake/k8s-run-dir")"
    check "refusal: summary.json synthesized" \
        '{"exit_code": 1}' "$(cat -- "$root/wake/summary.json")"
    check "refusal: k8s-timeout is 0" 0 "$(cat -- "$root/wake/k8s-timeout")"
}

# ---- case: rc 1 from run's wait timeout -- k8s-timeout is 1 ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-timeout" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    ( STUB_K8S_RUN_DIR="$root/k8srun" STUB_K8S_LAUNCH_RC=1 STUB_K8S_NO_SUMMARY=1 \
        STUB_K8S_TIMEOUT_MSG=1 "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "timeout: wrapper propagates rc 1" 1 "$rc"
    check "timeout: k8s-timeout is 1" 1 "$(cat -- "$root/wake/k8s-timeout")"
}

# ---- case: rc 1 from the agent's own exit 1 -- not a timeout ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-agent1" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    ( STUB_K8S_RUN_DIR="$root/k8srun" STUB_K8S_LAUNCH_RC=1 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" )
    rc=$?
    check "agent exit 1: wrapper propagates rc 1" 1 "$rc"
    check "agent exit 1: k8s-timeout is 0" 0 "$(cat -- "$root/wake/k8s-timeout")"
}

# ---- case: a bad-KEY env record is ignored, a good one is exported ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-env" \
        --outbox-dir "$root/wake/outbox"
    write_nul "$root/wake/env" "BAD-KEY=nope" "GOOD_VAR=hello"
    dump="$root/env-dump.txt"
    ( STUB_ENV_DUMP="$dump" STUB_K8S_LAUNCH_RC=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" ) >/dev/null
    if [[ -f "$dump" ]]; then
        contains "env: good record exported" "$(cat -- "$dump")" "GOOD_VAR=hello"
        case "$(cat -- "$dump")" in
            *"BAD-KEY"*) no "env: bad-KEY record ignored" "BAD-KEY leaked into launcher env" ;;
            *) ok "env: bad-KEY record ignored" ;;
        esac
    else
        no "env: dump written" "$dump missing"
    fi
}

# ---- case: an inherited stale FORK_SANDBOX_* var is scrubbed, not leaked ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-stale" \
        --outbox-dir "$root/wake/outbox"
    write_nul "$root/wake/env" "GOOD_VAR=hello"
    dump="$root/env-dump-stale.txt"
    ( export FORK_SANDBOX_STALE=old-value
      STUB_ENV_DUMP="$dump" STUB_K8S_LAUNCH_RC=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" ) >/dev/null
    if [[ -f "$dump" ]]; then
        contains "stale env: good record still exported" "$(cat -- "$dump")" "GOOD_VAR=hello"
        case "$(cat -- "$dump")" in
            *"FORK_SANDBOX_STALE"*) no "stale env: inherited FORK_SANDBOX_* scrubbed" \
                "FORK_SANDBOX_STALE leaked into launcher env" ;;
            *) ok "stale env: inherited FORK_SANDBOX_* scrubbed" ;;
        esac
    else
        no "stale env: dump written" "$dump missing"
    fi
}

# ---- case: exit-code is written strictly before summary.json ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-order" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    ( STUB_K8S_LAUNCH_RC=0 "$root/bin/fork-sandbox-k8s-wake.sh" "$root/wake" ) >/dev/null
    if [[ "$root/wake/exit-code" -ot "$root/wake/summary.json" ]]; then
        ok "order: exit-code precedes summary.json"
    else
        no "order: exit-code precedes summary.json" "exit-code is not older than summary.json"
    fi
}

# ---- case: --help prints usage and exits 0 ----
{
    root=""
    setup_root root
    out="$("$root/bin/fork-sandbox-k8s-wake.sh" --help)"
    rc=$?
    check "--help exits 0" 0 "$rc"
    contains "--help mentions Usage" "$out" "Usage:"
}

# ---- case: --detach starts a tmux session named cc-k8s-<branch> ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "weird/branch name!" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"

    tmux_log="$root/tmux-argv.log"
    cat > "$root/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmux_log"
# Run the command tmux was given (the last arg) so the rest of the test
# can observe the wrapper's own side effects too.
last="\${!#}"
exec "\$last"
STUB
    chmod +x -- "$root/bin/tmux"

    ( PATH="$root/bin:$PATH" STUB_K8S_LAUNCH_RC=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" --detach "$root/wake" )
    rc=$?
    check "--detach: wrapper returns 0" 0 "$rc"
    if [[ -f "$tmux_log" ]]; then
        contains "--detach: session named cc-k8s-<sanitized branch>" \
            "$(cat -- "$tmux_log")" "cc-k8s-weird-branch-name-"
        contains "--detach: run.sh passed as the one command" \
            "$(cat -- "$tmux_log")" "$root/wake/run.sh"
    else
        no "--detach: tmux was invoked" "tmux-argv.log missing"
    fi
    check "--detach: exit-code eventually written" 0 "$(cat -- "$root/wake/exit-code" 2>/dev/null || echo MISSING)"
}

# ---- case: --detach exits 1 when tmux cannot start a session ----
{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "test-branch-notmux" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    cat > "$root/bin/tmux" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x -- "$root/bin/tmux"
    ( PATH="$root/bin:$PATH" "$root/bin/fork-sandbox-k8s-wake.sh" --detach "$root/wake" ) >/dev/null 2>&1
    rc=$?
    check "--detach: propagates tmux failure as rc 1" 1 "$rc"
}

# ---- adopt: a wake dir whose wrapper died; resume replaces submit ----
# adopt_setup <label-branch>: a wake dir with a launch.log from the dead
# wrapper (submit's run-dir line plus an earlier timeout message that must
# NOT be mistaken for this attempt's), and the adopt-count the caller wrote.
adopt_setup() {
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "$1" --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    run_dir="$root/k8srun"
    mkdir -p -- "$run_dir"
    printf 'original launch output\n  run dir:  %s\nError: timed out after 9s waiting for branch\n' \
        "$run_dir" > "$root/wake/launch.log"
    printf '2' > "$root/wake/adopt-count"
}
adopt_run() { ( "$@" "$root/bin/fork-sandbox-k8s-wake.sh" --adopt "$root/wake" ) >/dev/null 2>&1; }

adopt_setup adopt-branch-0
adopt_run env STUB_K8S_RESUME_RC=0
rc=$?
check "adopt rc 0: wrapper exits 0" 0 "$rc"
check "adopt rc 0: exit-code is 0" 0 "$(cat -- "$root/wake/exit-code")"
check "adopt rc 0: summary.json copied through" '{"exit_code": 0}' "$(cat -- "$root/wake/summary.json")"
check "adopt rc 0: k8s-run-dir recorded" "$run_dir" "$(cat -- "$root/wake/k8s-run-dir")"
check "adopt rc 0: k8s-timeout is 0 (the earlier attempt's timeout message is not this one's)" \
    0 "$(cat -- "$root/wake/k8s-timeout")"
check "adopt rc 0: resume called with the run dir, no submit" \
    "resume --run-dir $run_dir" "$(cat -- "$root/resume-calls.log")"
if [[ -s "$root/wake/pid" && -s "$root/wake/pid-identity" ]]; then
    ok "adopt: pid and pid-identity written"
else
    no "adopt: pid and pid-identity written"
fi
check "adopt: adopt-count is left to the caller" 2 "$(cat -- "$root/wake/adopt-count")"
log="$(cat -- "$root/wake/launch.log")"
contains "adopt: launch.log keeps the original output (appended, not replaced)" "$log" "original launch output"
contains "adopt: launch.log carries the adopting banner with the attempt" \
    "$log" "--- fork-sandbox-k8s-wake: adopting adopt-branch-0 (attempt 2) ---"
contains "adopt: launch.log carries resume's output" "$log" "stub resume output"
if [[ "$root/wake/exit-code" -ot "$root/wake/summary.json" ]]; then
    ok "adopt: exit-code precedes summary.json"
else
    no "adopt: exit-code precedes summary.json"
fi

adopt_setup adopt-branch-3
adopt_run env STUB_K8S_RESUME_RC=3 STUB_K8S_SUMMARY_EXIT_CODE=0
rc=$?
check "adopt rc 3: wrapper exits 0 (normalized)" 0 "$rc"
check "adopt rc 3: exit-code file is 0" 0 "$(cat -- "$root/wake/exit-code")"
if [[ -f "$root/rm-calls.log" ]]; then
    contains "adopt rc 3: the kept Job is reaped" "$(cat -- "$root/rm-calls.log")" "--branch adopt-branch-3"
else
    no "adopt rc 3: the kept Job is reaped" "rm-calls.log never written"
fi

adopt_setup adopt-branch-2
adopt_run env STUB_K8S_RESUME_RC=2 STUB_K8S_NO_SUMMARY=1
rc=$?
check "adopt rc 2: wrapper propagates rc 2" 2 "$rc"
check "adopt rc 2: exit-code file is 2" 2 "$(cat -- "$root/wake/exit-code")"
check "adopt rc 2: summary.json synthesized" '{"exit_code": 2}' "$(cat -- "$root/wake/summary.json")"
check "adopt rc 2: rm not called" 0 "$( [[ -f "$root/rm-calls.log" ]] && echo 1 || echo 0 )"

adopt_setup adopt-branch-timeout
adopt_run env STUB_K8S_RESUME_RC=1 STUB_K8S_NO_SUMMARY=1 STUB_K8S_TIMEOUT_MSG=1
rc=$?
check "adopt timeout: wrapper propagates rc 1" 1 "$rc"
check "adopt timeout: k8s-timeout is 1 (resume's own wait-timeout message)" 1 "$(cat -- "$root/wake/k8s-timeout")"

adopt_setup adopt-branch-agent1
adopt_run env STUB_K8S_RESUME_RC=1
check "adopt agent exit 1: k8s-timeout is 0" 0 "$(cat -- "$root/wake/k8s-timeout")"

adopt_setup adopt-branch-file
rm -f -- "$root/wake/launch.log"
printf '%s' "$run_dir" > "$root/wake/k8s-run-dir"
adopt_run env STUB_K8S_RESUME_RC=0
rc=$?
check "adopt: the k8s-run-dir file alone is enough (no launch.log)" 0 "$rc"
check "adopt: resume used the k8s-run-dir file's directory" \
    "resume --run-dir $run_dir" "$(cat -- "$root/resume-calls.log")"

adopt_setup adopt-branch-nodir
printf 'no run dir line here\n' > "$root/wake/launch.log"
adopt_run env STUB_K8S_RESUME_RC=0
rc=$?
check "adopt without a run dir: wrapper exits 1" 1 "$rc"
check "adopt without a run dir: exit-code is 1" 1 "$(cat -- "$root/wake/exit-code")"
check "adopt without a run dir: summary.json synthesized" '{"exit_code": 1}' "$(cat -- "$root/wake/summary.json")"
check "adopt without a run dir: resume never called" 0 "$( [[ -f "$root/resume-calls.log" ]] && echo 1 || echo 0 )"
contains "adopt without a run dir: the failure is logged (log appended)" \
    "$(cat -- "$root/wake/launch.log")" "no k8s run directory recorded"

adopt_setup adopt-branch-gone
rm -rf -- "$run_dir"
adopt_run env STUB_K8S_RESUME_RC=0
check "adopt with a run dir that no longer exists: exit-code is 1" 1 "$(cat -- "$root/wake/exit-code")"

adopt_setup adopt-branch-env
write_nul "$root/wake/env" "GOOD_VAR=hello"
adopt_dump="$root/env-dump-adopt.txt"
FORK_SANDBOX_STALE=old-value STUB_ENV_DUMP="$adopt_dump" \
    "$root/bin/fork-sandbox-k8s-wake.sh" --adopt "$root/wake" >/dev/null 2>&1
check "adopt: exits 0" 0 "$(cat -- "$root/wake/exit-code")"
contains "adopt: resume runs with the env records applied" "$(cat -- "$adopt_dump" 2>/dev/null)" "GOOD_VAR=hello"
case "$(cat -- "$adopt_dump" 2>/dev/null)" in
    *FORK_SANDBOX_STALE*) no "adopt: inherited FORK_SANDBOX_* scrubbed" "FORK_SANDBOX_STALE leaked into resume's env" ;;
    *) ok "adopt: inherited FORK_SANDBOX_* scrubbed" ;;
esac

# ---- adopt --detach: same tmux session name, run.sh execs --adopt ----
adopt_setup adopt-branch-detach
tmux_log="$root/tmux-argv.log"
cat > "$root/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmux_log"
last="\${!#}"
exec "\$last"
STUB
chmod +x -- "$root/bin/tmux"
( PATH="$root/bin:$PATH" "$root/bin/fork-sandbox-k8s-wake.sh" --adopt --detach "$root/wake" )
rc=$?
check "adopt --detach: wrapper returns 0" 0 "$rc"
contains "adopt --detach: same cc-k8s-<branch> session name" "$(cat -- "$tmux_log")" "cc-k8s-adopt-branch-detach"
contains "adopt --detach: run.sh execs --adopt" "$(cat -- "$root/wake/run.sh")" "--adopt $root/wake"
check "adopt --detach: the adopted wake ran to completion" 0 "$(cat -- "$root/wake/exit-code" 2>/dev/null || echo MISSING)"

# ---- --detach-mode setsid: no tmux, the same run.sh under setsid ----
setsid_stubs() {
    # $1 = root; a setsid stub that logs its argv and runs the command, and
    # a tmux stub that records any call (there must be none).
    cat > "$1/bin/setsid" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/setsid-argv.log"
last="\${!#}"
exec "\$last"
STUB
    cat > "$1/bin/tmux" <<STUB
#!/usr/bin/env bash
printf 'called\n' >> "$1/tmux-called.log"
exit 1
STUB
    chmod +x -- "$1/bin/setsid" "$1/bin/tmux"
}

{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" \
        "$root/bin/launcher.sh" --branch "setsid-branch" \
        --outbox-dir "$root/wake/outbox"
    : > "$root/wake/env"
    setsid_stubs "$root"
    ( PATH="$root/bin:$PATH" STUB_K8S_LAUNCH_RC=0 \
        "$root/bin/fork-sandbox-k8s-wake.sh" --detach --detach-mode setsid "$root/wake" )
    rc=$?
    check "--detach-mode setsid: wrapper returns 0" 0 "$rc"
    contains "--detach-mode setsid: run.sh is the command setsid was given" \
        "$(cat -- "$root/setsid-argv.log" 2>/dev/null)" "$root/wake/run.sh"
    check "--detach-mode setsid: tmux is never called" 0 \
        "$( [[ -e "$root/tmux-called.log" ]] && echo 1 || echo 0 )"
    check "--detach-mode setsid: the wake ran to completion" 0 \
        "$(cat -- "$root/wake/exit-code" 2>/dev/null || echo MISSING)"
    check "--detach-mode setsid: wake.out exists (stdout/stderr target)" 1 \
        "$( [[ -e "$root/wake/wake.out" ]] && echo 1 || echo 0 )"
    check "--detach-mode setsid: the wake recorded its own pid" 1 \
        "$( [[ -s "$root/wake/pid" ]] && echo 1 || echo 0 )"
}

adopt_setup adopt-setsid-branch
setsid_stubs "$root"
( PATH="$root/bin:$PATH" "$root/bin/fork-sandbox-k8s-wake.sh" --adopt --detach --detach-mode setsid "$root/wake" )
rc=$?
check "adopt --detach-mode setsid: wrapper returns 0" 0 "$rc"
contains "adopt --detach-mode setsid: run.sh execs --adopt" "$(cat -- "$root/wake/run.sh")" "--adopt $root/wake"
check "adopt --detach-mode setsid: tmux is never called" 0 \
    "$( [[ -e "$root/tmux-called.log" ]] && echo 1 || echo 0 )"
check "adopt --detach-mode setsid: the adopted wake ran to completion" 0 \
    "$(cat -- "$root/wake/exit-code" 2>/dev/null || echo MISSING)"

{
    root=""
    setup_root root
    write_nul "$root/wake/fs-argv" "$root/bin/launcher.sh" --branch "setsid-fail"
    : > "$root/wake/env"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/setsid"
    chmod +x -- "$root/bin/setsid"
    ( PATH="$root/bin:$PATH" "$root/bin/fork-sandbox-k8s-wake.sh" --detach --detach-mode setsid "$root/wake" ) >/dev/null 2>&1
    rc=$?
    check "--detach-mode setsid: propagates a setsid failure as rc 1" 1 "$rc"
    ( PATH="$root/bin:$PATH" "$root/bin/fork-sandbox-k8s-wake.sh" --detach --detach-mode bogus "$root/wake" ) >/dev/null 2>&1
    rc=$?
    check "--detach-mode: an unknown mode is refused" 1 "$rc"
}

printf '\n%s ok, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
