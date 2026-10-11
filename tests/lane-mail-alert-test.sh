#!/usr/bin/env bash
# lane-mail-alert-test.sh -- Exercise lane-mail-alert: alert webhooks into
# lane mail, with threading, dedup, the reopen window, the HTTP front, and a
# cross-host recipient.
#
# No real lane-mail root, no real ssh, no network beyond 127.0.0.1. Each
# "host" is a throwaway directory holding its own store root and config dir
# and copies of the lane-mail scripts, with the fixed LANE_MAIL_ROOT line in
# lane-mail-lib.sh pointed at that host's temp root (as in
# lane-mail-hosts-test.sh). lane-mail-alert finds lane-mail.sh beside itself,
# so the copy in a host's bin dir mails that host's store.
#
# Usage: tests/lane-mail-alert-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
scripts="$repo_dir/scripts"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}
contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "'$3' not found in: $2" ;; esac
}

scratch="$(mktemp -d)"
server_pid=""
cleanup() {
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
    rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/home" "$scratch/tmp"
export HOME="$scratch/home" TMPDIR="$scratch/tmp"
unset TMUX FORK_SANDBOX_MAIL_ROOT XDG_STATE_HOME

# The ssh stand-in plays sshd for the cross-host case: it runs the target
# host's lane-mail-serve with the forced --peer and SSH_ORIGINAL_COMMAND.
cat > "$scratch/ssh-stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
while [[ "${1:-}" == -* ]]; do shift 2; done
dest="$1"; shift
[[ "$dest" == beta-dest ]] || { echo "ssh: Could not resolve hostname $dest" >&2; exit 255; }
SSH_ORIGINAL_COMMAND="$*" FORK_SANDBOX_CONFIG_DIR="$BETA/cfg" \
    "$BETA/bin/lane-mail-serve" --peer alpha
STUB
chmod +x "$scratch/ssh-stub"

mk_host() {
    local name="$1" d="$scratch/$1"
    mkdir -p "$d/root" "$d/cfg" "$d/bin"
    cp "$scripts/lane-mail.sh" "$scripts/lane-mail-serve" "$scripts/lane-mail-alert" "$d/bin/"
    sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$d/root|" "$scripts/lane-mail-lib.sh" > "$d/bin/lane-mail-lib.sh"
    ln -s "$scripts/fork-sandbox-mail.sh" "$d/bin/fork-sandbox-mail.sh"
    printf 'LANE_MAIL_PEER_NAME=%s\nLANE_MAIL_SSH=%s\n' "$name" "$scratch/ssh-stub" > "$d/cfg/lane-mail.env"
}
mk_host alpha
mk_host beta
# The mail API client, played by a stub that runs the store against the
# "cluster" root: --via remote must hand it `mail <verb> args...`.
mkdir -p "$scratch/cluster"
cat > "$scratch/alpha/bin/fork-sandbox-mail-remote.py" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == mail ]] || { echo "stub: expected the mail tool, got '$1'" >&2; exit 2; }
shift
FORK_SANDBOX_MAIL_ROOT="$CLUSTER_ROOT" exec "$STORE" "$@"
STUB
chmod +x "$scratch/alpha/bin/fork-sandbox-mail-remote.py"
export CLUSTER_ROOT="$scratch/cluster" STORE="$scripts/fork-sandbox-mail.sh"
printf 'beta beta-dest\n' > "$scratch/alpha/cfg/lane-mail-peers"
export BETA="$scratch/beta"

state="$scratch/state"
on() {
    local h="$1"; shift
    env PATH="$scratch/$h/bin:$scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/$h/cfg" "$@"
}
alert() { on alpha "$scratch/alpha/bin/lane-mail-alert" "$@"; }
ingest() { alert ingest --state-dir "$state" "$@"; }
lm() { on alpha "$scratch/alpha/bin/lane-mail.sh" "$@"; }
field() { pyfield "$1" "$2"; }
pyfield() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]) or "")' "$1" "$2"; }
hdr() { sed -n "s/^$2: //p" <<<"$1" | head -1; }
msgs() { find "$scratch/$1/root" -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }

