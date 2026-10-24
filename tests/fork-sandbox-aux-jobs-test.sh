#!/usr/bin/env bash
# fork-sandbox-aux-jobs-test.sh — Exercise scripts/fork-sandbox-aux-jobs
# with a fake `kubectl` and a fake `fork-sandbox` (mail export) on PATH:
# validation, gates, header sourcing, the hardened spec, labels, Job
# names, partial-failure exit status, and an absent registry.
#
# Usage: tests/fork-sandbox-aux-jobs-test.sh
#
# Offline; everything lives in a temp dir.

# shellcheck disable=SC2016  # single-quoted bash -c / python snippets are literal
set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
aux="$repo_dir/scripts/fork-sandbox-aux-jobs"

pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() { # label, condition-command...
    local label="$1"; shift
    if "$@"; then ok "$label"; else no "$label"; fi
}

bin="$tmp/bin"
mkdir -p "$bin"
# Fake mail export: the root (lowest seq, listed second to prove sorting)
# carries the headers in $FAKE_HEADERS (JSON array of [name, value]).
cat > "$bin/fork-sandbox" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FORK_SANDBOX_MAIL_ROOT-<unset>}" > "$FAKE_MAIL_ROOT_SEEN"
if [[ -n "${FAKE_ROOT_ERROR:-}" ]]; then
    printf '{"messages":[{"seq":1,"error":"parse","file":"x"},{"seq":2,"headers":[["X-Preview-Repo","example-org/example-repo"],["X-Preview-PR","9"]]}]}\n'
    exit 0
fi
printf '{"messages":[{"seq":2,"headers":[["X-Preview-Repo","other/reply"]]},{"seq":1,"headers":%s}]}\n' "${FAKE_HEADERS:-[]}"
FAKE
# Fake kubectl: records stdin per call; fails when FAKE_KUBECTL_FAIL matches
# the Job's app label.
cat > "$bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
body="$(cat)"
printf '%s\n' "$body" >> "$FAKE_KUBECTL_LOG"
printf '%s\n' "$*" >> "$FAKE_KUBECTL_ARGS"
if [[ -n "${FAKE_KUBECTL_FAIL:-}" && "$body" == *"\"app\": \"$FAKE_KUBECTL_FAIL\""* ]]; then
    echo "boom" >&2; exit 1
fi
FAKE
chmod +x "$bin/fork-sandbox" "$bin/kubectl"
export PATH="$bin:$PATH"
export FAKE_KUBECTL_LOG="$tmp/kubectl.log" FAKE_KUBECTL_ARGS="$tmp/kubectl.args"
export FAKE_MAIL_ROOT_SEEN="$tmp/mail-root-seen"

SHA=0123456789abcdef0123456789abcdef01234567
DIG=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TID=0a1b2c3d4e5f60718293a4b5c6d7e8f9
HDR='[["x-preview-repo","example-org/example-repo"],["X-Preview-PR","12"],["X-Preview-Ref","feature"]]'

run() { # registry-yaml [env assignments...]; sets rc, out, err
    local reg="$tmp/reg.yaml"
    printf '%s\n' "$1" > "$reg"; shift
    : > "$FAKE_KUBECTL_LOG"; : > "$FAKE_KUBECTL_ARGS"
    out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION=3 \
        FAKE_HEADERS="${FAKE_HEADERS-$HDR}" "$@" python3 -I "$aux" --registry "$reg" 2>"$tmp/err")"
    rc=$?
    err="$(cat "$tmp/err")"
}
dry() { run "$1" "${@:2}" ; }
jqq() { printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

entry() { # name [extra yaml lines]
    printf -- '- name: %s\n  event: on-target\n  image: registry.example.com/team/render-panel:sha-%s\n  active_deadline_seconds: 600\n%s\n' "$1" "$SHA" "${2:-}"
}

echo "-- help / args"
"$aux" --help > "$tmp/help"; check "--help prints the header" grep -q 'Usage: fork-sandbox-aux-jobs' "$tmp/help"
if python3 -I "$aux" >/dev/null 2>&1; then no "--registry required"; else ok "--registry required"; fi

echo "-- mail export reads the hook's store"
run "$(entry a '  gates: {requires_pr: true}')" FS_HOOK_MAIL_ROOT=/srv/example-mail
check "FS_HOOK_MAIL_ROOT reaches mail export as FORK_SANDBOX_MAIL_ROOT" \
    grep -qx /srv/example-mail "$FAKE_MAIL_ROOT_SEEN"

echo "-- absent registry"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID python3 -I "$aux" --registry "$tmp/nope.yaml" 2>/dev/null)"; rc=$?
check "absent registry exits 0" test "$rc" -eq 0

