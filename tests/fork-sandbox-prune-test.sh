#!/usr/bin/env bash
# fork-sandbox-prune-test.sh — Exercise `fork-sandbox prune` against fake run dirs
#
# Usage: tests/fork-sandbox-prune-test.sh
#
# Every run dir here is fabricated inside a throwaway forks root
# (FORK_SANDBOX_PRUNE_ROOT); nothing ever points at the real one. That root
# is itself made under the scratch forks/ directory with a
# claude-fork-sandbox. prefix only so that fork-sandbox-status.sh, which
# accepts nothing else, will read the run dirs inside it afterwards.
#
# It covers:
#   - --dry-run lists exactly the eligible runs and deletes nothing.
#   - a live run (pid or tmux session), an unfetched run, a run with
#     uncommitted work (counted or unknown), a run younger than the
#     retention, a run that has not ended, a --k8s run and non-run
#     directories are never pruned, each counted under its own reason.
#   - age is measured from summary.json's ended_at, not the dir's mtime.
#   - a symlinked clone, a symlinked run dir and a run dir whose clone
#     resolves elsewhere are never followed or deleted.
#   - a real prune removes clone/ only (read-only subdirectories too),
#     leaves a clone-pruned marker, reports bytes and a total, and a
#     second prune counts it as already pruned.
#   - status and status --result still work on a pruned run dir, and the
#     clone: line says it was pruned.
#   - a held lock makes a second prune exit 0 without doing anything.
#   - --auto reads FORK_SANDBOX_RUN_RETENTION_DAYS from runs.env, prints
#     nothing, logs one line, and does nothing at all with retention 0.

# ok always succeeds, so `test && ok .. || no ..` never runs both.
# shellcheck disable=SC2015
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
prune="$repo_dir/scripts/fork-sandbox-prune.sh"
status="$repo_dir/scripts/fork-sandbox-status.sh"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}
has() {
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else no "$1" "no '$2' in: $3"; fi
}
lacks() {
    if [[ "$3" != *"$2"* ]]; then ok "$1"; else no "$1" "unexpected '$2' in: $3"; fi
}

mkdir -p /var/tmp/claude-scratch/forks
root="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.prune-test.XXXXXX)"
outside="$(mktemp -d)"
config="$(mktemp -d)"
stub_bin="$(mktemp -d)"
sleeper=""
lock_holder=""
cleanup() {
    [[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null
    [[ -n "$lock_holder" ]] && kill "$lock_holder" 2>/dev/null
    chmod -R u+rwx "$root" "$outside" 2>/dev/null
    rm -rf -- "$root" "$outside" "$config" "$stub_bin"
}
trap cleanup EXIT

export FORK_SANDBOX_PRUNE_ROOT="$root"
export FORK_SANDBOX_CONFIG_DIR="$config"
# A tmux stub, so the suite never asks a real tmux server which sessions
# exist: it names exactly the sessions listed in $stub_bin/sessions.
cat > "$stub_bin/tmux" <<EOF
#!/usr/bin/env bash
[[ "\$1" == list-sessions ]] || exit 1
cat "$stub_bin/sessions" 2>/dev/null
EOF
chmod +x "$stub_bin/tmux"
: > "$stub_bin/sessions"
export PATH="$stub_bin:$PATH"

now="$(date +%s)"
day=86400
dead_pid=999999999

# make_run NAME [key=value ...] -- a run dir as the launcher and runner
# leave it, ended 30 days ago, fetched, nothing uncommitted. Keys override:
# fetched, uncommitted (raw JSON), ended_at (raw JSON, or "absent"),
# summary (no to omit), pid, session, network.
make_run() {
    local name="$1"; shift
    local fetched=true uncommitted=0 ended_at=$(( now - 30 * day ))
    local summary=yes pid="$dead_pid" session="" network=""
    local kv
    for kv in "$@"; do
        case "$kv" in
            fetched=*) fetched="${kv#*=}" ;;
            uncommitted=*) uncommitted="${kv#*=}" ;;
            ended_at=*) ended_at="${kv#*=}" ;;
            summary=*) summary="${kv#*=}" ;;
            pid=*) pid="${kv#*=}" ;;
            session=*) session="${kv#*=}" ;;
            network=*) network="${kv#*=}" ;;
        esac
    done
    local rd="$root/claude-fork-sandbox.$name"
    mkdir -p "$rd/clone/repo/.git" "$rd/outbox" "$rd/scripts"
    head -c 65536 /dev/zero > "$rd/clone/repo/big.bin"
    printf 'x\n' > "$rd/clone/repo/.git/HEAD"
    {
        printf 'version=1\n'
        printf 'run_dir=/var/tmp/claude-scratch/forks/claude-fork-sandbox.%s\n' "$name"
        printf 'origin_repo=/tmp/origin\nclone_dir=%s/clone/repo\n' "$rd"
        printf 'branch=sbx-%s\nstarted_at=%s\n' "$name" "$(( now - 31 * day ))"
        [[ -n "$session" ]] && printf 'session=%s\n' "$session"
        [[ -n "$network" ]] && printf 'network=%s\n' "$network"
    } > "$rd/run.env"
    printf '%s\n' "$pid" > "$rd/pid"
    printf '{"type":"result","subtype":"success","result":"session account %s"}\n' "$name" > "$rd/events.jsonl"
    printf 'reply\n' > "$rd/outbox/reply.md"
    if [[ "$summary" == yes ]]; then
        printf '0\n' > "$rd/exit-code"
        printf 'fetched:   yes. Branch sbx-%s is now in /tmp/origin\n' "$name" > "$rd/summary.txt"
        if [[ "$ended_at" == absent ]]; then
            jq -n --argjson f "$fetched" --argjson u "$uncommitted" \
                '{version:1, exit_code:0, fetched:$f, uncommitted_files:$u}' > "$rd/summary.json"
        else
            jq -n --argjson f "$fetched" --argjson u "$uncommitted" --argjson e "$ended_at" \
                '{version:1, exit_code:0, fetched:$f, uncommitted_files:$u, ended_at:$e}' > "$rd/summary.json"
        fi
    fi
    printf '%s' "$rd"
}

