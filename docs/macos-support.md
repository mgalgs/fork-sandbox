# macOS support

The sandbox backend contract has a container implementation, and on macOS the
runtime's Linux VM supplies the kernel that bubblewrap cannot. That was the
hard part, and it was already done. What remained was the layer *above* the
sandbox, which still assumed it was running on the machine it was sandboxing.

This document is what that layer needed, what was built, and what a Mac still
has to confirm.

## Getting it running

```bash
brew install bash coreutils util-linux   # util-linux is keg-only: add its bin to PATH
./install.sh --check                     # names anything still missing
./scripts/build-sandbox-image.sh         # the userland the sandbox runs
export FORK_SANDBOX_BACKEND=container
export FORK_SANDBOX_CONTAINER_IMAGE=fork-sandbox:latest
```

From there every command is the same as on Linux.

## Three gaps, not one

The README used to name two blockers. There were three; the third had not been
written down anywhere.

1. **Toolchain source.** The callers resolved the agent CLI, node, and several
   caches on the host and bound them into the sandbox. A Mach-O binary cannot
   run in a Linux container.
2. **Host-script portability.** Everything above the sandbox is bash, and it is
   *GNU* bash-4 with GNU coreutils. macOS ships bash 3.2 and BSD userland.
3. **Credential location.** On macOS, Claude Code keeps its OAuth credential in
   the login Keychain rather than in `~/.claude/.credentials.json`.
   `claude-sandboxed` required that file and exited when it was missing, so a
   Mac never reached the sandbox at all.

Gap 3 was the one that bit first, before any of the interesting work ran.

## Gap 1: where the toolchain comes from

### The property is the backend's, not the host's

The temptation is to branch on `uname -s`. That is wrong, and testing it shows
why: a **Linux** host running the container backend has exactly the same
problem. The image's `/usr` is not the host's, so a host binary bound into it
is missing its interpreter and its shared libraries. It is Mach-O-versus-ELF on
a Mac and glibc-versus-musl on Linux, but it is one property either way:

> Does the sandbox inherit the host's userland, or does it bring its own?

bwrap mounts the host's `/usr`, so its toolchain is the host's. A container
gets its toolchain from its image. That is a fact about the **backend**, and
deriving it from the backend rather than from the host had a second benefit
that decided the whole verification plan: **the image-toolchain path is fully
exercisable on Linux.** Almost all of this was written and tested there, before
a Mac was involved at all.

### The contract addition

```
sandbox-backend-<name> --capabilities
```

Prints `key=value` lines and exits 0, running nothing. One key is defined:
`toolchain`, either `host` or `image`. bwrap answers `host`; the container
backend answers `image`. A backend that does not implement the option exits
non-zero, and callers read that as `host` — the status quo, so a backend
written against the earlier contract keeps working unchanged. Output from a
failed call is never parsed, because usage text can contain an `=` and reading
that as a declaration would be inventing an answer out of an error message.

`fs_backend_capabilities` in the library queries once and fills
`FS_BACKEND_TOOLCHAIN`. Callers branch on that and never on a backend name.

### What changed in each caller

- **`claude-sandboxed`** no longer resolves or binds the host's claude in image
  mode; the command becomes `claude`, found on the sandbox's own PATH. The
  credential copy, the synthesized `~/.claude` and the onboarding file are
  unchanged — they are data, not binaries, and travel to any sandbox.
- **`fork-sandbox.sh`**, in all three of its claude, codex and pi arms, skips
  the host resolution and the `--bind-ro` of the node tree, and invokes the
  agent by name. The codex JWT expiry check reads `~/.codex/auth.json`, which
  is data and still works.
- **`fs_resolve_pi`** answers with `FS_PI_ARGV0=(pi)` and empty `FS_PI_ROOT`
  and `FS_PI_BIN_DIR`, so its two callers need one branch rather than five.
- **`fs_node_provision`** does not bind an `.nvmrc` node, and says which
  version it did not honour.
- **`fs_venv_interpreter_bind`** does not bind a uv or pyenv interpreter, and
  warns that the venv will not run.
