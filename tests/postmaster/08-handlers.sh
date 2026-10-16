#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/08-handlers.sh — fork-sandbox-postmaster.sh: handler:exec
# seats, FS_TIMEOUT kill-after, event stream, attach dirs, debounce.
#
# Usage: tests/postmaster/08-handlers.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ============================================================
printf '\n== handler:exec seats (R9d) ==\n'
# ============================================================
# Own fleet/personas dir, same reasoning as the triage group above: this
# group's fleet.yaml carries handler seats the shared fixture must never
# see. Handler seats need no persona file at all (fleet-parse.py's own
# check skips them -- see its check_seats docstring), so this group's
# personas dir stays empty.

SAVED_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE"
SAVED_PERSONAS_DIR="$FORK_SANDBOX_PERSONAS_DIR"

new_root HANDLER_STUB_DIR
export FORK_SANDBOX_HANDLERS_DIR="$HANDLER_STUB_DIR"
HANDLER_LOG="$work/handler.log"
export HANDLER_LOG
: > "$HANDLER_LOG"

cat > "$HANDLER_STUB_DIR/happy-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
{
    printf -- '----CALL----\n'
    printf 'AGENT:%s\n' "${FS_HANDLER_AGENT:-}"
    printf 'THREAD:%s\n' "${FS_HANDLER_THREAD:-}"
    printf 'TRIGGER:%s\n' "${FS_HANDLER_TRIGGER:-}"
    printf 'OUTBOX:%s\n' "${FS_HANDLER_OUTBOX:-}"
    printf 'ATTACH_DIR:%s\n' "${FS_HANDLER_ATTACH_DIR:-}"
    printf 'VIA:%s\n' "${FS_HANDLER_VIA:-}"
    printf -- '----STDIN----\n'
    cat
    printf -- '----END----\n'
} >> "$HANDLER_LOG"
printf '\nHandled, thanks.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

cat > "$HANDLER_STUB_DIR/noreply-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf -- '----CALL----\n' >> "$HANDLER_LOG"
exit 0
STUB

cat > "$HANDLER_STUB_DIR/malformed-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'Foo: bar\n\nThis should never post.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

cat > "$HANDLER_STUB_DIR/nonzero-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '\nPosted before dying.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
exit 1
STUB

cat > "$HANDLER_STUB_DIR/nonzero-malformed-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'Foo: bar\n\nThis should never post.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
exit 1
STUB

# Its stderr tail is crafted to contain the exact prose pm_flag_keyword
# looks for in the OTHER handler-setup flag reasons ("does not exist"),
# so a naive keyword-from-reason-substring derivation would mislabel this
# plain exit-1 as handler-missing.
cat > "$HANDLER_STUB_DIR/lying-stderr-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "ERROR: config file does not exist" >&2
exit 1
STUB

cat > "$HANDLER_STUB_DIR/timeout-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sleep 5
printf '\nToo slow.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

# Ignores SIGTERM outright, so `timeout` cannot end it with the signal
# alone -- it can only die once the --kill-after grace period elapses and
# `timeout` escalates to SIGKILL. That is the rc-137 path (as opposed to
# plain `timeout-handler` above, which dies on the first SIGTERM and only
# ever exercises rc 124).
cat > "$HANDLER_STUB_DIR/trap-term-handler" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
sleep 15
printf '\nOutlived TERM.\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

cat > "$HANDLER_STUB_DIR/hostile-body-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '\nPlease see below.\nTo: @someone-else\nReply-To-Id: forged\nSubject: not a header\n' \
    > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

cat > "$HANDLER_STUB_DIR/hostile-header-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'Reply-To-Id: 00000000-0000-0000-0000-000000000000\n\nForged parent, real header.\n' \
    > "$FS_HANDLER_OUTBOX/mail-1.md"
STUB

