#!/usr/bin/env bash
# fork-sandbox-account-profile-test.sh -- account profiles
# (docs/account-profiles.md): profiles.env parsing and validation, the
# resolution tiers (flag, session, default), the repo guard rules, remote
# URL normalization, and the pod exemption -- as lib functions, sourced
# directly and called with fixture config dirs. Launcher wiring (run.env,
# sandbox_cmd, codex home, refusals before anything is created) is covered
# further down in this same file, against the real fork-sandbox.sh.
#
# Every fixture name is invented (alpha, beta, example.com/acme).
#
# Usage: tests/fork-sandbox-account-profile-test.sh

# shellcheck disable=SC2016  # literal shell snippets handed to fake_hook are intentional
set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# This suite decides for itself whether it looks like a Claude Code session
# or a pod; never inherit either from whatever runs it.
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR KUBERNETES_SERVICE_HOST

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

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

equals() {
    local label="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then ok "$label"; else no "$label" "want '$want', got '$got'"; fi
}

newdir() {
    local d
    d="$(mktemp -d)"
    tmpdirs+=("$d")
    printf '%s' "$d"
}

fake_cred() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf '{"claudeAiOauth":{"accessToken":"fixture"}}\n' > "$path"
    printf '%s' "$path"
}

fake_hook() {
    local name="$1" body="$2" bindir
    bindir="$(newdir)"
    cat > "$bindir/fork-sandbox-headroom-$name" <<HOOK
#!/usr/bin/env bash
$body
HOOK
    chmod +x "$bindir/fork-sandbox-headroom-$name"
    printf '%s' "$bindir"
}

script_dir="$repo_dir/scripts"

# Loads $1's profiles.env; prints stderr and the return code.
load_err() {
    local err rc
    err="$(fs_profiles_load "$1" 2>&1)"; rc=$?
    printf '%s\nrc=%s' "$err" "$rc"
}

# A standard two-profile fixture: alpha has a two-entry pool and a codex
# home, beta one credential and no codex.
std_fixture() {
    local d="$1"
    a1="$(fake_cred "$d/creds/alpha-1.json")"
    a2="$(fake_cred "$d/creds/alpha-2.json")"
    b1="$(fake_cred "$d/creds/beta-1.json")"
    mkdir -p "$d/codex-alpha"
    {
        printf '# invented fixture\n\n'
        printf 'PROFILE_alpha_CLAUDE_POOL=%s:%s\n' "$a1" "$a2"
        printf 'PROFILE_alpha_CODEX_HOME=%s\n' "$d/codex-alpha"
        printf 'PROFILE_beta_CLAUDE_POOL=%s\n' "$b1"
    } > "$d/profiles.env"
    printf 'CLAUDE_HEADROOM_HOOK=pick\n' > "$d/claude.env"
}

printf '== parsing and validation ==\n'

d="$(newdir)"
fs_profiles_load "$d"; rc=$?
equals "no profiles.env: loads inactive" "0/0" "$rc/$FS_PROFILES_ACTIVE"

d="$(newdir)"; std_fixture "$d"
if fs_profiles_load "$d"; then
    equals "valid file: active" 1 "$FS_PROFILES_ACTIVE"
    equals "valid file: profile names in order" "alpha beta" "${FS_PROFILE_NAMES[*]}"
    equals "valid file: alpha's pool" "$a1:$a2" "${FS_PROFILE_POOL[alpha]}"
    equals "valid file: alpha's codex home" "$d/codex-alpha" "${FS_PROFILE_CODEX[alpha]}"
    equals "valid file: beta has no codex home" "" "${FS_PROFILE_CODEX[beta]:-}"
    equals "valid file: membership is indexed" "beta" "${FS_PROFILE_OF[$b1]}"
else
    no "valid file loads" "$(load_err "$d")"
fi

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_beta_CLAUDE_POOL=%s\n' "$a1" > "$d/profiles.env.tmp"
{ grep -v '^PROFILE_beta' "$d/profiles.env"; cat "$d/profiles.env.tmp"; } > "$d/p" && mv "$d/p" "$d/profiles.env"
contains "duplicate credential across profiles is refused" \
    "is in profile 'alpha'" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'CLAUDE_CREDENTIAL_POOL=%s\nCLAUDE_HEADROOM_HOOK=pick\n' "$a1" > "$d/claude.env"
out="$(load_err "$d")"
contains "CLAUDE_CREDENTIAL_POOL + profiles is refused" \
    "claude.env sets CLAUDE_CREDENTIAL_POOL" "$out"
contains "... with a nonzero return" "rc=1" "$out"

