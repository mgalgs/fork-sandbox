# Presets: agents and a pipeline in a file, not flags in a command

`fork-sandbox.sh` grew its pipeline one flag pair at a time — `--harness`
and `--model`, then `--review-harness`/`--review-model`/`--review-loop`,
then the maintainer trio — and a launch that uses all of it is a command
line only an orchestrating session can love. A preset names that whole
shape once: which agent codes, who reviews it, who maintains, who fixes
what each finds, with what loop caps. The launch becomes

```
fork-sandbox.sh --preset deep ~/src/myrepo /var/tmp/claude-scratch/handoff.md
```

This is the first rung of the "pipeline as data" idea recorded in
[ideas.md](ideas.md): the leg list as a declarative document the existing
execution machinery walks, with the flags becoming sugar for — and
overrides on — what the document says. Two knobs here already have no
flag equivalent at all (`fix_agent` and `repeat`, below): new pipeline
capability lands preset-first, which is that entry's direction of travel.
The general agent-graph DSL stays parked; see "Where the syntax stops"
below for the boundary.

## Where presets live

`~/.config/fork-sandbox/presets/<name>.yaml`, beside the rest of the
per-machine config (`aliases.conf`, `pi.env`). Overridable, like the rest
of that config, via `FORK_SANDBOX_CONFIG_DIR`, and specifically via
`FORK_SANDBOX_PRESETS_DIR` when only the presets should move.

**This repo ships the mechanism only, no preset files** — the same call it
makes for prompt overlays. A preset names models, and which model is
"fast" or "smart" on a given machine is a fact about that machine's
config, endpoints and budget, not something this repo can know. The
worked examples below are prose to copy, not shipped files.

`fork-sandbox.sh configure` does not write presets, the same way it does
not write `coder-mode.env`: there is nothing to discover — a preset is a
judgement about how much machine a class of task deserves, authored by
hand.

The preset name is part of the flag, so it follows the same rule
discoverer ids do — `^[a-z0-9][a-z0-9_-]*$`, one path component, never a
path. Naming a preset that does not exist is an error that lists the
presets that do; there is no silent fallback.

Parsing the file needs PyYAML (commonly packaged as `python-yaml` or
`python3-yaml`) — the preset feature's one dependency beyond the stock
`python3` the repo already uses. A machine without it gets a plain error
naming the package, and only when `--preset` is actually passed.

## The file format

YAML, shaped like a CI workflow file: an `agents` mapping, and a
`pipeline` list of uniform steps — every step is `action:` plus named
properties.

```yaml
# Deep, cheaply: a small model types and re-checks its own typing, a
# cross-family reviewer reads the diff, and a maintainer with a strong
# fixer has the last word.
agents:
  haiku-coder:
    harness: claude
    model: haiku
    repeat: 3           # every coding leg by this agent runs 3 passes
    refresh-at: 0.6
  reviewer:
    harness: pi
    model: moonshotai/kimi-k3
  coder:
    harness: claude
    model: fable
  elder:
    harness: claude
    model: opus

pipeline:
  - action: code
    agent: haiku-coder

  - action: review
    repeat: 3
    agent: reviewer
    fix_agent: haiku-coder   # findings re-run this agent (x3, its repeat)

  - action: maintain
    repeat: 2
    agent: elder
    fix_agent: coder         # the maintainer's findings get the strong fixer
```

### `agents`

An agent is a named seat: who types, on what, and how. Names match
`^[a-z0-9][a-z0-9_-]*$`. Properties:

| property | meaning |
|---|---|
| `harness` | required — `claude`, `pi` or `codex`. The combined `harness/model` form the flags accept works here too, split at the first slash for the same reason (an OpenRouter model id carries its own slash). |
| `network` | `pinned` (the default) or `sealed`, the same axis as `--network`: whether this seat's harness reaches the network at all. `sealed` requires `harness: pi` — `claude` and `codex` have no self-hosted-endpoint path, and `{harness: claude, network: sealed}` is refused at load time. Otherwise independent of `harness` — `{harness: pi, network: sealed}` is `--harness pi --network sealed`. |
| `model` | the seat's model or model alias. Optional where the flag is optional, required where it is required (`pi` needs one, on any seat, unless `network: sealed`); conflicts with a combined `harness` form, exactly as `--model` conflicts with `--harness pi/x`. |
| `claude-args` | extra arguments for the claude CLI — e.g. `--effort high`. Reaches every leg this agent sits in a composed pipeline; in a legacy-shaped pipeline (see "Composed runs" below), the implement seat's legs only. |
| `pi-args` | extra arguments for pi — e.g. `--thinking low`. Same reach as `claude-args`. |
| `codex-args` | extra arguments for `codex exec` — e.g. `-c model_reasoning_effort="high"`. Same reach as `claude-args`. |
| `repeat` | run every coding leg this agent sits — a code step, or a loop's fix legs — as N passes on the same prompt. See "Repeat passes" below. A code step may set its own `repeat` (below) to override this agent-level default for that step only. |
| `refresh-at` / `refresh-max` | context refresh for this agent's coding, same values and claude-only rule as the flags of these names. |
| `endpoint` | which named `K8S_PROXY_ENDPOINTS` entry the seat talks to on a `--k8s` run, passed on to `fork-sandbox-k8s.sh run`, which resolves it against the registered endpoints. Refused on an agent that does not sit the first code step in pipeline order — the run has one proxy base URL for the whole run — and refused without `--k8s`: it names a cluster proxy path and means nothing locally. |

