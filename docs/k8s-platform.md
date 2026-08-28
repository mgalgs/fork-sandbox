# The Kubernetes platform interface

[kubernetes-runs.md](kubernetes-runs.md) puts a fleet of sandboxed agents on a
Kubernetes cluster. Clusters are not interchangeable: which policy dialect the
CNI enforces, whether ICMP can be restricted at all, whether a stronger
`RuntimeClass` exists, where the cloud metadata address lives — all of that
varies by cluster, and none of it belongs as `if` statements scattered through
a client script. This document is the interface that keeps it out: one small
contract a cluster-specific plugin implements, so `fork-sandbox-k8s.sh` never
has to know which cluster it is talking to.

This follows the pattern [sandbox-backend.md](sandbox-backend.md) set for the
local sandbox, and for the same reason: the contract is written down and
implemented once before a second implementation is attempted, because the
parts that have to be right are cheaper to get right on paper.

**Status: `fork-sandbox-k8s-platform-generic` implements this contract, and
`fork-sandbox-k8s.sh` is its one caller.** v1 ships the contract and that one
implementation. It does not ship a second. See "Why only one platform" below
for why that is deliberate rather than a shortcut.

## The command line

```
fork-sandbox-k8s-platform-<name> --capabilities
fork-sandbox-k8s-platform-<name> render-policy --namespace NS \
        --agent-label KEY=VAL --proxy-label KEY=VAL --proxy-port PORT
```

Two verbs. A platform that needs a third is a sign the contract is missing
something, not a place to bolt one on quietly — raise it instead of growing
this list ad hoc.

| Verb | Meaning |
|---|---|
| `--capabilities` | Print `key=value` lines describing this platform. Exits 0. Renders nothing. |
| `render-policy` | Print, to stdout, the NetworkPolicy-shaped YAML that seals the agent pod's egress on this platform's dialect. Exits 0. |

`render-policy`'s options:

| Option | Meaning |
|---|---|
| `--namespace NS` | The namespace the agent pod and the proxy run in. |
| `--agent-label KEY=VAL` | The label the rendered policy's `podSelector` must match — the agent pod carries it. |
| `--proxy-label KEY=VAL` | The label of the proxy pod the agent is allowed to reach. |
| `--proxy-port PORT` | The port on the proxy the agent is allowed to reach. |

All four are required. `render-policy` prints one thing: a policy that seals
the agent pod to exactly two egress destinations — DNS in `kube-system`, and
the proxy on the given label and port — plus whatever this platform's dialect
can add to that (an ICMP denial, if the dialect supports one). It has no
opinion about the proxy's own policy, which is ordinary and portable and lives
as a static file in `manifests/k8s/` instead.

## Asking a platform about itself

```
fork-sandbox-k8s-platform-<name> --capabilities
```

Prints `key=value` lines to stdout and exits 0, rendering nothing. Four keys
are defined for v1:

| Key | Values | Meaning |
|---|---|---|
| `policy` | `networkpolicy` \| `cilium` \| `none` | The dialect `render-policy` emits. |
| `icmp` | `filtered` \| `unfiltered` | Whether this dialect can restrict ICMP at all. |
| `dns` | `filtered` \| `recursive` | Whether DNS egress is content-filtered. |
| `runtimeclass` | a name, or `none` | A stronger isolation class this platform offers, if any. |

Unknown keys are ignored, so a newer platform may declare more than a given
caller understands — the same forward-compatibility rule
`sandbox-backend.md` uses for its own `--capabilities`. A missing key takes
the conservative value: `unfiltered` for `icmp`, `recursive` for `dns`, `none`
for `runtimeclass`. A platform that does not implement `--capabilities` at
all — there should be none, since this contract requires it from the start —
would be read the same way: entirely conservative.

## Why these keys are not decoration

Two things read them, and both change behavior because of what they say:

- **The egress gate** probes what the platform *claims*. A platform
  declaring `icmp=filtered` gets an ICMP probe added to the initContainer
  gate that must fail before a run is allowed to start; a platform declaring
  `unfiltered` does not get that probe, because a probe that is expected to
  fail proves nothing about the platform and would only teach the gate to
  ignore its own result.
- **The docs** state limits per platform instead of one global disclaimer.
  This is the whole reason the key exists: `sandbox-backend.md` exists so it
  is possible to say which guarantees a given *backend* actually holds, and
  this document exists so it is possible to say which guarantees a given
  *cluster* actually holds. "Some clusters might restrict ICMP" is a useless
  sentence to a reader trying to reason about a specific run. "This cluster
  reports `icmp=unfiltered`, so a pod on it can ping-sweep the LAN" is not.

## `fork-sandbox-k8s-platform-generic`

The one v1 implementation, and the portable baseline every other platform is
measured against. It emits plain Kubernetes `NetworkPolicy` — the dialect
Calico, Cilium, kube-router, Antrea and Weave all honour — and nothing more
cluster-specific than that.

```
policy=networkpolicy
icmp=unfiltered
dns=recursive
runtimeclass=none
```

`icmp=unfiltered` is not a shortcut taken for v1's convenience; it is the
truth about this dialect. Plain `NetworkPolicy` has no field that denies
ICMP — the spec only speaks in terms of TCP, UDP and SCTP ports — so a pod
under a bare `NetworkPolicy` policy can ping-sweep whatever the policy's
egress rules leave reachable, and can tunnel data out in ICMP echo-request
bodies regardless of what the policy says. Declaring `unfiltered` here is how
the system stays honest about a real gap, rather than implying a coverage it
does not have. A future `cilium` platform, using `CiliumNetworkPolicy`'s
richer L4 rule set, is where `icmp=filtered` first becomes true.

It is named `generic`, not after any cluster or CNI, because it is not tied to
one — it *is* the portable baseline, and its name should say so.

## Why only one platform

The backend contract in `sandbox-backend.md` was written down before its
second implementation existed, and it survived that second implementation
without bending — that is what made the extraction worth doing, and it is
this project's own evidence that a contract written first is worth trusting
before a second implementation forces changes into it. This contract follows
the same discipline: it is written and implemented once, against a real
constraint (portable `NetworkPolicy`, checked against a live cluster), before
a second platform — for a richer dialect such as Cilium's, or for a cluster
whose CNI cannot enforce `NetworkPolicy` at all — is attempted. Building a
second implementation now, with nothing yet pushing on the contract from a
different direction, would be guessing at a shape rather than finding one.

## Selecting a platform

`FORK_SANDBOX_K8S_PLATFORM` names the platform; the default is `generic`.
`fork-sandbox-k8s.sh` resolves `fork-sandbox-k8s-platform-$FORK_SANDBOX_K8S_PLATFORM`
on `PATH` first — which is how a platform that does not live in this
repository gets used — and then beside the calling script, so a checkout
works before `install.sh` has run. This is the identical rule
`sandbox-backend.md` uses to resolve `sandbox-backend-$FORK_SANDBOX_BACKEND`,
kept identical on purpose: one resolution rule to remember for the whole
project, not one per plugin family.

An unknown platform name, or a platform binary that cannot be found by either
route, is refused with a clear error before anything is created — the same
fail-fast rule every resolver in this project follows.
