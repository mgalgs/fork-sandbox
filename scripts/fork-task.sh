#!/usr/bin/env bash
# fork-task.sh — Launch a Claude Code or Codex session in tmux.
#
# Usage: fork-task.sh [options] <project-path> <handoff-file>
#
# --split:                vertical split (pane below) instead of new window
#                         Requires $TMUX_PANE to be set when using --split.
# --hsplit:               horizontal split (pane beside, side by side) instead
#                         of new window. Requires $TMUX_PANE too.
# --session <name>:       create the new window in that tmux session instead of
#                         the current one. The session must already exist.
#                         Mutually exclusive with --split and --hsplit, which
#                         target a pane.
# --worktree <name>:      create a worktree via <project-path>/.claude/fork-worktree.sh
#                         before launching.  The hook receives <name> plus any
#                         --worktree-args, prints the worktree path to stdout.
# --worktree-args "...":  extra arguments forwarded to fork-worktree.sh
# --harness <name>:        agent to launch: claude (default) or codex
# --sol:                  shorthand for --harness codex --model gpt-5.6-sol
# --model <model>:        model for the new session (e.g. fable, opus, sonnet,
#                         gpt-5.6-sol)
# --claude-args "...":    extra arguments passed verbatim to the claude CLI
# --permission-mode <m>:  permission mode the new claude session starts in
#                         (e.g. auto, acceptEdits, plan). Claude harness only;
#                         meaningless with --sandboxed, which already bypasses
#                         permissions entirely.
# --claude-config-dir <d>: launch claude with CLAUDE_CONFIG_DIR=<d>, so the
#                         session runs on that config dir's plan and
#                         credentials (e.g. a second Claude login's config
#                         dir). Claude harness only; not with --sandboxed — a
#                         sandbox mounts no host config dir, use
#                         fork-sandbox's --claude-credentials there.
# --codex-args "...":     extra arguments passed verbatim to the codex CLI
# --sandboxed:            run the session inside claude-sandboxed, with every
#                         permission check bypassed. Clones the repo first;
#                         see below. Cannot be combined with --worktree.
# --branch <name>:        branch the sandboxed session commits on. Defaults to
#                         a timestamped name.
# --purpose <slug>:       short name for the fork, used as the session name for
#                         cross-session messaging and recorded in the agent
#                         registry. Defaults to the project directory basename.
# --sandbox-args "...":   extra arguments passed to claude-sandboxed itself
#                         (e.g. --unpin-egress)
# -h, --help:             print this header and exit.
#
# Sandboxed mode trades isolation for silence: the session never asks for
# permission, because the sandbox is the boundary instead of the prompt.
#
# --sandboxed starts an INTERACTIVE session, so someone has to answer the
# bypass-permissions dialog and close the session at the end. For an
# unattended run use fork-sandbox.sh, which runs the same sandboxed clone
# headless: no dialog, it exits on its own, and it logs every event to a
# host-side file. The clone and quoting logic below is shared with it,
# in fork-sandbox-lib.sh.
#
# It does NOT run in your checkout. It runs in a throwaway `git clone
# --shared` of it, and only that clone is writable. This is the whole
# security design, not a convenience. A writable git directory is host
# code execution: a hook, or a config key such as core.fsmonitor, runs on
# the HOST the next time anyone uses git in that repo — outside the
# sandbox, with the ssh keys and the tailnet. The clone's own git
# directory is writable and therefore untrusted, so the work comes back
# by `git fetch`, which git deliberately does not let a fetched-from
# repository use to run commands. Nothing writable of yours is ever
# mounted, so there is no hook to plant and nothing to enumerate.
#
# The session commits on --branch. When it exits, this script fetches that
# branch back into your repo and leaves you in a shell there.
#
# What the session gives up:
#   - No global ~/.claude. No global CLAUDE.md, skills, scripts, settings
#     or hooks. A project .claude/ is committed, so it comes with the clone.
#   - No ssh keys, no tokens, no agent. It commits; it cannot push.
#   - No tailnet and no VPN. The LAN stays reachable.
#   - Only committed state. Uncommitted changes, .env files, node_modules
#     and anything else untracked stay behind. So does any project setup a
#     .claude/fork-worktree.sh hook would have done.
# Write the handoff doc so it stands on its own, and tell the session to
# commit — uncommitted work has nothing to fetch.
#
# Reviewing still matters. The sandbox contains the session while it runs;
# it does not make the code it wrote safe. Read the branch before you
# build it, exactly as you would a pull request from a stranger.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# fork-task.sh now lives in fork-sandbox's own scripts/ (this repo,
# github.com/mgalgs/fork-sandbox), beside fork-sandbox-lib.sh, so the first
# candidate below is the one that matches in a normal install: this script
# is reached via a symlink from install.sh's PORCELAIN link (or run in
# place from a checkout), and either way readlink -f resolves script_dir to
# this scripts/ directory. The other candidates are defensive fallbacks --
# a copy of this script running somewhere else on PATH, or a
# ~/.claude/scripts/ layout -- kept in case fork-sandbox-lib.sh is not
# beside it for some reason; they are not expected to fire in the normal
# case.
#
# The source stays eager and the failure below unconditional -- both the
# --sandboxed and NON-sandboxed paths call into fs_reject_unsafe_chars from
# the lib, so there is no path that can skip needing it, and no reason to
# duplicate that check instead of sharing it.
fork_sandbox_lib=""
fork_sandbox_porcelain="$(command -v fork-sandbox.sh 2>/dev/null || true)"
fork_sandbox_beside=""
if [[ -n "$fork_sandbox_porcelain" ]]; then
    fork_sandbox_beside="$(dirname "$(readlink -f "$fork_sandbox_porcelain")")/fork-sandbox-lib.sh"
