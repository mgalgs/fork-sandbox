---
name: fork-task
description: Fork a task to a Claude Code or Codex agent in another project directory, a split pane, or a new worktree. Writes a handoff doc, launches the selected agent in a new tmux window or pane. Use when work is needed in a dependent package or sibling project.
argument-hint: [--harness claude|codex] [--sol] [--split|--hsplit] [--worktree] [--shared] [--sandboxed] [--branch <name>] [--model <model>] [--purpose <slug>] [--claude-args "..."] [--codex-args "..."] <project-path> — path to the target project directory (omit or use "." for same-project handoff). Use --harness codex (or --agent codex) for an interactive Codex pane; `--sol` is shorthand for Codex with `gpt-5.6-sol`; Claude is the default. Use --split to open in a split pane below the current one, or --hsplit to open it beside (side by side) instead. Use --worktree to create an isolated worktree via the project's .claude/fork-worktree.sh hook. Use --shared for shared-db worktrees. Use --sandboxed to run the Claude fork in a throwaway clone inside claude-sandboxed, with no permission prompts; name its branch with --branch. Use --model to pick the model for the new session (fable, opus, sonnet, or a Codex model such as gpt-5.6-sol). Use --purpose to set a session name for cross-session messaging (defaults to the project basename). Use --claude-args or --codex-args to pass extra flags to the selected CLI. Codex uses its normal interactive sandbox and cannot be combined with --sandboxed.
---

# Fork Task

Launch a Claude Code or Codex session in a new tmux window (or split pane) with a handoff doc, either in another project or the current one.

## Modes

- **Cross-project fork:** `<project-path>` is a different directory. Use when work is needed in a dependent package or sibling project.
- **Codex fork:** pass `--harness codex` (or `--agent codex`). This launches the local interactive `codex` CLI in the tmux pane; its own sandbox remains enabled. Do not combine it with `--sandboxed`, which is the Claude sandbox mode. `--model` is passed as a Codex model ID, such as `gpt-5.6-sol`.
- **Same-project handoff:** `<project-path>` is omitted, `.`, or the current working directory. Use when the user wants to continue the current work in a fresh session (e.g., context is getting long, switching focus areas, or handing off in-progress work).
- **Worktree fork:** `--worktree` is specified. Creates an isolated worktree before launching. Requires `.claude/fork-worktree.sh` in the target project.
- **Sandboxed fork:** `--sandboxed` is specified. Clones the repo, runs the session in that clone inside `claude-sandboxed`, and fetches the branch back when it exits. The session never asks for permission. Use it for unattended work — a long build, a broad refactor, a test sweep. It cannot be combined with `--worktree`. See "Sandboxed forks" below.

## Deferred forks

A side idea fired off mid-task does not have to fork right away. When it
does not change the work in flight, acknowledge it in one sentence and
continue the current work. The acknowledgement keeps the idea in the
conversation, so nothing else records it. Save **all** fork work for the
break — no due diligence, no handoff doc, no branch name.

At the next natural break, fork it in earnest. Two things differ from an
immediate fork:

- Write the handoff doc from the user's **original words** — scroll back to
  the ask, not to your summary of it.
- Check whether later conversation changed or obsoleted the idea. If it did,
  say so instead of forking a stale version.

## Instructions

1. **Determine the target project and mode:**
   - If the argument is omitted, `.`, or matches the current working directory, this is a **same-project handoff**.
   - Otherwise, verify the target directory exists with `ls`.
   - For same-project handoffs, the target is the current working directory.

2. **If `--worktree` is requested:**
   - Generate a short kebab-case worktree name from the task description (2-4 words, max 40 chars).
   - Determine worktree-args from the user's flags:
     - `--shared` → `--worktree-args "--shared-db"` (shared database, faster creation)
     - Other project-specific flags can be passed via `--worktree-args "..."` directly.
   - The project-path should be the **main repo root** (so the `.claude/fork-worktree.sh` hook can be found).

3. **Gather context and write the handoff doc:**
   - Ask the user what needs to be done (if not already clear from conversation).
   - Write a handoff markdown file to a temp file (`mktemp /var/tmp/claude-scratch/claude-handoff-XXXXXX.md`).
   - The handoff doc should include:
     - **Goal:** What needs to be accomplished
     - **Context:** Why this change is needed, what the upstream/caller project expects
     - **Current state:** What has already been done, what's working, what's not yet working
     - **Details:** Specific files, APIs, interfaces, or contracts involved
     - **Remaining work:** Concrete next steps for the receiving agent
     - **Acceptance criteria:** How to know the task is done (e.g., tests pass, specific export exists)
   - Be thorough — the receiving agent has no conversation context from this session.
   - For same-project handoffs, emphasize **Current state** and **Remaining work** — the new session needs to know exactly where things left off, including any debugging observations or hypotheses.

