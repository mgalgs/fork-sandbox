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
#     mistakes the other verbs reject.
#   - `run`'s whole poll/wait/fetch/pull-back/rm sequence, driven end to
#     end against a stubbed kubectl+git pair (the stub cannot prove what a
#     real pod does with the .fetched marker, only what the client does in
#     what order): a failed outbox read reports kubectl's own stderr,
#     a failed read with empty stderr says so explicitly, the outbox
#     read happens BEFORE the fetch touches /work/.fetched, a
#     substantially-over-cap outbox is diagnosed as over the cap (not as
#     a read failure) even when kubectl dies of EPIPE, and the
#     review-loop.json read carries the same request-timeout bound.
#   - the `wait` and `collect` verbs, driven directly against the same
#     stubbed kubectl pair: a completed wait prints the agent's exit code
#     to stdout and nothing else (a non-zero AGENT exit is a successful
#     wait that exits 0), while a Failed pod, a Succeeded pod (run
#     completed, then idled out its TTL), a Failed job condition and a
#     malformed sentinel each fail the wait with the terminal code 2
#     (the run can never complete through it again) and a timeout fails
#     it with code 1 (the run may still be going); collect
#     lands the outbox at --outbox-dir, refuses an over-cap one without
#     costing the fetch, warns on an unreadable one and still fetches,
#     reports an approved and a cap review-loop outcome under
#     --review-loop 1, never reads review-loop.json when --review-loop is
#     omitted, removes the job unless --keep, and reads the outbox before
#     the fetch touches /work/.fetched.
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
#   - fork-sandbox-k8s.sh keeps spelling its GNU tools through the
#     resolved names fork-sandbox-lib.sh sets ($FS_STAT, $FS_REALPATH,
#     $FS_TIMEOUT) rather than the bare names, which on macOS are the BSD
#     tools that reject the GNU flags -- with exactly one documented
#     exception, the readlink -f bootstrap that runs before the library
#     is sourced.
#   - fork-sandbox.sh --k8s: the two new lib functions it shares with the
#     local path (fs_require_scratch_handoff, fs_require_src_project), that
#     it defaults a bare --k8s to --harness pi, that a model-less --k8s run
#     passes the launcher on ANY install -- on a legacy install the
#     refusal is fork-sandbox-k8s.sh's own run verb, and on an endpoints
#     install the render lands on K8S_DEFAULT_ENDPOINT's endpoint when
#     k8s.env names one --
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
#   - `--pi-args ARGS` on submit and run: the value renders verbatim into
#     the rendered Job's PI_ARGS env var when given, and the flag's
#     absence renders no PI_ARGS env at all (not an empty value); the
#     entrypoint's pi invocation (run_pi_coding_leg, extracted from the
#     entrypoint's own source and run against a stubbed pi that records
#     its argv) receives "--thinking low" as two separate arguments and
#     an unset or empty PI_ARGS as none; a value containing a single
#     quote, a double quote, or a backslash is refused at parse time
#     with nothing created (the stubbed kubectl's log stays empty),
#     --harness claude is refused,
#     and run's copy forwards to submit unchanged (byte-for-byte the same
#     dry-run render).
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
#   - `--checkout REF` on submit and run: the push's source side is no
#     longer hardcoded to HEAD. A resolvable ref renders (exits 0) under
#     --dry-run; an unresolvable one fails with the ref named and the
#     stubbed kubectl's own log still empty (nothing created), under
#     --dry-run and not; a value with a single quote is refused by
#     fs_reject_unsafe_chars before any kubectl call, like every other
#     rejected input; the push refspec carries the resolved sha of the
#     named ref (not HEAD), and the push line reports it; under
#     --review-loop, the BASE_SHA the loop measures against is that same
#     sha; without the flag the refspec and the base are HEAD, exactly as
#     before; and `fork-sandbox.sh --k8s --checkout REF` is no longer
#     refused -- it forwards the flag, and its render matches a direct
#     `run --dry-run --checkout REF` byte-for-byte.
#   - K8S_PROXY_ENDPOINTS, the named-keyless-endpoint registry: a legacy
#     K8S_PROXY_UPSTREAM install renders byte-identical to
#     tests/fixtures/k8s-proxy-legacy-install.yaml, a render captured before
#     this feature existed; K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS set
#     together are refused as mutually exclusive; neither set is still
#     refused with a useful message; N registered endpoints render exactly
#     2N EXACT-match locations (/e/<name>/v1/chat/completions,
#     /e/<name>/v1/models, never a regex or prefix match) alongside the
#     surviving default-deny `location /`; a K8S_PROXY_ENDPOINTS install
#     creates no Secret, references no upstream-key Secret volume or
#     volumeMount on the Deployment, includes no upstream-key.conf, and
#     injects no Authorization header; its rendered nginx.conf passes
#     `nginx -t`, the same check the legacy render gets above; submit
#     --endpoint NAME renders a Job whose PROXY_BASE_URL is the
#     endpoint's /e/NAME/v1 location, an unregistered name and an omitted
#     --endpoint against a multi-endpoint install are both errors listing
#     the registered names, an omitted --endpoint against a single-
#     endpoint install resolves to it (and says so on stderr), and
#     --endpoint against a legacy K8S_PROXY_UPSTREAM install is refused;
#     K8S_DEFAULT_ENDPOINT in k8s.env sits between the flag and the
#     one-candidate rule -- an explicit --endpoint wins over it, a default
#     naming an unregistered endpoint is a parse-time error naming k8s.env
#     and listing the registered names (never a fallthrough), and a default
#     on a legacy K8S_PROXY_UPSTREAM install is refused with the same shape
#     as the --endpoint refusal;
#     --model is optional on an endpoints install (submit accepts it and
#     renders an empty MODEL env) but stays required on a legacy install,
#     and --harness claude keeps the requirement even on an endpoints
#     install; K8S_PROXY_ALLOW
#     replaces the default RFC1918-except egress block with exactly the
#     given <cidr>:<port> entries, and a hostname there is refused with a
#     message naming why (NetworkPolicy has no hostname field); a partial
#     K8S_PROXY_ALLOW (covering some registered endpoints but not others)
#     warns by name about the ones it does not cover; http:// is accepted
#     to a private address and refused to a public one, checked on both
#     the legacy K8S_PROXY_UPSTREAM path and a K8S_PROXY_ENDPOINTS entry,
#     and each of those warns that it is unreachable when K8S_PROXY_ALLOW
#     is unset; an IPv4 octet with a leading zero is never read as octal
#     (nor spews a bash arithmetic error) when classifying an address as
#     private; a duplicate name, a non-RFC1123 name, and an empty base URL
#     in K8S_PROXY_ENDPOINTS are each refused, as is a K8S_PROXY_ALLOW
#     port outside 1-65535.
#   - fork-sandbox-k8s-entrypoint.sh's pod-side model discovery
#     (discover_model_facts), driven with curl stubbed on PATH: a
#     single-model /v1/models response resolves MODEL and sets CTX /
#     MAX_TOKENS from max_model_len (agent-sandboxed's rules: a 32768
#     MAX_TOKENS floor capped at a quarter of the window); a multi-model
#     response with no MODEL is an error listing the ids; a curl failure
#     (the ordinary connection-refused state) errors naming the URL; a
#     missing max_model_len warns and falls back to 32768; a MODEL absent
#     from the listing warns and continues; REVIEW_MODEL gets the window
#     discovered for its OWN id, not MODEL's -- the --harness claude case
#     where MODEL is a Claude Code model name the listing never contains;
#     and discovery runs in the script BEFORE the repository-receive
#     wait, with no hardcoded contextWindow/maxTokens left in
#     synthesize_pi_config's render. The call itself is gated on the
#     host-set MODEL_DISCOVERY env: a legacy K8S_PROXY_UPSTREAM install
#     (whose proxy forwards only /api/v1/chat/completions, so /models
#     would 403) and a --harness claude run without a --review-loop
#     (no pi leg talks to the proxy, so the run must not hard-depend on
#     the endpoint being up) render no MODEL_DISCOVERY env and the pod
#     keeps the pre-discovery 131072/32768 constants, while an endpoints
#     render for a run that uses the pi proxy carries it. A failed
#     repository push in submit surfaces the pod's container log, since
#     a pod that died in early discovery would otherwise only show
#     git's bare "connection refused".
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# Every run this suite launches is a fixture, not real work. Mark it so
# sandbox-run-log.py's list/stats exclude it by default. A cluster run does
# not append to the run log at all today, so this changes nothing yet -- it
# is here so that whenever the k8s path does gain a run-log entry, this
# suite's fixtures do not silently start polluting the operator's stats.
export FORK_SANDBOX_RUN_SOURCE=test

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
# selector and the static NetworkPolicy's podSelector -- three SEPARATE
# objects, since a --harness claude run's per-run proxy Pod also carries
# app: fork-sandbox-proxy (for the platform agent-egress policy) and would
# otherwise be picked up by either the Service (round-robining pi traffic
# into a proxy that 403s it) or the static policy (whose ingress admits
# every agent pod in the namespace, not just one run's own). A bare
# occurrence count of 3 cannot tell "one per object" apart from "three
# copies inside the Deployment's pod template, Service selector and
# NetworkPolicy podSelector left untightened" -- so each object's own
# rendered document is checked individually instead.
extract_doc_by_kind() {
    local kind="$1" file="$2"
    awk -v k="kind: $kind" '
        $0 == k { flag=1 }
        flag && /^---$/ { exit }
        flag { print }
    ' "$file"
}
proxy_deployment_doc="$(extract_doc_by_kind Deployment "$install_out")"
proxy_service_doc="$(extract_doc_by_kind Service "$install_out")"
proxy_netpol_doc="$(extract_doc_by_kind NetworkPolicy "$install_out")"
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_deployment_doc"; then
    ok "the Deployment's pod template carries fork-sandbox/role: model-proxy"
else
    no "the Deployment's pod template carries fork-sandbox/role: model-proxy" \
        "not found in Deployment doc from $install_out"
fi
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_service_doc"; then
    ok "the Service's own selector carries fork-sandbox/role: model-proxy"
else
    no "the Service's own selector carries fork-sandbox/role: model-proxy" \
        "not found in Service doc from $install_out"
fi
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_netpol_doc"; then
    ok "the static NetworkPolicy's own podSelector carries fork-sandbox/role: model-proxy"
else
    no "the static NetworkPolicy's own podSelector carries fork-sandbox/role: model-proxy" \
        "not found in NetworkPolicy doc from $install_out"
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

    # Runs `nginx -t` against $1/nginx.conf ($nginx_check_dir when $1 is
    # omitted, the legacy-render caller below), with upstream-key.conf
    # staged at the literal absolute path the include names
    # (/etc/nginx/upstream-key.conf) -- harmless to stage even against a
    # keyless render's config, which never includes it. Prints combined
    # output; returns nginx's exit status.
    run_nginx_t() {
        local check_dir="${1:-$nginx_check_dir}"
        case "$nginx_mode" in
            native)
                # The include and proxy_ssl_trusted_certificate directives
                # are absolute host paths, so testing natively needs the
                # stub staged at the literal path -- which needs root. Fall
                # back to docker rather than fail outright when that is not
                # available.
                if install -Dm644 "$check_dir/upstream-key.conf" \
                        /etc/nginx/upstream-key.conf 2>/dev/null; then
                    local rc
                    nginx -t -c "$check_dir/nginx.conf" 2>&1
                    rc=$?
                    rm -f /etc/nginx/upstream-key.conf
                    return "$rc"
                fi
                if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                    echo "(cannot stage /etc/nginx/upstream-key.conf without root; falling back to docker)"
                    nginx_mode=docker
                    run_nginx_t "$check_dir"
                    return $?
                fi
                echo "nginx is on PATH but /etc/nginx/upstream-key.conf could not be staged, and no docker fallback is available"
                return 127
                ;;
            docker)
                docker run --rm \
                    -v "$check_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
                    -v "$check_dir/upstream-key.conf:/etc/nginx/upstream-key.conf:ro" \
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

printf '\n== K8S_PROXY_ENDPOINTS: named keyless endpoints ==\n'
# Byte-identical legacy render: the load-bearing backward-compatibility
# guarantee for this whole feature. tests/fixtures/k8s-proxy-legacy-install.yaml
# is a render captured before K8S_PROXY_ENDPOINTS/K8S_PROXY_ALLOW/the
# optional-key/the http-private-address work started, using the exact same
# k8s.env as $config_dir/$install_out above -- an existing
# K8S_PROXY_UPSTREAM install must still render exactly this.
if diff -q "$repo_dir/tests/fixtures/k8s-proxy-legacy-install.yaml" "$install_out" >/dev/null 2>&1; then
    ok "legacy K8S_PROXY_UPSTREAM install renders byte-identical to the pre-change fixture"
else
    no "legacy K8S_PROXY_UPSTREAM install renders byte-identical to the pre-change fixture" \
        "$(diff "$repo_dir/tests/fixtures/k8s-proxy-legacy-install.yaml" "$install_out" 2>&1 | head -20)"
fi

# K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS are mutually exclusive -- an
# error, never a precedence rule.
both_config_dir="$(newdir)"; tmpdirs+=("$both_config_dir")
cat > "$both_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS together are refused" \
    "mutually" \
    env FORK_SANDBOX_CONFIG_DIR="$both_config_dir" "$k8s_sh" install --dry-run

# Neither a key (K8S_PROXY_UPSTREAM) nor K8S_PROXY_ENDPOINTS: still a clear
# error, not a silent default.
neither_config_dir="$(newdir)"; tmpdirs+=("$neither_config_dir")
cat > "$neither_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "install with neither K8S_PROXY_UPSTREAM nor K8S_PROXY_ENDPOINTS errors usefully" \
    "K8S_PROXY_ENDPOINTS" \
    env FORK_SANDBOX_CONFIG_DIR="$neither_config_dir" "$k8s_sh" install --dry-run

# parse_proxy_endpoints' own refusal branches: a name registered twice, a
# name that doesn't match the RFC1123-label shape it becomes a path
# segment from, and an entry with no base URL at all.
dup_name_config_dir="$(newdir)"; tmpdirs+=("$dup_name_config_dir")
cat > "$dup_name_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,primary=http://10.0.0.6:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS name registered twice is refused" \
    "must be unique" \
    env FORK_SANDBOX_CONFIG_DIR="$dup_name_config_dir" "$k8s_sh" install --dry-run

bad_name_config_dir="$(newdir)"; tmpdirs+=("$bad_name_config_dir")
cat > "$bad_name_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=Primary_1=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS name that is not RFC1123-label shaped is refused" \
    "is not valid" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_name_config_dir" "$k8s_sh" install --dry-run

empty_url_config_dir="$(newdir)"; tmpdirs+=("$empty_url_config_dir")
cat > "$empty_url_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS entry with an empty base URL is refused" \
    "has an empty" \
    env FORK_SANDBOX_CONFIG_DIR="$empty_url_config_dir" "$k8s_sh" install --dry-run

# parse_proxy_allow's own port-range branch.
bad_port_allow_config_dir="$(newdir)"; tmpdirs+=("$bad_port_allow_config_dir")
cat > "$bad_port_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW=10.0.0.5/32:70000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ALLOW port outside 1-65535 is refused" \
    "must be 1-65535" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_port_allow_config_dir" "$k8s_sh" install --dry-run

# N registered endpoints render exactly 2N EXACT-match locations
# (/e/<name>/v1/chat/completions, /e/<name>/v1/models), never a regex or
# prefix match, and the default-deny location / survives unchanged.
endpoints_config_dir="$(newdir)"; tmpdirs+=("$endpoints_config_dir")
cat > "$endpoints_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
endpoints_out="$(newdir)/endpoints-install.yaml"; tmpdirs+=("$(dirname "$endpoints_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" install --dry-run \
    > "$endpoints_out" 2>/tmp/fs-k8s-test-endpoints-install.err; then
    ok "K8S_PROXY_ENDPOINTS install --dry-run exits 0"
else
    no "K8S_PROXY_ENDPOINTS install --dry-run exits 0" "$(cat /tmp/fs-k8s-test-endpoints-install.err)"
fi

# submit --endpoint wires the run to the named endpoint's /e/<name>/v1
# location instead of the legacy /api/v1 path -- the wiring the old
# "submit refuses endpoints installs" refusal stood in for, now proven
# by rendering.
ep_submit_out="$(newdir)/ep-submit.yaml"; tmpdirs+=("$(dirname "$ep_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint secondary \
    "$proj_dir" "$handoff_file" > "$ep_submit_out" 2>/tmp/fs-k8s-test-ep-submit.err; then
    ok "submit --dry-run --endpoint against a K8S_PROXY_ENDPOINTS namespace exits 0"
else
    no "submit --dry-run --endpoint against a K8S_PROXY_ENDPOINTS namespace exits 0" \
        "$(cat /tmp/fs-k8s-test-ep-submit.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$ep_submit_out" \
    && ! grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$ep_submit_out"; then
    ok "submit --endpoint renders PROXY_BASE_URL at the endpoint's /e/<name>/v1"
else
    no "submit --endpoint renders PROXY_BASE_URL at the endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$ep_submit_out")"
fi

# An unregistered name is an error listing the registered ones.
refuses "submit --endpoint with an unregistered name errors listing the registered ones" \
    "--endpoint 'bogus' is not registered" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint bogus \
    "$proj_dir" "$handoff_file"
unreg_out="$(FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint bogus \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$unreg_out" == *primary* && "$unreg_out" == *secondary* ]]; then
    ok "the unregistered --endpoint error lists the registered names"
else
    no "the unregistered --endpoint error lists the registered names" "$unreg_out"
fi

# An omitted --endpoint against a multi-endpoint install is an error
# listing the names (the one-candidate rule, mirrored from
# agent-sandboxed's model resolution).
refuses "submit with no --endpoint against a multi-endpoint install errors" \
    "more than one endpoint" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file"
multi_out="$(FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$multi_out" == *primary* && "$multi_out" == *secondary* ]]; then
    ok "the multi-endpoint no-\`--endpoint\` error lists the registered names"
else
    no "the multi-endpoint no-\`--endpoint\` error lists the registered names" "$multi_out"
fi

# K8S_DEFAULT_ENDPOINT in k8s.env is the site's preferred named
# endpoint. Precedence: an explicit --endpoint, then the default, then
# the one-candidate rule, then the error listing the names.
default_ep_config_dir="$(newdir)"; tmpdirs+=("$default_ep_config_dir")
cat > "$default_ep_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_DEFAULT_ENDPOINT=secondary
K8S_DENIED_PROBE=10.0.0.1:443
CONF

