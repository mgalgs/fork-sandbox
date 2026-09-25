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

4. **Launch the new session** as a split in the current window,
   **carrying the current session's model over** — a refresh must not
   silently change models (a Fable session forks to Fable, not to the
   CLI default). Read the model from the status-line stash, the same
   source `context-usage.sh` prints:
   ```bash
   model="$(jq -r .model "/tmp/claude-$(id -u)/context-nudge/ctx-$CLAUDE_CODE_SESSION_ID.json")"
   fork-task.sh --split --model "$model" . <handoff-file>
   ```
   Always use `--split` and `.` (current project) — this is a same-project
   session refresh, not a cross-project fork.

   **Name the new session with `--purpose`.** Without it the session name
   defaults to the project directory basename, which is generic and breaks
   cross-session addressing. If the current session has a chain name with a
   numbered suffix (`orch-5`, `builder-2`), bump the number
   (`--purpose orch-6`); otherwise pick a short slug and start one.

   If the user asked for a specific model (fable, opus, sonnet, or a full
   model ID), use that instead of the stashed one:
   ```bash
   fork-task.sh --split --model sonnet . <handoff-file>
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
   `lane-mail.sh inbox <lane>`, and arm the lane watch so mail wakes
   the session (`Monitor({command: "lane-mail-watch.sh <lane>",
   persistent: true})`). Then, AFTER launching the continuation, run
   `lane-mail.sh unregister` in THIS session: an outgoing session
   still registered gets stop-blocked on -- and may mark seen, i.e.
   steal -- mail that belongs to its successor.

5. **Confirm** to the user that the handoff is ready and the new session
   is running in the split below.
