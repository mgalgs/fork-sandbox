#!/usr/bin/env bash
# fork-sandbox-resume-orchestration-test.sh — --resume <state-dir>: one
# conversation, one moving branch, across many submits
#
# Usage: tests/fork-sandbox-resume-orchestration-test.sh
#
# A client program drives fork-sandbox as its agent backend: one state dir
# per conversation, submitting a note, polling status --json, and
# submitting the next note into the same state dir once the last one
# replies. This exercises the LOCAL path end to end, through a stub
# claude-sandboxed (records nothing; just commits, same recipe
# tests/fork-sandbox-tidy-test.sh uses) and a no-op
# sandbox-backend-fake-image stub, so no real sandbox is built and no real
# claude runs. --k8s's own submit/collect plumbing already has its
# dedicated coverage in tests/fork-sandbox-k8s-test.sh; this suite's
# --k8s cases are limited to the flag-wiring fork-sandbox.sh itself does
# before handing off (--allow-existing-branch forwarded, --resume's own
# flags refused), not a full detached submit against a stub cluster.
#
# It covers:
#   - a fresh state dir's first submit: no --base, a fresh branch, prints
#     exactly the run dir, returns promptly.
#   - a repeat submit of the SAME note path: prints the same run dir,
#     starts nothing new (no second commit).
#   - a second submit with --base <the first run's branch>: the SAME
#     branch name, fast-forwarded (both commits present), not a fresh one.
#   - --base without --resume, and --resume alongside a flag it manages
#     itself (--session-state, --branch, ...), are refused up front.
#   - a second, different note submitted while the first run's state dir
#     is locked is refused, never racing the session store.
#   - status --json reports state: replied with a reply_file once the run
#     finishes.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
status_sh="$repo_dir/scripts/fork-sandbox-status.sh"
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()

real_tmux="$(command -v tmux)"
sock_log="$(mktemp /var/tmp/claude-scratch/fs-resumeorch-socks.XXXXXX)"

