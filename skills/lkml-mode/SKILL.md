---
name: lkml-mode
description: Review a patch series the way the Linux kernel mailing list does -- a cover letter and patches posted to a shared mailbox, a panel of AI-persona reviewers (always including a core reviewer with the highest bar) replying in threads from sandboxed runs, the author posting v2, v3... with a changelog answering review, converging when the right reviewers have signed off and no NAK stands. Use for a change substantial enough to want several independent, adversarial voices and an iterated record of what they asked for and why it changed -- not for a small diff you can review yourself in one pass.
argument-hint: <series> <branch> [--personas <p1,p2,...>] — <series> is a short kebab-case slug for the mailbox; <branch> is the branch to post as v1 (format-patch against its merge-base with main, or state another base explicitly). Default personas are core plus whichever reviewer archetypes fit the change; always include core.
user-invocable: true
---

# lkml-mode

A patch series posted to a shared mailbox, reviewed by a panel of AI
personas replying in threads from sandboxed runs, revised into v2, v3...
by an author persona answering the review, converging when the right
reviewers have signed off and nobody holds a NAK. This session is the
**orchestrating** Claude session throughout — it never writes the code
under review and never edits it in response to review; every reviewer and
every revision is a separate `fork-sandbox.sh` run in its own sandboxed
clone. Read the `fork-sandbox` skill first if you have not; this mode is
built entirely out of its primitives.

## What you read, and what you do not

You see the **cover letter** and the **thread tree** — `lkml-mailbox.sh
cover`, `lkml-mailbox.sh tree`, `lkml-mailbox.sh open`, `lkml-mailbox.sh
tally`, and `lkml-status.sh` for the one-screen summary. That is enough to
decide who replies to what next. You do **not** read message bodies
(`lkml-mailbox.sh show <id>`) unless a thread demands it — a NAK whose
reasoning you need to weigh before deciding whether the author should
contest it, a tally that looks wrong, a reviewer whose comment the tree's
one-line rendering does not make clear. Reading everything defeats the
point of the arrangement: the mailbox exists so this session's job is
scheduling, not reading, and the reviewers' job is reading.

## The scripts

- **`lkml-mailbox.sh`** — the message store. `init` posts a cover letter
  and a `git format-patch` set as v1 (or the next version); `post` replies
  in a thread; `tree`/`cover`/`show`/`open`/`tally` read it back. `init`
  and `post` also take `--attach <file>` (repeatable) to carry a file
  (e.g. a screenshot a reviewer persona should look at) alongside a
  message — it lands under `<series>/attachments/`, gets an
  `X-Attachment` header, and `tree` marks the message with a trailing
  "📎". Read its own header comment for the full verb list, the message
  shape, and the attachment size cap/collision rules. You will mostly call
  `tree`, `open`, `tally` and `cover` — see above.
- **`scripts/lkml-render.py`** — renders a self-contained HTML archive of the
  threads and review tally: `lkml-render.py "$LKML_MAILBOX_ROOT/<series>" > threads.html`.
  The HTML is the human view; `lkml-render.py --text "$LKML_MAILBOX_ROOT/<series>"`
  renders the same thread as plain text on stdout (series header, tally table,
  reviewer blocks, then every message in thread order, bodies indented under
  their headers, with [PATCH] bodies keeping the commit message and diffstat,
  the diff cut at the first `diff --git`) — the view for agents and `grep`
  that would otherwise
  fight 500KB of markup.
- **`lkml-round.sh`** — launches one sandboxed run per persona, in
  parallel, either reviewing the whole series fresh or replying to
  specific threads you name with `--reply-to`. Every run's replies are
  harvested back into the mailbox when it finishes; the runs themselves
  make no commits.
