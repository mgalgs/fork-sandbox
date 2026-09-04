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
# default. Every run also prints a separate, informational section reporting
# what the cluster path (fork-sandbox.sh --k8s) needs on this machine, because
# the two roads need different things.
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
# same name do not have, and macOS ships no timeout at all. On Linux these ARE
# the GNU tools; under Homebrew they are grealpath, gstat and gtimeout, which
# the scripts find on their own -- but only if coreutils is installed.
#
# This repeats fork-sandbox-lib.sh's _fs_resolve_gnu_tool rather than sourcing
# it, deliberately: one thing this installer has to do is tell a macOS user
# their bash is too old, and it cannot do that from a library it failed to
# parse with that same bash.
#
# Capture the version rather than piping it to grep. Under `set -o pipefail` a
# `--version | grep -q` gives the producer SIGPIPE, and the pipeline then
# reports a match as a failure. Trying the bare name after a g-prefixed one
# that turned out not to be GNU matters too -- `g`-prefixed is a convention,
# not a guarantee.
gnu_timeout=""
for gnu_tool in realpath stat timeout; do
    gnu_found=""
    for gnu_cand in "g$gnu_tool" "$gnu_tool"; do
        command -v "$gnu_cand" >/dev/null 2>&1 || continue
        gnu_ver="$("$gnu_cand" --version 2>/dev/null)" || gnu_ver=""
        case "$gnu_ver" in
            *"GNU coreutils"*) gnu_found="$gnu_cand"; break ;;
        esac
    done
    if [[ -z "$gnu_found" ]]; then
        missing_required+=("GNU $gnu_tool — the scripts need it (brew install coreutils)")
    elif [[ "$gnu_tool" == timeout ]]; then
        gnu_timeout="$gnu_found"
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

# --- Cluster path: a different road, reported separately ---------------------
#
# Informational only, and about a DIFFERENT road than the requirements above:
# fork-sandbox.sh --k8s runs the whole sandbox as a pod, so on that road the
# local sandbox never runs at all -- no container runtime, no sandbox image,
# no FORK_SANDBOX_BACKEND. Nothing here changes what the local backend
# requires, and a missing kubectl is not a broken install: it means only the
# cluster road is unavailable on this machine. Presence of a binary and the
# reported contents of a file only: this installs nothing and must not contact
# a cluster.
echo ""
echo "Cluster path (fork-sandbox.sh --k8s) -- a different road, informational only:"
echo "The sandbox is a pod, so this machine supplies neither a container"
echo "runtime (bwrap or docker) nor a locally-built sandbox image -- the pod"
echo "runs K8S_IMAGE from a registry. Nothing in this section is a required tool."
if kubectl_bin="$(command -v kubectl 2>/dev/null)"; then
    # --client reaches no cluster, and newer kubectl dropped -o short, so no
    # -o at all: take the first line, which is the Client version, and leave
    # the Kustomize line out of the report.
    kubectl_version="$(kubectl version --client 2>/dev/null | grep -m1 '^Client Version:' || true)"
    if [[ -n "$kubectl_version" ]]; then
        echo "  kubectl: found ($kubectl_bin)"
        echo "    $kubectl_version"
    else
        echo "  kubectl: found ($kubectl_bin)"
    fi
else
    echo "  kubectl: not found on PATH (cluster road unavailable; local backend unaffected)"
fi
# scripts/fork-sandbox-k8s.sh is authoritative for which keys exist and what
# they default to. This deliberately minimal re-read is for reporting only.
read_k8s_env_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "$key="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
    return 1
}

k8s_config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
k8s_env="$k8s_config_dir/k8s.env"
if [[ -e "$k8s_env" ]]; then
    echo "  $k8s_config_dir/k8s.env: present"
    if k8s_context="$(read_k8s_env_value "$k8s_env" K8S_CONTEXT)" && [[ -n "$k8s_context" ]]; then
        echo "    K8S_CONTEXT: set"
    else
        echo "    K8S_CONTEXT: MISSING -- a --k8s run will fail"
    fi
    if k8s_image="$(read_k8s_env_value "$k8s_env" K8S_IMAGE)" && [[ -n "$k8s_image" ]]; then
        echo "    K8S_IMAGE: set"
    else
        echo "    K8S_IMAGE: MISSING -- a --k8s run will fail at submit"
    fi
    if k8s_denied_probe="$(read_k8s_env_value "$k8s_env" K8S_DENIED_PROBE)" && [[ -n "$k8s_denied_probe" ]]; then
        echo "    K8S_DENIED_PROBE: set"
    else
        echo "    K8S_DENIED_PROBE: MISSING -- a --k8s run will fail at submit"
    fi
    if k8s_namespace="$(read_k8s_env_value "$k8s_env" K8S_NAMESPACE)" && [[ -n "$k8s_namespace" ]]; then
        echo "    K8S_NAMESPACE: $k8s_namespace"
    else
        echo "    K8S_NAMESPACE: fork-sandbox (default)"
    fi
    if [[ -n "${k8s_context:-}" && -n "$gnu_timeout" ]]; then
        if k8s_contexts="$($gnu_timeout 2s kubectl config get-contexts -o name 2>/dev/null)"; then
            k8s_context_found=0
            while IFS= read -r context_name; do
                if [[ "$context_name" == "$k8s_context" ]]; then
                    k8s_context_found=1
                    break
                fi
            done <<< "$k8s_contexts"
            if (( k8s_context_found )); then
                echo "    K8S_CONTEXT: $k8s_context (found in this machine's kubeconfig)"
            else
                echo "    K8S_CONTEXT: $k8s_context is not in this machine's kubeconfig; run 'kubectl config get-contexts' to see available contexts"
            fi
        else
            echo "    K8S_CONTEXT: unable to inspect contexts (kubectl config get-contexts failed or timed out)"
        fi
    fi
else
    echo "  $k8s_config_dir/k8s.env: not present"
fi
echo "  Usage: docs/kubernetes-runs.md."

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
