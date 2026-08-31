#!/usr/bin/env bash
# fork-sandbox.sh — Run one unattended headless agent session in a sandboxed clone
#
# Usage: fork-sandbox.sh [options] <project-path> <handoff-file>
#        fork-sandbox.sh configure [--remove] [--all] [--dry-run]
#
# `configure` discovers per-machine config already present on this host --
# an OPENROUTER_API_KEY in the environment, a local model endpoint, a
# kubectl context -- and installs the pieces you pick into
# ~/.config/fork-sandbox/{pi,model,k8s}.env, the files documented below and
# in docs/configure.md. `--remove` runs the same picker against what is
# currently set, to take keys back out. See docs/configure.md for the full
# picture, including how to add a new discoverer.
#
# --branch <name>:       branch the session commits on. Defaults to a
#                        timestamped name.
# --checkout <ref>:      start the branch at <ref> instead of the repo's HEAD.
#                        The ref is resolved in YOUR repo, so anything it can
#                        name works, including a commit under a private ref
#                        namespace such as a fetched pull request head. That
#                        commit also becomes the base the session's work is
#                        measured against, so a session that commits nothing
#                        still leaves the repo unchanged.
# --review-only:         review an existing branch once, without a coding or
#                        fix leg. Requires --checkout; use --review-base to
#                        choose the start of the review range.
# --review-base <ref>:   commit the review range starts from. Defaults to the
#                        origin repo's merge-base of --checkout and HEAD.
# --model <model>:       model or model alias for the session (e.g. fable,
#                        opus, sonnet, or a name from aliases.conf).
#                        Required with --harness pi, where it names an
#                        OpenRouter model such as moonshotai/kimi-k3.
#                        Optional with --harness pi-local, which asks the
#                        endpoint what it serves, and with --harness codex,
#                        which passes it to `codex exec --model`.
# --model-unchecked:     send the selected model verbatim, without alias
#                        resolution or validation. Useful before a new model
#                        reaches a harness's local cache. Requires a model.
#                        Governs --review-model too, when both are given.
# --harness <name>[/<model>]:
#                        claude (the default), pi, pi-local, or codex. A model
#                        may follow the first slash, so a displayed
#                        harness/model value can be pasted back in. Claude
#                        model names are passed to its CLI, which resolves
#                        opus/sonnet/haiku/fable itself; pi model ids are also
#                        passed through because neither has a local model list.
#                        See below.
# --dry-run:             resolve and print the harness and model, then exit
#                        without creating a clone, run directory or session.
# --claude-args "...":   extra arguments passed verbatim to the claude CLI
# --pi-args "...":       extra arguments passed verbatim to pi, e.g.
#                        "--thinking low". Only with --harness pi or
#                        pi-local, which are the harnesses that start pi.
# --review-loop <N>:     after the session ends, review its commits in a fresh
#                        session and let a third one fix what the review
#                        found, up to N times. N must be a positive integer.
#                        See "The review loop" below.
# --review-model <model>:
#                        use this model for review legs. Fix legs continue to
#                        use --model. Requires --review-loop. Resolved and
#                        validated the same way as --model, against the same
#                        harness (or against --review-harness, when given).
# --review-harness <name>[/<model>]:
#                        use this harness for review legs -- claude, pi,
#                        pi-local or codex, with the same combined
#                        harness/model form --harness takes. Fix legs
#                        continue to use --harness. Requires --review-loop.
#                        A model given both here and via --review-model
#                        conflicts, same as --harness/--model. --harness
#                        pi-local (sealed, no network) with a networked
#                        --review-harness is refused: the review leg would
#                        send the clone's contents to that harness's model
#                        provider, defeating the seal. The reverse --
#                        --review-harness pi-local reviewing a networked
#                        implement harness -- is fine. Refused with --k8s.
# --task-meta '<json>':  one JSON object of orchestrator-supplied task
#                        metadata -- kind, difficulty, size,
#                        prompt_template_id, stage -- stored beside the run
#                        and folded into the run-log record. See
#                        sandbox-run-log.py's header for the recommended
#                        fields.
# --sandbox-args "...":  extra arguments passed to claude-sandboxed itself.
#                        Only --unpin-egress is accepted. Refused outright
#                        with --harness pi-local, which is sealed and so has
#                        no egress to unpin.
# --context-ro <dir>:    bind <dir> read-only into the sandbox as gathered
#                        context. The directory must live under
#                        /var/tmp/claude-scratch/forks/ — a staging path a
#                        host-side script created on purpose — never an
#                        arbitrary host path.
# --keep-session:        leave the tmux session open on a shell when the run
#                        ends, instead of letting it close. Ignored with
#                        --foreground, which has no tmux session.
# --foreground:          run here in the foreground instead of a detached
#                        tmux session. Blocks until the session ends.
# --no-services:         skip the per-run services a repo opts into with
#                        .agents/sandbox-services/ (see below), even when it
#                        has them.
# --services-trust-ref <ref>:
#                        honor the services hook only if the checked-out ref
#                        did not change the sandbox-services contract relative to
#                        <ref>. A services hook is host-side code, so a
#                        review of an untrusted ref (a pull request head)
#                        passes the trusted base here, and a hook the ref
#                        modified is not run.
# --prompts-dir <dir>:   overlay model-specific prompt fragments from <dir>
#                        onto the generated prompt for this run only. <dir>
#                        must exist. See docs/prompt-overlays.md.
# --refresh-at <fraction|tokens>:
#                        nudge a session to hand off to a fresh one when its
#                        context fills up, so a long run degrades into a new
#                        session instead of into compaction. Default 0.5 (half
#                        the model's context window); 0 disables it. A value
#                        above 1 is an absolute token count instead of a
#                        fraction. claude only for now — see "A run that
#                        refreshes itself" below. Refused with any other
#                        --harness, and with --k8s.
# --refresh-max <n>:     how many continuation legs may follow the first
#                        before the run gives up and moves on to the review
#                        loop anyway. Default 6. Requires --refresh-at (which
#                        is on by default), so it inherits the same harness
#                        and --k8s restrictions.
# --k8s:                 submit this run as a Kubernetes Job instead of a
#                        local sandbox, by exec'ing fork-sandbox-k8s.sh run
#                        with the arguments below. Defaults --harness to pi,
#                        the only harness the cluster path builds; claude,
#                        pi-local and codex are still refused if named
#                        explicitly. Most other flags describe LOCAL sandbox
#                        machinery this run never touches and are refused by
#                        name rather than silently dropped -- see
#                        "Kubernetes runs" below.
# --timeout <seconds>:   with --k8s, how long to wait for the agent before
#                        giving up (passed to fork-sandbox-k8s.sh run).
#                        Refused without --k8s.
# --keep:                with --k8s, leave the Job and pod in place after a
#                        successful fetch instead of removing them (passed
#                        to fork-sandbox-k8s.sh run). Refused without --k8s.
# --outbox-dir <path>:   with --k8s, where to land the pod's /work/outbox
#                        after the agent finishes (passed to
#                        fork-sandbox-k8s.sh run). Defaults to
#                        /var/tmp/claude-scratch/forks/k8s-<safe-branch>/outbox.
#                        Refused without --k8s.
# --outbox-max <size>:   raise the outbox size cap above the default 64 MiB.
#                        Takes a plain byte count or a size with a K/M/G
#                        suffix (512K, 256M, 2G). Applies to both the local
#                        path and --k8s -- there is no upper ceiling, since
#                        the operator raising it is the one accepting the
#                        extra disk cost.
# -h, --help:            print this header and exit.
#
# The run gets its own detached tmux session, not a window of yours, so
# launching one never takes your focus and never adds to your window list.
# Attach only to troubleshoot or to watch:
#
#   tmux attach -t cc-sbx-<branch>          # from a plain terminal
#   tmux switch-client -t cc-sbx-<branch>   # from inside tmux
#
# The tmux session ends when the run ends, so a session that still exists
# means the work is still going. Everything worth reading outlives it in the
# run directory, so nothing is lost when it closes. Pass --keep-session to
# hold it open on a shell instead.
#
# This needs tmux but does not need you to be inside it. Launched from a plain
# terminal it starts the tmux server itself.
#
# This is fork-task.sh --sandboxed, made unattended. The session runs
# headless — `claude --print` — so three things follow that an interactive
# session does not get:
#
#   - It needs no keypress. --dangerously-skip-permissions shows a one-time
#     acceptance dialog and records the answer under $HOME. The sandbox gives
#     every run a fresh ephemeral $HOME, so the answer is never remembered and
#     an interactive session stops on that dialog forever. Print mode never
#     shows it.
#   - It exits when the work is done, so the branch comes back on its own.
#   - Its whole event stream lands in a host-side log file. The redirection is
#     opened by this script, outside the sandbox, so the sandbox cannot see or
#     touch the log.
#
# Read the log with fork-sandbox-status.sh, which is the supported way in.
#
# A run is not sealed off once it starts. <run-dir>/inbox is bound read-only
# into the sandbox, and fork-sandbox-say.sh drops an operator addendum there —
# a course correction carrying the same authority as the handoff. On the claude
# harness a hook puts it in front of the session on its next tool call and
# refuses to let it finish while one is unread; the other harnesses are told
# to read the directory on a tool-call floor, around long commands, before
# each commit, and before their final report. So steering a run no longer
# means killing it and starting over. Each leg archives what it was shown
# into <run-dir>/inbox-delivered/leg-<N>/ the moment it ends, so a later
# leg's fresh sandbox never re-reads it; a --refresh-at continuation's
# prompt carries every archived addendum forward, while a review or fix leg
# gets none.
#
# The review loop. --review-loop N adds a quality pass after the coding
# session: a REVIEW leg reads the commits the run just made and writes a
# verdict, and when that verdict lists problems a FIX leg is given them and
# commits the fixes. That pair repeats up to N times. Each leg is a fresh
# session of the same harness, started the same way as the main one (or with
# --review-model, or an entirely different harness and model via
# --review-harness, for review legs), with a generated prompt on stdin. A
# reviewer therefore never sits inside the
# conversation whose work it is judging — an author defends its code, a
# stranger reads it. --review-harness pushes that further: a stranger from a
# different model family entirely catches what the implement harness's own
# family is blind to. Fix legs always stay on the implement harness and
# model, whichever review flags were given -- there is no --fix-harness. The
# review leg follows the code-review-portable skill,
# which is bound into every run already, and writes its verdict to
# .git/review-verdict.md in the clone: the first line is APPROVED or FINDINGS,
# and the rest is one finding per paragraph, each citing file:line -- or,
# after APPROVED, a "Checked:" paragraph saying what the reviewer read, ran
# and failed to refute. It then ends with a five-paragraph "## Report" for
# the orchestrator; the report is shown by --result while only the verdict
# body reaches the fix leg. A verdict is data, and it reaches the fix leg the
# way every prompt does, on stdin.
#
# The loop stops on the first of four things:
#
#   approved       the review leg said APPROVED. The usual good ending.
#   findings       review-only reported findings; there is no fix leg.
#   cap            N iterations ran and the last review still had findings.
#   no-progress    a fix leg left the branch head where it found it. The same
#                  model reviews its own work here, so it can argue with
#                  itself forever; an iteration that commits nothing is the
#                  end of the argument.
#   harness-error  a leg exited non-zero, died of a model error, or left no
#                  readable verdict. Nothing is inferred from a leg that
#                  failed — neither approval nor a lack of progress.
#
# The loop is skipped, and says so, when the main leg exited non-zero or
# committed nothing: there is nothing to review. What happened is recorded in
# <run-dir>/review-loop.json, per iteration, with each leg's exit code, head
# sha, cost and token usage, and it lands in the run log as `review_loop` —
# the point being to answer later, from real data, how many iterations are
# worth paying for on a given model. Each leg is a session at that model's
# price, so N=2 can cost three times a plain run: summary.json's
# total_cost_usd is the sum of all of them, while cost_usd goes on meaning the
# coding session alone.
#
# The legs write their own event files (events-review-N.jsonl,
# events-fix-N.jsonl); events.jsonl stays the coding session's, so --result
# and --follow keep showing the work rather than the review of it. The run
# counts as running until the last leg is done — the exit code is published
# after the loop — so a watcher gets one terminal event, at the end, with a
# summary that reflects the reviewed branch.
#
# A run that refreshes itself. An interactive session that fills its context
# writes a hand-off and forks a fresh session rather than degrade into
# compaction. --refresh-at gives an unattended run the same move, with no
# human in the loop: when a coding leg's context crosses the threshold, a hook
# nudges it, once, through the same channel an operator addendum uses, to
# finish the step it is on, commit, write a self-contained hand-off for a
# fresh session to <run-dir>/outbox/handoff.md, and end its turn. If it does,
# this script moves that file to <run-dir>/handoff-N.md (the record) and runs
# a fresh session on the SAME clone and branch with it as the prompt —
# continuation N, whose prompt also embeds <run-dir>/handoff-original.md, a
# verbatim snapshot of the hand-off this run itself was launched with, ahead
# of the previous leg's own hand-off. That repeats, on the same nudge-and-
# check cycle, until a leg ends with nothing waiting in the outbox (the
# ordinary ending), until --refresh-max legs have run, or until a nudged leg
# ends without writing a hand-off at all. The review loop above, when both
# flags are given, then runs once, after the LAST coding leg, over every
# commit the whole chain made.
#
# A hand-off can go stale: a session may keep working and committing long
# after writing it and never rewrite it. The inbox hook sends a Stop back
# once when the hand-off already in the outbox predates the clone's last
# commit; if the leg ends anyway (crash, timeout), this script's own check,
# after moving the hand-off to its handoff-N.md record, warns the
# continuation it forks in that leg's own prompt instead.
#
# It costs what it looks like it costs: each continuation is another whole
# session, at the same model's price. summary.json's `continuations` array
# and `refresh` field say what happened — how many legs ran, each one's exit,
# cost and usage, and how the chain ended (`none`, `empty-outbox`, `cap`,
# `no-handoff` for a nudged leg that never wrote one, or `leg-error` for a
# continuation that exited non-zero) — and `total_cost_usd` folds every
# continuation in beside the review loop's own legs.
#
# claude only, for now. The threshold is measured in
# fork-sandbox-inbox-hook.sh, which already runs on every tool call and reads
# the transcript path off the hook payload — pi, pi-local and codex have no
# hook system to measure with, so --refresh-at is refused outright on those
# harnesses, and on --k8s, whose pod runs a different entrypoint.
#
# Sandboxed mode trades isolation for silence: the session never asks for
# permission, because the sandbox is the boundary instead of the prompt.
#
# It does NOT run in your checkout. It runs in a throwaway `git clone
# --shared` of it, and only that clone is writable. This is the whole
# security design, not a convenience. A writable git directory is host code
# execution: a hook, or a config key such as core.fsmonitor, runs on the HOST
# the next time anyone uses git in that repo — outside the sandbox, with the
# ssh keys and the tailnet. The clone's own git directory is writable and
# therefore untrusted, so the work comes back by `git fetch`, which git
# deliberately does not let a fetched-from repository use to run commands.
# Nothing writable of yours is ever mounted, so there is no hook to plant and
# nothing to enumerate. For the same reason nothing here ever runs git inside
# the clone once the sandbox has touched it.
#
# What the session gives up:
#   - No global ~/.claude. No global CLAUDE.md, skills, scripts, settings
#     or hooks. A project .claude/ is committed, so it comes with the clone.
#   - No ssh keys, repository tokens or agent socket. Some harnesses carry only
#     the model credential described below. It commits; it cannot push.
#   - No tailnet and no VPN. The LAN stays reachable.
#   - No tmux. It cannot split panes or fork further tasks.
#   - Only committed state, with three carve-outs. Uncommitted changes,
#     .env files and anything else untracked stay behind, as does any
#     project setup a .claude/fork-worktree.sh hook would have done. The
#     carve-outs: for a node project the origin's node_modules is copied
#     into the clone and the .nvmrc node is bound read-only; a repo may
#     list untracked paths in .agents/sandbox-services/provision-ro to
#     bind read-only from the origin (a .venv, say); and a repo may stand
#     per-run services up with .agents/sandbox-services/ (see below).
# Write the handoff doc so it stands on its own, and tell the session to
# commit — uncommitted work has nothing to fetch.
#
# Per-run services. A repo opts in by committing .agents/sandbox-services/ (or
# the legacy .claude/sandbox-services/) with a compose file and a
# sandbox-services.sh. When it is present, this
# script stands the services up on the HOST as a throwaway docker compose
# project, one per run, and binds only a unix-socket directory into the
# sandbox read-write. There is no TCP path from the sandbox to the host, the
# egress pin is untouched, and the compose publishes no host ports — that
# last one is the hook's obligation, not something this script can enforce —
# so a hostile session can at worst trash its own empty per-run database. The
# services come down when the run ends, on the same trap that runs however
# the session dies. The hook is host-side code, run from a copy taken before
# the sandbox starts; for an untrusted checkout use --services-trust-ref so a
# ref that changed the hook does not run it. The full contract — the up/down
# interface, what this script guarantees, and the isolation properties a
# repo's hook must hold — is docs/sandbox-services.md.
#
# Reviewing still matters. The sandbox contains the session while it runs;
# it does not make the code it wrote safe. Read the branch before you build
# it, exactly as you would a pull request from a stranger.
#
# --harness pi runs pi (github.com/earendil-works/pi) against OpenRouter
# instead of claude,
# in the same sandbox, with the same clone and the same fetch-back. It
# needs --model, because there is no default, and it reads its key from
# ~/.config/fork-sandbox/pi.env, which claude-sandboxed requires to be
# mode 0600 and owned by you. That key is the only credential inside: no
# Claude token is copied, and the run cannot spend the subscription.
#
# It keeps the review kit. pi implements the Agent Skills standard, so the
# commit-then-review and code-review-portable skill directories and the script
# toolbox are bound in; pi is handed each skill with --skill, because its $HOME
# here is a fresh tmpfs with no settings file to discover them from. A handoff
# should ask for a skill by name rather than with a slash command.
# code-review-portable is a stand-in for the built-in /code-review, which is
# compiled into claude and so exists on no other harness.
#
# What a pi run does give up is the rendered log. It runs with --mode json,
# so events.jsonl holds one JSON AgentSessionEvent per line — agent_start,
# message_start, message_end, text, auto_compaction_start,
# auto_compaction_end, agent_end — but those are pi's own event shapes, not
# claude's stream-json, so the formatted views of fork-sandbox-status.sh —
# --result above all — still have nothing to render. Read events.jsonl
# directly, with --log and the summary alongside it.
#
# --harness pi-local runs pi against a model YOU host, in a sandbox with no
# network at all. The wrapper is agent-sandboxed rather than
# claude-sandboxed: same clone, same services, same fetch-back, but egress
# is sealed and the one endpoint arrives over a unix socket. Read its
# header for how the bridge works.
#
# Three things follow. The run costs nothing, because the tokens are yours.
# Nothing secret is inside — a local endpoint needs no credential, so
# unlike a pi or a codex run there is no key in there at all. And the
# session cannot exfiltrate or reach a LAN service, because there is
# nowhere to reach.
#
# It needs an endpoint, in ~/.config/fork-sandbox/model.env, and --model
# only when the endpoint serves more than one. The review kit, the raw-text
# log caveat and the session copy are the same as --harness pi.
#
# The cost is that nothing can be fetched: no npm install, no pip install,
# no git fetch. A repo whose suite needs dependencies must provision them
# the usual way — node_modules is copied in, provision-ro binds a venv, and
# .agents/sandbox-services stands the databases up. The generated prompt
# tells the session that the network is gone, so it reports a missing
# dependency instead of trying to install one.
#
# --harness codex runs OpenAI's codex the same way. It needs no --model,
# because codex has a default of its own -- but one given is honoured, and
# passed straight to `codex exec --model`. It needs no key file either: it
# takes the ChatGPT sign-in from ~/.codex/auth.json. codex will not parse a
# credential with fields missing, so the whole file goes in — except the
# refresh token, which is replaced by a placeholder. That token is
# single-use, and a sandbox that spent it would silently log the host out
# of codex. codex refreshes only when the access token has expired, so a
# run works and cannot rotate the host's credential; when the token HAS
# expired the run refuses to start and says to log in again. The launcher
# warns when under an hour is left.
#
# codex reports tokens but no price, so a codex run has counts and a null
# cost. Its cached_input_tokens is part of input_tokens rather than a
# figure beside it, unlike claude's, which is why total_tokens is
# computed per harness and usage_source names which convention produced
# the numbers.
#
# Both report their cost where they can, which matters more here than for
# claude: an OpenRouter run spends money rather than a subscription.
# claude states the session total in its result event; pi states it
# nowhere, but records the token cost of every message in its session
# file. So the session is written inside the clone's .git, copied to
# <run-dir>/pi-session when the run ends, and totalled. Either way the
# summary carries one 'cost:' line, which is the place to look.
#
# --k8s hands the whole run to fork-sandbox-k8s.sh, which submits it as a
# Kubernetes Job, waits for it to finish, fetches the branch back and (unless
# --keep) tears the Job down. See docs/kubernetes-runs.md for the design.
# It is a thin dispatcher, not a second implementation: this script resolves
# and validates the harness and model exactly as it does locally, builds the
# argument list fork-sandbox-k8s.sh run already accepts, and execs it. None
# of the clone, tmux-runner or review-loop machinery below this point ever
# runs for a --k8s call.
#
# That also means most of this script's flags have nothing to attach to on a
# cluster run: they describe local-sandbox machinery -- bubblewrap, per-run
# docker-compose services, the detached tmux session -- that a Kubernetes pod
# has no equivalent of, they describe a real capability (--checkout,
# --prompts-dir, --pi-args, --task-meta) the cluster path has
# not been built to carry yet, or -- --claude-args alone, since --harness
# claude landed here -- the pod's own invocation of the flag's target IS
# built, but fixed: a --harness claude pod really does run the claude CLI,
# just with no flag yet to extend its rendered invocation the way a local
# claude launch can be extended. --k8s refuses each of these by name instead
# of accepting and dropping it: an operator who thinks a refused flag did
# something, when a k8s run silently ignored it, has no way to notice from
# the outside -- no error, no missing output, just a run that looks like it
# honored a flag it never saw.
#
# --review-loop is the one capability in that list that IS carried: --k8s
# passes it through to fork-sandbox-k8s.sh run, which runs the loop POD-SIDE
# after the coding leg, always as pi against the model proxy -- see
# fork-sandbox-k8s-review-loop.sh and docs/kubernetes-runs.md. --review-model
# is carried too, on both harnesses: models.json lists every distinct id
# among --model and --review-model, so the review leg can run a different
# pi model than the coding leg used. --review-harness stays refused outright
# for --harness pi (there is nothing to switch: the review loop already is
# pi) but is required, and must be 'pi', for --harness claude with
# --review-loop -- claude never reviews itself in the pod, so a mixed run
# needs pi's review leg named explicitly, and named as an OpenRouter id via
# --review-model, since a habit-typed --model-shaped value like "opus" would
# otherwise only fail after a paid coding leg instead of at validation.
#
# --context-ro is the other capability that IS carried: --k8s forwards it to
# fork-sandbox-k8s.sh run, which threads it to cmd_submit the same way a
# local run's own --context-ro reaches the sandbox -- see 'Getting files in'
# in docs/kubernetes-runs.md. cmd_submit applies the same directory-under-
# /var/tmp/claude-scratch/forks/, no-symlinks, 256 MiB constraints itself, so
# there is nothing left for this script's own local-path check, below, to
# duplicate for a --k8s run -- it never reaches that check at all.
#
# One gap is not a refused flag, because no flag controls it: a --k8s run
# never appends to the durable run log described below
# (~/.claude/sandbox-runs.jsonl), unlike every local run. The numbers that
# log would need -- cost, tokens, exit code -- live in the pod, and getting
# them out is its own piece of work, not done here. --task-meta IS refused
# with --k8s, for the same underlying reason: it exists to be folded into
# that log by sandbox-run-log.py, and there is no log entry for a --k8s run
# to fold it into yet.
#
# Every run's end is also appended to the durable run log,
# ~/.claude/sandbox-runs.jsonl, by sandbox-run-log.py -- whatever the
# harness and however the run ended: harness, model, exit code, commits,
# tokens, cost, the --task-meta object, and a hash plus archived copy of
# the handoff. The orchestrator judges the run later with
# `sandbox-run-log.py verdict <run-id>` (the run dir's basename is the
# id); `list` and `stats` read the log back. A machine without the tool
# skips the append rather than failing the run.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

# The GNU flags these scripts use (realpath -m, stat -c) do not exist on the
# BSD tools of the same name, and macOS has no timeout at all. Say so here, in
# a sentence, before anything is created -- otherwise the first use fails as
# "illegal option -- m" from a tool the reader has no reason to suspect.
fs_require_gnu_tools || exit 1

formatter="$script_dir/fork-sandbox-format.sh"
status_cmd="fork-sandbox-status.sh"

# Per-machine facts a shared checkout must not carry: the model endpoint for
# a pi-local run, and the OpenRouter key for a pi run. agent-sandboxed reads
# the same directory, and honors the same override.
config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"

# ---------------------------------------------------------------------------
# `configure` -- discovering and installing the per-machine config above.
# See docs/configure.md for the full picture; this comment covers only the
# part that must not be casually loosened later.
#
# fork-sandbox.sh is blanket-approved in this project's own permission
# config, so once launched it runs with nobody watching. A discoverer
# (fork-sandbox-discover-<name>) is an executable found on PATH or beside
# this script -- effectively a plugin supplied by whoever set up this
# machine, not code this repo has reviewed. If a discoverer could name an
# arbitrary file to write, running `configure` would be equivalent to
# running whatever that plugin says, which defeats the point of a narrow
# blanket approval.
#
# The fix: a discoverer never supplies a path, only a `target` string of
# the form <file>:<KEY>, which is looked up in the table below -- a fixed
# set of (filename, key) pairs compiled into this script. A target that is
# not a key here is refused by name, loudly, and the candidate that named
# it is dropped without being written anywhere. Every write `configure`
# ever makes lands in $config_dir, under one of the four filenames that
# appear as a key prefix below, with no other path reachable by any flag or
# plugin. Adding a target means editing this table, in a reviewed change to
# a script the user already trusts -- not something a discoverer can do by
# itself, ever.
#
# The value half of each entry is "secret" or "plain". A "secret" target's
# file is created (or tightened) to mode 0600, and its value is never
# printed anywhere this command writes -- not in --dry-run, not in a
# confirmation, not in an error.
declare -A FS_CONFIGURE_TARGETS=(
    [pi.env:OPENROUTER_API_KEY]=secret
    [model.env:MODEL_ENDPOINT]=plain
    [model.env:MODEL_ID]=plain
    [model.env:MODEL_CTX]=plain
    [k8s.env:K8S_CONTEXT]=plain
    [k8s.env:K8S_NAMESPACE]=plain
    [k8s.env:K8S_IMAGE]=plain
    [k8s.env:K8S_PROXY_UPSTREAM]=plain
    [k8s.env:K8S_DENIED_PROBE]=plain
)

cmd_configure_usage() {
    cat <<'EOF'
Usage: fork-sandbox.sh configure [--remove] [--all] [--dry-run]

Discover per-machine config already on this host -- an OPENROUTER_API_KEY,
a local model endpoint, a kubectl context -- and install the pieces you
pick into ~/.config/fork-sandbox/{pi,model,k8s}.env.

  --remove    show what is currently set and remove the selected keys,
              instead of adding new ones.
  --all       skip the picker and take every candidate (add) or every
              currently-set key (remove). configure refuses to run
              non-interactively without this.
  --dry-run   print what would be written or removed; write nothing.
  -h, --help  print this and exit.

See docs/configure.md, including "Adding a discoverer".
EOF
}

# Resolves the discoverer binary for one name: PATH first, then beside this
# script. Identical to fork-sandbox-k8s.sh's resolve_platform, and for the
# identical reason -- a checkout must work before install.sh has put
# anything on PATH.
fs_configure_resolve_discoverer() {
    local name="$1" bin
    bin="$(command -v "fork-sandbox-discover-$name" 2>/dev/null || true)"
    if [[ -z "$bin" && -x "$script_dir/fork-sandbox-discover-$name" ]]; then
        bin="$script_dir/fork-sandbox-discover-$name"
    fi
    printf '%s' "$bin"
}

