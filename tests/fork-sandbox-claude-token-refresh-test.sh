#!/usr/bin/env bash
# fork-sandbox-claude-token-refresh-test.sh -- the host-side OAuth-refresh machinery
#
# Usage: tests/fork-sandbox-claude-token-refresh-test.sh
#
# Covers three pieces added for the "sandboxed step dies on a revoked
# access token" problem, all driven by a single stub `claude` executable
# that speaks just enough of the real contract (see the stub itself, below,
# and fork-sandbox-claude-token-probe's own header) to exercise each path:
#
#   - fs_claude_refresh_if_needed (fork-sandbox-lib.sh): the host-side early
#     refresh, its locking, and its validation of what came back.
#   - fork-sandbox-claude-token-probe and fs_claude_token_contract_check: the
#     contract probe's five checks, and the marker-caching wrapper around it.
#   - claude-sandboxed's live-sync loop: driven end to end through a stub
#     FORK_SANDBOX_BACKEND=test backend, exactly as
#     tests/claude-sandboxed-credentials-test.sh drives the rest of
#     claude-sandboxed offline.
#
# Never touches the real `claude`, the real `~/.claude`, or the real
# /var/tmp/claude-scratch/forks/.claude-token-contract cache -- every
# credential is a fixture under a temp HOME or temp work dir, and every
# contract-cache lookup is pointed at FS_CLAUDE_TOKEN_CONTRACT_DIR overrides
# private to this run. fs_claude_refresh_if_needed's own scratch dir is the
# one exception: it is hardcoded (by design -- see fork-sandbox-lib.sh) under
# /var/tmp/claude-scratch/forks/claude-fork-token-refresh.*, exactly like
# every other scratch dir this repo's machinery creates there, and this
# suite checks it is removed again on every path.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091
source "$repo_dir/scripts/fork-sandbox-lib.sh"
fs_require_gnu_tools || exit 1

work="$(mktemp -d)"; tmpdirs+=("$work")

write_cred() {
    # write_cred PATH MINUTES-FROM-NOW [MCPOAUTH-JSON]
    local path="$1" mins="$2" mcp="${3:-}" ms
    ms=$(( ($(date +%s) + mins * 60) * 1000 ))
    if [[ -n "$mcp" ]]; then
        jq -n --arg at "orig-access-token" --arg rt "orig-refresh-token" --argjson exp "$ms" --argjson mcp "$mcp" \
            '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $exp, scopes: ["user:inference"]}, mcpOAuth: $mcp}' \
            > "$path"
    else
        jq -n --arg at "orig-access-token" --arg rt "orig-refresh-token" --argjson exp "$ms" \
            '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $exp, scopes: ["user:inference"]}}' \
            > "$path"
    fi
}

count_refresh_scratch_dirs() {
    compgen -G '/var/tmp/claude-scratch/forks/claude-fork-token-refresh.*' 2>/dev/null | wc -l | tr -d ' '
}

# ---- the stub claude -------------------------------------------------------
#
# One executable, two personalities, picked by which env vars the caller
# sets:
#   - STUB_MODE=success|blank|failexit|noop -- a simple, unconditional
#     refresh outcome, for fs_claude_refresh_if_needed's own tests, which
#     only ever invoke it as `claude mcp list`.
#   - PROBE_BREAK_CHECK=<name>, or neither set -- a small, faithful model of
#     claude's real OAuth-refresh contract (startup refresh on an expired
#     token, the 401 handler's forced refresh, honouring a live lock,
#     breaking a stale one), for fork-sandbox-claude-token-probe's own
#     tests. Left unset, every check should pass; set to the name of one of
#     the probe's checks, it deliberately violates exactly that one
#     behaviour so the corresponding check can be seen to fail and name
#     itself.
# Every invocation is recorded to $STUB_CALL_LOG when that is set, so tests
# can assert "the stub was/was not called" without caring what it did.
stub="$work/claude-stub"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# fake claude for fork-sandbox-claude-token-refresh-test.sh. Speaks enough
# of the real claude's contract for fork-sandbox-claude-token-probe's
# checks to exercise, including the two marker strings its check 5 greps
# for: tengu_oauth_401_recovered_from_keychain and .oauth_refresh.lock.
set -uo pipefail

