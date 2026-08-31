#!/usr/bin/env bash
# fork-sandbox-status.sh — :approved: Read the state and result of a fork-sandbox run
#
# Usage: fork-sandbox-status.sh [--result | --json | --events N | --log | --monitor | --follow] <run-dir>
#
# <run-dir> is the run directory fork-sandbox.sh printed when it launched.
#
# (no flag):    a compact status block. When the run has finished it also
#               prints the git summary, the review report, and the session's
#               own result text.
#               Its 'inbox:' line counts the operator addenda written into
#               the run with fork-sandbox-say.sh.
# --result:     the review report, when present, followed by the session's
#               own summary of what it did.
# --json:       the run's structured summary — harness, model, branch, exit
#               code, commits with their subjects, cost in dollars — and
#               nothing else, so it pipes into jq. Written when the run
#               ends, so it is absent until then.
# --events N:   the last N formatted events.
# --log:        the sandbox wrapper's messages (startup errors live here).
# --monitor:    watch the run and print one line per notable change, then the
#               summary when it ends. Built for the Monitor tool, so it is
#               deliberately near-silent: notable means commits, operator
#               addenda reaching the session, and the final
#               result, and a session that never commits — a review — shows
#               nothing between heartbeats. It confirms itself with a line
#               when it arms, shows the last event in each heartbeat, and
#               emits on every terminal state, crashes and abandoned runs
#               included, so silence never means success.
# -h, --help:   print this header and exit.
# --follow:     watch the run and print EVERY event, rendered — the same
#               stream the run's tmux pane shows. For a human at a terminal;
#               the Monitor tool wants --monitor. Ends like --monitor does,
#               with the summary, on every terminal state.
#
# Why this is safe to blanket-approve. It reads and never writes, it runs no
# git and no other program except fork-sandbox-format.sh, and it accepts only
# a directory under /var/tmp/claude-scratch/forks/claude-fork-sandbox.* (or the
# legacy /var/tmp/claude-fork-sandbox.*), resolved first, holding a run.env.
# Inside that directory it opens a fixed list of file names (including review
# verdicts) and
# refuses a symlink, so it cannot be turned into a way to read an arbitrary
# file. It never reads stdin.
#
# It deliberately does not inspect the clone. The clone's git config is
# writable by the sandbox, and a key such as core.fsmonitor makes any git
# command there run on the HOST. Everything reported about commits comes
# either from the event log or from the summary the runner wrote after it
# fetched the branch into the user's own repo.

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
formatter="$script_dir/fork-sandbox-format.sh"

RUN_DIR_PREFIX="/var/tmp/claude-scratch/forks/claude-fork-sandbox."
# The pre-consolidation location, still accepted so a run dir from before the
# move can be read. New runs never land here.
RUN_DIR_PREFIX_LEGACY="/var/tmp/claude-fork-sandbox."
POLL_SECONDS=5
HEARTBEAT_SECONDS=300
# The runner writes its pid as its first act. Still no pid after this long and
# it never ran at all — a tmux session that failed to start, say. Report that
# rather than wait forever on a run that does not exist.
START_GRACE_SECONDS=60

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

mode="status"
events_n=""
run_dir_arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result) mode="result"; shift ;;
        --json) mode="json"; shift ;;
        --log) mode="log"; shift ;;
        --monitor) mode="monitor"; shift ;;
        --follow) mode="follow"; shift ;;
        --events)
            mode="events"
            events_n="${2:?--events requires a count}"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            [[ -z "$run_dir_arg" ]] || die "only one run directory may be given"
            run_dir_arg="$1"
            shift
            ;;
    esac
done

[[ -n "$run_dir_arg" ]] || die "usage: fork-sandbox-status.sh [--result | --events N | --log | --monitor | --follow] <run-dir>"
if [[ -n "$events_n" && ! "$events_n" =~ ^[0-9]+$ ]]; then
    die "--events takes a number"
