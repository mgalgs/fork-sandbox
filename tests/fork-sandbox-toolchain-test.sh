#!/usr/bin/env bash
# fork-sandbox-toolchain-test.sh — Exercise the backend toolchain property
#
# Usage: tests/fork-sandbox-toolchain-test.sh
#
# bwrap mounts the host's /usr, so a bwrap sandbox can be handed the host's
# claude, node or virtualenv interpreter and run them. A container cannot: its
# userland is its image's, and a host binary bound into it has neither its
# interpreter nor its shared libraries. That is Mach-O against Linux on a Mac
# and glibc against musl on Linux — one property, two symptoms — so the callers
# ask the BACKEND which case they are in rather than asking `uname`.
#
# This covers that machinery end to end at the library level:
#
#   - `--capabilities`, the contract addition, on both real backends.
#   - fs_backend_capabilities parsing, including every way a backend can fail
#     to answer. A backend written before the option existed must read as
#     `host`, the status quo, and never as `image`: guessing `image` would stop
#     binding a toolchain that a bwrap sandbox genuinely needs.
#   - The provisioning functions that change behaviour with it.
#
# It does NOT launch a sandbox. What a run does with these flags needs a real
# backend and a real image; what is testable here is that the right flags, and
# the right warnings, come out of the library.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

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

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

# Like contains(), but never echoes the haystack. Used where the value under
# test could be a real credential: a secret printed into a failure message is
# a leaked secret, and a test log is a place secrets go to be forgotten about.
contains_quiet() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle'; the actual value is withheld here because it may be a credential" ;;
    esac
}

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

scratch="$(mktemp -d)"
tmpdirs+=("$scratch")

# A stand-in backend whose only job is to answer --capabilities however the
# case needs. Each one is a real executable, so fs_backend_capabilities runs it
# exactly as it runs a real backend.
fake_backend() {
    local name="$1" body="$2"
    local path="$scratch/sandbox-backend-$name"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$body"; } > "$path"
    chmod 755 "$path"
    printf '%s\n' "$path"
}

echo "== the contract addition, on the real backends =="

for backend in bwrap container; do
    out="$("$repo_dir/scripts/sandbox-backend-$backend" --capabilities 2>&1)"
    rc=$?
    check "sandbox-backend-$backend --capabilities exits 0" "0" "$rc"
    case "$backend" in
        bwrap)     check "bwrap declares toolchain=host" "toolchain=host" "$out" ;;
        container) check "container declares toolchain=image" "toolchain=image" "$out" ;;
    esac
done

# The option must not need a command, a work dir or a network mode: it is a
# question about the backend, asked before any run is being set up.
out="$("$repo_dir/scripts/sandbox-backend-container" --capabilities 2>&1)"
lacks "--capabilities needs no other option" "Error" "$out"

echo ""
echo "== fs_backend_capabilities =="

bin="$(fake_backend host-decl 'echo toolchain=host')"
fs_backend_capabilities "$bin"
check "a host declaration is read" "host" "$FS_BACKEND_TOOLCHAIN"

bin="$(fake_backend image-decl 'echo toolchain=image')"
fs_backend_capabilities "$bin"
check "an image declaration is read" "image" "$FS_BACKEND_TOOLCHAIN"

# A backend from before the option existed refuses it. That has to read as
# `host` — the behaviour every backend had before the property was invented.
bin="$(fake_backend legacy 'echo "Error: unknown option" >&2; exit 1')"
fs_backend_capabilities "$bin"
check "a backend that refuses the option reads as host" "host" "$FS_BACKEND_TOOLCHAIN"

# ...and specifically must not be believed when it exits non-zero, even if
# something on stdout happens to look like a declaration. Usage text is not an
# answer.
bin="$(fake_backend usage-on-error 'echo toolchain=image; echo "Error: unknown option" >&2; exit 1')"
fs_backend_capabilities "$bin"
check "output from a failed call is not parsed" "host" "$FS_BACKEND_TOOLCHAIN"

# A usage line can hold an '=' without being a capability.
bin="$(fake_backend usage-text 'echo "  --setenv K=V   Set one variable inside."')"
fs_backend_capabilities "$bin"
check "a usage line with an = is not a declaration" "host" "$FS_BACKEND_TOOLCHAIN"

# An unknown key is ignored, so a newer backend can declare more than an older
# caller understands without breaking it.
bin="$(fake_backend future 'echo toolchain=image; echo isolation=microvm')"
fs_backend_capabilities "$bin"
check "an unknown key is ignored, the known one still read" "image" "$FS_BACKEND_TOOLCHAIN"

