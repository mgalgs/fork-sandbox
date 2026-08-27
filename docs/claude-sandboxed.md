# `claude-sandboxed`: design notes and future work

Why this script exists, what it does not protect against, and the options we
have already evaluated. The script's own header documents the current
behaviour; this file records the reasoning and the open questions.

The isolation itself lives in `sandbox-backend-bwrap`, which `claude-sandboxed`
calls; `claude-sandboxed` is the Claude client of it — the credential copy, the
synthetic `~/.claude`, the onboarding file, the transcript rescue. Everything
below about mounts, namespaces and egress therefore describes the backend, and
its header is where those properties are stated in full. What holds has not
changed; where it is implemented has. See
[sandbox-backend.md](sandbox-backend.md) for the contract.

## Why not Claude Code's built-in sandbox

Claude Code ships a sandboxed Bash tool (`/sandbox`). It uses bubblewrap on
Linux, the same primitive this script uses, but it covers a different scope:
Bash commands and their children only. The Read, Edit and Write tools, MCP
servers and hooks all run unconfined on the host.

Anthropic's own guidance is that the built-in Bash sandbox "is not sufficient
for fully unattended runs", and that a `--dangerously-skip-permissions`
session belongs inside a container, a VM, or the sandbox runtime. This script
is in that last category: it wraps the whole `claude` process.

Two more differences worth knowing:

- The built-in sandbox allows reads almost everywhere by default. The docs say
  plainly that `~/.aws/credentials` and `~/.ssh/` stay readable unless you add
  `credentials` or `denyRead` entries. Our allowlist makes them absent.
- Its network model is a proxy with a domain allowlist, default deny. We want
  unrestricted egress, so that layer does not fit.

## Known gaps in the current design

Ordered by how much they matter.

1. **No seccomp filter.** Verified inside the sandbox: `Seccomp: 0`. `keyctl`,
   `add_key`, `bpf`, `userfaultfd` and `perf_event_open` are all reachable.
   These are the historic source of kernel privilege escalations. This is the
   one gap that would meaningfully change the breakout story.
2. **Namespaces, not a virtual machine.** A kernel bug breaks out. Only a VM
   fixes this.
3. **The access token is inside the sandbox.** Whatever runs there can spend
   the subscription. Mitigated only in duration: the refresh token stays on
   the host, so a leaked copy dies at token expiry.
4. **Unrestricted egress is an exfiltration channel** for anything the sandbox
   can read. That is the deliberate trade for full internet.
5. **The local LAN is reachable.** LAN services that trust network position
   rather than a credential are exposed. Tunnels are not: egress is pinned to
   the default-route interface, so the tailnet, WireGuard and the libvirt and
   docker bridges are unreachable.
6. **No OS package installation.** See below.

## Sealed egress

`--seal-egress` removes the network instead of shaping it. No pasta runs;
bwrap unshares the network namespace, so the sandbox holds loopback and
nothing else — no internet, no LAN, no DNS.

The seal needs no packet filter to hold, because there is no interface to
filter. A namespace with nothing in it reaches nothing, and the sandbox cannot
put anything in it: `ip link set lo up` fails with `EPERM` in there, because
bubblewrap drops the capabilities that would allow it.

Two details are worth stating precisely, because both look like properties of
the kernel and are not.

- **bubblewrap brings `lo` up, not the kernel.** A fresh network namespace has
  `lo` DOWN — verified: `unshare -rn ip addr show lo` reports `state DOWN`.
  bubblewrap's own loopback setup is what raises it, which is what makes a
  loopback bridge possible at all. So the bridge depends on `--unshare-net`
  being bwrap's doing; a future switch to some other way of removing the
  network could silently take the loopback with it.
- **The capability drop is not absolute.** A process in there can still nest
  its own user and network namespaces and hold `CAP_NET_ADMIN` inside those.
  That changes nothing: the namespace it gets is empty too, and an interface it
  creates there is connected to nothing. The seal rests on there being no
  route out of any namespace it can reach, not on `EPERM` alone.

It changes the gap list above for such a run:

- **Gap 4 (exfiltration) closes.** There is nowhere to send anything.
- **Gap 5 (the LAN) closes.** Every service that trusts network position —
  a NAS export, an unauthenticated admin panel, a metrics endpoint — is
  unreachable.
- **Gap 3 (the token) does not apply.** Sealed mode requires `--exec`, so no
  Claude credential is ever copied in. A sealed run holds no secret at all
  unless `--env-file` names one.
