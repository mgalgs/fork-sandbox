#!/usr/bin/env bash
# fork-sandbox-resume-test.sh — session-per-thread resume: --session-state
# and --resume-session, end to end through the two launchers
#
# Usage: tests/fork-sandbox-resume-test.sh
#
# An agent woken repeatedly on one mail thread should be ONE continuing
# claude conversation. The mechanism is two flags: --session-state binds a
# host directory at the sandbox HOME's ~/.claude/projects, so the claude
# CLI's transcript store outlives the run, and --resume-session makes the
# next run resume a session out of it. Resume is a continuity and cost
# optimization only -- a wake whose resume state is missing or broken must
# still work as a fresh session -- so as much of this suite is about the
# refusals and the fallback as about the happy path.
#
# Three seams, each borrowed from a suite that already uses it:
#
#   - fork-sandbox.sh's own refusals and --dry-run, run directly. No stub
#     needed: --dry-run exits before anything is created.
#   - what fork-sandbox.sh hands to claude-sandboxed: a stub
#     claude-sandboxed on PATH that records its argv, as
#     tests/fork-sandbox-review-kit-bind-test.sh does.
#   - what claude-sandboxed hands to the BACKEND, and what it hands to
#     claude: FORK_SANDBOX_BACKEND=test plus a stub sandbox-backend-test,
#     as tests/agent-sandboxed-ctx-test.sh does. The stub backend execs the
#     words after '--', so a stub claude on PATH sees the real invocation.
#
# No real sandbox is ever built and no real claude is ever run.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work. Mark it so
# sandbox-run-log.py's list/stats exclude it by default.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
        # The per-call argv files and the call counter the stub writes
        # beside a registered argv file ("<file>.1", "<file>.count").
        rm -f -- "$d".[0-9]* "$d".count 2>/dev/null
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

# Checks that argv (one token per line in FILE) contains FLAG immediately
# followed by VALUE -- exactly how every flag pair in these argvs is built.
argv_has_flag_value() {
    local file="$1" flag="$2" value="$3"
    awk -v f="$flag" -v v="$value" '
        pending { if ($0 == v) found = 1; pending = 0 }
        $0 == f { pending = 1 }
        END { exit !found }
    ' "$file"
}

argv_has_word() {
    grep -qxF -- "$2" "$1"
}

scratch="/var/tmp/claude-scratch"
mkdir -p "$scratch/forks"

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

# ---------------------------------------------------------------------------
printf '== fork-sandbox.sh: the refusals ==\n'
# ---------------------------------------------------------------------------

# A handoff has to live in the scratch root, and a project under ~/src, or
# the launcher refuses for those reasons instead of the ones under test.
refusal_handoff_dir="$(mktmp_dir "$scratch/fs-resume-ho.XXXXXX")"
refusal_handoff="$refusal_handoff_dir/handoff.md"
printf 'do the task\n' > "$refusal_handoff"

