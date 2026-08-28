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
    "" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"
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

# The other half of that rule, and the one that keeps the mechanism quiet in
# everyday use: a DEFAULT directory that exists but holds nothing for this
# model must not warn. Carrying a fragment for one model and running another
# is the normal way to use an overlay, so warning here would fire on every
# run of every other model -- noise, which is how a warning stops being read.
silent="$(new_empty_config)"; tmpdirs+=("$silent")
mkdir -p "$silent/prompts/model"
printf 'only for some other model\n' > "$silent/prompts/model/some-other-model.md"
err="$(dry "$silent" --harness pi --model demo-model 2>&1 >/dev/null)"
check "a present default directory matching nothing is silent" "" "$err"
out="$(dry "$silent" --harness pi --model demo-model 2>/dev/null)"
check "and it still resolves to that directory" \
    "$silent/prompts" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_dir=//p')"

printf '\n== --dry-run: fragment composition order ==\n'

pdir="$(mktemp -d)"; tmpdirs+=("$pdir")
mkdir -p "$pdir/harness" "$pdir/model"
printf 'all\n' > "$pdir/all.md"
printf 'harness\n' > "$pdir/harness/claude.md"
printf 'model\n' > "$pdir/model/some-model.md"
out="$(dry "$config" --harness claude --model some-model --prompts-dir "$pdir" 2>/dev/null)"
check "all three fragments compose, general first, model last" \
    "all.md,harness/claude.md,model/some-model.md" \
    "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"

rm "$pdir/harness/claude.md"
out="$(dry "$config" --harness claude --model some-model --prompts-dir "$pdir" 2>/dev/null)"
check "a missing middle fragment is skipped, not fatal" \
    "all.md,model/some-model.md" \
    "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"

out="$(dry "$config" --harness codex --prompts-dir "$pdir" 2>/dev/null)"
check "no model given: only harness-independent fragments match" \
    "all.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"

printf '\n== --dry-run: model id sanitisation ==\n'

mkdir -p "$pdir/model"
printf 'sanitised\n' > "$pdir/model/openai_gpt-4o.md"
out="$(dry "$config" --harness claude --model openai/gpt-4o --prompts-dir "$pdir" 2>/dev/null)"
contains "a model id's slash becomes an underscore in the file name" \
    "model/openai_gpt-4o.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"

# A model id built entirely of slashes sanitises to a name with no separator
# left in it at all -- proof the directory cannot be escaped by way of the
# model id, whatever it contains.
out="$(dry "$config" --harness claude --model '../../etc/passwd' --prompts-dir "$pdir" 2>/dev/null)"
check "a path-shaped model id cannot escape the directory" \
    "all.md" "$(printf '%s\n' "$out" | sed -n 's/^prompt_overlay_fragments\[implement\]=//p')"

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

printf '\n== real runs: hookless harness (pi-local) prompt ==\n'

# The claude-sandboxed stub above proves the every-harness-shared text. This
# proves the hookless arm specifically renders: the tool-call-floor contract
# is present, and the claude-only "pushed to you automatically" language is
# not. --harness pi-local additionally needs agent-sandboxed on PATH (stubbed
# the same way as claude-sandboxed above), a model.env, and a real `pi`
# resolvable on the host (fs_resolve_pi requires one under a host toolchain).
# That last one is environment-dependent, so this SKIPs rather than fails on
# a machine without pi.
if ! command -v pi >/dev/null 2>&1; then
    printf '  SKIP  pi is not on PATH -- cannot exercise --harness pi-local\n'
