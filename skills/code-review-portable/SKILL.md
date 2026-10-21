---
name: code-review-portable
description: Portable code review of a local commit range — find correctness bugs and reuse/simplification/efficiency cleanups, verify each finding before reporting, and scale depth by effort level. A harness-agnostic stand-in for the built-in /code-review, for agents that do not have it (pi, codex).
argument-hint: "<level> <base>...<head> — level is low|medium|high|xhigh|max; the range is a local git range such as abc123...HEAD"
---

# Portable Code Review

Review the change in one local commit range. Find what is wrong, and what is
worth cleaning up. Report it concretely.

This skill is a portable stand-in for the built-in `/code-review`, which is
compiled into Claude Code and so exists only on the `claude` harness. Every
other harness — `pi`, `codex` — gets this instead. The method is
the same; only the engine differs. Follow the steps in order.

You need no network for any of this. The review is entirely local: the clone
is already checked out at the head, and the base commit is named in the range
you were given. Do not try to fetch, push, or reach a code host — you have no
credential for one, and none is needed.

## What you were given

- **A level**: `low`, `medium`, `high`, `xhigh`, or `max`. It sets how wide
  you cast and how sure you must be. See "Effort level" below.
- **A range**: `<base>...<head>`, such as `abc123...HEAD`. The three dots are
  deliberate. They measure the change from the point where the branch left the
  base, exactly as a code host shows a pull request diff, so an unrelated later
  commit on the base branch is not dragged in. Use the range exactly as given.

## Effort level — breadth against confidence

The level trades coverage for confidence. It does not change the method; it
changes where you set the bar.

- **low, medium** — Report only findings you are confident are real. Few,
  high-signal. Right for a small mechanical diff. When in doubt, drop it.
- **high** — The default. Cast wider. You may report a finding you are less
  than certain of, but say so plainly and put the weakest ones under Notes or
  Questions, not Issues.
- **xhigh, max** — Exhaustive. Read every changed file and its neighbors in
  full. Reason about every branch. Include uncertain findings, each marked with
  how sure you are. Miss nothing; noise is acceptable here, a miss is not.

## Method

### 1. Read the change

Read the whole range, not a summary of it.

```
git log --oneline <base>...<head>
git diff <base>...<head>
```

Then **read the whole files the diff touches, not only the hunks.** A bug often
sits in an unchanged line next to a changed one — a caller the change now breaks,
a guard the change made unreachable, an assumption the change quietly voided.

Read the commits one at a time when the history matters. A commit that adds a
guard and a later one that drops it both look fine in the combined diff.

### 1b. Follow the edges out of the diff

The diff shows one side of every contract it touches. Read the other side,
one hop out at `high`, two at `xhigh` and `max`:

- **Callers.** For each function, script, flag, exit code, output line or
  file format the change adds or alters, search the repository for what uses
  it — code, tests, docs and skills that invoke it — and read those uses.
  Does each one still get what it expects?
- **Callees.** For each function, command or tool the new code relies on,
  read it, and check it does what the new code assumes: its return values,
  its error cases, what it does on empty input.
- **Shared state.** For each file, directory, environment variable, config
  key or lock the change reads or writes, find the other readers and
  writers. Can they now see a state they never saw before?

Say in the report which callers and callees you read. A review that names
none has not done this step.

### 2. Hunt

Look for two kinds of thing, in this order.

**Correctness bugs — the priority.** Reason about, at least:

- Boundary and off-by-one errors; empty, single-element, and huge inputs.
- Null, nil, `None`, undefined, and missing-key access.
- Error and exception paths: swallowed errors, wrong error returned, cleanup
  skipped on the failure path, a resource (file, lock, connection) leaked.
- Ordering, comparison, and ranking. Anything that sorts, scores, compares, or
  picks a "best" value is invisible to test with one input — reason about **at
  least two candidates that differ along the axis the code varies.**
- Concurrency: shared state, races, a check separated from the act it guards.
- Options and modes: run each new flag or argument through every mode the
  parser accepts it in, not only the mode it was written for.
- Encoding, escaping, and types: a value that changes type, a string built
  where a list was meant, a number parsed from untrusted text.
- Security, which no other pass may own: a secret committed in the diff; a
  dropped or missing permission or authorization check; input that reaches a
  shell, a query, or a filesystem path without being escaped.

**Cleanups — after the bugs.**

- **Reuse**: logic duplicated from an existing helper, or worth extracting.
- **Simplification**: a branch that cannot be taken, a simpler equivalent, dead
  code the change left behind.
- **Efficiency**: needless repeated work, an O(n^2) loop over data that grows, a
  query in a loop.

**Read the tests as suspiciously as the code.** A test written alongside the
implementation tends to encode the implementation's own assumptions, so it
passes and proves nothing. Ask of each: what input would make this fail? If a
test merely restates a docstring, or a fake cannot produce the failure the real
system produces, that is a finding, not a nit.

### 3. Verify each finding before you report it

This step is what separates a review from a guess. For **every** candidate,
before it goes in the report:

1. State the exact input or state that triggers it.
2. Trace the actual code path with that input, line by line.
3. **Try to refute it.** Look for the guard, the earlier return, the caller
   that never passes that input, the invariant that rules it out.

If you cannot produce a concrete failure — real input, real code path, real
wrong result — it is a guess. Drop it, or move it to Questions phrased as a
question. Spend more refutation passes on a finding the higher the level.

Never report a finding whose failure you could not trace. A plausible-but-wrong
finding costs the reader more than a missed nit.

**Then have someone else try.** At `high` and above, if your harness can
start a subagent (Claude Code's Agent tool, for one), give each surviving
finding to a fresh one, in parallel, one finding each. Hand it the file and
line, the triggering input and the claimed failure, and none of your
reasoning. Ask it only to confirm or refute that claim from the code, not to
look for other problems. Then:

- it traced the same failure: the finding is **confirmed**;
- it could neither confirm nor refute: the finding is **plausible**;
- it found the guard, caller or invariant that rules it out, and you agree
  on reading it: drop the finding.

Without subagents, your own refutation above is the check; say so in the
report.

### 4. Rank and report

Order findings **worst first**. Each one needs, without exception:

- The **file and line**.
- The **input or state** that triggers it.
- **What goes wrong** as a result.
- **What to do** about it.
- **Confirmed or plausible**, when a second check ran.

If you cannot state a finding that concretely, it is not ready — drop it or ask
it as a question.

Do not pad. No style nits a formatter would fix. No praise. No retelling of the
diff. **"No issues found" is a complete and good review of a sound change.**

## Output format

If your caller (a handoff, a prompt, an invoking skill) specified an output
format, **use theirs** — it wins over anything here. Only when none was given,
use this default:

- `## Issues` — real problems, worst first. Write "No issues found." when there
  are none.
- `## Questions` — what you could not settle from the code, phrased for the
  author.
- `## Notes` — anything else worth saying, and everything you could not verify.
  Say plainly what you could not run and why.
