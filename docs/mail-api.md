# The mail API

The mail store and the postmaster's state live on the postmaster's host. A
caller with no shell there -- a CI job kicking off a review thread, an
operator interjecting from a laptop, a dashboard doing a read-only export --
still needs to reach them. `kubectl exec` into the postmaster's pod would
work, but exec carries the pod's ServiceAccount powers, which reach every
Secret in the namespace. The mail API is a small HTTP server instead: it
runs only the existing mail and postmaster verbs, from a fixed allowlist,
and authenticates each request with a bearer token bound to the identities
it may use.

It is plain HTTP. It is meant for in-cluster traffic and
`kubectl port-forward`, not for the open internet. A site that wants TLS
fronts it itself.

The server is `scripts/fork-sandbox-mail-api.py`, run as `fork-sandbox
mail-api serve` or `fork-sandbox mail-api mint`. The client is
`scripts/fork-sandbox-mail-remote.py`, which `fork-sandbox mail --remote
<verb> ...` and `fork-sandbox postmaster --remote <verb> ...` run
underneath, so a laptop and a CI job invoke the identical command line.

## Who may post as which name

The postmaster's rule 1 clears a thread's needs-operator flag and resets its
spawn budget when a message arrives whose From is not a fleet agent. The
API's part is to decide which names a caller may put in `--from`; what the
mail then does to a thread is the postmaster's rule.

The operator list is `$FORK_SANDBOX_OPERATORS`: comma-separated `@name`s,
no spaces, no empty elements; unset or empty means `@operator`. The server
and the postmaster read the same variable, so there is one source. Only an
operator token may post as a name on the list. The loader refuses to start
if a client entry's identities include a listed name, `mint` refuses to
mint one, and the allowlist refuses `--from <listed name>` from anything
but an operator token, unconditionally.

What a client's mail can do depends on which postmaster reads it:

- **Cluster postmaster** (`deliver --cluster`). Only names on the operator
  list carry rule-1 authority. Mail from any other non-fleet sender, a
  client identity such as `@ci-kickoff` included, is delivered and routed
  like fleet mail, but it leaves a thread's flag and spawn budget alone. A
  client `reply` into a flagged thread returns 200 and the flag stays.
- **Laptop postmaster** (`deliver` without `--cluster`). Rule 1 still gives
  every non-fleet sender authority, client identities included. Do not
  issue client tokens against a laptop store.

Known limit. `reply --hops` lets a client set the hop budget of its own
message, so treat a client token as able to keep waking agents in any
thread it can reply into.

## The tokens file

One entry per line, whitespace-separated, `#` comments and blank lines
ignored:

    <role> <sha256-hex-of-token> <label> <identities|-> <caps|->

    operator 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  laptop      -            -
    client   2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae ci-kickoff  @ci-kickoff  read,grant

The file holds the SHA-256 hash of each token, never the token itself. The
server hashes the presented bearer token and compares it against every
entry with `hmac.compare_digest`.

- `role` is `operator` or `client`.
- An operator entry's `identities` and `caps` fields must both be `-`. An
  operator token may run any allowlisted verb with any `--from` or thread
  argument.
- A client entry's `identities` field is a comma-separated list of the
  `@name`s it may use as `--from` (matched against mail's address
  pattern), or `-` for none. Its `caps` field is a subset of `read`,
  `grant` and `seen`, or `-`.

`serve` reads this file once, at startup; rotating a token means rewriting
the file and restarting the server. It refuses to start (exit 2, one line
naming the offending label, never a hash) when:

- any line is malformed, or has an unknown role or cap, or a malformed
  identity;
- two entries share a hash or a label;
- a client entry's identities include a name on the operator list;
- an operator entry has anything but `-` for identities or caps;
- the table has no entries at all.

## `mint`

    fork-sandbox mail-api mint --role operator|client --label <label>
                           [--as @a[,@b]] [--caps read,grant,seen]

