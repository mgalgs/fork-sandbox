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


printf '== the list resolves ==\n'
run_fg() { launch --foreground --harness claude "$@" "$proj" "$handoff_dir/handoff.md"; }

for spec in '"kit-alpha kit-beta"' 'kit-alpha,kit-beta' 'kit-alpha, kit-beta' \
            'kit-alpha kit-alpha commit-then-review'; do
    set_kit "$spec"
    run_fg --kit-skill kit-alpha --kit-skill code-review-portable
    if (( RC == 0 )); then
        ok "kit.env $spec resolves"
    else
        no "kit.env $spec resolves" "rc=$RC $OUT"
    fi
done
rm -f "$cfg/kit.env"
run_fg
if (( RC == 0 )); then
    ok "no kit.env means an empty machine kit"
else
    no "no kit.env means an empty machine kit" "rc=$RC $OUT"
fi
printf 'SOMETHING_ELSE=1\n' > "$cfg/kit.env"
run_fg
if (( RC == 0 )); then
    ok "a kit.env without the key means an empty machine kit"
else
    no "a kit.env without the key means an empty machine kit" "rc=$RC $OUT"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
