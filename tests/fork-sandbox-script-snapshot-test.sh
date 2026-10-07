#!/usr/bin/env bash
# fork-sandbox-script-snapshot-test.sh — a run executes a launch-time snapshot
# of the scripts it was launched from
#
# Usage: tests/fork-sandbox-script-snapshot-test.sh
#        SCRIPTS_SRC=<dir holding another scripts/ tree> tests/...
#
# The checkout fork-sandbox is installed from is live: ~/.claude/scripts
# symlinks into it, so a pull or merge moves it under every run in flight,
# and a run keeps launching helpers for hours. fork-sandbox.sh therefore
# copies the whole scripts/ directory into <run-dir>/scripts at launch and
# points everything the run executes at the copy.
#
# This suite proves it the hard way. It builds a throwaway "checkout" (a copy
# of scripts/, with a stub claude-sandboxed standing in for the real
# wrapper), installs a fixture ~/.claude/scripts farm that links into it,
# and launches a two-leg run (implement, then review) through that checkout.
# The implement leg's stub then does to the checkout what a merge would do:
# replaces the wrapper, the backend, the formatter, the library and the
# run-log writer with ones that fail loudly. The review leg's stub deletes
# the checkout outright. The run must still finish, every leg must have run
# the launch-time wrapper out of the snapshot, none of the loud failures may
# have fired, and the run log must still be written by the snapshot's own
# writer.
#
# SCRIPTS_SRC aims the throwaway checkout at a different scripts/ tree, so
# the suite can be pointed at the code from before the snapshot existed and
# shown to FAIL there (git archive <commit> scripts | tar -x -C <dir>).
#
# claude-sandboxed is a stub and nothing here starts a sandbox or tmux: the
# launcher runs --foreground, which exec's the runner in this process.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
scripts_src="${SCRIPTS_SRC:-$repo_dir/scripts}"

# Every run this suite launches is a fixture, not real work.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()
fs_by_session_scratch="$(mktemp -d)"; tmpdirs+=("$fs_by_session_scratch")
export FORK_SANDBOX_BY_SESSION_DIR="$fs_by_session_scratch"

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

# contains LABEL NEEDLE HAYSTACK / lacks LABEL NEEDLE HAYSTACK
contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) no "$1" "expected '$2' in: $3" ;;
    esac
}
lacks() {
    case "$3" in
        *"$2"*) no "$1" "did not expect '$2' in: $3" ;;
        *) ok "$1" ;;
    esac
}

work="$(mktemp -d /var/tmp/claude-scratch/fs-script-snapshot.XXXXXX)"
tmpdirs+=("$work")
checkout="$work/checkout"
home="$work/home"
leg_log="$work/leg.log"
runlog_marker="$work/live-run-log-ran"
mkdir -p "$checkout" "$home/src" "$home/.claude/scripts" \
    "$home/.claude/skills/commit-then-review" \
    "$home/.claude/skills/code-review-portable"
: > "$leg_log"

# The throwaway checkout: a copy of the scripts, as install.sh would have
# linked them. cp -a so the mode bits and pi-sandboxed's relative link come
# along.
cp -a "$scripts_src" "$checkout/scripts"
# agent-sandboxed reads the sandbox's pi configuration from ../pi-agent next to
# the scripts it resolves to, so the checkout carries one, with a marker file.
cp -a "$repo_dir/pi-agent" "$checkout/pi-agent"
printf 'launch-time\n' > "$checkout/pi-agent/snapshot-marker"

# The stub wrapper. It lives in the checkout like the real one, so a run that
# resolves its wrapper through the farm reaches it there. Each call logs where
# it ran from and what it was handed, plus where `sandbox-backend-bwrap` would
# resolve on the PATH it sees; then:
#   leg 1 (implement): commits a file, then replaces the checkout's helpers
#     with ones that fail loudly -- new inodes via mv, so a copy of the old
#     one that is mid-execution is not rewritten under itself;
#   leg 2 (review): approves, then deletes the checkout.
# Replaced here, before the launch, with the checkout's own copy; the
# snapshot taken at launch carries this stub too, which is the point.
cat > "$checkout/scripts/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
clone=""
for a in "$@"; do [[ -d "$a/.git" ]] && clone="$a"; done
n=$(( $(wc -l < "$LEG_LOG") + 1 ))
printf 'leg %s: ran %s (v1) backend=%s argv=%s\n' "$n" "$0" \
    "$(command -v sandbox-backend-bwrap || echo none)" "$*" >> "$LEG_LOG"