fi
for cand in "$script_dir/fork-sandbox-lib.sh" \
            "$(command -v fork-sandbox-lib.sh 2>/dev/null || true)" \
            "$fork_sandbox_beside" \
            "$HOME/.claude/scripts/fork-sandbox-lib.sh"; do
    if [[ -n "$cand" && -f "$cand" ]]; then
        fork_sandbox_lib="$(readlink -f "$cand")"
        break
    fi
done
if [[ -z "$fork_sandbox_lib" ]]; then
    echo "Error: cannot find fork-sandbox-lib.sh, which every fork needs" >&2
    echo "(--sandboxed or not) for its shared input checks." >&2
    echo "It should be beside this script in fork-sandbox's scripts/ --" >&2
    echo "check that your fork-sandbox checkout is not missing files." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$fork_sandbox_lib"

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

split=false
split_flag=-v
split_where=below
session=""
worktree_name=""
worktree_args=""
model=""
harness="claude"
claude_extra_args=""
codex_extra_args=""
claude_extra_argv=()
codex_extra_argv=()
sandbox_extra_argv=()
permission_mode=""
claude_config_dir=""
sandboxed=false
sandbox_args=""
branch=""
purpose=""
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --split)
            split=true
            shift
            ;;
        --hsplit)
            split=true
            split_flag=-h
            split_where=beside
            shift
            ;;
        --session)
            session="${2:?--session requires a name}"
            shift 2
            ;;
        --worktree)
            worktree_name="${2:?--worktree requires a name}"
            shift 2
            ;;
        --worktree-args)
            worktree_args="${2:?--worktree-args requires a value}"
            shift 2
            ;;
        --model)
            model="${2:?--model requires a value}"
            shift 2
            ;;
        --harness|--agent)
            harness="${2:?--harness requires a value}"
            case "$harness" in
                claude|codex) ;;
                *)
                    echo "Error: --harness must be claude or codex, got '$harness'" >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --sol)
            harness="codex"
            model="gpt-5.6-sol"
            shift
            ;;
        --claude-args)
            claude_extra_args="${2:?--claude-args requires a value}"
            shift 2
            ;;
        --permission-mode)
            permission_mode="${2:?--permission-mode requires a value}"
            shift 2
            ;;
        --claude-config-dir)
            claude_config_dir="${2:?--claude-config-dir requires a directory}"
            shift 2
            ;;
        --codex-args)
            codex_extra_args="${2:?--codex-args requires a value}"
            shift 2
            ;;
        --sandboxed)
            sandboxed=true
            shift
            ;;
        --sandbox-args)
            sandbox_args="${2:?--sandbox-args requires a value}"
            shift 2
            ;;
        --branch)
            branch="${2:?--branch requires a name}"
            shift 2
            ;;
        --purpose)
            purpose="${2:?--purpose requires a slug}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run 'fork-task.sh --help' for the options." >&2
            exit 1
            ;;
    esac
