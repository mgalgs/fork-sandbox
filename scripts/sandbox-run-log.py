#!/usr/bin/env python3
""":approved: Track sandboxed coder runs -- append, judge and query the run log.

Every fork-sandbox run ends by appending one JSON line to one fixed file,
~/.claude/sandbox-runs.jsonl: harness, model, exit code, commits, token
counts, cost, the orchestrator's task metadata (--task-meta at launch), and
a hash plus archived copy of the handoff -- the actual prompt. That is the
mechanical half of a record, and it fires from the generated runner on
every terminal state, so the log accumulates without anyone remembering to
write it.

The judgment half only the orchestrator knows, and only later: did the work
land? That is a second event, appended by hand after review, joined to the
run by the run directory's basename. Together the two halves make the
model+harness+prompt performance database this file is: which prompt shapes
survive contact with which models, stratified by task kind, difficulty and
size, so prompt templates can be iterated on and eventually dispatched to
match the task.

Like log-prompt-slip.py, this is deliberately boring: fixed log path, fixed
archive path, no output-path argument anywhere, so blanket approval hands
over nothing. `record` reads only run directories under the fork machinery's
own root.

Usage:
  sandbox-run-log.py list --days 14
  sandbox-run-log.py record --run-dir /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX
  sandbox-run-log.py verdict claude-fork-sandbox.XXXXXX --outcome integrated \\
      --defects 1 --notes 'off-by-one in selection; fixed on integrate'
  sandbox-run-log.py show claude-fork-sandbox.XXXXXX
  sandbox-run-log.py stats --by model,task.kind

Events:
  run_end   appended by fork-sandbox.sh's runner when a run ends. Re-running
            a runner appends again; queries take the LAST run_end per run id.
  verdict   appended by the orchestrator after review. Also last-wins.

Recommended --task-meta fields (documented here, enforced nowhere):
  kind                implement | fix | refactor | test | docs |
                      investigate | review | pr-review
  difficulty          1-5, the orchestrator's own assessment
  size                xs | s | m | l | xl -- expected scope
  prompt_template_id  a slug naming the handoff SHAPE (plan-heavy-v1,
                      spec-and-tests-v2). Coin one when trying a new shape,
                      then reuse it exactly, or the stats group on noise.
  stage, tags         free-form

The review loop (fork-sandbox.sh --review-loop N):
  review_loop  present only when the run used the flag. The whole loop, as
               the runner recorded it: `cap`, `ended` (approved | cap |
               no-progress | harness-error | skipped), `detail` for the last
               two, and `iterations` -- one object per review/fix pair with
               its findings count, each leg's exit code and cost, the branch
               head before and after, and the commits the fix leg added.
               `total_cost_usd` beside it is the run's implement leg plus
               every loop leg; `cost_usd` stays the implement leg alone.
               Group on it directly: `stats --by model,review_loop.ended`
               answers how often a model talks itself into an extra
               iteration, and the per-iteration costs say what that was
               worth.

The maintainer loop (fork-sandbox.sh --maintainer-loop N): the outer
sibling of the review loop, on its own model and harness, reading the
branch after the review loop ended.
  maintainer_loop  present only when the run used the flag. Same shape as
               review_loop -- `cap`, `maintainer_model`,
               `maintainer_harness`, `ended` (approved | cap | no-progress |
               harness-error | skipped), `detail`, and `iterations` with
               each maintainer/fix leg's exit code, cost, heads and the
               commits the fix leg added. A fix leg's commits go to the
               maintainer's next iteration, never to the review loop.
               Group on it directly: `stats --by model,maintainer_loop.ended`

Context refresh (fork-sandbox.sh --refresh-at, on by default at 0.5 on the
claude harness):
  refresh        how the run's context-refresh chain ended: `none` (disabled,
                 or any harness but claude), `empty-outbox` (a coding leg
                 ended with no hand-off waiting -- the ordinary ending,
                 whether or not any continuation ran), `cap` (--refresh-max
                 legs ran and a hand-off was still waiting), `no-handoff`
                 (a leg was nudged and ended its turn without writing one),
                 or `leg-error` (a continuation leg exited non-zero -- a
                 crash, not an ordinary ending; see `continuations[].exit`).
                 Present on every claude run made after this field existed,
                 even one that never came near its threshold -- readers
                 comparing against `none` do not also need to check for a
                 missing key.
  continuations  one object per continuation leg the run actually made --
                 `leg` (2 for the first, matching leg 1 being the implement
                 leg), `exit`, `cost_usd`, `usage`, `handoff` (the
                 <run-id>/handoff-N.md record its prompt was built from) and
                 `handoff_stale` (true when that record predated the clone's
                 last commit at the time this leg's prompt was built).
                 Empty for a run that never refreshed. `total_cost_usd`
                 folds every continuation's cost in beside the review loop's;
                 `cost_usd` stays the implement leg alone. Group on it
                 directly: `stats --by model,refresh` says how often a model
                 needs to refresh itself at all, and the per-leg costs in
                 `continuations` say what each extra session was worth.

The prompt overlay (fork-sandbox.sh --prompts-dir, or a machine's default
~/.config/fork-sandbox/prompts):
  prompt_overlay  present only when a run applied one, to at least one leg.
                  `dir` is the source directory and `rev` its git HEAD --
                  suffixed `-dirty` if its working tree had uncommitted
                  changes, or null if it is not a git repo at all -- both
                  facts about the run, not about any one leg. `legs` holds
                  one key per leg that actually got a fragment --
                  `implement`, `review`, `fix` -- each an object with
                  `fragments` (the relative paths that matched, in the order
                  they were composed) and `sha256` (a fingerprint of their
                  concatenated bytes). A leg that matched nothing is absent
                  from `legs` entirely; a run with --review-loop unset never
                  has `review` or `fix` keys, since those legs never ran.
                  This ships no fragment content of its own; see
                  docs/prompt-overlays.md. Group on it directly: `stats --by
                  model,prompt_overlay.rev` says which prompt revision a
                  model's outcomes actually came from, and `stats --by
                  prompt_overlay.legs.fix.sha256` narrows to the fix leg
                  alone.

Verdict outcomes:
  integrated             merged as-is, or with trivial touch-ups
  integrated-with-fixes  merged after this session fixed real defects
  rescued                the run died; work recovered from the clone and used
  rejected               discarded; the task was redone or relaunched
  abandoned              the task itself was dropped
"""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import statistics
import sys