# Prints every discoverer name found on PATH or beside this script, one per
# line, deduplicated. A name is whatever follows the fork-sandbox-discover-
# prefix in an executable file's basename.
fs_configure_discoverer_names() {
    local -A seen=()
    local -a dirs=()
    IFS=':' read -r -a dirs <<< "$PATH"
    dirs+=("$script_dir")
    local dir f name
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/fork-sandbox-discover-*; do
            [[ -f "$f" && -x "$f" ]] || continue
            name="${f##*/fork-sandbox-discover-}"
            [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || continue
            seen["$name"]=1
        done
    done
    if (( ${#seen[@]} )); then
        printf '%s\n' "${!seen[@]}" | sort
    fi
}

# The candidate table `configure` builds by running every discoverer's
# `discover` verb. Parallel arrays rather than one structured value, because
# bash has no records: index i of each array describes one candidate.
# Filled by fs_configure_gather; read by the add path built in later
# commits.
FS_CAND_ID=()          # namespaced "<discoverer>/<id>", for display and logs
FS_CAND_RAWID=()       # the id exactly as the discoverer printed it
FS_CAND_TARGET=()      # "<file>:<KEY>", or "-" for informational
FS_CAND_LABEL=()
FS_CAND_SOURCE=()
FS_CAND_DISPLAY=()     # already-safe rendering; never a raw secret
FS_CAND_BIN=()         # the discoverer binary that produced this candidate
FS_CAND_NAME=()        # the discoverer's name, for error messages
FS_CAND_SELECTABLE=()  # 1 unless target is "-"

# Runs `discover` against every resolved discoverer and appends whatever it
# printed to the FS_CAND_* arrays above, after checking each line's target
# against FS_CONFIGURE_TARGETS. A discoverer that exits non-zero, or a line
# naming a target outside that table, is reported to stderr and skipped
# rather than aborting the whole command -- one broken, or maliciously
# steered, plugin must not take every other one down with it, and must
# never turn into a write anywhere but $config_dir.
fs_configure_gather() {
    FS_CAND_ID=(); FS_CAND_RAWID=(); FS_CAND_TARGET=(); FS_CAND_LABEL=()
    FS_CAND_SOURCE=(); FS_CAND_DISPLAY=(); FS_CAND_BIN=(); FS_CAND_NAME=()
    FS_CAND_SELECTABLE=()

    local name bin out rc id target label source display
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        bin="$(fs_configure_resolve_discoverer "$name")"
        if [[ -z "$bin" ]]; then
            echo "Warning: configure: could not resolve fork-sandbox-discover-$name; skipping." >&2
            continue
        fi

        rc=0
        out="$("$bin" discover)" || rc=$?
        if (( rc != 0 )); then
            echo "Warning: configure: fork-sandbox-discover-$name exited $rc on 'discover'; skipping its candidates." >&2
            continue
        fi
        [[ -n "$out" ]] || continue

        while IFS=$'\t' read -r id target label source display; do
            [[ -n "$id" ]] || continue
            if [[ ! "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
                echo "Warning: configure: fork-sandbox-discover-$name printed an invalid id '$id'; dropping that candidate." >&2
                continue
            fi
            # The security boundary: a target not in the fixed table is
            # refused by name, loudly, and dropped -- never written, and
            # never silently ignored either, since a silent drop here is
            # indistinguishable from "everything is fine" to whoever is
            # reading the output of a --dry-run or a script's log.
            if [[ "$target" != "-" && -z "${FS_CONFIGURE_TARGETS[$target]+x}" ]]; then
                echo "Error: configure: fork-sandbox-discover-$name named target" >&2
                echo "'$target', which is not one of the targets this script" >&2
                echo "writes. A discoverer names a target from a fixed table," >&2
                echo "never a path -- see docs/configure.md. Dropping that candidate." >&2
                continue
            fi
            FS_CAND_ID+=("$name/$id")
            FS_CAND_RAWID+=("$id")
            FS_CAND_TARGET+=("$target")
            FS_CAND_LABEL+=("$label")
            FS_CAND_SOURCE+=("$source")
            FS_CAND_DISPLAY+=("$display")
            FS_CAND_BIN+=("$bin")
            FS_CAND_NAME+=("$name")
            if [[ "$target" == "-" ]]; then
                FS_CAND_SELECTABLE+=(0)
            else
                FS_CAND_SELECTABLE+=(1)
            fi
        done <<< "$out"
    done < <(fs_configure_discoverer_names)
}

# Calls `value <id>` on the discoverer that produced candidate $1 (an index
# into the FS_CAND_* arrays) and prints the raw value on stdout. This is the
# second half of the two-phase protocol: a secret's real value is read only
# for a candidate the user actually selected, never while the picker is
# still deciding.
fs_configure_fetch_value() {
    local idx="$1" bin rawid rc out
    bin="${FS_CAND_BIN[$idx]}"
    rawid="${FS_CAND_RAWID[$idx]}"
    rc=0
    out="$("$bin" value "$rawid")" || rc=$?
    if (( rc != 0 )); then
        echo "Warning: configure: fork-sandbox-discover-${FS_CAND_NAME[$idx]} could not produce a value for '$rawid'; skipping." >&2
        return 1
    fi
    printf '%s' "$out"
}

# The result of the most recent fs_configure_select call: indices into
# whatever display array was passed to it. A global rather than a return
# value, because bash has no way to return an array from a function.
FS_CONFIGURE_SELECTED=()

# The picker. $1 and $2 name (by nameref) two same-length arrays: display
# lines and a 1/0 selectable flag per line. $3 is a header string, $4
# whether --all was given.
#
# fzf when it is on PATH and stdout is a tty; a numbered plain-text list
# otherwise. Not a tty and no --all is refused outright -- configure is
# meant to be looked at, and silently selecting everything when nobody
# could see what "everything" was would be a surprise, not a convenience.
# --all skips both UIs and takes every selectable line.
#
# An unselectable line (target "-", an informational candidate) is shown in
# both UIs so the user knows it exists, but is filtered back out of
# whatever they picked -- fzf has no per-line disable, so this is done
# after the fact rather than by refusing the keystroke.
fs_configure_select() {
    local -n _fcs_lines="$1"
    local -n _fcs_selectable="$2"
    local header="$3" all="$4"
    FS_CONFIGURE_SELECTED=()

    local n="${#_fcs_lines[@]}"
    (( n > 0 )) || return 0

    if [[ "$all" == true ]]; then
        local i
        for i in "${!_fcs_lines[@]}"; do
            [[ "${_fcs_selectable[$i]}" == 1 ]] && FS_CONFIGURE_SELECTED+=("$i")
        done
        return 0
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "Error: configure is interactive and needs a terminal to pick" >&2
        echo "candidates. Pass --all to take every candidate non-interactively" >&2
        echo "-- the mode a script driving this should use." >&2
        return 1
    fi

    if command -v fzf >/dev/null 2>&1; then
        local i input out sel_idx rest
        input=""
        for i in "${!_fcs_lines[@]}"; do
            if [[ "${_fcs_selectable[$i]}" == 1 ]]; then
                input+="$i"$'\t'"${_fcs_lines[$i]}"$'\n'
            else
                input+="$i"$'\t'"(info, not selectable) ${_fcs_lines[$i]}"$'\n'
            fi
        done
        out="$(printf '%s' "$input" | fzf --multi --delimiter=$'\t' --with-nth=2.. \
            --header="$header (TAB to select, ENTER to confirm)")" || true
        while IFS=$'\t' read -r sel_idx rest; do
            [[ -n "$sel_idx" ]] || continue
            [[ "${_fcs_selectable[$sel_idx]}" == 1 ]] || continue
            FS_CONFIGURE_SELECTED+=("$sel_idx")
        done <<< "$out"
    else
        local i reply tok idx
        echo "$header" >&2
        for i in "${!_fcs_lines[@]}"; do
            if [[ "${_fcs_selectable[$i]}" == 1 ]]; then
                printf '  %d) %s\n' "$((i + 1))" "${_fcs_lines[$i]}" >&2
            else
                printf '  -) %s (informational, not selectable)\n' "${_fcs_lines[$i]}" >&2
            fi
        done
        printf 'Pick numbers separated by spaces, "all", or empty to cancel: ' >&2
        read -r reply
        if [[ -z "$reply" ]]; then
            return 0
        fi
        if [[ "$reply" == all ]]; then
            for i in "${!_fcs_lines[@]}"; do
                [[ "${_fcs_selectable[$i]}" == 1 ]] && FS_CONFIGURE_SELECTED+=("$i")
            done
        else
            for tok in $reply; do
                [[ "$tok" =~ ^[0-9]+$ ]] || continue
                idx=$((tok - 1))
                (( idx >= 0 && idx < n )) || continue
                [[ "${_fcs_selectable[$idx]}" == 1 ]] && FS_CONFIGURE_SELECTED+=("$idx")
            done
        fi
    fi
    return 0
}

# Checked before a value is ever written. $1 is the target ("<file>:<KEY>"),
# $2 the raw value a discoverer's `value` verb printed.
fs_configure_validate_value() {
    local target="$1" value="$2" key
    if [[ "$value" =~ ^[[:space:]]*$ ]]; then
        echo "Error: configure: empty value for $target; refusing to write it." >&2
        return 1
    fi
    # A newline here would inject a second NAME=VALUE line into the env
    # file this is merged into -- a real escalation when the file is
    # k8s.env, where K8S_CONTEXT picks the cluster a run talks to. Checked
    # before fs_reject_unsafe_chars below too, so the reason is specific
    # rather than folded into that helper's generic message.
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "Error: configure: value for $target contains a newline or" >&2
        echo "carriage return. Writing it verbatim would inject a second" >&2
        echo "NAME=VALUE line into the env file. Refusing." >&2
        return 1
    fi
    fs_reject_unsafe_chars "$value" || return 1
    key="${target#*:}"
    case "$key" in
        MODEL_ENDPOINT|K8S_PROXY_UPSTREAM)
            if [[ ! "$value" =~ ^https?:// ]]; then
                echo "Error: configure: '$key' must look like a URL (http://" >&2
                echo "or https://); refusing to write it." >&2
                return 1
            fi
            ;;
    esac
    return 0
}

# Writes one target's value into its file under $config_dir, merging rather
# than clobbering: an existing NAME=VALUE line for this key is replaced in
# place (first match, the same semantics fs_read_env_value reads back), and
# every other line -- other keys, comments, blank lines -- survives
# untouched. Builds a temp file beside the target and mv's it into place,
# the atomic-write discipline used throughout this repo.
#
# A file receiving a "secret" target is created, or tightened, to mode
# 0600; tightening an existing looser file is reported on stderr rather
# than done silently, since a silent permission change is as confusing as
# silently leaving one too loose.
fs_configure_write_target() {
    local target="$1" value="$2" secret="$3"
    local file key tmp replaced=false line existing_mode=""
    file="$config_dir/${target%%:*}"
    key="${target#*:}"
    tmp="$file.part"

    if [[ -f "$file" ]]; then
        existing_mode="$("$FS_STAT" -c '%a' -- "$file")"
    fi

    : > "$tmp"
    # Tighten BEFORE the value goes in, not after. The temp file is created
    # with the ambient umask -- commonly 0644 -- and $config_dir itself is
    # world-executable, so chmodding only once the merge loop below had
    # already written the secret would leave it readable by any other local
    # user for the length of that loop. A test can only observe the final
    # mode, so this window would pass every assertion while still being a
    # real exposure.
    [[ "$secret" == secret ]] && chmod 0600 -- "$tmp"
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$replaced" == false && "$line" == "$key="* ]]; then
                printf '%s=%s\n' "$key" "$value" >> "$tmp"
                replaced=true
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$file"
    fi
    if [[ "$replaced" == false ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi

    if [[ "$secret" == secret ]]; then
        chmod 0600 -- "$tmp"
        if [[ -n "$existing_mode" && "$existing_mode" != "600" ]]; then
            echo "fork-sandbox: configure: tightening $file to mode 0600 (was $existing_mode) because it now holds a secret." >&2
        fi
    elif [[ -n "$existing_mode" ]]; then
        chmod "$existing_mode" -- "$tmp"
    fi

    mv -- "$tmp" "$file"
}

fs_configure_do_add() {
    local all="$1" dry_run="$2"
    fs_configure_gather

    local n="${#FS_CAND_ID[@]}"
    if (( n == 0 )); then
        echo "fork-sandbox: configure: no discoverers found any candidates." >&2
        return 0
    fi

    local -a fs_configure_display=()
    local i target key file existing marker
    for i in "${!FS_CAND_ID[@]}"; do
        target="${FS_CAND_TARGET[$i]}"
        marker=""
        if [[ "$target" != "-" ]]; then
            file="$config_dir/${target%%:*}"
            key="${target#*:}"
            existing="$(fs_read_env_value "$file" "$key" || true)"
            [[ -n "$existing" ]] && marker=" (replaces existing)"
        fi
        fs_configure_display+=("${FS_CAND_LABEL[$i]} [$target] -- ${FS_CAND_SOURCE[$i]}: ${FS_CAND_DISPLAY[$i]}${marker}")
    done

    fs_configure_select fs_configure_display FS_CAND_SELECTABLE \
        "configure: pick what to install" "$all" || exit 1

    if (( ${#FS_CONFIGURE_SELECTED[@]} == 0 )); then
        echo "fork-sandbox: configure: nothing selected." >&2
        return 0
    fi

    local idx value secret
    for idx in "${FS_CONFIGURE_SELECTED[@]}"; do
        target="${FS_CAND_TARGET[$idx]}"
        secret="${FS_CONFIGURE_TARGETS[$target]}"
        value="$(fs_configure_fetch_value "$idx")" || continue
        if ! fs_configure_validate_value "$target" "$value"; then
            echo "Warning: configure: dropping ${FS_CAND_ID[$idx]} (see error above)." >&2
            continue
        fi
        if [[ "$dry_run" == true ]]; then
            echo "[dry-run] would write $target from ${FS_CAND_ID[$idx]} (${FS_CAND_DISPLAY[$idx]})" >&2
            continue
        fi
        fs_configure_write_target "$target" "$value" "$secret"
        echo "fork-sandbox: configure: wrote $target from ${FS_CAND_ID[$idx]}." >&2
    done
}

# Deletes every line matching "<KEY>=" from $target's file, leaving every
# other line -- other keys, comments, blank lines -- intact. The same
# temp-file-then-mv discipline as the writer. If the file ends up empty,
# it is left in place rather than removed: deleting a file the user may
# have hand-commented would be a surprise nobody asked for.
fs_configure_remove_target() {
    local target="$1" file key tmp line existing_mode
    file="$config_dir/${target%%:*}"
    key="${target#*:}"
    [[ -f "$file" ]] || return 0
    existing_mode="$("$FS_STAT" -c '%a' -- "$file")"
    tmp="$file.part"
    : > "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] && continue
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    chmod "$existing_mode" -- "$tmp"
    mv -- "$tmp" "$file"
}

fs_configure_do_remove() {
    local all="$1" dry_run="$2"
    local -a rm_target=() rm_display=() rm_selectable=()
    local target secret file key value

    for target in "${!FS_CONFIGURE_TARGETS[@]}"; do
        secret="${FS_CONFIGURE_TARGETS[$target]}"
        file="$config_dir/${target%%:*}"
        key="${target#*:}"
        value="$(fs_read_env_value "$file" "$key" || true)"
        [[ -n "$value" ]] || continue
        rm_target+=("$target")
        if [[ "$secret" == secret ]]; then
            rm_display+=("$target = $(fs_mask_secret "$value")")
        else
            rm_display+=("$target = $value")
        fi
        rm_selectable+=(1)
    done

    if (( ${#rm_target[@]} == 0 )); then
        echo "fork-sandbox: configure --remove: nothing currently set in $config_dir." >&2
        return 0
    fi

    fs_configure_select rm_display rm_selectable \
        "configure --remove: pick what to remove" "$all" || exit 1

    if (( ${#FS_CONFIGURE_SELECTED[@]} == 0 )); then
        echo "fork-sandbox: configure --remove: nothing selected." >&2
        return 0
    fi

    # A second confirmation on top of the picker's own ENTER-to-confirm
    # gesture, because removal is destructive and --all bypasses the picker
    # entirely -- there is otherwise no point at which a non-interactive
    # removal of everything currently configured gets a chance to be
    # stopped.
    if [[ "$all" != true && "$dry_run" != true ]]; then
        local reply
        printf 'Remove %d key(s) from %s? [y/N] ' "${#FS_CONFIGURE_SELECTED[@]}" "$config_dir" >&2
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo "fork-sandbox: configure --remove: cancelled." >&2
            return 0
        fi
    fi

    local idx
    for idx in "${FS_CONFIGURE_SELECTED[@]}"; do
        target="${rm_target[$idx]}"
        if [[ "$dry_run" == true ]]; then
            echo "[dry-run] would remove $target" >&2
            continue
        fi
        fs_configure_remove_target "$target"
        echo "fork-sandbox: configure --remove: removed $target." >&2
    done
}

cmd_configure() {
    local remove=false all=false dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove) remove=true; shift ;;
            --all) all=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) cmd_configure_usage; exit 0 ;;
            *)
                echo "Error: configure: unknown option '$1'." >&2
                echo "Run 'fork-sandbox.sh configure --help' for the options." >&2
                exit 1
                ;;
        esac
    done

    mkdir -p -- "$config_dir"

    if [[ "$remove" == true ]]; then
        fs_configure_do_remove "$all" "$dry_run"
    else
        fs_configure_do_add "$all" "$dry_run"
    fi
}

# Intercepted before the flag-parsing loop below, and before config_dir's
# usual readers care what $1 is: the loop that follows treats $1 as either
# an option or the leading `<project-path>` positional, and `configure`
# would otherwise be mistaken for one or the other. This is the same place
# fork-sandbox-k8s.sh intercepts -h/--help, for the same reason.
if [[ "${1-}" == configure ]]; then
    shift
    cmd_configure "$@"
    exit 0
fi

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

branch=""
checkout_ref=""
model=""
model_option=""
model_given=false
model_unchecked=false
review_model=""
harness_spec="claude"
harness_given=false
harness=""
combined_model=""
review_harness_spec=""
review_harness_given=false
review_harness=""
review_combined_model=""
dry_run=false
claude_extra_args=""
pi_extra_args=""
sandbox_args=""
task_meta=""
context_ro=""
review_loop_arg=""
review_loop_cap=0
review_only=false
mode=run
review_base_ref=""
foreground=false
keep_session=false
no_services=false
services_trust_ref=""
prompts_dir_arg=""
refresh_at_arg=""
refresh_at_given=false
refresh_max_arg=""
k8s_mode=false
k8s_timeout=""
k8s_keep=false
k8s_outbox_dir=""
outbox_max_arg=""

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --branch)
            branch="${2:?--branch requires a name}"
            shift 2
            ;;
        --harness)
            harness_spec="${2:?--harness requires claude, pi, pi-local or codex}"
            harness_given=true
            shift 2
            ;;
        --checkout)
            checkout_ref="${2:?--checkout requires a ref}"
            shift 2
            ;;
        --review-only)
            review_only=true
            shift
            ;;
        --review-base)
            review_base_ref="${2:?--review-base requires a ref}"
            shift 2
            ;;
        --model)
            model_option="${2:?--model requires a value}"
            model_given=true
            shift 2
            ;;
        --model-unchecked)
            model_unchecked=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --review-model)
            review_model="${2:?--review-model requires a value}"
            shift 2
            ;;
        --review-harness)
            review_harness_spec="${2:?--review-harness requires claude, pi, pi-local or codex}"
            review_harness_given=true
            shift 2
            ;;
        --claude-args)
            claude_extra_args="${2:?--claude-args requires a value}"
            shift 2
            ;;
        --pi-args)
            pi_extra_args="${2:?--pi-args requires a value}"
            shift 2
            ;;
        --sandbox-args)
            sandbox_args="${2:?--sandbox-args requires a value}"
            shift 2
            ;;
        --task-meta)
            task_meta="${2:?--task-meta requires a JSON object}"
            shift 2
            ;;
        --context-ro)
            context_ro="${2:?--context-ro requires a directory}"
            shift 2
            ;;
        --review-loop)
            review_loop_arg="${2:?--review-loop requires a positive integer}"
            shift 2
            ;;
        --foreground|--no-window)
            # --no-window is the old name, kept so existing callers work.
            foreground=true
            shift
            ;;
        --keep-session)
            keep_session=true
            shift
            ;;
        --no-services)
            no_services=true
            shift
            ;;
        --services-trust-ref)
            services_trust_ref="${2:?--services-trust-ref requires a ref}"
            shift 2
            ;;
        --prompts-dir)
            prompts_dir_arg="${2:?--prompts-dir requires a directory}"
            shift 2
            ;;
        --refresh-at)
            refresh_at_arg="${2:?--refresh-at requires a fraction or a token count}"
            refresh_at_given=true
            shift 2
            ;;
        --refresh-max)
            refresh_max_arg="${2:?--refresh-max requires a non-negative integer}"
            shift 2
            ;;
        --k8s)
            k8s_mode=true
            shift
            ;;
        --timeout)
            k8s_timeout="${2:?--timeout requires a number of seconds}"
            shift 2
            ;;
        --keep)
            k8s_keep=true
            shift
            ;;
        --outbox-dir)
            k8s_outbox_dir="${2:?--outbox-dir requires a path}"
            shift 2
            ;;
        --outbox-max)
            outbox_max_arg="${2:?--outbox-max requires a size}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run 'fork-sandbox.sh --help' for the options." >&2
            exit 1
            ;;
    esac
done

project_path="${1:?Usage: fork-sandbox.sh [options] <project-path> <handoff-file>}"
handoff_file="${2:?Usage: fork-sandbox.sh [options] <project-path> <handoff-file>}"

if [[ "$review_only" == true ]]; then
    mode=review-only
    if [[ -z "$checkout_ref" ]]; then
        echo "Error: --review-only requires --checkout <ref>." >&2
        exit 1
    fi
    if [[ -n "$review_model" || "$review_harness_given" == true || -n "$review_loop_arg" ]]; then
        echo "Error: --review-only runs one review leg; name its harness and model" >&2
        echo "with --harness/--model." >&2
        exit 1
    fi
    if [[ "$refresh_at_given" == true ]]; then
        echo "Error: --refresh-at is not supported with --review-only." >&2
        exit 1
    fi
    if [[ "$k8s_mode" == true ]]; then
        echo "Error: --review-only is not supported with --k8s." >&2
        exit 1
    fi
fi

# Split only the harness prefix. pi model ids are commonly provider/model, so
# splitting every slash (or the last one) would corrupt the model that most
# needs the combined form.
if [[ "$harness_spec" == */* ]]; then
    harness="${harness_spec%%/*}"
    combined_model="${harness_spec#*/}"
else
    harness="$harness_spec"
fi

case "$harness" in
    claude|pi|pi-local|codex) ;;
    *)
        echo "Error: --harness takes 'claude', 'pi', 'pi-local' or 'codex'," >&2
        echo "not '$harness'." >&2
        exit 1
        ;;
esac

# --review-harness takes the identical harness[/model] shape as --harness,
# split the identical way, for the identical reason (an OpenRouter model id
# such as moonshotai/kimi-k3 carries its own slash).
if [[ "$review_harness_given" == true ]]; then
    if [[ "$review_harness_spec" == */* ]]; then
        review_harness="${review_harness_spec%%/*}"
        review_combined_model="${review_harness_spec#*/}"
    else
        review_harness="$review_harness_spec"
    fi

    case "$review_harness" in
        claude|pi|pi-local|codex) ;;
        *)
            echo "Error: --review-harness takes 'claude', 'pi', 'pi-local' or" >&2
            echo "'codex', not '$review_harness'." >&2
            exit 1
            ;;
    esac
fi

# pi is the cluster path's default harness (see the --k8s block below,
# which also accepts --harness claude), so --k8s defaults to it rather than
# making an operator type --harness pi on the one flag whose whole purpose
# is being the front door.
# This has to run before the harness/model validation just below -- the
# pi-needs-model check in particular -- so every downstream check sees the
# harness this run will actually use, instead of the still-"claude" value a
# bare --k8s would otherwise have at validation time. Nothing here becomes
# ambiguous once another harness lands on the cluster path: pi simply stays
# the established default.
if [[ "$k8s_mode" == true && "$harness_given" != true ]]; then
    harness="pi"
fi

if [[ -n "$combined_model" && "$model_given" == true ]]; then
    echo "Error: combined harness model '$combined_model' conflicts with" >&2
    echo "--model '$model_option'. Drop one of the two model values." >&2
    exit 1
fi
if [[ -n "$combined_model" ]]; then
    model="$combined_model"
    model_given=true
else
    model="$model_option"
fi
if [[ -n "$review_combined_model" && -n "$review_model" ]]; then
    echo "Error: combined review-harness model '$review_combined_model'" >&2
    echo "conflicts with --review-model '$review_model'. Drop one of the two" >&2
    echo "model values." >&2
    exit 1
fi
[[ -n "$review_combined_model" ]] && review_model="$review_combined_model"

if [[ "$model_unchecked" == true && "$model_given" != true ]]; then
    echo "Error: --model-unchecked requires a model, since it sends that" >&2
    echo "value verbatim, from either --model or the combined harness/model" >&2
    echo "form." >&2
    exit 1
fi

