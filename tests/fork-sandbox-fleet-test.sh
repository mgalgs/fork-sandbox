#!/usr/bin/env bash
# fork-sandbox-fleet-test.sh — Exercise fork-sandbox-fleet.sh: check,
# resolve, expand, roster, and the fleet-parse.py plumbing underneath it,
# against throwaway fixtures.
#
# Usage: tests/fork-sandbox-fleet-test.sh
#
# Runs entirely offline against temp FORK_SANDBOX_FLEET_FILE /
# FORK_SANDBOX_PERSONAS_DIR paths -- never the real defaults.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fleet="$repo_dir/scripts/fork-sandbox-fleet.sh"
parse="$repo_dir/scripts/fork-sandbox-fleet-parse.py"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        no "$label" "expected '$expected', got '$actual'"
    fi
}

contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

refuses() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        no "$label" "it succeeded; output: $out"
    else
        ok "$label"
    fi
}

# Sets $1 to a fresh temp dir and registers it for cleanup. A nameref
# out-param, not a printf-and-capture return: "$(new_root)" would run the
# body in a command-substitution subshell, where "tmpdirs+=" only updates
# the subshell's copy and the dir would never actually get tracked.
new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

printf '== check: clean config ==\n'

new_root FORK_SANDBOX_FLEET_FILE_DIR
export FORK_SANDBOX_FLEET_FILE="$FORK_SANDBOX_FLEET_FILE_DIR/fleet.yaml"
new_root FORK_SANDBOX_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR

cat > "$FORK_SANDBOX_PERSONAS_DIR/riffler.md" <<'EOF'
---
harness: claude
model: opus
description: reviews riffs
---
Body text, opaque to the registry.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/tuner.md" <<'EOF'
No frontmatter at all, just prose.
EOF
cat > "$FORK_SANDBOX_PERSONAS_DIR/scout.md" <<'EOF'
---
network: sealed
---
EOF

cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  riffler:
    model: sonnet
  tuner: {}
  scout:
    harness: pi
lists:
  jam-band:
    members: [riffler, tuner, scout]
EOF

out="$("$fleet" check 2>&1)"; rc=$?
check "check: clean config exits 0" "0" "$rc"
check "check: clean config prints nothing" "" "$out"

printf '\n== check: validation errors ==\n'

bad() {
    # Write a fleet file named bad, expect a `check` refusal containing
    # $2 (and $3, when given -- usually the path that addresses the
    # error). Reuses whatever personas dir is currently exported.
    local label="$1" needle="$2" needle2="${3:-}"
    local badfile="$FORK_SANDBOX_FLEET_FILE_DIR/bad.yaml"
    cat > "$badfile"
    local saved="$FORK_SANDBOX_FLEET_FILE"
    export FORK_SANDBOX_FLEET_FILE="$badfile"
    local err
    if err="$("$fleet" check 2>&1)"; then
        no "$label" "expected a refusal, got exit 0"
    else
        contains "$label" "$err" "$needle"
        [[ -z "$needle2" ]] || contains "$label (addressed by path)" "$err" "$needle2"
    fi
    export FORK_SANDBOX_FLEET_FILE="$saved"
}

bad "unknown key is refused, addressed by path" "unknown key" "agents.riffler.modle" <<'EOF'
agents:
  riffler:
    modle: opus
EOF

bad "uppercase agent name is rejected" "agent names match" <<'EOF'
agents:
  Riffler: {}
EOF

bad "leading-dash agent name is rejected" "agent names match" <<'EOF'
agents:
  -riffler: {}
EOF

bad "agent+list name collision is rejected" "defined as both an agent and a list" <<'EOF'
agents:
  riffler: {}
lists:
  riffler:
    members: [riffler]
EOF

bad "list member naming an undefined agent is rejected" "not a defined agent" <<'EOF'
agents:
  riffler: {}
lists:
  jam-band:
    members: [riffler, nobody]
EOF

bad "list member naming a list is rejected" "lists cannot contain lists" <<'EOF'
agents:
  riffler: {}
lists:
  inner:
    members: [riffler]
  outer:
    members: [inner]
EOF

bad "missing persona file for a declared agent is rejected" "does not exist" <<'EOF'
agents:
  ghost: {}
EOF

