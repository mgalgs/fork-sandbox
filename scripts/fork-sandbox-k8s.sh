#!/usr/bin/env bash
# fork-sandbox-k8s.sh -- run a sandboxed agent as a Kubernetes Job
#
# Usage: fork-sandbox-k8s.sh install [--dry-run]
#        fork-sandbox-k8s.sh submit [--dry-run] --branch NAME [--model MODEL]
#                            [--endpoint NAME] [--harness pi|claude|codex]
#                            [--pi-args ARGS] [--review-loop N] [--review-model MODEL]
#                            [--outbox-max SIZE]
#                            [--context-ro DIR | --context-secret NAME]
#                            [--thread-dir DIR] [--attach-dir DIR] [--run-dir DIR]
#                            [--checkout REF] [--services-trust-ref REF]
#                            [--extra-ref NAME=SHA]...
#                            [--session-state DIR] [--resume-session ID | --session-id ID]
#                            [--refresh-at N] [--refresh-max N]
#                            [--claude-credentials PATH]
#                            [--label key=value]... [--task-meta JSON]
#                            [--allow-namespace NS[:PORT]]... [--reach-probe HOST:PORT]...
#                            <project-path> <handoff-file>
#        fork-sandbox-k8s.sh run [--dry-run] [--timeout SECONDS] [--keep]
#                            --branch NAME [--model MODEL] [--endpoint NAME]
#                            [--harness pi|claude|codex] [--pi-args ARGS]
#                            [--review-loop N] [--review-model MODEL]
#                            [--outbox-dir DIR] [--outbox-max SIZE]
#                            [--context-ro DIR | --context-secret NAME]
#                            [--thread-dir DIR] [--attach-dir DIR] [--run-dir DIR]
#                            [--checkout REF] [--services-trust-ref REF]
#                            [--extra-ref NAME=SHA]...
#                            [--session-state DIR] [--resume-session ID | --session-id ID]
#                            [--refresh-at N] [--refresh-max N]
#                            [--claude-credentials PATH]
#                            [--label key=value]... [--task-meta JSON]
#                            [--allow-namespace NS[:PORT]]... [--reach-probe HOST:PORT]...
#                            <project-path> <handoff-file>
#        fork-sandbox-k8s.sh wait --branch NAME [--timeout SECONDS] [--probe]
#                            [--run-dir DIR]
#        fork-sandbox-k8s.sh collect --branch NAME [--outbox-dir DIR]
#                            [--outbox-max SIZE] [--review-loop N]
#                            [--keep] [--run-dir DIR] <project-path>
#        fork-sandbox-k8s.sh resume --run-dir DIR [--timeout SECONDS]
#        fork-sandbox-k8s.sh fetch --branch NAME
#                            [--upstream REF | --upstream-none REASON]
#                            <project-path>
#        fork-sandbox-k8s.sh say --branch NAME <text>
#        fork-sandbox-k8s.sh say --branch NAME -        # text from stdin
#        fork-sandbox-k8s.sh rm --branch NAME
#        fork-sandbox-k8s.sh check-grant [--allow-namespace NS[:PORT]]...
#                            [--reach-probe HOST:PORT]...
#                            [--context-ro DIR | --context-secret NAME]
#
# --model MODEL is REQUIRED on a K8S_PROXY_UPSTREAM (legacy) install. On a
# K8S_PROXY_ENDPOINTS install it is optional: the pod discovers the model
# (and its context window) from the proxy's /v1/models at startup -- see
# --endpoint below and fork-sandbox-k8s-entrypoint.sh.
#
# The Kubernetes analogue of fork-sandbox.sh: submit a task from anywhere
# with cluster access, and a few minutes later fetch a branch. See
# docs/kubernetes-runs.md for the design and docs/k8s-platform.md for the
# pluggable layer this script talks to. fork-sandbox.sh --k8s is a thin
# dispatcher onto the `run` verb below, for a caller already using
# fork-sandbox.sh; this script remains the direct entry point, and every
# verb below is unchanged by that dispatcher's existence.
#
# install renders manifests/k8s/ and this cluster's egress policy (from the
# platform plugin), applies both, and creates the Secret the model proxy
# reads its provider key from. Idempotent -- safe to run again after
# changing config.
#
# install --postmaster does everything plain install does, then also
# renders and applies the cluster postmaster: a single-replica Deployment
# running the same fork-sandbox-postmaster.sh a laptop runs. See the
# K8S_POSTMASTER_* keys below and docs/cluster-postmaster.md for the full
# setup. --dry-run covers this too, printing a placeholder line for the
# git deploy-key Secret instead of its content.
#
# With the mail API deployed (K8S_MAIL_API_TOKENS_FILE), install --postmaster
# also gives the team self-service access to it: it creates one shared
# "team" token, an operator-role token whose raw value lives in Secret
# fork-sandbox-mail-api-team-token, and serves that token's hash beside the
# tokens-file entries. It creates the Secret only when it is absent: a
# re-install reuses the token it finds and never rotates it, so it cannot lock
# the team out. `install --postmaster --rotate-team-token` is the one way to
# replace it (the pod rolls, and the old token stops working). A Role,
# fork-sandbox-mail-team, lets a teammate port-forward to the API and read
# that one Secret; it is bound to nobody unless K8S_MAIL_TEAM_SUBJECTS is
# set. See docs/mail-api.md, "Team access".
#
# submit renders a Job for one run, applies it, pushes the project's repo
# into the pod over the same `kubectl exec` channel the work later returns
# on, and writes the sentinel that lets the pod's entrypoint proceed. The
# pod holds no git credential and never pushes anywhere; it only receives.
#
# run is submit + wait + collect, literally -- the three phases are their
# own verbs (below) and run composes them: the one-shot equivalent of
# a local fork-sandbox.sh launch, for anywhere with cluster access. submit
# and fetch remain available on their own for when you want to start a run
# from one place and collect it later from somewhere else, rather than
# block on it. The wait polls for a sentinel the pod's entrypoint writes
# after the agent exits (/work/.run-complete, holding the agent's own exit
# code) -- never pod phase, which stays Running while the pod idles for a
# later fetch even after the agent itself has finished. A run still going
# at --timeout is left in place, never fetched and never removed, and the
# error names the fetch command to run by hand once it completes.
#
# wait is run's second phase on its own: it polls the same sentinel and,
# on success, prints the agent's exit code to stdout -- and nothing else to
# stdout -- and exits 0. A non-zero exit from wait means the wait itself
# failed, never the agent's exit status: an agent that ran to completion
# and exited 3 is a successful wait that prints 3. A caller probing in a
# loop must read the code: exit 2 is TERMINAL -- the run can never
# complete through this wait again (pod Failed, pod Succeeded and exited,
# job Failed condition, pod gone, malformed sentinel) -- give the run up;
# exit 1 is the probe's own deadline with the run possibly still going (or
# a usage error): probe again. exit 4 (only with --probe): the cluster
# could not be asked; the run's state is unknown -- neither adopt nor give
# up; probe again later.
#
# collect is run's third and last phase on its own: it reads the review
# loop's outcome (only when --review-loop N is given and non-zero), pulls
# the pod's /work/outbox back, pulls the run's evidence back (the agent's
# own transcript from /work/events*.jsonl plus the pod's logs, into a
# sibling `evidence` directory of the outbox -- never inside it, so
# operator-captured evidence stays distinguishable from the agent's own
# artifacts), fetches the branch into the named project, and removes the
# Job and pod unless --keep. Two automatic rules guard the removal: a run
# whose evidence could not be captured in full is NOT reaped (its
# resources are left in place with the manual `rm` command printed), and
# a run that produced nothing -- the agent exited 0, the fetch brought
# back zero commits, and the outbox holds no file the agent wrote -- keeps
# its job and exits 3 rather than reporting success. With --run-dir, it
# also finalizes the run directory submit created -- writing summary.json
# and calling sandbox-run-log.py record -- so the run gets a row in the
# durable run log; see "The durable run log" in docs/kubernetes-runs.md.
#
# wait and collect exist so a caller fanning out several runs can submit
# them all up front and then wait on and collect them independently, rather
# than blocking one run at a time through run.
#
# resume is run's own tail (wait, collect, the "run complete" line and its
# exit code) for a run submit already created, taking only that run's
# directory: a caller whose `run` process died while the Job kept going
# (a postmaster host restart, a pod eviction) picks the run up again
# without submitting a second Job. Everything the tail needs is read back
# from DIR/run.env, which submit writes -- BRANCH, PROJECT, OUTBOX_DIR,
# OUTBOX_MAX_BYTES, REVIEW_LOOP, KEEP, TIMEOUT and SUBMITTED_AT -- with
# the same strict KEY=VALUE reader collect uses (a file is never
# sourced). --timeout defaults to the run's recorded TIMEOUT minus the
# time elapsed since SUBMITTED_AT, floored at 60 seconds. A run
# directory with no run.env, or one without BRANCH or PROJECT, is refused
# (exit 1). Exit codes are run's own: the agent's, or the wait's nonzero
# rc (2 for a dead pod, after writing the run-log row; 1 for a timeout).
#
# resume is also the adopt path, so it refuses a run whose submit never
# finished pushing the run's inputs into the pod (the pod gives up on its
# own, so there is nothing to adopt). submit writes INPUTS_PUSH_EXPECTED=true
# at run.env's first write and INPUTS_PUSH_COMPLETE=true the moment the pod
# is told its inputs are complete; a run.env with the first and not the
# second is refused with exit 2 (the code a missing pod gets), after
# deleting the run's cluster objects by branch label as submit's failure
# trap does. A run.env with neither key (an older submit) is adopted as
# before.
#
# fetch runs `git fetch` against the pod's clone, the same channel in
# reverse, landing the branch in your real repo. It also signals the pod
# that the run has been collected, so it does not idle out its full TTL.
# It then points the fetched branch's upstream at whatever collect (via
# --upstream/--upstream-none) tells it submit resolved -- see "The upstream
# rule" in docs/kubernetes-runs.md. A standalone fetch, with neither flag,
# resolves it itself instead, against this repo's own HEAD or the remote
# default branch. Never fails the run either way: at worst it notes that no
# upstream was set.
#
# say sends an operator addendum to a run that is already going -- the
# Kubernetes analogue of fork-sandbox-say.sh, over the same kubectl exec
# channel submit and fetch already use. It resolves the pod from --branch
# exactly as fetch does, then writes one generated filename
# (<epoch>-<nn>.md, never taken from an argument) into /work/inbox inside
# the pod. The pod runs pi, which has no hook system, so delivery is the
# same hookless contract every non-claude harness gets: the agent reads the
# inbox itself, on a tool-call floor and around long commands, commits and
# its final report -- see fs_emit_prompt_preamble in fork-sandbox-lib.sh.
# fork-sandbox-say.sh itself is not taught to reach into a pod: it is
# blanket-approved specifically because its write is bounded to one
# structurally constrained host directory, and kubectl exec would replace
# that argument with a far larger one. This is a separate command instead.
#
# rm deletes the run's Job, its pod, and its ConfigMap.
#
# check-grant validates a --allow-namespace/--reach-probe/--context-ro/
# --context-secret grant with NO kubectl and NO cluster -- it runs exactly
# the same checks submit runs on those flags (the pairing rule, the
# per-probe HOST:PORT/DNS shape/grant-match checks, --context-ro's
# forks/-only + no-links checks, and --context-secret's name checks),
# sharing the same functions, so a grant check-grant accepts is one
# submit will also accept later, for the identical reason. It needs no
# k8s.env either. Exit 0 and, on stdout only, one line per flag in the order
# given (ALLOW_NAMESPACE=..., REACH_PROBE=..., then CONTEXT_RO=<realpath of
# DIR> when --context-ro was given, then CONTEXT_SECRET=<name> when
# --context-secret was given, always last) -- this is the grant file format the
# postmaster's per-thread grant store (fork-sandbox-mail.sh's `grant` verb)
# writes verbatim. Exit 1 for no flags at all or an unknown option (a usage
# error). Exit 2 for a refused value, printing the same message submit would
# print for the same input. See "Per-run namespace grants" in
# docs/kubernetes-runs.md.
#
# --dry-run (install, submit, run): print the rendered YAML and exit 0.
# Contacts nothing -- no kubectl, no git push, no cluster reachability
# check. This is how the rendering logic is tested without a cluster.
#
# --timeout SECONDS (run, wait): how long to wait for the agent before giving
# up. Defaults to 3600, matching the entrypoint's own RUN_TTL default --
# waiting longer than the pod itself will idle is pointless.
#
# --keep (run, collect): skip the final rm, leaving the Job and pod in place
# after a successful fetch.
#
# --checkout REF (submit, run): start the branch at the commit REF names
# instead of the repo's HEAD. REF is resolved in the origin repo before
# anything is created (an unresolvable ref is refused with no Job, Secret
# or proxy Pod left behind), and the resolved sha -- not the ref name -- is
# what the push sends, so the ref cannot move between the check and the
# push, the pushed revision is the one the push line reports, and (under
# --review-loop) the review base is the same revision the branch starts
# from. With no --checkout, HEAD is resolved and pushed as before.
#
# --extra-ref NAME=SHA (submit, run; repeatable): push one more commit into
# the pod as a branch named NAME, beside the run's own branch, in the SAME
# push. The pod (fork-sandbox-k8s-entrypoint.sh) then creates a LOCAL
# branch NAME at origin/NAME, verifies its sha is SHA, and leaves the run's
# branch checked out; nothing but the run's own branch comes back at fetch.
# NAME must match ^[a-z][a-z0-9-]{0,30}$, must not be the run's own branch,
# and may be given once; SHA must be a full 40- or 64-hex commit sha
# present in the origin repo. All three are checked before anything is
# created. The names and shas reach the pod as the EXTRA_REFS env var
# (space-separated NAME=SHA). Nothing else in the tooling passes it today
# but the postmaster, which hands a review thread's `sets` seat the human
# author's pushed commit as `upstream` (docs/agent-mail.md, "Upstream
# moved"). It is deliberately not part of any fork-sandbox.sh preset.
#
# --services-trust-ref REF (submit, run): the trusted base a per-run
# services spec (.agents/sandbox-services/services.yaml) is diffed against
# before it is honored -- exactly the trust gate --services-trust-ref
# applies to the local path's own hook. Only meaningful alongside
# --checkout: with no --checkout, the pushed revision is already the
# operator's own HEAD and the spec is trusted as-is; a --checkout with no
# --services-trust-ref disables per-run services for that run rather than
# trusting an unanchored ref, and a --checkout whose ref changed
# .agents/sandbox-services/ relative to REF disables them too -- both cases
# warn naming why. See docs/kubernetes-runs.md's "Per-run services" section.
#
# --session-state DIR / --resume-session ID / --session-id ID (submit, run):
# give this run the same harness conversation across many k8s wakes,
# exactly what a local run's own --session-state gives a persistent seat.
# cmd_submit pushes DIR into the pod at /work/session-store before the Job
# starts (same channel and window as --context-ro's own push); the
# entrypoint binds it into the harness's transcript directory and, for
# claude, resumes RESUME_SESSION, or, for pi, opens SESSION_ID under
# --session-dir; cmd_collect pulls the store back into DIR afterward, using
# fs_session_discover_id to report session_id in summary.json the way a
# local run's does. --resume-session (claude, discover-mode) and
# --session-id (pi, given-mode) each require --session-state, and only the
# one matching --harness applies -- see fs_harness_session_caps in
# fork-sandbox-lib.sh. DIR is validated with fs_validate_scratch_dir, the
# same whole-scratch-root rule --thread-dir/--attach-dir apply above. The
# store is tarred and capped at CONTEXT_MAX_BYTES (256 MiB), like
# --context-ro -- but unlike --context-ro, a store over the cap does not
# refuse the run: it warns and the run proceeds with no push and no
# session_state recorded in run.env, so a later collect will not pull one
# back either. The seat simply loses continuity for that one wake; there is
# no flag to raise this cap, unlike --outbox-max. See docs/kubernetes-runs.md.
#
# --refresh-at N / --refresh-max N (submit, run; claude only): the same
# self-refresh loop a local run has. N <= 1 is a fraction of the model's
# context window, larger is tokens; 0 disables; the default is 0.5, so
# every claude run refreshes unless told not to (--refresh-max defaults
# to 6 continuations). The threshold and cap reach the pod as
# REFRESH_THRESHOLD_TOKENS / REFRESH_MAX (and the assumed window as
# REFRESH_CONTEXT_WINDOW, for a warning only); the entrypoint runs the
# continuation legs and records them under /work, which collect pulls
# back as evidence and summarizes as refresh/continuations in
# summary.json. Resolved by fs_refresh_resolve in fork-sandbox-lib.sh, so
# local and k8s runs agree on defaults and refusals (pi is refused).
#
# --outbox-dir DIR (run, collect): where to land the pod's /work/outbox after the
# agent finishes. Defaults to the run directory's outbox for a run with a
# run directory; a standalone collect uses the branch's scratch directory. Pulled back over
# the same kubectl exec channel fetch uses, through
# fork-sandbox-k8s-outbox-extract.sh, which refuses the whole archive if it
# is oversized or contains anything unsafe (absolute paths, `..` components,
# symlinks) -- see that script's own header. Best-effort: a failure here
# warns and falls through rather than failing the run, since retrieving
# artifacts must never cost the branch itself.
#
# --outbox-max SIZE (submit, run, collect): raise the outbox size cap above the
# default 64 MiB (FS_OUTBOX_MAX_BYTES). Takes a plain byte count or a size
# with a K/M/G suffix (512K, 256M, 2G); no upper ceiling -- the operator
# raising it is the one accepting the extra disk cost. The effective value
# is threaded everywhere the cap matters: the rendered Job's
# OUTBOX_MAX_BYTES env var, the pod-side entrypoint check, the
# preamble text the agent reads, run's own pull-back head -c/stat guard,
# and the extractor's third argument -- so the pod, the client and the
# extractor can never disagree about the number.
#
# --review-loop N (submit, run, collect): on submit and run, after the coding
# leg, run a fresh review session against the branch and, on findings, a
# fresh fix session, up to N times -- the cluster analogue of
# fork-sandbox.sh's own --review-loop. The
# loop runs POD-SIDE, in fork-sandbox-k8s-review-loop.sh, shipped in the
# same per-run ConfigMap as the entrypoint; the review and fix prompts
# themselves are rendered HOST-SIDE, by fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body in fork-sandbox-lib.sh -- the same functions the
# local loop uses -- and shipped in alongside handoff.md, never composed a
# second time inside the pod. The outcome lands in the pod at
# /work/review-loop.json; `run` reads it back and prints a summary before
# fetching (see cmd_collect below), because the container's own exit code stays
# the CODING leg's regardless of how the loop ended -- see
# fork-sandbox-k8s-entrypoint.sh's comment on .run-complete for why. See
# docs/kubernetes-runs.md for the full design.
#
# --endpoint NAME (submit, run): the registered K8S_PROXY_ENDPOINTS entry
# the run is wired to -- the pod's PROXY_BASE_URL becomes the proxy's
# /e/NAME/v1 location instead of the legacy /api/v1 path. A name that is
# not registered is an error listing the registered names. Omitted, it
# resolves to K8S_DEFAULT_ENDPOINT in k8s.env when that names a
# registered entry (announced on stderr), then to the single registered
# endpoint when there is exactly one (announced on stderr), and is an
# error, listing the names, when there are several -- the same
# one-candidate rule agent-sandboxed applies when resolving a model, with
# the site default sitting between the flag and the one-candidate rule.
# On a legacy K8S_PROXY_UPSTREAM install it is an
# error: that render has no named endpoints. It is what makes --model
# optional on an endpoints install (see the note above); --harness
# claude keeps the requirement even on an endpoints install, because
# discovery only lists the pi endpoint's model ids, never a Claude Code
# model name. fork-sandbox.sh --k8s accepts the same omission on its
# own path: a model-less pi --k8s run skips the launcher's own --model
# requirement and lands here, where this install-mode-aware validation is
# the one that decides.
#
# --context-ro DIR (submit, run): push DIR into the pod at /work/context,
# read-only by convention, over the same gated kubectl-exec channel the
# repository push uses -- after the repository, before the
# .inputs-complete sentinel, so a failure here fails the run closed rather
# than leaving a half-received context directory for the agent to find.
# DIR must be a real directory under /var/tmp/claude-scratch/forks/, the
# same rule fork-sandbox.sh's own local --context-ro applies to its
# --bind-ro -- a blanket-approved script must not be pointable at an
# arbitrary host directory. DIR must not contain a symlink, refused on the
# host before anything is created or pushed -- tar cf's ordinary walk turns one into
# a link entry, which the pod-side extractor also refuses, but only after
# the Job exists, the pod is Ready and the repository has already been
# pushed. Capped at a fixed 256 MiB, checked twice,
# independently: spooled and checked on the host before anything is created
# or pushed
# (fork-sandbox-k8s.sh itself), and again pod-side by
# fork-sandbox-k8s-context-extract.sh before it extracts anything -- no
# --context-max flag, since a context directory is gathered notes and
# small caches, not a size nobody has needed to raise yet. Unlike the local
# flag's real --bind-ro, an emptyDir cannot be bound read-only per
# subdirectory, so read-only here is enforced by the prompt text the agent
# reads (a `## Gathered context` section appended to handoff.md), not by
# the filesystem.
#
# --context-secret NAME (submit, run): mount the Kubernetes Secret NAME
# read-only at /work/context in the agent container, one file per key. For
# a credential the task depends on, such as an API key for a preview
# environment. Anything that can create a pod can mount any Secret in its
# namespace, so the Secret must opt in: it must carry the label
# fork-sandbox/context=true and must NOT carry fork-sandbox/branch (rm and
# the submit trap delete Secrets by that label, so a context Secret carrying
# it would be deleted by the first run that uses it). Names starting
# fork-sandbox- (every installer-created Secret) and ending -claude-token
# (the per-run token Secrets) are refused by name. The name is checked with
# no cluster (check-grant, submit); the labels are checked by submit, after
# --dry-run's exit, with kubectl get secret. Mutually exclusive with
# --context-ro, which extracts into the same /work/context path. The
# handoff names the Secret and tells the agent never to print, copy, log or
# commit its contents.
#
# --thread-dir DIR / --attach-dir DIR (submit, run): push DIR into the pod
# at /thread / /attachments respectively -- the same in-pod paths a LOCAL
# sandbox run binds these two flags to (fork-sandbox.sh's own --thread-dir
# and --attach-dir), so the postmaster's generated prompt, which names
# those paths, needs no idea which backend a wake landed on. Validated with
# fs_validate_scratch_dir (the same whole-scratch-root rule
# fork-sandbox.sh's local --attach-dir/--thread-dir apply, not
# --context-ro's narrower forks/-only rule): the postmaster stages these
# under its mail root, which sits under the scratch root but not under
# forks/, so --context-ro's own rule would refuse every real wake.
# Symlinks and hard-linked files inside DIR are refused for the same
# tar-turns-a-link-into-a-link-entry reason --context-ro refuses them.
# Transport mirrors --context-ro exactly: spooled to its own tar, capped at
# the same CONTEXT_MAX_BYTES, pushed with its own kubectl exec through the
# same pod-side extractor, in the same window (after the repository push,
# before the .inputs-complete sentinel). The destination is an emptyDir
# volume, mounted only when the matching flag is given -- the pod's root
# filesystem is read-only, so nothing could mkdir /thread or /attachments
# for the extractor to write into otherwise. That emptyDir is writable, not
# read-only: read-only here is a convention the agent is expected to honor,
# not a filesystem guarantee, exactly like --context-ro's own
# not-really-read-only emptyDir above. This is accepted rather than a gap --
# the pod's copy is a disposable per-wake copy, and the host directory
# named by --thread-dir/--attach-dir is never written back, so an agent
# writing into its own /thread or /attachments only ever harms its own view
# of it.
#
# --run-dir DIR (submit, run): runner mode -- DIR is a run directory the
# launcher (fork-sandbox.sh's --k8s dispatch) already staged, holding
# run.sh and pipeline.json, and this run's job is to execute it rather than
# the usual single HARNESS/MODEL leg. Validated: an existing, non-symlink
# directory under the scratch forks root holding both run.sh and
# pipeline.json (fs_validate_scratch_dir plus the two-file check), refused
# by name otherwise. No run directory is created when this is given --
# DIR itself becomes run_dir, mktemp is skipped, and run.env is written
# into it (RUNNER=1, alongside the usual keys) instead of a fresh
# mktemp'd directory. The whole of DIR -- run.sh, pipeline.json, scripts/,
# inbox/, any step prompts -- is mounted into the agent container as an
# emptyDir at DIR's own absolute path (RUN_DIR in its env) and pushed in
# after the repository push, before the .inputs-complete sentinel -- see
# the entrypoint's own RUN_DIR handling for what it does once RUN_DIR is
# set. handoff.md is NOT written into DIR here -- the launcher already
# rendered its own implement prompt there before this command ran, and
# this command's own rendering exists only to size the context archive, so
# writing it over the launcher's file would feed the pod's first leg the
# wrong prompt (see the handoff.md/handoff-original.md split below, where
# runner mode's divergence from the ordinary single-leg case is spelled
# out). handoff-original.md is still written, but only if the launcher did
# not already leave one; continuation-prompt-header.md joins it when
# refresh is enabled, since --k8s runner mode's own prompt rendering does
# not reach this far (see docs/kubernetes-runs.md's composed-pipelines
# section). The claude token Secret, per-run claude proxy and
# CLAUDE_PROXY_BASE_URL env are created when ANY seat (step or fix) in
# pipeline.json is claude, not only when --harness is -- harness/model
# mean nothing in runner mode; the forwarded --harness/--model instead
# become plain HARNESS/MODEL record keys in run.env, read back by resume,
# collect and the fleet status line. --dry-run with --run-dir prints the
# manifests and removes DIR, the same "no trace of a dry run" rule as
# ordinary submit. On collect, a RUNNER=1 run.env means pulling the pod's
# whole run dir back (step-<K>-loop.json, progress.json, events, the
# runner's own summary.json) and merging it with this client's summary
# rather than writing a lone single-leg one -- see cmd_collect.
#
# --pi-args ARGS (submit, run): extra arguments, verbatim, for the pod's
# pi coding-leg invocation -- e.g. "--thinking low" for a persona whose
# frontmatter carries `thinking:`. Only the pi harness starts pi, so
# --harness claude is refused with it -- the same refusal fork-sandbox.sh's
# own --pi-args applies. The value passes the same fs_reject_unsafe_chars
# guard as --branch/--model/--checkout, plus a double quote or backslash
# of its own, because the rendered Job embeds it as a double-quoted YAML
# scalar, at parse time, before any Job, Secret or proxy Pod exists. It
# travels into the pod as the PI_ARGS env
# var (exactly the path --model takes) and is split on whitespace into an
# array the entrypoint expands as arguments: splitting, never eval, never
# a shell-string interpolation. Unset or empty adds no arguments at all.
#
# --claude-credentials PATH (submit, run; --harness claude only): pins the
# OAuth credential file this run reads, overriding both CLAUDE_CREDENTIALS in
# claude.env and the launcher-balanced pool choice (CLAUDE_CREDENTIAL_POOL +
# CLAUDE_HEADROOM_HOOK, see docs/credential-balancing.md) -- the same
# precedence fork-sandbox.sh's local path resolves, and, when this run was
# started via `fork-sandbox.sh --k8s`, the same flag that launcher forwards
# here already resolved, so the hook is never invoked twice for one run. PATH
# must exist; a typo is refused before the Job, the ConfigMap or the per-run
# claude-proxy Secret are created. See fs_balance_claude_credential in
# scripts/fork-sandbox-lib.sh for the pool/hook contract itself.
#
# --label key=value (submit, run): an opt-in free-form label for this run's
# objects, repeatable. Renders as fork-sandbox.io/<key>: <value> on the Job,
# ConfigMap, Pod template and (--harness claude) the per-run claude-proxy
# objects -- the fixed fork-sandbox.io/ prefix is not optional, since app and
# fork-sandbox/branch are the NetworkPolicy selector keys that isolate one
# run's claude-proxy (and the operator's real access token behind it) from
# another's, and a free-form label must never be able to land on one of
# those keys instead. Setting app, fork-sandbox/branch, fork-sandbox/role or
# fork-sandbox/owner directly is refused by name, before anything is
# created, even though the prefix already makes the collision impossible --
# see docs/kubernetes-runs.md. K8S_RUN_LABELS in k8s.env supplies file-level
# defaults; a --label for the same key overrides the file's value (announced
# on stderr), a file-only key survives unchanged.
#
# --task-meta JSON (submit, run): one JSON object of orchestrator-supplied
# task metadata, folded verbatim into the run's row in the durable run log
# (~/.claude/sandbox-runs.jsonl) as its `task` field -- the same flag and
# the same meaning as fork-sandbox.sh's own local --task-meta. See "The
# durable run log" in docs/kubernetes-runs.md and sandbox-run-log.py's own
# header for the recommended fields.
#
# --allow-namespace NS[:PORT] (submit, run), repeatable: opens this run's own
# agent egress to an extra namespace, for THIS RUN ONLY -- unlike the static
# K8S_AGENT_ALLOW_NS in k8s.env below, which is a machine-wide default every
# run inherits. Same syntax and port semantics as K8S_AGENT_ALLOW_NS: with a
# port, that TCP port only; without one, every port and protocol. Requires
# the resolved platform plugin to support the `render-grant` capability (see
# docs/k8s-platform.md), and requires at least one --reach-probe. See "Per-run
# namespace grants" in docs/kubernetes-runs.md.
#
# --reach-probe HOST:PORT (submit, run), repeatable: a destination the egress
# gate must reach before the agent starts, required whenever --allow-namespace
# is given (and refused without it). HOST must be <svc>.<ns>, <svc>.<ns>.svc,
# or <svc>.<ns>.svc.$K8S_CLUSTER_DOMAIN, and <ns> must be one of this run's
# --allow-namespace values -- a grant the gate never exercises is not
# verified. See "Per-run namespace grants" in docs/kubernetes-runs.md.
#
# --run-dir DIR (collect): finalize the run directory submit created --
# writing summary.json and calling sandbox-run-log.py record -- rather than
# collect's ordinary behavior of writing and recording nothing. `run`
# threads this automatically, using the directory its own submit phase
# created; a caller driving submit and collect separately passes back what
# submit printed on its "run dir:" line. See "The durable run log" in
# docs/kubernetes-runs.md.
#
# --harness pi|claude|codex (submit): which coding harness the pod runs. Defaults
# to pi, which talks to the shared fork-sandbox-proxy over PROXY_BASE_URL,
# exactly as before this flag existed. claude runs Claude Code instead,
# against a PER-RUN proxy Pod (manifests/k8s/31-claude-proxy.yaml, rendered
# and applied alongside this run's Job) that carries the operator's own
# access token in a per-run Secret -- the pod itself still holds no
# real credential. codex is allowed only with --run-dir, whose composed
# seats use their own per-run Codex proxy. A legacy single-harness codex
# run stays refused. See docs/kubernetes-runs.md's "Model access" section for the
# full design.
#
# --image REF (submit, run): the pod image for THIS run only, overriding both
# K8S_PROJECT_IMAGES's entry for this project and K8S_IMAGE in k8s.env --
# the same precedence --endpoint applies over K8S_DEFAULT_ENDPOINT. REF must
# be a fully qualified image reference (never defaulted, same rule K8S_IMAGE
# documents below); unlike K8S_IMAGE, that rule IS enforced here, since this
# is a new flag with no installed base to stay compatible with. Renders on
# both the egress-gate and agent containers. See "Per-project and per-run
# images" in docs/kubernetes-runs.md.
#
# Cluster-specific settings are never taken from this repo -- a public repo
# must not carry a private hostname, a real cluster name or a registry
# address, and none of those belong hardcoded regardless. They are read at
# runtime from ~/.config/fork-sandbox/k8s.env, one NAME=VALUE per line,
# following the pattern fork-sandbox.sh already uses for pi.env and
# model.env:
#
#   K8S_CONTEXT=          kubectl --context value. REQUIRED, never
#                         defaulted -- a wrong-cluster write is the failure
#                         mode worth an error message.
#   K8S_NAMESPACE=        defaults to fork-sandbox.
#   K8S_IMAGE=            a fully qualified image ref. REQUIRED for submit,
#                         never defaulted -- this project ships a Dockerfile
#                         and a build script, and NEVER ships an image or a
#                         registry. A pod cannot use a local docker image,
#                         so a silent default would only produce a
#                         confusing ImagePullBackOff. Build with
#                         scripts/build-sandbox-image.sh and push it to a
#                         registry you control; see docs/kubernetes-runs.md
#                         for concrete options.
#   K8S_PROJECT_IMAGES=   <project>=<ref>[,<project>=<ref>...] -- a default
#                         image for a project whose runs should use its own
#                         image (built FROM the base one, see
#                         docs/kubernetes-runs.md's provisioning section)
#                         instead of K8S_IMAGE. <project> is the basename of
#                         the origin repo's top level (two repos sharing a
#                         basename share the default; use --image for the
#                         exception). <ref> must be fully qualified, the
#                         same rule --image enforces. Optional; an unlisted
#                         project still falls back to K8S_IMAGE exactly as
#                         before this key existed. Overridden by --image.
#   K8S_PROXY_UPSTREAM=   https://<provider host>, e.g. https://openrouter.ai.
#                         The legacy single, API-keyed upstream. install
#                         requires this or K8S_PROXY_ENDPOINTS, never both.
#   K8S_PROXY_ENDPOINTS=  <name>=<base-url>[,<name>=<base-url>...] -- one or
#                         more named OpenAI-compatible endpoints (vLLM,
#                         Ollama, TGI, or a keyed in-cluster gateway), e.g.
#                         primary=http://10.0.0.5:8001/v1. Keyless by
#                         default; see K8S_PROXY_ENDPOINT_KEYS below to key
#                         one. Mutually exclusive with K8S_PROXY_UPSTREAM.
#   K8S_PROXY_ENDPOINT_KEYS=
#                         <name>=<VAR_NAME>[,<name>=<VAR_NAME>...] -- keys a
#                         K8S_PROXY_ENDPOINTS entry. <name> must already be
#                         registered there; <VAR_NAME> is the NAME of a
#                         variable in pi.env holding the credential -- never
#                         the value itself, since this file is published for
#                         onboarding. install refuses if the named variable
#                         is missing or empty in pi.env, naming both the
#                         endpoint and the variable. The value is stored in
#                         a Secret, mounted into the proxy only, and never
#                         reaches the agent pod -- same handling as
#                         K8S_PROXY_UPSTREAM's own key, one layer down.
#   K8S_PROXY_ENDPOINT_EMBEDDINGS=
#                         <name>[,<name>...] -- opts K8S_PROXY_ENDPOINTS
#                         entries in to two more exact-match proxy routes,
#                         /e/<name>/v1/embeddings and the TEI-native
#                         /e/<name>/embed, for app code running in the pod.
#                         Each <name> must be registered, and its base URL
#                         must end in /v1 (the TEI route is served at the
#                         gateway's root, so the /v1 is stripped for it).
#                         Rate-limited in its own zone, apart from the
#                         agent's chat traffic. Endpoints only, and off by
#                         default: unset renders exactly as before.
#   K8S_DEFAULT_ENDPOINT= the K8S_PROXY_ENDPOINTS entry a run is wired to
#                         when neither submit nor run names one with
#                         --endpoint. Optional, and only meaningful on an
#                         endpoints install -- on a legacy
#                         K8S_PROXY_UPSTREAM install a set value is a
#                         parse-time error, same shape as --endpoint.
#                         The name it gives must be registered (a
#                         parse-time error listing the names otherwise,
#                         pointing at this file rather than a command
#                         line that never mentions it). Precedence:
#                         --endpoint, then this key, then the single
#                         registered endpoint.
#   K8S_DEFAULT_MODEL=    the model a run uses when neither submit nor run
#                         names one with --model. Optional, and only
#                         meaningful on an endpoints install where the pod
#                         would otherwise discover the model from the
#                         endpoint's /v1/models at startup -- a --harness
#                         claude run still requires --model regardless,
#                         since discovery lists the pi endpoint's model
#                         ids, never a Claude Code model name. Precedence:
#                         --model, then this key, then the pod's own
#                         single-candidate discovery rule, then that
#                         discovery's error listing what it found. If the
#                         pod cannot READ this id's context length -- the
#                         listing does not contain it, the listing carries
#                         no usable max_model_len for it, or the catalog
#                         fetch failed -- that is an error at pod start
#                         unless K8S_ALLOW_UNLISTED_MODEL is set.
#   K8S_ALLOW_UNLISTED_MODEL=
#                         set to 1 to permit a launch whose context
#                         length had to be guessed: the model id is
#                         absent from the endpoint's /v1/models listing,
#                         the catalog fetch itself failed, timed out or
#                         came back unparseable, or the entry carries no
#                         usable max_model_len. Without it the pod
#                         refuses: a warning that proceeds is
#                         indistinguishable from success once the pod is
#                         reaped, and the guess-low context window that
#                         follows a missing id would then stand silently
#                         for a real one. The warning it restores names
#                         the guessed value as a guess. May only be 1 or
#                         unset.
#   K8S_CLUSTER_DOMAIN=   the cluster's own DNS domain, defaults to
#                         cluster.local. A K8S_PROXY_UPSTREAM or
#                         K8S_PROXY_ENDPOINTS URL on http:// to a host
#                         ending in .svc.$K8S_CLUSTER_DOMAIN is accepted --
#                         a Service name resolves only inside the cluster,
#                         so it can never route to the open internet the
#                         way a plain hostname could.
#   K8S_PROXY_ALLOW=      <cidr>:<port>[,<cidr>:<port>...] egress allowlist
#                         for K8S_PROXY_ENDPOINTS hosts. Unset keeps the
#                         default policy (any host except RFC1918, on 443);
#                         a set value REPLACES that default wholesale --
#                         it does not add to it -- so every endpoint host
#                         needs its own <cidr>:<port> entry here or it is
#                         unreachable. See also K8S_PROXY_ALLOW_NS, below,
#                         for a Service living inside the cluster.
#   K8S_PROXY_ALLOW_NS=   <namespace>[:<port>][,<namespace>[:<port>]...]
#                         egress allowlist by namespace, for an in-cluster
#                         Service K8S_PROXY_ENDPOINTS points at. kube-proxy
#                         DNATs a ClusterIP to a pod IP before egress policy
#                         is evaluated on most CNIs, so K8S_PROXY_ALLOW's
#                         ipBlock cannot reliably express "reach this
#                         Service" -- a namespaceSelector can, since it
#                         matches the pod's own namespace label regardless
#                         of DNAT. Port is optional; omitted means every
#                         port. Composes WITH K8S_PROXY_ALLOW -- both apply
#                         at once -- rather than replacing it, since a site
#                         may need both a LAN endpoint and an in-cluster
#                         one. Each namespace is validated against the
#                         standard kubernetes.io/metadata.name label shape.
#   K8S_AGENT_ALLOW_NS=   <namespace>[:<port>][,<namespace>[:<port>]...]
#                         extra egress destinations for the AGENT pod, on
#                         top of the two its policy otherwise seals it to
#                         (DNS, and the proxy). Same syntax, same validation
#                         and the same DNAT reasoning as K8S_PROXY_ALLOW_NS
#                         above -- but that key governs what the PROXY may
#                         dial, which is a different pod and a different
#                         question. Unset (the default) leaves the agent
#                         sealed exactly as before.
#                         This is the one key that WIDENS the agent's seal,
#                         so it is deliberately the caller's to set and to
#                         announce: install prints every entry it forwards,
#                         and --dry-run shows the rendered rules. A platform
#                         plugin cannot open this on its own, because a
#                         widening only a plugin knew about would be
#                         invisible to the egress gate, whose fixed checks
#                         (denied probe unreachable, proxy reachable, ICMP
#                         where declared) touch no widened namespace, so it
#                         passes either way -- and would quietly falsify what
#                         docs/k8s-platform.md says this cluster guarantees.
#                         Setting it means K8S_DENIED_PROBE must name a
#                         destination OUTSIDE every namespace listed here,
#                         or the gate proves nothing.
#   K8S_DENIED_PROBE=     host:port the egress gate must NOT reach.
#                         Required for submit.
#   K8S_RUN_TTL=          seconds the pod idles after the agent exits.
#                         Defaults to 3600.
#   K8S_QUOTA_PODS=, K8S_QUOTA_REQUESTS_CPU=, K8S_QUOTA_REQUESTS_MEMORY=,
#   K8S_QUOTA_LIMITS_CPU=, K8S_QUOTA_LIMITS_MEMORY=
#                         the five limits of the namespace's ResourceQuota,
#                         rendered by `install` (and re-rendered on every
#                         install, so a patch to the live object does not
#                         survive one -- set the key instead). Optional;
#                         default to 10, 10, 20Gi, 20 and 40Gi. pods must be
#                         a positive integer, the cpu keys a Kubernetes
#                         cpu quantity (4, 0.5, 500m), the memory keys an
#                         integer with an optional suffix (512Mi, 20Gi,
#                         20G). A claude seat is two pods (the agent and
#                         its per-run claude-proxy), so raise K8S_QUOTA_PODS
#                         for concurrent claude runs. A malformed value is
#                         refused by install before anything is applied.
#   K8S_AGENT_REQUESTS_CPU=, K8S_AGENT_REQUESTS_MEMORY=,
#   K8S_AGENT_LIMITS_CPU=, K8S_AGENT_LIMITS_MEMORY=
#                         explicit resource requests and limits for the
#                         container that runs the agent's work in every run
#                         pod -- and so for every seat the in-cluster
#                         postmaster launches, since the pod reads the same
#                         k8s.env. That is the single `agent` container of
#                         a fixed-skeleton pod, and the `leg` container of
#                         a composed (--run-dir) pod; the composed pod's
#                         `agent` container (the pipeline walker) gets no
#                         resources and keeps the LimitRange default. Not
#                         renamed K8S_LEG_*: one set of keys, one meaning.
#                         Optional, each independent; unset (the default)
#                         renders no field for it. With no key set the
#                         namespace LimitRange default applies (limit 1
#                         cpu / 2Gi, request 250m / 512Mi). An unset
#                         request beside a set limit is NOT the LimitRange
#                         default: Kubernetes copies the limit into the
#                         request, so a lone LIMITS_MEMORY=6Gi reserves a
#                         6Gi request; set a request alongside each limit.
#                         The egress-gate init
#                         container, the claude-proxy pods and the
#                         postmaster are untouched. The cpu keys take a
#                         Kubernetes cpu quantity (2, 0.5, 500m), the memory
#                         keys an integer with an optional suffix (512Mi,
#                         6Gi, 6G); zero is refused. Refused, naming the
#                         key, before anything is applied: a malformed
#                         value, a request above its limit, a limit above
#                         the LimitRange max (4 cpu / 8Gi), a request above
#                         the LimitRange default limit while its limit is
#                         unset. The namespace quota must leave room for
#                         concurrent seats at that size: see
#                         K8S_QUOTA_LIMITS_MEMORY above.
#   K8S_QUOTA_WAIT_SECONDS=
#                         how long submit waits, in total, for room in
#                         that quota when a create is refused ("exceeded
#                         quota": the claude-proxy Pod, or the Job's agent
#                         pod). Optional; defaults to 900; a positive
#                         integer (refused otherwise, naming the key). A
#                         budget of its own: time spent quota-blocked does
#                         not count against the pod-ready budget. Other
#                         create errors stay fatal.
#   GIT_USER_NAME=, GIT_USER_EMAIL=
#                         identity the pod's commits land under. Optional;
#                         default to a fixed fork-sandbox identity.
#   K8S_RUN_OWNER=        value for this run's fork-sandbox/owner label.
#                         Optional; defaults to a sanitized $USER, and is
#                         omitted entirely when neither yields a value. An
#                         explicit value here must already be a valid label
#                         value (refused otherwise, nothing created) --
#                         unlike $USER, which this script sanitizes instead
#                         of refusing. For attribution inside a shared
#                         namespace; see docs/kubernetes-runs.md.
#   K8S_RUN_LABELS=       <key>=<value>[,<key>=<value>...] free-form labels
#                         applied to every run by default, each rendered as
#                         fork-sandbox.io/<key>: <value>. Optional; overridden
#                         key-by-key by --label on a given invocation. See
#                         --label above.
#
# The following keys are read only by `install --postmaster` and by the
# postmaster pod's own init step; no other verb or key changes behavior
# based on them. See docs/cluster-postmaster.md.
#   K8S_POSTMASTER_IMAGE= the image ref scripts/build-sandbox-image.sh
#                         --postmaster built and you pushed. REQUIRED with
#                         --postmaster, never defaulted, same reasoning as
#                         K8S_IMAGE above.
#   K8S_POSTMASTER_REPO_URL=
#                         ssh URL of the project repo the postmaster pod
#                         clones: ssh://[user@]host[:port]/path or the
#                         scp-like user@host:path form. REQUIRED with
#                         --postmaster; anything else (https://, a bare
#                         hostname) is refused -- the pod holds a
#                         read-only deploy key, never a token or password.
#   K8S_POSTMASTER_PROJECT=
#                         directory name under $HOME/src in the pod.
#                         Optional; defaults to K8S_POSTMASTER_REPO_URL's
#                         last path component with a trailing .git
#                         stripped. Must match ^[A-Za-z0-9][A-Za-z0-9._-]*$
#                         (so it can never be "." or "..").
#   K8S_POSTMASTER_GIT_KEY_FILE=
#                         laptop path to the read-only deploy private key
#                         for K8S_POSTMASTER_REPO_URL. REQUIRED with
#                         --postmaster; must be a regular file, owned by
#                         you, mode 0600 or stricter (require_secret_file).
#   K8S_POSTMASTER_KNOWN_HOSTS_FILE=
#                         laptop path to a known_hosts file for that
#                         remote. REQUIRED with --postmaster and must be
#                         non-empty: the pod never trusts a host on first
#                         use.
#   K8S_POSTMASTER_STORAGE_CLASS=
#                         the storageClassName of both postmaster PVCs.
#                         Optional; empty (the default) omits the field
#                         entirely, so the cluster's default StorageClass
#                         applies.
#   K8S_POSTMASTER_STORAGE=
#                         the postmaster data PVC's requested size.
#                         Optional, defaults to 20Gi; must match
#                         ^[0-9]+(Mi|Gi|Ti)$.
#   K8S_POSTMASTER_MAIL_STORAGE=
#                         the postmaster mail PVC's requested size (the
#                         mail store, the only volume the mail API sees).
#                         Optional, defaults to 2Gi; same pattern as
#                         K8S_POSTMASTER_STORAGE.
#   K8S_POSTMASTER_ACCESS_MODE=
#                         the access mode of both postmaster PVCs. Optional,
#                         defaults to ReadWriteOncePod; ReadWriteOnce is
#                         also accepted (for a StorageClass/CSI driver
#                         that does not support RWOP yet). Any other value
#                         is refused.
#   K8S_POSTMASTER_OPERATORS=
#                         comma-separated @names (no spaces) that carry
#                         rule-1 authority in the cluster postmaster: only
#                         mail From one of them clears a thread's
#                         needs-operator flag or resets its spawn budget.
#                         Optional; defaults to @operator. Each name must
#                         match ^@[a-z0-9][a-z0-9-]*$, no empty elements,
#                         and none may resolve as an agent in the laptop
#                         fleet (refused otherwise). Rendered into the
#                         Deployment as FORK_SANDBOX_OPERATORS on both the
#                         postmaster and the mail-api container.
#   K8S_POSTMASTER_HOOKS_SECRET=
#                         name of a Kubernetes Secret YOU create in
#                         K8S_NAMESPACE holding whatever credentials the
#                         postmaster's hooks (on-harvest, on-target,
#                         on-quiescent, shipped from
#                         ~/.config/fork-sandbox/hooks) need. Optional;
#                         when set, install mounts it read-only at
#                         /etc/fork-sandbox/hook-secret in the postmaster
#                         container only (never the mail-api container)
#                         and sets FS_HOOK_SECRET_DIR there. install never
#                         creates, reads or prints it, and it is not in the
#                         pod's config checksum, so changing its content
#                         does not roll the pod. Must be a DNS-1123
#                         subdomain name (<= 253 chars, lowercase
#                         alphanumerics, '-' and '.'); install refuses
#                         its own Secret names (fork-sandbox-upstream-key,
#                         fork-sandbox-postmaster-git,
#                         fork-sandbox-mail-api-tokens) so a config typo
#                         can never hand a hook the provider or deploy key.
#   K8S_MAIL_API_TOKENS_FILE=
#                         laptop path to the mail API tokens file (see
#                         `fork-sandbox-mail-api.py mint`). Optional; when
#                         set, install deploys the mail API beside the
#                         postmaster (container, tokens Secret, ClusterIP
#                         Service); when unset it is not deployed. Must be
#                         a regular file, owned by you, mode 0600 or
#                         stricter (require_secret_file), and pass
#                         `fork-sandbox-mail-api.py check` under
#                         K8S_POSTMASTER_OPERATORS -- install refuses
#                         otherwise. Rotating its content rolls the pod.
#   K8S_MAIL_TEAM_SUBJECTS=
#                         who may use the team token: comma-separated
#                         user:<name> and group:<name> entries, no spaces,
#                         no empty elements (user:alice@example.com,
#                         group:platform-team). Optional; when set, install
#                         binds the Role fork-sandbox-mail-team to exactly
#                         those subjects. Unset (the default) renders the
#                         Role and no RoleBinding, which suits a team whose
#                         members are already cluster admins. Never bound to
#                         anything by default. Only meaningful with
#                         K8S_MAIL_API_TOKENS_FILE set; each name must be
#                         made of [A-Za-z0-9._:@/+=-] and start with a
#                         letter or digit, or install refuses.
#   K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=
#                         laptop path to a claude credentials JSON, minted
#                         with `claude setup-token` (a long-lived OAuth
#                         token; the cluster postmaster never refreshes
#                         it). Optional; when set, install creates Secret
#                         fork-sandbox-postmaster-claude from it, mounts it
#                         read-only at /etc/fork-sandbox/claude in the
#                         postmaster container only, ships a claude.env
#                         pointing CLAUDE_CREDENTIALS at it, and sets
#                         FORK_SANDBOX_CLUSTER_CLAUDE=1 on that container so
#                         `fleet check --cluster` accepts claude seats.
#                         Unset: no claude credential, and a claude seat is
#                         refused in the cluster, same as before this key
#                         existed. Must be a regular file, owned by you,
#                         mode 0600 or stricter (require_secret_file), with
#                         a non-empty .claudeAiOauth.accessToken and a
#                         .claudeAiOauth.expiresAt at least 7 days in the
#                         future -- install refuses otherwise, since a
#                         shorter-lived token (an interactive login's, say)
#                         would leave every claude seat in flight stranded
#                         when it expires. See docs/cluster-postmaster.md,
#                         "Claude seats in a cluster postmaster". Rotating
#                         its content rolls the pod.
#
# The provider key is NOT in this file. install reads it from
# ~/.config/fork-sandbox/pi.env (OPENROUTER_API_KEY=...), the same file a
# local --harness pi run reads, so there is one credential source shared
# between local and cluster runs. It never enters the agent pod: only the
# model proxy holds it, mounted from the Secret this creates.
#
# FORK_SANDBOX_K8S_PLATFORM names the platform plugin; default generic. See
# docs/k8s-platform.md.
#
# FORK_SANDBOX_FLEET_FILE / FORK_SANDBOX_PERSONAS_DIR, when set in the
# caller's shell, are the laptop fleet file and personas dir
# `install --postmaster` ships into the postmaster's ConfigMaps, instead
# of $config_dir/fleet.yaml and $config_dir/personas -- for a site that
# keeps its fleet and personas in a repo of its own. Unset or empty falls
# back to $config_dir, unchanged from before this pair of keys existed.
# Every other install-time dir (prompts, handlers, hooks, presets) still
# reads only $config_dir; see docs/cluster-postmaster.md.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

if [[ "${1-}" == -h || "${1-}" == --help ]]; then
    usage
    exit 0
fi

fs_require_gnu_tools || exit 1

config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
k8s_env="$config_dir/k8s.env"
pi_env="$config_dir/pi.env"
claude_env="$config_dir/claude.env"

# Reads one NAME=VALUE line from an env file, first match wins. Never
# `source`d: these files are read by a script that goes on to build
# commands from other things too, and a config file is not the place to
# accept arbitrary shell.
read_env_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

# A Kubernetes label VALUE: empty, or up to 63 characters matching
# [a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?. Shared by the owner label
# (K8S_RUN_OWNER, below) and every free-form --label/K8S_RUN_LABELS value.
k8s_valid_label_value() {
    local value="$1"
    [[ -z "$value" ]] && return 0
    (( ${#value} <= 63 )) && [[ "$value" =~ ^[a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?$ ]]
}

# A Kubernetes label KEY's local part -- the same shape as a value above,
# but never empty.
k8s_valid_label_key() {
    local key="$1"
    [[ -n "$key" ]] || return 1
    (( ${#key} <= 63 )) && [[ "$key" =~ ^[a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?$ ]]
}

# check-grant runs no kubectl and touches no cluster -- it is the grant
# parser alone -- so it must work with no k8s.env at all (the postmaster
# round's kickoff tooling may call it before install has ever run). Every
# other verb still requires the file and K8S_CONTEXT in it, checked below.
if [[ "${1-}" != check-grant && ! -f "$k8s_env" ]]; then
    echo "Error: $k8s_env not found. A Kubernetes run reads cluster-specific" >&2
    echo "settings from that file, one NAME=VALUE per line:" >&2
    echo "  mkdir -p $config_dir" >&2
    echo "  cat > $k8s_env <<'CONF'" >&2
    echo "K8S_CONTEXT=your-cluster-context" >&2
    echo "K8S_NAMESPACE=fork-sandbox" >&2
    echo "K8S_IMAGE=registry.example/you/fork-sandbox:latest" >&2
    echo "K8S_PROXY_UPSTREAM=https://openrouter.ai" >&2
    echo "K8S_DENIED_PROBE=10.0.0.1:443" >&2
    echo "K8S_RUN_TTL=3600" >&2
    echo "CONF" >&2
    echo "See docs/kubernetes-runs.md for what each key means." >&2
    exit 1
fi

K8S_CONTEXT="$(read_env_value "$k8s_env" K8S_CONTEXT || true)"
if [[ -z "$K8S_CONTEXT" && "${1-}" != check-grant ]]; then
    echo "Error: K8S_CONTEXT is not set in $k8s_env. This is never defaulted:" >&2
    echo "a wrong-cluster write is the failure mode worth an error message." >&2
    echo "Add a line: K8S_CONTEXT=your-cluster-context" >&2
    exit 1
fi
K8S_NAMESPACE="$(read_env_value "$k8s_env" K8S_NAMESPACE || true)"
K8S_NAMESPACE="${K8S_NAMESPACE:-fork-sandbox}"
K8S_IMAGE="$(read_env_value "$k8s_env" K8S_IMAGE || true)"
# Per-project default image ref -- see resolve_run_image below for how it
# combines with --image and K8S_IMAGE.
K8S_PROJECT_IMAGES="$(read_env_value "$k8s_env" K8S_PROJECT_IMAGES || true)"
K8S_PROXY_UPSTREAM="$(read_env_value "$k8s_env" K8S_PROXY_UPSTREAM || true)"
K8S_PROXY_ENDPOINTS="$(read_env_value "$k8s_env" K8S_PROXY_ENDPOINTS || true)"
# Keys a K8S_PROXY_ENDPOINTS entry -- holds the VAR_NAME only, never the
# value; see parse_proxy_endpoint_keys and cmd_install's Secret handling.
K8S_PROXY_ENDPOINT_KEYS="$(read_env_value "$k8s_env" K8S_PROXY_ENDPOINT_KEYS || true)"
# Opts endpoints in to the embeddings routes; see parse_proxy_endpoint_embeddings.
K8S_PROXY_ENDPOINT_EMBEDDINGS="$(read_env_value "$k8s_env" K8S_PROXY_ENDPOINT_EMBEDDINGS || true)"
K8S_DEFAULT_ENDPOINT="$(read_env_value "$k8s_env" K8S_DEFAULT_ENDPOINT || true)"
# Default model for a run with no --model, on a K8S_PROXY_ENDPOINTS
# install; see the model-requirement block in cmd_submit, which resolves
# it with the same precedence shape as K8S_DEFAULT_ENDPOINT above.
K8S_DEFAULT_MODEL="$(read_env_value "$k8s_env" K8S_DEFAULT_MODEL || true)"
# Permits a launch whose context length had to be guessed (see the key's
# header entry above); the pod refuses such a launch without it. Empty
# means unset, meaning refuse -- the same read_env_value empty-means-unset
# convention as every other K8S_* key.
K8S_ALLOW_UNLISTED_MODEL="$(read_env_value "$k8s_env" K8S_ALLOW_UNLISTED_MODEL || true)"
K8S_PROXY_ALLOW="$(read_env_value "$k8s_env" K8S_PROXY_ALLOW || true)"
# Namespace-selector egress allowlist, composing with K8S_PROXY_ALLOW --
# see parse_proxy_allow_ns and render_proxy_egress_rules_ns below.
K8S_PROXY_ALLOW_NS="$(read_env_value "$k8s_env" K8S_PROXY_ALLOW_NS || true)"
# The agent pod's own namespace-selector egress allowlist -- the one key that
# widens the seal the platform plugin renders. Parsed with the same function,
# and rendered by the plugin rather than here, since the agent policy is the
# platform's to emit. See the header for why this is a caller decision.
K8S_AGENT_ALLOW_NS="$(read_env_value "$k8s_env" K8S_AGENT_ALLOW_NS || true)"
# The cluster's own DNS domain -- a Service's in-cluster name is
# <svc>.<ns>.svc.$K8S_CLUSTER_DOMAIN, and that domain is set at cluster
# install time, so cluster.local (the common default) cannot be assumed.
# See validate_upstream_url's own header for what this unlocks.
K8S_CLUSTER_DOMAIN="$(read_env_value "$k8s_env" K8S_CLUSTER_DOMAIN || true)"
K8S_CLUSTER_DOMAIN="${K8S_CLUSTER_DOMAIN:-cluster.local}"
K8S_DENIED_PROBE="$(read_env_value "$k8s_env" K8S_DENIED_PROBE || true)"
K8S_RUN_TTL="$(read_env_value "$k8s_env" K8S_RUN_TTL || true)"
K8S_RUN_TTL="${K8S_RUN_TTL:-3600}"
# Caps how large the clone, leg-handoff and leg-home emptyDirs may grow in
# the composed (--run-dir) pod shape -- see "A leg cannot write the
# runner's own state" in docs/kubernetes-runs.md. A plain Kubernetes
# quantity, the same shape K8S_SERVICE_MAX_MEMORY below already uses.
# Unlike the single-leg shape's own "work" volume (see the comment beside
# its emptyDir, further down, for why THAT one stays unlimited), hitting
# this limit evicting the pod is the outcome wanted here, not an accident
# to avoid: these three volumes hold nothing this project trusts a leg to
# grow without bound (the clone's legitimate size is the operator's own
# repository, which does not change leg to leg), so a leg that fills one
# on purpose should fail the run closed, not exhaust the node. Generous by
# default for exactly that reason -- a real repository plus a normal
# leg's own stdout/stderr should never come close.
K8S_LEG_VOLUME_SIZE_LIMIT="$(read_env_value "$k8s_env" K8S_LEG_VOLUME_SIZE_LIMIT || true)"
K8S_LEG_VOLUME_SIZE_LIMIT="${K8S_LEG_VOLUME_SIZE_LIMIT:-8Gi}"
# Per-run services caps -- see docs/sandbox-services.md's cluster section.
# A repo must not be able to claim the namespace: these bound how many
# services, how much cpu/memory, and how long a startup window a committed
# services.yaml can ask for. The cpu/memory/seconds shapes are validated by
# fork-sandbox-k8s-services-parse.py itself (the only place that needs a
# Kubernetes-quantity parser), not here.
K8S_SERVICES_MAX="$(read_env_value "$k8s_env" K8S_SERVICES_MAX || true)"
K8S_SERVICES_MAX="${K8S_SERVICES_MAX:-8}"
K8S_SERVICE_MAX_CPU="$(read_env_value "$k8s_env" K8S_SERVICE_MAX_CPU || true)"
K8S_SERVICE_MAX_CPU="${K8S_SERVICE_MAX_CPU:-1000m}"
K8S_SERVICE_MAX_MEMORY="$(read_env_value "$k8s_env" K8S_SERVICE_MAX_MEMORY || true)"
K8S_SERVICE_MAX_MEMORY="${K8S_SERVICE_MAX_MEMORY:-1Gi}"
# The per-service readyWhen.startupSeconds cap -- see "Restarting a sidecar
# that is still starting is never useful" in docs/sandbox-services.md.
# 600s (10 minutes) is deliberately generous: the spec's own default is far
# below this (see fork-sandbox-k8s-services-parse.py's DEFAULT_STARTUP_SECONDS),
# and this key exists only to bound how far a spec can push submit's own
# pod-ready budget (see pod_budget in cmd_submit), not to suggest 600s is a
# normal wait.
K8S_SERVICE_MAX_STARTUP_SECONDS="$(read_env_value "$k8s_env" K8S_SERVICE_MAX_STARTUP_SECONDS || true)"
K8S_SERVICE_MAX_STARTUP_SECONDS="${K8S_SERVICE_MAX_STARTUP_SECONDS:-600}"
# How long submit waits, in total, for room in the namespace ResourceQuota
# (the per-run proxy Pod's create or the Job's pod create refused with
# "exceeded quota") before giving up. Its own budget, apart from submit's
# pod-ready budget -- see k8s_quota_wait_step.
K8S_QUOTA_WAIT_SECONDS="$(read_env_value "$k8s_env" K8S_QUOTA_WAIT_SECONDS || true)"
K8S_QUOTA_WAIT_SECONDS="${K8S_QUOTA_WAIT_SECONDS:-900}"
# The namespace ResourceQuota's five limits, substituted into
# manifests/k8s/00-namespace.yaml by cmd_install, which also validates them
# (only install renders the quota, so no other verb fails over a bad one).
# The defaults are the quota the manifest used to hard-code.
K8S_QUOTA_PODS="$(read_env_value "$k8s_env" K8S_QUOTA_PODS || true)"
K8S_QUOTA_PODS="${K8S_QUOTA_PODS:-10}"
K8S_QUOTA_REQUESTS_CPU="$(read_env_value "$k8s_env" K8S_QUOTA_REQUESTS_CPU || true)"
K8S_QUOTA_REQUESTS_CPU="${K8S_QUOTA_REQUESTS_CPU:-10}"
K8S_QUOTA_REQUESTS_MEMORY="$(read_env_value "$k8s_env" K8S_QUOTA_REQUESTS_MEMORY || true)"
K8S_QUOTA_REQUESTS_MEMORY="${K8S_QUOTA_REQUESTS_MEMORY:-20Gi}"
K8S_QUOTA_LIMITS_CPU="$(read_env_value "$k8s_env" K8S_QUOTA_LIMITS_CPU || true)"
K8S_QUOTA_LIMITS_CPU="${K8S_QUOTA_LIMITS_CPU:-20}"
K8S_QUOTA_LIMITS_MEMORY="$(read_env_value "$k8s_env" K8S_QUOTA_LIMITS_MEMORY || true)"
K8S_QUOTA_LIMITS_MEMORY="${K8S_QUOTA_LIMITS_MEMORY:-40Gi}"
# Optional explicit resources for the container that runs the legs (see the
# header table). Unset means no field is rendered and the LimitRange default
# applies. Validated below by k8s_validate_agent_resources.
K8S_AGENT_REQUESTS_CPU="$(read_env_value "$k8s_env" K8S_AGENT_REQUESTS_CPU || true)"
K8S_AGENT_REQUESTS_MEMORY="$(read_env_value "$k8s_env" K8S_AGENT_REQUESTS_MEMORY || true)"
K8S_AGENT_LIMITS_CPU="$(read_env_value "$k8s_env" K8S_AGENT_LIMITS_CPU || true)"
K8S_AGENT_LIMITS_MEMORY="$(read_env_value "$k8s_env" K8S_AGENT_LIMITS_MEMORY || true)"
# The namespace LimitRange's numbers (manifests/k8s/00-namespace.yaml), for
# the early checks on those keys; the test suite pins them to the manifest.
K8S_LIMITRANGE_MAX_CPU=4
K8S_LIMITRANGE_MAX_MEMORY=8Gi
K8S_LIMITRANGE_DEFAULT_CPU=1
K8S_LIMITRANGE_DEFAULT_MEMORY=2Gi
GIT_USER_NAME="$(read_env_value "$k8s_env" GIT_USER_NAME || true)"
GIT_USER_NAME="${GIT_USER_NAME:-fork-sandbox agent}"
GIT_USER_EMAIL="$(read_env_value "$k8s_env" GIT_USER_EMAIL || true)"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@fork-sandbox.invalid}"
# The fork-sandbox/owner label's value -- see resolve_run_owner below for
# how an unset key falls back to a sanitized $USER. K8S_RUN_LABELS is the
# free-form labels' file-level default registry; parsed per-submit by
# resolve_run_labels, not here, the same way K8S_PROXY_ENDPOINTS is read
# here but parsed by parse_proxy_endpoints inside cmd_install/cmd_submit.
K8S_RUN_OWNER="$(read_env_value "$k8s_env" K8S_RUN_OWNER || true)"
K8S_RUN_LABELS="$(read_env_value "$k8s_env" K8S_RUN_LABELS || true)"
# Read unconditionally, like every other key above -- but only
# `install --postmaster` (and the pod's own init step, a separate script)
# ever act on them; every required-ness and shape check lives in
# cmd_install, gated on --postmaster, so a plain install or any other verb
# never fails over a key it does not use. See the header table above.
K8S_POSTMASTER_IMAGE="$(read_env_value "$k8s_env" K8S_POSTMASTER_IMAGE || true)"
K8S_POSTMASTER_REPO_URL="$(read_env_value "$k8s_env" K8S_POSTMASTER_REPO_URL || true)"
K8S_POSTMASTER_PROJECT="$(read_env_value "$k8s_env" K8S_POSTMASTER_PROJECT || true)"
K8S_POSTMASTER_GIT_KEY_FILE="$(read_env_value "$k8s_env" K8S_POSTMASTER_GIT_KEY_FILE || true)"
K8S_POSTMASTER_KNOWN_HOSTS_FILE="$(read_env_value "$k8s_env" K8S_POSTMASTER_KNOWN_HOSTS_FILE || true)"
K8S_POSTMASTER_STORAGE_CLASS="$(read_env_value "$k8s_env" K8S_POSTMASTER_STORAGE_CLASS || true)"
K8S_POSTMASTER_STORAGE="$(read_env_value "$k8s_env" K8S_POSTMASTER_STORAGE || true)"
K8S_POSTMASTER_STORAGE="${K8S_POSTMASTER_STORAGE:-20Gi}"
K8S_POSTMASTER_MAIL_STORAGE="$(read_env_value "$k8s_env" K8S_POSTMASTER_MAIL_STORAGE || true)"
K8S_POSTMASTER_MAIL_STORAGE="${K8S_POSTMASTER_MAIL_STORAGE:-2Gi}"
K8S_POSTMASTER_ACCESS_MODE="$(read_env_value "$k8s_env" K8S_POSTMASTER_ACCESS_MODE || true)"
K8S_POSTMASTER_ACCESS_MODE="${K8S_POSTMASTER_ACCESS_MODE:-ReadWriteOncePod}"
K8S_POSTMASTER_OPERATORS="$(read_env_value "$k8s_env" K8S_POSTMASTER_OPERATORS || true)"
K8S_POSTMASTER_OPERATORS="${K8S_POSTMASTER_OPERATORS:-@operator}"
K8S_POSTMASTER_HOOKS_SECRET="$(read_env_value "$k8s_env" K8S_POSTMASTER_HOOKS_SECRET || true)"
K8S_MAIL_API_TOKENS_FILE="$(read_env_value "$k8s_env" K8S_MAIL_API_TOKENS_FILE || true)"
K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE="$(read_env_value "$k8s_env" K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE || true)"
K8S_MAIL_TEAM_SUBJECTS="$(read_env_value "$k8s_env" K8S_MAIL_TEAM_SUBJECTS || true)"
# Free-form labels for this run, populated by resolve_run_labels in
# cmd_submit. Declared empty here (module-global) so build_extra_label_lines
# can read them under `set -u` even on a verb that never calls
# resolve_run_labels.
RUN_LABEL_KEYS=()
RUN_LABEL_VALUES=()

# The run directory cmd_submit just created, for cmd_run to read straight
# back after calling cmd_submit as a plain bash function (never a
# subprocess) -- the same "module-global out param" idiom
# k8s_parse_label_entry's PARSED_LABEL_KEY/PARSED_LABEL_VALUE already use in
# this file, chosen over capturing cmd_submit's output so its progress
# messages keep streaming to the terminal live rather than being buffered
# until submit finishes. Declared empty here so it is safe to read under
# `set -u` even on a verb that never calls cmd_submit.
K8S_LAST_SUBMIT_RUN_DIR=""

# Quantity -> a comparable integer: millicores for cpu, bytes for memory.
# Prints nothing for a value that is not a (positive) quantity of that kind.
k8s_quantity_value() {
    awk -v kind="$1" -v v="$2" 'BEGIN {
        if (kind == "cpu") {
            if (v ~ /^[0-9]+m$/) { sub(/m$/, "", v); n = v + 0 }
            else if (v ~ /^[0-9]+(\.[0-9]+)?$/) { n = v * 1000 }
            else exit
        } else {
            if (v !~ /^[0-9]+(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$/) exit
            s = v; sub(/^[0-9]+/, "", s); sub(/[^0-9].*$/, "", v)
            split("Ki Mi Gi Ti Pi Ei k M G T P E", u, " ")
            split("1024 1048576 1073741824 1099511627776 1125899906842624 1152921504606846976 1000 1000000 1000000000 1000000000000 1000000000000000 1000000000000000000", m, " ")
            f = 1
            for (i = 1; i <= 12; i++) if (u[i] == s) f = m[i]
            n = v * f
        }
        if (n > 0) printf "%.0f", n
    }'
}

# Validates K8S_AGENT_{REQUESTS,LIMITS}_{CPU,MEMORY}, all shape and
# ordering checks, before anything is rendered or applied. Each value lands
# in a YAML manifest with no quoting of its own, so the anchored shape check
# is also what keeps a value from injecting YAML.
k8s_validate_agent_resources() {
    local kind key val what max_val def_val
    for kind in cpu memory; do
        for key in "K8S_AGENT_REQUESTS_${kind^^}" "K8S_AGENT_LIMITS_${kind^^}"; do
            val="${!key}"
            [[ -z "$val" ]] && continue
            if [[ "$kind" == cpu ]]; then
                what="a Kubernetes cpu quantity (2, 0.5 or 500m) greater than zero"
            else
                what="a Kubernetes memory quantity greater than zero: an integer with an optional binary or decimal suffix (512Mi, 6Gi, 6G)"
            fi
            if [[ -z "$(k8s_quantity_value "$kind" "$val")" ]]; then
                echo "Error: $key in $k8s_env must be $what," >&2
                echo "got '$val'." >&2
                exit 1
            fi
        done
        local req_key="K8S_AGENT_REQUESTS_${kind^^}" lim_key="K8S_AGENT_LIMITS_${kind^^}"
        local req="${!req_key}" lim="${!lim_key}" req_n lim_n
        if [[ "$kind" == cpu ]]; then
            max_val="$K8S_LIMITRANGE_MAX_CPU"; def_val="$K8S_LIMITRANGE_DEFAULT_CPU"
        else
            max_val="$K8S_LIMITRANGE_MAX_MEMORY"; def_val="$K8S_LIMITRANGE_DEFAULT_MEMORY"
        fi
        req_n="$(k8s_quantity_value "$kind" "$req")"
        lim_n="$(k8s_quantity_value "$kind" "$lim")"
        if [[ -n "$lim_n" ]] && (( lim_n > $(k8s_quantity_value "$kind" "$max_val") )); then
            echo "Error: $lim_key in $k8s_env is $lim, above the namespace LimitRange max" >&2
            echo "of $max_val (manifests/k8s/00-namespace.yaml); the pod would be rejected at" >&2
            echo "admission. Raise the LimitRange max there, or lower the key." >&2
            exit 1
        fi
        if [[ -n "$req_n" && -n "$lim_n" ]] && (( req_n > lim_n )); then
            echo "Error: $req_key in $k8s_env ($req) is above $lim_key ($lim);" >&2
            echo "a request cannot exceed its limit." >&2
            exit 1
        fi
        if [[ -n "$req_n" && -z "$lim_n" ]] \
            && (( req_n > $(k8s_quantity_value "$kind" "$def_val") )); then
            echo "Error: $req_key in $k8s_env ($req) is above the LimitRange default limit" >&2
            echo "($def_val) that applies while $lim_key is unset; set $lim_key too." >&2
            exit 1
        fi
    done
}

# The `resources:` lines for the container that runs the legs (leading
# newline included, so it appends to the line before it), or nothing when no
# K8S_AGENT_* key is set. Called on the single container of a legacy pod and
# on the `leg` container of a composed one -- never on the composed `agent`
# (walker) container.
k8s_agent_resources_yaml() {
    local req="" lim=""
    [[ -n "$K8S_AGENT_REQUESTS_CPU" ]] && req+=$'\n'"              cpu: \"$K8S_AGENT_REQUESTS_CPU\""
    [[ -n "$K8S_AGENT_REQUESTS_MEMORY" ]] && req+=$'\n'"              memory: \"$K8S_AGENT_REQUESTS_MEMORY\""
    [[ -n "$K8S_AGENT_LIMITS_CPU" ]] && lim+=$'\n'"              cpu: \"$K8S_AGENT_LIMITS_CPU\""
    [[ -n "$K8S_AGENT_LIMITS_MEMORY" ]] && lim+=$'\n'"              memory: \"$K8S_AGENT_LIMITS_MEMORY\""
    [[ -z "$req$lim" ]] && return 0
    printf '\n          resources:'
    [[ -n "$req" ]] && printf '\n            requests:%s' "$req"
    [[ -n "$lim" ]] && printf '\n            limits:%s' "$lim"
    return 0
}

# check-grant needs none of the checks in this block (it renders no
# manifest, spawns no run, and never reads any of these keys) except
# K8S_CLUSTER_DOMAIN just below -- so, like the file-existence and
# K8S_CONTEXT checks above, each is skipped for that verb. Otherwise a
# k8s.env value check-grant never consumes (K8S_RUN_TTL, say) would make
# `mail grant` fail for a reason it has nothing to do with.
if [[ "${1-}" != check-grant && ! "$K8S_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: K8S_NAMESPACE='$K8S_NAMESPACE' is not a valid namespace name." >&2
    exit 1
fi
# Substituted straight into manifests and into nginx's `resolver` directive
# (validate_upstream_url's own header, and both manifest render sites) with
# no quoting of its own, so a shape check belongs here, the same as every
# other key of this kind (K8S_NAMESPACE above) -- not just the generic
# fs_reject_unsafe_chars pass below, which lets through characters (a
# space, a `;`, a `|`) that break the sed substitution or the rendered
# nginx directive without ever naming this key as the cause. check-grant
# DOES need this one -- it validates --reach-probe hosts against
# K8S_CLUSTER_DOMAIN -- so this check runs for every verb.
if [[ ! "$K8S_CLUSTER_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "Error: K8S_CLUSTER_DOMAIN='$K8S_CLUSTER_DOMAIN' is not a valid DNS" >&2
    echo "domain name." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && -n "$K8S_RUN_TTL" && ! "$K8S_RUN_TTL" =~ ^[0-9]+$ ]]; then
    echo "Error: K8S_RUN_TTL must be a number of seconds, got '$K8S_RUN_TTL'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant \
    && ! "$K8S_LEG_VOLUME_SIZE_LIMIT" =~ ^[0-9]+(\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$ ]]; then
    echo "Error: K8S_LEG_VOLUME_SIZE_LIMIT must be a Kubernetes quantity" >&2
    echo "(e.g. 8Gi), got '$K8S_LEG_VOLUME_SIZE_LIMIT'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && -n "$K8S_ALLOW_UNLISTED_MODEL" && "$K8S_ALLOW_UNLISTED_MODEL" != 1 ]]; then
    echo "Error: K8S_ALLOW_UNLISTED_MODEL in $k8s_env must be 1 (or unset)," >&2
    echo "got '$K8S_ALLOW_UNLISTED_MODEL'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && -n "$K8S_RUN_OWNER" ]] && ! k8s_valid_label_value "$K8S_RUN_OWNER"; then
    echo "Error: K8S_RUN_OWNER='$K8S_RUN_OWNER' in $k8s_env is not a valid" >&2
    echo "Kubernetes label value -- it must be at most 63 characters and" >&2
    echo 'match [a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?. An operator-typed' >&2
    echo "value that fails this is a mistake worth reporting, unlike a" >&2
    echo "generic \$USER value, which this script sanitizes instead of" >&2
    echo "refusing -- see docs/kubernetes-runs.md." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && ! "$K8S_SERVICES_MAX" =~ ^[0-9]+$ ]]; then
    echo "Error: K8S_SERVICES_MAX must be a positive integer, got '$K8S_SERVICES_MAX'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && ! "$K8S_SERVICE_MAX_STARTUP_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: K8S_SERVICE_MAX_STARTUP_SECONDS must be a positive integer, got" >&2
    echo "'$K8S_SERVICE_MAX_STARTUP_SECONDS'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant && ! "$K8S_QUOTA_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: K8S_QUOTA_WAIT_SECONDS must be a positive integer, got" >&2
    echo "'$K8S_QUOTA_WAIT_SECONDS'." >&2
    exit 1
fi
if [[ "${1-}" != check-grant ]]; then
    k8s_validate_agent_resources
fi

# None of these keys feed check-grant's extracted validators (which read
# only K8S_CLUSTER_DOMAIN, itself already shape-checked above by a regex
# stricter than "no unsafe chars"), so this pass is skipped for that verb
# too, same reasoning as the block above.
if [[ "${1-}" != check-grant ]]; then
    fs_reject_unsafe_chars "$K8S_CONTEXT" "$K8S_NAMESPACE" "$K8S_IMAGE" \
        "$K8S_PROJECT_IMAGES" \
        "$K8S_PROXY_UPSTREAM" "$K8S_PROXY_ENDPOINTS" "$K8S_PROXY_ENDPOINT_KEYS" \
        "$K8S_PROXY_ENDPOINT_EMBEDDINGS" \
        "$K8S_PROXY_ALLOW" \
        "$K8S_PROXY_ALLOW_NS" "$K8S_CLUSTER_DOMAIN" \
        "$K8S_DENIED_PROBE" "$GIT_USER_NAME" "$GIT_USER_EMAIL" \
        "$K8S_SERVICE_MAX_CPU" "$K8S_SERVICE_MAX_MEMORY" \
        "$K8S_LEG_VOLUME_SIZE_LIMIT" \
        "$K8S_AGENT_REQUESTS_CPU" "$K8S_AGENT_REQUESTS_MEMORY" \
        "$K8S_AGENT_LIMITS_CPU" "$K8S_AGENT_LIMITS_MEMORY" \
        "$K8S_RUN_OWNER" "$K8S_RUN_LABELS" \
        "$K8S_POSTMASTER_IMAGE" "$K8S_POSTMASTER_REPO_URL" \
        "$K8S_POSTMASTER_PROJECT" "$K8S_POSTMASTER_GIT_KEY_FILE" \
        "$K8S_POSTMASTER_KNOWN_HOSTS_FILE" "$K8S_POSTMASTER_STORAGE_CLASS" \
        "$K8S_POSTMASTER_STORAGE" "$K8S_POSTMASTER_MAIL_STORAGE" \
        "$K8S_POSTMASTER_ACCESS_MODE" \
        "$K8S_POSTMASTER_OPERATORS" "$K8S_POSTMASTER_HOOKS_SECRET" \
        "$K8S_MAIL_API_TOKENS_FILE" "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" \
        "$K8S_MAIL_TEAM_SUBJECTS" \
        || exit 1
fi

kubectl() {
    command kubectl --context="$K8S_CONTEXT" -n "$K8S_NAMESPACE" "$@"
}

# Report the stderr a failed kubectl read captured to $file, instead of
# discarding it (a 2>/dev/null on the read throws away the only thing that
# would explain the failure). Prints a labeled heading line, then the
# captured text indented so it reads as kubectl's own output; the body is
# capped at 4 KiB so a pathological stderr cannot flood the operator's
# terminal, with a note when it was truncated. An empty capture is itself
# a fact: it says so explicitly rather than printing an empty block.
fs_report_captured_stderr() {
    local what="$1" file="$2" size cap=4096
    size="$("$FS_STAT" -c '%s' -- "$file")"
    if (( size == 0 )); then
        echo "fork-sandbox-k8s: $what wrote nothing to stderr." >&2
        return 0
    fi
    echo "fork-sandbox-k8s: $what reported, on stderr:" >&2
    if (( size > cap )); then
        sed 's/^/    /' <(head -c "$cap" -- "$file") >&2
        echo "fork-sandbox-k8s:    (... truncated; $size bytes total)" >&2
    else
        sed 's/^/    /' "$file" >&2
    fi
}

# The pod's operator inbox. Must track fork-sandbox-k8s-entrypoint.sh's own
# work_dir/inbox_dir, for the same reason cmd_submit's pod_clone_dir must
# track its work_dir/clone_dir: this script renders and writes before the
# pod's own shell ever runs, so there is nowhere to read the path back from.
# A sibling of /work/clone, never a descendant -- the entrypoint's
# `git add -A` at run end is scoped to the clone it runs in, so a path
# outside it can never be swept into a commit. Read by cmd_submit (to tell
# the preamble where to point the agent) and cmd_say (to know where to
# write).
POD_INBOX_DIR=/work/inbox

# The pod's artifact outbox. Same tracking requirement and sibling-of-clone
# reasoning as POD_INBOX_DIR above, mirrored on fork-sandbox-k8s-entrypoint.sh's
# own outbox_dir. Read by cmd_submit (to tell the preamble where to point the
# agent) and cmd_collect (to know where to pull artifacts back from).
POD_OUTBOX_DIR=/work/outbox

# The pod's gathered-context directory, populated from a --context-ro
# push. Same sibling-of-clone reasoning as POD_INBOX_DIR and POD_OUTBOX_DIR
# above -- it lives in the `work` emptyDir but must stay outside the clone
# so the entrypoint's `git add -A` never sweeps it into a commit. Unlike
# those two, read only by cmd_submit -- to tell the preamble where to point
# the agent, and to push into -- since nothing else (cmd_say, cmd_collect) ever
# touches it.
POD_CONTEXT_DIR=/work/context

# The pod's harness session store, populated from a --session-state push
# and read back by cmd_collect before cmd_fetch. Same sibling-of-clone
# reasoning as POD_CONTEXT_DIR above -- it lives in the `work` emptyDir,
# not its own top-level mount like POD_THREAD_DIR/POD_ATTACH_DIR below.
# The entrypoint (fork-sandbox-k8s-entrypoint.sh) hardcodes this same
# literal path on the pod side; the two are kept in sync by comment only,
# the same convention POD_INBOX_DIR documents above.
POD_SESSION_DIR=/work/session-store

# The pod-side destinations for --thread-dir/--attach-dir, mirroring the
# local sandbox's own /thread and /attachments paths so the postmaster's
# generated prompt needs no idea which backend a wake landed on. Unlike
# POD_CONTEXT_DIR above these are NOT under /work: they are their own
# top-level emptyDir mounts (see the volume render in cmd_submit), so
# there is no clone-sibling requirement to track here. These constants
# are threaded to the exec-push calls as DEST_DIR; the volume render
# itself hardcodes the same two paths directly in the YAML, the same way
# POD_CONTEXT_DIR coexists with the work/tmp/home volumeMounts' own
# hardcoded literals above -- the mount path in the pod spec and the
# DEST_DIR argument to the extractor must independently agree with each
# other and with the postmaster's own convention.
POD_THREAD_DIR=/thread
POD_ATTACH_DIR=/attachments

# The pod-side context-extract.sh cap: 256 MiB, fixed. A context directory
# is gathered notes and small caches, not build artifacts or datasets, so
# this has no --context-max flag -- see docs/kubernetes-runs.md. A second,
# independent literal lives in fork-sandbox-k8s-context-extract.sh's own
# body, the same way FS_OUTBOX_MAX_BYTES and outbox-extract.sh's default
# are two literals rather than one threaded value: this script and the pod
# script never share a sourced constant.
CONTEXT_MAX_BYTES=$((256 * 1024 * 1024))

# The identical resolution rule fs_resolve_backend uses for
# sandbox-backend-<name>, applied to the platform plugin: PATH first, then
# beside this script, so a checkout works before install.sh has run.
resolve_platform() {
    local name bin
    name="${FORK_SANDBOX_K8S_PLATFORM:-generic}"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: FORK_SANDBOX_K8S_PLATFORM='$name' is not a platform name." >&2
        echo "It becomes 'fork-sandbox-k8s-platform-$name', so it must be" >&2
        echo "lowercase alphanumerics, hyphens and underscores." >&2
        return 1
    fi
    bin="$(command -v "fork-sandbox-k8s-platform-$name" 2>/dev/null || true)"
    if [[ -z "$bin" && -x "$script_dir/fork-sandbox-k8s-platform-$name" ]]; then
        bin="$script_dir/fork-sandbox-k8s-platform-$name"
    fi
    if [[ -z "$bin" ]]; then
        echo "Error: cannot find fork-sandbox-k8s-platform-$name, which renders" >&2
        echo "this cluster's egress policy. It is named by" >&2
        echo "FORK_SANDBOX_K8S_PLATFORM (default generic) and looked up on PATH" >&2
        echo "and beside this script. Run install.sh in the fork-sandbox repo," >&2
        echo "or set FORK_SANDBOX_K8S_PLATFORM to a platform that is installed." >&2
        return 1
    fi
    K8S_PLATFORM_BIN="$bin"
    return 0
}

# Prints one capability value, or the conservative default when the
# platform's --capabilities did not declare it -- the same forward-
# compatibility rule docs/k8s-platform.md defines.
platform_capability() {
    local key="$1" default="$2" out
    out="$("$K8S_PLATFORM_BIN" --capabilities 2>/dev/null | awk -F= -v k="$key" '$1 == k { print $2; exit }')"
    printf '%s' "${out:-$default}"
}

# Reads a file that holds a secret: not a symlink, owned by the invoking
# user, mode 0600 or stricter. The same check claude-sandboxed applies to
# --env-file, applied here to pi.env before its key is read.
require_secret_file() {
    local file="$1" stat_out owner perms
    if [[ -L "$file" ]]; then
        echo "Error: '$file' is a symlink. Name the file itself." >&2
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "Error: '$file' not found." >&2
        return 1
    fi
    stat_out="$("$FS_STAT" -c '%u %a' -- "$file")"
    owner="${stat_out%% *}"
    perms="${stat_out##* }"
    if [[ "$owner" != "$UID" ]]; then
        echo "Error: '$file' is owned by uid $owner, not by you." >&2
        return 1
    fi
    if (( 8#$perms & 0077 )); then
        echo "Error: '$file' is mode $perms. It holds a secret, so it must" >&2
        echo "be 0600 or stricter. Run: chmod 600 '$file'" >&2
        return 1
    fi
    return 0
}

# Refuses a credential that would break the nginx `set $var "...";` line
# cmd_install renders it into: a literal '"' ends the string early (the rest
# of the value spills out as bare nginx syntax), a literal '$' starts
# nginx variable interpolation even inside the double quotes, and a literal
# '\' is nginx's own escape character inside a quoted string (so a trailing
# one escapes the closing quote and swallows the line's terminator) -- all
# three making a config nginx refuses to load, crashlooping the proxy for
# every run in the namespace, not just the one that supplied the bad value.
# fs_reject_unsafe_chars (single quote / newline) guards a different set of
# sinks -- the shell commands and run records this script builds -- and
# does not cover this one. Every value that ends up inside a `set $var
# "...";` line in the rendered nginx config goes through this:
# OPENROUTER_API_KEY and a K8S_PROXY_ENDPOINT_KEYS value in cmd_install,
# the per-run claude_access_token Secret built for a --harness claude run,
# and K8S_PROXY_UPSTREAM / each K8S_PROXY_ENDPOINTS URL
# (validate_upstream_url only checks scheme and host, never the path, so
# the raw value still needs this check before render_proxy_locations_body
# renders it into
# `set $upstream "...";`).
reject_nginx_unsafe_chars() {
    local v="$1" label="$2"
    if [[ "$v" == *'"'* || "$v" == *'$'* || "$v" == *\\* \
        || "$v" == *$'\n'* || "$v" == *$'\r'* ]]; then
        echo "Error: $label contains a '\"', a '\$' or a backslash, which" >&2
        echo "would break the nginx config line it is rendered into" >&2
        echo "(set \$var \"...\";). Use a credential without those" >&2
        echo "characters." >&2
        return 1
    fi
    return 0
}

# The server-side-apply field manager for the claude-token Secret. Its two
# applies (cmd_submit's create, k8s_push_claude_key's replacement) must use
# the same one, or the second conflicts with the first over .data. Both pass
# --force-conflicts: a Secret an older submit created client-side belongs to
# kubectl-client-side-apply, and without it the keeper's push is refused.
K8S_CLAUDE_TOKEN_FIELD_MANAGER=fork-sandbox-k8s-claude-token

# The field manager for cmd_install's Secrets, applied server-side with
# --force-conflicts for the same reason as the claude-token Secret above:
# a re-install over Secrets an older client-side apply created.
K8S_INSTALL_SECRET_FIELD_MANAGER=fork-sandbox-k8s-install

# Builds the per-run Claude token Secret manifest -- name and namespace as
# arguments, the real access token on STDIN ONLY, never argv, so it never
# appears in `ps` or a log line. Prints a Secret manifest (JSON, which
# `kubectl apply -f -` accepts same as YAML) with the token base64-encoded,
# already in the `set $upstream_key "...";` shape 31-claude-proxy.yaml's
# nginx.conf includes, to stdout.
#
# The ONE place that ever turns the real token into this Secret's content --
# shared by cmd_submit's initial create below and k8s_push_claude_key's
# later replacement (see cmd_wait's keeper), so the two can never render
# this object differently. `-R -s` (raw, slurp) reads the whole of stdin as
# one JSON string with no interpretation, so the token itself never has to
# survive being valid JSON or YAML on its own.
k8s_render_claude_token_secret_manifest() {
    local name="$1" namespace="$2"
    jq -R -s --arg name "$name" --arg ns "$namespace" '
        {
            apiVersion: "v1",
            kind: "Secret",
            metadata: { name: $name, namespace: $ns },
            type: "Opaque",
            data: { "upstream-key.conf": ("set $upstream_key \"" + . + "\";\n" | @base64) }
        }'
}

# Reads both values from one host auth snapshot and emits a complete nginx
# include. Never install a partial include: nginx -t accepts empty strings.
k8s_render_codex_key_conf() {
    local auth_path="$1" token account_id
    token="$(jq -er '.tokens.access_token | select(type == "string" and length > 0)' \
        "$auth_path" 2>/dev/null)" || return 1
    account_id="$(jq -er '.tokens.account_id | select(type == "string" and length > 0)' \
        "$auth_path" 2>/dev/null)" || return 1
    reject_nginx_unsafe_chars "$token" "the Codex access token" || return 1
    reject_nginx_unsafe_chars "$account_id" "the Codex account id" || return 1
    # shellcheck disable=SC2016  # nginx variables are literal config text
    printf 'set $upstream_key "%s";\nset $upstream_account_id "%s";\n' \
        "$token" "$account_id"
}

# Builds the fork-sandbox-upstream-key Secret manifest from the finished
# upstream-key.conf text on STDIN ONLY (it holds API keys; argv shows in
# `ps`). Stored byte-for-byte, trailing newline included.
k8s_render_upstream_key_secret_manifest() {
    local name="$1" namespace="$2"
    jq -R -s --arg name "$name" --arg ns "$namespace" '
        {
            apiVersion: "v1",
            kind: "Secret",
            metadata: { name: $name, namespace: $ns },
            type: "Opaque",
            data: { "upstream-key.conf": (. | @base64) }
        }'
}

# Indents a file's content for embedding under a YAML block scalar (`key:
# |`), 4 spaces to match this script's ConfigMap templates. Blank lines are
# left empty rather than padded, so a generated ConfigMap has no trailing
# whitespace for yamllint to flag.
indent_block() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            printf '\n'
        else
            printf '    %s\n' "$line"
        fi
    done
}

# Extracts the `nginx.conf` key from a rendered proxy ConfigMap's block
# scalar (`nginx.conf: |`), reversing indent_block's 4-space indent. A blank
# line in the block carries no indent of its own, so it is matched too.
k8s_extract_nginx_conf() {
    awk '
        /^  nginx\.conf: \|$/ { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    '
}

# A hex sha256 of stdin, for the proxy config-change annotation below.
# sha256sum and openssl are not both guaranteed on every machine this might
# run on (sha256sum is missing without GNU coreutils, openssl is missing on
# a minimal install) -- try the GNU tool, then two portable fallbacks,
# before giving up.
k8s_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | sed 's/^.* //'
    else
        echo "Error: none of sha256sum, shasum or openssl found. One is" >&2
        echo "needed to hash the proxy ConfigMap's content, so a config" >&2
        echo "change can roll the proxy Deployment -- see" >&2
        echo "docs/kubernetes-runs.md." >&2
        return 1
    fi
}

# The sanitising half of k8s_safe_name below, factored out so a filesystem
# path (which has no 63-char Kubernetes object-name limit) can reuse it
# without the truncation that would otherwise chop it.
k8s_safe_name_component() {
    local branch="$1" safe
    safe="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    safe="${safe##-}"
    safe="${safe%%-}"
    printf '%s' "$safe"
}

# Resolves the fork-sandbox/owner label value: an explicit K8S_RUN_OWNER
# (already validated above, used as-is -- an operator-typed value is
# trusted, never re-sanitized on top of that), else a sanitized $USER,
# else nothing. k8s_safe_name_component does most of the sanitizing, but
# its output is NOT already a valid label value in every case -- see the
# trim and length notes in the body -- so this tightens it and then gates
# on k8s_valid_label_value rather than assuming.
#
# Omitting the label is reserved for a genuinely absent value -- neither
# K8S_RUN_OWNER nor $USER set, or $USER sanitizes to the empty string
# (e.g. every character in it is outside [a-z0-9-]). It is NOT for a value
# that merely looks generic: 'runner' correctly says a run came from CI
# and 'ubuntu' says it came from a devbox, and both are more useful than
# no label at all -- never add a check that omits the label because the
# name looks uninformative.
resolve_run_owner() {
    local owner
    if [[ -n "$K8S_RUN_OWNER" ]]; then
        printf '%s' "$K8S_RUN_OWNER"
        return 0
    fi
    [[ -n "${USER:-}" ]] || return 0
    owner="$(k8s_safe_name_component "$USER")"
    # k8s_safe_name_component's own trim is ${x##-}/${x%%-}, which removes
    # exactly ONE hyphen from each end. That is enough where it is normally
    # used -- an object name renders as "prefix-component", so a leftover
    # hyphen lands interior -- and not enough here, where the value stands
    # alone and must begin and end alphanumeric. A login name of "..bob"
    # sanitizes to "--bob" and survives that trim as "-bob", which the API
    # server rejects at submit. There is no length cap there either, and a
    # label value stops at 63.
    while [[ "$owner" == -* ]]; do owner="${owner#-}"; done
    while [[ "$owner" == *- ]]; do owner="${owner%-}"; done
    owner="${owner:0:63}"
    # Truncation can land on a hyphen, so trim again after it, not before.
    while [[ "$owner" == *- ]]; do owner="${owner%-}"; done
    # Belt and braces against a $USER shape not anticipated here: gate on the
    # same validator an operator-typed K8S_RUN_OWNER is refused by, and omit
    # the label rather than render one the API server will reject. Omitting
    # on an unrenderable value is the "genuinely absent" case above; it is
    # still never a judgement about the name looking uninformative.
    k8s_valid_label_value "$owner" || return 0
    printf '%s' "$owner"
}

# Builds the ordered list of already-qualified "key: value" label lines
# this run's resolved owner and free-form labels render as on every
# object: EXTRA_LABEL_LINES (module-global), owner first (bare
# fork-sandbox/owner key, only when $1 is non-empty) followed by each
# free-form label under the fixed fork-sandbox.io/ prefix, in
# RUN_LABEL_KEYS/RUN_LABEL_VALUES order (populated by resolve_run_labels).
build_extra_label_lines() {
    local owner="$1" i
    EXTRA_LABEL_LINES=()
    [[ -n "$owner" ]] && EXTRA_LABEL_LINES+=("fork-sandbox/owner: $owner")
    for i in "${!RUN_LABEL_KEYS[@]}"; do
        EXTRA_LABEL_LINES+=("fork-sandbox.io/${RUN_LABEL_KEYS[$i]}: ${RUN_LABEL_VALUES[$i]}")
    done
}

# Renders EXTRA_LABEL_LINES for interpolation directly after an existing
# "fork-sandbox/branch: $safe_name" line inside a heredoc, indented by $1
# spaces: "" when there are no extra labels (adds nothing to the render),
# or a leading newline plus one indented "key: value" line per entry with
# NO trailing newline -- the same optional-trailing-content shape
# $model_discovery_env and its neighbors above already use, so
# interpolating it straight after existing text produces no stray blank
# line either way.
render_extra_labels_indent() {
    local indent="$1" pad line out=""
    (( ${#EXTRA_LABEL_LINES[@]} == 0 )) && { printf '%s' ""; return 0; }
    pad="$(printf "%${indent}s" '')"
    for line in "${EXTRA_LABEL_LINES[@]}"; do
        out+=$'\n'"$pad$line"
    done
    printf '%s' "$out"
}

# Same label lines, for the claude-proxy static-template's __EXTRA_LABELS__
# marker substitution: each line indented by $1 spaces WITH a trailing
# newline (including the last), so a literal ${var//search/replace} can
# swap the whole marker line -- trailing newline included -- for either
# nothing (marker vanishes, no blank line left behind) or this block.
render_extra_labels_block() {
    local indent="$1" pad line out=""
    pad="$(printf "%${indent}s" '')"
    for line in "${EXTRA_LABEL_LINES[@]}"; do
        out+="$pad$line"$'\n'
    done
    printf '%s' "$out"
}

# Refuses a free-form label's key/value, in the order that gives the best
# error: (1) a reserved key -- app and fork-sandbox/branch are the
# NetworkPolicy selector keys that isolate one run's claude-proxy (and the
# operator's real access token behind it) from another's, fork-sandbox/role
# and fork-sandbox/owner are this script's own labels. The fixed
# fork-sandbox.io/ prefix already makes a collision with any of these
# impossible, but a caller who tries one gets a specific reason instead of a
# generic shape error. (2) the key's shape, since it becomes
# fork-sandbox.io/$key. (3) the value's shape. $what names the caller's
# source for the error message, e.g. "--label 'key=value'".
k8s_validate_label_kv() {
    local key="$1" value="$2" what="$3"
    case "$key" in
        app|fork-sandbox/branch|fork-sandbox/role|fork-sandbox/owner)
            echo "Error: $what sets '$key', which is reserved -- this script" >&2
            echo "renders it itself (app and fork-sandbox/branch select which" >&2
            echo "pods may reach a run's claude-proxy and its operator access" >&2
            echo "token; fork-sandbox/role and fork-sandbox/owner are its own" >&2
            echo "labels). Every free-form label already renders under" >&2
            echo "fork-sandbox.io/, so this can never collide in practice --" >&2
            echo "pick a different key." >&2
            return 1
            ;;
    esac
    if ! k8s_valid_label_key "$key"; then
        echo "Error: $what has key '$key', which is not a valid label key --" >&2
        echo 'it must be at most 63 characters and match' >&2
        echo '[a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?, since it renders as' >&2
        echo "fork-sandbox.io/$key." >&2
        return 1
    fi
    if ! k8s_valid_label_value "$value"; then
        echo "Error: $what has value '$value', which is not a valid label" >&2
        echo 'value -- it must be at most 63 characters and match' >&2
        echo '[a-zA-Z0-9]([-_.a-zA-Z0-9]*[a-zA-Z0-9])?, or be empty.' >&2
        return 1
    fi
    return 0
}

# Splits one key=value entry and validates it, setting the scratch globals
# PARSED_LABEL_KEY / PARSED_LABEL_VALUE on success -- the same "module-global
# out params" idiom parse_proxy_endpoints' PROXY_ENDPOINT_NAMES/_URLS already
# use in this file, rather than a bash nameref (unused anywhere else here).
# $what names the entry's source for the error, e.g. "--label 'key=value'".
k8s_parse_label_entry() {
    local entry="$1" what="$2" key value
    if [[ "$entry" != *=* ]]; then
        echo "Error: $what has no '='. Expected key=value." >&2
        return 1
    fi
    key="${entry%%=*}"
    value="${entry#*=}"
    k8s_validate_label_kv "$key" "$value" "$what" || return 1
    PARSED_LABEL_KEY="$key"
    PARSED_LABEL_VALUE="$value"
    return 0
}

# Parses K8S_RUN_LABELS ("key=value,key=value,...") into the
# RUN_LABELS_FILE_KEYS / RUN_LABELS_FILE_VALUES arrays (module-global, not
# local -- callers read them back after this returns), mirroring
# parse_proxy_endpoints above. An empty spec is not an error. A key repeated
# within the file itself is refused -- unlike a --label overriding a file
# key at resolve_run_labels below, two file entries for the same key is not
# an override, just an ambiguous file.
parse_run_labels_file() {
    local spec="$1" entry seen=","
    RUN_LABELS_FILE_KEYS=()
    RUN_LABELS_FILE_VALUES=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        k8s_parse_label_entry "$entry" "K8S_RUN_LABELS entry '$entry'" || return 1
        if [[ "$seen" == *",$PARSED_LABEL_KEY,"* ]]; then
            echo "Error: K8S_RUN_LABELS entry '$entry' repeats key" >&2
            echo "'$PARSED_LABEL_KEY', already set earlier in K8S_RUN_LABELS." >&2
            return 1
        fi
        seen+="$PARSED_LABEL_KEY,"
        RUN_LABELS_FILE_KEYS+=("$PARSED_LABEL_KEY")
        RUN_LABELS_FILE_VALUES+=("$PARSED_LABEL_VALUE")
    done
    return 0
}

# Resolves this run's free-form labels: K8S_RUN_LABELS supplies file-level
# defaults, each optionally overridden key-by-key by a --label given on this
# invocation ($@, in flag order) -- an override is announced on stderr, the
# way the --endpoint resolution above announces its own defaults; a
# file-only key is left alone. Populates the module-global
# RUN_LABEL_KEYS/RUN_LABEL_VALUES arrays build_extra_label_lines reads.
# Returns 1 (not exit) on any validation failure, matching
# parse_proxy_endpoints, so cmd_submit can `|| exit 1` it before anything is
# created.
resolve_run_labels() {
    local -a labels_raw=("$@")
    parse_run_labels_file "$K8S_RUN_LABELS" || return 1
    RUN_LABEL_KEYS=("${RUN_LABELS_FILE_KEYS[@]}")
    RUN_LABEL_VALUES=("${RUN_LABELS_FILE_VALUES[@]}")

    local entry seen_cli="," i found
    for entry in "${labels_raw[@]}"; do
        k8s_parse_label_entry "$entry" "--label '$entry'" || return 1
        if [[ "$seen_cli" == *",$PARSED_LABEL_KEY,"* ]]; then
            echo "Error: --label '$entry' repeats key '$PARSED_LABEL_KEY'," >&2
            echo "already given earlier with --label." >&2
            return 1
        fi
        seen_cli+="$PARSED_LABEL_KEY,"

        found=false
        for i in "${!RUN_LABEL_KEYS[@]}"; do
            if [[ "${RUN_LABEL_KEYS[$i]}" == "$PARSED_LABEL_KEY" ]]; then
                echo "fork-sandbox-k8s: --label '$PARSED_LABEL_KEY=$PARSED_LABEL_VALUE'" >&2
                echo "overrides K8S_RUN_LABELS's '$PARSED_LABEL_KEY=${RUN_LABEL_VALUES[$i]}'." >&2
                RUN_LABEL_VALUES[i]="$PARSED_LABEL_VALUE"
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            RUN_LABEL_KEYS+=("$PARSED_LABEL_KEY")
            RUN_LABEL_VALUES+=("$PARSED_LABEL_VALUE")
        fi
    done
    return 0
}

# An image reference's shape: no comma, equals sign, space, quote or
# newline -- every legal OCI reference fits this, and it is what the
# unquoted `image: $ref` YAML line below needs to stay a single scalar.
# $what names the flag or key for the error (e.g. "--image", or
# "K8S_PROJECT_IMAGES entry 'proj'"). When $require_qualified is 1, REF must
# also be fully qualified by Docker's own rule: the part before the first
# '/' contains a '.' or a ':', or is exactly 'localhost' -- a ref with no
# '/' at all is unqualified. K8S_IMAGE is deliberately never passed through
# this second check: that rule is documented for it but, unlike --image and
# K8S_PROJECT_IMAGES (new flags with no installed base), never enforced,
# per Compatibility.
k8s_valid_image_ref() {
    local ref="$1" what="$2" require_qualified="${3:-0}" first_segment
    if [[ -z "$ref" || ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]; then
        echo "Error: $what: '$ref' is not a valid image reference." >&2
        return 1
    fi
    if [[ "$require_qualified" == 1 ]]; then
        first_segment="${ref%%/*}"
        if [[ "$ref" != */* ]] \
            || { [[ "$first_segment" != *.* && "$first_segment" != *:* \
                    && "$first_segment" != localhost ]]; }; then
            echo "Error: $what: '$ref' is not a fully qualified image" >&2
            echo "reference. It must include a registry host (e.g." >&2
            echo "registry.example/you/image:tag) -- there is no default" >&2
            echo "registry to resolve a bare name against." >&2
            return 1
        fi
    fi
    return 0
}

# Parses K8S_PROJECT_IMAGES ("<project>=<ref>,<project>=<ref>,...") into the
# PROJECT_IMAGE_NAMES / PROJECT_IMAGE_REFS arrays (module-global, same
# convention as PROXY_ENDPOINT_NAMES/_URLS). <project> is a basename, so it
# gets the same shape K8S_POSTMASTER_PROJECT already requires
# (^[A-Za-z0-9][A-Za-z0-9._-]*$, so it can never be "." or ".."). An empty
# spec is not an error.
parse_project_images() {
    local spec="$1" entry name ref seen=","
    PROJECT_IMAGE_NAMES=()
    PROJECT_IMAGE_REFS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *=* ]]; then
            echo "Error: K8S_PROJECT_IMAGES entry '$entry' is not" >&2
            echo "<project>=<ref>." >&2
            return 1
        fi
        name="${entry%%=*}"
        ref="${entry#*=}"
        if [[ -z "$name" || ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "Error: K8S_PROJECT_IMAGES entry '$entry' has an invalid" >&2
            echo "project name -- it must match ^[A-Za-z0-9][A-Za-z0-9._-]*\$" >&2
            echo "(the basename of the project's repo top level)." >&2
            return 1
        fi
        if [[ "$seen" == *",$name,"* ]]; then
            echo "Error: K8S_PROJECT_IMAGES entry '$entry' repeats project" >&2
            echo "'$name', already set earlier in K8S_PROJECT_IMAGES." >&2
            return 1
        fi
        k8s_valid_image_ref "$ref" "K8S_PROJECT_IMAGES entry '$name'" 1 || return 1
        seen+="$name,"
        PROJECT_IMAGE_NAMES+=("$name")
        PROJECT_IMAGE_REFS+=("$ref")
    done
    return 0
}

# Resolves the pod image for this run: --image (REF_FLAG) wins over
# K8S_PROJECT_IMAGES's entry for PROJECT_BASENAME, which wins over K8S_IMAGE
# -- the precedence acceptance 2 requires. Sets the module-global RUN_IMAGE
# and RUN_IMAGE_SOURCE ("flag"|"project"|"k8s-env"). Announces the source on
# stderr for "flag"/"project", and a K8S_PROJECT_IMAGES miss; a run with
# neither key nor flag (nothing new applies) must stay silent, same as the
# --endpoint/--label precedence resolvers above announcing only a
# non-default choice. Returns 1 (not exit) on a bad ref, matching every
# other resolver in this file, so cmd_submit can `|| exit 1` it.
resolve_run_image() {
    local ref_flag="$1" project_basename="$2" i
    RUN_IMAGE=""
    RUN_IMAGE_SOURCE="k8s-env"

    if [[ -n "$ref_flag" ]]; then
        k8s_valid_image_ref "$ref_flag" "--image" 1 || return 1
        RUN_IMAGE="$ref_flag"
        RUN_IMAGE_SOURCE="flag"
        echo "fork-sandbox-k8s: --image '$ref_flag' overrides any" >&2
        echo "K8S_PROJECT_IMAGES entry and K8S_IMAGE." >&2
        return 0
    fi

    parse_project_images "$K8S_PROJECT_IMAGES" || return 1
    for i in "${!PROJECT_IMAGE_NAMES[@]}"; do
        if [[ "${PROJECT_IMAGE_NAMES[$i]}" == "$project_basename" ]]; then
            RUN_IMAGE="${PROJECT_IMAGE_REFS[$i]}"
            RUN_IMAGE_SOURCE="project"
            echo "fork-sandbox-k8s: using K8S_PROJECT_IMAGES entry" >&2
            echo "'$project_basename=$RUN_IMAGE' ($k8s_env)." >&2
            return 0
        fi
    done
    # Only when the key is set: a worktree or symlinked checkout has a
    # different basename and would otherwise drop to K8S_IMAGE unnoticed.
    if (( ${#PROJECT_IMAGE_NAMES[@]} > 0 )); then
        echo "fork-sandbox-k8s: no K8S_PROJECT_IMAGES entry for project" >&2
        echo "'$project_basename'; using K8S_IMAGE." >&2
    fi

    RUN_IMAGE="$K8S_IMAGE"
    RUN_IMAGE_SOURCE="k8s-env"
    return 0
}

# A Kubernetes object name: lowercase RFC 1123, <=63 chars. Branch names are
# freeform, so this derives a safe name rather than requiring the caller to
# pick one that already qualifies. Capped at 50, not 63: this name is also
# used as the base of the per-run claude-proxy Service, with a
# "-claude-proxy" suffix appended (13 chars), and a Service name is itself
# capped at 63 -- so the base must leave room for that suffix or a long
# branch renders a Service name the API server rejects, aborting submit
# after the Secret, ConfigMap and Pod for that run already exist.
# A normalized branch gets a digest too, even when it fits: otherwise refs
# such as feature/foo and feature-foo (or Feature/foo and feature-foo) share
# one set of Kubernetes objects.
k8s_safe_name() {
    local prefix="$1" branch="$2" component candidate digest base
    component="$(k8s_safe_name_component "$branch")"
    candidate="$prefix-$component"
    if [[ "$component" == "$branch" ]] && (( ${#candidate} <= 50 )); then
        printf '%s' "$candidate"
        return
    fi
    digest="$(printf '%s' "$branch" | k8s_sha256_stdin | cut -c1-8)"
    base="${candidate:0:41}"
    base="${base%-}"
    printf '%s-%s' "$base" "$digest"
}

# The object-name derivation used before k8s_safe_name added digests. Keep it
# for management commands so runs submitted by that version remain fetchable,
# sayable, and removable after this script is updated. Submit must continue to
# use k8s_safe_name: unlike this legacy form, it distinguishes names that
# sanitize to the same component.
k8s_legacy_safe_name() {
    local prefix="$1" branch="$2"
    printf '%s-%s' "$prefix" "$(k8s_safe_name_component "$branch")" \
        | cut -c1-50 | sed 's/-$//'
}

# Prefer the current name, then look for an object created with the legacy
# name. The fallback is intentionally limited to management commands; a
# submit never reuses a possibly colliding legacy name.
k8s_find_pod() {
    local safe_name="$1" legacy_name="$2" pod_name
    pod_name="$(kubectl get pod -l "job-name=$safe_name" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$pod_name" && "$legacy_name" != "$safe_name" ]]; then
        pod_name="$(kubectl get pod -l "job-name=$legacy_name" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    printf '%s' "$pod_name"
}

# --probe-only pod lookup: unlike k8s_find_pod above, a kubectl failure is
# NOT swallowed -- cmd_wait's --probe path needs to tell "the API answered:
# no pod" apart from "could not ask". Same safe/legacy name fallback, and
# every call carries --request-timeout so a hung API server cannot block
# past $3 seconds. Prints the pod name (possibly empty, when kubectl did
# answer) on stdout and returns 0, or prints nothing and returns 1 on any
# kubectl failure.
#
# Deliberately uses {.items[*]...}, NOT {.items[0]...}: kubectl's jsonpath
# engine treats an out-of-range index as a template error (exit 1, "array
# index out of bounds") on a genuinely empty, successfully-fetched list --
# indistinguishable from a real API failure, which is exactly the
# distinction this function exists to make. {.items[*]...} returns exit 0
# with empty output for an empty list instead, so a real kubectl failure
# stays a kubectl failure.
k8s_probe_find_pod() {
    local safe_name="$1" legacy_name="$2" req_timeout="$3" pod_name
    pod_name="$(kubectl get pod -l "job-name=$safe_name" \
        --request-timeout="${req_timeout}s" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || return 1
    pod_name="${pod_name%% *}"
    if [[ -z "$pod_name" && "$legacy_name" != "$safe_name" ]]; then
        pod_name="$(kubectl get pod -l "job-name=$legacy_name" \
            --request-timeout="${req_timeout}s" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || return 1
        pod_name="${pod_name%% *}"
    fi
    printf '%s' "$pod_name"
}

# --probe-only Job existence check, safe name then legacy: prints "" when
# kubectl answered "no such Job" (--ignore-not-found suppresses the
# NotFound error rather than failing the call) or a non-empty object name
# when it still exists, and returns 0 -- or prints nothing and returns 1 on
# any kubectl failure. Used by cmd_wait --probe to tell "the pod is simply
# gone (evicted, not yet scheduled)" -- Job still exists, not terminal --
# apart from "the run itself is gone" -- no Job either, terminal.
k8s_probe_find_job() {
    local safe_name="$1" legacy_name="$2" req_timeout="$3" job_name
    job_name="$(kubectl get job "$safe_name" --ignore-not-found -o name \
        --request-timeout="${req_timeout}s" 2>/dev/null)" || return 1
    if [[ -z "$job_name" && "$legacy_name" != "$safe_name" ]]; then
        job_name="$(kubectl get job "$legacy_name" --ignore-not-found -o name \
            --request-timeout="${req_timeout}s" 2>/dev/null)" || return 1
    fi
    printf '%s' "$job_name"
}

# Renders the four --review-loop-only ConfigMap keys: the review and fix
# prompts, the flattened review skill, and the loop script itself. The
# prompts are composed the same way handoff.md itself is -- preamble, then
# body -- except with NO overlay in between: --prompts-dir is refused on
# this path (see fork-sandbox.sh's --k8s flag refusals), so there is no
# overlay to layer on. The body text comes from fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body in fork-sandbox-lib.sh, the exact functions
# fork-sandbox.sh's own local --review-loop uses -- this function renders
# no prompt prose of its own, only concatenates what those functions emit.
# Indented 2 spaces to sit beside handoff.md as ConfigMap data keys.
#
# Each key's content is captured into a variable BEFORE the heredoc, and a
# failed capture returns 1. A command substitution inside a heredoc body
# hands its exit status to cat, not to the caller, so an inline $(...) would
# swallow an emitter failure -- e.g. fs_append_handoff_brief refusing a
# handoff that is missing, unreadable or empty at prompt-build time -- and
# render the prompt prose ("the brief ... is appended below") with the brief
# silently absent, a spec-less review and fix leg the commit that added the
# handoff section exists to prevent. cmd_submit calls this inside its own
# $(...), so returning 1 here makes its
# review_loop_configmap_keys=... assignment fail under set -e, the same
# guarantee the local path gets from its { ...; } > file block.
render_review_loop_configmap_keys() {
    local pod_clone_dir="$1" pod_inbox_dir="$2" pod_skill_dir="$3" pod_verdict_file="$4"
    local branch="$5" base_sha="$6" review_skill_src="$7" review_loop_sh="$8"
    local pod_outbox_dir="$9" outbox_max_bytes="${10}" handoff_file="${11}"
    local review_prompt fix_prompt_header review_skill review_loop
    review_prompt="$({ fs_emit_prompt_preamble "$pod_clone_dir" "$pod_inbox_dir" pi gated "$pod_outbox_dir" pod \
        "$outbox_max_bytes"
      fs_emit_review_prompt_body "$branch" "$base_sha" "$pod_skill_dir" \
          "$pod_verdict_file" "$pod_inbox_dir" "$handoff_file"; } | indent_block)" \
        || return 1
    fix_prompt_header="$({ fs_emit_prompt_preamble "$pod_clone_dir" "$pod_inbox_dir" pi gated "$pod_outbox_dir" pod \
        "$outbox_max_bytes"
      fs_emit_fix_prompt_body "$branch" "$base_sha" "$handoff_file"; } | indent_block)" \
        || return 1
    review_skill="$(indent_block < "$review_skill_src")" || return 1
    review_loop="$(indent_block < "$review_loop_sh")" || return 1
    cat <<KEYS
  review-prompt.md: |
$review_prompt
  fix-prompt-header.md: |
$fix_prompt_header
  code-review-portable-skill.md: |
$review_skill
  review-loop.sh: |
$review_loop
KEYS
}

# The two --review-loop-only env vars the agent container needs --
# REVIEW_LOOP_CAP (so the entrypoint knows to run the loop) and BASE_SHA
# (the commit review-loop.sh measures the branch against). Indented to
# match the other env entries in the rendered Job spec.
render_review_loop_env() {
    local cap="$1" base_sha="$2"
    cat <<ENV
            - name: REVIEW_LOOP_CAP
              value: "$cap"
            - name: BASE_SHA
              value: "$base_sha"
ENV
}

# The four --harness claude-only ConfigMap keys: the placeholder credential
# (already sanitized by the caller -- see cmd_submit's credential preflight),
# the operator-inbox hook, shipped in so the entrypoint can copy it to
# /work/inbox/.inbox-hook.sh and register it exactly like a local claude
# run's --settings does (fork-sandbox.sh's own inbox-hook install, around
# its own harness == claude guard), the commit-guard Stop hook
# (fork-sandbox-stop-guard.sh), installed and registered the same way, and
# fork-sandbox-lib.sh itself -- so the entrypoint's own claude-leg retry (see
# run_claude_attempt's wrapper) can source fs_leg_error_retryable and
# fs_harness_error from the exact same file the local runner does, rather
# than a second copy that could drift. Only shipped for claude: a pi run's
# entrypoint has no use for any of the three. Indented 2 spaces to sit
# beside the other ConfigMap data keys.
render_claude_configmap_keys() {
    local configmap_cred="$1" inbox_hook_src="$2" stop_guard_src="$3" lib_sh_src="$4"
    cat <<KEYS
  claude-credentials.json: |
$(printf '%s\n' "$configmap_cred" | indent_block)
  inbox-hook.sh: |
$(indent_block < "$inbox_hook_src")
  stop-guard.sh: |
$(indent_block < "$stop_guard_src")
  lib.sh: |
$(indent_block < "$lib_sh_src")
KEYS
}

# The three refresh-loop ConfigMap keys: the shared refresh.sh the pod's
# entrypoint sources, the continuation header (everything in handoff.md
# before the operator's own text), and the operator's handoff verbatim (the
# "original brief" every continuation prompt restates). Indented like
# render_claude_configmap_keys; refresh.sh's lines stay <= 96 columns so the
# 4-column indent fits the YAML line limit.
#
# handoff-original.md's trailing newlines are normalized to exactly one (the
# block scalar's clip chomping); accepted, so nothing here preserves them.
render_refresh_configmap_keys() {
    local refresh_src="$1" header_text="$2" handoff_src="$3"
    cat <<KEYS
  refresh.sh: |
$(indent_block < "$refresh_src")
  continuation-header.md: |
$(printf '%s' "$header_text" | indent_block)
  handoff-original.md: |
$(indent_block < "$handoff_src")
KEYS
}

# The --context-ro-only handoff.md section, appended after the shared
# preamble and before the operator's own handoff text -- see cmd_submit's
# handoff.md rendering below. Not folded into fs_emit_prompt_preamble
# itself: that function is shared with the local --context-ro flag, which
# binds the directory at its own host path and needs no section like this
# one, since the handoff author already knows that path. A pod's path
# differs from the host path the caller named, so this names it instead.
render_context_section() {
    local pod_context_dir="$1"
    cat <<EOF

## Gathered context

The directory named with \`--context-ro\` on the host is at:

    $pod_context_dir

here, read-only by convention. Do not write to it and do not copy it into
the clone.
EOF
}

# The --context-secret-only handoff.md section, in the slot
# render_context_section takes for --context-ro. Names the Secret, never
# any value.
render_context_secret_section() {
    local pod_context_dir="$1" secret_name="$2"
    cat <<EOF

## Context secret

The Kubernetes Secret \`$secret_name\` is mounted read-only at:

    $pod_context_dir

One file per key. Read what the task needs. Never print, copy, log or
commit its contents.
EOF
}

# The per-run-services-only handoff.md section: names each service and its
# 127.0.0.1:<port>, and the .env.sandbox convention -- mirrors the register
# of the local path's own "Per-run services are up" section
# (fork-sandbox.sh's fs_emit_prompt_overlay context), minus the sockets
# directory and socat relay recipe, since a sidecar shares the pod's
# network namespace and is reachable directly. services_lines is
# prompt-services.txt's content, one "<name> 127.0.0.1:<port>" per line.
render_services_section() {
    local services_lines="$1"
    local sandbox_env_present="$2"
    cat <<EOF

## Per-run services

This repository declares per-run services (.agents/sandbox-services/services.yaml),
running now, reachable directly on localhost:

$(printf '%s\n' "$services_lines" | sed 's/^/    /')

EOF
    if (( sandbox_env_present )); then
        cat <<EOF
The clone holds an env file, \`.env.sandbox\`, with the connection settings
from the spec's \`sandboxEnv\`. Use it the way the project expects -- most
projects read it as \`ENVFILE=.env.sandbox <command>\`, or by sourcing it;
check the project's own CLAUDE.md.
EOF
    fi

    cat <<EOF
These come up empty. Copy no developer data in. The session migrates and
loads its own fixtures.
EOF
}

# Validates an upstream base URL -- K8S_PROXY_UPSTREAM, or one
# K8S_PROXY_ENDPOINTS entry's URL. https:// is accepted for any host,
# unchanged from before this function existed. http:// is accepted ONLY
# when its host is a private address (RFC1918, loopback, or link-local) --
# plain http:// to a public host would put a request on the open internet
# in cleartext, which stays refused. TLS and authentication are
# independent properties: whether an upstream needs a key is never
# inferred from its scheme, so this checks the URL alone and nothing about
# K8S_PROXY_UPSTREAM vs K8S_PROXY_ENDPOINTS. A hostname (anything that
# doesn't parse as a literal IPv4 address) on http:// is refused too --
# this script has no network access to resolve one, so its privateness
# can never be verified. One hostname shape IS structurally verifiable
# without DNS, though: a Kubernetes Service name, <svc>.<ns>.svc.<cluster
# domain>, resolves only inside the cluster's own DNS -- though an
# ExternalName Service can still CNAME it to a public host, so the name
# alone is not a privateness guarantee. A host ending in
# .svc.$K8S_CLUSTER_DOMAIN is still accepted on http:// (checked before
# the IPv4 path below ever runs), refused outright on port 443 (the only
# port the default egress policy ever carries to a public address), and
# left to cmd_install's reachability review to warn about on any other
# port a custom K8S_PROXY_ALLOW opens publicly.
#
# On success, prints the bare host (scheme stripped, path cut at the first
# /, port kept) on stdout -- the same value proxy_ssl_name/Host has always
# used -- and returns 0. On failure, prints nothing to stdout, an
# explanatory message to stderr, and returns non-zero. $2, when given,
# names the setting in error messages (defaults to "URL").
validate_upstream_url() {
    local url="$1" label="${2:-URL}" scheme host host_only octet o1 o2

    case "$url" in
        https://*) scheme=https ;;
        http://*) scheme=http ;;
        *)
            echo "Error: $label must start with https:// or http://, got" >&2
            echo "'$url'." >&2
            return 1
            ;;
    esac

    host="${url#*://}"
    host="${host%%/*}"
    if [[ "$scheme" == https ]]; then
        printf '%s' "$host"
        return 0
    fi

    # ${host%:*} is a no-op when there is no ':' to split on, which is
    # exactly right for a bare IPv4 host with no port.
    host_only="${host%:*}"

    # A Service DNS name (the .svc. segment is what marks it as one,
    # narrower than just "ends in the cluster domain") resolves only inside
    # the cluster's own DNS -- but an ExternalName Service can still CNAME
    # that name to an arbitrary public host, so the name itself is not a
    # guarantee of privateness. What actually holds the gate up is the
    # proxy's own NetworkPolicy egress (render_proxy_egress_rules /
    # render_proxy_egress_rules_ns): a .svc. name only stays inside the
    # cluster if the rendered egress policy does not also carry its port to
    # a public address. The default policy (unset K8S_PROXY_ALLOW) carries
    # ANY address on port 443 and nothing else, so http:// to a .svc. name
    # on 443 is refused outright below WHEN K8S_PROXY_ALLOW IS UNSET -- a
    # CNAME to a public host would otherwise leak this endpoint's
    # Authorization header to the open internet in cleartext, exactly what
    # this http:// gate exists to prevent. A set K8S_PROXY_ALLOW replaces
    # that default policy wholesale (render_proxy_egress_rules's own
    # header), so whether port 443 still carries to a public address then
    # depends on the operator's own entries, not this function's hardcoded
    # assumption -- checking that needs PROXY_ALLOW_CIDRS/PORTS, which are
    # not parsed yet at validation time (parse_proxy_endpoints, and thus
    # this function, runs before parse_proxy_allow). So a set
    # K8S_PROXY_ALLOW skips this refusal entirely and defers to
    # cmd_install's reachability review, exactly like every other port
    # already does. Accepted here before the IPv4-only path below even
    # runs -- everything past this point is unchanged.
    if [[ "$host_only" == *".svc.$K8S_CLUSTER_DOMAIN" ]]; then
        # Forced base 10 (10#$svc_port): same unforced-base trap this
        # function's own IPv4-octet loop below (and parse_proxy_allow_ns's
        # header) document. A malformed port here just skips this 443
        # check rather than erroring -- full port validation for a
        # Service-DNS URL is cmd_install's reachability review's job, not
        # this function's.
        local svc_port
        svc_port="${host#*:}"
        [[ "$svc_port" == "$host" ]] && svc_port=""
        if [[ "$svc_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$svc_port == 443 )) \
            && [[ -z "$K8S_PROXY_ALLOW" ]]; then
            echo "Error: $label uses http:// to '$host_only' on port" >&2
            echo "443 -- the default egress policy (unset" >&2
            echo "K8S_PROXY_ALLOW) carries any address on port 443, so" >&2
            echo "if this Service name ever CNAMEs off-cluster the" >&2
            echo "request would leave the cluster in cleartext," >&2
            echo "credential included. Use https://, or a non-443 port" >&2
            echo "if this really is a plaintext in-cluster Service." >&2
            return 1
        fi
        printf '%s' "$host"
        return 0
    fi

    if [[ ! "$host_only" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        echo "Error: $label uses http://, which this repo only accepts to a" >&2
        echo "private address (RFC1918, loopback, or link-local) --" >&2
        echo "'$host_only' is not a literal IPv4 address, so it cannot be" >&2
        echo "verified as private without DNS. Use https://, or a literal" >&2
        echo "private IP." >&2
        return 1
    fi
    # Forced base 10 (10#$octet): plain (( octet > 255 )) hands bash
    # arithmetic a string it parses as C-style integer literals, so a
    # leading zero is octal -- "012" reads as 10, and "08"/"09" aren't
    # valid octal digits at all and abort with a bash error. Both let an
    # octet with a leading zero either misclassify (letting a public
    # address like 012.5.6.7 -> 10.5.6.7 pass the private-address gate) or
    # spew interpreter noise instead of this function's own message.
    for octet in "${BASH_REMATCH[@]:1}"; do
        if (( 10#$octet > 255 )); then
            echo "Error: $label's host '$host_only' is not a valid IPv4" >&2
            echo "address." >&2
            return 1
        fi
    done
    o1="${BASH_REMATCH[1]}"
    o2="${BASH_REMATCH[2]}"
    if ! { (( 10#$o1 == 10 )) \
        || (( 10#$o1 == 172 && 10#$o2 >= 16 && 10#$o2 <= 31 )) \
        || (( 10#$o1 == 192 && 10#$o2 == 168 )) \
        || (( 10#$o1 == 127 )) \
        || (( 10#$o1 == 169 && 10#$o2 == 254 )); }; then
        echo "Error: $label uses http:// to '$host_only', which is not a" >&2
        echo "private address (RFC1918 10.0.0.0/8, 172.16.0.0/12," >&2
        echo "192.168.0.0/16, loopback 127.0.0.0/8, or link-local" >&2
        echo "169.254.0.0/16). Plain http:// to a public address would put" >&2
        echo "a request on the open internet in cleartext -- use https://" >&2
        echo "instead." >&2
        return 1
    fi

    printf '%s' "$host"
    return 0
}

# Parses K8S_PROXY_ENDPOINTS ("name=url,name=url,...") into the
# PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS arrays (module-global, not
# local -- callers read them back after this returns). An empty spec is not
# an error here; cmd_install is what decides whether an empty registry is
# acceptable, since that depends on K8S_PROXY_UPSTREAM too. Each name
# becomes a path segment (/e/<name>/v1/...) on the rendered proxy, so it is
# validated against the same RFC1123-label shape K8S_NAMESPACE already
# uses above -- one registry entry, one deliberate config roll; the model
# behind it is free to change without touching this.
parse_proxy_endpoints() {
    local spec="$1" entry name url seen=","
    PROXY_ENDPOINT_NAMES=()
    PROXY_ENDPOINT_URLS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *=* ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$entry' is not" >&2
            echo "<logical-name>=<base-url>." >&2
            return 1
        fi
        name="${entry%%=*}"
        url="${entry#*=}"
        if [[ -z "$name" ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$entry' has an empty" >&2
            echo "name." >&2
            return 1
        fi
        if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS name '$name' is not valid -- it" >&2
            echo "becomes a path segment (/e/$name/v1/...) and must match" >&2
            echo '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$.' >&2
            return 1
        fi
        if [[ -z "$url" ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS entry '$name' has an empty" >&2
            echo "base URL." >&2
            return 1
        fi
        validate_upstream_url "$url" "K8S_PROXY_ENDPOINTS entry '$name'" >/dev/null || return 1
        # validate_upstream_url only inspects scheme and host; the full raw
        # value (path included) is what render_proxy_locations_body renders
        # into `set $upstream "...";`, so it needs reject_nginx_unsafe_chars
        # too (see that function's own header).
        reject_nginx_unsafe_chars "$url" "K8S_PROXY_ENDPOINTS entry '$name' URL" || return 1
        if [[ "$seen" == *",$name,"* ]]; then
            echo "Error: K8S_PROXY_ENDPOINTS name '$name' is registered more" >&2
            echo "than once. Each logical name must be unique." >&2
            return 1
        fi
        seen+="$name,"
        # render_proxy_locations_body concatenates this straight onto
        # "/chat/completions" and "/models" -- a trailing slash here would
        # double up into ".../chat/completions" and 404 on vLLM and most
        # OpenAI-compatible servers. Strip exactly one; validate_upstream_url
        # already rejected anything that couldn't parse as a URL at all.
        url="${url%/}"
        PROXY_ENDPOINT_NAMES+=("$name")
        PROXY_ENDPOINT_URLS+=("$url")
    done
    return 0
}

# Parses K8S_PROXY_ENDPOINT_KEYS ("<name>=<VAR_NAME>,<name>=<VAR_NAME>,...")
# into the KEYED_ENDPOINT_NAMES / KEYED_ENDPOINT_VARS arrays (module-global,
# same convention as PROXY_ENDPOINT_NAMES/_URLS above). <name> is meant to be
# a K8S_PROXY_ENDPOINTS entry, but that is NOT cross-checked here -- callers
# (cmd_install) do that separately, after both parsers have run, so an
# unregistered name can be reported naming both halves (the endpoint and the
# pi.env variable) at once, which this parser alone cannot do. <VAR_NAME> is
# the NAME of a variable in pi.env holding the credential -- this file holds
# only the name, never the value, since k8s.env is published for onboarding
# (see docs/kubernetes-runs.md). An empty spec is not an error -- an install
# with no keyed endpoints is the common case.
parse_proxy_endpoint_keys() {
    local spec="$1" entry name var_name seen=","
    KEYED_ENDPOINT_NAMES=()
    KEYED_ENDPOINT_VARS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *=* ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS entry '$entry' is not" >&2
            echo "<endpoint-name>=<VAR_NAME>." >&2
            return 1
        fi
        name="${entry%%=*}"
        var_name="${entry#*=}"
        if [[ -z "$name" ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS entry '$entry' has an empty" >&2
            echo "endpoint name." >&2
            return 1
        fi
        if [[ -z "$var_name" ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS entry '$name' has an empty" >&2
            echo "variable name." >&2
            return 1
        fi
        if [[ ! "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS variable name '$var_name' (for" >&2
            echo "endpoint '$name') is not a valid environment variable name --" >&2
            echo 'it must match ^[A-Za-z_][A-Za-z0-9_]*$.' >&2
            return 1
        fi
        if [[ "$seen" == *",$name,"* ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS names endpoint '$name' more" >&2
            echo "than once. Each endpoint can be keyed at most once." >&2
            return 1
        fi
        seen+="$name,"
        KEYED_ENDPOINT_NAMES+=("$name")
        KEYED_ENDPOINT_VARS+=("$var_name")
    done
    return 0
}

# True (0) if $1 is a K8S_PROXY_ENDPOINT_KEYS-registered endpoint name, per
# the KEYED_ENDPOINT_NAMES array parse_proxy_endpoint_keys filled in. Used by
# render_proxy_locations_body to decide which endpoint's location blocks get
# an Authorization header.
is_keyed_endpoint() {
    local name="$1" k
    for k in "${KEYED_ENDPOINT_NAMES[@]}"; do
        [[ "$k" == "$name" ]] && return 0
    done
    return 1
}

# Parses K8S_PROXY_ENDPOINT_EMBEDDINGS ("<name>,<name>,...") into the
# EMBED_ENDPOINT_NAMES array (module-global). Must run after
# parse_proxy_endpoints: every name has to be registered there, and an
# opted-in endpoint's base URL has to end in /v1, since the TEI-native
# /embed route lives at the gateway root and its upstream is derived by
# stripping that one segment. An empty spec is not an error.
parse_proxy_endpoint_embeddings() {
    local spec="$1" name i url rest seen=","
    EMBED_ENDPOINT_NAMES=()
    [[ -z "$spec" ]] && return 0

    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        echo "Error: K8S_PROXY_ENDPOINT_EMBEDDINGS is not available: this" >&2
        echo "namespace was installed with K8S_PROXY_UPSTREAM; there are no" >&2
        echo "named endpoints." >&2
        return 1
    fi
    # read -ra drops a trailing empty field, so a trailing comma has to be
    # caught on the raw string.
    if [[ "$spec" == ,* || "$spec" == *, || "$spec" == *,,* ]]; then
        echo "Error: K8S_PROXY_ENDPOINT_EMBEDDINGS '$spec' has an empty" >&2
        echo "element. Names are comma-separated, with no leading, doubled" >&2
        echo "or trailing comma." >&2
        return 1
    fi

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for name in "${entries[@]}"; do
        url=""
        for (( i = 0; i < ${#PROXY_ENDPOINT_NAMES[@]}; i++ )); do
            if [[ "${PROXY_ENDPOINT_NAMES[$i]}" == "$name" ]]; then
                url="${PROXY_ENDPOINT_URLS[$i]}"
                break
            fi
        done
        if [[ -z "$url" ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_EMBEDDINGS names endpoint '$name'," >&2
            echo "which is not registered in K8S_PROXY_ENDPOINTS. The registered" >&2
            echo "endpoints are:" >&2
            printf '%s\n' "${PROXY_ENDPOINT_NAMES[@]}" | sed 's/^/  /' >&2
            return 1
        fi
        if [[ "$seen" == *",$name,"* ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_EMBEDDINGS names endpoint '$name'" >&2
            echo "more than once." >&2
            return 1
        fi
        seen+="$name,"
        # Judged on what follows the scheme, so a host that is itself
        # called v1 (http://v1) is not mistaken for a /v1 path segment.
        rest="${url#*://}"
        if [[ "$rest" != */v1 ]]; then
            echo "Error: K8S_PROXY_ENDPOINT_EMBEDDINGS opts in endpoint '$name'," >&2
            echo "but its base URL '$url' does not end in /v1, so the TEI root" >&2
            echo "for /e/$name/embed cannot be derived." >&2
            return 1
        fi
        EMBED_ENDPOINT_NAMES+=("$name")
    done
    return 0
}

# True (0) if $1 is a K8S_PROXY_ENDPOINT_EMBEDDINGS-opted-in endpoint name.
is_embeddings_endpoint() {
    local name="$1" e
    for e in "${EMBED_ENDPOINT_NAMES[@]}"; do
        [[ "$e" == "$name" ]] && return 0
    done
    return 1
}

# Parses K8S_PROXY_ALLOW ("<cidr>:<port>,<cidr>:<port>,...") into the
# PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS arrays (module-global). An empty spec
# is not an error -- cmd_install renders today's default RFC1918-except
# egress block when it's unset, unchanged. NetworkPolicy has no hostname
# field, so a name here (anything that doesn't parse as an IPv4 CIDR) is
# refused outright rather than silently accepted and never matching
# anything -- see the ipBlock section of the NetworkPolicy API: it takes a
# CIDR, never a DNS name.
parse_proxy_allow() {
    local spec="$1" entry cidr port
    PROXY_ALLOW_CIDRS=()
    PROXY_ALLOW_PORTS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *:* ]]; then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' is not <cidr>:<port>." >&2
            return 1
        fi
        cidr="${entry%:*}"
        port="${entry##*:}"
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' does not name a valid" >&2
            echo "IPv4 CIDR ('$cidr'). NetworkPolicy has no hostname field --" >&2
            echo "an egress rule can only ever match an ipBlock, never a DNS" >&2
            echo "name, so a hostname cannot be accepted here." >&2
            return 1
        fi
        # Each octet range-checked 0-255: the regex above admits both a
        # leading-zero octet ("010") and an out-of-range one ("999"). An
        # out-of-range octet is a correctness bug, not a style one: it
        # overflows ipv4_to_int's 32-bit packing (999 << 24 masked to 32
        # bits is 231, so 999.0.0.0 would be classified as the DIFFERENT
        # real network 231.0.0.0). This deliberately re-implements the
        # octet check that sandbox-backend-container's is_valid_ipv4
        # performs inline rather than sharing it: the shared predicate
        # reports validity only, and this message names the failing
        # octet; the pair also lives in that standalone backend script,
        # not in fork-sandbox-lib.sh, so reusing it would mean lifting
        # it there first.
        local -a octets
        IFS='.' read -ra octets <<< "${cidr%/*}"
        local o
        for o in "${octets[@]}"; do
            if (( 10#$o > 255 )); then
                echo "Error: K8S_PROXY_ALLOW entry '$entry' has an octet '$o'" >&2
                echo "outside the valid range 0-255 (in CIDR '$cidr')." >&2
                return 1
            fi
        done
        # The prefix is range-checked 0-32 BEFORE the octets are
        # normalized below, so -- like the octet refusal above -- this
        # message quotes the CIDR exactly as the operator wrote it, not
        # the parser's normalized internal state. The regex admits "33"
        # through "99", and cidr_contains's and cidr_is_private's
        # 0xFFFFFFFF << (32 - prefix) arithmetic assumes a 0-32 prefix.
        if (( 10#${cidr#*/} > 32 )); then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' has a prefix length" >&2
            echo "'${cidr#*/}' outside the valid range 0-32 (in CIDR '$cidr')." >&2
            return 1
        fi
        # Canonical decimal address, so 192.000.002.015/32 is stored (and
        # rendered) as 192.0.2.15/32. Two independent reasons, and the
        # first one is load-bearing:
        #
        # The manifest renders the stored CIDR verbatim, and a current
        # Kubernetes API server REFUSES a leading-zero octet in
        # NetworkPolicy ipBlock.cidr. Verified by server-side dry-run
        # against a live v1.36.1 API server, which answered:
        #   spec.egress[0].to[0].ipBlock.cidr: Invalid value:
        #   "192.000.002.015/32": must not have leading 0s in IP or
        #   prefix length
        # So without this normalization the install dies at apply time
        # with an API error instead of this function's own message.
        # Do not weaken this to "cosmetic" on the argument that
        # k8s.io/utils/net's lenient ParseCIDRSloppy accepts leading
        # zeros: whatever the historical parse path, the server observed
        # above rejects it. Older servers may well be lenient, which is
        # an argument for normalizing here rather than against it.
        #
        # Second, independent of any API behaviour: the canonical form
        # is what this function range-checked, and it matches the prefix
        # and port normalization below.
        cidr="$(( 10#${octets[0]} )).$(( 10#${octets[1]} )).$(( 10#${octets[2]} )).$(( 10#${octets[3]} ))/${cidr#*/}"
        # Forced base 10 (10#$prefix), normalized to canonical decimal: a
        # leading-zero prefix like "/08" passes the regex above (it's
        # [0-9]{1,2}) and would otherwise reach cidr_contains's and
        # cidr_is_private's own arithmetic unnormalized -- the same
        # unforced-base trap validate_upstream_url's header documents,
        # except here it aborts the whole install with a bare interpreter
        # error instead of either function's own message.
        cidr="${cidr%/*}/$(( 10#${cidr#*/} ))"
        # Forced base 10 (10#$port), and normalized to canonical decimal
        # below: plain (( port < 1 || port > 65535 )) hands bash arithmetic
        # a string it parses as a C-style integer literal, so a leading
        # zero is octal -- the same trap validate_upstream_url's own header
        # documents. Left unnormalized, a value like "08080" would still
        # crash cmd_install's reachability review later, at the
        # (( port == PROXY_ALLOW_PORTS[j] )) comparisons that assume this
        # array already holds clean decimal ports (same reasoning as
        # parse_proxy_allow_ns's own normalization, below).
        if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
            echo "Error: K8S_PROXY_ALLOW entry '$entry' has an invalid port" >&2
            echo "'$port' -- must be 1-65535." >&2
            return 1
        fi
        port="$(( 10#$port ))"
        PROXY_ALLOW_CIDRS+=("$cidr")
        PROXY_ALLOW_PORTS+=("$port")
    done
    return 0
}

# Prints, to stderr, every extra egress destination K8S_AGENT_ALLOW_NS opens
# for the AGENT pod, plus the caveat that makes K8S_DENIED_PROBE meaningful
# alongside it. Prints nothing when the key is unset, which is every install
# that has not asked to widen the seal.
#
# Called from BOTH install and submit, deliberately. install is what applies
# the policy, but it is a separate command run once; every run for weeks
# afterwards is governed by a seal nobody is looking at, and a run log that
# says only "policy verified, proceeding" points its reader at a tighter seal
# than actually exists. Repeating it per submit costs three lines and keeps
# the run's own output honest about what that run could reach.
#
# Requires PROXY_ALLOW_NS_* to already hold THIS key's parse; callers restore
# the proxy's afterwards (see cmd_install).
announce_agent_allow_ns() {
    local i ns port
    (( ${#PROXY_ALLOW_NS_NAMESPACES[@]} )) || return 0
    for (( i = 0; i < ${#PROXY_ALLOW_NS_NAMESPACES[@]}; i++ )); do
        ns="${PROXY_ALLOW_NS_NAMESPACES[$i]}"
        port="${PROXY_ALLOW_NS_PORTS[$i]}"
        if [[ -n "$port" ]]; then
            echo "fork-sandbox-k8s: K8S_AGENT_ALLOW_NS opens agent egress to namespace '$ns' on TCP port $port." >&2
        else
            echo "fork-sandbox-k8s: K8S_AGENT_ALLOW_NS opens agent egress to namespace '$ns' on every port and protocol." >&2
        fi
    done
    echo "fork-sandbox-k8s: K8S_DENIED_PROBE must name a destination outside those namespaces, or the gate's denied half proves nothing." >&2
}

# Same as announce_agent_allow_ns, worded for a single run's own
# --allow-namespace grant rather than the machine-wide K8S_AGENT_ALLOW_NS
# default. Reads PROXY_ALLOW_NS_NAMESPACES/PORTS directly like its sibling,
# so the caller must call this immediately after its own
# parse_proxy_allow_ns call, before anything else can overwrite those
# globals.
announce_run_allow_ns() {
    local i ns port
    (( ${#PROXY_ALLOW_NS_NAMESPACES[@]} )) || return 0
    for (( i = 0; i < ${#PROXY_ALLOW_NS_NAMESPACES[@]}; i++ )); do
        ns="${PROXY_ALLOW_NS_NAMESPACES[$i]}"
        port="${PROXY_ALLOW_NS_PORTS[$i]}"
        if [[ -n "$port" ]]; then
            echo "fork-sandbox-k8s: this run's --allow-namespace opens agent egress to namespace '$ns' on TCP port $port, for this run only." >&2
        else
            echo "fork-sandbox-k8s: this run's --allow-namespace opens agent egress to namespace '$ns' on every port and protocol, for this run only." >&2
        fi
    done
    echo "fork-sandbox-k8s: K8S_DENIED_PROBE must name a destination outside every namespace this run can reach, static or per-run, or the gate's denied half proves nothing." >&2
}

# Parses K8S_PROXY_ALLOW_NS ("<namespace>[:<port>],<namespace>[:<port>],...")
# into the PROXY_ALLOW_NS_NAMESPACES / PROXY_ALLOW_NS_PORTS arrays
# (module-global; an empty string in PROXY_ALLOW_NS_PORTS means "every
# port"). An empty spec is not an error -- it renders no namespaceSelector
# rule at all, see render_proxy_egress_rules_ns. Unlike K8S_PROXY_ALLOW, the
# port here is optional: kube-proxy DNATs a ClusterIP to a pod IP before
# egress policy is evaluated on most CNIs, so this exists specifically to
# reach an in-cluster Service by the namespace label a NetworkPolicy can
# actually match, and a site pointing at such a Service may not know (or
# want to pin) which port it listens on.
# $2 is the config key name used in error messages, defaulting to
# K8S_PROXY_ALLOW_NS. K8S_AGENT_ALLOW_NS passes its own name so a bad entry
# names the key the operator actually set -- the syntax, the validation and
# the DNAT reasoning are identical for both, only the pod they govern
# differs (the proxy's policy here, the agent's in the platform plugin).
parse_proxy_allow_ns() {
    local spec="$1" label="${2:-K8S_PROXY_ALLOW_NS}" entry ns port
    PROXY_ALLOW_NS_NAMESPACES=()
    PROXY_ALLOW_NS_PORTS=()
    [[ -z "$spec" ]] && return 0

    local -a entries
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        if [[ "$entry" == *:* ]]; then
            ns="${entry%:*}"
            port="${entry##*:}"
            if [[ -z "$port" ]]; then
                echo "Error: $label entry '$entry' has a trailing ':'" >&2
                echo "with no port after it -- omit the ':' entirely for every port," >&2
                echo "or name one, such as '$ns:8001'." >&2
                return 1
            fi
        else
            ns="$entry"
            port=""
        fi
        # 63 is the label-VALUE cap the API enforces on
        # kubernetes.io/metadata.name -- the same limit k8s_valid_label_value
        # applies to every other label this script emits. Checking it here
        # fails fast instead of at kubectl apply.
        if [[ ! "$ns" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ || ${#ns} -gt 63 ]]; then
            echo "Error: $label entry '$entry' does not name a valid" >&2
            echo "namespace ('$ns') -- it must match" >&2
            echo '[a-z0-9]([a-z0-9-]*[a-z0-9])?, the standard' >&2
            echo "kubernetes.io/metadata.name label shape, and be at most" >&2
            echo "63 characters." >&2
            return 1
        fi
        # Forced base 10 (10#$port): plain (( port < 1 || port > 65535 ))
        # hands bash arithmetic a string it parses as a C-style integer
        # literal, so a leading zero is octal -- "08"/"09" aren't valid
        # octal digits at all and abort with a bash arithmetic error instead
        # of this function's own message, leaving the port unvalidated and
        # rendered as-is. validate_upstream_url's own header documents this
        # same trap.
        if [[ -n "$port" ]] && { [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); }; then
            echo "Error: $label entry '$entry' has an invalid port" >&2
            echo "'$port' -- must be 1-65535." >&2
            return 1
        fi
        # Re-rendered below as a bare YAML `port: $port` (and compared with
        # plain (( )) arithmetic by cmd_install's reachability check) --
        # normalized to canonical decimal here so a leading-zero input like
        # "08" never carries into either as a string the Kubernetes API
        # reads as a named port (or crashes the same unforced-base
        # arithmetic this parser just avoided).
        [[ -n "$port" ]] && port="$(( 10#$port ))"
        PROXY_ALLOW_NS_NAMESPACES+=("$ns")
        PROXY_ALLOW_NS_PORTS+=("$port")
    done
    return 0
}

# Packs a literal IPv4 address (no validation -- callers already matched one
# with the ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ regex
# validate_upstream_url uses) into a 32-bit integer for cidr_contains below.
# 10#$octet forces base 10 for the same reason validate_upstream_url does --
# see its own header -- a leading zero in $1 must never be read as octal.
ipv4_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    printf '%d' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

# True (0) if the literal IPv4 address $2 falls inside the literal IPv4
# CIDR $1 ("<a.b.c.d>/<prefix>"), used by cmd_install's K8S_PROXY_ALLOW
# coverage warning below. $1 is already known to match
# parse_proxy_allow's own CIDR regex.
cidr_contains() {
    local cidr="$1" ip="$2" net prefix mask
    net="${cidr%/*}"
    prefix="${cidr#*/}"
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( ($(ipv4_to_int "$net") & mask) == ($(ipv4_to_int "$ip") & mask) ))
}

# True (0) if the literal IPv4 CIDR $1 ("<a.b.c.d>/<prefix>") is wholly
# inside RFC1918 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16), loopback
# (127.0.0.0/8), link-local (169.254.0.0/16) or CGNAT (100.64.0.0/10) --
# used by cmd_install's reachability review to decide whether a
# K8S_PROXY_ALLOW entry that carries a .svc. http:// endpoint's port is
# itself public. Subset containment against each reference range (its own
# prefix included), not just a check on the network address's own octets:
# the prefix matters too, since a supernet like 10.0.0.0/7 has a network
# address that looks private (o1=10) but actually spans into 11.0.0.0/8,
# which is public -- a plain octet check would call that CIDR private and
# suppress the cleartext warning for it. Accepted because this is a
# warning, not a refusal (see validate_upstream_url's 1a/1b split).
# 10#$prefix forces base 10 for the same unforced-base reason
# validate_upstream_url's own header documents -- parse_proxy_allow now
# normalizes every CIDR it accepts, so a leading-zero prefix should never
# reach here in practice, but this function has no way to enforce that on
# a caller and the cost of forcing it again is one extra "10#"; ipv4_to_int
# already forces base 10 on each octet it packs.
cidr_is_private() {
    local cidr="$1" net prefix net_int ref refnet refprefix refmask
    net="${cidr%/*}"
    prefix="${cidr#*/}"
    net_int="$(ipv4_to_int "$net")"
    for ref in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 \
        169.254.0.0/16 100.64.0.0/10; do
        refnet="${ref%/*}"
        refprefix="${ref#*/}"
        refmask=$(( (0xFFFFFFFF << (32 - refprefix)) & 0xFFFFFFFF ))
        if (( 10#$prefix >= refprefix )) \
            && (( (net_int & refmask) == ($(ipv4_to_int "$refnet") & refmask) )); then
            return 0
        fi
    done
    return 1
}

# The NetworkPolicy egress rule(s) allowing whichever hosts model access
# needs -- replaces the whole `- to: []  # __PROXY_EGRESS_RULES__` /
# `ports: []` placeholder stanza in manifests/k8s/30-proxy.yaml (see
# render_proxy_egress_rules_sub below for why a whole-stanza replacement,
# rather than a bare token, is what keeps the raw template parseable YAML).
# Unset K8S_PROXY_ALLOW renders exactly what this repo has always rendered
# here (byte-for-byte): any host except RFC1918/loopback/link-local/CGNAT, on
# 443. A set K8S_PROXY_ALLOW replaces that block with exactly the given
# <cidr>:<port> entries (from the PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS
# arrays parse_proxy_allow filled in) and nothing else -- explicit egress,
# for whatever private (or public) addresses K8S_PROXY_ENDPOINTS names.
# K8S_PROXY_ALLOW_NS's namespaceSelector rule(s), rendered by
# render_proxy_egress_rules_ns below, always append after whichever of the
# two blocks above ran -- it composes with K8S_PROXY_ALLOW rather than being
# replaced by it, since the two express different, non-overlapping things
# (an ipBlock can't reliably match a Service's DNAT'd traffic; see that
# function's own header).
render_proxy_egress_rules() {
    if [[ ${#PROXY_ALLOW_CIDRS[@]} -eq 0 ]]; then
        cat <<'EOF'
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
              - 100.64.0.0/10
      ports:
        - protocol: TCP
          port: 443
EOF
    else
        local i cidr port
        for (( i = 0; i < ${#PROXY_ALLOW_CIDRS[@]}; i++ )); do
            cidr="${PROXY_ALLOW_CIDRS[$i]}"
            port="${PROXY_ALLOW_PORTS[$i]}"
            cat <<EOF
    - to:
        - ipBlock:
            cidr: $cidr
      ports:
        - protocol: TCP
          port: $port
EOF
        done
    fi
    render_proxy_egress_rules_ns
}

# K8S_PROXY_ALLOW_NS's egress rule(s) -- one namespaceSelector rule per
# <namespace>[:<port>] entry in PROXY_ALLOW_NS_NAMESPACES /
# PROXY_ALLOW_NS_PORTS (parse_proxy_allow_ns). Prints nothing when that
# array is empty, which is what keeps render_proxy_egress_rules's output
# byte-identical to today's whenever K8S_PROXY_ALLOW_NS is unset, regardless
# of whether K8S_PROXY_ALLOW is set. kube-proxy DNATs a ClusterIP to a pod
# IP before egress policy is evaluated on most CNIs, so an ipBlock naming
# the ClusterIP may never match -- a namespaceSelector matches the
# destination pod's own namespace label instead, which survives the DNAT.
# An empty port (see parse_proxy_allow_ns) omits the `ports:` key entirely
# rather than rendering an empty list -- NetworkPolicy treats a rule with no
# `ports:` key as every port and protocol.
render_proxy_egress_rules_ns() {
    local i ns port
    for (( i = 0; i < ${#PROXY_ALLOW_NS_NAMESPACES[@]}; i++ )); do
        ns="${PROXY_ALLOW_NS_NAMESPACES[$i]}"
        port="${PROXY_ALLOW_NS_PORTS[$i]}"
        cat <<EOF
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $ns
EOF
        if [[ -n "$port" ]]; then
            cat <<EOF
      ports:
        - protocol: TCP
          port: $port
EOF
        fi
    done
}

# manifests/k8s/30-proxy.yaml's own __PROXY_EGRESS_RULES__ marker sits on a
# placeholder stanza that is, by itself, valid YAML (`- to: []` / `ports:
# []`) -- unlike __PROXY_LOCATIONS__, this one lives in a real parsed
# NetworkPolicy list, not inside an nginx.conf block scalar, so a bare
# dedented token here is a syntax error rather than harmless block-scalar
# text. This substitutes the WHOLE two-line stanza (matched literally, not
# as a token) for render_proxy_egress_rules's output, which supplies its own
# 4-space list-item indent on every line since nothing in the template
# indents it for us this time. No trailing newline on either side of this
# substitution: $1 already had its own trailing newline stripped by the
# $(sed ...) capture that produced it (this stanza is the file's last
# line), the same convention the untouched original template's last line
# always rendered under -- see cmd_install's own `rendered+="$file_rendered"$'\n'`
# for where that newline comes back.
render_proxy_egress_rules_sub() {
    local text="$1" stanza stripped
    stanza=$'    - to: []  # __PROXY_EGRESS_RULES__\n      ports: []'
    stripped="${text/"$stanza"/$(render_proxy_egress_rules)}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the __PROXY_EGRESS_RULES__ placeholder" >&2
        echo "stanza in the rendered proxy NetworkPolicy --" >&2
        echo "manifests/k8s/30-proxy.yaml and render_proxy_egress_rules_sub" >&2
        echo "in this script have drifted apart." >&2
        return 1
    fi
    printf '%s' "$stripped"
}

# The nginx location block(s) inside the proxy's server {} -- fills
# __PROXY_LOCATIONS__ in manifests/k8s/30-proxy.yaml. Built fully-resolved in
# bash, rather than left as sed tokens for the per-file substitution pass in
# cmd_install to fill in later, because a K8S_PROXY_ENDPOINTS registry can
# name the same base URL more than once under different logical names, and a
# global sed token has only one value per render.
#
# Legacy K8S_PROXY_UPSTREAM (upstream_host given as $1) renders exactly what
# this repo has always rendered here -- byte-for-byte, Authorization header
# included -- to hold the backward-compatibility guarantee: an existing
# install using K8S_PROXY_UPSTREAM must render identically after this
# function existed as after it didn't.
#
# K8S_PROXY_ENDPOINTS (read from the PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS
# arrays parse_proxy_endpoints filled in) renders two EXACT-match locations
# per registered name -- /e/<name>/v1/chat/completions and
# /e/<name>/v1/models -- never a regex or prefix match: N endpoints must
# widen the surface by exactly 2N known paths and nothing else. An endpoint
# is keyless by default -- neither location carries an Authorization header
# -- unless it is named in K8S_PROXY_ENDPOINT_KEYS (is_keyed_endpoint above),
# in which case BOTH of its locations get
# `proxy_set_header Authorization "Bearer $upstream_key_<name>"` -- an
# endpoint whose key is only on the completions path leaves model discovery
# 401ing, which surfaces pod-side as a dead run rather than a config error,
# so both paths matter equally here -- and the same goes for the two
# embeddings locations an opted-in endpoint (is_embeddings_endpoint) adds.
# See cmd_install's Secret/include
# handling for the other half of that. Preserves the same
# $upstream variable-in-proxy_pass
# trick and resolver the legacy block uses (see manifests/k8s/30-proxy.yaml's
# own comment on it) so nginx resolves each endpoint's host at request time
# rather than pinning a DNS answer at startup.
#
# manifests/k8s/30-proxy.yaml's own __PROXY_LOCATIONS__ placeholder line
# carries the block's 12-space indent already, so the raw template stays
# valid YAML block-scalar content before substitution -- a token dedented to
# column 0 ends the block scalar as far as a YAML parser is concerned, even
# though nothing downstream of that indentation actually needs it (the
# rendered, fully-substituted output is valid either way). This wrapper
# strips that same 12-space indent from just the first line of
# render_proxy_locations_body's output, so it isn't doubled up; every other
# line supplies its own indent, since nothing in the template indents them.
render_proxy_locations() {
    local body
    body="$(render_proxy_locations_body "$@")" || return 1
    printf '%s' "${body/#            /}"
}

# The server-level `include /etc/nginx/upstream-key.conf;` block (plus its
# leading comment and the one blank line that follows it), verbatim from
# manifests/k8s/30-proxy.yaml -- kept as a STATIC block in that file, never a
# placeholder token, specifically so the legacy K8S_PROXY_UPSTREAM path needs
# no substitution machinery here at all and its bytes cannot drift. A
# K8S_PROXY_ENDPOINTS install with no K8S_PROXY_ENDPOINT_KEYS entries strips
# this exact block out of the rendered text instead (see
# strip_proxy_key_include below): a keyless registry must create no Secret
# and include no such file -- see cmd_install's own Secret-creation guard
# for the other half of that. An endpoints install with at least one keyed
# endpoint keeps this block, same as the legacy path -- both need
# $upstream_key* defined from the mounted Secret.
proxy_key_include_block() {
    local block
    # $() strips ALL trailing newlines, not just one, so the heredoc's own
    # trailing newline cannot be relied on to produce the block's trailing
    # blank line. A trailing sentinel (X) protects the two newlines this
    # prints from being stripped a SECOND time by strip_proxy_key_include's
    # own $(proxy_key_include_block) capture -- the sentinel is removed there
    # with a parameter expansion, which does not touch trailing whitespace.
    block="$(cat <<'BLOCK'
            # Defines $upstream_key. Mounted from the Secret, never from this
            # ConfigMap -- see the header above.
            #
            # This include sits in `server`, NOT in `http`, and that is
            # load-bearing: the file it pulls in is a `set` directive, and
            # nginx allows `set` only in server, location and if. At http
            # level nginx refuses to start with
            #   "set" directive is not allowed here
            # which crashloops the proxy. Measured against a live cluster.
            include /etc/nginx/upstream-key.conf;
BLOCK
)"
    printf '%s\n\nX' "$block"
}

# Removes proxy_key_include_block's exact text (plus the one blank line that
# follows it in the template) from $1, for a K8S_PROXY_ENDPOINTS
# (keyless) render. Errors out rather than silently no-op'ing if the block
# is not found -- a mismatch here means manifests/k8s/30-proxy.yaml's static
# text and this function's copy of it have drifted apart, and applying a
# keyless render that still includes upstream-key.conf would be a Secret
# dependency this mode promises never to have.
strip_proxy_key_include() {
    local text="$1" block stripped
    block="$(proxy_key_include_block)"
    block="${block%X}"
    stripped="${text/"$block"/}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the upstream-key include block in the" >&2
        echo "rendered proxy ConfigMap -- manifests/k8s/30-proxy.yaml and" >&2
        echo "proxy_key_include_block in this script have drifted apart." >&2
        return 1
    fi
    printf '%s' "$stripped"
}

# Removes the Deployment's upstream-key volumeMount and volume stanzas
# (verbatim from manifests/k8s/30-proxy.yaml) from $1, for a
# K8S_PROXY_ENDPOINTS (keyless) render. Companion to strip_proxy_key_include
# above: that one keeps nginx from trying to include a file that was never
# mounted, this one keeps the Pod spec from referencing a Secret that
# cmd_install never creates on this path (see its own Secret-creation guard).
# Without this, kubelet refuses to start the pod at all --
# "MountVolume.SetUp failed ... secret \"fork-sandbox-upstream-key\" not
# found" -- which is a worse failure than the ConfigMap-only half of this
# fix: the proxy never reaches Ready, so a keyless install never comes up.
# Both stanzas sit between list items with no surrounding blank line, unlike
# proxy_key_include_block's ConfigMap text, so a plain literal substitution
# is enough here -- no blank-line bookkeeping needed.
strip_proxy_key_volume() {
    local text="$1" mount_block volume_block stripped
    mount_block=$'            - name: upstream-key\n              mountPath: /etc/nginx/upstream-key.conf\n              subPath: upstream-key.conf\n              readOnly: true\n'
    volume_block=$'        - name: upstream-key\n          secret:\n            secretName: fork-sandbox-upstream-key\n'

    stripped="${text/"$mount_block"/}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the upstream-key volumeMount in the" >&2
        echo "rendered proxy Deployment -- manifests/k8s/30-proxy.yaml and" >&2
        echo "strip_proxy_key_volume in this script have drifted apart." >&2
        return 1
    fi
    text="$stripped"

    stripped="${text/"$volume_block"/}"
    if [[ "$stripped" == "$text" ]]; then
        echo "Error: could not find the upstream-key volume in the rendered" >&2
        echo "proxy Deployment -- manifests/k8s/30-proxy.yaml and" >&2
        echo "strip_proxy_key_volume in this script have drifted apart." >&2
        return 1
    fi
    printf '%s' "$stripped"
}

# Removes one of the postmaster Deployment's marker-fenced optional blocks
# (manifests/k8s/40-postmaster.yaml's "# >>> $tag" / "# <<< $tag" comment
# pairs -- personas/prompts/handlers/hooks/presets, each fencing an env entry, a
# volumeMount entry and a volume entry, three tags per name) from $1, for
# `install --postmaster` when that name's laptop config dir does not
# exist -- the pod must see the same "absent dir means absent" semantics
# the postmaster itself already applies locally. sed's range-delete finds
# the pair by the marker text alone, regardless of indentation (yamllint's
# comments-indentation rule requires each marker's own indentation to
# match, which is a per-manifest-edit concern, not this function's).
# Errors out, rather than silently no-op'ing, if a marker pair is not
# found -- same drift-detection discipline as strip_proxy_key_volume
# above: manifests/k8s/40-postmaster.yaml and this function's tags must
# never quietly disagree.
strip_pm_optional_block() {
    local text="$1" tag="$2" out
    out="$(printf '%s' "$text" | sed "/# >>> ${tag}\$/,/# <<< ${tag}\$/d")"
    if [[ "$out" == "$text" ]]; then
        echo "Error: could not find the '$tag' block in the rendered" >&2
        echo "postmaster Deployment -- manifests/k8s/40-postmaster.yaml" >&2
        echo "and cmd_install have drifted apart." >&2
        return 1
    fi
    printf '%s' "$out"
}

# Fills the module-global PM_CONFIGMAP_FILE_ARGS (one --from-file=key=path
# per file, for kubectl create configmap) and PM_CONFIGMAP_FILE_PATHS (the
# bare paths, for the 900 KiB total-size guard in cmd_install) from every
# regular top-level file in $1 -- never recursing, since a ConfigMap
# volume cannot hold subdirectories, so a nested one is refused by name
# rather than silently flattened or dropped. A symlink is refused by name
# too, never followed: kubectl would copy whatever it points at (even
# outside $1) into the ConfigMap, which --dry-run would then print.
# $2 ("true"/"false") requires
# each included file to be executable, for the handlers and hooks dirs: a
# non-executable one is skipped with a warning rather than refused,
# mirroring what the postmaster itself does with a non-executable
# handler or hook (see FLEET/PM's own exec checks). $3 names the dir
# in that warning ("handlers" or "hooks").
pm_collect_configmap_files() {
    local dir="$1" require_exec="$2" what="${3:-handlers}" sub f base
    PM_CONFIGMAP_FILE_ARGS=()
    PM_CONFIGMAP_FILE_PATHS=()
    sub="$(find "$dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [[ -n "$sub" ]]; then
        echo "Error: '$sub' is a subdirectory of $dir -- a ConfigMap can only" >&2
        echo "hold flat files. Remove it or move its content up a level." >&2
        return 1
    fi
    for f in "$dir"/*; do
        if [[ -L "$f" ]]; then
            echo "Error: '$f' is a symlink -- a ConfigMap can only hold" >&2
            echo "regular files copied by value, never a symlink that might" >&2
            echo "point outside $dir. Remove it or replace it with a real" >&2
            echo "file." >&2
            return 1
        fi
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        if [[ "$require_exec" == true && ! -x "$f" ]]; then
            echo "Warning: $f is not executable; skipping it from the $what" >&2
            echo "ConfigMap -- the postmaster itself would skip a" >&2
            echo "non-executable ${what%s} the same way." >&2
            continue
        fi
        PM_CONFIGMAP_FILE_ARGS+=(--from-file="$base=$f")
        PM_CONFIGMAP_FILE_PATHS+=("$f")
    done
    return 0
}

render_proxy_locations_body() {
    local upstream_host="$1"

    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        cat <<EOF
            location = /api/v1/chat/completions {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$K8S_PROXY_UPSTREAM";
                proxy_pass \$upstream/api/v1/chat/completions;

                # A variable in proxy_pass makes nginx resolve at request
                # time through the resolver above, rather than once at
                # startup -- so the upstream's DNS record can rotate
                # without a restart here.
                # proxy_ssl_verify without a trusted certificate is a
                # startup error, not a silent downgrade -- nginx refuses
                # with "no proxy_ssl_trusted_certificate for
                # proxy_ssl_verify". The path is the CA bundle shipped in
                # the nginx alpine image. Measured against a live cluster.
                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$upstream_host";
                proxy_set_header Host "$upstream_host";

                proxy_set_header Authorization "Bearer \$upstream_key";
                proxy_hide_header Authorization;
            }
EOF
        return 0
    fi

    local i name base host nginx_var auth_header
    for (( i = 0; i < ${#PROXY_ENDPOINT_NAMES[@]}; i++ )); do
        name="${PROXY_ENDPOINT_NAMES[$i]}"
        base="${PROXY_ENDPOINT_URLS[$i]}"
        host="${base#*://}"
        host="${host%%/*}"
        # Only a K8S_PROXY_ENDPOINT_KEYS-registered name gets an
        # Authorization header, on BOTH of its locations below -- an empty
        # auth_header leaves the rendered text byte-identical to a keyless
        # endpoint's, which is what keeps the no-K8S_PROXY_ENDPOINT_KEYS
        # case unchanged.
        auth_header=""
        if is_keyed_endpoint "$name"; then
            nginx_var="upstream_key_${name//-/_}"
            printf -v auth_header '\n                proxy_set_header Authorization "Bearer $%s";\n                proxy_hide_header Authorization;' \
                "$nginx_var"
        fi
        (( i > 0 )) && printf '\n'
        cat <<EOF
            location = /e/$name/v1/chat/completions {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$base";
                proxy_pass \$upstream/chat/completions;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";${auth_header}
            }

            location = /e/$name/v1/models {
                limit_req zone=fork_sandbox burst=10 nodelay;

                set \$upstream "$base";
                proxy_pass \$upstream/models;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";${auth_header}
            }
EOF
        is_embeddings_endpoint "$name" || continue
        # The TEI-native route is served at the gateway root, not under /v1;
        # parse_proxy_endpoint_embeddings guarantees $base ends in /v1.
        cat <<EOF

            location = /e/$name/v1/embeddings {
                limit_req zone=fork_sandbox_embed burst=100 nodelay;

                set \$upstream "$base";
                proxy_pass \$upstream/embeddings;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";${auth_header}
            }

            location = /e/$name/embed {
                limit_req zone=fork_sandbox_embed burst=100 nodelay;

                set \$upstream "${base%/v1}";
                proxy_pass \$upstream/embed;

                proxy_ssl_verify on;
                proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                proxy_ssl_verify_depth 3;
                proxy_ssl_server_name on;
                proxy_ssl_name "$host";
                proxy_set_header Host "$host";${auth_header}
            }
EOF
    done
}

# The mail API's shared team token (docs/mail-api.md, "Team access"). Its raw
# value lives in this Secret, key `token`; the server only ever gets its hash.
PM_TEAM_SECRET=fork-sandbox-mail-api-team-token
# Out parameters of pm_plan_team_token: the token's SHA-256, and the manifest
# of the Secret to create (empty when the cluster already has one to keep).
PM_TEAM_HASH=""
PM_TEAM_SECRET_YAML=""

# pm_plan_team_token DRY_RUN ROTATE: decide the team token this install
# serves. An existing Secret is read and kept, whatever its content: install
# never rotates it, since a re-install that did would lock the team out.
# Only ROTATE (or no Secret at all) mints a new one. The Secret itself is
# created later, at apply time, once the namespace exists; here the cluster
# is only read, and not at all on a --dry-run (a placeholder hash stands in).
# The raw token passes through a shell variable and printf, never argv.
pm_plan_team_token() {
    local dry="$1" rotate="$2" found="" mint_out="" token="" stored=""
    PM_TEAM_HASH=""
    PM_TEAM_SECRET_YAML=""
    if [[ "$dry" == true ]]; then
        PM_TEAM_HASH="$(printf '%064d' 0)"
        return 0
    fi
    if [[ "$rotate" != true ]]; then
        if ! found="$(kubectl get secret "$PM_TEAM_SECRET" --ignore-not-found \
            -o 'jsonpath={.metadata.name} {.data.token}')"; then
            echo "Error: could not read Secret $PM_TEAM_SECRET to see whether the team" >&2
            echo "token exists; refusing to guess." >&2
            return 1
        fi
        if [[ -n "$found" ]]; then
            stored="${found#* }"
            if [[ -z "$stored" || "$found" == "$stored" ]]; then
                echo "Error: Secret $PM_TEAM_SECRET exists but holds no 'token' key." >&2
                echo "Delete it, or run install --postmaster --rotate-team-token." >&2
                return 1
            fi
            PM_TEAM_HASH="$(printf '%s' "$stored" | base64 -d | k8s_sha256_stdin)" || return 1
            return 0
        fi
    fi
    mint_out="$("$script_dir/fork-sandbox-mail-api.py" mint --role operator --label team)" || return 1
    token="${mint_out%%$'\n'*}"
    PM_TEAM_HASH="$(printf '%s' "$token" | k8s_sha256_stdin)" || return 1
    PM_TEAM_SECRET_YAML="$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n  token: "%s"\n' \
        "$PM_TEAM_SECRET" "$K8S_NAMESPACE" "$token")"
}

cmd_install() {
    local dry_run=false postmaster=false rotate_team=false
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --postmaster) postmaster=true; shift ;;
            --rotate-team-token) rotate_team=true; shift ;;
            *) echo "Error: unknown option '$1' for install." >&2; exit 1 ;;
        esac
    done
    if $rotate_team && ! $postmaster; then
        echo "Error: --rotate-team-token goes with install --postmaster." >&2
        exit 1
    fi

    # The quota keys are substituted into a YAML manifest with no quoting
    # of their own, so these anchored shape checks are what keep a value
    # from injecting YAML (a newline, `: `, a quote or a `|` matches none
    # of them). Run first, before anything is rendered or applied. Shape
    # only: whether a limit is big enough is the operator's call.
    local quota_pair quota_key quota_val quota_re quota_what
    for quota_pair in \
        "K8S_QUOTA_PODS|$K8S_QUOTA_PODS" \
        "K8S_QUOTA_REQUESTS_CPU|$K8S_QUOTA_REQUESTS_CPU" \
        "K8S_QUOTA_LIMITS_CPU|$K8S_QUOTA_LIMITS_CPU" \
        "K8S_QUOTA_REQUESTS_MEMORY|$K8S_QUOTA_REQUESTS_MEMORY" \
        "K8S_QUOTA_LIMITS_MEMORY|$K8S_QUOTA_LIMITS_MEMORY"; do
        quota_key="${quota_pair%%|*}"
        quota_val="${quota_pair#*|}"
        case "$quota_key" in
            K8S_QUOTA_PODS)
                quota_re='^[1-9][0-9]*$'
                quota_what="a positive integer" ;;
            *_CPU)
                quota_re='^([0-9]+(\.[0-9]+)?|[0-9]+m)$'
                quota_what="a Kubernetes cpu quantity (4, 0.5 or 500m)" ;;
            *)
                quota_re='^[0-9]+(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$'
                quota_what="an integer with an optional binary or decimal suffix (512Mi, 20Gi, 20G)" ;;
        esac
        if [[ ! "$quota_val" =~ $quota_re ]]; then
            echo "Error: $quota_key in $k8s_env must be $quota_what," >&2
            echo "got '$quota_val'." >&2
            exit 1
        fi
    done

    # --postmaster's own validation, kept visually separate from the
    # proxy's checks below and run first, so "validate before rendering or
    # applying anything" holds for both halves of this command
    # independently. The ssh-URL and project-name regexes are copied
    # verbatim from fork-sandbox-postmaster-pod-init.sh's own "2. config"
    # section -- if you touch one, touch both, so the two validators can
    # never disagree.
    local pm_project="" pm_team_subjects_yaml=""
    if $postmaster; then
        if [[ -z "$K8S_POSTMASTER_IMAGE" ]]; then
            echo "Error: K8S_POSTMASTER_IMAGE is not set in $k8s_env. install" >&2
            echo "--postmaster needs the image ref build-sandbox-image.sh" >&2
            echo "--postmaster built and you pushed. Add a line:" >&2
            echo "  K8S_POSTMASTER_IMAGE=registry.example/you/fork-sandbox-postmaster:abc1234" >&2
            exit 1
        fi
        if [[ -z "$K8S_POSTMASTER_REPO_URL" ]]; then
            echo "Error: K8S_POSTMASTER_REPO_URL is not set in $k8s_env." >&2
            exit 1
        fi
        if [[ "$K8S_POSTMASTER_REPO_URL" =~ ^ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(:[0-9]+)?/[^[:space:]]+$ ]]; then
            :
        elif [[ "$K8S_POSTMASTER_REPO_URL" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^[:space:]]+$ ]]; then
            :
        else
            echo "Error: K8S_POSTMASTER_REPO_URL='$K8S_POSTMASTER_REPO_URL' is not a" >&2
            echo "recognized ssh URL (ssh://host/path, ssh://user@host/path or" >&2
            echo "user@host:path)." >&2
            exit 1
        fi
        pm_project="$K8S_POSTMASTER_PROJECT"
        if [[ -z "$pm_project" ]]; then
            # Mirrors fork-sandbox-postmaster-pod-init.sh's own derivation --
            # touch one, touch both. scp-like URLs have no scheme and no
            # guaranteed "/" (a root-level path like user@host:proj.git has
            # none at all), so strip the "host:" prefix first; the scp-form
            # regex above guarantees the first ":" is that separator, since
            # host chars exclude ":". ssh:// URLs always have a "/" before
            # the path, so "##*/" alone works.
            if [[ "$K8S_POSTMASTER_REPO_URL" == ssh://* ]]; then
                pm_project="${K8S_POSTMASTER_REPO_URL##*/}"
            else
                pm_project="${K8S_POSTMASTER_REPO_URL#*:}"
                pm_project="${pm_project##*/}"
            fi
            pm_project="${pm_project%.git}"
        fi
        if [[ ! "$pm_project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "Error: K8S_POSTMASTER_PROJECT (or the name derived from" >&2
            echo "K8S_POSTMASTER_REPO_URL) '$pm_project' is not a valid directory" >&2
            echo "name. Set K8S_POSTMASTER_PROJECT explicitly." >&2
            exit 1
        fi
        if [[ -z "$K8S_POSTMASTER_GIT_KEY_FILE" ]]; then
            echo "Error: K8S_POSTMASTER_GIT_KEY_FILE is not set in $k8s_env." >&2
            exit 1
        fi
        if [[ -z "$K8S_POSTMASTER_KNOWN_HOSTS_FILE" ]]; then
            echo "Error: K8S_POSTMASTER_KNOWN_HOSTS_FILE is not set in $k8s_env." >&2
            exit 1
        fi
        require_secret_file "$K8S_POSTMASTER_GIT_KEY_FILE" || exit 1
        if [[ -L "$K8S_POSTMASTER_KNOWN_HOSTS_FILE" || ! -f "$K8S_POSTMASTER_KNOWN_HOSTS_FILE" ]]; then
            echo "Error: K8S_POSTMASTER_KNOWN_HOSTS_FILE='$K8S_POSTMASTER_KNOWN_HOSTS_FILE' is" >&2
            echo "not a regular file." >&2
            exit 1
        fi
        if [[ ! -s "$K8S_POSTMASTER_KNOWN_HOSTS_FILE" ]]; then
            echo "Error: K8S_POSTMASTER_KNOWN_HOSTS_FILE='$K8S_POSTMASTER_KNOWN_HOSTS_FILE' is" >&2
            echo "empty. The cluster postmaster trusts no host on first use --" >&2
            echo "populate it (e.g. ssh-keyscan) before install." >&2
            exit 1
        fi
        if [[ ! "$K8S_POSTMASTER_STORAGE" =~ ^[0-9]+(Mi|Gi|Ti)$ ]]; then
            echo "Error: K8S_POSTMASTER_STORAGE='$K8S_POSTMASTER_STORAGE' must match" >&2
            echo '^[0-9]+(Mi|Gi|Ti)$.' >&2
            exit 1
        fi
        if [[ ! "$K8S_POSTMASTER_MAIL_STORAGE" =~ ^[0-9]+(Mi|Gi|Ti)$ ]]; then
            echo "Error: K8S_POSTMASTER_MAIL_STORAGE='$K8S_POSTMASTER_MAIL_STORAGE' must match" >&2
            echo '^[0-9]+(Mi|Gi|Ti)$.' >&2
            exit 1
        fi
        if [[ "$K8S_POSTMASTER_ACCESS_MODE" != ReadWriteOncePod && "$K8S_POSTMASTER_ACCESS_MODE" != ReadWriteOnce ]]; then
            echo "Error: K8S_POSTMASTER_ACCESS_MODE='$K8S_POSTMASTER_ACCESS_MODE' must be" >&2
            echo "ReadWriteOncePod or ReadWriteOnce." >&2
            exit 1
        fi
        if [[ -n "$K8S_POSTMASTER_HOOKS_SECRET" ]]; then
            if (( ${#K8S_POSTMASTER_HOOKS_SECRET} > 253 )) \
                || [[ ! "$K8S_POSTMASTER_HOOKS_SECRET" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
                echo "Error: K8S_POSTMASTER_HOOKS_SECRET='$K8S_POSTMASTER_HOOKS_SECRET' is not a" >&2
                echo "valid Secret name: at most 253 characters matching" >&2
                echo '^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ (a DNS-1123 subdomain).' >&2
                exit 1
            fi
            case "$K8S_POSTMASTER_HOOKS_SECRET" in
                fork-sandbox-upstream-key|fork-sandbox-postmaster-git|fork-sandbox-mail-api-tokens|fork-sandbox-mail-api-team-token)
                    echo "Error: K8S_POSTMASTER_HOOKS_SECRET='$K8S_POSTMASTER_HOOKS_SECRET' is one of" >&2
                    echo "this installer's own Secrets; a hook must never be handed the" >&2
                    echo "provider key, the deploy key or the mail API tokens. Name a" >&2
                    echo "Secret you created for the hooks alone." >&2
                    exit 1
                    ;;
            esac
        fi
        # FORK_SANDBOX_FLEET_FILE / FORK_SANDBOX_PERSONAS_DIR, when the
        # caller's shell sets them, let a site keep its fleet and personas
        # outside $config_dir (its own repo, say) -- resolved once, here,
        # so the presence check below, the fleet-check gate, and the
        # ConfigMaps all agree on the same path. Unset or empty falls back
        # to $config_dir/fleet.yaml and $config_dir/personas, unchanged
        # from before this pair of keys existed. A set value that names
        # nothing is refused by the variable's own name -- the caller set
        # it on purpose, so this is not a silent fallback to $config_dir.
        # $FS_REALPATH resolves any symlink in the path, so a symlinked
        # personas directory is followed, same as $FS_REALPATH is used
        # for every other path in this function.
        local pm_fleet_file="$config_dir/fleet.yaml"
        if [[ -n "${FORK_SANDBOX_FLEET_FILE:-}" ]]; then
            if [[ ! -f "$FORK_SANDBOX_FLEET_FILE" ]]; then
                echo "Error: FORK_SANDBOX_FLEET_FILE='$FORK_SANDBOX_FLEET_FILE' is not a" >&2
                echo "regular file." >&2
                exit 1
            fi
            pm_fleet_file="$("$FS_REALPATH" -- "$FORK_SANDBOX_FLEET_FILE")"
        fi
        local pm_personas_dir="$config_dir/personas"
        if [[ -n "${FORK_SANDBOX_PERSONAS_DIR:-}" ]]; then
            if [[ ! -d "$FORK_SANDBOX_PERSONAS_DIR" ]]; then
                echo "Error: FORK_SANDBOX_PERSONAS_DIR='$FORK_SANDBOX_PERSONAS_DIR' is not a" >&2
                echo "directory." >&2
                exit 1
            fi
            pm_personas_dir="$("$FS_REALPATH" -- "$FORK_SANDBOX_PERSONAS_DIR")"
        fi
        echo "fork-sandbox-k8s: shipping fleet file $pm_fleet_file" >&2
        echo "fork-sandbox-k8s: shipping personas dir $pm_personas_dir" >&2
        # deliver --cluster refuses to start at all with no fleet file
        # (pm_require_fleet_check: "--cluster needs a fleet file ...
        # declaring backend: k8s seats"), so an install with no
        # fleet.yaml renders and applies a Deployment whose pod
        # crash-loops forever. Catch that here, before anything is
        # rendered or applied, instead of leaving it for `kubectl logs`
        # to discover after the fact.
        if [[ ! -f "$pm_fleet_file" ]]; then
            echo "Error: no fleet file at $pm_fleet_file. install" >&2
            echo "--postmaster needs one: the cluster postmaster's 'deliver" >&2
            echo "--cluster' refuses to start without a fleet file declaring" >&2
            echo "backend: k8s seats." >&2
            exit 1
        fi
        # The check the pod runs at startup, against the fleet file and
        # personas dir this install will ship (resolved above), and the
        # handlers/presets dirs pinned to $config_dir rather than whatever
        # FORK_SANDBOX_*_DIR the caller's shell exports otherwise: it must
        # see what the pod will see. FORK_SANDBOX_CLUSTER_CLAUDE mirrors the
        # env var the manifest sets on the postmaster container (below) when
        # a claude credential is being shipped, so this gate and the pod's
        # own `deliver --cluster` startup check agree on whether claude
        # seats are accepted.
        local -a pm_fleet_env=(
            FORK_SANDBOX_FLEET_FILE="$pm_fleet_file"
            FORK_SANDBOX_PERSONAS_DIR="$pm_personas_dir"
            FORK_SANDBOX_HANDLERS_DIR="$config_dir/handlers"
            FORK_SANDBOX_PRESETS_DIR="$config_dir/presets"
        )
        if [[ -n "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]]; then
            pm_fleet_env+=(FORK_SANDBOX_CLUSTER_CLAUDE=1)
        fi
        if ! env "${pm_fleet_env[@]}" "$script_dir/fork-sandbox-fleet.sh" check --cluster; then
            echo "Error: the cluster postmaster would crash-loop on this fleet" >&2
            echo "($pm_fleet_file): 'deliver --cluster' runs the same" >&2
            echo "check at startup. Fix the errors above and re-run install." >&2
            exit 1
        fi
        # Same parse as the postmaster's own $FORK_SANDBOX_OPERATORS: comma
        # separated, no spaces, each an @name, no empty element (the
        # appended comma makes a trailing one visible).
        local pm_op_el pm_op_re='^@[a-z0-9][a-z0-9-]*$'
        local -a pm_op_parts
        IFS=',' read -ra pm_op_parts <<< "$K8S_POSTMASTER_OPERATORS,"
        for pm_op_el in "${pm_op_parts[@]}"; do
            if [[ ! "$pm_op_el" =~ $pm_op_re ]]; then
                echo "Error: K8S_POSTMASTER_OPERATORS element '$pm_op_el' is not an @name" >&2
                echo "(comma-separated, no spaces, no empty elements, each matching" >&2
                echo "$pm_op_re)." >&2
                exit 1
            fi
            if env "${pm_fleet_env[@]}" "$script_dir/fork-sandbox-fleet.sh" \
                resolve "${pm_op_el#@}" >/dev/null 2>&1; then
                echo "Error: K8S_POSTMASTER_OPERATORS names '$pm_op_el', which is a fleet" >&2
                echo "agent; an operator name must not be a fleet agent." >&2
                exit 1
            fi
        done
        if [[ -n "$K8S_MAIL_API_TOKENS_FILE" ]]; then
            require_secret_file "$K8S_MAIL_API_TOKENS_FILE" || exit 1
            local pm_tokens_out=""
            if ! pm_tokens_out="$(FORK_SANDBOX_OPERATORS="$K8S_POSTMASTER_OPERATORS" \
                "$script_dir/fork-sandbox-mail-api.py" check \
                --tokens "$K8S_MAIL_API_TOKENS_FILE" \
                --team-hash "$(printf '%064d' 0)" 2>&1)"; then
                echo "Error: K8S_MAIL_API_TOKENS_FILE='$K8S_MAIL_API_TOKENS_FILE' failed" >&2
                echo "fork-sandbox-mail-api.py check:" >&2
                printf '%s\n' "$pm_tokens_out" >&2
                exit 1
            fi
        fi
        # K8S_MAIL_TEAM_SUBJECTS: user:<name> / group:<name>, comma
        # separated like the operator list. The names go into the
        # RoleBinding inside double quotes with no escaping, so the
        # character class is what keeps a value from injecting YAML.
        # Validated whether or not the API is deployed, so a typo surfaces
        # the first time it is written, not the day the API is switched on.
        if [[ -n "$K8S_MAIL_TEAM_SUBJECTS" ]]; then
            local pm_ts_el pm_ts_kind pm_ts_name pm_ts_k
            local pm_ts_re='^[A-Za-z0-9][A-Za-z0-9._:@/+=-]*$'
            local -a pm_ts_parts
            IFS=',' read -ra pm_ts_parts <<< "$K8S_MAIL_TEAM_SUBJECTS,"
            for pm_ts_el in "${pm_ts_parts[@]}"; do
                pm_ts_kind="${pm_ts_el%%:*}"
                pm_ts_name="${pm_ts_el#*:}"
                pm_ts_k=""
                if [[ "$pm_ts_el" == *:* ]]; then
                    case "$pm_ts_kind" in
                        user) pm_ts_k=User ;;
                        group) pm_ts_k=Group ;;
                    esac
                fi
                if [[ -z "$pm_ts_k" || ${#pm_ts_name} -gt 253 || ! "$pm_ts_name" =~ $pm_ts_re ]]; then
                    echo "Error: K8S_MAIL_TEAM_SUBJECTS element '$pm_ts_el' is not user:<name> or" >&2
                    echo "group:<name> (comma-separated, no spaces, no empty elements; a name" >&2
                    echo "starts with a letter or digit and holds only [A-Za-z0-9._:@/+=-])." >&2
                    exit 1
                fi
                pm_team_subjects_yaml+="  - kind: $pm_ts_k"$'\n'"    name: \"$pm_ts_name\""$'\n'"    apiGroup: rbac.authorization.k8s.io"$'\n'
            done
        fi
        # K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE, when set, ships a
        # long-lived claude OAuth token into the cluster postmaster (see
        # docs/cluster-postmaster.md, "Claude seats in a cluster postmaster").
        # The token is never captured into a shell variable here -- every
        # check below is a boolean jq -e test against the file directly --
        # so there is nothing to accidentally echo. expiresAt is not
        # secret, so it alone is read out, to compute the 7-day floor.
        if [[ -n "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]]; then
            require_secret_file "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" || exit 1
            if ! jq -e '(.claudeAiOauth.accessToken | type == "string" and length > 0)' \
                "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" >/dev/null 2>&1; then
                echo "Error: K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=" >&2
                echo "'$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE' has no non-empty" >&2
                echo ".claudeAiOauth.accessToken." >&2
                exit 1
            fi
            if ! jq -e '(.claudeAiOauth.expiresAt | type == "number")' \
                "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" >/dev/null 2>&1; then
                echo "Error: K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=" >&2
                echo "'$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE' has no numeric" >&2
                echo ".claudeAiOauth.expiresAt." >&2
                exit 1
            fi
            local pm_claude_expires_at_ms pm_claude_min_expiry_ms
            pm_claude_expires_at_ms="$(jq -r '.claudeAiOauth.expiresAt | floor' \
                "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE")"
            pm_claude_min_expiry_ms=$(( ($(date +%s) + 7 * 86400) * 1000 ))
            if (( pm_claude_expires_at_ms < pm_claude_min_expiry_ms )); then
                echo "Error: the access token in K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" >&2
                echo "expires too soon for a cluster that never refreshes it -- the" >&2
                echo "postmaster pod loads it once at start and holds it for every" >&2
                echo "claude seat until this file is replaced and install is rerun." >&2
                echo "Mint a long-lived one with 'claude setup-token'; see" >&2
                echo "docs/cluster-postmaster.md, 'Claude seats in a cluster postmaster'." >&2
                exit 1
            fi
        fi
        # The postmaster image ships no platform plugin beyond generic and
        # the Deployment sets no FORK_SANDBOX_K8S_PLATFORM, so a seat
        # submitted from inside the pod always resolves the generic
        # plugin, regardless of what this install itself is running with.
        # Warn rather than refuse: some sites may intend the pod to use
        # generic even when the laptop runs something else.
        if [[ -n "${FORK_SANDBOX_K8S_PLATFORM:-}" && "$FORK_SANDBOX_K8S_PLATFORM" != generic ]]; then
            echo "Warning: FORK_SANDBOX_K8S_PLATFORM='$FORK_SANDBOX_K8S_PLATFORM' is set," >&2
            echo "but the cluster postmaster pod always uses the generic platform" >&2
            echo "plugin (it ships no other plugin binary and the Deployment sets no" >&2
            echo "such variable). Seats submitted from inside the pod will use" >&2
            echo "generic even though this install is running under" >&2
            echo "'$FORK_SANDBOX_K8S_PLATFORM'." >&2
        fi
    fi

    # ConfigMap file collection for --postmaster: the four optional
    # integrations (personas/prompts/handlers/hooks/presets), each included only
    # when its laptop config dir exists, plus the always-present
    # k8s.env/fleet.yaml config. Done here, still before any render or
    # apply, so the 900 KiB total-size guard and the subdirectory refusal
    # both fail loudly before a single kubectl call.
    local -a pm_config_paths=() pm_config_args=()
    local -a pm_personas_args=() pm_prompts_args=() pm_handlers_args=() pm_hooks_args=() pm_presets_args=()
    local -a pm_personas_paths=() pm_prompts_paths=() pm_handlers_paths=() pm_hooks_paths=() pm_presets_paths=()
    local pm_have_personas=false pm_have_prompts=false pm_have_handlers=false pm_have_hooks=false pm_have_presets=false
    if $postmaster; then
        pm_config_args=(--from-file="k8s.env=$k8s_env")
        pm_config_paths=("$k8s_env")
        if [[ -f "$pm_fleet_file" ]]; then
            pm_config_args+=(--from-file="fleet.yaml=$pm_fleet_file")
            pm_config_paths+=("$pm_fleet_file")
        fi
        # The operator's own $config_dir/claude.env, if any, is never
        # shipped -- it names laptop paths. This one line is the pod's
        # own, pointing at the mount the claude Secret (below) lands on.
        if [[ -n "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]]; then
            # A global, not a local, and :- in the trap: the apply path
            # returns from cmd_install, so a local is out of scope when the
            # EXIT trap fires, and set -u aborts the trap with exit 1.
            K8S_INSTALL_CLAUDE_ENV="$(mktemp)"
            trap 'rm -f -- "${K8S_INSTALL_CLAUDE_ENV:-}"' EXIT
            printf 'CLAUDE_CREDENTIALS=/etc/fork-sandbox/claude/credentials.json\n' \
                > "$K8S_INSTALL_CLAUDE_ENV"
            pm_config_args+=(--from-file="claude.env=$K8S_INSTALL_CLAUDE_ENV")
            pm_config_paths+=("$K8S_INSTALL_CLAUDE_ENV")
        fi

        if [[ -d "$pm_personas_dir" ]]; then
            pm_have_personas=true
            pm_collect_configmap_files "$pm_personas_dir" false || exit 1
            pm_personas_args=("${PM_CONFIGMAP_FILE_ARGS[@]}")
            pm_personas_paths=("${PM_CONFIGMAP_FILE_PATHS[@]}")
        fi
        if [[ -d "$config_dir/prompts" ]]; then
            pm_have_prompts=true
            pm_collect_configmap_files "$config_dir/prompts" false || exit 1
            pm_prompts_args=("${PM_CONFIGMAP_FILE_ARGS[@]}")
            pm_prompts_paths=("${PM_CONFIGMAP_FILE_PATHS[@]}")
        fi
        if [[ -d "$config_dir/handlers" ]]; then
            pm_have_handlers=true
            pm_collect_configmap_files "$config_dir/handlers" true handlers || exit 1
            pm_handlers_args=("${PM_CONFIGMAP_FILE_ARGS[@]}")
            pm_handlers_paths=("${PM_CONFIGMAP_FILE_PATHS[@]}")
        fi
        if [[ -d "$config_dir/hooks" ]]; then
            pm_have_hooks=true
            pm_collect_configmap_files "$config_dir/hooks" true hooks || exit 1
            pm_hooks_args=("${PM_CONFIGMAP_FILE_ARGS[@]}")
            pm_hooks_paths=("${PM_CONFIGMAP_FILE_PATHS[@]}")
        fi
        if [[ -d "$config_dir/presets" ]]; then
            pm_have_presets=true
            pm_collect_configmap_files "$config_dir/presets" false || exit 1
            pm_presets_args=("${PM_CONFIGMAP_FILE_ARGS[@]}")
            pm_presets_paths=("${PM_CONFIGMAP_FILE_PATHS[@]}")
        fi

        local pm_total=0 pm_biggest_file="" pm_biggest_bytes=0 pm_path pm_bytes
        for pm_path in "${pm_config_paths[@]}" "${pm_personas_paths[@]}" \
            "${pm_prompts_paths[@]}" "${pm_handlers_paths[@]}" \
            "${pm_hooks_paths[@]}" "${pm_presets_paths[@]}"; do
            pm_bytes="$("$FS_STAT" -c '%s' -- "$pm_path")"
            pm_total=$(( pm_total + pm_bytes ))
            if (( pm_bytes > pm_biggest_bytes )); then
                pm_biggest_bytes=$pm_bytes
                pm_biggest_file="$pm_path"
            fi
        done
        if (( pm_total > 900 * 1024 )); then
            echo "Error: the postmaster ConfigMaps would total $pm_total bytes," >&2
            echo "over the 900 KiB guard (a Kubernetes object is capped at 1 MiB)." >&2
            echo "The biggest file is $pm_biggest_file ($pm_biggest_bytes bytes)." >&2
            exit 1
        fi
    fi

    if [[ -n "$K8S_PROXY_UPSTREAM" && -n "$K8S_PROXY_ENDPOINTS" ]]; then
        echo "Error: K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS are mutually" >&2
        echo "exclusive -- set one or the other, never both. K8S_PROXY_UPSTREAM" >&2
        echo "is the legacy single API-keyed upstream; K8S_PROXY_ENDPOINTS" >&2
        echo "registers one or more named, keyless endpoints instead." >&2
        exit 1
    fi
    if [[ -z "$K8S_PROXY_UPSTREAM" && -z "$K8S_PROXY_ENDPOINTS" ]]; then
        echo "Error: neither K8S_PROXY_UPSTREAM nor K8S_PROXY_ENDPOINTS is set" >&2
        echo "in $k8s_env. Add one of:" >&2
        echo "  K8S_PROXY_UPSTREAM=https://openrouter.ai" >&2
        echo "  K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1" >&2
        exit 1
    fi

    local upstream_host=""
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        upstream_host="$(validate_upstream_url "$K8S_PROXY_UPSTREAM" K8S_PROXY_UPSTREAM)" || exit 1
        # validate_upstream_url only inspects scheme and host; the full raw
        # value (path included) is what render_proxy_locations_body renders
        # into `set $upstream "...";` on the legacy path, so it needs
        # reject_nginx_unsafe_chars too (see that function's own header).
        reject_nginx_unsafe_chars "$K8S_PROXY_UPSTREAM" K8S_PROXY_UPSTREAM || exit 1
    fi

    # Fills the module-global PROXY_ENDPOINT_NAMES / PROXY_ENDPOINT_URLS
    # arrays render_proxy_locations reads below. Validated here, before
    # anything is rendered or applied, same as every other check in this
    # function.
    parse_proxy_endpoints "$K8S_PROXY_ENDPOINTS" || exit 1

    # Fills the module-global KEYED_ENDPOINT_NAMES / KEYED_ENDPOINT_VARS
    # arrays render_proxy_locations (is_keyed_endpoint) and the Secret
    # creation below both read. Cross-checking each keyed name against the
    # registry parse_proxy_endpoints just filled happens here, not inside
    # the parser itself, so the error can name both halves at once.
    parse_proxy_endpoint_keys "$K8S_PROXY_ENDPOINT_KEYS" || exit 1
    local key_i key_name key_found key_known
    for (( key_i = 0; key_i < ${#KEYED_ENDPOINT_NAMES[@]}; key_i++ )); do
        key_name="${KEYED_ENDPOINT_NAMES[$key_i]}"
        key_found=false
        for key_known in "${PROXY_ENDPOINT_NAMES[@]}"; do
            if [[ "$key_known" == "$key_name" ]]; then
                key_found=true
                break
            fi
        done
        if ! $key_found; then
            echo "Error: K8S_PROXY_ENDPOINT_KEYS names endpoint '$key_name'," >&2
            echo "keyed by ${KEYED_ENDPOINT_VARS[$key_i]}, but '$key_name' is not" >&2
            echo "registered in K8S_PROXY_ENDPOINTS." >&2
            exit 1
        fi
    done

    # Fills EMBED_ENDPOINT_NAMES, which render_proxy_locations reads.
    parse_proxy_endpoint_embeddings "$K8S_PROXY_ENDPOINT_EMBEDDINGS" || exit 1

    # Fills the module-global PROXY_ALLOW_CIDRS / PROXY_ALLOW_PORTS arrays
    # render_proxy_egress_rules reads below. K8S_PROXY_ALLOW is independent
    # of which upstream mode is active -- nothing here requires
    # K8S_PROXY_ENDPOINTS, since a legacy install could in principle want an
    # explicit allowlist too.
    parse_proxy_allow "$K8S_PROXY_ALLOW" || exit 1

    # Fills the module-global PROXY_ALLOW_NS_NAMESPACES / PROXY_ALLOW_NS_PORTS
    # arrays render_proxy_egress_rules_ns reads below. Composes with
    # K8S_PROXY_ALLOW rather than replacing it -- see that function's own
    # header for why an ipBlock alone cannot reliably reach an in-cluster
    # Service.
    parse_proxy_allow_ns "$K8S_PROXY_ALLOW_NS" || exit 1

    # Every URL this install's proxy will dial -- the legacy
    # K8S_PROXY_UPSTREAM (if set) plus each K8S_PROXY_ENDPOINTS entry --
    # checked below against whichever egress policy this same install is
    # about to apply, so a config that can never reach one of its own
    # upstreams gets a warning instead of a silent, always-timing-out
    # install.
    local -a warn_labels=() warn_urls=()
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        warn_labels+=("K8S_PROXY_UPSTREAM")
        warn_urls+=("$K8S_PROXY_UPSTREAM")
    fi
    local i
    for (( i = 0; i < ${#PROXY_ENDPOINT_URLS[@]}; i++ )); do
        warn_labels+=("K8S_PROXY_ENDPOINTS entry '${PROXY_ENDPOINT_NAMES[$i]}'")
        warn_urls+=("${PROXY_ENDPOINT_URLS[$i]}")
    done

    # A Service DNS name (host ending in .svc.$K8S_CLUSTER_DOMAIN) is
    # reachable only through the namespaceSelector rule K8S_PROXY_ALLOW_NS
    # renders (render_proxy_egress_rules_ns) -- never through
    # K8S_PROXY_ALLOW or the default ipBlock policy the two checks below
    # judge, which cannot reliably reach a ClusterIP at all
    # (parse_proxy_allow_ns's own header explains why). Judged here
    # instead, against PROXY_ALLOW_NS_NAMESPACES/PORTS, and marked in
    # is_svc_url so neither check below re-judges it by a policy that was
    # never going to carry it -- otherwise every Service-mode endpoint,
    # correctly covered by K8S_PROXY_ALLOW_NS or not, gets the wrong
    # warning below (or the right warning for the wrong reason).
    local -a is_svc_url=()
    local url host host_only svc_ns port covered j
    local port_carried_public port_carried_reason public_allow_cidr
    for (( i = 0; i < ${#warn_urls[@]}; i++ )); do
        is_svc_url[i]=false
        url="${warn_urls[$i]}"
        host="${url#*://}"
        host="${host%%/*}"
        host_only="${host%:*}"
        [[ "$host_only" == *".svc.$K8S_CLUSTER_DOMAIN" ]] || continue
        is_svc_url[i]=true
        svc_ns="${host_only#*.}"
        svc_ns="${svc_ns%%.*}"
        port="${host#*:}"
        [[ "$port" == "$host" ]] && port=""
        if [[ -n "$port" ]]; then
            # Forced base 10 (10#$port): this port comes straight out of
            # the endpoint's URL and, unlike PROXY_ALLOW_NS_PORTS (already
            # normalized by parse_proxy_allow_ns), has never been
            # validated -- plain arithmetic on an unforced leading-zero
            # value hands bash a C-style integer literal (see
            # validate_upstream_url's own header for the same trap). This
            # branch also reports an out-of-range port by name instead of
            # just forcing the base, since a .svc. URL's port is otherwise
            # unvalidated anywhere upstream; the plain-IPv4-literal path
            # below forces base 10 the same way but doesn't re-report range
            # itself -- an unforced leading zero there would still misfire
            # the same way, so it forces base 10 too, just silently.
            if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] \
                || (( 10#$port < 1 || 10#$port > 65535 )); then
                echo "Error: ${warn_labels[$i]} has an invalid port" >&2
                echo "'$port' -- must be 1-65535." >&2
                exit 1
            fi
            port=$(( 10#$port ))
        else
            if [[ "$url" == https://* ]]; then port=443; else port=80; fi
        fi

        # Whether the egress policy this install is about to render
        # carries this endpoint's port to ANY address, and separately
        # whether it carries that port to a non-private address --
        # computed once here and read by both the NS-coverage warning
        # below and the cleartext warning after this loop, so the two
        # never disagree about the same endpoint's config. A .svc. http://
        # endpoint CAN still reach this point with port 443 when
        # K8S_PROXY_ALLOW is set: validate_upstream_url's 1a only refuses
        # that unconditionally when K8S_PROXY_ALLOW is unset, and defers
        # to this review otherwise (see that function's own header). The
        # "WILL go through" warning below must fire only when the carrying
        # match is itself non-private (port_carried_public) -- a
        # K8S_PROXY_ALLOW entry that only opens a private CIDR (e.g.
        # 172.16.0.0/12) carries the port, but a CNAME resolving off-cluster
        # to a public host still hits no matching ipBlock and is dropped,
        # same as if nothing had matched at all.
        port_carried_public=false
        port_carried_reason=""
        public_allow_cidr=""
        if [[ ${#PROXY_ALLOW_CIDRS[@]} -eq 0 ]]; then
            if (( port == 443 )); then
                port_carried_public=true
                port_carried_reason="the default egress policy carries"
                port_carried_reason+=" any address on port 443"
            fi
        else
            for (( j = 0; j < ${#PROXY_ALLOW_CIDRS[@]}; j++ )); do
                if (( port == PROXY_ALLOW_PORTS[j] )); then
                    if ! cidr_is_private "${PROXY_ALLOW_CIDRS[$j]}"; then
                        public_allow_cidr="${PROXY_ALLOW_CIDRS[$j]}"
                        port_carried_public=true
                        port_carried_reason="K8S_PROXY_ALLOW entry"
                        port_carried_reason+=" ${PROXY_ALLOW_CIDRS[$j]}:$port carries"
                        port_carried_reason+=" port $port to ${PROXY_ALLOW_CIDRS[$j]}"
                    fi
                fi
            done
        fi

        covered=false
        for (( j = 0; j < ${#PROXY_ALLOW_NS_NAMESPACES[@]}; j++ )); do
            if [[ "${PROXY_ALLOW_NS_NAMESPACES[$j]}" == "$svc_ns" ]] \
                && { [[ -z "${PROXY_ALLOW_NS_PORTS[$j]}" ]] || (( port == PROXY_ALLOW_NS_PORTS[j] )); }; then
                covered=true
                break
            fi
        done
        if ! $covered; then
            if $port_carried_public; then
                echo "Warning: ${warn_labels[$i]} names an in-cluster Service in" >&2
                echo "namespace '$svc_ns' on port $port, which no K8S_PROXY_ALLOW_NS" >&2
                echo "entry covers -- a normal in-cluster Service on this port would" >&2
                echo "be dropped, but $port_carried_reason, so if this Service name" >&2
                echo "ever resolves off-cluster (an ExternalName CNAME) requests to" >&2
                echo "it WILL go through. Add $svc_ns:$port to K8S_PROXY_ALLOW_NS if" >&2
                echo "this is meant to stay a normal in-cluster Service." >&2
            else
                echo "Warning: ${warn_labels[$i]} names an in-cluster Service in" >&2
                echo "namespace '$svc_ns' on port $port, which no K8S_PROXY_ALLOW_NS" >&2
                echo "entry covers -- every request to it will be dropped. Add" >&2
                echo "$svc_ns:$port to K8S_PROXY_ALLOW_NS to fix that." >&2
            fi
        fi
        # A separate, physically distinct path from the ClusterIP path
        # $covered judges above: this is the CNAME-to-public-address case
        # validate_upstream_url's 1b defers here (it needs
        # PROXY_ALLOW_CIDRS/PORTS, not populated yet at validation time).
        # Not nested inside `if ! $covered`, since a Service can be both
        # NS-covered for its normal in-cluster address AND have its port
        # opened to a public CIDR -- the two are unrelated egress paths to
        # the same name.
        if [[ "$url" == http://* && -n "$public_allow_cidr" ]]; then
            echo "Warning: ${warn_labels[$i]} uses http:// to an in-cluster" >&2
            echo "Service name on port $port, and K8S_PROXY_ALLOW entry" >&2
            echo "$public_allow_cidr:$port opens that port to a non-private" >&2
            echo "address -- if this Service name ever CNAMEs off-cluster, its" >&2
            echo "Authorization header would leave the cluster in cleartext." >&2
        fi
    done

    if [[ ${#PROXY_ALLOW_CIDRS[@]} -eq 0 ]]; then
        # A warn_urls entry on http:// is, by validate_upstream_url's own
        # rule, always a private (RFC1918/loopback/link-local) address --
        # and the default egress policy (unset K8S_PROXY_ALLOW) excepts
        # exactly those ranges. So this specific combination is not just
        # probably unreachable, it is deterministically unreachable under
        # the policy this same install is about to apply -- worth a
        # warning, even though K8S_PROXY_ALLOW stays a separate,
        # unvalidated knob (see above): a renderer has no business
        # refusing a config it cannot know is actually wrong (an https://
        # endpoint on a non-443 port has the same problem but isn't
        # checkable without parsing every port out of every URL).
        for (( i = 0; i < ${#warn_urls[@]}; i++ )); do
            ${is_svc_url[$i]} && continue
            if [[ "${warn_urls[$i]}" == http://* ]]; then
                echo "Warning: ${warn_labels[$i]} uses http://, which is only" >&2
                echo "ever accepted to a private address -- but K8S_PROXY_ALLOW is" >&2
                echo "unset, so the proxy's default egress policy (any host except" >&2
                echo "RFC1918/loopback/link-local/CGNAT, on 443) excepts exactly that" >&2
                echo "address. Every request to it will be dropped. Set" >&2
                echo "K8S_PROXY_ALLOW=<cidr>:<port> for this endpoint to fix that." >&2
            fi
        done
    else
        # A set K8S_PROXY_ALLOW REPLACES the default egress rule wholesale
        # (render_proxy_egress_rules's own header) rather than extending
        # it, so an endpoint the allowlist doesn't literally cover is just
        # as unreachable as the default-policy case above -- checkable for
        # any endpoint whose host is a literal IPv4 address (a hostname
        # can't be checked without DNS, the same caveat
        # validate_upstream_url documents).
        local url host host_only port covered j
        for (( i = 0; i < ${#warn_urls[@]}; i++ )); do
            url="${warn_urls[$i]}"
            host="${url#*://}"
            host="${host%%/*}"
            [[ "$host" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(:([0-9]+))?$ ]] || continue
            host_only="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[3]}"
            if [[ -z "$port" ]]; then
                if [[ "$url" == https://* ]]; then port=443; else port=80; fi
            else
                # Forced base 10 (10#$port): this port comes straight out
                # of the endpoint's URL and has never been validated --
                # same leading-zero trap validate_upstream_url's own
                # header documents, and the same reason the .svc. branch
                # above forces it before its own (( port == ... ))
                # comparisons.
                port="$(( 10#$port ))"
            fi
            covered=false
            for (( j = 0; j < ${#PROXY_ALLOW_CIDRS[@]}; j++ )); do
                if (( port == PROXY_ALLOW_PORTS[j] )) && cidr_contains "${PROXY_ALLOW_CIDRS[$j]}" "$host_only"; then
                    covered=true
                    break
                fi
            done
            if ! $covered; then
                echo "Warning: ${warn_labels[$i]} resolves to $host_only:$port, which" >&2
                echo "no K8S_PROXY_ALLOW entry covers -- a set K8S_PROXY_ALLOW replaces" >&2
                echo "the default egress rule wholesale rather than extending it, so" >&2
                echo "every request to this endpoint will be dropped. Add" >&2
                echo "$host_only/32:$port to K8S_PROXY_ALLOW to fix that." >&2
            fi
        done
    fi

    # Every credential this install's proxy needs, read from pi.env and
    # validated, before anything is rendered or applied (and ahead of the
    # --dry-run exit below, so --dry-run surfaces the same failure a real
    # install would hit instead of certifying a config that cannot actually
    # apply). A missing or unsafe credential caught only after `kubectl
    # apply -f -` leaves the shared proxy's manifests applied -- including
    # the upstream-key.conf include and Secret volume restored above
    # whenever KEYED_ENDPOINT_NAMES is non-empty -- with no working Secret
    # behind them: exactly the "MountVolume.SetUp failed ... secret not
    # found" state strip_proxy_key_volume's own header says a keyless
    # install must never reach, and on a K8S_PROXY_ENDPOINTS install this
    # can take down a previously-working keyless proxy on a single typo'd
    # K8S_PROXY_ENDPOINT_KEYS variable.
    local api_key=""
    local -a keyed_endpoint_values=() keyed_endpoint_nginx_vars=()
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        require_secret_file "$pi_env" || exit 1
        api_key="$(read_env_value "$pi_env" OPENROUTER_API_KEY || true)"
        if [[ -z "$api_key" ]]; then
            echo "Error: OPENROUTER_API_KEY not found in $pi_env. install reads" >&2
            echo "the model proxy's key from the same file a local --harness pi" >&2
            echo "run uses." >&2
            exit 1
        fi
        fs_reject_unsafe_chars "$api_key" || exit 1
        reject_nginx_unsafe_chars "$api_key" "OPENROUTER_API_KEY" || exit 1
    elif [[ ${#KEYED_ENDPOINT_NAMES[@]} -gt 0 ]]; then
        require_secret_file "$pi_env" || exit 1
        local key_j key_endpoint key_var key_value key_nginx_var
        for (( key_j = 0; key_j < ${#KEYED_ENDPOINT_NAMES[@]}; key_j++ )); do
            key_endpoint="${KEYED_ENDPOINT_NAMES[$key_j]}"
            key_var="${KEYED_ENDPOINT_VARS[$key_j]}"
            key_value="$(read_env_value "$pi_env" "$key_var" || true)"
            if [[ -z "$key_value" ]]; then
                echo "Error: K8S_PROXY_ENDPOINT_KEYS declares endpoint" >&2
                echo "'$key_endpoint' keyed by $key_var, but $key_var is not set" >&2
                echo "(or is empty) in $pi_env." >&2
                exit 1
            fi
            fs_reject_unsafe_chars "$key_value" || exit 1
            reject_nginx_unsafe_chars "$key_value" \
                "$key_var (K8S_PROXY_ENDPOINT_KEYS endpoint '$key_endpoint')" || exit 1
            # Endpoint names are already validated as RFC1123 labels by
            # parse_proxy_endpoints, so '-' is the only character this
            # mapping ever needs to rewrite -- but assert the result is a
            # legal nginx variable name anyway, rather than trust that
            # invariant silently: a future loosening of the endpoint-name
            # regex should fail loudly here, not render broken nginx config.
            key_nginx_var="upstream_key_${key_endpoint//-/_}"
            if [[ ! "$key_nginx_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                echo "Error: endpoint name '$key_endpoint' does not map to a" >&2
                echo "legal nginx variable name ('\$$key_nginx_var')." >&2
                exit 1
            fi
            keyed_endpoint_values+=("$key_value")
            keyed_endpoint_nginx_vars+=("$key_nginx_var")
        done
    fi

    resolve_platform || exit 1

    local manifests_dir
    manifests_dir="$(dirname "$script_dir")/manifests/k8s"
    if [[ ! -d "$manifests_dir" ]]; then
        echo "Error: $manifests_dir not found. Run this from a fork-sandbox" >&2
        echo "checkout." >&2
        exit 1
    fi

    local rendered f
    rendered=""
    for f in "$manifests_dir"/*.yaml; do
        # 31-claude-proxy.yaml is rendered per-run by cmd_submit, keyed on
        # that run's own __RUN_NAME__ -- a value install has no run to take
        # it from. Applying it here would apply a broken manifest with a
        # literal, unsubstituted __RUN_NAME__ in it.
        [[ "$(basename "$f")" == 31-claude-proxy.yaml ]] && continue
        [[ "$(basename "$f")" == 32-codex-proxy.yaml ]] && continue
        # 40-postmaster.yaml carries __PM_*__ placeholders that only
        # `install --postmaster` has values for (see that block, below the
        # base render loop and the platform NetworkPolicy render) -- plain
        # install must skip it exactly like 31-claude-proxy.yaml above, or
        # this loop would apply a manifest with literal, unsubstituted
        # placeholders in it.
        [[ "$(basename "$f")" == 40-postmaster.yaml ]] && continue
        local file_rendered
        file_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__PROXY_UPSTREAM_HOST__|$upstream_host|g" \
            -e "s|__PROXY_UPSTREAM__|$K8S_PROXY_UPSTREAM|g" \
            -e "s|__CLUSTER_DOMAIN__|$K8S_CLUSTER_DOMAIN|g" \
            -e "s|__QUOTA_PODS__|$K8S_QUOTA_PODS|g" \
            -e "s|__QUOTA_REQUESTS_CPU__|$K8S_QUOTA_REQUESTS_CPU|g" \
            -e "s|__QUOTA_REQUESTS_MEMORY__|$K8S_QUOTA_REQUESTS_MEMORY|g" \
            -e "s|__QUOTA_LIMITS_CPU__|$K8S_QUOTA_LIMITS_CPU|g" \
            -e "s|__QUOTA_LIMITS_MEMORY__|$K8S_QUOTA_LIMITS_MEMORY|g" \
            "$f")"
        if [[ "$(basename "$f")" == 30-proxy.yaml ]]; then
            # The nginx location block(s) for whichever upstream mode is
            # active -- built fully-resolved (see render_proxy_locations's
            # own header for why), never left as a token for a later sed
            # pass to fill in.
            file_rendered="${file_rendered//__PROXY_LOCATIONS__/$(render_proxy_locations "$upstream_host")}"

            # The embeddings rate-limit zone line exists only when some
            # endpoint opts in; otherwise the placeholder's whole line goes,
            # so an install without the key renders byte-identically.
            if (( ${#EMBED_ENDPOINT_NAMES[@]} > 0 )); then
                file_rendered="${file_rendered//__PROXY_EMBED_ZONE__/limit_req_zone \$binary_remote_addr zone=fork_sandbox_embed:10m rate=50r/s;}"
            else
                file_rendered="$(sed '/^ *__PROXY_EMBED_ZONE__$/d' <<< "$file_rendered")"
            fi

            # The proxy's own NetworkPolicy egress rule(s) -- see
            # render_proxy_egress_rules's own header for why unset
            # K8S_PROXY_ALLOW must render byte-identical to today's default.
            file_rendered="$(render_proxy_egress_rules_sub "$file_rendered")" || exit 1

            # A K8S_PROXY_ENDPOINTS install with no keyed endpoints creates
            # no fork-sandbox-upstream-key Secret below, so it must not
            # include a file that Secret is the only thing that ever mounts
            # -- nginx would otherwise crashloop on a missing include -- and
            # it must not reference that Secret from the Deployment's
            # volumes either, or kubelet refuses to start the pod at all.
            # The legacy K8S_PROXY_UPSTREAM path, and an endpoints install
            # with at least one K8S_PROXY_ENDPOINT_KEYS entry, both leave
            # both in place untouched -- either one needs the same Secret
            # mounted, just with different content -- which is what keeps a
            # keyless install's render byte-identical.
            if [[ -z "$K8S_PROXY_UPSTREAM" && ${#KEYED_ENDPOINT_NAMES[@]} -eq 0 ]]; then
                file_rendered="$(strip_proxy_key_include "$file_rendered")" || exit 1
                file_rendered="$(strip_proxy_key_volume "$file_rendered")" || exit 1
            fi

            # A hash of the rendered nginx.conf, filled into the proxy
            # Deployment's pod-template annotation so a config change rolls
            # the proxy by itself -- see the annotation's own comment in
            # manifests/k8s/30-proxy.yaml for why the template, not the
            # Deployment's own metadata, has to carry it.
            local conf_checksum
            conf_checksum="$(k8s_extract_nginx_conf <<< "$file_rendered" | k8s_sha256_stdin)" || exit 1
            file_rendered="${file_rendered//__PROXY_CONF_CHECKSUM__/$conf_checksum}"
        fi
        rendered+="$file_rendered"$'\n'
    done

    # --postmaster's own render: the config ConfigMaps (client-side, so no
    # cluster is contacted yet), the checksum over them, and the postmaster
    # manifest template with its placeholders filled and its absent
    # optional blocks stripped. Needs $manifests_dir, just computed above.
    local pm_config_yaml="" pm_personas_yaml="" pm_prompts_yaml="" pm_handlers_yaml="" pm_hooks_yaml="" pm_presets_yaml=""
    local pm_config_checksum="" pm_file_rendered="" tag
    local pm_git_secret_yaml="" pm_tokens_secret_yaml="" pm_claude_secret_yaml=""
    if $postmaster; then
        pm_config_yaml="$(kubectl create configmap fork-sandbox-postmaster-config \
            "${pm_config_args[@]}" --dry-run=client -o yaml)"
        $pm_have_personas && pm_personas_yaml="$(kubectl create configmap fork-sandbox-postmaster-personas \
            "${pm_personas_args[@]}" --dry-run=client -o yaml)"
        $pm_have_prompts && pm_prompts_yaml="$(kubectl create configmap fork-sandbox-postmaster-prompts \
            "${pm_prompts_args[@]}" --dry-run=client -o yaml)"
        $pm_have_handlers && pm_handlers_yaml="$(kubectl create configmap fork-sandbox-postmaster-handlers \
            "${pm_handlers_args[@]}" --dry-run=client -o yaml)"
        $pm_have_hooks && pm_hooks_yaml="$(kubectl create configmap fork-sandbox-postmaster-hooks \
            "${pm_hooks_args[@]}" --dry-run=client -o yaml)"
        $pm_have_presets && pm_presets_yaml="$(kubectl create configmap fork-sandbox-postmaster-presets \
            "${pm_presets_args[@]}" --dry-run=client -o yaml)"

        # Both Secrets are rendered here, once, and folded into the
        # checksum: the API server reads its tokens at startup and the git
        # key is read at pod init, so rotating either must roll the pod.
        # Their text goes into the hash and the apply phase only -- never
        # to any output stream.
        pm_git_secret_yaml="$(kubectl create secret generic fork-sandbox-postmaster-git \
            --from-file="deploy-key=$K8S_POSTMASTER_GIT_KEY_FILE" \
            --from-file="known_hosts=$K8S_POSTMASTER_KNOWN_HOSTS_FILE" \
            --dry-run=client -o yaml)"
        if [[ -n "$K8S_MAIL_API_TOKENS_FILE" ]]; then
            # The team token's hash rides in the same Secret as the tokens
            # file, as a sibling key the server reads (fork-sandbox-mail-api.py
            # serve, "The team token"): the Deployment needs no new volume
            # and the raw token never reaches the pod. The hash is not a
            # secret, so --from-literal is fine.
            pm_plan_team_token "$dry_run" "$rotate_team" || exit 1
            pm_tokens_secret_yaml="$(kubectl create secret generic fork-sandbox-mail-api-tokens \
                --from-file="tokens=$K8S_MAIL_API_TOKENS_FILE" \
                --from-literal="team-token-sha256=$PM_TEAM_HASH" \
                --dry-run=client -o yaml)"
        fi
        if [[ -n "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]]; then
            pm_claude_secret_yaml="$(kubectl create secret generic fork-sandbox-postmaster-claude \
                --from-file="credentials.json=$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" \
                --dry-run=client -o yaml)"
        fi

        pm_config_checksum="$(printf '%s%s%s%s%s%s%s%s%s' \
            "$pm_config_yaml" "$pm_personas_yaml" "$pm_prompts_yaml" \
            "$pm_handlers_yaml" "$pm_hooks_yaml" "$pm_presets_yaml" \
            "$pm_git_secret_yaml" "$pm_tokens_secret_yaml" \
            "$pm_claude_secret_yaml" | k8s_sha256_stdin)"

        pm_file_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__PM_IMAGE__|$K8S_POSTMASTER_IMAGE|g" \
            -e "s|__PM_ACCESS_MODE__|$K8S_POSTMASTER_ACCESS_MODE|g" \
            -e "s|__PM_STORAGE__|$K8S_POSTMASTER_STORAGE|g" \
            -e "s|__PM_MAIL_STORAGE__|$K8S_POSTMASTER_MAIL_STORAGE|g" \
            -e "s|__PM_CONFIG_CHECKSUM__|$pm_config_checksum|g" \
            -e "s|__PM_OPERATORS__|$K8S_POSTMASTER_OPERATORS|g" \
            -e "s|__PM_HOOKS_SECRET__|${K8S_POSTMASTER_HOOKS_SECRET:-(none)}|g" \
            "$manifests_dir/40-postmaster.yaml")"
        if [[ -z "$K8S_POSTMASTER_STORAGE_CLASS" ]]; then
            local pm_scline pm_stripped
            pm_scline=$'  storageClassName: __PM_STORAGE_CLASS__\n'
            pm_stripped="${pm_file_rendered//"$pm_scline"/}"
            if [[ "$pm_stripped" == "$pm_file_rendered" ]]; then
                echo "Error: could not find the storageClassName placeholder line" >&2
                echo "in the rendered postmaster PVCs -- manifests/k8s/40-postmaster.yaml" >&2
                echo "and cmd_install have drifted apart." >&2
                exit 1
            fi
            pm_file_rendered="$pm_stripped"
            # The line itself is gone, but the file's own header comment
            # names every placeholder token by literal text -- including
            # this one -- so it still needs a substitution, not just the
            # field.
            pm_file_rendered="${pm_file_rendered//__PM_STORAGE_CLASS__/(cluster default)}"
        else
            pm_file_rendered="${pm_file_rendered//__PM_STORAGE_CLASS__/$K8S_POSTMASTER_STORAGE_CLASS}"
        fi
        if ! $pm_have_personas; then
            for tag in "personas env" "personas volumeMount" "personas volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if ! $pm_have_prompts; then
            for tag in "prompts env" "prompts volumeMount" "prompts volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if ! $pm_have_handlers; then
            for tag in "handlers env" "handlers volumeMount" "handlers volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if ! $pm_have_hooks; then
            for tag in "hooks env" "hooks volumeMount" "hooks volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if [[ -z "$K8S_POSTMASTER_HOOKS_SECRET" ]]; then
            for tag in "hook-secret env" "hook-secret volumeMount" "hook-secret volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if [[ -z "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]]; then
            for tag in "claude-credentials env" "claude-credentials volumeMount" "claude-credentials volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if ! $pm_have_presets; then
            for tag in "presets env" "presets volumeMount" "presets volume"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
        fi
        if [[ -z "$K8S_MAIL_API_TOKENS_FILE" ]]; then
            for tag in "mail-api container" "mail-api volume" "mail-api service" \
                "mail-team role" "mail-team binding"; do
                pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "$tag")" || exit 1
            done
            echo "fork-sandbox-k8s: the mail API is not deployed (K8S_MAIL_API_TOKENS_FILE is" >&2
            echo "not set); see docs/cluster-postmaster.md to enable it." >&2
            if [[ -n "$K8S_MAIL_TEAM_SUBJECTS" ]]; then
                echo "fork-sandbox-k8s: K8S_MAIL_TEAM_SUBJECTS is ignored without the mail API." >&2
            fi
        elif [[ -z "$K8S_MAIL_TEAM_SUBJECTS" ]]; then
            pm_file_rendered="$(strip_pm_optional_block "$pm_file_rendered" "mail-team binding")" || exit 1
        else
            pm_file_rendered="${pm_file_rendered//"  - __PM_TEAM_SUBJECTS__"/${pm_team_subjects_yaml%$'\n'}}"
        fi
    fi

    # K8S_AGENT_ALLOW_NS becomes one --allow-namespace per entry. It reuses
    # the proxy key's parser -- identical syntax, identical validation, and
    # the same DNAT reasoning -- but the RULE is rendered by the plugin, not
    # here, because the agent policy is the platform's to emit and this
    # script has no business knowing its dialect.
    #
    # That parser fills the module-global PROXY_ALLOW_NS_* arrays, and those
    # are what render_proxy_egress_rules_ns reads for the PROXY's policy.
    # Parsing the agent's key through it therefore clobbers the proxy's
    # entries. The proxy policy happens to be rendered already by this point,
    # but leaning on that would leave a live trap: move this block earlier --
    # "validate all config before rendering anything" is a plausible tidy-up
    # -- and K8S_PROXY_ALLOW_NS's namespaces silently vanish from the proxy
    # policy while the agent's appear there instead, with every test still
    # green. So the proxy's parse is restored below rather than assumed
    # spent. The invariant is enforced here, not documented at a distance.
    local -a agent_allow_args=()
    if [[ -n "$K8S_AGENT_ALLOW_NS" ]]; then
        parse_proxy_allow_ns "$K8S_AGENT_ALLOW_NS" K8S_AGENT_ALLOW_NS || exit 1
        local ai ans aport
        for (( ai = 0; ai < ${#PROXY_ALLOW_NS_NAMESPACES[@]}; ai++ )); do
            ans="${PROXY_ALLOW_NS_NAMESPACES[$ai]}"
            aport="${PROXY_ALLOW_NS_PORTS[$ai]}"
            if [[ -n "$aport" ]]; then
                agent_allow_args+=(--allow-namespace "$ans:$aport")
            else
                agent_allow_args+=(--allow-namespace "$ans")
            fi
        done
        announce_agent_allow_ns
        # Restore the proxy's own parse. An empty K8S_PROXY_ALLOW_NS resets
        # the arrays to empty and succeeds, which is the correct restore for
        # the common case of the key being unset.
        parse_proxy_allow_ns "$K8S_PROXY_ALLOW_NS" || exit 1
    fi
    rendered+="$("$K8S_PLATFORM_BIN" render-policy --namespace "$K8S_NAMESPACE" \
        --agent-label app=fork-sandbox-agent \
        --proxy-label app=fork-sandbox-proxy --proxy-port 8080 \
        ${agent_allow_args[@]+"${agent_allow_args[@]}"})"

    if [[ "$dry_run" == true ]]; then
        printf '%s\n' "$rendered"
        local dry_key_name
        for dry_key_name in "${KEYED_ENDPOINT_NAMES[@]}"; do
            printf '# (dry-run) would create/update Secret fork-sandbox-upstream-key entry for K8S_PROXY_ENDPOINTS endpoint '\''%s'\'' here -- not shown.\n' \
                "$dry_key_name"
        done
        if $postmaster; then
            # kubectl's own -o yaml render carries no leading `---`, unlike
            # every manifests/k8s/*.yaml file (each already opens with
            # one) -- so each ConfigMap needs one added here to keep the
            # whole dry-run stream valid multi-document YAML.
            printf -- '---\n%s\n' "$pm_config_yaml"
            $pm_have_personas && printf -- '---\n%s\n' "$pm_personas_yaml"
            $pm_have_prompts  && printf -- '---\n%s\n' "$pm_prompts_yaml"
            $pm_have_handlers && printf -- '---\n%s\n' "$pm_handlers_yaml"
            $pm_have_hooks    && printf -- '---\n%s\n' "$pm_hooks_yaml"
            $pm_have_presets  && printf -- '---\n%s\n' "$pm_presets_yaml"
            printf '# (dry-run) would create Secret fork-sandbox-postmaster-git ... -- not shown.\n'
            [[ -z "$K8S_MAIL_API_TOKENS_FILE" ]] || \
                printf '# (dry-run) would create Secret fork-sandbox-mail-api-tokens ... -- not shown.\n'
            if [[ -n "$K8S_MAIL_API_TOKENS_FILE" ]]; then
                if $rotate_team; then
                    printf '# (dry-run) would REPLACE Secret %s with a new token ... -- not shown.\n' "$PM_TEAM_SECRET"
                else
                    printf '# (dry-run) would create Secret %s if absent ... -- not shown.\n' "$PM_TEAM_SECRET"
                fi
            fi
            [[ -z "$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE" ]] || \
                printf '# (dry-run) would create Secret fork-sandbox-postmaster-claude ... -- not shown.\n'
            printf '%s\n' "$pm_file_rendered"
        fi
        exit 0
    fi

    printf '%s\n' "$rendered" | kubectl apply -f -

    # OPENROUTER_API_KEY/K8S_PROXY_ENDPOINT_KEYS credentials (api_key /
    # keyed_endpoint_values) were already read from pi.env and validated
    # above, before anything was rendered or applied -- this just builds
    # and applies the Secret from those already-checked values. This Secret
    # is created on the legacy K8S_PROXY_UPSTREAM path, or on a
    # K8S_PROXY_ENDPOINTS install only when at least one endpoint is named
    # in K8S_PROXY_ENDPOINT_KEYS -- a keyless endpoints install (see
    # proxy_key_include_block/strip_proxy_key_include above for the other
    # half of that) reads no credential from pi.env at all.
    if [[ -n "$K8S_PROXY_UPSTREAM" ]]; then
        # shellcheck disable=SC2016  # the literal text $upstream_key is nginx config, not shell
        printf 'set $upstream_key "%s";' "$api_key" \
            | k8s_render_upstream_key_secret_manifest fork-sandbox-upstream-key "$K8S_NAMESPACE" \
            | kubectl apply -f - --server-side --field-manager="$K8S_INSTALL_SECRET_FIELD_MANAGER" --force-conflicts
    elif [[ ${#KEYED_ENDPOINT_NAMES[@]} -gt 0 ]]; then
        local secret_content="" key_j
        for (( key_j = 0; key_j < ${#KEYED_ENDPOINT_NAMES[@]}; key_j++ )); do
            secret_content+="set \$${keyed_endpoint_nginx_vars[$key_j]} \"${keyed_endpoint_values[$key_j]}\";"$'\n'
        done
        printf '%s' "$secret_content" \
            | k8s_render_upstream_key_secret_manifest fork-sandbox-upstream-key "$K8S_NAMESPACE" \
            | kubectl apply -f - --server-side --field-manager="$K8S_INSTALL_SECRET_FIELD_MANAGER" --force-conflicts
    fi

    # Postmaster ConfigMaps and Secret before the Deployment (bundled with
    # the SA/Role/RoleBinding/PVC in $pm_file_rendered) -- so the Deployment
    # never comes up racing a config or credential that is not there yet.
    if $postmaster; then
        printf '%s\n' "$pm_config_yaml" | kubectl apply -f -
        $pm_have_personas && printf '%s\n' "$pm_personas_yaml" | kubectl apply -f -
        $pm_have_prompts  && printf '%s\n' "$pm_prompts_yaml" | kubectl apply -f -
        $pm_have_handlers && printf '%s\n' "$pm_handlers_yaml" | kubectl apply -f -
        $pm_have_hooks    && printf '%s\n' "$pm_hooks_yaml" | kubectl apply -f -
        $pm_have_presets  && printf '%s\n' "$pm_presets_yaml" | kubectl apply -f -
        printf '%s\n' "$pm_git_secret_yaml" | kubectl apply -f - \
            --server-side --field-manager="$K8S_INSTALL_SECRET_FIELD_MANAGER" --force-conflicts
        # The team token, before the tokens Secret that carries its hash.
        # `create`, never `apply`: it fails when the Secret exists instead
        # of overwriting the token the team already holds. PM_TEAM_SECRET_YAML
        # is set only when pm_plan_team_token found no Secret (or a rotation
        # was asked for), so a plain re-install skips this entirely.
        if [[ -n "$PM_TEAM_SECRET_YAML" ]]; then
            if $rotate_team; then
                kubectl delete secret "$PM_TEAM_SECRET" --ignore-not-found >/dev/null
            fi
            if ! printf '%s\n' "$PM_TEAM_SECRET_YAML" | kubectl create -f - >/dev/null; then
                echo "Error: could not create Secret $PM_TEAM_SECRET (did a concurrent" >&2
                echo "install create it first?). Nothing of the mail API was changed;" >&2
                echo "re-run install --postmaster." >&2
                exit 1
            fi
            if $rotate_team; then
                echo "fork-sandbox-k8s: rotated the mail API team token (Secret $PM_TEAM_SECRET);" >&2
                echo "the old token stops working when the postmaster pod rolls." >&2
            else
                echo "fork-sandbox-k8s: created the mail API team token (Secret $PM_TEAM_SECRET)." >&2
            fi
        fi
        [[ -z "$pm_tokens_secret_yaml" ]] || \
            printf '%s\n' "$pm_tokens_secret_yaml" | kubectl apply -f - \
                --server-side --field-manager="$K8S_INSTALL_SECRET_FIELD_MANAGER" --force-conflicts
        [[ -z "$pm_claude_secret_yaml" ]] || \
            printf '%s\n' "$pm_claude_secret_yaml" | kubectl apply -f - \
                --server-side --field-manager="$K8S_INSTALL_SECRET_FIELD_MANAGER" --force-conflicts
        printf '%s\n' "$pm_file_rendered" | kubectl apply -f -
    fi

    echo "fork-sandbox-k8s: installed into namespace $K8S_NAMESPACE" >&2
}

# Shared by --thread-dir and --attach-dir (Section 1 of the thread/attach
# work): the same tar-cf-turns-a-symlink-into-a-link-entry hazard
# --context-ro's own inline checks (in cmd_submit, below) guard against
# applies to any directory pushed through this transport. Kept as its own
# function rather than a third inline copy of the same two `find`s;
# --context-ro's own inline copy is left untouched, matching text, so
# either check's error message stays exactly what its own tests pin.
k8s_refuse_dir_links() {
    local dir="$1" flag="$2" sym hl
    sym="$(find "$dir" -type l -print -quit)"
    if [[ -n "$sym" ]]; then
        echo "Error: $flag directory '$dir' contains a symlink" >&2
        echo "('$sym'); links are not allowed in a pushed directory." >&2
        return 1
    fi
    hl="$(find "$dir" -type f -links +1 -print -quit)"
    if [[ -n "$hl" ]]; then
        echo "Error: $flag directory '$dir' contains a hard-linked file" >&2
        echo "('$hl'); links are not allowed in a pushed directory." >&2
        return 1
    fi
    return 0
}

# Shared by --thread-dir, --attach-dir and --run-dir: packs DIR's
# top-level entries (including dotfiles) into TAR as child members named
# ./<entry>, never as `.` itself -- see fork-sandbox-k8s-context-extract.sh's
# own pre-existing-DEST_DIR comment for the pod-side EPERM that avoids.
# Entries are enumerated with a bash glob rather than find(1): this
# spool runs on the host, which may be macOS, and BSD find has no
# -printf. The `./` prefix keeps a name starting with `-` from being
# read as a tar option; names travel to tar as separate argv words, so
# spaces and other odd bytes are safe with no --null -T dance needed.
# Those words go through xargs -0 rather than one `tar` call: a wide
# directory (tens of thousands of entries) can overflow a single
# invocation's argv before tar ever gets to see it, and xargs -0 knows
# the host's real ARG_MAX and batches accordingly. Batching starts from
# the same empty archive the zero-entries case below creates, so the
# archive-size cap the caller checks stays the actual limit.
#
# `-h` dereferences symlinks into the real file (or directory) they point
# at, rather than archiving a link entry -- fork-sandbox-k8s-context-
# extract.sh refuses a link entry outright on the pod side (that guard
# stays; it is what makes a hostile or confused push safe). A staged
# --run-dir, unlike --thread-dir/--attach-dir, is never pre-checked for
# symlinks before reaching here (its own agent-kit skill directories are
# routinely symlinks on an installed machine), so without `-h` every live
# composed --k8s run would tar a link entry and the pod would then refuse
# the whole push. --thread-dir/--attach-dir already refuse a symlinked
# tree before calling this function, so `-h` is a no-op for them.
k8s_spool_dir_entries() {
    local dir="$1" tar_out="$2"
    local -a entries=()
    local entry
    while IFS= read -r -d '' entry; do
        entries+=("$entry")
    done < <(
        shopt -s dotglob nullglob
        for entry in "$dir"/*; do
            printf './%s\0' "${entry#"$dir"/}"
        done
    )
    # tar refuses to create an archive with no members at all.
    tar cf "$tar_out" -T /dev/null
    if (( ${#entries[@]} > 0 )); then
        printf '%s\0' "${entries[@]}" | xargs -0 tar rhf "$tar_out" -C "$dir" --
    fi
}

# --allow-namespace's own parse + validate: the comma-join into
# parse_proxy_allow_ns and the per-run announce, exactly as cmd_submit ran
# them inline before this round. Fills the caller's namespaces/ports
# arrays (namerefs, named by the caller since both cmd_submit and
# check-grant keep going with the raw values afterward -- cmd_submit's
# probe loop right after, check-grant's own copy of that same loop).
# Exits 1 on a refused value, same message as always; check-grant runs
# this in a subshell and maps the subshell's exit status to 2 itself, so
# this function's own exit behaviour need not change.
validate_run_allow_ns() {
    local -n _vrans_ns="$1" _vrans_port="$2"
    shift 2
    local -a allow_ns_raw=("$@")
    _vrans_ns=()
    _vrans_port=()
    # check-grant prints each raw value back out verbatim, one per line
    # (see cmd_check_grant) -- a value containing a newline would forge
    # further lines in that output, and the grant file is a straight copy
    # of it (mail_write_grant), so this is a boundary check, not a style
    # one. fs_reject_unsafe_chars already refuses newline (and a single
    # quote, which cmd_submit's own downstream shell-outs need refused
    # too); reused rather than reimplemented, same as every other sink in
    # this file.
    fs_reject_unsafe_chars "${allow_ns_raw[@]}" || exit 1
    if (( ${#allow_ns_raw[@]} > 0 )); then
        local allow_ns_joined
        allow_ns_joined="$(IFS=,; printf '%s' "${allow_ns_raw[*]}")"
        parse_proxy_allow_ns "$allow_ns_joined" --allow-namespace || exit 1
        _vrans_ns=("${PROXY_ALLOW_NS_NAMESPACES[@]}")
        _vrans_port=("${PROXY_ALLOW_NS_PORTS[@]}")
        announce_run_allow_ns
    fi
}

# --reach-probe's own parse + validate: the pairing rule against
# --allow-namespace (a probe needs a namespace, a namespace needs at least
# one probe) and the per-probe HOST:PORT/DNS-shape/grant-match checks,
# unchanged from cmd_submit's old inline loop. $1 is a nameref to the
# caller's probes-out array; $2/$3 are namerefs to the (already-filled, by
# validate_run_allow_ns above) namespaces/ports arrays; $4 is the number of
# --allow-namespace flags actually given (not always the same length as
# $2 in theory, so passed explicitly rather than inferred from it, the
# same value cmd_submit's own pairing check used: ${#allow_ns_raw[@]}).
# Same exit-1-on-refusal contract as validate_run_allow_ns above.
validate_run_reach_probes() {
    local -n _vrrp_probes="$1" _vrrp_ns="$2" _vrrp_port="$3"
    local allow_ns_count="$4"
    shift 4
    local -a reach_probe_raw=("$@")
    _vrrp_probes=()

    # Same boundary as validate_run_allow_ns above, and for the same
    # reason: a --reach-probe value reaches check-grant's verbatim stdout
    # (REACH_PROBE=<value exactly as given>) and from there the grant
    # file, so a newline here forges a line neither check-grant nor its
    # caller ever validated. Checked before the HOST:PORT split below --
    # bash's "${probe%:*}" and the read into host_labels operate on the
    # string as a whole and would happily carry an embedded newline
    # through shape validation unnoticed (read stops at the first one,
    # not the caller-intended end of the host).
    fs_reject_unsafe_chars "${reach_probe_raw[@]}" || exit 1

    if (( ${#reach_probe_raw[@]} > 0 && allow_ns_count == 0 )); then
        echo "Error: --reach-probe requires --allow-namespace. A reach probe" >&2
        echo "verifies a grant the gate actually exercises; there is nothing" >&2
        echo "to verify without one." >&2
        exit 1
    fi
    if (( allow_ns_count > 0 && ${#reach_probe_raw[@]} == 0 )); then
        echo "Error: --allow-namespace requires at least one --reach-probe." >&2
        echo "A missing policy once passed the gate silently -- every grant" >&2
        echo "must be exercised by at least one probe, or refuse." >&2
        exit 1
    fi

    # Per-probe validation: HOST must be <svc>.<ns>, <svc>.<ns>.svc, or
    # <svc>.<ns>.svc.$K8S_CLUSTER_DOMAIN (the same three shapes this file
    # accepts elsewhere for a Service DNS name), <ns> must be one of this
    # run's granted namespaces, and if that namespace's grant names a port
    # the probe's port must equal it -- otherwise the probe can never pass
    # and the run would only fail 60s later at the gate, for a reason
    # submit could have named right here. Shape is checked by splitting on
    # "." and counting/comparing labels, not with [[ =~ ]] or a "*.*.svc"
    # style glob: K8S_CLUSTER_DOMAIN may contain literal dots, an ERE dot
    # is a metacharacter, and a glob's "*" absorbs embedded dots too --
    # "*.*.svc" wrongly accepts "svc.ns.extra.svc" (see this file's other
    # glob-not-regex host comparisons, which use a single suffix "*" and
    # don't have this trap).
    local probe host port_probe ns_seg gi found gport port_ok shape_ok
    local -a host_labels domain_labels
    local di domain_match
    for probe in "${reach_probe_raw[@]}"; do
        host="${probe%:*}"
        port_probe="${probe##*:}"
        if [[ "$port_probe" == "$probe" || -z "$host" || -z "$port_probe" ]]; then
            echo "Error: --reach-probe '$probe' must be HOST:PORT." >&2
            exit 1
        fi
        if [[ ! "$port_probe" =~ ^[0-9]{1,5}$ ]] || (( 10#$port_probe < 1 || 10#$port_probe > 65535 )); then
            echo "Error: --reach-probe '$probe' has an invalid port" >&2
            echo "'$port_probe' -- must be 1-65535." >&2
            exit 1
        fi
        port_probe=$(( 10#$port_probe ))

        shape_ok=false
        IFS='.' read -r -a host_labels <<< "$host"
        IFS='.' read -r -a domain_labels <<< "$K8S_CLUSTER_DOMAIN"
        if (( ${#host_labels[@]} == 2 )); then
            shape_ok=true
        elif (( ${#host_labels[@]} == 3 )) && [[ "${host_labels[2]}" == svc ]]; then
            shape_ok=true
        elif (( ${#host_labels[@]} == 3 + ${#domain_labels[@]} )) \
                && [[ "${host_labels[2]}" == svc ]]; then
            domain_match=true
            for (( di = 0; di < ${#domain_labels[@]}; di++ )); do
                [[ "${host_labels[3 + di]}" == "${domain_labels[$di]}" ]] || domain_match=false
            done
            [[ "$domain_match" == true ]] && shape_ok=true
        fi
        if [[ "$shape_ok" != true ]]; then
            echo "Error: --reach-probe '$probe' has host '$host', which must be" >&2
            echo "<svc>.<ns>, <svc>.<ns>.svc, or <svc>.<ns>.svc.$K8S_CLUSTER_DOMAIN." >&2
            exit 1
        fi
        ns_seg="${host#*.}"
        ns_seg="${ns_seg%%.*}"

        # A namespace can be granted more than once with different ports
        # (--allow-namespace ns:443 --allow-namespace ns:80 is legal, both
        # are repeatable per the flag's own contract, and render-grant
        # emits both as separate egress rules) -- so the probe's port must
        # be checked against EVERY grant entry for this namespace, not just
        # the first one found, or a probe on the second-declared port is
        # wrongly refused even though the gate would actually let it through.
        found=false
        port_ok=false
        for (( gi = 0; gi < ${#_vrrp_ns[@]}; gi++ )); do
            if [[ "${_vrrp_ns[$gi]}" == "$ns_seg" ]]; then
                found=true
                gport="${_vrrp_port[$gi]}"
                if [[ -z "$gport" ]] || (( gport == port_probe )); then
                    port_ok=true
                    break
                fi
            fi
        done
        if [[ "$found" != true ]]; then
            echo "Error: --reach-probe '$probe' targets namespace '$ns_seg'," >&2
            echo "which is not one of this run's --allow-namespace grants." >&2
            exit 1
        fi
        if [[ "$port_ok" != true ]]; then
            echo "Error: --reach-probe '$probe' uses port $port_probe, but no" >&2
            echo "--allow-namespace grant for '$ns_seg' names that port --" >&2
            echo "they must match, or the probe can never pass the gate." >&2
            exit 1
        fi
        _vrrp_probes+=("$host:$port_probe")
    done
}

# --context-ro's own validate: the resolved real path must sit under
# /var/tmp/claude-scratch/forks/, must exist, and must contain no symlink
# or hard-linked file (tar cf's ordinary walk turns either into a link
# entry the pod-side extractor refuses -- but only after the Job exists,
# the pod is Ready and the repository has already been pushed; refusing
# here catches it before any cluster object is created). Prints the
# resolved real path on stdout on success -- callers run it via command
# substitution, e.g. context_ro="$(validate_context_ro_dir "$context_ro")"
# || exit 1, which already runs it in a subshell of its own, so exit 1
# inside here never has to be distinguished from exit 2 the way the two
# functions above do.
validate_context_ro_dir() {
    local context_ro="$1" context_ro_real
    context_ro_real="$("$FS_REALPATH" -m "$context_ro")"
    # Same boundary as the two validators above: this path is check-grant's
    # CONTEXT_RO= line verbatim, and a directory basename may legally
    # contain a newline (only NUL and '/' are forbidden in a filename), so
    # without this a crafted --context-ro forges further lines in the
    # grant file the same way a crafted probe or namespace would.
    fs_reject_unsafe_chars "$context_ro_real" || exit 1
    if [[ "$context_ro_real" != "$FS_SCRATCH_ROOT"/forks/* ]]; then
        echo "Error: --context-ro must name a directory under" >&2
        echo "/var/tmp/claude-scratch/forks/ — got '$context_ro_real'. The" >&2
        echo "pod reads it after it is pushed, so which paths may be" >&2
        echo "handed to a pod this way is a security boundary. Stage the" >&2
        echo "context in a mktemp directory there and rerun." >&2
        exit 1
    fi
    if [[ ! -d "$context_ro_real" ]]; then
        echo "Error: --context-ro directory '$context_ro_real' does not exist." >&2
        exit 1
    fi
    local context_ro_symlink
    context_ro_symlink="$(find "$context_ro_real" -type l -print -quit)"
    if [[ -n "$context_ro_symlink" ]]; then
        echo "Error: --context-ro directory '$context_ro_real' contains a symlink" >&2
        echo "('$context_ro_symlink'); links are not allowed in a pushed context" >&2
        echo "directory." >&2
        exit 1
    fi
    local context_ro_hardlink
    context_ro_hardlink="$(find "$context_ro_real" -type f -links +1 -print -quit)"
    if [[ -n "$context_ro_hardlink" ]]; then
        echo "Error: --context-ro directory '$context_ro_real' contains a hard-linked file" >&2
        echo "('$context_ro_hardlink'); links are not allowed in a pushed context" >&2
        echo "directory." >&2
        exit 1
    fi
    printf '%s\n' "$context_ro_real"
}

# --run-dir's own validate: the resolved real path must sit under
# /var/tmp/claude-scratch/forks/ (the same root ordinary submit creates a
# run dir under, via mktemp just below) -- a symlink there is refused for
# the same reason --context-ro's is, and so is anything that is not
# already an existing directory holding both run.sh and pipeline.json: a
# --run-dir submit never creates a run dir, it executes one the launcher
# already staged, so a directory missing either file could only mean a
# caller that built it by hand or interrupted partway through staging,
# either of which should fail loud here rather than produce a Job with no
# runner to execute or no pipeline to describe it. Prints the resolved
# real path on success, exactly like validate_context_ro_dir above.
validate_run_dir_flag() {
    local run_dir_flag="$1" run_dir_real
    if [[ -L "$run_dir_flag" ]]; then
        echo "Error: --run-dir '$run_dir_flag' is a symlink. Name the directory" >&2
        echo "itself: a symlink checked here and resolved later is a different" >&2
        echo "directory from the one that gets used." >&2
        exit 1
    fi
    run_dir_real="$("$FS_REALPATH" -m "$run_dir_flag")"
    fs_reject_unsafe_chars "$run_dir_real" || exit 1
    if [[ "$run_dir_real" != "$FS_SCRATCH_ROOT"/forks/* ]]; then
        echo "Error: --run-dir must name a directory under" >&2
        echo "/var/tmp/claude-scratch/forks/ — got '$run_dir_real'. That is" >&2
        echo "the root every run directory, staged or mktemp'd, lives under." >&2
        exit 1
    fi
    if [[ ! -d "$run_dir_real" ]]; then
        echo "Error: --run-dir directory '$run_dir_real' does not exist. It must" >&2
        echo "already hold run.sh and pipeline.json, staged by the launcher." >&2
        exit 1
    fi
    if [[ ! -f "$run_dir_real/run.sh" ]]; then
        echo "Error: --run-dir directory '$run_dir_real' has no run.sh. It must" >&2
        echo "already hold run.sh and pipeline.json, staged by the launcher." >&2
        exit 1
    fi
    if [[ ! -f "$run_dir_real/pipeline.json" ]]; then
        echo "Error: --run-dir directory '$run_dir_real' has no pipeline.json." >&2
        echo "It must already hold run.sh and pipeline.json, staged by the" >&2
        echo "launcher." >&2
        exit 1
    fi
    printf '%s\n' "$run_dir_real"
}

# --context-secret's name check, shared by check-grant and submit (no
# kubectl -- the label checks need the cluster and run in submit). A
# DNS-1123 subdomain that is not a name fork-sandbox reserves for itself.
# exit 1 on refusal, like the validators above.
validate_context_secret_name() {
    local name="$1"
    if (( ${#name} > 253 )) || [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
        echo "Error: --context-secret '$name' is not a valid Secret name: it" >&2
        echo "must be a DNS-1123 subdomain (lowercase letters, digits, '-' and" >&2
        echo "'.', starting and ending alphanumeric, at most 253 characters)." >&2
        exit 1
    fi
    if [[ "$name" == fork-sandbox-* ]]; then
        echo "Error: --context-secret '$name' starts with 'fork-sandbox-', a" >&2
        echo "prefix reserved for the Secrets fork-sandbox itself creates" >&2
        echo "(provider key, mail tokens). Name a Secret made for this purpose." >&2
        exit 1
    fi
    if [[ "$name" == *-claude-token ]]; then
        echo "Error: --context-secret '$name' ends with '-claude-token', a" >&2
        echo "suffix reserved for the per-run Claude token Secrets." >&2
        exit 1
    fi
    if [[ "$name" == *-codex-token ]]; then
        echo "Error: --context-secret '$name' ends with '-codex-token', a" >&2
        echo "suffix reserved for the per-run Codex token Secrets." >&2
        exit 1
    fi
}

# --context-secret and --context-ro both populate /work/context.
refuse_context_secret_with_ro() {
    echo "Error: --context-secret and --context-ro cannot be combined: both" >&2
    echo "populate /work/context." >&2
    exit 1
}

# check-grant: runs ONLY the three validators above (no kubectl, no
# cluster), the grant half of what cmd_submit checks -- the "one grant
# parser" the postmaster's per-thread grants (mail grant, Section 5) rely
# on: a grant accepted here is one submit will also accept later, and a
# grant refused here is refused for the identical reason. See
# docs/kubernetes-runs.md.
cmd_check_grant() {
    local -a allow_ns_raw=() reach_probe_raw=()
    local context_ro="" context_secret="" saw_any=false
    while (( $# )); do
        case "$1" in
            --allow-namespace) allow_ns_raw+=("${2:?--allow-namespace requires NS[:PORT]}"); saw_any=true; shift 2 ;;
            --reach-probe) reach_probe_raw+=("${2:?--reach-probe requires HOST:PORT}"); saw_any=true; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; saw_any=true; shift 2 ;;
            --context-secret) context_secret="${2:?--context-secret requires a Secret name}"; saw_any=true; shift 2 ;;
            *)
                echo "Usage: fork-sandbox-k8s.sh check-grant [--allow-namespace NS[:PORT]]..." >&2
                echo "                            [--reach-probe HOST:PORT]..." >&2
                echo "                            [--context-ro DIR | --context-secret NAME]" >&2
                exit 1
                ;;
        esac
    done
    if [[ "$saw_any" != true ]]; then
        echo "Usage: fork-sandbox-k8s.sh check-grant [--allow-namespace NS[:PORT]]..." >&2
        echo "                            [--reach-probe HOST:PORT]..." >&2
        echo "                            [--context-ro DIR | --context-secret NAME]" >&2
        exit 1
    fi

    # Run in a subshell so the extracted validators' own "exit 1 on
    # refusal" (unchanged, so submit's behaviour above stays identical)
    # becomes THIS verb's exit 2 -- and so the success-case stdout lines
    # below print only once validation has fully passed, never a partial
    # set ahead of a later refusal.
    if ! (
        local -a run_allow_ns_namespaces=() run_allow_ns_ports=() run_reach_probes=()
        validate_run_allow_ns run_allow_ns_namespaces run_allow_ns_ports "${allow_ns_raw[@]}"
        validate_run_reach_probes run_reach_probes run_allow_ns_namespaces run_allow_ns_ports \
            "${#allow_ns_raw[@]}" "${reach_probe_raw[@]}"
        local context_ro_real=""
        if [[ -n "$context_ro" ]]; then
            context_ro_real="$(validate_context_ro_dir "$context_ro")" || exit 1
        fi
        if [[ -n "$context_secret" ]]; then
            [[ -z "$context_ro" ]] || refuse_context_secret_with_ro
            validate_context_secret_name "$context_secret"
        fi
        local v
        for v in "${allow_ns_raw[@]}"; do
            printf 'ALLOW_NAMESPACE=%s\n' "$v"
        done
        for v in "${reach_probe_raw[@]}"; do
            printf 'REACH_PROBE=%s\n' "$v"
        done
        if [[ -n "$context_ro" ]]; then
            printf 'CONTEXT_RO=%s\n' "$context_ro_real"
        fi
        if [[ -n "$context_secret" ]]; then
            printf 'CONTEXT_SECRET=%s\n' "$context_secret"
        fi
        exit 0
    ); then
        exit 2
    fi
}

# Called when cmd_submit's own `kubectl wait --for=condition=Ready pod`
# times out. Pod events are not retained on every cluster,
# so the container status and log (both still on the live, not-yet-reaped
# pod) are the evidence, named here instead of the bare "timed out waiting
# for the condition" kubectl itself would print. Scoped to whichever
# container(s) report not ready -- in practice a stuck service sidecar or
# the service-ready initContainer.
#
# The agent container is the one place a Secret CAN surface in this
# output: --context-secret and the claude-token Secret are both mounted or
# injected there alone (fork-sandbox-k8s.sh's own job render), never into a
# service sidecar or service-ready, which carry only the fixed env this
# script writes. kubectl logs reproduces whatever the container itself
# printed, which this script does not control -- so if the agent entrypoint
# or harness ever echoes that mount while dying, tailing it here would
# print the Secret to submit's own stderr. Submit never prints Secret
# content, so that tail is skipped. The agent's
# status (restart count, reason, exit code -- never Secret-bearing) is
# still reported; only its raw log tail is skipped.
#
# $2, when given, is services_ready_checks's own "name:port:seconds
# name2:port2:seconds2" text. A service sidecar carries no readinessProbe
# of its own (a kubelet tcpSocket/httpGet probe dials the pod IP, never the
# 127.0.0.1 bind the sidecar needs -- see
# fork-sandbox-k8s-services-parse.py's ready-checks header), so it reports
# ready=true the moment it starts even when the service inside never opens
# its port. When that happens, the ONLY unready container is the separate
# service-ready checker, and its own log says "connection refused" or
# similar -- not why the service itself failed. So whenever service-ready
# is unready, every sidecar it is checking is tailed too, regardless of
# that sidecar's own (possibly misleading) ready status.
#
# A container with restartCount > 0 has a lastState.terminated to go with
# that count, but its CURRENT instance -- the one plain `kubectl logs`
# tails -- may not have logged anything yet (freshly restarted, still
# starting, or waiting out CrashLoopBackOff). Whenever restarts > 0, also
# tail `kubectl logs --previous`: that is where the crash the restart count
# and last-exit-code are reporting actually printed its output.
k8s_report_unready_pod() {
    local pod="$1" ready_checks="${2:-}" pod_json
    if ! pod_json="$(kubectl get pod "$pod" -o json --request-timeout=60s 2>/dev/null)"; then
        echo "fork-sandbox-k8s: could not read pod $pod's status for diagnostics." >&2
        return 0
    fi
    local unready
    unready="$(jq -r '
        (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
        | map(select(.ready != true)) | .[].name
    ' <<< "$pod_json" 2>/dev/null || true)"
    if [[ -z "$unready" ]]; then
        echo "fork-sandbox-k8s: pod $pod did not become Ready in time, but every" >&2
        echo "container reports ready -- inspect it with:" >&2
        echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe pod $pod" >&2
        return 0
    fi
    echo "fork-sandbox-k8s: pod $pod did not become Ready in time. Unready container(s):" >&2

    local -a also_tail=()
    if [[ -n "$ready_checks" ]] && grep -qx 'service-ready' <<< "$unready"; then
        local entry svc_name
        for entry in $ready_checks; do
            svc_name="${entry%%:*}"
            grep -qx "$svc_name" <<< "$unready" || also_tail+=("$svc_name")
        done
    fi

    local c restarts reason exit_code
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        restarts="$(jq -r --arg c "$c" '
            (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
            | map(select(.name == $c)) | .[0].restartCount // 0
        ' <<< "$pod_json" 2>/dev/null || echo "?")"
        reason="$(jq -r --arg c "$c" '
            (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
            | map(select(.name == $c))
            | .[0].lastState.terminated.reason // .[0].state.waiting.reason // .[0].state.terminated.reason // "unknown"
        ' <<< "$pod_json" 2>/dev/null || echo "unknown")"
        exit_code="$(jq -r --arg c "$c" '
            (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
            | map(select(.name == $c))
            | .[0].lastState.terminated.exitCode // .[0].state.terminated.exitCode // "n/a"
        ' <<< "$pod_json" 2>/dev/null || echo "n/a")"
        echo "  - $c: restarts=$restarts last-reason=$reason last-exit-code=$exit_code" >&2
        if [[ "$c" == agent ]]; then
            echo "    log tail omitted: the agent container is the one that may hold a" >&2
            echo "    mounted Secret (--context-secret or the claude-token), so its raw log" >&2
            echo "    is never printed here." >&2
        else
            echo "    log tail (kubectl logs $pod -c $c):" >&2
            if ! kubectl logs "$pod" -c "$c" --tail=20 --request-timeout=60s 2>/dev/null \
                    | sed 's/^/      /' >&2; then
                echo "      (no log captured yet)" >&2
            fi
            if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
                echo "    previous log tail (kubectl logs $pod -c $c --previous):" >&2
                if ! kubectl logs "$pod" -c "$c" --previous --tail=20 --request-timeout=60s 2>/dev/null \
                        | sed 's/^/      /' >&2; then
                    echo "      (no previous log captured)" >&2
                fi
            fi
        fi
    done <<< "$unready"

    local a
    for a in "${also_tail[@]}"; do
        restarts="$(jq -r --arg c "$a" '
            (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
            | map(select(.name == $c)) | .[0].restartCount // 0
        ' <<< "$pod_json" 2>/dev/null || echo "?")"
        echo "  - $a: reports ready (restarts=$restarts), but service-ready's own check" >&2
        echo "    did not pass -- $a carries no probe of its own, so a service that" >&2
        echo "    crashed or never opened its port still shows ready:" >&2
        echo "    log tail (kubectl logs $pod -c $a):" >&2
        if ! kubectl logs "$pod" -c "$a" --tail=20 --request-timeout=60s 2>/dev/null \
                | sed 's/^/      /' >&2; then
            echo "      (no log captured yet)" >&2
        fi
        if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
            echo "    previous log tail (kubectl logs $pod -c $a --previous):" >&2
            if ! kubectl logs "$pod" -c "$a" --previous --tail=20 --request-timeout=60s 2>/dev/null \
                    | sed 's/^/      /' >&2; then
                echo "      (no previous log captured)" >&2
            fi
        fi
    done
}

# -- The namespace quota wait ---------------------------------------------
#
# The namespace ResourceQuota (00-namespace.yaml) can be full when submit
# runs. Two refusals both mean "no room yet", not "this run is broken", and
# submit waits on both instead of failing: the per-run claude-proxy Pod's
# create ("forbidden: exceeded quota"), and the Job controller failing to
# create the Job's agent pod (FailedCreate events carrying the same
# message, while no pod for the Job exists). Every other create error stays
# fatal. The wait has its own budget, K8S_QUOTA_WAIT_SECONDS, cumulative
# over the whole submit and apart from the pod-ready budget: expiry is its
# own failure, naming the quota. Quota is not transactional, so the
# pre-check before the proxy Pod only narrows the window in which the proxy
# holds a slot while its agent pod is blocked; it cannot close it.
K8S_QUOTA_NAME=fork-sandbox-quota
K8S_QUOTA_POLL_SECONDS=10
K8S_QW_START=""      # epoch the current quota block began, empty when not blocked
K8S_QW_TOTAL=0       # seconds spent quota-blocked in earlier blocks
K8S_QW_LAST_MSG=""   # epoch of the last progress line

# Prints "<used> <hard>" for the quota's pods, or nothing when the quota
# cannot be read (no such quota, no RBAC to read it): callers treat that as
# "no known limit", never as full.
k8s_quota_pods_state() {
    local out used hard
    out="$(kubectl get resourcequota "$K8S_QUOTA_NAME" \
        -o jsonpath='{.status.used.pods} {.status.hard.pods}' 2>/dev/null)" || return 0
    read -r used hard <<< "$out"
    [[ "$used" =~ ^[0-9]+$ && "$hard" =~ ^[0-9]+$ ]] || return 0
    printf '%s %s\n' "$used" "$hard"
}

# One blocked iteration: fails submit once the budget is spent, prints a
# progress line to stderr at most once a minute, then sleeps. $1 is the
# progress text used when the quota's own numbers cannot be read.
k8s_quota_wait_step() {
    local fallback="$1" now state used hard
    now="$(date +%s)"
    [[ -n "$K8S_QW_START" ]] || K8S_QW_START="$now"
    if (( K8S_QW_TOTAL + now - K8S_QW_START >= K8S_QUOTA_WAIT_SECONDS )); then
        echo "Error: the namespace quota ($K8S_QUOTA_NAME) was full for ${K8S_QUOTA_WAIT_SECONDS}s;" >&2
        echo "gave up waiting for room. Free a slot (remove finished runs), or raise" >&2
        echo "the quota or K8S_QUOTA_WAIT_SECONDS." >&2
        exit 1
    fi
    if [[ -z "$K8S_QW_LAST_MSG" ]] || (( now - K8S_QW_LAST_MSG >= 60 )); then
        state="$(k8s_quota_pods_state)"
        if [[ -n "$state" ]]; then
            read -r used hard <<< "$state"
            echo "fork-sandbox-k8s: waiting for namespace quota: pods $used/$hard" >&2
        else
            echo "fork-sandbox-k8s: waiting for namespace quota: $fallback" >&2
        fi
        K8S_QW_LAST_MSG="$now"
    fi
    sleep "$K8S_QUOTA_POLL_SECONDS"
}

# The block (if any) is over: bank its duration against the budget.
k8s_quota_wait_end() {
    [[ -n "$K8S_QW_START" ]] || return 0
    K8S_QW_TOTAL=$(( K8S_QW_TOTAL + $(date +%s) - K8S_QW_START ))
    K8S_QW_START=""
}

# Waits until the quota has room for $1 more pods (no-op when the quota is
# unreadable).
k8s_quota_wait_for_room() {
    local need="$1" state used hard
    while :; do
        state="$(k8s_quota_pods_state)"
        [[ -n "$state" ]] || break
        read -r used hard <<< "$state"
        (( hard - used >= need )) && break
        k8s_quota_wait_step "pods $used/$hard"
    done
    k8s_quota_wait_end
}

# `kubectl apply` of $1 on stdin-equivalent, retried while the ONLY problem
# is the quota refusal (apply is idempotent, so a retry after a partial
# apply is safe). stdout passes through; any other failure returns kubectl's
# own status after printing its stderr, exactly as a bare apply would.
k8s_apply_waiting_for_quota() {
    local manifest="$1" err rc
    while :; do
        rc=0
        { err="$(printf '%s\n' "$manifest" | kubectl apply -f - 2>&1 1>&3)" || rc=$?; } 3>&1
        [[ -z "$err" ]] || printf '%s\n' "$err" >&2
        if (( rc == 0 )); then
            k8s_quota_wait_end
            return 0
        fi
        if [[ "$err" == *"exceeded quota"* ]]; then
            k8s_quota_wait_step "the run's proxy pod cannot be created"
            continue
        fi
        k8s_quota_wait_end
        return "$rc"
    done
}

# True when Job $1's controller has been refused a pod create for quota.
k8s_job_quota_blocked() {
    local msgs
    msgs="$(kubectl get events \
        --field-selector "involvedObject.kind=Job,involvedObject.name=$1,reason=FailedCreate" \
        -o jsonpath='{.items[*].message}' 2>/dev/null || true)"
    [[ "$msgs" == *"exceeded quota"* ]]
}

cmd_submit() {
    local dry_run=false branch="" model="" review_loop_cap="" outbox_max_arg=""
    local context_ro="" context_secret="" harness="pi" review_model="" endpoint="" checkout_ref=""
    local pi_args="" services_trust_ref="" task_meta="" claude_credentials_flag=""
    local thread_dir="" attach_dir="" image_flag="" run_dir_flag=""
    # Recorded in run.env for `resume` only; submit itself acts on none.
    local outbox_dir="" keep=false run_timeout=3600
    local session_state="" resume_session="" session_id_arg=""
    local refresh_at_arg="" refresh_at_given=false refresh_max_arg=""
    # fs_refresh_resolve sets these; refresh_context_window is rendered into the
    # Job as REFRESH_CONTEXT_WINDOW, which the entrypoint's window warning reads.
    local refresh_at="" refresh_enabled=0 refresh_max="" refresh_context_window=""
    local refresh_threshold_tokens="" refresh_ceiling_tokens=""
    local -a labels_raw=() allow_ns_raw=() reach_probe_raw=() extra_refs_raw=()
    # Internal: set only by fork-sandbox.sh's own --resume orchestration,
    # which is the one caller that deliberately targets a branch it
    # expects to already exist (the moving draft a prior run in the same
    # state dir left behind) -- see fs_check_branch_free's call below.
    local allow_existing_branch=false
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --allow-existing-branch) allow_existing_branch=true; shift ;;
            --checkout) checkout_ref="${2:?--checkout requires a ref}"; shift 2 ;;
            --services-trust-ref) services_trust_ref="${2:?--services-trust-ref requires a ref}"; shift 2 ;;
            --extra-ref) extra_refs_raw+=("${2:?--extra-ref requires NAME=SHA}"); shift 2 ;;
            --model) model="${2:?--model requires an OpenRouter model id}"; shift 2 ;;
            --endpoint) endpoint="${2:?--endpoint requires a name}"; shift 2 ;;
            --image) image_flag="${2:?--image requires an image reference}"; shift 2 ;;
            --harness) harness="${2:?--harness requires a harness}"; shift 2 ;;
            --pi-args) pi_args="${2:?--pi-args requires a value}"; shift 2 ;;
            --review-loop) review_loop_cap="${2:?--review-loop requires a positive integer}"; shift 2 ;;
            --review-model) review_model="${2:?--review-model requires a model id}"; shift 2 ;;
            --outbox-max) outbox_max_arg="${2:?--outbox-max requires a size}"; shift 2 ;;
            --outbox-dir) outbox_dir="${2:?--outbox-dir requires a path}"; shift 2 ;;
            --keep) keep=true; shift ;;
            --timeout) run_timeout="${2:?--timeout requires a number of seconds}"; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; shift 2 ;;
            --context-secret) context_secret="${2:?--context-secret requires a Secret name}"; shift 2 ;;
            --thread-dir) thread_dir="${2:?--thread-dir requires a directory}"; shift 2 ;;
            --attach-dir) attach_dir="${2:?--attach-dir requires a directory}"; shift 2 ;;
            --run-dir) run_dir_flag="${2:?--run-dir requires a directory}"; shift 2 ;;
            --session-state) session_state="${2:?--session-state requires a directory}"; shift 2 ;;
            --resume-session) resume_session="${2:?--resume-session requires a session id}"; shift 2 ;;
            --session-id) session_id_arg="${2:?--session-id requires a session id}"; shift 2 ;;
            --refresh-at) refresh_at_arg="${2:?--refresh-at requires a value}"; refresh_at_given=true; shift 2 ;;
            --refresh-max) refresh_max_arg="${2:?--refresh-max requires a value}"; shift 2 ;;
            --claude-credentials) claude_credentials_flag="${2:?--claude-credentials requires a path}"; shift 2 ;;
            --label) labels_raw+=("${2:?--label requires key=value}"); shift 2 ;;
            --task-meta) task_meta="${2:?--task-meta requires a JSON object}"; shift 2 ;;
            --allow-namespace) allow_ns_raw+=("${2:?--allow-namespace requires NS[:PORT]}"); shift 2 ;;
            --reach-probe) reach_probe_raw+=("${2:?--reach-probe requires HOST:PORT}"); shift 2 ;;
            -*) echo "Error: unknown option '$1' for submit." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"
    local handoff_file="${2:?Usage: fork-sandbox-k8s.sh submit [options] <project-path> <handoff-file>}"

    case "$harness" in
        pi|claude) ;;
        codex)
            if [[ -z "$run_dir_flag" ]]; then
                echo "Error: --harness codex requires a composed --run-dir run;" >&2
                echo "the legacy single-harness entrypoint has no Codex proxy." >&2
                exit 1
            fi
            ;;
        *)
            echo "Error: --harness takes 'pi' or 'claude', not '$harness'." >&2
            exit 1
            ;;
    esac

    # runner mode: a pre-staged run dir, executed rather than built here.
    # pipeline_has_claude/pipeline_pi_models read pipeline.json's own seats
    # (every step and every step's fix seat) rather than --harness/--model,
    # which runner mode does not use the way a single-leg run does -- see
    # --run-dir's own doc comment above for the whole shape. Computed
    # here, early, rather than down among the other optional-directory
    # checks below: the claude-credential gate just below this already
    # reads pipeline_has_claude, under set -u, so it must exist (0/"" when
    # --run-dir was not given) before that point, not merely before the
    # Job is rendered.
    local pipeline_has_claude=0 pipeline_has_codex=0 pipeline_pi_models=""
    if [[ -n "$run_dir_flag" ]]; then
        run_dir_flag="$(validate_run_dir_flag "$run_dir_flag")" || exit 1
        if jq -e '
            ([.steps[] | select(.harness == "claude")]
             + [.steps[] | select(.fix != null and .fix.harness == "claude")])
            | length > 0' "$run_dir_flag/pipeline.json" > /dev/null 2>&1; then
            pipeline_has_claude=1
        fi
        if jq -e '
            ([.steps[] | select(.harness == "codex")]
             + [.steps[] | select(.fix != null and .fix.harness == "codex")])
            | length > 0' "$run_dir_flag/pipeline.json" > /dev/null 2>&1; then
            pipeline_has_codex=1
        fi
        pipeline_pi_models="$(jq -r '
            [.steps[] | select(.harness == "pi") | .model] +
            [.steps[] | select(.fix != null and .fix.harness == "pi") | .fix.model]
            | unique | .[]' "$run_dir_flag/pipeline.json" 2>/dev/null)"
    fi

    # --task-meta never enters the pod -- it is written straight to a file
    # in the run directory, where sandbox-run-log.py's `record` (invoked by
    # cmd_collect) picks it up as the record's `task` object -- so the check
    # it needs is JSON validity, not shell safety, the same rule
    # fork-sandbox.sh's own local --task-meta applies. Compacting to one
    # line here also normalizes whatever whitespace the caller's JSON
    # carried. Validated before anything is created, so a typo fails at
    # once, same as every other pre-creation check in this function.
    if [[ -n "$task_meta" ]]; then
        if ! task_meta="$(printf '%s' "$task_meta" \
            | jq -ce 'if type == "object" then . else halt_error end' 2>/dev/null)"; then
            echo "Error: --task-meta must be one valid JSON object, e.g." >&2
            echo "  --task-meta '{\"kind\":\"implement\",\"difficulty\":3}'" >&2
            echo "See sandbox-run-log.py's header for the recommended fields." >&2
            exit 1
        fi
    fi

    # FORK_SANDBOX_RUN_SOURCE is a token that ends up in the durable run
    # log, not free text: it must be groupable in stats, so it is refused,
    # with a clear message, before the run is created -- the same check
    # fork-sandbox.sh applies to its own local run, repeated here because
    # `fork-sandbox.sh --k8s` execs straight into this script's `run`
    # (scripts/fork-sandbox.sh) ABOVE fork-sandbox.sh's own copy of this
    # check, so neither that script nor a direct `submit`/`run` here would
    # otherwise validate it at all. Checked under LC_ALL=C for the same
    # reason fork-sandbox.sh's copy is: in a UTF-8 locale a [a-z] range
    # matches accented characters, which the recorder's ASCII-only check
    # would then silently reject -- the two gates must refuse exactly the
    # same set.
    if [[ -n "${FORK_SANDBOX_RUN_SOURCE:-}" ]] \
        && (LC_ALL=C; [[ ! "$FORK_SANDBOX_RUN_SOURCE" =~ ^[a-z][a-z0-9-]{0,31}$ ]]); then
        echo "Error: FORK_SANDBOX_RUN_SOURCE is a provenance token that ends up" >&2
        echo "in the run log, so it must start with a lowercase letter and be" >&2
        echo "only lowercase letters, digits and hyphens, at most 32 chars" >&2
        echo "(^[a-z][a-z0-9-]{0,31}$) -- not '$FORK_SANDBOX_RUN_SOURCE'." >&2
        exit 1
    fi

    # --pi-args names pi, which only the pi harness starts -- the same
    # refusal fork-sandbox.sh's own --pi-args applies to its non-pi
    # harnesses, checked here before anything is created.
    if [[ -n "$pi_args" && "$harness" == claude ]]; then
        echo "Error: --pi-args passes flags to pi, which a claude run" >&2
        echo "never starts. Drop it, or use --harness pi." >&2
        exit 1
    fi

    # The named endpoint this run is wired to, on a K8S_PROXY_ENDPOINTS
    # install (see proxy_base_url below, which this resolves into).
    # install is what validates the registry's shape at config-roll time;
    # submit reuses the same parser here so an unregistered --endpoint
    # name is an error now, not a 404 inside the pod.
    # Precedence: an explicit --endpoint wins over K8S_DEFAULT_ENDPOINT
    # in k8s.env, which wins over the one-candidate rule below.
    local proxy_endpoint="" known_endpoint
    if [[ -n "$K8S_PROXY_ENDPOINTS" ]]; then
        parse_proxy_endpoints "$K8S_PROXY_ENDPOINTS" || exit 1
        if [[ -n "$endpoint" ]]; then
            for known_endpoint in "${PROXY_ENDPOINT_NAMES[@]}"; do
                if [[ "$known_endpoint" == "$endpoint" ]]; then
                    proxy_endpoint="$endpoint"
                    break
                fi
            done
            if [[ -z "$proxy_endpoint" ]]; then
                echo "Error: --endpoint '$endpoint' is not registered. The" >&2
                echo "registered endpoints are:" >&2
                printf '%s\n' "${PROXY_ENDPOINT_NAMES[@]}" | sed 's/^/  /' >&2
                exit 1
            fi
        elif [[ -n "$K8S_DEFAULT_ENDPOINT" ]]; then
            # Validated exactly as the flag above: a default naming an
            # unregistered endpoint is a config error that must be loud
            # here, not a silent fallthrough to the one-candidate rule --
            # and the error names k8s.env, because the reader is looking
            # at a command line that never mentions the bad name.
            for known_endpoint in "${PROXY_ENDPOINT_NAMES[@]}"; do
                if [[ "$known_endpoint" == "$K8S_DEFAULT_ENDPOINT" ]]; then
                    proxy_endpoint="$known_endpoint"
                    break
                fi
            done
            if [[ -z "$proxy_endpoint" ]]; then
                echo "Error: K8S_DEFAULT_ENDPOINT '$K8S_DEFAULT_ENDPOINT' in" >&2
                echo "$k8s_env is not registered. The registered endpoints are:" >&2
                printf '%s\n' "${PROXY_ENDPOINT_NAMES[@]}" | sed 's/^/  /' >&2
                exit 1
            fi
            # The single registered endpoint announces itself on the next
            # branch; this one must too -- silent magic in the layer that
            # picks which model answers is not a kindness.
            echo "fork-sandbox-k8s: no --endpoint given; using '$proxy_endpoint'" >&2
            echo "(K8S_DEFAULT_ENDPOINT in $k8s_env)." >&2
        elif (( ${#PROXY_ENDPOINT_NAMES[@]} == 1 )); then
            # The same one-candidate rule agent-sandboxed applies when
            # resolving a model: exactly one choice is usable unnamed,
            # and says so rather than staying silent about it.
            proxy_endpoint="${PROXY_ENDPOINT_NAMES[0]}"
            echo "fork-sandbox-k8s: no --endpoint given; using the single" >&2
            echo "registered endpoint '$proxy_endpoint'." >&2
        else
            echo "Error: this namespace registers more than one endpoint, so" >&2
            echo "one must be named with --endpoint. The registered endpoints" >&2
            echo "are:" >&2
            printf '%s\n' "${PROXY_ENDPOINT_NAMES[@]}" | sed 's/^/  /' >&2
            exit 1
        fi
    elif [[ -n "$endpoint" ]]; then
        echo "Error: --endpoint is not available: this namespace was" >&2
        echo "installed with K8S_PROXY_UPSTREAM; there are no named" >&2
        echo "endpoints." >&2
        exit 1
    elif [[ -n "$K8S_DEFAULT_ENDPOINT" ]]; then
        # Same shape as the --endpoint refusal above: a legacy install has
        # no named endpoints, so a default naming one is a config error,
        # not something to ignore.
        echo "Error: K8S_DEFAULT_ENDPOINT is not available: this namespace was" >&2
        echo "installed with K8S_PROXY_UPSTREAM; there are no named" >&2
        echo "endpoints." >&2
        exit 1
    fi

    # --model stays required on a legacy K8S_PROXY_UPSTREAM install, where
    # there is no model to discover. On a K8S_PROXY_ENDPOINTS install it is
    # optional -- the pod discovers it from the proxy's /v1/models at
    # startup (fork-sandbox-k8s-entrypoint.sh) -- with one carve-out:
    # --harness claude, because discovery lists the pi endpoint's model
    # ids, never a Claude Code model name.
    if [[ -n "$run_dir_flag" ]]; then
        : # A composed runner uses each seat's own model, not this record field.
    elif [[ -z "$K8S_PROXY_ENDPOINTS" ]]; then
        if [[ -z "$model" && -n "$K8S_DEFAULT_MODEL" ]]; then
            # Same shape as the K8S_DEFAULT_ENDPOINT refusal above: a
            # legacy install has no model discovery for K8S_DEFAULT_MODEL
            # to stand in for, so naming it here is a config error, not
            # something to ignore -- an error claiming "there is no
            # default" while k8s.env sets one would contradict the
            # operator's own config file.
            echo "Error: K8S_DEFAULT_MODEL is not available: this namespace" >&2
            echo "was installed with K8S_PROXY_UPSTREAM, which has no model" >&2
            echo "discovery for K8S_DEFAULT_MODEL to stand in for. Pass" >&2
            echo "--model explicitly." >&2
            exit 1
        fi
        [[ -n "$model" ]] || { echo "Error: submit requires --model. There is no default:" >&2
            echo "the model is an OpenRouter id, such as moonshotai/kimi-k3." >&2; exit 1; }
    elif [[ -z "$model" && "$harness" == claude ]]; then
        echo "Error: --harness claude requires --model even on a" >&2
        echo "K8S_PROXY_ENDPOINTS install -- the pod's model discovery" >&2
        echo "lists the pi endpoint's model ids, not Claude Code model" >&2
        echo "names." >&2
        exit 1
    elif [[ -z "$model" && -n "$K8S_DEFAULT_MODEL" ]]; then
        # Same precedence shape as K8S_DEFAULT_ENDPOINT one layer up:
        # --model wins, then this key, then the pod's own single-candidate
        # discovery rule (fork-sandbox-k8s-entrypoint.sh), which only runs
        # when MODEL still arrives at the pod empty. The claude-harness
        # branch above must stay ahead of this one, so a claude run still
        # requires --model even with K8S_DEFAULT_MODEL set.
        model="$K8S_DEFAULT_MODEL"
        echo "fork-sandbox-k8s: no --model given; using '$model'" >&2
        echo "(K8S_DEFAULT_MODEL in $k8s_env)." >&2
    fi
    branch="${branch:-k8s-$(date +%Y%m%d-%H%M%S)}"
    # checkout_ref is caller-supplied and interpolated into a git command
    # line below (the push refspec), so it gets the same treatment as
    # branch and model: rejected before anything is created. pi_args is
    # caller-supplied command-line text that becomes arguments for the
    # pod's pi invocation, so it is refused by the same guard here, plus
    # the double quote and backslash, rather than anywhere pod-side.
    fs_reject_unsafe_chars "$branch" "$model" "$checkout_ref" "$pi_args" \
        "$services_trust_ref" || exit 1

    # Re-validated independently here, the same defense-in-depth rule
    # every other flag in this function follows (branch/model/checkout_ref
    # above, claude_credentials_flag below): fork-sandbox.sh already ran
    # this exact check before dispatch, but cmd_submit is directly
    # callable (the postmaster calls it without going through
    # fork-sandbox.sh at all), so the identical refusal must run again
    # here, before anything is created. See fs_validate_session_flags in
    # fork-sandbox-lib.sh.
    session_state="$(fs_validate_session_flags "$harness" "$session_state" \
        "$resume_session" "$session_id_arg")" || exit 1

    # One resolver shared with the local runner: same defaults (claude 0.5),
    # same refusals (pi), same threshold arithmetic. Sets refresh_enabled,
    # refresh_max and refresh_threshold_tokens for the Job env, ConfigMap
    # keys and run.env below.
    fs_refresh_resolve "$harness" "$refresh_at_arg" "$refresh_at_given" \
        "$refresh_max_arg" "$model" || exit 1

    # The session store's size cap is checked here, right after validation,
    # rather than at push time (where it used to live): the SESSION_HARNESS_
    # STORE/RESUME_SESSION/SESSION_ID env block below and run.env further
    # down both bake $session_state's presence in well before push, so a
    # decision made at push time is too late to keep either in sync.
    # Skipped under --dry-run, which creates and contacts nothing -- the
    # mkdir below would otherwise break that contract; a real submit still
    # catches an oversized store here, before anything is created in the
    # cluster. mkdir+chmod here (not any earlier) for the same reason: session_
    # state was only validated (not created) by fs_validate_session_flags
    # above, the same "nothing is created before --dry-run's exit" rule
    # every other flag in this function follows. Same 0700 rule as the local
    # path's equivalent (fork-sandbox.sh, session_state block): the store
    # holds a whole conversation transcript.
    #
    # A store over the cap does not fail the run: the design here is
    # "warned, not fixed" (a store this large loses k8s continuity, not the
    # run) -- refusing outright would wedge every later wake of a seat once
    # its store, which only grows, crosses the cap. So this run proceeds
    # without session continuity instead: no push below, and no session_state
    # in run.env, so cmd_collect will not pull either.
    local session_tar="" session_size=""
    if [[ -n "$session_state" && "$dry_run" != true ]]; then
        mkdir -p -- "$session_state"
        chmod 700 -- "$session_state"
        session_tar="$(mktemp)"
        K8S_SUBMIT_SESSION_TAR="$session_tar"
        trap 'rm -f -- "${K8S_SUBMIT_SESSION_TAR:-}"' EXIT
        tar cf "$session_tar" -C "$session_state" .
        session_size="$("$FS_STAT" -c '%s' -- "$session_tar")"
        if (( session_size > CONTEXT_MAX_BYTES )); then
            echo "Warning: --session-state directory '$session_state' tars to" >&2
            echo "$session_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap. Running this wake without session" >&2
            echo "continuity -- see docs/kubernetes-runs.md." >&2
            rm -f -- "$session_tar"
            K8S_SUBMIT_SESSION_TAR=""
            session_tar=""
            session_state=""
            resume_session=""
            session_id_arg=""
        fi
    fi
    # pi_args is additionally embedded in the rendered Job's PI_ARGS env
    # var as a YAML double-quoted scalar, so a double quote or a
    # backslash is refused on top of the guard above: an unescaped quote
    # would end the scalar and leave a manifest that dies at kubectl
    # apply instead of at this parse-time refusal, and a backslash is an
    # escape the YAML parser rewrites -- "a\nb" would reach pi as "a"
    # plus a real newline, and the entrypoint's whitespace split would
    # then drop the rest, wrong output with no diagnostic anywhere.
    local backslash=$'\\'
    if [[ "$pi_args" == *'"'* || "$pi_args" == *"$backslash"* ]]; then
        echo "Error: --pi-args must not contain a double quote or a" >&2
        echo "backslash: it is embedded in the rendered Job's PI_ARGS env" >&2
        echo "var as a double-quoted YAML scalar, where either changes" >&2
        echo "what pi receives." >&2
        exit 1
    fi

    # --review-loop takes a positive integer, the same shape and the same
    # message fork-sandbox.sh's own local flag uses, so a bad value reads
    # the same regardless of which path a caller is on. review_loop_cap
    # starts empty (flag not given) rather than "0", so that "--review-loop
    # 0" -- a real value, not the same thing as omitting the flag -- is
    # caught here instead of silently collapsing into "no loop".
    if [[ -n "$review_loop_cap" && ! "$review_loop_cap" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: --review-loop takes a positive integer — the maximum" >&2
        echo "number of review-then-fix iterations — not '$review_loop_cap'." >&2
        exit 1
    fi
    local review_loop_recorded="$review_loop_cap"
    review_loop_cap="${review_loop_cap:-0}"
    if [[ ! "$run_timeout" =~ ^[0-9]+$ ]]; then
        echo "Error: --timeout must be a whole number of seconds, got '$run_timeout'." >&2
        exit 1
    fi

    # Resolved here, before anything is created, same as the checks above --
    # fs_parse_size_bytes already prints its own error naming what was given.
    local outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    if [[ -n "$outbox_max_arg" ]]; then
        outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
    fi

    [[ -n "$review_model" ]] && { fs_reject_unsafe_chars "$review_model" || exit 1; }

    # The same cross-check fork-sandbox-k8s-entrypoint.sh enforces pod-side
    # (HARNESS=claude and REVIEW_LOOP_CAP set but REVIEW_MODEL empty),
    # checked here too so a caller of this direct entry point -- not just
    # fork-sandbox.sh --k8s, which already guarantees it -- fails before the
    # proxy Pod, the token Secret, the Job and a full repository push all
    # happen for a run that can only fail once the pod starts.
    if [[ "$harness" == claude && $review_loop_cap -gt 0 && -z "$review_model" ]]; then
        echo "Error: --review-model is required with --harness claude" >&2
        echo "--review-loop -- the review loop always runs pi, and --model" >&2
        echo "is a Claude Code model name pi cannot use." >&2
        exit 1
    fi

    # The operator's own OAuth credential, for --harness claude only --
    # read and validated here, before anything is created, the same rule
    # every other pre-creation check in this function follows. Read once;
    # both the per-run Secret below (the real access token, for the proxy)
    # and the ConfigMap's placeholder credential (the sanitized JSON, for
    # the pod's claude CLI) come from this single read. This is a local
    # file read (or, on macOS, a Keychain read), so it runs even under
    # --dry-run -- no cluster is contacted, exactly like every other
    # validation in this function that --dry-run is meant to exercise.
    #
    # Precedence: --claude-credentials > CLAUDE_CREDENTIALS in claude.env >
    # a launcher-balanced pool choice (fs_balance_claude_credential) >
    # today's default -- the same chain fork-sandbox.sh's own local path
    # resolves, sharing fs_balance_claude_credential itself so the pool/hook
    # config and its error checks cannot drift between the two entry
    # points, while the precedence glue around it is deliberately
    # duplicated rather than factored into a second shared function (see
    # fs_balance_claude_credential's own header comment).
    local claude_cred_json="" claude_access_token="" claude_configmap_cred=""
    local codex_key_conf="" codex_auth_path=""
    if (( pipeline_has_codex )); then
        codex_auth_path="${CODEX_HOME:-$HOME/.codex}/auth.json"
        if [[ ! -f "$codex_auth_path" ]]; then
            echo "Error: a composed Codex seat needs host Codex sign-in." >&2
            exit 1
        fi
        if [[ "$dry_run" != true ]]; then
            if ! python3 "$script_dir/fork-sandbox-codex-refresh.py" "$codex_auth_path"; then
                echo "Error: the host Codex access token could not be refreshed." >&2
                exit 1
            fi
        fi
        if ! codex_key_conf="$(k8s_render_codex_key_conf "$codex_auth_path")"; then
            echo "Error: host Codex auth needs an access token and account id." >&2
            exit 1
        fi
    fi
    local claude_credentials_override="" claude_credentials_via="default"
    if [[ -n "$claude_credentials_flag" && "$harness" != claude \
        && "$pipeline_has_claude" != 1 ]]; then
        # A typo in --claude-credentials is refused here too, even though
        # this harness will never read the file -- the same "fail loud
        # rather than silently drop it" rule fork-sandbox.sh's own two
        # entry points apply to this identical flag (see the comment on
        # the "flag" branch below). Without this, the flag would carry two
        # opposite meanings across the pair of call sites this round exists
        # to keep from drifting.
        fs_reject_unsafe_chars "$claude_credentials_flag" || exit 1
        local claude_credentials_flag_resolved
        claude_credentials_flag_resolved="$("$FS_REALPATH" -m "$claude_credentials_flag")"
        if [[ ! -f "$claude_credentials_flag_resolved" ]]; then
            echo "Error: --claude-credentials names" >&2
            echo "'$claude_credentials_flag_resolved', which does not exist." >&2
            exit 1
        fi
    fi
    if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
        local claude_credentials_config
        claude_credentials_config="$(read_env_value "$claude_env" CLAUDE_CREDENTIALS || true)"
        if [[ -n "$claude_credentials_flag" ]]; then
            claude_credentials_override="$claude_credentials_flag"
            # A bare flag means "flag" for a caller invoking this script
            # directly. But fork-sandbox.sh --k8s forwards its OWN already-
            # resolved choice as this same flag (see the comment above its
            # exec), and that choice may really have come from
            # CLAUDE_CREDENTIALS or the balancer -- FORK_SANDBOX_CLAUDE_
            # CREDENTIALS_VIA is that launcher's internal handoff of the true
            # source, so the ledger keeps per-account attribution instead of
            # flattening every delegated run to "flag".
            local via_env="${FORK_SANDBOX_CLAUDE_CREDENTIALS_VIA:-flag}"
            case "$via_env" in
                flag | claude-env | balance) claude_credentials_via="$via_env" ;;
                *) claude_credentials_via="flag" ;;
            esac
        elif [[ -n "${FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED:-}" ]]; then
            # fork-sandbox.sh --k8s already ran this exact precedence chain,
            # balancer included, before delegating here (see the exec site);
            # an empty claude_credentials_flag then means it fell through to
            # today's default. Running fs_balance_claude_credential again
            # here would invoke the operator's headroom hook a second time
            # for one run, which is the one thing the launcher's own forward
            # is meant to prevent.
            claude_credentials_via="default"
        else
            # Called unconditionally, not gated on claude_credentials_config
            # being empty -- fs_balance_claude_credential also validates
            # that CLAUDE_CREDENTIALS and the pool keys are not BOTH set,
            # so a misconfigured claude.env is refused loudly rather than
            # having the pin silently win.
            local claude_balance_out=""
            if claude_balance_out="$(fs_balance_claude_credential "$config_dir" "$script_dir")"; then
                if [[ -n "$claude_balance_out" ]]; then
                    claude_credentials_override="$claude_balance_out"
                    claude_credentials_via="balance"
                elif [[ -n "$claude_credentials_config" ]]; then
                    claude_credentials_override="$claude_credentials_config"
                    claude_credentials_via="claude-env"
                fi
            else
                # fs_balance_claude_credential already printed the specific error.
                exit 1
            fi
        fi

        if [[ -n "$claude_credentials_override" ]]; then
            fs_reject_unsafe_chars "$claude_credentials_override" || exit 1
            # Resolved to an absolute path here, before the existence check
            # below, the same reason fork-sandbox.sh's own local path
            # resolves its equivalent ahead of its own existence check: a
            # relative path stored verbatim would read differently
            # depending on the caller's cwd once it is recorded into
            # run.env/summary.json.
            claude_credentials_override="$("$FS_REALPATH" -m "$claude_credentials_override")"
            if [[ "$claude_credentials_via" == "flag" \
                && ! -f "$claude_credentials_override" ]]; then
                echo "Error: --claude-credentials names" >&2
                echo "'$claude_credentials_override', which does not exist." >&2
                exit 1
            elif [[ "$claude_credentials_via" == "balance" \
                && ! -f "$claude_credentials_override" ]]; then
                # The balancer's choice is an operator-authored pool entry,
                # same rule as the explicit flag above: a balanced choice
                # naming a missing file is this run's problem to raise, not
                # to swallow.
                echo "Error: the credential balancer chose" >&2
                echo "'$claude_credentials_override', which does not exist." >&2
                echo "Fix the pool entry in $claude_env, or pin" >&2
                echo "--claude-credentials to override the balancer." >&2
                exit 1
            elif [[ "$claude_credentials_via" == "claude-env" \
                && ! -f "$claude_credentials_override" ]]; then
                echo "Error: CLAUDE_CREDENTIALS in $claude_env names" >&2
                echo "'$claude_credentials_override', which does not exist." >&2
                exit 1
            fi
        fi

        # Refresh the HOST's credential first, before it is even read below,
        # exactly as claude-sandboxed's own pre-step does for a local run:
        # the whole point is to refresh a token close to expiry rather than
        # copy one into the run that is about to be revoked. A cluster run
        # can span hours, well past FS_CLAUDE_REFRESH_BEFORE_MIN (2h) --
        # unlike the sandboxed path, there is no live-sync loop yet at this
        # point in submit; that gap is what the keeper cmd_wait starts below
        # closes for the rest of the run's lifetime (see
        # k8s_claude_keeper_start). claude_cred_file is empty for a
        # Keychain-backed credential, which -- like a missing host claude
        # binary -- makes both the contract check and the refresh silent
        # no-ops, same as claude-sandboxed. Resolved the same way
        # claude-sandboxed resolves HOST_CLAUDE_BIN: PATH, then
        # ~/.local/bin/claude, then resolved to an absolute path to survive
        # a relative PATH entry across the refresh's own cd -- via
        # $FS_REALPATH (no flags: every path component here already
        # exists), not a raw GNU readlink call, since fork-sandbox-lib.sh's
        # shim is already sourced by this point.
        local host_claude_bin claude_cred_file
        host_claude_bin="$(command -v claude 2>/dev/null || true)"
        if [[ -z "$host_claude_bin" && -x "$HOME/.local/bin/claude" ]]; then
            host_claude_bin="$HOME/.local/bin/claude"
        fi
        if [[ "$host_claude_bin" == */* ]]; then
            host_claude_bin="$("$FS_REALPATH" "$host_claude_bin" 2>/dev/null || true)"
        fi
        claude_cred_file="$(fs_claude_credential_file "$claude_credentials_override")" || claude_cred_file=""
        if [[ -n "$claude_cred_file" && -n "$host_claude_bin" ]]; then
            fs_claude_token_contract_check "$host_claude_bin" "$script_dir/fork-sandbox-claude-token-probe"
            fs_claude_refresh_if_needed "$claude_cred_file" "$host_claude_bin"
        fi

        claude_cred_json="$(fs_read_claude_credential "$claude_credentials_override")" || exit 1

        # The pod itself still cannot refresh the token -- but a run that
        # outlives it no longer dies partway through, as long as `wait`,
        # `run` or `resume` stays running: the keeper cmd_wait starts (see
        # k8s_claude_keeper_start) pushes a fresh token to the per-run proxy
        # whenever the host's own copy changes, for as long as that command
        # blocks. This warning is worded accordingly; the two hard refusals
        # below are unchanged -- a token already too close to expiry to
        # survive submit itself is refused outright, keeper or not.
        # Piped with printf, never a here-string: on bash before 5.1 a
        # here-string spills its value to a temp file, and this one holds
        # the live token. Same rule as fs_read_claude_credential's header.
        local claude_expires_at_ms claude_mins_left
        claude_expires_at_ms="$(printf '%s' "$claude_cred_json" | jq -r '.claudeAiOauth.expiresAt // 0')"
        claude_mins_left=$(( claude_expires_at_ms / 60000 - $(date +%s) / 60 ))
        if (( claude_mins_left <= 0 )); then
            echo "Error: the access token in $(fs_claude_credential_source "$claude_credentials_override") has expired." >&2
            echo "Log in with claude on the host, then retry." >&2
            exit 1
        elif (( claude_mins_left < 5 )); then
            echo "Error: the access token in $(fs_claude_credential_source "$claude_credentials_override") expires in ${claude_mins_left}m." >&2
            echo "The pod cannot refresh the token, so the pod's session would die almost at once. Log in with claude on the host, then retry." >&2
            exit 1
        elif (( claude_mins_left < 60 )); then
            if [[ -n "$claude_cred_file" && -n "$host_claude_bin" ]]; then
                echo "Warning: the access token expires in ${claude_mins_left}m; the keeper started by wait/run/resume will refresh it on the host before then." >&2
            else
                echo "Warning: the access token expires in ${claude_mins_left}m; the pod's session dies then." >&2
            fi
        fi

        claude_access_token="$(printf '%s' "$claude_cred_json" | jq -r '.claudeAiOauth.accessToken // empty')"
        if [[ -z "$claude_access_token" ]]; then
            echo "Error: $(fs_claude_credential_source "$claude_credentials_override") has no claudeAiOauth.accessToken." >&2
            exit 1
        fi
        fs_reject_unsafe_chars "$claude_access_token" || exit 1
        reject_nginx_unsafe_chars "$claude_access_token" \
            "the access token in $(fs_claude_credential_source "$claude_credentials_override")" || exit 1

        # The placeholder credential shipped into the pod's ConfigMap: the
        # same sanitizing jq claude-sandboxed applies to a local sandbox's
        # copy (drop mcpOAuth, and the refresh token and its expiry -- the
        # pod needs and may hold neither), plus one substitution unique to
        # this path -- the real access token becomes the literal string
        # "sandbox", since Claude Code accepts any placeholder locally and
        # the proxy supplies the real bearer on the way past. After this
        # substitution the file holds no secret (just scopes, subscription
        # type, expiry), which is what makes a ConfigMap -- not a Secret --
        # the right place for it. A `claude setup-token` credential has no
        # scopes, and a CLI that finds none reports "Not logged in" before
        # any request, so the placeholder supplies the inference scope.
        # expiresAt is pushed far out: the proxy's keeper owns the real
        # token's lifetime, and a placeholder that inherited the host
        # token's expiry would read as expired to the pod's claude, with no
        # refresh token to recover from, while the proxy's key is still good.
        claude_configmap_cred="$(printf '%s' "$claude_cred_json" | jq \
            --argjson exp "$K8S_PLACEHOLDER_EXPIRES_AT_MS" '
            del(.mcpOAuth)
            | del(.claudeAiOauth.refreshToken, .claudeAiOauth.refreshTokenExpiresAt)
            | .claudeAiOauth.accessToken = "sandbox"
            | .claudeAiOauth.expiresAt = $exp
            | .claudeAiOauth.scopes //= ["user:inference"]
        ')"
    fi

    # The same rule fork-sandbox.sh's own local --context-ro flag applies to
    # its --bind-ro (scripts/fork-sandbox.sh, around the FS_REALPATH check
    # near its argument validation): the directory's real path must be
    # under /var/tmp/claude-scratch/forks/, and it must exist. Checked here,
    # ahead of --dry-run's early exit below, so a bad path is refused with
    # no cluster involved -- the size cap, which needs an actual tar of the
    # directory, is checked later, alongside the real push, which --dry-run
    # never reaches. Extracted into validate_context_ro_dir above so
    # check-grant can run the identical check with no cluster.
    if [[ -n "$context_secret" ]]; then
        [[ -z "$context_ro" ]] || refuse_context_secret_with_ro
        validate_context_secret_name "$context_secret"
    fi
    if [[ -n "$context_ro" ]]; then
        context_ro="$(validate_context_ro_dir "$context_ro")" || exit 1
    fi

    # --thread-dir/--attach-dir use fs_validate_scratch_dir's rule, not
    # --context-ro's: the postmaster stages these under its mail root,
    # which is under the scratch root but not under forks/, so
    # --context-ro's forks/-only rule would refuse every real wake. Plus
    # the same symlink/hard-link refusals --context-ro applies above,
    # via k8s_refuse_dir_links -- refused here, before any cluster object
    # exists, even though the pod-side extractor refuses them too.
    if [[ -n "$thread_dir" ]]; then
        thread_dir="$(fs_validate_scratch_dir "$thread_dir" --thread-dir)" || exit 1
        if [[ ! -d "$thread_dir" ]]; then
            echo "Error: --thread-dir directory '$thread_dir' does not exist." >&2
            exit 1
        fi
        k8s_refuse_dir_links "$thread_dir" --thread-dir || exit 1
    fi
    if [[ -n "$attach_dir" ]]; then
        attach_dir="$(fs_validate_scratch_dir "$attach_dir" --attach-dir)" || exit 1
        if [[ ! -d "$attach_dir" ]]; then
            echo "Error: --attach-dir directory '$attach_dir' does not exist." >&2
            exit 1
        fi
        k8s_refuse_dir_links "$attach_dir" --attach-dir || exit 1
    fi

    if [[ ! -d "$project_path" ]]; then
        echo "Error: project path '$project_path' is not a directory." >&2
        exit 1
    fi
    local origin_repo
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1
    # --allow-existing-branch skips this: fast-forward-only is enforced at
    # fetch-back time instead (cmd_fetch's own non-force refspec), which is
    # the property a continuation actually needs -- the branch being
    # already there is the point, not a collision.
    $allow_existing_branch || fs_check_branch_free "$origin_repo" "$branch" || exit 1

    # The pod image for this run: --image, then K8S_PROJECT_IMAGES's entry
    # for this project's basename, then K8S_IMAGE -- see resolve_run_image's
    # own header. Resolved here, right after origin_repo is known, and before
    # the K8S_IMAGE requirement below, which this resolution makes
    # conditional: a project with its own image needs no K8S_IMAGE at all.
    local RUN_IMAGE="" RUN_IMAGE_SOURCE=""
    resolve_run_image "$image_flag" "$(basename "$origin_repo")" || exit 1

    # --checkout names the commit the branch starts from instead of the
    # repo's HEAD. Resolved to a sha here, before the Job, the Secret and
    # the proxy Pod exist, for the same reason every other pre-creation
    # check in this function runs: an unresolvable ref must fail now, not
    # after cluster objects for a run that cannot work already exist. The
    # sha is also what the push below sends, so the ref cannot move
    # between this check and the push, and the pushed revision is the one
    # the push line reports and (under --review-loop) the base the review
    # leg measures against.
    local checkout_sha=""
    if [[ -n "$checkout_ref" ]]; then
        if ! checkout_sha="$(cd "$origin_repo" && git rev-parse --verify --quiet "$checkout_ref^{commit}" 2>/dev/null)"; then
            echo "Error: --checkout '$checkout_ref' does not name a commit in $origin_repo." >&2
            exit 1
        fi
    fi

    # --extra-ref NAME=SHA: each entry is checked before the Job, the Secret
    # and the proxy Pod exist, for the same reason --checkout is above. NAME
    # becomes a branch in the pod's repo and, in the entrypoint, a local
    # branch, so its shape is pinned (under LC_ALL=C, like
    # FORK_SANDBOX_RUN_SOURCE above: in a UTF-8 locale [a-z] matches accented
    # characters) and it may not be the run's own branch or a repeat; SHA
    # must already be a commit in the origin repo, since the push below sends
    # it from there.
    local -a extra_ref_names=() extra_ref_shas=()
    local extra_ref er_name er_sha er_seen
    for extra_ref in "${extra_refs_raw[@]}"; do
        if [[ "$extra_ref" != *=* ]]; then
            echo "Error: --extra-ref '$extra_ref' must look like NAME=SHA." >&2
            exit 1
        fi
        er_name="${extra_ref%%=*}"
        er_sha="${extra_ref#*=}"
        if ! (LC_ALL=C; [[ "$er_name" =~ ^[a-z][a-z0-9-]{0,30}$ ]]); then
            echo "Error: --extra-ref name '$er_name' must match ^[a-z][a-z0-9-]{0,30}\$." >&2
            exit 1
        fi
        if [[ "$er_name" == "$branch" ]]; then
            echo "Error: --extra-ref name '$er_name' is this run's own branch." >&2
            exit 1
        fi
        for er_seen in "${extra_ref_names[@]}"; do
            if [[ "$er_seen" == "$er_name" ]]; then
                echo "Error: --extra-ref name '$er_name' was given twice." >&2
                exit 1
            fi
        done
        if ! (LC_ALL=C; [[ "$er_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]); then
            echo "Error: --extra-ref '$er_name': '$er_sha' must be a full 40- or 64-character" >&2
            echo "lowercase hex commit sha." >&2
            exit 1
        fi
        if ! (cd "$origin_repo" && git cat-file -e "$er_sha^{commit}" 2>/dev/null); then
            echo "Error: --extra-ref '$er_name': '$er_sha' does not name a commit in $origin_repo." >&2
            exit 1
        fi
        extra_ref_names+=("$er_name")
        extra_ref_shas+=("$er_sha")
    done

    # Per-run services: a repo commits a SPEC, never a hook, so the harness
    # (not repo-controlled code) synthesizes the sidecars from it -- see
    # docs/sandbox-services.md's cluster section. Read from the EXACT
    # revision being pushed (never the working tree, which under
    # --checkout may not even be at that revision) so an operator's own
    # dirty tree cannot influence what a pinned run gets. Absent file
    # means no services and no behaviour change -- silent, not a warning,
    # since that is the case every existing repo is in.
    local services_rev="${checkout_sha:-HEAD}"
    local services_containers="" services_volumes=""
    local services_grace_env="" services_prompt_text="" sandbox_env_content=""
    local sandbox_env_present=0
    # SERVICE_READY_CHECKS for fork-sandbox-k8s-service-ready.sh
    # ("name:port:seconds", space-separated) and the longest window among
    # them, 0 when no service declares a readyWhen -- cmd_submit's
    # pod_budget (below) must cover at least this, and the service-ready
    # initContainer is rendered only when this is non-empty.
    local services_ready_checks="" services_ready_max=0
    if git -C "$origin_repo" cat-file -e \
            "${services_rev}:.agents/sandbox-services/services.yaml" 2>/dev/null; then
        # --services-trust-ref gates this exactly as the local path's hook
        # is gated (fork-sandbox.sh:3546-3604): a checkout that changed
        # .agents/sandbox-services/ relative to the given ref does not get
        # services. Data is still input to an apply made with the
        # operator's credentials.
        local services_trusted=1
        if [[ -n "$checkout_ref" && -z "$services_trust_ref" ]]; then
            echo "Warning: --checkout names an unanchored ref, so its" >&2
            echo "per-run services spec is NOT used -- the spec is data" >&2
            echo "the operator's own apply acts on, and the ref may be" >&2
            echo "untrusted. Pass --services-trust-ref <trusted-base> to" >&2
            echo "enable it." >&2
            services_trusted=0
        elif [[ -n "$services_trust_ref" ]]; then
            local trust_compare_sha="${checkout_sha:-$(cd "$origin_repo" && git rev-parse HEAD)}"
            local trust_diff_rc=0
            (cd "$origin_repo" && git diff --quiet \
                "${services_trust_ref}...${trust_compare_sha}" \
                -- .agents/sandbox-services/) || trust_diff_rc=$?
            if (( trust_diff_rc == 1 )); then
                echo "Warning: the checked-out ref changes" >&2
                echo ".agents/sandbox-services/ relative to the trusted" >&2
                echo "base, so per-run services are disabled for this run." >&2
                services_trusted=0
            elif (( trust_diff_rc != 0 )); then
                echo "Error: git could not evaluate --services-trust-ref" >&2
                echo "'$services_trust_ref' against '$trust_compare_sha'" >&2
                echo "(git exited $trust_diff_rc; its error is above)." >&2
                exit 1
            fi
        fi

        if (( services_trusted )); then
            local services_dir
            services_dir="$(mktemp -d)"
            local services_spec_file="$services_dir/services.yaml"
            git -C "$origin_repo" show \
                "${services_rev}:.agents/sandbox-services/services.yaml" \
                > "$services_spec_file"
            local services_out="$services_dir/out"
            if ! python3 "$script_dir/fork-sandbox-k8s-services-parse.py" \
                    "$services_spec_file" "$services_out" "$K8S_SERVICES_MAX" \
                    "$K8S_SERVICE_MAX_CPU" "$K8S_SERVICE_MAX_MEMORY" \
                    "$K8S_SERVICE_MAX_STARTUP_SECONDS"; then
                rm -rf -- "$services_dir"
                exit 1
            fi
            # Everything needed is read into shell variables here, and the
            # temp dir removed immediately after -- nothing below this
            # block depends on it, so there is no cleanup to defer onto an
            # EXIT trap (this function already juggles more than one of
            # those further down, each of which replaces the last).
            [[ -f "$services_out/containers.yaml" ]] && \
                services_containers=$'\n'"$(cat "$services_out/containers.yaml")"
            [[ -f "$services_out/volumes.yaml" ]] && \
                services_volumes=$'\n'"$(cat "$services_out/volumes.yaml")"
            [[ -f "$services_out/grace" ]] && \
                services_grace_env=$'\n'"      terminationGracePeriodSeconds: 10"
            [[ -f "$services_out/prompt-services.txt" ]] && \
                services_prompt_text="$(cat "$services_out/prompt-services.txt")"
            if [[ -f "$services_out/sandbox-env" ]]; then
                sandbox_env_present=1
                sandbox_env_content="$(cat "$services_out/sandbox-env")"
            fi
            if [[ -f "$services_out/ready-checks" ]]; then
                local rc_name rc_port rc_seconds
                while read -r rc_name rc_port rc_seconds; do
                    [[ -n "$rc_name" ]] || continue
                    services_ready_checks+="${services_ready_checks:+ }$rc_name:$rc_port:$rc_seconds"
                    (( rc_seconds > services_ready_max )) && services_ready_max=$rc_seconds
                done < "$services_out/ready-checks"
            fi
            rm -rf -- "$services_dir"
        fi
    fi

    # base_sha, the review skill and the loop script itself are only needed
    # under --review-loop, but resolved here, before anything is created,
    # so a missing one fails now rather than after the pod is up.
    local base_sha="" review_skill_src="" review_loop_sh="$script_dir/fork-sandbox-k8s-review-loop.sh"
    if (( review_loop_cap > 0 )); then
        # submit pushes the branch's starting revision -- this repo's
        # current HEAD, or the commit --checkout names when one is given
        # (resolved to a sha above) -- as the branch's starting point
        # (see the push below), so that revision is the base the review
        # leg's commit range is measured from.
        if [[ -n "$checkout_ref" ]]; then
            base_sha="$checkout_sha"
        elif ! base_sha="$(cd "$origin_repo" && git rev-parse HEAD 2>/dev/null)"; then
            echo "Error: could not read HEAD in $origin_repo. --review-loop" >&2
            echo "needs the commit the branch is measured against, and submit" >&2
            echo "pushes this repo's current HEAD as that base." >&2
            exit 1
        fi

        # The review leg's method. Read from this repo's own skills/, never
        # from ~/.claude/skills/ -- that path is a symlink into this repo on
        # a machine that has run install.sh, and would not exist elsewhere.
        review_skill_src="$(dirname "$script_dir")/skills/code-review-portable/SKILL.md"
        if [[ ! -f "$review_skill_src" ]]; then
            echo "Error: --review-loop needs the code-review-portable skill, which" >&2
            echo "is the review leg's method, and $review_skill_src" >&2
            echo "is not there. Run this from a fork-sandbox checkout." >&2
            exit 1
        fi
    fi

    # The upstream the branch this run creates should track, resolved once,
    # here, in the same repo --checkout was resolved in -- HEAD in
    # $origin_repo can move while the run is in flight on the cluster, so
    # this must not be re-derived at collect or fetch time. Recorded in
    # run.env below for cmd_collect to read back and hand to cmd_fetch; a
    # standalone fetch with no run.env in scope resolves it itself instead
    # (rules 3-5, no checkout ref).
    local upstream_errf upstream="" upstream_reason=""
    upstream_errf="$(mktemp)"
    upstream="$(fs_resolve_upstream "$origin_repo" "$checkout_ref" 2>"$upstream_errf")"
    upstream_reason="$(cat "$upstream_errf")"
    rm -f "$upstream_errf"

    if [[ ! -f "$handoff_file" ]]; then
        echo "Error: handoff file '$handoff_file' not found." >&2
        exit 1
    fi
    if [[ ! -s "$handoff_file" ]]; then
        echo "Error: handoff file '$handoff_file' is empty. It is the run's" >&2
        echo "whole prompt." >&2
        exit 1
    fi
    # Advisory only, same rule as the local runner's: a brief that already
    # eats a large share of a leg's own working budget is the single
    # biggest cause of a chain that nudges repeatedly and commits nothing.
    if (( refresh_enabled )); then
        local brief_warning
        brief_warning="$(fs_refresh_warn_brief "$handoff_file" "$refresh_threshold_tokens")"
        [[ -n "$brief_warning" ]] && printf '%s\n' "$brief_warning" >&2
    fi

    # Skipped when the image came from --image or K8S_PROJECT_IMAGES: a
    # project with its own image needs no K8S_IMAGE in k8s.env at all. A
    # plain run (RUN_IMAGE_SOURCE == k8s-env) still requires it, unchanged.
    if [[ "$RUN_IMAGE_SOURCE" == k8s-env && -z "$K8S_IMAGE" ]]; then
        echo "Error: K8S_IMAGE is not set in $k8s_env. This project ships a" >&2
        echo "Dockerfile and a build script, and never ships an image or a" >&2
        echo "registry -- you build it and push it to a registry you control." >&2
        echo "There is no default: a pod cannot use a local docker image, so" >&2
        echo "a silent default would only produce a confusing" >&2
        echo "ImagePullBackOff. Add a line:" >&2
        echo "  K8S_IMAGE=registry.example/you/fork-sandbox:latest" >&2
        echo "See docs/kubernetes-runs.md for registry options." >&2
        exit 1
    fi
    if [[ -z "$K8S_DENIED_PROBE" ]]; then
        echo "Error: K8S_DENIED_PROBE is not set in $k8s_env. The egress gate" >&2
        echo "needs a host:port the policy must deny, to prove the pin holds" >&2
        echo "before anything untrusted runs. Add a line:" >&2
        echo "  K8S_DENIED_PROBE=10.0.0.1:443" >&2
        exit 1
    fi
    # What THIS run can reach beyond the sealed default, restated here because
    # install said it once and may have been weeks ago. Parsed and discarded:
    # submit renders no policy of its own, so nothing downstream reads these
    # arrays and there is nothing to restore.
    if [[ -n "$K8S_AGENT_ALLOW_NS" ]]; then
        parse_proxy_allow_ns "$K8S_AGENT_ALLOW_NS" K8S_AGENT_ALLOW_NS || exit 1
        announce_agent_allow_ns
    fi

    # This run's own --allow-namespace grant, on top of (never instead of)
    # K8S_AGENT_ALLOW_NS above, plus the paired --reach-probe checks --
    # both extracted into validate_run_allow_ns / validate_run_reach_probes
    # above so check-grant can run the identical checks with no cluster.
    # parse_proxy_allow_ns (inside validate_run_allow_ns) fills
    # PROXY_ALLOW_NS_* -- already fully consumed by the static-key block's
    # own announce_agent_allow_ns call just above -- so overwriting it here
    # is safe.
    local -a run_allow_ns_namespaces=() run_allow_ns_ports=()
    validate_run_allow_ns run_allow_ns_namespaces run_allow_ns_ports "${allow_ns_raw[@]}"

    local -a run_reach_probes=()
    validate_run_reach_probes run_reach_probes run_allow_ns_namespaces run_allow_ns_ports \
        "${#allow_ns_raw[@]}" "${reach_probe_raw[@]}"

    resolve_platform || exit 1
    local icmp_check=0
    [[ "$(platform_capability icmp unfiltered)" == filtered ]] && icmp_check=1

    local safe_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"

    # This run's own grant object, when --allow-namespace was given --
    # resolved here, before any cluster object exists, so a platform that
    # cannot render one refuses before anything is created. "-agent-grant"
    # is 12 chars, one shorter than the "-claude-proxy" suffix
    # k8s_safe_name's own comment already budgets 50 chars for, so
    # grant_name is never over the 63-char Kubernetes object-name cap
    # either. The stale-grant check (does a NetworkPolicy of this name
    # already exist) is NOT here: it needs kubectl, and this is a purely
    # local capability check that must keep running under --dry-run, which
    # contacts no cluster at all -- see that check further down, placed
    # after --dry-run's exit.
    local grant_name=""
    if (( ${#run_allow_ns_namespaces[@]} > 0 )); then
        if [[ "$(platform_capability grant "")" != render-grant ]]; then
            echo "Error: --allow-namespace needs a platform that supports" >&2
            echo "per-run grants, but platform" >&2
            echo "'${FORK_SANDBOX_K8S_PLATFORM:-generic}' does not declare" >&2
            echo "grant=render-grant in its --capabilities. This platform" >&2
            echo "cannot grant a per-run namespace." >&2
            exit 1
        fi
        grant_name="$safe_name-agent-grant"
    fi

    local proxy_base_url
    if [[ -n "$proxy_endpoint" ]]; then
        # The named endpoint's exact-match location. A K8S_PROXY_ENDPOINTS
        # install renders no /api/v1 path at all -- this is the wiring the
        # old "submit cannot yet target K8S_PROXY_ENDPOINTS" refusal
        # guard stood in for, and is why that guard is gone.
        proxy_base_url="http://fork-sandbox-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN:8080/e/$proxy_endpoint/v1"
    else
        proxy_base_url="http://fork-sandbox-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN:8080/api/v1"
    fi

    # The egress-gate initContainer's own proxy probe: the shared pi proxy
    # for a pi run, this run's own per-run proxy for a claude run -- see
    # the Job env below, which is what actually needs this value. A runner
    # mode (--run-dir) pipeline with both kinds of seat probes the per-run
    # claude proxy too -- the NEWER of the two services, more likely to
    # reveal a startup race than the long-lived shared proxy -- since this
    # is only a readiness heuristic, not the egress boundary itself (the
    # NetworkPolicy is that).
    local egress_proxy_host="fork-sandbox-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN"
    [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]] \
        && egress_proxy_host="$safe_name-claude-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN"
    if (( pipeline_has_codex )) && (( ! pipeline_has_claude )); then
        egress_proxy_host="$safe_name-codex-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN"
    fi

    # The fork-sandbox/owner label plus this run's free-form labels --
    # resolved once here, ahead of both the claude-proxy template
    # substitution below and the job_rendered heredoc further down, since
    # both need EXTRA_LABEL_LINES. resolve_run_labels validates and merges
    # K8S_RUN_LABELS with this invocation's --label flags before anything is
    # created, matching every other submit-time validation. See
    # resolve_run_owner, resolve_run_labels and build_extra_label_lines
    # above.
    local run_owner
    run_owner="$(resolve_run_owner)"
    resolve_run_labels "${labels_raw[@]}" || exit 1
    build_extra_label_lines "$run_owner"
    local extra_labels_4 extra_labels_8
    extra_labels_4="$(render_extra_labels_indent 4)"
    extra_labels_8="$(render_extra_labels_indent 8)"

    # Every per-run object's label set: branch, owner (if any), and the
    # fork-sandbox.io/* pairs resolve_run_labels resolved above -- built
    # once here so the grant below and, for --harness claude, this run's
    # own token Secret (further down) read the identical set rather than
    # two copies that could drift.
    local -a run_label_pairs=("fork-sandbox/branch=$safe_name")
    [[ -n "$run_owner" ]] && run_label_pairs+=("fork-sandbox/owner=$run_owner")
    local run_label_i
    for run_label_i in "${!RUN_LABEL_KEYS[@]}"; do
        run_label_pairs+=("fork-sandbox.io/${RUN_LABEL_KEYS[$run_label_i]}=${RUN_LABEL_VALUES[$run_label_i]}")
    done

    # The per-run grant NetworkPolicy, rendered (never applied) here --
    # grant_name is empty unless --allow-namespace was given, in which case
    # the capability and stale-name checks above already ran. Applied
    # before the claude proxy and the Job below, so the egress gate sees it
    # on its very first poll iteration; see the apply sequence further down.
    local -a grant_allow_args=()
    local grant_i
    for (( grant_i = 0; grant_i < ${#run_allow_ns_namespaces[@]}; grant_i++ )); do
        if [[ -n "${run_allow_ns_ports[$grant_i]}" ]]; then
            grant_allow_args+=(--allow-namespace "${run_allow_ns_namespaces[$grant_i]}:${run_allow_ns_ports[$grant_i]}")
        else
            grant_allow_args+=(--allow-namespace "${run_allow_ns_namespaces[$grant_i]}")
        fi
    done
    local grant_rendered=""
    if [[ -n "$grant_name" ]]; then
        local -a grant_label_args=()
        for grant_i in "${!run_label_pairs[@]}"; do
            grant_label_args+=(--label "${run_label_pairs[$grant_i]}")
        done
        # job-name, never fork-sandbox/branch: the per-run claude-proxy Pod
        # carries the branch label too, and a grant selecting it would widen
        # the egress of the pod holding the operator's real access token.
        grant_rendered="$("$K8S_PLATFORM_BIN" render-grant --namespace "$K8S_NAMESPACE" \
            --name "$grant_name" --agent-label "job-name=$safe_name" \
            "${grant_label_args[@]}" "${grant_allow_args[@]}")"$'\n'
    fi

    # The per-run Claude Code proxy manifest (ConfigMap + Pod + Service),
    # rendered here -- ahead of the ConfigMap+Job below, in the SAME
    # `kubectl apply` stream -- for --harness claude only. See
    # manifests/k8s/31-claude-proxy.yaml's own header for why this is a
    # separate per-run Pod rather than a sidecar or the shared proxy.
    # __RUN_NAME__ is this run's own $safe_name, the same object-name
    # component the agent Job and its ConfigMap use.
    local claude_proxy_rendered=""
    if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
        local claude_proxy_template
        claude_proxy_template="$(dirname "$script_dir")/manifests/k8s/31-claude-proxy.yaml"
        if [[ ! -f "$claude_proxy_template" ]]; then
            echo "Error: $claude_proxy_template not found. Run this from a" >&2
            echo "fork-sandbox checkout." >&2
            exit 1
        fi
        claude_proxy_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__RUN_NAME__|$safe_name|g" \
            -e "s|__CLUSTER_DOMAIN__|$K8S_CLUSTER_DOMAIN|g" \
            "$claude_proxy_template")"$'\n'
        # A literal (non-regex) global replace, not another sed -- the
        # replacement can hold embedded newlines (one per extra label),
        # which sed's own s|from|to| cannot take without escaping. The
        # placeholder itself is a real "key: value" pair (not a bare
        # word) so the unsubstituted template stays valid YAML on its
        # own -- see the yamllint check in the test suite. The search
        # string includes the placeholder's own leading whitespace and
        # trailing newline, so an empty replacement (no extra labels)
        # removes the whole marker line cleanly, with no blank line left
        # behind, in all four labels: blocks at once.
        local extra_labels_marker=$'    __EXTRA_LABELS__: "true"\n'
        local extra_labels_proxy_block
        # Command substitution strips ALL trailing newlines from its
        # capture, including the one render_extra_labels_block always puts
        # after its last line -- put it back (only when there is a last
        # line at all) so the replacement still ends in \n, matching the
        # marker it replaces.
        extra_labels_proxy_block="$(render_extra_labels_block 4)"
        [[ -n "$extra_labels_proxy_block" ]] && extra_labels_proxy_block+=$'\n'
        claude_proxy_rendered="${claude_proxy_rendered//$extra_labels_marker/$extra_labels_proxy_block}"
    fi
    local codex_proxy_rendered=""
    if (( pipeline_has_codex )); then
        local codex_proxy_template
        codex_proxy_template="$(dirname "$script_dir")/manifests/k8s/32-codex-proxy.yaml"
        [[ -f "$codex_proxy_template" ]] || {
            echo "Error: $codex_proxy_template not found." >&2
            exit 1
        }
        codex_proxy_rendered="$(sed \
            -e "s|__NAMESPACE__|$K8S_NAMESPACE|g" \
            -e "s|__RUN_NAME__|$safe_name|g" \
            -e "s|__CLUSTER_DOMAIN__|$K8S_CLUSTER_DOMAIN|g" \
            "$codex_proxy_template")"$'\n'
        local codex_label_marker=$'    __EXTRA_LABELS__: "true"\n'
        local codex_label_block
        codex_label_block="$(render_extra_labels_block 4)"
        [[ -n "$codex_label_block" ]] && codex_label_block+=$'\n'
        codex_proxy_rendered="${codex_proxy_rendered//$codex_label_marker/$codex_label_block}"
    fi

    local entrypoint_sh="$script_dir/fork-sandbox-k8s-entrypoint.sh"
    local gate_sh="$script_dir/fork-sandbox-k8s-egress-gate.sh"
    local service_ready_sh="$script_dir/fork-sandbox-k8s-service-ready.sh"
    local inbox_write_sh="$script_dir/fork-sandbox-k8s-inbox-write.sh"
    local context_extract_sh="$script_dir/fork-sandbox-k8s-context-extract.sh"
    local leg_loop_sh="$script_dir/fork-sandbox-k8s-leg-loop.sh"
    local inbox_hook_sh="$script_dir/fork-sandbox-inbox-hook.sh"
    local stop_guard_sh="$script_dir/fork-sandbox-stop-guard.sh"
    local refresh_sh="$script_dir/fork-sandbox-refresh.sh"
    local lib_sh="$script_dir/fork-sandbox-lib.sh"
    for f in "$entrypoint_sh" "$gate_sh" "$inbox_write_sh" "$review_loop_sh" "$context_extract_sh" "$leg_loop_sh"; do
        [[ -x "$f" ]] || { echo "Error: $f is missing or not executable." >&2; exit 1; }
    done

    # The four --harness claude-only ConfigMap keys: the placeholder
    # credential, the operator-inbox hook, the commit-guard Stop hook and
    # fork-sandbox-lib.sh itself -- see render_claude_configmap_keys's own
    # header. Same newline-prefix convention as review_loop_configmap_keys
    # below, so an empty string here changes nothing about the no-claude
    # render.
    local claude_configmap_keys=""
    if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
        [[ -x "$inbox_hook_sh" ]] \
            || { echo "Error: $inbox_hook_sh is missing or not executable." >&2; exit 1; }
        [[ -x "$stop_guard_sh" ]] \
            || { echo "Error: $stop_guard_sh is missing or not executable." >&2; exit 1; }
        [[ -r "$lib_sh" ]] \
            || { echo "Error: $lib_sh is missing or unreadable." >&2; exit 1; }
        claude_configmap_keys=$'\n'"$(render_claude_configmap_keys \
            "$claude_configmap_cred" "$inbox_hook_sh" "$stop_guard_sh" "$lib_sh")"
    fi
    local codex_env=""
    if (( pipeline_has_codex )); then
        codex_env=$'\n'"$(cat <<CENV
            - name: CODEX_PROXY_BASE_URL
              value: "http://$safe_name-codex-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN:8080/v1"
CENV
)"
    fi

    # Must track fork-sandbox-k8s-entrypoint.sh's own work_dir/clone_dir --
    # this script renders the ConfigMap before the pod exists, so there is
    # nowhere to read the value back from. POD_SKILL_DIR and
    # POD_VERDICT_FILE are the same kind of pod-path knowledge, for the two
    # more paths the review prompt has to name.
    local pod_clone_dir=/work/clone
    local POD_SKILL_DIR=/work/skills/code-review-portable
    local POD_VERDICT_FILE="$pod_clone_dir/.git/review-verdict.md"

    # The four --review-loop-only ConfigMap keys and the two env vars they
    # need, rendered only when this run carries a loop. Prefixed with a
    # newline so embedding an EMPTY string here changes nothing about the
    # no-review-loop render below -- see render_review_loop_configmap_keys's
    # own header for why the keys carry no prompt prose of their own.
    local review_loop_configmap_keys="" review_loop_env=""
    if (( review_loop_cap > 0 )); then
        review_loop_configmap_keys=$'\n'"$(render_review_loop_configmap_keys \
            "$pod_clone_dir" "$POD_INBOX_DIR" "$POD_SKILL_DIR" "$POD_VERDICT_FILE" \
            "$branch" "$base_sha" "$review_skill_src" "$review_loop_sh" "$POD_OUTBOX_DIR" \
            "$outbox_max_bytes" "$handoff_file")"
        review_loop_env=$'\n'"$(render_review_loop_env "$review_loop_cap" "$base_sha")"
    fi

    # CLAUDE_PROXY_BASE_URL, for --harness claude or any claude seat in
    # pipeline.json -- the per-run proxy Service a claude leg needs; a pi
    # leg talks to the shared proxy via PROXY_BASE_URL instead, set
    # unconditionally above.
    local claude_env=""
    if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
        claude_env=$'\n'"$(cat <<CENV
            - name: CLAUDE_PROXY_BASE_URL
              value: "http://$safe_name-claude-proxy.$K8S_NAMESPACE.svc.$K8S_CLUSTER_DOMAIN:8080"
CENV
)"
    fi

    # REVIEW_MODEL, whenever --review-model was given -- regardless of
    # harness. The review loop always runs pi, so this is the id its
    # models.json should carry alongside (pi) or instead of (claude) the
    # coding leg's own MODEL; see synthesize_pi_config in the entrypoint.
    local review_model_env=""
    if [[ -n "$review_model" ]]; then
        review_model_env=$'\n'"$(cat <<CENV
            - name: REVIEW_MODEL
              value: "$review_model"
CENV
)"
    fi

    # PI_ARGS, whenever --pi-args was given (pi harness only -- a claude
    # run is refused with it above): the extra arguments for the pod's pi
    # coding-leg invocation, split on whitespace in the entrypoint and
    # passed to pi as an array. Rendered only when non-empty, so a run
    # without --pi-args renders no PI_ARGS at all -- the entrypoint treats
    # an unset or empty PI_ARGS as "no arguments".
    local pi_args_env=""
    if [[ -n "$pi_args" ]]; then
        pi_args_env=$'\n'"$(cat <<CENV
            - name: PI_ARGS
              value: "$pi_args"
CENV
)"
    fi

    # EXTRA_REFS, whenever --extra-ref was given: space-separated NAME=SHA
    # pairs, one per extra branch pushed alongside $branch. The entrypoint
    # creates a local branch per name and checks the sha. Every character is
    # already pinned above (a lowercase name, hex), so there is no quoting
    # concern for the YAML double-quoted scalar.
    local extra_refs_env="" extra_refs_value="" er_i
    for er_i in "${!extra_ref_names[@]}"; do
        extra_refs_value+="${extra_refs_value:+ }${extra_ref_names[$er_i]}=${extra_ref_shas[$er_i]}"
    done
    if [[ -n "$extra_refs_value" ]]; then
        extra_refs_env=$'\n'"$(cat <<CENV
            - name: EXTRA_REFS
              value: "$extra_refs_value"
CENV
)"
    fi

    # SESSION_HARNESS_STORE/RESUME_SESSION/SESSION_ID: the pod-side half of
    # continuity across wakes, set only when --session-state was given (a
    # store was pushed below). RESUME_SESSION/SESSION_ID are already
    # regex-validated by fs_validate_session_flags (hex and hyphens only),
    # so unlike PI_ARGS above there is no double-quote/backslash concern
    # for the YAML double-quoted scalar here.
    local session_harness_store_env="" resume_session_env="" session_id_env=""
    if [[ -n "$session_state" ]]; then
        session_harness_store_env=$'\n'"$(cat <<CENV
            - name: SESSION_HARNESS_STORE
              value: "1"
CENV
)"
    fi
    if [[ "$harness" == claude && -n "$resume_session" ]]; then
        resume_session_env=$'\n'"$(cat <<CENV
            - name: RESUME_SESSION
              value: "$resume_session"
CENV
)"
    fi
    if [[ "$harness" == pi && -n "$session_id_arg" ]]; then
        session_id_env=$'\n'"$(cat <<CENV
            - name: SESSION_ID
              value: "$session_id_arg"
CENV
)"
    fi

    # REFRESH_THRESHOLD_TOKENS/REFRESH_MAX: the pod-side half of the
    # self-refresh loop, set only when fs_refresh_resolve enabled it (claude
    # only, by construction). Both are validated integers, so no quoting
    # concern inside the YAML double-quoted scalars.
    local refresh_env=""
    if [[ "$refresh_enabled" == 1 ]]; then
        refresh_env=$'\n'"$(cat <<CENV
            - name: REFRESH_THRESHOLD_TOKENS
              value: "$refresh_threshold_tokens"
            - name: REFRESH_MAX
              value: "$refresh_max"
            - name: REFRESH_CEILING_TOKENS
              value: "$refresh_ceiling_tokens"
            - name: REFRESH_CONTEXT_WINDOW
              value: "$refresh_context_window"
CENV
)"
    fi

    # The sandbox-env ConfigMap key, present only when the services spec
    # carried a `sandboxEnv` map -- copied verbatim, pod-side, to
    # .env.sandbox in the clone (fork-sandbox-k8s-entrypoint.sh), the same
    # filename the local services path uses.
    local services_env_configmap_key=""
    if [[ -n "$sandbox_env_content" ]]; then
        services_env_configmap_key=$'\n'"$(cat <<KEYS
  sandbox-env: |
$(printf '%s' "$sandbox_env_content" | indent_block)
KEYS
)"
    fi

    # The service-ready initContainer, rendered only when at least one
    # service declares a readyWhen (services_ready_checks, built above from
    # fork-sandbox-k8s-services-parse.py's ready-checks output) -- a spec
    # with no readyWhen has nothing to wait for, the same as today. Placed
    # AFTER the service sidecars (services_containers) in the
    # initContainers list below, so it starts once they have, and built
    # from RUN_IMAGE -- the agent's own image, never a service's, which may
    # be distroless and shell-less -- see
    # fork-sandbox-k8s-service-ready.sh's own header for why the check
    # cannot live on the sidecar itself (a kubelet tcpSocket/httpGet probe
    # dials the pod IP, never 127.0.0.1) and why no probe on the sidecar
    # means a slow service is never killed and restarted for failing one.
    local service_ready_container="" service_ready_configmap_key=""
    if [[ -n "$services_ready_checks" ]]; then
        service_ready_configmap_key=$'\n'"$(cat <<KEYS
  service-ready.sh: |
$(indent_block < "$service_ready_sh")
KEYS
)"
        service_ready_container=$'\n'"$(cat <<KEYS
        - name: service-ready
          image: $RUN_IMAGE
          command: ["bash", "/mnt/fork-sandbox/service-ready.sh"]
          env:
            - name: SERVICE_READY_CHECKS
              value: "$services_ready_checks"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
KEYS
)"
    fi

    # MODEL_DISCOVERY, set only when this run is wired to a named
    # endpoint AND will actually use the pi proxy -- a pi coding leg,
    # or any run carrying a --review-loop (the loop always runs pi): it
    # is the host's half of the pod-side model-discovery gate. The
    # install kind alone is not enough: a --harness claude run without
    # a loop never reads PROXY_BASE_URL (its leg talks to
    # CLAUDE_PROXY_BASE_URL), so gating on the install alone would turn
    # such a run into a hard dependency on an endpoint it never talks
    # to -- dying at pod start when a workstation-class endpoint is
    # down, the expected ordinary state. The pod cannot tell the two
    # proxy renders apart from PROXY_BASE_URL alone -- on a legacy
    # K8S_PROXY_UPSTREAM install the proxy forwards only
    # /api/v1/chat/completions, so the discovery probe would 403 and die
    # the pod before the repository push. Set here, where the install
    # kind and the harness are already resolved, is the only place that
    # cannot guess wrong. See the MODEL_DISCOVERY entry in
    # fork-sandbox-k8s-entrypoint.sh's env header.
    local model_discovery_env=""
    if [[ -n "$proxy_endpoint" \
        && ( "$harness" == pi || $review_loop_cap -gt 0 || -n "$pipeline_pi_models" ) ]]; then
        model_discovery_env=$'\n'"$(cat <<CENV
            - name: MODEL_DISCOVERY
              value: "1"
CENV
)"
    fi

    # ALLOW_UNLISTED_MODEL, rendered only when k8s.env sets
    # K8S_ALLOW_UNLISTED_MODEL=1 (validated at parse time above): the pod's
    # half of the escape hatch -- it permits a launch whose context length
    # had to be guessed. Unset renders nothing, so the pod-side default
    # stays refuse without this script spelling "0".
    local allow_unlisted_model_env=""
    if [[ "$K8S_ALLOW_UNLISTED_MODEL" == 1 ]]; then
        allow_unlisted_model_env=$'\n'"$(cat <<CENV
            - name: ALLOW_UNLISTED_MODEL
              value: "1"
CENV
)"
    fi

    # The emptyDir volume + mount for --thread-dir/--attach-dir, rendered
    # only when the matching flag was given -- locally the mount is
    # likewise absent when the flag is absent, and the postmaster's own
    # prompt says "when that mount is present", so the pod must match.
    # A writable emptyDir, not read-only: the pod's own filesystem is
    # readOnlyRootFilesystem, so nothing can mkdir /thread or /attachments
    # for the exec extractor (below) to write into unless the mount itself
    # is writable. This is accepted, not a gap -- the pod's copy is a
    # disposable per-wake copy, the host source directory named by
    # --thread-dir/--attach-dir is never written back, so an agent writing
    # into its own /thread or /attachments only ever harms its own view of
    # it. A sidecar or second container to enforce read-only here would be
    # pure ceremony for a property nothing downstream reads.
    local thread_volume_mount="" thread_volume=""
    if [[ -n "$thread_dir" ]]; then
        thread_volume_mount=$'\n'"$(cat <<CENV
            - name: thread
              mountPath: /thread
CENV
)"
        thread_volume=$'\n'"$(cat <<CENV
        - name: thread
          emptyDir: {}
CENV
)"
    fi
    local attach_volume_mount="" attach_volume=""
    if [[ -n "$attach_dir" ]]; then
        attach_volume_mount=$'\n'"$(cat <<CENV
            - name: attachments
              mountPath: /attachments
CENV
)"
        attach_volume=$'\n'"$(cat <<CENV
        - name: attachments
          emptyDir: {}
CENV
)"
    fi
    # Runner mode's own emptyDir, mounted at the run dir's own absolute
    # host path rather than a fixed pod-side constant like /thread or
    # /attachments above -- every path baked into run.sh (prompts,
    # handoff.md, the inbox, every *_sandbox_cmd array) was generated
    # against that exact path, so moving it would mean rewriting run.sh
    # instead of just mounting it where it already expects to be. RUN_DIR
    # carries the same path into the entrypoint's own env.
    local run_dir_volume_mount="" run_dir_volume="" run_dir_env=""
    if [[ -n "$run_dir_flag" ]]; then
        run_dir_volume_mount=$'\n'"$(cat <<CENV
            - name: run
              mountPath: $run_dir_flag
CENV
)"
        run_dir_volume=$'\n'"$(cat <<CENV
        - name: run
          emptyDir: {}
CENV
)"
        run_dir_env=$'\n'"$(cat <<CENV
            - name: RUN_DIR
              value: "$run_dir_flag"
CENV
)"
    fi

    # --context-secret's mount and volume. defaultMode 0440 with the pod's
    # fsGroup 1000 gives the mounting container's group read.
    #
    # Which container actually gets this mount differs by shape, and has
    # to -- a --context-secret exists to give
    # the RUN'S OWN TASK a credential (e.g. an API key a seat's work must
    # exercise), never the walker. The single-leg (legacy) shape has one
    # container, which both runs the task and IS "the agent" -- so
    # $context_secret_volume_mount is used there unchanged, below. The
    # composed (--run-dir) shape splits those two roles: the `agent`
    # container is the walker, fork-sandbox-runner.sh, which never
    # executes a leg's own harness invocation itself (see "A leg cannot
    # write the runner's own state" in docs/kubernetes-runs.md) -- so it
    # has no use for the secret and does not mount it; only the `leg`
    # container, which actually runs the task, does.
    local context_secret_volume_mount="" context_secret_volume=""
    if [[ -n "$context_secret" ]]; then
        context_secret_volume_mount=$'\n'"$(cat <<CENV
            - name: context-secret
              mountPath: $POD_CONTEXT_DIR
              readOnly: true
CENV
)"
        context_secret_volume=$'\n'"$(cat <<CENV
        - name: context-secret
          secret:
            secretName: $context_secret
            defaultMode: 0440
CENV
)"
    fi

    # The exact prompt text the pod's ConfigMap embeds under handoff.md --
    # preamble, then the optional context/services sections, then the
    # headless-turn warning, then the operator's own handoff -- captured
    # here once so run_dir's own
    # handoff.md (below) is a faithful archive rather than a second,
    # independent render. A trailing sentinel byte survives command
    # substitution's trailing-newline stripping and is peeled back off, so
    # the archive retains blank lines at the end of the operator's handoff.
    # The ConfigMap's enclosing pipeline strips those newlines before YAML's
    # clip chomping gives the pod one trailing newline.
    # The part before the separator is also the continuation header the pod's
    # refresh loop re-sends on every continuation leg, so it is rendered on
    # its own by the same calls (never string-split back out of the whole).
    local continuation_header rendered_handoff
    continuation_header="$({ fs_emit_prompt_preamble "$pod_clone_dir" "$POD_INBOX_DIR" "$harness" gated "$POD_OUTBOX_DIR" pod \
       "$outbox_max_bytes"
   [[ -n "$context_ro" ]] && render_context_section "$POD_CONTEXT_DIR"
   [[ -n "$context_secret" ]] && render_context_secret_section "$POD_CONTEXT_DIR" "$context_secret"
   [[ -n "$services_prompt_text" ]] && render_services_section "$services_prompt_text" "$sandbox_env_present"
   fs_emit_headless_turn_section
   printf 'X'; })"
    continuation_header="${continuation_header%X}"
    rendered_handoff="$({ printf '%s' "$continuation_header"
   printf '\n---\n\n'
   cat -- "$handoff_file"
   printf 'X'; })"
    rendered_handoff="${rendered_handoff%X}"

    # The refresh loop's three ConfigMap keys, present only when refresh is
    # enabled -- see render_refresh_configmap_keys. The header keeps its own
    # trailing newlines (indent_block/YAML clip them to one), which is all
    # fs_refresh_build_prompt needs.
    local refresh_configmap_keys=""
    if [[ "$refresh_enabled" == 1 ]]; then
        [[ -r "$refresh_sh" ]] \
            || { echo "Error: $refresh_sh is missing or unreadable." >&2; exit 1; }
        refresh_configmap_keys=$'\n'"$(render_refresh_configmap_keys \
            "$refresh_sh" "$continuation_header" "$handoff_file")"
    fi

    # leg-loop.sh is shipped in the ConfigMap unconditionally (like
    # entrypoint.sh/egress-gate.sh above) rather than only for --run-dir: a
    # single-leg or legacy-review-loop pod never references it (its own
    # command stays "bash .../entrypoint.sh"), so shipping it costs
    # nothing there and keeps every pod's ConfigMap the same shape
    # regardless of run kind.
    #
    # Isolation for a composed (--run-dir) run: see "Composed pipelines on
    # --k8s" in docs/kubernetes-runs.md. The walker (fork-sandbox-
    # runner.sh, via entrypoint.sh's RUN_DIR arm) keeps running in the
    # "agent" container -- the same name a single-leg pod's own one
    # container already uses, deliberately: every kubectl exec/logs/get
    # call site this script makes against a running pod names "agent"
    # explicitly below, and that works unchanged for either pod shape only
    # because the name is the same one in both. That container mounts
    # $run_dir_flag (the run directory -- run.sh, pipeline.json,
    # progress.json, every step's prompt, the verdict a leg already wrote
    # once this runner has copied it out -- see run_leg's own `rm -f
    # "$cur_verdict_file"` before every review/maintain iteration)
    # read-write; a leg never runs in this container at all. Every leg
    # instead runs in a SEPARATE "leg" container, started by
    # fork-sandbox-k8s-leg-loop.sh, which mounts the SAME run-directory
    # volume read-ONLY -- so nothing a leg does, no matter how it tries,
    # can write run.sh, pipeline.json, a later step's prompt, or any of
    # the runner's own bookkeeping, because the kernel's own read-only
    # bind mount refuses the write before either container's code ever
    # runs. The two containers trade requests and responses over
    # fork-sandbox-runner.sh's fs_run_leg_split and
    # fork-sandbox-k8s-leg-loop.sh's own loop -- the request side writes
    # under $run_dir_flag (so only the agent container can issue one), the
    # response side under the dedicated "leg-handoff" volume below,
    # mounted read-write in the leg container and read-only in the
    # agent's, so a leg can hand back its own output and nothing else's.
    # The clone and
    # the outbox move to their OWN dedicated volumes, read-write in BOTH
    # containers (real work and real artifacts, legitimately produced by
    # whichever leg is running, and reading them back is not a privilege
    # a leg's own container needs to be denied) -- carved out of the
    # single "work" emptyDir a single-leg pod still uses unsplit, so the
    # leg container never mounts the REST of "work" (the bare repository,
    # the push/fetch sentinels) at all; a leg that could write
    # /work/.run-complete early could fool a client's `wait` into fetching
    # a half-finished branch, which is exactly the kind of forged
    # end-of-run state this split exists to prevent.
    local leg_handoff_dir="/handoff"
    # Named so it can be handed to the leg container as FORK_SANDBOX_CLONE_DIR
    # below -- unlike the agent container, which discovers this same path as
    # a local variable inside fork-sandbox-k8s-entrypoint.sh, leg-loop.sh has
    # no entrypoint-generation step of its own to bake it into, so it has to
    # arrive as an env var instead.
    local leg_clone_dir="/work/clone"
    local containers_yaml volumes_yaml
    if [[ -n "$run_dir_flag" ]]; then
        containers_yaml="$(cat <<CYAML
        - name: agent
          image: $RUN_IMAGE
          command: ["bash", "/mnt/fork-sandbox/entrypoint.sh"]
          env:
            - name: HOME
              value: /tmp
            - name: BRANCH
              value: "$branch"
            - name: HARNESS
              value: "$harness"
            - name: MODEL
              value: "$model"
            - name: PROXY_BASE_URL
              value: "$proxy_base_url"
            - name: GIT_USER_NAME
              value: "$GIT_USER_NAME"
            - name: GIT_USER_EMAIL
              value: "$GIT_USER_EMAIL"
            - name: RUN_TTL
              value: "$K8S_RUN_TTL"
            - name: OUTBOX_MAX_BYTES
              value: "$outbox_max_bytes"${model_discovery_env}${allow_unlisted_model_env}${review_loop_env}${claude_env}${codex_env}${review_model_env}${pi_args_env}${extra_refs_env}${session_harness_store_env}${resume_session_env}${session_id_env}${refresh_env}${run_dir_env}
            - name: FORK_SANDBOX_LEG_HANDOFF_DIR
              value: "$leg_handoff_dir"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
            - name: work
              mountPath: /work
            - name: runner-tmp
              mountPath: /tmp
            - name: clone
              mountPath: $leg_clone_dir
            - name: outbox
              mountPath: /work/outbox
            - name: run
              mountPath: $run_dir_flag
            - name: leg-handoff
              mountPath: $leg_handoff_dir
              readOnly: true${thread_volume_mount}${attach_volume_mount}
        - name: leg
          image: $RUN_IMAGE
          command: ["bash", "/mnt/fork-sandbox/leg-loop.sh"]$(k8s_agent_resources_yaml)
          env:
            - name: HOME
              value: /home/agent
            - name: RUN_DIR
              value: "$run_dir_flag"
            - name: FORK_SANDBOX_LEG_HANDOFF_DIR
              value: "$leg_handoff_dir"
            - name: FORK_SANDBOX_CLONE_DIR
              value: "$leg_clone_dir"${claude_env}${codex_env}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
            - name: tmp
              mountPath: /tmp
            - name: home
              mountPath: /home/agent
            - name: clone
              mountPath: $leg_clone_dir
            - name: outbox
              mountPath: /work/outbox
            - name: run
              mountPath: $run_dir_flag
              readOnly: true
            - name: leg-handoff
              mountPath: $leg_handoff_dir${thread_volume_mount}${attach_volume_mount}${context_secret_volume_mount}
CYAML
)"
        volumes_yaml="$(cat <<VYAML
        - name: scripts
          configMap:
            name: $safe_name-scripts
        - name: work
          emptyDir: {}
        - name: runner-tmp
          emptyDir: {}
        # This is the LEG container's own /tmp (mounted at /tmp there,
        # below) -- a leg can fill it without
        # bound, same as home/clone/leg-handoff, so it gets the same cap.
        # It is NOT runner-tmp above, the agent container's own /tmp,
        # which only ever holds the walker's own scratch state.
        - name: tmp
          emptyDir:
            sizeLimit: $K8S_LEG_VOLUME_SIZE_LIMIT
        # home (the leg container's $HOME), clone, leg-handoff and tmp
        # above are the four volumes a leg can fill without bound
        # otherwise -- see K8S_LEG_VOLUME_SIZE_LIMIT's own comment above.
        # outbox and work (the single-leg shape's own volume, further
        # below) are deliberately NOT capped the same way: outbox holds a
        # legitimately large, operator-raised artifact
        # (FS_OUTBOX_MAX_BYTES), and an emptyDir sizeLimit breach evicts
        # the whole pod rather than just refusing the oversized thing,
        # which would cost the branch along with the outbox -- a worse
        # trade than the one this cap makes for home/clone/leg-handoff/tmp,
        # none of which a legitimate run ever needs to grow without bound.
        # A leg can still fill the outbox's underlying node storage before
        # the client's own pull-back check ever runs (that check is a
        # client-side refusal at fetch time, not a pod-side guard) -- an
        # accepted risk, identical to the one the single-leg shape's own
        # "work" volume (which co-hosts ITS outbox) already accepts, for
        # the same reason.
        - name: home
          emptyDir:
            sizeLimit: $K8S_LEG_VOLUME_SIZE_LIMIT
        - name: clone
          emptyDir:
            sizeLimit: $K8S_LEG_VOLUME_SIZE_LIMIT
        - name: outbox
          emptyDir: {}
        - name: leg-handoff
          emptyDir:
            sizeLimit: $K8S_LEG_VOLUME_SIZE_LIMIT${thread_volume}${attach_volume}${context_secret_volume}${services_volumes}${run_dir_volume}
VYAML
)"
    else
        containers_yaml="$(cat <<CYAML
        - name: agent
          image: $RUN_IMAGE
          command: ["bash", "/mnt/fork-sandbox/entrypoint.sh"]$(k8s_agent_resources_yaml)
          env:
            - name: HOME
              value: /home/agent
            - name: BRANCH
              value: "$branch"
            - name: HARNESS
              value: "$harness"
            - name: MODEL
              value: "$model"
            - name: PROXY_BASE_URL
              value: "$proxy_base_url"
            - name: GIT_USER_NAME
              value: "$GIT_USER_NAME"
            - name: GIT_USER_EMAIL
              value: "$GIT_USER_EMAIL"
            - name: RUN_TTL
              value: "$K8S_RUN_TTL"
            - name: OUTBOX_MAX_BYTES
              value: "$outbox_max_bytes"${model_discovery_env}${allow_unlisted_model_env}${review_loop_env}${claude_env}${review_model_env}${pi_args_env}${extra_refs_env}${session_harness_store_env}${resume_session_env}${session_id_env}${refresh_env}${run_dir_env}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            - name: home
              mountPath: /home/agent${thread_volume_mount}${attach_volume_mount}${context_secret_volume_mount}${run_dir_volume_mount}
CYAML
)"
        volumes_yaml="$(cat <<VYAML
        - name: scripts
          configMap:
            name: $safe_name-scripts
        - name: work
          # Deliberately no sizeLimit here. /work holds the outbox this
          # file's own OUTBOX_MAX_BYTES budgets -- but an emptyDir sizeLimit
          # is enforced by the kubelet EVICTING THE WHOLE POD the moment
          # it's crossed, which would destroy the clone and the branch along
          # with the oversized outbox. A refused pull-back (the outcome
          # OUTBOX_MAX_BYTES actually produces, via cmd_collect's pull-back guard
          # and the pod-side warning in fork-sandbox-k8s-entrypoint.sh) is
          # far cheaper than losing the whole run to eviction. If you're
          # about to add one back: don't -- the cap already has an
          # enforcement point, and it isn't this.
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: home
          emptyDir: {}${thread_volume}${attach_volume}${context_secret_volume}${services_volumes}${run_dir_volume}
VYAML
)"
    fi

    local job_rendered rendered
    job_rendered="$(cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $safe_name-scripts
  namespace: $K8S_NAMESPACE
  labels:
    app: fork-sandbox-agent
    fork-sandbox/branch: $safe_name${extra_labels_4}
data:
  entrypoint.sh: |
$(indent_block < "$entrypoint_sh")
  egress-gate.sh: |
$(indent_block < "$gate_sh")
  inbox-write.sh: |
$(indent_block < "$inbox_write_sh")
  context-extract.sh: |
$(indent_block < "$context_extract_sh")
  leg-loop.sh: |
$(indent_block < "$leg_loop_sh")
  handoff.md: |
$(printf '%s' "$rendered_handoff" | indent_block)${review_loop_configmap_keys}${claude_configmap_keys}${refresh_configmap_keys}${services_env_configmap_key}${service_ready_configmap_key}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $safe_name
  namespace: $K8S_NAMESPACE
  labels:
    app: fork-sandbox-agent
    fork-sandbox/branch: $safe_name${extra_labels_4}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: fork-sandbox-agent
        fork-sandbox/branch: $safe_name${extra_labels_8}
    spec:
      restartPolicy: Never${services_grace_env}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: egress-gate
          image: $RUN_IMAGE
          command: ["bash", "/mnt/fork-sandbox/egress-gate.sh"]
          env:
            - name: DENIED_PROBE
              value: "$K8S_DENIED_PROBE"
            - name: PROXY_HOST
              value: "$egress_proxy_host"
            - name: PROXY_PORT
              value: "8080"
            - name: ICMP_CHECK
              value: "$icmp_check"
            - name: REACH_PROBES
              value: "${run_reach_probes[*]:-}"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /mnt/fork-sandbox
              readOnly: true${services_containers}${service_ready_container}
      containers:
$containers_yaml
      volumes:
$volumes_yaml
EOF
)"
    rendered="${grant_rendered}${claude_proxy_rendered}${codex_proxy_rendered}${job_rendered}"

    if [[ "$dry_run" == true ]]; then
        printf '%s\n' "$rendered"
        if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
            printf '# (dry-run) would create Secret %s-claude-token here, holding the operator access token -- not shown.\n' \
                "$safe_name"
        fi
        if (( pipeline_has_codex )); then
            printf '# (dry-run) would create Secret %s-codex-token here, holding the operator access token -- not shown.\n' \
                "$safe_name"
        fi
        # Unlike an ordinary (no --run-dir) dry-run, which creates nothing
        # of its own to clean up before this point, a --run-dir dry-run
        # must NOT remove DIR: validate_run_dir_flag above only confirms
        # DIR holds run.sh and pipeline.json, a shape every live composed
        # run directory has too, staged or already collected -- this
        # process never created DIR, so it is never this invocation's to
        # delete, dry-run or not: --run-dir does not always name a
        # just-staged, throwaway directory, and a --dry-run against an
        # operator's own live run dir must not destroy it.
        exit 0
    fi

    # This run's row in the durable run log (~/.claude/sandbox-runs.jsonl):
    # a run directory in exactly the shape fork-sandbox.sh's own local run
    # creates (same mktemp template, same FORKS_ROOT, same prefix), so
    # sandbox-run-log.py's `record` -- invoked by cmd_collect once the run
    # is known to have finished -- can read it back as an ordinary run
    # directory rather than needing a second code path of its own. Created
    # here, after --dry-run's exit above (a dry-run contacts nothing, and
    # that includes the host filesystem outside rendering), but before any
    # cluster object exists, so it is populated with what submit already
    # knows regardless of whether the cluster calls below succeed.
    #
    # Not removed by this script once a cluster object for this run may
    # exist: this directory is the join key an orchestrator later attaches
    # a verdict to (`sandbox-run-log.py verdict <run-id>`, the directory's
    # basename), and it is what cmd_collect's own record call reads --
    # removing it then would defeat the whole point. It is removed by the
    # orchestrator after review, exactly like a local run's own run
    # directory. Before that point -- while a failure can still only be
    # host-side, with nothing yet in the cluster to join this directory to
    # -- it IS removed on failure, by the trap set right after it is
    # created below; see that trap's own comment.
    # A script cannot assume the hook ran: fork-sandbox.sh's own root
    # mkdir (its own comment says as much) sits AFTER the --k8s dispatch's
    # exec, which replaces this process before that line ever runs, and a
    # cron/CI driver or a fresh box calling this script directly never
    # reaches fork-sandbox.sh's mkdir at all. Without this, the mktemp
    # below dies on a missing parent, under set -euo pipefail, after every
    # validation above has already passed.
    mkdir -p /var/tmp/claude-scratch/forks
    local run_dir run_dir_created_here
    if [[ -n "$run_dir_flag" ]]; then
        # Runner mode: DIR was already staged (validate_run_dir_flag above
        # already confirmed it exists and holds run.sh/pipeline.json), so
        # it becomes run_dir as-is -- no mktemp, nothing new created here.
        # run_dir_created_here stays false: every trap below that removes
        # run_dir on a host-side failure must not touch a directory this
        # process never created -- the same shape of live run directory
        # --dry-run above never deletes either.
        run_dir="$run_dir_flag"
        run_dir_created_here=false
    else
        run_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"
        run_dir_created_here=true
    fi
    fs_reject_unsafe_chars "$run_dir"

    # Removed on any failure between here and the first cluster object,
    # mirroring fork-sandbox.sh's own local launcher, which removes ITS
    # run dir when fs_make_clone fails so a bad branch name does not leave
    # an empty directory behind -- but ONLY when run_dir_created_here is
    # true. A submit that dies validating something host-side (the
    # context archive's size cap below, a spool failure) never reaches
    # the cluster at all -- no Job, no Secret, nothing for "the
    # orchestrator after review" or an operator's `rm --branch` to find --
    # so a freshly mktemp'd run dir's join key has nothing to join to, and
    # would otherwise leak forever. A caller-supplied --run-dir is never
    # this invocation's to delete, on any outcome: the same reasoning
    # --dry-run above follows. Disarmed just before the first kubectl
    # create/apply below: from that point on, a cluster object may already
    # exist, and this directory is what cmd_collect's own record call
    # needs to read back, exactly like every run that does reach the
    # cluster. Also covers the session store's own tar, in case it was
    # already spooled above (the session cap check runs before run_dir
    # exists, so its own trap could not yet reference run_dir too).
    trap 'rm -f -- "${K8S_SUBMIT_SESSION_TAR:-}"; [[ "$run_dir_created_here" == true ]] && rm -rf -- "$run_dir"' EXIT

    # The run dir is printed after run.env is written below, so a client
    # can poll status --json as soon as it receives the path. Same line shape
    # fork-sandbox.sh's own local launcher prints (two leading spaces,
    # "run dir:", two spaces), so a caller fanning out -- this project's
    # own test suites, or an external panel launcher calling
    # submit/wait/collect directly rather than blocking through run --
    # scrapes it with the identical `sed -n 's/^  run dir:  *//p'` either
    # path uses, and gets the same value whether this submit goes on to
    # succeed or not.

    # The run's provenance, when the launching shell declared one -- same
    # absence convention and same file name as fork-sandbox.sh's own local
    # run (scripts/fork-sandbox.sh, beside its own run_dir creation):
    # sandbox-run-log.py reads this back as the record's `source`, so a
    # test suite driving this script for real (a stubbed kubectl, no
    # cluster) can tag its fixture runs and stay out of the operator's own
    # stats without this script needing to know why.
    if [[ -n "${FORK_SANDBOX_RUN_SOURCE:-}" ]]; then
        printf '%s\n' "$FORK_SANDBOX_RUN_SOURCE" > "$run_dir/run-source"
    fi

    # The task metadata rides beside the run, where sandbox-run-log.py
    # picks it up at collect time -- same absence convention as a local
    # run's own task-meta.json: no file when --task-meta was not given.
    if [[ -n "$task_meta" ]]; then
        printf '%s\n' "$task_meta" > "$run_dir/task-meta.json"
    fi

    # Two archived copies, matching the local run's own handoff.md /
    # handoff-original.md split (scripts/fork-sandbox.sh): handoff.md is
    # the rendered prompt captured above as $rendered_handoff, while
    # handoff-original.md is the operator's raw file, unrendered. The
    # archive preserves trailing newlines; YAML clip chomping means the pod
    # receives the ConfigMap form with exactly one trailing newline.
    # Written now rather than left for cmd_collect to read later: the
    # caller may edit or remove the original while the run is in flight.
    #
    # Runner mode (--run-dir) never writes handoff.md here: the launcher
    # already rendered its own implement prompt to $run_dir/handoff.md
    # before this submit ever ran (the composed preamble's own handoff=
    # points at it), and this $rendered_handoff is this command's
    # legacy-shaped rendering of the SAME raw file, built above purely to
    # size the context archive -- overwriting the launcher's file with it
    # would feed the pod's first leg the wrong prompt. handoff-original.md
    # is still useful in runner mode (the operator's raw file, archived),
    # so it is written, but only if the launcher did not already leave one.
    if [[ -z "$run_dir_flag" ]]; then
        printf '%s' "$rendered_handoff" > "$run_dir/handoff.md"
        cp -- "$handoff_file" "$run_dir/handoff-original.md"
    elif [[ ! -e "$run_dir/handoff-original.md" ]]; then
        cp -- "$handoff_file" "$run_dir/handoff-original.md"
    fi
    # Runner mode's own third archived copy: $continuation_header (just
    # above) is already exactly the preamble a --refresh-at continuation
    # leg re-sends, including the pod-only context/services sections
    # fs_render_leg_prompts (the launcher's own prompt renderer, which
    # never reaches this far -- see docs/kubernetes-runs.md) has no way to
    # know about, so this is written here rather than by whoever staged
    # the rest of run_dir.
    if [[ -n "$run_dir_flag" && "$refresh_enabled" == 1 ]]; then
        printf '%s' "$continuation_header" > "$run_dir/continuation-prompt-header.md"
    fi

    # run.env: the same fallback shape a local run's own run.env offers
    # sandbox-run-log.py when summary.json (written by cmd_collect, once
    # the run is known to have finished) is missing or unreadable.
    # base_sha here is the revision the branch is about to start from --
    # checkout_sha when --checkout was given, else this repo's HEAD --
    # computed independently of the review-loop's own base_sha above
    # (which stays empty without --review-loop) because the log wants this
    # value regardless of whether a review loop ran.
    local run_log_base_sha="$checkout_sha"
    if [[ -z "$run_log_base_sha" ]]; then
        run_log_base_sha="$(cd "$origin_repo" && git rev-parse HEAD 2>/dev/null || true)"
    fi
    # Resolved to absolute now, at the caller's cwd, rather than left
    # relative: `resume` reads this back later and would otherwise resolve
    # a relative path against ITS OWN cwd, not the cwd a direct CLI `run`
    # was invoked from. Empty (no --outbox-dir) stays empty -- feeding the
    # empty string through the resolver would instead yield the cwd
    # itself, which is not "no outbox dir" and must not be recorded as
    # though it were.
    local outbox_dir_recorded=""
    [[ -n "$outbox_dir" ]] && outbox_dir_recorded="$("$FS_REALPATH" -m -- "$outbox_dir")"
    # Runner mode (--run-dir) reaches this with the launcher's OWN run.env
    # already written at that same path -- version=, run_dir=, clone_dir=,
    # started_at= and the rest fork-sandbox-status.sh needs to accept a
    # composed k8s run's host directory at all (see that writer's own
    # comment). APPEND to it rather than truncate: `>` here would silently
    # erase every one of those keys, exactly the bug that left a collected
    # run's run.env with no version= at all. A standalone submit (no
    # --run-dir) still gets a fresh file -- there is nothing to preserve.
    # The few keys below that both writers print (branch, origin_repo,
    # harness, model) end up duplicated; read_env_value/run_env_get take
    # the FIRST match, so the launcher's own value (printed first, since
    # its write always runs before this one) wins for those, which is fine
    # since both sides resolve them from the same seat. `network` is NOT
    # duplicated -- the launcher's writer skips it in k8s_runner_mode
    # precisely so this line, the only writer of it, decides.
    local run_env_redirect=">"
    [[ -n "$run_dir_flag" ]] && run_env_redirect=">>"
    local submit_started_at
    submit_started_at="$(date +%s)"
    {
        # version= and started_at=: a standalone submit (no --run-dir) is
        # the ONLY writer of run.env for a plain --k8s run, and
        # fork-sandbox-status.sh hard-refuses any run directory without a
        # version= key at all (see that script's own version= check) --
        # today's gap this closes. Runner mode never prints these: the
        # launcher's own writer (fork-sandbox.sh, before this submit ever
        # ran) already did, and run_env_redirect's append here must not
        # produce a second version= line for read_env_value/run_env_get's
        # first-match-wins rule to still mean the launcher's value.
        if [[ -z "$run_dir_flag" ]]; then
            printf 'version=1\n'
            printf 'started_at=%s\n' "$submit_started_at"
        fi
        printf 'mode=run\n'
        printf 'harness=%s\n' "$harness"
        printf 'network=cluster\n'
        # Read back by fork-sandbox-status.sh in place of a tmux session
        # name, which a cluster run never has: this is the Job/Pod label
        # name (k8s_safe_name, the same derivation every management verb
        # uses to find this run's objects), the one thing that actually
        # exists for an operator to look at.
        printf 'k8s_job_name=%s\n' "$safe_name"
        printf 'model=%s\n' "$model"
        printf 'image=%s\n' "$RUN_IMAGE"
        printf 'image_source=%s\n' "$RUN_IMAGE_SOURCE"
        printf 'branch=%s\n' "$branch"
        printf 'origin_repo=%s\n' "$origin_repo"
        printf 'base_sha=%s\n' "$run_log_base_sha"
        # Read back by cmd_resume (upper-case: its own keys, apart from the
        # run-log fallback keys above), so a run can be picked up again
        # from its directory alone.
        printf 'BRANCH=%s\n' "$branch"
        printf 'PROJECT=%s\n' "$origin_repo"
        printf 'OUTBOX_DIR=%s\n' "$outbox_dir_recorded"
        printf 'OUTBOX_MAX_BYTES=%s\n' "$outbox_max_bytes"
        printf 'REVIEW_LOOP=%s\n' "$review_loop_recorded"
        printf 'KEEP=%s\n' "$keep"
        printf 'TIMEOUT=%s\n' "$run_timeout"
        printf 'SUBMITTED_AT=%s\n' "$submit_started_at"
        # Written at the FIRST write: a run.env carrying this key promises
        # INPUTS_PUSH_COMPLETE=true follows once the pod has its inputs, and
        # `resume` (which a restarted postmaster's adopt path runs) refuses
        # a run that has the first without the second -- a submitter that
        # died mid-push. A run.env with neither key predates the marker and
        # is adopted as before.
        printf 'INPUTS_PUSH_EXPECTED=true\n'
        # Read back by cmd_collect, before cmd_fetch, and handed to
        # cmd_fetch's own --upstream/--upstream-none: resolved once above,
        # at submit time, so a later collect or re-collect applies the same
        # upstream rather than re-resolving it against whatever HEAD is by
        # then.
        printf 'UPSTREAM=%s\n' "$upstream"
        printf 'UPSTREAM_REASON=%s\n' "$upstream_reason"
        [[ -n "$run_dir_flag" ]] && printf 'RUNNER=1\n'
        if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
            printf 'claude_credentials_source=%s\n' "${claude_credentials_override:-default}"
            printf 'claude_credentials_via=%s\n' "$claude_credentials_via"
            # Read back by cmd_wait (via --run-dir, from k8s_run_tail or a
            # hand-run `wait --run-dir`) to find the file-backed credential
            # to keep alive -- never its content, only the path. Empty for
            # a Keychain-backed credential, which is cmd_wait's own signal
            # to print a note and start no keeper, same as claude-sandboxed
            # skips its own live-sync loop for one.
            printf 'CLAUDE_CREDENTIAL_PATH=%s\n' "$claude_cred_file"
        fi
        if (( pipeline_has_codex )); then
            printf 'CODEX_AUTH_PATH=%s\n' "$codex_auth_path"
        fi
        # Read back by cmd_collect, before cmd_fetch, so a standalone
        # collect (no run.env in scope of the calling process) still
        # knows where to pull the session store from and which harness's
        # discovery rules apply. fork-sandbox.sh's own local run.env
        # carries no equivalent keys -- it never needs to round-trip this
        # across a process boundary the way k8s's submit/collect split
        # does -- so these key names are free; chosen to match the names
        # fork-sandbox.sh's own --dry-run print block already uses for
        # the same three flags, for a reader's sake, not because anything
        # parses them positionally.
        [[ -z "$session_state" ]] || printf 'session_state=%s\n' "$session_state"
        [[ -z "$resume_session" ]] || printf 'resume_session=%s\n' "$resume_session"
        [[ -z "$session_id_arg" ]] || printf 'session_id=%s\n' "$session_id_arg"
        # Absent when refresh is off: cmd_collect reads a missing
        # refresh_threshold_tokens as "disabled".
        if [[ "$refresh_enabled" == 1 ]]; then
            printf 'refresh_at=%s\n' "$refresh_at"
            printf 'refresh_max=%s\n' "$refresh_max"
            printf 'refresh_threshold_tokens=%s\n' "$refresh_threshold_tokens"
        fi
    } > "$run_dir/run.env.submit-part"
    if [[ "$run_env_redirect" == ">>" ]]; then
        cat -- "$run_dir/run.env.submit-part" >> "$run_dir/run.env"
        rm -f -- "$run_dir/run.env.submit-part"
    else
        mv -f -- "$run_dir/run.env.submit-part" "$run_dir/run.env"
    fi
    printf '  run dir:  %s\n' "$run_dir" >&2

    K8S_LAST_SUBMIT_RUN_DIR="$run_dir"

    # Spool and size the context before creating anything in the cluster or
    # pushing the repository. The EXIT trap covers tar/stat failures and
    # later submit failures, so a large temporary archive cannot leak.
    # K8S_SUBMIT_SESSION_TAR is deliberately NOT reset here: the session
    # store, if any, was already spooled above (before run_dir existed), and
    # resetting it now would drop the trap's only reference to that tar.
    local context_tar="" context_size=""
    K8S_SUBMIT_CONTEXT_TAR=""
    K8S_SUBMIT_THREAD_TAR=""
    K8S_SUBMIT_ATTACH_TAR=""
    K8S_SUBMIT_RUN_DIR_TAR=""
    if [[ -n "$context_ro" ]]; then
        context_tar="$(mktemp)"
        K8S_SUBMIT_CONTEXT_TAR="$context_tar"
        # Replaces (does not stack with) the run-dir-only trap set right
        # after run_dir was created -- bash keeps only the latest EXIT
        # trap -- so this one covers both: a tar/stat failure or an
        # over-cap archive here is still before any cluster object, and
        # must still take run_dir with it.
        trap 'rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"; [[ "$run_dir_created_here" == true ]] && rm -rf -- "$run_dir"' EXIT
        tar cf "$context_tar" -C "$context_ro" .
        context_size="$("$FS_STAT" -c '%s' -- "$context_tar")"
        if (( context_size > CONTEXT_MAX_BYTES )); then
            echo "Error: --context-ro directory '$context_ro' tars to" >&2
            echo "$context_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap." >&2
            exit 1
        fi
    fi

    # Same spool-then-cap treatment as --context-ro above, one tar apiece,
    # same CONTEXT_MAX_BYTES cap -- a context directory and a gathered
    # thread/attachments directory are the same shape of thing (gathered
    # notes and small caches), so they share the one cap rather than
    # growing a --thread-max/--attach-max nobody has needed yet.
    #
    # Unlike --context-ro's `-C DIR .`, these two push into a DEST_DIR
    # that already exists as a mounted emptyDir -- k8s_spool_dir_entries
    # (above) packs the directory's top-level entries instead of `.`
    # itself; see its own comment for why.
    local thread_tar="" thread_size=""
    if [[ -n "$thread_dir" ]]; then
        thread_tar="$(mktemp)"
        K8S_SUBMIT_THREAD_TAR="$thread_tar"
        trap 'rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"; [[ "$run_dir_created_here" == true ]] && rm -rf -- "$run_dir"' EXIT
        k8s_spool_dir_entries "$thread_dir" "$thread_tar"
        thread_size="$("$FS_STAT" -c '%s' -- "$thread_tar")"
        if (( thread_size > CONTEXT_MAX_BYTES )); then
            echo "Error: --thread-dir directory '$thread_dir' tars to" >&2
            echo "$thread_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap." >&2
            exit 1
        fi
    fi
    local attach_tar="" attach_size=""
    if [[ -n "$attach_dir" ]]; then
        attach_tar="$(mktemp)"
        K8S_SUBMIT_ATTACH_TAR="$attach_tar"
        trap 'rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"; [[ "$run_dir_created_here" == true ]] && rm -rf -- "$run_dir"' EXIT
        k8s_spool_dir_entries "$attach_dir" "$attach_tar"
        attach_size="$("$FS_STAT" -c '%s' -- "$attach_tar")"
        if (( attach_size > CONTEXT_MAX_BYTES )); then
            echo "Error: --attach-dir directory '$attach_dir' tars to" >&2
            echo "$attach_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap." >&2
            exit 1
        fi
    fi

    # Runner mode's own push: same shape as thread/attach above (a
    # pre-existing emptyDir, so k8s_spool_dir_entries packs the directory's
    # top-level entries, never `.` itself), same CONTEXT_MAX_BYTES cap --
    # run.sh plus fork-sandbox-runner.sh/fork-sandbox-lib.sh/
    # fork-sandbox-refresh.sh/fork-sandbox-format.sh/the leg wrapper plus
    # every prompt file is well under it.
    local run_dir_tar="" run_dir_tar_size=""
    if [[ -n "$run_dir_flag" ]]; then
        run_dir_tar="$(mktemp)"
        K8S_SUBMIT_RUN_DIR_TAR="$run_dir_tar"
        trap 'rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"; [[ "$run_dir_created_here" == true ]] && rm -rf -- "$run_dir"' EXIT
        k8s_spool_dir_entries "$run_dir_flag" "$run_dir_tar"
        run_dir_tar_size="$("$FS_STAT" -c '%s' -- "$run_dir_tar")"
        if (( run_dir_tar_size > CONTEXT_MAX_BYTES )); then
            echo "Error: --run-dir directory '$run_dir_flag' tars to" >&2
            echo "$run_dir_tar_size bytes, over the $CONTEXT_MAX_BYTES byte" >&2
            echo "(256 MiB) cap." >&2
            exit 1
        fi
    fi

    # The harness session store's tar, size cap and mkdir/chmod are handled
    # earlier, right after fs_validate_session_flags -- before this
    # function's dry-run print and before run.env is written, both of
    # which need to already know whether the store fit. $session_tar and
    # $session_state (cleared there if oversized) are reused below,
    # unchanged, for the push.

    # The stale-grant check: does a NetworkPolicy named $grant_name
    # already exist, most likely left behind by an earlier run on this
    # branch. This is the first kubectl call cmd_submit makes -- run only
    # after --dry-run's exit above, so a dry-run still contacts nothing,
    # per this script's own --dry-run contract. It still runs before any
    # cluster object for THIS run is created, and before the cluster-object
    # EXIT trap below is installed, so a refusal here cannot trigger that
    # trap's by-label delete and touch the stale object it just found.
    if [[ -n "$grant_name" ]]; then
        if [[ -n "$(kubectl get networkpolicy "$grant_name" --ignore-not-found -o name 2>/dev/null)" ]]; then
            echo "Error: a NetworkPolicy named '$grant_name' already exists --" >&2
            echo "most likely a stale grant a previous run on branch '$branch'" >&2
            echo "left behind. Reusing it here would silently widen this run's" >&2
            echo "egress to whatever that grant named. Remove it first:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            exit 1
        fi
    fi

    # --context-secret's label checks, the cluster half of the name checks
    # above. Anything that can create a pod can mount any Secret in its
    # namespace, so the Secret must opt in with fork-sandbox/context=true,
    # and must not carry fork-sandbox/branch: rm and the trap below delete
    # Secrets by that label. Only the labels are read; never the data.
    if [[ -n "$context_secret" ]]; then
        local ctx_secret_labels
        if ! ctx_secret_labels="$(kubectl get secret "$context_secret" -o json 2>/dev/null \
                | jq -r '(.metadata.labels // {}) | "\(.["fork-sandbox/context"] // "")\t\(has("fork-sandbox/branch"))"')" \
            || [[ -z "$ctx_secret_labels" ]]; then
            echo "Error: --context-secret '$context_secret': no such Secret in the" >&2
            echo "cluster namespace." >&2
            exit 1
        fi
        local ctx_secret_ctx_label="${ctx_secret_labels%%$'\t'*}"
        local ctx_secret_has_branch="${ctx_secret_labels##*$'\t'}"
        if [[ "$ctx_secret_ctx_label" != true ]]; then
            echo "Error: --context-secret '$context_secret' lacks the label" >&2
            echo "fork-sandbox/context=true. Label it to opt it in:" >&2
            echo "  kubectl label secret $context_secret fork-sandbox/context=true" >&2
            exit 1
        fi
        if [[ "$ctx_secret_has_branch" == true ]]; then
            echo "Error: --context-secret '$context_secret' carries the label" >&2
            echo "fork-sandbox/branch, so rm and the submit trap would delete it." >&2
            echo "Remove that label from the Secret." >&2
            exit 1
        fi
    fi

    # From here on, a cluster object may exist for this run (the grant
    # below, a Secret further down for the claude harness, the Job either
    # way), so run_dir must survive a failure past this point instead of
    # being taken with it -- resets the trap back to guarding cluster
    # objects instead. K8S_SUBMIT_SAFE_NAME/K8S_SUBMIT_BRANCH are set
    # unconditionally here (not just for claude) because this trap now
    # covers BOTH harnesses: a pi run's grant or Job can fail to apply too,
    # and until now nothing rolled that back -- only claude's own trap,
    # installed further down, deleted anything. The claude branch below
    # installs a strictly richer trap over this one (same by-label delete,
    # plus the claude-token Secret's own by-name delete, since that Secret
    # can be left unlabeled by a failure between its create and its label
    # call); for the pi harness, this is the trap that stays live for the
    # rest of this function.
    K8S_SUBMIT_SAFE_NAME="$safe_name"
    K8S_SUBMIT_BRANCH="$branch"
    trap '
        rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"
        kubectl delete secret "$K8S_SUBMIT_SAFE_NAME-codex-token" --ignore-not-found >&2
        kubectl delete job,pod,service,secret,configmap,networkpolicy \
            -l fork-sandbox/branch="$K8S_SUBMIT_SAFE_NAME" --ignore-not-found >&2
        echo "fork-sandbox-k8s: submit failed -- removed this run'"'"'s cluster" >&2
        echo "objects, if any were created (branch $K8S_SUBMIT_BRANCH)." >&2
    ' EXIT

    # Applied before the claude proxy and the Job below, for either
    # harness, so the egress gate's REACH_PROBES sees it on the pod's very
    # first poll iteration -- see fork-sandbox-k8s-egress-gate.sh.
    if [[ -n "$grant_name" ]]; then
        printf '%s\n' "$grant_rendered" | kubectl apply -f -
    fi

    if [[ "$harness" == claude || "$pipeline_has_claude" == 1 ]]; then
        # The per-run Secret carrying the REAL operator access token, read
        # by the per-run proxy below -- created here, as the LAST step
        # before any cluster object for this run exists, so that every
        # check above (executable checks, ConfigMap key rendering, YAML
        # substitution) has already run and cannot abort submit with a
        # bare token Secret left behind. Built by
        # k8s_render_claude_token_secret_manifest, the same manifest builder
        # k8s_push_claude_key's later replacement uses (see cmd_wait's
        # keeper) -- token on STDIN ONLY, never argv, then applied
        # --server-side (client-side apply would copy the whole Secret,
        # token included, into the last-applied-configuration annotation) --
        # then labeled in a SEPARATE command, since the manifest above
        # carries no labels of its own and this keeps the token off that
        # second command's argv too. Install the trap BEFORE the create
        # command, so a failure in that command or its pipeline still cleans
        # up. The trap covers the gap between
        # the two commands: if the label call itself is what fails, the
        # Secret it leaves behind carries no fork-sandbox/branch label, so
        # the trap's own by-label delete would miss it too -- which is why
        # the trap also deletes this Secret by name. It also removes the
        # pre-sized context archive, if this run has one.
        # K8S_SUBMIT_SAFE_NAME/K8S_SUBMIT_BRANCH are already set, above.
        trap '
            rm -f -- "${K8S_SUBMIT_CONTEXT_TAR:-}" "${K8S_SUBMIT_THREAD_TAR:-}" "${K8S_SUBMIT_ATTACH_TAR:-}" "${K8S_SUBMIT_SESSION_TAR:-}" "${K8S_SUBMIT_RUN_DIR_TAR:-}"
            kubectl delete secret "$K8S_SUBMIT_SAFE_NAME-claude-token" --ignore-not-found >&2
            kubectl delete secret "$K8S_SUBMIT_SAFE_NAME-codex-token" --ignore-not-found >&2
            kubectl delete job,pod,service,secret,configmap,networkpolicy \
                -l fork-sandbox/branch="$K8S_SUBMIT_SAFE_NAME" --ignore-not-found >&2
            echo "fork-sandbox-k8s: submit failed -- removed this run'"'"'s cluster objects, if any were created (branch $K8S_SUBMIT_BRANCH)." >&2
        ' EXIT
        printf '%s' "$claude_access_token" \
            | k8s_render_claude_token_secret_manifest "$safe_name-claude-token" "$K8S_NAMESPACE" \
            | kubectl apply -f - --server-side --field-manager="$K8S_CLAUDE_TOKEN_FIELD_MANAGER" --force-conflicts
        # The attribution labels go on here too, not just fork-sandbox/branch:
        # this Secret is one of the run's objects, and the docs promise every
        # one of them carries the owner. kubectl label takes key=value;
        # run_label_pairs (built above, shared with the grant) already holds
        # exactly this set.
        kubectl label secret "$safe_name-claude-token" \
            "${run_label_pairs[@]}" --overwrite

        # Applied, and waited on, BEFORE the Job below: the egress-gate
        # initContainer probes this proxy the moment the Job's pod starts,
        # and if both went into one `kubectl apply` stream that start could
        # race the proxy's own image pull and readiness, failing the gate
        # closed on a cold node well within its default 60s GATE_TIMEOUT.
        # Two pods per run (proxy + agent): wait for room for both first,
        # and a create the quota still refuses is waited on, not fatal.
        k8s_quota_wait_for_room 2
        k8s_apply_waiting_for_quota "$claude_proxy_rendered"
        echo "fork-sandbox-k8s: waiting for proxy pod ($safe_name-claude-proxy) to be ready" >&2
        kubectl wait --for=condition=Ready "pod/$safe_name-claude-proxy" --timeout=120s
    fi
    if (( pipeline_has_codex )); then
        printf '%s\n' "$codex_key_conf" \
            | k8s_render_upstream_key_secret_manifest "$safe_name-codex-token" "$K8S_NAMESPACE" \
            | kubectl apply -f - --server-side \
                --field-manager="$K8S_CLAUDE_TOKEN_FIELD_MANAGER" --force-conflicts
        kubectl label secret "$safe_name-codex-token" \
            "${run_label_pairs[@]}" --overwrite
        k8s_quota_wait_for_room 2
        k8s_apply_waiting_for_quota "$codex_proxy_rendered"
        echo "fork-sandbox-k8s: waiting for proxy pod ($safe_name-codex-proxy) to be ready" >&2
        kubectl wait --for=condition=Ready "pod/$safe_name-codex-proxy" --timeout=120s
    fi

    # Server-side: client-side apply copies the whole object into the
    # last-applied-configuration annotation, and the scripts ConfigMap
    # (every script plus the rendered handoff) outgrows its 256 KiB cap.
    printf '%s\n' "$job_rendered" | kubectl apply -f - --server-side

    echo "fork-sandbox-k8s: waiting for pod (job $safe_name) to be ready" >&2
    # The Job controller creates the pod asynchronously, and `kubectl wait`
    # with a label selector fails at once ("no matching resources found")
    # when nothing matches yet -- so poll for the pod's existence first,
    # then wait for Ready, both inside one budget. External date/sleep, not
    # bash builtins, so the tests can stub them; no `wait --for=create`
    # (needs kubectl 1.31+).
    #
    # The 180s base covers scheduling and a cold image pull.
    # services_ready_max (0 when no service declares a readyWhen) is added
    # on top, never folded into it, so a service's own startup window is
    # covered IN ADDITION to that base margin, not instead of it.
    local pod_budget=$(( 180 + services_ready_max )) pod_start pod_elapsed pod_remaining
    pod_start="$(date +%s)"
    while [[ -z "$(kubectl get pod -l "job-name=$safe_name" -o name 2>/dev/null || true)" ]]; do
        # A Job controller refused a pod by the namespace quota is a wait on
        # the quota's own budget; the pod-ready budget restarts each blocked
        # iteration, so time spent here never eats it.
        if k8s_job_quota_blocked "$safe_name"; then
            k8s_quota_wait_step "job $safe_name cannot create its pod"
            pod_start="$(date +%s)"
            continue
        fi
        k8s_quota_wait_end
        if (( $(date +%s) - pod_start >= pod_budget )); then
            echo "Error: job $safe_name created no pod within ${pod_budget}s. The Job controller" >&2
            echo "may be blocked (quota, admission, or pod security). Inspect it with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe job $safe_name" >&2
            exit 1
        fi
        sleep 2
    done
    k8s_quota_wait_end
    pod_elapsed=$(( $(date +%s) - pod_start ))
    pod_remaining=$(( pod_budget - pod_elapsed ))
    (( pod_remaining >= 10 )) || pod_remaining=10

    local pod_name
    pod_name="$(kubectl get pod -l "job-name=$safe_name" -o jsonpath='{.items[0].metadata.name}')"
    if [[ -z "$pod_name" ]]; then
        echo "Error: could not find the pod for job $safe_name." >&2
        exit 1
    fi

    local pod_wait_rc=0
    kubectl wait --for=condition=Ready "pod" -l "job-name=$safe_name" --timeout="${pod_remaining}s" \
        || pod_wait_rc=$?
    if (( pod_wait_rc != 0 )); then
        # Pod events are not retained on every cluster, so the container
        # status and log -- still readable on this live, not-yet-reaped
        # pod -- are the evidence named here, instead of kubectl wait's own
        # bare "timed out waiting for the condition".
        k8s_report_unready_pod "$pod_name" "$services_ready_checks"
        exit "$pod_wait_rc"
    fi

    # The push line names the revision the branch starts from, so an
    # operator reading the log can tell a --checkout run from a HEAD run
    # without inspecting the pod.
    local push_src="HEAD"
    if [[ -n "$checkout_ref" ]]; then
        push_src="$checkout_sha"
    fi
    echo "fork-sandbox-k8s: pushing $origin_repo to pod $pod_name (branch starts at $push_src)" >&2
    # -c protocol.ext.allow=always: git disables the ext:: transport by
    # default (post-CVE-2017-1000117 hardening), so an unadorned push here
    # fails with 'fatal: transport "ext" not allowed'. Scoped to this one
    # invocation with git -c, never to global config or GIT_ALLOW_PROTOCOL --
    # this is a real hardening measure, relaxed for exactly one command.
    # -c core.hooksPath=/dev/null: this push runs ON THE HOST, in the repo
    # named on the command line -- and git would otherwise run that repo's
    # own pre-push hook. project_path is caller-supplied, so this script must
    # not trust hooks in a repo it was merely pointed at. Scoped with git -c
    # to this one invocation, never set globally.
    # kubectl exec -i, never -t: a tty applies line-discipline translation
    # to what must stay a binary pack stream, and would corrupt it.
    # The `|| push_rc=$?` rather than a bare call under set -e is what
    # lets the failure branch below dump the pod's log: the agent
    # container has no readinessProbe, so the wait above returns the
    # moment it starts, and an entrypoint that dies early (model
    # discovery against a dead endpoint on an K8S_PROXY_ENDPOINTS
    # install) can terminate the container BEFORE this push lands. git's
    # or kubectl's own error there is a bare "connection refused" that
    # tells the operator nothing -- the entrypoint's fail-fast message
    # is in the container's log, which is what the branch prints.
    # One refspec per --extra-ref rides in the SAME push, so the pod's repo
    # holds every ref by the time the sentinel below is written.
    local -a extra_refspecs=()
    for er_i in "${!extra_ref_names[@]}"; do
        extra_refspecs+=("${extra_ref_shas[$er_i]}:refs/heads/${extra_ref_names[$er_i]}")
    done
    local push_rc=0
    (cd "$origin_repo" && git -c protocol.ext.allow=always -c core.hooksPath=/dev/null push --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i -c agent $pod_name -- git-receive-pack /work/repo.git" \
        "$push_src:refs/heads/$branch" "${extra_refspecs[@]}") || push_rc=$?
    if (( push_rc != 0 )); then
        echo "Error: the repository push to pod $pod_name failed (git exit $push_rc)." >&2
        echo "fork-sandbox-k8s: the pod's agent container log, for the reason:" >&2
        kubectl logs "$pod_name" -c agent 2>/dev/null \
            || echo "fork-sandbox-k8s: (the container log is not available yet)" >&2
        exit 1
    fi

    # Pushed after the repository, before the sentinel below -- a failure
    # here fails submit before /work/.inputs-complete exists, so the pod
    # fails closed on its INPUTS_TIMEOUT exactly as it does for a client
    # that died mid-push. Spooled to a temp file first (rather than piping
    # `tar cf -` straight into the exec) so the cap below is checked before
    # any of it reaches the pod; kubectl exec -i, never -t, for the same
    # binary-stream reason as the repository push above.
    if [[ -n "$context_ro" ]]; then
        echo "fork-sandbox-k8s: pushing context ($context_ro) to pod $pod_name" >&2
        kubectl exec -i -c agent "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$POD_CONTEXT_DIR" "$CONTEXT_MAX_BYTES" context < "$context_tar"
        rm -f -- "$context_tar"
    fi

    # Same push, same extractor, same CALLER literal "context" as
    # --context-ro above: the 256 MiB ceiling is identical either way, so a
    # new CALLER arm in the extractor would be pure duplication for no
    # different behaviour.
    if [[ -n "$thread_dir" ]]; then
        echo "fork-sandbox-k8s: pushing thread ($thread_dir) to pod $pod_name" >&2
        kubectl exec -i -c agent "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$POD_THREAD_DIR" "$CONTEXT_MAX_BYTES" context < "$thread_tar"
        rm -f -- "$thread_tar"
    fi
    if [[ -n "$attach_dir" ]]; then
        echo "fork-sandbox-k8s: pushing attachments ($attach_dir) to pod $pod_name" >&2
        kubectl exec -i -c agent "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$POD_ATTACH_DIR" "$CONTEXT_MAX_BYTES" context < "$attach_tar"
        rm -f -- "$attach_tar"
    fi

    # Same push, same extractor, same CALLER literal "context" as the three
    # above -- pushed even for an empty store (session_tar always exists
    # when session_state is set, see the spool above), so the pod always
    # has SOMETHING at POD_SESSION_DIR once SESSION_HARNESS_STORE=1 tells
    # the entrypoint to look.
    if [[ -n "$session_state" ]]; then
        echo "fork-sandbox-k8s: pushing session store ($session_state) to pod $pod_name" >&2
        kubectl exec -i -c agent "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$POD_SESSION_DIR" "$CONTEXT_MAX_BYTES" context < "$session_tar"
        rm -f -- "$session_tar"
    fi

    # Runner mode's own push, after the repository and every other input --
    # the entrypoint's RUN_DIR handling waits on .inputs-complete exactly
    # like the single-leg path does, so this has to land before it. The
    # "run" volume is mounted in the agent container too (read-write,
    # same as a single-leg pod) even though a composed run's own leg
    # container mounts it read-only -- see "Composed pipelines on --k8s"
    # in docs/kubernetes-runs.md.
    if [[ -n "$run_dir_flag" ]]; then
        echo "fork-sandbox-k8s: pushing the run directory ($run_dir_flag) to pod $pod_name" >&2
        kubectl exec -i -c agent "$pod_name" -- sh /mnt/fork-sandbox/context-extract.sh \
            "$run_dir_flag" "$CONTEXT_MAX_BYTES" context < "$run_dir_tar"
        rm -f -- "$run_dir_tar"
    fi

    kubectl exec -c agent "$pod_name" -- sh -c 'touch /work/.inputs-complete'
    # The pod has been told its inputs are complete: see
    # INPUTS_PUSH_EXPECTED above and cmd_resume's check of the pair.
    printf 'INPUTS_PUSH_COMPLETE=true\n' >> "$run_dir/run.env"

    # Everything this run needs now exists and is up -- nothing left for
    # the cleanup trap above to protect, for either harness.
    trap - EXIT

    echo "fork-sandbox-k8s: submitted. branch=$branch pod=$pod_name" >&2
    echo "fork-sandbox-k8s: fetch with: fork-sandbox-k8s.sh fetch --branch $branch $project_path" >&2
}

# Printed only after the bare `submit` verb (see the dispatch case at the
# bottom of this file) -- never after cmd_run's own internal call to
# cmd_submit, which goes straight on to k8s_run_tail's cmd_wait and so
# starts the keeper itself. Reads K8S_LAST_SUBMIT_RUN_DIR's run.env back,
# the same way cmd_wait itself does, rather than taking any state directly
# from cmd_submit, since by the time this runs cmd_submit has already
# returned and its own locals are gone. Silent for a pi run, or a claude
# run with no file-backed credential recorded (nothing this note would
# apply to).
k8s_note_standalone_submit_keeper() {
    local run_dir="$K8S_LAST_SUBMIT_RUN_DIR" claude_cred_path codex_auth_path_note
    [[ -n "$run_dir" && -f "$run_dir/run.env" ]] || return 0
    codex_auth_path_note="$(read_env_value "$run_dir/run.env" CODEX_AUTH_PATH || true)"
    if [[ -n "$codex_auth_path_note" ]]; then
        echo "fork-sandbox-k8s: the Codex proxy token is refreshed only while" >&2
        echo "'run', 'resume', or 'wait --run-dir $run_dir' is active." >&2
    fi
    claude_cred_path="$(read_env_value "$run_dir/run.env" CLAUDE_CREDENTIAL_PATH || true)"
    [[ -n "$claude_cred_path" ]] || return 0
    echo "fork-sandbox-k8s: the pod's Claude access token is kept alive only" >&2
    echo "while 'run' or 'resume' is running against this branch, or while" >&2
    echo "'wait --run-dir $run_dir' is -- a bare 'submit', or 'wait' with no" >&2
    echo "--run-dir, starts no keeper." >&2
}

cmd_fetch() {
    local branch="" upstream_ref="" upstream_none_reason=""
    local upstream_ref_given=false upstream_none_given=false
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            # Set by cmd_collect, which reads UPSTREAM/UPSTREAM_REASON back
            # from the run's own run.env -- the resolution submit already
            # made, once, before the run started. A standalone fetch (no
            # collect in the picture) passes neither, and this function
            # resolves it itself below instead.
            --upstream) upstream_ref="${2:?--upstream requires a ref}"; upstream_ref_given=true; shift 2 ;;
            --upstream-none) upstream_none_reason="${2:?--upstream-none requires a reason}"; upstream_none_given=true; shift 2 ;;
            -*) echo "Error: unknown option '$1' for fetch." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh fetch [options] --branch NAME <project-path>}"
    [[ -n "$branch" ]] || { echo "Error: fetch requires --branch." >&2; exit 1; }
    if $upstream_ref_given && $upstream_none_given; then
        echo "Error: --upstream and --upstream-none are mutually exclusive." >&2
        exit 1
    fi
    fs_reject_unsafe_chars "$branch" || exit 1

    local origin_repo
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1

    local upstream="$upstream_ref" upstream_reason="$upstream_none_reason"
    if ! $upstream_ref_given && ! $upstream_none_given; then
        # A standalone fetch, with no submit/collect context: resolve now,
        # with no checkout ref, same as a run with no --checkout would
        # (rules 3-5 of the upstream rule: HEAD's own upstream in this
        # repo, else the remote default branch, else none).
        local upstream_errf
        upstream_errf="$(mktemp)"
        upstream="$(fs_resolve_upstream "$origin_repo" "" 2>"$upstream_errf")"
        upstream_reason="$(cat "$upstream_errf")"
        rm -f "$upstream_errf"
    fi

    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    echo "fork-sandbox-k8s: fetching $branch from pod $pod_name" >&2
    # Same -c protocol.ext.allow=always and -i (never -t) as the push side
    # above, and for the same two reasons. core.hooksPath=/dev/null is
    # load-bearing here too, not just on push: this fetch writes straight
    # into refs/heads/$branch in the caller's real repo rather than a
    # remote-tracking ref, and githooks(5) documents reference-transaction as
    # firing on any Git command that performs reference updates, fetch
    # included -- so a hook in project_path's repo would otherwise run here
    # as well.
    # A caller that wraps this call in `if`/`!` (cmd_collect, below) needs
    # the fetch's own exit status to tell a lost fast-forward race from a
    # landed one -- under set -euo pipefail this bare command would
    # otherwise take the whole process down right here on a rejected
    # fetch, with no chance for a caller to catch it at all, so the rc is
    # captured explicitly instead of left to propagate on its own.
    local fetch_rc=0
    (cd "$origin_repo" && git -c protocol.ext.allow=always -c core.hooksPath=/dev/null fetch --quiet \
        "ext::kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE exec -i -c agent $pod_name -- git-upload-pack /work/clone" \
        "refs/heads/$branch:refs/heads/$branch") || fetch_rc=$?

    # Touched regardless of the fetch's own outcome: it is the pod's
    # signal to stop idling and exit, and a rejected fetch (the branch
    # moved in $origin_repo while the pod ran) is not a reason to leave
    # the pod running any longer than a landed one would.
    kubectl exec -c agent "$pod_name" -- sh -c 'touch /work/.fetched' || true
    if (( fetch_rc != 0 )); then
        echo "fork-sandbox-k8s: warning: fetching branch '$branch' from pod $pod_name failed (exit $fetch_rc) -- most likely a non-fast-forward (the branch moved in $origin_repo while the pod ran); its old tip there is untouched." >&2
        return "$fetch_rc"
    fi
    echo "fork-sandbox-k8s: fetched into $origin_repo as branch $branch" >&2

    # Reaching here means the branch exists in $origin_repo at the pod's
    # tip -- the only precondition fs_apply_upstream needs. It never fails
    # the fetch itself: it always returns 0.
    local upstream_line
    upstream_line="$(fs_apply_upstream "$origin_repo" "$branch" "$upstream" "$upstream_reason")"
    echo "$upstream_line" >&2
}

cmd_say() {
    local branch="" text="" have_text=0
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            -)
                # The stdin sentinel, not an option -- same convention
                # fork-sandbox-say.sh uses for "read the message from stdin".
                [[ -n "$branch" ]] \
                    || { echo "Error: the branch comes first: fork-sandbox-k8s.sh say --branch NAME -" >&2; exit 1; }
                (( have_text )) && { echo "Error: only one message may be given" >&2; exit 1; }
                text="$(cat)"
                have_text=1
                shift
                ;;
            -*) echo "Error: unknown option '$1' for say." >&2; exit 1 ;;
            *)
                if (( ! have_text )); then
                    text="$1"
                    have_text=1
                else
                    echo "Error: only one message may be given; quote it as a single argument" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    [[ -n "$branch" ]] || { echo "Error: say requires --branch." >&2; exit 1; }
    (( have_text )) \
        || { echo "Error: nothing to say. Give the message as one quoted argument, or '-' to read it from stdin." >&2; exit 1; }
    # A regex find-one-non-space, NOT ${text//[[:space:]]/}: that glob
    # substitution walks the whole message per multibyte character under a
    # UTF-8 locale, which is quadratic -- 7.5s at 64KB, 33s at 128KB, 139s
    # at 256KB, against ~6ms for this form. An addendum is exactly the
    # input that gets large (a thread, a diff, a log pasted in for the
    # session to read), and fork-sandbox-say.sh's identical check on the
    # local path is where that was first measured.
    [[ "$text" =~ [^[:space:]] ]] \
        || { echo "Error: the message is empty. A blank addendum tells the session nothing." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1

    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    # The search-and-write loop lives in fork-sandbox-k8s-inbox-write.sh,
    # mounted into the pod at /mnt/fork-sandbox/ from the same per-run
    # ConfigMap entrypoint.sh and egress-gate.sh already ride in on -- see
    # that script's own header for why the name is always generated and
    # never taken from an argument, and why the final rename is atomic. It
    # runs as the single command this kubectl exec -i carries on its stdio.
    # kubectl exec -i, never -t: a tty would apply line-discipline
    # translation to the message bytes on their way to `cat`.
    local epoch write_out
    epoch="$(date +%s)"
    if ! write_out="$(printf '%s\n' "$text" | kubectl exec -i -c agent "$pod_name" -- \
        sh /mnt/fork-sandbox/inbox-write.sh "$epoch" "$POD_INBOX_DIR" 2>&1)"; then
        echo "Error: could not write the addendum into pod $pod_name: $write_out" >&2
        exit 1
    fi

    printf 'wrote %s\n' "$write_out"
    # The delivery contract differs by harness: a pi pod has no hook system
    # and only ever polls the inbox itself, but a claude pod installs
    # fork-sandbox-inbox-hook.sh into PostToolUse/Stop (see
    # fork-sandbox-k8s-entrypoint.sh), so delivery is on the very next tool
    # call and a Stop is blocked while the addendum is unread. Read back off
    # the pod's own HARNESS env rather than assumed, since this command has
    # no other record of which harness this run picked.
    local say_harness
    say_harness="$(kubectl get pod "$pod_name" \
        -o jsonpath='{.spec.containers[?(@.name=="agent")].env[?(@.name=="HARNESS")].value}')"
    if [[ "$say_harness" == claude ]]; then
        printf 'delivery: on the next tool call. The pod runs claude, which\n'
        printf 'installs the operator-inbox hook into PostToolUse and Stop --\n'
        printf 'the agent reads the addendum right after its next tool call,\n'
        printf 'and a Stop is blocked while it is still unread.\n'
    else
        printf 'delivery: within ~25 tool calls. The pod runs pi, which has no\n'
        printf 'hook system, so the agent reads the inbox itself -- on a\n'
        printf 'tool-call floor, around long commands, before each commit, and\n'
        printf 'before its final report.\n'
    fi
}

cmd_rm() {
    local branch=""
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            *) echo "Error: unknown option '$1' for rm." >&2; exit 1 ;;
        esac
    done
    [[ -n "$branch" ]] || { echo "Error: rm requires --branch." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1

    local safe_name legacy_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    kubectl delete job "$safe_name" --ignore-not-found
    kubectl delete configmap "$safe_name-scripts" --ignore-not-found
    if [[ "$legacy_name" != "$safe_name" ]]; then
        kubectl delete job "$legacy_name" --ignore-not-found
        kubectl delete configmap "$legacy_name-scripts" --ignore-not-found
    fi
    # Additionally, by label: the claude-proxy Pod, Service, ConfigMap,
    # Secret and NetworkPolicy, none of which the two deletes above name --
    # harmless on a pi run, which never created anything carrying this
    # label beyond the scripts ConfigMap already deleted above.
    kubectl delete pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch="$safe_name" --ignore-not-found
    if [[ "$legacy_name" != "$safe_name" ]]; then
        kubectl delete pod,service,secret,configmap,networkpolicy \
            -l fork-sandbox/branch="$legacy_name" --ignore-not-found
    fi
    echo "fork-sandbox-k8s: removed job and configmap for branch $branch" >&2
}

# k8s_push_claude_key <safe_name> <hm-display> < token-on-stdin
#
# Pushes a replacement Claude access token to this run's live proxy pod --
# an nginx reload, over `kubectl exec` with the token on stdin only -- and
# then to the Secret backing it, applied --server-side (client-side apply
# would copy the whole Secret, token included, into the
# last-applied-configuration annotation), so the two never drift apart.
# Called only from cmd_wait's keeper (k8s_claude_keeper_start below), which
# owns the host-side view of "did the credential change". Uses this file's
# own kubectl() wrapper (which already carries --context/-n), so callers
# need not thread those through themselves.
#
# The token reaches the proxy pod's writable /etc/nginx/key emptyDir (see
# manifests/k8s/31-claude-proxy.yaml) via a temp file in that SAME
# directory, `mv`d over the live key only after `nginx -t` accepts it, with
# the previous key kept as a backup and restored if `nginx -t` rejects the
# new one -- so a bad push leaves the proxy still serving its last good
# key rather than a broken config. Every byte the exec'd script itself
# might print (nginx's own -t/-s reload output) is discarded inside the
# pod; nothing the pod says comes back through this function's own stdout,
# which -- because this runs inside cmd_wait's keeper, and cmd_wait's own
# stdout is the machine-readable exit-code channel k8s_run_tail captures
# with `$(...)` -- must stay silent no matter what.
#
# Prints exactly one line, naming no token, on success ("now
# <hm-display>"); on ANY failure -- an unsafe token, a failed exec, an
# nginx -t the pushed key did not pass, a failed Secret apply -- prints
# exactly one warning line and returns 1. Callers must never treat a
# failure here as a reason to abort the wait.
k8s_push_claude_key() {
    local safe_name="$1" hm="$2" token
    token="$(cat)"
    if ! reject_nginx_unsafe_chars "$token" "the Claude access token"; then
        echo "fork-sandbox-k8s: warning: could not push a new Claude access token to the proxy (the token itself is unsafe for the nginx config)." >&2
        return 1
    fi

    # shellcheck disable=SC2016  # a program for the proxy pod's own sh, not this shell
    local exec_script='dir=/etc/nginx/key
umask 077
cp "$dir/upstream-key.conf" "$dir/upstream-key.conf.bak" 2>/dev/null
cat > "$dir/upstream-key.conf.new" || exit 1
mv -f "$dir/upstream-key.conf.new" "$dir/upstream-key.conf"
if nginx -t >/dev/null 2>&1; then
    nginx -s reload >/dev/null 2>&1
else
    rc=$?
    mv -f "$dir/upstream-key.conf.bak" "$dir/upstream-key.conf" 2>/dev/null
    exit "$rc"
fi'
    # shellcheck disable=SC2016  # the literal text $upstream_key is nginx config, not shell
    if ! printf 'set $upstream_key "%s";\n' "$token" \
        | kubectl exec -i "$safe_name-claude-proxy" -- sh -c "$exec_script" >/dev/null 2>&1; then
        echo "fork-sandbox-k8s: warning: could not push a new Claude access token to the proxy (nginx -t rejected it, or the exec itself failed); the proxy keeps serving its last key." >&2
        return 1
    fi

    if ! printf '%s' "$token" \
        | k8s_render_claude_token_secret_manifest "$safe_name-claude-token" "$K8S_NAMESPACE" \
        | kubectl apply -f - --server-side --field-manager="$K8S_CLAUDE_TOKEN_FIELD_MANAGER" --force-conflicts >/dev/null 2>&1; then
        echo "fork-sandbox-k8s: warning: pushed a new Claude access token to the proxy but could not update its Secret; they may now differ." >&2
        return 1
    fi

    echo "fork-sandbox-k8s: pushed a new Claude access token to the proxy (now $hm)" >&2
}

# K8S_CLAUDE_KEEPER_PID holds the background keeper's PID for exactly as
# long as k8s_claude_keeper_start's subshell is alive, so
# k8s_claude_keeper_stop knows whether there is anything to kill. Global,
# not local to cmd_wait, for the same reason claude-sandboxed's SYNC_LOOP_PID
# is a top-level variable: the stop half runs from an EXIT trap, a different
# call frame than the one that set it.
K8S_CLAUDE_KEEPER_PID=""

# The pod's placeholder credential's expiresAt (2100-01-01T00:00:00Z) -- see
# cmd_submit's placeholder jq.
K8S_PLACEHOLDER_EXPIRES_AT_MS=4102444800000

# k8s_claude_keeper_start <cred-file> <safe_name>
#
# Starts, in the background, the loop that keeps this run's proxy Secret
# and live nginx key in step with the HOST's own Claude credential file
# (<cred-file>) for as long as cmd_wait -- via `wait`, `run` or `resume` --
# is still blocked waiting on this run's pod. Mirrors claude-sandboxed's
# own live-sync loop almost exactly (see there): every 2s it reads the
# host credential's access token (a local file read, cheap) and pushes it,
# via k8s_push_claude_key, when it differs from the last one THIS keeper
# pushed; about every 60s, first in the same tick, it calls
# fs_claude_refresh_if_needed, so a refresh the keeper itself triggers
# costs the pod no extra window on a token about to be revoked.
#
# The "last pushed" value is held only as a hash, in a shell variable,
# never written to disk or a log -- and it starts EMPTY, not seeded from
# the credential file, so the keeper always pushes once, unconditionally,
# on its very first tick. Seeding it from the file's own current token
# instead (matching what cmd_submit pushed) would only be safe if nothing
# could have changed the live proxy's key since submit -- but a `resume`
# or a wake-path relaunch starts a brand new keeper long after submit, and
# the host may have refreshed the credential (revoking the token the proxy
# still holds) in the gap. Pushing once on start, regardless of whether the
# on-disk token "looks unchanged", is what makes the keeper self-correcting
# instead of trusting a baseline it never verified against the proxy.
#
# Exits on its own once its parent (the process that called this function,
# i.e. cmd_wait) is gone, the same `kill -0 "$parent_pid"` idiom claude-
# sandboxed's loop uses, so a SIGKILLed parent cannot leave it running
# forever; the caller is still expected to kill and wait for it explicitly
# on every ordinary exit path (see k8s_claude_keeper_stop). Its own EXIT
# trap protects any refresh it has in flight with
# _fs_claude_refresh_emergency_cleanup, exactly as claude-sandboxed's loop
# does, so a kill landing mid-refresh still merges a completed result
# rather than losing the only live copy of the refresh token.
#
# `exec >/dev/null` first, unconditionally: this subshell is forked from
# inside cmd_wait, whose own stdout may be the write end of a `$(cmd_wait
# ...)` pipe (see k8s_run_tail) -- dropping this process's copy of that fd
# immediately, before anything else runs, means it can never hold that pipe
# open nor leak a stray byte into the exit-code capture, no matter what any
# function called below does to its own stdout.
k8s_claude_keeper_start() {
    local cred_file="$1" safe_name="$2"
    local host_claude_bin
    host_claude_bin="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$host_claude_bin" && -x "$HOME/.local/bin/claude" ]]; then
        host_claude_bin="$HOME/.local/bin/claude"
    fi
    if [[ "$host_claude_bin" == */* ]]; then
        host_claude_bin="$("$FS_REALPATH" "$host_claude_bin" 2>/dev/null || true)"
    fi
    # $BASHPID, not $$: under k8s_run_tail's `$(cmd_wait ...)` the caller is
    # a subshell, and $$ would name the top-level script, which outlives it.
    local parent_pid=$BASHPID
    (
        exec >/dev/null
        cred_dir="$(dirname -- "$cred_file")"
        sync_lock1="$cred_dir/.oauth_refresh.lock"
        sync_lock2="$("$FS_REALPATH" -m "$cred_dir").lock"
        trap '_fs_claude_refresh_emergency_cleanup "$sync_lock1" "$sync_lock2"' EXIT
        # Left empty, deliberately -- see this function's header comment.
        # No hash of any real token collides with the empty string, so the
        # very first tick below always finds "the current token differs
        # from the last one pushed" and pushes it, regardless of whether
        # the on-disk file has moved since submit.
        last_pushed_hash=""
        tick=0
        while kill -0 "$parent_pid" 2>/dev/null; do
            if (( tick % 30 == 0 )); then
                fs_claude_refresh_if_needed "$cred_file" "$host_claude_bin"
            fi
            if [[ -f "$cred_file" ]]; then
                token="$(jq -r '.claudeAiOauth.accessToken // ""' "$cred_file" 2>/dev/null)" || token=""
                if [[ -n "$token" ]]; then
                    hash="$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)"
                    if [[ "$hash" != "$last_pushed_hash" ]]; then
                        exp_ms="$(jq -r '.claudeAiOauth.expiresAt // 0' "$cred_file" 2>/dev/null)" || exp_ms=0
                        [[ "$exp_ms" =~ ^[0-9]+$ ]] || exp_ms=0
                        left_min=$(( exp_ms / 60000 - $(date +%s) / 60 ))
                        hm="$(printf '%dh%02dm' $(( left_min / 60 )) $(( left_min % 60 )))"
                        if printf '%s' "$token" | k8s_push_claude_key "$safe_name" "$hm"; then
                            last_pushed_hash="$hash"
                        fi
                    fi
                fi
            fi
            tick=$(( tick + 1 ))
            sleep 2
        done
    ) &
    K8S_CLAUDE_KEEPER_PID=$!
}

# Stops whatever k8s_claude_keeper_start last started, if anything: kills
# the background subshell and waits for it, so its own EXIT trap (which may
# be mid-refresh, holding claude's locks and a scratch dir with the real
# refresh token in it) runs to completion before this function returns --
# see _fs_claude_refresh_emergency_cleanup. Idempotent: called with no
# keeper running, it does nothing.
k8s_claude_keeper_stop() {
    if [[ -n "$K8S_CLAUDE_KEEPER_PID" ]]; then
        kill "$K8S_CLAUDE_KEEPER_PID" 2>/dev/null
        # `|| true`: this whole script runs under set -e, and `wait` for a
        # PID that died BY SIGNAL (exactly what the kill just above causes)
        # returns 128+signum -- a bare, untested command with that exit
        # status trips set -e right here, aborting the process with THAT
        # status before it ever reaches this function's own end. Installed
        # as an EXIT trap (see cmd_wait), that would silently turn a clean
        # cmd_wait success (agent_rc already written to stdout) into an
        # apparent SIGTERM death for whatever called it.
        wait "$K8S_CLAUDE_KEEPER_PID" 2>/dev/null || true
        K8S_CLAUDE_KEEPER_PID=""
    fi
    # Same defensive ending _fs_claude_refresh_emergency_cleanup uses, for
    # the same reason: this function's own return status must never be
    # anything but 0 once installed as cmd_wait's EXIT trap.
    true
}

# k8s_teardown_claude_proxy <safe_name>
#
# Deletes this run's claude proxy (every object manifests/k8s/31-claude-
# proxy.yaml renders) and its claude-token Secret, by name. A no-op for a
# pi run. Called only from cmd_wait's EXIT trap after a terminal failure:
# nothing will refresh that token again. Never on a timeout, where the
# still-running pod needs the proxy. When 31-claude-proxy.yaml gains an
# object, add it here too.
#
# Output goes to stderr only: stdout is cmd_wait's exit-code channel. A
# delete failure warns once and returns 1; the caller ignores it.
k8s_teardown_claude_proxy() {
    local safe_name="$1"
    if ! kubectl delete \
        pod/"$safe_name-claude-proxy" \
        service/"$safe_name-claude-proxy" \
        configmap/"$safe_name-claude-proxy-conf" \
        networkpolicy/"$safe_name-claude-proxy" \
        secret/"$safe_name-claude-token" \
        --ignore-not-found --wait=false >&2; then
        echo "fork-sandbox-k8s: warning: could not remove this run's claude proxy and token Secret; they may still be live in the cluster." >&2
        return 1
    fi
}

# The Codex access token stays in this proxy's private key volume. This
# mirrors the Claude push, with the token supplied on stdin and no token
# bytes in kubectl arguments, ConfigMaps or agent-container mounts.
k8s_push_codex_key() {
    local safe_name="$1" key_conf
    key_conf="$(cat)"
    # shellcheck disable=SC2016  # nginx variables are literal config text
    [[ "$key_conf" == *'set $upstream_key "'* \
        && "$key_conf" == *'set $upstream_account_id "'* ]] || return 1
    # shellcheck disable=SC2016
    local exec_script='dir=/etc/nginx/key
umask 077
cp "$dir/upstream-key.conf" "$dir/upstream-key.conf.bak" 2>/dev/null
cat > "$dir/upstream-key.conf.new" || exit 1
mv -f "$dir/upstream-key.conf.new" "$dir/upstream-key.conf"
if nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; then
    rm -f "$dir/upstream-key.conf.bak"
else
    rc=$?
    mv -f "$dir/upstream-key.conf.bak" "$dir/upstream-key.conf" 2>/dev/null
    exit "$rc"
fi'
    # shellcheck disable=SC2016
    if ! printf '%s\n' "$key_conf" \
        | kubectl exec -i "$safe_name-codex-proxy" -- sh -c "$exec_script" \
            >/dev/null 2>&1; then
        echo "fork-sandbox-k8s: warning: could not update the Codex proxy key." >&2
        return 1
    fi
    if ! printf '%s\n' "$key_conf" \
        | k8s_render_upstream_key_secret_manifest "$safe_name-codex-token" "$K8S_NAMESPACE" \
        | kubectl apply -f - --server-side \
            --field-manager="$K8S_CLAUDE_TOKEN_FIELD_MANAGER" --force-conflicts \
            >/dev/null 2>&1; then
        echo "fork-sandbox-k8s: warning: Codex proxy key updated, Secret update failed." >&2
        return 1
    fi
}

K8S_CODEX_KEEPER_PID=""
k8s_codex_keeper_start() {
    local auth_path="$1" safe_name="$2" parent_pid=$BASHPID
    (
        exec >/dev/null
        last_hash=""
        while kill -0 "$parent_pid" 2>/dev/null; do
            if ! python3 "$script_dir/fork-sandbox-codex-refresh.py" "$auth_path"; then
                echo "fork-sandbox-k8s: warning: host Codex token refresh failed." >&2
            fi
            key_conf="$(k8s_render_codex_key_conf "$auth_path")" || key_conf=""
            if [[ -n "$key_conf" ]]; then
                hash="$(printf '%s' "$key_conf" | sha256sum | cut -d' ' -f1)"
                if [[ "$hash" != "$last_hash" ]]; then
                    if printf '%s\n' "$key_conf" | k8s_push_codex_key "$safe_name"; then
                        last_hash="$hash"
                    fi
                fi
            fi
            sleep 30
        done
    ) &
    K8S_CODEX_KEEPER_PID=$!
}

k8s_codex_keeper_stop() {
    if [[ -n "$K8S_CODEX_KEEPER_PID" ]]; then
        kill "$K8S_CODEX_KEEPER_PID" 2>/dev/null || true
        wait "$K8S_CODEX_KEEPER_PID" 2>/dev/null || true
        K8S_CODEX_KEEPER_PID=""
    fi
    true
}

k8s_teardown_codex_proxy() {
    local safe_name="$1"
    kubectl delete \
        pod/"$safe_name-codex-proxy" \
        service/"$safe_name-codex-proxy" \
        configmap/"$safe_name-codex-proxy-conf" \
        networkpolicy/"$safe_name-codex-proxy" \
        secret/"$safe_name-codex-token" \
        --ignore-not-found --wait=false >&2
}

# cmd_run's wait phase, standalone: poll the run's pod until its entrypoint
# writes /work/.run-complete (which holds the agent's own exit code),
# failing fast on a dead pod, a Failed job condition, a timeout or a
# malformed sentinel. It exists so a caller fanning out several runs can
# submit them all before waiting on any -- see cmd_run, which composes this
# verb.
#
# On success it prints the agent's exit code to stdout, and nothing else:
# every message in this function goes to stderr, and stdout is unused by
# every other verb in this script, which is what makes it available as the
# machine-readable channel. The distinction that makes this verb worth
# having: a non-zero exit means the WAIT failed, never the agent's exit
# status -- an agent that ran to completion and exited 3 is a successful
# wait that prints 3 and exits 0. The code carries a second,
# machine-readable distinction a probe loop depends on: exit 2 is
# TERMINAL (the pod is dead, gone, or its sentinel unusable -- no further
# wait can succeed, and whatever is left in the pod is at best already
# fetched), while exit 1 is the probe's own deadline (the run may still be
# going) or a usage error.
#
# Captures the agent container's log when cmd_wait finds a Failed pod or a
# Failed job condition -- a pod that died before any leg never reaches
# cmd_collect's own evidence capture (k8s_run_tail below exits on a
# non-zero wait before collect ever runs), so this is the only chance to
# carry the tail into the run's own log and status. Prints the last 40
# lines to stderr, bounded (--request-timeout=60s, like every other
# evidence read in this file) and best effort: a read failure is reported
# but never changes the caller's exit code. Given a non-empty $2 (the run
# directory), also saves the full log to $2/evidence/pod-log-agent.log --
# the exact path pm_wake_exit_record (fork-sandbox-postmaster.sh) already
# reads for a k8s wake's own failure tail.
k8s_capture_failed_agent_log() {
    local pod_name="$1" run_dir="$2" log_tmp="" err_tmp=""
    # Every step is guarded: the caller runs this right before its terminal
    # exit 2, under set -e, and a failure here must not turn that into 1.
    if ! log_tmp="$(mktemp)" || ! err_tmp="$(mktemp)"; then
        echo "fork-sandbox-k8s: could not create a temp file; agent log not captured." >&2
        rm -f -- "$log_tmp"
        return 0
    fi
    if ! kubectl logs "$pod_name" -c agent --request-timeout=60s > "$log_tmp" 2>"$err_tmp"; then
        echo "fork-sandbox-k8s: could not capture $pod_name's agent log." >&2
        fs_report_captured_stderr "kubectl logs $pod_name -c agent" "$err_tmp"
        rm -f -- "$log_tmp" "$err_tmp"
        return 0
    fi
    rm -f -- "$err_tmp"
    echo "fork-sandbox-k8s: $pod_name's agent log (last 40 lines):" >&2
    tail -n 40 -- "$log_tmp" | sed 's/^/    /' >&2 || true
    if [[ -n "$run_dir" ]]; then
        if ! { mkdir -p -- "$run_dir/evidence" \
            && cp -- "$log_tmp" "$run_dir/evidence/pod-log-agent.log"; } 2>/dev/null; then
            echo "fork-sandbox-k8s: could not save the agent log to $run_dir/evidence." >&2
        fi
    fi
    rm -f -- "$log_tmp"
    return 0
}
cmd_wait() {
    local timeout=3600 branch="" project_path="${project_path-}" probe=false run_dir=""
    # Set just before a terminal exit 2 once the pod is known, never under
    # --probe; the EXIT trap then tears down the claude proxy.
    local wait_terminal_teardown=false
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --timeout) timeout="${2:?--timeout requires a number of seconds}"; shift 2 ;;
            --probe) probe=true; shift ;;
            # Optional: names the run directory cmd_submit wrote run.env
            # into, so this wait can find CLAUDE_CREDENTIAL_PATH and keep
            # a --harness claude run's proxy token alive for as long as
            # this call blocks -- see k8s_claude_keeper_start below.
            # k8s_run_tail always passes this when it has a run_dir; a
            # hand-run `wait` gets the keeper only by passing it too.
            --run-dir) run_dir="${2:?--run-dir requires a directory}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for wait." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    [[ -n "$branch" ]] || { echo "Error: wait requires --branch." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "Error: --timeout must be a whole number of seconds, got '$timeout'." >&2
        exit 1
    fi

    # $project_path is not an option: it appears only in the "fetch by hand"
    # advice, and when cmd_run drives this verb through a $(...) capture the
    # run's own local is already in scope in that subshell. ${project_path-}
    # keeps a standalone wait from tripping set -u; the advice line drops the
    # path in that case, since this verb cannot know it.
    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"

    # Every kubectl call on the probe path carries this bound, capped at
    # 10s, so a single hung API server call cannot block past --timeout
    # (or hang forever, absent this, if the API never answers at all).
    local probe_req_timeout=10
    if [[ "$probe" == true ]] && (( probe_req_timeout > timeout )); then
        probe_req_timeout=$timeout
    fi
    local -a probe_kubectl_opts=()
    [[ "$probe" == true ]] && probe_kubectl_opts=(--request-timeout="${probe_req_timeout}s")

    if [[ "$probe" == true ]]; then
        if ! pod_name="$(k8s_probe_find_pod "$safe_name" "$legacy_name" "$probe_req_timeout")"; then
            echo "Error: fork-sandbox-k8s: cannot reach the cluster to probe branch $branch" >&2
            exit 4
        fi
        if [[ -z "$pod_name" ]]; then
            local job_name
            if ! job_name="$(k8s_probe_find_job "$safe_name" "$legacy_name" "$probe_req_timeout")"; then
                echo "Error: fork-sandbox-k8s: cannot reach the cluster to probe branch $branch" >&2
                exit 4
            fi
            if [[ -n "$job_name" ]]; then
                # The Job outlives its pod across an eviction, or a pod
                # not yet scheduled -- not terminal, probe again.
                exit 1
            fi
            echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
            echo "have already been fetched and removed, or the run never started." >&2
            exit 2
        fi
    else
        pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
        if [[ -z "$pod_name" ]]; then
            echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
            echo "have already been fetched and removed, or the run never started." >&2
            exit 2
        fi
    fi

    if [[ "$probe" != true ]]; then
        echo "fork-sandbox-k8s: waiting for branch $branch to finish (polling" >&2
        echo "every 10s, timeout ${timeout}s)" >&2
    fi

    # The keeper: for as long as THIS call blocks, keep a --harness claude
    # run's proxy token in step with the host's own credential file -- see
    # k8s_claude_keeper_start's own header. Started only once pod_name is
    # known (every exit above this point never waited on anything worth
    # keeping alive), and stopped on every exit path below via this trap,
    # including a signal -- k8s_claude_keeper_stop is idempotent when no
    # keeper was ever started. The keeper stops before any teardown. On the
    # success path cmd_wait returns rather than exits, so this trap fires
    # after its locals are gone: the ${...:-} defaults matter under set -u.
    trap '
        k8s_claude_keeper_stop
        k8s_codex_keeper_stop
        if [[ "${wait_terminal_teardown:-false}" == true ]]; then
            k8s_teardown_claude_proxy "${safe_name:-}" || true
            k8s_teardown_codex_proxy "${safe_name:-}" || true
        fi
    ' EXIT
    if [[ -n "$run_dir" && -f "$run_dir/run.env" ]]; then
        local wait_harness claude_cred_path
        wait_harness="$(read_env_value "$run_dir/run.env" harness || true)"
        claude_cred_path="$(read_env_value "$run_dir/run.env" CLAUDE_CREDENTIAL_PATH || true)"
        if [[ -n "$claude_cred_path" ]]; then
            k8s_claude_keeper_start "$claude_cred_path" "$safe_name"
        elif [[ "$wait_harness" == claude ]]; then
            echo "fork-sandbox-k8s: no Claude credential path was recorded for this run" >&2
            echo "(a Keychain-backed credential, or a run submitted before this" >&2
            echo "feature existed) -- the pod's access token will not be kept alive." >&2
        fi
        local codex_auth_path_wait
        codex_auth_path_wait="$(read_env_value "$run_dir/run.env" CODEX_AUTH_PATH || true)"
        if [[ -n "$codex_auth_path_wait" ]]; then
            k8s_codex_keeper_start "$codex_auth_path_wait" "$safe_name"
        fi
    elif [[ "$probe" != true ]]; then
        # No --run-dir at all (a hand-run `wait --branch X` that did not
        # pass the run directory `submit` printed) -- this call cannot even
        # look up the run's harness, so it cannot know whether there is a
        # Claude token to keep alive. Say so once rather than silently
        # leaving it unprotected, matching the note printed after a bare
        # `submit` (see k8s_note_standalone_submit_keeper) and the "no
        # keeper" case just above. Gated on --probe, like the startup and
        # heartbeat messages below: a probe loop (the postmaster's poller)
        # calls this every few seconds with no --run-dir and promises quiet
        # stderr on an ordinary still-running result.
        echo "fork-sandbox-k8s: no --run-dir given -- if this is a --harness" >&2
        echo "claude run, its pod's access token will not be kept alive for" >&2
        echo "this wait. Pass --run-dir <dir> (printed by submit as 'run dir:')" >&2
        echo "to keep it alive." >&2
    fi

    local start_ts now elapsed last_report_ts run_complete phase job_failed
    start_ts=$(date +%s)
    last_report_ts=$start_ts
    run_complete=""
    while true; do
        # One kubectl exec per probe, as the header comment promises -- this
        # single call both checks for the sentinel and reads it, so a
        # completed run needs no second round trip.
        if run_complete="$(kubectl exec "${probe_kubectl_opts[@]}" -c agent "$pod_name" -- cat /work/.run-complete 2>/dev/null)"; then
            break
        fi

        # A pod that dies before writing the sentinel (OOM, crash, image
        # pull failure, node eviction) must not be polled for the full
        # timeout -- check its state every iteration and stop as soon as it
        # is clearly dead, rather than waiting out the deadline on a corpse.
        # A Succeeded pod is dead in the other direction: it ran to
        # completion and then its container exited -- either idling out
        # its TTL or exiting right after a successful fetch. cmd_run
        # never reaches this (it waits while the run executes), but a
        # standalone wait may begin after the fact, in the fan-out
        # workflow this verb exists for.
        #
        # Note for the message below: do not advise a by-hand fetch here.
        # cmd_fetch moves git objects through `kubectl exec` and cmd_
        # collect reads the outbox the same way, and exec cannot run
        # against an exited container -- so nothing this tool offers can
        # reach what is left in the pod's /work volume.
        phase="$(kubectl get pod "${probe_kubectl_opts[@]}" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "$phase" == Failed ]]; then
            echo "Error: pod $pod_name is Failed -- it died before writing" >&2
            echo "/work/.run-complete. Inspect it with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe pod $pod_name" >&2
            echo "fork-sandbox-k8s: the job and pod are left in place for" >&2
            echo "inspection. Remove them with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            [[ "$probe" == true ]] || { wait_terminal_teardown=true; k8s_capture_failed_agent_log "$pod_name" "$run_dir"; }
            exit 2
        fi
        if [[ "$phase" == Succeeded ]]; then
            echo "Error: pod $pod_name is Succeeded -- the run completed and" >&2
            echo "its container has since exited (it idled out its TTL, or it" >&2
            echo "was fetched and left in place). kubectl exec cannot reach an" >&2
            echo "exited container, so neither fetch nor collect can pull the" >&2
            echo "branch or outbox back: whatever is still in the pod's /work" >&2
            echo "volume is unreachable through this tool. This wait began" >&2
            echo "after the run finished. Inspect the pod's logs with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE logs $pod_name" >&2
            echo "If the branch was not fetched before the container exited, the" >&2
            echo "work cannot be recovered through fetch. Remove the job and pod" >&2
            echo "with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            [[ "$probe" == true ]] || wait_terminal_teardown=true
            exit 2
        fi
        job_failed="$(kubectl get job "${probe_kubectl_opts[@]}" "$safe_name" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
        if [[ "$job_failed" == True ]]; then
            echo "Error: job $safe_name reports a Failed condition -- it" >&2
            echo "died before /work/.run-complete appeared. Inspect it with:" >&2
            echo "  kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE describe job $safe_name" >&2
            echo "fork-sandbox-k8s: the job and pod are left in place for" >&2
            echo "inspection. Remove them with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            [[ "$probe" == true ]] || { wait_terminal_teardown=true; k8s_capture_failed_agent_log "$pod_name" "$run_dir"; }
            exit 2
        fi

        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        if (( elapsed >= timeout )); then
            if [[ "$probe" == true ]]; then
                exit 1
            fi
            echo "Error: timed out after ${timeout}s waiting for branch" >&2
            echo "$branch to finish. The pod is still running, holding its" >&2
            echo "work -- run does not fetch a half-finished branch and does" >&2
            echo "not remove a still-running pod. Its claude proxy and token" >&2
            echo "Secret stay up too, for the still-running pod; nothing" >&2
            echo "keeps the token fresh once this wait exits, unless" >&2
            echo "'wait --run-dir' or 'resume' is run again." >&2
            echo "Fetch by hand once it completes:" >&2
            echo "  fork-sandbox-k8s.sh fetch --branch $branch${project_path:+ $project_path}" >&2
            echo "and clean up (job, pod, proxy and token Secret alike)" >&2
            echo "afterwards with:" >&2
            echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
            exit 1
        fi
        # Probe mode promises quiet transient waits, so the progress
        # heartbeat is gated exactly like the startup and timeout messages
        # -- a --probe --timeout over 60s would otherwise leak it.
        if [[ "$probe" != true ]] && (( now - last_report_ts >= 60 )); then
            echo "fork-sandbox-k8s: still waiting on branch $branch (${elapsed}s elapsed)" >&2
            last_report_ts=$now
        fi
        if [[ "$probe" == true ]]; then
            # Never sleep past the deadline: a --probe --timeout 5 must not
            # block for a full 10s poll interval against a still-running
            # pod.
            local remaining poll=10
            (( remaining = timeout - elapsed ))
            (( remaining < poll )) && poll=$remaining
            (( poll < 0 )) && poll=0
            sleep "$poll"
        else
            sleep 10
        fi
    done

    if [[ ! "$run_complete" =~ ^[0-9]+$ ]]; then
        echo "Error: /work/.run-complete on pod $pod_name does not hold an" >&2
        echo "integer exit code (got: '$run_complete'). Treating this as a" >&2
        echo "malformed run rather than guessing at an exit code." >&2
        echo "Inspect it, then fetch by hand if there is anything worth" >&2
        echo "keeping:" >&2
        echo "  fork-sandbox-k8s.sh fetch --branch $branch${project_path:+ $project_path}" >&2
        echo "and clean up afterwards with:" >&2
        echo "  fork-sandbox-k8s.sh rm --branch $branch" >&2
        [[ "$probe" == true ]] || wait_terminal_teardown=true
        exit 2
    fi
    local agent_rc="$run_complete"

    echo "fork-sandbox-k8s: agent finished (exit $agent_rc)" >&2

    printf '%s\n' "$agent_rc"
}

# The byte cap on the run-evidence pull-back: the agent transcript and the
# agent's own stderr logs that cmd_collect pulls from the pod. Same order
# of magnitude as the outbox's FS_OUTBOX_MAX_BYTES -- a JSONL transcript of
# an ordinary session is small, and the cap exists so a session that loops
# writing to its own output cannot fill the host's disk.
FS_RUN_EVIDENCE_MAX_BYTES=$((64 * 1024 * 1024))

# The byte cap on a single pulled summary.json before it is ever handed to
# `jq -s` (which slurps the whole file into memory to count documents --
# see cmd_collect's own comment on why it needs the count, not just the
# parse). summary.json is always a small, flat record -- a few KB even with
# a long retries/continuations history -- so this is generous headroom, not
# a tuned limit: a pod that writes a 200 MB `summary.json` (a bare array
# repeated enough times) must be refused before `jq -s` ever reads it, not
# after it has already bloated to multiple GB of RSS parsing it.
FS_POD_SUMMARY_MAX_BYTES=$((1024 * 1024))

# Files the pod's ENTRYPOINT writes into /work/outbox, not the agent: its
# own harness metadata, for the host's bookkeeping. The zero-harvest check
# in cmd_collect below decides whether "the outbox is empty of anything the
# agent wrote" by discounting these as a class. When
# fork-sandbox-k8s-entrypoint.sh starts writing another metadata file into
# the outbox, register it in THIS list -- here, and only here -- or the
# next one will silently re-break the check the same way
# .fork-sandbox-model already broke the naive every-file count.
FS_OPERATOR_OUTBOX_FILES=(.fork-sandbox-model)

# Count the files an outbox directory holds that the AGENT wrote: every
# file, minus the operator metadata named in FS_OPERATOR_OUTBOX_FILES.
fs_count_agent_outbox_files() {
    local dir="$1" total operator
    total="$(find "$dir" -type f | wc -l)"
    operator="$(fs_count_operator_outbox_files "$dir")"
    printf '%s\n' "$(( total - operator ))"
}

# Count an outbox directory's operator metadata files (top level only: the
# entrypoint writes them flat). Files are matched against
# FS_OPERATOR_OUTBOX_FILES by basename, so a subdirectory the agent happens
# to name like one of them is not discounted.
fs_count_operator_outbox_files() {
    local dir="$1" f known count=0
    while IFS= read -r -d '' f; do
        f="${f##*/}"
        for known in "${FS_OPERATOR_OUTBOX_FILES[@]}"; do
            if [[ "$f" == "$known" ]]; then
                count=$(( count + 1 ))
                break
            fi
        done
    done < <(find "$dir" -maxdepth 1 -type f -print0)
    printf '%s\n' "$count"
}

# Appends a row to the durable run log for $1 (a run directory) -- the
# sandbox-run-log.py record invocation cmd_collect and cmd_run's own
# wait-failure branch both need. Best-effort, like fork-sandbox.sh's own
# local append: a run that finished must never be reported as failed
# because a log append broke, and a machine without sandbox-run-log.py
# installed simply skips it.
fs_record_run_log() {
    local run_dir="$1" run_log_bin
    run_log_bin="$(command -v sandbox-run-log.py 2>/dev/null || true)"
    [[ -n "$run_log_bin" ]] || run_log_bin="$HOME/.claude/scripts/sandbox-run-log.py"
    if [[ -x "$run_log_bin" ]]; then
        "$run_log_bin" record --run-dir "$run_dir" >&2 \
            || echo "fork-sandbox-k8s: run-log append failed" >&2
    fi
}

# cmd_run's collect phase, standalone: read the review loop's outcome (when
# --review-loop N is given and non-zero), pull the pod's /work/outbox back,
# fetch the branch into the named project, and remove the Job and pod unless
# --keep. It exists so a caller fanning out several runs can submit them all,
# wait on them all, and collect them one at a time -- see cmd_run, which
# composes this verb.
cmd_collect() {
    local keep=false branch="" outbox_dir="" outbox_max_arg="" review_loop_cap=""
    local run_dir=""
    while (( $# )); do
        case "$1" in
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --outbox-dir) outbox_dir="${2:?--outbox-dir requires a path}"; shift 2 ;;
            --outbox-max) outbox_max_arg="${2:?--outbox-max requires a size}"; shift 2 ;;
            --review-loop) review_loop_cap="${2:?--review-loop requires a positive integer}"; shift 2 ;;
            --keep) keep=true; shift ;;
            --run-dir) run_dir="${2:?--run-dir requires a path}"; shift 2 ;;
            -*) echo "Error: unknown option '$1' for collect." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh collect [options] --branch NAME <project-path>}"
    [[ -n "$branch" ]] || { echo "Error: collect requires --branch." >&2; exit 1; }
    fs_reject_unsafe_chars "$branch" || exit 1
    # Nothing else on this path validates the cap (cmd_submit's validation
    # only applies to a run), so a garbage value must not reach the
    # `(( review_loop_cap > 0 ))` gate and silently collapse into "no loop
    # read". "0" is accepted and means skip, like an omitted flag: the gate
    # below decides whether the read happens at all.
    if [[ -n "$review_loop_cap" && ! "$review_loop_cap" =~ ^[0-9]+$ ]]; then
        echo "Error: --review-loop takes an integer of review-then-fix iterations" >&2
        echo "(0 or omitted: none), not '$review_loop_cap'." >&2
        exit 1
    fi

    local outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    if [[ -n "$outbox_max_arg" ]]; then
        outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
    fi

    local safe_name legacy_name pod_name
    safe_name="$(k8s_safe_name fork-sandbox-agent "$branch")"
    legacy_name="$(k8s_legacy_safe_name fork-sandbox-agent "$branch")"
    pod_name="$(k8s_find_pod "$safe_name" "$legacy_name")"
    if [[ -z "$pod_name" ]]; then
        echo "Error: no pod found for branch '$branch' (job $safe_name). It may" >&2
        echo "have already been fetched and removed, or the run never started." >&2
        exit 1
    fi

    # The review loop's outcome, when this run carried one. This is the
    # ONLY place a bad loop outcome ever surfaces: the agent's exit code
    # stays the CODING leg's exit code (see fork-sandbox-k8s-entrypoint.sh's
    # own comment on .run-complete for why), so a `--k8s --review-loop` run
    # that hit its cap with findings still open would otherwise report
    # success and say nothing about it. Read before cmd_fetch, so this
    # prints even if the fetch itself fails partway through. It is the
    # same kind of exec as the outbox read below -- runnable while the
    # pod is idle -- so it carries the same request-timeout bound.
    if (( review_loop_cap > 0 )); then
        local loop_json loop_err
        loop_err="$(mktemp)"
        if loop_json="$(kubectl exec --request-timeout=60s -c agent "$pod_name" -- cat /work/review-loop.json 2> "$loop_err")" \
            && jq -e . >/dev/null 2>&1 <<< "$loop_json"; then
            local loop_ended loop_detail loop_iters loop_last_findings
            loop_ended="$(jq -r '.ended // "unknown"' <<< "$loop_json")"
            loop_detail="$(jq -r '.detail // empty' <<< "$loop_json")"
            loop_iters="$(jq -r '.iterations | length' <<< "$loop_json")"
            loop_last_findings="$(jq -r '.iterations[-1].findings // "unknown"' <<< "$loop_json")"
            case "$loop_ended" in
                approved)
                    echo "fork-sandbox-k8s: review loop: APPROVED after $loop_iters iteration(s)" >&2
                    ;;
                cap|no-progress)
                    echo "fork-sandbox-k8s: ################################################" >&2
                    echo "fork-sandbox-k8s: *** review loop ended '$loop_ended' after" >&2
                    echo "fork-sandbox-k8s: *** $loop_iters iteration(s) -- the branch was NOT" >&2
                    echo "fork-sandbox-k8s: *** approved, with $loop_last_findings finding(s)" >&2
                    echo "fork-sandbox-k8s: *** outstanding as of the last iteration." >&2
                    echo "fork-sandbox-k8s: ################################################" >&2
                    ;;
                skipped)
                    echo "fork-sandbox-k8s: review loop skipped${loop_detail:+: $loop_detail}" >&2
                    ;;
                *)
                    echo "fork-sandbox-k8s: ################################################" >&2
                    echo "fork-sandbox-k8s: *** review loop ended '$loop_ended'${loop_detail:+: $loop_detail}" >&2
                    echo "fork-sandbox-k8s: ################################################" >&2
                    ;;
            esac
        else
            echo "fork-sandbox-k8s: warning: could not read /work/review-loop.json" >&2
            echo "from pod $pod_name -- the branch is still worth fetching." >&2
            fs_report_captured_stderr "kubectl exec into pod $pod_name (review-loop.json read)" "$loop_err"
        fi
        rm -f -- "$loop_err"
    fi

    # Pull /work/outbox back, symmetric with the local path's run_dir/outbox
    # (see fs_emit_prompt_preamble's "## Artifact outbox" section). This is
    # best-effort: retrieving artifacts must never cost the branch fetch
    # that follows, or block the --keep/rm step below, so every failure here
    # warns and falls through rather than exiting. It runs BEFORE that
    # fetch, not after it, because cmd_fetch touches /work/.fetched -- the
    # pod's own signal to stop idling and exit (see the entrypoint's idle
    # loop) -- and a kubectl exec into a completed pod fails. This read
    # and the review-loop.json read above are the kubectl execs in this
    # sequence that can run while the pod is otherwise idle, so both are
    # bounded with --request-timeout: a hung connection may now delay the
    # fetch, but it cannot hang indefinitely.
    local outbox_dest="$outbox_dir"
    if [[ -z "$outbox_dest" ]]; then
        if [[ -n "$run_dir" ]]; then
            outbox_dest="$run_dir/outbox"
        else
            outbox_dest="$FS_SCRATCH_ROOT/forks/k8s-$(k8s_safe_name_component "$branch")/outbox"
            # A later run or re-collect of this branch must start with its
            # own artifacts. The extractor refuses a nonempty destination.
            rm -rf -- "$outbox_dest" "$(dirname -- "$outbox_dest")/evidence"
        fi
    fi
    local outbox_tar outbox_err outbox_ok=true outbox_rc=0
    local outbox_agent_count=0 outbox_operator_count=0
    outbox_tar="$(mktemp)"
    outbox_err="$(mktemp)"
    kubectl exec --request-timeout=60s -c agent "$pod_name" -- tar cf - -C /work/outbox . 2> "$outbox_err" \
            | head -c "$((outbox_max_bytes + 1))" > "$outbox_tar" \
            || outbox_rc=$?
    # Size check BEFORE exit status: an outbox well past the cap makes
    # head -c exit early, kubectl then dies of EPIPE and the pipeline is
    # non-zero under pipefail -- but that IS the over-cap case, not a
    # read failure, because by the time head has had to close, outbox_tar
    # is always filled to cap+1 bytes. Only a non-zero pipeline that
    # leaves the tarball under the cap is a genuine read error.
    if (( $("$FS_STAT" -c '%s' -- "$outbox_tar") > outbox_max_bytes )); then
        echo "fork-sandbox-k8s: warning: pod $pod_name's outbox is over the $outbox_max_bytes byte cap; refusing to pull it back." >&2
        outbox_ok=false
    elif (( outbox_rc != 0 )); then
        echo "fork-sandbox-k8s: warning: could not read the outbox from pod $pod_name; nothing pulled back." >&2
        fs_report_captured_stderr "kubectl exec into pod $pod_name (outbox read)" "$outbox_err"
        outbox_ok=false
    fi
    rm -f -- "$outbox_err"
    if [[ "$outbox_ok" == true ]] && ! mkdir -p -- "$(dirname -- "$outbox_dest")"; then
        echo "fork-sandbox-k8s: warning: could not create $(dirname -- "$outbox_dest"); outbox not pulled back." >&2
        outbox_ok=false
    fi
    if [[ "$outbox_ok" == true ]]; then
        if "$script_dir/fork-sandbox-k8s-outbox-extract.sh" "$outbox_tar" "$outbox_dest" "$outbox_max_bytes"; then
            # Count only what the AGENT wrote: the entrypoint puts its own
            # metadata dotfile(s) into the outbox (named in
            # FS_OPERATOR_OUTBOX_FILES), and a completely dead run's outbox
            # holds exactly one of them. Counting every file would let that
            # one stand in for a harvest -- the failure the zero-harvest
            # check below exists to catch.
            outbox_agent_count="$(fs_count_agent_outbox_files "$outbox_dest")"
            outbox_operator_count="$(fs_count_operator_outbox_files "$outbox_dest")"
            if (( outbox_agent_count > 0 )); then
                local outbox_count_note=""
                if (( outbox_operator_count > 0 )); then
                    outbox_count_note=" ($outbox_operator_count operator metadata file(s) not counted)"
                fi
                echo "fork-sandbox-k8s: outbox: $outbox_agent_count agent file(s) at $outbox_dest$outbox_count_note" >&2
            elif (( outbox_operator_count > 0 )); then
                echo "fork-sandbox-k8s: outbox: empty of agent files (only $outbox_operator_count operator metadata file(s))" >&2
            else
                echo "fork-sandbox-k8s: outbox: empty (nothing written)" >&2
            fi
        else
            echo "fork-sandbox-k8s: warning: could not extract the outbox tarball; nothing pulled back to $outbox_dest" >&2
            # A REFUSED archive is a failed read for the zero-harvest check
            # below, not an empty one: the guard refuses whole archives that
            # hold a link entry, an absolute path, or a `..` component, and a
            # symlinked report is a natural agent habit -- the archive
            # refused is evidence the agent DID write, that the count above
            # simply never got to see. Leaving outbox_ok true here would let
            # the conjunction read "nothing was extracted" as "the agent
            # wrote nothing".
            outbox_ok=false
        fi
    fi
    # The pod's harness metadata dotfile, when the outbox came back:
    # line 1 is the bare model id (the pre-existing shape), and an
    # entrypoint that ran model discovery appends the context facts it
    # established for that id as key=value lines. Absent extra lines are
    # not an error -- an older pod image predates them -- and neither is
    # an unrecognized line. Surface whatever is there so a completed run's
    # record says whether its context was reported or guessed; the
    # entrypoint's own comment on the file records why (the 32768
    # fingerprint that makes a bare number unreadable).
    if [[ -f "$outbox_dest/.fork-sandbox-model" ]]; then
        local model_record model_facts="" model_line
        # Bounded with head -c ahead of the line reads below, on top of
        # (not instead of) the extractor's own total-size cap over the
        # whole outbox archive: a `head -n 1` or line-at-a-time `read`
        # loop has no cap of its own, and this file is small structured
        # metadata (a model id plus a few key=value lines) that never
        # legitimately approaches even this bound, so it costs nothing
        # real here and closes the "every read of a pod-written file on
        # the host must also be bounded" requirement for this one
        # directly, rather than resting solely on the extractor upstream.
        model_record="$(head -c 65536 -- "$outbox_dest/.fork-sandbox-model" | head -n 1)"
        while IFS= read -r model_line || [[ -n "$model_line" ]]; do
            case "$model_line" in
                context=*) model_facts+="${model_facts:+, }$model_line" ;;
                max_tokens=*) model_facts+="${model_facts:+, }$model_line" ;;
                context_source=*) model_facts+="${model_facts:+, }$model_line" ;;
            esac
        done < <(head -c 65536 -- "$outbox_dest/.fork-sandbox-model" | tail -n +2)
        if [[ -n "$model_record" ]]; then
            # $model_record and $model_facts are pod-controlled bytes (the
            # outbox's own untrusted content), printed straight to the
            # operator's terminal here the same way fork-sandbox-status.sh's
            # verdict/log/summary readers are -- stripped of control bytes
            # for the same reason: an escape sequence (OSC 52 clipboard
            # write, among others) surviving this echo reaches both a real
            # terminal and any orchestrating agent session reading this
            # script's stderr, making it a prompt-injection channel too.
            printf 'fork-sandbox-k8s: model: %s%s\n' \
                "$model_record" "${model_facts:+ ($model_facts)}" \
                | tr -d '\000-\010\013-\037\177' >&2
        fi
    fi
    rm -f -- "$outbox_tar"

    # The run's evidence, pulled back BEFORE the fetch for exactly the
    # reason the outbox read above runs before it: cmd_fetch touches
    # /work/.fetched -- the pod's own signal to stop idling and exit --
    # and a kubectl exec into a completed pod fails. The primary evidence
    # is the agent's transcript: /work/events.jsonl, the cluster-side
    # analogue of the local path's <run-dir>/events.jsonl (the entrypoint
    # redirects the agent's output there), plus the review loop's legs at
    # /work/events-<kind>-<n>.jsonl and the agent's own stderr log. The
    # pod's stdout is NOT this: it is the entrypoint narrating its own
    # steps -- a handful of lines on a silent seat -- and a perfect capture of
    # it answers nothing about what the agent did. The pod's logs come
    # back too, named per container, as a supplement for connection-level
    # diagnosis.
    #
    # Written to a SIBLING of the outbox directory, never inside it: the
    # outbox is the agent's artifact space, and operator-captured evidence
    # must stay distinguishable from what the agent chose to write -- the
    # zero-harvest check below depends on that distinction.
    #
    # Like the outbox read, a failure here warns and falls through rather
    # than exiting: retrieving evidence must never cost the branch fetch
    # that follows. But a failed capture is recorded in evidence_ok and
    # governs the reap decision at the bottom of this function: a run
    # whose evidence was not captured is not reaped, because reaping is
    # what destroys the record.
    local evidence_dir
    evidence_dir="$(dirname -- "$outbox_dest")/evidence"
    local evidence_ok=true
    # An earlier collect's refresh.json must not stand in for this pod's:
    # summary.json reads it below, and a pod with no record (or a failed
    # capture) has to leave the refresh keys absent, not inherit old ones.
    rm -f -- "$evidence_dir/refresh.json"
    local events_tar events_err events_rc=0
    events_tar="$(mktemp)"
    events_err="$(mktemp)"
    kubectl exec --request-timeout=60s -c agent "$pod_name" -- \
            sh -c 'cd /work && find . -maxdepth 1 -name "events*.jsonl" -o -name "pi-stderr.log" -o -name "claude-stderr.log" -o -name "claude-stderr-*.log" -o -name "handoff-*.md" -o -name "continuation-prompt-*.md" -o -name "refresh.json" -o -name "refresh.log" | tar cf - --files-from=-' \
            2> "$events_err" \
            | head -c "$((FS_RUN_EVIDENCE_MAX_BYTES + 1))" > "$events_tar" \
            || events_rc=$?
    # Same size-check-before-exit-status ordering as the outbox read above:
    # an over-cap stream makes head -c exit early and the pipeline non-zero
    # under pipefail, and that IS the over-cap case, not a read failure.
    if (( $("$FS_STAT" -c '%s' -- "$events_tar") > FS_RUN_EVIDENCE_MAX_BYTES )); then
        echo "fork-sandbox-k8s: warning: pod $pod_name's transcript is over the $FS_RUN_EVIDENCE_MAX_BYTES byte cap; refusing to pull it back." >&2
        evidence_ok=false
    elif (( events_rc != 0 )); then
        echo "fork-sandbox-k8s: warning: could not read the transcript from pod $pod_name; no transcript pulled back." >&2
        fs_report_captured_stderr "kubectl exec into pod $pod_name (transcript read)" "$events_err"
        evidence_ok=false
    fi
    rm -f -- "$events_err"
    # The shared extraction guard, same as the outbox: untarring a stream
    # from an untrusted pod is a path-traversal sink. A 0-byte spool is a
    # stream that produced NO bytes at all -- the pod held none of the
    # named files -- not a truncated archive, so there is nothing to
    # extract and nothing that failed.
    if [[ "$evidence_ok" == true ]] \
        && (( $("$FS_STAT" -c '%s' -- "$events_tar") > 0 )) \
        && ! "$script_dir/fork-sandbox-k8s-outbox-extract.sh" "$events_tar" "$evidence_dir" "$FS_RUN_EVIDENCE_MAX_BYTES"; then
        echo "fork-sandbox-k8s: warning: could not extract the transcript tarball; no transcript pulled back to $evidence_dir" >&2
        evidence_ok=false
    fi
    rm -f -- "$events_tar"

    # The pod's own logs, one file per container, alongside the
    # transcript: the entrypoint narration and (on a claude run) the
    # proxy's connectivity errors. A supplement to the transcript above,
    # which is the actual record of what the agent did.
    if ! mkdir -p -- "$evidence_dir"; then
        echo "fork-sandbox-k8s: warning: could not create $evidence_dir; pod logs not captured." >&2
        evidence_ok=false
    else
        local pod_json pod_json_err containers c
        pod_json_err="$(mktemp)"
        if ! pod_json="$(kubectl get pod "$pod_name" -o json --request-timeout=60s 2> "$pod_json_err")"; then
            echo "fork-sandbox-k8s: warning: could not read pod $pod_name's spec; pod logs not captured." >&2
            fs_report_captured_stderr "kubectl get pod $pod_name (spec read)" "$pod_json_err"
            evidence_ok=false
        elif ! containers="$(jq -r '(.spec.containers // []) + (.spec.initContainers // []) | .[].name' <<< "$pod_json")" \
            || [[ -z "$containers" ]]; then
            # The spec came back but carries no readable container list --
            # not JSON at all, or JSON with no containers (a live pod always
            # has some). Like every other failure in this block, that is a
            # FAILED capture: it warns and records itself in evidence_ok, so
            # the reap rule below keeps the run rather than reaping a run
            # whose pod logs were never captured.
            echo "fork-sandbox-k8s: warning: could not read the container names from pod $pod_name's spec; pod logs not captured." >&2
            evidence_ok=false
        else
            while IFS= read -r c; do
                [[ -n "$c" ]] || continue
                if ! kubectl logs "$pod_name" -c "$c" --request-timeout=60s > "$evidence_dir/pod-log-$c.log" 2> "$pod_json_err"; then
                    echo "fork-sandbox-k8s: warning: could not capture the pod logs for container '$c' of $pod_name." >&2
                    fs_report_captured_stderr "kubectl logs $pod_name -c $c" "$pod_json_err"
                    evidence_ok=false
                fi
            done <<< "$containers"
        fi
        rm -f -- "$pod_json_err"
    fi

    # Pull /work/session-store back into the host's --session-state store,
    # so the NEXT wake on this seat resumes the same conversation instead
    # of starting fresh -- the k8s half of the continuity --session-state
    # already gives a local run. Read back from run.env, not accepted as
    # collect's own flag: only submit knows session_state/session_id, the
    # same reason harness/model are read back rather than re-specified
    # here (see the run_dir block below). Runs BEFORE cmd_fetch, for the
    # same reason the outbox and evidence pulls above do: cmd_fetch
    # touches /work/.fetched, the pod's own signal to exit, and a kubectl
    # exec into a completed pod fails.
    #
    # Best-effort like the outbox pull above, but stricter: a failure here
    # -- an exec error, an over-cap store, or an archive the extractor
    # refuses (a link entry, an absolute path, a `..` component) -- warns
    # and falls through, never touching the function's exit code, and
    # never touching the host store either. The swap below only happens
    # once the spool AND the extraction have both already succeeded, so
    # any earlier failure leaves the pre-pull store byte-identical.
    # fs_session_discover_id (called at the summary write further down)
    # then reports whichever id the store actually holds -- the previous
    # one, on a failed pull: the seat keeps its persona and loses only
    # this turn.
    local pull_session_state="" pull_session_id=""
    if [[ -n "$run_dir" ]]; then
        pull_session_state="$(read_env_value "$run_dir/run.env" session_state || true)"
        pull_session_id="$(read_env_value "$run_dir/run.env" session_id || true)"
    fi
    if [[ -n "$pull_session_state" ]]; then
        local session_pull_ok=true
        local session_pull_tar session_pull_err session_pull_rc=0 session_pull_tmp=""
        session_pull_tar="$(mktemp)"
        session_pull_err="$(mktemp)"
        kubectl exec --request-timeout=60s -c agent "$pod_name" -- tar cf - -C /work/session-store . 2> "$session_pull_err" \
                | head -c "$((CONTEXT_MAX_BYTES + 1))" > "$session_pull_tar" \
                || session_pull_rc=$?
        # Same size-check-before-exit-status ordering as the outbox pull
        # above, for the identical reason: an over-cap store makes head -c
        # exit early, kubectl then dies of EPIPE and the pipeline is
        # non-zero under pipefail -- that IS the over-cap case, not a read
        # failure.
        if (( $("$FS_STAT" -c '%s' -- "$session_pull_tar") > CONTEXT_MAX_BYTES )); then
            echo "fork-sandbox-k8s: warning: pod $pod_name's session store is over the $CONTEXT_MAX_BYTES byte cap; leaving the host session store as it was." >&2
            session_pull_ok=false
        elif (( session_pull_rc != 0 )); then
            echo "fork-sandbox-k8s: warning: could not read the session store from pod $pod_name; leaving the host session store as it was." >&2
            fs_report_captured_stderr "kubectl exec into pod $pod_name (session store read)" "$session_pull_err"
            session_pull_ok=false
        fi
        rm -f -- "$session_pull_err"

        if [[ "$session_pull_ok" == true ]] && ! mkdir -p -- "$(dirname -- "$pull_session_state")"; then
            echo "fork-sandbox-k8s: warning: could not create $(dirname -- "$pull_session_state"); session store not pulled back." >&2
            session_pull_ok=false
        fi
        if [[ "$session_pull_ok" == true ]] \
            && ! session_pull_tmp="$(mktemp -d -- "$(dirname -- "$pull_session_state")/.session-pull.XXXXXX")"; then
            echo "fork-sandbox-k8s: warning: could not create a staging directory for the session store; leaving it as it was." >&2
            session_pull_ok=false
        fi
        if [[ "$session_pull_ok" == true ]] \
            && ! "$script_dir/fork-sandbox-k8s-outbox-extract.sh" "$session_pull_tar" "$session_pull_tmp" "$CONTEXT_MAX_BYTES"; then
            echo "fork-sandbox-k8s: warning: could not extract the session store tarball; leaving the host session store as it was." >&2
            session_pull_ok=false
        fi
        rm -f -- "$session_pull_tar"

        if [[ "$session_pull_ok" == true ]]; then
            # Atomic swap: move the current store aside, move the pulled
            # one into place, then remove the old one -- only once the new
            # one is confirmed in place. A missing pull_session_state (a
            # first-ever collect run on a host that never held this store,
            # e.g. a different host than the one that ran submit) skips
            # straight to installing the pulled store, nothing to move
            # aside.
            local session_pull_old=""
            if [[ -e "$pull_session_state" ]]; then
                session_pull_old="$(mktemp -u -- "${pull_session_state}.old.XXXXXX")"
                if ! mv -- "$pull_session_state" "$session_pull_old"; then
                    echo "fork-sandbox-k8s: warning: could not move aside the existing session store $pull_session_state; leaving it as it was." >&2
                    session_pull_ok=false
                fi
            fi
            if [[ "$session_pull_ok" == true ]]; then
                if ! mv -- "$session_pull_tmp" "$pull_session_state"; then
                    echo "fork-sandbox-k8s: warning: could not install the pulled session store at $pull_session_state; restoring the previous one." >&2
                    [[ -n "$session_pull_old" && -e "$session_pull_old" ]] && mv -- "$session_pull_old" "$pull_session_state"
                    session_pull_ok=false
                else
                    chmod 700 -- "$pull_session_state"
                    [[ -n "$session_pull_old" && -e "$session_pull_old" ]] && rm -rf -- "$session_pull_old"
                fi
            fi
        fi
        [[ -n "$session_pull_tmp" && -e "$session_pull_tmp" ]] && rm -rf -- "$session_pull_tmp"
    fi

    # Runner mode (RUNNER=1 in run.env, written by a --run-dir submit --
    # see its own doc comment above cmd_submit): the pod walked a
    # pre-staged pipeline through the shared runner rather than running a
    # single HARNESS/MODEL leg, and everything that walk produced --
    # step-<K>-loop.json, progress.json, every events*.jsonl, sandbox.log,
    # verdicts and the runner's own summary.json -- lives in the pod's
    # own copy of this same run directory (mounted at $run_dir's own
    # absolute path, per --run-dir's emptyDir), not under /work/outbox or
    # /work (the evidence pull above pulls transcripts, not these).
    # Pulled into a FRESH staging directory, never straight into
    # $run_dir: the shared extractor refuses to extract into a directory
    # that already exists and is non-empty, and $run_dir always already
    # holds the host-written files (run.sh, pipeline.json, run.env,
    # scripts/, inbox/, any staged skill) that must survive this collect
    # untouched. Only an allowlist of named artifacts is then copied up
    # into $run_dir from the staging copy (see the loop below) -- the
    # pod's copy sits on an emptyDir every leg in the pod could write to,
    # so a blind copy of everything the pod has would let a leg plant any
    # file the host lacks by name, exit-code and pid among them.
    #
    # Best-effort, like the outbox and evidence pulls above: a failure
    # here must not cost the branch fetch that follows, and never touches
    # this function's exit code. The pod's own summary.json is read out
    # of the staging copy explicitly, into run_dir_pod_summary, BEFORE the
    # allowlisted copy below would otherwise leave it sitting unread in
    # $run_dir/summary.json: the client's own summary.json write further
    # down truncates that file, so reading it after would be too late.
    # See that write, below, for the merge this feeds (client keys win on
    # overlap; the pod's summary.json stands alone when no summary.json
    # was pulled).
    local runner_mode="" run_dir_pod_summary=""
    if [[ -n "$run_dir" ]]; then
        runner_mode="$(read_env_value "$run_dir/run.env" RUNNER || true)"
    fi
    if [[ "$runner_mode" == 1 ]]; then
        local run_dir_pull_ok=true
        local run_dir_pull_tar run_dir_pull_err run_dir_pull_rc=0 run_dir_pull_tmp=""
        run_dir_pull_tar="$(mktemp)"
        run_dir_pull_err="$(mktemp)"
        kubectl exec --request-timeout=60s -c agent "$pod_name" -- tar cf - -C "$run_dir" . 2> "$run_dir_pull_err" \
                | head -c "$((CONTEXT_MAX_BYTES + 1))" > "$run_dir_pull_tar" \
                || run_dir_pull_rc=$?
        # Same size-check-before-exit-status ordering as the outbox and
        # session-store pulls above, for the identical reason: an
        # over-cap directory makes head -c exit early, kubectl then dies
        # of EPIPE and the pipeline is non-zero under pipefail -- that IS
        # the over-cap case, not a read failure.
        if (( $("$FS_STAT" -c '%s' -- "$run_dir_pull_tar") > CONTEXT_MAX_BYTES )); then
            echo "fork-sandbox-k8s: warning: pod $pod_name's run directory is over the $CONTEXT_MAX_BYTES byte cap; refusing to pull its runner records back." >&2
            run_dir_pull_ok=false
        elif (( run_dir_pull_rc != 0 )); then
            echo "fork-sandbox-k8s: warning: could not read the run directory from pod $pod_name; no runner records pulled back." >&2
            fs_report_captured_stderr "kubectl exec into pod $pod_name (run directory read)" "$run_dir_pull_err"
            run_dir_pull_ok=false
        fi
        rm -f -- "$run_dir_pull_err"

        if [[ "$run_dir_pull_ok" == true ]] && ! run_dir_pull_tmp="$(mktemp -d)"; then
            echo "fork-sandbox-k8s: warning: could not create a staging directory for the run directory pull; no runner records pulled back." >&2
            run_dir_pull_ok=false
        fi
        if [[ "$run_dir_pull_ok" == true ]] \
            && ! "$script_dir/fork-sandbox-k8s-outbox-extract.sh" "$run_dir_pull_tar" "$run_dir_pull_tmp" "$CONTEXT_MAX_BYTES"; then
            echo "fork-sandbox-k8s: warning: could not extract the run directory tarball; no runner records pulled back." >&2
            run_dir_pull_ok=false
        fi
        rm -f -- "$run_dir_pull_tar"

        if [[ "$run_dir_pull_ok" == true ]]; then
            if [[ -s "$run_dir_pull_tmp/summary.json" ]]; then
                # A pod leg can write summary.json more than once -- two
                # JSON documents concatenated, not one -- and `jq -c .`
                # with no -s processes each document separately, printing
                # one line apiece. The merge below slurps this value with
                # `jq -s`, so two documents here would slurp as the pod's
                # OWN two objects ahead of the client's single object, and
                # ".[0] * .[1]" would merge the pod's two against each
                # other, never reaching the client's write at all -- by
                # experiment, a planted second document completely
                # replaced the client's branch/origin_repo/commits/
                # exit_code. Require exactly one JSON value, and that it
                # is an object; `jq -s '.'` here only counts documents, it
                # is never itself fed into the merge.
                #
                # Sized BEFORE that slurp, not after: `jq -s` reads the
                # whole file into memory to build the array it counts, so
                # the cap has to gate the read itself, the same discipline
                # every other pod pull in this function already applies
                # (outbox, evidence, session store, this very directory).
                # A legitimate summary.json is a few KB; refusing anything
                # over FS_POD_SUMMARY_MAX_BYTES costs nothing real and
                # stops a planted multi-hundred-MB file from ever reaching
                # jq at all.
                local run_dir_pod_summary_size
                run_dir_pod_summary_size="$("$FS_STAT" -c '%s' -- "$run_dir_pull_tmp/summary.json" 2>/dev/null || echo -1)"
                if (( run_dir_pod_summary_size >= 0 && run_dir_pod_summary_size <= FS_POD_SUMMARY_MAX_BYTES )); then
                    local run_dir_pod_summary_docs
                    run_dir_pod_summary_docs="$(jq -s '.' < "$run_dir_pull_tmp/summary.json" 2>/dev/null)"
                    if [[ "$(printf '%s' "$run_dir_pod_summary_docs" | jq 'length' 2>/dev/null)" == 1 ]] \
                            && [[ "$(printf '%s' "$run_dir_pod_summary_docs" | jq -r '.[0] | type' 2>/dev/null)" == object ]]; then
                        # Allowlist, not the whole object, even once it is
                        # confirmed to be exactly one object: every host-known
                        # fact the client's own write below sets itself
                        # (branch, origin_repo, commits, exit_code, run_dir/
                        # clone_dir/base_sha, started_at/ended_at/
                        # duration_seconds, session_id, harness/model/network/
                        # image) must come from the host, never the pod. The
                        # client wins on overlap further down regardless, but
                        # a key the client has no occasion to set at all
                        # (session_id, on a run with no --session-state) would
                        # otherwise pass through from the pod completely
                        # unchallenged. Only fields the pod's own in-process
                        # runner computes and nothing else can -- cost, usage,
                        # retries, the uncommitted-work check -- are let
                        # through. tidy and tidy_has_maintain_step are
                        # deliberately NOT in this list, unlike every other
                        # field the runner's own summary.json carries: the
                        # host already knows, unconditionally, that a --k8s
                        # pod run never runs the tidy-history leg (see the
                        # tidy.json write further below), so a pod claiming
                        # {"tidy":{"ended":"accepted"}} would otherwise pass
                        # straight through into the host's summary.json with
                        # nothing there to collide with and override it --
                        # the client's own write never sets a "tidy" key
                        # itself, so "the client wins on overlap" above gives
                        # this one no protection at all. The host sets both
                        # keys itself, from tidy.json, alongside the merge
                        # below. Every numeric leaf is also bounded (walk
                        # below): a pod that reports cost_usd as 1e1000
                        # parses as a legal-looking but non-finite JSON
                        # number, and that survives an ordinary jq pass
                        # unchanged (jq preserves a number literal it never
                        # touches) -- it is only downstream, in Python's json
                        # module, that it becomes the bareword Infinity, not
                        # valid JSON. Null out anything non-finite or
                        # absurdly large here, at the host's one choke point
                        # for pod-reported numbers, rather than relying
                        # solely on sandbox-run-log.py's own defenses.
                        run_dir_pod_summary="$(printf '%s' "$run_dir_pod_summary_docs" | jq -c '
                            .[0]
                            | {cost_usd, total_cost_usd, usage, usage_source, leg_retries,
                               implement_retries, uncommitted_files, uncommitted_files_list,
                               uncommitted_patch,
                               continuations, leg_refreshes, outbox_bytes, outbox_max_bytes,
                               author_email, author_email_unexpected, authorship_normalized,
                               agent_kit, harness_error, end_reason,
                               steps, refresh, report_from}
                            | with_entries(select(.value != null))
                            | walk(if type == "number" and ((isnan or isinfinite) or . > 1e15 or . < -1e15)
                                   then null else . end)
                        ' 2>/dev/null)"
                    fi
                else
                    echo "fork-sandbox-k8s: warning: pod $pod_name's summary.json is over the $FS_POD_SUMMARY_MAX_BYTES byte cap; ignoring it." >&2
                fi
            fi
            # The pod's copy of the run directory sits on an emptyDir every
            # leg in the pod can write to -- unlike a local run, which
            # never shares its filesystem with the sandboxed agent -- so a
            # leg can plant any file by name: task-meta.json (when the
            # host never gave one), exit-code, pid (this run's own, still
            # live), or any file this function itself is about to write.
            # Blindly copying the whole directory would let any of those
            # land, so copy back only the named artifacts a local composed
            # run leaves that the host actually needs --
            # fork-sandbox-status.sh's own resolve_run_file allowlist
            # (what the status/run-log readers consume), minus every name
            # the host already owns and writes itself (run.env, pid,
            # exit-code, handoff.md, pipeline.json -- never taken from the
            # pod), plus progress.json (read directly, not through that
            # helper, but the same discipline). summary.json is deliberately
            # excluded: it is read into run_dir_pod_summary above and
            # merged into the client's own write further down, not copied
            # as a file. review-loop.json and maintainer-loop.json are
            # ALSO excluded, deliberately: those are the legacy single-leg
            # loop record names, and a composed run (runner mode) only
            # ever writes the step-numbered step-<K>-loop.json shape
            # matched below, legacy maintain presets on --k8s included (see
            # the s<K>-review-verdict-N.md/s<K>-maintain-verdict-N.md
            # patterns further down, which is what those presets' verdicts
            # are actually named under the runner). A pod leg has no
            # legitimate reason to ever write review-loop.json or
            # maintainer-loop.json in runner mode, so letting either
            # through would only ever be a forged loop history landing on
            # the host as if it were real. tidy.json is excluded for a
            # different reason: the host already knows, unconditionally,
            # that a --k8s pod run never runs the tidy-history leg (see
            # this function's own tidy.json write further below), so there
            # is never a real one on the pod worth taking either. Each
            # candidate that IS copied must be a regular file -- not a
            # symlink, FIFO or anything else no regular run ever leaves --
            # under the size cap below, and lands only as a flat
            # "$run_dir/<name>" (never a subdirectory, so this can never
            # plant anything under inbox/, scripts/ or clone/).
            local run_dir_pull_cap=$((16 * 1024 * 1024))
            local run_dir_pull_entry run_dir_pull_name run_dir_pull_size run_dir_pull_cp_err
            while IFS= read -r -d '' run_dir_pull_entry; do
                run_dir_pull_name="${run_dir_pull_entry##*/}"
                case "$run_dir_pull_name" in
                    progress.json|summary.txt|sandbox.log|plan.md| \
                    events.jsonl|uncommitted.patch) ;;
                    step-[0-9]*-loop.json)
                        [[ "$run_dir_pull_name" =~ ^step-[0-9]+-loop\.json$ ]] || continue ;;
                    events-review-[0-9]*.jsonl|events-fix-[0-9]*.jsonl|events-maintainer-[0-9]*.jsonl|events-mntfix-[0-9]*.jsonl|events-code-[0-9]*.jsonl|events-continuation-[0-9]*.jsonl|events-tidy-[0-9]*.jsonl)
                        [[ "$run_dir_pull_name" =~ ^events-(review|fix|maintainer|mntfix|code|continuation|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ ]] || continue ;;
                    events-s[0-9]*-*.jsonl)
                        [[ "$run_dir_pull_name" =~ ^events-s[0-9]+-(code|review|maintain|fix|plan|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ ]] || continue ;;
                    review-verdict-[0-9]*.md)
                        [[ "$run_dir_pull_name" =~ ^review-verdict-[0-9]+\.md$ ]] || continue ;;
                    maintainer-verdict-[0-9]*.md)
                        [[ "$run_dir_pull_name" =~ ^maintainer-verdict-[0-9]+\.md$ ]] || continue ;;
                    s[0-9]*-*-verdict-[0-9]*.md)
                        [[ "$run_dir_pull_name" =~ ^s[0-9]+-(review|maintain)-verdict-[0-9]+\.md$ ]] || continue ;;
                    *) continue ;;
                esac
                [[ -f "$run_dir_pull_entry" && ! -L "$run_dir_pull_entry" ]] || continue
                [[ -e "$run_dir/$run_dir_pull_name" ]] && continue
                run_dir_pull_size="$("$FS_STAT" -c '%s' -- "$run_dir_pull_entry" 2>/dev/null || echo -1)"
                (( run_dir_pull_size >= 0 && run_dir_pull_size <= run_dir_pull_cap )) || continue
                # Every other pull in this function (outbox, evidence,
                # session-store) warns by name on failure; this one used to
                # swallow it silently (`2>/dev/null || true`), the one way a
                # copy that fails on a live cluster -- a transient I/O
                # error, a host /tmp exhausted mid-collect -- could leave an
                # artifact missing with no trace of why. Capture and report
                # it the same way its siblings do.
                if ! run_dir_pull_cp_err="$(cp -- "$run_dir_pull_entry" "$run_dir/$run_dir_pull_name" 2>&1)"; then
                    echo "fork-sandbox-k8s: warning: could not copy $run_dir_pull_name back from pod $pod_name's run directory: $run_dir_pull_cp_err" >&2
                fi
            done < <(find "$run_dir_pull_tmp" -mindepth 1 -maxdepth 1 -print0)

            # The pod's summary.json can claim uncommitted_patch: true while
            # the loop above just skipped uncommitted.patch for being over
            # run_dir_pull_cap (it only ever grows with the leftover work's
            # own size, unlike every other artifact here) -- leaving a
            # client-side summary asserting recoverable work that never
            # landed. Downgrade the claim to what is actually sitting in
            # run_dir now, so a reader never sees uncommitted_patch: true
            # for a patch it cannot read.
            if [[ -n "$run_dir_pod_summary" ]]; then
                local run_dir_pull_patch_landed=false
                [[ -s "$run_dir/uncommitted.patch" && -f "$run_dir/uncommitted.patch" && ! -L "$run_dir/uncommitted.patch" ]] \
                    && run_dir_pull_patch_landed=true
                run_dir_pod_summary="$(printf '%s' "$run_dir_pod_summary" | jq -c --argjson landed "$run_dir_pull_patch_landed" '
                    if has("uncommitted_patch") then .uncommitted_patch = (.uncommitted_patch and $landed) else . end
                ' 2>/dev/null)"
            fi

            # run.env is the one exception to "copy back only named
            # artifacts": the pod's copy started as the same file submit
            # staged, and the runner rewrites exactly four fields in place
            # (cost=, model=, outbox_bytes=, outbox_max_bytes=; see
            # fork-sandbox-runner.sh), which the loop above skips entirely
            # (run.env is host-owned). Trusting the WHOLE pulled file
            # would let a leg plant any other key (PROJECT, OUTBOX_DIR,
            # BRANCH, ...) and steer a later resume or collect, so only
            # those four fields are carried over, each validated and each
            # replacing its line the same way the runner itself does.
            #
            # model is excluded from that carry-over entirely, unlike the
            # other three: it feeds the postmaster's X-AI-Model header, and
            # the host's own seat resolution -- whatever the launcher's own
            # run.env write and cmd_submit's write above it already printed
            # for model=, including empty for a model-less pi-local seat
            # that only discovers its model once the pod starts -- is
            # authoritative even then. Falling back to the pod's
            # self-reported value on an empty host line would let a
            # compromised pod plant an arbitrary valid-looking model id
            # into that header for exactly the run where the host has no
            # value of its own to defend against it; an unreported model
            # for that seat type is the honest answer, not a borrowed one.
            if [[ -s "$run_dir_pull_tmp/run.env" ]]; then
                local pod_env_key pod_env_val
                for pod_env_key in cost outbox_bytes outbox_max_bytes; do
                    pod_env_val="$(read_env_value "$run_dir_pull_tmp/run.env" "$pod_env_key" || true)"
                    [[ -n "$pod_env_val" ]] || continue
                    case "$pod_env_key" in
                        cost)
                            [[ "$pod_env_val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || continue
                            ;;
                        outbox_bytes|outbox_max_bytes)
                            [[ "$pod_env_val" =~ ^[0-9]+$ ]] || continue
                            ;;
                    esac
                    if [[ -s "$run_dir/run.env" ]] \
                        && grep -v "^${pod_env_key}=" "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
                        printf '%s=%s\n' "$pod_env_key" "$pod_env_val" >> "$run_dir/run.env.part"
                        mv -f -- "$run_dir/run.env.part" "$run_dir/run.env"
                    else
                        rm -f -- "$run_dir/run.env.part"
                    fi
                done
            fi

            # tidy.json: the host's own record, not the pod's (see the
            # exclusion from the copy-back allowlist above). A --k8s pod
            # run never runs the tidy-history leg -- fetch-back is the
            # host's own job, after collect, so there is nothing for an
            # in-pod tidy leg to verify or publish against -- and that is
            # true of every composed k8s run, not a fact the pod gets to
            # report on. Written only if nothing else already wrote one
            # (a standalone re-collect of an already-finalized run leaves
            # an earlier one standing), and only for a pipeline that has a
            # maintain step at all -- the same gate a local composed run's
            # own tidy.json write uses (see fork-sandbox-runner.sh's
            # summary.txt comment on tidy_has_maintain_step), so a
            # read-only or code-and-review-only composed k8s run reads
            # exactly as its local counterpart would: no tidy.json at all,
            # not a skip record for a leg that was never going to run.
            if [[ ! -e "$run_dir/tidy.json" ]] \
                && [[ -s "$run_dir/pipeline.json" ]] \
                && [[ "$(jq '[.steps[]? | select(.action == "maintain")] | length > 0' \
                    "$run_dir/pipeline.json" 2>/dev/null)" == true ]]; then
                if jq -n '{ended: "skipped", detail: "a --k8s pod run does not fetch back; the tidy-history leg'"'"'s verification and publish are host-side only", head_approved: null, head_after: null, exit: null, cost_usd: null, usage: null, retries: [], clone_restored: null}' \
                    > "$run_dir/tidy.json.part" 2>/dev/null; then
                    mv -f -- "$run_dir/tidy.json.part" "$run_dir/tidy.json"
                else
                    rm -f -- "$run_dir/tidy.json.part"
                fi
            fi
        fi
        [[ -n "$run_dir_pull_tmp" && -e "$run_dir_pull_tmp" ]] && rm -rf -- "$run_dir_pull_tmp"
    elif [[ -n "$run_dir" && "$evidence_ok" == true && -s "$evidence_dir/events.jsonl" && ! -e "$run_dir/events.jsonl" ]]; then
        # Runner mode copies its own events*.jsonl straight into run_dir
        # above (the run_dir_pull_entry allowlist); a legacy (non-runner)
        # --k8s run never goes through that pull at all, and its
        # transcript landed only in evidence_dir, a SIBLING of run_dir, not
        # inside it -- fork-sandbox-status.sh (and this function's own
        # reply.md write, below) only ever look under run_dir. Mirrored
        # here, read-only evidence copied in verbatim, so a plain --k8s
        # run's status/result/reply.md read exactly as a local or composed
        # run's would. `-e` guards a re-collect that already has one.
        cp -- "$evidence_dir/events.jsonl" "$run_dir/events.jsonl" 2>/dev/null || true
    fi

    # The agent's own exit code, from the sentinel the entrypoint writes
    # after the agent exits. Read here rather than taken from a caller so
    # the zero-harvest check below works for a standalone collect the same
    # as for run. Absent or non-numeric -- a run still going, a pod that
    # died early -- simply does not satisfy the check's "agent exited 0"
    # term, rather than being guessed.
    #
    # Unlike model (see the run.env carry-over's own comment above), this
    # value is taken from the pod without a host-side alternative to
    # prefer: no seat resolution on the host ever produces an exit code
    # ahead of time, so /work/.run-complete, written by the entrypoint
    # rather than the agent itself, is the only source there has ever
    # been for it. Narrowed to digits-only above guards against it being
    # anything other than a plain exit code.
    local agent_exit_code
    agent_exit_code="$(kubectl exec --request-timeout=60s -c agent "$pod_name" -- cat /work/.run-complete 2>/dev/null || true)"
    [[ "$agent_exit_code" =~ ^[0-9]+$ ]] || agent_exit_code=""

    # How many commits the run produced. The measure that answers that
    # question is the sha pushed at submit. The pod's bare repository
    # (/work/repo.git) received exactly that push and nothing else ever
    # writes to it -- the agent commits in the clone, and the fetch
    # uploads from the clone -- so its branch tip is still the pushed
    # base, and the run produced no commits exactly when the fetched
    # branch lands at that sha.
    #
    # The FIRST collect of a run -- always the case when cmd_run drives
    # this, since cmd_submit refuses a branch that already exists locally
    # and the submit push creates it only in the pod's repo -- cannot be
    # measured against the local ref at all: cmd_fetch's refspec
    # refs/heads/$branch:refs/heads/$branch creates the local ref at the
    # pod's tip, so before/after there compares "" to the fetched tip and
    # reads new work where there is none: a genuinely dead run would pass
    # the check below and be reaped.
    #
    # A branch that ALREADY exists locally -- a re-collect -- is not
    # measured by the local ref either: before/after there answers "did
    # THIS fetch land new commits", which for a re-collect of a branch
    # whose commits an earlier collect already delivered (a live idle pod
    # plus an existing local ref, or the crash window between the fetch's
    # ref update and its touch of /work/.fetched) reads "no" while the
    # run plainly produced them -- a false zero-harvest. The pushed base
    # answers the run's own question in both cases, so it is read in
    # both, like the sentinel above, through a bounded exec BEFORE the
    # fetch, which is what ends the pod.
    local origin_repo before_sha after_sha base_sha="" zero_commits=false
    origin_repo="$(fs_repo_toplevel "$project_path")" || exit 1
    before_sha="$(git -C "$origin_repo" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
    local base_err
    base_err="$(mktemp)"
    base_sha="$(kubectl exec --request-timeout=60s -c agent "$pod_name" -- \
        git -C /work/repo.git rev-parse -q --verify "refs/heads/$branch" 2> "$base_err" || true)"
    rm -f -- "$base_err"

    echo "fork-sandbox-k8s: fetching branch $branch" >&2
    # UPSTREAM/UPSTREAM_REASON: read back from run.env, the same way
    # pull_session_state above is, and handed to cmd_fetch's own
    # --upstream/--upstream-none rather than re-resolved here -- submit
    # already resolved this once, before the run started, and a re-collect
    # must apply that same answer, not derive a fresh one against whatever
    # HEAD is by now. A standalone collect (no --run-dir) leaves both
    # empty, so cmd_fetch resolves it itself instead.
    local -a fetch_argv=(--branch "$branch")
    if [[ -n "$run_dir" ]]; then
        local upstream_from_env="" upstream_reason_from_env=""
        upstream_from_env="$(read_env_value "$run_dir/run.env" UPSTREAM || true)"
        upstream_reason_from_env="$(read_env_value "$run_dir/run.env" UPSTREAM_REASON || true)"
        [[ -n "$upstream_from_env" ]] && fetch_argv+=(--upstream "$upstream_from_env")
        [[ -n "$upstream_reason_from_env" ]] && fetch_argv+=(--upstream-none "$upstream_reason_from_env")
    fi
    # Wrapped in `if`, not called bare: under set -euo pipefail a bare
    # call would take this whole process down the moment cmd_fetch's own
    # git fetch lost a fast-forward race, with no summary.json ever
    # written at all -- the `if` suppresses that for this whole call
    # (cmd_fetch's own rc capture, inside, needs exactly this to work; see
    # its own comment). cmd_fetch already touches /work/.fetched and warns
    # on this path, so there is nothing left to do here but remember it.
    local fetch_ok=true
    if ! cmd_fetch "${fetch_argv[@]}" "$project_path"; then
        fetch_ok=false
    fi
    after_sha="$(git -C "$origin_repo" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
    if [[ -n "$base_sha" ]]; then
        [[ "$base_sha" == "$after_sha" ]] && zero_commits=true
    elif [[ -n "$before_sha" && "$before_sha" != "$after_sha" ]]; then
        # The base could not be read, but the fetch landed new commits:
        # the run produced work, whatever the base would have said.
        :
    else
        # Undecidable, in the same sense the outbox_ok term below is:
        # neither the base nor a before/after compare can say the run
        # produced no commits -- the fetch landed nothing new, and that
        # says nothing about a ref an earlier collect may already have
        # advanced off an unreadable base. An undecidable check does not
        # report a suspicion.
        echo "fork-sandbox-k8s: warning: could not decide whether the run produced commits (the pushed base sha was unreadable from pod $pod_name's repository, and this fetch landed no new commits); the zero-harvest check is undecidable for this collect." >&2
    fi

    # Finalize the run directory submit created (--run-dir, threaded
    # automatically by cmd_run) and append this run to the durable run log
    # (~/.claude/sandbox-runs.jsonl), however it ended -- including a
    # zero-harvest run, which is exactly the case a query like "has a seat
    # been silently failing" needs to see, so this runs BEFORE the
    # zero-harvest check below rather than after it (that check can exit 3
    # a few lines down, and code after an exit never runs). Absent
    # --run-dir, this does and writes nothing at all, unchanged from
    # collect's behavior before --run-dir existed.
    #
    # harness and model are not collect's own arguments -- only submit
    # knows them -- so they are read back from run.env, written by submit
    # into this same directory at launch. Every other field is known here:
    # network is always "cluster" (a pod's reachability is enforced by
    # NetworkPolicy, not by this project's local pinned/sealed vocabulary),
    # base_sha is the pushed revision already read above (the same value
    # the zero-harvest check measures against), and commits is a rev-list
    # count over that same base and the post-fetch tip -- mirroring how
    # fork-sandbox.sh's own local run counts its commits. cost and token
    # counts are omitted entirely, never written as zero: they live in the
    # pod, and extracting them is separate work this round does not do --
    # an absent key says "not measured"; a zero would falsely claim the
    # run was measured and free. commits gets the same treatment: it is
    # only computable when both base_sha and after_sha are known, which is
    # exactly when the zero-harvest check above is decidable -- an
    # unreadable base (kubectl exec failure) leaves it empty, and empty
    # becomes null below rather than the 0 the initializer used to leave
    # in place, which would have told a reader "this run produced no
    # commits" about a run this same collect just called undecidable.
    if [[ -n "$run_dir" ]]; then
        local run_log_harness run_log_model run_log_commits=""
        local run_log_claude_source="" run_log_claude_via=""
        local run_log_image="" run_log_image_source=""
        local run_log_exit_code run_log_started_at run_log_ended_at run_log_duration_block
        run_log_harness="$(read_env_value "$run_dir/run.env" harness || true)"
        run_log_model="$(read_env_value "$run_dir/run.env" model || true)"
        run_log_image="$(read_env_value "$run_dir/run.env" image || true)"
        run_log_image_source="$(read_env_value "$run_dir/run.env" image_source || true)"
        run_log_claude_source="$(read_env_value "$run_dir/run.env" claude_credentials_source || true)"
        run_log_claude_via="$(read_env_value "$run_dir/run.env" claude_credentials_via || true)"
        if [[ -n "$base_sha" && -n "$after_sha" ]]; then
            run_log_commits="$(cd "$origin_repo" && git rev-list --count "$base_sha..$after_sha" 2>/dev/null || true)"
        fi
        # Read AFTER the session-store pull above resolves, whichever way
        # it went: a successful pull discovers the newest id from the
        # freshly-swapped store, and a failed one (left byte-identical)
        # discovers the same id it would have before the pull was
        # attempted -- the previous turn's id, on purpose. Present only
        # when this run carried a store at all (pull_session_state
        # non-empty), same absent-not-null convention fork-sandbox.sh's
        # own local summary.json uses for this same pair.
        local run_log_session_id=""
        if [[ -n "$pull_session_state" ]]; then
            run_log_session_id="$(fs_session_discover_id "$run_log_harness" "$pull_session_state" "$pull_session_id")"
        fi
        # The refresh keys, same three-way shape as the local summary:
        # disabled (no threshold in run.env) is "none" and []; enabled
        # takes the pod's own refresh.json, pulled as evidence above; and
        # enabled with no usable record leaves both keys ABSENT (a warning,
        # not "none": the run was set to refresh and we cannot say whether
        # it did). The pod records no per-continuation cost or usage.
        #
        # Runner mode (RUNNER=1) skips this whole block: the runner tracks
        # refresh itself, in-process, and already reports it through
        # summary.json's own refresh/continuations/leg_refreshes keys --
        # part of the allowlist run_dir_pod_summary reduces the pod's
        # summary.json to above, merged into this write further down.
        # evidence/refresh.json is the LEGACY single-leg shape's own
        # record (fork-sandbox-refresh.sh, run outside the runner); a
        # composed/runner pod never writes it, so looking for it here
        # finds nothing but a stale file left by `rm -f` above and prints
        # a warning about a run that was never missing anything. Leaving
        # run_log_refresh_block at '{}' below means `+ $refresh_block`
        # contributes no keys at all, so the merge further down (pod
        # summary * this write, this write winning on overlap) leaves the
        # pod's own refresh/continuations/leg_refreshes standing rather
        # than overwriting them with the disabled-shaped default.
        local run_log_refresh_block='{"refresh":"none","continuations":[]}'
        local run_log_refresh_tokens run_log_refresh_json run_log_refresh_docs
        run_log_refresh_tokens="$(read_env_value "$run_dir/run.env" refresh_threshold_tokens || true)"
        if [[ "$runner_mode" == 1 ]]; then
            run_log_refresh_block='{}'
        elif [[ -n "$run_log_refresh_tokens" ]]; then
            # The same single-JSON-value discipline summary.json's own pod
            # read already applies (see run_dir_pod_summary_docs above): a
            # refresh.json holding two concatenated documents makes a bare
            # `jq -ce 'select(...)'` print one line per matching document,
            # and a two-line result fails --argjson below, which used to
            # fall through to `|| rm -f summary.json` and delete the
            # client's own just-written facts (branch, origin_repo,
            # commits, exit_code, base_sha) -- see this function's own
            # write further down, which no longer has a bare `|| rm -f` at
            # all for exactly this reason. Slurp and require exactly one
            # object before ever applying the select/reshape.
            # `|| true`: this script runs under `set -e`, and a bare
            # assignment's command substitution is NOT exempt from it the
            # way an `if`/`&&` condition is -- a missing refresh.json
            # makes the `<` redirection itself fail, which would
            # otherwise abort this whole function (and print the
            # redirection's own "No such file or directory" to the
            # real stderr, past the `2>/dev/null` that only covers jq's
            # own stderr, not the shell's).
            run_log_refresh_docs="$(jq -s '.' < "$evidence_dir/refresh.json" 2>/dev/null)" || true
            if [[ "$(printf '%s' "$run_log_refresh_docs" | jq 'length' 2>/dev/null)" == 1 ]] \
                    && [[ "$(printf '%s' "$run_log_refresh_docs" | jq -r '.[0] | type' 2>/dev/null)" == object ]] \
                    && run_log_refresh_json="$(printf '%s' "$run_log_refresh_docs" | jq -ce '.[0] | select((.ended | type == "string") and (.continuations | type == "array")) | {refresh: .ended, continuations: [.continuations[] | {leg, exit, handoff, handoff_stale}]}' 2>/dev/null)" \
                    && [[ -n "$run_log_refresh_json" ]]; then
                run_log_refresh_block="$run_log_refresh_json"
            else
                run_log_refresh_block='{}'
                echo "fork-sandbox-k8s: warning: this run had --refresh-at enabled but no usable refresh.json came back from the pod; summary.json carries no refresh or continuations keys." >&2
            fi
        fi
        # tidy, like fetched/run_dir below, is a host-known fact, never the
        # pod's: a --k8s pod run never runs the tidy-history leg (see the
        # tidy.json write above), so the same maintain-step check that
        # gates that write gates this too, and the value comes from the
        # file this function itself just wrote (or left from an earlier
        # collect), never from run_dir_pod_summary's allowlist -- "tidy"
        # and "tidy_has_maintain_step" are deliberately absent from that
        # allowlist for exactly this reason.
        local run_log_tidy_has_maintain=false run_log_tidy_json=null
        if [[ -s "$run_dir/pipeline.json" ]] \
            && [[ "$(jq '[.steps[]? | select(.action == "maintain")] | length > 0' \
                "$run_dir/pipeline.json" 2>/dev/null)" == true ]]; then
            run_log_tidy_has_maintain=true
            [[ -s "$run_dir/tidy.json" ]] && run_log_tidy_json="$(cat -- "$run_dir/tidy.json")"
        fi
        # exit_code: a fetch that lost the fast-forward race (fetch_ok=
        # false, above) overrides a clean agent exit the same way the
        # local runner's own rc override does -- a run that "succeeded"
        # with its work stranded, unreachable from the branch the caller
        # was told to expect, must not report done. A harness-side failure
        # (agent_exit_code already nonzero) is left exactly as the agent
        # reported it; this never clears an existing failure, only adds one.
        run_log_exit_code="${agent_exit_code:-null}"
        if [[ "$fetch_ok" != true ]] && [[ "${agent_exit_code:-0}" == "0" ]]; then
            run_log_exit_code=1
        fi
        # The agent's reply, when present, is the file the client reads.
        # Otherwise render the session account at that path. The pod's
        # fetch_back=0 skips this host-side fallback.
        # Written BEFORE summary.json (below), not after: --json's own
        # contract_state calls a run "replied" the moment summary.json
        # exists, so writing reply.md afterward -- worse, best-effort,
        # possibly never -- let a poller see "replied" with a reply_file
        # that was not there yet or never would be. A render failure is
        # folded into run_log_exit_code the same way a lost fetch-back race
        # already is, just above, rather than silently reported as success
        # with nothing to read.
        local reply_ok=true
        if [[ "$outbox_ok" == true && -f "$outbox_dest/reply.md" && ! -L "$outbox_dest/reply.md" ]]; then
            mkdir -p -- "$run_dir/outbox" 2>/dev/null \
                && { [[ "$outbox_dest" == "$run_dir/outbox" ]] \
                    || cp -- "$outbox_dest/reply.md" "$run_dir/outbox/reply.md"; } \
                || reply_ok=false
        else
            mkdir -p -- "$run_dir/outbox" 2>/dev/null \
                && "$script_dir/fork-sandbox-status.sh" --result "$run_dir" \
                    > "$run_dir/outbox/reply.md" 2>/dev/null \
                || reply_ok=false
        fi
        if [[ "$reply_ok" == true ]]; then
            :
        elif [[ "${agent_exit_code:-0}" == "0" ]]; then
            run_log_exit_code=1
        fi
        # started_at/ended_at/duration_seconds: a plain --k8s run's
        # summary.json never carried these at all (the local run's own
        # summary.json has always had them) -- started_at is read back from
        # run.env, written at submit time (either by THIS script's own
        # standalone writer, above, or by fork-sandbox.sh's launcher writer
        # in runner mode); ended_at is simply now, since collect is what
        # decides a run is over. Left out of the object (not emitted as
        # null) when started_at cannot be read at all, rather than claim a
        # duration that was never measured.
        run_log_started_at="$(read_env_value "$run_dir/run.env" started_at 2>/dev/null || true)"
        run_log_ended_at="$(date +%s)"
        run_log_duration_block='{}'
        if [[ "$run_log_started_at" =~ ^[0-9]+$ ]]; then
            run_log_duration_block="$(jq -n --argjson started_at "$run_log_started_at" \
                --argjson ended_at "$run_log_ended_at" \
                '{started_at: $started_at, ended_at: $ended_at,
                  duration_seconds: ($ended_at - $started_at)}')"
        fi
        if jq -n \
            --arg mode "run" \
            --arg harness "$run_log_harness" \
            --arg network "cluster" \
            --arg model "$run_log_model" \
            --arg image "$run_log_image" \
            --arg image_source "$run_log_image_source" \
            --arg branch "$branch" \
            --arg origin_repo "$origin_repo" \
            --arg run_dir "$run_dir" \
            --arg base_sha "$base_sha" \
            --argjson exit_code "$run_log_exit_code" \
            --argjson fetched "$fetch_ok" \
            --arg commits "$run_log_commits" \
            --arg outbox "$outbox_dest" \
            --argjson duration_block "$run_log_duration_block" \
            --arg claude_credentials_source "$run_log_claude_source" \
            --arg claude_credentials_via "$run_log_claude_via" \
            --arg session_state "$pull_session_state" \
            --arg session_id "$run_log_session_id" \
            --argjson refresh_block "$run_log_refresh_block" \
            --argjson tidy_has_maintain_step "$run_log_tidy_has_maintain" \
            --argjson tidy "$run_log_tidy_json" \
            '{
                mode: $mode,
                harness: $harness,
                network: $network,
                model: (if $model == "" then null else $model end),
                image: $image,
                image_source: $image_source,
                branch: $branch,
                origin_repo: $origin_repo,
                run_dir: $run_dir,
                base_sha: (if $base_sha == "" then null else $base_sha end),
                exit_code: $exit_code,
                fetched: $fetched,
                outbox: $outbox,
                commits: (if $commits == "" then null else ($commits | tonumber) end),
            }
            + (if $claude_credentials_via == "" then {} else {
                claude_credentials_source: $claude_credentials_source,
                claude_credentials_via: $claude_credentials_via,
            } end)
            + (if $session_state == "" then {} else {
                session_state: $session_state,
                session_id: (if $session_id == "" then null else $session_id end),
            } end)
            + (if $tidy_has_maintain_step then {tidy: $tidy} else {} end)
            + $refresh_block
            + $duration_block' > "$run_dir/summary.json.part" 2>/dev/null; then
            mv -f -- "$run_dir/summary.json.part" "$run_dir/summary.json"
        else
            rm -f -- "$run_dir/summary.json.part"
        fi

        # A runner-mode run's own summary.json (captured into
        # run_dir_pod_summary above, already reduced to one validated
        # object and an allowlist of pod-only keys, BEFORE the write just
        # above could truncate it) carries the runner's own accounting --
        # cost, usage, retries, the uncommitted-work check -- that this
        # client cannot see from outside the pod. Merged with `*` so the
        # client's own write above wins on any overlapping key regardless
        # (none of the allowlisted keys should ever collide with what the
        # client writes, but this is not the only thing standing between
        # the pod and the client's own fields). When no pod summary.json
        # was pulled, or it did not pass the single-object check above,
        # the client's write stands alone, unchanged -- this block simply
        # has nothing to do.
        if [[ -n "$run_dir_pod_summary" ]]; then
            if [[ -s "$run_dir/summary.json" ]]; then
                local run_dir_summary_merged
                if run_dir_summary_merged="$(jq -s '.[0] * .[1]' \
                    <(printf '%s' "$run_dir_pod_summary") "$run_dir/summary.json" 2>/dev/null)" \
                    && [[ -n "$run_dir_summary_merged" ]]; then
                    printf '%s' "$run_dir_summary_merged" > "$run_dir/summary.json"
                fi
            else
                printf '%s' "$run_dir_pod_summary" > "$run_dir/summary.json"
            fi
        fi

        # summary.txt is the pod's own prose, pulled back verbatim above
        # (it is on the copy-back allowlist). It is written by a runner
        # that always runs with fetch_back=0 (see fork-sandbox.sh's own
        # comment on that seam), so it unconditionally describes its own
        # clone as the only place the work landed -- "fetched: NO -- the
        # work is in the clone only", a pod path (/work/clone) as if it
        # were meaningful on the host, and a closing "Nothing landed in
        # <origin>" paragraph -- even on a run whose branch this very
        # collect just fetched into origin_repo moments ago. Patch the
        # three places that claim that, in place, with what the host
        # itself just established (zero_commits, from the base/after sha
        # compare above); everything else in the file -- cost, review/
        # maintainer loop lines, the diffstat, warnings -- is left exactly
        # as the pod wrote it. Only for a runner-mode pull: a standalone
        # collect with no run_dir, or a legacy --k8s run, never pulls a
        # summary.txt back in the first place.
        if [[ "$runner_mode" == 1 && -s "$run_dir/summary.txt" && ! -L "$run_dir/summary.txt" ]]; then
            local summary_txt_fetched_line summary_txt_landed_1 summary_txt_landed_2
            if [[ "$zero_commits" == true ]]; then
                summary_txt_fetched_line="fetched:   nothing landed -- the session made no commits beyond its starting point."
                summary_txt_landed_1="No commits landed in $origin_repo for branch $branch."
                summary_txt_landed_2=""
            else
                summary_txt_fetched_line="fetched:   yes. Branch $branch is now in $origin_repo"
                summary_txt_landed_1="Review the branch before you build it. It is agent-written code,"
                summary_txt_landed_2="and a Makefile or package.json script in it runs on the host."
            fi
            if awk -v fetched_line="$summary_txt_fetched_line" \
                -v para1="$summary_txt_landed_1" \
                -v para2="$summary_txt_landed_2" \
                -v run_dir="$run_dir" '
                BEGIN { skip_next = 0 }
                skip_next { skip_next = 0; next }
                /^clone:/ { print "run dir:   " run_dir; next }
                /^fetched:/ { print fetched_line; next }
                /^Nothing landed in / {
                    print para1
                    if (para2 != "") print para2
                    skip_next = 1
                    next
                }
                { print }
            ' "$run_dir/summary.txt" > "$run_dir/summary.txt.part" 2>/dev/null; then
                mv -f -- "$run_dir/summary.txt.part" "$run_dir/summary.txt"
            else
                rm -f -- "$run_dir/summary.txt.part"
            fi
        fi

        fs_record_run_log "$run_dir"

        # fork-sandbox-status.sh's run_state() calls a run "done"/"failed" by
        # the presence of $run_dir/exit-code, the same file a local run's own
        # runner writes the moment it finishes -- a composed k8s run has no
        # local process and so never gets one any other way, and without it
        # every collected run reads as "starting" forever. Written host-side,
        # from the same sentinel the zero-harvest check below already trusts,
        # never taken from the pod directly (an exit-code file in the pod's
        # own run_dir copy is excluded from the copy-back allowlist above for
        # exactly this reason).
        #
        # Written LAST, after cmd_fetch above and after the summary.json/
        # summary.txt finalization just above this, not the moment
        # agent_exit_code is known: exit-code's presence is what a
        # --monitor-terminal poll or `fork-sandbox stop` use to decide the
        # run is over, and a reader that saw it the instant it existed, ahead
        # of the fetch landing the branch or the summary correction running,
        # would print the pod's still-uncorrected "nothing landed" account
        # for a branch that (by the time exit-code appears now) has already
        # landed. Only for a run that has one: a run still going (no
        # --run-dir collect reaches here from k8s_run_tail only once the
        # wait is over) always has agent_exit_code set by this point, so an
        # empty value here means a standalone collect against a pod whose
        # agent never finished, which must not fabricate a done/failed state.
        # $run_log_exit_code, not raw $agent_exit_code: a lost fast-forward
        # race already overrode that above to a failure even when the agent
        # itself exited 0, and this is the one file every terminal-state
        # consumer (status --json, --monitor-terminal, `run --wait`) reads
        # as the run's own outcome -- writing the agent's unoverridden code
        # here would let all of them report success for a run whose branch
        # never landed, while summary.json alone said otherwise.
        if [[ -n "$agent_exit_code" && ! -e "$run_dir/exit-code" ]]; then
            printf '%s\n' "$run_log_exit_code" > "$run_dir/exit-code" 2>/dev/null || true
        fi
    fi

    # A zero-harvest run is not a success: the agent exited 0, the fetch
    # brought back zero commits, and the outbox holds no file the agent
    # wrote. Each term alone is legitimate -- a review panel seat commits
    # nothing and writes its verdict to the outbox, and zero commits with
    # a non-empty outbox is a success -- so only the full three-way
    # conjunction is reported. It is also only DECIDABLE when the outbox
    # read succeeded: a refused or failed outbox read cannot establish
    # "empty of anything the agent wrote", and an undecidable check must
    # not report a suspicion.
    if [[ "$agent_exit_code" == "0" && "$zero_commits" == true && "$outbox_ok" == true ]] \
        && (( outbox_agent_count == 0 )); then
        echo "fork-sandbox-k8s: ################################################" >&2
        echo "fork-sandbox-k8s: *** SUSPICIOUS: this run produced nothing." >&2
        echo "fork-sandbox-k8s: *** The agent exited 0, the fetch brought back zero" >&2
        echo "fork-sandbox-k8s: *** commits, and the outbox holds no file the agent" >&2
        echo "fork-sandbox-k8s: *** wrote. That combination is the signature of a seat" >&2
        echo "fork-sandbox-k8s: *** that started and did no work -- typically a launch" >&2
        echo "fork-sandbox-k8s: *** whose context was empty or wrong. The job is being" >&2
        echo "fork-sandbox-k8s: *** KEPT for inspection rather than reaped, and this" >&2
        echo "fork-sandbox-k8s: *** run exits non-zero. The agent's own transcript, when" >&2
        echo "fork-sandbox-k8s: *** captured, explains the exit:" >&2
        echo "fork-sandbox-k8s: ***   $evidence_dir/events.jsonl" >&2
        echo "fork-sandbox-k8s: *** Clean up with:" >&2
        echo "fork-sandbox-k8s: ***   fork-sandbox-k8s.sh rm --branch $branch" >&2
        echo "fork-sandbox-k8s: ################################################" >&2
        # 3, distinct from the agent's exit code (0) and from the wait's
        # 1/2 codes: the agent's work exited 0; the RUN produced nothing.
        exit 3
    fi

    if [[ "$keep" == true ]]; then
        echo "fork-sandbox-k8s: --keep set; leaving job and pod for branch $branch in place" >&2
    elif [[ "$evidence_ok" == false ]]; then
        # Not reaped: reaping now destroys the only record of what this
        # run did, and a rule that leaves resources behind must say so
        # and say how to remove them -- a namespaced pods limit turns an
        # unexplained leftover into a quota-exhaustion bug otherwise.
        echo "fork-sandbox-k8s: ################################################" >&2
        echo "fork-sandbox-k8s: *** This run's evidence could not be captured in full," >&2
        echo "fork-sandbox-k8s: *** so its resources are being LEFT IN PLACE rather than" >&2
        echo "fork-sandbox-k8s: *** reaped. Reaping now would destroy the only record of" >&2
        echo "fork-sandbox-k8s: *** what the run did; whatever still remains in the pod" >&2
        echo "fork-sandbox-k8s: *** is worth inspecting first:" >&2
        echo "fork-sandbox-k8s: ***   kubectl --context=$K8S_CONTEXT -n $K8S_NAMESPACE logs $pod_name" >&2
        echo "fork-sandbox-k8s: *** Remove them by hand when you are done:" >&2
        echo "fork-sandbox-k8s: ***   fork-sandbox-k8s.sh rm --branch $branch" >&2
        echo "fork-sandbox-k8s: ################################################" >&2
    else
        cmd_rm --branch "$branch"
    fi
}

# Records this process as the one watching $1 (a run dir) through to
# collect. fork-sandbox-status.sh's run_state() already treats
# k8s_client_pid, under network=cluster, as a liveness signal (never a
# kill target -- that branch's own comment explains why) for a composed
# --k8s run, whose host-side launcher writes it before exec'ing into this
# script with the same pid. A plain `run`/`resume` (this file's own
# submit+wait+collect verbs) reaches that exact same shape -- one process,
# alive from here through collect -- but cmd_submit's own run.env writer
# never prints this key, because a bare `submit` alone has no wait/collect
# to follow and must not claim this pid speaks for the whole run. Called
# only from cmd_run and cmd_resume, the two callers that DO commit to
# seeing a run through, right before each hands off to k8s_run_tail below
# -- without it, run_state() reads every plain --k8s run as "abandoned"
# for its entire active life (no local pid file, network=cluster, and no
# k8s_client_pid key at all), long before any Job failure actually
# happened. Rewrites the key in place (the cost=/model=/outbox_bytes=
# quartet's own idiom) rather than appending, so a resume by a new process
# after an old one died replaces the stale pid instead of leaving it as
# the first, authoritative match.
k8s_record_client_pid() {
    local run_dir="$1"
    [[ -n "$run_dir" && -f "$run_dir/run.env" ]] || return 0
    if grep -v '^k8s_client_pid=' "$run_dir/run.env" > "$run_dir/run.env.part" 2>/dev/null; then
        printf 'k8s_client_pid=%s\n' "$$" >> "$run_dir/run.env.part"
        mv -f "$run_dir/run.env.part" "$run_dir/run.env"
    else
        rm -f "$run_dir/run.env.part"
    fi
}

# run's tail, shared by cmd_run and cmd_resume so there is exactly one:
# wait, then collect, then the "run complete" line, then exit with the
# agent's code (or the wait's own nonzero rc). Never returns.
# Args: run_dir branch timeout project_path outbox_dir outbox_max_bytes
#       review_loop_cap keep(true|false)
k8s_run_tail() {
    local run_dir="$1" branch="$2" timeout="$3" project_path="$4"
    local outbox_dir="$5" outbox_max_bytes="$6" review_loop_cap="$7" keep="$8"

    # The wait runs in a $(...) subshell to capture the agent's exit code
    # from its stdout. An `exit` inside a subshell stops only the
    # subshell, so a dead-pod, timeout or malformed-sentinel failure would
    # otherwise be swallowed and the run would carry on with an empty code:
    # propagate it explicitly. cmd_collect below is NOT captured -- it is
    # called normally, so its own exit paths behave exactly as they did
    # inline before this extraction.
    local agent_rc wait_rc=0
    local -a wait_argv=(--branch "$branch" --timeout "$timeout")
    # Threaded through so cmd_wait can find CLAUDE_CREDENTIAL_PATH in
    # run.env and keep this run's proxy token alive for as long as it
    # blocks -- see k8s_claude_keeper_start. Both cmd_run (a fresh submit)
    # and cmd_resume (an existing run directory) reach this through
    # k8s_run_tail, so both get the keeper the same way.
    [[ -n "$run_dir" ]] && wait_argv+=(--run-dir "$run_dir")
    agent_rc="$(cmd_wait "${wait_argv[@]}")" || wait_rc=$?
    if (( wait_rc != 0 )); then
        # cmd_wait failed before the agent's sentinel appeared (a dead pod
        # or a malformed sentinel, both terminal codes -- exit 2 -- or a
        # timeout, exit 1) -- cmd_collect, the only other caller of
        # sandbox-run-log.py record, is never reached in that case, and the
        # run directory cmd_submit created would otherwise carry no
        # summary.json and no row in the durable run log: exactly the "a
        # seat is silently failing" case this log exists to surface.
        # cmd_wait's own error already told the operator the job and pod
        # are left in place for inspection, so this does not attempt any of
        # collect's pod reads (outbox, evidence, fetch) against a pod that
        # is dead -- it records only what submit already knew, via
        # record's own run.env fallback for a run directory with no
        # summary.json. exit_code stays absent (record's null): none is
        # known.
        #
        # A timeout (wait_rc 1) is excluded: cmd_wait's own message for it
        # says the opposite of "this run ended" -- "the pod is still
        # running, holding its work" -- and a run_end row written while the
        # run is still going would be a false record no later collect ever
        # supersedes (a by-hand fetch/rm, the advice cmd_wait gives, passes
        # no --run-dir). Every other wait_rc (2: dead pod, malformed
        # sentinel, an already-Succeeded pod, pod not found) is terminal
        # from wait's own perspective -- no further wait will ever turn
        # into a normal completion -- so those still get the row.
        if [[ -n "$run_dir" && "$wait_rc" != 1 ]]; then
            fs_record_run_log "$run_dir"
        fi
        exit "$wait_rc"
    fi

    local -a collect_argv=(--branch "$branch")
    [[ -n "$outbox_dir" ]] && collect_argv+=(--outbox-dir "$outbox_dir")
    # The parsed byte count, always: it is either the operator's --outbox-max
    # or the same default collect would apply itself, so there is nothing to
    # distinguish at the forwarding point.
    collect_argv+=(--outbox-max "$outbox_max_bytes")
    # Passed through whenever the flag was given at all, "0" included --
    # cmd_submit already did the positive-integer validation above, and
    # collect's own copy only decides whether the loop read happens.
    [[ -n "$review_loop_cap" ]] && collect_argv+=(--review-loop "$review_loop_cap")
    [[ "$keep" == true ]] && collect_argv+=(--keep)
    [[ -n "$run_dir" ]] && collect_argv+=(--run-dir "$run_dir")
    cmd_collect "${collect_argv[@]}" "$project_path"

    # cmd_collect's own exit status is not captured (see the comment
    # above this function's wait, on why) -- but $agent_rc alone is not
    # this run's real outcome either: a lost fast-forward race makes
    # collect overwrite $run_dir/exit-code with a failure even when the
    # agent itself exited 0 (see that write, inside cmd_collect). Read
    # the corrected value back rather than report the agent's raw code
    # here, so this process's own exit status agrees with exit-code and
    # summary.json instead of contradicting both of them.
    local tail_rc="$agent_rc" exit_code_written
    if [[ -n "$run_dir" ]] && exit_code_written="$(tr -dc '0-9-' < "$run_dir/exit-code" 2>/dev/null)" \
        && [[ "$exit_code_written" =~ ^-?[0-9]+$ ]]; then
        tail_rc="$exit_code_written"
    fi

    # The one line this verb prints that none of its three phases can: it
    # reports the agent's exit code, which collect does not know.
    echo "fork-sandbox-k8s: run complete. branch=$branch agent_exit=$agent_rc landed_in=$project_path" >&2
    exit "$tail_rc"
}

# resume: run's tail for a run submit already created; see the header.
cmd_resume() {
    local run_dir="" timeout_arg=""
    while (( $# )); do
        case "$1" in
            --run-dir) run_dir="${2:?--run-dir requires a directory}"; shift 2 ;;
            --timeout) timeout_arg="${2:?--timeout requires a number of seconds}"; shift 2 ;;
            *) echo "Error: unknown argument '$1' for resume." >&2; exit 1 ;;
        esac
    done
    [[ -n "$run_dir" ]] || { echo "Error: resume requires --run-dir." >&2; exit 1; }
    [[ -d "$run_dir" ]] || { echo "Error: resume: no such run directory: $run_dir" >&2; exit 1; }
    local env_file="$run_dir/run.env"
    [[ -f "$env_file" ]] || {
        echo "Error: resume: $run_dir has no run.env; nothing to resume." >&2
        exit 1
    }
    local branch project outbox_dir outbox_max_bytes review_loop keep rec_timeout submitted_at
    branch="$(read_env_value "$env_file" BRANCH || true)"
    project="$(read_env_value "$env_file" PROJECT || true)"
    if [[ -z "$branch" || -z "$project" ]]; then
        echo "Error: resume: $env_file lacks BRANCH or PROJECT; cannot resume." >&2
        exit 1
    fi
    # A run whose submitter died before the pod got its inputs: the pod's
    # entrypoint gives up on its own, so there is nothing to adopt. Only a
    # run.env that says the marker is expected is held to it -- one with
    # neither key (an older submit, possibly still live) is adopted as ever.
    if [[ "$(read_env_value "$env_file" INPUTS_PUSH_EXPECTED || true)" == true \
        && "$(read_env_value "$env_file" INPUTS_PUSH_COMPLETE || true)" != true ]]; then
        echo "Error: resume: the submit for branch $branch never completed its push" >&2
        echo "(INPUTS_PUSH_COMPLETE is missing from $env_file); the pod never got its" >&2
        echo "inputs. Removing the run's cluster objects; submit it again." >&2
        kubectl delete job,pod,service,secret,configmap,networkpolicy \
            -l fork-sandbox/branch="$(k8s_safe_name fork-sandbox-agent "$branch")" \
            --ignore-not-found >&2
        exit 2
    fi
    outbox_dir="$(read_env_value "$env_file" OUTBOX_DIR || true)"
    outbox_max_bytes="$(read_env_value "$env_file" OUTBOX_MAX_BYTES || true)"
    [[ "$outbox_max_bytes" =~ ^[0-9]+$ ]] || outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    review_loop="$(read_env_value "$env_file" REVIEW_LOOP || true)"
    keep="$(read_env_value "$env_file" KEEP || true)"
    [[ "$keep" == true ]] || keep=false
    rec_timeout="$(read_env_value "$env_file" TIMEOUT || true)"
    [[ "$rec_timeout" =~ ^[0-9]+$ ]] || rec_timeout=3600
    submitted_at="$(read_env_value "$env_file" SUBMITTED_AT || true)"

    local timeout="$timeout_arg"
    if [[ -z "$timeout" ]]; then
        local elapsed=0
        [[ "$submitted_at" =~ ^[0-9]+$ ]] && elapsed=$(( $(date +%s) - submitted_at ))
        (( elapsed < 0 )) && elapsed=0
        timeout=$(( rec_timeout - elapsed ))
        (( 60 <= timeout )) || timeout=60
    elif [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "Error: --timeout must be a whole number of seconds, got '$timeout'." >&2
        exit 1
    fi

    k8s_record_client_pid "$run_dir"
    k8s_run_tail "$run_dir" "$branch" "$timeout" "$project" \
        "$outbox_dir" "$outbox_max_bytes" "$review_loop" "$keep"
}

# submit, then wait, then collect -- see the header comment above for why.
# Each phase's body lives in its own verb (cmd_wait, cmd_collect, plus
# cmd_fetch and cmd_rm inside cmd_collect), so a caller fanning out several
# runs can drive the phases separately; nothing here duplicates any of
# their logic. The only new logic in this function is the phase sequence
# itself and the final completion line.
cmd_run() {
    local dry_run=false keep=false timeout="" timeout_given=false branch="" model="" review_loop_cap=""
    local outbox_dir="" outbox_max_arg="" context_ro="" context_secret="" harness="" review_model="" endpoint=""
    local checkout_ref="" pi_args="" services_trust_ref="" task_meta="" claude_credentials_flag=""
    local thread_dir="" attach_dir="" image_flag="" run_dir_flag=""
    local session_state="" resume_session="" session_id_arg=""
    local refresh_at_arg="" refresh_at_given=false refresh_max_arg=""
    local allow_existing_branch=false
    local -a labels_raw=() allow_ns_raw=() reach_probe_raw=() extra_refs_raw=()
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --allow-existing-branch) allow_existing_branch=true; shift ;;
            --keep) keep=true; shift ;;
            --timeout) timeout="${2:?--timeout requires a number of seconds}"; timeout_given=true; shift 2 ;;
            --branch) branch="${2:?--branch requires a name}"; shift 2 ;;
            --checkout) checkout_ref="${2:?--checkout requires a ref}"; shift 2 ;;
            --services-trust-ref) services_trust_ref="${2:?--services-trust-ref requires a ref}"; shift 2 ;;
            --extra-ref) extra_refs_raw+=("${2:?--extra-ref requires NAME=SHA}"); shift 2 ;;
            --model) model="${2:?--model requires an OpenRouter model id}"; shift 2 ;;
            --endpoint) endpoint="${2:?--endpoint requires a name}"; shift 2 ;;
            --image) image_flag="${2:?--image requires an image reference}"; shift 2 ;;
            --harness) harness="${2:?--harness requires 'pi' or 'claude'}"; shift 2 ;;
            --pi-args) pi_args="${2:?--pi-args requires a value}"; shift 2 ;;
            --review-loop) review_loop_cap="${2:?--review-loop requires a positive integer}"; shift 2 ;;
            --review-model) review_model="${2:?--review-model requires a model id}"; shift 2 ;;
            --outbox-dir) outbox_dir="${2:?--outbox-dir requires a path}"; shift 2 ;;
            --outbox-max) outbox_max_arg="${2:?--outbox-max requires a size}"; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; shift 2 ;;
            --context-secret) context_secret="${2:?--context-secret requires a Secret name}"; shift 2 ;;
            --thread-dir) thread_dir="${2:?--thread-dir requires a directory}"; shift 2 ;;
            --attach-dir) attach_dir="${2:?--attach-dir requires a directory}"; shift 2 ;;
            --run-dir) run_dir_flag="${2:?--run-dir requires a directory}"; shift 2 ;;
            --session-state) session_state="${2:?--session-state requires a directory}"; shift 2 ;;
            --resume-session) resume_session="${2:?--resume-session requires a session id}"; shift 2 ;;
            --session-id) session_id_arg="${2:?--session-id requires a session id}"; shift 2 ;;
            --refresh-at) refresh_at_arg="${2:?--refresh-at requires a value}"; refresh_at_given=true; shift 2 ;;
            --refresh-max) refresh_max_arg="${2:?--refresh-max requires a value}"; shift 2 ;;
            --claude-credentials) claude_credentials_flag="${2:?--claude-credentials requires a path}"; shift 2 ;;
            --label) labels_raw+=("${2:?--label requires key=value}"); shift 2 ;;
            --task-meta) task_meta="${2:?--task-meta requires a JSON object}"; shift 2 ;;
            --allow-namespace) allow_ns_raw+=("${2:?--allow-namespace requires NS[:PORT]}"); shift 2 ;;
            --reach-probe) reach_probe_raw+=("${2:?--reach-probe requires HOST:PORT}"); shift 2 ;;
            -*) echo "Error: unknown option '$1' for run." >&2; exit 1 ;;
            *) break ;;
        esac
    done
    local project_path="${1:?Usage: fork-sandbox-k8s.sh run [options] --branch NAME [--model MODEL] <project-path> <handoff-file>}"
    local handoff_file="${2:?Usage: fork-sandbox-k8s.sh run [options] --branch NAME [--model MODEL] <project-path> <handoff-file>}"

    # Unlike submit, run has no auto-generated branch name: it needs to know
    # the name up front so the same name can be used to poll, fetch and
    # clean up this one run.
    [[ -n "$branch" ]] || { echo "Error: run requires --branch." >&2; exit 1; }
    # --model, like in cmd_submit, is required on a legacy install and
    # optional on a K8S_PROXY_ENDPOINTS install (the pod discovers it).
    # --harness claude keeps the requirement, for the same reason submit
    # does.
    if [[ -n "$run_dir_flag" ]]; then
        : # cmd_submit validates each composed seat after forwarding.
    elif [[ -z "$K8S_PROXY_ENDPOINTS" ]]; then
        if [[ -z "$model" && -n "$K8S_DEFAULT_MODEL" ]]; then
            # Same refusal cmd_submit gives, checked here too since this
            # is the fail-fast duplicate of cmd_submit's own --model
            # requirement, ahead of the submit_argv forwarding below.
            echo "Error: K8S_DEFAULT_MODEL is not available: this namespace" >&2
            echo "was installed with K8S_PROXY_UPSTREAM, which has no model" >&2
            echo "discovery for K8S_DEFAULT_MODEL to stand in for. Pass" >&2
            echo "--model explicitly." >&2
            exit 1
        fi
        [[ -n "$model" ]] || { echo "Error: run requires --model. There is no default:" >&2
            echo "the model is an OpenRouter id, such as moonshotai/kimi-k3." >&2; exit 1; }
    elif [[ -z "$model" && "$harness" == claude ]]; then
        echo "Error: --harness claude requires --model even on a" >&2
        echo "K8S_PROXY_ENDPOINTS install -- the pod's model discovery" >&2
        echo "lists the pi endpoint's model ids, not Claude Code model" >&2
        echo "names." >&2
        exit 1
    fi
    if [[ "$timeout_given" == true ]]; then
        if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
            echo "Error: --timeout must be a whole number of seconds, got '$timeout'." >&2
            exit 1
        fi
    else
        # No --timeout: 3600s (one hour, matching the entrypoint's own
        # RUN_TTL default) is sized for a single leg, which is all a
        # legacy (no --run-dir) run ever has. A composed run staged a
        # pipeline.json needs the MAXIMUM number of legs the runner can
        # start for it, not just its steps' own repeat caps, or cmd_wait
        # (and the claude-proxy keeper it runs alongside -- see
        # k8s_claude_keeper_start) gives up on a pipeline that is still
        # working its way through later legs:
        #   - a review/maintain step's repeat is iterations, not legs --
        #     each one runs a fix leg on a FINDINGS verdict, and the
        #     runner resolves a fix seat (repeat 1, on the run's own
        #     implement harness/model) even when pipeline.json's step has
        #     no "fix" key at all, so the multiplier is always
        #     1 + (fix.repeat // 1), never 1 + (fix.repeat // 0).
        #   - a code step's own passes, and every fix pass above, each
        #     open their own --refresh-at continuation chain when that
        #     leg's harness is claude and refresh is enabled -- on by
        #     default for a claude leg (see fs_refresh_resolve) -- adding
        #     up to --refresh-max (default 6) further legs apiece.
        # See docs/kubernetes-runs.md for the rationale.
        timeout=3600
        if [[ -n "$run_dir_flag" ]]; then
            local timeout_run_dir_real timeout_step_repeats timeout_impl_harness \
                timeout_refresh_at timeout_refresh_enabled timeout_refresh_max
            timeout_run_dir_real="$(validate_run_dir_flag "$run_dir_flag")" || exit 1
            # The same fallback harness a fix seat with no harness of its
            # own resolves to at run time (the runner's bare $harness,
            # read from run.env, which cmd_submit always sets from this
            # same --harness flag -- never from pipeline.json).
            timeout_impl_harness="${harness:-pi}"
            timeout_refresh_at="0"
            if [[ "$refresh_at_given" == true ]]; then
                timeout_refresh_at="$refresh_at_arg"
            elif [[ "$timeout_impl_harness" == claude ]]; then
                timeout_refresh_at="0.5"
            fi
            timeout_refresh_enabled=0
            awk -v v="$timeout_refresh_at" 'BEGIN{exit !(v>0)}' 2>/dev/null \
                && timeout_refresh_enabled=1
            timeout_refresh_max=6
            [[ "$refresh_max_arg" =~ ^[0-9]+$ ]] && timeout_refresh_max="$refresh_max_arg"
            timeout_step_repeats="$(jq \
                --argjson enabled "$timeout_refresh_enabled" \
                --argjson max "$timeout_refresh_max" \
                --arg impl "$timeout_impl_harness" \
                '[.steps[] |
                    ((.fix.repeat // 1)) as $fix_repeat |
                    ((.fix.harness // $impl)) as $fix_harness |
                    (.repeat // 1) *
                    (if .action == "code" then
                        1 + (if $enabled == 1 and .harness == "claude" then $max else 0 end)
                     elif .action == "review" or .action == "maintain" then
                        1 + $fix_repeat *
                            (1 + (if $enabled == 1 and $fix_harness == "claude" then $max else 0 end))
                     else 1 end)
                ] | add // 0' \
                "$timeout_run_dir_real/pipeline.json" 2>/dev/null)"
            if [[ "$timeout_step_repeats" =~ ^[0-9]+$ ]] && (( timeout_step_repeats > 0 )); then
                timeout=$(( timeout_step_repeats * 3600 ))
            fi
        fi
    fi

    # Resolved here, before anything is created, so a bad --outbox-max is
    # refused before submit creates anything -- and forwarded to cmd_collect
    # below as the parsed byte count, which is all collect needs. fs_parse_
    # size_bytes already prints its own error naming what was given.
    local outbox_max_bytes="$FS_OUTBOX_MAX_BYTES"
    if [[ -n "$outbox_max_arg" ]]; then
        outbox_max_bytes="$(fs_parse_size_bytes "$outbox_max_arg")" || exit 1
    fi

    local -a submit_argv=(--branch "$branch")
    # Forwarded only when given: on a K8S_PROXY_ENDPOINTS install a run
    # may omit --model, and cmd_submit's own discovery-based optionality
    # is what applies -- forwarding an empty value would be a different
    # thing. --endpoint follows the same pass-through-when-given rule as
    # --review-loop below.
    [[ -n "$model" ]] && submit_argv+=(--model "$model")
    [[ -n "$endpoint" ]] && submit_argv+=(--endpoint "$endpoint")
    [[ -n "$image_flag" ]] && submit_argv+=(--image "$image_flag")
    [[ -n "$harness" ]] && submit_argv+=(--harness "$harness")
    # Same pass-through-when-given rule as --harness above: the value is
    # forwarded UNCHANGED, and cmd_submit re-runs its own refusal (the
    # claude-harness cross-check and fs_reject_unsafe_chars) before
    # anything is created. An empty --pi-args means "absent", not an
    # empty argument the pod's pi would see as a positional.
    [[ -n "$pi_args" ]] && submit_argv+=(--pi-args "$pi_args")
    # Passed through whenever the flag was given at all, "0" included --
    # cmd_submit does the actual positive-integer validation below, and a
    # bad value here must reach that error rather than silently collapse
    # into "no loop" the way an `(( review_loop_cap > 0 ))` gate would.
    [[ -n "$review_loop_cap" ]] && submit_argv+=(--review-loop "$review_loop_cap")
    [[ -n "$review_model" ]] && submit_argv+=(--review-model "$review_model")
    [[ -n "$outbox_max_arg" ]] && submit_argv+=(--outbox-max "$outbox_max_arg")
    # Recorded by submit in run.env for `resume`; submit acts on none.
    [[ -n "$outbox_dir" ]] && submit_argv+=(--outbox-dir "$outbox_dir")
    [[ "$keep" == true ]] && submit_argv+=(--keep)
    submit_argv+=(--timeout "$timeout")
    [[ -n "$context_ro" ]] && submit_argv+=(--context-ro "$context_ro")
    [[ -n "$context_secret" ]] && submit_argv+=(--context-secret "$context_secret")
    [[ -n "$thread_dir" ]] && submit_argv+=(--thread-dir "$thread_dir")
    [[ -n "$attach_dir" ]] && submit_argv+=(--attach-dir "$attach_dir")
    [[ -n "$run_dir_flag" ]] && submit_argv+=(--run-dir "$run_dir_flag")
    # Forwarded unchanged, like --pi-args above: cmd_submit re-runs
    # fs_validate_session_flags itself before anything is created.
    [[ -n "$session_state" ]] && submit_argv+=(--session-state "$session_state")
    [[ -n "$resume_session" ]] && submit_argv+=(--resume-session "$resume_session")
    [[ -n "$session_id_arg" ]] && submit_argv+=(--session-id "$session_id_arg")
    [[ "$refresh_at_given" == true ]] && submit_argv+=(--refresh-at "$refresh_at_arg")
    [[ -n "$refresh_max_arg" ]] && submit_argv+=(--refresh-max "$refresh_max_arg")
    [[ -n "$claude_credentials_flag" ]] && submit_argv+=(--claude-credentials "$claude_credentials_flag")
    # Passed through only when given, like every other optional option
    # above: an empty --checkout at submit's parse would be an argument
    # error, not "no checkout". cmd_submit does the resolution and the
    # rev-parse check itself, before anything is created.
    [[ -n "$checkout_ref" ]] && submit_argv+=(--checkout "$checkout_ref")
    [[ -n "$services_trust_ref" ]] && submit_argv+=(--services-trust-ref "$services_trust_ref")
    [[ -n "$task_meta" ]] && submit_argv+=(--task-meta "$task_meta")
    $allow_existing_branch && submit_argv+=(--allow-existing-branch)
    # Unconditional, unlike the scalar flags above: an empty labels_raw
    # array is itself the "no --label given" signal, so the loop simply
    # forwards nothing rather than needing a separate -n guard.
    local l
    for l in "${labels_raw[@]}"; do submit_argv+=(--label "$l"); done
    for l in "${allow_ns_raw[@]}"; do submit_argv+=(--allow-namespace "$l"); done
    for l in "${reach_probe_raw[@]}"; do submit_argv+=(--reach-probe "$l"); done
    for l in "${extra_refs_raw[@]}"; do submit_argv+=(--extra-ref "$l"); done
    submit_argv+=("$project_path" "$handoff_file")

    # cmd_submit does its own full validation (K8S_IMAGE, K8S_DENIED_PROBE,
    # branch freedom, handoff contents...) and, under --dry-run, exits the
    # whole process itself with the rendered YAML -- run never reaches the
    # wait/fetch/rm steps below in that case, and touches no kubectl either.
    # (A dry-run also never reaches cmd_submit's run-dir creation, so there
    # is nothing for K8S_LAST_SUBMIT_RUN_DIR to hold in this branch.)
    if [[ "$dry_run" == true ]]; then
        cmd_submit --dry-run "${submit_argv[@]}"
        exit 0
    fi
    cmd_submit "${submit_argv[@]}"

    # cmd_submit is a plain bash function call, never a subprocess, so its
    # progress messages above already streamed straight to this run's own
    # stderr -- capturing its output here (the way cmd_wait's subshell
    # below captures agent_rc) would buffer all of that until submit
    # finished instead. K8S_LAST_SUBMIT_RUN_DIR is the module-global out
    # param cmd_submit set as its last action instead, read back here so
    # this run's own collect phase can finalize the same run directory --
    # see cmd_run's own row in "The durable run log" in
    # docs/kubernetes-runs.md.
    local run_dir="$K8S_LAST_SUBMIT_RUN_DIR"

    k8s_record_client_pid "$run_dir"
    k8s_run_tail "$run_dir" "$branch" "$timeout" "$project_path" \
        "$outbox_dir" "$outbox_max_bytes" "$review_loop_cap" "$keep"
}

verb="${1-}"
[[ -n "$verb" ]] || { echo "Error: no command given. Run 'fork-sandbox-k8s.sh --help'." >&2; exit 1; }
shift

case "$verb" in
    install) cmd_install "$@" ;;
    submit) cmd_submit "$@"; k8s_note_standalone_submit_keeper ;;
    run) cmd_run "$@" ;;
    resume) cmd_resume "$@" ;;
    wait) cmd_wait "$@" ;;
    collect) cmd_collect "$@" ;;
    fetch) cmd_fetch "$@" ;;
    say) cmd_say "$@" ;;
    rm) cmd_rm "$@" ;;
    check-grant) cmd_check_grant "$@" ;;
    *)
        echo "Error: unknown command '$verb'. Use install, submit, run, resume, wait, collect, fetch, say, rm or check-grant." >&2
        exit 1
        ;;
esac
