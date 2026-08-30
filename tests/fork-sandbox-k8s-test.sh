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
#   - shellcheck on the seven new scripts (the client, the platform plugin,
#     the pod entrypoint, the egress gate, the inbox writer, the review
#     loop, the context extractor).
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
#     it defaults a bare --k8s to --harness pi (still requiring --model),
#     that --harness claude is accepted too (also requiring --model, its
#     own Claude Code model name) while every other --harness value and
#     every flag the cluster path cannot honor is refused by name (never
#     silently dropping one), that --timeout/--keep are refused without
#     --k8s, that a --branch is generated when none is given, and that
#     --dry-run renders byte-for-byte the same Job YAML
#     `fork-sandbox-k8s.sh run --dry-run` does for the same arguments --
#     proving the dispatcher execs rather than growing a divergent copy of
#     anything.
#   - `submit --dry-run --review-loop N`: the four review-loop ConfigMap
#     keys (review-prompt.md, fix-prompt-header.md,
#     code-review-portable-skill.md, review-loop.sh) and the REVIEW_LOOP_CAP
#     / BASE_SHA env vars render only with the flag, never without it; the
#     rendered review-prompt.md and fix-prompt-header.md are byte-for-byte
#     what fs_emit_prompt_preamble + fs_emit_review_prompt_body /
#     fs_emit_fix_prompt_body produce for the same arguments, with no
#     overlay in between -- the property that keeps this from growing a
#     second copy of the prompt text; the rendered review prompt names the
#     POD's skill and verdict paths, never a host path; --review-loop 0 and
#     a non-numeric value are both rejected before any kubectl call.
#   - fork-sandbox.sh --k8s --review-loop N is no longer refused, and
#     --review-model given without --review-loop still is, on either
#     harness -- the same coherence rule the local path applies. On
#     --harness claude, a --review-loop also requires --review-harness pi
#     given explicitly (with a review model, via --review-model or the
#     combined pi/<id> form), since the pod's review leg is always pi and
#     never claude; --review-harness itself is refused outright on
#     --harness pi, where there is nothing to switch.
#   - fork-sandbox-k8s-review-loop.sh, the pod-side review/fix loop, driven
#     directly against a scratch git repo with PI_BIN pointed at a stub --
#     no cluster, no pod, no real pi. Covers every ended value the control
#     flow can reach: approved, findings-then-fix-with-progress,
#     no-progress, harness-error (a bad first verdict line, a missing
#     verdict, and a SYMLINKED verdict whose target is never read), cap,
#     and skipped (branch head already at --base-sha).
#   - `--outbox-max` on both submit and run: a parsed value in each accepted
#     unit (bare digits, K, M, G) reaches both the rendered Job spec's
#     OUTBOX_MAX_BYTES env entry and fs_emit_prompt_preamble's stated MiB
#     figure; run's own copy is forwarded through to submit's render, not
#     just accepted directly; 0/negative/garbage values are rejected before
#     anything is created, for both verbs; combined with --review-loop N,
#     all three preamble renders (not just handoff.md) carry the raised
#     figure; the default still renders when the flag is absent, and its
#     literal matches the pod-side entrypoint's own default; the work
#     emptyDir volume carries no sizeLimit key. The extractor honoring an
#     explicit non-default cap is covered in its own section below.
#   - fork-sandbox-k8s-entrypoint.sh points the bare repo's HEAD at the
#     pushed branch before cloning (so the clone never hits the dangling
#     default HEAD a bare push leaves behind) and no longer uses
#     `checkout -b` (the clone already lands on that branch); a real git
#     bare-repo/push/symbolic-ref/clone sequence confirms the property the
#     fix relies on: no "nonexistent ref" warning, and the clone's HEAD is
#     the pushed branch.
#   - `--context-ro DIR` on both submit and run, under --dry-run: the
#     context-extract.sh ConfigMap key ships unconditionally (like
#     inbox-write.sh), but the `## Gathered context` handoff.md section
#     naming /work/context renders only with the flag; a directory outside
#     /var/tmp/claude-scratch/forks/ and a directory that does not exist
#     are both refused by name before any kubectl call; run --dry-run
#     forwards the flag and renders byte-for-byte the same YAML submit
#     --dry-run does. fork-sandbox-k8s-context-extract.sh's own extraction
#     guards (well-formed, absolute path, `..`, symlink, hard link,
#     over-cap, an existing DEST_DIR) are covered in its own section above,
#     the pod-side half of this same mechanism.
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
review_loop_sh="$repo_dir/scripts/fork-sandbox-k8s-review-loop.sh"
outbox_extract_sh="$repo_dir/scripts/fork-sandbox-k8s-outbox-extract.sh"
context_extract_sh="$repo_dir/scripts/fork-sandbox-k8s-context-extract.sh"

# Sourced directly into this shell, not a subshell: ok()/no() below have to
# reach the pass/fail counters this file reports at the end, and a subshell
# (command substitution, or the read side of a pipe) would trap them there.
# Sourced up here, rather than only where fs_require_scratch_handoff is
# first used further down, because the --review-loop ConfigMap-rendering
# section below also needs fs_emit_prompt_preamble / fs_emit_review_prompt_body
# / fs_emit_fix_prompt_body directly, to compute the byte-for-byte expected
# prompt text.
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib_sh"

printf '== shellcheck ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP  shellcheck not installed\n'
else
    for f in "$k8s_sh" "$platform_generic" "$entrypoint_sh" "$gate_sh" "$inbox_write_sh" "$review_loop_sh" "$outbox_extract_sh" "$context_extract_sh"; do
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

printf '\n== shared proxy Service and static NetworkPolicy carry the role key ==\n'
# fork-sandbox/role: model-proxy, alongside the pre-existing app:
# fork-sandbox-proxy, on the Deployment's pod template, the Service
# selector and the static NetworkPolicy's podSelector -- three places,
# since a --harness claude run's per-run proxy Pod also carries
# app: fork-sandbox-proxy (for the platform agent-egress policy) and would
# otherwise be picked up by either the Service (round-robining pi traffic
# into a proxy that 403s it) or the static policy (whose ingress admits
# every agent pod in the namespace, not just one run's own).
role_key_count="$(grep -cF 'fork-sandbox/role: model-proxy' "$install_out")"
if [[ "$role_key_count" -eq 3 ]]; then
    ok "fork-sandbox/role: model-proxy appears on the Deployment template, Service selector and static NetworkPolicy podSelector"
else
    no "fork-sandbox/role: model-proxy appears on the Deployment template, Service selector and static NetworkPolicy podSelector" \
        "found $role_key_count occurrences in $install_out, want 3"
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

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude ==\n'
# The default (--harness pi, i.e. submit_out above) renders no claude-proxy
# object at all -- the per-run proxy is entirely opt-in.
if grep -q 'claude-proxy' "$submit_out"; then
    no "a pi run (default harness) renders no claude-proxy object" \
        "found 'claude-proxy' in $submit_out"
else
    ok "a pi run (default harness) renders no claude-proxy object"
fi

refuses "--harness takes only pi or claude" \
    "--harness takes 'pi' or 'claude'" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness bogus \
    "$proj_dir" "$handoff_file"

# A fixture HOME carrying a Claude credential, so --harness claude never
# reads the real operator's ~/.claude/.credentials.json. The access token
# is a distinctive fixture string, checked below to never leak into any
# rendered output.
claude_home="$(newdir)"; tmpdirs+=("$claude_home")
mkdir -p "$claude_home/.claude"
claude_fixture_token="fixture-real-secret-token-do-not-leak"
claude_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
cat > "$claude_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "$claude_fixture_token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON

claude_submit_out="$(newdir)/claude-submit.yaml"; tmpdirs+=("$(dirname "$claude_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_submit_out" 2>/tmp/fs-k8s-test-claude-submit.err; then
    ok "submit --dry-run --harness claude exits 0"
else
    no "submit --dry-run --harness claude exits 0" "$(cat /tmp/fs-k8s-test-claude-submit.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    # Line-length excluded, same as the --review-loop render below: this
    # ConfigMap embeds fork-sandbox-inbox-hook.sh's full prose-commented
    # source as a block-scalar value, and long lines in that string are
    # not a YAML structure problem -- see .yamllint's own header comment.
    out="$(yamllint -d "{extends: default, rules: {line-length: disable}}" "$claude_submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run --harness claude output (line-length excluded)"
    else no "yamllint: submit --dry-run --harness claude output (line-length excluded)" "$out"; fi
fi
if grep -q '__RUN_NAME__' "$claude_submit_out" || grep -q '__NAMESPACE__' "$claude_submit_out"; then
    no "submit --dry-run --harness claude leaves no unsubstituted placeholder" \
        "found __RUN_NAME__ or __NAMESPACE__ in $claude_submit_out"
else
    ok "submit --dry-run --harness claude leaves no unsubstituted placeholder"
fi
# fork-sandbox-agent-fs-k8s-test-branch is k8s_safe_name's own output for
# prefix fork-sandbox-agent and branch fs-k8s-test-branch, the same
# derivation the rendered Job/ConfigMap names above already rely on.
claude_run_name="fork-sandbox-agent-fs-k8s-test-branch"
if grep -q '^kind: Pod$' "$claude_submit_out" && grep -q "name: $claude_run_name-claude-proxy\$" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy Pod"
else
    no "rendered manifest carries the per-run claude-proxy Pod" "not found in $claude_submit_out"
fi
if grep -q '^kind: Service$' "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy Service"
else
    no "rendered manifest carries the per-run claude-proxy Service" "not found in $claude_submit_out"
fi
if grep -q "name: $claude_run_name-claude-proxy-conf" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy ConfigMap"
else
    no "rendered manifest carries the per-run claude-proxy ConfigMap" "not found in $claude_submit_out"
fi
if grep -q "secretName: $claude_run_name-claude-token" "$claude_submit_out"; then
    ok "rendered claude-proxy Pod mounts this run's own claude-token Secret"
else
    no "rendered claude-proxy Pod mounts this run's own claude-token Secret" \
        "not found in $claude_submit_out"
fi
if grep -qF 'location = /v1/messages {' "$claude_submit_out" \
    && grep -qF 'location = /v1/messages/count_tokens {' "$claude_submit_out"; then
    ok "rendered claude-proxy nginx.conf forwards exactly the two v1/messages paths"
else
    no "rendered claude-proxy nginx.conf forwards exactly the two v1/messages paths" \
        "not found in $claude_submit_out"
fi
# The manifest's own comments explain in prose that anthropic-beta is
# passed through untouched, so this checks for a directive that would
# actually intercept it (proxy_set_header/proxy_hide_header naming it),
# not for the plain substring, which the prose itself contains.
if grep -qiE '(proxy_set_header|proxy_hide_header)[[:space:]]+anthropic-beta' "$claude_submit_out"; then
    no "rendered claude-proxy nginx.conf does not touch the anthropic-beta header" \
        "found a directive naming anthropic-beta in $claude_submit_out"
else
    ok "rendered claude-proxy nginx.conf does not touch the anthropic-beta header"
fi
if grep -qF 'app: fork-sandbox-proxy' "$claude_submit_out"; then
    ok "the claude-proxy Pod carries the shared app: fork-sandbox-proxy label"
else
    no "the claude-proxy Pod carries the shared app: fork-sandbox-proxy label" \
        "not found in $claude_submit_out"
fi
# fork-sandbox/role: model-proxy is the key that keeps this Pod OUT of the
# shared proxy's own Service and NetworkPolicy selectors (both tightened to
# require it -- see the install-render checks above). This Pod must never
# carry it itself, or it would opt back into both.
if grep -qF 'fork-sandbox/role: model-proxy' "$claude_submit_out"; then
    no "the claude-proxy Pod does not carry fork-sandbox/role: model-proxy" \
        "found in $claude_submit_out"
else
    ok "the claude-proxy Pod does not carry fork-sandbox/role: model-proxy"
fi
if grep -q "^kind: NetworkPolicy\$" "$claude_submit_out" \
    && grep -qF "name: $claude_run_name-claude-proxy" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy NetworkPolicy"
else
    no "rendered manifest carries the per-run claude-proxy NetworkPolicy" \
        "not found in $claude_submit_out"
fi
if grep -qF 'fork-sandbox/role: claude-proxy' "$claude_submit_out" \
    && grep -qF "fork-sandbox/branch: $claude_run_name" "$claude_submit_out" \
    && grep -qF 'app: fork-sandbox-agent' "$claude_submit_out"; then
    ok "the per-run claude-proxy NetworkPolicy scopes ingress to this run's own agent Pod"
else
    no "the per-run claude-proxy NetworkPolicy scopes ingress to this run's own agent Pod" \
        "not found in $claude_submit_out"
fi
# The rendered ConfigMap's claude-credentials.json: sanitized (no
# refreshToken) and carrying the "sandbox" placeholder access token, never
# the fixture's real one -- the whole point of the substitution.
if grep -q '"accessToken": "sandbox"' "$claude_submit_out"; then
    ok "rendered claude-credentials.json carries the sandbox placeholder access token"
else
    no "rendered claude-credentials.json carries the sandbox placeholder access token" \
        "not found in $claude_submit_out"
fi
if grep -q 'refreshToken' "$claude_submit_out"; then
    no "rendered claude-credentials.json carries no refreshToken" \
        "found 'refreshToken' in $claude_submit_out"
else
    ok "rendered claude-credentials.json carries no refreshToken"
fi
if grep -qF "$claude_fixture_token" "$claude_submit_out"; then
    no "the rendered YAML never contains the fixture's real access token" \
        "found the fixture token in $claude_submit_out"
else
    ok "the rendered YAML never contains the fixture's real access token"
fi
if grep -q 'inbox-hook.sh: |' "$claude_submit_out"; then
    ok "rendered ConfigMap carries the inbox-hook.sh key"
else
    no "rendered ConfigMap carries the inbox-hook.sh key" "not found in $claude_submit_out"
fi
if grep -qF 'Addenda are pushed to you automatically' "$claude_submit_out"; then
    ok "rendered handoff.md preamble is worded for the claude harness (pushed, not polled)"
else
    no "rendered handoff.md preamble is worded for the claude harness (pushed, not polled)" \
        "not found in $claude_submit_out"
fi
if grep -q 'name: HARNESS' "$claude_submit_out" \
    && grep -A1 'name: HARNESS' "$claude_submit_out" | grep -q 'value: "claude"'; then
    ok "rendered Job sets HARNESS=claude"
else
    no "rendered Job sets HARNESS=claude" "not found in $claude_submit_out"
fi
if grep -q 'name: CLAUDE_PROXY_BASE_URL' "$claude_submit_out" \
    && grep -A1 'name: CLAUDE_PROXY_BASE_URL' "$claude_submit_out" \
        | grep -qF "http://$claude_run_name-claude-proxy.fork-sandbox-test.svc.cluster.local:8080"; then
    ok "rendered Job's CLAUDE_PROXY_BASE_URL names this run's own proxy Service"
else
    no "rendered Job's CLAUDE_PROXY_BASE_URL names this run's own proxy Service" \
        "not found in $claude_submit_out"
fi
if grep -A1 'name: PROXY_HOST' "$claude_submit_out" \
    | grep -qF "value: \"$claude_run_name-claude-proxy.fork-sandbox-test.svc.cluster.local\""; then
    ok "the egress-gate initContainer's PROXY_HOST names this run's own proxy Service"
else
    no "the egress-gate initContainer's PROXY_HOST names this run's own proxy Service" \
        "not found in $claude_submit_out"
fi
# The pi path's own PROXY_HOST is untouched by any of the above: a plain
# pi run keeps probing the shared proxy.
if grep -A1 'name: PROXY_HOST' "$submit_out" \
    | grep -qF 'value: "fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local"'; then
    ok "a pi run's egress-gate PROXY_HOST still names the shared proxy"
else
    no "a pi run's egress-gate PROXY_HOST still names the shared proxy" "not found in $submit_out"
fi
if grep -q 'would create Secret' "$claude_submit_out"; then
    ok "submit --dry-run --harness claude notes the Secret it would create, without a value"
else
    no "submit --dry-run --harness claude notes the Secret it would create, without a value" \
        "not found in $claude_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-submit.err

# submit_out above carries no --review-model, so it must render no
# REVIEW_MODEL env at all -- the flag is opt-in for both harnesses.
if grep -q 'name: REVIEW_MODEL' "$submit_out"; then
    no "a submit with no --review-model renders no REVIEW_MODEL env" \
        "found 'name: REVIEW_MODEL' in $submit_out"
else
    ok "a submit with no --review-model renders no REVIEW_MODEL env"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --review-model (both harnesses) ==\n'
# REVIEW_MODEL now renders for --harness pi too, not just claude -- the
# review loop always runs pi and needs to know which id to prefer
# regardless of the coding leg's own harness.
pi_rm_submit_out="$(newdir)/pi-rm-submit.yaml"; tmpdirs+=("$(dirname "$pi_rm_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --review-model opus \
    "$proj_dir" "$handoff_file" > "$pi_rm_submit_out" 2>/tmp/fs-k8s-test-pi-rm-submit.err; then
    ok "submit --dry-run --harness pi --review-model exits 0"
else
    no "submit --dry-run --harness pi --review-model exits 0" \
        "$(cat /tmp/fs-k8s-test-pi-rm-submit.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$pi_rm_submit_out" \
    && grep -A1 'name: REVIEW_MODEL' "$pi_rm_submit_out" | grep -q 'value: "opus"'; then
    ok "a pi run's rendered Job sets REVIEW_MODEL when --review-model is given"
else
    no "a pi run's rendered Job sets REVIEW_MODEL when --review-model is given" \
        "not found in $pi_rm_submit_out"
fi
if grep -q 'name: CLAUDE_PROXY_BASE_URL' "$pi_rm_submit_out"; then
    no "a pi run with --review-model still renders no CLAUDE_PROXY_BASE_URL" \
        "found 'name: CLAUDE_PROXY_BASE_URL' in $pi_rm_submit_out"
else
    ok "a pi run with --review-model still renders no CLAUDE_PROXY_BASE_URL"
fi
rm -f /tmp/fs-k8s-test-pi-rm-submit.err

claude_rm_submit_out="$(newdir)/claude-rm-submit.yaml"; tmpdirs+=("$(dirname "$claude_rm_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude --review-model opus \
    "$proj_dir" "$handoff_file" > "$claude_rm_submit_out" 2>/tmp/fs-k8s-test-claude-rm-submit.err; then
    ok "submit --dry-run --harness claude --review-model exits 0"
else
    no "submit --dry-run --harness claude --review-model exits 0" \
        "$(cat /tmp/fs-k8s-test-claude-rm-submit.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$claude_rm_submit_out" \
    && grep -A1 'name: REVIEW_MODEL' "$claude_rm_submit_out" | grep -q 'value: "opus"'; then
    ok "a claude run's rendered Job sets REVIEW_MODEL when --review-model is given"
else
    no "a claude run's rendered Job sets REVIEW_MODEL when --review-model is given" \
        "not found in $claude_rm_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-rm-submit.err

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude: credential expiry ==\n'
claude_home_expired="$(newdir)"; tmpdirs+=("$claude_home_expired")
mkdir -p "$claude_home_expired/.claude"
claude_past_ms=$(( ($(date +%s) - 3600) * 1000 ))
cat > "$claude_home_expired/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "tok", "expiresAt": $claude_past_ms}}
JSON
refuses "an expired Claude credential is refused" \
    "has expired" \
    env HOME="$claude_home_expired" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file"

claude_home_soon="$(newdir)"; tmpdirs+=("$claude_home_soon")
mkdir -p "$claude_home_soon/.claude"
claude_soon_ms=$(( ($(date +%s) + 1800) * 1000 ))
cat > "$claude_home_soon/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "tok", "expiresAt": $claude_soon_ms}}
JSON
soon_out="$(HOME="$claude_home_soon" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" 2>&1 1>/dev/null)"
if [[ "$soon_out" == *"expires in"*"the pod's session dies then"* ]]; then
    ok "a credential expiring within an hour warns but still renders"
else
    no "a credential expiring within an hour warns but still renders" "$soon_out"
fi

printf '\n== fork-sandbox-k8s.sh rm removes the per-run claude-proxy objects ==\n'
# No live cluster here (see this file's own header), so `rm`'s kubectl
# calls are checked against a stub kubectl placed ahead of the real one on
# PATH, logging its own argv rather than touching any cluster.
kubectl_stub_bin="$(newdir)"; tmpdirs+=("$kubectl_stub_bin")
kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$kubectl_log")")
cat > "$kubectl_stub_bin/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$kubectl_log"
exit 0
STUB
chmod +x "$kubectl_stub_bin/kubectl"
if PATH="$kubectl_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" rm --branch fs-k8s-test-branch >/dev/null 2>/tmp/fs-k8s-test-rm.err; then
    ok "rm exits 0 against a stubbed kubectl"
else
    no "rm exits 0 against a stubbed kubectl" "$(cat /tmp/fs-k8s-test-rm.err)"
fi
if grep -q "delete pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch=$claude_run_name --ignore-not-found" "$kubectl_log"; then
    ok "rm issues the label-based delete covering the claude-proxy Pod/Service/Secret/ConfigMap/NetworkPolicy"
else
    no "rm issues the label-based delete covering the claude-proxy Pod/Service/Secret/ConfigMap/NetworkPolicy" \
        "not found in $kubectl_log: $(cat "$kubectl_log")"
fi
if grep -q "delete job $claude_run_name --ignore-not-found" "$kubectl_log" \
    && grep -q "delete configmap $claude_run_name-scripts --ignore-not-found" "$kubectl_log"; then
    ok "rm still issues its original job/configmap deletes too"
else
    no "rm still issues its original job/configmap deletes too" "$(cat "$kubectl_log")"
fi
rm -f /tmp/fs-k8s-test-rm.err

printf '\n== fork-sandbox-k8s.sh install --dry-run excludes 31-claude-proxy.yaml ==\n'
if grep -q 'claude-proxy' "$install_out"; then
    no "install --dry-run renders no claude-proxy object (per-run only)" \
        "found 'claude-proxy' in $install_out"
else
    ok "install --dry-run renders no claude-proxy object (per-run only)"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --review-loop N ==\n'
# Extracts one ConfigMap data key's block-scalar content, reversing
# indent_block's 4-space indent -- the same technique extract_nginx_conf
# above uses for the nginx.conf key, generalized to any key name so it can
# pull review-prompt.md and fix-prompt-header.md back out for a byte-for-byte
# comparison against what fs_emit_prompt_preamble / fs_emit_review_prompt_body
# / fs_emit_fix_prompt_body produce directly.
extract_configmap_key() {
    local key="$1" file="$2"
    awk -v k="  ${key}: |" '
        $0 == k { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    ' "$file"
}

proj_base_sha="$(git -C "$proj_dir" rev-parse HEAD)"
rl_submit_out="$(newdir)/rl-submit.yaml"; tmpdirs+=("$(dirname "$rl_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-branch --model moonshotai/kimi-k3 --review-loop 2 \
    "$proj_dir" "$handoff_file" > "$rl_submit_out" 2>/tmp/fs-k8s-test-rl-submit.err; then
    ok "submit --dry-run --review-loop 2 exits 0"
else
    no "submit --dry-run --review-loop 2 exits 0" "$(cat /tmp/fs-k8s-test-rl-submit.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    # Only structural validity is asserted here, not zero warnings: the
    # rendered review/fix prompt bodies and the skill's own front matter
    # carry long prose lines by nature, which .yamllint's own header comment
    # documents as an accepted, non-error condition for exactly this file.
    out="$(yamllint -d "{extends: default, rules: {line-length: disable}}" "$rl_submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run --review-loop output (line-length excluded)"
    else no "yamllint: submit --dry-run --review-loop output (line-length excluded)" "$out"; fi
fi

# Item: the four review-loop-only ConfigMap keys render with the flag, and
# render in NONE of the earlier no-flag submit_out.
for key in review-prompt.md fix-prompt-header.md code-review-portable-skill.md review-loop.sh; do
    if grep -qF "  $key: |" "$rl_submit_out"; then
        ok "submit --review-loop renders the $key ConfigMap key"
    else
        no "submit --review-loop renders the $key ConfigMap key" "not found in $rl_submit_out"
    fi
    if grep -qF "  $key: |" "$submit_out"; then
        no "submit without --review-loop renders no $key ConfigMap key" "found in $submit_out"
    else
        ok "submit without --review-loop renders no $key ConfigMap key"
    fi
done

# Item: REVIEW_LOOP_CAP / BASE_SHA env present with the flag, absent without
# it. Matched as full Job-spec env entries ("- name: X"), not a bare
# substring search -- entrypoint.sh's own header comment now mentions both
# names in prose, and that comment is embedded in EVERY render, flag or not.
if grep -qF -- '- name: REVIEW_LOOP_CAP' "$rl_submit_out" \
    && grep -qF -- '- name: BASE_SHA' "$rl_submit_out"; then
    ok "submit --review-loop renders REVIEW_LOOP_CAP and BASE_SHA env entries"
else
    no "submit --review-loop renders REVIEW_LOOP_CAP and BASE_SHA env entries" \
        "not found in $rl_submit_out"
fi
if grep -qF -- '- name: REVIEW_LOOP_CAP' "$submit_out" \
    || grep -qF -- '- name: BASE_SHA' "$submit_out"; then
    no "submit without --review-loop renders no REVIEW_LOOP_CAP/BASE_SHA env entries" \
        "found in $submit_out"
else
    ok "submit without --review-loop renders no REVIEW_LOOP_CAP/BASE_SHA env entries"
fi

# Item: the rendered review-prompt.md / fix-prompt-header.md are
# byte-for-byte what fs_emit_prompt_preamble + fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body produce for the same arguments, with NO overlay in
# between -- the property that keeps fork-sandbox-k8s.sh from ever growing a
# second copy of this prompt text. Same assertion style
# tests/fork-sandbox-prompt-overlay-test.sh already uses for the local path.
pod_clone_dir_expected=/work/clone
pod_inbox_dir_expected=/work/inbox
pod_skill_dir_expected=/work/skills/code-review-portable
pod_verdict_file_expected=/work/clone/.git/review-verdict.md
pod_outbox_dir_expected=/work/outbox
expected_rl_review_prompt="$({ fs_emit_prompt_preamble "$pod_clone_dir_expected" \
        "$pod_inbox_dir_expected" pi gated "$pod_outbox_dir_expected" pod
    fs_emit_review_prompt_body fs-k8s-test-rl-branch "$proj_base_sha" \
        "$pod_skill_dir_expected" "$pod_verdict_file_expected" "$pod_inbox_dir_expected"
})"
actual_rl_review_prompt="$(extract_configmap_key review-prompt.md "$rl_submit_out")"
check "review-prompt.md renders byte-for-byte (preamble + body, no overlay)" \
    "$expected_rl_review_prompt" "$actual_rl_review_prompt"

expected_rl_fix_header="$({ fs_emit_prompt_preamble "$pod_clone_dir_expected" \
        "$pod_inbox_dir_expected" pi gated "$pod_outbox_dir_expected" pod
    fs_emit_fix_prompt_body fs-k8s-test-rl-branch "$proj_base_sha"
})"
actual_rl_fix_header="$(extract_configmap_key fix-prompt-header.md "$rl_submit_out")"
check "fix-prompt-header.md renders byte-for-byte (preamble + body, no overlay)" \
    "$expected_rl_fix_header" "$actual_rl_fix_header"

