#!/usr/bin/env bash
# fork-sandbox-wait-test.sh — Exercise `fork-sandbox run --wait` and
# `--wait-timeout`: the exit-code remapping (clean, non-zero, abandoned),
# the timeout wrap, and the three refusals.
#
# Usage: tests/fork-sandbox-wait-test.sh
#
# Modeled on fork-sandbox-stop-test.sh's fixture shape: a stub
# claude-sandboxed bypasses bwrap entirely, so real detached
# fork-sandbox.sh runs complete in well under a second, under a scratch
# HOME so no fixture ever touches the operator's own ~/.claude state.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work -- see
# fork-sandbox-refresh-test.sh's own header for why this matters to
# sandbox-run-log.py's default stats.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()
# Real fork-sandbox.sh fixtures below run under this scratch HOME, not the
# operator's -- sandbox-run-log.py's archive dir and run log are
# hardcoded under ~/.claude, so a fixture run under the real HOME appends
# handoff archives indistinguishable from an operator's real work. A
# scratch HOME also empties the launcher's ${FORK_SANDBOX_CONFIG_DIR:-
# $HOME/.config/fork-sandbox}, so machine config cannot route or refuse a
# fixture run. The guard near the end of this file holds the archive half
# of this.
launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
# The launcher's own security boundary requires the project to live under
# ~/src, resolved against the scratch HOME above -- fixture projects must
# live there too. sandbox-run-log.py's record() opens
# ~/.claude/sandbox-runs.jsonl in append mode without creating the parent
# itself, so pre-create it rather than relying on a prior real run having
# already done so.
mkdir -p "$launcher_home/src" "$launcher_home/.claude"
operator_archive_dir="$HOME/.claude/sandbox-handoffs"

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

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

