#!/usr/bin/env bash
# lane-mail-peer-test.sh -- Exercise `lane-mail-peer add`: wiring two hosts
# for cross-host lane mail in one run, and refusing before changing anything.
#
# No real ssh, no network, no real ~/.ssh, no real lane-mail root. Each "host"
# is a throwaway directory holding a fake HOME with the tools installed where
# install.sh puts them (~/.claude/scripts), its own store root (the copies of
# lane-mail-lib.sh point at it) and its own config dir. `ssh` is a stub first
# on PATH that plays both ends of the wire:
#
#   * no `-i`: the operator's ordinary login. It runs the remote command in
#     a shell as the target host, HOME set, PATH WITHOUT the scripts dir (what
#     a non-interactive login gets).
#   * `-i <key>`: the mail key. It finds that key in the target's
#     authorized_keys and runs the forced command found on that line, with the
#     client's request in SSH_ORIGINAL_COMMAND, as sshd would -- so an
#     authorized_keys line that is wrong fails here too.
#
# Host keys are modelled: a mail-key connection to a destination the client
# has not seen fails ("Host key verification failed") unless the client passed
# StrictHostKeyChecking=accept-new, which records it.
#
# Usage: tests/lane-mail-peer-test.sh

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
export HOME="$scratch/realhome" TMPDIR="$scratch/tmp"
mkdir -p "$HOME" "$TMPDIR"
unset TMUX FORK_SANDBOX_MAIL_ROOT FORK_SANDBOX_CONFIG_DIR

stubbin="$scratch/stubbin"
mkdir -p "$stubbin"
cat > "$stubbin/ssh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
key="" opts=() ctl=0
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -i) key="$2" ;;
        -o) opts+=("$2") ;;
        -O) ctl=1 ;;
    esac
    shift 2
done
dest="$1"; shift
(( ctl )) && exit 0
printf 'key=%s opts=%s dest=%s request=%s\n' "${key:+yes}" "${opts[*]}" "$dest" "$*" >> "$SSH_LOG"
target="$(awk -F'\t' -v d="$dest" '$1 == d { print $2 }' "$SSH_TABLE")"
if [[ -z "$target" ]]; then
    echo "ssh: Could not resolve hostname $dest" >&2
    exit 255
fi
known="$HOME/../known_hosts"
accept=0 verbose=0
for o in "${opts[@]}"; do
    [[ "$o" == StrictHostKeyChecking=accept-new ]] && accept=1
    [[ "$o" == LogLevel=VERBOSE ]] && verbose=1
done
if [[ -z "$key" ]]; then
    # The operator's ordinary login: they have already answered any prompt.
    grep -qxF "$dest" "$known" 2>/dev/null || echo "$dest" >> "$known"
    exec env -u FORK_SANDBOX_CONFIG_DIR HOME="$target" PATH="$(dirname "$0"):/usr/bin:/bin" sh -c "$*"
fi
if ! grep -qxF "$dest" "$known" 2>/dev/null; then
    if (( accept )); then
        echo "$dest" >> "$known"
        (( verbose )) && echo "Server host key: ssh-ed25519 SHA256:TESTFP-$dest" >&2
    else
        echo "Host key verification failed." >&2
        exit 255
    fi
fi
blob="$(awk '{ print $2 }' "$key.pub")"
line="$(awk -v b="$blob" '{ for (i = 1; i <= NF; i++) if ($i == b) { print; exit } }' "$target/.ssh/authorized_keys" 2>/dev/null)"
if [[ -z "$line" ]]; then
    echo "Permission denied (publickey)." >&2
    exit 255
