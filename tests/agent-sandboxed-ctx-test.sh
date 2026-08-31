#!/usr/bin/env bash
# Exercise agent-sandboxed's context-window probe without starting a sandbox.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
agent="$repo_dir/scripts/agent-sandboxed"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }
check() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        no "$1" "expected $2, got $3"
    fi
}

work="$(mktemp -d)"; tmpdirs+=("$work")
bin="$work/bin"; mkdir "$bin"
ln -s "$(command -v node)" "$bin/node"
cat > "$bin/pi" <<'PI'
#!/usr/bin/env bash
exit 0
PI
chmod +x "$bin/pi"
cat > "$bin/sandbox-backend-test" <<'BACKEND'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    printf 'toolchain=host\n'
    exit 0
fi
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == --bind-ro ]]; then
        j=$((i + 1))
        case "${!j}" in
            */pi-agent) cp -- "${!j}/models.json" "$CTX_CAPTURE"; break ;;
        esac
    fi
done
exit 0
BACKEND
chmod +x "$bin/sandbox-backend-test"

cat > "$work/server.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
mode, port_file = sys.argv[1], sys.argv[2]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == '/v1/models':
            body = {'data': [{'id': 'test-model'}]}
            if mode == 'models': body['data'][0]['max_model_len'] = 20000
            raw = json.dumps(body).encode()
        elif self.path == '/props':
            if mode == 'props': raw = json.dumps({'default_generation_settings': {'n_ctx': 12000}}).encode()
            elif mode == 'malformed': raw = b'{not json'
            elif mode == 'timeout': time.sleep(3); raw = b'{}'
            else: raw = b'{}'
        else: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)
server = HTTPServer(('127.0.0.1', 0), Handler)
open(port_file, 'w').write(str(server.server_address[1]))
server.serve_forever()
PY

run_case() {
    local name="$1" mode="$2" config_ctx="$3" expected="$4"
    local port_file="$work/$name.port" capture="$work/$name.models.json" server_pid rc
    : > "$capture"
    if [[ -n "$config_ctx" ]]; then printf 'MODEL_CTX=%s\n' "$config_ctx" > "$work/model.env"; else : > "$work/model.env"; fi
    python3 "$work/server.py" "$mode" "$port_file" & server_pid=$!
    for _ in $(seq 1 50); do [[ -s "$port_file" ]] && break; sleep 0.02; done
    out="$(PATH="$bin:$PATH" FORK_SANDBOX_BACKEND=test FORK_SANDBOX_CONFIG_DIR="$work" \
        AGENT_SANDBOXED_PROPS_TIMEOUT=1 \
        CTX_CAPTURE="$capture" timeout 8 "$agent" --endpoint "http://127.0.0.1:$(cat "$port_file")/v1" \
        --model test-model "$work/project" 2>&1)"
    rc=$?
    kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null
    if (( rc != 0 )); then no "$name exits successfully" "$out"; return; fi
    if [[ -s "$capture" ]]; then
        check "$name computes MAX_TOKENS" "$expected" "$(jq -r '.providers.local.models[0].maxTokens' "$capture")"
    else
        no "$name exposes generated model settings"
    fi
}

run_case "MODEL_CTX pin wins" models 10000 2500
run_case "max_model_len wins over props" models "" 5000
run_case "props supplies context" props "" 3000
run_case "both absent uses fallback" absent "" 8192
run_case "malformed props uses fallback" malformed "" 8192
run_case "props timeout uses fallback" timeout "" 8192

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
