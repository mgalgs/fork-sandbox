#!/usr/bin/env bash
# claude-sandboxed-credentials-test.sh -- --claude-credentials on claude-sandboxed
#
# Usage: tests/claude-sandboxed-credentials-test.sh
#
# Covers the client end of the CLAUDE_CREDENTIALS override (fork-sandbox.sh
# and fork-sandbox-k8s.sh are covered by their own suites):
#   - --claude-credentials and --exec contradict each other (an --exec
#     sandbox reads no Claude credential of any kind) and are refused.
#   - a missing --claude-credentials path fails naming that path.
#   - the sandbox's own credential copy is read from the override file, not
#     $HOME/.claude/.credentials.json, and is still stripped of mcpOAuth and
#     the refresh token/expiry the same way the default path is -- the
#     brief's non-negotiable: an override must not route around the
#     stripping that keeps a sandbox refresh from invalidating the host's
#     token.
#
# Runs entirely offline against a stub sandbox-backend-test (FORK_SANDBOX_
# BACKEND=test), as tests/agent-sandboxed-ctx-test.sh does: no bubblewrap,
# no real claude session. The stub captures $STATE_DIR/claude/.credentials.json
# -- the file claude-sandboxed writes on the host BEFORE invoking any
# backend -- from the --bind-rw-at argument that remaps it to $HOME/.claude,
# since claude-sandboxed's own EXIT trap deletes STATE_DIR the moment the
# backend returns.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
client="$repo_dir/scripts/claude-sandboxed"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }
refuses() {
    local label="$1" needle="$2" out rc; shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$needle"* ]]; then ok "$label"; else no "$label" "status $rc: $out"; fi
}

work="$(mktemp -d)"; tmpdirs+=("$work")
bin="$work/bin"; mkdir "$bin"
cat > "$bin/sandbox-backend-test" <<'BACKEND'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    printf 'toolchain=host\n'
    exit 0
fi
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == --bind-rw-at ]]; then
        j=$((i + 1)); k=$((i + 2))
        src="${!j}"; dest="${!k}"
        if [[ "$dest" == */.claude && -n "${CREDS_CAPTURE:-}" ]]; then
            cp -- "$src/.credentials.json" "$CREDS_CAPTURE" 2>/dev/null || true
        fi
    fi
done
exit 0
BACKEND
chmod +x "$bin/sandbox-backend-test"

test_home="$work/home"; mkdir -p "$test_home"
future_ms=$(( ($(date +%s) + 7200) * 1000 ))

printf '\n== --claude-credentials and --exec ==\n'
work_dir="$work/exec-wd"; mkdir -p "$work_dir"
refuses "--claude-credentials with --exec is refused" \
    "--claude-credentials works only without --exec" \
    env PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test HOME="$test_home" \
    "$client" --claude-credentials "$work/whatever.json" --exec "$work_dir" true

printf '\n== a missing --claude-credentials path ==\n'
missing_cred="$test_home/does-not-exist-credentials.json"
work_dir2="$work/missing-wd"; mkdir -p "$work_dir2"
refuses "a missing --claude-credentials path fails naming that path" \
    "$missing_cred" \
    env PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test HOME="$test_home" \
    "$client" --claude-credentials "$missing_cred" "$work_dir2" --print hello

printf '\n== --claude-credentials is read instead of the default, and still stripped ==\n'
override_cred="$work/override-credentials.json"
override_token="fixture-sandboxed-override-token-do-not-leak"
cat > "$override_cred" <<JSON
{"claudeAiOauth": {"accessToken": "$override_token", "refreshToken": "fixture-refresh-should-be-stripped", "refreshTokenExpiresAt": 999, "expiresAt": $future_ms, "scopes": ["user:inference"]}, "mcpOAuth": {"someserver": {"accessToken": "fixture-mcp-should-be-stripped"}}}
JSON
work_dir3="$work/strip-wd"; mkdir -p "$work_dir3"
creds_capture="$work/captured-credentials.json"
if PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test HOME="$test_home" \
    CREDS_CAPTURE="$creds_capture" \
    "$client" --claude-credentials "$override_cred" "$work_dir3" --print hello \
    >/tmp/claude-sandboxed-cred-test.out 2>&1; then
    ok "a --claude-credentials run against the stub backend exits 0"
else
    no "a --claude-credentials run against the stub backend exits 0" \
        "$(cat /tmp/claude-sandboxed-cred-test.out)"
fi
if [[ -s "$creds_capture" ]]; then
    ok "the stub backend captured the sandbox's own credentials.json"
else
    no "the stub backend captured the sandbox's own credentials.json" \
        "$(cat /tmp/claude-sandboxed-cred-test.out)"
fi
if [[ -s "$creds_capture" ]] && grep -qF "\"$override_token\"" "$creds_capture"; then
    ok "the sandbox's credentials.json carries the override's access token"
else
    no "the sandbox's credentials.json carries the override's access token" \
        "$(cat "$creds_capture" 2>/dev/null)"
fi
if [[ -s "$creds_capture" ]] && grep -q 'refreshToken' "$creds_capture"; then
    no "the sandbox's credentials.json carries no refreshToken (override still stripped)" \
        "found 'refreshToken' in $(cat "$creds_capture")"
else
    ok "the sandbox's credentials.json carries no refreshToken (override still stripped)"
fi
if [[ -s "$creds_capture" ]] && grep -q 'mcpOAuth' "$creds_capture"; then
    no "the sandbox's credentials.json carries no mcpOAuth (override still stripped)" \
        "found 'mcpOAuth' in $(cat "$creds_capture")"
else
    ok "the sandbox's credentials.json carries no mcpOAuth (override still stripped)"
fi
rm -f /tmp/claude-sandboxed-cred-test.out

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
