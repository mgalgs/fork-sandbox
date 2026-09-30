#!/usr/bin/env bash
# fork-sandbox-uncommitted-test.sh — the run-end uncommitted-work check
#
# Usage: tests/fork-sandbox-uncommitted-test.sh
#
# A run's session edits files, then ends its turn without committing them --
# the runner fetches commits only, so that work was previously invisible: 0
# commits looked like an empty run, and an operator had to diff the clone by
# hand to discover it. Covers the check that catches this: a real
# `git status --porcelain`, run INSIDE the sandbox (never against the clone
# on the host -- see fork-sandbox.sh's own header comment on why), reported
# in summary.json (uncommitted_files, uncommitted_files_list) and as a
# WARNING in summary.txt, whether or not the run also committed something.
# Also pins that no host-side git command ever targets the clone directly.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
status="$repo_dir/scripts/fork-sandbox-status.sh"

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"
export FORK_SANDBOX_RUN_SOURCE=test

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
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

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

printf '== pin: no host-side git command targets the clone ==\n'
# The check under test has to run git status AGAINST the clone -- that is
# the whole feature. It does it by handing the clone to the sandbox backend
# as --workdir and letting the backend's own confinement run `git status`
# inside, never by this script (or the lib it sources) calling git with the
# clone as -C's argument or as a bare `cd` target -- see fork-sandbox.sh's
# own header comment (the fetch-back's "Nothing below runs git inside the
# clone") for why that distinction is load-bearing, not stylistic.
# shellcheck disable=SC2016  # the pattern is literal source text to grep for, not to expand
if grep -qE -- '-C "\$clone_dir"|cd "\$clone_dir"' "$repo_dir/scripts/fork-sandbox.sh" \
    "$repo_dir/scripts/fork-sandbox-lib.sh"; then
    # shellcheck disable=SC2016
    no "fork-sandbox.sh and fork-sandbox-lib.sh run no git directly against the clone" \
        "$(grep -nE -- '-C "\$clone_dir"|cd "\$clone_dir"' \
            "$repo_dir/scripts/fork-sandbox.sh" "$repo_dir/scripts/fork-sandbox-lib.sh")"
else
    ok "fork-sandbox.sh and fork-sandbox-lib.sh run no git directly against the clone"
fi

launcher_home="$(mktemp -d)"; tmpdirs+=("$launcher_home")
mkdir -p "$launcher_home/src"
real_cfg="$(mktemp -d)"; tmpdirs+=("$real_cfg")