# payload <status> <groupKey> <alert-json>...: an Alertmanager webhook body.
payload() {
    local status="$1" key="$2"; shift 2
    local alerts; alerts="$(IFS=,; printf '%s' "$*")"
    printf '{"version":"4","groupKey":"%s","status":"%s","receiver":"lane-mail","groupLabels":{"alertname":"KubeNodePressure","node":"node-a1"},"commonLabels":{"alertname":"KubeNodePressure"},"externalURL":"http://am.example.test","alerts":[%s]}' \
        "$key" "$status" "$alerts"
}
# am_alert <status> <fingerprint> [extra-label-value]
am_alert() {
    printf '{"status":"%s","fingerprint":"%s","labels":{"alertname":"KubeNodePressure","node":"node-a1","condition":"%s"},"annotations":{"summary":"Node has DiskPressure","description":"line one\\nline two"},"startsAt":"2026-10-10T01:00:00Z","endsAt":"2026-10-10T02:00:00Z","generatorURL":"http://prom.example.test/graph?g0"}' \
        "$1" "$2" "${3:-DiskPressure}"
}
G1='{}/{}:{alertname=\"KubeNodePressure\", node=\"node-a1\"}'

echo "== usage =="
out="$(alert --help)"; rc=$?
check "--help exits 0" "0" "$rc"
contains "--help prints the header" "$out" "Turn Alertmanager and Grafana alert webhooks into lane mail"
alert ingest --to 'ops' </dev/null >/dev/null 2>&1; rc=$?
check "a --to that is not a lane address is refused with exit 2" "2" "$rc"
alert ingest --from '@a:beta' </dev/null >/dev/null 2>&1; rc=$?
check "a --from on another host is refused with exit 2" "2" "$rc"
alert serve --listen 127.0.0.1:0 >/dev/null 2>&1; rc=$?
check "serve without --token-file is refused with exit 2" "2" "$rc"

echo "== a group opens a thread =="
out="$(payload firing "$G1" "$(am_alert firing fp1)" | ingest)"; rc=$?
check "a firing group is handled" "0" "$rc"
check "it is sent as a new thread" "sent" "$(field "$out" result)"
id1="$(field "$out" id)"
group="$(field "$out" group)"
check "the group is 16 hex" "1" "$([[ "$group" =~ ^[0-9a-f]{16}$ ]] && echo 1 || echo 0)"
inbox="$(lm inbox ops)"
check "it lands in @ops's inbox" "$id1" "$(cut -f1 <<<"$inbox")"
check "from @alerts" "@alerts" "$(cut -f4 <<<"$inbox")"
check "the subject names the status, count and group" "[FIRING:1] KubeNodePressure node-a1" "$(cut -f5 <<<"$inbox")"
m="$(lm show "$id1")"
check "X-Alert-Group carries the group" "$group" "$(hdr "$m" X-Alert-Group)"
check "X-Alert-Status is firing" "firing" "$(hdr "$m" X-Alert-Status)"
contains "the body has the summary" "$m" "  summary: Node has DiskPressure"
contains "a multi-line annotation is indented" "$m" $'  description: line one\n      line two'
contains "the body has the other labels" "$m" "  labels: condition=DiskPressure, node=node-a1"
contains "the body has the generator link" "$m" "  source: http://prom.example.test/graph?g0"
contains "the body has the source" "$m" "Source: http://am.example.test"
check "a firing alert has no end time in the body" "0" "$(grep -c '  ended:' <<<"$m")"
check "the thread is findable by its group header" "$id1" \
    "$(lm list --header "X-Alert-Group: $group" | cut -f1)"