# ---------------------------------------------------------------------------
printf '== eligibility and --dry-run ==\n'

sleep 600 &
sleeper=$!

eligible_a="$(make_run eligA)"
eligible_b="$(make_run eligB ended_at=$(( now - 15 * day )))"
live_pid="$(make_run livepid pid="$sleeper")"
live_tmux="$(make_run livetmux session=sbx-live-session)"
printf 'sbx-live-session\n' > "$stub_bin/sessions"
unfetched="$(make_run unfetched fetched=false)"
uncommitted="$(make_run uncommitted uncommitted=3)"
unknown="$(make_run unknown uncommitted=null)"
young="$(make_run young ended_at=$(( now - 2 * day )))"
running="$(make_run running summary=no)"
k8s="$(make_run k8s network=cluster)"
noend="$(make_run noend ended_at=absent)"
# Not a run dir: matches the name pattern, but no launcher run.env.
mkdir -p "$root/claude-fork-sandbox.notarun/clone/stuff"
# A run.env that names some other directory is not this launcher's layout.
foreign="$(make_run foreign)"
sed -i 's#^run_dir=.*#run_dir=/elsewhere/claude-fork-sandbox.other#' "$foreign/run.env"
# Another tool's directory under the root: not even looked at.
mkdir -p "$root/claude-fork-codex.abc/clone"
# Age comes from ended_at, not mtime: an old mtime on a young run...
touch -d '@'"$(( now - 100 * day ))" "$young"
# ...and a fresh mtime on an old one.
touch "$eligible_a"

# A symlinked clone pointing at a fully-eligible-looking target outside.
symclone="$(make_run symclone)"
rm -rf -- "$symclone/clone"
mkdir -p "$outside/victim"
printf 'keep\n' > "$outside/victim/precious"
ln -s "$outside/victim" "$symclone/clone"
# A symlinked run dir: the link is under the root, the run dir is not.
outside_run="$(make_run outsiderun)"
mv -- "$outside_run" "$outside/claude-fork-sandbox.outsiderun"
ln -s "$outside/claude-fork-sandbox.outsiderun" "$outside_run"

out="$("$prune" --dry-run 2>&1)"
rc=$?
check 'dry-run exits 0' 0 "$rc"
check 'dry-run lists exactly the eligible runs' \
    "$(printf '%s\n' "$eligible_a" "$eligible_b" | sort)" \
    "$(printf '%s\n' "$out" | sed -n 's/^would prune  \([^ ]*\)  .*/\1/p' | sort)"
has 'dry-run reports a total' 'total: would prune 2 run(s) older than 14 days' "$out"
for rd in "$eligible_a" "$eligible_b"; do
    if [[ -f "$rd/clone/repo/big.bin" && ! -e "$rd/clone-pruned" ]]; then
        ok "dry-run deleted nothing in ${rd##*/}"
    else
        no "dry-run deleted nothing in ${rd##*/}"
    fi