fi
[[ -x "$formatter" ]] || die "$formatter is missing. Run install.sh."

# Resolve first, then check the prefix, so a symlink cannot point the rest of
# this script somewhere else.
run_dir="$("$FS_REALPATH" -e -- "$run_dir_arg" 2>/dev/null)" \
    || die "'$run_dir_arg' does not exist"
[[ -d "$run_dir" ]] || die "'$run_dir' is not a directory"
[[ "$run_dir" == "$RUN_DIR_PREFIX"* || "$run_dir" == "$RUN_DIR_PREFIX_LEGACY"* ]] \
    || die "'$run_dir' is not a fork-sandbox run directory (expected $RUN_DIR_PREFIX*)"

# The only file names this script ever opens. Anything else, and any symlink,
# is refused, so a run directory cannot be dressed up to make this read some
# other file. A refusal never yields a path, so nothing is read either way;
# called at the top level it also stops the script.
#
# The answer comes back in RUN_FILE_PATH rather than on stdout, because `die`
# inside a command substitution would only kill the subshell and the caller
# would carry on. The checks below run before any read, so that ordering
# costs nothing.
RUN_FILE_PATH=""
resolve_run_file() {
    local name="$1" path="$run_dir/$1"
    RUN_FILE_PATH=""
    case "$name" in
        run.env|events.jsonl|sandbox.log|exit-code|summary.txt|summary.json|pid|handoff.md|review-loop.json) ;;
        review-verdict-[0-9]*.md)
            [[ "$name" =~ ^review-verdict-[0-9]+\.md$ ]] || die "'$name' is not a fork-sandbox run file" ;;
        *) die "'$name' is not a fork-sandbox run file" ;;
    esac
    if [[ -L "$path" ]]; then
        die "'$path' is a symlink; refusing to read it"
    fi
    [[ -e "$path" ]] || return 1
    if [[ ! -f "$path" ]]; then
        die "'$path' is not a regular file"
    fi
    RUN_FILE_PATH="$path"
    return 0
}

run_file_read() {
    resolve_run_file "$1" || return 1
    cat -- "$RUN_FILE_PATH"
}

# The same discipline for the one DIRECTORY this script looks at. A fixed name,
# a symlink refusal, and no path ever taken from an argument — so listing the
# inbox cannot be turned into a way to enumerate some other directory.
RUN_SUBDIR_PATH=""
resolve_run_subdir() {
    local name="$1" path="$run_dir/$1"
    RUN_SUBDIR_PATH=""
    case "$name" in
        inbox|inbox-delivered) ;;
        *) die "'$name' is not a fork-sandbox run directory" ;;
    esac
    if [[ -L "$path" ]]; then
        die "'$path' is a symlink; refusing to read it"
    fi
    [[ -e "$path" ]] || return 1
    if [[ ! -d "$path" ]]; then
        die "'$path' is not a directory"
    fi
    RUN_SUBDIR_PATH="$path"
    return 0
}

review_verdict_path() {
    local n path found=""
    for path in "$run_dir"/review-verdict-*.md; do
        [[ -L "$path" ]] && die "'$path' is a symlink; refusing to read it"
        [[ -e "$path" ]] || continue
        n="${path##*/review-verdict-}"; n="${n%.md}"
        [[ "$n" =~ ^[0-9]+$ ]] || die "'$path' is not a valid review verdict name"
        [[ -f "$path" ]] || die "'$path' is not a regular file"
        if [[ -z "$found" || "$n" -gt "$found" ]]; then found="$n"; fi
    done
    [[ -n "$found" ]] || return 1
    printf '%s/review-verdict-%s.md' "$run_dir" "$found"
}

print_report_marker() {
    local verdict leg status
    if verdict="$(review_verdict_path 2>/dev/null)"; then
        leg="${verdict##*/review-verdict-}"; leg="${leg%.md}"
        status="$(head -n 1 -- "$verdict" | tr -d '\000-\037\177' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        printf 'report: review leg %s (%s)\n' "$leg" "$status"
    else
        printf 'report: session\n'
    fi
}

