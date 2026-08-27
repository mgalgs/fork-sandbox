---
name: fork-sandbox
description: Fork a task to an unattended Claude Code session in a sandboxed clone of the repo. Headless, so it needs no keypress, exits on its own, fetches its branch back, and logs every event to a file this session can watch. A running session can still be steered with fork-sandbox-say.sh, which sends it an operator addendum. Use when work should run without babysitting — a refactor, a test sweep, a long build.
argument-hint: [--branch <name>] [--model <model>] [--harness claude|pi|pi-local|codex] [--review-loop <N>] [--sandbox-args "..."] <project-path> — path to the target project (omit or use "." for the current repo). Use --branch to name the branch the session commits on. Use --model to pick the model (fable, opus, sonnet). Use --harness pi to run pi against OpenRouter, which then requires --model; --harness pi-local to run pi against a self-hosted endpoint in a sandbox with no network at all, which costs nothing; or --harness codex to run OpenAI codex on your ChatGPT sign-in. Use --review-loop N to have a fresh session review the run's commits and a third session fix what it found, up to N times. Use --sandbox-args "--unpin-egress" only when the task must reach the tailnet, a VPN, or a libvirt/docker bridge.
---

# Fork Sandbox

Run one Claude Code session in a throwaway clone of the repo, inside
`claude-sandboxed`, with every permission check bypassed. The session is
**headless**: it takes no keypress, it exits when the work is done, and its
branch is fetched back into the real repo on its own.

This is `fork-task --sandboxed` made unattended. Use `fork-task` instead when
you want an interactive session someone will sit with.

## When to use it

- Work that should run while the user does something else.
- Work the user does not want to approve tool-by-tool.
- Work that is safe to hand to an agent with no secrets and no network
  credentials: a refactor, a test sweep, a doc pass, a self-contained feature.

Do **not** use it when the task needs uncommitted state, an `.env` file,
ssh keys, a push, the tailnet, or the user's global `~/.claude`. None of
those reach the sandbox. (`node_modules` and the project's pinned node DO
reach it — see "What it gives up".)

## Instructions

1. **Pick a branch name.** Short kebab-case from the task, 2-4 words, prefixed
   `sbx-` — for example `sbx-truncate-slug`. It must not already exist in the
   repo; the script refuses if it does.

2. **Write the handoff doc.** `mktemp /var/tmp/claude-scratch/claude-handoff-XXXXXX.md`.
   The document is the session's entire prompt, so it must stand on its own.
   Include:
   - **Goal** — what to accomplish.
   - **Context** — why, and what the caller expects.
   - **Current state** — what already works, what does not.
   - **Details** — the files, APIs and contracts involved.
   - **Acceptance criteria** — how the session knows it is done.
   - **Commit the work.** Say this explicitly. Uncommitted work has nothing to
     fetch back and is lost when the clone is deleted.
   - **Report** — ask for two or three sentences on what it did, whether tests
     pass, and anything it was unsure about. That text becomes the result you
     report to the user.

   Remember what is missing when you write it. There is no global CLAUDE.md,
   no global skills and no global scripts, so do not refer to them. Name the
   test command in full.

