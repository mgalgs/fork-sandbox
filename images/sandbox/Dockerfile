# The sandbox image: the userland a container-backend run gets.
#
# bwrap mounts the host's /usr, so a bwrap sandbox inherits the host's tools.
# A container does not: its userland is this image's. That is the whole reason
# this file exists, and the reason macOS can work at all -- a Mach-O binary
# cannot run in a Linux container, so the toolchain has to be here instead of
# bound in from the host.
#
# Build it with scripts/build-sandbox-image.sh, and point the backend at it
# with FORK_SANDBOX_CONTAINER_IMAGE or --image.
#
# This is a BASE, not a universal answer. A repo whose suites need a compiler,
# a database client or a browser should build its own image FROM this one and
# name that instead. Keeping this one small is deliberate. On a --k8s run, a
# derived image may also carry an executable at /opt/fork-sandbox/provision,
# which the pod runs once before the agent starts to link its own prebuilt
# tooling into the clone -- see "Provisioning the clone from the image" in
# docs/kubernetes-runs.md. This base image deliberately ships no such
# executable.
#
# It is also a supply-chain surface, and worth naming as one: it holds the
# agent CLIs, and a run gives them the user's access token. Build it yourself
# from this file; there is no registry copy to trust.

ARG BASE_IMAGE=node:22-bookworm-slim
FROM ${BASE_IMAGE}

# The supported custom bases are Debian-family images with apt. Diagnose an
# incompatible base before apt's own (less useful) command-not-found failure.
RUN set -eu; \
    if ! command -v apt-get >/dev/null || ! command -v dpkg >/dev/null || [ ! -f /etc/os-release ]; then \
        echo 'Error: sandbox base requires Debian-family apt (apt-get and dpkg), node >=22 and npm.' >&2; exit 1; \
    fi; \
    . /etc/os-release; \
    case " ${ID:-} ${ID_LIKE:-} " in \
        *' debian '*) ;; \
        *) echo 'Error: sandbox base requires Debian-family apt, node >=22 and npm.' >&2; exit 1 ;; \
    esac; \
    if [ "$(id -u)" -ne 0 ]; then \
        echo 'Error: sandbox base must build as root to install apt packages and node >=22 with npm.' >&2; exit 1; \
    fi

# bash, because the backend's generated bootstrap and the callers' shims are
# bash. git and jq, because a run commits and the tooling reads JSON.
# iproute2, because pinned mode installs routes with `ip` -- and the backend's
# probe wants real iproute2, not BusyBox's applet. socat, because a sealed
# run's bridges are socat relays. ca-certificates, because every agent CLI
# talks TLS. ripgrep and less because the agents shell out to them.
# shellcheck, because a repo whose contribution rules require it -- this one
# does -- otherwise hands an agent a rule it cannot follow: the sandbox has no
# network, so a run that finds shellcheck missing cannot install it and can
# only report that it skipped the check. bsdextrautils for the same reason,
# one layer worse: it carries `column`, which shell test suites reach for
# routinely and which Debian leaves out of the slim base, and a seat that
# finds it missing has been observed writing its own stand-in and reporting
# the suite green -- a missing tool an agent can fake is worse than one it
# cannot. On bookworm and trixie, /usr/bin/column is in bsdextrautils,
# not util-linux.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bsdextrautils \
        ca-certificates \
        curl \
        git \
        iproute2 \
        jq \
        less \
        procps \
        python3 \
        ripgrep \
        shellcheck \
        socat \
        tar \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Keep an adequate node/npm from the base. Debian 13's nodejs package is too
# old, so fetch a fixed node 22 release when needed. Check the tarball against
# the official release's published SHA256 list before unpacking it.
RUN set -eu; \
    node_major=0; \
    if command -v node >/dev/null 2>&1; then \
        node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"; \
    fi; \
    case "$node_major" in ''|*[!0-9]*) node_major=0 ;; esac; \
    if [ "$node_major" -lt 22 ] || ! command -v npm >/dev/null 2>&1; then \
        case "$(dpkg --print-architecture)" in \
            amd64) node_arch=x64 ;; \
            arm64) node_arch=arm64 ;; \
            *) echo 'Error: node >=22 and npm require an official Linux amd64 or arm64 tarball.' >&2; exit 1 ;; \
        esac; \
        node_version=v22.16.0; \
        node_file="node-${node_version}-linux-${node_arch}.tar.xz"; \
        node_url="https://nodejs.org/dist/${node_version}"; \
        node_tmp="$(mktemp -d)"; \
        curl -fsSLo "$node_tmp/SHASUMS256.txt" "$node_url/SHASUMS256.txt"; \
        curl -fsSLo "$node_tmp/$node_file" "$node_url/$node_file"; \
        awk -v file="$node_file" '$2 == file { print }' "$node_tmp/SHASUMS256.txt" > "$node_tmp/checksum"; \
        [ -s "$node_tmp/checksum" ] || { echo "Error: published SHA256 missing for $node_file" >&2; exit 1; }; \
        (cd "$node_tmp" && sha256sum -c checksum); \
        tar -xJf "$node_tmp/$node_file" -C /usr/local --strip-components=1; \
        rm -rf "$node_tmp"; \
    fi

# Each agent CLI is installed globally, into /usr/local, and NEVER into a home
# directory: $HOME inside the sandbox is a fresh tmpfs, so anything under it
# would simply not be there. That rules out claude's native installer, which
# targets ~/.local/bin, and makes the npm package the right choice here.
#
# Set any of these to "none" to leave that agent out.
ARG CLAUDE_VERSION=latest
ARG CODEX_VERSION=latest
ARG PI_VERSION=latest

RUN if [ "$CLAUDE_VERSION" != none ]; then \
        npm install -g --no-fund --no-audit "@anthropic-ai/claude-code@$CLAUDE_VERSION"; \
    fi
RUN if [ "$CODEX_VERSION" != none ]; then \
        npm install -g --no-fund --no-audit "@openai/codex@$CODEX_VERSION"; \
    fi
RUN if [ "$PI_VERSION" != none ]; then \
        npm install -g --no-fund --no-audit "@earendil-works/pi-coding-agent@$PI_VERSION"; \
    fi
RUN npm cache clean --force

# What is actually in here, readable from inside a run and from `docker run`.
# A run record that names the image should be able to say what the image held,
# rather than leave "which claude ran this?" to guesswork.
RUN { \
        echo "node=$(node --version 2>/dev/null || echo none)"; \
        echo "npm=$(npm --version 2>/dev/null || echo none)"; \
        echo "git=$(git --version 2>/dev/null | awk '{print $3}' || echo none)"; \
        echo "claude=$(claude --version 2>/dev/null | head -1 || echo none)"; \
        echo "codex=$(codex --version 2>/dev/null | head -1 || echo none)"; \
        echo "pi=$(pi --version 2>/dev/null | head -1 || echo none)"; \
    } > /etc/fork-sandbox-image \
    && chmod 0444 /etc/fork-sandbox-image \
    && cat /etc/fork-sandbox-image

# The backend runs as the host's UID with all capabilities dropped, and
# synthesizes its own passwd and group entries. Nothing here may depend on
# running as root or on the image's own users. The backend overrides the
# entrypoint in any case; clearing node's keeps `docker run` on this image
# behaving the same way.
ENTRYPOINT []
CMD ["/bin/bash"]
