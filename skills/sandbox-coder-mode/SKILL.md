---
name: sandbox-coder-mode
description: Enter a standing mode where this session stops writing code and delegates every coding and editing task to an unattended fork-sandbox run, acting as orchestrator, reviewer and integrator. Use when the user wants an expensive model to plan and review while cheap or self-hosted models do the typing, or wants unattended editing to happen somewhere that is not their own checkout. Stays on until the user ends it.
argument-hint: [off] [--long] — no argument turns the mode on. Pass "off" (or say so in plain words) to end it. Pass "--long" to enter the long-horizon variant, for many rounds across hours — see "Entering the mode".
user-invocable: true
---

# Sandbox Coder Mode

A standing mode, not a one-shot task. From the moment the user invokes it
until they end it, this session writes no project code. It reads, plans,
delegates the editing to `fork-sandbox` runs, reviews what comes back, and
integrates it in the real repo.

`--long` enters the same mode with a second layer of discipline for running
many rounds across hours rather than one or two — see **Entering the mode**.

Read the `fork-sandbox` skill before the first launch. It owns the
mechanics — branch naming, the handoff document, the harnesses, monitoring,
what the sandbox gives up. This file owns the mode: what stays here, what
goes out, and how to run several rounds without losing the thread.

## Why the mode exists

**Token economics.** This session can be the expensive model, because it
spends its tokens on reading, planning, reviewing and integrating — not on
generating the bulk of the code. The sandboxes run whatever is cheap:
a smaller claude model, `pi` against OpenRouter, or `pi-local` against a
self-hosted endpoint, which costs nothing at all.

**Permissions.** The user does not want `--dangerously-skip-permissions`, or
even auto mode, on their own box. A sandboxed run already bypasses every
permission check — inside a throwaway clone with no secrets, no ssh keys and
no tailnet. That is where unattended editing belongs. Nothing this session
runs on the host needs to be more permissive than it already is.

Both reasons collapse if the harness is unpinned. Pin the model on every
launch — see **Choosing a harness and a model**.

## Stay high level (the default; `--long`)

High-level operation is the mode's default, not a special tier — learned
from a real day of use:

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
- **Screenshots and shape summaries go to the user; heartbeats do not.** A
  monitor event that changes nothing gets one line, or none.
- **"Stay high level" only needs to be said once.** The mode does not need
  to hear it again. "Exit sandbox coder mode" is the only thing that ends it.

This posture is the mode's long form. `/sandbox-coder-mode --long` is the
explicit spelling of it; it is also what plain `/sandbox-coder-mode` means.

## Entering the mode

Tell the user, in one or two lines, stating plainly that this session will
stay high level:

> Sandbox coder mode is on. I'll read, plan, review and integrate; the actual
> editing goes to sandboxed runs on their own branches. Say "exit sandbox
> coder mode" when you want me writing code here again.

Then carry on with whatever they asked for. Do not re-announce the mode on
every turn.

### `--long` — many rounds across hours

Everything above still holds. `--long` is not a different mode, it is this
one run at a scale where a few extra failure modes show up — the handoff
gets skimmed instead of followed, a round finishes without committing, a
run's own summary turns out to be wrong. None of that is visible in a single
round; it only shows up on the third or fourth one, hours in, when nobody is
re-reading this file. The rest of this document describes the standing mode;
this section describes what changes when it runs long.

Tell the user, in one or two lines:

> Sandbox coder mode is on, long-horizon. I'll run this as tiers: I plan,
> stay high level, and integrate; a cheap model does the typing in the
> sandbox, with an optional in-sandbox reviewer ahead of me. I'll report
> each round with its cost, and flag anything still unpushed.

**The tiers.** Three, and the distinction between them is the whole point:

- **Tier 1 — orchestrator and reviewer.** The expensive model: this session.
  It reads the code to decide the design, writes the handoffs, reviews each
  round per **Stay high level** — the report, the verdicts, the diffstat,
  and a spot-check of what executes on the host — integrates, and owns all
  host-side git (see **What stays in this session**). It writes no project
  code.
- **Tier 2 — implementer.** The cheap model, in the sandbox. It types. Pin it
  explicitly on every launch — `--harness claude --model sonnet`, or a `pi` /
  `pi-local` harness — per **Choosing a harness and a model**.
- **Tier 3 — in-sandbox reviewer.** Optional, via `--review-loop N`. A fresh
  cheap session that reviews tier 2's work before it ever leaves the sandbox.

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

A worked example: a round had to decide what an exit-code file should hold
when an extra review pass had run — the coding leg's code or the review's.
That reads like a coin flip until you notice the local equivalent already
answers it, and matching it is what keeps the two paths analogous. The
handoff said which, and why, and "do not revisit." The round implemented it
correctly and left a comment explaining it to the next reader.

**Front-load the commit contract.** The failure mode: a round does all its
work correctly, never commits, and the launcher fetches an empty branch and
deletes it. The work survives only because the clone is still on disk. This
is not hypothetical and it is not rare: one round ran 170 turns over 25
minutes, produced complete and correct work across six files, and ended by
*offering* to commit. Two other rounds sat at 490 and 376 tool calls with
zero commits until nudged by hand. Two of five local-model runs never
committed at all.

The instruction lives in the handoff, which is read once at the start —
hundreds of tool calls before it matters. What works: put a **commit
contract at the very top of the handoff**, before the goal, as its own
section; state the failure with its evidence; and give an explicit
per-section commit sequence, so committing is a step in the plan rather
than a virtue to remember. The next round after that change produced eight
clean commits in sequence, in 17 minutes, for a third of the cost.