bad "absolute persona: value is rejected" "must be a bare filename" <<'EOF'
agents:
  riffler:
    persona: /tmp/elsewhere/x.md
EOF

bad "persona: value with a subdirectory is rejected" "must be a bare filename" <<'EOF'
agents:
  riffler:
    persona: subdir/x.md
EOF

cat > "$FORK_SANDBOX_PERSONAS_DIR/collide.md" <<'EOF'
---
harness: claude
---
EOF
bad "list name colliding with a persona file is rejected" "also makes it a valid agent name" <<'EOF'
agents:
  riffler: {}
lists:
  collide:
    members: [riffler]
EOF
rm -f "$FORK_SANDBOX_PERSONAS_DIR/collide.md"

cat > "$FORK_SANDBOX_PERSONAS_DIR/loner-bad.md" <<'EOF'
---
harness: gpt-9
---
EOF
bad "bare persona file with no fleet.yaml entry is still checked" \
    "takes 'claude', 'pi' or 'codex', not 'gpt-9'" <<'EOF'
agents:
  riffler: {}
EOF
rm -f "$FORK_SANDBOX_PERSONAS_DIR/loner-bad.md"

bad "network sealed with harness claude in the same fleet.yaml entry is rejected" \
    "network 'sealed' requires harness 'pi'" <<'EOF'
agents:
  riffler:
    harness: claude
    network: sealed
EOF

cat > "$FORK_SANDBOX_PERSONAS_DIR/sealed-claude.md" <<'EOF'
---
harness: claude
network: sealed
---
EOF
bad "network sealed with harness claude in frontmatter alone is rejected" \
    "network 'sealed' requires harness 'pi'" <<'EOF'
agents:
  sealed-claude: {}
EOF
rm -f "$FORK_SANDBOX_PERSONAS_DIR/sealed-claude.md"

cat > "$FORK_SANDBOX_PERSONAS_DIR/merged-sealed.md" <<'EOF'
---
harness: pi
network: sealed
---
EOF
bad "network sealed from frontmatter merged with a harness override from fleet.yaml is rejected" \
    "network 'sealed' requires harness 'pi'" <<'EOF'
agents:
  merged-sealed:
    harness: claude
EOF
rm -f "$FORK_SANDBOX_PERSONAS_DIR/merged-sealed.md"

bad "wake-on-cc must be a YAML boolean, not a string" \
    "agents.riffler.wake-on-cc: must be a YAML boolean" <<'EOF'
agents:
  riffler:
    wake-on-cc: "yes"
EOF

bad "refresh-at must match fork-sandbox.sh's --refresh-at grammar" \
    "agents.riffler.refresh-at: must be a fraction" <<'EOF'
agents:
  riffler:
    refresh-at: soon
EOF

badfile="$FORK_SANDBOX_FLEET_FILE_DIR/bad.yaml"
cat > "$badfile" <<'EOF'
agents:
  Riffler:
    modle: opus
lists:
  jam-band:
    members: [nobody]
EOF
saved="$FORK_SANDBOX_FLEET_FILE"
export FORK_SANDBOX_FLEET_FILE="$badfile"
multi_err="$("$fleet" check 2>&1)"; multi_rc=$?
check "multiple errors: exits 1" "1" "$multi_rc"
contains "multiple errors: reports the bad name" "$multi_err" "agent names match"
contains "multiple errors: reports the bad list member" "$multi_err" "not a defined agent"
check "multiple errors: reports more than one line" "1" "$(( $(wc -l <<< "$multi_err") > 1 ))"
export FORK_SANDBOX_FLEET_FILE="$saved"

printf '\n== resolve ==\n'

resolve_lines() {
    # Reads the eight-line contract into named globals for assertions.
    { read -r r_harness; read -r r_model; read -r r_thinking; read -r r_network; \
      read -r r_persona; read -r r_description; read -r r_wake_on_cc; \
      read -r r_refresh_at; } < <("$fleet" resolve "$1")
}

resolve_lines riffler
check "resolve: model comes from fleet.yaml (overrides frontmatter)" "sonnet" "$r_model"
check "resolve: harness falls back to frontmatter" "claude" "$r_harness"
check "resolve: description falls back to frontmatter" "reviews riffs" "$r_description"
check "resolve: thinking is empty when unset anywhere" "" "$r_thinking"
check "resolve: persona path is under the personas dir" "$FORK_SANDBOX_PERSONAS_DIR/riffler.md" "$r_persona"

