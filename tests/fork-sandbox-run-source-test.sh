#!/usr/bin/env bash
# fork-sandbox-run-source-test.sh — Exercise a run's provenance declaration:
# the launcher's FORK_SANDBOX_RUN_SOURCE validation, the run-source marker
# in the run directory, sandbox-run-log.py record picking the marker up as
# the record's `source`, and list/stats excluding source "test" by default
# (announced on stderr, re-enabled with --include-tests) while show stays
# unfiltered.
#
# Usage: tests/fork-sandbox-run-source-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
runlog="$repo_dir/scripts/sandbox-run-log.py"

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
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

not_contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect to find '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

last_line() { printf '%s\n' "$1" | tail -n1; }

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")
export FORK_SANDBOX_CONFIG_DIR="$tmp/config"
mkdir -p "$FORK_SANDBOX_CONFIG_DIR"

# The throwaway HOME the run log lives in: the suite never touches the
# operator's own ~/.claude/sandbox-runs.jsonl. Snapshot the real log (if
# this host has one) so the final check can prove it was left untouched.
log_home="$tmp/log-home"
mkdir -p "$log_home/.claude"
real_log="$HOME/.claude/sandbox-runs.jsonl"
real_log_before="$(cat "$real_log" 2>/dev/null || true)"

record() {
    HOME="$log_home" python3 "$runlog" record --run-dir "$1"
}
query() {
    HOME="$log_home" python3 "$runlog" "$@"
}

# --dry-run resolves and validates, then exits before the clone -- exactly
# what the launcher-side checks need, and none of it needs a real project
# or handoff.
dry() {
    "$launcher" --dry-run unused-project unused-handoff
}

