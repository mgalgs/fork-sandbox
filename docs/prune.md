# Pruning finished runs: `fork-sandbox prune`

Every local run leaves its run dir under `/var/tmp/claude-scratch/forks/`,
and almost all of a run dir's size is its `clone/`. Nothing else ever
deletes one, so without this the forks root only grows.

```
fork-sandbox prune [--dry-run] [--older-than DAYS]
```

It removes the `clone/` of each run that qualifies (below), and nothing
else. It prints one line per run dir it prunes, with the bytes freed, then
a total, then how many run dirs it skipped and why. `--dry-run` prints the
same list and deletes nothing.

```
pruned  /var/tmp/claude-scratch/forks/claude-fork-sandbox.Ab12Cd  2.3 GiB
total: pruned 1 run(s) older than 14 days, freed 2.3 GiB
skipped: 5
  live                 1
  not-fetched          1
  too-recent           3
```

## What stays

Everything but `clone/`: `summary.json`, `summary.txt`, `events*.jsonl`,
`exit-code`, `run.env`, `outbox/`, handoffs, logs and `scripts/`. They are
small, and they are what `fork-sandbox status`, `status --result`,
`status --json` and `fork-sandbox log` read, so all of those keep working
on a pruned run dir. The run dir gains a `clone-pruned` file
(`pruned_at=<epoch>`, `bytes=<n>`), and `fork-sandbox status` adds
"(pruned <date>; ...)" to its `clone:` line instead of naming a directory
that is no longer there.

## Which runs qualify

All of these must hold; the skip reason a run is counted under when one
does not is in brackets.

- **It is a local run dir the launcher made**: a directory directly under
  the forks root named `claude-fork-sandbox.*`, not a symlink, resolving to
  exactly that path, holding a `run.env` with `version=` and a `run_dir=`
  that names this same directory [`not-a-run`, `unsafe-path`]. Other
  tools' directories under the root (pr-review, resume, backend scratch,
  context and stage dirs, `by-session/`) are never looked at. A `--k8s`
  run is left alone [`k8s-run`].
- **It has a clone to prune**: a real `clone/` directory, not a symlink,
  resolving inside the run dir [`no-clone`, `already-pruned`,
  `unsafe-path`].
- **It is not live**: its recorded runner pid is not a live process (the
  zombie-aware test `fork-sandbox status` uses), and no tmux session of
  its recorded name exists [`live`].
- **It has ended**: the runner's `summary.json` (written last) and
  `exit-code` are both there [`not-ended`]. A run that crashed before
  writing its summary stays here too: it may need rescuing.
- **Its branch came home**: `summary.json` says `"fetched": true`
  [`not-fetched`] and `"uncommitted_files": 0` [`uncommitted-work` when it
  is more, `uncommitted-unknown` when it is null or absent, as on a summary
  from before that field existed]. A run that failed to fetch or left
  uncommitted work may still need its clone for the rescue procedure, so
  it is never pruned.
- **It ended long enough ago**: `summary.json`'s `ended_at` is more than
  the retention age ago [`too-recent`; `no-end-time` without one]. The run
  dir's own mtime does not count.

## Safety

It never follows a symlink and never deletes anything whose resolved path
is not inside the forks root. It runs no git at all: a clone's git config
is writable from inside the sandbox, so a git command run in it executes
on the host. Deletion stays on one filesystem, and directories a sandboxed
tool left without write permission are made writable first so `rm` can
empty them. The marker is written before the clone is removed, so a
removal that fails part-way (reported as `PARTIAL`, exit 1) still reads as
pruned, and the next prune tries again.

Two prunes never run at once: each holds an `flock` on
`<forks-root>/.fork-sandbox-prune.lock`, and one that cannot take it exits
0 straight away.

## Automatic prune at launch

Every local `fork-sandbox run` starts `fork-sandbox-prune.sh --auto` in
the background before it creates its run dir. It is detached in its own
session, at low priority, with none of the launcher's file descriptors,
and nothing waits for it, so it never delays or fails the launch. It
prints nothing and appends one line about what it did to
`<forks-root>/.fork-sandbox-prune.log`:

```
2026-01-31T12:00:00Z prune --auto (retention 14 days): pruned 3 run(s), freed 41.2 GiB; skipped 12 (live 1, too-recent 11)
```

It starts only when the launch reads the login user's own
`~/.config/fork-sandbox` (home taken from the password database, not
`$HOME`). The forks root is machine-wide, so a launch whose config was
moved elsewhere -- by `FORK_SANDBOX_CONFIG_DIR` or a different `$HOME`, as
every test suite does -- starts no prune: it would otherwise prune the real
root at a retention the operator never set.

## Configuration

One per-machine key, in `~/.config/fork-sandbox/runs.env`
(`FORK_SANDBOX_CONFIG_DIR` moves the directory):

```
FORK_SANDBOX_RUN_RETENTION_DAYS=14
```

The retention, in whole days, for the automatic prune, and the verb's
default when `--older-than` is not given. Missing means 14. `0` turns the
automatic prune off (the verb then defaults to 14). The largest accepted
value is 36500 (about a century; anything larger would overflow the age
arithmetic). A value that is not a whole number from 0 to 36500 makes the
automatic prune log that and do nothing, and makes the verb refuse to run
unless `--older-than` is given; `--older-than` has the same range.

The Kubernetes path and the cluster postmaster keep their own retention;
this touches neither.