new_project() {
    local home="$1" d
    mkdir -p "$home/src"
    d="$(mktemp -d "$home/src/fs-resume-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

refusal_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
refusal_proj="$(new_project "$refusal_home")"
refusal_cfg="$(mktmp_dir "$scratch/fs-resume-cfg.XXXXXX")"

# Runs the launcher with --dry-run (so nothing is created) and prints its
# combined output; the exit status is the launcher's.
dry_run() {
    HOME="$refusal_home" FORK_SANDBOX_CONFIG_DIR="$refusal_cfg" \
        timeout 60 "$launcher" --dry-run --branch fs-resume-test "$@" \
        "$refusal_proj" "$refusal_handoff" 2>&1
}

# Asserts the launcher refused, and that its message names the constraint.
refuses() {
    local label="$1" needle="$2"; shift 2
    local out rc
    out="$(dry_run "$@")"; rc=$?
    if (( rc == 0 )); then
        no "$label" "accepted; expected a refusal"
    elif ! printf '%s' "$out" | grep -qF -- "$needle"; then
        no "$label" "refused with the wrong message: $out"
    else
        ok "$label"
    fi
}

# pi and codex are resumable too now (fs_harness_session_caps), so
# --session-state is accepted on both -- only a harness with no
# session-resume capability at all would be refused here, and every harness
# --harness itself accepts (claude/pi/codex) has one, so that refusal path
# is exercised at the fs_harness_session_caps unit level
# (fork-sandbox-harness-session-caps-test.sh), not reachable through this
# CLI's own --harness flag.
pi_state_out="$(dry_run --harness pi --model vendor/model --session-state "$scratch/fs-resume-unused")"
pi_state_rc=$?
if (( pi_state_rc == 0 )) && printf '%s\n' "$pi_state_out" \
    | grep -q '^session_state='; then
    ok "--session-state accepted on --harness pi"
else
    no "--session-state accepted on --harness pi" "$pi_state_out"
fi
codex_state_out="$(dry_run --harness codex --session-state "$scratch/fs-resume-unused")"
codex_state_rc=$?
if (( codex_state_rc == 0 )) && printf '%s\n' "$codex_state_out" \
    | grep -q '^session_state='; then
    ok "--session-state accepted on --harness codex"
else
    no "--session-state accepted on --harness codex" "$codex_state_out"
fi
refuses "--session-state refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --session-state "$scratch/fs-resume-unused"
refuses "--resume-session refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--resume-session refused without --session-state" \
    "requires --session-state" --harness claude \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--session-id refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--session-id refused without --session-state" \
    "requires --session-state" --harness pi --model vendor/model \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--session-id refused on a discover-mode harness (claude)" \
    "with nothing to" --harness claude \
    --session-state "$scratch/fs-resume-unused" \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--session-id refused on a discover-mode harness (codex)" \
    "with nothing to" --harness codex \
    --session-state "$scratch/fs-resume-unused" \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--resume-session refused on a given-mode harness (pi)" \
    "does not do" --harness pi --model vendor/model \
    --session-state "$scratch/fs-resume-unused" \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab

# A sealed pi run dispatches through agent-sandboxed, not a direct pi exec,
# and agent-sandboxed has no --session-dir/--session-id wiring at all -- so
# these three flags are refused there even though plain --harness pi (no
# --network sealed) has the capability. Both spellings of a sealed pi seat
# (the explicit pair and the pi-local alias) are refused the same way.
refuses "--session-state refused with --harness pi --network sealed" \
    "supported with --harness pi --network sealed" \
    --harness pi --network sealed \
    --session-state "$scratch/fs-resume-unused"
refuses "--session-state refused with --harness pi-local" \
    "supported with --harness pi-local" \
    --harness pi-local --session-state "$scratch/fs-resume-unused"
refuses "--session-id refused with --harness pi --network sealed" \
    "supported with --harness pi --network sealed" \
    --harness pi --network sealed \
    --session-state "$scratch/fs-resume-unused" \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab

# The id is used as a transcript filename stem, so path characters and
# anything outside [0-9a-f-] must not survive to the claude command line. A
# leading hyphen is refused too: it would make the id flag-shaped, so a
# caller building one by hand could hand the claude CLI an option instead of
# a session id.
for bad in "../etc/passwd" "a/b" "abcdef12.jsonl" "ABCDEF1234" "short" \
           "-abcdef12" "-" \
           "$(printf 'a%.0s' {1..65})"; do
    refuses "bad session id refused: '$bad'" "is not a session id" \
        --harness claude --session-state "$scratch/fs-resume-unused" \
        --resume-session "$bad"
    refuses "bad --session-id refused: '$bad'" "is not a session id" \
        --harness pi --model vendor/model --session-state "$scratch/fs-resume-unused" \
        --session-id "$bad"
done

# A symlink checked here and resolved later is a different directory from
# the one that gets a writable bind, so it is refused rather than followed.
symlink_target="$(mktmp_dir "$scratch/fs-resume-linktarget.XXXXXX")"
symlink_state="$scratch/fs-resume-link.$$"
ln -sfn "$symlink_target" "$symlink_state"
tmpdirs+=("$symlink_state")
refuses "--session-state refused when it is a symlink" "is a symlink" \
    --harness claude --session-state "$symlink_state"

outside_dir="$(mktemp -d)"
tmpdirs+=("$outside_dir")
refuses "--session-state refused outside the scratch root" \
    "/var/tmp/claude-scratch/" \
    --harness claude --session-state "$outside_dir/elsewhere"
# ... including by way of a parent that resolves out of it: realpath -m
# resolves the whole path, not only the last component.
refuses "--session-state refused when a parent symlink leads out" \
    "/var/tmp/claude-scratch/" \
    --harness claude --session-state "$scratch/../../etc/fs-resume"

# Both spellings of the scratch root are accepted, exactly as a handoff path
# is (fs_require_scratch_handoff): on a host where /tmp/claude-scratch is a
# real directory rather than the compat symlink -- which ensure-scratch-dirs.sh
# leaves alone on purpose -- realpath cannot fold it into /var/tmp, and a
# narrower rule here would refuse a mail root the postmaster's own startup
# validation had already accepted, wedging every claude wake in the fleet.
tmp_root_out="$(dry_run --harness claude \
    --session-state /tmp/claude-scratch/fs-resume-tmp-root/state)"
tmp_root_rc=$?
if (( tmp_root_rc == 0 )) && printf '%s\n' "$tmp_root_out" \
    | grep -q '^session_state='; then
    ok "--session-state accepts a /tmp/claude-scratch path"
else
    no "--session-state accepts a /tmp/claude-scratch path" "$tmp_root_out"
fi

printf '\n== fork-sandbox.sh: --dry-run prints both flags resolved ==\n'

dry_state="$scratch/fs-resume-dry.$$/state"
dry_out="$(dry_run --harness claude --session-state "$dry_state" \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab)"
if printf '%s\n' "$dry_out" | grep -qx "session_state=$dry_state"; then
    ok "--dry-run prints the resolved session_state"
else
    no "--dry-run prints the resolved session_state" "$dry_out"
fi
if printf '%s\n' "$dry_out" \
    | grep -qx 'resume_session=0123abcd-4567-89ab-cdef-0123456789ab'; then
    ok "--dry-run prints resume_session"
else
    no "--dry-run prints resume_session" "$dry_out"
fi
if [[ -e "$scratch/fs-resume-dry.$$" ]]; then
    no "--dry-run creates no state directory" "it created $dry_state"
    rm -rf "$scratch/fs-resume-dry.$$"
else
    ok "--dry-run creates no state directory"
fi

dry_pi_state="$scratch/fs-resume-dry-pi.$$/state"
dry_pi_out="$(dry_run --harness pi --model vendor/model --session-state "$dry_pi_state" \
    --session-id 0123abcd-4567-89ab-cdef-0123456789ab)"
if printf '%s\n' "$dry_pi_out" \
    | grep -qx 'session_id=0123abcd-4567-89ab-cdef-0123456789ab'; then
    ok "--dry-run prints session_id"
else
    no "--dry-run prints session_id" "$dry_pi_out"
fi
[[ -e "$scratch/fs-resume-dry-pi.$$" ]] && rm -rf "$scratch/fs-resume-dry-pi.$$"

# A run with neither flag must print neither key, so a caller parsing the
# dry run can tell "not requested" from "requested and empty".
dry_out_plain="$(dry_run --harness claude)"
if printf '%s\n' "$dry_out_plain" | grep -q '^session_state='; then
    no "--dry-run omits session_state when the flag is absent" "$dry_out_plain"
else
    ok "--dry-run omits session_state when the flag is absent"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh -> claude-sandboxed: the flags flow through ==\n'
# ---------------------------------------------------------------------------

stub_bin="$(mktmp_dir "$scratch/fs-resume-stub.XXXXXX")"
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses the backend entirely. It drains the prompt
# from stdin (never read) and records the argv it was handed, then exits 0.
cat >/dev/null
# A caller that only cares about run.sh (grepped straight out of the run
# dir, e.g. the pi --session-state cases below) never sets FAKE_ARGV_FILE at
# all; without this guard, every write below still resolves to a path
# (bash does not error on ">> empty-string", and ".count"/".$call_n" resolve
# to plain relative names) and litters the CURRENT DIRECTORY with stray
# dot-files instead of doing nothing.
if [[ -n "${FAKE_ARGV_FILE:-}" ]]; then
    printf '%s\n' "$@" >> "$FAKE_ARGV_FILE"
    printf -- '--- end of argv ---\n' >> "$FAKE_ARGV_FILE"
    # ...and once more per invocation, in its own file, so a multi-leg run can
    # be asserted on leg by leg: "$FAKE_ARGV_FILE.1" is the implement leg,
    # ".2" the leg after it, and so on.
    call_n=$(( $(cat "$FAKE_ARGV_FILE.count" 2>/dev/null || printf 0) + 1 ))
    printf '%s\n' "$call_n" > "$FAKE_ARGV_FILE.count"
    printf '%s\n' "$@" > "$FAKE_ARGV_FILE.$call_n"
fi
# The work dir is the argument before claude's own first flag, and the outbox
# is the --bind-rw whose basename says so. Both are read off the argv rather
# than passed in, so this stub cannot disagree with the launcher about them.
stub_clone=""
stub_outbox=""
stub_prev=""
for a in "$@"; do
    [[ "$a" == --dangerously-skip-permissions ]] && stub_clone="$stub_prev"
    [[ "$stub_prev" == --bind-rw && "${a##*/}" == outbox ]] && stub_outbox="$a"
    stub_prev="$a"
done
# FAKE_HANDOFF_ON_CALL=N: write an outbox hand-off on the Nth invocation, so
# the launcher's --refresh-at loop runs exactly one continuation leg.
if [[ "${FAKE_HANDOFF_ON_CALL:-}" == "$call_n" && -n "$stub_outbox" ]]; then
    printf 'done some of it; the rest is left\n' > "$stub_outbox/handoff.md"
fi
# FAKE_COMMIT_ON_CALL=N: commit in the clone on the Nth invocation. The
# review loop refuses to start on a branch whose head still equals the base,
# so a review leg only ever runs if a coding leg committed something.
if [[ "${FAKE_COMMIT_ON_CALL:-}" == "$call_n" && -n "$stub_clone" ]]; then
    git -C "$stub_clone" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        commit -q --allow-empty -m 'stub work' >/dev/null 2>&1
fi
# Stand in for the claude CLI's transcript store when the caller asks for
# one: FAKE_TRANSCRIPTS is "<stem>@<mtime> ..." and each becomes a .jsonl
# under a per-project directory of the bound state dir, exactly where the
# real CLI files them. Fixed mtimes, so "newest" is not a race.
if [[ -n "${FAKE_TRANSCRIPTS:-}" ]]; then
    state=""
    prev=""
    for a in "$@"; do
        [[ "$prev" == --session-state ]] && state="$a"
        prev="$a"
    done
    if [[ -n "$state" ]]; then
        mkdir -p "$state/-home-agent-project"
        for spec in $FAKE_TRANSCRIPTS; do
            printf '{}\n' > "$state/-home-agent-project/${spec%%@*}.jsonl"
            touch -d "@${spec##*@}" "$state/-home-agent-project/${spec%%@*}.jsonl"
        done
    fi
fi
# Stand in for pi's own append-only session file across resumed wakes:
# FAKE_PI_APPEND_FILE names a file (a host path -- the --session-state
# directory itself, since this stub never runs inside a real bind) to
# append FAKE_PI_APPEND_LINE to, simulating a resumed pi CLI adding this
# wake's own turn on top of whatever an earlier wake already left there.
if [[ -n "${FAKE_PI_APPEND_FILE:-}" && -n "${FAKE_PI_APPEND_LINE:-}" ]]; then
    printf '%s\n' "$FAKE_PI_APPEND_LINE" >> "$FAKE_PI_APPEND_FILE"
fi
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# Runs the launcher for real, in the foreground, against a fixture $HOME and
# a given project, and prints "argv-file<newline>run-dir" for the CALLER to
# register -- this body runs inside the caller's command substitution, so a
# tmpdirs+= here would never reach the trap. Takes the project explicitly (as
# opposed to run_and_capture_argv, below, which makes a fresh one per call)
# so a caller can drive --clone-dir reuse against a fixed origin_repo across
# more than one wake.
run_and_capture_argv_at() {
    local home="$1" proj="$2"; shift 2
    local handoff_dir handoff argv_file cfg out rc rd
    handoff_dir="$(mktemp -d "$scratch/fs-resume-ho.XXXXXX")"
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    argv_file="$(mktemp "$scratch/fs-resume-argv.XXXXXX")"
    cfg="$(mktemp -d)"
    out="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FAKE_ARGV_FILE="$argv_file" \
        timeout 120 "$launcher" --foreground --harness claude "$@" \
        "$proj" "$handoff" 2>&1)"
    rc=$?
    rd=""
    if (( rc != 0 )); then
        printf 'run failed (rc=%s):\n%s\n' "$rc" "$out" >&2
    else
        rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    fi
    printf '%s\n%s\n%s\n%s\n' "$argv_file" "$handoff_dir" "$cfg" "$rd"
    (( rc == 0 ))
}

# Same, but makes its own fresh project rather than taking one from the
# caller -- the common case, everywhere a test does not need the project
# held fixed across repeated calls (see run_and_capture_argv_at above).
run_and_capture_argv() {
    local home="$1"; shift
    run_and_capture_argv_at "$home" "$(new_project "$home")" "$@"
}

register_run_paths() {
    local result="$1"
    local -a fields
    mapfile -t fields <<<"$result"
    REGISTERED_ARGV_FILE="${fields[0]:-}"
    REGISTERED_RUN_DIR="${fields[3]:-}"
    local f
    for f in "${fields[@]}"; do
        [[ -n "$f" ]] && tmpdirs+=("$f")
    done
}

flow_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
flow_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
flow_sid=0123abcd-4567-89ab-cdef-0123456789ab
flow_result="$(run_and_capture_argv "$flow_home" \
    --session-state "$flow_state" --resume-session "$flow_sid")"
flow_rc=$?
register_run_paths "$flow_result"
flow_argv="$REGISTERED_ARGV_FILE"
flow_run_dir="$REGISTERED_RUN_DIR"

if (( flow_rc != 0 )); then
    no "the launcher completed with --session-state" "run failed"
else
    if argv_has_flag_value "$flow_argv" --session-state "$flow_state"; then
        ok "claude-sandboxed is handed --session-state <dir>"
    else
        no "claude-sandboxed is handed --session-state <dir>" "$(cat "$flow_argv")"
    fi
    if argv_has_flag_value "$flow_argv" --resume-session "$flow_sid"; then
        ok "claude-sandboxed is handed --resume-session <id>"
    else
        no "claude-sandboxed is handed --resume-session <id>" "$(cat "$flow_argv")"
    fi
    # claude-sandboxed stops parsing its own flags at the first argument
    # starting with '-' or at the work dir, so both must precede the clone.
    if awk '/^--session-state$/ { seen = 1 }
            /^--dangerously-skip-permissions$/ { exit !seen }
            END { exit !seen }' "$flow_argv"; then
        ok "the flags precede the claude arguments in the argv"
    else
        no "the flags precede the claude arguments in the argv" "$(cat "$flow_argv")"
    fi
    # The launcher creates it; the postmaster should not have to.
    if [[ -d "$flow_state" ]]; then
        ok "the state directory exists after the run"
    else
        no "the state directory exists after the run" "missing: $flow_state"
    fi
fi

# Whole conversations land in the store, so the ambient umask does not get to
# decide who can read them -- the same 0700 the codex sessions directory gets.
# The directory must be one the LAUNCHER creates (mktemp -d makes 0700 by
# itself, which would pass without the chmod), under a umask that would
# otherwise publish it.
mode_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
mode_parent="$scratch/fs-resume-mode.$$"
tmpdirs+=("$mode_parent")
mode_umask="$(umask)"
umask 022
mode_result="$(run_and_capture_argv "$mode_home" \
    --session-state "$mode_parent/state")"
mode_rc=$?
umask "$mode_umask"
register_run_paths "$mode_result"
if (( mode_rc != 0 )); then
    no "the state directory is created mode 700 under umask 022" "run failed"
else
    mode_bits="$(stat -c '%a' "$mode_parent/state" 2>/dev/null)"
    if [[ "$mode_bits" == 700 ]]; then
        ok "the state directory is created mode 700 under umask 022"
    else
        no "the state directory is created mode 700 under umask 022" \
            "mode is '$mode_bits'"
    fi
fi

# Without --resume-session, neither flag appears at all: a run that was
# never asked to persist anything must be byte-identical to one built
# before the flags existed.
plain_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
plain_result="$(run_and_capture_argv "$plain_home")"
plain_rc=$?
register_run_paths "$plain_result"
plain_argv="$REGISTERED_ARGV_FILE"
plain_run_dir="$REGISTERED_RUN_DIR"
if (( plain_rc != 0 )); then
    no "a run with no --session-state passes neither flag" "run failed"
else
    if argv_has_word "$plain_argv" --session-state \
        || argv_has_word "$plain_argv" --resume-session; then
        no "a run with no --session-state passes neither flag" "$(cat "$plain_argv")"
    else
        ok "a run with no --session-state passes neither flag"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n== a resumed wake is told what did not carry over ==\n'
# ---------------------------------------------------------------------------

# The transcript is the only thing that crosses between wakes. The clone, the
# inbox, the outbox and the branch are all new, and commits the resumed
# conversation remembers making are not reachable from this HEAD -- so the
# coding leg's prompt has to say so, or the session reasons from a sandbox
# that no longer exists.
cont_marker='## This session is a continuation'

if [[ -z "$flow_run_dir" || ! -f "$flow_run_dir/handoff.md" ]]; then
    no "the resumed leg's prompt carries the continuation section" \
        "no handoff.md for the resumed run"
else
    if grep -qF -- "$cont_marker" "$flow_run_dir/handoff.md"; then
        ok "the resumed leg's prompt carries the continuation section"
    else
        no "the resumed leg's prompt carries the continuation section" \
            "$cont_marker not in $flow_run_dir/handoff.md"
    fi
    # The three things it must name concretely: this run's branch, the fact
    # that earlier commits are not reachable, and where they are instead.
    flow_branch="$(jq -r '.branch // ""' "$flow_run_dir/summary.json" 2>/dev/null)"
    if [[ -n "$flow_branch" ]] \
        && grep -qF -- "The branch is \`$flow_branch\`" "$flow_run_dir/handoff.md"; then
        ok "the continuation section names this run's own branch"
    else
        no "the continuation section names this run's own branch" \
            "branch '$flow_branch' not named"
    fi
    if grep -qF -- 'not reachable from HEAD here' "$flow_run_dir/handoff.md" \
        && grep -qF -- 'git branch -r' "$flow_run_dir/handoff.md"; then
        ok "it says earlier commits are unreachable, and where to find them"
    else
        no "it says earlier commits are unreachable, and where to find them" \
            "$(cat "$flow_run_dir/handoff.md")"
    fi
    # The hand-off the caller passed in is still there, verbatim and last.
    if grep -qF -- 'do the task' "$flow_run_dir/handoff.md"; then
        ok "the caller's hand-off survives beside the continuation section"
    else
        no "the caller's hand-off survives beside the continuation section" \
            "$(cat "$flow_run_dir/handoff.md")"
    fi
fi

# A run that resumes nothing has nothing stale to correct, and must not be
# told it is a continuation of a conversation it never had.
if [[ -z "$plain_run_dir" || ! -f "$plain_run_dir/handoff.md" ]]; then
    no "a fresh run's prompt has no continuation section" \
        "no handoff.md for the plain run"
elif grep -qF -- "$cont_marker" "$plain_run_dir/handoff.md"; then
    no "a fresh run's prompt has no continuation section" \
        "$(cat "$plain_run_dir/handoff.md")"
else
    ok "a fresh run's prompt has no continuation section"
fi

# ---------------------------------------------------------------------------
printf '\n== a resumed wake in a reused --clone-dir workspace is told differently ==\n'
# ---------------------------------------------------------------------------

# The "told what did not carry over" section above only proves the text for
# clone_reused=false (no --clone-dir was ever passed in this file until now).
# fork-sandbox.sh's continuation-prompt generator has two more branches,
# gated on clone_reused as well as resume_session: when --clone-dir is reused,
# the clone/branch are NOT all new, so the "not reachable from HEAD here,
# check git branch -r" text above would be actively wrong -- the generator
# says something different instead. Exercise those branches for real, the
# same way tests/fork-sandbox-clone-dir-test.sh drives a real two-wake
# --clone-dir reuse (that file already covers the clone_reused-but-no-
# resume-session branch; this covers the two where resume_session is set
# too, which only this suite's flags can reach).

# run_and_capture_argv_at (defined above, near run_and_capture_argv) takes
# the project explicitly for exactly this: driving --clone-dir reuse against
# a fixed origin_repo across more than one wake.

reuse_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
reuse_proj="$(new_project "$reuse_home")"
reuse_clone="$scratch/fs-resume-ws.$$"
tmpdirs+=("$reuse_clone")
reuse_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
reuse_sid=89abcdef-0123-4567-89ab-cdef01234567

# Wake 1: just establishes the workspace (clone_reused=false on this call).
reuse_w1_result="$(run_and_capture_argv_at "$reuse_home" "$reuse_proj" \
    --branch fs-resume-reuse-b1 --clone-dir "$reuse_clone")"
reuse_w1_rc=$?
register_run_paths "$reuse_w1_result"
if (( reuse_w1_rc != 0 )); then
    no "clone-dir reuse fixture: wake 1 creates the workspace" "$reuse_w1_result"
fi

# Wake 2: same --clone-dir plus --resume-session, no --checkout -- resume_session
# set AND clone_reused true.
reuse_w2_result="$(run_and_capture_argv_at "$reuse_home" "$reuse_proj" \
    --branch fs-resume-reuse-b2 --clone-dir "$reuse_clone" \
    --session-state "$reuse_state" --resume-session "$reuse_sid")"
reuse_w2_rc=$?
register_run_paths "$reuse_w2_result"
reuse_w2_run_dir="$REGISTERED_RUN_DIR"

if (( reuse_w2_rc != 0 )) || [[ -z "$reuse_w2_run_dir" || ! -f "$reuse_w2_run_dir/handoff.md" ]]; then
    no "resumed + reused workspace: prompt says the clone did not move" \
        "run failed or missing handoff.md: $reuse_w2_result"
else
    if grep -qF -- "The clone is the SAME directory as the earlier run's: \`$reuse_clone\`" \
        "$reuse_w2_run_dir/handoff.md"; then
        ok "resumed + reused workspace: prompt says the clone did not move"
    else
        no "resumed + reused workspace: prompt says the clone did not move" \
            "$(cat "$reuse_w2_run_dir/handoff.md")"
    fi
    if grep -qF -- "already on this branch's history" "$reuse_w2_run_dir/handoff.md" \
        && ! grep -qF -- 'not reachable from HEAD here' "$reuse_w2_run_dir/handoff.md" \
        && ! grep -qF -- 'git branch -r' "$reuse_w2_run_dir/handoff.md"; then
        ok "resumed + reused workspace: says commits are already on this branch, not the fresh-clone unreachable-ref text"
    else
        no "resumed + reused workspace: says commits are already on this branch, not the fresh-clone unreachable-ref text" \
            "$(cat "$reuse_w2_run_dir/handoff.md")"
    fi
fi

# Wake 3: same --clone-dir, --resume-session AND --checkout -- resume_session
# set, clone_reused true, checkout_ref pins the start point instead of the
# earlier wake's branch tip, so the "already on this branch's history" claim
# from wake 2 no longer holds and the generator says so instead.
reuse_w3_result="$(run_and_capture_argv_at "$reuse_home" "$reuse_proj" \
    --branch fs-resume-reuse-b3 --clone-dir "$reuse_clone" --checkout HEAD \
    --session-state "$reuse_state" --resume-session "$reuse_sid")"
reuse_w3_rc=$?
register_run_paths "$reuse_w3_result"
reuse_w3_run_dir="$REGISTERED_RUN_DIR"

if (( reuse_w3_rc != 0 )) || [[ -z "$reuse_w3_run_dir" || ! -f "$reuse_w3_run_dir/handoff.md" ]]; then
    no "resumed + reused workspace with --checkout: prompt warns commits may not be reachable" \
        "run failed or missing handoff.md: $reuse_w3_result"
else
    if grep -qF -- "\`--checkout HEAD\`, which pins its start point at that ref" \
        "$reuse_w3_run_dir/handoff.md" \
        && grep -qF -- 'may not be reachable from this branch'"'"'s history at all' \
            "$reuse_w3_run_dir/handoff.md" \
        && ! grep -qF -- "already on this branch's history" "$reuse_w3_run_dir/handoff.md"; then
        ok "resumed + reused workspace with --checkout: prompt warns commits may not be reachable"
    else
        no "resumed + reused workspace with --checkout: prompt warns commits may not be reachable" \
            "$(cat "$reuse_w3_run_dir/handoff.md")"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n== the store belongs to the coding legs alone ==\n'
# ---------------------------------------------------------------------------

# A --refresh-at continuation is the same conversation continued, so it
# WRITES into the store -- but it must never be handed --resume-session. The
# continuation prompt tells that leg it is "that fresh session, with none of
# its memory"; resuming would load the very conversation the refresh exists
# to drop, so the leg would start at or above the threshold it just crossed
# and hand off again at once, spending every --refresh-max leg for nothing.
# --refresh-at needs no flag here: it defaults to 0.5 on the claude harness,
# which is how the postmaster launches every wake.
cont_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
cont_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
cont_sid=0123abcd-4567-89ab-cdef-0123456789ab
export FAKE_HANDOFF_ON_CALL=1
cont_result="$(run_and_capture_argv "$cont_home" \
    --session-state "$cont_state" --resume-session "$cont_sid")"
cont_rc=$?
unset FAKE_HANDOFF_ON_CALL
register_run_paths "$cont_result"
cont_argv="$REGISTERED_ARGV_FILE"
cont_run_dir="$REGISTERED_RUN_DIR"

if (( cont_rc != 0 )); then
    no "a continuation leg ran" "run failed"
elif [[ ! -f "$cont_argv.2" ]]; then
    no "a continuation leg ran" "only $(cat "$cont_argv.count" 2>/dev/null) leg(s) launched"
else
    ok "a continuation leg ran"
    if argv_has_flag_value "$cont_argv.1" --resume-session "$cont_sid"; then
        ok "the implement leg still resumes the caller's session"
    else
        no "the implement leg still resumes the caller's session" \
            "$(cat "$cont_argv.1")"
    fi
    if argv_has_flag_value "$cont_argv.2" --session-state "$cont_state"; then
        ok "the continuation leg still binds the store"
    else
        no "the continuation leg still binds the store" "$(cat "$cont_argv.2")"
    fi
    if argv_has_word "$cont_argv.2" --resume-session; then
        no "the continuation leg is NOT resumed" "$(cat "$cont_argv.2")"
    else
        ok "the continuation leg is NOT resumed"
    fi
    # ...and it is not told it is a continuation of an earlier SANDBOX
    # either, which it is not: a continuation leg runs in this very run's
    # clone, with this run's paths and this run's branch. The section
    # belongs to the resumed implement leg alone.
    if [[ -n "$cont_run_dir" ]] \
        && grep -rqF -- "$cont_marker" \
            "$cont_run_dir/continuation-prompt-header.md" \
            "$cont_run_dir"/continuation-prompt-[0-9]*.md 2>/dev/null; then
        no "a continuation leg's prompt has no continuation-of-a-wake section" \
            "found in $cont_run_dir"
    else
        ok "a continuation leg's prompt has no continuation-of-a-wake section"
    fi
fi

# A review leg is a different conversation with a different prompt, so it
# gets neither flag: resuming the agent's session into it would append the
# reviewer's turns to the agent's own transcript, and merely writing there
# would make the review the newest transcript in the store -- which is the
# one summary.json reports as this run's session_id, and the one the next
# wake would resume.
rev_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
rev_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
# --review-loop refuses to launch without the review leg's method on the
# host, and this fixture HOME has nothing in it. Stage the repo's own copy,
# the same place install.sh puts it.
mkdir -p "$rev_home/.claude/skills"
cp -R "$repo_dir/skills/code-review-portable" "$rev_home/.claude/skills/"
export FAKE_COMMIT_ON_CALL=1
rev_result="$(run_and_capture_argv "$rev_home" --review-loop 1 \
    --session-state "$rev_state" --resume-session "$cont_sid")"
rev_rc=$?
unset FAKE_COMMIT_ON_CALL
register_run_paths "$rev_result"
rev_argv="$REGISTERED_ARGV_FILE"

if (( rev_rc != 0 )); then
    no "a review leg ran" "run failed"
elif [[ ! -f "$rev_argv.2" ]]; then
    no "a review leg ran" "only $(cat "$rev_argv.count" 2>/dev/null) leg(s) launched"
else
    ok "a review leg ran"
    if argv_has_word "$rev_argv.2" --session-state \
        || argv_has_word "$rev_argv.2" --resume-session; then
        no "the review leg gets neither flag" "$(cat "$rev_argv.2")"
    else
        ok "the review leg gets neither flag"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n== summary.json: session_state and session_id ==\n'
# ---------------------------------------------------------------------------

# What a caller reads to learn what the next wake should resume. The id is
# the newest transcript in the store by mtime -- a heuristic, because the
# CLI records nowhere which transcript was this run's.

summary_field() {
    jq -r "$2" "$1/summary.json" 2>/dev/null
}

# Two transcripts, a day apart, written in the order that would trip a
# naive "last one wins": the OLDER stem is written second.
sum_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
sum_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
sum_new=aaaabbbb-1111-2222-3333-444455556666
sum_old=ccccdddd-7777-8888-9999-aaaabbbbcccc
export FAKE_TRANSCRIPTS="$sum_new@1700000200 $sum_old@1700000100"
sum_result="$(run_and_capture_argv "$sum_home" --session-state "$sum_state")"
sum_rc=$?
unset FAKE_TRANSCRIPTS
register_run_paths "$sum_result"
sum_run_dir="$REGISTERED_RUN_DIR"

if (( sum_rc != 0 )) || [[ -z "$sum_run_dir" ]]; then
    no "summary.json reports session_state and session_id" "run failed"
else
    if [[ "$(summary_field "$sum_run_dir" .session_state)" == "$sum_state" ]]; then
        ok "summary.json carries session_state"
    else
        no "summary.json carries session_state" \
            "$(summary_field "$sum_run_dir" .session_state)"
    fi
    if [[ "$(summary_field "$sum_run_dir" .session_id)" == "$sum_new" ]]; then
        ok "summary.json session_id is the newest transcript stem"
    else
        no "summary.json session_id is the newest transcript stem" \
            "$(summary_field "$sum_run_dir" .session_id)"
    fi
fi

# The store stayed empty -- a session that died before writing a transcript.
# session_state is still reported; session_id is null, not missing, so a
# caller can tell "nothing to resume" from "resume was never asked for".
empty_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
empty_state="$(mktmp_dir "$scratch/fs-resume-state.XXXXXX")"
empty_result="$(run_and_capture_argv "$empty_home" --session-state "$empty_state")"
empty_rc=$?
register_run_paths "$empty_result"
empty_run_dir="$REGISTERED_RUN_DIR"
if (( empty_rc != 0 )) || [[ -z "$empty_run_dir" ]]; then
    no "summary.json session_id is null on an empty store" "run failed"
else
    if [[ "$(summary_field "$empty_run_dir" .session_id)" == null \
        && "$(summary_field "$empty_run_dir" .session_state)" == "$empty_state" ]]; then
        ok "summary.json session_id is null on an empty store"
    else
        no "summary.json session_id is null on an empty store" \
            "$(summary_field "$empty_run_dir" .)"
    fi
fi

# The mtime walk behind session_id runs on every host this script supports,
# so it must not reach for a GNU-only find. `find -printf` is findutils, and
# `brew install coreutils` does not supply find: on macOS, which the
# container backend supports, BSD find would reject it, the error would go
# to /dev/null with the rest of the walk's stderr, and session_id would come
# back null on every single run -- a silent no-op instead of a failure.
# Comment lines are skipped: the comment where the walk explains this rule
# names the flag it is refusing to use.
printf_hits="$(awk '/-printf/ && $0 !~ /^[[:space:]]*#/ { printf "%d: %s\n", NR, $0 }' \
    "$launcher")"
if [[ -n "$printf_hits" ]]; then
    no "the launcher uses no GNU-only find -printf" "$printf_hits"
else
    ok "the launcher uses no GNU-only find -printf"
fi

# No --session-state: both keys absent entirely, not null.
if [[ -z "$plain_run_dir" ]]; then
    no "summary.json omits both keys without --session-state" "no run dir"
elif [[ "$(summary_field "$plain_run_dir" 'has("session_id") or has("session_state")')" == false ]]; then
    ok "summary.json omits both keys without --session-state"
else
    no "summary.json omits both keys without --session-state" \
        "$(summary_field "$plain_run_dir" .)"
fi

# ---------------------------------------------------------------------------
printf '\n== claude-sandboxed: the bind, the resume and the retry ==\n'
# ---------------------------------------------------------------------------

wrapper="$repo_dir/scripts/claude-sandboxed"

# A fixture $HOME with a synthetic, unexpired credential. claude-sandboxed
# reads it with jq before anything else in claude mode, so without one every
# assertion below would fail on the operator's real credential instead of on
# what is under test. Nothing here is a real token.
cs_home="$(mktmp_dir "$scratch/fs-resume-cshome.XXXXXX")"
mkdir -p "$cs_home/.claude"
jq -n --argjson exp "$(( ($(date +%s) + 86400) * 1000 ))" \
    '{claudeAiOauth: {accessToken: "fixture-not-a-token", expiresAt: $exp,
                      refreshToken: "fixture-refresh"}}' \
    > "$cs_home/.claude/.credentials.json"
