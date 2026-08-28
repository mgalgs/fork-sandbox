#!/usr/bin/env bash
# fork-sandbox-prompt-overlay-test.sh — Exercise the machine-local prompt overlay
#
# Usage: tests/fork-sandbox-prompt-overlay-test.sh
#
# Covers fork-sandbox.sh's --prompts-dir mechanism (docs/prompt-overlays.md):
# resolving the source directory, composing its fragments in order, sanitising
# a model id for use as a file name, the dirty-repo provenance rule, and the
# one property that matters most -- a machine with no prompts directory gets a
# byte-identical prompt to a run made before this mechanism existed.
#
# Most of this is testable through --dry-run, which resolves the overlay and
# prints it without creating anything (cheap, like fork-sandbox-alias-test.sh).
# The composition and provenance-file cases need the actual rendered
# handoff.md and prompt-overlay.json, so those run fork-sandbox.sh for real,
# with --foreground and claude-sandboxed stubbed out: the stub only reads
# stdin and exits 0, so no sandbox is ever created and no bwrap/container
# backend is exercised -- this is testing the host-side script only, up to and
# including the point where it would hand off to the sandbox wrapper.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the Utilities
# table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
launcher="$repo_dir/scripts/fork-sandbox.sh"
run_log="$repo_dir/scripts/sandbox-run-log.py"

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
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

# A config dir with no prompts/ subdirectory: the every-day case, "nobody has
# configured an overlay here". FORK_SANDBOX_CONFIG_DIR is pointed here (never
# at the real ~/.config/fork-sandbox) so a run on this machine cannot leak the
# real user's aliases.conf or prompts into the test.
#
# Registering the result with tmpdirs is the CALLER's job, not this
# function's: every caller captures the path with `x="$(new_empty_config)"`,
# and command substitution runs the function in a subshell, so an append to
# tmpdirs made inside it vanishes with that subshell instead of reaching the
# array the EXIT trap actually reads.
new_empty_config() {
    mktemp -d
}

# --dry-run resolves and prints the harness, model and prompt overlay without
# creating anything.
dry() {
    local config="$1"; shift
    FORK_SANDBOX_CONFIG_DIR="$config" "$launcher" --dry-run "$@" \
        unused-project unused-handoff
}

printf '== --dry-run: resolving the source directory ==\n'

config="$(new_empty_config)"; tmpdirs+=("$config")
out="$(dry "$config" --harness claude 2>/dev/null)"
check "default directory is \$config_dir/prompts" \
    "$config/prompts" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_dir=//p')"
check "default directory being absent leaves fragments empty" \
    "" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"
err="$(dry "$config" --harness claude 2>&1 >/dev/null)"
check "an absent default directory is completely silent" "" "$err"

envdir="$(mktemp -d)"; tmpdirs+=("$envdir")
mkdir -p "$envdir/all-override"
printf 'x\n' > "$envdir/all-override/all.md"
out="$(FORK_SANDBOX_PROMPTS_DIR="$envdir/all-override" dry "$config" --harness claude 2>/dev/null)"
check "FORK_SANDBOX_PROMPTS_DIR overrides the default" \
    "$envdir/all-override" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_dir=//p')"

if dry "$config" --harness claude --prompts-dir "$config/does-not-exist" \
    >/dev/null 2>"$config/err"; then
    no "--prompts-dir naming nothing is refused"
else
    contains "--prompts-dir naming nothing is refused" \
        "does not exist" "$(cat "$config/err")"
fi

mkdir -p "$config/empty-explicit"
out="$(dry "$config" --harness pi --model demo-model \
    --prompts-dir "$config/empty-explicit" 2>"$config/err")"
check "an explicit but empty directory still resolves (no crash)" \
    "$config/empty-explicit" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_dir=//p')"
err="$(cat "$config/err")"
contains "an explicit directory matching nothing warns" \
    "matched" "$err"
