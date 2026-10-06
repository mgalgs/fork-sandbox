#!/usr/bin/env bash
# fork-sandbox-k8s-service-ready.sh -- wait for per-run services' readyWhen
# ports to open, from inside the pod's shared network namespace
#
# Runs as a regular initContainer, placed AFTER the per-run service
# sidecars (native sidecars, restartPolicy: Always) in the Job's
# initContainers list, and shipped in via a ConfigMap rather than baked
# into the image, the same reason fork-sandbox-k8s-egress-gate.sh is --
# iterating on it needs no rebuild and no registry push. Invoked as
# `bash fork-sandbox-k8s-service-ready.sh`.
#
# Why this exists instead of a Kubernetes startupProbe on the service
# container itself:
#
#   - A kubelet tcpSocket/httpGet probe dials the POD IP from the node, so
#     it can never see a service that binds to 127.0.0.1 only -- which is
#     the right bind for a per-run database, since it already shares the
#     agent's network namespace and should not be reachable from the pod
#     network (see docs/sandbox-services.md).
#   - An `exec` probe on the service's OWN container would reach
#     127.0.0.1 fine (every container in a pod shares one network
#     namespace), but it has to run with a tool inside that container's
#     image, and a distroless or minimal service image may carry no
#     shell at all. This script instead runs in its own container, built
#     from the same image as the agent -- which this project already
#     requires to carry bash and /dev/tcp, see
#     fork-sandbox-k8s-egress-gate.sh -- and reaches every service over
#     the pod's shared loopback from there.
#   - Because no probe is attached to the service containers themselves,
#     a slow service is never killed and restarted for failing one.
#     Restarting a sidecar that is still starting only resets its
#     progress and is never useful (see docs/sandbox-services.md); this
#     script's own per-service deadline, not Kubernetes' probe retries,
#     is what bounds the wait.
#
# Env:
#   SERVICE_READY_CHECKS   space-separated "name:port:seconds" triples,
#                          one per service with a readyWhen -- rendered by
#                          fork-sandbox-k8s.sh from
#                          fork-sandbox-k8s-services-parse.py's
#                          "ready-checks" output. Defaults to empty
#                          (nothing to check -- exits 0 immediately).
#
# Exit 0 once every service's port has accepted a connection on 127.0.0.1
# within its own window. Exit 1, naming the first service whose window ran
# out, otherwise -- and the agent container never starts, because an
# initContainer that exits non-zero stops the pod there.

set -euo pipefail

: "${SERVICE_READY_CHECKS:=}"

read -ra checks <<< "$SERVICE_READY_CHECKS"
(( ${#checks[@]} > 0 )) || exit 0

names=() ports=() deadlines=()
now="$(date +%s)"
for entry in "${checks[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    port="${rest%%:*}"
    seconds="${rest##*:}"
    names+=("$name")
    ports+=("$port")
    deadlines+=("$(( now + seconds ))")
done

# A bare TCP connect attempt is enough to know the port is open -- see
# fork-sandbox-k8s-egress-gate.sh's own tcp_connects for why this is
# preferred over adding a curl/nc dependency.
tcp_connects() {
    timeout 2 bash -c "exec 3<>\"/dev/tcp/127.0.0.1/$1\"" 2>/dev/null
}

pending=()
for i in "${!names[@]}"; do pending+=("$i"); done

while (( ${#pending[@]} > 0 )); do
    still_pending=()
    for i in "${pending[@]}"; do
        if tcp_connects "${ports[$i]}"; then
            echo "fork-sandbox-k8s-service-ready: ${names[$i]} is ready" \
                "(127.0.0.1:${ports[$i]})." >&2
            continue
        fi
        if (( $(date +%s) >= ${deadlines[$i]} )); then
            echo "Error: service '${names[$i]}' did not open 127.0.0.1:${ports[$i]}" >&2
            echo "within its startup window. It may need more time" \
                "(readyWhen.startupSeconds in .agents/sandbox-services/services.yaml," >&2
            echo "capped by K8S_SERVICE_MAX_STARTUP_SECONDS), or it may be failing to" >&2
            echo "start -- check its own container log" \
                "(kubectl logs <pod> -c ${names[$i]})." >&2
            exit 1
        fi
        still_pending+=("$i")
    done
    pending=("${still_pending[@]+"${still_pending[@]}"}")
    (( ${#pending[@]} > 0 )) && sleep 1
done

echo "fork-sandbox-k8s-service-ready: every service is ready." >&2
exit 0
