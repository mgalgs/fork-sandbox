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

## Skills

The `skills/` directory is for the agent that *orchestrates* runs, not the one
inside the sandbox:

- **`fork-sandbox`** — how to launch a run, watch it, and read what came back.
- **`sandbox-coder-mode`** — a standing mode: the session stops writing code
  and becomes an orchestrator, reviewer and integrator, delegating every edit
  to a sandboxed run. An expensive model plans and reviews while a cheap or
  self-hosted one does the typing.
- **`commit-then-review`**, **`code-review-portable`** — the review kit, bound
  into every run.

`install.sh` links them into Claude Code's skills directory, the
`~/.agents/skills` convention, and pi's. Codex users can point at the scripts
directly; the skills are markdown, readable by anything.

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
