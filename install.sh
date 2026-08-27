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

need bwrap  "bubblewrap: the sandbox itself"                     required
need pasta  "passt: pinned egress for a non-sealed run"          required
need git    "cloning the project into the sandbox"               required
need jq     "reading run events and generating agent config"     required
need tmux   "detached runs; --foreground works without it"       optional
need socat  "the model bridge for a sealed local-model run"      optional
need setsid "same bridge: its own process group for teardown"    optional
need docker "container backend and --services runtime"           optional
need python3 "sandbox-run-log.py, the durable run log"           optional

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

# The sandbox is bubblewrap and network namespaces, so it is Linux-only. Say so
# here rather than let bwrap's absence read as a packaging problem.
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Note: this is Linux-only today. The isolation is bubblewrap plus a"
    echo "network namespace, and macOS has no equivalent — see the README for"
    echo "where a container backend would fit."
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
