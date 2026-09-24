#!/usr/bin/env bash
# fork-sandbox-postmaster-pod-init-test.sh -- pod init: kubeconfig from the
# ServiceAccount, deploy-key install, clone-or-fetch, and the final exec
# into the postmaster
#
# Usage: tests/fork-sandbox-postmaster-pod-init-test.sh
#
# Runs entirely offline: stub git/ssh/kubectl on PATH (git is a functional
# fake that creates/records what a real clone or fetch would do; ssh and
# kubectl only need to exist for the tool self-check) and a stub postmaster
# binary (FORK_SANDBOX_POSTMASTER_BIN) that records its argv and the
# GIT_SSH_COMMAND it inherited instead of actually running. Never touches a
# real cluster, a real key, or this repo's own git history.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
script="$repo_dir/scripts/fork-sandbox-postmaster-pod-init.sh"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
refuses() {
    local label="$1" needle="$2" out rc; shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$needle"* ]]; then ok "$label"; else no "$label" "status $rc: $out"; fi
}
newdir() { mktemp -d; }

# A full, working stub toolset, standing in for the entire PATH (not just
# an addition to the test host's PATH -- otherwise the "missing tool"
# case below could never truly hide a tool the host actually has). Every
# external command pod-init or its shebang needs, symlinked from whatever
# the test host actually has: bash itself (env resolves it from PATH even
# though env's own absolute path comes from the shebang line), the few
# coreutils pod-init calls directly, and flock/setsid/python3/tar for the
# self-check (their behavior is never exercised, only their presence).
# git/ssh/kubectl are fakes: git records every invocation to $GIT_LOG and
# either fakes a clone (mkdir the .git dir) or a fetch, each failable via
# GIT_CLONE_FAIL/GIT_FETCH_FAIL; ssh/kubectl are no-ops (pod-init itself
# never execs either -- it only needs them to exist for the self-check,
# and to build the GIT_SSH_COMMAND string).
full_tools="$(newdir)"; tmpdirs+=("$full_tools")
for t in bash dirname readlink mkdir chmod cat mv sed ln id flock setsid python3 tar; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$full_tools/$t"
done
cat > "$full_tools/git" <<'EOF'
#!/usr/bin/env bash
[[ -n "${GIT_LOG:-}" ]] && printf '%s\n' "$*" >> "$GIT_LOG"
case "$1" in
    clone)
        if [[ -n "${GIT_CLONE_FAIL:-}" ]]; then
            echo "stub git: clone failed" >&2
            exit 1
        fi
        mkdir -p "$3/.git"
        exit 0
        ;;
    -C)
        case "$3" in
            fetch)
                if [[ -n "${GIT_FETCH_FAIL:-}" ]]; then
                    echo "stub git: fetch failed" >&2
                    exit 1
                fi
                exit 0
                ;;
            merge)
                if [[ -n "${GIT_MERGE_FAIL:-}" ]]; then
                    echo "stub git: merge failed" >&2
                    exit 1
                fi
                exit 0
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$full_tools/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$full_tools/ssh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$full_tools/kubectl"
chmod +x "$full_tools/ssh" "$full_tools/kubectl"

# One fresh HOME + config dir + fake ServiceAccount dir + fake mounted
# git secret dir + stub postmaster binary per test, so tests never share
# mutable state.
setup_env() {
    home="$(newdir)"; tmpdirs+=("$home")
    config_dir="$home/cfg"; mkdir -p "$config_dir"
    sa_dir="$home/sa"; mkdir -p "$sa_dir"
    printf 'fake-token\n' > "$sa_dir/token"
    printf 'fake-ca\n' > "$sa_dir/ca.crt"
    data_dir="$home/data"; mkdir -p "$data_dir/agent-mail"
    secret_dir="$home/git-secret"; mkdir -p "$secret_dir"
    printf 'FAKE PRIVATE KEY\n' > "$secret_dir/deploy-key"
    printf 'git.example ssh-ed25519 FAKEHOSTKEY\n' > "$secret_dir/known_hosts"
    pm_record="$home/pm-argv.txt"
    pm_env_record="$home/pm-env.txt"
    cat > "$home/pm" <<EOF
#!/usr/bin/env bash
: > "$pm_record"
for a in "\$@"; do printf '%s\n' "\$a" >> "$pm_record"; done
printf 'GIT_SSH_COMMAND=%s\n' "\${GIT_SSH_COMMAND:-}" > "$pm_env_record"
exit 0
EOF
    chmod +x "$home/pm"
    git_log="$home/git-log.txt"
}

