#!/usr/bin/env bash
# fork-sandbox-configure-test.sh — `fork-sandbox.sh configure` holds its own contract
#
# Usage: tests/fork-sandbox-configure-test.sh
#
# Runs entirely offline: no network, no real credential, no live cluster.
# Every discoverer under test is either a fixture built in a temp dir on
# PATH, or one of the four real discoverers run against a deliberately
# empty environment (no OPENROUTER_API_KEY, no ~/.claude, no kubectl
# config) so it has nothing real to find. FORK_SANDBOX_CONFIG_DIR always
# points at a temp dir, never ~/.config/fork-sandbox.
#
# It covers:
#   - a fixture discoverer's candidates are installed by `configure --all`
#     into the right file and key.
#   - a discoverer naming a target outside the allowlist is refused by
#     name and dropped, for both an unknown key and a path-traversal
#     attempt, and nothing is written for either.
#   - a value containing an embedded newline is refused, and no second
#     line is injected into the env file.
#   - an empty value is refused.
#   - a secret target's file is created mode 0600, and a pre-existing 0644
#     file is tightened to 0600 with the tightening reported.
#   - merge semantics: an unrelated key and a comment both survive a
#     write, and an existing value for the same key is replaced once, not
#     duplicated.
#   - no secret ever reaches stdout or stderr, including under --dry-run.
#   - `value` is called only for a selected id, proven by a fixture that
#     records its own invocations and an unselected (informational)
#     candidate that must never be read.
#   - `--remove --all` removes the keys currently set and leaves the rest
#     of the file, including a comment, intact.
#   - configure run non-interactively (no tty) without --all exits
#     non-zero with the explanatory error.
#   - `--dry-run` writes nothing.
#   - a discoverer that exits non-zero produces a warning and does not
#     abort the run; a good discoverer's candidate is still installed.
#   - each of the four real discoverers (openrouter, model, claude, k8s)
#     runs `discover` and exits 0 against a clean environment.
#   - shellcheck on fork-sandbox.sh and the four discoverer scripts.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry, and a directory
# there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
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

fs_sh="$repo_dir/scripts/fork-sandbox.sh"
lib_sh="$repo_dir/scripts/fork-sandbox-lib.sh"
discover_openrouter="$repo_dir/scripts/fork-sandbox-discover-openrouter"
discover_model="$repo_dir/scripts/fork-sandbox-discover-model"
discover_claude="$repo_dir/scripts/fork-sandbox-discover-claude"
discover_k8s="$repo_dir/scripts/fork-sandbox-discover-k8s"

# Sourced directly, not a subshell, so ok()/no() reach the pass/fail
# counters this file reports at the end -- the same reasoning
# fork-sandbox-k8s-test.sh gives for sourcing its own lib copy up here.
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib_sh"

# Runs `fork-sandbox.sh configure` with $1 as PATH's front, $2 as
# FORK_SANDBOX_CONFIG_DIR, and the rest as configure's own arguments.
# Stdin is /dev/null, so a bug that reaches the interactive picker fails
# fast on a closed pipe instead of hanging the test suite.
run_configure() {
    local bindir="$1" configdir="$2"
    shift 2
    PATH="$bindir:$PATH" FORK_SANDBOX_CONFIG_DIR="$configdir" "$fs_sh" configure "$@" < /dev/null 2>&1
}

printf '== shellcheck ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP  shellcheck not installed\n'
else
    for f in "$fs_sh" "$discover_openrouter" "$discover_model" "$discover_claude" "$discover_k8s"; do
        out="$(shellcheck -x "$f" 2>&1)"
        if [[ -z "$out" ]]; then ok "shellcheck: $(basename "$f")"; else no "shellcheck: $(basename "$f")" "$out"; fi
    done
fi

printf '\n== configure --all installs a fixture candidate ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-t1" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'ep\tmodel.env:MODEL_ENDPOINT\tFixture endpoint\tfixture\thttp://example.com:9000/v1\n' ;;
    value) [[ "$2" == ep ]] && printf 'http://example.com:9000/v1' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-t1"
out="$(run_configure "$bindir" "$configdir" --all)"
val="$(fs_read_env_value "$configdir/model.env" MODEL_ENDPOINT || true)"
check "candidate installed into model.env:MODEL_ENDPOINT" "http://example.com:9000/v1" "$val"

printf '\n== a target outside the allowlist is refused and dropped ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-evil" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover)
        printf 'a\tevil.env:X\tEvil\tfixture\tval\n'
        printf 'b\t../../../tmp/fork-sandbox-configure-test-pwned:X\tEvil2\tfixture\tval\n'
        ;;
    value) printf 'SENTINEL-SHOULD-NOT-BE-WRITTEN' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-evil"
