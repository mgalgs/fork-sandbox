#!/usr/bin/env bash
# fork-sandbox-k8s-test.sh — the Kubernetes run mode holds its own contract
#
# Usage: tests/fork-sandbox-k8s-test.sh
#
# Runs entirely offline: no cluster, no network. Everything it checks is
# either static analysis (shellcheck, yamllint) or the rendered text of a
# --dry-run invocation, which touches no kubectl and no git remote. That is
# the whole point of --dry-run existing -- see docs/kubernetes-runs.md.
#
# It covers:
#   - shellcheck on the five new scripts (the client, the platform plugin,
#     the pod entrypoint, the egress gate, the inbox writer).
#   - yamllint on manifests/k8s/ and on the install/submit/run --dry-run
#     renders.
#   - fork-sandbox-k8s-platform-generic's two verbs.
#   - the properties docs/kubernetes-runs.md promises: the agent pod never
#     automounts a ServiceAccount token, and its egress policy has no rule
#     permitting port 443 -- only the proxy and DNS are reachable.
#   - an unknown platform name fails with a clear error.
#   - `run --dry-run` renders byte-for-byte the same Job YAML as
#     `submit --dry-run`, proving run delegates rather than growing its own
#     divergent copy of the rendering, and rejects the same argument
#     mistakes the other verbs reject. The poll/wait/fetch/rm sequence
#     itself needs a live cluster and is not covered here -- see the header
#     comment on cmd_run in fork-sandbox-k8s.sh.
#   - `submit --dry-run`'s rendered handoff.md carries the operator-inbox
#     section, names /work/inbox, and never claims that directory is
#     read-only -- it is not, in a pod (see docs/kubernetes-runs.md).
#   - `say`'s own argument validation (missing --branch, missing/empty
#     message, unknown option) -- all rejected before any kubectl call, so
#     they run with no cluster. The kubectl exec write itself needs a live
#     pod and is not covered here.
#   - fork-sandbox-k8s-inbox-write.sh's naming and no-collision behavior,
#     run directly against a plain directory -- the same script the pod
#     mounts and `say` execs over kubectl exec, so this is the real
#     implementation under test, not a duplicate of its logic.
#   - no file in the repo matches a private-hostname shape, guarding the
#     public-repo leak rule every script and manifest here has to hold to.
#   - fork-sandbox.sh --k8s: the two new lib functions it shares with the
#     local path (fs_require_scratch_handoff, fs_require_src_project), that
#     it refuses --harness values other than pi and every flag the cluster
#     path cannot honor by name (never silently dropping one), that
#     --timeout/--keep are refused without --k8s, that a --branch is
#     generated when none is given, and that --dry-run renders byte-for-byte
#     the same Job YAML `fork-sandbox-k8s.sh run --dry-run` does for the
#     same arguments -- proving the dispatcher execs rather than growing a
#     divergent copy of anything.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
refuses() {
    local label="$1" needle="$2" out rc; shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$needle"* ]]; then ok "$label"; else no "$label" "status $rc: $out"; fi
}
newdir() { mktemp -d; }

k8s_sh="$repo_dir/scripts/fork-sandbox-k8s.sh"
fs_sh="$repo_dir/scripts/fork-sandbox.sh"
lib_sh="$repo_dir/scripts/fork-sandbox-lib.sh"
platform_generic="$repo_dir/scripts/fork-sandbox-k8s-platform-generic"
entrypoint_sh="$repo_dir/scripts/fork-sandbox-k8s-entrypoint.sh"
gate_sh="$repo_dir/scripts/fork-sandbox-k8s-egress-gate.sh"
inbox_write_sh="$repo_dir/scripts/fork-sandbox-k8s-inbox-write.sh"

printf '== shellcheck ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP  shellcheck not installed\n'
else
    for f in "$k8s_sh" "$platform_generic" "$entrypoint_sh" "$gate_sh" "$inbox_write_sh"; do
        out="$(shellcheck "$f" 2>&1)"
        if [[ -z "$out" ]]; then ok "shellcheck: $(basename "$f")"; else no "shellcheck: $(basename "$f")" "$out"; fi
    done
fi

printf '\n== yamllint manifests/k8s/ ==\n'
if ! command -v yamllint >/dev/null 2>&1; then
    printf '  SKIP  yamllint not installed\n'