cleanup() {
    local d s
    # Only ever by -L name: a bare kill-server follows $TMUX to the
    # caller's own server.
    while IFS= read -r s; do
        [[ -n "$s" ]] && "$real_tmux" -L "$s" kill-server >/dev/null 2>&1
    done < "$sock_log"
    rm -f -- "$sock_log"
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

refuses() {
    local label="$1" needle="$2"; shift 2
    local out
    if out="$("$@" 2>&1)"; then
        no "$label" "exited 0: $out"
        return
    fi
    if [[ "$out" == *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "missing '$needle': $out"
    fi
}

mktmp_dir() { local d; d="$(mktemp -d "$1")"; tmpdirs+=("$d"); printf '%s' "$d"; }

launcher_home="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-home.XXXXXX)"
mkdir -p "$launcher_home/src"
real_cfg="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-cfg.XXXXXX)"
printf 'OPENROUTER_API_KEY=fake\n' > "$real_cfg/pi.env"
printf 'MODEL_ENDPOINT=http://198.51.100.1:8001/v1\n' > "$real_cfg/model.env"

real_stub="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-stub.XXXXXX)"
cat > "$real_stub/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
# Scripted one action per call, same shape tests/fork-sandbox-tidy-test.sh's
# own stub uses: "commit" makes a plain empty commit, "hang N" sleeps N
# seconds first (so the lock-contention case below has a real window to
# submit a second note into), anything else is a no-op success.
count_file="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-count.XXXXXX)/n"
script_file="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-script.XXXXXX)/actions"
: > "$script_file"
cat > "$real_stub/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
clone_dir="" prev=""
for a in "$@"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && clone_dir="$prev"
    prev="$a"
done
prompt="$(cat)"
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n="$(cat "$FAKE_COUNT_FILE")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FAKE_COUNT_FILE"
action="$(sed -n "${n}p" "$FAKE_SCRIPT" 2>/dev/null)"
if [[ "${FAKE_WRITE_REPLY:-}" == 1 ]]; then
    reply_dir="$(printf '%s\n' "$prompt" | awk '/^## Artifact outbox$/{seen=1; next} seen && /^    \/var\/tmp\// {sub(/^    /, ""); print; exit}')"
    [[ -z "$reply_dir" ]] || printf 'local agent reply\n' > "$reply_dir/reply.md"
elif [[ "${FAKE_WRITE_REPLY:-}" == fifo ]]; then
    reply_dir="$(printf '%s\n' "$prompt" | awk '/^## Artifact outbox$/{seen=1; next} seen && /^    \/var\/tmp\// {sub(/^    /, ""); print; exit}')"
    [[ -z "$reply_dir" ]] || mkfifo "$reply_dir/reply.md"
fi
case "$action" in
    hang*)
        sleep "${action#hang }"
        ;;
esac
git -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    -C "$clone_dir" commit --allow-empty -q -m "resumeorch commit $n"
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
cat > "$real_stub/tmux" <<STUB
#!/usr/bin/env bash
exec "$real_tmux" -L "\${FS_TEST_TMUX_SOCKET:?}" "\$@"
STUB
chmod +x "$real_stub"/*

new_project() {
    local d
    d="$(mktmp_dir "$launcher_home/src/proj.XXXXXX")"
    (
        cd "$d" && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# A detached run's tmux pane takes its environment from the server, not
# from the launcher, so the stub's FAKE_* variables reach it only from a
# server this launch starts. Every launch gets a fresh private socket.
new_sock() {
    local s="fs-resumeorch-$$-$BASHPID-$RANDOM"
    printf '%s\n' "$s" >> "$sock_log"
    printf '%s' "$s"
}

run_fs() {
    FS_TEST_TMUX_SOCKET="$(new_sock)" \
    HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count_file" \
    FAKE_SCRIPT="$script_file" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FS_LEG_RETRY_DELAYS="0 0" \
    timeout 60 "$launcher" "$@"
}

# Polls the way a client does: replied promises the branch and reply_file.
wait_for_reply() {
    local rd="$1" st
    for _ in $(seq 1 100); do
        st="$("$status_sh" --json "$rd" 2>/dev/null | jq -r '.state' 2>/dev/null)"
        [[ "$st" == replied || "$st" == failed ]] && return 0
        sleep 0.2
    done
    return 1
}

wait_for_exit_code() {
    local rd="$1"
    for _ in $(seq 1 100); do
        [[ -e "$rd/exit-code" ]] && return 0
        sleep 0.2
    done
    return 1
}

# ---------------------------------------------------------------------------
printf '\n== --resume: the refusals, before anything is created ==\n'
# ---------------------------------------------------------------------------
proj0="$(new_project)"
note0_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-notes0.XXXXXX)"
note0="$note0_dir/note.md"
printf 'do the thing\n' > "$note0"

refuses "--base without --resume is refused" "--base requires --resume" \
    run_fs --base some-branch "$proj0" "$note0"
refuses "--resume with --session-state is refused" \
    "is not accepted alongside it" \
    run_fs --resume "$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-sd.XXXXXX)" \
        --session-state "$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-ss.XXXXXX)" \
        "$proj0" "$note0"
refuses "--resume with --branch is refused" \
    "is not accepted alongside it" \
    run_fs --resume "$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-sd2.XXXXXX)" \
        --branch some-branch "$proj0" "$note0"
refuses "--resume outside the scratch root is refused" \
    "must name a directory under" \
    run_fs --resume /tmp/not-under-scratch "$proj0" "$note0"

# ---------------------------------------------------------------------------
printf '\n== --resume: first submit starts a fresh conversation, no --base ==\n'
# ---------------------------------------------------------------------------
proj1="$(new_project)"
state1="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-state1.XXXXXX)"
notes1_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-notes1.XXXXXX)"
note1="$notes1_dir/note1.md"
printf 'first note\n' > "$note1"
: > "$script_file"
printf 'commit\n' >> "$script_file"

rd1="$(FAKE_WRITE_REPLY=1 run_fs --resume "$state1" --harness claude "$proj1" "$note1")"
rc1=$?
check "submit 1: exits 0" "0" "$rc1"
if [[ -n "$rd1" && -d "$rd1" ]]; then
    ok "submit 1: printed a real run dir"
else
    no "submit 1: printed a real run dir" "got: '$rd1'"
fi
wait_for_reply "$rd1" || true
check "submit 1: the run exits 0" "0" "$(cat "$rd1/exit-code" 2>/dev/null)"
check "submit 1: the local agent's reply survives rendering" \
    "local agent reply" "$(cat "$rd1/outbox/reply.md" 2>/dev/null)"
branch1="$(sed -n 's/^branch=//p' "$rd1/run.env" 2>/dev/null | head -1)"
if [[ -n "$branch1" ]]; then
    ok "submit 1: a fresh branch was minted"
else
    no "submit 1: a fresh branch was minted" "no branch= in run.env"
fi
check "submit 1: branch1 has exactly 2 commits (init + the new one)" \
    "2" "$(git -C "$proj1" rev-list --count "$branch1" 2>/dev/null)"
check "submit 1: the branch carries one new commit" \
    "resumeorch commit 1" "$(git -C "$proj1" log -1 --format=%s "$branch1" 2>/dev/null)"

# ---------------------------------------------------------------------------
printf '\n== --resume: a repeat submit of the SAME note is idempotent ==\n'
# ---------------------------------------------------------------------------
rd1_count_before="$(cat "$count_file")"
rd1b="$(run_fs --resume "$state1" --harness claude "$proj1" "$note1")"
check "repeat submit: prints the same run dir" "$rd1" "$rd1b"
check "repeat submit: no second claude-sandboxed call" \
    "$rd1_count_before" "$(cat "$count_file")"

# submit 1's own detached worker releases the state dir's lock only once
# its poll loop next notices the exit-code file (up to its own poll
# interval after the run actually finished) -- give it a moment, so
# submit 2 below does not race a lock that is still draining down.
sleep 3

# ---------------------------------------------------------------------------
printf '\n== --resume --base: continues the SAME branch, fast-forwarded ==\n'
# ---------------------------------------------------------------------------
note2="$notes1_dir/note2.md"
printf 'second note\n' > "$note2"
printf 'commit\n' >> "$script_file"

rd2="$(run_fs --resume "$state1" --base "$branch1" --harness claude "$proj1" "$note2")"
rc2=$?
check "submit 2 (--base): exits 0" "0" "$rc2"
wait_for_reply "$rd2" || true
check "submit 2: the run exits 0" "0" "$(cat "$rd2/exit-code" 2>/dev/null)"
branch2="$(sed -n 's/^branch=//p' "$rd2/run.env" 2>/dev/null | head -1)"
check "submit 2: reuses the exact same branch name" "$branch1" "$branch2"
check "submit 2: checkout started from branch1's own tip" \
    "$branch1" "$(sed -n 's/^checkout=//p' "$rd2/run.env" 2>/dev/null | head -1)"
check "submit 2: the branch now carries BOTH commits (fast-forwarded, not replaced)" \
    "3" "$(git -C "$proj1" rev-list --count "$branch1" 2>/dev/null)"
check "submit 2: run2's own commit is the new tip" \
    "resumeorch commit 2" "$(git -C "$proj1" log -1 --format=%s "$branch1" 2>/dev/null)"
check "submit 2: run1's commit is still reachable (fast-forward, not a reset)" \
    "resumeorch commit 1" "$(git -C "$proj1" log -2 --format=%s "$branch1" 2>/dev/null | tail -1)"

# ---------------------------------------------------------------------------
printf '\n== --resume: status --json reports state: replied with a reply_file ==\n'
# ---------------------------------------------------------------------------
json2="$("$status_sh" --json "$rd2" 2>&1)"
check "status --json: state is replied" "replied" "$(jq -r '.state' <<< "$json2" 2>/dev/null)"
check "status --json: reply_file is the run dir's outbox/reply.md" \
    "$rd2/outbox/reply.md" "$(jq -r '.reply_file' <<< "$json2" 2>/dev/null)"
if [[ -s "$rd2/outbox/reply.md" ]]; then
    ok "status --json: reply_file actually exists once replied"
else
    no "status --json: reply_file actually exists once replied" "$(ls -la "$rd2/outbox" 2>&1)"
fi
[[ -n "$rd1" && -d "$rd1" ]] && tmpdirs+=("$rd1")
[[ -n "$rd2" && -d "$rd2" ]] && tmpdirs+=("$rd2")

# ---------------------------------------------------------------------------
printf '\n== --resume: a second, different note while one is active is refused ==\n'
# ---------------------------------------------------------------------------
state3="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-state3.XXXXXX)"
proj3="$(new_project)"
notes3_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-notes3.XXXXXX)"
note3a="$notes3_dir/note-a.md"
printf 'note a\n' > "$note3a"
note3b="$notes3_dir/note-b.md"
printf 'note b\n' > "$note3b"
count_file3="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-count3.XXXXXX)/n"
script_file3="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-script3.XXXXXX)/actions"
printf 'hang 3\n' > "$script_file3"

# This submit returns as soon as its own tmux session is up, well before
# the stub's 3-second "hang" even starts -- but by then its detached
# worker already holds the state dir's lock for the hang's own duration
# (see fork-sandbox-resume-lib.sh's header on why the lock outlives this
# process), so the SECOND submit, right after, races a lock that is
# already held.
rd3a="$(FS_TEST_TMUX_SOCKET="$(new_sock)" \
    HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count_file3" \
    FAKE_SCRIPT="$script_file3" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FS_LEG_RETRY_DELAYS="0 0" \
    timeout 60 "$launcher" --resume "$state3" --harness claude "$proj3" "$note3a")"
out3b="$(FS_TEST_TMUX_SOCKET="$(new_sock)" \
    HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count_file3" \
    FAKE_SCRIPT="$script_file3" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FS_LEG_RETRY_DELAYS="0 0" \
    timeout 60 "$launcher" --resume "$state3" --harness claude "$proj3" "$note3b" 2>&1)"
rc3b=$?
if (( rc3b != 0 )) && [[ "$out3b" == *"already active"* ]]; then
    ok "a second, different note while one is active is refused"
else
    no "a second, different note while one is active is refused" \
        "rc=$rc3b out=$out3b"
fi
[[ -n "$rd3a" ]] && wait_for_exit_code "$rd3a"
[[ -n "$rd3a" ]] && tmpdirs+=("$rd3a")

printf '\n== --resume: a missing runner exit code fails and releases the lock ==\n'
proj4="$(new_project)"
state4="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-state4.XXXXXX)"
notes4_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-notes4.XXXXXX)"
note4a="$notes4_dir/note-a.md"; printf 'note a\n' > "$note4a"
note4b="$notes4_dir/note-b.md"; printf 'note b\n' > "$note4b"
count_file4="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-count4.XXXXXX)/n"
script_file4="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-script4.XXXXXX)/actions"
printf 'hang 30\ncommit\n' > "$script_file4"
rd4a="$(FS_TEST_TMUX_SOCKET="$(new_sock)" \
    HOME="$launcher_home" PATH="$real_stub:$PATH" FAKE_COUNT_FILE="$count_file4" \
    FAKE_SCRIPT="$script_file4" FORK_SANDBOX_CONFIG_DIR="$real_cfg" \
    FORK_SANDBOX_BACKEND=fake-image FS_LEG_RETRY_DELAYS="0 0" \
    timeout 60 "$launcher" --resume "$state4" --harness claude "$proj4" "$note4a")"
for _ in $(seq 1 100); do
    [[ -s "$rd4a/pid" && -s "$count_file4" ]] && break
    sleep 0.1
done
if [[ -s "$rd4a/pid" && -s "$count_file4" ]]; then
    ok "dead runner: hanging stub started"
    if kill -9 "$(cat "$rd4a/pid")" 2>/dev/null; then
        ok "dead runner: runner was killed"
    else
        no "dead runner: runner was killed"
    fi
else
    no "dead runner: hanging stub started"
fi
if wait_for_exit_code "$rd4a"; then
    check "dead runner: reports failed" "failed" \
        "$("$status_sh" --json "$rd4a" 2>/dev/null | jq -r '.state')"
else
    no "dead runner: writes a terminal exit code" "no exit-code after 20s"
fi
for _ in $(seq 1 40); do
    if flock -n "$state4/.fork-sandbox/lock" -c true 2>/dev/null; then break; fi
    sleep 0.1
done
if flock -n "$state4/.fork-sandbox/lock" -c true 2>/dev/null; then
    ok "dead runner: state lock was released"
else
    no "dead runner: state lock was released"
fi
tmpdirs+=("$rd4a")

printf '\n== --resume: a FIFO planted at reply.md cannot hang the runner ==\n'
proj5="$(new_project)"
state5="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-state5.XXXXXX)"
notes5_dir="$(mktmp_dir /var/tmp/claude-scratch/fs-resumeorch-notes5.XXXXXX)"
note5="$notes5_dir/note.md"; printf 'note\n' > "$note5"
: > "$script_file"; : > "$count_file"
printf 'commit\n' > "$script_file"
rd5="$(FAKE_WRITE_REPLY=fifo run_fs --resume "$state5" --harness claude "$proj5" "$note5")"
if [[ -n "$rd5" ]] && wait_for_reply "$rd5"; then
    ok "fifo reply: the run reaches a terminal state"
else
    no "fifo reply: the run reaches a terminal state" "state: $("$status_sh" --json "$rd5" 2>/dev/null | jq -r '.state' 2>/dev/null)"
    [[ -s "$rd5/pid" ]] && kill -9 "$(cat "$rd5/pid")" 2>/dev/null
fi
[[ -n "$rd5" && -d "$rd5" ]] && tmpdirs+=("$rd5")

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
