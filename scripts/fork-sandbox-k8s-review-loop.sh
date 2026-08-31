#!/usr/bin/env bash
# fork-sandbox-k8s-review-loop.sh -- pod-side review/fix loop for
# fork-sandbox-k8s.sh's --review-loop, run by
# fork-sandbox-k8s-entrypoint.sh after the coding leg exits.
#
# Usage: fork-sandbox-k8s-review-loop.sh \
#            --clone DIR          the git clone the legs work in
#            --cap N              maximum iterations, positive integer
#            --base-sha SHA       the commit the branch is measured against
#            --review-prompt FILE the fully-rendered review prompt
#            --fix-header FILE    the fully-rendered fix prompt header
#            --verdict FILE       where the review leg must write its verdict
#            --work-dir DIR       where per-leg events files and fix
#                                 prompts go
#            --out FILE           where to write review-loop.json
#
# Env:
#   PI_BIN  the pi binary each leg runs. Defaults to "pi"; a test overrides
#           this with a stub, which is the whole reason it is a variable
#           rather than a hardcoded name.
#   MODEL   the model id passed to pi. Required, same as the entrypoint's
#           own coding-leg invocation.
#
# This is the same control flow as fork-sandbox.sh's own --review-loop (see
# its "review loop" section), ported to run INSIDE the pod rather than on
# the host: review a fresh session's read of the branch, hand any findings
# to a fresh fix session, repeat until approved, until a fix leg makes no
# progress, or until --cap iterations have run. It has to run pod-side --
# the pod owns the clone, and running legs anywhere else would cost a
# `kubectl exec` per leg.
#
# It is a standalone script, shipped into the pod in the per-run ConfigMap
# alongside entrypoint.sh, egress-gate.sh and inbox-write.sh, for the same
# reason inbox-write.sh is one: the control flow is then testable directly
# against a plain git repo, with a stub standing in for pi, and no cluster
# involved at all.
#
# It renders no prompt text of its own. Every word of the review and fix
# prompts is composed on the HOST by fork-sandbox-lib.sh's
# fs_emit_review_prompt_body/fs_emit_fix_prompt_body, the same functions
# fork-sandbox.sh's local loop uses, and shipped in as --review-prompt and
# --fix-header. This script's only prompt-related job is concatenating the
# fix header to a verdict -- see the fix-prompt assembly below.

set -euo pipefail

clone="" cap="" base_sha="" review_prompt="" fix_header="" verdict=""
work_dir="" out=""
while (( $# )); do
    case "$1" in
        --clone) clone="${2:?--clone requires a directory}"; shift 2 ;;
        --cap) cap="${2:?--cap requires a positive integer}"; shift 2 ;;
        --base-sha) base_sha="${2:?--base-sha requires a commit}"; shift 2 ;;
        --review-prompt) review_prompt="${2:?--review-prompt requires a file}"; shift 2 ;;
        --fix-header) fix_header="${2:?--fix-header requires a file}"; shift 2 ;;
        --verdict) verdict="${2:?--verdict requires a file}"; shift 2 ;;
        --work-dir) work_dir="${2:?--work-dir requires a directory}"; shift 2 ;;
        --out) out="${2:?--out requires a file}"; shift 2 ;;
        *) echo "Error: unknown option '$1'." >&2; exit 1 ;;
    esac
done