else
    out="$(yamllint "$repo_dir/manifests/k8s" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: manifests/k8s/"; else no "yamllint: manifests/k8s/" "$out"; fi
fi

printf '\n== fork-sandbox-k8s-platform-generic ==\n'
caps="$("$platform_generic" --capabilities)"
check "capabilities: policy" "policy=networkpolicy" "$(grep '^policy=' <<< "$caps")"
check "capabilities: icmp" "icmp=unfiltered" "$(grep '^icmp=' <<< "$caps")"
check "capabilities: dns" "dns=recursive" "$(grep '^dns=' <<< "$caps")"
check "capabilities: runtimeclass" "runtimeclass=none" "$(grep '^runtimeclass=' <<< "$caps")"

policy="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy --proxy-port 8080)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint - <<< "$policy" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: render-policy output"; else no "yamllint: render-policy output" "$out"; fi
fi
if [[ "$policy" == *"port: 443"* ]]; then
    no "agent policy has no rule permitting port 443" "found 'port: 443' in render-policy output"
else
    ok "agent policy has no rule permitting port 443"
fi

printf '\n== fork-sandbox-k8s.sh --dry-run (fixture config, no cluster) ==\n'
config_dir="$(newdir)"; tmpdirs+=("$config_dir")
cat > "$config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
install -m 600 /dev/null "$config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$config_dir/pi.env"
chmod 600 "$config_dir/pi.env"

refuses "unknown platform name fails with a clear error" \
    "cannot find fork-sandbox-k8s-platform-bogus" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" FORK_SANDBOX_K8S_PLATFORM=bogus \
    "$k8s_sh" install --dry-run

proj_dir="$(newdir)"; tmpdirs+=("$proj_dir")
git -C "$proj_dir" init -q
git -C "$proj_dir" -c user.email=t@example -c user.name=t commit -q --allow-empty -m init

handoff_file="$(newdir)/handoff.md"; tmpdirs+=("$(dirname "$handoff_file")")
printf 'Do the thing.\n' > "$handoff_file"