While a run is in flight, `fork-sandbox-say.sh` (see **Iterating on a
run**) can nudge a session that is accumulating work without committing.
Watch the commit count in the monitor and use it.

**Verify the run's self-report.** A finished run tells you what it did. Do
not take it at face value. Two real cases from one day:

- A run reported "nothing has been committed" while the monitor had reported
  nine commits. Both were right about different things: the monitor was
  counting `git commit` calls inside test scaffolds' own scratch
  repositories, and the branch genuinely had nothing on it.
- A run reported test counts below the stated baselines and explained the
  gap as environmental. That claim needed re-measuring on the host, where
  the suites are actually authoritative, before it could be believed or
  disbelieved.

Re-measure on the host. Run the suites yourself, per **Reviewing and
integrating** step 4. Read the diffstat rather than the prose summary. The
run's own account is a lead, not a finding.

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
  round's harness. One day's rounds ranged from 0.31 to 11.12 USD.
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

**Ending a long round.** Per round, in order: read the diff, run the suites
on the host, integrate, record the verdict with `sandbox-run-log.py
verdict`, and report — the same sequence as **Reviewing and integrating**.
Keep the run directory until the branch is reviewed and merged — it is the
only copy of the events log, and it is the evidence when something needs
explaining later.

## What stays in this session

Everything that is not writing project files:

- Reading code, searching, and running read-only commands (`git log`,
  `git diff`, `find`, `grep`, the project's own read-only tooling).
- Answering questions, explaining code, and designing the change.
- Deciding what to delegate, and writing the handoff.
- Reviewing the diff that comes back.
- **All git that writes**, in the real repo: `commit`, `merge`, `rebase`,
  `cherry-pick`, `push`, tags. A sandbox cannot push and has no credential
  for anything remote, so integration is this session's job and only this
  session's job.
- Running the project's tests on the host, once the branch is reviewed.
- Anything needing a secret, the tailnet, or a service credential.

## What gets delegated

Any task whose product is a change to files in the project.

The exceptions are the ones where a round trip costs more than the work:

- **A small, self-contained edit** — a typo, a comment, a wording fix, a few
  lines across a file or two. A sandbox costs a clone, a run, a review and a
  merge; that is a bad trade for a change you can read and be sure of.
- Files outside the project: scratch files, notes, and the handoff documents
  themselves. The sandbox cannot see them, so they can only be written here.
- A change the user explicitly asks this session to make by hand.

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

```bash
fork-sandbox.sh --model sonnet --branch "<branch>" \
    --task-meta '{"kind":"implement","difficulty":3,"size":"m","prompt_template_id":"<slug>"}' \
    "<project-path>" "<handoff-file>"
```

`--task-meta` feeds the run log (see **Tracking every round**). Pass it on
every launch — it is this session's assessment of the task, which nothing
downstream can reconstruct.

Keep the run directory the launcher prints — every later command takes it.
Then arm the Monitor tool on the command it printed:

```
fork-sandbox-status.sh --monitor <run-dir>
```

Never hand-roll a poll loop. When the user wants to watch a run live in
their own terminal, give them `fork-sandbox-status.sh --follow <run-dir>`
and keep the Monitor on `--monitor`.

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
acceptance criterion, a dead end you can see it walking into from the monitor.
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
starts from the first one's branch:

```bash
fork-sandbox.sh --model sonnet --branch "<branch>-2" --checkout "<branch>" \
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

1. **Read the diff before building anything.** The fetched branch is
   agent-written code. A `Makefile`, a `package.json` script or an `.envrc`
   in it runs on the host the moment anyone builds it. Treat it exactly as a
   pull request from a stranger — this is the `fork-sandbox` warning, and in
   this mode it applies on every round rather than once.

   ```bash
   git log --oneline HEAD.."<branch>"
   git diff HEAD.."<branch>"
   ```

   **Never run git inside the clone** — not `log`, not `status`, not
   `git -C`. The clone's git config is writable by the sandbox, and a key
   such as `core.fsmonitor` makes any git command there run on the host with
   the ssh keys and the tailnet. The branch is in the user's own repo now;
   read it there.

2. **Read the session's own account** of what it did:
   `fork-sandbox-status.sh --result <run-dir>` for a claude run, or
   `<run-dir>/events.jsonl` for `pi`, `pi-local` and `codex`, which write
   plain text the formatted views cannot render.

3. **Integrate in the real repo**: merge, rebase or cherry-pick onto the
   working branch. These prompt for permission, and that friction is the
   point — this is the one place host state changes.

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

Pick per task, and say why in one line when you launch:

| Task | Harness | Cost |
|---|---|---|
| Mechanical, high-volume, exploratory — a test sweep, a rename, a data-shape investigation | `--harness pi-local` | nothing |
| Ordinary implementation with a clear plan | `--harness claude --model sonnet` | subscription |
| Work where the model quality decides the outcome | `--harness claude --model opus` | subscription |
| A second opinion from outside the family | `--harness pi --model <openrouter-id>` or `--harness codex` | real money / ChatGPT sign-in |

**Pin `--model` on every claude run.** Without it the run takes the host's
default, which is the expensive model this session is likely running on —
and the mode's whole reason for existing is gone.

`pi-local` is sealed: no network at all, so nothing can be installed or
fetched in there. Say in the handoff what is already provided, or the run
spends itself discovering it cannot `npm install`.

Check what a round actually cost before choosing the next one's harness:

```bash
fork-sandbox-status.sh --json <run-dir> | jq .cost_usd
```

`--json` also carries the token counts and the harness version. A `pi-local`
run reads a zero cost; a codex run reports tokens and a null cost.

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
