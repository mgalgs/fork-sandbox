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

# 7. The commit count understands the pi event shape: pi puts the bash call
# in a tool_execution_start's args, not in an assistant tool_use, so a pi
# run used to count zero no matter how many commits it made.

# 7a. The formatter counts pi-shaped commits.
pi_events="$(mktemp)"
run_dirs+=("$pi_events")
cat > "$pi_events" <<'EOF'
{"type":"agent_start"}
{"type":"tool_execution_start","toolCallId":"a1","toolName":"bash","args":{"command":"git commit -m one"}}
{"type":"tool_execution_end","toolCallId":"a1","toolName":"bash","result":{"content":[]},"isError":false}
{"type":"tool_execution_start","toolCallId":"a2","toolName":"bash","args":{"command":"git log --oneline"}}
{"type":"tool_execution_start","toolCallId":"a3","toolName":"bash","args":{"command":"git commit --amend -m two"}}
EOF
count="$("$repo_dir/scripts/fork-sandbox-format.sh" --commit-count "$pi_events")"
[[ "$count" == "2" ]] || { echo "pi commit count wrong: $count"; exit 1; }

# 7b. The claude shape still counts, and non-JSON lines are dropped.
cat > "$pi_events" <<'EOF'
not json at all
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
EOF
count="$("$repo_dir/scripts/fork-sandbox-format.sh" --commit-count "$pi_events")"
[[ "$count" == "1" ]] || { echo "claude commit count regressed: $count"; exit 1; }

# 7c. Through the status script, a pi run's commits are seen in every leg.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"tool_execution_start","toolCallId":"a1","toolName":"bash","args":{"command":"git commit -m one"}}
EOF
cat > "$rd_new/events-review-1.jsonl" <<'EOF'
{"type":"tool_execution_start","toolCallId":"b1","toolName":"bash","args":{"command":"git commit -m two"}}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"commits:  2 (seen so far"* ]] || { echo "pi commits not summed: $out"; exit 1; }

# 7d. The --notable commit line fires for the pi shape too: it was left on
# the claude shape, so a pi run's --monitor stream stayed silent for the
# whole run even though the counter saw the commits.
cat > "$pi_events" <<'EOF'
{"type":"tool_execution_start","toolCallId":"a1","toolName":"bash","args":{"command":"git commit -m one"}}
{"type":"result","subtype":"success","result":"done"}
EOF
out="$("$repo_dir/scripts/fork-sandbox-format.sh" --notable "$pi_events")"
[[ "$out" == *"commit: git commit -m one"* ]] \
    || { echo "notable pi commit line missing: $out"; exit 1; }

# 8. The activity line names the active leg and how long since it moved, so
# a healthy multi-leg run no longer reads as wedged.

# 8a. It names the newest leg, not the code leg.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
cat > "$rd_new/events-review-2.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"review account"}
EOF
now_s=$(date +%s)
touch -d "@$((now_s - 600))" "$rd_new/events.jsonl"
touch -d "@$((now_s - 5))" "$rd_new/events-review-2.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"activity: review-2, last event "* ]] \
    || { echo "activity line did not name the active leg: $out"; exit 1; }
[[ "$out" != *"activity: code,"* && "$out" != *"activity: review-2, last event 10m"* ]] \
    || { echo "activity line named the wrong leg or stale age: $out"; exit 1; }

# 8b. A run with only events.jsonl names the code leg.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"activity: code, last event "* ]] \
    || { echo "activity line did not name the code leg: $out"; exit 1; }

# 8c. A run with no event files yet prints no activity line at all.
new_run_dir
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" != *"activity:"* ]] || { echo "activity line printed with no event files: $out"; exit 1; }
[[ "$out" == *"events:   0"* ]] || { echo "no-event-file count wrong: $out"; exit 1; }

# 9. The runner's remaining leg file shapes: a repeat pass of a fix or
# mntfix round names its file <kind>-<N>-p<P>, and the code leg's own repeat
# passes write events-code-<N>.jsonl. The first shape used to die the whole
# status script before anything was printed; the second was silently
# dropped from every counter and the activity line.