- **`lkml-revise.sh`** — launches the author persona to answer open review
  (fixing code and/or replying) and post the next version. A large series'
  revision round is a single long sandboxed run with no mid-run checkpoint
  today; a run that can resume itself from a hand-off in its own outbox
  (see the fork-sandbox skill and `fork-sandbox.sh`'s docs once that lands)
  would let a long author revision pick up where it left off instead of
  restarting from the checked-out ref on a timeout. Nothing here depends on
  it yet — this is a note for when it exists, not a requirement now.
- **`lkml-summarize.sh <series> --project <path>`** — a standalone
  two-tier summary of the thread, for when a human wants the story as a
  document rather than a message. It runs two sequential
  `fork-sandbox.sh` runs over `lkml-render.py --text`'s output: an
  **extraction** run (default `claude/sonnet`) writes a structured
  intermediate (verdicts, defects with severities and reply ids, open
  questions, cross-reply duplicates), then a **synthesis** run (default
  `claude/opus`) gets that intermediate plus the version's tally section
  inline and writes the human-facing markdown — a `# Summary` section
  held to ~200 words for the small collapsed-card slot a render round
  is meant to fill (the script warns on stderr when it overruns) and a
  `# Details` section. Both tiers are
  read-only, no-commit runs on a throwaway
  branch; the outputs land in the series dir as `results-v<N>.json` and
  `results-v<N>.md` (latest recorded version by default, `--version <N>`
  to pin; re-summarizing overwrites in place). It is deliberately not the
  `secretary` seat: secretary posts one summary as a reply to the cover
  letter INSIDE the thread; this writes files OUTSIDE the thread and
  touches nothing in the mailbox. The tier harnesses/models are
  overridable with `--high`/`--low` or a
  `~/.config/fork-sandbox/lkml-summarize.env` file; a bare harness
  (e.g. `--high pi-local`) passes through bare, exactly like a reviewer
  persona's.
- **`lkml-series.sh`** — for reviewing work AFTER it already shipped: given
  `<base>..<tip>` that already landed (a merge commit, a pile of WIP
  commits, whatever), launches the author persona once to recreate the
  SAME end state as thematic, individually reviewable commits, then
  `git format-patch`es that reconstruction as v1. Verifies the
  reconstruction's tree against `<tip>` itself before trusting it. Does
  not post a cover letter — follow it with `lkml-cover.sh`. See "Post-hoc
  review" below.
- **`lkml-cover.sh`** — launches the author persona to write a cover
  letter for patches that already exist (`lkml-series.sh`'s
  reconstruction, or any other already-formatted patch set) and posts it
  with `lkml-mailbox.sh init`. This is also what step 1 below means by
  "something you ask the `author` persona to write in its own short
  sandboxed run first."
- **`lkml-forklift.sh`** — the post-hoc exit point: once a version has
  converged (step 5), folds that version's reviewed delta back onto a real
  branch in the operator's own repo (`--onto <branch>`) as one commit
  carrying the tally and changelog, tolerating `--onto` having moved since
  the series branched off. It is the only script here that mutates the
  operator's real repository — read its own header comment before running
  it.
- **`lkml-status.sh`** — one screen: current version, its tally, every
  open thread, the deepest thread, and cost so far.

## Building a panel

**`core` is on every panel, whatever the series.** It is the reviewer with
the highest bar: it reads the whole system rather than the diff, traces
the error paths as carefully as the fast path, treats every new interface
as permanent, checks the changelog against the diff, and rants only when
a patch has earned it. It is modeled on a standard, not on a person —
explicitly an AI persona in a sandbox that signs as itself and never as
any human. `skills/lkml-mode/personas/` ships it plus five
general-purpose reviewer archetypes (`architecture`, `security`, `tests`,
`docs`, `newcomer`), the `ci` bot, the `author` persona that revises
the series, and the `secretary` persona that summarizes it.

**`secretary` runs as a solo seat AFTER the review rounds it summarizes** —
`lkml-round.sh <series> --personas secretary` once the panel's replies are
in. It reads the whole thread and posts one structured summary (key
takeaways, defects and their standing, notable exchanges, state of the
series) as a reply to the cover letter, so someone not on the list can
act on the discussion without reading it. The seat's sandbox cannot read
the mailbox, so `lkml-round.sh` hands a `secretary` seat the whole thread
in its handoff — the `--text` render of the mailbox, bodies included; the
reviewer seats do not get it, they read the diff in their own clone.
Running it alongside the panel
defeats it: there is no thread to summarize yet.

**`ci` runs first on every version.** It holds no opinions: it runs every
test suite at the series' tip and posts one reply on the cover — a table
of `N passed, M failed` per suite, the `FAIL` lines verbatim, and
`Tested-by` or `NAK`. Every other reviewer reasons about the code; this
is the one seat that executes it, and a reviewer who "traced the path and
expects it to work" is not a substitute. Pin it to the cheapest harness
you have, launch it alone before the panel, and do not let the author
post a version the bot has not run.

Beyond `core`, **build a panel tailored to the series** rather than
launching all five archetypes by default. A kernel-style locking change
wants a locking-literate reviewer; a kids' game wants a child-safety
reviewer; a data-pipeline change wants someone who has actually operated
one. When none of the shipped archetypes fit, write a new one or two —
copy an existing persona file's shape (a `harness`/`model`/`display`
frontmatter block, then a short voice-and-focus body) into
`skills/lkml-mode/personas/`. A persona is pinned to one harness and model
for the whole series, so its voice stays consistent version over version —
do not vary it round to round.

## The loop

1. **`init` the series** from a branch: `lkml-mailbox.sh init <series>
   --cover <file> --patches <dir> --from author ...`, where `<dir>` is a
   `git format-patch <base>..<branch>` output directory and the cover
   letter is either something you write yourself or something you ask the
   `author` persona to write in its own short sandboxed run first.
2. **Build the panel** (always `core`; see above). Round 0: `ci` alone,
   `lkml-round.sh <series> --project <path> --checkout <branch> --base
   <base-ref> --personas ci`. Round 1: every persona reviews the whole
   series — the same command with `--personas <list>` and no
   `--reply-to`.