d="$(newdir)"; std_fixture "$d"
printf 'CLAUDE_CREDENTIALS=%s\n' "$a1" > "$d/claude.env"
contains "CLAUDE_CREDENTIALS + profiles is refused" \
    "claude.env sets CLAUDE_CREDENTIALS" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
: > "$d/claude.env"
contains "a multi-entry pool with no CLAUDE_HEADROOM_HOOK is refused" \
    "sets no CLAUDE_HEADROOM_HOOK" "$(load_err "$d")"

d="$(newdir)"
b1="$(fake_cred "$d/b.json")"
printf 'PROFILE_beta_CLAUDE_POOL=%s\n' "$b1" > "$d/profiles.env"
fs_profiles_load "$d"; rc=$?
equals "a one-entry pool needs no hook" "0/1" "$rc/$FS_PROFILES_ACTIVE"

d="$(newdir)"; std_fixture "$d"
printf 'DEFAULT_PROFILE=gamma\n' >> "$d/profiles.env"
contains "DEFAULT_PROFILE naming no profile is refused" \
    "DEFAULT_PROFILE='gamma'" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'REPO_RULE=example.com/acme/* gamma\n' >> "$d/profiles.env"
contains "REPO_RULE naming no profile is refused" "names no defined profile" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'REPO_RULE=example.com/acme/*\n' >> "$d/profiles.env"
contains "REPO_RULE without a profile is refused" "REPO_RULE takes" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_gamma_CODEX_HOME=%s\n' "$d" >> "$d/profiles.env"
contains "a profile with no Claude pool is refused" \
    "has no PROFILE_gamma_CLAUDE_POOL" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_Gamma_CLAUDE_POOL=/x.json\n' >> "$d/profiles.env"
contains "an uppercase profile name is refused" "profile name 'Gamma'" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_gamma_CLAUDE_POOL=relative.json\n' >> "$d/profiles.env"
contains "a relative pool entry is refused" "is not an" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_gamma_CLAUDE_POOL=/x.json\nPROFILE_gamma_CODEX_HOME=rel\n' >> "$d/profiles.env"
contains "a relative codex home is refused" "is not an absolute path" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_gamma_CLAUDE_POOL=/x.json::/y.json\n' >> "$d/profiles.env"
contains "an empty pool entry is refused" "has an empty entry" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'CLAUDE_CREDENTIAL_POOL=/x.json\n' >> "$d/profiles.env"
contains "an unknown key is refused" "unknown key 'CLAUDE_CREDENTIAL_POOL'" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'PROFILE_beta_CLAUDE_POOL=/x.json\n' >> "$d/profiles.env"
contains "a key set twice is refused" "sets PROFILE_beta_CLAUDE_POOL twice" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf 'just words\n' >> "$d/profiles.env"
contains "a line that is not KEY=VALUE is refused" "is not KEY=VALUE" "$(load_err "$d")"

d="$(newdir)"; std_fixture "$d"
printf '$(touch %s/sourced)\n' "$d" >> "$d/profiles.env"
load_err "$d" >/dev/null
if [[ -e "$d/sourced" ]]; then no "profiles.env is never sourced"; else ok "profiles.env is never sourced"; fi

printf '\n== remote URL normalization ==\n'
for url in git@example.com:acme/widget.git ssh://git@example.com/acme/widget.git \
    ssh://git@example.com:2222/acme/widget https://example.com/acme/widget.git \
    https://user@EXAMPLE.com/acme/widget/ http://example.com:8080/acme/widget; do
    equals "$url normalizes to example.com/acme/widget" \
        "example.com/acme/widget" "$(fs_normalize_remote_url "$url")"
done
equals "a local path is left as the path" "/srv/git/widget" \
    "$(fs_normalize_remote_url /srv/git/widget.git)"

printf '\n== resolution tiers ==\n'

# resolve <cfg> <flag> <needs_claude> <needs_codex> [project]
resolve() {
    fs_resolve_account_profile "$1" "$script_dir" "$2" "$3" "$4" "${5:-}"
}
resolve_err() {
    local err rc
    err="$( resolve "$@" 2>&1 >/dev/null)"; rc=$?
    printf '%s\nrc=%s' "$err" "$rc"
}

d="$(newdir)"
resolve "$d" "" true true; rc=$?
equals "no profiles.env: via none, nothing chosen" "0/none//default" \
    "$rc/$FS_PROFILE_VIA/$FS_PROFILE/$FS_PROFILE_CLAUDE_VIA"