loud() {  # loud NAME BODY -- replace the live checkout's NAME with BODY
    local f="$CHECKOUT/scripts/$1"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$f.new" && chmod +x "$f.new" && mv -f "$f.new" "$f"
}
if (( n == 1 )); then
    printf 'work\n' > "$clone/work.txt"
    git -C "$clone" add work.txt
    git -C "$clone" -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q -m work
    loud claude-sandboxed "echo 'LIVE claude-sandboxed (v2) ran' >> '$LEG_LOG'; exit 97"
    loud sandbox-backend-bwrap "echo 'LIVE backend ran' >> '$LEG_LOG'; exit 96"
    loud fork-sandbox-format.sh "echo 'LIVE formatter ran' >> '$LEG_LOG'; exit 95"
    loud fork-sandbox-lib.sh "echo 'LIVE lib sourced' >> '$LEG_LOG'; exit 94"
    loud fork-sandbox-refresh.sh "echo 'LIVE refresh sourced' >> '$LEG_LOG'; exit 93"
    loud sandbox-run-log.py "echo 'LIVE run-log ran' >> '$LEG_LOG'; touch '$RUNLOG_MARKER'; exit 92"
else
    printf 'APPROVED\n\nSound.\n\n## Report\nSound.\n' > "$clone/.git/review-verdict.md"
    rm -rf "$CHECKOUT"
fi
printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
STUB
chmod +x "$checkout/scripts/claude-sandboxed"

# The fixture farm: per-file links into the throwaway checkout, as install.sh
# makes them, put on PATH the way a user's shell does.
for f in claude-sandboxed sandbox-run-log.py fork-sandbox-format.sh; do
    ln -s "$checkout/scripts/$f" "$home/.claude/scripts/$f"
done

proj="$(mktemp -d "$home/src/fs-script-snapshot-test.XXXXXX")"
(
    cd "$proj" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'hello\n' > file.txt \
        && git add file.txt \
        && git commit -q -m init
) >/dev/null 2>&1
printf 'do the task\n' > "$work/handoff.md"
cfg="$work/config"; mkdir -p "$cfg"

printf '== a two-leg run whose checkout is rewritten, then deleted, mid-run ==\n'

out="$(HOME="$home" PATH="$home/.claude/scripts:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
    LEG_LOG="$leg_log" CHECKOUT="$checkout" RUNLOG_MARKER="$runlog_marker" \
    timeout 120 "$checkout/scripts/fork-sandbox.sh" --foreground --harness claude \
    --review-loop 1 --review-harness claude "$proj" "$work/handoff.md" 2>&1)"
rc=$?
rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if (( rc != 0 )) || [[ -z "$rd" ]]; then
    no "the run finishes though its checkout is rewritten and then deleted" \
        "rc=$rc rd=$rd: $out"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
ok "the run finishes though its checkout is rewritten and then deleted"

log="$(cat "$leg_log")"
check_legs="$(grep -c '^leg ' "$leg_log")"
if [[ "$check_legs" == 2 ]]; then
    ok "both legs ran (implement, then review)"
else
    no "both legs ran (implement, then review)" "$log"
fi
lacks "no leg reached the rewritten wrapper" "LIVE claude-sandboxed" "$log"
lacks "the sandbox backend was not the rewritten one" "LIVE backend" "$log"
lacks "the formatter was not the rewritten one" "LIVE formatter" "$log"
lacks "the library was not the rewritten one" "LIVE lib" "$log"
lacks "refresh was not the rewritten one" "LIVE refresh" "$log"

# Where each leg's wrapper ran from.
legs_off_snapshot=0
while IFS= read -r line; do
    [[ "$line" == "leg "[0-9]*": ran $rd/scripts/claude-sandboxed "* ]] || legs_off_snapshot=$(( legs_off_snapshot + 1 ))
done < <(grep '^leg ' "$leg_log")
if (( legs_off_snapshot == 0 )); then
    ok "every leg ran the wrapper out of the run's own scripts/"
else
    no "every leg ran the wrapper out of the run's own scripts/" "$log"
fi
contains "a wrapper's backend lookup lands in the snapshot" \
    "backend=$rd/scripts/sandbox-backend-bwrap" "$log"
