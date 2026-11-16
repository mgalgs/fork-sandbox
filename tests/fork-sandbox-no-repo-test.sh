#!/usr/bin/env bash
# fork-sandbox-no-repo-test.sh -- `fork-sandbox.sh --no-repo <handoff>`: a run
# with no project. Covers the empty work dir, the clean summary (no branch, no
# fetch failure), the run log's no_repo record, every refused flag (refused
# with nothing created), and that the handoff and --attach-dir scratch-root
# checks still apply.
#
# Usage: tests/fork-sandbox-no-repo-test.sh

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
export FORK_SANDBOX_RUN_SOURCE=test

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

work="$(mktemp -d /var/tmp/claude-scratch/forks/fs-no-repo-test.XXXXXX)"; tmpdirs+=("$work")
home="$work/home"; mkdir -p "$home/src" "$work/bin" "$work/config"
project="$home/src/project"; mkdir "$project"
git -C "$project" init -q
git -C "$project" -c user.name=Test -c user.email=test@fork-sandbox.invalid commit --allow-empty -qm init
handoff="/var/tmp/claude-scratch/fs-no-repo-handoff-$$.md"; tmpdirs+=("$handoff")
printf 'test no-repo\n' > "$handoff"

ln -s "$repo_dir/scripts/agent-sandboxed" "$work/bin/agent-sandboxed"
ln -s "$repo_dir/scripts/sandbox-run-log.py" "$work/bin/sandbox-run-log.py"
cat > "$work/bin/pi" <<'STUB'
process.exit(0);
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"fixture-model"}]}'
STUB
# Records its argv and the work dir's listing at launch, then runs the agent.
cat > "$work/bin/sandbox-backend-test" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then printf 'toolchain=host\n'; exit 0; fi
if [[ ! -e "$FIXTURE_ARGV" ]]; then
    printf '%s\n' "$@" > "$FIXTURE_ARGV"
    wd=""; prev=""
    for a in "$@"; do [[ "$prev" == --workdir ]] && wd="$a"; prev="$a"; done
    [[ -z "$wd" ]] || { ls -A "$wd" > "$FIXTURE_ARGV.ls" 2>&1; printf '%s\n' "$wd" > "$FIXTURE_ARGV.wd"; }