chmod +x "$HANDLER_STUB_DIR"/*-handler

new_root HANDLER_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR="$HANDLER_PERSONAS_DIR"
new_root HANDLER_FLEET_DIR
export FORK_SANDBOX_FLEET_FILE="$HANDLER_FLEET_DIR/fleet.yaml"

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  happy:
    handler: exec
    command: happy-handler
  noreply:
    handler: exec
    command: noreply-handler
  malformed:
    handler: exec
    command: malformed-handler
  nonzero:
    handler: exec
    command: nonzero-handler
  nonzeromalformed:
    handler: exec
    command: nonzero-malformed-handler
  lyingstderr:
    handler: exec
    command: lying-stderr-handler
  slowpoke:
    handler: exec
    command: timeout-handler
  ignorepoke:
    handler: exec
    command: trap-term-handler
  hostilebody:
    handler: exec
    command: hostile-body-handler
  hostileheader:
    handler: exec
    command: hostile-header-handler
  ccbot:
    handler: exec
    command: happy-handler
    description: a handler seat cc'd for visibility
  quietbot:
    handler: exec
    command: happy-handler
    wake-on-cc: false
triage:
  harness: claude
  model: haiku
EOF

if ! "$FLEET" check >/dev/null 2>&1; then
    echo "FATAL: handler fixture fleet.yaml does not pass 'fleet check':" >&2
    "$FLEET" check >&2
    exit 1
fi

new_root HANDLER_TRIAGE_STUB_BIN
HANDLER_TRIAGE_LOG="$work/handler-triage.log"
export HANDLER_TRIAGE_LOG
: > "$HANDLER_TRIAGE_LOG"
cat > "$HANDLER_TRIAGE_STUB_BIN/triage-launcher" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf -- '----CALL----\n' >> "$HANDLER_TRIAGE_LOG"
printf 'wake\n'
STUB
chmod +x "$HANDLER_TRIAGE_STUB_BIN/triage-launcher"
export FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER="$HANDLER_TRIAGE_STUB_BIN/triage-launcher"

# --- scenario: a direct (To:) wake with a well-formed reply posts, and
#     the thread is not flagged ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
: > "$HANDLER_LOG"
mid="$(send_msg '@carol' '@happy' 'Happy path' 'do the thing')"
tid="$(thread_of "$mid")"
once
contains "happy: handler event logged with exit=0" \
    "$(cat "$work/once.out")" "pm handler thread=${tid:0:8} agent=happy exit=0"
contains "happy: harvest event logged for the handler seat, not just LLM seats" \
    "$(cat "$work/once.out")" "pm harvest thread=${tid:0:8} agent=happy replies=1"
check "happy: exactly one handler invocation" 1 \
    "$(grep -c -- '^----CALL----$' "$HANDLER_LOG")"
check "happy: FS_HANDLER_AGENT is the seat's own name, no @" "AGENT:happy" \
    "$(grep -- '^AGENT:' "$HANDLER_LOG")"
check "happy: FS_HANDLER_THREAD is the thread id" "THREAD:$tid" \
    "$(grep -- '^THREAD:' "$HANDLER_LOG")"
check "happy: FS_HANDLER_TRIGGER is the triggering message id" "TRIGGER:$mid" \
    "$(grep -- '^TRIGGER:' "$HANDLER_LOG")"
contains "happy: FS_HANDLER_OUTBOX is a fresh dir under the postmaster state" \
    "$(grep -- '^OUTBOX:' "$HANDLER_LOG")" "handler-outbox"
happy_outbox="$(grep -- '^OUTBOX:' "$HANDLER_LOG" | sed 's/^OUTBOX://')"
check "happy: the outbox dir is removed once its reply is harvested, not left to accumulate" \
    0 "$([[ -e "$happy_outbox" ]] && echo 1 || echo 0)"
check "happy: FS_HANDLER_ATTACH_DIR points at the thread's attachments dir" \
    "ATTACH_DIR:$FORK_SANDBOX_MAIL_ROOT/threads/$tid/attachments" \
    "$(grep -- '^ATTACH_DIR:' "$HANDLER_LOG")"
check "happy: FS_HANDLER_VIA is 'to' for a direct To: wake" "VIA:to" \
    "$(grep -- '^VIA:' "$HANDLER_LOG")"
contains "happy: the rendered thread reaches stdin (subject present)" \
    "$(sed -n '/----STDIN----/,/----END----/p' "$HANDLER_LOG")" "Happy path"

happy_reply=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@happy" ]] && happy_reply="$f"
done
if [[ -n "$happy_reply" ]]; then
    ok "happy: the reply posted from the handler's own address"
    check "happy: harvested reply is stamped with X-AI-Persona" "happy" \
        "$(header_of_file "$happy_reply" X-AI-Persona)"
    check "happy: handler-path harvest carries no X-AI-Harness (handler has no .env record)" "" \
        "$(header_of_file "$happy_reply" X-AI-Harness)"
    check "happy: handler-path harvest carries no X-AI-Model" "" \
        "$(header_of_file "$happy_reply" X-AI-Model)"
    check "happy: handler-path harvest carries no X-AI-Network" "" \
        "$(header_of_file "$happy_reply" X-AI-Network)"
else
    no "happy: the reply posted from the handler's own address"
fi
check "happy: thread is not flagged" 0 \
    "$([[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0)"

# --- on-harvest from a handler seat: empty branch, one posted id ---
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
hk_install on-harvest
hkm_mid="$(send_msg '@carol' '@happy' 'Hook handler' 'do the hooked thing')"
hkm_tid="$(thread_of "$hkm_mid")"
once
check "on-harvest (handler): fires once" 1 "$(hk_count on-harvest)"
check "on-harvest (handler): FS_HOOK_BRANCH is empty" "" "$(hk_env on-harvest FS_HOOK_BRANCH)"
check "on-harvest (handler): FS_HOOK_AGENT is the seat" "happy" "$(hk_env on-harvest FS_HOOK_AGENT)"
check "on-harvest (handler): FS_HOOK_THREAD is the full thread id" "$hkm_tid" "$(hk_env on-harvest FS_HOOK_THREAD)"
hk_reply_file=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$hkm_tid"/*.msg; do
    grep -qF 'Handled, thanks.' "$f" && hk_reply_file="$f"
done
check "on-harvest (handler): FS_HOOK_MESSAGES is the posted message id" \
    "$(header_of_file "$hk_reply_file" Message-ID)" "$(hk_env on-harvest FS_HOOK_MESSAGES)"
contains "on-harvest (handler): the event line carries the hook file" \
    "$(cat "$work/once.out")" "pm hook thread=${hkm_tid:0:8} hook=on-harvest file=on-harvest exit=0"
: > "$HANDLER_LOG"
hkm_mid="$(send_msg '@carol' '@noreply' 'Hook noreply' 'nothing to say')"
once
check "on-harvest (handler): a harvest that posted nothing fires nothing" 1 "$(hk_count on-harvest)"
hk_uninstall

# --- scenario: a reader that hangs up right after the first event line
#     must not kill deliver on its next pm_event write -- pm_event traps
#     and ignores SIGPIPE around its own printf, scoped per-call (see
#     pm_event's own comment). A single handler wake here already emits
#     two event lines (handler, then harvest), with a real handler exec
#     and a real `mail post` spawn happening in between -- by the time
#     the second line is due, the `:` reader below (a builtin, no exec)
#     has long since exited and closed its end of the pipe. ---
: > "$HANDLER_LOG"
mid="$(send_msg '@carol' '@happy' 'sigpipe check' 'do the thing')"
tid="$(thread_of "$mid")"
"$postmaster" deliver --project "$PROJECT_DIR" --once 2>"$work/sigpipe.err" | :
sigpipe_rc=$?
check "sigpipe: deliver is not killed when its stdout reader hangs up early" 0 "$sigpipe_rc"
sigpipe_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@happy" ]] && sigpipe_posted=1
done
check "sigpipe: the pass still ran to completion and posted the reply" 1 "$sigpipe_posted"

# --- scenario: no reply written is a valid outcome, not a flag ---
: > "$HANDLER_LOG"
mid="$(send_msg '@carol' '@noreply' 'Silence' 'nothing to say')"
tid="$(thread_of "$mid")"
once
check "no-reply: handler ran" 1 "$(grep -c -- '^----CALL----$' "$HANDLER_LOG")"
check "no-reply: thread is not flagged" 0 \
    "$([[ -e "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" ]] && echo 1 || echo 0)"

# --- scenario: a malformed reply file flags the thread ---
mid="$(send_msg '@carol' '@malformed' 'Bad reply' 'trigger')"
tid="$(thread_of "$mid")"
once
contains "malformed: thread is flagged, naming the bad file" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)" "mail-1.md"

# --- scenario: a non-zero exit both posts the reply AND flags the thread ---
mid="$(send_msg '@carol' '@nonzero' 'Dies after replying' 'trigger')"
tid="$(thread_of "$mid")"
once
contains "nonzero: handler event logged with exit=1" \
    "$(cat "$work/once.out")" "pm handler thread=${tid:0:8} agent=nonzero exit=1"
contains "nonzero: flag event uses the fixed handler-exit keyword" \
    "$(cat "$work/once.out")" "pm flag thread=${tid:0:8} reason=handler-exit"
posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@nonzero" ]] && posted=1
done
check "nonzero: reply still posted despite the non-zero exit" 1 "$posted"
contains "nonzero: thread flagged with an exit-code-shaped reason" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)" "exited 1"

# --- scenario: a handler's own stderr echoes prose pm_flag_keyword would
#     otherwise mistake for one of the wake-time setup failures (handler
#     missing/not-regular/not-executable) it shares the "handler " prefix
#     with -- the keyword must still describe what actually happened
#     (a plain non-zero exit), not what the handler's stderr claims ---
mid="$(send_msg '@carol' '@lyingstderr' 'Lies in stderr' 'trigger')"
tid="$(thread_of "$mid")"
once
contains "lying stderr: flag event uses handler-exit, not the stderr's own words" \
    "$(cat "$work/once.out")" "pm flag thread=${tid:0:8} reason=handler-exit"
check "lying stderr: no misleading handler-missing keyword reached stdout" 0 \
    "$(grep -c -- 'reason=handler-missing' "$work/once.out")"

# --- scenario: a handler that BOTH writes a malformed reply AND exits
#     non-zero flags the thread with the malformed-file reason, not the
#     exit code -- pm_flag overwrites rather than appends, so whichever
#     flag call runs last wins, and the per-file parse failure is the more
#     actionable of the two ---
mid="$(send_msg '@carol' '@nonzeromalformed' 'Dies and posts garbage' 'trigger')"
tid="$(thread_of "$mid")"
once
flag_body="$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)"
contains "nonzero+malformed: the malformed-file reason wins the collision" \
    "$flag_body" "mail-1.md"
case "$flag_body" in
    *"exited 1"*) no "nonzero+malformed: the exit-code reason clobbered the malformed-file reason" "$flag_body" ;;
    *) ok "nonzero+malformed: the exit-code reason did not clobber the malformed-file reason" ;;
esac

# --- scenario: a handler that outruns the timeout is flagged and the
#     pass does not hang ---
export FORK_SANDBOX_HANDLER_TIMEOUT=2
mid="$(send_msg '@carol' '@slowpoke' 'Too slow' 'trigger')"
tid="$(thread_of "$mid")"
once
contains "timeout: thread flagged with a timeout-shaped reason" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)" "timed out after 2s"
contains "timeout: flag event uses the fixed handler-timeout keyword" \
    "$(cat "$work/once.out")" "pm flag thread=${tid:0:8} reason=handler-timeout"
timeout_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@slowpoke" ]] && timeout_posted=1
done
check "timeout: the killed handler's late write never posted" 0 "$timeout_posted"
unset FORK_SANDBOX_HANDLER_TIMEOUT

# --- scenario: a handler that ignores SIGTERM outlives the plain timeout
#     and is only ended once --kill-after's grace period elapses and
#     `timeout` escalates to SIGKILL (rc 137, not 124) -- the flag reason
#     must still name it a timeout, not "exited 137" ---
export FORK_SANDBOX_HANDLER_TIMEOUT=2
mid="$(send_msg '@carol' '@ignorepoke' 'Immune to TERM' 'trigger')"
tid="$(thread_of "$mid")"
once
contains "kill-after: SIGKILL-ended handler flagged as a timeout, not exited 137" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)" "timed out after 2s"
contains "kill-after: flag event uses handler-timeout, not handler-exit" \
    "$(cat "$work/once.out")" "pm flag thread=${tid:0:8} reason=handler-timeout"
ignorepoke_posted=0
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@ignorepoke" ]] && ignorepoke_posted=1
done
check "kill-after: the SIGKILL-ended handler's late write never posted" 0 "$ignorepoke_posted"
unset FORK_SANDBOX_HANDLER_TIMEOUT

# --- scenario: header-shaped lines in the BODY are never reinterpreted as
#     real headers ---
mid="$(send_msg '@carol' '@hostilebody' 'Hostile body' 'trigger')"
tid="$(thread_of "$mid")"
once
hostile_reply=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@hostilebody" ]] && hostile_reply="$f"
done
if [[ -n "$hostile_reply" ]]; then
    ok "hostile body: the reply posted (body-only header shapes did not break parsing)"
    check "hostile body: the forged To: line landed as literal body text" \
        "@carol" "$(header_of_file "$hostile_reply" To)"
    contains "hostile body: the forged Subject: line is not the real subject" \
        "$(header_of_file "$hostile_reply" Subject)" "Hostile body"
else
    no "hostile body: the reply posted (body-only header shapes did not break parsing)"
fi

# --- scenario: a forged Reply-To-Id (a real header, naming a message that
#     does not exist anywhere in the store) is refused by mail.sh's own
#     reply validation -- reused, unmodified, for a handler's harvest --
#     not silently accepted as a fabricated parent ---
mid="$(send_msg '@carol' '@hostileheader' 'Hostile header' 'trigger' 6)"
tid="$(thread_of "$mid")"
once
forged_reply=""
for f in "$FORK_SANDBOX_MAIL_ROOT/threads/$tid"/*.msg; do
    [[ -e "$f" ]] || continue
    [[ "$(header_of_file "$f" From)" == "@hostileheader" ]] && forged_reply="$f"
done
check "hostile header: a nonexistent forged parent never posts a reply" 0 \
    "$([[ -n "$forged_reply" ]] && echo 1 || echo 0)"
contains "hostile header: thread flagged naming the bad file" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid" 2>/dev/null)" "mail-1.md"

# --- scenario: a Cc-only handler wakes without ever calling the triage
#     classifier, even though this fleet has a top-level triage: block ---
: > "$HANDLER_LOG"
: > "$HANDLER_TRIAGE_LOG"
mid="$(send_msg '@carol' '@happy' 'Cc handler' 'trigger' 8 '@ccbot')"
tid="$(thread_of "$mid")"
once
check "cc handler: the Cc'd handler wakes" 1 \
    "$(grep -c -- 'AGENT:ccbot' "$HANDLER_LOG")"
check "cc handler: FS_HANDLER_VIA is 'cc' for a Cc-only wake" "VIA:cc" \
    "$(awk '/^AGENT:ccbot$/{f=1} f && /^VIA:/{print; exit}' "$HANDLER_LOG")"
check "cc handler: zero triage classifier calls" 0 \
    "$(grep -c -- '^----CALL----$' "$HANDLER_TRIAGE_LOG")"

# --- scenario: wake-on-cc: false suppresses a handler's Cc wake exactly
#     like an LLM seat's ---
: > "$HANDLER_LOG"
mid="$(send_msg '@carol' '@happy' 'No cc wake' 'trigger' 8 '@quietbot')"
tid="$(thread_of "$mid")"
once
check "wake-on-cc false: the opted-out handler never wakes" 0 \
    "$(grep -c -- 'AGENT:quietbot' "$HANDLER_LOG")"

# --- scenario: cmd_status does not error on a minimal exec-kind .env
#     record (no RUN_DIR/HARNESS/RESUMED fields) -- every exec wake writes
#     its HARVESTED marker in the same call as its .env record, so status's
#     live-run loop skips every one of them (R9d decision 2/3: a handler
#     wake is never "live"); this only asserts status does not crash on
#     the minimal record shape, not that it lists one ---
status_out="$("$postmaster" status 2>&1)"
status_rc=$?
check "status: exits 0 with only exec-kind runs recorded" 0 "$status_rc"
contains "status: no exec run is reported live (none harvested-and-live)" "$status_out" "live runs:"

# --- scenario: a thread render failure (forced here by corrupting the
#     triggering message's own Thread-ID, the same trick the LLM wake
#     render-failure scenario above uses) flags the thread and never
#     creates an outbox dir to leak -- pm_exec_wake only mkdir's $outbox
#     after the render succeeds ---
mid="$(send_msg '@carol' '@happy' 'Render will fail' 'trigger')"
tid="$(thread_of "$mid")"
bogus_tid="${tid}-missing"
msg_file="$(msg_file_of "$mid")"
sed -i "s/^Thread-ID: .*/Thread-ID: $bogus_tid/" "$msg_file"
: > "$HANDLER_LOG"
once
check "render failure: the handler never runs for the doomed message" 0 \
    "$(grep -c -- "^TRIGGER:$mid\$" "$HANDLER_LOG")"