if [[ -n "${STUB_CALL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$STUB_CALL_LOG"
fi

if [[ "${1:-}" == --version ]]; then
    printf '%s\n' "${STUB_VERSION:-9.9.9-test-stub}"
    exit 0
fi

cred="${CLAUDE_CONFIG_DIR:-}/.credentials.json"
[[ -f "$cred" ]] || exit 0

lock1="${CLAUDE_CONFIG_DIR:-}/.oauth_refresh.lock"
lock2="$(cd "${CLAUDE_CONFIG_DIR:-.}" && pwd -P).lock"

lock_live() {
    local d="$1" mtime age
    [[ -d "$d" ]] || return 1
    if [[ "${PROBE_BREAK_CHECK:-}" == stale_lock ]]; then
        return 0
    fi
    mtime="$(stat -c %Y "$d" 2>/dev/null)" || return 1
    age=$(( $(date +%s) - mtime ))
    (( age < 60 ))
}

break_stale_locks() {
    local d
    for d in "$lock1" "$lock2"; do
        [[ -d "$d" ]] || continue
        lock_live "$d" && continue
        rmdir "$d" 2>/dev/null || true
    done
}

any_lock_blocks() {
    [[ "${PROBE_BREAK_CHECK:-}" == lock_live ]] && return 1
    lock_live "$lock1" && return 0
    lock_live "$lock2" && return 0
    return 1
}

blank() {
    jq '.claudeAiOauth.accessToken = "" | .claudeAiOauth.refreshToken = ""' "$cred" > "$cred.tmp" 2>/dev/null \
        && mv "$cred.tmp" "$cred"
}

succeed() {
    jq --arg at "stub-new-access-$$-$RANDOM" --arg rt "stub-new-refresh-$$-$RANDOM" \
        --argjson exp "$(( ($(date +%s) + 28800) * 1000 ))" \
        '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp' \
        "$cred" > "$cred.tmp" 2>/dev/null && mv "$cred.tmp" "$cred"
}

if [[ -n "${STUB_MODE:-}" ]]; then
    case "$STUB_MODE" in
        success) succeed ;;
        blank) blank ;;
        failexit) exit 1 ;;
        noop) : ;;
    esac
    exit 0
fi

break_stale_locks

case "${1:-}" in
    mcp)
        [[ "${PROBE_BREAK_CHECK:-}" == startup_refresh ]] && exit 0
        expires_at="$(jq -r '.claudeAiOauth.expiresAt // 0' "$cred" 2>/dev/null)"
        now_ms=$(( $(date +%s) * 1000 ))
        (( expires_at > now_ms )) && exit 0
        any_lock_blocks && exit 0
        blank
        ;;
    -p)
        [[ "${PROBE_BREAK_CHECK:-}" == handler_401 ]] && exit 1
        rt="$(jq -r '.claudeAiOauth.refreshToken // ""' "$cred" 2>/dev/null)"
        [[ -z "$rt" ]] && exit 1
        any_lock_blocks && exit 1
        blank
        ;;
esac
exit 0
STUB
chmod +x "$stub"

nomarkers_stub="$work/claude-stub-nomarkers"
cat > "$nomarkers_stub" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && printf 'nomarkers-stub\n'
exit 0
STUB
chmod +x "$nomarkers_stub"

echo '=== fs_claude_refresh_if_needed ==='

printf '\n== plenty of time left: no-op, no lock, stub not called ==\n'
plenty_cred="$work/plenty-credentials.json"
write_cred "$plenty_cred" 150
: > "$work/plenty-call-log"
before_scratch="$(count_refresh_scratch_dirs)"
STUB_CALL_LOG="$work/plenty-call-log" fs_claude_refresh_if_needed "$plenty_cred" "$stub"
if [[ ! -s "$work/plenty-call-log" ]]; then
    ok "the stub is not called when at least 120m remain"
else
    no "the stub is not called when at least 120m remain" "$(cat "$work/plenty-call-log")"
fi
if [[ ! -d "$work/.oauth_refresh.lock" ]]; then
    ok "no lock dir is created when at least 120m remain"