new_project() {
    local d
    d="$(mktemp -d "$launcher_home/src/fs-uncommitted-test.XXXXXX")"
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

proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-uncommitted-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

# Every other suite's fake backend is a pure no-op ("exit 0" for anything
# but --capabilities) -- fine for suites that do not care what the backend
# actually ran, wrong here: this suite has to see the REAL state of the
# clone the sandboxed `git status --porcelain` reads, so this stub actually
# execs the command it is given, with the cwd --workdir names.
stub_dir="$(mktemp -d /var/tmp/claude-scratch/fs-uncommitted-stub.XXXXXX)"
tmpdirs+=("$stub_dir")
cat > "$stub_dir/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "$@"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done
cat >/dev/null
if [[ -n "${FAKE_COMMIT:-}" ]]; then
    git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        -C "$clone_dir" commit --allow-empty -q -m "$FAKE_COMMIT"
fi
if [[ -n "${FAKE_LEAVE_UNCOMMITTED:-}" ]]; then
    printf 'changed\n' >> "$clone_dir/file.txt"
    printf 'new\n' > "$clone_dir/untracked.txt"
fi
if [[ -n "${FAKE_LEAVE_UNTRACKED_DIR:-}" ]]; then
    mkdir -p "$clone_dir/newpkg"
    printf 'one\n' > "$clone_dir/newpkg/a.txt"
    printf 'two\n' > "$clone_dir/newpkg/b.txt"
    printf 'three\n' > "$clone_dir/newpkg/c.txt"
fi
if [[ -n "${FAKE_WRITE_ENV_SANDBOX:-}" ]]; then
    printf 'SOME_URL=unix:///tmp/does-not-matter.sock\n' > "$clone_dir/.env.sandbox"
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
cat > "$stub_dir/sandbox-backend-fake-run" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
# The only other caller of this stub is the run-end uncommitted-work check
# itself (the harness leg goes through the separately-stubbed
# claude-sandboxed, above, never this binary directly) -- capture its argv
# so the suite can pin that the clone's alternates got bound, the same way
# fs_build_sandbox_cmd binds them for the harness leg. A stub that just cd's
# into --workdir and execs, as this one does, cannot catch a missing bind on
# its own: the whole host filesystem stays reachable either way, unlike the
# real bwrap/container backend this stands in for.
printf '%s\n' "$@" > "$FIXTURE_STATUS_ARGV"
if [[ -n "${FAKE_STATUS_FAIL:-}" ]]; then
    echo "fatal: simulated sandboxed git failure" >&2
    exit 128
fi
workdir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir) workdir="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
cd "$workdir" || exit 1
exec "$@"
STUB
chmod +x "$stub_dir"/*

status_argv="$stub_dir/status-argv.txt"
proj_objects_real="$(cd "$proj/.git/objects" && pwd -P)"

run_real() {
    local out rc rd
    rm -f "$status_argv"
    out="$(HOME="$launcher_home" PATH="$stub_dir:$PATH" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
        FORK_SANDBOX_BACKEND=fake-run FIXTURE_STATUS_ARGV="$status_argv" \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if [[ -z "$rd" ]]; then
        printf 'run_real failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

printf '\n== a clean run: no uncommitted work ==\n'
export FAKE_COMMIT="clean implement"
unset FAKE_LEAVE_UNCOMMITTED
rd_clean="$(run_real --harness claude --branch "fs-uncommitted-clean-$$")" && tmpdirs+=("$rd_clean")
if [[ -n "$rd_clean" ]]; then
    check "one commit landed" "1" "$(jq -r '.commits' "$rd_clean/summary.json")"
    check "summary.json: uncommitted_files is 0" "0" \
        "$(jq -r '.uncommitted_files' "$rd_clean/summary.json")"
    check "summary.json: uncommitted_files_list is empty" "[]" \
        "$(jq -c '.uncommitted_files_list' "$rd_clean/summary.json")"
    lacks "summary.txt carries no uncommitted-work WARNING" \
        "uncommitted file(s)" "$(cat "$rd_clean/summary.txt")"
    out_status="$("$status" "$rd_clean" 2>&1)"
    lacks "fork-sandbox-status.sh's default view carries no uncommitted-work WARNING" \
        "uncommitted file(s)" "$out_status"
else
    no "a clean run produced a run directory" "run_real failed"
fi

printf '\n== a run that leaves modified and untracked files, no commit ==\n'
unset FAKE_COMMIT
export FAKE_LEAVE_UNCOMMITTED=1
rd_dirty="$(run_real --harness claude --branch "fs-uncommitted-dirty-$$")" && tmpdirs+=("$rd_dirty")
if [[ -n "$rd_dirty" ]]; then
    check "no commits landed" "0" "$(jq -r '.commits' "$rd_dirty/summary.json")"
    check "summary.json: uncommitted_files counts both files" "2" \
        "$(jq -r '.uncommitted_files' "$rd_dirty/summary.json")"
    uf_list="$(jq -r '.uncommitted_files_list[]' "$rd_dirty/summary.json" 2>/dev/null)"
    contains "the list names the modified tracked file" "file.txt" "$uf_list"
    contains "the list names the untracked file" "untracked.txt" "$uf_list"
    contains "summary.txt carries the WARNING, with the count" \
        "WARNING: the clone holds 2 uncommitted file(s)" "$(cat "$rd_dirty/summary.txt")"
    contains "summary.txt names review and maintainer never seeing them" \
        "Review and maintainer legs never saw them" "$(cat "$rd_dirty/summary.txt")"
    clone_dir_dirty="$(jq -r '.clone_dir' "$rd_dirty/summary.json")"
    contains "summary.txt names the clone path" "$clone_dir_dirty" "$(cat "$rd_dirty/summary.txt")"
    contains "summary.txt lists the modified file" "file.txt" "$(cat "$rd_dirty/summary.txt")"
    contains "summary.txt lists the untracked file" "untracked.txt" "$(cat "$rd_dirty/summary.txt")"
    # The check only reads; it must never touch what it found.
    check "the modified file is still modified, untouched by the check" \
        $'hello\nchanged' "$(cat "$clone_dir_dirty/file.txt" 2>/dev/null)"
    check "the untracked file is still there, untouched by the check" \
        "new" "$(cat "$clone_dir_dirty/untracked.txt" 2>/dev/null)"
    out_status="$("$status" "$rd_dirty" 2>&1)"
    contains "fork-sandbox-status.sh's default view carries the WARNING" \
        "WARNING: the clone holds 2 uncommitted file(s)" "$out_status"
    out_monterm="$(timeout 30 "$status" --monitor-terminal "$rd_dirty" 2>&1)"
    contains "fork-sandbox-status.sh --monitor-terminal carries the WARNING" \
        "WARNING: the clone holds 2 uncommitted file(s)" "$out_monterm"
    # The clone is a --shared clone of $proj: it carries no objects of its
    # own and reads its history through $proj/.git/objects via
    # .git/objects/info/alternates. Without that store bound read-only into
    # the sandbox the same way fs_build_sandbox_cmd binds it for the
    # harness leg, the checked-out `git status --porcelain` above would see
    # refs but not the objects behind them and fail outright -- this stub
    # cannot catch that on its own (it execs on the real host filesystem
    # regardless of which binds it was handed), so pin the argv directly.
    contains "the uncommitted-work check's backend invocation binds the clone's alternates" \
        "--bind-ro
$proj_objects_real" "$(cat "$status_argv" 2>/dev/null)"
else
    no "a dirty run produced a run directory" "run_real failed"
fi

printf '\n== a run that leaves an untracked directory: files counted, not folded ==\n'
# git status --porcelain's default untracked mode folds a whole untracked
# directory into one "?? dir/" line. The runner counts porcelain lines as
# files, so without --untracked-files=all a new 3-file directory would
# report uncommitted_files: 1 -- wrong, and the handoff this check was
# built for says "never guess".
unset FAKE_COMMIT FAKE_LEAVE_UNCOMMITTED
export FAKE_LEAVE_UNTRACKED_DIR=1
rd_dir="$(run_real --harness claude --branch "fs-uncommitted-dir-$$")" && tmpdirs+=("$rd_dir")
if [[ -n "$rd_dir" ]]; then
    check "summary.json counts each file in the untracked directory, not the folded line" \
        "3" "$(jq -r '.uncommitted_files' "$rd_dir/summary.json")"
    contains "summary.txt carries the WARNING, with the per-file count" \
        "WARNING: the clone holds 3 uncommitted file(s)" "$(cat "$rd_dir/summary.txt")"
else
    no "an untracked-directory run produced a run directory" "run_real failed"
fi
unset FAKE_LEAVE_UNTRACKED_DIR

printf '\n== a services hook writes .env.sandbox: not the session own work, not flagged ==\n'
# docs/sandbox-services.md's `up` contract writes <clone-dir>/.env.sandbox
# into the working tree itself, not under .git -- fs_make_clone excludes it
# via .git/info/exclude the same way it excludes claude-session/, so this
# run-of-the-mill file never shows up as the session's own uncommitted work.
unset FAKE_COMMIT FAKE_LEAVE_UNCOMMITTED
export FAKE_WRITE_ENV_SANDBOX=1
rd_env="$(run_real --harness claude --branch "fs-uncommitted-env-$$")" && tmpdirs+=("$rd_env")
if [[ -n "$rd_env" ]]; then
    check "summary.json: .env.sandbox is not counted as uncommitted" "0" \
        "$(jq -r '.uncommitted_files' "$rd_env/summary.json")"
    lacks "summary.txt carries no uncommitted-work WARNING for .env.sandbox" \
        "uncommitted file(s)" "$(cat "$rd_env/summary.txt")"
    clone_dir_env="$(jq -r '.clone_dir' "$rd_env/summary.json")"
    check "the services hook's .env.sandbox is still there, untouched" \
        "SOME_URL=unix:///tmp/does-not-matter.sock" "$(cat "$clone_dir_env/.env.sandbox" 2>/dev/null)"
else
    no "a services-hook run produced a run directory" "run_real failed"
fi
unset FAKE_WRITE_ENV_SANDBOX

printf '\n== a run that commits AND leaves an uncommitted file: both show ==\n'
export FAKE_COMMIT="dirty implement"
export FAKE_LEAVE_UNCOMMITTED=1
rd_both="$(run_real --harness claude --branch "fs-uncommitted-both-$$")" && tmpdirs+=("$rd_both")
if [[ -n "$rd_both" ]]; then
    check "one commit landed" "1" "$(jq -r '.commits' "$rd_both/summary.json")"
    check "summary.json still counts the uncommitted files" "2" \
        "$(jq -r '.uncommitted_files' "$rd_both/summary.json")"
    contains "summary.txt reports the commit was fetched" \
        "fetched:   yes." "$(cat "$rd_both/summary.txt")"
    contains "summary.txt still carries the uncommitted-work WARNING" \
        "WARNING: the clone holds 2 uncommitted file(s)" "$(cat "$rd_both/summary.txt")"
else
    no "a both-commit-and-dirty run produced a run directory" "run_real failed"
fi

printf '\n== the check itself fails: unknown, never guessed at zero ==\n'
export FAKE_COMMIT="unchecked implement"
export FAKE_LEAVE_UNCOMMITTED=1
export FAKE_STATUS_FAIL=1
rd_fail="$(run_real --harness claude --branch "fs-uncommitted-fail-$$")" && tmpdirs+=("$rd_fail")
unset FAKE_STATUS_FAIL
if [[ -n "$rd_fail" ]]; then
    check "the commit still landed" "1" "$(jq -r '.commits' "$rd_fail/summary.json")"
    check "summary.json: uncommitted_files is null" "null" \
        "$(jq -c '.uncommitted_files' "$rd_fail/summary.json")"
    check "summary.json: uncommitted_files_list is null" "null" \
        "$(jq -c '.uncommitted_files_list' "$rd_fail/summary.json")"
    contains "summary.txt says the check could not run" \
        "WARNING: could not check the clone for uncommitted work." "$(cat "$rd_fail/summary.txt")"
    contains "git-status.log keeps the sandboxed error" \
        "simulated sandboxed git failure" "$(cat "$rd_fail/git-status.log" 2>/dev/null)"
else
    no "a failed-check run produced a run directory" "run_real failed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
