#!/usr/bin/env bash
# lane-mail-liveness-test.sh -- Exercise lane-mail registration liveness:
# the owning process `register` records, the per-turn refresh and backfill
# in lane-mail-hook.sh, and the readers of old one-line registrations.
#
# No real lane-mail root and no real registry. The scripts run from a
# scratch copy whose fixed LANE_MAIL_ROOT line (lane-mail-lib.sh) points at
# a temp dir and whose LANES_DIR lines (lane-mail.sh, lane-mail-hook.sh)
# name a registry directory unique to this run under /tmp/claude-<uid>,
# removed on exit; the scripts themselves gain no override. The Claude Code
# CLI is played by a script named `claude` (so its process is named that),
# and CLAUDE_PID is cleared so the real session running the test is never
# what a registration records.
#
# Usage: tests/lane-mail-liveness-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}

scratch="$(mktemp -d)"
reg_name="lane-mail-liveness-test-$$"
reg_dir="/tmp/claude-$(id -u)/$reg_name"
holds=()
cleanup() {
    local h
    for h in "${holds[@]:-}"; do [[ -n "$h" ]] && rm -f -- "$h"; done
    chmod -R u+w -- "$reg_dir" 2>/dev/null
    rm -rf -- "$scratch" "$reg_dir"
}
trap cleanup EXIT
unset CLAUDE_PID TMUX_PANE

mkdir -p "$scratch/root" "$scratch/fake" "$scratch/mods/lane-complete" "$scratch/home"
cp -r "$repo_dir/scripts" "$scratch/scripts"
cp -r "$repo_dir/mods/lane-complete/bin" "$scratch/mods/lane-complete/bin"
sed -i "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$scratch/root|" "$scratch/scripts/lane-mail-lib.sh"
sed -i "s|^LANES_DIR=.*|LANES_DIR=\"/tmp/claude-\$(id -u)/$reg_name\"|" \
    "$scratch/scripts/lane-mail.sh" "$scratch/scripts/lane-mail-hook.sh"
export HOME="$scratch/home" PATH="$scratch/scripts:$PATH"
sc="$scratch/scripts/lane-mail.sh"
hook="$scratch/scripts/lane-mail-hook.sh"

# The stand-in Claude Code CLI: runs one command; with $HOLD set it then
# writes $HOLD.ready and stays alive until $HOLD is removed.
cat > "$scratch/fake/claude" <<'EOF'
#!/bin/bash
"$@"
rc=$?
if [[ -n "${HOLD:-}" ]]; then
    : > "$HOLD.ready"
    while [[ -e "$HOLD" ]]; do sleep 0.05; done
fi
exit "$rc"
EOF
chmod +x "$scratch/fake/claude"
claude="$scratch/fake/claude"

# held <name> <command...>: runs the command under a fake claude that stays
# alive afterwards; sets held_pid. Output goes to $scratch/<name>.out; stdin
# comes from the file $held_in, when set.
held() {
    local name="$1" hold="$scratch/$1.hold" i
    shift
    : > "$hold"
    holds+=("$hold")
    HOLD="$hold" "$claude" "$@" < "${held_in:-/dev/null}" > "$scratch/$name.out" 2>&1 &
    held_pid=$!
    for (( i = 0; i < 200; i++ )); do
        [[ -e "$hold.ready" ]] && return 0
        sleep 0.05
    done
    return 1
}
release() {  # release <name> <pid>: lets a held fake claude exit
    rm -f -- "$scratch/$1.hold"
    wait "$2" 2>/dev/null
}

start_of() {  # field 22 of /proc/<pid>/stat
    local s
    read -r s < "/proc/$1/stat" || return 1
    s="${s##*) }"
    # shellcheck disable=SC2086  # split on purpose
    set -- $s
    printf '%s' "${20}"
}
reg_value() {  # reg_value <file> <key>
    sed -n "s/^$2=//p" "$1"
}
run_hook() {  # run_hook <mode> <session id>
    printf '{"session_id":"%s"}' "$2" | "$hook" "$1"
}

