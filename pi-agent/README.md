# `pi-agent/`: the sandboxed pi configuration

This directory is pi's configuration for **sandboxed runs only**. Every
`agent-sandboxed` run copies it to a per-run staging directory, and the shim
inside the sandbox copies that into the ephemeral `$HOME` as `~/.pi/agent`.

Two consequences follow from the copy:

- **Nothing written inside a run persists.** pi rewrites `settings.json` when
  you change a setting from the TUI, and would write `auth.json` on `/login`.
  Those land in a tmpfs and die with the sandbox.
- **This directory cannot be corrupted by a run.** The master copy is never
  mounted, so no session can reach it.

Your personal, interactive pi configuration lives in `~/.pi/agent` and is
**never** mounted into a sandbox. That is deliberate: it is a git checkout of
its own, it holds `auth.json`, and its extensions expect a machine that a
sealed sandbox is not.

## What is generated per run, and will overwrite what is here

- `models.json` — written fresh every run. It registers the `local` provider
  pointing at the loopback address the socket bridge listens on, with the
  model and context window discovered from the endpoint. Do not commit a
  `models.json` here; it would be replaced.
- The `defaultProvider` and `defaultModel` keys of `settings.json` — merged
  over whatever this directory provides, because only the run knows which
  model the endpoint serves.

Everything else in `settings.json` is yours and survives the merge.

## What to grow here

Anything a sandboxed pi session should always have:

- `settings.json` — theme, compaction, `defaultThinkingLevel` once experience
  says what it should be. There is deliberately no thinking default today:
  `--thinking <level>` passes through from the command line, and Shift+Tab
  cycles it live in the TUI. Set it here when a winner is clear.
- `extensions/` — TypeScript extensions pi discovers on startup.
- `skills/` — skills for sealed work.

Remember what a sealed sandbox cannot do: there is no network, so an extension
that fetches anything will fail. Nothing here may assume the host's scripts,
hooks or `~/.claude` exist either.
