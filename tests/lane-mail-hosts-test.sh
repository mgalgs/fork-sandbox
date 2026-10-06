#!/usr/bin/env bash
# lane-mail-hosts-test.sh -- Exercise cross-host lane mail: `@lane:host`
# addressing, lane-mail.sh's delivery over ssh, and lane-mail-serve, the
# forced command on the receiving side.
#
# No real ssh, no network, no real lane-mail root, no real ~/.ssh. Each
# "host" is a throwaway directory holding its own store root, its own config
# dir (peer name, peers file) and its own copy of lane-mail.sh and
# lane-mail-serve. The one thing the copies change is the fixed
# LANE_MAIL_ROOT line in lane-mail-lib.sh, which the test points at that
# host's temp root; the scripts themselves gain no root override. The client's
# ssh is a stub (LANE_MAIL_SSH in the host's lane-mail.env) that plays sshd:
# it looks the destination up in a table, then runs the target host's
# lane-mail-serve with the forced command's --peer argument and the client's
# request in SSH_ORIGINAL_COMMAND, exactly as sshd would. So a full two-host
# round trip runs in one process with two roots.
#
# Usage: tests/lane-mail-hosts-test.sh

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
lacks() {
    case "$2" in *"$3"*) no "$1" "'$3' unexpectedly found in: $2" ;; *) ok "$1" ;; esac
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/tmp"
export HOME="$scratch/home" TMPDIR="$scratch/tmp"
unset TMUX FORK_SANDBOX_MAIL_ROOT

# --- the ssh stand-in ------------------------------------------------------
# argv: [-o K=V]... <destination> <request words...>. $SSH_TABLE lines are
# `destination<TAB>server-dir<TAB>forced-peer`; the destination "dead" is
# unreachable. Every call is logged to $SSH_LOG.
cat > "$scratch/ssh-stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
opts=()
while [[ "${1:-}" == -* ]]; do
    opts+=("$1" "$2")
    shift 2
done
dest="$1"; shift
printf 'opts=%s dest=%s request=%s\n' "${opts[*]}" "$dest" "$*" >> "$SSH_LOG"
if [[ "$dest" == dead ]]; then
    echo "ssh: connect to host dead port 22: Connection refused" >&2
    exit 255
fi
line="$(awk -F'\t' -v d="$dest" '$1 == d' "$SSH_TABLE")"
[[ -n "$line" ]] || { echo "ssh: Could not resolve hostname $dest" >&2; exit 255; }
IFS=$'\t' read -r _ server peer <<<"$line"
SSH_ORIGINAL_COMMAND="$*" \
    FORK_SANDBOX_CONFIG_DIR="$server/cfg" \
    "$server/bin/lane-mail-serve" --peer "$peer"
STUB
chmod +x "$scratch/ssh-stub"
export SSH_LOG="$scratch/ssh.log"
: > "$SSH_LOG"

# mk_host <name>: root, config dir, bin dir (copies of the two scripts and
# the lib with the root line pointed at this host's temp root).
mk_host() {
    local name="$1" d="$scratch/$1"
    mkdir -p "$d/root" "$d/cfg" "$d/bin"
    cp "$scripts/lane-mail.sh" "$scripts/lane-mail-serve" "$d/bin/"
    sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$d/root|" "$scripts/lane-mail-lib.sh" > "$d/bin/lane-mail-lib.sh"
    ln -s "$scripts/fork-sandbox-mail.sh" "$d/bin/fork-sandbox-mail.sh"
    printf 'LANE_MAIL_PEER_NAME=%s\nLANE_MAIL_SSH=%s\n' "$name" "$scratch/ssh-stub" > "$d/cfg/lane-mail.env"
}
mk_host alpha
mk_host beta
mk_host gamma

# Peers files: alpha reaches beta, gamma and a dead peer; beta and gamma reach
# alpha. Each table is what the target's authorized_keys would pin: the
# forced --peer is the SENDER's name.
printf '# peers\nbeta beta-dest\ngamma gamma-dest\ngone dead\nmallory mallory-dest\n' > "$scratch/alpha/cfg/lane-mail-peers"
printf 'alpha alpha-dest\n' > "$scratch/beta/cfg/lane-mail-peers"
printf 'alpha alpha-dest\nbeta beta-dest\n' > "$scratch/gamma/cfg/lane-mail-peers"
printf 'beta-dest\t%s\talpha\ngamma-dest\t%s\talpha\nmallory-dest\t%s\tmallory\n' \
    "$scratch/beta" "$scratch/gamma" "$scratch/beta" > "$scratch/table-alpha"
