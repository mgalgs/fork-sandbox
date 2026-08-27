#!/bin/bash
# Install fork-sandbox: put the scripts on PATH and the skills where agents look.
#
# Usage: ./install.sh [--check]
#
# Everything is a symlink back into this checkout, so `git pull` is the whole
# upgrade path and nothing is copied anywhere to go stale.
#
#   scripts/*   ->  ~/.claude/scripts/          (and that directory onto PATH)
#   skills/*    ->  ~/.claude/skills/           Claude Code
#               ->  ~/.agents/skills/           the Agent Skills convention
#               ->  ~/.pi/agent/skills/         pi
#
# The scripts are harness-neutral: fork-sandbox.sh runs claude, pi or codex.
# The skills are for the agent that ORCHESTRATES runs, which is why they land
# in every farm — install the ones your orchestrator reads and ignore the rest.
#
# --check reports what is missing and installs nothing. Run it first; the
# sandbox needs bubblewrap and pasta, and neither is usually present by
# default.
#
# This does NOT touch settings.json. The three commands meant to run without a
# permission prompt are listed in docs/permissions.md, with the reasoning for
# each — adding them is a decision, not a step in an installer.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.claude/scripts"
SKILL_FARMS=("$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.pi/agent/skills")

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
elif [[ $# -gt 0 ]]; then
    echo "Usage: ./install.sh [--check]" >&2
    exit 1
fi

# --- Dependencies -----------------------------------------------------------
#
# Required means fork-sandbox.sh cannot run at all without it. Optional means
# one harness or one flag needs it, and the rest still works.

missing_required=()
missing_optional=()

need() {
    local tool="$1" why="$2" tier="$3"
    command -v "$tool" >/dev/null && return 0
    if [[ "$tier" == required ]]; then
        missing_required+=("$tool — $why")
    else
        missing_optional+=("$tool — $why")
    fi
}

HOST_OS="$(uname -s)"

need git    "cloning the project into the sandbox"               required
need jq     "reading run events and generating agent config"     required

# Which sandbox this machine can actually run decides what is required.
# bubblewrap and pasta are Linux kernel features with no macOS equivalent, so
# listing them as missing on a Mac would be reporting the weather. There the
# container backend is the sandbox, and its own dependencies take their place.
if [[ "$HOST_OS" == Darwin ]]; then
    need docker "the container backend: the sandbox macOS runs"   required
    need flock  "the container backend's per-work-directory lock" required
    need tmux   "detached runs; --foreground works without it"    optional
    need socat  "the model bridge for a sealed local-model run"   optional
    need python3 "sandbox-run-log.py, the durable run log"        optional
else
    need bwrap  "bubblewrap: the sandbox itself"                     required
    need pasta  "passt: pinned egress for a non-sealed run"          required
    need tmux   "detached runs; --foreground works without it"       optional
    need socat  "the model bridge for a sealed local-model run"      optional
    need setsid "same bridge: its own process group for teardown"    optional
    need docker "container backend and --services runtime"           optional
    need python3 "sandbox-run-log.py, the durable run log"           optional
fi

# The scripts start with `#!/usr/bin/env bash`, so the bash that matters is the
# first one on PATH, not the /bin/bash running this installer. macOS ships 3.2
# from 2007, and these scripts use mapfile and ${var,,}, which are bash 4.
# Check the one that will actually run them.
env_bash="$(command -v bash 2>/dev/null || true)"
if [[ -n "$env_bash" ]]; then
    # shellcheck disable=SC2016  # the expansion is for the inner bash, not this one
    bash_major="$("$env_bash" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)"
    if [[ "$bash_major" =~ ^[0-9]+$ ]] && (( bash_major < 4 )); then
        missing_required+=("bash 4+ — $env_bash is $bash_major.x; the scripts use mapfile and \${var,,}")
    fi
fi

# GNU coreutils. realpath -m and stat -c are GNU flags the BSD tools of the
# same name do not have. On Linux these ARE the GNU tools; under Homebrew they
# are grealpath and gstat, which the scripts find on their own -- but only if
# coreutils is installed at all.
for gnu_tool in realpath stat; do
    if ! { "g$gnu_tool" --version 2>/dev/null || "$gnu_tool" --version 2>/dev/null; } \
        | grep -q "GNU coreutils"; then
        missing_required+=("GNU $gnu_tool — the scripts use its GNU-only flags (brew install coreutils)")
    fi
done

if (( ${#missing_required[@]} )); then
    echo "Missing required tools:"
    printf '  %s\n' "${missing_required[@]}"
    echo ""
    echo "On Debian/Ubuntu: apt install bubblewrap passt git jq"
    echo "On Arch:          pacman -S bubblewrap passt git jq"
    echo "On Fedora:        dnf install bubblewrap passt git jq"
    echo ""
fi
if (( ${#missing_optional[@]} )); then
    echo "Missing optional tools:"
    printf '  %s\n' "${missing_optional[@]}"
    echo ""
fi

# The default sandbox is bubblewrap and network namespaces, so it is
# Linux-only. Say so here rather than let bwrap's absence read as a packaging
# problem -- and say what the container backend does and does not get you,
# rather than let its existence read as macOS support.
if [[ "$HOST_OS" != "Linux" ]]; then
    echo "Note: the default backend is bubblewrap plus a network namespace,"
    echo "which is Linux-only. On macOS the sandbox is sandbox-backend-container,"
    echo "which implements the same contract in a Linux container. Select it,"
    echo "and build the image that supplies its userland:"
    echo ""
    echo "  ./scripts/build-sandbox-image.sh"
    echo "  export FORK_SANDBOX_BACKEND=container"
    echo "  export FORK_SANDBOX_CONTAINER_IMAGE=fork-sandbox:latest"
    echo ""
    echo "Homebrew supplies the rest:"
    echo "  brew install bash coreutils util-linux"
    echo "util-linux is keg-only, so put its bin directory on PATH for flock."
    echo ""
    echo "Two things are still unverified on macOS, and both fail closed: the"
    echo "Darwin routing branch that builds pinned egress, and unix-socket"
    echo "bridges (so --harness pi-local). See docs/macos-support.md."
    echo ""
fi

# Unprivileged user namespaces are what let bwrap run without root. Some
# distros ship them disabled, and the failure is otherwise cryptic.
if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]] &&
   [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" == "0" ]]; then
    echo "Warning: unprivileged user namespaces are disabled on this kernel."
    echo "bwrap will fail. Enable with:"
    echo "  sudo sysctl -w kernel.unprivileged_userns_clone=1"
    echo ""
fi

if (( CHECK_ONLY )); then
    if (( ${#missing_required[@]} )); then
        exit 1
    fi
    echo "All required tools present."
    exit 0
fi

# --- Symlinks ---------------------------------------------------------------

ensure_link() {
    local source="$1" target="$2" label="$3"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        return
    elif [ -L "$target" ]; then
        echo "  $label: updated symlink"
        rm "$target"
    elif [ -e "$target" ]; then
        echo "  $label: WARNING — $target exists and is not a symlink, skipping"
        return
    else
        echo "  $label: linked"
    fi
    ln -s "$source" "$target"
}

mkdir -p "$SCRIPTS_DIR" "${SKILL_FARMS[@]}"

# Per file, not per directory: the farm is shared with whatever else you keep
# there, so this only ever owns the names it installs.
for script in "$REPO_DIR"/scripts/*; do
    ensure_link "$script" "$SCRIPTS_DIR/$(basename "$script")" "$(basename "$script")"
done

for skill_dir in "$REPO_DIR"/skills/*/; do
    skill_name="$(basename "$skill_dir")"
    for farm in "${SKILL_FARMS[@]}"; do
        ensure_link "$skill_dir" "$farm/$skill_name" "$skill_name (${farm#"$HOME/"})"
    done
done

echo ""
echo "Done. (Only new or changed symlinks are shown above.)"

case ":$PATH:" in
    *":$SCRIPTS_DIR:"*) ;;
    *)
        echo ""
        echo "Add the scripts to your PATH — the skills call them by bare name:"
        echo "  export PATH=\"\$PATH:$SCRIPTS_DIR\""
        ;;
esac

echo ""
echo "Next: docs/sandbox-quickstart.md to run one, docs/permissions.md to stop"
echo "your agent being prompted every time it checks on one."
