#!/usr/bin/env bash
# fork-sandbox-review-kit-bind-test.sh — The review kit's checkout bind
#
# Usage: tests/fork-sandbox-review-kit-bind-test.sh
#
# fork-sandbox.sh binds the shared ~/.claude/scripts farm read-only into
# every sandboxed run, plus --prepend-path so the review kit's porcelain is
# reachable. The farm holds per-file symlinks install.sh makes into a
# checkout's scripts/ directory, and other projects link their own scripts
# into the same farm -- so binding the farm alone mounts dangling links
# unless the checkout each entry resolves into is bound too, at its real
# path.
#
# Which checkout owns a given farm entry cannot be inferred by picking
# "whichever link readdir returns first" (the bug this suite guards
# against): that answer depends on directory order, not on which checkout
# this script actually is. The fix binds this launcher's OWN directory
# instead, since that IS the one checkout whose links need to resolve here.
# A foreign project's links in the same farm are expected to stay dangling
# inside the sandbox -- mounting them was never intended.
#
# claude-sandboxed is stubbed out entirely -- it drains stdin, records its
# own argv, and exits 0 -- so no sandbox backend is ever exercised. This
# tests only what fork-sandbox.sh decides to bind, following the approach
# tests/fork-sandbox-review-harness-test.sh already uses for the same
# reason (see its "run_real" and stub_bin).
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work. Mark it so
# sandbox-run-log.py's list/stats exclude it by default (see the sibling
# suites for the same export).
export FORK_SANDBOX_RUN_SOURCE=test

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

# Checks that argv (one token per line in FILE) contains FLAG immediately
# followed by VALUE -- exactly how --bind-ro/--prepend-path pairs are built.
argv_has_flag_value() {
    local file="$1" flag="$2" value="$3"
    awk -v f="$flag" -v v="$value" '
        pending { if ($0 == v) found = 1; pending = 0 }
        $0 == f { pending = 1 }
        END { exit !found }
    ' "$file"
}

argv_lacks_bind_ro() {
    local file="$1" dir="$2"
    ! argv_has_flag_value "$file" --bind-ro "$dir"
}

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-review-kit-bind-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
# Fake claude-sandboxed: bypasses bwrap entirely. It drains the prompt from
# stdin (never read) and records the argv it was handed -- exactly what a
# caller building bind flags needs checked -- then exits 0 without ever
# creating a sandbox.
cat >/dev/null
printf '%s\n' "$@" > "$FAKE_ARGV_FILE"
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

new_project() {
    local home="$1" d
    mkdir -p "$home/src"
    d="$(mktemp -d "$home/src/fs-review-kit-bind-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# Runs fork-sandbox.sh for real, foreground, against a fixture $HOME, and
# prints the path to the file the stub recorded its argv into. Every path it
# creates is registered with tmpdirs itself -- this runs in the caller's own
# shell, not inside a command substitution subshell, so an append here does
# reach the trap.
run_and_capture_argv() {
    local home="$1"
    local proj handoff_dir handoff argv_file cfg out rc rd
    proj="$(new_project "$home")"
    handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-review-kit-bind-handoff.XXXXXX)"
    tmpdirs+=("$handoff_dir")
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    argv_file="$(mktemp /var/tmp/claude-scratch/fs-review-kit-bind-argv.XXXXXX)"
    tmpdirs+=("$argv_file")
    cfg="$(mktemp -d)"
    tmpdirs+=("$cfg")
    out="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FAKE_ARGV_FILE="$argv_file" \
        timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
        printf 'run failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    [[ -n "$rd" ]] && tmpdirs+=("$rd")
    printf '%s' "$argv_file"
}

printf '== the shared farm: this checkout is bound, a foreign one is not ==\n'

# A fixture $HOME whose farm holds a symlink into THIS repo's own scripts/
# directory (the checkout under test, and the one fork-sandbox.sh's own
# script_dir resolves to) plus a symlink into an unrelated directory,
# standing in for a different project's checkout sharing the same farm.
# ORDER controls which link is created first, so cases 1-3 below can be
# proven order-independent -- the whole point of the fix.
new_farm_home() {
    local order="$1" home foreign_dir
    home="$(mktemp -d)"
    tmpdirs+=("$home")
    mkdir -p "$home/.claude/scripts"
    foreign_dir="$(mktemp -d /var/tmp/claude-scratch/fs-review-kit-bind-foreign.XXXXXX)"
    tmpdirs+=("$foreign_dir")
    printf '#!/usr/bin/env bash\nexit 0\n' > "$foreign_dir/foreign-tool.sh"
    chmod +x "$foreign_dir/foreign-tool.sh"
    if [[ "$order" == foreign-first ]]; then
        ln -s "$foreign_dir/foreign-tool.sh" "$home/.claude/scripts/foreign-tool.sh"
        ln -s "$repo_dir/scripts/fork-sandbox.sh" "$home/.claude/scripts/fork-sandbox.sh"
    else
        ln -s "$repo_dir/scripts/fork-sandbox.sh" "$home/.claude/scripts/fork-sandbox.sh"
        ln -s "$foreign_dir/foreign-tool.sh" "$home/.claude/scripts/foreign-tool.sh"
    fi
    printf '%s|%s' "$home" "$foreign_dir"
}

