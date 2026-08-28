# Running a sandboxed agent in Kubernetes

**Status: v1 built.** `scripts/fork-sandbox-k8s.sh` is the client,
`manifests/k8s/` is the bundle it applies, and
[docs/k8s-platform.md](k8s-platform.md) is the pluggable layer underneath it,
implemented once by `fork-sandbox-k8s-platform-generic`. Several decisions
below changed after this document was first written and before anything was
built; each says so where it applies, because the reasoning that led to the
change is worth keeping even after the design itself moved on.

This follows the pattern `docs/sandbox-backend-container.md` set — the design
is written down and agreed before implementation, because the parts that have
to be right are cheaper to get right on paper. It is a companion to
[docs/k8s-platform.md](k8s-platform.md), which is the contract for the one
part of this that varies by cluster: this document is the shape of a run,
that one is the interface a specific cluster's CNI dialect implements.

The goal is a self-hosted cloud agent: submit a task from anywhere with cluster
access, and a few minutes later fetch a branch. Anyone who can reach the cluster
gets an agent, which is what makes it usable from CI rather than only from a
workstation.

```
scripts/fork-sandbox-k8s.sh install
scripts/fork-sandbox-k8s.sh submit --branch my-branch --model moonshotai/kimi-k3 \
    ~/src/myproject ~/handoff.md
scripts/fork-sandbox-k8s.sh fetch --branch my-branch ~/src/myproject
```

This is a **new script**, not a mode of `fork-sandbox.sh`. There is no `--k8s`
flag and none is planned yet — wiring the two together is a later round, and
doing it before this path has run for a while would put an untested cluster
dependency in a script that is otherwise pure local sandboxing.

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

The client submits a Job. The pod's initContainer verifies its own egress
policy, then the main container waits for the client to push the repository
in, runs the agent, and commits. The client fetches the branch and the pod
idles out or is removed.

| | Local run | Cluster run |
|---|---|---|
| Isolation | bwrap, or a container | the pod spec |
| Toolchain | host `/usr`, or the image | the image |
| Agent's credentials | the model token, or none | **none** — see "Model access" below |
| Git write credential | **none** — it commits, it cannot push | **none** — the same |
| Repository arrives via | a `git clone --shared` of the origin | `git push` over `kubectl exec`, in — see below |
| Files arrive via | `--bind-ro` of a host path | not yet built for a cluster run — see "Deliberately not done" |
| Work leaves via | `git fetch` from the clone | `git fetch` over `kubectl exec`, from the pod's clone |
| Services reach it via | unix-socket bridges | Services, narrowed by NetworkPolicy |
| Egress pin | pasta, or blackhole routes | NetworkPolicy, sealed to DNS and the proxy, plus an initContainer self-test |
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

**v1 goes further than the original plan here: the agent pod holds no
credential at all, not even the model token.** The design as first written
said the pod "does hold exactly one secret, the model API token." That is no
longer the arrangement — see "Model access: three modes, one built" below.
The pod carries a literal placeholder string where a key would go; the one
thing in the namespace that ever holds the real key is a proxy this repo
ships, and the pod cannot reach anywhere else on the internet to spend it even
if it were compromised.

## Getting the work back without a credential

git can fetch over an arbitrary transport, which removes the need for a server:

```bash
git -c protocol.ext.allow=always fetch \
    "ext::kubectl --context=CTX -n NS exec -i POD -- git-upload-pack /work/clone" \
    refs/heads/BRANCH:refs/heads/BRANCH
```

`ext::` hands git's pack protocol to any command's stdio. There is no git
daemon, no Service, no Ingress, no port-forward, and **no new credential** — it
reuses the cluster RBAC the operator already has, and `git` is already in the
image. A CI job with a kubeconfig can do this as easily as a workstation.