contains "inside the sandbox, this checkout's scripts are the snapshot, at the checkout's own path" \
    "--bind-ro-at $rd/scripts $checkout/scripts" "$log"
lacks "the live checkout is not bound as itself" "--bind-ro $checkout/scripts" "$log"

# The run log was written by the snapshot's writer, after the checkout was gone.
if [[ -e "$runlog_marker" ]]; then
    no "the run log was written by the launch-time writer" "the live writer ran"
elif grep -q "$(basename "$rd")" "$home/.claude/sandbox-runs.jsonl" 2>/dev/null; then
    ok "the run log was written by the launch-time writer, with the checkout deleted"
else
    no "the run log was written by the launch-time writer, with the checkout deleted" \
        "$(cat "$home/.claude/sandbox-runs.jsonl" 2>/dev/null) / $(tail -3 "$rd/sandbox.log" 2>/dev/null)"
fi

printf '\n== nothing the run executes names the checkout or the farm ==\n'

# What run.sh points at: its own script_dir, the formatter, the run-log
# writer, and the executable each sandbox command starts with (the binds
# after it legitimately name the checkout: that is where the snapshot is
# mounted inside the sandbox). None may resolve into the live checkout or the
# ~/.claude/scripts farm.
runsh="$rd/run.sh"
check_one() {
    local label="$1" pattern="$2" line word
    line="$(grep -m1 -E "$pattern" "$runsh")"
    word="${line#*=}"; word="${word#\(}"; word="${word%% *}"
    if [[ -z "$line" ]]; then
        no "$label" "no line matching $pattern in run.sh"
    elif [[ "$word" == "$rd/scripts" || "$word" == "$rd/scripts/"* ]]; then
        ok "$label"
    else
        no "$label" "points at: $word"
    fi
}
check_one "script_dir is the snapshot" '^script_dir='
check_one "the formatter is the snapshot's" '^formatter='
check_one "the review formatter is the snapshot's" '^rev_formatter='
check_one "the run-log writer is the snapshot's" '^run_log_bin='
check_one "the implement leg's wrapper is the snapshot's" '^sandbox_cmd='
check_one "the review leg's wrapper is the snapshot's" '^review_sandbox_cmd='
# shellcheck disable=SC2016  # a literal line of the generated run.sh
if grep -q '^export PATH="\$script_dir:\$PATH"$' "$runsh"; then
    ok "run.sh puts the snapshot first on its PATH"
else
    no "run.sh puts the snapshot first on its PATH" "$(grep -n PATH "$runsh" | head -3)"
fi

printf '\n== the snapshot is the whole directory, byte for byte ==\n'

# claude-sandboxed is the stub replaced above; the snapshot carries the stub.
if differs="$(diff -r -x claude-sandboxed "$scripts_src" "$rd/scripts" 2>&1)"; then
    ok "every other script in scripts/ is in the snapshot, unchanged"
else
    no "every other script in scripts/ is in the snapshot, unchanged" "$differs"
fi
if [[ -L "$rd/scripts/pi-sandboxed" && "$(readlink "$rd/scripts/pi-sandboxed")" == agent-sandboxed ]]; then
    ok "pi-sandboxed is still a relative link to agent-sandboxed inside the snapshot"
else
    no "pi-sandboxed is still a relative link to agent-sandboxed inside the snapshot"
fi

# agent-sandboxed locates pi-agent/ relative to its own resolved path; the same
# expression, run on the snapshot's pi-sandboxed link, must find it there.
# shellcheck disable=SC2016  # a line of agent-sandboxed, quoted verbatim
if ! grep -qF 'REPO_ROOT="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"' "$rd/scripts/agent-sandboxed"; then
    no "agent-sandboxed still derives its pi-agent root from its own path" "the expression changed; update this test"
else
    snap_root="$(dirname "$(dirname "$(readlink -f "$rd/scripts/pi-sandboxed")")")"
    if [[ "$snap_root" == "$rd" && "$(cat "$snap_root/pi-agent/snapshot-marker" 2>/dev/null)" == launch-time ]] \
        && diff -r -x snapshot-marker "$repo_dir/pi-agent" "$rd/pi-agent" >/dev/null 2>&1; then
        ok "a pi leg launched from the snapshot finds the launch-time pi-agent/"
    else
        no "a pi leg launched from the snapshot finds the launch-time pi-agent/" \
            "root=$snap_root ls=$(ls "$rd" 2>&1)"
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
