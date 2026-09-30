#!/usr/bin/env bash
# sandbox-backend-bind-order-test.sh — Nested binds must survive their parent
#
# Usage: tests/sandbox-backend-bind-order-test.sh
#
# A backend applies mounts in sequence, and a mount over a directory hides
# every mount made inside it beforehand. So a caller that binds a leaf and
# then remaps the tree above it gets the leaf only if the backend orders the
# two by destination depth rather than by the order the flags arrived.
#
# claude-sandboxed is exactly that caller: it binds the self-review skills at
# $HOME/.claude/skills/<name> and the script toolbox at $HOME/.claude/scripts,
# and it also remaps the whole of $HOME/.claude to a per-run state dir so the
# sandbox cannot see the host's. Ordered wrongly, the remap lands last and the
# review kit is silently absent -- a sandbox that looks complete, a
# --review-loop with no review engine, and a --prepend-path pointing at
# nothing. Nothing errors, which is why this suite exists.
#
# The property is the contract's, not one backend's, so both backends are held
# to it. The container backend has always passed: Docker orders its own mounts
# by destination depth. bwrap does not, and did not, until the backend sorted
# them itself.
#
# The tests are hermetic -- a temp tree stands in for $HOME/.claude -- and each
# half is skipped when its runtime is missing.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

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
contains() {
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else no "$1" "missing '$2' in: $3"; fi
}
lacks() {
    if [[ "$3" != *"$2"* ]]; then ok "$1"; else no "$1" "unexpected '$2' in: $3"; fi
}
newdir() { mktemp -d; }

# The shape under test, built once and handed to whichever backend is running.
#
#   $tree/dot-claude/skills/kit/marker   the leaf, bound read-only
#   $tree/dot-claude                     the tree above it, remapped writable
#
# `dot-claude` rather than `.claude`: the name is immaterial to the property,
# and a visible one keeps a stray `ls` in a failure message readable.
tree="$(newdir)"; tmpdirs+=("$tree")
leaf="$tree/dot-claude/skills/kit"
mkdir -p "$leaf"
printf 'kit-present\n' > "$leaf/marker"
state="$(newdir)"; tmpdirs+=("$state")
printf 'state-present\n' > "$state/state-marker"

# What the sandbox runs: report the leaf, then the remap, then both nested
# under one another. `-` for anything missing, so a wrong answer prints as a
# value rather than as an empty string.
# shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
probe='printf "%s|%s" "$(cat "$1/skills/kit/marker" 2>/dev/null || printf -- -)" "$(cat "$1/state-marker" 2>/dev/null || printf -- -)"'

run_bwrap() {
    "$repo_dir/scripts/sandbox-backend-bwrap" --net sealed "$@" 2>/dev/null
}

# Host aliases decide what the resolver reaches, so reject values before they
# can become a line in the synthesized hosts file. These fail before bwrap is
# invoked and therefore run even on machines without the runtime.
for bad_alias in $'gateway.example\ninjected.invalid' '-gateway.example' \
    'gateway example'; do
    if "$repo_dir/scripts/sandbox-backend-bwrap" --net sealed --workdir "$(newdir)" \
        --hosts-alias "$bad_alias" -- true >/dev/null 2>&1; then
        no "rejects unsafe hosts alias '$bad_alias'"
    else
        ok "rejects unsafe hosts alias '$bad_alias'"
    fi
done
too_long_alias="$(printf 'a%.0s' {1..254})"
if "$repo_dir/scripts/sandbox-backend-bwrap" --net sealed --workdir "$(newdir)" \
    --hosts-alias "$too_long_alias" -- true >/dev/null 2>&1; then
    no "rejects hosts alias longer than 253 characters"
else
    ok "rejects hosts alias longer than 253 characters"
fi

printf '== bwrap backend ==\n'
if ! command -v bwrap >/dev/null 2>&1; then
    printf '  SKIP  bwrap not installed\n'