printf '== register records its owner ==\n'

held reg-a env CLAUDE_CODE_SESSION_ID=sess-a TMUX_PANE=%7 "$sc" register alpha \
    || no "fake claude came up" "$(cat "$scratch/reg-a.out")"
pid_a=$held_pid
f="$reg_dir/sess-a"
check "the first line is the lane" alpha "$(head -n1 "$f" 2>/dev/null)"
check "owner_pid is the nearest Claude Code ancestor" "$pid_a" "$(reg_value "$f" owner_pid)"
check "owner_start is that process's start time" "$(start_of "$pid_a")" "$(reg_value "$f" owner_start)"
check "tmux_pane is recorded when set" "%7" "$(reg_value "$f" tmux_pane)"
check "registration prints the lane alone" alpha "$(CLAUDE_CODE_SESSION_ID=sess-a "$sc" registration)"
release reg-a "$pid_a"

"$claude" env CLAUDE_CODE_SESSION_ID=sess-b "$sc" register beta >/dev/null 2>&1
if ! grep -q '^tmux_pane=' "$reg_dir/sess-b"; then
    ok "no tmux_pane line without TMUX_PANE"
else
    no "no tmux_pane line without TMUX_PANE" "$(cat "$reg_dir/sess-b")"
fi
out="$(CLAUDE_CODE_SESSION_ID=sess-b "$sc" unregister 2>&1)"
if [[ "$out" == *"unregistered from @beta" && ! -e "$reg_dir/sess-b" ]]; then
    ok "unregister names the lane and removes the registration"
else
    no "unregister names the lane and removes the registration" "$out"
fi
if [[ -z "$(find "$reg_dir" -name '.reg.*')" ]]; then
    ok "register leaves no temp file in the registry"
else
    no "register leaves no temp file in the registry"
fi

printf '== legacy one-line registrations ==\n'

printf 'legacy\n' > "$reg_dir/sess-old"
check "registration reads a legacy file" legacy "$(CLAUDE_CODE_SESSION_ID=sess-old "$sc" registration)"
printf 'hi\n' | "$sc" send --to @legacy --subject "hello legacy" --body - >/dev/null 2>&1 \
    || no "a message to @legacy is sent"
out="$(run_hook prompt sess-old 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"[lane-mail] @legacy: 1 unread"* ]]; then
    ok "the hook reads a legacy file"
else
    no "the hook reads a legacy file" "rc=$rc: $out"
fi
cp "$reg_dir/sess-old" "$reg_dir/sess-old2"
out="$(CLAUDE_CODE_SESSION_ID=sess-old2 "$sc" unregister 2>&1)"
check "unregister reads a legacy file" "lane-mail: session sess-old... unregistered from @legacy" "$out"

printf '== the hook refreshes last-seen and backfills the owner ==\n'

# The legacy-reader check above may have backfilled the file with whatever
# Claude Code runs this test; start this section from a legacy file again.
printf 'legacy\n' > "$reg_dir/sess-old"
touch -d '3 days ago' "$reg_dir/sess-old"
printf '{"session_id":"sess-old"}' > "$scratch/old.json"
held_in="$scratch/old.json" held hook-a "$hook" prompt \
    || no "fake claude came up" "$(cat "$scratch/hook-a.out")"
pid_h=$held_pid
f="$reg_dir/sess-old"
check "backfill keeps the lane on the first line" legacy "$(head -n1 "$f")"
check "backfill records the session's process" "$pid_h" "$(reg_value "$f" owner_pid)"
check "backfill records its start time" "$(start_of "$pid_h")" "$(reg_value "$f" owner_start)"
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
if (( age < 60 )); then ok "the hook refreshes last-seen"; else no "the hook refreshes last-seen" "age ${age}s"; fi
if [[ "$(cat "$scratch/hook-a.out")" == *"@legacy: 1 unread"* ]]; then
    ok "the banner still prints on a backfilling turn"
