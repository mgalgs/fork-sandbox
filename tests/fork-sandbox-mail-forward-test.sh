#!/usr/bin/env bash
# fork-sandbox-mail-forward-test.sh -- Exercise team access to the cluster mail
# API: `fork-sandbox mail-forward --setup`, and `mail --remote` setting itself
# up from it (fork-sandbox-mail-forward.py, fork-sandbox-mail-remote.py).
#
# Usage: tests/fork-sandbox-mail-forward-test.sh
#
# A real API server runs on loopback with a team-token hash beside its tokens
# file, as the cluster's does. A stub `kubectl` on PATH stands in for the
# cluster: `get secret` answers with the team token, and `port-forward` runs a
# small TCP relay to the server, like the real one, until it is killed. Every
# stub call is logged, so the tests can count forwards, check that every call
# carries --context, and look for the token anywhere it should not be. No
# cluster, no network beyond loopback, no tmux. Everything started here is
# stopped on exit.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
disp="$repo_dir/scripts/fork-sandbox"
api="$repo_dir/scripts/fork-sandbox-mail-api.py"
fwd="$repo_dir/scripts/fork-sandbox-mail-forward.py"

pass=0
fail=0
tmpdirs=()
pids=()

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}
contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "'$3' not found in: $2" ;; esac
}
lacks() {
    case "$2" in *"$3"*) no "$1" "'$3' found in: $2" ;; *) ok "$1" ;; esac
}

work="$(mktemp -d)"
tmpdirs+=("$work")
export HOME="$work/home"
mkdir -p "$HOME"
export FORK_SANDBOX_CONFIG_DIR="$work/config"
export XDG_STATE_HOME="$work/state"
export FORK_SANDBOX_MAIL_ROOT="$work/mailroot"
export STUB_LOG="$work/kubectl.log"
export STUB_TOKEN_FILE="$work/secrets/team-token"
export FORK_SANDBOX_MAIL_API_RETRY_SECONDS=30
mkdir -p "$FORK_SANDBOX_CONFIG_DIR" "$work/secrets" "$work/bin"
: > "$STUB_LOG"
unset FORK_SANDBOX_MAIL_API_URL FORK_SANDBOX_MAIL_API_TOKEN_FILE K8S_MAIL_API_URL K8S_MAIL_API_TOKEN_FILE

cleanup() {
    local p d
    PATH="$work/bin:$PATH" "$fwd" --stop >/dev/null 2>&1
    for p in "${pids[@]-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done
}
trap cleanup EXIT

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
wait_port() {
    local _
    for _ in $(seq 100); do
        python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

# The server: the team token's hash beside the tokens file, as in the pod.
mkdir -p "$work/api"
"$api" mint --role operator --label team | sed -n 1p > "$STUB_TOKEN_FILE"
team_token="$(cat "$STUB_TOKEN_FILE")"
printf '%s' "$team_token" | sha256sum | cut -d' ' -f1 > "$work/api/team-token-sha256"
"$api" mint --role operator --label laptop > "$work/laptop.mint"
sed -n 1p "$work/laptop.mint" > "$work/laptop-token"
sed -n 2p "$work/laptop.mint" > "$work/api/tokens"
backend_port="$(free_port)"
"$api" serve --tokens "$work/api/tokens" --listen "127.0.0.1:$backend_port" 2> "$work/server.log" &
pids+=("$!")
wait_port "$backend_port" || { echo "the API server did not start" >&2; exit 1; }

cat > "$work/relay.py" <<'PY'
import socket, sys, threading
backend = int(sys.argv[1])
port = int(sys.argv[-1].split(":")[0])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", port))
except OSError:
    print("Unable to listen on port %d: address already in use" % port, flush=True)
    sys.exit(1)
srv.listen(16)
print("Forwarding from 127.0.0.1:%d -> 8080" % port, flush=True)

def pump(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

while True:
    c, _ = srv.accept()
    try:
        u = socket.create_connection(("127.0.0.1", backend), 5)
    except OSError:
        c.close()
        continue
    threading.Thread(target=pump, args=(c, u), daemon=True).start()
    threading.Thread(target=pump, args=(u, c), daemon=True).start()
PY

cat > "$work/bin/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_LOG"
has_ctx=false
for a in "\$@"; do [[ "\$a" == --context=* ]] && has_ctx=true; done
if ! \$has_ctx; then
    echo NOCONTEXT >> "\$STUB_LOG"
    echo "stub kubectl: no --context" >&2
    exit 99
fi
case " \$* " in
    *" get secret fork-sandbox-mail-api-team-token "*)
        if [[ -n "\${STUB_GET_RC:-}" ]]; then
            echo 'Error from server (Forbidden): secrets "fork-sandbox-mail-api-team-token" is forbidden' >&2
            exit "\$STUB_GET_RC"
        fi
        if [[ -f "\$STUB_WRONG_ONCE" ]]; then
            rm -f "\$STUB_WRONG_ONCE"
            printf 'not-the-token' | base64 -w0
            exit 0
        fi
        base64 -w0 < "\$STUB_TOKEN_FILE"
        ;;
    *" port-forward "*)
        echo FORWARD-START >> "\$STUB_LOG"
        if [[ -f "\$STUB_PF_FAIL_ONCE" ]]; then
            cat "\$STUB_PF_FAIL_ONCE"
            rm -f "\$STUB_PF_FAIL_ONCE"
            exit 1
        fi
        if [[ -n "\${STUB_PF_FAIL:-}" ]]; then
            echo "\$STUB_PF_FAIL"
            exit 1
        fi
        exec python3 "$work/relay.py" "$backend_port" "\$@"
        ;;
    *)
        echo "stub kubectl: unexpected call: \$*" >&2
        exit 98
        ;;