else
    no "no lock dir is created when at least 120m remain" "$work/.oauth_refresh.lock exists"
fi
after_scratch="$(count_refresh_scratch_dirs)"
if [[ "$after_scratch" == "$before_scratch" ]]; then
    ok "no refresh scratch dir is created when at least 120m remain"
else
    no "no refresh scratch dir is created when at least 120m remain" "count went from $before_scratch to $after_scratch"
fi

printf '\n== under 120m: a successful refresh updates the real file and preserves mcpOAuth ==\n'
due_cred="$work/due-credentials.json"
write_cred "$due_cred" 30 '{"someserver":{"accessToken":"keep-me"}}'
before_scratch="$(count_refresh_scratch_dirs)"
STUB_MODE=success fs_claude_refresh_if_needed "$due_cred" "$stub"
after_scratch="$(count_refresh_scratch_dirs)"
new_at="$(jq -r '.claudeAiOauth.accessToken' "$due_cred" 2>/dev/null)"
if [[ "$new_at" == stub-new-access-* ]]; then
    ok "a successful refresh replaces the access token"
else
    no "a successful refresh replaces the access token" "accessToken is '$new_at'"
fi
mcp_kept="$(jq -r '.mcpOAuth.someserver.accessToken // ""' "$due_cred" 2>/dev/null)"
if [[ "$mcp_kept" == "keep-me" ]]; then
    ok "a successful refresh preserves other top-level keys (mcpOAuth)"
else
    no "a successful refresh preserves other top-level keys (mcpOAuth)" "mcpOAuth.someserver.accessToken is '$mcp_kept'"
fi
mode="$(stat -c %a "$due_cred" 2>/dev/null)"
if [[ "$mode" == 600 ]]; then
    ok "the refreshed file is mode 600"
else
    no "the refreshed file is mode 600" "mode is $mode"
fi
if [[ ! -d "$work/.oauth_refresh.lock" && ! -d "$(realpath -m "$work").lock" ]]; then
    ok "both lock dirs are gone after a successful refresh"
else
    no "both lock dirs are gone after a successful refresh" "a lock dir is still present"
fi
if [[ "$after_scratch" == "$before_scratch" ]]; then
    ok "the refresh scratch dir is gone after a successful refresh"
else
    no "the refresh scratch dir is gone after a successful refresh" "count went from $before_scratch to $after_scratch"
fi

printf '\n== re-check under the lock: a concurrent refresh wins the race, so the stub is never called ==\n'
race_cred="$work/race-credentials.json"
write_cred "$race_cred" 20
race_dir="$(dirname "$race_cred")"
race_lock1="$race_dir/.oauth_refresh.lock"
: > "$work/race-call-log"
(
    mkdir "$race_lock1"
    sleep 1.5
    tmp="$(mktemp "$race_dir/race-credentials.json.XXXXXX")"
    jq --argjson exp "$(( ($(date +%s) + 9000) * 1000 ))" '.claudeAiOauth.expiresAt = $exp' "$race_cred" > "$tmp"
    mv "$tmp" "$race_cred"
    rmdir "$race_lock1"
) &
race_bg=$!
FS_CLAUDE_REFRESH_LOCK_BUDGET_SEC=10 STUB_CALL_LOG="$work/race-call-log" \
    fs_claude_refresh_if_needed "$race_cred" "$stub"
wait "$race_bg"
if [[ ! -s "$work/race-call-log" ]]; then
    ok "the stub is not called when another process refreshed while we waited for the lock"
else
    no "the stub is not called when another process refreshed while we waited for the lock" "$(cat "$work/race-call-log")"
fi

printf '\n== a live lock held past the wait budget: a warning, and the file is untouched ==\n'
held_cred="$work/held-credentials.json"
write_cred "$held_cred" 10
held_dir="$(dirname "$held_cred")"
mkdir "$held_dir/.oauth_refresh.lock"
before_bytes="$(cat "$held_cred")"
held_out="$(FS_CLAUDE_REFRESH_LOCK_BUDGET_SEC=2 fs_claude_refresh_if_needed "$held_cred" "$stub" 2>&1)"
after_bytes="$(cat "$held_cred")"
if [[ "$held_out" == *"could not acquire"* ]]; then
    ok "a live lock held past budget prints a warning"
