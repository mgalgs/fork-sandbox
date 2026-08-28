#!/usr/bin/env bash
# fork-sandbox-k8s-entrypoint.sh -- the agent pod's main container
#
# Shipped in via a ConfigMap rather than baked into the image, so iterating
# on it needs no rebuild and no registry push. Invoked as
# `bash fork-sandbox-k8s-entrypoint.sh`, after the egress-gate initContainer
# has already verified the pod's network is sealed the way the platform
# claims. Env is set by the Job spec fork-sandbox-k8s.sh renders.
#
# The repository arrives by PUSH, not by cloning a remote: the client pushes
# it into this pod over the same `kubectl exec` channel the work returns on
# (`git push "ext::kubectl exec -i POD -- git-receive-pack /work/repo.git"`).
# So this script never dials out for the repo, no git remote or credential
# is ever named inside the pod, and egress can stay sealed to the proxy and
# DNS alone.
#
# What follows is the two-phase start every gated input in this project
# uses: wait for a sentinel written LAST, fail closed on a deadline. A
# client that dies mid-push must not become an agent running with a
# half-received repository, so a missing sentinel by the deadline is a
# failure here, not a green light to proceed with whatever arrived.
#
# Env:
#   BRANCH          the branch name the agent's commits land on. Required.
#   MODEL           the OpenRouter model id pi should use. Required.
#   PROXY_BASE_URL  the model proxy's base URL, e.g.
#                   http://fork-sandbox-proxy.NS.svc.cluster.local:8080/api/v1
#                   Required.
#   GIT_USER_NAME, GIT_USER_EMAIL
#                   the identity commits land under. Default to a fixed
#                   fork-sandbox identity when unset -- there is no host
#                   gitconfig to inherit inside a pod.
#   INPUTS_TIMEOUT  seconds to wait for the repository push. Default 300.
#   RUN_TTL         seconds to idle after the agent exits, so the clone is
#                   still there when the client fetches. Default 3600.
#
# Reads from /mnt/fork-sandbox/ (the scripts ConfigMap, mounted read-only):
#   handoff.md              the run's whole prompt, on pi's stdin.
#   pi-agent-settings.json  optional; this repo's pi-agent/settings.json,
#                           the same file agent-sandboxed seeds a sealed
#                           local run's ~/.pi/agent from. Only the
#                           defaultProvider/defaultModel keys are generated
#                           fresh here; everything else in it survives.
#
# Creates /work/inbox: the operator inbox, written to from outside the pod
# by `fork-sandbox-k8s.sh say` over kubectl exec, and read by the agent per
# the preamble fs_emit_prompt_preamble renders into handoff.md. It is a
# sibling of clone_dir, never a descendant of it, so the `git add -A` this
# script runs at the bottom -- scoped to clone_dir, the repository it is run
# in -- can never sweep an addendum into a commit.

set -euo pipefail

: "${BRANCH:?BRANCH must be set to the branch the agent commits on}"
: "${MODEL:?MODEL must be set to an OpenRouter model id}"
: "${PROXY_BASE_URL:?PROXY_BASE_URL must be set to the model proxy base URL}"
: "${GIT_USER_NAME:=fork-sandbox agent}"
: "${GIT_USER_EMAIL:=agent@fork-sandbox.invalid}"
: "${INPUTS_TIMEOUT:=300}"
: "${RUN_TTL:=3600}"

mounts_dir=/mnt/fork-sandbox
work_dir=/work
repo_bare="$work_dir/repo.git"
clone_dir="$work_dir/clone"
inbox_dir="$work_dir/inbox"
sentinel="$work_dir/.inputs-complete"
fetched_marker="$work_dir/.fetched"
run_complete="$work_dir/.run-complete"

echo "fork-sandbox-k8s-entrypoint: creating $inbox_dir" >&2
mkdir -p "$inbox_dir"

