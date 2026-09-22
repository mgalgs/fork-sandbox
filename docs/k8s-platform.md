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
        --agent-label KEY=VAL --proxy-label KEY=VAL --proxy-port PORT \
        [--allow-namespace NS[:PORT]]...
fork-sandbox-k8s-platform-<name> render-grant --namespace NS \
        --name NAME --agent-label KEY=VAL [--label KEY=VAL]... \
        --allow-namespace NS[:PORT] [--allow-namespace NS[:PORT]]...
```

Three verbs. A platform that needs a fourth is a sign the contract is
missing something, not a place to bolt one on quietly — raise it instead of
growing this list ad hoc.

`--allow-namespace` was added to `render-policy` after the first
implementation shipped. A plugin predating it hits its own unknown-option arm
and refuses the moment an operator sets `K8S_AGENT_ALLOW_NS` — fail-closed and
correct, but the error names a flag nobody typed, so a plugin you did not write
is worth checking before setting that key. Plugins must accept the option; the
caller guarantees every value it passes already matches the namespace label
shape and a valid port.

| Verb | Meaning |
|---|---|
| `--capabilities` | Print `key=value` lines describing this platform. Exits 0. Renders nothing. |
| `render-policy` | Print, to stdout, the NetworkPolicy-shaped YAML that seals the agent pod's egress on this platform's dialect. Exits 0. |
| `render-grant` | Print, to stdout, ONE additional NetworkPolicy that widens a single run's egress to one or more namespaces, without touching the shared seal. Exits 0. Only offered by a platform that declares the `grant` capability key. |

`render-policy`'s options:

| Option | Meaning |
|---|---|
| `--namespace NS` | The namespace the agent pod and the proxy run in. |
| `--agent-label KEY=VAL` | The label the rendered policy's `podSelector` must match — the agent pod carries it. |
| `--proxy-label KEY=VAL` | The label of the proxy pod the agent is allowed to reach. |
| `--proxy-port PORT` | The port on the proxy the agent is allowed to reach. |
| `--allow-namespace NS[:PORT]` | Repeatable, and the only optional one. An extra namespace the agent may reach. With a port: that **TCP** port only. Without one: every port *and every protocol*. Renders a `namespaceSelector` on `kubernetes.io/metadata.name`. |

The first four are required; `--allow-namespace` is optional and repeatable.
With none of it, `render-policy` prints one thing: a policy that seals the
agent pod to exactly two egress destinations — DNS in `kube-system`, and the
proxy on the given label and port — plus whatever this platform's dialect can
add to that (an ICMP denial, if the dialect supports one). It has no opinion
about the proxy's own policy, which is ordinary and portable and lives as a
static file in `manifests/k8s/` instead.

### `render-grant`, the per-run widening verb

Where `--allow-namespace` on `render-policy` widens the *shared* seal for
every agent pod in the namespace, `render-grant` prints a *separate* object
scoped to one run's pods only, so a launcher can widen a single run's egress
without touching any other run sharing the namespace.

| Option | Meaning |
|---|---|
| `--namespace NS` | The namespace the run's agent pod lives in. |
| `--name NAME` | The rendered object's `metadata.name`. Caller-chosen, and NEVER `render-policy`'s fixed name — reusing that name would replace the shared seal instead of adding to it (see below). |
| `--agent-label KEY=VAL` | The label the rendered policy's `podSelector` must match — scoped to this one run's pod(s), not every agent pod in the namespace. |
| `--label KEY=VAL` | Repeatable, optional. Extra `metadata.labels` on the rendered object, so a caller's by-label delete (`kubectl delete networkpolicy -l ...`) reaches it too. |
| `--allow-namespace NS[:PORT]` | Repeatable. At least one required. Identical syntax and rendering to `render-policy`'s option of the same name. |

`render-grant`'s output has `policyTypes: [Egress]` only — no `Ingress`, and
no `ingress:` key at all — because it is purely additive. NetworkPolicies
are additive by construction: the shared seal (`render-policy`'s output,
applied separately) already supplies the deny baseline and the DNS/proxy
rules, so `render-grant` renders nothing but the requested
`--allow-namespace` rules, using the exact same rule-rendering as
`render-policy`'s own `--allow-namespace` tail (the two are implemented by
one shared function so they cannot drift).

**Never implement a per-run grant by calling `render-policy` with a per-run
selector.** `render-policy` hardcodes `metadata.name:
fork-sandbox-agent-egress`. Applying it with a narrower `podSelector` per run
would *replace* the shared seal each time — the seal would then match only
that one run's pod, leaving every other agent pod in the namespace with no
egress policy at all, which Kubernetes reads as unrestricted egress. This is
why `render-grant` is its own verb with its own object, not a `render-policy`
variant.

### `--allow-namespace`, the one thing that widens the seal

Every other extension in this contract *narrows*: the dialect hook exists so a
richer policy language can deny ICMP. This one is the exception, and it is
deliberately shaped so the widening cannot happen quietly.

It is a **caller** decision, never a platform one. `fork-sandbox-k8s.sh`
passes it from `K8S_AGENT_ALLOW_NS` in the machine's `k8s.env`, announces
every entry it forwards on stderr, and shows the rendered rules under
`--dry-run`. A plugin must not read its own config to decide this. The reason
is not tidiness:

- **The egress gate would not notice.** It checks a fixed set of conditions
  — `K8S_DENIED_PROBE` unreachable, the proxy reachable, and ICMP blocked on a
  platform declaring `icmp=filtered` — and not one of them touches a widened
  namespace. It therefore passes whether the seal is two destinations or
  twelve. A gate that passes while the seal silently grew is the failure class
  `sandbox-backend.md` calls out — a pin asserted but never verified.
- **This document would become false.** It exists so it is possible to say
  which guarantees a given cluster actually holds. A plugin that widened
  privately would make its own `--capabilities` answer a half-truth, with
  nothing anywhere to contradict it.

**`--capabilities` does not report this, and that is a real limit rather than
an oversight.** The keys describe the platform's *dialect* — what policy
language it emits, whether that language can deny ICMP — and widening is not a
dialect property: it is a caller's choice, expressed per invocation, so two
runs against the same plugin can seal differently. A key would therefore have
to answer "could be widened", which is true of every platform and tells a
reader nothing about the run in front of them.

The consequence is worth stating plainly: **nothing can ask the plugin, after
the fact, how wide a given policy was rendered.** `--capabilities` answers as
though the seal were the two default destinations regardless. A consumer that
needs the real answer has to read the applied `NetworkPolicy`, or the
`K8S_AGENT_ALLOW_NS` the launcher was given — both of which are available, and
neither of which is this interface. That is an accepted trade, made because
the alternative (a key that is either always-true or silently per-run) would
be worse than the gap it filled.

Setting it has one consequence the operator owns: `K8S_DENIED_PROBE` must name
a destination **outside** every namespace listed, or the gate proves nothing.
`fork-sandbox-k8s.sh` says so on every install that uses the key.

Each entry renders a `namespaceSelector` on the standard
`kubernetes.io/metadata.name` label, never an `ipBlock`. kube-proxy DNATs a
`ClusterIP` to a pod IP *before* egress policy is evaluated on most CNIs, so an
`ipBlock` naming a Service's `ClusterIP` validates fine and then never matches;
a `namespaceSelector` matches the destination pod's own namespace label, which
survives the DNAT. This is the same construct, and the same reasoning, that
`K8S_PROXY_ALLOW_NS` applies to the proxy's policy — a different pod answering
a different question.

**The two halves of the option differ by protocol, which is easy to miss.** A
named port renders `protocol: TCP` and permits nothing else; an omitted port
renders no `ports:` key at all, which NetworkPolicy reads as every port *and
every protocol*. So the narrower-looking form is also the one that silently
drops UDP — `K8S_AGENT_ALLOW_NS=telemetry:8125` for a StatsD sidecar, or `:514`
for syslog, announces an opening at install and then discards every datagram.
Omit the port for a UDP or mixed-protocol service.

## Asking a platform about itself

```
fork-sandbox-k8s-platform-<name> --capabilities
```

Prints `key=value` lines to stdout and exits 0, rendering nothing. Five keys
are defined for v1:

| Key | Values | Meaning |
|---|---|---|
| `policy` | `networkpolicy` \| `cilium` \| `none` | The dialect `render-policy` emits. |
| `icmp` | `filtered` \| `unfiltered` | Whether this dialect can restrict ICMP at all. |
| `dns` | `filtered` \| `recursive` | Whether DNS egress is content-filtered. |
| `runtimeclass` | a name, or `none` | A stronger isolation class this platform offers, if any. |
| `grant` | `render-grant`, or absent | Whether this platform supports `render-grant`, the per-run widening verb. A missing key means unsupported — a caller wanting to grant a run extra namespaces must refuse before creating anything, naming the platform and the missing capability, rather than attempt a verb the platform never promised. |

Unknown keys are ignored, so a newer platform may declare more than a given
caller understands — the same forward-compatibility rule
`sandbox-backend.md` uses for its own `--capabilities`. A missing key takes
the conservative value: `unfiltered` for `icmp`, `recursive` for `dns`, `none`
for `runtimeclass`, unsupported for `grant`. A platform that does not
implement `--capabilities` at all — there should be none, since this
contract requires it from the start — would be read the same way: entirely
conservative.

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
grant=render-grant
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