d="$(newdir)"; std_fixture "$d"
hook_bin="$(fake_hook pick 'printf "%s\n" "$2"')"
PATH="$hook_bin:$PATH" resolve "$d" "$b1" true false; rc=$?
equals "flag tier: the profile containing the pinned path" "0/flag/beta" "$rc/$FS_PROFILE_VIA/$FS_PROFILE"
equals "flag tier: the pinned path is used as given" "flag/$b1" "$FS_PROFILE_CLAUDE_VIA/$FS_PROFILE_CLAUDE_CRED"

PATH="$hook_bin:$PATH" resolve "$d" "$a1" true false
equals "flag tier: a pinned path in a multi-entry pool is used as given, no hook" \
    "flag/alpha/$a1" "$FS_PROFILE_CLAUDE_VIA/$FS_PROFILE/$FS_PROFILE_CLAUDE_CRED"

stray="$(fake_cred "$d/stray.json")"
out="$(resolve_err "$d" "$stray" true false)"
contains "flag tier: a pinned path in no profile is refused" "which is in no" "$out"
contains "... naming the path" "$stray" "$out"

# Session tier: CLAUDE_CONFIG_DIR's .credentials.json is the session login.
sess="$(newdir)"
cp "$b1" "$sess/.credentials.json"
printf 'PROFILE_beta_CLAUDE_POOL=%s\n' "$sess/.credentials.json" > "$d/p" \
    && grep -v '^PROFILE_beta' "$d/profiles.env" >> "$d/p" && mv "$d/p" "$d/profiles.env"
CLAUDECODE=1 CLAUDE_CONFIG_DIR="$sess" PATH="$hook_bin:$PATH" resolve "$d" "" true false; rc=$?
equals "session tier (CLAUDECODE): the profile holding the session's login" \
    "0/session/beta/profile" "$rc/$FS_PROFILE_VIA/$FS_PROFILE/$FS_PROFILE_CLAUDE_VIA"
CLAUDE_CODE_SESSION_ID=fixture-session CLAUDE_CONFIG_DIR="$sess" resolve "$d" "" true false
equals "session tier (CLAUDE_CODE_SESSION_ID alone also counts)" "session/beta" "$FS_PROFILE_VIA/$FS_PROFILE"

other="$(newdir)"
cp "$b1" "$other/.credentials.json"
out="$(CLAUDECODE=1 CLAUDE_CONFIG_DIR="$other" resolve_err "$d" "" true false)"
contains "session tier: a session login in no profile is refused" "is in no account profile" "$out"
contains "... naming the file" "$other/.credentials.json" "$out"
printf 'DEFAULT_PROFILE=alpha\n' >> "$d/profiles.env"
out="$(CLAUDECODE=1 CLAUDE_CONFIG_DIR="$other" resolve_err "$d" "" true false)"
contains "session tier: the refusal holds even with a DEFAULT_PROFILE set" "is in no account profile" "$out"

CLAUDECODE=1 CLAUDE_CONFIG_DIR="$other" PATH="$hook_bin:$PATH" resolve "$d" "$a2" true false
equals "a pinned flag beats the session tier" "flag/alpha" "$FS_PROFILE_VIA/$FS_PROFILE"

PATH="$hook_bin:$PATH" resolve "$d" "" true false; rc=$?
equals "default tier: DEFAULT_PROFILE, pool balanced by the hook" \
    "0/default/alpha/balance/$a2" "$rc/$FS_PROFILE_VIA/$FS_PROFILE/$FS_PROFILE_CLAUDE_VIA/$FS_PROFILE_CLAUDE_CRED"

grep -v '^DEFAULT_PROFILE' "$d/profiles.env" > "$d/p" && mv "$d/p" "$d/profiles.env"
out="$(resolve_err "$d" "" true false)"
contains "no session and no default: refused" "no Claude Code" "$out"
contains "... saying how to choose" "set DEFAULT_PROFILE" "$out"

resolve "$d" "" false false; rc=$?
equals "a run with no claude/codex leg and no pin resolves nothing" "0/none" "$rc/$FS_PROFILE_VIA"

printf '\n== the hook inside a profile ==\n'
d="$(newdir)"; std_fixture "$d"
printf 'DEFAULT_PROFILE=alpha\n' >> "$d/profiles.env"
argv_log="$d/hook-argv"
hook_bin="$(fake_hook pick "printf '%s\n' \"\$*\" > '$argv_log'; printf '%s\n' \"\$1\"")"
PATH="$hook_bin:$PATH" resolve "$d" "" true false
equals "the hook is handed only the profile's own pool" "$a1 $a2" "$(cat "$argv_log")"
hook_bin="$(fake_hook pick 'exit 2')"
contains "hook exit 2 inside a profile is a hard error" "no routable credential" \
    "$(PATH="$hook_bin:$PATH" resolve_err "$d" "" true false)"
