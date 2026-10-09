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
# --json with no summary.json yet (done-by-exit-code, but the fetch that
# writes summary.json never ran in this fixture) now prints a state-only
# stand-in instead of hard-failing: a poller must be able to read `state`
# through to "replied"/"failed" without summary.json ever existing.
json="$($status --json "$rd")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "replied" ]] \
    || { echo "json state wrong without summary: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r .branch)" == "test" ]] \
    || { echo "json branch wrong without summary: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r .reply_file)" == "$rd/outbox/reply.md" ]] \
    || { echo "json reply_file wrong without summary: $json"; exit 1; }
# The runner writes exit-code before its fetch-back and reply.md: while the
# process in pid is still alive, an exit 0 is not yet a reply.
sleep 30 & finalizer=$!
printf '%s\n' "$finalizer" > "$rd/pid"
json="$($status --json "$rd")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "working" ]] \
    || { kill "$finalizer"; echo "replied while the runner was still finishing: $json"; exit 1; }
kill "$finalizer"; wait "$finalizer" 2>/dev/null
json="$($status --json "$rd")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "replied" ]] \
    || { echo "not replied once the runner exited: $json"; exit 1; }
rm -f -- "$rd/pid"
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

# 4c. The terminal block is one burst, emitted only once summary.txt
# exists: the result event must not go out ahead of the summary wait, or
# the Monitor tool delivers it as its own notification seconds early.
new_run_dir
printf '%s\n' "$dead_pid" > "$rd_new/pid"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"early account"}
EOF
printf '0\n' > "$rd_new/exit-code"
burst_out="$rd_new/monitor-out"
timeout 30 "$status" --monitor-terminal "$rd_new" > "$burst_out" 2>&1 &
burst_pid=$!
sleep 3
[[ ! -s "$burst_out" ]] \
    || { echo "monitor-terminal printed before summary.txt existed: $(cat "$burst_out")"; exit 1; }
printf 'late summary\n' > "$rd_new/summary.txt"
wait "$burst_pid"
out="$(cat "$burst_out")"
[[ "$out" == *"early account"* && "$out" == *"finished: done, exit 0, "* && "$out" == *"late summary"* ]] \
    || { echo "monitor-terminal burst incomplete: $out"; exit 1; }

# 4d. On a multi-leg run events.jsonl is only the code leg, so its result
# event is labelled as the code leg's rather than read as the run's end.
new_run_dir
printf '%s\n' "$dead_pid" > "$rd_new/pid"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"code leg account"}
EOF
cat > "$rd_new/events-review-1.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"review leg account"}
EOF
printf '0\n' > "$rd_new/exit-code"
printf 'multi summary\n' > "$rd_new/summary.txt"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$(head -1 <<<"$out")" == "(the code leg's own account; later legs' verdicts follow)" ]] \
    || { echo "multi-leg result event not labelled as the code leg's: $out"; exit 1; }
[[ "$out" == *"code leg account"* && "$out" == *"multi summary"* ]] \
    || { echo "multi-leg monitor-terminal block incomplete: $out"; exit 1; }

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

# 6d2. Event files sharing one mtime: the tie goes to the later step by
# number, so step 10 outranks steps 2 through 9.
new_run_dir
now_s=$(date +%s)
for n in 2 9 10; do
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"step %s line"}]}}\n' \
        "$n" > "$rd_new/events-s$n-review-1.jsonl"
    touch -d "@$((now_s - 5))" "$rd_new/events-s$n-review-1.jsonl"
done
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"last:     step 10 line"* ]] \
    || { echo "a tie did not go to step 10: $out"; exit 1; }

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

# 7e. The commit-guard Stop hook (fork-sandbox-stop-guard.sh) tags its own
# refusals on stderr the same way the inbox hook tags a delivery, so a
# refusal shows up in --notable (and therefore --monitor) too.
guard_events="$(mktemp)"
run_dirs+=("$guard_events")
cat > "$guard_events" <<'EOF'
{"type":"system","subtype":"hook_response","stderr":"fork-sandbox-stop-guard: refused 1/3 (2 uncommitted, 0 background shells)\n"}
EOF
out="$("$repo_dir/scripts/fork-sandbox-format.sh" --notable "$guard_events")"
[[ "$out" == *"◆ fork-sandbox-stop-guard: refused 1/3 (2 uncommitted, 0 background shells)"* ]] \
    || { echo "notable stop-guard refusal line missing: $out"; exit 1; }

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

