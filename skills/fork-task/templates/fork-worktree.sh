#!/usr/bin/env bash
# fork-worktree.sh -- create an isolated worktree for a forked Claude Code session.
#
# TEMPLATE. Copy this to <project>/.claude/fork-worktree.sh, `chmod +x` it, then
# adapt the PROJECT-SPECIFIC sections near the bottom. It runs correctly as-is on
# a repo with no dependency directory and no ignored config.
#
# Contract (see the fork-task skill):
#   .claude/fork-worktree.sh <name> [extra-args...]
#   - prints the absolute worktree path to stdout: one line, nothing else
#   - status messages go to stderr
#   - exits non-zero on failure
#
# stdout IS the return value. Any echo that is not the final path must be
# redirected to stderr, or fork-task.sh reads the noise as the worktree path.
# `git worktree add` and `cp -v` both write to stdout -- redirect them.

set -euo pipefail

name="${1:?usage: fork-worktree.sh <name> [extra-args...]}"
shift
extra_args=("$@")

# The name becomes a branch name and a directory name. Keep it boring.
if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: name must be lowercase kebab-case: $name" >&2
    exit 1
fi

# readlink -f so this still resolves when .claude/ is a symlink.
repo_root="$(git -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" rev-parse --show-toplevel)"

# Worktrees live beside the repo, never inside it: a worktree inside the repo
# gets swept up by test globs, linters, and bundlers.
worktree_root="$(dirname "$repo_root")/$(basename "$repo_root")-worktrees"
target="$worktree_root/$name"

# Pre-flight. `git worktree add` fails on both of these anyway, but its message
# does not say how to recover.
if [ -e "$target" ]; then
    echo "error: path already exists: $target" >&2
    echo "hint: remove it with 'git worktree remove $target', or pick another name." >&2
    exit 1
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name"; then
    echo "error: branch already exists: $name" >&2
    exit 1
fi

mkdir -p "$worktree_root"

# Branch from the current HEAD, not from the main branch: a fork usually
# continues the work that is checked out right now, and that work may not be
# merged yet.
base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
echo "==> creating worktree $name from $base" >&2
git -C "$repo_root" worktree add -b "$name" "$target" >&2

# A worktree gets the tracked files and nothing else. Ignored files that the
# session needs have to be copied over.
#
# The .claude settings are the pair that always applies -- they hold the
# permission rules, so without them a session in the worktree prompts for things
# the parent repo allows. settings.local.json is gitignored by definition.
# settings.json is often tracked, but do not count on it: a global gitignore
# with a `/.claude/` line ignores the whole directory, and then it is only in the
# parent because someone force-added it. Copying whatever the worktree did not
# already get is correct either way.
carry=(
    ".claude/settings.json"
    ".claude/settings.local.json"
    # PROJECT-SPECIFIC: add ignored files the worktree needs, for example
    # ".env"
    # "web/.env.local"
)

for rel in "${carry[@]}"; do
    # Nothing to copy, or tracked and git already placed it.
    if [ ! -f "$repo_root/$rel" ] || [ -e "$target/$rel" ]; then
        continue
    fi
    mkdir -p "$target/$(dirname "$rel")"
    cp "$repo_root/$rel" "$target/$rel"
    echo "==> copied $rel" >&2
done

# Claude Code prompts for any path outside the session's working directory, even
# when the command itself is allowlisted. So a session in the parent repo that
# reads a file in this worktree prompts unless the worktree root is listed in
# additionalDirectories. That is one-time parent setup, not something this hook
# can do for itself -- so just say so.
if ! grep -qF "$worktree_root" "$repo_root/.claude/settings.local.json" 2>/dev/null; then
    echo "note: $worktree_root is not in the parent's additionalDirectories." >&2
    echo "      Without it, this session prompts when it reads worktree files." >&2
    echo "      Add to .claude/settings.local.json:" >&2
    echo "        \"permissions\": { \"additionalDirectories\": [\"$worktree_root\"] }" >&2
fi

# PROJECT-SPECIFIC: dependencies.
#
# A worktree has no node_modules / .venv / vendor, and the build fails until it
# does. Pick one and delete the rest:
#
#   Symlink (fast, but the two trees share state -- avoid if the fork will
#   add or upgrade a dependency):
#     ln -s "$repo_root/node_modules" "$target/node_modules"
#
#   Copy (isolated, slower, more disk):
#     cp -a "$repo_root/node_modules" "$target/node_modules" >&2
#
#   Install from scratch (slowest, always correct):
#     (cd "$target" && npm ci) >&2
#
# Use "${extra_args[@]}" to let the caller choose, e.g. a --shared-deps flag.
if [ ${#extra_args[@]} -gt 0 ]; then
    echo "note: ignoring extra args: ${extra_args[*]}" >&2
fi

# PROJECT-SPECIFIC: a dev server port, if two checkouts would collide on one.
# Derive it from the name so recreating the same worktree keeps the same port:
#   port=$((5200 + $(cksum <<<"$name" | cut -d' ' -f1) % 60))

# The contract: the path, on stdout, last.
echo "$target"