# Item: the rendered review prompt names the POD's paths, never a host path
# -- proof this run's clone-under-/var/tmp and the operator's real project
# path never leak into a prompt a model on the internet is about to read.
if grep -qF '/work/skills/code-review-portable' "$rl_submit_out" \
    && grep -qF '/work/clone/.git/review-verdict.md' "$rl_submit_out"; then
    ok "rendered review prompt names the pod's skill and verdict paths"
else
    no "rendered review prompt names the pod's skill and verdict paths" \
        "not found in $rl_submit_out"
fi
if grep -qF "$proj_dir" "$rl_submit_out"; then
    no "rendered review prompt does not name the host project path" \
        "found $proj_dir in $rl_submit_out"
else
    ok "rendered review prompt does not name the host project path"
fi

# Item: an empty outbox_dir argument (5th positional) omits the whole
# "## Artifact outbox" section -- fs_emit_prompt_preamble is shared with the
# local path, where a run genuinely has no outbox to point at is not a case
# that currently arises (fork-sandbox.sh now always binds one), but the
# function itself still has to degrade cleanly for any future caller that
# passes "".
no_outbox_preamble="$(fs_emit_prompt_preamble "$pod_clone_dir_expected" \
    "$pod_inbox_dir_expected" pi gated "" pod)"
if [[ "$no_outbox_preamble" != *'## Artifact outbox'* ]]; then
    ok "fs_emit_prompt_preamble omits the outbox section when outbox_dir is empty"
else
    no "fs_emit_prompt_preamble omits the outbox section when outbox_dir is empty" \
        "found '## Artifact outbox' despite an empty outbox_dir argument"
fi

# Item: --review-loop 0 and a non-numeric value are both rejected, before
# any kubectl call -- --dry-run proves that, the same way it does for every
# other flag-validation case in this file.
refuses "submit --review-loop 0 is rejected" \
    "--review-loop takes a positive integer" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-bad --model moonshotai/kimi-k3 --review-loop 0 \
    "$proj_dir" "$handoff_file"
refuses "submit --review-loop abc is rejected" \
    "--review-loop takes a positive integer" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-bad --model moonshotai/kimi-k3 --review-loop abc \
    "$proj_dir" "$handoff_file"
rm -f /tmp/fs-k8s-test-rl-submit.err

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

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --outbox-max ==\n'
# --outbox-max threads one byte value into both the rendered Job spec's
# OUTBOX_MAX_BYTES env entry and fs_emit_prompt_preamble's own stated
# figure -- covers bare digits plus each accepted unit suffix, per the
# operator addendum that added this flag ("a parsed value in each accepted
# unit reaches the Job spec and the preamble text").
check_outbox_max_render() {
    local label="$1" out="$2" expected_bytes="$3" expected_mib="$4"
    if grep -qF "value: \"$expected_bytes\"" "$out"; then
        ok "$label: OUTBOX_MAX_BYTES=$expected_bytes in the Job spec"
    else
        no "$label: OUTBOX_MAX_BYTES=$expected_bytes in the Job spec" "not found in $out"
    fi
    if grep -qF "$expected_mib MiB budget" "$out"; then
        ok "$label: preamble states $expected_mib MiB budget"
    else
        no "$label: preamble states $expected_mib MiB budget" "not found in $out"
    fi
}