chmod 600 "$cs_home/.claude/.credentials.json"

# The backend stub: answers --capabilities, dumps its own argv, then execs
# the words after '--' so the stub claude below sees the real invocation.
cs_bin="$(mktmp_dir "$scratch/fs-resume-csbin.XXXXXX")"
cat > "$cs_bin/sandbox-backend-test" <<'BACKEND'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    printf 'toolchain=host\n'
    exit 0
fi
[[ -z "${BACKEND_CAPTURE:-}" ]] || printf '%s\n' "$@" >> "$BACKEND_CAPTURE"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
shift
exec "$@"
BACKEND
chmod +x "$cs_bin/sandbox-backend-test"

# The stub claude: records the argv it was handed and the prompt it was fed,
# and fails on demand with a chosen message on stderr.
cat > "$cs_bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CLAUDE_ARGV_FILE"
printf -- '--- attempt end ---\n' >> "$CLAUDE_ARGV_FILE"
cat >> "$CLAUDE_STDIN_FILE"
# CLAUDE_FAIL_ONCE names a marker file: fail while it exists, and remove it
# on the way out, so the FIRST attempt fails and a retry succeeds. Without
# it, CLAUDE_FAIL_MESSAGE fails every attempt.
if [[ -n "${CLAUDE_FAIL_ONCE:-}" ]]; then
    if [[ -e "$CLAUDE_FAIL_ONCE" ]]; then
        rm -f "$CLAUDE_FAIL_ONCE"
        printf '%s\n' "${CLAUDE_FAIL_MESSAGE:-failed}" >&2
        exit 1
    fi
    exit 0