# 8b-i. A read-only run (bare --review-only, or any preset whose first step
# is a review step) has no code leg at all -- its first leg's events go to
# events.jsonl too (run_leg's own "mode == review-only" branch), and
# run.env's first_leg_kind (written at launch) says which leg that was, so
# the activity line must name it, not "code".
new_run_dir
printf 'first_leg_kind=review\n' >> "$rd_new/run.env"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"activity: review, last event "* ]] \
    || { echo "activity line did not name the read-only review leg: $out"; exit 1; }

# 8b-ii. A read-only preset whose lone step is a maintain step runs on the
# maintainer seat instead, and its leg claims events.jsonl the same way.
new_run_dir
printf 'first_leg_kind=maintainer\n' >> "$rd_new/run.env"
cat > "$rd_new/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"account"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
[[ "$out" == *"activity: maintainer, last event "* ]] \
    || { echo "activity line did not name the read-only maintainer leg: $out"; exit 1; }

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

# 9c2. A per-leg refresh chain's continuation file (events-<tag>-continuation-
# <N>.jsonl, not the flat step-1 events-continuation-<N>.jsonl 9c already
# covers) is also a tee'd copy of its leg's own events-<tag>.jsonl, not new
# events, and must be skipped the same way.
new_run_dir
cat > "$rd_new/events-s2-code-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m one"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"base work"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
{"type":"result","subtype":"success","result":"continuation account"}
EOF
cat > "$rd_new/events-s2-code-1-continuation-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
{"type":"result","subtype":"success","result":"continuation account"}
EOF
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
if (( rc != 0 )); then echo "events-s2-code-1-continuation-1.jsonl was not accepted (rc=$rc): $out"; exit 1; fi
[[ "$out" == *"events:   4"* ]] || { echo "per-leg continuation double-counted: $out"; exit 1; }
[[ "$out" == *"commits:  1 (seen so far"* ]] || { echo "per-leg continuation commit miscounted: $out"; exit 1; }

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
printf '{"branch":"test","exit_code":0}\n' > "$rd_new/summary.json"
out="$(timeout 12 "$status" "$rd_new" 2>&1)"
rc=$?
[[ $rc -eq 0 && "$out" != *"is not a fork-sandbox run file"* ]] \
    || { echo "plain status choked on a run dir carrying pipeline.json (rc=$rc): $out"; exit 1; }
json="$(timeout 12 "$status" --json "$rd_new" 2>&1)"
rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r .branch)" == "test" \
    && "$(printf '%s' "$json" | jq -r .state)" == "replied" ]] \
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

# 18. --json on one run dir, no --set, carries every pre-existing key of
# the bare object untouched -- fixture-diffed on the subset, rather than
# substring matched -- plus the new additive state/reply_file keys. The
# hard exit 1 on a missing summary.json is gone; see the --resume contract
# cases above.
new_run_dir
printf '{"branch":"test","exit_code":0,"total_cost_usd":1.25}\n' > "$rd_new/summary.json"
out="$("$status" --json "$rd_new" 2>&1)"
[[ "$(printf '%s' "$out" | jq -c '{branch,exit_code,total_cost_usd}')" \
    == '{"branch":"test","exit_code":0,"total_cost_usd":1.25}' ]] \
    || { echo "single-dir --json dropped or changed a pre-existing key: $out"; exit 1; }
[[ "$(printf '%s' "$out" | jq -r .state)" == "replied" ]] \
    || { echo "single-dir --json state wrong: $out"; exit 1; }
# 18b. --json on a run dir with no summary.json at all no longer hard-exits
# -- it prints the state-only stand-in (queued, here: no exit-code, no pid,
# so run_state() reads "starting") -- the behavior change the --resume
# contract cases above exist to prove.
new_run_dir
out="$("$status" --json "$rd_new")"
[[ "$(printf '%s' "$out" | jq -r .state)" == "queued" ]] \
    || { echo "--json on a run dir with no summary.json had the wrong state: $out"; exit 1; }

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