resolve_lines scout
check "resolve: harness from fleet.yaml overrides nothing when frontmatter lacks it" "pi" "$r_harness"
check "resolve: network from frontmatter-only persona" "sealed" "$r_network"

resolve_lines tuner
check "resolve: all-empty agent, harness empty" "" "$r_harness"
check "resolve: all-empty agent, model empty" "" "$r_model"
check "resolve: all-empty agent, network empty" "" "$r_network"
check "resolve: all-empty agent, description empty" "" "$r_description"
check "resolve: all-empty agent, wake-on-cc empty" "" "$r_wake_on_cc"
check "resolve: all-empty agent, refresh-at empty" "" "$r_refresh_at"
check "resolve: all-empty agent still resolves a persona path" "$FORK_SANDBOX_PERSONAS_DIR/tuner.md" "$r_persona"

# Piped, not captured via $(...): command substitution strips trailing
# newlines, which would silently swallow the count when the last field
# (refresh-at) is empty, as it is for tuner.
check "resolve: output is exactly eight lines" "8" "$("$fleet" resolve tuner | wc -l)"

printf '\n== resolve: wake-on-cc / refresh-at ==\n'

cat > "$FORK_SANDBOX_PERSONAS_DIR/observer.md" <<'EOF'
---
wake-on-cc: false
refresh-at: 0.75
---
EOF
cat > "$FORK_SANDBOX_FLEET_FILE" <<'EOF'
agents:
  riffler:
    model: sonnet
  tuner: {}
  scout:
    harness: pi
  observer: {}
  loud:
    wake-on-cc: true
    refresh-at: 4000
lists:
  jam-band:
    members: [riffler, tuner, scout]
EOF

resolve_lines observer
check "resolve: wake-on-cc from frontmatter alone" "false" "$r_wake_on_cc"
check "resolve: refresh-at from frontmatter alone" "0.75" "$r_refresh_at"

cat > "$FORK_SANDBOX_PERSONAS_DIR/loud.md" <<'EOF'
---
wake-on-cc: false
refresh-at: 0.1
---
EOF
resolve_lines loud
check "resolve: wake-on-cc from fleet.yaml overrides frontmatter" "true" "$r_wake_on_cc"
check "resolve: refresh-at from fleet.yaml overrides frontmatter" "4000" "$r_refresh_at"

refuses "resolve: unknown agent exits nonzero" "$fleet" resolve nosuchagent

printf '\n== expand ==\n'

check "expand: single agent passes through" "@riffler" "$("$fleet" expand @riffler)"

exp_list="$("$fleet" expand @jam-band)"
check "expand: list expansion preserves members order" "$(printf '@riffler\n@tuner\n@scout')" "$exp_list"

exp_dedup="$("$fleet" expand @riffler,@jam-band)"
check "expand: dedup keeps first-seen position" "$(printf '@riffler\n@tuner\n@scout')" "$exp_dedup"

exp_comma="$("$fleet" expand @tuner,@scout)"
check "expand: comma-separated input" "$(printf '@tuner\n@scout')" "$exp_comma"

exp_spaced="$("$fleet" expand "@tuner, @scout")"
check "expand: comma-space-joined input, mail's canonical To:/Cc: form" \
    "$(printf '@tuner\n@scout')" "$exp_spaced"

refuses "expand: unknown address errors" "$fleet" expand @nobody
refuses "expand: address without @ is rejected" "$fleet" expand riffler

printf '\n== roster ==\n'

roster_out="$("$fleet" roster 2>&1)"; roster_rc=$?
check "roster: exits 0 on the fixture" "0" "$roster_rc"
contains "roster: lists riffler" "$roster_out" "riffler"
contains "roster: lists tuner" "$roster_out" "tuner"
contains "roster: lists scout" "$roster_out" "scout"
contains "roster: lists the jam-band list" "$roster_out" "jam-band"

printf '\n== roster includes persona-only agents (no fleet.yaml entry) ==\n'

cat > "$FORK_SANDBOX_PERSONAS_DIR/drifter.md" <<'EOF'
---
harness: codex
---
EOF
roster_loner="$("$fleet" roster 2>&1)"
contains "roster: lists a persona-only agent with no fleet.yaml entry" "$roster_loner" "drifter"
contains "roster: resolves the persona-only agent's harness" "$roster_loner" "harness=codex"
rm -f "$FORK_SANDBOX_PERSONAS_DIR/drifter.md"