# An explicit --endpoint wins over K8S_DEFAULT_ENDPOINT.
def_flag_out="$(newdir)/def-flag-submit.yaml"; tmpdirs+=("$(dirname "$def_flag_out")")
def_flag_err="$(newdir)/def-flag-submit.err"; tmpdirs+=("$(dirname "$def_flag_err")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint primary \
    "$proj_dir" "$handoff_file" > "$def_flag_out" 2>"$def_flag_err"; then
    ok "submit --endpoint wins over K8S_DEFAULT_ENDPOINT and exits 0"
else
    no "submit --endpoint wins over K8S_DEFAULT_ENDPOINT and exits 0" \
        "$(cat "$def_flag_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1"' "$def_flag_out" \
    && ! grep -qF '/e/secondary/v1' "$def_flag_out"; then
    ok "the --endpoint-over-default render is wired to the flagged endpoint"
else
    no "the --endpoint-over-default render is wired to the flagged endpoint" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$def_flag_out")"
fi

# No flag, several registered: the default is used and announced.
def_default_out="$(newdir)/def-default-submit.yaml"; tmpdirs+=("$(dirname "$def_default_out")")
def_default_err="$(newdir)/def-default-submit.err"; tmpdirs+=("$(dirname "$def_default_err")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$def_default_out" 2>"$def_default_err"; then
    ok "submit with no --endpoint uses K8S_DEFAULT_ENDPOINT against a multi-endpoint install"
else
    no "submit with no --endpoint uses K8S_DEFAULT_ENDPOINT against a multi-endpoint install" \
        "$(cat "$def_default_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$def_default_out"; then
    ok "the K8S_DEFAULT_ENDPOINT resolution renders that endpoint's /e/<name>/v1"
else
    no "the K8S_DEFAULT_ENDPOINT resolution renders that endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$def_default_out")"
fi
if grep -q 'K8S_DEFAULT_ENDPOINT' "$def_default_err" && grep -q "'secondary'" "$def_default_err"; then
    ok "the K8S_DEFAULT_ENDPOINT resolution announces itself on stderr"
else
    no "the K8S_DEFAULT_ENDPOINT resolution announces itself on stderr" \
        "$(cat "$def_default_err")"
fi

# A default naming an unregistered endpoint is a parse-time error that
# names k8s.env (the command line never mentions the bad name) and lists
# the registered names -- never a fallthrough to the one-candidate rule.
bad_default_config_dir="$(newdir)"; tmpdirs+=("$bad_default_config_dir")
sed 's/^K8S_DEFAULT_ENDPOINT=.*/K8S_DEFAULT_ENDPOINT=bogus/' \
    "$default_ep_config_dir/k8s.env" > "$bad_default_config_dir/k8s.env"
refuses "submit with an unregistered K8S_DEFAULT_ENDPOINT errors" \
    "K8S_DEFAULT_ENDPOINT 'bogus'" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"
bad_default_out="$(FORK_SANDBOX_CONFIG_DIR="$bad_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$bad_default_out" == *k8s.env* && "$bad_default_out" == *"is not registered"* \
    && "$bad_default_out" == *primary* && "$bad_default_out" == *secondary* ]]; then
    ok "the unregistered K8S_DEFAULT_ENDPOINT error names k8s.env and the registered names"
else
    no "the unregistered K8S_DEFAULT_ENDPOINT error names k8s.env and the registered names" "$bad_default_out"
fi

# A default on a legacy K8S_PROXY_UPSTREAM install is a config error, not
# something to ignore -- the same shape as the --endpoint refusal.
legacy_default_config_dir="$(newdir)"; tmpdirs+=("$legacy_default_config_dir")
sed 's/^K8S_PROXY_ENDPOINTS=.*/K8S_PROXY_UPSTREAM=https:\/\/openrouter.ai/' \
    "$default_ep_config_dir/k8s.env" > "$legacy_default_config_dir/k8s.env"
refuses "K8S_DEFAULT_ENDPOINT on a legacy K8S_PROXY_UPSTREAM install errors" \
    "K8S_DEFAULT_ENDPOINT is not available" \
    env FORK_SANDBOX_CONFIG_DIR="$legacy_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"

# ...and against a single-endpoint install it resolves to the one
# endpoint, says so on stderr, and renders that endpoint's location.
single_ep_config_dir="$(newdir)"; tmpdirs+=("$single_ep_config_dir")
cat > "$single_ep_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
single_ep_submit_out="$(newdir)/single-ep-submit.yaml"; tmpdirs+=("$(dirname "$single_ep_submit_out")")
single_ep_submit_err="$(newdir)/single-ep-submit.err"; tmpdirs+=("$(dirname "$single_ep_submit_err")")
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$single_ep_submit_out" 2>"$single_ep_submit_err"; then
    ok "submit with no --endpoint against a single-endpoint install exits 0"
else
    no "submit with no --endpoint against a single-endpoint install exits 0" \
        "$(cat "$single_ep_submit_err")"
fi
if grep -q 'using the single' "$single_ep_submit_err" \
    && grep -q "'primary'" "$single_ep_submit_err"; then
    ok "the single-endpoint resolution announces itself on stderr"
else
    no "the single-endpoint resolution announces itself on stderr" \
        "$(cat "$single_ep_submit_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1"' "$single_ep_submit_out"; then
    ok "the single-endpoint resolution renders that endpoint's /e/<name>/v1"
else
    no "the single-endpoint resolution renders that endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$single_ep_submit_out")"
fi

# --model is optional on an endpoints install: accepted, and the rendered
# Job carries an empty MODEL env (the pod will discover it).
no_model_submit_out="$(newdir)/no-model-submit.yaml"; tmpdirs+=("$(dirname "$no_model_submit_out")")
no_model_err="$(FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file" \
    > "$no_model_submit_out" 2>/dev/null; then
    ok "submit without --model on an endpoints install is accepted"
else
    no "submit without --model on an endpoints install is accepted" "$no_model_err"
fi
model_env="$(grep -A1 'name: MODEL$' "$no_model_submit_out" | tail -n1)"
check "the no-\`--model\` endpoints render carries an empty MODEL env" \
    '              value: ""' "$model_env"
# ...but stays required on a legacy install, with the same error text.
refuses "submit without --model on a legacy install is still refused" \
    "submit requires --model. There is no default:" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file"
# ...and --harness claude keeps the requirement even on an endpoints
# install: discovery lists the pi endpoint's model ids, never a Claude
# Code model name.
refuses "submit --harness claude without --model on an endpoints install is refused" \
    "not Claude Code model" \
    env FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --harness claude "$proj_dir" "$handoff_file"

# --endpoint against a legacy K8S_PROXY_UPSTREAM install is an error.
refuses "submit --endpoint against a legacy K8S_PROXY_UPSTREAM install errors" \
    "K8S_PROXY_UPSTREAM; there are no named" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint primary \
    "$proj_dir" "$handoff_file"
# And the legacy render keeps the /api/v1 literal, untouched by all of
# the above (already asserted by the byte-identical fixture render and
# the submit_out checks above; named here so the pair reads together).
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$submit_out"; then
    ok "a legacy install's rendered PROXY_BASE_URL is still the /api/v1 literal"
else
    no "a legacy install's rendered PROXY_BASE_URL is still the /api/v1 literal" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$submit_out")"
fi
# ...and the legacy render carries no MODEL_DISCOVERY env at all: that
# proxy forwards only /api/v1/chat/completions, so the pod-side discovery
# probe would 403 and die the pod before the repository push. (The needle
# is the YAML env line itself, which the entrypoint's own prose never
# spells.)
model_discovery_count="$(grep -cF -- '- name: MODEL_DISCOVERY' "$submit_out")"
if [[ "$model_discovery_count" == 0 ]]; then
    ok "a legacy install's rendered Job carries no MODEL_DISCOVERY env"
else
    no "a legacy install's rendered Job carries no MODEL_DISCOVERY env" \
        "found $model_discovery_count in the legacy submit render"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$no_model_submit_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$no_model_submit_out" | grep -qF 'value: "1"'; then
    ok "an endpoints install's rendered Job carries MODEL_DISCOVERY=1"
else
    no "an endpoints install's rendered Job carries MODEL_DISCOVERY=1" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$no_model_submit_out")"
fi
# A --harness claude run on an endpoints install WITHOUT a --review-loop
# never talks to the pi proxy (its leg uses CLAUDE_PROXY_BASE_URL), so
# the render carries no MODEL_DISCOVERY env: the run must not die at pod
# start just because a workstation-class endpoint is down. WITH a
# --review-loop the loop runs pi, so the env is back.
claude_gate_home="$(newdir)"; tmpdirs+=("$claude_gate_home")
mkdir -p "$claude_gate_home/.claude"
claude_gate_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
cat > "$claude_gate_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "fixture-gate-token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_gate_future_ms, "scopes": ["user:inference"]}}
JSON
claude_gate_out="$(newdir)/claude-gate.yaml"; tmpdirs+=("$(dirname "$claude_gate_out")")
if HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_gate_out" 2>/dev/null; then
    ok "submit --dry-run --harness claude on an endpoints install exits 0"
else
    no "submit --dry-run --harness claude on an endpoints install exits 0" \
        "$(HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
            --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
            "$proj_dir" "$handoff_file" 2>&1)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$claude_gate_out")" == 0 ]]; then
    ok "a claude run without a review loop carries no MODEL_DISCOVERY env"
else
    no "a claude run without a review loop carries no MODEL_DISCOVERY env" \
        "found MODEL_DISCOVERY in the claude render: $(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_out")"
fi
claude_gate_loop_out="$(newdir)/claude-gate-loop.yaml"; tmpdirs+=("$(dirname "$claude_gate_loop_out")")
if HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
    --review-loop 1 --review-model qwen3-8b \
    "$proj_dir" "$handoff_file" > "$claude_gate_loop_out" 2>/dev/null; then
    ok "submit --dry-run --harness claude --review-loop on an endpoints install exits 0"
else
    no "submit --dry-run --harness claude --review-loop on an endpoints install exits 0" \
        "$(HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
            --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
            --review-loop 1 --review-model qwen3-8b \
            "$proj_dir" "$handoff_file" 2>&1)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out" | grep -qF 'value: "1"'; then
    ok "a claude run with a --review-loop carries MODEL_DISCOVERY=1 (the loop runs pi)"
else
    no "a claude run with a --review-loop carries MODEL_DISCOVERY=1 (the loop runs pi)" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out")"
fi

# run forwards --endpoint (and the omitted --model) to submit rather than
# growing its own copy of either: the same arguments must render
# byte-for-byte the same YAML as the direct submit call.
ep_run_out="$(newdir)/ep-run.yaml"; tmpdirs+=("$(dirname "$ep_run_out")")
ep_run_err="$(newdir)/ep-run.err"; tmpdirs+=("$(dirname "$ep_run_err")")
ep_run_submit_out="$(newdir)/ep-run-submit.yaml"; tmpdirs+=("$(dirname "$ep_run_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --endpoint primary \
    "$proj_dir" "$handoff_file" > "$ep_run_out" 2>"$ep_run_err" \
    && FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --endpoint primary \
    "$proj_dir" "$handoff_file" > "$ep_run_submit_out" 2>/dev/null; then
    ok "run --dry-run --endpoint (no --model) exits 0"
else
    no "run --dry-run --endpoint (no --model) exits 0" "$(cat "$ep_run_err")"
fi
if diff -q "$ep_run_out" "$ep_run_submit_out" >/dev/null 2>&1; then
    ok "run --dry-run --endpoint renders byte-for-byte the same YAML as submit"
else
    no "run --dry-run --endpoint renders byte-for-byte the same YAML as submit" \
        "$(diff "$ep_run_out" "$ep_run_submit_out" 2>&1 | head -n 20)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$endpoints_out" 2>&1)"
    if [[ -z "$out" ]]; then
        ok "yamllint: K8S_PROXY_ENDPOINTS install --dry-run output"
    else
        no "yamllint: K8S_PROXY_ENDPOINTS install --dry-run output" "$out"
    fi
fi
location_count="$(grep -c '^            location = /e/' "$endpoints_out")"
check "two registered endpoints render exactly 4 (2N) locations" 4 "$location_count"
non_exact_count="$(grep -c '^            location [^=]' "$endpoints_out")"
check "the only non-exact-match location is the default-deny location /" 1 "$non_exact_count"
regex_count="$(grep -c 'location ~' "$endpoints_out")"
check "no endpoint location uses a regex match" 0 "$regex_count"
for path in /e/primary/v1/chat/completions /e/primary/v1/models \
    /e/secondary/v1/chat/completions /e/secondary/v1/models; do
    if grep -qF "location = $path {" "$endpoints_out"; then
        ok "renders an exact-match location for $path"
    else
        no "renders an exact-match location for $path" "not found in $endpoints_out"
    fi
done
if grep -q 'location / {' "$endpoints_out"; then
    ok "the default-deny location / survives a K8S_PROXY_ENDPOINTS install"
else
    no "the default-deny location / survives a K8S_PROXY_ENDPOINTS install" \
        "not found in $endpoints_out"
fi

# Same coverage as 'nginx -t on the rendered proxy config' above, against
# the K8S_PROXY_ENDPOINTS (keyless) render this time -- a genuinely
# different nginx.conf shape (no upstream-key.conf include, no
# $upstream_key, 2N exact-match locations, $upstream values carrying a
# path component that proxy_pass then concatenates onto) that every other
# assertion in this section only greps YAML text for, so a keyless config
# nginx refuses to start on could ship fully green otherwise. Reuses
# nginx_mode/run_nginx_t/proxy_image from the legacy check above --
# staging upstream-key.conf here is harmless even though this render never
# includes it.
endpoints_nginx_conf="$(extract_nginx_conf "$endpoints_out")"
if [[ -z "$endpoints_nginx_conf" ]]; then
    no "extracted nginx.conf from K8S_PROXY_ENDPOINTS install --dry-run output" \
        "no nginx.conf block found in $endpoints_out"
elif [[ -z "${nginx_mode:-}" ]]; then
    printf '  SKIP  neither nginx nor a working docker on PATH\n'
else
    endpoints_nginx_check_dir="$(newdir)"; tmpdirs+=("$endpoints_nginx_check_dir")
    printf '%s\n' "${endpoints_nginx_conf//kube-dns.kube-system.svc.cluster.local/127.0.0.1}" \
        > "$endpoints_nginx_check_dir/nginx.conf"
    # shellcheck disable=SC2016  # $upstream_key is nginx config, not shell
    printf 'set $upstream_key "dummy";\n' > "$endpoints_nginx_check_dir/upstream-key.conf"
    out="$(run_nginx_t "$endpoints_nginx_check_dir")"; rc=$?
    if (( rc == 0 )); then
        ok "nginx -t accepts the rendered K8S_PROXY_ENDPOINTS (keyless) proxy config"
    else
        no "nginx -t accepts the rendered K8S_PROXY_ENDPOINTS (keyless) proxy config" "$out"
    fi
fi

# Keyless by construction: no Secret, no upstream-key.conf include, no
# Authorization header anywhere in the render.
if grep -q 'kind: Secret' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install creates no Secret" "found 'kind: Secret' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install creates no Secret"
fi
if grep -q 'include /etc/nginx/upstream-key.conf' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install includes no upstream-key.conf" \
        "found the include in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install includes no upstream-key.conf"
fi
if grep -q 'Authorization' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install injects no Authorization header" \
        "found 'Authorization' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install injects no Authorization header"
fi
# The other half of "no Secret": the Deployment must not reference one
# either, via the volumeMount or the volume itself -- a render with no
# `kind: Secret` doc but a surviving `secretName: fork-sandbox-upstream-key`
# volume still fails at kubelet ("secret ... not found"), which the
# assertions above alone would not catch.
if grep -q 'secretName: fork-sandbox-upstream-key' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install references no upstream-key Secret volume" \
        "found 'secretName: fork-sandbox-upstream-key' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install references no upstream-key Secret volume"
fi
if grep -q 'name: upstream-key' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install carries no upstream-key volume/volumeMount" \
        "found 'name: upstream-key' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install carries no upstream-key volume/volumeMount"
fi

# K8S_PROXY_ALLOW replaces the default RFC1918-except egress block with
# exactly the given <cidr>:<port> entries.
allow_config_dir="$(newdir)"; tmpdirs+=("$allow_config_dir")
cat > "$allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_PROXY_ALLOW=10.0.0.5/32:8001,10.0.0.6/32:8000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
allow_out="$(newdir)/allow-install.yaml"; tmpdirs+=("$(dirname "$allow_out")")
FORK_SANDBOX_CONFIG_DIR="$allow_config_dir" "$k8s_sh" install --dry-run \
    > "$allow_out" 2>/tmp/fs-k8s-test-allow-install.err
proxy_netpol_allow_doc="$(extract_doc_by_kind NetworkPolicy "$allow_out")"
if grep -q 'cidr: 0.0.0.0/0' <<< "$proxy_netpol_allow_doc"; then
    no "K8S_PROXY_ALLOW replaces the default RFC1918-except block" \
        "still found 'cidr: 0.0.0.0/0' in the NetworkPolicy doc"
else
    ok "K8S_PROXY_ALLOW replaces the default RFC1918-except block"
fi
if grep -q 'cidr: 10.0.0.5/32' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'port: 8001' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'cidr: 10.0.0.6/32' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'port: 8000' <<< "$proxy_netpol_allow_doc"; then
    ok "K8S_PROXY_ALLOW renders exactly the given cidr:port entries"
else
    no "K8S_PROXY_ALLOW renders exactly the given cidr:port entries" "$proxy_netpol_allow_doc"
fi

# A set K8S_PROXY_ALLOW REPLACES the default egress rule wholesale rather
# than extending it -- so an entry it does not literally cover is just as
# unreachable as an http:// endpoint under the unset-K8S_PROXY_ALLOW
# default, and install must warn about it by name, not just the one entry
# that happened to prompt setting K8S_PROXY_ALLOW in the first place.
partial_allow_config_dir="$(newdir)"; tmpdirs+=("$partial_allow_config_dir")
cat > "$partial_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=a=http://10.0.0.5:8001/v1,b=http://10.0.0.6:9000/v1
K8S_PROXY_ALLOW=10.0.0.5/32:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
partial_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$partial_allow_config_dir" "$k8s_sh" install --dry-run \
    2>&1 >/dev/null)"
if [[ "$partial_allow_err" == *"'b'"* && "$partial_allow_err" == *"10.0.0.6"* ]]; then
    ok "a partial K8S_PROXY_ALLOW warns about the endpoint it does not cover"
else
    no "a partial K8S_PROXY_ALLOW warns about the endpoint it does not cover" "$partial_allow_err"
fi
if [[ "$partial_allow_err" == *"'a'"* ]]; then
    no "a partial K8S_PROXY_ALLOW does not also warn about the endpoint it does cover" \
        "$partial_allow_err"
else
    ok "a partial K8S_PROXY_ALLOW does not also warn about the endpoint it does cover"
fi

# A hostname in K8S_PROXY_ALLOW is refused -- NetworkPolicy has no hostname
# field, so the error says so rather than just "invalid".
hostname_allow_config_dir="$(newdir)"; tmpdirs+=("$hostname_allow_config_dir")
cat > "$hostname_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW=vllm.internal.example.com:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a hostname in K8S_PROXY_ALLOW is refused" \
    "NetworkPolicy has no hostname field" \
    env FORK_SANDBOX_CONFIG_DIR="$hostname_allow_config_dir" "$k8s_sh" install --dry-run

# http:// is accepted to a private address and refused to a public one, on
# both the legacy K8S_PROXY_UPSTREAM path and a K8S_PROXY_ENDPOINTS entry.
http_private_config_dir="$(newdir)"; tmpdirs+=("$http_private_config_dir")
cat > "$http_private_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=http://10.0.0.5:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$http_private_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-http-private.out 2>/tmp/fs-k8s-test-http-private.err; then
    ok "K8S_PROXY_UPSTREAM http:// to a private address is accepted"
