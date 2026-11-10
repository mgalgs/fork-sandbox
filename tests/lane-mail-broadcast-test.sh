#!/usr/bin/env bash
# lane-mail-broadcast-test.sh -- Exercise `@all`, lane mail's local
# broadcast address: who it reaches, the literal header, the local-only
# refusal, and that the fleet store does not apply it.
#
# No real lane-mail root and no real registry. The scripts run from a
# scratch copy whose fixed LANE_MAIL_ROOT line (lane-mail-lib.sh) points at
# a temp dir and whose LANES_DIR line (lane-mail.sh) names a registry
# directory unique to this run under /tmp/claude-<uid>, removed on exit.
# Registrations are written directly: a live one names this shell as its
# owner, a stale one names no owner. A second scratch copy plays a peer
# host, reached through an ssh stub that runs its lane-mail-serve the way
# the forced command would.
#
# Usage: tests/lane-mail-broadcast-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

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
reg_name="lane-mail-broadcast-test-$$"
reg_dir="/tmp/claude-$(id -u)/$reg_name"
cleanup() { rm -rf -- "$scratch" "$reg_dir"; }
trap cleanup EXIT
unset CLAUDE_PID TMUX_PANE FORK_SANDBOX_MAIL_ROOT

# mk_host <name>: a scripts copy rooted at $scratch/<name>/root, with its
# own config dir naming it as its peer name.
mk_host() {
    local d="$scratch/$1"
    mkdir -p "$d/root" "$d/cfg" "$d/mods/lane-complete" "$d/home"
    cp -r "$repo_dir/scripts" "$d/scripts"
    cp -r "$repo_dir/mods/lane-complete/bin" "$d/mods/lane-complete/bin"
    sed -i "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$d/root|" "$d/scripts/lane-mail-lib.sh"
    sed -i "s|^LANES_DIR=.*|LANES_DIR=\"/tmp/claude-\$(id -u)/$reg_name-$1\"|" "$d/scripts/lane-mail.sh"
    printf 'LANE_MAIL_PEER_NAME=%s\nLANE_MAIL_SSH=%s\n' "$1" "$scratch/ssh-stub" > "$d/cfg/lane-mail.env"
}
mk_host alpha
mk_host beta
reg_dir="/tmp/claude-$(id -u)/$reg_name-alpha"
mkdir -p "$reg_dir"
printf 'beta beta-dest\n' > "$scratch/alpha/cfg/lane-mail-peers"
printf 'alpha alpha-dest\n' > "$scratch/beta/cfg/lane-mail-peers"

# The ssh stand-in: <dest> is <host>-dest; the forced --peer is the other host.
cat > "$scratch/ssh-stub" <<STUB
#!/usr/bin/env bash
while [[ "\${1:-}" == -* ]]; do shift 2; done
to="\${1%-dest}"; shift
peer=alpha; [[ "\$to" == alpha ]] && peer=beta
SSH_ORIGINAL_COMMAND="\$*" FORK_SANDBOX_CONFIG_DIR="$scratch/\$to/cfg" \\
    exec "$scratch/\$to/scripts/lane-mail-serve" --peer "\$peer"
STUB
chmod +x "$scratch/ssh-stub"

root="$scratch/alpha/root"
lm() {
    env HOME="$scratch/alpha/home" FORK_SANDBOX_CONFIG_DIR="$scratch/alpha/cfg" \
        PATH="$scratch/alpha/scripts:$PATH" "$scratch/alpha/scripts/lane-mail.sh" "$@"
}
lm_beta() {
    env HOME="$scratch/beta/home" FORK_SANDBOX_CONFIG_DIR="$scratch/beta/cfg" \
        PATH="$scratch/beta/scripts:$PATH" "$scratch/beta/scripts/lane-mail.sh" "$@"
}
inbox_ids() { lm inbox "$1" | cut -f1 | sort | tr '\n' ' '; }
has() {  # has <lane> <id>: 1 when <id> is in <lane>'s inbox
    lm inbox "$1" --all | cut -f1 | grep -cx -- "$2"
}

# Lanes: a and b live, c stale (registered, no owner), d mailbox only.
read -r stat < "/proc/$$/stat"
read -ra stat <<<"${stat##*) }"
start="${stat[19]}"   # field 22, the start time
printf 'a\nowner_pid=%s\nowner_start=%s\n' "$$" "$start" > "$reg_dir/sess-a"
printf 'b\nowner_pid=%s\nowner_start=%s\n' "$$" "$start" > "$reg_dir/sess-b"
printf 'c\n' > "$reg_dir/sess-c"
mkdir -p "$root/agents/d"
check "the lanes are a, b live; c stale; d mailbox; beta a peer" \
    "live a live b stale c mailbox d peer beta " \
    "$(lm lanes | cut -f1,2 | tr '\t\n' '  ')"

echo "== send --to @all =="
out="$(printf 'disk full\n' | lm send --from @a --to @all --subject 'tmp is full' --body - 2>"$scratch/err")"; rc=$?
id1="$out"
check "send --to @all succeeds" "0" "$rc"
contains "it says whom @all reached" "$(cat "$scratch/err")" "lane-mail: @all reached @b, @c, @d"
for l in b c d; do
    check "@$l has it in its inbox" "1" "$(has "$l" "$id1")"