om_bare_out="$(newdir)/om-bare.yaml"; tmpdirs+=("$(dirname "$om_bare_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-bare --model moonshotai/kimi-k3 \
    --outbox-max "$((100 * 1024 * 1024))" \
    "$proj_dir" "$handoff_file" > "$om_bare_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max <bare digits> exits 0"
else
    no "submit --outbox-max <bare digits> exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max <bare digits>" "$om_bare_out" "$((100 * 1024 * 1024))" 100

om_k_out="$(newdir)/om-k.yaml"; tmpdirs+=("$(dirname "$om_k_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-k --model moonshotai/kimi-k3 --outbox-max 131072K \
    "$proj_dir" "$handoff_file" > "$om_k_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 131072K exits 0"
else
    no "submit --outbox-max 131072K exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 131072K" "$om_k_out" "$((131072 * 1024))" 128

om_m_out="$(newdir)/om-m.yaml"; tmpdirs+=("$(dirname "$om_m_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-m --model moonshotai/kimi-k3 --outbox-max 256M \
    "$proj_dir" "$handoff_file" > "$om_m_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 256M exits 0"
else
    no "submit --outbox-max 256M exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 256M" "$om_m_out" "$((256 * 1024 * 1024))" 256

om_g_out="$(newdir)/om-g.yaml"; tmpdirs+=("$(dirname "$om_g_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-g --model moonshotai/kimi-k3 --outbox-max 2G \
    "$proj_dir" "$handoff_file" > "$om_g_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 2G exits 0"
else
    no "submit --outbox-max 2G exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 2G" "$om_g_out" "$((2 * 1024 * 1024 * 1024))" 2048
rm -f /tmp/fs-k8s-test-om.err

# `run --dry-run --outbox-max` is a different code path than the direct
# submit case above: cmd_run parses its own copy for its own pull-back
# guard, then forwards the raw string into submit_argv for cmd_submit to
# parse again for the Job spec -- the same boundary --review-loop already
# crosses. Assert the forwarded path renders the same figure, not just the
# direct one.
om_run_out="$(newdir)/om-run.yaml"; tmpdirs+=("$(dirname "$om_run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-om-run --model moonshotai/kimi-k3 --outbox-max 256M \
    "$proj_dir" "$handoff_file" > "$om_run_out" 2>/tmp/fs-k8s-test-om-run.err; then
    ok "run --outbox-max 256M exits 0"
else
    no "run --outbox-max 256M exits 0" "$(cat /tmp/fs-k8s-test-om-run.err)"
fi
check_outbox_max_render "run --outbox-max 256M (forwarded to submit)" "$om_run_out" "$((256 * 1024 * 1024))" 256
rm -f /tmp/fs-k8s-test-om-run.err

# Bad values are rejected before anything is created -- same convention as
# the --review-loop bad-value checks above -- for both verbs, since each
# parses its own copy via fs_parse_size_bytes.
for verb in submit run; do
    refuses "$verb --outbox-max 0 is rejected" \
        "Error: size '0' must be greater than zero" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max 0 \
        "$proj_dir" "$handoff_file"
    refuses "$verb --outbox-max -5 is rejected" \
        "Error: invalid size '-5'" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max -5 \
        "$proj_dir" "$handoff_file"
    refuses "$verb --outbox-max bogus is rejected" \
        "Error: invalid size 'bogus'" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max bogus \
        "$proj_dir" "$handoff_file"
done

# --review-loop N --outbox-max SIZE together: render_review_loop_configmap_keys
# is a separate code path from the handoff.md render above, with its own
# fs_emit_prompt_preamble calls for review-prompt.md and fix-prompt-header.md
# -- confirm the raised figure reaches all three preamble renders, not just
# handoff.md. 512K is deliberately sub-1-MiB: fs_emit_prompt_preamble's MiB
# display truncates via integer division (see fork-sandbox-lib.sh), so this
# also pins the pre-existing "0 MiB budget" display for a sub-1-MiB cap
# rather than silently drifting if that rounding ever changes.
om_rl_out="$(newdir)/om-rl.yaml"; tmpdirs+=("$(dirname "$om_rl_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-rl --model moonshotai/kimi-k3 \
    --review-loop 2 --outbox-max 512K \
    "$proj_dir" "$handoff_file" > "$om_rl_out" 2>/tmp/fs-k8s-test-om-rl.err; then
    ok "submit --review-loop 2 --outbox-max 512K exits 0"
else
    no "submit --review-loop 2 --outbox-max 512K exits 0" "$(cat /tmp/fs-k8s-test-om-rl.err)"
fi
om_rl_mib_count="$(grep -c '0 MiB budget' "$om_rl_out" || true)"
check "--review-loop + --outbox-max 512K: all three preambles (handoff.md, review-prompt.md, fix-prompt-header.md) state 0 MiB budget" \
    3 "$om_rl_mib_count"
om_rl_env_count="$(grep -cF 'value: "524288"' "$om_rl_out" || true)"
check "--review-loop + --outbox-max 512K: exactly one OUTBOX_MAX_BYTES Job-spec env entry carries 524288" \
    1 "$om_rl_env_count"
rm -f /tmp/fs-k8s-test-om-rl.err

# Default OUTBOX_MAX_BYTES (FS_OUTBOX_MAX_BYTES, unraised) still renders when
# --outbox-max is absent -- reusing submit_out from the plain submit
# --dry-run render earlier in this file, which was never given the flag.
if grep -qF "value: \"$FS_OUTBOX_MAX_BYTES\"" "$submit_out"; then
    ok "submit without --outbox-max renders the default OUTBOX_MAX_BYTES"
else
    no "submit without --outbox-max renders the default OUTBOX_MAX_BYTES" "not found in $submit_out"
fi
# The pod-side entrypoint has its own literal default (it does not source
# fork-sandbox-lib.sh) -- guard the two from drifting apart silently.
if grep -qF ":=$FS_OUTBOX_MAX_BYTES}" "$entrypoint_sh"; then
    ok "fork-sandbox-k8s-entrypoint.sh's OUTBOX_MAX_BYTES default matches FS_OUTBOX_MAX_BYTES"
else
    no "fork-sandbox-k8s-entrypoint.sh's OUTBOX_MAX_BYTES default matches FS_OUTBOX_MAX_BYTES" \
        "expected literal $FS_OUTBOX_MAX_BYTES in $entrypoint_sh"
fi

# The work emptyDir must never grow a sizeLimit key back (see the comment
# on that volume entry in fork-sandbox-k8s.sh, which explains why -- and
# which itself mentions the word "sizeLimit" in prose, so this checks for
# the YAML key specifically rather than the bare substring). Scoped to the
# work volume's own block, not the whole file, so this would still fail if
# some other volume grew a sizeLimit while `work` stayed clean.
work_volume_block="$(awk '
    /^        - name: work$/ { p=1 }
    p { print }
    p && /emptyDir: \{\}/ { exit }
' "$submit_out")"
if [[ -n "$work_volume_block" ]] && ! grep -qE '^\s*sizeLimit:' <<< "$work_volume_block"; then
    ok "the work emptyDir volume carries no sizeLimit"
else
    no "the work emptyDir volume carries no sizeLimit" "$work_volume_block"
fi

# Captured once, then matched, rather than piped straight into `grep -q`.
# Piping is what made this flaky: `grep -q` exits the moment it matches,
# which closes the pipe under usage()'s `sed`, which then dies of SIGPIPE --
# and with `set -o pipefail` above, that non-zero status fails the whole
# pipeline even though grep found what it was looking for. It only bit the
# `run` check, because `run` appears early enough in the help text that grep
# reliably won the race; `say` appears further down and so usually finished
# writing first. Same latent bug either way.
help_out="$("$k8s_sh" --help 2>&1)"
for verb in run say; do
    if grep -q "fork-sandbox-k8s.sh $verb" <<< "$help_out"; then
        ok "usage() mentions $verb"
    else
        no "usage() mentions $verb" "not found in --help output"
    fi
done

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --context-ro ==\n'
# --context-ro pushes a directory into the pod at /work/context over the
# same gated channel the repository push uses -- see
# docs/kubernetes-runs.md's "Getting files in" section. All of this is
# checked under --dry-run, which touches no kubectl and no cluster: the
# path-under-/var/tmp/claude-scratch/forks/ and directory-exists checks run
# before --dry-run's early exit, and the ConfigMap key / prompt section are
# both computed as part of the same rendered YAML --dry-run prints.
cr_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr.XXXXXX)"; tmpdirs+=("$cr_dir")
printf 'gathered notes\n' > "$cr_dir/notes.md"

cr_submit_out="$(newdir)/cr-submit.yaml"; tmpdirs+=("$(dirname "$cr_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-branch --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" > "$cr_submit_out" 2>/tmp/fs-k8s-test-cr-submit.err; then
    ok "submit --dry-run --context-ro exits 0"
else
    no "submit --dry-run --context-ro exits 0" "$(cat /tmp/fs-k8s-test-cr-submit.err)"
fi
rm -f /tmp/fs-k8s-test-cr-submit.err

if grep -q '^  context-extract.sh: |$' "$cr_submit_out"; then
    ok "submit --context-ro renders the context-extract.sh ConfigMap key"
else
    no "submit --context-ro renders the context-extract.sh ConfigMap key" "not found in $cr_submit_out"
fi
if grep -q '## Gathered context' "$cr_submit_out"; then
    ok "submit --context-ro renders the Gathered context section"
else
    no "submit --context-ro renders the Gathered context section" "not found in $cr_submit_out"
fi
if grep -q '/work/context' "$cr_submit_out"; then
    ok "submit --context-ro names the pod's context path"
else
    no "submit --context-ro names the pod's context path" "not found in $cr_submit_out"
fi

# The context-extract.sh ConfigMap key ships unconditionally, the same way
# inbox-write.sh does even on a run where `say` is never used -- small,
# cheap, and simpler than a second conditionally-rendered key. Only the
# prompt section is conditional on the flag. Reuses submit_out from the
# earlier fixture-config dry-run section above, which was rendered with no
# --context-ro at all.
if grep -q '^  context-extract.sh: |$' "$submit_out"; then
    ok "submit without --context-ro still renders the context-extract.sh ConfigMap key"
else
    no "submit without --context-ro still renders the context-extract.sh ConfigMap key" \
        "not found in $submit_out"
fi
if grep -q '## Gathered context' "$submit_out"; then
    no "submit without --context-ro renders no Gathered context section" \
        "found in $submit_out"
else
    ok "submit without --context-ro renders no Gathered context section"
fi

# A path outside the allowed root is refused by name, before any kubectl call.
cr_outside="$(mktemp -d)"; tmpdirs+=("$cr_outside")
refuses "submit --context-ro outside /var/tmp/claude-scratch/forks/ is refused" \
    "--context-ro must name a directory under" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-bad --model moonshotai/kimi-k3 --context-ro "$cr_outside" \
    "$proj_dir" "$handoff_file"

# A missing directory is refused, even though its name is under the
# allowed root.
refuses "submit --context-ro on a missing directory is refused" \
    "does not exist" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-missing --model moonshotai/kimi-k3 \
    --context-ro /var/tmp/claude-scratch/forks/fs-k8s-test-cr-missing-xyz \
    "$proj_dir" "$handoff_file"

# A directory containing a symlink is refused on the host, before the
# Job is ever created -- `tar cf`'s ordinary walk would turn it into a
# link entry the pod-side extractor also refuses, but only after the
# repository has already been pushed. --dry-run touches no kubectl and no
# cluster, so this check runs (and is observable) with neither.
cr_sym_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-sym.XXXXXX)"; tmpdirs+=("$cr_sym_dir")
ln -s /etc/passwd "$cr_sym_dir/evil"
refuses "submit --context-ro containing a symlink is refused" \
    "contains a symlink" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-sym --model moonshotai/kimi-k3 --context-ro "$cr_sym_dir" \
    "$proj_dir" "$handoff_file"

# A directory containing a hard link is refused on the host too -- `find
# -type l` alone never matches a hard link (it has no distinct file type),
# but `tar cf`'s walk still turns the second name for the same inode into a
# link entry, which the pod-side extractor refuses just like a symlink's,
# only after the Job exists and the repository has already been pushed.
cr_hl_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-hl.XXXXXX)"; tmpdirs+=("$cr_hl_dir")
printf 'x\n' > "$cr_hl_dir/f.txt"
ln "$cr_hl_dir/f.txt" "$cr_hl_dir/g.txt"
refuses "submit --context-ro containing a hard link is refused" \
    "contains a hard-linked file" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-hl --model moonshotai/kimi-k3 --context-ro "$cr_hl_dir" \
    "$proj_dir" "$handoff_file"

# A two-file fixture never queues enough `stat` output to catch this: the
# hard-link check's `awk` used to `exit` on the first duplicate inode,
# which, once there was more than a pipe buffer (64 KiB) of `stat` output
# still to come, closed the pipe out from under a still-writing `stat`,
# took it down with SIGPIPE, and made `find` (and, under this file's
# `set -euo pipefail`, the whole script) fail before "contains a
# hard-linked file" ever printed. A `cp -al`-provisioned cache -- exactly
# the shape this check exists for -- reproduces it: thousands of files in
# one call each via brace expansion and `cp -al`, no per-file forking.
cr_hl_many_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-hl-many.XXXXXX)"; tmpdirs+=("$cr_hl_many_dir")
mkdir "$cr_hl_many_dir/a"
touch "$cr_hl_many_dir/a/f"{1..4000}
cp -al "$cr_hl_many_dir/a" "$cr_hl_many_dir/b"
refuses "submit --context-ro with many hard links still reports its own error" \
    "contains a hard-linked file" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-hl-many --model moonshotai/kimi-k3 --context-ro "$cr_hl_many_dir" \
    "$proj_dir" "$handoff_file"

# `run --dry-run --context-ro` forwards to submit rather than growing its
# own divergent copy -- same property --outbox-max's own run/submit pair
# already proves above, applied to this flag.
cr_run_out="$(newdir)/cr-run.yaml"; tmpdirs+=("$(dirname "$cr_run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-cr-branch --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" > "$cr_run_out" 2>/tmp/fs-k8s-test-cr-run.err; then
    ok "run --dry-run --context-ro exits 0"
else
    no "run --dry-run --context-ro exits 0" "$(cat /tmp/fs-k8s-test-cr-run.err)"
fi
rm -f /tmp/fs-k8s-test-cr-run.err
check "run --dry-run --context-ro renders byte-for-byte the same as submit --dry-run --context-ro" \
    "$(cat "$cr_submit_out")" "$(cat "$cr_run_out")"

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

printf '\n== fork-sandbox-k8s-outbox-extract.sh: extraction guards (no cluster) ==\n'
# This script is the actual security boundary for the outbox pull-back --
# what stands between a hostile or confused pod's tar stream and the host
# filesystem (see its own header comment for the full threat model). Driven
# directly here against hand-built tar fixtures, the same way the
# inbox-write.sh section above drives that script directly: no cluster, no
# kubectl, no real pod involved.
#
# GNU tar sanitizes dangerous member names AT CREATION TIME by default (it
# silently strips a leading `/` and a leading `../`), which is exactly the
# opposite of what a fixture for this test needs -- so the absolute-path and
# `..`-component fixtures below are built with `tar -P`/`--absolute-names`,
# which preserves the member name as given. The warning tar prints to
# stderr while doing that ("Removing leading...") is fixture-creation noise,
# not a signal, so it is redirected away rather than asserted on.

# well-formed: the shape `tar cf - -C /work/outbox .` on a real pod
# produces -- relative entries, no `..`, no links. Must extract cleanly.
of_src="$(newdir)"; tmpdirs+=("$of_src")
mkdir -p "$of_src/sub"
printf 'hello\n' > "$of_src/foo.txt"
printf 'world\n' > "$of_src/sub/bar.txt"
of_parent="$(newdir)"; tmpdirs+=("$of_parent")
of_wf_tar="$of_parent/wf.tar"
tar cf "$of_wf_tar" -C "$of_src" .
of_wf_dest="$of_parent/wf_dest"
if "$outbox_extract_sh" "$of_wf_tar" "$of_wf_dest" >/tmp/fs-k8s-outbox-wf.err 2>&1; then
    ok "well-formed archive extracts"
else
    no "well-formed archive extracts" "$(cat /tmp/fs-k8s-outbox-wf.err)"
fi
if [[ "$(cat "$of_wf_dest/foo.txt" 2>/dev/null)" == "hello" \
    && "$(cat "$of_wf_dest/sub/bar.txt" 2>/dev/null)" == "world" ]]; then
    ok "well-formed archive's files land with their content intact"
else
    no "well-formed archive's files land with their content intact" \
        "$(find "$of_wf_dest" 2>&1)"
fi
rm -f /tmp/fs-k8s-outbox-wf.err

# absolute path: refused outright, whole archive, before anything is
# extracted -- the dest directory must not even be created.
of_abs_src="$(newdir)"; tmpdirs+=("$of_abs_src")
mkdir -p "$of_abs_src/a"
printf 'x\n' > "$of_abs_src/a/f.txt"
of_abs_parent="$(newdir)"; tmpdirs+=("$of_abs_parent")
of_abs_tar="$of_abs_parent/abs.tar"
( cd "$of_abs_src" && tar -P -cf "$of_abs_tar" "$of_abs_src/a/f.txt" 2>/dev/null )
of_abs_dest="$of_abs_parent/abs_dest"
refuses "absolute path is refused" \
    "contains an absolute path" \
    "$outbox_extract_sh" "$of_abs_tar" "$of_abs_dest"
if [[ ! -e "$of_abs_dest" ]]; then
    ok "absolute-path archive: nothing is extracted"
else
    no "absolute-path archive: nothing is extracted" "$of_abs_dest exists"
fi

# `..` path component: same refuse-the-whole-archive treatment.
of_dd_src="$(newdir)"; tmpdirs+=("$of_dd_src")
mkdir -p "$of_dd_src/a"
printf 'x\n' > "$of_dd_src/a/f.txt"
of_dd_parent="$(newdir)"; tmpdirs+=("$of_dd_parent")
of_dd_tar="$of_dd_parent/dd.tar"
( cd "$of_dd_src" && tar -P -cf "$of_dd_tar" a/../a/f.txt 2>/dev/null )
of_dd_dest="$of_dd_parent/dd_dest"
refuses "a '..' path component is refused" \
    "contains a '..' path component" \
    "$outbox_extract_sh" "$of_dd_tar" "$of_dd_dest"
if [[ ! -e "$of_dd_dest" ]]; then
    ok "'..'-component archive: nothing is extracted"
else
    no "'..'-component archive: nothing is extracted" "$of_dd_dest exists"
fi

# symlink: refused as a link entry, listed and rejected before extraction
# even starts -- this is the guard that closes the kubectl-cp-CVE-shaped
# escape the script's header describes (a symlink entry followed by a
# second entry that writes through it).
of_sym_src="$(newdir)"; tmpdirs+=("$of_sym_src")
ln -s /etc/passwd "$of_sym_src/evil"
of_sym_parent="$(newdir)"; tmpdirs+=("$of_sym_parent")
of_sym_tar="$of_sym_parent/sym.tar"
tar cf "$of_sym_tar" -C "$of_sym_src" .
of_sym_dest="$of_sym_parent/sym_dest"
refuses "a symlink entry is refused" \
    "contains a link entry" \
    "$outbox_extract_sh" "$of_sym_tar" "$of_sym_dest"
if [[ ! -e "$of_sym_dest" ]]; then
    ok "symlink archive: nothing is extracted"
else
    no "symlink archive: nothing is extracted" "$of_sym_dest exists"
fi

# hard link: a distinct code path from the symlink check above (tar -tvf
# marks a hard link with a leading 'h' and a trailing "link to TARGET",
# not the 'l' mode a symlink gets), so it needs its own fixture.
of_hl_src="$(newdir)"; tmpdirs+=("$of_hl_src")
printf 'x\n' > "$of_hl_src/f.txt"
ln "$of_hl_src/f.txt" "$of_hl_src/g.txt"
of_hl_parent="$(newdir)"; tmpdirs+=("$of_hl_parent")
of_hl_tar="$of_hl_parent/hl.tar"
tar cf "$of_hl_tar" -C "$of_hl_src" .
of_hl_dest="$of_hl_parent/hl_dest"
refuses "a hard-link entry is refused" \
    "contains a link entry" \
    "$outbox_extract_sh" "$of_hl_tar" "$of_hl_dest"
if [[ ! -e "$of_hl_dest" ]]; then
    ok "hard-link archive: nothing is extracted"
else
    no "hard-link archive: nothing is extracted" "$of_hl_dest exists"
fi

# oversized: refused on the streaming byte-size cap, before tar -tvf is
# even run over it.
of_big_src="$(newdir)"; tmpdirs+=("$of_big_src")
dd if=/dev/zero of="$of_big_src/big.bin" bs=1M count=65 2>/dev/null
of_big_parent="$(newdir)"; tmpdirs+=("$of_big_parent")
of_big_tar="$of_big_parent/big.tar"
tar cf "$of_big_tar" -C "$of_big_src" .
of_big_dest="$of_big_parent/big_dest"
# The needle names both the outbox-extract label and the tar file: this is
# a failure surfaced through the shared context-extract.sh implementation,
# and an operator reading it must see which script and which archive were
# rejected, not "context-extract" naming a DEST_DIR that may belong to a
# run that never used --context-ro at all.
refuses "an over-cap archive is refused" \
    "fork-sandbox-k8s-outbox-extract: $of_big_tar" \
    "$outbox_extract_sh" "$of_big_tar" "$of_big_dest"
if [[ ! -e "$of_big_dest" ]]; then
    ok "over-cap archive: nothing is extracted"
else
    no "over-cap archive: nothing is extracted" "$of_big_dest exists"
fi

# An explicit $3 cap, not just the default -- the argument fork-sandbox-k8s.sh
# actually passes (its own resolved outbox_max_bytes), so this exercises the
# real call shape rather than only the no-arg default the two cases above use.
of_cap_src="$(newdir)"; tmpdirs+=("$of_cap_src")
printf 'a small file, well under any default cap\n' > "$of_cap_src/small.txt"
of_cap_parent="$(newdir)"; tmpdirs+=("$of_cap_parent")
of_cap_tar="$of_cap_parent/cap.tar"
tar cf "$of_cap_tar" -C "$of_cap_src" .
of_cap_dest_lo="$of_cap_parent/cap_dest_lo"
refuses "an explicit low \$3 cap refuses an archive under the default cap" \
    "byte cap; refusing it" \
    "$outbox_extract_sh" "$of_cap_tar" "$of_cap_dest_lo" 10
if [[ ! -e "$of_cap_dest_lo" ]]; then
    ok "explicit low \$3 cap: nothing is extracted"
else
    no "explicit low \$3 cap: nothing is extracted" "$of_cap_dest_lo exists"
fi
of_cap_dest_hi="$of_cap_parent/cap_dest_hi"
if "$outbox_extract_sh" "$of_cap_tar" "$of_cap_dest_hi" 1000000 \
    >/tmp/fs-k8s-outbox-cap.err 2>&1; then
    ok "an explicit high \$3 cap extracts the same archive"
else
    no "an explicit high \$3 cap extracts the same archive" "$(cat /tmp/fs-k8s-outbox-cap.err)"
fi
if [[ "$(cat "$of_cap_dest_hi/small.txt" 2>/dev/null)" == "a small file, well under any default cap" ]]; then
    ok "explicit high \$3 cap: the file lands with its content intact"
else
    no "explicit high \$3 cap: the file lands with its content intact" \
        "$(find "$of_cap_dest_hi" 2>&1)"
fi
rm -f /tmp/fs-k8s-outbox-cap.err

# A $3 above 256 MiB -- the shared context-extract.sh script's own default
# ceiling, meant for --context-ro -- must still be honored, not silently
# reduced to it: --outbox-max is documented as having no upper ceiling, so
# an archive between 256 MiB and the caller's $3 must still extract. This
# pins the regression where fork-sandbox-k8s-outbox-extract.sh became a thin
# wrapper around fork-sandbox-k8s-context-extract.sh and inherited its
# literal without overriding it.
of_huge_src="$(newdir)"; tmpdirs+=("$of_huge_src")
truncate -s 257M "$of_huge_src/big.bin"
of_huge_parent="$(newdir)"; tmpdirs+=("$of_huge_parent")
of_huge_tar="$of_huge_parent/huge.tar"
tar cf "$of_huge_tar" -C "$of_huge_src" .
of_huge_dest="$of_huge_parent/huge_dest"
if "$outbox_extract_sh" "$of_huge_tar" "$of_huge_dest" $((300 * 1024 * 1024)) \
        >/tmp/fs-k8s-outbox-huge.err 2>&1; then
    ok "a \$3 above 256 MiB is honored, not silently capped there"
else
    no "a \$3 above 256 MiB is honored, not silently capped there" \
        "$(cat /tmp/fs-k8s-outbox-huge.err)"
fi
rm -f /tmp/fs-k8s-outbox-huge.err
# These three fixtures are ~257 MiB apiece (source, tar, extracted copy);
# /tmp is a tmpfs, so held-until-EXIT here (this suite's default cleanup)
# means ~770 MiB of RAM for the rest of the run. Removed the moment this
# one assertion is done rather than joining tmpdirs for EXIT-time cleanup.
rm -rf -- "$of_huge_src" "$of_huge_parent"

printf '\n== fork-sandbox-k8s-context-extract.sh: extraction guards (no cluster) ==\n'
# The pod-side half of the --context-ro push -- what stands between a
# pushed tar stream and the pod's filesystem (see its own header comment
# for the full threat model). Driven directly here against hand-built tar
# fixtures on stdin, the same way the outbox-extract section above drives
# that script directly against a tar file argument: no cluster, no
# kubectl, no real pod involved. MAX_BYTES is a required argument for this
# script (unlike outbox-extract.sh's optional $3), so every case below
# passes one explicitly.

# well-formed: the shape `tar cf - -C CONTEXT_DIR .` on the host produces
# -- relative entries, no `..`, no links. Must extract cleanly.
cf_src="$(newdir)"; tmpdirs+=("$cf_src")
mkdir -p "$cf_src/sub"
printf 'hello\n' > "$cf_src/foo.txt"
printf 'world\n' > "$cf_src/sub/bar.txt"
cf_parent="$(newdir)"; tmpdirs+=("$cf_parent")
cf_wf_tar="$cf_parent/wf.tar"
tar cf "$cf_wf_tar" -C "$cf_src" .
cf_wf_dest="$cf_parent/wf_dest"
if "$context_extract_sh" "$cf_wf_dest" 100000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-wf.err 2>&1; then
    ok "well-formed archive extracts"
else
    no "well-formed archive extracts" "$(cat /tmp/fs-k8s-ctx-wf.err)"
fi
if [[ "$(cat "$cf_wf_dest/foo.txt" 2>/dev/null)" == "hello" \
    && "$(cat "$cf_wf_dest/sub/bar.txt" 2>/dev/null)" == "world" ]]; then
    ok "well-formed archive's files land with their content intact"
else
    no "well-formed archive's files land with their content intact" \
        "$(find "$cf_wf_dest" 2>&1)"
fi
rm -f /tmp/fs-k8s-ctx-wf.err

# refuses an existing DEST_DIR: a second push must not merge into a first.
cf_exist_dest="$cf_parent/exist_dest"
mkdir -p "$cf_exist_dest"
refuses "an existing DEST_DIR is refused" \
    "already exists; refusing" \
    "$context_extract_sh" "$cf_exist_dest" 100000000 < "$cf_wf_tar"

# absolute path: refused outright, whole archive, before anything is
# extracted -- the dest directory must not even be created.
cf_abs_src="$(newdir)"; tmpdirs+=("$cf_abs_src")
mkdir -p "$cf_abs_src/a"
printf 'x\n' > "$cf_abs_src/a/f.txt"
cf_abs_parent="$(newdir)"; tmpdirs+=("$cf_abs_parent")
cf_abs_tar="$cf_abs_parent/abs.tar"
( cd "$cf_abs_src" && tar -P -cf "$cf_abs_tar" "$cf_abs_src/a/f.txt" 2>/dev/null )
cf_abs_dest="$cf_abs_parent/abs_dest"
refuses "absolute path is refused" \
    "contains an absolute path" \
    "$context_extract_sh" "$cf_abs_dest" 100000000 < "$cf_abs_tar"
if [[ ! -e "$cf_abs_dest" ]]; then
    ok "absolute-path archive: nothing is extracted"
else
    no "absolute-path archive: nothing is extracted" "$cf_abs_dest exists"
fi

# `..` path component: same refuse-the-whole-archive treatment.
cf_dd_src="$(newdir)"; tmpdirs+=("$cf_dd_src")
mkdir -p "$cf_dd_src/a"
printf 'x\n' > "$cf_dd_src/a/f.txt"
cf_dd_parent="$(newdir)"; tmpdirs+=("$cf_dd_parent")
cf_dd_tar="$cf_dd_parent/dd.tar"
( cd "$cf_dd_src" && tar -P -cf "$cf_dd_tar" a/../a/f.txt 2>/dev/null )
cf_dd_dest="$cf_dd_parent/dd_dest"
refuses "a '..' path component is refused" \
    "contains a '..' path component" \
    "$context_extract_sh" "$cf_dd_dest" 100000000 < "$cf_dd_tar"
if [[ ! -e "$cf_dd_dest" ]]; then
    ok "'..'-component archive: nothing is extracted"
else
    no "'..'-component archive: nothing is extracted" "$cf_dd_dest exists"
fi

# symlink: refused as a link entry, listed and rejected before extraction
# even starts.
cf_sym_src="$(newdir)"; tmpdirs+=("$cf_sym_src")
ln -s /etc/passwd "$cf_sym_src/evil"
cf_sym_parent="$(newdir)"; tmpdirs+=("$cf_sym_parent")
cf_sym_tar="$cf_sym_parent/sym.tar"
tar cf "$cf_sym_tar" -C "$cf_sym_src" .
cf_sym_dest="$cf_sym_parent/sym_dest"
refuses "a symlink entry is refused" \
    "contains a link entry" \
    "$context_extract_sh" "$cf_sym_dest" 100000000 < "$cf_sym_tar"
if [[ ! -e "$cf_sym_dest" ]]; then
    ok "symlink archive: nothing is extracted"
else
    no "symlink archive: nothing is extracted" "$cf_sym_dest exists"
fi

# hard link: a distinct code path from the symlink check above.
cf_hl_src="$(newdir)"; tmpdirs+=("$cf_hl_src")
printf 'x\n' > "$cf_hl_src/f.txt"
ln "$cf_hl_src/f.txt" "$cf_hl_src/g.txt"
cf_hl_parent="$(newdir)"; tmpdirs+=("$cf_hl_parent")
cf_hl_tar="$cf_hl_parent/hl.tar"
tar cf "$cf_hl_tar" -C "$cf_hl_src" .
cf_hl_dest="$cf_hl_parent/hl_dest"
refuses "a hard-link entry is refused" \
    "contains a link entry" \
    "$context_extract_sh" "$cf_hl_dest" 100000000 < "$cf_hl_tar"
if [[ ! -e "$cf_hl_dest" ]]; then
    ok "hard-link archive: nothing is extracted"
else
    no "hard-link archive: nothing is extracted" "$cf_hl_dest exists"
fi

# oversized: refused on the spooled byte-size cap, before tar -tvf is even
# run over it.
cf_big_src="$(newdir)"; tmpdirs+=("$cf_big_src")
dd if=/dev/zero of="$cf_big_src/big.bin" bs=1M count=2 2>/dev/null
cf_big_parent="$(newdir)"; tmpdirs+=("$cf_big_parent")
cf_big_tar="$cf_big_parent/big.tar"
tar cf "$cf_big_tar" -C "$cf_big_src" .
cf_big_dest="$cf_big_parent/big_dest"
refuses "an over-cap archive is refused" \
    "byte cap; refusing it" \
    "$context_extract_sh" "$cf_big_dest" 100 < "$cf_big_tar"
if [[ ! -e "$cf_big_dest" ]]; then
    ok "over-cap archive: nothing is extracted"
else
    no "over-cap archive: nothing is extracted" "$cf_big_dest exists"
fi

# the same small archive under a generous cap still extracts -- confirms
# the cap check compares against the given MAX_BYTES, not a hidden default.
cf_hi_dest="$cf_parent/wf_dest_hi"
if "$context_extract_sh" "$cf_hi_dest" 1000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-hi.err 2>&1; then
    ok "the same well-formed archive extracts under a generous cap"
else
    no "the same well-formed archive extracts under a generous cap" "$(cat /tmp/fs-k8s-ctx-hi.err)"
fi
rm -f /tmp/fs-k8s-ctx-hi.err

# The 256 MiB literal on this stdin/kubectl-exec path cannot be raised by
# MAX_BYTES, however large -- there is deliberately no env var for that (see
# fork-sandbox-k8s-context-extract.sh's own header): a caller able to set an
# env var alongside MAX_BYTES on this path could raise its own ceiling, and
# the whole point of the literal is that it cannot. First, a small archive
# still extracts when MAX_BYTES is far above the literal -- clamping lowers
# the effective cap, it does not error out just because the caller asked
# for more than the literal allows.
cf_big_max_dest="$cf_parent/wf_dest_big_max"
if "$context_extract_sh" "$cf_big_max_dest" 100000000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-bigmax.err 2>&1; then
    ok "a small archive extracts under a MAX_BYTES far above the literal"
else
    no "a small archive extracts under a MAX_BYTES far above the literal" \
        "$(cat /tmp/fs-k8s-ctx-bigmax.err)"
fi
rm -f /tmp/fs-k8s-ctx-bigmax.err

# Second, an archive over the literal but comfortably under MAX_BYTES is
# still refused -- proving the clamp itself needs a real >256 MiB fixture,
# since there is no longer a way to shrink the literal for a cheap one.
# Sparse and removed the moment this assertion completes, the same as the
# of_huge_* fixture above: /tmp is a tmpfs, and this is the only place left
# in the suite that needs a fixture this size.
cf_clamp_src="$(newdir)"; tmpdirs+=("$cf_clamp_src")
truncate -s 257M "$cf_clamp_src/big.bin"
cf_clamp_parent="$(newdir)"; tmpdirs+=("$cf_clamp_parent")
cf_clamp_tar="$cf_clamp_parent/clamp.tar"
tar cf "$cf_clamp_tar" -C "$cf_clamp_src" .
cf_clamp_dest="$cf_clamp_parent/clamp_dest"
refuses "a MAX_BYTES far above the literal is still clamped down to it" \
    "byte cap; refusing it" \
    "$context_extract_sh" "$cf_clamp_dest" 100000000000 < "$cf_clamp_tar"
if [[ ! -e "$cf_clamp_dest" ]]; then
    ok "clamped-to-literal archive: nothing is extracted"
else
    no "clamped-to-literal archive: nothing is extracted" "$cf_clamp_dest exists"
fi
rm -rf -- "$cf_clamp_src" "$cf_clamp_parent"

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

printf '\n== fork-sandbox-k8s-review-loop.sh: control flow (no cluster) ==\n'
# Driven directly against a scratch git repo, with PI_BIN pointed at a tiny
# stub that reads the prompt off stdin (discarded) and writes a canned
# verdict / commit per the test's own logic. No cluster, no pod, no real pi
# -- this is the same reason fork-sandbox-k8s-inbox-write.sh's own section
# above runs the real script directly rather than re-implementing its logic
# in the test.
rl_sh="$repo_dir/scripts/fork-sandbox-k8s-review-loop.sh"

# A fresh one-commit-past-base git repo, with review-prompt.md/fix-header.md
# fixtures (their content is irrelevant to the control flow under test --
# the stub ignores stdin) and a work dir for the loop's own artifacts.
# Returns "repo base_sha work_dir review_prompt fix_header out" on stdout,
# callers split with `read`. The fixture's own root is `dirname "$repo"`,
# which is what callers register with tmpdirs for cleanup.
new_rl_fixture() {
    local d repo base_sha work
    d="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-test.XXXXXX)"
    repo="$d/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=t \
        commit -q --allow-empty -m init
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=t \
        commit -q --allow-empty -m "the coding leg's work"
    printf 'review prompt fixture\n' > "$d/review-prompt.md"
    printf 'fix header fixture\n' > "$d/fix-header.md"
    work="$d/work"
    printf '%s %s %s %s %s %s\n' "$repo" "$base_sha" "$work" \
        "$d/review-prompt.md" "$d/fix-header.md" "$d/review-loop.json"
}

# jq -r '.ended' / '.iterations | length' / '.iterations[N].FIELD' against
# the written review-loop.json, for terse assertions below.
rl_json() { jq -r "$2" "$1" 2>/dev/null; }

printf '\n-- approved on the first review --\n'
stub_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir")
cat > "$stub_dir/pi-approve" <<'STUB'
#!/bin/sh
cat >/dev/null
echo APPROVED > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir/pi-approve"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir/pi-approve" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "approved: ended=approved" "approved" "$(rl_json "$out" '.ended')"
check "approved: one iteration recorded" "1" "$(rl_json "$out" '.iterations | length')"
check "approved: findings=0" "0" "$(rl_json "$out" '.iterations[0].findings')"

printf '\n-- findings, then a fix leg that makes progress --\n'
stub_dir2="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir2")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
counter_file="$stub_dir2/count"
cat > "$stub_dir2/pi-dispatch" <<STUB
#!/bin/sh
cat >/dev/null
n=0
[ -f "$counter_file" ] && n=\$(cat "$counter_file")
n=\$((n + 1))
echo \$n > "$counter_file"
if [ \$((n % 2)) -eq 1 ]; then
    printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n' > "\$RL_TEST_VERDICT"
else
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=t \\
        commit -q --allow-empty -m "fix \$n"
fi
exit 0
STUB
chmod +x "$stub_dir2/pi-dispatch"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir2/pi-dispatch" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "progress: ended=cap (findings still open after 2 iterations)" \
    "cap" "$(rl_json "$out" '.ended')"
check "progress: iteration 1 findings=1" "1" "$(rl_json "$out" '.iterations[0].findings')"
check "progress: iteration 1 head_after != head_before" "true" \
    "$(rl_json "$out" 'if .iterations[0].head_after != .iterations[0].head_before then "true" else "false" end')"
check "progress: iteration 1 commits_added=1" "1" "$(rl_json "$out" '.iterations[0].commits_added')"
if [[ -f "$work/fix-prompt-1.md" ]] && grep -qF 'fix header fixture' "$work/fix-prompt-1.md" \
    && grep -qF 'something is wrong at foo.c:12' "$work/fix-prompt-1.md"; then
    ok "the fix prompt concatenates the fix header and the verdict"
else
    no "the fix prompt concatenates the fix header and the verdict" \
        "$(cat "$work/fix-prompt-1.md" 2>/dev/null)"
fi

printf '\n-- no-progress: the fix leg commits nothing --\n'
stub_dir3="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir3")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir3/pi-findings-only" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir3/pi-findings-only"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir3/pi-findings-only" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 3 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "no-progress: ended=no-progress" "no-progress" "$(rl_json "$out" '.ended')"
check "no-progress: exactly one iteration ran" "1" "$(rl_json "$out" '.iterations | length')"

printf '\n-- harness-error: neither APPROVED nor FINDINGS --\n'
stub_dir4="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir4")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir4/pi-garbage" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'this is not a verdict\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir4/pi-garbage"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir4/pi-garbage" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "bad first line: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"

printf '\n-- harness-error: the review leg writes no verdict at all --\n'
stub_dir5="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir5")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir5/pi-silent" <<'STUB'
#!/bin/sh
cat >/dev/null
exit 0
STUB
chmod +x "$stub_dir5/pi-silent"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir5/pi-silent" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "no verdict written: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"

