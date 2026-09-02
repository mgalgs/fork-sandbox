---
name: sandbox-coder-mode
description: Enter a standing mode where this session stops writing code and delegates every coding and editing task to an unattended fork-sandbox run, acting as orchestrator, reviewer and integrator. Use when the user wants an expensive model to plan and review while cheap or self-hosted models do the typing, or wants unattended editing to happen somewhere that is not their own checkout. Stays on until the user ends it.
argument-hint: [off|--auto-preset-router] — no argument turns the mode on. Pass "off" (or say so in plain words) to end it. "--auto-preset-router" lets the orchestrator route each round to the machine preset that fits the task — see "The auto-preset router". "--long" is accepted and changes nothing: the long-horizon discipline is the default — see "Running long".
user-invocable: true
---

# Sandbox Coder Mode

A standing mode, not a one-shot task. From the moment the user invokes it
until they end it, this session writes no project code — with the
deliberate carve-outs **What gets delegated** makes for small compiled
edits and for prose. It reads, plans, delegates the editing to
`fork-sandbox` runs, reviews what comes back, and integrates it in the
real repo.

The mode is built to run long — many rounds across hours — and the
discipline that takes is part of the mode, not a variant: see **Running
long**. (`--long` is accepted for compatibility and changes nothing.)

Read the `fork-sandbox` skill before the first launch. It owns the
mechanics — branch naming, the handoff document, the harnesses, monitoring,
what the sandbox gives up. This file owns the mode: what stays here, what
goes out, and how to run several rounds without losing the thread.

## Why the mode exists

**Token economics.** This session can be the expensive model, because it
spends its tokens on reading, planning, reviewing and integrating — not on
generating the bulk of the code. The typing in the sandbox runs whatever is
cheap: a smaller claude model, `pi` against OpenRouter, or `pi-local` against
a self-hosted endpoint, which costs nothing at all. The in-sandbox review
leg (tier 3, see **Entering the mode**) is the deliberate exception: it runs
the expensive model too, by default, because catching a defect before it
ever leaves the sandbox is worth that model's price — the economics argument
is about where the *bulk* of the tokens go, not a ban on the expensive model
appearing in a sandbox at all.

**Permissions.** The user does not want `--dangerously-skip-permissions`, or
even auto mode, on their own box. A sandboxed run already bypasses every
permission check — inside a throwaway clone with no secrets, no ssh keys and
no tailnet. That is where unattended editing belongs. Nothing this session
runs on the host needs to be more permissive than it already is.

Both reasons collapse if the harness is unpinned. Pin the model on every
launch — see **Choosing a harness and a model**.

## Stay high level (the default)

High-level operation is the mode's default, not a special tier:

- **The orchestrating session reads to plan, then stops reading.** It does
  not read the code a sandbox writes; it reads the run's five-line report,
  the review verdicts, and the diffstat, and spot-checks only what executes
  on the host (Makefile, package.json scripts, shell scripts, Dockerfile).
- **Every handoff demands a five-line report** as the run's last message:
  files touched, test result as `N ok / M fail`, one line per non-obvious
  decision, what was left open, what the session is unsure of. Nothing else.
- **The user's narrative outranks implementation detail.** When the user is
  describing a world, a feel, a product, answer in that register — vision,
  shape, the read of a screenshot, the two decisions that are the user's —
  never file names and line numbers unless asked.
- **Findings from a review are split by file ownership into fix rounds**;
  this session never fixes them by hand, except the few-line case the
  threshold already allows.
- **Screenshots and shape summaries go to the user; mid-run noise does not.**
  The monitor this mode arms on `--monitor-terminal` is silent until the
  terminal state, so a mid-run update that changes nothing gets no line at
  all.
- **"Stay high level" only needs to be said once.** The mode does not need
  to hear it again. "Exit sandbox coder mode" is the only thing that ends it.

This posture is the default; it does not need to be asked for.

## Entering the mode

Before the first launch, read `~/.config/fork-sandbox/coder-mode.env` if it
exists — `cat` it, or use the Read tool, either is fine — and note the
effective launch defaults; see **Choosing a harness and a model** for what
it can override and what a missing file means. The announcement below
names those defaults in one clause, worded from what was actually read, not
from the example text here, so a machine whose config overrides them
announces what it will actually do.

When the file sets `CODER_MODE_PRESET`, the composition lives in
`~/.config/fork-sandbox/presets/<name>.yaml` instead of in per-flag keys:
read that file too, and word the announcement from what it says — see
**The machine's composition can be a preset** for the key's rules.

When the mode is invoked with `--auto-preset-router` (or the machine sets
`CODER_MODE_AUTO_PRESET_ROUTER=1`), also list
`~/.config/fork-sandbox/presets/` and read every preset there — the header
comment is its author's statement of intent, the `agents`/`pipeline` body
is what it actually runs — and name the roster in the announcement, so the
user hears which presets rounds will be routed among. See **The
auto-preset router** for the routing rules.

Tell the user, in one or two lines, stating plainly that this session will
stay high level:

> Sandbox coder mode is on. I'll read, plan, review and integrate; the actual
> editing goes to sandboxed runs on their own branches — sonnet implements,
> opus reviews, up to two review rounds. I'll report each round with its
> cost and flag anything unpushed. Say "exit sandbox coder mode" when you
> want me writing code here again.

Then carry on with whatever they asked for. Do not re-announce the mode on
every turn.

### Running long — many rounds across hours

Everything above still holds at any length. The reason it is written down
this firmly is what happens at scale: a few extra failure modes show up —
the handoff gets skimmed instead of followed, a round finishes without
committing, a run's own summary turns out to be wrong. None of that is
visible in a single round; it only shows up on the third or fourth one,
hours in, when nobody is re-reading this file. The rest of this document
describes the mode; this section describes what running long demands.

**The tiers.** Three, and the distinction between them is the whole point:

- **Tier 1 — orchestrator and reviewer.** The expensive model: this session.
  It reads the code to decide the design, writes the handoffs, reviews each
  round per **Stay high level** — the report, the verdicts, the diffstat,
  and a spot-check of what executes on the host — integrates, and owns all
  host-side git (see **What stays in this session**). It writes no project
  code.
- **Tier 2 — implementer.** The cheap model, in the sandbox. It types, at the
  default `--harness claude --model sonnet` — or a `pi` / `pi-local` harness
  when a per-round reason calls for one — per **Choosing a harness and a
  model**.
- **Tier 3 — in-sandbox reviewer.** On by default, via `--review-model opus
  --review-loop 2`. A fresh opus session reviews tier 2's work before it
  ever leaves the sandbox; drop below the default only for a stated reason.

**Tier 1's review is never skipped because tier 3 ran.** This is the
load-bearing rule of the whole arrangement:

> A round came back having passed its own suite, having grown a test file
> from 88 to 125 checks, with `shellcheck` clean. Reading the diff found a
> real defect anyway: the implementer had ported a helper from a sibling
> script but dropped a pipe to `awk` that was masking git's exit status.
> Under `set -euo pipefail` the rewritten version killed the script on a
> failed `rev-parse`, making three error paths unreachable — paths the same
> commit had written as if they were reachable. No test caught it, and no
> test would have: the suite proves the happy path, and the failure needed a
> reader who knew why the original had a pipeline in it.

Tests prove behaviour the author thought of. Tier 1 catches the thing the
author did not think of. Budget for that reading; it is what the expensive
model is for, and it applies at **Reviewing and integrating** step 1 on
every round, tier 3 or not.

**Decide the open questions before delegating.** If a handoff contains an
open question, the implementer will answer it — and it will answer as a
cheap model with no context answers, then build on the answer for the rest
of the round. You pay a whole round to undo that. Resolve every design
question first, write the decision **and its rationale** into the handoff
(see **Writing the handoff**), and say plainly "implement this, do not
revisit it." Where a question genuinely belongs to the user, ask the user
before launching, not the sandbox.

Where a question has a right answer that is not obvious, give the answer
*and* the reason in the handoff, so the implementer neither guesses nor
re-derives it: often the local equivalent already answers it, and matching
it is what keeps the two paths analogous.

**Front-load the commit contract.** The failure mode: a round does all its
work correctly, never commits, and the launcher fetches an empty branch and
deletes it. The work survives only because the clone is still on disk. This
is neither hypothetical nor rare — rounds routinely finish complete, correct
work and then only *offer* to commit, and some never commit at all.

The instruction lives in the handoff, which is read once at the start —
hundreds of tool calls before it matters. So put a **commit contract at the
very top of the handoff**, before the goal, as its own section; state the
failure; and give an explicit per-section commit sequence, so committing is
a step in the plan rather than a virtue to remember.

While a run is in flight, `fork-sandbox-say.sh` (see **Iterating on a
run**) can nudge a session that is accumulating work without committing.
Watch the commit count in the run's status block and use it.

**Verify the run's self-report.** A finished run tells you what it did; do
not take it at face value. Its commit count can disagree with the event
stream's (the stream includes `git commit` calls inside test scaffolds' own
scratch repositories too), and a run that explains a shortfall as
"environmental" is making a claim only the host can settle. Re-measure on the host: run the
suites yourself, per **Reviewing and integrating** step 4, and read the
diffstat rather than the prose summary. The run's own account is a lead, not
a finding.

**The rescue procedure.** When a run ends without committing, the work is
still in the clone. Recover it without ever running git inside that clone
(see the "never run git inside the clone" warning under **Reviewing and
integrating**):

```bash
diff -rq --exclude=.git <origin-repo> <run-dir>/clone/<name>
```

then copy the differing files out and commit them in the real repo. Never
`git -C` the clone — its config is sandbox-writable and a key such as
`core.fsmonitor` executes on the host. Record such a round as `rescued` in
the run log (**Tracking every round**).

