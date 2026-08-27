---
name: commit-then-review
description: Commit current changes then run a rigorous code review of all work on the current branch, via /code-review, and commit the fixes. Use after completing a chunk of work to review before human review.
argument-hint: "[low|medium|high|max] [--no-commit] [--base <branch>] — effort defaults to high; skip the opening commit with --no-commit; fixes found by the review are still committed."
---

# Commit Then Review

Commit the current work, run `/code-review` over the branch, then commit
what the review fixes.

This skill does not carry its own review checklist. `/code-review` is the
review engine: it ranks findings by severity, verifies them adversarially
before reporting, and scales depth with the effort level. Maintaining a
second checklist here only splits attention between two engines that
drift apart. What this skill owns is the part `/code-review` does not:
committing before the review so nothing is lost, and committing after it
so the fixes survive.

## Step 1: Commit Current Changes

If `--no-commit` was specified, skip to Step 2. It governs this step only
— the work that was already in the tree when you started. Fixes the
review itself produces are committed either way, in Step 3.

Run `review-context.sh --pre-commit` to capture the working tree state
(status, staged/unstaged diffs, recent commit style) in one call.

If there are staged or unstaged changes:
- Analyze the diffs from the output.
- Draft a concise commit message matching the style of recent commits.
- Stage relevant files **by name** and commit.

If the working tree is already clean, move on.

## Step 2: Run the Review

Invoke the `code-review` skill against the branch, at **high** effort
unless the caller named a level.

High is the default because this is the gate before a human sees the
work, and the failure mode that matters here is a **miss**, not noise.
Lower levels report fewer, higher-confidence findings — the right trade
for a small mechanical diff, the wrong one for logic, metrics, or
anything whose output is a number that always looks plausible. One high
review costs a fraction of a second review round with a human.

Pass `--base <branch>` through if the caller supplied one.

Two things to insist on, because a general review engine will not know
to weight them:

- **Review the tests as suspiciously as the code.** A test written
  alongside the implementation tends to encode the implementation's own
  assumptions, so it passes and proves nothing. Ask of each one: what
  input would make this fail? If a test merely restates a docstring, or
  a fake cannot produce the failure the real system produces, say so —
  that is a finding, not a nit.
- **Check values across the axis the feature varies.** Anything that
  ranks, scores, compares, or picks a best value needs to be reasoned
  about with at least two candidates that differ along that axis. Bugs
  in ordering and comparison are invisible with one.

## Step 3: Fix the Issues, and Commit the Fixes

This step is the same whether someone is watching or not.

- **Fix all Critical and Important findings immediately.**
- **Fix the Minor findings you judge worth it**, and fix anything else
  you notice that should be fixed, whether or not the review named it.
  Do not stop to ask which ones. A question costs the user more
  attention than reading a fix does, and an unattended session has
  nobody to answer it.
- **Commit the fixes.** Amend when the fix belongs to your own just-made
  commit and nothing has built on it; otherwise a fixup, or a new commit
  with its own honest message.
- **List everything you fixed, and everything you saw and chose to
  leave, in your final report.** The report is where the user's
  judgement re-enters. That is what makes committing safe: the work is
  on the branch, the reasoning is in front of them, and reverting one
  commit is easier than reconstructing a pile of unstaged edits.

Leaving fixes uncommitted looks cautious and is not. An uncommitted fix
is invisible to every tool that reads the branch, it is lost the moment
anything stashes or checks out, and in a sandboxed clone it does not
exist at all — only committed state is fetched back.

There is no exception, `--no-commit` included. That flag is about the
work that was already in the tree when the review started, not about
what the review itself produces.

It does mean the tree may hold changes that are not yours to commit. So
stage the files you actually fixed, by name. Never `git add -A` or
`git add .` — a review that sweeps up unrelated work in progress has
done the user real damage, and the run that most needs the care is
exactly the one where they asked you to leave their tree alone.