printf '\n== missing fleet file / personas dir ==\n'

new_root MISSING_DIR
missing_fleet="$MISSING_DIR/no-such-fleet.yaml"
missing_personas="$MISSING_DIR/no-such-personas"

saved_fleet="$FORK_SANDBOX_FLEET_FILE"
export FORK_SANDBOX_FLEET_FILE="$missing_fleet"
refuses "check: missing fleet file is refused" "$fleet" check
refuses "roster: missing fleet file is refused" "$fleet" roster
check "check: missing fleet file message names it" "1" \
    "$("$fleet" check 2>&1 | grep -c "no fleet file")"
export FORK_SANDBOX_FLEET_FILE="$saved_fleet"

saved_personas="$FORK_SANDBOX_PERSONAS_DIR"
export FORK_SANDBOX_PERSONAS_DIR="$missing_personas"
refuses "check: missing personas dir is refused" "$fleet" check
check "check: missing personas dir message names it" "1" \
    "$("$fleet" check 2>&1 | grep -c "no personas dir")"
export FORK_SANDBOX_PERSONAS_DIR="$saved_personas"

printf '\n== personas alone, no fleet file (a valid fleet of unlisted agents) ==\n'

new_root LONER_PERSONAS_DIR
export FORK_SANDBOX_PERSONAS_DIR="$LONER_PERSONAS_DIR"
cat > "$LONER_PERSONAS_DIR/loner.md" <<'EOF'
---
harness: codex
---
EOF
saved_fleet="$FORK_SANDBOX_FLEET_FILE"
export FORK_SANDBOX_FLEET_FILE="$MISSING_DIR/still-no-fleet.yaml"
resolve_lines loner
check "expand/resolve: bare agent works from persona alone, no fleet file" "codex" "$r_harness"
check "expand: bare agent from persona alone" "@loner" "$("$fleet" expand @loner)"
export FORK_SANDBOX_FLEET_FILE="$saved_fleet"
export FORK_SANDBOX_PERSONAS_DIR="$saved_personas"

printf '\n== pi-local is rejected as a harness value ==\n'

bad "pi-local names the two-axis spelling instead" "harness: pi" "network: sealed" <<'EOF'
agents:
  legacy:
    harness: pi-local
EOF

printf '\n== teardown ==\n'

# Asserts path $2 does/does not exist, per $1 ("gone" or "present").
path_state() {
    local label="$1" want="$2" path="$3"
    if [[ "$want" == gone ]]; then
        if [[ -e "$path" ]]; then no "$label" "still present: $path"; else ok "$label"; fi
    else
        if [[ -e "$path" ]]; then ok "$label"; else no "$label" "missing: $path"; fi
    fi
}

new_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
PM_STATE="$FORK_SANDBOX_MAIL_ROOT/.postmaster"

# alice/th1: a full seat -- workspace, session record, session state.
mkdir -p -- "$PM_STATE/workspaces/th1/alice" "$PM_STATE/state/th1/alice" "$PM_STATE/sessions/th1"
echo sid-alice > "$PM_STATE/sessions/th1/alice"

td_out="$("$fleet" teardown alice --thread th1)"; td_rc=$?
check "teardown: no-live-run seat exits 0" "0" "$td_rc"
contains "teardown: reports workspace removed" "$td_out" "workspace"
contains "teardown: reports session record removed" "$td_out" "session record"
contains "teardown: reports session state removed" "$td_out" "session state"
path_state "teardown: workspace actually removed" gone "$PM_STATE/workspaces/th1/alice"
path_state "teardown: session record actually removed" gone "$PM_STATE/sessions/th1/alice"
path_state "teardown: session state actually removed" gone "$PM_STATE/state/th1/alice"

td_out2="$("$fleet" teardown alice --thread th1)"; td_rc2=$?
check "teardown: nothing-to-remove exits 0" "0" "$td_rc2"
contains "teardown: nothing-to-remove message" "$td_out2" "nothing to remove"