- **`fs_cache_binds`** splits by what a cache holds. The Hugging Face cache is
  model *data* and still travels. The Playwright cache is browser *binaries*
  and does not.

**A bug this exposed.** Several of those paths short-circuited on `/usr`, on
the reasoning that "/usr is mounted already". Under the container backend that
reasoning is false: `/usr` inside is the image's. So a distro-packaged codex
under `/usr` was silently absent inside a container run — on Linux, today,
before any of this was about macOS.

### `node_modules` — copied, scanned, and warned about

`fs_node_provision` copies the host's `node_modules` into the clone so a run
can execute a suite without a network install. Nearly all of that tree is
JavaScript and runs anywhere. A few packages also carry a compiled `.node`
file, built for one OS and one CPU. Under bwrap those are the right binaries.
Under an image they are not, and the failure is a throw from deep inside node
with nothing to say the platform is the reason.

**Decision: keep the copy, and scan it.** The all-JavaScript case is the common
one and stays fast and offline. In image mode the provisioning step looks for
`.node` files in the copied tree and, when it finds any, warns once and names
them. A baffling runtime error becomes a sentence at launch, for almost no cost.

Rejected: skipping the copy entirely (fails cleanly, but costs a network
install on every node run), and `npm rebuild` inside the image (correct, but
costs a container start per run and needs a compiler toolchain in the image).

## Gap 2: host-script portability

Found by survey, each a specific line rather than a guess. The chosen approach
was the hybrid: fix what is small and low-risk, and require Homebrew for the
rest.

**Fixed.** `realpath -m`, `realpath -e`, `realpath -s` and `stat -c` are GNU
flags that the BSD tools of the same name do not have. Under Homebrew,
coreutils installs them as `grealpath` and `gstat` and is keg-only, so the
plain names still resolve to BSD's. The library now resolves each once, and
every call site keeps its GNU flags. Resolving the *name* rather than growing a
second BSD spelling is deliberate: an unexercised portability branch is a bug
waiting for the one person who runs it.

**Required instead of rewritten.** `bash` 5 (macOS ships 3.2, and the scripts
use `mapfile` and `${var,,}`), `flock`, and GNU `coreutils`. `install.sh
--check` enforces all three, and checks the bash that `#!/usr/bin/env bash`
would actually find rather than the one running the installer.

**Also fixed, because the first version of this document was wrong about it.**
`timeout` and `xargs -r` appear in the per-run services teardown, which an
earlier draft called a Linux-only path. It is not. There is no `--services`
flag: services are opt-*out* (`--no-services`), and they turn on automatically
whenever a repo carries a `sandbox-services.sh` hook and `docker` is on `PATH`
— and `install.sh` makes docker a *required* dependency on Darwin, so that
condition holds by construction on exactly the platform the claim excluded.

macOS ships no `timeout` at all, so the teardown would have failed into its own
`|| true` and leaked the compose stack silently, with the orphan sweep meant to
catch that leak failing identically. `timeout` now resolves like `realpath` and
`stat`; `xargs -r` is gone, since BSD xargs rejects the flag rather than
ignoring it, replaced by testing the list for emptiness in the shell.

## Gap 3: the credential on macOS

`claude-sandboxed` required `$HOME/.claude/.credentials.json` and exited when
it was missing. On macOS the CLI stores the OAuth credential in the login
Keychain instead.

**Evidence, and its limit.** The Linux claude binary contains both a
`.credentials.json` path and a `security find-generic-password` invocation —
both platform branches are in the bundle. That is strong evidence, but it is
inference from a Linux build, so **the service name is still unconfirmed** and
is the one thing here a Mac has to settle.

The implementation is arranged so that confirming it is a one-line change:
`FS_CLAUDE_KEYCHAIN_SERVICES` in `fork-sandbox-lib.sh` is a list of candidate
service names, each tried in turn, and the failure message says how to find the
right one by hand. A Keychain item that does not parse as a credential is
skipped rather than carried into the sandbox to fail as a 401 an hour later.

Two properties fell out of the design and are worth stating:

- It is read **once, at launch, on the host**. Reading the Keychain can prompt,
  and a prompt has no place inside an unattended run.
- The value never reaches an argv. It is held in a variable and piped with
  `printf`, a builtin, so `ps` and `/proc` never show it. That is also why the
  reader does not report *where* it came from through a variable of its own —
  a caller can only take the JSON through a command substitution, and a
  subshell cannot set a variable in the shell that started it, so such a
  variable would read empty at exactly the moment an error message wanted it.
  `fs_claude_credential_source` answers that question separately.

## The image

[images/sandbox/Dockerfile](../images/sandbox/Dockerfile), built by
`scripts/build-sandbox-image.sh`.

**Base: `node:22-bookworm-slim`** — glibc rather than musl, because the agent
CLIs ship prebuilt native binaries and glibc is the better-tested target, and
because a host `node_modules` copied from a glibc Linux host at least matches.
On top: `git`, `jq`, `ca-certificates`, `iproute2` (pinned mode), `socat`
(bridges), `procps`, `less`, `ripgrep`, `python3`, and the three agent CLIs.

Each CLI is installed with `npm install -g`, into `/usr/local`, and never into
a home directory — `$HOME` inside the sandbox is a fresh tmpfs, so anything
under it would simply not be there. That rules out claude's native installer,
which targets `~/.local/bin`. `--claude`, `--codex` and `--pi` pin a version or
take `none` to leave an agent out. `/etc/fork-sandbox-image` records what
went in.

It is a **base**, not a universal answer: a repo whose suites need a compiler,
a database client or a browser should build its own image `FROM` it and name
that instead. Keeping this one small is deliberate.

It is also a **supply-chain surface**. It holds the agent CLIs, and a run hands
them the user's access token. There is no registry copy to pull, deliberately:
you build the thing you trust.

## What is verified, and how

Because the toolchain question is asked of the backend rather than of the host,
`FORK_SANDBOX_BACKEND=container` on Linux exercises **the same code path a Mac
takes**. Verified there, end to end: a real agent session in the shipping
image, committing, with the branch fetched back — under both backends, so the
default path is covered against regression as well as the new one.

`tests/fork-sandbox-toolchain-test.sh` covers the contract addition on both
real backends, every way a backend can fail to answer it, and each provisioning
function's behaviour under both toolchains.

One bug was found and fixed along the way: the container backend redirected a
background `docker start` from `/dev/stdin`, which cannot be opened when the
caller's stdin is **closed** rather than merely empty — a script run from a
harness, a cron job or a tmux runner. Every pinned run died before the command
started. It failed closed, and it is fixed.

## What still needs a Mac

Everything below fails closed, so the consequence is a refused run rather than
a sandbox quietly holding less than it claims.

1. **The Darwin routing branch**, which builds pinned egress. It has never
   executed on a Mac. `tests/sandbox-backend-container-test.sh` drives it on
   any host with stubbed `uname`, `route`, `netstat` and `ifconfig`, but the
   fixture is representative rather than captured. With that fixture the
   LAN-restore loop emits only the router's `/32`, which on a Mac would leave
   pinned mode reaching the router and no other LAN host — contradicting
   guarantee 3. **Pasting real `netstat -rn -f inet` and `ifconfig` output from
   a Mac into that fixture settles it in one step**, and is the cheapest useful
   thing a Mac owner can contribute.
2. **The Keychain service name**, as above.
3. **Unix-socket bridges**, and so `--harness pi-local`, which is sealed plus a
   bridge. Docker Desktop and Colima share files over virtiofs or a FUSE
   gateway, and unix sockets generally do not survive that.
4. **Per-run services**, which drive Docker Compose on the host from inside a
   run. These are opt-out rather than opt-in, so a repo that ships a
   `sandbox-services.sh` hook gets them on a Mac whether or not anyone planned
   for it. Their GNU-tool dependencies are fixed, but the path as a whole has
   not been exercised on macOS — in particular whether the sockets the services
   publish survive Docker Desktop's filesystem sharing, which is the same
   open question as the bridges above. `--no-services` turns them off.