done
has 'live counted' 'live                 2' "$out"
has 'unfetched counted' 'not-fetched          1' "$out"
has 'uncommitted work counted' 'uncommitted-work     1' "$out"
has 'unknown uncommitted state counted' 'uncommitted-unknown  1' "$out"
has 'young run counted' 'too-recent           1' "$out"
has 'unended run counted' 'not-ended            1' "$out"
has 'k8s run counted' 'k8s-run              1' "$out"
has 'missing ended_at counted' 'no-end-time          1' "$out"
has 'non-run dirs counted' 'not-a-run            2' "$out"
has 'symlinks counted as unsafe' 'unsafe-path          2' "$out"
lacks 'other tools dirs not looked at' 'codex' "$out"

out14="$("$prune" --dry-run --older-than 20 2>&1)"
check '--older-than narrows the set' "$eligible_a" \
    "$(printf '%s\n' "$out14" | sed -n 's/^would prune  \([^ ]*\)  .*/\1/p')"

"$prune" --older-than abc >/dev/null 2>&1
check '--older-than must be a number' 2 "$?"

# ---------------------------------------------------------------------------
printf '== a real prune ==\n'

# A sandboxed tool can leave directories without owner write permission.
mkdir -p "$eligible_a/clone/repo/ro/inner"
printf 'x\n' > "$eligible_a/clone/repo/ro/inner/f"
chmod a-w "$eligible_a/clone/repo/ro/inner" "$eligible_a/clone/repo/ro"

out="$("$prune" 2>&1)"
rc=$?
check 'prune exits 0' 0 "$rc"
has 'prune names the run dir and bytes' "pruned  $eligible_a  " "$out"
has 'prune reports a total' 'total: pruned 2 run(s) older than 14 days, freed' "$out"
for rd in "$eligible_a" "$eligible_b"; do
    n="${rd##*/}"
    if [[ ! -e "$rd/clone" ]]; then ok "clone removed: $n"; else no "clone removed: $n"; fi
    if [[ -f "$rd/run.env" && -f "$rd/summary.json" && -f "$rd/events.jsonl" \
        && -f "$rd/exit-code" && -f "$rd/outbox/reply.md" && -d "$rd/scripts" \
        && -f "$rd/pid" && -f "$rd/summary.txt" ]]; then
        ok "everything but the clone kept: $n"
    else
        no "everything but the clone kept: $n" "$(ls -A "$rd")"
    fi
    if grep -qE '^pruned_at=[0-9]+$' "$rd/clone-pruned" && grep -qE '^bytes=[0-9]+$' "$rd/clone-pruned"; then
        ok "marker records when and how much: $n"
    else
        no "marker records when and how much: $n" "$(cat "$rd/clone-pruned" 2>&1)"
    fi
done
for rd in "$live_pid" "$live_tmux" "$unfetched" "$uncommitted" "$unknown" \
    "$young" "$running" "$k8s" "$noend" "$foreign" "$root/claude-fork-sandbox.notarun"; do
    if [[ -d "$rd/clone" && ! -e "$rd/clone-pruned" ]]; then
        ok "never pruned: ${rd##*/}"
    else
        no "never pruned: ${rd##*/}"
    fi
done
[[ -d "$root/claude-fork-codex.abc/clone" ]] && ok 'other tools dir untouched' || no 'other tools dir untouched'
if [[ -f "$outside/victim/precious" && -L "$symclone/clone" ]]; then
    ok 'symlinked clone neither followed nor removed'
else
    no 'symlinked clone neither followed nor removed'
fi
if [[ -d "$outside/claude-fork-sandbox.outsiderun/clone/repo" && -L "$outside_run" ]]; then
    ok 'run dir resolving outside the root untouched'
else
    no 'run dir resolving outside the root untouched'
fi

out="$("$prune" --dry-run 2>&1)"
has 'a second prune counts it as already pruned' 'already-pruned       2' "$out"
lacks 'and lists nothing to prune' 'would prune  ' "$out"

# A run whose ended_at is past the cutoff once the clock has moved on is
# picked up by a later prune: the young run is still too young, though.
out="$("$prune" --older-than 1 --dry-run 2>&1)"
has 'a shorter retention picks up the younger run' "would prune  $young  " "$out"

