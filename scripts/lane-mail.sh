#!/bin/bash
# lane-mail.sh -- :approved: Agent mail between lane sessions
#
# Usage: lane-mail.sh register <lane>
#        lane-mail.sh registration
#        lane-mail.sh unregister
#        lane-mail.sh send|reply|show|tree|list|inbox|seen [args...]
#        lane-mail.sh send --to @lane:host ...     (another host, over ssh)
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
# The root is fixed on purpose (LANE_MAIL_ROOT in lane-mail-lib.sh). Callers
# never pass it, so the approved invocation surface cannot be pointed at
# another store, and no env-var prefix (which would defeat allowlist
# matching) is ever needed. Writes are bounded to the mail root (including
# the scratch files of an in-flight cross-host send, under it) and the
# per-user lane registry below.
#
# Other hosts. An address `@lane:host` names a lane on a peer host; a bare
# `@lane` is this host. `send`/`reply` with such a recipient (for a reply,
# including one inherited from the parent by reply-all) deliver it over ssh:
#
#   1. every remote host must be a peer in the peers file
#      (~/.config/fork-sandbox/lane-mail-peers, one `<peer> <ssh destination>`
#      per line); an unknown host is an error naming that file;
#   2. the message is built once, in portable form (every bare address
#      qualified with this host's peer name -- LANE_MAIL_PEER_NAME in
#      ~/.config/fork-sandbox/lane-mail.env, default the short hostname);
#   3. it is delivered to each remote host: `ssh -o BatchMode=yes -o
#      ConnectTimeout=<LANE_MAIL_SSH_TIMEOUT, 10> <destination> lane-mail-serve
#      deliver`, message on stdin. The far side's authorized_keys pins the key
#      to `lane-mail-serve --peer <this host>` (see that script's header), which
#      stamps the sender's host itself;
#   4. only after every delivery succeeded is the SAME message (same id,
#      thread id, headers) stored here, so `show`, `tree` and `reply
#      --reply-to` work on both sides and the far side's reply threads under it.
#
# If any step fails the command exits non-zero with the reason (for ssh, its
# own stderr) and writes nothing here; hosts delivered before a failure are
# named in the error. There is no retry queue -- re-send. A message to several
# hosts is delivered to each, in order. A cross-host message carries no
# attachments, grants or review target (refused). `--from` must be a lane on
# this host. Waking is unchanged: the receiving host's watcher and unread-mail
# hook see the message in that host's own store. `inbox` and `seen` are always
# this host's; nothing reads a remote inbox.
#
# `register` maps the calling Claude Code session to its lane mailbox in
# /tmp/claude-$UID/lane-mail-lanes/<session-id>; the unread-mail hooks
# (lane-mail-hook.sh) read that mapping to surface inbox state between
# turns. Sessions that never register are invisible to the hooks.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/lane-mail-lib.sh"
# By path, not PATH: a non-interactive ssh login's PATH lacks the scripts dir.
mail_bin="$script_dir/fork-sandbox-mail.sh"

LANES_DIR="/tmp/claude-$(id -u)/lane-mail-lanes"
work=""    # scratch dir of an in-flight cross-host send; removed on exit

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p }' "$0"
}

die() {
    echo "lane-mail: $*" >&2
    exit 1
}

