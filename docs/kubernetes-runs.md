# Running a sandboxed agent in Kubernetes

**Status: design. Nothing here is built.**

This follows the pattern `docs/sandbox-backend-container.md` set — the design is
written down and agreed before implementation, because the parts that have to be
right are cheaper to get right on paper.

The goal is a self-hosted cloud agent: submit a task from anywhere with cluster
access, and a few minutes later fetch a branch. Anyone who can reach the cluster
gets an agent, which is what makes it usable from CI rather than only from a
workstation.

```
fork-sandbox.sh --k8s --harness claude --model opus <project> <handoff>
```

## This is a run mode, not a backend

The natural first guess is a third backend beside `bwrap` and `container`.
It does not work, for two reasons that are both about *locality*.

**`--bind-ro PATH` assumes the thing running the command can see `PATH`.** On
one machine that is free. Across a network it is not, and the layers above lean
on it hard: the clone itself, the git alternates object store that a
`git clone --shared` reads all of its history through, `node_modules`, the model
cache, the browser cache. Several are gigabytes. None of them become ConfigMaps.

**The work returns by `git fetch` from a bind-mounted clone**, which needs the
submitting machine and the sandbox to share a filesystem.

So a backend would only work where the client and the cluster share storage.
More importantly, it would not deliver the thing worth having: with a backend,
every run still needs one particular machine awake, holding the clone and
performing the fetch. That is not a fleet.

The unit that should move to the cluster is the **run** — clone, provision,
agent, return a branch, die. In a cluster **the pod already is the sandbox**:
the pod spec supplies the namespaces, the filesystem policy and the egress
control that a backend supplies locally. Wrapping a backend inside a Job means
isolating twice and inheriting host-path assumptions in exchange for nothing.

The backend contract in [sandbox-backend.md](sandbox-backend.md) therefore stays
honestly local. This is a different verb at a different layer.

## The shape

The client submits a Job and polls. The pod clones from a git remote,
provisions itself, runs the agent, and commits. The client fetches the branch
and the pod exits.

| | Local run | Cluster run |
|---|---|---|
| Isolation | bwrap, or a container | the pod spec |
| Toolchain | host `/usr`, or the image | the image |
| Agent's credentials | the model token only | the model token only, from a Secret |
| Git write credential | **none** — it commits, it cannot push | **none** — the same |
| Work leaves via | `git fetch` from the clone | `git fetch` from the pod's clone |
| Services reach it via | unix-socket bridges | Services, narrowed by NetworkPolicy |
| Egress pin | pasta, or blackhole routes | NetworkPolicy, plus a self-test |
| Exit status | the process's | the terminated container's `exitCode` |

The client is whatever submits: a workstation, or a CI job holding a kubeconfig.
Nothing in the design requires a dedicated orchestrator pod, and adding one
would put a long-lived credential somewhere it is not needed.

## Credentials: the property that must not invert

Every layer of this system states the same property: **the sandbox holds no git
write credential and cannot push.** Work leaves as files, through the one
writable path that outlives the run. That is what makes it safe to hand an
unattended agent a whole repository.

An earlier sketch of this design had the pod return work by **pushing to a
remote**, and described that as simpler than the local flow. It is not simpler;
it is a different trust model. Pushing puts a write credential inside the blast
radius — inside the one process in the system deliberately built to hold none.
That would be the largest single regression available to this project, and it is
rejected.

What replaces it is the arrangement the local flow already uses, unchanged: the
agent commits to a clone it owns and never pushes anywhere, and something
outside the blast radius reads the result out.

The agent pod does hold exactly one secret, the model API token, mounted from a
Secret. That is the same exposure a local run has and is accepted for the same
reason: the token is what the agent is *for*, and it is short-lived. As locally,
only a stripped, short-lived credential should ever be mounted — never a refresh
token, which is long-lived and single-use.

## Getting the work back without a credential

git can fetch over an arbitrary transport, which removes the need for a server:

```bash
git fetch "ext::kubectl exec -i <pod> -- git-upload-pack /work/clone" <branch>
```

`ext::` hands git's pack protocol to any command's stdio. There is no git
daemon, no Service, no Ingress, no port-forward, and **no new credential** — it
reuses the cluster RBAC the operator already has, and `git` is already in the
image. A CI job with a kubeconfig can do this as easily as a workstation.

This needs the pod to still exist when the client fetches, which is the one
constraint it imposes:

- **v1: the pod idles after the agent exits**, holding its clone, until it is
  fetched or a deadline expires. No PVC, no second workload. The cost is a pod
  occupying scheduling capacity for the TTL, and the work is lost if the node
  fails.
- **Upgrade path: a PVC plus an on-demand results pod.** The Job completes
  cleanly, the work survives the node, and a short-lived pod mounts the volume
  when someone fetches. More moving parts; worth it once runs are routine.

Either way the TTL is a real setting with a real trade-off, and it should be
explicit rather than defaulted silently.

## The agent pod

