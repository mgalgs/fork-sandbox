#!/usr/bin/env bash
# ensure-scratch-dirs.sh — Create the scratch root and keep the /tmp compat symlink
#
# Usage: ensure-scratch-dirs.sh
#
# Runs from the UserPromptSubmit hook. It does two things:
#   1. Creates /var/tmp/claude-scratch/forks and .../fixtures. `mkdir -p` makes
#      both levels. This is the one scratch root, on disk. Interactive scratch
#      files and handoff docs live directly in it; forks/ holds the
#      fork/sandbox machinery — run dirs, stage dirs, sandbox work dirs, lock
#      files — and fixtures/ holds staged read-only inputs for --fixtures.
#
#      fixtures/ is separate from forks/ on purpose, and the separation is a
#      security boundary rather than tidiness: forks/ holds credential staging
#      directories, so a --fixtures bind rooted there would hand a live token
#      to an internet-connected agent at /fixtures/env. Do not merge the two.
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

# Best-effort: this runs on every prompt, so it must never fail the prompt, so
# every step is guarded and the script always exits 0.
#
# That used to be justified with "the scripts that use these paths create them
# too, so a failure here breaks nothing", and that is no longer true of all of
# them. fork-sandbox.sh REFUSES a --fixtures directory outside fixtures/ rather
# than creating the root, because the root is a security boundary and a
# launcher that created what it was about to trust would be no boundary at all.
# So a failure here is not free for that path: it turns into a refused run
# later. Still best-effort, because failing the prompt is worse -- but the
# installer calls this too, which is where a permissions problem should surface
# loudly instead.
mkdir -p "$root/forks" "$root/fixtures" 2>/dev/null || true

# A dangling symlink counts as absent to -e but as a link to -L, so test -L
# first. A real directory fails both tests, so it is left alone.
if [[ -L "$link" || ! -e "$link" ]]; then
    ln -sfn "$root" "$link" 2>/dev/null || true
fi

exit 0