# Sets the array `remote_hosts` to the distinct hosts, other than this one,
# named by the recipients of a `send`/`reply` invocation (args: verb, then the
# store's arguments). A reply with no --to inherits the parent's From/To/Cc.
find_remote_hosts() {
    local verb="$1"; shift
    local -a recips=() parts=()
    local reply_to="" have_to=0 line name self="" addr host seen h
    remote_hosts=()
    while (( $# )); do
        case "$1" in
            --to|--cc)
                [[ "$1" == --to ]] && have_to=1
                IFS=',' read -ra parts <<<"${2:-}"
                recips+=("${parts[@]:-}")
                shift $(( $# >= 2 ? 2 : 1 ))
                ;;
            --reply-to) reply_to="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
            --from|--subject|--body|--attach|--hops|--header|--allow-namespace|--reach-probe|\
            --context-ro|--context-secret|--review-target|--upstream-head|--upstream-state)
                shift $(( $# >= 2 ? 2 : 1 ))
                ;;
            *) shift ;;
        esac
    done
    if [[ "$verb" == reply && "$have_to" == 0 && -n "$reply_to" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            name="${line%%:*}"
            case "$name" in
                From|To|Cc)
                    IFS=',' read -ra parts <<<"${line#"$name":}"
                    recips+=("${parts[@]:-}")
                    ;;
            esac
        done < <(FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT" "$mail_bin" show "$reply_to" 2>/dev/null || true)
    fi
    self="$(lane_mail_self_name || true)"
    for addr in "${recips[@]:-}"; do
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"
        [[ "$addr" == @*:* ]] || continue
        host="${addr#*:}"
        [[ "$host" == "$self" ]] && continue
        seen=0
        for h in "${remote_hosts[@]:-}"; do [[ "$h" == "$host" ]] && seen=1; done
        (( seen )) || remote_hosts+=("$host")
    done
}

# Prints one header's value from a message file ($1), or nothing.
msg_header() {
    local file="$1" name="$2" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        if [[ "$line" == "$name:"* ]]; then
            printf '%s' "${line#"$name": }"
            return 0
        fi
    done < "$file"
    return 0
}

# Delivers a send/reply to other hosts, then stores it here. Args: verb, then
# the store's arguments. See the header ("Other hosts") for the contract.
cross_host() {
    local verb="$1"; shift
    local self
    self="$(lane_mail_self_name)" || die "cannot determine this host's peer name; set LANE_MAIL_PEER_NAME in $(lane_mail_config_dir)/lane-mail.env (lowercase alphanumeric, '-' and '.')"

    mkdir -p -- "$LANE_MAIL_ROOT"
    work="$(mktemp -d "$LANE_MAIL_ROOT/.xhost.XXXXXX")"
    trap 'rm -rf -- "$work"' EXIT

    # A body from stdin is read once, up front: it is needed again for the
    # local copy only through the message, but the store must see a file.
    local -a args=()
    while (( $# )); do
        if [[ "$1" == --body && "${2:-}" == - ]]; then
            cat > "$work/body"
            args+=(--body "$work/body")
            shift 2
        else
            args+=("$1")
            shift
        fi
    done

    local msg="$work/msg" rc=0
    "$mail_bin" "$verb" --emit "${args[@]}" > "$msg" || rc=$?
    (( rc == 0 )) || exit "$rc"

    local mid from from_host
    mid="$(msg_header "$msg" Message-ID)"
    from="$(msg_header "$msg" From)"
    from_host="${from#*:}"
    [[ "$from_host" == "$self" ]] || die "--from must be a lane on this host ('$from' names host '$from_host', this host is '$self')"

    find_remote_hosts "$verb" --to "$(msg_header "$msg" To)" --cc "$(msg_header "$msg" Cc)"
    local host dest peers_file
    peers_file="$(lane_mail_peers_file)"
    local -a dests=()
    for host in "${remote_hosts[@]:-}"; do
        [[ -n "$host" ]] || continue
        dest="$(lane_mail_peer_dest "$host" || true)"
        if [[ -z "$dest" ]]; then
            die "unknown host '$host': no such peer in $peers_file (add a line '$host <ssh destination>'); nothing was sent or stored"
        fi
        dests+=("$dest")
    done

    local -a ssh_cmd
    local ssh_value timeout
    ssh_value="$(lane_mail_env_value LANE_MAIL_SSH || true)"
    read -ra ssh_cmd <<<"${ssh_value:-ssh}"
    timeout="$(lane_mail_env_value LANE_MAIL_SSH_TIMEOUT || true)"
    [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout > 0 )) || timeout=10

    local i resp delivered=""
    for i in "${!dests[@]}"; do
        host="${remote_hosts[$i]}"
        rc=0
        resp="$("${ssh_cmd[@]}" -o BatchMode=yes -o ConnectTimeout="$timeout" \
            -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
            "${dests[$i]}" lane-mail-serve deliver < "$msg" 2>"$work/err")" || rc=$?
        if (( rc != 0 )) || [[ "$resp" != "ok $mid" ]]; then
            local why
            why="$(tr '\n' ' ' < "$work/err")"
            [[ -n "$why" ]] || why="unexpected reply '${resp:0:80}'"
            die "delivery to '$host' failed (exit $rc): ${why% }; nothing was stored locally${delivered:+; already delivered to:$delivered}"
        fi
        delivered+=" $host"
    done

    export FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT"
    if ! "$mail_bin" ingest < "$msg" >/dev/null; then
        die "delivered to$delivered but the local store write failed; $mid exists only on the remote side"
    fi
    echo "lane-mail: delivered $mid to$delivered and stored it here" >&2
    printf '%s\n' "$mid"
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
        # Registering arms no watch. Say how, here, where the caller acts.
        echo "lane-mail: to be woken when mail lands, run 'lane-mail-watch.sh $lane --wait'"
        echo "lane-mail: as a background command (not a Monitor, which expires); mark"
        echo "lane-mail: handled mail seen before relaunching it."
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
    send|reply)
        export FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT"
        remote_hosts=()
        find_remote_hosts "$cmd" "${@:2}"
        if (( ${#remote_hosts[@]} > 0 )); then
            cross_host "$cmd" "${@:2}"
        else
            exec "$mail_bin" "$@"
        fi
        ;;
    show|tree|list|inbox|seen)
        export FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT"
        exec "$mail_bin" "$@"
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
