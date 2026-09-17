#!/usr/bin/env bash
# fork-sandbox-attach-dir-test.sh -- --attach-dir binds a directory read-only
# at /attachments, the LLM-seat counterpart of the handler path's
# FS_HANDLER_ATTACH_DIR. Sits beside fork-sandbox-clone-dir-test.sh and
# fork-sandbox-fixtures-test.sh, the other directory-bind/host-flag suites.
#
# Usage: tests/fork-sandbox-attach-dir-test.sh
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
export FORK_SANDBOX_RUN_SOURCE=test

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

# Keep the backend separator in the assertion: an agent argument after -- is
# not evidence that the backend received a launcher flag.
argv_has_flag_value() {
    awk -v flag="$2" -v value="$3" '
        $0 == "--" { after = 1 }
        !after && prev == flag && $0 == value { found = 1 }
        { prev = $0 }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

work="$(mktemp -d /var/tmp/claude-scratch/forks/fs-attach-dir-test.XXXXXX)"; tmpdirs+=("$work")
home="$work/home"; mkdir -p "$home/src" "$work/bin" "$work/config"
project="$home/src/project"; mkdir "$project"
git -C "$project" init -q
git -C "$project" -c user.name=Test -c user.email=test@fork-sandbox.invalid commit --allow-empty -qm init
handoff="/var/tmp/claude-scratch/fs-attach-dir-handoff-$$.md"; tmpdirs+=("$handoff")
printf 'test attach-dir\n' > "$handoff"

ln -s "$repo_dir/scripts/agent-sandboxed" "$work/bin/agent-sandboxed"
cat > "$work/bin/pi" <<'STUB'
process.exit(0);
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"fixture-model"}]}'
STUB
cat > "$work/bin/sandbox-backend-test" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then printf 'toolchain=host\n'; exit 0; fi
printf '%s\n' "$@" > "$FIXTURE_ARGV"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
[[ $# -eq 0 ]] || { shift; "$@"; }
STUB
chmod +x "$work/bin/pi" "$work/bin/curl" "$work/bin/sandbox-backend-test"
printf 'MODEL_ENDPOINT=http://127.0.0.1:8080/v1\n' > "$work/config/model.env"

run_launcher() {
    local attach_arg="$1" capture="$2"; shift 2
    local -a args=(--foreground --harness pi-local)
    [[ -z "$attach_arg" ]] || args+=(--attach-dir "$attach_arg")
    HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" \
        FORK_SANDBOX_RUN_SOURCE=test FORK_SANDBOX_BACKEND=test FIXTURE_ARGV="$capture" \
        timeout 30 "$launcher" "${args[@]}" "$@" "$project" "$handoff" 2>&1
}

printf '== --attach-dir binds the directory read-only at /attachments ==\n'

attach="$(mktemp -d /var/tmp/claude-scratch/fs-attach-dir-real.XXXXXX)"; tmpdirs+=("$attach")
printf 'a fixture attachment\n' > "$attach/file.txt"
capture="$work/backend-argv"
out="$(run_launcher "$attach" "$capture")"; rc=$?
if (( rc == 0 )) && argv_has_flag_value "$capture" --bind-ro-at "$attach"; then
    if awk -v src="$attach" '$0 == "--bind-ro-at" { getline; if ($0 == src) { getline; if ($0 == "/attachments") found = 1 } } END { exit(!found) }' "$capture"; then
        ok "--attach-dir binds the requested directory read-only at /attachments"
    else
        no "--attach-dir binds the requested directory read-only at /attachments" "$(cat "$capture")"
    fi
else
    no "--attach-dir binds the requested directory read-only at /attachments" "$out"
fi

printf '\n== --attach-dir refusals ==\n'

outside="$(mktemp -d)"; tmpdirs+=("$outside")
out="$(run_launcher "$outside" "$work/outside-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"must name a directory under"* && "$out" == *"$outside"* ]]; then
    ok "attach directory outside the scratch root is refused"
else
    no "attach directory outside the scratch root is refused" "$out"
fi

# --attach-dir shares fs_validate_scratch_dir with --session-state and
# --clone-dir, which refuse ANY symlink outright, before ever resolving
# where it points (see fs_validate_scratch_dir's own comment: a symlink
# checked here and resolved later is a different directory from the one
# that gets used) -- so this is refused for being a symlink at all, not
# specifically for escaping the scratch root.
escaped="$attach/escaped-attach"; ln -s "$outside" "$escaped"; tmpdirs+=("$escaped")
out="$(run_launcher "$escaped" "$work/escaped-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"is a symlink"* && "$out" == *"$escaped"* ]]; then
    ok "attach-dir symlink is refused outright, not resolved and boundary-checked"
else
    no "attach-dir symlink is refused outright, not resolved and boundary-checked" "$out"
fi

missing="$attach/no-such-dir"
out="$(run_launcher "$missing" "$work/missing-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$missing"* && "$out" == *"does not exist"* ]]; then
    ok "missing attach directory is refused by name"
else
    no "missing attach directory is refused by name" "$out"
fi

file="$attach/file.txt"
out="$(run_launcher "$file" "$work/file-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$file"* && "$out" == *"not a directory"* ]]; then
    ok "attach-dir naming a plain file is refused"
else
    no "attach-dir naming a plain file is refused" "$out"
fi

out="$(run_launcher "$attach" "$work/k8s-argv" --k8s --model vendor/model)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"not supported with --k8s"* ]]; then
    ok "--attach-dir refused with --k8s"
else
    no "--attach-dir refused with --k8s" "$out"
fi

plain="$work/plain-argv"
out="$(run_launcher "" "$plain")"; rc=$?
if (( rc == 0 )) && ! grep -qx -- '/attachments' "$plain"; then
    ok "absent --attach-dir adds no bind"
else
    no "absent --attach-dir adds no bind" "${out:-$(cat "$plain" 2>/dev/null)}"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
