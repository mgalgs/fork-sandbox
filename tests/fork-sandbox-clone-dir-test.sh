#!/usr/bin/env bash
# fork-sandbox-clone-dir-test.sh -- persistent seat workspaces: --clone-dir
#
# Usage: tests/fork-sandbox-clone-dir-test.sh
#
# --clone-dir names a directory to persist the sandbox's clone in across
# separate invocations, instead of the throwaway one fork-sandbox.sh makes
# under its own run dir. This suite covers the flag end to end: refusals and
# --dry-run (run directly, no stub needed -- --dry-run exits before anything
# is created), then real (non-dry-run) launches against a stub
# claude-sandboxed, asserting on the DISK STATE --clone-dir's target ends up
# in -- git branch, git log, ancestry -- since --clone-dir only changes where
# fork-sandbox.sh puts the clone before invoking claude-sandboxed and is not
# itself forwarded into that argv.
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
        rm -f -- "$d".[0-9]* "$d".count 2>/dev/null
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

scratch="/var/tmp/claude-scratch"
mkdir -p "$scratch/forks"

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

new_project() {
    local home="$1" d
    mkdir -p "$home/src"
    d="$(mktemp -d "$home/src/fs-clonedir-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
printf '== fork-sandbox.sh: --clone-dir refusals and --dry-run ==\n'
# ---------------------------------------------------------------------------

refusal_handoff_dir="$(mktmp_dir "$scratch/fs-clonedir-ho.XXXXXX")"
refusal_handoff="$refusal_handoff_dir/handoff.md"
printf 'do the task\n' > "$refusal_handoff"

refusal_home="$(mktmp_dir "$scratch/fs-clonedir-home.XXXXXX")"
refusal_proj="$(new_project "$refusal_home")"
refusal_cfg="$(mktmp_dir "$scratch/fs-clonedir-cfg.XXXXXX")"

dry_run() {
    HOME="$refusal_home" FORK_SANDBOX_CONFIG_DIR="$refusal_cfg" \
        timeout 60 "$launcher" --dry-run --branch fs-clonedir-test "$@" \
        "$refusal_proj" "$refusal_handoff" 2>&1
}

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

refuses "--clone-dir refused with --k8s" \
    "not supported with --k8s" --k8s --model vendor/model \
    --clone-dir "$scratch/fs-clonedir-unused"

# --clone-dir has no claude-only gate: pi and codex accept it too.
dry_pi_out="$(dry_run --harness pi --model vendor/model \
    --clone-dir "$scratch/fs-clonedir-pi-unused")"
dry_pi_rc=$?
if (( dry_pi_rc == 0 )) && printf '%s\n' "$dry_pi_out" | grep -q '^clone_dir='; then
    ok "--clone-dir accepted on --harness pi"
else
    no "--clone-dir accepted on --harness pi" "$dry_pi_out"
fi

symlink_target="$(mktmp_dir "$scratch/fs-clonedir-linktarget.XXXXXX")"
symlink_dir="$scratch/fs-clonedir-link.$$"
ln -sfn "$symlink_target" "$symlink_dir"
tmpdirs+=("$symlink_dir")
refuses "--clone-dir refused when it is a symlink" "is a symlink" \
    --clone-dir "$symlink_dir"

outside_dir="$(mktemp -d)"
tmpdirs+=("$outside_dir")
refuses "--clone-dir refused outside the scratch root" \
    "/var/tmp/claude-scratch/" \
    --clone-dir "$outside_dir/elsewhere"

not_a_dir="$(mktmp_dir "$scratch/fs-clonedir-file-parent.XXXXXX")/plain-file"
: > "$not_a_dir"
tmpdirs+=("$not_a_dir")
refuses "--clone-dir refused when it exists and is not a directory" \
    "exists and is not a" \
    --clone-dir "$not_a_dir"

tmp_root_out="$(dry_run --clone-dir /tmp/claude-scratch/fs-clonedir-tmp-root/clone)"
tmp_root_rc=$?
if (( tmp_root_rc == 0 )) && printf '%s\n' "$tmp_root_out" | grep -q '^clone_dir='; then
    ok "--clone-dir accepts a /tmp/claude-scratch path"
else
    no "--clone-dir accepts a /tmp/claude-scratch path" "$tmp_root_out"
fi

printf '\n== fork-sandbox.sh: --dry-run prints the resolved clone_dir ==\n'

dry_clone="$scratch/fs-clonedir-dry.$$/clone"
dry_out="$(dry_run --clone-dir "$dry_clone")"
if printf '%s\n' "$dry_out" | grep -qx "clone_dir=$dry_clone"; then
    ok "--dry-run prints the resolved clone_dir"
else
    no "--dry-run prints the resolved clone_dir" "$dry_out"
fi
if [[ -e "$scratch/fs-clonedir-dry.$$" ]]; then
    no "--dry-run creates no clone directory" "it created $dry_clone"
    rm -rf "$scratch/fs-clonedir-dry.$$"
else
    ok "--dry-run creates no clone directory"
fi

dry_out_plain="$(dry_run)"
if printf '%s\n' "$dry_out_plain" | grep -q '^clone_dir='; then
    no "--dry-run omits clone_dir when the flag is absent" "$dry_out_plain"
else
    ok "--dry-run omits clone_dir when the flag is absent"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --clone-dir create and reuse, real launches ==\n'
# ---------------------------------------------------------------------------

stub_bin="$(mktmp_dir "$scratch/fs-clonedir-stub.XXXXXX")"
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses the backend entirely. It drains the prompt
# from stdin (never read) and records the argv it was handed, then exits 0.
cat >/dev/null
call_n=$(( $(cat "$FAKE_ARGV_FILE.count" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$call_n" > "$FAKE_ARGV_FILE.count"
printf '%s\n' "$@" > "$FAKE_ARGV_FILE.$call_n"
# The work dir is the argument before claude's own first flag.
stub_clone=""
stub_prev=""
for a in "$@"; do
    [[ "$a" == --dangerously-skip-permissions ]] && stub_clone="$stub_prev"
    stub_prev="$a"
done
# FAKE_COMMIT_ON_CALL=N: commit in the clone on the Nth invocation.
if [[ "${FAKE_COMMIT_ON_CALL:-}" == "$call_n" && -n "$stub_clone" ]]; then
    git -C "$stub_clone" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        commit -q --allow-empty -m 'stub work' >/dev/null 2>&1
fi
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

run_and_capture() {
    local home="$1" proj="$2"; shift 2
    local handoff_dir handoff argv_file cfg out rc rd
    handoff_dir="$(mktemp -d "$scratch/fs-clonedir-ho.XXXXXX")"
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    argv_file="$(mktemp "$scratch/fs-clonedir-argv.XXXXXX")"
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

register_paths() {
    local result="$1"
    local -a fields
    mapfile -t fields <<<"$result"
    local f
    for f in "${fields[@]}"; do
        [[ -n "$f" ]] && tmpdirs+=("$f")
    done
}

flow_home="$(mktmp_dir "$scratch/fs-clonedir-home.XXXXXX")"
flow_proj="$(new_project "$flow_home")"
flow_clone="$scratch/fs-clonedir-ws.$$"
tmpdirs+=("$flow_clone")

# --- first wake: fresh create, directory used as given (not nested) -------
first_result="$(run_and_capture "$flow_home" "$flow_proj" \
    --branch fs-clonedir-b1 --clone-dir "$flow_clone")"
first_rc=$?
register_paths "$first_result"

if (( first_rc == 0 )); then
    ok "first wake: launch succeeds with --clone-dir"
else
    no "first wake: launch succeeds with --clone-dir" "$first_result"
fi
if [[ -d "$flow_clone/.git" ]]; then
    ok "first wake: clone_dir is used as given, not nested under project basename"
else
    no "first wake: clone_dir is used as given, not nested under project basename" \
        "expected $flow_clone/.git"
fi
if git -C "$flow_clone" rev-parse --verify --quiet fs-clonedir-b1 >/dev/null; then
    ok "first wake: clone is on the run's branch"
else
    no "first wake: clone is on the run's branch" "no branch fs-clonedir-b1 in $flow_clone"
fi
if [[ -e "$flow_clone/.git/fork-sandbox-lock" ]]; then
    ok "first wake: the lock file lives under .git, not the working tree"
else
    no "first wake: the lock file lives under .git, not the working tree" \
        "expected $flow_clone/.git/fork-sandbox-lock"
fi
if [[ -z "$(git -C "$flow_clone" status --porcelain)" ]]; then
    ok "first wake: the lock file leaves the working tree clean"
else
    no "first wake: the lock file leaves the working tree clean" \
        "$(git -C "$flow_clone" status --porcelain)"
fi
first_head="$(git -C "$flow_clone" rev-parse HEAD 2>/dev/null)"
proj_head="$(git -C "$flow_proj" rev-parse HEAD 2>/dev/null)"
if [[ -n "$first_head" && "$first_head" == "$proj_head" ]]; then
    ok "first wake: branch starts at the origin project's HEAD"
else
    no "first wake: branch starts at the origin project's HEAD" \
        "clone HEAD=$first_head project HEAD=$proj_head"
fi
if [[ ! -e "$flow_clone/.git/objects/info/alternates" ]]; then
    ok "first wake: dissociated from the origin's object store (no alternates file)"
else
    no "first wake: dissociated from the origin's object store (no alternates file)" \
        "$(cat "$flow_clone/.git/objects/info/alternates")"
fi
if git -C "$flow_clone" fsck --full >/dev/null 2>&1; then
    ok "first wake: git fsck passes with the origin's objects repacked locally"
else
    no "first wake: git fsck passes with the origin's objects repacked locally" \
        "$(git -C "$flow_clone" fsck --full 2>&1)"
fi
if grep -qxF 'claude-session/' "$flow_clone/.git/info/exclude" 2>/dev/null; then
    ok "first wake: claude-session/ is excluded via .git/info/exclude"
else
    no "first wake: claude-session/ is excluded via .git/info/exclude" \
        "$(cat "$flow_clone/.git/info/exclude" 2>/dev/null)"
fi

# --- second wake: reuse, new branch built on the first wake's commit ------
git -C "$flow_clone" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    commit -q --allow-empty -m 'first wake work' >/dev/null 2>&1
seat_commit="$(git -C "$flow_clone" rev-parse HEAD)"

# Stand-ins for what a wake actually leaves behind: pi's fixed-path session
# dirs under .git, and claude-sandboxed's transcript rescue in the working
# tree. Nothing in the stub harness writes these, so seed them here and
# assert the next wake clears them rather than folding them into its own
# accounting or carrying them forward forever.
mkdir -p "$flow_clone/.git/pi-session" "$flow_clone/.git/pi-session-review-1" \
    "$flow_clone/claude-session"
printf '{"stopReason":"prior wake leftover"}\n' \
    > "$flow_clone/.git/pi-session/prior-wake.jsonl"
printf 'prior wake transcript\n' > "$flow_clone/claude-session/prior-wake.jsonl"

# The reuse-time cleanup is surgical -- exactly claude-session/ and
# .git/pi-session* -- so an agent's own untracked scratch file, left behind
# in the workspace by design (it is not one of the two known-accumulating
# artifact paths above), must survive the same cleanup that clears those.
printf 'agent scratch notes\n' > "$flow_clone/agent-scratch.txt"

second_result="$(run_and_capture "$flow_home" "$flow_proj" \
    --branch fs-clonedir-b2 --clone-dir "$flow_clone")"
second_rc=$?
register_paths "$second_result"

if [[ ! -e "$flow_clone/.git/pi-session" && ! -e "$flow_clone/.git/pi-session-review-1" ]]; then
    ok "second wake: a prior wake's pi-session dirs are cleared, not folded in"
else
    no "second wake: a prior wake's pi-session dirs are cleared, not folded in" \
        "$(find "$flow_clone/.git" -maxdepth 1 -name 'pi-session*')"
fi
if [[ ! -e "$flow_clone/claude-session" ]]; then
    ok "second wake: a prior wake's claude-session/ is cleared, not left to grow"
else
    no "second wake: a prior wake's claude-session/ is cleared, not left to grow" \
        "$(ls -la "$flow_clone/claude-session")"
fi
if [[ -f "$flow_clone/agent-scratch.txt" ]]; then
    ok "second wake: an unrelated untracked file in the workspace survives reuse cleanup"
else
    no "second wake: an unrelated untracked file in the workspace survives reuse cleanup" \
        "agent-scratch.txt was removed; reuse cleanup is not surgical"
fi

if (( second_rc == 0 )); then
    ok "second wake: launch succeeds reusing --clone-dir"
else
    no "second wake: launch succeeds reusing --clone-dir" "$second_result"
fi
if git -C "$flow_clone" merge-base --is-ancestor "$seat_commit" fs-clonedir-b2 2>/dev/null; then
    ok "second wake: new branch is built on the first wake's own commit"
else
    no "second wake: new branch is built on the first wake's own commit" \
        "seat_commit=$seat_commit not an ancestor of fs-clonedir-b2"
fi

# Commit accounting has to measure THIS wake against the commit the reused
# clone actually started from -- the previous wake's tip -- not against the
# origin's HEAD from before any wake existed. The stub commits nothing on
# this call, so a wake that made no commits of its own must report 0, not
# claim the first wake's already-accounted-for commit as its own.
second_fields=()
mapfile -t second_fields <<<"$second_result"
second_rundir="${second_fields[3]:-}"
if [[ -n "$second_rundir" && -f "$second_rundir/summary.json" ]]; then
    second_commits="$(jq -r '.commits' "$second_rundir/summary.json" 2>/dev/null)"
    if [[ "$second_commits" == "0" ]]; then
        ok "second wake: a wake that commits nothing reports 0 commits, not its predecessor's"
    else
        no "second wake: a wake that commits nothing reports 0 commits, not its predecessor's" \
            "summary.json reports commits=$second_commits"
    fi
else
    no "second wake: a wake that commits nothing reports 0 commits, not its predecessor's" \
        "no summary.json at '${second_rundir:-<empty>}'"
fi
if git -C "$flow_proj" rev-parse --verify --quiet fs-clonedir-b2 >/dev/null 2>&1; then
    no "second wake: a no-new-commits wake does not leave its branch behind in the origin" \
        "found branch fs-clonedir-b2 in $flow_proj"
else
    ok "second wake: a no-new-commits wake does not leave its branch behind in the origin"
fi

# This run passed no --resume-session (that flag is claude-only; --clone-dir
# is not), so the reused-workspace notice must key off clone_reused alone --
# a seat reusing a persistent workspace has to be told so even when there is
# no transcript to resume.
if [[ -n "$second_rundir" && -f "$second_rundir/handoff.md" ]]; then
    if grep -qF -- '## This workspace is not new' "$second_rundir/handoff.md"; then
        ok "second wake: a reused workspace is flagged even with no --resume-session"
    else
        no "second wake: a reused workspace is flagged even with no --resume-session" \
            "$(cat "$second_rundir/handoff.md")"
    fi
    if grep -qF -- '## This session is a continuation' "$second_rundir/handoff.md"; then
        no "second wake: no false claim of a resumed transcript" \
            "found the resumed-session marker with no --resume-session given"
    else
        ok "second wake: no false claim of a resumed transcript"
    fi
else
    no "second wake: a reused workspace is flagged even with no --resume-session" \
        "no handoff.md at '${second_rundir:-<empty>}'"
fi

# fs_reuse_clone's fetch overwrites the origin/<b> refs the first wake's
# fs_make_clone mirrored, so only the first wake's preamble may describe that
# mapping.
first_fields=()
mapfile -t first_fields <<<"$first_result"
first_rundir="${first_fields[3]:-}"
if [[ -n "$first_rundir" && -f "$first_rundir/handoff.md" ]] \
    && grep -qF -- 'origin/<b>' "$first_rundir/handoff.md"; then
    ok "first wake: the preamble describes the origin/<b> mapping"
else
    no "first wake: the preamble describes the origin/<b> mapping" \
        "no origin/<b> sentence in '${first_rundir:-<empty>}/handoff.md'"
fi
if [[ -n "$second_rundir" && -f "$second_rundir/handoff.md" ]] \
    && ! grep -qF -- 'origin/<b>' "$second_rundir/handoff.md"; then
    ok "second wake: the preamble does not describe the origin/<b> mapping a reuse fetch overwrites"
else
    no "second wake: the preamble does not describe the origin/<b> mapping a reuse fetch overwrites" \
        "origin/<b> sentence present or no handoff.md at '${second_rundir:-<empty>}'"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --clone-dir reuse fetches forward ==\n'
# ---------------------------------------------------------------------------

# A ref that lands in the origin AFTER a seat workspace was cloned (here:
# after both wakes above) must become visible as origin/<name> in the SAME
# workspace on its very next wake -- a reused clone's remote-tracking refs
# are exactly as stale as its last fetch, and the reuse path must re-fetch
# every time, not just on first clone.
git -C "$flow_proj" branch fs-clonedir-new-origin-branch >/dev/null 2>&1

third_result="$(run_and_capture "$flow_home" "$flow_proj" \
    --branch fs-clonedir-b3 --clone-dir "$flow_clone")"
third_rc=$?
register_paths "$third_result"

if (( third_rc == 0 )); then
    ok "third wake: launch succeeds reusing --clone-dir again"
else
    no "third wake: launch succeeds reusing --clone-dir again" "$third_result"
fi
if git -C "$flow_clone" rev-parse --verify --quiet \
        origin/fs-clonedir-new-origin-branch >/dev/null; then
    ok "third wake: a branch added to the origin after cloning is fetched on reuse"
else
    no "third wake: a branch added to the origin after cloning is fetched on reuse" \
        "origin/fs-clonedir-new-origin-branch did not resolve in $flow_clone"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --clone-dir edge cases ==\n'
# ---------------------------------------------------------------------------

# A --clone-dir target that is a git repo with zero commits (no HEAD to
# resolve) falls back to the origin project's HEAD instead of failing.
empty_home="$(mktmp_dir "$scratch/fs-clonedir-home2.XXXXXX")"
empty_proj="$(new_project "$empty_home")"
empty_clone="$(mktmp_dir "$scratch/fs-clonedir-empty.XXXXXX")"
# A real previous-wake clone always has an 'origin' remote (fs_make_clone
# sets one up), even in the pathological case its HEAD is unresolvable, so
# the fixture needs one too for the reuse path's fetch to have somewhere to
# fetch from.
git init -q "$empty_clone" >/dev/null 2>&1
git -C "$empty_clone" remote add origin "$empty_proj" >/dev/null 2>&1

empty_result="$(run_and_capture "$empty_home" "$empty_proj" \
    --branch fs-clonedir-empty-b --clone-dir "$empty_clone")"
empty_rc=$?
register_paths "$empty_result"

if (( empty_rc == 0 )); then
    ok "unresolvable-HEAD clone_dir: launch still succeeds"
else
    no "unresolvable-HEAD clone_dir: launch still succeeds" "$empty_result"
fi
empty_clone_head="$(git -C "$empty_clone" rev-parse HEAD 2>/dev/null)"
empty_proj_head="$(git -C "$empty_proj" rev-parse HEAD 2>/dev/null)"
if [[ -n "$empty_clone_head" && "$empty_clone_head" == "$empty_proj_head" ]]; then
    ok "unresolvable-HEAD clone_dir: falls back to the origin project's HEAD"
else
    no "unresolvable-HEAD clone_dir: falls back to the origin project's HEAD" \
        "clone HEAD=$empty_clone_head project HEAD=$empty_proj_head"
fi

# A --clone-dir target that exists but is not a git repository at all is a
# hard error distinct from the not-reachable / not-a-directory refusals above.
notrepo_home="$(mktmp_dir "$scratch/fs-clonedir-home3.XXXXXX")"
notrepo_proj="$(new_project "$notrepo_home")"
notrepo_clone="$(mktmp_dir "$scratch/fs-clonedir-notrepo.XXXXXX")"
printf 'not a git repo\n' > "$notrepo_clone/some-file"

notrepo_out="$(HOME="$notrepo_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$(mktmp_dir "$scratch/fs-clonedir-cfg2.XXXXXX")" \
    FAKE_ARGV_FILE="$(mktemp "$scratch/fs-clonedir-argv2.XXXXXX")" \
    timeout 60 "$launcher" --foreground --harness claude \
    --branch fs-clonedir-notrepo-b --clone-dir "$notrepo_clone" \
    "$notrepo_proj" "$refusal_handoff" 2>&1)"
notrepo_rc=$?
if (( notrepo_rc != 0 )) && printf '%s' "$notrepo_out" | grep -qF "exists and is not a git"; then
    ok "--clone-dir naming a non-git directory is a hard error"
else
    no "--clone-dir naming a non-git directory is a hard error" "$notrepo_out"
fi

# ---------------------------------------------------------------------------
printf '\n== fork-sandbox.sh: --clone-dir workspace lock ==\n'
# ---------------------------------------------------------------------------

# Belt and braces on top of the postmaster's own single-writer routing: two
# runs given the same --clone-dir at once must not both touch that git
# working tree. Hold the lock file externally, the same way a concurrent
# fork-sandbox.sh run would, and confirm this run refuses rather than races
# it -- then confirm the workspace is usable again once that hold is gone.
lock_home="$(mktmp_dir "$scratch/fs-clonedir-home4.XXXXXX")"
lock_proj="$(new_project "$lock_home")"
lock_clone="$(mktmp_dir "$scratch/fs-clonedir-lock.XXXXXX")"
git init -q "$lock_clone" >/dev/null 2>&1
git -C "$lock_clone" remote add origin "$lock_proj" >/dev/null 2>&1

lock_marker="$(mktemp "$scratch/fs-clonedir-lockmarker.XXXXXX")"
tmpdirs+=("$lock_marker")
rm -f -- "$lock_marker"

(
    exec {lock_fd}<>"$lock_clone/.git/fork-sandbox-lock"
    if flock -n "$lock_fd"; then
        touch "$lock_marker"
        sleep 30
    fi
) &
lock_holder_pid=$!

# Wait for the external holder to actually acquire the lock (up to 5s) before
# racing the launcher against it.
for _ in $(seq 1 50); do
    [[ -e "$lock_marker" ]] && break
    sleep 0.1
done

locked_out="$(HOME="$lock_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$(mktmp_dir "$scratch/fs-clonedir-cfg3.XXXXXX")" \
    FAKE_ARGV_FILE="$(mktemp "$scratch/fs-clonedir-argv3.XXXXXX")" \
    timeout 60 "$launcher" --foreground --harness claude \
    --branch fs-clonedir-locked-b --clone-dir "$lock_clone" \
    "$lock_proj" "$refusal_handoff" 2>&1)"
locked_rc=$?

# Kill the sleep this subshell forked first -- it inherits the locked fd, so
# killing only the subshell leaves it as an orphan still holding the lock.
pkill -TERM -P "$lock_holder_pid" 2>/dev/null
kill "$lock_holder_pid" 2>/dev/null
wait "$lock_holder_pid" 2>/dev/null

if (( locked_rc != 0 )) && printf '%s' "$locked_out" | grep -qF "is locked by another run"; then
    ok "--clone-dir refuses to start against a locked workspace"
else
    no "--clone-dir refuses to start against a locked workspace" "$locked_out"
fi

# The lock must be taken BEFORE the reuse path fetches/checks out a branch,
# not after: a run that loses the race has to refuse before it touches the
# live holder's git state, not after it has already switched the checked-out
# branch out from under it.
if git -C "$lock_clone" rev-parse --verify --quiet fs-clonedir-locked-b >/dev/null; then
    no "--clone-dir refuses before checking out a branch in the locked workspace" \
        "found branch fs-clonedir-locked-b in $lock_clone"
else
    ok "--clone-dir refuses before checking out a branch in the locked workspace"
fi

unlocked_out="$(HOME="$lock_home" PATH="$stub_bin:$PATH" \
    FORK_SANDBOX_CONFIG_DIR="$(mktmp_dir "$scratch/fs-clonedir-cfg4.XXXXXX")" \
    FAKE_ARGV_FILE="$(mktemp "$scratch/fs-clonedir-argv4.XXXXXX")" \
    timeout 60 "$launcher" --foreground --harness claude \
    --branch fs-clonedir-unlocked-b --clone-dir "$lock_clone" \
    "$lock_proj" "$refusal_handoff" 2>&1)"
unlocked_rc=$?
if (( unlocked_rc == 0 )); then
    ok "--clone-dir succeeds once the external lock is released"
else
    no "--clone-dir succeeds once the external lock is released" "$unlocked_out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
