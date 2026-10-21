---
name: freshly-forked
description: Refresh the current session by forking a continuation into a split pane with a thorough handoff doc. Use when context is getting long, the user wants a fresh context window, or says "refresh", "fresh session", "new context", "hand off".
argument-hint: [topic] [--model <model>] — optional description of what to focus on next; --model picks the model for the new session (fable, opus, sonnet)
---

# Refresh Session

Replace the current session with a fresh one in this same tmux window,
writing a detailed handoff so nothing gets dropped.

## Instructions

1. **Analyze the conversation** to build a complete picture of:
   - What was accomplished (with specifics: files changed, commands run,
     things deployed, branches/worktrees created)
   - What is currently in progress (background tasks, running builds,
     pending deploys, forked tasks in other windows/worktrees)
   - What remains to be done (in priority order)
   - Any important context the new session needs (decisions made, approaches
     rejected, gotchas discovered, things to verify)

2. **Write the handoff doc** straight to a file with the Write tool — do NOT
   run `mktemp` first. Pre-creating the file makes the Write tool demand a
   redundant Read of the empty file, and a guaranteed-unique name isn't needed
   (overwriting a spent handoff is harmless). `/var/tmp/claude-scratch/`
   always exists: `install.sh` creates it via `ensure-scratch-dirs.sh`, and
   that same script, wired as a `UserPromptSubmit` hook (see
   docs/permissions.md), recreates it on every prompt if anything ever
   removed it. Just Write to a descriptive path like
   `/var/tmp/claude-scratch/claude-handoff-<slug>.md` in one step.

   Structure the handoff as:
   - **Goal** — what the overall effort is about
   - **What's Done** — completed work with enough detail to not re-do it
   - **In Progress** — anything still running (with commands to check status)
   - **Remaining Work** — concrete next steps in priority order, with
     commands, file paths, and enough context to act immediately
   - **Key References** — file paths, URLs, server names, credentials
     locations, and other facts the new session will need

   Be thorough — the new session has zero conversation context. Include
   specific file paths, line numbers, server names, branch names, and
   exact commands. If you discovered something non-obvious (a bug, a
   gotcha, a workaround), document it explicitly.

3. **If the user provided a topic**, emphasize that area in the
   "Remaining Work" section as the first priority.

4. **Launch the new session** as a split beside the current pane,
   **carrying the current session's model over** — a refresh must not
   silently change models (a Fable session forks to Fable, not to the
   CLI default). Read the model from the stash `statusline-stash.sh`
   writes (wiring it as your statusLine command is covered in
   docs/permissions.md), the same source `context-usage.sh` prints:
   ```bash
   model="$(jq -r .model "/tmp/claude-$(id -u)/context-nudge/ctx-$CLAUDE_CODE_SESSION_ID.json")"
   fork-task.sh --hsplit --relation continuation --ack --model "$model" . <handoff-file>
   ```
   `--ack` makes the new session's first act `fork-task-ack.sh <token>`,
   and fork-task.sh prints `Ack token: <token>`. Right after the launch,
   run `fork-task-ack.sh --wait <token>` as a background Bash command
   (`run_in_background: true`). It exits 0 once the child is past the
   trust prompt and running, or 3 after ten minutes without an ack. Step 6
   acts on it.
   Always use `--hsplit` (side by side, not `--split`, which stacks the new
   pane below) and `.` (current project) — this is a same-project
   session refresh, not a cross-project fork. Always pass
   `--relation continuation` too: the new session carries on this same job
   under a new session id, so the agent registry must record it as a
   continuation edge, not a delegation — that is what lets a status line
   reader walk back to this session's runs after the handoff.

   **Name the new session with `--purpose`.** Without it the session name
   defaults to the project directory basename, which is generic and breaks
   cross-session addressing. If the current session has a chain name with a
   numbered suffix (`orch-5`, `builder-2`), bump the number
   (`--purpose orch-6`); otherwise pick a short slug and start one.

   If the user asked for a specific model (fable, opus, sonnet, or a full
   model ID), use that instead of the stashed one:
   ```bash
   fork-task.sh --hsplit --relation continuation --ack --model sonnet . <handoff-file>
   ```
   Only if the stash file is missing (the status line never ran) and the
   user named no model, omit `--model` and say so in the launch report.

   **Orchestrator-lane continuations start in Auto mode.** When the
   session being refreshed is a long-horizon orchestrator (sandbox-coder-
   mode on, or a numbered chain name like `frontend-14`), add
   `--permission-mode auto` to the fork-task.sh call. The current
   permission mode is not programmatically readable, so this is a
   convention, not detection — pass it for orchestrator lanes, omit it
   otherwise unless the user asks.

   **Carry the lane-mail registration.** Lane registration is per
   session id, so a continuation starts unregistered and its unread-mail
   hooks stay silent. If `lane-mail.sh registration` prints a lane,
   put three lines in the handoff's entry protocol: run
   `lane-mail.sh register <lane>` on entry, process
   `lane-mail.sh inbox <lane>`, and run `lane-mail-watch.sh <lane> --wait`
   as a background Bash command (`run_in_background: true`) so mail wakes
   the session once when it lands — a Monitor would wake it on a timer
   even with nothing to read. After processing what it wakes for, mark
   the mail `seen`, then relaunch the same background command. Then,
   AFTER launching the continuation, run `lane-mail.sh unregister` in
   THIS session: an outgoing session still registered gets stop-blocked
   on -- and may mark seen, i.e. steal -- mail that belongs to its
   successor.

5. **Confirm** to the user that the handoff is ready and the new session
   is running in the split beside this one.

6. **Retire this pane once the child is up.** Background Bash commands
   (`run_in_background`), port-forwards, drivers and watchers this
   session started are its child processes: closing the pane kills them
   mid-run. List them (your own background task IDs, plus
   `ps -o pid,etime,args --ppid` on any PIDs you know of). The
   lane-mail watcher and the ack wait are the exceptions.
   - If there are any, name them in the handoff's In Progress section as
     owned by the old session. Have the continuation adopt whatever it
     can relaunch cleanly. Keep watching the rest here, and make the
     **last line** of your final message, on its own, exactly:

     **Don't close this session until its ongoing tasks complete. I'll
     tell you when it's safe to close.**

   Then act on the ack wait:
   - **Exit 3 (no ack):** tell the user the new session may be stuck at
     a prompt (folder trust, a permission request), name its pane, and
     stay where you are.
   - **Exit 0, and nothing here is left for the user:** no result you
     have not reported, no question awaiting their answer, no task you
     own still running. Say in one line that this pane is retiring, then
     run `tmux-reap.sh`. It moves this pane into the tmux session
     `reaped`; a later reap closes it with SIGTERM once it is 24 hours
     old, and the transcript is kept. To keep a pane, move its window
     out of `reaped` before then.
   - **Exit 0, but something remains:** stay. When the last of it is
     done and reported, run `tmux-reap.sh` then.