**A named gotcha, confirmed against a real cluster: `ext::` needs an explicit
flag.** Git disables the `ext::` transport by default — hardening added after
the git protocol CVEs — so an unadorned push or fetch against an `ext::` URL
fails with `fatal: transport "ext" not allowed`. The fix is
`-c protocol.ext.allow=always`, scoped to the single command with git's own
`-c`, never set in global config and never exported as `GIT_ALLOW_PROTOCOL`
for the whole session — the relaxation should last exactly one command, since
it is a real hardening measure being deliberately relaxed rather than a false
alarm to silence permanently. `scripts/fork-sandbox-k8s.sh` passes it on both
the push and the fetch path; anyone hand-running a recovery fetch outside the
client will hit the same error and should add the same flag. Separately:
`kubectl exec` must be given `-i` and **never `-t`** — a tty applies
line-discipline translation to what has to stay a binary pack stream, and
would corrupt it.

This needs the pod to still exist when the client fetches, which is the one
constraint it imposes:

- **v1: the pod idles after the agent exits**, holding its clone, until it is
  fetched or a deadline (`K8S_RUN_TTL`) expires. No PVC, no second workload.
  The cost is a pod occupying scheduling capacity for the TTL, and the work is
  lost if the node fails. `fetch` also signals the pod once it has collected
  the branch, so a successful fetch usually ends the idle early rather than
  running out the full TTL.
- **Upgrade path: a PVC plus an on-demand results pod.** The Job completes
  cleanly, the work survives the node, and a short-lived pod mounts the volume
  when someone fetches. More moving parts; worth it once runs are routine.
  Not built in v1.

## Getting the repository in: by push, not by clone

**This is the biggest change from the original design, and it replaces two
things at once.** The design as first written had the pod clone from a git
remote, and separately proposed `--copy-files` — a `kubectl cp` of a host path
into the pod — as the answer to files a run needs that are not in the
repository. v1 does neither. Instead, **the client pushes the repository into
the pod**, over the same `kubectl exec` channel the work later returns on:

```bash
git -c protocol.ext.allow=always push \
    "ext::kubectl --context=CTX -n NS exec -i POD -- git-receive-pack /work/repo.git" \
    HEAD:refs/heads/BRANCH
```

The script's actual push also passes `-c core.hooksPath=/dev/null`, for a
reason unrelated to `protocol.ext.allow`. This push runs on the host, in the
repository the caller names on the command line — and that path is
caller-supplied, so the client has no business trusting whatever `pre-push`
hook happens to be installed there. Disabling hooks for the one invocation
is what keeps a repo the script was merely pointed at from running its own
code inside the client.

The fetch carries the same flag for a different reason. It writes straight
into `refs/heads/BRANCH` in the caller's real repository rather than into a
remote-tracking ref, and `githooks(5)` documents `reference-transaction` as
firing on any git command that updates refs — fetch included — so the same
untrusted repository could run a hook there too. Both invocations scope the
flag with git's own `-c`, exactly like `protocol.ext.allow=always` above:
never set globally, and never active for longer than the one command that
needs it.

The pod's entrypoint runs `git init --bare /work/repo.git` before anything
else, so there is somewhere for this to land; once the push completes, the
client writes a sentinel and the pod clones its own bare repo, checks out the
branch, and proceeds.

Three things follow, and all three are improvements over the original plan:

- **It resolves open question 3 outright.** The original design could not run
  against a repository with no reachable remote, and called that "a real
  capability loss." A pushed repository needs no remote at all — whatever
  `HEAD` in the client's working tree is becomes the pod's starting point,
  exactly as a local sandboxed run's `git clone --shared` does.
- **No git credential exists anywhere in this system.** The original plan's
  pod dialed out to a remote to clone, which means naming a remote and
  usually authenticating to it. A pod that only ever receives a push
  authenticates nothing and reaches nothing to clone from.
- **Egress can stay sealed.** Nothing in the repository-arrival path needs the
  pod to reach a git host, so the only two things it can reach at all are DNS
  and the model proxy — see "Egress is sealed" below.

The pod still never pushes anywhere; the direction is client-to-pod on the way
in, pod-to-nothing on the way out. The property that the sandbox holds no
write credential is unchanged — see "Credentials" above.