install_out="$(newdir)/install.yaml"; tmpdirs+=("$(dirname "$install_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" install --dry-run > "$install_out" 2>/tmp/fs-k8s-test-install.err; then
    ok "install --dry-run exits 0"
else
    no "install --dry-run exits 0" "$(cat /tmp/fs-k8s-test-install.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$install_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: install --dry-run output"; else no "yamllint: install --dry-run output" "$out"; fi
    out="$(yamllint - < "$install_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: install --dry-run piped through stdin"; else no "yamllint: install --dry-run piped through stdin" "$out"; fi
fi

printf '\n== namespace enforces Pod Security Admission (restricted) ==\n'
if grep -q 'pod-security.kubernetes.io/enforce: restricted' "$install_out"; then
    ok "rendered Namespace enforces PSA restricted"
else
    no "rendered Namespace enforces PSA restricted" "not found in $install_out"
fi
if grep -q 'pod-security.kubernetes.io/warn: restricted' "$install_out" \
    && grep -q 'pod-security.kubernetes.io/audit: restricted' "$install_out"; then
    ok "rendered Namespace holds PSA warn and audit to the same level"
else
    no "rendered Namespace holds PSA warn and audit to the same level" "not found in $install_out"
fi

printf '\n== proxy Deployment rolls when its config changes ==\n'
# A ConfigMap update alone does not restart the pods reading it, so
# fork-sandbox-k8s.sh hashes the rendered nginx.conf into the proxy
# Deployment's POD TEMPLATE annotation -- see the annotation's own comment
# in manifests/k8s/30-proxy.yaml. Confirm the annotation exists, and that it
# actually changes when the config does, by rendering install twice with two
# different K8S_PROXY_UPSTREAM values (the upstream is embedded in
# nginx.conf, so this is a real config change, not a synthetic one).
checksum1="$(sed -n 's/.*checksum\/nginx-conf: "\([0-9a-f]*\)".*/\1/p' "$install_out" | head -n1)"
if [[ -n "$checksum1" ]]; then
    ok "rendered proxy Deployment carries a checksum/nginx-conf annotation"
else
    no "rendered proxy Deployment carries a checksum/nginx-conf annotation" "not found in $install_out"
fi

config_dir2="$(newdir)"; tmpdirs+=("$config_dir2")
cat > "$config_dir2/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://example.com
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
install -m 600 /dev/null "$config_dir2/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$config_dir2/pi.env"
chmod 600 "$config_dir2/pi.env"
install_out2="$(newdir)/install2.yaml"; tmpdirs+=("$(dirname "$install_out2")")
FORK_SANDBOX_CONFIG_DIR="$config_dir2" "$k8s_sh" install --dry-run > "$install_out2" 2>/tmp/fs-k8s-test-install2.err
checksum2="$(sed -n 's/.*checksum\/nginx-conf: "\([0-9a-f]*\)".*/\1/p' "$install_out2" | head -n1)"
if [[ -n "$checksum1" && -n "$checksum2" && "$checksum1" != "$checksum2" ]]; then
    ok "checksum/nginx-conf annotation changes when the proxy config changes"
else
    no "checksum/nginx-conf annotation changes when the proxy config changes" \
        "checksum1='$checksum1' checksum2='$checksum2' ($(cat /tmp/fs-k8s-test-install2.err 2>/dev/null))"
fi
rm -f /tmp/fs-k8s-test-install2.err

printf '\n== nginx -t on the rendered proxy config ==\n'
# The gap this closes: yamllint proves the manifest is valid YAML, not that
# the string embedded in it is a config nginx will actually start on -- see
# 'manifests/k8s: Fix the two directives nginx refuses to start on'. Extract
# the nginx.conf key exactly as the ConfigMap embeds it (indent_block's
# 4-space block-scalar indent), then run nginx -t against it, either with a
# real nginx or with the image manifests/k8s/30-proxy.yaml itself names.
extract_nginx_conf() {
    awk '
        /^  nginx\.conf: \|$/ { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    ' "$1"
}

nginx_conf="$(extract_nginx_conf "$install_out")"
if [[ -z "$nginx_conf" ]]; then
    no "extracted nginx.conf from install --dry-run output" "no nginx.conf block found in $install_out"
else
    nginx_check_dir="$(newdir)"; tmpdirs+=("$nginx_check_dir")
    # nginx resolves `resolver` AT STARTUP, and
    # kube-dns.kube-system.svc.cluster.local only exists inside a real
    # cluster. An IP literal needs no resolution, so this lets the check run
    # outside a cluster -- in THIS COPY ONLY. manifests/k8s/30-proxy.yaml
    # keeps the real in-cluster name; nothing here writes back to it.
    printf '%s\n' "${nginx_conf//kube-dns.kube-system.svc.cluster.local/127.0.0.1}" \
        > "$nginx_check_dir/nginx.conf"
    # $upstream_key is Secret-mounted in a deployed pod; a throwaway stub
    # stands in at the same path the include names.
    # shellcheck disable=SC2016  # $upstream_key is nginx config, not shell
    printf 'set $upstream_key "dummy";\n' > "$nginx_check_dir/upstream-key.conf"

    proxy_image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/manifests/k8s/30-proxy.yaml" | head -n1)"

    nginx_mode=""
    if command -v nginx >/dev/null 2>&1; then
        nginx_mode=native
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        nginx_mode=docker
    fi

    # Runs `nginx -t` against $nginx_check_dir/nginx.conf, with
    # upstream-key.conf staged at the literal absolute path the include
    # names (/etc/nginx/upstream-key.conf). Prints combined output; returns
    # nginx's exit status.
    run_nginx_t() {
        case "$nginx_mode" in
            native)
                # The include and proxy_ssl_trusted_certificate directives
                # are absolute host paths, so testing natively needs the
                # stub staged at the literal path -- which needs root. Fall
                # back to docker rather than fail outright when that is not
                # available.
                if install -Dm644 "$nginx_check_dir/upstream-key.conf" \
                        /etc/nginx/upstream-key.conf 2>/dev/null; then
                    local rc
                    nginx -t -c "$nginx_check_dir/nginx.conf" 2>&1
                    rc=$?
                    rm -f /etc/nginx/upstream-key.conf
                    return "$rc"
                fi
                if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                    echo "(cannot stage /etc/nginx/upstream-key.conf without root; falling back to docker)"
                    nginx_mode=docker
                    run_nginx_t
                    return $?
                fi
                echo "nginx is on PATH but /etc/nginx/upstream-key.conf could not be staged, and no docker fallback is available"
                return 127
                ;;
            docker)
                docker run --rm \
                    -v "$nginx_check_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
                    -v "$nginx_check_dir/upstream-key.conf:/etc/nginx/upstream-key.conf:ro" \
                    "$proxy_image" nginx -t 2>&1
                return $?
                ;;
        esac
    }

    if [[ -z "$nginx_mode" ]]; then
        printf '  SKIP  neither nginx nor a working docker on PATH\n'
    else
        out="$(run_nginx_t)"; rc=$?
        if (( rc == 0 )); then
            ok "nginx -t accepts the rendered proxy config"
        else
            no "nginx -t accepts the rendered proxy config" "$out"
        fi
    fi