Three of these reach less far than an agent definition suggests, and the
parser refuses the cases the engine cannot honor rather than trimming
them silently: the refresh keys may only be SET on the first code step's
agent — there is no per-seat refresh plumbing, only the one run-level
`--refresh-at`/`--refresh-max` pair — but once set there they become that
pair and so govern every code and fix leg of the run exactly as the flags
would (see "A run that refreshes itself" in `README.md`), not only the
first code step's first pass. `repeat` is refused on an agent that never
codes, and `endpoint` is refused on an agent that does not sit the first
code step in pipeline order (the run has one proxy base URL for the whole
run) and without `--k8s` (it names a cluster proxy path and means nothing
there).

`claude-args`/`pi-args`/`codex-args` reach every leg the agent sits in a
composed pipeline (see "Composed runs" below) — only in a legacy-shaped
pipeline are they narrower, reaching the implement seat's legs alone. The
key must match the agent's own harness (`claude-args` on a `claude` seat,
`pi-args` on `pi`/`pi-local`, `codex-args` on `codex`); a mismatch, or an
agent that carries arguments but sits no seat at all, is refused at load
time rather than silently dropped.

### `pipeline`

A list of steps, each `action: code`, `review`, `maintain` or `plan`, in
any order and any count — the only structural requirement is at least
one step:

```yaml
  - action: code
    agent: haiku-coder
```

A `code` step is a coding leg. It takes `agent` and an optional `repeat`
that overrides the agent's own `repeat` (above) for this step only;
omitted, it defaults to the agent's `repeat` property.

`review` and `maintain` steps are loops:

| key | meaning |
|---|---|
| `agent` | who reads and writes the verdict. |
| `repeat` | required — the loop cap: how many verdict-then-fix rounds may run. |
| `fix_agent` | who acts on findings — any agent, running on its own harness and model, with its own `repeat`. Omitted, it defaults to the first code step's agent in pipeline order, riding the implement command exactly as fix legs always have. A pipeline with no code step has no such default: with no `fix_agent` anywhere it is read-only (below), and otherwise every `review`/`maintain` step needs one. |

Today's local run engine walks arbitrary linear pipelines. Kubernetes still
accepts only a **legacy-shaped** pipeline — one code step, then at most one
review step, then at most one maintain step, in that order. Free-order
pipelines can otherwise use this grammar directly.

Each round runs the verdict leg; **approval ends the loop** — every
review and maintain leg ends by writing a verdict whose first line is
`APPROVED` or `FINDINGS` (the code-review-portable contract), and
APPROVED is the exit. Otherwise the findings go to a fix leg on the
`fix_agent`, and the loop comes around, up to `repeat` rounds; a fix
round that moves the branch nowhere also ends it (no-progress). The
review step's read is the diff, line by line (`--review-loop`
machinery); the maintain step reads the way a maintainer judges a pull
request — the surrounding code, building on the review loop's final
verdict, which the engine forwards into its prompt (`--maintainer-loop`
machinery). A `maintain` step without a `review` step is valid, and is
then the branch's only review.

When a pipeline's LAST step is a `maintain` step and it approves, one more
leg runs right after it, on that same seat (same harness, same model) — a
tidy-history leg that rewrites the branch's commits into logical ones,
one change per commit, before the run ends. This is not a step of its
own: it has no `action` keyword, no preset key, and no flag to turn it
on or off — it is attached to whichever step, legacy or composed, ends up
last and is a `maintain` step, the operator's reasoning being that a
weaker model tidying history tends to hallucinate commit trailers, so
the maintain seat's own model (presumably a strong one) does this job
too. A pipeline whose `maintain` step is not last, or that has none at
all, runs no tidy leg; whoever integrates the branch reshapes it by hand,
and such a run leaves no tidy trace anywhere in its output or artifacts —
no `tidy.json`, no `tidy` key in `summary.json`, not even a "skipped" one.
The runner enforces that the rewrite changes no content (tree-identical
to what was approved), stays on the same base with no merge commits, and
invents no commit trailer, including one shaped like a trailer that
git's own parser would not recognize as one — a rewrite that fails any
of those, or that is still running past `--tidy-timeout` (default 30
minutes, per attempt — a retried attempt gets this same limit again,
fresh, not a shared budget across all of them), is discarded and the
approved history is kept, so a run's outcome never depends on this leg
succeeding. See `fork-sandbox.sh`'s own "The tidy leg" section for the
full contract.

A `plan` step is a one-shot leg that lets a strong model plan before a
cheaper one codes, so an orchestrator can write a short, intent-level
handoff and leave the mechanics — files and functions to touch, the test
list, the commit split — to this leg instead. It takes `agent` and an
optional `repeat`, which must be 1 for now (there is no loop to cap).
Every `plan` step must come before the pipeline's first `code` step — a
pipeline with a `plan` step and no `code` step anywhere is refused, the
same as one where a `plan` step sits after the first `code` step:

```yaml
agents:
  planner:
    harness: claude
    model: fable
  coder:
    harness: claude
    model: sonnet

pipeline:
  - action: plan
    agent: planner
  - action: code
    agent: coder
```

Every leg is also told to record a suite it runs, against a clean commit, in
`test-runs.jsonl` in the same outbox; a later review, maintain or fix leg that
starts on that exact commit is shown the record and told not to re-run the
suite (see [test-ledger.md](test-ledger.md)).