echo "== repeats, changes, resolution =="
out="$(payload firing "$G1" "$(am_alert firing fp1)" | ingest)"
check "the identical notification is a duplicate" "duplicate" "$(field "$out" result)"
check "a duplicate stores nothing" "1" "$(msgs alpha)"
out="$(payload firing "$G1" "$(am_alert firing fp1)" "$(am_alert firing fp2 MemoryPressure)" | ingest)"
check "a second alert joining the group replies" "replied" "$(field "$out" result)"
id2="$(field "$out" id)"
check "in the same thread" "$id1" "$(field "$out" thread)"
check "the reply's parent is the first message" "$id1" "$(hdr "$(lm show "$id2")" In-Reply-To)"
check "its subject counts both" "[FIRING:2] KubeNodePressure node-a1" "$(hdr "$(lm show "$id2")" Subject)"
out="$(payload resolved "$G1" "$(am_alert resolved fp1)" "$(am_alert resolved fp2)" | ingest)"
check "resolution replies" "replied" "$(field "$out" result)"
id3="$(field "$out" id)"
check "under the last message" "$id2" "$(hdr "$(lm show "$id3")" In-Reply-To)"
m="$(lm show "$id3")"
check "with a RESOLVED subject" "[RESOLVED] KubeNodePressure node-a1" "$(hdr "$m" Subject)"
check "and X-Alert-Status resolved" "resolved" "$(hdr "$m" X-Alert-Status)"
contains "a resolved alert shows its end time" "$m" "  ended: 2026-10-10T02:00:00Z"
check "the reply goes to the configured recipients" "@ops" "$(hdr "$m" To)"
out="$(payload resolved "$G1" "$(am_alert resolved fp1)" "$(am_alert resolved fp2)" | ingest)"
check "a repeated resolution is a duplicate" "duplicate" "$(field "$out" result)"

echo "== flapping and reopening =="
out="$(payload firing "$G1" "$(am_alert firing fp1)" | ingest)"
check "firing again inside --reopen continues the thread" "$id1" "$(field "$out" thread)"
check "as a reply" "replied" "$(field "$out" result)"
payload resolved "$G1" "$(am_alert resolved fp1)" | ingest >/dev/null
sf="$state/$group.json"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["updated"]-=7200; json.dump(s, open(p,"w"))' "$sf"
out="$(payload firing "$G1" "$(am_alert firing fp1)" | ingest)"
check "firing after --reopen has passed opens a new thread" "sent" "$(field "$out" result)"
id4="$(field "$out" id)"
check "the new thread is its own" "$id4" "$(field "$out" thread)"
payload resolved "$G1" "$(am_alert resolved fp1)" | ingest >/dev/null
out="$(payload firing "$G1" "$(am_alert firing fp1)" | ingest --reopen 0)"
check "--reopen 0 never continues a resolved thread" "sent" "$(field "$out" result)"

echo "== a thread gone from the store =="
id5="$(field "$out" id)"
rm -rf -- "$scratch/alpha/root/threads/$id5"
out="$(payload firing "$G1" "$(am_alert firing fp1)" "$(am_alert firing fp3 PIDPressure)" | ingest 2>"$scratch/err")"
check "a reply whose thread is gone opens a new thread" "sent" "$(field "$out" result)"
contains "and says why on stderr" "$(cat "$scratch/err")" "reply failed"

