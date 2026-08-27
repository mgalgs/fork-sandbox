# The sandbox backend interface

Everything in this repository above the sandbox is ordinary bash: clone a repo,
provision it, run an agent in it, fetch a branch back, write down what happened.
Only one layer is Linux-specific — the part that actually isolates the agent —
and this document defines the contract that layer implements, so another
implementation can be dropped in without the layers above knowing.

**Status: `sandbox-backend-bwrap` and `sandbox-backend-container` implement
this contract, and `claude-sandboxed` and `agent-sandboxed` are their two
callers.** The Kubernetes backend described below is not built. The contract was written
down before the extraction because it is the part that has to be right; a
backend that gets it wrong is not a weaker sandbox, it is a sandbox that lies.

## Why an interface at all

Three reasons, in the order they will bite:

1. **macOS.** bubblewrap, pasta and network namespaces have no macOS
   equivalent, and `sandbox-exec` cannot express pinned egress or a sealed
   bridge. A Linux container is the honest port, and it is a *different
   backend*, not a patch to this one.
2. **Kubernetes.** A cloud fleet of agents wants the same run shape — clone,
   work, push a branch, die — with a Job as the unit. The isolation primitive
   changes completely; nothing else does.
3. **Honesty.** Writing the guarantees down as a contract makes it possible to
   say which of them a given backend actually holds. Before this existed it was
   implicit in 1,000 lines of flag handling inside `claude-sandboxed`.

## The command line

```
sandbox-backend-<name> [options] -- COMMAND [ARG...]
```

| Option | Meaning |
|---|---|
| `--workdir DIR` | The one writable project directory. Becomes the command's cwd. Required. |
| `--bind-ro PATH` | Mount PATH read-only at the same path inside. Repeatable. |
| `--bind-rw PATH` | Mount PATH read-write at the same path inside. Repeatable. |
| `--bind-ro-at SRC DEST` | Mount SRC read-only at a *different* path inside. Repeatable. |
| `--bind-rw-at SRC DEST` | Mount SRC read-write at a *different* path inside. Repeatable. Carries `--bind-rw`'s risk, so SRC is refused on the same list as `--workdir`. A client that synthesizes state on the host cannot work without it: `claude-sandboxed` builds a throwaway `~/.claude` in its own state dir and has to mount it at `$HOME/.claude`. |
| `--net pinned\|sealed` | The network mode. Required — there is no default, because the default would be the one nobody chose. |
| `--bridge SOCKET=PORT` | Sealed mode only: make host unix socket SOCKET reachable at `127.0.0.1:PORT` inside. Repeatable. PORT must be ≥1024. |
| `--setenv K=V` | Set one variable inside. Repeatable. The environment is otherwise empty. |
| `--prepend-path DIR` | Prepend DIR to the sandbox `PATH`. Repeatable. |
| `--hostname NAME` | Set the sandbox hostname, so a prompt can show where it is. |
| `--` | Ends option parsing. Everything after is the command, passed verbatim. |

Backends may add their own options — a container backend needs an image, a
Kubernetes backend needs a namespace and a service account. Those are declared
by the backend and must not be required for the contract above to work.

## The guarantees

A backend that cannot hold all six is not a backend; it is a different tool that
should say so in its own name.

1. **Filesystem.** The only writable paths are `--workdir`, each `--bind-rw`
   and `--bind-rw-at`, and ephemeral scratch (`/tmp`) that does not survive the
   run. Everything else is read-only or absent. Nothing the command writes
   reaches the host except through those paths.
2. **The home directory is not inherited.** `$HOME` inside is a fresh, empty,
   ephemeral directory. Host dotfiles — `~/.ssh`, cloud credentials, shell
   history, agent config — are absent unless a `--bind-*` names them
   explicitly. This is the one that matters most in practice.
3. **Pinned egress** reaches the public internet through the host's default
   route only. It does **not** reach host loopback, VPN or tunnel interfaces, or
   any address that only exists on them. It *does* reach the host's LAN — see
   the limits below.
4. **Sealed egress** reaches nothing. No internet, no LAN, no DNS. The only
   crossings are the `--bridge` sockets, and each carries exactly one TCP
   endpoint the caller named.
5. **The environment starts empty.** Only what `--setenv` and `--prepend-path`
   put there, plus the minimum a shell needs to function. Host variables — and
   therefore host secrets in variables — do not leak in.
6. **The exit code is the command's.** Not the backend's, not a wrapper's. The
   layers above use it to decide whether a run failed, so a backend that
   substitutes its own breaks failure detection silently.

## The limits every backend must state

A guarantee list invites the reader to assume everything else is covered. It is
not. A backend documents, in its own header:

- **Isolation strength.** Shared-kernel namespaces (bwrap, plain containers)
  mean a kernel bug is an escape. A syscall-virtualizing runtime (gVisor) or a
  microVM (Kata, Firecracker) is stronger and should say so.
- **Syscall filtering.** Whether a seccomp profile is applied. The bwrap backend
  applies none.
- **LAN reachability in pinned mode.** With bwrap+pasta the sandbox's traffic is
  re-originated from the host's own address, so LAN services that authenticate
  by network position cannot tell the sandbox from the host. A backend on a
  different network model must say what its equivalent is.
- **Resource limits.** Whether CPU, memory and disk are bounded. The bwrap
  backend bounds none of them.
- **What a SIGKILL leaves behind.** Teardown that runs from a trap does not run
  when the trap is skipped.

## Backends

### `bwrap` — Linux, today

`sandbox-backend-bwrap`. bubblewrap for filesystem and process isolation, pasta
for pinned egress, a socat pair per bridge in sealed mode — the backend runs the
sandbox half of each bridge, the caller runs the host half and owns tearing it
down. Strength: shared-kernel namespaces, no seccomp. Its own header states the
limits above in full.

It declares one backend-specific option, which this contract allows and
deliberately does not adopt: `--net unpinned`, full egress including tunnels.
The contract offers `pinned` and `sealed` only, because a mode whose guarantee
is "none" does not belong in a guarantee list. It exists for the one case the
pin breaks — a VM on a libvirt or docker bridge, which has to be addressed by
its bridge address — and it prints a warning naming what it gave up.

### `container` — the macOS answer

`sandbox-backend-container` runs the command in a Linux container. Mounts
implement the filesystem allowlist, a network-less container implements sealed
egress, and destination blackhole routes implement pinned egress. On macOS the
container's Linux VM provides the kernel, so the port stops being a port and
becomes a second backend. It declares one backend-specific option, `--image`.
Its mechanism, threat model, and limits are described in
[sandbox-backend-container.md](sandbox-backend-container.md).

### `k8s` — planned

One Job per run. `--net` maps onto a NetworkPolicy, `--bridge` onto an egress
rule to a Service. `runAsNonRoot`, `readOnlyRootFilesystem`, dropped
capabilities, `automountServiceAccountToken: false` and a `seccompProfile` are
the pod-level equivalents of the guarantees above, and a `RuntimeClass` of
gVisor or Kata raises the isolation strength past anything available locally.
The branch comes back by being pushed to a remote rather than fetched from a run
directory, which is simpler than the local flow rather than harder.

## Selecting one

`FORK_SANDBOX_BACKEND` names the backend; the default is `bwrap`. The layers
above resolve `sandbox-backend-$FORK_SANDBOX_BACKEND` on `PATH` first — which is
how a backend that does not live in this repository gets used — and then beside
the calling script, so a checkout works before `install.sh` has run.