printf 'alpha-dest\t%s\tbeta\n' "$scratch/alpha" > "$scratch/table-beta"
printf 'alpha-dest\t%s\tgamma\nbeta-dest\t%s\tgamma\n' "$scratch/alpha" "$scratch/beta" > "$scratch/table-gamma"

# ha/hb/hg: run lane-mail.sh as that host.
host_run() {
    local h="$1"; shift
    env PATH="$scratch/$h/bin:$scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/$h/cfg" \
        SSH_TABLE="$scratch/table-$h" "$scratch/$h/bin/lane-mail.sh" "$@"
}
ha() { host_run alpha "$@"; }
hb() { host_run beta "$@"; }
hg() { host_run gamma "$@"; }
msgs() { find "$scratch/$1/root" -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
ssh_calls() { wc -l < "$SSH_LOG" | tr -d ' '; }
hdr() { sed -n "s/^$2: //p" <<<"$1" | head -1; }

echo "== alpha -> beta =="
out="$(printf 'hello from alpha\n' | ha send --from @fe --to @x:beta --subject 'cross host' --body - 2>"$scratch/err")"; rc=$?
id1="$out"
check "send to a peer's lane succeeds and prints the id" "0" "$rc"
check "the id is a message id" "1" "$([[ "$id1" =~ ^[0-9a-f-]{36}$ ]] && echo 1 || echo 0)"
inbox_b="$(hb inbox x)"
check "the message shows in the peer's inbox for the lane" "$id1" "$(cut -f1 <<<"$inbox_b")"
check "the peer sees From: @<lane>:<sender host>" "@fe:alpha" "$(cut -f4 <<<"$inbox_b")"
b_msg="$(hb show "$id1")"
a_msg="$(ha show "$id1")"
contains "the peer stores To in its own bare form" "$b_msg" $'\nTo: @x\n'
contains "the sender's copy keeps the remote address" "$a_msg" $'\nTo: @x:beta\n'
contains "the sender's copy has the same id" "$a_msg" "Message-ID: $id1"
check "both copies share the thread id" "$(hdr "$a_msg" Thread-ID)" "$(hdr "$b_msg" Thread-ID)"
for h in Date Subject X-Hops; do
    check "both copies share $h" "$(hdr "$a_msg" "$h")" "$(hdr "$b_msg" "$h")"
done
check "the message body arrived intact" "hello from alpha" "$(sed -n '/^$/,$p' <<<"$b_msg" | tail -1)"
check "the sender's local inbox for the lane is empty" "" "$(ha inbox fe)"
last_call="$(tail -1 "$SSH_LOG")"
contains "ssh is told never to prompt" "$last_call" "BatchMode=yes"
contains "ssh gets a connect timeout" "$last_call" "ConnectTimeout=10"
contains "ssh runs the fixed server command" "$last_call" "dest=beta-dest request=lane-mail-serve deliver"
check "the receiving host's watcher sees the new message" "1" \
    "$(env PATH="$scratch/beta/bin:$scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/beta/cfg" \
        "$scripts/lane-mail-watch.sh" x --once | grep -c "new: @fe:alpha -- cross host (id $id1)")"
check "the sender's copy is findable in a thread tree" "1" "$(ha tree "$id1" | grep -c 'cross host')"

echo "== beta replies =="
out="$(printf 'hello back\n' | hb reply --from @x --reply-to "$id1" --body - 2>/dev/null)"; rc=$?
id2="$out"
check "a reply on the receiving side succeeds" "0" "$rc"
a_reply="$(ha show "$id2")"
contains "the reply reaches the original sender's store with the same id" "$a_reply" "Message-ID: $id2"
check "the reply threads under the original on the sender's side" "$id1" "$(hdr "$a_reply" Thread-ID)"
contains "the reply points at its parent" "$a_reply" "In-Reply-To: $id1"
contains "the reply is from the replying host's lane" "$a_reply" $'\nFrom: @x:beta\n'
contains "the sender's store has it addressed to the bare lane" "$a_reply" $'\nTo: @fe\n'
check "the original sender's inbox has the reply" "$id2" "$(ha inbox fe | cut -f1)"
b_reply="$(hb show "$id2")"
check "the replier's copy has the same thread id" "$id1" "$(hdr "$b_reply" Thread-ID)"
contains "the replier's copy keeps the remote address" "$b_reply" $'\nTo: @fe:alpha\n'
check "tree shows both messages on alpha" "2" "$(ha tree "$id1" | grep -c .)"
check "tree shows both messages on beta" "2" "$(hb tree "$id1" | grep -c .)"
printf 'second\n' | ha reply --from @fe --reply-to "$id2" --body - >/dev/null 2>&1; rc=$?
check "a reply-all back (no --to) is delivered across the hosts" "0 2" "$rc $(hb inbox x --all | wc -l | tr -d ' ')"
check "all four messages are on beta" "3" "$(msgs beta)"

echo "== several hosts =="
before_a="$(msgs alpha)"; before_b="$(msgs beta)"; before_g="$(msgs gamma)"
out="$(printf 'to many\n' | ha send --from @fe --to @x:beta,@y --cc @z:gamma --subject many --body - 2>/dev/null)"; rc=$?
check "a message with recipients on several hosts succeeds" "0" "$rc"
check "it is delivered to each remote host once" "$(( before_b + 1 )) $(( before_g + 1 ))" "$(msgs beta) $(msgs gamma)"
check "and stored once locally" "$(( before_a + 1 ))" "$(msgs alpha)"
check "the local recipient sees it in the local inbox" "$out" "$(ha inbox y | cut -f1)"
check "gamma's lane sees it as a Cc" "Cc" "$(hg inbox z | cut -f3)"
contains "every host's copy lists all the recipients" "$(hg show "$out")" $'\nTo: @x:beta, @y:alpha\n'

echo "== local addresses are unchanged =="
calls="$(ssh_calls)"
out="$(printf 'local\n' | ha send --from @fe --to @y,@x:alpha --subject local --body - 2>/dev/null)"; rc=$?
check "a bare address and the local host's own name send locally" "0 $calls" "$rc $(ssh_calls)"
contains "the local host's own name is stored bare" "$(ha show "$out")" $'\nTo: @y, @x\n'

echo "== failures leave nothing behind =="
before_a="$(msgs alpha)"; calls="$(ssh_calls)"
err="$(printf 'x\n' | ha send --from @fe --to @x:nowhere --subject s --body - 2>&1)"; rc=$?
check "an unknown host fails" "1" "$rc"
contains "it names the host" "$err" "nowhere"
contains "it names the peers file" "$err" "$scratch/alpha/cfg/lane-mail-peers"
check "nothing was stored and ssh never ran" "$before_a $calls" "$(msgs alpha) $(ssh_calls)"

before_b="$(msgs beta)"
err="$(printf 'x\n' | ha send --from @fe --to @x:beta,@q:nowhere --subject s --body - 2>&1)"; rc=$?
check "one unknown host among several fails before any delivery" "1 $before_b $before_a" "$rc $(msgs beta) $(msgs alpha)"

err="$(printf 'x\n' | ha send --from @fe --to @x:gone --subject s --body - 2>&1)"; rc=$?
check "an unreachable peer fails non-zero" "1" "$rc"
contains "the ssh error is reported" "$err" "Connection refused"
check "an unreachable peer leaves no local copy" "$before_a" "$(msgs alpha)"

err="$(printf 'x\n' | ha send --from @fe --to @x:beta --cc @q:gone --subject partial --body - 2>&1)"; rc=$?
check "a failure after one delivery fails non-zero" "1" "$rc"
contains "it says which host already has the message" "$err" "already delivered to: beta"
check "and still leaves no local copy" "$before_a" "$(msgs alpha)"
check "the message is on the host that succeeded" "$(( before_b + 1 ))" "$(msgs beta)"

before_b="$(msgs beta)"
err="$(printf 'x\n' | ha send --from @fe --to @x:mallory --subject s --body - 2>&1)"; rc=$?
check "a peer whose key is pinned to another name refuses the message" "1 $before_b" "$rc $(msgs beta)"
contains "the refusal reaches the sender" "$err" "does not match the sending peer"
check "the refused message has no local copy" "$before_a" "$(msgs alpha)"

err="$(printf 'x\n' | ha send --from @fe:beta --to @x:beta --subject s --body - 2>&1)"; rc=$?
check "--from must be a lane on this host" "1" "$rc"
contains "it says so" "$err" "--from must be a lane on this host"

printf 'attach\n' > "$scratch/att.txt"
err="$(printf 'x\n' | ha send --from @fe --to @x:beta --subject s --body - --attach "$scratch/att.txt" 2>&1)"; rc=$?
check "a cross-host message refuses an attachment" "1 $before_b $before_a" "$rc $(msgs beta) $(msgs alpha)"

mv "$scratch/alpha/cfg/lane-mail.env" "$scratch/alpha/cfg/lane-mail.env.save"
printf 'LANE_MAIL_PEER_NAME=Bad_Name\nLANE_MAIL_SSH=%s\n' "$scratch/ssh-stub" > "$scratch/alpha/cfg/lane-mail.env"
err="$(printf 'x\n' | ha send --from @fe --to @x:beta --subject s --body - 2>&1)"; rc=$?
check "with no valid peer name a cross-host send fails" "1 $before_b" "$rc $(msgs beta)"
contains "it names the key to configure" "$err" "LANE_MAIL_PEER_NAME"
mv "$scratch/alpha/cfg/lane-mail.env.save" "$scratch/alpha/cfg/lane-mail.env"

# The sender's peers file calls the receiver "beta" but the receiver knows
# itself as host-b: the mail could never reach an inbox, so it is a failed
# delivery, not a silent success.
cp "$scratch/beta/cfg/lane-mail.env" "$scratch/beta/cfg/lane-mail.env.save"
printf 'LANE_MAIL_PEER_NAME=host-b\nLANE_MAIL_SSH=%s\n' "$scratch/ssh-stub" > "$scratch/beta/cfg/lane-mail.env"
before_a="$(msgs alpha)"; before_b="$(msgs beta)"
err="$(printf 'lost\n' | ha send --from @fe --to @x:beta --subject mismatch --body - 2>&1)"; rc=$?
check "a peers-file name that is not the receiver's own name fails the send" "1" "$rc"
contains "the refusal names the receiver's peer name" "$err" "peer name is 'host-b'"
check "and nothing is stored on either side" "$before_a $before_b" "$(msgs alpha) $(msgs beta)"
mv "$scratch/beta/cfg/lane-mail.env.save" "$scratch/beta/cfg/lane-mail.env"

echo "== lane-mail-serve, through its forced-command interface =="
serve() {
    # serve <ssh-original-command|-> <stdin file> [serve args...], as host beta.
    local req="$1" input="$2"; shift 2
    local -a envv=(PATH="$scratch/beta/bin:$scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/beta/cfg")
    [[ "$req" == - ]] || envv+=(SSH_ORIGINAL_COMMAND="$req")
    env "${envv[@]}" "$scratch/beta/bin/lane-mail-serve" "$@" < "$input"
}
portable="$scratch/portable.msg"
FORK_SANDBOX_MAIL_ROOT="$scratch/emit-root" FORK_SANDBOX_CONFIG_DIR="$scratch/alpha/cfg" \
    bash -c 'mkdir -p "$FORK_SANDBOX_MAIL_ROOT"; printf "direct body\n" | "$0" send --emit --from @fe --to @x:beta --subject direct --body -' \
    "$scripts/fork-sandbox-mail.sh" > "$portable" 2>/dev/null
pid="$(sed -n 's/^Message-ID: //p' "$portable")"
check "the fixture is a portable message" "1" "$([[ -n "$pid" ]] && echo 1 || echo 0)"

outside_before="$(find "$scratch/home" "$scratch/tmp" "$scratch/emit-root" 2>/dev/null | sort | md5sum)"
before_b="$(msgs beta)"
one_line() { [[ "$(wc -l < "$1" | tr -d ' ')" == 1 ]]; }
refused() {
    # refused <label> <request|-> <expected rc> [serve args...]
    local label="$1" req="$2" want="$3"; shift 3
    local rc err="$scratch/serve.err"
    serve "$req" "$portable" "$@" >"$scratch/serve.out" 2>"$err"; rc=$?
    if [[ "$rc" == "$want" ]] && one_line "$err" && [[ ! -s "$scratch/serve.out" ]]; then
        ok "$label"
    else
        no "$label" "rc=$rc out=$(cat "$scratch/serve.out") err=$(cat "$err")"
    fi
}
refused "a missing --peer is refused" deliver 2
refused "a missing --peer with no request is refused" - 2
refused "a malformed --peer is refused" deliver 2 --peer 'Bad Peer'
refused "a path-shaped --peer is refused" deliver 2 --peer '../alpha'
refused "an unknown argument is refused" deliver 2 --peer alpha --root /tmp/elsewhere
refused "an interactive login (no request) is refused" - 2 --peer alpha
for verb in 'inbox x' 'show 1' 'list' 'seen x 1' 'bash' 'sh -c id' 'cat /etc/passwd' \
        'deliver extra' 'deliver; touch '"$scratch"'/pwned' 'deliver && touch '"$scratch"'/pwned' \
        'lane-mail-serve inbox x' 'lane-mail-serve deliver extra' 'DELIVER' ' deliver' 'deliver '; do
    refused "request '$verb' is refused" "$verb" 2 --peer alpha
done
refused "an empty request is refused" "" 2 --peer alpha
check "no refused request ran anything" "no" "$([[ -e "$scratch/pwned" ]] && echo yes || echo no)"
check "refusals stored nothing" "$before_b" "$(msgs beta)"

# ping: the allowlist grew by one read-only verb.
ping_before="$(find "$scratch/home" "$scratch/tmp" "$scratch/emit-root" "$scratch/beta/root" 2>/dev/null | sort | md5sum)"
out="$(serve ping /dev/null --peer alpha 2>"$scratch/serve.err")"; rc=$?
check "ping answers with this host's peer name" "0 pong beta" "$rc $out"
out="$(serve 'lane-mail-serve ping' /dev/null --peer alpha 2>/dev/null)"
check "the git-style spelling 'lane-mail-serve ping' is accepted" "pong beta" "$out"
out="$(serve ping "$portable" --peer alpha 2>/dev/null)"
check "ping ignores stdin" "pong beta" "$out"
check "ping writes nothing" "$ping_before" \
    "$(find "$scratch/home" "$scratch/tmp" "$scratch/emit-root" "$scratch/beta/root" 2>/dev/null | sort | md5sum)"
for verb in 'ping extra' 'ping; touch '"$scratch"'/pwned' 'PING' ' ping' 'ping ' 'lane-mail-serve ping extra'; do
    refused "request '$verb' is refused" "$verb" 2 --peer alpha
done
refused "ping still needs a --peer" ping 2
cp "$scratch/beta/cfg/lane-mail.env" "$scratch/beta/cfg/lane-mail.env.save"
printf 'LANE_MAIL_PEER_NAME=Bad_Name\n' > "$scratch/beta/cfg/lane-mail.env"
serve ping /dev/null --peer alpha >"$scratch/serve.out" 2>"$scratch/serve.err"; rc=$?
check "ping with no valid peer name fails, one line, no pong" "1 1 0" "$rc $(wc -l < "$scratch/serve.err" | tr -d ' ') $(grep -c pong "$scratch/serve.out")"
mv "$scratch/beta/cfg/lane-mail.env.save" "$scratch/beta/cfg/lane-mail.env"

out="$(serve deliver "$portable" --peer alpha 2>"$scratch/serve.err")"; rc=$?
check "deliver stores the message and acknowledges it" "0 ok $pid" "$rc $out"
check "the delivered message is in the lane's inbox" "$pid" "$(hb inbox x | grep -F "$pid" | cut -f1)"
sed 's/^Message-ID: .*/Message-ID: 22222222-2222-4222-8222-222222222222/;s/^Thread-ID: .*/Thread-ID: 22222222-2222-4222-8222-222222222222/' "$portable" > "$scratch/p2.msg"
out="$(serve 'lane-mail-serve deliver' "$scratch/p2.msg" --peer alpha 2>/dev/null)"
check "the git-style spelling 'lane-mail-serve deliver' is accepted" "ok 22222222-2222-4222-8222-222222222222" "$out"
serve deliver "$portable" --peer alpha >/dev/null 2>"$scratch/serve.err"; rc=$?
check "delivering the same message twice is refused, one line" "1 1" "$rc $(wc -l < "$scratch/serve.err" | tr -d ' ')"
contains "the duplicate refusal says so" "$(cat "$scratch/serve.err")" "already in this store"

before_b="$(msgs beta)"
sed 's/^Message-ID: .*/Message-ID: 33333333-3333-4333-8333-333333333333/;s/^Thread-ID: .*/Thread-ID: 33333333-3333-4333-8333-333333333333/' "$portable" > "$scratch/p3.msg"
serve deliver "$scratch/p3.msg" --peer gamma >/dev/null 2>"$scratch/serve.err"; rc=$?
check "a From host that differs from --peer is refused, one line" "1 1" "$rc $(wc -l < "$scratch/serve.err" | tr -d ' ')"
contains "the mismatch refusal says so" "$(cat "$scratch/serve.err")" "does not match the sending peer"
sed 's/^From: .*/From: not an address/' "$scratch/p3.msg" > "$scratch/p4.msg"
serve deliver "$scratch/p4.msg" --peer alpha >/dev/null 2>"$scratch/serve.err"; rc=$?
check "an invalid address is refused with one line" "1 1" "$rc $(wc -l < "$scratch/serve.err" | tr -d ' ')"
{ cat "$scratch/p3.msg"; head -c 1100000 /dev/zero | tr '\0' x; echo; } > "$scratch/p5.msg"
serve deliver "$scratch/p5.msg" --peer alpha >/dev/null 2>"$scratch/serve.err"; rc=$?
check "an oversized message is refused with one line" "1 1" "$rc $(wc -l < "$scratch/serve.err" | tr -d ' ')"
contains "the oversize refusal says so" "$(cat "$scratch/serve.err")" "byte cap"
sed '/^Thread-ID:/s/.*/Thread-ID: ..\/..\/..\/escape/' "$scratch/p3.msg" > "$scratch/p6.msg"
serve deliver "$scratch/p6.msg" --peer alpha >/dev/null 2>&1; rc=$?
check "a path-shaped thread id is refused" "1" "$rc"
check "none of those refusals stored anything" "$before_b" "$(msgs beta)"
sed 's/^From: .*/From: @spoof/' "$scratch/p3.msg" > "$scratch/p7.msg"
serve deliver "$scratch/p7.msg" --peer alpha >/dev/null 2>&1
contains "a bare From is stamped with the forced peer" "$(hb show 33333333-3333-4333-8333-333333333333)" $'\nFrom: @spoof:alpha\n'
check "the server wrote nothing outside its root" \
    "$outside_before" "$(find "$scratch/home" "$scratch/tmp" "$scratch/emit-root" 2>/dev/null | sort | md5sum)"
check "no scratch files are left in the root" "" \
    "$(find "$scratch/beta/root" -maxdepth 1 -name '.*' ! -name . | grep -E 'ingest|body|xhost' | head -2)"

check "lane-mail.sh works with no scripts dir on PATH (non-interactive ssh)" "$id1" \
    "$(env PATH=/usr/bin:/bin FORK_SANDBOX_CONFIG_DIR="$scratch/beta/cfg" "$scratch/beta/bin/lane-mail.sh" inbox x --all | cut -f1 | grep -Fx "$id1")"

help_out="$(PATH="$scratch/beta/bin:$PATH" "$scratch/beta/bin/lane-mail-serve" --help)"
contains "--help documents the authorized_keys line" "$help_out" 'command="lane-mail-serve --peer <name>",restrict'
contains "--help states the trust model" "$help_out" "ONLY source of"
contains "--help documents the ping verb" "$help_out" "pong <this host's"
contains "lane-mail.sh --help documents the address form" "$(ha --help)" "@lane:host"
check "the repo's lane-mail-serve is executable" "1" "$([[ -x "$scripts/lane-mail-serve" ]] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
