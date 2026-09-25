# Approving these commands without a prompt

Several of the scripts here are meant to run without a permission prompt,
because prompting on them defeats the point: an orchestrating session that has
to stop and ask before it can *check on* a run it already launched, or before
it can read lane-mail it was just handed, is not unattended. A few hooks
belong in the same bucket for the same reason — a hook fires on every prompt
or every stop, so a permission dialog there would not be a checkpoint, it
would be constant noise.

This document says which scripts and hooks, and what makes each one safe to
hand a blanket approval to. Read it before you add the rules — a blanket
approval is permanent and unsupervised, so the script itself is the security
boundary, and you should agree with its reasoning rather than take it on faith.

## The rules

For Claude Code, in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(fork-sandbox.sh:*)",
      "Bash(fork-sandbox-status.sh:*)",
      "Bash(fork-sandbox-say.sh:*)",
      "Bash(fork-sandbox run:*)",
      "Bash(fork-sandbox status:*)",
      "Bash(fork-sandbox say:*)"
    ],
    "additionalDirectories": ["/var/tmp/claude-scratch/"]
  }
}
```

The last three are the same three programs reached through the `fork-sandbox`
dispatcher, so they grant nothing the first three do not. Approve them
**per verb**, never as a bare `Bash(fork-sandbox:*)`: rules are literal
prefix matches, so that one string would also match every `fork-sandbox-*`
name on your PATH — including plumbing nobody meant to approve, like the
pod-side k8s scripts and the `fork-sandbox-discover-*` executables, and
including any such script added in a later release.

Permission rules match on the literal command text, so if you also invoke a
script by an absolute path, that spelling needs its own rule. The
`additionalDirectories` entry is what lets a session write a handoff file
without prompting; without it the write prompts even though the launch does not.

Nothing else in this section should be blanket-approved (the lane-mail rules
further down are the only other exception, argued separately). In particular
`claude-sandboxed`, `agent-sandboxed` and `sandbox-backend-bwrap` take
`--bind-ro` and `--bind-rw`,
which mount arbitrary host paths into the sandbox — approving those hands over
exactly the power the sandbox exists to withhold. The backend is the sharpest
of those three, because it is the one that actually performs the mount and it
takes `--bind-rw-at` as well, so a rule for it would hand that power over for
every client at once.

## Why each one is safe

**`fork-sandbox-status.sh` — read-only.** It reads a run directory and prints
what it finds. It runs no git, mutates nothing, and refuses any path that is not
under the run-dir prefix. The worst outcome of a bad argument is an error.

**`fork-sandbox-say.sh` — bounded write.** It writes one file into
`<run-dir>/inbox`, under a name it generates itself (`<epoch>-<nn>.md`). The
name is never taken from an argument, which is what keeps it from being an
arbitrary-file-write primitive; the run directory is resolved and then required
to sit under the run-dir prefix and to contain a `run.env`; a symlinked inbox is
refused, so the write cannot be redirected. The authority it grants is not new
either — the session that launched the run already authored the entire handoff.

**`fork-sandbox.sh` — constrained launch.** This one starts a sandboxed agent,
so it is the one that needs the argument. Three of its inputs would otherwise be
dangerous primitives, and each is constrained:

- The **handoff** is read into the prompt of a model with network access, so an
  unconstrained path would be arbitrary-file-read plus exfiltration. Handoffs
  must live under the scratch root, where sessions stage them deliberately.
- The **project** is cloned into the sandbox — the same channel. It must be a
  repository under one of the configured project roots (`PROJECT_ROOTS` in
  `~/.config/fork-sandbox/projects.env`, defaulting to `~/src`). Editing that
  file widens what an approved call can hand to a sandbox, so treat it with
  the same care as the allowlist itself.
- **Sandbox arguments** are not passed through. The script adds every bind the
  run needs; a caller cannot ask it to mount `~/.ssh`.

## lane-mail and lane-mail-watch

Two more scripts are safe to blanket-approve, though the argument for
`lane-mail.sh` is not quite the one above: it fixes *where it writes*, not
what it reads. See below.

```json
{
  "permissions": {
    "allow": [
      "Bash(lane-mail.sh:*)",
      "Bash(~/.claude/scripts/lane-mail.sh:*)",
      "Bash(/home/<you>/.claude/scripts/lane-mail.sh:*)",
      "Bash(lane-mail-watch.sh:*)",
      "Bash(~/.claude/scripts/lane-mail-watch.sh:*)",
      "Bash(/home/<you>/.claude/scripts/lane-mail-watch.sh:*)"
    ]
  }
}
```

Replace `<you>` with your own username. All three spellings are listed
because permission rules match on literal command text: a hook, a tmux key
binding, or a shell alias can invoke either script by its bare name, by
`~/.claude/...`, or by the fully expanded `$HOME`-based path, and each
spelling needs its own rule.

**`lane-mail.sh` — fixed root, no root argument.** Its mail root
(`/var/tmp/claude-scratch/lane-mail`) is a constant in the script, never a
parameter, so no caller can point `send`, `reply`, `inbox`, `seen` or any
other subcommand at a different store — the same separation that keeps this
root from colliding with the unrelated fleet mail store. `register` and
`unregister` only ever write the calling session's own
`/tmp/claude-$UID/lane-mail-lanes/<session-id>` file, named from
`$CLAUDE_CODE_SESSION_ID`, so one session cannot touch another's registration.

That fixed root bounds where this writes, not what it reads. `send` and
`reply` pass `"$@"` straight through to `fork-sandbox-mail.sh`, whose
`--body <file>` and `--attach <file>` read any path the caller can already
read, and whose k8s grant flags (`--allow-namespace`, `--context-ro`,
`--context-secret`) ride along on `send` too. So approving this script
approves that whole surface, not just the fixed store. It is still a
reasonable blanket approval — the session already has the read access and
grant authority these flags exercise some other way, the files this script
writes are 0600 via `mktemp`, and no networked sandbox or postmaster reads
from this root — but that is a weaker, different claim than "cannot pick a
path outside what the script fixes," and it is the one you are actually
approving.

**`lane-mail-watch.sh` — read-only.** It only ever calls `lane-mail.sh inbox
<lane>` in a loop and prints what comes back. It mutates nothing. Its
`--wait` mode is the same read-only loop with a different exit condition —
it blocks until that call returns something, then exits — so the same
approval covers it.

## context-usage.sh

One more script is safe to blanket-approve, for the same shape of reason as
`lane-mail-watch.sh`: it only ever reads.

```json
{
  "permissions": {
    "allow": [
      "Bash(context-usage.sh:*)",
      "Bash(~/.claude/scripts/context-usage.sh:*)",
      "Bash(/home/<you>/.claude/scripts/context-usage.sh:*)"
    ]
  }
}
```

Replace `<you>` with your own username, for the same reason as above: a
rule matches literal command text, and this script gets invoked by all
three spellings.

**`context-usage.sh` — read-only, and bounded to your own reading.** It
only ever reads one file under your own `/tmp/claude-$UID/context-nudge/`
— the stash `statusline-stash.sh` writes for the session id it is given —
and prints what it finds. A session id is either its own
(`CLAUDE_CODE_SESSION_ID`) or one passed explicitly, but every session's
stash lives under that same uid-scoped directory, so this can never read
another user's data, and it mutates nothing.

## Hooks: lane-mail, the scratch root, and context-nudge

Four hook commands are meant to run on every prompt or stop, for
`lane-mail.sh`, `ensure-scratch-dirs.sh` and `context-nudge.py`. In
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "lane-mail-hook.sh prompt" },
          { "type": "command", "command": "ensure-scratch-dirs.sh" },
          { "type": "command", "command": "context-nudge.py" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "lane-mail-hook.sh stop" }
        ]
      }
    ]
  }
}
```

