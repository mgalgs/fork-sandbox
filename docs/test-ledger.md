# The test-run ledger

A run is a pipeline of legs (code, review, fix, maintain) working one after
another on one branch in one clone. A review or maintain leg that is handed the
exact commit an earlier leg already tested has no reason to run that suite
again: nothing changed. The ledger is how the earlier leg's result reaches it.

A leg that runs a test suite appends one line to `test-runs.jsonl` in the run's
outbox, naming the commit it tested. When the runner builds a later review,
maintain or fix leg's prompt, it reads the clone's current HEAD, picks the
ledger lines for that HEAD, and shows them to the leg with an instruction to
rely on them. A leg whose HEAD has moved since — a fix leg committed — matches
no earlier line and is told so; it runs what it needs.

## Where it lives

`<run-dir>/outbox/test-runs.jsonl` (on a local run), JSONL, append-only. The
outbox is the one path every leg of a run can write and the host can read, so
the ledger needs no bind of its own. It counts against the outbox's size
budget like any other file and comes back with the rest of the outbox.

## The line

One JSON object per line, written on a single line. All seven fields are
required:

| field     | type    | meaning |
|-----------|---------|---------|
| `sha`     | string  | the commit tested: `git rev-parse HEAD`, all 40 lowercase hex digits |
| `cmd`     | string  | the exact command run, 1-300 characters |
| `ok`      | integer | tests that passed, 0-1000000 |
| `fail`    | integer | tests that failed, 0-1000000 |
| `outcome` | string  | `pass` or `fail` |
| `leg`     | string  | the kind of leg that ran it: `implement`, `review`, `fix` or `maintain` (a short lowercase word) |
| `at`      | string  | UTC timestamp, e.g. `2026-01-31T12:00:00Z` |

```json
{"sha":"0123456789abcdef0123456789abcdef01234567","cmd":"make test","ok":120,"fail":0,"outcome":"pass","leg":"implement","at":"2026-01-31T12:00:00Z"}
```

## Who writes it

Any leg that runs a test suite, right after the run, once per suite — and
**only when the working tree was clean at that commit**. A run made with
uncommitted edits describes no commit, so nothing is recorded for it. A leg that
edits therefore commits first and runs the suite on the clean tree. A leg
appends; it never rewrites or deletes earlier lines.

The instruction lives in `fs_emit_prompt_preamble`'s "Artifact outbox"
section, as a "Test-run ledger" paragraph, so every leg that has an outbox gets
it: implement, review, fix, maintain, and the legs of a Kubernetes pod (whose
outbox is `/work/outbox`).

## Who reads it

The host-side runner, in the generated `run.sh`, for:

- every review and maintain leg of the legacy tiers and of composed pipelines
  (`review-prompt-<N>.md`, `maintainer-prompt-<N>.md`, `step-<K>-prompt-<N>.md`);
- every fix leg (`fix-prompt-<N>.md`, `maintainer-fix-prompt-<N>.md`,
  `s<K>-fix-prompt-<N>.md`), placed after the findings.

It reads the HEAD fresh each time it builds a prompt, the way it reads the
branch head everywhere else: over `git ls-remote` from outside the clone,
never by running git inside it. Implement legs and the Kubernetes in-pod review
loop do not read the ledger.

What the prompt gets (`fs_emit_test_record_section`):

- **A record matches HEAD.** A `## Recorded test runs for this commit`
  section, stating the HEAD it matched and listing the matching lines (newest
  ten at most). The leg is told these suites already ran against the exact
  commit it is reviewing, not to re-run them, to re-run only on a specific
  reason to doubt the record and then to state the reason. A narrower test a
  specific finding needs stays allowed; the rule is against re-running the
  unchanged suite. The Report's tests item accepts
  `reused: <command> at <short sha> from the <leg> leg, N ok / M fail` in place
  of what the leg RAN. A fix leg gets the same record with fix wording: it
  starts from that commit, and its own commit makes the record stale.
- **The ledger has valid lines, none for HEAD.** A short
  `## No test run is recorded for this commit` note naming the HEAD, so the leg
  does not carry an older commit's result over. This is what a review leg sees
  after a fix leg committed and ran nothing.
- **Anything else** (no ledger, an empty one, only malformed lines): nothing is
  added, and the prompt is as it would be without the feature apart from the
  instruction to record.

The prompt bodies shared with the Kubernetes path say nothing about a record on
their own; the Report item reads "...or, for a suite you relied on instead of
re-running because this prompt has a 'Recorded test runs for this commit'
section, `reused: ...`", which is inert without the section.

## Trust

The sandbox writes the ledger, so the host treats it as untrusted text, the way
it treats the rest of the outbox. The ledger is evidence handed to the next
model; the runner never acts on it. A leg can write a false line, and a later
leg that trusts it is relying on it the way it relies on an author's commit
message; the reviewer keeps the right to re-run on doubt, and the operator
re-runs the suites on the host before merging regardless.

`fs_test_ledger_parse` therefore:

- refuses a ledger that is a symlink or not a regular file (no following a link
  out of the outbox, no blocking on a fifo);
- reads only the last 256 KiB (dropping the fragment of the first line) and the
  last 500 lines of that, so padding cannot push later lines out of view and a
  huge file costs nothing;
- drops any line over 4096 bytes, that does not parse as an object, or whose
  fields are not of the documented type and bounded length — silently, but
  counted, and the count is stated in the section when it is non-zero;
- ignores extra keys, and reduces `cmd` to printable ASCII with no backtick, so
  nothing in it can close the inline code span it is rendered in, add a fence,
  or start a heading, and the record is exactly one list line;
- never fails the caller: a missing `jq` or any other error yields no section,
  not a failed prompt build.

## Not covered

- The in-pod review loop of a Kubernetes run does not read the ledger (it is
  told to write it, and the file comes back with the outbox).
- A flaky suite gets one recorded result.
- A refresh chain's stall check treats any outbox write, ledger lines included,
  as progress (see `fs_refresh_outbox_sig`).
