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
  `grant`, `seen`, `target` and `upstream`, or `-`.

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
                           [--as @a[,@b]] [--caps read,grant,seen,target,upstream]

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
authenticated caller that this token may not do. `409` is a request whose
`Idempotency-Key` is still being run by another request (see "Idempotency
keys"). `422` is an `Idempotency-Key` reused with a different request. `504`
is a verb that ran past its timeout and was killed.

`--attach <name>` must name a key of `files`, and it must be a plain
basename: non-empty, no `/`, no leading `.`, not `.` or `..`, no NUL or
newline. The server writes each uploaded file into a fresh temporary
directory, substitutes the real path into argv, and removes the directory
once the call returns. At most 16 files per request, 4 MiB decoded per
file, 4 MiB decoded for `stdin_b64`.

The server logs one line per request to stderr: time, label (or `-` when
unauthenticated), tool, verb, HTTP status and rc, with a trailing `replay`
when the response was a recorded one. It never logs the token, the request
body, a file, an idempotency key, or an argv value.

## Idempotency keys

The postmaster pod restarts with `Recreate`, so the API is down for the
length of a rollout, and a caller whose request was run but whose reply was
lost cannot tell that from a request that never arrived. A request for a verb
that changes state (`send`, `reply`, `seen`, `grant`, `flag`, `unflag`) may
therefore carry an `Idempotency-Key` header: 16 to 128 characters from
`A-Za-z0-9_-` (anything else is a 400). The server does not mint
Message-IDs from it or accept one from the caller; the store alone makes
those, as ever.

- The first request with a key, from a given token, runs the verb. When the
  verb has *completed* (any 200, whatever its rc), the server records the
  response. A later request with the same key and the same body gets the
  recorded response and the verb does not run again; the log line ends in
  `replay`. The same key with a different body is a 422, and nothing runs.
  Keys are per token: another token's identical key is a different key.
- The record is one file under
  `$FORK_SANDBOX_MAIL_ROOT/.postmaster/api-idempotency/`, on the mail
  volume, so it survives a restart of the server. Its name is a hash of the
  token's label and the key, and it holds a hash of the request body and
  the response: never the key. It is written atomically (a synced temp file
  renamed into place), so a reader sees all of a record or none of it.
- A request that dies before the verb completes (the 60 s kill, a crash of
  the server) leaves no record, and its retry runs the verb. A request that
  is refused (401, 403, 400, 413) never reaches the key.
- Records older than 24 h are ignored, and deleted the next time the server
  writes a record. A retry a day later could therefore run again; the client's
  budget is minutes.
- Two requests with one key at once run the verb once: the second waits up
  to 30 s for the first, then answers with its record, or with 409 when the
  first has not finished (the client retries a 409). The lock is in the
  server's memory, which is enough because the mail volume has one writer.
- The header is ignored for the read-only verbs, and a server that predates
  it ignores it too (an unknown header is dropped). A client's retries
  against such a server are at-least-once: a send whose reply was lost can
  be delivered twice. The client does not detect the server's version.

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
| send | 0 | `--from --to* --cc* --subject --body --attach* --hops --header* --allow-namespace* --reach-probe* --context-secret --review-target` | `--from` in the token's identities; `--allow-namespace`/`--reach-probe`/`--context-secret` also need cap `grant`; `--review-target` also needs cap `target` |
| reply | 0 | `--from --reply-to --body --to* --cc* --subject --attach* --hops --header* --upstream-head --upstream-state` | `--from` in the token's identities; `--upstream-head` and `--upstream-state` also need cap `upstream` |
| show | 1 | | `read` |
| tree | 1 | | `read` |
| list | 0 | `--json --header*` | `read` |
| inbox | 1 | `--all` | `read` |
| export | 1 | `--json` | `read` |
| seen | 1+ | | the first positional in the token's identities, and cap `seen` |
| grant | 1 | `--allow-namespace* --reach-probe* --context-secret --clear --show --json` | `--show` alone needs `read`; anything else needs `grant` |

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
the table entirely rather than given a value form. `--context-secret` is
allowed: a Secret name means the same thing over the API as on the host. It
is a single-value flag and needs cap `grant`, like the other grant flags.

`mail`'s own rule that a namespace grant needs at least one
`--reach-probe` still applies over the API: the server only checks that
the flags are individually allowed, not that they are used together, so
that check happens in `mail grant`/`mail send` as it always has.

On `mail send` and `mail reply`, `--header` refuses any name that is
`X-Version`, `X-Upstream-Head` or `X-Upstream-State`, or starts with
`X-Review-Target`, compared case-insensitively (403, one line naming the
reason). Those headers are the review-target and upstream contracts (see
[docs/agent-mail.md](agent-mail.md)): only `mail send --review-target` and
the postmaster may write the review-target ones, only `mail reply
--upstream-head` may write `X-Upstream-Head`, and only `mail reply
--upstream-state` may write `X-Upstream-State`, so no caller may set them
through `--header`, including an operator token. `list`'s `--header`
is a read-only filter and is never subject to this restriction.

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
| `FORK_SANDBOX_MAIL_API_RETRY_SECONDS` | `K8S_MAIL_API_RETRY_SECONDS` | the retry budget in whole seconds; default `300`, `0` turns retries off |

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

**Retries.** A server restart is a window in which calls fail, so the client
retries on its own, for every verb: when it cannot connect, loses the
connection, times out waiting for the reply, or gets `409`, `502`, `503` or
`504`. Any other status is a real answer, a 4xx included, and is returned at
once without a retry. The wait before attempt *n*+1 is random between half
of and all of `min(30 s, 1 s * 2^(n-1))` (exponential, jittered, capped), and
the retries stop when the retry budget, counted from the first attempt, is
spent: 300 s by default, set by the environment variable or `k8s.env` key in
the table above, and `0` means a single attempt, exactly as before retries
existed. A budget that is not a whole number of seconds is a one-line error
and exit 2. Each retry prints one line to stderr (`fork-sandbox mail
--remote: attempt 2 failed (<error>); retrying in 1.7 s`); when the budget
runs out the last error is printed as before, followed by `fork-sandbox mail
--remote: gave up after N attempts`, and the exit code is 2.

The retries cover callers that reach the server through a stable endpoint,
such as the in-cluster Service URL. A `kubectl port-forward` to the Service
stays bound to the pod it picked when it started and does not reconnect to
the pod that replaces it after a rollout, so a client behind one retries
until its budget is spent without getting through. Restart the forward after
a rollout, or keep it under a supervisor that does.

For each invocation of a verb that changes state the client makes one
random `Idempotency-Key` and sends the same key on every attempt of that
invocation (see "Idempotency keys"), so a retry after a lost reply returns
the first result, with the same message id, instead of delivering a second
message. Read-only verbs send no key. Against a server that predates the
key, retries are at-least-once.

## Running the server

    fork-sandbox mail-api serve --tokens /path/to/tokens --listen 0.0.0.0:8080

`serve` runs `mail` and `postmaster` by absolute path, next to its own
script, with the environment it was started under -- so `FORK_SANDBOX_MAIL_ROOT`
reaches it the same way it reaches a local invocation. It never opens a
shell.

## Out of scope here

This server does not reload tokens without a restart, does not rate limit,
and does not terminate TLS. Deploying it in a cluster is covered in
[docs/cluster-postmaster.md](cluster-postmaster.md).
