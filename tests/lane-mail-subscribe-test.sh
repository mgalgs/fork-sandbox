#!/usr/bin/env bash
# lane-mail-subscribe-test.sh -- Exercise lane-mail-subscribe: following a
# lane in a remote store, with a cursor per subscriber.
#
# No network and no mail API. The script is copied into a scratch bin dir
# beside a stub fork-sandbox-mail-remote.py that runs the real store against
# a temp root (the "remote" store), so the subscriber goes through exactly
# the argv it would send to the API. Two subscribers are two state dirs.
#
# Usage: tests/lane-mail-subscribe-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
scripts="$repo_dir/scripts"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}
contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "'$3' not found in: $2" ;; esac
}

scratch="$(mktemp -d)"
wait_pid=""
cleanup() {
    [[ -n "$wait_pid" ]] && kill "$wait_pid" 2>/dev/null
    rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/bin" "$scratch/remote" "$scratch/home"
export HOME="$scratch/home"
unset XDG_STATE_HOME FORK_SANDBOX_MAIL_ROOT
cp "$scripts/lane-mail-subscribe" "$scratch/bin/"
cat > "$scratch/bin/fork-sandbox-mail-remote.py" <<'STUB'
#!/usr/bin/env bash
[[ -e "$REMOTE_DOWN" ]] && { echo "mail API: connection refused" >&2; exit 2; }
[[ "$1" == mail ]] || { echo "stub: expected the mail tool" >&2; exit 2; }
shift
printf '%s\n' "$*" >> "$CALLS"
FORK_SANDBOX_MAIL_ROOT="$REMOTE_ROOT" exec "$STORE" "$@"
STUB
chmod +x "$scratch/bin/fork-sandbox-mail-remote.py"
export REMOTE_ROOT="$scratch/remote" STORE="$scripts/fork-sandbox-mail.sh" \
    CALLS="$scratch/calls" REMOTE_DOWN="$scratch/down"
: > "$CALLS"

post() {
    printf 'body\n' | FORK_SANDBOX_MAIL_ROOT="$REMOTE_ROOT" "$STORE" send --from @seat \
        --to @ops --cc @shop-outbox --subject "$1" --body - 2>/dev/null
}
# sub <who> <args>: run as subscriber <who>, with its own state dir.
sub() {
    local who="$1"; shift
    XDG_STATE_HOME="$scratch/state-$who" "$scratch/bin/lane-mail-subscribe" "$@"
}

echo "== usage =="
contains "--help prints the header" "$(sub a --help)" "Follow a lane in a remote mail store"
sub a unread '@shop' >/dev/null 2>&1; rc=$?
check "a lane with a leading @ is refused with exit 2" "2" "$rc"
sub a seen shop not-an-id >/dev/null 2>&1; rc=$?
check "a bad message id is refused with exit 2" "2" "$rc"
sub a frob shop >/dev/null 2>&1; rc=$?
check "an unknown verb is refused with exit 2" "2" "$rc"

echo "== first read starts from now =="
old="$(post 'before anyone subscribed')"
out="$(sub a unread shop-outbox 2>"$scratch/err")"
check "the first read shows nothing already there" "" "$out"
contains "and says it skipped it" "$(cat "$scratch/err")" "1 earlier messages skipped"
contains "it reads the lane's whole inbox through the API" "$(tail -1 "$CALLS")" "inbox shop-outbox --all"
out="$(sub b unread shop-outbox --backlog)"
check "--backlog shows what was already there" "$old" "$(cut -f1 <<<"$out")"
check "with its sender and subject" $'@seat\tbefore anyone subscribed' "$(cut -f3,4 <<<"$out")"

echo "== each subscriber has its own cursor =="
id1="$(post 'disk filling on node-a1')"
check "a new message is unseen for a" "$id1" "$(sub a unread shop-outbox | cut -f1)"
sub a seen shop-outbox "$id1"
check "a marks it seen and no longer sees it" "" "$(sub a unread shop-outbox)"
check "b still sees it" "1" "$(sub b unread shop-outbox | grep -c "$id1")"
check "the remote store's own seen list is untouched" "1" \
    "$(FORK_SANDBOX_MAIL_ROOT="$REMOTE_ROOT" "$STORE" inbox shop-outbox | grep -c "$id1")"

echo "== wait =="
out="$(sub b wait shop-outbox --interval 0.1)"; rc=$?
check "wait with unseen mail exits at once" "0" "$rc"
contains "printing a watcher-style line" "$out" "[lane-mail] @shop-outbox new: @seat -- disk filling on node-a1 (id $id1)"
sub a wait shop-outbox --interval 0.2 > "$scratch/wait-out" & wait_pid=$!
sleep 0.6
check "wait blocks while nothing is unseen" "1" "$(kill -0 "$wait_pid" 2>/dev/null && echo 1 || echo 0)"
id2="$(post 'pods evicted')"
for _ in $(seq 1 50); do kill -0 "$wait_pid" 2>/dev/null || break; sleep 0.1; done
wait "$wait_pid"; rc=$?
wait_pid=""
check "wait exits 0 when a message lands" "0" "$rc"
contains "naming it" "$(cat "$scratch/wait-out")" "pods evicted (id $id2)"
touch "$REMOTE_DOWN"
sub a seen shop-outbox "$id2"
out="$(sub a wait shop-outbox --interval 0.05)"; rc=$?
check "wait exits 1 after five failed reads" "1" "$rc"
contains "with the error" "$out" "remote read failed: mail API: connection refused"
sub a unread shop-outbox >/dev/null 2>"$scratch/err"; rc=$?
check "unread exits 1 when the API is unreachable" "1" "$rc"
rm -f "$REMOTE_DOWN"

echo "== show, tree =="
contains "show reads a message through the API" "$(sub a show "$id1")" "Subject: disk filling on node-a1"
contains "tree reads a thread through the API" "$(sub a tree "$id1")" "disk filling"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