fi
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
[[ $# -eq 0 ]] || { shift; "$@"; }
STUB
chmod +x "$work/bin/pi" "$work/bin/curl" "$work/bin/sandbox-backend-test"
printf 'MODEL_ENDPOINT=http://127.0.0.1:8080/v1\n' > "$work/config/model.env"

run_dirs() { find /var/tmp/claude-scratch/forks -maxdepth 1 -name "claude-fork-sandbox.*" | sort; }

launch() {   # launch <capture> <args...>
    local capture="$1"; shift
    HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" \
        FORK_SANDBOX_RUN_SOURCE=test FORK_SANDBOX_BACKEND=test FIXTURE_ARGV="$capture" \
        timeout 60 "$launcher" --foreground --harness pi-local "$@" 2>&1
}

printf '== a handoff-only run ==\n'
capture="$work/argv"
out="$(launch "$capture" --no-repo "$handoff")"; rc=$?
run_dir="$(sed -n 's/^  run dir:  //p' <<<"$out" | head -1)"
if (( rc == 0 )) && [[ -n "$run_dir" && -d "$run_dir" ]]; then
    ok "a --no-repo run with only a handoff launches and exits 0"
else
    no "a --no-repo run with only a handoff launches and exits 0" "rc=$rc $out"
fi
if [[ -f "$capture.wd" && "$(cat "$capture.wd")" == "$run_dir/work" ]]; then
    ok "the session's work dir is a fresh directory inside the run dir"
else
    no "the session's work dir is a fresh directory inside the run dir" "$(cat "$capture.wd" 2>&1)"
fi
if [[ "$(tr -d '\n' < "$capture.ls" 2>/dev/null)" == ".git" ]]; then
    ok "the work dir held nothing but .git at launch"
else
    no "the work dir held nothing but .git at launch" "$(cat "$capture.ls" 2>&1)"
fi
summary="$(cat "$run_dir/summary.txt" 2>/dev/null)"
if [[ "$summary" == *"branch:    (none -- no project)"* && "$summary" == *"fetched:   nothing."* \
      && "$summary" != *"NO --"* && "$summary" != *"WARNING"* && "$summary" != *"Nothing landed"* ]]; then
    ok "the summary says there is no branch and reports no fetch failure"
else
    no "the summary says there is no branch and reports no fetch failure" "$summary"
fi
if jq -e '.no_repo == true and .origin_repo == null and .fetched == false and .exit_code == 0 and .commits == 0' \
        "$run_dir/summary.json" >/dev/null 2>&1; then
    ok "summary.json records no_repo, a null origin_repo and exit 0"
else
    no "summary.json records no_repo, a null origin_repo and exit 0" "$(cat "$run_dir/summary.json" 2>&1)"
fi
if [[ "$(cat "$run_dir/exit-code" 2>/dev/null)" == 0 ]]; then
    ok "exit-code is 0"
else
    no "exit-code is 0" "$(cat "$run_dir/exit-code" 2>&1)"
fi
if [[ -s "$run_dir/outbox/reply.md" ]] \
   && "$repo_dir/scripts/fork-sandbox-status.sh" --result "$run_dir" >/dev/null 2>&1; then
    ok "reply.md exists and --result reads the run"
else
    no "reply.md exists and --result reads the run" "$(ls "$run_dir/outbox" 2>&1)"
fi
rm -rf "$run_dir"

printf '\n== the run log ==\n'
logf="$home/.claude/sandbox-runs.jsonl"
rm -f "$logf"
out="$(launch "$work/argv-log" --no-repo "$handoff")"
run_dir2="$(sed -n 's/^  run dir:  //p' <<<"$out" | head -1)"
if jq -e 'select(.no_repo == true and .origin_repo == null)' "$logf" >/dev/null 2>&1; then
    ok "the run log records no project (origin_repo null, no_repo true)"
else
    no "the run log records no project (origin_repo null, no_repo true)" "$(cat "$logf" 2>&1)"
fi
[[ -z "$run_dir2" ]] || rm -rf "$run_dir2"

printf '\n== refusals create nothing ==\n'
refuse() {   # refuse <label> <expected-substring> <args...>
    local label="$1" want="$2"; shift 2
    local before after out rc
    before="$(run_dirs)"
    out="$(launch "$work/argv-refuse" "$@")"; rc=$?
    after="$(run_dirs)"
    if (( rc != 0 )) && [[ "$out" == *"$want"* && "$before" == "$after" && ! -e "$work/argv-refuse" ]]; then
        ok "$label"
    else
        no "$label" "rc=$rc $out"
    fi
}
refuse "a project path plus --no-repo is a usage error" "Usage" --no-repo "$project" "$handoff"
refuse "--branch is refused" "--branch" --no-repo --branch foo "$handoff"
refuse "--checkout is refused" "--checkout" --no-repo --checkout HEAD "$handoff"
refuse "--review-only is refused" "--review-only" --no-repo --review-only "$handoff"
refuse "--review-loop is refused" "--review-loop" --no-repo --review-loop 2 "$handoff"
refuse "--maintainer-loop is refused" "--maintainer-loop" --no-repo --maintainer-loop 2 "$handoff"
refuse "--preset is refused" "--preset" --no-repo --preset anything "$handoff"
refuse "--pipeline is refused" "--pipeline" --no-repo --pipeline csonnet "$handoff"
refuse "--k8s is refused" "--k8s" --no-repo --k8s "$handoff"
refuse "--clone-dir is refused" "--clone-dir" --no-repo --clone-dir /var/tmp/claude-scratch/x "$handoff"
refuse "--finalize-script is refused" "--finalize-script" --no-repo --finalize-script "$handoff" "$handoff"
rm -f "$work/argv-refuse"
# --resume is intercepted ahead of the option loop.
before="$(run_dirs)"
out="$(HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" timeout 30 \
    "$launcher" --resume "$work/nonexistent" --no-repo 2>&1)"; rc=$?
after="$(run_dirs)"
if (( rc != 0 )) && [[ "$out" == *"--no-repo cannot be combined with --resume"* && "$before" == "$after" ]]; then
    ok "resuming a previous run is refused"
else
    no "resuming a previous run is refused" "rc=$rc $out"
fi

printf '\n== the scratch-root constraints still hold ==\n'
outside_handoff="$(mktemp "${TMPDIR:-/tmp}/fs-no-repo-outside.XXXXXX")"; tmpdirs+=("$outside_handoff")
printf 'outside\n' > "$outside_handoff"
if [[ "$outside_handoff" == /var/tmp/claude-scratch/* || "$outside_handoff" == /tmp/claude-scratch/* ]]; then
    outside_handoff="$home/outside-handoff.md"; printf 'outside\n' > "$outside_handoff"
fi
refuse "a handoff outside the scratch root is still refused" "handoff files must live under" \
    --no-repo "$outside_handoff"

outside="$(mktemp -d)"; tmpdirs+=("$outside")
refuse "--attach-dir outside the scratch root is still refused" "must name a directory under" \
    --no-repo --attach-dir "$outside" "$handoff"

attach="$(mktemp -d /var/tmp/claude-scratch/fs-no-repo-attach.XXXXXX)"; tmpdirs+=("$attach")
printf 'frame\n' > "$attach/frame.txt"
capture="$work/argv-attach"
out="$(launch "$capture" --no-repo --attach-dir "$attach" "$handoff")"; rc=$?
run_dir3="$(sed -n 's/^  run dir:  //p' <<<"$out" | head -1)"
if (( rc == 0 )) && awk -v src="$attach" '$0 == "--bind-ro-at" { getline; if ($0 == src) { getline; if ($0 == "/attachments") found = 1 } } END { exit(!found) }' "$capture"; then
    ok "--attach-dir inside the scratch root works under --no-repo"
else
    no "--attach-dir inside the scratch root works under --no-repo" "rc=$rc $out"
fi
[[ -z "$run_dir3" ]] || rm -rf "$run_dir3"

printf '\n== without --no-repo nothing changes ==\n'
rm -f "$logf"
out="$(launch "$work/argv-plain" "$project" "$handoff")"; rc=$?
dry="$(launch "$work/argv-dry" --dry-run "$project" "$handoff")"
if (( rc == 0 )) && [[ "$out" == *"->  $project"* && "$dry" != *no_repo* ]] \
   && jq -e 'select(.event == "run_end" and (has("no_repo") | not) and .origin_repo == "'"$project"'")' "$logf" >/dev/null 2>&1; then
    ok "a normal run still names its project and carries no no_repo key"
else
    no "a normal run still names its project and carries no no_repo key" "rc=$rc $out $(cat "$logf" 2>&1)"
fi

printf '\n%d ok / %d fail\n' "$pass" "$fail"
(( fail == 0 ))