esac
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
export STUB_WRONG_ONCE="$work/wrong-once" STUB_PF_FAIL_ONCE="$work/pf-fail-once"

local_port="$(free_port)"
mailr() { "$disp" mail --remote "$@"; }
starts() { grep -c '^FORWARD-START$' "$STUB_LOG" || true; }
relays() { pgrep -f "relay.py $backend_port .*port-forward.* $local_port:80" | wc -l; }
reset_log() { : > "$STUB_LOG"; }

printf '== help and dispatch ==\n'
check "the dispatcher reaches the script: --help" "0" "$("$disp" mail-forward --help >/dev/null; echo $?)"
contains "--help says what setup records" "$("$disp" mail-forward --help)" "the kube CONTEXT"
check "no arguments: exit 2" "2" "$("$disp" mail-forward >/dev/null 2>&1; echo $?)"
check "an unknown option: exit 2" "2" "$("$disp" mail-forward --frobnicate >/dev/null 2>&1; echo $?)"

printf '== before setup ==\n'
out="$(mailr list 2>&1)"; rc=$?
check "mail --remote with no config and no setup: exit 2" "2" "$rc"
contains "... names the explicit settings" "$out" "K8S_MAIL_API_URL"
contains "... and points at mail-forward --setup" "$out" "mail-forward --setup"
check "... and ran no kubectl" "" "$(cat "$STUB_LOG")"
check "--status before setup: exit 2" "2" "$("$disp" mail-forward --status >/dev/null 2>&1; echo $?)"
contains "--status before setup says how to set up" "$("$disp" mail-forward --status 2>&1)" "--setup"

printf '== setup ==\n'
out="$("$disp" mail-forward --setup --namespace ns-one --name @alice 2>&1)"; rc=$?
check "setup without --context: exit 2" "2" "$rc"
contains "... says the context is never taken from the kubeconfig" "$out" "never taken from your kubeconfig"
check "... and writes nothing" "no" "$([[ -e "$FORK_SANDBOX_CONFIG_DIR/mail-team.env" ]] && echo yes || echo no)"
check "setup without --namespace: exit 2" "2" \
    "$("$disp" mail-forward --setup --context ctx --name @alice >/dev/null 2>&1; echo $?)"
check "setup without --name: exit 2" "2" \
    "$("$disp" mail-forward --setup --context ctx --namespace ns-one >/dev/null 2>&1; echo $?)"