# ---------------------------------------------------------------------------
printf '== status on a pruned run dir ==\n'

out="$("$status" "$eligible_a" 2>&1)"
rc=$?
check 'status exits 0 after a prune' 0 "$rc"
has 'status says the clone was pruned' "clone:    $eligible_a/clone/repo (pruned " "$out"
out="$("$status" --result "$eligible_a" 2>&1)"
rc=$?
check 'status --result exits 0 after a prune' 0 "$rc"
has 'status --result still shows the session account' 'session account eligA' "$out"
out="$("$status" --json "$eligible_a" 2>&1)"
check 'status --json still reads summary.json' true "$(jq -r '.fetched' <<<"$out" 2>/dev/null)"
out="$("$status" "$young" 2>&1)"
lacks 'an unpruned run has no pruned note' '(pruned' "$out"

# ---------------------------------------------------------------------------
printf '== the lock ==\n'

lockable="$(make_run lockable)"
# exec, so the pid killed below is the very process holding the lock.
( exec 9>>"$root/.fork-sandbox-prune.lock"; flock 9; exec sleep 30 ) &
lock_holder=$!
for _ in $(seq 50); do
    flock -n "$root/.fork-sandbox-prune.lock" true 2>/dev/null || break
    sleep 0.1
done
start=$SECONDS
out="$("$prune" 2>&1)"
rc=$?
check 'a second prune exits 0' 0 "$rc"
(( SECONDS - start < 5 )) && ok 'and does not wait for the lock' || no 'and does not wait for the lock'
[[ -d "$lockable/clone" ]] && ok 'and prunes nothing' || no 'and prunes nothing'
lacks 'and lists nothing' 'pruned  ' "$out"
out="$("$prune" --auto 2>&1)"
check '--auto under a held lock is silent' '' "$out"
kill "$lock_holder" 2>/dev/null; wait "$lock_holder" 2>/dev/null; lock_holder=""

# ---------------------------------------------------------------------------
printf '== --auto and the retention key ==\n'

log="$root/.fork-sandbox-prune.log"
rm -f -- "$log"
printf 'FORK_SANDBOX_RUN_RETENTION_DAYS=0\n' > "$config/runs.env"
out="$("$prune" --auto 2>&1)"
check 'retention 0: --auto prints nothing' '' "$out"
[[ -d "$lockable/clone" ]] && ok 'retention 0: --auto prunes nothing' || no 'retention 0: --auto prunes nothing'
[[ ! -e "$log" ]] && ok 'retention 0: --auto logs nothing' || no 'retention 0: --auto logs nothing'
out="$("$prune" --dry-run 2>&1)"
has 'retention 0 does not disable the verb' "would prune  $lockable  " "$out"

printf 'FORK_SANDBOX_RUN_RETENTION_DAYS=soon\n' > "$config/runs.env"
"$prune" --auto >/dev/null 2>&1
[[ -d "$lockable/clone" ]] && ok 'an invalid retention prunes nothing' || no 'an invalid retention prunes nothing'
has 'an invalid retention is logged' "FORK_SANDBOX_RUN_RETENTION_DAYS='soon'" "$(cat "$log" 2>/dev/null)"
rm -f -- "$log"

printf 'FORK_SANDBOX_RUN_RETENTION_DAYS=60\n' > "$config/runs.env"
"$prune" --auto >/dev/null 2>&1
[[ -d "$lockable/clone" ]] && ok 'retention 60 keeps a 30-day-old run' || no 'retention 60 keeps a 30-day-old run'
out="$("$prune" --dry-run 2>&1)"
has 'the configured retention is the verb default' 'older than 60 days' "$out"
rm -f -- "$log"

printf 'FORK_SANDBOX_RUN_RETENTION_DAYS=7\n' > "$config/runs.env"
out="$("$prune" --auto 2>&1)"
check '--auto prints nothing' '' "$out"
[[ ! -e "$lockable/clone" ]] && ok '--auto prunes with the configured retention' || no '--auto prunes with the configured retention'
check '--auto logs exactly one line' 1 "$(wc -l < "$log" 2>/dev/null | tr -d ' ')"
has '--auto log line says what it did' 'prune --auto (retention 7 days): pruned 1 run(s)' "$(cat "$log" 2>/dev/null)"

"$prune" --auto --dry-run >/dev/null 2>&1
check '--auto takes no other option' 2 "$?"

printf '\n%d ok / %d fail\n' "$pass" "$fail"
(( fail == 0 ))
