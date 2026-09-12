#!/usr/bin/env bash
# fork-sandbox-postmaster-test.sh — Exercise fork-sandbox-postmaster.sh's
# routing rules, wake spawning, and reply harvest against throwaway
# fixtures, stubbing fork-sandbox.sh the same way tests/lkml-round-test.sh
# stubbed it for lkml-round.sh.
#
# Usage: tests/fork-sandbox-postmaster-test.sh
#
# Real fork-sandbox-mail.sh and fork-sandbox-fleet.sh are used throughout
# (seeded with a small invented fleet); only fork-sandbox.sh is a stub
# resolved from PATH by bare name, matching how pm_spawn_wake invokes it.
# The stub records every invocation's argv (one arg per line, one
# "----CALL----" marker per call) and fabricates a run dir with an
# outbox/; tests control terminal state themselves by writing exit-code
# and outbox/mail-*.md files by hand, except where STUB_IMMEDIATE_EXIT is
# set.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
postmaster="$repo_dir/scripts/fork-sandbox-postmaster.sh"
MAIL="$repo_dir/scripts/fork-sandbox-mail.sh"
FLEET="$repo_dir/scripts/fork-sandbox-fleet.sh"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
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
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

refuses() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        no "$label" "it succeeded; output: $out"
    else
        ok "$label"
    fi
}

# Sets $1 to a fresh temp dir and registers it for cleanup -- a nameref
# out-param, same as fork-sandbox-fleet-test.sh's new_root.
new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

# Same as new_root, but under /var/tmp/claude-scratch: FORK_SANDBOX_MAIL_ROOT
# feeds fs_require_scratch_handoff via HANDOFFS at `deliver` startup (see
# fork-sandbox-postmaster.sh), so a bare mktemp -d root (usually under /tmp)
# would fail that check before ever reaching the routing logic under test.
new_scratch_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d /var/tmp/claude-scratch/fs-postmaster-test.XXXXXX)"
    tmpdirs+=("$out_ref")
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

# ---- shared fixtures: a small invented fleet, reused across most groups ----

new_root FORK_SANDBOX_FLEET_FILE_DIR
export FORK_SANDBOX_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE_DIR/fleet.yaml"
new_root FORK_SANDBOX_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR

cat > "$FORK_SANDBOX_PERSONAS_DIR/alice.md" <<'EOF'
---
model: opus
---
Alice reviews code carefully, flagging subtle bugs before they ship.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/bob.md" <<'EOF'
---
thinking: medium
---
Bob thinks slowly and precisely about edge cases.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/carol.md" <<'EOF'
Carol keeps her replies short.
EOF

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  alice: {}
  bob:
    harness: pi
    network: sealed
  carol: {}
lists:
  team:
    members: [alice, bob, carol]
EOF

if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

# ---- stub fork-sandbox.sh, resolved via FORK_SANDBOX_POSTMASTER_LAUNCHER
# (pm_spawn_wake resolves the real thing through script_dir, not PATH, so
# a plain PATH stub would be shadowed by the checkout's own scripts/) ----

new_root STUB_BIN
new_root STUB_RUN_PREFIX
export STUB_RUN_PREFIX
STUB_ARGV_LOG="$work/argv.log"
export STUB_ARGV_LOG
: > "$STUB_ARGV_LOG"

cat > "$STUB_BIN/fork-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf -- '----CALL----\n' >> "$STUB_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_ARGV_LOG"; done
run_dir="$(mktemp -d "$STUB_RUN_PREFIX/run.XXXXXX")"
mkdir -p -- "$run_dir/outbox"
if [[ -n "${STUB_IMMEDIATE_EXIT:-}" ]]; then
    printf '%s\n' "${STUB_IMMEDIATE_EXIT}" > "$run_dir/exit-code"