The plan leg writes its plan, as markdown, to `plan.md` in the run's
outbox (reserved there the same way `handoff.md` is, for every leg —
see "Artifact outbox" in the prompt every leg gets) and makes no
commits; the engine snapshots the file into the run directory and fails
the run if the branch head moved, so a plan that committed is caught
exactly like one that never wrote a plan at all. The plan is grounded in
the repository — files and functions to touch, with `file:line`
pointers — and asks for one decision, every open question turned into an
assumption, requirements stated as testable behavior with a test mapped
to each, and a commit split that keeps the tree green throughout; see
`fs_emit_plan_prompt_body` in `scripts/fork-sandbox-lib.sh` for the
prompt itself. If the plan's first non-blank line starts with the word
`BLOCKED` (heading or emphasis markup aside), the run ends there with no
code leg, and the plan's own text is the run's result.

The plan, once written, is embedded — right after the brief, which wins
where the two disagree — in the prompt of every code, fix, review and
maintain leg that runs after it. A reviewer is told to treat a code change
that deviates from the plan without saying why, and a plan assumption that
contradicts the brief, as findings; a code or fix leg is told instead to
say why when it deviates, so the reviewer is not left guessing.

`--refresh-at`'s continuation chain reaches the code leg that follows a
plan step exactly as it reaches a step-1 code leg — it follows every code
and fix leg of the run, wherever it sits (see "A run that refreshes
itself" in `README.md`). A plan-first run's step-1 `refresh` field in
`summary.json` reports `none` regardless (there is no implement leg at
step 1 for it to describe); the plan-following code step's own chain, like
every other non-step-1 leg's, lands in `summary.json`'s `leg_refreshes`
array instead. A `plan` leg itself never refreshes — it is a short
read-and-verdict leg, same as review and maintain.

A `plan` step is refused on a read-only pipeline and with `--review-only`
(both read-only shapes; a plan step always makes a pipeline composed, and
a read-only pipeline has no code step for a plan to precede). It runs on
`--k8s` like any other composed step: its seat is a claude or pi seat the
same per-seat checks apply to (see "Composed pipelines on `--k8s`" in
`docs/kubernetes-runs.md`), not a role the cluster path special-cases.

The same agent may sit any number of seats; an agent that sits none
draws a warning, not an error.

### Read-only pipelines

A pipeline with no `code` step and no `fix_agent` has nothing that could
act on a finding, so it reviews an existing branch instead: each step
writes its verdict once and the run ends. It takes the `--review-only`
range — `--checkout <ref>`, from `--review-base` or the merge-base with
`HEAD` — and the review-only prompt wording, which says no fix leg
follows. It may hold any number of `review` and `maintain` steps, in any
order. `repeat` must be 1: with no fix leg there is nothing to loop on.

Every leg builds on every earlier leg. Leg *k*'s prompt embeds the verbatim
verdict of each earlier leg in this run, oldest first, each under a heading
naming its step number, action and seat (`### Step 2: maintain
(claude/opus)`); the first leg's prompt carries none. A `maintain` step
is told a review already read the diff only when an earlier `review` step
ran; after maintainers alone, it is told to read the diff itself.

```
fork-sandbox.sh --pipeline ropus --checkout my-branch ~/src/myrepo brief.md
fork-sandbox.sh --pipeline rsol-mopus --checkout my-branch ~/src/myrepo brief.md
fork-sandbox.sh --pipeline ropus-mopus-ropus --checkout my-branch ~/src/myrepo brief.md
```

A `review`, a `maintain`, or a `review` then a `maintain` step runs on the
fixed review and maintain seats, and `--model`/`--harness`,
`--maintainer-model`/`--maintainer-harness` and the `--*-args` flags can
override them. Any other shape is a composed pipeline in read-only mode:
each step has its own seat and its own files in the run directory
(`s<K>-<action>-verdict-1.md`, `events-s<K>-<action>-1.jsonl`,
`step-<K>-loop.json`), and there is no single seat for a flag to land on, so
the seat-override flags (`--model`, `--harness`, `--review-*`,
`--maintainer-*`, `--review-loop`, `--maintainer-loop`, `--claude-args`,
`--pi-args`, `--codex-args`) are refused. Edit the pipeline instead — a
preset's own per-agent `claude-args`/`pi-args`/`codex-args` key is the
route onto one of these steps, same as a composed pipeline with a code
step.

`--review-only` is a deprecated bare-flag alias for this: without a preset
it is the one-review-leg case, seated by `--harness`/`--model`. Over a
preset it drops the code step and fix seats and runs the remaining review
and maintain steps this way, once each, whatever their `repeat` says (a
note says so). Prefer a read-only `--pipeline` (`--pipeline r<model>`) in
new callers; `--review-only` stays only as "drop the code step, review
`--checkout`" for callers that already depend on it. Like `--review-only`,
a read-only pipeline is refused with `--k8s`.

### Repeat passes

`repeat: N` on an agent turns each of its coding legs into N sequential
passes of the *same prompt*, deliberately without an early exit. The
point is to distrust a cheap model's premature "done": pass 1 writes the
implementation and declares victory; pass 2 reads the same brief, finds
the work already in place, and checks, polishes and fixes what pass 1
left shallow; pass 3 again. A pass that changes nothing does not stop
the remaining passes — a pass that *looks* finished is exactly the case
the mechanism exists for — only a harness error does (a dead run is not
polished, it is dead). The wager is that N cheap passes cost less than
one pass of a large model and land somewhere near it in quality; the run
log is where that wager gets settled per task shape.

Each pass is an ordinary leg with its own events file
(`events-code-2.jsonl`, or `events-fix-1-p2.jsonl` for a fix round's
second pass) and its own accounting. When it applies to fix legs, the
loop's no-progress check compares the branch across the whole N-pass
round. Every pass context-refreshes on its own, exactly like any other
code or fix leg — a pass that crosses the threshold hands off and
continues under a fresh session the same way, with its own chain of
`handoff-<leg>-c<N>.md`/`continuation-prompt-<leg>-c<N>.md`/
`events-<leg>-continuation-<N>.jsonl` records named after that pass's own
leg tag (e.g. `code-2`, `fix-1-p2`). A refused hand-off is filed as
`handoff-<leg>-c<N>-refused-empty.md` or `…-refused-too-large.md`. A
hand-off an earlier chain left in the outbox (the step-1 chain leaves its
capped one there) is moved to `handoff-unclaimed-<K>.md` before a later
leg is armed, so that leg never mistakes it for its own.

## Inline pipelines: `--pipeline`

A preset whose name already spells its pipeline need not exist as a file.
`--pipeline <spec>` takes that name and compiles it:

```
fork-sandbox.sh --pipeline csonnet2-rsol2-mopus2 ~/src/myrepo handoff.md
```

The spec is `-`-joined segments, `<stage><model>[<harness>][<N>]`:

- **stage** is `c` (code), `r` (review), `m` (maintain) or `p` (plan), in
  any order and any count, as a preset file's `pipeline` allows:
  `csonnet-csol-ropus-rsol-mopus-mastra` is two code steps, two review
  steps and two maintain steps. Fix legs ride the first code step's agent.
  A `p` segment carries the same rule its preset form does: it must come
  before the spec's first `c` segment, and a spec with `p` and no `c` is
  refused. The other exception is a spec with no `c` at all: it compiles
  to a read-only pipeline, so every repeat in it must be 1.
- **model** is a name from the table at the top of
  `scripts/fork-sandbox-pipeline-spec.py`, and runs on its native harness:
  `haiku`, `sonnet`, `opus`, `fable` on claude; `luna`, `terra`, `sol`,
  `astra` on codex. A codex model there is a bare tier name, not a
  generation-pinned slug — `resolve_model` turns it into a real model id
  at launch the same way it does for any other seat (see "Model aliases
  resolve at launch" below). A new tier needs a one-line addition to
  that table *and* a matching one-line addition to `MODEL_ALIASES` in
  `scripts/sandbox-run-log.py` — a test in
  `tests/sandbox-run-log-test.sh` enforces the two stay in step, and
  skipping the second leaves the tier displaying under a hashed slug
  in composition output instead of its name. A new *generation* of an
  existing tier needs neither edit — see "Bumping a generation" below.
- **harness**, optional, seats the model on a non-native harness
  (`csolpi2`); the table must carry the model's id for that harness.
- **N**, optional and 1 by default, is the code agent's `repeat`, or a
  review or maintain step's loop cap; on a `p` segment it must be 1.
  `csonnet-rsol-mopus` is one of each.

Each segment compiles to its own agent and its own pipeline step. A
stage's first segment names its agent the plain way (`coder`, `reviewer`,
`maintainer`, `planner`); a second and later segment of the same stage
numbers it from there (`reviewer2`, `reviewer3`, …) — deterministic on
the spec's own segment order, not on the model or harness a segment
names.

The spec compiles to the preset document a hand-written preset with the
same shape would be, and from there runs the `--preset` path unchanged:
the same parser, the same rules, the same flag overrides — for a
legacy-shaped spec, `--claude-args` reaches the code seat as it does over
a legacy-shaped preset file; a composed spec (more than one review or
maintain segment, say) refuses the flag the same way a composed preset
file does. Fix legs ride the code seat. `--dry-run` prints the compiled
seats, and the run records the spec in `preset.json` as `pipeline`, with
the spec as its `name`.

What the grammar cannot say — a `fix_agent`, per-seat arguments, a
network — stays a preset file. `--pipeline` and `--preset` are mutually
exclusive, but `--preset <name>` falls back to `--pipeline <name>` when no
file has that name and the name parses as a spec, so a composition name
works whether or not its file exists; a file always wins. A spec with no
`c` stage is a read-only pipeline (see "Read-only pipelines" above).

## Flags override, key by key

A preset value lands in exactly the variable its flag counterpart sets,
*before* any validation runs — so it passes through the same alias
resolution, the same harness rules, the same `--k8s` refusals the flag
would. And an explicit flag beats its preset counterpart, one key at a
time:

```
fork-sandbox.sh --preset deep --model opus ...     # the code seat types on opus
fork-sandbox.sh --preset deep --review-loop 5 ...  # a deeper review, same seats
```

Every override is announced on stderr, one line each, after a summary of
what the preset said — a run should never be a mystery about which of the
two sources a value came from. `--dry-run` prints `preset=<name>` and the
fully compiled result, and is the way to check a preset before spending a
run on it.

One override is coarser than the rest, on purpose: a flag that moves a
*seat's harness* (`--harness`, `--review-harness`,
`--maintainer-harness`) drops that seat's preset model, arguments and
repeat too, with a note — they were tuned to the agent the preset named,
not to the override. An explicit `fix_agent` is its own seat and
survives a code-seat override; a *defaulted* fix seat follows the
implement command wherever the flags took it, dropping the preset
agent's repeat along the way (also with a note). What a `--harness`
override does not drop: the code seat's `endpoint`, always — only an
explicit `--endpoint` replaces it, because it names a fact about the
run's cluster (which named proxy endpoint the pod talks to), not about
the agent the preset named; and the seat's refresh keys, whenever the
override lands on claude — refresh is claude-only and is gated on the
harness the seat ends up on, so an override off claude drops the keys
with a note of its own. No flag names a fix
seat or a repeat, so nothing overrides those two — they are the first
preset-only knobs.

