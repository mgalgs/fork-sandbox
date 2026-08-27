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
