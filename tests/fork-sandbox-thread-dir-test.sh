#!/usr/bin/env bash
# fork-sandbox-thread-dir-test.sh -- --thread-dir binds a directory read-only
# at /thread, where a wake reads the rendered thread snapshot it was woken
# on. It is the sibling of --attach-dir: same validation, same read-only
# bind, a different mount point. Sits beside fork-sandbox-clone-dir-test.sh
# and fork-sandbox-fixtures-test.sh, the other directory-bind/host-flag
# suites.
#
# Usage: tests/fork-sandbox-thread-dir-test.sh
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

work="$(mktemp -d /var/tmp/claude-scratch/forks/fs-thread-dir-test.XXXXXX)"; tmpdirs+=("$work")
home="$work/home"; mkdir -p "$home/src" "$work/bin" "$work/config"
project="$home/src/project"; mkdir "$project"
git -C "$project" init -q
git -C "$project" -c user.name=Test -c user.email=test@fork-sandbox.invalid commit --allow-empty -qm init
handoff="/var/tmp/claude-scratch/fs-thread-dir-handoff-$$.md"; tmpdirs+=("$handoff")
printf 'test thread-dir\n' > "$handoff"

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
# A legacy k8s.env, so --k8s --dry-run below has an install to dispatch
# against; this is the same fixture shape tests/fork-sandbox-k8s-test.sh
# builds for its own config_dir.
cat > "$work/config/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF

run_launcher() {
    local attach_arg="$1" capture="$2"; shift 2
    local -a args=(--foreground --harness pi-local)
    [[ -z "$attach_arg" ]] || args+=(--thread-dir "$attach_arg")
    HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" \
        FORK_SANDBOX_RUN_SOURCE=test FORK_SANDBOX_BACKEND=test FIXTURE_ARGV="$capture" \
        timeout 30 "$launcher" "${args[@]}" "$@" "$project" "$handoff" 2>&1
}

printf '== --thread-dir binds the directory read-only at /thread ==\n'

attach="$(mktemp -d /var/tmp/claude-scratch/fs-thread-dir-real.XXXXXX)"; tmpdirs+=("$attach")
printf 'a fixture attachment\n' > "$attach/file.txt"
capture="$work/backend-argv"
out="$(run_launcher "$attach" "$capture")"; rc=$?
if (( rc == 0 )) && argv_has_flag_value "$capture" --bind-ro-at "$attach"; then
    if awk -v src="$attach" '$0 == "--bind-ro-at" { getline; if ($0 == src) { getline; if ($0 == "/thread") found = 1 } } END { exit(!found) }' "$capture"; then
        ok "--thread-dir binds the requested directory read-only at /thread"
    else
        no "--thread-dir binds the requested directory read-only at /thread" "$(cat "$capture")"
    fi
else
    no "--thread-dir binds the requested directory read-only at /thread" "$out"
fi

printf '\n== --thread-dir refusals ==\n'

outside="$(mktemp -d)"; tmpdirs+=("$outside")
out="$(run_launcher "$outside" "$work/outside-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"must name a directory under"* && "$out" == *"$outside"* ]]; then
    ok "thread directory outside the scratch root is refused"
else
    no "thread directory outside the scratch root is refused" "$out"
fi

# --thread-dir shares fs_validate_scratch_dir with --session-state and
# --clone-dir, which refuse ANY symlink outright, before ever resolving
# where it points (see fs_validate_scratch_dir's own comment: a symlink
# checked here and resolved later is a different directory from the one
# that gets used) -- so this is refused for being a symlink at all, not
# specifically for escaping the scratch root.
escaped="$attach/escaped-attach"; ln -s "$outside" "$escaped"; tmpdirs+=("$escaped")
out="$(run_launcher "$escaped" "$work/escaped-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"is a symlink"* && "$out" == *"$escaped"* ]]; then
    ok "thread-dir symlink is refused outright, not resolved and boundary-checked"
else
    no "thread-dir symlink is refused outright, not resolved and boundary-checked" "$out"
fi

missing="$attach/no-such-dir"
out="$(run_launcher "$missing" "$work/missing-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$missing"* && "$out" == *"does not exist"* ]]; then
    ok "missing thread directory is refused by name"
else
    no "missing thread directory is refused by name" "$out"
fi

file="$attach/file.txt"
out="$(run_launcher "$file" "$work/file-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$file"* && "$out" == *"not a directory"* ]]; then
    ok "thread-dir naming a plain file is refused"
else
    no "thread-dir naming a plain file is refused" "$out"
fi

# --thread-dir is forwarded, not refused, with --k8s: fork-sandbox-k8s.sh's
# own submit renders an emptyDir mount at /thread for it (see
# tests/fork-sandbox-k8s-test.sh's td_test_scratch_push). This dispatcher
# call must skip run_launcher's --harness pi-local (refused with --k8s) and
# needs the project/handoff fixtures directly, not through run_launcher's
# own arg-shape. A fresh directory, not $attach -- the refusal tests above
# grew a symlink inside it.
k8s_thread="$(mktemp -d /var/tmp/claude-scratch/fs-thread-dir-k8s.XXXXXX)"; tmpdirs+=("$k8s_thread")
printf 'thread.txt\n' > "$k8s_thread/thread.txt"
k8s_dry_run_out="$(HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" \
    FORK_SANDBOX_RUN_SOURCE=test \
    timeout 30 "$launcher" --k8s --dry-run --model moonshotai/kimi-k3 \
    --thread-dir "$k8s_thread" "$project" "$handoff" 2>&1)"; rc=$?
if (( rc == 0 )) && grep -qF 'mountPath: /thread' <<< "$k8s_dry_run_out"; then
    ok "--thread-dir is forwarded with --k8s, not refused"
else
    no "--thread-dir is forwarded with --k8s, not refused" "$k8s_dry_run_out"
fi

plain="$work/plain-argv"
out="$(run_launcher "" "$plain")"; rc=$?
if (( rc == 0 )) && ! grep -qx -- '/thread' "$plain"; then
    ok "absent --thread-dir adds no bind"
else
    no "absent --thread-dir adds no bind" "${out:-$(cat "$plain" 2>/dev/null)}"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
