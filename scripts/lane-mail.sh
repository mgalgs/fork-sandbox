#!/bin/bash
# lane-mail.sh -- :approved: Agent mail between lane sessions
#
# Usage: lane-mail.sh register <lane>
#        lane-mail.sh registration
#        lane-mail.sh unregister
#        lane-mail.sh send|reply|show|tree|list|inbox|seen [args...]
#
# The fork-sandbox mail store (fork-sandbox-mail.sh; format and semantics in
# this repo's docs/agent-mail.md), pointed at a root reserved for
# lane-to-lane mail:
#
#   /var/tmp/claude-scratch/lane-mail
#
# A mailbox here (@frontend, @backend, @docs) belongs to a LANE, not to a
# session, so mail survives handoff rolls: the next session in a chain
# reads the same inbox (`lane-mail.sh inbox <lane>`), acts, and marks
# messages seen (`lane-mail.sh seen <lane> <id>...`).
#
# This root must stay separate from the fleet store
# (/var/tmp/claude-scratch/agent-mail): a postmaster delivering against that
# store flags every thread addressing a non-fleet name as needs-operator,
# so lane names there become noise in fleet panels.
#
# The root is fixed here on purpose. Callers never pass it, so the approved
# invocation surface cannot be pointed at another store, and no env-var
# prefix (which would defeat allowlist matching) is ever needed. Writes are
# bounded to the mail root and the per-user lane registry below.
#
# `register` maps the calling Claude Code session to its lane mailbox in
# /tmp/claude-$UID/lane-mail-lanes/<session-id>; the unread-mail hooks
# (lane-mail-hook.sh) read that mapping to surface inbox state between
# turns. Sessions that never register are invisible to the hooks.

set -euo pipefail

LANE_MAIL_ROOT=/var/tmp/claude-scratch/lane-mail
LANES_DIR="/tmp/claude-$(id -u)/lane-mail-lanes"

usage() {
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"
case "$cmd" in
    register)
        lane="${2:?Usage: lane-mail.sh register <lane>}"
        if [[ ! "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "lane-mail: bad lane name '$lane' (want ^[a-z0-9][a-z0-9-]*$, no leading @)" >&2
            exit 2
        fi
        sid="${CLAUDE_CODE_SESSION_ID:?lane-mail: CLAUDE_CODE_SESSION_ID is not set; run from inside a Claude Code session}"
        mkdir -p "$LANES_DIR"
        printf '%s\n' "$lane" > "$LANES_DIR/$sid"
        echo "lane-mail: session ${sid:0:8}... registered as @$lane"
        ;;
    registration)
        sid="${CLAUDE_CODE_SESSION_ID:-}"
        if [[ -n "$sid" && -f "$LANES_DIR/$sid" ]]; then
            cat "$LANES_DIR/$sid"
        else
            echo "lane-mail: this session has no registered lane" >&2
            exit 1
        fi
        ;;
    unregister)
        # For an outgoing session that handed its lane to a successor:
        # while registered, its Stop hook demands inbox-zero and would
        # have it mark seen -- i.e. steal -- mail meant for the next
        # session. Deregistering silences the hooks; the mail waits.
        sid="${CLAUDE_CODE_SESSION_ID:-}"
        if [[ -n "$sid" && -f "$LANES_DIR/$sid" ]]; then
            lane="$(<"$LANES_DIR/$sid")"
            rm -f "$LANES_DIR/$sid"
            echo "lane-mail: session ${sid:0:8}... unregistered from @$lane"
        else
            echo "lane-mail: this session has no registered lane" >&2
            exit 1
        fi
        ;;
    send|reply|show|tree|list|inbox|seen)
        export FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT"
        exec fork-sandbox-mail.sh "$@"
        ;;
    -h|--help|"")
        usage
        exit 0
        ;;
    *)
        echo "lane-mail: unknown subcommand '$cmd' (see --help)" >&2
        exit 2
        ;;
esac