check "setup with a name lacking @: exit 2" "2" \
    "$("$disp" mail-forward --setup --context test-ctx --namespace ns-one --name alice >/dev/null 2>&1; echo $?)"
check "setup with an upper-case name: exit 2" "2" \
    "$("$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @Alice >/dev/null 2>&1; echo $?)"
check "setup with a bad namespace: exit 2" "2" \
    "$("$disp" mail-forward --setup --context test-ctx --namespace 'Bad_NS' --name @alice >/dev/null 2>&1; echo $?)"
check "setup with an option-looking context: exit 2" "2" \
    "$("$disp" mail-forward --setup --context --all-namespaces --namespace ns-one --name @alice >/dev/null 2>&1; echo $?)"
check "setup with a low port: exit 2" "2" \
    "$("$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @alice --port 80 >/dev/null 2>&1; echo $?)"
check "setup with an unknown option: exit 2" "2" \
    "$("$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @alice --bogus >/dev/null 2>&1; echo $?)"
check "none of those ran kubectl" "" "$(cat "$STUB_LOG")"

STUB_GET_RC=1 "$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @alice --port "$local_port" > "$work/out" 2> "$work/err"; rc=$?
check "setup whose credentials cannot read the token: exit 2" "2" "$rc"
contains "... says what failed" "$(cat "$work/err")" "cannot read the team token"
contains "... with kubectl's own words" "$(cat "$work/err")" "forbidden"
check "... and writes nothing" "no" "$([[ -e "$FORK_SANDBOX_CONFIG_DIR/mail-team.env" ]] && echo yes || echo no)"
reset_log

"$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @alice --port "$local_port" > "$work/out" 2> "$work/err"; rc=$?
check "setup: exit 0" "0" "$rc"
contains "setup: reports what it recorded" "$(cat "$work/out")" "set up as @alice: context test-ctx, namespace ns-one"
cfg="$FORK_SANDBOX_CONFIG_DIR/mail-team.env"
check "setup writes MAIL_TEAM_CONTEXT" "MAIL_TEAM_CONTEXT=test-ctx" "$(grep '^MAIL_TEAM_CONTEXT=' "$cfg")"
check "setup writes MAIL_TEAM_NAMESPACE" "MAIL_TEAM_NAMESPACE=ns-one" "$(grep '^MAIL_TEAM_NAMESPACE=' "$cfg")"
check "setup writes MAIL_TEAM_NAME" "MAIL_TEAM_NAME=@alice" "$(grep '^MAIL_TEAM_NAME=' "$cfg")"
check "setup writes MAIL_TEAM_LOCAL_PORT" "MAIL_TEAM_LOCAL_PORT=$local_port" "$(grep '^MAIL_TEAM_LOCAL_PORT=' "$cfg")"
check "setup's verify read the token once, with the context" "1" \
    "$(grep -c -- '^--context=test-ctx --namespace=ns-one get secret fork-sandbox-mail-api-team-token ' "$STUB_LOG")"
check "setup started no forward" "0" "$(starts)"
check "the setup file holds no token" "0" "$(grep -cF -- "$team_token" "$cfg")"
reset_log
"$disp" mail-forward --setup --context test-ctx --namespace ns-one --name @alice --port "$local_port" --no-verify >/dev/null 2>&1
check "setup --no-verify runs no kubectl" "" "$(cat "$STUB_LOG")"

