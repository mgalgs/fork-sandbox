# Sandbox tooling quickstart

How to use the fork/sandbox tooling in a project, starting from zero. This is
the entry-level guide; the operational contracts live in
`skills/fork-sandbox/SKILL.md` and `skills/pr-review-sandbox/SKILL.md`, and
the threat model in `docs/claude-sandboxed.md`.

## The mental model, in 30 seconds

Your machine ("the host") gathers context and launches the run. The work
happens in a **throwaway `git clone` of your repo**, inside a bubblewrap
sandbox with **no credentials** — no ssh keys, no tokens, no `.env`, no
tailnet route. A headless Claude session works there unattended, with every
permission check bypassed, which is safe *because* the sandbox holds nothing
worth stealing and no way to push.

Results come home on their own:

- a task run commits on a branch, which is **fetched back** into your repo;
- a PR review writes `REVIEW.md` and a final summary you read from the host;
- every event lands in a run directory you can watch live.

The sandbox contains the session while it runs. It does **not** make the code
the session wrote safe — review the fetched branch like a stranger's PR.

## Day one: any repo, zero setup

Every repo under `~/src` works today. Nothing needs to be added to the
project for these two flows.

The easiest entry: tell a Claude session to "fork this task to a sandbox" —
the `fork-sandbox` skill does everything below. By hand:

### Fork a task

1. Write a handoff document in `/var/tmp/claude-scratch/`. It becomes the
   session's **entire prompt**, so it must stand on its own: goal, context,
   the files involved, the full test command, acceptance criteria — and an
   explicit "commit the work" (uncommitted work is lost with the clone).

2. Launch:

   ```bash
   fork-sandbox.sh --branch sbx-my-task ~/src/myrepo \
       /var/tmp/claude-scratch/claude-handoff-my-task.md
   ```

   It prints the run directory and the exact watch commands. The run lives in
   a detached tmux session; you never have to attach.

3. Watch, if you want:

   ```bash
   fork-sandbox-status.sh --follow <run-dir>    # live, rendered
   fork-sandbox-status.sh <run-dir>             # state, branch, cost, summary
   fork-sandbox-status.sh --result <run-dir>    # the session's own report
   ```

4. When it ends, the branch is already fetched back into your repo. Read the
   diff before you build or merge it.

### Review a pull request

```bash
cd ~/src/myrepo
pr-review-sandbox.sh --dry-run 123   # gather + write the prompt, launch nothing
pr-review-sandbox.sh 123
```

The host gathers the PR, its comments, the referenced issues and the CI
failure logs, then hands them **read-only** to a sandboxed reviewer that has
no GitHub credential at all. `--dry-run` is free — use it to read the
generated prompt before spending a run. The review arrives as `REVIEW.md` in
the clone and as `fork-sandbox-status.sh --result <run-dir>`. Nothing is
posted to GitHub; you decide what to do with the text.

## What reaches the sandbox

Committed state only, plus a few provisioned extras:

- **Node repos:** `node_modules` is copied in and the `.nvmrc` toolchain is
  bound read-only. Suites that need them just run. Automatic.
- **Everything else on the opt-in ladder below.**

What never reaches it: uncommitted files, `.env`, ssh keys, tokens, your
global `~/.claude`, the tailnet or any VPN. The sandbox has ordinary internet
egress pinned to your default route, and no way to authenticate anywhere.

## The opt-in ladder for a project

### Level 0: nothing

Most repos. If the tests run from committed state (plus `node_modules` for
node), stop here.

### Level 1: a Python venv — `provision-ro`

A clone has no `.venv`. Commit `.agents/sandbox-services/provision-ro`, a
newline list of untracked repo-relative paths to bind **read-only** from your
real checkout into the clone at the same path:

```
# Untracked paths bound read-only from the origin repo into the clone.
.venv
```

A relocated venv runs fine (`sys.prefix` follows the binary). The one
casualty is console-script shebangs, which hardcode your real checkout's
path: invoke tools as `.venv/bin/python -m pytest`, never `.venv/bin/pytest`.
Say so in the project's `CLAUDE.md`.

The venv's **interpreter** must also be reachable inside the sandbox. A venv
built on the system python needs nothing (`/usr` is mounted), but `uv` and
`pyenv` install interpreters under `$HOME`, which is an empty tmpfs in the
sandbox — `.venv/bin/python` would dangle, and every compiled extension
behind it would be unusable. The provisioner reads `pyvenv.cfg`'s `home =`
and binds the interpreter prefix read-only when it sits in a recognized
store (`~/.local/share/uv/python`, `~/.pyenv/versions`). An interpreter
somewhere else is reported as a warning and not bound; move it under a
recognized store or build the venv on the system python.

Entries cannot escape the repo — absolute paths, `..` and symlinks that
resolve outside are refused.

### Level 2: databases and services — `sandbox-services`

For suites that need postgres, redis, object storage. The repo commits
`.agents/sandbox-services/` (the drivers still read the legacy
`.claude/sandbox-services/` when that is all a repo has); fork-sandbox then
stands the services up on the
host as a **throwaway compose project, one per run**, reachable from the
sandbox only through unix sockets in one bound directory. No TCP path, no
published host ports: a hostile session can at worst trash its own empty
per-run database.

