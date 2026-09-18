# Balancing Claude credentials across a pool

A single pinned `CLAUDE_CREDENTIALS` (see [docs/configure.md](configure.md))
works until the account behind it runs low on quota mid-fleet. This document
covers the alternative: an operator-configured pool of credential files, with
an operator-installed hook deciding which one has headroom right now. This
repo ships the mechanism — the pool/hook plumbing and its contract — never
the policy. Which account is healthy is answered entirely by the hook,
installed outside this repo, so no real quota tool or account name is ever
named here (see the repo's own `CLAUDE.md`).

## Config (`~/.config/fork-sandbox/claude.env`)

| Key | Meaning |
|---|---|
| `CLAUDE_CREDENTIAL_POOL` | Colon-separated list of absolute credential file paths — the candidates. Every entry must be absolute, contain no whitespace, and pass the same unsafe-character check every credential path does; a colon in a path is therefore unsupported, since colon is the list separator. |
| `CLAUDE_HEADROOM_HOOK` | A plugin **name**, not a path — see "Resolving the hook" below. Must match `^[a-z0-9][a-z0-9-]*$`. |

Both keys are set together, or neither: a pool with no hook has no way to
pick a candidate, and a hook with no pool has nothing to judge. Setting
`CLAUDE_CREDENTIALS` (the single pin) alongside `CLAUDE_CREDENTIAL_POOL` is
also refused — two sources for one fact is a setup mistake, not something
this repo resolves silently by picking a winner. Every one of these is a
hard error at launch, before anything is created.

## Precedence

For any run with at least one `--harness claude` leg:

```
--claude-credentials  >  CLAUDE_CREDENTIALS  >  the pool/hook balancer  >  today's default
```

Today's default is `$HOME/.claude/.credentials.json`, falling back to the
login Keychain on macOS. The balancer never runs for a run with no claude
leg — a pure-`pi` run never touches the hook.

The credential the balancer chooses flows through the exact same resolution
as an explicit `--claude-credentials` or `CLAUDE_CREDENTIALS`: resolved to an
absolute path, checked for unsafe characters, and required to exist. A
balanced choice naming a missing file is a hard error, exactly like a typo in
`--claude-credentials` — the pool is operator-authored, so a bad entry is
this run's problem to raise, not to swallow.

This is one precedence chain, one implementation
(`fs_balance_claude_credential` in `scripts/fork-sandbox-lib.sh`), shared by
both places a Claude credential gets read: `fork-sandbox.sh`'s local path,
and `fork-sandbox-k8s.sh`'s direct entry point. `fork-sandbox.sh --k8s`
resolves the chain itself and forwards the result into
`fork-sandbox-k8s.sh run`'s own `--claude-credentials`, so the hook is asked
at most once per run rather than once per script.

## Resolving the hook

`CLAUDE_HEADROOM_HOOK=<name>` becomes the executable `fork-sandbox-headroom-
<name>`, resolved on `PATH` first (so a checkout works before `install.sh`
has run) and then beside the calling script. This is the identical rule
`fork-sandbox-k8s.sh` uses to resolve a `fork-sandbox-k8s-platform-<name>`
plugin — one resolution rule for the whole project, kept identical on
purpose.

A name is required instead of a path for the same reason a `configure`
discoverer cannot name a path (see [docs/configure.md](configure.md), "The
allowlist"): config a blanket-approved script trusts unconditionally must
not be able to point it at an arbitrary executable outside the plugin
convention.

An unresolvable name — nothing on `PATH`, nothing beside the script — is a
hard error naming the plugin name it looked for and where it looked.

## The hook contract

```
fork-sandbox-headroom-<name> <candidate-path>...
```

- The pool entries are passed as argv, in the order `CLAUDE_CREDENTIAL_POOL`
  lists them.
- No stdin, no secrets — argv carries paths only.
- No timeout is imposed. A hook that hangs blocks the launch; that is the
  operator's own hook to fix, not something this repo works around.

Exit behavior, in full:

| Exit | Stdout | Meaning |
|---|---|---|
| `0` | Exactly one line, byte-equal to one of the argv candidates | That candidate is the choice. |
| `0` | Anything else — empty, multiple lines, a path not in the candidate list | A broken contract. **Hard error**, naming the hook and quoting what it printed. Never a silent fallback. |
| `2` | (ignored) | The hook's own considered answer: no candidate is routable right now (e.g. every account looks unhealthy). **Hard error**, telling the operator to pin `--claude-credentials` to override. |
| anything else nonzero | (ignored) | Hook failure. A **warning** names the hook and the exit code, and the launch falls through to today's default credential chain — a crashed plugin must not brick every launch on the machine. |

The health-gate policy — what "routable" or "healthy" means — lives
entirely in the hook. This document defines only the contract above.

## Recording (`run.env`, `summary.json`, and the run log)

A run with a claude leg gets two extra keys, wherever that run's outcome is
recorded — `run.env`, `summary.json`, and the JSONL row
`sandbox-run-log.py` appends:

- `claude_credentials_source` — the resolved path, or the literal `default`.
- `claude_credentials_via` — `flag` | `claude-env` | `balance` | `default`,
  naming which of the four precedence tiers actually decided it.

Token material is never recorded — paths only. See
`scripts/sandbox-run-log.py`'s own header for how to group stats on these
fields (`stats --by claude_credentials_via`, for instance, answers how often
a fleet actually rode the balancer versus a pin versus the default).

## A neutral example hook

Invented paths, an invented headroom source — nothing here names a real
quota tool. This hook favors whichever candidate its own (imaginary) headroom
file lists first as healthy, and answers "no routable candidate" only when
none of them are:

```bash
#!/usr/bin/env bash
# fork-sandbox-headroom-example -- picks the first candidate an operator's
# own (invented) headroom source still lists as healthy.
set -euo pipefail

healthy_accounts="$(cat /etc/example-fleet/healthy-accounts.txt 2>/dev/null || true)"

for candidate in "$@"; do
    account="$(basename "$candidate" .json)"
    if grep -qxF "$account" <<< "$healthy_accounts"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

echo "example-headroom: no candidate in $*" \
    "is in healthy-accounts.txt" >&2
exit 2
```

Installed as `fork-sandbox-headroom-example` on `PATH`, with:

```
CLAUDE_CREDENTIAL_POOL=/etc/example-fleet/team-a.json:/etc/example-fleet/team-b.json
CLAUDE_HEADROOM_HOOK=example
```

## Out of scope

- Shipping any real headroom hook in this repo — the operator's own hook
  lives outside it; this repo ships only the contract, the mechanism, and
  test fakes.
- The local (non-`--k8s`) path's `--dry-run` exiting before its credential
  check runs — a known, separately tracked gap, unrelated to the balancer.
- Any change to token stripping, retry logic, or the `pi`/`codex` credential
  paths, none of which this document's mechanism touches.