fi
if [[ -n "${CLAUDE_FAIL_MESSAGE:-}" ]]; then
    printf '%s\n' "$CLAUDE_FAIL_MESSAGE" >&2
    exit 1
fi
exit 0
CLAUDE
chmod +x "$cs_bin/claude"

# Runs claude-sandboxed for real against those stubs. Prints
# "backend-argv<nl>claude-argv<nl>claude-stdin<nl>wrapper-output"; exit status
# is the wrapper's.
run_wrapper() {
    local work backend_argv claude_argv claude_stdin out rc
    work="$(mktemp -d "$scratch/forks/fs-resume-work.XXXXXX")"
    backend_argv="$(mktemp "$scratch/fs-resume-backend.XXXXXX")"
    claude_argv="$(mktemp "$scratch/fs-resume-claudeargv.XXXXXX")"
    claude_stdin="$(mktemp "$scratch/fs-resume-claudestdin.XXXXXX")"
    out="$(printf 'the prompt\n' \
        | HOME="$cs_home" PATH="$cs_bin:$PATH" \
          FORK_SANDBOX_BACKEND=test \
          BACKEND_CAPTURE="$backend_argv" \
          CLAUDE_ARGV_FILE="$claude_argv" \
          CLAUDE_STDIN_FILE="$claude_stdin" \
          timeout 60 "$wrapper" "$@" "$work" --print 2>&1)"
    rc=$?
    rm -rf "$work"
    printf '%s\n%s\n%s\n%s\n' "$backend_argv" "$claude_argv" "$claude_stdin" "$out"
    (( rc == 0 ))
}