# 26. A summary-bearing member whose exit_code is null (the k8s shape
# when the completion marker could not be read) must not be fabricated
# into "failed" -- it lands as "unknown", the same way TRAP 2 keeps an
# unknown cost from being summed as a known 0.
new_run_dir; rdNullExit="$rd_new"
printf '{"branch":"test","exit_code":null,"total_cost_usd":null}\n' > "$rdNullExit/summary.json"
json="$("$status" --json "$rdX" "$rdNullExit" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || { echo "a null-exit_code member failed the whole aggregate: $json"; exit 1; }
member="$(printf '%s' "$json" | jq -c '.runs[] | select(.run_id == "'"$(basename "$rdNullExit")"'")')"
[[ "$(jq -r '.state' <<<"$member")" == "unknown" && "$(jq -r '.summary' <<<"$member")" == "true" ]] \
    || { echo "null exit_code member was not derived as unknown: $member"; exit 1; }
[[ "$(jq -r '.totals.states.unknown' <<<"$json")" == "1" ]] \
    || { echo "totals.states did not count the unknown-state member: $json"; exit 1; }

# 27. --session <id> --progress: reads the by-session index fork-sandbox.sh
# writes at launch, never any run-dir argument on this command line, and
# runs no git. FORK_SANDBOX_BY_SESSION_DIR stands in for the real root, so
# this fixture never touches /var/tmp/claude-scratch/forks/by-session.
by_session_root="$(mktemp -d)"
trap 'rm -rf -- "${run_dirs[@]}" "$by_session_root"' EXIT

new_run_dir; rdProgA="$rd_new"
cat > "$rdProgA/progress.json" <<'EOF'
{"schema":1,"label":"sbx-foo","spec":null,"state":"running","updated":1,
 "steps":[{"action":"code","state":"done","i":1,"cap":1,"ended":null},
          {"action":"review","state":"running","i":1,"cap":2,"ended":null},
          {"action":"maintain","state":"pending","i":0,"cap":1,"ended":null}]}
EOF
new_run_dir; rdProgB="$rd_new"
# No progress.json at all -- the "still starting, or too old" case.

sess="fixture-session-$$"
mkdir -p "$by_session_root/$sess"
# Linked oldest first, by an explicit mtime on each SYMLINK itself (-h),
# never on the target -- the target's own mtime moves constantly as
# progress.json is rewritten, which print_progress_view must not sort by.
ln -s "$rdProgB" "$by_session_root/$sess/$(basename "$rdProgB")"
touch -h -d '2020-01-01T00:00:00' "$by_session_root/$sess/$(basename "$rdProgB")"
ln -s "$rdProgA" "$by_session_root/$sess/$(basename "$rdProgA")"
touch -h -d '2020-01-02T00:00:00' "$by_session_root/$sess/$(basename "$rdProgA")"

out="$(FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session "$sess" --progress 2>&1)"
[[ "$out" == "$(basename "$rdProgB")  ?"$'\n'"sbx-foo  running  code:done review:running(1/2) maintain:pending" ]] \
    || { echo "--session --progress did not print the expected two lines, oldest first: $out"; exit 1; }

out="$(FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session "no-such-session-$$" --progress 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
    || { echo "an unknown session did not print nothing and exit 0: rc=$rc out=$out"; exit 1; }

if "$status" --session "$sess" >/dev/null 2>&1; then
    echo "--session with no --progress was accepted"; exit 1
fi
if "$status" --progress >/dev/null 2>&1; then
    echo "--progress with no --session was accepted"; exit 1
fi
if FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session "$sess" --progress "$rdProgA" \
    >/dev/null 2>&1; then
    echo "--progress accepted a run-dir argument"; exit 1
fi

# 28. --session must be held to the launcher's own session-id shape
# (fork-sandbox.sh only ever creates an index directory named by a single
# path component, never "." or ".." or anything with a "/") -- otherwise
# "$by_session_root/$session" can walk out of the by-session root entirely.
# ".." is the sharpest case: it is a legal [A-Za-z0-9._-]+ string, so the
# regex alone would not catch it, and "$by_session_root/.." always exists
# (it is the by-session root's own parent), so without the extra ".."
# check this would list whatever else that parent happens to hold.
out="$(FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session ".." --progress 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
    || { echo "--session '..' was not refused like an unknown session: rc=$rc out=$out"; exit 1; }
out="$(FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session "../etc" --progress 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
    || { echo "--session '../etc' was not refused like an unknown session: rc=$rc out=$out"; exit 1; }

