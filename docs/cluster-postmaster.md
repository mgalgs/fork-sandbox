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
  below), not just the mail store.

## Setup

Do these in order.

1. **Build and push the base image**, as for any other cluster run (see
   [docs/kubernetes-runs.md](kubernetes-runs.md)), then build and push the
   postmaster image, a thin layer over it that adds `kubectl` and `ssh`:

   ```
   scripts/build-sandbox-image.sh --postmaster --base "$K8S_IMAGE"
   ```

   Push the tag it prints to the registry the cluster pulls from.

2. **Create a read-only deploy key and a known_hosts file** for the project
   repo the postmaster clones. The key must be read-only on the remote (the
   pod never pushes); `known_hosts` must be pre-populated, since the pod
   never trusts a host on first use.

3. **Add the postmaster keys to `k8s.env`**, alongside the keys an ordinary
   cluster run already reads:

   | key | required | meaning |
   |---|---|---|
   | `K8S_POSTMASTER_IMAGE` | yes | the image ref step 1 built and you pushed |
   | `K8S_POSTMASTER_REPO_URL` | yes | ssh URL of the project repo: `ssh://[user@]host[:port]/path` or the scp-like `user@host:path` form. Anything else (`https://`, a bare hostname) is refused. |
   | `K8S_POSTMASTER_PROJECT` | no | directory name under `$HOME/src` in the pod; defaults to the URL's last path component with a trailing `.git` stripped. Must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`, so it can never be `.` or `..`. |
   | `K8S_POSTMASTER_GIT_KEY_FILE` | yes | laptop path to the deploy private key from step 2 |
   | `K8S_POSTMASTER_KNOWN_HOSTS_FILE` | yes | laptop path to the known_hosts file from step 2 |
   | `K8S_POSTMASTER_STORAGE_CLASS` | no | PVC `storageClassName`; empty (the default) omits the field, so the cluster's default StorageClass applies |
   | `K8S_POSTMASTER_STORAGE` | no | PVC requested size; default `20Gi`; must match `^[0-9]+(Mi\|Gi\|Ti)$` |
   | `K8S_POSTMASTER_ACCESS_MODE` | no | `ReadWriteOncePod` (default) or `ReadWriteOnce`, for a StorageClass or CSI driver that does not support RWOP yet; anything else is refused |
   | `K8S_POSTMASTER_OPERATORS` | no | comma-separated `@names` that carry rule-1 authority; default `@operator`. See "Operators". |
   | `K8S_POSTMASTER_HOOKS_SECRET` | no | the name of a Secret you create in the namespace, to hand your hooks credentials. Install never creates or reads it, only references it. Must be a DNS-1123 subdomain name. See "Hooks". |
   | `K8S_MAIL_API_TOKENS_FILE` | no | laptop path to the mail API tokens file; when set, the mail API is deployed. See "The mail API". |
   | `K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` | no | laptop path to a claude credentials JSON; when set, claude seats are accepted in the cluster. See "Claude seats in a cluster postmaster". |

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
   ServiceAccount, Role and RoleBinding, a PVC, a Secret holding the deploy
   key and known_hosts, one or more ConfigMaps, and the Deployment itself
   (plus the mail API's Secret and Service when it is enabled).
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
- **Rotating the git deploy key** is the same: replace the file named by
  `K8S_POSTMASTER_GIT_KEY_FILE` (or `K8S_POSTMASTER_KNOWN_HOSTS_FILE`) and
  run `install --postmaster` again. The Secret is part of the checksum, so
  the pod rolls and picks the new key up at init.
- **A new fork-sandbox version** needs a new postmaster image and a new
  `K8S_POSTMASTER_IMAGE` in `k8s.env`, then `install --postmaster` again.
- **New commits on the project repo** reach the pod only at pod start: the
  pod init clones once (or, on a restart, fetches and fast-forwards the
  existing clone to `origin`'s tip) and the postmaster itself never fetches
  again afterward. A running pod does not pick up new commits on its own;
  restart it (a rollout, or deleting the pod) to pull them in.
- **In-flight seats survive a rollout.** A restarted postmaster adopts
  still-running Jobs instead of re-spawning them, so a rollout does not
  lose a seat's work in progress.

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

**Rotation.** Edit the tokens file and re-run `install --postmaster`. The
server reads its tokens once at startup; the Secret is part of the
`checksum/pm-config` annotation, so a changed file rolls the pod.

**From a laptop**, through a port-forward:

```
kubectl port-forward svc/fork-sandbox-mail-api 8765:80
```

then set `K8S_MAIL_API_URL=http://127.0.0.1:8765` and
`K8S_MAIL_API_TOKEN_FILE=<file holding the raw token>` in `k8s.env` and use
`fork-sandbox mail --remote <verb> ...` (and `fork-sandbox postmaster
--remote <verb> ...`).

**In-cluster callers** use `http://fork-sandbox-mail-api.<namespace>.svc`.
Seat pods cannot reach it: the agent NetworkPolicy pins their egress.

**Security.** The API container holds no ServiceAccount token: the pod
turns off the automatic mount and projects the token into the postmaster
container only, so the network-facing container cannot read the
namespace's Secrets. It has its own `$HOME` and `/tmp`, never the
postmaster's, since the postmaster reads its kubeconfig, gitconfig and
deploy key from `$HOME`. It also mounts only the mail root
(`/var/tmp/claude-scratch/agent-mail`) of the scratch volume, not the whole
scratch root: the postmaster's wake directories under `forks/` hold the
launch records it executes, and stay out of the API container's reach. The
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
ConfigMap cannot hold). It is mounted at
`/etc/fork-sandbox/hooks` in the postmaster container only, with
`FORK_SANDBOX_HOOKS_DIR` set to that path. Like any config change, editing
a hook needs `install --postmaster` run again.

A hook that needs a credential of its own gets it from a Secret the site
creates. Set `K8S_POSTMASTER_HOOKS_SECRET=<name>` in `k8s.env`. Install
never creates or reads that Secret; it only references it. It is mounted
read-only at `/etc/fork-sandbox/hook-secret` in the postmaster container
only, and `FS_HOOK_SECRET_DIR` is set to that path in every hook's
environment. The value must be a DNS-1123 subdomain name. Install also
refuses its own Secret names, `fork-sandbox-upstream-key`,
`fork-sandbox-postmaster-git` and `fork-sandbox-mail-api-tokens`, so a typo
cannot hand a hook the provider key.

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

One token serves every claude seat in the cluster, and every seat bills
that subscription. A claude seat's in-pod review loop still runs pi: `--k8s
--harness claude` requires `--review-harness pi`, unchanged by this
feature.

**Rotation** is the same as any other config change: replace the file at
`K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE` and re-run `install --postmaster`.
The credential is part of the `checksum/pm-config` annotation, so a
changed file rolls the pod.

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
that needs more raises the quota where `00-namespace.yaml` is rendered.

## Storage

One PVC backs the whole pod. `ReadWriteOncePod` (or `ReadWriteOnce` as a
fallback) together with the Deployment's `Recreate` strategy keeps exactly
one writer at a time, which matters because the store's lock is a local
`flock` with no cluster-wide coordination behind it. The PVC holds the
scratch tree, the run directories, the project clone under `$HOME/src`,
and the durable run log and other state under `$HOME/.claude`.

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
`networkpolicies`). That is not a new exposure introduced by this Role:
anything that can create a Job can already mount any Secret in its own
namespace by naming it in that Job's spec, regardless of what its own Role
lists. What the Role does add is the ability to *list and delete* Secrets
by label, which the postmaster needs for the same cleanup path an ordinary
cluster run uses (deleting `pod,service,secret,configmap,networkpolicy`
by label when a run finishes or is removed).

The practical consequence: `kubectl exec` into the postmaster pod reaches
every credential the ServiceAccount can read, not just the mail store.
Keep that to cluster admins.

Hooks run in the postmaster pod, in the same trust tier as handlers,
beside the credentials the postmaster already holds.

See `manifests/k8s/40-postmaster.yaml` and
`manifests/k8s/10-rbac.yaml` for the exact rules.
