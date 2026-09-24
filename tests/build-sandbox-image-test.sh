#!/usr/bin/env bash
# build-sandbox-image-test.sh -- scripts/build-sandbox-image.sh's --postmaster
# mode, and a pinned check that plain (non-postmaster) builds are unchanged
#
# Usage: tests/build-sandbox-image-test.sh
#
# Runs entirely offline against a stub `docker` on PATH that records its argv
# instead of building anything. Driven against a scratch git repo copy (never
# the real checkout under test) so the dirty/clean and commit-sha assertions
# can control git state freely without touching this repo's own history.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
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

# A scratch checkout: just enough of the tree for build-sandbox-image.sh to
# find its two Dockerfiles, under its own git history -- so the dirty-tree
# and commit-sha checks below can control git state without ever touching
# $repo_dir.
scratch="$(newdir)"; tmpdirs+=("$scratch")
mkdir -p "$scratch/scripts" "$scratch/images/sandbox" "$scratch/images/postmaster"
cp "$repo_dir/scripts/build-sandbox-image.sh" "$scratch/scripts/build-sandbox-image.sh"
chmod +x "$scratch/scripts/build-sandbox-image.sh"
cat > "$scratch/images/sandbox/Dockerfile" <<'EOF'
FROM scratch
EOF
cat > "$scratch/images/postmaster/Dockerfile" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
EOF
git -C "$scratch" init -q
git -C "$scratch" config user.email t@fork-sandbox.invalid
git -C "$scratch" config user.name Tester
git -C "$scratch" add -A
git -C "$scratch" commit -q -m init
scratch_sha="$(git -C "$scratch" rev-parse --short HEAD)"

script="$scratch/scripts/build-sandbox-image.sh"

# A stub `docker` that records the argv of its `build` call (only) into
# $DOCKER_RECORD, one argument per line, and no-ops everything else (`run
# --rm --entrypoint cat ... /etc/fork-sandbox-image`, called unconditionally
# after a successful build to print what's inside it).
bindir="$(newdir)"; tmpdirs+=("$bindir")
cat > "$bindir/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == build ]]; then
    : > "$DOCKER_RECORD"
    for a in "$@"; do printf '%s\n' "$a" >> "$DOCKER_RECORD"; done
fi
exit 0
EOF
chmod +x "$bindir/docker"

record="$(newdir)/record.txt"; tmpdirs+=("$(dirname "$record")")
run_build() {
    DOCKER_RECORD="$record" PATH="$bindir:$PATH" "$script" "$@"
}

printf '\n== --postmaster requires --base ==\n'
rm -f "$record"
refuses "--postmaster without --base refuses" "requires --base" \
    run_build --postmaster
if [[ -s "$record" ]]; then
    no "--postmaster without --base never calls docker build" "$(cat "$record")"
else
    ok "--postmaster without --base never calls docker build"
fi

printf '\n== --postmaster refuses --claude/--codex/--pi ==\n'
rm -f "$record"
refuses "--postmaster --claude refuses" "do not apply to --postmaster" \
    run_build --postmaster --base registry.example/you/fork-sandbox:latest --claude none
check "--postmaster --claude never calls docker build" "" "$([[ -s "$record" ]] && cat "$record" || true)"
rm -f "$record"
refuses "--postmaster --codex refuses" "do not apply to --postmaster" \
    run_build --postmaster --base registry.example/you/fork-sandbox:latest --codex none
rm -f "$record"
refuses "--postmaster --pi refuses" "do not apply to --postmaster" \
    run_build --postmaster --base registry.example/you/fork-sandbox:latest --pi 1.2.3

printf '\n== plain build refuses --base ==\n'
rm -f "$record"
refuses "plain build --base refuses" "only applies to --postmaster" \
    run_build --base registry.example/you/fork-sandbox:latest
check "plain build --base never calls docker build" "" "$([[ -s "$record" ]] && cat "$record" || true)"