`mint` generates a token with a cryptographically random 32-byte value and
prints it alone on the first line of stdout; the second line is the
tokens-file line to append (with the token's hash, not the token). It
writes no file. It applies the same validation the loader applies, so
`mint --role client --as @operator` (or any other listed name) is refused
before a line is ever produced.

## `check`

    fork-sandbox mail-api check --tokens <file>

`check` runs the loader `serve` runs, under the same
`$FORK_SANDBOX_OPERATORS`, and exits. On a good file it prints `ok: <n>
entries (<k> operator, <m> client)` and exits 0. On a bad one it prints the
one line `serve` would refuse with and exits 2. It never prints a hash or a
token. `install --postmaster` runs it on `K8S_MAIL_API_TOKENS_FILE` before
rendering anything.

## HTTP

    GET  /healthz     no auth; 200, body "ok"
    POST /v1/exec      Authorization: Bearer <token>; JSON body

Request body, capped at 24 MiB by `Content-Length` (checked before the body
is read; missing length is 411, oversized is 413):

    {"tool": "mail", "argv": ["send", "--from", "@ci-kickoff", "..."],
     "stdin_b64": "<base64, optional>",
     "files": {"patch.diff": "<base64>"}}

Response, always JSON:

    200  {"rc": <int>, "stdout_b64": "...", "stderr_b64": "..."}
    4xx/5xx  {"error": "<one line>"}

`400` is a malformed request (bad JSON, an unknown key, a NUL in argv, a
`--body` that is not `-`, an `--attach` naming a file that was not
uploaded, an unreferenced `files` entry, and so on). `403` is an
authenticated caller that this token may not do. `504` is a verb that ran
past its timeout and was killed.

`--attach <name>` must name a key of `files`, and it must be a plain
basename: non-empty, no `/`, no leading `.`, not `.` or `..`, no NUL or
newline. The server writes each uploaded file into a fresh temporary
directory, substitutes the real path into argv, and removes the directory
once the call returns. At most 16 files per request, 4 MiB decoded per
file, 4 MiB decoded for `stdin_b64`.

The server logs one line per request to stderr: time, label (or `-` when
unauthenticated), tool, verb, HTTP status and rc. It never logs the token,
the request body, a file, or an argv value.

## The verb allowlist

The server checks argv *structure* only: which verb, which flags exist for
it, whether a flag takes a value, and how many positionals. The values
themselves are left to `mail` and `postmaster`, which already validate
them. A flag must match exactly -- no `--flag=value`, no abbreviation, no
combined short flags -- and its value is the very next argv element. A
positional that starts with `-` (other than a lone `-`) is treated as a
flag and refused, since there is no way to tell it from one.

`tool: "mail"`:

| verb | positionals | flags | auth |
|---|---|---|---|
| send | 0 | `--from --to --cc --subject --body --attach* --hops --header* --allow-namespace* --reach-probe*` | `--from` in the token's identities; `--allow-namespace`/`--reach-probe` also need cap `grant` |
| reply | 0 | `--from --reply-to --body --to --cc --subject --attach* --hops --header*` | `--from` in the token's identities |
| show | 1 | | `read` |
| tree | 1 | | `read` |
| list | 0 | | `read` |
| inbox | 1 | `--all` | `read` |
| export | 1 | `--json` | `read` |
| seen | 1+ | | the first positional in the token's identities, and cap `seen` |
| grant | 1 | `--allow-namespace* --reach-probe* --clear --show --json` | `--show` alone needs `read`; anything else needs `grant` |

(`*` marks a repeatable flag.)

`tool: "postmaster"`:

| verb | positionals | flags | auth |
|---|---|---|---|
| status | 0 | `--thread --json` | `read` |
| flag | 1-2 | | operator only |
| unflag | 1 | | operator only |

An operator token passes every auth column, for any identity. A client's
identity check compares the flag's value against its own identities list
exactly, so a client can never pass `--from` a name on the operator list:
the loader already refused to load any client entry that lists one.

`send` and `grant` refuse `--context-ro` (403: "a host path has no meaning
over the API") even for an operator, since it names a path on the
server's own host and the API has no way to honor it -- it is left out of
the table entirely rather than given a value form.

`mail`'s own rule that a namespace grant needs at least one
`--reach-probe` still applies over the API: the server only checks that
the flags are individually allowed, not that they are used together, so
that check happens in `mail grant`/`mail send` as it always has.

## `--body` and `--attach` over the API

`--body` must be `-`: the body travels as `stdin_b64`, never as a value in
argv (a `--body /path` sent directly to the API is a 400). The `--remote`
client shim does this rewrite for you: `--body <file>` becomes `--body -`
plus the file's bytes as `stdin_b64`, and `--body -` forwards the client's
own stdin. `--attach <path>` becomes `--attach <basename>` with the bytes
uploaded under `files`; two attachments that would collide on the same
basename are refused locally, before anything is sent.

## The `--remote` client

`fork-sandbox mail --remote <verb> ...` and `fork-sandbox postmaster
--remote <verb> ...` behave like the local verb, but run against the API
server instead of the local store. Configuration comes from the
environment first, then from `k8s.env` in
`${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}` (`KEY=value`
lines, parsed by hand, never sourced as shell):

| environment variable | `k8s.env` key | meaning |
|---|---|---|
| `FORK_SANDBOX_MAIL_API_URL` | `K8S_MAIL_API_URL` | e.g. `http://127.0.0.1:8080` |
| `FORK_SANDBOX_MAIL_API_TOKEN_FILE` | `K8S_MAIL_API_TOKEN_FILE` | path to a file holding the raw token |

A missing URL or token file, or an empty token, is a one-line error naming
both the environment variable and the `k8s.env` key, and the shim exits 2.
Trailing whitespace in the token file is stripped.

The client's request has no proxy and follows no redirect, so the token
only ever goes to the configured URL. On a 200 response it writes the
decoded stdout and stderr byte-exact and exits with the verb's own rc. On
any other status it prints one line, `fork-sandbox <tool> --remote: HTTP
<code>: <error>`, to stderr and exits 2 -- this covers a `401` (bad token)
and a `403` (not allowed) the same as any other failure. A connection
failure is also a one-line error with exit 2.

## Running the server

    fork-sandbox mail-api serve --tokens /path/to/tokens --listen 0.0.0.0:8080

`serve` runs `mail` and `postmaster` by absolute path, next to its own
script, with the environment it was started under -- so `FORK_SANDBOX_MAIL_ROOT`
reaches it the same way it reaches a local invocation. It never opens a
shell.

## Out of scope here

This server does not filter by review target (no `X-Review-Target*`
header handling), does not reload tokens without a restart, does not rate
limit, and does not terminate TLS. Deploying it in a cluster is covered in
[docs/cluster-postmaster.md](cluster-postmaster.md).
