#!/usr/bin/env bash
# fork-sandbox-mail-api-test.sh -- Exercise fork-sandbox-mail-api.py: the tokens
# file loader, mint, the auth rules, the verb allowlist and the size caps.
#
# Usage: tests/fork-sandbox-mail-api-test.sh
#
# Starts the server on 127.0.0.1 with an ephemeral port, a temp
# FORK_SANDBOX_MAIL_ROOT (the postmaster's state lives under it) and a tokens
# file made with `mint`. It is driven through the real client shim
# (`fork-sandbox mail --remote ...`) wherever the shim can express the case,
# and through a small raw HTTP helper for the malformed-request cases. No
# cluster, no network beyond loopback. The server is killed on exit.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
mail="$repo_dir/scripts/fork-sandbox-mail.sh"
pm="$repo_dir/scripts/fork-sandbox-postmaster.sh"
disp="$repo_dir/scripts/fork-sandbox"
api="$repo_dir/scripts/fork-sandbox-mail-api.py"

pass=0
fail=0
tmpdirs=()
server_pid=""

cleanup() {
    local d
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null
        wait "$server_pid" 2>/dev/null
    fi
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

lacks() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' found in: $haystack" ;;
        *) ok "$label" ;;
    esac
}

new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

work=""; new_root work
cd "$work" || exit 1
tok="$work/tokens"; mkdir -p "$tok"

# A raw HTTP client: one request, the status on stdout, the response body in
# $RESP. Options: --tool T, --stdin S, --stdin-file PATH, --file NAME=PATH (repeatable), --raw
# JSON (send this body as is), --claim-length N (send the headers only),
# --no-length, --method M, --path P, then `--` and the argv.
cat > "$work/xr.py" <<'PY'
import base64, http.client, json, os, sys

a = sys.argv[1:]
token_file = a.pop(0)
method, path, tool, stdin, raw = "POST", "/v1/exec", None, None, None
files, claim, no_length, argv = {}, None, False, []
while a:
    o = a.pop(0)
    if o == "--tool": tool = a.pop(0)
    elif o == "--stdin": stdin = a.pop(0)
    elif o == "--stdin-file": stdin = open(a.pop(0)).read()
    elif o == "--file":
        n, _, p = a.pop(0).partition("=")
        files[n] = open(p, "rb").read()
    elif o == "--raw": raw = a.pop(0).encode()
    elif o == "--claim-length": claim = a.pop(0)
    elif o == "--no-length": no_length = True
    elif o == "--method": method = a.pop(0)
    elif o == "--path": path = a.pop(0)
    elif o == "--": argv = a; break
if raw is None:
    req = {"tool": tool, "argv": argv}
    if stdin is not None:
        req["stdin_b64"] = base64.b64encode(stdin.encode()).decode()
    if files:
        req["files"] = {k: base64.b64encode(v).decode() for k, v in files.items()}
    raw = json.dumps(req).encode()
host, port = os.environ["API_HOSTPORT"].split(":")
conn = http.client.HTTPConnection(host, int(port), timeout=60)
conn.putrequest(method, path)
if token_file != "-":
    conn.putheader("Authorization", "Bearer " + open(token_file).read().strip())
if not no_length:
    conn.putheader("Content-Length", claim if claim is not None else str(len(raw)))
conn.endheaders()
if claim is None:
    conn.send(raw)
r = conn.getresponse()
open(os.environ["RESP"], "wb").write(r.read())
print(r.status)
PY
RESP="$work/resp"; export RESP

# Read one field of the last JSON response: rc, error, or the decoded
# stdout / stderr.
rjson() {
    python3 - "$RESP" "$1" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
k = sys.argv[2]
if k in ("stdout", "stderr"):
    sys.stdout.buffer.write(base64.b64decode(d[k + "_b64"]))
else:
    print(d.get(k, ""))
PY
}

xr() { python3 "$work/xr.py" "$@"; }

# Mint a token into $tok/<label>, and append its table line to $tokens_file.
mint_into() {
    local label="$1"; shift
    local out
    out="$("$api" mint --label "$label" "$@")" || return 1
    printf '%s\n' "$out" | sed -n 1p > "$tok/$label"
    printf '%s\n' "$out" | sed -n 2p >> "$tokens_file"
}

printf '== loader and mint ==\n'

good_hash="$(printf 'not a real token' | sha256sum | cut -d' ' -f1)"
other_hash="$(printf 'another one' | sha256sum | cut -d' ' -f1)"

refuses_tokens() {
    local label="$1" want="$2" content="$3" f="$work/refused.tokens" out rc
    printf '%s' "$content" > "$f"
    out="$(timeout 10 "$api" serve --tokens "$f" --listen 127.0.0.1:0 2>&1)"; rc=$?
    check "loader refuses $label: exit 2" "2" "$rc"
    contains "loader refuses $label: names it" "$out" "$want"
    lacks "loader refuses $label: no hash in the error" "$out" "$good_hash"
    lacks "loader refuses $label: no other hash in the error" "$out" "$other_hash"
    check "loader refuses $label: one line" "1" "$(printf '%s\n' "$out" | wc -l)"
}