# One fixed file and one fixed archive dir. Not arguments, on purpose: with
# no output path there is nothing to aim somewhere else.
LOG = os.path.expanduser("~/.claude/sandbox-runs.jsonl")
ARCHIVE_DIR = os.path.expanduser("~/.claude/sandbox-handoffs")

# `record` reads files a run left behind, so its one path argument must be a
# run directory the fork machinery itself created -- the same boundary
# fork-sandbox.sh enforces for what it stages. Anything else is refused.
FORKS_ROOT = "/var/tmp/claude-scratch/forks"
RUN_DIR_PREFIX = "claude-fork-sandbox."

OUTCOMES = [
    "integrated",
    "integrated-with-fixes",
    "rescued",
    "rejected",
    "abandoned",
]

# Fields lifted verbatim from summary.json into a run_end record.
SUMMARY_FIELDS = [
    "mode",
    "harness",
    "harness_version",
    "model",
    "usage_source",
    "branch",
    "origin_repo",
    "base_sha",
    "exit_code",
    "harness_error",
    "commits",
    "commits_list",
    "fetched",
    "branch_removed",
    "cost_usd",
    "total_cost_usd",
    "refresh",
    "report_from",
    "continuations",
    "usage",
    "started_at",
    "ended_at",
    "duration_seconds",
]


def die(msg):
    print(f"sandbox-run-log: error: {msg}", file=sys.stderr)
    sys.exit(1)


def now_iso():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def epoch_iso(epoch):
    return dt.datetime.fromtimestamp(epoch).astimezone().isoformat(
        timespec="seconds"
    )


def append(rec):
    line = json.dumps(rec, separators=(",", ":"))
    # Concurrent runs end concurrently; an exclusive lock keeps two appends
    # from interleaving mid-line.
    with open(LOG, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line + "\n")