3. **Launch it.**
   ```bash
   fork-sandbox.sh --branch "<branch>" "<project-path>" "<handoff-file>"
   ```
   Extra flags, all optional:
   ```bash
   fork-sandbox.sh --model sonnet --branch "<branch>" "<path>" "<handoff>"
   fork-sandbox.sh --sandbox-args "--unpin-egress" --branch "<branch>" "<path>" "<handoff>"
   fork-sandbox.sh --claude-args "--effort high" --branch "<branch>" "<path>" "<handoff>"
   fork-sandbox.sh --task-meta '{"kind":"implement","difficulty":3,"size":"m"}' --branch "<branch>" "<path>" "<handoff>"
   fork-sandbox.sh --review-loop 2 --branch "<branch>" "<path>" "<handoff>"
   ```
   Pass `--sandbox-args "--unpin-egress"` only when the task must reach the
   tailnet, a VPN, or a libvirt/docker bridge. It removes a restriction.

   ### `--review-loop N` — let the run review its own work

   With the flag, the run does not end when the coding session does. A
   **fresh** session reviews the commits it made, following the
   `code-review-portable` skill, and writes a verdict whose first line is
   `APPROVED` or `FINDINGS`. On `FINDINGS`, another fresh session is handed
   those findings and commits fixes. That pair repeats up to N times, and the
   loop stops on the first of: the review approves, N iterations have run, a
   fix session commits nothing (`no-progress`), or a leg fails outright
   (`harness-error`). The review never sits inside the coding session's own
   conversation — an author defends its work, a stranger reads it.

   **Reach for it when** the branch will be integrated with little scrutiny,
   when the model is a cheap or local one whose first draft usually needs a
   second pass, or when a defect would be expensive and quiet — a migration,
   a security-adjacent change, anything touching money or auth. **Skip it**
   for a small mechanical diff you will read yourself anyway, and for
   exploratory work where there is no settled definition of correct for a
   reviewer to hold the branch to.

   **It costs sessions.** Every iteration is up to two more sessions at the
   same model and price as the run itself, so `--review-loop 2` can cost
   three to five times a plain run. Note the asymmetry: a review that
   approves costs one extra session, a review that finds something costs
   two. On a `pi-local` run the price is zero either way, which is where a
   large N is free to try.

   **Watching one is no different.** The run counts as running until the last
   leg is done, so the Monitor tool still fires exactly one terminal event,
   at the end of the whole loop, with the summary — which now carries a
   `review:` line saying how many iterations ran and how it ended. Expect the
   wall-clock to be two to five times a plain run, and set `timeout_ms`
   accordingly.

   `<run-dir>/review-loop.json` records what happened per iteration —
   findings, each leg's exit and cost, the head sha before and after — and
   `summary.json`'s `total_cost_usd` is the whole run including the loop
   (`cost_usd` stays the coding session alone). Read
   `<run-dir>/review-verdict-<i>.md` for what the reviewer actually said. It
   is worth quoting to the user when the loop ended in `cap` or
   `no-progress`, which means the branch came back with findings still
   outstanding.

   The script prints the **run directory** and the exact monitor, status and
   result commands. Keep the run directory path; everything else needs it.

   The run goes into its own **detached** tmux session, so it never takes the
   user's focus and never adds a window to their session. The launcher prints
   the `tmux attach` line for it. Do not attach, and do not suggest attaching
   unless the user wants to watch it live — the run directory is the record.

4. **Arm the monitor.** Do not hand-roll a poll loop. Use the Monitor tool
   with the command the launcher printed:
   ```
   fork-sandbox-status.sh --monitor <run-dir>
   ```
   Set `timeout_ms` to cover the work — 1800000 (30 min) is a good default,
   and use `persistent: true` for anything longer. The monitor confirms itself
   with a `watching:` line when it arms, then prints one line per commit, a
   heartbeat every five minutes with the session's last event, and a full
   summary when the run ends. It emits on **every** terminal state — a clean
   exit, a non-zero exit, and a runner that vanished without writing an exit
   code — so silence never means success.

   `--monitor` is deliberately near-silent between those signals. When the
   **user** wants to watch the run live in their own terminal, give them
   `fork-sandbox-status.sh --follow <run-dir>` instead — every event,
   rendered, ending with the same summary. Keep the Monitor tool on
   `--monitor`.

5. **Report back, briefly.** When the monitor fires its terminal event you
   already have the summary. If you need more, read:
   ```bash
   fork-sandbox-status.sh <run-dir>            # state, branch, commits, cost, summary
   fork-sandbox-status.sh --result <run-dir>   # the session's own summary
   fork-sandbox-status.sh --json <run-dir>     # the structured summary, for jq
   fork-sandbox-status.sh --events 40 <run-dir>  # the last 40 events
   fork-sandbox-status.sh --log <run-dir>      # sandbox startup messages
   ```

   Read a single fact with `--json` rather than grepping the prose — the
   cost is a decimal, and the obvious strip-to-digits turns `$0.076198`
   into `076198`:
   ```bash
   fork-sandbox-status.sh --json <run-dir> | jq .cost_usd
   ```

   `--json` also carries `harness_version` and a `usage` object —
   `input_tokens`, `output_tokens`, `cache_read_tokens`,
   `cache_write_tokens`, `total_tokens` — with `usage_source` naming
   where they came from. A count the harness does not report is `null`
   rather than `0`, so "not reported" never reads as "none used". With
   the model and the version alongside them, a caller can price a run
   against whatever the rates are that day.
   Then tell the user, in a few lines: the branch, the head sha and subject,
   the files touched, whether tests ran and passed, and any caveat the session
   raised. Not a wall of text. The full log stays in the run directory if they
   want it.

   Finish with the review warning below.