out="$(run_configure "$bindir" "$configdir" --all)"
if [[ "$out" == *"not one of the targets"* && "$out" == *"evil.env:X"* \
    && "$out" == *"../../../tmp/fork-sandbox-configure-test-pwned:X"* \
    && ! -e "$configdir/evil.env" && ! -e /tmp/fork-sandbox-configure-test-pwned ]]; then
    ok "unknown key and traversal target are both refused by name and dropped"
else
    no "unknown key and traversal target are both refused by name and dropped" "$out"
fi

printf '\n== a value with an embedded newline is refused ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-nl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'x\tmodel.env:MODEL_ID\tFixture\tfixture\tbad\n' ;;
    value) printf 'line-one\nK8S_CONTEXT=injected' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-nl"
out="$(run_configure "$bindir" "$configdir" --all)"
if [[ ! -f "$configdir/model.env" ]]; then
    ok "newline-bearing value refused (no file written)"
elif ! grep -q '^MODEL_ID=' "$configdir/model.env" && ! grep -q 'K8S_CONTEXT=injected' "$configdir/model.env"; then
    ok "newline-bearing value refused (no injected line)"
else
    no "newline-bearing value refused" "$(cat -- "$configdir/model.env" 2>/dev/null)"
fi

printf '\n== an empty value is refused ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-empty" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'x\tmodel.env:MODEL_ID\tFixture\tfixture\t(empty)\n' ;;
    value) printf '' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-empty"
out="$(run_configure "$bindir" "$configdir" --all)"
val="$(fs_read_env_value "$configdir/model.env" MODEL_ID || true)"
check "empty value is refused, nothing written for the key" "" "$val"

printf '\n== a secret target file is created 0600, an existing looser one is tightened ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
printf 'OPENROUTER_API_KEY=old-fixture-key\n' > "$configdir/pi.env"
chmod 0644 "$configdir/pi.env"
cat > "$bindir/fork-sandbox-discover-secret" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'k\tpi.env:OPENROUTER_API_KEY\tFixture key\tfixture\t...cret\n' ;;
    value) printf 'sk-fixture-new-secret' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-secret"
out="$(run_configure "$bindir" "$configdir" --all)"
mode="$(stat -c '%a' -- "$configdir/pi.env")"
check "pi.env ends up mode 0600" "600" "$mode"
if [[ "$out" == *"tightening"*"0600"* ]]; then
    ok "the tightening from 0644 is reported"
else
    no "the tightening from 0644 is reported" "$out"
fi

printf '\n== merge: unrelated key and comment survive; existing value is replaced, not duplicated ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$configdir/model.env" <<'CONF'
# a hand-written comment
MODEL_ID=keep-me
MODEL_ENDPOINT=http://old.example.com:1/v1
CONF
cat > "$bindir/fork-sandbox-discover-merge" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'e\tmodel.env:MODEL_ENDPOINT\tFixture\tfixture\thttp://new.example.com:2/v1\n' ;;
    value) printf 'http://new.example.com:2/v1' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-merge"
out="$(run_configure "$bindir" "$configdir" --all)"
content="$(cat -- "$configdir/model.env")"
endpoint_lines="$(grep -c '^MODEL_ENDPOINT=' "$configdir/model.env")"
if [[ "$content" == *"# a hand-written comment"* && "$content" == *"MODEL_ID=keep-me"* \
    && "$content" == *"MODEL_ENDPOINT=http://new.example.com:2/v1"* && "$endpoint_lines" == 1 ]]; then
    ok "comment and unrelated key survive; MODEL_ENDPOINT replaced once, not duplicated"
else
    no "comment and unrelated key survive; MODEL_ENDPOINT replaced once, not duplicated" "$content"
fi

printf '\n== no secret ever reaches stdout or stderr, including under --dry-run ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
cat > "$bindir/fork-sandbox-discover-leaktest" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'k\tpi.env:OPENROUTER_API_KEY\tFixture key\tfixture\t...NEL\n' ;;
    value) printf 'SENTINEL-LEAK-CHECK-9f3a' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-leaktest"
configdir="$(newdir)"; tmpdirs+=("$configdir")
out_write="$(run_configure "$bindir" "$configdir" --all)"
configdir2="$(newdir)"; tmpdirs+=("$configdir2")
out_dry="$(run_configure "$bindir" "$configdir2" --all --dry-run)"
if [[ "$out_write" != *"SENTINEL-LEAK-CHECK-9f3a"* && "$out_dry" != *"SENTINEL-LEAK-CHECK-9f3a"* ]]; then
    ok "the fixture secret never appears in configure's own output"
else
    no "the fixture secret never appears in configure's own output" "write: $out_write | dry-run: $out_dry"