else
    no "K8S_PROXY_UPSTREAM http:// to a private address is accepted" \
        "$(cat /tmp/fs-k8s-test-http-private.err)"
fi
# Accepted is not the same as reachable: this exact config's default
# egress policy excepts the only address it can ever dial (see
# validate_upstream_url's own header), so install must say so rather than
# render a NetworkPolicy that provably never lets this proxy connect.
if grep -q 'K8S_PROXY_ALLOW=<cidr>:<port> for this endpoint' /tmp/fs-k8s-test-http-private.err; then
    ok "K8S_PROXY_UPSTREAM http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable"
else
    no "K8S_PROXY_UPSTREAM http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable" \
        "$(cat /tmp/fs-k8s-test-http-private.err)"
fi

http_public_config_dir="$(newdir)"; tmpdirs+=("$http_public_config_dir")
cat > "$http_public_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=http://8.8.8.8
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_UPSTREAM http:// to a public address is refused" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$http_public_config_dir" "$k8s_sh" install --dry-run

endpoints_http_private_config_dir="$(newdir)"; tmpdirs+=("$endpoints_http_private_config_dir")
cat > "$endpoints_http_private_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$endpoints_http_private_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-endpoints-http-private.out 2>/tmp/fs-k8s-test-endpoints-http-private.err; then
    ok "K8S_PROXY_ENDPOINTS http:// to a private address is accepted"
else
    no "K8S_PROXY_ENDPOINTS http:// to a private address is accepted" \
        "$(cat /tmp/fs-k8s-test-endpoints-http-private.err)"
fi
# Same reachability warning as the legacy K8S_PROXY_UPSTREAM case above.
if grep -q 'K8S_PROXY_ALLOW=<cidr>:<port> for this endpoint' /tmp/fs-k8s-test-endpoints-http-private.err; then
    ok "K8S_PROXY_ENDPOINTS http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable"
else
    no "K8S_PROXY_ENDPOINTS http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable" \
        "$(cat /tmp/fs-k8s-test-endpoints-http-private.err)"
fi

endpoints_http_public_config_dir="$(newdir)"; tmpdirs+=("$endpoints_http_public_config_dir")
cat > "$endpoints_http_public_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://1.2.3.4:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_ENDPOINTS http:// to a public address is refused" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_http_public_config_dir" "$k8s_sh" install --dry-run

# An octet with a leading zero must never be read as octal by the (( ))
# arithmetic validate_upstream_url uses to classify an address as private
# -- "012" is decimal 12 (a public address), not octal 10 (private
# 10.5.6.7), so this must still be refused as public.
octal_octet_config_dir="$(newdir)"; tmpdirs+=("$octal_octet_config_dir")
cat > "$octal_octet_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://012.5.6.7:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "an octet with a leading zero is not read as octal (012 stays decimal 12, public)" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$octal_octet_config_dir" "$k8s_sh" install --dry-run

# A leading-zero octet that isn't valid octal ("08", "09") must not spew
# a bash arithmetic error instead of this function's own message.
invalid_octal_octet_config_dir="$(newdir)"; tmpdirs+=("$invalid_octal_octet_config_dir")
cat > "$invalid_octal_octet_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://08.0.0.1:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
invalid_octal_err="$(FORK_SANDBOX_CONFIG_DIR="$invalid_octal_octet_config_dir" "$k8s_sh" install --dry-run \
    2>&1 >/dev/null)"
# "not a private address" itself is not checked here -- validate_upstream_url
# wraps it across a line break ("...is not a\nprivate address...") that a
# plain substring match can't span; "is not a valid IPv4" is this
# function's other (unwrapped) message and proves the same thing.
if [[ "$invalid_octal_err" == *"value too great for base"* ]]; then
    no "a leading-zero octet that isn't valid octal fails with this function's own message" \
        "$invalid_octal_err"
elif [[ "$invalid_octal_err" == *"K8S_PROXY_ENDPOINTS entry 'primary'"* ]]; then
    ok "a leading-zero octet that isn't valid octal fails with this function's own message"
else
    no "a leading-zero octet that isn't valid octal fails with this function's own message" \
        "$invalid_octal_err"
fi

rm -f /tmp/fs-k8s-test-endpoints-install.err /tmp/fs-k8s-test-allow-install.err \
    /tmp/fs-k8s-test-http-private.out /tmp/fs-k8s-test-http-private.err \
    /tmp/fs-k8s-test-endpoints-http-private.out /tmp/fs-k8s-test-endpoints-http-private.err

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

# The cleanup trap must exist before Secret creation: a label failure leaves
# an unlabeled Secret behind, so only the explicit by-name delete can catch
# it. This stub makes that exact command fail and records the cleanup calls.
printf '\n== submit cleanup trap and safe-name uniqueness ==\n'
submit_stub_dir="$(newdir)"; tmpdirs+=("$submit_stub_dir")
cat > "$submit_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in create|apply|label|delete|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    create) printf 'apiVersion: v1\nkind: Secret\n' ;;
    apply) cat >/dev/null ;;
    label) exit 37 ;;
    delete) : ;;
    *) : ;;
esac
STUB
chmod +x "$submit_stub_dir/kubectl"
label_stub_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$label_stub_log")")
PATH="$submit_stub_dir:$PATH" K8S_STUB_LOG="$label_stub_log" HOME="$claude_home" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-label-failure --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-label.out 2>&1
label_rc=$?
if (( label_rc == 0 )); then
    no "label failure makes submit fail and invokes by-name Secret cleanup" "submit unexpectedly succeeded"
else
    if grep -q 'label secret fork-sandbox-agent-fs-k8s-test-label-failure-claude-token' "$label_stub_log" \
        && grep -q 'delete secret fork-sandbox-agent-fs-k8s-test-label-failure-claude-token' "$label_stub_log"; then
        ok "label failure makes submit fail and invokes by-name Secret cleanup"
    else
        no "label failure makes submit fail and invokes by-name Secret cleanup" "$(cat "$label_stub_log")"
    fi
fi
rm -f /tmp/fs-k8s-test-label.out