else
    no "the banner still prints on a backfilling turn" "$(cat "$scratch/hook-a.out")"
fi

# A live owner is left as recorded; only the time moves.
before="$(cat "$f")"
touch -d '2 hours ago' "$f"
run_hook stop sess-old >/dev/null 2>&1
check "a live registration is not rewritten" "$before" "$(cat "$f")"
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
if (( age < 60 )); then ok "a live registration's last-seen moves"; else no "a live registration's last-seen moves" "age ${age}s"; fi
release hook-a "$pid_h"

# Its owner gone (a session resumed in a new process), the next turn heals it.
held_in="$scratch/old.json" held hook-b "$hook" prompt \
    || no "fake claude came up" "$(cat "$scratch/hook-b.out")"
pid_h2=$held_pid
check "a dead owner is replaced by the process whose turn it is" "$pid_h2" "$(reg_value "$f" owner_pid)"
release hook-b "$pid_h2"

out="$(run_hook prompt sess-none 2>&1)"; rc=$?
if (( rc == 0 )) && [[ -z "$out" && ! -e "$reg_dir/sess-none" ]]; then
    ok "an unregistered session stays silent and gets no file"
else
    no "an unregistered session stays silent and gets no file" "rc=$rc: $out"
fi

# A registry the hook cannot write never fails the turn.
printf 'legacy\n' > "$reg_dir/sess-ro"
chmod a-w "$reg_dir"
out="$("$claude" "$hook" prompt <<<'{"session_id":"sess-ro"}' 2>&1)"; rc=$?
chmod u+w "$reg_dir"
if (( rc == 0 )) && [[ "$out" == *"@legacy: 1 unread"* ]]; then
    ok "an unwritable registry does not fail the hook"
else
    no "an unwritable registry does not fail the hook" "rc=$rc: $out"
fi
check "and leaves the registration as it was" legacy "$(cat "$reg_dir/sess-ro")"

if [[ -z "$(find "$reg_dir" -name '.reg.*')" ]]; then
    ok "the hook leaves no temp file in the registry"
else
    no "the hook leaves no temp file in the registry"
fi

printf '== lanes: live and stale ==\n'