**`lane-mail-hook.sh prompt`** reads the registered lane for the calling
session and, if it has unread mail, injects a banner of message count plus
one line per subject — deliberately never bodies, so a full inbox cannot
flood the new turn's context. A session that never ran `lane-mail.sh register
<lane>` costs this hook one file stat and nothing else.

**`lane-mail-hook.sh stop`** blocks the stop (`decision: block`) while the
registered session has unread mail, so it processes its inbox before going
idle — the interactive analog of a fleet wake. It checks `stop_hook_active`
before blocking, so it never fires twice on the same stop and cannot loop.

**`ensure-scratch-dirs.sh`** recreates `/var/tmp/claude-scratch` (and the
`/tmp/claude-scratch` compat symlink) on every prompt. `install.sh` already
runs it once at install time; the hook is what keeps that guarantee true
after a reboot empties `/tmp`, or after anything else removes the symlink.

**`context-nudge.py`** reads the session's stashed context-window reading
(written by `statusline-stash.sh`) and, at 35%, 80% and 90% usage, injects
a short system nudge telling the model to run `/freshly-forked` at the
next natural break. It is rate-limited to once per session per step — a
later climb past the same step stays silent until usage drops back under
30%, which re-arms every step — and it swallows any internal error rather
than surfacing it, since a hook must never break prompt submission.

## statusLine: the context-window stash writer

Claude Code runs exactly one `statusLine` command, and hands it the only
copy of the true context-window size and the model's `[1m]` suffix that
exists outside Claude Code itself. `statusline-stash.sh` stashes those
numbers per session and then runs your own display command, passing it the
exact stdin bytes it received — so wiring it in is not a permission rule
(there is nothing to approve; it runs as your statusLine, not as a tool
call invocation), just a `settings.json` entry:

```json
{
  "statusLine": {
    "type": "command",
    "command": "statusline-stash.sh"
  }
}
```

Or, wrapping your own display script instead of getting the bare one-line
default `statusline-stash.sh` prints on its own:

```json
{
  "statusLine": {
    "type": "command",
    "command": "statusline-stash.sh ~/.claude/scripts/my-status-line.sh"
  }
}
```

There is exactly one `statusLine` slot, which is why the stash writer
wraps a display command instead of replacing it outright — if your own
script already renders colours, cost or cwd, `statusline-stash.sh` is the
only way to keep that and still have the stash written. `context-usage.sh`,
`context-nudge.py` and `/freshly-forked`'s model carry-over step all depend
on `statusline-stash.sh` actually running as the `statusLine` command; if
it never runs, no stash file ever exists, and each falls back to (or
fails with) whatever they document for that case.

## `fork-task.sh` is not on this list

`fork-task.sh` launches an unsandboxed, interactive agent session — the
opposite of the bounded, read-or-write-one-thing scripts above. A prompt on
each launch is the intended checkpoint, not friction to engineer around:
unlike checking on a run that is already sandboxed and already committed to
a branch, starting a brand-new session with its own fresh set of permissions
is exactly the moment a human should look at what is about to run.

## The part no rule can give you

Everything above is about not being interrupted. It is not a claim that the
agent inside the sandbox is trustworthy — the sandbox is what handles that, and
what it does and does not contain is documented in
[claude-sandboxed.md](claude-sandboxed.md). Read that too, especially the
residual-risk section, before pointing an unattended agent at anything you care
about.