# Long branches with the same truncated prefix must still name distinct
# objects, while the already-pinned short naming rule remains unchanged.
name_branch_a="same-prefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-branch-one"
name_branch_b="same-prefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-branch-two"
name_a_out="$(newdir)/a.yaml"; tmpdirs+=("$(dirname "$name_a_out")")
name_b_out="$(newdir)/b.yaml"; tmpdirs+=("$(dirname "$name_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$name_branch_a" --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$name_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$name_branch_b" --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$name_b_out"
safe_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$name_a_out")"
safe_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$name_b_out")"
if [[ "$safe_a" != "$safe_b" && ${#safe_a} -le 50 && ${#safe_b} -le 50 ]]; then
    ok "long branch names get distinct safe names within the 50-byte cap"
else
    no "long branch names get distinct safe names within the 50-byte cap" "a='$safe_a' b='$safe_b'"
fi
if grep -q 'name: fork-sandbox-agent-fs-k8s-test-branch$' "$submit_out"; then
    ok "short branch safe name remains unchanged"
else
    no "short branch safe name remains unchanged" "expected pinned short name"
fi

# Normalization is lossy even for short branches. Each colliding pair must
# receive a digest-bearing name, so submitting one cannot overwrite the
# other's objects (and cleanup cannot remove the wrong run).
normalized_a_out="$(newdir)/normalized-a.yaml"; tmpdirs+=("$(dirname "$normalized_a_out")")
normalized_b_out="$(newdir)/normalized-b.yaml"; tmpdirs+=("$(dirname "$normalized_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch feature/foo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch feature-foo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_b_out"
normalized_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_a_out")"
normalized_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_b_out")"
if [[ "$normalized_a" != "$normalized_b" && "$normalized_a" =~ -[0-9a-f]{8}$ \
        && ${#normalized_a} -le 50 && ${#normalized_b} -le 50 ]]; then
    ok "slash and dash branch names get distinct digest-bearing safe names"
else
    no "slash and dash branch names get distinct digest-bearing safe names" \
        "a='$normalized_a' b='$normalized_b'"
fi

FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch FeatureFoo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch featurefoo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_b_out"
normalized_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_a_out")"
normalized_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_b_out")"
if [[ "$normalized_a" != "$normalized_b" && "$normalized_a" =~ -[0-9a-f]{8}$ \
        && ${#normalized_a} -le 50 && ${#normalized_b} -le 50 ]]; then
    ok "case-colliding branch names get distinct digest-bearing safe names"
else
    no "case-colliding branch names get distinct digest-bearing safe names" \
        "a='$normalized_a' b='$normalized_b'"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude (long branch name) ==\n'
# k8s_safe_name used to cap at 63 with no budget for the "-claude-proxy"
# suffix appended afterward, so any branch whose sanitized form was 32+
# characters rendered an over-63-char Service name and submit aborted after
# the Secret, ConfigMap and Pod for the run already existed. This branch's
# sanitized form is well past that threshold.
long_branch="claude-harness-review-fix-round-2-with-extra-words-appended-to-push-well-past-any-reasonable-cap"
long_submit_out="$(newdir)/claude-long-submit.yaml"; tmpdirs+=("$(dirname "$long_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$long_branch" --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$long_submit_out" 2>/tmp/fs-k8s-test-claude-long-submit.err; then
    ok "submit --dry-run --harness claude (long branch) exits 0"
else
    no "submit --dry-run --harness claude (long branch) exits 0" \
        "$(cat /tmp/fs-k8s-test-claude-long-submit.err)"
fi
# The claude-proxy Service name must still fit a Service's 63-char RFC 1035
# label cap once the "-claude-proxy" suffix (13 chars) lands on it.
long_proxy_name="$(grep -m1 '^kind: Service$' -A2 "$long_submit_out" \
    | sed -n 's/^ *name: //p')"
if [[ -n "$long_proxy_name" && ${#long_proxy_name} -le 63 ]]; then
    ok "long-branch claude-proxy Service name fits the 63-char label cap (${#long_proxy_name} chars)"
else
    no "long-branch claude-proxy Service name fits the 63-char label cap" \
        "name='$long_proxy_name' (${#long_proxy_name} chars) in $long_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-long-submit.err

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

printf '\n== fork-sandbox-k8s.sh submit/run --pi-args ==\n'
# --pi-args is extra arguments for the pod's pi coding leg. It travels
# the same path --model takes: into the rendered Job's env (PI_ARGS),
# then into the pi command line in the entrypoint -- and is refused, at
# parse time, on a claude run and for values fs_reject_unsafe_chars
# rejects, before anything is created.
pialg_submit_out="$(newdir)/pialg-submit.yaml"; tmpdirs+=("$(dirname "$pialg_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_submit_out" 2>/tmp/fs-k8s-test-pialg-submit.err; then
    ok "submit --dry-run --pi-args exits 0 and prints the rendered YAML"
else
    no "submit --dry-run --pi-args exits 0 and prints the rendered YAML" \
        "$(cat /tmp/fs-k8s-test-pialg-submit.err)"
fi
if grep -q 'name: PI_ARGS' "$pialg_submit_out" \
    && grep -A1 'name: PI_ARGS' "$pialg_submit_out" | grep -q 'value: "--thinking low"'; then
    ok "the rendered Job carries PI_ARGS with the value verbatim"
else
    no "the rendered Job carries PI_ARGS with the value verbatim" \
        "$(grep -A1 'name: PI_ARGS' "$pialg_submit_out")"
fi
rm -f /tmp/fs-k8s-test-pialg-submit.err

# submit_out above carries no --pi-args, so it must render no PI_ARGS env
# at all -- absence asserted, not an empty value.
if grep -q 'name: PI_ARGS' "$submit_out"; then
    no "a submit with no --pi-args renders no PI_ARGS env" \
        "found 'name: PI_ARGS' in $submit_out"
else
    ok "a submit with no --pi-args renders no PI_ARGS env"
fi

# The pod-side half of the contract: run_pi_coding_leg, extracted from
# the entrypoint's own source and run against a stubbed pi that records
# its argv -- the same function-extraction this suite uses for
# discover_model_facts. The stub's record is its own argv count first, so
# an empty-string argument (which pi would see as a positional) is
# visible even at the end of the line.
pialg_fn="$(sed -n '/^run_pi_coding_leg() {/,/^}/p' "$entrypoint_sh")"
pialg_fn_file="$(newdir)/run-pi-leg.sh"; tmpdirs+=("$(dirname "$pialg_fn_file")")
if [[ -n "$pialg_fn" ]]; then
    printf '%s\n' 'set -euo pipefail' \
        ': "${PI_ARGS:=}"' \
        "$pialg_fn" \
        'run_pi_coding_leg' > "$pialg_fn_file"
    ok "run_pi_coding_leg is a standalone function in the entrypoint"
else
    no "run_pi_coding_leg is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi
# $1 = the PI_ARGS value to pass (unset when called with no argument).
# PIALG_RECORD ends up holding the stub pi's recorded argv (count line
# first, then one argument per line). Called directly, never inside a
# command substitution, so the tmpdirs it registers are not lost in a
# subshell.
PIALG_RECORD=""
pialg_run() {
    local stub_dir record mounts work
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    record="$(newdir)/pi-argv.txt"; tmpdirs+=("$(dirname "$record")")
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$#" > "$PI_ARGV_RECORD"' \
        'printf "%s\n" "$@" >> "$PI_ARGV_RECORD"' \
        'exit 0' > "$stub_dir/pi"
    chmod +x "$stub_dir/pi"
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    work="$(newdir)"; tmpdirs+=("$work")
    printf 'Do the thing.\n' > "$mounts/handoff.md"
    PIALG_RECORD="$record"
    if [[ $# -gt 0 ]]; then
        PI_ARGS="$1" PI_ARGV_RECORD="$record" PATH="$stub_dir:$PATH" \
            MODEL="moonshotai/kimi-k3" mounts_dir="$mounts" work_dir="$work" \
            bash "$pialg_fn_file" >/dev/null
    else
        PI_ARGV_RECORD="$record" PATH="$stub_dir:$PATH" \
            MODEL="moonshotai/kimi-k3" mounts_dir="$mounts" work_dir="$work" \
            bash "$pialg_fn_file" >/dev/null
    fi
}
# The stub's $@ never includes the command name itself, so the base
# invocation records seven arguments.
pialg_base="--provider
proxy
--model
moonshotai/kimi-k3
--mode
json
-p"
pialg_run "--thinking low"
pialg_two="$(cat "$PIALG_RECORD")"
pialg_expected_two="$pialg_base"$'\n--thinking\nlow'
if [[ "$(printf '%s\n' "$pialg_two" | head -n1)" == 9 ]] \
    && [[ "$(printf '%s\n' "$pialg_two" | tail -n2)" == $'--thinking\nlow' ]] \
    && printf '%s\n' "$pialg_two" | grep -qx -- '--thinking' \
    && printf '%s\n' "$pialg_two" | grep -qx -- 'low' \
    && ! printf '%s\n' "$pialg_two" | grep -qxF -- '--thinking low' \
    && [[ "$(printf '%s\n' "$pialg_two" | tail -n +2)" == "$pialg_expected_two" ]]; then
    ok "the entrypoint's pi line receives PI_ARGS as two arguments, appended to the base flags"
else
    no "the entrypoint's pi line receives PI_ARGS as two arguments, appended to the base flags" \
        "record: $(printf '%s\n' "$pialg_two" | tr '\n' '|')"
fi
pialg_run
pialg_none="$(cat "$PIALG_RECORD")"
pialg_run ""
pialg_empty="$(cat "$PIALG_RECORD")"
for case_none in "none:$pialg_none" "empty:$pialg_empty"; do
    pialg_case_name="${case_none%%:*}"
    pialg_case_val="${case_none#*:}"
    if [[ "$(printf '%s\n' "$pialg_case_val" | head -n1)" == 7 ]] \
        && [[ "$(printf '%s\n' "$pialg_case_val" | tail -n +2)" == "$pialg_base" ]]; then
        ok "an unset/empty PI_ARGS adds no arguments at all ($pialg_case_name)"
    else
        no "an unset/empty PI_ARGS adds no arguments at all ($pialg_case_name)" \
            "record: $(printf '%s\n' "$pialg_case_val" | tr '\n' '|')"
    fi
done

# An unsafe character in the value is refused at parse time -- and the
# refusal is before any Job, Secret or proxy Pod exists. Proven against a
# stubbed kubectl (no --dry-run here) whose log must stay empty.
refuses "submit --pi-args with a single quote is refused" \
    "single quote" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking it's" \
    "$proj_dir" "$handoff_file"
# A double quote and a backslash are refused too: the rendered Job embeds
# the value as a double-quoted YAML scalar, where a quote would break the
# manifest and a backslash would be re-escaped by the YAML parser into a
# value different from the one split and passed to pi.
refuses "submit --pi-args with a double quote is refused" \
    "double quote" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a"b' \
    "$proj_dir" "$handoff_file"
refuses "submit --pi-args with a backslash is refused" \
    "backslash" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a\nb' \
    "$proj_dir" "$handoff_file"
pialg_stub_bin="$(newdir)"; tmpdirs+=("$pialg_stub_bin")
pialg_klog="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pialg_klog")")
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$K8S_STUB_LOG"' > "$pialg_stub_bin/kubectl"
chmod +x "$pialg_stub_bin/kubectl"
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking it's" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'single quote' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a refused --pi-args value creates nothing (the stubbed kubectl recorded no call)"
else
    no "a refused --pi-args value creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out
# Same "nothing created" proof for the YAML-scalar rejections: a double
# quote and a backslash must also die before the first kubectl call.
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a"b' \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'double quote' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a --pi-args value with a double quote creates nothing (the stubbed kubectl recorded no call)"
else
    no "a --pi-args value with a double quote creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a\nb' \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'backslash' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a --pi-args value with a backslash creates nothing (the stubbed kubectl recorded no call)"
else
    no "a --pi-args value with a backslash creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out

refuses "submit --pi-args with --harness claude is refused" \
    "passes flags to pi, which a claude run" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file"

# run forwards --pi-args to submit unchanged: the same arguments must
# render byte-for-byte the same YAML as the direct submit call.
pialg_run_out="$(newdir)/pialg-run.yaml"; tmpdirs+=("$(dirname "$pialg_run_out")")
pialg_run_err="$(newdir)/pialg-run.err"; tmpdirs+=("$(dirname "$pialg_run_err")")
pialg_run_submit_out="$(newdir)/pialg-run-submit.yaml"; tmpdirs+=("$(dirname "$pialg_run_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_run_out" 2>"$pialg_run_err" \
    && FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_run_submit_out" 2>/dev/null; then
    ok "run --dry-run --pi-args exits 0"
else
    no "run --dry-run --pi-args exits 0" "$(cat "$pialg_run_err")"
fi
if diff -q "$pialg_run_out" "$pialg_run_submit_out" >/dev/null 2>&1; then
    ok "run --dry-run --pi-args renders byte-for-byte the same YAML as submit (forwarded unchanged)"
else
    no "run --dry-run --pi-args renders byte-for-byte the same YAML as submit (forwarded unchanged)" \
        "$(diff "$pialg_run_out" "$pialg_run_submit_out" 2>&1 | head -n 20)"
fi

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
# Item: --harness claude --review-loop with no --review-model is refused
# here directly, not just by fork-sandbox.sh's own --k8s gate -- this
# script is a documented direct entry point in its own right, and without
# this check a bad direct invocation would only fail pod-side, after the
# proxy Pod, the token Secret, the Job and a full repository push already
# exist for the run.
refuses "submit --harness claude --review-loop without --review-model is refused" \
    "--review-model is required with --harness claude" \
    env HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-branch --model claude-sonnet-5 --harness claude --review-loop 2 \
    "$proj_dir" "$handoff_file"

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
# before the Job exists or the repository is pushed.
cr_hl_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-hl.XXXXXX)"; tmpdirs+=("$cr_hl_dir")
printf 'x\n' > "$cr_hl_dir/f.txt"
ln "$cr_hl_dir/f.txt" "$cr_hl_dir/g.txt"
refuses "submit --context-ro containing a hard link is refused" \
    "contains a hard-linked file" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-hl --model moonshotai/kimi-k3 --context-ro "$cr_hl_dir" \
    "$proj_dir" "$handoff_file"

# A single hard-linked file is refused even when its other name is outside
# the context tree; link count, rather than duplicate in-tree inodes, is the
# security property being checked.
cr_ext_parent="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-ext.XXXXXX)"; tmpdirs+=("$cr_ext_parent")
cr_ext_dir="$cr_ext_parent/context"; mkdir "$cr_ext_dir"
printf 'outside-linked\n' > "$cr_ext_parent/outside.txt"
ln "$cr_ext_parent/outside.txt" "$cr_ext_dir/inside.txt"
refuses "submit --context-ro refuses a file hard-linked outside the tree" \
    "inside.txt" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-external-link --model moonshotai/kimi-k3 --context-ro "$cr_ext_dir" \
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

# The host-side archive cap is checked before any kubectl apply. A tar stub
# makes a sparse over-cap archive without allocating 256 MiB of test data.
cr_big_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-big.XXXXXX)"; tmpdirs+=("$cr_big_dir")
printf 'too large\n' > "$cr_big_dir/file.txt"
cr_order_stub="$(newdir)"; tmpdirs+=("$cr_order_stub")
cat > "$cr_order_stub/tar" <<'STUB'
#!/usr/bin/env bash
truncate -s $((256 * 1024 * 1024 + 1)) "$2"
STUB
chmod +x "$cr_order_stub/tar"
cr_order_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cr_order_log")")
cr_order_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$cr_order_kubectl")")
cat > "$cr_order_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
STUB
chmod +x "$cr_order_kubectl"
PATH="$cr_order_stub:$(dirname "$cr_order_kubectl"):$PATH" K8S_STUB_LOG="$cr_order_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-cr-over-cap --model moonshotai/kimi-k3 --context-ro "$cr_big_dir" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-cr-big.out 2>&1
cr_order_rc=$?
if (( cr_order_rc == 0 )); then
    no "oversized context is refused before kubectl apply" "submit unexpectedly succeeded"
else
    if [[ ! -s "$cr_order_log" ]] && grep -q 'over the .* byte' /tmp/fs-k8s-test-cr-big.out; then
        ok "oversized context is refused before kubectl apply"
    else
        no "oversized context is refused before kubectl apply" "log=$(cat "$cr_order_log") out=$(cat /tmp/fs-k8s-test-cr-big.out)"
    fi
fi
rm -f /tmp/fs-k8s-test-cr-big.out

# A context exec failure must remove the already-sized host archive. The git
# wrapper lets validation and the repository push complete without a remote;
# the kubectl stub fails only the context exec and records every call.
cr_exec_tmp="$(newdir)"; tmpdirs+=("$cr_exec_tmp")
cr_exec_git="$(newdir)/git"; tmpdirs+=("$(dirname "$cr_exec_git")")
cat > "$cr_exec_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
chmod +x "$cr_exec_git"
cr_exec_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$cr_exec_kubectl")")
cat > "$cr_exec_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec) cat >/dev/null; exit 19 ;;
esac
STUB
chmod +x "$cr_exec_kubectl"
cr_exec_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cr_exec_log")")
PATH="$(dirname "$cr_exec_git"):$(dirname "$cr_exec_kubectl"):$PATH" \
    TMPDIR="$cr_exec_tmp" K8S_STUB_LOG="$cr_exec_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-cr-exec-failure --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-cr-exec.out 2>&1
cr_exec_rc=$?
if (( cr_exec_rc == 0 )); then
    no "context exec failure removes the temporary archive" "submit unexpectedly succeeded"
else
    if [[ -z "$(find "$cr_exec_tmp" -type f -print -quit)" ]] \
        && grep -q 'exec -i stub-pod' "$cr_exec_log"; then
        ok "context exec failure removes the temporary archive"
    else
        no "context exec failure removes the temporary archive" "tmp=$(find "$cr_exec_tmp" -type f) log=$(cat "$cr_exec_log")"
    fi
fi
rm -f /tmp/fs-k8s-test-cr-exec.out

printf '\n== fork-sandbox-k8s.sh run: poll/fetch/pull-back vs stubbed kubectl ==\n'
# The sequence cmd_run drives after submit was previously only executable
# against a live cluster (see this file's header); it is now driven end to
# end with a stubbed git (no-ops the ext:: push/fetch) and a stubbed
# kubectl (logs every invocation, serves canned answers). The outbox read
# -- the kubectl exec that tars /work/outbox -- is controlled through the
# environment: it always tars K8S_STUB_OUTBOX_DIR when that is set, then
# exits with K8S_STUB_OUTBOX_RC and writes K8S_STUB_OUTBOX_STDERR to stderr
# -- RC is independent of the streaming, which is what lets a test pair a
# large stream with EPIPE's status.
runstub_dir="$(newdir)"; tmpdirs+=("$runstub_dir")
cat > "$runstub_dir/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$runstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" apply -f -"*) cat >/dev/null; exit 0 ;;
    *" wait "*) exit 0 ;;
    *" get "*) printf 'stub-pod\n' ;;
    *" delete "*) exit 0 ;;
    *" tar cf - -C /work/outbox "*)
        # Serve the fixture stream whenever K8S_STUB_OUTBOX_DIR is set,
        # independently of the exit status -- a kubectl exec that dies of
        # EPIPE partway through an over-cap stream has already streamed
        # data, so callers can pair a large fixture with a non-zero RC.
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_OUTBOX_STDERR:-}" ]] && printf '%s' "$K8S_STUB_OUTBOX_STDERR" >&2
        exit "${K8S_STUB_OUTBOX_RC:-1}"
        ;;
    *" cat /work/.run-complete "*) printf '0\n' ;;
esac
exit 0
STUB
chmod +x "$runstub_dir/git" "$runstub_dir/kubectl"
runstub_pod_outbox="$(newdir)"; tmpdirs+=("$runstub_pod_outbox")
printf 'an artifact\n' > "$runstub_pod_outbox/hello.txt"
runstub_run() {
    # $1 = kubectl log, $2 = output file, rest = fork-sandbox-k8s.sh run args.
    # K8S_STUB_OUTBOX_DIR may be set by the caller to serve a different
    # pod-side outbox fixture than the default one.
    local log="$1" out="$2"; shift 2
    PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$log" \
        K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" run "$@" > "$out" 2>&1
}

# 1. A failed outbox read must surface kubectl's own stderr: the stub's
# exec writes a recognizable string to stderr and exits non-zero, and the
# operator sees both the existing warning and that string.
runstub_log1="$(newdir)/kubectl.log"; runstub_out1="$(newdir)/out1.txt"
tmpdirs+=("$(dirname "$runstub_log1")" "$(dirname "$runstub_out1")")
if K8S_STUB_OUTBOX_STDERR='stub-kubectl says: pod stub-pod is already Completed' \
    K8S_STUB_OUTBOX_RC=1 runstub_run "$runstub_log1" "$runstub_out1" \
    --branch fs-k8s-test-run-outbox-err --model moonshotai/kimi-k3 \
    --outbox-dir "$(dirname "$runstub_out1")/outbox-1" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'warning: could not read the outbox' "$runstub_out1" \
        && grep -q 'stub-kubectl says: pod stub-pod is already Completed' "$runstub_out1" \
        && grep -q 'run complete' "$runstub_out1"; then
        ok "failed outbox read surfaces kubectl's own stderr"
    else
        no "failed outbox read surfaces kubectl's own stderr" "$(cat "$runstub_out1")"
    fi
else
    no "failed outbox read surfaces kubectl's own stderr" "run exited nonzero: $(cat "$runstub_out1")"
fi

# 2. A failed read with NOTHING on stderr is reported as silent, not as an
# empty block: the explicit "wrote nothing" line, and not the heading the
# non-empty case prints.
runstub_log2="$(newdir)/kubectl.log"; runstub_out2="$(newdir)/out2.txt"
tmpdirs+=("$(dirname "$runstub_log2")" "$(dirname "$runstub_out2")")
if K8S_STUB_OUTBOX_STDERR='' K8S_STUB_OUTBOX_RC=1 \
    runstub_run "$runstub_log2" "$runstub_out2" \
    --branch fs-k8s-test-run-outbox-silent --model moonshotai/kimi-k3 \
    --outbox-dir "$(dirname "$runstub_out2")/outbox-2" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'wrote nothing to stderr' "$runstub_out2" \
        && ! grep -q 'reported, on stderr:' "$runstub_out2"; then
        ok "failed outbox read with empty stderr is reported as silent"
    else
        no "failed outbox read with empty stderr is reported as silent" "$(cat "$runstub_out2")"
    fi
else
    no "failed outbox read with empty stderr is reported as silent" "run exited nonzero: $(cat "$runstub_out2")"
fi

# 3. The regression test for the ordering: the stubbed kubectl logs every
# invocation, and the outbox tar read must appear in that log BEFORE the
# fetch's touch /work/.fetched -- which is what makes the pod exit, and a
# kubectl exec into a completed pod fails. The same log line must carry
# the request-timeout bound that keeps a hung read from delaying the
# fetch indefinitely.
runstub_log3="$(newdir)/kubectl.log"; runstub_out3="$(newdir)/out3.txt"; runstub_dest3="$(newdir)/outbox-3"
tmpdirs+=("$(dirname "$runstub_log3")" "$(dirname "$runstub_out3")" "$(dirname "$runstub_dest3")")
if K8S_STUB_OUTBOX_RC=0 runstub_run "$runstub_log3" "$runstub_out3" \
    --branch fs-k8s-test-run-ordering --model moonshotai/kimi-k3 \
    --outbox-dir "$runstub_dest3" \
    "$proj_dir" "$handoff_file"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    tar_ln="$(grep -n 'tar cf - -C /work/outbox' "$runstub_log3" | head -n 1 | cut -d: -f1 || true)"
    fetched_ln="$(grep -n 'touch /work/.fetched' "$runstub_log3" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$tar_ln" && -n "$fetched_ln" ]] && (( tar_ln < fetched_ln )) \
        && grep -q -- '--request-timeout=60s' <(sed -n "${tar_ln}p" "$runstub_log3") \
        && [[ -f "$runstub_dest3/hello.txt" ]] \
        && grep -q 'outbox: 1 file(s) at' "$runstub_out3"; then
        ok "outbox is pulled back before the fetch touches /work/.fetched"
        ok "the outbox kubectl exec carries a request-timeout bound"
    else
        no "outbox is pulled back before the fetch touches /work/.fetched" \
            "tar_ln=$tar_ln fetched_ln=$fetched_ln dest=$(find "$runstub_dest3" 2>/dev/null) out=$(cat "$runstub_out3")"
    fi
else
    no "outbox is pulled back before the fetch touches /work/.fetched" "run exited nonzero: $(cat "$runstub_out3")"
fi

# 4. A substantially-over-cap outbox is the over-cap case, not a read
# failure: with set -o pipefail in force, head -c exiting early makes
# kubectl die of EPIPE and the pipeline non-zero. K8S_STUB_OUTBOX_RC=141
# (bash's SIGPIPE status) emulates that EPIPE on a stream that is well
# past the cap -- the run must warn about the cap, not report a failed
# read, and must not extract anything.
runstub_big_outbox="$(newdir)"; tmpdirs+=("$runstub_big_outbox")
head -c 4096 /dev/zero > "$runstub_big_outbox/big.bin"
runstub_log4="$(newdir)/kubectl.log"; runstub_out4="$(newdir)/out4.txt"; runstub_dest4="$(newdir)/outbox-4"
tmpdirs+=("$(dirname "$runstub_log4")" "$(dirname "$runstub_out4")" "$(dirname "$runstub_dest4")")
if K8S_STUB_OUTBOX_DIR="$runstub_big_outbox" K8S_STUB_OUTBOX_RC=141 \
    runstub_run "$runstub_log4" "$runstub_out4" \
    --branch fs-k8s-test-run-outbox-overcap --model moonshotai/kimi-k3 \
    --outbox-max 128 \
    --outbox-dir "$runstub_dest4" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'over the 128 byte cap; refusing to pull it back' "$runstub_out4" \
        && ! grep -q 'could not read the outbox' "$runstub_out4" \
        && [[ ! -d "$runstub_dest4" ]] \
        && grep -q 'run complete' "$runstub_out4"; then
        ok "substantially-over-cap outbox is diagnosed as over the cap, not a read failure"
    else
        no "substantially-over-cap outbox is diagnosed as over the cap, not a read failure" \
            "dest=$(find "$runstub_dest4" 2>/dev/null) out=$(cat "$runstub_out4")"
    fi
else
    no "substantially-over-cap outbox is diagnosed as over the cap, not a read failure" "run exited nonzero: $(cat "$runstub_out4")"
fi

# 5. The review-loop.json read is the second kubectl exec in run's tail
# sequence that can execute while the pod is idle, so it must carry the
# same --request-timeout bound as the outbox read: a --review-loop run's
# kubectl log shows the bound on that exec too.
runstub_log5="$(newdir)/kubectl.log"; runstub_out5="$(newdir)/out5.txt"
tmpdirs+=("$(dirname "$runstub_log5")" "$(dirname "$runstub_out5")")
if runstub_run "$runstub_log5" "$runstub_out5" \
    --branch fs-k8s-test-run-loop-timeout --model moonshotai/kimi-k3 \
    --review-loop 1 \
    --outbox-dir "$(dirname "$runstub_out5")/outbox-5" \
    "$proj_dir" "$handoff_file"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    loop_ln="$(grep -n 'cat /work/review-loop.json' "$runstub_log5" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$loop_ln" ]] \
        && grep -q -- '--request-timeout=60s' <(sed -n "${loop_ln}p" "$runstub_log5"); then
        ok "the review-loop.json kubectl exec carries a request-timeout bound"
    else
        no "the review-loop.json kubectl exec carries a request-timeout bound" \
            "loop_ln=$loop_ln out=$(cat "$runstub_out5")"
    fi
else
    no "the review-loop.json kubectl exec carries a request-timeout bound" "run exited nonzero: $(cat "$runstub_out5")"
fi

printf '\n== fork-sandbox-k8s.sh wait: direct drive vs stubbed kubectl ==\n'
# The extracted wait verb, driven directly against a stubbed kubectl that
# serves canned pod/job answers through the environment. The distinction
# under test is the whole reason the verb exists: a non-zero AGENT exit is
# a successful wait that prints the code to stdout, while a non-zero wait
# exit means the wait itself failed.
waitstub_dir="$(newdir)"; tmpdirs+=("$waitstub_dir")
cat > "$waitstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" get pod -l job-name="*)
        [[ -n "${K8S_STUB_POD_NAME:-}" ]] && printf '%s\n' "$K8S_STUB_POD_NAME"
        exit 0 ;;
    *" get pod "*)
        printf '%s' "${K8S_STUB_POD_PHASE:-Running}"
        exit 0 ;;
    *" get job "*)
        printf '%s' "${K8S_STUB_JOB_FAILED:-False}"
        exit 0 ;;
    *" cat /work/.run-complete "*)
        [[ -n "${K8S_STUB_RUN_COMPLETE:-}" ]] && printf '%s\n' "$K8S_STUB_RUN_COMPLETE"
        exit "${K8S_STUB_SENTINEL_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$waitstub_dir/kubectl"
waitstub_wait() {
    # $1 = kubectl log, $2 = stdout file, $3 = stderr file, rest = wait
    # args. K8S_STUB_* env vars, set by the caller, control the pod's
    # answers (sentinel value/rc, pod phase, job condition).
    local log="$1" out="$2" err="$3"; shift 3
    K8S_STUB_POD_NAME="${K8S_STUB_POD_NAME:-stub-pod}" \
    PATH="$waitstub_dir:$PATH" K8S_STUB_LOG="$log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" wait "$@" > "$out" 2> "$err"
}

# 1. Sentinel present: the agent's exit code lands on stdout, alone, and
# the wait exits 0 even though the agent itself exited non-zero.
wait_log1="$(newdir)/kubectl.log"; wait_out1="$(newdir)/out1.txt"; wait_err1="$(newdir)/err1.txt"
tmpdirs+=("$(dirname "$wait_log1")")
if K8S_STUB_RUN_COMPLETE=3 K8S_STUB_SENTINEL_RC=0 \
    waitstub_wait "$wait_log1" "$wait_out1" "$wait_err1" \
    --branch fs-k8s-test-wait-rc --timeout 5; then
    if [[ "$(cat "$wait_out1")" == "3" ]] \
        && grep -q 'agent finished (exit 3)' "$wait_err1"; then
        ok "a completed wait prints the agent exit code to stdout, alone"
    else
        no "a completed wait prints the agent exit code to stdout, alone" \
            "stdout='$(cat "$wait_out1")' stderr='$(cat "$wait_err1")'"
    fi
else
    no "a completed wait prints the agent exit code to stdout, alone" "wait exited nonzero: $(cat "$wait_err1")"
fi

# 2. A Failed pod: the wait itself fails with the TERMINAL code 2 (the
# run can never complete through this wait again -- a probe loop must
# give the seat up, not re-probe it), naming the pod.
wait_log2="$(newdir)/kubectl.log"; wait_out2="$(newdir)/out2.txt"; wait_err2="$(newdir)/err2.txt"
tmpdirs+=("$(dirname "$wait_log2")")
rc=0
K8S_STUB_POD_PHASE=Failed \
    waitstub_wait "$wait_log2" "$wait_out2" "$wait_err2" \
    --branch fs-k8s-test-wait-podfailed --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'pod stub-pod is Failed -- it died before writing' "$wait_err2"; then
    ok "a Failed pod fails the wait with the terminal code 2"
else
    no "a Failed pod fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err2")"
fi

# 3. A Failed job condition: the wait itself fails with the terminal
# code 2, naming the job.
wait_log3="$(newdir)/kubectl.log"; wait_out3="$(newdir)/out3.txt"; wait_err3="$(newdir)/err3.txt"
tmpdirs+=("$(dirname "$wait_log3")")
rc=0
K8S_STUB_JOB_FAILED=True \
    waitstub_wait "$wait_log3" "$wait_out3" "$wait_err3" \
    --branch fs-k8s-test-wait-jobfailed --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'reports a Failed condition' "$wait_err3"; then
    ok "a Failed job condition fails the wait with the terminal code 2"
