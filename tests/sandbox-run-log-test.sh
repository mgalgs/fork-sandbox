#!/usr/bin/env bash
# sandbox-run-log-test.sh — Exercise sandbox-run-log.py's `network` field:
# record lifting it from summary.json and from a summary-missing run.env
# fallback, and read-time normalization of a historical harness="pi-local"
# row (from before harness and network were split) to harness="pi",
# network="sealed" -- without ever rewriting the log file on disk.
#
# Usage: tests/sandbox-run-log-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
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

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")

log_home="$tmp/log-home"
mkdir -p "$log_home/.claude"
log_file="$log_home/.claude/sandbox-runs.jsonl"

record() {
    HOME="$log_home" python3 "$runlog" record --run-dir "$1"
}
query() {
    HOME="$log_home" python3 "$runlog" "$@"
}

mk_run_dir() {  # $1 = distinctive suffix
    mktemp -d "/var/tmp/claude-scratch/forks/claude-fork-sandbox.rlog-$1.XXXXXX"
}

printf '== record: network is lifted from summary.json ==\n'
rd_sealed="$(mk_run_dir sealed)"
tmpdirs+=("$rd_sealed")
cat > "$rd_sealed/summary.json" <<'EOF'
{"harness":"pi","network":"sealed","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"usage":{"input_tokens":10,"output_tokens":1},"duration_seconds":0}
EOF
printf '0\n' > "$rd_sealed/exit-code"
record "$rd_sealed" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_sealed")")"
contains "a sealed run's network field is recorded" '"network": "sealed"' "$out"
contains "its harness stays pi (the binary), not folded into network" \
    '"harness": "pi"' "$out"

printf '\n== record: network from a summary-missing run.env fallback ==\n'
rd_env="$(mk_run_dir env)"
tmpdirs+=("$rd_env")
cat > "$rd_env/run.env" <<'EOF'
harness=pi
network=sealed
model=
branch=fixture-branch
origin_repo=/var/tmp/claude-scratch/forks/fixture-origin
base_sha=0123456789abcdef0123456789abcdef01234567
EOF
printf '0\n' > "$rd_env/exit-code"
record "$rd_env" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_env")")"
contains "run.env fallback still carries network" '"network": "sealed"' "$out"
contains "run.env fallback marks summary_missing" '"summary_missing": true' "$out"

printf '\n== read-time normalization of a historical pi-local row ==\n'
before_bytes="$(cat "$log_file")"
# A row shaped exactly like a run recorded before this round: harness is
# the literal string "pi-local", and there is no network key at all.
printf '%s\n' '{"v":1,"event":"run_end","run_id":"claude-fork-sandbox.histfix","ts":"2025-01-01T00:00:00+00:00","source":"fork-sandbox","harness":"pi-local","model":null,"exit_code":0,"commits":1,"cost_usd":0.01}' >> "$log_file"

out="$(query show claude-fork-sandbox.histfix)"
contains "show normalizes a historical pi-local row's harness to pi" \
    '"harness": "pi"' "$out"
contains "show normalizes a historical pi-local row's network to sealed" \
    '"network": "sealed"' "$out"

out="$(query list 2>/dev/null)"
not_contains "list does not show the unnormalized pi-local harness" \
    "pi-local" "$out"
contains "list shows the normalized harness cell as exactly pi" \
    "pi       -" "$out"

out="$(query stats --by network 2>/dev/null)"
contains "stats --by network groups the historical row under sealed" \
    "sealed" "$out"

after_bytes="$(cat "$log_file")"
check "the log file itself is never rewritten by normalization" \
    "$before_bytes
{\"v\":1,\"event\":\"run_end\",\"run_id\":\"claude-fork-sandbox.histfix\",\"ts\":\"2025-01-01T00:00:00+00:00\",\"source\":\"fork-sandbox\",\"harness\":\"pi-local\",\"model\":null,\"exit_code\":0,\"commits\":1,\"cost_usd\":0.01}" \
    "$after_bytes"

# A record that already carries network (post-round) must not be touched
# by the normalizer even if its harness happened to be "pi-local" (should
# never occur in practice, but the guard is "no network key", not "no
# harness value", so this proves the guard does not also fire here).
printf '%s\n' '{"v":1,"event":"run_end","run_id":"claude-fork-sandbox.histpinned","ts":"2025-01-01T00:00:00+00:00","source":"fork-sandbox","harness":"pi-local","network":"pinned","model":null,"exit_code":0,"commits":0}' >> "$log_file"
out="$(query show claude-fork-sandbox.histpinned)"
contains "a row that already carries network is left alone" \
    '"network": "pinned"' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