fi
echo "fork-sandbox: launched in a stub"
printf '  run dir:  %s\n' "$run_dir"
STUB
chmod +x "$STUB_BIN/fork-sandbox.sh"
export FORK_SANDBOX_POSTMASTER_LAUNCHER="$STUB_BIN/fork-sandbox.sh"

new_root PROJECT_DIR

# ---- test helpers ----

send_msg() {
    local from="$1" to="$2" subject="$3" body="$4" hops="${5:-8}" cc="${6:-}"
    printf '%s\n' "$body" > "$work/body.tmp"
    local -a extra=()
    [[ -n "$cc" ]] && extra=(--cc "$cc")
    "$MAIL" send --from "$from" --to "$to" --subject "$subject" \
        --body "$work/body.tmp" --hops "$hops" "${extra[@]}" 2>/dev/null
}

reply_msg() {
    local from="$1" reply_to="$2" body="$3"; shift 3
    printf '%s\n' "$body" > "$work/body.tmp"
    "$MAIL" reply --from "$from" --reply-to "$reply_to" --body "$work/body.tmp" "$@" 2>/dev/null
}

thread_of() { "$MAIL" show "$1" 2>/dev/null | sed -n 's/^Thread-ID: //p'; }
hops_of_mid() { "$MAIL" show "$1" 2>/dev/null | sed -n 's/^X-Hops: //p'; }
header_of_file() { sed -n "s/^$2: //p" "$1" | head -n1; }

once() {
    "$postmaster" deliver --project "$PROJECT_DIR" --once >"$work/once.out" 2>"$work/once.err"
}

once_rc() {
    "$postmaster" deliver --project "$PROJECT_DIR" --once >"$work/once.out" 2>"$work/once.err"
    echo $?
}

argv_after() {
    local flag="$1" file="$2"
    awk -v f="$flag" 'found{print; exit} $0==f{found=1}' "$file"
}

env_file_for_agent() {
    local agent="$1" f
    for f in "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env; do
        [[ -e "$f" ]] || continue
        grep -q "^AGENT=$agent\$" "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

spawn_count_of() {
    local tid="$1"
    local f="$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
    [[ -f "$f" ]] && wc -l < "$f" || printf '0'
}

# ============================================================
printf '\n== To wakes, Cc does not; list wakes every member once; direct+list dedup ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

mid="$(send_msg '@alice' '@bob' 'cc test' 'body for cc test' 8 '@carol')"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "To recipient (bob) spawns" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "Cc recipient (carol) does not spawn" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@carol' '@bob,@team' 'list dedup test' 'body for list dedup' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "list member alice wakes" 1 "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"
check "direct+list bob wakes exactly once" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "sender carol does not wake on her own message" 0 "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== a list member never wakes on a message they sent themselves ==\n'
# ============================================================

# Operator-seeded shape: @operator mails @team (alice/bob/carol), one of
# whom (bob) reply-alls. mail.sh's reply-all keeps @team in the parent's
# To: verbatim (it only strips the literal sender address, not list
# membership), so bob's reply is still addressed to a list he belongs to.
# Without the sender exclusion in pm_process_message, that would wake bob
# on his own reply -- and self-sustainingly so, since his next reply-all
# would be byte-for-byte the same shape. All three first runs are
# harvested before bob replies so the busy-run dedup (rule 4) can't be
# what's suppressing his second wake -- only the sender exclusion can,
# and alice/carol waking as usual on the same message shows it's not
# some other rule blocking everyone.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid1="$(send_msg '@operator' '@team' 'self-wake regression' 'body from operator' 8)"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
once
check "operator mail wakes all three team members" 3 \
    "$(grep -c -- "^sbx-mail-$short-\(alice\|bob\|carol\)-" "$STUB_ARGV_LOG")"

for a in alice bob carol; do
    run_env="$(env_file_for_agent "$a")"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
    mkdir -p -- "$run_dir/outbox"
    printf '0\n' > "$run_dir/exit-code"
done
once

mid2="$(reply_msg '@bob' "$mid1" 'reply from bob')"
contains "bob's reply-all still addresses the team list" \
    "$("$MAIL" show "$mid2" 2>/dev/null | sed -n 's/^To: //p')" '@team'
: > "$STUB_ARGV_LOG"
once
check "bob does not wake on the message he just sent" 0 \
    "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "alice still wakes on bob's reply" 1 \
    "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"
check "carol still wakes on bob's reply" 1 \
    "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== unknown/external To name is skipped, no crash, no flag ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob,@nobody' 'unknown to test' 'body' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
rc="$(once_rc)"
check "unknown To name: deliver still exits 0" "0" "$rc"
check "unknown To name: known recipient still wakes" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "unknown To name: no flag raised" "" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)"