echo "-- validation"
run "$(entry ok-one)
$(entry Bad)" ; python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run >/dev/null 2>&1; rc=$?
check "one bad entry exits non-zero" test "$rc" -ne 0
check "error names entry and field" grep -q "field name" <<< "$err"
run "$(entry ok-one)
$(entry second)
  image: registry.example.com/x:latest"
check "bad image: no kubectl calls" test ! -s "$FAKE_KUBECTL_LOG"
check "bad image: non-zero" test "$rc" -ne 0
check "bad image names field" grep -q "field image" <<< "$err"
run "- name: a
  event: on-target
  image: registry.example.com/x:latest
  active_deadline_seconds: 5"
check ":latest refused" test "$rc" -ne 0
run "- name: a
  event: on-target
  image: registry.example.com/x:v1
  active_deadline_seconds: 5"
check "bare tag refused" test "$rc" -ne 0
run "- name: a
  event: on-target
  image: registry.example.com/x@sha256:$DIG
  active_deadline_seconds: 5"
check "digest image accepted" test "$rc" -eq 0
run "$(entry a)
  event: on-nothing"
check "bad event refused" test "$rc" -ne 0
run "- name: a
  event: on-target
  image: registry.example.com/x@sha256:$DIG"
check "active_deadline_seconds required" test "$rc" -ne 0
run "$(entry a '  gates: {branch: [main]}')"
check "unknown gate kind refused" test "$rc" -ne 0
run "$(entry a '  env: {X: {value: a, header: B}}')"
check "two env sources refused" test "$rc" -ne 0
run "$(entry a)
$(entry a)"
check "duplicate name refused" test "$rc" -ne 0
run "$(entry a '  securityContext: {privileged: true}')"
check "spec override field refused" test "$rc" -ne 0
run "$(entry fork-sandbox-agent)"
check "reserved fork-sandbox name refused" test "$rc" -ne 0
run "$(entry a '  secrets:
    - {secret: s, key: k, path: /work}')"
check "secret at /work refused" test "$rc" -ne 0
run "$(entry a '  secrets:
    - {secret: s, key: k, path: /work/x}')"
check "secret under /work refused" test "$rc" -ne 0
run "$(entry a '  secrets:
    - {secret: s, key: k, path: /run/t}
    - {secret: s2, key: k2, path: /run/t/}')"
check "duplicate secret path refused" test "$rc" -ne 0
check "duplicate secret path launches nothing" test ! -s "$FAKE_KUBECTL_LOG"
run "$(entry a '  run_as: {uid: 0}')"
check "uid 0 refused" test "$rc" -ne 0
run "{}"
check "non-list registry refused" test "$rc" -ne 0
run "$(entry a)
$(entry b)"
check "two valid entries launch two Jobs" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 2

echo "-- events"
run "$(entry a)" FS_HOOK_EVENT=on-harvest
check "other event launches nothing" test ! -s "$FAKE_KUBECTL_LOG"