## Because a preset is just flags, the flag rules apply

There is no separate preset semantic to learn, which also means the sharp
edges are the flags' own — plus the edges of the two preset-only knobs:

- **`--k8s` works with a preset, two different ways depending on its
  shape.** A legacy-shaped preset (the fixed one-code/one-review/one-
  maintain skeleton, or a subset of it) has its compiled values flow into
  the cluster path like typed flags — but its agent's own preset-only
  knobs that have no `--k8s` flag equivalent (`fix_agent`, `repeat > 1`)
  are refused there by name, same as `claude-args`/`pi-args`/`codex-args`
  and the refresh keys are refused against ANY composed preset above
  (unrelated to `--k8s`: a composed step's seat has nothing those
  flags would land on). A code seat may carry an `endpoint` key, which
  wires the run to that named proxy endpoint on a `K8S_PROXY_ENDPOINTS`
  install, with `--endpoint` overriding it like every other key.
  A *composed* preset instead dispatches through the shared runner — see
  "Composed pipelines on `--k8s`" in `docs/kubernetes-runs.md` for what
  runs, what collect lands, and the handful of seat shapes (codex, a
  sealed/pi-local network, a model-less claude or pi seat) still refused
  by name.
- **`--review-only` refuses review and maintainer flags**, so it refuses
  a preset that carries loops — and one whose code seat repeats, since
  there is no coding leg to repeat. A preset with only a code step works
  fine as the seat for `--review-only`.
