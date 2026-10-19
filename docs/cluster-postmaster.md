# Running the postmaster in the cluster

This is a single-replica Deployment that runs the same
`fork-sandbox-postmaster.sh` a laptop runs, so a review panel keeps working
when no laptop is on. It watches the agent-mail store, wakes addressed
seats, harvests their replies, and enforces the stop rules, exactly as it
does on a workstation.

## What it is not, yet

- **No codex seats.** The cluster postmaster always refuses to wake a
  `codex` seat; that harness needs a credential in the pod, and shipping
  one is deferred.
- **Claude seats need a credential installed.** A pi seat always works,
  no credential needed. A `claude` seat is refused until a site installs
  a claude credential -- see "Claude seats in a cluster postmaster"
  below.
- **No local or bwrap seats, no triage.** Only seats a pod can actually run
  get woken; anything else is refused rather than silently mis-scheduled.
- **A fresh store.** The pod starts from an empty agent-mail store. Threads
  on a laptop's store are not imported.
- **Remote mail access is opt-in.** Without a tokens file (see "The mail
  API" below) nothing outside the pod can read or post to the store, and
  the only way to reach it is:

  ```
  kubectl exec deploy/fork-sandbox-postmaster -- fork-sandbox mail ...
  ```

  Treat that as cluster-admin-only: `kubectl exec` into this pod reaches
  every Secret the pod's ServiceAccount can read (see "Security posture"
  below), not just the mail store. A team that wants to reach the store without
  exec uses the mail API's team access (see "The mail API" below).

## Setup

Do these in order.

1. **Build and push the sandbox image**, `scripts/build-sandbox-image.sh`
   with no `--postmaster` and no project `--base` (see
   [docs/kubernetes-runs.md](kubernetes-runs.md)), then build and push the
   postmaster image, a thin layer over it that adds `kubectl` and `ssh`:

   ```
   scripts/build-sandbox-image.sh --postmaster --base <sandbox-image>
   ```

   The base is that plain sandbox image, not `K8S_IMAGE`: at a site whose
   `K8S_IMAGE` is a project's seat image, layering on it would ship the
   project's toolchain in the postmaster. Push the tag it prints to the
   registry the cluster pulls from.

2. **Create a read-only deploy key and a known_hosts file** for the project
   repo the postmaster clones. The key must be read-only on the remote (the
   pod never pushes); `known_hosts` must be pre-populated, since the pod
   never trusts a host on first use.