It buys more than a passing suite. A database the session may freely wreck
turns out to change what a session will attempt: handed a disposable
postgres, an agent generated its own probe data and measured a query with an
index present and dropped, unprompted, rather than reasoning about the plan
from the source. A session that can destroy its database can verify claims
it would otherwise have to guess at — so the ceiling this raises is the
trustworthiness of the report, not only the number of tests that run.

Three files, all committed:

- `compose.yaml` — the services (shape below).
- `sandbox-services.sh` — the hook the wrapper calls: `up <sockets-dir>
  <clone-dir> <project>` before the sandbox starts, `down <project>` after
  it exits.
- `provision-ro` — optional, as in level 1.

**The hook must be committed to run.** The wrapper only executes committed
hook code (it clones committed state, and for PR reviews it also verifies
the hook is unchanged against the trusted base). A local, untracked hook is
invisible by design.

#### Reference `sandbox-services.sh`

The wrapper passes **positional arguments only and sets no environment**, and
runs the hook from a **copy** taken before the sandbox starts — so `up` must
export every variable the compose interpolates, and `down` (which has no
clone and no sockets dir) must tear down without re-parsing anything:

```bash
#!/usr/bin/env bash
# fork-sandbox per-run services hook.
#   up <sockets-dir> <clone-dir> <project>    before the sandbox starts
#   down <project>                            after the session exits
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"

case "${1:?usage: sandbox-services.sh up|down ...}" in
    up)
        sockets_dir="$2" clone_dir="$3" project="$4"
        # The wrapper sets no environment; export what the compose needs.
        export SANDBOX_SOCKETS_DIR="$sockets_dir"
        # Containers create their sockets as their own uid; password auth is
        # what guards the services, so a world-writable dir is fine.
        chmod 777 "$sockets_dir"
        docker compose -f "$here/compose.yaml" -p "$project" up -d --wait
        # Point the project's config at the sockets. The session reads this.
        cat > "$clone_dir/.env.sandbox" <<EOF
DATABASE_URL=postgresql://app:app@/app?host=$sockets_dir
REDIS_URL=unix://:app@$sockets_dir/redis.sock
EOF
        ;;
    down)
        project="$2"
        # No clone and no env at teardown: sweep by the compose project
        # label instead of re-parsing compose files. Version-proof.
        docker ps -aq --filter "label=com.docker.compose.project=$project" \
            | xargs -r docker rm -f
        docker volume ls -q --filter "label=com.docker.compose.project=$project" \
            | xargs -r docker volume rm
        docker network ls -q --filter "label=com.docker.compose.project=$project" \
            | xargs -r docker network rm
        ;;
    *)
        echo "usage: sandbox-services.sh up|down ..." >&2; exit 1 ;;
esac
```

The wrapper kills `down` after 120 seconds, so keep it simple.

#### Reference `compose.yaml`

Every trap in this example was hit for real during the first integration;
the comments are the scars:

```yaml
services:
  postgres:
    image: postgres:16      # pulled, never built -- see the rules below
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app   # auth is what guards the socket
      POSTGRES_DB: app
    volumes:
      - ${SANDBOX_SOCKETS_DIR:-/nonexistent}:/sockets
    # Keep the image's default socket dir in the list, not just /sockets:
    # the entrypoint's bootstrap psql and pg_isready use the compiled-in
    # /var/run/postgresql, and dropping it fails initdb.
    command: >
      postgres
      -c unix_socket_directories=/var/run/postgresql,/sockets
      -c listen_addresses=''

  redis:
    image: redis:7
    volumes:
      - ${SANDBOX_SOCKETS_DIR:-/nonexistent}:/sockets
    command: >
      redis-server --requirepass app
      --port 0
      --unixsocket /sockets/redis.sock --unixsocketperm 777
    # --port 0 turns TCP off, so a TCP healthcheck can never pass.
    # Check over the socket instead.
    healthcheck:
      test: ["CMD", "redis-cli", "-s", "/sockets/redis.sock", "-a", "app", "ping"]

  # A TCP-only service gets a socat sidecar in the same project.
  minio:
    image: minio/minio:latest
    environment:
      MINIO_ROOT_USER: app
      MINIO_ROOT_PASSWORD: app-secret
    command: server /data
  minio-sock:
    image: alpine/socat:latest
    depends_on: [minio]
    volumes:
      - ${SANDBOX_SOCKETS_DIR:-/nonexistent}:/sockets
    # unlink-early: an unclean teardown leaves the socket file behind, and
    # UNIX-LISTEN refuses to bind over an existing path.
    command: UNIX-LISTEN:/sockets/minio.sock,fork,mode=777,unlink-early TCP:minio:9000
```

Note the `${SANDBOX_SOCKETS_DIR:-/nonexistent}` shape: **every interpolated
variable needs a default**, so the file still parses in contexts that lack
the up-time environment.

#### The variant: overlaying an existing compose

A repo that already has a `docker-compose.yml` can keep it: the hook
delegates to a repo script that runs the base file plus a sockets overlay
committed in the hook dir. Two extra traps on that road:

- `ports: !override []` (compose v2.24+) **replaces** the base port list; a
  plain empty list would merge and leave the host ports published.
- `down` must be the label sweep above — the base compose lives in the
  clone, which the hook's copy cannot reach at teardown.

#### Tell the session about `.env.sandbox`

The hook writes `<clone>/.env.sandbox`; the sandboxed session is told
services are up and where the sockets are. Add one line to the project's
`CLAUDE.md` saying how to consume it (for example
`env $(cat .env.sandbox) python -m pytest`), so the session does not have to
guess the convention.

## Local-model runs: `--harness pi-local`

The levels above assume a session that costs money and has ordinary internet.
There is one more mode, and it is the opposite on both counts:

```bash
fork-sandbox.sh --harness pi-local --branch sbx-my-task ~/src/myrepo \
    /var/tmp/claude-scratch/claude-handoff-my-task.md
```

That runs pi against a model **you** host, in a sandbox with **no network at
all** — no internet, no LAN, no DNS. The endpoint arrives over a unix socket
and is the only thing the session can reach. So the run costs nothing, holds no
credential, and cannot send anything anywhere.

Setup is one file, on each machine that has such an endpoint:

```bash
mkdir -p ~/.config/fork-sandbox
echo 'MODEL_ENDPOINT=http://your-model-host:8001/v1' > ~/.config/fork-sandbox/model.env
```

It is not in the repo on purpose: an endpoint is a fact about one machine's
network, and this checkout is shared with machines that must not reach it.

The catch is that **nothing can be fetched** — no `npm install`, no
`pip install`, no `git fetch`. The provisioning ladder above is therefore not
optional here but the whole supply line, and a handoff should say what is
already provided. Combined with level 2 this is the interesting case: a
disposable database, a full service stack, an agent free to wreck any of it,
no way out, and no bill.

For an interactive session in the same sealed sandbox — you at the keyboard,
no clone, no fetch-back — run `pi-sandboxed <dir>` directly. It is
`agent-sandboxed` under a name that says which agent starts, and it drops you
into pi's TUI with the model already selected.

Add `--services` to stand up the same level-2 stack for that interactive
session: `pi-sandboxed --services <dir>` reads the repo's
`.agents/sandbox-services/`, brings the compose project up, binds the sockets
read-only and the venv's interpreter, and tears the stack down when you quit.
It is the one-flag form of the four steps an interactive session used to do by
hand. The one difference from fork-sandbox is that there is no clone: the work
dir is your real checkout, so the hook writes `.env.sandbox` straight into it
(fine when the repo gitignores `.env*`), and a linked worktree's real gitdir is
bound read-only so `git status` and `git log` work. Commits cannot be made in a
sealed session — use `fork-sandbox.sh` for work meant to return as a branch.

A sealed session reaches the model and nothing else. When it needs one more
service — a GPU embedder a test suite calls, an internal API — add
`--bridge HOST:PORT[=INPORT]`, once per endpoint. It carries that host:port in
over the same unix-socket bridge the model uses: a host-side `socat` dials the
real host, a sandbox-side `socat` listens on `127.0.0.1:INPORT`, and the run
prints the mapping on start so a client can point at the in-sandbox address.
`INPORT` defaults to `PORT` and must be 1024 or higher (the sandbox's
unprivileged uid cannot bind a privileged port); the endpoint host is reached
from the host's own network, so a tunnel or VPN the sandbox must not see still
works. It is `agent-sandboxed`/`pi-sandboxed` only — nothing else opens in the
seal.

## Rules the wrapper enforces

These are checked, not advisory:

- **Committed only.** For a clone (fork-sandbox), the hook runs from committed
  state; PR reviews run it only if it is unchanged against the trusted base
  branch. The interactive `pi-sandboxed --services` path runs the hook present
  in your own checkout — it is your tree, trusted the same as any script you
  run there — but still copies it out first, so a session cannot rewrite the
  teardown code.
- **Pulled images only.** If any `*.yml`/`*.yaml` in the hook dir contains a
  `build:` key, services are disabled for the run — a build would execute
  clone-controlled Dockerfile steps on the host, outside the sandbox.
- **No published host ports.** The sockets directory is the only path in.
- **Teardown always runs** (with a 120s cap), and the next run sweeps any
  orphaned `claude-fork-sandbox-*` compose project whose run dir is gone.

## Where to read more

- `skills/fork-sandbox/SKILL.md` — the full operational contract: handoff
  shape, monitoring, the services contract, trust rules.
- `skills/pr-review-sandbox/SKILL.md` — the PR review flow.
- `docs/claude-sandboxed.md` — why the sandbox looks like this, what it does
  not protect against, and what sealed egress changes.
- `docs/sandbox-backend.md` — the contract the isolation layer implements,
  and where a container or Kubernetes backend would plug in.
- The script headers (`fork-sandbox.sh`, `pr-review-sandbox.sh`,
  `claude-sandboxed`, `agent-sandboxed`, `sandbox-backend-bwrap`) — flags and
  boundaries, exhaustively.
- `pi-agent/README.md` — the pi configuration sandboxed runs get.