# Splits a run_wrapper result, registering the three files with tmpdirs in
# the shell that owns the array -- run_wrapper's own body runs inside the
# caller's command substitution, where a tmpdirs+= would not survive.
take_wrapper_result() {
    local -a fields
    mapfile -t fields <<<"$1"
    W_BACKEND="${fields[0]:-}"
    W_CLAUDE_ARGV="${fields[1]:-}"
    W_CLAUDE_STDIN="${fields[2]:-}"
    tmpdirs+=("$W_BACKEND" "$W_CLAUDE_ARGV" "$W_CLAUDE_STDIN")
}

cs_state="$(mktmp_dir "$scratch/fs-resume-csstate.XXXXXX")"
cs_sid=0123abcd-4567-89ab-cdef-0123456789ab

# --- the bind ---------------------------------------------------------------
take_wrapper_result "$(run_wrapper --session-state "$cs_state")"
if argv_has_flag_value "$W_BACKEND" --bind-rw-at "$cs_state" \
    && awk -v s="$cs_state" -v d="$cs_home/.claude/projects" '
        $0 == s && prev == "--bind-rw-at" { want = 1 }
        want && $0 == d { found = 1; want = 0 }
        { prev = $0 }
        END { exit !found }' "$W_BACKEND"; then
    ok "the state dir is bound rw at the sandbox HOME's ~/.claude/projects"