else
    no "a live lock held past budget prints a warning" "$held_out"
fi
if [[ "$before_bytes" == "$after_bytes" ]]; then
    ok "a live lock held past budget leaves the file untouched"
else
    no "a live lock held past budget leaves the file untouched" "file content changed"
fi
rmdir "$held_dir/.oauth_refresh.lock" 2>/dev/null || true

printf '\n== a stale lock (mtime 60s+) is broken, and the refresh proceeds ==\n'
stale_cred="$work/stale-credentials.json"
write_cred "$stale_cred" 10
stale_dir="$(dirname "$stale_cred")"
mkdir "$stale_dir/.oauth_refresh.lock"
touch -d '61 seconds ago' "$stale_dir/.oauth_refresh.lock"
STUB_MODE=success fs_claude_refresh_if_needed "$stale_cred" "$stub"
stale_at="$(jq -r '.claudeAiOauth.accessToken' "$stale_cred" 2>/dev/null)"
if [[ "$stale_at" == stub-new-access-* ]]; then
    ok "a stale (61s+) lock is broken and the refresh proceeds"
else
    no "a stale (61s+) lock is broken and the refresh proceeds" "accessToken is '$stale_at'"
fi
if [[ ! -d "$stale_dir/.oauth_refresh.lock" ]]; then
    ok "the broken stale lock is gone afterwards"
else
    no "the broken stale lock is gone afterwards" "$stale_dir/.oauth_refresh.lock still exists"
fi

printf '\n== a failing second mktemp does not leak the scratch dir or lock dirs, and does not abort the caller ==\n'
# A PATH-shadowing wrapper, real mktemp underneath: delegates every call
# except the SECOND mktemp inside _fs_claude_do_refresh (the one staging the
# merged real file next to the credential -- fork-sandbox-lib.sh, the
# `mktemp "$dir/.credentials.json.XXXXXX"` line), which it fails outright.
# The first mktemp (the -d scratch dir) is unaffected, so this isolates
# exactly the reviewer's own repro: a successful stub refresh followed by
# that one mktemp failing.
real_mktemp="$(command -v mktemp)"
mktemp_fail_bin="$work/mktemp-fail-bin"
mkdir -p "$mktemp_fail_bin"
cat > "$mktemp_fail_bin/mktemp" <<WRAP
#!/usr/bin/env bash
case "\$*" in
    *.credentials.json.XXXXXX*) exit 1 ;;
    *) exec "$real_mktemp" "\$@" ;;
esac
WRAP
chmod +x "$mktemp_fail_bin/mktemp"
mktemp_fail_cred="$work/mktemp-fail-credentials.json"
write_cred "$mktemp_fail_cred" 10
before_mtime_fail="$(cat "$mktemp_fail_cred")"
before_scratch_count="$(count_refresh_scratch_dirs)"
mktemp_fail_dir="$(dirname "$mktemp_fail_cred")"
# Run under set -e in a subshell, matching how claude-sandboxed and the
# live-sync loop actually call this (a bare statement under `set -e`) -- the
# exact context the leak needed to happen in. Deliberately NOT `... || rc=$?`
# here: wrapping the substitution itself in a tested context would exempt
# everything run inside it from -e too (bash extends that exemption into
# subshells), masking exactly the failure mode this test exists to catch.
mktemp_fail_out="$(
    set -e
    PATH="$mktemp_fail_bin:$PATH" \
        STUB_MODE=success fs_claude_refresh_if_needed "$mktemp_fail_cred" "$stub"
)"
mktemp_fail_rc=$?
if [[ "$mktemp_fail_rc" == 0 ]]; then
    ok "a failing second mktemp does not abort the caller under set -e"
else
    no "a failing second mktemp does not abort the caller under set -e" "exit $mktemp_fail_rc: $mktemp_fail_out"
fi
after_mtime_fail="$(cat "$mktemp_fail_cred")"
if [[ "$before_mtime_fail" == "$after_mtime_fail" ]]; then
    ok "a failing second mktemp leaves the real file byte-identical"
else
    no "a failing second mktemp leaves the real file byte-identical" "before: $before_mtime_fail / after: $after_mtime_fail"