check_farm_case() {
    local order="$1" label_suffix="$2" pair home foreign_dir argv_file
    pair="$(new_farm_home "$order")"
    home="${pair%%|*}"
    foreign_dir="${pair#*|}"
    argv_file="$(run_and_capture_argv "$home")"
    if [[ -z "$argv_file" ]]; then
        no "run_and_capture_argv produced an argv file$label_suffix" "run failed"
        return
    fi
    if argv_has_flag_value "$argv_file" --bind-ro "$repo_dir/scripts"; then
        ok "this checkout's scripts dir is bound$label_suffix"
    else
        no "this checkout's scripts dir is bound$label_suffix" "$(cat "$argv_file")"
    fi
    if argv_lacks_bind_ro "$argv_file" "$foreign_dir"; then
        ok "the foreign checkout's dir is NOT bound$label_suffix"
    else
        no "the foreign checkout's dir is NOT bound$label_suffix" "$(cat "$argv_file")"
    fi
    if argv_has_flag_value "$argv_file" --bind-ro "$home/.claude/scripts"; then
        ok "the farm itself is bound$label_suffix"
    else
        no "the farm itself is bound$label_suffix" "$(cat "$argv_file")"
    fi
    if argv_has_flag_value "$argv_file" --prepend-path "$home/.claude/scripts"; then
        ok "the farm is prepended onto PATH$label_suffix"
    else
        no "the farm is prepended onto PATH$label_suffix" "$(cat "$argv_file")"
    fi
}

# Case 1+2+4: repo-checkout bound, foreign checkout not, farm bound+prepended.
check_farm_case repo-first " (repo link created first)"

# Case 3: order-independence -- the same assertions must hold when the
# foreign link is the one readdir would see first. A test that only passed
# in the lucky ordering would prove nothing about the fix.
check_farm_case foreign-first " (foreign link created first)"

printf '\n== no farm: neither bind fires ==\n'

no_farm_home="$(mktemp -d)"
tmpdirs+=("$no_farm_home")
argv_file_nofarm="$(run_and_capture_argv "$no_farm_home")"
if [[ -n "$argv_file_nofarm" ]]; then
    if argv_lacks_bind_ro "$argv_file_nofarm" "$no_farm_home/.claude/scripts"; then
        ok "no --bind-ro for a farm that does not exist"
    else
        no "no --bind-ro for a farm that does not exist" "$(cat "$argv_file_nofarm")"
    fi
    if argv_lacks_bind_ro "$argv_file_nofarm" "$repo_dir/scripts"; then
        ok "no --bind-ro for the checkout either, with no farm to make it resolvable"
    else
        no "no --bind-ro for the checkout either, with no farm to make it resolvable" \
            "$(cat "$argv_file_nofarm")"
    fi
else
    no "no --bind-ro for a farm that does not exist" "run failed"
    no "no --bind-ro for the checkout either, with no farm to make it resolvable" "run failed"
fi

printf '\n== a farm with no symlinks at all still gets the checkout bind ==\n'

# The case the old first_link/readdir approach silently skipped: nothing to
# find a link *from*, yet the checkout bind no longer depends on finding one.
plain_farm_home="$(mktemp -d)"
tmpdirs+=("$plain_farm_home")
mkdir -p "$plain_farm_home/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$plain_farm_home/.claude/scripts/plain-tool.sh"
chmod +x "$plain_farm_home/.claude/scripts/plain-tool.sh"
argv_file_plain="$(run_and_capture_argv "$plain_farm_home")"
if [[ -n "$argv_file_plain" ]]; then
    if argv_has_flag_value "$argv_file_plain" --bind-ro "$repo_dir/scripts"; then
        ok "the checkout is bound even when the farm holds only regular files"
    else
        no "the checkout is bound even when the farm holds only regular files" \
            "$(cat "$argv_file_plain")"
    fi
    if argv_has_flag_value "$argv_file_plain" --bind-ro "$plain_farm_home/.claude/scripts"; then
        ok "the farm itself is still bound alongside it"
    else
        no "the farm itself is still bound alongside it" "$(cat "$argv_file_plain")"
    fi
else
    no "the checkout is bound even when the farm holds only regular files" "run failed"
    no "the farm itself is still bound alongside it" "run failed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