refuses_tokens "a client with @operator" "opc" \
    "client $good_hash opc @operator read"$'\n'
refuses_tokens "a client with @operator among others" "opc2" \
    "client $good_hash opc2 @a,@operator -"$'\n'
refuses_tokens "a duplicate label" "dup" \
    "client $good_hash dup @a read"$'\n'"client $other_hash dup @b read"$'\n'
refuses_tokens "a shared hash" "two" \
    "client $good_hash one @a read"$'\n'"client $good_hash two @b read"$'\n'
refuses_tokens "an operator with caps" "opcaps" \
    "operator $good_hash opcaps - read"$'\n'
refuses_tokens "an operator with identities" "opid" \
    "operator $good_hash opid @a -"$'\n'
refuses_tokens "an unknown cap" "badcap" \
    "client $good_hash badcap @a read,write"$'\n'
refuses_tokens "an unknown role" "badrole" \
    "admin $good_hash badrole - -"$'\n'
refuses_tokens "a malformed identity" "badid" \
    "client $good_hash badid @A read"$'\n'
refuses_tokens "an identity with a trailing empty element" "trail" \
    "client $good_hash trail @a, read"$'\n'
refuses_tokens "a short line" "line 1" \
    "client $good_hash short @a"$'\n'
refuses_tokens "a short hash" "shorthash" \
    "client abcd shorthash @a read"$'\n'
refuses_tokens "an empty file" "no entries" ""
refuses_tokens "a comments-only file" "no entries" \
    "# nothing here"$'\n\n'

out="$(timeout 10 "$api" serve --tokens "$work/does-not-exist" --listen 127.0.0.1:0 2>&1)"; rc=$?
check "loader refuses a missing file: exit 2" "2" "$rc"

tokens_file="$work/tokens.table"
: > "$tokens_file"

out="$("$api" mint --role client --label bad --as @operator --caps read 2>&1)"; rc=$?
check "mint refuses a client with @operator: exit 2" "2" "$rc"
contains "mint refuses a client with @operator: says why" "$out" "@operator"
out="$("$api" mint --role operator --label bad --caps read 2>&1)"; rc=$?
check "mint refuses an operator with caps: exit 2" "2" "$rc"
out="$("$api" mint --role client --label bad --caps write 2>&1)"; rc=$?
check "mint refuses an unknown cap: exit 2" "2" "$rc"
out="$("$api" mint --role client --label 'has space' 2>&1)"; rc=$?
check "mint refuses a malformed label: exit 2" "2" "$rc"
out="$("$api" mint --role boss --label x 2>&1)"; rc=$?
check "mint refuses an unknown role: exit 2" "2" "$rc"

minted="$("$api" mint --role client --label shape --as @a,@b --caps read,seen)"
check "mint prints two lines" "2" "$(printf '%s\n' "$minted" | wc -l)"
minted_token="$(printf '%s\n' "$minted" | sed -n 1p)"
minted_line="$(printf '%s\n' "$minted" | sed -n 2p)"
check "mint: the first line is a bare token" "1" \
    "$([[ "$minted_token" =~ ^[A-Za-z0-9_-]{43}$ ]] && echo 1 || echo 0)"
check "mint: the table line has the token's sha256" \
    "client $(printf '%s' "$minted_token" | sha256sum | cut -d' ' -f1) shape @a,@b read,seen" \
    "$minted_line"
lacks "mint: the table line does not hold the token" "$minted_line" "$minted_token"
check "mint writes no file" "0" "$(find . -maxdepth 1 -name 'shape*' | wc -l)"
minted="$("$api" mint --role client --label bare)"
contains "mint: no identities and no caps are '-'" "$(printf '%s\n' "$minted" | sed -n 2p)" " bare - -"

printf '== server ==\n'

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
new_root FORK_SANDBOX_CONFIG_DIR; export FORK_SANDBOX_CONFIG_DIR

mint_into laptop --role operator
mint_into ci-kickoff --role client --as @ci-kickoff --caps read,grant
mint_into bot --role client --as @bot
mint_into reader --role client --as @reader --caps read,seen
printf '# a comment\n\n' | cat - "$tokens_file" > "$tokens_file.new" && mv "$tokens_file.new" "$tokens_file"

server_log="$work/server.log"
"$api" serve --tokens "$tokens_file" --listen 127.0.0.1:0 2> "$server_log" &
server_pid=$!
for _ in $(seq 100); do
    grep -q '^listening on ' "$server_log" && break
    sleep 0.1
done
listen="$(sed -n 's/^listening on //p' "$server_log" | head -n 1)"
if [[ -z "$listen" ]]; then
    no "the server started on 127.0.0.1" "$(cat "$server_log")"
    printf '\n%s passed, %s failed\n' "$pass" "$fail"
    exit 1