# ============================================================
printf '\n== seat resolution reaches launcher argv ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

: > "$STUB_ARGV_LOG"
send_msg '@bob' '@alice' 'seat alice' 'body' 8 >/dev/null
once
check "seat alice: harness falls back to default (unset anywhere but frontmatter)" "claude" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
check "seat alice: model from persona frontmatter" "opus" "$(argv_after '--model' "$STUB_ARGV_LOG")"
check "seat alice: network defaults to pinned" "pinned" "$(argv_after '--network' "$STUB_ARGV_LOG")"
if grep -qF -- '--pi-args' "$STUB_ARGV_LOG"; then
    no "seat alice: no --pi-args on a claude harness"
else
    ok "seat alice: no --pi-args on a claude harness"
fi

: > "$STUB_ARGV_LOG"
send_msg '@alice' '@bob' 'seat bob' 'body' 8 >/dev/null
once
check "seat bob: harness from fleet.yaml" "pi" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
if grep -qF -- '--model' "$STUB_ARGV_LOG"; then
    no "seat bob: no --model on a pi harness with no configured model (sonnet is a claude alias)" \
        "$(argv_after '--model' "$STUB_ARGV_LOG")"
else
    ok "seat bob: no --model on a pi harness with no configured model (sonnet is a claude alias)"
fi
check "seat bob: network from fleet.yaml" "sealed" "$(argv_after '--network' "$STUB_ARGV_LOG")"
check "seat bob: thinking passed as --pi-args on a pi harness" "--thinking medium" "$(argv_after '--pi-args' "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
send_msg '@alice' '@carol' 'seat carol' 'body' 8 >/dev/null
once
check "seat carol: harness defaults to claude (all-empty agent)" "claude" "$(argv_after '--harness' "$STUB_ARGV_LOG")"
check "seat carol: model defaults to sonnet (all-empty agent)" "sonnet" "$(argv_after '--model' "$STUB_ARGV_LOG")"
check "seat carol: network defaults to pinned (all-empty agent)" "pinned" "$(argv_after '--network' "$STUB_ARGV_LOG")"
if grep -qF -- '--pi-args' "$STUB_ARGV_LOG"; then
    no "seat carol: no --pi-args on a claude harness"
else
    ok "seat carol: no --pi-args on a claude harness"
fi

# ============================================================
printf '\n== X-Hops 0 gate: no spawn, thread flagged ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'hops zero' 'body' 0)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
once
check "X-Hops 0: no spawn" 0 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "X-Hops 0: flag names the message id" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "$mid"
contains "X-Hops 0: flag reason says hops exhausted" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "hops exhausted"

# ============================================================
printf '\n== thread budget: default 12, env override, flag on exhaust ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'budget default' 'body' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns"
seq 1 12 > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
: > "$STUB_ARGV_LOG"
once
check "budget default 12: no spawn once exhausted" 0 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "budget default 12: flag names the limit" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "thread budget 12 exhausted"

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_THREAD_BUDGET=1
mid1="$(send_msg '@alice' '@bob' 'budget override' 'body one' 8)"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "budget override 1: first message spawns" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
check "budget override 1: spawn count is 1" "1" "$(spawn_count_of "$tid")"
mid2="$(reply_msg '@alice' "$mid1" 'body two' --to '@carol')"
: > "$STUB_ARGV_LOG"
once
check "budget override 1: second message (different agent) still blocked" 0 \
    "$(grep -c -- "^sbx-mail-$short-carol-" "$STUB_ARGV_LOG")"
