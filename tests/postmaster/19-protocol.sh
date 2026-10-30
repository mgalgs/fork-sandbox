#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/19-protocol.sh — fork-sandbox-postmaster.sh: a seat's
# `protocol: <name>` prints <prompts-dir>/protocol-<name>.md verbatim right
# after the persona body, so a persona split into body + protocol file
# renders byte for byte as the undivided persona did.
#
# Usage: tests/postmaster/19-protocol.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

new_root PROTOCOL_PROMPTS_DIR
export FORK_SANDBOX_PROMPTS_DIR="$PROTOCOL_PROMPTS_DIR"
saved_fleet="$(cat "$FORK_SANDBOX_FLEET_FILE")"
saved_alice="$(cat "$FORK_SANDBOX_PERSONAS_DIR/alice.md")"

# The persona body ends in a newline; the protocol text starts with a blank
# line. Their concatenation is the undivided persona's body.
persona_body=$'Alice reviews code carefully.\nShe keeps replies short.\n'
protocol_text=$'\n## Reply format\n\nEnd every reply with VERDICT: ok or VERDICT: changes.\n'

# The handoff up to, not including, the thread section's heading: kit,
# blank line, persona section. Everything after it is the same code path
# with or without a protocol, and carries per-run ids besides.
handoff_head() {
    awk '/^## (Thread|The message you are answering)$/{exit} {print}' "$1"
}

# What today's handoff opens with for alice woken via To: -- the repo kit,
# substituted, then a blank line, then $1 (the persona section), then the
# blank line that follows it.
expected_head() {
    local kit
    kit="$(<"$repo_dir/share/fleet-kit.md")"
    kit="${kit//\{name\}/alice}"
    kit="${kit//\{operator\}/operator}"
    kit="${kit//\{via\}/To}"
    printf '%s\n\n%s\n' "$kit" "$1"
}

# Wakes alice once on a fresh thread and copies her handoff's head to $1.
wake_alice_head() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    send_msg '@bob' '@alice' 'protocol check' 'Please review.' 8 >/dev/null
    : > "$STUB_ARGV_LOG"
    once
    local hf
    if hf="$(handoff_file_for_agent alice)" && [[ -f "$hf" ]]; then
        handoff_head "$hf" > "$1"
    else
        : > "$1"
        no "a handoff was written for alice ($1)" "$(cat "$work/once.err")"
    fi
}

# ============================================================
printf '\n== protocol: no field, the handoff is byte-identical to before ==\n'
# ============================================================

printf -- '---\nmodel: opus\n---\n%s%s' "$persona_body" "$protocol_text" \
    > "$FORK_SANDBOX_PERSONAS_DIR/alice.md"
wake_alice_head "$work/whole.head"
expected_head "$persona_body$protocol_text" > "$work/whole.expected"
if cmp -s "$work/whole.expected" "$work/whole.head"; then
    ok "no protocol: kit, blank line, body, blank line, exactly"
else
    no "no protocol: kit, blank line, body, blank line, exactly" \
        "$(diff "$work/whole.expected" "$work/whole.head" | head -n 20)"
fi

# ============================================================
printf '\n== protocol: body + protocol file equals the undivided persona ==\n'
# ============================================================

printf '%s' "$protocol_text" > "$PROTOCOL_PROMPTS_DIR/protocol-reviewer.md"
printf -- '---\nmodel: opus\nprotocol: reviewer\n---\n%s' "$persona_body" \
    > "$FORK_SANDBOX_PERSONAS_DIR/alice.md"
wake_alice_head "$work/split.head"
if cmp -s "$work/whole.head" "$work/split.head"; then
    ok "protocol: the split persona's handoff head equals the undivided one's"
else
    no "protocol: the split persona's handoff head equals the undivided one's" \
        "$(diff "$work/whole.head" "$work/split.head" | head -n 20)"
fi

# ============================================================
printf '\n== protocol: printed verbatim, a leading --- is not frontmatter ==\n'
# ============================================================

dashes_text=$'---\nnot: frontmatter\n---\nTrailing protocol line.\n'
printf '%s' "$dashes_text" > "$PROTOCOL_PROMPTS_DIR/protocol-dashes.md"
printf -- '---\nmodel: opus\n---\n%s' "$persona_body" \
    > "$FORK_SANDBOX_PERSONAS_DIR/alice.md"
sed -i 's/^  alice: {}$/  alice:\n    protocol: dashes/' "$FORK_SANDBOX_FLEET_FILE"
wake_alice_head "$work/dashes.head"
expected_head "$persona_body$dashes_text" > "$work/dashes.expected"
if cmp -s "$work/dashes.expected" "$work/dashes.head"; then
    ok "protocol: a fleet.yaml protocol starting with --- prints as-is"
else
    no "protocol: a fleet.yaml protocol starting with --- prints as-is" \
        "$(diff "$work/dashes.expected" "$work/dashes.head" | head -n 20)"
fi

# ============================================================
printf '\n== protocol: a missing file refuses deliver at startup ==\n'
# ============================================================

rm -f -- "$PROTOCOL_PROMPTS_DIR/protocol-dashes.md"
new_scratch_root FORK_SANDBOX_MAIL_ROOT
export FORK_SANDBOX_MAIL_ROOT
send_msg '@bob' '@alice' 'protocol missing' 'Please review.' 8 >/dev/null
rc="$(once_rc)"
check "protocol: deliver refuses a fleet whose protocol file is missing" 1 "$rc"
contains "protocol: the refusal names the missing file" "$(cat "$work/once.err")" \
    "$PROTOCOL_PROMPTS_DIR/protocol-dashes.md"

printf '%s\n' "$saved_fleet" > "$FORK_SANDBOX_FLEET_FILE"
printf '%s\n' "$saved_alice" > "$FORK_SANDBOX_PERSONAS_DIR/alice.md"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
