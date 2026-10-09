#!/usr/bin/env bash
# fork-sandbox-status.sh — :approved: Read the state and result of a fork-sandbox run
#
# Usage: fork-sandbox-status.sh [--result | --json | --events N | --log | --monitor | --monitor-terminal | --follow] <run-dir>...
#        fork-sandbox-status.sh --json --set <run-dir>...
#        fork-sandbox-status.sh --session <id> --progress
#
# <run-dir> is the run directory fork-sandbox.sh printed when it launched.
#
# (no flag):    a compact status block. When the run has finished it also
#               prints the git summary, the maintainer report, the review
#               report, and the session's own result text.
#               Its 'inbox:' line counts the operator addenda written into
#               the run with fork-sandbox-say.sh.
# --result:     the maintainer report, then the review report, when present,
#               followed by the session's own summary of what it did.
# --json:       one <run-dir>, no --set: the run's structured summary --
#               harness, model, branch, exit code, commits with their
#               subjects, cost in dollars -- and nothing else, so it pipes
#               into jq. Written when the run ends, so it is absent until
#               then, and this hard-exits 1 on a run dir with no
#               summary.json yet.
#               2+ <run-dir>s, or --set with any number including one: a
#               fleet view, {"runs": [...], "totals": {...}}. "runs" holds
#               one object per argument, in argument order. A run dir with
#               no summary.json yet -- still going, or dead before the
#               fetch -- gets {run_id, state, branch, harness, model,
#               summary: false} instead of failing the whole call; a run
#               dir this script cannot read at all (not a run dir, or a
#               symlink where a run file should be) gets {run_id, state:
#               "unreadable", summary: false, error}. Either way "summary"
#               is the marker: false means no summary.json fields are on
#               this entry, true means the entry is that run's full
#               summary.json plus run_id and a derived state -- derived as
#               "unknown", never guessed as "failed", when exit_code in
#               that summary.json is null or otherwise not a number.
#               "totals"
#               never renders an unknown cost as a $0 masquerading as
#               known: cost_usd_total sums total_cost_usd only over runs
#               where it is a number (never coerces a missing/null one to
#               0), runs_with_cost and runs_without_cost count the same
#               split, and states counts every run's state, one key per
#               state that actually occurs. Two defaults, on purpose: an
#               absent states key is a genuine zero, a null
#               cost_usd_total is NOT KNOWN -- default the counts, never
#               the cost.
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
# --monitor-terminal: like --monitor, but with the mid-run stream
#               suppressed: every mid-run line is a notification that goes
#               nowhere for the Monitor tool of an orchestrating session
#               that acts on terminal events only. At the terminal state it
#               waits for the summary, then prints one block: the code
#               leg's final result event, when the session wrote one
#               (labelled as the code leg's on a multi-leg run), then the
#               same finished line, summary, and report marker --monitor
#               prints. Cannot be combined with another mode flag in either
#               argument order.
# --follow:     watch the run and print EVERY event, rendered — the same
#               stream the run's tmux pane shows. For a human at a terminal;
#               the Monitor tool wants --monitor-terminal. Ends like
#               --monitor does,
#               with the summary, on every terminal state.
# --session <id> --progress: takes no <run-dir> at all. One compact line per
#               run this Claude session (CLAUDE_CODE_SESSION_ID at launch)
#               has started, oldest first, read from each run's own
#               progress.json via the by-session index fork-sandbox.sh
#               writes at launch time (FORK_SANDBOX_BY_SESSION_DIR
#               overrides its root, for tests). Each line is
#               "<label>  <state>  <action>:<state>[(<i>/<cap>)] ...", one
#               <action>:<state> per pipeline step, e.g.:
#                 sbx-foo  running  code:done review:running(1/2) maintain:pending
#               A run linked under the session but with no progress.json
#               yet prints its run-dir basename and a bare "?". An unknown
#               session (no index directory at all) prints nothing and
#               exits 0. Reads no git, like every other mode here.
#
# Why this is safe to blanket-approve. It reads and never writes, it runs no
# git and no other program except fork-sandbox-format.sh, and it accepts only
# a directory under /var/tmp/claude-scratch/forks/claude-fork-sandbox.* (or the
# legacy /var/tmp/claude-fork-sandbox.*), resolved first, holding a run.env.
# Inside that directory it opens a fixed list of file names (including the
# review and maintainer loop records and the review and maintainer verdicts)
# and
# refuses a symlink, so it cannot be turned into a way to read an arbitrary
# file. It never reads stdin. --session --progress reads a by-session
# symlink instead of a <run-dir> argument, but print_progress_view holds
# each resolved link target to this same prefix-and-run.env rule (and
# progress.json to the same non-symlink, regular-file rule) before opening
# it, and validates the session id itself against the launcher's own
# single-path-component shape before touching the by-session root at all --
# so neither an adversarial link nor a "--session ../x" can point it
# anywhere this boundary would otherwise exclude.
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
# The resolved path to this very script, so the fleet wrapper can
# re-invoke it once per run dir (see run_fleet_json).
self="$(readlink -f "${BASH_SOURCE[0]}")"

RUN_DIR_PREFIX="$FS_SCRATCH_ROOT/forks/claude-fork-sandbox."
# The pre-consolidation location, still accepted so a run dir from before the
# move can be read. New runs never land here.
RUN_DIR_PREFIX_LEGACY="$("$FS_REALPATH" -m /var/tmp)/claude-fork-sandbox."
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

set_mode() {
    # A mode flag after --monitor-terminal would switch the mode out from
    # under its terminal_only flag — a --follow that prints nothing at all,
    # a --monitor that stays silent for its whole window — so
    # --monitor-terminal cannot be combined with another mode flag in either
    # order. This catches the flag-after case; the flag-before case is caught
    # where --monitor-terminal is parsed, against the mode flag set_mode
    # recorded.
    if (( terminal_only )); then
        die "$2 cannot be combined with --monitor-terminal"
    fi
    mode="$1"
    explicit_mode="$2"
}