fi
ok "the server started on $listen"
export API_HOSTPORT="$listen"

printf 'nope\n' > "$tok/wrong"

printf '== 1. healthz and auth ==\n'

check "healthz: 200" "200" "$(xr - --method GET --path /healthz)"
check "healthz: body is ok" "ok" "$(cat "$RESP")"
check "no token: 401" "401" "$(xr - --tool mail -- list)"
check "no token: a JSON error" "missing or bad token" "$(rjson error)"
check "a wrong token: 401" "401" "$(xr "$tok/wrong" --tool mail -- list)"
check "an empty token: 401" "401" "$(printf '\n' > "$tok/empty"; xr "$tok/empty" --tool mail -- list)"
check "a valid token: 200" "200" "$(xr "$tok/laptop" --tool mail -- list)"
check "an unknown path: 404" "404" "$(xr "$tok/laptop" --method GET --path /v1/nope)"
check "GET /v1/exec: 405" "405" "$(xr "$tok/laptop" --method GET --path /v1/exec)"
check "POST /healthz: 405" "405" "$(xr - --path /healthz)"
check "DELETE /v1/exec: 405" "405" "$(xr "$tok/laptop" --method DELETE --path /v1/exec)"

printf '== 3. who may post as whom ==\n'

seed="$("$mail" send --from @seed --to @bob --subject "seed thread" --body - <<< "seed" 2>/dev/null)"
check "a seed thread exists" "1" "$([[ -n "$seed" ]] && echo 1 || echo 0)"

check "a client sends as @operator: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @operator --to @x --subject s --body -)"
check "a client sends as @someone-else: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @someone-else --to @x --subject s --body -)"
check "a client replies as @operator: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- reply --from @operator --reply-to "$seed" --body -)"
check "no thread was made by the refusals" "1" "$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -mindepth 1 -maxdepth 1 | wc -l)"
check "the operator sends as @operator: 200" "200" \
    "$(xr "$tok/laptop" --tool mail --stdin hi -- send --from @operator --to @x --subject s --body -)"
check "the operator's send ran: rc 0" "0" "$(rjson rc)"
check "the operator replies as @operator: rc 0" "0" \
    "$(xr "$tok/laptop" --tool mail --stdin hi -- reply --from @operator --reply-to "$seed" --body - >/dev/null; rjson rc)"
check "a client sends as itself: 200 rc 0" "0" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @ci-kickoff --to @x --subject s --body - >/dev/null; rjson rc)"
check "a client with no --from: passes through and MAIL refuses (rc 1)" "1" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --to @x --subject s --body - >/dev/null; rjson rc)"
check "--from given twice: 400" "400" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @ci-kickoff --from @operator --to @x --subject s --body -)"
check "--from=@operator form: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from=@operator --to @x --subject s --body -)"

printf '== 4. flag and unflag ==\n'

flag_file="$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$seed"
check "a client runs flag: 403" "403" "$(xr "$tok/ci-kickoff" --tool postmaster -- flag "$seed" why)"
check "a client runs unflag: 403" "403" "$(xr "$tok/ci-kickoff" --tool postmaster -- unflag "$seed")"
check "a reader with every other cap still gets 403 on flag" "403" "$(xr "$tok/reader" --tool postmaster -- flag "$seed")"
check "no flag file after the refusals" "0" "$([[ -e "$flag_file" ]] && echo 1 || echo 0)"
check "the operator runs flag: 200" "200" "$(xr "$tok/laptop" --tool postmaster -- flag "$seed" "stuck on CI")"
check "the operator's flag: rc 0" "0" "$(rjson rc)"
check "the flag file appears" "stuck on CI" "$(cat "$flag_file" 2>/dev/null)"
check "a client cannot clear it" "403" "$(xr "$tok/ci-kickoff" --tool postmaster -- unflag "$seed")"
check "the flag file is still there" "1" "$([[ -e "$flag_file" ]] && echo 1 || echo 0)"
seed_msgs="$(find "$FORK_SANDBOX_MAIL_ROOT/threads/$seed" -name '*.msg' | wc -l)"
seed_id="$(cd "$FORK_SANDBOX_MAIL_ROOT/threads/$seed" && grep -h -m1 '^Message-ID: ' -- *.msg | tail -n 1 | sed 's/^Message-ID: //')"
check "a client replies into the flagged thread: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- reply --from @ci-kickoff --reply-to "$seed_id" --body -)"
contains "... and the error says the thread is flagged" "$(rjson error)" "flagged"
check "no message was posted into the flagged thread" "$seed_msgs" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/threads/$seed" -name '*.msg' | wc -l)"
check "the flag file survives the client's reply" "stuck on CI" "$(cat "$flag_file" 2>/dev/null)"
check "the operator may still reply into the flagged thread" "0" \
    "$(xr "$tok/laptop" --tool mail --stdin hi -- reply --from @operator --reply-to "$seed_id" --body - >/dev/null; rjson rc)"