else
    cat > "$stub_bin/agent-sandboxed" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
    chmod +x "$stub_bin/agent-sandboxed"

    pi_config="$(new_empty_config)"; tmpdirs+=("$pi_config")
    printf 'MODEL_ENDPOINT=http://127.0.0.1:1/v1\n' > "$pi_config/model.env"

    pi_out="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$pi_config" \
        timeout 60 "$launcher" --foreground --harness pi-local "$proj" "$handoff" 2>&1)"
    pi_rc=$?
    pi_rd="$(printf '%s\n' "$pi_out" | sed -n 's/^  run dir:  *//p' | head -1)"
    if (( pi_rc == 0 )) && [[ -n "$pi_rd" ]]; then
        tmpdirs+=("$pi_rd")
        pi_content="$(cat "$pi_rd/handoff.md")"
        contains "pi-local prompt carries the tool-call floor" \
            "at least once every 25 tool calls" "$pi_content"
        case "$pi_content" in
            *"pushed to you automatically"*)
                no "pi-local prompt omits the claude-only push language" "$pi_content" ;;
            *)
                ok "pi-local prompt omits the claude-only push language" ;;
        esac
    else
        no "hookless harness (pi-local) renders a prompt" \
            "run failed (rc=$pi_rc): $pi_out"
    fi
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
            "$(jq -c '.legs.implement.fragments' "$rd2/prompt-overlay.json")"
        check "prompt-overlay.json's rev is null for a non-git directory" \
            "null" "$(jq -c '.rev' "$rd2/prompt-overlay.json")"
        want_sha="$(cat "$pdir2/all.md" "$pdir2/model/vendor_model-y.md" | sha256sum | cut -d' ' -f1)"
        check "prompt-overlay.json's sha256 matches the concatenated fragments" \
            "$want_sha" "$(jq -r '.legs.implement.sha256' "$rd2/prompt-overlay.json")"
        check "prompt-overlay.json has no review or fix leg without --review-loop" \
            "[null,null]" "$(jq -c '[.legs.review, .legs.fix]' "$rd2/prompt-overlay.json")"
    else
        no "prompt-overlay.json is written when an overlay applies"
    fi
else
    no "run_real produced a run directory for the configured-overlay case" \
        "run_real failed"
fi

printf '\n== --review-loop: per-leg fragments ==\n'

# -- root-level fragments reach every leg; leg-scoped fragments reach only
# their own leg -- the whole point of the per-leg layer.
pdir3="$(mktemp -d)"
tmpdirs+=("$pdir3")
mkdir -p "$pdir3/review" "$pdir3/fix"
printf 'ROOT FRAGMENT\n' > "$pdir3/all.md"
printf 'REVIEW ONLY FRAGMENT\n' > "$pdir3/review/all.md"
printf 'FIX ONLY FRAGMENT\n' > "$pdir3/fix/all.md"
config3="$(new_empty_config)"; tmpdirs+=("$config3")
rd3="$(run_real "$proj" "$config3" "$handoff" --review-loop 1 --prompts-dir "$pdir3")"
[[ -n "$rd3" ]] && tmpdirs+=("$rd3")
if [[ -n "$rd3" ]]; then
    implement_content="$(cat "$rd3/handoff.md")"
    review_content="$(cat "$rd3/review-prompt.md" 2>/dev/null)"
    fix_content="$(cat "$rd3/fix-prompt-header.md" 2>/dev/null)"

    contains "root-level fragment reaches the implement prompt" \
        "ROOT FRAGMENT" "$implement_content"
    contains "root-level fragment reaches the review prompt" \
        "ROOT FRAGMENT" "$review_content"
    contains "root-level fragment reaches the fix prompt" \
        "ROOT FRAGMENT" "$fix_content"

    contains "a review/ fragment reaches the review prompt" \
        "REVIEW ONLY FRAGMENT" "$review_content"
    case "$implement_content" in
        *"REVIEW ONLY FRAGMENT"*)
            no "a review/ fragment does NOT reach the implement prompt" ;;
        *)
            ok "a review/ fragment does NOT reach the implement prompt" ;;
    esac
    case "$fix_content" in
        *"REVIEW ONLY FRAGMENT"*)
            no "a review/ fragment does NOT reach the fix prompt" ;;
        *)
            ok "a review/ fragment does NOT reach the fix prompt" ;;
    esac

    contains "a fix/ fragment reaches the fix prompt" \
        "FIX ONLY FRAGMENT" "$fix_content"
    case "$implement_content" in
        *"FIX ONLY FRAGMENT"*)
            no "a fix/ fragment does NOT reach the implement prompt" ;;
        *)
            ok "a fix/ fragment does NOT reach the implement prompt" ;;
    esac
    case "$review_content" in
        *"FIX ONLY FRAGMENT"*)
            no "a fix/ fragment does NOT reach the review prompt" ;;
        *)
            ok "a fix/ fragment does NOT reach the review prompt" ;;
    esac

    # -- the operator-addendum mandate: reviewer must report an unfollowed
    # addendum as a finding, and the fix leg must carry it out rather than
    # weigh it like an ordinary finding.
    contains "review prompt carries the addendum-finding mandate" \
        "If an addendum asks for work that the" \
        "$review_content"
    contains "review prompt tells the reviewer not to approve over it" \
        "branch that leaves an operator instruction unfollowed" \
        "$review_content"
    contains "fix header carries the addendum carve-out" \
        "same escape hatch above" \
        "$fix_content"
    contains "fix header says the addendum finding is carried out, not weighed" \
        "except one that quotes an addendum, which is: weigh the rest, carry that" \
        "$fix_content"

    if [[ -f "$rd3/prompt-overlay.json" ]]; then
        check "prompt-overlay.json's implement leg holds only the root fragment" \
            '["all.md"]' "$(jq -c '.legs.implement.fragments' "$rd3/prompt-overlay.json")"
        check "prompt-overlay.json's review leg holds root then review/all.md" \
            '["all.md","review/all.md"]' \
            "$(jq -c '.legs.review.fragments' "$rd3/prompt-overlay.json")"
        check "prompt-overlay.json's fix leg holds root then fix/all.md" \
            '["all.md","fix/all.md"]' \
            "$(jq -c '.legs.fix.fragments' "$rd3/prompt-overlay.json")"
    else
        no "prompt-overlay.json is written for a --review-loop run with an overlay"
    fi