fi

submit_out="$(newdir)/submit.yaml"; tmpdirs+=("$(dirname "$submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$submit_out" 2>/tmp/fs-k8s-test-submit.err; then
    ok "submit --dry-run exits 0"
else
    no "submit --dry-run exits 0" "$(cat /tmp/fs-k8s-test-submit.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run output"; else no "yamllint: submit --dry-run output" "$out"; fi
    out="$(yamllint - < "$submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run piped through stdin"; else no "yamllint: submit --dry-run piped through stdin" "$out"; fi
fi
if grep -q 'automountServiceAccountToken: false' "$submit_out"; then
    ok "rendered Job sets automountServiceAccountToken: false"
else
    no "rendered Job sets automountServiceAccountToken: false" "not found in $submit_out"
fi

# fs_emit_prompt_preamble (fork-sandbox-lib.sh), shared with fork-sandbox.sh's
# local path: the rendered handoff.md must carry the clone-path and
# gated-egress blocks, must carry an "Operator inbox" section naming
# /work/inbox, must NOT claim that directory is read-only (it is not, in a
# pod -- see docs/kubernetes-runs.md), and must still carry the operator's
# own handoff text after the preamble.
if grep -q '/work/clone' "$submit_out"; then
    ok "rendered handoff.md preamble names the pod's clone path"
else
    no "rendered handoff.md preamble names the pod's clone path" "not found in $submit_out"
fi
if grep -q "egress is gated to the model proxy" "$submit_out"; then
    ok "rendered handoff.md preamble includes the gated-egress block"
else
    no "rendered handoff.md preamble includes the gated-egress block" \
        "not found in $submit_out"
fi
if grep -q '## Operator inbox' "$submit_out"; then
    ok "rendered handoff.md includes the operator inbox section"
else
    no "rendered handoff.md includes the operator inbox section" \
        "not found in $submit_out"
fi
if grep -q '/work/inbox' "$submit_out"; then
    ok "rendered handoff.md preamble names the pod's inbox path"
else
    no "rendered handoff.md preamble names the pod's inbox path" "not found in $submit_out"
fi
# The negated form ("not mounted read-only", the pod's honest wording) also
# contains the substring 'mounted read-only', so this checks for the old,
# unqualified claim exactly -- the sentence a local run's rendered preamble
# still carries unchanged.
if grep -qF 'The directory is mounted read-only.' "$submit_out"; then
    no "rendered handoff.md does not claim the pod inbox is read-only" \
        "found the unqualified read-only claim in $submit_out"
else
    ok "rendered handoff.md does not claim the pod inbox is read-only"
fi
if grep -qF 'not mounted read-only' "$submit_out"; then
    ok "rendered handoff.md tells the agent the pod inbox is writable"
else
    no "rendered handoff.md tells the agent the pod inbox is writable" \
        "not found in $submit_out"
fi
if grep -q 'Do the thing.' "$submit_out"; then
    ok "rendered handoff.md still carries the operator's own handoff text"
else
    no "rendered handoff.md still carries the operator's own handoff text" \
        "not found in $submit_out"
fi
rm -f /tmp/fs-k8s-test-install.err /tmp/fs-k8s-test-submit.err

printf '\n== fork-sandbox-k8s.sh run --dry-run (fixture config, no cluster) ==\n'
run_out="$(newdir)/run.yaml"; tmpdirs+=("$(dirname "$run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$run_out" 2>/tmp/fs-k8s-test-run.err; then
    ok "run --dry-run exits 0"
else
    no "run --dry-run exits 0" "$(cat /tmp/fs-k8s-test-run.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$run_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: run --dry-run output"; else no "yamllint: run --dry-run output" "$out"; fi
    out="$(yamllint - < "$run_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: run --dry-run piped through stdin"; else no "yamllint: run --dry-run piped through stdin" "$out"; fi
fi
# The strongest proof that `run --dry-run` delegates to cmd_submit's own
# rendering, rather than having grown a second, divergent copy of it: for
# the same arguments the two must render byte-for-byte identical YAML.
if diff -q "$submit_out" "$run_out" >/dev/null 2>&1; then
    ok "run --dry-run renders the same Job YAML as submit --dry-run"
else
    no "run --dry-run renders the same Job YAML as submit --dry-run" \
        "$(diff "$submit_out" "$run_out" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-test-run.err

refuses "run rejects a missing --branch" \
    "run requires --branch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file"
refuses "run rejects a missing project path" \
    "Usage: fork-sandbox-k8s.sh run" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3
refuses "run rejects an unknown option" \
    "unknown option" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --bogus \
    "$proj_dir" "$handoff_file"

if "$k8s_sh" --help 2>&1 | grep -q 'fork-sandbox-k8s.sh run'; then
    ok "usage() mentions run"
else
    no "usage() mentions run" "not found in --help output"
fi
if "$k8s_sh" --help 2>&1 | grep -q 'fork-sandbox-k8s.sh say'; then
    ok "usage() mentions say"
else
    no "usage() mentions say" "not found in --help output"
fi

printf '\n== fork-sandbox-k8s.sh say: argument validation (no cluster) ==\n'
# Every one of these is rejected before cmd_say ever calls kubectl, so all
# of them run with no cluster reachable. The write itself (kubectl exec into
# a real pod) is not covered here -- see the inbox-write.sh section below
# for what of the write path CAN be proven offline.
refuses "say rejects a missing --branch" \
    "say requires --branch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say "hello"
refuses "say rejects a missing message" \
    "nothing to say" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch
refuses "say rejects an empty message" \
    "the message is empty" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch ""
refuses "say rejects an all-whitespace message" \
    "the message is empty" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch "   "
refuses "say rejects an unknown option" \
    "unknown option" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch --bogus "hello"

printf '\n== fork-sandbox-k8s-inbox-write.sh: naming and no-collision (no cluster) ==\n'
# This is the exact script the pod mounts and `say` execs over kubectl exec
# -i -- run directly here, against a plain directory, so its naming and
# no-collision behavior is proven without a cluster or kubectl at all.
inbox_dir="$(newdir)"; tmpdirs+=("$inbox_dir")
fixed_epoch=1700000000
out1="$(printf 'first message\n' | "$inbox_write_sh" "$fixed_epoch" "$inbox_dir")"
if [[ "$out1" == "$inbox_dir"/"$fixed_epoch"-[0-9][0-9].md ]]; then
    ok "generated filename matches <epoch>-<nn>.md"
else
    no "generated filename matches <epoch>-<nn>.md" "got '$out1'"
fi
if [[ -f "$out1" && "$(cat "$out1")" == "first message" ]]; then
    ok "the written file holds the message"
else
    no "the written file holds the message" "'$out1' missing or wrong content"
fi
out2="$(printf 'second message\n' | "$inbox_write_sh" "$fixed_epoch" "$inbox_dir")"
if [[ -n "$out2" && "$out1" != "$out2" ]]; then
    ok "two addenda in the same second do not collide"
else
    no "two addenda in the same second do not collide" "out1='$out1' out2='$out2'"
fi
inbox_count="$(find "$inbox_dir" -maxdepth 1 -type f | wc -l)"
if [[ "$inbox_count" -eq 2 ]]; then
    ok "both addenda land in the inbox directory, nothing else"
else
    no "both addenda land in the inbox directory, nothing else" "$(ls "$inbox_dir")"
fi

# git disables the ext:: transport by default, so a push or fetch built
# without -c protocol.ext.allow=always fails at the git layer with 'fatal:
# transport "ext" not allowed' -- a real cluster confirmed this. This is a
# static assertion on the source rather than a live push/fetch, which no
# cluster here can exercise, but it is exactly the kind of check that stops
# a future refactor from silently dropping the flag on one of the two paths.
if grep -qE 'git -c protocol\.ext\.allow=always .*push' "$k8s_sh"; then
    ok "submit's git push scopes protocol.ext.allow=always"
else
    no "submit's git push scopes protocol.ext.allow=always" "not found in $k8s_sh"
fi
if grep -qE 'git -c protocol\.ext\.allow=always .*fetch' "$k8s_sh"; then
    ok "fetch's git fetch scopes protocol.ext.allow=always"
else
    no "fetch's git fetch scopes protocol.ext.allow=always" "not found in $k8s_sh"
fi
# This push and this fetch both run ON THE HOST, in a repo named on the
# command line, and git would otherwise run that repo's own hooks --
# pre-push on the push side, reference-transaction on the fetch side, since
# fetch here writes straight into refs/heads/$branch rather than a
# remote-tracking ref (githooks(5): reference-transaction "is invoked by any
# Git command that performs reference updates"). Scoped the same way as
# protocol.ext.allow=always, and checked the same way here.
if grep -qE 'git -c protocol\.ext\.allow=always -c core\.hooksPath=/dev/null push' "$k8s_sh"; then
    ok "submit's git push scopes core.hooksPath=/dev/null"
else
    no "submit's git push scopes core.hooksPath=/dev/null" "not found in $k8s_sh"
fi
if grep -qE 'git -c protocol\.ext\.allow=always -c core\.hooksPath=/dev/null fetch' "$k8s_sh"; then
    ok "fetch's git fetch scopes core.hooksPath=/dev/null"
else
    no "fetch's git fetch scopes core.hooksPath=/dev/null" "not found in $k8s_sh"
fi
if grep -qE 'kubectl.*exec -t' "$k8s_sh"; then
    no "no kubectl exec uses -t (would corrupt the pack stream)" "found in $k8s_sh"
else
    ok "no kubectl exec uses -t (would corrupt the pack stream)"
fi

printf '\n== fs_require_scratch_handoff / fs_require_src_project (fork-sandbox-lib.sh) ==\n'
# Unit-level, sourcing the lib directly -- the same level fork-sandbox-clone-
# test.sh tests fs_make_clone at. These are the two checks that let
# fork-sandbox.sh be blanket-approved as its own security boundary, shared
# between the local path and --k8s below; a regression here would silently
# widen what either path accepts.
# Sourced directly into this shell, not a subshell: ok()/no() below have to
# reach the pass/fail counters this file reports at the end, and a subshell
# (command substitution, or the read side of a pipe) would trap them there.
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib_sh"
lib_test_scratch_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-lib-test.XXXXXX)"
tmpdirs+=("$lib_test_scratch_dir")
err="$(mktemp)"

if fs_require_scratch_handoff "$lib_test_scratch_dir/handoff.md" 2>"$err"; then
    ok "a scratch-dir handoff accepted"
else
    no "a scratch-dir handoff accepted" "$(cat "$err")"
fi
if fs_require_scratch_handoff "/tmp/outside-scratch/handoff.md" 2>"$err"; then
    no "a handoff outside scratch is refused"
else
    case "$(cat "$err")" in
        *"must live under /var/tmp/claude-scratch"*)
            ok "a handoff outside scratch is refused" ;;
        *) no "a handoff outside scratch is refused" "$(cat "$err")" ;;
    esac
