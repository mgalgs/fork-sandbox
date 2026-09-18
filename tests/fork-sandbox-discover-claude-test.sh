#!/usr/bin/env bash
# fork-sandbox-discover-claude-test.sh -- the `claude` configure discoverer's
# CLAUDE_CREDENTIALS override handling, and its pool/hook balancer handling
#
# Usage: tests/fork-sandbox-discover-claude-test.sh
#
# fork-sandbox-discover-claude reads CLAUDE_CREDENTIALS from
# $FORK_SANDBOX_CONFIG_DIR/claude.env so `configure`'s report matches what a
# real run resolves (fs_read_claude_credential in fork-sandbox-lib.sh). The
# only prior coverage (fork-sandbox-configure-test.sh) ran `discover` under
# env -i with an empty HOME and asserted only exit 0 -- true whether the
# override is read correctly, read from the wrong key, read from a
# hardcoded $HOME/.config/fork-sandbox that ignores FORK_SANDBOX_CONFIG_DIR,
# or not read at all. This file asserts on the actual reported source path,
# which only the correct read produces.
#
# It also runs fs_balance_claude_credential (CLAUDE_CREDENTIAL_POOL +
# CLAUDE_HEADROOM_HOOK) the same way a real run would, per the header
# comment in scripts/fork-sandbox-discover-claude -- this file pins the
# three behaviors that header promises: a healthy pool is reported as the
# pool's choice, a pool choice beats CLAUDE_CREDENTIALS, and a misconfigured
# pool reports nothing (exit 0) rather than falling back to the default.
#
# Runs entirely offline: no real credential, no network. HOME always points
# at a temp dir with no real ~/.claude, so the default-credential and
# Keychain paths this file doesn't exercise stay untouched.

# shellcheck disable=SC2016  # literal shell snippets handed to fake_hook are intentional
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
discover_claude="$repo_dir/scripts/fork-sandbox-discover-claude"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
newdir() { mktemp -d; }

# Runs `discover` with a clean HOME (no real ~/.claude, no real Keychain
# reachable -- this is Linux) and the given FORK_SANDBOX_CONFIG_DIR. An
# optional extra PATH dir (for a fake hook) is prepended ahead of the
# minimal PATH the other cases use.
run_discover() {
    local home="$1" config_dir="$2" extra_path="${3:-}"
    env -i PATH="${extra_path:+$extra_path:}/usr/bin:/bin" HOME="$home" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$discover_claude" discover
}

# A fake credential file -- content never matters to the balancer, only the
# path does; the balancer and the hook both only ever handle paths.
fake_cred() {
    local dir="$1" name="$2" path
    path="$dir/$name"
    printf '{"claudeAiOauth":{"accessToken":"fixture-%s"}}\n' "$name" > "$path"
    printf '%s' "$path"
}

# A fake hook executable named fork-sandbox-headroom-<name>, in its own PATH
# dir. $1 = name, $2 = script body (referencing "$@" for the candidate argv).
fake_hook() {
    local name="$1" body="$2" bindir
    bindir="$(mktemp -d)"; tmpdirs+=("$bindir")
    cat > "$bindir/fork-sandbox-headroom-$name" <<HOOK
#!/usr/bin/env bash
$body
HOOK
    chmod +x "$bindir/fork-sandbox-headroom-$name"
    printf '%s' "$bindir"
}

printf '== no override, no default credential: reports nothing ==\n'
home_empty="$(newdir)"; tmpdirs+=("$home_empty")
cfg_empty="$(newdir)"; tmpdirs+=("$cfg_empty")
out="$(run_discover "$home_empty" "$cfg_empty")"
check "empty environment: discover prints nothing" "" "$out"

printf '\n== CLAUDE_CREDENTIALS in claude.env is read from FORK_SANDBOX_CONFIG_DIR, not a hardcoded ~/.config/fork-sandbox ==\n'
home_a="$(newdir)"; tmpdirs+=("$home_a")
cfg_a="$(newdir)"; tmpdirs+=("$cfg_a")
cred_a="$cfg_a/team-credentials.json"
printf 'secret-token-marker-a\n' > "$cred_a"
printf 'CLAUDE_CREDENTIALS=%s\n' "$cred_a" > "$cfg_a/claude.env"
# A decoy claude.env under $HOME/.config/fork-sandbox: if the discoverer
# ever hardcodes that path instead of honoring FORK_SANDBOX_CONFIG_DIR, it
# reads THIS file's override (which names a file that does not exist)
# instead of $cfg_a's, and the assertions below fail.
mkdir -p "$home_a/.config/fork-sandbox"
printf 'CLAUDE_CREDENTIALS=%s/does-not-exist.json\n' "$home_a" > "$home_a/.config/fork-sandbox/claude.env"
out="$(run_discover "$home_a" "$cfg_a")"
check "override present: reports exactly one line" 1 "$(printf '%s' "$out" | grep -c .)"
check "override present: the line's source is the override path" \
    "present	-	Claude credential	$cred_a	found" "$out"