## Every run is gated, and the gate is an initContainer

**The design as first written said "a run with no `--copy-files` has no gate
at all."** That is no longer true, and the reason is the change above: since
the repository itself now arrives through the same gated push-and-sentinel
channel `--copy-files` was going to use, every run has exactly one input path
and it is always gated. This is simpler than the original plan, not more
complex — there is no longer a code path for "ungated," so there is nothing
to get wrong by choosing it. The handoff prompt travels the same way, as a
ConfigMap-mounted file the entrypoint reads on pi's stdin, so it needs no gate
of its own: it is present before the container starts, the same way small,
always-present data is for any pod.

The sentinel is the same shape the local flow's other gates use: the client
writes `/work/.inputs-complete` **after** the push finishes, the entrypoint
polls for exactly that file with a deadline, and expiry is a failure — a
client that died mid-push must not become an agent running with a
half-received repository.

`--copy-files` itself — a general mechanism for handing a run something that
is not the repository and not the handoff — is not built in v1. See
"Deliberately not done" below.

## Egress is sealed, except the proxy

**Stronger than the original design's `pinned` mode, and worth stating
precisely.** The agent pod's egress allowlist is exactly two entries:

- DNS to `kube-dns` in `kube-system`, on 53/UDP and 53/TCP.
- the model proxy Service, on 8080/TCP.

No port 443. No LAN. No public internet from the agent pod at all. This is the
cluster analogue of `--harness pi-local`'s sealed sandbox, and it is why the
pod can hold no credential of its own: there is nowhere for a leaked one to be
spent from inside the pod.

**The cost, stated rather than worked around: a run cannot install anything.**
No `npm install`, no `pip install`, no fetching a package from anywhere.
Whatever a run needs has to already be in the image. See "Limits" below.

`docs/k8s-platform.md` is where the *mechanism* for this lives: a platform
plugin renders the NetworkPolicy-shaped YAML for its cluster's dialect, and
declares what it can and cannot enforce. `fork-sandbox-k8s-platform-generic`
is the one shipped implementation, emitting portable Kubernetes
`NetworkPolicy`.

**Enforcement varies by CNI, so the pod self-tests its own pin before the
agent starts** — the same commitment the original design made for `pinned`
mode, carried through here. `scripts/fork-sandbox-k8s-egress-gate.sh` runs as
an **initContainer**, not inline in the main container, because a policy
engine observed on a real cluster took roughly 15 seconds after pod start to
program the pod's firewall chain: a probe pod reached the entire LAN at t+0
and was blocked only from t+15. An initContainer is the only construct that
guarantees nothing untrusted has run before the gate passes, and the gate
polls rather than checking once, for the same reason.

The gate asserts **both directions, simultaneously**:

- a configured denied address (`K8S_DENIED_PROBE`) must be unreachable, and
- the proxy must be reachable.

The second is not decoration. Without it, a completely broken network — every
route dropped, not just the denied one — passes as a working policy. Fail
closed on either.

## Model access: three modes, one built

Model access is **orthogonal to the platform plugin** — every mode below works
the same regardless of which cluster or CNI is underneath. Three modes exist
as an option space; only the first is built.

### 1. proxy — **Status: built.**

The mode described above, and the one `install`/`submit` implement. A
`nginx` `Deployment` this repo ships holds the provider key in a Secret and
injects it into the `Authorization` header of every request it forwards. The
agent pod carries a placeholder string where a key would go and cannot reach
anywhere that would check it.

Concretely, for the OpenRouter upstream v1 ships:

- `K8S_PROXY_UPSTREAM=https://openrouter.ai` — the only upstream host the
  proxy's own `NetworkPolicy` allows on 443.
- Exactly one path is forwarded: `/api/v1/chat/completions`. Everything else
  returns 403 from `nginx`'s own default-deny `location /`.