3. **Add the postmaster keys to `k8s.env`**, alongside the keys an ordinary
   cluster run already reads:

   | key | required | meaning |
   |---|---|---|
   | `K8S_POSTMASTER_IMAGE` | yes | the image ref step 1 built and you pushed |
   | `K8S_POSTMASTER_BASE_IMAGE` | for `upgrade-postmaster` | the plain sandbox image step 1 layered on; see "Updating" |
   | `K8S_POSTMASTER_DEPLOY_REPO` | for `deploy-main` | git URL (`https://`, `ssh://` or `file://`) of a deploy repo whose CI runs `upgrade-postmaster`; see "Deploying from a deploy repo" |
   | `K8S_POSTMASTER_REPO_URL` | yes | ssh URL of the project repo: `ssh://[user@]host[:port]/path` or the scp-like `user@host:path` form. Anything else (`https://`, a bare hostname) is refused. |
   | `K8S_POSTMASTER_PROJECT` | no | directory name under `$HOME/src` in the pod; defaults to the URL's last path component with a trailing `.git` stripped. Must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`, so it can never be `.` or `..`. A `K8S_PROJECT_IMAGES` entry (see "Per-project and per-run images" in [docs/kubernetes-runs.md](kubernetes-runs.md)) keys on this same name, since a run the postmaster spawns resolves its default image from the project path it was handed, the same as any other run. |
   | `K8S_POSTMASTER_GIT_KEY_FILE` | yes, unless `K8S_POSTMASTER_GIT_SECRET` | laptop path to the deploy private key from step 2 |
   | `K8S_POSTMASTER_KNOWN_HOSTS_FILE` | yes, unless `K8S_POSTMASTER_GIT_SECRET` | laptop path to the known_hosts file from step 2 |
   | `K8S_POSTMASTER_GIT_SECRET` | no | name of a Secret you create with keys `deploy-key` and `known_hosts`, instead of the two files. See "Secrets by reference". |
   | `K8S_POSTMASTER_STORAGE_CLASS` | no | `storageClassName` of both PVCs; empty (the default) omits the field, so the cluster's default StorageClass applies |
   | `K8S_POSTMASTER_STORAGE` | no | the data volume's requested size; default `20Gi`; must match `^[0-9]+(Mi\|Gi\|Ti)$` |
   | `K8S_POSTMASTER_MAIL_STORAGE` | no | the mail volume's requested size; default `2Gi`; same pattern as `K8S_POSTMASTER_STORAGE` |
   | `K8S_POSTMASTER_ACCESS_MODE` | no | access mode of both PVCs: `ReadWriteOncePod` (default) or `ReadWriteOnce`, for a StorageClass or CSI driver that does not support RWOP yet; anything else is refused |
   | `K8S_POSTMASTER_SEAT_SERVICES` | no | `true` (default) or `false` for k8s seat services; a seat's `services` value in `fleet.yaml` wins over this default. Other values are refused by `install --postmaster`. |
   | `K8S_POSTMASTER_OPERATORS` | no | comma-separated `@names` that carry rule-1 authority; default `@operator`. See "Operators". |
   | `K8S_POSTMASTER_HOOKS_SECRET` | no | the name of a Secret you create in the namespace, to hand your hooks credentials. Install never creates or reads it, only references it. Must be a DNS-1123 subdomain name. See "Hooks". |
   | `K8S_MAIL_API_TOKENS_FILE` | no | laptop path to the mail API tokens file; when set, the mail API is deployed. See "The mail API". |
   | `K8S_MAIL_API_TOKENS_SECRET` | no | name of a Secret you create with key `tokens`, instead of the file; it deploys the mail API the same way. See "Secrets by reference". |
   | `K8S_MAIL_TEAM_SUBJECTS` | no | who may use the mail API's shared team token: comma-separated `user:<name>` and `group:<name>`, no spaces. When set, install binds Role `fork-sandbox-mail-team` to exactly those subjects; unset (the default) renders the Role and no binding. Only meaningful with `K8S_MAIL_API_TOKENS_FILE`. See "Team access" in [mail-api.md](mail-api.md). |
   | `K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` | no | laptop path to a claude credentials JSON; when set, claude seats are accepted in the cluster. See "Claude seats in a cluster postmaster". |
   | `K8S_POSTMASTER_CLAUDE_SECRET` | no | name of a Secret you create with key `credentials.json`, instead of the file (not with the pool). See "Secrets by reference". |
   | `K8S_POSTMASTER_CLAUDE_CREDENTIAL_POOL` | no | colon-separated absolute laptop paths to Claude credential files; set with `K8S_POSTMASTER_CLAUDE_HEADROOM_HOOK` instead of the single file. |
   | `K8S_POSTMASTER_CLAUDE_HEADROOM_HOOK` | no | plugin name selected from `K8S_POSTMASTER_HEADROOM_DIR`; required with the pool. |
   | `K8S_POSTMASTER_HEADROOM_DIR` | no | laptop directory of executable headroom plugins, shipped as a ConfigMap and put on the postmaster's `PATH`. |

   For review seats that do not need the project's per-run services, set
   `services: false` on each k8s agent in `fleet.yaml`, or set
   `K8S_POSTMASTER_SEAT_SERVICES=false` in `k8s.env`. A per-seat
   `services: true` restores services. Precedence is per seat, then env,
   then the existing enabled default. `fleet check --cluster` requires a
   YAML boolean.

   `K8S_AGENT_PRIORITY_CLASS` applies to agent Jobs and their per-run proxy
   Pods. The PriorityClass must already exist; `install` checks and warns
   if it cannot find it, but does not create it.

   The rest of `k8s.env` (`K8S_CONTEXT`, `K8S_NAMESPACE`, and the rest) is
   read the same way a laptop run reads it, since the whole file is copied
   into the pod as its config. If the config dir also has `fleet.yaml` and
   any of `personas/`, `prompts/`, `handlers/`, `presets/` (all directly
   under `$HOME/.config/fork-sandbox`), those come along too: each becomes
   its own ConfigMap, included only if the matching directory exists on the
   laptop. `FORK_SANDBOX_FLEET_FILE` and `FORK_SANDBOX_PERSONAS_DIR`, when
   set in the installing shell's environment, override the fleet file and
   personas dir source: install ships that file and that dir instead of
   `$config_dir/fleet.yaml` and `$config_dir/personas`, for a site that
   keeps its fleet and personas in a repo of its own. Unset or empty falls
   back to `$config_dir`, unchanged from before this pair of variables
   existed. Every other install-time dir (prompts, handlers, hooks,
   presets) still reads only `$config_dir`. Files under `handlers/` must
   be executable to be included; a non-executable one is skipped with a
   warning, the same way the laptop postmaster would skip it.

   The laptop's `hooks/` dir (same config dir as `handlers/`) ships the
   same way, into ConfigMap `fork-sandbox-postmaster-hooks`, and again only
   executable files are included. The dir is flat files (`on-<event>` and
   `on-<event>.<suffix>`), since a ConfigMap cannot hold subdirectories.
   See "Hooks" below.

