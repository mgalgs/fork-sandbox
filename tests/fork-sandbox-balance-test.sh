#!/usr/bin/env bash
# fork-sandbox-balance-test.sh -- fs_balance_claude_credential, the shared
# lib function fork-sandbox.sh's local path and fork-sandbox-k8s.sh's direct
# entry point both call to pick a Claude credential from an operator
# configured pool via a headroom hook.
#
# This suite is a unit test of the lib function itself, sourced directly and
# called with fixture config dirs and fake hook executables -- it does not
# launch a real sandboxed run. The two call sites (fork-sandbox.sh wiring,
# run.env keys; fork-sandbox-k8s.sh wiring, --claude-credentials there) are
# covered by fork-sandbox-claude-credentials-test.sh and
# fork-sandbox-k8s-test.sh respectively, per the brief's commit sequence.
#
# Usage: tests/fork-sandbox-balance-test.sh

# shellcheck disable=SC2016  # literal shell snippets handed to fake_hook are intentional
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

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

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

newdir() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s' "$d"
}

# A fake credential file -- content never matters to the balancer, only the
# path does; the hook and the balancer both only ever handle paths.
fake_cred() {
    local dir="$1" name="$2" path
    path="$dir/$name"
    printf '{"claudeAiOauth":{"accessToken":"fixture-%s"}}\n' "$name" > "$path"
    printf '%s' "$path"
}

# A fake hook executable named fork-sandbox-headroom-<name>, in its own PATH
# dir. $1 = name, $2 = script body (the hook's own logic, referencing "$@"
# for the candidate argv).
fake_hook() {
    local name="$1" body="$2" bindir
    bindir="$(newdir)"
    cat > "$bindir/fork-sandbox-headroom-$name" <<HOOK
#!/usr/bin/env bash
$body
HOOK
    chmod +x "$bindir/fork-sandbox-headroom-$name"
    printf '%s' "$bindir"
}

config_dir=""
script_dir="$repo_dir/scripts"

run_balance() {
    fs_balance_claude_credential "$config_dir" "$script_dir"
}

printf '== not configured at all: empty output, exit 0, no hook invoked ==\n'
config_dir="$(newdir)"
out="$(run_balance)"; rc=$?
if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "no pool/hook configured: exits 0 with empty stdout"
else
    no "no pool/hook configured: exits 0 with empty stdout" "rc=$rc out='$out'"
fi

printf '\n== config errors, each refused loudly ==\n'

# CLAUDE_CREDENTIALS and CLAUDE_CREDENTIAL_POOL both set.
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
cred_b="$(fake_cred "$config_dir" b.json)"
{
    printf 'CLAUDE_CREDENTIALS=%s\n' "$cred_a"
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_b"
    printf 'CLAUDE_HEADROOM_HOOK=fake\n'
} > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "CLAUDE_CREDENTIALS + CLAUDE_CREDENTIAL_POOL both set is refused" \
        "both CLAUDE_CREDENTIALS and" "$err"
else
    no "CLAUDE_CREDENTIALS + CLAUDE_CREDENTIAL_POOL both set is refused" "exited 0: $err"
fi

# Pool without hook.
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a" > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "pool without hook is refused" "without" "$err"
else
    no "pool without hook is refused" "exited 0: $err"
fi

# Hook without pool.
config_dir="$(newdir)"
printf 'CLAUDE_HEADROOM_HOOK=fake\n' > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "hook without pool is refused" "without" "$err"
else
    no "hook without pool is refused" "exited 0: $err"
fi

# Bad hook name shape (uppercase, leading hyphen, underscore).
for bad_name in Fake -fake fake_hook; do
    config_dir="$(newdir)"
    cred_a="$(fake_cred "$config_dir" a.json)"
    {
        printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
        printf 'CLAUDE_HEADROOM_HOOK=%s\n' "$bad_name"
    } > "$config_dir/claude.env"
    err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
    if (( rc != 0 )); then
        contains "bad hook name '$bad_name' is refused" "not a plugin" "$err"
    else
        no "bad hook name '$bad_name' is refused" "exited 0: $err"
    fi
done

# Bad pool entries: relative, whitespace, colon (colon is the separator so a
# path containing one splits into two malformed entries -- either way it is
# refused).
config_dir="$(newdir)"
{
    printf 'CLAUDE_CREDENTIAL_POOL=relative-credentials.json\n'
    printf 'CLAUDE_HEADROOM_HOOK=fake\n'
} > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "relative pool entry is refused" "not an" "$err"
else
    no "relative pool entry is refused" "exited 0: $err"
fi

config_dir="$(newdir)"
{
    printf 'CLAUDE_CREDENTIAL_POOL=/tmp/has space/creds.json\n'
    printf 'CLAUDE_HEADROOM_HOOK=fake\n'
} > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "pool entry with whitespace is refused" "whitespace" "$err"
else
    no "pool entry with whitespace is refused" "exited 0: $err"
fi

config_dir="$(newdir)"
{
    printf 'CLAUDE_CREDENTIAL_POOL=/tmp/a.json::/tmp/b.json\n'
    printf 'CLAUDE_HEADROOM_HOOK=fake\n'
} > "$config_dir/claude.env"
err="$(run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "doubled ':' (empty pool entry) is refused" "empty entry" "$err"
else
    no "doubled ':' (empty pool entry) is refused" "exited 0: $err"