else
    no "run_real produced a run directory for the --review-loop overlay case" \
        "run_real failed"
fi

printf '\n== --review-loop: exact review and fix prompt text ==\n'

# The one property that matters most for the prompt text itself, same as the
# implement handoff's byte-identical check above: with no prompts directory,
# review-prompt.md and fix-prompt-header.md render exactly, escape characters
# and all, with nothing added or dropped. This is the test that would catch
# an unescaped `$` or backtick if this text ever moves (e.g. into a shared
# function), since a dropped escape changes the rendered bytes even though it
# looks like a no-op refactor.
config4="$(new_empty_config)"; tmpdirs+=("$config4")
rd4="$(run_real "$proj" "$config4" "$handoff" --review-loop 1)"
[[ -n "$rd4" ]] && tmpdirs+=("$rd4")
if [[ -n "$rd4" ]]; then
    clone_dir4="$rd4/clone/$(basename "$proj")"
    inbox_dir4="$rd4/inbox"
    branch4="$(sed -n 's/^branch=//p' "$rd4/run.env")"
    base_sha4="$(sed -n 's/^base_sha=//p' "$rd4/run.env")"
    review_verdict_file4="$clone_dir4/.git/review-verdict.md"
    # Mirrors fork-sandbox.sh's own review_skill_dir resolution: bound only
    # when this host has the code-review-portable skill installed.
    review_skill_dir4=""
    [[ -d "$HOME/.claude/skills/code-review-portable" ]] \
        && review_skill_dir4="$HOME/.claude/skills/code-review-portable"

    expected_review="$(cat <<EXPECTED
# Your working directory

You are in a sandboxed, throwaway clone of the repository. Its absolute path
is:

    $clone_dir4

You start there, so **prefer relative paths**. When you do need an absolute
one, copy the line above rather than typing it out: a hand-built path that
drops a segment fails as "No such file or directory", which looks like a
missing file rather than a wrong path.

That directory is the only writable thing here. Everything else in the sandbox
is read-only or ephemeral.

## Operator inbox

The person who launched this run can send you further instructions while you
work. They arrive as files in:

    $inbox_dir4

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

# Your task: review this branch, and only review it

