#!/usr/bin/env bash
# tests/shellcheck-memory-budget-test.sh — keep any one file's shellcheck
# run under a memory budget, so a lint pass can never OOM the host running it.
#
# Usage: tests/shellcheck-memory-budget-test.sh
#
# Background: shellcheck 0.11's extended (dataflow) analysis can use
# enormous memory on a large, flat, top-level shell file -- line count does
# not predict the peak, flat top-level code does. It once reached ~19.6 GB
# RSS on tests/fork-sandbox-k8s-test.sh and got OOM-killed, taking a whole
# unattended sandbox run down with it (systemd's default OOMPolicy=stop
# takes the rest of that unit down with the process it killed). That file
# and tests/fork-sandbox-postmaster-test.sh now carry a per-file
# "# shellcheck extended-analysis=false" directive for exactly this reason
# -- never remove those two lines. This suite is the guard that says
# whether some OTHER file needs the same treatment: it runs shellcheck on
# every tracked script under a hard memory cap, one file at a time (never
# in parallel -- the point is not to OOM the machine running this test),
# and fails on any file whose shellcheck run gets OOM-killed. A shellcheck
# LINT finding (its own exit status 1, or a parse error) is not this
# suite's business, only memory is.
#
# The real check needs `systemd-run --user` with a reachable --user
# manager, which most containers (and this project's own sandboxes) do not
# have; it SKIPs cleanly there rather than failing, and the same is true if
# the shellcheck binary itself is missing. The decision logic that tells an
# OOM-kill apart from a lint finding, and the SKIP paths themselves, are exercised
# below by self-tests that stub systemd-run (and, for the "missing
# entirely" cases, an injectable command name) rather than the real thing --
# so they stay covered even on a host, like this sandbox, where the real
# check cannot run at all.
#
# ulimit -v / prlimit --as are deliberately NOT used here even though they
# would be simpler: shellcheck is a Haskell binary whose runtime reserves
# huge virtual address space up front regardless of how much it actually
# touches, so an address-space limit fails it spuriously on every file, not
# just the ones that are actually a problem. A cgroup MemoryMax (RSS-based,
# via systemd-run) does not have that failure mode.
#
# SHELLCHECK_MEMORY_BUDGET overrides the default 3G cap, e.g. for local
# experiments narrowing down which file needs the directive.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
budget="${SHELLCHECK_MEMORY_BUDGET:-3G}"

# Injectable command names -- overridden by self-tests below to exercise
# "the binary does not exist at all", which PATH stubbing alone cannot do
# on a host that already has a real one earlier on PATH than any stub
# directory this suite could prepend.
systemd_run_bin="systemd-run"
shellcheck_bin="shellcheck"

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

contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$label"; else no "$label" "expected to find: $needle"; fi
}

lacks() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then ok "$label"; else no "$label" "did not expect to find: $needle"; fi
}

check_rc() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected rc=$expected, got rc=$actual"; fi
}

# --- The list of files -------------------------------------------------

