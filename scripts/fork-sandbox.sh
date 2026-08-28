#!/usr/bin/env bash
# fork-sandbox.sh — Run one unattended headless agent session in a sandboxed clone
#
# Usage: fork-sandbox.sh [options] <project-path> <handoff-file>
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
#                        harness.
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
# means killing it and starting over.
#
# The review loop. --review-loop N adds a quality pass after the coding
# session: a REVIEW leg reads the commits the run just made and writes a
# verdict, and when that verdict lists problems a FIX leg is given them and
# commits the fixes. That pair repeats up to N times. Each leg is a fresh
# session of the same harness, started the same way as the main one (or with
# --review-model for review legs), with a generated prompt on stdin. A reviewer
# therefore never sits inside the
# conversation whose work it is judging — an author defends its code, a
# stranger reads it. The review leg follows the code-review-portable skill,
# which is bound into every run already, and writes its verdict to
# .git/review-verdict.md in the clone: the first line is APPROVED or FINDINGS,
# and the rest is one finding per paragraph, each citing file:line. A verdict
# is data, and it reaches the fix leg the way every prompt does, on stdin.
#
# The loop stops on the first of four things:
#
#   approved       the review leg said APPROVED. The usual good ending.
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
harness=""
combined_model=""
dry_run=false
claude_extra_args=""
pi_extra_args=""
sandbox_args=""
task_meta=""
context_ro=""
review_loop_arg=""
review_loop_cap=0
foreground=false
keep_session=false
no_services=false
services_trust_ref=""
prompts_dir_arg=""

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --branch)
            branch="${2:?--branch requires a name}"
            shift 2
            ;;
        --harness)
            harness_spec="${2:?--harness requires claude, pi, pi-local or codex}"
            shift 2
            ;;
        --checkout)
            checkout_ref="${2:?--checkout requires a ref}"
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
# "review_model"), in place, when $2 is true. Shared by --model and
# --review-model: both go through the same alias file and codex-cache
# lookup, against the same $harness, so a bad --review-model is refused
# before the clone exactly as a bad --model is.
resolve_model() {
    local varname="$1" given="$2"
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
        resolved="$(awk -v harness="$harness" -v alias="$current" '
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

    case "$harness" in
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

resolve_model model "$model_given" || exit 1

review_model_given=false
[[ -n "$review_model" ]] && review_model_given=true
resolve_model review_model "$review_model_given" || exit 1

if [[ "$harness" == "pi" && -z "$model" ]]; then
    echo "Error: --harness pi needs --model. There is no default: the model" >&2
    echo "is an OpenRouter id, such as moonshotai/kimi-k3." >&2
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
# The resolved model values are what --dry-run prints, so they have to clear
# the shell-safety check before it prints them. The full sweep over every
# generated-runner value still runs below; this is the same check applied
# early to dry-run's own subject, so a model the real run refuses cannot get
# a green light here first.
fs_reject_unsafe_chars "$model" "$review_model" || exit 1

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

if [[ "$dry_run" == true ]]; then
    printf 'harness=%s\nmodel=%s\n' "$harness" "$model"
    [[ -z "$review_model" ]] || printf 'review_model=%s\n' "$review_model"
    printf 'prompt_overlay_dir=%s\n' "$prompt_overlay_dir"
    for prompt_overlay_leg in "${prompt_overlay_legs[@]}"; do
        prompt_overlay_leg_csv="${prompt_overlay_fragments[$prompt_overlay_leg]:-}"
        prompt_overlay_leg_csv="${prompt_overlay_leg_csv//$'\n'/,}"
        printf 'prompt_overlay_fragments[%s]=%s\n' \
            "$prompt_overlay_leg" "$prompt_overlay_leg_csv"
    done
    printf 'prompt_overlay_rev=%s\n' "$prompt_overlay_rev"
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
harness_flags=()
harness_cmd=()
harness_exec=0
harness_sandbox_bin=""
run_formatter="$formatter"
usage_source="$harness"
pi_session_dir=""

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

case "$harness" in
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
    harness_cmd=("${FS_PI_ARGV0[@]}" --provider openrouter --model "$model")
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
    if [[ -n "$model" ]]; then
        harness_flags+=(--model "$model")
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
    if [[ -n "$model" ]]; then
        harness_cmd+=(--model "$model")
    fi
    harness_cmd+=(-)
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

# Check every value that goes into the generated runner or the run record
# before anything is created, so a bad name cannot leave a clone behind on
# the way out.
fs_reject_unsafe_chars "$project_path" "$handoff_file" "$branch" "$checkout_ref" \
    "$model" "$review_model" "$claude_extra_args" "$sandbox_args"

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
    if ! base_sha="$(cd "$origin_repo" && \
        git rev-parse --verify --quiet "$checkout_ref^{commit}")"; then
        echo "Error: --checkout '$checkout_ref' does not name a commit in" >&2
        echo "$origin_repo. The ref is resolved there, not in the clone, so" >&2
        echo "fetch it into that repo first." >&2
        exit 1
    fi
elif ! base_sha="$(cd "$origin_repo" && git rev-parse HEAD 2>/dev/null)"; then
    echo "Error: '$origin_repo' has no commits yet, so there is nothing to" >&2
    echo "clone. Make a first commit and try again." >&2
    exit 1
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
    "${checkout_ref:+$base_sha}"; then
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
            "${services_trust_ref}...${base_sha}" \
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
            echo "'$services_trust_ref' against '$base_sha' (git exited" >&2
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
    if [[ "$harness" == "pi" || "$harness" == "pi-local" ]]; then
        harness_cmd+=(--skill "$skill_dir")
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
if [[ "$harness" == "claude" ]]; then
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

# The handoff is the whole prompt, so prepend the one fact the caller cannot
# know: where the clone ended up. The session starts there, so relative paths
# always work — but a model that writes an absolute path by hand can drop a
# segment, and the "No such file or directory" it gets back reads as a missing
# file rather than a wrong path. Naming the directory once, at the top, costs
# nothing and removes the guess.
handoff_copy="$run_dir/handoff.md"

# The preamble every generated prompt starts with: where the clone is, where
# the operator inbox is, how addenda reach this harness, and — for a sealed
# run — that there is no network. The handoff needs it, and so do the review
# and fix prompts of --review-loop, which are separate sessions in the same
# sandbox and know none of it either. Written once here rather than pasted
# three times.
fs_emit_prompt_preamble() {
    cat <<EOF
# Your working directory

You are in a sandboxed, throwaway clone of the repository. Its absolute path
is:

    $clone_dir

You start there, so **prefer relative paths**. When you do need an absolute
one, copy the line above rather than typing it out: a hand-built path that
drops a segment fails as "No such file or directory", which looks like a
missing file rather than a wrong path.

That directory is the only writable thing here. Everything else in the sandbox
is read-only or ephemeral.
EOF
    # Same convention as the working-directory block above: name the absolute
    # path once so nothing has to build it by hand.
    cat <<EOF

## Operator inbox

The person who launched this run can send you further instructions while you
work. They arrive as files in:

    $inbox_dir

Each file there is an **operator addendum**: a message from the same person who
wrote your handoff, written after this run started. An addendum is a
continuation of the handoff and carries the same authority — it may override
the handoff rather than merely add to it, and where the two conflict the
addendum is the newer instruction and wins.

The directory is mounted read-only. Never write to it. An empty inbox is the
normal case, not a problem: most runs get no addenda at all.
EOF
    if [[ "$harness" == "claude" ]]; then
        cat <<'EOF'

Addenda are pushed to you automatically — beside a tool result, or at the end
of a turn — so you do not have to go looking. Reading the directory yourself is
a backstop, not the mechanism.
EOF
    else
        cat <<'EOF'

Nothing pushes them at you on this harness, so you have to look. List that
directory and read anything new at each of these points:

  - before each commit,
  - before and after any command you expect to take more than ~30 seconds
    (a test suite, a build, a bulk network call),
  - at least once every 25 tool calls,
  - before you write your final report.

Reading it is an `ls` and a `cat` over a small directory, so it costs almost
nothing — read it more often than you think you need to. Do not wait for a
commit: a session that is stuck, off-scope, or grinding through a long build
is the one most likely to be sent a correction and the least likely to reach
a commit. An addendum you never read is an instruction you never followed.
EOF
    fi
    if [[ "$harness" == "pi-local" ]]; then
        cat <<'EOF'

## This sandbox has no network

There is no internet here, no LAN, and no DNS. The model you are running on is
reached over a socket and is the only thing outside this machine you can talk
to. Nothing else will answer.

So do not try to install anything — no `npm install`, no `pip install`, no
`apt-get`, no `git fetch`, no documentation lookup. Those fail, and the failure
is the sandbox working as intended rather than a problem to debug or work
around.

Everything the work needs is already here: the clone, whatever dependencies
were provisioned into it, and any per-run services. If something genuinely
necessary is missing, say so in your final report instead of trying to fetch
it.
EOF
    fi
}

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
    fs_emit_prompt_preamble
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
        fs_emit_prompt_preamble
        fs_emit_prompt_overlay review
        cat <<EOF

---

# Your task: review this branch, and only review it

Another session worked in this same clone and committed to the branch
\`$branch\`. You are a different session, with none of its reasoning and none
of its attachment to the result. Read what it committed and say what is wrong
with it.

The change is the commit range:

    $base_sha...HEAD

## Method

Follow the code-review-portable skill. It is bound into this sandbox at:

    $review_skill_dir

Read its \`SKILL.md\` and do what it says, at effort level \`high\`, for the
range above. Use the range exactly as written — three dots, base first.

## An unfollowed addendum is a finding

You read the operator inbox as part of every session; this leg is where that
reading has to show up in the verdict. If an addendum asks for work that the
commits under review do not contain, that is a finding. Report it as one,
with the addendum quoted, so the fix leg can carry it out. Do not approve a
branch that leaves an operator instruction unfollowed. You are reporting the
gap here, not closing it — the next section still applies.

## Do not touch the code

Do not fix anything. Do not edit, stage, commit, amend, rebase or revert.
Another session applies the fixes; a review that quietly repaired what it
found leaves nobody able to tell the two apart. Reading, building and running
the tests is fine — changing tracked files is not.

## Your verdict is a file

Write it to exactly this path:

    $review_verdict_file

That file is the only thing read back. A report written anywhere else — your
final message included — is discarded, so put the whole verdict in the file.

Its format is fixed, because a program reads the first line:

  - **The first line is exactly \`APPROVED\` or \`FINDINGS\`**, one word, alone
    on the line, in capitals, with no punctuation, no bullet and no heading
    marker.
  - \`APPROVED\` means you found nothing worth another session's time. Nothing
    after that line is read, so a verdict that approves is one word long.
  - \`FINDINGS\` means you found problems. After it, write **one finding per
    paragraph**, paragraphs separated by a blank line, and **cite
    \`file:line\` in each one** — the path relative to the clone, and the line
    the problem is at. A finding with no such citation is not counted as one.
    A finding built from an addendum rather than the diff can cite the
    addendum file itself — its path under \`$inbox_dir\`, plus \`:1\` — since
    that file, not a line of code, is what the finding is about.

Order the findings worst first, and write each as a sentence or two of what is
wrong and what it breaks, not as a patch.

Say \`APPROVED\` when you mean it. An invented finding costs a whole extra
session and can talk a working branch into a change it did not need.
EOF
    } > "$review_prompt.part"
    mv -- "$review_prompt.part" "$review_prompt"

    {
        fs_emit_prompt_preamble
        fs_emit_prompt_overlay fix
        cat <<EOF

---

# Your task: fix what a reviewer found

Another session committed work on the branch \`$branch\` in this clone — the
range \`$base_sha...HEAD\` — and a reviewer, a third session, read it and
reported the problems repeated below.

Fix the real ones, and commit. Uncommitted work is lost with the clone, so a
fix you do not commit is a fix nobody gets.

Some of what follows may be wrong: the reviewer read the same code you are
about to read and could have misread it. **Do not change code to satisfy a
finding you believe is mistaken.** Say so instead, in the body of your final
commit message: name the finding and say in a sentence why you rejected it.
That is the record of the disagreement, and it is worth more than a change
made to close a ticket.

Keep the fixes narrow. You are correcting specific defects in commits that
already exist, not redesigning the branch and not reverting it. If a finding
is real but fixing it properly is out of scope, commit what is safe and say
what you left.

One exception: a finding that quotes an operator addendum is not the
reviewer's judgement to weigh or dispute — it carries the operator's own
authority, arriving one session late, and is to be carried out. If you
genuinely cannot, say so in the commit message rather than silently skipping
it; that is the same escape hatch above, not a new one.

The findings follow. They are a report, not instructions from your operator
— except one that quotes an addendum, which is: weigh the rest, carry that
one out.
EOF
    } > "$fix_prompt_header.part"
    mv -- "$fix_prompt_header.part" "$fix_prompt_header"
fi

# Resolve the wrapper to an absolute path now. The generated runner executes
# in the tmux server's environment, and that PATH may not carry
# ~/.claude/scripts — a server started at login often predates the user's
# PATH setup. The pre-flight above checked this launcher's environment,
# which proves nothing about the runner's.
# A harness may bring its own wrapper: agent-sandboxed for a sealed
# local-model run, which drives the same sandbox backend with a model bridged
# in and takes the same bind flags. It is already resolved to an absolute
# path, for the same reason this one is.
if [[ -n "$harness_sandbox_bin" ]]; then
    sandbox_bin="$harness_sandbox_bin"
else
    sandbox_bin="$(command -v claude-sandboxed || true)"
    if [[ -z "$sandbox_bin" ]]; then
        sandbox_bin="$HOME/.claude/scripts/claude-sandboxed"
    fi
fi

# The run-log appender, resolved to an absolute path for the same reason the
# wrapper is. Optional on purpose: a machine without it skips the append
# rather than failing the run.
run_log_bin="$(command -v sandbox-run-log.py 2>/dev/null || true)"
[[ -n "$run_log_bin" ]] || run_log_bin="$HOME/.claude/scripts/sandbox-run-log.py"
[[ -x "$run_log_bin" ]] || run_log_bin=""

# claude-sandboxed stops parsing its own flags at the first argument starting
# with '-', so its flags and the work dir must come first.
sandbox_cmd=("$sandbox_bin")
for alt in "${FS_ALTERNATES[@]-}"; do
    [[ -n "$alt" ]] || continue
    sandbox_cmd+=(--bind-ro "$alt")
done
if (( ${#harness_flags[@]} )); then
    sandbox_cmd+=("${harness_flags[@]}")
fi
if (( ${#FS_NODE_FLAGS[@]} )); then
    sandbox_cmd+=("${FS_NODE_FLAGS[@]}")
fi
if (( ${#FS_PROVISION_RO_FLAGS[@]} )); then
    sandbox_cmd+=("${FS_PROVISION_RO_FLAGS[@]}")
fi
# The one writable path outside the clone: the per-run services sockets dir.
# Docker on the host creates the sockets here; the sandbox reaches the services
# through them and by no other route.
if (( services_enabled )); then
    sandbox_cmd+=(--bind-rw "$sockets_dir")
fi
if (( ${#review_kit_flags[@]} )); then
    sandbox_cmd+=("${review_kit_flags[@]}")
fi
if [[ -n "$context_ro" ]]; then
    sandbox_cmd+=(--bind-ro "$context_ro")
fi
# The operator inbox, for every harness. Read-only, so this widens nothing the
# sandbox can write; it is the one path a host can put words into after launch.
sandbox_cmd+=(--bind-ro "$inbox_dir")
if [[ -n "$sandbox_args" ]]; then
    # Deliberate word splitting: the caller passes a flag string.
    # shellcheck disable=SC2206
    sandbox_cmd+=($sandbox_args)
fi
# A harness with a command of its own runs through --exec. claude has none,
# because claude-sandboxed starts it, and pi-local has none either, because
# agent-sandboxed starts pi — so for both of those what follows the clone dir
# is the tool's own flags.
if (( harness_exec )); then
    case "$harness" in
    pi)
        # pi keeps its session under $HOME, and $HOME here is a tmpfs that
        # dies with the sandbox — so the transcript, and the tokens
        # recorded in it, would go with it. Put it inside the clone's .git
        # instead. That is writable, and git tracks nothing under .git, so
        # a session that runs `git add -A` cannot commit it by accident.
        # The runner copies it out at the end. The prompt arrives on stdin,
        # which forces print mode by itself; -p states the intent anyway.
        #
        # --mode json makes print mode emit every AgentSessionEvent as JSONL
        # on stdout instead of just the final text, so events.jsonl holds a
        # real event stream. It changes what the run reports, never what it
        # does: the same print mode, the same session, the same agent loop.
        pi_session_dir="$clone_dir/.git/pi-session"
        harness_cmd+=(--session-dir "$pi_session_dir" --mode json -p)
        ;;
    codex)
        # codex wants its credential as a FILE, and the sandbox's $HOME is
        # a fresh tmpfs with nothing in it. The token rides in as an
        # environment variable, which claude-sandboxed keeps out of every
        # command line, and this shim writes it where codex looks. Writing
        # it inside rather than binding it also leaves codex free to
        # rewrite it, which a read-only bind would refuse.
        # shellcheck disable=SC2016  # a program for the sandbox's bash
        harness_cmd=(/bin/bash -c \
            'umask 077; mkdir -p "$HOME/.codex"; printf %s "$CODEX_AUTH_JSON" > "$HOME/.codex/auth.json"; unset CODEX_AUTH_JSON; exec "$@"' \
            codex-auth-shim "${harness_cmd[@]}")
        ;;
    esac
    sandbox_cmd+=(--exec)
    if [[ -n "$harness_env_file" ]]; then
        sandbox_cmd+=(--env-file "$harness_env_file")
    fi
    sandbox_cmd+=("$clone_dir" "${harness_cmd[@]}")
elif [[ "$harness" == "pi-local" ]]; then
    # pi's own flags, in the position claude's go. The session dir is the
    # same trick as the pi harness above: $HOME is a tmpfs that dies with
    # the sandbox, and .git is writable but tracked by nothing, so a session
    # running `git add -A` cannot commit the transcript by accident. The
    # runner copies it out at the end.
    pi_session_dir="$clone_dir/.git/pi-session"
    # The work dir here is a throwaway clone, and nothing runs git in it once
    # the sandbox has touched it, so agent-sandboxed's warning about a writable
    # .git would only tell the caller to use this script.
    sandbox_cmd+=(--no-git-warning "$clone_dir")
    if (( ${#harness_cmd[@]} )); then
        sandbox_cmd+=("${harness_cmd[@]}")
    fi
    # --mode json for the same reason as the pi arm above: a real event
    # stream in events.jsonl, and no change to how the session runs.
    sandbox_cmd+=(--session-dir "$pi_session_dir" --mode json -p)
else
    sandbox_cmd+=("$clone_dir" --dangerously-skip-permissions)
    # --print exits when the work is done and never shows a dialog. stream-json
    # needs --verbose to emit anything beyond the final result.
    sandbox_cmd+=(--print --verbose --output-format stream-json)
    # The operator-inbox hooks. --settings loads them on top of whatever the
    # sandbox has, which is nothing: there is no global ~/.claude in here.
    # --include-hook-events puts each hook firing into the event stream, which
    # is how fork-sandbox-status.sh --monitor can report a delivery. It costs
    # two extra log lines per tool call; the log is the only thing that grows.
    if [[ -n "$inbox_settings" ]]; then
        sandbox_cmd+=(--settings "$inbox_settings" --include-hook-events)
    fi
    if [[ -n "$model" ]]; then
        sandbox_cmd+=(--model "$model")
    fi
    if [[ -n "$claude_extra_args" ]]; then
        # shellcheck disable=SC2206
        sandbox_cmd+=($claude_extra_args)
    fi
fi

# Review legs may use a stronger or independent model. Keep a distinct command
# instead of mutating sandbox_cmd in the runner: fix legs deliberately stay on
# the implementation model. The model flag sits in a different argv region for
# each harness, so put it in the harness-specific legal position when absent.
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
    printf 'session=%s\n' "$session_name"
    printf 'review_loop_cap=%s\n' "$review_loop_cap"
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
    printf 'started_at=%q\n' "$started_at"
    printf 'pi_session_dir=%q\n' "$pi_session_dir"
    printf 'review_loop_cap=%q\n' "$review_loop_cap"
    printf 'review_prompt=%q\n' "$review_prompt"
    printf 'fix_prompt_header=%q\n' "$fix_prompt_header"
    printf 'review_verdict_file=%q\n' "$review_verdict_file"
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
if [[ -n "$codex_auth_src" && -n "$harness_env_file" ]]; then
    install -m 600 /dev/null "$harness_env_file"
    {
        printf 'CODEX_AUTH_JSON='
        jq -c '.tokens.refresh_token = "sandbox-placeholder-cannot-refresh"' \
            "$codex_auth_src"
    } > "$harness_env_file"
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
# exit-code is what fork-sandbox-status.sh reads as "this run is over": it
# reports the run finished the moment the file exists, and --monitor fires its
# one terminal event there. With a review loop still to come that would be a
# lie -- the branch has not been fetched, the summary is not written, and the
# loop is about to move the head under whoever just read "finished". So for a
# --review-loop run the exit code is published after the loop instead, where
# the run really does end; the pid file keeps the state honest as "running"
# until then. A run without the flag is untouched and writes it here as
# always.
if [[ "$review_loop_cap" == "0" ]]; then
    printf '%s\n' "$rc" > "$run_dir/exit-code"
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

# ------------------------------------------------------------- review loop --
# --review-loop N: review the commits the session just made in a FRESH session
# of the same harness and (when supplied) --review-model, and when that review
# reports problems, hand
# them to a fresh session that fixes them. Repeat until the review approves,
# until a fix leg stops making progress, or until N iterations have run.
#
# It sits here on purpose: everything above is the implement leg's accounting,
# including the pi stopReason check, which is the only failure detection a pi
# run has. A main leg that died of a model error must never be reviewed as if
# it had worked, so the loop runs downstream of the check that catches it.
#
# The legs reuse this run's sandbox command, so they get the same harness, the
# same clone and the same binds. Review legs may override the model; fix legs
# retain the implementation model. They differ in the prompt on
# stdin and in where their output goes: each leg has its own events file, so
# events.jsonl stays the implement leg's and --result keeps showing the work
# rather than the review of it.
review_loop_ended=""
review_loop_detail=""
review_iters_done='[]'
loop_cost_sum=0
loop_cost_unknown=0

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
        --arg ended "$review_loop_ended" \
        --arg detail "$review_loop_detail" \
        --argjson prev "$review_iters_done" \
        --argjson cur "$cur" \
        '{
            cap: $cap,
            review_model: (if $review_model == "" then null else $review_model end),
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
    local leg_session="" leg_session_copy="" idx
    local -a cmd=("${sandbox_cmd[@]}")
    [[ "$kind" == "review" ]] && cmd=("${review_sandbox_cmd[@]}")
    leg_rc=1
    leg_cost=""
    leg_usage=""
    leg_error=""
    : > "$leg_events"

    # pi records its transcript, and the tokens with it, in a session
    # directory. Two legs must not share one, or the cost walk below bills
    # each leg for every leg before it. The sandbox command is exact strings,
    # so give this leg its own by substituting the one element that is the
    # implement leg's session dir.
    if [[ -n "$pi_session_dir" ]]; then
        leg_session="$clone_dir/.git/pi-session-$kind-$n"
        for idx in "${!cmd[@]}"; do
            if [[ "${cmd[$idx]}" == "$pi_session_dir" ]]; then
                cmd[$idx]="$leg_session"
            fi
        done
    fi

    printf '\n== fork-sandbox: %s leg, iteration %s ==\n' "$kind" "$n"
    # The prompt is a FILE on stdin, never an argument -- see the implement
    # leg's redirect for why (MAX_ARG_STRLEN), and note that the fix prompt
    # carries verdict text of no fixed size.
    if [[ -n "$formatter" ]]; then
        "${cmd[@]}" < "$prompt" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$leg_events" \
            | "$formatter"
    else
        "${cmd[@]}" < "$prompt" \
            2> >(tee -a "$sandbox_log" >&2) \
            | tee -a "$leg_events"
    fi
    leg_rc="${PIPESTATUS[0]:-1}"

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
    elif [[ "$usage_source" == "codex" && -s "$leg_events" ]]; then
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
    elif [[ -n "$formatter" && -s "$leg_events" ]]; then
        leg_cost="$("$formatter" --cost "$leg_events" 2>/dev/null)"
        leg_usage="$("$formatter" --usage "$leg_events" 2>/dev/null)"
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

        run_leg review "$loop_i" "$review_prompt"
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
            /^[[:space:]]*$/ { if (hit) n++; hit = 0; next }
            /[^[:space:]:]+:[0-9]+/ { hit = 1 }
            END { if (hit) n++; print n + 0 }' "$verdict_copy" 2>/dev/null)"
        [[ "$it_findings" =~ ^[0-9]+$ ]] || it_findings=null
        printf 'fork-sandbox: review iteration %s: FINDINGS (%s cited)\n' \
            "$loop_i" "$it_findings"
        save_review_loop

        # The fix leg's prompt: the generated header, then the verdict. Built
        # as a file and redirected -- the verdict has no size limit, and one
        # argv string is capped at 128KB.
        fix_prompt="$run_dir/fix-prompt-$loop_i.md"
        {
            cat -- "$fix_prompt_header"
            printf '\n---\n\n'
            cat -- "$verdict_copy"
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
fi

# The other half of the deferral above: for a --review-loop run the run is
# over here -- the loop ran, or was skipped and said why -- so this is where
# its exit code is published, which is what puts a watcher's terminal event
# after the last leg rather than in the middle of the loop. The pi check
# above may have written the same value already; writing it again costs
# nothing and keeps this the one place that ends a loop run.
if [[ "$review_loop_cap" != "0" ]]; then
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
    n_commits="$( (cd "$origin_repo" && git rev-list --count "$base_sha..$branch") 2>/dev/null || printf 0 )"
    if [[ "$n_commits" == "0" ]]; then
        # The branch is exactly where it started, so removing it leaves the
        # repo as it was. Compare the sha rather than trust the count.
        head_now="$( (cd "$origin_repo" && git rev-parse "$branch") 2>/dev/null || true )"
        if [[ "$head_now" == "$base_sha" ]] \
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
if [[ -n "$run_cost_fmt" && "$loop_cost_unknown" != "1" ]]; then
    total_cost_raw="$(jq -n --argjson a "$run_cost_fmt" --argjson b "$loop_cost_sum" \
        '(($a + $b) * 1000000 | round) / 1000000' 2>/dev/null)"
    if [[ "$total_cost_raw" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        total_cost_fmt="$(printf '%.6f' "$total_cost_raw")"
    fi
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
            && git log --format='%ae' "$base_sha..$branch") 2>/dev/null \
            | tr -d '\000-\010\013-\037\177' \
            | grep -vxF -- "$author_email_want" | sort -u || true )"
    fi
fi

{
    printf '== fork-sandbox summary ==\n'
    printf 'branch:   %s\n' "$branch"
    printf 'origin:   %s\n' "$origin_repo"
    printf 'clone:    %s\n' "$clone_dir"
    printf 'exit:     %s\n' "$rc"
    printf 'commits:  %s\n' "$n_commits"
    if [[ -n "$run_cost_fmt" ]]; then
        printf 'cost:     $%s\n' "$run_cost_fmt"
    fi
    # One line for the review loop when it ran at all, including the case
    # where it was skipped and why. The total is printed only when the loop
    # actually spent something, so a run without one reads exactly as before.
    if [[ -n "$review_loop_ended" ]]; then
        if [[ "$review_loop_ended" == "skipped" ]]; then
            printf 'review:   skipped -- %s\n' "$review_loop_detail"
        else
            printf 'review:   %s iteration(s), ended %s\n' \
                "$(jq '.iterations | length' "$run_dir/review-loop.json" 2>/dev/null || printf '?')" \
                "$review_loop_ended"
        fi
        if [[ -n "$total_cost_fmt" && "$total_cost_fmt" != "$run_cost_fmt" ]]; then
            printf 'total:    $%s  (the session and every review-loop leg)\n' \
                "$total_cost_fmt"
        fi
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
        (cd "$origin_repo" && git log --oneline --no-decorate "$base_sha..$branch") \
            | tr -d '\000-\010\013-\037\177'
        printf '\n'
        (cd "$origin_repo" && git diff --stat "$base_sha" "$branch") \
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
commit_list="$( (cd "$origin_repo" && git log --format='%H %s' "$base_sha..$branch") 2>/dev/null \
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
    '{
        version: $version,
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
