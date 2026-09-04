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
# name that instead. Keeping this one small is deliberate.
#
# It is also a supply-chain surface, and worth naming as one: it holds the
# agent CLIs, and a run gives them the user's access token. Build it yourself
# from this file; there is no registry copy to trust.

FROM node:22-bookworm-slim

# bash, because the backend's generated bootstrap and the callers' shims are
# bash. git and jq, because a run commits and the tooling reads JSON.
# iproute2, because pinned mode installs routes with `ip` -- and the backend's
# probe wants real iproute2, not BusyBox's applet. socat, because a sealed
# run's bridges are socat relays. ca-certificates, because every agent CLI
# talks TLS. ripgrep and less because the agents shell out to them.
# shellcheck, because a repo whose contribution rules require it -- this one
# does -- otherwise hands an agent a rule it cannot follow: the sandbox has no
# network, so a run that finds shellcheck missing cannot install it and can
# only report that it skipped the check.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
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
    && rm -rf /var/lib/apt/lists/*

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