contains "budget override 1: flag names the override value" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "thread budget 1 exhausted"
unset FORK_SANDBOX_THREAD_BUDGET

# ============================================================
printf '\n== operator mail (From not a fleet agent) resets flag and spawn count ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
root_mid="$(send_msg '@operator' '@alice' 'operator reset' 'first message' 5)"
tid="$(thread_of "$root_mid")"
short="${tid:0:8}"
"$postmaster" flag "$tid" "stale reason from a previous round" >/dev/null 2>&1
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns"
printf 'stale-1\nstale-2\nstale-3\n' > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/spawns/$tid"
: > "$STUB_ARGV_LOG"
once
check "operator mail: pre-existing flag is cleared" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)"
check "operator mail: spawn count reset before this message's own spawn is counted" "1" "$(spawn_count_of "$tid")"
check "operator mail: routes normally after reset (alice spawns)" 1 "$(grep -c -- "^sbx-mail-$short-alice-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== pending: busy agent does not get a second spawn; follow-up wake after harvest ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid1="$(send_msg '@alice' '@bob' 'pending test' 'first message' 8)"
tid="$(thread_of "$mid1")"
short="${tid:0:8}"
: > "$STUB_ARGV_LOG"
once
check "pending: first message spawns bob" 1 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"

run_env="$(env_file_for_agent bob)"
check "pending: exactly one live run for bob" "1" "$( [[ -n "$run_env" ]] && echo 1 || echo 0 )"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"

mid2="$(reply_msg '@alice' "$mid1" 'second message' --to '@bob')"
: > "$STUB_ARGV_LOG"
once
check "pending: busy agent gets no second spawn" 0 "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "pending: message id recorded as pending on the live run" \
    "$(cat "$run_env")" "PENDING_MSGS=$mid2"

mkdir -p -- "$run_dir/outbox"
printf '0\n' > "$run_dir/exit-code"
printf '\nAcknowledged, thanks.\n' > "$run_dir/outbox/mail-1.md"
: > "$STUB_ARGV_LOG"
once
check "pending: harvest fires a follow-up wake for the pending message" 1 \
    "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"
contains "pending: follow-up wake's TRIGGER is the pending message" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"/*.env)" "TRIGGER=$mid2"

# ============================================================
printf '\n== harvest: reply-file stanzas, hops handling, malformed files ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
trig_mid="$(send_msg '@alice' '@bob' 'harvest topic' 'the original body' 8)"
tid="$(thread_of "$trig_mid")"
short="${tid:0:8}"
trig_hops="$(hops_of_mid "$trig_mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent bob)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"

mkdir -p -- "$run_dir/outbox"
# 1. No stanza at all (default reply-all, default subject, no hops override).
printf '\nSounds good to me.\n' > "$run_dir/outbox/mail-1.md"
# 2. Explicit To/Subject honored, ordinary in-thread reply.
printf 'To: @carol\nSubject: Custom subject line\n\nRouted explicitly.\n' > "$run_dir/outbox/mail-2.md"
# 3. Reply-To-Id: new starts a fresh thread with decremented hops.
printf 'To: @carol\nSubject: Fresh topic\nReply-To-Id: new\n\nStarting something new.\n' > "$run_dir/outbox/mail-3.md"
# 4. Malformed: an unrecognized header line.
printf 'Foo: bar\n\nThis should never post.\n' > "$run_dir/outbox/mail-4.md"
printf '0\n' > "$run_dir/exit-code"
once

