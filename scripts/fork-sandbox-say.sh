#!/usr/bin/env bash
# fork-sandbox-say.sh — :approved: Send an operator addendum to a running fork-sandbox run
#
# Usage: fork-sandbox-say.sh <run-dir> <text>
#        fork-sandbox-say.sh <run-dir> -        # text read from stdin
#
# <run-dir> is the run directory fork-sandbox.sh printed when it launched.
#
# This is the whole operator interface for steering a run that is already
# going. It writes one timestamped file into <run-dir>/inbox, which is bound
# read-only into the sandbox, so the session sees it without anything being
# remounted or restarted.
#
# An addendum carries the same authority as the handoff: it may override the
# handoff, not merely append to it. Both the generated prompt and the delivery
# hook say so, because without that a session reads a course change as a
# footnote and carries on with the original plan.
#
# When it lands depends on the harness, and this script says which on every
# write:
#   claude   next tool call. A PostToolUse hook puts it beside the tool
#            result, and a Stop hook refuses to let the session finish while
#            an addendum is unread — so it cannot be missed.
#   others   within ~25 tool calls. pi, pi-local and codex have no hook
#            system, so the generated prompt tells the session to read the
#            inbox on a tool-call floor, around long commands, before each
#            commit, and before its final report. Same inbox, slower delivery.
#
# Why this is safe to blanket-approve. It is a bounded write
# (docs/permissions.md): it writes into exactly one structurally constrained
# directory, under a name it generates itself.
#
#   - The launching session already authors the entire handoff — the run's
#     whole prompt — with no prompt at all. An addendum into that same run is
#     no new power; it is the same authority, delivered later.
#   - The target directory is <run-dir>/inbox, where <run-dir> is resolved
#     first and then required to sit under the run-dir prefix and to hold a
#     run.env. A symlinked inbox is refused, so the write cannot be redirected.
#   - The file name is ALWAYS generated (<epoch>-<nn>.md) and never taken from
#     an argument. That is what keeps this from being the arbitrary-file-write
#     primitive a blanket approval must not hand over: there is no argument
#     that names a path.
#   - It writes and never reads anything of yours. The text comes from the
#     command line or stdin, so no path is opened for reading at all.
#
# It refuses a run that has already ended, rather than write a file nothing
# will read, so an operator is never left believing a message landed.

set -uo pipefail

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

RUN_DIR_PREFIX="/var/tmp/claude-scratch/forks/claude-fork-sandbox."
# The pre-consolidation location, still accepted so a run dir from before the
# move can be steered. New runs never land here.
RUN_DIR_PREFIX_LEGACY="/var/tmp/claude-fork-sandbox."

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

run_dir_arg=""
text_arg=""
have_text=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -)
            # The stdin sentinel, not an option. The usual convention for
            # an argument whose value is "read it from stdin".
            [[ -n "$run_dir_arg" ]] || die "the run directory comes first: fork-sandbox-say.sh <run-dir> -"
            (( have_text )) && die "only one message may be given"
            text_arg="$(cat)"
            have_text=1
            shift
            ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            if [[ -z "$run_dir_arg" ]]; then
                run_dir_arg="$1"
            elif (( ! have_text )); then
                text_arg="$1"
                have_text=1
            else
                die "only one message may be given; quote it as a single argument"
            fi
            shift
            ;;
    esac
done

[[ -n "$run_dir_arg" ]] \
    || die "usage: fork-sandbox-say.sh <run-dir> <text>   (or '-' to read stdin)"
(( have_text )) \
    || die "nothing to say. Give the message as one quoted argument, or '-' to read it from stdin."
# A regex find-one-non-space, NOT ${text_arg//[[:space:]]/}: that glob
# substitution rewrites the whole string just to test emptiness, and under
# a UTF-8 locale bash walks it per multibyte character — ~24s of CPU on a
# 360KB stdin message, which reads as a hang. The regex stops at the first
# non-space byte (measured ~5ms on the same input).
[[ "$text_arg" =~ [^[:space:]] ]] \
    || die "the message is empty. A blank addendum tells the session nothing."

# Resolve first, then check the prefix, so a symlink cannot point the write
# somewhere else.
run_dir="$("$FS_REALPATH" -e -- "$run_dir_arg" 2>/dev/null)" \
    || die "'$run_dir_arg' does not exist"
[[ -d "$run_dir" ]] || die "'$run_dir' is not a directory"
[[ "$run_dir" == "$RUN_DIR_PREFIX"* || "$run_dir" == "$RUN_DIR_PREFIX_LEGACY"* ]] \
    || die "'$run_dir' is not a fork-sandbox run directory (expected $RUN_DIR_PREFIX*)"