- The key never appears in the ConfigMap that holds `nginx.conf`. It is
  `include`d from a Secret-mounted file (`upstream-key.conf`, holding
  `set $upstream_key "...";`), so `kubectl get configmap` never shows it, and
  `proxy_set_header Authorization "Bearer $upstream_key"` is the only place
  the value is used.

This is the mode a real provider (OpenRouter, and by extension any API-keyed
service) requires, because the key has to live somewhere.

### 2. direct — **Status: designed, not built.**

A self-hosted OpenAI-compatible endpoint — vLLM, Ollama, and similar all speak
this shape — needs **no key and therefore no proxy at all**. The pod would
talk straight to the endpoint, and there would be no credential anywhere in
the system: not in a Secret, not as a placeholder, nothing to leak. This is
the cluster analogue of `--harness pi-local`, and because it removes an entire
moving part (the proxy Deployment, its Secret, its `NetworkPolicy`) it is the
**cheapest and strongest** option here, not a footnote to the built mode.

Its sketched config surface:

```
K8S_MODEL_ACCESS=proxy|direct
K8S_MODEL_ENDPOINT=http://host:port/v1
```

`direct` would skip the proxy Deployment entirely, and the agent pod's egress
policy would allow `K8S_MODEL_ENDPOINT` in place of the proxy Service. The
endpoint can take two placements:

- **In-cluster** — a `Deployment` plus `Service`, keeping the agent pod sealed
  to the cluster network exactly as the built mode does.
- **On the LAN** — a workstation running `ollama serve`, which requires a
  deliberate, narrow LAN egress exception in the agent pod's policy, since the
  default posture denies the whole LAN.

Ollama serves an OpenAI-compatible API at `/v1`, so pi needs no new provider
shape to speak to it — the same `api: "openai-completions"` registration
`fork-sandbox-k8s-entrypoint.sh` already writes for the proxy would work
unchanged, pointed at a different `baseUrl`.

**A consequence for the egress gate that direct mode makes sharp:**
`K8S_DENIED_PROBE` must name an address that is **not** in the current
allowlist. Under `proxy` mode that is easy — the allowlist is DNS and the
proxy Service, and everything else on the LAN is denied. Under `direct` mode
with a LAN endpoint, some LAN egress is *deliberately* permitted, so the
probe has to be a **different** LAN host than the model endpoint. A gate whose
denied probe is actually allowed passes every time and proves nothing — the
exact failure class this project keeps paying to avoid (see
`docs/sandbox-backend.md`'s discussion of a pin that is asserted but never
verified).

**A constraint learned since, worth recording before `direct` is ever
built:** an on-LAN endpoint (an `ollama serve` on a workstation, say) may sit
on hardware shared with other work, and can simply not be there when a run
tries to dispatch to it. `direct` therefore has to health-check the endpoint
before dispatch and fail with a clear message rather than hang waiting on a
model call that will never return. A connection refusal from
`K8S_MODEL_ENDPOINT` is an expected, ordinary state to design for, not a bug
to chase down each time it happens.

### 3. secret — **Status: designed, not built.**

Mount the provider token directly into the agent pod, from a Secret — the
original design doc's plan, before the proxy was built. Weaker than `proxy`,
because the token is now inside the same blast radius as the agent, but
honest and simple: no proxy to run, no extra hop, no new failure mode.
Reasonable for a cluster where the operator accepts that trade for the
simplicity, but v1 does not build it — the proxy exists specifically to avoid
this trade by default.

## Getting files in — not yet built

`--copy-files`, as a general "hand the pod a host path that is not the
repository" mechanism, is **not built in v1**. The repository itself now
travels the gated push channel described above, and the handoff prompt rides
along as a small ConfigMap-mounted file, which covers the common cases. A
run that needs something larger or more specific — a gathered-context
directory, a provisioned cache — has no answer yet; adding one is a later
round, following the same two-phase gate the repository push already
established, once real usage says what shape it should take.

## The agent pod