echo "== other groups, Grafana, truncation =="
out="$(payload firing 'other-group' "$(am_alert firing fp1)" | ingest)"
check "a different groupKey is a different thread" "sent" "$(field "$out" result)"
grafana='{"receiver":"lane-mail","status":"firing","orgId":1,"groupKey":"{}:{alertname=\"HighLoad\"}","groupLabels":{"alertname":"HighLoad"},"title":"[FIRING:1] HighLoad","alerts":[{"status":"firing","labels":{"alertname":"HighLoad","grafana_folder":"infra"},"annotations":{},"startsAt":"2026-10-10T03:00:00Z","dashboardURL":"http://grafana.example.test/d/abc","panelURL":"http://grafana.example.test/d/abc?viewPanel=2","silenceURL":"http://grafana.example.test/alerting/silence/new","valueString":"[ var=A value=9.5 ]"}]}'
out="$(printf '%s' "$grafana" | ingest)"
check "a Grafana payload (no fingerprints) is handled" "sent" "$(field "$out" result)"
m="$(lm show "$(field "$out" id)")"
contains "the Grafana dashboard link is in the body" "$m" "  dashboard: http://grafana.example.test/d/abc"
contains "the Grafana value string is in the body" "$m" "  values: [ var=A value=9.5 ]"
check "a Grafana repeat is a duplicate" "duplicate" "$(field "$(printf '%s' "$grafana" | ingest)" result)"
many=()
for i in $(seq 1 25); do many+=("$(am_alert firing "m$i")"); done
out="$(payload firing 'many' "${many[@]}" | ingest)"
m="$(lm show "$(field "$out" id)")"
contains "alerts past the first 20 are counted, not listed" "$m" "(5 more alerts not shown)"
check "the subject counts all of them" "[FIRING:25] KubeNodePressure node-a1" "$(hdr "$m" Subject)"

echo "== bad payloads and failed sends =="
before="$(msgs alpha)"
printf 'not json' | ingest >/dev/null 2>&1; rc=$?
check "non-JSON is refused with exit 2" "2" "$rc"
printf '{"status":"firing","alerts":[]}' | ingest >/dev/null 2>&1; rc=$?
check "an empty alerts list is refused with exit 2" "2" "$rc"
printf '{"status":"pending","alerts":[{}]}' | ingest >/dev/null 2>&1; rc=$?
check "an unknown status is refused with exit 2" "2" "$rc"
printf '{"status":"firing","alerts":[{"labels":"x"}]}' | ingest >/dev/null 2>&1; rc=$?
check "labels that are not an object are refused with exit 2" "2" "$rc"
payload firing 'dead' "$(am_alert firing fp1)" | ingest --to @ops:nowhere >/dev/null 2>"$scratch/err"; rc=$?
check "a send that fails exits 1" "1" "$rc"
contains "with lane-mail's reason" "$(cat "$scratch/err")" "unknown host 'nowhere'"
check "nothing was stored by any of them" "$before" "$(msgs alpha)"
out="$(payload firing 'dead' "$(am_alert firing fp1)" | ingest)"
check "a failed send left no state, so the retry is sent" "sent" "$(field "$out" result)"

echo "== cross-host recipients =="
out="$(payload firing 'xhost' "$(am_alert firing fp1)" | ingest --to @ops,@ops:beta)"
xid="$(field "$out" id)"
check "a group to a local and a remote lane is sent" "sent" "$(field "$out" result)"
check "it lands in the remote host's @ops inbox" "$xid" "$(on beta "$scratch/beta/bin/lane-mail.sh" inbox ops | cut -f1)"
check "from @alerts on the bridge host" "@alerts:alpha" "$(on beta "$scratch/beta/bin/lane-mail.sh" inbox ops | cut -f4)"
out="$(payload resolved 'xhost' "$(am_alert resolved fp1)" | ingest --to @ops,@ops:beta)"
check "its resolution threads under it on the remote host too" "$xid" \
    "$(hdr "$(on beta "$scratch/beta/bin/lane-mail.sh" show "$(field "$out" id)")" In-Reply-To)"

echo "== --via and --route =="
alert ingest --via nowhere </dev/null >/dev/null 2>&1; rc=$?
check "an unknown --via is refused with exit 2" "2" "$rc"
alert ingest --via fleet --to @ops:beta </dev/null >/dev/null 2>&1; rc=$?
check "--via fleet refuses a host-qualified address" "2" "$rc"
alert ingest --route 'namespace=shop' </dev/null >/dev/null 2>&1; rc=$?
check "a --route without a lane is refused with exit 2" "2" "$rc"
alert ingest --heartbeat 5 </dev/null >/dev/null 2>&1; rc=$?
check "--heartbeat outside serve is refused with exit 2" "2" "$rc"
mkdir -p "$scratch/fleet"
out="$(payload firing 'fleet-group' "$(am_alert firing fp1)" \
    | FORK_SANDBOX_MAIL_ROOT="$scratch/fleet" ingest --via fleet)"