# 9a. A multi-pass fix leg is accepted in every mode and counted.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"code account"}
EOF
cat > "$rd_new/events-fix-1.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"fix pass 1 account"}
EOF
cat > "$rd_new/events-fix-1-p2.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m two"}}]}}
{"type":"result","subtype":"success","result":"fix pass 2 account"}
EOF
cat > "$rd_new/events-mntfix-1-p2.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"mntfix pass 2 account"}
EOF
now_s=$(date +%s)
touch -d "@$((now_s - 600))" "$rd_new/events.jsonl"
touch -d "@$((now_s - 300))" "$rd_new/events-fix-1.jsonl"
touch -d "@$((now_s - 30))" "$rd_new/events-mntfix-1-p2.jsonl"
touch -d "@$((now_s - 5))" "$rd_new/events-fix-1-p2.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc != 0 )); then echo "events-fix-1-p2.jsonl killed the status script (rc=$rc): $out"; exit 1; fi
[[ "$out" == *"events:   5"* ]] || { echo "multi-pass fix leg not counted: $out"; exit 1; }
[[ "$out" == *"commits:  1 (seen so far"* ]] || { echo "multi-pass fix leg commit not counted: $out"; exit 1; }
[[ "$out" == *"activity: fix-1-p2, last event "* ]] || { echo "activity did not name the pass file: $out"; exit 1; }
# The refusal ran in the startup pre-check before any mode dispatch, so one
# more mode on the same dir proves the others print as well.
"$status" --result "$rd_new" >/dev/null 2>&1 \
    || { echo "--result still died on a pass leg file"; exit 1; }

# 9b. The code leg's repeat passes (events-code-<N>.jsonl) are counted.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
EOF
cat > "$rd_new/events-code-2.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m two"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"polish"}]}}
{"type":"result","subtype":"success","result":"pass 2 account"}
EOF
now_s=$(date +%s)
touch -d "@$((now_s - 600))" "$rd_new/events.jsonl"
touch -d "@$((now_s - 5))" "$rd_new/events-code-2.jsonl"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"events:   4"* ]] || { echo "code repeat pass not counted: $out"; exit 1; }
[[ "$out" == *"commits:  2 (seen so far"* ]] || { echo "code repeat pass commit not counted: $out"; exit 1; }
[[ "$out" == *"activity: code-2, last event "* ]] || { echo "activity did not name the code pass: $out"; exit 1; }

# 9c. A continuation leg's file is accepted, and its events are counted
# exactly once: the runner tees the leg into events.jsonl AND its own file,
# so the file is a copy of an events.jsonl slice, not new events.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
EOF
cat > "$rd_new/events-continuation-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc != 0 )); then echo "events-continuation-1.jsonl was not accepted (rc=$rc): $out"; exit 1; fi
[[ "$out" == *"events:   2"* ]] || { echo "continuation leg double-counted: $out"; exit 1; }
[[ "$out" == *"commits:  1 (seen so far"* ]] || { echo "continuation leg commit miscounted: $out"; exit 1; }

# 9d. A name in the new shapes that still fails the pattern is refused.
new_run_dir
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
cat > "$rd_new/events-code-x.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"should not appear"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc == 0 )); then echo "events-code-x.jsonl was accepted (rc=0)"; exit 1; fi
[[ "$out" == *"'events-code-x.jsonl' is not a fork-sandbox run file"* ]] \
    || { echo "no refusal for a malformed code leg name: $out"; exit 1; }
[[ "$out" != *"should not appear"* ]] || { echo "malformed code leg file was read: $out"; exit 1; }

# 10. inbox_count skips mail-banner-* files -- a postmaster mail notice, not
# an operator addendum -- both while still live in inbox/ and after
# fs_archive_inbox has moved it out (the addendum still gets one; the
# banner sitting beside it in the same directories does not).
new_run_dir
mkdir -p "$rd_new/inbox" "$rd_new/inbox-delivered/leg-1"
printf 'an operator addendum\n' > "$rd_new/inbox/1700000000-01.md"
printf 'mail banner text\n' > "$rd_new/inbox/mail-banner-001-deadbeef.md"
printf 'an archived addendum\n' > "$rd_new/inbox-delivered/leg-1/1699999999-01.md"
printf 'archived mail banner text\n' > "$rd_new/inbox-delivered/leg-1/mail-banner-002-deadbeef.md"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"inbox:    2 addenda"* ]] \
    || { echo "inbox_count counted a mail banner as an addendum: $out"; exit 1; }

