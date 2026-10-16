#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/07-triage.sh — fork-sandbox-postmaster.sh: the triage
# classifier gating a Cc-only wake.
#
# Usage: tests/postmaster/07-triage.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== triage classifier gates a Cc-only wake ==\n'
# ============================================================

# The shared fixture's fleet.yaml/personas (set up at the top of this file)
# has no top-level triage: block, and every OTHER group in this file relies
# on that -- turning triage on for it here would make every other group's
# Cc wakes route through a classifier none of them stub, so this group gets
# its own fleet file and persona dir instead of touching the shared ones.

SAVED_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE"
SAVED_PERSONAS_DIR="$FORK_SANDBOX_PERSONAS_DIR"

new_root TRIAGE_STUB_BIN
TRIAGE_LOG="$work/triage.log"
export TRIAGE_LOG
: > "$TRIAGE_LOG"

cat > "$TRIAGE_STUB_BIN/triage-launcher" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
{
    printf -- '----CALL----\n'
    for a in "$@"; do printf 'ARG:%s\n' "$a"; done
    printf -- '----STDIN----\n'
    cat
    printf -- '----END----\n'
} >> "$TRIAGE_LOG"
case "${TRIAGE_STUB_MODE:-verdict}" in
    fail) exit 1 ;;
    timeout) sleep 5 ;;
    garbage) printf 'this is not a valid verdict\n' ;;
    verdict) printf '%s\n' "${TRIAGE_STUB_VERDICT:-wake}" ;;
esac
STUB
chmod +x "$TRIAGE_STUB_BIN/triage-launcher"
export FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER="$TRIAGE_STUB_BIN/triage-launcher"

new_root TRIAGE_FLEET_DIR
export FORK_SANDBOX_FLEET_FILE="$TRIAGE_FLEET_DIR/fleet.yaml"
new_root TRIAGE_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR="$TRIAGE_PERSONAS_DIR"

cat > "$FORK_SANDBOX_PERSONAS_DIR/alice.md" <<'EOF'
Alice is a Cc-only reviewer whose wake is gated by triage.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/bob.md" <<'EOF'
Bob is the direct recipient; his wake is never gated.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/carol.md" <<'EOF'
Carol is the sender used throughout this group.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/dave.md" <<'EOF'
Dave opts out of triage entirely; his Cc wake always spawns.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/eve.md" <<'EOF'
Eve has no description anywhere (no fleet.yaml entry, no frontmatter);
her Cc wake always spawns because there is nothing to triage against.
EOF

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  alice:
    description: Cc-only reviewer, wakes only when something needs her
  bob:
    description: direct recipient, always wakes
  carol:
    description: sender used throughout this group
  dave:
    description: opts out of triage entirely
    triage: false
triage:
  harness: claude
  model: haiku
EOF

if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: triage fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

cat > "$TRIAGE_FLEET_DIR/no-triage-fleet.yaml" <<'EOF'
agents:
  alice: {}
  bob: {}
  carol: {}
  dave:
    triage: false
EOF

# --- scenario 1: a wake verdict spawns the Cc-only candidate, To is
#     never routed through the classifier at all ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_MODE=verdict
export TRIAGE_STUB_VERDICT=wake
mid="$(send_msg '@carol' '@bob' 'A' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "wake verdict: bob (To) spawns" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-bob-" "$STUB_ARGV_LOG")"
check "wake verdict: alice (Cc) spawns" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
check "wake verdict: exactly one classifier call (bob's To wake was never classified)" 1 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

# The prompt/argv the classifier actually received: the stub logs every
# ARG and the whole stdin, but until now nothing asserted on either, so
# a regression in the prompt's anti-forgery quoting, the candidate's
# name, or the launch flags would pass a green suite silently.
check "wake verdict: Subject never appears bare (unquoted) in the prompt" 0 \
    "$(grep -c -- '^Subject: A$' "$TRIAGE_LOG")"
check "wake verdict: Subject appears quoted, inside the sender-authored region" 1 \
    "$(grep -c -- '^> Subject: A$' "$TRIAGE_LOG")"