printf '\n-- harness-error: a SYMLINK at the verdict path is refused --\n'
stub_dir6="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir6")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
rl_fixture_dir6="$(dirname "$repo")"; tmpdirs+=("$rl_fixture_dir6")
secret_target="$rl_fixture_dir6/secret-target"
printf 'this must never be read\n' > "$secret_target"
cat > "$stub_dir6/pi-symlink" <<STUB
#!/bin/sh
cat >/dev/null
ln -sf "$secret_target" "\$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir6/pi-symlink"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir6/pi-symlink" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "symlinked verdict: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"
# A copy is only ever made AFTER the symlink check passes, so no
# review-verdict-*.md copy existing at all is itself proof the target was
# never read -- but check any that do exist too, in case that invariant
# ever regresses silently.
secret_leaked=false
while IFS= read -r verdict_copy_file; do
    [[ -n "$verdict_copy_file" ]] || continue
    grep -qF 'this must never be read' "$verdict_copy_file" 2>/dev/null && secret_leaked=true
done < <(find "$work" -maxdepth 1 -name 'review-verdict-*.md' 2>/dev/null)
if [[ "$secret_leaked" == true ]]; then
    no "symlinked verdict: the symlink target is never read" \
        "the secret target's content leaked into $work"
else
    ok "symlinked verdict: the symlink target is never read"