3. **Read `tree` and `open`.** Decide who replies to what: usually the
   author answers a reviewer's Question or NAK, but a reviewer can also
   reply to another reviewer's comment. Launch a round per batch of
   replies-to-write with `--reply-to <id>` (repeatable). **There is no cap
   on how many replies a round may contain — the only limit is depth 30
   per thread**, enforced by `lkml-mailbox.sh post` itself.
4. **When `open` is empty**, or everything left open can only be moved by
   the author, run `lkml-revise.sh <series> --project <path> --checkout
   <branch> --version <N> --base <base-ref>` to produce vN+1, where
   `<base-ref>` is the SAME base you formatted v1 against in step 1, not
   vN's branch -- the author's commits land on top of vN, so posting
   against vN's tip would ship only this round's fixups as if they were
   the whole series. This posts vN+1 on a NEW, timestamped branch named
   `lkml/<series>-v<N+1>-<timestamp>` -- lkml-revise.sh's own report names
   the exact branch, which you need verbatim since the timestamp makes it
   unguessable. Go back
   to step 2 with the whole panel checked out against THAT branch, not the
   one you started this step with: a round launched with `--checkout
   <branch>` still pointing at vN's branch reviews vN's code while being
   handed vN+1's patches in its handoff, and every comment it produces is
   against a version that has already been superseded.
5. **Converged** when every patch in the current version has
   `Reviewed-by` or `Acked-by` from `core` AND from at least one other
   reviewer (`lkml-mailbox.sh tally`), no `NAK` stands unanswered, and
   `open` is empty. At that point the series is mergeable — **the operator
   merges it**, not this session; see "What this is not" below.
   **Stopped** (report honestly, do not keep spending rounds) when
   `--max-versions` (default 8, tracked by you, not enforced by any
   script) is reached, or `lkml-revise.sh` reports the author made no
   commits — its own "a version changes nothing" line.
6. **`lkml-status.sh <series>`** any time you want the one-screen version
   of all of the above, including cost so far.

## Post-hoc review (work that already shipped)

Everything above assumes a branch and a cover letter ready for step 1's
`init`. For a range that already landed and is being reviewed AFTER THE
FACT, get there differently, then rejoin the loop at step 2:

1. **`lkml-series.sh <series> --project <path> --range <base>..<tip>`**
   reconstructs `<base>..<tip>` as thematic, individually reviewable
   commits on a new branch and format-patches them into `<series>/patches-
   v1/`. It does not post anything.
2. **`lkml-cover.sh <series> --project <path> --checkout <branch> --base
   <base> --patches <series>/patches-v1/`** launches the author persona to
   write v1's cover letter and posts it with `lkml-mailbox.sh init` — this
   is step 1 of the loop, done for you.
3. Continue at step 2 of the loop above, panel checked out against
   `<branch>`.

When the series converges (step 5), the reviewed version exists only as a
branch in `<series>/versions.jsonl` — it still needs to land on the real
branch it started from. **`lkml-forklift.sh <series> --project <path>
--version <n> --onto <branch>`** does that: it folds vN's reviewed delta
onto `<branch>`'s CURRENT tip as one commit, tolerating `<branch>` having
moved since the series branched off, and refuses outright (moving nothing)
if the two have genuinely diverged. Read its own header comment before
running it — it is the only script in lkml-mode that mutates the
operator's real repository, and it does not push or run tests for you.

## Attribution is non-negotiable, and it is not your job to enforce it

Every message's `From` header carries `(AI persona)`, every message
carries `X-AI-Persona`/`X-AI-Harness`/`X-AI-Model`, and `tree` renders the
harness/model column — all of this is baked into `lkml-mailbox.sh` itself
(the one function that ever writes a message file), not left to a
persona's good behavior. You do not need to check for it, and a persona
prompt that tried to write around it would still get stamped, not
believed. What IS your job: the cover letter you write or ask `author` to
write states plainly, in its first paragraph, that every participant is an
AI persona run in a sandbox — say that in your own words when you draft
one, the mailbox cannot write your cover letter's prose for you.

## What this is not

This is not a substitute for a human merge. Convergence here means the
personas agree the series is ready — it does not mean anyone with actual
authority over the codebase has looked at it. Report convergence as "ready
for your review," hand the operator the branch and the `lkml-status.sh`
summary, and let them decide to merge it. Nor is it a substitute for
running the tests: a `Reviewed-by` from a sandboxed persona is a reading of
the diff, not a test run, and nothing here executes the suite for you.

This is also not free. Every persona's every round is a real
`fork-sandbox.sh` run at that persona's model's price, tagged
`kind: review`, `kind: implement` or `kind: summarize` (the two
`lkml-summarize.sh` tiers) and `tags: ["lkml", "<series>",
"<persona>"]`, so `sandbox-run-log.py stats` can price a series later by
persona and by model. `lkml-status.sh` gives you the running total; do not
let a series run to `--max-versions` without checking it.
