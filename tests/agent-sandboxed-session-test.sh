#!/usr/bin/env bash
# Exercise agent-sandboxed's own --session-dir/--session-id flags: the
# durable-store bind and the argv pi actually receives, without starting a
# real sandbox backend or pi.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
agent="$repo_dir/scripts/agent-sandboxed"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

work="$(mktemp -d)"; tmpdirs+=("$work")
bin="$work/bin"; mkdir "$bin"
REAL_NODE="$(command -v node)"
cat > "$bin/node" <<'NODE'
#!/usr/bin/env bash
exec "$REAL_NODE" "$@"
NODE
chmod +x "$bin/node"
export REAL_NODE
cat > "$bin/pi" <<'PI'
#!/usr/bin/env bash
exit 0
PI
chmod +x "$bin/pi"
cat > "$bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"test-model"}]}'
CURL
chmod +x "$bin/curl"
# Captures the backend's full argv (BACKEND_CAPTURE, NUL-separated, same
# convention as agent-sandboxed-ctx-test.sh) and, when named, a copy of the
# generated shim.sh -- the one file that shows what pi is actually invoked
# with, since everything after the work dir is baked into it rather than
# passed to this stub directly.
cat > "$bin/sandbox-backend-test" <<'BACKEND'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    printf '%s\n' 'toolchain=host'
    exit 0
fi
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == --bind-ro ]]; then
        j=$((i + 1))
        case "${!j}" in
            */pi-agent) [[ -n "${CTX_CAPTURE:-}" ]] && cp -- "${!j}/models.json" "$CTX_CAPTURE" ;;
            */shim.sh) [[ -n "${SHIM_CAPTURE:-}" ]] && cp -- "${!j}" "$SHIM_CAPTURE" ;;
        esac
    fi
done
[[ -z "${BACKEND_CAPTURE:-}" ]] || printf '%s\0' "$@" > "$BACKEND_CAPTURE"
exit 0
BACKEND
chmod +x "$bin/sandbox-backend-test"

run_case() {
    local name="$1"; shift
    local capture="$work/$name.args" shim="$work/$name.shim.sh" out rc
    out="$(PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test FORK_SANDBOX_CONFIG_DIR="$work" \
        BACKEND_CAPTURE="$capture" SHIM_CAPTURE="$shim" timeout 8 "$agent" \
        --endpoint 'http://127.0.0.1:1/v1' --model test-model "$@" "$work/project-$name" 2>&1)"
    rc=$?
    printf '%s' "$out" > "$work/$name.out"
    return "$rc"
}

session_store="$work/durable-store"
if run_case "durable" --session-dir "$session_store" --session-id abc12345; then
    ok "durable run exits successfully"
else
    no "durable run exits successfully" "$(cat "$work/durable.out")"
fi
tr '\0' '\n' < "$work/durable.args" > "$work/durable.args.text" 2>/dev/null || : > "$work/durable.args.text"
if grep -qxF -- '--bind-rw-at' "$work/durable.args.text" && \
    grep -qxF -- "$session_store" "$work/durable.args.text" && \
    grep -qxF -- "$HOME/.pi/sessions" "$work/durable.args.text"; then
    ok "durable run binds the given directory read-write at \$HOME/.pi/sessions"
else
    no "durable run binds the given directory read-write at \$HOME/.pi/sessions" "$(cat "$work/durable.args.text")"
fi
if [[ -s "$work/durable.shim.sh" ]] && \
    grep -qF -- "--session-dir $HOME/.pi/sessions --session-id abc12345" "$work/durable.shim.sh"; then
    ok "durable run's shim carries --session-dir and --session-id for pi"
else
    no "durable run's shim carries --session-dir and --session-id for pi" "$(cat "$work/durable.shim.sh" 2>/dev/null)"
fi
if [[ -d "$session_store" ]]; then
    ok "durable run creates the given session directory"
else
    no "durable run creates the given session directory"
fi

if run_case "default"; then
    ok "default run (no --session-dir) exits successfully"
else
    no "default run (no --session-dir) exits successfully" "$(cat "$work/default.out")"
fi
tr '\0' '\n' < "$work/default.args" > "$work/default.args.text" 2>/dev/null || : > "$work/default.args.text"
if ! grep -qxF -- '--bind-rw-at' "$work/default.args.text"; then
    ok "default run adds no session bind"
else
    no "default run adds no session bind" "$(cat "$work/default.args.text")"
fi
if [[ -s "$work/default.shim.sh" ]] && \
    grep -qF -- "--session-dir $work/project-default/pi-sessions" "$work/default.shim.sh"; then
    ok "default run's shim keeps the work-dir-relative session dir"
else
    no "default run's shim keeps the work-dir-relative session dir" "$(cat "$work/default.shim.sh" 2>/dev/null)"
fi

out="$(PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test FORK_SANDBOX_CONFIG_DIR="$work" \
    timeout 8 "$agent" --endpoint 'http://127.0.0.1:1/v1' --model test-model \
    --session-id abc12345 "$work/project-idonly" 2>&1)"
rc=$?
if (( rc != 0 )) && [[ "$out" == *'--session-id requires --session-dir'* ]]; then
    ok "--session-id without --session-dir is refused"
else
    no "--session-id without --session-dir is refused" "$out"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