lacks_secret=1
[[ "$out" == *"secret-token-marker-a"* ]] && lacks_secret=0
check "override present: the credential content never reaches stdout" 1 "$lacks_secret"

printf '\n== an override naming a missing path fails closed -- no fallback to a real default credential ==\n'
home_b="$(newdir)"; tmpdirs+=("$home_b")
cfg_b="$(newdir)"; tmpdirs+=("$cfg_b")
mkdir -p "$home_b/.claude"
printf 'secret-token-marker-b\n' > "$home_b/.claude/.credentials.json"
printf 'CLAUDE_CREDENTIALS=%s/missing-credentials.json\n' "$cfg_b" > "$cfg_b/claude.env"
out="$(run_discover "$home_b" "$cfg_b")"
check "missing override, real default present: discover still prints nothing" "" "$out"

printf '\n== no override: falls back to the default HOME/.claude/.credentials.json ==\n'
home_c="$(newdir)"; tmpdirs+=("$home_c")
cfg_c="$(newdir)"; tmpdirs+=("$cfg_c")
mkdir -p "$home_c/.claude"
printf 'secret-token-marker-c\n' > "$home_c/.claude/.credentials.json"
out="$(run_discover "$home_c" "$cfg_c")"
check "no override: reports the default path as the source" \
    "present	-	Claude credential	$home_c/.claude/.credentials.json	found" "$out"

printf '\n== healthy pool: reports the hook'"'"'s choice ==\n'
home_d="$(newdir)"; tmpdirs+=("$home_d")
cfg_d="$(newdir)"; tmpdirs+=("$cfg_d")
cred_d1="$(fake_cred "$cfg_d" pool-d1.json)"
cred_d2="$(fake_cred "$cfg_d" pool-d2.json)"
hook_dir_d="$(fake_hook happy 'printf "%s\n" "$2"')"
printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\nCLAUDE_HEADROOM_HOOK=happy\n' "$cred_d1" "$cred_d2" \
    > "$cfg_d/claude.env"
out="$(run_discover "$home_d" "$cfg_d" "$hook_dir_d")"
check "healthy pool: reports the hook's chosen candidate as the source" \
    "present	-	Claude credential	$cred_d2	found" "$out"

printf '\n== pool set alongside CLAUDE_CREDENTIALS is refused, not resolved by falling back to CLAUDE_CREDENTIALS ==\n'
home_e="$(newdir)"; tmpdirs+=("$home_e")
cfg_e="$(newdir)"; tmpdirs+=("$cfg_e")
cred_pin_e="$(fake_cred "$cfg_e" pinned.json)"
cred_e1="$(fake_cred "$cfg_e" pool-e1.json)"
cred_e2="$(fake_cred "$cfg_e" pool-e2.json)"
hook_dir_e="$(fake_hook happy2 'printf "%s\n" "$1"')"
printf 'CLAUDE_CREDENTIALS=%s\nCLAUDE_CREDENTIAL_POOL=%s:%s\nCLAUDE_HEADROOM_HOOK=happy2\n' \
    "$cred_pin_e" "$cred_e1" "$cred_e2" > "$cfg_e/claude.env"
out="$(run_discover "$home_e" "$cfg_e" "$hook_dir_e")"
check "CLAUDE_CREDENTIALS + pool both set: discover reports nothing, not the pinned credential" \
    "" "$out"

printf '\n== misconfigured pool (no hook): reports nothing, not the real default credential ==\n'
home_f="$(newdir)"; tmpdirs+=("$home_f")
cfg_f="$(newdir)"; tmpdirs+=("$cfg_f")
mkdir -p "$home_f/.claude"
printf 'secret-token-marker-f\n' > "$home_f/.claude/.credentials.json"
cred_f="$(fake_cred "$cfg_f" pool-f.json)"
printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$cred_f" > "$cfg_f/claude.env"
out="$(run_discover "$home_f" "$cfg_f")"
check "pool without hook, real default present: discover still prints nothing" "" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