# Every .sh file in the checkout, plus the extensionless bash
# porcelain/plumbing under scripts/. Enumerated with find rather than `git
# ls-files`, matching the repo's other whole-tree scan -- the leak guard in
# tests/fork-sandbox-k8s-test.sh ("no private-hostname shape in the repo")
# -- which greps the tree with .git excluded instead of shelling out to
# git; that also means this test still enumerates correctly in a checkout
# exported without a .git directory. install.sh's own PORCELAIN and
# PLUMBING arrays are already the one place that enumerates the
# extensionless names (every entry without a dot in its name is a bash
# script -- see install.sh's own "need bash 4+" comment on why they all
# start "#!/usr/bin/env bash"), so this reads them out the same way
# tests/install-porcelain-test.sh's own extract_list does rather than
# keeping a second, driftable list.
shellcheck_budget_files() {
    local repo="$1" path
    while IFS= read -r path; do
        printf '%s\n' "${path#"$repo"/}"
    done < <(find "$repo" -path "$repo/.git" -prune -o -type f -name '*.sh' -print)
    awk '
        /^(PORCELAIN|PLUMBING)=\($/ { grabbing=1; next }
        grabbing && /^\)/ { grabbing=0; next }
        grabbing {
            line = $0
            sub(/#.*/, "", line)
            gsub(/^[ \t]+/, "", line)
            gsub(/[ \t]+$/, "", line)
            if (line != "" && line !~ /\./) print "scripts/" line
        }
    ' "$repo/install.sh"
}

# --- The mechanism ------------------------------------------------------

# True if this host can actually run something under a systemd-run memory
# cap: the binary is on PATH, shellcheck is on PATH, and a live probe
# against a reachable --user manager succeeds. "systemd-run exists" and
# "systemd-run --user works here" are different facts -- most containers,
# and this project's own sandboxes, have the former without the latter --
# so scripts/fork-sandbox.sh's own systemd-scope probe (see its
# run_scope_available) checks both the same way this does. The probe uses
# $budget itself, not a hardcoded cap, so an unparsable
# SHELLCHECK_MEMORY_BUDGET (systemd rejects the -p MemoryMax=... value and
# the unit never starts) is caught here as "unavailable" rather than
# surfacing later as a false pass on every file.
shellcheck_budget_available() {
    command -v "$systemd_run_bin" >/dev/null 2>&1 || return 1
    command -v "$shellcheck_bin" >/dev/null 2>&1 || return 1
    "$systemd_run_bin" --user --wait --collect --pipe --quiet \
        -p "MemoryMax=$budget" -p MemorySwapMax=0 -- true >/dev/null 2>&1
}

# Runs shellcheck on FILE under a systemd-run memory cap of CAP, one file
# at a time -- callers must not run this in parallel across files, which is
# the whole point of the budget. Sets SHELLCHECK_BUDGET_LAST_OUTPUT to the
# run's captured output, SHELLCHECK_BUDGET_LAST_RESULT to the parsed
# "Finished with result: <value>" (empty if no such line could be found),
# and returns 0 if it stayed within budget, 1 otherwise.
#
# This keys on systemd's own "Finished with result: <value>" line (see
# systemd.exec(5)'s Result table) rather than a substring search for
# "oom-kill", and fails CLOSED: only "success" (a clean exit(0), i.e. the
# lint tool found nothing) or "exit-code" (a nonzero exit(N) that is still
# a normal process exit -- shellcheck's own lint-finding and parse-error
# statuses land here) count as staying within budget. Every other outcome
# is treated as a failure to report on, including "oom-kill" itself, but
# also: "signal" (a host with DefaultOOMPolicy=continue reports an OOM
# kill this way instead of "oom-kill"), "timeout"/"watchdog"/"resources", or
# no "Finished with result:" line at all -- which is what happens when the
# transient unit never starts, e.g. systemd-run rejecting an unparsable
# -p MemoryMax=$cap ("Failed to parse MemoryMax value"), SYSTEMD_LOG_LEVEL
# being set high enough to suppress the log_info line it comes from, or a
# summary line whose result value is not plain lowercase text (e.g. a host
# with SYSTEMD_COLORS forced on wrapping it in ANSI colour codes, which
# `[a-z-]*` will not match past). A guard whose only job is to catch OOM
# kills must never let "the check could not run or be read" read as "the
# check passed", so an unrecognized or missing result is a failure, not a
# silent pass -- but the caller (shellcheck_budget_report) still needs
# SHELLCHECK_BUDGET_LAST_RESULT to tell that apart from an actual OOM kill,
# since only the latter is fixed by the extended-analysis directive. That
# is also why --quiet is NOT passed here even though the mechanism probe
# above uses it: --quiet would suppress exactly the line this depends on.
# --pipe is kept per the recommended invocation, but its own stdout is not
# otherwise inspected -- the lint verdict itself is not this test's business.
SHELLCHECK_BUDGET_LAST_OUTPUT=""
SHELLCHECK_BUDGET_LAST_RESULT=""
shellcheck_budget_check() {
    local file="$1" cap="$2"
    SHELLCHECK_BUDGET_LAST_OUTPUT="$("$systemd_run_bin" --user --wait --collect --pipe \
        -p "MemoryMax=$cap" -p MemorySwapMax=0 \
        -- "$shellcheck_bin" "$file" 2>&1)"
    SHELLCHECK_BUDGET_LAST_RESULT="$(printf '%s\n' "$SHELLCHECK_BUDGET_LAST_OUTPUT" \
        | grep -o 'Finished with result: [a-z-]*' | tail -n1 | sed 's/^.*: //')"
    [[ "$SHELLCHECK_BUDGET_LAST_RESULT" == "success" || "$SHELLCHECK_BUDGET_LAST_RESULT" == "exit-code" ]]
}

# Checks FILE and records ok/no the same way the real run below does, so
# the self-tests exercise the actual reporting text (which file, which fix)
# instead of a second copy of it.
#
# A failure only gets the OOM diagnosis and the extended-analysis fix when
# SHELLCHECK_BUDGET_LAST_RESULT is actually "oom-kill" or "signal" (the
# DefaultOOMPolicy=continue spelling of the same kill). Every other failure
# -- no result line, an unrecognized one, a timeout -- means the check
# itself could not run or be read, which the extended-analysis directive
# does not fix and is not evidence that any given file is the problem; it
# is reported with the parsed result and a tail of the captured output
# instead, so the real cause is visible rather than discarded.
shellcheck_budget_report() {
    local file="$1" cap="$2"
    if shellcheck_budget_check "$file" "$cap"; then
        ok "shellcheck stays under $cap on $file"
        return
    fi
    case "$SHELLCHECK_BUDGET_LAST_RESULT" in
        oom-kill|signal)
            no "shellcheck was OOM-killed checking $file" \
               "add '# shellcheck extended-analysis=false' near the top of $file (or split its flat top-level code into functions) -- the budget exists so one lint run cannot OOM a host"
            ;;
        *)
            no "the memory-budget check could not run or be read for $file" \
               "systemd-run result: '${SHELLCHECK_BUDGET_LAST_RESULT:-<none found>}'; last lines of its output: $(printf '%s\n' "$SHELLCHECK_BUDGET_LAST_OUTPUT" | tail -n5)"
            ;;
    esac
}

