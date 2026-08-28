#!/usr/bin/env bash
# fork-sandbox-k8s-egress-gate.sh -- verify the pod's egress policy before
# anything untrusted runs
#
# Runs as the agent pod's initContainer, shipped in via a ConfigMap rather
# than baked into the image, so iterating on it needs no rebuild and no
# registry push. Invoked as `bash fork-sandbox-k8s-egress-gate.sh`.
#
# On a cluster observed in practice, the policy engine programs a pod's
# firewall chain roughly 15 seconds after the pod starts -- a probe pod
# reached the entire LAN at t+0 and was blocked from t+15. So this cannot run
# in the main container ahead of the agent: it has to be an initContainer,
# the only construct that guarantees nothing untrusted has run yet, and it
# has to POLL, not check once, because the policy can still be landing when
# the first check runs.
#
# It asserts both directions and requires them to hold SIMULTANEOUSLY:
#
#   - DENIED_PROBE (a host:port the policy must deny) must be UNREACHABLE.
#   - the proxy (PROXY_HOST:PROXY_PORT) must be REACHABLE.
#
# The second is not decoration. Without it a completely broken network --
# every route dropped, not just the denied one -- passes as a working
# policy: the denied probe would fail for the wrong reason, and nothing
# would catch it. Fail closed on either.
#
# If the platform's --capabilities declared icmp=filtered (ICMP_CHECK=1),
# it also probes ICMP to DENIED_PROBE's host and requires that to fail too.
# A platform declaring icmp=unfiltered leaves ICMP_CHECK=0, and the probe is
# skipped -- a probe expected to fail proves nothing about the platform.
#
# Env:
#   DENIED_PROBE   HOST:PORT that egress must NOT reach. Required.
#   PROXY_HOST     the proxy Service name. Required.
#   PROXY_PORT     the proxy Service port. Required.
#   ICMP_CHECK     1 to also require ICMP to DENIED_PROBE's host to fail.
#                  Defaults to 0.
#   GATE_TIMEOUT   seconds to poll before failing closed. Defaults to 60.
#
# Exit 0 only when every condition held on the same iteration. Exit 1,
# naming which condition never held, otherwise -- and the command this
# gates never runs, because an initContainer that exits non-zero stops the
# pod before the main container starts.

set -euo pipefail

: "${DENIED_PROBE:?DENIED_PROBE must be set to a HOST:PORT the policy must deny}"
: "${PROXY_HOST:?PROXY_HOST must be set to the proxy Service name}"
: "${PROXY_PORT:?PROXY_PORT must be set to the proxy Service port}"
: "${ICMP_CHECK:=0}"
: "${GATE_TIMEOUT:=60}"

if [[ "$DENIED_PROBE" != *:* ]]; then
    echo "Error: DENIED_PROBE must be HOST:PORT, got '$DENIED_PROBE'." >&2
    exit 1
fi
denied_host="${DENIED_PROBE%:*}"
denied_port="${DENIED_PROBE##*:}"

# A bare TCP connect attempt is enough to know whether the connection opens
# -- curl would add a dependency this check does not need, and would leave
# it unclear whether an HTTP-layer failure meant "blocked" or "reachable but
# erroring".
tcp_connects() {
    local host="$1" port="$2"
    timeout 2 bash -c "exec 3<>\"/dev/tcp/$host/$port\"" 2>/dev/null
}

# Only called when ICMP_CHECK=1, i.e. the platform claimed it filters ICMP.
# No ping binary in that case is itself a failure to verify the claim, not a
# reason to skip it -- fail closed rather than assume the platform is right.
icmp_is_blocked() {
    if ! command -v ping >/dev/null 2>&1; then
        echo "Error: the platform declared icmp=filtered, so this gate must" >&2
        echo "verify ICMP is blocked, but no ping binary is on PATH to probe" >&2
        echo "with. Failing closed rather than assuming the claim holds." >&2
        return 1
    fi
    ! timeout 2 ping -c 1 -W 1 "$denied_host" >/dev/null 2>&1
}

deadline=$(( $(date +%s) + GATE_TIMEOUT ))
denied_unreachable=0
proxy_reachable=0
icmp_ok=1
satisfied=0

while (( $(date +%s) < deadline )); do
    denied_unreachable=1
    tcp_connects "$denied_host" "$denied_port" && denied_unreachable=0

    proxy_reachable=0
    tcp_connects "$PROXY_HOST" "$PROXY_PORT" && proxy_reachable=1

    icmp_ok=1
    if [[ "$ICMP_CHECK" == 1 ]]; then
        icmp_ok=0
        icmp_is_blocked && icmp_ok=1
    fi

    if (( denied_unreachable )) && (( proxy_reachable )) && (( icmp_ok )); then
        satisfied=1
        break
    fi
    sleep 1
done

if (( ! satisfied )); then
    echo "Error: egress gate timed out after ${GATE_TIMEOUT}s. Unmet:" >&2
    (( denied_unreachable )) || echo "  - $DENIED_PROBE is reachable and must not be" >&2
    (( proxy_reachable )) || echo "  - $PROXY_HOST:$PROXY_PORT (the proxy) is not reachable" >&2
    (( icmp_ok )) || echo "  - ICMP to $denied_host did not fail as icmp=filtered requires" >&2
    exit 1
fi

elapsed=$(( GATE_TIMEOUT - (deadline - $(date +%s)) ))
echo "fork-sandbox-k8s-egress-gate: policy verified after ${elapsed}s, proceeding." >&2
exit 0
