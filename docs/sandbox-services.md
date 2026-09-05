# The sandbox-services hook contract

What a repo commits to get per-run throwaway services in its sandboxed runs,
what the harness (`fork-sandbox.sh`) guarantees, and — the reason this doc
exists — the isolation obligations the repo's hook must hold, because the
harness cannot enforce them.

## The shape

A sandboxed run gets committed state only: no database, no cache, no object
store. A repo opts into per-run services by committing a hook directory:

    .agents/sandbox-services/
        sandbox-services.sh    the hook fork-sandbox.sh invokes
        provision-ro           optional: untracked paths to bind read-only
        README.md              the repo's own documentation

(`.claude/sandbox-services/` is the legacy location and still honored.)

When the directory is present, fork-sandbox.sh stands the services up **on
the host** as a throwaway docker compose project — one per run — and binds a
unix-socket directory into the sandbox. The egress pin is untouched: there
is no TCP path from the sandbox to the host, so the sockets are the only way
in, and a hostile session can at worst trash its own empty per-run stack.

## The interface

The harness invokes the hook with positional arguments only. It passes no
contract-carrying environment variables, so the hook must not rely on any.

    sandbox-services.sh up <sockets-dir> <clone-dir> <project>
    sandbox-services.sh down <project>

`up` runs before the sandbox starts. It must stand the stack up exposed
**only** through unix sockets created under `<sockets-dir>`, and write the
connection settings to `<clone-dir>/.env.sandbox`, which is where the
generated prompt tells the session to look.

`down` runs after the session exits — from a **copy** of the hook directory
taken before the sandbox started, outside the clone. The clone is untrusted
by then (the session wrote to it) and may not even exist, so `down` gets no
clone path and must not read compose files from one: tear down by docker
label (see the obligations below), not by `docker compose down`.

`provision-ro` lists one repo-relative untracked path per line (a `.venv`,
say). Each is bound read-only from the origin repo into the clone at the
same relative path, so the session has a working interpreter without the
network. Read-only is the security boundary: the sandbox must never write
back into the real checkout.

## What the harness guarantees

- **A unique compose project per run.** The project name is the run-dir
  basename (mktemp-unique, prefix `claude-fork-sandbox`), case-folded with a
  checksum suffix so folding cannot collapse two concurrent runs into one
  name. Everything the hook namespaces by `<project>` is therefore isolated
  per run — that namespacing is the hook's job, below.
- **A fresh, empty sockets directory per run**, under the run dir, bound
  read-write into the sandbox. No other run and no other host path is
  reachable through it.
- **The hook runs from a trusted copy.** It is copied out of the clone
  before the sandbox starts; both `up` and `down` run the copy, so a session
  cannot edit the teardown it will be cleaned up by.
- **Teardown always runs.** `down` fires on the runner's EXIT trap however
  the session dies, with timeouts so a wedged docker daemon cannot hang the
  run. An orphan sweep on later runs removes any `claude-fork-sandbox-*`
  compose project whose run dir is gone, by compose-project label.
- **Untrusted refs cannot run the hook.** With `--services-trust-ref <ref>`
  the hook runs only if the checkout did not change the hook directory
  relative to `<ref>`. The hook is host-side code; pr-review-sandbox.sh
  passes the pull request's base, so a PR that introduces or edits the hook
  cannot make it run.
- **Failure is a warning, not a wedge.** If `up` fails, the session still
  runs; the prompt gets a correction telling it the services are absent.
- **The session is told what it has.** The generated prompt gets a "Per-run
  services are up" section naming the sockets directory, the `.env.sandbox`
  convention, and a socat relay recipe for TCP-only clients.

## What the hook must hold

The harness hands the hook a unique `<project>` and a private
`<sockets-dir>`; nothing forces the hook to use them correctly. These are
the properties that make N parallel runs isolated from each other and from
the developer's own stack. Every one is load-bearing.

- **Namespace everything by `<project>`.** Drive compose with
  `-p "$project"`. Declare volumes bare in the top-level `volumes:` block —
  never `external: true`, never an explicit `name:` — so compose prefixes
  each as `<project>_<volume>` and every run gets its own fresh, empty set.
  Never set `container_name:`, which is likewise global. The developer's
  stack lives under a different project name and is never touched.