# A fixture run directory, directly under the forks root with a
# distinctive name, carrying a fabricated summary.json: what a test
# suite's own runs look like in the record. Prints the new directory; the
# caller registers it in tmpdirs (this runs in a subshell, so it cannot).
mk_run_dir() {
    local rd
    rd="$(mktemp -d "/var/tmp/claude-scratch/forks/claude-fork-sandbox.rsrc-$1.XXXXXX")"
    cat > "$rd/summary.json" <<'EOF'
{"harness":"claude","model":"test/fixture-model","branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"usage":{"input_tokens":100,"output_tokens":10},"duration_seconds":0}
EOF
    printf '0\n' > "$rd/exit-code"
    printf '%s' "$rd"
}

err="$tmp/err"

# The record of a run with NO marker must be byte-for-byte the old shape:
# the default source, and no extra keys.
printf '== record: the marker, and its absence ==\n'
rd_plain="$(mk_run_dir plain)"
tmpdirs+=("$rd_plain")
if ! record "$rd_plain" >/dev/null 2>"$err"; then
    no "record without a marker succeeds" "record exited non-zero"
else
    check "record without a marker: source stays the default" "fork-sandbox" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"
fi
not_contains "record without a marker prints no warning" \
    "run-source" "$(cat "$err")"
check "record without a marker has no summary_missing key" "false" \
    "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -c 'has("summary_missing")')"
check "record without a marker still has the default event" "run_end" \
    "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .event)"
not_contains "record without a marker writes no marker" \
    "run-source" "$(find "$rd_plain" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"

# A marker holding "test" becomes the record's source.
rd_test="$(mk_run_dir test)"
tmpdirs+=("$rd_test")
printf 'test\n' > "$rd_test/run-source"
record "$rd_test" >/dev/null 2>"$err" \
    && check "a 'test' marker becomes the source" "test" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"
# No trailing newline on the marker: the read strips it.
rd_test_nonl="$(mk_run_dir testnonl)"
tmpdirs+=("$rd_test_nonl")
printf 'test' > "$rd_test_nonl/run-source"
record "$rd_test_nonl" >/dev/null 2>"$err" \
    && check "a 'test' marker without a trailing newline is accepted" "test" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"

# An unrecognized-but-well-formed token is a source too: the tool does not
# police the value, it records it.
rd_other="$(mk_run_dir other)"
tmpdirs+=("$rd_other")
printf 'fixture\n' > "$rd_other/run-source"
record "$rd_other" >/dev/null 2>"$err" \
    && check "a well-formed non-test marker becomes the source" "fixture" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"

# The other side of the pattern's length boundary: 32 characters is the
# maximum and must record cleanly, not fall back.
rd_max="$(mk_run_dir max)"
tmpdirs+=("$rd_max")
printf 'a1234567890123456789012345678901\n' > "$rd_max/run-source"
record "$rd_max" >/dev/null 2>"$err" \
    && check "a 32-character marker (the pattern's maximum) is accepted" \
        "a1234567890123456789012345678901" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"
not_contains "a 32-character marker prints no warning" \
    "run-source marker" "$(cat "$err")"

printf '\n== record: a malformed marker warns and falls back ==\n'
rd_bad="$(mk_run_dir bad)"
tmpdirs+=("$rd_bad")
bad_source() {  # $1 = marker bytes to write; record must fall back
    printf '%s' "$1" > "$rd_bad/run-source"
    if record "$rd_bad" >/dev/null 2>"$err"; then
        ok "a malformed marker does not fail the record ($2)"
        check "a malformed marker falls back to the default ($2)" \
            "fork-sandbox" \
            "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"
        contains "a malformed marker warns on stderr ($2)" \
            "run-source marker" "$(cat "$err")"
    else
        no "a malformed marker does not fail the record ($2)" "record exited non-zero"
    fi
}
bad_source 'TEST' "uppercase"
bad_source 'has space' "embedded space"
bad_source 'a234567890123456789012345678901234567890' "40 characters"
bad_source 'a12345678901234567890123456789012' "33 characters"
bad_source 'test
extra
' "embedded newline"
# Present but not a regular file we can trust: a symlink.
rm -f "$rd_bad/run-source"
ln -s /etc/hostname "$rd_bad/run-source"
if record "$rd_bad" >/dev/null 2>"$err"; then
    ok "a symlink marker does not fail the record"
    check "a symlink marker falls back to the default" "fork-sandbox" \
        "$(tail -1 "$log_home/.claude/sandbox-runs.jsonl" | jq -r .source)"
    contains "a symlink marker warns on stderr" \
        "run-source marker" "$(cat "$err")"
else
    no "a symlink marker does not fail the record" "record exited non-zero"
fi
rm -f "$rd_bad/run-source"

# Fresh log for the query checks: one ordinary run, one future-source
# run, two test runs.
printf '\n== list and stats: source "test" is excluded by default ==\n'
rm -f "$log_home/.claude/sandbox-runs.jsonl"
record "$rd_plain"  >/dev/null 2>"$err"   # source: fork-sandbox
record "$rd_other"  >/dev/null 2>"$err"   # source: fixture
record "$rd_test"   >/dev/null 2>"$err"   # source: test
record "$rd_test_nonl" >/dev/null 2>"$err" # source: test

out="$(query list 2>"$err")"
check "list by default reports the two non-test runs" "2 run(s)" \
    "$(last_line "$out")"
contains "list still shows the ordinary run" "rsrc-plain" "$out"
contains "a future source value appears by default" "rsrc-other" "$out"
not_contains "list omits the test runs" "rsrc-test" "$out"
contains "the exclusion announces itself on stderr" \
    "sandbox-run-log: 2 test run(s) excluded; pass --include-tests to include them" \
    "$(cat "$err")"
not_contains "the exclusion notice stays off stdout" "excluded" "$out"

out="$(query list --include-tests 2>"$err")"
check "list --include-tests reports all four" "4 run(s)" "$(last_line "$out")"
contains "list --include-tests shows the test runs" "rsrc-test" "$out"
not_contains "no notice when nothing was dropped" "excluded" "$(cat "$err")"

out="$(query stats --by harness 2>"$err")"
check "stats by default counts the two non-test runs" \
    "2 run(s); LANDED = integrated, integrated-with-fixes or rescued; DIED = exit != 0" \
    "$(last_line "$out")"
contains "stats exclusion announces itself on stderr" \
    "2 test run(s) excluded" "$(cat "$err")"
out="$(query stats --by harness --include-tests 2>"$err")"
check "stats --include-tests counts all four" \
    "4 run(s); LANDED = integrated, integrated-with-fixes or rescued; DIED = exit != 0" \
    "$(last_line "$out")"
not_contains "stats --include-tests prints no notice" "excluded" "$(cat "$err")"

# Only "test" is hidden: group on source itself and the future value is
# there by default, "test" is not, and the flag brings it back.
out="$(query stats --by source 2>"$err")"
contains "stats --by source shows the future source by default" "fixture" "$out"
not_contains "stats --by source hides only 'test'" "test" "$out"
out="$(query stats --by source --include-tests 2>"$err")"
contains "stats --by source --include-tests shows 'test'" "test" "$out"

# show is per-run inspection: unfiltered, no flag.
out="$(query show "$(basename "$rd_test")")"
contains "show displays a test run with no flag" '"source": "test"' "$out"
contains "show still displays the whole record" '"duration_seconds": 0' "$out"

# A log with no test runs at all prints no notice.
rm -f "$log_home/.claude/sandbox-runs.jsonl"
record "$rd_plain" >/dev/null 2>"$err"
query list >/dev/null 2>"$err"
not_contains "no notice when the log holds no test runs" "excluded" "$(cat "$err")"

printf '\n== the launcher: FORK_SANDBOX_RUN_SOURCE validation ==\n'
# A malformed value is refused with a clear error, before the dry-run
# exit, so --dry-run cannot approve a launch the real run refuses.
bad_env() {  # $1 = value, $2 = description
    local rc=0
    FORK_SANDBOX_RUN_SOURCE="$1" dry >/dev/null 2>"$err" || rc=$?
    if (( rc != 0 )); then
        ok "FORK_SANDBOX_RUN_SOURCE='$2' is refused"
        contains "the refusal names the variable ($2)" \
            "FORK_SANDBOX_RUN_SOURCE" "$(cat "$err")"
    else
        no "FORK_SANDBOX_RUN_SOURCE='$2' is refused" "dry-run exited 0"
    fi
}
bad_env "Bad Value" "a space"
bad_env "Test" "uppercase"
bad_env "a12345678901234567890123456789012" "33 characters, one over the maximum"
bad_env "a234567890123456789012345678901234567890" "40 characters"
bad_env "-leading-hyphen" "a leading hyphen"
bad_env "1leading-digit" "a leading digit"
# Nothing is created: the refusal happens above run-directory creation.
before="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
    -name 'claude-fork-sandbox.*' -type d | wc -l)"
