#!/bin/bash
# lane-mail.sh -- :approved: Agent mail between lane sessions
#
# Usage: lane-mail.sh register <lane> [--about "<text>"] [--dir <abs-path>]
#        lane-mail.sh describe <lane> "<text>"     ("" clears; "-" reads stdin)
#        lane-mail.sh registration
#        lane-mail.sh unregister
#        lane-mail.sh lane-for <abs-path>           (the directory->lane table)
#        lane-mail.sh send|reply|show|tree|list|inbox|seen [args...]
#        lane-mail.sh send --to @lane:host ...     (another host, over ssh)
#        lane-mail.sh lanes                        (the lanes there are)
#        lane-mail.sh kv get|set|del|list ...      (shared key/value store)
#
# `lanes` prints one `<source><TAB><lane><TAB><description><TAB><last seen>`
# line per lane: `live` (a session that registered it is still running),
# `stale` (registered, but no registering session is still running --
# registrations are never cleaned up), `mailbox`, `remote` (`lane:host` that
# has written here) and `peer` (a host). The third column is the lane's
# description (below), empty when unset and always empty for `remote` and
# `peer`. The fourth is when a session of a `live` or `stale` lane was last
# seen (local `YYYY-MM-DD HH:MM`, the latest of its registrations), empty for
# the other sources. Read the first fields and ignore the rest if you do not
# want them. `list` lists messages, not lanes.
#
# `send` and `reply` never refuse or hold mail over liveness, but for each
# local recipient lane (`@lane`, or `@lane:<this host>`) that is registered
# with no live session they print, after delivering, one stderr line
#   lane-mail: @x: registered but no live session (last seen <when>); mail will wait
# with the exit status unchanged. A lane never registered (mailbox-only), a
# remote `@lane:host`, @noreply and the sender's own lane are not checked.
#
# A lane may carry a one-line description of what it owns, so a name like
# @alpha is not read as "anything alpha-related" when its owner means one
# repo. `describe <lane> "<text>"` sets it (a leading @ on <lane> is
# accepted; "" clears it; "-" reads the text from stdin, trailing newlines
# dropped); `register <lane> --about "<text>"` does the same while
# registering. Registering without --about leaves an existing description
# alone. The text must be one line: a newline, tab or NUL is refused, as is
# anything over 200 characters. It is stored with the lane's mailbox
# (<root>/agents/<lane>/about), not with the session registration, so it
# survives a handoff replacing the session. Only local lanes have one: a
# `lane:host` is refused, and nothing is synced between hosts.
#
# Key/value store. Sessions on this host sometimes need shared state that
# is not a message ("which lane owns this pull request"). `kv` keeps it,
# under a key-naming convention of the caller's own; lane mail never
# interprets a key or a value.
#
#   kv get <key>              print the value's bytes exactly as stored, no
#                             newline added
#   kv get --json <key>       print {"key":..,"value":..,"version":..}; value
#                             and version come from ONE read of the record,
#                             so the version is safe to pass to --if-version
#   kv set <key> <value>      store; a value of `-` is read from stdin.
#                             Prints the new version.
#   kv set ... --if-version <v>   write only if the key exists at version <v>
#   kv set ... --if-absent        write only if the key does not exist
#                             (the two are mutually exclusive)
#   kv del <key> [--if-version <v>]
#   kv list [--prefix <p>]    the matching keys, sorted, one per line
#   kv list --json [--prefix <p>] one JSON object, key -> value
#
# `--` ends the options, for a value that starts with `--`.
#
# Exit codes: 0 success; 1 the key is absent (get, del; nothing on stdout);
# 2 usage or validation error (bad key, NUL or oversize value, conflicting
# flags); 3 precondition failed (--if-version on a missing key or another
# version, --if-absent on an existing key): stderr names which, and nothing
# was written; 4 the store could not be read or written (a permission or
# disk error, a damaged record): stderr says why, and the outcome of a
# write is unknown, so read again before relying on it.
#
# A key matches ^[A-Za-z0-9@][A-Za-z0-9._:/#@+=-]{0,199}$, so
# `pr:org/repo#2778` and `owner:@lane:host` are keys; a '/' is just a
# character, never a directory. A value is any bytes but NUL, at most 64 KiB
# (65536 bytes). `--json` output decodes values as UTF-8, invalid bytes
# replaced by U+FFFD; plain `get` is the byte-exact read.
#
# A version is an opaque token the store issues, new and unique on every
# write (time plus random), never a per-key counter, so deleting and
# re-creating a key never reissues a version a stale client still holds.
# Never compute one: take it from `set` or `get --json`. The pattern for a
# safe read-modify-write is `get --json`, then `set ... --if-version <v>`,
# retrying from the `get` on exit 3.
#
# The store is <root>/kv (created on first write): one file per key holding
# version and value, named by the key lower-cased with '/' replaced by '%',
# plus '~' and a hex mask of its upper-case positions, so keys that differ
# only in case stay apart on a case-insensitive file system. Writes run
# under one exclusive flock on the store -- a conditional write's check and
# its write under the same hold -- and land by temp-file-then-rename, so the
# lock-free reads never see a torn record. Per-host only: no `@lane:host`
# addressing (a value may contain one as text), no expiry, and no access
# control beyond the filesystem's -- any session can overwrite any key. The
# work is done by lane-mail-kv.py, which this script hands the store path.
#
# `~/.local/state/fork-sandbox/lanes.json` remembers, per project directory,
# the lane last used there: a flat JSON object mapping an absolute directory
# to a lane name. `register <lane> --dir <abs-path>` records that mapping
# (the directory is given by the caller, since neither this script nor $PWD
# reliably knows a session's primary working directory); `lane-for
# <abs-path>` reads it back. Both treat a trailing slash as not part of the
# key ("/a/b/" and "/a/b" are the same entry; "/" stays "/"), and neither
# resolves symlinks. This is the only code that touches that file: callers
# that want the mapping go through these two verbs, never a direct Read/Write
# of the JSON, so a lock and an atomic rename -- not "last writer wins" --
# settle two sessions registering a directory at nearly the same moment.
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
# the scratch files of an in-flight cross-host send and the `kv` store, both
# under it), the
# per-user lane registry below, and the directory->lane table (lanes.json,
# above).
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
# hosts is delivered to each, in order. A cross-host message carries
# --attach (fork-sandbox-mail.sh's --emit frames it as a LANE-MAIL-BUNDLE on
# the same stdin stream -- no second connection, no new ssh verb; see
# docs/agent-mail.md, "Lane mail between hosts", for the wire format, the
# caps, and the trust rules the receiving `ingest` applies to it) but no
# grants or review target (refused). A receiving fork-sandbox that predates
# bundle support refuses the whole delivery with an error naming the
# upgrade it needs; nothing is stored, here or there. `--from` must be a
# lane on this host; a send without --from passes, since its `@noreply`
# sentinel is qualified with this host like any other From. Waking is unchanged: the receiving host's watcher and
# unread-mail hook see the message in that host's own store. `inbox` and
# `seen` are always this host's; nothing reads a remote inbox.
#
# `register` maps the calling Claude Code session to its lane mailbox in
# /tmp/claude-$UID/lane-mail-lanes/<session-id>; the unread-mail hooks
# (lane-mail-hook.sh) read that mapping to surface inbox state between
# turns. Sessions that never register are invisible to the hooks. The file
# also records the session's Claude Code process (the nearest ancestor that
# is the CLI: its pid and start time, plus $TMUX_PANE when set), which is
# what `live` means; the hook refreshes its last-seen time every turn and
# re-records the process when it changed. Format and rules: "Session
# registrations" in lane-mail-lib.sh. `registration` prints the lane alone.
# `register noreply` is refused before anything is written: `@noreply` is
# the store's one-way sender (`send` without --from), and no mailbox may
# answer to it.

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/lane-mail-lib.sh"
# By path, not PATH: a non-interactive ssh login's PATH lacks the scripts dir.
mail_bin="$script_dir/fork-sandbox-mail.sh"