# 29. A by-session link is not trusted just because it lives in the index:
# its resolved target must still be a real fork-sandbox run directory (the
# same prefix-and-run.env rule every other mode here already applies)
# before its progress.json is read. A link to an arbitrary directory outside
# that boundary -- holding a progress.json of its own, as any directory
# could -- must print "?" like a missing-progress.json run, never that
# directory's actual label or state.
secret_dir="$(mktemp -d)"
cat > "$secret_dir/progress.json" <<'EOF'
{"schema":1,"label":"SECRET","spec":null,"state":"running","updated":1,"steps":[]}
EOF
sess_hostile="fixture-session-hostile-$$"
mkdir -p "$by_session_root/$sess_hostile"
ln -s "$secret_dir" "$by_session_root/$sess_hostile/not-a-run-dir"
out="$(FORK_SANDBOX_BY_SESSION_DIR="$by_session_root" "$status" --session "$sess_hostile" --progress 2>&1)"
[[ "$out" == "not-a-run-dir  ?" ]] \
    || { echo "a link outside the run-dir prefix was not refused: $out"; exit 1; }
[[ "$out" != *SECRET* ]] \
    || { echo "a directory outside the run-dir prefix leaked its progress.json: $out"; exit 1; }
rm -rf -- "$secret_dir"

# 30. A BLOCKED plan leg ends the run with no code leg and no events.jsonl,
# so --result and plain status must fall back to the plan's own text (see
# print_plan_report) rather than the generic "wrote no result" text a run
# with no events otherwise gets. step-1-loop.json's "ended" is the signal
# (the pipeline grammar keeps a plan step at step 1 whenever one exists).
new_run_dir
cat > "$rd_new/step-1-loop.json" <<'EOF'
{"ended":"blocked"}
EOF
printf 'BLOCKED\nthe brief asks for something this repository cannot do\n' \
    > "$rd_new/plan.md"
printf '1\n' > "$rd_new/exit-code"
printf 'exit: 1\ncommits: 0\nNothing landed.\n' > "$rd_new/summary.txt"
out="$($status --result "$rd_new")"
[[ "$out" == *"== report: plan leg (BLOCKED) =="* ]] \
    || { echo "--result omitted the plan report: $out"; exit 1; }
[[ "$out" == *"the brief asks for something this repository cannot do"* ]] \
    || { echo "--result did not carry the plan's own text: $out"; exit 1; }
[[ "$out" != *"wrote no result"* ]] \
    || { echo "--result still printed the generic no-result fallback: $out"; exit 1; }
out="$($status "$rd_new")"
[[ "$out" == *"== report: plan leg (BLOCKED) =="* ]] \
    || { echo "plain status omitted the plan report: $out"; exit 1; }
[[ "$out" == *"the brief asks for something this repository cannot do"* ]] \
    || { echo "plain status did not carry the plan's own text: $out"; exit 1; }
: > "$rd_new/events.jsonl"
printf '%s\n' "$dead_pid" > "$rd_new/pid"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$(head -1 <<<"$out")" == "== report: plan leg (BLOCKED) ==" ]] \
    || { echo "--monitor-terminal did not lead with the BLOCKED plan: $out"; exit 1; }
[[ "$out" != *"own account"* ]] \
    || { echo "--monitor-terminal printed an empty code-leg header: $out"; exit 1; }

# 30a. A plan leg that simply finished ("done") is not BLOCKED, so no plan
# report should appear -- the run's result is whatever the code leg after
# it wrote, which events.jsonl (absent here) would otherwise carry.
new_run_dir
cat > "$rd_new/step-1-loop.json" <<'EOF'
{"ended":"done"}
EOF
printf 'the approach\n' > "$rd_new/plan.md"
printf '0\n' > "$rd_new/exit-code"
out="$($status --result "$rd_new")"
[[ "$out" != *"report: plan leg"* ]] \
    || { echo "a done plan leg wrongly produced a plan report: $out"; exit 1; }

# 30b. A run whose step 1 is not code leaves events.jsonl empty; the session
# account comes from the last per-step code leg's events, pass order included.
new_run_dir
: > "$rd_new/events.jsonl"
printf '{"type":"result","subtype":"success","result":"plan account"}\n' \
    > "$rd_new/events-s1-plan-1.jsonl"
printf '{"type":"result","subtype":"success","result":"first code pass"}\n' \
    > "$rd_new/events-s2-code-1.jsonl"