# 11a. status.sh never asks resolve_run_file for pipeline.json by name --
# reading it is 3d's job, not this round's -- so a run dir carrying it was
# always going to leave plain/--json status alone regardless of the
# allowlist; this is a smoke test that an unrelated file sitting in the run
# dir does not somehow trip a read, not proof the allowlist matters yet.
new_run_dir
printf '{"steps":[{"action":"code","harness":"claude","model":"haiku","repeat":1,"network":null,"fix":null}]}\n' \
    > "$rd_new/pipeline.json"
printf '0\n' > "$rd_new/exit-code"
printf '{"branch":"test"}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
[[ $rc -eq 0 && "$out" != *"is not a fork-sandbox run file"* ]] \
    || { echo "plain status choked on a run dir carrying pipeline.json (rc=$rc): $out"; exit 1; }
json="$(timeout 12 "$status" --json "$rd_new" 2>&1)"
rc=$?
[[ $rc -eq 0 && "$json" == '{"branch":"test"}' ]] \
    || { echo "--json choked on a run dir carrying pipeline.json (rc=$rc): $json"; exit 1; }

# 11b. The actual, checkable claim: resolve_run_file's literal-name allowlist
# names pipeline.json, so a future reader (3d's ledger) is not refused the
# moment it asks. Pinned against the source directly, since nothing calls
# resolve_run_file with that name yet for 11a to exercise end to end.
allowlist_line="$(grep -m1 '^ *run\.env|' "$repo_dir/scripts/fork-sandbox-status.sh")"
[[ "$allowlist_line" == *"|pipeline.json)"* ]] \
    || { echo "pipeline.json is missing from resolve_run_file's allowlist: $allowlist_line"; exit 1; }

# 12. A composed, review-only pipeline: one step, action review, named with
# the s<K>- prefix instead of the legacy review-loop.json/review-verdict-N
# shape. Every reader that used to glob only the legacy names must pick this
# up too.
new_run_dir
cat > "$rd_new/step-1-loop.json" <<'EOF'
{"ended":"approved"}
EOF
printf 'APPROVED\nChecked: the diff.\n\n## Report\ncomposed review body\n' \
    > "$rd_new/s1-review-verdict-1.md"
printf '0\n' > "$rd_new/exit-code"
printf 'done\n' > "$rd_new/summary.txt"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"== report: review leg 1 (APPROVED) =="* ]] \
    || { echo "composed review-only report missing: $out"; exit 1; }
[[ "$out" == *"composed review body"* ]] \
    || { echo "composed review-only report body missing: $out"; exit 1; }
mon_out="$(timeout 12 "$status" --monitor "$rd_new" 2>&1)"
[[ "$mon_out" == *"report: review leg 1 (APPROVED)"* ]] \
    || { echo "composed review-only marker wrong: $mon_out"; exit 1; }

# 13. A composed pipeline whose highest step is a review, not a maintain:
# step 1 maintains, step 2 reviews. The marker must still name step 2's
# review -- proving the selection rule is "highest step wins", not "prefer
# maintain" -- while both step bodies still print, maintainer first, same
# order the legacy dual-loop shape always used.
new_run_dir
cat > "$rd_new/step-1-loop.json" <<'EOF'
{"ended":"approved"}
EOF
cat > "$rd_new/step-2-loop.json" <<'EOF'
{"ended":"approved"}
EOF
printf 'APPROVED\nChecked: the branch.\n\n## Report\nstep 1 maintain body\n' \
    > "$rd_new/s1-maintain-verdict-1.md"
printf 'APPROVED\nChecked: the diff.\n\n## Report\nstep 2 review body\n' \
    > "$rd_new/s2-review-verdict-1.md"
