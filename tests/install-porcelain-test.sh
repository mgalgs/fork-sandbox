#!/usr/bin/env bash
# install-porcelain-test.sh — Exercise install.sh's porcelain/plumbing split:
# only PORCELAIN goes on PATH, PLUMBING never does, an unclassified script
# fails closed, and pruning only ever touches links this repo made.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle'" ;;
    esac
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

# --- Pull the two lists out of install.sh itself -----------------------------
#
# So this test fails the moment someone adds a script to scripts/ without
# classifying it in install.sh, rather than only when a maintainer remembers
# to update this file too.

extract_list() {
    local list_name="$1"
    awk -v name="$list_name" '
        $0 == name"=(" { grabbing=1; next }
        grabbing && $0 ~ /^\)/ { grabbing=0; next }
        grabbing {
            line = $0
            sub(/#.*/, "", line)
            gsub(/^[ \t]+/, "", line)
            gsub(/[ \t]+$/, "", line)
            if (line != "") print line
        }
    ' "$repo_dir/install.sh"
}

mapfile -t porcelain < <(extract_list PORCELAIN)
mapfile -t plumbing < <(extract_list PLUMBING)

in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

echo "== list extraction sanity =="
if (( ${#porcelain[@]} > 0 )); then ok "PORCELAIN parsed from install.sh (${#porcelain[@]} names)"; else no "PORCELAIN parsed from install.sh" "got zero names"; fi
if (( ${#plumbing[@]} > 0 )); then ok "PLUMBING parsed from install.sh (${#plumbing[@]} names)"; else no "PLUMBING parsed from install.sh" "got zero names"; fi

# --- Case 1: every regular file in scripts/ is in exactly one list ----------

actual_scripts=()
for f in "$repo_dir"/scripts/*; do
    [[ -f "$f" ]] || continue
    actual_scripts+=("$(basename "$f")")
done

echo "== every scripts/ file is classified exactly once =="
for name in "${actual_scripts[@]}"; do
    in_p=0; in_l=0
    in_list "$name" "${porcelain[@]}" && in_p=1
    in_list "$name" "${plumbing[@]}" && in_l=1
    if (( in_p + in_l == 1 )); then
        ok "$name is classified exactly once"
    elif (( in_p + in_l == 0 )); then
        no "$name is classified exactly once" "not in PORCELAIN or PLUMBING"
    else
        no "$name is classified exactly once" "in both PORCELAIN and PLUMBING"
    fi
done

# --- Case 2: every listed name exists in scripts/ ---------------------------

echo "== every classified name exists in scripts/ =="
for name in "${porcelain[@]}" "${plumbing[@]}"; do
    if [[ -e "$repo_dir/scripts/$name" ]]; then
        ok "$name exists in scripts/"
    else
        no "$name exists in scripts/" "listed in install.sh but not present in scripts/"
    fi
done

# --- Case 10: the four load-bearing porcelain names, before anything else
# risks masking their absence behind a green run of the cases above.

echo "== load-bearing porcelain names are protected =="
for name in ensure-scratch-dirs.sh sandbox-run-log.py claude-sandboxed agent-sandboxed; do
    if in_list "$name" "${porcelain[@]}"; then
        ok "$name stays in PORCELAIN (regression guard: it is reached by bare name or hardcoded path, not script_dir)"
    else
        no "$name stays in PORCELAIN" "$name must be in PORCELAIN — it is reached by a bare-name hook invocation or a hardcoded \$HOME/.claude/scripts path, not script_dir, so unlinking it silently breaks a running machine"
    fi
done

run_install() {
    local home_dir="$1"
    shift
    HOME="$home_dir" "$repo_dir/install.sh" "$@" >/dev/null 2>&1
}

resolved_source() {
    # install.sh links straight from $REPO_DIR/scripts, not a resolved path.
    printf '%s/scripts/%s' "$repo_dir" "$1"
}

# --- Case 3 & 4: a clean install links exactly the porcelain names ----------

echo "== clean install links porcelain, and only porcelain =="
clean_home="$scratch/clean-home"
mkdir -p "$clean_home"
run_install "$clean_home"
clean_scripts="$clean_home/.claude/scripts"

for name in "${porcelain[@]}"; do
    target="$clean_scripts/$name"
    if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$(resolved_source "$name")")" ]]; then
        ok "$name is linked"
    else
        no "$name is linked" "expected a symlink at $target resolving into scripts/"
    fi
done

for name in "${plumbing[@]}"; do
    if [[ -e "$clean_scripts/$name" ]]; then
        no "$name is not linked" "found $clean_scripts/$name but it is plumbing"
    else
        ok "$name is not linked"
    fi
done

# --- Case 5: __pycache__ is skipped, and does not trip fail-closed ----------
#
# Build in a fixture copy so this never depends on (or creates) a real
# __pycache__ next to the scripts this suite is otherwise reading.

echo "== __pycache__ is ignored, not reported unclassified =="
fixture_repo="$scratch/fixture-repo"
mkdir -p "$fixture_repo"
cp -a "$repo_dir/scripts" "$fixture_repo/scripts"
cp "$repo_dir/install.sh" "$fixture_repo/install.sh"
mkdir -p "$fixture_repo/scripts/__pycache__"
touch "$fixture_repo/scripts/__pycache__/module.cpython-312.pyc"

pycache_home="$scratch/pycache-home"
mkdir -p "$pycache_home"
pycache_output="$(HOME="$pycache_home" "$fixture_repo/install.sh" 2>&1)"
pycache_rc=$?
if [[ "$pycache_rc" == 0 ]]; then ok "install with __pycache__ present exits 0"; else no "install with __pycache__ present exits 0" "got rc=$pycache_rc: $pycache_output"; fi
case "$pycache_output" in
    *__pycache__*) no "__pycache__ is not reported as unclassified" "found a mention of __pycache__ in output: $pycache_output" ;;
    *) ok "__pycache__ is not reported as unclassified" ;;
esac
if [[ -e "$pycache_home/.claude/scripts/__pycache__" ]]; then
    no "__pycache__ is not linked" "found $pycache_home/.claude/scripts/__pycache__"
else
    ok "__pycache__ is not linked"
fi

# --- Case 6 & 7: pruning removes only links this repo made ------------------

echo "== pruning removes only links this repo made for plumbing names =="
prune_home="$scratch/prune-home"
prune_scripts="$prune_home/.claude/scripts"
mkdir -p "$prune_scripts"

owned_plumbing_name="${plumbing[0]}"
ln -s "$(resolved_source "$owned_plumbing_name")" "$prune_scripts/$owned_plumbing_name"

outside_dir="$scratch/outside"
mkdir -p "$outside_dir"
touch "$outside_dir/$owned_plumbing_name.decoy"
foreign_plumbing_name="${plumbing[1]}"
ln -s "$outside_dir/$owned_plumbing_name.decoy" "$prune_scripts/$foreign_plumbing_name"

run_install "$prune_home"

if [[ -e "$prune_scripts/$owned_plumbing_name" ]]; then
    no "a stale link into this repo's scripts/ is pruned" "$prune_scripts/$owned_plumbing_name still exists"
else
    ok "a stale link into this repo's scripts/ is pruned"
fi

if [[ -L "$prune_scripts/$foreign_plumbing_name" ]] && [[ "$(readlink "$prune_scripts/$foreign_plumbing_name")" == "$outside_dir/$owned_plumbing_name.decoy" ]]; then
    ok "a link resolving outside this repo survives pruning, even named as plumbing"
else
    no "a link resolving outside this repo survives pruning, even named as plumbing" "expected $prune_scripts/$foreign_plumbing_name to still point at $outside_dir/$owned_plumbing_name.decoy"
fi

# --- Case 8: a regular file occupying a porcelain name is left alone -------

echo "== a regular file occupying a porcelain name is never touched =="
regfile_home="$scratch/regfile-home"
regfile_scripts="$regfile_home/.claude/scripts"
mkdir -p "$regfile_scripts"
porcelain_name="${porcelain[0]}"
printf 'not a symlink\n' > "$regfile_scripts/$porcelain_name"

regfile_output="$(HOME="$regfile_home" "$repo_dir/install.sh" 2>&1)"

if [[ -f "$regfile_scripts/$porcelain_name" ]] && [[ ! -L "$regfile_scripts/$porcelain_name" ]] && [[ "$(cat "$regfile_scripts/$porcelain_name")" == "not a symlink" ]]; then
    ok "the regular file at a porcelain name survives untouched"
else
    no "the regular file at a porcelain name survives untouched" "expected an unmodified regular file at $regfile_scripts/$porcelain_name"
fi
contains "the not-a-symlink warning is printed" "$porcelain_name: WARNING" "$regfile_output"

# --- Case 9: --check creates, updates and removes nothing -------------------

echo "== --check touches no links =="

check_clean_home="$scratch/check-clean-home"
mkdir -p "$check_clean_home"
run_install "$check_clean_home" --check
if [[ -e "$check_clean_home/.claude/scripts" ]]; then
    no "--check on a clean directory creates nothing" "$check_clean_home/.claude/scripts exists"
else
    ok "--check on a clean directory creates nothing"
fi

check_stale_home="$scratch/check-stale-home"
check_stale_scripts="$check_stale_home/.claude/scripts"
mkdir -p "$check_stale_scripts"
stale_plumbing_name="${plumbing[2]}"
ln -s "$(resolved_source "$stale_plumbing_name")" "$check_stale_scripts/$stale_plumbing_name"
before_listing="$(ls -la "$check_stale_scripts")"
run_install "$check_stale_home" --check
after_listing="$(ls -la "$check_stale_scripts")"
if [[ "$before_listing" == "$after_listing" ]]; then
    ok "--check on a directory with a stale plumbing link removes nothing"
else
    no "--check on a directory with a stale plumbing link removes nothing" "directory listing changed under --check"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
