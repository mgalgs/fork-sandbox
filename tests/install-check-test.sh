#!/usr/bin/env bash
# install-check-test.sh — Exercise install.sh --check's cluster reporting.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle'" ;;
    esac
}

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect '$needle'" ;;
        *) ok "$label" ;;
    esac
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

fake_bin="$scratch/bin"
mkdir -p "$fake_bin"

# Keep the check independent of the host's local-backend installation. The
# cluster-reporting assertions below should not fail just because this host
# lacks bwrap, pasta, jq, or a particular GNU coreutils spelling.
cat > "$fake_bin/dependency-stub" <<'EOF'
#!/usr/bin/env bash
case "${0##*/}" in
    grealpath|gstat|gtimeout|realpath|stat|timeout)
        if [[ "${1:-}" == --version ]]; then
            echo "GNU coreutils test stub"
        elif [[ "${0##*/}" == gtimeout || "${0##*/}" == timeout ]]; then
            shift
            exec "$@"
        fi
        ;;
esac
EOF
chmod 755 "$fake_bin/dependency-stub"
for tool in git jq bwrap pasta docker flock realpath stat gtimeout; do
    ln -s dependency-stub "$fake_bin/$tool"
done

cat > "$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "version --client" ]]; then
    echo "Client Version: test"
elif [[ "$*" == "config get-contexts -o name" ]]; then
    if [[ -n "${FAKE_CONTEXTS:-}" ]]; then
        printf '%s\n' "$FAKE_CONTEXTS"
    fi
fi
EOF
chmod 755 "$fake_bin/kubectl"

run_check() {
    local name="$1" contents="$2" config_dir="$scratch/$1" output rc
    mkdir -p "$config_dir"
    if [[ -n "$contents" ]]; then
        printf '%s' "$contents" > "$config_dir/k8s.env"
    fi
    output="$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        FAKE_CONTEXTS='' "$repo_dir/install.sh" --check 2>&1)"
    rc=$?
    printf '%s\n' "$output"
    check_rc "$name exits 0" 0 "$rc"
    RUN_OUTPUT="$output"
}

check_rc() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected $expected, got $actual"; fi
}

echo "== cluster key reporting =="

run_check absent ''
contains "absent k8s.env is reported" "k8s.env: not present" "$RUN_OUTPUT"

run_check complete $'K8S_CONTEXT=kind\nK8S_IMAGE=registry.example/sandbox:v1\n'
contains "context is reported set" "K8S_CONTEXT: set" "$RUN_OUTPUT"
contains "image is reported set" "K8S_IMAGE: set" "$RUN_OUTPUT"
contains "namespace defaults" "K8S_NAMESPACE: fork-sandbox (default)" "$RUN_OUTPUT"

run_check image-missing $'K8S_CONTEXT=kind\n'
contains "missing image is obvious" "K8S_IMAGE: MISSING" "$RUN_OUTPUT"
check_rc "missing image does not gate check" 0 "$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/image-missing" FAKE_CONTEXTS='' "$repo_dir/install.sh" --check >/dev/null 2>&1; echo $?)"

run_check context-empty $'K8S_CONTEXT=\nK8S_IMAGE=image\n'
contains "empty context is missing" "K8S_CONTEXT: MISSING" "$RUN_OUTPUT"
check_rc "empty context does not gate check" 0 "$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$scratch/context-empty" FAKE_CONTEXTS='' "$repo_dir/install.sh" --check >/dev/null 2>&1; echo $?)"

run_check equals $'K8S_CONTEXT=kind\nK8S_IMAGE=image\nK8S_NAMESPACE=registry.example/path=tag\n'
contains "value after the first equals survives" "K8S_NAMESPACE: registry.example/path=tag" "$RUN_OUTPUT"

run_check commented $'#K8S_IMAGE=commented\nK8S_CONTEXT=kind\n'
contains "commented image does not count" "K8S_IMAGE: MISSING" "$RUN_OUTPUT"

run_check namespace-set $'K8S_CONTEXT=kind\nK8S_IMAGE=image\nK8S_NAMESPACE=team-sandbox\n'
contains "namespace value is reported" "K8S_NAMESPACE: team-sandbox" "$RUN_OUTPUT"
lacks "namespace is not reported missing" "K8S_NAMESPACE: MISSING" "$RUN_OUTPUT"

context_dir="$scratch/context-known"
mkdir -p "$context_dir"
printf '%s\n' 'K8S_CONTEXT=kind' 'K8S_IMAGE=image' > "$context_dir/k8s.env"
known_output="$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$context_dir" \
    FAKE_CONTEXTS=$'other\nkind' "$repo_dir/install.sh" --check 2>&1)"
known_rc=$?
check_rc "known context check exits 0" 0 "$known_rc"
contains "known context is reported" "K8S_CONTEXT: kind (found in this machine's kubeconfig)" "$known_output"

unknown_output="$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$context_dir" \
    FAKE_CONTEXTS=other "$repo_dir/install.sh" --check 2>&1)"
unknown_rc=$?
check_rc "unknown context check exits 0" 0 "$unknown_rc"
contains "unknown context is reported" "is not in this machine's kubeconfig" "$unknown_output"

empty_output="$(PATH="$fake_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$context_dir" \
    FAKE_CONTEXTS='' "$repo_dir/install.sh" --check 2>&1)"
empty_rc=$?
check_rc "empty context check exits 0" 0 "$empty_rc"
contains "empty kubeconfig reports unknown context" "is not in this machine's kubeconfig" "$empty_output"

printf '\n%d ok / %d fail\n' "$pass" "$fail"
(( fail == 0 ))