else
    no "a Failed job condition fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err3")"
fi

# 4. No sentinel by the deadline: the wait itself fails with code 1 --
# NOT the terminal 2, because the run may still be going and a probe
# loop must try again -- with the fetch-by-hand advice. --timeout 0
# trips on the first probe, so no 10s poll sleep.
wait_log4="$(newdir)/kubectl.log"; wait_out4="$(newdir)/out4.txt"; wait_err4="$(newdir)/err4.txt"
tmpdirs+=("$(dirname "$wait_log4")")
rc=0
waitstub_wait "$wait_log4" "$wait_out4" "$wait_err4" \
    --branch fs-k8s-test-wait-timeout --timeout 0 || rc=$?
if (( rc == 1 )) && grep -q 'timed out after 0s waiting for branch' "$wait_err4" \
    && grep -q 'Fetch by hand once it' "$wait_err4"; then
    ok "a timed-out wait fails with code 1 and the fetch-by-hand advice"
else
    no "a timed-out wait fails with code 1 and the fetch-by-hand advice" "rc=$rc: $(cat "$wait_err4")"
fi

# 5. A malformed sentinel: the wait fails rather than guessing, with the
# terminal code 2 (the sentinel will not repair itself; no further wait
# can succeed).
wait_log5="$(newdir)/kubectl.log"; wait_out5="$(newdir)/out5.txt"; wait_err5="$(newdir)/err5.txt"
tmpdirs+=("$(dirname "$wait_log5")")
rc=0
K8S_STUB_RUN_COMPLETE='not-a-number' K8S_STUB_SENTINEL_RC=0 \
    waitstub_wait "$wait_log5" "$wait_out5" "$wait_err5" \
    --branch fs-k8s-test-wait-malformed --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'does not hold an' "$wait_err5" \
    && grep -q "integer exit code (got: 'not-a-number')" "$wait_err5"; then
    ok "a malformed sentinel fails the wait with the terminal code 2"
else
    no "a malformed sentinel fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err5")"
fi

# 6. A Succeeded pod: the run finished and its container has since exited
# (TTL idled out, or already fetched), so the sentinel can no longer be
# read via exec. The wait must fail fast on the first probe -- not poll to
# its own timeout on a run that can never become executable again -- and
# must NOT advise a by-hand fetch: fetch and collect both run through
# kubectl exec, which cannot reach an exited container, so the only
# by-hand steps left are the logs pointer and the rm.
wait_log6="$(newdir)/kubectl.log"; wait_out6="$(newdir)/out6.txt"; wait_err6="$(newdir)/err6.txt"
tmpdirs+=("$(dirname "$wait_log6")")
rc=0
K8S_STUB_POD_PHASE=Succeeded \
    waitstub_wait "$wait_log6" "$wait_out6" "$wait_err6" \
    --branch fs-k8s-test-wait-podsucceeded --timeout 0 || rc=$?
if (( rc == 2 )) && grep -q 'pod stub-pod is Succeeded -- the run completed and' "$wait_err6" \
    && grep -q 'unreachable through this tool' "$wait_err6" \
    && ! grep -q 'fetch --branch' "$wait_err6" \
    && ! grep -q 'timed out' "$wait_err6"; then
    ok "a Succeeded pod fails the wait with the terminal code 2, without fetch advice"
else
    no "a Succeeded pod fails the wait with the terminal code 2, without fetch advice" "rc=$rc: $(cat "$wait_err6")"
fi

printf '\n== fork-sandbox-k8s.sh collect: direct drive vs stubbed kubectl ==\n'
# The extracted collect verb, driven directly against a stubbed git+kubectl
# pair: the same outbox machinery run drives, with the pod's answers
# controlled through the environment.
collectstub_dir="$(newdir)"; tmpdirs+=("$collectstub_dir")
cat > "$collectstub_dir/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$collectstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" get pod -l job-name="*)
        [[ -n "${K8S_STUB_POD_NAME:-}" ]] && printf '%s\n' "$K8S_STUB_POD_NAME"
        exit 0 ;;
    *" cat /work/review-loop.json "*)
        [[ -n "${K8S_STUB_REVIEW_LOOP_JSON:-}" ]] && printf '%s' "$K8S_STUB_REVIEW_LOOP_JSON"
        exit "${K8S_STUB_REVIEW_LOOP_RC:-0}" ;;
    *" tar cf - -C /work/outbox "*)
        # Serve the fixture stream whenever K8S_STUB_OUTBOX_DIR is set,
        # independently of the exit status -- same trick the runstub uses
        # above.
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_OUTBOX_STDERR:-}" ]] && printf '%s' "$K8S_STUB_OUTBOX_STDERR" >&2
        exit "${K8S_STUB_OUTBOX_RC:-1}" ;;
    *" delete "*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$collectstub_dir/git" "$collectstub_dir/kubectl"
collectstub_collect() {
    # $1 = kubectl log, $2 = output file, rest = collect args.
    local log="$1" out="$2"; shift 2
    K8S_STUB_POD_NAME="${K8S_STUB_POD_NAME:-stub-pod}" \
    PATH="$collectstub_dir:$PATH" K8S_STUB_LOG="$log" \
    K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" collect "$@" > "$out" 2>&1
}

# 1. A readable outbox lands at the --outbox-dir path, and the fetch still
# happens.
collect_log1="$(newdir)/kubectl.log"; collect_out1="$(newdir)/out1.txt"; collect_dest1="$(newdir)/outbox-1"
tmpdirs+=("$(dirname "$collect_log1")" "$(dirname "$collect_dest1")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log1" "$collect_out1" \
    --branch fs-k8s-test-collect-outbox --outbox-dir "$collect_dest1" "$proj_dir"; then
    if [[ -f "$collect_dest1/hello.txt" ]] \
        && grep -q "outbox: 1 file(s) at $collect_dest1" "$collect_out1" \
        && grep -q 'fetched into' "$collect_out1"; then
        ok "collect lands the outbox at --outbox-dir and fetches"
    else
        no "collect lands the outbox at --outbox-dir and fetches" \
            "dest=$(find "$collect_dest1" 2>/dev/null) out=$(cat "$collect_out1")"
    fi
else
    no "collect lands the outbox at --outbox-dir and fetches" "collect exited nonzero: $(cat "$collect_out1")"
fi

# 2. An over-cap outbox is refused -- and only the pull-back is refused:
# the fetch must still complete and collect must still exit 0.
collect_log2="$(newdir)/kubectl.log"; collect_out2="$(newdir)/out2.txt"; collect_dest2="$(newdir)/outbox-2"
tmpdirs+=("$(dirname "$collect_log2")" "$(dirname "$collect_dest2")")
if K8S_STUB_OUTBOX_DIR="$runstub_big_outbox" K8S_STUB_OUTBOX_RC=141 \
    collectstub_collect "$collect_log2" "$collect_out2" \
    --branch fs-k8s-test-collect-overcap --outbox-max 128 --outbox-dir "$collect_dest2" "$proj_dir"; then
    if grep -q 'over the 128 byte cap; refusing to pull it back' "$collect_out2" \
        && ! grep -q 'could not read the outbox' "$collect_out2" \
        && [[ ! -d "$collect_dest2" ]] \
        && grep -q 'fetched into' "$collect_out2"; then
        ok "collect refuses an over-cap outbox without costing the fetch"
    else
        no "collect refuses an over-cap outbox without costing the fetch" \
            "dest=$(find "$collect_dest2" 2>/dev/null) out=$(cat "$collect_out2")"
    fi
else
    no "collect refuses an over-cap outbox without costing the fetch" "collect exited nonzero: $(cat "$collect_out2")"
fi

# 3. An unreadable outbox warns, falls through, and the fetch succeeds.
collect_log3="$(newdir)/kubectl.log"; collect_out3="$(newdir)/out3.txt"; collect_dest3="$(newdir)/outbox-3"
tmpdirs+=("$(dirname "$collect_log3")" "$(dirname "$collect_dest3")")
if K8S_STUB_OUTBOX_STDERR='stub-kubectl says: outbox read exploded' K8S_STUB_OUTBOX_RC=1 \
    collectstub_collect "$collect_log3" "$collect_out3" \
    --branch fs-k8s-test-collect-outbox-err --outbox-dir "$collect_dest3" "$proj_dir"; then
    if grep -q 'warning: could not read the outbox' "$collect_out3" \
        && grep -q 'stub-kubectl says: outbox read exploded' "$collect_out3" \
        && grep -q 'fetched into' "$collect_out3"; then
        ok "collect warns on an unreadable outbox and still fetches"
    else
        no "collect warns on an unreadable outbox and still fetches" "$(cat "$collect_out3")"
    fi
else
    no "collect warns on an unreadable outbox and still fetches" "collect exited nonzero: $(cat "$collect_out3")"
fi

# 4. --review-loop 1 reports an approved outcome.
collect_log4="$(newdir)/kubectl.log"; collect_out4="$(newdir)/out4.txt"; collect_dest4="$(newdir)/outbox-4"
tmpdirs+=("$(dirname "$collect_log4")" "$(dirname "$collect_dest4")")
if K8S_STUB_OUTBOX_RC=0 K8S_STUB_REVIEW_LOOP_JSON='{"ended":"approved","iterations":[{},{}]}' \
    collectstub_collect "$collect_log4" "$collect_out4" \
    --branch fs-k8s-test-collect-loop-approved --review-loop 1 \
    --outbox-dir "$collect_dest4" "$proj_dir"; then
    if grep -q 'review loop: APPROVED after 2 iteration(s)' "$collect_out4"; then
        ok "collect --review-loop 1 reports an approved outcome"
    else
        no "collect --review-loop 1 reports an approved outcome" "$(cat "$collect_out4")"
    fi
else
    no "collect --review-loop 1 reports an approved outcome" "collect exited nonzero: $(cat "$collect_out4")"
fi

# 5. --review-loop 1 reports a cap outcome, with the last iteration's
# finding count.
collect_log5="$(newdir)/kubectl.log"; collect_out5="$(newdir)/out5.txt"; collect_dest5="$(newdir)/outbox-5"
tmpdirs+=("$(dirname "$collect_log5")" "$(dirname "$collect_dest5")")
if K8S_STUB_OUTBOX_RC=0 \
    K8S_STUB_REVIEW_LOOP_JSON='{"ended":"cap","iterations":[{"findings":5},{"findings":4}]}' \
    collectstub_collect "$collect_log5" "$collect_out5" \
    --branch fs-k8s-test-collect-loop-cap --review-loop 1 \
    --outbox-dir "$collect_dest5" "$proj_dir"; then
    if grep -q "review loop ended 'cap' after" "$collect_out5" \
        && grep -q '2 iteration(s)' "$collect_out5" \
        && grep -q '4 finding(s)' "$collect_out5"; then
        ok "collect --review-loop 1 reports a cap outcome"
    else
        no "collect --review-loop 1 reports a cap outcome" "$(cat "$collect_out5")"
    fi
else
    no "collect --review-loop 1 reports a cap outcome" "collect exited nonzero: $(cat "$collect_out5")"
fi

# 6. --review-loop omitted: no review-loop.json read at all -- a loop
# outcome that was never going to be printed must not be read "just in
# case" and turned into silence.
collect_log6="$(newdir)/kubectl.log"; collect_out6="$(newdir)/out6.txt"; collect_dest6="$(newdir)/outbox-6"
tmpdirs+=("$(dirname "$collect_log6")" "$(dirname "$collect_dest6")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log6" "$collect_out6" \
    --branch fs-k8s-test-collect-no-loop --outbox-dir "$collect_dest6" "$proj_dir"; then
    if ! grep -q 'review-loop.json' "$collect_log6"; then
        ok "collect without --review-loop reads no review-loop.json"
    else
        no "collect without --review-loop reads no review-loop.json" \
            "log=$(grep 'review-loop.json' "$collect_log6")"
    fi
else
    no "collect without --review-loop reads no review-loop.json" "collect exited nonzero: $(cat "$collect_out6")"
fi

# 7. --keep leaves the job and pod in place.
collect_log7="$(newdir)/kubectl.log"; collect_out7="$(newdir)/out7.txt"; collect_dest7="$(newdir)/outbox-7"
tmpdirs+=("$(dirname "$collect_log7")" "$(dirname "$collect_dest7")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log7" "$collect_out7" \
    --branch fs-k8s-test-collect-keep --outbox-dir "$collect_dest7" --keep "$proj_dir"; then
    if grep -q -- '--keep set; leaving job and pod' "$collect_out7" \
        && ! grep -q 'delete job' "$collect_log7"; then
        ok "collect --keep leaves the job in place"
    else
        no "collect --keep leaves the job in place" \
            "log=$(grep 'delete' "$collect_log7") out=$(cat "$collect_out7")"
    fi
else
    no "collect --keep leaves the job in place" "collect exited nonzero: $(cat "$collect_out7")"
fi

# 8. Without --keep the job is removed.
collect_log8="$(newdir)/kubectl.log"; collect_out8="$(newdir)/out8.txt"; collect_dest8="$(newdir)/outbox-8"
tmpdirs+=("$(dirname "$collect_log8")" "$(dirname "$collect_dest8")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log8" "$collect_out8" \
    --branch fs-k8s-test-collect-rm --outbox-dir "$collect_dest8" "$proj_dir"; then
    if grep -q 'delete job' "$collect_log8" \
        && ! grep -q -- '--keep set' "$collect_out8"; then
        ok "collect without --keep removes the job"
    else
        no "collect without --keep removes the job" \
            "log=$(grep 'delete' "$collect_log8") out=$(cat "$collect_out8")"
    fi
else
    no "collect without --keep removes the job" "collect exited nonzero: $(cat "$collect_out8")"
fi

# 9. The ordering invariant holds on the collect path too: the outbox tar
# read must appear in the kubectl log BEFORE the fetch's touch
# /work/.fetched.
collect_log9="$(newdir)/kubectl.log"; collect_out9="$(newdir)/out9.txt"; collect_dest9="$(newdir)/outbox-9"
tmpdirs+=("$(dirname "$collect_log9")" "$(dirname "$collect_dest9")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log9" "$collect_out9" \
    --branch fs-k8s-test-collect-ordering --outbox-dir "$collect_dest9" "$proj_dir"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    tar_ln="$(grep -n 'tar cf - -C /work/outbox' "$collect_log9" | head -n 1 | cut -d: -f1 || true)"
    fetched_ln="$(grep -n 'touch /work/.fetched' "$collect_log9" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$tar_ln" && -n "$fetched_ln" ]] && (( tar_ln < fetched_ln )); then
        ok "collect pulls the outbox back before the fetch touches /work/.fetched"
    else
        no "collect pulls the outbox back before the fetch touches /work/.fetched" \
            "tar_ln=$tar_ln fetched_ln=$fetched_ln out=$(cat "$collect_out9")"
    fi
else
    no "collect pulls the outbox back before the fetch touches /work/.fetched" "collect exited nonzero: $(cat "$collect_out9")"
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

# A large addendum must clear the emptiness check promptly. That check once
# used a whole-string glob substitution, which walks the message per
# multibyte character under a UTF-8 locale: 7.5s at 64KB, 33s at 128KB,
# 139s at 256KB, against ~6ms for the regex form. An addendum is exactly
# the input that gets large -- a thread, a diff, a log pasted in for the
# session to read. There is no cluster here, so this say fails at pod
# lookup either way; what is under test is that it FAILS rather than
# hangs. Exit 124 is timeout's own code, so it distinguishes the two.
say_big_dir="$(newdir)"; tmpdirs+=("$say_big_dir")
say_big="$say_big_dir/addendum.txt"
printf 'große Zeile mit Umlauten — %d\n' $(seq 6000) > "$say_big"
LC_ALL=C.UTF-8 timeout 20 env FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" say --branch fs-k8s-test-branch - < "$say_big" >/dev/null 2>&1
say_big_rc=$?
if (( say_big_rc != 124 )); then
    ok "say clears the emptiness check on a large multibyte message"
else
    no "say clears the emptiness check on a large multibyte message" \
        "timed out -- the check may have regressed to a glob substitution"
fi

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

# A regular member whose filename contains the words " link to " is not a
# link entry; only tar's leading type character identifies links here.
cf_phrase_src="$(newdir)"; tmpdirs+=("$cf_phrase_src")
printf 'ordinary\n' > "$cf_phrase_src/notes link to cache"
cf_phrase_parent="$(newdir)"; tmpdirs+=("$cf_phrase_parent")
cf_phrase_tar="$cf_phrase_parent/phrase.tar"
tar cf "$cf_phrase_tar" -C "$cf_phrase_src" .
cf_phrase_dest="$cf_phrase_parent/phrase_dest"
if "$context_extract_sh" "$cf_phrase_dest" 100000000 < "$cf_phrase_tar" \
        >/tmp/fs-k8s-ctx-phrase.err 2>&1; then
    ok "a regular filename containing ' link to ' extracts"
else
    no "a regular filename containing ' link to ' extracts" "$(cat /tmp/fs-k8s-ctx-phrase.err)"
fi
rm -f /tmp/fs-k8s-ctx-phrase.err

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
printf 'APPROVED\n\n## Report\nThe branch is sound.\n' > "$RL_TEST_VERDICT"
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

printf '\n-- malformed present report section --\n'
stub_dir_malformed="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_malformed")
cat > "$stub_dir_malformed/pi-malformed" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'APPROVED\n\nChecked: useful evidence.\n\n## Report\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir_malformed/pi-malformed"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_malformed/pi-malformed" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "malformed report: still ended=approved" "approved" "$(rl_json "$out" '.ended')"

printf '\n-- approved without a report section --\n'
stub_dir_no_report="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_no_report")
cat > "$stub_dir_no_report/pi-approve-no-report" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'APPROVED\n\nThe branch is sound.\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir_no_report/pi-approve-no-report"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_no_report/pi-approve-no-report" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "approved without report: ended=approved" "approved" "$(rl_json "$out" '.ended')"

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
    printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n\n## Report\nThe review found one issue.\n' > "\$RL_TEST_VERDICT"
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

printf '\n-- findings without a report section --\n'
stub_dir_no_report_findings="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_no_report_findings")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir_no_report_findings/pi-findings-no-report" <<STUB
#!/bin/sh
prompt=\$(cat)
n=0
[ -f "$stub_dir_no_report_findings/count" ] && n=\$(cat "$stub_dir_no_report_findings/count")
n=\$((n + 1))
echo \$n > "$stub_dir_no_report_findings/count"
if [ \$n -eq 1 ]; then
    printf 'FINDINGS\n\nfoo.c:12 first issue\n\nbar.c:34 second issue\n' > "\$RL_TEST_VERDICT"
    exit 0
fi
case "\$prompt" in
    *'foo.c:12 first issue'*'bar.c:34 second issue'*)
        git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=t \
            commit -q --allow-empty -m fix
        printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
        exit 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$stub_dir_no_report_findings/pi-findings-no-report"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_no_report_findings/pi-findings-no-report" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 1 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "findings without report: ended=cap" "cap" "$(rl_json "$out" '.ended')"