check "wake verdict: From never appears bare (unquoted) in the prompt" 0 \
    "$(grep -c -- '^From: @carol$' "$TRIAGE_LOG")"
check "wake verdict: From appears quoted, inside the sender-authored region" 1 \
    "$(grep -c -- '^> From: @carol$' "$TRIAGE_LOG")"
check "wake verdict: the body is quoted" 1 \
    "$(grep -c -- '^> body$' "$TRIAGE_LOG")"
check "wake verdict: the prompt names the candidate agent" 1 \
    "$(grep -c -- '^Agent: alice$' "$TRIAGE_LOG")"
check "wake verdict: the prompt carries the candidate's description" 1 \
    "$(grep -c -- '^Candidate: Cc-only reviewer, wakes only when something needs her$' "$TRIAGE_LOG")"
check "wake verdict: --tools reaches the launcher (deny all tools)" 1 \
    "$(grep -c -- '^ARG:--tools$' "$TRIAGE_LOG")"
check "wake verdict: --tools value is the empty string (all tools denied)" "ARG:" \
    "$(grep -A1 -- '^ARG:--tools$' "$TRIAGE_LOG" | tail -n1)"
check "wake verdict: --model reaches the launcher" 1 \
    "$(grep -c -- '^ARG:--model$' "$TRIAGE_LOG")"
check "wake verdict: --model value is haiku" "ARG:haiku" \
    "$(grep -A1 -- '^ARG:--model$' "$TRIAGE_LOG" | tail -n1)"
contains "wake verdict: the work dir reaches the launcher" \
    "$(grep -m1 -- '^ARG:' "$TRIAGE_LOG")" ".postmaster.triage-work."

# --- scenario 1b: the claude triage seat is a claude leg like any
#     other, so it obeys CLAUDE_CREDENTIALS in claude.env the same way
#     every other claude-sandboxed invocation does (docs/configure.md) ---
new_root TRIAGE_CONFIG_DIR
cat > "$TRIAGE_CONFIG_DIR/claude.env" <<EOF
CLAUDE_CREDENTIALS=$TRIAGE_CONFIG_DIR/team-credentials.json
EOF
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=wake
mid="$(FORK_SANDBOX_CONFIG_DIR="$TRIAGE_CONFIG_DIR" send_msg '@carol' '@bob' 'Creds' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
FORK_SANDBOX_CONFIG_DIR="$TRIAGE_CONFIG_DIR" once
check "CLAUDE_CREDENTIALS: --claude-credentials reaches the launcher" 1 \
    "$(grep -c -- '^ARG:--claude-credentials$' "$TRIAGE_LOG")"
check "CLAUDE_CREDENTIALS: its value is the path claude.env named" \
    "ARG:$TRIAGE_CONFIG_DIR/team-credentials.json" \
    "$(grep -A1 -- '^ARG:--claude-credentials$' "$TRIAGE_LOG" | tail -n1)"
# claude-sandboxed stops parsing its own flags at the first one it does
# not recognize (--dangerously-skip-permissions among them), so
# --claude-credentials only reaches its own parse branch if it precedes
# the work dir. The stub above logs every ARG in argv order but has no
# idea what a flag means positionally -- it would pass this scenario
# identically whether the flag were forwarded straight through to
# `claude` instead of consumed here. Pin the order directly: the first
# logged ARG must be --claude-credentials, not the work dir.
check "CLAUDE_CREDENTIALS: --claude-credentials precedes the work dir in the launcher argv" \
    "ARG:--claude-credentials" \
    "$(grep -m1 -- '^ARG:' "$TRIAGE_LOG")"

# --- scenario 2: a skip verdict suppresses only the Cc wake, and is
#     recorded in triaged/<thread-id> ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@carol' '@bob' 'A2' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "skip verdict: bob (To) still spawns" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-bob-" "$STUB_ARGV_LOG")"
check "skip verdict: alice (Cc) does not spawn" 0 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
check "skip verdict: triaged/<thread-id> has exactly one line" 1 \
    "$(wc -l < "$FORK_SANDBOX_MAIL_ROOT/.postmaster/triaged/$tid" 2>/dev/null || echo 0)"
