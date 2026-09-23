# The postmaster image: a thin layer over the sandbox image (see
# images/sandbox/Dockerfile) that adds what fork-sandbox-postmaster.sh needs
# to run as a Deployment instead of on a laptop -- ssh (for the project's git
# remote) and kubectl (for every kubectl call the postmaster and the scripts
# it drives make, routed through the same `kubectl --context=$K8S_CONTEXT`
# wrapper as a local install).
#
# Build with scripts/build-sandbox-image.sh --postmaster --base <image-ref>,
# from the repo root (the COPY lines below need scripts/, share/ and
# manifests/ as build context, not just this directory). See
# docs/cluster-postmaster.md for the full setup.
#
# BASE_IMAGE must be a sandbox image already carrying the pi CLI (cluster
# postmasters are pi-only for now -- see docs/cluster-postmaster.md for why).

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.0
ARG KUBECTL_SHA256_AMD64=6129359f4e1f3848a5572ccb0b26cf28b8ca08cef38c95a765b2f64a2c961a2f
ARG KUBECTL_SHA256_ARM64=922df28df248cc00a9e025f947704f1d1482de64ece54cfe57e61f19eaf1eef3

USER root

# openssh-client: the base image has git, curl, python3 and jq, but no ssh,
# and the postmaster's pod init clones/fetches the project over ssh (deploy
# key only -- see docs/cluster-postmaster.md).
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

# kubectl is not in the base image at all: a laptop postmaster uses whatever
# kubectl is on the operator's PATH, but a pod has to carry its own. Pinned
# and checksummed rather than pulled from a moving "stable" URL, and the
# build fails outright on an architecture this Dockerfile has no pinned
# checksum for -- a silently-unverified kubectl binary in an image that
# holds a ServiceAccount token capable of creating Jobs is not a risk worth
# taking quietly.
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) sha256="$KUBECTL_SHA256_AMD64" ;; \
        arm64) sha256="$KUBECTL_SHA256_ARM64" ;; \
        *) echo "Error: no pinned kubectl checksum for TARGETARCH=$TARGETARCH." >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "${sha256}  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/kubectl

# The scripts, their share/ data and the manifest templates travel together,
# in the same layout as the checkout: fork-sandbox-k8s.sh locates
# manifests/k8s as a sibling of its own directory (dirname "$script_dir"),
# and every script here finds its sibling scripts through `readlink -f`, not
# through an install-time rewrite.
COPY scripts/ /opt/fork-sandbox/scripts/
COPY share/ /opt/fork-sandbox/share/
COPY manifests/ /opt/fork-sandbox/manifests/
RUN rm -rf /opt/fork-sandbox/scripts/__pycache__

ENV PATH=/opt/fork-sandbox/scripts:$PATH

ARG FORK_SANDBOX_COMMIT=unknown
RUN { \
        echo "kubectl=$(kubectl version --client 2>/dev/null | head -1 || echo none)"; \
        echo "fork-sandbox=${FORK_SANDBOX_COMMIT}"; \
    } >> /etc/fork-sandbox-image \
    && cat /etc/fork-sandbox-image

# The pod sets its own uid (see manifests/k8s/40-postmaster.yaml's pod
# securityContext), same as the sandbox image this is built on top of.
ENTRYPOINT []
