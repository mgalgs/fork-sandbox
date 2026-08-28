#!/bin/sh
# fork-sandbox-k8s-inbox-write.sh -- write one operator addendum inside the
# pod, invoked by fork-sandbox-k8s.sh's `say` verb over `kubectl exec -i`.
#
# Usage: fork-sandbox-k8s-inbox-write.sh EPOCH INBOX_DIR   (message on stdin)
#
# Mirrors fork-sandbox-say.sh's own naming rule: the filename is always
# generated (<epoch>-<nn>.md), never taken from an argument -- an argument
# that named a path would be the arbitrary-file-write primitive a write into
# someone else's pod must not become. EPOCH comes from the CLIENT's clock, at
# the moment `say` starts the write, not the pod's; the counter below only
# has to break ties within that one second. The search for a free name and
# the write both happen here, in the one process `kubectl exec -i` starts,
# so the final `mv` is a rename on one filesystem -- the same atomicity
# guarantee fork-sandbox-say.sh gets from `mv` locally.
#
# Written as a standalone POSIX sh script -- not inlined into
# fork-sandbox-k8s.sh -- so it can run two ways with no divergence between
# them: inside the pod (mounted from the per-run scripts ConfigMap, the same
# way entrypoint.sh and egress-gate.sh are), and directly in a test, with no
# cluster and no kubectl involved either way.

set -eu

epoch="${1:?usage: fork-sandbox-k8s-inbox-write.sh EPOCH INBOX_DIR}"
dir="${2:?usage: fork-sandbox-k8s-inbox-write.sh EPOCH INBOX_DIR}"

n=1
while [ "$n" -le 99 ]; do
    nn=$(printf '%02d' "$n")
    f="$dir/$epoch-$nn.md"
    if [ ! -e "$f" ] && [ ! -e "$f.part" ]; then
        if cat > "$f.part" && mv "$f.part" "$f"; then
            printf '%s\n' "$f"
            exit 0
        fi
        echo "could not write into $dir" >&2
        exit 1
    fi
    n=$((n + 1))
done
echo "99 addenda already written in this second; wait a moment and retry." >&2
exit 1