printf '0\n' > "$rd_new/exit-code"
printf 'done\n' > "$rd_new/summary.txt"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"== report: maintainer leg 1 (APPROVED) =="* ]] \
    || { echo "step 1 maintain report missing: $out"; exit 1; }
[[ "$out" == *"== report: review leg 1 (APPROVED) =="* ]] \
    || { echo "step 2 review report missing: $out"; exit 1; }
if [[ "${out%%'== report: maintainer'*}" != "$out" \
    && "${out%%'== report: review leg'*}" == *"step 1 maintain body"* ]]; then
    : # maintainer body precedes review body, as legacy dual-loop always did
else
    echo "composed dual report order wrong: $out"; exit 1
fi
mon_out="$(timeout 12 "$status" --monitor "$rd_new" 2>&1)"
[[ "$mon_out" == *"report: review leg 1 (APPROVED)"* ]] \
    || { echo "highest-step-wins marker did not pick the review step: $mon_out"; exit 1; }
[[ "$mon_out" != *"report: maintainer leg"* ]] \
    || { echo "marker preferred maintain over the higher-numbered review step: $mon_out"; exit 1; }

# 14. A 4-step composition: code, review, maintain, review. The marker must
# come from the last step (a review, step 4), and each report body must come
# from the highest step of its own action -- the maintainer body from step 3
# (the only maintain step), the review body from step 4 (not step 2, the
# earlier review).
new_run_dir
cat > "$rd_new/step-2-loop.json" <<'EOF'
{"ended":"approved"}
EOF
cat > "$rd_new/step-3-loop.json" <<'EOF'
{"ended":"approved"}
EOF
cat > "$rd_new/step-4-loop.json" <<'EOF'
{"ended":"approved"}
EOF
printf 'APPROVED\nChecked: first pass.\n\n## Report\nstep 2 review body\n' \
    > "$rd_new/s2-review-verdict-1.md"
printf 'APPROVED\nChecked: the branch.\n\n## Report\nstep 3 maintain body\n' \
    > "$rd_new/s3-maintain-verdict-1.md"
printf 'APPROVED\nChecked: second pass.\n\n## Report\nstep 4 review body\n' \
    > "$rd_new/s4-review-verdict-1.md"
printf '0\n' > "$rd_new/exit-code"
printf 'done\n' > "$rd_new/summary.txt"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"== report: maintainer leg 1 (APPROVED) =="* && "$out" == *"step 3 maintain body"* ]] \
    || { echo "4-step maintainer report did not come from step 3: $out"; exit 1; }
[[ "$out" == *"step 4 review body"* ]] \
    || { echo "4-step review report did not come from step 4: $out"; exit 1; }
[[ "$out" != *"step 2 review body"* ]] \
    || { echo "4-step review report wrongly used the earlier step 2 verdict: $out"; exit 1; }
mon_out="$(timeout 12 "$status" --monitor "$rd_new" 2>&1)"
[[ "$mon_out" == *"report: review leg 1 (APPROVED)"* ]] \
    || { echo "4-step marker did not pick the last step's review: $mon_out"; exit 1; }

# 15. A symlinked composed verdict is refused exactly like a symlinked
# legacy one -- the preflight scan's widened glob must actually catch it,
# not just resolve_run_file's per-file allowlist.
new_run_dir
cat > "$rd_new/step-2-loop.json" <<'EOF'
{"ended":"approved"}
EOF
ln -s /etc/passwd "$rd_new/s2-review-verdict-1.md"
if "$status" --result "$rd_new" >/dev/null 2>&1; then
    echo "symlinked composed verdict was accepted"; exit 1
fi

# 16. The state line's done|failed case-arm annotates summary.json's
# end_reason -- stopped, stop-timeout, salvaged -- and adds nothing when
# the key is absent, so a run from before 'fork-sandbox stop' existed
# prints exactly as it always did.
new_run_dir
printf '0\n' > "$rd_new/exit-code"
printf '{"branch":"test","end_reason":"stopped"}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"state:    done (exit 0, after "*", stopped by operator)"* ]] \
    || { echo "stopped end_reason not annotated: $out"; exit 1; }