fi
if [[ ! -d "$mktemp_fail_dir/.oauth_refresh.lock" ]]; then
    ok "a failing second mktemp leaves no .oauth_refresh.lock behind"
else
    no "a failing second mktemp leaves no .oauth_refresh.lock behind" "lock still exists"
    rmdir "$mktemp_fail_dir/.oauth_refresh.lock" 2>/dev/null || true
fi
mktemp_fail_legacy_lock="$(cd "$mktemp_fail_dir" && pwd -P).lock"
if [[ ! -d "$mktemp_fail_legacy_lock" ]]; then
    ok "a failing second mktemp leaves no legacy <dir>.lock behind"
else
    no "a failing second mktemp leaves no legacy <dir>.lock behind" "lock still exists"
    rmdir "$mktemp_fail_legacy_lock" 2>/dev/null || true
fi
after_scratch_count="$(count_refresh_scratch_dirs)"
if [[ "$after_scratch_count" == "$before_scratch_count" ]]; then
    ok "a failing second mktemp leaves no refresh scratch dir behind"
else
    no "a failing second mktemp leaves no refresh scratch dir behind" "scratch dir count went from $before_scratch_count to $after_scratch_count"
fi

for mode in blank failexit; do
    printf '\n== a failed refresh (stub %s) leaves the real file byte-identical, and warns ==\n' "$mode"
    fail_cred="$work/fail-$mode-credentials.json"
    write_cred "$fail_cred" 10
    before="$(cat "$fail_cred")"
    fail_out="$(STUB_MODE="$mode" fs_claude_refresh_if_needed "$fail_cred" "$stub" 2>&1)"
    after="$(cat "$fail_cred")"
    if [[ "$before" == "$after" ]]; then
        ok "a failed refresh (stub $mode) leaves the file byte-identical"
    else
        no "a failed refresh (stub $mode) leaves the file byte-identical" "before: $before / after: $after"
    fi
    if [[ "$fail_out" == *"could not refresh"* ]]; then
        ok "a failed refresh (stub $mode) prints a warning"
    else
        no "a failed refresh (stub $mode) prints a warning" "$fail_out"
    fi
done

echo
echo '=== fork-sandbox-claude-token-probe ==='

probe="$repo_dir/scripts/fork-sandbox-claude-token-probe"

printf '\n== a fully compliant claude passes every check ==\n'
probe_out="$(PROBE_BREAK_CHECK='' "$probe" --claude "$stub" 2>&1)"
probe_rc=$?
if (( probe_rc == 0 )); then
    ok "the probe exits 0 against a fully compliant stub"
else
    no "the probe exits 0 against a fully compliant stub" "rc=$probe_rc: $probe_out"
fi
if [[ "$probe_out" != *FAIL* ]]; then
    ok "the probe reports no FAIL lines against a fully compliant stub"
else
    no "the probe reports no FAIL lines against a fully compliant stub" "$probe_out"
fi

declare -A BREAK_LABELS=(
    [startup_refresh]="refresh at startup"
    [lock_live]="refresh lock path, live"
    [stale_lock]="stale lock is broken"
    [handler_401]="401 handler takes the refresh-token branch"
)
for key in startup_refresh lock_live stale_lock handler_401; do
    printf '\n== a claude that violates "%s" fails exactly that check, and exits 1 ==\n' "$key"
    broken_out="$(PROBE_BREAK_CHECK="$key" "$probe" --claude "$stub" 2>&1)"
    broken_rc=$?
    if (( broken_rc == 1 )); then
        ok "violating '$key' makes the probe exit 1"
    else
        no "violating '$key' makes the probe exit 1" "rc=$broken_rc"
    fi
    if [[ "$broken_out" == *"FAIL  ${BREAK_LABELS[$key]}"* ]]; then
        ok "violating '$key' is reported by name"
    else
        no "violating '$key' is reported by name" "$broken_out"
    fi
done

printf '\n== a claude binary without the marker strings fails the (weaker) mtime re-read check ==\n'
nomarkers_out="$("$probe" --claude "$nomarkers_stub" 2>&1)"
nomarkers_rc=$?
if (( nomarkers_rc == 1 )); then
    ok "a claude without the marker strings makes the probe exit 1"
