# Account profiles: which logins a run may use

One machine is often used for more than one billing owner — an employer's
accounts and the operator's own, say. Without profiles, fork-sandbox has
one machine-wide Claude credential chain (`CLAUDE_CREDENTIALS`, or
`CLAUDE_CREDENTIAL_POOL` + `CLAUDE_HEADROOM_HOOK`, see
[credential-balancing.md](credential-balancing.md)) and one codex login
(`${CODEX_HOME:-~/.codex}`), so a run launched for one owner without an
explicit `--claude-credentials` is billed to whatever the machine default
is.

An **account profile** is a named bundle of the logins a run may use: a
Claude credential pool and, optionally, a codex home. The profile for a run
comes from **who launched it**, not from the repo — some repos are worked
on for more than one owner and are billed to whoever is doing the work.
Optional per-repo rules can then **refuse** a launch whose profile is wrong
for that repo; they never pick one.

Profiles are resolved on the host, at launch, once per run — never inside a
Kubernetes pod (see "Pods" below).

## Config (`~/.config/fork-sandbox/profiles.env`)

Read line by line, never sourced; one `KEY=VALUE` per line, blank lines and
`#` comments skipped. Every rule below is a hard error at launch, before
anything is created.

| Key | Meaning |
|---|---|
| `PROFILE_<name>_CLAUDE_POOL` | Required for each profile. Colon-separated absolute credential-file paths, with the same rules as `CLAUDE_CREDENTIAL_POOL` (absolute, no whitespace, no empty entry). |
| `PROFILE_<name>_CODEX_HOME` | Optional. An absolute directory holding the codex `auth.json` (and `models_cache.json`) — what `CODEX_HOME` means to codex. A profile without one has no codex. |
| `DEFAULT_PROFILE` | Optional. The profile for a launch from a plain shell, cron or CI. Must name a defined profile. |
| `REPO_RULE` | Optional, repeatable: `<glob> <name>`. See "Repo guard rules". |

`<name>` is lowercase alphanumerics and hyphens, starting with an
alphanumeric (no underscore, so the key splits unambiguously). Unknown keys,
a key set twice, and a line that is not `KEY=VALUE` are refused.

A credential path may appear in only one profile — membership decides the
billing owner and must never be ambiguous. Paths are compared after
canonicalization, so two spellings of one file count as the same file.

`CLAUDE_HEADROOM_HOOK` stays in `claude.env` and balances any profile pool
with more than one entry, under the contract in
[credential-balancing.md](credential-balancing.md#the-hook-contract); the
hook is handed only the resolved profile's own pool. A profile pool of one
entry needs no hook. A multi-entry pool with no hook configured is refused.

With `profiles.env` present, `CLAUDE_CREDENTIALS` or `CLAUDE_CREDENTIAL_POOL`
in `claude.env` is a hard error: two sources for one fact. With no
`profiles.env`, nothing on this page applies and every path behaves exactly
as it did before profiles existed.

## Resolution order

For a run with any claude or codex leg, or an explicit
`--claude-credentials`:

1. **`--claude-credentials <path>`** → the profile containing that path. A
   path in no profile is refused. This is how a plain shell picks a profile;
   there is no separate flag.
2. **Launched from inside a Claude Code session** → the profile whose pool
   contains that session's own credential file,
   `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`. A session is
   detected from the environment Claude Code gives its tool processes:
   `CLAUDECODE=1` or a non-empty `CLAUDE_CODE_SESSION_ID`. If that file is in
   no profile the launch is **refused**, naming the file — not sent to
   `DEFAULT_PROFILE`: an operator who configured profiles has not placed
   this login, and guessing is the failure profiles exist to stop.
3. **Otherwise** (plain shell, cron, CI) → `DEFAULT_PROFILE`. If unset, the
   launch is refused with how to choose: pin `--claude-credentials` or set
   `DEFAULT_PROFILE`.

Within the resolved profile, an explicit `--claude-credentials` is used as
given. Otherwise the profile's pool is balanced by the hook (or its single
entry used). Hook exit 2 and a broken hook contract are hard errors, exactly
as for the machine-wide pool; a hook that crashes (any other nonzero exit)
warns and falls back to the profile's **first** entry — never outside the
profile.