# A value that is neither is refused loudly and falls back to the safe answer.
# Redirect stderr to a file rather than capturing it: a command substitution
# would run the call in a subshell, and the variable it sets would not come
# back — the very shape this suite exists to keep honest.
bin="$(fake_backend nonsense 'echo toolchain=banana')"
fs_backend_capabilities "$bin" 2>"$scratch/cap-err"
err="$(cat "$scratch/cap-err")"
check "an unknown toolchain value falls back to host" "host" "$FS_BACKEND_TOOLCHAIN"
contains "an unknown toolchain value warns" "not 'host' or 'image'" "$err"

# A backend that says nothing at all.
bin="$(fake_backend silent 'exit 0')"
fs_backend_capabilities "$bin"
check "a silent backend reads as host" "host" "$FS_BACKEND_TOOLCHAIN"

echo ""
echo "== fs_resolve_pi under an image toolchain =="

FS_BACKEND_TOOLCHAIN=image
fs_resolve_pi
rc=$?
check "fs_resolve_pi succeeds without a host pi" "0" "$rc"
check "pi is invoked by name" "pi" "${FS_PI_ARGV0[*]}"
check "there is no tree to bind" "" "$FS_PI_ROOT"
check "there is nothing to put on PATH" "" "$FS_PI_BIN_DIR"
check "no host node is named" "" "$FS_PI_NODE"

echo ""
echo "== fs_node_provision =="

# A repo with an .nvmrc and a node_modules holding one compiled module.
origin="$scratch/origin"
mkdir -p "$origin/node_modules/better-sqlite3/build/Release"
printf 'v22.11.0\n' > "$origin/.nvmrc"
printf 'not really a binary\n' \
    > "$origin/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
printf 'module.exports = 1\n' > "$origin/node_modules/left-pad.js"

FS_BACKEND_TOOLCHAIN=image
clone="$scratch/clone-image"
mkdir -p "$clone"
err="$(fs_node_provision "$origin" "$clone" 2>&1)"
check "image mode binds no host node" "0" "${#FS_NODE_FLAGS[@]}"
contains "image mode says the .nvmrc is not honoured" "image's node is what the run gets" "$err"
contains "image mode counts the native modules" "1 compiled native module" "$err"
contains "image mode names the offender" "better_sqlite3.node" "$err"
contains "image mode says how to fix it" "npm rebuild" "$err"
if [[ -f "$clone/node_modules/left-pad.js" ]]; then
    ok "image mode still copies node_modules"
else
    no "image mode still copies node_modules"
fi

# Under a host toolchain none of that fires, and a real .nvmrc install would be
# bound. Point the version at one that cannot exist so the case is stable on
# any machine: the warning proves the host branch ran.
FS_BACKEND_TOOLCHAIN=host
clone="$scratch/clone-host"
mkdir -p "$clone"
printf 'v0.0.1\n' > "$origin/.nvmrc"
err="$(fs_node_provision "$origin" "$clone" 2>&1)"
lacks "host mode does not scan for native modules" "compiled native module" "$err"
contains "host mode still resolves the .nvmrc" "not installed" "$err"

echo ""
echo "== fs_cache_binds =="

# The two caches differ in kind, and the split is the point: model DATA travels
# to any sandbox, browser BINARIES only to one running the host's userland.
fake_home="$scratch/home"
mkdir -p "$fake_home/.cache/huggingface/hub" "$fake_home/.cache/ms-playwright"
real_home="$HOME"
HOME="$fake_home"

FS_BACKEND_TOOLCHAIN=host
fs_cache_binds
contains "host mode binds the model cache" "huggingface/hub" "${FS_CACHE_FLAGS[*]}"
contains "host mode binds the browser cache" "ms-playwright" "${FS_CACHE_FLAGS[*]}"

FS_BACKEND_TOOLCHAIN=image
fs_cache_binds
contains "image mode still binds the model cache" "huggingface/hub" "${FS_CACHE_FLAGS[*]}"
lacks "image mode does not bind the browser cache" "ms-playwright" "${FS_CACHE_FLAGS[*]}"
contains "image mode keeps HF_HUB_OFFLINE with the cache" "HF_HUB_OFFLINE=1" "${FS_CACHE_FLAGS[*]}"

HOME="$real_home"

echo ""
echo "== fs_venv_interpreter_bind =="

venv="$scratch/venv"
mkdir -p "$venv" "$scratch/interp/3.12/bin"
printf 'home = %s\n' "$scratch/interp/3.12/bin" > "$venv/pyvenv.cfg"