fi
if fs_require_scratch_handoff "/var/tmp/claude-scratch/forks/x/handoff.md" 2>"$err"; then
    no "a handoff under forks/ is refused"
else
    case "$(cat "$err")" in
        *"must not live under the forks/"*)
            ok "a handoff under forks/ is refused" ;;
        *) no "a handoff under forks/ is refused" "$(cat "$err")" ;;
    esac
fi
if fs_require_src_project "$HOME/src/anything" 2>"$err"; then
    ok "a ~/src project is accepted"
else
    no "a ~/src project is accepted" "$(cat "$err")"
fi
if fs_require_src_project "/tmp/outside-src" 2>"$err"; then
    no "a project outside ~/src is refused"
else
    case "$(cat "$err")" in
        *"must live under ~/src"*)
            ok "a project outside ~/src is refused" ;;
        *) no "a project outside ~/src is refused" "$(cat "$err")" ;;
    esac
fi
rm -f "$err"

printf '\n== fork-sandbox.sh --k8s (fixture config, no cluster) ==\n'
# Real fixtures: unlike --dry-run's own local exit, fs_require_scratch_handoff
# and fs_require_src_project run for every --k8s call, including a --dry-run
# one, so a placeholder path is refused rather than ignored. Only the flag-
# refusal cases below get away with a placeholder -- each fails on its own
# flag before reaching these checks. new_src_project mirrors fork-sandbox-
# prompt-overlay-test.sh's own fixture: a real git repo under the real
# ~/src, since that is the one root fork-sandbox.sh accepts a project from.
new_src_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-k8s-flag-test.XXXXXX")"
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
k8s_flag_proj="$(new_src_project)"; tmpdirs+=("$k8s_flag_proj")
k8s_flag_handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-test.XXXXXX)"
tmpdirs+=("$k8s_flag_handoff_dir")
k8s_flag_handoff="$k8s_flag_handoff_dir/handoff.md"
printf 'Do the k8s thing.\n' > "$k8s_flag_handoff"