hook_bin="$(fake_hook pick 'exit 7')"
out="$(PATH="$hook_bin:$PATH" resolve "$d" "" true false 2>&1; printf '|%s|%s' "$FS_PROFILE_CLAUDE_VIA" "$FS_PROFILE_CLAUDE_CRED")"
contains "a crashed hook warns" "exited 7" "$out"
contains "... and falls back inside the profile, never outside it" "|profile|$a1" "$out"
hook_bin="$(fake_hook pick 'echo /not/a/candidate.json')"
contains "a hook choosing outside the profile's pool is refused" "is not one" \
    "$(PATH="$hook_bin:$PATH" resolve_err "$d" "" true false)"

printf '\n== codex home ==\n'
d="$(newdir)"; std_fixture "$d"
resolve "$d" "$a1" false true
equals "a codex leg gets the profile's codex home" "$d/codex-alpha" "$FS_PROFILE_CODEX_HOME"
out="$(resolve_err "$d" "$b1" false true)"
contains "a codex leg under a profile with no codex home is refused" "has no codex login" "$out"
contains "... naming the profile" "'beta'" "$out"
resolve "$d" "$b1" true false; rc=$?
equals "a no-codex profile is fine for a run with no codex leg" 0 "$rc"

printf '\n== repo guard rules ==\n'
d="$(newdir)"; std_fixture "$d"
{
    printf 'REPO_RULE=example.com/acme/* alpha\n'
    printf 'REPO_RULE=example.com/* beta\n'
} >> "$d/profiles.env"
mkrepo() {
    local r
    r="$(newdir)"
    git -C "$r" init -q
    [[ -n "$1" ]] && git -C "$r" remote add origin "$1"
    printf '%s' "$r"
}
hook_bin="$(fake_hook pick 'printf "%s\n" "$1"')"
r_ssh="$(mkrepo git@example.com:acme/widget.git)"
r_https="$(mkrepo https://example.com/acme/widget)"
r_other="$(mkrepo https://example.com/solo/widget)"
r_nomatch="$(mkrepo https://example.org/acme/widget)"
r_none="$(mkrepo "")"
out="$(resolve_err "$d" "$b1" true false "$r_ssh")"
contains "rule mismatch (ssh remote) is refused" "requires account profile" "$out"
contains "... naming the repo" "example.com/acme/widget" "$out"
contains "... the rule" "REPO_RULE=example.com/acme/*" "$out"
contains "... the required profile" "'alpha'" "$out"
contains "... and the resolved one" "resolved profile" "$out"
contains "rule mismatch (https remote of the same repo) is refused the same way" \
    "requires account profile" "$(resolve_err "$d" "$b1" true false "$r_https")"
PATH="$hook_bin:$PATH" resolve "$d" "$a1" true false "$r_https"; rc=$?
equals "rule match with the right profile is allowed" 0 "$rc"
resolve "$d" "$b1" true false "$r_other"; rc=$?
equals "the first matching rule wins (example.com/* -> beta)" 0 "$rc"
contains "... and a later rule never rescues an earlier mismatch" "'beta'" \
    "$(resolve_err "$d" "$a1" true false "$r_other")"
resolve "$d" "$b1" true false "$r_nomatch"; rc=$?
equals "no matching rule: no constraint" 0 "$rc"
resolve "$d" "$b1" true false "$r_none"; rc=$?
equals "no origin remote: matches nothing" 0 "$rc"

printf '\n== inside a pod, profiles are never consulted ==\n'
d="$(newdir)"; std_fixture "$d"
# The postmaster pod's own claude.env: a pool, which profiles would refuse.
printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\nCLAUDE_HEADROOM_HOOK=pick\n' "$a1" "$a2" > "$d/claude.env"
hook_bin="$(fake_hook pick 'printf "%s\n" "$2"')"
KUBERNETES_SERVICE_HOST=192.0.2.1 fs_profiles_load "$d"; rc=$?
equals "in a pod: profiles.env is not loaded" "0/0" "$rc/$FS_PROFILES_ACTIVE"
KUBERNETES_SERVICE_HOST=192.0.2.1 CLAUDECODE=1 CLAUDE_CONFIG_DIR="$(newdir)" \
    resolve "$d" "" true true; rc=$?
equals "in a pod: no profile and no session lookup, via none" "0/none" "$rc/$FS_PROFILE_VIA"
out="$(KUBERNETES_SERVICE_HOST=192.0.2.1 PATH="$hook_bin:$PATH" \
    fs_balance_claude_credential "$d" "$script_dir" 2>&1)"; rc=$?
equals "in a pod: the in-pod pool path balances exactly as before" "0/$a2" "$rc/$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