# bob/th2: a live, not-yet-harvested run -- teardown must refuse it.
mkdir -p -- "$PM_STATE/workspaces/th2/bob" "$PM_STATE/runs" "$PM_STATE/harvested"
printf 'AGENT=bob\nTHREAD=th2\n' > "$PM_STATE/runs/run-bob.env"
td_out3="$("$fleet" teardown bob --thread th2 2>&1)"; td_rc3=$?
check "teardown: live-run refusal exits 1" "1" "$td_rc3"
contains "teardown: live-run refusal names the run" "$td_out3" "run-bob"
path_state "teardown: live-run seat's workspace untouched" present "$PM_STATE/workspaces/th2/bob"

# carol has seats on two threads; teardown with no --thread sweeps both.
mkdir -p -- "$PM_STATE/workspaces/th3/carol" "$PM_STATE/workspaces/th4/carol"
td_out4="$("$fleet" teardown carol)"; td_rc4=$?
check "teardown: bare agent (no --thread) sweeps every thread, exits 0" "0" "$td_rc4"
contains "teardown: bare agent tears down th3" "$td_out4" "carol/th3"
contains "teardown: bare agent tears down th4" "$td_out4" "carol/th4"
path_state "teardown: th3 workspace actually gone" gone "$PM_STATE/workspaces/th3/carol"
path_state "teardown: th4 workspace actually gone" gone "$PM_STATE/workspaces/th4/carol"

# --all: a mix of a clean seat and bob's still-live one -- best-effort,
# both outcomes reported, non-zero exit because one seat was refused.
mkdir -p -- "$PM_STATE/workspaces/th5/dave"
td_out5="$("$fleet" teardown --all 2>&1)"; td_rc5=$?
check "teardown --all: exits 1 when any seat is refused" "1" "$td_rc5"
contains "teardown --all: reports the refused seat" "$td_out5" "run-bob"
contains "teardown --all: reports the cleanly torn down seat" "$td_out5" "dave/th5"
path_state "teardown --all: dave workspace actually gone" gone "$PM_STATE/workspaces/th5/dave"
path_state "teardown --all: bob (live) workspace untouched" present "$PM_STATE/workspaces/th2/bob"

# Once bob's run is no longer live, --all clears the rest and settles at
# "nothing to tear down" -- still exit 0, not an error.
rm -f -- "$PM_STATE/runs/run-bob.env"
"$fleet" teardown --all >/dev/null; td_rc6=$?
check "teardown --all: clean sweep once the run clears exits 0" "0" "$td_rc6"

td_out7="$("$fleet" teardown --all)"; td_rc7=$?
check "teardown --all: nothing left exits 0" "0" "$td_rc7"
contains "teardown --all: nothing-to-tear-down message" "$td_out7" "nothing to tear down"

# --thread is a path component, exactly like <agent>: a traversal value must
# not be able to steer the removal outside the state tree.
refuses "teardown: --thread with a '/' is refused" \
    "$fleet" teardown alice --thread "../escape"
refuses "teardown: --thread of '..' is refused" \
    "$fleet" teardown alice --thread ".."
refuses "teardown: --thread of '.' is refused" \
    "$fleet" teardown alice --thread "."

# eve/th6: the workspace's own git-dir lock is the authoritative liveness
# signal, checked in ADDITION to runs/*.env -- a workspace can be mid-clone
# for a wake the postmaster has not finished recording yet (no runs/*.env
# exists), and teardown must still refuse it rather than pull the clone out
# from under that in-flight run. Simulated by holding the same lock
# fork-sandbox-lib.sh's fs_lock_clone_dir takes, with no runs/*.env at all.
mkdir -p -- "$PM_STATE/workspaces/th6/eve/.git"
(
    exec {eve_lock_fd}<>"$PM_STATE/workspaces/th6/eve/.git/fork-sandbox-lock"
    flock "$eve_lock_fd"
    touch "$work/eve-lock-held"
    sleep 30
) &
eve_holder_pid=$!
for _ in $(seq 1 50); do
    [[ -e "$work/eve-lock-held" ]] && break
    sleep 0.1
done

td_out8="$("$fleet" teardown eve --thread th6 2>&1)"; td_rc8=$?
pkill -TERM -P "$eve_holder_pid" 2>/dev/null
kill "$eve_holder_pid" 2>/dev/null
wait "$eve_holder_pid" 2>/dev/null
rm -f -- "$work/eve-lock-held"