[[ -n "$clone" ]] || { echo "Error: --clone is required." >&2; exit 1; }
[[ -d "$clone" ]] || { echo "Error: --clone '$clone' is not a directory." >&2; exit 1; }
[[ -n "$cap" ]] || { echo "Error: --cap is required." >&2; exit 1; }
if [[ ! "$cap" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --cap must be a positive integer, got '$cap'." >&2
    exit 1
fi
[[ -n "$base_sha" ]] || { echo "Error: --base-sha is required." >&2; exit 1; }
[[ -n "$review_prompt" ]] || { echo "Error: --review-prompt is required." >&2; exit 1; }
[[ -f "$review_prompt" ]] || { echo "Error: no file at $review_prompt" >&2; exit 1; }
[[ -n "$fix_header" ]] || { echo "Error: --fix-header is required." >&2; exit 1; }
[[ -f "$fix_header" ]] || { echo "Error: --fix-header '$fix_header' not found." >&2; exit 1; }
[[ -n "$verdict" ]] || { echo "Error: --verdict is required." >&2; exit 1; }
[[ -n "$work_dir" ]] || { echo "Error: --work-dir is required." >&2; exit 1; }
[[ -n "$out" ]] || { echo "Error: --out is required." >&2; exit 1; }

mkdir -p "$work_dir"
mkdir -p "$(dirname -- "$out")"

PI_BIN="${PI_BIN:-pi}"
: "${MODEL:?MODEL must be set to the model id pi runs each leg with}"

# The branch head, read straight from the clone with plain git. Locally,
# fork-sandbox.sh's own clone_branch_head deliberately goes over `git
# ls-remote` FROM OUTSIDE the clone, because on the host the clone is
# sandbox-writable and a key such as core.fsmonitor in its config would
# execute ON THE HOST. That boundary does not exist here: this script runs
# INSIDE the pod, which already IS the sandbox, so there is nothing to
# escape by reading the clone directly. Do not "restore" the ls-remote
# indirection here -- it would just be a slower way to ask the same
# question with no boundary left to protect.
#
# The `|| true` is load-bearing under `set -e`: every caller assigns this in
# a command substitution and then checks the result for emptiness, and a
# simple assignment takes its exit status from the command, so without it a
# failed rev-parse would kill the script outright -- before the caller's own
# check could turn it into a recorded harness-error, and before
# save_review_loop could write a terminal `ended`. The local loop this was
# ported from never needed it because its ls-remote is piped into awk, whose
# success masks git's failure; dropping that pipeline dropped the masking
# too.
clone_branch_head() {
    git -C "$clone" rev-parse HEAD 2>/dev/null || true
}

cap_n="$cap"
ended=""
detail=""
# Finished iterations, as a JSON array (text). The current iteration is
# tracked separately in the it_* variables below and only folded in here by
# close_iter, once it is actually finished.
iters_done='[]'

# One iteration's record, built leg by leg. Anything not established is
# null rather than 0: "not reported" must never read as "none".
it_i=""
it_findings=null
it_review_exit=null
it_fix_exit=null
it_head_before=""
it_head_after=""
it_commits_added=null

reset_iter() {
    it_i="$1"
    it_findings=null
    it_review_exit=null
    it_fix_exit=null
    it_head_before=""
    it_head_after=""
    it_commits_added=null
}

# The current iteration as a one-element JSON array, or nothing when there
# is no current iteration (it_i unset).
iter_json() {
    [[ -n "$it_i" ]] || return 1
    jq -c -n \
        --argjson i "$it_i" \
        --argjson findings "$it_findings" \
        --argjson review_exit "$it_review_exit" \
        --argjson fix_exit "$it_fix_exit" \
        --arg head_before "$it_head_before" \
        --arg head_after "$it_head_after" \
        --argjson commits_added "$it_commits_added" \
        '[{
            i: $i,
            findings: $findings,
            review_exit: $review_exit,
            fix_exit: $fix_exit,
            head_before: (if $head_before == "" then null else $head_before end),
            head_after: (if $head_after == "" then null else $head_after end),
            commits_added: $commits_added,
        }]' 2>/dev/null
}

# Write review-loop.json from what is known right now. Called after every
# leg, not just at the end, so a pod killed mid-loop still leaves behind the
# iterations it finished. Built beside the file and renamed, which is
# atomic, so a reader watching the run sees one version or the other and
# never half of one.
save_review_loop() {
    local cur
    cur="$(iter_json)" || cur='[]'
    [[ -n "$cur" ]] || cur='[]'
    if jq -n \
        --argjson cap "$cap_n" \
        --arg ended "$ended" \
        --arg detail "$detail" \
        --argjson prev "$iters_done" \
        --argjson cur "$cur" \
        '{
            cap: $cap,
            ended: (if $ended == "" then null else $ended end),
            detail: (if $detail == "" then null else $detail end),
            iterations: ($prev + $cur),
        }' > "$out.part" 2>/dev/null; then
        mv -f "$out.part" "$out"
    else
        rm -f "$out.part"
    fi
}

