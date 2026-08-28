#!/usr/bin/env bash
# build-sandbox-image.sh -- Build the sandbox image the container backend runs
#
# Usage: build-sandbox-image.sh [--tag NAME] [--claude VER] [--codex VER] [--pi VER] [--no-cache]
#
# The container backend gets its userland from an image rather than from the
# host, which is what makes macOS possible and what makes the toolchain this
# image's problem. images/sandbox/Dockerfile is that image; this builds it.
#
# --tag names the result (default fork-sandbox:latest). --claude, --codex and
# --pi pin an agent CLI to a version, or leave it out entirely with "none";
# each defaults to "latest".
#
# On success it prints the line to put in your environment:
#
#   export FORK_SANDBOX_BACKEND=container
#   export FORK_SANDBOX_CONTAINER_IMAGE=fork-sandbox:latest
#
# This script never pushes anywhere, and this project never ships a built
# image or a registry of its own -- deliberately: the image carries the agent
# CLIs, and a local run hands them your access token, so the honest
# arrangement is that you build the thing you trust rather than pull a copy
# someone else built.
#
# A Kubernetes run (docs/kubernetes-runs.md) is the one case that needs this
# image to leave the machine that built it: a pod cannot pull from a local
# docker daemon, so that path pushes the image you built here to a registry
# you control (see "Bringing your own image and registry" in that doc for
# concrete options) and names it with K8S_IMAGE. That does not weaken the
# reasoning above, and if anything the supply-chain exposure is LOWER for a
# Kubernetes run than a local one: the k8s agent pod holds no credential of
# its own at all, where a locally-run agent may carry a model token this
# image's build step never sees or needs to protect.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
repo_root="$(dirname "$script_dir")"
dockerfile="$repo_root/images/sandbox/Dockerfile"

TAG="fork-sandbox:latest"
CLAUDE_VERSION="latest"
CODEX_VERSION="latest"
PI_VERSION="latest"
EXTRA=()

while (( $# )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a name}"; shift 2 ;;
        --claude) CLAUDE_VERSION="${2:?--claude requires a version or 'none'}"; shift 2 ;;
        --codex) CODEX_VERSION="${2:?--codex requires a version or 'none'}"; shift 2 ;;
        --pi) PI_VERSION="${2:?--pi requires a version or 'none'}"; shift 2 ;;
        --no-cache) EXTRA+=(--no-cache); shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

CLI="${FORK_SANDBOX_CONTAINER_CLI:-docker}"
command -v "$CLI" >/dev/null || {
    echo "Error: '$CLI' not found. This builds a container image, so it needs a" >&2
    echo "container runtime. Set FORK_SANDBOX_CONTAINER_CLI for a" >&2
    echo "Docker-compatible CLI under another name." >&2
    exit 1
}
[[ -f "$dockerfile" ]] || {
    echo "Error: $dockerfile not found. Run this from a fork-sandbox checkout." >&2
    exit 1
}

echo "Building $TAG from $dockerfile" >&2
echo "  claude=$CLAUDE_VERSION codex=$CODEX_VERSION pi=$PI_VERSION" >&2

"$CLI" build \
    --tag "$TAG" \
    --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION" \
    --build-arg "CODEX_VERSION=$CODEX_VERSION" \
    --build-arg "PI_VERSION=$PI_VERSION" \
    "${EXTRA[@]+"${EXTRA[@]}"}" \
    "$(dirname "$dockerfile")"

echo "" >&2
echo "Built $TAG. What is inside it:" >&2
"$CLI" run --rm --entrypoint cat "$TAG" /etc/fork-sandbox-image >&2 || true
echo "" >&2
echo "To use it:" >&2
echo "  export FORK_SANDBOX_BACKEND=container" >&2
echo "  export FORK_SANDBOX_CONTAINER_IMAGE=$TAG" >&2