check "the operator runs unflag: rc 0" "0" "$(xr "$tok/laptop" --tool postmaster -- unflag "$seed" >/dev/null; rjson rc)"
check "the flag file clears" "0" "$([[ -e "$flag_file" ]] && echo 1 || echo 0)"
check "flag with no thread id: 400" "400" "$(xr "$tok/laptop" --tool postmaster -- flag)"
check "flag with three arguments: 400" "400" "$(xr "$tok/laptop" --tool postmaster -- flag a b c)"

printf '== 5. caps ==\n'

check "no caps: show is 403" "403" "$(xr "$tok/bot" --tool mail -- show "$seed")"
check "no caps: list is 403" "403" "$(xr "$tok/bot" --tool mail -- list)"
check "no caps: tree is 403" "403" "$(xr "$tok/bot" --tool mail -- tree "$seed")"
check "no caps: inbox is 403" "403" "$(xr "$tok/bot" --tool mail -- inbox bob)"
check "no caps: export is 403" "403" "$(xr "$tok/bot" --tool mail -- export "$seed" --json)"
check "no caps: postmaster status is 403" "403" "$(xr "$tok/bot" --tool postmaster -- status)"
check "no caps: send --from @bot is 200" "200" \
    "$(xr "$tok/bot" --tool mail --stdin hi -- send --from @bot --to @x --subject s --body -)"
check "no caps: that send ran: rc 0" "0" "$(rjson rc)"
check "read cap: show is 200" "200" "$(xr "$tok/ci-kickoff" --tool mail -- show "$seed")"
check "read cap: show is rc 0" "0" "$(rjson rc)"
check "read cap: export is 200" "200" "$(xr "$tok/ci-kickoff" --tool mail -- export "$seed" --json)"
check "read cap: status --thread --json is 200" "200" \
    "$(xr "$tok/ci-kickoff" --tool postmaster -- status --thread "$seed" --json)"
check "read cap: status --thread --json is rc 0" "0" "$(rjson rc)"
check "grant cap: grant --allow-namespace with a probe: rc 0" "0" \
    "$(xr "$tok/ci-kickoff" --tool mail -- grant "$seed" --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 >/dev/null; rjson rc)"
check "the grant file was written" "1" \
    "$([[ -f "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants/$seed.env" ]] && echo 1 || echo 0)"
check "grant --show with read: 200" "200" "$(xr "$tok/ci-kickoff" --tool mail -- grant "$seed" --show)"
check "no caps: grant is 403" "403" "$(xr "$tok/bot" --tool mail -- grant "$seed" --allow-namespace x)"
check "no caps: grant --show is 403 (no read)" "403" "$(xr "$tok/bot" --tool mail -- grant "$seed" --show)"
check "read only: grant --clear is 403" "403" "$(xr "$tok/reader" --tool mail -- grant "$seed" --clear)"
check "read only: grant --show --clear is 403 (needs grant too)" "403" \
    "$(xr "$tok/reader" --tool mail -- grant "$seed" --show --clear)"
check "read only: send with a grant flag is 403 (needs grant)" "403" \
    "$(xr "$tok/reader" --tool mail --stdin hi -- send --from @reader --to @x --subject s --body - --allow-namespace x)"
check "grant cap: send with a grant flag is 200" "200" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @ci-kickoff --to @x --subject s --body - --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80)"
check "grant cap: that send ran: rc 0" "0" "$(rjson rc)"
check "the operator clears the grant: rc 0" "0" \
    "$(xr "$tok/laptop" --tool mail -- grant "$seed" --clear >/dev/null; rjson rc)"

printf '== 6. seen ==\n'

check "seen: a client marks its own name: 200" "200" \
    "$(xr "$tok/reader" --tool mail -- seen reader "$seed")"
check "seen: that ran: rc 0" "0" "$(rjson rc)"
check "seen: the mark was written" "$seed" "$(cat "$FORK_SANDBOX_MAIL_ROOT/agents/reader/seen" 2>/dev/null)"
check "seen: another name: 403" "403" "$(xr "$tok/reader" --tool mail -- seen someone-else "$seed")"
check "seen: without the cap: 403" "403" "$(xr "$tok/ci-kickoff" --tool mail -- seen ci-kickoff "$seed")"
check "seen: no message id: passes the allowlist, MAIL refuses (rc 1)" "1" \
    "$(xr "$tok/reader" --tool mail -- seen reader >/dev/null; rjson rc)"
check "seen: no arguments at all: 400" "400" "$(xr "$tok/reader" --tool mail -- seen)"

printf '== 7. the allowlist ==\n'

