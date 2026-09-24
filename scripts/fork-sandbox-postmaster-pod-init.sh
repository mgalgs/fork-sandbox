#!/usr/bin/env bash
# fork-sandbox-postmaster-pod-init.sh -- Container command for the cluster
# postmaster Deployment (see docs/cluster-postmaster.md)
#
# Usage: fork-sandbox-postmaster-pod-init.sh
#
# Runs once, at container start, before handing off to the postmaster
# itself. In order:
#
#   1. Checks that every tool the rest of this script and the postmaster
#      need is on PATH: kubectl, git, ssh, flock, setsid, python3, tar.
#      Refuses, naming every missing one, rather than fail later on
#      whichever happens to be called first.
#   2. Reads $FORK_SANDBOX_CONFIG_DIR/k8s.env (default
#      $HOME/.config/fork-sandbox/k8s.env, the same file and the same
#      NAME=VALUE format a laptop's fork-sandbox-k8s.sh reads) for
#      K8S_CONTEXT (required), K8S_NAMESPACE (default fork-sandbox),
#      K8S_POSTMASTER_REPO_URL (required: an ssh:// or scp-like
#      user@host:path git URL -- anything else is refused) and
#      K8S_POSTMASTER_PROJECT (default: the URL's last path component
#      minus a trailing .git; must match ^[A-Za-z0-9][A-Za-z0-9._-]*$).
#   3. Writes $HOME/.kube/config from the pod's own ServiceAccount: a
#      single cluster pointed at the in-cluster API server, a single user
#      whose credential is a *reference* to the SA token file (never the
#      token's contents, so a rotated token is picked up with no restart),
#      and a single context named exactly $K8S_CONTEXT with namespace
#      $K8S_NAMESPACE, set current. Naming the context $K8S_CONTEXT (not
#      some fixed "in-cluster" name) is what lets every other script's
#      `kubectl --context=$K8S_CONTEXT` wrapper work unmodified in the pod.
#   4. Copies the mounted deploy key and known_hosts
#      ($FORK_SANDBOX_GIT_SECRET_DIR, default /etc/fork-sandbox/git) into
#      $HOME/.ssh (0600/0644) and exports GIT_SSH_COMMAND so the postmaster's
#      own later git calls inherit it.
#   5. Clones $K8S_POSTMASTER_REPO_URL to $HOME/src/$project if that
#      directory has no .git yet, else fetches it and fast-forwards the
#      checked-out branch to its upstream (a fetch alone only moves
#      refs/remotes/origin/*; the postmaster itself never fetches, so
#      without this HEAD would stay pinned at whatever commit the first
#      clone produced -- see docs/cluster-postmaster.md's "getting new
#      commits into the pod" section). A failed fetch on an existing
#      clone is a warning (the remote may be briefly down and the
#      postmaster can still route on what is already on disk); so is a
#      fast-forward that is not possible (a diverged local branch, e.g.
#      from manual `kubectl exec` surgery). A failed clone is fatal,
#      since there is nothing to route on at all.
#   6. execs fork-sandbox-postmaster.sh deliver --cluster --project
#      $HOME/src/$project, resolved next to this script (not via PATH).
#
# FORK_SANDBOX_SA_DIR overrides the ServiceAccount directory (default
# /var/run/secrets/kubernetes.io/serviceaccount); FORK_SANDBOX_POSTMASTER_BIN
# overrides the postmaster binary this execs. Both exist for tests only.

set -euo pipefail

self="$(readlink -f "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$self")"

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    sed -n '2,/^$/p' "$self" | sed 's/^# \{0,1\}//'
    exit 0
fi

# --- 1. self-check ----------------------------------------------------

missing=()
for tool in kubectl git ssh flock setsid python3 tar; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
    echo "Error: missing required tools: ${missing[*]}." >&2
    exit 1
fi

# --- 2. config ----------------------------------------------------------

config_dir="${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}"
k8s_env="$config_dir/k8s.env"

# Copied, not sourced, so a config file cannot execute code in this
# process -- same discipline fork-sandbox-k8s.sh's own read_env_value uses.
read_env_value() {
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

if [[ ! -f "$k8s_env" ]]; then
    echo "Error: $k8s_env not found." >&2
    exit 1
fi

k8s_context="$(read_env_value "$k8s_env" K8S_CONTEXT || true)"
k8s_namespace="$(read_env_value "$k8s_env" K8S_NAMESPACE || true)"
k8s_namespace="${k8s_namespace:-fork-sandbox}"
repo_url="$(read_env_value "$k8s_env" K8S_POSTMASTER_REPO_URL || true)"
project="$(read_env_value "$k8s_env" K8S_POSTMASTER_PROJECT || true)"

if [[ -z "$k8s_context" ]]; then
    echo "Error: K8S_CONTEXT not set in $k8s_env." >&2
    exit 1
fi
if [[ -z "$repo_url" ]]; then
    echo "Error: K8S_POSTMASTER_REPO_URL not set in $k8s_env." >&2
    exit 1
fi

if [[ "$repo_url" =~ ^ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(:[0-9]+)?/[^[:space:]]+$ ]]; then
    :
elif [[ "$repo_url" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^[:space:]]+$ ]]; then
    :