# run.env is a fixed set of key=value lines. Read it with a match, never with
# `source`, so nothing in it can run. Refuse a symlink for the same reason
# fork-sandbox-status.sh does: a run directory must not be dressable into a
# way to reach some other file.
run_env="$run_dir/run.env"
[[ -L "$run_env" ]] && die "'$run_env' is a symlink; refusing to read it"
[[ -f "$run_env" ]] \
    || die "'$run_dir' has no run.env; it is not a fork-sandbox run directory"

run_env_get() {
    grep -m1 -- "^$1=" "$run_env" | cut -d= -f2-
}

[[ -n "$(run_env_get version)" ]] \
    || die "'$run_dir' has no run.env version; it is not a fork-sandbox run directory"

# Refuse a run that has ended. The runner writes exit-code as the session's
# last act, so its presence is the terminal signal — and a file written after
# that would sit in the inbox forever with nothing to read it.
exit_code_file="$run_dir/exit-code"
if [[ -e "$exit_code_file" && ! -L "$exit_code_file" ]]; then
    die "run has ended; nothing is listening (exit $(tr -dc '0-9-' < "$exit_code_file")).
A new round is a new run — see 'Iterating on a run' in the sandbox-coder-mode skill."
fi

# The same check the status script's run_state makes for "abandoned": the pid
# is there but the process is not. Nothing will read the inbox in that case
# either, and saying so beats a file that vanishes with the run dir.
pid_file="$run_dir/pid"
if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
    pid="$(tr -dc '0-9' < "$pid_file")"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        die "run has ended; nothing is listening (the runner process is gone and
wrote no exit code, so it was probably killed). Nothing was fetched."
    fi
fi

inbox="$run_dir/inbox"
[[ -L "$inbox" ]] && die "'$inbox' is a symlink; refusing to write through it"
[[ -d "$inbox" ]] \
    || die "'$run_dir' has no inbox directory. It was launched by a
fork-sandbox.sh from before the operator inbox existed, so there is no channel
into it. Relaunching is the only way to change its instructions."

# The name is generated, never taken from an argument — that is the property
# that keeps a blanket approval from being an arbitrary-file-write. Allocate
# it under a per-run lock: two sends can happen in the same second, and a
# leg boundary can archive the first file before the next send. The last
# issued name is kept in the run directory, which archiving never touches, so
# an addendum identity cannot be recycled during this run. The archive scan
# also honors names written by an older sender or by a test fixture.
say_lock="$run_dir/.inbox-say.lock"
say_last="$run_dir/.inbox-say-last"
[[ ! -L "$say_lock" ]] || die "'$say_lock' is a symlink; refusing to use it"
[[ ! -L "$say_last" ]] || die "'$say_last' is a symlink; refusing to use it"
exec {say_lock_fd}>"$say_lock" \
    || die "could not open the addendum allocation lock"
flock -x "$say_lock_fd" \
    || die "could not lock the addendum allocation lock"

epoch="$(date +%s)"
name=""
for n in $(seq -w 1 99); do
    candidate="$epoch-$n.md"
    [[ -e "$inbox/$candidate" || -e "$inbox/$candidate.part" ]] && continue
    [[ -f "$say_last" && "$(cat -- "$say_last")" == "$candidate" ]] && continue
    [[ -n "$(find "$run_dir/inbox-delivered" -type f -name "$candidate" \
        -print -quit 2>/dev/null)" ]] && continue
    name="$candidate"
    break
done
[[ -n "$name" ]] \
    || die "99 addenda already written in this second; wait a moment and retry."

# Write beside the destination and rename. A rename within one directory is
# atomic, so the hook and the session never read a half-written addendum.
part="$inbox/$name.part"
if ! printf '%s\n' "$text_arg" > "$part"; then
    rm -f -- "$part"
    die "could not write into '$inbox'"
fi
chmod 644 "$part" 2>/dev/null
if ! mv -- "$part" "$inbox/$name"; then
    rm -f -- "$part"
    die "could not place '$name' in '$inbox'"
fi
if ! printf '%s\n' "$name" > "$say_last"; then
    die "could not record the addendum name in '$say_last'"
fi

harness="$(run_env_get harness)"
[[ -n "$harness" ]] || harness="claude"

printf 'wrote %s\n' "$inbox/$name"
if [[ "$harness" == "claude" ]]; then
    printf 'delivery: next tool call. A Stop hook also blocks the session from\n'
    printf 'finishing while it is unread, so it cannot be missed.\n'
else
    printf 'delivery: within ~25 tool calls. The %s harness has no hook\n' "$harness"
    printf 'system, so the session reads the inbox itself — on a tool-call\n'
    printf 'floor, around long commands, before each commit, and before its\n'
    printf 'final report. Expect it to land later than it would on claude.\n'
fi