usage() {
    # The header block is the documentation: print it from line 2 down to the
    # first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

# --json's fleet view: one --json call per run dir, each a fresh child
# process, so a run dir this script cannot read dies only in its own child
# and never takes the aggregate down with it -- the FS_STATUS_FLEET_MEMBER
# child gets this script's ordinary single-dir resolution, symlink refusal
# included, for free. A child that exits 0 already printed the right shape
# (the full summary, or the no-summary-yet stand-in -- see the
# fleet-member case arm); a child that exits non-zero hit a die() before
# either was possible, so its first stderr line becomes this run's
# "unreadable" entry.
run_fleet_json() {
    local dirs=("$@") dir rid out errline
    local -a entries=()
    for dir in "${dirs[@]}"; do
        rid="$(basename -- "${dir%/}")"
        if out="$(FS_STATUS_FLEET_MEMBER=1 "$self" "$dir" 2>&1)"; then
            entries+=("$out")
        else
            errline="$(printf '%s\n' "$out" | head -n1)"
            errline="${errline#Error: }"
            entries+=("$(jq -n --arg rid "$rid" --arg err "$errline" \
                '{run_id: $rid, state: "unreadable", summary: false, error: $err}')")
        fi
    done
    local runs_json
    runs_json="$(printf '%s\n' "${entries[@]}" | jq -s '.')"
    jq -n --argjson runs "$runs_json" '
        def is_known: (.total_cost_usd != null and (.total_cost_usd | type) == "number");
        ($runs | map(select(is_known))) as $known
        | ($runs | map(select(is_known | not))) as $unknown
        | {
            runs: $runs,
            totals: {
                runs: ($runs | length),
                cost_usd_total: (if ($known | length) == 0 then null
                                  else ($known | map(.total_cost_usd) | add) end),
                runs_with_cost: ($known | length),
                runs_without_cost: ($unknown | length),
                states: ($runs | group_by(.state) | map({key: .[0].state, value: length}) | from_entries)
            }
        }'
}

# --session <id> --progress's own reader: one compact line per run this
# Claude session has launched, oldest link first. The by-session index is a
# directory of symlinks fork-sandbox.sh creates at launch time (never
# pruned), named by the run dir's own basename. A link's target is not
# trusted just because it lives in that index: it is resolved and then held
# to the exact same "Why this is safe" invariant every other mode here
# gives -- a directory under RUN_DIR_PREFIX (or the legacy prefix) that
# holds a real, non-symlink run.env -- before progress.json, itself checked
# non-symlink and regular, is read from it. Sorted by each SYMLINK's own
# mtime (lstat, not the target's -- the run dir's mtime moves constantly as
# progress.json is rewritten, which is not launch order at all), captured
# once when fork-sandbox.sh created the link and never touched again.
print_progress_view() {
    local session="$1" by_session_root link mtime base target
    # The launcher only ever creates an index directory named by its own
    # validated session id (see the by-session link comment in
    # fork-sandbox.sh): a single path component, never ".", ".." or
    # carrying a "/". A session id shaped any other way cannot be a real
    # index -- most dangerously "..", which "$by_session_root/$session"
    # would otherwise resolve to the by-session root's own parent -- so it
    # is refused here the same way an unknown session is: nothing printed,
    # exit 0.
    if [[ ! "$session" =~ ^[A-Za-z0-9._-]+$ \
            || "$session" == "." || "$session" == ".." ]]; then
        return 0
    fi
    by_session_root="${FORK_SANDBOX_BY_SESSION_DIR:-$FS_SCRATCH_ROOT/forks/by-session}"
    [[ -d "$by_session_root/$session" ]] || return 0
    while IFS=$'\t' read -r mtime link; do
        [[ -n "$link" ]] || continue
        base="$(basename -- "$link")"
        target="$("$FS_REALPATH" -e -- "$link" 2>/dev/null)"
        if [[ -z "$target" || ! -d "$target" \
                || ( "$target" != "$RUN_DIR_PREFIX"* && "$target" != "$RUN_DIR_PREFIX_LEGACY"* ) \
                || -L "$target/run.env" || ! -f "$target/run.env" \
                || -L "$target/progress.json" || ! -f "$target/progress.json" ]]; then
            printf '%s  ?\n' "$base"
            continue
        fi
        print_progress_line "$target/progress.json" "$base"
    done < <(
        for link in "$by_session_root/$session"/*; do
            [[ -L "$link" ]] || continue
            mtime="$("$FS_STAT" -c '%Y' -- "$link" 2>/dev/null)" || continue
            printf '%s\t%s\n' "$mtime" "$link"
        done | sort -n -s -k1,1
    )
}

# $1 a progress.json path already resolved and confirmed to be a plain
# file, never a symlink (see print_progress_view's own checks). $2 the
# run-dir basename, used as the displayed name when the file carries no
# label (should not happen, but a reader must never print nothing). One
# line: "<label>  <state>  <action>:<state>(<i>/<cap>) ...", the (<i>/<cap>)
# suffix only on a step whose cap is not 1 -- a plain one-pass code step
# never shows it, matching the module's own worked example.
print_progress_line() {
    local path="$1" fallback="$2" json
    json="$(cat -- "$path" 2>/dev/null)"
    if [[ -z "$json" ]]; then
        printf '%s  ?\n' "$fallback"
        return
    fi
    # progress.json is collect's own pull-back on a composed --k8s run (or
    # a live pod's push of the same file, on a design that later allows
    # it) -- the same untrusted-stranger bytes the verdict readers
    # elsewhere in this script already strip control characters from, so
    # the rendered line gets the same treatment here.
    printf '%s' "$json" | jq -r --arg fallback "$fallback" '
        (.label // $fallback) as $label
        | (.state // "unknown") as $state
        | ([.steps[]?
             | (.action // "?") + ":" + (.state // "?")
               + (if (.cap // 1) != 1
                  then "(" + ((.i // 0) | tostring) + "/" + ((.cap // 1) | tostring) + ")"
                  else "" end)
           ] | join(" ")) as $steps
        | $label + "  " + $state + "  " + $steps' 2>/dev/null \
        | tr -d '\000-\010\013-\037\177' \
        || printf '%s  ?\n' "$fallback"
}

mode="status"
events_n=""
run_dir_args=()
fleet_set=0
terminal_only=0
session_arg=""
# The name of a mode flag already parsed, so --monitor-terminal can refuse
# to follow one — the reverse of the case set_mode refuses, the same broken
# combination with the arguments swapped.
explicit_mode=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result) set_mode result --result; shift ;;
        --json) set_mode json --json; shift ;;
        --log) set_mode log --log; shift ;;
        --monitor) set_mode monitor --monitor; shift ;;
        --monitor-terminal)
            [[ -z "$explicit_mode" ]] \
                || die "--monitor-terminal cannot be combined with $explicit_mode"
            mode="monitor"; terminal_only=1; shift
            ;;
        --follow) set_mode follow --follow; shift ;;
        --events)
            set_mode events --events
            events_n="${2:?--events requires a count}"
            shift 2
            ;;
        --set) fleet_set=1; shift ;;
        --session)
            session_arg="${2:?--session requires a session id}"
            shift 2
            ;;
        --progress) set_mode progress --progress; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            run_dir_args+=("$1")
            shift
            ;;
    esac
done

# FS_STATUS_FLEET_MEMBER is set only by run_fleet_json's own re-invocation
# of this script above, one child per run dir, and never by a real caller.
# It overrides mode here, after flags are parsed, so the child needs no
# flag of its own -- the env var alone decides, and no dir count or mode
# rule below applies to it (it always runs with exactly one dir and no
# --set).
if [[ -n "${FS_STATUS_FLEET_MEMBER:-}" ]]; then
    mode="fleet-member"
fi

if (( fleet_set )); then
    [[ "$mode" == "json" ]] || die "--set is only valid with --json"
    (( ${#run_dir_args[@]} > 0 )) || die "--set requires at least one run directory"
fi
if [[ -n "$session_arg" && "$mode" != "progress" ]]; then
    die "--session is only valid with --progress"
fi
if [[ "$mode" == "progress" ]]; then
    [[ -n "$session_arg" ]] || die "--progress requires --session <id>"
    (( ${#run_dir_args[@]} == 0 )) || die "--progress takes no run directory argument"
fi
if (( ${#run_dir_args[@]} > 1 )) && [[ "$mode" != "json" ]]; then
    die "only one run directory may be given"
fi
if [[ -n "$events_n" && ! "$events_n" =~ ^[0-9]+$ ]]; then
    die "--events takes a number"
fi
[[ -x "$formatter" ]] || die "$formatter is missing. Run install.sh."

# --session --progress takes no run directory at all -- it reads the
# by-session index fork-sandbox.sh writes at launch, not a run dir named on
# this command line -- so it is dispatched here, before every check below
# that assumes exactly one (or, for --json, one-or-more) run-dir argument.
if [[ "$mode" == "progress" ]]; then
    print_progress_view "$session_arg"
    exit 0
fi

# --json with 2+ run dirs, or --set at any arity (including one -- a
# one-seat fleet is legal, and lkml's fleet screens must be able to ask
# for the wrapper shape unconditionally), is the fleet view. Every other
# case -- one bare dir, no --set -- falls through to the single-dir path
# below, untouched, so that shape stays byte-identical to before this
# existed.
wrapper_mode=0
if [[ "$mode" == "json" ]] && { (( fleet_set )) || (( ${#run_dir_args[@]} > 1 )); }; then
    wrapper_mode=1
fi
if (( wrapper_mode )); then
    run_fleet_json "${run_dir_args[@]}"
    exit $?
fi

[[ ${#run_dir_args[@]} -eq 1 ]] \
    || die "usage: fork-sandbox-status.sh [--result | --events N | --log | --monitor | --monitor-terminal | --follow] <run-dir>"
run_dir_arg="${run_dir_args[0]}"

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
        run.env|events.jsonl|sandbox.log|exit-code|summary.txt|summary.json|pid|handoff.md|review-loop.json|maintainer-loop.json|plan.md|tidy.json|pipeline.json) ;;
        step-[0-9]*-loop.json)
            [[ "$name" =~ ^step-[0-9]+-loop\.json$ ]] || die "'$name' is not a fork-sandbox run file" ;;
        # One file per leg, named by the runner. The leg kinds are
        # enumerated literally and the name is re-checked against the exact
        # pattern: a loose events-*.jsonl would let any name that starts
        # events- through, which is the property this allowlist exists to
        # deny. A repeat pass of a leg appends -p<P> to the leg number, and
        # the refresh loop's continuation legs and the code leg's repeat
        # passes have their own kinds. A code or fix leg that itself
        # refreshes (every code and fix leg now can, not just the run's
        # step-1 implement leg) appends -continuation-<C> to ITS OWN leg
        # name instead of getting the flat events-continuation-N.jsonl the
        # step-1 chain still uses -- see fs_refresh_chain's own naming
        # comment in fork-sandbox.sh.
        events-review-[0-9]*.jsonl|events-fix-[0-9]*.jsonl|events-maintainer-[0-9]*.jsonl|events-mntfix-[0-9]*.jsonl|events-code-[0-9]*.jsonl|events-continuation-[0-9]*.jsonl|events-tidy-[0-9]*.jsonl)
            [[ "$name" =~ ^events-(review|fix|maintainer|mntfix|code|continuation|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ ]] \
                || die "'$name' is not a fork-sandbox run file" ;;
        events-s[0-9]*-*.jsonl)
            [[ "$name" =~ ^events-s[0-9]+-(code|review|maintain|fix|plan|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ ]] \
                || die "'$name' is not a fork-sandbox run file" ;;
        review-verdict-[0-9]*.md)
            [[ "$name" =~ ^review-verdict-[0-9]+\.md$ ]] || die "'$name' is not a fork-sandbox run file" ;;
        maintainer-verdict-[0-9]*.md)
            [[ "$name" =~ ^maintainer-verdict-[0-9]+\.md$ ]] || die "'$name' is not a fork-sandbox run file" ;;
        s[0-9]*-*-verdict-[0-9]*.md)
            [[ "$name" =~ ^s[0-9]+-(review|maintain)-verdict-[0-9]+\.md$ ]] || die "'$name' is not a fork-sandbox run file" ;;
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

# The best verdict this run has, filtered to one action when asked and
# optionally required to have a finished loop record backing it: one scan
# serves both the marker (any action, no loop-record gate -- it worked this
# way before composed pipelines existed and nothing here changes that) and
# the two report bodies (one action each, gated on the loop record so an
# orphaned verdict with no accompanying loop record still prints nothing,
# exactly as before).
#
# "Highest step wins, ties break to the highest iteration" is the one
# comparison every caller shares. A legacy-shaped pipeline is always
# compiled code-then-review-then-maintain, so pinning legacy review to step
# 1 and legacy maintainer to step 2 reproduces the old "maintainer outranks
# review" marker as one instance of this rule, not a second hardcoded order.
# A composed pipeline's real step numbers come from its s<K>- prefixed
# verdict names. A legacy and a composed run never share a run directory (a
# whole-pipeline, compile-time choice), so the two numbering schemes never
# collide here.
#
# Sets STEP_VERDICT_STEP, STEP_VERDICT_ACTION, STEP_VERDICT_ITER and
# STEP_VERDICT_PATH. Returns 1 when nothing matches.
STEP_VERDICT_STEP=""
STEP_VERDICT_ACTION=""
STEP_VERDICT_ITER=""
STEP_VERDICT_PATH=""
best_verdict() {
    local want_action="$1" require_loop="$2"
    STEP_VERDICT_STEP=""
    STEP_VERDICT_ACTION=""
    STEP_VERDICT_ITER=""
    STEP_VERDICT_PATH=""
    local path base step action iter loopfile
    for path in "$run_dir"/review-verdict-*.md "$run_dir"/maintainer-verdict-*.md \
            "$run_dir"/s[0-9]*-*-verdict-*.md; do
        [[ -L "$path" ]] && die "'$path' is a symlink; refusing to read it"
        [[ -e "$path" ]] || continue
        base="${path##*/}"
        if [[ "$base" =~ ^review-verdict-([0-9]+)\.md$ ]]; then
            step=1; action=review; iter="${BASH_REMATCH[1]}"; loopfile=review-loop.json
        elif [[ "$base" =~ ^maintainer-verdict-([0-9]+)\.md$ ]]; then
            step=2; action=maintain; iter="${BASH_REMATCH[1]}"; loopfile=maintainer-loop.json
        elif [[ "$base" =~ ^s([0-9]+)-(review|maintain)-verdict-([0-9]+)\.md$ ]]; then
            step="${BASH_REMATCH[1]}"; action="${BASH_REMATCH[2]}"; iter="${BASH_REMATCH[3]}"
            loopfile="step-${step}-loop.json"
        else
            die "'$path' is not a valid verdict name"
        fi
        [[ -f "$path" ]] || die "'$path' is not a regular file"
        [[ -z "$want_action" || "$action" == "$want_action" ]] || continue
        if [[ "$require_loop" == 1 ]]; then
            resolve_run_file "$loopfile" >/dev/null || continue
        fi
        if [[ -z "$STEP_VERDICT_STEP" ]] || (( step > STEP_VERDICT_STEP )) \
                || { (( step == STEP_VERDICT_STEP )) && (( iter > STEP_VERDICT_ITER )); }; then
            STEP_VERDICT_STEP="$step"
            STEP_VERDICT_ACTION="$action"
            STEP_VERDICT_ITER="$iter"
            STEP_VERDICT_PATH="$path"
        fi
    done
    [[ -n "$STEP_VERDICT_PATH" ]]
}

print_report_marker() {
    local status label
    if ! best_verdict "" 0; then
        printf 'report: session\n'
        return
    fi
    status="$(head -n 1 -- "$STEP_VERDICT_PATH" | tr -d '\000-\037\177' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    label="$STEP_VERDICT_ACTION"
    [[ "$label" == maintain ]] && label=maintainer
    printf 'report: %s leg %s (%s)\n' "$label" "$STEP_VERDICT_ITER" "$status"
}

# A BLOCKED plan's text is the run's result: no code leg ran, so there is
# no events.jsonl to report from. A plan step is always step 1.
print_plan_report() {
    local loopfile ended
    resolve_run_file step-1-loop.json >/dev/null 2>&1 || return 1
    loopfile="$RUN_FILE_PATH"
    ended="$(jq -r '.ended // empty' -- "$loopfile" 2>/dev/null)"
    [[ "$ended" == "blocked" ]] || return 1
    resolve_run_file plan.md >/dev/null 2>&1 || return 1
    [[ -s "$RUN_FILE_PATH" ]] || return 1
    printf '== report: plan leg (BLOCKED) ==\n'
    cat -- "$RUN_FILE_PATH" | tr -d '\000-\010\013-\037\177'
    printf '\n'
}

print_review_report() {
    local verdict leg status
    best_verdict review 1 || return 1
    verdict="$STEP_VERDICT_PATH"
    leg="$STEP_VERDICT_ITER"
    status="$(head -n 1 -- "$verdict" | tr -d '\000-\037\177' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if fs_verdict_has_usable_report "$verdict"; then
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

# The maintainer's report, the review report's outer sibling: the best
# maintain-type step's last verdict, printed when that step's loop ran. Same
# shape and refusal discipline as the review one -- the file name comes only
# from a fixed pattern, never from an argument.
print_maintainer_report() {
    local verdict leg status
    best_verdict maintain 1 || return 1
    verdict="$STEP_VERDICT_PATH"
    leg="$STEP_VERDICT_ITER"
    status="$(head -n 1 -- "$verdict" | tr -d '\000-\037\177' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if fs_verdict_has_usable_report "$verdict"; then
        printf '== report: maintainer leg %s (%s) ==\n' "$leg" "$status"
        awk '/^## Report$/ { in_report=1; next } in_report { print }' "$verdict" \
            | tr -d '\000-\010\013-\037\177'
    else
        printf '== report: maintainer leg %s (%s) — verdict, no usable report section ==\n' \
            "$leg" "$status"
        cat -- "$verdict" | tr -d '\000-\010\013-\037\177'
    fi
    printf '\n'
}

# Preflight verdicts outside command substitutions so a refusal exits this
# process rather than only the subshell used to find the best one. Widened
# to the composed s<K>-(review|maintain)-verdict-<i>.md shape alongside the
# legacy names, so a composed run's verdicts get the same refusal before any
# read that the legacy ones always had.
for _verdict in "$run_dir"/review-verdict-*.md "$run_dir"/maintainer-verdict-*.md \
        "$run_dir"/s[0-9]*-*-verdict-*.md; do
    [[ -L "$_verdict" ]] && die "'$_verdict' is a symlink; refusing to read it"
    [[ -e "$_verdict" ]] || continue
    [[ "${_verdict##*/}" =~ ^review-verdict-[0-9]+\.md$ \
        || "${_verdict##*/}" =~ ^maintainer-verdict-[0-9]+\.md$ \
        || "${_verdict##*/}" =~ ^s[0-9]+-(review|maintain)-verdict-[0-9]+\.md$ ]] \
        || die "'$_verdict' is not a valid verdict name"
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
    local have=0 n=0 f d base
    if resolve_run_subdir inbox 2>/dev/null; then
        have=1
        for f in "$RUN_SUBDIR_PATH"/*.md; do
            [[ -f "$f" ]] || continue
            base="${f##*/}"
            # mail-banner-* is a postmaster mail notice (pm_deliver_live), not
            # an operator addendum -- counting it here would report live mail
            # deliveries as if the operator had sent them.
            [[ "$base" == mail-banner-* ]] && continue
            n=$(( n + 1 ))
        done
    fi
    if resolve_run_subdir inbox-delivered 2>/dev/null; then
        have=1
        for d in "$RUN_SUBDIR_PATH"/leg-*; do
            [[ -L "$d" || ! -d "$d" ]] && continue
            for f in "$d"/*.md; do
                [[ -f "$f" ]] || continue
                base="${f##*/}"
                [[ "$base" == mail-banner-* ]] && continue
                n=$(( n + 1 ))
            done
        done
    fi
    (( have )) || return 1
    printf '%s' "$n"
}

