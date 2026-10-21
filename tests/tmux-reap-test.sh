#!/usr/bin/env bash
# tmux-reap-test.sh — Exercise tmux-reap.sh against a PRIVATE tmux server.
#
# Usage: tests/tmux-reap-test.sh
#
# tmux ignores TMUX_TMPDIR when $TMUX is set, so a test that only set
# TMUX_TMPDIR could still reach (and kill) the operator's real server.
# This test unsets TMUX and TMUX_PANE for its whole run, points
# TMUX_TMPDIR at a scratch dir, and refuses to start unless the server
# socket tmux reports lives in that dir. The only processes it signals are
# `sleep`/bash children it started inside that private server.

# shellcheck disable=SC2015  # A && ok || no: ok never fails
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
reap="$repo_dir/scripts/tmux-reap.sh"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

tmp="$(mktemp -d)"
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$tmp/tmux"
mkdir -p "$TMUX_TMPDIR"

cleanup() {
    # Only ever against the private socket, verified below.
    [[ -n "${priv_sock:-}" ]] && tmux -S "$priv_sock" kill-server 2>/dev/null
    rm -rf -- "$tmp"
}
trap cleanup EXIT

tmux new-session -d -s main -x 80 -y 24 "sleep 600"
priv_sock="$(tmux display-message -p -t main '#{socket_path}')"
if [[ "$priv_sock" != "$tmp/"* ]]; then
    echo "refusing to run: tmux socket $priv_sock is outside the private dir" >&2
    priv_sock=""
    exit 2
fi

exists() { [[ "$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null)" == "$1" ]]; }

printf '== tmux-reap.sh ==\n'

"$reap" --help | grep -q 'Usage:' && ok "--help prints usage" || no "--help prints usage"

# A pane that will be reaped, and an innocent bystander in `main`.
victim="$(tmux new-window -d -t main: -P -F '#{pane_id}' "sleep 601")"
bystander="$(tmux new-window -d -t main: -P -F '#{pane_id}' "sleep 602")"

TMUX_PANE="$victim" "$reap" >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "reap exits 0" || no "reap exits 0" "rc=$rc"
[[ "$(tmux display-message -p -t "$victim" '#{session_name}')" == reaped ]] \
    && ok "reap moves \$TMUX_PANE into session reaped" || no "reap moves \$TMUX_PANE into session reaped"
[[ "$(tmux display-message -p -t "$bystander" '#{session_name}')" == main ]] \
    && ok "reap leaves other panes where they were" || no "reap leaves other panes where they were"
stamp="$(tmux display-message -p -t "$victim" '#{@reaped_at}')"
[[ "$stamp" =~ ^[0-9]+$ ]] && ok "reap stamps @reaped_at" || no "reap stamps @reaped_at" "'$stamp'"
n="$(tmux list-windows -t =reaped | wc -l)"
[[ "$n" == 1 ]] && ok "reaped holds just the moved pane (placeholder removed)" || no "reaped holds just the moved pane" "windows=$n"
exists "$victim" && ok "young stamped pane survives the sweep" || no "young stamped pane survives the sweep"

# Panes in reaped: one hand-moved without a stamp, one stamped but young,
# one stamped and old, one old-stamped outside reaped.
unstamped="$(tmux new-window -d -t main: -P -F '#{pane_id}' "sleep 603")"
tmux break-pane -d -s "$unstamped" -t =reaped:
outside="$(tmux new-window -d -t main: -P -F '#{pane_id}' "sleep 604")"
tmux set-option -p -t "$outside" @reaped_at 1

term_marker="$tmp/term"
old="$(tmux new-window -d -t main: -P -F '#{pane_id}' \
    "bash -c 'trap \"echo got-term > $term_marker; exit 0\" TERM; sleep 605 & wait'")"
tmux break-pane -d -s "$old" -t =reaped:
tmux set-option -p -t "$old" @reaped_at 1
sleep 1

out="$("$reap" --sweep 2>&1)"
case "$out" in *"Closed $old"*) ok "sweep reports the pane it closed" ;; *) no "sweep reports the pane it closed" "$out" ;; esac
exists "$old" && no "old stamped pane is closed" || ok "old stamped pane is closed"
[[ -s "$term_marker" ]] && ok "the pane's process got SIGTERM" || no "the pane's process got SIGTERM"
for p in "$victim" "$unstamped" "$bystander" "$outside"; do
    exists "$p" \
        && ok "sweep leaves $p alone" || no "sweep leaves $p alone"
done

# --grace: a young stamp is closed once the grace is shortened to 0, but
# the unstamped pane and the pane outside reaped still are not.
"$reap" --sweep --grace 0 >/dev/null 2>&1
exists "$victim" && no "--grace 0 closes a stamped pane" || ok "--grace 0 closes a stamped pane"
for p in "$unstamped" "$bystander" "$outside"; do
    exists "$p" \
        && ok "--grace 0 still leaves $p alone" || no "--grace 0 still leaves $p alone"
done

# A process that ignores SIGTERM is closed by kill-pane after --term-wait.
stubborn="$(tmux new-window -d -t main: -P -F '#{pane_id}' "bash -c 'trap \"\" TERM; sleep 606; sleep 606'")"
tmux break-pane -d -s "$stubborn" -t =reaped:
tmux set-option -p -t "$stubborn" @reaped_at 1
sleep 1
"$reap" --sweep --term-wait 2 >/dev/null 2>&1
exists "$stubborn" && no "a SIGTERM-ignoring pane is closed by kill-pane" || ok "a SIGTERM-ignoring pane is closed by kill-pane"

"$reap" --bogus >/dev/null 2>&1 && no "unknown option refused" || ok "unknown option refused"
env -u TMUX_PANE "$reap" >/dev/null 2>&1 && no "reap without TMUX_PANE refused" || ok "reap without TMUX_PANE refused"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