check "--context-ro on send: 403" "403" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @ci-kickoff --to @x --subject s --body - --context-ro /tmp)"
contains "--context-ro on send: says why" "$(rjson error)" "a host path has no meaning over the API"
check "--context-ro on send: 403 even for the operator" "403" \
    "$(xr "$tok/laptop" --tool mail --stdin hi -- send --from @operator --to @x --subject s --body - --context-ro /tmp)"
check "--context-ro on grant: 403" "403" \
    "$(xr "$tok/laptop" --tool mail -- grant "$seed" --context-ro /tmp)"
check "an unknown verb (deliver): 403" "403" "$(xr "$tok/laptop" --tool postmaster -- deliver)"
contains "an unknown verb: names it" "$(rjson error)" "deliver"
check "an unknown mail verb: 403" "403" "$(xr "$tok/laptop" --tool mail -- deliver)"
check "an unknown flag: 403" "403" "$(xr "$tok/laptop" --tool mail -- list --verbose)"
contains "an unknown flag: names it" "$(rjson error)" "--verbose"
check "--help: 403" "403" "$(xr "$tok/laptop" --tool mail -- list --help)"
check "an abbreviated flag: 403" "403" "$(xr "$tok/laptop" --tool mail -- inbox bob --al)"
check "a combined short flag: 403" "403" "$(xr "$tok/laptop" --tool mail -- inbox bob -a)"
check "an unknown tool: 403" "403" "$(xr "$tok/laptop" --tool sh -- -c id)"
check "a missing tool: 400" "400" "$(xr "$tok/laptop" --raw '{"argv":["list"]}')"
check "a flag with no value: 400" "400" "$(xr "$tok/laptop" --tool mail -- send --from)"
check "a repeated single-value flag: 400" "400" \
    "$(xr "$tok/laptop" --tool mail --stdin hi -- send --from @a --from @b --to @x --subject s --body -)"
check "a wrong positional count: 400" "400" "$(xr "$tok/laptop" --tool mail -- show)"
check "--body /etc/passwd sent raw: 400" "400" \
    "$(xr "$tok/ci-kickoff" --tool mail -- send --from @ci-kickoff --to @x --subject s --body /etc/passwd)"
check "--attach ../x sent raw: 400" "400" \
    "$(echo x > "$work/x"; xr "$tok/ci-kickoff" --tool mail --stdin hi --file ../x="$work/x" -- send --from @ci-kickoff --to @x --subject s --body - --attach ../x)"
check "--attach .hidden: 400" "400" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi --file .hidden="$work/x" -- send --from @ci-kickoff --to @x --subject s --body - --attach .hidden)"
check "--attach of a file that was not uploaded: 400" "400" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi -- send --from @ci-kickoff --to @x --subject s --body - --attach nothing.bin)"
check "an unreferenced files key: 400" "400" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi --file stray.bin="$work/x" -- send --from @ci-kickoff --to @x --subject s --body -)"
check "a NUL in argv: 400" "400" \
    "$(xr "$tok/laptop" --raw '{"tool":"mail","argv":["show","a\u0000b"]}')"
check "malformed JSON: 400" "400" "$(xr "$tok/laptop" --raw '{"tool":')"
check "a JSON array body: 400" "400" "$(xr "$tok/laptop" --raw '[]')"
check "an unknown request key: 400" "400" "$(xr "$tok/laptop" --raw '{"tool":"mail","argv":["list"],"env":{}}')"
check "argv that is not a list of strings: 400" "400" "$(xr "$tok/laptop" --raw '{"tool":"mail","argv":["show",1]}')"
check "bad base64 stdin: 400" "400" "$(xr "$tok/laptop" --raw '{"tool":"mail","argv":["list"],"stdin_b64":"@@@"}')"
check "a flag-shaped positional: 403" "403" "$(xr "$tok/laptop" --tool mail -- show -x)"

printf '== 8. sizes ==\n'

head -c 5242880 /dev/zero > "$work/big.bin"
check "a 5 MiB attachment: 413" "413" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi --file big.bin="$work/big.bin" -- send --from @ci-kickoff --to @x --subject s --body - --attach big.bin)"
check "Content-Length above 24 MiB: 413 without the body" "413" \
    "$(xr "$tok/laptop" --tool mail --claim-length 25165825 -- list)"
check "no Content-Length: 411" "411" "$(xr "$tok/laptop" --tool mail --no-length -- list)"
check "a bad Content-Length: 400" "400" "$(xr "$tok/laptop" --tool mail --claim-length abc -- list)"
check "an unauthenticated oversize claim: 401, not 413" "401" \
    "$(xr - --tool mail --claim-length 25165825 -- list)"
head -c 4194305 /dev/zero | tr '\0' a > "$work/stdin.big"
check "stdin over 4 MiB: 413" "413" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin-file "$work/stdin.big" -- send --from @ci-kickoff --to @x --subject s --body -)"
many_files=()
for i in $(seq 17); do echo "$i" > "$work/f$i"; many_files+=(--file "f$i=$work/f$i"); done
many_argv=(send --from @ci-kickoff --to @x --subject s --body -)
for i in $(seq 17); do many_argv+=(--attach "f$i"); done
check "17 attachments: 413" "413" \
    "$(xr "$tok/ci-kickoff" --tool mail --stdin hi "${many_files[@]}" -- "${many_argv[@]}")"

