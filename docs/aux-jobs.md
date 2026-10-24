# Auxiliary Jobs from postmaster hooks

`scripts/fork-sandbox-aux-jobs` is a generic launcher for auxiliary CI
tasks ("render a video for this PR") that run as Kubernetes Jobs. It reads
a small registry and creates one Job per entry that matches the hook
event, so a new task is a registry entry, not a new hook. See "Hooks" in
[agent-mail.md](agent-mail.md) for the events and the environment a hook
gets. The cluster postmaster pod has `python3`, `python3-yaml` and
`kubectl`, and `fork-sandbox-aux-jobs` is on its PATH.

## The hook

A deployment writes one hook file per event it uses (for example
`on-target.aux`), with this body:

```bash
#!/usr/bin/env bash
exec fork-sandbox-aux-jobs --registry "$(dirname "$0")/aux-jobs.yaml"
```

`--registry` is required; there is no default path. The launcher reads
`FS_HOOK_EVENT`, `FS_HOOK_THREAD`, `FS_HOOK_MAIL_ROOT` and `FS_TARGET_*`
from the hook env.
`--dry-run` prints the Job manifests as JSON and calls no kubectl.

## The registry

A YAML list. The file ships in the hooks ConfigMap, which carries only
executable files, so a deployment names it `aux-jobs.yaml` and gives it
mode 0755; the launcher does not care about the mode.

```yaml
- name: render-panel            # app label and Job name prefix
  event: on-target              # on-harvest | on-target | on-quiescent
  image: registry.example.com/team/render-panel:sha-0123456789abcdef0123456789abcdef01234567
  gates:
    repo: [example-org/example-repo]   # X-Preview-Repo of the thread root
    requires_pr: true                  # root must carry X-Preview-PR
  repo_default: example-org/example-repo   # used when the header is absent
  env:
    PR:      {header: X-Preview-PR}
    REF:     {header: X-Preview-Ref, default: main}
    VERSION: {hook_env: FS_TARGET_VERSION}
    MODE:    {value: fast}
  secrets:
    - {secret: render-token, key: token, path: /run/secrets/render-token}
  resources:
    requests: {cpu: 500m, memory: 1Gi}
    limits: {memory: 2Gi}
  active_deadline_seconds: 1800
  ttl_seconds_after_finished: 86400   # default
  run_as: {uid: 1000, gid: 1000}      # default
```

- `name` matches `^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`.
- `image` must be pinned: `:sha-<40 hex>` or `@sha256:<64 hex>`. Anything
  else, `:latest` included, is refused.
- Each `env` entry has exactly one source. A `header` source with no
  `default` whose header is absent from the thread root means that entry
  does not launch (logged, skipped). `hook_env` takes an `FS_*` name; an
  unset one is the empty string.
- Each `secrets` item mounts one key of a Secret read-only, mode 0444, at
  `path`. The launcher never reads the secret.
- Unknown fields are refused, so an entry cannot reach the Job spec.

Gates come only from what the thread carries: the root message's headers
(lowest `seq`, via `fork-sandbox mail export <thread> --json`). The
launcher never makes a GitHub or other network read. There are no other gate
kinds; a task that needs more filters itself in its Job and exits 0.

The whole registry is validated first. One invalid entry exits non-zero,
naming the entry and field, and launches nothing. An absent file exits 0
and launches nothing.

## The fixed Job spec

Set by the launcher; entries cannot override it. PodSecurity `restricted`
(runAsNonRoot, seccomp RuntimeDefault, no privilege escalation, all
capabilities dropped), `automountServiceAccountToken: false`,
`restartPolicy: Never`, `backoffLimit: 0`, an emptyDir at `/work`. Labels
are `app: <name>` and `aux-job: <name>`, never `fork-sandbox/*` or
`app=fork-sandbox-agent` (the postmaster's cleanup paths delete by
those). The namespace is kubectl's current one. The Job is named
`<name>-<short thread id>-<target version, or event>-<random suffix>`, at
most 63 characters, and is created with `kubectl create -f -` (60 s timeout).

## Failure semantics and accepted risks

Entries launch independently. If a `kubectl create` fails the rest still
launch and the exit status is non-zero, naming the failures. The
postmaster logs the exit; nothing retries, keeps a ledger or dedupes. An
operator re-fires with `hook fire`, and the Job dedupes itself.

Accepted: Job egress is open (no default-deny in the namespace, and plain
NetworkPolicy cannot express an FQDN allowlist; a per-Job policy is a later
step), and the registry must be mode 0755 to ship.