new_project() {
    local d
    d="$(mktemp -d "$launcher_home/src/fs-wait-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# =====================================================================
printf '== fixtures ==\n'
# =====================================================================

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-wait-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely. Sleeps for
# FAKE_SLEEP_SECONDS (default 0), then either exits FAKE_EXIT_CODE
# directly (skipping the JSON result line, mirroring a harness that died
# before reporting) or reports a normal success result and exits 0.
# Verified manually this leg: a plain non-zero FAKE_EXIT_CODE propagates
# straight through the runner's single-leg PIPESTATUS read into the
# exit-code file unchanged.
set -uo pipefail
cat >/dev/null
sleep "${FAKE_SLEEP_SECONDS:-0}"
if [[ "${FAKE_EXIT_CODE:-0}" != 0 ]]; then
    exit "${FAKE_EXIT_CODE}"
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-wait-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

# Run dirs produced by a real launch this suite must account for in the
# archive guard at the very end.
owned_run_dirs=()

# Launches a real detached fixture run in the background under
# FAKE_SLEEP_SECONDS=10 (long enough to kill mid-run, short enough not to
# slow the suite down), setting wait_bg_out (captured-output file) and
# wait_bg_pid (the launcher's own pid) as globals. Extra launcher flags
# (e.g. --wait) come first, then rely on $proj/$handoff already set.
#
# Deliberately NOT `out="$(launch_wait_bg ...)"`: command substitution
# runs the whole function body in a subshell, so the `&` background job
# it starts would belong to that subshell's job table, not this script's
# -- $! read back here would never see it. Globals avoid that trap.
launch_wait_bg() {
    wait_bg_out="$(mktemp)"; tmpdirs+=("$wait_bg_out")
    HOME="$launcher_home" PATH="$stub_bin:$PATH" FAKE_SLEEP_SECONDS=10 \
        "$launcher" "$@" "$proj" "$handoff" > "$wait_bg_out" 2>&1 &
    wait_bg_pid=$!
}

run_dir_from_output() {
    sed -n 's/^  run dir:  *//p' "$1" 2>/dev/null | head -1
}

wait_for_run_dir() {
    local out_file="$1" rd=""
    local _n
    for _n in $(seq 1 100); do
        rd="$(run_dir_from_output "$out_file")"
        [[ -n "$rd" ]] && break
        sleep 0.1
    done
    printf '%s' "$rd"
}

wait_for_file() {
    local f="$1" _n
    for _n in $(seq 1 100); do
        [[ -e "$f" ]] && return 0
        sleep 0.1
    done
    return 1
}

# =====================================================================
printf '\n== clean stub run: run --wait exits 0, branch fetched ==\n'
# =====================================================================

out_clean="$(mktemp)"; tmpdirs+=("$out_clean")
HOME="$launcher_home" PATH="$stub_bin:$PATH" FAKE_SLEEP_SECONDS=0 FAKE_EXIT_CODE=0 \
    timeout 60 "$launcher" --harness claude --wait "$proj" "$handoff" \
    > "$out_clean" 2>&1
rc_clean=$?
rd_clean="$(run_dir_from_output "$out_clean")"
if [[ -n "$rd_clean" ]]; then
    tmpdirs+=("$rd_clean")
    owned_run_dirs+=("$rd_clean")
    check "clean run: --wait exits 0" "0" "$rc_clean"
    check "clean run: branch fetched" \
        "true" "$(jq -r '.fetched // empty' "$rd_clean/summary.json" 2>/dev/null)"
    branch_clean="$(sed -n 's/^branch=//p' "$rd_clean/run.env" 2>/dev/null | head -1)"
    [[ -n "$branch_clean" ]] && (cd "$proj" && git branch -q -D "$branch_clean" >/dev/null 2>&1) || true
else
    no "clean run: --wait exits 0" "no run dir ever appeared: $(cat "$out_clean")"
    no "clean run: branch fetched" "no run dir"
fi

# =====================================================================
printf '\n== stub harness exiting 3: --wait exits 3 ==\n'
# =====================================================================

out_exit3="$(mktemp)"; tmpdirs+=("$out_exit3")
HOME="$launcher_home" PATH="$stub_bin:$PATH" FAKE_SLEEP_SECONDS=0 FAKE_EXIT_CODE=3 \
    timeout 60 "$launcher" --harness claude --wait "$proj" "$handoff" \
    > "$out_exit3" 2>&1
rc_exit3=$?
rd_exit3="$(run_dir_from_output "$out_exit3")"
if [[ -n "$rd_exit3" ]]; then
    tmpdirs+=("$rd_exit3")
    owned_run_dirs+=("$rd_exit3")
    check "exit-3 run: --wait exits 3" "3" "$rc_exit3"
    branch_exit3="$(sed -n 's/^branch=//p' "$rd_exit3/run.env" 2>/dev/null | head -1)"
    [[ -n "$branch_exit3" ]] && (cd "$proj" && git branch -q -D "$branch_exit3" >/dev/null 2>&1) || true
else
    no "exit-3 run: --wait exits 3" "no run dir ever appeared: $(cat "$out_exit3")"
fi

# =====================================================================
printf '\n== abandoned: kill the runner mid-run, --wait exits 125 ==\n'
# =====================================================================

launch_wait_bg --harness claude --wait
out_abandoned="$wait_bg_out"
wait_pid="$wait_bg_pid"
rd_abandoned="$(wait_for_run_dir "$out_abandoned")"
if [[ -n "$rd_abandoned" ]]; then
    tmpdirs+=("$rd_abandoned")
    owned_run_dirs+=("$rd_abandoned")
    if wait_for_file "$rd_abandoned/pid"; then
        # A hard kill, not TERM: TERM would tear down cleanly through the
        # runner's own trap and land in done/failed, not abandoned. -9
        # never reaches that trap and never writes exit-code, which is
        # exactly what distinguishes "abandoned" from "stopped".
        kill -9 "$(cat "$rd_abandoned/pid")" 2>/dev/null || true
        wait "$wait_pid" 2>/dev/null
        rc_abandoned=$?
        check "abandoned: --wait exits 125" "125" "$rc_abandoned"
        contains "abandoned: names abandoned in its output" "abandoned" "$(cat "$out_abandoned")"
        branch_abandoned="$(sed -n 's/^branch=//p' "$rd_abandoned/run.env" 2>/dev/null | head -1)"
        [[ -n "$branch_abandoned" ]] && (cd "$proj" && git branch -q -D "$branch_abandoned" >/dev/null 2>&1) || true
    else
        no "abandoned: --wait exits 125" "runner never wrote a pid file"
        no "abandoned: names abandoned in its output" "runner never wrote a pid file"
        kill "$wait_pid" 2>/dev/null || true
        wait "$wait_pid" 2>/dev/null || true
    fi
else
    no "abandoned: --wait exits 125" "no run dir ever appeared: $(cat "$out_abandoned")"
    no "abandoned: names abandoned in its output" "no run dir ever appeared"
    kill "$wait_pid" 2>/dev/null || true
    wait "$wait_pid" 2>/dev/null || true
fi

# =====================================================================
printf '\n== timeout: --wait-timeout 2 exits 124, run still live ==\n'
# =====================================================================

out_timeout="$(mktemp)"; tmpdirs+=("$out_timeout")
HOME="$launcher_home" PATH="$stub_bin:$PATH" FAKE_SLEEP_SECONDS=999 \
    timeout 30 "$launcher" --harness claude --wait --wait-timeout 2 \
    "$proj" "$handoff" > "$out_timeout" 2>&1
rc_timeout=$?
rd_timeout="$(run_dir_from_output "$out_timeout")"
if [[ -n "$rd_timeout" ]]; then
    tmpdirs+=("$rd_timeout")
    owned_run_dirs+=("$rd_timeout")
    check "timeout: --wait-timeout exits 124" "124" "$rc_timeout"
    check "timeout: run dir shows no exit-code yet (still running)" \
        "0" "$([[ -e "$rd_timeout/exit-code" ]] && echo 1 || echo 0)"
    # The run is genuinely still alive (a real tmux session, a real
    # runner sleeping 999s) -- tear it down with the real stop verb
    # before this suite's own tmpdirs cleanup removes the run dir out
    # from under a still-running process.
    HOME="$launcher_home" "$repo_dir/scripts/fork-sandbox-stop.sh" "$rd_timeout" >/dev/null 2>&1 || true
    branch_timeout="$(sed -n 's/^branch=//p' "$rd_timeout/run.env" 2>/dev/null | head -1)"
    [[ -n "$branch_timeout" ]] && (cd "$proj" && git branch -q -D "$branch_timeout" >/dev/null 2>&1) || true
else
    no "timeout: --wait-timeout exits 124" "no run dir ever appeared: $(cat "$out_timeout")"
    no "timeout: run dir shows no exit-code yet (still running)" "no run dir"
fi

# =====================================================================
printf '\n== refusals (no real launch needed) ==\n'
# =====================================================================

out_k8s="$(HOME="$launcher_home" "$launcher" --wait --k8s "$proj" "$handoff" 2>&1)"; rc_k8s=$?
check "--wait with --k8s: exits 1" "1" "$rc_k8s"
contains "--wait with --k8s: names the refusal" "not supported with --k8s" "$out_k8s"

out_fg="$(HOME="$launcher_home" "$launcher" --wait --foreground "$proj" "$handoff" 2>&1)"; rc_fg=$?
check "--wait with --foreground: exits 1" "1" "$rc_fg"
contains "--wait with --foreground: names the refusal" "redundant with --foreground" "$out_fg"

out_timeout_alone="$(HOME="$launcher_home" "$launcher" --wait-timeout 5 "$proj" "$handoff" 2>&1)"; rc_timeout_alone=$?
check "--wait-timeout without --wait: exits 1" "1" "$rc_timeout_alone"
contains "--wait-timeout without --wait: names the refusal" "requires --wait" "$out_timeout_alone"

out_timeout_zero="$(HOME="$launcher_home" "$launcher" --wait --wait-timeout 0 "$proj" "$handoff" 2>&1)"; rc_timeout_zero=$?
check "--wait-timeout 0: exits 1" "1" "$rc_timeout_zero"
contains "--wait-timeout 0: names positive integer" "positive integer" "$out_timeout_zero"

# A zero-padded all-zero string ("00") is digit-only, so the regex half
# of the check passes it; a naive string comparison against the literal
# "0" then misses it too, since "00" != "0" as strings. That let
# `timeout --foreground 00 ...` through, which expires immediately
# (exit 124 from timeout itself, not a real wait) instead of being
# refused at parse time.
out_timeout_zeropad="$(HOME="$launcher_home" "$launcher" --wait --wait-timeout 00 "$proj" "$handoff" 2>&1)"; rc_timeout_zeropad=$?
check "--wait-timeout 00: exits 1" "1" "$rc_timeout_zeropad"
contains "--wait-timeout 00: names positive integer" "positive integer" "$out_timeout_zeropad"

out_timeout_abc="$(HOME="$launcher_home" "$launcher" --wait --wait-timeout abc "$proj" "$handoff" 2>&1)"; rc_timeout_abc=$?
check "--wait-timeout abc: exits 1" "1" "$rc_timeout_abc"
contains "--wait-timeout abc: names positive integer" "positive integer" "$out_timeout_abc"

# =====================================================================
printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# =====================================================================
# Same guard as fork-sandbox-stop-test.sh's / fork-sandbox-k8s-test.sh's:
# archives carry no source marker, so a leaked fixture archive is
# indistinguishable from an operator's real work. Ownership, not a global
# snapshot diff -- a snapshot diff would fail this suite over an
# unrelated concurrent run's archive landing during this suite's window.
new_operator_archives=""
for owned_rd in "${owned_run_dirs[@]-}"; do
    [[ -z "$owned_rd" ]] && continue
    archive_path="$operator_archive_dir/$(basename "$owned_rd").md"
    [[ -e "$archive_path" ]] && new_operator_archives+="$archive_path "
done
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$new_operator_archives"

# Positive control: prove the scratch-HOME redirect actually redirects, not
# that archiving silently stopped. rd_clean is an ordinary --wait run that
# exits 0, and sandbox-run-log.py's record step runs unconditionally at the
# end of every run, so its archive is guaranteed to exist somewhere.
if [[ -n "${rd_clean:-}" ]]; then
    scratch_archive="$launcher_home/.claude/sandbox-handoffs/$(basename -- "$rd_clean").md"
    if [[ -f "$scratch_archive" ]]; then
        ok "a fixture run's handoff archive lands in the scratch HOME"
    else
        no "a fixture run's handoff archive lands in the scratch HOME" \
            "expected $scratch_archive"
    fi
else
    no "a fixture run's handoff archive lands in the scratch HOME" "rd_clean not set"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
