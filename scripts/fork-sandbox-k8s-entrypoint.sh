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
#   HARNESS         "pi" or "claude", the coding leg's harness. Default
#                   "pi". The review loop, when it runs, always runs pi
#                   regardless of this -- see REVIEW_MODEL below.
#   MODEL           the model id the coding leg's harness should use: an
#                   OpenRouter id for pi, a Claude Code model name for
#                   claude. Required.
#   PROXY_BASE_URL  the pi model proxy's base URL, e.g.
#                   http://fork-sandbox-proxy.NS.svc.cluster.local:8080/api/v1
#                   Required regardless of HARNESS -- the review loop
#                   always needs it, even on a claude coding leg.
#   CLAUDE_PROXY_BASE_URL
#                   the base URL of the per-run proxy that swaps the
#                   placeholder credential below for the operator's real
#                   token, a Service DNS name at port 8080. Required when
#                   HARNESS=claude; unused otherwise.
#   GIT_USER_NAME, GIT_USER_EMAIL
#                   the identity commits land under. Default to a fixed
#                   fork-sandbox identity when unset -- there is no host
#                   gitconfig to inherit inside a pod.
#   INPUTS_TIMEOUT  seconds to wait for the repository push. Default 300.
#   RUN_TTL         seconds to idle after the agent exits, so the clone is
#                   still there when the client fetches. Default 3600.
#   REVIEW_LOOP_CAP the maximum review-then-fix iterations to run after the
#                   coding leg, for fork-sandbox-k8s.sh's --review-loop.
#                   Default 0 (no loop). Set by fork-sandbox-k8s.sh's
#                   `submit` only when --review-loop was given.
#   BASE_SHA        the commit the branch is measured against, for the
#                   review loop's commit range. Required when
#                   REVIEW_LOOP_CAP is set; unused otherwise.
#   REVIEW_MODEL    the OpenRouter model id the review loop's pi runs
#                   should use, when it differs from MODEL. Required when
#                   HARNESS=claude and REVIEW_LOOP_CAP is set, since
#                   MODEL is then a Claude Code model name pi cannot use.
#                   Optional otherwise; the review loop falls back to
#                   MODEL when unset.
#   OUTBOX_MAX_BYTES the outbox size cap, in bytes, for the end-of-run
#                   warning below. Default 67108864 (64 MiB) -- must match
#                   FS_OUTBOX_MAX_BYTES in fork-sandbox-lib.sh; nothing
#                   enforces the two staying equal, since this script does
#                   not source that file. Set by fork-sandbox-k8s.sh's
#                   `submit` to the effective value (default, or raised by
#                   --outbox-max).
#
# Reads from /mnt/fork-sandbox/ (the scripts ConfigMap, mounted read-only):
#   handoff.md              the run's whole prompt, on the coding harness's
#                           stdin.
#   pi-agent-settings.json  optional; this repo's pi-agent/settings.json,
#                           the same file agent-sandboxed seeds a sealed
#                           local run's ~/.pi/agent from. Only the
#                           defaultProvider/defaultModel keys are generated
#                           fresh here; everything else in it survives.
#   claude-credentials.json, inbox-hook.sh
#                           present only when HARNESS=claude. The former is
#                           the operator's own credential with the access
#                           token replaced by a placeholder (the per-run
#                           proxy swaps in the real one); the latter is
#                           this repo's own operator-inbox hook, installed
#                           and registered exactly as a local claude run's
#                           --settings does.
#   review-prompt.md, fix-prompt-header.md, code-review-portable-skill.md,
#   review-loop.sh          present only when REVIEW_LOOP_CAP is set. The
#                           first two are the review and fix leg prompts,
#                           fully rendered on the HOST by
#                           fork-sandbox-k8s.sh (fs_emit_review_prompt_body /
#                           fs_emit_fix_prompt_body in fork-sandbox-lib.sh) --
#                           this script never composes prompt text of its
#                           own. review-loop.sh is the loop's own control
#                           flow; see its header for why it is a separate
#                           script.
#
# Creates /work/inbox: the operator inbox, written to from outside the pod
# by `fork-sandbox-k8s.sh say` over kubectl exec, and read by the agent per
# the preamble fs_emit_prompt_preamble renders into handoff.md. It is a
# sibling of clone_dir, never a descendant of it, so the `git add -A` this
# script runs at the bottom -- scoped to clone_dir, the repository it is run
# in -- can never sweep an addendum into a commit. /work/skills, created
# below when a review skill is shipped, is a sibling for the identical
# reason.
#
# Also creates /work/outbox: the artifact outbox, read back out of the pod
# by `fork-sandbox-k8s.sh run` over kubectl exec once the agent finishes.
# Same sibling-of-clone_dir reasoning as /work/inbox above.

set -euo pipefail