- **Publish no host ports.** The base compose file may publish ports for
  interactive development; the sandbox overlay must strip them with
  `ports: !override []` (compose v2.24+ — a plain overlay list merges and
  leaves the base ports published). Parallel runs would otherwise collide,
  and a session could cross-connect to the wrong stack or the dev one.
  Sockets under `<sockets-dir>` are the only reachability.
- **Bind-mount no shared host data.** The only host path in any container is
  `<sockets-dir>`. Never bind a data directory — that is how a run reaches
  another run's state, or the developer's.
- **Tear down by label only.** `down <project>` removes containers, volumes,
  and networks filtered by `label=com.docker.compose.project=<project>` —
  exactly the set `docker compose down -v --remove-orphans` would remove,
  without needing the compose files (which are gone with the clone). Never
  remove by name pattern; a pattern wide enough to catch strays is wide
  enough to catch a neighbor.
- **Come up empty.** Copy no developer data in. The session migrates and
  loads its own fixtures; the prompt tells it so.
- **Budget memory per run.** Runs multiply: a three-leg review panel is
  three stacks. A JVM service with a fixed heap (OpenSearch at ~2 GB, say)
  dominates, so keep per-run limits sane and document them in the hook's
  README.
- **Mind the sockets-dir permissions.** The directory is typically made
  world-writable so containers running as their own uid can create sockets
  in it; any service with auth disabled is then only as private as that
  directory. Fine for a single-user host running sealed sandboxes; say so in
  the repo's README, and do not use the pattern on a shared host.

Isolation here is docker-level: all stacks share one daemon. It is
namespacing and resource isolation, not a security boundary against a
container escape.

## Reference implementation

A working implementation of all of the above looks like this: a
`.agents/sandbox-services/` directory holding the compose file and its hook
script, with postgres on its native unix socket, socat sidecars bridging the
TCP-only services to sockets, `ports: !override []` throughout, and
label-scoped teardown. Where a project already has a service-management
script of its own, the hook is best written as a thin adapter over it plus a
compose overlay that swaps published ports for socket mounts.

## The cluster path: a committed spec, not a hook

Everything above is the local path: an executable hook the harness invokes.
The `--k8s` cluster path takes different input for the same idea — committed
data, never code the harness would run with its own credentials. Two
reasons, both load-bearing:

1. The harness can then **guarantee** the sidecar's security context outright
   instead of hoping a hook script emitted one.
2. A spec is backend-agnostic, unlike a hook: the same file is meant to grow
   into driving the local path too, later. The hook above is not going away
   and is not being migrated by this section.

### Where it lives

    .agents/sandbox-services/services.yaml

Same directory as the hook above, so a repo keeps one services directory
regardless of which backend it runs under. Absent file means no services and
no behaviour change — silent, not a warning, since that is the case every
existing repo is in.

### The schema, version 1

```yaml
version: 1
services:
  - name: postgres
    image: registry.example/rootless/postgres:16
    port: 5432
    env:
      POSTGRES_PASSWORD: dev
    writableDirs:
      - /var/lib/postgresql/data
    readyWhen:
      tcpPort: 5432
    resources:
      cpu: 500m
      memory: 512Mi
sandboxEnv:
  DATABASE_URL: "postgres://dev:dev@127.0.0.1:5432/dev"
```

- `version` — required, must be `1`. Any other value is refused, naming the
  supported versions — this is how the schema changes later without a repo
  silently getting the wrong parse.