check "teardown: a workspace locked with no runs/*.env yet is refused" "1" "$td_rc8"
contains "teardown: names the workspace lock as the reason" "$td_out8" "locked"
path_state "teardown: locked-workspace seat untouched" present "$PM_STATE/workspaces/th6/eve"

# Once the lock is released, the same seat tears down normally.
"$fleet" teardown eve --thread th6 >/dev/null; td_rc9=$?
check "teardown: the same seat tears down once the lock clears" "0" "$td_rc9"
path_state "teardown: eve workspace gone once unlocked" gone "$PM_STATE/workspaces/th6/eve"

# A mid-flight routing pass holds the postmaster's own lock; teardown must
# not run against it (a sweep started under it could tear down a seat the
# router is about to spawn a wake for).
mkdir -p -- "$PM_STATE/workspaces/th7/frank"
(
    exec {pm_lock_fd}<>"$PM_STATE/lock"
    flock "$pm_lock_fd"
    touch "$work/pm-lock-held"
    sleep 30
) &
pm_holder_pid=$!
for _ in $(seq 1 50); do
    [[ -e "$work/pm-lock-held" ]] && break
    sleep 0.1
done

td_out10="$("$fleet" teardown frank --thread th7 2>&1)"; td_rc10=$?
pkill -TERM -P "$pm_holder_pid" 2>/dev/null
kill "$pm_holder_pid" 2>/dev/null
wait "$pm_holder_pid" 2>/dev/null
rm -f -- "$work/pm-lock-held"

check "teardown: refuses while the postmaster's own lock is held" "1" "$td_rc10"
contains "teardown: names the postmaster lock as the reason" "$td_out10" "lock"
path_state "teardown: seat untouched while the postmaster lock is held" \
    present "$PM_STATE/workspaces/th7/frank"

"$fleet" teardown frank --thread th7 >/dev/null; td_rc11=$?
check "teardown: the same seat tears down once the postmaster lock clears" "0" "$td_rc11"
path_state "teardown: frank workspace gone once the postmaster lock clears" \
    gone "$PM_STATE/workspaces/th7/frank"

unset FORK_SANDBOX_MAIL_ROOT

printf '\n== dispatcher wiring ==\n'

dispatcher="$repo_dir/scripts/fork-sandbox"
if [[ -x "$dispatcher" ]]; then
    "$dispatcher" fleet check >/dev/null 2>&1; disp_rc=$?
    check "fork-sandbox fleet check routes to the fleet script" "0" "$disp_rc"
    disp_roster="$("$dispatcher" fleet roster 2>&1)"
    check "fork-sandbox fleet roster output matches direct invocation" "$roster_out" "$disp_roster"
    disp_help="$("$dispatcher" fleet --help 2>&1)"
    contains "fork-sandbox fleet --help reaches the fleet script's header" "$disp_help" "fork-sandbox-fleet.sh"
    disp_mail_root="$(mktemp -d)"
    tmpdirs+=("$disp_mail_root")
    disp_teardown="$(FORK_SANDBOX_MAIL_ROOT="$disp_mail_root" "$dispatcher" fleet teardown --all 2>&1)"; disp_teardown_rc=$?
    check "fork-sandbox fleet teardown --all (empty root) routes through and exits 0" "0" "$disp_teardown_rc"
    contains "fork-sandbox fleet teardown --all (empty root) reports nothing to tear down" "$disp_teardown" "nothing to tear down"
else
    no "dispatcher wiring" "scripts/fork-sandbox is not executable"
fi

printf '\n== parser standalone: malformed YAML is a precise error, not a traceback ==\n'

malformed="$FORK_SANDBOX_FLEET_FILE_DIR/malformed.yaml"
printf 'agents: [\n' > "$malformed"
parse_err="$(python3 "$parse" check "$malformed" "$malformed" "$FORK_SANDBOX_PERSONAS_DIR" 2>&1)"; parse_rc=$?
check "parser standalone: malformed YAML exits 1" "1" "$parse_rc"
contains "parser standalone: names the YAML problem" "$parse_err" "not valid YAML"
case "$parse_err" in
    *"Traceback"*) no "parser standalone: no python traceback leaks out" "$parse_err" ;;
    *) ok "parser standalone: no python traceback leaks out" ;;
esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