: "${BRANCH:?BRANCH must be set to the branch the agent commits on}"
: "${HARNESS:=pi}"
case "$HARNESS" in
    pi|claude) ;;
    *)
        echo "Error: HARNESS must be 'pi' or 'claude', got '$HARNESS'." >&2
        exit 1
        ;;
esac
: "${MODEL:?MODEL must be set to a model id}"
: "${PROXY_BASE_URL:?PROXY_BASE_URL must be set to the pi model proxy base URL}"
if [[ "$HARNESS" == claude ]]; then
    : "${CLAUDE_PROXY_BASE_URL:?CLAUDE_PROXY_BASE_URL must be set when HARNESS=claude}"
fi
: "${GIT_USER_NAME:=fork-sandbox agent}"
: "${GIT_USER_EMAIL:=agent@fork-sandbox.invalid}"
: "${INPUTS_TIMEOUT:=300}"
: "${RUN_TTL:=3600}"
: "${REVIEW_LOOP_CAP:=0}"
: "${REVIEW_MODEL:=}"
: "${OUTBOX_MAX_BYTES:=67108864}"  # must match FS_OUTBOX_MAX_BYTES in fork-sandbox-lib.sh
if [[ "$REVIEW_LOOP_CAP" =~ ^[1-9][0-9]*$ ]]; then
    : "${BASE_SHA:?BASE_SHA must be set when REVIEW_LOOP_CAP is set}"
    if [[ "$HARNESS" == claude && -z "$REVIEW_MODEL" ]]; then
        echo "Error: REVIEW_MODEL must be set when HARNESS=claude and" >&2
        echo "REVIEW_LOOP_CAP is set -- the review loop always runs pi, and" >&2
        echo "MODEL is a Claude Code model name pi cannot use." >&2
        exit 1
    fi
elif [[ "$REVIEW_LOOP_CAP" != "0" ]]; then
    echo "Error: REVIEW_LOOP_CAP must be a non-negative integer, got '$REVIEW_LOOP_CAP'." >&2
    exit 1
fi

mounts_dir=/mnt/fork-sandbox
work_dir=/work
repo_bare="$work_dir/repo.git"
clone_dir="$work_dir/clone"
inbox_dir="$work_dir/inbox"
outbox_dir="$work_dir/outbox"
skill_dir="$work_dir/skills/code-review-portable"
sentinel="$work_dir/.inputs-complete"
fetched_marker="$work_dir/.fetched"
run_complete="$work_dir/.run-complete"

echo "fork-sandbox-k8s-entrypoint: creating $inbox_dir" >&2
mkdir -p "$inbox_dir"
echo "fork-sandbox-k8s-entrypoint: creating $outbox_dir" >&2
mkdir -p "$outbox_dir"

# The review skill, staged only when this run carries one. A ConfigMap key
# cannot contain '/', so the skill arrives flattened at
# code-review-portable-skill.md and is placed here at the path the review
# prompt (rendered on the host, see fs_emit_review_prompt_body) names it at.
# /work/skills is a SIBLING of clone_dir, never a descendant of it -- the
# same structural reason /work/inbox above is a sibling -- so the
# `git add -A` this script runs at the bottom, scoped to clone_dir, can
# never sweep it into a commit.
if [[ -f "$mounts_dir/code-review-portable-skill.md" ]]; then
    echo "fork-sandbox-k8s-entrypoint: staging the review skill at $skill_dir" >&2
    mkdir -p "$skill_dir"
    cp "$mounts_dir/code-review-portable-skill.md" "$skill_dir/SKILL.md"
fi

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


# Only refs/heads/$BRANCH was ever pushed into this bare repo (cmd_submit
# pushes exactly "HEAD:refs/heads/$branch"), so the bare repo's default
# HEAD (refs/heads/main or master, set by git init --bare) dangles. Left
# alone, the clone below would print "warning: remote HEAD refers to
# nonexistent ref, unable to checkout" and check out nothing. Point HEAD at
# the branch that actually exists before cloning, so the clone lands
# directly on it.
git --git-dir="$repo_bare" symbolic-ref HEAD "refs/heads/$BRANCH"

echo "fork-sandbox-k8s-entrypoint: cloning to $clone_dir" >&2
git clone --quiet "$repo_bare" "$clone_dir"
cd "$clone_dir"
# The clone above already checked out $BRANCH as a local branch (HEAD now
# points there), so this only needs to switch onto it, not create it.
git checkout --quiet "$BRANCH"
git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
git config commit.gpgsign false
git config tag.gpgsign false