- **Gaps 1 and 2 are unchanged.** Still no seccomp filter, still namespaces
  rather than a virtual machine.

A sealed sandbox with no way out is also a sandbox with no way to reach a
model, which is why the mode requires `--exec`: claude itself would die on its
first request. The way back in is one unix socket bound from the host.
`connect()` needs write permission on the socket inode, not a writable mount,
so a read-only bind of a sockets directory is enough — the caller publishes
exactly one service and nothing else. `agent-sandboxed` does that with a local
model endpoint; `sandbox-services` already did it with databases; and
`agent-sandboxed --bridge HOST:PORT[=INPORT]` carries extra endpoints in the
same way, one socket each, when a sealed run needs to reach more than the model
(a GPU embedder a test suite calls, say).

What a sealed run gives up is everything that fetches: no `npm install`, no
`pip install`, no documentation lookup. Whatever the run needs has to arrive
through the mounts.

## Option: adopt the sandbox runtime (`srt`)

`@anthropic-ai/sandbox-runtime` wraps an arbitrary process in the same
bubblewrap isolation, and it is the closest thing to this script that
Anthropic maintains.

What it would give us:

- **Pre-built static seccomp BPF filters** that block unix domain socket
  creation. This is exactly gap 1, solved and maintained upstream. It applies
  the filter after bubblewrap initialises, inside a nested PID namespace, so
  the sandboxed command cannot reach unfiltered helper processes.
- Deny-then-allow reads, so `~/.ssh` can be hidden.
- Whole-process isolation, the same scope we need.

What it would cost us:

- **Its network model is deny-all with a domain allowlist, served by host HTTP
  and SOCKS proxies.** That conflicts with the full-internet requirement. It
  is also proxy-based, so protocols that ignore proxy environment variables
  bypass it — a limitation the project documents itself.
- **No equivalent of egress interface pinning.** A domain allowlist cannot
  express "do not reach any of my private subnets through the VPN". Our pasta
  network namespace can.
- Beta research preview; the configuration format may change.

**Recommendation: borrow, do not switch.** The valuable part is the seccomp
filter. Investigate whether its `apply-seccomp` helper can be invoked from
this script while pasta keeps providing unrestricted egress. Falling back to
`srt` wholesale would trade our network model for their syscall filter.

## Option: move to a container or microVM

- **Container (docker or rootless podman).** Isolation is the default rather
  than a policy we maintain, and a writable image filesystem makes OS package
  installation trivial. Costs: an image to maintain, loss of the host
  toolchain, and on this host docker's daemon runs as root.
- **Docker Desktop `sbx`.** A microVM with its own kernel — the strongest
  boundary, and credentials stay on the host rather than inside the sandbox.
  Costs: Ubuntu-only official support, a reported severe performance hit, and
  it ignores `~/.claude`, so global CLAUDE.md, skills and scripts are absent.
  Its network policy is also default-deny, though an "Open" mode exists.

Revisit if the work shifts to genuinely untrusted code, where a kernel
boundary is the requirement.

## Option: writable `/usr` for OS packages (deferred)

Tested and deliberately not enabled.

`--overlay-src /usr --tmp-overlay /usr` does work, at uid 1000: `/usr` becomes
writable, host contents stay visible, writes land in an invisible tmpfs, and
the host `/usr` is untouched. That part is two arguments, not fiddly.

The feature is incomplete anyway:

- Overlaying `/var` fails with `Invalid argument`, and pacman's database lives
  in `/var/lib/pacman`. It would need its own narrower overlay.
- `pacman` requires euid 0. Running the sandbox as root-in-userns collides
  with claude refusing `--dangerously-skip-permissions` as root, though the
  docs note that check is skipped "inside a recognized sandbox".
- The overlay is ephemeral, so packages would be reinstalled on every run.

What already works without any change: pip, npm and cargo install into the
ephemeral `$HOME`. Extracting a `.pkg.tar.zst` into a writable `/usr` would
also work as uid 1000, with no package manager involved.

Revisit only if a real task is blocked by a missing OS package.

## The agent can build its own OS environment

Tested and working. This needs no change to the script, so it is a technique
rather than a feature: the agent decides which distro and version a project
needs, builds that environment itself in the work dir, and installs packages
into it. Image choice and upkeep move to the agent, per task.

The recipe:

1. Download a distro rootfs tarball with `curl`. Alpine's minirootfs is 3.6 MB;
   Ubuntu's base rootfs is 29 MB.
