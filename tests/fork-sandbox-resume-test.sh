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
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

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

refuses "--session-state refused on --harness pi" \
    "claude-only" --harness pi --model vendor/model \
    --session-state "$scratch/fs-resume-unused"
refuses "--session-state refused on --harness codex" \
    "claude-only" --harness codex \
    --session-state "$scratch/fs-resume-unused"
refuses "--session-state refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --session-state "$scratch/fs-resume-unused"
refuses "--resume-session refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab
refuses "--resume-session refused without --session-state" \
    "requires --session-state" --harness claude \
    --resume-session 0123abcd-4567-89ab-cdef-0123456789ab

# The id is used as a transcript filename stem, so path characters and
# anything outside [0-9a-f-] must not survive to the claude command line.
for bad in "../etc/passwd" "a/b" "abcdef12.jsonl" "ABCDEF1234" "short" \
           "$(printf 'a%.0s' {1..65})"; do
    refuses "bad session id refused: '$bad'" "is not a session id" \
        --harness claude --session-state "$scratch/fs-resume-unused" \
        --resume-session "$bad"
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
printf '%s\n' "$@" >> "$FAKE_ARGV_FILE"
printf -- '--- end of argv ---\n' >> "$FAKE_ARGV_FILE"
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# Runs the launcher for real, in the foreground, against a fixture $HOME and
# the stub above, and prints "argv-file<newline>run-dir" for the CALLER to
# register -- this body runs inside the caller's command substitution, so a
# tmpdirs+= here would never reach the trap.
run_and_capture_argv() {
    local home="$1"; shift
    local proj handoff_dir handoff argv_file cfg out rc rd
    proj="$(new_project "$home")"
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

register_run_paths() {
    local result="$1"
    local -a fields
    mapfile -t fields <<<"$result"
    REGISTERED_ARGV_FILE="${fields[0]:-}"
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

# Without --resume-session, neither flag appears at all: a run that was
# never asked to persist anything must be byte-identical to one built
# before the flags existed.
plain_home="$(mktmp_dir "$scratch/fs-resume-home.XXXXXX")"
plain_result="$(run_and_capture_argv "$plain_home")"
plain_rc=$?
register_run_paths "$plain_result"
plain_argv="$REGISTERED_ARGV_FILE"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