printf '{"type":"result","subtype":"success","result":"second code pass"}\n' \
    > "$rd_new/events-s2-code-2.jsonl"
printf '0\n' > "$rd_new/exit-code"
printf 'exit: 0\n' > "$rd_new/summary.txt"
out="$($status --result "$rd_new")"
[[ "$out" == *"second code pass"* ]] \
    || { echo "--result did not read the last code leg's events: $out"; exit 1; }
[[ "$out" != *"wrote no result"* && "$out" != *"plan account"* ]] \
    || { echo "--result fell back to the wrong account: $out"; exit 1; }
out="$($status "$rd_new")"
[[ "$out" == *"second code pass"* ]] \
    || { echo "plain status did not read the last code leg's events: $out"; exit 1; }
printf '%s\n' "$dead_pid" > "$rd_new/pid"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$out" == *$'own account; later legs\' verdicts follow)\n== result: success'*"second code pass"* ]] \
    || { echo "--monitor-terminal did not flush the last code leg's result: $out"; exit 1; }

# 30c. A code leg's own --refresh-at continuation is tee'd into its base
# leg's file already (fs_refresh_chain), so the base file
# (events-s2-code-1.jsonl) holds the whole chain and the continuation file
# (events-s2-code-1-continuation-1.jsonl) is only its last slice. Sorted by
# name, the continuation file sorts after its base, so have_events must
# skip it explicitly or it wins as "the session's own account" and a
# reader sees only the tail, never the earlier lines (commits included) --
# --monitor's offset tracking would also read from under itself the moment
# the continuation file appeared, since it is far shorter than the base
# file it replaces.
new_run_dir
: > "$rd_new/events.jsonl"
cat > "$rd_new/events-s2-code-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m base-work"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
{"type":"result","subtype":"success","result":"continuation account"}
EOF
cat > "$rd_new/events-s2-code-1-continuation-1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"continuation line"}]}}
{"type":"result","subtype":"success","result":"continuation account"}
EOF
out="$($status --events 10 "$rd_new")"
[[ "$out" == *"base-work"* ]] \
    || { echo "--events read the continuation's own file instead of its base leg's: $out"; exit 1; }
printf '%s\n' "$dead_pid" > "$rd_new/pid"
out="$(timeout 30 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$out" == *"continuation account"* ]] \
    || { echo "--monitor-terminal did not flush the code leg's own continuation result: $out"; exit 1; }

# Security: every file collect brings back from a --k8s pod is input from
# a stranger, including bytes this script prints straight to a terminal
# (an OSC 52 clipboard-write sequence went through the progress label
# intact, by experiment -- the same channel feeds orchestrating agent
# sessions too, so it is a prompt-injection vector as well). Verdict files
# already strip control characters (see the review-verdict checks above);
# these prove the same treatment reaches --log, the tail of sandbox.log,
# the default view's summary.txt, and --session --progress's rendered
# line.
# The fix strips control BYTES, not the printable text an escape sequence
# carries alongside them -- "]52;c;...==" (the OSC payload, minus its ESC
# prefix and BEL terminator) is expected to remain; only the ESC/BEL bytes
# that make it an actual escape sequence to a terminal must be gone.
new_run_dir
printf 'startup ok\n\033]52;c;ZXZpbA==\007\ninjected\n' > "$rd_new/sandbox.log"
out="$("$status" --log "$rd_new" 2>&1)"
[[ "$out" == *"startup ok"* && "$out" == *"injected"* ]] \
    || { echo "--log dropped ordinary sandbox.log content: $out"; exit 1; }
[[ "$out" != *$'\033'* && "$out" != *$'\007'* ]] \
    || { echo "--log let a control sequence through to the terminal: $(printf '%q' "$out")"; exit 1; }

# print_tail_of_log in the default view only fires for "failed" or
# "abandoned" (a "done" run's default view never shows the log tail).
printf '1\n' > "$rd_new/exit-code"
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" == *"startup ok"* && "$out" == *"injected"* ]] \
    || { echo "default status dropped ordinary sandbox.log content: $out"; exit 1; }
[[ "$out" != *$'\033'* && "$out" != *$'\007'* ]] \
    || { echo "default status let a control sequence through via print_tail_of_log: $(printf '%q' "$out")"; exit 1; }

