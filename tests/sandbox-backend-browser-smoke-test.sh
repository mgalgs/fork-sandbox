#!/usr/bin/env bash
# sandbox-backend-browser-smoke-test.sh — G3: the announced screenshot recipe
# actually renders, per backend
#
# Usage: tests/sandbox-backend-browser-smoke-test.sh
#
# docs/visual-browser.md's G3 guarantee is that the flags fs_detect_browser
# and the ## Browser prompt section promise are not folklore: they are
# measured to work on each backend. This test is that measurement, redone on
# every run rather than trusted from the design doc's one-time experiment.
#
# The bwrap half execs a real nested sandbox: a static HTML page is served on
# loopback INSIDE the sandboxed network namespace (--net sealed unshares the
# namespace, so a host-side server would be unreachable -- server and client
# have to share one bwrap invocation), then screenshotted with the exact
# recipe flags docs/visual-browser.md and the ## Browser section commit to.
# SKIPped when bwrap or a host chromium is unavailable, the same style as
# tests/sandbox-backend-bind-order-test.sh.
#
# The container half needs no live container: the default image ships no
# browser (images/sandbox/Dockerfile), so this only asserts that
# fs_detect_browser reports absence under an image toolchain -- the truth
# G2's container announcement already encodes.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"
pass=0; fail=0; tmpdirs=(); server_pid=""
cleanup() {
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
    local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done
}
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
newdir() { mktemp -d; }

printf '== bwrap backend ==\n'
if ! command -v bwrap >/dev/null 2>&1; then
    printf '  SKIP  bwrap not installed\n'
else
    FS_BACKEND_TOOLCHAIN=host
    fs_detect_browser
    if [[ -z "$FS_BROWSER_CHROMIUM" ]]; then
        printf '  SKIP  no chromium detected on this host\n'
    else
        w="$(newdir)"; tmpdirs+=("$w")
        cat > "$w/index.html" <<'HTML'
<!doctype html>
<html><body style="margin:0">
<div style="width:100vw;height:100vh;background:#ff3366"></div>
</body></html>
HTML

        port=18917
        # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
        probe='
w="$1"; chromium="$2"; port="$3"
cd "$w" || exit 1
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
for _ in $(seq 1 50); do
    (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null && break
    sleep 0.1
done
"$chromium" --headless=new --disable-gpu --disable-dev-shm-usage \
    --screenshot="$w/out.png" --window-size=1280,2000 \
    "http://127.0.0.1:$port/" >/dev/null 2>&1
rc=$?
kill "$srv" 2>/dev/null
exit "$rc"
'
        if timeout 30 "$repo_dir/scripts/sandbox-backend-bwrap" --net sealed \
            --workdir "$w" -- /bin/bash -c "$probe" _ "$w" "$FS_BROWSER_CHROMIUM" "$port"; then
            ok "screenshot recipe exits 0 inside a sealed bwrap sandbox"
        else
            no "screenshot recipe exits 0 inside a sealed bwrap sandbox"
        fi

        if [[ -s "$w/out.png" ]]; then
            magic="$(od -An -tx1 -N4 "$w/out.png" | tr -d ' \n')"
            if [[ "$magic" == "89504e47" ]]; then
                ok "screenshot is a PNG"
            else
                no "screenshot is a PNG" "magic bytes were $magic"
            fi

            size="$(wc -c < "$w/out.png")"
            if (( size > 3000 )); then
                ok "screenshot is non-trivial ($size bytes)"
            else
                no "screenshot is non-trivial" "only $size bytes"
            fi
        else
            no "screenshot is a PNG" "out.png was not written"
            no "screenshot is non-trivial" "out.png was not written"
        fi
    fi
fi

printf '\n== container backend ==\n'
# No live container needed: the default image ships no browser
# (images/sandbox/Dockerfile), so the container half of G2's announcement is
# always the absence text. This asserts fs_detect_browser encodes that.
# shellcheck disable=SC2034  # read by fs_detect_browser after this test sources the library
FS_BACKEND_TOOLCHAIN=image
fs_detect_browser
if [[ -z "$FS_BROWSER_CHROMIUM" && -z "$FS_BROWSER_PLAYWRIGHT" ]]; then
    ok "fs_detect_browser reports no browser under an image toolchain"
else
    no "fs_detect_browser reports no browser under an image toolchain" \
        "chromium='$FS_BROWSER_CHROMIUM' playwright='$FS_BROWSER_PLAYWRIGHT'"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