done

project_path="${1:?Usage: fork-task.sh [options] <project-path> <handoff-file>}"
handoff_file="${2:?Usage: fork-task.sh [options] <project-path> <handoff-file>}"

if ! $sandboxed && [[ -n "$sandbox_args" || -n "$branch" ]]; then
    echo "Error: --sandbox-args and --branch require --sandboxed" >&2
    exit 1
fi
# --split and --hsplit target a pane in the current session; --session targets
# a different session entirely. Asking for both says nothing coherent about
# where to land.
if $split && [[ -n "$session" ]]; then
    echo "Error: --split/--hsplit and --session are mutually exclusive. A split" >&2
    echo "puts a pane in the current window; --session opens one elsewhere." >&2
    exit 1
fi
# Checked up front so a failure costs nothing. Left until after the worktree is
# created, a typo here would strand a fresh worktree with no session to run in.
if [[ -n "$session" ]] && ! tmux has-session -t "$session" 2>/dev/null; then
    echo "Error: no tmux session named '$session'. Existing sessions:" >&2
    tmux list-sessions -F '  #{session_name}' >&2 2>/dev/null || echo "  (none)" >&2
    exit 1
fi
# The two modes isolate in incompatible ways. A worktree shares its object
# store with the main repo and must have it mounted writable to work at
# all; sandboxed mode exists precisely so nothing of yours is writable.
if $sandboxed && [[ -n "$worktree_name" ]]; then
    echo "Error: --sandboxed and --worktree are mutually exclusive. Sandboxed" >&2
    echo "mode clones the repo instead, so that nothing writable of yours is" >&2
    echo "mounted. Drop --worktree and use --branch to name the branch." >&2
    exit 1
fi
if $sandboxed; then
    fs_require_sandbox_wrapper
fi

if [[ ! -d "$project_path" ]]; then
    echo "Error: project path '$project_path' is not a directory" >&2
    exit 1
fi
if [[ ! -f "$handoff_file" ]]; then
    echo "Error: handoff file '$handoff_file' not found" >&2
    exit 1
fi

# Keep the shared fork-sandbox input checks for paths and values that also
# appear in records. The final tmux command is independently shell-quoted.
fs_reject_unsafe_chars "$project_path" "$handoff_file" "$branch" "$model" \
    "$claude_extra_args" "$codex_extra_args" "$sandbox_args" "$purpose" "$harness" \
    "$permission_mode" "$claude_config_dir"

if [[ "$harness" == "claude" && -n "$codex_extra_args" ]]; then
    echo "Error: --codex-args requires --harness codex" >&2
    exit 1
fi
if [[ "$harness" == "codex" && -n "$claude_extra_args" ]]; then
    echo "Error: --claude-args requires --harness claude" >&2
    exit 1
fi

if [[ "$harness" == "codex" && "$sandboxed" == true ]]; then
    echo "Error: --sandboxed already provides Claude's sandbox; use fork-sandbox.sh" >&2
    echo "for an unattended Codex fork, or omit --sandboxed for an interactive Codex pane." >&2
    exit 1
fi

if [[ -n "$permission_mode" && "$harness" != "claude" ]]; then
    echo "Error: --permission-mode requires --harness claude" >&2
    exit 1
fi
if [[ -n "$permission_mode" && "$sandboxed" == true ]]; then
    echo "Error: --permission-mode is meaningless with --sandboxed, which runs" >&2
    echo "--dangerously-skip-permissions; drop one of the two." >&2
    exit 1