echo "fork-sandbox-k8s-entrypoint: initializing $repo_bare" >&2
git init --quiet --bare "$repo_bare"

echo "fork-sandbox-k8s-entrypoint: waiting for $sentinel (deadline ${INPUTS_TIMEOUT}s)" >&2
deadline=$(( $(date +%s) + INPUTS_TIMEOUT ))
until [[ -f "$sentinel" ]]; do
    if (( $(date +%s) >= deadline )); then
        echo "Error: timed out waiting for the repository to arrive -- no" >&2
        echo "$sentinel after ${INPUTS_TIMEOUT}s. A client that died mid-push" >&2
        echo "must not become an agent running with its inputs missing, so" >&2
        echo "this run fails closed instead of proceeding on a partial repo." >&2
        exit 1
    fi
    sleep 1
done

echo "fork-sandbox-k8s-entrypoint: cloning to $clone_dir" >&2
git clone --quiet "$repo_bare" "$clone_dir"
cd "$clone_dir"
git checkout --quiet -b "$BRANCH"
git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
git config commit.gpgsign false
git config tag.gpgsign false

echo "fork-sandbox-k8s-entrypoint: synthesizing pi config" >&2
mkdir -p "$HOME/.pi/agent"
if [[ -f "$mounts_dir/pi-agent-settings.json" ]]; then
    cp "$mounts_dir/pi-agent-settings.json" "$HOME/.pi/agent/settings.json"
fi

# baseUrl is the proxy Service, not a loopback bridge -- there is no socket
# bridge here, because network policy rather than a unix socket is what
# seals this pod. apiKey is a placeholder; the proxy replaces the header on
# the way past, so this value is never sent anywhere that checks it.
jq -n --arg base "$PROXY_BASE_URL" --arg model "$MODEL" '
    {
        providers: {
            proxy: {
                baseUrl: $base,
                api: "openai-completions",
                apiKey: "sandbox",
                models: [{
                    id: $model,
                    name: ($model + " (proxy)"),
                    reasoning: true,
                    input: ["text"],
                    contextWindow: 131072,
                    maxTokens: 32768,
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                }],
            },
        },
    }' > "$HOME/.pi/agent/models.json"

settings_base='{}'
if [[ -f "$HOME/.pi/agent/settings.json" ]]; then
    settings_base="$(cat "$HOME/.pi/agent/settings.json")"
fi
if ! jq -n --argjson base "$settings_base" --arg model "$MODEL" \
    '$base * { defaultProvider: "proxy", defaultModel: $model }' \
    > "$HOME/.pi/agent/settings.json.new"; then
    echo "Error: pi-agent/settings.json is not valid JSON, so the generated" >&2
    echo "model defaults cannot be merged into it." >&2
    exit 1
fi
mv "$HOME/.pi/agent/settings.json.new" "$HOME/.pi/agent/settings.json"

echo "fork-sandbox-k8s-entrypoint: running pi" >&2
pi_rc=0
pi --provider proxy --model "$MODEL" --mode json -p \
    < "$mounts_dir/handoff.md" \
    > "$work_dir/events.jsonl" \
    2> "$work_dir/pi-stderr.log" \
    || pi_rc=$?
echo "fork-sandbox-k8s-entrypoint: pi exited $pi_rc" >&2

if [[ -n "$(git status --porcelain)" ]]; then
    echo "fork-sandbox-k8s-entrypoint: committing work the agent left uncommitted" >&2
    git add -A
    git commit --quiet -m "fork-sandbox: commit uncommitted work at run end"
fi

printf '%s\n' "$pi_rc" > "$run_complete"

echo "fork-sandbox-k8s-entrypoint: idling up to ${RUN_TTL}s for the fetch" >&2
idle_deadline=$(( $(date +%s) + RUN_TTL ))
while [[ ! -f "$fetched_marker" ]] && (( $(date +%s) < idle_deadline )); do
    sleep 5
done

exit "$pi_rc"