fi

printf '\n== value is fetched only for a selected candidate ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
invoke_log="$(newdir)/invocations"; tmpdirs+=("$(dirname "$invoke_log")")
cat > "$bindir/fork-sandbox-discover-sel" <<FIXTURE
#!/usr/bin/env bash
set -euo pipefail
case "\${1-}" in
    discover)
        printf 'sel\tmodel.env:MODEL_ID\tSelectable\tfixture\tval\n'
        printf 'info\t-\tInformational\tfixture\tval\n'
        ;;
    value)
        echo "\$2" >> "$invoke_log"
        case "\$2" in
            sel) printf 'selected-value' ;;
            info) printf 'SHOULD-NEVER-BE-READ' ;;
        esac
        ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-sel"
out="$(run_configure "$bindir" "$configdir" --all)"
invoked="$(cat -- "$invoke_log" 2>/dev/null || true)"
if [[ "$invoked" == *sel* && "$invoked" != *info* ]]; then
    ok "value is called for the selected id and never for the informational one"
else
    no "value is called for the selected id and never for the informational one" "invocations: $invoked"
fi

printf '\n== --remove --all removes what is set, leaves the rest of the file intact ==\n'
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$configdir/k8s.env" <<'CONF'
K8S_CONTEXT=fixture-context
# a note about this cluster
K8S_NAMESPACE=fixture-ns
CONF
out="$(FORK_SANDBOX_CONFIG_DIR="$configdir" "$fs_sh" configure --remove --all < /dev/null 2>&1)"
content="$(cat -- "$configdir/k8s.env")"
if [[ "$content" == *"# a note about this cluster"* \
    && "$content" != *"K8S_CONTEXT="* && "$content" != *"K8S_NAMESPACE="* ]]; then
    ok "--remove --all removes the set keys and leaves the comment"
else
    no "--remove --all removes the set keys and leaves the comment" "$content"
fi

printf '\n== non-interactive configure without --all is refused ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-t10" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'x\tmodel.env:MODEL_ID\tFixture\tfixture\tval\n' ;;
    value) printf 'val' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-t10"
out="$(run_configure "$bindir" "$configdir")"
rc=$?
if (( rc != 0 )) && [[ "$out" == *"interactive"* ]]; then
    ok "configure without --all and without a tty exits non-zero with an explanation"
else
    no "configure without --all and without a tty exits non-zero with an explanation" "status $rc: $out"
fi

printf '\n== --dry-run writes nothing ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-dry" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'e\tmodel.env:MODEL_ENDPOINT\tFixture\tfixture\thttp://example.com:1/v1\n' ;;
    value) printf 'http://example.com:1/v1' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-dry"
out="$(run_configure "$bindir" "$configdir" --all --dry-run)"
if [[ ! -f "$configdir/model.env" ]]; then
    ok "--dry-run writes no file"
else
    no "--dry-run writes no file" "$(cat -- "$configdir/model.env")"
fi

printf '\n== a discoverer exiting non-zero warns and does not abort the run ==\n'
bindir="$(newdir)"; tmpdirs+=("$bindir")
configdir="$(newdir)"; tmpdirs+=("$configdir")
cat > "$bindir/fork-sandbox-discover-bad" <<'FIXTURE'
#!/usr/bin/env bash
exit 3
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-bad"
cat > "$bindir/fork-sandbox-discover-good" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
    discover) printf 'e\tmodel.env:MODEL_ENDPOINT\tFixture\tfixture\thttp://good.example.com:1/v1\n' ;;
    value) printf 'http://good.example.com:1/v1' ;;
esac
FIXTURE
chmod +x "$bindir/fork-sandbox-discover-good"
out="$(run_configure "$bindir" "$configdir" --all)"
val="$(fs_read_env_value "$configdir/model.env" MODEL_ENDPOINT || true)"
if [[ "$out" == *"fork-sandbox-discover-bad"* && "$out" == *"exited 3"* && "$val" == "http://good.example.com:1/v1" ]]; then
    ok "a non-zero discoverer is warned about and the run continues"
else
    no "a non-zero discoverer is warned about and the run continues" "$out / MODEL_ENDPOINT=$val"
fi

printf '\n== the four real discoverers run against a clean environment ==\n'
clean_home="$(newdir)"; tmpdirs+=("$clean_home")
for d in "$discover_openrouter" "$discover_model" "$discover_claude" "$discover_k8s"; do
    if env -i PATH="/usr/bin:/bin" HOME="$clean_home" "$d" discover >/dev/null 2>&1; then
        ok "$(basename "$d") discover exits 0 in a clean environment"
    else
        no "$(basename "$d") discover exits 0 in a clean environment" "exit $?"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