FORK_SANDBOX_RUN_SOURCE="Bad Value" dry >/dev/null 2>&1 || true
after="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
    -name 'claude-fork-sandbox.*' -type d | wc -l)"
check "a refused value creates no run directory" "$before" "$after"
# A well-formed value passes, and so does an unset variable. The
# 32-character value is the pattern's maximum: exactly at the boundary
# it passes, one character over was refused above.
if FORK_SANDBOX_RUN_SOURCE="a1234567890123456789012345678901" dry >/dev/null 2>&1; then
    ok "a well-formed value passes --dry-run"
else
    no "a well-formed value passes --dry-run" "dry-run failed"
fi
if FORK_SANDBOX_RUN_SOURCE="a1234567890123456789012345678901" dry >/dev/null 2>&1; then
    ok "a 32-character value (the pattern's maximum) passes --dry-run"
else
    no "a 32-character value (the pattern's maximum) passes --dry-run" \
        "dry-run failed"
fi
if dry >/dev/null 2>&1; then
    ok "an unset variable passes --dry-run"
else
    no "an unset variable passes --dry-run" "dry-run failed"
fi

# The suite's own guarantee: the operator's real log is untouched.
check "the operator's real log is untouched" "$real_log_before" \
    "$(cat "$real_log" 2>/dev/null || true)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