check "--via fleet sends" "sent" "$(field "$out" result)"
fid="$(field "$out" id)"
check "into the store at FORK_SANDBOX_MAIL_ROOT" "$fid" \
    "$(FORK_SANDBOX_MAIL_ROOT="$scratch/fleet" "$scripts/fork-sandbox-mail.sh" inbox ops | cut -f1)"
check "and not into lane mail" "0" "$(lm inbox ops --all | grep -c "$fid")"
out="$(payload resolved 'fleet-group' "$(am_alert resolved fp1)" \
    | FORK_SANDBOX_MAIL_ROOT="$scratch/fleet" ingest --via fleet)"
check "--via fleet threads the resolution" "$fid" "$(field "$out" thread)"
out="$(payload firing 'remote-group' "$(am_alert firing fp1)" | ingest --via remote)"
check "--via remote sends through the API client" "sent" "$(field "$out" result)"
rid="$(field "$out" id)"
check "into the remote store" "$rid" \
    "$(FORK_SANDBOX_MAIL_ROOT="$CLUSTER_ROOT" "$scripts/fork-sandbox-mail.sh" inbox ops | cut -f1)"
out="$(payload resolved 'remote-group' "$(am_alert resolved fp1)" | ingest --via remote)"
check "--via remote replies in the thread" "replied" "$(field "$out" result)"
shop='{"groupKey":"shop-g","status":"firing","groupLabels":{"alertname":"PodCrashLooping"},"commonLabels":{"alertname":"PodCrashLooping","namespace":"shop"},"alerts":[{"status":"firing","fingerprint":"s1","labels":{"alertname":"PodCrashLooping","namespace":"shop"},"annotations":{}}]}'
out="$(printf '%s' "$shop" | ingest --route 'namespace=other:@other' --route 'namespace=shop:@shop,@ops')"
m="$(lm show "$(field "$out" id)")"
check "the first matching --route picks the recipients" "@shop, @ops" "$(hdr "$m" To)"
out="$(payload firing 'unrouted' "$(am_alert firing fp1)" | ingest --route 'namespace=shop:@shop')"
check "a group no route matches goes to --to" "@ops" "$(hdr "$(lm show "$(field "$out" id)")" To)"

echo "== serve =="
# serve_bg <args>: start serve in the background, set $server_pid and $port.
# env, not the on() function, so $! is the server itself and kill reaches it.
serve_bg() {
    env PATH="$scratch/alpha/bin:$scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/alpha/cfg" \
        "$scratch/alpha/bin/lane-mail-alert" serve --listen 127.0.0.1:0 --token-file "$scratch/token" \
        "$@" >/dev/null 2>"$scratch/serve.log" &
    server_pid=$!
    port=""
    for _ in $(seq 1 100); do
        port="$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\),.*/\1/p' "$scratch/serve.log")"
        [[ -n "$port" ]] && break
        sleep 0.1
    done
}
printf 'short\n' > "$scratch/short-token"
alert serve --listen 127.0.0.1:0 --token-file "$scratch/short-token" >/dev/null 2>&1; rc=$?
check "a token under 16 characters is refused with exit 2" "2" "$rc"
token="test-token-0123456789abcdef"
printf '%s\n' "$token" > "$scratch/token"
serve_bg --state-dir "$scratch/state-http"
check "serve reports the port it bound" "1" "$([[ "$port" =~ ^[0-9]+$ ]] && echo 1 || echo 0)"
url="http://127.0.0.1:$port"
code() { curl -s -o "$scratch/resp" -w '%{http_code}' "$@"; }
check "/healthz needs no token" "200" "$(code "$url/healthz")"
body="$(payload firing 'http-group' "$(am_alert firing fp1)")"
check "a POST without a token is 401" "401" "$(code -X POST --data "$body" "$url/v1/alert")"
check "a POST with a wrong token is 401" "401" "$(code -X POST -H 'Authorization: Bearer wrong-token-0123456789' --data "$body" "$url/v1/alert")"
check "an unknown path is 404" "404" "$(code -X POST -H "Authorization: Bearer $token" --data "$body" "$url/v1/nope")"
check "a bad payload is 400" "400" "$(code -X POST -H "Authorization: Bearer $token" --data 'nope' "$url/v1/alert")"
check "a webhook is 200" "200" "$(code -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "$body" "$url/v1/alert")"
resp="$(cat "$scratch/resp")"
check "and is sent" "sent" "$(field "$resp" result)"
check "into @ops's inbox" "1" "$(lm inbox ops | grep -c "$(field "$resp" id)")"
check "its repeat is 200 duplicate" "200" "$(code -X POST -H "Authorization: Bearer $token" --data "$body" "$url/v1/alert")"
check "reported as a duplicate" "duplicate" "$(field "$(cat "$scratch/resp")" result)"
dead="$(payload firing 'http-dead' "$(am_alert firing fp1)")"
kill "$server_pid"; wait "$server_pid" 2>/dev/null
serve_bg --state-dir "$scratch/state-http" --to @ops:nowhere
check "a failed send is 500, so the sender retries" "500" \
    "$(code -X POST -H "Authorization: Bearer $token" --data "$dead" "http://127.0.0.1:$port/v1/alert")"
