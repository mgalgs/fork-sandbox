# `fork-sandbox.sh configure`

`fork-sandbox.sh` needs a little per-machine config before it can run
anything:

| file in `~/.config/fork-sandbox/` | holds |
|---|---|
| `pi.env` | `OPENROUTER_API_KEY` — a real secret, mode 0600 |
| `model.env` | `MODEL_ENDPOINT`, `MODEL_ID`, `MODEL_CTX` — a local model endpoint |
| `k8s.env` | `K8S_CONTEXT`, `K8S_NAMESPACE`, `K8S_IMAGE`, `K8S_PROXY_UPSTREAM`, `K8S_DENIED_PROBE` |
| `coder-mode.env` | `CODER_MODE_HARNESS`, `CODER_MODE_MODEL`, `CODER_MODE_REVIEW_HARNESS`, `CODER_MODE_REVIEW_MODEL`, `CODER_MODE_REVIEW_LOOP` — the `sandbox-coder-mode` skill's launch defaults, read by the orchestrating session, not by any script; `configure` does not write it |

Assembling that by hand means copying key names out of docs and typing a
`chmod 600`. `configure` does it instead: it discovers what is already on
this machine — an `OPENROUTER_API_KEY` in your environment, a local model
endpoint, a kubectl context — shows you what it found, and writes the
pieces you pick into the files above, **except `coder-mode.env`**, which
has no discoverer and is never a `configure` target — see the row above.

```
fork-sandbox.sh configure [--remove] [--all] [--dry-run]
```

## The picker

Running `configure` with no flags runs every installed discoverer (see
below), then shows what they found: a label, where it came from, and a
safe rendering of the value — a secret is always shown masked to its last
4 characters, e.g. `…a91f`. Pick with `fzf` when it is on your `PATH`
(`TAB` to select, `ENTER` to confirm); otherwise a numbered plain-text list
takes a line like `1 3 4`, `all`, or nothing to cancel.

A candidate that already has a value in your config is marked
`(replaces existing)`. Picking it merges into the file: the existing
`KEY=value` line is replaced in place, every other line — other keys, your
own comments — is left exactly as it was.

Some candidates are informational only — nothing is written for them, they
just tell you something is already working. `fork-sandbox-discover-claude`
is the one that ships with this repo: it reports whether `claude` has a
credential ready, since `fork-sandbox.sh` finds that credential on its own
at run time and there is nothing to install.

`configure` needs a terminal to run its picker. Without one, and without
`--all`, it refuses outright rather than guess:

```
$ fork-sandbox.sh configure < /dev/null
Error: configure is interactive and needs a terminal to pick candidates.
Pass --all to take every candidate non-interactively -- the mode a script
driving this should use.
```

## `--remove`

```
fork-sandbox.sh configure --remove
```

Same picker, run against what is *currently set* instead of what a
discoverer found: every allowlisted key that has a value in your config
files, shown the same way (a secret masked, a plain value in full). This
never includes `coder-mode.env`'s keys — they are not on the allowlist, so
`--remove` cannot offer them; edit that file by hand to change or clear
them. Pick what to take back out. Since this deletes rather than adds, an
interactive run asks for one more `y/N` confirmation before it writes
anything.
Removing the last key from a file leaves the (possibly empty) file in
place — deleting a file you may have hand-commented would be a surprise,
not a convenience.

## `--all` and `--dry-run`

`--all` skips the picker and takes every candidate (add) or every
currently-set key (remove) — the flag a script uses to drive `configure`
without a terminal.

`--dry-run` stops one step short of writing: it prints what *would* be
written or removed — the target and the same masked rendering the picker
showed — and touches no file. A secret's real value is never printed by
`--dry-run` any more than it is printed anywhere else.

## Adding a discoverer

A discoverer is any executable named `fork-sandbox-discover-<name>`,
resolved on `PATH` first and then beside `fork-sandbox.sh` — the identical
rule `fork-sandbox-k8s.sh` uses to resolve
`fork-sandbox-k8s-platform-<name>` (see [k8s-platform.md](k8s-platform.md)),
kept identical on purpose: one resolution rule for the whole project, not
one per plugin family. `configure` runs every discoverer it can find; there
is nowhere to register one beyond dropping it on `PATH`.

It implements two verbs:

```
fork-sandbox-discover-<name> discover
fork-sandbox-discover-<name> value <id>
```

**`discover`** prints zero or more candidate lines to stdout,
**TAB-separated, metadata only, never a secret value**:

```
id<TAB>target<TAB>label<TAB>source<TAB>display
```

| Field | Meaning |
|---|---|
| `id` | Stable, matches `^[a-z0-9][a-z0-9_-]*$`, unique within this discoverer. `configure` namespaces it as `<name>/<id>` for display; `value` is always called with the plain id. |
| `target` | `<file>:<KEY>`, from the allowlist below. The literal `-` means informational only: shown in the listing, never selectable, no value ever read for it. |
| `label` | A short human name, e.g. `OpenRouter key`. |
| `source` | Where it was found, e.g. `$OPENROUTER_API_KEY` or `~/.config/openrouter/key`. |
| `display` | The safe rendering `configure` shows. **For a secret this must already be masked** (last 4 characters, e.g. `…a91f`) — for a non-secret it is the value in full. `configure` shows this and never reads the real value unless the candidate is selected. |

**`value <id>`** prints the raw value on stdout and nothing else. `configure`
calls this **only** for an id the user actually selected — never while the
picker is still deciding, and never for an informational candidate.

That split is the whole point: a secret never enters the picker, never
reaches `fzf`'s stdin, and is read only once, for exactly the candidates
that were chosen.

### A complete example

A discoverer that finds a token in an environment variable:

```bash
#!/usr/bin/env bash
set -euo pipefail

mask() { local v="$1"; if (( ${#v} <= 4 )); then printf '…%s' "$v"; else printf '…%s' "${v: -4}"; fi; }

case "${1-}" in
    discover)
        if [[ -n "${MY_THING_TOKEN:-}" ]]; then
            printf 'env\tpi.env:OPENROUTER_API_KEY\tMy thing token\t$MY_THING_TOKEN\t%s\n' \
                "$(mask "$MY_THING_TOKEN")"
        fi
        ;;
    value)
        [[ "$2" == env ]] && printf '%s' "${MY_THING_TOKEN:-}"
        ;;
    *)
        echo "Usage: $(basename "$0") discover|value <id>" >&2
        exit 1
        ;;
esac
```

Name it `fork-sandbox-discover-mything`, put it on `PATH`, and
`fork-sandbox.sh configure` finds it.

### The allowlist, and why a discoverer cannot just name a path

`fork-sandbox.sh` is blanket-approved in most permission setups (see
[permissions.md](permissions.md)), so once launched it runs unsupervised. A
discoverer is an executable found on `PATH` — a plugin supplied by whoever
set up this machine, not code this repo has reviewed. If a discoverer could
name an arbitrary file to write, running `configure` would be equivalent to
running whatever that plugin says, which defeats the entire point of a
narrow blanket approval.

So a discoverer never supplies a path. It supplies a `target` string, which
`configure` looks up in a fixed table compiled into `fork-sandbox.sh`:

| target | secret |
|---|---|
| `pi.env:OPENROUTER_API_KEY` | **yes** |
| `model.env:MODEL_ENDPOINT` | no |
| `model.env:MODEL_ID` | no |
| `model.env:MODEL_CTX` | no |
| `k8s.env:K8S_CONTEXT` | no |
| `k8s.env:K8S_NAMESPACE` | no |
| `k8s.env:K8S_IMAGE` | no |
| `k8s.env:K8S_PROXY_UPSTREAM` | no |
| `k8s.env:K8S_DENIED_PROBE` | no |

A target that is not a key in this table is refused by name — loudly, with
the discoverer and the bad target named in the error — and the candidate
that named it is dropped without being written anywhere. There is no flag
and no code path that writes outside `~/.config/fork-sandbox/`.

Adding a new target means editing this table, which is a reviewed change
to a script the user already trusts. It is not something a discoverer can
do by itself, ever — that asymmetry is the security boundary, not an
oversight to work around.

Before a value is written at all, `configure` also checks it: non-empty
after trimming, no newline or carriage return (one would inject a second
`NAME=VALUE` line — a real escalation when the file is `k8s.env`, since
`K8S_CONTEXT` picks which cluster a run talks to), the same character
check `fork-sandbox-k8s.sh` applies everywhere it builds a command, and a
`http(s)://` shape for the two endpoint targets.