fi

printf '\n-- skipped: branch head already at --base-sha --\n'
stub_dir7="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir7")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
current_head="$(git -C "$repo" rev-parse HEAD)"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir7/should-never-run" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$current_head" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "skipped: ended=skipped" "skipped" "$(rl_json "$out" '.ended')"
check "skipped: no iterations ran" "0" "$(rl_json "$out" '.iterations | length')"


printf '\n== fs_require_scratch_handoff / fs_require_src_project (fork-sandbox-lib.sh) ==\n'
# Unit-level, sourcing the lib directly -- the same level fork-sandbox-clone-
# test.sh tests fs_make_clone at. These are the two checks that let
# fork-sandbox.sh be blanket-approved as its own security boundary, shared
# between the local path and --k8s below; a regression here would silently
# widen what either path accepts. lib_sh was already sourced near the top of
# this file.
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

printf '\n== fs_parse_size_bytes (fork-sandbox-lib.sh) ==\n'
# Unit-level, sourcing the lib directly -- the one place --outbox-max's
# accepted units and rejections are defined, shared by fork-sandbox.sh and
# fork-sandbox-k8s.sh below rather than each parsing it their own way.
check "bare digits mean bytes" "12345" "$(fs_parse_size_bytes 12345)"
check "K means KiB" "$((512 * 1024))" "$(fs_parse_size_bytes 512K)"
check "a lowercase k also means KiB" "$((512 * 1024))" "$(fs_parse_size_bytes 512k)"
check "M means MiB" "$((256 * 1024 * 1024))" "$(fs_parse_size_bytes 256M)"
check "G means GiB" "$((2 * 1024 * 1024 * 1024))" "$(fs_parse_size_bytes 2G)"