2. Extract it into the work dir. Ownership becomes the sandbox user, which is
   fine.
3. Copy `/etc/resolv.conf` into the rootfs so DNS works.
4. Enter it with a nested bwrap as uid 0:
   `bwrap --bind rootfs / --dev /dev --proc /proc --unshare-user --uid 0 --gid 0 ...`

Inside that nested sandbox the agent is root in its own user namespace, with a
writable filesystem, so package managers work.

Results:

- **Alpine works cleanly.** `apk add` installs and the tools run. gcc, make,
  git all work. Compiled C programs run. A toolchain environment takes 216 MB.
  Alpine is musl, so it is the wrong choice for reproducing glibc behaviour.
- **Ubuntu works with one flag.** Plain `apt-get` fails with
  "Method http has died unexpectedly": apt drops privileges to the `_apt`
  user, and only uid 0 is mapped. Passing `-o APT::Sandbox::User=root` fixes
  that. `apt-get update` then succeeds and gcc, make, pkg-config, and git
  install and work — verified by compiling and running a C program inside.
- **Arch does not work.** pacman itself calls `fchownat()` on its sync
  download directory, which fails with `EINVAL` for unmapped gids. pacman
  cannot even synchronise its database, so no packages can install.
- **Debian and Fedora have no standalone rootfs tarballs.** Debian's cloud
  images are disk images, not tarballs. Fedora's container images are OCI
  layers that need `skopeo`/`umoci` to extract. Both would need `debootstrap`
  or Docker layer inspection. Use Ubuntu (same package manager as Debian) or
  Alpine instead.

### dpkg chown errors on Ubuntu

dpkg reports errors from postinst scripts that call `chown` with group names
whose gids are not mapped in the user namespace (only gid 0 is mapped). The
error is `fchownat() ... failed: Invalid argument` (kernel returns `EINVAL`).

**fakeroot does not fix this.** Tested directly: fakeroot's LD_PRELOAD
intercepts `stat()` and returns fake ownership (verified: `stat` shows the
desired owner), but the `chown` command still exits 1 and prints the error.
The reason: fakeroot records fake ownership in a `faked` daemon, then calls the
real `fchownat()` syscall underneath, which returns `EINVAL` for unmapped gids.
The `chown` binary sees the error and exits non-zero. dpkg's postinst calls
`chown` as a command and checks its exit code, so the postinst fails.

dpkg `--force-*` flags (`--force-unsafe-io`, `--force-overwrite`,
`--force-all`) do not help either. The errors come from postinst scripts, not
from dpkg's own operations.

**Affected packages**: those with daemon users whose postinst scripts chown
files to non-root groups. Examples: `cron` (chowns to `crontab`), `rsyslog`
(chowns to `syslog`), `openssh-client` (chgrps `ssh-agent` to `ssh`),
`fontconfig-config` (chowns to `staff`).

**Unaffected packages**: development tools and libraries. `gcc`,
`build-essential`, `make`, `python3`, `git`, `pkg-config`, `tree`, and
similar packages install cleanly. Their postinst scripts do not chown to
non-root groups.

**Practical guidance**: install development packages freely. If a package
shows chown errors, check whether the binary you need is present anyway
(`command -v <tool>`). Avoid packages that create daemon users unless you do
not need the daemon to run.

### Distro comparison

| Distro | Rootfs tarball | Size (with toolchain) | Package manager workaround | Verdict |
|--------|---------------|----------------------|---------------------------|---------|
| Alpine | `alpine-minirootfs-*.tar.gz` (3.6 MB) | 216 MB | None needed | Best for most tasks |
| Ubuntu | `ubuntu-base-*.tar.gz` (29 MB) | 670–900 MB | `-o APT::Sandbox::User=root` | Best for glibc projects |
| Arch | `archlinux-bootstrap-*.tar.zst` (121 MB) | Unusable | pacman fails on chown | No |
| Debian | No tarball | N/A | N/A | Use Ubuntu |
| Fedora | No tarball | N/A | N/A | Use Ubuntu or Alpine |

### Other findings inside the rootfs

- **git** works. Initialise, add, commit all succeed.
- **/dev/shm** exists and is writable.
- **/dev/pts** exists (has `ptmx`).
- **Locales**: the minimal rootfs has no locale data. `LANG=en_US.UTF-8`
  triggers perl warnings. Functional, not blocking.