write_k8s_env() {
    cat > "$config_dir/k8s.env"
}

run_init() {
    local tools="${PI_TOOLS:-$full_tools}"
    HOME="$home" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    FORK_SANDBOX_SA_DIR="$sa_dir" \
    FORK_SANDBOX_PM_DATA_DIR="$data_dir" \
    FORK_SANDBOX_GIT_SECRET_DIR="$secret_dir" \
    FORK_SANDBOX_POSTMASTER_BIN="$home/pm" \
    KUBERNETES_SERVICE_HOST="${TEST_K8S_HOST:-198.51.100.10}" \
    KUBERNETES_SERVICE_PORT="${TEST_K8S_PORT:-443}" \
    GIT_LOG="$git_log" \
    GIT_CLONE_FAIL="${TEST_GIT_CLONE_FAIL:-}" \
    GIT_FETCH_FAIL="${TEST_GIT_FETCH_FAIL:-}" \
    GIT_MERGE_FAIL="${TEST_GIT_MERGE_FAIL:-}" \
    PATH="$tools" \
    "$script" "$@"
}

printf '\n== --help ==\n'
setup_env
if run_init --help 2>&1 | grep -q "fork-sandbox-postmaster-pod-init.sh"; then
    ok "--help prints the header"
else
    no "--help prints the header"
fi