else
    no "the state dir is bound rw at the sandbox HOME's ~/.claude/projects" \
        "$(cat "$W_BACKEND")"
fi

# It must be the ONLY new writable bind: never the whole ~/.claude, whose
# other contents (the credential copy, the settings, the onboarding file)
# stay ephemeral. Compare the DESTINATIONS of every writable bind against the
# same run without the flag -- the sources are per-run mktemp paths, which
# differ between two runs for reasons that have nothing to do with this flag.
rw_destinations() {
    awk '
        prev2 == "--bind-rw-at" { print }
        prev == "--bind-rw" { print }
        { prev2 = prev; prev = $0 }
    ' "$1" | sort
}
take_wrapper_result "$(run_wrapper)"
plain_backend="$W_BACKEND"
take_wrapper_result "$(run_wrapper --session-state "$cs_state")"
added="$(comm -13 <(rw_destinations "$plain_backend") <(rw_destinations "$W_BACKEND"))"
if [[ "$added" == "$cs_home/.claude/projects" ]]; then
    ok "--session-state adds that bind and nothing else writable"
else
    no "--session-state adds that bind and nothing else writable" \
        "writable destinations added: $added"
fi
# ~/.claude as a whole must still be the ephemeral state dir's copy, not a
# second host bind: the credential lives in there.
if (( $(grep -cx -- "$cs_home/.claude" "$W_BACKEND") == 1 )); then
    ok "the sandbox HOME .claude is still bound exactly once, from the temp state dir"
else
    no "the sandbox HOME .claude is still bound exactly once, from the temp state dir" \
        "$(cat "$W_BACKEND")"
fi

# --- the resume -------------------------------------------------------------
take_wrapper_result "$(run_wrapper --session-state "$cs_state" \
    --resume-session "$cs_sid")"
if argv_has_flag_value "$W_CLAUDE_ARGV" --resume "$cs_sid"; then
    ok "claude is invoked with --resume <id>"
else
    no "claude is invoked with --resume <id>" "$(cat "$W_CLAUDE_ARGV")"
fi
if grep -qx -- --print "$W_CLAUDE_ARGV"; then
    ok "--resume rides alongside the caller's --print (headless resume)"
else
    no "--resume rides alongside the caller's --print (headless resume)" \
        "$(cat "$W_CLAUDE_ARGV")"
fi
if grep -qx 'the prompt' "$W_CLAUDE_STDIN"; then
    ok "the prompt still reaches a resumed session on stdin"
else
    no "the prompt still reaches a resumed session on stdin" \
        "$(cat "$W_CLAUDE_STDIN")"
fi

take_wrapper_result "$(run_wrapper --session-state "$cs_state")"
if grep -qx -- --resume "$W_CLAUDE_ARGV"; then
    no "no --resume-session means a fresh session" "$(cat "$W_CLAUDE_ARGV")"
else
    ok "no --resume-session means a fresh session"
fi

# --- the retry --------------------------------------------------------------
fail_once="$scratch/fs-resume-failonce.$$"
tmpdirs+=("$fail_once")
: > "$fail_once"
retry_out="$(printf 'the prompt\n' \
    | HOME="$cs_home" PATH="$cs_bin:$PATH" FORK_SANDBOX_BACKEND=test \
      BACKEND_CAPTURE=/dev/null \
      CLAUDE_ARGV_FILE="$scratch/fs-resume-retryargv.$$" \
      CLAUDE_STDIN_FILE="$scratch/fs-resume-retrystdin.$$" \
      CLAUDE_FAIL_MESSAGE="No conversation found with session ID: $cs_sid" \
      CLAUDE_FAIL_ONCE="$fail_once" \
      timeout 60 "$wrapper" --session-state "$cs_state" \
      --resume-session "$cs_sid" \
      "$(mktemp -d "$scratch/forks/fs-resume-work.XXXXXX")" --print 2>&1)"