printf '== mail --remote sets itself up ==\n'
reset_log
msgid="$(mailr send --to @reviewer --subject "team hello" --body - <<< "first message" 2> "$work/err")"; rc=$?
check "the first send: exit 0" "0" "$rc"
check "... it printed a message id" "1" "$([[ "$msgid" =~ ^[0-9a-f-]{36}$ ]] && echo 1 || echo 0)"
check "... one forward was started" "1" "$(starts)"
check "... and one relay is running" "1" "$(relays)"
check "... the token was read once" "1" "$(grep -c ' get secret fork-sandbox-mail-api-team-token ' "$STUB_LOG")"
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "mail --remote tree: exit 0" "0" "$rc"
contains "... shows the thread" "$out" "team hello"
check "... reused the forward: still one start" "1" "$(starts)"
check "... still one relay" "1" "$(relays)"
mailr list >/dev/null 2>&1; mailr show "$msgid" >/dev/null 2>&1
check "more calls: still one start" "1" "$(starts)"
check "more calls: the token is read once per call (4 calls)" "4" "$(grep -c ' get secret fork-sandbox-mail-api-team-token ' "$STUB_LOG")"
out="$("$disp" postmaster --remote status 2>&1)"; rc=$?
check "postmaster --remote status goes through the same path: exit 0" "0" "$rc"
check "... and reuses the forward" "1" "$(starts)"
out="$("$disp" mail-forward --status 2>&1)"; rc=$?
check "--status while running: exit 0" "0" "$rc"
contains "--status names the port and context" "$out" "127.0.0.1:$local_port (context test-ctx, namespace ns-one)"

printf '== the forward listens on loopback only, and the state holds no token ==\n'
check "the relay was asked for 127.0.0.1" "1" "$(grep -c -- "--address 127.0.0.1 $local_port:80" "$STUB_LOG" | awk '{print ($1 >= 1) ? 1 : 0}')"
check "the forward targets the mail API Service" "1" "$(grep -c 'port-forward svc/fork-sandbox-mail-api ' "$STUB_LOG" | awk '{print ($1 >= 1) ? 1 : 0}')"
leaks="$(grep -rlF -- "$team_token" "$HOME" "$FORK_SANDBOX_CONFIG_DIR" "$XDG_STATE_HOME" 2>/dev/null | tr '\n' ' ')"
check "no file the client wrote holds the team token" "" "$leaks"
check "... nor its hash" "0" "$(grep -rlF -- "$(cat "$work/api/team-token-sha256")" "$HOME" "$FORK_SANDBOX_CONFIG_DIR" "$XDG_STATE_HOME" 2>/dev/null | wc -l)"
check "no kubectl argument holds the token" "0" "$(grep -cF -- "$team_token" "$STUB_LOG")"
check "the state dir holds only the pid file, the lock and the log" "forward.json forward.lock forward.log" \
    "$(find "$XDG_STATE_HOME/fork-sandbox/mail-forward" -type f -printf '%f\n' | sort | paste -sd' ')"

printf '== --from ==\n'
id2="$(mailr send --to @reviewer --subject "default from" --body - <<< "no --from given" 2>/dev/null)"; rc=$?
check "send with no --from: exit 0" "0" "$rc"
contains "... was sent as the configured @name" "$(mailr show "$id2" 2>&1)" "From: @alice"
id3="$(mailr send --from @bob --to @reviewer --subject "explicit from" --body - <<< "explicit" 2>/dev/null)"
contains "an explicit --from wins" "$(mailr show "$id3" 2>&1)" "From: @bob"
id4="$(mailr send --from @operator --to @reviewer --subject "as operator" --body - <<< "operator" 2>/dev/null)"; rc=$?
check "--from @operator works with the team token: exit 0" "0" "$rc"
contains "... and is sent as @operator" "$(mailr show "$id4" 2>&1)" "From: @operator"
id5="$(mailr reply --reply-to "$id2" --to @reviewer --body - <<< "reply with no --from" 2>/dev/null)"; rc=$?
check "reply with no --from: exit 0" "0" "$rc"
contains "... was sent as the configured @name" "$(mailr show "$id5" 2>&1)" "From: @alice"
id6="$(mailr send --to @reviewer --subject "value that reads --from" --header "X-Note: --from" --body - <<< "tricky" 2>/dev/null)"
contains "a value that reads like --from does not count as one" "$(mailr show "$id6" 2>&1)" "From: @alice"
check "the forward was never restarted by any of that" "1" "$(starts)"

printf '== every kubectl carries --context ==\n'
check "no call lacked --context" "0" "$(grep -c '^NOCONTEXT$' "$STUB_LOG")"
check "every call names the configured context and namespace" "0" \
    "$(grep -v '^FORWARD-START$' "$STUB_LOG" | grep -vc '^--context=test-ctx --namespace=ns-one ')"
