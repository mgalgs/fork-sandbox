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
# unless every checkout an entry resolves into is bound too, at its real
# path.
#
# Which checkout owns a given farm entry cannot be inferred by picking
# "whichever link readdir returns first" (the original bug this suite
# guards against), nor by assuming this launcher's own directory is the
# only one that matters (a second bug the same fix introduced and this
# suite was rewritten to catch): a farm can hold links from several
# checkouts at once, and the script a skill actually names -- e.g.
# review-context.sh, for commit-then-review -- may live in any of them. The
# fix resolves every symlink in the farm to its target directory, dedups,
# and binds all of them, so no checkout's links are left dangling.
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
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
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
# prints the paths it created (argv file, handoff dir, config dir, run dir --
# one per line, run dir may be empty on failure) for the CALLER to register
# with tmpdirs. This function's own body runs inside the caller's
# `$(run_and_capture_argv ...)` command substitution, hence a subshell of
# its own, so a tmpdirs+= made here would update only that subshell's copy
# of the array and never reach the trap -- register_run_paths below exists
# to do the registration back in the shell that owns the real array.
run_and_capture_argv() {
    local home="$1"
    local proj handoff_dir handoff argv_file cfg out rc rd
    proj="$(new_project "$home")"
    handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-review-kit-bind-handoff.XXXXXX)"
    handoff="$handoff_dir/handoff.md"
    printf 'do the task\n' > "$handoff"
    argv_file="$(mktemp /var/tmp/claude-scratch/fs-review-kit-bind-argv.XXXXXX)"
    cfg="$(mktemp -d)"
    out="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FAKE_ARGV_FILE="$argv_file" \
        timeout 60 "$launcher" --foreground --harness claude "$proj" "$handoff" 2>&1)"
    rc=$?
    rd=""
    if (( rc != 0 )); then
        printf 'run failed (rc=%s):\n%s\n' "$rc" "$out" >&2
    else
        rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    fi
    printf '%s\n%s\n%s\n%s\n' "$argv_file" "$handoff_dir" "$cfg" "$rd"
    (( rc == 0 ))
}

# Splits a run_and_capture_argv result and registers every non-empty path
# with tmpdirs (the argv file is always created, win or lose, so it is
# registered unconditionally), then leaves it in REGISTERED_ARGV_FILE for
# the caller. Called directly -- never through a command substitution -- so
# the tmpdirs+= here lands in the real array the EXIT trap reads.
register_run_paths() {
    local result="$1"
    local -a fields
    mapfile -t fields <<<"$result"
    REGISTERED_ARGV_FILE="${fields[0]:-}"
    local handoff_dir="${fields[1]:-}" cfg="${fields[2]:-}" rd="${fields[3]:-}"
    [[ -n "$REGISTERED_ARGV_FILE" ]] && tmpdirs+=("$REGISTERED_ARGV_FILE")
    [[ -n "$handoff_dir" ]] && tmpdirs+=("$handoff_dir")
    [[ -n "$cfg" ]] && tmpdirs+=("$cfg")
    [[ -n "$rd" ]] && tmpdirs+=("$rd")
}

printf '== the shared farm: both checkouts it holds links for are bound ==\n'

# A fixture $HOME whose farm holds a symlink into THIS repo's own scripts/
# directory (the checkout under test, and the one fork-sandbox.sh's own
# script_dir resolves to) plus a symlink into an unrelated directory,
# standing in for a different project's checkout sharing the same farm.
# Creation order is varied between cases 1 and 2 below only as a light
# regression guard against a future "pick one link" reintroduction --
# find's own readdir order is not something this fixture controls, and the
# current fix does not depend on it: every symlink in the farm is resolved
# and its target dir bound, so which one is created first cannot matter.
new_farm_home() {
    local order="$1" home foreign_dir
    home="$(mktemp -d)"
    mkdir -p "$home/.claude/scripts"
    foreign_dir="$(mktemp -d /var/tmp/claude-scratch/fs-review-kit-bind-foreign.XXXXXX)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$foreign_dir/foreign-tool.sh"
    chmod +x "$foreign_dir/foreign-tool.sh"
    if [[ "$order" == foreign-first ]]; then
        ln -s "$foreign_dir/foreign-tool.sh" "$home/.claude/scripts/foreign-tool.sh"
        ln -s "$repo_dir/scripts/fork-sandbox.sh" "$home/.claude/scripts/fork-sandbox.sh"
    else
        ln -s "$repo_dir/scripts/fork-sandbox.sh" "$home/.claude/scripts/fork-sandbox.sh"
        ln -s "$foreign_dir/foreign-tool.sh" "$home/.claude/scripts/foreign-tool.sh"
    fi
    printf '%s\n%s\n' "$home" "$foreign_dir"
}

check_farm_case() {
    local order="$1" label_suffix="$2" pair_result home foreign_dir argv_file
    local -a pair_fields
    local run_result run_rc
    pair_result="$(new_farm_home "$order")"
    mapfile -t pair_fields <<<"$pair_result"
    home="${pair_fields[0]:-}"
    foreign_dir="${pair_fields[1]:-}"
    tmpdirs+=("$home" "$foreign_dir")
    run_result="$(run_and_capture_argv "$home")"
    run_rc=$?
    register_run_paths "$run_result"
    argv_file="$REGISTERED_ARGV_FILE"
    if (( run_rc != 0 )); then
        no "run_and_capture_argv produced an argv file$label_suffix" "run failed"
        return
    fi
    if argv_has_flag_value "$argv_file" --bind-ro "$repo_dir/scripts"; then
        ok "this checkout's scripts dir is bound$label_suffix"
    else
        no "this checkout's scripts dir is bound$label_suffix" "$(cat "$argv_file")"
    fi
    if argv_has_flag_value "$argv_file" --bind-ro "$foreign_dir"; then
        ok "the foreign checkout's dir is ALSO bound$label_suffix"
    else
        no "the foreign checkout's dir is ALSO bound$label_suffix" "$(cat "$argv_file")"
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

# Case 1: repo checkout and foreign checkout both bound, farm bound+prepended.
check_farm_case repo-first " (repo link created first)"

# Case 2: the same assertions must hold with the links created in the
# opposite order -- see the note on new_farm_home above.
check_farm_case foreign-first " (foreign link created first)"

printf '\n== no farm: neither bind fires ==\n'

no_farm_home="$(mktemp -d)"
tmpdirs+=("$no_farm_home")
run_result_nofarm="$(run_and_capture_argv "$no_farm_home")"
run_rc_nofarm=$?
register_run_paths "$run_result_nofarm"
argv_file_nofarm="$REGISTERED_ARGV_FILE"
if (( run_rc_nofarm == 0 )); then
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
run_result_plain="$(run_and_capture_argv "$plain_farm_home")"
run_rc_plain=$?
register_run_paths "$run_result_plain"
argv_file_plain="$REGISTERED_ARGV_FILE"
if (( run_rc_plain == 0 )); then
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