new_run_dir
printf '143\n' > "$rd_new/exit-code"
printf '{"branch":"test","end_reason":"stop-timeout"}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"state:    failed (exit 143, after "*", stop timeout kill)"* ]] \
    || { echo "stop-timeout end_reason not annotated: $out"; exit 1; }

new_run_dir
printf '143\n' > "$rd_new/exit-code"
printf '{"branch":"test","end_reason":"salvaged"}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"state:    failed (exit 143, after "*", salvaged after external kill)"* ]] \
    || { echo "salvaged end_reason not annotated: $out"; exit 1; }

new_run_dir
printf '0\n' > "$rd_new/exit-code"
printf '{"branch":"test"}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"state:    done (exit 0, after "*")"* ]] \
    || { echo "plain done state line missing: $out"; exit 1; }
[[ "$out" != *"stopped by operator"* && "$out" != *"salvaged"* && "$out" != *"timeout kill"* ]] \
    || { echo "absent end_reason wrongly annotated: $out"; exit 1; }

# 17. fork-sandbox-stop.sh's own forced/salvage completion deliberately
# never fabricates a summary.json (a stub there would suppress
# sandbox-run-log.py record's own no-summary fallback -- see that script's
# comment), so stop-timeout/salvaged now land only in the run log, keyed
# by the run dir's basename. The state line must still surface them from
# there when summary.json is absent -- exactly this run dir's shape.
new_run_dir
printf '143\n' > "$rd_new/exit-code"
printf 'test\n' > "$rd_new/run-source"
"$repo_dir/scripts/sandbox-run-log.py" record --run-dir "$rd_new" \
    --end-reason stop-timeout >/dev/null 2>&1
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"state:    failed (exit 143, after "*", stop timeout kill)"* ]] \
    || { echo "stop-timeout end_reason not read from the run-log fallback: $out"; exit 1; }

# 18. --json on one run dir, no --set, stays exactly the bare object it
# always was -- byte-identical, fixture-diffed rather than substring
# matched -- and the hard exit 1 on a missing summary.json is untouched.
new_run_dir
printf '{"branch":"test","exit_code":0,"total_cost_usd":1.25}\n' > "$rd_new/summary.json"
out="$("$status" --json "$rd_new" 2>&1)"
[[ "$out" == '{"branch":"test","exit_code":0,"total_cost_usd":1.25}' ]] \
    || { echo "single-dir --json is no longer byte-identical to the pre-fleet shape: $out"; exit 1; }
new_run_dir
if "$status" --json "$rd_new" >/dev/null 2>&1; then
    echo "--json on a run dir with no summary.json did not hard-exit"; exit 1
fi

# 19. 2+ dirs, no --set: the wrapper shape, runs in argument order.
new_run_dir; rdX="$rd_new"
printf 'harness=claude\nmodel=sonnet\n' >> "$rdX/run.env"
printf '{"branch":"test","exit_code":0,"total_cost_usd":1.5}\n' > "$rdX/summary.json"
new_run_dir; rdY="$rd_new"
printf 'harness=codex\nmodel=\n' >> "$rdY/run.env"
printf '{"branch":"test","exit_code":1,"total_cost_usd":null}\n' > "$rdY/summary.json"
json="$("$status" --json "$rdY" "$rdX" 2>&1)"
[[ "$(printf '%s' "$json" | jq -r '.runs | length')" == "2" ]] \
    || { echo "wrapper did not carry both runs: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r '.runs[0].run_id')" == "$(basename "$rdY")" \
    && "$(printf '%s' "$json" | jq -r '.runs[1].run_id')" == "$(basename "$rdX")" ]] \
    || { echo "wrapper runs were not in argument order: $json"; exit 1; }

# 20. --set with one dir: the wrapper shape even at arity one.
json="$("$status" --json --set "$rdX" 2>&1)"
[[ "$(printf '%s' "$json" | jq -r '.runs | length')" == "1" \
    && "$(printf '%s' "$json" | jq -r '.totals.runs')" == "1" ]] \
    || { echo "--set at arity one did not force the wrapper shape: $json"; exit 1; }