# mail-1: ordinary reply-all, hops decremented by the harvester's --hops
# override on `mail reply` (both reply paths decrement now).
default_reply=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" Subject)" == "Re: harvest topic" ]] && default_reply="$f"
done
if [[ -n "$default_reply" ]]; then
    ok "harvest: no-stanza reply posted with reply-all default subject"
    check "harvest: no-stanza reply hops are the trigger's decremented by 1" \
        "$(( trig_hops - 1 ))" "$(header_of_file "$default_reply" X-Hops)"
else
    no "harvest: no-stanza reply posted with reply-all default subject"
fi

explicit_reply=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ "$(header_of_file "$f" Subject)" == "Custom subject line" ]] && explicit_reply="$f"
done
if [[ -n "$explicit_reply" ]]; then
    ok "harvest: explicit To/Subject reply posted"
    check "harvest: explicit reply To honored" "@carol" "$(header_of_file "$explicit_reply" To)"
else
    no "harvest: explicit To/Subject reply posted"
fi

new_tid=""
for d in "$FORK_SANDBOX_MAIL_ROOT"/threads/*/; do
    dt="$(basename -- "$d")"
    [[ "$dt" == "$tid" ]] && continue
    for f in "$d"*.msg; do
        [[ -e "$f" ]] || continue
        [[ "$(header_of_file "$f" Subject)" == "Fresh topic" ]] && new_tid="$dt"
    done
done
if [[ -n "$new_tid" ]]; then
    ok "harvest: Reply-To-Id: new creates a fresh thread"
    new_hops="$(header_of_file "$FORK_SANDBOX_MAIL_ROOT/threads/$new_tid"/*.msg X-Hops)"
    check "harvest: new-thread hops are the trigger's decremented by 1" "$(( trig_hops - 1 ))" "$new_hops"
else
    no "harvest: Reply-To-Id: new creates a fresh thread"
fi

contains "harvest: malformed file flags the thread with its name" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")" "mail-4.md"
malformed_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg "$FORK_SANDBOX_MAIL_ROOT"/threads/*/*.msg; do
    [[ -e "$f" ]] || continue
    grep -qF 'This should never post.' "$f" && malformed_posted=1
done
check "harvest: malformed file's body was never posted" 0 "$malformed_posted"
check "harvest: run marked harvested exactly once" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

msg_count_before="$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -name '*.msg' | wc -l)"
once
msg_count_after="$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -name '*.msg' | wc -l)"
check "harvest: second scan over an already-harvested run posts nothing new" \
    "$msg_count_before" "$msg_count_after"

# ============================================================
printf '\n== routed marker idempotence: two --once passes route each message once ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'idempotence' 'body' 8)"
tid="$(thread_of "$mid")"
short="${tid:0:8}"
: > "$STUB_ARGV_LOG"
once
once
check "routed idempotence: exactly one spawn across two --once passes" 1 \
    "$(grep -c -- "^sbx-mail-$short-bob-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== lock: flock held refuses, released allows, stale content is ignored ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mkdir -p -- "$FORK_SANDBOX_MAIL_ROOT/.postmaster"
lock_file="$FORK_SANDBOX_MAIL_ROOT/.postmaster/lock"
ready_file="$work/lock-holder-ready"
rm -f -- "$ready_file"
flock "$lock_file" -c "touch '$ready_file'; sleep 5" &
holder_pid=$!
for _ in $(seq 1 50); do [[ -e "$ready_file" ]] && break; sleep 0.1; done
err="$("$postmaster" deliver --project "$PROJECT_DIR" --once 2>&1)"; rc=$?
check "lock: second deliver refuses while the flock is held" "1" "$rc"
contains "lock: refusal names the lock" "$err" "holds the lock"
wait "$holder_pid" 2>/dev/null

