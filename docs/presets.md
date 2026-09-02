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
| `harness` | required — `claude`, `pi`, `pi-local` or `codex`. The combined `harness/model` form the flags accept works here too, split at the first slash for the same reason (an OpenRouter model id carries its own slash). |
| `model` | the seat's model or model alias. Optional where the flag is optional, required where it is required (`pi` needs one, on any seat); conflicts with a combined `harness` form, exactly as `--model` conflicts with `--harness pi/x`. |
| `claude-args` | extra arguments for the claude CLI — e.g. `--effort high`. |
| `pi-args` | extra arguments for pi — e.g. `--thinking low`. |
| `repeat` | run every coding leg this agent sits — the code step, or a loop's fix legs — as N passes on the same prompt. See "Repeat passes" below. |
| `refresh-at` / `refresh-max` | context refresh for this agent's coding, same values and claude-only rule as the flags of these names. |
| `endpoint` | which named `K8S_PROXY_ENDPOINTS` entry the seat talks to on a `--k8s` run, passed on to `fork-sandbox-k8s.sh run`, which resolves it against the registered endpoints. Refused on an agent that does not sit the code seat — the run has one proxy base URL for the whole run — and refused without `--k8s`: it names a cluster proxy path and means nothing locally. |

Four of these reach less far than an agent definition suggests, and the
parser refuses the cases the engine cannot honor rather than trimming
them silently: `claude-args`/`pi-args` reach only the first code seat's
legs (there is no per-seat argument plumbing for any other leg yet), the
refresh keys reach only the first code seat's *first pass*, `repeat`
is refused on an agent that never codes, and `endpoint` is refused on
an agent that does not sit the code seat (the run has one proxy base
URL for the whole run) and without `--k8s` (it names a cluster proxy
path and means nothing there).

### `pipeline`

The first item is the **code step** — the coding leg, exactly once:

```yaml
  - action: code
    agent: haiku-coder
```

Then at most one **review step** and one **maintain step**, in that
order. Each is a loop:

| key | meaning |
|---|---|
| `agent` | who reads and writes the verdict. |
| `repeat` | required — the loop cap: how many verdict-then-fix rounds may run. |
| `fix_agent` | who acts on findings — any agent, running on its own harness and model, with its own `repeat`. Omitted, it is the code seat's agent, riding the implement command exactly as fix legs always have. |

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

The same agent may sit any number of seats; an agent that sits none
draws a warning, not an error.

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
round. Passes after the first do not context-refresh — the refresh chain
belongs to the first pass of the code step alone.

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
agent's repeat along the way (also with a note). The one key a
`--harness` override does not drop is the code seat's `endpoint`, and
only an explicit `--endpoint` replaces it — it names a fact about the
run's cluster (which named proxy endpoint the pod talks to), not about
the agent the preset named. No flag names a fix
seat or a repeat, so nothing overrides those two — they are the first
preset-only knobs.

## Because a preset is just flags, the flag rules apply

There is no separate preset semantic to learn, which also means the sharp
edges are the flags' own — plus the edges of the two preset-only knobs:

- **`--k8s` works with a preset** — the compiled values flow into the
  cluster path like typed flags — but a preset that sets things the
  cluster path refuses (a `maintain` step, `claude-args`, `pi-args`, the
  refresh keys) is refused exactly as those flags are, and fix seats and
  `repeat` are refused there by name too: the pod's own review loop runs
  its fix legs on the coding model, once each. A code seat may carry an
  `endpoint` key, which wires the run to that named proxy endpoint on a
  `K8S_PROXY_ENDPOINTS` install, with `--endpoint` overriding it like
  every other key. A cluster run wants a preset shaped for the cluster.
- **`--review-only` refuses review and maintainer flags**, so it refuses
  a preset that carries loops — and one whose code seat repeats, since
  there is no coding leg to repeat. A preset with only a code step works
  fine as the seat for `--review-only`.
- **A codex fix seat is refused** for now: the runner writes a per-seat
  codex credential for the implement, review and maintainer seats only.
- **Model aliases resolve at launch, not at authoring time.** A preset
  holding `model: sol` means whatever `aliases.conf` (or the codex model
  cache) says `sol` means on the day of the run.
- **Validation messages speak flag vocabulary** where a flag exists. The
  mapping is one-to-one: code seat ⇢ `--harness`/`--model`/
  `--claude-args`/`--pi-args`/`--endpoint`, the review step ⇢ `--review-harness`/
  `--review-model`/`--review-loop`, the maintain step ⇢ the maintainer
  trio, refresh keys ⇢ `--refresh-at`/`--refresh-max`.

What a preset deliberately cannot set: the task-shaped flags. `--branch`,
`--checkout`, `--k8s`, `--review-only`, `--task-meta`, `--context-ro`,
`--prompts-dir` and the rest describe *this run's task*; a preset
describes *how much machine a class of task deserves*. Keeping the file
to the second kind is what keeps one preset reusable across many runs.

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

**free-typing** — a self-hosted model types for free while a paid model
reviews, the coder-mode economics as one word:

```yaml
agents:
  typist:
    harness: pi-local
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

Two accounting notes for multi-pass rounds: an iteration's `fix_cost_usd`
is the passes' sum (null when any pass went unpriced), and its
`fix_usage` is recorded for single-pass rounds only — per-pass token
detail stays in each pass's own events file.

```
sandbox-run-log.py stats --by preset.name
sandbox-run-log.py stats --by preset.name,model
```

## Where the syntax stops

The pipeline vocabulary is exactly the legs the execution machinery has,
and what the syntax does not have, the engine does not have either:

- **No conditional vocabulary.** Approval ends a loop, the cap ends it,
  no-progress ends it — those are the verbs' meaning, not options to
  choose among.
- **No `summarize` action**, or other steps that pass work along without
  fixing.
- **No third tier**, and no arbitrary chains or branches.
- **No per-seat args or refresh** beyond the first code seat, and no
  codex fix seats — each a plumbing gap named by its refusal, not a
  design position.
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