else
    no "a claude without the marker strings makes the probe exit 1" "rc=$nomarkers_rc"
fi
if [[ "$nomarkers_out" == *"FAIL  mtime re-read"* ]]; then
    ok "the mtime re-read check is reported by name"
else
    no "the mtime re-read check is reported by name" "$nomarkers_out"
fi

echo
echo '=== fs_claude_token_contract_check (marker caching around the probe) ==='

printf '\n== the probe runs once per claude version, not once per call ==\n'
contract_dir="$work/contract-cache"
call_log="$work/probe-wrapper-calls"
: > "$call_log"
wrapper="$work/probe-wrapper.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "called\\n" >> %q\n' "$call_log"
    printf 'exec %q "$@"\n' "$probe"
} > "$wrapper"
chmod +x "$wrapper"

FS_CLAUDE_TOKEN_CONTRACT_DIR="$contract_dir" PROBE_BREAK_CHECK='' fs_claude_token_contract_check "$stub" "$wrapper" 2>/dev/null
FS_CLAUDE_TOKEN_CONTRACT_DIR="$contract_dir" PROBE_BREAK_CHECK='' fs_claude_token_contract_check "$stub" "$wrapper" 2>/dev/null
calls="$(wc -l < "$call_log" | tr -d ' ')"
if [[ "$calls" == 1 ]]; then
    ok "the probe runs exactly once across two calls for the same claude version"
else
    no "the probe runs exactly once across two calls for the same claude version" "expected 1 call, got $calls"
fi
if compgen -G "$contract_dir/*.ok" >/dev/null; then
    ok "a passing probe leaves an .ok marker"
else
    no "a passing probe leaves an .ok marker" "no .ok marker under $contract_dir"
fi

printf '\n== a held probe lock is not waited on: no probe run, a "pending" note ==\n'
contract_dir2="$work/contract-cache-2"
mkdir -p "$contract_dir2"
stub_version="$("$stub" --version)"
mkdir -p "$contract_dir2/.probe-$stub_version.lock"
: > "$call_log"
pending_out="$(FS_CLAUDE_TOKEN_CONTRACT_DIR="$contract_dir2" fs_claude_token_contract_check "$stub" "$wrapper" 2>&1)"
if [[ "$pending_out" == *pending* ]]; then
    ok "a held probe lock produces a 'pending' note instead of waiting"
else
    no "a held probe lock produces a 'pending' note instead of waiting" "$pending_out"
fi
if [[ ! -s "$call_log" ]]; then
    ok "a held probe lock means the probe itself is not run"
else
    no "a held probe lock means the probe itself is not run" "$(cat "$call_log")"
fi
if [[ ! -e "$contract_dir2/$stub_version.ok" && ! -e "$contract_dir2/$stub_version.fail" ]]; then
    ok "a held probe lock leaves no verdict marker behind"
else
    no "a held probe lock leaves no verdict marker behind" "a marker exists under $contract_dir2"
fi
rmdir "$contract_dir2/.probe-$stub_version.lock" 2>/dev/null || true

printf '\n== a failing probe warns loudly, on the first call and every cached call after ==\n'
contract_dir3="$work/contract-cache-3"
out1="$(PROBE_BREAK_CHECK=startup_refresh FS_CLAUDE_TOKEN_CONTRACT_DIR="$contract_dir3" \
    fs_claude_token_contract_check "$stub" "$wrapper" 2>&1)"
out2="$(PROBE_BREAK_CHECK=startup_refresh FS_CLAUDE_TOKEN_CONTRACT_DIR="$contract_dir3" \
    fs_claude_token_contract_check "$stub" "$wrapper" 2>&1)"
if [[ "$out1" == *WARNING* && "$out1" == *"refresh at startup"* ]]; then
    ok "a failing probe prints a loud warning naming the failed check (fresh run)"
else
    no "a failing probe prints a loud warning naming the failed check (fresh run)" "$out1"
fi
if [[ "$out2" == *WARNING* && "$out2" == *"refresh at startup"* ]]; then
    ok "the loud warning still prints on a later, cache-hit call"
else
    no "the loud warning still prints on a later, cache-hit call" "$out2"