contains "the warning says no fragment was found" \
    "no fragment" "$err"
contains "the warning names the harness path it looked for" \
    "$config/empty-explicit/harness/pi.md" "$err"
contains "the warning names the model path it looked for" \
    "$config/empty-explicit/model/demo-model.md" "$err"

printf '\n== --dry-run: fragment composition order ==\n'

pdir="$(mktemp -d)"; tmpdirs+=("$pdir")
mkdir -p "$pdir/harness" "$pdir/model"
printf 'all\n' > "$pdir/all.md"
printf 'harness\n' > "$pdir/harness/claude.md"
printf 'model\n' > "$pdir/model/some-model.md"
out="$(dry "$config" --harness claude --model some-model --prompts-dir "$pdir" 2>/dev/null)"
check "all three fragments compose, general first, model last" \
    "all.md,harness/claude.md,model/some-model.md" \
    "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"

rm "$pdir/harness/claude.md"
out="$(dry "$config" --harness claude --model some-model --prompts-dir "$pdir" 2>/dev/null)"
check "a missing middle fragment is skipped, not fatal" \
    "all.md,model/some-model.md" \
    "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"

out="$(dry "$config" --harness codex --prompts-dir "$pdir" 2>/dev/null)"
check "no model given: only harness-independent fragments match" \
    "all.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"

printf '\n== --dry-run: model id sanitisation ==\n'

mkdir -p "$pdir/model"
printf 'sanitised\n' > "$pdir/model/openai_gpt-4o.md"
out="$(dry "$config" --harness claude --model openai/gpt-4o --prompts-dir "$pdir" 2>/dev/null)"
contains "a model id's slash becomes an underscore in the file name" \
    "model/openai_gpt-4o.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"

# A model id built entirely of slashes sanitises to a name with no separator
# left in it at all -- proof the directory cannot be escaped by way of the
# model id, whatever it contains.
out="$(dry "$config" --harness claude --model '../../etc/passwd' --prompts-dir "$pdir" 2>/dev/null)"
check "a path-shaped model id cannot escape the directory" \
    "all.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments=//p')"

printf '\n== --dry-run: git provenance ==\n'

gdir="$(mktemp -d)"; tmpdirs+=("$gdir")
(
    cd "$gdir" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'x\n' > all.md \
        && git add all.md \
        && git commit -q -m init
) >/dev/null 2>&1

out="$(dry "$config" --harness claude --prompts-dir "$gdir" 2>/dev/null)"
head_sha="$(git -C "$gdir" rev-parse HEAD)"
check "a clean prompts repo records its plain HEAD" \
    "$head_sha" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_rev=//p')"

printf 'more\n' >> "$gdir/all.md"
out="$(dry "$config" --harness claude --prompts-dir "$gdir" 2>/dev/null)"
check "a dirty prompts repo suffixes the rev -dirty" \
    "${head_sha}-dirty" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_rev=//p')"
git -C "$gdir" checkout -q -- all.md

nongit="$(mktemp -d)"; tmpdirs+=("$nongit")
printf 'x\n' > "$nongit/all.md"
out="$(dry "$config" --harness claude --prompts-dir "$nongit" 2>/dev/null)"
check "a non-git prompts directory records no rev" \
    "" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_rev=//p')"

printf '\n== real runs: rendered prompt and provenance ==\n'

# claude-sandboxed itself is never exercised below -- this stub replaces it
# entirely, so what is under test is only what fork-sandbox.sh does before
# handing off to the sandbox wrapper: composing handoff.md and writing the
# run's provenance files.
stub_bin="$(mktemp -d /var/tmp/claude-scratch/fs-prompt-overlay-stub.XXXXXX)"
tmpdirs+=("$stub_bin")
cat > "$stub_bin/claude-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
chmod +x "$stub_bin/claude-sandboxed"

