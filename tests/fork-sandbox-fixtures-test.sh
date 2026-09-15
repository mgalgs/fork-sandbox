#!/usr/bin/env bash
# fork-sandbox-fixtures-test.sh — fixture staging reaches the local backend.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -e "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

# Keep the backend separator in the assertion: an agent argument after -- is
# not evidence that the backend received a launcher flag.
argv_has_flag_value() {
    awk -v flag="$2" -v value="$3" '
        $0 == "--" { after = 1 }
        !after && prev == flag && $0 == value { found = 1 }
        { prev = $0 }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

work="$(mktemp -d /var/tmp/claude-scratch/forks/fs-fixtures-test.XXXXXX)"; tmpdirs+=("$work")
home="$work/home"; mkdir -p "$home/src" "$work/bin" "$work/config"
project="$home/src/project"; mkdir "$project"
git -C "$project" init -q
git -C "$project" -c user.name=Test -c user.email=test@fork-sandbox.invalid commit --allow-empty -qm init
handoff="/var/tmp/claude-scratch/fs-fixtures-handoff-$$.md"; tmpdirs+=("$handoff")
printf 'test fixtures\n' > "$handoff"
fixtures="$work/fixtures"; mkdir "$fixtures"

ln -s "$repo_dir/scripts/agent-sandboxed" "$work/bin/agent-sandboxed"
cat > "$work/bin/pi" <<'STUB'
process.exit(0);
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"fixture-model"}]}'
STUB
cat > "$work/bin/sandbox-backend-test" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then printf 'toolchain=host\n'; exit 0; fi
printf '%s\n' "$@" > "$FIXTURE_ARGV"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
[[ $# -eq 0 ]] || { shift; "$@"; }
STUB
chmod +x "$work/bin/pi" "$work/bin/curl" "$work/bin/sandbox-backend-test"
printf 'MODEL_ENDPOINT=http://127.0.0.1:8080/v1\n' > "$work/config/model.env"

run_launcher() {
    local fixture_arg="$1" capture="$2"
    local -a args=(--foreground --harness pi-local)
    [[ -z "$fixture_arg" ]] || args+=(--fixtures "$fixture_arg")
    HOME="$home" PATH="$work/bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$work/config" \
        FORK_SANDBOX_RUN_SOURCE=test FORK_SANDBOX_BACKEND=test FIXTURE_ARGV="$capture" \
        timeout 30 "$launcher" "${args[@]}" \
        "$project" "$handoff" 2>&1
}

capture="$work/backend-argv"
out="$(run_launcher "$fixtures" "$capture")"; rc=$?
if (( rc == 0 )) && argv_has_flag_value "$capture" --bind-ro-at "$fixtures"; then
    # --bind-ro-at has two values, so its fixed destination is independently
    # checked immediately after the source pair.
    if awk -v src="$fixtures" '$0 == "--bind-ro-at" { getline; if ($0 == src) { getline; if ($0 == "/fixtures") found = 1 } } END { exit(!found) }' "$capture"; then
        ok "--fixtures binds the requested directory read-only at /fixtures"
    else
        no "--fixtures binds the requested directory read-only at /fixtures" "$(cat "$capture")"
    fi
else
    no "--fixtures binds the requested directory read-only at /fixtures" "$out"
fi
if (( rc == 0 )) && argv_has_flag_value "$capture" --setenv FORK_SANDBOX_FIXTURE_DIR=/fixtures; then
    ok "--fixtures exports its fixed fixture directory variable"
else
    no "--fixtures exports its fixed fixture directory variable" "${out:-$(cat "$capture" 2>/dev/null)}"
fi

missing="$work/no-such-fixtures"
out="$(run_launcher "$missing" "$work/missing-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$missing"* && "$out" == *"does not exist"* ]]; then ok "missing fixture directory is refused by name"; else no "missing fixture directory is refused by name" "$out"; fi

file="$work/fixture-file"; : > "$file"
out="$(run_launcher "$file" "$work/file-argv")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"$file"* && "$out" == *"not a directory"* ]]; then ok "fixture file is refused"; else no "fixture file is refused" "$out"; fi

plain="$work/plain-argv"
out="$(run_launcher "" "$plain")"; rc=$?
if (( rc == 0 )) && ! argv_has_flag_value "$plain" --setenv FORK_SANDBOX_FIXTURE_DIR=/fixtures && ! grep -qx -- '/fixtures' "$plain"; then
    ok "absent --fixtures adds neither bind nor variable"
else
    no "absent --fixtures adds neither bind nor variable" "${out:-$(cat "$plain" 2>/dev/null)}"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