err_file="$(mktemp)"
for bad in "" 0 0K -5 5.5M 5MB M garbage; do
    if out="$(fs_parse_size_bytes "$bad" 2>"$err_file")"; then
        no "'$bad' is rejected" "accepted, got '$out'"
    else
        ok "'$bad' is rejected"
    fi
done
if fs_parse_size_bytes garbage 2>"$err_file"; then
    no "a bad value's error names what was given"
else
    case "$(cat "$err_file")" in
        *"'garbage'"*) ok "a bad value's error names what was given" ;;
        *) no "a bad value's error names what was given" "$(cat "$err_file")" ;;
    esac
fi
if fs_parse_size_bytes 0 2>"$err_file"; then
    no "0 is rejected with a message naming it"
else
    case "$(cat "$err_file")" in
        *"'0'"*) ok "0 is rejected with a message naming it" ;;
        *) no "0 is rejected with a message naming it" "$(cat "$err_file")" ;;
    esac
fi
rm -f "$err_file"

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
# A project fixture rooted under claude_home's own $HOME/src, not the real
# one -- fs_require_src_project checks the project path against $HOME/src
# at call time, so a --harness claude case run with HOME="$claude_home" (to
# pick up its fixture credential) needs a project under that same fixture
# HOME, not the real one k8s_flag_proj lives under.
mkdir -p "$claude_home/src"
k8s_flag_claude_proj="$(HOME="$claude_home" new_src_project)"; tmpdirs+=("$k8s_flag_claude_proj")
k8s_flag_handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-test.XXXXXX)"
tmpdirs+=("$k8s_flag_handoff_dir")
k8s_flag_handoff="$k8s_flag_handoff_dir/handoff.md"
printf 'Do the k8s thing.\n' > "$k8s_flag_handoff"

refuses "--k8s with no --harness and no --model needs a model" \
    "--harness pi needs --model" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    unused-project unused-handoff
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-default-harness \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-default-harness.err; then
    ok "--k8s with no --harness defaults to pi"
else
    no "--k8s with no --harness defaults to pi" \
        "$(cat /tmp/fs-k8s-flag-test-default-harness.err)"
fi
rm -f /tmp/fs-k8s-flag-test-default-harness.err
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 \
    --branch fs-k8s-flag-test-claude-harness \
    "$k8s_flag_claude_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-claude-harness.err; then
    ok "--k8s --harness claude is accepted"
else
    no "--k8s --harness claude is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-claude-harness.err)"
fi
rm -f /tmp/fs-k8s-flag-test-claude-harness.err
refuses "--k8s --harness claude with no --model needs a model" \
    "--k8s --harness claude needs --model" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude "$k8s_flag_claude_proj" "$k8s_flag_handoff"
refuses "--k8s --harness pi-local is refused" \
    "only supports --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi-local unused-project unused-handoff
refuses "--k8s --harness codex is refused" \
    "only supports --harness pi" \
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
# --context-ro is carried through, not refused -- fork-sandbox-k8s.sh's own
# submit applies the directory-under-/var/tmp/claude-scratch/forks/,
# no-symlinks, 256 MiB constraints itself, so the fixture below needs a real
# directory satisfying those, the same way k8s_flag_proj/k8s_flag_handoff
# above stand in for --dry-run's own post-flag-parse validation.
k8s_flag_cr_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-flag-test-cr.XXXXXX)"
tmpdirs+=("$k8s_flag_cr_dir")
printf 'gathered notes\n' > "$k8s_flag_cr_dir/notes.md"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --context-ro "$k8s_flag_cr_dir" \
    --branch fs-k8s-flag-test-cr-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-cr.yaml 2>/tmp/fs-k8s-flag-test-cr.err; then
    ok "--k8s --context-ro --dry-run is no longer refused"
else
    no "--k8s --context-ro --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-cr.err)"
fi
if grep -q '## Gathered context' /tmp/fs-k8s-flag-test-cr.yaml; then
    ok "--k8s --context-ro --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --context-ro --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "not found in /tmp/fs-k8s-flag-test-cr.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-cr.err /tmp/fs-k8s-flag-test-cr.yaml
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
# --review-loop is carried through, not refused -- the cluster analogue of
# fork-sandbox.sh's own local loop, running pod-side. Real fixtures
# required (k8s_flag_proj / k8s_flag_handoff): --dry-run's own validation
# runs after fs_require_scratch_handoff / fs_require_src_project, unlike
# the flag-refusal cases above, which fail on their own flag first and so
# get away with a placeholder.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 \
    --branch fs-k8s-flag-test-rl-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-rl.yaml 2>/tmp/fs-k8s-flag-test-rl.err; then
    ok "--k8s --review-loop 2 --dry-run is no longer refused"
else
    no "--k8s --review-loop 2 --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-rl.err)"
fi
if grep -qF '  review-prompt.md: |' /tmp/fs-k8s-flag-test-rl.yaml; then
    ok "--k8s --review-loop 2 --dry-run renders the review-prompt.md ConfigMap key"
else
    no "--k8s --review-loop 2 --dry-run renders the review-prompt.md ConfigMap key" \
        "not found in /tmp/fs-k8s-flag-test-rl.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-rl.err /tmp/fs-k8s-flag-test-rl.yaml

# --review-model is now carried on both harnesses (models.json lists every
# distinct id among --model and --review-model), but only alongside
# --review-loop -- the same "only applies to review legs" rule the general
# non-k8s path applies, checked first in the --k8s block, before any
# harness-specific --review-harness rule below.
refuses "--k8s --harness pi --review-model without --review-loop is refused" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-model opus \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-model without --review-loop is refused (coherence checked before harness rules)" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-model opus \
    unused-project unused-handoff
refuses "--k8s --harness pi --review-harness pi --review-model without --review-loop hits the coherence message first" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-harness pi --review-model opus \
    unused-project unused-handoff

