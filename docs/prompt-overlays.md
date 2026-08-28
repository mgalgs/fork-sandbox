# Prompt overlays: model-specific corrections, machine-local

`fork-sandbox.sh` renders one prompt per run: a preamble describing the
sandbox, the services block when a repo has them, and the operator's
handoff. Every model reads the same text. That is right for most of it — the
sandbox does not change per model — but some corrections are genuinely
model-specific, and pasting them into the shared preamble either wastes
tokens on a model that never needed them or, worse, becomes a correction one
model needs and every other model has to read anyway.

The prompt overlay is a fourth block: a machine-local directory of markdown
fragments, selected by harness and model, appended after the generated
environment blocks and immediately before the handoff. This repo ships the
mechanism only. No fragment for any model lives here — the same call the
repo already makes for its Dockerfile-not-image, manifests-not-cluster
pieces. What a model needs corrected is something you observe by running it,
not something this repo can know in advance.

## What this is for

A concrete example, observed rather than invented: a local model, driven
through `--harness pi-local`, was asked to commit its work. It wrote

```
git commit -m "ran the tests: `pytest -q` all green, pushing now: `git push`"
```

Inside a **double**-quoted string, backticks are not inert — the shell
command-substitutes them. One backticked span ran the whole test suite and
spliced its output into the commit message; the other attempted a push (which
failed harmlessly here, since the sandbox has no credential, but would not be
harmless on a harness that does). The fix is a one-line instruction: use a
quoted heredoc, so nothing inside is re-interpreted —

```
git commit -m "$(cat <<'EOF'
ran the tests: pytest -q all green
EOF
)"
```

That instruction is worth exactly nothing to a stronger model, which already
avoids unquoted backticks in a shell string without being told. Put it in the
shared preamble and every run of every model pays for it in tokens, forever.
Put it in a fragment under `model/`, and only the model that needs it ever
sees it — and the run record says whether that fragment was even present, so
a later change to it is visible as a change in results rather than a mystery.

## Where the fragments live

Default: `~/.config/fork-sandbox/prompts`, alongside this project's other
per-machine config (`aliases.conf`, `pi.env`). Overridable, like the rest of
that config, via `FORK_SANDBOX_CONFIG_DIR`, and specifically via
`FORK_SANDBOX_PROMPTS_DIR` when only the prompts should move.

**Absent by default is the normal case, not an error.** Most machines have no
such directory, and a run on one of them is completely unaffected: no
warning, no empty section in the prompt, no difference from a run made
before this mechanism existed.

## Search order

Three files, general first so a later one can override what an earlier one
said:

```
<prompts-dir>/all.md
<prompts-dir>/harness/<harness>.md
<prompts-dir>/model/<model>.md
```

`<harness>` is one of `claude`, `pi`, `pi-local`, `codex`. Any file that does
not exist is skipped silently — a directory holding only `all.md` is a
perfectly normal setup. The ones that do exist are concatenated, in that
order, under one heading, into the rendered prompt.

There is no glob or family matching (`qwen*.md` for a whole model family is
tempting, but the override order gets fiddly fast, and this project prefers
predictable over clever). That is a deliberate deferral, not an oversight —
if fragments need to be shared across a model family, make the prompts
directory a git repo and symlink the family's file names to one shared
fragment. Machine-local means you can do that however you like; this
mechanism only reads what results.

## The model file name

A model id commonly holds a slash — `openai/gpt-4o`,
`deepseek/deepseek-v4-flash` — and a slash is a path separator, not a
character a file name may safely carry unexamined. Every `/` in the model id
is replaced with `_` before it is used as a file name:
`openai/gpt-4o` → `model/openai_gpt-4o.md`. This is also what keeps a model id
from being used to escape the directory: with every `/` gone, the sanitized
name is always a single path component, never a `..` climb or an absolute
path.

## Applying one fragment set to one run: `--prompts-dir`

```
fork-sandbox.sh --prompts-dir ~/experiments/prompts-v2 --harness pi-local \
    --model qwen3.5-9b ~/src/myrepo /var/tmp/claude-scratch/handoff.md
```

This is what makes a sweep possible: point successive runs at different
directories, or different worktrees of the same prompts repo, and compare
outcomes with `sandbox-run-log.py stats --by prompt_overlay.rev` (below).

**Naming a directory that does not exist is an error, not silence.** The
default directory being absent is fine — nobody asked for anything. Naming
one explicitly and having it silently do nothing is the failure class this
project keeps paying to avoid: a results database that looks like it used an
overlay, and did not, is worse than one that visibly refused to run.

A directory that exists but matches no fragment (right harness, wrong model,
say) is not an error, but it is a warning naming every path that was looked
for — the caller asked for something, and got nothing, and should know
that before spending the run.

## `--dry-run` shows what a run would get

`--dry-run` already resolves and prints the harness and model without
creating anything. It also prints the resolved prompts directory, the
fragments that would apply, and their rev — so `--prompts-dir` can be
checked before it is spent on a real run.

## Provenance: what the run record carries

A prompt is part of what produced a result, so a change to one has to be
attributable the same way a code change is. When an overlay applies,
`fork-sandbox.sh` writes `<run-dir>/prompt-overlay.json`, and
`sandbox-run-log.py record` folds it into the run's log entry under
`prompt_overlay`:

```json
"prompt_overlay": {
  "dir": "/home/you/.config/fork-sandbox/prompts",
  "rev": "abc1234-dirty",
  "fragments": ["all.md", "model/qwen3.5-9b.md"],
  "sha256": "…"
}
```

- **`dir`** — the source directory this run read.
- **`fragments`** — the relative paths that matched, in composition order.
- **`sha256`** — a fingerprint of exactly the bytes concatenated into the
  prompt, independent of git state.
- **`rev`** — `git rev-parse HEAD` of the prompts directory, when it is a git
  repository. **If its working tree has uncommitted changes, the rev is
  suffixed `-dirty`.** This is the one rule that has to be right: a record
  that names a clean commit which did not actually produce the run's prompt
  is worse than a record with no rev at all, because it looks trustworthy
  when it is lying. The dirty check (`git status --porcelain`) is scoped to
  the prompts directory itself, not the whole repository it may live inside.
  When the directory is not a git repository at all, `rev` is `null` — the
  fragment list and the hash still work, and still identify exactly what ran.

No key is written at all when a run applied no overlay — the common case, and
the same shape a run made before this mechanism existed already had.

Query it like any other dimension `sandbox-run-log.py` groups on:

```
sandbox-run-log.py stats --by model,prompt_overlay.rev
```

## What is deliberately not here

- **No fragment content**, for any model. This document's worked example is
  prose, not a shipped file — copy the pattern, do not expect to find it
  under `model/`.
- **No glob or family matching** (see above).
- **No `--prompts-rev`** that checks out a revision for you. `--prompts-dir`
  plus a git worktree already covers a sweep; a convenience flag that
  mutates a checkout on your behalf can come later, deliberately, if it turns
  out to be worth the risk of doing that automatically.