**One round owns one set of files.** Per **Parallelism**, two rounds may run
at once only when they touch disjoint files, split by file and never by
topic. The sequencing consequence over a long horizon: **merge each
reviewed round before launching the next one that touches the same files.**
A round branches from `HEAD` at launch and cannot see a sibling's work, so
leaving a reviewed branch unmerged buys a conflict for nothing.

**Talking to the user across a long horizon.** The user is not watching the
run. They are doing something else and checking in. That shapes the
reporting:

- Report each round in a few lines — branch, what landed, whether tests
  pass, the cost, and any caveat, including one that contradicts the run's
  own summary — per **Reviewing and integrating**.
- Quote the cost every round. It varies by an order of magnitude between
  rounds of similar size, and it is the number that decides the next
  round's harness. The
  default `--review-loop 2` with `--review-model opus` means up to two
  opus review legs and two sonnet fix legs on top of the coding session
  itself, so a round at the defaults can cost materially more than a
  single-pass run.
- A mid-turn ask is not an interrupt. When the user fires off a new idea
  while a round is in flight, acknowledge it in one sentence, keep the
  current work moving, and start it at the next natural break — unless it
  changes the work in flight or corrects a premise it rests on, in which
  case handle it now.
- Never state a background run's outcome before it lands. A run that is
  still going has no result to report, and a monitor event is not the user
  speaking.
- Say what is still unpushed. Over a long session, integrated-but-unpushed
  work accumulates silently. Name the count.

**Ending a long round.** Per round, in order: read the diffstat and
spot-check what runs on the host, run the suites on the host, integrate,
record the verdict with `sandbox-run-log.py verdict`, and report — the same
sequence as **Reviewing and integrating**, at the high-level default from
**Stay high level**.
Keep the run directory until the branch is reviewed and merged — it is the
only copy of the events log, and it is the evidence when something needs
explaining later.

## What stays in this session

Everything that is not writing project files:

- Reading code, searching, and running read-only commands (`git log`,
  `git diff`, `find`, `grep`, the project's own read-only tooling).
- Answering questions, explaining code, and designing the change.
- Deciding what to delegate, and writing the handoff.
- Reviewing what comes back — the report, the review verdicts and the
  diffstat by default; the diff itself only per **Stay high level**.
- **All git that writes**, in the real repo: `commit`, `merge`, `rebase`,
  `cherry-pick`, `push`, tags. A sandbox cannot push and has no credential
  for anything remote, so integration is this session's job and only this
  session's job.
- Running the project's tests on the host, once the branch is reviewed.
- Anything needing a secret, the tailnet, or a service credential.

## What gets delegated

Run this mode as a **compiler**. The user↔session channel carries
idea-space — goals, shapes, problems, including problems about code — and
this session's whole job is compiling that into coding instructions: a
design, a plan, a handoff. The compilation itself is never delegated. It
is what the expensive model is for, and it is where the leverage is: a
fork never carries an idea, only a compiled instruction, so fork quality
IS compile quality.

A direct coding instruction from the user ("rename X to Y", "apply this
diff") arrives already compiled and enters at the join. Either way the
pipeline converges on the same state — coding instructions exist, held by
this session — and from there the work dispatches by the instruction's
compiled **shape**, never by its origin:

- **Small and self-contained** — right by reading, a few lines across a
  file or two — executes in-session, whether it began as an idea or an
  instruction. An idea that compiles to a one-liner runs here; a sandbox
  costs a clone, a run, a review and a merge, a bad trade for a change
  you can read and be sure of.
- **A build** — multi-file, wants its own review loop, or has scale (a
  migration, a sweep) — forks a sandbox carrying the compiled
  instruction, and this session reviews what returns. A direct-but-huge
  instruction still forks: origin does not exempt it from scale.
- **Prose that matters** — public-facing docs, READMEs, skill text — is
  written in-session, on the highest model available, the same shape as
  review and with no new configuration. (Not a per-kind model registry;
  just the one rule.)
- **Review** never forks: it is the far end of the same pipeline — the
  compiler checking what came back against what it emitted.

This amends the mode's headline. "This session writes no project code"
still describes every build — the bulk typing always happens in a
sandbox — but compiled output that is small, and prose whose quality is
the point, are written here, deliberately.

Also always written here, since a sandbox cannot see them: files outside
the project — scratch files, notes, and the handoff documents themselves.
And a change the user explicitly asks this session to make by hand.

**The threshold is confidence, not line count.** Make the edit here when you
can tell it is right by reading it, and the whole change stays within a few
lines across a file or two. Send it to a sandbox when it needs a plan, spans
several files, or can only be shown correct by running something — a test
suite, a build, a render.

Do not stand up a sandbox to fix three lines. The overhead is real and it is
paid in wall-clock, tokens and your own attention; a round trip that costs
more than the work is not caution, it is ceremony.

When a "small" edit turns out to need a second and a third, stop and delegate
the rest. The signal is not the size you estimated, but the size it is turning
into.

## Before every launch

1. **Commit the working tree.** A clone carries committed state only.
   `fork-sandbox.sh` warns about a dirty tree but launches anyway, and the
   session then works from stale code. As the integrator, this session is
   the one holding uncommitted work — check for it every time.
2. **Pick a free branch name**, kebab-case, `sbx-` prefix. The script refuses
   a name that already exists, which matters here because a second round on
   the same task wants a related name (`sbx-parser-fix`, `sbx-parser-fix-2`).
3. **Do the reading first.** That is the whole point of the arrangement.

## Writing the handoff

The `fork-sandbox` skill lists the required sections and the constraints —
no global `~/.claude`, no secrets, no network credentials, name the test
command in full, tell the session to commit. All of that still applies.

What this mode adds: **the handoff carries the plan.** This session has
already read the code and decided the approach. Write that down — the files
to touch, the shape of the change, the interfaces involved, what to leave
alone — instead of shipping the bare goal and paying a cheaper model to
rediscover it. That is the trade that makes the economics work: the reading
happened here once, at the good model's price, and every round after it
starts from the answer.

Say what is out of scope, too. An unattended session with no one to ask will
otherwise widen the task on its own.

## Launching and watching

The flags below are the shipped defaults from **Choosing a harness and a
model** — substitute the effective values noted at **Entering the mode** if
`coder-mode.env` overrides any of them (including adding `--review-harness`
or the `--maintainer-*` trio, which the shipped defaults don't set), and see
**Reasons to deviate for one round** before changing `--harness` for a
single launch.

```bash
fork-sandbox.sh --harness claude --model sonnet --review-model opus --review-loop 2 \
    --branch "<branch>" \
    --task-meta '{"kind":"implement","difficulty":3,"size":"m","prompt_template_id":"<slug>"}' \
    "<project-path>" "<handoff-file>"
```

On a machine whose `coder-mode.env` names a preset, the composition flags
collapse into it — the task-shaped flags stay on the command line, since a
preset deliberately cannot carry them (see `docs/presets.md`):

```bash
fork-sandbox.sh --preset <name> \
    --branch "<branch>" \
    --task-meta '{"kind":"implement","difficulty":3,"size":"m","prompt_template_id":"<slug>"}' \
    "<project-path>" "<handoff-file>"
```

`--task-meta` feeds the run log (see **Tracking every round**). Pass it on
every launch — it is this session's assessment of the task, which nothing
downstream can reconstruct.

Keep the run directory the launcher prints — every later command takes it.
Then arm the Monitor tool on the command it printed:

```
fork-sandbox-status.sh --monitor-terminal <run-dir>
```

Never hand-roll a poll loop. When the user wants to watch a run live in
their own terminal, give them `fork-sandbox-status.sh --follow <run-dir>`
and keep the Monitor on `--monitor-terminal`.

For a long run on the `claude` or `codex` harness, check the access token
right after launch: the sandbox snapshots it and cannot refresh it, so a run
started late in a token's life dies partway with nothing committed.

Both warn only when the token is nearly spent, so silence is the good case,
not a missing reading. `claude-sandboxed` prints a warning under 60 minutes
and refuses outright at zero; it reaches `fork-sandbox-status.sh --log
<run-dir>`, which otherwise says nothing about the token. codex's warning
lands on the launcher's own output. Neither reports the lifetime when there
is plenty left, so an empty log means "over an hour", not "unknown" — and
there is no command that will tell you the number.

## Parallelism

Two runs at once are fine when they touch **disjoint files**. Two runs that
touch the same file produce two branches that conflict, and this session
resolves the conflict by hand — which costs more than running them in
sequence.

The rule: split by file, not by topic. If the plan cannot say which files
each run owns, it is one run.

Each run needs its own `--branch`. To fan out, launch them back to back,
then arm one Monitor per run directory. They are independent; a failure in
one says nothing about the others.

A run started now branches from the repo's current `HEAD`, so it cannot see
a sibling's work. When run B needs run A's changes, it is not parallel —
merge A first, then launch B.

There is no registry of sandbox runs to query; `agent-registry.sh` records
interactive `fork-task.sh` launches only. Keep the branch, the run directory
and the task in this session's own notes. Live runs do show up as detached
tmux sessions named `cc-sbx-<branch>`, and they close when the run ends:

```bash
tmux list-sessions
```

## Iterating on a run

**A small course correction is an addendum, not a new round.** A run in flight
can be steered:

```bash
fork-sandbox-say.sh <run-dir> "The API changed under you — parse() takes a dict now, not a string."
```

It lands on the session's next tool call (`claude`) or within ~25 tool calls
(`pi`, `pi-local`, `codex`), and it carries the same authority as the
handoff, so it may override it. See "Steering a run" in the `fork-sandbox`
skill.

Prefer an addendum when the run is broadly on track and one fact changed: a
detail you got wrong in the handoff, a file it should not touch, an extra
acceptance criterion, a dead end you can see it walking into in the run's status block.
The run keeps everything it has already done.

Prefer a **new round** when the handoff itself was wrong — the wrong goal, the
wrong approach, or so much missing context that the addendum would be longer
than the correction. Steering does not repair a bad premise; it just spends the
rest of the run acting on it. If you find yourself writing a third addendum to
the same run, that is the signal.

**A run can continue itself, but only for one reason: running out of room.**
`fork-sandbox.sh --refresh-at` (on by default) nudges a session that fills
its own context to write a hand-off and end its turn, then forks a fresh
session on the *same* clone and branch to keep going from it — automatically,
with the same handoff and the same goal, no orchestrator involvement. That is
the whole of what it does. It does not read a review, does not change
direction, and does not know the branch came back wrong; it exists purely so
a long task does not degrade into compaction partway through. Nothing here
changes because of it.

What there is still no flag for is resuming with NEW instructions — a
different handoff, a corrected approach, or one round applying what a review
found. `fork-sandbox.sh` starts a fresh session every time, and the sandbox
is destroyed with its clone, so THAT kind of second round is a new run that
starts from the first one's branch. Same shipped-default flags as
**Launching and watching** above, substituted the same way:

```bash
fork-sandbox.sh --harness claude --model sonnet --review-model opus --review-loop 2 \
    --branch "<branch>-2" --checkout "<branch>" \
    "<project-path>" "<handoff-file-2>"
```

`--checkout` resolves the ref in the **real** repo — which is where round
one's branch was fetched to — and moves the base the new commits are
measured against, so the second run's summary shows only the new work.

If the first branch is already merged into the working branch, drop
`--checkout` and launch from `HEAD` as usual.

The second handoff is a new document, not a diff against the first. The new
session has no memory of the previous one and cannot read its log. Write out
what round one produced, what is wrong with it, and what to change — the
review comments in full, not a pointer to them. Naming the previous commits
is still useful, since the branch is checked out in the clone:

```bash
git log --oneline "<branch>"
git show "<branch>"
```

When a run comes back badly wrong, consider whether the handoff was the
problem before spending another round on the same instructions. A cheap
model that misread the task will misread it again.

## Reviewing and integrating

1. **Read the diffstat, and spot-check what runs on the host, before
   building anything.** Per **Stay high level**, this session does not read
   the code a sandbox writes — but a `Makefile`, a `package.json` script, a
   shell script or an `.envrc` in the branch runs on the host the moment
   anyone builds it. Treat those exactly as a pull request from a stranger —
   this is the `fork-sandbox` warning, and in this mode it applies on every
   round rather than once.

   ```bash
   git log --oneline HEAD.."<branch>"
   git diff --stat HEAD.."<branch>"
   ```

   Pull the full `git diff HEAD.."<branch>"` only when something calls for
   it: the diffstat touches a host-executed path, the review verdict flagged
   something the fix round may not have fully settled, or the user asks to
   see the code.

   **Never run git inside the clone** — not `log`, not `status`, not
   `git -C`. The clone's git config is writable by the sandbox, and a key
   such as `core.fsmonitor` makes any git command there run on the host with
   the ssh keys and the tailnet. The branch is in the user's own repo now;
   read it there.

2. **Read the report** of what the reviewer observed:
   `fork-sandbox-status.sh --result <run-dir>` leads with the review report
   when `--review-loop` ran, then shows the session's own account; the split
   matters because the report is based on the branch and diff, while the
   session account is the author's claim. For a run without a review report,
   read the session account as before, or
   `<run-dir>/events.jsonl` for `pi`, `pi-local` and `codex`, which write
   plain text the formatted views cannot render.

3. **Integrate in the real repo**: merge, rebase or cherry-pick onto the
   working branch. These prompt for permission, and that friction is the
   point — this is the one place host state changes. When the branch
   modifies code other things already run through, see **One more pass
   before you merge** first.

4. **Run the tests on the host.** The sandbox's pass is evidence, not proof:
   it had no network, and possibly no dependencies the suite wanted.

5. **Push only if the user asks.** No sandbox can.

6. **Record the verdict** — what the review found, which the log cannot know
   by itself. The run id is the run directory's basename; capture it before
   the cleanup below deletes the directory:

   ```bash
   sandbox-run-log.py verdict <run-id> --outcome integrated-with-fixes \
       --defects 2 --notes "selection off-by-one; missing test for empty set"
   ```

7. **Clean up** once the branch is reviewed: `rm -rf <run-dir>`.

Report each round in a few lines — branch, head commit, files touched,
whether tests passed, what the run cost, and any caveat the session raised.

## One more pass before you merge

`--review-loop` reads the diff. It is good at that, and it is not the same
thing as reading what the diff does to the code around it — the callers,
the sibling features, the paths that already ran through the file being
changed. The loop never opens those, because they are not in the diff, and
neither does a green suite: the suite exercises what someone already
thought to write down.

So, as a habit before merging: when a branch **modifies** code that other
things already run through — an engine file, a shared helper, a state
container, a hot path — spend one more review on the branch as it will be
merged, with the strongest model available. Launching the run with
`--maintainer-loop 1 --maintainer-model opus` does exactly this pass at
the end of the run — a fresh session reviewing the merged shape the way a
maintainer would, after the loop's verdict — with no hand-off to write.

For a branch that is already back and was not launched with that tier,
the pass is one review-only run over it:

```bash
fork-sandbox.sh --review-only --checkout "<branch>" \
    --harness claude --model opus "<project-path>" "<review-handoff>"
```

Adding a new self-contained file does not earn a pass; modifying a file
other code depends on does. `git diff --diff-filter=M HEAD.."<branch>"` is
the whole test — when it comes back empty, or names only the branch's own
new tests, the loop's word is enough.

This neither replaces `--review-loop` nor lowers it. The loop still runs on
every round, in the sandbox, at the user's composition; this is one pass on
top, at the end, over the merged shape instead of over each round's diff.

**On the manual pass, say that in the review handoff** — the
`--maintainer-loop` prompt already carries the framing — or the pass
drifts back into reviewing the branch and buys a third opinion on a diff
that already has two. Tell it:
this diff has already been reviewed, twice, line by line, so re-reading it
for the same class of defect will find the same things; what has *not* been
looked at is the blast radius — who calls this, what assumed the old
behaviour, and what now runs on every frame or every request. That
instruction is the difference between the pattern working and being an
expensive third reviewer.

> Measured on one feature, 2026-08-30. The in-sandbox reviewer passed it
> twice, with real findings each time, and this session read the diff and
> passed it too. One `--review-only` pass on a stronger model then found
> eight, among them an unconditional `TypeError` that killed the join for
> every user — the new code assumed a shape of entity that much of the
> existing world does not have. The fix round went back through the loop,
> which passed it twice again; a second strong pass found ten more, three
> blocking, one a regression already visible in production. The suite was
> green for all of it. Every miss had the same shape: not a defect in the
> diff, a defect in what the diff did to code that was not in it.
>
> Read that as two passes on one feature, not two cases — and the feature
> was picked because it already had the shape above, shared per-frame code
> and a tick loop. It says the pass earns its money on that shape. It does
> not say how often the shape occurs, or what a pass finds on a branch that
> lacks it.

It is a habit, not a gate. Nothing enforces it and nothing should — blocking
a push the user asked for is its own kind of wrong. It costs roughly ten
minutes and a few dollars, so skip it when the change does not warrant that,
and say plainly that you skipped it.

## Tracking every round

Every run appends its own mechanics to `~/.claude/sandbox-runs.jsonl` when it
ends — harness, model, exit code, commits, tokens, cost, and an archived copy
of the handoff. The two halves only this session knows are the launch-time
`--task-meta` and the post-review verdict above. With all three in place the
log is a performance database of model+harness+prompt combos, which is what
makes prompt iteration measurable instead of anecdotal.

Recommended `--task-meta` fields (the full vocabulary is in
`sandbox-run-log.py`'s header):

- `kind`: implement | fix | refactor | test | docs | investigate | review
- `difficulty`: 1-5, this session's own assessment
- `size`: xs-xl, the expected scope
- `prompt_template_id`: a slug naming the handoff *shape*. Coin one when
  trying a new shape, then reuse it exactly — the point is comparing shapes
  across runs.
- `stage`, `tags`: free-form

Verdict outcomes: `integrated`, `integrated-with-fixes`, `rescued` (the run
died; its work was recovered from the clone and used), `rejected`,
`abandoned`.

Consult the record when picking the next round's harness, model or prompt
shape:

```bash
sandbox-run-log.py stats --by model,task.kind
sandbox-run-log.py stats --by task.prompt_template_id --kind implement
sandbox-run-log.py list --days 14
```

## Choosing a harness and a model

The default launch is:

```
--harness claude --model sonnet --review-model opus --review-loop 2
```

That is what to launch with when no per-round reason says otherwise. It is
overridable per machine, never per repo: if
`~/.config/fork-sandbox/coder-mode.env` exists, its keys replace the
matching flag's default and every other flag keeps its default. A missing
file, or a key absent from it, means the default above.

| key | flag | default |
|---|---|---|
| `CODER_MODE_HARNESS` | `--harness` | `claude` |
| `CODER_MODE_MODEL` | `--model` | `sonnet` |
| `CODER_MODE_REVIEW_HARNESS` | `--review-harness` | unset (same as `--harness`) |
| `CODER_MODE_REVIEW_MODEL` | `--review-model` | `opus` |
| `CODER_MODE_REVIEW_LOOP` | `--review-loop` | `2` |
| `CODER_MODE_MAINTAINER_HARNESS` | `--maintainer-harness` | unset (same as `--harness`) |
| `CODER_MODE_MAINTAINER_MODEL` | `--maintainer-model` | unset — **required** to run the tier |
| `CODER_MODE_MAINTAINER_LOOP` | `--maintainer-loop` | unset (no maintainer tier) |

1. **A harness's keys move together.** `sonnet` and `opus` are claude model
   names. A file that sets `CODER_MODE_HARNESS` to anything else must also
   set `CODER_MODE_MODEL` and `CODER_MODE_REVIEW_MODEL` to names that
   harness understands — the review model is resolved against the review
   harness when one is set and against the implement harness otherwise, so
   a `pi` machine that leaves the review model at `opus` sends its review
   legs a model id that does not exist. Set `CODER_MODE_REVIEW_HARNESS`
   only to run the review legs under a different harness than the typing;
   it does not change which model name they need.
2. **`pi-local` paired with a networked review harness costs money.** The
   implement leg stays sealed either way, but `CODER_MODE_HARNESS=pi-local`
   with a `CODER_MODE_REVIEW_HARNESS` of `claude`, `pi` or `codex` sends
   the review leg's contents to that harness's model provider, and the
   script only warns about this by name rather than refusing it — see
   `README.md`'s `--harness pi-local --review-harness claude --review-model
   opus --review-loop 2` for the recipe this exists to unblock. Leave the
   review harness unset, or `pi-local`, to keep the whole run sealed.
3. **`CODER_MODE_REVIEW_LOOP=0` means no in-sandbox reviewer**: omit
   `--review-loop`, `--review-model` and `--review-harness` from the
   launch, all three — the script refuses `--review-harness` without
   `--review-loop`, and refuses `--review-loop` set to `0` on the command
   line.
4. **The maintainer keys follow the same rules, with one inversion.**
   Unset (or `0`) `CODER_MODE_MAINTAINER_LOOP` means no maintainer tier:
   omit all three `--maintainer-*` flags, as in item 3. When the loop is
   set, `CODER_MODE_MAINTAINER_MODEL` is **required** — unlike the review
   model, the maintainer model has no default, because its verdict is the
   run's last word on the branch (`fork-sandbox.sh` refuses the loop
   without a model). The harness key resolves the model name exactly as
   item 1 describes for review, and a sealed `pi-local` implement with a
   networked maintainer harness warns by name exactly as item 2 describes
   — a maintainer leg sends the clone's contents to that harness's
   provider just as a review leg does.

No script reads this file — `fork-sandbox.sh` itself has no idea it exists.
Reading it is this session's job, done once per **Entering the mode**,
because a script that read it would make these flags the default for every
caller of `fork-sandbox.sh`, not just coder mode. `fork-sandbox.sh configure`
does not write it either — its target allowlist is deliberately hardcoded
(see [configure.md](../../docs/configure.md)); this file is written by
hand, by whoever set up the machine.

### The machine's composition can be a preset

`CODER_MODE_PRESET=<name>` replaces the whole table above: the composition
then lives in `~/.config/fork-sandbox/presets/<name>.yaml` (the format and
override rules are `docs/presets.md`), and every launch passes `--preset
<name>` in place of the per-flag spelling. The per-flag keys must not also
be set — a file carrying both is a config error to surface to the user,
never to resolve silently, because two sources for one composition is
exactly what this key exists to remove. `coder-mode.env` then holds only
the pointer, plus any mode keys that are not composition (the router key,
for one).

Everything else in this section applies unchanged. A per-round deviation
is flags stacked on top of `--preset` — a flag beats its preset
counterpart key by key, and a harness override drops that seat's preset
model, arguments and repeat ("Flags override, key by key" in
`docs/presets.md`) — announced with its reason exactly as before, and the
review composition is still never lowered: see the next sections.

### Reasons to deviate for one round

Pick per task, and say why in one line when you launch:

| Task | Harness | Cost (this leg) |
|---|---|---|
| Mechanical, high-volume, exploratory — a test sweep, a rename, a data-shape investigation | `--harness pi-local` | nothing — unless the round's `--review-harness` is networked, which prices the review leg separately (see item 2 above) |
| Ordinary implementation with a clear plan | `--harness claude --model sonnet` (the default) | subscription |
| Work where the model quality decides the outcome | `--harness claude --model opus` | subscription |
| A second opinion from outside the family | `--harness pi --model <openrouter-id>` or `--harness codex` | real money / ChatGPT sign-in |

The review flags travel with `--harness`, not with this table: a round
that deviates from the machine's harness restates `--review-model` (and
`--review-harness`, if the reviewer should run elsewhere) in names that
harness understands. Deviating on the harness never drops the review leg:
the only round that runs without one is the medium-model one-shot in the
next section, and that is an upward deviation on the implementer, not a
review omission.

### The review loop is the user's setting, not the orchestrator's

The composition the user launched the mode with — or the machine file
above — has two tiers in it: `--model` is the *light* model that types,
`--review-model` is the *medium* model that reads, and `--review-loop` is
how many times. A machine file that sets the maintainer keys adds a third:
the model that judges the branch the way a maintainer judging a pull
request would, after the inner loop has finished arguing. That composition
is the default for **every** round, and the orchestrator does not lower
it: not the loop count, not the review model, not the maintainer tier, not
for a round that "looks small". An implementer cannot judge its own work,
and the orchestrator cannot judge its own spec; neither decides whether a
review — inner or maintainer — runs.

The one permitted deviation is **upward on the implementer, never downward
on the review**: a change small enough that a loop is plainly overkill goes
to the *medium* model one-shot, and the orchestrator reads the diff itself.
"Light model, no review" is not a composition the orchestrator may choose.
The bar for even that is very high confidence about the *spec*, not the
task: the files are named, the change is written out line by line, no
security property is touched, and the implementer is left no choice to
make. Any latitude at all, and the default stands. Doubt resolves toward
the user's settings.

**Say what you are using whenever it is not the default.** One line at
launch, every flag spelled out, and the reason — extremely verbose, zero
ceremony:

> Launching `sbx-review-cleared-fp` with `--harness claude --model opus`
> and no review loop, not the session's `--model sonnet --review-loop 1
> --review-model opus`: the handoff names both files and gives the regex,
> the three lines, and all ten test cases, so the implementer has nothing
> to decide; I read the diff.

A launch at the default needs no such line. A launch that deviates and
does not carry one is a launch the user cannot audit.

### The auto-preset router

`--auto-preset-router` on the mode's invocation — or
`CODER_MODE_AUTO_PRESET_ROUTER=1` in `coder-mode.env` as the machine
default — moves one decision, *which preset*, from the user to the
orchestrator. On entering the mode, read every preset in
`~/.config/fork-sandbox/presets/` (see **Entering the mode**). Then route
each round to the preset whose shape fits the task's — the same judgement
`--task-meta` already records: a mechanical sweep or rename to the
cheapest single-leg preset, an ordinary implement to the machine's
default, a change that modifies code other things already run through to
the deepest composition available (one with a maintain step, when one
exists).

This does not repeal the previous section; it relocates it. Every preset
in the roster was authored by the user for this machine — that authorship
is the consent the previous section demands — and the router picks whole
presets, never composes flags of its own and never edits a preset
downward. Two rules keep it auditable:

- **Announce every routing decision.** One line at launch: the preset
  chosen and the task-shape reason. A routed launch always gets the line,
  even to the default preset — with the router on, silence would leave
  the user unable to tell a decision from a habit.
- **Doubt resolves upward.** When the task's shape is ambiguous, or no
  preset fits it, launch on the machine's default composition — never on
  a cheaper preset because the task "looks small". The one permitted
  deviation above (upward on the implementer, never downward on the
  review) binds the router exactly as it binds a flag deviation.

Without the flag or the env key, nothing changes: the machine's one
composition is the default for every round, and preset choice is not the
orchestrator's to make.

**Pin `--model` on every claude run.** Without it the run takes the host's
default, which is the expensive model this session is likely running on —
and the mode's whole reason for existing is gone. The defaults above are
that pin; only spell the flags out again when deviating from them.

`pi-local` is sealed: no network at all, so nothing can be installed or
fetched in there. Say in the handoff what is already provided, or the run
spends itself discovering it cannot `npm install`.

Check what a round actually cost before choosing the next one's harness:

```bash
fork-sandbox-status.sh --json <run-dir> | jq .cost_usd
```

`--json` also carries the token counts and the harness version. A `pi-local`
run reads a zero cost; a codex run reports tokens and a null cost.

## When a single round of review isn't enough

`--review-loop N` is one reviewer, on one model, arguing with one
implementation until it approves or gives up. Reach for the `lkml-mode`
skill instead when a change is substantial enough to want several
independent, adversarial voices reading it in parallel — always including
a core reviewer with the highest bar — with an iterated record of what each
asked for, whether the author addressed it or pushed back, and why: a
patch series posted to a shared mailbox, reviewed and revised through v2,
v3... the way the Linux kernel mailing list works, until the right
reviewers have signed off and no NAK stands. It costs more than one
`--review-loop` pass — several sandboxed runs per round instead of one —
so save it for changes where that scrutiny is worth paying for, not for
the everyday implement-then-review cycle this mode already covers.

## When NOT to use this mode

Drop out of it — for one task, without ending the mode — when the work needs
something the sandbox does not have:

- **Uncommitted state.** A clone carries committed files only.
- **Secrets**: an `.env`, ssh keys, an API token, a service credential.
- **A push**, or anything else touching a remote.
- **The tailnet or a VPN.** (`--sandbox-args "--unpin-egress"` reaches them,
  but it removes a restriction — use it only when the task genuinely needs
  it, and never on a `pi-local` run, which refuses it outright.)
- **An interactive session** — anything where someone has to answer a
  question mid-run, or watch a UI. That is `fork-task`, not `fork-sandbox`.
- **A change small enough to prove by reading**, per the threshold above.

Say which of these applies, do the work here, and go back to delegating.

## Leaving the mode

The mode ends when the user says so — "exit sandbox coder mode", "stop
delegating", "you can write code again", or `/sandbox-coder-mode off`.
Confirm in one line that the mode is off and that this session is writing
code directly again, and mention any sandbox run still in flight along with
its branch.

Nothing else ends it. A failed run, an urgent fix, or a long queue of small
edits is not a reason to quietly resume writing code here.