# As with new_empty_config, callers register the result with tmpdirs
# themselves -- an append made in here would run inside this function's own
# command-substitution subshell and never reach the trap.
new_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-prompt-overlay-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

# Runs fork-sandbox.sh for real, foreground, with claude-sandboxed stubbed
# out, and echoes the run directory (registered with tmpdirs by the caller,
# same reason as above). The stub exits immediately, so this never launches
# an actual sandboxed session.
run_real() {
    local proj="$1" cfg="$2" handoff="$3"; shift 3
    local out rc rd
    out="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$cfg" \
        timeout 60 "$launcher" --foreground --harness claude "$@" \
        "$proj" "$handoff" 2>&1)"
    rc=$?
    rd="$(printf '%s\n' "$out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( rc != 0 )) || [[ -z "$rd" ]]; then
        printf 'run_real failed (rc=%s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi
    printf '%s' "$rd"
}

proj="$(new_project)"; tmpdirs+=("$proj")
handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-prompt-overlay-handoff.XXXXXX)"
tmpdirs+=("$handoff_dir")
handoff="$handoff_dir/handoff.md"
printf 'do the task\n' > "$handoff"

# -- no prompts directory: byte-identical to a run before this mechanism --
config="$(new_empty_config)"; tmpdirs+=("$config")
rd="$(run_real "$proj" "$config" "$handoff")"
[[ -n "$rd" ]] && tmpdirs+=("$rd")
if [[ -n "$rd" ]]; then
    clone_dir="$rd/clone/$(basename "$proj")"
    inbox_dir="$rd/inbox"
    expected="$(cat <<EXPECTED
# Your working directory

You are in a sandboxed, throwaway clone of the repository. Its absolute path
is:

    $clone_dir

You start there, so **prefer relative paths**. When you do need an absolute
one, copy the line above rather than typing it out: a hand-built path that
drops a segment fails as "No such file or directory", which looks like a
missing file rather than a wrong path.

That directory is the only writable thing here. Everything else in the sandbox
is read-only or ephemeral.

## Operator inbox

The person who launched this run can send you further instructions while you
work. They arrive as files in:

    $inbox_dir

Each file there is an **operator addendum**: a message from the same person who
wrote your handoff, written after this run started. An addendum is a
continuation of the handoff and carries the same authority — it may override
the handoff rather than merely add to it, and where the two conflict the
addendum is the newer instruction and wins.

The directory is mounted read-only. Never write to it. An empty inbox is the
normal case, not a problem: most runs get no addenda at all.

Addenda are pushed to you automatically — beside a tool result, or at the end
of a turn — so you do not have to go looking. Reading the directory yourself is
a backstop, not the mechanism.

---

do the task
EXPECTED
)"
    check "no prompts directory: handoff.md is byte-identical to the pre-overlay render" \
        "$expected" "$(cat "$rd/handoff.md")"
    n=$(find "$rd" -maxdepth 1 -name 'prompt-overlay.json' | wc -l)
    check "no prompts directory: no prompt-overlay.json is written" "0" "$n"
else
    no "no prompts directory: handoff.md is byte-identical to the pre-overlay render" \
        "run_real did not produce a run directory"
    no "no prompts directory: no prompt-overlay.json is written" "run_real failed"
fi