printf '== 2. the client shim: send with a body file and an attachment ==\n'

# One shim call as one identity. The URL and token file come from the
# environment, as in CI.
as_() {
    local who="$1"; shift
    FORK_SANDBOX_MAIL_API_URL="http://$listen" \
        FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/$who" "$disp" "$@"
}

printf 'line one\nBODY-SENTINEL-4471\n\nlast line, no newline' > "$work/body.txt"
printf 'a\0b\377\n---\r\nPATCH-SENTINEL\n' > "$work/patch.diff"
tid="$(as_ ci-kickoff mail --remote send --from @ci-kickoff --to @reviewer \
    --subject "kickoff" --body "$work/body.txt" --attach "$work/patch.diff" 2>"$work/send.err")"
rc=$?
check "shim send: rc 0" "0" "$rc"
check "shim send: the thread id is on stdout" "1" "$([[ "$tid" =~ ^[0-9a-f][0-9a-f-]{7,63}$ ]] && echo 1 || echo 0)"
contains "shim send: the local 'sent' line is on stderr" "$(cat "$work/send.err")" "sent"
shown="$("$mail" show "$tid")"
contains "the local mail show has the body" "$shown" "BODY-SENTINEL-4471"
contains "the local mail show has the sender" "$shown" "From: @ci-kickoff"
check "the attachment is byte-exact" "0" \
    "$(cmp -s "$work/patch.diff" "$FORK_SANDBOX_MAIL_ROOT/threads/$tid/attachments/patch.diff"; echo $?)"
body_out="$("$mail" export "$tid" --json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["messages"][0]["body"]))')"
check "the stored body is the file, verbatim" \
    "$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$work/body.txt")" "$body_out"

tid2="$(printf 'from stdin\n' | as_ ci-kickoff mail --remote send --from @ci-kickoff --to @reviewer --subject "two" --body - 2>/dev/null)"
check "shim send with --body -: stdin is the body" "1" \
    "$([[ "$("$mail" show "$tid2")" == *'from stdin'* ]] && echo 1 || echo 0)"
reply_out="$(printf 'a reply\n' | as_ ci-kickoff mail --remote reply --from @ci-kickoff --reply-to "$tid" --body - 2>&1)"
check "shim reply: rc 0" "0" "$?"
contains "shim reply: the reply landed in the thread" "$("$mail" tree "$tid")" "@ci-kickoff"
lacks "shim reply: no error text" "$reply_out" "Error"

printf '== shim: exit codes, refusals and config ==\n'

head -c 5242880 /dev/zero > "$work/big.bin"
as_ ci-kickoff mail --remote send --from @ci-kickoff --to @reviewer --subject big \
    --body "$work/body.txt" --attach "$work/big.bin" > /dev/null 2> "$work/err"
check "shim: an oversize upload exits 2" "2" "$?"
contains "shim: an oversize upload prints the HTTP line" "$(cat "$work/err")" "fork-sandbox mail --remote: HTTP 413:"

mkdir -p "$work/other"; cp "$work/patch.diff" "$work/other/patch.diff"
threads_before="$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -mindepth 1 -maxdepth 1 | wc -l)"
as_ ci-kickoff mail --remote send --from @ci-kickoff --to @reviewer --subject dup \
    --body "$work/body.txt" --attach "$work/patch.diff" --attach "$work/other/patch.diff" > /dev/null 2> "$work/err"
check "shim: two attachments with one basename: rc 2" "2" "$?"
contains "shim: ... refused locally, naming the basename" "$(cat "$work/err")" "patch.diff"
check "shim: ... and nothing was sent" "$threads_before" "$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -mindepth 1 -maxdepth 1 | wc -l)"

as_ ci-kickoff mail --remote send --from @ci-kickoff --to @reviewer --subject s \
    --body "$work/no-such-file" > "$work/out" 2> "$work/err"
shim_rc=$?
"$mail" send --from @ci-kickoff --to @reviewer --subject s --body "$work/no-such-file" > "$work/lout" 2> "$work/lerr"
local_rc=$?
check "shim: a missing body file has the local rc" "$local_rc" "$shim_rc"
check "shim: a missing body file has the local message" "$(cat "$work/lerr")" "$(cat "$work/err")"

as_ ci-kickoff mail --remote send --from @operator --to @x --subject s --body - <<< hi > "$work/out" 2> "$work/err"
check "shim: a 403 exits 2" "2" "$?"
check "shim: a 403 prints one HTTP line" "1" "$(wc -l < "$work/err")"
contains "shim: a 403 names the code" "$(cat "$work/err")" "fork-sandbox mail --remote: HTTP 403: "
check "shim: a 403 prints nothing on stdout" "0" "$(wc -c < "$work/out")"