contains "skip verdict: triaged line names the message and agent" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/triaged/$tid" 2>/dev/null)" \
    "$mid"$'\t'"alice"
contains "skip verdict: triage-skip event names alice on stdout" \
    "$(cat "$work/once.out")" "pm triage-skip thread=${tid:0:8} agent=alice"
contains "status prints the triaged count" "$("$postmaster" status 2>&1)" "triaged: 1"
# alice resolved to a real seat, was considered, and was declined by the
# triage classifier -- that is not the same thing as an @-shaped name that
# never resolved to any seat at all, and must never flag as unresolvable
# (the handoff's own trap: "resolved, considered, declined -- never
# flagged").
check "skip verdict: a triage-skipped Cc candidate is not flagged as unresolvable" "" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null || true)"

# --- scenario 3: a To candidate is never classified, even when the
#     stub would have said skip ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@carol' '@alice' 'B' 'body' 8)"
tid="$(thread_of "$mid")"
once
check "To candidate spawns regardless of the stub's skip verdict" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
check "To candidate: zero classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

# --- scenario 4: operator/external mail is never classified, for any
#     candidate on the message ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@operator' '@carol' 'C' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "operator mail: alice (Cc) spawns regardless of the stub's skip verdict" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
check "operator mail: zero classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

# --- scenario 5: an unparseable verdict fails toward wake ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_MODE=garbage
mid="$(send_msg '@carol' '@bob' 'D' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "garbage classifier output: alice (Cc) still spawns" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"

# --- scenario 6: a non-zero classifier exit fails toward wake ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_MODE=fail
mid="$(send_msg '@carol' '@bob' 'E' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "failed classifier: alice (Cc) still spawns" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"

# --- scenario 7: a classifier timeout fails toward wake ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_MODE=timeout
(
    export FORK_SANDBOX_POSTMASTER_TRIAGE_TIMEOUT=1
    mid="$(send_msg '@carol' '@bob' 'F' 'body' 8 '@alice')"
    tid="$(thread_of "$mid")"
    once
    check "timed-out classifier: alice (Cc) still spawns" 1 \
        "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
)
export TRIAGE_STUB_MODE=verdict

# --- scenario 8: a per-agent triage: false opt-out is never classified ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@carol' '@bob' 'G' 'body' 8 '@dave')"
tid="$(thread_of "$mid")"
once
check "opted-out agent: dave (Cc) spawns regardless of the stub's skip verdict" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-dave-" "$STUB_ARGV_LOG")"
check "opted-out agent: zero classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

# --- scenario 9: no top-level triage: block means no triage at all
#     (regression baseline) ---
export FORK_SANDBOX_FLEET_FILE="$TRIAGE_FLEET_DIR/no-triage-fleet.yaml"
if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: no-triage fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@carol' '@bob' 'H' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "no triage: block: alice (Cc) spawns regardless of the stub's skip verdict" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-alice-" "$STUB_ARGV_LOG")"
check "no triage: block: zero classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

export FORK_SANDBOX_FLEET_FILE="$TRIAGE_FLEET_DIR/fleet.yaml"

# --- scenario 10: a candidate with no description anywhere is never
#     classified -- there is nothing for the classifier to judge "should
#     this agent wake" against, so it is treated as a reason to skip the
#     classifier (and wake), not to guess ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=skip
mid="$(send_msg '@carol' '@bob' 'I' 'body' 8 '@eve')"
tid="$(thread_of "$mid")"
once
check "no description: eve (Cc) spawns regardless of the stub's skip verdict" 1 \
    "$(grep -c -- "^sbx-mail-${tid:0:8}-eve-" "$STUB_ARGV_LOG")"
check "no description: zero classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"