check "the client never asked kubectl for the current context" "0" "$(grep -c 'current-context' "$STUB_LOG")"

printf '== a dead forward is replaced ==\n'
pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$XDG_STATE_HOME/fork-sandbox/mail-forward/forward.json")"
kill -9 "$pid"
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
check "the relay is gone" "0" "$(relays)"
out="$("$disp" mail-forward --status 2>&1)"; rc=$?
check "--status after the forward died: exit 1" "1" "$rc"
contains "... says it is not running" "$out" "not running"
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "the next call after it died: exit 0" "0" "$rc"
contains "... and shows the thread" "$out" "team hello"
check "... a second forward was started" "2" "$(starts)"
check "... and exactly one relay is running" "1" "$(relays)"
new_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$XDG_STATE_HOME/fork-sandbox/mail-forward/forward.json")"
check "... the state names the new one" "1" "$([[ "$new_pid" != "$pid" ]] && kill -0 "$new_pid" 2>/dev/null && echo 1 || echo 0)"
# A forward whose pod was replaced is alive but answers nothing: stop the
# server's end by freezing the relay, and the next call replaces it.
kill -STOP "$new_pid"
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "a forward that is up but not answering is replaced: exit 0" "0" "$rc"
check "... a third forward was started" "3" "$(starts)"
check "... the frozen one is gone" "no" "$(kill -0 "$new_pid" 2>/dev/null && echo yes || echo no)"
check "... and exactly one relay is running" "1" "$(relays)"

printf '== concurrent first calls start one forward ==\n'
"$disp" mail-forward --stop >/dev/null 2>&1
check "--stop leaves no relay" "0" "$(relays)"
reset_log
par_pids=()
for i in 1 2 3 4 5; do
    mailr tree "$msgid" > "$work/par.$i" 2>&1 &
    par_pids+=("$!")
done
wait "${par_pids[@]}"
ok_n=0
for i in 1 2 3 4 5; do grep -q "team hello" "$work/par.$i" && ok_n=$(( ok_n + 1 )); done
check "five calls at once all succeed" "5" "$ok_n"
check "... and started exactly one forward" "1" "$(starts)"
check "... leaving exactly one relay" "1" "$(relays)"

printf '== --stop ==\n'
out="$("$disp" mail-forward --stop 2>&1)"
check "--stop reports it stopped one" "stopped" "$out"
check "... no relay is left" "0" "$(relays)"
check "--stop again: nothing to stop" "not running" "$("$disp" mail-forward --stop 2>&1)"
reset_log
mailr tree "$msgid" >/dev/null 2>&1
check "the next call starts it again" "1" "$(starts)"

printf '== explicit configuration wins ==\n'
reset_log
FORK_SANDBOX_MAIL_API_URL="http://127.0.0.1:$backend_port" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$work/laptop-token" \
    "$disp" mail --remote tree "$msgid" > "$work/out" 2>&1; rc=$?
check "an explicit URL and token: exit 0" "0" "$rc"
contains "... talks to that server" "$(cat "$work/out")" "team hello"
check "... without running kubectl at all" "" "$(cat "$STUB_LOG")"
FORK_SANDBOX_MAIL_API_URL="http://127.0.0.1:$backend_port" "$disp" mail --remote tree "$msgid" > "$work/out" 2>&1; rc=$?
check "an explicit URL and no token file: exit 2, not the team path" "2" "$rc"
contains "... names the token variable" "$(cat "$work/out")" "FORK_SANDBOX_MAIL_API_TOKEN_FILE"
check "... and ran no kubectl" "" "$(cat "$STUB_LOG")"
printf 'K8S_MAIL_API_URL=http://127.0.0.1:%s\nK8S_MAIL_API_TOKEN_FILE=%s\n' "$backend_port" "$work/laptop-token" > "$FORK_SANDBOX_CONFIG_DIR/k8s.env"
"$disp" mail --remote tree "$msgid" > "$work/out" 2>&1; rc=$?
check "explicit settings in k8s.env win too: exit 0" "0" "$rc"
check "... without running kubectl" "" "$(cat "$STUB_LOG")"
rm -f "$FORK_SANDBOX_CONFIG_DIR/k8s.env"