refuses "--k8s without --harness pi is refused (default harness)" \
    "needs --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --model moonshotai/kimi-k3 unused-project unused-handoff
refuses "--k8s --harness claude is refused" \
    "needs --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model moonshotai/kimi-k3 unused-project unused-handoff
refuses "--k8s --harness pi-local is refused" \
    "needs --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi-local unused-project unused-handoff
refuses "--k8s --harness codex is refused" \
    "needs --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness codex unused-project unused-handoff

refuses "--k8s --sandbox-args is refused" \
    "--sandbox-args is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --sandbox-args "--unpin-egress" \
    unused-project unused-handoff
refuses "--k8s --claude-args is refused" \
    "--claude-args is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --claude-args "--effort high" \
    unused-project unused-handoff
refuses "--k8s --no-services is refused" \
    "--no-services is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --no-services \
    unused-project unused-handoff
refuses "--k8s --services-trust-ref is refused" \
    "--services-trust-ref is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --services-trust-ref main \
    unused-project unused-handoff
refuses "--k8s --keep-session is refused" \
    "--keep-session is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --keep-session \
    unused-project unused-handoff

refuses "--k8s --checkout is refused as not yet supported" \
    "--checkout is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --checkout HEAD \
    unused-project unused-handoff
refuses "--k8s --pi-args is refused as not yet supported" \
    "--pi-args is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --pi-args "--thinking low" \
    unused-project unused-handoff
