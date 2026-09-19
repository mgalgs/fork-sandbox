#!/usr/bin/env bash
# fork-sandbox-browser-detect-test.sh — Exercise G1: in-sandbox browser detection
#
# Usage: tests/fork-sandbox-browser-detect-test.sh
#
# Covers docs/visual-browser.md's G1 guarantee: fs_detect_browser records
# whether a usable browser exists for a run, without inventing one that is
# not actually reachable at run time.
#
#   - the FORK_SANDBOX_BROWSER kill switch (0/none forces absence, unset/auto
#     detects)
#   - image toolchain forces both signals empty, regardless of what is on
#     the (test) host
#   - Playwright cache detection via a fake $HOME, mirroring fs_cache_binds'
#     own condition exactly
#   - the /usr/-prefix rule for a system chromium, via the internal
#     candidate-list and prefix variables rather than a real chromium
#   - fs_backend_capabilities' chromium_own_sandbox parsing and its
#     toolchain-based default when the key is absent
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

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

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

fake_backend() {
    local name="$1" body="$2"
    local path="$scratch/sandbox-backend-$name"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$body"; } > "$path"
    chmod 755 "$path"
    printf '%s\n' "$path"
}

scratch="$(mktemp -d)"
tmpdirs+=("$scratch")

# A fake "/usr" tree with a fake chromium in it, so detection can be
# exercised without a real browser on the test host.
fake_usr="$scratch/usr"
mkdir -p "$fake_usr/bin"
cat > "$fake_usr/bin/chromium" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod 755 "$fake_usr/bin/chromium"

fake_home="$scratch/home"
mkdir -p "$fake_home"

real_home="$HOME"
real_path="$PATH"
real_prefix="$FS_BROWSER_USR_PREFIX"
real_candidates=("${FS_BROWSER_CHROMIUM_CANDIDATES[@]}")

restore_env() {
    HOME="$real_home"
    PATH="$real_path"
    FS_BROWSER_USR_PREFIX="$real_prefix"
    FS_BROWSER_CHROMIUM_CANDIDATES=("${real_candidates[@]}")
    unset FORK_SANDBOX_BROWSER
}

echo "== fs_detect_browser =="

# The candidate list and prefix are internal variables precisely so this
# suite never needs a real chromium under a real /usr.
FS_BROWSER_CHROMIUM_CANDIDATES=(chromium)
FS_BROWSER_USR_PREFIX="$fake_usr/"
PATH="$fake_usr/bin:$PATH"
HOME="$fake_home"

FS_BACKEND_TOOLCHAIN=host
unset FORK_SANDBOX_BROWSER
fs_detect_browser
check "host toolchain, no playwright cache: chromium found" \
    "$fake_usr/bin/chromium" "$FS_BROWSER_CHROMIUM"
check "host toolchain, no playwright cache: playwright absent" \
    "" "$FS_BROWSER_PLAYWRIGHT"

mkdir -p "$fake_home/.cache/ms-playwright"
fs_detect_browser
check "playwright cache present is detected" \
    "$fake_home/.cache/ms-playwright" "$FS_BROWSER_PLAYWRIGHT"
check "chromium is still reported alongside playwright (announce both)" \
    "$fake_usr/bin/chromium" "$FS_BROWSER_CHROMIUM"

# A resolvable binary outside the trusted prefix is not there at run time,
# so it must not be trusted just because `command -v` finds it on the host
# doing the detecting -- even when a later candidate name resolves inside
# the trusted prefix.
outside="$scratch/outside/bin"
mkdir -p "$outside"
cat > "$outside/chromium" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod 755 "$outside/chromium"
cat > "$fake_usr/bin/chromium-browser" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod 755 "$fake_usr/bin/chromium-browser"
FS_BROWSER_CHROMIUM_CANDIDATES=(chromium chromium-browser)
PATH="$outside:$fake_usr/bin:$real_path"
fs_detect_browser
check "an untrusted match on one candidate name falls through to the next" \
    "$fake_usr/bin/chromium-browser" "$FS_BROWSER_CHROMIUM"