FS_BACKEND_TOOLCHAIN=image
FS_PROVISION_RO_FLAGS=()
err="$(fs_venv_interpreter_bind "$venv" 2>&1)"
check "image mode binds no interpreter" "0" "${#FS_PROVISION_RO_FLAGS[@]}"
contains "image mode says why" "userland comes from an" "$err"

echo ""
echo "== fs_read_claude_credential =="

# The Keychain is NOT addressed through $HOME, so overriding HOME does not
# isolate it: on a Mac the fallback would read the user's real credential,
# every assertion below would compare against it, and a failure message would
# print it. Point the lookup at a service that cannot exist instead. That keeps
# the cases running on every platform AND keeps a live token out of them.
FS_CLAUDE_KEYCHAIN_SERVICES=("fork-sandbox-test-service-that-does-not-exist")

cred_home="$scratch/cred-home"
mkdir -p "$cred_home/.claude"
printf '{"claudeAiOauth":{"accessToken":"tok","expiresAt":1}}\n' \
    > "$cred_home/.claude/.credentials.json"
HOME="$cred_home"
out="$(fs_read_claude_credential)"
rc=$?
check "a credential file is read" "0" "$rc"
contains_quiet "the file's contents come back" '"accessToken":"tok"' "$out"
# The source is a separate function precisely because the reader can only be
# used through a command substitution, and a subshell cannot hand a variable
# back. Naming it must therefore work from inside one.
check "the source is named for error messages" \
    "$cred_home/.claude/.credentials.json" "$(fs_claude_credential_source)"

# No file, and no Keychain item under the service name above.
HOME="$scratch/empty-home"
mkdir -p "$HOME"
if err="$(fs_read_claude_credential 2>&1)"; then
    no "a missing credential returns non-zero"
else
    ok "a missing credential returns non-zero"
fi
contains_quiet "a missing credential says what to do" "claude" "$err"

# A file that exists but cannot be READ. `-f` proves neither, and returning 0
# with no output here is diagnosed downstream as an expired token -- sending
# the user to log in again, which rewrites a file they still cannot read.
HOME="$cred_home"
chmod 000 "$cred_home/.claude/.credentials.json"
if err="$(fs_read_claude_credential 2>&1)"; then
    no "an unreadable credential returns non-zero"
else
    ok "an unreadable credential returns non-zero"
fi
contains_quiet "an unreadable credential is not called expired" "could not be read" "$err"
chmod 600 "$cred_home/.claude/.credentials.json"
HOME="$real_home"

echo ""
echo "== GNU tool resolution =="

# On Linux the GNU tool is the bare name. Under Homebrew it is g-prefixed and
# keg-only, so the bare name is still BSD's — which is the whole reason the
# scripts ask for it by resolved name rather than hardcoding one.
check "a GNU realpath was found" "0" "$( _fs_resolve_gnu_tool realpath >/dev/null; echo $? )"
check "a GNU stat was found" "0" "$( _fs_resolve_gnu_tool stat >/dev/null; echo $? )"
check "a GNU timeout was found" "0" "$( _fs_resolve_gnu_tool timeout >/dev/null; echo $? )"
check "fs_require_gnu_tools passes here" "0" "$( fs_require_gnu_tools >/dev/null 2>&1; echo $? )"

# A g-prefixed build wins over a bare one, which is what makes a Mac work.
gdir="$scratch/gnu-bin"
mkdir -p "$gdir"
printf '#!/usr/bin/env bash\necho "grealpath (GNU coreutils) 9.9"\n' > "$gdir/grealpath"
chmod 755 "$gdir/grealpath"
old_path="$PATH"
PATH="$gdir:$PATH"
check "the g-prefixed build is preferred" "grealpath" "$(_fs_resolve_gnu_tool realpath)"
PATH="$old_path"

# A BSD-only machine has neither, and must be told rather than left to hit an
# illegal-option error deep in a run.
bsddir="$scratch/bsd-bin"
mkdir -p "$bsddir"
for t in realpath stat timeout; do
    printf '#!/bin/bash\necho "usage: %s [-q] path" >&2\nexit 1\n' "$t" > "$bsddir/$t"
    chmod 755 "$bsddir/$t"
done
# The stubs use an absolute shebang on purpose: `#!/usr/bin/env bash` would
# send env looking for bash on a PATH that holds only this directory, so the
# stubs would fail to EXEC rather than answer like BSD tools -- and the
# assertion would pass for the wrong reason.
check "the stubs actually run" "1" "$(PATH="$bsddir" realpath --version >/dev/null 2>&1; echo $?)"
err="$(PATH="$bsddir" fs_require_gnu_tools 2>&1)"
rc=$?
check "a BSD-only PATH fails the check" "1" "$rc"
contains "and says how to fix it" "brew install coreutils" "$err"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