The image is the one the container backend already uses,
[images/sandbox/Dockerfile](../images/sandbox/Dockerfile). That work transfers
directly: a container backend and a Job have the same requirement, that the
sandbox's userland comes from the image rather than from a host. Building and
publishing that image for a cluster to pull is the operator's job, not this
repo's — see "Bringing your own image" in the client script's own header
(`scripts/fork-sandbox-k8s.sh`) and in `K8S_IMAGE` below.

The pod spec is the isolation, so it carries the guarantees the backend contract
lists: `runAsNonRoot`, `readOnlyRootFilesystem` with explicit writable volumes,
all capabilities dropped, `allowPrivilegeEscalation: false`, a `seccompProfile`,
and **`automountServiceAccountToken: false`** — which does as much work for
containment here as any egress rule. A `RuntimeClass` of gVisor or Kata raises
isolation strength past anything available locally, and is the one place this
path can be *stronger* than a workstation rather than merely equal — a
platform plugin declares one via the `runtimeclass` capability key in
`docs/k8s-platform.md`; `generic` declares `none`.

**The prompt's carrier**, in v1, is a ConfigMap key (`handoff.md`), mounted
read-only alongside the entrypoint and egress-gate scripts and read on pi's
stdin. This is the "small data needed at start" case the original design
flagged as the natural first use of a gated-input mechanism, applied directly
rather than waiting for a general `--copy-files`.

**The pod does not provision itself the way the original design assumed.**
There is no install step, because there is no egress to install anything
with — see "Limits" below. Whatever a run needs is already in the image.

**Scripts ship as a ConfigMap, not baked into the image.** Both
`scripts/fork-sandbox-k8s-entrypoint.sh` (the main container) and
`scripts/fork-sandbox-k8s-egress-gate.sh` (the initContainer) are mounted in
from a per-run ConfigMap `submit` renders, rather than compiled into
`K8S_IMAGE`. Iterating on either needs no image rebuild and no registry push
— only a re-`submit`.

## Bringing your own image and registry

**A named principle, stated explicitly because it shapes `K8S_IMAGE`:**
fork-sandbox ships a Dockerfile
([images/sandbox/Dockerfile](../images/sandbox/Dockerfile)) and a build script
(`scripts/build-sandbox-image.sh`), and it **never** ships an image, a
registry, or a default image reference. `K8S_IMAGE` in
`~/.config/fork-sandbox/k8s.env` is a fully qualified image ref the operator
supplies. It has no default, and `fork-sandbox-k8s.sh submit` refuses to run
with a clear error when it is unset — the same way it refuses a missing
`K8S_CONTEXT`. There is deliberately no fallback such as `fork-sandbox:latest`:
a pod cannot use a local docker image, so a silent default would only produce
a confusing `ImagePullBackOff` far from the config mistake that caused it.

This is the same "build the thing you trust" stance
`scripts/build-sandbox-image.sh`'s own header states for the local container
backend, carried one step further: a cluster run additionally needs that image
to *reach a registry*, since a pod cannot pull from a local docker daemon. So
where a local run stops at "build it yourself," a cluster run is "build it
yourself, then push it somewhere your cluster can pull from." That extra step
is not a weaker supply-chain story than the local one — if anything it is
stronger here, because the k8s agent pod holds no credential at all (see
"Model access" above), where a locally-run agent may hold a model token. What
the image carries either way is the same: the agent CLIs, and this project's
stance is unchanged that you should build that from source rather than trust
a copy someone else pushed.

"Bring your own" should not mean "figure it out yourself." Concrete options,
roughly in order of least new infrastructure:

1. **A git forge you may already self-host.** Forgejo and Gitea both ship a
   built-in OCI registry — usually a setting to enable, not a new service.
2. **The upstream distribution registry**, `registry:2` — the smallest
   standalone option when nothing else is running yet.
3. **A hosted registry** — GHCR, ECR, Artifact Registry — when the cluster
   already lives in that provider's cloud.
4. **A distro or k3s built-in registry**, where the cluster ships one.