contains "render failure: thread is flagged, naming the handler" \
    "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$bogus_tid" 2>/dev/null)" \
    "thread render failed for handler happy"
check "render failure: no outbox directory is left behind" 0 \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/handler-outbox" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"

# --- every handler run above (happy, malformed, nonzero, timeout,
#     hostile, cc, quietbot, the render failure above) removes its own
#     outbox once harvested (or never creates one) -- nothing should be
#     left accumulating under the mail root ---
check "handler-outbox: no run-id directory survives across every scenario above" 0 \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/handler-outbox" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"

unset FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER
unset FORK_SANDBOX_HANDLERS_DIR
export FORK_SANDBOX_FLEET_FILE="$SAVED_FLEET_FILE"
export FORK_SANDBOX_PERSONAS_DIR="$SAVED_PERSONAS_DIR"

# ============================================================
printf '\n== handler command must be a regular file (wake-time gate) ==\n'
# ============================================================
# `fleet check` (tested in fork-sandbox-fleet-test.sh) and deliver's own
# startup fleet check (pm_require_fleet_check) both already refuse a
# directory as `command:` before any message would ever route -- so the
# only way to exercise pm_exec_wake's OWN re-check is the same race its
# path-separator re-check already documents: the handler file changing
# on disk after the once-at-startup check has already passed. This runs
# deliver in loop mode (not --once, which re-runs the startup check every
# call) and swaps the handler command from a real file to a directory
# during the interval between two passes, so the startup check -- which
# already ran once and passed -- never sees the swap, but the next
# wake-time check does.