# A dead process can never leave a stale flock behind (the kernel releases
# it on exit, however the process died), so a leftover pid in the lock
# file's content -- with nothing actually holding the flock -- must not
# block a new deliver. This is the case the old mkdir+pid+kill-0 scheme
# needed a whole "detect and break a stale lock" path for; flock has no
# such case to detect.
printf '99999999\n' > "$lock_file"
rc="$(once_rc)"
check "lock: a stale pid left in the lock file's content does not block deliver" "0" "$rc"

rc="$(once_rc)"
check "lock: a second deliver after release succeeds (the flock was released)" "0" "$rc"

# ============================================================
printf '\n== generated handoff contains persona, thread, trigger id, no-reply line ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@bob' '@alice' 'handoff check' 'Please take a look at this specific body text.' 8)"
: > "$STUB_ARGV_LOG"
once
handoff_file="$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/handoffs" -type f -name '*.md' | head -n1)"
if [[ -n "$handoff_file" ]]; then
    handoff="$(cat "$handoff_file")"
    contains "handoff: persona body present" "$handoff" "Alice reviews code carefully"
    contains "handoff: thread message body present" "$handoff" "Please take a look at this specific body text."
    contains "handoff: triggering message id called out" "$handoff" "$mid"
    contains "handoff: no-action-needed line present verbatim" "$handoff" "No action needed is a valid outcome"
else
    no "handoff file was written"
fi

# ============================================================
printf '\n== status lists unrouted/live/flagged truthfully ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
live_mid="$(send_msg '@alice' '@bob' 'status live' 'body' 8)"
live_tid="$(thread_of "$live_mid")"
once
flag_mid="$(send_msg '@alice' '@carol' 'status flagged' 'body' 0)"
flag_tid="$(thread_of "$flag_mid")"
once
unrouted_mid="$(send_msg '@alice' '@carol' 'status unrouted' 'body' 8)"

status_out="$("$postmaster" status)"
contains "status: reports one unrouted message" "$status_out" "unrouted: 1"
contains "status: lists the live run's agent" "$status_out" "agent=bob"
contains "status: lists the live run's thread" "$status_out" "thread=$live_tid"
contains "status: lists the flagged thread" "$status_out" "$flag_tid"
contains "status: flagged thread's reason" "$status_out" "hops exhausted"
contains "status: spawn count per thread" "$status_out" "$live_tid: 1 spawns"
[[ -n "$unrouted_mid" ]] # silence unused-var warnings under -u in some shells

# ============================================================
printf '\n== flag / unflag verbs ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
manual_tid="manually-flagged-thread"
"$postmaster" flag "$manual_tid" "operator wants eyes on this" >/dev/null 2>&1
check "flag: reason recorded" "operator wants eyes on this" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$manual_tid")"
"$postmaster" unflag "$manual_tid" >/dev/null 2>&1
check "unflag: flag file removed" "0" \
    "$( [[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$manual_tid" ]] && echo 1 || echo 0 )"

# ============================================================
printf '\n== branch names never repeat, even across an operator spawn-count reset ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
root_mid="$(send_msg '@operator' '@alice' 'reset one' 'first' 8)"
tid="$(thread_of "$root_mid")"
short="${tid:0:8}"
: > "$STUB_ARGV_LOG"
once
first_branch="$(argv_after '--branch' "$STUB_ARGV_LOG")"

# Harvest the first run (no new spawn -- just clears the live-run block so
# alice is eligible to be woken again).
alice_env="$(env_file_for_agent alice)"
alice_run_dir="$(sed -n 's/^RUN_DIR=//p' "$alice_env")"
mkdir -p -- "$alice_run_dir/outbox"
printf '0\n' > "$alice_run_dir/exit-code"
once

# A second operator message on the same thread resets the (rule 1) budget
# counter again before this spawn is counted -- without a separate,
# never-reset sequence for branch naming, this would recompute the same
# "count + 1" as the first spawn and hand fork-sandbox.sh the same branch
# name twice.
second_mid="$(reply_msg '@operator' "$root_mid" 'second')"
[[ "$(thread_of "$second_mid")" == "$tid" ]] || no "fixture: second operator message landed on the same thread"
: > "$STUB_ARGV_LOG"
once
second_branch="$(argv_after '--branch' "$STUB_ARGV_LOG")"