# -- configured overlay: the fragment text actually lands in the prompt --
pdir2="$(mktemp -d)"
tmpdirs+=("$pdir2")
mkdir -p "$pdir2/model"
printf 'ALL FRAGMENT TEXT\n' > "$pdir2/all.md"
printf 'MODEL FRAGMENT TEXT\n' > "$pdir2/model/vendor_model-y.md"
config2="$(new_empty_config)"; tmpdirs+=("$config2")
rd2="$(run_real "$proj" "$config2" "$handoff" --model 'vendor/model-y' --prompts-dir "$pdir2")"
[[ -n "$rd2" ]] && tmpdirs+=("$rd2")
if [[ -n "$rd2" ]]; then
    content="$(cat "$rd2/handoff.md")"
    contains "the overlay heading is present" "## Model-specific notes" "$content"
    contains "the all.md fragment lands in the prompt" "ALL FRAGMENT TEXT" "$content"
    contains "the sanitised model fragment lands in the prompt" \
        "MODEL FRAGMENT TEXT" "$content"
    all_pos="${content%%ALL FRAGMENT TEXT*}"
    model_pos="${content%%MODEL FRAGMENT TEXT*}"
    if (( ${#all_pos} < ${#model_pos} )); then
        ok "all.md renders before the model fragment"
    else
        no "all.md renders before the model fragment"
    fi
    case "$content" in
        *"---"*"do the task"*"## Model-specific notes"*)
            no "the overlay renders before the handoff, not after" ;;
        *)
            ok "the overlay renders before the handoff, not after" ;;
    esac

    if [[ -f "$rd2/prompt-overlay.json" ]]; then
        ok "prompt-overlay.json is written when an overlay applies"
        check "prompt-overlay.json names the source directory" \
            "$pdir2" "$(jq -r '.dir' "$rd2/prompt-overlay.json")"
        check "prompt-overlay.json lists fragments in composition order" \
            '["all.md","model/vendor_model-y.md"]' \
            "$(jq -c '.fragments' "$rd2/prompt-overlay.json")"
        check "prompt-overlay.json's rev is null for a non-git directory" \
            "null" "$(jq -c '.rev' "$rd2/prompt-overlay.json")"
        want_sha="$(cat "$pdir2/all.md" "$pdir2/model/vendor_model-y.md" | sha256sum | cut -d' ' -f1)"
        check "prompt-overlay.json's sha256 matches the concatenated fragments" \
            "$want_sha" "$(jq -r '.sha256' "$rd2/prompt-overlay.json")"
    else
        no "prompt-overlay.json is written when an overlay applies"
    fi
else
    no "run_real produced a run directory for the configured-overlay case" \
        "run_real failed"
fi

printf '\n== sandbox-run-log.py: prompt_overlay in the record ==\n'

if [[ -n "$rd2" && -x "$run_log" ]]; then
    fakehome="$(mktemp -d /var/tmp/claude-scratch/fs-prompt-overlay-fakehome.XXXXXX)"
    tmpdirs+=("$fakehome")
    mkdir -p "$fakehome/.claude"
    if HOME="$fakehome" "$run_log" record --run-dir "$rd2" >/dev/null 2>&1; then
        ok "sandbox-run-log.py record accepts a run with a prompt overlay"
        rec="$(HOME="$fakehome" "$run_log" show "$(basename "$rd2")")"
        check "the record carries prompt_overlay.dir" \
            "$pdir2" "$(printf '%s' "$rec" | jq -r '.prompt_overlay.dir')"
        check "the record carries prompt_overlay.fragments" \
            '["all.md","model/vendor_model-y.md"]' \
            "$(printf '%s' "$rec" | jq -c '.prompt_overlay.fragments')"
        stats_out="$(HOME="$fakehome" "$run_log" stats --by prompt_overlay.rev 2>&1)"
        contains "stats --by prompt_overlay.rev groups on it" \
            "PROMPT_OVERLAY.REV" "$stats_out"
    else
        no "sandbox-run-log.py record accepts a run with a prompt overlay"
    fi

    if [[ -n "$rd" ]]; then
        HOME="$fakehome" "$run_log" record --run-dir "$rd" >/dev/null 2>&1
        rec="$(HOME="$fakehome" "$run_log" show "$(basename "$rd")")"
        check "a run with no overlay carries no prompt_overlay key" \
            "null" "$(printf '%s' "$rec" | jq -c '.prompt_overlay // null')"
    fi
else
    no "sandbox-run-log.py record accepts a run with a prompt overlay" \
        "prior run_real step failed, or $run_log is not executable"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
