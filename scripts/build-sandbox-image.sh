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
# The image is built locally and never pushed. There is no registry copy,
# deliberately: it carries the agent CLIs, and a run hands them your access
# token, so the honest arrangement is that you build the thing you trust.

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