kill "$server_pid"; wait "$server_pid" 2>/dev/null
server_pid=""

echo "== heartbeat =="
serve_bg --state-dir "$scratch/state-hb" --to @hb --heartbeat 2
url="http://127.0.0.1:$port"
beat='{"groupKey":"wd","status":"firing","groupLabels":{"alertname":"Watchdog"},"alerts":[{"status":"firing","fingerprint":"w","labels":{"alertname":"Watchdog","severity":"none"},"annotations":{}}]}'
check "a heartbeat is 200" "200" "$(code -X POST -H "Authorization: Bearer $token" --data "$beat" "$url/v1/alert")"
check "answered as a heartbeat" "heartbeat" "$(field "$(cat "$scratch/resp")" result)"
check "a heartbeat is never mailed" "" "$(lm inbox hb)"
for _ in $(seq 1 60); do [[ -n "$(lm inbox hb)" ]] && break; sleep 0.1; done
quiet="$(lm inbox hb)"
check "silence past --heartbeat mails AlertingQuiet" "[FIRING:1] AlertingQuiet" "$(cut -f5 <<<"$quiet")"
contains "naming the heartbeat" "$(lm show "$(cut -f1 <<<"$quiet")")" "No Watchdog heartbeat for"
sleep 1
check "the quiet alert is mailed once" "1" "$(lm inbox hb | grep -c .)"
code -X POST -H "Authorization: Bearer $token" --data "$beat" "$url/v1/alert" >/dev/null
back="$(lm inbox hb | tail -1)"
check "the heartbeat's return mails the resolution" "[RESOLVED] AlertingQuiet" "$(cut -f5 <<<"$back")"
check "threaded under the quiet alert" "$(cut -f1 <<<"$quiet")" "$(hdr "$(lm show "$(cut -f1 <<<"$back")")" In-Reply-To)"
wd_alert='{"status":"firing","fingerprint":"w","labels":{"alertname":"Watchdog"},"annotations":{}}'
mixed="$(payload firing 'with-beat' "$(am_alert firing fp1)" "$wd_alert")"
check "a payload mixing a heartbeat with alerts is 200" "200" \
    "$(code -X POST -H "Authorization: Bearer $token" --data "$mixed" "$url/v1/alert")"
m="$(lm show "$(field "$(cat "$scratch/resp")" id)")"
check "its real alerts are mailed, the heartbeat left out" "[FIRING:1] KubeNodePressure node-a1" "$(hdr "$m" Subject)"
kill "$server_pid"; wait "$server_pid" 2>/dev/null
server_pid=""

echo
echo "lane-mail-alert: $pass passed, $fail failed"
(( fail == 0 ))
