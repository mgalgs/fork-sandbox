#!/usr/bin/env bash
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status="$repo_dir/scripts/fork-sandbox-status.sh"
rd="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.status.XXXXXX)"
trap 'rm -rf -- "$rd"' EXIT
cat > "$rd/run.env" <<EOF
version=1
branch=test
origin_repo=/tmp/origin
clone_dir=/tmp/clone
started_at=$(date +%s)
EOF
cat > "$rd/review-loop.json" <<'EOF'
{"ended":"approved"}
EOF
cat > "$rd/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"session account"}
EOF
printf 'APPROVED\nChecked: tests.\n\n## Report\nleg 1\n' > "$rd/review-verdict-1.md"
printf 'FINDINGS\n\nfile:1 finding\n\n## Report\nleg 2\n' > "$rd/review-verdict-2.md"

out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 2 (FINDINGS) =="* ]] || { echo "no leg 2 report"; exit 1; }
[[ "$out" == *$'leg 2\n\n== the session'* ]] || { echo "report did not precede session account"; exit 1; }
[[ "$out" != *"file:1 finding"* && "$out" != *"Checked:"* ]] || { echo "verdict body leaked into report"; exit 1; }
printf 'done\n' > "$rd/summary.txt"
printf '0\n' > "$rd/exit-code"
out="$($status "$rd")"
[[ "$out" == *"== report: review leg 2 (FINDINGS) =="* ]] || { echo "default status omitted review report"; exit 1; }
[[ "$out" == *$'leg 2\n\n== the session'* ]] || { echo "default status report did not precede session account"; exit 1; }
[[ "$out" != *"file:1 finding"* && "$out" != *"Checked:"* ]] || { echo "default status leaked verdict body"; exit 1; }
printf 'APPROVED\nChecked: no report heading.\n' > "$rd/review-verdict-3.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 3 (APPROVED) — verdict, no usable report section =="* ]] || { echo "no report banner missing"; exit 1; }
[[ "$out" == *$'APPROVED\nChecked: no report heading.\n\n== the session'* ]] || { echo "whole verdict was not printed"; exit 1; }
printf 'APPROVED\nChecked: useful evidence.\n\n## Report\n' > "$rd/review-verdict-5.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 5 (APPROVED) — verdict, no usable report section =="* ]] || { echo "malformed report fallback banner missing"; exit 1; }
[[ "$out" == *$'APPROVED\nChecked: useful evidence.\n\n## Report\n\n== the session'* ]] || { echo "malformed report did not fall back to whole verdict"; exit 1; }
printf 'APPROVED\nChecked: useful evidence.\n\n## Report\nfirst\n\n## Report\nsecond\n' > "$rd/review-verdict-6.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 6 (APPROVED) — verdict, no usable report section =="* ]] || { echo "duplicate report fallback banner missing"; exit 1; }
[[ "$out" == *$'first\n\n## Report\nsecond\n\n== the session'* ]] || { echo "duplicate report did not fall back to whole verdict"; exit 1; }
json="$($status --json "$rd" 2>/dev/null || true)"
[[ -z "$json" ]] || { echo "unexpected json without summary"; exit 1; }
ln -s /etc/passwd "$rd/review-verdict-4.md"
if "$status" --result "$rd" >/dev/null 2>&1; then
    echo "symlinked verdict was accepted"; exit 1
fi

# Monitor modes on synthetic run dirs. run_state() judges a run running when
# the pid it read is alive, so the test's own pid plays the runner; a pid
# that has exited plays an abandoned run. Each case runs in a fresh dir and
# the watch loop either exits on its own (terminal state) or is stopped by
# timeout (a run that stays running).
run_dirs=("$rd")
new_run_dir() {
    rd_new="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.status.XXXXXX)"
    run_dirs+=("$rd_new")
    cat > "$rd_new/run.env" <<EOF
version=1
branch=test
origin_repo=/tmp/origin
clone_dir=/tmp/clone
started_at=$(date +%s)
EOF
}
trap 'rm -rf -- "${run_dirs[@]}"' EXIT

# 1. --monitor-terminal on a running run is silent for the whole window:
# no watching line, no notable stream, no early heartbeat.
new_run_dir
printf '%s\n' "$$" > "$rd_new/pid"
: > "$rd_new/events.jsonl"
out="$(timeout 12 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ -z "$out" ]] || { echo "monitor-terminal spoke before a terminal state: $out"; exit 1; }

# 2. --monitor on the same still-running run does announce itself.
new_run_dir
printf '%s\n' "$$" > "$rd_new/pid"
: > "$rd_new/events.jsonl"
out="$(timeout 12 "$status" --monitor "$rd_new" 2>&1)"
[[ "$out" == "watching: running, "* ]] || { echo "monitor did not announce a running run: $out"; exit 1; }

# 3. A finished run: --monitor-terminal stays silent until the terminal
# state. The finished run already has an exit code, so neither mode
# announces itself, and --monitor additionally streams the notable events
# first. The one terminal line the suppressed stream would have carried is
# the result event: --monitor-terminal must still flush it, before the
# finished: line, so the orchestrator sees the session's account. From the
# finished: line down, the two modes print the same thing.
new_run_dir
printf '%s\n' "$$" > "$rd_new/pid"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"session account"}
EOF
printf '0\n' > "$rd_new/exit-code"
printf 'summary body line\n' > "$rd_new/summary.txt"
mon="$(timeout 30 "$status" --monitor "$rd_new" 2>&1)"
monterm="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$(head -1 <<<"$monterm")" == "== result: success"* ]] \
    || { echo "monitor-terminal did not flush the result event first: $monterm"; exit 1; }
[[ "$monterm" == *"session account"* ]] \
    || { echo "monitor-terminal dropped the session's result text: $monterm"; exit 1; }
tail_mon="$(sed -n '/^finished:/,$p' <<<"$mon")"
tail_monterm="$(sed -n '/^finished:/,$p' <<<"$monterm")"
[[ -n "$tail_mon" ]] || { echo "monitor printed no finished: line: $mon"; exit 1; }
[[ "$tail_mon" == "$tail_monterm" ]] \
    || { echo "monitor-terminal terminal output differs from monitor: $tail_monterm vs $tail_mon"; exit 1; }
[[ "$monterm" == *"finished: done, exit 0, "* && "$monterm" == *"summary body line"* ]] \
    || { echo "monitor-terminal missing finished line or summary: $monterm"; exit 1; }

# 4. An abandoned run: --monitor-terminal prints the abandoned: lines.
sleep 0.1 & dead_pid=$!
wait "$dead_pid"
new_run_dir
printf '%s\n' "$dead_pid" > "$rd_new/pid"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$out" == "abandoned: the runner is gone and wrote no exit code, after "* ]] \
    || { echo "monitor-terminal did not report abandonment: $out"; exit 1; }
[[ "$out" == *"Nothing was fetched. The clone is still at /tmp/clone"* ]] \
    || { echo "monitor-terminal abandoned report incomplete: $out"; exit 1; }

# 5. --monitor-terminal followed by another mode flag is refused, instead
# of leaving terminal_only straddling modes — a --follow that prints
# nothing at all.
new_run_dir
printf '%s\n' "$$" > "$rd_new/pid"
: > "$rd_new/events.jsonl"
if out="$(timeout 12 "$status" --monitor-terminal --follow "$rd_new" 2>&1)"; then
    echo "monitor-terminal plus follow was accepted"; exit 1
fi
[[ "$out" == *"cannot be combined with --monitor-terminal"* ]] \
    || { echo "no conflict message: $out"; exit 1; }

echo "6 passed, 0 failed"