else
    echo "Error: K8S_POSTMASTER_REPO_URL='$repo_url' is not a recognized ssh URL" >&2
    echo "(ssh://host/path, ssh://user@host/path or user@host:path)." >&2
    exit 1
fi

if [[ -z "$project" ]]; then
    # scp-like URLs (user@host:path) have no scheme and no guaranteed "/"
    # -- a root-level path like user@host:proj.git has none at all -- so
    # strip the "host:" prefix first; the scp-form regex above guarantees
    # the first ":" is that separator, since host chars exclude ":".
    # ssh:// URLs always have a "/" before the path, so "##*/" alone works.
    if [[ "$repo_url" == ssh://* ]]; then
        project="${repo_url##*/}"
    else
        project="${repo_url#*:}"
        project="${project##*/}"
    fi
    project="${project%.git}"
fi
if [[ ! "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: project name '$project' is not a valid directory name" >&2
    echo "(set K8S_POSTMASTER_PROJECT explicitly)." >&2
    exit 1
fi

# --- 3. kubeconfig --------------------------------------------------------

sa_dir="${FORK_SANDBOX_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
token_file="$sa_dir/token"
ca_file="$sa_dir/ca.crt"

if [[ -z "${KUBERNETES_SERVICE_HOST:-}" ]]; then
    echo "Error: KUBERNETES_SERVICE_HOST is not set. This does not look like" >&2
    echo "a pod running with a Kubernetes ServiceAccount." >&2
    exit 1
fi
if [[ ! -f "$token_file" ]]; then
    echo "Error: ServiceAccount token not found at $token_file." >&2
    exit 1
fi
if [[ ! -f "$ca_file" ]]; then
    echo "Error: ServiceAccount CA not found at $ca_file." >&2
    exit 1
fi

api_host="$KUBERNETES_SERVICE_HOST"
[[ "$api_host" == *:* ]] && api_host="[$api_host]"
api_port="${KUBERNETES_SERVICE_PORT:-443}"

# Double-quoted YAML scalar: escape backslash and double-quote so a context
# name carrying either (unlikely, but names ride in from k8s.env) cannot
# break out of the quoted string.
yaml_dq() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}
context_q="$(yaml_dq "$k8s_context")"

kube_dir="$HOME/.kube"
mkdir -p "$kube_dir"
kubeconfig="$kube_dir/config"
tmp="$kubeconfig.part"
: > "$tmp"
chmod 0600 -- "$tmp"
cat >> "$tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://${api_host}:${api_port}
    certificate-authority: ${ca_file}
users:
- name: postmaster
  user:
    tokenFile: ${token_file}
contexts:
- name: "${context_q}"
  context:
    cluster: in-cluster
    user: postmaster
    namespace: ${k8s_namespace}
current-context: "${context_q}"
EOF
mv -- "$tmp" "$kubeconfig"

# --- 4. ssh ---------------------------------------------------------------

git_secret_dir="${FORK_SANDBOX_GIT_SECRET_DIR:-/etc/fork-sandbox/git}"
mounted_key="$git_secret_dir/deploy-key"
mounted_known_hosts="$git_secret_dir/known_hosts"

if [[ ! -f "$mounted_key" ]]; then
    echo "Error: deploy key not found at $mounted_key." >&2
    exit 1
fi
if [[ ! -f "$mounted_known_hosts" ]]; then
    echo "Error: known_hosts not found at $mounted_known_hosts." >&2
    exit 1
fi

ssh_dir="$HOME/.ssh"
mkdir -p "$ssh_dir"

deploy_key="$ssh_dir/deploy-key"
tmp="$deploy_key.part"
: > "$tmp"
chmod 0600 -- "$tmp"
cat -- "$mounted_key" >> "$tmp"
mv -- "$tmp" "$deploy_key"

known_hosts="$ssh_dir/known_hosts"
tmp="$known_hosts.part"
: > "$tmp"
chmod 0644 -- "$tmp"
cat -- "$mounted_known_hosts" >> "$tmp"
mv -- "$tmp" "$known_hosts"

export GIT_SSH_COMMAND="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts"

# --- 5. repo ----------------------------------------------------------

src_dir="$HOME/src"
mkdir -p "$src_dir"
repo_dir="$src_dir/$project"

if [[ -d "$repo_dir/.git" ]]; then
    if git -C "$repo_dir" fetch --prune origin; then
        if ! git -C "$repo_dir" merge --ff-only '@{u}' >/dev/null 2>&1; then
            echo "Warning: could not fast-forward $repo_dir to its upstream" >&2
            echo "(diverged?); continuing with what is already on disk." >&2
        fi
    else
        echo "Warning: fetch failed for existing clone at $repo_dir;" >&2
        echo "continuing with what is already on disk." >&2
    fi
else
    git clone "$repo_url" "$repo_dir"
fi

# --- 6. hand off to the postmaster ----------------------------------------

pm_bin="${FORK_SANDBOX_POSTMASTER_BIN:-$script_dir/fork-sandbox-postmaster.sh}"
exec "$pm_bin" deliver --cluster --project "$repo_dir"