# --- Self-test stubs -----------------------------------------------------

# A systemd-run stub that reports success for a probe call, paired with a
# stub for the shellcheck binary too -- so the "available" self-test below
# is deterministic even on a host with no real shellcheck installed.
write_probe_ok_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$bin/systemd-run"
    cat > "$bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$bin/shellcheck"
}

# A systemd-run stub simulating "the binary is on PATH but there is no
# usable --user manager" -- exactly what this sandbox itself looks like.
write_probe_fail_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$bin/systemd-run"
}

# A systemd-run stub that fakes systemd's own OOM report for one named
# file, a lint-finding exit code (1, "Finished with result: exit-code",
# which is what a normal nonzero exit(N) looks like, OOM or not) for
# another, and a clean "Finished with result: success" exit for everything
# else -- without ever running a real shellcheck. It inspects only the last
# argv element, which in the real invocation is always the file path the
# linter was handed.
write_decision_stub() {
    local bin="$1" oom_needle="$2" lint_needle="$3"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<STUB
#!/usr/bin/env bash
target="\${*: -1}"
if [[ "\$target" == *"$oom_needle"* ]]; then
    echo "Main PID: 1 (code=killed, signal=KILL)" >&2
    echo "Finished with result: oom-kill" >&2
    exit 137
fi
if [[ "\$target" == *"$lint_needle"* ]]; then
    echo "Finished with result: exit-code" >&2
    exit 1
fi
echo "Finished with result: success" >&2
exit 0
STUB
    chmod +x "$bin/systemd-run"
}

# A systemd-run stub simulating the unit never starting at all -- e.g. an
# unparsable -p MemoryMax=... value ("Failed to parse MemoryMax value") --
# so there is no "Finished with result:" line to find at all, only a
# nonzero exit.
write_no_result_line_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "Failed to parse MemoryMax value" >&2
exit 1
STUB
    chmod +x "$bin/systemd-run"
}