refuses "--k8s --context-ro is refused as not yet supported" \
    "--context-ro is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --context-ro /var/tmp/claude-scratch/forks/somewhere \
    unused-project unused-handoff
refuses "--k8s --task-meta is refused as not yet supported" \
    "--task-meta is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --task-meta '{"kind":"implement"}' \
    unused-project unused-handoff
refuses "--k8s --prompts-dir is refused as not yet supported" \
    "--prompts-dir is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --prompts-dir /nonexistent \
    unused-project unused-handoff
refuses "--k8s --review-loop is refused as not yet supported" \
    "--review-loop is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 \
    unused-project unused-handoff
refuses "--k8s --review-model is refused as not yet supported" \
    "--review-model is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-model opus \
    unused-project unused-handoff

refuses "--timeout without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --timeout 100 unused-project unused-handoff
refuses "--keep without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --keep unused-project unused-handoff

refuses "--k8s refuses a handoff outside the scratch dir" \
    "must live under /var/tmp/claude-scratch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    "$k8s_flag_proj" /tmp/fs-k8s-flag-test-outside-scratch.md
refuses "--k8s refuses a project outside ~/src" \
    "must live under ~/src" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    /tmp/fs-k8s-flag-test-outside-src "$k8s_flag_handoff"

# The positive case: --k8s --harness pi --dry-run has to actually reach
# fork-sandbox-k8s.sh, and with the arguments this dispatcher promises. Prove
# it the same way this file already proves `run --dry-run` delegates to
# `submit --dry-run` above: a direct invocation and the dispatcher's must
# render byte-for-byte the same Job YAML for the same branch and model.
dispatch_out="$(newdir)/dispatch.yaml"; tmpdirs+=("$(dirname "$dispatch_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$dispatch_out" 2>/tmp/fs-k8s-flag-test-dispatch.err; then
    ok "--k8s --harness pi --dry-run exits 0"
else
    no "--k8s --harness pi --dry-run exits 0" "$(cat /tmp/fs-k8s-flag-test-dispatch.err)"
fi
direct_out="$(newdir)/direct.yaml"; tmpdirs+=("$(dirname "$direct_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-flag-test-branch --model moonshotai/kimi-k3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$direct_out" 2>/tmp/fs-k8s-flag-test-direct.err; then
    ok "direct run --dry-run (matching args) exits 0"
else
    no "direct run --dry-run (matching args) exits 0" \
        "$(cat /tmp/fs-k8s-flag-test-direct.err)"
fi
rm -f /tmp/fs-k8s-flag-test-direct.err
if diff -q "$direct_out" "$dispatch_out" >/dev/null 2>&1; then
    ok "--k8s renders the same Job YAML as a direct run --dry-run call"
else
    no "--k8s renders the same Job YAML as a direct run --dry-run call" \
        "$(diff "$direct_out" "$dispatch_out" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-flag-test-dispatch.err

# --branch omitted: --k8s generates one, unlike a direct `run` call, which
# requires --branch up front. The generated name follows submit's own
# auto-naming convention (k8s-<timestamp>), embedded in the rendered Job as
# both the fork-sandbox/branch label and the BRANCH env value.
nobranch_out="$(newdir)/nobranch.yaml"; tmpdirs+=("$(dirname "$nobranch_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$nobranch_out" 2>/tmp/fs-k8s-flag-test-nobranch.err; then
    ok "--k8s without --branch exits 0"
else
    no "--k8s without --branch exits 0" "$(cat /tmp/fs-k8s-flag-test-nobranch.err)"
fi
if grep -qE 'value: "k8s-[0-9]{8}-[0-9]{6}"' "$nobranch_out"; then
    ok "--k8s without --branch generates a k8s-<timestamp> branch"
else
    no "--k8s without --branch generates a k8s-<timestamp> branch" \
        "$(cat "$nobranch_out")"
fi
rm -f /tmp/fs-k8s-flag-test-nobranch.err

# --timeout/--keep are accepted with --k8s (--dry-run never reaches the poll
# loop they configure, but they must not be refused as unsupported flags).
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --timeout 42 --keep \
    --branch fs-k8s-flag-test-branch2 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-timeout.err; then
    ok "--k8s accepts --timeout and --keep"
else
    no "--k8s accepts --timeout and --keep" "$(cat /tmp/fs-k8s-flag-test-timeout.err)"
fi
rm -f /tmp/fs-k8s-flag-test-timeout.err

printf '\n== no private-hostname shape anywhere in the repo ==\n'
# Guards the public-repo leak rule (see the fork-sandbox-k8s.sh header): no
# real hostname, cluster name or LAN address may be committed, only
# placeholders such as registry.example or your-cluster. .git is excluded
# (irrelevant to a checkout's own content) and this test file is excluded
# (it must be allowed to name the pattern it looks for without tripping on
# itself). 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 and
# 100.64.0.0/10 are excluded when they appear as CIDR examples (a trailing
# /N) -- this project's own docs and manifests document those ranges by
# name, deliberately, as the excluded set in an egress policy.
# shellcheck disable=SC2016  # the regex is meant literally, not expanded
leak_pattern='[[:alnum:]-]+\.home\.lan\b|[[:alnum:]-]+\.lan\b|192\.168\.[0-9]+\.[0-9]+'
hits="$(grep -rEn --exclude-dir=.git --exclude='fork-sandbox-k8s-test.sh' \
    "$leak_pattern" "$repo_dir" 2>/dev/null \
    | grep -Ev '192\.168\.0\.0/16' || true)"
if [[ -z "$hits" ]]; then
    ok "no private-hostname shape in the repo"
else
    no "no private-hostname shape in the repo" "$hits"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
