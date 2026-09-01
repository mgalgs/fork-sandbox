# Working in this repository

## This repo is public and general-purpose

Nothing environment-specific goes in the repo — not in code, docs, tests,
fixtures, or commit messages. That means: no private hostnames or internal
DNS names, no real internal IP addresses, no cluster or kubectl context
names, no employer, product, or internal project names, and no personal
filesystem paths beyond generic `$HOME`-style examples. Commit messages
are published too; write them like the code.

Machine- and site-specific values live OUTSIDE the repo, in
`~/.config/fork-sandbox/*.env`, and are read at run time. When behavior
must vary by environment, add a hook, plugin, or env key — never a
constant:

- **configure discoverers** — any executable named
  `fork-sandbox-discover-<name>` on PATH (see docs/configure.md)
- **Kubernetes platform plugins** — `fork-sandbox-k8s-platform-<name>`
  (see docs/k8s-platform.md)
- **prompt overlays** — `~/.config/fork-sandbox/prompts/`
- **lkml personas** — a persona `.md` file, pinned to its own harness/model
- **per-machine launch defaults** — `~/.config/fork-sandbox/coder-mode.env`,
  read by the orchestrating session, never by scripts

Test fixtures use invented names and documentation/private example
addresses (RFC 5737 ranges, generic RFC 1918 constants). The k8s test
suite carries a repo-wide leak-guard check ("no private-hostname shape in
the repo"); keep it green, and when a new class of leak becomes possible,
extend the guard in the same commit that makes it possible.

## Conventions

- bash, `set -euo pipefail` unless a script documents why not; run
  `shellcheck` on every changed `.sh` and fix what it reports.
- Python scripts pass `python-check.py <file>`.
- Every behavior change lands WITH its tests in the same commit.
- Scripts are self-documenting: usage and rationale live in the header
  comment, and `--help` prints it.