check "findings without report: counts two cited paragraphs" "2" \
    "$(rl_json "$out" '.iterations[0].findings')"
if grep -qF 'foo.c:12 first issue' "$work/fix-prompt-1.md" \
    && grep -qF 'bar.c:34 second issue' "$work/fix-prompt-1.md"; then
    ok "findings without report: fix prompt carries the verdict"
else
    no "findings without report: fix prompt carries the verdict" \
        "$(cat "$work/fix-prompt-1.md" 2>/dev/null)"
fi

printf '\n-- no-progress: the fix leg commits nothing --\n'
stub_dir3="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir3")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir3/pi-findings-only" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n\n## Report\nThe review found one issue.\n' > "$RL_TEST_VERDICT"
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

# A model-less pi --k8s run passes the launcher on ANY install: the
# endpoint question belongs to fork-sandbox-k8s.sh's install-mode-aware
# validation, and on a legacy K8S_PROXY_UPSTREAM install the refusal is
# its run verb's own -- after the launcher's project/handoff checks, so
# this case needs the real fixtures, not the placeholders the flag-
# refusal cases use.
refuses "--k8s with no --harness and no --model on a legacy install is refused by fork-sandbox-k8s.sh" \
    "run requires --model" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    "$k8s_flag_proj" "$k8s_flag_handoff"
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
# --services-trust-ref is carried through to the dispatched run. A checked-out
# service spec is disabled without the trust ref, so the rendered sidecar
# proves the launcher passed this flag rather than merely accepting it.
k8s_flag_svc_dir="$k8s_flag_proj/.agents/sandbox-services"
mkdir -p "$k8s_flag_svc_dir"
printf 'version: 1\nservices:\n  - name: launcher-svc\n    image: registry.example/x:1\n    port: 5432\n' > "$k8s_flag_svc_dir/services.yaml"
git -C "$k8s_flag_proj" add .agents/sandbox-services/services.yaml
git -C "$k8s_flag_proj" -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q -m services
git -C "$k8s_flag_proj" tag fs-k8s-launcher-services
k8s_flag_services_sha="$(git -C "$k8s_flag_proj" rev-parse HEAD)"
k8s_flag_services_out="$(newdir)/k8s-flag-services.yaml"; tmpdirs+=("$(dirname "$k8s_flag_services_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --checkout "$k8s_flag_services_sha" \
    --services-trust-ref fs-k8s-launcher-services \
    --branch fs-k8s-flag-test-services-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$k8s_flag_services_out" 2>/tmp/fs-k8s-flag-test-services.err; then
    ok "--k8s --services-trust-ref --dry-run reaches the dispatched command"
else
    no "--k8s --services-trust-ref --dry-run reaches the dispatched command" \
        "$(cat /tmp/fs-k8s-flag-test-services.err)"
fi
check "--k8s --services-trust-ref forwards the flag and enables the checked-out spec" \
    2 "$(awk '/^      initContainers:/{f=1} f&&/^      containers:/{f=0} f' "$k8s_flag_services_out" | grep -c '^        - name:')"
rm -f /tmp/fs-k8s-flag-test-services.err
refuses "--k8s --keep-session is refused" \
    "--keep-session is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --keep-session \
    unused-project unused-handoff

# --checkout is carried through, not refused -- its own section below
# drives both verbs, stubbed, and proves the flag reaches the dispatcher's
# render.
refuses "--k8s --pi-args is refused (the dispatcher does not forward it)" \
    "--pi-args is not supported with --k8s" \
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
# --endpoint is carried through, not refused -- on a K8S_PROXY_ENDPOINTS
# install the forwarded flag must reach the render: the Job's PROXY_BASE_URL
# lands at the named endpoint's /e/<name>/v1 instead of the legacy /api/v1
# path. Reuses endpoints_config_dir's primary/secondary registry above.
k8s_flag_ep_out="$(newdir)/k8s-flag-ep.yaml"; tmpdirs+=("$(dirname "$k8s_flag_ep_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --endpoint secondary \
    --branch fs-k8s-flag-test-ep-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_ep_out" 2>/tmp/fs-k8s-flag-test-ep.err; then
    ok "--k8s --endpoint --dry-run exits 0"
else
    no "--k8s --endpoint --dry-run exits 0" "$(cat /tmp/fs-k8s-flag-test-ep.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$k8s_flag_ep_out" \
    && ! grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$k8s_flag_ep_out"; then
    ok "--k8s --endpoint --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --endpoint --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$k8s_flag_ep_out")"
fi
rm -f /tmp/fs-k8s-flag-test-ep.err
# --endpoint is also the launcher-side way off the pi model requirement:
# on a K8S_PROXY_ENDPOINTS install the pod discovers its model, so a
# model-less --k8s --endpoint --dry-run must reach the render with the
# discovery gate on and an empty MODEL env, mirroring the submit-level
# no-model assertions above.
k8s_flag_ep_nm_out="$(newdir)/k8s-flag-ep-nomodel.yaml"; tmpdirs+=("$(dirname "$k8s_flag_ep_nm_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --endpoint secondary \
    --branch fs-k8s-flag-test-ep-nomodel-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_ep_nm_out" 2>/tmp/fs-k8s-flag-test-ep-nomodel.err; then
    ok "--k8s --endpoint --dry-run without --model exits 0"
else
    no "--k8s --endpoint --dry-run without --model exits 0" \
        "$(cat /tmp/fs-k8s-flag-test-ep-nomodel.err)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out" | grep -qF 'value: "1"'; then
    ok "the no-model --k8s --endpoint render carries MODEL_DISCOVERY=1"
else
    no "the no-model --k8s --endpoint render carries MODEL_DISCOVERY=1" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out")"
fi
model_env="$(grep -A1 'name: MODEL$' "$k8s_flag_ep_nm_out" | tail -n1)"
check "the no-model --k8s --endpoint render carries an empty MODEL env" \
    '              value: ""' "$model_env"
rm -f /tmp/fs-k8s-flag-test-ep-nomodel.err "$k8s_flag_ep_nm_out"
# And the launcher no longer pre-empts the endpoint rule at all: with no
# --model and no --endpoint, K8S_DEFAULT_ENDPOINT in k8s.env alone is
# enough for a pi --k8s run to pass the launcher's own validation and
# reach the render, wired to the default's endpoint. Reuses
# default_ep_config_dir's primary/secondary registry + default above.
k8s_flag_def_out="$(newdir)/k8s-flag-def.yaml"; tmpdirs+=("$(dirname "$k8s_flag_def_out")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$fs_sh" --k8s --dry-run \
    --branch fs-k8s-flag-test-def-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_def_out" 2>/tmp/fs-k8s-flag-test-def.err; then
    ok "--k8s --dry-run with neither --model nor --endpoint passes the launcher when k8s.env names a default"
else
    no "--k8s --dry-run with neither --model nor --endpoint passes the launcher when k8s.env names a default" \
        "$(cat /tmp/fs-k8s-flag-test-def.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$k8s_flag_def_out" \
    && ! grep -qF '/e/primary/v1' "$k8s_flag_def_out"; then
    ok "the no-model no-endpoint --k8s render is wired to K8S_DEFAULT_ENDPOINT's endpoint"
else
    no "the no-model no-endpoint --k8s render is wired to K8S_DEFAULT_ENDPOINT's endpoint" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$k8s_flag_def_out")"
fi
rm -f /tmp/fs-k8s-flag-test-def.err
# --harness claude keeps the model requirement even with --endpoint --
# the pod's discovery lists the pi endpoint's model ids, never a Claude
# Code model name -- and the launcher refuses it before any render.
refuses "--k8s --harness claude --endpoint without --model is still refused" \
    "--k8s --harness claude needs --model" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --endpoint secondary \
    "$k8s_flag_proj" "$k8s_flag_handoff"
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
refuses "--endpoint without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint llm unused-project unused-handoff
refuses "--endpoint with a bad name shape is refused" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint LLM-1 unused-project unused-handoff
# Names parse_proxy_endpoints would itself refuse (underscore, trailing
# hyphen) must be refused at the same shape, not only at submit as
# 'not registered'.
refuses "--endpoint with an underscore is refused as a bad shape" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint my_ep unused-project unused-handoff
refuses "--endpoint with a trailing hyphen is refused as a bad shape" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint a- unused-project unused-handoff

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

printf '\n== --checkout: a named ref as the branch start (no cluster) ==\n'
# The push's source side was hardcoded HEAD, so a cluster run could only
# start from the origin repo's current HEAD. --checkout REF must instead
# resolve REF in the origin repo BEFORE anything is created, and push the
# resolved sha -- the one the push line reports and the review loop
# measures against. Driven with a stubbed kubectl (logs every invocation)
# and a stubbed git (records the push's own arguments, otherwise the real
# git): that pair is what makes "nothing was created" assertable against
# the stub's own log rather than by eyeballing the output.
co_proj="$(mktemp -d "$HOME/src/fs-k8s-checkout-test.XXXXXX")"; tmpdirs+=("$co_proj")
# Built with the operator's global and system git config neutralised. An
# operator who sets commit.gpgsign or tag.gpgSign (both are common, and both
# are set on at least one machine this suite runs on) otherwise gets a
# fixture that fails to build: `git tag <name>` with signing on is an
# ANNOTATED tag, which dies "fatal: no tag message?" without -m, and the &&
# chain then silently skips the second commit. The identity below is set
# locally, so dropping the global config costs the fixture nothing.
(
    # shellcheck disable=SC2030,SC2031  # scoped to this subshell only
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    cd "$co_proj" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'one\n' > file.txt \
        && git add file.txt \
        && git commit -q -m one \
        && git tag fs-k8s-checkout-v1 \
        && printf 'two\n' >> file.txt \
        && git add file.txt \
        && git commit -q -m two
) >/dev/null 2>&1
co_tag="fs-k8s-checkout-v1"
# --verify --quiet, so an unbuilt fixture yields an EMPTY sha and the check
# below fails loudly. A bare `git rev-parse <bad-ref>` echoes the ref back on
# stdout, which made this assertion pass against a tag that did not exist.
co_tag_sha="$(git -C "$co_proj" rev-parse --verify --quiet "${co_tag}^{commit}")"
co_head_sha="$(git -C "$co_proj" rev-parse --verify --quiet HEAD)"
if [[ -n "$co_tag_sha" && "$co_tag_sha" != "$co_head_sha" ]]; then
    ok "the checkout fixture's tag is a commit distinct from HEAD"
else
    no "the checkout fixture's tag is a commit distinct from HEAD" \
        "tag=$co_tag_sha head=$co_head_sha"
fi
co_stub="$(newdir)"; tmpdirs+=("$co_stub")
cat > "$co_stub/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) printf '%s\n' "$*" >> "$GIT_STUB_LOG"; exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$co_stub/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" apply -f -"*) cat >/dev/null; exit 0 ;;
    *" wait "*) exit 0 ;;
    *" get "*) printf 'stub-pod\n' ;;
esac
exit 0
STUB
chmod +x "$co_stub/git" "$co_stub/kubectl"

# 1. A ref that resolves renders cleanly under --dry-run, which touches
# nothing beyond the validation this flag lives in.
co_out1="$(newdir)/co-1.yaml"; tmpdirs+=("$(dirname "$co_out1")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-dryrun --model moonshotai/kimi-k3 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_out1" 2>&1; then
    ok "submit --dry-run --checkout with a resolvable ref exits 0"
else
    no "submit --dry-run --checkout with a resolvable ref exits 0" "$(cat "$co_out1")"
fi

# 2. The important one: a ref that does NOT resolve must fail, name the
# ref, and create nothing -- asserted against the stub kubectl's own log
# (it records every invocation) and the stub git's push log, on the
# NON-dry-run path where a Job, Secret and proxy Pod would otherwise go
# down.
co_dir2="$(newdir)"; tmpdirs+=("$co_dir2")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir2/kubectl.log" GIT_STUB_LOG="$co_dir2/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-badref --model moonshotai/kimi-k3 \
    --checkout fs-k8s-checkout-nosuch \
    "$co_proj" "$handoff_file" > "$co_dir2/out.txt" 2>&1
co_rc2=$?
if (( co_rc2 != 0 )) \
    && [[ "$(cat "$co_dir2/out.txt")" == *"fs-k8s-checkout-nosuch"* && "$(cat "$co_dir2/out.txt")" == *"does not name a commit"* ]] \
    && [[ ! -s "$co_dir2/kubectl.log" && ! -s "$co_dir2/git.log" ]]; then
    ok "submit --checkout with an unresolvable ref fails with the ref named and creates nothing (stub logs empty)"
else
    no "submit --checkout with an unresolvable ref fails with the ref named and creates nothing (stub logs empty)" \
        "rc=$co_rc2 kubectl=$(cat "$co_dir2/kubectl.log") git=$(cat "$co_dir2/git.log") out=$(cat "$co_dir2/out.txt")"
fi
# The same refusal holds under --dry-run: the check is validation, and
# --dry-run exists to exercise exactly those.
refuses "submit --dry-run --checkout with an unresolvable ref is refused before the render" \
    "does not name a commit" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-dryrun-bad --model moonshotai/kimi-k3 \
    --checkout fs-k8s-checkout-nosuch \
    "$co_proj" "$handoff_file"

# 3. A value with a single quote is refused by fs_reject_unsafe_chars, the
# same way the suite already tests other rejected inputs -- on the
# non-dry-run path, with the stub's log still empty: the value is
# interpolated into a git command line, so it is treated as hostile.
co_dir3="$(newdir)"; tmpdirs+=("$co_dir3")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir3/kubectl.log" GIT_STUB_LOG="$co_dir3/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-quote --model moonshotai/kimi-k3 \
    --checkout "no'such-ref" \
    "$co_proj" "$handoff_file" > "$co_dir3/out.txt" 2>&1
co_rc3=$?
if (( co_rc3 != 0 )) && [[ "$(cat "$co_dir3/out.txt")" == *"single quote"* ]] \
    && [[ ! -s "$co_dir3/kubectl.log" && ! -s "$co_dir3/git.log" ]]; then
    ok "submit --checkout with a single quote is refused before any kubectl call"
else
    no "submit --checkout with a single quote is refused before any kubectl call" \
        "rc=$co_rc3 kubectl=$(cat "$co_dir3/kubectl.log") out=$(cat "$co_dir3/out.txt")"
fi

# 4. The push refspec carries the RESOLVED SHA of the named ref, not HEAD
# or the ref name -- read from the stub git's record of the push's own
# arguments -- and the push line reports the same sha.
co_dir4="$(newdir)"; tmpdirs+=("$co_dir4")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir4/kubectl.log" GIT_STUB_LOG="$co_dir4/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-sha --model moonshotai/kimi-k3 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_dir4/out.txt" 2>&1
co_rc4=$?
if (( co_rc4 == 0 )) \
    && grep -qF -- "$co_tag_sha:refs/heads/fs-k8s-test-co-sha" "$co_dir4/git.log" \
    && ! grep -qF 'HEAD:refs/heads/' "$co_dir4/git.log" \
    && [[ "$(cat "$co_dir4/out.txt")" == *"branch starts at $co_tag_sha"* ]]; then
    ok "the push refspec carries the resolved sha of the named ref, not HEAD, and the push line reports it"
else
    no "the push refspec carries the resolved sha of the named ref, not HEAD, and the push line reports it" \
        "rc=$co_rc4 git=$(cat "$co_dir4/git.log") out=$(cat "$co_dir4/out.txt")"
fi

# 5. No --checkout: the refspec and the review base are exactly what they
# are today -- HEAD, resolved the same way.
co_dir5="$(newdir)"; tmpdirs+=("$co_dir5")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir5/kubectl.log" GIT_STUB_LOG="$co_dir5/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-head --model moonshotai/kimi-k3 \
    "$co_proj" "$handoff_file" > "$co_dir5/out.txt" 2>&1
co_rc5=$?
if (( co_rc5 == 0 )) \
    && grep -qF -- "HEAD:refs/heads/fs-k8s-test-co-head" "$co_dir5/git.log" \
    && [[ "$(cat "$co_dir5/out.txt")" == *"branch starts at HEAD"* ]]; then
    ok "no --checkout: the push refspec and the push line are HEAD, exactly as before"
else
    no "no --checkout: the push refspec and the push line are HEAD, exactly as before" \
        "rc=$co_rc5 git=$(cat "$co_dir5/git.log") out=$(cat "$co_dir5/out.txt")"
fi
co_out6="$(newdir)/co-6.yaml"; tmpdirs+=("$(dirname "$co_out6")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-rl-checkout --model moonshotai/kimi-k3 \
    --review-loop 1 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_out6" 2>/dev/null; then
    ok "submit --dry-run --review-loop 1 --checkout exits 0"
else
    no "submit --dry-run --review-loop 1 --checkout exits 0" "$(cat "$co_out6")"
fi
if grep -A1 'name: BASE_SHA' "$co_out6" | grep -qF "value: \"$co_tag_sha\""; then
    ok "under --checkout, the review base is the same revision the push sends"
else
    no "under --checkout, the review base is the same revision the push sends" \
        "$(grep -A1 'name: BASE_SHA' "$co_out6")"
fi
co_out7="$(newdir)/co-7.yaml"; tmpdirs+=("$(dirname "$co_out7")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-rl-head --model moonshotai/kimi-k3 \
    --review-loop 1 \
    "$co_proj" "$handoff_file" > "$co_out7" 2>/dev/null; then
    ok "submit --dry-run --review-loop 1 (no --checkout) exits 0"
else
    no "submit --dry-run --review-loop 1 (no --checkout) exits 0" "$(cat "$co_out7")"
fi
if grep -A1 'name: BASE_SHA' "$co_out7" | grep -qF "value: \"$co_head_sha\""; then
    ok "no --checkout: the review base is HEAD's sha, exactly as before"
else
    no "no --checkout: the review base is HEAD's sha, exactly as before" \
        "$(grep -A1 'name: BASE_SHA' "$co_out7")"
fi

# 6. The dispatcher: fork-sandbox.sh --k8s --checkout no longer errors, and
# the flag actually reaches fork-sandbox-k8s.sh run -- proved the same way
# this file proves every other carried flag, by diffing the dispatcher's
# render against a direct run --dry-run with the same arguments. --review-loop
# rides along so the pushed revision is visible in the render (BASE_SHA):
# a dispatcher that dropped --checkout would render HEAD's sha, and the tag
# is a different commit, so the diff would fail.
co_out8="$(newdir)/co-8.yaml"; tmpdirs+=("$(dirname "$co_out8")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 1 --checkout "$co_tag" \
    --branch fs-k8s-test-co-dispatch \
    "$co_proj" "$k8s_flag_handoff" \
    > "$co_out8" 2>/tmp/fs-k8s-co-dispatch.err; then
    ok "fork-sandbox.sh --k8s --checkout --dry-run is no longer refused"
else
    no "fork-sandbox.sh --k8s --checkout --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-co-dispatch.err)"
fi
co_out9="$(newdir)/co-9.yaml"; tmpdirs+=("$(dirname "$co_out9")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-co-dispatch --model moonshotai/kimi-k3 \
    --review-loop 1 --checkout "$co_tag" \
    "$co_proj" "$k8s_flag_handoff" \
    > "$co_out9" 2>/dev/null; then
    ok "direct run --dry-run --checkout (matching args) exits 0"
else
    no "direct run --dry-run --checkout (matching args) exits 0" "$(cat "$co_out9")"
fi
if diff -q "$co_out8" "$co_out9" >/dev/null 2>&1 \
    && grep -A1 'name: BASE_SHA' "$co_out8" | grep -qF "value: \"$co_tag_sha\""; then
    ok "--k8s --checkout forwards the flag (render matches the direct run --checkout call, base is the checkout sha)"
else
    no "--k8s --checkout forwards the flag (render matches the direct run --checkout call, base is the checkout sha)" \
        "$(diff "$co_out8" "$co_out9" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-co-dispatch.err

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

# A generated sandbox env file is ignored through the clone-local exclude
# file, and the exact entry is guarded so repeated setup does not duplicate it.
if grep -qF '>> "$clone_dir/.git/info/exclude"' "$entrypoint_sh" \
    && grep -qF "grep -qxF '.env.sandbox' \"\$clone_dir/.git/info/exclude\"" "$entrypoint_sh"; then
    ok "entrypoint excludes .env.sandbox from end-of-leg commits without duplicate entries"
else
    no "entrypoint excludes .env.sandbox from end-of-leg commits without duplicate entries" \
        "missing clone-local info/exclude guard in $entrypoint_sh"
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
if grep -qF '| unique | map(' "$entrypoint_sh"; then
    ok "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique"
else
    no "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique" \
        "missing a '| unique |' models array in $entrypoint_sh"
fi

printf '\n== entrypoint: pod-side model discovery (curl stubbed) ==\n'
# discover_model_facts, the real function extracted from the entrypoint's
# own source and run in a subshell with a stubbed curl on PATH -- the
# same PATH-stubbing the suite already uses for kubectl. The subshell is
# what makes the function's own `exit 1` safe (it kills only the
# subshell), and on success the subshell prints the values the function
# established for the rest of the script to consume.
discover_fn="$(sed -n '/^discover_model_facts() {/,/^}/p' "$entrypoint_sh")"
discover_fn_file="$(newdir)/discover.sh"; tmpdirs+=("$(dirname "$discover_fn_file")")
if [[ -n "$discover_fn" ]]; then
    printf '%s\n' "$discover_fn" > "$discover_fn_file"
    ok "discover_model_facts is a standalone function in the entrypoint"
else
    no "discover_model_facts is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi

# Runs the extracted function in a subshell: $1 is the stub curl's stdout
# (or "FAIL" for a connection-refused stub), $2 the MODEL value (or "")
# it is handed, $3 the REVIEW_MODEL value (or ""), $4 the HARNESS value
# (default pi). Captures combined output and the subshell's exit status
# in $discover_out / $discover_rc.
discover_run() {
    local stub_dir
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    if [[ "$1" == FAIL ]]; then
        printf '%s\n' '#!/usr/bin/env bash' \
            'echo "curl: (7) Failed to connect to 10.0.0.5 port 8001: Connection refused" >&2' \
            'exit 7' > "$stub_dir/curl"
    else
        printf '%s\n' '#!/usr/bin/env bash' 'cat <<JSON' "$1" 'JSON' > "$stub_dir/curl"
    fi
    chmod +x "$stub_dir/curl"
    discover_out="$(PATH="$stub_dir:$PATH" MODEL="$2" REVIEW_MODEL="${3-}" HARNESS="${4:-pi}" \
        PROXY_BASE_URL="http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1" \
        bash -c 'source "$1"; discover_model_facts; \
            printf "MODEL=%s CTX=%s MAX_TOKENS=%s REVIEW_CTX=%s REVIEW_MAX_TOKENS=%s\n" \
                "$MODEL" "$CTX" "$MAX_TOKENS" "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"' \
        _ "$discover_fn_file" 2>&1)"
    discover_rc=$?
}

# A single-model response resolves MODEL and takes the context window
# from max_model_len; MAX_TOKENS is agent-sandboxed's rule -- a 32768
# floor, capped at a quarter of the window (24576/4 = 6144).
discover_run '{"data":[{"id":"qwen3-8b","max_model_len":24576}]}' ""
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=qwen3-8b CTX=24576 MAX_TOKENS=6144"* ]]; then
    ok "discovery: single-model response resolves MODEL and CTX from max_model_len"
else
    no "discovery: single-model response resolves MODEL and CTX from max_model_len" \
        "rc=$discover_rc: $discover_out"
fi
if [[ "$discover_out" == *"serves exactly one model"* ]]; then
    ok "discovery: the resolved single model is announced on stderr"
else
    no "discovery: the resolved single model is announced on stderr" "$discover_out"
fi

# A large window keeps the 32768 MAX_TOKENS floor (131072/4 = 32768,
# not below the floor, so it stays).
discover_run '{"data":[{"id":"big","max_model_len":131072}]}' ""
if [[ "$discover_out" == *"CTX=131072 MAX_TOKENS=32768"* ]]; then
    ok "discovery: MAX_TOKENS keeps the 32768 floor when the window is large"
else
    no "discovery: MAX_TOKENS keeps the 32768 floor when the window is large" \
        "rc=$discover_rc: $discover_out"
fi

# A missing max_model_len warns and falls back to the low 32768 guess.
discover_run '{"data":[{"id":"solo"}]}' ""
if (( discover_rc == 0 )) && [[ "$discover_out" == *"assumes 32768"* \
        && "$discover_out" == *"MODEL=solo CTX=32768 MAX_TOKENS=8192"* ]]; then
    ok "discovery: missing max_model_len warns and falls back to 32768"
else
    no "discovery: missing max_model_len warns and falls back to 32768" \
        "rc=$discover_rc: $discover_out"
fi

# Several models, no MODEL: an error naming the situation and listing
# what was found.
discover_run '{"data":[{"id":"a-model"},{"id":"b-model"}]}' ""
if (( discover_rc != 0 )) && [[ "$discover_out" == *"more than one model"* \
        && "$discover_out" == *a-model* && "$discover_out" == *b-model* ]]; then
    ok "discovery: multi-model response without MODEL errors listing the ids"
else
    no "discovery: multi-model response without MODEL errors listing the ids" \
        "rc=$discover_rc: $discover_out"
fi

# ...but a MODEL that IS in the listing goes through, unchanged.
discover_run '{"data":[{"id":"a-model","max_model_len":8192},{"id":"b-model"}]}' "a-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=a-model CTX=8192 MAX_TOKENS=2048"* ]]; then
    ok "discovery: a MODEL present in the listing passes through unchanged"
else
    no "discovery: a MODEL present in the listing passes through unchanged" \
        "rc=$discover_rc: $discover_out"
fi

# A MODEL absent from the listing warns and continues -- the listing may
# be stale, and refusing would strand a legitimate run.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "other-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"does not list a model called 'other-model'"* \
        && "$discover_out" == *"MODEL=other-model CTX=32768"* ]]; then
    ok "discovery: a MODEL absent from the listing warns and continues"
else
    no "discovery: a MODEL absent from the listing warns and continues" \
        "rc=$discover_rc: $discover_out"
fi

# The --harness claude case: MODEL is a Claude Code model name the pi
# endpoint's listing never contains and no pi leg of this run uses, so
# it is neither checked against the listing nor looked up per-model --
# no warning about it, and the summary names the review model. The
# review loop's window must come from REVIEW_MODEL's own entry, not
# inherit MODEL's.
discover_run '{"data":[{"id":"qwen3-8b","max_model_len":24576}]}' "claude-opus-5" "qwen3-8b" claude
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=claude-opus-5 CTX=32768 MAX_TOKENS=8192"* \
        && "$discover_out" == *"REVIEW_CTX=24576 REVIEW_MAX_TOKENS=6144"* \
        && "$discover_out" == *"review model qwen3-8b at"* \
        && "$discover_out" != *"does not list"* \
        && "$discover_out" != *"does not report a context length"* ]]; then
    ok "discovery: on a claude run the Claude Code name is not probed and the review model's window stands"
else
    no "discovery: on a claude run the Claude Code name is not probed and the review model's window stands" \
        "rc=$discover_rc: $discover_out"
fi
# ...and a REVIEW_MODEL absent from the listing gets the low-guess
# fallback for itself, with the warning naming IT.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model" "other-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=a-model CTX=8192 MAX_TOKENS=2048"* \
        && "$discover_out" == *"'other-model', so the run using it assumes 32768"* \
        && "$discover_out" == *"REVIEW_CTX=32768 REVIEW_MAX_TOKENS=8192"* ]]; then
    ok "discovery: a REVIEW_MODEL absent from the listing warns and falls back to 32768"