# Builds ~/.pi/agent/models.json + settings.json for a single model id,
# pointed at the pi proxy. Used for the pi harness's own coding leg below,
# and again (with REVIEW_MODEL) right before the review loop when the
# coding leg ran claude instead -- see that block for why a second call is
# needed there. baseUrl is the proxy Service, not a loopback bridge --
# there is no socket bridge here, because network policy rather than a
# unix socket is what seals this pod. apiKey is a placeholder; the proxy
# replaces the header on the way past, so this value is never sent
# anywhere that checks it.
synthesize_pi_config() {
    local model="$1"
    echo "fork-sandbox-k8s-entrypoint: synthesizing pi config for $model" >&2
    mkdir -p "$HOME/.pi/agent"
    if [[ -f "$mounts_dir/pi-agent-settings.json" ]]; then
        cp "$mounts_dir/pi-agent-settings.json" "$HOME/.pi/agent/settings.json"
    fi

    jq -n --arg base "$PROXY_BASE_URL" --arg model "$model" '
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

    local settings_base='{}'
    if [[ -f "$HOME/.pi/agent/settings.json" ]]; then
        settings_base="$(cat "$HOME/.pi/agent/settings.json")"
    fi
    if ! jq -n --argjson base "$settings_base" --arg model "$model" \
        '$base * { defaultProvider: "proxy", defaultModel: $model }' \
        > "$HOME/.pi/agent/settings.json.new"; then
        echo "Error: pi-agent/settings.json is not valid JSON, so the generated" >&2
        echo "model defaults cannot be merged into it." >&2
        exit 1
    fi
    mv "$HOME/.pi/agent/settings.json.new" "$HOME/.pi/agent/settings.json"
}

# A safety net run after both the coding leg and (when there is one) the
# review loop: whichever left work uncommitted must not lose it. A single
# function rather than two copies, so the call at each site stays short --
# nesting three levels deep inside the review-loop block below is exactly
# where a repeated inline version would blow past this file's own line
# length.
commit_uncommitted_work() {
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "fork-sandbox-k8s-entrypoint: committing uncommitted work ($1)" >&2
        git add -A
        git commit --quiet -m "fork-sandbox: commit uncommitted work at run end"
    fi
}

pi_rc=0
if [[ "$HARNESS" == pi ]]; then
    synthesize_pi_config "$MODEL"

    echo "fork-sandbox-k8s-entrypoint: running pi" >&2
    pi --provider proxy --model "$MODEL" --mode json -p \
        < "$mounts_dir/handoff.md" \
        > "$work_dir/events.jsonl" \
        2> "$work_dir/pi-stderr.log" \
        || pi_rc=$?
    echo "fork-sandbox-k8s-entrypoint: pi exited $pi_rc" >&2
else
    echo "fork-sandbox-k8s-entrypoint: installing the claude credential" >&2
    mkdir -p "$HOME/.claude"
    install -m 600 "$mounts_dir/claude-credentials.json" "$HOME/.claude/.credentials.json"
    # $HOME is a fresh tmpfs, so claude finds no config. Pre-accept
    # onboarding and trust for the clone dir, same jq claude-sandboxed
    # uses for a local sealed run, to keep this non-interactive run from
    # stalling on a dialog nothing can answer.
    jq -n --arg dir "$clone_dir" '{
        hasCompletedOnboarding: true,
        hasTrustDialogAccepted: true,
        projects: { ($dir): { hasTrustDialogAccepted: true } },
    }' > "$HOME/.claude.json"

    # The operator-inbox hook, exactly as a local claude run's --settings
    # installs it, so `fork-sandbox-k8s.sh say` addenda are delivered on
    # the next tool call and block a Stop while unread.
    install -m 755 "$mounts_dir/inbox-hook.sh" "$inbox_dir/.inbox-hook.sh"
    jq -n --arg hook "$inbox_dir/.inbox-hook.sh" '{
        hooks: {
            PostToolUse: [ { matcher: "*",
                             hooks: [ { type: "command", command: $hook, timeout: 20 } ] } ],
            Stop: [ { hooks: [ { type: "command", command: $hook, timeout: 20 } ] } ],
        },
    }' > "$work_dir/inbox-settings.json"

    echo "fork-sandbox-k8s-entrypoint: running claude" >&2
    ANTHROPIC_BASE_URL="$CLAUDE_PROXY_BASE_URL" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        DISABLE_AUTOUPDATER=1 \
        TERM=dumb \
        claude --dangerously-skip-permissions --print --verbose \
            --output-format stream-json --model "$MODEL" \
            --settings "$work_dir/inbox-settings.json" --include-hook-events \
        < "$mounts_dir/handoff.md" \
        > "$work_dir/events.jsonl" \
        2> "$work_dir/claude-stderr.log" \
        || pi_rc=$?
    echo "fork-sandbox-k8s-entrypoint: claude exited $pi_rc" >&2
fi

commit_uncommitted_work "coding leg"