# The event log, once. Every reader goes through this, so the symlink refusal
# applies to all of them.
#
# A composed run whose step 1 is not code (a plan or review step first)
# leaves events.jsonl empty; its code legs log to per-step files, and the
# last of those carries the session's account.
have_events() {
    if resolve_run_file events.jsonl && [[ -s "$RUN_FILE_PATH" ]]; then
        return 0
    fi
    local -a all_code_files=("$run_dir"/events-s[0-9]*-code-*.jsonl) code_files=()
    local f
    for f in "${all_code_files[@]}"; do
        # A code leg's own continuation is tee'd into its base leg's file
        # already (fs_refresh_chain), so the base file holds the whole
        # chain and the continuation file is only its last slice. Excluding
        # it here keeps the base file, not its tail, picked below.
        [[ "$f" == *-continuation-*.jsonl ]] && continue
        code_files+=("$f")
    done
    local last
    if [[ -e "${code_files[0]}" ]]; then
        # Sorted without the extension so "-p2" orders after its base leg.
        last="$(printf '%s\n' "${code_files[@]##*/}" | sed 's/\.jsonl$//' \
            | sort -V | tail -n1).jsonl"
        if [[ "$last" =~ ^events-s[0-9]+-code-[0-9]+(-p[0-9]+)?\.jsonl$ ]] \
            && resolve_run_file "$last" && [[ -s "$RUN_FILE_PATH" ]]; then
            return 0
        fi
    fi
    resolve_run_file events.jsonl
}

