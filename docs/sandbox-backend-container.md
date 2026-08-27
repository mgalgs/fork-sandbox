# Container sandbox backend design

`sandbox-backend-container` implements the sandbox backend contract with a
Linux container. It is also the macOS implementation: there the runtime's Linux
VM supplies the namespaces and kernel.

## Runtime and image

The backend uses `docker`, overridden by `FORK_SANDBOX_CONTAINER_CLI` for a
Docker-compatible CLI, and requires an image from `--image NAME` or
`FORK_SANDBOX_CONTAINER_IMAGE`. Only Docker is tested; Podman rootless UID
mapping is not. The image supplies `bash`, and supplies iproute2's `ip` for
pinned mode and `socat` for bridges. A startup probe checks these requirements.

This differs fundamentally from bwrap. bwrap mounts the host's `/usr`, so its
toolchain is the host's. A container gets its toolchain from its image. A
read-only host toolchain bind is not reliable either way: on macOS a Mach-O
binary cannot run in Linux at all, and on Linux a host binary bound into an
image finds neither its interpreter nor its shared libraries.

That is a property of the backend, not of the host, so the backend declares it
rather than leaving callers to infer it:

```
sandbox-backend-container --capabilities
toolchain=image
```

`sandbox-backend-bwrap` answers `toolchain=host`. The callers use the answer to
decide whether to bind the agent CLI, node and a virtualenv interpreter from
the host, or to expect the image to carry them. See
[sandbox-backend.md](sandbox-backend.md).

The image is therefore where the run's userland lives.
[images/sandbox/Dockerfile](../images/sandbox/Dockerfile) is the one this
repository ships — Debian, node, git, jq, iproute2, socat, and the three agent
CLIs — built by `scripts/build-sandbox-image.sh`. It is a base: a repo whose
suites need a compiler, a database client or a browser should build its own
image `FROM` it. Any image meeting the requirements above works; nothing in
the backend knows about that particular one.

It is also a supply-chain surface worth naming as one. It holds the agent CLIs
and a run hands them the user's credential, which is why there is no published
copy to pull: you build the thing you trust.

The contract maps directly to bind mounts, runtime environment and hostname
options. All mounts use `--mount type=bind`, never `-v`, because `-v` creates a
missing source as a root-owned host directory. `$HOME` and `/tmp` are tmpfs,
mounted `rw,nosuid,nodev,exec` — Docker's `--tmpfs` default set includes
`noexec`, which would silently diverge from bwrap's equivalent scratch space,
so `exec` is requested explicitly. Neither tmpfs has a size cap.
The container runs as the host UID/GID, with all capabilities dropped,
no-new-privileges, Docker's default seccomp profile, and an init process.
A synthesized passwd/group entry makes the otherwise unknown host UID usable.
The image entrypoint is never used.

The writable container overlay is destroyed at cleanup. It is intentionally
not read-only: the filesystem guarantee concerns writes reaching the host, and
only explicitly writable bind mounts do so.

## Why a bridge network is not a pin

bwrap asks pasta to bind outbound sockets to the host's default-route
interface. Destinations routed through another interface then fail at routing.
A container sees only its own interface; the host routes its NATed traffic per
destination. A plain bridge therefore reaches VPN routes, other host bridges,
and host interface addresses. Docker has no equivalent source-interface pin.

The container backend instead expresses the policy as destination
reachability inside the container network namespace. This is a different
mechanism with different edges; treating a normal bridge as equivalent would
silently break guarantee 3.

## Destination blackhole pin

At container start the backend computes and installs, in this order:

1. Blackholes for `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
   `100.64.0.0/10`, and `198.18.0.0/15`.
2. An IPv6 default blackhole, because the runtime network is IPv4-only and an
   unpinned address family must not remain.
3. Blackholes for every host prefix routed through an interface other than the
   default-route interface.
4. `/32` blackholes for every host address on the default-route interface.
5. A `/32` blackhole for the container gateway. It remains usable as a next
   hop.
6. Normal routes through that gateway for every directly connected prefix on
   the host default-route interface, punching the LAN through broader private
   range denials while the `/32` host and gateway denials still win.
7. Last: a blackhole for `169.254.0.0/16`.

Longest-prefix matching makes rule order irrelevant to *which* destinations
end up blocked. The container's own subnet route is normally more specific
than the fixed private-range denial and therefore remains usable. If a host
LAN overlaps the container subnet, that part of the LAN is unreachable;
failing closed is preferable.

Order is not irrelevant to the *gate* described below, though: it polls for
one specific route and treats that route's appearance as proof the whole
program above ran. `169.254.0.0/16` is therefore installed last, deliberately,
rather than grouped with the other five fixed ranges in step 1 — a poll that
lands after step 1 but before steps 3-6 have run must not see a pin it can
trust.

A short-lived helper container shares the target's network namespace and runs
as root with `NET_ADMIN` to install the routes. The target itself has
`--cap-drop=ALL` from creation and cannot undo them.

The namespace exists only after the target starts, and a container created on
`none` cannot later join another network. The target therefore starts attached,
but its generated bootstrap gates the real command: it polls for the sentinel
blackhole `169.254.0.0/16`, then executes the command only after observing it.
A bounded timeout exits nonzero without running the command. Thus the sandbox
verifies its own pin and fails closed; only the local poll runs during setup.
Failure to read routes, identify a non-tunnel default interface, or run the
helper aborts the run.

Properties measured on Docker 29.7 with a rootful daemon and cgroups v2:

| Destination | Plain bridge | Pinned | Required |
|---|---|---|---|
| Public internet | reachable | reachable | reachable |
| Another LAN host | reachable | reachable | reachable |
| Host's LAN address | reachable | unreachable | unreachable |
| Host VPN-interface address | reachable | unreachable | unreachable |
| VPN-only subnet | reachable | unreachable | unreachable |
| Container gateway | reachable | unreachable | unreachable |
| Other container or VM bridge | reachable | unreachable | unreachable |
| Host loopback | container-local | container-local | unreachable |

`--net unpinned` is an explicit extension: it uses a plain per-run bridge and
warns that tunnels, VPNs and bridge networks are reachable.

## Sealed networking and bridges

Sealed mode uses `--network none`, leaving only container loopback and no DNS.
For each `--bridge SOCKET=PORT`, the socket's directory is mounted read-only
and a `socat` relay listens at `127.0.0.1:PORT`. Directories are deduplicated;
mounting the directory avoids pinning a replaced socket inode and lets a
watchdog observe disappearance. The single generated bootstrap handles the
pinned gate, bridge readiness, socket-vanish watchdogs, then `exec`s the real
command without consuming stdin.

## Exit status and cleanup

The backend uses create, attached start, and `docker wait` rather than
`docker run`. Runtime statuses 125–127 otherwise collide with real command
statuses. `docker inspect .State.StartedAt` first confirms the container ever
started, since a container that never did has no command exit code and is
reported as a backend failure; `docker wait` then blocks until the container
stops and provides the authoritative command exit code. An earlier version
used `docker inspect .State.ExitCode` for that second step, but inspect
reports 0 for a container that is still running, so any path where attach
returned early or failed silently would have reported success for a run that
never finished. `--init` is mandatory so signals reach the command rather
than being ignored by a command running as PID 1.

An EXIT trap removes the target container, its per-run network, and its state
directory, in that order. A per-work-directory `flock` prevents overlapping
runs after a caller times out.

## Limits

- **Isolation strength.** Linux containers share the host kernel, so a kernel
  bug is an escape, as with bwrap. On macOS an escape reaches the runtime's
  Linux VM rather than the Mac, which is stronger with respect to the user's
  machine. A rootful Docker daemon is itself root-equivalent: anyone allowed
  to invoke this backend already has that power. Writable-path refusals guard
  the operator against mistakes, not the daemon boundary.
- **Syscall filtering.** Docker's default seccomp profile applies, stronger
  than bwrap's lack of filtering. It blocks nested unprivileged user
  namespaces: Chromium/Playwright needs `--no-sandbox`, and nested bwrap is not
  possible. A runtime configured with `--security-opt seccomp=unconfined`
  restores those syscalls but gives up this protection; the backend does not
  request that option.
- **LAN reachability in pinned mode.** LAN traffic is NATed from the host's
  address, so services trusting network position cannot distinguish it from
  the host. This is a destination denylist computed at start, not bwrap's
  source-interface pin. A later tunnel is covered only when it uses a fixed
  denied range; globally routable tunnel prefixes are covered only by the
  startup routing snapshot. DNS uses Docker's embedded resolver in the daemon
  namespace, so VPN-only names may resolve even though their addresses remain
  unreachable: names leak, reachability does not.
- **Resource limits.** None are set. Docker can express memory, CPU and PID
  limits with `--memory`, `--cpus`, and `--pids-limit`; this backend does not.
- **What SIGKILL leaves behind.** The stopped labeled container, labeled
  per-run network, and state directory remain; the kernel releases the lock.
  Find runtime strays with
  `docker ps -a --filter label=fork-sandbox-run` and
  `docker network ls --filter label=fork-sandbox-run`.
- **macOS bridges.** Unix-socket bridges are verified only on Linux and
  probably do not survive Docker Desktop or Colima filesystem sharing. Treat a
  sealed run with a bridge as Linux-only until verified on Darwin.

The synthesized `/etc/passwd` and `/etc/group` replace the image's files.
Images whose entrypoint depends on their own users are unsupported; the
backend always overrides the entrypoint.