# 21. --set with zero dirs: a one-line refusal, not a crash.
err="$("$status" --json --set 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(wc -l <<<"$err")" -eq 1 ]] \
    || { echo "--set with no dirs did not refuse cleanly: rc=$rc out=$err"; exit 1; }

# 22. An in-flight member (no summary.json yet, still running) never kills
# the aggregate: it gets a state-only stand-in with summary:false and the
# fields run_state/run.env can actually supply, and the call still exits 0.
new_run_dir; rdRunning="$rd_new"
printf 'harness=claude\nmodel=opus\n' >> "$rdRunning/run.env"
printf '%s\n' "$$" > "$rdRunning/pid"
json="$("$status" --json "$rdX" "$rdRunning" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || { echo "an in-flight member failed the whole aggregate: $json"; exit 1; }
member="$(printf '%s' "$json" | jq -c '.runs[] | select(.run_id == "'"$(basename "$rdRunning")"'")')"
[[ "$(jq -r '.summary' <<<"$member")" == "false" ]] \
    || { echo "in-flight member did not carry summary:false: $member"; exit 1; }
[[ "$(jq -r '.state' <<<"$member")" == "running" \
    && "$(jq -r '.harness' <<<"$member")" == "claude" \
    && "$(jq -r '.model' <<<"$member")" == "opus" \
    && "$(jq 'has("cost_usd") or has("total_cost_usd")' <<<"$member")" == "false" ]] \
    || { echo "in-flight member is missing state/branch/harness/model or fabricated a summary field: $member"; exit 1; }

# 23. A hostile member (symlinked run.env) never kills the aggregate
# either, the refused file is never read, and it lands as "unreadable".
new_run_dir; rdHostile="$rd_new"
rm -f "$rdHostile/run.env"
ln -s /etc/passwd "$rdHostile/run.env"
json="$("$status" --json "$rdX" "$rdHostile" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || { echo "a hostile member failed the whole aggregate: $json"; exit 1; }
member="$(printf '%s' "$json" | jq -c '.runs[] | select(.run_id == "'"$(basename "$rdHostile")"'")')"
[[ "$(jq -r '.state' <<<"$member")" == "unreadable" && "$(jq -r '.summary' <<<"$member")" == "false" \
    && "$(jq -r '.error' <<<"$member")" == *"symlink"* ]] \
    || { echo "hostile member did not land as unreadable: $member"; exit 1; }
[[ "$(jq -r '.runs[0].run_id' <<<"$json")" == "$(basename "$rdX")" ]] \
    || { echo "the hostile member displaced a good one instead of standing alone: $json"; exit 1; }

# 24. totals: a numeric cost and a null (codex-shaped) cost in the same
# set sum only the numeric one, and count both. rdX above carries 1.5,
# rdY carries null.
json="$("$status" --json "$rdX" "$rdY" 2>&1)"
[[ "$(jq -r '.totals.runs_with_cost' <<<"$json")" == "1" \
    && "$(jq -r '.totals.runs_without_cost' <<<"$json")" == "1" \
    && "$(jq -r '.totals.cost_usd_total' <<<"$json")" == "1.5" ]] \
    || { echo "mixed numeric/null cost totals wrong: $json"; exit 1; }
[[ "$(jq -r '.totals.states.done' <<<"$json")" == "1" \
    && "$(jq -r '.totals.states.failed' <<<"$json")" == "1" ]] \
    || { echo "totals.states did not count both done and failed: $json"; exit 1; }

# 25. An all-null-cost set renders cost_usd_total as null, never a 0 that
# would masquerade as a known total.
json="$("$status" --json "$rdY" "$rdRunning" "$rdHostile" 2>&1)"
[[ "$(jq -r '.totals.cost_usd_total' <<<"$json")" == "null" \
    && "$(jq -r '.totals.runs_with_cost' <<<"$json")" == "0" \
    && "$(jq -r '.totals.runs_without_cost' <<<"$json")" == "3" ]] \
    || { echo "an all-unknown-cost set fabricated a total: $json"; exit 1; }

echo "54 passed, 0 failed"