else
    no "discovery: a REVIEW_MODEL absent from the listing warns and falls back to 32768" \
        "rc=$discover_rc: $discover_out"
fi
# ...and with no separate review model, the review loop falls back to
# MODEL and shares its window.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"REVIEW_CTX=8192 REVIEW_MAX_TOKENS=2048"* ]]; then
    ok "discovery: no REVIEW_MODEL shares MODEL's window with the review loop"
else
    no "discovery: no REVIEW_MODEL shares MODEL's window with the review loop" \
        "rc=$discover_rc: $discover_out"
fi

# A curl failure -- the ordinary connection-refused state of a
# workstation-class endpoint -- errors naming the URL, and reads like
# operations rather than a stack trace.
discover_run FAIL ""
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"/e/primary/v1/models"* \
        && "$discover_out" == *"Connection refused"* \
        && "$discover_out" == *"expected, ordinary state"* ]]; then
    ok "discovery: a curl failure errors naming the URL, ops-flavoured"
else
    no "discovery: a curl failure errors naming the URL, ops-flavoured" \
        "rc=$discover_rc: $discover_out"
fi

# The ordering the design doc's health-check requirement records: discovery
# runs BEFORE the repository-receive wait, so a dead endpoint fails in
# seconds instead of after the whole submit dance. It must ALSO run
# AFTER the bare repository's git init: the agent container has no
# readinessProbe, so the host's push can land the moment the container
# starts, and a discovery ahead of the git init would race that push
# against a nonexistent /work/repo.git and fail a healthy run.
# shellcheck disable=SC2016  # needle is literal entrypoint text
discover_call_line="$(grep -nE '^[[:space:]]*discover_model_facts[[:space:]]*$' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
sentinel_wait_line="$(grep -nF 'waiting for $sentinel' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
git_init_line="$(grep -nF 'git init --quiet --bare "$repo_bare"' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
if [[ -n "$git_init_line" && -n "$discover_call_line" && -n "$sentinel_wait_line" \
        && "$git_init_line" -lt "$discover_call_line" \
        && "$discover_call_line" -lt "$sentinel_wait_line" ]]; then
    ok "discovery runs after git init and before the repository-receive wait"
else
    no "discovery runs after git init and before the repository-receive wait" \
        "git init line '$git_init_line', discovery call line '$discover_call_line', sentinel wait line '$sentinel_wait_line'"
fi
if grep -qF 'if [[ -n "$MODEL_DISCOVERY" ]]; then' "$entrypoint_sh" \
    && grep -qF 'CTX=131072' "$entrypoint_sh" \
    && grep -qF 'REVIEW_MAX_TOKENS=32768' "$entrypoint_sh"; then
    ok "discovery is gated on MODEL_DISCOVERY, with the legacy constants kept in the else branch"
else
    no "discovery is gated on MODEL_DISCOVERY, with the legacy constants kept in the else branch" \
        "missing the MODEL_DISCOVERY gate or the legacy 131072/32768 constants in $entrypoint_sh"
fi
if grep -qF ': "${MODEL:?MODEL must be set to a model id}"' "$entrypoint_sh"; then
    no "the entrypoint no longer hard-requires MODEL at startup" \
        "the old MODEL:? required-var check is still there"
else
    ok "the entrypoint no longer hard-requires MODEL at startup"
fi
if grep -qF 'contextWindow: 131072' "$entrypoint_sh" \
    || grep -qF 'maxTokens: 32768' "$entrypoint_sh"; then
    no "synthesize_pi_config carries no hardcoded contextWindow/maxTokens" \
        "a hardcoded 131072/32768 is still in the models.json render in $entrypoint_sh"
else
    ok "synthesize_pi_config carries no hardcoded contextWindow/maxTokens"
fi
# A repository push that fails because the pod's container already died
# (the entrypoint's fail-fast model discovery, on an K8S_PROXY_ENDPOINTS
# install with a dead endpoint) must surface the container's log -- git's
# own "connection refused" tells the operator nothing, and nothing else
# in this script reads the pod log.
if grep -qF -- '"$push_src:refs/heads/$branch") || push_rc=$?' "$k8s_sh" \
    && grep -A4 -F 'if (( push_rc != 0 )); then' "$k8s_sh" \
        | grep -qF 'kubectl logs "$pod_name"'; then
    ok "a failed repository push surfaces the pod's container log"
else
    no "a failed repository push surfaces the pod's container log" \
        "the push failure branch in $k8s_sh does not dump the container log"
fi
# Per-model windows, EXECUTED rather than grepped: the real
# synthesize_pi_config, extracted from the entrypoint's own source the
# same way discover_model_facts above is, run in a subshell against a
# throwaway HOME with two ids and DISTINCT coding/review windows. A
# models.json that is never written, a jq program that does not parse,
# or one id's window stamped onto the other all fail this; grepping the
# function's own source text would pass all three.
synth_fn="$(sed -n '/^synthesize_pi_config() {/,/^}/p' "$entrypoint_sh")"
synth_fn_file="$(newdir)/synthesize.sh"; tmpdirs+=("$(dirname "$synth_fn_file")")
if [[ -n "$synth_fn" ]]; then
    printf '%s\n' "$synth_fn" > "$synth_fn_file"
    ok "synthesize_pi_config is a standalone function in the entrypoint"
else
    no "synthesize_pi_config is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi

# Runs the extracted function in a subshell (so its `exit 1` kills only
# the subshell); the six arguments are passed through as-is. The
# rendered models.json is left in a throwaway HOME, captured in
# $synth_home, and $synth_out / $synth_rc hold the combined output and
# the subshell's exit status.
synth_run() {
    local home mounts
    home="$(newdir)"; tmpdirs+=("$home")
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    synth_home="$home"
    synth_out="$(HOME="$home" mounts_dir="$mounts" \
        PROXY_BASE_URL="http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1" \
        bash -c 'source "$1"; synthesize_pi_config \
            "${2-}" "${3-}" "${4-}" "${5-}" "${6-}" "${7-}"' \
        _ "$synth_fn_file" "$@" 2>&1)"
    synth_rc=$?
}

# Two ids with distinct windows: each entry in models.json must carry
# the window for ITS OWN id, never one id's value stamped onto the
# other.
synth_run coder reviewer 24576 6144 98304 24576
synth_models="$(jq -r '.providers.proxy.models[] | "\(.id)=\(.contextWindow)/\(.maxTokens)"' \
    "$synth_home/.pi/agent/models.json" 2>/dev/null | sort)"
if (( synth_rc == 0 )) \
    && [[ "$synth_models" == *"coder=24576/6144"* && "$synth_models" == *"reviewer=98304/24576"* ]]; then
    ok "synthesize_pi_config renders each models.json id from its own window (executed)"
else
    no "synthesize_pi_config renders each models.json id from its own window (executed)" \
        "rc=$synth_rc: $synth_out; models.json: $synth_models"
fi
# ...and with no second model, exactly one entry, from the first pair.
synth_run coder "" 8192 2048 "" ""
synth_models="$(jq -r '.providers.proxy.models[] | "\(.id)=\(.contextWindow)/\(.maxTokens)"' \
    "$synth_home/.pi/agent/models.json" 2>/dev/null | sort)"
if (( synth_rc == 0 )) && [[ "$synth_models" == "coder=8192/2048" ]]; then
    ok "synthesize_pi_config with no second model renders exactly one entry (executed)"
else
    no "synthesize_pi_config with no second model renders exactly one entry (executed)" \
        "rc=$synth_rc: $synth_out; models.json: $synth_models"
fi
if grep -A1 -qF -- 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh" \
    && grep -A1 -F 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh" \
        | grep -qF -- '"$CTX" "$MAX_TOKENS" "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"'; then
    ok "the pi coding leg's synthesize_pi_config passes both models' discovered windows"
else
    no "the pi coding leg's synthesize_pi_config passes both models' discovered windows" \
        "missing a per-model CTX/MAX_TOKENS wiring in $entrypoint_sh"
fi
if grep -A1 -F 'synthesize_pi_config "$review_loop_model"' "$entrypoint_sh" \
    | grep -qF -- '"$REVIEW_CTX" "$REVIEW_MAX_TOKENS"'; then
    ok "a claude coding leg's synthesize_pi_config uses the review model's own window"
else
    no "a claude coding leg's synthesize_pi_config uses the review model's own window" \
        "missing the REVIEW_CTX/REVIEW_MAX_TOKENS wiring in the claude branch of $entrypoint_sh"
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

