#!/usr/bin/env bash
# fork-sandbox-agent-kit-test.sh — The agent kit: machine-level extra skills
#
# Usage: tests/fork-sandbox-agent-kit-test.sh
#
# fork-sandbox.sh binds a fixed review kit into every run, and an operator can
# add skills of their own the same way: AGENT_KIT_SKILLS in kit.env, plus
# --kit-skill per launch. This suite covers how that list is resolved (order,
# dedup, the review-kit names dropped, loud failure before anything is
# created), how it behaves with --k8s, how each skill is bound, and what a run
# records about it.
#
# claude-sandboxed is stubbed out, the way tests/fork-sandbox-review-kit-bind-
# test.sh does it: it drains stdin, records its argv and exits 0, so no
# sandbox backend is exercised. HOME and FORK_SANDBOX_CONFIG_DIR point at
# temp dirs holding invented skills (kit-alpha, kit-beta).
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and a directory there breaks its Utilities table.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"

# Every run this suite launches is a fixture, not real work.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

# FLAG immediately followed by VALUE, one token per line in FILE.
argv_has_flag_value() {
    local file="$1" flag="$2" value="$3"
    awk -v f="$flag" -v v="$value" '
        pending { if ($0 == v) found = 1; pending = 0 }
        $0 == f { pending = 1 }
        END { exit !found }
    ' "$file"
}

stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-agent-kit-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$@" > "$FAKE_ARGV_FILE"
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# A fixture $HOME with skills kit-alpha and kit-beta (each with SKILL.md), the
# two review-kit skills, and one project. Prints: home, cfg dir, project.
new_env() {
    local home cfg proj n
    home="$(mktemp -d)"
    cfg="$(mktemp -d)"
    for n in kit-alpha kit-beta commit-then-review code-review-portable; do
        mkdir -p "$home/.claude/skills/$n"
        printf -- '---\nname: %s\n---\n' "$n" > "$home/.claude/skills/$n/SKILL.md"
    done
    proj="$home/src/proj"
    mkdir -p "$proj"
    (
        cd "$proj" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s\n%s\n%s\n' "$home" "$cfg" "$proj"
}

handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-agent-kit-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
printf 'do the task\n' > "$handoff_dir/handoff.md"

mapfile -t E < <(new_env)
home="${E[0]}" cfg="${E[1]}" proj="${E[2]}"
tmpdirs+=("$home" "$cfg")
skills="$home/.claude/skills"

bound() { argv_has_flag_value "$ARGV" --bind-ro "$skills/$1"; }
bind_count() { grep -cxF -- "$skills/$1" "$ARGV" || true; }

set_kit() { printf 'AGENT_KIT_SKILLS=%s\n' "$1" > "$cfg/kit.env"; }

# Runs the launcher against the fixture. Leaves the combined output in OUT,
# the exit status in RC and the stub's recorded argv path in ARGV.
launch() {
    ARGV="$(mktemp /var/tmp/claude-scratch/fs-agent-kit-argv.XXXXXX)"
    tmpdirs+=("$ARGV")
    OUT="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FAKE_ARGV_FILE="$ARGV" \
        timeout 60 "$launcher" "$@" 2>&1)"
    RC=$?
    local rd
    rd="$(printf '%s\n' "$OUT" | sed -n 's/^  run dir:  *//p' | head -1)"
    [[ -n "$rd" ]] && tmpdirs+=("$rd")
    return 0
}


# 1. Reads the machine list: spaces, commas, or both; quotes are tolerated.
printf '== the machine list ==\n'
run_fg() { launch --foreground --harness claude "$@" "$proj" "$handoff_dir/handoff.md"; }

set_kit '"kit-alpha kit-beta"'
run_fg
if (( RC == 0 )) && bound kit-alpha && bound kit-beta; then
    ok "space-separated, quoted list binds both skills"
else
    no "space-separated, quoted list binds both skills" "rc=$RC $OUT"
fi

set_kit 'kit-alpha,kit-beta'
run_fg
if (( RC == 0 )) && bound kit-alpha && bound kit-beta; then
    ok "comma-separated list binds both skills"
else
    no "comma-separated list binds both skills" "rc=$RC $OUT"
fi

set_kit 'kit-alpha, kit-beta'
run_fg
if (( RC == 0 )) && bound kit-alpha && bound kit-beta; then
    ok "comma-and-space list binds both skills"
else
    no "comma-and-space list binds both skills" "rc=$RC $OUT"
fi

rm -f "$cfg/kit.env"
run_fg
if (( RC == 0 )) && ! bound kit-alpha && ! bound kit-beta; then
    ok "no kit.env means an empty machine kit"
else
    no "no kit.env means an empty machine kit" "rc=$RC $OUT"
fi

printf 'SOMETHING_ELSE=1\n' > "$cfg/kit.env"
run_fg
if (( RC == 0 )) && ! bound kit-alpha; then
    ok "a kit.env without the key means an empty machine kit"
else
    no "a kit.env without the key means an empty machine kit" "rc=$RC $OUT"
fi

# 2. --kit-skill is additive.
printf '\n== --kit-skill ==\n'
rm -f "$cfg/kit.env"
run_fg --kit-skill kit-beta
if (( RC == 0 )) && bound kit-beta && ! bound kit-alpha; then
    ok "--kit-skill alone binds just that skill"
else
    no "--kit-skill alone binds just that skill" "rc=$RC $OUT"
fi

set_kit 'kit-alpha'
run_fg --kit-skill kit-beta
if (( RC == 0 )) && bound kit-alpha && bound kit-beta; then
    ok "--kit-skill adds to the machine list, it does not replace it"
else
    no "--kit-skill adds to the machine list, it does not replace it" "rc=$RC $OUT"
fi

# 3. Dedup and review-kit names.
printf '\n== dedup ==\n'
set_kit 'kit-alpha kit-alpha commit-then-review'
run_fg --kit-skill kit-alpha --kit-skill code-review-portable --kit-skill kit-beta
if (( RC == 0 )) && [[ "$(bind_count kit-alpha)" == 1 && "$(bind_count kit-beta)" == 1 ]]; then
    ok "a repeated name is bound once"
else
    no "a repeated name is bound once" "rc=$RC alpha=$(bind_count kit-alpha) beta=$(bind_count kit-beta)"
fi
if [[ "$(bind_count commit-then-review)" == 1 && "$(bind_count code-review-portable)" == 1 ]]; then
    ok "review kit names in the agent kit are dropped, not bound twice"
else
    no "review kit names in the agent kit are dropped, not bound twice" \
        "ctr=$(bind_count commit-then-review) crp=$(bind_count code-review-portable)"
fi
lacks "dropping a review kit name is silent" "kit" "$(printf '%s' "$OUT" | grep -i 'error\|warn\|notice' || true)"

# 4. Order: machine list first, then flags in the order given.
printf '\n== order ==\n'
set_kit 'kit-beta'
run_fg --kit-skill kit-alpha
order="$(grep -nxF -e "$skills/kit-alpha" -e "$skills/kit-beta" "$ARGV" | sed 's/^[0-9]*://' | tr '\n' ' ')"
if [[ "$order" == "$skills/kit-beta $skills/kit-alpha " ]]; then
    ok "the machine list is bound before --kit-skill names"
else
    no "the machine list is bound before --kit-skill names" "$order"
fi

# 5. Failures come before anything is created, naming skill and source.
printf '\n== loud failure ==\n'
fails() {
    local label="$1" want_name="$2" want_src="$3"
    shift 3
    run_fg "$@"
    if (( RC != 0 )) && [[ "$OUT" == *"$want_name"* && "$OUT" == *"$want_src"* ]]; then
        ok "$label"
    else
        no "$label" "rc=$RC $OUT"
    fi
    if [[ ! -s "$ARGV" && "$OUT" != *"run dir:"* ]]; then
        ok "$label: nothing was launched"
    else
        no "$label: nothing was launched" "$OUT"
    fi
}

rm -f "$cfg/kit.env"
fails "a bad --kit-skill name fails" "bad/name" "--kit-skill" --kit-skill bad/name
fails "a leading-dot --kit-skill name fails" ".hidden" "--kit-skill" --kit-skill .hidden
fails "a missing --kit-skill directory fails" "kit-gamma" "--kit-skill" --kit-skill kit-gamma
mkdir -p "$skills/kit-empty"
fails "a --kit-skill directory without SKILL.md fails" "kit-empty" "--kit-skill" --kit-skill kit-empty
set_kit 'kit-alpha bad/name'
fails "a bad kit.env name fails" "bad/name" "kit.env"
set_kit 'kit-gamma'
fails "a missing kit.env directory fails" "kit-gamma" "kit.env"
set_kit 'kit-empty'
fails "a kit.env directory without SKILL.md fails" "kit-empty" "kit.env"
rm -f "$cfg/kit.env"

# 6. --k8s.
printf '\n== --k8s ==\n'
cat > "$cfg/k8s.env" <<'K8S'
K8S_CONTEXT=example-context
K8S_NAMESPACE=fork-sandbox
K8S_IMAGE=registry.invalid/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=192.0.2.1:443
K8S_RUN_TTL=3600
K8S
k8s_run() {
    OUT="$(HOME="$home" PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        timeout 60 "$launcher" --k8s --dry-run --harness pi --model example/model "$@" \
        "$proj" "$handoff_dir/handoff.md" 2>&1)"
    RC=$?
}

k8s_run --kit-skill kit-alpha
if (( RC != 0 )) && [[ "$OUT" == *"--kit-skill is not supported with --k8s"* ]]; then
    ok "--kit-skill with --k8s is refused"
else
    no "--kit-skill with --k8s is refused" "rc=$RC $OUT"
fi

set_kit 'kit-alpha kit-gamma'
k8s_run
if (( RC == 0 )) && [[ "$OUT" == *"NOTICE:"*"kit-alpha kit-gamma"* ]]; then
    ok "a machine kit with --k8s prints a NOTICE naming the skills and does not fail"
else
    no "a machine kit with --k8s prints a NOTICE naming the skills and does not fail" "rc=$RC $OUT"
fi
lacks "the NOTICE is the only kit line: a missing host skill is not an error" "Error: agent kit" "$OUT"

rm -f "$cfg/kit.env"
k8s_run
if (( RC == 0 )) && [[ "$OUT" != *NOTICE* ]]; then
    ok "no machine kit, no NOTICE"
else
    no "no machine kit, no NOTICE" "rc=$RC $OUT"
fi
rm -f "$cfg/k8s.env"

# 7. --help documents it.
printf '\n== --help ==\n'
helptext="$("$launcher" --help 2>&1)"
contains "--help documents --kit-skill" "--kit-skill" "$helptext"
contains "--help documents kit.env" "kit.env" "$helptext"

# --- binding into each seat's command -------------------------------------
# A real (foreground) run with every wrapper stubbed and the backend faked into
# image mode, so pi resolves without a host install. The built commands are
# read back out of the run's run.sh.
printf '\n== binding: every seat ==\n'
img_stub="$(mktemp -d /var/tmp/claude-scratch/fs-agent-kit-img-stub.XXXXXX)"
tmpdirs+=("$img_stub")
for w in claude-sandboxed agent-sandboxed; do
    printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$img_stub/$w"
done
cat > "$img_stub/sandbox-backend-fake-image" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--capabilities" ]]; then
    printf 'toolchain=image\n'
    exit 0
fi
exit 0
STUB
chmod +x "$img_stub"/*
install -m 600 /dev/null "$cfg/pi.env"
printf 'OPENROUTER_API_KEY=fake\n' > "$cfg/pi.env"
mkdir -p "$cfg/presets"

# Leaves the run dir in RD ("" on failure).
launch_real() {
    local out rc
    out="$(HOME="$home" PATH="$img_stub:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        FORK_SANDBOX_BACKEND=fake-image \
        timeout 60 "$launcher" --foreground "$@" "$proj" "$handoff_dir/handoff.md" 2>&1)"
    rc=$?
    RD="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$RD" ]]; then
        printf 'launch_real failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        RD=""
        return 1
    fi
    tmpdirs+=("$RD")
}

# One assignment line of run.sh, e.g. cmd_line sandbox_cmd.
cmd_line() { grep "^$1=" "$RD/run.sh" | head -1; }

set_kit 'kit-alpha'
if launch_real --harness claude --review-loop 1 --model opus --review-model opus; then
    for v in sandbox_cmd review_sandbox_cmd; do
        contains "claude: $v binds the kit skill" "--bind-ro $skills/kit-alpha" "$(cmd_line $v)"
        lacks "claude: $v carries no --skill" "--skill $skills/kit-alpha" "$(cmd_line $v)"
    done
else
    no "claude run with a kit skill launches"
fi

if launch_real --harness pi --model example/model --review-loop 1; then
    contains "pi: the implement command binds the kit skill" \
        "--bind-ro $skills/kit-alpha" "$(cmd_line sandbox_cmd)"
    contains "pi: the implement command is handed --skill for it" \
        "--skill $skills/kit-alpha" "$(cmd_line sandbox_cmd)"
    contains "pi: the review leg (the implement command) is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line review_sandbox_cmd)"
else
    no "pi run with a kit skill launches"
fi

if launch_real --harness claude --model opus --review-loop 1 --review-harness pi --review-model example/model; then
    lacks "claude implement + pi review: the claude leg has no --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line sandbox_cmd)"
    contains "claude implement + pi review: the pi review leg is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line review_sandbox_cmd)"
    contains "claude implement + pi review: the pi review leg binds it" \
        "--bind-ro $skills/kit-alpha" "$(cmd_line review_sandbox_cmd)"
else
    no "claude implement + pi review launches"
fi

if launch_real --harness claude --model opus --review-loop 1 --review-harness pi \
    --review-model example/model --maintainer-loop 1 --maintainer-harness pi \
    --maintainer-model example/model; then
    contains "a named pi maintainer harness is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line maintainer_sandbox_cmd)"
else
    no "claude implement + pi review + pi maintainer launches"
fi

# A preset whose review seat is pi, in a legacy shape and a composed one.
cat > "$cfg/presets/pi-review.yaml" <<'YAML'
agents:
  coder:
    harness: claude
    model: opus
  reviewer:
    harness: pi
    model: example/model
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
YAML
if launch_real --preset pi-review; then
    contains "a legacy preset's pi review seat is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line review_sandbox_cmd)"
    lacks "a legacy preset's claude code seat is not" \
        "--skill $skills/kit-alpha" "$(cmd_line sandbox_cmd)"
else
    no "a legacy preset with a pi review seat launches"
fi

cat > "$cfg/presets/pi-composed.yaml" <<'YAML'
agents:
  coder:
    harness: pi
    model: example/model
  reviewer:
    harness: pi
    model: example/model
  checker:
    harness: claude
    model: opus
pipeline:
  - action: code
    agent: coder
  - action: review
    repeat: 1
    agent: reviewer
  - action: review
    repeat: 1
    agent: checker
YAML
if launch_real --preset pi-composed; then
    contains "a composed preset's pi code step is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line s1_sandbox_cmd)"
    contains "a composed preset's pi review step is handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line s2_sandbox_cmd)"
    contains "a composed preset's claude review step binds it" \
        "--bind-ro $skills/kit-alpha" "$(cmd_line s3_sandbox_cmd)"
    lacks "a composed preset's claude review step is not handed --skill" \
        "--skill $skills/kit-alpha" "$(cmd_line s3_sandbox_cmd)"
else
    no "a composed preset with a pi review seat launches"
fi
rm -f "$cfg/kit.env"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