# Every event file the run has written: the code leg's events.jsonl first, then
# one file per later leg, in leg-number order within each kind. Every name is
# resolved through resolve_run_file, so a leg file gets the same allowlist and
# the same symlink refusal as events.jsonl — no reader may bypass it. The
# answer comes back in EVENT_FILES rather than on stdout, for the same reason
# RUN_FILE_PATH exists: a die inside a command substitution would kill only
# the subshell and the caller would carry on.
EVENT_FILES=()
all_event_files() {
    EVENT_FILES=()
    local path name
    resolve_run_file events.jsonl 2>/dev/null && EVENT_FILES+=("$RUN_FILE_PATH")
    local -a candidates=() step_files=()
    candidates=("$run_dir"/events-{review,fix,maintainer,mntfix,code,continuation,tidy}-*.jsonl)
    # Step files go in numeric step order (s2 before s10), which a plain glob
    # does not give and latest_event_file's tie rule relies on.
    step_files=("$run_dir"/events-s[0-9]*-*.jsonl)
    if [[ -e "${step_files[0]}" ]]; then
        mapfile -t step_files < <(printf '%s\n' "${step_files[@]}" | sort -V)
        candidates+=("${step_files[@]}")
    fi
    for path in "${candidates[@]}"; do
        [[ -e "$path" ]] || continue
        name="${path##*/}"
        [[ "$name" =~ ^events-(review|fix|maintainer|mntfix|code|continuation|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ \
            || "$name" =~ ^events-s[0-9]+-(code|review|maintain|fix|plan|tidy)-[0-9]+(-p[0-9]+)?(-continuation-[0-9]+)?\.jsonl$ ]] \
            || die "'$name' is not a valid event file name"
        resolve_run_file "$name" || die "'$name' is not a readable event file"
        EVENT_FILES+=("$RUN_FILE_PATH")
    done
    (( ${#EVENT_FILES[@]} > 0 )) || return 1
}

# The newest event file by mtime is the active leg: the code leg stops writing
# events.jsonl when it ends, so that file's mtime no longer moves while a
# healthy multi-leg run goes on, and it is the one an operator wants. The mtime
# comes back in LATEST_EVENT_MTIME for the same reason as RUN_FILE_PATH.
LATEST_EVENT_FILE=""
LATEST_EVENT_MTIME=""
latest_event_file() {
    LATEST_EVENT_FILE=""
    LATEST_EVENT_MTIME=""
    all_event_files 2>/dev/null || return 1
    local f m
    for f in "${EVENT_FILES[@]}"; do
        m="$("$FS_STAT" -c %Y -- "$f" 2>/dev/null)"
        [[ "$m" =~ ^[0-9]+$ ]] || continue
        # A tie goes to the later file: events.jsonl is listed first, and a
        # run with no code leg leaves it empty.
        if [[ -z "$LATEST_EVENT_FILE" ]] || (( m >= LATEST_EVENT_MTIME )); then
            LATEST_EVENT_FILE="$f"
            LATEST_EVENT_MTIME="$m"
        fi
    done
    [[ -n "$LATEST_EVENT_FILE" ]]
}

# Which leg an event file belongs to: events.jsonl is the run's first leg
# (run.env's first_leg_kind; "code" for run dirs that predate the key),
# events-<kind>-<N>.jsonl is <kind>-<N> (a repeat pass's -p<P> stays in the
# name, so a fix round's second pass reads as fix-1-p2).
event_file_leg_name() {
    local base leg_kind
    base="${1##*/}"
    if [[ "$base" == "events.jsonl" ]]; then
        leg_kind="$(run_env_get first_leg_kind)"
        printf '%s' "${leg_kind:-code}"
    else
        base="${base#events-}"
        printf '%s' "${base%.jsonl}"
    fi
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
# Set only for a composed --k8s run (cmd_submit's one and only writer of
# this key) -- see run_state()'s own use of it for why "cluster" changes
# how a pid-less run dir is read.
network="$(run_env_get network)"
# Older runs recorded a tmux window instead of a session. Fall back to it so a
# run launched before that change still reports where it went. Empty for a
# composed --k8s run (network=cluster): it never starts a tmux session at
# all, so there is no window/session key to fall back to either -- see
# print_status_block's own use of network, below, for what prints instead.
tmux_target="$(run_env_get session)"
[[ -n "$tmux_target" ]] || tmux_target="$(run_env_get window)"
# cmd_submit's own writer, the cluster-side equivalent of a tmux session
# name: the Job/Pod label name, the one thing that actually exists for an
# operator to look at. Empty on a run.env written before this field
# existed.
k8s_job_name="$(run_env_get k8s_job_name)"

# Resolve every file this script may open, once, here at the top level, so a
# tampered run directory is rejected before anything is printed. A file the
# run has not written yet is fine and is checked again when it appears.
for _name in events.jsonl sandbox.log exit-code summary.txt summary.json pid tidy.json; do
    resolve_run_file "$_name" || true
done
# The same check for the leg event files, globbed instead of named: the
# runner only writes events-<kind>-<N>(-p<P>).jsonl for the legacy leg kinds
# above, or events-s<K>-<kind>-<N>(-p<P>).jsonl for a composed step, so a
# name in either shape that fails its pattern is not a run file, and any
# symlink is refused before anything is printed.
for _leg_events in "$run_dir"/events-{review,fix,maintainer,mntfix,code,continuation,tidy}-*.jsonl \
        "$run_dir"/events-s[0-9]*-*.jsonl; do
    [[ -e "$_leg_events" ]] || continue
    resolve_run_file "${_leg_events##*/}" || die "'$_leg_events' is not a readable event file"
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

# `kill -0` alone cannot tell a running process from a zombie one: POSIX
# leaves a zombie's pid allocated, not yet reaped by its parent, precisely
# so its exit status stays collectible -- so signal 0 against it still
# succeeds. The --resume contract rules that answer out explicitly:
# polling must not depend on the submitter's pid being alive, because the
# client's own PID 1 may not reap, and a finished submitter can linger as
# a zombie indefinitely. On Linux, /proc/<pid>/stat's third field is the
# single-letter process state, and 'Z' names exactly this case; comm
# (field 2) is parenthesized and can itself contain ") ", so the split
# anchors on the LAST ") " the same way fs_proc_start_time's own
# /proc/<pid>/stat read does. Without /proc (no Linux procfs), this can
# only fall back to kill -0's own answer.
fs_status_pid_alive() {
    local pid="$1" stat_line rest state
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -r "/proc/$pid/stat" ]] && stat_line="$(cat -- "/proc/$pid/stat" 2>/dev/null)" \
        && [[ -n "$stat_line" ]]; then
        rest="${stat_line##*) }"
        state="${rest%% *}"
        [[ "$state" == "Z" ]] && return 1
    fi
    return 0
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
        # Neither a composed nor a plain --k8s run ever gets a pid file:
        # the agent runs in a pod, not under this host's tmux, so there is
        # no local process to record one for. run.env instead carries
        # k8s_client_pid -- the host-side process watching the run through
        # to collect (fork-sandbox.sh's own launcher, pre-exec, for a
        # composed run; fork-sandbox-k8s.sh's cmd_run/cmd_resume,
        # k8s_record_client_pid, for a plain one), recorded under a key
        # fork-sandbox-stop.sh never reads, so it cannot be mistaken for a
        # killable local runner (see that key's own writers for why "pid"
        # would be unsafe here). network=cluster is this shape's only
        # tell -- a run dir that reaches this function at all already has
        # a version=, and the only writers of version= that ever omit a
        # pid file are these.
        if [[ "$network" == "cluster" ]]; then
            local k8s_pid
            k8s_pid="$(run_env_get k8s_client_pid)"
            k8s_pid="${k8s_pid//[^0-9]/}"
            if [[ -n "$k8s_pid" ]] && fs_status_pid_alive "$k8s_pid"; then
                printf 'running'
            elif [[ "$(run_env_get INPUTS_PUSH_EXPECTED)" == true \
                && "$(run_env_get INPUTS_PUSH_COMPLETE)" != true ]]; then
                # k8s_record_client_pid only runs once cmd_submit has
                # returned to cmd_run/cmd_resume, which is after
                # INPUTS_PUSH_COMPLETE is already written (see that
                # writer's own comment in fork-sandbox-k8s.sh) -- so a
                # submit still pushing the pod's inputs has no
                # k8s_client_pid yet even though it is very much alive, so
                # it reads "starting" (-> queued), not "abandoned", until
                # the push is far too old to still be in progress.
                local submitted_at
                submitted_at="$(run_env_get SUBMITTED_AT)"
                if [[ "$submitted_at" =~ ^[0-9]+$ ]] \
                    && (( $(date +%s) - submitted_at > 7200 )); then
                    printf 'abandoned'
                else
                    printf 'starting'
                fi
            else
                printf 'abandoned'
            fi
            return
        fi
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

# The --resume contract's own state vocabulary (queued|working|replied|failed),
# a mapping from run_state()'s starting|running|abandoned|done|failed, not a
# replacement for it: that vocabulary is this script's human-readable prose,
# this one is what a program polling --json compares against. abandoned has
# no good home in four states and is reported as failed -- the run never will
# reply, which is the fact a poller needs, not the distinction between "died"
# and "never going to finish" that abandoned draws for a human reader.
contract_state() {
    case "$(run_state)" in
        starting) printf 'queued' ;;
        running) printf 'working' ;;
        # exit-code lands before the fetch-back and reply.md. replied promises
        # both, so it waits for the process that writes them to exit.
        done)
            if run_finalizer_alive; then printf 'working'; else printf 'replied'; fi
            ;;
        abandoned|failed) printf 'failed' ;;
    esac
}