# A systemd-run stub simulating a host with DefaultOOMPolicy=continue,
# where the kernel OOM killer's SIGKILL is reported as "result: signal"
# rather than "result: oom-kill".
write_signal_death_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "Main PID: 1 (code=killed, signal=KILL)" >&2
echo "Finished with result: signal" >&2
exit 137
STUB
    chmod +x "$bin/systemd-run"
}

# A systemd-run stub that rejects an unparsable MemoryMax value the way
# systemd itself does, and accepts a well-formed one -- so the probe's use
# of $budget (rather than a hardcoded cap) is exercised against something
# other than a stub that blindly exits 0 regardless of its arguments.
write_budget_validating_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        -pMemoryMax=*|MemoryMax=*)
            val="${arg#*MemoryMax=}"
            if [[ ! "$val" =~ ^[0-9]+[KMGT%]?$ ]]; then
                echo "Failed to parse MemoryMax value $val" >&2
                exit 1
            fi
            ;;
    esac
done
exit 0
STUB
    chmod +x "$bin/systemd-run"
    cat > "$bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$bin/shellcheck"
}

real_path="$PATH"

mktmp_dir() { local d; d="$(mktemp -d)"; tmpdirs+=("$d"); printf '%s' "$d"; }

# --- Self-tests: the mechanism probe -------------------------------------

echo "== self-tests: shellcheck_budget_available (mechanism probe) =="

avail_stub="$(mktmp_dir)"
write_probe_ok_stub "$avail_stub"

PATH="$avail_stub:$real_path"
shellcheck_budget_available; rc=$?
PATH="$real_path"
check_rc "systemd-run + shellcheck present, probe succeeds: available" 0 "$rc"

fail_stub="$(mktmp_dir)"
write_probe_fail_stub "$fail_stub"

PATH="$fail_stub:$real_path"
shellcheck_budget_available; rc=$?
PATH="$real_path"
check_rc "systemd-run present but no reachable --user manager: SKIP" 1 "$rc"

systemd_run_bin="systemd-run-does-not-exist-xyz"
shellcheck_budget_available; rc=$?
systemd_run_bin="systemd-run"
check_rc "systemd-run missing entirely: SKIP" 1 "$rc"

shellcheck_bin="shellcheck-does-not-exist-xyz"
PATH="$avail_stub:$real_path"
shellcheck_budget_available; rc=$?
PATH="$real_path"
shellcheck_bin="shellcheck"
check_rc "shellcheck missing entirely: SKIP" 1 "$rc"

budget_validating_stub="$(mktmp_dir)"
write_budget_validating_stub "$budget_validating_stub"

old_budget="$budget"
budget="3G"
PATH="$budget_validating_stub:$real_path"
shellcheck_budget_available; rc=$?
PATH="$real_path"
check_rc "a well-formed \$budget is accepted by the probe" 0 "$rc"

budget="three"
PATH="$budget_validating_stub:$real_path"
shellcheck_budget_available; rc=$?
PATH="$real_path"
budget="$old_budget"
check_rc "an unparsable SHELLCHECK_MEMORY_BUDGET is caught by the probe, not left for every per-file run to silently pass" 1 "$rc"

# --- Self-tests: the per-file OOM decision --------------------------------

echo
echo "== self-tests: shellcheck_budget_check (per-file OOM decision) =="

decision_stub="$(mktmp_dir)"
write_decision_stub "$decision_stub" "big-flat.sh" "has-lint-findings.sh"

PATH="$decision_stub:$real_path"
shellcheck_budget_check "/repo/scripts/big-flat.sh" "$budget"; rc=$?
PATH="$real_path"
check_rc "an OOM'd file fails the check" 1 "$rc"
contains "the captured output names systemd's own result" "oom-kill" "$SHELLCHECK_BUDGET_LAST_OUTPUT"

PATH="$decision_stub:$real_path"
shellcheck_budget_check "/repo/scripts/has-lint-findings.sh" "$budget"; rc=$?
PATH="$real_path"
check_rc "a shellcheck lint-finding exit code (1, no OOM) is not a failure" 0 "$rc"

PATH="$decision_stub:$real_path"
shellcheck_budget_check "/repo/scripts/clean.sh" "$budget"; rc=$?
PATH="$real_path"
check_rc "a clean shellcheck run (exit 0) stays within budget" 0 "$rc"