rm -f "$reg_dir"/*
row() { "$sc" lanes | grep -P "^[a-z]+\t$1\t"; }
held live-z env CLAUDE_CODE_SESSION_ID=sess-z "$sc" register zeta \
    || no "fake claude came up" "$(cat "$scratch/live-z.out")"
pid_z=$held_pid
"$claude" env CLAUDE_CODE_SESSION_ID=sess-y "$sc" register theta >/dev/null 2>&1
check "a lane registered by a running session is live" live "$(row zeta | cut -f1)"
check "a lane whose registering process exited is stale" stale "$(row theta | cut -f1)"
if [[ "$(row theta | cut -f4)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
    ok "a stale lane shows its last-seen time"
else
    no "a stale lane shows its last-seen time" "$(row theta)"
fi
release live-z "$pid_z"
check "the live lane goes stale when its session ends" stale "$(row zeta | cut -f1)"
# A second session on the same lane, alive, makes it live again.
held live-z2 env CLAUDE_CODE_SESSION_ID=sess-z2 "$sc" register zeta \
    || no "fake claude came up" "$(cat "$scratch/live-z2.out")"
pid_z2=$held_pid
check "a lane is live when any of its registrations is" live "$(row zeta | cut -f1)"
check "and is listed once" 1 "$(row zeta | wc -l)"
release live-z2 "$pid_z2"
printf 'legacy\n' > "$reg_dir/sess-old"
check "lanes reads a legacy file (stale: no owner recorded)" stale "$(row legacy | cut -f1)"

printf '== send and reply warn about stale lanes ==\n'

# theta: registered, its process gone. zeta: registered, alive. omega: a
# mailbox and no registration.
held send-z env CLAUDE_CODE_SESSION_ID=sess-z "$sc" register zeta \
    || no "fake claude came up" "$(cat "$scratch/send-z.out")"
pid_z=$held_pid
mkdir -p "$scratch/root/agents/omega"
# send <args...>: body "hi" on stdin; sets out, err (stderr without the
# store's own "sent" line) and rc.
send() {
    out="$(printf 'hi\n' | "$sc" "$@" --body - 2>"$scratch/err")"; rc=$?
    err="$(grep -v '^fork-sandbox mail: sent ' "$scratch/err")"
}
send send --to @theta --subject "to theta"
want_re='^lane-mail: @theta: registered but no live session \(last seen [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}, (just now|[0-9]+ (min|h|d) ago)\); mail will wait$'
if (( rc == 0 )) && [[ "$err" =~ $want_re ]]; then
    ok "send to a stale lane warns on stderr and exits 0"
else
    no "send to a stale lane warns on stderr and exits 0" "rc=$rc err=$err"
fi
theta_mid="$out"
if [[ -n "$theta_mid" ]] && "$sc" inbox theta | grep -q "^$theta_mid"; then
    ok "and the message is delivered"
else
    no "and the message is delivered" "mid=$theta_mid inbox=$("$sc" inbox theta)"
fi

touch -d '3 hours ago' "$reg_dir/sess-y"
send send --to @theta --subject "later"
if [[ "$err" == *", 3 h ago); mail will wait" ]]; then ok "the warning gives the age of the last sighting"; else no "the warning gives the age of the last sighting" "$err"; fi

send send --to @zeta --subject "to zeta"
if (( rc == 0 )) && [[ -z "$err" ]]; then ok "send to a live lane does not warn"; else no "send to a live lane does not warn" "rc=$rc err=$err"; fi
send send --to @omega --subject "to omega"
if (( rc == 0 )) && [[ -z "$err" ]]; then ok "send to a mailbox-only lane does not warn"; else no "send to a mailbox-only lane does not warn" "rc=$rc err=$err"; fi

send send --to @theta,@zeta --cc @theta,@omega --subject "to all"
if (( rc == 0 )) && [[ "$(grep -c . <<<"$err")" == 1 && "$err" == *"@theta: registered but no live session"* ]]; then
    ok "a stale lane named twice among several recipients warns once"
else
    no "a stale lane named twice among several recipients warns once" "rc=$rc err=$err"
fi

send send --from @theta --to @zeta --subject "from theta"
from_theta="$out"
if (( rc == 0 )) && [[ -z "$err" ]]; then ok "the sender's own lane is not warned about"; else no "the sender's own lane is not warned about" "rc=$rc err=$err"; fi
send reply --from @zeta --reply-to "$from_theta"
if (( rc == 0 )) && [[ "$err" == *"@theta: registered but no live session"* ]]; then
    ok "reply warns about a stale lane it inherits as a recipient"
else
    no "reply warns about a stale lane it inherits as a recipient" "rc=$rc err=$err"
fi

mkdir -p "$HOME/.config/fork-sandbox"
printf 'LANE_MAIL_PEER_NAME=selfhost\n' > "$HOME/.config/fork-sandbox/lane-mail.env"
send send --to @theta:selfhost --subject "qualified"
if (( rc == 0 )) && [[ "$err" == *"@theta: registered but no live session"* ]]; then
    ok "a stale lane qualified with this host's own name warns too"
else
    no "a stale lane qualified with this host's own name warns too" "rc=$rc err=$err"
fi

send send --to @theta
if (( rc != 0 )) && [[ "$err" != *"no live session"* ]]; then
    ok "a send that fails does not warn"
else
    no "a send that fails does not warn" "rc=$rc err=$err"
fi
release send-z "$pid_z"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