def read_log():
    if not os.path.exists(LOG):
        return []
    recs = []
    bad = 0
    with open(LOG, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    if bad:
        print(f"sandbox-run-log: skipped {bad} unparsable line(s) in {LOG}",
              file=sys.stderr)
    return recs


def merged_runs(recs):
    """One dict per run id: the last run_end, with the last verdict (if any)
    attached under 'verdict'. Ordered by appearance in the log."""
    runs = {}
    verdicts = {}
    for rec in recs:
        rid = rec.get("run_id")
        if not rid:
            continue
        if rec.get("event") == "run_end":
            runs[rid] = dict(rec)
        elif rec.get("event") == "verdict":
            verdicts[rid] = rec
    for rid, v in verdicts.items():
        if rid in runs:
            runs[rid]["verdict"] = v
    return runs


def get_path(rec, path):
    cur = rec
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def parse_ts(rec):
    try:
        return dt.datetime.fromisoformat(rec.get("ts", ""))
    except ValueError:
        return None


def load_json_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def load_run_env(path):
    """run.env is key=value, one per line; the FIRST match for a key wins,
    matching fork-sandbox-status.sh's convention."""
    env = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env.setdefault(k.strip(), v.rstrip("\n"))
    except OSError:
        pass
    return env


def cmd_record(args):
    rd = os.path.realpath(args.run_dir)
    root = os.path.realpath(FORKS_ROOT)
    if os.path.dirname(rd) != root or not os.path.basename(rd).startswith(
        RUN_DIR_PREFIX
    ):
        die(
            f"--run-dir must name a {RUN_DIR_PREFIX}* directory directly "
            f"under {FORKS_ROOT} (got {rd}). This tool reads only what the "
            f"fork machinery wrote."
        )
    if not os.path.isdir(rd):
        die(f"run directory {rd} does not exist")
    run_id = os.path.basename(rd)

    rec = {
        "v": 1,
        "event": "run_end",
        "run_id": run_id,
        "ts": now_iso(),
        "source": "fork-sandbox",
    }

    summary = load_json_file(os.path.join(rd, "summary.json"))
    if summary:
        for k in SUMMARY_FIELDS:
            if k in summary:
                rec[k] = summary[k]
        if isinstance(summary.get("ended_at"), (int, float)):
            rec["ts"] = epoch_iso(summary["ended_at"])
    else:
        # summary.json is written by a jq that is allowed to fail; the run
        # is still worth a record. run.env and exit-code carry the basics.
        rec["summary_missing"] = True
        env = load_run_env(os.path.join(rd, "run.env"))
        for k in ("harness", "harness_version", "model", "branch",
                  "origin_repo", "base_sha"):
            if env.get(k):
                rec[k] = env[k]
        try:
            with open(os.path.join(rd, "exit-code"), encoding="utf-8") as f:
                rec["exit_code"] = int(f.read().strip())
        except (OSError, ValueError):
            pass

    rec["task"] = load_json_file(os.path.join(rd, "task-meta.json"))

    # --review-loop's record, when the run had one: what the loop cost, how
    # many iterations it took and how it ended. No key at all when the file is
    # absent, which is every run launched without the flag and every run from
    # before it existed -- readers must not assume it is there.
    review_loop = load_json_file(os.path.join(rd, "review-loop.json"))
    if review_loop is not None:
        rec["review_loop"] = review_loop

    # --maintainer-loop's record, when the run had one: the outer tier's
    # cost, iterations and ending. Same absence convention: no key at all
    # when the file is absent, which is every run without the flag.
    maintainer_loop = load_json_file(os.path.join(rd, "maintainer-loop.json"))
    if maintainer_loop is not None:
        rec["maintainer_loop"] = maintainer_loop

    # The prompt overlay's provenance, when the run applied one: which
    # machine-local fragments, from where, at what rev (marked -dirty if the
    # prompts working tree had uncommitted changes when the run started, null
    # if the directory is not a git repo at all). No key at all when the run
    # had no prompts directory or nothing in it matched -- readers must not
    # assume it is there. See docs/prompt-overlays.md.
    prompt_overlay = load_json_file(os.path.join(rd, "prompt-overlay.json"))
    if prompt_overlay is not None:
        rec["prompt_overlay"] = prompt_overlay

    # The preset's provenance, when the run was launched with --preset: its
    # name, the machine-local file it came from and a hash of that file's
    # bytes at launch. Same absence convention -- no key at all when the run
    # used no preset. Group on it with e.g. `stats --by preset.name`. See
    # docs/presets.md.
    preset = load_json_file(os.path.join(rd, "preset.json"))
    if preset is not None:
        rec["preset"] = preset
        # The definition's bytes AS LAUNCHED, when the run dir carries them:
        # archive under the sha256 the record already records, so identical
        # definitions dedup for free and an edited preset's old epochs keep
        # resolving from the ledger alone. This never reads the live file in
        # the config dir -- record runs at run end, by which time the preset
        # may have been edited; the launch-time copy is the only source that
        # cannot race it.
        preset_yaml = os.path.join(rd, "preset.yaml")
        if os.path.isfile(preset_yaml) and not os.path.islink(preset_yaml):
            try:
                with open(preset_yaml, "rb") as f:
                    data = f.read()
                # A hand-crafted or corrupted preset.json may be any JSON
                # value: keep this read inside the guard so a missing or
                # non-string sha256 skips the archive, not the record.
                dest = os.path.join(
                    ARCHIVE_DIR, "presets",
                    rec["preset"]["sha256"] + ".yaml")
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                # A second run of the same definition is a no-op: the key
                # is the hash, so its existence is the dedup.
                if not os.path.exists(dest):
                    with open(dest, "wb") as f:
                        f.write(data)
                rec["preset"]["archive"] = dest
            except (OSError, KeyError, TypeError) as e:
                print(f"sandbox-run-log: preset not archived: {e}",
                      file=sys.stderr)
        else:
            # An older run dir: provenance recorded, definition gone.
            print("sandbox-run-log: preset not archived: no preset.yaml "
                  "in the run directory", file=sys.stderr)

    # The handoff is the prompt, and the run dir it lives in gets deleted
    # after review -- archive it, so prompt iteration has the actual text to
    # study, and hash it, so identical prompts are identifiable.
    handoff = os.path.join(rd, "handoff.md")
    if os.path.isfile(handoff) and not os.path.islink(handoff):
        try:
            with open(handoff, "rb") as f:
                data = f.read()
            rec["handoff_sha256"] = hashlib.sha256(data).hexdigest()
            rec["handoff_bytes"] = len(data)
            os.makedirs(ARCHIVE_DIR, exist_ok=True)
            dest = os.path.join(ARCHIVE_DIR, run_id + ".md")
            with open(dest, "wb") as f:
                f.write(data)
            rec["handoff_archive"] = dest
        except OSError as e:
            print(f"sandbox-run-log: handoff not archived: {e}",
                  file=sys.stderr)

    append(rec)
    print(
        f"sandbox-run-log: recorded {run_id} "
        f"({rec.get('harness', '?')}/{rec.get('model', '?')}, "
        f"exit {rec.get('exit_code', '?')}, "
        f"{rec.get('commits', '?')} commit(s))"
    )


def cmd_verdict(args):
    runs = merged_runs(read_log())
    if args.run_id not in runs:
        print(
            f"sandbox-run-log: warning: no run_end for '{args.run_id}' in the "
            f"log; appending the verdict anyway (the join is by id)",
            file=sys.stderr,
        )
    elif runs[args.run_id].get("verdict"):
        prev = runs[args.run_id]["verdict"].get("outcome")
        print(
            f"sandbox-run-log: note: replacing earlier verdict '{prev}' "
            f"(queries take the last one)",
            file=sys.stderr,
        )
    rec = {
        "v": 1,
        "event": "verdict",
        "run_id": args.run_id,
        "ts": now_iso(),
        "outcome": args.outcome,
    }
    if args.defects is not None:
        rec["defects"] = args.defects
    if args.retries is not None:
        rec["retries"] = args.retries
    if args.notes:
        rec["notes"] = args.notes
    append(rec)
    print(f"sandbox-run-log: {args.run_id} -> {args.outcome}")


def apply_filters(runs, args):
    out = []
    since = None
    if getattr(args, "days", None):
        since = dt.datetime.now().astimezone() - dt.timedelta(days=args.days)
    if getattr(args, "since", None):
        since = dt.datetime.fromisoformat(args.since).astimezone()
    for rec in runs.values():
        if since:
            ts = parse_ts(rec)
            if ts is None or ts < since:
                continue
        if args.harness and rec.get("harness") != args.harness:
            continue
        if args.model and args.model not in (rec.get("model") or ""):
            continue
        if args.kind and get_path(rec, "task.kind") != args.kind:
            continue
        if args.template and get_path(
            rec, "task.prompt_template_id"
        ) != args.template:
            continue
        if args.outcome and get_path(rec, "verdict.outcome") != args.outcome:
            continue
        out.append(rec)
    out.sort(key=lambda r: r.get("ts", ""))
    return out


def fmt_tok(n):
    if n is None:
        return "-"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.0f}k"
    return str(n)