pi_review_model_out="$(newdir)/pi-review-model.yaml"; tmpdirs+=("$(dirname "$pi_review_model_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 --review-model opus \
    --branch fs-k8s-flag-test-pi-review-model \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$pi_review_model_out" 2>/tmp/fs-k8s-flag-test-pi-review-model.err; then
    ok "--k8s --harness pi --review-model with --review-loop is accepted"
else
    no "--k8s --harness pi --review-model with --review-loop is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-pi-review-model.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$pi_review_model_out" \
    && grep -A1 'name: REVIEW_MODEL' "$pi_review_model_out" | grep -q 'value: "opus"'; then
    ok "--k8s --harness pi forwards --review-model through to the rendered Job env"
else
    no "--k8s --harness pi forwards --review-model through to the rendered Job env" \
        "not found in $pi_review_model_out"
fi
rm -f /tmp/fs-k8s-flag-test-pi-review-model.err

refuses "--k8s --harness pi --review-harness is refused (the pod's review loop is always pi)" \
    "not supported with --k8s --harness" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 --review-harness pi \
    --review-model opus unused-project unused-handoff

refuses "--k8s --harness claude --review-loop without --review-harness pi is refused" \
    "needs" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-harness claude is refused as pi-only, regardless of --review-loop" \
    "pi-only" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-harness claude \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-loop --review-harness claude is refused as pi-only" \
    "pi-only" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 --review-harness claude \
    unused-project unused-handoff

claude_review_out="$(newdir)/claude-review.yaml"; tmpdirs+=("$(dirname "$claude_review_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 \
    --review-harness pi --review-model moonshotai/kimi-k3 \
    --branch fs-k8s-flag-test-claude-review \
    "$k8s_flag_claude_proj" "$k8s_flag_handoff" \
    > "$claude_review_out" 2>/tmp/fs-k8s-flag-test-claude-review.err; then
    ok "--k8s --harness claude --review-loop --review-harness pi --review-model is accepted"
else
    no "--k8s --harness claude --review-loop --review-harness pi --review-model is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-claude-review.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$claude_review_out" \
    && grep -A1 'name: REVIEW_MODEL' "$claude_review_out" | grep -q 'value: "moonshotai/kimi-k3"'; then
    ok "--k8s --harness claude forwards --review-model through to the rendered Job env"
else
    no "--k8s --harness claude forwards --review-model through to the rendered Job env" \
        "not found in $claude_review_out"
fi
rm -f /tmp/fs-k8s-flag-test-claude-review.err

refuses "--timeout without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --timeout 100 unused-project unused-handoff
refuses "--keep without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --keep unused-project unused-handoff
refuses "--outbox-dir without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --outbox-dir /tmp/fs-k8s-flag-test-outbox unused-project unused-handoff

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

# --outbox-dir is likewise accepted with --k8s and threaded through to
# fork-sandbox-k8s.sh run (--dry-run never reaches the pull-back step it
# configures, but the flag must not be refused as unknown on either leg of
# the dispatch).
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --outbox-dir /tmp/fs-k8s-flag-test-outbox \
    --branch fs-k8s-flag-test-branch3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-outboxdir.err; then
    ok "--k8s accepts --outbox-dir"
else
    no "--k8s accepts --outbox-dir" "$(cat /tmp/fs-k8s-flag-test-outboxdir.err)"
fi
rm -f /tmp/fs-k8s-flag-test-outboxdir.err

printf '\n== bare repo HEAD points at the pushed branch before cloning ==\n'
# cmd_submit only ever pushes refs/heads/$branch into the pod's bare repo,
# so its default HEAD (set by git init --bare) dangles. The entrypoint must
# point HEAD at the pushed branch before cloning, not after -- otherwise the
# clone still hits the dangling default and prints the warning this fix
# exists to silence.
# shellcheck disable=SC2016  # the needles match a literal $BRANCH etc. in the entrypoint text
symref_line="$(grep -n 'symbolic-ref HEAD "refs/heads/\$BRANCH"' "$entrypoint_sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # ditto
clone_line="$(grep -n 'git clone --quiet "\$repo_bare" "\$clone_dir"' "$entrypoint_sh" | head -1 | cut -d: -f1)"
if [[ -n "$symref_line" && -n "$clone_line" ]]; then
    ok "entrypoint sets symbolic-ref HEAD to refs/heads/\$BRANCH"
    if (( symref_line < clone_line )); then
        ok "the symbolic-ref line precedes the git clone line"
    else
        no "the symbolic-ref line precedes the git clone line" \
            "symbolic-ref at line $symref_line, clone at line $clone_line"
    fi
else
    no "entrypoint sets symbolic-ref HEAD to refs/heads/\$BRANCH" \
        "symref_line='$symref_line' clone_line='$clone_line' in $entrypoint_sh"
fi

# Now that the clone lands directly on $BRANCH (HEAD already points there),
# `checkout -b` would fail with "already exists" -- the entrypoint must use
# a plain checkout instead.
if grep -qF 'checkout --quiet -b' "$entrypoint_sh"; then
    no "entrypoint no longer uses checkout --quiet -b" \
        "found 'checkout --quiet -b' in $entrypoint_sh"
else
    ok "entrypoint no longer uses checkout --quiet -b"
fi

# The real-git property the fix relies on: pushing a branch into a bare repo
# leaves its default HEAD dangling, and a plain `git clone` of that repo
# warns and checks out nothing -- but pointing HEAD at the pushed branch
# first makes the clone land directly on it, with no warning.
symref_root="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-symref-test.XXXXXX)"; tmpdirs+=("$symref_root")
symref_bare="$symref_root/repo.git"
symref_src="$symref_root/src"
symref_clone="$symref_root/clone"
git init --quiet --bare "$symref_bare"
mkdir -p "$symref_src"
git -C "$symref_src" init --quiet
git -C "$symref_src" -c user.email=t@fork-sandbox.invalid -c user.name=t \
    commit -q --allow-empty -m init
git -C "$symref_src" push --quiet "$symref_bare" HEAD:refs/heads/x
git --git-dir="$symref_bare" symbolic-ref HEAD refs/heads/x
symref_clone_err="$(git clone --quiet "$symref_bare" "$symref_clone" 2>&1 1>/dev/null)"
if [[ "$symref_clone_err" != *"nonexistent ref"* ]]; then
    ok "cloning a bare repo with HEAD pointed at the pushed branch prints no nonexistent-ref warning"
else
    no "cloning a bare repo with HEAD pointed at the pushed branch prints no nonexistent-ref warning" \
        "$symref_clone_err"
fi
symref_clone_branch="$(git -C "$symref_clone" rev-parse --abbrev-ref HEAD 2>/dev/null)"
check "the clone lands directly on branch x" "x" "$symref_clone_branch"

printf '\n== entrypoint: HARNESS switch and claude coding leg ==\n'
# All the needles below are grepped as literal text against the entrypoint
# script's own source, matching a literal "$VAR" there -- none of them are
# meant to expand in this test script.
# shellcheck disable=SC2016

# HARNESS defaults to pi and rejects anything but pi|claude.
if grep -qF ': "${HARNESS:=pi}"' "$entrypoint_sh" \
    && grep -qF 'pi|claude) ;;' "$entrypoint_sh"; then
    ok "entrypoint defaults HARNESS to pi and validates it against pi|claude"
else
    no "entrypoint defaults HARNESS to pi and validates it against pi|claude" \
        "missing HARNESS default or pi|claude case arm in $entrypoint_sh"
fi

# CLAUDE_PROXY_BASE_URL is required only for HARNESS=claude.
# shellcheck disable=SC2016
if grep -qF 'CLAUDE_PROXY_BASE_URL:?CLAUDE_PROXY_BASE_URL must be set when HARNESS=claude' \
    "$entrypoint_sh"; then
    ok "entrypoint requires CLAUDE_PROXY_BASE_URL when HARNESS=claude"
else
    no "entrypoint requires CLAUDE_PROXY_BASE_URL when HARNESS=claude" \
        "missing CLAUDE_PROXY_BASE_URL required-var check in $entrypoint_sh"
fi

# A claude run with REVIEW_LOOP_CAP set and no REVIEW_MODEL fails at
# startup, before the coding leg -- the review loop always runs pi, and
# MODEL is a Claude Code model name pi cannot use.
# shellcheck disable=SC2016
if grep -qF 'HARNESS" == claude && -z "$REVIEW_MODEL"' "$entrypoint_sh"; then
    ok "entrypoint refuses HARNESS=claude with REVIEW_LOOP_CAP set and no REVIEW_MODEL"
else
    no "entrypoint refuses HARNESS=claude with REVIEW_LOOP_CAP set and no REVIEW_MODEL" \
        "missing the REVIEW_MODEL startup check in $entrypoint_sh"
fi

# The claude branch installs the placeholder credential and the pre-accepted
# onboarding/trust config at the paths claude reads from $HOME.
# shellcheck disable=SC2016
if grep -qF 'install -m 600 "$mounts_dir/claude-credentials.json" "$HOME/.claude/.credentials.json"' \
    "$entrypoint_sh"; then
    ok "entrypoint installs the placeholder claude credential"
else
    no "entrypoint installs the placeholder claude credential" \
        "missing the claude-credentials.json install line in $entrypoint_sh"
fi
# shellcheck disable=SC2016
if grep -qF 'hasCompletedOnboarding: true' "$entrypoint_sh" \
    && grep -qF '> "$HOME/.claude.json"' "$entrypoint_sh"; then
    ok "entrypoint writes a pre-accepted ~/.claude.json for the claude branch"
else
    no "entrypoint writes a pre-accepted ~/.claude.json for the claude branch" \
        "missing the .claude.json synthesis in $entrypoint_sh"
fi

# The operator-inbox hook is installed executable and registered via
# --settings, exactly as a local claude run's own inbox-hook install does.
# shellcheck disable=SC2016
if grep -qF 'install -m 755 "$mounts_dir/inbox-hook.sh" "$inbox_dir/.inbox-hook.sh"' \
    "$entrypoint_sh"; then
    ok "entrypoint installs the inbox hook mode 755"
else
    no "entrypoint installs the inbox hook mode 755" \
        "missing the inbox-hook.sh install line in $entrypoint_sh"
fi
# shellcheck disable=SC2016
if grep -qF '"$work_dir/inbox-settings.json"' "$entrypoint_sh"; then
    ok "entrypoint renders an inbox-settings.json for --settings"
else
    no "entrypoint renders an inbox-settings.json for --settings" \
        "missing inbox-settings.json in $entrypoint_sh"
fi

# The claude launch line itself: base URL via env, non-interactive flags,
# the inbox-hook --settings file, and stdin/stdout/stderr wired the same
# way as pi's own invocation but to claude-stderr.log, not pi-stderr.log.
# shellcheck disable=SC2016
claude_launch_checks=(
    'ANTHROPIC_BASE_URL="$CLAUDE_PROXY_BASE_URL"'
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1'
    'DISABLE_AUTOUPDATER=1'
    'TERM=dumb'
    'claude --dangerously-skip-permissions --print --verbose'
    '--output-format stream-json --model "$MODEL"'
    '--settings "$work_dir/inbox-settings.json" --include-hook-events'
    '< "$mounts_dir/handoff.md"'
    '> "$work_dir/events.jsonl"'
    '2> "$work_dir/claude-stderr.log"'
)
claude_launch_missing=""
for needle in "${claude_launch_checks[@]}"; do
    if ! grep -qF -- "$needle" "$entrypoint_sh"; then
        claude_launch_missing+="  missing: $needle"$'\n'
    fi
done
if [[ -z "$claude_launch_missing" ]]; then
    ok "entrypoint's claude launch line carries every required flag/env/redirect"
else
    no "entrypoint's claude launch line carries every required flag/env/redirect" \
        "$claude_launch_missing"
fi

# The review loop always runs pi and always prefers REVIEW_MODEL over
# MODEL when set, regardless of harness -- required at startup for
# HARNESS=claude (checked above), optional otherwise.
# shellcheck disable=SC2016
if grep -qF 'review_loop_model="${REVIEW_MODEL:-$MODEL}"' "$entrypoint_sh" \
    && grep -qF 'synthesize_pi_config "$review_loop_model"' "$entrypoint_sh" \
    && grep -qF 'MODEL="$review_loop_model" bash "$mounts_dir/review-loop.sh"' "$entrypoint_sh"; then
    ok "entrypoint threads REVIEW_MODEL into the review loop's pi config and invocation"
else
    no "entrypoint threads REVIEW_MODEL into the review loop's pi config and invocation" \
        "missing review_loop_model wiring in $entrypoint_sh"
fi

# A pi coding leg folds REVIEW_MODEL into models.json alongside MODEL up
# front, via a second synthesize_pi_config argument, and the function's
# own jq dedupes the two ids with `unique` so an unset REVIEW_MODEL (or
# one equal to MODEL) never produces a bogus or duplicate model entry.
# shellcheck disable=SC2016
if grep -qF 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh"; then
    ok "entrypoint's pi coding leg folds REVIEW_MODEL into models.json up front"
else
    no "entrypoint's pi coding leg folds REVIEW_MODEL into models.json up front" \
        "missing synthesize_pi_config \"\$MODEL\" \"\$REVIEW_MODEL\" call in $entrypoint_sh"
fi
if grep -qF '| unique | map({' "$entrypoint_sh"; then
    ok "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique"
else
    no "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique" \
        "missing a '| unique | map({' models array in $entrypoint_sh"
fi

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