fi
forced="$(sed -n 's/^command="\([^"]*\)".*/\1/p' <<<"$line")"
[[ -n "$forced" && "$line" == *restrict* ]] || { echo "no forced command on the key's line" >&2; exit 255; }
exec env -i HOME="$target" PATH="/usr/bin:/bin" SSH_ORIGINAL_COMMAND="$*" sh -c "$forced"
STUB
chmod +x "$stubbin/ssh"

W="" n_worlds=0
# mk_world: a fresh pair of hosts, alpha and beta, nothing wired.
mk_world() {
    n_worlds=$(( n_worlds + 1 ))
    W="$scratch/w$n_worlds"
    local h d
    for h in alpha beta; do
        d="$W/$h"
        mkdir -p "$d/home/.claude/scripts" "$d/home/.config/fork-sandbox" "$d/root"
        cp "$scripts/lane-mail-peer" "$scripts/lane-mail.sh" "$scripts/lane-mail-serve" "$d/home/.claude/scripts/"
        sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$d/root|" "$scripts/lane-mail-lib.sh" > "$d/home/.claude/scripts/lane-mail-lib.sh"
        ln -s "$scripts/fork-sandbox-mail.sh" "$d/home/.claude/scripts/fork-sandbox-mail.sh"
        printf 'LANE_MAIL_PEER_NAME=%s\n' "$h" > "$d/home/.config/fork-sandbox/lane-mail.env"
    done
    printf 'alpha-dest\t%s\nbeta-dest\t%s\n' "$W/alpha/home" "$W/beta/home" > "$W/table"
    : > "$W/ssh.log"
}
# as <host> <command...>: run as that host's user.
as() {
    local h="$1"; shift
    env HOME="$W/$h/home" PATH="$stubbin:/usr/bin:/bin" SSH_TABLE="$W/table" SSH_LOG="$W/ssh.log" "$@"
}
peer_tool() { local h="$1"; shift; as "$h" "$W/$h/home/.claude/scripts/lane-mail-peer" "$@"; }
mail() { local h="$1"; shift; as "$h" "$W/$h/home/.claude/scripts/lane-mail.sh" "$@"; }
snap() {
    local h
    for h in alpha beta; do
        ( cd "$W/$h/home" && find . | sort && find . -type f -print0 | sort -z | xargs -0 md5sum ) 2>/dev/null
    done | md5sum
}
file_of() { cat "$W/$1/home/$2" 2>/dev/null; }
mode_of() { stat -c %a "$W/$1/home/$2" 2>/dev/null; }
count_of() { grep -c -- "$3" "$W/$1/home/$2" 2>/dev/null || true; }

echo "== a clean pair, wired both ways in one run =="
mk_world
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "add succeeds" "0" "$rc"
contains "it reports both probes passing" "$out" "alpha -> beta: pass (pong beta)"
contains "the back probe passes too" "$out" "beta -> alpha: pass (pong alpha)"
contains "it prints the host key it accepted on first contact" "$out" "SHA256:TESTFP-alpha-dest"
contains "it says what it changed" "$out" "changed:"
for h in alpha beta; do
    check "$h has a mail key" "yes" "$([[ -f "$W/$h/home/.ssh/lane-mail" && -f "$W/$h/home/.ssh/lane-mail.pub" ]] && echo yes || echo no)"
    check "$h's mail key is ed25519" "ssh-ed25519" "$(cut -d' ' -f1 "$W/$h/home/.ssh/lane-mail.pub")"
    check "$h's mail key has no passphrase" "0" "$(ssh-keygen -y -P '' -f "$W/$h/home/.ssh/lane-mail" >/dev/null 2>&1; echo $?)"
    check "$h's ~/.ssh is 0700" "700" "$(mode_of "$h" .ssh)"
    check "$h's authorized_keys is 0600" "600" "$(mode_of "$h" .ssh/authorized_keys)"
    check "$h's authorized_keys has exactly one line" "1" "$(wc -l < "$W/$h/home/.ssh/authorized_keys" | tr -d ' ')"
    check "$h's ssh config was never created" "no" "$([[ -e "$W/$h/home/.ssh/config" ]] && echo yes || echo no)"
    check "$h's LANE_MAIL_SSH names the absolute key and IdentitiesOnly" \
        "LANE_MAIL_SSH=ssh -i $W/$h/home/.ssh/lane-mail -o IdentitiesOnly=yes" \
        "$(grep '^LANE_MAIL_SSH=' "$W/$h/home/.config/fork-sandbox/lane-mail.env")"
    check "$h kept its peer name line" "1" "$(count_of "$h" .config/fork-sandbox/lane-mail.env "^LANE_MAIL_PEER_NAME=$h\$")"
done
check "beta's peers file names alpha with the back dest" "alpha alpha-dest" "$(file_of beta .config/fork-sandbox/lane-mail-peers)"
check "alpha's peers file names beta with the given dest" "beta beta-dest" "$(file_of alpha .config/fork-sandbox/lane-mail-peers)"
alpha_pub="$(cut -d' ' -f1,2 "$W/alpha/home/.ssh/lane-mail.pub")"
beta_pub="$(cut -d' ' -f1,2 "$W/beta/home/.ssh/lane-mail.pub")"
check "beta's authorized_keys line is the forced command at beta's install path, pinned to alpha" \
    "command=\"$W/beta/home/.claude/scripts/lane-mail-serve --peer alpha\",restrict $alpha_pub lane-mail@alpha" \
    "$(file_of beta .ssh/authorized_keys)"
check "alpha's authorized_keys line is pinned to beta" \
    "command=\"$W/alpha/home/.claude/scripts/lane-mail-serve --peer beta\",restrict $beta_pub lane-mail@beta" \
    "$(file_of alpha .ssh/authorized_keys)"

printf 'to beta\n' | mail alpha send --from @fe --to @x:beta --subject a2b --body - >"$W/id1" 2>"$W/err"; rc=$?
id1="$(cat "$W/id1")"
check "a send alpha -> beta succeeds" "0" "$rc"
check "it lands in beta's inbox" "$id1" "$(mail beta inbox x | cut -f1)"
printf 'to alpha\n' | mail beta send --from @be --to @y:alpha --subject b2a --body - >"$W/id2" 2>"$W/err"; rc=$?
id2="$(cat "$W/id2")"
check "a send beta -> alpha succeeds" "0" "$rc"
check "it lands in alpha's inbox" "$id2" "$(mail alpha inbox y | cut -f1)"
deliveries="$(grep 'request=lane-mail-serve deliver' "$W/ssh.log")"
check "both deliveries ran through the mail key" "2 0" "$(grep -c 'key=yes' <<<"$deliveries") $(grep -c accept-new <<<"$deliveries")"
check "ordinary deliveries keep strict host key checking" "0" "$(grep -c 'StrictHostKeyChecking' <<<"$deliveries")"
pings="$(grep 'request=lane-mail-serve ping' "$W/ssh.log")"
check "both probes ran through the mail key, BatchMode, accept-new" "2 2 2" \
    "$(grep -c 'key=yes' <<<"$pings") $(grep -c 'BatchMode=yes' <<<"$pings") $(grep -c 'StrictHostKeyChecking=accept-new' <<<"$pings")"
check "the setup connections used the ordinary login, not BatchMode, not the mail key" "0" \
    "$(grep 'key=' "$W/ssh.log" | grep -v 'request=lane-mail-serve' | grep -c -e 'key=yes' -e BatchMode)"

echo "== a second add changes nothing =="
before="$(snap)"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "the second add succeeds" "0" "$rc"
contains "it says nothing needed changing" "$out" "nothing to change"
lacks "it lists no changes" "$out" "changed:"
lacks "a two-way pair is not described as one way" "$out" "one way"
check "no file on either side changed" "$before" "$(snap)"
contains "it still proves both directions" "$out" "beta -> alpha: pass"
alpha_peers_before="$(file_of alpha .config/fork-sandbox/lane-mail-peers)"

echo "== re-running after a partial state only fills the gap =="
sed -i '/^LANE_MAIL_SSH=/d' "$W/alpha/home/.config/fork-sandbox/lane-mail.env"
: > "$W/alpha/home/.config/fork-sandbox/lane-mail-peers"
beta_auth="$(file_of beta .ssh/authorized_keys)"
beta_snap="$(cd "$W/beta/home" && find . -type f -print0 | sort -z | xargs -0 md5sum | md5sum)"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "add repairs alpha" "0" "$rc"
check "alpha's peers file is restored" "$alpha_peers_before" "$(file_of alpha .config/fork-sandbox/lane-mail-peers)"
check "the key already in beta's authorized_keys is left alone" "$beta_auth" "$(file_of beta .ssh/authorized_keys)"
check "nothing on beta changed" "$beta_snap" "$(cd "$W/beta/home" && find . -type f -print0 | sort -z | xargs -0 md5sum | md5sum)"
contains "it reports the key as already present" "$out" "already in"

echo "== --one-way wires alpha -> beta only =="
mk_world
out="$(peer_tool alpha add beta beta-dest --one-way 2>&1)"; rc=$?
check "add --one-way succeeds" "0" "$rc"
contains "the forward probe passes" "$out" "alpha -> beta: pass"
lacks "there is no back probe" "$out" "beta -> alpha"
out2="$(peer_tool alpha add beta beta-dest --one-way 2>&1)"
contains "a second --one-way add says it is already wired, one way" "$out2" "already wired (one way)"
check "beta has no mail key" "no" "$([[ -e "$W/beta/home/.ssh/lane-mail" ]] && echo yes || echo no)"
check "beta has no peers file" "no" "$([[ -e "$W/beta/home/.config/fork-sandbox/lane-mail-peers" ]] && echo yes || echo no)"
check "beta has no LANE_MAIL_SSH" "0" "$(count_of beta .config/fork-sandbox/lane-mail.env '^LANE_MAIL_SSH=')"
check "alpha has no authorized_keys" "no" "$([[ -e "$W/alpha/home/.ssh/authorized_keys" ]] && echo yes || echo no)"
printf 'x\n' | mail alpha send --from @fe --to @x:beta --subject s --body - >"$W/id" 2>/dev/null; rc=$?
check "alpha -> beta delivers" "0 $(cat "$W/id")" "$rc $(mail beta inbox x | cut -f1)"
printf 'x\n' | mail beta send --from @be --to @y:alpha --subject s --body - >/dev/null 2>&1; rc=$?
check "beta -> alpha does not" "1" "$rc"

echo "== existing files: other lines are never touched =="
mk_world
mkdir -m 700 "$W/beta/home/.ssh"
printf '# operator note\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEYOTHERKEYOTHERKEYOTHERKEYOTHERKEY0 me@laptop' > "$W/beta/home/.ssh/authorized_keys"
chmod 640 "$W/beta/home/.ssh/authorized_keys"
printf '# my peers\ngamma gamma-dest\n' > "$W/alpha/home/.config/fork-sandbox/lane-mail-peers"
head -2 "$W/beta/home/.ssh/authorized_keys" > "$W/auth.expect"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "add succeeds against existing files" "0" "$rc"
check "the existing authorized_keys lines are byte-identical and in order" "$(cat "$W/auth.expect")" "$(head -2 "$W/beta/home/.ssh/authorized_keys")"
check "the new line was added on its own line" "3" "$(wc -l < "$W/beta/home/.ssh/authorized_keys" | tr -d ' ')"
check "an existing authorized_keys keeps its mode" "640" "$(mode_of beta .ssh/authorized_keys)"
check "an existing peers file keeps its other lines" "# my peers
gamma gamma-dest
beta beta-dest" "$(file_of alpha .config/fork-sandbox/lane-mail-peers)"

echo "== an existing mail key is never overwritten =="
mk_world
mkdir -m 700 "$W/alpha/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -C preexisting -f "$W/alpha/home/.ssh/lane-mail"
key_before="$(md5sum "$W/alpha/home/.ssh/lane-mail" "$W/alpha/home/.ssh/lane-mail.pub")"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "add succeeds with a key already there" "0" "$rc"
check "the key pair is untouched" "$key_before" "$(md5sum "$W/alpha/home/.ssh/lane-mail" "$W/alpha/home/.ssh/lane-mail.pub")"
check "beta authorizes that very key" "1" "$(grep -c "$(cut -d' ' -f2 "$W/alpha/home/.ssh/lane-mail.pub")" "$W/beta/home/.ssh/authorized_keys")"

echo "== a key already authorized under other options is reported, not duplicated =="
mk_world
mkdir -m 700 "$W/alpha/home/.ssh" "$W/beta/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -C preexisting -f "$W/alpha/home/.ssh/lane-mail"
printf 'restrict %s\n' "$(cut -d' ' -f1,2 "$W/alpha/home/.ssh/lane-mail.pub")" > "$W/beta/home/.ssh/authorized_keys"
auth_before="$(file_of beta .ssh/authorized_keys)"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"
check "the existing line is left alone" "$auth_before" "$(file_of beta .ssh/authorized_keys)"
contains "the report says the key is already there" "$out" "already in $W/beta/home/.ssh/authorized_keys (line 1)"
contains "it flags a line without the forced command" "$out" "without 'lane-mail-serve --peer alpha'"

echo "== refusals change nothing on either side =="
refuses() {
    # refuses <label> <expected text> <add args...>
    local label="$1" want="$2"; shift 2
    local before out rc
    before="$(snap)"
    out="$(peer_tool alpha add "$@" 2>&1)"; rc=$?
    check "$label: exits 1" "1" "$rc"
    contains "$label: says why" "$out" "$want"
    contains "$label: says nothing was changed" "$out" "hanged"
    check "$label: no file on either side changed" "$before" "$(snap)"
    check "$label: no mail key was made" "no" "$([[ -e "$W/alpha/home/.ssh/lane-mail" || -e "$W/beta/home/.ssh/lane-mail" ]] && echo yes || echo no)"
}
mk_world
refuses "a typed name that mismatches" "calls itself 'beta', not 'delta'" delta beta-dest --back-dest alpha-dest

mk_world
rm "$W/beta/home/.claude/scripts/lane-mail-serve"
refuses "lane-mail-serve missing on the peer" "lane-mail-serve is not at $W/beta/home/.claude/scripts/lane-mail-serve" beta beta-dest --back-dest alpha-dest

mk_world
rm "$W/beta/home/.claude/scripts/lane-mail-peer"
refuses "fork-sandbox not installed on the peer" "not installed on beta-dest" beta beta-dest --back-dest alpha-dest

mk_world
printf 'alpha somewhere-else\n' > "$W/beta/home/.config/fork-sandbox/lane-mail-peers"
refuses "a conflicting peers line on the peer" "already has 'alpha somewhere-else'" beta beta-dest --back-dest alpha-dest
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"
contains "it names the value it would have added" "$out" "'alpha alpha-dest'"

mk_world
printf 'beta stale-dest\n' > "$W/alpha/home/.config/fork-sandbox/lane-mail-peers"
refuses "a conflicting peers line here" "already has 'beta stale-dest'" beta beta-dest --back-dest alpha-dest

mk_world
printf 'LANE_MAIL_SSH=ssh -F /somewhere/config\n' >> "$W/alpha/home/.config/fork-sandbox/lane-mail.env"
refuses "a conflicting LANE_MAIL_SSH here" "LANE_MAIL_SSH in $W/alpha/home/.config/fork-sandbox/lane-mail.env is 'ssh -F /somewhere/config'" beta beta-dest --back-dest alpha-dest
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"
contains "it tells the operator what to set" "$out" "-o IdentitiesOnly=yes"

mk_world
printf 'LANE_MAIL_SSH=ssh -F /somewhere/config\n' >> "$W/beta/home/.config/fork-sandbox/lane-mail.env"
refuses "a conflicting LANE_MAIL_SSH on the peer" "beta: LANE_MAIL_SSH in" beta beta-dest --back-dest alpha-dest

mk_world
printf 'LANE_MAIL_PEER_NAME=Bad_Name\n' > "$W/alpha/home/.config/fork-sandbox/lane-mail.env"
out="$(peer_tool alpha add beta beta-dest 2>&1)"; rc=$?
check "an invalid own peer name is refused" "1" "$rc"
contains "it names the key to set" "$out" "LANE_MAIL_PEER_NAME"

mk_world
mkdir -m 700 "$W/alpha/home/.ssh"; : > "$W/alpha/home/.ssh/lane-mail.pub"
refuses "a lone public key with no private key" "is never overwritten" beta beta-dest --back-dest alpha-dest

echo "== a failed probe: non-zero, changes stay, report says what failed =="
mk_world
printf '#!/bin/sh\necho "lane-mail-serve: refused: request is not allowed" >&2\nexit 2\n' > "$W/beta/home/.claude/scripts/lane-mail-serve"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "an old lane-mail-serve with no ping fails the run" "1" "$rc"
contains "the failing direction is named" "$out" "alpha -> beta: FAIL"
contains "the far side's reason is shown" "$out" "request is not allowed"
contains "the other direction still reports" "$out" "beta -> alpha: pass"
contains "it lists what it changed" "$out" "changed:"
check "the setup stays in place" "1" "$(wc -l < "$W/beta/home/.ssh/authorized_keys" | tr -d ' ')"
mk_world
printf '#!/bin/sh\necho "pong impostor"\n' > "$W/beta/home/.claude/scripts/lane-mail-serve"
out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
check "a pong naming another host fails the run" "1" "$rc"
contains "it says what answered" "$out" "answered 'pong impostor', expected 'pong beta'"
mk_world
out="$(peer_tool alpha add beta beta-dest --back-dest nowhere-dest 2>&1)"; rc=$?
check "a back destination beta cannot reach fails the run" "1" "$rc"
contains "the forward direction passed" "$out" "alpha -> beta: pass"
contains "the back direction failed" "$out" "beta -> alpha: FAIL"
check "beta's peers line for alpha stays in place" "alpha nowhere-dest" "$(file_of beta .config/fork-sandbox/lane-mail-peers)"

echo "== the default back destination is this host's hostname -f =="
mk_world
default_dest="$(hostname -f 2>/dev/null || true)"
if [[ "$default_dest" =~ ^[A-Za-z0-9_][A-Za-z0-9._@:%+-]*$ ]]; then
    peer_tool alpha add beta beta-dest >/dev/null 2>&1
    check "beta's peers line for alpha uses it" "alpha $default_dest" "$(file_of beta .config/fork-sandbox/lane-mail-peers)"
else
    ok "(skipped: hostname -f is not usable here)"
fi

echo "== a failed write is a failure, not a reported change =="
if [[ "$(id -u)" != 0 ]]; then
    mk_world
    printf '# mine\n' > "$W/alpha/home/.config/fork-sandbox/lane-mail-peers"
    chmod 444 "$W/alpha/home/.config/fork-sandbox/lane-mail-peers"
    out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
    check "an unwritable local peers file fails the add" "1" "$rc"
    contains "it says which write failed" "$out" "could not write"
    lacks "it does not report changes" "$out" "changed:"
    lacks "it does not reach the probes" "$out" "probes:"
    check "nothing was appended to the peers file" "# mine" "$(file_of alpha .config/fork-sandbox/lane-mail-peers)"

    mk_world
    mkdir -m 700 "$W/beta/home/.ssh"
    : > "$W/beta/home/.ssh/authorized_keys"
    chmod 400 "$W/beta/home/.ssh/authorized_keys"
    out="$(peer_tool alpha add beta beta-dest --back-dest alpha-dest 2>&1)"; rc=$?
    check "an unwritable authorized_keys on the peer fails the add" "1" "$rc"
    contains "it names the peer and the failed write" "$out" "beta: could not write"
    lacks "it does not claim the peer was changed" "$out" "changed:"
    check "the peer's authorized_keys is still empty" "0" "$(wc -c < "$W/beta/home/.ssh/authorized_keys" | tr -d ' ')"
else
    ok "(running as root: unwritable-file tests skipped)"
fi

echo "== usage, help =="
help_out="$(peer_tool alpha --help)"
contains "--help documents the verb" "$help_out" "lane-mail-peer add <peer> <ssh-dest>"
contains "--help says it is operator-only" "$help_out" "never allowlist it for an agent"
contains "--help documents the authorized_keys line" "$help_out" 'command="<R'"'"'s lane-mail-serve> --peer <S'"'"'s name>",restrict'
contains "--help documents --one-way" "$help_out" "--one-way"
peer_tool alpha >/dev/null 2>&1; check "no arguments is a usage error" "2" "$?"
peer_tool alpha remove beta >/dev/null 2>&1; check "an unknown verb is a usage error" "2" "$?"
peer_tool alpha add beta >/dev/null 2>&1; check "a missing destination is a usage error" "2" "$?"
peer_tool alpha add beta -oProxyCommand=x >/dev/null 2>&1; check "an option-shaped destination is refused" "2" "$?"
peer_tool alpha add beta 'a b' >/dev/null 2>&1; check "a destination with a space is refused" "2" "$?"
peer_tool alpha add Beta beta-dest >/dev/null 2>&1; check "a malformed peer name is refused" "2" "$?"
peer_tool alpha add alpha beta-dest >/dev/null 2>&1; check "pairing a host with itself is refused" "1" "$?"
check "the real HOME was never touched" "no" "$([[ -e "$HOME/.ssh" || -e "$HOME/.config" ]] && echo yes || echo no)"
check "the repo's lane-mail-peer is executable" "1" "$([[ -x "$scripts/lane-mail-peer" ]] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