fi

printf '\n== happy path: hook choice is used ==\n'
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
cred_b="$(fake_cred "$config_dir" b.json)"
hook_dir="$(fake_hook happy 'printf "%s\n" "$2"')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$cred_a" "$cred_b"
    printf 'CLAUDE_HEADROOM_HOOK=happy\n'
} > "$config_dir/claude.env"
out="$(PATH="$hook_dir:$PATH" run_balance)"; rc=$?
if (( rc == 0 )) && [[ "$out" == "$cred_b" ]]; then
    ok "happy path: hook's choice (second candidate) is printed"
else
    no "happy path: hook's choice (second candidate) is printed" "rc=$rc out='$out'"
fi

marker="$(newdir)/hook-invoked"
hook_dir2="$(fake_hook marker "touch $marker; printf '%s\n' \"\$1\"")"
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=marker\n'
} > "$config_dir/claude.env"
out="$(PATH="$hook_dir2:$PATH" run_balance)"; rc=$?
if [[ -f "$marker" ]]; then
    ok "happy path: the hook is actually invoked with the pool as argv"
else
    no "happy path: the hook is actually invoked with the pool as argv" "no marker file"
fi

printf '\n== exit-0 contract violations: each a hard error ==\n'

config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
hook_empty="$(fake_hook empty 'true')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=empty\n'
} > "$config_dir/claude.env"
err="$(PATH="$hook_empty:$PATH" run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "empty stdout on exit 0 is a hard error" "printed nothing" "$err"
else
    no "empty stdout on exit 0 is a hard error" "exited 0: $err"
fi

config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
cred_b="$(fake_cred "$config_dir" b.json)"
hook_two="$(fake_hook twolines 'printf "%s\n%s\n" "$1" "$2"')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$cred_a" "$cred_b"
    printf 'CLAUDE_HEADROOM_HOOK=twolines\n'
} > "$config_dir/claude.env"
err="$(PATH="$hook_two:$PATH" run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "two lines on exit 0 is a hard error" "more than one line" "$err"
else
    no "two lines on exit 0 is a hard error" "exited 0: $err"
fi

config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
hook_nonmember="$(fake_hook nonmember 'printf "%s\n" "/not/a/pool/member.json"')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=nonmember\n'
} > "$config_dir/claude.env"
err="$(PATH="$hook_nonmember:$PATH" run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "a non-member path on exit 0 is a hard error" "not one" "$err"
else
    no "a non-member path on exit 0 is a hard error" "exited 0: $err"
fi

printf '\n== exit 2: hard error naming the pin-override escape hatch ==\n'
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
hook_exit2="$(fake_hook noroute 'exit 2')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=noroute\n'
} > "$config_dir/claude.env"
err="$(PATH="$hook_exit2:$PATH" run_balance 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "exit 2 (no routable candidate) is a hard error" "no routable credential" "$err"
    contains "exit 2's error names the --claude-credentials override" "--claude-credentials" "$err"
else
    no "exit 2 (no routable candidate) is a hard error" "exited 0: $err"
fi

printf '\n== exit 1 (or any other nonzero): warning, empty output, exit 0 ==\n'
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
hook_crash="$(fake_hook crash 'exit 1')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=crash\n'
} > "$config_dir/claude.env"
out="$(PATH="$hook_crash:$PATH" run_balance 2>/tmp/fs-balance-test-crash.err)"; rc=$?
crash_err="$(cat /tmp/fs-balance-test-crash.err)"
rm -f /tmp/fs-balance-test-crash.err
if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "hook crash (exit 1): exits 0 with empty stdout, falling through to default"
else
    no "hook crash (exit 1): exits 0 with empty stdout, falling through to default" "rc=$rc out='$out'"
fi
contains "hook crash (exit 1): warning names the hook and the exit code" "exited 1" "$crash_err"

printf '\n== hook resolution: PATH first, then beside the calling script dir ==\n'
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
beside_dir="$(newdir)"
cat > "$beside_dir/fork-sandbox-headroom-beside" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$1"
HOOK
chmod +x "$beside_dir/fork-sandbox-headroom-beside"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=beside\n'
} > "$config_dir/claude.env"
out="$(fs_balance_claude_credential "$config_dir" "$beside_dir")"; rc=$?
if (( rc == 0 )) && [[ "$out" == "$cred_a" ]]; then
    ok "a hook not on PATH resolves beside the calling script's own dir"
else
    no "a hook not on PATH resolves beside the calling script's own dir" "rc=$rc out='$out'"
fi

printf '\n== an unresolvable hook name is a hard error ==\n'
config_dir="$(newdir)"
cred_a="$(fake_cred "$config_dir" a.json)"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_a"
    printf 'CLAUDE_HEADROOM_HOOK=does-not-exist-anywhere\n'
} > "$config_dir/claude.env"
err="$(fs_balance_claude_credential "$config_dir" "$(newdir)" 2>&1 1>/dev/null)"; rc=$?
if (( rc != 0 )); then
    contains "an unresolvable hook name is a hard error" "cannot find" "$err"
else
    no "an unresolvable hook name is a hard error" "exited 0: $err"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