4. **Launch Claude in tmux:**
   - The `fork-task.sh` script handles all tmux logic
     (sandboxed detection, split vs window, pane targeting, worktree creation).

   **Choosing window vs split:** If the user says "in this window", "here",
   "in this pane", "split", or similar — use `--split`, which stacks the new
   pane below. When they ask for it beside the current pane ("next to this",
   "side by side", "left/right"), use `--hsplit` instead. Only create a new
   window when the user explicitly asks for a separate/new window or doesn't
   express any preference about where the fork should land.

   **Basic usage:**
   ```bash
   fork-task.sh "<project-path>" "<handoff-file>"
   ```

   **Split pane (default when user asks to fork "here" or "in this window"):**
   ```bash
   fork-task.sh --split "<project-path>" "<handoff-file>"
   fork-task.sh --hsplit "<project-path>" "<handoff-file>"  # beside, not below
   ```

   **With worktree creation:**
   ```bash
   # Isolated worktree (own database copy, etc.)
   fork-task.sh --worktree "<name>" "<project-path>" "<handoff-file>"

   # Shared-db worktree (faster, no DB copy)
   fork-task.sh --worktree "<name>" --worktree-args "--shared-db" "<project-path>" "<handoff-file>"
   ```

   **With a specific model (fable, opus, sonnet, or a full model ID):**
   ```bash
   fork-task.sh --model sonnet "<project-path>" "<handoff-file>"
   fork-task.sh --split --model fable "<project-path>" "<handoff-file>"
   ```
   Only pass `--model` when the user asks for a specific model; otherwise
   let the new session use its default.

   **Codex interactive pane:**
   ```bash
   fork-task.sh --harness codex --split --model gpt-5.6-sol "<project-path>" "<handoff-file>"
   fork-task.sh --sol --split "<project-path>" "<handoff-file>"
   ```
   `--agent codex` is accepted as an alias for `--harness codex`. Use
   `--codex-args` for additional Codex CLI flags. The Codex sandbox remains
   enabled; use `fork-sandbox.sh --harness codex` for an unattended run.

   **With a purpose (sets the session name for cross-session messaging):**
   ```bash
   fork-task.sh --purpose "fix-auth" "<project-path>" "<handoff-file>"
   fork-task.sh --split --purpose "refactor-db" "<project-path>" "<handoff-file>"
   ```
   Pass `--purpose` when the default (project basename) is not
   distinctive enough — for example, when two forks target the same
   project.

   **With extra claude CLI args (e.g., `--chrome`):**
   ```bash
   fork-task.sh --claude-args "--chrome" "<project-path>" "<handoff-file>"
   ```

   **Sandboxed (no permission prompts):**
   ```bash
   fork-task.sh --sandboxed --branch "<branch-name>" "<project-path>" "<handoff-file>"
   ```
   Generate a short kebab-case branch name from the task, the same way you
   would a worktree name. Pass extra flags to the sandbox itself with
   `--sandbox-args`; the common one is `--unpin-egress`, needed only when the
   task must reach the tailnet, a VPN, or a libvirt/docker bridge:
   ```bash
   fork-task.sh --sandboxed --branch "<name>" --sandbox-args "--unpin-egress" "<project-path>" "<handoff-file>"
   ```

   The script reads `$TMUX_PANE` automatically for split targeting.

5. **Report back:**
   - Tell the user the window name, handoff file path, and session name
     (printed by `fork-task.sh`). Save the session name — it is the
     address for `SendMessage`.
   - For new windows, offer to switch: `tmux select-window -t '<name>'`
   - For split panes, the pane is already visible — just confirm it's running.

6. **The handoff doc stays live — keep the path and session name.**
   The forked session is told where its doc is, so a correction after
   launch costs one line instead of a re-explanation. `fork-task.sh`
   prints the session name at launch — save it for messaging later.

   When the doc needs a correction, **edit the handoff file** and use
   `SendMessage` to tell the fork: "The handoff doc has been updated.
   Read it again at <path>." Do not paste the correction as a fresh
   instruction and leave the doc stale: the doc is what the session
   re-reads when it loses context, and a stale one is worse than none.

   If you lost the session name, run `ListAgents` and match the fork
   by its pane ID from the agent registry — query it with
   `agent-registry.sh` if it's on PATH, or read
   `/var/tmp/claude-scratch/agent-registry.jsonl` directly otherwise. The
   pane ID appears in the listing's tmux field. Never select a session
   by name similarity — always match by pane ID.

   **Never use `tmux send-keys` to type into another session.** Window
   names change; typing into the wrong pane is destructive.

   Not available for `--sandboxed` forks. Nothing of the host is mounted
   there, so the session cannot re-read the path and is not given one —
   a sandboxed doc has to be right when it is written.