print_review_report() {
    local verdict leg status
    resolve_run_file review-loop.json >/dev/null || return 1
    verdict="$(review_verdict_path 2>/dev/null)" || return 1
    leg="${verdict##*/review-verdict-}"; leg="${leg%.md}"
    status="$(head -n 1 -- "$verdict" | tr -d '\000-\037\177' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if awk '
        $0 == "## Report" { headings++; in_report = 1; next }
        in_report && /[^[:space:]]/ { usable = 1 }
        END { exit !(headings == 1 && usable) }' "$verdict" 2>/dev/null; then
        printf '== report: review leg %s (%s) ==\n' "$leg" "$status"
        awk '/^## Report$/ { in_report=1; next } in_report { print }' "$verdict" \
            | tr -d '\000-\010\013-\037\177'
    else
        printf '== report: review leg %s (%s) — verdict, no usable report section ==\n' \
            "$leg" "$status"
        cat -- "$verdict" | tr -d '\000-\010\013-\037\177'
    fi
    printf '\n'
}

# Preflight verdicts outside command substitutions so a refusal exits this
# process rather than only the subshell used to find the latest leg.
for _verdict in "$run_dir"/review-verdict-*.md; do
    [[ -L "$_verdict" ]] && die "'$_verdict' is a symlink; refusing to read it"
    [[ -e "$_verdict" ]] || continue
    [[ "${_verdict##*/}" =~ ^review-verdict-[0-9]+\.md$ ]] \
        || die "'$_verdict' is not a valid review verdict name"
    [[ -f "$_verdict" ]] || die "'$_verdict' is not a regular file"
done