## Steering a run

A run is not sealed off once it starts. Every run directory has an **operator inbox** — `<run-dir>/inbox`, bound read-only into the sandbox — and one command puts a message in it:

```bash
fork-sandbox-say.sh <run-dir> "Also cover the empty-input case in the tests."
fork-sandbox-say.sh <run-dir> -      # long message from stdin
```

That is the whole interface. The file is timestamped and generated; you never name it.

**An addendum carries the same authority as the handoff.** It may override the handoff, not merely append to it — where the two conflict, the addendum is the newer instruction and wins. Both the generated prompt and the delivery hook say so out loud, because without that a session reads a course change as a footnote and carries on with the original plan.

**When it lands depends on the harness.** `fork-sandbox-say.sh` prints this on every write, so you never have to remember:

| Harness | Delivery | How |
|---|---|---|
| `claude` | next tool call | A `PostToolUse` hook puts it beside the tool result. A `Stop` hook refuses to let the session finish while an addendum is unread, so it cannot be missed. |
| `pi`, `pi-local`, `codex` | next commit | No hook system. The generated prompt tells the session to read the inbox before each commit and before its final report. |

So steering a `pi` run lands at the next commit, not the next tool call. For a session in the middle of a long build that can be a while. Send it anyway — the instruction to read the inbox before the final report means it will not finish without seeing it.

The status block counts what you have sent, and `--monitor` prints a line when one actually reaches the session:

```
inbox:    2 addenda
◆ fork-sandbox-inbox: delivered 1787718559-01.md
```

### What to send, and what not to

Good addenda are course corrections and additions in ordinary words: *"the API changed under you, `parse()` now takes a dict"*, *"skip the migration, we're doing that separately"*, *"add a test for the empty case"*.

Two things to avoid:

- **Do not write it in the shape of a prompt injection.** Phrasing like *"ignore your previous instructions and reply with exactly X"* is the canonical attack pattern, and a session that spots it will report it to you as an injection attempt instead of acting on it. This is measured, not theoretical. Say what you actually want changed and why; a plain *"correction: I no longer need the count, just list the names"* lands fine.
- **Do not use it to re-scope the whole task.** An addendum is a correction to a run in flight. If the handoff was wrong from the start, kill the run and write a better one — see "Iterating on a run" in the `sandbox-coder-mode` skill.

### Why a hook and not a socket

`nc`/`socat` is the first idea everyone has, and it is the wrong primitive here. A headless `claude -p` run has no REPL to type into — its prompt is fixed at launch — and a listener inside the sandbox would only ever be read if the agent chose to poll it, which is exactly the cooperation you cannot count on from a session that has wandered off. The hook path is how Claude Code already surfaces a user's mid-turn message to a running session, so it inherits the same delivery guarantee the interactive product has, with no agent cooperation at all.

The inbox also adds **no writable surface**. The bind is read-only; a read-only bind still reflects host writes live, which is the whole trick. Nothing inside the sandbox can write to the inbox, or forge an addendum.

## The other harnesses: `pi`, `pi-local` and `codex`