printf '\n== --postmaster --base renders the expected build ==\n'
rm -f "$record"
if run_build --postmaster --base registry.example/you/fork-sandbox:latest >/tmp/bsi-test-out.log 2>&1; then
    ok "--postmaster --base exits 0"
else
    no "--postmaster --base exits 0" "$(cat /tmp/bsi-test-out.log)"
fi
rm -f /tmp/bsi-test-out.log
argv="$(cat "$record")"
if grep -qxF -- "--file" <<< "$argv" && grep -qxF "$scratch/images/postmaster/Dockerfile" <<< "$argv"; then
    ok "argv names the postmaster Dockerfile with --file"
else
    no "argv names the postmaster Dockerfile with --file" "$argv"
fi
if grep -qxF "$scratch" <<< "$argv"; then
    ok "argv's build context is the repo root"
else
    no "argv's build context is the repo root" "$argv"
fi
if grep -qxF "BASE_IMAGE=registry.example/you/fork-sandbox:latest" <<< "$argv"; then
    ok "argv carries --build-arg BASE_IMAGE"
else
    no "argv carries --build-arg BASE_IMAGE" "$argv"
fi
scratch_commit="$(git -C "$scratch" rev-parse HEAD)"
if grep -qxF "FORK_SANDBOX_COMMIT=$scratch_commit" <<< "$argv"; then
    ok "argv carries --build-arg FORK_SANDBOX_COMMIT (full sha)"
else
    no "argv carries --build-arg FORK_SANDBOX_COMMIT (full sha)" "$argv"
fi
check "default tag is fork-sandbox-postmaster:<short sha> on a clean tree" \
    "fork-sandbox-postmaster:$scratch_sha" "$(grep -A1 -xF -- '--tag' <<< "$argv" | tail -1)"

printf '\n== a dirty tree appends -dirty to the default tag ==\n'
echo dirty >> "$scratch/images/sandbox/Dockerfile"
rm -f "$record"
err="$(run_build --postmaster --base registry.example/you/fork-sandbox:latest 2>&1 >/dev/null)"
argv="$(cat "$record")"
check "dirty tree: default tag carries -dirty" \
    "fork-sandbox-postmaster:${scratch_sha}-dirty" "$(grep -A1 -xF -- '--tag' <<< "$argv" | tail -1)"
if [[ "$err" == *"dirty"* ]]; then
    ok "dirty tree: warns on stderr"
else
    no "dirty tree: warns on stderr" "$err"
fi
git -C "$scratch" checkout -q -- images/sandbox/Dockerfile

printf '\n== --tag still overrides the default ==\n'
rm -f "$record"
run_build --postmaster --base registry.example/you/fork-sandbox:latest --tag custom:tag >/dev/null 2>&1
argv="$(cat "$record")"
check "--tag overrides the postmaster default" \
    "custom:tag" "$(grep -A1 -xF -- '--tag' <<< "$argv" | tail -1)"

printf '\n== plain build argv is unchanged from today (pinned) ==\n'
rm -f "$record"
run_build >/dev/null 2>&1
argv="$(cat "$record")"
read -r -d '' expected_argv <<EOF || true
build
--tag
fork-sandbox:latest
--build-arg
CLAUDE_VERSION=latest
--build-arg
CODEX_VERSION=latest
--build-arg
PI_VERSION=latest
$scratch/images/sandbox
EOF
check "plain build argv matches the pinned baseline" "$expected_argv" "$argv"

printf '\n== plain build ignores --postmaster-only state ==\n'
rm -f "$record"
run_build --tag mine:latest --claude none --codex none --pi 1.2.3 --no-cache >/dev/null 2>&1
argv="$(cat "$record")"
read -r -d '' expected_argv2 <<EOF || true
build
--tag
mine:latest
--build-arg
CLAUDE_VERSION=none
--build-arg
CODEX_VERSION=none
--build-arg
PI_VERSION=1.2.3
--no-cache
$scratch/images/sandbox
EOF
check "plain build with flags still matches the expected argv shape" "$expected_argv2" "$argv"

printf '\n=== %d ok / %d fail ===\n' "$pass" "$fail"
(( fail == 0 ))