- **Model aliases resolve at launch, not at authoring time.** A preset
  holding `model: sol` means whatever `aliases.conf` (or the codex model
  cache) says `sol` means on the day of the run.
- **Validation messages speak flag vocabulary** where a flag exists. The
  mapping is one-to-one: code seat ⇢ `--harness`/`--model`/
`--claude-args`/`--pi-args`/`--codex-args`/`--endpoint`, the review step ⇢ `--review-harness`/
  `--review-model`/`--review-loop`, the maintain step ⇢ the maintainer
  trio, refresh keys ⇢ `--refresh-at`/`--refresh-max`.

What a preset deliberately cannot set: the task-shaped flags. `--branch`,
`--checkout`, `--k8s`, `--review-only`, `--task-meta`, `--context-ro`,
`--context-secret`, `--prompts-dir` and the rest describe *this run's task*; a preset
describes *how much machine a class of task deserves*. Keeping the file
to the second kind is what keeps one preset reusable across many runs.

## Bumping a generation

`--pipeline`'s codex tier names (`luna`, `terra`, `sol`, `astra`) name a
role, not a specific model release — `rsol2` means "the sol tier as
`aliases.conf` pins it today", nothing more. Moving a whole fleet to a new
codex generation is therefore an edit to `aliases.conf` and nothing else:
no preset file or script changes.

```
# ~/.config/fork-sandbox/aliases.conf
codex luna gpt-6-luna
codex sol  gpt-6-sol
codex astra gpt-6-astra
```

With no matching line, a tier name falls back to the codex model cache
(`${CODEX_HOME:-~/.codex}/models_cache.json`), matched by exact id, then by
unique suffix or substring. Once two generations of the same tier are both
visible there (`gpt-5.6-sol` and `gpt-6-sol`), that fallback becomes
ambiguous on purpose — a generation bump is never picked silently — and
the refusal names `aliases.conf` and the exact line to add. A tier with
only one visible generation still resolves through the cache with no
`aliases.conf` line at all.

An **old** generation is pinned the opposite way: name its exact slug in a
preset file (`model: gpt-5.6-sol`), never in the composition-name grammar,
which only ever spells tier names.

## Worked examples

**fast** — one cheap leg, no loops. For mechanical sweeps where a review
would cost more than retyping the change:

```yaml
agents:
  coder:
    harness: claude
    model: haiku

pipeline:
  - action: code
    agent: coder
```

**cheap-passes** — the repeat wager by itself: three haiku passes, no
review. Pass 1 implements; passes 2 and 3 check the work pass 1 declared
finished:

```yaml
agents:
  coder:
    harness: claude
    model: haiku
    repeat: 3

pipeline:
  - action: code
    agent: coder
```

**smart** — a high-intelligence implementer with effort turned up, and a
self-review loop to catch its own slips:

```yaml
agents:
  coder:
    harness: claude
    model: fable
    claude-args: --effort high

pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: coder
```

This is a legacy-shaped pipeline (one code step, then one review step), so
`claude-args` reaches only the code seat's legs: the self-review loop runs
without `--effort high`. Add another step (making the
pipeline composed) to route the coder's own arguments to its review leg too.

**free-typing** — a self-hosted model types for free while a paid model
reviews, the coder-mode economics as one word:

```yaml
agents:
  typist:
    harness: pi
    network: sealed
  reviewer:
    harness: claude
    model: fable

pipeline:
  - action: code
    agent: typist
  - action: review
    repeat: 3
    agent: reviewer
```

**deep** — the shape from "The file format" above: a repeating cheap
implementer, a cross-family reviewer whose findings re-run the cheap
seat, and a maintainer whose findings get a strong fixer.

**planned** — a strong model works out the approach, a cheap one codes
it, and a mid-tier model reviews against both the plan and the brief:

```yaml
agents:
  planner:
    harness: claude
    model: fable
  coder:
    harness: claude
    model: haiku
  reviewer:
    harness: claude
    model: sonnet

pipeline:
  - action: plan
    agent: planner
  - action: code
    agent: coder
  - action: review
    repeat: 2
    agent: reviewer
```

Equivalently, `--pipeline pfable-chaiku-rsonnet2`.

## Provenance: what the run record carries

A preset is part of what produced a result, so a run launched with one
writes `<run-dir>/preset.json` — the preset's name, the file it came
from, and a sha256 of the definition's bytes at launch — alongside
`<run-dir>/preset.yaml`, a byte-identical copy of the definition as
launched, and `sandbox-run-log.py record` folds the provenance into the
run's log entry under `preset` and, since the live file may be edited
during the run, archives that copy under `preset.archive`, deduplicated
by the sha256. The compiled outcome is already in the record: `run.env`
carries `code_repeat`, `fix_harness`/`fix_model`/`fix_repeat` and their
`maintainer_fix_*` counterparts when set, and `review-loop.json` /
`maintainer-loop.json` name their loop's fix seat beside the reviewer.
What `preset.json` pins is which document produced all of it, so an
edit to a preset shows up as a changed hash rather than as two
indistinguishable runs. No `preset` key at all when the run used no
preset — the same absence convention every optional record key follows.
A `--pipeline` run has no file: its `preset.json` carries `pipeline`, the
spec, in place of `file`, and `preset.yaml` is the compiled document.

Two accounting notes for multi-pass rounds: an iteration's `fix_cost_usd`
is the passes' sum (null when any pass went unpriced), and its
`fix_usage` is recorded for single-pass rounds only — per-pass token
detail stays in each pass's own events file.

```
sandbox-run-log.py stats --by preset.name
sandbox-run-log.py stats --by preset.name,model
```

## Composed runs: artifacts on disk, and the ledger key

A **legacy-shaped** run (one code step, then at most one review step, then
at most one maintain step) writes the historical, unindexed names:
`review-loop.json`, `maintainer-loop.json`, `review-verdict-<N>.md`,
`maintainer-verdict-<N>.md`, `review-prompt-<N>.md`,
`maintainer-prompt-<N>.md`, `events-review-<N>.jsonl`,
`events-maintainer-<N>.jsonl`, `events-fix-<N>.jsonl`,
`events-mntfix-<N>[-p<P>].jsonl`, `events-code-<N>.jsonl`,
`events-continuation-<N>.jsonl`. When the maintain step is last and
approves, the tidy leg that follows it adds `tidy-prompt.md` (the static
base), `tidy-prompt-1.md` (the per-run copy, naming the approved head)
and `events-tidy-1.jsonl`.

A **composed** run (anything else this grammar can express — free step
order, more than one review or maintain step, review after maintain, and
so on) writes step-indexed names instead, where `<K>` is the 1-based step
number in pipeline order: `step-<K>-loop.json`,
`s<K>-review-verdict-<i>.md`, `s<K>-maintain-verdict-<i>.md`,
`step-<K>-prompt-<i>.md`, and
`events-s<K>-(code|review|maintain|fix)-<N>[-p<P>].jsonl`. The same tidy
leg, when the LAST step is maintain and approves, adds
`step-<K>-tidy-prompt.md`, `step-<K>-tidy-prompt-1.md` and
`events-s<K>-tidy-1.jsonl` for that step's `<K>`. `tidy.json` -- `ended`
(`accepted`/`unchanged`/`discarded`/`skipped`), `detail`, the two heads
compared, cost, usage and `clone_restored` -- is written in BOTH shapes,
on every run whose pipeline has a maintain step ANYWHERE (not just last):
`skipped` with a reason when that step is not last or did not approve.
`summary.json`'s own `tidy` key mirrors it the same way. A pipeline with
no maintain step at all writes neither -- no `tidy.json`, no `tidy` key.
A run launched
with `--preset` also writes `pipeline.json` (see "Provenance" above for
`preset.json`/`preset.yaml`, which are separate files) — its `steps` array
is the source of truth this section's canonical key is built from.

A code or fix leg's OWN refresh chain (every one of them, now — see "A
run that refreshes itself" in `README.md`) is named after that leg's own
tag, never the run's flat numbering, which stays reserved for the step-1
implement leg's own chain: `handoff-<leg>-c<C>.md`,
`continuation-prompt-<leg>-c<C>.md` and `events-<leg>-continuation-<C>.jsonl`
for continuation `<C>` of leg `<leg>` — `code-2` or `fix-1-p2` in a
legacy-shaped run, `s2-code-1` or `s3-fix-2` in a composed one, always
carrying a kind word that a flat `handoff-1.md`/`events-continuation-1.jsonl`
never does, so the two naming schemes can never collide.