printf '\n== missing tool refuses, naming it ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
no_tar="$(newdir)"; tmpdirs+=("$no_tar")
for f in "$full_tools"/*; do
    [[ "$(basename "$f")" == tar ]] && continue
    cp -P "$f" "$no_tar/"
done
PI_TOOLS="$no_tar" refuses "missing tar refuses, naming it" "tar" run_init

printf '\n== config validation refuses before any git call ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=https://example.com/not-ssh.git
EOF
refuses "non-ssh URL refuses" "not a recognized ssh URL" run_init
check "bad URL: git never called" "" "$([[ -f "$git_log" ]] && cat "$git_log" || true)"

setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
K8S_POSTMASTER_PROJECT=../evil
EOF
refuses "bad project name refuses" "not a valid directory name" run_init
check "bad project: git never called" "" "$([[ -f "$git_log" ]] && cat "$git_log" || true)"

setup_env
write_k8s_env <<'EOF'
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
refuses "missing K8S_CONTEXT refuses" "K8S_CONTEXT not set" run_init

setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
EOF
refuses "missing K8S_POSTMASTER_REPO_URL refuses" "K8S_POSTMASTER_REPO_URL not set" run_init

printf '\n== kubeconfig content ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=user@my-cluster/context
K8S_NAMESPACE=review-panel
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
kubeconfig="$home/.kube/config"
if [[ -f "$kubeconfig" ]]; then
    ok "kubeconfig written"
else
    no "kubeconfig written"
fi
check "kubeconfig mode is 0600" "600" "$(stat -c '%a' "$kubeconfig" 2>/dev/null)"
if grep -qF 'name: "user@my-cluster/context"' "$kubeconfig"; then
    ok "context name (with @ and /) is quoted in the YAML"
else
    no "context name (with @ and /) is quoted in the YAML" "$(cat "$kubeconfig")"
fi
if grep -qF 'current-context: "user@my-cluster/context"' "$kubeconfig"; then
    ok "current-context matches the quoted context name"
else
    no "current-context matches the quoted context name" "$(cat "$kubeconfig")"
fi
if grep -qF "tokenFile: $sa_dir/token" "$kubeconfig"; then
    ok "tokenFile is a path, not inline"
else
    no "tokenFile is a path, not inline" "$(cat "$kubeconfig")"
fi
if grep -q 'fake-token' "$kubeconfig"; then
    no "token contents never appear in the kubeconfig" "$(cat "$kubeconfig")"
else
    ok "token contents never appear in the kubeconfig"
fi
if grep -qF 'namespace: review-panel' "$kubeconfig"; then
    ok "namespace from K8S_NAMESPACE"
else
    no "namespace from K8S_NAMESPACE" "$(cat "$kubeconfig")"
fi

printf '\n== K8S_NAMESPACE defaults to fork-sandbox ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
if grep -qF 'namespace: fork-sandbox' "$home/.kube/config"; then
    ok "default namespace is fork-sandbox"
else
    no "default namespace is fork-sandbox" "$(cat "$home/.kube/config")"
fi

printf '\n== IPv6 API host is bracketed ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
TEST_K8S_HOST='2001:db8::1' run_init >/dev/null 2>&1
if grep -qF 'server: https://[2001:db8::1]:443' "$home/.kube/config"; then
    ok "IPv6 host is bracketed"
else
    no "IPv6 host is bracketed" "$(cat "$home/.kube/config")"
fi

printf '\n== ssh key install ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
check "deploy key mode is 0600" "600" "$(stat -c '%a' "$home/.ssh/deploy-key" 2>/dev/null)"
check "known_hosts mode is 0644" "644" "$(stat -c '%a' "$home/.ssh/known_hosts" 2>/dev/null)"
check "deploy key content copied" "FAKE PRIVATE KEY" "$(cat "$home/.ssh/deploy-key")"

printf '\n== clone when absent, fetch when present ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
if grep -q '^clone ' "$git_log"; then
    ok "absent repo: git clone is called"
else
    no "absent repo: git clone is called" "$(cat "$git_log")"
fi
check "clone target defaults from the URL's last path component" \
    "clone ssh://git.example/proj.git $home/src/proj" "$(grep '^clone ' "$git_log")"

setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
mkdir -p "$data_dir/.pm-home/src/proj/.git"
run_init >/dev/null 2>&1
if grep -q '^-C .*fetch' "$git_log"; then
    ok "present repo: git fetch is called instead of clone"
else
    no "present repo: git fetch is called instead of clone" "$(cat "$git_log")"
fi
if grep -q '^clone ' "$git_log"; then
    no "present repo: git clone is NOT called" "$(cat "$git_log")"
else
    ok "present repo: git clone is NOT called"
fi
if grep -q '^-C .*merge --ff-only @{u}' "$git_log"; then
    ok "present repo: a successful fetch fast-forwards to its upstream"
else
    no "present repo: a successful fetch fast-forwards to its upstream" "$(cat "$git_log")"
fi

printf '\n== a diverged branch (ff-only fails) warns and continues ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
mkdir -p "$data_dir/.pm-home/src/proj/.git"
out="$(TEST_GIT_MERGE_FAIL=1 run_init 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"Warning"*"fast-forward"* ]]; then
    ok "a clone whose local branch diverged from origin warns and exits 0"
else
    no "a clone whose local branch diverged from origin warns and exits 0" "status $rc: $out"
fi

printf '\n== failed fetch warns and continues; failed clone is fatal ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
mkdir -p "$data_dir/.pm-home/src/proj/.git"
out="$(TEST_GIT_FETCH_FAIL=1 run_init 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"Warning"* ]]; then
    ok "failed fetch on an existing clone warns and exits 0"
else
    no "failed fetch on an existing clone warns and exits 0" "status $rc: $out"
fi

setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
out="$(TEST_GIT_CLONE_FAIL=1 run_init 2>&1)"
rc=$?
if (( rc != 0 )) && [[ "$out" == *"clone failed"* ]]; then
    ok "failed clone exits non-zero"
else
    no "failed clone exits non-zero" "status $rc: $out"
fi

printf '\n== final exec and inherited environment ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
check "exec argv is deliver --cluster --project <path>" \
    "$(printf 'deliver\n--cluster\n--project\n%s/src/proj\n' "$home")" "$(cat "$pm_record" 2>/dev/null)"
if grep -qF "GIT_SSH_COMMAND=ssh -i $home/.ssh/deploy-key" "$pm_env_record" 2>/dev/null; then
    ok "GIT_SSH_COMMAND is inherited by the postmaster"
else
    no "GIT_SSH_COMMAND is inherited by the postmaster" "$(cat "$pm_env_record" 2>/dev/null)"
fi

printf '\n== scp-like URL is accepted ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=git@git.example:team/proj.git
K8S_POSTMASTER_PROJECT=proj
EOF
if run_init >/tmp/pi-test-out.log 2>&1; then
    ok "scp-like URL (user@host:path) is accepted"
else
    no "scp-like URL (user@host:path) is accepted" "$(cat /tmp/pi-test-out.log)"
fi
rm -f /tmp/pi-test-out.log

printf '\n== scp-like root-level URL derives a project with no explicit K8S_POSTMASTER_PROJECT ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=git@git.example:proj.git
EOF
run_init >/tmp/pi-test-out.log 2>&1
rc=$?
if (( rc == 0 )); then
    ok "scp-like root-level URL (user@host:proj.git), no explicit project: accepted"
else
    no "scp-like root-level URL (user@host:proj.git), no explicit project: accepted" \
        "$(cat /tmp/pi-test-out.log)"
fi
check "derived project name is 'proj', not 'git@git.example:proj'" \
    "clone git@git.example:proj.git $home/src/proj" "$(grep '^clone ' "$git_log")"
rm -f /tmp/pi-test-out.log

printf '\n== state directories: home links onto the data volume ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
run_init >/dev/null 2>&1
rc=$?
check "fresh run exits 0" "0" "$rc"
check "\$HOME/src links to the data volume" "$data_dir/.pm-home/src" "$(readlink "$home/src" 2>/dev/null)"
check "\$HOME/.claude links to the data volume" "$data_dir/.pm-home/claude" "$(readlink "$home/.claude" 2>/dev/null)"
if [[ -d "$data_dir/.pm-home/src" && -d "$data_dir/.pm-home/claude" ]]; then
    ok "both link targets exist"
else
    no "both link targets exist" "$(ls -la "$data_dir/.pm-home" 2>&1)"
fi
if [[ -d "$data_dir/.pm-home/src/proj/.git" ]]; then
    ok "the clone lands on the data volume"
else
    no "the clone lands on the data volume" "$(find "$data_dir" 2>&1)"
fi

printf '\n== a container restart (same HOME and data dir) keeps the links ==\n'
out="$(run_init 2>&1)"
rc=$?
check "second run exits 0" "0" "$rc"
[[ "$rc" == 0 ]] || printf '        %s\n' "$out"
check "second run: \$HOME/src still links to the same target" "$data_dir/.pm-home/src" "$(readlink "$home/src" 2>/dev/null)"
check "second run: \$HOME/.claude still links to the same target" "$data_dir/.pm-home/claude" "$(readlink "$home/.claude" 2>/dev/null)"
if [[ -e "$data_dir/.pm-home/src/src" || -L "$data_dir/.pm-home/src/src" ]]; then
    no "second run: no link nested inside the src target"
else
    ok "second run: no link nested inside the src target"
fi
if [[ -e "$data_dir/.pm-home/claude/claude" || -L "$data_dir/.pm-home/claude/claude" ]]; then
    no "second run: no link nested inside the claude target"
else
    ok "second run: no link nested inside the claude target"
fi

printf '\n== a real directory at a link path is refused ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
mkdir -p "$home/src"
refuses "real \$HOME/src directory refuses, naming it" "$home/src" run_init
check "real \$HOME/src: git never called" "" "$([[ -f "$git_log" ]] && cat "$git_log" || true)"

setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
mkdir -p "$home/.claude"
refuses "real \$HOME/.claude directory refuses, naming it" "$home/.claude" run_init

printf '\n== unwritable data volume or mail mount point is refused ==\n'
setup_env
write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
rmdir "$data_dir/agent-mail"
refuses "missing agent-mail refuses, naming it" "$data_dir/agent-mail" run_init

if (( $(id -u) == 0 )); then
    printf '  note  running as root: skipping the non-writable data dir case\n'
else
    setup_env
    write_k8s_env <<'EOF'
K8S_CONTEXT=my-context
K8S_POSTMASTER_REPO_URL=ssh://git.example/proj.git
EOF
    chmod 0555 "$data_dir"
    refuses "non-writable data dir refuses, naming it" "$data_dir is not writable" run_init
    chmod 0755 "$data_dir"
fi

printf '\n%d ok / %d fail\n' "$pass" "$fail"
(( fail == 0 ))
