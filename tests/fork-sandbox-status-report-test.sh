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

# 4. An abandoned run whose session did write its result before the
# runner died: --monitor-terminal must flush that result event, before
# the abandoned: lines — the runner-killed-after-result case the flush
# exists for. Without events.jsonl here, have_events fails inside the
# flush and a removed or broken flush would still pass this test.
sleep 0.1 & dead_pid=$!
wait "$dead_pid"
new_run_dir
printf '%s\n' "$dead_pid" > "$rd_new/pid"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"session account"}
EOF
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$(head -1 <<<"$out")" == "== result: success"* ]] \
    || { echo "monitor-terminal did not flush the result event first: $out"; exit 1; }
[[ "$out" == *"session account"* ]] \
    || { echo "monitor-terminal dropped the session's result text: $out"; exit 1; }
[[ "$out" == *$'session account\nabandoned: the runner is gone and wrote no exit code, after '* ]] \
    || { echo "result flush did not precede abandoned line: $out"; exit 1; }
[[ "$out" == *"Nothing was fetched. The clone is still at /tmp/clone"* ]] \
    || { echo "monitor-terminal abandoned report incomplete: $out"; exit 1; }

# 4b. A failed run with a result event: same flush on the done|failed
# arm, but with a nonzero exit code.
new_run_dir
printf '%s\n' "$dead_pid" > "$rd_new/pid"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"failed session account"}
EOF
printf '3\n' > "$rd_new/exit-code"
printf 'failed run summary\n' > "$rd_new/summary.txt"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$(head -1 <<<"$out")" == "== result: success"* ]] \
    || { echo "monitor-terminal did not flush the result event on a failed run: $out"; exit 1; }
[[ "$out" == *"failed session account"* ]] \
    || { echo "monitor-terminal dropped the failed run's result text: $out"; exit 1; }
[[ "$out" == *"finished: failed, exit 3, "* && "$out" == *"failed run summary"* ]] \
    || { echo "monitor-terminal missing failed finished line or summary: $out"; exit 1; }

# 5. --monitor-terminal combined with another mode flag is refused in
# either argument order. A mode flag after it would switch the mode out from
# under terminal_only — a --follow that prints nothing at all, and an
# explicit --monitor that stays silent for its whole window; a mode flag
# before it is the same broken combination with the arguments swapped.
new_run_dir
printf '%s\n' "$$" > "$rd_new/pid"
: > "$rd_new/events.jsonl"
if out="$(timeout 12 "$status" --monitor-terminal --follow "$rd_new" 2>&1)"; then
    echo "monitor-terminal plus follow was accepted"; exit 1
fi
[[ "$out" == *"cannot be combined with --monitor-terminal"* ]] \
    || { echo "no conflict message: $out"; exit 1; }

# 5b. The same combination with the arguments swapped: a mode flag before
# --monitor-terminal used to be silently overridden.
if out="$(timeout 12 "$status" --follow --monitor-terminal "$rd_new" 2>&1)"; then
    echo "follow before monitor-terminal was accepted"; exit 1
fi
[[ "$out" == *"--monitor-terminal cannot be combined with --follow"* ]] \
    || { echo "no conflict message (reversed order): $out"; exit 1; }

# 5c. An explicit --monitor after --monitor-terminal is refused too — the
# one direction the old exemption swallowed, leaving a monitor that prints
# nothing for its whole window.
if out="$(timeout 12 "$status" --monitor-terminal --monitor "$rd_new" 2>&1)"; then
    echo "monitor-terminal plus monitor was accepted"; exit 1
fi
[[ "$out" == *"cannot be combined with --monitor-terminal"* ]] \
    || { echo "no conflict message (explicit monitor): $out"; exit 1; }

# 6. Multi-leg event files. A run writes one event file per leg, and
# events.jsonl stops moving the moment the code leg ends, so every counter
# in the status block must span every leg, and the 'last:' line must come
# from the newest one, not from events.jsonl.

# 6a. A run with only events.jsonl reports the same numbers as before.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m first"}}]}}
{"type":"result","subtype":"success","result":"code leg account"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"events:   2"* ]] || { echo "single-file event count wrong: $out"; exit 1; }
[[ "$out" == *"commits:  1 (seen so far"* ]] || { echo "single-file commit count wrong: $out"; exit 1; }

# 6b. The event count sums across the code leg and the later legs.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
{"type":"result","subtype":"success","result":"code leg account"}
EOF
cat > "$rd_new/events-review-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"looking"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"at the diff"}]}}
{"type":"result","subtype":"success","result":"review leg account"}
EOF
cat > "$rd_new/events-fix-1.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"fix leg account"}
EOF
now_s=$(date +%s)
touch -d "@$((now_s - 600))" "$rd_new/events.jsonl"
touch -d "@$((now_s - 120))" "$rd_new/events-review-1.jsonl"
touch -d "@$((now_s - 5))" "$rd_new/events-fix-1.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"events:   6"* ]] || { echo "summed event count wrong: $out"; exit 1; }

# 6c. The commit count sums across legs too, so a fix-leg commit is seen.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
EOF
cat > "$rd_new/events-review-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"looking"}]}}
EOF
cat > "$rd_new/events-fix-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m two"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"commits:  2 (seen so far"* ]] || { echo "summed commit count wrong: $out"; exit 1; }

# 6d. The 'last:' line comes from the newest event file, the active leg,
# not from events.jsonl.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"code leg line"}]}}
EOF
cat > "$rd_new/events-review-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"review leg line"}]}}
EOF
now_s=$(date +%s)
touch -d "@$((now_s - 600))" "$rd_new/events.jsonl"
touch -d "@$((now_s - 5))" "$rd_new/events-review-1.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"last:     review leg line"* ]] \
    || { echo "last event not from the newest leg: $out"; exit 1; }
[[ "$out" != *"last:     code leg line"* ]] \
    || { echo "last event still from events.jsonl: $out"; exit 1; }

# 6e. A file that merely starts events- is not an event file: it is not
# read, and the counts are unaffected.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
cat > "$rd_new/events-bogus.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m no"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"should not be counted"}]}}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)" || { echo "events-bogus.jsonl was not tolerated: $out"; exit 1; }
[[ "$out" == *"events:   1"* ]] || { echo "events-bogus.jsonl was counted: $out"; exit 1; }
[[ "$out" == *"commits:  0 (seen so far"* ]] || { echo "events-bogus.jsonl was counted for commits: $out"; exit 1; }

# 6f. A leg name with a non-number is refused rather than read: the strict
# pattern is what makes 6e's shape a non-issue, and a tampered run directory
# gets rejected before anything is printed.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
cat > "$rd_new/events-review-x.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"should not appear"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc == 0 )); then
    echo "events-review-x.jsonl was accepted (rc=0): $out"; exit 1
fi
[[ "$out" == *"'events-review-x.jsonl' is not a fork-sandbox run file"* ]] \
    || { echo "no refusal for a malformed leg name: $out"; exit 1; }
[[ "$out" != *"should not appear"* ]] || { echo "malformed leg file was read: $out"; exit 1; }

# 6g. A symlinked leg event file is refused exactly as a symlinked
# events.jsonl is: the security property, not a convenience.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
ln -s /etc/passwd "$rd_new/events-review-1.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc == 0 )); then
    echo "symlinked leg event file was accepted (rc=0)"; exit 1
fi
[[ "$out" == *"events-review-1.jsonl' is a symlink; refusing to read it"* ]] \
    || { echo "no symlink refusal for a leg file: $out"; exit 1; }

echo "16 passed, 0 failed"
