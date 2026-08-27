#!/usr/bin/env bash
# ensure-scratch-dirs.sh — Create the scratch root and keep the /tmp compat symlink
#
# Usage: ensure-scratch-dirs.sh
#
# Runs from the UserPromptSubmit hook. It does two things:
#   1. Creates /var/tmp/claude-scratch/forks. `mkdir -p` makes both levels.
#      This is the one scratch root, on disk. Interactive scratch files and
#      handoff docs live directly in it; forks/ holds the fork/sandbox
#      machinery — run dirs, stage dirs, sandbox work dirs, lock files.
#   2. Maintains a compatibility symlink /tmp/claude-scratch ->
#      /var/tmp/claude-scratch, so old references keep working. /tmp empties on
#      reboot, so this recreates the link on the next prompt each boot.
#
# The scratch root is on disk (/var/tmp), not in RAM (/tmp), because the fork
# machinery under forks/ stores multi-GB clones and node_modules copies that
# tmpfs cannot hold.
#
# The symlink is replaced only when /tmp/claude-scratch is safe to replace: an
# existing symlink this hook can repoint, or nothing at all. A real directory
# there belongs to an older session, so it is left untouched, never clobbered.

set -uo pipefail

root="/var/tmp/claude-scratch"
link="/tmp/claude-scratch"

# Best-effort: this runs on every prompt, so it must never fail the prompt. The
# scripts that use these paths create them too, so a failure here breaks
# nothing. Hence every step is guarded and the script always exits 0.
mkdir -p "$root/forks" 2>/dev/null || true

# A dangling symlink counts as absent to -e but as a link to -L, so test -L
# first. A real directory fails both tests, so it is left alone.
if [[ -L "$link" || ! -e "$link" ]]; then
    ln -sfn "$root" "$link" 2>/dev/null || true
fi

exit 0