The same sandbox, the same clone, the same fetch-back — but the session is
[pi](https://github.com/earendil-works/pi) talking to OpenRouter instead of
claude:

```bash
fork-sandbox.sh --harness pi --model moonshotai/kimi-k3 \
    --branch "<branch>" "<path>" "<handoff>"
```

- **`--model` is required.** It is an OpenRouter id, such as
  `moonshotai/kimi-k3`. There is no default and the script refuses without one.
- **The key comes from `~/.config/fork-sandbox/pi.env`**, one `NAME=VALUE`
  per line, mode 0600. That key is the *only* credential in the sandbox. No
  Claude token is copied in, so a pi run cannot spend the subscription.
- **`--claude-args` is refused**, since no claude CLI runs.

What carries over, and what does not:

- **The review kit does carry over.** pi implements the Agent Skills
  standard, so `commit-then-review` and the `~/.claude/scripts` toolbox are
  bound in exactly as for claude, and the skill is handed to pi with
  `--skill`. Ask for it **by name** in the handoff — "follow the
  commit-then-review skill" — because `/commit-then-review` is a claude
  slash command and means nothing to pi. Say explicitly that the session is
  unattended, so it applies the skill's unattended rules and commits its
  fixes.
- **The rendered log does not.** pi writes plain text, not stream-json, so
  `events.jsonl` holds its raw output and the formatted views have nothing
  to render. `--result` and `--follow` print nothing useful. Use
  `fork-sandbox-status.sh <run-dir>` for state and the summary, and read
  `<run-dir>/events.jsonl` directly for what the session actually said.
  `--monitor` still works for the terminal event, but reports no commits
  along the way.
- **Cost still gets reported, and here it is real money.** A claude run
  spends the subscription; a pi run spends OpenRouter credit. Both put a
  `cost:` line in the run summary — claude's from the session total in its
  result event, pi's summed from the per-message cost in its session file,
  which is rescued to `<run-dir>/pi-session`. Quote that line when you
  report a pi run.
- **Everything else is identical**: same mount allowlist, same egress pin,
  same `node_modules` and `.nvmrc` provisioning, same branch fetch.

### `--harness pi-local`

pi against a model **you** host, in a sandbox with **no network at all**:

```bash
fork-sandbox.sh --harness pi-local --branch "<branch>" "<path>" "<handoff>"
```

The wrapper here is `agent-sandboxed` rather than `claude-sandboxed` — the
same sandbox with egress sealed and the one endpoint bridged in over a unix
socket. Read `agent-sandboxed`'s header for how that works.

- **It costs nothing.** The tokens are yours. The summary still prints a
  `cost:` line and it reads `$0.000000`.
- **Nothing secret is inside.** A local endpoint needs no credential, so
  unlike a `pi` or `codex` run there is no key in the sandbox at all.
- **It cannot exfiltrate or reach the LAN**, because there is nowhere to
  reach. No internet, no LAN, no DNS.
- **`--model` is optional.** With one model on the endpoint the script asks
  and uses it. Pass `--model` when the endpoint serves several.
- **The endpoint comes from `~/.config/fork-sandbox/model.env`**
  (`MODEL_ENDPOINT=http://your-host:8001/v1`). It is deliberately not in the
  repo: the endpoint is a fact about one machine's network, and this
  checkout is shared with machines that must not reach it. A missing config
  file fails before the clone, with the lines to create it.
- **Nothing can be fetched.** No `npm install`, no `pip install`, no
  `git fetch`, no doc lookup. A suite that needs dependencies must get them
  the usual way — `node_modules` copy-in, `provision-ro` for a venv,
  `.agents/sandbox-services` for databases. **Say in the handoff what is
  already provided**, because a session that cannot install will otherwise
  spend its run discovering that. The generated prompt already tells it the
  network is gone and to report a missing dependency rather than fetch one.
- **The raw-text log caveat applies**, exactly as for `--harness pi`.

Reach for it when the task is long, mechanical or exploratory and the model
quality matters less than the freedom to hammer at it — a test sweep, a
data-shape investigation, poking at a disposable database. Prefer claude when
the work needs the stronger model.

### `--harness codex`

```bash
fork-sandbox.sh --harness codex --branch "<branch>" "<path>" "<handoff>"
```

- **`--model` is optional** — codex has a default of its own. Pass one to
  override it.
- **The credential is your ChatGPT sign-in**, taken from
  `~/.codex/auth.json` at launch. There is no key file to set up, but
  `codex login` must be current: codex cannot refresh inside the sandbox,
  by design, so an expired token refuses the run rather than starting one
  that dies. The launcher warns when under an hour is left.
- **It cannot log you out.** codex's refresh token is single-use, so a
  sandbox that spent it would silently break the host's login. The run
  gets a placeholder in its place, which is why the token has to be
  current — it is a credential that works and cannot rotate yours.
- **Tokens but no price.** codex reports usage and no cost, so a codex run
  has `usage` counts and `cost_usd: null`. Its `cache_read_tokens` is part
  of `input_tokens` rather than a figure beside it, unlike claude's — hence
  `usage_source`, and hence `total_tokens` being computed per harness
  rather than by adding the same four fields every time.
- Like pi, it writes its own JSONL rather than claude's stream-json, so
  the rendered views have nothing to render.

Reviewing the branch matters more for both, not less. Say so when you
report.

## What the calling session must not do

- **Do not run git inside the clone.** Not `git log`, not `git status`, not
  `git -C`. The clone's git config is writable by the sandbox, and a key such
  as `core.fsmonitor` makes any git command there run on the **host**, outside
  the sandbox, with the ssh keys and the tailnet. `fork-sandbox-status.sh`
  runs no git at all for this reason. Once the branch is fetched, inspect it
  in the user's own repo, which is where it now lives.
- **Do not `tmux send-keys` into the session.** Nothing in it wants input, and
  to say something to it you have `fork-sandbox-say.sh` — see "Steering a run".
- **Do not write into `<run-dir>/inbox` by hand.** `fork-sandbox-say.sh`
  generates the name and writes atomically; a hand-placed file can be read
  half-written, or never read at all if the name is wrong.
- **Do not scrape the pane.** The log file is the record; the pane is a view.
- **Do not attach to the tmux session,** and never switch the user's client to
  it. It is detached on purpose.

## Where everything lives

The run directory holds the whole run. The sandbox cannot see it — only the
clone inside it is mounted, and the log is written by the host shell.

| Path | What it is |
|------|------------|
| `<run-dir>/events.jsonl` | every event, one JSON object per line |
| `<run-dir>/sandbox.log` | the sandbox wrapper's messages, startup errors included |
| `<run-dir>/summary.txt` | branch, exit code, commit list and diffstat after the fetch |
| `<run-dir>/summary.json` | the same facts structured — harness and its version, model, exit code, commits with subjects, `cost_usd`, `total_cost_usd` (the run plus any `--review-loop` legs), `usage` token counts, and `author_email_unexpected` (empty unless a returned commit carries an address other than the repo's own) — for reading, not grepping |
| `<run-dir>/handoff.md` | the prompt as it was sent |
| `<run-dir>/task-meta.json` | the `--task-meta` object, when one was given |
| `<run-dir>/review-loop.json` | `--review-loop` only: how the loop ended, and one record per iteration |
| `<run-dir>/review-verdict-<i>.md` | `--review-loop` only: what the reviewer wrote, verbatim |
| `<run-dir>/events-review-<i>.jsonl`, `<run-dir>/events-fix-<i>.jsonl` | `--review-loop` only: each loop leg's own event stream |
| `<run-dir>/inbox/` | operator addenda, written with `fork-sandbox-say.sh`; bound read-only into the sandbox |
| `<run-dir>/exit-code` | written when the session exits |
| `<run-dir>/pi-session` | `--harness pi` only: pi's session, with per-message cost |
| `<run-dir>/clone/<name>` | the clone; the only path the sandbox can write |

## What it gives up

Say this to the user when you launch one:

- **Committed state only**, with three carve-outs. No uncommitted changes,
  no `.env`, nothing untracked, and no project setup a
  `.claude/fork-worktree.sh` hook would have done. The carve-outs: for a
  node project the origin's `node_modules` is copied into the clone and the
  `.nvmrc` node is bound read-only, first on PATH — npm and the project's
  own suites work; a repo may name untracked paths in
  `.agents/sandbox-services/provision-ro` to bind read-only from the origin
  (a `.venv`, say); and a repo may stand per-run services up with
  `.agents/sandbox-services/` (see **Per-run services** below). A project
  whose test log lands in an untracked directory (`notes/`) writes no log
  there; read the run output instead.
- **The Hugging Face model cache, read-only**, when the host has one:
  `~/.cache/huggingface/hub` and `.../xet` at their own paths, with
  `HF_HUB_OFFLINE=1` set alongside them. An ML project's `settings` import
  often reaches transformers, and `from_pretrained()` is a local read when
  the snapshot is cached and a doomed network call when it is not — sealed
  sandboxes have no network, and no sandbox has an HF token. Only those two
  content directories are bound, never the parent, because that is where
  `huggingface_hub` keeps `token`. Read-only both ways: nothing in the
  sandbox can poison a cache the host later loads models from. A host with
  no cache gets no bind and no `HF_HUB_OFFLINE`.
- **The Playwright browser cache, read-only**, when the host has one:
  `~/.cache/ms-playwright` at its own path. Playwright hardcodes that
  location, so a suite that launches Chromium finds the browser instead of
  dying on a `playwright install` it cannot run. The whole directory is
  bound — it holds browser builds and nothing else — and Chromium's own
  sandbox still works inside.
- **No global `~/.claude`** — with two carve-outs. The `commit-then-review`
  skill and the `~/.claude/scripts` toolbox are bound in read-only, so the
  handoff can (and should) tell the session to end with
  `/commit-then-review`; scripts that want a credential fail closed in
  there. No global CLAUDE.md, no other skills, no settings or hooks. A
  project `.claude/` is committed, so it comes with the clone.
- **No secrets.** No ssh keys, no ssh agent, no API tokens, no environment
  variables. It commits; it cannot push, and cannot reach Forgejo, GitHub or
  Slack. (`--harness pi` carries one deliberate exception: the OpenRouter
  key the run needs to exist at all.)
- **No tailnet and no VPN.** The internet and the local LAN stay reachable.
- **No tmux.** It cannot split panes or fork further tasks.

## Why the clone

The session does **not** run in the user's checkout. `fork-sandbox.sh` makes a
throwaway `git clone --shared` under `/var/tmp/claude-scratch/forks` and mounts
only that clone writable.

This is the security design, not a convenience. A writable git directory is
host code execution: a hook, or a config key such as `core.fsmonitor`, runs on
the **host** the next time anyone uses git in that repo. Because nothing
writable of the user's is ever mounted, there is no hook to plant. The work
returns by `git fetch`, which git deliberately does not let a fetched-from
repository use to run commands.

## Per-run services

A committed clone has no database and no venv, so a session cannot run the
suites that need them. A repo closes that gap by committing
`.agents/sandbox-services/` (or the legacy `.claude/sandbox-services/`). When it
is present, `fork-sandbox.sh` stands the
services up on the **host** as a throwaway `docker compose` project, one per
run, and binds only a unix-socket directory into the sandbox. There is **no TCP
path** from the sandbox to the host, the egress pin is untouched, and the
compose publishes no host ports — so a hostile session can at worst trash its
own empty per-run database.

The contract, all under `.agents/sandbox-services/`:

- **`compose.yaml`** — the services. It **must not publish host ports**. Each
  service listens on a unix socket in a directory the wrapper provides. The
  compose reads that directory from an environment variable the hook exports
  (e.g. `${SANDBOX_SOCKETS_DIR}`) and bind-mounts it into the container:
  postgres via `unix_socket_directories`, redis via `unixsocket`. A TCP-only
  service gets a
  `socat` sidecar in the same project —
  `socat UNIX-LISTEN:/sockets/<name>.sock,fork TCP:<service>:<port>`. Give every
  interpolated variable a default (`${VAR:-...}`), so `docker compose down`,
  which runs without the up-time environment, can still parse the file. Put
  heavy optional services behind compose profiles. Images are **pulled, never
  built**, and no clone path is bind-mounted or used as a build context: the
  compose runs on the host at the checked-out ref, and the trust check covers
  only the `sandbox-services` dir itself — a `build:` from the clone would
  hand a hostile Dockerfile host-side execution with unrestricted network.
  The wrapper disables services for the run when any `*.yml`/`*.yaml` file in
  the hook directory contains a `build:` key — an overlay with another name
  is scanned too.
- **`sandbox-services.sh`** — runs on the host, invoked by the wrapper. It
  must find its `compose.yaml` **relative to itself**
  (`dirname "$(readlink -f "$0")"`), not under the clone: the wrapper runs a
  copy taken before the sandbox started, and the clone's copy is untrusted by
  the time `down` runs. The wrapper passes positional arguments only and sets
  no environment. The hook itself must export every variable the compose
  interpolates — `SANDBOX_SOCKETS_DIR` from its first argument, `SANDBOX_UID`
  from `id -u` — before it runs `docker compose`.
  - `up <sockets-dir> <clone-dir> <project-name>` — `docker compose up -d
    --wait` plus whatever readiness polling the services need, then write
    `<clone-dir>/.env.sandbox` pointing the project's config at the sockets.
  - `down <project-name>` — remove everything the project created. It gets
    only the project name and no clone path, and the wrapper kills it after
    120 seconds. The version-proof reference sweeps by the compose project
    label and needs no compose file at all:

    ```bash
    docker ps -aq --filter "label=com.docker.compose.project=$project" | xargs -r docker rm -f
    docker volume ls -q --filter "label=com.docker.compose.project=$project" | xargs -r docker volume rm
    docker network ls -q --filter "label=com.docker.compose.project=$project" | xargs -r docker network rm
    ```

    `docker compose down -v --remove-orphans` also works, but only when every
    compose file the project used sits inside the hook directory and parses
    with no environment set (give every interpolated variable a default). A
    compose that overlays the project's own base file cannot be re-parsed
    here: the copy the wrapper runs has no clone.
- **`provision-ro`** — optional. A newline list of untracked, repo-relative
  paths (a `.venv`, say) to bind read-only from the origin into the clone at
  the same path. A relocated venv still runs; only console-script shebangs,
  which hardcode the origin path, break — invoke tools as
  `.venv/bin/python -m <tool>`, never as `.venv/bin/<tool>`.

**Permissions.** The sockets directory must be writable by the container's uid.
Prefer running the service as the host uid — `user: "${SANDBOX_UID}"` in the
compose, which the hook exports (`id -u`) — where the image allows it. Keep
password/scram auth on a database socket, so a world-readable socket is not an
open database.

**Trust.** The hook is committed host-side code, so it runs only when it is
trusted: never with `--no-services`, and — when a caller passes
`--services-trust-ref <ref>`, as a review of an untrusted pull-request head
does — only if the checked-out ref did **not** change
the `sandbox-services` contract relative to that ref. So a pull request that
introduces or edits the hook cannot make it run, and neither can `provision-ro`
from such a ref expose an origin secret. `provision-ro` itself refuses any
entry that escapes the repo (an absolute path, a `..`, or a symlink resolving
outside).

**Teardown and orphans.** `down` runs on the same cleanup path that fires
however the session ends — a normal exit, an error, or a kill. A session
`SIGKILL`ed before that fires can leave a `claude-*` compose project behind;
the next run's teardown sweeps orphaned `claude-*` projects whose run
directory is gone. To clear any by hand:

```bash
docker compose ls -a --format json | jq -r 'if type == "array" then .[] else . end | .Name' | grep '^claude-fork-sandbox-'
docker ps -aq --filter label=com.docker.compose.project=<name> | xargs -r docker rm -f
```

Pass `--no-services` to skip the whole mechanism for a run.

## Review before building

The sandbox contains the session while it runs. It does not make the code it
wrote safe. The fetched branch is agent-written code, and a `Makefile`, a
`package.json` script or an `.envrc` in it runs on the host the moment anyone
builds it. Read the diff first, exactly as you would a pull request from a
stranger. Always say this when you report.

## Afterwards

Every run's end lands in the durable run log, `~/.claude/sandbox-runs.jsonl`,
on its own — harness, model, exit, commits, tokens, cost, the `--task-meta`
object, and an archived copy of the handoff. What only the launching session
knows is whether the work was any good; record that after review, joined by
the run directory's basename:

```bash
sandbox-run-log.py verdict <run-id> --outcome integrated
```

Outcomes: `integrated`, `integrated-with-fixes`, `rescued`, `rejected`,
`abandoned`. `sandbox-run-log.py list` and `stats` read the log back.

The clone stays at the path the launcher printed. Delete the run directory
when the branch has been reviewed:

```bash
rm -rf <run-dir>
```

The tmux session closes itself when the run ends, so there is nothing to tidy
up there. Everything it printed is in the run directory.

## If it goes wrong

- **No commits, branch removed.** The session did work but never committed, or
  it failed early. Read `fork-sandbox-status.sh --result <run-dir>` and
  `--log <run-dir>`. The clone still holds whatever it wrote.
- **`abandoned`.** The tmux session was killed, or the runner was. Nothing was
  fetched; the clone still holds the work.
- **Non-zero exit.** `--log <run-dir>` carries the sandbox wrapper's own
  errors — an expired access token is the common one.
- **An addendum was never acted on.** Check the count in the status block
  against the `◆ fork-sandbox-inbox: delivered` lines in `--monitor` or
  `--follow`: written but never delivered means the run ended first, while
  delivered but ignored usually means it was worded like a prompt injection —
  see "Steering a run". `fork-sandbox-say.sh` refuses a run that has already
  ended, so a message it accepted did reach a live session.