- `services[].name` — required, `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, unique,
  and not one of the harness's own pod container names. Becomes the
  sidecar's container name.
- `services[].image` — required, an image ref. An unqualified image resolves
  wherever the cluster's container runtime points (commonly Docker Hub);
  fully qualify the ref to pin the registry.
- `services[].port` — required, an integer **1025-65535**. Every service
  container runs non-root (below), and a non-root process cannot bind a port
  under 1024. Must not collide with another service's port.
- `services[].env` — optional, a flat map of string to string. Literal
  values only — no `valueFrom`, no secret reference, no substitution.
- `services[].writableDirs` — optional, a list of absolute paths, each
  mounted as its own `emptyDir`. Needed because the container runs with
  `readOnlyRootFilesystem: true` and a service still needs somewhere to
  write. Each must be absolute and must not contain a `..` component.
- `services[].readyWhen.tcpPort` — optional. Renders a `startupProbe` so the
  agent does not race the service coming up. There is no `exec` form: a
  command here would be repo-controlled execution, which is exactly what a
  spec (as opposed to a hook) removes.
- `services[].resources` — optional, `cpu` and `memory`; omitted members
  default to the configured cap, and all values are capped by the harness —
  see `docs/kubernetes-runs.md`'s `K8S_SERVICES_MAX` /
  `K8S_SERVICE_MAX_CPU` / `K8S_SERVICE_MAX_MEMORY`.
- `sandboxEnv` — optional, a flat string map, written verbatim to
  `.env.sandbox` in the clone — the same filename the local hook path
  writes. No templating and no substitution: the repo already chose the
  ports, so it writes the literal connection URL itself. The port appearing
  twice (once in a service's own `port`, again inside a `sandboxEnv` URL) is
  deliberate — it buys away an entire class of injection surface a
  templating step would reintroduce.

**Unknown keys anywhere are an error, not ignored.** A typo'd `writeableDirs`
that silently does nothing is exactly how a repo ends up debugging a service
that has no disk.

There is no field for `securityContext`, `hostPath`, `hostNetwork`,
`privileged`, `capabilities`, or a service account — attempting any of them
is rejected as an unknown key. Not merely refused: **not expressible**, so
there is nothing to bypass.

### Validation is the security boundary

The spec comes from the repo, and the repo is something the agent itself can
edit — every field is treated as hostile. Rejections name the offending
field, e.g. `services[0].port: must be between 1025 and 65535, got 80`.
`--services-trust-ref REF` gates the spec exactly as `--checkout` is gated
for the rest of a run — see `docs/kubernetes-runs.md`'s "Per-run services"
section for the three-way trust rule.

### What the harness guarantees on every sidecar, never from the spec

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
```

The namespace also enforces PodSecurity `restricted`; a pod missing this is
rejected outright by the cluster, with no pod ever scheduled. `runAsUser`,
`runAsGroup`, `fsGroup` and the seccomp profile come from the pod's own
`securityContext`, which already applies to every container in the pod,
sidecars included — they are not restated per service.

Each service renders as a **native sidecar**: an `initContainers` entry with
`restartPolicy: Always`, never a plain `containers:` entry. A Job pod is
`Complete` only once every container has terminated, and a service never
exits on its own — a regular container would hang the run until its TTL. A
native sidecar starts before the main container, runs alongside it, and is
terminated by the kubelet when the agent's own container exits.

Two consequences worth knowing before reaching for this:

- **A service image that needs root at startup cannot run here.** The stock
  `postgres` image is the headline case — it starts as root to `chown` its
  data directory before dropping privileges. Bring a rootless-capable image
  instead; there is no way to relax the security context above for one
  service.
- **A service that ignores `SIGTERM` costs every run 30 extra seconds.** The
  pod sets `terminationGracePeriodSeconds: 10` whenever services are
  present, but a sidecar that does not handle `SIGTERM` as PID 1 rides out
  the grace period and then still eats the kubelet's default wait before
  `SIGKILL` — a run that finishes its actual work in seconds still pays the
  full teardown. A service image that reaps `SIGTERM` avoids this entirely.

### Telling the agent

The clone gets `.env.sandbox` written pod-side, before the agent starts,
from the spec's `sandboxEnv` — absent `sandboxEnv` writes nothing. The
generated prompt gets a `## Per-run services` section naming each service's
`127.0.0.1:<port>` and the `.env.sandbox` convention, in the same register as
the local path's own "Per-run services are up" section above, minus the
sockets directory and socat relay recipe — a sidecar shares the pod's
network namespace, so it is reachable directly.