**The gotcha that costs the most time:** a plain-HTTP or self-signed registry
needs the **nodes** to trust it, configured in the container runtime
(containerd's registry config), not just the machine that pushes. A push can
succeed while every pull on every node fails, and the failure shows up as a
pod stuck in `ImagePullBackOff` on the cluster side, nowhere near the
push that "worked." Set this up before the first `submit`, not after
debugging a stuck pod.

`K8S_IMAGE` itself takes whatever ref your registry gives back —
`registry.example:5000/you/fork-sandbox:latest`, `ghcr.io/you/fork-sandbox`,
whatever your setup names it. This document names no real registry, on
purpose: which one to use is a decision for the operator's own cluster, not
this project's to make for them.

## The Kubernetes platform interface

See [docs/k8s-platform.md](k8s-platform.md) for the full contract. The short
version: clusters differ in which policy dialect their CNI enforces, whether
ICMP can be restricted at all, whether a stronger `RuntimeClass` exists, and
where the cloud metadata address lives, and none of that belongs as `if`
statements scattered through the client. `fork-sandbox-k8s-platform-<name>`
is a small plugin — two verbs, `--capabilities` and `render-policy` — that a
cluster-specific implementation provides. `fork-sandbox-k8s.sh` resolves
`fork-sandbox-k8s-platform-$FORK_SANDBOX_K8S_PLATFORM` (default `generic`) on
`PATH` and then beside itself, the identical rule `sandbox-backend.md` uses
for backends.

v1 ships the contract and **one** implementation, `generic`, which emits
portable `NetworkPolicy`. It does not ship a second. Both the egress gate
(whether to add an ICMP probe) and this document's own limits section read
the platform's declared capabilities rather than assuming anything about a
specific cluster.

## Limits

Stated rather than solved, in the same spirit `docs/sandbox-backend.md` states
what each backend does not hold:

- **No package installation inside a run.** Egress is sealed to DNS and the
  proxy; there is no reachable package registry, no `npm install`, no
  `pip install`, no fetching anything not already in `K8S_IMAGE`.
- **Under `icmp=unfiltered`** — which is what `generic` declares, because
  plain Kubernetes `NetworkPolicy` has no field that denies ICMP — a pod can
  ping-sweep whatever its egress rules leave reachable, and can tunnel data
  out in ICMP echo-request bodies regardless of what the policy's TCP/UDP
  rules say. A platform that declares `icmp=filtered` closes this; `generic`
  does not, and says so rather than implying it does.
- **Under `dns=recursive`** — also `generic`'s declared value — DNS is an
  exfiltration channel: a process that can make DNS queries can encode data
  in the names it asks for, and a recursive resolver forwards them. It is
  also a reconnaissance channel in the other direction: internal cluster
  names still resolve, which leaks the naming scheme of everything else in
  the cluster to a pod that has no other way to see it.
- **The pod's own filesystem, network identity and everything else the pod
  spec controls directly are covered by the guarantees above** — this list is
  specifically the gaps that remain even when every guarantee holds, not a
  restatement of them.

This project states limits rather than implying coverage a given cluster does
not actually have. A future platform that closes one of the ICMP or DNS gaps
should update this section, not just its own `--capabilities` output.

## What transfers from the container backend

Not nothing — this is the second port, and the first one paid for several
lessons:

- The backend contract survived a second implementation without bending, which
  is what made it worth extracting. `docs/k8s-platform.md` follows the same
  discipline for the platform layer: write the contract, implement it once
  against a real constraint, and only then consider a second implementation.
- An image-based sandbox must supply its own toolchain. A Job needs this exactly
  as a container does, and the image already exists.
- passwd and group synthesis, so an unmapped uid resolves. (The container
  backend's synthesis is inside `sandbox-backend-container`; a Job instead
  runs as a fixed, known uid via the pod's `securityContext`, so this
  particular problem does not recur here the same way — there is no unmapped
  uid to synthesize for.)
- **Exit-code discipline.** Take the authoritative status from the runtime's own
  record. The container backend learned this the hard way: an inspect field read
  0 for a container that was still running, so any path where attach returned
  early would have reported success for a run that never finished. The analogue
  here is the pod's terminated container `exitCode`, which is exactly what a Job's
  own status reports — the entrypoint's own `exit "$pi_rc"` is what that
  field ends up holding, and nothing wraps or reinterprets it in between.

## Open questions

Two of the six the design started with are resolved by decisions taken during
implementation. The rest are unchanged.

1. **Credentials for unattended runs.** Resolved differently than the question
   assumed: v1 sidesteps it rather than answering it. The agent pod holds no
   credential of any kind — see "Model access" above — so there is no
   stripped, short-lived token to mint at submit time and nothing for a CI
   trigger's longer-lived key to threaten. This only fully applies to `proxy`
   and `direct` mode; `secret` mode, if it is ever built, reopens this
   question for whoever chooses it.
2. **What runs the agent inside the pod.** Resolved:
   `scripts/fork-sandbox-k8s-entrypoint.sh`, a small dedicated entrypoint
   shipped as a ConfigMap, not `fork-sandbox.sh` in a passthrough-backend
   mode. The passthrough-backend option this question raised was flagged at
   the time as "precisely the shape that becomes a sandbox that lies if it is
   ever reachable outside a pod" — building the small dedicated entrypoint
   instead avoids that risk entirely rather than mitigating it.
3. **Repositories with no reachable remote.** Resolved: no longer a
   limitation at all. See "Getting the repository in: by push, not by clone"
   above — a pushed repository needs no remote, so this capability loss the
   original design accepted does not exist in what got built.
4. **Concurrency and quota.** Still open. `manifests/k8s/00-namespace.yaml`
   sets a namespace `ResourceQuota` and `LimitRange`, which bounds the
   cluster-wide blast radius of a runaway fleet, but nothing yet bounds how
   many runs one person or one pipeline can have in flight at once.
5. **The operator inbox.** Still open, and explicitly out of scope for v1 —
   see "Deliberately not done" below.
6. **Seeding a large read-only cache.** Still open; a volume shared across
   runs still needs a lifecycle, a writer and a story for staleness, and v1
   has no cache-bearing run to force the question.

## Deliberately not done

Scoped out of v1 on purpose, not overlooked:

- **A second platform implementation.** Contract plus `generic` only — see
  `docs/k8s-platform.md`.
- **`--copy-files` as a general, user-facing mechanism.** The repository and
  the handoff both travel the gated channel now; a general "copy anything
  else in" flag is a later round once real usage says what shape it needs.
- **The claude and codex harnesses inside a pod.** pi only, for the same
  reason `--harness pi-local` is pi-only locally: it is the harness this
  project's sealed-network story is built around.
- **A second model-access upstream.** OpenRouter only; see "Model access"
  above for why the shape is a new proxy config file, not a rewrite, when a
  second one is added.
- **The PVC / results-pod upgrade path.** v1 idles the pod, as originally
  planned.
- **The operator inbox** (`fork-sandbox-say.sh`'s cluster equivalent). Nothing
  reaches a running pod after submission in v1.
- **`status` / `logs` subcommands.** `kubectl` already does both, against the
  Job and pod this client creates with ordinary, discoverable names and
  labels.
- **Any change to `fork-sandbox.sh`.** `fork-sandbox-k8s.sh` is a new,
  separate script. No `--k8s` flag exists yet.
- **Any change to `sandbox-backend-*`.** Kubernetes is explicitly not a
  backend — see "This is a run mode, not a backend" above, and
  `sandbox-backend.md`'s own "Kubernetes — deliberately not a backend"
  section.
- **No double isolation.** The pod could run the container backend inside
  itself, and it should not: once the pod spec is right, isolating twice buys
  little and costs the host-path assumptions this design exists to shed.
- **No push credential**, for the reasons in "Credentials" above.
- **No dedicated orchestrator pod.** The client is whatever submits.