new_run_dir
printf '0\n' > "$rd_new/exit-code"
printf 'ordinary summary line\n\033]52;c;ZXZpbA==\007\nmore summary\n' > "$rd_new/summary.txt"
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" == *"ordinary summary line"* && "$out" == *"more summary"* ]] \
    || { echo "default status dropped ordinary summary.txt content: $out"; exit 1; }
[[ "$out" != *$'\033'* && "$out" != *$'\007'* ]] \
    || { echo "default status let a control sequence through via summary.txt: $(printf '%q' "$out")"; exit 1; }

# --session --progress's rendered line: label/state/action all come
# through a jq -r pipeline straight to stdout.
progress_session_root="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.status-progress.XXXXXX)"
run_dirs+=("$progress_session_root")
new_run_dir
printf '{"schema":1,"label":"evil\\u001b]52;c;ZXZpbA==\\u0007","state":"running","updated":%s,"steps":[]}\n' \
    "$(date +%s)" > "$rd_new/progress.json"
mkdir -p "$progress_session_root/sess1"
ln -s "$rd_new" "$progress_session_root/sess1/$(basename "$rd_new")"
out="$(FORK_SANDBOX_BY_SESSION_DIR="$progress_session_root" "$status" --progress --session sess1 2>&1)"
[[ "$out" == *"evil"* ]] \
    || { echo "--progress dropped the ordinary label text: $out"; exit 1; }
[[ "$out" != *$'\033'* && "$out" != *$'\007'* ]] \
    || { echo "--progress let a control sequence through via the label: $(printf '%q' "$out")"; exit 1; }

# 7. A composed --k8s run dir (network=cluster) never gets a local pid
# file: its agent runs in a pod, not under this host's tmux. Without a
# k8s-aware liveness signal, run_state() would read "starting" forever,
# and once started_at is more than a minute old --monitor-terminal would
# tell the operator the run never started and to relaunch it -- wrong,
# and a duplicate-launch hazard, for a pod that is in fact still running.
# k8s_client_pid (this test's own pid, standing in for the host-side
# client that is still waiting on the pod) must read as "running" instead.
new_run_dir
cat > "$rd_new/run.env" <<EOF
version=1
branch=test-k8s-live
origin_repo=/tmp/origin
clone_dir=/work/clone
started_at=$(( $(date +%s) - 300 ))
network=cluster
k8s_client_pid=$$
EOF
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" == "state:    running"* ]] \
    || { echo "a live composed k8s run was not read as running: $out"; exit 1; }
out="$("$status" --result "$rd_new" 2>&1)"
[[ "$out" == *"still running"* ]] \
    || { echo "--result read a live composed k8s run as anything but running: $out"; exit 1; }
out="$(timeout 5 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$out" != *"never started"* ]] \
    || { echo "monitor-terminal falsely reported a live composed k8s run as never started: $out"; exit 1; }

# 7b. The same shape, once the host-side client is gone: "abandoned", not
# stuck as "starting" forever, and the abandoned message names the k8s
# remedies (fork-sandbox-k8s.sh collect/rm) rather than the tmux/clone
# wording a local run's own abandoned message carries -- wrong here, since
# a composed k8s run's clone_dir is a pod path (/work/clone), never a host
# path to point an operator at.
new_run_dir
cat > "$rd_new/run.env" <<EOF
version=1
branch=test-k8s-dead
origin_repo=/tmp/origin
clone_dir=/work/clone
started_at=$(( $(date +%s) - 300 ))
network=cluster
k8s_client_pid=$dead_pid
EOF
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" == "state:    abandoned"* ]] \
    || { echo "a dead composed k8s run was not read as abandoned: $out"; exit 1; }
[[ "$out" == *"fork-sandbox-k8s.sh collect --run-dir "* ]] \
    || { echo "abandoned k8s run did not name the collect remedy: $out"; exit 1; }
[[ "$out" == *"--branch test-k8s-dead /tmp/origin"* ]] \
    || { echo "abandoned k8s run's collect remedy named the wrong branch/project: $out"; exit 1; }
[[ "$out" == *"fork-sandbox-k8s.sh rm --branch test-k8s-dead"* ]] \
    || { echo "abandoned k8s run did not name the rm remedy: $out"; exit 1; }
[[ "$out" != *"tmux session"* ]] \
    || { echo "abandoned k8s run used the local-run tmux wording: $out"; exit 1; }