display_config_path() {
    local path="$1"
    if [[ "$path" == "$HOME"/* ]]; then
        # Literal display text, not a path for the shell to expand.
        # shellcheck disable=SC2088
        printf '~/%s' "${path#"$HOME"/}"
    else
        printf '%s' "$path"
    fi
}

# Resolves the model named by $1 (a variable name — "model" or
# "review_model"), in place, when $2 is true, against harness $3. Shared by
# --model and --review-model: both go through the same alias file and
# codex-cache lookup, so a bad --review-model is refused before the clone
# exactly as a bad --model is. $3 is the harness to resolve against rather
# than always the implement $harness, because --review-harness (when
# given) means review_model's aliases and codex cache belong to a
# different harness than model's do.
resolve_model() {
    local varname="$1" given="$2" resolve_harness="$3"
    local aliases_file="$config_dir/aliases.conf"
    local resolved="" source="" cache_file="" cache_label="" cache_rows="" current
    local -a candidates=() known=()

    [[ "$given" == true ]] || return 0
    current="${!varname}"
    if [[ "$model_unchecked" == true ]]; then
        echo "Warning: sending model '$current' verbatim; alias resolution and" >&2
        echo "validation were skipped by --model-unchecked." >&2
        return 0
    fi

    if [[ -f "$aliases_file" ]]; then
        resolved="$(awk -v harness="$resolve_harness" -v alias="$current" '
            /^[[:space:]]*($|#)/ { next }
            $1 == harness && $2 == alias { print $3; exit }
        ' "$aliases_file")"
        if [[ -n "$resolved" ]]; then
            source="$(display_config_path "$aliases_file")"
            if [[ "$resolved" != "$current" ]]; then
                echo "fork-sandbox: model '$current' -> '$resolved' ($source)" >&2
            fi
            printf -v "$varname" '%s' "$resolved"
            return 0
        fi
    fi

    case "$resolve_harness" in
        claude|pi|pi-local)
            return 0
            ;;
        codex)
            cache_file="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
            cache_label="$(display_config_path "$cache_file")"
            # No readable cache means there is nothing to validate against,
            # so the value goes through unresolved. Say so: this is the same
            # outcome --model-unchecked asks for, and that flag announces
            # itself. Staying quiet here would let a typo survive the one
            # check meant to catch it before anything is cloned.
            if ! cache_rows="$(jq -er '
                .models | arrays | .[] |
                select(.slug | type == "string") |
                [.slug, (.visibility // "")] | @tsv
            ' "$cache_file" 2>/dev/null)"; then
                echo "Warning: no readable model cache at $cache_label, so" >&2
                echo "'$current' could not be checked and is being sent" >&2
                echo "verbatim. Run codex once to populate the cache." >&2
                return 0
            fi
            mapfile -t known <<< "$cache_rows"

            mapfile -t candidates < <(printf '%s\n' "${known[@]}" |
                awk -F '\t' -v name="$current" '$1 == name { print $1 }')
            if (( ${#candidates[@]} == 0 )); then
                mapfile -t candidates < <(printf '%s\n' "${known[@]}" |
                    awk -F '\t' -v suffix="-$current" '
                        $2 == "list" && substr($1, length($1) - length(suffix) + 1) == suffix { print $1 }
                    ')
            fi
            if (( ${#candidates[@]} == 0 )); then
                mapfile -t candidates < <(printf '%s\n' "${known[@]}" |
                    awk -F '\t' -v name="$current" '
                        $2 == "list" && index($1, name) { print $1 }
                    ')
            fi
            if (( ${#candidates[@]} == 1 )); then
                resolved="${candidates[0]}"
                if [[ "$resolved" != "$current" ]]; then
                    echo "fork-sandbox: model '$current' -> '$resolved' ($cache_label)" >&2
                fi
                printf -v "$varname" '%s' "$resolved"
                return 0
            fi
            if (( ${#candidates[@]} > 1 )); then
                echo "Error: model '$current' is ambiguous for harness codex" >&2
                echo "($cache_label). Matches:" >&2
                printf '  %s\n' "${candidates[@]}" >&2
                return 1
            fi

            echo "Error: no model matching '$current' for harness codex." >&2
            echo "Known models ($cache_label):" >&2
            printf '%s\n' "${known[@]}" | awk -F '\t' '$2 == "list" { printf "  %s\n", $1 }' >&2
            echo "Pass --model-unchecked to send it anyway." >&2
            return 1
            ;;
    esac
}

resolve_model model "$model_given" "$harness" || exit 1

review_model_given=false
[[ -n "$review_model" ]] && review_model_given=true
# Against the review harness when one was given -- its aliases and codex
# cache are its own, not the implement harness's -- and against the
# implement harness otherwise, exactly as before --review-harness existed.
resolve_model review_model "$review_model_given" "${review_harness:-$harness}" || exit 1

if [[ "$harness" == "pi" && -z "$model" ]]; then
    echo "Error: --harness pi needs --model. There is no default: the model" >&2
    echo "is an OpenRouter id, such as moonshotai/kimi-k3." >&2
    exit 1
fi
if [[ "$review_harness_given" == true && "$review_harness" == "pi" && -z "$review_model" ]]; then
    echo "Error: --review-harness pi needs a model, either in the combined" >&2
    echo "harness/model form (--review-harness pi/moonshotai/kimi-k3) or via" >&2
    echo "--review-model. There is no default." >&2
    exit 1
fi

# Validated here, above both the --k8s dispatch below and the local dry-run
# exit further down, since --outbox-max applies to both paths and must fail
# before either one creates anything. fs_parse_size_bytes already prints its
# own error naming what was given, so there is nothing to add on failure.
outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
if [[ -n "$outbox_max_arg" ]]; then
    outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
fi

# --k8s dispatches the whole run to fork-sandbox-k8s.sh run, which submits it
# as a Kubernetes Job -- see the header comment above and
# docs/kubernetes-runs.md. This block is placed here, before the review-loop,
# prompt-overlay and local dry-run handling below, on purpose: every one of
# those belongs to the LOCAL sandbox path, and --k8s must refuse (or ignore
# outright) every flag among them rather than let this script's own
# machinery run and then throw its result away. The harness and model are
# already resolved above, exactly as a local run resolves them, so this
# reuses that work rather than re-implementing it.
if [[ "$k8s_mode" == true ]]; then
    if [[ "$harness" != "pi" && "$harness" != "claude" ]]; then
        echo "Error: --k8s only supports --harness pi or claude. A cluster run" >&2
        echo "is pi talking to a model proxy that holds the provider key, or" >&2
        echo "claude talking through a per-run proxy that swaps in the" >&2
        echo "operator's own token; pi-local and codex have no sandboxed path" >&2
        echo "in the cluster (not yet supported)." >&2
        exit 1
    fi
    if [[ "$harness" == "claude" && -z "$model" ]]; then
        echo "Error: --k8s --harness claude needs --model. A local claude run" >&2
        echo "can fall back to the claude CLI's own default, but the pod's" >&2
        echo "entrypoint has no such fallback -- pass a Claude Code model" >&2
        echo "name, such as opus or sonnet." >&2
        exit 1
    fi

    # Flags that name local-sandbox machinery a cluster run has no
    # equivalent of AT ALL, and never will: bubblewrap arguments, the claude
    # CLI, per-run docker-compose services and their trust anchor, and the
    # detached tmux session this script normally launches.
    if [[ -n "$sandbox_args" ]]; then
        echo "Error: --sandbox-args is not supported with --k8s. It passes flags" >&2
        echo "to claude-sandboxed, the bubblewrap wrapper -- a Kubernetes pod has" >&2
        echo "no bubblewrap to pass them to." >&2
        exit 1
    fi
    if [[ -n "$claude_extra_args" ]]; then
        echo "Error: --claude-args is not supported with --k8s. It passes flags" >&2
        echo "to the claude CLI, and the pod's own claude invocation (when" >&2
        echo "--harness claude) is fixed -- there is no flag yet to extend it." >&2
        exit 1
    fi
    if [[ "$no_services" == true ]]; then
        echo "Error: --no-services is not supported with --k8s. There is no" >&2
        echo "per-run services mechanism on the cluster path to skip in the" >&2
        echo "first place." >&2
        exit 1
    fi
    if [[ -n "$services_trust_ref" ]]; then
        echo "Error: --services-trust-ref is not supported with --k8s, for the" >&2
        echo "same reason as --no-services: there is no per-run services" >&2
        echo "mechanism on the cluster path to trust or distrust." >&2
        exit 1
    fi
    if [[ "$keep_session" == true ]]; then
        echo "Error: --keep-session is not supported with --k8s. It holds open" >&2
        echo "the detached tmux session a local run starts on the end of the" >&2
        echo "run; a --k8s run execs fork-sandbox-k8s.sh directly and never" >&2
        echo "creates one. A cluster run already blocks in this shell until it" >&2
        echo "finishes, which is what --foreground asks for locally, so that" >&2
        echo "flag is accepted (and redundant) rather than refused." >&2
        exit 1
    fi

    # Flags that name a real, wanted capability the cluster path has not been
    # built to carry yet -- a later round of work, not a permanent no.
    if [[ -n "$checkout_ref" ]]; then
        echo "Error: --checkout is not yet supported with --k8s. submit always" >&2
        echo "pushes the origin repo's current HEAD into the pod; starting a" >&2
        echo "cluster run from another ref needs submit to take one, which it" >&2
        echo "does not yet." >&2
        exit 1
    fi
    if [[ -n "$pi_extra_args" ]]; then
        echo "Error: --pi-args is not yet supported with --k8s." >&2
        echo "fork-sandbox-k8s.sh run has no flag yet to carry extra pi" >&2
        echo "arguments into the pod." >&2
        exit 1
    fi
    if [[ -n "$task_meta" ]]; then
        echo "Error: --task-meta is not yet supported with --k8s. It is folded" >&2
        echo "into the local run log, and a --k8s run does not append to that" >&2
        echo "log at all yet." >&2
        exit 1
    fi
    if [[ -n "$prompts_dir_arg" ]]; then
        echo "Error: --prompts-dir is not yet supported with --k8s. The overlay" >&2
        echo "is layered onto a generated per-leg prompt, and the cluster path" >&2
        echo "sends the handoff file straight through with no generated prompt" >&2
        echo "to layer it onto." >&2
        exit 1
    fi
    # Flag coherence comes before harness rules: whether the combination
    # even makes sense at all, regardless of --harness, is checked first,
    # exactly the same wording (and rule) as the general non-k8s path
    # applies at the equivalent point below -- this script's own dry-run
    # approval, above, must not approve something a real --k8s run refuses.
    if [[ -n "$review_model" && -z "$review_loop_arg" ]]; then
        echo "Error: --review-model only applies to review legs and requires" >&2
        echo "--review-loop." >&2
        exit 1
    fi
    if [[ "$harness" == "pi" ]]; then
        if [[ "$review_harness_given" == true ]]; then
            echo "Error: --review-harness is not supported with --k8s --harness" >&2
            echo "pi. The pod's review loop always runs pi against the model" >&2
            echo "proxy; use --review-model to give it a different model, not" >&2
            echo "--review-harness." >&2
            exit 1
        fi
    else
        # harness == claude here -- pi-local and codex were already refused
        # above, before this point.
        if [[ "$review_harness_given" == true && "$review_harness" != "pi" ]]; then
            echo "Error: --review-harness $review_harness is not supported with" >&2
            echo "--k8s --harness claude. The pod's review loop is pi-only;" >&2
            echo "pass --review-harness pi." >&2
            exit 1
        fi
        if [[ -n "$review_loop_arg" && "$review_harness_given" != true ]]; then
            echo "Error: --k8s --harness claude --review-loop needs" >&2
            echo "--review-harness pi and an OpenRouter review model, e.g." >&2
            echo "--review-harness pi --review-model moonshotai/kimi-k3." >&2
            exit 1
        fi
        # review_harness_given == true && review_harness == "pi" here, the
        # only combination left. Line ~1393, which runs unconditionally
        # before this whole --k8s block, already refused --review-harness pi
        # with no model, so review_model is guaranteed non-empty already.
    fi
    if [[ "$refresh_at_given" == true ]]; then
        echo "Error: --refresh-at is not supported with --k8s. It is measured by" >&2
        echo "a hook fork-sandbox-inbox-hook.sh installs into the local" >&2
        echo "sandbox's claude session; the pod runs a different entrypoint with" >&2
        echo "no such hook." >&2
        exit 1
    fi
    if [[ -n "$refresh_max_arg" ]]; then
        echo "Error: --refresh-max is not supported with --k8s, for the same" >&2
        echo "reason as --refresh-at: there is no context-refresh mechanism on" >&2
        echo "the cluster path to cap." >&2
        exit 1
    fi

    # Same two security checks the local path applies below, applied here
    # before this run is handed to fork-sandbox-k8s.sh: this script is meant
    # to be blanket-approved, so it is the security boundary regardless of
    # which path a run takes. The handoff becomes the pod's prompt to a model
    # with internet access, and project_path is what gets pushed into the
    # pod, so both need the same constraint here that the local path enforces
    # for the same reason -- see fs_require_scratch_handoff and
    # fs_require_src_project in fork-sandbox-lib.sh.
    fs_require_scratch_handoff "$handoff_file" || exit 1
    fs_require_src_project "$project_path" || exit 1

    # Unlike fork-sandbox-k8s.sh run, this script generates a branch name
    # when one is not given -- the same convenience --branch has locally.
    # Naming it the way `submit` itself does when --branch is omitted
    # (k8s-<timestamp>) keeps a cluster run's auto-named branches
    # recognizable as cluster runs at a glance, and means `run`'s own
    # --branch requirement is always satisfied by the time this execs: run
    # needs the name up front to poll, fetch and clean up by, and there is
    # no point teaching it to generate one only for this one caller.
    branch="${branch:-k8s-$(date +%Y%m%d-%H%M%S)}"

    k8s_argv=(run)
    [[ "$dry_run" == true ]] && k8s_argv+=(--dry-run)
    [[ -n "$k8s_timeout" ]] && k8s_argv+=(--timeout "$k8s_timeout")
    [[ "$k8s_keep" == true ]] && k8s_argv+=(--keep)
    # --review-loop's own validation (a positive integer) is left to
    # fork-sandbox-k8s.sh's cmd_submit, which run below execs into -- it
    # applies the identical check, before any kubectl call, so there is
    # nothing to duplicate here.
    [[ -n "$review_loop_arg" ]] && k8s_argv+=(--review-loop "$review_loop_arg")
    [[ -n "$review_model" ]] && k8s_argv+=(--review-model "$review_model")
    [[ -n "$k8s_outbox_dir" ]] && k8s_argv+=(--outbox-dir "$k8s_outbox_dir")
    # Forwarded as the raw string, not the byte count already parsed above:
    # fork-sandbox-k8s.sh does its own parsing, so there is one source of
    # truth per process rather than a cross-process byte count to keep in
    # sync.
    [[ -n "$outbox_max_arg" ]] && k8s_argv+=(--outbox-max "$outbox_max_arg")
    [[ -n "$context_ro" ]] && k8s_argv+=(--context-ro "$context_ro")
    k8s_argv+=(--harness "$harness" --branch "$branch" --model "$model" "$project_path" "$handoff_file")

    exec "$script_dir/fork-sandbox-k8s.sh" "${k8s_argv[@]}"
fi

if [[ -n "$k8s_timeout" || "$k8s_keep" == true || -n "$k8s_outbox_dir" ]]; then
    echo "Error: --timeout, --keep and --outbox-dir only apply with --k8s," >&2
    echo "which passes them on to fork-sandbox-k8s.sh run. Add --k8s, or drop" >&2
    echo "the flag." >&2
    exit 1
fi

# Validated here, above the dry-run exit, rather than beside the rest of the
# review-loop setup below: --dry-run exists to say whether a flag combination
# is good, so it must not approve one the real run refuses.
if [[ -n "$review_loop_arg" ]]; then
    if [[ ! "$review_loop_arg" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: --review-loop takes a positive integer — the maximum" >&2
        echo "number of review-then-fix iterations — not '$review_loop_arg'." >&2
        exit 1
    fi
    review_loop_cap="$review_loop_arg"
fi
if [[ -n "$review_model" && "$review_loop_cap" == "0" ]]; then
    echo "Error: --review-model only applies to review legs and requires" >&2
    echo "--review-loop." >&2
    exit 1
fi
if [[ "$review_harness_given" == true && "$review_loop_cap" == "0" ]]; then
    echo "Error: --review-harness only applies to review legs and requires" >&2
    echo "--review-loop." >&2
    exit 1
fi
if [[ "$review_only" == true ]]; then
    review_loop_cap=1
fi

# --harness pi-local is sealed: no network at all, which is the property a
# caller picks it for. If its review legs ran under a networked harness,
# the same clone's contents -- the code a sealed run was chosen to keep
# local -- would go to that harness's model provider, silently defeating
# the seal. Refuse the combination by name, the same way this script
# refuses every other combination that would quietly widen what a sandbox
# can reach, rather than honor it and let the seal's whole point leak out
# through a flag nobody thought to cross-check. The reverse is fine: a
# networked implement harness reviewed by --review-harness pi-local adds
# no exposure the run did not already have.
if [[ "$review_harness_given" == true && "$harness" == "pi-local" \
    && "$review_harness" != "pi-local" ]]; then
    echo "Error: --harness pi-local seals this run -- no network at all -- and" >&2
    echo "--review-harness $review_harness is networked. Its review leg would" >&2
    echo "send the clone's contents to $review_harness's model provider," >&2
    echo "defeating the seal this run was chosen for. If a networked second" >&2
    echo "opinion is genuinely wanted, run it as a separate fork-sandbox.sh" >&2
    echo "invocation against the branch this run returns." >&2
    exit 1
fi

# --refresh-at: refused outright, by name, on every harness but claude --
# see the "A run that refreshes itself" section above for why. Refused only
# when GIVEN explicitly, so the 0.5 default stays silent on a plain pi or
# codex run rather than erroring on every launch that never mentioned it.
if [[ "$refresh_at_given" == true && "$harness" != "claude" ]]; then
    echo "Error: --refresh-at only works with --harness claude. The context" >&2
    echo "threshold is measured by a hook installed into the claude session;" >&2
    echo "the other harnesses have no hook system to measure with, and this" >&2
    echo "is not built for them yet." >&2
    exit 1
fi
if [[ -n "$refresh_max_arg" && "$harness" != "claude" ]]; then
    echo "Error: --refresh-max only applies with --harness claude, alongside" >&2
    echo "--refresh-at." >&2
    exit 1
fi
refresh_at="0"
[[ "$harness" == "claude" ]] && refresh_at="${refresh_at_arg:-0.5}"
if [[ ! "$refresh_at" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: --refresh-at takes a fraction (0-1) of the context window, an" >&2
    echo "absolute token count above 1, or 0 to disable it -- not '$refresh_at'." >&2
    exit 1
fi
# awk, not bash arithmetic, for the ">0" test: $refresh_at can be a fraction
# ("0.5"), and bash's (( )) only understands integers.
refresh_enabled=0
awk -v v="$refresh_at" 'BEGIN{exit !(v>0)}' && refresh_enabled=1
if [[ -n "$refresh_max_arg" && "$refresh_enabled" == "0" ]]; then
    echo "Error: --refresh-max requires --refresh-at (which is on by default," >&2
    echo "so this only happens with an explicit --refresh-at 0). With refresh" >&2
    echo "disabled there is no continuation loop for it to cap." >&2
    exit 1
fi
refresh_max=6
if [[ -n "$refresh_max_arg" ]]; then
    if [[ ! "$refresh_max_arg" =~ ^[0-9]+$ ]]; then
        echo "Error: --refresh-max takes a non-negative integer -- the number of" >&2
        echo "continuation legs that may follow the first -- not '$refresh_max_arg'." >&2
        exit 1
    fi
    refresh_max="$refresh_max_arg"
fi
refresh_context_window=""
refresh_threshold_tokens=""
if (( refresh_enabled )); then
    # A one-line, one-place guess, kept here rather than duplicated in the
    # hook: a model whose name carries "[1m]" gets the 1,000,000-token beta
    # window; everything else gets the standard 200,000.
    # FORK_SANDBOX_CONTEXT_WINDOW overrides the guess outright, and
    # --refresh-at <tokens> (an absolute count above 1) sidesteps it
    # entirely, since the comparison below then needs no window at all.
    refresh_context_window="${FORK_SANDBOX_CONTEXT_WINDOW:-}"
    if [[ -z "$refresh_context_window" ]]; then
        case "${model,,}" in
            *'[1m]'*) refresh_context_window=1000000 ;;
            *)        refresh_context_window=200000 ;;
        esac
    fi
    if awk -v v="$refresh_at" 'BEGIN{exit !(v<=1)}'; then
        refresh_threshold_tokens="$(awk -v f="$refresh_at" -v w="$refresh_context_window" \
            'BEGIN{printf "%d", f*w}')"
    else
        refresh_threshold_tokens="$(awk -v f="$refresh_at" 'BEGIN{printf "%d", f}')"
    fi
fi

# The resolved model values are what --dry-run prints, so they have to clear
# the shell-safety check before it prints them. The full sweep over every
# generated-runner value still runs below; this is the same check applied
# early to dry-run's own subject, so a model the real run refuses cannot get
# a green light here first.
fs_reject_unsafe_chars "$model" "$review_model" "$review_harness" || exit 1

# --- Prompt overlay -------------------------------------------------------
# A machine-local directory of prompt fragments, layered onto each generated
# prompt below the environment blocks and above that leg's own task text.
# This script ships the mechanism only -- no fragment for any model lives in
# this repo. See docs/prompt-overlays.md.
#
# Resolved here, above the dry-run exit, for the same reason the model is:
# --dry-run exists to say what a real run would get, so it has to see the
# same overlay a real run would apply.
#
# --prompts-dir names a directory for this run alone. Naming one that does
# not exist is refused outright: silently applying nothing would look
# exactly like a run that used it, and that gap is the failure class this
# project keeps paying to avoid. Left unset, the default directory is
# read only if it happens to exist -- absent is the common case, and it is
# silent on purpose, so a machine with no overlay configured is completely
# unaffected.
if [[ -n "$prompts_dir_arg" ]]; then
    prompt_overlay_dir="$prompts_dir_arg"
    prompt_overlay_explicit=true
else
    prompt_overlay_dir="${FORK_SANDBOX_PROMPTS_DIR:-$config_dir/prompts}"
    prompt_overlay_explicit=false
fi
fs_reject_unsafe_chars "$prompt_overlay_dir" || exit 1

if [[ "$prompt_overlay_explicit" == true && ! -d "$prompt_overlay_dir" ]]; then
    echo "Error: --prompts-dir '$prompt_overlay_dir' does not exist." >&2
    exit 1
fi

# Every leg this run generates a prompt for: the implement leg always, and
# the review and fix legs only under --review-loop. review_loop_cap is
# resolved above, before this section, so a dry run knows this exactly as
# well as a real run does, and reports only the legs that would exist.
prompt_overlay_legs=(implement)
(( review_loop_cap > 0 )) && prompt_overlay_legs+=(review fix)

# Per-leg relative fragment paths (composition order, newline-joined) and
# per-leg content hashes, keyed by leg name. Empty on a machine with no
# overlay directory -- the common case -- which is what makes
# fs_emit_prompt_overlay a no-op below. Declared even when unused so later
# code can index them unconditionally.
declare -A prompt_overlay_fragments=()
declare -A prompt_overlay_sha256=()
prompt_overlay_rev=""
prompt_overlay_matched=false
# Every path considered, across every applicable leg -- used only to build
# the "matched nothing" warning below.
prompt_overlay_all_candidates=()

if [[ -d "$prompt_overlay_dir" ]]; then
    # A model id commonly holds a slash (openai/gpt-4o), and a slash in a
    # filename is a path separator -- replacing every one with '_' both
    # produces a sane file name and removes the only character that could
    # turn a model id into a path outside this directory.
    prompt_overlay_model_frag=""
    [[ -n "$model" ]] && prompt_overlay_model_frag="${model//\//_}"

    for prompt_overlay_leg in "${prompt_overlay_legs[@]}"; do
        # General first, specific last: a later fragment can override an
        # earlier one. The root-level trio applies to every leg -- a
        # fragment saying how this model should write a commit is as true
        # in the fix leg as in the implement leg -- and the leg-scoped pair
        # narrows it for this leg alone. No glob or family matching --
        # deliberately deferred, see docs/prompt-overlays.md.
        prompt_overlay_candidates=("all.md" "harness/$harness.md")
        [[ -n "$prompt_overlay_model_frag" ]] \
            && prompt_overlay_candidates+=("model/$prompt_overlay_model_frag.md")
        prompt_overlay_candidates+=("$prompt_overlay_leg/all.md")
        [[ -n "$prompt_overlay_model_frag" ]] \
            && prompt_overlay_candidates+=(
                "$prompt_overlay_leg/model/$prompt_overlay_model_frag.md")

        prompt_overlay_all_candidates+=("${prompt_overlay_candidates[@]}")

        prompt_overlay_leg_fragments=()
        prompt_overlay_leg_paths=()
        for prompt_overlay_rel in "${prompt_overlay_candidates[@]}"; do
            if [[ -f "$prompt_overlay_dir/$prompt_overlay_rel" ]]; then
                prompt_overlay_leg_fragments+=("$prompt_overlay_rel")
                prompt_overlay_leg_paths+=("$prompt_overlay_dir/$prompt_overlay_rel")
            fi
        done

        if (( ${#prompt_overlay_leg_fragments[@]} )); then
            prompt_overlay_matched=true
            prompt_overlay_fragments[$prompt_overlay_leg]="$(
                IFS=$'\n'; printf '%s' "${prompt_overlay_leg_fragments[*]}")"
            # A content fingerprint of exactly the bytes about to be
            # inserted for this leg, independent of git state -- the one
            # thing that ties a run to what it actually saw, whether or not
            # the directory is version controlled or clean.
            prompt_overlay_sha256[$prompt_overlay_leg]="$(
                cat -- "${prompt_overlay_leg_paths[@]}" | sha256sum | cut -d' ' -f1)"
        fi
    done

    if [[ "$prompt_overlay_matched" == false && "$prompt_overlay_explicit" == true ]]; then
        # The directory exists but matched nothing, in any leg. Warn only
        # when the caller named it with --prompts-dir: they asked for an
        # overlay and got none, which is the request-that-quietly-does-nothing
        # this mechanism exists to avoid.
        #
        # The DEFAULT directory is silent here on purpose. Holding fragments
        # for one model and running another is the normal way to use this --
        # a machine with only model/<some-small-model>.md would otherwise warn
        # on every run of every other model, which is noise, and noise is how
        # a warning stops being read. --dry-run already reports the fragments
        # a run would get, so the fact stays available where it is wanted.
        echo "Warning: prompt overlay directory '$prompt_overlay_dir' matched" >&2
        echo "no fragment. Looked for:" >&2
        for prompt_overlay_rel in "${prompt_overlay_all_candidates[@]}"; do
            echo "  $prompt_overlay_dir/$prompt_overlay_rel" >&2
        done
    elif [[ "$prompt_overlay_matched" == true ]]; then
        # dir and rev are facts about the run, not about any one leg, so one
        # rev covers every leg's fragments.
        if [[ "$(git -C "$prompt_overlay_dir" rev-parse --is-inside-work-tree \
                2>/dev/null)" == "true" ]]; then
            prompt_overlay_head="$(git -C "$prompt_overlay_dir" rev-parse HEAD 2>/dev/null || true)"
            if [[ -n "$prompt_overlay_head" ]]; then
                # A dirty working tree means the commit named below is not
                # what actually rendered. Recording the plain rev anyway
                # would attribute this run's outcome to a commit that did not
                # produce it -- worse than recording no rev at all, because
                # it looks trustworthy. The check is scoped to this directory
                # alone, not the whole repo, so an unrelated change elsewhere
                # in a larger checkout (a dotfiles repo, say) does not mark it
                # dirty.
                if [[ -n "$(git -C "$prompt_overlay_dir" status --porcelain -- . 2>/dev/null)" ]]; then
                    prompt_overlay_rev="${prompt_overlay_head}-dirty"
                else
                    prompt_overlay_rev="$prompt_overlay_head"
                fi
            fi
        fi
    fi
fi

checkout_sha=""
base_sha=""
return_base_sha=""
if [[ "$review_only" == true ]]; then
    if [[ ! -d "$project_path" ]]; then
        echo "Error: project path '$project_path' is not a directory" >&2
        exit 1
    fi
    review_only_origin_repo="$(fs_repo_toplevel "$project_path")"
    if ! checkout_sha="$(cd "$review_only_origin_repo" && git rev-parse --verify --quiet "$checkout_ref^{commit}")"; then
        echo "Error: --checkout '$checkout_ref' does not name a commit in $review_only_origin_repo." >&2
        exit 1
    fi
    return_base_sha="$checkout_sha"
    if [[ -n "$review_base_ref" ]]; then
        if ! base_sha="$(cd "$review_only_origin_repo" && git rev-parse --verify --quiet "$review_base_ref^{commit}")"; then
            echo "Error: --review-base '$review_base_ref' does not name a commit in $review_only_origin_repo." >&2
            exit 1
        fi
    elif ! base_sha="$(cd "$review_only_origin_repo" && git merge-base "$checkout_ref" HEAD)"; then
        echo "Error: could not compute the merge-base of '$checkout_ref' and HEAD." >&2
        exit 1
    fi
    if [[ "$base_sha" == "$checkout_sha" ]]; then
        echo "Error: nothing to review between $base_sha and $checkout_ref" >&2
        exit 1
    fi
fi

if [[ "$dry_run" == true ]]; then
    printf 'harness=%s\nmodel=%s\n' "$harness" "$model"
    [[ -z "$review_model" ]] || printf 'review_model=%s\n' "$review_model"
    [[ "$review_harness_given" != true ]] || printf 'review_harness=%s\n' "$review_harness"
    printf 'prompt_overlay_dir=%s\n' "$prompt_overlay_dir"
    for prompt_overlay_leg in "${prompt_overlay_legs[@]}"; do
        prompt_overlay_leg_csv="${prompt_overlay_fragments[$prompt_overlay_leg]:-}"
        prompt_overlay_leg_csv="${prompt_overlay_leg_csv//$'\n'/,}"
        printf 'prompt_overlay_fragments[%s]=%s\n' \
            "$prompt_overlay_leg" "$prompt_overlay_leg_csv"
    done
    printf 'prompt_overlay_rev=%s\n' "$prompt_overlay_rev"
    printf 'refresh_at=%s\nrefresh_max=%s\n' "$refresh_at" "$refresh_max"
    printf 'outbox_max_bytes=%s\n' "$outbox_max_bytes"
    if [[ "$review_only" == true ]]; then
        printf 'mode=review-only\ncheckout=%s\nbase_sha=%s\nrange=%s...%s\n' \
            "$checkout_ref" "$base_sha" "$base_sha" "$checkout_ref"
    fi
    if (( refresh_enabled )); then
        printf 'refresh_context_window=%s\nrefresh_threshold_tokens=%s\n' \
            "$refresh_context_window" "$refresh_threshold_tokens"
    fi
    exit 0
fi

if [[ ! -d "$project_path" ]]; then
    echo "Error: project path '$project_path' is not a directory" >&2
    exit 1
fi
if [[ ! -f "$handoff_file" ]]; then
    echo "Error: handoff file '$handoff_file' not found" >&2
    exit 1
fi
if [[ ! -s "$handoff_file" ]]; then
    echo "Error: handoff file '$handoff_file' is empty. It is the session's" >&2
    echo "whole prompt, so an empty one gives the session nothing to do." >&2
    exit 1
fi

# This script is meant to be blanket-approved, so IT is the security boundary
# (docs/permissions.md), and three of its arguments could otherwise be
# turned into primitives the approval must not hand over:
#
#   - The handoff is READ INTO THE PROMPT of a model with internet
#     access, so an unconstrained path is arbitrary-file-read plus
#     exfiltration. Handoffs live in the scratch dir, where sessions
#     stage them on purpose.
#   - The project is CLONED INTO the sandbox, same channel. Repos under
#     ~/src are the working material; nothing else is.
#   - --sandbox-args passes through to claude-sandboxed, where --bind-ro
#     would mount any host path — ~/.ssh, say — into that same sandbox.
#     Only --unpin-egress may pass; the script adds every bind it needs
#     itself.
handoff_real="$("$FS_REALPATH" -m "$handoff_file")"
if [[ "$handoff_real" != /var/tmp/claude-scratch/* && "$handoff_real" != /tmp/claude-scratch/* ]]; then
    echo "Error: handoff files must live under /var/tmp/claude-scratch/ (or the" >&2
    echo "/tmp/claude-scratch compat symlink) — got '$handoff_real'. The handoff" >&2
    echo "becomes the prompt of a session with internet access, so this path is a" >&2
    echo "security boundary, not a tidiness rule. Stage the document there and" >&2
    echo "rerun." >&2
    exit 1
fi
# forks/ is excluded: it holds what approved scripts mktemp — run dirs, stage
# dirs, and the codex credential staging dir. A handoff there would read a
# file the machinery wrote (the credential above all) into the prompt of a
# session with internet access. Handoffs go in the scratch root.
if [[ "$handoff_real" == /var/tmp/claude-scratch/forks/* || "$handoff_real" == /tmp/claude-scratch/forks/* ]]; then
    echo "Error: handoff files must not live under the forks/ machinery" >&2
    echo "directory — got '$handoff_real'. forks/ holds run dirs, staging" >&2
    echo "dirs and credential files that approved scripts create; reading one" >&2
    echo "into an internet-connected prompt is the exfiltration this check" >&2
    echo "exists to stop. Stage the handoff in the scratch root itself." >&2
    exit 1
fi
project_real="$("$FS_REALPATH" -m "$project_path")"
if [[ "$project_real" != "$HOME"/src/* && "$project_real" != "$HOME/src" ]]; then
    echo "Error: the project must live under ~/src — got '$project_real'." >&2
    echo "An unattended agent gets the whole clone, and for most harnesses it" >&2
    echo "gets internet too, so which repos may be handed over is a security" >&2
    echo "boundary. Work from a checkout under ~/src, or launch" >&2
    echo "claude-sandboxed by hand for something else." >&2
    exit 1
fi
# --context-ro is the reviewed home for the one extra bind a caller may
# need: context a host-side script gathered for the session to read. The
# path constraint is what keeps it from becoming the --bind-ro primitive
# the --sandbox-args check below refuses: /var/tmp/claude-scratch/forks/ holds
# staging directories that approved scripts mktemp on purpose, and nothing
# else — no $HOME, no ~/.ssh, no secrets.
if [[ -n "$context_ro" ]]; then
    context_ro_real="$("$FS_REALPATH" -m "$context_ro")"
    if [[ "$context_ro_real" != /var/tmp/claude-scratch/forks/* ]]; then
        echo "Error: --context-ro must name a directory under" >&2
        echo "/var/tmp/claude-scratch/forks/ — got '$context_ro_real'. An" >&2
        echo "unattended agent can read the bind, and for most harnesses it has" >&2
        echo "internet too, so which paths may be handed over is a security" >&2
        echo "boundary. Stage the context in a mktemp directory there and rerun." >&2
        exit 1
    fi
    if [[ ! -d "$context_ro_real" ]]; then
        echo "Error: --context-ro directory '$context_ro_real' does not exist." >&2
        exit 1
    fi
    context_ro="$context_ro_real"
fi

# A pi-local run is sealed, and --unpin-egress — the one value permitted below
# — is the one flag agent-sandboxed refuses outright. So there is nothing this
# option can legally carry for that harness; say so here rather than let it fail
# after the clone.
if [[ -n "$sandbox_args" && "$harness" == "pi-local" ]]; then
    echo "Error: --sandbox-args does nothing for --harness pi-local. The only" >&2
    echo "value allowed here is --unpin-egress, and a sealed sandbox refuses" >&2
    echo "it: there is no network to unpin. Drop the flag." >&2
    exit 1
fi
if [[ -n "$sandbox_args" && "$sandbox_args" != "--unpin-egress" ]]; then
    echo "Error: --sandbox-args may only be '--unpin-egress'. Anything else —" >&2
    echo "--bind-ro above all — widens what the sandbox can read, and this" >&2
    echo "script is approved to run unsupervised. Add other binds to the" >&2
    echo "script itself, where they get reviewed." >&2
    exit 1
fi
if [[ ! -x "$formatter" ]]; then
    echo "Error: $formatter is missing or not executable." >&2
    echo "Run install.sh in the fork-sandbox repo." >&2
    exit 1
fi

# --review-loop is a count of iterations, so it must be a whole number and at
# least one. Refuse 0 rather than read it as "no loop": a caller who means that
# leaves the flag off, and a silently accepted 0 makes a typo look like a run
# that reviewed itself. Checked here, with the other flag checks, so a bad
# value fails before anything is created.
# --review-loop and --review-model are validated above, before the dry-run
# exit, so that --dry-run cannot approve a combination the real run refuses.
# The review leg follows the code-review-portable skill, which is also what
# gets bound into the sandbox below. Without it there is no review method to
# point the leg at, and a review leg improvising one is not the reviewed
# quality pass the flag promises. Fail now rather than after the clone.
review_skill_src="$HOME/.claude/skills/code-review-portable"
if (( review_loop_cap > 0 )) && [[ ! -d "$review_skill_src" ]]; then
    echo "Error: --review-loop needs the code-review-portable skill, which is" >&2
    echo "the review leg's method, and $review_skill_src" >&2
    echo "is not there. Run install.sh in the fork-sandbox repo." >&2
    exit 1
fi

fs_require_sandbox_wrapper

# The run dir, the codex auth dir and everything else this run stages live
# under the one scratch root's forks/ directory. Create it now; the
# UserPromptSubmit hook makes it too, but a script cannot assume the hook ran.
mkdir -p /var/tmp/claude-scratch/forks

# One block per harness, each resolving its tool and filling the same
# variables. Nothing after this knows which harness it is looking at, so a
# fourth means writing another arm rather than threading one more
# condition through the rest of the script. Everything resolves here,
# before anything is created, so a missing piece fails now rather than in
# a detached tmux session an hour later.
#
#   harness_bin       the tool, as an absolute path. The tmux runner's
#                     PATH is not this script's, so a bare name is not
#                     enough.
#   harness_version   what that binary calls itself, recorded so a result
#                     can be read months later.
#   harness_env_file  a NAME=VALUE file for the run's own secrets, or
#                     empty. claude-sandboxed requires 0600 and refuses to
#                     put a value on any command line.
#   harness_flags     extra sandbox-wrapper flags — binds and PATH.
#   harness_cmd       with harness_exec, the command --exec runs. Without
#                     it, the tool's own flags, which follow the work dir.
#                     Empty for claude, which claude-sandboxed starts by
#                     itself.
#   harness_exec      1 when the harness is a command claude-sandboxed has
#                     to be told to run, 0 when the wrapper starts the
#                     tool itself and takes its flags instead.
#   harness_sandbox_bin
#                     the sandbox wrapper, when it is not claude-sandboxed.
#                     agent-sandboxed for a sealed local-model run: it
#                     drives the same sandbox backend, sealed and with the
#                     model bridged in, and it takes the same bind flags.
#   run_formatter     what renders the output stream, or empty when the
#                     tool does not speak stream-json.
#   usage_source      which reader can total this run's tokens.
harness_bin=""
harness_version=""
harness_env_file=""
harness_sandbox_bin=""
run_formatter="$formatter"
usage_source="$harness"
pi_session_dir=""

# --review-harness (below) needs the whole block below resolved a second
# time, for a second harness, without the two runs seeing or clobbering
# each other's state -- see fs_resolve_harness just above its case
# statement for how.

# --claude-args names the claude CLI, which no other harness starts.
if [[ -n "$claude_extra_args" && "$harness" != "claude" ]]; then
    echo "Error: --claude-args passes flags to the claude CLI, which a" >&2
    echo "$harness run never starts. Drop it, or drop --harness $harness." >&2
    exit 1
fi

# --pi-args names pi, which only the pi harnesses start.
if [[ -n "$pi_extra_args" && "$harness" != "pi" && "$harness" != "pi-local" ]]; then
    echo "Error: --pi-args passes flags to pi, which a $harness run" >&2
    echo "never starts. Drop it, or use --harness pi / pi-local." >&2
    exit 1
fi
pi_extra_argv=()
if [[ -n "$pi_extra_args" ]]; then
    read -r -a pi_extra_argv <<< "$pi_extra_args"
fi

# Where the sandbox's userland comes from. It decides whether the agent CLI
# and node are bound in from this host or supplied by the sandbox itself, and
# every harness arm below needs the answer. Ask before the clone, so a missing
# backend is one line here rather than a failure after a repo has been copied.
fs_resolve_backend "$script_dir" || exit 1
fs_backend_capabilities "$FS_BACKEND_BIN"

# For the run record only. In image mode there is no host binary to ask for a
# version, so name where the toolchain came from instead of inventing one.
# This reads a backend's own variable, which is a leak -- but into a log line,
# never into a decision, and a backend that does not set it says "unnamed".
image_toolchain_version="image:${FORK_SANDBOX_CONTAINER_IMAGE:-unnamed}"

# Resolves one harness (claude, pi, pi-local or codex) into a run's worth
# of command-building state -- the same case statement a single-harness run
# always ran, wrapped so it can run TWICE in one invocation: once for the
# implement harness, and again for --review-harness, without either call
# seeing or overwriting the other's result. $1 is the harness name, $2 its
# model (already resolved by resolve_model), $3 a prefix ("impl" or "rev")
# naming where the output lands.
#
# Every output is a bash nameref bound to "${prefix}_<name>", so the case
# arms below -- moved here unchanged from the single-harness block this
# replaced -- read and write the exact same bare names (harness_bin,
# harness_cmd, ...) they always did; only the declarations here say which
# prefixed global those names actually resolve to. $model is the one thing
# the old arms read from outside their own scope, so it becomes the local
# $rh_model parameter instead -- everything else below is untouched,
# comments included.
fs_resolve_harness() {
    local rh_harness="$1" rh_model="$2" prefix="$3"

    local -n harness_bin="${prefix}_harness_bin"
    local -n harness_version="${prefix}_harness_version"
    local -n harness_env_file="${prefix}_harness_env_file"
    # shellcheck disable=SC2178  # -n aliases an array here; shellcheck
    # cannot see through the dynamic target name to know that.
    local -n harness_flags="${prefix}_harness_flags"
    # shellcheck disable=SC2178
    local -n harness_cmd="${prefix}_harness_cmd"
    # shellcheck disable=SC2034  # read back via fs_build_sandbox_cmd's own
    # nameref, not by name here -- same false positive as above.
    local -n harness_exec="${prefix}_harness_exec"
    local -n harness_sandbox_bin="${prefix}_harness_sandbox_bin"
    local -n run_formatter="${prefix}_run_formatter"
    local -n usage_source="${prefix}_usage_source"
    # Not part of the old bare-name contract -- these two just record the
    # inputs this call resolved from, so fs_build_sandbox_cmd (which builds
    # a command from "${prefix}_*" alone) can find the harness name and
    # model without a caller having to pass them again.
    # Read back via a differently-named nameref in fs_build_sandbox_cmd,
    # invisible to shellcheck across the function boundary -- same false
    # positive as every nameref in this function.
    # shellcheck disable=SC2034
    local -n out_prefix_harness="${prefix}_harness"
    # shellcheck disable=SC2034
    local -n out_prefix_model="${prefix}_model"

    harness_bin=""
    harness_version=""
    harness_env_file=""
    harness_flags=()
    harness_cmd=()
    harness_exec=0
    harness_sandbox_bin=""
    run_formatter="$formatter"
    usage_source="$rh_harness"
    # shellcheck disable=SC2034  # read by fs_build_sandbox_cmd, across the
    # same nameref-name boundary shellcheck cannot see through.
    out_prefix_harness="$rh_harness"
    # shellcheck disable=SC2034
    out_prefix_model="$rh_model"

    case "$rh_harness" in
    claude)
    # claude-sandboxed resolves and starts claude itself, and has done
    # since before there was more than one harness. Leave it that way:
    # its credential handling is bound up with that path.
    if [[ "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        harness_bin="$(command -v claude 2>/dev/null || true)"
        [[ -n "$harness_bin" ]] || harness_bin="$HOME/.local/bin/claude"
        if [[ -x "$harness_bin" ]]; then
            harness_version="$("$harness_bin" --version 2>/dev/null | head -1 || true)"
        fi
    else
        # The image carries claude; claude-sandboxed invokes it by name.
        harness_bin="claude"
        harness_version="$image_toolchain_version"
    fi
    ;;

pi)
    harness_env_file="$config_dir/pi.env"
    if [[ ! -f "$harness_env_file" ]]; then
        echo "Error: $harness_env_file not found. A pi run reads its" >&2
        echo "OpenRouter key from that file, one NAME=VALUE per line, and" >&2
        echo "claude-sandboxed requires it to be mode 0600 and owned by you:" >&2
        echo "  install -m 600 /dev/null $harness_env_file" >&2
        echo "  \$EDITOR $harness_env_file   # OPENROUTER_API_KEY=..." >&2
        exit 1
    fi

    # Resolving pi, its node and the tree to bind is shared with
    # agent-sandboxed, so it lives in the lib.
    fs_resolve_pi || exit 1
    pi_real="$FS_PI_REAL"
    pi_bin_dir="$FS_PI_BIN_DIR"
    pi_root="$FS_PI_ROOT"
    pi_node="$FS_PI_NODE"

    # Under a host toolchain: /usr is mounted already, anything else needs its
    # own bind, and the bin dir goes on PATH so a repo with no .nvmrc still
    # has a node and an npm. These flags go in before the .nvmrc ones, and
    # claude-sandboxed puts the last --prepend-path first, so a project that
    # pins its own node still wins.
    #
    # Under an image toolchain fs_resolve_pi leaves both empty: there is
    # nothing on this host to bind, and the image's own /usr/local/bin is
    # already on the sandbox PATH.
    if [[ -n "$pi_root" && "$pi_root" != "/usr" ]]; then
        harness_flags+=(--bind-ro "$pi_root")
    fi
    if [[ -n "$pi_bin_dir" ]]; then
        harness_flags+=(--prepend-path "$pi_bin_dir")
    fi

    harness_bin="$pi_real"
    if [[ "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        harness_version="$("${FS_PI_ARGV0[@]}" --version 2>/dev/null | head -1 || true)"
    else
        harness_version="$image_toolchain_version"
    fi
    # pi reads its prompt on stdin, like every other harness. --skill comes
    # later, with the review kit; --mode json and -p come last, from the runner.
    harness_cmd=("${FS_PI_ARGV0[@]}" --provider openrouter --model "$rh_model")
    if (( ${#pi_extra_argv[@]} )); then
        harness_cmd+=("${pi_extra_argv[@]}")
    fi
    harness_exec=1
    # pi speaks plain text, not stream-json, so there is nothing for the
    # formatter to render. The log keeps the raw output instead.
    run_formatter=""
    fs_reject_unsafe_chars "$harness_env_file" "$pi_real" "$pi_node" "$pi_root" "$pi_bin_dir"
    ;;

pi-local)
    # pi against a model you host, in a sandbox with no network at all.
    # agent-sandboxed is the wrapper: it calls sandbox-backend-bwrap
    # sealed, adds the socket bridge that carries the one endpoint in, and
    # resolves pi, generates pi's config and starts pi itself. So this arm
    # names no command and no key — there is nothing to authenticate to —
    # and what follows the clone dir is pi's own flags.
    harness_sandbox_bin="$(command -v agent-sandboxed 2>/dev/null || true)"
    if [[ -z "$harness_sandbox_bin" ]]; then
        harness_sandbox_bin="$HOME/.claude/scripts/agent-sandboxed"
    fi
    if [[ ! -x "$harness_sandbox_bin" ]]; then
        echo "Error: cannot find agent-sandboxed, which runs the sealed" >&2
        echo "local-model sandbox. Run install.sh in the fork-sandbox repo." >&2
        exit 1
    fi
    # Fail before the clone, not after it: agent-sandboxed would refuse the
    # same thing, but by then this script has staged a run directory, cloned
    # the repo and started the services. --model does not stand in for the
    # config file: it names the model, and there is no flag here that can
    # carry an endpoint.
    if [[ ! -f "$config_dir/model.env" ]]; then
        echo "Error: --harness pi-local needs an endpoint to talk to. It is a" >&2
        echo "fact about this machine's network, so it lives in a config file:" >&2
        echo "  mkdir -p $config_dir" >&2
        echo "  echo 'MODEL_ENDPOINT=http://your-host:8001/v1' > $config_dir/model.env" >&2
        exit 1
    fi

    # Only for the version record: agent-sandboxed resolves pi again for
    # itself, and binds it, so nothing here has to.
    fs_resolve_pi || exit 1
    harness_bin="$FS_PI_REAL"
    if [[ "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        harness_version="$("${FS_PI_ARGV0[@]}" --version 2>/dev/null | head -1 || true)"
    else
        harness_version="$image_toolchain_version"
    fi
    if [[ -n "$rh_model" ]]; then
        harness_flags+=(--model "$rh_model")
    fi
    # harness_cmd lands after the clone dir, where agent-sandboxed passes
    # argv through to pi -- harness_flags would hit agent-sandboxed's own
    # option parser instead.
    if (( ${#pi_extra_argv[@]} )); then
        harness_cmd+=("${pi_extra_argv[@]}")
    fi
    run_formatter=""
    fs_reject_unsafe_chars "$harness_sandbox_bin" "$FS_PI_REAL" "$FS_PI_NODE"
    # The run's token counts come from pi's session file either way, so the
    # reader is pi's, whichever endpoint served the run.
    usage_source="pi"
    ;;

codex)
    # Every path this arm might resolve, emptied up front: in image mode none
    # of them is set, and they all reach fs_reject_unsafe_chars at the end.
    codex_bin=""; codex_real=""; codex_bin_dir=""; codex_root=""; codex_node=""

    # nvm is a shell function, so a non-interactive PATH usually has no
    # node and no codex. Fall back to where a global npm install under nvm
    # puts it; the last match of the glob wins, which is the newest version
    # for the v1x/v2x names nvm creates.
    #
    # Only under a host toolchain. When the sandbox brings its own userland
    # the host's codex could not execute inside, so there is nothing to look
    # for here and the image supplies it.
    if [[ "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        codex_bin="$(command -v codex 2>/dev/null || true)"
        if [[ -z "$codex_bin" ]]; then
            for cand in "$HOME"/.nvm/versions/node/*/bin/codex; do
                [[ -x "$cand" ]] && codex_bin="$cand"
            done
        fi
        if [[ -z "$codex_bin" ]]; then
            echo "Error: cannot find codex. Install it with:" >&2
            echo "  npm install -g @openai/codex" >&2
            echo "or, on Arch, the openai-codex package." >&2
            exit 1
        fi
    fi
    # Same CODEX_HOME the model cache is read from above. Honouring it in one
    # place and not the other let a run validate its model against one codex
    # home and then authenticate from a different one, so the model check --
    # whose whole job is to fail before the clone -- could pass against an
    # account that is not the one the run uses.
    codex_auth_src="${CODEX_HOME:-$HOME/.codex}/auth.json"
    if [[ ! -f "$codex_auth_src" ]]; then
        echo "Error: $codex_auth_src not found. Sign in on the host first:" >&2
        echo "  codex login" >&2
        exit 1
    fi

    # The sandbox cannot refresh, so check the lifetime here and say so in
    # words, rather than let the run die inside codex as a 401. The token
    # is a JWT: take its payload, undo base64url, and read exp. A payload
    # that will not decode leaves the check silent rather than blocking a
    # run over a format guess.
    codex_exp=""
    codex_jwt="$(jq -r '.tokens.access_token // empty' "$codex_auth_src" \
        | cut -d. -f2 | tr '_-' '/+')"
    if [[ -n "$codex_jwt" ]]; then
        while (( ${#codex_jwt} % 4 )); do codex_jwt+="="; done
        codex_exp="$(printf '%s' "$codex_jwt" | base64 -d 2>/dev/null \
            | jq -r '.exp // empty' 2>/dev/null)"
    fi
    if [[ "$codex_exp" =~ ^[0-9]+$ ]]; then
        codex_mins_left=$(( codex_exp / 60 - $(date +%s) / 60 ))
        if (( codex_mins_left <= 0 )); then
            echo "Error: the codex access token expired. The sandbox cannot" >&2
            echo "refresh it — that is deliberate, because the refresh token is" >&2
            echo "single-use and a sandbox refresh would log the host out. Run:" >&2
            echo "  codex login" >&2
            exit 1
        elif (( codex_mins_left < 60 )); then
            echo "Warning: the codex access token expires in ${codex_mins_left}m;" >&2
            echo "a longer run than that will die when it does." >&2
        fi
    fi

    # How codex gets into the sandbox, which is the one thing the toolchain
    # answer changes here. Everything above -- the credential, its expiry --
    # is data and is the same either way.
    if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
        # The image's codex, found on the sandbox PATH. Nothing to resolve,
        # nothing to bind, and no host node to name: the image's codex runs on
        # the image's node.
        codex_argv0=(codex)
        harness_bin="codex"
        harness_version="$image_toolchain_version"
    else
        # An npm codex is a node script symlinked out of bin/ into
        # lib/node_modules, so the bin dir taken as written and the script
        # taken as resolved name two different trees; bind the one directory
        # that covers both. The sandbox's $HOME is a fresh tmpfs, so an
        # install under ~/.nvm is invisible there without this. A distro
        # package is a native binary under /usr, which is mounted already and
        # needs none of it.
        codex_real="$(readlink -f "$codex_bin")"
        codex_bin_dir="$(readlink -f "$(dirname "$codex_bin")")"
        codex_root="$(dirname "$codex_bin_dir")"
        if [[ "$(head -c 2 "$codex_real" 2>/dev/null)" == '#!' ]] \
            && head -1 "$codex_real" | grep -q node; then
            # The shebang is `env node`, so running the script by name would take
            # whatever node the sandbox PATH happens to offer -- the project's
            # pinned one, from a different major version. Name codex's own node
            # instead, and let PATH stay the project's business.
            codex_node="$codex_bin_dir/node"
            if [[ ! -x "$codex_node" ]]; then
                codex_node="$(command -v node 2>/dev/null || true)"
            fi
            if [[ -z "$codex_node" || ! -x "$codex_node" ]]; then
                echo "Error: found codex at $codex_bin but no node to run it with." >&2
                exit 1
            fi
            # One bind covers the lot: under nvm, bin/node and lib/node_modules/...
            # are both inside the version directory. Refuse the case it does not
            # cover rather than guess at a second mount -- a guess that binds too
            # little fails deep inside node, as a missing package.
            if [[ "$codex_real" != "$codex_root"/* ]]; then
                echo "Error: codex resolves to $codex_real, which is outside its" >&2
                echo "node install at $codex_root. This binds that one tree into" >&2
                echo "the sandbox, so an install split across two would lose its" >&2
                echo "dependencies. Install codex with npm -g under nvm." >&2
                exit 1
            fi
        fi

        # /usr is mounted already; anything else needs its own bind. The bin dir
        # goes on PATH so a repo with no .nvmrc still has a node. These flags go
        # in before the .nvmrc ones, and claude-sandboxed puts the last
        # --prepend-path first, so a project that pins its own node still wins.
        if [[ "$codex_root" != "/usr" ]]; then
            harness_flags+=(--bind-ro "$codex_root")
        fi
        harness_flags+=(--prepend-path "$codex_bin_dir")

        # Whether codex is run through its own node or straight, every later use
        # is the same words, so settle it once.
        codex_argv0=("$codex_real")
        [[ -n "$codex_node" ]] && codex_argv0=("$codex_node" "$codex_real")

        harness_bin="$codex_real"
        harness_version="$("${codex_argv0[@]}" --version 2>/dev/null | head -1 || true)"
    fi
    # The credential is built by the runner, into a file this script only
    # names. See the runner for why it is made there and not here.
    codex_auth_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-codex.XXXXXX)"
    chmod 700 "$codex_auth_dir"
    harness_env_file="$codex_auth_dir/env"

    #   --json                 events as JSONL, which is where the token
    #                          counts are; codex reports them nowhere else.
    #   --dangerously-bypass…  codex ships its own Landlock and seccomp
    #                          sandbox, which cannot nest inside bwrap's
    #                          user namespace. Ours is the boundary here,
    #                          and two half-working ones are worse than
    #                          one that holds.
    #   --ignore-rules         codex otherwise loads execpolicy .rules
    #                          files FROM THE CHECKOUT. The clone is
    #                          untrusted content by design, and a rules
    #                          file in it steers the tool. No container
    #                          closes that; not reading them does.
    #   -                      read the prompt from stdin, said out loud
    #                          rather than left to a default.
    harness_cmd=("${codex_argv0[@]}" exec --json
                 --dangerously-bypass-approvals-and-sandbox --ignore-rules)
    if [[ -n "$rh_model" ]]; then
        harness_cmd+=(--model "$rh_model")
    fi
    harness_cmd+=(-)
    # shellcheck disable=SC2034  # read by fs_build_sandbox_cmd via its own
    # nameref -- see fs_resolve_harness's declarations, above.
    harness_exec=1
    # codex speaks its own JSONL, not claude's stream-json, so the
    # formatter has nothing it can render.
    run_formatter=""
    fs_reject_unsafe_chars "$codex_bin" "$codex_auth_src" "$codex_auth_dir" \
        "$codex_real" "$codex_bin_dir" "$codex_root" "$codex_node"
    ;;
    esac

    [[ -n "$harness_version" ]] || harness_version="unknown"
    fs_reject_unsafe_chars "$harness_bin" "$harness_version"
}

fs_resolve_harness "$harness" "$model" impl
# Compatibility copy: the run record (run.env, the generated runner) and
# the review-loop accounting below still read these bare names -- moving
# THEM onto "impl_"/"rev_" is per-leg accounting, a later commit's job, not
# this refactor's. harness_flags/harness_cmd/harness_exec are NOT copied
# back: nothing reads them bare any more, since fs_build_sandbox_cmd below
# reads "${prefix}_harness_flags" etc. directly, and the review-kit skill
# loop just below was updated to write into "impl_harness_cmd" for the
# same reason. The "impl_*" names only exist as the namerefs above wrote
# them into being, so shellcheck has no literal assignment to point at --
# SC2154 here is a false positive of the same dynamic-name pattern
# fs_resolve_harness itself uses.
# shellcheck disable=SC2154
{
    harness_bin="$impl_harness_bin"
    harness_version="$impl_harness_version"
    harness_env_file="$impl_harness_env_file"
    harness_sandbox_bin="$impl_harness_sandbox_bin"
    run_formatter="$impl_run_formatter"
    usage_source="$impl_usage_source"
}

# --review-harness resolves a second time here, before anything is
# created, for the same reason the implement harness resolves above: a
# missing credential or binary fails now, in one message, rather than an
# hour into the run when the first review leg starts and finds its
# OpenRouter key or its codex login missing. Without this, an
# implement-pi + review-claude run would do the whole (possibly
# expensive) coding leg, then die at the very first review leg with
# nothing to show for it -- precisely the failure "fail before the clone"
# exists to prevent for the implement harness alone.
if [[ "$review_harness_given" == true ]]; then
    fs_resolve_harness "$review_harness" "$review_model" rev
fi

# Check every value that goes into the generated runner or the run record
# before anything is created, so a bad name cannot leave a clone behind on
# the way out.
fs_reject_unsafe_chars "$project_path" "$handoff_file" "$branch" "$checkout_ref" \
    "$model" "$review_model" "$review_harness" "$claude_extra_args" "$sandbox_args"

# --task-meta never enters the generated runner -- it is written straight to
# a file in the run dir -- so the check it needs is JSON validity, not shell
# safety. Compacting to one line here also normalizes whatever whitespace
# the caller's JSON carried. Validate before anything is created, so a typo
# fails at once.
if [[ -n "$task_meta" ]]; then
    if ! task_meta="$(printf '%s' "$task_meta" \
        | jq -ce 'if type == "object" then . else halt_error end' 2>/dev/null)"; then
        echo "Error: --task-meta must be one valid JSON object, e.g." >&2
        echo "  --task-meta '{\"kind\":\"implement\",\"difficulty\":3}'" >&2
        echo "See sandbox-run-log.py's header for the recommended fields." >&2
        exit 1
    fi
fi
if [[ "$review_only" == true && -z "$task_meta" ]]; then
    task_meta='{"kind":"review"}'
fi

origin_repo="$(fs_repo_toplevel "$project_path")"
branch="${branch:-sandbox-$(date +%Y%m%d-%H%M%S)}"

fs_reject_unsafe_chars "$origin_repo" "$branch"
fs_check_branch_free "$origin_repo" "$branch"

# The clone starts at the origin repo's HEAD, so that is what the session's
# commits are measured against later. --checkout moves that start point, and
# moves the base with it, so a session that reviews a pull request head and
# commits nothing still leaves the repo exactly as it was. Resolve the ref
# here, in the user's own repo: a clone carries refs/heads and refs/tags only,
# so a commit held under a private ref namespace has no name inside it.
# A repo with no commits has nothing to clone and nothing to branch from.
if [[ -n "$checkout_ref" ]]; then
    if [[ "$review_only" != true ]]; then
        if ! checkout_sha="$(cd "$origin_repo" && \
            git rev-parse --verify --quiet "$checkout_ref^{commit}")"; then
            echo "Error: --checkout '$checkout_ref' does not name a commit in" >&2
            echo "$origin_repo. The ref is resolved there, not in the clone, so" >&2
            echo "fetch it into that repo first." >&2
            exit 1
        fi
        base_sha="$checkout_sha"
        return_base_sha="$checkout_sha"
    fi
    # The review range base is used to build review prompts, but the return
    # path must measure changes from the commit the clone actually checked
    # out. In particular, an unchanged review-only clone must be removable
    # even when the reviewed range has pre-existing commits.
elif ! base_sha="$(cd "$origin_repo" && git rev-parse HEAD 2>/dev/null)"; then
    echo "Error: '$origin_repo' has no commits yet, so there is nothing to" >&2
    echo "clone. Make a first commit and try again." >&2
    exit 1
else
    checkout_sha="$base_sha"
    return_base_sha="$base_sha"
fi

fs_warn_if_dirty "$project_path" "$origin_repo"

# Everything about this run lives under one directory. The clone sits inside
# it, and only the clone is bind-mounted into the sandbox, so the log, the
# handoff and the summary are all out of the sandbox's reach.
run_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
fs_reject_unsafe_chars "$run_dir"
# The task metadata rides beside the run, where sandbox-run-log.py picks it
# up at the end. The run dir is never bound into the sandbox, so the session
# cannot see or edit it.
if [[ -n "$task_meta" ]]; then
    printf '%s\n' "$task_meta" > "$run_dir/task-meta.json"
fi
# The prompt overlay's provenance, beside the run for the same reason: what
# was applied has to be queryable later, not just present in the rendered
# prompts. dir and rev are facts about the run; fragments and sha256 vary
# per leg, since review/all.md need not be what fix/all.md is. Written only
# when at least one leg matched something -- a run with no prompts
# directory, or one that matched nothing anywhere, writes no file, and
# sandbox-run-log.py reads that as "no prompt_overlay key", exactly like a
# run made before this mechanism existed. A leg that matched nothing (or
# never ran, absent --review-loop) gets no key under "legs" either.
if [[ "$prompt_overlay_matched" == true ]]; then
    prompt_overlay_legs_json="{}"
    for prompt_overlay_leg in "${prompt_overlay_legs[@]}"; do
        prompt_overlay_leg_frags="${prompt_overlay_fragments[$prompt_overlay_leg]:-}"
        [[ -n "$prompt_overlay_leg_frags" ]] || continue
        prompt_overlay_leg_frags_arr=()
        readarray -t prompt_overlay_leg_frags_arr <<<"$prompt_overlay_leg_frags"
        prompt_overlay_leg_json="$(jq -n \
            --arg sha256 "${prompt_overlay_sha256[$prompt_overlay_leg]}" \
            '{fragments: $ARGS.positional, sha256: $sha256}' \
            --args "${prompt_overlay_leg_frags_arr[@]}")"
        prompt_overlay_legs_json="$(jq \
            --argjson leg "$prompt_overlay_leg_json" \
            --arg name "$prompt_overlay_leg" \
            '.[$name] = $leg' <<<"$prompt_overlay_legs_json")"
    done
    jq -n \
        --arg dir "$prompt_overlay_dir" \
        --arg rev "$prompt_overlay_rev" \
        --argjson legs "$prompt_overlay_legs_json" \
        '{dir: $dir, rev: (if $rev == "" then null else $rev end), legs: $legs}' \
        > "$run_dir/prompt-overlay.json"
fi
# Name the parent 'clone', not 'repo'. A directory called 'repo' sitting one
# level above the checkout reads like the repository root, and a session that
# builds an absolute path by hand drops the last segment and reads nothing.
# The error it gets back says "No such file or directory", which looks like a
# missing file rather than a wrong path.
clone_dir="$run_dir/clone/$(basename "$origin_repo")"
mkdir -p "$run_dir/clone"

echo "Cloning '$origin_repo' for the sandbox..." >&2
# Take the run dir back out if the clone fails, so a bad branch name does
# not leave an empty directory behind under the scratch root.
if ! fs_make_clone "$origin_repo" "$branch" "$clone_dir" \
    "${checkout_ref:+${checkout_sha:-$base_sha}}"; then
    rm -rf "$run_dir"
    exit 1
fi
fs_collect_alternates "$clone_dir"

# Node toolchain and dependencies, for a repo that has them (fs_node_provision
# in the lib explains both halves).
fs_node_provision "$origin_repo" "$clone_dir"

# Per-run services and provision-ro binds, for a repo that opts in with
# .agents/sandbox-services/ (or the legacy .claude/sandbox-services/). Both are
# host-side or origin-reading actions
# driven by committed config, so they run only when that config is trusted:
# not with --no-services, and — when a trust ref is named, as a review of an
# untrusted pull request head does — only if the checked-out ref did not
# change the hook relative to that ref.
services_enabled=0        # docker compose services are stood up
provision_enabled=0       # provision-ro binds are honored
services_hook_dir="$(fs_services_dir "$clone_dir")"
if ! $no_services && [[ -d "$services_hook_dir" ]]; then
    services_trusted=1
    if [[ -n "$checkout_ref" && -z "$services_trust_ref" ]]; then
        # --checkout names an arbitrary ref, which may be untrusted — a fetched
        # pull-request head, say. A services hook is host-side code, and this
        # script is blanket-approved, so the boundary is here, not a prompt: a
        # checked-out ref does not get its hook run without a trust anchor.
        echo "Warning: --checkout names an unanchored ref, so its per-run" >&2
        echo "services hook is NOT run — a hook is host-side code and the ref" >&2
        echo "may be untrusted. Pass --services-trust-ref <trusted-base> to" >&2
        echo "enable it, or --no-services to skip this quietly." >&2
        services_trusted=0
    elif [[ -n "$services_trust_ref" ]]; then
        # Run git in the ORIGIN, never the clone: the clone's git config is
        # writable by the sandbox. Three-dot, so only what the checked-out ref
        # changed relative to the trust ref counts — a hook change made on the
        # base branch that the ref never touched does not disable it.
        # git diff --quiet exits 0 for unchanged, 1 for changed, and higher
        # when it could not evaluate the refs at all. Only 1 means what the
        # warning says. A bad ref must be loud instead: the caller named an
        # anchor on purpose, and a typo silently disabling services would
        # change the run while blaming the checked-out ref for it.
        trust_diff_rc=0
        # Diff BOTH contract paths, not only the resolved one: a hostile ref
        # could ADD a hook at the path the base lacks, and that must count as a
        # change. .agents/sandbox-services/ is current, .claude/ the fallback.
        (cd "$origin_repo" && git diff --quiet \
            "${services_trust_ref}...${checkout_sha}" \
            -- .agents/sandbox-services/ .claude/sandbox-services/) || trust_diff_rc=$?
        if (( trust_diff_rc == 1 )); then
            echo "Warning: the checked-out ref changes the sandbox-services" >&2
            echo "contract (.agents/ or .claude/sandbox-services/) relative to the" >&2
            echo "trusted base, so per-run services and" >&2
            echo "provisioning are disabled for this run. A services hook is" >&2
            echo "host-side code; a modified one from an untrusted ref is not run." >&2
            services_trusted=0
        elif (( trust_diff_rc != 0 )); then
            echo "Error: git could not evaluate --services-trust-ref" >&2
            echo "'$services_trust_ref' against '$checkout_sha' (git exited" >&2
            echo "$trust_diff_rc; its error is above). Fix the ref — is it" >&2
            echo "fetched? — and rerun." >&2
            exit 1
        fi
    fi
    if (( services_trusted )); then
        provision_enabled=1
        if [[ -f "$services_hook_dir/sandbox-services.sh" ]]; then
            if command -v docker >/dev/null; then
                services_enabled=1
            else
                echo "Warning: the sandbox-services contract is present but docker" >&2
                echo "is not on PATH; running without per-run services." >&2
            fi
        fi
    fi
fi

# Provision-ro binds (read-only origin paths into the clone), gated by the same
# trust decision as the services. fs_provision_ro fills FS_PROVISION_RO_FLAGS.
if (( provision_enabled )); then
    fs_provision_ro "$origin_repo" "$clone_dir"
fi

# A services compose must pull its images, never build them: a `build:` runs
# Dockerfile steps from the checked-out clone on the HOST daemon, with
# unrestricted network — content the trust check above does not cover, since it
# diffs only the sandbox-services dir and a hostile ref can edit a Dockerfile
# alone. Refuse the mechanism rather than run it. The clone is still trusted
# committed state at this point (the sandbox has not started), so checking it
# here equals checking the copy taken below.
#
# This scans the hook dir only. A repo using the overlay variant keeps its base
# compose at the repo root, and may name a repo-root overlay too (referenced
# from its own hook script); both are outside this scan, exactly as the base
# compose always was. The protection there is the trusted, trust-diffed hook not
# invoking a build — not this grep.
if (( services_enabled )); then
    if grep -rqE '^[[:space:]]*build[[:space:]]*:' "$services_hook_dir" \
        --include='*.yml' --include='*.yaml' 2>/dev/null; then
        echo "Warning: the services compose contains a 'build:' key, so per-run" >&2
        echo "services are disabled for this run. Images must be pulled, never" >&2
        echo "built: a build runs Dockerfile steps from the checked-out clone on" >&2
        echo "the host, outside the sandbox and outside the trust check. See the" >&2
        echo "contract in skills/fork-sandbox/SKILL.md." >&2
        services_enabled=0
    fi
fi

# Stand the services up: create the sockets directory, copy the hook out of the
# clone before the sandbox can touch it, and name a compose project the orphan
# sweep can recognize. The copy matters — the clone is trusted committed state
# now but becomes untrusted the moment the sandbox writes to it, and `down`
# runs after that. The run dir is never bound into the sandbox, so a copy here
# stays trusted for both up and down.
services_script=""
sockets_dir=""
services_project=""
if (( services_enabled )); then
    sockets_dir="$run_dir/services/sockets"
    mkdir -p "$sockets_dir"
    cp -a "$services_hook_dir" "$run_dir/services/hook"
    services_script="$run_dir/services/hook/sandbox-services.sh"
    chmod +x "$services_script" 2>/dev/null || true
    # Compose project names must be lowercase alphanumeric and hyphens. The run
    # dir basename already begins 'claude-fork-sandbox', which is the
    # distinctive prefix the orphan sweep matches on. Do NOT prepend another
    # 'claude-': a broad 'claude-*' sweep would also match unrelated user
    # compose projects (any `docker compose` run in a 'claude-*' directory) and
    # delete their volumes.
    services_rd_base="$(basename "$run_dir")"
    services_project="${services_rd_base,,}"
    services_project="${services_project//[^a-z0-9-]/-}"
    # Case-folding collapses mktemp's case-sensitive uniqueness, so two
    # concurrent runs could fold to one project name — and one run's `down -v`
    # would then destroy the other's volumes mid-session. A checksum of the
    # original basename keeps folded names distinct. The orphan sweep in the
    # generated runner derives live names the same way; keep the two matched.
    services_project="$services_project-$(printf '%s' "$services_rd_base" | cksum | cut -d' ' -f1)"
    fs_reject_unsafe_chars "$sockets_dir" "$services_script" "$services_project"
fi

# The self-review skills and the read-only script toolbox, so an unattended
# session can end its work the way an interactive one does: run
# commit-then-review, which drives review-context.sh. Two skills go in.
# commit-then-review is the wrapper. code-review-portable is the review engine
# itself, a harness-agnostic stand-in for the built-in /code-review — which is
# compiled into claude and so exists on no other harness; a handoff for pi,
# pi-local or codex asks for it by name, while claude keeps its built-in. The
# skills are instructions; the scripts are whatever your toolbox holds, and any
# that want a credential fail closed in the sandbox, because the ones they reach
# for — a forge token, gh, slack — are not in the environment. Keep secrets out
# of that directory: it is bound read-only into every run. A pi run does carry
# one key, its own OpenRouter key, and no script here uses that.
# The global CLAUDE.md stays out on purpose — a sandboxed run gets the
# project's CLAUDE.md from its own clone.
#
# Every harness gets the binds. pi implements the Agent Skills standard and its
# own documentation names ~/.claude/skills as a source, so the same directory
# serves both; the difference is that claude discovers a skill and pi has to be
# handed it with --skill, because the sandbox gives it a fresh $HOME with no
# settings file to read.
# Both destinations sit INSIDE $HOME/.claude, which claude-sandboxed also
# remaps wholesale to its per-run state dir. That works only because a backend
# applies binds shallowest destination first, so the remap goes down before the
# kit lands in it -- see the mount-order section of docs/sandbox-backend.md,
# and tests/sandbox-backend-bind-order-test.sh, which holds both backends to
# it. Ordered the other way the remap covers the kit and the run comes up
# without it: no error, no missing file, just a --review-loop whose review leg
# has no method and a --prepend-path aimed at nothing. Keep new binds under
# $HOME/.claude aware of that.
review_kit_flags=()
# Where code-review-portable ends up bound, for the review leg's prompt to
# point at. The bind puts it at the same absolute path inside the sandbox, so
# the path recorded here is the one the leg reads.
review_skill_dir=""
for skill_name in commit-then-review code-review-portable; do
    skill_dir="$HOME/.claude/skills/$skill_name"
    [[ -d "$skill_dir" ]] || continue
    fs_reject_unsafe_chars "$skill_dir"
    review_kit_flags+=(--bind-ro "$skill_dir")
    [[ "$skill_name" == "code-review-portable" ]] && review_skill_dir="$skill_dir"
    # Written into "impl_harness_cmd" (and "rev_harness_cmd", when
    # --review-harness names its own pi/pi-local) directly -- the arrays
    # fs_resolve_harness left behind for each -- not a bare "harness_cmd":
    # fs_build_sandbox_cmd reads the prefixed array, and there is no bare
    # one to read any more. Checked independently per harness, since an
    # implement/review pair can mix a pi-family harness with one that
    # isn't: a pi-local implement reviewed by claude needs the skill flag
    # on its own leg but not the other's, and the reverse just as much.
    if [[ "$harness" == "pi" || "$harness" == "pi-local" ]]; then
        impl_harness_cmd+=(--skill "$skill_dir")
    fi
    if [[ "$review_harness_given" == true \
        && ( "$review_harness" == "pi" || "$review_harness" == "pi-local" ) ]]; then
        rev_harness_cmd+=(--skill "$skill_dir")
    fi
done
if [[ -d "$HOME/.claude/scripts" ]]; then
    review_kit_flags+=(--bind-ro "$HOME/.claude/scripts"
                       --prepend-path "$HOME/.claude/scripts")
    # The farm is per-file symlinks into a checkout (install.sh's doing),
    # so binding the farm alone mounts dangling links. Bind the checkout's
    # scripts directory too, at its real path, so the links resolve. One
    # readlink suffices: every script resolves into the one directory.
    first_link="$(find "$HOME/.claude/scripts" -maxdepth 1 -type l -print -quit)"
    if [[ -n "$first_link" ]]; then
        link_target_dir="$(dirname "$(readlink -f "$first_link")")"
        if [[ -d "$link_target_dir" && "$link_target_dir" != "$HOME/.claude/scripts" ]]; then
            review_kit_flags+=(--bind-ro "$link_target_dir")
        fi
    fi
fi

# The operator inbox: the one channel that reaches a run after it has started.
# The host writes files into it with fork-sandbox-say.sh; the sandbox sees it
# read-only, and a read-only bind reflects host writes live, so an addendum
# written a minute from now is visible inside without remounting anything.
#
# This adds NO writable surface. The bind is read-only, and the run dir already
# lives under /var/tmp/claude-scratch/forks/, which is the same constraint
# --context-ro enforces on the one caller-chosen bind — so it is a path this
# script may legally mount.
inbox_dir="$run_dir/inbox"
mkdir -p "$inbox_dir"
chmod 755 "$inbox_dir"
fs_reject_unsafe_chars "$inbox_dir"

# Delivery on the claude harness is by hook, so the session needs no
# cooperation: a PostToolUse hook puts an unread addendum next to the very next
# tool result, and a Stop hook refuses to let the session finish while one is
# unread. Both the hook script and the settings file naming it must be readable
# INSIDE the sandbox, and the run dir is not bound — only the inbox is. So both
# go in the inbox, as dotfiles: the hook and fork-sandbox-say.sh both work in
# '*.md', so a leading dot is invisible to them, and it keeps the sandbox's
# bind list at one entry instead of three. Nothing inside can rewrite them —
# the bind is read-only — and nothing outside writes the inbox except
# fork-sandbox-say.sh, which only ever generates a '<epoch>-<nn>.md' name.
inbox_hook=""
inbox_settings=""
# One hook and one settings file cover every claude leg this run has, not
# just the implement one: --review-harness claude (with a non-claude
# implement harness) still starts a claude session for its review leg, and
# that leg needs the same delivery mechanism the implement leg would have
# gotten. fs_build_sandbox_cmd only wires --settings/--include-hook-events
# into a build whose OWN harness is claude, so creating these unconditionally
# whenever either harness is claude, rather than only the implement one,
# is what makes a claude review leg (implement pi, say) receive addenda at
# all instead of running the "no hook" harness it happens not to be.
if [[ "$harness" == "claude" || "$review_harness" == "claude" ]]; then
    inbox_hook_src="$script_dir/fork-sandbox-inbox-hook.sh"
    if [[ ! -r "$inbox_hook_src" ]]; then
        echo "Error: $inbox_hook_src is missing. It delivers operator addenda" >&2
        echo "to a running session. Run install.sh in the fork-sandbox repo." >&2
        exit 1
    fi
    inbox_hook="$inbox_dir/.inbox-hook.sh"
    inbox_settings="$inbox_dir/.settings.json"
    install -m 755 "$inbox_hook_src" "$inbox_hook"
    # jq builds it so the path is escaped properly rather than interpolated
    # into hand-written JSON. Stop takes no matcher; PostToolUse matches every
    # tool, because an addendum is not about any particular one.
    jq -n --arg hook "$inbox_hook" '{
        hooks: {
            PostToolUse: [ { matcher: "*",
                             hooks: [ { type: "command", command: $hook, timeout: 20 } ] } ],
            Stop: [ { hooks: [ { type: "command", command: $hook, timeout: 20 } ] } ],
        },
    }' > "$inbox_settings"
    fs_reject_unsafe_chars "$inbox_hook" "$inbox_settings"
fi

# The artifact outbox: the ONE writable path outside the clone, bound
# --bind-rw beside the read-only inbox. This adds a writable surface, unlike
# everything above, and that is deliberate rather than an oversight -- an
# agent needs somewhere to put a screenshot, a report, a generated image, or
# (when --refresh-at is enabled) a hand-off nobody proactively reads out of
# the clone for it. It stays safe because it is read the same way the
# workspace and PLAN.md already are: the host only ever reads a hand-off as
# TEXT, and treats it as untrusted prompt content, never as anything to
# execute -- see the continuation prompt this script builds further down.
# Created and bound on every run, whether or not refresh is enabled.
outbox_dir="$run_dir/outbox"
mkdir -p "$outbox_dir"
chmod 755 "$outbox_dir"
fs_reject_unsafe_chars "$outbox_dir"

refresh_config=""
if (( refresh_enabled )); then
    # The hook's own settings, in the same inbox-dotfile trick .settings.json
    # uses above: the run dir itself is never bound, so anything the hook
    # needs to read has to live somewhere that IS. THRESHOLD_TOKENS is
    # resolved on the host, from --refresh-at and the model's context window,
    # so the hook does no fraction math; OUTBOX_DIR is this same directory,
    # named so the hook can check it without knowing the run dir layout.
    refresh_config="$inbox_dir/.refresh-config"
    {
        printf 'THRESHOLD_TOKENS=%s\n' "$refresh_threshold_tokens"
        printf 'OUTBOX_DIR=%s\n' "$outbox_dir"
        # CLONE_DIR: the clone is bound into the sandbox at this same
        # absolute path (see fs_build_sandbox_cmd below), so the hook can
        # stat $CLONE_DIR/.git/logs/HEAD without knowing anything else about
        # the run's layout -- see its own comment on why the reflog and not
        # the index.
        printf 'CLONE_DIR=%s\n' "$clone_dir"
    } > "$refresh_config"
    fs_reject_unsafe_chars "$refresh_config"
fi

# The handoff is the whole prompt, so prepend the one fact the caller cannot
# know: where the clone ended up. The session starts there, so relative paths
# always work — but a model that writes an absolute path by hand can drop a
# segment, and the "No such file or directory" it gets back reads as a missing
# file rather than a wrong path. Naming the directory once, at the top, costs
# nothing and removes the guess.
handoff_copy="$run_dir/handoff.md"

# A verbatim snapshot of the caller's own handoff, no preamble and no
# overlay, taken now rather than re-read from $handoff_file later: this run's
# --refresh-at continuations (below) embed it as the authoritative brief, and
# the launching session may edit $handoff_file after this run starts. Taking
# the copy here means a continuation always sees what leg 1 saw. Only
# refresh_build_prompt reads this back, and only a refresh-enabled run ever
# calls it, so the snapshot itself is skipped otherwise -- see SKILL.md's
# "--refresh-at only" note on this file.
handoff_original="$run_dir/handoff-original.md"
if (( refresh_enabled )); then
    fs_reject_unsafe_chars "$handoff_original"
    cat -- "$handoff_file" > "$handoff_original.part"
    mv -- "$handoff_original.part" "$handoff_original"
fi

# fs_emit_prompt_preamble (fork-sandbox-lib.sh) takes its network argument
# explicitly rather than reading $harness itself, so it can also serve
# fork-sandbox-k8s.sh's pod, which is a network situation of its own and not
# "pi-local". Resolve it once here: "sealed" for a pi-local run (no network
# at all), empty for every other local harness (unrestricted).
preamble_network=""
[[ "$harness" == "pi-local" ]] && preamble_network=sealed

# The review leg's own preamble, separate from the implement/fix one above:
# fs_emit_prompt_preamble's $harness argument decides whether the prompt
# describes claude's automatic addendum push or the "you have to look"
# instructions every other harness gets, and $network decides whether it
# describes a sealed sandbox -- both are true facts about whichever harness
# is ABOUT TO RUN that leg, not necessarily the implement harness. The fix
# leg has no such split: it always stays on the implement harness (the
# existing rule --review-model never changed), so its own preamble below
# keeps reading $harness/$preamble_network directly.
review_preamble_harness="$harness"
review_preamble_network="$preamble_network"
if [[ "$review_harness_given" == true ]]; then
    review_preamble_harness="$review_harness"
    review_preamble_network=""
    [[ "$review_harness" == "pi-local" ]] && review_preamble_network=sealed
fi

# The model-specific layer, applied after every generated block above and
# immediately before that leg's own task text: the environment blocks say
# where the agent is, this says how THIS model should behave in THIS leg,
# and the task text says what to do. $1 is the leg -- implement, review or
# fix. A no-op when that leg matched no fragment, which is the default on a
# machine with no prompts directory configured -- so this function costs the
# rendered prompt nothing when the feature is unused. See
# docs/prompt-overlays.md; no fragment for any model ships here.
fs_emit_prompt_overlay() {
    local leg="$1"
    local frags="${prompt_overlay_fragments[$leg]:-}"
    [[ -n "$frags" ]] || return 0
    printf '\n## Model-specific notes\n\n'
    printf 'A machine-local overlay applies here (see docs/prompt-overlays.md).\n'
    printf 'Fragments, general first: %s\n' "${frags//$'\n'/,}"
    local rel
    while IFS= read -r rel; do
        printf '\n'
        cat -- "$prompt_overlay_dir/$rel"
    done <<<"$frags"
}

{
    fs_emit_prompt_preamble "$clone_dir" "$inbox_dir" "$harness" "$preamble_network" \
        "$outbox_dir" "" "$outbox_max_bytes"
    if (( services_enabled )); then
        cat <<EOF

## Per-run services are up

This repository sets up services for the sandbox, and they are running now on
the host. The clone holds an env file, \`.env.sandbox\`, that points the
project's configuration at them over unix sockets. Use it the way the project
expects — most projects read it as \`ENVFILE=.env.sandbox <command>\`, or by
sourcing it; check the project's own CLAUDE.md.

The services listen on unix sockets under:

    $sockets_dir

A client that speaks a unix socket connects to it directly. A client that can
only reach a service over TCP on localhost needs a relay first — run this in
the background, once per such service, before starting the client:

    socat TCP-LISTEN:<port>,fork,bind=127.0.0.1 UNIX:$sockets_dir/<name>.sock &

\`socat\` is already on PATH here. The socket names, the ports and the env-file
convention are the project's; its CLAUDE.md or the services hook documents them.
EOF
    fi
    fs_emit_prompt_overlay implement
    printf '\n---\n\n'
    cat -- "$handoff_file"
} > "$handoff_copy.part"
# Assemble into a temp name and rename, rather than redirect straight onto the
# destination. A redirection truncates before the `cat` above reads, so a caller
# that passed this very path as its handoff would have its prompt destroyed and
# replaced by the preamble alone. `cp` used to make that case an error; building
# beside the destination keeps it correct instead.
mv -- "$handoff_copy.part" "$handoff_copy"

# The --review-loop prompts. Both are generated here, beside the handoff and
# with the same build-then-rename discipline, because everything they have to
# name — the clone, the inbox, the bound skill, the base commit — is known now
# and known nowhere else. The runner only feeds them to a session; it composes
# no prompt text of its own beyond appending the verdict to the fix header.
#
# The verdict lands in the clone's .git. That directory is writable, and git
# tracks nothing under it, so a leg running `git add -A` cannot commit the
# verdict by accident — the same reason a pi session lives there.
review_prompt=""
fix_prompt_header=""
review_verdict_file=""
if (( review_loop_cap > 0 )); then
    review_prompt="$run_dir/review-prompt.md"
    fix_prompt_header="$run_dir/fix-prompt-header.md"
    review_verdict_file="$clone_dir/.git/review-verdict.md"
    fs_reject_unsafe_chars "$review_prompt" "$fix_prompt_header" \
        "$review_verdict_file" "$review_skill_dir"
    {
        fs_emit_prompt_preamble "$clone_dir" "$inbox_dir" \
            "$review_preamble_harness" "$review_preamble_network" "$outbox_dir" \
            "" "$outbox_max_bytes"
        fs_emit_prompt_overlay review
        fs_emit_review_prompt_body "$branch" "$base_sha" "$review_skill_dir" \
            "$review_verdict_file" "$inbox_dir"
    } > "$review_prompt.part"
    mv -- "$review_prompt.part" "$review_prompt"

    {
        fs_emit_prompt_preamble "$clone_dir" "$inbox_dir" "$harness" "$preamble_network" \
            "$outbox_dir" "" "$outbox_max_bytes"
        fs_emit_prompt_overlay fix
        fs_emit_fix_prompt_body "$branch" "$base_sha"
    } > "$fix_prompt_header.part"
    mv -- "$fix_prompt_header.part" "$fix_prompt_header"
fi

# --refresh-at's continuation prompt: just the preamble, built once here for
# the same reason review_prompt and fix_prompt_header are -- everything it
# names (the clone, the inbox) is known now and known nowhere else, and the
# runner has no access to fs_emit_prompt_preamble at all, since it is a
# standalone generated script. The runner appends the "this is continuation
# N" line and that leg's own hand-off at runtime, the same way it appends the
# verdict to fix_prompt_header above.
continuation_prompt_header=""
if (( refresh_enabled )); then
    continuation_prompt_header="$run_dir/continuation-prompt-header.md"
    fs_reject_unsafe_chars "$continuation_prompt_header"
    fs_emit_prompt_preamble "$clone_dir" "$inbox_dir" "$harness" "$preamble_network" \
        "$outbox_dir" "" "$outbox_max_bytes" > "$continuation_prompt_header.part"
    mv -- "$continuation_prompt_header.part" "$continuation_prompt_header"
fi

# The run-log appender, resolved to an absolute path for the same reason the
# wrapper is. Optional on purpose: a machine without it skips the append
# rather than failing the run.
run_log_bin="$(command -v sandbox-run-log.py 2>/dev/null || true)"
[[ -n "$run_log_bin" ]] || run_log_bin="$HOME/.claude/scripts/sandbox-run-log.py"
[[ -x "$run_log_bin" ]] || run_log_bin=""

# Builds one harness's full sandbox_cmd argv from fs_resolve_harness's
# "${prefix}_*" output, plus every bind flag that is the same regardless of
# which harness runs -- the alternates, the node toolchain, provision-ro,
# the services socket, the review kit, --context-ro, the inbox and the
# outbox, and --sandbox-args. Those shared flags are not captured
# into a separate array first: they are read straight off the same globals
# fs_node_provision, fs_provision_ro and the services/inbox/outbox setup
# above already computed once, in the same order, on every call -- so a
# call for "impl" and a call for "rev" can never disagree about them,
# without a second array to keep in sync by hand. $1 is the prefix; $2 is
# the name of the array to write the built command into.
fs_build_sandbox_cmd() {
    local prefix="$1" out_name="$2"

    local -n b_harness="${prefix}_harness"
    local -n b_model="${prefix}_model"
    local -n b_harness_env_file="${prefix}_harness_env_file"
    local -n b_harness_exec="${prefix}_harness_exec"
    local -n b_harness_sandbox_bin="${prefix}_harness_sandbox_bin"
    # shellcheck disable=SC2178  # -n aliases an array here; shellcheck
    # cannot see through the dynamic target name to know that.
    local -n b_harness_flags="${prefix}_harness_flags"
    # shellcheck disable=SC2178
    local -n b_harness_cmd_src="${prefix}_harness_cmd"
    local -n out="$out_name"
    local -n out_pi_session_dir="${prefix}_pi_session_dir"
    # Only the pi and pi-local arms below set this; claude and codex leave
    # it empty. Pre-set it here rather than leave it unset -- under set -u
    # an unassigned nameref target was never auto-vivified at all, and the
    # compat-copy read of it below would die as an unbound variable.
    out_pi_session_dir=""

    # A local, mutable copy: this prefix's own resolved harness_cmd is
    # appended to below (--session-dir, the codex auth shim), and must not
    # mutate fs_resolve_harness's own recorded result -- a second build for
    # the same prefix (there is none today, but nothing here should assume
    # it can never happen) would otherwise pick up the previous build's
    # additions too.
    local -a harness_cmd=("${b_harness_cmd_src[@]}")

    # Resolve the wrapper to an absolute path now. The generated runner
    # executes in the tmux server's environment, and that PATH may not
    # carry ~/.claude/scripts — a server started at login often predates
    # the user's PATH setup. The pre-flight above checked this launcher's
    # environment, which proves nothing about the runner's.
    # A harness may bring its own wrapper: agent-sandboxed for a sealed
    # local-model run, which drives the same sandbox backend with a model
    # bridged in and takes the same bind flags. It is already resolved to
    # an absolute path, for the same reason this one is.
    local sandbox_bin
    if [[ -n "$b_harness_sandbox_bin" ]]; then
        sandbox_bin="$b_harness_sandbox_bin"
    else
        sandbox_bin="$(command -v claude-sandboxed || true)"
        if [[ -z "$sandbox_bin" ]]; then
            sandbox_bin="$HOME/.claude/scripts/claude-sandboxed"
        fi
    fi

    # claude-sandboxed stops parsing its own flags at the first argument
    # starting with '-', so its flags and the work dir must come first.
    out=("$sandbox_bin")
    for alt in "${FS_ALTERNATES[@]-}"; do
        [[ -n "$alt" ]] || continue
        out+=(--bind-ro "$alt")
    done
    if (( ${#b_harness_flags[@]} )); then
        out+=("${b_harness_flags[@]}")
    fi
    if (( ${#FS_NODE_FLAGS[@]} )); then
        out+=("${FS_NODE_FLAGS[@]}")
    fi
    if (( ${#FS_PROVISION_RO_FLAGS[@]} )); then
        out+=("${FS_PROVISION_RO_FLAGS[@]}")
    fi
    # The one writable path outside the clone: the per-run services sockets
    # dir. Docker on the host creates the sockets here; the sandbox reaches
    # the services through them and by no other route.
    if (( services_enabled )); then
        out+=(--bind-rw "$sockets_dir")
    fi
    if (( ${#review_kit_flags[@]} )); then
        out+=("${review_kit_flags[@]}")
    fi
    if [[ -n "$context_ro" ]]; then
        out+=(--bind-ro "$context_ro")
    fi
    # The operator inbox, for every harness. Read-only, so this widens
    # nothing the sandbox can write; it is the one path a host can put
    # words into after launch.
    out+=(--bind-ro "$inbox_dir")
    # The artifact outbox: writable, bound on every run -- see the comment
    # where it is created, above.
    out+=(--bind-rw "$outbox_dir")
    if [[ -n "$sandbox_args" ]]; then
        # Deliberate word splitting: the caller passes a flag string.
        # shellcheck disable=SC2206
        out+=($sandbox_args)
    fi
    # A harness with a command of its own runs through --exec. claude has
    # none, because claude-sandboxed starts it, and pi-local has none
    # either, because agent-sandboxed starts pi — so for both of those what
    # follows the clone dir is the tool's own flags.
    if (( b_harness_exec )); then
        case "$b_harness" in
        pi)
            # pi keeps its session under $HOME, and $HOME here is a tmpfs
            # that dies with the sandbox — so the transcript, and the
            # tokens recorded in it, would go with it. Put it inside the
            # clone's .git instead. That is writable, and git tracks
            # nothing under .git, so a session that runs `git add -A`
            # cannot commit it by accident. The runner copies it out at
            # the end. The prompt arrives on stdin, which forces print
            # mode by itself; -p states the intent anyway.
            #
            # --mode json makes print mode emit every AgentSessionEvent as
            # JSONL on stdout instead of just the final text, so
            # events.jsonl holds a real event stream. It changes what the
            # run reports, never what it does: the same print mode, the
            # same session, the same agent loop.
            out_pi_session_dir="$clone_dir/.git/pi-session"
            harness_cmd+=(--session-dir "$out_pi_session_dir" --mode json -p)
            ;;
        codex)
            # codex wants its credential as a FILE, and the sandbox's $HOME
            # is a fresh tmpfs with nothing in it. The token rides in as an
            # environment variable, which claude-sandboxed keeps out of
            # every command line, and this shim writes it where codex
            # looks. Writing it inside rather than binding it also leaves
            # codex free to rewrite it, which a read-only bind would
            # refuse.
            # shellcheck disable=SC2016  # a program for the sandbox's bash
            harness_cmd=(/bin/bash -c \
                'umask 077; mkdir -p "$HOME/.codex"; printf %s "$CODEX_AUTH_JSON" > "$HOME/.codex/auth.json"; unset CODEX_AUTH_JSON; exec "$@"' \
                codex-auth-shim "${harness_cmd[@]}")
            ;;
        esac
        out+=(--exec)
        if [[ -n "$b_harness_env_file" ]]; then
            out+=(--env-file "$b_harness_env_file")
        fi
        out+=("$clone_dir" "${harness_cmd[@]}")
    elif [[ "$b_harness" == "pi-local" ]]; then
        # pi's own flags, in the position claude's go. The session dir is
        # the same trick as the pi harness above: $HOME is a tmpfs that
        # dies with the sandbox, and .git is writable but tracked by
        # nothing, so a session running `git add -A` cannot commit the
        # transcript by accident. The runner copies it out at the end.
        out_pi_session_dir="$clone_dir/.git/pi-session"
        # The work dir here is a throwaway clone, and nothing runs git in
        # it once the sandbox has touched it, so agent-sandboxed's warning
        # about a writable .git would only tell the caller to use this
        # script.
        out+=(--no-git-warning "$clone_dir")
        if (( ${#harness_cmd[@]} )); then
            out+=("${harness_cmd[@]}")
        fi
        # --mode json for the same reason as the pi arm above: a real
        # event stream in events.jsonl, and no change to how the session
        # runs.
        out+=(--session-dir "$out_pi_session_dir" --mode json -p)
    else
        out+=("$clone_dir" --dangerously-skip-permissions)
        # --print exits when the work is done and never shows a dialog.
        # stream-json needs --verbose to emit anything beyond the final
        # result.
        out+=(--print --verbose --output-format stream-json)
        # The operator-inbox hooks. --settings loads them on top of
        # whatever the sandbox has, which is nothing: there is no global
        # ~/.claude in here. --include-hook-events puts each hook firing
        # into the event stream, which is how fork-sandbox-status.sh
        # --monitor can report a delivery. It costs two extra log lines
        # per tool call; the log is the only thing that grows.
        if [[ -n "$inbox_settings" ]]; then
            out+=(--settings "$inbox_settings" --include-hook-events)
        fi
        if [[ -n "$b_model" ]]; then
            out+=(--model "$b_model")
        fi
        # --claude-args has no per-leg form -- see the check beside
        # --pi-args, above, which refuses it against anything but the
        # implement harness. It applies to the implement leg alone, so
        # only the "impl" build picks it up here.
        if [[ "$prefix" == impl && -n "$claude_extra_args" ]]; then
            # shellcheck disable=SC2206
            out+=($claude_extra_args)
        fi
    fi
}

# "sandbox_cmd" is itself the out-array-name passed in, and
# "impl_pi_session_dir" only exists as the nameref inside fs_build_sandbox_cmd
# wrote it into being -- shellcheck cannot trace either through the dynamic
# name, the same false positive noted above fs_resolve_harness's call.
# shellcheck disable=SC2154
{
    fs_build_sandbox_cmd impl sandbox_cmd
    pi_session_dir="$impl_pi_session_dir"
}

# Review legs may use a stronger or independent model, or -- with
# --review-harness -- a different harness entirely. A different harness
# means a different wrapper, harness_flags and harness_cmd: there is
# nothing in sandbox_cmd to patch, so that whole case is built fresh by
# fs_build_sandbox_cmd from the "rev_*" state fs_resolve_harness resolved
# above, exactly as sandbox_cmd itself was built from "impl_*". Without
# --review-harness, review legs still run the implement harness, and the
# original approach applies: keep a distinct command instead of mutating
# sandbox_cmd in the runner (fix legs deliberately stay on the
# implementation model), patching --review-model into whatever
# harness-specific argv position is legal, since the model flag sits in a
# different region for each harness.
if [[ "$review_harness_given" == true ]]; then
    # "rev_pi_session_dir" ends up set as a side effect (fs_build_sandbox_cmd
    # writes it via its own nameref, same as it does "impl_pi_session_dir"
    # above); nothing further to copy here since the per-leg accounting
    # below reads "rev_pi_session_dir" directly, not a bare compat name.
    fs_build_sandbox_cmd rev review_sandbox_cmd
else
    # "sandbox_cmd" was populated above by fs_build_sandbox_cmd's nameref,
    # not by a literal assignment shellcheck can see -- the same false
    # positive as fs_resolve_harness's "impl_*"/"rev_*" outputs.
    # shellcheck disable=SC2154
    review_sandbox_cmd=("${sandbox_cmd[@]}")
    if [[ -n "$review_model" ]]; then
        if [[ "$harness" == "claude" ]]; then
            # Last occurrence wins, including over one supplied in --claude-args.
            review_sandbox_cmd+=(--model "$review_model")
        elif [[ "$harness" == "pi-local" ]]; then
            model_flag_i=-1
            workdir_i=-1
            for i in "${!review_sandbox_cmd[@]}"; do
                if [[ "${review_sandbox_cmd[$i]}" == "$clone_dir" ]]; then
                    workdir_i="$i"
                    break
                fi
                [[ "${review_sandbox_cmd[$i]}" == "--model" ]] && model_flag_i="$i"
            done
            if (( model_flag_i >= 0 )); then
                review_sandbox_cmd[model_flag_i+1]="$review_model"
            elif (( workdir_i >= 0 )); then
                review_sandbox_cmd=("${review_sandbox_cmd[@]:0:workdir_i}" --model "$review_model" "${review_sandbox_cmd[@]:workdir_i}")
            else
                echo "Error: cannot place --review-model in the pi-local command:" >&2
                echo "neither --model nor the clone directory was found in it." >&2
                exit 1
            fi
        elif [[ "$harness" == "codex" ]]; then
            model_flag_i=-1
            prompt_i=-1
            for i in "${!review_sandbox_cmd[@]}"; do
                if [[ "${review_sandbox_cmd[$i]}" == "-" ]]; then
                    prompt_i="$i"
                    break
                fi
                [[ "${review_sandbox_cmd[$i]}" == "--model" ]] && model_flag_i="$i"
            done
            if (( model_flag_i >= 0 )); then
                review_sandbox_cmd[model_flag_i+1]="$review_model"
            elif (( prompt_i >= 0 )); then
                review_sandbox_cmd=("${review_sandbox_cmd[@]:0:prompt_i}" --model "$review_model" "${review_sandbox_cmd[@]:prompt_i}")
            else
                echo "Error: cannot place --review-model in the codex command:" >&2
                echo "neither --model nor the '-' prompt marker was found in it." >&2
                exit 1
            fi
        else
            # OpenRouter pi always has this flag, immediately after its provider.
            for i in "${!review_sandbox_cmd[@]}"; do
                if [[ "${review_sandbox_cmd[$i]}" == "--provider" && "${review_sandbox_cmd[$((i+2))]:-}" == "--model" ]]; then
                    review_sandbox_cmd[i+3]="$review_model"
                    break
                fi
            done
        fi
    fi
    # No --review-harness, so the review leg stays on the implement
    # harness in every respect fs_resolve_harness would otherwise have
    # resolved separately -- its session dir (there is only one clone, so
    # only one "$clone_dir/.git/pi-session"), its usage reader, its
    # formatter and its credential file. Falling back to the "impl_*"
    # values here, rather than branching on review_harness_given again
    # everywhere a leg's own accounting reads one of these, means the
    # runner (below) and run_leg can always read "rev_*" for a review leg
    # and get the right answer whether or not --review-harness was given.
    rev_pi_session_dir="$impl_pi_session_dir"
    rev_usage_source="$impl_usage_source"
    rev_run_formatter="$impl_run_formatter"
    rev_harness_env_file="$impl_harness_env_file"
    rev_harness_version="$impl_harness_version"
fi

# tmux rewrites ':' and '.' in a session name without saying so, and a branch
# name may hold either. Fold every character tmux would touch to '-' here, so
# the name this script records is the name tmux actually uses.
session_name="cc-sbx-$(printf '%s' "$branch" | tr -c 'A-Za-z0-9_-' '-')"
# Two runs on different repos may want the same branch name, and an earlier
# --keep-session run may still be sitting there. tmux refuses a duplicate, so
# fall back to the run directory's own unique suffix.
if tmux has-session -t "=$session_name" 2>/dev/null; then
    session_name="$session_name-${run_dir##*.}"
fi

user_shell="${SHELL:-/bin/bash}"
# In the foreground the runner holds this terminal, so an interactive shell at
# the end would never hand it back.
if $keep_session && $foreground; then
    echo "Warning: --keep-session does nothing with --foreground; there is" >&2
    echo "no tmux session to keep open." >&2
fi
if $keep_session && ! $foreground; then
    keep_open=1
else
    keep_open=0
fi

started_at="$(date +%s)"

{
    printf 'version=1\n'
    printf 'run_dir=%s\n' "$run_dir"
    printf 'origin_repo=%s\n' "$origin_repo"
    printf 'clone_dir=%s\n' "$clone_dir"
    # The run's machine-readable record of where the inbox is, for a reader
    # that has the run.env and should not have to know the layout. The two
    # scripts that touch the inbox deliberately do NOT read this: they build
    # "$run_dir/inbox" from the run dir they validated, which is the same
    # fixed-name discipline resolve_run_file uses, so a rewritten run.env
    # cannot point either of them at another directory.
    printf 'inbox=%s\n' "$inbox_dir"
    printf 'branch=%s\n' "$branch"
    printf 'base_sha=%s\n' "$base_sha"
    printf 'checkout=%s\n' "$checkout_ref"
    printf 'harness=%s\n' "$harness"
    printf 'harness_version=%s\n' "$harness_version"
    printf 'model=%s\n' "$model"
    printf 'review_model=%s\n' "$review_model"
    printf 'review_harness=%s\n' "$review_harness"
    printf 'session=%s\n' "$session_name"
    printf 'review_loop_cap=%s\n' "$review_loop_cap"
    if [[ "$review_only" == true ]]; then
        printf 'mode=review-only\n'
    else
        printf 'mode=run\n'
    fi
    printf 'outbox_max_bytes=%s\n' "$outbox_max_bytes"
    printf 'started_at=%s\n' "$started_at"
} > "$run_dir/run.env"

# Generate the runner instead of building a shell command string. Every value
# below is quoted with printf %q, so nothing in a path, a branch name or a
# handoff document is ever re-parsed as shell syntax.
{
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by fork-sandbox.sh. One headless sandboxed agent session.\n'
    printf '# Values are quoted with printf %%q. Do not edit; relaunch instead.\n'
    printf 'set -uo pipefail\n\n'
    # The sandbox selection has to survive the trip into tmux. This launcher
    # asked the backend for its toolchain and baked the answer into
    # sandbox_cmd's binds; claude-sandboxed then resolves the backend AGAIN
    # inside this runner, which tmux starts in the tmux SERVER's environment.
    # A server started at login carries neither variable -- the same hazard
    # the PATH comment below already names -- so the two halves would disagree
    # and one of them would be wrong: an image-mode command line under bwrap
    # (nothing bound, "codex: command not found"), or a host binary bound into
    # a container, which is the exact failure this all exists to prevent.
    # Freeze the values, so both halves resolve the same backend.
    printf 'export FORK_SANDBOX_BACKEND=%q\n' "${FORK_SANDBOX_BACKEND:-bwrap}"
    if [[ -n "${FORK_SANDBOX_CONTAINER_IMAGE:-}" ]]; then
        printf 'export FORK_SANDBOX_CONTAINER_IMAGE=%q\n' "$FORK_SANDBOX_CONTAINER_IMAGE"
    fi
    if [[ -n "${FORK_SANDBOX_CONTAINER_CLI:-}" ]]; then
        printf 'export FORK_SANDBOX_CONTAINER_CLI=%q\n' "$FORK_SANDBOX_CONTAINER_CLI"
    fi
    # agent-sandboxed reads its endpoint config from here, and a pi-local run
    # starts it from this runner.
    if [[ -n "${FORK_SANDBOX_CONFIG_DIR:-}" ]]; then
        printf 'export FORK_SANDBOX_CONFIG_DIR=%q\n' "$FORK_SANDBOX_CONFIG_DIR"
    fi
    printf '\n'
    printf 'run_dir=%q\n' "$run_dir"
    printf 'clone_dir=%q\n' "$clone_dir"
    printf 'origin_repo=%q\n' "$origin_repo"
    printf 'branch=%q\n' "$branch"
    printf 'base_sha=%q\n' "$base_sha"
    printf 'return_base_sha=%q\n' "$return_base_sha"
    printf 'handoff=%q\n' "$handoff_copy"
    printf 'formatter=%q\n' "$run_formatter"
    printf 'harness=%q\n' "$harness"
    printf 'harness_version=%q\n' "$harness_version"
    printf 'usage_source=%q\n' "$usage_source"
    printf 'harness_env_file=%q\n' "$harness_env_file"
    printf 'codex_auth_src=%q\n' "${codex_auth_src:-}"
    printf 'codex_auth_dir=%q\n' "${codex_auth_dir:-}"
    printf 'model=%q\n' "$model"
    printf 'review_model=%q\n' "$review_model"
    printf 'review_harness=%q\n' "$review_harness"
    # run_leg needs this to know whether a review leg's own Stop-hook
    # invariant holds for fs_archive_inbox -- see review_preamble_harness's
    # own definition above, beside the review preamble, for why it is not
    # simply "$review_harness": with no --review-harness that is empty, and
    # a review leg then runs on the implement harness instead.
    printf 'review_preamble_harness=%q\n' "$review_preamble_harness"
    # The review leg's own accounting state, so run_leg can read a leg's
    # session dir, usage reader, formatter and credential file without
    # knowing whether --review-harness was given -- see the "rev_*"
    # fallback set above, right beside review_sandbox_cmd, for the case
    # where it was not.
    printf 'rev_usage_source=%q\n' "$rev_usage_source"
    printf 'rev_formatter=%q\n' "$rev_run_formatter"
    printf 'rev_harness_version=%q\n' "$rev_harness_version"
    printf 'rev_harness_env_file=%q\n' "$rev_harness_env_file"
    printf 'started_at=%q\n' "$started_at"
    printf 'pi_session_dir=%q\n' "$pi_session_dir"
    printf 'rev_pi_session_dir=%q\n' "$rev_pi_session_dir"
    printf 'review_loop_cap=%q\n' "$review_loop_cap"
    printf 'mode=%q\n' "$mode"
    printf 'review_prompt=%q\n' "$review_prompt"
    printf 'fix_prompt_header=%q\n' "$fix_prompt_header"
    printf 'review_verdict_file=%q\n' "$review_verdict_file"
    printf 'refresh_enabled=%q\n' "$refresh_enabled"
    printf 'refresh_max=%q\n' "$refresh_max"
    printf 'refresh_config=%q\n' "$refresh_config"
    printf 'outbox_dir=%q\n' "$outbox_dir"
    printf 'outbox_max_bytes=%q\n' "$outbox_max_bytes"
    printf 'continuation_prompt_header=%q\n' "$continuation_prompt_header"
    printf 'handoff_original=%q\n' "$handoff_original"
    printf 'user_shell=%q\n' "$user_shell"
    printf 'keep_open=%q\n' "$keep_open"
    printf 'services_enabled=%q\n' "$services_enabled"
    printf 'services_script=%q\n' "$services_script"
    printf 'sockets_dir=%q\n' "$sockets_dir"
    printf 'services_project=%q\n' "$services_project"
    printf 'run_log_bin=%q\n' "$run_log_bin"
    # GNU coreutils' timeout, under whatever name this machine has for it. The
    # services teardown below is an EXIT trap around a docker daemon that can
    # wedge, so the bound matters -- and macOS has no `timeout` at all, where
    # a bare call would fail into the `|| true` and leak the compose stack
    # silently, which is the one outcome the trap exists to prevent.
    printf 'FS_TIMEOUT=%q\n' "$FS_TIMEOUT"
    printf 'sandbox_cmd=('
    printf '%q ' "${sandbox_cmd[@]}"
    printf ')\n'
    printf 'review_sandbox_cmd=('
    printf '%q ' "${review_sandbox_cmd[@]}"
    printf ')\n\n'
    cat <<'RUNNER'
events="$run_dir/events.jsonl"
sandbox_log="$run_dir/sandbox.log"

printf '%s\n' "$$" > "$run_dir/pid"
# Drop the previous run's exit code, so a manual re-run reads as running
# rather than as already finished.
rm -f "$run_dir/exit-code"
: > "$events"
: > "$sandbox_log"

# Every later leg of this run -- a --refresh-at continuation, a review leg, a
# fix leg -- is a fresh sandbox with a fresh /tmp, bound to this same inbox
# directory. fork-sandbox-inbox-hook.sh's seen-list lives in that ephemeral
# /tmp, so without this, a later leg would re-read every addendum ever sent
# to the run, with no memory of anyone acting on it. The hook's Stop contract
# guarantees a session cannot end with an addendum unread, so at the moment a
# leg ends, every '*.md' in the inbox has already been delivered to it: move
# each one out into that leg's own record. $1 is the leg number the console
# log and --monitor use -- the implement leg is 1, and continuation, review
# and fix legs continue the count in the order they ran. $2 is the harness
# THAT LEG actually ran on: the Stop-contract guarantee above only holds on
# claude, which is the only harness the hook is installed for (see the
# harness check above the inbox_hook/inbox_settings block) -- every other
# harness only asks the session in its prompt to go look, and cannot enforce
# it, so a leg that ran pi/pi-local/codex may end with an addendum it never
# read. Archiving that file anyway would not just mislabel it: it moves the
# addendum out of the live inbox path the NEXT leg's own prompt names, into
# a numbered directory nothing but a --refresh-at continuation ever reads
# back, so it would never reach any session at all. Skip the move on any
# non-claude leg and leave the file where every leg's prompt already tells
# the agent to look. $3 is that leg's own exit code: the Stop hook only runs
# as part of the model ending its turn, so a leg that was killed, timed out,
# or otherwise exited non-zero never ran it, and any addendum sitting in the
# inbox at that point was never subject to the "cannot end with it unread"
# guarantee either -- skip the move for the same reason a non-claude leg
# does, and leave it for a later leg to actually see. This does not close
# the narrower race where a write lands after the Stop hook already let a
# clean-exit leg go but before this function runs (the pipeline still
# draining through tee) -- that is a pre-existing property of any Stop-hook-
# guarded workflow, not something archiving introduced, and closing it needs
# the hook to record which files it actually marked seen, not a leg-level
# rc check. The path is built from run_dir, the same fixed-name discipline
# fork-sandbox-status.sh's resolve_run_subdir uses, rather than threaded in
# as its own variable: this runner is a generated, standalone script, and
# run_dir is the one thing about the inbox it already carries. The dotfiles
# the hook and --refresh-at share the inbox with (.inbox-hook.sh,
# .settings.json, .refresh-config) are untouched by the '*.md' glob already.
# A symlink is refused rather than followed -- the inbox is host-written and
# nothing should ever put one there, but archiving is a move, and following
# a link out of the inbox is not a mistake worth making possible.
fs_archive_inbox() {
    local leg_no="$1" leg_harness="$2" leg_rc="$3" inbox_dir="$run_dir/inbox" dest="" f moved=0
    [[ "$leg_harness" == "claude" && "$leg_rc" == "0" ]] || return 0
    for f in "$inbox_dir"/*.md; do
        [[ -e "$f" || -L "$f" ]] || continue
        if [[ -L "$f" ]]; then
            printf 'fork-sandbox: %s is a symlink; refusing to archive it.\n' "$f" \
                >> "$sandbox_log"
            continue
        fi
        [[ -f "$f" ]] || continue
        if (( ! moved )); then
            dest="$run_dir/inbox-delivered/leg-$leg_no"
            mkdir -p "$dest"
        fi
        mv -f -- "$f" "$dest/"
        moved=1
    done
}

# Every addendum fs_archive_inbox has moved out of a strictly earlier leg of
# THIS run, oldest first: sorted by leg number rather than by directory name,
# since "leg-10" must not sort before "leg-2". One line per inbox-delivered
# leg directory. Shared by refresh_build_prompt below and the review loop
# further down -- both need "every earlier leg's addenda, in order", not
# just what happens to still be sitting in the live inbox this leg's own
# sandbox has bound.
fs_addenda_dirs() {
    local d leg_n
    for d in "$run_dir"/inbox-delivered/leg-*; do
        [[ -d "$d" && ! -L "$d" ]] || continue
        leg_n="${d##*/leg-}"
        printf '%s %s\n' "$leg_n" "$d"
    done | sort -n -k1,1 | cut -d' ' -f2-
}

printf '== fork-sandbox ==\n'
printf 'harness: %s\n' "$harness"
printf 'branch:  %s\n' "$branch"
printf 'origin:  %s\n' "$origin_repo"
printf 'clone:   %s\n' "$clone_dir"
printf 'log:     %s\n' "$events"
printf '\nHeadless. Nothing here needs a keypress; the session exits on its own.\n\n'

# codex's credential is built here, when the run starts, rather than by the
# launcher — a run that sits in a queue would otherwise carry a token that
# aged while it waited. The refresh token is replaced by a placeholder: the
# real one is single-use, so a sandbox that spent it would silently log the
# host out of codex. codex only refreshes when the access token has
# expired, so this run works and simply cannot rotate the host's
# credential. The file is 0600 and goes when this script does.
# Cleanup that must run however this session ends — a normal exit, an error, or
# a kill. It removes the codex credential and tears the per-run services down.
# It runs its body once (a --keep-session run calls it inline before the exec,
# which never reaches an EXIT trap; the trap catches every other ending).
run_cleanup() {
    [[ -n "${_cleanup_done:-}" ]] && return 0
    _cleanup_done=1
    if [[ -n "$codex_auth_dir" ]]; then
        rm -rf "$codex_auth_dir"
    fi
    if [[ "$services_enabled" == "1" && -n "$services_script" ]]; then
        # timeout on every docker-touching command here: this function is the
        # EXIT trap, and a wedged docker daemon must not hang the run forever
        # with the output hidden in sandbox.log.
        "$FS_TIMEOUT" 120 "$services_script" down "$services_project" \
            >> "$sandbox_log" 2>&1 || true
        # Opportunistic sweep: remove any claude-* compose project whose run
        # dir is gone. A session killed before this ran can leak one; catch it
        # on the next run's teardown. Best-effort, never fatal.
        if command -v docker >/dev/null 2>&1; then
            local live=" " d bn p orphan
            for d in /var/tmp/claude-scratch/forks/claude-fork-sandbox.*/; do
                [[ -d "$d" ]] || continue
                # Both name forms per run dir: with the cksum suffix (what the
                # launcher derives now) and without it (what runs launched
                # before the suffix existed still use). Dropping the old form
                # would sweep a live old-format run's services out from under
                # it during the transition.
                bn="$(basename "$d")"; p="${bn,,}"; p="${p//[^a-z0-9-]/-}"
                live+="$p $p-$(printf '%s' "$bn" | cksum | cut -d' ' -f1) "
            done
            while IFS= read -r orphan; do
                # Only projects this script creates: the run-dir basename,
                # sanitized. A bare claude-* would sweep unrelated user projects.
                case "$orphan" in claude-fork-sandbox-*) ;; *) continue ;; esac
                [[ "$live" == *" $orphan "* ]] && continue
                # The run dir is gone, so its compose file is too. Remove the
                # project's resources by their compose label rather than through
                # a compose file that no longer exists.
                # `xargs -r` would be the natural way to skip an empty list,
                # but BSD xargs rejects the flag rather than ignoring it, so
                # the whole sweep would fail on a Mac. Collect and test here,
                # which needs no flag at all.
                for what in ps network volume; do
                    case "$what" in
                        ps)      ids="$("$FS_TIMEOUT" 60 docker ps -aq --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                        network) ids="$("$FS_TIMEOUT" 60 docker network ls -q --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                        volume)  ids="$("$FS_TIMEOUT" 60 docker volume ls -q --filter "label=com.docker.compose.project=$orphan" 2>/dev/null || true)" ;;
                    esac
                    [[ -n "$ids" ]] || continue
                    case "$what" in
                        ps)      printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker rm -f >> "$sandbox_log" 2>&1 || true ;;
                        network) printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker network rm >> "$sandbox_log" 2>&1 || true ;;
                        volume)  printf '%s\n' "$ids" | xargs "$FS_TIMEOUT" 60 docker volume rm >> "$sandbox_log" 2>&1 || true ;;
                    esac
                done
            done < <("$FS_TIMEOUT" 60 docker compose ls -a --format json 2>/dev/null \
                     | jq -r 'if type == "array" then .[] else . end
                              | .Name' 2>/dev/null || true)
            # The jq filter takes both shapes compose emits: one JSON array
            # (current `compose ls`) and NDJSON, one object per line (what
            # `compose ps` moved to in v2.21) — assuming one shape makes the
            # sweep a silent permanent no-op on the other.
        fi
    fi
}
trap run_cleanup EXIT
if [[ "$harness" == "codex" && -n "$harness_env_file" ]]; then
    install -m 600 /dev/null "$harness_env_file"
    {
        printf 'CODEX_AUTH_JSON='
        jq -c '.tokens.refresh_token = "sandbox-placeholder-cannot-refresh"' \
            "$codex_auth_src"
    } > "$harness_env_file"
fi
# The review leg's own credential file, when --review-harness names its
# own codex independently of the implement harness. review_harness is
# empty without --review-harness, in which case rev_harness_env_file
# already equals harness_env_file (fs_resolve_harness was never called a
# second time -- see the "rev_*" fallback beside review_sandbox_cmd,
# above) and the path-equality check below skips the duplicate write.
review_codex_harness="$harness"
[[ -n "$review_harness" ]] && review_codex_harness="$review_harness"
if [[ "$review_codex_harness" == "codex" && -n "$rev_harness_env_file" \
    && "$rev_harness_env_file" != "$harness_env_file" ]]; then
    install -m 600 /dev/null "$rev_harness_env_file"
    {
        printf 'CODEX_AUTH_JSON='
        jq -c '.tokens.refresh_token = "sandbox-placeholder-cannot-refresh"' \
            "$codex_auth_src"
    } > "$rev_harness_env_file"
fi

# Per-run services: stand them up before the session and point the project's
# config at the sockets. The teardown is already armed, so a failure here still
# cleans up. A services failure is a warning, not fatal — the session runs, it
# just cannot reach the services.
if [[ "$services_enabled" == "1" && -n "$services_script" ]]; then
    printf 'fork-sandbox: starting per-run services (%s)...\n' "$services_project" >&2
    if ! "$services_script" up "$sockets_dir" "$clone_dir" "$services_project" \
        >> "$sandbox_log" 2>&1; then
        printf 'fork-sandbox: WARNING: services failed to start; see %s.\n' \
            "$sandbox_log" >&2
        printf 'The session runs without them.\n' >&2
        # The prompt's preamble already says the services are up — it was
        # written at launch, before this could fail. Correct it, or the
        # session burns its run debugging sockets that never existed. The
        # prompt is read below, after this block, so both prompt paths see
        # the correction.
        cat >> "$handoff" <<'NOSVC'

---

## Correction: the per-run services FAILED to start

Ignore the "Per-run services are up" section at the top of this prompt.
`docker compose up` failed on the host after that text was written, so there
is no `.env.sandbox` and no socket under the sockets directory works. Treat
the environment as committed state only, and report "the per-run services
failed to start" instead of debugging the missing sockets.
NOSVC
    fi
fi

# The handoff document is the prompt, and every harness reads it on stdin —
# never as an argument. Linux caps one argv string at 128KB (MAX_ARG_STRLEN),
# so an argv prompt makes a big handoff die as exit 126 before the tool even
# starts; stdin has no such cap. pi treats piped stdin as a prompt and forces
# print mode on it; claude and codex read stdin natively. The redirect opens
# the file at exec time, after the services block above, so a failure
# correction appended there still lands in the prompt.

# stdout is the session's output: tee keeps the raw copy in the event log,
# and the formatter renders it live when there is one to render. The
# sandbox's own messages go to stderr, which is copied to the log and shown
# here too.
rc=0
if [[ "$mode" != "review-only" ]]; then
if [[ -n "$formatter" ]]; then
    "${sandbox_cmd[@]}" < "$handoff" \
        2> >(tee -a "$sandbox_log" >&2) \
        | tee -a "$events" \
        | "$formatter"
else
    "${sandbox_cmd[@]}" < "$handoff" \
        2> >(tee -a "$sandbox_log" >&2) \
        | tee -a "$events"
fi
rc="${PIPESTATUS[0]:-1}"
# The implement leg is leg 1. Archive right after its exit code is known,
# same as every later leg below.
fs_archive_inbox 1 "$harness" "$rc"
# exit-code is what fork-sandbox-status.sh reads as "this run is over": it
# reports the run finished the moment the file exists, and --monitor fires its
# one terminal event there. With a review loop still to come that would be a
# lie -- the branch has not been fetched, the summary is not written, and the
# loop is about to move the head under whoever just read "finished". So for a
# --review-loop run the exit code is published after the loop instead, where
# the run really does end; the pid file keeps the state honest as "running"
# until then. A run without the flag is untouched and writes it here as
# always. --refresh-at defers the same way, and for the same reason: a
# continuation leg can still change $rc below.
if [[ "$review_loop_cap" == "0" && "$refresh_enabled" == "0" ]]; then
    printf '%s\n' "$rc" > "$run_dir/exit-code"
fi
fi

# The credential and the services are NOT cleaned up here. --review-loop can
# start further sessions below, in the same sandbox, on the same harness: a
# codex leg needs the credential this run wrote, and a fix leg may run the
# suite, which needs the services. run_cleanup happens once the loop is done,
# before the fetch. The EXIT trap is the backstop for every path that never
# reaches it.

# A pi-local run usually carries no --model: agent-sandboxed discovers the
# model from the endpoint, so this script never saw it and the run record
# would say null. Recover it from the banner agent-sandboxed prints into the
# log. The model id is the one whitespace-free token between "pi against " and
# " at ", so match a run of non-space characters. Take the first banner only.
if [[ -z "$model" && -s "$sandbox_log" ]]; then
    model="$(sed -n 's/^agent-sandboxed: pi against \([^ ]*\) at .*/\1/p' \
        "$sandbox_log" | head -n1)"
fi

# What the run cost, in one place for both harnesses. Either way a missing
# or unreadable source leaves it unreported rather than wrong.
#
# claude says so itself: the result event carries the session total, and
# the formatter reads it out. pi does not say it anywhere in its output,
# but records the token cost of every message in its session file — so
# rescue that file first, before anything else touches the clone. It is
# worth keeping for its own sake, being the whole transcript. cp -a copies
# symlinks as symlinks, so nothing the sandbox left behind can redirect
# this write. Summing every usage.cost counts tool-reported usage too,
# which is what pi's own totals do.
run_cost=""
run_usage=""
run_error=""
if [[ -n "$pi_session_dir" && -d "$pi_session_dir" ]]; then
    cp -a "$pi_session_dir" "$run_dir/pi-session" 2>/dev/null

    # pi exits 0 even when its final turn ended in a provider error -- a
    # context-length 400, a refused request, a dropped endpoint -- because the
    # process itself ran fine; the failure was in the last response it read.
    # The run then reports "done, exit 0" having written nothing, which is the
    # one outcome a watcher cannot tell apart from success. Observed: a review
    # that spent 23 minutes reading, overflowed the window by a single token on
    # its final call, and was reported as a clean run.
    #
    # The session file is the only place that error is recorded, so take the
    # last turn's stopReason from it. The LAST one specifically: pi retries, and
    # an error it recovered from is not a failed run.
    pi_error="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -rs '[.. | objects | select(has("stopReason"))] | last // empty
                  | select(.stopReason == "error")
                  | .errorMessage // "the model reported an error"' \
             2>/dev/null || true)"
    if [[ -n "$pi_error" ]]; then
        run_error="$pi_error"
        printf 'fork-sandbox: the session ended in a model error: %s\n' \
            "$pi_error" >> "$sandbox_log"
        # Never turn a non-zero exit into a different non-zero one: the
        # process's own code is the better diagnosis when it has one.
        if [[ "$rc" == "0" ]]; then
            rc=1
            printf '%s\n' "$rc" > "$run_dir/exit-code"
        fi
    fi

    # Round to millionths. Adding floats leaves noise a dollar figure
    # should not carry, and a cheap run costs well under a cent, so
    # rounding to cents would report every one of them as zero.
    run_cost="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -s '[.. | objects | select(has("usage")) | .usage.cost.total? // empty]
                 | add
                 | if . == null then empty else (. * 1000000 | round) / 1000000 end' \
             2>/dev/null)"
    # The same walk, for the counts behind that figure. pi names them
    # differently from claude; this is where they are made to agree.
    run_usage="$(find "$run_dir/pi-session" -name '*.jsonl' -exec cat {} + 2>/dev/null \
        | jq -s -c '[.. | objects | select(has("usage")) | .usage]
                    | if length == 0 then empty else
                        {
                          input_tokens: ([.[].input // empty] | add),
                          output_tokens: ([.[].output // empty] | add),
                          cache_read_tokens: ([.[].cacheRead // empty] | add),
                          cache_write_tokens: ([.[].cacheWrite // empty] | add),
                          reasoning_output_tokens: null,
                          total_tokens: ([.[].totalTokens // empty] | add),
                        }
                      end' 2>/dev/null)"
elif [[ "$usage_source" == "codex" && -s "$events" ]]; then
    # codex reports tokens in its turn.completed events and a price
    # nowhere, so cost stays null and the counts carry the run.
    #
    # Note what total_tokens must NOT be here. codex's
    # cached_input_tokens is part of input_tokens, not a figure beside
    # it — 9600 cached of 12217 input — so adding the two double-counts
    # the cache. claude reports its cache separately and does add up.
    # That is what usage_source is for: the shape is common, the
    # convention behind it is not.
    run_usage="$(jq -R -s -c '
        [ split("\n")[] | fromjson? // empty
          | select(.type == "turn.completed") | .usage // empty ]
        | if length == 0 then empty else
            {
              input_tokens: ([.[].input_tokens // empty] | add),
              output_tokens: ([.[].output_tokens // empty] | add),
              cache_read_tokens: ([.[].cached_input_tokens // empty] | add),
              cache_write_tokens: null,
              reasoning_output_tokens: ([.[].reasoning_output_tokens // empty] | add),
              total_tokens: (([.[].input_tokens // empty] | add)
                             + ([.[].output_tokens // empty] | add)),
            }
          end' "$events" 2>/dev/null)"
elif [[ -n "$formatter" && -s "$events" ]]; then
    run_cost="$("$formatter" --cost "$events" 2>/dev/null)"
    run_usage="$("$formatter" --usage "$events" 2>/dev/null)"
fi
# A reader should not have to tell "no tokens" from "tokens not reported".
[[ -n "$run_usage" ]] || run_usage=null

# Format once, here, and record it where a caller can read it without
# parsing prose. %.6f rather than the raw number: a sum of floats carries
# noise, and a cheap run is small enough that jq hands back scientific
# notation, which is no way to write a price. Millionths, because a run
# can honestly cost less than a cent. run.env is the run's machine-readable
# record and fork-sandbox-status.sh already reads it key by key, so the
# value goes there as well as into the summary. Check it is a number
# first: this block writes into the summary with stderr folded in, so a
# printf that rejects its argument would land its complaint in the report.
run_cost_fmt=""
if [[ "$run_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    run_cost_fmt="$(printf '%.6f' "$run_cost")"
    # Replace the line rather than append one. This script can be re-run by
    # hand, which is why everything else it writes is truncated first, and
    # a reader takes the FIRST match for a key — so a second cost= line
    # would hide the new figure behind the old one. Build the replacement
    # beside the file and rename, which is atomic, so a reader watching the
    # run sees one version or the other and never a half-written record.
    # Rewrite nothing if the record cannot be read: an empty run.env would
    # lose the whole run rather than one line.
    if [[ -s "$run_dir/run.env" ]] \
        && grep -v '^cost=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
        printf 'cost=%s\n' "$run_cost_fmt" >> "$run_dir/run.env.part"
        mv -f "$run_dir/run.env.part" "$run_dir/run.env"
    else
        rm -f "$run_dir/run.env.part"
    fi
fi
# The run.env written at start carries model= empty for a run whose model the
# endpoint discovered. Refresh that one line the same way: replace rather
# than append, because a reader takes the first match, and build the
# replacement beside the file and rename, which is atomic.
if [[ -n "$model" ]] \
    && [[ -s "$run_dir/run.env" ]] \
    && grep -v '^model=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'model=%s\n' "$model" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi

# Shared with the review loop below: the running total of every extra
# session this run pays for beyond the implement leg, and whether that total
# is still honest. A continuation leg's cost lands here first; a review-loop
# leg's cost lands here too, once that section runs -- one accumulator, so
# total_cost_usd at the very end is never short a leg.
loop_cost_sum=0
loop_cost_unknown=0

# ---------------------------------------------------------------- refresh --
# --refresh-at: when a coding leg's own context crossed the threshold,
# fork-sandbox-inbox-hook.sh nudged it, once, to write a hand-off to
# $outbox_dir/handoff.md and end its turn. If it did, this loop moves that
# file to $run_dir/handoff-N.md (the record) and runs continuation N: a
# fresh session, same clone, same branch, with that hand-off as its whole
# prompt. It keeps going -- checking the outbox again, running another
# continuation -- until a leg ends with nothing waiting there, which is the
# ordinary way this ends.
#
# $rc is OVERWRITTEN by each continuation's own exit code, deliberately: the
# review loop below (and the final exit code) must judge the run by its LAST
# coding leg, not its first. It sits here, after the implement leg's own
# run_cost/run_usage accounting above, so that accounting keeps meaning the
# implement leg alone -- exactly as it did before this feature existed --
# while every continuation's cost instead joins loop_cost_sum, the same
# accumulator the review loop below adds its own legs to.
refresh_ended=""
continuations_json='[]'
refresh_leg_n=0
# The events slice to check for a nudge marker once no hand-off is waiting:
# starts as the implement leg's own events.jsonl (nothing else has been
# appended to it yet at this point), and becomes each continuation's own
# events-continuation-N.jsonl in turn.
refresh_last_events="$events"

# Continuation legs share fork-sandbox-inbox-hook.sh's own tag rather than
# invent a second one: that hook already writes it to stderr, which
# --include-hook-events folds into this leg's own event stream as a
# hook_response event, so it is right there in whichever file this leg wrote.
refresh_leg_was_nudged() {
    grep -q 'fork-sandbox-refresh: nudged' "$1" 2>/dev/null
}

# $1 continuation number (1 for the first continuation -- the same count
# named in handoff-N.md, continuation-prompt-N.md and README/SKILL.md, NOT
# the leg number the console log and --monitor use, which counts the
# implement leg as 1). $2 the hand-off file, already moved to its $run_dir
# record. $3 the destination path. $4 (optional, default 0) whether the host-
# side backstop found this hand-off older than the clone's last commit -- see
# its check above. The static preamble, then the original brief
# ($handoff_original, snapshotted once at launch -- see above), any operator
# addenda archived from earlier legs of this run, a warning block when $4 is
# set, and finally the previous leg's own hand-off -- there is no
# verdict-style body to append here, unlike the fix leg's prompt.
refresh_build_prompt() {
    local n="$1" handoff="$2" out="$3" stale="${4:-0}"
    # Every addendum fs_archive_inbox has moved out of a strictly earlier leg
    # of THIS run, oldest first: sorted by leg number rather than by
    # directory name, since "leg-10" must not sort before "leg-2". The review
    # loop rebuilds its own review-prompt copy with the same list, for the
    # same reason -- a continuation is the same task continued, so it gets
    # all of them, not just the ones its immediate predecessor saw.
    local addenda_list f
    addenda_list="$(fs_addenda_dirs)"
    {
        cat -- "$continuation_prompt_header"
        printf '\n---\n\n# This is continuation %s of a run that refreshed its context\n\n' "$n"
        printf 'A previous session, in this same clone and on this same branch, used up\n'
        printf 'most of its context window and wrote a hand-off for a fresh session to\n'
        printf 'continue from. You are that fresh session, with none of its memory.\n'
        if [[ -n "$addenda_list" ]]; then
            printf 'Three documents follow: the original brief this run was launched\n'
            printf 'with, any operator addenda delivered to earlier legs of this run,\n'
            printf 'and the hand-off the previous leg wrote against it.\n\n'
        else
            printf 'Two documents follow: the original brief this run was launched with,\n'
            printf 'and the hand-off the previous leg wrote against it.\n\n'
        fi
        printf 'The brief is authoritative for what the task IS -- check its own list\n'
        printf 'of items, not the hand-off'"'"'s account of it, to decide what is left.\n'
        if [[ -n "$addenda_list" ]]; then
            printf 'The addenda carry the same authority as the brief and outrank it\n'
            printf 'where the two conflict -- see their own section below for what each\n'
            printf 'one asked for.\n'
        fi
        printf 'The hand-off is authoritative for what has been done against the brief\n'
        printf 'so far. Where the hand-off summarises, abbreviates or omits items the\n'
        printf 'brief contains, the brief wins.\n\n'
        printf '\n---\n\n## The original brief\n\n'
        cat -- "$handoff_original"
        if [[ -n "$addenda_list" ]]; then
            printf '\n---\n\n## Operator addenda delivered to earlier legs\n\n'
            printf 'The operator sent the messages below to an earlier leg of this same\n'
            printf 'run, oldest first. They carry the same authority as the brief above\n'
            printf 'and outrank it where the two conflict. Where a message asks for\n'
            printf 'something to be done, the leg that received it has most likely\n'
            printf 'already done it -- check `git log --oneline` before redoing any of\n'
            printf 'it. Where a message is a constraint or a correction, it still binds.\n'
            while IFS= read -r d; do
                [[ -n "$d" ]] || continue
                for f in "$d"/*.md; do
                    [[ -f "$f" ]] || continue
                    printf '\n### %s\n\n' "${f##*/}"
                    cat -- "$f"
                done
            done <<< "$addenda_list"
        fi
        if (( stale )); then
            printf '\n---\n\n## Warning: this hand-off is stale\n\n'
            printf 'It was written before the last commit on this branch, so its "done"\n'
            printf 'and "left" lists may be wrong. Run `git log --oneline` and `git status`\n'
            printf 'first and reconcile against the brief above before doing anything.\n'
        fi
        printf '\n---\n\n## Hand-off from the previous leg\n\n'
        cat -- "$handoff"
    } > "$out.part"
    mv -- "$out.part" "$out"
}

if [[ "$refresh_enabled" == "1" ]]; then
    while :; do
        if [[ -f "$outbox_dir/handoff.md" ]]; then
            if (( refresh_leg_n >= refresh_max )); then
                refresh_ended="cap"
                break
            fi
            # The hand-off is written by a session, so a symlink at that path
            # is not a hand-off: refuse it rather than follow it out of the
            # clone -- the same guard the review loop's verdict file gets.
            if [[ -L "$outbox_dir/handoff.md" ]]; then
                printf 'fork-sandbox: outbox handoff.md is a symlink; refusing it.\n' \
                    >> "$sandbox_log"
                rm -f -- "$outbox_dir/handoff.md" 2>/dev/null
                refresh_ended="no-handoff"
                break
            fi
            # An oversized hand-off is refused rather than trusted -- moved
            # aside so it is not silently reconsidered on the next check, and
            # the run proceeds as if this leg had written nothing at all.
            handoff_bytes="$(wc -c < "$outbox_dir/handoff.md" 2>/dev/null || printf 0)"
            if (( handoff_bytes > 65536 )); then
                printf 'fork-sandbox: outbox handoff.md is %s bytes, over the 64 KiB cap; refusing it.\n' \
                    "$handoff_bytes" >> "$sandbox_log"
                mv -f -- "$outbox_dir/handoff.md" "$run_dir/handoff-refused-too-large.md" 2>/dev/null
                refresh_ended="no-handoff"
                break
            fi
            # An empty or dangling hand-off (wc -c failing on it falls back to
            # 0, which passes the cap above) is refused the same way -- it
            # would otherwise launch a whole continuation with nothing under
            # "Read the hand-off as your task".
            if [[ ! -s "$outbox_dir/handoff.md" ]]; then
                printf 'fork-sandbox: outbox handoff.md is empty; refusing it.\n' \
                    >> "$sandbox_log"
                mv -f -- "$outbox_dir/handoff.md" "$run_dir/handoff-refused-empty.md" 2>/dev/null
                refresh_ended="no-handoff"
                break
            fi

            refresh_leg_n=$(( refresh_leg_n + 1 ))
            leg_no=$(( refresh_leg_n + 1 ))
            record_name="handoff-$refresh_leg_n.md"
            mv -f -- "$outbox_dir/handoff.md" "$run_dir/$record_name"
            # Guard the window between the checks above and this mv: what
            # gets cat'd into the prompt below must be a plain file that
            # actually landed in the run dir, never a symlink followed here.
            if [[ -L "$run_dir/$record_name" || ! -f "$run_dir/$record_name" ]]; then
                printf 'fork-sandbox: %s is not a regular file after the move; refusing it.\n' \
                    "$record_name" >> "$sandbox_log"
                rm -f -- "$run_dir/$record_name" 2>/dev/null
                refresh_leg_n=$(( refresh_leg_n - 1 ))
                leg_no=$(( leg_no - 1 ))
                refresh_ended="no-handoff"
                break
            fi

            # Bug B's host-side backstop: the sandbox-side Stop check cannot
            # help a leg that died (quota, crash, timeout) right after
            # writing an early hand-off. mv above preserves mtime, so this
            # compares the RECORD, not the outbox path it came from. This
            # reads an mtime only -- it does NOT run git in the clone, which
            # stays forbidden on the host (see the review-loop commit count
            # below, "nothing may run git in the clone to count them there").
            handoff_stale=0
            if [[ -f "$clone_dir/.git/logs/HEAD" \
                && "$clone_dir/.git/logs/HEAD" -nt "$run_dir/$record_name" ]]; then
                handoff_stale=1
                printf "fork-sandbox: %s predates the clone's last commit; continuation leg %s is warned\n" \
                    "$record_name" "$leg_no" | tee -a "$sandbox_log"
            fi

            cont_prompt="$run_dir/continuation-prompt-$refresh_leg_n.md"
            refresh_build_prompt "$refresh_leg_n" "$run_dir/$record_name" "$cont_prompt" "$handoff_stale"

            # A synthetic marker event, so --monitor and --follow notice a
            # continuation starting without waiting for that leg's own first
            # event -- see fork-sandbox-format.sh's rendering of it.
            jq -c -n --argjson leg "$leg_no" --arg handoff "$record_name" \
                '{type: "system", subtype: "fork_sandbox_continuation", leg: $leg, handoff: $handoff}' \
                >> "$events" 2>/dev/null
            printf '\n== fork-sandbox: continuation leg %s (from %s) ==\n' "$leg_no" "$record_name"

            cont_events="$run_dir/events-continuation-$refresh_leg_n.jsonl"
            : > "$cont_events"
            # Both files: events.jsonl so --result, --follow and --monitor
            # keep showing the whole coding phase as it happens (JQ_RESULT's
            # "last result wins" is exactly "the LAST coding leg's result"),
            # and this leg's own file so its cost and usage can be read in
            # isolation below, the same way a review-loop leg's can.
            if [[ -n "$formatter" ]]; then
                "${sandbox_cmd[@]}" < "$cont_prompt" \
                    2> >(tee -a "$sandbox_log" >&2) \
                    | tee -a "$events" -a "$cont_events" \
                    | "$formatter"
            else
                "${sandbox_cmd[@]}" < "$cont_prompt" \
                    2> >(tee -a "$sandbox_log" >&2) \
                    | tee -a "$events" -a "$cont_events"
            fi
            rc="${PIPESTATUS[0]:-1}"
            fs_archive_inbox "$leg_no" "$harness" "$rc"
            refresh_last_events="$cont_events"

            cont_cost="$("$formatter" --cost "$cont_events" 2>/dev/null)"
            cont_usage="$("$formatter" --usage "$cont_events" 2>/dev/null)"
            [[ -n "$cont_usage" ]] || cont_usage=null
            if [[ "$cont_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                summed="$(jq -n --argjson a "$loop_cost_sum" --argjson b "$cont_cost" \
                    '$a + $b' 2>/dev/null)"
                if [[ -n "$summed" ]]; then
                    loop_cost_sum="$summed"
                else
                    loop_cost_unknown=1
                fi
            else
                cont_cost=null
                loop_cost_unknown=1
            fi

            handoff_stale_json=false
            (( handoff_stale )) && handoff_stale_json=true
            merged="$(jq -c -n \
                --argjson prev "$continuations_json" \
                --argjson leg "$leg_no" \
                --argjson exit "$rc" \
                --argjson cost "$cont_cost" \
                --argjson usage "$cont_usage" \
                --arg handoff "$record_name" \
                --argjson handoff_stale "$handoff_stale_json" \
                '$prev + [{leg: $leg, exit: $exit, cost_usd: $cost, usage: $usage, handoff: $handoff, handoff_stale: $handoff_stale}]' \
                2>/dev/null)"
            [[ -n "$merged" ]] && continuations_json="$merged"

            if [[ "$rc" != "0" ]]; then
                # A crashed leg is not the ordinary ending: it gets its own
                # terminal value rather than being folded into empty-outbox,
                # which readers (including `stats --by refresh`) treat as
                # success. A hand-off the leg managed to write just before
                # dying is worth keeping as part of the record even though
                # this run is not going to act on it.
                if [[ -f "$outbox_dir/handoff.md" && ! -L "$outbox_dir/handoff.md" ]]; then
                    mv -f -- "$outbox_dir/handoff.md" \
                        "$run_dir/handoff-leg-$leg_no-after-error.md" 2>/dev/null
                fi
                refresh_ended="leg-error"
                break
            fi
            continue
        fi

        # No hand-off is waiting. The leg that just finished -- the implement
        # leg, the first time through -- is the run's last coding leg, unless
        # it was nudged and still left nothing there, which is worth telling
        # apart from a run that simply never needed to refresh at all.
        if refresh_leg_was_nudged "$refresh_last_events"; then
            refresh_ended="no-handoff"
        else
            refresh_ended="empty-outbox"
        fi
        break
    done
fi
[[ -n "$refresh_ended" ]] || refresh_ended="none"
if [[ "$refresh_enabled" == "1" ]]; then
    printf 'fork-sandbox: refresh ended: %s (%s continuation leg(s) ran)\n' \
        "$refresh_ended" "$refresh_leg_n"
    # sandbox_cmd (and review_sandbox_cmd, derived from it below) still has
    # the outbox bind and the hook settings baked in, but the review and fix
    # legs that reuse it have no loop watching the outbox any more -- this
    # loop just broke out of the only code that does. Remove the config the
    # hook gates the whole nudge mechanism on so those legs' sandboxes see an
    # inbox with no .refresh-config and never get told to hand off to nobody.
    if [[ -n "$refresh_config" ]]; then
        rm -f -- "$refresh_config" 2>/dev/null
    fi
fi

# ------------------------------------------------------------- review loop --
# --review-loop N: review the commits the session just made in a FRESH session
# of the same harness and (when supplied) --review-model, and when that review
# reports problems, hand
# them to a fresh session that fixes them. Repeat until the review approves,
# until a fix leg stops making progress, or until N iterations have run.
#
# It sits here on purpose: everything above is the implement leg's accounting
# and, when --refresh-at ran any continuations, the refresh loop's -- including
# the pi stopReason check, which is the only failure detection a pi run has. A
# coding leg that died of a model error must never be reviewed as if it had
# worked, so the loop runs downstream of the checks that catch it, and $rc by
# now names the LAST coding leg's exit, not necessarily the implement leg's.
#
# The legs reuse this run's sandbox command, so they get the same harness, the
# same clone and the same binds. Review legs may override the model; fix legs
# retain the implementation model. They differ in the prompt on stdin and in
# where their output goes: each leg has its own events file and never touches
# events.jsonl, so it keeps showing the coding phase -- implement leg plus any
# continuations -- and --result keeps showing the work rather than the review
# of it. loop_cost_sum and loop_cost_unknown are shared with the refresh loop
# above, so this section only ADDS to them.
#
# Review and fix legs continue the same leg count the refresh loop above left
# off at, for fs_archive_inbox: leg_no is the implement leg's own number (1)
# when no continuation ran, or the last continuation's number otherwise.
next_leg_no=$(( ${leg_no:-1} + 1 ))
review_loop_ended=""
review_loop_detail=""
review_iters_done='[]'
leg_cost=""
leg_usage=null
leg_error=""

# The branch head, read from the clone the one way anything here may read it:
# over upload-pack from outside, exactly like the fetch below. Nothing runs git
# INSIDE the clone -- the sandbox can write its config, and a key such as
# core.fsmonitor runs on the HOST.
clone_branch_head() {
    (cd "$origin_repo" && git ls-remote "$clone_dir" "refs/heads/$branch" \
        2>/dev/null) | awk 'NR == 1 { print $1 }'
}

# One iteration's record, built leg by leg. Anything not established is null
# rather than 0: "not reported" must never read as "none", which is the rule
# the implement leg's accounting follows too.
it_i=""
it_findings=null
it_review_exit=null
it_fix_exit=null
it_head_before=""
it_head_after=""
it_review_cost=null
it_fix_cost=null
it_review_usage=null
it_fix_usage=null

reset_iter() {
    it_i="$1"
    it_findings=null
    it_review_exit=null
    it_fix_exit=null
    it_head_before=""
    it_head_after=""
    it_review_cost=null
    it_fix_cost=null
    it_review_usage=null
    it_fix_usage=null
}

# The current iteration as a one-element array, or nothing when there is no
# current iteration. jq builds it, so every value is escaped whatever it came
# from. commits_added is null here and filled in after the fetch below: the
# count needs the objects in the origin repo, and nothing may run git in the
# clone to take it there.
iter_json() {
    [[ -n "$it_i" ]] || return 1
    jq -c -n \
        --argjson i "$it_i" \
        --argjson findings "$it_findings" \
        --argjson review_exit "$it_review_exit" \
        --argjson fix_exit "$it_fix_exit" \
        --arg head_before "$it_head_before" \
        --arg head_after "$it_head_after" \
        --argjson review_cost "$it_review_cost" \
        --argjson fix_cost "$it_fix_cost" \
        --argjson review_usage "$it_review_usage" \
        --argjson fix_usage "$it_fix_usage" \
        '[{
            i: $i,
            findings: $findings,
            review_exit: $review_exit,
            fix_exit: $fix_exit,
            head_before: (if $head_before == "" then null else $head_before end),
            head_after: (if $head_after == "" then null else $head_after end),
            commits_added: null,
            review_cost_usd: $review_cost,
            fix_cost_usd: $fix_cost,
            review_usage: $review_usage,
            fix_usage: $fix_usage,
        }]' 2>/dev/null
}

# Write review-loop.json from what is known right now. Called after every leg,
# so a runner killed mid-loop still leaves behind the iterations it finished.
# Built beside the file and renamed, which is atomic, so a reader watching the
# run sees one version or the other and never half of one.
save_review_loop() {
    local cur
    cur="$(iter_json)" || cur='[]'
    [[ -n "$cur" ]] || cur='[]'
    if jq -n \
        --argjson cap "$review_loop_cap" \
        --arg review_model "$review_model" \
        --arg review_harness "$review_harness" \
        --arg ended "$review_loop_ended" \
        --arg detail "$review_loop_detail" \
        --argjson prev "$review_iters_done" \
        --argjson cur "$cur" \
        '{
            cap: $cap,
            review_model: (if $review_model == "" then null else $review_model end),
            review_harness: (if $review_harness == "" then null else $review_harness end),
            ended: (if $ended == "" then null else $ended end),
            detail: (if $detail == "" then null else $detail end),
            iterations: ($prev + $cur),
        }' > "$run_dir/review-loop.json.part" 2>/dev/null; then
        mv -f "$run_dir/review-loop.json.part" "$run_dir/review-loop.json"
    else
        rm -f "$run_dir/review-loop.json.part"
    fi
}

# Move the current iteration into the finished list and write the file again.
close_iter() {
    local cur merged
    if cur="$(iter_json)" && [[ -n "$cur" ]]; then
        merged="$(jq -c -n --argjson d "$review_iters_done" --argjson c "$cur" \
            '$d + $c' 2>/dev/null)"
        [[ -n "$merged" ]] && review_iters_done="$merged"
    fi
    it_i=""
    save_review_loop
}

# Run one leg: kind (review or fix), iteration number, prompt file. Sets
# leg_rc, leg_cost (a number, or empty when the harness does not report one),
# leg_usage (a JSON object, or null) and leg_error (a model-error message, or
# empty).
run_leg() {
    local kind="$1" n="$2" prompt="$3"
    local leg_events="$run_dir/events-$kind-$n.jsonl"
    [[ "$mode" == "review-only" ]] && leg_events="$run_dir/events.jsonl"
    local leg_session="" leg_session_copy="" idx
    local -a cmd=("${sandbox_cmd[@]}")
    # A review leg's own harness (--review-harness, when given -- the
    # "rev_*" values, which fall back to the implement ones otherwise, see
    # where they are set above) decides its accounting, not the implement
    # harness's: a different harness means a different session-dir marker
    # to substitute, a different usage reader, and a different formatter
    # for its own output stream. A fix leg stays on the implement harness
    # throughout, by the existing rule that --review-model never changed.
    local leg_pi_session_dir="$pi_session_dir"
    local leg_usage_source="$usage_source"
    local leg_formatter="$formatter"
    # The harness THIS leg actually runs on -- $review_preamble_harness for a
    # review leg (set above beside the review preamble: $review_harness when
    # --review-harness was given, $harness otherwise), $harness for a fix
    # leg, which never overrides it. fs_archive_inbox's Stop-contract
    # invariant only holds for whichever harness this is, not for the
    # implement harness unconditionally.
    local leg_harness="$harness"
    if [[ "$kind" == "review" ]]; then
        cmd=("${review_sandbox_cmd[@]}")
        leg_pi_session_dir="$rev_pi_session_dir"
        leg_usage_source="$rev_usage_source"
        leg_formatter="$rev_formatter"
        leg_harness="$review_preamble_harness"
    fi
    leg_rc=1
    leg_cost=""
    leg_usage=""
    leg_error=""
    : > "$leg_events"

    # pi records its transcript, and the tokens with it, in a session
    # directory. Two legs must not share one, or the cost walk below bills
    # each leg for every leg before it. The sandbox command is exact
    # strings, so give this leg its own by substituting the one element
    # that is this leg's harness's session dir -- the review harness's
    # marker for a review leg, the implement harness's for anything else,
    # so a review leg under an independent harness is not searched for a
    # marker that was never in its own command in the first place, which
    # would silently leave it sharing the implement leg's session
    # directory and billing every leg for every leg before it.
    if [[ -n "$leg_pi_session_dir" ]]; then
        leg_session="$clone_dir/.git/pi-session-$kind-$n"
        for idx in "${!cmd[@]}"; do
            if [[ "${cmd[$idx]}" == "$leg_pi_session_dir" ]]; then
                cmd[$idx]="$leg_session"
            fi
        done
    fi

    printf '\n== fork-sandbox: %s leg, iteration %s ==\n' "$kind" "$n"
    # The prompt is a FILE on stdin, never an argument -- see the implement
    # leg's redirect for why (MAX_ARG_STRLEN), and note that the fix prompt
    # carries verdict text of no fixed size.
    if [[ -n "$leg_formatter" ]]; then
        "${cmd[@]}" < "$prompt" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$leg_events" \
            | "$leg_formatter"
    else
        "${cmd[@]}" < "$prompt" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$leg_events"
    fi
    leg_rc="${PIPESTATUS[0]:-1}"
    fs_archive_inbox "$next_leg_no" "$leg_harness" "$leg_rc"
    next_leg_no=$(( next_leg_no + 1 ))

    # The same three readers the implement leg's accounting uses, applied per
    # leg. Deliberately a copy of those walks rather than a refactor of them:
    # that block is the only failure detection a pi run has, and it is not
    # worth disturbing to save thirty lines here.
    if [[ -n "$leg_session" && -d "$leg_session" ]]; then
        leg_session_copy="$run_dir/pi-session-$kind-$n"
        # Take any earlier copy out first: cp -a onto an existing directory
        # nests one inside it, and the cost walk below would then sum both.
        # A runner re-run by hand in the same run dir is the case that does it.
        rm -rf "$leg_session_copy"
        cp -a "$leg_session" "$leg_session_copy" 2>/dev/null
        # pi exits 0 when its final turn ended in a provider error, so the
        # session file is the only place that failure is recorded. Take the
        # LAST turn's stopReason: an error pi retried past is not a failed leg.
        leg_error="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -rs '[.. | objects | select(has("stopReason"))] | last // empty
                      | select(.stopReason == "error")
                      | .errorMessage // "the model reported an error"' \
                 2>/dev/null || true)"
        leg_cost="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -s '[.. | objects | select(has("usage")) | .usage.cost.total? // empty]
                     | add
                     | if . == null then empty else (. * 1000000 | round) / 1000000 end' \
                 2>/dev/null)"
        leg_usage="$(find "$leg_session_copy" -name '*.jsonl' -exec cat {} + 2>/dev/null \
            | jq -s -c '[.. | objects | select(has("usage")) | .usage]
                        | if length == 0 then empty else
                            {
                              input_tokens: ([.[].input // empty] | add),
                              output_tokens: ([.[].output // empty] | add),
                              cache_read_tokens: ([.[].cacheRead // empty] | add),
                              cache_write_tokens: ([.[].cacheWrite // empty] | add),
                              reasoning_output_tokens: null,
                              total_tokens: ([.[].totalTokens // empty] | add),
                            }
                          end' 2>/dev/null)"
    elif [[ "$leg_usage_source" == "codex" && -s "$leg_events" ]]; then
        # codex reports tokens and no price, so a codex leg has counts and a
        # null cost. cached_input_tokens is part of input_tokens here, which
        # is why total_tokens is not a sum of all three.
        leg_usage="$(jq -R -s -c '
            [ split("\n")[] | fromjson? // empty
              | select(.type == "turn.completed") | .usage // empty ]
            | if length == 0 then empty else
                {
                  input_tokens: ([.[].input_tokens // empty] | add),
                  output_tokens: ([.[].output_tokens // empty] | add),
                  cache_read_tokens: ([.[].cached_input_tokens // empty] | add),
                  cache_write_tokens: null,
                  reasoning_output_tokens: ([.[].reasoning_output_tokens // empty] | add),
                  total_tokens: (([.[].input_tokens // empty] | add)
                                 + ([.[].output_tokens // empty] | add)),
                }
              end' "$leg_events" 2>/dev/null)"
    elif [[ -n "$leg_formatter" && -s "$leg_events" ]]; then
        leg_cost="$("$leg_formatter" --cost "$leg_events" 2>/dev/null)"
        leg_usage="$("$leg_formatter" --usage "$leg_events" 2>/dev/null)"
    fi
    [[ -n "$leg_usage" ]] || leg_usage=null
    if [[ ! "$leg_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        leg_cost=""
    fi
    if [[ -n "$leg_error" && "$leg_rc" == "0" ]]; then
        # Never turn a non-zero exit into a different one: the process's own
        # code is the better diagnosis when it has one.
        leg_rc=1
        printf 'fork-sandbox: the %s leg of iteration %s ended in a model error: %s\n' \
            "$kind" "$n" "$leg_error" >> "$sandbox_log"
    fi
    # The run's total cost is the implement leg plus every loop leg, and a sum
    # is only honest when every part is known. One leg the harness priced
    # nowhere makes the total unknown rather than low.
    if [[ -n "$leg_cost" ]]; then
        loop_cost_sum="$(jq -n --argjson a "$loop_cost_sum" --argjson b "$leg_cost" \
            '$a + $b' 2>/dev/null)"
        if [[ -z "$loop_cost_sum" ]]; then
            loop_cost_sum=0
            loop_cost_unknown=1
        fi
    else
        loop_cost_unknown=1
    fi
}

if [[ "$review_loop_cap" != "0" && -n "$review_prompt" ]]; then
    # Three reasons not to start at all, each recorded rather than silent.
    if [[ "$rc" != "0" ]]; then
        review_loop_ended="skipped"
        review_loop_detail="the session exited $rc, so there is nothing worth reviewing"
    else
        loop_head="$(clone_branch_head)"
        if [[ -z "$loop_head" ]]; then
            review_loop_ended="skipped"
            review_loop_detail="branch $branch could not be read from the clone"
        elif [[ "$loop_head" == "$base_sha" ]]; then
            review_loop_ended="skipped"
            review_loop_detail="the session committed nothing, so there is nothing to review"
        fi
    fi

    loop_i=1
    while [[ -z "$review_loop_ended" ]] && (( loop_i <= review_loop_cap )); do
        reset_iter "$loop_i"
        it_head_before="$loop_head"
        save_review_loop

        # A verdict from a previous iteration must never be read as this
        # one's, so the path starts empty whatever left something there.
        rm -f "$review_verdict_file"

        # review_prompt is static, built once at launch -- but the review
        # prompt body (fs_emit_review_prompt_body) tells the review leg that
        # an unfollowed addendum is a finding, and by the time any review
        # leg runs, fs_archive_inbox has already moved every addendum an
        # earlier claude leg saw out of the live inbox this sandbox binds
        # and into inbox-delivered/, where nothing but this leg's own prompt
        # (built fresh here, the same way refresh_build_prompt does it for a
        # continuation) ever carries it back. Without this, the review leg's
        # own contract is impossible to meet on exactly the harness where it
        # is enforceable: it would approve a branch that left a claude leg's
        # addendum unfollowed, for no reason it could see.
        review_prompt_iter="$run_dir/review-prompt-$loop_i.md"
        {
            cat -- "$review_prompt"
            rp_addenda_list="$(fs_addenda_dirs)"
            if [[ -n "$rp_addenda_list" ]]; then
                printf '\n---\n\n## Operator addenda delivered to earlier legs of this run\n\n'
                printf 'The operator sent the messages below to an earlier leg of this run,\n'
                printf 'oldest first. The live inbox bound into this sandbox no longer holds\n'
                printf 'them -- a claude leg archives what it saw the moment it ends -- so\n'
                printf 'this is the only copy this leg will see. Check the commit range\n'
                printf 'under review against each one: if it asks for work the commits do\n'
                printf 'not contain, that is a finding under "An unfollowed addendum is a\n'
                printf 'finding" above, citing the message file itself.\n'
                while IFS= read -r rp_dir; do
                    [[ -n "$rp_dir" ]] || continue
                    for rp_file in "$rp_dir"/*.md; do
                        [[ -f "$rp_file" ]] || continue
                        printf '\n### %s\n\n' "${rp_file##*/}"
                        cat -- "$rp_file"
                    done
                done <<< "$rp_addenda_list"
            fi
        } > "$review_prompt_iter.part"
        mv -- "$review_prompt_iter.part" "$review_prompt_iter"

        run_leg review "$loop_i" "$review_prompt_iter"
        it_review_exit="$leg_rc"
        it_review_cost="${leg_cost:-null}"
        it_review_usage="$leg_usage"
        save_review_loop
        if [[ "$leg_rc" != "0" ]]; then
            review_loop_ended="harness-error"
            review_loop_detail="the review leg of iteration $loop_i exited $leg_rc${leg_error:+ ($leg_error)}"
            close_iter
            break
        fi

        # The verdict is DATA. It is copied, counted and concatenated into a
        # prompt file -- never sourced, never evaluated, never put on a
        # command line. It is also written by a session, so a symlink at that
        # path is not a verdict: refuse it rather than follow it out of the
        # clone.
        verdict_copy="$run_dir/review-verdict-$loop_i.md"
        if [[ -L "$review_verdict_file" || ! -f "$review_verdict_file" ]]; then
            review_loop_ended="harness-error"
            review_loop_detail="the review leg of iteration $loop_i left no verdict at $review_verdict_file"
            close_iter
            break
        fi
        # The run dir outlives the clone, so the copy is the record. Take the
        # original away in the same breath, so iteration i+1 cannot re-read it.
        cp -- "$review_verdict_file" "$verdict_copy" 2>/dev/null
        rm -f "$review_verdict_file"
        if [[ ! -s "$verdict_copy" ]]; then
            review_loop_ended="harness-error"
            review_loop_detail="the review leg of iteration $loop_i wrote an empty verdict"
            close_iter
            break
        fi

        # Untrusted text on its way to a terminal: strip control characters so
        # an ESC or a CR in the verdict cannot spoof the pane or the monitor.
        verdict_line="$(head -n 1 "$verdict_copy" | tr -d '\000-\037\177' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # Deliberately nothing here checks the "## Report" section. The first
        # line is the contract; the report is a courtesy to the orchestrator,
        # and an absent, empty or duplicated one must never turn a valid
        # verdict into a failed loop -- fork-sandbox-status.sh falls back to
        # printing the whole verdict when the section is not usable.
        case "$verdict_line" in
        APPROVED)
            it_findings=0
            review_loop_ended="approved"
            printf 'fork-sandbox: review iteration %s: APPROVED\n' "$loop_i"
            close_iter
            break
            ;;
        FINDINGS)
            ;;
        *)
            review_loop_ended="harness-error"
            review_loop_detail="the review leg of iteration $loop_i wrote a first line that is neither APPROVED nor FINDINGS"
            close_iter
            break
            ;;
        esac

        # One finding per paragraph, each citing file:line -- so count the
        # paragraphs that carry a citation. That is what the prompt asks for
        # and all that can be counted without reading the prose.
        it_findings="$(awk '
            NR == 1 { next }
            /^## Report$/ { exit }
            /^[[:space:]]*$/ { if (hit) n++; hit = 0; next }
            /[^[:space:]:]+:[0-9]+/ { hit = 1 }
            END { if (hit) n++; print n + 0 }' "$verdict_copy" 2>/dev/null)"
        [[ "$it_findings" =~ ^[0-9]+$ ]] || it_findings=null
        printf 'fork-sandbox: review iteration %s: FINDINGS (%s cited)\n' \
            "$loop_i" "$it_findings"
        save_review_loop

        if [[ "$mode" == "review-only" ]]; then
            review_loop_ended="findings"
            close_iter
            break
        fi

        # The fix leg's prompt: the generated header, then the verdict. Built
        # as a file and redirected -- the verdict has no size limit, and one
        # argv string is capped at 128KB.
        fix_prompt="$run_dir/fix-prompt-$loop_i.md"
        {
            cat -- "$fix_prompt_header"
            printf '\n---\n\n'
            awk '/^## Report$/ { exit } { print }' "$verdict_copy"
        } > "$fix_prompt.part"
        mv -f "$fix_prompt.part" "$fix_prompt"

        run_leg fix "$loop_i" "$fix_prompt"
        it_fix_exit="$leg_rc"
        it_fix_cost="${leg_cost:-null}"
        it_fix_usage="$leg_usage"
        it_head_after="$(clone_branch_head)"
        save_review_loop
        if [[ "$leg_rc" != "0" ]]; then
            review_loop_ended="harness-error"
            review_loop_detail="the fix leg of iteration $loop_i exited $leg_rc${leg_error:+ ($leg_error)}"
            close_iter
            break
        fi
        if [[ -z "$it_head_after" ]]; then
            review_loop_ended="harness-error"
            review_loop_detail="branch $branch could not be read from the clone after the fix leg of iteration $loop_i"
            close_iter
            break
        fi
        if [[ "$it_head_after" == "$it_head_before" ]]; then
            # The same model reviews its own work here, so it can argue with
            # itself indefinitely. An iteration that committed nothing is the
            # end of the argument, not a reason to run another one.
            review_loop_ended="no-progress"
            printf 'fork-sandbox: review iteration %s: the fix leg committed nothing\n' \
                "$loop_i"
            close_iter
            break
        fi
        loop_head="$it_head_after"
        close_iter
        loop_i=$(( loop_i + 1 ))
    done
    [[ -n "$review_loop_ended" ]] || review_loop_ended="cap"
    save_review_loop
    printf 'fork-sandbox: review loop ended: %s\n' "$review_loop_ended"
    if [[ "$mode" == "review-only" ]]; then
        case "$review_loop_ended" in
            approved) printf 'fork-sandbox: review-only: APPROVED\n' ;;
            findings) printf 'fork-sandbox: review-only: FINDINGS (%s cited)\n' "$it_findings" ;;
        esac
        printf 'fork-sandbox: review verdict: %s\n' "$run_dir/review-verdict-1.md"
    fi
fi

# In review-only mode the sole leg is the review leg, so its accounting is the
# run accounting as well. This also makes cost_usd and total_cost_usd agree.
if [[ "$mode" == "review-only" ]]; then
    run_cost="$leg_cost"
    run_usage="$leg_usage"
    run_error="$leg_error"
    if [[ "$run_cost" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        run_cost_fmt="$(printf '%.6f' "$run_cost")"
    else
        run_cost_fmt=""
    fi
    [[ "$review_loop_ended" == "harness-error" ]] && rc=1
fi

# The other half of the deferral above: for a --review-loop or --refresh-at
# run the run is over here -- every loop ran, or was skipped and said why --
# so this is where its exit code is published, which is what puts a
# watcher's terminal event after the last leg rather than in the middle of
# either loop. The pi check above may have written the same value already;
# writing it again costs nothing and keeps this the one place that ends a
# loop run.
if [[ "$review_loop_cap" != "0" || "$refresh_enabled" == "1" ]]; then
    printf '%s\n' "$rc" > "$run_dir/exit-code"
fi

# The session and every loop leg are done with the credential and the
# services. Clean both up now rather than lean on the trap, which a
# --keep-session run never reaches: that path ends in exec. run_cleanup runs
# its body once, so the EXIT trap is a no-op after this.
run_cleanup

printf '\n'
if [[ "$rc" != "0" ]]; then
    printf 'fork-sandbox: the session exited %s\n' "$rc"
fi

# Bring the work back. Fetching is the one way into the real repo that cannot
# be turned into code execution by the clone's config, so the work crosses
# back as objects and nothing else. Nothing below runs git inside the clone:
# the sandbox could write its config, and a key such as core.fsmonitor runs
# on the HOST. Every git command here runs in the origin repo, which is the
# user's own.
fetched=0
if (cd "$origin_repo" && git fetch --quiet "$clone_dir" "$branch:$branch"); then
    fetched=1
fi

n_commits=0
removed=0
if (( fetched )); then
    n_commits="$( (cd "$origin_repo" && git rev-list --count "$return_base_sha..$branch") 2>/dev/null || printf 0 )"
    if [[ "$n_commits" == "0" ]]; then
        # The branch is exactly where it started, so removing it leaves the
        # repo as it was. Compare the sha rather than trust the count.
        head_now="$( (cd "$origin_repo" && git rev-parse "$branch") 2>/dev/null || true )"
        if [[ "$head_now" == "$return_base_sha" ]] \
            && (cd "$origin_repo" && git branch -q -D "$branch") >/dev/null 2>&1; then
            removed=1
        fi
    fi
fi

# Now that the origin repo holds the objects, each loop iteration's
# commits_added can be counted. It could not be taken while the loop ran:
# counting needs the commits locally, and nothing may run git in the clone to
# count them there. A run killed mid-loop keeps its iterations and leaves this
# field null, which is the same "not established" the rest of the record uses.
if (( fetched )) && [[ -s "$run_dir/review-loop.json" ]]; then
    loop_counts=""
    while IFS="$(printf '\t')" read -r hb ha; do
        c=null
        if [[ -n "$hb" && -n "$ha" ]]; then
            c="$( (cd "$origin_repo" && git rev-list --count "$hb..$ha") 2>/dev/null || printf null )"
            [[ "$c" =~ ^[0-9]+$ ]] || c=null
        fi
        loop_counts+="$c"$'\n'
    done < <(jq -r '.iterations[]? | [(.head_before // ""), (.head_after // "")] | @tsv' \
                "$run_dir/review-loop.json" 2>/dev/null)
    loop_counts_json="$(printf '%s' "$loop_counts" | jq -R -s -c \
        'split("\n") | map(select(length > 0) | fromjson)' 2>/dev/null)"
    if [[ -n "$loop_counts_json" ]] \
        && jq --argjson c "$loop_counts_json" \
            '.iterations |= [range(0; length) as $i | .[$i] + {commits_added: $c[$i]}]' \
            "$run_dir/review-loop.json" > "$run_dir/review-loop.json.part" 2>/dev/null; then
        mv -f "$run_dir/review-loop.json.part" "$run_dir/review-loop.json"
    else
        rm -f "$run_dir/review-loop.json.part"
    fi
fi

# What the whole run cost: the implement leg plus every loop leg. A sum is
# only honest when every part is a number, so one leg the harness priced
# nowhere -- codex prices none of them -- leaves the total null rather than
# low. cost_usd keeps meaning the implement leg alone.
total_cost_fmt=""
if [[ "$mode" == "review-only" ]]; then
    total_cost_fmt="$run_cost_fmt"
elif [[ -n "$run_cost_fmt" && "$loop_cost_unknown" != "1" ]]; then
    total_cost_raw="$(jq -n --argjson a "$run_cost_fmt" --argjson b "$loop_cost_sum" \
        '(($a + $b) * 1000000 | round) / 1000000' 2>/dev/null)"
    if [[ "$total_cost_raw" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        total_cost_fmt="$(printf '%.6f' "$total_cost_raw")"
    fi
fi

report_from="session"
if compgen -G "$run_dir/review-verdict-*.md" >/dev/null 2>&1; then
    report_from="review"
fi

# Did the work come back authored by this repo's own identity? The clone is
# seeded with the origin's effective user.email (fs_make_clone in the lib says
# why), so it should. Before that seeding existed a repo whose identity was a
# local override got commits authored by whatever ~/.gitconfig held, and
# nothing downstream noticed: integration re-creates the commits on the host,
# and cherry-pick and rebase deliberately keep the author. Silent misattribution
# is how that survived, so the run checks itself rather than wait for someone to
# look. A report only -- rewriting authorship on fetch would be a surprise, and
# integration is where that call belongs. When the seeding works this is empty
# and the summary reads exactly as before, so silence is the pass signal.
#
# The addresses come from the session's commits and are untrusted text, so
# control characters go the same way they do for the subjects below.
author_email_want=""
author_email_bad=""
if (( fetched )) && [[ "$n_commits" != "0" ]]; then
    author_email_want="$( (cd "$origin_repo" && git config --get user.email) 2>/dev/null || true )"
    if [[ -n "$author_email_want" ]]; then
        author_email_bad="$( (cd "$origin_repo" \
            && git log --format='%ae' "$return_base_sha..$branch") 2>/dev/null \
            | tr -d '\000-\010\013-\037\177' \
            | grep -vxF -- "$author_email_want" | sort -u || true )"
    fi
fi

# The outbox is measured here, at the end of the run, rather than checked
# live as the agent writes to it: a local run has nothing to "pull" the way
# a k8s run's client does, so there is no point to enforce and nothing to
# refuse -- only a heads-up if the agent left more there than the cap allows.
# Nothing is deleted either way; the files stay on disk for the operator to
# look at and clean up themselves.
outbox_bytes="$(du -sb -- "$outbox_dir" 2>/dev/null | cut -f1)"
[[ -n "$outbox_bytes" ]] || outbox_bytes=0
if (( outbox_bytes > outbox_max_bytes )); then
    printf 'fork-sandbox: WARNING: outbox is %s bytes, over the %s byte cap.\n' \
        "$outbox_bytes" "$outbox_max_bytes" >&2
    printf 'fork-sandbox: files are still on disk at %s -- nothing was deleted.\n' \
        "$outbox_dir" >&2
fi
# Recorded in run.env the same way cost= and model= are refreshed above:
# replace rather than append, since a reader takes the first match, and
# build the replacement beside the file and rename, which is atomic.
if [[ -s "$run_dir/run.env" ]] \
    && grep -v '^outbox_bytes=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'outbox_bytes=%s\n' "$outbox_bytes" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi
if [[ -s "$run_dir/run.env" ]] \
    && grep -v '^outbox_max_bytes=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
    printf 'outbox_max_bytes=%s\n' "$outbox_max_bytes" >> "$run_dir/run.env.part"
    mv -f "$run_dir/run.env.part" "$run_dir/run.env"
else
    rm -f "$run_dir/run.env.part"
fi

{
    printf '== fork-sandbox summary ==\n'
    printf 'branch:   %s\n' "$branch"
    printf 'mode:     %s\n' "$mode"
    printf 'origin:   %s\n' "$origin_repo"
    printf 'clone:    %s\n' "$clone_dir"
    printf 'exit:     %s\n' "$rc"
    printf 'commits:  %s\n' "$n_commits"
    if [[ -n "$run_cost_fmt" ]]; then
        printf 'cost:     $%s\n' "$run_cost_fmt"
    fi
    # One line for the review loop when it ran at all, including the case
    # where it was skipped and why.
    if [[ -n "$review_loop_ended" ]]; then
        if [[ "$review_loop_ended" == "skipped" ]]; then
            printf 'review:   skipped -- %s\n' "$review_loop_detail"
        else
            printf 'review:   %s iteration(s), ended %s\n' \
                "$(jq '.iterations | length' "$run_dir/review-loop.json" 2>/dev/null || printf '?')" \
                "$review_loop_ended"
        fi
    fi
    # Its sibling for --refresh-at, printed only when something happened --
    # either a continuation actually ran, or a leg was nudged and never wrote
    # one, both of which are worth a line. A run that never came near its
    # threshold (the common case, since the flag is on by default) reads
    # exactly as it did before this feature existed.
    if [[ "$refresh_leg_n" -gt 0 || "$refresh_ended" == "no-handoff" ]]; then
        printf 'refresh:  %s continuation leg(s), ended %s\n' \
            "$refresh_leg_n" "$refresh_ended"
    fi
    # The total is printed only when it actually spent something beyond the
    # coding session's own cost, so a run with neither flag -- or with
    # neither ever doing anything -- reads exactly as it did before either
    # feature existed.
    if [[ -n "$total_cost_fmt" && "$total_cost_fmt" != "$run_cost_fmt" ]]; then
        printf 'total:    $%s  (the session and every review-loop or continuation leg)\n' \
            "$total_cost_fmt"
    fi
    if [[ -d "$run_dir/pi-session" ]]; then
        printf 'session:  %s\n' "$run_dir/pi-session"
    fi
    if (( ! fetched )); then
        printf 'fetched:  NO -- the work is in the clone only\n'
    elif (( removed )); then
        printf 'fetched:  nothing. The session made no commits, so branch %s\n' "$branch"
        printf '          was removed again and %s is unchanged.\n' "$origin_repo"
    else
        printf 'fetched:  yes. Branch %s is now in %s\n' "$branch" "$origin_repo"
    fi
    if (( fetched )) && [[ "$n_commits" != "0" ]]; then
        # The commits are untrusted, and git passes a subject through
        # verbatim when stdout is not a tty. Strip control characters so an
        # ESC or CR planted in a commit message cannot spoof this summary in
        # the pane or the monitor stream. Tab and newline stay.
        printf '\n'
        (cd "$origin_repo" && git log --oneline --no-decorate "$return_base_sha..$branch") \
            | tr -d '\000-\010\013-\037\177'
        printf '\n'
        (cd "$origin_repo" && git diff --stat "$return_base_sha" "$branch") \
            | tr -d '\000-\010\013-\037\177'
    fi
    if (( fetched )) && [[ "$n_commits" != "0" ]]; then
        printf '\nReview the branch before you build it. It is agent-written code,\n'
        printf 'and a Makefile or package.json script in it runs on the host.\n'
    else
        printf '\nNothing landed in %s. Whatever the session wrote is still\n' "$origin_repo"
        printf 'in the clone at %s\n' "$clone_dir"
    fi
    # Last, so it is the hardest line in the summary to skim past.
    if [[ -n "$author_email_bad" ]]; then
        printf '\nWARNING: a returned commit was authored by an unexpected address.\n'
        printf '  expected: %s   (the user.email %s resolves to)\n' \
            "$author_email_want" "$origin_repo"
        printf '%s\n' "$author_email_bad" | sed 's/^/  found:    /'
        printf 'The clone is seeded with the repo user.email, so a mismatch means\n'
        printf 'that seeding regressed. Fix authorship before you integrate: rebase\n'
        printf 'and cherry-pick both keep the author, so it lands as-is otherwise.\n'
    fi
} > "$run_dir/summary.txt" 2>&1

# The same facts, structured, so a caller never has to parse the prose
# above — a decimal cost especially, which the obvious grep-and-strip
# mangles. jq builds it, so every value is escaped properly: commit
# subjects come from the session and are untrusted text. A jq that fails
# leaves no file, and summary.txt, which is what a person reads, stands.
commit_list="$( (cd "$origin_repo" && git log --format='%H %s' "$return_base_sha..$branch") 2>/dev/null \
    | jq -R -s 'split("\n") | map(select(length > 0))
                | map({sha: .[0:40], subject: .[41:]})' 2>/dev/null )"
[[ -n "$commit_list" ]] || commit_list='[]'
# The identity check, structured: the address the commits should carry, and
# every other one they actually do. An empty array is the pass, and it is the
# array a caller can assert on without parsing the warning prose above.
author_email_bad_json="$(printf '%s' "$author_email_bad" \
    | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)"
[[ -n "$author_email_bad_json" ]] || author_email_bad_json='[]'
fetched_json=false
(( fetched )) && fetched_json=true
removed_json=false
(( removed )) && removed_json=true
session_dir_json=""
[[ -d "$run_dir/pi-session" ]] && session_dir_json="$run_dir/pi-session"
ended_at="$(date +%s)"

jq -n \
    --argjson version 1 \
    --arg mode "$mode" \
    --arg harness "$harness" \
    --arg harness_version "$harness_version" \
    --arg usage_source "$usage_source" \
    --argjson usage "$run_usage" \
    --arg model "$model" \
    --arg branch "$branch" \
    --arg origin_repo "$origin_repo" \
    --arg clone_dir "$clone_dir" \
    --arg run_dir "$run_dir" \
    --arg base_sha "$base_sha" \
    --arg session_dir "$session_dir_json" \
    --arg harness_error "$run_error" \
    --argjson exit_code "$rc" \
    --argjson commits "$n_commits" \
    --argjson fetched "$fetched_json" \
    --argjson branch_removed "$removed_json" \
    --argjson cost_usd "${run_cost_fmt:-null}" \
    --argjson total_cost_usd "${total_cost_fmt:-null}" \
    --argjson started_at "$started_at" \
    --argjson ended_at "$ended_at" \
    --argjson commits_list "$commit_list" \
    --arg author_email "$author_email_want" \
    --argjson author_email_unexpected "$author_email_bad_json" \
    --arg refresh "$refresh_ended" \
    --arg report_from "$report_from" \
    --argjson continuations "$continuations_json" \
    --argjson outbox_bytes "$outbox_bytes" \
    --argjson outbox_max_bytes "$outbox_max_bytes" \
    '{
        version: $version,
        mode: $mode,
        harness: $harness,
        harness_version: (if $harness_version == "" then null else $harness_version end),
        model: (if $model == "" then null else $model end),
        branch: $branch,
        origin_repo: $origin_repo,
        clone_dir: $clone_dir,
        run_dir: $run_dir,
        base_sha: $base_sha,
        exit_code: $exit_code,
        harness_error: (if $harness_error == "" then null else $harness_error end),
        commits: $commits,
        commits_list: $commits_list,
        author_email: (if $author_email == "" then null else $author_email end),
        author_email_unexpected: $author_email_unexpected,
        fetched: $fetched,
        branch_removed: $branch_removed,
        cost_usd: $cost_usd,
        total_cost_usd: $total_cost_usd,
        refresh: $refresh,
        report_from: $report_from,
        continuations: $continuations,
        outbox_bytes: $outbox_bytes,
        outbox_max_bytes: $outbox_max_bytes,
        usage: $usage,
        usage_source: (if $usage == null then null else $usage_source end),
        session_dir: (if $session_dir == "" then null else $session_dir end),
        started_at: $started_at,
        ended_at: $ended_at,
        duration_seconds: ($ended_at - $started_at),
    }' > "$run_dir/summary.json" 2>/dev/null \
    || rm -f "$run_dir/summary.json"

# Append this run to the durable run log (~/.claude/sandbox-runs.jsonl),
# however it ended. The tool owns the record shape and reads summary.json,
# task-meta.json and the handoff out of the run dir itself. Best-effort: a
# failed append must not fail the run.
if [[ -n "$run_log_bin" && -x "$run_log_bin" ]]; then
    "$run_log_bin" record --run-dir "$run_dir" >> "$sandbox_log" 2>&1 \
        || printf 'fork-sandbox: run-log append failed; see %s\n' \
            "$sandbox_log" >&2
fi

cat "$run_dir/summary.txt"

if [[ "$keep_open" == "1" ]]; then
    cd "$origin_repo" 2>/dev/null || cd /
    exec "$user_shell" -i
fi
exit "$rc"
RUNNER
} > "$run_dir/run.sh"
chmod +x "$run_dir/run.sh"

where="here, in the foreground"
if ! $foreground; then
    # -d leaves it detached, so this never takes the caller's focus and never
    # adds a window to the caller's session. It also works outside tmux: with
    # no server running, tmux starts one.
    if ! tmux new-session -d -s "$session_name" -n "$session_name" \
        -c "$origin_repo" "$run_dir/run.sh"; then
        echo "Error: tmux could not start a session. Run it here with" >&2
        echo "--foreground, or start the generated runner yourself:" >&2
        echo "$run_dir/run.sh" >&2
        exit 1
    fi
    where="detached tmux session $session_name"
fi

# Its own leading newline, so an unused line adds nothing to the block.
checkout_line=""
if [[ -n "$checkout_ref" ]]; then
    checkout_line="$(printf '\n  start:    %s (%.12s)' "$checkout_ref" "$base_sha")"
fi

harness_line="$harness"
[[ -z "$model" ]] || harness_line="$harness  ($model)"

cat <<EOF
fork-sandbox: launched in $where
  harness:  $harness_line
  branch:   $branch  ->  $origin_repo$checkout_line
  clone:    $clone_dir
  run dir:  $run_dir
  log:      $run_dir/events.jsonl

EOF

# Only claude speaks the stream-json the formatter renders. Every other harness
# writes something else — pi plain text, codex its own JSONL — so point at what
# does hold the output instead of at commands that print nothing. Keyed on the
# formatter rather than on a harness name, so a harness added later cannot
# promise a rendered log it does not produce.
if [[ -z "$run_formatter" ]]; then
    cat <<EOF
  watch:    $status_cmd --monitor $run_dir   (state and the final summary)
  status:   $status_cmd $run_dir
  output:   $run_dir/events.jsonl   ($harness's own output, whatever the name says)
EOF
else
    cat <<EOF
  watch:    $status_cmd --monitor $run_dir
  follow:   $status_cmd --follow $run_dir   (every event, live, for a terminal)
  status:   $status_cmd $run_dir
  result:   $status_cmd --result $run_dir
EOF
fi

if ! $foreground; then
    cat <<EOF
  attach:   tmux attach -t $session_name
            (from inside tmux: tmux switch-client -t $session_name)

Nothing in the tmux session needs input, and the run directory holds
everything worth reading, so attach only to troubleshoot.
EOF
    if (( keep_open )); then
        echo "It stays open on a shell when the run ends. Close it yourself."
    else
        echo "It closes when the run ends, so a session that is still there"
        echo "means the work is still going."
    fi
fi

cat <<EOF

The session is headless and needs no keypress. When it exits, branch
'$branch' is fetched into $origin_repo on its own.
It sees committed state only, has no global ~/.claude, no ssh keys and no
tailnet, and it cannot push.
EOF

if [[ "$harness" == "pi" ]]; then
    cat <<EOF
The OpenRouter key in $harness_env_file is the one
credential inside. No Claude token is copied, so this run cannot spend
the subscription. pi has the commit-then-review skill and the script
toolbox, but writes plain text, so read
$run_dir/events.jsonl rather than --result. Its session
is copied to $run_dir/pi-session when the run
ends, and the summary reports what the run cost from it.
EOF
elif [[ "$harness" == "pi-local" ]]; then
    cat <<EOF
This sandbox has no network at all, and the model it runs on is one you
host, so the run holds no credential and costs nothing. Nothing can be
installed or fetched in there — the clone, its provisioned dependencies
and any per-run services are all it has. pi has the commit-then-review
skill and the script toolbox, but writes plain text, so read
$run_dir/events.jsonl rather than --result. Its session
is copied to $run_dir/pi-session when the run ends.
EOF
elif [[ "$harness" == "codex" ]]; then
    cat <<EOF
The sandbox carries a live Codex access token so it can reach the model, but
its refresh token is replaced with a placeholder. It has no GitHub token or
other service credential and cannot rotate the host's Codex sign-in.
EOF
else
    cat <<EOF
It carries no API tokens.
EOF
fi

cat <<EOF
Review the branch before you build it.
EOF

if $foreground; then
    exec "$run_dir/run.sh"
fi