# How many operator addenda have been sent to this run, or nothing at all for
# a run launched before the inbox existed. Counted rather than listed: the
# names are timestamps and say nothing a reader wants in a status block.
#
# An addendum starts in inbox/ and is archived into inbox-delivered/leg-<N>/
# the moment the leg it was delivered to ends (see fs_archive_inbox in
# fork-sandbox.sh), so this count is a run-lifetime total only if it adds
# both: inbox/ alone would drop to zero after the first leg ends even though
# nothing was ever un-sent.
inbox_count() {
    local have=0 n=0 f d
    if resolve_run_subdir inbox 2>/dev/null; then
        have=1
        for f in "$RUN_SUBDIR_PATH"/*.md; do
            [[ -f "$f" ]] && n=$(( n + 1 ))
        done
    fi
    if resolve_run_subdir inbox-delivered 2>/dev/null; then
        have=1
        for d in "$RUN_SUBDIR_PATH"/leg-*; do
            [[ -L "$d" || ! -d "$d" ]] && continue
            for f in "$d"/*.md; do
                [[ -f "$f" ]] && n=$(( n + 1 ))
            done
        done
    fi
    (( have )) || return 1
    printf '%s' "$n"
}

# The event log, once. Every reader goes through this, so the symlink refusal
# applies to all of them.
have_events() {
    resolve_run_file events.jsonl
}

# run.env is a fixed set of key=value lines. Read it with a match, never with
# `source`, so nothing in it can run.
run_env_get() {
    local key="$1"
    resolve_run_file run.env || return 1
    grep -m1 -- "^$key=" "$RUN_FILE_PATH" | cut -d= -f2-
}

[[ -n "$(run_env_get version)" ]] \
    || die "'$run_dir' has no run.env; it is not a fork-sandbox run directory"
# run_env_get runs in a command substitution above, where a refusal cannot
# stop the script. Resolve it once more directly so a tampered run.env is
# rejected here, before any value from it is used.
resolve_run_file run.env >/dev/null

branch="$(run_env_get branch)"
origin_repo="$(run_env_get origin_repo)"
clone_dir="$(run_env_get clone_dir)"
started_at="$(run_env_get started_at)"
# Older runs recorded a tmux window instead of a session. Fall back to it so a
# run launched before that change still reports where it went.
tmux_target="$(run_env_get session)"
[[ -n "$tmux_target" ]] || tmux_target="$(run_env_get window)"

# Resolve every file this script may open, once, here at the top level, so a
# tampered run directory is rejected before anything is printed. A file the
# run has not written yet is fine and is checked again when it appears.
for _name in events.jsonl sandbox.log exit-code summary.txt summary.json pid; do
    resolve_run_file "$_name" || true
done
resolve_run_subdir inbox || true
resolve_run_subdir inbox-delivered || true

human_duration() {
    local s="$1"
    if (( s < 60 )); then
        printf '%ds' "$s"
    elif (( s < 3600 )); then
        printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    fi
}

# How long the run has taken. Once it has finished, measure to the moment the
# exit code was written rather than to now, so a summary read hours later
# still reports how long the work actually took.
elapsed_seconds() {
    local end
    if [[ ! "$started_at" =~ ^[0-9]+$ ]]; then
        printf '0'
        return
    fi
    if resolve_run_file exit-code 2>/dev/null; then
        end="$("$FS_STAT" -c %Y -- "$RUN_FILE_PATH" 2>/dev/null)"
    fi
    if [[ ! "${end:-}" =~ ^[0-9]+$ ]]; then
        end="$(date +%s)"
    fi
    printf '%s' $(( end - started_at ))
}

elapsed_human() {
    if [[ ! "$started_at" =~ ^[0-9]+$ ]]; then
        printf 'unknown'
        return
    fi
    human_duration "$(elapsed_seconds)"
}

# starting | running | abandoned | done | failed
run_state() {
    local rc pid
    if rc="$(run_file_read exit-code 2>/dev/null)"; then
        rc="${rc//[^0-9-]/}"
        if [[ "$rc" == "0" ]]; then
            printf 'done'
        else
            printf 'failed'
        fi
        return
    fi
    if ! pid="$(run_file_read pid 2>/dev/null)"; then
        printf 'starting'
        return
    fi
    pid="${pid//[^0-9]/}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        printf 'running'
    else
        printf 'abandoned'
    fi
}

exit_code() {
    local rc
    rc="$(run_file_read exit-code 2>/dev/null)" || { printf '?'; return; }
    printf '%s' "${rc//[^0-9-]/}"
}

event_count() {
    if have_events 2>/dev/null; then
        wc -l < "$RUN_FILE_PATH"
    else
        printf '0'
    fi
}

# While the work runs the only evidence is the event log, where counting
# `git commit` calls is an estimate — a commit made by a script leaves no
# line, and a failed attempt still counts. Once the runner has fetched the
# branch it records the real number, counted by git in the user's own repo,
# so prefer that.
commits_from_summary() {
    local n
    resolve_run_file summary.txt 2>/dev/null || return 1
    n="$(grep -m1 '^commits:' -- "$RUN_FILE_PATH" | tr -dc '0-9')"
    [[ -n "$n" ]] || return 1
    printf '%s' "$n"
}

commit_count() {
    if have_events 2>/dev/null; then
        "$formatter" --commit-count "$RUN_FILE_PATH" 2>/dev/null || printf '0'
    else
        printf '0'
    fi
}

commit_count_labelled() {
    local n
    if n="$(commits_from_summary)"; then
        printf '%s\n' "$n"
    else
        printf '%s (seen so far; git has the exact count when it ends)\n' \
            "$(commit_count)"
    fi
}

last_event_line() {
    if have_events 2>/dev/null; then
        "$formatter" --tail 1 "$RUN_FILE_PATH" 2>/dev/null | tail -1
    fi
}

print_status_block() {
    local state
    state="$(run_state)"
    printf 'state:    %s' "$state"
    case "$state" in
        done|failed) printf ' (exit %s, after %s)' "$(exit_code)" "$(elapsed_human)" ;;
        *)           printf ' (%s elapsed)' "$(elapsed_human)" ;;
    esac
    printf '\n'
    printf 'branch:   %s\n' "$branch"
    printf 'origin:   %s\n' "$origin_repo"
    printf 'clone:    %s\n' "$clone_dir"
    printf 'tmux:     %s\n' "$tmux_target"
    printf 'run dir:  %s\n' "$run_dir"
    printf 'commits:  %s\n' "$(commit_count_labelled)"
    printf 'events:   %s\n' "$(event_count)"
    # Printed even at zero, whenever the run has an inbox at all: it tells a
    # reader the steering channel exists and is empty, which is a different
    # fact from a run too old to have one. A run without an inbox prints
    # nothing here, exactly as it did before.
    local addenda
    if addenda="$(inbox_count)"; then
        printf 'inbox:    %s addenda\n' "$addenda"
    fi
    # The runner appends this when the session ends, so it is absent while
    # the work runs and for a run that never reached the end. Read it here
    # rather than at startup for that reason.
    local cost
    cost="$(run_env_get cost)"
    [[ -z "$cost" ]] || printf 'cost:     $%s\n' "$cost"
    local last
    last="$(last_event_line)"
    if [[ -n "$last" ]]; then
        printf 'last:     %s\n' "$last"
    fi
    if [[ "$state" == "abandoned" ]]; then
        printf '\nThe runner process is gone and it never wrote an exit code.\n'
        printf 'The tmux session was probably killed. Nothing was fetched.\n'
    fi
}

print_tail_of_log() {
    if resolve_run_file sandbox.log 2>/dev/null && [[ -s "$RUN_FILE_PATH" ]]; then
        printf '\n-- sandbox wrapper messages --\n'
        tail -n 20 -- "$RUN_FILE_PATH"
    fi
}

case "$mode" in
    result)
        if print_review_report; then
            printf '== the session'"'"'s own account ==\n'
        fi
        out=""
        if have_events 2>/dev/null; then
            out="$("$formatter" --result "$RUN_FILE_PATH")"
        fi
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            state="$(run_state)"
            case "$state" in
                starting|running)
                    printf 'No result yet. The session is still %s, %s in.\n' \
                        "$state" "$(elapsed_human)"
                    ;;
                *)
                    printf 'The session wrote no result. It ended as "%s" after %s,\n' \
                        "$state" "$(elapsed_human)"
                    printf 'so it never finished its turn.\n'
                    print_tail_of_log
                    ;;
            esac
        fi
        ;;

    events)
        if have_events 2>/dev/null; then
            "$formatter" --tail "$events_n" "$RUN_FILE_PATH"
        else
            echo "(no events yet)"
        fi
        ;;

    json)
        # The machine-readable twin of the summary, written when the run
        # ends. Print nothing but the JSON, so this pipes into jq.
        if ! run_file_read summary.json; then
            echo "Error: $run_dir has no summary.json. It is written when the" >&2
            echo "run ends, so a run still going, or one that died before the" >&2
            echo "fetch, does not have one yet." >&2
            exit 1
        fi
        ;;

    log)
        run_file_read sandbox.log || echo "(no sandbox log yet)"
        ;;

    status)
        print_status_block
        state="$(run_state)"
        if [[ "$state" == "done" || "$state" == "failed" ]]; then
            if summary="$(run_file_read summary.txt 2>/dev/null)"; then
                printf '\n%s\n' "$summary"
            fi
            if print_review_report; then
                printf '== the session'"'"'s own account ==\n'
            fi
            if have_events 2>/dev/null; then
                printf '\n'
                "$formatter" --result "$RUN_FILE_PATH"
            fi
        fi
        if [[ "$state" == "failed" || "$state" == "abandoned" ]]; then
            print_tail_of_log
        fi
        ;;

    monitor|follow)
        # The same watch loop with two filters. --monitor prints one line per
        # notable change — commits and the final result — for the Monitor
        # tool, where every line is a notification. --follow prints every
        # event, rendered, for a human who wants to see the run move. Both
        # end the same way: every way the run can stop emits something — a
        # clean exit, a non-zero exit, and a runner that disappeared without
        # writing an exit code.
        filter=(--notable)
        [[ "$mode" == "follow" ]] && filter=()
        offset=0
        last_beat="$(date +%s)"
        # Confirm the watch immediately. In monitor mode a session that never
        # commits — a review, say — has nothing to report until the first
        # heartbeat, a full interval away; without this line the monitor
        # looks dead for exactly that long. A terminal state says nothing
        # here; the loop below reports it in its first pass.
        state="$(run_state)"
        if [[ "$state" == "starting" || "$state" == "running" ]]; then
            printf 'watching: %s, %s elapsed, %s events so far\n' \
                "$state" "$(elapsed_human)" "$(event_count)"
            if [[ "$mode" == "monitor" ]]; then
                last="$(last_event_line)"
                [[ -z "$last" ]] || printf '  last: %s\n' "$last"
            fi
        fi
        while true; do
            if [[ ! -d "$run_dir" ]]; then
                echo "gone: the run directory $run_dir was removed"
                exit 0
            fi

            if have_events; then
                total="$(wc -l < "$RUN_FILE_PATH")"
                if (( total > offset )); then
                    # Stop at the line count read above, so a line still being
                    # written is not reported twice.
                    tail -n "+$(( offset + 1 ))" -- "$RUN_FILE_PATH" \
                        | head -n "$(( total - offset ))" \
                        | "$formatter" "${filter[@]}"
                    offset="$total"
                fi
            fi

            state="$(run_state)"
            case "$state" in
                done|failed)
                    # exit-code is written before the fetch, so wait a bounded
                    # while for the summary the fetch produces.
                    waited=0
                    while [[ ! -f "$run_dir/summary.txt" ]] && (( waited < 120 )); do
                        sleep 2
                        waited=$(( waited + 2 ))
                    done
                    printf 'finished: %s, exit %s, after %s\n' \
                        "$state" "$(exit_code)" "$(elapsed_human)"
                    if summary="$(run_file_read summary.txt 2>/dev/null)"; then
                        printf '%s\n' "$summary"
                    else
                        printf 'No summary was written, so the branch was probably never fetched.\n'
                        print_tail_of_log
                    fi
                    if [[ "$mode" == "monitor" ]]; then
                        print_report_marker
                    fi
                    exit 0
                    ;;
                abandoned)
                    printf 'abandoned: the runner is gone and wrote no exit code, after %s\n' \
                        "$(elapsed_human)"
                    printf 'Nothing was fetched. The clone is still at %s\n' "$clone_dir"
                    print_tail_of_log
                    exit 0
                    ;;
                starting)
                    if (( $(elapsed_seconds) > START_GRACE_SECONDS )); then
                        printf 'never started: no runner process after %s\n' \
                            "$(elapsed_human)"
                        printf 'The tmux session probably never started. Run it by hand with\n'
                        printf '%s/run.sh, or relaunch.\n' "$run_dir"
                        exit 0
                    fi
                    ;;
            esac

            # Heartbeats belong to monitor mode. In follow mode the stream
            # itself shows liveness, and a quiet stretch means exactly what
            # it means in the tmux pane: one long-running tool call.
            now="$(date +%s)"
            if [[ "$mode" == "monitor" ]] && (( now - last_beat >= HEARTBEAT_SECONDS )); then
                printf 'running: %s elapsed, %s commits so far, %s events\n' \
                    "$(elapsed_human)" "$(commit_count)" "$(event_count)"
                # The event count proves liveness; the last event says what
                # the session is doing. A session that never commits gives
                # the heartbeat nothing else to show.
                last="$(last_event_line)"
                [[ -z "$last" ]] || printf '  last: %s\n' "$last"
                last_beat="$now"
            fi

            sleep "$POLL_SECONDS"
        done
        ;;
esac