SAVED_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE"
SAVED_PERSONAS_DIR="$FORK_SANDBOX_PERSONAS_DIR"

new_root SWAP_HANDLERS_DIR
export FORK_SANDBOX_HANDLERS_DIR="$SWAP_HANDLERS_DIR"
printf '#!/bin/sh\n' > "$SWAP_HANDLERS_DIR/swap-handler"
chmod +x "$SWAP_HANDLERS_DIR/swap-handler"

new_root SWAP_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR="$SWAP_PERSONAS_DIR"
new_root SWAP_FLEET_DIR
export FORK_SANDBOX_FLEET_FILE="$SWAP_FLEET_DIR/fleet.yaml"
cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  swapseat:
    handler: exec
    command: swap-handler
EOF

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT

SWAP_LOG="$work/swap-deliver.log"
FORK_SANDBOX_POSTMASTER_INTERVAL=3 "$postmaster" deliver --project "$PROJECT_DIR" \
    >"$SWAP_LOG" 2>&1 &
swap_pid=$!

# Generous enough that the startup fleet check (a subprocess launch of
# fleet.sh) and the empty first pass have certainly both finished before
# the swap below lands -- if either is still mid-flight when the swap
# happens, the startup check would see the directory too and this test
# would be exercising the wrong checkpoint.
sleep 1
rm -f -- "$SWAP_HANDLERS_DIR/swap-handler"
mkdir -p -- "$SWAP_HANDLERS_DIR/swap-handler"