fi

if [[ -n "$claude_config_dir" ]]; then
    if [[ "$harness" != "claude" ]]; then
        echo "Error: --claude-config-dir requires --harness claude" >&2
        exit 1
    fi
    if $sandboxed; then
        echo "Error: --claude-config-dir cannot be combined with --sandboxed; a" >&2
        echo "sandbox mounts no host config dir. Use fork-sandbox's" >&2
        echo "--claude-credentials instead." >&2
        exit 1
    fi
    if ! claude_config_dir="$(realpath -e "$claude_config_dir" 2>/dev/null)" \
        || [[ ! -d "$claude_config_dir" ]]; then
        echo "Error: --claude-config-dir: no such directory" >&2
        exit 1
    fi
fi

# Extra-argument options are strings for compatibility with the existing CLI.
# Split them as data, never by eval: each resulting word is shell-quoted when
# the tmux command is assembled below.
if [[ -n "$claude_extra_args" ]]; then
    read -r -a claude_extra_argv <<< "$claude_extra_args"
fi
if [[ -n "$codex_extra_args" ]]; then
    read -r -a codex_extra_argv <<< "$codex_extra_args"
fi
if [[ -n "$sandbox_args" ]]; then
    read -r -a sandbox_extra_argv <<< "$sandbox_args"
fi

# Handle worktree creation
if [[ -n "$worktree_name" ]]; then
    hook="$project_path/.claude/fork-worktree.sh"
    if [[ ! -x "$hook" ]]; then
        echo "Error: --worktree requires $hook to exist and be executable" >&2
        exit 1
    fi
    echo "Creating worktree '$worktree_name'..." >&2
    # shellcheck disable=SC2086
    wt_path=$("$hook" "$worktree_name" $worktree_args) || {
        echo "Error: fork-worktree.sh failed" >&2
        exit 1
    }
    if [[ -z "$wt_path" || ! -d "$wt_path" ]]; then
        echo "Error: fork-worktree.sh did not return a valid directory: '$wt_path'" >&2
        exit 1
    fi
    echo "Worktree ready: $wt_path" >&2
    project_path="$wt_path"
fi

# Use the user's login shell (works for both bash and zsh)
user_shell="${SHELL:-/bin/bash}"

# Sandboxed mode works in a throwaway clone, never in the user's checkout.
fetch_back=""
origin_repo=""
clone_dir=""
if $sandboxed; then
    origin_repo="$(fs_repo_toplevel "$project_path")"
    branch="${branch:-sandbox-$(date +%Y%m%d-%H%M%S)}"

    fs_check_branch_free "$origin_repo" "$branch"
    fs_warn_if_dirty "$project_path" "$origin_repo"

    # The clone parent is machinery, so it lives under the scratch root's
    # forks/ directory. The hook makes it too, but a script cannot assume the
    # hook ran.
    mkdir -p /var/tmp/claude-scratch/forks
    clone_parent="$(mktemp -d /var/tmp/claude-scratch/forks/claude-sandbox-clone.XXXXXX)"
    clone_dir="$clone_parent/${branch//\//-}"
    echo "Cloning '$origin_repo' for the sandbox..." >&2
    fs_make_clone "$origin_repo" "$branch" "$clone_dir"

    fs_collect_alternates "$clone_dir"
    sandbox_bind_argv=()
    for alt in "${FS_ALTERNATES[@]-}"; do
        [[ -n "$alt" ]] || continue
        sandbox_bind_argv+=(--bind-ro "$alt")
    done

    # Node toolchain and dependencies, for a repo that has them
    # (fs_node_provision in the lib explains both halves). The flags join
    # the same double-quoted string the alternates use; the version part
    # is refused by the lib unless it is a plain dotted number, so nothing
    # here can end the single-quoted command this string lands inside.
    fs_node_provision "$origin_repo" "$clone_dir"
    for nf in "${FS_NODE_FLAGS[@]-}"; do
        [[ -n "$nf" ]] || continue
        sandbox_bind_argv+=("$nf")
    done

    echo "Sandbox clone: $clone_dir (branch $branch)" >&2
    project_path="$clone_dir"

    # Runs in the pane once the session exits. Fetching is the one way
    # into the real repo that cannot be turned into code execution by the
    # clone's config, so the work crosses back as objects and nothing else.
    # Quote every dynamic word before this fragment reaches the login shell.
    printf -v origin_q '%q' "$origin_repo"
    printf -v clone_q '%q' "$clone_dir"
    printf -v refspec_q '%q' "$branch:$branch"
    printf -v branch_q '%q' "$branch"
    printf -v shell_q '%q' "$user_shell"
    fetch_back="printf '\\n== sandbox session ended ==\\n';"
    fetch_back="$fetch_back cd $origin_q &&"
    fetch_back="$fetch_back git fetch $clone_q $refspec_q"
    fetch_back="$fetch_back && printf 'fetched branch %s -- review it before building\\n' $branch_q"
    fetch_back="$fetch_back || printf 'fetch failed; the clone is still at %s\\n' $clone_q;"
    fetch_back="$fetch_back exec $shell_q"