as_ wrong mail --remote list > /dev/null 2> "$work/err"
check "shim: a wrong token exits 2" "2" "$?"
check "shim: a wrong token: the message" "fork-sandbox mail --remote: HTTP 401: missing or bad token" "$(cat "$work/err")"
as_ ci-kickoff postmaster --remote flag "$tid" > /dev/null 2> "$work/err"
check "shim: postmaster flag as a client exits 2" "2" "$?"
contains "shim: postmaster flag as a client: the message" "$(cat "$work/err")" "fork-sandbox postmaster --remote: HTTP 403: "
as_ laptop postmaster --remote flag "$tid" "by shim" > /dev/null 2>&1
check "shim: postmaster flag as the operator: rc 0" "0" "$?"
check "shim: ... and the flag file is there" "by shim" "$(cat "$FORK_SANDBOX_MAIL_ROOT/.postmaster/needs-operator/$tid")"
as_ laptop postmaster --remote unflag "$tid" > /dev/null 2>&1
check "shim: postmaster unflag as the operator: rc 0" "0" "$?"

FORK_SANDBOX_MAIL_API_URL="http://127.0.0.1:1" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/laptop" \
    "$disp" mail --remote list > /dev/null 2> "$work/err"
check "shim: a connection failure exits 2" "2" "$?"
check "shim: a connection failure is one line" "1" "$(wc -l < "$work/err")"
contains "shim: a connection failure names the tool" "$(cat "$work/err")" "fork-sandbox mail --remote: cannot reach http://127.0.0.1:1"

check "shim: an http proxy in the environment is ignored" "0" \
    "$(http_proxy=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 as_ laptop mail --remote list > /dev/null 2>&1; echo $?)"

# Config: the environment first, else k8s.env; never sourced.
# shellcheck disable=SC2016  # the $( ) is the point: it must stay literal
printf 'K8S_MAIL_API_URL=http://%s\nK8S_MAIL_API_TOKEN_FILE=%s\nK8S_OTHER=$(touch %s/sourced)\n' \
    "$listen" "$tok/laptop" "$work" > "$FORK_SANDBOX_CONFIG_DIR/k8s.env"
check "shim: config from k8s.env" "0" "$("$disp" mail --remote list > /dev/null 2>&1; echo $?)"
check "shim: k8s.env is not sourced" "0" "$([[ -e "$work/sourced" ]] && echo 1 || echo 0)"
check "shim: the environment beats k8s.env" "2" \
    "$(FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/wrong" "$disp" mail --remote list > /dev/null 2>&1; echo $?)"
rm -f "$FORK_SANDBOX_CONFIG_DIR/k8s.env"

"$disp" mail --remote list > /dev/null 2> "$work/err"
check "shim: no URL exits 2" "2" "$?"
contains "shim: no URL names FORK_SANDBOX_MAIL_API_URL" "$(cat "$work/err")" "FORK_SANDBOX_MAIL_API_URL"
contains "shim: no URL names K8S_MAIL_API_URL" "$(cat "$work/err")" "K8S_MAIL_API_URL"
check "shim: no URL is one line" "1" "$(wc -l < "$work/err")"
FORK_SANDBOX_MAIL_API_URL="http://$listen" "$disp" mail --remote list > /dev/null 2> "$work/err"
check "shim: no token file exits 2" "2" "$?"
contains "shim: no token file names FORK_SANDBOX_MAIL_API_TOKEN_FILE" "$(cat "$work/err")" "FORK_SANDBOX_MAIL_API_TOKEN_FILE"
contains "shim: no token file names K8S_MAIL_API_TOKEN_FILE" "$(cat "$work/err")" "K8S_MAIL_API_TOKEN_FILE"
: > "$work/empty-token"
FORK_SANDBOX_MAIL_API_URL="http://$listen" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$work/empty-token" \
    "$disp" mail --remote list > /dev/null 2> "$work/err"
check "shim: an empty token file exits 2" "2" "$?"
FORK_SANDBOX_MAIL_API_URL="http://$listen" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$work/missing-token" \
    "$disp" mail --remote list > /dev/null 2> "$work/err"
check "shim: an unreadable token file exits 2" "2" "$?"

# --remote is checked before a local store or local state is made, and it is
# only special as the first argument.
none_root="$work/no-local-root"
FORK_SANDBOX_MAIL_ROOT="$none_root" "$disp" mail --remote list > /dev/null 2>&1
check "shim: mail --remote makes no local store" "0" "$([[ -e "$none_root" ]] && echo 1 || echo 0)"
FORK_SANDBOX_MAIL_ROOT="$none_root" "$disp" postmaster --remote status > /dev/null 2>&1
check "shim: postmaster --remote makes no local state" "0" "$([[ -e "$none_root" ]] && echo 1 || echo 0)"
out="$(FORK_SANDBOX_MAIL_API_URL="http://127.0.0.1:1" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/laptop" \
    "$mail" show --remote 2>&1)"