# The --review-loop pass, when this run carries one. Runs pod-side -- the
# pod owns the clone, so a fresh review/fix session per iteration costs no
# kubectl round trip. See review-loop.sh's own header for the control flow;
# this block only decides whether to run it and folds its result in.
if [[ "$REVIEW_LOOP_CAP" =~ ^[1-9][0-9]*$ ]]; then
    if [[ "$pi_rc" != "0" ]]; then
        # A session that died of a model error must not be reviewed as if
        # it had worked -- the same rule fork-sandbox.sh's own local loop
        # follows. There is no review-loop.sh invocation to make that call
        # itself here, since only this script knows pi's exit code, so the
        # skip and its review-loop.json are written right here rather than
        # threaded into the loop script's interface.
        echo "fork-sandbox-k8s-entrypoint: pi exited $pi_rc; skipping the review loop" >&2
        jq -n --argjson cap "$REVIEW_LOOP_CAP" --arg rc "$pi_rc" '{
            cap: $cap,
            ended: "skipped",
            detail: ("the session exited " + $rc + ", so there is nothing worth reviewing"),
            iterations: [],
        }' > "$work_dir/review-loop.json"
    else
        echo "fork-sandbox-k8s-entrypoint: running the review loop" >&2
        # The review loop always runs pi, regardless of the coding leg's
        # harness. A claude coding leg never synthesized pi config at all
        # (MODEL is a Claude Code model name pi cannot use), so it is
        # synthesized here, for the first time, from REVIEW_MODEL --
        # required at startup for exactly this case, see the validation
        # above. A pi coding leg already synthesized it for MODEL; this
        # override only matters once REVIEW_MODEL differs from MODEL.
        review_loop_model="$MODEL"
        if [[ "$HARNESS" == claude ]]; then
            review_loop_model="$REVIEW_MODEL"
            synthesize_pi_config "$review_loop_model"
        fi
        loop_rc=0
        MODEL="$review_loop_model" bash "$mounts_dir/review-loop.sh" \
            --clone "$clone_dir" \
            --cap "$REVIEW_LOOP_CAP" \
            --base-sha "$BASE_SHA" \
            --review-prompt "$mounts_dir/review-prompt.md" \
            --fix-header "$mounts_dir/fix-prompt-header.md" \
            --verdict "$clone_dir/.git/review-verdict.md" \
            --work-dir "$work_dir" \
            --out "$work_dir/review-loop.json" \
            || loop_rc=$?
        if [[ "$loop_rc" != "0" ]]; then
            # Not propagated to this container's own exit status -- see the
            # comment on run_complete below. review-loop.json is where the
            # loop's outcome actually lives.
            echo "fork-sandbox-k8s-entrypoint: review-loop.sh exited $loop_rc" >&2
        fi

        # Deliberately NOT run between iterations -- review-loop.sh's own
        # no-progress detection reads the branch head, and auto-committing
        # mid-loop would make "a fix leg committed nothing" undetectable
        # from inside it.
        commit_uncommitted_work "review loop"
    fi
fi

# Measured here, at the end of the run, same as the local path's own
# end-of-run check in fork-sandbox.sh -- this is a heads-up only, never
# enforced: the client's own pull-back (fork-sandbox-k8s.sh run) applies the
# real refusal against the same cap once it has the tarball in hand, and
# deleting anything here would destroy work the operator might still want to
# inspect with `kubectl exec` before that pull-back runs.
outbox_bytes="$(du -sb -- "$outbox_dir" 2>/dev/null | cut -f1)"
[[ -n "$outbox_bytes" ]] || outbox_bytes=0
if (( outbox_bytes > OUTBOX_MAX_BYTES )); then
    echo "fork-sandbox-k8s-entrypoint: WARNING: outbox is $outbox_bytes bytes," >&2
    echo "fork-sandbox-k8s-entrypoint: over the $OUTBOX_MAX_BYTES byte cap --" >&2
    echo "fork-sandbox-k8s-entrypoint: the client will refuse to pull it back." >&2
fi

# .run-complete holds the CODING leg's exit code, never the review loop's --
# even when a loop ran and even if it ended in harness-error. This mirrors
# fork-sandbox.sh's own local loop, where `rc` stays the implement leg's
# code and the loop never reassigns it: the loop's outcome travels in
# review-loop.json instead, and cmd_run reports it separately (see
# fork-sandbox-k8s.sh). Do not "fix" this to propagate the loop's result
# into the process exit code -- that would collapse two different signals
# (did the AGENT'S work run, did the REVIEW judge it clean) into one.
printf '%s\n' "$pi_rc" > "$run_complete"

echo "fork-sandbox-k8s-entrypoint: idling up to ${RUN_TTL}s for the fetch" >&2
idle_deadline=$(( $(date +%s) + RUN_TTL ))
while [[ ! -f "$fetched_marker" ]] && (( $(date +%s) < idle_deadline )); do
    sleep 5
done

exit "$pi_rc"