# Move the current iteration into the finished list and write the file
# again.
close_iter() {
    local cur merged
    if cur="$(iter_json)" && [[ -n "$cur" ]]; then
        merged="$(jq -c -n --argjson d "$iters_done" --argjson c "$cur" '$d + $c' 2>/dev/null)"
        [[ -n "$merged" ]] && iters_done="$merged"
    fi
    it_i=""
    save_review_loop
}

# Run one leg: kind (review or fix), iteration number, prompt file. Sets
# leg_rc. The four pi flags below are a deliberate duplicate of the
# entrypoint's own coding-leg invocation rather than threaded through a
# shared function or an env-var indirection -- four flags is cheaper to
# repeat here than it is to build and maintain a shared path for.
run_leg() {
    local kind="$1" n="$2" prompt="$3"
    local leg_events="$work_dir/events-$kind-$n.jsonl"
    printf '\n== fork-sandbox-k8s-review-loop: %s leg, iteration %s ==\n' "$kind" "$n" >&2
    leg_rc=0
    "$PI_BIN" --provider proxy --model "$MODEL" --mode json -p \
        < "$prompt" > "$leg_events" 2>> "$work_dir/pi-stderr.log" \
        || leg_rc=$?
}

loop_head="$(clone_branch_head)"
if [[ -z "$loop_head" ]]; then
    echo "Error: could not read the branch head from $clone." >&2
    exit 1
fi

# One skip condition, recorded rather than silent: the coding session
# committed nothing, so there is nothing to review. (The other local skip
# condition -- the coding leg itself exiting non-zero -- is
# fork-sandbox-k8s-entrypoint.sh's call, not this script's: only the
# entrypoint knows the coding leg's exit code.)
if [[ "$loop_head" == "$base_sha" ]]; then
    ended="skipped"
    detail="the session committed nothing, so there is nothing to review"
fi