out="$(timeout 10 "$status" --monitor-terminal "$rd_new" 2>&1)"
[[ "$out" == *"abandoned: the runner is gone and wrote no exit code"* ]] \
    || { echo "monitor-terminal did not report the abandoned composed k8s run: $out"; exit 1; }
[[ "$out" == *"fork-sandbox-k8s.sh collect --run-dir "* ]] \
    || { echo "monitor-terminal's abandoned block did not name the collect remedy: $out"; exit 1; }

# 8. The default status block's own "tmux:" line, for a composed --k8s run
# dir (network=cluster): no tmux session was ever started for one (see
# fork-sandbox.sh's own run.env writer, which skips `session=` in
# k8s_runner_mode), so printing it anyway -- naming a session that does not
# exist -- is a flat lie. cmd_submit's own k8s_job_name, the Job/Pod label
# an operator can actually act on, takes its place.
new_run_dir
cat > "$rd_new/run.env" <<EOF
version=1
branch=test-k8s-job
origin_repo=/tmp/origin
clone_dir=/work/clone
started_at=$(( $(date +%s) - 300 ))
network=cluster
k8s_client_pid=$$
k8s_job_name=fork-sandbox-agent-test-k8s-job
EOF
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" == *"job:      fork-sandbox-agent-test-k8s-job"* ]] \
    || { echo "a composed k8s run dir's status did not print its job name: $out"; exit 1; }
[[ "$out" != *"tmux:"* ]] \
    || { echo "a composed k8s run dir's status still printed a tmux line: $out"; exit 1; }

# 8b. A run.env written before k8s_job_name existed: no job name to print,
# but still no false tmux claim either -- an absent line beats a made-up one.
new_run_dir
cat > "$rd_new/run.env" <<EOF
version=1
branch=test-k8s-nojobname
origin_repo=/tmp/origin
clone_dir=/work/clone
started_at=$(( $(date +%s) - 300 ))
network=cluster
k8s_client_pid=$$
EOF
out="$("$status" "$rd_new" 2>&1)"
[[ "$out" != *"tmux:"* ]] \
    || { echo "a composed k8s run dir with no recorded job name still printed a tmux line: $out"; exit 1; }
[[ "$out" != *"job:"* ]] \
    || { echo "a composed k8s run dir with no recorded job name printed a job line anyway: $out"; exit 1; }

# 9. --json on a run whose summary.json already exists: state and
# reply_file are added on top, and every key summary.json already carried
# (branch, exit_code, harness) stays exactly as written -- additive, never
# a rename.
new_run_dir
cat > "$rd_new/run.env" <<EOF
version=1
branch=test-json-summary
origin_repo=/tmp/origin
clone_dir=/tmp/clone
started_at=$(date +%s)
EOF
cat > "$rd_new/summary.json" <<'EOF'
{"branch":"test-json-summary","exit_code":0,"harness":"claude"}
EOF
json="$("$status" --json "$rd_new")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "replied" ]] \
    || { echo "json state wrong with a done summary: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r .reply_file)" == "$rd_new/outbox/reply.md" ]] \
    || { echo "json reply_file wrong with a done summary: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r .branch)" == "test-json-summary" ]] \
    || { echo "json dropped the existing branch key: $json"; exit 1; }
[[ "$(printf '%s' "$json" | jq -r .harness)" == "claude" ]] \
    || { echo "json dropped an unrelated existing key: $json"; exit 1; }

# A local --keep-session runner execs a shell after writing summary.json.
# Its pid remains alive, but the run has finished and should be terminal.
printf '%s\n' "$$" > "$rd_new/pid"
json="$("$status" --json "$rd_new")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "replied" ]] \
    || { echo "completed local run stayed working with a live shell: $json"; exit 1; }

# 9b. The same, but a nonzero exit_code: state reads failed, not replied.
printf '{"branch":"test-json-summary","exit_code":1,"harness":"claude"}' \
    > "$rd_new/summary.json"
json="$("$status" --json "$rd_new")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "failed" ]] \
    || { echo "json state wrong with a failed summary: $json"; exit 1; }

# A cluster collector still owns teardown after it writes the summary.
printf 'network=cluster\n' >> "$rd_new/run.env"
json="$("$status" --json "$rd_new")"
[[ "$(printf '%s' "$json" | jq -r .state)" == "working" ]] \
    || { echo "cluster run finished before its live collector: $json"; exit 1; }

echo "92 passed, 0 failed"