# --- scenario 11: the classifier's prompt carries only the triggering
#     message, never the rest of the thread (the stated privacy property)
#     ---
: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=wake
mid_first="$(send_msg '@carol' '@bob' 'Thread start' 'FIRSTUNIQUETOKEN' 8)"
reply_msg '@bob' "$mid_first" 'SECONDUNIQUETOKEN' --cc '@alice' >/dev/null
tid="$(thread_of "$mid_first")"
once
check "thread privacy: exactly one classifier call (message 1 never cc'd alice)" 1 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"
check "thread privacy: the prompt carries the triggering message's body" 1 \
    "$(grep -c -- '^> SECONDUNIQUETOKEN$' "$TRIAGE_LOG")"
check "thread privacy: the prompt does not carry an earlier message's body" 0 \
    "$(grep -c -- 'FIRSTUNIQUETOKEN' "$TRIAGE_LOG")"

# --- scenario 12: a pi-harness triage seat's argv shape is distinct from
#     claude's -- agent-sandboxed reads a `--model` flag (when the seat
#     sets one) BEFORE the work dir, never gets a defaulted model (haiku
#     is a claude alias, see pm_triage_wake), and always ends in `-p` ---
cat > "$TRIAGE_FLEET_DIR/pi-fleet.yaml" <<'EOF'
agents:
  alice:
    description: Cc-only reviewer, wakes only when something needs her
  bob:
    description: direct recipient, always wakes
  carol:
    description: sender used throughout this group
triage:
  harness: pi
EOF
export FORK_SANDBOX_FLEET_FILE="$TRIAGE_FLEET_DIR/pi-fleet.yaml"
if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: pi-harness triage fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
export TRIAGE_STUB_VERDICT=wake
mid="$(send_msg '@carol' '@bob' 'PiNoModel' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "pi harness, no model configured: exactly one classifier call" 1 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"
check "pi harness, no model configured: no --model flag reaches the launcher" 0 \
    "$(grep -c -- '^ARG:--model$' "$TRIAGE_LOG")"
check "pi harness, no model configured: exactly two args (work dir, -p)" 2 \
    "$(grep -c -- '^ARG:' "$TRIAGE_LOG")"
contains "pi harness, no model configured: the first arg is the work dir" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '1p')" ".postmaster.triage-work."
check "pi harness, no model configured: the second arg is -p" "ARG:-p" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '2p')"

cat > "$TRIAGE_FLEET_DIR/pi-model-fleet.yaml" <<'EOF'
agents:
  alice:
    description: Cc-only reviewer, wakes only when something needs her
  bob:
    description: direct recipient, always wakes
  carol:
    description: sender used throughout this group
triage:
  harness: pi
  model: some-local-model
EOF
export FORK_SANDBOX_FLEET_FILE="$TRIAGE_FLEET_DIR/pi-model-fleet.yaml"
if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: pi-harness+model triage fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

: > "$STUB_ARGV_LOG"
: > "$TRIAGE_LOG"
mid="$(send_msg '@carol' '@bob' 'PiWithModel' 'body' 8 '@alice')"
tid="$(thread_of "$mid")"
once
check "pi harness with model: exactly one classifier call" 1 \
    "$(grep -c -- '^----CALL----$' "$TRIAGE_LOG")"
check "pi harness with model: --model is the first arg" "ARG:--model" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '1p')"
check "pi harness with model: the model value follows, second" "ARG:some-local-model" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '2p')"
contains "pi harness with model: the work dir follows the model flag, third" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '3p')" ".postmaster.triage-work."
check "pi harness with model: the fourth (last) arg is -p" "ARG:-p" \
    "$(grep -- '^ARG:' "$TRIAGE_LOG" | sed -n '4p')"
check "pi harness with model: exactly four args" 4 \
    "$(grep -c -- '^ARG:' "$TRIAGE_LOG")"

unset FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER
export FORK_SANDBOX_FLEET_FILE="$SAVED_FLEET_FILE"
export FORK_SANDBOX_PERSONAS_DIR="$SAVED_PERSONAS_DIR"

finish_suite