fi

# Generate a window/pane name from the project directory basename. Mark
# sandboxed forks, because they behave differently from a normal session.
project_real="$(realpath "$project_path")"
slug=$(basename "$project_real")
if $sandboxed; then
    name="cc-sbx-${slug}"
else
    name="cc-fork-${slug}"
fi

purpose="${purpose:-$slug}"

# Non-sandboxed forks get a deterministic session name so the
# orchestrator can SendMessage them immediately after launch.
session_name=""
if ! $sandboxed; then
    session_name="$purpose"
fi

if $sandboxed; then
    # claude-sandboxed stops parsing its own flags at the first argument
    # starting with '-', so its flags and the work dir must come first.
    prog_argv=(claude-sandboxed "${sandbox_bind_argv[@]}" "${sandbox_extra_argv[@]}" "$project_path" --dangerously-skip-permissions)
    [[ -n "$model" ]] && prog_argv+=(--model "$model")
    prog_argv+=("${claude_extra_argv[@]}")
else
    prog_argv=()
    # env, not a VAR=val prefix: the command is assembled as an argv array,
    # and a bare assignment is not a valid argv[0].
    [[ -n "$claude_config_dir" ]] && prog_argv+=(env "CLAUDE_CONFIG_DIR=$claude_config_dir")
    prog_argv+=(claude)
    [[ -n "$model" ]] && prog_argv+=(--model "$model")
    [[ -n "$session_name" ]] && prog_argv+=(--name "$session_name")
    [[ -n "$permission_mode" ]] && prog_argv+=(--permission-mode "$permission_mode")
    prog_argv+=("${claude_extra_argv[@]}")
fi

if [[ "$harness" == "codex" ]]; then
    # Codex is itself sandboxed in its normal interactive mode. Keep that
    # defense in place; this launcher only supplies the host tmux placement.
    prog_argv=(codex --cd "$project_path")
    [[ -n "$model" ]] && prog_argv+=(--model "$model")
    prog_argv+=("${codex_extra_argv[@]}")
fi

printf -v prog '%q ' "${prog_argv[@]}"
prog="${prog% }"

# Preserve the shared input checks after paths created by worktree/clone
# setup have replaced the original arguments. The command itself is assembled
# from an argv array with printf %q below.
# Re-check here: --worktree and the clone both replace $project_path after
# the first check, with a path this script did not see before.
fs_reject_unsafe_chars "$project_path" "$handoff_file" "$branch" "$origin_repo" \
    "$clone_dir" "$model" "$claude_extra_args" "$codex_extra_args" "$sandbox_args" "$purpose" "$session_name" "$harness" \
    "$claude_config_dir"