fi
if compgen -G "$contract_dir3/*.fail" >/dev/null; then
    ok "a failing probe leaves a .fail marker"
else
    no "a failing probe leaves a .fail marker" "no .fail marker under $contract_dir3"
fi

echo
echo '=== claude-sandboxed live-sync loop (end to end, offline) ==='

printf '\n== the sandbox credential copy follows a host refresh, and repairs a blanked copy ==\n'
sync_work="$work/sync"; mkdir -p "$sync_work/bin"
sync_bin="$sync_work/bin"

cat > "$sync_bin/sandbox-backend-test" <<'BACKEND'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    printf 'toolchain=host\n'
    exit 0
fi
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == --bind-rw-at ]]; then
        j=$((i + 1)); k=$((i + 2))
        s="${!j}"; d="${!k}"
        if [[ "$d" == */.claude && -n "${SYNC_WATCH_DIR:-}" ]]; then
            printf '%s' "$s" > "$SYNC_WATCH_DIR/src-path"
        fi
    fi
done
sleep "${SYNC_SLEEP_SECS:-16}"
exit 0
BACKEND
chmod +x "$sync_bin/sandbox-backend-test"

cat > "$sync_bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && printf 'sync-loop-test-stub\n'
exit 0
CLAUDE
chmod +x "$sync_bin/claude"

sync_home="$sync_work/home"; mkdir -p "$sync_home"
sync_cred="$sync_work/host-credentials.json"
write_cred "$sync_cred" 240
sync_watch="$sync_work/watch"; mkdir -p "$sync_watch"
sync_wd="$sync_work/wd"; mkdir -p "$sync_wd"

(
    PATH="$sync_bin:$PATH" FORK_SANDBOX_BACKEND=test HOME="$sync_home" \
    FS_CLAUDE_TOKEN_CONTRACT_DIR="$sync_work/contract" \
    SYNC_WATCH_DIR="$sync_watch" SYNC_SLEEP_SECS=16 \
    "$repo_dir/scripts/claude-sandboxed" --claude-credentials "$sync_cred" "$sync_wd" --print hello \
        > "$sync_work/run.out" 2>&1
    echo "$?" > "$sync_work/run.rc"
) &
sync_pid=$!

# A bounded poll, not a fixed sleep -- setup time (including the one-time
# OAuth-refresh contract probe against the stub above) varies.
waited=0
while [[ ! -f "$sync_watch/src-path" && $waited -lt 40 ]]; do
    sleep 0.25
    waited=$(( waited + 1 ))
done
if [[ -f "$sync_watch/src-path" ]]; then
    ok "claude-sandboxed reaches the backend (the sync loop's own credential path is known)"
else
    no "claude-sandboxed reaches the backend (the sync loop's own credential path is known)" \
        "timed out waiting for $sync_watch/src-path; run.out: $(cat "$sync_work/run.out" 2>/dev/null)"
fi
src_path="$(cat "$sync_watch/src-path" 2>/dev/null || true)"

if [[ -n "$src_path" ]]; then
    sleep 1
    tmp="$(mktemp "$sync_work/host-credentials.json.XXXXXX")"
    jq --arg at "sync-new-access-token" --argjson exp "$(( ($(date +%s) + 25200) * 1000 ))" \
        '.claudeAiOauth.accessToken = $at | .claudeAiOauth.expiresAt = $exp' "$sync_cred" > "$tmp"
    mv "$tmp" "$sync_cred"

    followed=0
    for _ in 1 2 3 4 5 6; do
        if grep -qsF '"sync-new-access-token"' "$src_path/.credentials.json" 2>/dev/null; then
            followed=1
            break
        fi
        sleep 1
    done
    if (( followed )); then
        ok "the sandbox's credential copy follows a host refresh within a few seconds"
    else
        no "the sandbox's credential copy follows a host refresh within a few seconds" \
            "$(cat "$src_path/.credentials.json" 2>/dev/null)"
    fi

    jq '.claudeAiOauth.accessToken = "" | .claudeAiOauth.refreshToken = ""' "$src_path/.credentials.json" \
        > "$src_path/.credentials.json.tmp" 2>/dev/null \
        && mv "$src_path/.credentials.json.tmp" "$src_path/.credentials.json"

    repaired=0
    for _ in 1 2 3 4 5 6; do
        if grep -qsF '"sync-new-access-token"' "$src_path/.credentials.json" 2>/dev/null; then
            repaired=1
            break
        fi
        sleep 1
    done
    if (( repaired )); then
        ok "a blanked sandbox credential copy is repaired from the host's copy"
    else
        no "a blanked sandbox credential copy is repaired from the host's copy" \
            "$(cat "$src_path/.credentials.json" 2>/dev/null)"
    fi