loop_i=1
while [[ -z "$ended" ]] && (( loop_i <= cap_n )); do
    reset_iter "$loop_i"
    it_head_before="$loop_head"
    save_review_loop

    # A verdict from a previous iteration must never be read as this one's,
    # so the path starts empty whatever left something there.
    rm -f "$verdict"

    run_leg review "$loop_i" "$review_prompt"
    it_review_exit="$leg_rc"
    save_review_loop
    if [[ "$leg_rc" != "0" ]]; then
        ended="harness-error"
        detail="the review leg of iteration $loop_i exited $leg_rc"
        close_iter
        break
    fi

    # The verdict is DATA. It is copied, counted and concatenated into a
    # prompt file -- never sourced, never evaluated, never put on a command
    # line. It is also written by a session, so a symlink at that path is
    # not a verdict: refuse it rather than follow it out of the clone. The
    # symlink check runs before anything reads through the path, so a
    # symlink's target is never opened.
    verdict_copy="$work_dir/review-verdict-$loop_i.md"
    if [[ -L "$verdict" || ! -f "$verdict" ]]; then
        ended="harness-error"
        detail="the review leg of iteration $loop_i left no verdict at $verdict"
        close_iter
        break
    fi
    # The work dir outlives the clone, so the copy is the record. Take the
    # original away in the same breath, so iteration i+1 cannot re-read it.
    cp -- "$verdict" "$verdict_copy" 2>/dev/null
    rm -f "$verdict"
    if [[ ! -s "$verdict_copy" ]]; then
        ended="harness-error"
        detail="the review leg of iteration $loop_i wrote an empty verdict"
        close_iter
        break
    fi

    # Untrusted text: strip control characters so an ESC or a CR in the
    # verdict cannot spoof a terminal reading this loop's stderr.
    verdict_line="$(head -n 1 "$verdict_copy" | tr -d '\000-\037\177' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # Deliberately nothing here checks the "## Report" section -- see the
    # same comment in fork-sandbox.sh's loop: the first line is the contract,
    # and a malformed report must never fail a valid verdict.
    case "$verdict_line" in
    APPROVED)
        it_findings=0
        ended="approved"
        printf 'fork-sandbox-k8s-review-loop: review iteration %s: APPROVED\n' "$loop_i" >&2
        close_iter
        break
        ;;
    FINDINGS)
        ;;
    *)
        ended="harness-error"
        detail="review iteration $loop_i: first verdict line is neither APPROVED nor FINDINGS"
        close_iter
        break
        ;;
    esac

    # One finding per paragraph, each citing file:line -- so count the
    # paragraphs that carry a citation. Copied verbatim from
    # fork-sandbox.sh's own loop: it is the counterpart to what the review
    # prompt asks for, and diverging here would silently change what
    # "findings" means between the local and cluster paths.
    it_findings="$(awk '
        NR == 1 { next }
        /^## Report$/ { exit }
        /^[[:space:]]*$/ { if (hit) n++; hit = 0; next }
        /[^[:space:]:]+:[0-9]+/ { hit = 1 }
        END { if (hit) n++; print n + 0 }' "$verdict_copy" 2>/dev/null)"
    [[ "$it_findings" =~ ^[0-9]+$ ]] || it_findings=null
    printf 'fork-sandbox-k8s-review-loop: review iteration %s: FINDINGS (%s cited)\n' \
        "$loop_i" "$it_findings" >&2
    save_review_loop

    # The fix leg's prompt: the host-generated header, then the verdict.
    # Built as a file and redirected -- the verdict has no size limit, and
    # pi's prompt travels on stdin for exactly that reason.
    fix_prompt="$work_dir/fix-prompt-$loop_i.md"
    {
        cat -- "$fix_header"
        printf '\n---\n\n'
        awk '/^## Report$/ { exit } { print }' "$verdict_copy"
    } > "$fix_prompt.part"
    mv -f "$fix_prompt.part" "$fix_prompt"

    run_leg fix "$loop_i" "$fix_prompt"
    it_fix_exit="$leg_rc"
    it_head_after="$(clone_branch_head)"
    save_review_loop
    if [[ "$leg_rc" != "0" ]]; then
        ended="harness-error"
        detail="the fix leg of iteration $loop_i exited $leg_rc"
        close_iter
        break
    fi
    if [[ -z "$it_head_after" ]]; then
        ended="harness-error"
        detail="branch head unreadable after the fix leg of iteration $loop_i"
        close_iter
        break
    fi
    if [[ "$it_head_after" == "$it_head_before" ]]; then
        # The same model reviews its own work here, so it can argue with
        # itself indefinitely. An iteration that committed nothing is the
        # end of the argument, not a reason to run another one.
        ended="no-progress"
        printf 'fork-sandbox-k8s-review-loop: iteration %s: fix leg committed nothing\n' \
            "$loop_i" >&2
        close_iter
        break
    fi
    # Unlike the local loop, this script owns the clone directly, so
    # commits_added can be counted right here rather than deferred until
    # after a fetch lands the objects on the host.
    # `|| true` for the same set -e reason as clone_branch_head above: the
    # non-numeric fallback on the next line is the intended handling of a
    # failure here, and it only gets to run if the failure does not take the
    # script down with it first.
    it_commits_added="$(git -C "$clone" rev-list --count \
        "$it_head_before..$it_head_after" 2>/dev/null || true)"
    [[ "$it_commits_added" =~ ^[0-9]+$ ]] || it_commits_added=null
    loop_head="$it_head_after"
    close_iter
    loop_i=$(( loop_i + 1 ))
done
[[ -n "$ended" ]] || ended="cap"
save_review_loop
printf 'fork-sandbox-k8s-review-loop: review loop ended: %s\n' "$ended" >&2
