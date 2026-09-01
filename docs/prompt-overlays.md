# Prompt overlays: model-specific corrections, machine-local

`fork-sandbox.sh` renders up to four prompts per run: the implement prompt
(`handoff.md`), always, and — under `--review-loop` — a review prompt and a
fix prompt, one pair per review-then-fix iteration's shared template, and —
under `--maintainer-loop` — a maintainer prompt (whose fix legs reuse the
fix template). Each starts with the same preamble describing the sandbox,
the services block when a repo has them, and that leg's own task text (the
operator's handoff for implement, "review this branch" for review, "fix
what a reviewer found" for fix, "review this branch the way a maintainer
would" for maintainer). Every model reads the same text for a given leg. That is right for
most of it — the sandbox does not change per model — but some corrections
are genuinely model-specific, and pasting them into the shared preamble
either wastes tokens on a model that never needed them or, worse, becomes a
correction one model needs and every other model has to read anyway.

The prompt overlay is a fourth block: a machine-local directory of markdown
fragments, selected by leg, harness and model, appended after the generated
environment blocks and immediately before that leg's task text. This repo
ships the mechanism only. No fragment for any model lives here — the same
call the repo already makes for its Dockerfile-not-image,
manifests-not-cluster pieces. What a model needs corrected is something you
observe by running it, not something this repo can know in advance.

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

That example happened during the implement leg, but the implement leg is not
the only one that commits. Under `--review-loop`, the fix leg's own prompt
says "Fix the real ones, and commit" — it is the leg that turns a reviewer's
findings into a committed change, so a commit-safety correction is exactly
as relevant there as it is in the implement leg, and arguably more urgent:
it is the leg most runs actually reach last. A fragment under `model/` alone
cannot land there and nowhere else — it reaches every leg or none. The
per-leg layer below (`fix/model/<model>.md`) is what makes "this model needs
correcting, and only when it is about to commit" expressible at all.

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

Five files, general first so a later one can override what an earlier one
said:

```
<prompts-dir>/all.md
<prompts-dir>/harness/<harness>.md
<prompts-dir>/model/<model>.md
<prompts-dir>/<leg>/all.md
<prompts-dir>/<leg>/model/<model>.md
```

`<harness>` is one of `claude`, `pi`, `pi-local`, `codex`. `<leg>` is exactly
one of `implement`, `review`, `fix`, `maintainer` — the prompt currently
being rendered.
Any file that does not exist is skipped silently — a directory holding only
`all.md` is a perfectly normal setup. The ones that do exist are
concatenated, in that order, under one heading, into the rendered prompt.

The first three are the same three this mechanism always had, and they still
mean what they meant: every leg reads them. A fragment saying how a model
should write a commit is as true in the fix leg as in the implement leg, so
`all.md`, `harness/<harness>.md` and `model/<model>.md` apply everywhere,
unchanged, and an existing prompts directory keeps working exactly as it did
before this layer existed — it now simply applies to every leg instead of
one. The last two narrow that baseline to one leg: `<leg>/all.md` for every
model in this leg, `<leg>/model/<model>.md` for this model in this leg
alone, general first within the leg-scoped pair too. A `maintainer/`
directory is how you correct the maintainer leg's prompt specifically — the
leg that runs only under `--maintainer-loop`.

`implement`, `review`, `fix` and `maintainer` are reserved directory names at
the root of a prompts directory — a model can never be called `review`.
There is no actual collision to worry about: a model id is always sanitised
into `model/<id>.md` (below), never written at the root, so a model literally
named `review` still cannot shadow the leg directory. But a reader should not
have to work that out to know a model id is safe to pick; treat the four leg
names as off-limits at the root, full stop.

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
creating anything. It also prints the resolved prompts directory, one
`prompt_overlay_fragments[<leg>]=` line per leg with that leg's fragments in
composition order (comma-separated, empty when the leg matched nothing), and
the one rev that covers all of them:

```
prompt_overlay_dir=/home/you/.config/fork-sandbox/prompts
prompt_overlay_fragments[implement]=all.md,model/qwen3.5-9b.md
prompt_overlay_fragments[review]=all.md,review/all.md
prompt_overlay_fragments[fix]=all.md,fix/all.md,fix/model/qwen3.5-9b.md
prompt_overlay_rev=abc1234
```

`--dry-run` knows, from `--review-loop` and `--maintainer-loop`, exactly
which legs a real run would generate — the same flags the real run reads —
so it reports exactly those legs and no others: `implement` always, `review`
under `--review-loop`, `fix` under either loop (a maintainer fix leg runs on
the implement harness and shares the fix template), and `maintainer` under
`--maintainer-loop`. With neither flag, only `implement` is printed; the
other legs never ran, so there is nothing to report for them. This is what
lets a reader see, at a glance, that the fix leg gets a fragment the review
leg does not: check `--prompts-dir` before it is spent on a real run.

## Provenance: what the run record carries

A prompt is part of what produced a result, so a change to one has to be
attributable the same way a code change is. When an overlay applies to at
least one leg, `fork-sandbox.sh` writes `<run-dir>/prompt-overlay.json`, and
`sandbox-run-log.py record` folds it into the run's log entry under
`prompt_overlay`:

```json
"prompt_overlay": {
  "dir": "/home/you/.config/fork-sandbox/prompts",
  "rev": "abc1234-dirty",
  "legs": {
    "implement": {
      "fragments": ["all.md", "model/qwen3.5-9b.md"],
      "sha256": "…"
    },
    "fix": {
      "fragments": ["all.md", "fix/all.md", "fix/model/qwen3.5-9b.md"],
      "sha256": "…"
    }
  }
}
```

- **`dir`** — the source directory this run read. A fact about the run, not
  about any one leg, so it stays at the top level.
- **`rev`** — `git rev-parse HEAD` of the prompts directory, when it is a git
  repository. **If its working tree has uncommitted changes, the rev is
  suffixed `-dirty`.** This is the one rule that has to be right: a record
  that names a clean commit which did not actually produce the run's prompts
  is worse than a record with no rev at all, because it looks trustworthy
  when it is lying. The dirty check (`git status --porcelain`) is scoped to
  the prompts directory itself, not the whole repository it may live inside.
  When the directory is not a git repository at all, `rev` is `null`. Like
  `dir`, one rev covers every leg — the directory did not change git state
  between rendering the implement prompt and rendering the fix prompt.
- **`legs`** — one key per leg that matched at least one fragment:
  `implement`, `review`, `fix`, `maintainer`. A leg that matched nothing is
  absent from `legs` entirely, and a leg that never rendered a prompt is
  absent from a run made without the flag that turns it on — `review`
  without `--review-loop`, `fix` with neither loop, `maintainer` without
  `--maintainer-loop` — since a prompt that was never rendered carries no
  provenance. Each present leg holds:
  - **`fragments`** — the relative paths that matched for that leg, in
    composition order (the five-file search order above, filtered to what
    existed).
  - **`sha256`** — a fingerprint of exactly the bytes concatenated into that
    leg's prompt, independent of git state. Two legs that matched the same
    fragments (root-level `all.md` only, say) get the same hash; a leg with
    its own `<leg>/all.md` gets a different one.

No `prompt_overlay` key is written at all when a run applied no overlay to
any leg — the common case, and the same shape a run made before this
mechanism existed already had.

Query it like any other dimension `sandbox-run-log.py` groups on:

```
sandbox-run-log.py stats --by model,prompt_overlay.rev
sandbox-run-log.py stats --by prompt_overlay.legs.fix.sha256
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