4. **Install:**

   ```
   scripts/fork-sandbox-k8s.sh install --postmaster
   ```

   Before rendering anything, install runs `fork-sandbox-fleet.sh check
   --cluster` on the fleet it is about to ship (the `fleet.yaml`,
   `personas/`, `handlers/` and `presets/` under the config dir) and
   refuses a fleet the pod could not run: the postmaster runs the same
   check at startup and would crash-loop on a local, triage or codex
   seat, or a claude seat with no credential installed (see "Claude
   seats in a cluster postmaster" below).

   It then applies the base cluster manifests exactly as plain `install`
   does, and renders and applies the postmaster's own pieces: a
   ServiceAccount, Role and RoleBinding, two PVCs, a Secret holding the deploy
   key and known_hosts (unless it is referenced), one or more ConfigMaps,
   and the Deployment itself (plus the mail API's Secret and Service when it
   is enabled).
   `--dry-run` prints everything it would apply, with each Secret's content
   replaced by a placeholder line — its bytes never reach stdout or stderr
   either way.

5. **Confirm it came up:**

   ```
   kubectl rollout status deployment/fork-sandbox-postmaster
   kubectl logs deployment/fork-sandbox-postmaster
   ```

## Updating

- **Config changes** (`k8s.env`, `fleet.yaml`, personas, prompts, handlers,
  presets) need `install --postmaster` run again. The Deployment's pod
  template carries a `checksum/pm-config` annotation computed over the
  rendered ConfigMaps and Secrets; a changed checksum is a changed pod
  template, which rolls the pod.
- **Config applied some other way** (a GitOps tool applying the rendered
  manifests, or a hand edit of a ConfigMap) is not live when the apply
  returns. If the pod does not roll, it sees the change only once the
  kubelet syncs the mounted ConfigMap, which takes up to about a minute by
  default. Mail sent in that window runs with the old values, a stale
  `K8S_IMAGE` included. If it does roll, the old pod may take mail until
  the new one is ready. Either way, wait for `kubectl rollout status`, or
  for the pod to show the new value, before sending.
- **Rotating the git deploy key** is the same: replace the file named by
  `K8S_POSTMASTER_GIT_KEY_FILE` (or `K8S_POSTMASTER_KNOWN_HOSTS_FILE`) and
  run `install --postmaster` again. The Secret is part of the checksum, so
  the pod rolls and picks the new key up at init.
- **A new fork-sandbox version** needs a new postmaster image. From a
  clean checkout of the version to deploy, one command does the whole
  sequence:

  ```
  scripts/fork-sandbox-k8s.sh upgrade-postmaster [--timeout 10m]
  ```

  It needs `K8S_POSTMASTER_BASE_IMAGE` in `k8s.env`: the plain sandbox
  image from setup step 1, never `K8S_IMAGE`. The new image is
  `K8S_POSTMASTER_IMAGE`'s repository, tagged with HEAD's 10-character sha.
  That key's own tag is ignored. The command runs these steps and, on
  failure, names the step that failed:

  | step | what it does |
  |---|---|
  | preflight | refuses untracked or uncommitted files, and a HEAD not reachable from `origin/main` (or `main` when there is no `origin/main`; a detached checkout of a merged sha passes). Then it runs `install --postmaster --dry-run` against the new image, so a config error stops it before a build. |
  | build | `build-sandbox-image.sh --postmaster --base "$K8S_POSTMASTER_BASE_IMAGE"` |
  | push | pushes the image with `$FORK_SANDBOX_CONTAINER_CLI` (default `docker`); the registry login is yours |
  | install | `install --postmaster --image <ref>` |
  | rollout | `kubectl rollout status deployment/fork-sandbox-postmaster` |
  | verify | the one live pod runs every container (postmaster, and mail-api when the mail API is configured) ready on the new image |

  `k8s.env` is never written. `install --postmaster --image <ref>` deploys
  `<ref>` for that one install. Afterwards, `K8S_POSTMASTER_IMAGE` still
  names the old tag, and a later plain `install --postmaster` would deploy
  that tag. Either bump the key, or keep running config changes through
  `upgrade-postmaster` too.
- **New commits on the project repo** reach the pod only at pod start: the
  pod init clones once (or, on a restart, fetches and fast-forwards the
  existing clone to `origin`'s tip) and the postmaster itself never fetches
  again afterward. A running pod does not pick up new commits on its own;
  restart it (a rollout, or deleting the pod) to pull them in.
- **Moving to the two-volume storage layout.** An install made before it
  has one PVC laid out in subPath directories that may be root-owned, which
  the pod cannot write. Scale the Deployment to 0, delete PVC
  `fork-sandbox-postmaster`, then run `install --postmaster` again. This
  discards the old store; it holds no imported threads (see "A fresh
  store").
- **A rollout no longer loses mail API calls.** The `Recreate` strategy takes
  the API down for the length of a rollout, but `fork-sandbox mail --remote`
  and `postmaster --remote` retry through it on their own (a 5 minute budget
  by default, `K8S_MAIL_API_RETRY_SECONDS` in `k8s.env`), and the server
  records each state-changing call's idempotency key on the mail volume, so a
  retried send is not delivered twice. This holds for callers that reach the
  API through a stable endpoint, such as the in-cluster
  `http://fork-sandbox-mail-api.<namespace>.svc` URL. A `kubectl
  port-forward` to the Service is bound to the one pod it picked and never
  reconnects to the replacement, so a caller behind one retries to no
  effect: restart the forward after a rollout, or run it under a supervisor
  that does. A call is also lost if the rollout outlasts the caller's
  budget, or if the server is an older version that does not know the key
  (its retries are at-least-once). See "The `--remote` client" and
  "Idempotency keys" in [mail-api.md](mail-api.md).
- **In-flight seats survive a rollout.** A restarted postmaster adopts
  still-running Jobs instead of re-spawning them, so a rollout does not
  lose a seat's work in progress. A Job whose submit never finished pushing
  its inputs cannot be adopted: it is refused and its objects deleted (see
  "The run directory is the join" in
  [kubernetes-runs.md](kubernetes-runs.md)). So the old postmaster drains
  before it exits. On SIGTERM it launches nothing more and waits until no
  wake is still submitting and no hook is still running, for at most
  `FORK_SANDBOX_POSTMASTER_DRAIN_TIMEOUT` seconds (default 150). The pod's
  `terminationGracePeriodSeconds` (180) covers that wait, and the
  whole shutdown stays inside the mail client's 5 minute retry budget. A
  `pm drain done busy=<n>` line with `n` above 0 means the timeout cut
  something off. A run may be adopted at most twice, but an adoption after
  a clean shutdown does not count: the drain marks each live wake
  `handed-off` (a `pm handed-off` line), so a long seat survives any number
  of rollouts. Only a wrapper that dies some other way spends one.

  This is the postmaster adopting its own restarted wake wrapper
  (`fork-sandbox-k8s-wake.sh --adopt`, which calls `fork-sandbox-k8s.sh
  resume` under the hood) -- a narrower case than the general-purpose
  `fork-sandbox adopt <run-dir>` verb: the postmaster already knows which
  wake directories are its own and adopts automatically, on its own
  restart, with no caller involved. A `--k8s` run submitted OUTSIDE the
  postmaster (a workstation's own `fork-sandbox run --k8s`, or any other
  caller holding a run directory) has no such automatic restart story --
  that is what `fork-sandbox adopt` is for, called by whatever the
  consumer's own re-adoption logic is. See "Re-adopting a run whose
  host-side driver died" in [kubernetes-runs.md](kubernetes-runs.md).

## Deploying from a deploy repo

`upgrade-postmaster` can run in CI instead of on a workstation. The site
keeps a private deploy repo that holds its `k8s.env`, `fleet.yaml` and
hooks, plus a `pins.env` naming the exact commits to deploy. CI runs
`upgrade-postmaster` from a checkout at those pins on every push to the
deploy repo's `main`. A deploy is then a change to `pins.env`.

`deploy-main` makes that change for you:

```
scripts/fork-sandbox-k8s.sh deploy-main [--dry-run]
```

`pins.env` holds one pair of lines per repo the deploy pins:

```
FORK_SANDBOX_REPO=https://example.com/you/fork-sandbox.git
FORK_SANDBOX_SHA=<40-hex sha>
```

The verb clones the deploy repo named by `K8S_POSTMASTER_DEPLOY_REPO` in
`k8s.env`. It sets every `<NAME>_SHA` to the current head of `main` on
`<NAME>_REPO`, then commits and pushes to the deploy repo's `main`. It
never force-pushes: if `main` moved meanwhile, the push is refused,
nothing is deployed, and you run it again. If nothing changed, it says so
and pushes nothing. `--dry-run` prints the diff and pushes nothing.

A pin can carry two optional extras:

```
HOOK_REPO=ssh://git@example.com/you/app.git
HOOK_BRANCH=dev
HOOK_SHA=<40-hex sha>
HOOK_TEMPLATE=scripts/hook-launcher
HOOK_RENDER_TO=config/hooks/on-harvest.app,config/hooks/on-quiescent.app
```

- `<NAME>_BRANCH` follows a branch other than `main`.
- `<NAME>_TEMPLATE` and `<NAME>_RENDER_TO` go together. On every run,
  `deploy-main` reads the template from `<NAME>_REPO` at the new sha,
  replaces each `@PIN@` with that sha, and writes the result, with the
  template's mode, to each comma-separated path in the deploy repo. The
  rendered files land in the same commit as the `_SHA` line, so a file
  that embeds a sha cannot fall behind its pin. A rendered file edited by
  hand is overwritten on the next run. A template with no `@PIN@` is
  refused.

The laptop running `deploy-main` reads every pinned repo, so the deploy
repo's CI needs read access only to the repos it clones itself. A repo
used only for rendering needs no CI credential.

It takes no sha on purpose. It can only deploy what has already merged to
the pinned branch, so an operator can allow it without a prompt and still
review every deploy where the code is merged. Git runs with
`GIT_ALLOW_PROTOCOL=https:ssh:file`, and every URL must use one of those
schemes. To roll back to an older sha, edit `pins.env` and the rendered
files by hand.

## The mail API

The mail API is a small HTTP server that runs the `mail` and `postmaster`
verbs from a fixed allowlist, so a CI job or a laptop can reach the pod's
mail store without `kubectl exec`. It runs as a second container in the
postmaster pod; the protocol, the tokens file and the verb allowlist are
described in [docs/mail-api.md](mail-api.md).

To enable it:

1. Mint an operator token first, then one token per client:

   ```
   fork-sandbox mail-api mint --role operator --label laptop
   fork-sandbox mail-api mint --role client --label ci-kickoff \
       --as @ci-kickoff --caps read,grant
   ```

   Each prints the raw token on its first line (keep it) and the tokens-file
   line, holding only the token's hash, on its second.
2. Put the tokens-file lines in one file, mode 0600, owned by you, and set
   `K8S_MAIL_API_TOKENS_FILE` in `k8s.env` to its path.
3. Run `install --postmaster`. Install checks the file with
   `fork-sandbox-mail-api.py check` (under `K8S_POSTMASTER_OPERATORS`) and
   refuses on the loader's one-line error, then creates a Secret from it
   and adds the container and a ClusterIP Service,
   `fork-sandbox-mail-api`. With the key unset, install strips all three
   and prints one note that the API is not deployed.

**Team access.** With the API enabled, install also creates a shared,
operator-role "team" token, so any teammate with Kubernetes access to the
namespace can use `fork-sandbox mail --remote` after one setup command, with
no token to mint or hand over. The raw token lives in Secret
`fork-sandbox-mail-api-team-token`; its hash is served beside the tokens-file
entries, which keep working unchanged. Install creates the Secret only when it
is absent and never rotates it on a re-install (so re-running install cannot
lock the team out); `install --postmaster --rotate-team-token` is the one way
to replace it, and it rolls the pod. Role `fork-sandbox-mail-team` grants only a
port-forward to the API and `get` on that one Secret, and K8S_MAIL_TEAM_SUBJECTS
binds it. The tokens file must still have at least one entry. Onboarding,
what the token can do, rotation and clearing a flag are in "Team access" in
[mail-api.md](mail-api.md).

**Rotation.** Edit the tokens file and re-run `install --postmaster`. The
server reads its tokens once at startup; the Secret is part of the
`checksum/pm-config` annotation, so a changed file rolls the pod.

**From a laptop**, through a port-forward:

```
kubectl port-forward svc/fork-sandbox-mail-api 8765:80
```

A port-forward does not follow a rollout to the new pod: restart it
afterward, or keep it under a supervisor that does (see the operations note
"A rollout no longer loses mail API calls"). Then set
`K8S_MAIL_API_URL=http://127.0.0.1:8765` and
`K8S_MAIL_API_TOKEN_FILE=<file holding the raw token>` in `k8s.env` and use
`fork-sandbox mail --remote <verb> ...` (and `fork-sandbox postmaster
--remote <verb> ...`).

**From a laptop, with team access**, there is nothing to forward by hand:
`fork-sandbox mail-forward --setup` and then `fork-sandbox mail --remote ...`
start and supervise the forward themselves.

**In-cluster callers** use `http://fork-sandbox-mail-api.<namespace>.svc`.
Seat pods cannot reach it: the agent NetworkPolicy pins their egress.

**Security.** The API container holds no ServiceAccount token: the pod
turns off the automatic mount and projects the token into the postmaster
container only, so the network-facing container cannot read the
namespace's Secrets. It has its own `$HOME` and `/tmp`, never the
postmaster's, since the postmaster reads its kubeconfig, gitconfig and
deploy key from `$HOME`. It also mounts only the mail volume
(at `/var/tmp/claude-scratch/agent-mail`), never the data volume: the
postmaster's wake directories under `forks/` hold the launch records it
executes, and stay out of the API container's reach. The
mail root's `.postmaster` state is writable from the API (it needs that for
`flag` and `unflag`), and holds run records naming a wake directory, so in
cluster mode the postmaster only adopts a run whose directory is one of its
own wake directories. Even so, treat a compromised API container as able to
tamper with mail and postmaster state, and restrict who holds API tokens
accordingly. It speaks plain HTTP; a site
that wants TLS fronts it itself.

## Hooks

The postmaster runs site-supplied hooks on harvest, review-target and
quiescence events; the events, environment and rules are in
[docs/agent-mail.md](agent-mail.md), "Hooks". In the cluster they ship
like handlers do. The installer reads the laptop dir `hooks/` (under the
same config dir as `handlers/`), takes executable files only, and puts
them in the ConfigMap `fork-sandbox-postmaster-hooks` as flat files
(`on-<event>` and `on-<event>.<suffix>`; no subdirectories, which a
ConfigMap cannot hold). A per-seat `wake-when.<suffix>` gate ships in the
same dir, but unlike those hooks it runs synchronously, before a spawn of
the seat that names it (agent-mail.md, routing rule 5). It is mounted at
`/etc/fork-sandbox/hooks` in the postmaster container only, with
`FORK_SANDBOX_HOOKS_DIR` set to that path. Like any config change, editing
a hook needs `install --postmaster` run again.

A hook that needs a credential of its own gets it from a Secret the site
creates. Set `K8S_POSTMASTER_HOOKS_SECRET=<name>` in `k8s.env`. Install
never creates or reads that Secret; it only references it. It is mounted
read-only at `/etc/fork-sandbox/hook-secret` in the postmaster container
only, and `FS_HOOK_SECRET_DIR` is set to that path in every hook's
environment. The name follows the rules in "Secrets by reference" below,
so a typo cannot hand a hook the provider key or another credential.

## Secrets by reference

Install can build every postmaster Secret from laptop files, which suits a
single operator. A site that deploys from CI, or keeps credentials off
laptops, can instead create the Secrets in the namespace itself and name
them in `k8s.env`:

| key | replaces | the Secret holds |
|---|---|---|
| `K8S_POSTMASTER_GIT_SECRET` | `K8S_POSTMASTER_GIT_KEY_FILE`, `K8S_POSTMASTER_KNOWN_HOSTS_FILE` | `deploy-key`, `known_hosts` |
| `K8S_POSTMASTER_CLAUDE_SECRET` | `K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` | `credentials.json` |
| `K8S_MAIL_API_TOKENS_SECRET` | `K8S_MAIL_API_TOKENS_FILE` | `tokens` |
| `K8S_POSTMASTER_HOOKS_SECRET` | (no file form) | whatever your hooks read |

The model proxy's keys can be referenced the same way, with
`K8S_PROXY_KEYS_SECRET`; see the proxy section of
[kubernetes-runs.md](kubernetes-runs.md). It follows the naming rules
below and counts as a reference for the distinct-Secret rule.

Setting a reference and the file key it replaces is refused. Install never
creates, reads or prints a referenced Secret; it only names it in the
Deployment. That has consequences:

- **The checks install makes on a file are yours to make.** It cannot see
  the key's owner and mode, that `known_hosts` is non-empty, that the claude
  token outlives the 7-day floor, or that the tokens pass
  `fork-sandbox-mail-api.py check`. Run those before you load the Secret.
- **Changing a referenced Secret does not roll the pod.** It is not in
  `checksum/pm-config`. After a rotation, run
  `kubectl rollout restart deployment/fork-sandbox-postmaster`.
- **A missing Secret or key is a pod that never starts**, not an install
  error. Wait for `kubectl rollout status` after installing.
- **The team token's hash** lives in `fork-sandbox-mail-api-team-hash`, a
  Secret install owns, mounted beside your `tokens`.

Each name must be a DNS-1123 subdomain, must not be one of install's own
Secrets (`fork-sandbox-upstream-key`, `fork-sandbox-postmaster-git`,
`fork-sandbox-postmaster-claude`, `fork-sandbox-mail-api-tokens`,
`fork-sandbox-mail-api-team-token`, `fork-sandbox-mail-api-team-hash`), and
no two references may name the same Secret: each is mounted whole, so a
shared one would hand the hooks the deploy key. Do not label a referenced
Secret `fork-sandbox/context=true`, which would let a run mount it with
`--context-secret`.

Switching an existing install to a reference leaves install's old Secret in
the namespace. Delete it once the new pod is up.

## Claude seats in a cluster postmaster

By default the cluster postmaster refuses to wake a `claude` seat, the
same as a `codex` seat: nothing in the pod holds a claude credential. A
site that wants claude seats installs one long-lived credential that every
claude seat in the pod shares.

The credential is a long-lived OAuth token, minted once and never
refreshed in the cluster. An interactive login's access token lasts only
hours and nothing in the pod refreshes it; and a refresh revokes the
previous access token at once, which would cut off every claude seat in
flight, since each run's claude-proxy loads its token once at pod start. A
long-lived token has neither problem.

To make the credential file:

```
claude setup-token
jq -n --arg t "$TOKEN" --argjson e "<expiry in epoch ms>" \
    '{claudeAiOauth: {accessToken: $t, expiresAt: $e}}' > claude-cluster.json
chmod 600 claude-cluster.json
```

The file must be owned by you and mode 0600 or stricter; install refuses
it otherwise.

Compute the expiry as `$(( $(date -d '+1 year' +%s) * 1000 ))` on Linux or
`$(( $(date -v+1y +%s) * 1000 ))` on macOS, and use the expiry
`claude setup-token` itself reports if it differs from a flat one-year
guess.

Set `K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` in `k8s.env` to that file's
path and run `install --postmaster`. Install refuses a token expiring
within 7 days: a cluster that never refreshes the token cannot afford one
that expires soon, so mint a longer-lived one with `claude setup-token`
instead.

For several accounts, set `K8S_POSTMASTER_CLAUDE_CREDENTIAL_POOL` to
colon-separated absolute laptop paths, `K8S_POSTMASTER_CLAUDE_HEADROOM_HOOK`
to a plugin name, and `K8S_POSTMASTER_HEADROOM_DIR` to the directory holding
its executable `fork-sandbox-headroom-<name>`. The pool and hook must be set
together and cannot be combined with `K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE`.
Install checks every token, ships one Secret with a key for each distinct file
basename, and passes in-pod paths to the hook at each Claude wake. The hook's
own credential, if needed, belongs in the existing `K8S_POSTMASTER_HOOKS_SECRET`.
See [credential-balancing.md](credential-balancing.md) for the contract.

With the single-file form, one token serves every claude seat in the cluster,
and every seat bills that subscription. A claude seat's in-pod review loop still runs pi: `--k8s
--harness claude` requires `--review-harness pi`, unchanged by this
feature.

**Rotation** is the same as any other config change: replace the file at
`K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` and re-run `install --postmaster`.
The credential is part of the `checksum/pm-config` annotation, so a
changed file rolls the pod. For a pool, replace one account's file and rerun
install; its Secret key updates and the pod rolls. A leak of the Claude Secret
exposes every account in the pool, while a leak of one source file exposes
that account. Limit access to the Secret and source files accordingly.

## Operators

`K8S_POSTMASTER_OPERATORS` is a comma-separated list of `@names`, no
spaces; the default is `@operator`. It is rendered into the Deployment as
`FORK_SANDBOX_OPERATORS` on both the postmaster and the mail API container,
so the two agree.

It matters because of the postmaster's rule 1: mail from a sender that is
not a fleet agent clears its thread's needs-operator flag and resets the
thread's spawn budget. On a laptop every such sender carries that
authority. In the cluster, CI jobs and other clients post through the mail
API under names that are not fleet agents, so only the names on this list
carry it. Any other non-fleet sender is delivered and can still wake the
seats it addresses, but leaves the flag and the budget alone.

One more message resets a thread's flag and budget regardless of that list:
a message carrying `X-Upstream-Head` (from `mail reply --upstream-head`) from
any non-fleet sender. The mail API only lets a token with the `upstream` cap
(or an operator) produce it, so the cap is the authorization; see "Upstream
moved" in [docs/agent-mail.md](agent-mail.md).

`mail reply --upstream-state closed|open` takes the same `upstream` cap. A
`closed` from any non-fleet sender stops the postmaster waking seats on that
thread (CI sends it when the pull request closes, since that also tears the
environment down). It clears the thread's needs-operator flag (journaled like
any unflag) but leaves the spawn budget alone. `open`, or a non-fleet
`X-Upstream-Head`, reopens the thread. See "Upstream closed" in
[docs/agent-mail.md](agent-mail.md).

Install refuses when:

- an element is not an `@name` matching `^@[a-z0-9][a-z0-9-]*$`, or is
  empty (`@a,,@b`, a trailing comma);
- a listed name resolves as an agent in the fleet: a fleet seat's own
  replies would otherwise carry operator authority;
- a client entry in the tokens file lists a listed name. The API refuses to
  load such a file, and `check` reports it.

## Capacity

The namespace `ResourceQuota` caps `pods` at 10. Plain install already runs
the always-on `fork-sandbox-proxy` Deployment, and `install --postmaster`
adds the postmaster pod alongside it, so two of those ten are already
spoken for. A panel gets at most eight seat pods running at once. A site
that needs more sets `K8S_QUOTA_PODS` in `k8s.env` and re-runs `install`; see
"The namespace quota" in [kubernetes-runs.md](kubernetes-runs.md). A seat
submitted while the quota is full waits for room (`K8S_QUOTA_WAIT_SECONDS`)
rather than failing.

A seat's container that runs the agent's work takes the namespace
`LimitRange` default (2Gi memory limit) unless `k8s.env` sets
`K8S_AGENT_LIMITS_MEMORY` and its siblings. That is the single `agent`
container of a fixed-skeleton seat and the `leg` container of a composed
(`--run-dir`) seat; a composed seat's `agent` (walker) container keeps the
default. The postmaster pod carries the same `k8s.env`, so the keys apply to
the seats it launches once `install --postmaster` has been re-run; see "The
agent's container resources" in [kubernetes-runs.md](kubernetes-runs.md).

## Storage

Two PVCs back the pod. The data volume, `fork-sandbox-postmaster`, mounts at
`/var/tmp/claude-scratch` and holds the scratch tree, the run directories,
and, under `.pm-home/`, the project clone and `~/.claude` (the durable run
log and other state), which pod init links from `$HOME/src` and
`$HOME/.claude`. The mail volume, `fork-sandbox-postmaster-mail`, mounts at
`/var/tmp/claude-scratch/agent-mail` inside it, holds the mail store, and is
the only volume the mail API container sees.

`ReadWriteOncePod` (or `ReadWriteOnce` as a fallback) together with the
Deployment's `Recreate` strategy keeps exactly one writer at a time on each
volume, which matters because the store's lock is a local `flock` with no
cluster-wide coordination behind it.

Both volumes must be writable at their root by the pod's `fsGroup`. Nothing
uses `subPath`, because kubelet may create a missing subPath directory as
root, which a non-root pod cannot write; pod init makes the directories it
needs on the volume roots instead.

## Network

The postmaster pod ships with no NetworkPolicy. It needs to reach the
Kubernetes API server and the git remote named by `K8S_POSTMASTER_REPO_URL`
and nothing else; a site that wants to seal that egress can add its own
policy. This does not change seat isolation: seat pods still get whatever
NetworkPolicy the platform plugin renders for them, unrelated to the
postmaster pod's own network posture.

`FORK_SANDBOX_K8S_PLATFORM` (default `generic`) names the platform plugin
that submit and render-grant use for that seat-pod policy. It is a laptop
environment variable, not a `k8s.env` key, and the postmaster image ships
no plugin binary beyond `generic` and sets no such variable in the
Deployment. So a seat submitted from inside the pod always resolves the
`generic` plugin, even when a site's laptop runs a different one.
`install --postmaster` warns on stderr when it is run with
`FORK_SANDBOX_K8S_PLATFORM` set to anything but `generic`, naming the
mismatch, but it does not refuse: some sites may intend the pod to use
generic even when the laptop runs something else.

## Security posture

The postmaster's ServiceAccount is bound to a Role that can read every
Secret in the namespace (`get`/`list`/`watch` on `secrets`, alongside
`configmaps`, `services`, `jobs`, `pods`, `pods/exec`, `pods/log`, and
`networkpolicies`, plus read-only `list` on `events` and `get` on
`resourcequotas` for submit's quota wait). That is not a new exposure introduced by this Role:
anything that can create a Job can already mount any Secret in its own
namespace by naming it in that Job's spec, regardless of what its own Role
lists. What the Role does add is the ability to *list and delete* Secrets
by label, which the postmaster needs for the same cleanup path an ordinary
cluster run uses (deleting `pod,service,secret,configmap,networkpolicy`
by label when a run finishes or is removed).

The practical consequence: `kubectl exec` into the postmaster pod reaches
every credential the ServiceAccount can read, not just the mail store.
Keep that to cluster admins.

The team Role `fork-sandbox-mail-team` is narrower than that: a teammate bound
to it can port-forward to the pods of the namespace and read the one team-token
Secret, and nothing else. That token is an operator token for the mail API, so
treat whoever can read it as an operator of the mail store; RBAC cannot make
it per-person.

Hooks run in the postmaster pod, in the same trust tier as handlers,
beside the credentials the postmaster already holds.

See `manifests/k8s/40-postmaster.yaml` and
`manifests/k8s/10-rbac.yaml` for the exact rules.