def cmd_list(args):
    rows = apply_filters(merged_runs(read_log()), args)
    if not rows:
        print("no matching runs")
        return
    hdr = ("RUN", "DATE", "HARNESS", "MODEL", "KIND", "DIF", "EXIT",
           "CMTS", "IN", "OUT", "COST", "OUTCOME")
    table = [hdr]
    for r in rows:
        model = (r.get("model") or "-").rsplit("/", 1)[-1]
        ts = (r.get("ts") or "")[:10]
        usage = r.get("usage") or {}
        cost = r.get("cost_usd")
        table.append((
            r.get("run_id", "?")[:30],
            ts,
            r.get("harness") or "-",
            model[:24],
            str(get_path(r, "task.kind") or "-"),
            str(get_path(r, "task.difficulty") or "-"),
            str(r.get("exit_code", "-")),
            str(r.get("commits", "-")),
            fmt_tok(usage.get("input_tokens")),
            fmt_tok(usage.get("output_tokens")),
            f"${cost:.4f}" if isinstance(cost, (int, float)) else "-",
            str(get_path(r, "verdict.outcome") or "-"),
        ))
    widths = [max(len(row[i]) for row in table) for i in range(len(hdr))]
    for row in table:
        print("  ".join(cell.ljust(w) for cell, w in zip(row, widths)).rstrip())
    print(f"\n{len(rows)} run(s)")