done
check "the sender @a does not" "0" "$(has a "$id1")"
check "@b sees it as To" "To" "$(lm inbox b | awk -F'\t' -v i="$id1" '$1 == i {print $3}')"
msg1="$(lm show "$id1")"
contains "the stored To still reads @all" "$msg1" $'\nTo: @all\n'
contains "the expansion is recorded alongside" "$msg1" $'\nX-Lane-Broadcast: @b, @c, @d\n'
check "the parked lane's watcher sees it" "1" \
    "$(env HOME="$scratch/alpha/home" FORK_SANDBOX_CONFIG_DIR="$scratch/alpha/cfg" PATH="$scratch/alpha/scripts:$PATH" \
        "$scratch/alpha/scripts/lane-mail-watch.sh" c --once | grep -c "(id $id1)")"
mkdir -p "$root/agents/e"
check "a lane that appears later does not get an earlier broadcast" "" "$(inbox_ids e)"
rmdir "$root/agents/e"

echo "== send --cc @all =="
out="$(printf 'switch accounts\n' | lm send --from @a --to @b --cc @all --subject accounts --body - 2>/dev/null)"; rc=$?
id2="$out"
check "send --cc @all succeeds" "0" "$rc"
for l in b c d; do
    check "@$l has the --cc @all message once" "1" "$(has "$l" "$id2")"
done
check "the sender does not" "0" "$(has a "$id2")"
check "@b, named in To, sees it as To" "To" "$(lm inbox b | awk -F'\t' -v i="$id2" '$1 == i {print $3}')"
check "@c sees it as Cc" "Cc" "$(lm inbox c | awk -F'\t' -v i="$id2" '$1 == i {print $3}')"
contains "the stored Cc still reads @all" "$(lm show "$id2")" $'\nCc: @all\n'

echo "== @all plus an explicit lane =="
out="$(printf 'dup\n' | lm send --from @a --to @all,@b --subject dup --body - 2>/dev/null)"; rc=$?
check "send --to @all,@b succeeds" "0" "$rc"
check "@b gets one copy" "1" "$(has b "$out")"
out="$(printf 'one-way\n' | lm send --to @all --subject oneway --body - 2>"$scratch/err")"; rc=$?
check "a one-way @all (no --from) reaches every lane, @a too" "0 1 1" "$rc $(has a "$out") $(has d "$out")"

echo "== refusals =="
before="$(find "$root/threads" -name '*.msg' | wc -l)"
err="$(printf 'x\n' | lm send --from @a --to @all:beta --subject s --body - 2>&1)"; rc=$?
check "@all:<host> is refused" "1" "$rc"
contains "it says broadcast is local-only" "$err" "broadcast is local-only"
err="$(printf 'x\n' | lm send --from @a --to @b --cc @all:alpha --subject s --body - 2>&1)"; rc=$?
check "@all naming this host is refused too" "1" "$rc"
err="$(printf 'x\n' | lm send --from @a --to @b --header 'X-Lane-Broadcast: @c' --subject s --body - 2>&1)"; rc=$?
check "a hand-written X-Lane-Broadcast header is refused" "1" "$rc"
check "nothing was stored by the refusals" "$before" "$(find "$root/threads" -name '*.msg' | wc -l)"
echo "== @all with a remote lane =="
out="$(printf 'both\n' | lm send --from @a --to @all,@x:beta --subject both --body - 2>"$scratch/err")"; rc=$?
check "@all plus @x:beta succeeds" "0" "$rc"
check "the remote lane gets it" "1" "$(lm_beta inbox x | cut -f1 | grep -cx -- "$out")"
for l in b c d; do check "local @$l gets it" "1" "$(has "$l" "$out")"; done
contains "the local copy keeps @all literal" "$(lm show "$out")" $'\nTo: @all, @x:beta\n'
mkdir -p "$scratch/beta/root/agents/b"
check "the peer does not expand @all for a lane of its own" "" \
    "$(lm_beta inbox b | cut -f1)"

echo "== the fleet store has no lane broadcast =="
# The fleet has an @all of its own (every fleet agent, resolved by the
# postmaster through `fork-sandbox-fleet.sh expand`). The store under it
# must not also apply lane mail's rules: no X-Lane-Broadcast inbox
# matching.
fleet="$scratch/fleet"
mkdir -p "$fleet"
fm() { env FORK_SANDBOX_MAIL_ROOT="$fleet" "$repo_dir/scripts/fork-sandbox-mail.sh" "$@"; }
fid="$(printf 'x\n' | fm send --from @a --to @all --header 'X-Lane-Broadcast: @b' --subject s --body - 2>/dev/null)"
check "X-Lane-Broadcast puts nothing in an inbox there" "" "$(fm inbox b | cut -f1)"
check "the store matches @all only as the literal name all" "$fid" "$(fm inbox all | cut -f1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