# The doc reaches the session on stdin, which tells it everything except
# WHERE IT CAME FROM. That gap costs a whole conversation: the launching
# session keeps working after the fork starts, learns something the doc
# got wrong, fixes the doc — and then has no way to say "read it again",
# because the fork never knew there was a file. So the prompt is the doc
# with one line in front of it naming the path.
#
# The header names the ORIGINAL handoff file, not this composed copy.
# The copy is a snapshot of the moment the window opened; the original is
# the living document the launcher edits.
#
# Not in sandboxed mode. Nothing of the host's is mounted there, so the
# path would be a promise the session cannot keep — it would go looking,
# find nothing, and be worse off than not being told.
prompt_file="$handoff_file"
if ! $sandboxed; then
    prompt_file="$(mktemp "${TMPDIR:-/tmp}/fork-prompt-XXXXXX.md")"
    {
        printf 'Your handoff doc is below, and it lives at %s\n' "$handoff_file"
        printf 'on disk. Keep that path: the session that launched you can\n'
        printf 'still edit it, and may tell you it has been updated and ask\n'
        printf 'you to read it again.\n\n---\n\n'
        cat "$handoff_file"
    } > "$prompt_file"
fi

# Re-checked because prompt_file is a path this script has just built.
fs_reject_unsafe_chars "$prompt_file"

if [[ "$harness" == "codex" ]]; then
    # Codex takes its initial prompt as an argument. Keep stdin attached to the
    # pane so the TUI remains interactive after consuming that prompt.
    prompt_text="$(< "$prompt_file")"
    prog_argv+=("$prompt_text")
    printf -v prog '%q ' "${prog_argv[@]}"
    inner_cmd="${prog% }"
else
    printf -v prompt_q '%q' "$prompt_file"
    inner_cmd="$prog < $prompt_q"
fi
inner_cmd="$inner_cmd${fetch_back:+; $fetch_back}"
printf -v cmd '%q -ic %q' "$user_shell" "$inner_cmd"

if $split; then
    pane="${TMUX_PANE:?TMUX_PANE must be set to split the current pane}"
    new_pane=$(tmux split-window "$split_flag" -t "$pane" -c "$project_path" -P -F '#{pane_id}' "$cmd")
    echo "Split pane created $split_where $pane"
elif [[ -n "$session" ]]; then
    # The trailing colon is what makes this "append a window to that session"
    # rather than "replace the window named $session".
    new_pane=$(tmux new-window -t "$session:" -n "$name" -c "$project_path" -P -F '#{pane_id}' "$cmd")
    echo "New window created: $session:$name"
    echo "Switch to it with: tmux switch-client -t '$session:$name'"
else
    new_pane=$(tmux new-window -n "$name" -c "$project_path" -P -F '#{pane_id}' "$cmd")
    echo "New window created: $name"
fi

# Record the launch in the agent registry so the orchestrator can
# match this fork against ListAgents rows by pane ID.
if ! $sandboxed && [[ -n "${new_pane:-}" ]]; then
    registry="/var/tmp/claude-scratch/agent-registry.jsonl"
    mkdir -p /var/tmp/claude-scratch 2>/dev/null || true
    jq -nc \
        --arg ts "$(date -Iseconds)" \
        --arg pane "$new_pane" \
        --arg project "$project_real" \
        --arg handoff "$handoff_file" \
        --arg purpose "$purpose" \
        --arg session_name "$session_name" \
        --arg claude_config_dir "$claude_config_dir" \
        '{ts: $ts, pane: $pane, project: $project, handoff: $handoff, purpose: $purpose, session_name: $session_name, claude_config_dir: $claude_config_dir}' \
        >> "$registry"
    echo "Session name: $session_name (use SendMessage to reach it)"
    echo "Pane: $new_pane"
    [[ -n "$claude_config_dir" ]] && echo "Claude config dir: $claude_config_dir"
fi

if $sandboxed; then
    echo "Sandboxed: a clone at $clone_dir, not your checkout."
    echo "It has no global ~/.claude, no ssh keys and no tailnet, and it sees"
    echo "committed state only. When it exits, branch '$branch' is fetched"
    echo "into $origin_repo and the pane drops to a shell there."
    echo "Review the branch before you build it."
fi