LANES_DIR="/tmp/claude-$(id -u)/lane-mail-lanes"
LANES_JSON="$HOME/.local/state/fork-sandbox/lanes.json"
BROADCAST="@all"   # the local broadcast address; see the header
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
# Also sets `recip_addrs` (every recipient, trimmed), `recip_from` (the
# --from value), `recip_self` (this host's peer name, or empty),
# `recip_all` (1 when --to or --cc names @all) and `recip_all_host` (an
# `@all:<host>` given in --to or --cc, or empty). An @all inherited by
# reply-all is dropped, as the store drops it.
find_remote_hosts() {
    local verb="$1"; shift
    local -a recips=() parts=()
    local reply_to="" have_to=0 line name self="" addr host seen h p
    remote_hosts=() recip_addrs=() recip_from="" recip_all=0 recip_all_host=""
    while (( $# )); do
        case "$1" in
            --to|--cc)
                [[ "$1" == --to ]] && have_to=1
                IFS=',' read -ra parts <<<"${2:-}"
                recips+=("${parts[@]:-}")
                for p in "${parts[@]:-}"; do
                    p="${p//[[:space:]]/}"
                    [[ "$p" == "$BROADCAST" ]] && recip_all=1
                    [[ "$p" == "$BROADCAST":* && -z "$recip_all_host" ]] && recip_all_host="$p"
                done
                shift $(( $# >= 2 ? 2 : 1 ))
                ;;
            --reply-to) reply_to="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
            --from) recip_from="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
            --subject|--body|--attach|--hops|--header|--allow-namespace|--reach-probe|--host-alias|--seat-resources|\
            --context-ro|--context-secret|--review-target|--upstream-head|--upstream-state|--services-env)
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
                    for p in "${parts[@]:-}"; do
                        h="${p//[[:space:]]/}"
                        [[ "$h" == "$BROADCAST" || "$h" == "$BROADCAST":* ]] || recips+=("$p")
                    done
                    ;;
            esac
        done < <(FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT" "$mail_bin" show "$reply_to" 2>/dev/null || true)
    fi
    self="$(lane_mail_self_name || true)"
    recip_self="$self"
    for addr in "${recips[@]:-}"; do
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"
        [[ -n "$addr" ]] && recip_addrs+=("$addr")
        [[ "$addr" == @*:* && "$addr" != "$BROADCAST":* ]] || continue
        host="${addr#*:}"
        [[ "$host" == "$self" ]] && continue
        seen=0
        for h in "${remote_hosts[@]:-}"; do [[ "$h" == "$host" ]] && seen=1; done
        (( seen )) || remote_hosts+=("$host")
    done
}

# Sets the array `stale_warnings` to one line per local lane among the
# recipients last parsed by find_remote_hosts that has registrations but no
# live one (see "Session registrations" in lane-mail-lib.sh). A lane that was
# never registered (mailbox-only), a remote `@lane:host`, @noreply and the
# sender's own lane are never checked. Nothing here refuses or holds mail.
find_stale_lanes() {
    local addr lane f any live best t from_lane
    local -A checked=()
    stale_warnings=()
    [[ -d "$LANES_DIR" ]] || return 0
    from_lane="${recip_from#@}"
    from_lane="${from_lane%%:*}"
    for addr in "${recip_addrs[@]:-}"; do
        [[ "$addr" == @* ]] || continue
        lane="${addr#@}"
        if [[ "$lane" == *:* ]]; then
            [[ -n "$recip_self" && "${lane#*:}" == "$recip_self" ]] || continue
            lane="${lane%%:*}"
        fi
        [[ "$lane" =~ $LANE_MAIL_LANE_RE && "$lane" != noreply && "$lane" != "$from_lane" ]] || continue
        [[ -z "${checked[$lane]:-}" ]] || continue
        checked[$lane]=1
        any=0 live=0 best=0
        for f in "$LANES_DIR"/*; do
            # shellcheck disable=SC2154  # set by lane_mail_reg_read (lane-mail-lib.sh)
            [[ -f "$f" ]] && lane_mail_reg_read "$f" && [[ "$lm_reg_lane" == "$lane" ]] || continue
            any=1
            if lane_mail_reg_live; then live=1; break; fi
            t="$(lane_mail_mtime "$f")" || continue
            (( t > best )) && best=$t
        done
        (( any && ! live )) || continue
        if (( best > 0 )); then t="$(lane_mail_when "$best" age)"; else t="unknown"; fi
        stale_warnings+=("lane-mail: @$lane: registered but no live session (last seen $t); mail will wait")
    done
}

# Prints the `@all` expansion for the recipients last parsed by
# find_remote_hosts, ", "-joined: every lane `lanes` lists as live, stale or
# mailbox, except @noreply, @all and the sender's own lane. Empty when there
# is none.
broadcast_lanes() {
    local lister listing src lane from_lane out=""
    lister="$script_dir/../mods/lane-complete/bin/list-lanes.sh"
    [[ -x "$lister" ]] || die "@all: $lister not found, so the lanes cannot be listed; nothing was sent"
    listing="$("$lister")" || die "@all: listing the lanes failed; nothing was sent"
    from_lane="${recip_from#@}"
    from_lane="${from_lane%%:*}"
    while IFS=$'\t' read -r src lane _; do
        case "$src" in live|stale|mailbox) ;; *) continue ;; esac
        [[ "$lane" =~ $LANE_MAIL_LANE_RE && "$lane" != noreply && "@$lane" != "$BROADCAST" && "$lane" != "$from_lane" ]] || continue
        out="${out:+$out, }@$lane"
    done <<<"$listing"
    printf '%s' "$out"
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
    local is_bundle=0
    [[ "$(head -n1 -- "$msg")" == "LANE-MAIL-BUNDLE 1" ]] && is_bundle=1

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
            # An old ingest refuses a bundle one of two ways, depending on
            # size: it checks the raw byte count before it ever parses
            # headers, so a bundle over the 1 MiB plain-message cap (the
            # common case once an attachment is involved) gets the generic
            # "over the byte cap" refusal; a bundle at or under that size
            # reaches header parsing, where the unparseable marker line
            # gets "malformed header line". Either way it is this host's
            # own old age, not a problem with the bundle, so both map to
            # the same upgrade-needed error.
            if (( is_bundle )) && { [[ "$why" == *"malformed header line"* ]] || [[ "$why" == *"message is over the "*" byte cap."* ]]; }; then
                die "delivery to '$host' failed: the far host's fork-sandbox predates attachment support and must be upgraded; nothing was stored locally${delivered:+; already delivered to:$delivered}"
            fi
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

# Sets (or, with empty text, clears) the description of local lane $1 to $2.
# Refuses anything that is not one line of at most 200 characters.
set_description() {
    local lane="${1#@}" text="$2" dir tmp
    if [[ ! "$lane" =~ $LANE_MAIL_LANE_RE ]]; then
        echo "lane-mail: bad lane name '$lane' (want $LANE_MAIL_LANE_RE; only local lanes have a description)" >&2
        return 2
    fi
    if [[ "$text" == *$'\n'* || "$text" == *$'\t'* ]]; then
        echo "lane-mail: a description is one line: no newline or tab" >&2
        return 2
    fi
    if (( ${#text} > 200 )); then
        echo "lane-mail: a description is at most 200 characters (got ${#text})" >&2
        return 2
    fi
    dir="$LANE_MAIL_ROOT/agents/$lane"
    if [[ -z "$text" ]]; then
        rm -f -- "$dir/about"
        echo "lane-mail: cleared the description of @$lane"
        return 0
    fi
    mkdir -p -- "$dir"
    tmp="$(mktemp "$dir/.about.XXXXXX")"
    printf '%s\n' "$text" > "$tmp"
    mv -f -- "$tmp" "$dir/about"
    echo "lane-mail: @$lane described: $text"
}

# Reads a description from stdin ("-") into `desc_text`, trailing newlines
# dropped. Returns 2 on a NUL byte (an argument can never carry one).
read_description_stdin() {
    local bytes clean
    mkdir -p -- "$LANE_MAIL_ROOT"
    desc_tmp="$(mktemp "$LANE_MAIL_ROOT/.about-stdin.XXXXXX")"
    trap 'rm -f -- "$desc_tmp"' EXIT
    trap 'exit 130' INT TERM
    cat > "$desc_tmp"
    bytes="$(wc -c < "$desc_tmp")"
    clean="$(tr -d '\0' < "$desc_tmp" | wc -c)"
    if (( bytes != clean )); then
        echo "lane-mail: a description is one line: no NUL" >&2
        return 2
    fi
    desc_text="$(cat -- "$desc_tmp")"   # drops trailing newlines
}

# Drops one trailing slash from a directory key ("/a/b/" -> "/a/b"; the root
# "/" is left alone). Does not resolve symlinks: the key must match what the
# caller later looks up with, not what the path resolves to.
normalize_lane_dir() {
    local d="$1"
    if [[ "$d" == / ]]; then
        printf '%s' "$d"
    else
        printf '%s' "${d%/}"
    fi
}

# Sets lanes.json's entry for directory $1 to lane $2, under an exclusive
# lock: read the object, set the one key, write a temp file in the same
# directory, rename it into place, release. A missing file or parent
# directory is created. A file that exists but is not a JSON object is left
# untouched; its path is named on stderr and this returns non-zero.
lanes_json_set() {
    local dir lane lanes_dir lock_fd tmp rc=0
    dir="$(normalize_lane_dir "$1")"
    lane="$2"
    lanes_dir="$(dirname -- "$LANES_JSON")"
    mkdir -p -- "$lanes_dir"
    exec {lock_fd}>"$LANES_JSON.lock"
    if ! flock -x "$lock_fd"; then
        echo "lane-mail: could not lock $LANES_JSON.lock" >&2
        exec {lock_fd}>&- 2>/dev/null || true
        return 1
    fi
    tmp="$(mktemp "$lanes_dir/.lanes.json.XXXXXX")"
    python3 - "$LANES_JSON" "$dir" "$lane" "$tmp" <<'PY' || rc=$?
import json
import sys

path, dirkey, lane, tmp = sys.argv[1:5]
try:
    with open(path) as f:
        text = f.read()
except FileNotFoundError:
    text = ""

data = {}
if text.strip():
    try:
        data = json.loads(text)
    except ValueError:
        sys.stderr.write("lane-mail: %s is not valid JSON; left untouched\n" % path)
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("lane-mail: %s is not a JSON object; left untouched\n" % path)
        sys.exit(1)

data[dirkey] = lane
with open(tmp, "w") as f:
    json.dump(data, f)
PY
    if (( rc != 0 )); then
        rm -f -- "$tmp"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&- 2>/dev/null || true
        return "$rc"
    fi
    if ! mv -f -- "$tmp" "$LANES_JSON"; then
        rm -f -- "$tmp"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&- 2>/dev/null || true
        return 1
    fi
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&- 2>/dev/null || true
}

# Prints the lane recorded for directory $1 and exits 0; exits 1 printing
# nothing when the file or the key is missing. Takes no lock: the rename in
# lanes_json_set already rules out a torn read.
lanes_json_get() {
    local dir
    dir="$(normalize_lane_dir "$1")"
    [[ -f "$LANES_JSON" ]] || return 1
    python3 - "$LANES_JSON" "$dir" <<'PY'
import json
import sys

path, dirkey = sys.argv[1:3]
with open(path) as f:
    text = f.read()

data = {}
if text.strip():
    try:
        data = json.loads(text)
    except ValueError:
        sys.stderr.write("lane-mail: %s is not valid JSON\n" % path)
        sys.exit(2)
    if not isinstance(data, dict):
        sys.stderr.write("lane-mail: %s is not a JSON object\n" % path)
        sys.exit(2)

lane = data.get(dirkey)
if lane is None:
    sys.exit(1)
print(lane)
PY
}

cmd="${1:-}"
case "$cmd" in
    describe)
        (( $# == 3 )) || { echo 'Usage: lane-mail.sh describe <lane> "<text>"' >&2; exit 2; }
        text="$3"
        if [[ "$text" == - ]]; then
            read_description_stdin || exit 2
            text="$desc_text"
        fi
        set_description "$2" "$text"
        ;;
    register)
        lane="" about="" have_about=0 dir="" have_dir=0
        shift
        while (( $# )); do
            case "$1" in
                --about)
                    (( $# >= 2 )) || { echo "lane-mail: --about needs a value" >&2; exit 2; }
                    about="$2"; have_about=1; shift 2 ;;
                --dir)
                    (( $# >= 2 )) || { echo "lane-mail: --dir needs a value" >&2; exit 2; }
                    dir="$2"; have_dir=1; shift 2 ;;
                *)
                    [[ -z "$lane" ]] || { echo "Usage: lane-mail.sh register <lane> [--about \"<text>\"] [--dir <abs-path>]" >&2; exit 2; }
                    lane="$1"; shift ;;
            esac
        done
        [[ -n "$lane" ]] || { echo "Usage: lane-mail.sh register <lane> [--about \"<text>\"] [--dir <abs-path>]" >&2; exit 2; }
        # @all is the broadcast address; no one mailbox may answer to it.
        if [[ "$lane" == all || "$lane" == "$BROADCAST" ]]; then
            echo "lane-mail: 'all' is reserved for broadcast (send --to @all) and cannot be registered" >&2
            exit 2
        fi
        if [[ ! "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "lane-mail: bad lane name '$lane' (want ^[a-z0-9][a-z0-9-]*$, no leading @)" >&2
            exit 2
        fi
        # @noreply is the store's one-way sender sentinel (`send` without
        # --from); a mailbox answering to it would turn "no return address"
        # into a real one.
        if [[ "$lane" == noreply ]]; then
            echo "lane-mail: 'noreply' is reserved for one-way mail (send without --from) and cannot be registered" >&2
            exit 2
        fi
        # Validate --dir before anything is written, same as --about below.
        if (( have_dir )) && [[ "$dir" != /* ]]; then
            echo "lane-mail: --dir must be an absolute path (got '$dir')" >&2
            exit 2
        fi
        sid="${CLAUDE_CODE_SESSION_ID:?lane-mail: CLAUDE_CODE_SESSION_ID is not set; run from inside a Claude Code session}"
        # Validate the description before registering, so a refusal changes nothing.
        if (( have_about )) && [[ "$about" == - ]]; then
            read_description_stdin || exit 2
            about="$desc_text"
        fi
        if (( have_about )); then
            if [[ "$about" == *$'\n'* || "$about" == *$'\t'* ]] || (( ${#about} > 200 )); then
                set_description "$lane" "$about" || exit 2
            fi
        fi
        # First of the writes: a malformed lanes.json refuses before the
        # session is registered, so the refusal changes nothing.
        if (( have_dir )); then lanes_json_set "$dir" "$lane" || exit $?; fi
        mkdir -p "$LANES_DIR"
        lane_mail_reg_write "$LANES_DIR/$sid" "$lane" || die "could not write $LANES_DIR/$sid"
        echo "lane-mail: session ${sid:0:8}... registered as @$lane"
        if (( have_about )); then set_description "$lane" "$about"; fi
        # Registering arms no watch. Say how, here, where the caller acts.
        echo "lane-mail: to be woken when mail lands, run 'lane-mail-watch.sh $lane --wait'"
        echo "lane-mail: as a background command (not a Monitor, which expires); mark"
        echo "lane-mail: handled mail seen before relaunching it."
        ;;
    lane-for)
        (( $# == 2 )) || { echo 'Usage: lane-mail.sh lane-for <abs-path>' >&2; exit 2; }
        lanes_json_get "$2"
        ;;
    registration)
        sid="${CLAUDE_CODE_SESSION_ID:-}"
        if [[ -n "$sid" && -f "$LANES_DIR/$sid" ]] && lane_mail_reg_read "$LANES_DIR/$sid"; then
            # shellcheck disable=SC2154  # set by lane_mail_reg_read (lane-mail-lib.sh)
            printf '%s\n' "$lm_reg_lane"
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
            lane_mail_reg_read "$LANES_DIR/$sid" || true
            # shellcheck disable=SC2154  # set by lane_mail_reg_read (lane-mail-lib.sh)
            lane="$lm_reg_lane"
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
        [[ -z "$recip_all_host" ]] || die "$recip_all_host: broadcast is local-only; @all takes no host (name a remote lane as @lane:host); nothing was sent"
        args=("${@:2}")
        for (( i = 0; i < ${#args[@]}; i++ )); do
            if [[ "${args[i]}" == --header && "${args[i+1]:-}" =~ ^[[:space:]]*[Xx]-[Ll][Aa][Nn][Ee]-[Bb][Rr][Oo][Aa][Dd][Cc][Aa][Ss][Tt][[:space:]]*: ]]; then
                die "--header may not set X-Lane-Broadcast; address the message to @all instead"
            fi
        done
        broadcast=""
        if (( recip_all )); then
            broadcast="$(broadcast_lanes)" || exit $?
            [[ -z "$broadcast" ]] || args+=(--header "X-Lane-Broadcast: $broadcast")
        fi
        find_stale_lanes
        rc=0
        if (( ${#remote_hosts[@]} > 0 )); then
            cross_host "$cmd" "${args[@]}"
        else
            "$mail_bin" "$cmd" "${args[@]}" || rc=$?
        fi
        # Delivered: say which local recipients have no session to read it.
        if (( rc == 0 )); then
            if (( recip_all )); then
                echo "lane-mail: @all reached ${broadcast:-no other local lane}" >&2
            fi
            for w in "${stale_warnings[@]:-}"; do [[ -z "$w" ]] || echo "$w" >&2; done
        fi
        exit "$rc"
        ;;
    show|tree|list|inbox|seen)
        export FORK_SANDBOX_MAIL_ROOT="$LANE_MAIL_ROOT"
        exec "$mail_bin" "$@"
        ;;
    kv)
        # The store sits under the fixed root like everything else written
        # here; the helper is given its directory, never the caller.
        exec python3 "$script_dir/lane-mail-kv.py" "$LANE_MAIL_ROOT/kv" "${@:2}"
        ;;
    lanes)
        # The lane-complete mod's lister already merges every source and
        # reads its paths from these scripts; one lister, two callers.
        lister="$script_dir/../mods/lane-complete/bin/list-lanes.sh"
        [[ -x "$lister" ]] || die "lanes: $lister not found (lane-mail.sh must run from a fork-sandbox checkout)"
        exec "$lister" "${@:2}"
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