printf '\n== fork-sandbox-k8s.sh: the GNU tools go through their resolved names ==\n'
# Guards the fork-sandbox-lib.sh name resolution: on macOS the bare names
# are BSD tools that reject the GNU flags (stat -c) or don't exist at all
# (timeout), so every call site must use the $FS_* names. What counts as a
# match, per pattern:
#   - "stat -c" and "realpath -m/-s/-e": any literal occurrence, comment
#     lines included -- the shimmed form ("$FS_STAT" -c) cannot spell the
#     raw form, and a comment describing the raw form would steer the next
#     edit back to it, so it is caught too. The grep -vF is a belt: it
#     would exclude a line literally containing the shimmed form.
#   - "timeout": command position only -- start of line (indented or not)
#     or immediately after ;, &, | or $(. --timeout, --request-timeout,
#     and the word in echo prose ("every 10s, timeout ...") all begin or
#     continue from other characters and do not match.
#   - "readlink -f": counted over the whole file, expected to be EXACTLY
#     one -- the script_dir bootstrap, which runs before the library is
#     sourced and structurally cannot use $FS_REALPATH. BSD readlink
#     gained -f in macOS 12.3, so every supported macOS has it. Asserting
#     1 rather than 0 documents the exception: if the bootstrap moves or
#     a second raw readlink appears, this test says so instead of passing
#     silently.
# shellcheck disable=SC2016  # the shimmed form is meant literally, not expanded
raw_stat_hits="$(grep -n 'stat -c' "$k8s_sh" | grep -vF -- '"$FS_STAT" ' || true)"
if [[ -z "$raw_stat_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no raw 'stat -c' outside the $FS_STAT shim"
else
    no "fork-sandbox-k8s.sh: no raw 'stat -c' outside the $FS_STAT shim" "$raw_stat_hits"
fi
# shellcheck disable=SC2016  # the shimmed form is meant literally, not expanded
raw_realpath_hits="$(grep -nE 'realpath -[mse]' "$k8s_sh" | grep -vF -- '"$FS_REALPATH" ' || true)"
if [[ -z "$raw_realpath_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no raw 'realpath -m/-s/-e' outside the $FS_REALPATH shim"
else
    no "fork-sandbox-k8s.sh: no raw 'realpath -m/-s/-e' outside the $FS_REALPATH shim" "$raw_realpath_hits"
fi
# shellcheck disable=SC2016  # the pattern is meant literally, not expanded
raw_timeout_hits="$(grep -nE '(^|[;&|(])[[:space:]]*timeout[[:space:]]' "$k8s_sh" || true)"
if [[ -z "$raw_timeout_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no bare 'timeout' command outside the $FS_TIMEOUT shim"
else
    no "fork-sandbox-k8s.sh: no bare 'timeout' command outside the $FS_TIMEOUT shim" "$raw_timeout_hits"
fi
readlink_count="$(grep -c 'readlink -f' "$k8s_sh" || true)"
check "fork-sandbox-k8s.sh: exactly one 'readlink -f' (the pre-library bootstrap)" \
    1 "$readlink_count"

printf '\n== per-run services (cluster path) ==\n'
# .agents/sandbox-services/services.yaml is declarative data the harness
# synthesizes sidecars from -- never a hook the repo could execute -- see
# docs/sandbox-services.md's cluster section. Every fixture below commits a
# spec at HEAD and calls submit --dry-run directly (no --checkout), which
# is the "trusted, operator's own HEAD" case (services_trusted defaults to
# 1 in fork-sandbox-k8s.sh's cmd_submit): rejections are asserted this way
# without needing a stubbed kubectl, since the parser runs and can fail
# before any Job is even assembled, --dry-run or not.
svc_mk_repo() {
    local content="$1" d
    d="$(newdir)"; tmpdirs+=("$d")
    mkdir -p "$d/.agents/sandbox-services"
    printf '%s' "$content" > "$d/.agents/sandbox-services/services.yaml"
    git -C "$d" init -q
    git -C "$d" -c user.email=t@example -c user.name=t add -A
    git -C "$d" -c user.email=t@example -c user.name=t commit -q -m spec
    printf '%s\n' "$d"
}
svc_initcontainers_count() {
    awk '/^      initContainers:/{f=1} f&&/^      containers:/{f=0} f' "$1" | grep -c '^        - name:'
}
svc_volumes_count() {
    awk '/^      volumes:/{f=1} f' "$1" | grep -c '^        - name:'
}
svc_refuses() {
    local label="$1" needle="$2" spec="$3" d
    d="$(svc_mk_repo "$spec")"
    refuses "$label" "$needle" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch fs-k8s-test-svc-rej --model moonshotai/kimi-k3 "$d" "$handoff_file"
}

# No spec file: byte-for-byte the same regression proof as every existing
# repo is in today -- proj_dir (built above) has no
# .agents/sandbox-services/ at all. This is the case that matters most: it
# must render exactly as before and never warn.
svc_nosvc_out="$(newdir)/svc-nosvc.yaml"; tmpdirs+=("$(dirname "$svc_nosvc_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-none --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$svc_nosvc_out" 2>/tmp/fs-k8s-test-svc-none.err; then
    ok "submit --dry-run with no services spec exits 0"
else
    no "submit --dry-run with no services spec exits 0" "$(cat /tmp/fs-k8s-test-svc-none.err)"
fi
if [[ -s /tmp/fs-k8s-test-svc-none.err ]]; then
    no "no services spec: nothing warns on stderr" "$(cat /tmp/fs-k8s-test-svc-none.err)"
else
    ok "no services spec: nothing warns on stderr"
fi
for needle in 'sandbox-env:' '## Per-run services' 'terminationGracePeriodSeconds'; do
    if grep -qF -- "$needle" "$svc_nosvc_out"; then
        no "no services spec: rendered Job has no '$needle'" "found it"
    else
        ok "no services spec: rendered Job has no '$needle'"
    fi
done
check "no services spec: initContainers has exactly one entry (egress-gate only)" \
    1 "$(svc_initcontainers_count "$svc_nosvc_out")"

# A valid one-service spec: one initContainers entry, restartPolicy:
# Always, the harness security context present, port/env/writableDirs/
# readyWhen/resources all rendered as given.
svc1_dir="$(svc_mk_repo 'version: 1
services:
  - name: postgres
    image: registry.example/rootless/postgres:16
    port: 5432
    env:
      POSTGRES_PASSWORD: dev
    writableDirs:
      - /var/lib/postgresql/data
    readyWhen:
      tcpPort: 5432
    resources:
      cpu: 500m
      memory: 512Mi
sandboxEnv:
  DATABASE_URL: "postgres://dev:dev@127.0.0.1:5432/dev"
')"
svc1_out="$(newdir)/svc1.yaml"; tmpdirs+=("$(dirname "$svc1_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc1 --model moonshotai/kimi-k3 \
    "$svc1_dir" "$handoff_file" > "$svc1_out" 2>/tmp/fs-k8s-test-svc1.err; then
    ok "submit --dry-run with a valid one-service spec exits 0"
else
    no "submit --dry-run with a valid one-service spec exits 0" "$(cat /tmp/fs-k8s-test-svc1.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$svc1_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: one-service submit --dry-run output"; else no "yamllint: one-service submit --dry-run output" "$out"; fi
fi
check "one-service spec: initContainers has exactly two entries (egress-gate, postgres)" \
    2 "$(svc_initcontainers_count "$svc1_out")"
if grep -qF -- '        - name: postgres' "$svc1_out" \
    && grep -A1 -F -- '        - name: postgres' "$svc1_out" | grep -qF 'image: "registry.example/rootless/postgres:16"'; then
    ok "one-service spec: the sidecar's name and image render as given"
else
    no "one-service spec: the sidecar's name and image render as given" "$(cat "$svc1_out")"
fi
if grep -A3 -F -- '        - name: postgres' "$svc1_out" | grep -qF 'restartPolicy: Always'; then
    ok "one-service spec: the sidecar carries restartPolicy: Always (native sidecar)"
else
    no "one-service spec: the sidecar carries restartPolicy: Always (native sidecar)" "$(cat "$svc1_out")"
fi
svc1_postgres_block="$(awk '/^        - name: postgres$/{f=1} f&&/^        - name:/&&!/^        - name: postgres$/{exit} f&&/^      [a-zA-Z]/{exit} f' "$svc1_out")"
if grep -qF 'allowPrivilegeEscalation: false' <<< "$svc1_postgres_block" \
    && grep -qF 'readOnlyRootFilesystem: true' <<< "$svc1_postgres_block" \
    && grep -qF 'drop: ["ALL"]' <<< "$svc1_postgres_block"; then
    ok "one-service spec: the harness's security context is present on the sidecar"
else
    no "one-service spec: the harness's security context is present on the sidecar" "$svc1_postgres_block"
fi
if grep -A2 -F 'env:' "$svc1_out" | grep -qF -- '- name: POSTGRES_PASSWORD'; then
    ok "one-service spec: env renders the given key"
else
    no "one-service spec: env renders the given key" "$(cat "$svc1_out")"
fi
if grep -qF 'value: "dev"' "$svc1_out"; then
    ok "one-service spec: env renders the given literal value"
else
    no "one-service spec: env renders the given literal value" "$(cat "$svc1_out")"
fi
if grep -A2 -F 'startupProbe:' "$svc1_out" | grep -qF 'port: 5432'; then
    ok "readyWhen.tcpPort renders a startupProbe"
else
    no "readyWhen.tcpPort renders a startupProbe" "$(cat "$svc1_out")"
fi
if grep -qF -- '- name: postgres-wd0' "$svc1_out" \
    && grep -A1 -F -- '- name: postgres-wd0' "$svc1_out" | grep -qF 'mountPath: "/var/lib/postgresql/data"'; then
    ok "writableDirs renders a volumeMount"
else
    no "writableDirs renders a volumeMount" "$(cat "$svc1_out")"
fi
if [[ "$(svc_volumes_count "$svc1_out")" -eq 5 ]] \
    && grep -A1 -F -- '        - name: postgres-wd0' "$svc1_out" | grep -qF 'emptyDir: {}'; then
    ok "writableDirs renders exactly one emptyDir volume for the one entry given"
else
    no "writableDirs renders exactly one emptyDir volume for the one entry given" "$(cat "$svc1_out")"
fi
if grep -qF '  sandbox-env: |' "$svc1_out" \
    && grep -A1 -F '  sandbox-env: |' "$svc1_out" | grep -qF 'DATABASE_URL=postgres://dev:dev@127.0.0.1:5432/dev'; then
    ok ".env.sandbox content (sandbox-env ConfigMap key) matches sandboxEnv"
else
    no ".env.sandbox content (sandbox-env ConfigMap key) matches sandboxEnv" "$(cat "$svc1_out")"
fi
if grep -qF '## Per-run services' "$svc1_out" \
    && grep -qF '    postgres 127.0.0.1:5432' "$svc1_out"; then
    ok "the prompt names the service and its 127.0.0.1:<port>"
else
    no "the prompt names the service and its 127.0.0.1:<port>" "$(cat "$svc1_out")"
fi
if grep -qF 'terminationGracePeriodSeconds: 10' "$svc1_out"; then
    ok "terminationGracePeriodSeconds is set to 10 when services are present"
else
    no "terminationGracePeriodSeconds is set to 10 when services are present" "$(cat "$svc1_out")"
fi

# Two services: both present, both ports distinct, and no readyWhen means
# no startupProbe.
svc2_dir="$(svc_mk_repo 'version: 1
services:
  - name: a
    image: registry.example/a:1
    port: 5432
  - name: b
    image: registry.example/b:1
    port: 6379
')"
svc2_out="$(newdir)/svc2.yaml"; tmpdirs+=("$(dirname "$svc2_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc2 --model moonshotai/kimi-k3 \
    "$svc2_dir" "$handoff_file" > "$svc2_out" 2>/tmp/fs-k8s-test-svc2.err; then
    ok "submit --dry-run with a valid two-service spec exits 0"
else
    no "submit --dry-run with a valid two-service spec exits 0" "$(cat /tmp/fs-k8s-test-svc2.err)"
fi
check "two-service spec: initContainers has exactly three entries (egress-gate, a, b)" \
    3 "$(svc_initcontainers_count "$svc2_out")"
if grep -qF '    a 127.0.0.1:5432' "$svc2_out" && grep -qF '    b 127.0.0.1:6379' "$svc2_out"; then
    ok "two-service spec: both services' ports render, both distinct"
else
    no "two-service spec: both services' ports render, both distinct" "$(cat "$svc2_out")"
fi
if grep -qF 'The clone holds an env file, \.env.sandbox' "$svc2_out"; then
    no "service-only spec: prompt does not name a nonexistent env file" "found env-file paragraph"
else
    ok "service-only spec: prompt does not name a nonexistent env file"
fi
if grep -qF 'startupProbe:' "$svc2_out"; then
    no "no readyWhen renders no startupProbe" "found startupProbe: with no readyWhen given"
else
    ok "no readyWhen renders no startupProbe"
fi

# Resources are always rendered, including when the spec omits them or gives
# only one member: omitted members take the configured per-service cap.
svc_cap_dir="$(svc_mk_repo 'version: 1
services:
  - name: capped
    image: registry.example/capped:1
    port: 5432
  - name: partial
    image: registry.example/partial:1
    port: 5433
    resources:
      cpu: 250m
')"
svc_cap_out="$(newdir)/svc-cap.yaml"; tmpdirs+=("$(dirname "$svc_cap_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-cap --model moonshotai/kimi-k3 \
    "$svc_cap_dir" "$handoff_file" > "$svc_cap_out" 2>/tmp/fs-k8s-test-svc-cap.err; then
    ok "omitted and partial resources render successfully"
else
    no "omitted and partial resources render successfully" "$(cat /tmp/fs-k8s-test-svc-cap.err)"
fi
svc_cap_block="$(awk '/^        - name: capped$/{f=1} f&&/^        - name:/&&!/^        - name: capped$/{exit} f' "$svc_cap_out")"
svc_partial_block="$(awk '/^        - name: partial$/{f=1} f&&/^        - name:/&&!/^        - name: partial$/{exit} f' "$svc_cap_out")"
if [[ "$(grep -c '^            requests:$' <<<"$svc_cap_block")" == 1 \
    && "$(grep -c '^            limits:$' <<<"$svc_cap_block")" == 1 ]]; then
    ok "no-resources service renders both resource blocks"
else
    no "no-resources service renders both resource blocks" "$svc_cap_block"
fi
if [[ "$(grep -c '^            requests:$' <<<"$svc_partial_block")" == 1 \
    && "$(grep -c '^            limits:$' <<<"$svc_partial_block")" == 1 ]]; then
    ok "partial resources service renders both resource blocks"
else
    no "partial resources service renders both resource blocks" "$svc_partial_block"
fi
if grep -A12 -F -- '        - name: capped' "$svc_cap_out" | grep -qF 'cpu: "1000m"' \
    && grep -A12 -F -- '        - name: capped' "$svc_cap_out" | grep -qF 'memory: "1Gi"'; then
    ok "no-resources service defaults cpu and memory to their caps"
else
    no "no-resources service defaults cpu and memory to their caps" "$svc_cap_block"
fi
if grep -A12 -F -- '        - name: partial' "$svc_cap_out" | grep -qF 'cpu: "250m"' \
    && grep -A12 -F -- '        - name: partial' "$svc_cap_out" | grep -qF 'memory: "1Gi"'; then
    ok "partial resources preserves cpu and defaults memory to its cap"
else
    no "partial resources preserves cpu and defaults memory to its cap" "$svc_partial_block"
fi

printf '\n== per-run services: --services-trust-ref gates the spec like the local hook ==\n'
svc_trust_dir="$(mktemp -d "$HOME/src/fs-k8s-svc-trust-test.XXXXXX")"; tmpdirs+=("$svc_trust_dir")
(
    # shellcheck disable=SC2030,SC2031  # scoped to this subshell only, same as the co_proj fixture above
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    cd "$svc_trust_dir" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && mkdir -p .agents/sandbox-services \
        && printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/a:1\n    port: 5432\n' \
            > .agents/sandbox-services/services.yaml \
        && git add -A && git commit -q -m base \
        && git tag fs-k8s-svc-trust-v1 \
        && printf 'x\n' > unrelated.txt && git add -A && git commit -q -m unrelated
) >/dev/null 2>&1
svc_trust_tag=fs-k8s-svc-trust-v1
svc_trust_unchanged_sha="$(git -C "$svc_trust_dir" rev-parse --verify --quiet HEAD)"

svc_trust_a_out="$(newdir)/svc-trust-a.yaml"; tmpdirs+=("$(dirname "$svc_trust_a_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-a --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_unchanged_sha" --services-trust-ref "$svc_trust_tag" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_a_out" 2>/tmp/fs-k8s-test-svc-trust-a.err
check "--services-trust-ref, unchanged relative to it: services stay enabled" \
    2 "$(svc_initcontainers_count "$svc_trust_a_out")"

(
    cd "$svc_trust_dir" \
        && printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/a:1\n    port: 5433\n' \
            > .agents/sandbox-services/services.yaml \
        && git -c user.email=t@fork-sandbox.invalid -c user.name=Tester add -A \
        && git -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q -m changed
) >/dev/null 2>&1
svc_trust_changed_sha="$(git -C "$svc_trust_dir" rev-parse --verify --quiet HEAD)"

svc_trust_b_out="$(newdir)/svc-trust-b.yaml"; tmpdirs+=("$(dirname "$svc_trust_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-b --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_changed_sha" --services-trust-ref "$svc_trust_tag" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_b_out" 2>/tmp/fs-k8s-test-svc-trust-b.err
check "--services-trust-ref, changed relative to it: services disabled" \
    1 "$(svc_initcontainers_count "$svc_trust_b_out")"
if grep -qF 'relative to the trusted' /tmp/fs-k8s-test-svc-trust-b.err; then
    ok "--services-trust-ref, changed relative to it: warns naming the trust gate"
else
    no "--services-trust-ref, changed relative to it: warns naming the trust gate" \
        "$(cat /tmp/fs-k8s-test-svc-trust-b.err)"
fi

svc_trust_c_out="$(newdir)/svc-trust-c.yaml"; tmpdirs+=("$(dirname "$svc_trust_c_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-c --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_changed_sha" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_c_out" 2>/tmp/fs-k8s-test-svc-trust-c.err
check "--checkout with no --services-trust-ref: services disabled" \
    1 "$(svc_initcontainers_count "$svc_trust_c_out")"
if grep -qF 'unanchored ref' /tmp/fs-k8s-test-svc-trust-c.err; then
    ok "--checkout with no --services-trust-ref: warns that the ref is unanchored"
else
    no "--checkout with no --services-trust-ref: warns that the ref is unanchored" \
        "$(cat /tmp/fs-k8s-test-svc-trust-c.err)"
fi

printf '\n== per-run services: every rejection in the spec names the offending field ==\n'
svc_refuses "unknown top-level key" \
    "unknown top-level key 'unknownTop'" \
    'version: 1
services: []
unknownTop: 1
'
svc_refuses "wrong version" \
    "version: must be one of [1], got 2" \
    'version: 2
services: []
'
svc_refuses "bad name" \
    "services[0].name: 'Bad_Name' must match" \
    'version: 1
services:
  - name: Bad_Name
    image: registry.example/x:1
    port: 5432
'
svc_refuses "reserved name" \
    "is reserved by the harness's own pod containers" \
    'version: 1
services:
  - name: egress-gate
    image: registry.example/x:1
    port: 5432
'
svc_refuses "duplicate name across services" \
    "is used by more than one service; names must be unique" \
    'version: 1
services:
  - name: a
    image: registry.example/x:1
    port: 5432
  - name: a
    image: registry.example/y:1
    port: 5433
'
svc_refuses "bad image" \
    "value may not contain a quote or a backslash" \
    'version: 1
services:
  - name: db
    image: "registry.example/db'"'"'x:1"
    port: 5432
'
svc_refuses "port out of range" \
    "must be between 1025 and 65535, got 80" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 80
'
svc_refuses "duplicate port" \
    "is also used by service 'a'; ports must be unique" \
    'version: 1
services:
  - name: a
    image: registry.example/x:1
    port: 5432
  - name: b
    image: registry.example/y:1
    port: 5432
'
svc_refuses "relative writableDirs" \
    "must be an absolute path" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - relative/path
'
svc_refuses ".. in writableDirs" \
    "must not contain '..'" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - /var/../etc
'
svc_refuses "duplicate writableDirs entry" \
    "is already listed for this service" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - /data
      - /data
'
svc_refuses "readyWhen unknown key" \
    "unknown key 'execCommand'; only 'tcpPort' is supported" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    readyWhen:
      execCommand: foo
'
svc_refuses "readyWhen missing tcpPort" \
    "readyWhen: needs 'tcpPort'" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    readyWhen: {}
'
svc_refuses "too many services" \
    "more than the 8 allowed" \
    "version: 1
services:
$(for i in 1 2 3 4 5 6 7 8 9; do printf '  - name: svc%d\n    image: registry.example/x:1\n    port: %d\n' "$i" $((5432 + i)); done)
"
svc_refuses "over-cap resources" \
    "exceeds the per-service cap" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    resources:
      cpu: 2000m
'
for key in securityContext hostPath privileged; do
    svc_refuses "spec attempting '$key:' is rejected as an unknown key, not expressible" \
        "unknown key '$key'" \
        "version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    $key: {}
"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