retry_rc=$?
tmpdirs+=("$scratch/fs-resume-retryargv.$$" "$scratch/fs-resume-retrystdin.$$")
retry_argv="$scratch/fs-resume-retryargv.$$"

if printf '%s\n' "$retry_out" | grep -q 'resume failed, retrying fresh'; then
    ok "a resume-shaped failure logs the marker line"
else
    no "a resume-shaped failure logs the marker line" "$retry_out"
fi
if (( $(grep -cx -- '--- attempt end ---' "$retry_argv") == 2 )); then
    ok "a resume-shaped failure runs claude exactly twice"
else
    no "a resume-shaped failure runs claude exactly twice" "$(cat "$retry_argv")"
fi
# The second attempt must carry no --resume at all.
if [[ "$(sed -n '/--- attempt end ---/,$p' "$retry_argv" | grep -cx -- --resume)" == 0 ]]; then
    ok "the second attempt drops --resume"
else
    no "the second attempt drops --resume" "$(cat "$retry_argv")"
fi
# And it must get the prompt: the first attempt consumed stdin, so an
# unbuffered retry would hand claude nothing.
if (( $(grep -cx 'the prompt' "$scratch/fs-resume-retrystdin.$$") == 2 )); then
    ok "both attempts are fed the buffered prompt"
else
    no "both attempts are fed the buffered prompt" \
        "$(cat "$scratch/fs-resume-retrystdin.$$")"
fi
if (( retry_rc == 0 )); then
    ok "the run succeeds when the fresh retry does"
else
    no "the run succeeds when the fresh retry does" "rc=$retry_rc: $retry_out"
fi

# A failure that is NOT resume-shaped is the run's own: no retry, and the
# exit code passes straight back.
plain_fail_argv="$scratch/fs-resume-plainargv.$$"
tmpdirs+=("$plain_fail_argv")
plain_fail_out="$(printf 'the prompt\n' \
    | HOME="$cs_home" PATH="$cs_bin:$PATH" FORK_SANDBOX_BACKEND=test \
      BACKEND_CAPTURE=/dev/null \
      CLAUDE_ARGV_FILE="$plain_fail_argv" \
      CLAUDE_STDIN_FILE=/dev/null \
      CLAUDE_FAIL_MESSAGE="Error: the model refused to do the work" \
      timeout 60 "$wrapper" --session-state "$cs_state" \
      --resume-session "$cs_sid" \
      "$(mktemp -d "$scratch/forks/fs-resume-work.XXXXXX")" --print 2>&1)"
plain_fail_rc=$?
if (( $(grep -cx -- '--- attempt end ---' "$plain_fail_argv") == 1 )); then
    ok "a non-resume failure does NOT retry"
else
    no "a non-resume failure does NOT retry" "$(cat "$plain_fail_argv")"
fi
if (( plain_fail_rc != 0 )); then
    ok "a non-resume failure keeps its exit code"
else
    no "a non-resume failure keeps its exit code" "$plain_fail_out"
fi

# A failure that merely mentions "session id:" -- but not the CLI's actual
# "No conversation found with session ID:" phrasing -- must not be treated
# as resume-shaped either. RESUME_FAIL_RE used to carry a bare "session
# id:" alternative broad enough to match this and trigger a full-price
# fresh rerun on top of a failed run's own commits.
unrelated_fail_argv="$scratch/fs-resume-unrelatedargv.$$"
tmpdirs+=("$unrelated_fail_argv")
unrelated_fail_out="$(printf 'the prompt\n' \
    | HOME="$cs_home" PATH="$cs_bin:$PATH" FORK_SANDBOX_BACKEND=test \
      BACKEND_CAPTURE=/dev/null \
      CLAUDE_ARGV_FILE="$unrelated_fail_argv" \
      CLAUDE_STDIN_FILE=/dev/null \
      CLAUDE_FAIL_MESSAGE="Error: unrelated tool failure (session id: not the resume marker)" \
      timeout 60 "$wrapper" --session-state "$cs_state" \
      --resume-session "$cs_sid" \
      "$(mktmp_dir "$scratch/forks/fs-resume-work.XXXXXX")" --print 2>&1)"
unrelated_fail_rc=$?
if (( $(grep -cx -- '--- attempt end ---' "$unrelated_fail_argv") == 1 )); then
    ok "an unrelated 'session id:' mention does NOT retry"
else
    no "an unrelated 'session id:' mention does NOT retry" "$(cat "$unrelated_fail_argv")"
fi
if (( unrelated_fail_rc != 0 )); then
    ok "an unrelated 'session id:' mention keeps its exit code"
else
    no "an unrelated 'session id:' mention keeps its exit code" "$unrelated_fail_out"
fi

# --- claude-sandboxed's own refusals ---------------------------------------
cs_refuses() {
    local label="$1" needle="$2"; shift 2
    local out rc
    out="$(HOME="$cs_home" PATH="$cs_bin:$PATH" FORK_SANDBOX_BACKEND=test \
        timeout 60 "$wrapper" "$@" 2>&1)"
    rc=$?
    if (( rc == 0 )); then
        no "$label" "accepted; expected a refusal"
    elif ! printf '%s' "$out" | grep -qF -- "$needle"; then
        no "$label" "refused with the wrong message: $out"
    else
        ok "$label"
    fi
}

cs_work="$(mktmp_dir "$scratch/forks/fs-resume-work.XXXXXX")"
cs_refuses "claude-sandboxed refuses --session-state with --exec" \
    "only without --exec" --exec --session-state "$cs_state" "$cs_work" true
cs_refuses "claude-sandboxed refuses --resume-session without --session-state" \
    "requires --session-state" --resume-session "$cs_sid" "$cs_work"
cs_refuses "claude-sandboxed refuses a bad session id" \
    "is not a session id" --session-state "$cs_state" \
    --resume-session "../etc/passwd" "$cs_work"
cs_refuses "claude-sandboxed refuses a leading-hyphen session id" \
    "is not a session id" --session-state "$cs_state" \
    --resume-session "-abcdef12" "$cs_work"
cs_refuses "claude-sandboxed refuses a symlinked state dir" \
    "is a symlink" --session-state "$symlink_state" "$cs_work"

# ---------------------------------------------------------------------------
printf '\n== pi'"'"'s own --session-state: bind destination, gating, --session-id ==\n'
# ---------------------------------------------------------------------------

# A non-sealed pi run still goes through claude-sandboxed (with --exec), so
# the same claude-sandboxed stub above -- which replaces the wrapper
# entirely and just records its argv -- works here too. fork-sandbox.sh
# itself still resolves a real pi+node to bind in, unless the backend
# reports an image toolchain (fs_resolve_pi) -- so fake the backend into
# image mode, the same way fork-sandbox-review-harness-test.sh's --harness
# pi/some-model cases do. A plain (non-sealed) pi run does need pi.env too:
# fork-sandbox.sh refuses it outright otherwise, well before
# fs_build_sandbox_cmd.
cat > "$stub_bin/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/sandbox-backend-fake-image"

pi_cfg="$(mktemp -d)"; tmpdirs+=("$pi_cfg")
install -m 600 /dev/null "$pi_cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$pi_cfg/pi.env"

pi_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
pi_state="$(mktmp_dir "$scratch/fs-resume-pi-state.XXXXXX")"
pi_sid=0123abcd-4567-89ab-cdef-0123456789ab
pi_proj="$(new_project "$pi_home")"