A code pass after the first also writes `code-prompt-<K>-<P>.md` (step
`<K>`, pass `<P>`): the handoff plus the addenda earlier legs archived, and
the plan when this run has one. It is written only when an addendum was
archived or this run has a plan step; otherwise the pass's prompt is the
handoff itself. A plan-prefixed pipeline's first code pass writes this
file too, from its own first pass: that code step is never the run's own
top-level implement leg (a plan step always runs ahead of it), so it has
no "first pass, outside this accounting" case to be the exception to.

A `plan` step (always composed — a pipeline containing one is never one of
the legacy-eligible shapes below) writes `plan.md` at the run directory's
own root, a snapshot of whatever it wrote to `plan.md` in the outbox, and
its own `step-<K>-loop.json`, shaped differently from a review/maintain
step's: `{cap, ended, detail, cost_usd, usage, retries}` plus an always
empty `iterations` array, and no fix fields — there is no verdict-then-fix loop
to record, just the one leg's own outcome. Its `ended` is `done`,
`blocked` (the plan's own first line was `BLOCKED`), `committed` (the leg
committed to the branch, which a plan leg must never do) or
`harness-error`.

A claude leg that failed on an auth or transient provider error is retried
fresh (see "The loop stops on the first of four things" near the top of
`fork-sandbox.sh` for what counts); each failed attempt's own events file
is archived beside the leg's own, as `<name>.jsonl.attempt<k>`, so the file
at the leg's ordinary name always holds its last attempt. The iteration
record gains a `retries` array (`{attempt, error, delay_s, leg}` per
retry, empty when the leg never retried), and its cost sums every attempt
rather than only the last one. The review/maintainer leg and its fix
leg(s) share one iteration record, so `leg` (`"review"`, `"maintainer"` or
`"fix"`) says which leg each element belongs to; a fix leg's own element
also carries `pass` when the fix seat's `repeat` ran more than one.

Note that a composed step's saved loop record always uses the `review_model`/
`review_harness` field names, even for a `maintain` step — only a
*legacy* maintainer step gets `maintainer_model`/`maintainer_harness`; a
reader has to consult `pipeline.json`'s own `action` for the step to tell
review and maintain apart.

`fork-sandbox-status.sh` reads both artifact shapes, and its report comes
from the verdict of the highest step index that produced one (ties break to
the highest iteration) — in a legacy-shaped run that is the maintainer's
verdict, same as it always was, just stated as one rule instead of two.

### `progress.json`: a live per-step status file

Every non-`--k8s` run also writes `<run-dir>/progress.json`, rewritten
atomically at every step start, leg start and end, and run end, so a reader
never sees a half-written file. It has one entry per pipeline step, legacy
or composed alike, in `pipeline.json` order (a legacy run's own translated
steps get the same one-entry-per-step treatment even though it never writes
`pipeline.json`):

```json
{"schema": 1, "label": "sbx-foo", "spec": "composed", "state": "running",
 "updated": 1234567890,
 "steps": [{"action": "code", "state": "done", "i": 1, "cap": 1, "ended": null, "continuation": 0},
           {"action": "review", "state": "running", "i": 1, "cap": 2, "ended": null, "continuation": 2}]}
```

`label` is the branch with a leading `sandbox/`-style prefix (one path
segment) stripped, and `spec` is the preset name, the `--pipeline` spec
string, or null for a plain-flags run — both fixed at launch. A review or
maintain loop is one entry regardless of its cap; `i` counts iterations
begun (or, for a code step with `repeat: N`, passes run so far), and
`ended` takes the walker's own vocabulary verbatim (`approved`, `findings`,
`cap`, `no-progress`, `harness-error`, `skipped`, `stop-requested`, a
`plan` step's own `done`, `blocked` and `committed`, …), same spelling as
`review-loop.json`/`step-<K>-loop.json`'s own `ended` key.

`continuation` counts the `--refresh-at` continuations taken so far by
this step's *currently running leg*: for a code step, its code leg's own
chain; for a review or maintain step, its fix leg's chain (a review or
maintain leg never refreshes, per the operator decisions above). It
resets to 0 when that leg starts a fresh chain — a code step's next
`repeat` pass, or a review/maintain step's next iteration's fix leg — so a
value here always describes the leg presently in flight, never a prior
pass's or prior iteration's chain. It stays 0 for the whole run when
`--refresh-at` is off, the seat isn't `claude`, or the step is plan,
review or maintain (no leg of its own ever refreshes). This is additive:
`i`'s own meaning (iterations/passes) is unchanged. The
run's own `state` is `failed` when the final exit code is non-zero *or* any
step ended `failed` — a review-loop harness error does not by itself
change the run's exit code (see "Composed runs" above), so this is the one
place that failure is visible without reading the loop record too.

`fork-sandbox.sh` also links every run it launches under a per-session
index, from `$CLAUDE_CODE_SESSION_ID` at launch time:
`<by-session-root>/<session-id>/<run-dir-basename>` → the run directory
(default root `/var/tmp/claude-scratch/forks/by-session`, overridable with
`FORK_SANDBOX_BY_SESSION_DIR`). `fork-sandbox-status.sh --session <id>
--progress` reads that index and prints one compact line per linked run,
oldest first, e.g. `sbx-foo  running  code:done review:running(1/2)`, so a
status line can show one glyph per pipeline step for every run a session
has started without shelling into tmux.

### Keying the run log by composition, not by name