def cmd_show(args):
    runs = merged_runs(read_log())
    if args.run_id not in runs:
        die(f"no run_end for '{args.run_id}' in {LOG}")
    print(json.dumps(runs[args.run_id], indent=2))


def cmd_stats(args):
    rows = apply_filters(merged_runs(read_log()), args)
    if not rows:
        print("no matching runs")
        return
    dims = [d.strip() for d in args.by.split(",") if d.strip()]
    groups = {}
    for r in rows:
        key = tuple(str(get_path(r, d) if get_path(r, d) is not None else "-")
                    for d in dims)
        groups.setdefault(key, []).append(r)

    hdr = tuple(d.upper() for d in dims) + (
        "RUNS", "EXIT0", "DIED", "LANDED", "REJ", "NOVERD",
        "MED-IN", "MED-OUT", "COST")
    table = [hdr]
    landed_set = {"integrated", "integrated-with-fixes", "rescued"}
    for key in sorted(groups):
        rs = groups[key]
        exit0 = sum(1 for r in rs if r.get("exit_code") == 0)
        died = sum(
            1 for r in rs
            if isinstance(r.get("exit_code"), int) and r["exit_code"] != 0
        )
        outcomes = [get_path(r, "verdict.outcome") for r in rs]
        landed = sum(1 for o in outcomes if o in landed_set)
        rej = sum(1 for o in outcomes if o in ("rejected", "abandoned"))
        noverd = sum(1 for o in outcomes if o is None)
        ins = [get_path(r, "usage.input_tokens") for r in rs]
        ins = [i for i in ins if isinstance(i, (int, float))]
        outs = [get_path(r, "usage.output_tokens") for r in rs]
        outs = [o for o in outs if isinstance(o, (int, float))]
        costs = [r.get("cost_usd") for r in rs
                 if isinstance(r.get("cost_usd"), (int, float))]
        table.append(key + (
            str(len(rs)),
            str(exit0),
            str(died),
            str(landed),
            str(rej),
            str(noverd),
            fmt_tok(statistics.median(ins)) if ins else "-",
            fmt_tok(statistics.median(outs)) if outs else "-",
            f"${sum(costs):.4f}" if costs else "-",
        ))
    widths = [max(len(row[i]) for row in table) for i in range(len(hdr))]
    for row in table:
        print("  ".join(cell.ljust(w) for cell, w in zip(row, widths)).rstrip())
    print(f"\n{len(rows)} run(s); LANDED = integrated, integrated-with-fixes "
          f"or rescued; DIED = exit != 0")


def add_filter_args(p):
    p.add_argument("--harness", help="exact harness name")
    p.add_argument("--model", help="substring of the model id")
    p.add_argument("--kind", help="task.kind, exact")
    p.add_argument("--template", help="task.prompt_template_id, exact")
    p.add_argument("--outcome", choices=OUTCOMES, help="verdict outcome")
    p.add_argument("--days", type=int, help="only runs from the last N days")
    p.add_argument("--since", help="only runs since YYYY-MM-DD")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0].replace(":approved: ", ""),
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("record",
                       help="append a run_end record from a run directory")
    p.add_argument("--run-dir", required=True,
                   help=f"a {RUN_DIR_PREFIX}* directory under {FORKS_ROOT}")
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("verdict",
                       help="append the orchestrator's post-review judgment")
    p.add_argument("run_id", help="the run directory's basename")
    p.add_argument("--outcome", required=True, choices=OUTCOMES)
    p.add_argument("--defects", type=int,
                   help="defects found in review/integration")
    p.add_argument("--retries", type=int,
                   help="extra rounds this task needed after this run")
    p.add_argument("--notes", help="free-form: what happened, what was fixed")
    p.set_defaults(func=cmd_verdict)

    p = sub.add_parser("list", help="one line per run, newest last")
    add_filter_args(p)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("show", help="the full merged record for one run")
    p.add_argument("run_id")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("stats", help="grouped success/cost/token stats")
    p.add_argument("--by", default="harness,model",
                   help="comma list of record paths to group by "
                        "(default: harness,model; e.g. model,task.kind or "
                        "task.prompt_template_id)")
    add_filter_args(p)
    p.set_defaults(func=cmd_stats)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