if [[ -n "$first_branch" && -n "$second_branch" ]]; then
    if [[ "$first_branch" != "$second_branch" ]]; then
        ok "branch name does not repeat across a rule-1 reset"
    else
        no "branch name does not repeat across a rule-1 reset" "both spawns got '$first_branch'"
    fi
else
    no "branch name does not repeat across a rule-1 reset" "missing a --branch value (first='$first_branch' second='$second_branch')"
fi
[[ -n "$short" ]] # silence unused-var warnings under -u in some shells

# ============================================================
printf '\n== harvest: non-zero exit code flags the thread even with a reply ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'crash test' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent bob)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
mkdir -p -- "$run_dir/outbox"
printf '1\n' > "$run_dir/exit-code"
once
contains "harvest: non-zero exit code flags the thread" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" "exited 1"
check "harvest: a failed run is still marked harvested (agent unblocks)" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"

# ============================================================
printf '\n== harvest: a run dir that vanishes is treated as a terminal failure ==\n'
# ============================================================

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
mid="$(send_msg '@alice' '@bob' 'vanished run dir' 'body' 8)"
tid="$(thread_of "$mid")"
: > "$STUB_ARGV_LOG"
once
run_env="$(env_file_for_agent bob)"
run_dir="$(sed -n 's/^RUN_DIR=//p' "$run_env")"
rm -rf -- "$run_dir"
once
contains "harvest: vanished run dir flags the thread" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)" "vanished"
check "harvest: vanished run dir is marked harvested (agent unblocks)" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/harvested" -type f | wc -l)"
: > "$STUB_ARGV_LOG"
mid2="$(reply_msg '@alice' "$mid" 'a new message on the same thread' --to '@bob')"
[[ "$(thread_of "$mid2")" == "$tid" ]] || no "fixture: follow-up message landed on the same thread"
once
check "harvest: agent is spawnable again after the vanished run was harvested" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-bob-" "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== spawn launcher is resolved independent of PATH ==\n'
# ============================================================

# FORK_SANDBOX_POSTMASTER_LAUNCHER (exported in the fixture setup above)
# points straight at the stub via script_dir-style resolution, never via
# PATH -- true whether or not some OTHER fork-sandbox.sh happens to be on
# PATH too (e.g. this machine's own install). Proof: the stub is the one
# that's called.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
send_msg '@alice' '@bob' 'path independence' 'body' 8 >/dev/null
: > "$STUB_ARGV_LOG"
rc="$(once_rc)"
check "launcher: deliver spawns" "0" "$rc"
check "launcher: the stub, not any fork-sandbox.sh found via PATH, received the call" 1 \
    "$(grep -c -- '^----CALL----$' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== session resume: state dir on every claude wake, id across wakes ==\n'
# ============================================================

# An agent woken repeatedly on one thread is one continuing claude
# conversation: --session-state binds a per-(thread, agent) transcript
# store into every wake, and the id harvest read out of the last wake's
# summary.json resumes it on the next.

PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

