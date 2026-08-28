---
name: sandbox-coder-mode
description: Enter a standing mode where this session stops writing code and delegates every coding and editing task to an unattended fork-sandbox run, acting as orchestrator, reviewer and integrator. Use when the user wants an expensive model to plan and review while cheap or self-hosted models do the typing, or wants unattended editing to happen somewhere that is not their own checkout. Stays on until the user ends it.
argument-hint: [off] — no argument turns the mode on. Pass "off" (or say so in plain words) to end it.
user-invocable: true
---

# Sandbox Coder Mode

A standing mode, not a one-shot task. From the moment the user invokes it
until they end it, this session writes no project code. It reads, plans,
delegates the editing to `fork-sandbox` runs, reviews what comes back, and
integrates it in the real repo.

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

## Entering the mode

Tell the user, in one or two lines:

> Sandbox coder mode is on. I'll read, plan, review and integrate; the actual
> editing goes to sandboxed runs on their own branches. Say "exit sandbox
> coder mode" when you want me writing code here again.

Then carry on with whatever they asked for. Do not re-announce the mode on
every turn.

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

- A one-line typo or a comment fix — under a minute, verifiable by reading.
- Files outside the project: scratch files, notes, and the handoff documents
  themselves. The sandbox cannot see them, so they can only be written here.
- A change the user explicitly asks this session to make by hand.

The threshold: if the edit needs a plan, touches more than a file or two, or
has to be verified by running something, it goes to a sandbox. If it is one
obvious edit this session can prove correct by reading, just make it. When a
"trivial" edit turns out to need a second one, stop and delegate the rest
rather than drifting back into writing the change here.

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

**There is no resume flag.** `fork-sandbox.sh` starts a fresh session every
time, and the sandbox is destroyed with its clone. A second round is a new
run that starts from the first one's branch:

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
run reads `$0.000000`; a codex run reports tokens and a null cost.

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