pi_out="$(HOME="$pi_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$pi_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 120 "$launcher" --foreground --harness pi --model vendor/model \
    --session-state "$pi_state" --session-id "$pi_sid" \
    "$pi_proj" "$refusal_handoff" 2>&1)"
pi_rc=$?
pi_run_dir="$(printf '%s\n' "$pi_out" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( pi_rc != 0 )) || [[ -z "$pi_run_dir" ]]; then
    no "a pi run with --session-state and --session-id completed" \
        "rc=$pi_rc: $pi_out"
else
    tmpdirs+=("$pi_run_dir")
    pi_impl_line="$(grep '^impl_sandbox_cmd=' "$pi_run_dir/run.sh")"
    pi_base_line="$(grep '^sandbox_cmd=' "$pi_run_dir/run.sh")"

    # The bind's SOURCE is the host directory; its DESTINATION -- what pi is
    # actually TOLD as --session-dir, since pi runs inside the sandbox and
    # never sees the host path -- is the fixed in-sandbox path, not
    # $pi_state again. sandbox-backend-bwrap sets the sandboxed process's
    # HOME to this script's own $HOME (here, $pi_home), so that is the value
    # pi is actually told -- fork-sandbox.sh expands "$HOME/.pi/sessions" at
    # generation time, same as it already does for codex's own destination.
    case "$pi_impl_line" in
        *"--bind-rw-at $pi_state $pi_home/.pi/sessions"*) \
            ok "the coding leg binds the host dir read-write at the in-sandbox destination" ;;
        *) no "the coding leg binds the host dir read-write at the in-sandbox destination" \
            "$pi_impl_line" ;;
    esac
    case "$pi_impl_line" in
        *"--session-dir $pi_home/.pi/sessions"*) \
            ok "pi is told --session-dir at the in-sandbox destination, not the host path" ;;
        *) no "pi is told --session-dir at the in-sandbox destination, not the host path" \
            "$pi_impl_line" ;;
    esac
    case "$pi_impl_line" in
        *"--session-id $pi_sid"*) ok "pi is told --session-id" ;;
        *) no "pi is told --session-id" "$pi_impl_line" ;;
    esac

    # sandbox_cmd is what a review, fix or maintainer leg without its own
    # seat falls back to (run_leg's "cmd=(\"\${sandbox_cmd[@]}\")" default):
    # it must carry NEITHER the bind nor --session-id, on pi exactly as on
    # claude/codex, or such a leg would write into -- and, since pi's id is
    # create-if-missing, effectively resume -- the coding leg's own session.
    case "$pi_base_line" in
        *"--bind-rw-at"*) no "a leg with no seat of its own gets no --session-state bind (pi)" \
            "$pi_base_line" ;;
        *) ok "a leg with no seat of its own gets no --session-state bind (pi)" ;;
    esac
    case "$pi_base_line" in
        *"--session-id"*) no "a leg with no seat of its own gets no --session-id (pi)" \
            "$pi_base_line" ;;
        *) ok "a leg with no seat of its own gets no --session-id (pi)" ;;
    esac
fi

# Without --session-id (--session-state alone), pi must still be told
# --session-dir at the durable destination -- but never a literal empty
# --session-id argument: fork-sandbox.sh omits the flag entirely rather than
# pass one an empty value, which pi would see as a bare '' argument.
pi_noid_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
pi_noid_state="$(mktmp_dir "$scratch/fs-resume-pi-state.XXXXXX")"
pi_noid_out="$(HOME="$pi_noid_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$pi_cfg" FORK_SANDBOX_BACKEND=fake-image \
    timeout 120 "$launcher" --foreground --harness pi --model vendor/model \
    --session-state "$pi_noid_state" \
    "$(new_project "$pi_noid_home")" "$refusal_handoff" 2>&1)"
pi_noid_rc=$?
pi_noid_run_dir="$(printf '%s\n' "$pi_noid_out" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( pi_noid_rc != 0 )) || [[ -z "$pi_noid_run_dir" ]]; then
    no "a pi run with --session-state and no --session-id completed" \
        "rc=$pi_noid_rc: $pi_noid_out"
else
    tmpdirs+=("$pi_noid_run_dir")
    pi_noid_impl_line="$(grep '^impl_sandbox_cmd=' "$pi_noid_run_dir/run.sh")"
    case "$pi_noid_impl_line" in
        *'--session-id'*) \
            no "no --session-id means no --session-id flag at all, not an empty one" \
                "$pi_noid_impl_line" ;;
        *) ok "no --session-id means no --session-id flag at all, not an empty one" ;;
    esac
fi

# The durable store crosses wakes, so it already holds an earlier wake's
# turns before this run's own pi process appends its own. Pre-seed one
# "prior wake" turn directly in the (host) --session-state directory, have
# the stub append one "this wake" turn to the SAME file (as a real resumed
# pi CLI would, appending to the id's own file), and confirm the run's own
# accounting -- and its rescued copy under the run dir -- carry only the
# new turn, not the running total across both.
pi_cross_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
pi_cross_state="$(mktmp_dir "$scratch/fs-resume-pi-state.XXXXXX")"
pi_cross_sid=89abcdef-0123-4567-89ab-cdef01234567
pi_cross_file="$pi_cross_state/$pi_cross_sid.jsonl"
printf '{"usage":{"cost":{"total":1},"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":20}}\n' \
    > "$pi_cross_file"

pi_cross_out="$(HOME="$pi_cross_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$pi_cfg" FORK_SANDBOX_BACKEND=fake-image \
    FAKE_PI_APPEND_FILE="$pi_cross_file" \
    FAKE_PI_APPEND_LINE='{"usage":{"cost":{"total":2},"input":20,"output":20,"cacheRead":0,"cacheWrite":0,"totalTokens":40}}' \
    timeout 120 "$launcher" --foreground --harness pi --model vendor/model \
    --session-state "$pi_cross_state" --session-id "$pi_cross_sid" \
    "$(new_project "$pi_cross_home")" "$refusal_handoff" 2>&1)"
pi_cross_rc=$?
pi_cross_run_dir="$(printf '%s\n' "$pi_cross_out" | sed -n 's/^  run dir:  *//p' | head -1)"
if (( pi_cross_rc != 0 )) || [[ -z "$pi_cross_run_dir" ]]; then
    no "a pi run against a pre-seeded durable store completed" \
        "rc=$pi_cross_rc: $pi_cross_out"
else
    tmpdirs+=("$pi_cross_run_dir")
    # The durable file itself now carries both turns -- that part is
    # supposed to grow; it is the seat's whole transcript.
    check "the durable session file carries both wakes' turns" "2" \
        "$(wc -l < "$pi_cross_file")"
    # The run dir's rescued copy, and this run's own reported cost, must
    # carry only the new one.
    pi_cross_copy="$pi_cross_run_dir/pi-session/$pi_cross_sid.jsonl"
    if [[ -f "$pi_cross_copy" ]]; then
        check "the rescued copy carries only this run's own new turn" "1" \
            "$(wc -l < "$pi_cross_copy")"
        check "the rescued copy's turn is this run's own, not the prior wake's" \
            '{"usage":{"cost":{"total":2},"input":20,"output":20,"cacheRead":0,"cacheWrite":0,"totalTokens":40}}' \
            "$(cat "$pi_cross_copy")"
    else
        no "the rescued copy carries only this run's own new turn" \
            "no file at $pi_cross_copy"
        no "the rescued copy's turn is this run's own, not the prior wake's" \
            "no file at $pi_cross_copy"
    fi
    check "summary.json's cost is this run's own turn, not the running total" \
        "2.000000" "$(jq -r '.cost_usd // empty' "$pi_cross_run_dir/summary.json" 2>/dev/null)"
    check "summary.json's usage is this run's own turn, not the running total" \
        "40" "$(jq -r '.usage.total_tokens // empty' "$pi_cross_run_dir/summary.json" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