else
    w="$(newdir)"; tmpdirs+=("$w")

    # The claude-sandboxed order: leaf first, remap second. This is the case
    # that regressed -- by category order the remap went last and won.
    out="$(run_bwrap --workdir "$w" \
        --bind-ro "$leaf" \
        --bind-rw-at "$state" "$tree/dot-claude" \
        -- /bin/bash -c "$probe" _ "$tree/dot-claude")"
    check "leaf bound before parent remap survives it" "kit-present|state-present" "$out"

    # The same two flags the other way round. Depth decides, so the answer must
    # not depend on the order the caller happened to pass them in.
    out="$(run_bwrap --workdir "$w" \
        --bind-rw-at "$state" "$tree/dot-claude" \
        --bind-ro "$leaf" \
        -- /bin/bash -c "$probe" _ "$tree/dot-claude")"
    check "flag order does not change the result" "kit-present|state-present" "$out"

    # Depth ordering must not cost the documented case it was already getting
    # right: a remapped read-only bind inside the writable work dir still
    # re-protects that path, because it is deeper than the work dir.
    ro_src="$(newdir)"; tmpdirs+=("$ro_src"); printf 'protected\n' > "$ro_src/file"
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" --bind-ro-at "$ro_src" "$w/guarded" \
        -- /bin/bash -c 'touch "$1/guarded/scratch" 2>/dev/null && printf writable || printf readonly; touch "$1/scratch" 2>/dev/null && printf "|writable" || printf "|readonly"' _ "$w")"
    check "read-only remap still re-protects inside the work dir" "readonly|writable" "$out"
    rm -f "$w/scratch"

    # Equal depths keep category order, which is what every caller saw before
    # the sort: read-only first, then the writable remap, so the remap wins a
    # tie at the same destination.
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" \
        --bind-ro "$state" \
        --bind-rw-at "$state" "$state" \
        -- /bin/bash -c 'touch "$1/tie" 2>/dev/null && printf writable || printf readonly' _ "$state")"
    check "equal depth keeps category order" "writable" "$out"
    rm -f "$state/tie"

    # Passing an alias twice must not leave the resolver two addresses to try.
    # shellcheck disable=SC2016  # quoted program runs inside the sandbox
    out="$(run_bwrap --workdir "$w" --hosts-alias gateway.example \
        --hosts-alias gateway.example -- /bin/bash -c \
        'grep -c "[[:space:]]gateway.example$" /etc/hosts')"
    check "hosts alias is unique" "1" "$out"
    if run_bwrap --workdir "$w" --hosts-alias gateway.example -- \
        /bin/bash -c 'grep -q "[[:space:]]localhost$" /etc/hosts'; then
        ok "hosts alias preserves localhost"
    else
        no "hosts alias preserves localhost"
    fi

    # Disk-backed scratch: /tmp and $HOME replaced tmpfs with a per-invocation
    # bind. Static check first -- neither --tmpfs /tmp nor --tmpfs "$HOME"
    # (the literal spelling this file used before) may remain in the script,
    # since a stray one would silently put RAM back under one of them.
    # shellcheck disable=SC2016  # the pattern, not this script's own $HOME
    if grep -qE -- '--tmpfs /tmp$|--tmpfs "\$HOME"$' "$repo_dir/scripts/sandbox-backend-bwrap"; then
        no "no --tmpfs /tmp or --tmpfs \$HOME remains"
    else
        ok "no --tmpfs /tmp or --tmpfs \$HOME remains"
    fi

    # A bind mount reports the SOURCE directory's own mode, so asking the
    # sandboxed process to stat $HOME and /tmp is a way to see the scratch
    # root's mode (0700, from mktemp) without ever seeing its host path.
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" -- /bin/bash -c 'stat -c %a "$HOME"; stat -c %a /tmp')"
    check "scratch \$HOME is mode 0700" "$(printf '700\n700')" "$out"

    # Two invocations must not share a root: a marker left in the first run's
    # $HOME must be gone in a second, independent one.
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" -- /bin/bash -c 'echo mark > "$HOME/marker"; cat "$HOME/marker"')"
    check "first invocation writes its marker" "mark" "$out"
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" -- /bin/bash -c '[[ -e "$HOME/marker" ]] && echo present || echo absent')"
    check "a second invocation gets a fresh root, not the first one's" "absent" "$out"

    # --run-dir: the scratch root lands under the caller-supplied directory
    # rather than the fallback location, and is gone once the sandbox exits
    # -- including when the command itself fails, since cleanup is a trap,
    # not a success-path step.
    rd="$(newdir)"; tmpdirs+=("$rd")
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    run_bwrap --workdir "$w" --run-dir "$rd" -- /bin/bash -c 'echo hi > "$HOME/x"' >/dev/null
    check "--run-dir leaves nothing behind after a normal exit" "" "$(ls -A "$rd")"
    run_bwrap --workdir "$w" --run-dir "$rd" -- /bin/bash -c 'exit 7' >/dev/null
    rc=$?
    check "the failing command's exit code still comes back" "7" "$rc"
    check "--run-dir leaves nothing behind after a failing command" "" "$(ls -A "$rd")"

    # --run-dir refuses the same system paths --workdir does, rather than
    # silently creating a scratch root there.
    if run_out="$("$repo_dir/scripts/sandbox-backend-bwrap" --workdir "$w" --net sealed --run-dir /etc -- true 2>&1)"; then
        no "--run-dir refuses a system path" "exit 0: $run_out"
    else
        case "$run_out" in *refusing*) ok "--run-dir refuses a system path" ;;
            *) no "--run-dir refuses a system path" "$run_out" ;; esac
    fi

    # A build tool's own cache (Go's module cache under $HOME is the standard
    # example) is routinely written read-only. On the old tmpfs that never
    # mattered -- unmounting discarded it regardless -- but a plain rm -rf on
    # disk stops at the first read-only directory and leaves the rest behind.
    rd="$(newdir)"; tmpdirs+=("$rd")
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    run_bwrap --workdir "$w" --run-dir "$rd" -- /bin/bash -c \
        'mkdir -p "$HOME/go/pkg/mod/x"; echo f > "$HOME/go/pkg/mod/x/f"; chmod -R a-w "$HOME/go/pkg/mod"' >/dev/null
    check "--run-dir leaves nothing behind after a read-only subtree" "" "$(ls -A "$rd")"

    # What the kernel says, not the argv: /tmp and $HOME are not tmpfs inside.
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(run_bwrap --workdir "$w" -- /bin/bash -c \
        'while read -r _ mp fs _; do [[ "$mp" == /tmp || "$mp" == "$HOME" ]] && echo "$mp $fs"; done < /proc/mounts' \
        | sed "s|^$HOME |HOME |")"
    case "$out" in
        *tmpfs*) no "/tmp and \$HOME are not tmpfs inside the sandbox" "$out" ;;
        *"/tmp "*) ok "/tmp and \$HOME are not tmpfs inside the sandbox" ;;
        *) no "/tmp and \$HOME are not tmpfs inside the sandbox" "no /tmp mount seen: $out" ;;
    esac

    # /dev/shm is capped where bwrap supports --size, and a bwrap that
    # predates --size still launches, keeping --dev's own /dev/shm.
    shm_opts() { grep ' /dev/shm ' /proc/mounts; }
    if bwrap --help 2>&1 | grep -q -- '--size'; then
        # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
        out="$(run_bwrap --workdir "$w" -- /bin/bash -c "$(declare -f shm_opts); shm_opts")"
        contains "/dev/shm is capped at 1GiB" "size=1048576k" "$out"
    fi
    oldbwrap="$(newdir)"; tmpdirs+=("$oldbwrap")
    real_bwrap="$(command -v bwrap)"
    cat > "$oldbwrap/bwrap" <<STUB