- **Seccomp**: `Seccomp: 0` — no filter applied. Same as the outer sandbox.
- **python3** is not in the Ubuntu base rootfs. Install with `apt-get`.

### Safety

Why this is safe: the nested sandbox inherits our namespaces and can only ever
subset them. Its uid 0 is root inside a nested user namespace that maps to the
real user, so it holds no host privilege. Verified separately: from a nested
namespace, `~/.ssh` still does not exist, and `bwrap --bind / /` plus a write
to `/etc` still fails read-only with nothing appearing on the host. Egress
also stays pinned, because the nested sandbox shares our network namespace.

Two practical limits. There is no `/dev/kvm`, so this gives containers, not
virtual machines. There is no init, so anything that needs systemd will not
start.

### Rootfs caching

A rootfs environment persists in the work dir between runs. Build once, reuse
on every subsequent run with the same work dir. The convention:

- `$WORK_DIR/rootfs-alpine/` for Alpine environments
- `$WORK_DIR/rootfs-ubuntu/` for Ubuntu environments

The agent checks for the directory on startup and skips the download if it
exists. A cached Ubuntu toolchain takes 670–900 MB. Alpine takes 216 MB. Work
dirs are not cleaned up automatically.

A shared cache across work dirs is not yet implemented. Each work dir holds
its own copy. For tasks that create many sandboxed runs on different work dirs,
this adds up. A future `--rootfs-cache DIR` flag could bind-mount a shared
cache read-only.

### Automating it

The steps above are worth wrapping in a script of your own once you use them
more than twice. Put it in the work dir rather than on the host toolbox path —
the sandbox does not mount `~/.claude`, so a helper reaches the agent by being
copied in beside the work:

    cp my-rootfs-helper.sh "$WORK_DIR/"
    claude-sandboxed "$WORK_DIR" ...

For an unattended run, the same steps can go in the handoff as a prompt block
instead, which costs nothing to maintain and is easier to vary per task.

### Why not docker or podman

- **docker** cannot work: the daemon socket is deliberately not mounted, and
  the daemon runs as root on the host. The CLI is present and fails to
  connect.
- **rootless podman** is not installed, and would struggle anyway.
  `newuidmap` and `newgidmap` are present but neutered: `NoNewPrivs=1` strips
  the setuid bit, so they fail with "Could not set caps". A `/etc/subuid`
  range exists on the host but is unusable without them, leaving a single uid
  mapping. Images that chown to several uids would fail to extract.

## Operational notes

- **A harness timeout does not kill the run.** A caller that stops waiting
  leaves the sandbox working. This happened: a caller reported the run as
  timed out while it went on to finish and write its deliverables. The
  per-work-dir lock exists because of it — a second run on the same work dir
  is refused, so a caller that clears the work dir first cannot destroy
  results still being written. The lock is the backend's, held outside the work
  dir at `/var/tmp/claude-scratch/forks/.sandbox-backend-lock-<hash>` and
  released by the kernel however the process ends. Check for live runs with
  `pgrep -af claude-sandboxed`, or `pgrep -af sandbox-backend` to catch a
  sealed pi run too.
- **The session transcript is copied into the work dir** on exit, under
  `claude-session/`. Without it, a killed run keeps its files but loses the
  agent's reasoning.
- **The session dies when the access token expires**, with no way to refresh.
  The script prints the remaining lifetime. Start long runs early in a
  token's life.
- **Commits work, pushing does not.** No key, token or agent is reachable.
  Work leaves the sandbox as files in the work dir.
- **The sandbox has none of the user-level Claude config.** No global
  CLAUDE.md, no skills, no utility scripts. This is deliberate: the global
  CLAUDE.md references scripts, hooks and tools that do not exist inside the
  sandbox. Mounting it would mislead the agent into calling absent helpers.
  Pass any needed conventions (working style, commit format) in the task
  prompt instead.
- **Services on the host itself are unreachable**, in either egress mode. Host
  loopback is not mapped, and the host's own LAN address belongs to the
  sandbox's namespace interface. A service published by DNAT, or an
  `/etc/hosts` name pointing at `127.0.0.1`, cannot be reached. Address such
  a service by the address it actually listens on.

## Verification

The breakout tests are not checked in. Each finding in the git history was
proven exploitable before the fix and unreachable after. The design was
validated on three hosts with different shapes: different egress interfaces
(`br0`, `wlp1s0`, `wlan0`), a symlinked and a real-file `/etc/resolv.conf`,
uid 1000 and uid 1001, and hosts with and without tunnels.