lacks "shim: --remote after the verb is not special" "$out" "cannot reach"
out="$(as_ laptop mail --remote --help 2>&1)"; rc=$?
check "shim: --remote --help prints the client usage" "0" "$rc"
contains "shim: --remote --help names the tool" "$out" "mail|postmaster"
check "shim: the scripts run --remote directly too (mail)" "0" \
    "$(FORK_SANDBOX_MAIL_API_URL="http://$listen" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/laptop" "$mail" --remote list > /dev/null 2>&1; echo $?)"
check "shim: the scripts run --remote directly too (postmaster)" "0" \
    "$(FORK_SANDBOX_MAIL_API_URL="http://$listen" FORK_SANDBOX_MAIL_API_TOKEN_FILE="$tok/laptop" "$pm" --remote status > /dev/null 2>&1; echo $?)"

printf '== 9. rc passthrough ==\n'

bad_id="00000000-0000-4000-8000-000000000000"
as_ ci-kickoff mail --remote show "$bad_id" > "$work/out" 2> "$work/err"
shim_rc=$?
"$mail" show "$bad_id" > "$work/lout" 2> "$work/lerr"
local_rc=$?
check "rc passthrough: a well-formed but nonexistent id: same rc" "$local_rc" "$shim_rc"
check "rc passthrough: a well-formed but nonexistent id: same stderr" "$(cat "$work/lerr")" "$(cat "$work/err")"
check "rc passthrough: a well-formed but nonexistent id: same stdout" "$(cat "$work/lout")" "$(cat "$work/out")"

malformed_id="not_an_id"
as_ ci-kickoff mail --remote show "$malformed_id" > "$work/out" 2> "$work/err"
shim_rc=$?
"$mail" show "$malformed_id" > "$work/lout" 2> "$work/lerr"
local_rc=$?
check "rc passthrough: a malformed id: same rc" "$local_rc" "$shim_rc"
check "rc passthrough: a malformed id: same stderr" "$(cat "$work/lerr")" "$(cat "$work/err")"

printf '== 10. byte-exact json views through the shim ==\n'

as_ ci-kickoff mail --remote export "$tid" --json > "$work/shim-export.json" 2> "$work/shim-export.err"
check "shim export --json: rc 0" "0" "$?"
"$mail" export "$tid" --json > "$work/local-export.json" 2> "$work/local-export.err"
check "local export --json: rc 0" "0" "$?"
check "export --json: byte-exact via shim" "0" \
    "$(cmp -s "$work/local-export.json" "$work/shim-export.json"; echo $?)"

as_ ci-kickoff postmaster --remote status --thread "$tid" --json > "$work/shim-status.json" 2> "$work/shim-status.err"
check "shim status --thread --json: rc 0" "0" "$?"
"$pm" status --thread "$tid" --json > "$work/local-status.json" 2> "$work/local-status.err"
check "local status --thread --json: rc 0" "0" "$?"
check "status --thread --json: byte-exact via shim" "0" \
    "$(cmp -s "$work/local-status.json" "$work/shim-status.json"; echo $?)"

as_ ci-kickoff mail --remote show "$tid" > "$work/shim-show.out" 2> "$work/shim-show.err"
check "shim show: rc 0" "0" "$?"
"$mail" show "$tid" > "$work/local-show.out" 2> "$work/local-show.err"
check "local show: rc 0" "0" "$?"
check "mail show: byte-exact via shim" "0" \
    "$(cmp -s "$work/local-show.out" "$work/shim-show.out"; echo $?)"

printf '== 13. the log ==\n'

sleep 0.2
log_text="$(cat "$server_log")"
leaked=0
for t in "$tok/laptop" "$tok/ci-kickoff" "$tok/bot" "$tok/reader"; do
    grep -qF -- "$(cat "$t")" "$server_log" && leaked=1
done
check "the log holds no token" "0" "$leaked"
lacks "the log holds no body string" "$log_text" "/etc/passwd"
lacks "the log holds no shim body string" "$log_text" "BODY-SENTINEL-4471"
lacks "the log holds no attachment name" "$log_text" "patch.diff"
lacks "the log holds no attachment content" "$log_text" "PATCH-SENTINEL"
lacks "the log holds no argv value" "$log_text" "stuck on CI"
contains "the log has a line with the label, tool, verb and status" "$log_text" " ci-kickoff mail send 200 rc=0"
contains "the log has the operator's flag call" "$log_text" " laptop postmaster flag 200 rc=0"
contains "the log shows a refusal" "$log_text" " ci-kickoff postmaster flag 403 rc=-"
contains "the log shows an unauthenticated request" "$log_text" " - - - 401 rc=-"
lacks "the log never holds a hash" "$log_text" "$good_hash"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