no_result_stub="$(mktmp_dir)"
write_no_result_line_stub "$no_result_stub"

PATH="$no_result_stub:$real_path"
shellcheck_budget_check "/repo/scripts/anything.sh" "$budget"; rc=$?
PATH="$real_path"
check_rc "no 'Finished with result:' line at all (e.g. an unparsable MemoryMax) fails closed, not open" 1 "$rc"
check_rc "...but the parsed result is empty, not 'oom-kill'" "" "$SHELLCHECK_BUDGET_LAST_RESULT"

signal_stub="$(mktmp_dir)"
write_signal_death_stub "$signal_stub"

PATH="$signal_stub:$real_path"
shellcheck_budget_check "/repo/scripts/anything.sh" "$budget"; rc=$?
PATH="$real_path"
check_rc "a DefaultOOMPolicy=continue host reporting the kill as 'result: signal' still fails the check" 1 "$rc"
check_rc "...and the parsed result is 'signal', so the report still diagnoses it as an OOM kill" "signal" "$SHELLCHECK_BUDGET_LAST_RESULT"

# --- Self-tests: the report names the file and the fix --------------------

echo
echo "== self-tests: shellcheck_budget_report =="

PATH="$decision_stub:$real_path"
report_out="$(shellcheck_budget_report "/repo/scripts/big-flat.sh" "$budget" 2>&1)"
PATH="$real_path"
contains "the failing file is named" "/repo/scripts/big-flat.sh" "$report_out"
contains "the fix is spelled out" "shellcheck extended-analysis=false" "$report_out"
contains "the report is marked FAIL" "FAIL" "$report_out"

PATH="$decision_stub:$real_path"
report_out="$(shellcheck_budget_report "/repo/scripts/clean.sh" "$budget" 2>&1)"
PATH="$real_path"
lacks "a within-budget file is not reported as FAIL" "FAIL" "$report_out"

PATH="$signal_stub:$real_path"
report_out="$(shellcheck_budget_report "/repo/scripts/anything.sh" "$budget" 2>&1)"
PATH="$real_path"
contains "a 'result: signal' kill is still reported as FAIL" "FAIL" "$report_out"
contains "...and still gets the OOM diagnosis and fix, since it is one" "shellcheck extended-analysis=false" "$report_out"

PATH="$no_result_stub:$real_path"
report_out="$(shellcheck_budget_report "/repo/scripts/anything.sh" "$budget" 2>&1)"
PATH="$real_path"
contains "a missing 'Finished with result:' line is still reported as FAIL" "FAIL" "$report_out"
lacks "...but is NOT misdiagnosed as an OOM kill" "OOM-killed" "$report_out"
lacks "...and does NOT prescribe the extended-analysis fix for a file that may not be the problem" "shellcheck extended-analysis=false" "$report_out"
contains "...and instead says the check itself could not run or be read" "could not run or be read" "$report_out"

# --- Self-tests: enumeration reuses install.sh's lists, not a new one -----

echo
echo "== self-tests: shellcheck_budget_files =="

files_out="$(shellcheck_budget_files "$repo_dir")"
contains "a tracked top-level .sh file is included" "install.sh" "$files_out"
contains "the two big test suites are included" "tests/fork-sandbox-k8s-test.sh" "$files_out"
contains "an extensionless PORCELAIN/PLUMBING bash script is included" "scripts/pi-sandboxed" "$files_out"
lacks "a .py entry from the same lists is not (this suite is bash-only)" "sandbox-run-log.py" "$files_out"

# --- The real check, or a clean SKIP -------------------------------------

echo
echo "== shellcheck memory budget: every tracked script, one at a time =="

if ! shellcheck_budget_available; then
    echo "SKIP: no usable '$systemd_run_bin --user ... --pipe' on this host (needs"
    echo "  systemd-run, shellcheck, and a reachable --user manager -- normal on"
    echo "  macOS, most containers, and this project's own sandboxes)."
else
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        shellcheck_budget_report "$repo_dir/$f" "$budget"
    done < <(shellcheck_budget_files "$repo_dir")
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