echo "-- gates"
run "$(entry a '  gates: {repo: [example-org/example-repo]}')"
check "repo gate pass launches" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 1
run "$(entry a '  gates: {repo: [example-org/elsewhere]}')"
check "repo gate mismatch skips" test ! -s "$FAKE_KUBECTL_LOG"
check "repo gate skip is not an error" test "$rc" -eq 0
FAKE_HEADERS='[]' run "$(entry a '  gates: {repo: [example-org/example-repo]}')"
check "repo gate: no header, no default skips" test ! -s "$FAKE_KUBECTL_LOG"
FAKE_HEADERS='[]' run "$(entry a '  gates: {repo: [example-org/example-repo]}
  repo_default: example-org/example-repo')"
check "repo_default used when header absent" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 1
FAKE_HEADERS='[["X-Preview-Repo","example-org/elsewhere"]]' run "$(entry a '  gates: {repo: [example-org/example-repo]}
  repo_default: example-org/example-repo')"
check "repo_default does not override a present header" test ! -s "$FAKE_KUBECTL_LOG"
run "$(entry a '  gates: {requires_pr: true}')"
check "requires_pr passes with header" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 1
FAKE_HEADERS='[["X-Preview-Repo","example-org/example-repo"]]' run "$(entry a '  gates: {requires_pr: true}')"
check "requires_pr skips without header" test ! -s "$FAKE_KUBECTL_LOG"
check "reply headers never count (root only)" test "$rc" -eq 0

FAKE_ROOT_ERROR=1 run "$(entry a '  gates: {repo: [example-org/example-repo], requires_pr: true}')"
check "unparseable root: reply never stands in" test ! -s "$FAKE_KUBECTL_LOG"

echo "-- env sources"
printf '%s\n' "$(entry a '  env:
    LIT: {value: hello}
    REF: {header: X-Preview-Ref}
    DEF: {header: X-Nope, default: dflt}
    VER: {hook_env: FS_TARGET_VERSION}')" > "$tmp/reg.yaml"
export FAKE_HEADERS="$HDR"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION=3 python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
check "env literal"   test "$(jqq 'd[0]["spec"]["template"]["spec"]["containers"][0]["env"][0]["value"]')" = hello
check "env header (case-insensitive)" test "$(jqq 'd[0]["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]')" = feature
check "env header default" test "$(jqq 'd[0]["spec"]["template"]["spec"]["containers"][0]["env"][2]["value"]')" = dflt
check "env hook_env" test "$(jqq 'd[0]["spec"]["template"]["spec"]["containers"][0]["env"][3]["value"]')" = 3
run "$(entry a '  env: {NOPE: {header: X-Nope}}')
$(entry b)"
check "missing header w/o default skips that entry only" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 1
check "skip is logged" grep -q "X-Nope" <<< "$err"
check "skip exits 0" test "$rc" -eq 0

echo "-- spec"
: > "$FAKE_KUBECTL_LOG"
reg="$(entry a '  resources: {requests: {cpu: 100m}, limits: {memory: 1Gi}}
  secrets:
    - {secret: example-token, key: token, path: /run/secrets/token}
  run_as: {uid: 2000, gid: 3000}
  ttl_seconds_after_finished: 60')"