mid="$(send_msg '@carol' '@swapseat' 'Swap' 'trigger')"
tid="$(thread_of "$mid")"

swap_flag_file="$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid"
for _ in $(seq 1 100); do [[ -e "$swap_flag_file" ]] && break; sleep 0.1; done
contains "wake-time gate: a command swapped to a directory mid-run is refused, naming the handler" \
    "$(cat "$swap_flag_file" 2>/dev/null)" "is not a regular file"

kill "$swap_pid" 2>/dev/null || true
wait "$swap_pid" 2>/dev/null || true

unset FORK_SANDBOX_HANDLERS_DIR
export FORK_SANDBOX_FLEET_FILE="$SAVED_FLEET_FILE"
export FORK_SANDBOX_PERSONAS_DIR="$SAVED_PERSONAS_DIR"

# ============================================================
printf '\n== --kill-after 10 on every FS_TIMEOUT invocation ==\n'
# ============================================================
# A child that ignores SIGTERM must still die -- `timeout` alone reports
# rc 124 but lets an ignoring child run to completion. This stubs `timeout`
# itself (not the classifier/handler binary underneath it), so the
# assertion is on what postmaster.sh hands the coreutils binary, not on
# what the wrapped command sees.

SAVED_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE"
SAVED_PERSONAS_DIR="$FORK_SANDBOX_PERSONAS_DIR"
SAVED_PATH="$PATH"