PATH="$outside:$real_path"
fs_detect_browser
check "an untrusted match with no trusted candidate anywhere is not trusted" \
    "" "$FS_BROWSER_CHROMIUM"
FS_BROWSER_CHROMIUM_CANDIDATES=(chromium)
PATH="$fake_usr/bin:$real_path"

FORK_SANDBOX_BROWSER=0
fs_detect_browser
check "FORK_SANDBOX_BROWSER=0 forces chromium absent" "" "$FS_BROWSER_CHROMIUM"
check "FORK_SANDBOX_BROWSER=0 forces playwright absent" "" "$FS_BROWSER_PLAYWRIGHT"

FORK_SANDBOX_BROWSER=none
fs_detect_browser
check "FORK_SANDBOX_BROWSER=none forces chromium absent" "" "$FS_BROWSER_CHROMIUM"
check "FORK_SANDBOX_BROWSER=none forces playwright absent" "" "$FS_BROWSER_PLAYWRIGHT"

FORK_SANDBOX_BROWSER=auto
fs_detect_browser
check "FORK_SANDBOX_BROWSER=auto detects normally" \
    "$fake_usr/bin/chromium" "$FS_BROWSER_CHROMIUM"
unset FORK_SANDBOX_BROWSER

FS_BACKEND_TOOLCHAIN=image
fs_detect_browser
check "image toolchain forces chromium absent" "" "$FS_BROWSER_CHROMIUM"
check "image toolchain forces playwright absent, cache dir notwithstanding" \
    "" "$FS_BROWSER_PLAYWRIGHT"

restore_env

echo ""
echo "== fs_backend_capabilities: chromium_own_sandbox =="

bin="$(fake_backend host-decl 'echo toolchain=host; echo chromium_own_sandbox=1')"
fs_backend_capabilities "$bin"
check "an explicit 1 is read" "1" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"

bin="$(fake_backend image-decl 'echo toolchain=image; echo chromium_own_sandbox=0')"
fs_backend_capabilities "$bin"
check "an explicit 0 is read" "0" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"

bin="$(fake_backend host-no-key 'echo toolchain=host')"
fs_backend_capabilities "$bin"
check "absent key defaults to 1 under host toolchain" \
    "1" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"

bin="$(fake_backend image-no-key 'echo toolchain=image')"
fs_backend_capabilities "$bin"
check "absent key defaults to 0 under image toolchain" \
    "0" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"

bin="$(fake_backend legacy 'echo "Error: unknown option" >&2; exit 1')"
fs_backend_capabilities "$bin"
check "a backend that refuses --capabilities entirely defaults to 1 (host)" \
    "1" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"

bin="$(fake_backend nonsense 'echo toolchain=host; echo chromium_own_sandbox=maybe')"
fs_backend_capabilities "$bin" 2>"$scratch/cap-err"
err="$(cat "$scratch/cap-err")"
check "an unknown value falls back to the toolchain default" \
    "1" "$FS_BACKEND_CHROMIUM_OWN_SANDBOX"
case "$err" in
    *"not '0' or '1'"*) ok "an unknown value warns" ;;
    *) no "an unknown value warns" "$err" ;;
esac

echo ""
echo "== the contract addition, on the real backends =="

out="$("$repo_dir/scripts/sandbox-backend-bwrap" --capabilities 2>&1)"
case "$out" in
    *"chromium_own_sandbox=1"*) ok "bwrap declares chromium_own_sandbox=1" ;;
    *) no "bwrap declares chromium_own_sandbox=1" "$out" ;;
esac

out="$("$repo_dir/scripts/sandbox-backend-container" --capabilities 2>&1)"
case "$out" in
    *"chromium_own_sandbox=0"*) ok "container declares chromium_own_sandbox=0" ;;
    *) no "container declares chromium_own_sandbox=0" "$out" ;;
esac

echo ""
echo "$pass passed, $fail failed"
(( fail == 0 ))