printf '%s\n' "$reg" > "$tmp/reg.yaml"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION=3 python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
chk() { check "$1" test "$(jqq "$2")" = "$3"; }
P='d[0]["spec"]["template"]["spec"]'
chk "kind Job" 'd[0]["kind"]' Job
chk "no namespace set" '"namespace" in d[0]["metadata"]' False
chk "runAsNonRoot" "$P"'["securityContext"]["runAsNonRoot"]' True
chk "runAsUser" "$P"'["securityContext"]["runAsUser"]' 2000
chk "runAsGroup" "$P"'["securityContext"]["runAsGroup"]' 3000
chk "seccomp" "$P"'["securityContext"]["seccompProfile"]["type"]' RuntimeDefault
chk "no privilege escalation" "$P"'["containers"][0]["securityContext"]["allowPrivilegeEscalation"]' False
chk "drop ALL" "$P"'["containers"][0]["securityContext"]["capabilities"]["drop"]' "['ALL']"
chk "no SA token" "$P"'["automountServiceAccountToken"]' False
chk "restartPolicy" "$P"'["restartPolicy"]' Never
chk "backoffLimit" 'd[0]["spec"]["backoffLimit"]' 0
chk "deadline" 'd[0]["spec"]["activeDeadlineSeconds"]' 600
chk "ttl override" 'd[0]["spec"]["ttlSecondsAfterFinished"]' 60
chk "work emptyDir" "$P"'["volumes"][0]["emptyDir"]' "{}"
chk "work mount" "$P"'["containers"][0]["volumeMounts"][0]["mountPath"]' /work
chk "secret mode" "$P"'["volumes"][1]["secret"]["defaultMode"]' 292
chk "secret mounted read-only at path" "$P"'["containers"][0]["volumeMounts"][1]["readOnly"], '"$P"'["containers"][0]["volumeMounts"][1]["mountPath"]' "(True, '/run/secrets/token')"
chk "secret mounts one key" "$P"'["volumes"][1]["secret"]["items"][0]["key"]' token
chk "resources passed through" "$P"'["containers"][0]["resources"]["limits"]["memory"]' 1Gi
printf '%s\n' "$(entry a)" > "$tmp/reg.yaml"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
chk "default ttl" 'd[0]["spec"]["ttlSecondsAfterFinished"]' 86400
chk "default uid" "$P"'["securityContext"]["runAsUser"]' 1000
chk "name falls back to event" 'd[0]["metadata"]["name"].split("-",2)[2].startswith("on-target")' True

echo "-- labels"
chk "labels" 'sorted(d[0]["metadata"]["labels"].items())' "[('app', 'a'), ('aux-job', 'a')]"
chk "pod labels" 'sorted(d[0]["spec"]["template"]["metadata"]["labels"].items())' "[('app', 'a'), ('aux-job', 'a')]"
check "no fork-sandbox labels" bash -c '! grep -q "fork-sandbox" <<< "$1"' _ "$out"

echo "-- dry-run / kubectl"
check "dry-run calls no kubectl" test ! -s "$FAKE_KUBECTL_LOG"
run "$(entry a)"
check "kubectl create -f -" grep -qx 'create -f -' "$FAKE_KUBECTL_ARGS"
check "no -n flag (current namespace)" bash -c '! grep -q -- "-n\|namespace" "$1"' _ "$FAKE_KUBECTL_ARGS"

echo "-- job name"
longname=abcdefghijklmnopqrstuvwxyz01234
printf '%s\n' "$(entry "$longname")" > "$tmp/reg.yaml"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION='V3.0_rc/1 weird-and-very-long-version' python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
jn="$(jqq 'd[0]["metadata"]["name"]')"
check "job name <= 63 chars" test "${#jn}" -le 63
check "job name DNS-safe" bash -c '[[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]' _ "$jn"
check "job name has prefix and thread id" bash -c '[[ "$1" == '"$longname"'-0a1b2c3d-* ]]' _ "$jn"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION=7 python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
a="$(jqq 'd[0]["metadata"]["name"]')"
out="$(env FS_HOOK_EVENT=on-target FS_HOOK_THREAD=$TID FS_TARGET_VERSION=7 python3 -I "$aux" --registry "$tmp/reg.yaml" --dry-run)"
check "random suffix differs per call" test "$a" != "$(jqq 'd[0]["metadata"]["name"]')"

echo "-- partial failure"
run "$(entry one)
$(entry two)
$(entry three)" FAKE_KUBECTL_FAIL=two
check "failure exits non-zero" test "$rc" -ne 0
check "all three attempted" test "$(grep -c . "$FAKE_KUBECTL_LOG")" -eq 3
check "failure names the entry" grep -q 'failed: two' <<< "$err"

printf '\n%d ok / %d fail\n' "$pass" "$fail"
(( fail == 0 ))