# The runner (local) or the k8s client (network=cluster): whichever process
# finishes the run after its exit-code is written.
run_finalizer_alive() {
    local p
    p="$(run_file_read pid 2>/dev/null)" || p=""
    p="${p//[^0-9]/}"
    if [[ -z "$p" && "$network" == "cluster" ]]; then
        p="$(run_env_get k8s_client_pid)"
        p="${p//[^0-9]/}"
    fi
    [[ -n "$p" ]] && fs_status_pid_alive "$p"
}

# end_reason: absent on every ordinary run (it ended on its own).
# 'fork-sandbox stop' is the only thing that ever produces stopped,
# stop-timeout, or salvaged, and the runner itself is the only thing that
# ever writes stopped into summary.json (a run it hands off gracefully).
# The stop verb's own forced/salvage completion deliberately does NOT
# fabricate a summary.json for stop-timeout/salvaged (a stub there would
# suppress sandbox-run-log.py record's no-summary fallback -- see that
# script's own comment) -- those two land only in the run log, keyed by
# this run dir's basename, so fall back to reading them back from there.
end_reason_value() {
    local json reason run_id
    json="$(run_file_read summary.json 2>/dev/null)"
    if [[ -n "$json" ]]; then
        reason="$(printf '%s' "$json" | jq -r '.end_reason // empty' 2>/dev/null)"
        [[ -n "$reason" ]] && { printf '%s' "$reason"; return; }
    fi
    run_id="$(basename "$run_dir")"
    "$script_dir/sandbox-run-log.py" show "$run_id" 2>/dev/null \
        | jq -r '.end_reason // empty' 2>/dev/null
}