new_root KILL_AFTER_TIMEOUT_STUB_DIR
KILL_AFTER_ARGV_LOG="$work/kill-after-argv.log"
export KILL_AFTER_ARGV_LOG
: > "$KILL_AFTER_ARGV_LOG"
# Answers --version as GNU coreutils so _fs_resolve_gnu_tool
# (fork-sandbox-lib.sh) accepts it as $FS_TIMEOUT; otherwise logs its full
# argv, then strips the leading `--kill-after N DURATION` it expects and
# execs the rest, so the wrapped classifier/handler still actually runs.
cat > "$KILL_AFTER_TIMEOUT_STUB_DIR/timeout" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == --version ]]; then
    echo "timeout (GNU coreutils) 9.9"
    exit 0
fi
{
    printf -- '----CALL----\n'
    for a in "$@"; do printf '%s\n' "$a"; done
} >> "$KILL_AFTER_ARGV_LOG"
if [[ "${1:-}" == --kill-after ]]; then
    shift 2
fi
shift
exec "$@"
STUB
chmod +x "$KILL_AFTER_TIMEOUT_STUB_DIR/timeout"
PATH="$KILL_AFTER_TIMEOUT_STUB_DIR:$PATH"

new_root KILL_AFTER_HANDLERS_DIR
export FORK_SANDBOX_HANDLERS_DIR="$KILL_AFTER_HANDLERS_DIR"
cat > "$KILL_AFTER_HANDLERS_DIR/quiet-handler" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$KILL_AFTER_HANDLERS_DIR/quiet-handler"

new_root KILL_AFTER_TRIAGE_STUB_BIN
cat > "$KILL_AFTER_TRIAGE_STUB_BIN/triage-launcher" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'wake\n'
STUB
chmod +x "$KILL_AFTER_TRIAGE_STUB_BIN/triage-launcher"
export FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER="$KILL_AFTER_TRIAGE_STUB_BIN/triage-launcher"

new_root KILL_AFTER_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR="$KILL_AFTER_PERSONAS_DIR"
new_root KILL_AFTER_FLEET_DIR
export FORK_SANDBOX_FLEET_FILE="$KILL_AFTER_FLEET_DIR/fleet.yaml"

cat > "$FORK_SANDBOX_PERSONAS_DIR/fromagent.md" <<'EOF'
Fromagent is the sender used throughout this group -- an agent, not the
operator, so its mail is subject to triage (never bypassed as
operator/external mail).
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/sender.md" <<'EOF'
Sender is the direct recipient; never gated by triage.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/triagee.md" <<'EOF'
Triagee is a Cc-only agent gated by the triage classifier.
EOF

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  fromagent:
    description: sender used throughout this group
  sender:
    description: direct recipient, never gated
  triagee:
    description: Cc-only agent gated by triage
  handlerseat:
    handler: exec
    command: quiet-handler