fi

wait "$sync_pid"
run_rc="$(cat "$sync_work/run.rc" 2>/dev/null || echo unknown)"
if [[ "$run_rc" == 0 ]]; then
    ok "the claude-sandboxed run under test exits 0"
else
    no "the claude-sandboxed run under test exits 0" "rc=$run_rc: $(cat "$sync_work/run.out" 2>/dev/null)"
fi
if [[ -n "$src_path" && ! -d "$(dirname "$src_path")" ]]; then
    ok "the per-run state dir, and with it the sync loop, is gone once claude-sandboxed exits"
else
    no "the per-run state dir, and with it the sync loop, is gone once claude-sandboxed exits" \
        "$(dirname "${src_path:-unknown}") still exists"
fi

printf '\n== a foreign lock held by someone else survives the loop'"'"'s own exit ==\n'
# Regression test: the live-sync loop's EXIT trap
# (_fs_claude_refresh_emergency_cleanup) used to rmdir both shared claude
# lock dirs unconditionally on every exit, even when this run never took
# them -- breaking claude's refresh mutual exclusion for the whole host the
# instant any step ended. Reproduce exactly that: pre-create both lock dirs
# as if another process (the host's interactive claude, or another step's
# own loop) holds them, then run claude-sandboxed against a credential far
# from expiry (so fs_claude_refresh_if_needed's own tick never takes them
# either) and let it exit normally. Both foreign locks must still be there
# afterwards.
foreign_work="$work/foreign-lock"; mkdir -p "$foreign_work/bin"
foreign_bin="$foreign_work/bin"
cp "$sync_bin/sandbox-backend-test" "$foreign_bin/sandbox-backend-test"
cp "$sync_bin/claude" "$foreign_bin/claude"

foreign_home="$foreign_work/home"; mkdir -p "$foreign_home"
foreign_cred="$foreign_work/host-credentials.json"
write_cred "$foreign_cred" 240
foreign_wd="$foreign_work/wd"; mkdir -p "$foreign_wd"

foreign_dir="$foreign_work"
foreign_lock1="$foreign_dir/.oauth_refresh.lock"
foreign_lock2="$("$FS_REALPATH" -m "$foreign_dir").lock"
mkdir "$foreign_lock1" "$foreign_lock2"

PATH="$foreign_bin:$PATH" FORK_SANDBOX_BACKEND=test HOME="$foreign_home" \
    FS_CLAUDE_TOKEN_CONTRACT_DIR="$foreign_work/contract" \
    SYNC_SLEEP_SECS=3 \
    "$repo_dir/scripts/claude-sandboxed" --claude-credentials "$foreign_cred" "$foreign_wd" --print hello \
        > "$foreign_work/run.out" 2>&1
foreign_rc=$?

if [[ "$foreign_rc" == 0 ]]; then
    ok "the run under test (with pre-existing foreign locks) exits 0"
else
    no "the run under test (with pre-existing foreign locks) exits 0" \
        "rc=$foreign_rc: $(cat "$foreign_work/run.out" 2>/dev/null)"
fi
if [[ -d "$foreign_lock1" ]]; then
    ok "a foreign .oauth_refresh.lock this run never took survives its exit"
else
    no "a foreign .oauth_refresh.lock this run never took survives its exit" \
        "$foreign_lock1 was removed"
fi
if [[ -d "$foreign_lock2" ]]; then
    ok "a foreign legacy <dir>.lock this run never took survives its exit"
else
    no "a foreign legacy <dir>.lock this run never took survives its exit" \
        "$foreign_lock2 was removed"
fi
rmdir "$foreign_lock1" "$foreign_lock2" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