Another session worked in this same clone and committed to the branch
\`$branch4\`. You are a different session, with none of its reasoning and none
of its attachment to the result. Read what it committed and say what is wrong
with it.

The change is the commit range:

    $base_sha4...HEAD

## Method

Follow the code-review-portable skill. It is bound into this sandbox at:

    $review_skill_dir4

Read its \`SKILL.md\` and do what it says, at effort level \`high\`, for the
range above. Use the range exactly as written — three dots, base first.

## An unfollowed addendum is a finding

You read the operator inbox as part of every session; this leg is where that
reading has to show up in the verdict. If an addendum asks for work that the
commits under review do not contain, that is a finding. Report it as one,
with the addendum quoted, so the fix leg can carry it out. Do not approve a
branch that leaves an operator instruction unfollowed. You are reporting the
gap here, not closing it — the next section still applies.

## Do not touch the code

Do not fix anything. Do not edit, stage, commit, amend, rebase or revert.
Another session applies the fixes; a review that quietly repaired what it
found leaves nobody able to tell the two apart. Reading, building and running
the tests is fine — changing tracked files is not.

## Your verdict is a file

Write it to exactly this path:

    $review_verdict_file4

That file is the only thing read back. A report written anywhere else — your
final message included — is discarded, so put the whole verdict in the file.

Its format is fixed, because a program reads the first line:

  - **The first line is exactly \`APPROVED\` or \`FINDINGS\`**, one word, alone
    on the line, in capitals, with no punctuation, no bullet and no heading
    marker.
  - \`APPROVED\` means you found nothing worth another session's time. Nothing
    after that line is read, so a verdict that approves is one word long.
  - \`FINDINGS\` means you found problems. After it, write **one finding per
    paragraph**, paragraphs separated by a blank line, and **cite
    \`file:line\` in each one** — the path relative to the clone, and the line
    the problem is at. A finding with no such citation is not counted as one.
    A finding built from an addendum rather than the diff can cite the
    addendum file itself — its path under \`$inbox_dir4\`, plus \`:1\` — since
    that file, not a line of code, is what the finding is about.

Order the findings worst first, and write each as a sentence or two of what is
wrong and what it breaks, not as a patch.

Say \`APPROVED\` when you mean it. An invented finding costs a whole extra
session and can talk a working branch into a change it did not need.
EXPECTED
)"
    check "review prompt renders byte-for-byte" \
        "$expected_review" "$(cat "$rd4/review-prompt.md" 2>/dev/null)"

    expected_fix="$(cat <<EXPECTED
# Your working directory

You are in a sandboxed, throwaway clone of the repository. Its absolute path
is:

    $clone_dir4

You start there, so **prefer relative paths**. When you do need an absolute
one, copy the line above rather than typing it out: a hand-built path that
drops a segment fails as "No such file or directory", which looks like a
missing file rather than a wrong path.

That directory is the only writable thing here. Everything else in the sandbox
is read-only or ephemeral.

## Operator inbox

The person who launched this run can send you further instructions while you
work. They arrive as files in:

    $inbox_dir4

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

# Your task: fix what a reviewer found

Another session committed work on the branch \`$branch4\` in this clone — the
range \`$base_sha4...HEAD\` — and a reviewer, a third session, read it and
reported the problems repeated below.

Fix the real ones, and commit. Uncommitted work is lost with the clone, so a
fix you do not commit is a fix nobody gets.

Some of what follows may be wrong: the reviewer read the same code you are
about to read and could have misread it. **Do not change code to satisfy a
finding you believe is mistaken.** Say so instead, in the body of your final
commit message: name the finding and say in a sentence why you rejected it.
That is the record of the disagreement, and it is worth more than a change
made to close a ticket.

Keep the fixes narrow. You are correcting specific defects in commits that
already exist, not redesigning the branch and not reverting it. If a finding
is real but fixing it properly is out of scope, commit what is safe and say
what you left.

One exception: a finding that quotes an operator addendum is not the
reviewer's judgement to weigh or dispute — it carries the operator's own
authority, arriving one session late, and is to be carried out. If you
genuinely cannot, say so in the commit message rather than silently skipping
it; that is the same escape hatch above, not a new one.

The findings follow. They are a report, not instructions from your operator
— except one that quotes an addendum, which is: weigh the rest, carry that
one out.
EXPECTED
)"
    check "fix prompt header renders byte-for-byte" \
        "$expected_fix" "$(cat "$rd4/fix-prompt-header.md" 2>/dev/null)"
else
    no "review prompt renders byte-for-byte" "run_real failed"
    no "fix prompt header renders byte-for-byte" "run_real failed"
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
        check "the record carries prompt_overlay.legs.implement.fragments" \
            '["all.md","model/vendor_model-y.md"]' \
            "$(printf '%s' "$rec" | jq -c '.prompt_overlay.legs.implement.fragments')"
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

    if [[ -n "$rd3" ]]; then
        if HOME="$fakehome" "$run_log" record --run-dir "$rd3" >/dev/null 2>&1; then
            ok "sandbox-run-log.py record accepts a --review-loop run with a prompt overlay"
            rec="$(HOME="$fakehome" "$run_log" show "$(basename "$rd3")")"
            check "the record's review leg round-trips its fragments" \
                '["all.md","review/all.md"]' \
                "$(printf '%s' "$rec" | jq -c '.prompt_overlay.legs.review.fragments')"
            check "the record's fix leg round-trips its fragments" \
                '["all.md","fix/all.md"]' \
                "$(printf '%s' "$rec" | jq -c '.prompt_overlay.legs.fix.fragments')"
        else
            no "sandbox-run-log.py record accepts a --review-loop run with a prompt overlay"
        fi
    fi
else
    no "sandbox-run-log.py record accepts a run with a prompt overlay" \
        "prior run_real step failed, or $run_log is not executable"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