triage:
  harness: claude
EOF

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
send_msg '@fromagent' '@sender' 'kill-after fanout' 'body' 8 '@triagee,@handlerseat' > /dev/null
"$postmaster" deliver --project "$PROJECT_DIR" --once > /dev/null 2>&1

check "kill-after: two \$FS_TIMEOUT invocations (triage wake + handler wake)" 2 \
    "$(grep -c -- '----CALL----' "$KILL_AFTER_ARGV_LOG")"
check "kill-after: every invocation carries '--kill-after'" 2 \
    "$(grep -c -- '^--kill-after$' "$KILL_AFTER_ARGV_LOG")"
check "kill-after: every invocation's grace period is 10" 2 \
    "$(grep -c -- '^10$' "$KILL_AFTER_ARGV_LOG")"

PATH="$SAVED_PATH"
unset FORK_SANDBOX_POSTMASTER_TRIAGE_LAUNCHER
unset FORK_SANDBOX_HANDLERS_DIR
export FORK_SANDBOX_FLEET_FILE="$SAVED_FLEET_FILE"
export FORK_SANDBOX_PERSONAS_DIR="$SAVED_PERSONAS_DIR"

# ============================================================
printf '\n== event stream: a hostile Subject/body never reaches stdout ==\n'
# ============================================================
# The event stream's hard safety requirement: no sender-controlled text
# (Subject, body, raw From, attachment names) may ever become a field
# value on a "pm <event> ..." stdout line. mail.sh's own --subject
# validation (mail_validate_no_newline) already refuses a literal
# newline in a Subject at send time -- so the newline half of this
# attack is exercised via the BODY instead, which carries no such
# restriction.

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
evil_subject=$'\e[31mFAKE\e[0m pm spawn thread=deadbeef agent=evilsubject run=x via=to'
evil_body=$'first line\npm flag thread=deadbeef reason=evilbody\nlast line'
mid="$(send_msg '@alice' '@bob' "$evil_subject" "$evil_body" 8)"
tid="$(thread_of "$mid")"
once
stdout_content="$(cat "$work/once.out")"
check "hostile subject: raw ANSI escape never reaches stdout" 0 \
    "$(printf '%s' "$stdout_content" | grep -acF $'\e[31m')"
check "hostile subject: forged agent name never reaches stdout" 0 \
    "$(printf '%s' "$stdout_content" | grep -ac -- 'evilsubject')"
check "hostile body: forged reason never reaches stdout" 0 \
    "$(printf '%s' "$stdout_content" | grep -ac -- 'evilbody')"
check "hostile subject/body: every stdout line matches the fixed pm event shape" 0 \
    "$(printf '%s' "$stdout_content" | grep -avc -- '^pm \(spawn\|harvest\|flag\|refuse\|triage-skip\|handler\) thread=[0-9a-f]\{8\} ')"
check "hostile subject/body: exactly the one legitimate spawn event, nothing extra" 1 \
    "$(printf '%s' "$stdout_content" | grep -ac '^pm ')"

# ============================================================
printf '\n== --attach-dir: LLM seat wakes bind a thread'"'"'s attachments ==\n'
# ============================================================

# Extracts the argv block (the lines between two "----CALL----" markers) that
# spawned the given branch prefix, so an assertion can check what one
# specific spawn's argv carried instead of the whole log.
call_block_for_branch() {
    local prefix="$1" file="$2"
    awk -v p="$prefix" '
        /^----CALL----$/ { if (blk ~ ("\n" p)) { print blk }; blk = ""; next }
        { blk = blk "\n" $0 }
        END { if (blk ~ ("\n" p)) print blk }
    ' "$file"
}

new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
: > "$STUB_ARGV_LOG"

printf 'has attachment\n' > "$work/attach-fixture.txt"
mid_att="$("$MAIL" send --from '@alice' --to '@bob' --subject 'has attachment' \
    --body - --attach "$work/attach-fixture.txt" --hops 8 <<< 'see attached' 2>/dev/null)"
tid_att="$(thread_of "$mid_att")"
short_att="${tid_att:0:8}"
once
block_att="$(call_block_for_branch "sbx-mail-$short_att-bob-" "$STUB_ARGV_LOG")"
if [[ -n "$block_att" ]] && printf '%s' "$block_att" | grep -qx -- "$FORK_SANDBOX_MAIL_ROOT/threads/$tid_att/attachments"; then
    check "thread with an attachment: wake's argv carries --attach-dir" 1 \
        "$(printf '%s' "$block_att" | grep -c -- '--attach-dir')"