`sandbox-run-log.py record` computes two fields from `pipeline.json`'s
`steps` array, present only when that file exists (a flag-driven run,
which writes no `pipeline.json`, gets neither field, and so cannot yet be
compared against a preset run in `stats` — the alternative, synthesizing a
composition from `run.env`, would give one concept two derivations, which
is the exact problem this design removes):

- **`composition`** — the canonical identity: each step reduced to exactly
  `action`, `harness`, `model`, `repeat`, `network`, `fix` (and `fix`, when
  set, reduced to exactly `harness`, `model`, `repeat`), then the whole
  array serialized as compact, key-sorted JSON
  (`json.dumps(steps, sort_keys=True, separators=(",", ":"))`). Step order
  is part of the identity and is never reordered. JSON, not a
  punctuation-joined token string, because a model id can legitimately
  contain both `/` (an OpenRouter `vendor/model-name` id) and `:` (an
  ollama-style `qwen2.5:7b` id) — any joined-string separator collides
  with some real model id, where JSON escapes for free.
- **`composition_short`** — a best-effort display label, never a grouping
  key: per step, in order, `<stage-letter><model-token><repeat>` joined
  with `-` (`code`/`review`/`maintain` → `c`/`r`/`m`; a model id one of
  whose separator-delimited segments is a registered alias —
  `sonnet`, `opus`, `haiku`, `fable`, `terra`, `sol`, `luna`, `astra` —
  contributes that alias spelled out; anything else slugs to the first 4
  lowercased `[a-z0-9]` characters after its last `/`, or `x` for no
  model). Actions are a closed set, so they keep single letters; models are
  an open set that grows without warning, so they are spelled out. A single
  letter per model was tried first and collided — sonnet claimed `s`, so
  sol was handed `l`, and luna then wanted `l` as well — which is also
  why `gpt-5.6-terra`, `gpt-5.6-sol` and `gpt-5.6-luna` must not share a
  token: slugging by the id's *head* gives all three `gpt5`. If any step took the slug path, a final
  `-<4 hex chars>` — the first 4 hex characters of the sha256 of the
  canonical string — is appended, so the reader can tell the shortname
  alone did not pin down the composition.

  This same segment match also means a tier's token does not carry its
  generation: a `sol` step on `gpt-5.6-sol` and one on `gpt-6-sol` both
  display as `...sol1...`, identically. They are never merged — grouping
  is always on the canonical `composition`, which carries the exact
  resolved model id — but two rows with an identical `composition_short`
  in a `--by composition_short` table can be different generations of the
  same tier. Read the canonical value (or `--by composition`) when that
  distinction matters.

**Renaming or copying a preset file never changes `composition`** — it is
computed from step content alone, which is exactly what lets `stats` group
runs of one preset that got renamed, or two differently-named presets that
happen to compose identically, together. `stats --by composition` groups
on this raw canonical value but prints `composition_short` in the cell —
grouping on the shortname, or on the preset's own name, would risk
silently merging two different compositions, which defeats the reason this
key exists. **Never group by the preset name or by `composition_short`
alone** when the question is "which compositions am I comparing" —
`--by composition_short` stays available, but stays honest about being a
display-only grouping that can merge distinct compositions.

`sandbox-run-log.py record` also folds every `step-<K>-loop.json` it finds
into the run record's `steps` array (ordered by `<K>`, each element the
parsed loop record plus `step` and `action`, the latter read from
`pipeline.json`, per the field-name trap above) — present only when at
least one such file exists. A composed run therefore carries `steps` and
neither `review_loop` nor `maintainer_loop`; a legacy run carries the
reverse; a run never carries both.

```
sandbox-run-log.py stats --by composition
sandbox-run-log.py stats --by composition_short
```

## Where the syntax stops

The pipeline vocabulary is exactly the legs the execution machinery has
(free-order and repeated-step composition, per "pipeline" above, is
grammar the run engine actually walks — not the general DSL below). What
the syntax does not have, no engine — present or planned — has either:

- **No conditional vocabulary.** Approval ends a loop, the cap ends it,
  no-progress ends it — those are the verbs' meaning, not options to
  choose among.
- **No `summarize` action**, or other steps that pass work along without
  fixing.
- **No action beyond `code`/`review`/`maintain`/`plan`**, and no branches
  or graphs — a pipeline is always a single linear chain, of any length.
  The tidy-history leg is not a fifth action: it has no `action` keyword
  and no preset key, and it is never a step of the pipeline a preset or
  `--pipeline` spec describes — it is the runner's own addition, attached
  to whichever step ends up last when that step is `maintain` and
  approves (see "Composed runs" above).
- **No per-seat `refresh-at`/`refresh-max`.** An agent's own key reaches
  only the first code step's agent, because there is no per-seat *refresh*
  plumbing — only the one run-level `--refresh-at`/`--refresh-max` pair a
  preset's key becomes once accepted — so it governs every code and fix
  leg of the run, not just the seat it was written on (see "A run that
  refreshes itself" in `README.md`). This is a plumbing gap named by its
  own refusal, not a design position.
- **No `input:` key.** The engine fixes the data flow — the code step
  reads the handoff, fix legs read the verdict, review prompts are
  generated — so a key that names a prompt source would promise a choice
  that does not exist.

Those belong to the general pipeline-as-data design still parked in
[ideas.md](ideas.md) — several independent seats, decision points per
edge, an iterated record — which is the mailing-list mode generalized,
and should not be built piecemeal from here. When the engine grows a leg
shape, its action or property joins this file's vocabulary; a preset
written today keeps meaning what it means.