## Sandboxed forks

`--sandboxed` runs the session through `claude-sandboxed` with
`--dangerously-skip-permissions`. The sandbox is the boundary, so the prompt
is not needed. The window is named `cc-sbx-<branch>`.

**It does not run in the user's checkout.** `fork-task.sh` makes a throwaway
`git clone --shared` under `/var/tmp/claude-scratch/forks`, checks out
`--branch`, and mounts only
that clone writable. When the session exits, the pane fetches the branch back
into the real repo and drops to a shell there.

This is the security design, not a convenience. A writable git directory is
host code execution: a hook, or a config key such as `core.fsmonitor`, runs
on the **host** the next time anyone uses git in that repo — outside the
sandbox, with the ssh keys and the tailnet. Because nothing writable of the
user's is ever mounted, there is no hook to plant. The work returns by `git
fetch`, which git deliberately does not let a fetched-from repository use to
run commands.

The clone reads history through `objects/info/alternates`, bound read-only,
so it stays cheap on a large repo and the real object store cannot be
corrupted.

**What the sandboxed session gives up.** Say this to the user when you launch
one:

- **Committed state only.** No uncommitted changes, no `.env`, nothing
  untracked, and no project setup a `.claude/fork-worktree.sh` hook would
  have done. `--worktree` and `--sandboxed` are mutually exclusive.
  Exception for node projects: the origin's `node_modules` is copied into
  the clone, and the `.nvmrc` node version is bound in read-only, first on
  PATH — npm and the project's own suites work.
- **No global `~/.claude`.** No global CLAUDE.md, skills, scripts, settings
  or hooks. A project `.claude/` is committed, so it comes with the clone.
- **No secrets.** No ssh keys, no ssh agent, no API tokens, no environment
  variables. It commits; it cannot push, and cannot reach Forgejo, GitHub or
  Slack.
- **No tailnet and no VPN.** The internet and the local LAN stay reachable.
- **No tmux.** It cannot split panes or fork further tasks.

**The handoff doc must tell the session to commit.** Uncommitted work has
nothing to fetch back. Write the doc so it stands on its own — there is no
global config to fall back on.

**Review before building.** The sandbox contains the session while it runs.
It does not make the code it wrote safe. The fetched branch is agent-written
code, and a `Makefile`, `package.json` script or `.envrc` in it runs on the
host the moment you build. Read the diff first, exactly as you would a pull
request from a stranger.

The clone is left behind at the path the script prints. Delete it when done.

## fork-worktree.sh hook contract

Projects that support `--worktree` must provide `.claude/fork-worktree.sh` (executable).

**Interface:**
```
.claude/fork-worktree.sh <name> [extra-args...]
```

**Behavior:**
- Creates an isolated worktree named `<name>`
- Prints the absolute worktree path to **stdout** (single line)
- Status messages go to **stderr**
- Exits 0 on success, non-zero on failure
- Extra args are project-specific (e.g., `--shared-db`)

**Writing one for a new project:** start from
`~/.claude/skills/fork-task/templates/fork-worktree.sh`. Copy it to
`<project>/.claude/fork-worktree.sh`, `chmod +x`, and adapt the two sections
marked `PROJECT-SPECIFIC`. It runs correctly unchanged on a repo with no
dependency directory. Do not write one from scratch — the template already
handles the traps below, each of which has bitten a real project here:

| Trap | What the template does |
|---|---|
| An unredirected `git worktree add` or `cp -v` corrupts the return value, because stdout *is* the contract. | Redirects every status line to stderr; the path is the last thing printed. |
| A worktree gets tracked files only, so `.claude/settings.local.json` does not come along and the worktree session prompts for what the parent allows. | Copies a `carry` list, skipping anything git already placed. Add project-ignored files (`.env`) to that list. |
| Claude Code prompts for any path outside the session's working directory even when the command is allowlisted, so the *parent* session prompts on worktree files. | Warns when the worktree root is missing from the parent's `additionalDirectories`, and prints the line to paste. |
| A worktree created inside the repo gets swept up by test globs and bundlers. | Puts worktrees in a sibling `<repo>-worktrees/` directory. |
| Branching from `main` silently drops unmerged work that is checked out right now. | Branches from current `HEAD`. |
| No `node_modules`/`.venv`, so the first build in the worktree fails. | `PROJECT-SPECIFIC` section with symlink / copy / clean-install spelled out. |