# The refresh loop's continuation legs tee into events.jsonl (or, for a
# per-leg chain, into that leg's own events-<tag>.jsonl) AND their own
# events-continuation-N.jsonl / events-<tag>-continuation-N.jsonl file, so
# their events are already counted through the file they were teed into.
# Skipping the copy here keeps the total exact; counting both would double
# every continuation leg.
event_files_counted() {
    local f
    for f in "${EVENT_FILES[@]}"; do
        [[ "${f##*/}" == *-continuation-[0-9]*.jsonl ]] && continue
        printf '%s\n' "$f"
    done
}

# Summed across every leg: a run's activity keeps moving in the leg files
# after events.jsonl has gone quiet, so counting one file would report a
# healthy multi-leg run as frozen. (events-continuation-*.jsonl is a copy of
# an events.jsonl slice, not new events -- see event_files_counted.)
event_count() {
    all_event_files 2>/dev/null || { printf '0'; return; }
    local f total=0
    while IFS= read -r f; do
        total=$(( total + $(wc -l < "$f") ))
    done < <(event_files_counted)
    printf '%s' "$total"
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

# Summed across every leg, so a commit made by a fix leg is not invisible
# (and, as in event_count, the continuation legs' copy is skipped).
commit_count() {
    all_event_files 2>/dev/null || { printf '0'; return; }
    local f n total=0
    while IFS= read -r f; do
        n="$("$formatter" --commit-count "$f" 2>/dev/null)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        total=$(( total + n ))
    done < <(event_files_counted)
    printf '%s' "$total"
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
    if latest_event_file 2>/dev/null; then
        "$formatter" --tail 1 "$LATEST_EVENT_FILE" 2>/dev/null | tail -1
    fi
}

print_status_block() {
    local state
    state="$(run_state)"
    printf 'state:    %s' "$state"
    case "$state" in
        done|failed)
            printf ' (exit %s, after %s' "$(exit_code)" "$(elapsed_human)"
            case "$(end_reason_value)" in
                stopped)      printf ', stopped by operator' ;;
                stop-timeout) printf ', stop timeout kill' ;;
                salvaged)     printf ', salvaged after external kill' ;;
            esac
            printf ')'
            ;;
        *) printf ' (%s elapsed)' "$(elapsed_human)" ;;
    esac
    printf '\n'
    printf 'branch:   %s\n' "$branch"
    printf 'origin:   %s\n' "$origin_repo"
    printf 'clone:    %s\n' "$clone_dir"
    # A composed --k8s run (network=cluster) has no tmux session to name --
    # see tmux_target's own comment, above, for why -- so this prints the
    # cluster object an operator can actually look at instead of a session
    # that was never started. Nothing at all for a run.env written before
    # k8s_job_name existed: a made-up name would be no better than the
    # false tmux claim this replaces.
    if [[ "$network" == "cluster" ]]; then
        [[ -n "$k8s_job_name" ]] && printf 'job:      %s\n' "$k8s_job_name"
    else
        printf 'tmux:     %s\n' "$tmux_target"
    fi
    printf 'run dir:  %s\n' "$run_dir"
    printf 'commits:  %s\n' "$(commit_count_labelled)"
    printf 'events:   %s\n' "$(event_count)"
    # The line that tells a healthy multi-leg run from a wedge: when the code
    # leg ends, events.jsonl's mtime, the event count, the commit count and
    # the inbox all go quiet at once and read as a hang, while the next leg is
    # still moving. Which leg is active and how long since it moved is the
    # signal that does not go stale with the others. Nothing at all when the
    # run has written no event files yet.
    if latest_event_file 2>/dev/null; then
        age=$(( $(date +%s) - LATEST_EVENT_MTIME ))
        (( age < 0 )) && age=0
        printf 'activity: %s, last event %s ago\n' \
            "$(event_file_leg_name "$LATEST_EVENT_FILE")" \
            "$(human_duration "$age")"
    fi
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
        if [[ "$network" == "cluster" ]]; then
            printf '\nThe host-side k8s client is gone and it never wrote an exit code.\n'
            printf 'The pod may still be running. Collect it with:\n'
            printf '  fork-sandbox-k8s.sh collect --run-dir %s --branch %s %s\n' \
                "$run_dir" "$branch" "$origin_repo"
            printf 'or remove it with: fork-sandbox-k8s.sh rm --branch %s\n' "$branch"
        else
            printf '\nThe runner process is gone and it never wrote an exit code.\n'
            printf 'The tmux session was probably killed. Nothing was fetched.\n'
        fi
    fi
}