The image is the one the container backend already uses,
[images/sandbox/Dockerfile](../images/sandbox/Dockerfile). That work transfers
directly: a container backend and a Job have the same requirement, that the
sandbox's userland comes from the image rather than from a host.

The pod spec is the isolation, so it carries the guarantees the backend contract
lists: `runAsNonRoot`, `readOnlyRootFilesystem` with explicit writable volumes,
all capabilities dropped, `allowPrivilegeEscalation: false`, a `seccompProfile`,
and **`automountServiceAccountToken: false`** — which does as much work for
containment here as any egress rule. A `RuntimeClass` of gVisor or Kata raises
isolation strength past anything available locally, and is the one place this
path can be *stronger* than a workstation rather than merely equal.

**The prompt needs a carrier.** Locally the handoff arrives on stdin, because
argv is capped at `MAX_ARG_STRLEN` and a handoff outgrew it once. A Job does not
take stdin the way a local process does, so the handoff has to arrive as a
mounted file — and it can be large, which rules out some of the obvious choices.

**The pod provisions itself.** It clones from a remote rather than receiving a
clone, and runs the project's own install step. This is where the local flow's
`node_modules` copy and `provision-ro` binds have no equivalent, and it is a
genuine behaviour difference: a cluster run starts cold.

## Egress

`--net pinned` maps onto a NetworkPolicy, and as a *mechanism* that is better
than what the container backend had to do: declarative, enforced by the CNI, no
sentinel gate, no helper container, no generated route program, and no race.

**But enforcement varies by CNI, and that is a sandbox-that-lies risk.** Some
CNIs silently ignore NetworkPolicy rather than rejecting it; others enforce it;
a policy-only firewall alongside a non-enforcing CNI also enforces it. A policy
that is not enforced looks exactly like one that is, right up until it matters.

**So the one commitment worth making now: the pod self-tests its own pin before
the agent starts.** It attempts a connection to an address the policy denies,
and refuses to run if the connection succeeds. This is the direct analogue of
the container backend's sentinel-route gate, and it is the lesson that backend
paid three review rounds to learn — a pin you asserted and a pin you verified
look identical until they don't. With the self-test in place, a cluster where
enforcement is silently absent **fails closed** instead of running an agent that
believes it is contained. It also makes this path testable in CI in a way
neither local backend ever was, because the test is a pod that must fail.

Two further problems that enforcement alone does not solve:

- **The policy contents.** The denied set is larger in a cluster than on a
  workstation: the API server, node addresses, other namespaces, cluster
  services, and the link-local metadata address. Traffic to a node address, and
  traffic that has been SNAT'd, are the classic soft spots across
  implementations. Test them; do not assume them.
- **The threat model has moved.** Locally the pin exists because a VPN
  authenticates the *device*, not the process, so a sandbox would inherit the
  workstation's tunnel membership. In a cluster the pod instead inherits the
  *cluster's* network position. The policy has to be written against the new
  risk rather than translated from the old one.

## What transfers from the container backend

Not nothing — this is the second port, and the first one paid for several
lessons:

- The backend contract survived a second implementation without bending, which
  is what made it worth extracting.
- An image-based sandbox must supply its own toolchain. A Job needs this exactly
  as a container does, and the image already exists.
- passwd and group synthesis, so an unmapped uid resolves.
- **Exit-code discipline.** Take the authoritative status from the runtime's own
  record. The container backend learned this the hard way: an inspect field read
  0 for a container that was still running, so any path where attach returned
  early would have reported success for a run that never finished. The analogue
  is the pod's terminated container `exitCode`, and *not* a phase field.

## Open questions

These are genuinely unresolved and should be settled before implementation:

1. **Credentials for unattended runs.** The local flow works because a client
   mints a stripped, short-lived token at submit time and a run outlives it by
   minutes. A CI trigger has no interactive login, so it needs a longer-lived
   key — a different credential class with a different blast radius, and
   possibly a different harness.
2. **What runs the agent inside the pod.** Either a small dedicated entrypoint,
   or `fork-sandbox.sh` in a mode whose backend is a passthrough, since the pod
   is already the isolation. A passthrough backend is precisely the shape that
   becomes a sandbox that lies if it is ever reachable outside a pod, so if it
   exists it must refuse to start unless it can prove where it is.
3. **Repositories with no reachable remote.** The local flow runs against a
   purely local repo with no remote at all. This one cannot. That is a real
   capability loss and should be stated rather than discovered.
4. **Concurrency and quota.** A fleet needs a bound on how many runs a person or
   a pipeline can have in flight, and a namespace `ResourceQuota` is only part
   of the answer.

## Deliberately not done

- **No double isolation.** The pod could run the container backend inside
  itself, and for v1 it should not: once the pod spec is right, isolating twice
  buys little and costs the host-path assumptions this design exists to shed.
  Revisit only with a specific threat in mind.
- **No push credential**, for the reasons above.
- **No dedicated orchestrator pod.** The client is whatever submits.