#!/usr/bin/env bash
if [[ "\${1-}" == --help ]]; then "$real_bwrap" --help 2>&1 | grep -v -- '--size'; exit 0; fi
for a in "\$@"; do [[ "\$a" == --size ]] && { echo "bwrap: Unknown option --size" >&2; exit 1; }; done
exec "$real_bwrap" "\$@"
STUB
    chmod +x "$oldbwrap/bwrap"
    # shellcheck disable=SC2016  # a program for the sandbox's bash, not this one
    out="$(PATH="$oldbwrap:$PATH" run_bwrap --workdir "$w" -- /bin/bash -c "$(declare -f shm_opts); shm_opts; echo launched")"
    contains "a bwrap without --size still launches" "launched" "$out"
    lacks "a bwrap without --size gets no /dev/shm cap" "size=1048576k" "$out"
fi

printf '\n== container backend ==\n'
runtime="${FORK_SANDBOX_CONTAINER_CLI:-docker}"
if ! command -v "$runtime" >/dev/null 2>&1 || ! "$runtime" info >/dev/null 2>&1; then
    printf '  SKIP  runtime unavailable\n'
else
    image="fork-sandbox-bind-order-test:$RANDOM-$$"
    if ! "$runtime" build -t "$image" "$repo_dir/tests/container-backend-image" >/dev/null 2>&1; then
        printf '  SKIP  test image build failed (the machine may be offline)\n'
    else
        w="$(newdir)"; tmpdirs+=("$w")
        out="$(FORK_SANDBOX_CONTAINER_CLI="$runtime" \
            "$repo_dir/scripts/sandbox-backend-container" --image "$image" --net sealed \
            --workdir "$w" \
            --bind-ro "$leaf" \
            --bind-rw-at "$state" "$tree/dot-claude" \
            -- /bin/bash -c "$probe" _ "$tree/dot-claude" 2>/dev/null)"
        check "leaf bound before parent remap survives it" "kit-present|state-present" "$out"

        # A nested bind needs a mountpoint inside the remapped tree, and the
        # runtime makes one when it is missing -- as root, in a directory the
        # caller owns, which the caller then cannot remove. claude-sandboxed
        # avoids that by creating the mountpoints itself before the run; this
        # checks the property that fix rests on, namely that a mountpoint
        # which already exists is left alone and stays the caller's.
        owner_state="$(newdir)"; tmpdirs+=("$owner_state")
        mkdir -p "$owner_state/skills/kit"
        FORK_SANDBOX_CONTAINER_CLI="$runtime" \
            "$repo_dir/scripts/sandbox-backend-container" --image "$image" --net sealed \
            --workdir "$w" \
            --bind-ro "$leaf" \
            --bind-rw-at "$owner_state" "$tree/dot-claude" \
            -- /bin/bash -c true >/dev/null 2>&1
        if [[ -O "$owner_state/skills/kit" ]]; then
            ok "pre-created mountpoint keeps its owner"
        else
            no "pre-created mountpoint keeps its owner" "$(ls -ld "$owner_state/skills/kit" 2>&1)"
        fi
        if rm -rf "$owner_state/skills" 2>/dev/null && [[ ! -e "$owner_state/skills" ]]; then
            ok "pre-created mountpoint is removable after the run"
        else
            # shellcheck disable=SC2012  # a diagnostic; ls prints the owner and find does not, portably
            no "pre-created mountpoint is removable after the run" "$(ls -ldR "$owner_state" 2>&1 | tr '\n' ' ')"
        fi

        "$runtime" image rm "$image" >/dev/null 2>&1 || true
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