# env_file_for_agent above returns the FIRST match, which after a harvest
# is a dead run. These wakes each follow the last one's harvest, so the
# live one is what every assertion below wants.
live_env_for_agent() {
    local agent="$1" f rid
    for f in "$PM_STATE_DIR/runs"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$PM_STATE_DIR/harvested/$rid" ]] && continue
        grep -q "^AGENT=$agent\$" "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Ends the live run for $1: exit code $2, and a summary.json naming
# session $3 when one is given (the shape fork-sandbox.sh writes on a
# --session-state run).
finish_run() {
    local agent="$1" code="$2" sid="${3:-}" env_f run_dir
    env_f="$(live_env_for_agent "$agent")"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$env_f")"
    mkdir -p -- "$run_dir/outbox"
    [[ -n "$sid" ]] \
        && printf '{"session_id":"%s","session_state":"x"}\n' "$sid" \
            > "$run_dir/summary.json"
    printf '%s\n' "$code" > "$run_dir/exit-code"
}

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

res_sid=11112222-3333-4444-5555-666677778888
res_mid1="$(send_msg '@carol' '@alice' 'resume topic' 'first message' 8)"
res_tid="$(thread_of "$res_mid1")"
res_state="$PM_STATE_DIR/state/$res_tid/alice"
res_sessions="$PM_STATE_DIR/sessions/$res_tid/alice"

: > "$STUB_ARGV_LOG"
once
check "resume: first wake binds the per-(thread, agent) state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"
check "resume: first wake passes no --resume-session" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "resume: first wake's .env records it as fresh" "RESUMED=" \
    "$(grep '^RESUMED=' "$(live_env_for_agent alice)")"
contains "resume: status marks a fresh wake" \
    "$("$postmaster" status 2>&1)" "session=fresh"

finish_run alice 0 "$res_sid"
once
check "resume: harvest records the session id from summary.json" \
    "$res_sid" "$(cat "$res_sessions" 2>/dev/null)"

res_mid2="$(reply_msg '@carol' "$res_mid1" 'second message' --to '@alice')"
: > "$STUB_ARGV_LOG"
once
check "resume: second wake resumes the recorded session" \
    "$res_sid" "$(argv_after --resume-session "$STUB_ARGV_LOG")"
check "resume: second wake binds the same state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"
contains "resume: status marks a resumed wake" \
    "$("$postmaster" status 2>&1)" "resumed=$res_sid"

# A resumed wake that fails outright forgets the session: the recorded id
# is the suspect, and a fresh wake always works. Never a retry loop --
# claude-sandboxed already retried once inside the run.
finish_run alice 1
once
check "resume: a failed wake clears the recorded session id" 0 \
    "$( [[ -e "$res_sessions" ]] && echo 1 || echo 0 )"

reply_msg '@carol' "$res_mid2" 'third message' --to '@alice' >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: the wake after a failure is fresh again" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"
check "resume: ...and still binds the state dir" \
    "$res_state" "$(argv_after --session-state "$STUB_ARGV_LOG")"

# A summary.json that names nothing usable leaves the store's own history
# alone rather than recording a value the launcher would refuse -- a bad
# id there would wedge every later wake of this seat.
finish_run alice 0 'not a session id'
once
check "resume: a malformed session id is not recorded" 0 \
    "$( [[ -e "$res_sessions" ]] && echo 1 || echo 0 )"

# pi and codex have no resume support and fork-sandbox.sh refuses both
# flags there, so a non-claude seat must get neither. bob is the pi seat.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
send_msg '@carol' '@bob' 'pi seat resume' 'body' 8 >/dev/null
: > "$STUB_ARGV_LOG"
once
check "resume: a pi seat gets no --session-state" 0 \
    "$(grep -c -- '^--session-state$' "$STUB_ARGV_LOG")"
check "resume: a pi seat gets no --resume-session" 0 \
    "$(grep -c -- '^--resume-session$' "$STUB_ARGV_LOG")"

# ============================================================
printf '\n== --help and dispatcher wiring ==\n'
# ============================================================

help_out="$("$postmaster" --help 2>&1)"
contains "--help prints usage naming deliver" "$help_out" "deliver"
contains "--help documents the routing rules" "$help_out" "ROUTING RULES"

dispatcher="$repo_dir/scripts/fork-sandbox"
if [[ -x "$dispatcher" ]]; then
    disp_help="$("$dispatcher" postmaster --help 2>&1)"
    contains "fork-sandbox postmaster --help reaches the postmaster script" "$disp_help" "fork-sandbox-postmaster.sh"
else
    no "dispatcher wiring" "scripts/fork-sandbox is not executable"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
