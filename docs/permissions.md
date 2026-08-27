# Approving these commands without a prompt

Three of the scripts here are meant to run without a permission prompt, because
prompting on them defeats the point: an orchestrating session that has to stop
and ask before it can *check on* a run it already launched is not unattended.

This document says which three, and what makes each one safe to hand a blanket
approval to. Read it before you add the rules — a blanket approval is permanent
and unsupervised, so the script itself is the security boundary, and you should
agree with its reasoning rather than take it on faith.

## The rules

For Claude Code, in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(fork-sandbox.sh:*)",
      "Bash(fork-sandbox-status.sh:*)",
      "Bash(fork-sandbox-say.sh:*)"
    ],
    "additionalDirectories": ["/var/tmp/claude-scratch/"]
  }
}
```

Permission rules match on the literal command text, so if you also invoke a
script by an absolute path, that spelling needs its own rule. The
`additionalDirectories` entry is what lets a session write a handoff file
without prompting; without it the write prompts even though the launch does not.

Nothing else here should be blanket-approved. In particular `claude-sandboxed`,
`agent-sandboxed` and `sandbox-backend-bwrap` take `--bind-ro` and `--bind-rw`,
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
  repository under your source root.
- **Sandbox arguments** are not passed through. The script adds every bind the
  run needs; a caller cannot ask it to mount `~/.ssh`.

## The part no rule can give you

Everything above is about not being interrupted. It is not a claim that the
agent inside the sandbox is trustworthy — the sandbox is what handles that, and
what it does and does not contain is documented in
[claude-sandboxed.md](claude-sandboxed.md). Read that too, especially the
residual-risk section, before pointing an unattended agent at anything you care
about.