A run with no claude or codex leg (a pure `pi` run) and no
`--claude-credentials` resolves no profile at all.

## Codex follows the profile

Every codex leg — code, review, maintain, fix, any composed pipeline seat,
local or `--k8s` — reads its `auth.json` and model cache from the resolved
profile's codex home instead of `${CODEX_HOME:-~/.codex}`: the launcher sets
`CODEX_HOME` to it for the rest of the launch. A run that would start any
codex leg under a profile with no codex home is refused at launch, before
anything is created, naming the profile.

## Repo guard rules

```
REPO_RULE=<glob> <profile>
```

The `origin` remote of the repo being forked is normalized to
`host/owner/repo` — scheme, `user@`, `:port` and a trailing `.git` or `/`
dropped, the scp-style `host:path` colon turned into a slash, the host
lowercased — so `git@example.com:acme/widget.git` and
`https://example.com/acme/widget` both become `example.com/acme/widget`.
The rules are tried in file order and the **first** whose glob matches
decides: if it names a profile other than the resolved one, the launch is
refused, naming the repo, the rule, the required profile and the resolved
one. No matching rule is no constraint; a repo with no `origin` matches
nothing. Rules never choose a profile.

## Both entry points

Resolution lives in one lib function, `fs_resolve_account_profile` in
`scripts/fork-sandbox-lib.sh`, called once per run: by `fork-sandbox.sh`
(local runs and `--k8s`, which forwards the chosen credential and profile to
`fork-sandbox-k8s.sh run`, so the hook is asked once) and by
`fork-sandbox-k8s.sh run`/`submit` when invoked directly. `configure`'s
claude discoverer reports the credential a launch from the same place would
resolve.

## Recording

`run.env`, `summary.json` and the run-log row (`sandbox-run-log.py`) carry,
beside the existing `claude_credentials_source` / `claude_credentials_via`:

- `account_profile` — the profile name (empty in `run.env`, `null` in JSON,
  when none applies).
- `account_profile_via` — `flag` | `session` | `default` | `none`. `none`
  means no `profiles.env` (or a pod), or a run that used no profile login.

Under a profile, `claude_credentials_via` is `flag`, `balance` (the hook
chose from the profile's pool), or `profile` (the profile's single entry,
or its first after a crashed hook). Names and paths only, never token
material: `sandbox-run-log.py stats --by account_profile` splits a fleet by
owner.

## Pods

Nothing inside a Kubernetes pod consults profiles: when
`KUBERNETES_SERVICE_HOST` is set (kubelet sets it in every container),
`profiles.env` is never read and no session detection runs. The cluster
postmaster's own pool (`K8S_POSTMASTER_*` in `k8s.env`, the in-pod
`CLAUDE_CREDENTIAL_POOL`) and every pod-side claude seat keep exactly the
chain described in [credential-balancing.md](credential-balancing.md).

## An invented example

```
# ~/.config/fork-sandbox/profiles.env
PROFILE_alpha_CLAUDE_POOL=/etc/example-fleet/alpha-1.json:/etc/example-fleet/alpha-2.json
PROFILE_alpha_CODEX_HOME=/etc/example-fleet/codex-alpha
PROFILE_beta_CLAUDE_POOL=/home/example/.claude/.credentials.json
DEFAULT_PROFILE=beta
REPO_RULE=example.com/acme/* alpha
```

With `CLAUDE_HEADROOM_HOOK=example` in `claude.env`:

- From a Claude Code session logged in as `/home/example/.claude/.credentials.json`,
  a run resolves `beta` (via `session`). Forking a repo whose origin is
  `git@example.com:acme/widget.git` is refused (the rule requires `alpha`);
  a codex leg is refused (`beta` has no codex home).
- `--claude-credentials /etc/example-fleet/alpha-2.json` resolves `alpha`
  (via `flag`) and uses that file as given; its codex legs read
  `/etc/example-fleet/codex-alpha/auth.json`.
- From cron, a run resolves `beta` (via `default`).