print_tail_of_log() {
    if resolve_run_file sandbox.log 2>/dev/null && [[ -s "$RUN_FILE_PATH" ]]; then
        printf '\n-- sandbox wrapper messages --\n'
        # sandbox.log is collect's own pull-back of a pod's wrapper
        # messages on a composed --k8s run -- bytes from the same
        # untrusted stranger the verdict readers above already strip
        # control characters from. A local run's own wrapper never writes
        # one either, so this costs nothing there.
        tail -n 20 -- "$RUN_FILE_PATH" | tr -d '\000-\010\013-\037\177'
    fi
}

# In terminal-only mode the notable stream is suppressed for the whole
# watch, and that stream is the only other place a final result event is
# printed. Flush it at the terminal state so the output carries the
# session's own account, exactly as --monitor's does.
# $1 is the event-file count. events.jsonl holds only the code leg, so on a
# multi-leg run its result event is not the run's outcome and must say so.
# A BLOCKED plan has no code leg, so its text is the account instead.
flush_result_if_terminal_only() {
    local out
    (( terminal_only )) || return 0
    print_plan_report && return 0
    have_events || return 0
    out="$("$formatter" --result "$RUN_FILE_PATH")"
    [[ -n "$out" ]] || return 0
    if (( ${1:-1} > 1 )); then
        printf "(the code leg's own account; later legs' verdicts follow)\n"
    fi
    printf '%s\n' "$out"
}