printf '== the token read ==\n'
touch "$STUB_WRONG_ONCE"
reset_log
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "a stale token (401) is read again once: exit 0" "0" "$rc"
contains "... and the call went through" "$out" "team hello"
check "... the token was read twice" "2" "$(grep -c ' get secret fork-sandbox-mail-api-team-token ' "$STUB_LOG")"
check "... no second forward" "0" "$(starts)"
printf 'not-the-token' > "$work/secrets/wrong-token"
cp "$STUB_TOKEN_FILE" "$work/secrets/good-token"
cp "$work/secrets/wrong-token" "$STUB_TOKEN_FILE"
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "a token the server never knew: exit 2" "2" "$rc"
contains "... says 401" "$out" "HTTP 401"
check "... one line" "1" "$(printf '%s\n' "$out" | wc -l)"
cp "$work/secrets/good-token" "$STUB_TOKEN_FILE"
reset_log
STUB_GET_RC=1 mailr tree "$msgid" > "$work/out" 2>&1; rc=$?
check "credentials that cannot read the token: exit 2" "2" "$rc"
contains "... says so" "$(cat "$work/out")" "cannot read the team token"
check "... one line, no retries" "1" "$(wc -l < "$work/out")"
check "... and started no forward" "0" "$(starts)"

printf '== the forward fails to start ==\n'
"$disp" mail-forward --stop >/dev/null 2>&1
reset_log
start_s="$SECONDS"
STUB_PF_FAIL='error: forbidden: User "alice" cannot create resource "pods/portforward"' mailr tree "$msgid" > "$work/out" 2>&1; rc=$?
check "a forbidden port-forward: exit 2" "2" "$rc"
contains "... says why" "$(cat "$work/out")" "forbidden"
check "... is not retried" "1" "$(starts)"
check "... and fails quickly" "1" "$(( SECONDS - start_s < 10 ? 1 : 0 ))"
reset_log
printf 'error: unable to forward port because pod is not running. Current status=Pending\n' > "$STUB_PF_FAIL_ONCE"
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "a pod that is not running yet is retried: exit 0" "0" "$rc"
contains "... the retry is announced" "$out" "retrying in"
contains "... and the call went through" "$out" "team hello"
check "... two forwards were started" "2" "$(starts)"
"$disp" mail-forward --stop >/dev/null 2>&1
blocker_port="$local_port"
python3 - "$blocker_port" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
PY
blocker=$!
pids+=("$blocker")
sleep 0.5
reset_log
out="$(mailr tree "$msgid" 2>&1)"; rc=$?
check "a local port held by something else: exit 2" "2" "$rc"
contains "... says the port is in use" "$out" "in use by something else"
contains "... and how to pick another" "$out" "--port"
check "... without a retry" "1" "$(starts)"
check "... and nothing was sent to the stranger (no relay of ours)" "0" "$(relays)"
kill "$blocker" 2>/dev/null; wait "$blocker" 2>/dev/null

printf '== a damaged setup ==\n'
printf 'MAIL_TEAM_CONTEXT=test-ctx\nMAIL_TEAM_NAMESPACE=ns-one\nMAIL_TEAM_NAME=nobody\nMAIL_TEAM_LOCAL_PORT=%s\n' "$local_port" > "$cfg"
reset_log
out="$(mailr list 2>&1)"; rc=$?
check "a setup file with a bad name: exit 2" "2" "$rc"
contains "... says the file is damaged" "$out" "is damaged"
check "... and ran no kubectl" "" "$(cat "$STUB_LOG")"
printf 'MAIL_TEAM_NAMESPACE=ns-one\nMAIL_TEAM_NAME=@alice\n' > "$cfg"
out="$(mailr list 2>&1)"; rc=$?
check "a setup file with no context: exit 2" "2" "$rc"
contains "... names the context" "$out" "context"
check "... and ran no kubectl (no fallback to the current context)" "" "$(cat "$STUB_LOG")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