else
    check "thread with an attachment: wake's argv carries --attach-dir" 1 0
fi

: > "$STUB_ARGV_LOG"
mid_noatt="$(send_msg '@alice' '@bob' 'no attachment' 'plain body' 8)"
tid_noatt="$(thread_of "$mid_noatt")"
short_noatt="${tid_noatt:0:8}"
once
block_noatt="$(call_block_for_branch "sbx-mail-$short_noatt-bob-" "$STUB_ARGV_LOG")"
check "thread without an attachment: wake's argv carries no --attach-dir" 0 \
    "$(printf '%s' "$block_noatt" | grep -c -- '--attach-dir')"

# ============================================================
printf '\n== debounce: thread quiescence gates routing ==\n'
# ============================================================

# A fresh thread's newest message is younger than the debounce, so it is
# skipped with no side effect; the same message routes once the store's
# own mtimes say the thread has gone quiet.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=300
mid_defer="$(send_msg '@carol' '@alice' 'debounce defer' 'defer body' 8)"
tid_defer="$(thread_of "$mid_defer")"
: > "$STUB_ARGV_LOG"
once
check "debounce: a fresh thread is not routed" 0 \
    "$(grep -c -- '^--branch$' "$STUB_ARGV_LOG")"
touch -d '10 minutes ago' "$FORK_SANDBOX_MAIL_ROOT/threads/$tid_defer"/*.msg
: > "$STUB_ARGV_LOG"
once
check "debounce: an aged thread routes on the next pass" 1 \
    "$(grep -c -- '^--branch$' "$STUB_ARGV_LOG")"
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0

# The bug scenario end to end: a cover plus its patch replies post as a
# non-atomic burst. A pass that lands before the patches do must not
# spawn a patchless wake off the cover alone; only once the whole burst
# has aged past the debounce does a pass route the cover-triggered wake,
# and by then the full series is on-thread. The cover addresses a real
# seat (not just @operator) so a mid-burst pass has an actual candidate
# to prematurely wake if the gate were missing.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=300
burst_cover="$(send_msg '@carol' '@alice' 'burst cover' 'burst cover body' 8)"
tid_burst="$(thread_of "$burst_cover")"
: > "$STUB_ARGV_LOG"
once
check "debounce: a mid-burst pass does not spawn off the cover alone" 0 \
    "$(grep -c -- '^--branch$' "$STUB_ARGV_LOG")"
reply_msg '@carol' "$burst_cover" 'burst patch one body' --subject 'burst patch one' >/dev/null
reply_msg '@carol' "$burst_cover" 'burst patch two body' --subject 'burst patch two' --to '@alice' >/dev/null
touch -d '10 minutes ago' "$FORK_SANDBOX_MAIL_ROOT/threads/$tid_burst"/*.msg
: > "$STUB_ARGV_LOG"
once
burst_dir="$(argv_after --thread-dir "$STUB_ARGV_LOG")"
contains "debounce: released burst snapshot contains the first patch" \
    "$(cat "$burst_dir/thread.txt")" 'burst patch one body'
contains "debounce: released burst snapshot contains the triggering patch" \
    "$(cat "$burst_dir/thread.txt")" 'burst patch two body'
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0

# Disabled: explicit zero routes fresh mail immediately (also what the
# rest of this suite relies on via the shared env export above).
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0
send_msg '@carol' '@alice' 'debounce disabled' 'off body' 8 >/dev/null
: > "$STUB_ARGV_LOG"
once
check "debounce: FORK_SANDBOX_POSTMASTER_DEBOUNCE=0 routes immediately" 1 \
    "$(grep -c -- '^--branch$' "$STUB_ARGV_LOG")"

# Quiescence is judged per thread: an aged thread routes in the same pass
# where an unrelated fresh thread is deferred.
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=300
mid_aged="$(send_msg '@carol' '@alice' 'debounce aged thread' 'aged body' 8)"
tid_aged="$(thread_of "$mid_aged")"
touch -d '10 minutes ago' "$FORK_SANDBOX_MAIL_ROOT/threads/$tid_aged"/*.msg
mid_fresh="$(send_msg '@carol' '@bob' 'debounce fresh thread' 'fresh body' 8)"
tid_fresh="$(thread_of "$mid_fresh")"
short_aged="${tid_aged:0:8}"
short_fresh="${tid_fresh:0:8}"
: > "$STUB_ARGV_LOG"
once
check "debounce: per-thread -- the aged thread routes" 1 \
    "$(grep -c -- "^sbx-mail-$short_aged-alice-" "$STUB_ARGV_LOG")"
check "debounce: per-thread -- the fresh thread does not" 0 \
    "$(grep -c -- "^sbx-mail-$short_fresh-bob-" "$STUB_ARGV_LOG")"
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0

finish_suite
