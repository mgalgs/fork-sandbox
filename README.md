# fork-sandbox

Run a coding agent unattended, in a sandbox, on a throwaway clone of your repo —
then get the work back as a branch.

```bash
fork-sandbox.sh ~/src/myproject /var/tmp/claude-scratch/handoff.md
```

That command clones the project, starts a headless agent inside a bubblewrap
sandbox with no access to your home directory, waits for it to finish, fetches
its branch back into your repo, and appends what it cost to a run log. You get
a run directory to watch and a branch to review. Your checkout is never
touched.

Or from an interactive session, where the skill writes the handoff for you:

```
/fork-sandbox fix the flaky tests
```

You can also tell your agent to delegate all implementation tasks to sandboxed
agents with `/sandbox-coder-mode`:

```
/sandbox-coder-mode

fix the flaky tests
...
juice up the flux capacitor
...
rule the world
```

It runs **Claude Code**, **pi**, or **codex**, against a hosted API or against
a model on your own hardware.

> **Linux by default; macOS through a container.** The default isolation is
> bubblewrap plus a network namespace, which macOS has no equivalent for. A
> container backend implements the same contract and is the macOS path: build
> the sandbox image, set two environment variables, and the same commands work.
> Two macOS-specific properties are still unverified, and both fail closed —
> see [Portability](#portability).

## Why

There are two usual ways to run a coding agent. Approve every action by hand,
which is slow and turns into rubber-stamping after the twentieth prompt. Or
turn approvals off and let it work in your checkout, where a mistake — or a
prompt injection in something it read — lands in your real repo, with your ssh
keys, your dotfiles and your VPN in reach.

fork-sandbox does neither. The agent works in a disposable clone, inside a
sandbox that contains no `~/.ssh`, no `~/.aws`, no dotfiles, and no route to
your VPN or tailnet. The only thing that comes out is a git branch, fetched
back into your repo when the run ends.

What you get:

- **Nothing to babysit.** Headless: no keypress, no attached terminal. It
  exits on its own and writes down what happened.
- **Containment.** The sandbox sees the clone, the host toolchain, and nothing
  else of yours. Egress goes out your default interface only, so a VPN or
  tailnet the host can reach, the sandbox cannot. Or seal the network
  entirely.
- **Free runs against your own model.** Point it at a model you host and the
  sandbox gets *no network at all* — the endpoint arrives over a unix socket.
  The tokens are yours, no credential is inside, and there is nowhere to
  exfiltrate to.
- **Steering without attaching.** `fork-sandbox-say.sh` sends a running
  session an addendum, delivered at its next tool call.
- **A record.** Every run appends harness, model, tokens, cost and commits to
  a log you can query later — which is how you find out whether the cheap
  model was actually cheaper.

## Install

```bash
git clone https://github.com/mgalgs/fork-sandbox ~/src/fork-sandbox
cd ~/src/fork-sandbox
./install.sh --check     # report what is missing
./install.sh             # symlink scripts onto PATH, skills into the farms
```

Everything installs as symlinks back into the checkout, so upgrading is
`git pull`.

You need `bwrap`, `pasta`, `git` and `jq`. `tmux`, `socat`, `setsid`, `docker`
and `python3` each unlock a harness or a flag, and `--check` names which.

Read [docs/permissions.md](docs/permissions.md) before adding any allowlist
rules. A blanket approval is permanent, and the doc explains what each script
does and does not let a caller do.

## How a run works

1. **Write a handoff.** A markdown file: the task, the constraints, what
   "done" means. It is the run's entire prompt — there is nobody to ask a
   follow-up.
2. **Launch it.** `fork-sandbox.sh <project> <handoff>`. It clones, provisions
   (`node_modules`, a venv, a service stack), and starts the agent detached.
3. **Watch, or don't.** `fork-sandbox-status.sh <run-dir>` prints the state,
   `--result` the final report, `--events N` the last N events, and
   `--monitor` a line-oriented feed an orchestrating agent can poll.
4. **Read the branch.** It is fetched back into your repo. Review it like a
   pull request from a stranger — a `Makefile` or a `package.json` script in
   it runs on *your* host the moment you build.

Pass `--review-loop 2` and the branch gets a quality pass before it comes back
in step 4: a fresh session reviews the commits the run just made and writes a
verdict, and if it found problems a third session fixes them and commits. That
repeats until the review approves, until a fix session stops making progress,
or until the count runs out. Each leg is a whole session at its selected
model's price, so reach for it when a defect would be expensive to find later — and
freely on a model you host yourself, where it costs nothing.

Add `--review-model <model>` to run only the review legs on a different model.
Fix legs continue to use `--model`, keeping the original implementation model
responsible for applying the findings.

The launcher accepts either `--model sol --harness codex` or the pasteable
combined form `--harness codex/sol`. It resolves personal aliases from
`~/.config/fork-sandbox/aliases.conf` first, then Codex aliases against the
models its local cache actually offers. Use `--dry-run` to print the resolved
harness and model without creating a run, or `--model-unchecked` to send a new
model id verbatim before it appears in the cache.

## A run that refreshes itself

An interactive session that fills its context window writes a hand-off and
forks a fresh session rather than degrade into compaction. `--refresh-at`
gives an unattended run the same move, with no human in the loop.

Its default is on: `--refresh-at 0.5` nudges a session, once, when it has used
half its model's context window, to finish the step it is on, commit, write a
self-contained hand-off to a writable outbox, and end its turn. If it does,
the run moves that hand-off to `<run-dir>/handoff-N.md` — the record — and
starts a fresh session on the *same clone and branch* with it as the prompt:
continuation N, with no memory of the session before it. Every continuation
also gets the original hand-off this run was launched with, embedded
verbatim ahead of the previous leg's own, so a long chain never loses track
of the task itself. That repeats, on the same nudge-and-check cycle, until a
leg ends with nothing waiting in the outbox — the ordinary ending — until
`--refresh-max` legs have run (default 6), or until a nudged leg ends its
turn without writing a hand-off at all. `--review-loop`, when both are given,
then runs once, after the *last* coding leg, over every commit the whole
chain made.

A session can keep working and committing for a long time after writing its
hand-off without ever rewriting it, which would start the next leg from a
document that no longer describes reality. If a hand-off already sitting in
the outbox predates the clone's last commit by the time that leg tries to
end its turn, it is sent back once to rewrite it; if the leg ends anyway
(crash, timeout), the continuation it forks is warned in its own prompt
instead.

```bash
fork-sandbox.sh --branch "<branch>" "<path>" "<handoff>"                # on by default
fork-sandbox.sh --refresh-at 0 --branch "<branch>" "<path>" "<handoff>" # disabled
fork-sandbox.sh --refresh-at 100000 --refresh-max 3 \
    --branch "<branch>" "<path>" "<handoff>"                           # an absolute token count
```

It costs what it looks like it costs: each continuation is another whole
session, at the same model's price. `<run-dir>/summary.json`'s
`continuations` array and `refresh` field say what happened — how many legs
ran, each one's exit, cost and usage, and how the chain ended — and
`total_cost_usd` folds every continuation in beside the review loop's own
legs, the same way it already does for `--review-loop`.

**`claude` only, for now.** The threshold is measured by a hook installed into
the local sandbox's claude session, which reads the transcript on every tool
call; `pi`, `pi-local` and `codex` have no hook system to measure with, so
`--refresh-at` is refused outright on those harnesses, and on `--k8s`, whose
pod runs a different entrypoint.

## The three network modes

Every run is in exactly one of these, and the mode decides what a compromised
or misled agent can reach.

| Mode | Reaches | Use for |
|---|---|---|
| **Pinned** (default) | The internet, via your default interface only. Not the VPN, not the tailnet, not host loopback. | A Claude or OpenRouter run that needs to fetch packages and read docs. |
| **Sealed** (`--harness pi-local`) | Nothing. One OpenAI-compatible endpoint over a unix socket. | A model you host. Costs nothing, holds no credential, cannot exfiltrate. |
| **Serviced** (`--services`) | Whichever of the above, plus a per-run compose stack on unix sockets. | A suite that needs postgres or redis to run. |

Sealed mode is why a local model is worth the trouble. A local endpoint needs
no API key, so there is no credential in the sandbox to steal, and with no
network there is nowhere to send anything anyway. The run costs nothing, so a
wrong answer wastes only time.

## Harnesses

| `--harness` | Runs | Credential in the sandbox |
|---|---|---|
| `claude` (default) | Claude Code | A short-lived access token |
| `pi` | [pi](https://github.com/earendil-works/pi) against OpenRouter | Your OpenRouter key |
| `pi-local` | pi against your own endpoint | **None** |
| `codex` | Codex CLI | Your ChatGPT auth |

Every harness gets the same clone, the same provisioning, the same fetch-back,
and a review kit — two skills that let the run review its own work before it
reports back.

`pi` and `pi-local` read their per-machine config (an OpenRouter key, a
model endpoint) from `~/.config/fork-sandbox/`. `fork-sandbox.sh configure`
discovers and installs it for you — see [docs/configure.md](docs/configure.md).

## Skills

Five skills ship with the package. They are plain markdown, readable by any
agent; `install.sh` links them into Claude Code's skills directory, the
`~/.agents/skills` convention, and pi's. Codex users can point at the
scripts directly.

For the session that orchestrates runs:

- **`sandbox-coder-mode`** — the workhorse. A standing mode: your session
  stops writing code and becomes orchestrator, reviewer and integrator;
  every edit happens in a sandboxed run on its own branch. The expensive
  model plans and reviews, a cheap or self-hosted one types. See
  [Driving sandbox-coder-mode](#driving-sandbox-coder-mode) below.
- **`fork-sandbox`** — one run at a time: launch it, watch it, read what
  comes back.
- **`lkml-mode`** — review a patch series the way the Linux kernel mailing
  list does: a shared mailbox, a panel of AI-persona reviewers (a Linus
  Torvalds caricature always among them) replying in threads from their own
  sandboxed runs, an author persona posting v2, v3... until the right
  reviewers sign off and no NAK stands. For a change that deserves several
  adversarial voices — not a diff you can read yourself.

Bound into every run, for the agent inside the sandbox:

- **`commit-then-review`**, **`code-review-portable`** — the review kit:
  commit, then find and verify defects before reporting back.

### Driving sandbox-coder-mode

Start it, speak in goals, end it with a sentence:

```
/sandbox-coder-mode          # or: /sandbox-coder-mode --long

fix the flaky tests
...
exit sandbox coder mode
```

What to expect while it is on:

- Coding work dispatches by its shape, not its origin: a build becomes a
  sandboxed run on an `sbx-` branch, while a small, self-contained edit —
  right by reading, a few lines across a file or two — executes
  in-session. The session reports each sandboxed round in a few lines —
  branch, what landed, whether the suites pass on the host, any caveat —
  and quotes the cost every round.
- The composition is yours, not the session's: runs launch at the mode's
  defaults (a light model implements, a stronger one reviews, up to two
  review loops), overridable per machine in
  `~/.config/fork-sandbox/coder-mode.env`. The session never lowers the
  review on its own; a deviation is announced in one line.
- Steer a round in flight by just saying so — the session relays the
  correction into the running sandbox as an operator addendum, without
  restarting it.
- Nothing is pushed until you say "push". Integrated-but-unpushed work
  accumulates on your working branch, and the session names the count.
- `--long` is the many-rounds-across-hours variant: the same mode, with
  more discipline about commits, handoffs between context windows, and
  distrust of a run's own self-report.

## Portability

The scripts above the sandbox are ordinary bash. The sandbox itself is
bubblewrap, pasta and network namespaces, all Linux-specific. That layer is a
**backend interface**: one executable per isolation mechanism, behind a fixed
contract, chosen with `FORK_SANDBOX_BACKEND`. Two implementations exist —
`sandbox-backend-bwrap`, the default, and `sandbox-backend-container` — and
`claude-sandboxed` and `agent-sandboxed` are their callers. The contract is
written down in [docs/sandbox-backend.md](docs/sandbox-backend.md).

Kubernetes is deliberately **not** a third backend. In a cluster the pod is
already the sandbox, and the contract's host-path options do not survive the
trip to another node — so the whole *run* moves there instead of one command.
That is designed in [docs/kubernetes-runs.md](docs/kubernetes-runs.md), and it
is not built either.

macOS's own `sandbox-exec` is not a substitute: its network control is
allow-all-or-nothing, so pinned egress and the sealed bridge cannot be
expressed with it. Running the sandbox in a Linux container is the realistic
path, which is what `sandbox-backend-container` is for: there the runtime's
Linux VM supplies the kernel, so the port becomes a second backend rather than
a translation.

### Running it on macOS

```bash
brew install bash coreutils util-linux   # util-linux is keg-only: add its bin to PATH
./install.sh --check                     # says what is still missing
./scripts/build-sandbox-image.sh         # the userland the sandbox runs
export FORK_SANDBOX_BACKEND=container
export FORK_SANDBOX_CONTAINER_IMAGE=fork-sandbox:latest
```

From there the commands are the same as on Linux.

The image is the part worth understanding. bwrap mounts the host's `/usr`, so
a bwrap sandbox borrows the host's tools; a container's userland is its
image's. So the agent CLIs, node and git live in the image rather than being
bound in from the host — which is what makes a Mac possible at all, since a
Mach-O binary cannot execute in a Linux container. The callers ask the backend
which case they are in (`--capabilities`, in the contract) rather than testing
`uname`, because a *Linux* host running the container backend has the same
problem: the image's `/usr` is not the host's either.

That image holds the agent CLIs and a run hands them your access token, so it
is a supply-chain surface. There is no registry copy; you build it from
[images/sandbox/Dockerfile](images/sandbox/Dockerfile), and a repo needing more
than the base should build its own image `FROM` it.

### What is still unverified on macOS

Three things have never executed on a Mac. The first two fail closed, so the
consequence there is a refused run rather than a sandbox that quietly holds
less than it claims:

- **The Darwin routing branch**, which builds pinned egress.
  `tests/sandbox-backend-container-test.sh` drives it on any host with stubbed
  Darwin commands, but the fixture is representative rather than captured.
  Replacing those stubs with real `netstat -rn -f inet` and `ifconfig` output
  from a Mac is the one step that settles it, and the cheapest useful thing a
  Mac owner can contribute.
- **Unix-socket bridges**, and so `--harness pi-local`, which is sealed plus a
  bridge. Docker Desktop and Colima share files over virtiofs or a FUSE
  gateway, and unix sockets generally do not survive that.
- **Per-run services.** These are opt-*out*, so a repo carrying a
  `sandbox-services.sh` hook gets them on a Mac whether or not anyone planned
  for it. Whether the sockets they publish survive Docker Desktop's filesystem
  sharing is the same open question as the bridges. `--no-services` turns them
  off.

[docs/macos-support.md](docs/macos-support.md) has the full design and the
remaining checklist.

## What this does not protect you from

Namespace isolation is not a virtual machine. There is no seccomp filter, and
a kernel bug still breaks out. A non-sealed run reaches your LAN as *this
machine* — pasta re-originates its connections from the host address, so
anything on your network that trusts IP rather than a credential trusts the
sandbox too. And the sandbox contains the session only while it runs; it does
not make the code it wrote safe. That is what the review is for.

[docs/claude-sandboxed.md](docs/claude-sandboxed.md) has the full account:
what is mounted, what is not, and a numbered list of the gaps.

## Documentation

- [docs/sandbox-quickstart.md](docs/sandbox-quickstart.md) — start here; the
  levels, from a plain run to a sealed one with services.
- [docs/configure.md](docs/configure.md) — `fork-sandbox.sh configure`:
  discover and install the per-machine config above, and how to add a
  discoverer of your own.
- [docs/claude-sandboxed.md](docs/claude-sandboxed.md) — the sandbox itself.
- [docs/sandbox-services.md](docs/sandbox-services.md) — the committed
  contract a repo uses to declare its service stack.
- [docs/permissions.md](docs/permissions.md) — running these without a prompt.
- [docs/sandbox-backend.md](docs/sandbox-backend.md) — the isolation contract
  and its two implementations.
- [docs/kubernetes-runs.md](docs/kubernetes-runs.md) — running a whole run in a
  cluster, and why that is not a backend. Design only.
- [docs/sandbox-backend-container.md](docs/sandbox-backend-container.md) — the
  container backend: mechanism, threat model, and limits.

Every script also documents itself: run it with `--help`, or read the header
comment, which is the same text.

## License

MIT — see [LICENSE](LICENSE).