# Counted outside the command substitution that buffers the terminal block:
# all_event_files can die, and a die in a subshell would truncate the block
# instead of stopping the script.
count_event_files() {
    EVENT_FILE_COUNT=0
    all_event_files 2>/dev/null && EVENT_FILE_COUNT=${#EVENT_FILES[@]}
    return 0
}

case "$mode" in
    result)
        # A BLOCKED plan ran no code leg, so its text replaces the fallback.
        if ! print_plan_report; then
            report_printed=false
            if print_maintainer_report; then
                report_printed=true
            fi
            if print_review_report; then
                report_printed=true
            fi
            if $report_printed; then
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
                        # A leg that died on a provider error (spend cap, revoked
                        # token) wrote no result, and summary.json carries the
                        # cause; say that instead of the generic account.
                        herr=""
                        if herr_json="$(run_file_read summary.json 2>/dev/null)"; then
                            herr="$(printf '%s' "$herr_json" \
                                | jq -r '.harness_error // empty' 2>/dev/null \
                                | tr -d '\000-\037\177')"
                        fi
                        if [[ -n "$herr" ]]; then
                            printf 'The session failed on a harness error: %s\n' "$herr"
                        else
                            printf 'The session wrote no result. It ended as "%s" after %s,\n' \
                                "$state" "$(elapsed_human)"
                            printf 'so it never finished its turn.\n'
                        fi
                        print_tail_of_log
                        ;;
                esac
            fi
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
        # ends, now augmented with two keys a program driving a run through
        # --resume (or any other --k8s or local run) can poll on without a
        # separate summary.json existence check: `state`
        # (queued|working|replied|failed -- see contract_state) and
        # `reply_file`, the path a finished run's agent reply or fallback
        # account lands at (see the local runner's and cmd_collect's write).
        # A run with no summary.json yet (still going, or dead before the
        # fetch) gets a state-only stand-in. Every key summary.json carries
        # is passed through untouched; this only ever adds.
        #
        # summary.json is written before the Kubernetes collector tears
        # down the run's cluster objects. Keep a live cluster finalizer in
        # "working" until it exits. A local --keep-session runner instead
        # execs an interactive shell after writing its summary, retaining
        # the same pid indefinitely. The summary's exit_code decides success.
        reply_file_path="$run_dir/outbox/reply.md"
        if summary_json="$(run_file_read summary.json 2>/dev/null)"; then
            finalizer_active=false
            if [[ "$network" == "cluster" ]] && run_finalizer_alive; then
                finalizer_active=true
            fi
            printf '%s' "$summary_json" | jq --arg reply_file "$reply_file_path" \
                --argjson finalizer_active "$finalizer_active" \
                '. + {state: (if $finalizer_active then "working"
                              elif (.exit_code | type) != "number" then "failed"
                              elif .exit_code == 0 then "replied"
                              else "failed" end),
                      reply_file: $reply_file}'
        else
            jq -n --arg state "$(contract_state)" --arg branch "$branch" \
                --arg reply_file "$reply_file_path" \
                '{state: $state, branch: $branch, reply_file: $reply_file}'
        fi
        ;;

    fleet-member)
        # run_fleet_json's own per-dir child (see FS_STATUS_FLEET_MEMBER
        # above). Reached only after every preflight check above this case
        # statement already passed for this run dir -- run.env exists and
        # is readable, the symlink refusals cleared -- so this always
        # exits 0. Unlike bare --json, a missing summary.json is not fatal
        # here: it prints a state-only stand-in instead, so a run still in
        # flight is a normal member of the fleet, not a failure.
        fleet_rid="$(basename -- "$run_dir")"
        if fleet_summary="$(run_file_read summary.json 2>/dev/null)"; then
            printf '%s' "$fleet_summary" | jq --arg rid "$fleet_rid" \
                '. + {run_id: $rid, summary: true,
                      state: (if (.exit_code | type) != "number" then "unknown"
                              elif .exit_code == 0 then "done"
                              else "failed" end)}'
        else
            fleet_model="$(run_env_get model)"
            jq -n --arg rid "$fleet_rid" --arg state "$(run_state)" --arg branch "$branch" \
                --arg harness "$(run_env_get harness)" --arg model "$fleet_model" \
                '{run_id: $rid, state: $state, branch: $branch, harness: $harness,
                  model: (if $model == "" then null else $model end), summary: false}'
        fi
        ;;

    log)
        # Resolved (and so symlink/non-regular-file refused) as a bare
        # call, not piped: a `resolve_run_file` refusal calls `die`, which
        # must stop this whole process, not just a forked pipeline stage
        # the way piping `run_file_read` itself would. Only the actual
        # read goes through `tr` -- sandbox.log is collect's own pull-back
        # on a composed --k8s run, the same untrusted-stranger bytes the
        # verdict readers already strip control characters from.
        if resolve_run_file sandbox.log; then
            cat -- "$RUN_FILE_PATH" | tr -d '\000-\010\013-\037\177'
        else
            echo "(no sandbox log yet)"
        fi
        ;;

    status)
        print_status_block
        state="$(run_state)"
        if [[ "$state" == "done" || "$state" == "failed" ]]; then
            # summary.txt is collect's own pull-back on a composed --k8s
            # run -- the same untrusted-stranger bytes the verdict readers
            # above already strip control characters from.
            if summary="$(run_file_read summary.txt 2>/dev/null | tr -d '\000-\010\013-\037\177')"; then
                printf '\n%s\n' "$summary"
            fi
            if ! print_plan_report; then
                report_printed=false
                if print_maintainer_report; then
                    report_printed=true
                fi
                if print_review_report; then
                    report_printed=true
                fi
                if $report_printed; then
                    printf '== the session'"'"'s own account ==\n'
                fi
                if have_events 2>/dev/null; then
                    printf '\n'
                    "$formatter" --result "$RUN_FILE_PATH"
                fi
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
        # here; the loop below reports it in its first pass. In terminal-only
        # mode this line is skipped: the Monitor tool already confirms
        # arming, and silence is the expected steady state there, so the
        # anti-looks-dead rationale does not apply.
        state="$(run_state)"
        if [[ "$state" == "starting" || "$state" == "running" ]] && (( ! terminal_only )); then
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

            # The mid-run stream is noise in terminal-only mode; nothing
            # else reads offset, so the whole block is skipped there.
            if (( ! terminal_only )) && have_events; then
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
                    # while for the summary the fetch produces -- before
                    # printing anything, and then print the block in one
                    # write: the Monitor tool turns each burst of output into
                    # its own notification.
                    waited=0
                    while [[ ! -f "$run_dir/summary.txt" ]] && (( waited < 120 )); do
                        sleep 2
                        waited=$(( waited + 2 ))
                    done
                    count_event_files
                    block="$(
                        flush_result_if_terminal_only "$EVENT_FILE_COUNT"
                        printf 'finished: %s, exit %s, after %s\n' \
                            "$state" "$(exit_code)" "$(elapsed_human)"
                        if summary="$(run_file_read summary.txt 2>/dev/null | tr -d '\000-\010\013-\037\177')"; then
                            printf '%s\n' "$summary"
                        else
                            printf 'No summary was written, so the branch was probably never fetched.\n'
                            print_tail_of_log
                        fi
                        if [[ "$mode" == "monitor" ]]; then
                            print_report_marker
                        fi
                    )"
                    printf '%s\n' "$block"
                    exit 0
                    ;;
                abandoned)
                    count_event_files
                    block="$(
                        flush_result_if_terminal_only "$EVENT_FILE_COUNT"
                        printf 'abandoned: the runner is gone and wrote no exit code, after %s\n' \
                            "$(elapsed_human)"
                        if [[ "$network" == "cluster" ]]; then
                            printf 'The host-side k8s client is gone. The pod may still be running.\n'
                            printf 'Collect it with: fork-sandbox-k8s.sh collect --run-dir %s --branch %s %s\n' \
                                "$run_dir" "$branch" "$origin_repo"
                            printf 'or remove it with: fork-sandbox-k8s.sh rm --branch %s\n' "$branch"
                        else
                            printf 'Nothing was fetched. The clone is still at %s\n' "$clone_dir"
                        fi
                        print_tail_of_log
                    )"
                    printf '%s\n' "$block"
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
            if [[ "$mode" == "monitor" ]] && (( ! terminal_only )) \
                    && (( now - last_beat >= HEARTBEAT_SECONDS )); then
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
