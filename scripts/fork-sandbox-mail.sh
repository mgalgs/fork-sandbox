#!/usr/bin/env bash
# fork-sandbox-mail.sh — A shared maildir-style message store for a fleet of
# asynchronous agents
#
# Usage: fork-sandbox-mail.sh send --from @a --to @b[,@c] [--cc @d[,@e]]
#                              --subject <s> (--body <file>|-)
#                              [--attach <file>]... [--hops <n>]
#                              [--header 'X-Name: value']...
#                              [--allow-namespace NS[:PORT]]...
#                              [--reach-probe HOST:PORT]...
#                              [--host-alias IP=HOST[,HOST...]]...
#                              [--seat-resources SEAT=cpu=QTY[,memory=QTY]]...
#                              [--context-ro DIR] [--context-secret NAME]
#                              [--review-target <branch>:<sha>] [--budget <n>]
#                              [--no-grant] [--services-env KEY=VAL]...
#        fork-sandbox-mail.sh reply --from @a --reply-to <message-id>
#                              (--body <file>|-) [--to @b[,@c]] [--cc @d[,@e]]
#                              [--subject <s>] [--attach <file>]... [--hops <n>]
#                              [--header 'X-Name: value']...
#                              [--upstream-head <branch>:<sha>]
#                              [--upstream-state closed|open]
#        fork-sandbox-mail.sh send|reply --emit ...   (print, do not store)
#        fork-sandbox-mail.sh ingest [--peer <name>] < message
#        fork-sandbox-mail.sh show <message-id>
#        fork-sandbox-mail.sh tree <thread-id>
#        fork-sandbox-mail.sh export <thread-id> --json
#        fork-sandbox-mail.sh list [--json] [--header 'Name: value']...
#        fork-sandbox-mail.sh inbox <name> [--all]
#        fork-sandbox-mail.sh seen <name> <message-id>...
#        fork-sandbox-mail.sh grant <thread-id> [--allow-namespace NS[:PORT]]...
#                              [--reach-probe HOST:PORT]...
#                              [--host-alias IP=HOST[,HOST...]]...
#                              [--seat-resources SEAT=cpu=QTY[,memory=QTY]]...
#                              [--context-ro DIR] [--context-secret NAME]
#        fork-sandbox-mail.sh grant <thread-id> --clear
#        fork-sandbox-mail.sh grant <thread-id> --show [--json]
#        fork-sandbox-mail.sh --remote <verb> ...
#
# `--remote` as the first argument runs the verb against the mail API server
# (fork-sandbox-mail-api.py) instead of the local store, with the same
# arguments and the same exit code; it needs FORK_SANDBOX_MAIL_API_URL and
# FORK_SANDBOX_MAIL_API_TOKEN_FILE (see docs/mail-api.md). Anywhere else in
# the arguments it is not special.
#
# `send --emit` / `reply --emit` build the message exactly as without the flag
# but print it (headers, blank line, body) on stdout instead of storing it,
# and write nothing to the store. The printed form is PORTABLE: every bare
# address is qualified with this host's peer name, so it means the same on
# any host. --emit does not carry grants, --review-target, --budget,
# --no-grant, --services-env or the upstream flags (refused). It exists so
# lane-mail.sh can deliver a message to another host before anything is
# written here.
#
# --emit WITH one or more --attach prints a LANE-MAIL-BUNDLE instead of the
# plain message: the plain message framed with its byte count, then one
# "attachment <basename> <size> <sha256>" frame per distinct attachment (in
# --attach order), each immediately followed by that many raw bytes and a
# single newline, then a final "end" line. At most
# MAIL_ATTACH_MAX_COUNT (8) attachments, each under MAIL_ATTACH_MAX_BYTES (4
# MiB); over either is refused here, before anything is sent. See
# docs/agent-mail.md, "Lane mail between hosts", for the exact framing
# grammar and the trust rules `ingest` applies to it.
#
# `ingest [--peer <name>]` reads one complete message OR one LANE-MAIL-BUNDLE
# from stdin (as --emit prints either) and stores it keeping its Message-ID,
# Thread-ID and all other headers, normalising addresses that name this host
# to the bare form. For a plain message it refuses (one-line error, exit 1):
# a message over 1 MiB, a malformed or duplicated core header, a missing core
# header (Message-ID, Thread-ID, Date, From, To, Subject, X-Hops), an id that
# is not a store-shaped id, the reserved headers X-Attachment, X-Upstream-*,
# X-Review-Target*, X-Version, X-Thread-Budget and X-Grant, an invalid
# address, an empty body, and a Message-ID already in the store. For a
# bundle, the message part goes through the same checks except that
# X-Attachment headers are required and must match the bundle's attachment
# frames exactly (same basenames, same order, same count); each attachment
# frame is validated (basename shape, size cap, declared size and sha256
# against the bytes actually sent) and staged atomically into
# threads/<tid>/attachments/ before the message is written -- see
# docs/agent-mail.md for the full grammar, caps and collision rules,
# including what a receiver that predates bundle support does with one
# (lane-mail.sh turns that into a specific upgrade error).
# With --peer the message is treated as received from that peer: From must
# name that host (a bare From is qualified with it; any other host is
# refused) and bare To/Cc addresses, which are in the sender's frame, are
# qualified with it too. --peer also refuses a message in which no To/Cc
# address is a lane on this host after normalisation (the one-line error
# names this host's peer name): the sender's name for this host did not match
# ours, or the mail was not for us, and no inbox or watcher would ever see
# it. This is the receiving half of lane-mail-serve; the peer name comes from
# its forced command, never from the message.
#
# `export <thread-id> --json` prints one thread as a JSON object (every
# header line, the verbatim body, attachment sizes, per-sender counts) for
# dashboards. --json is required: export has no other format. It is
# fork-sandbox-mail-render.py --json, run against this store; nothing is
# written.
#
# `list` prints one TSV line per thread: thread id, message count, root
# Subject, last message's Date. With --json it prints one JSON array, one
# object per thread; each --header 'Name: value' (split on the first colon)
# keeps only threads whose ROOT message has that header -- any name,
# case-insensitive name, exact value, several ANDed; replies never count.
# Bare `list` runs here in bash; with any flag it is
# fork-sandbox-mail-render.py --list, which owns the parsing and the filter.
# The JSON object shape is documented in docs/agent-mail.md.
#
# This is a store, not a router: `send`/`reply` write messages, `show`/
# `tree`/`list`/`inbox`/`seen` read them back. There is no agent spawning, no
# fleet registry, and no delivery beyond what `inbox` computes by scanning
# headers. Later rounds build a router and a registry on top of this.
#
# `reply --upstream-head <branch>:<sha>` tells a running review thread that
# the upstream moved: <branch> is a git branch name, <sha> a full 40-hex
# commit sha. It stamps `X-Upstream-Head: <branch> <sha>` on the reply, and
# the postmaster delivers that commit to the thread's `sets` seat as a local
# branch named `upstream` (docs/agent-mail.md, "Upstream moved"). Reply only:
# `send --upstream-head` is refused, since there is no thread to move. It is
# the ONLY way to produce the header -- a raw `--header X-Upstream-Head: ...`
# is refused here and at the mail API.
#
# `reply --upstream-state closed|open` tells the postmaster the upstream pull
# request the thread reviews was closed or merged (`closed`: it stops waking
# seats on the thread and treats it as finished) or reopened (`open`). It
# stamps `X-Upstream-State: closed|open` on the reply (docs/agent-mail.md,
# "Upstream closed"), and may be given together with --upstream-head. Reply
# only, for the same reason as --upstream-head, and the ONLY way to produce
# the header: a raw `--header X-Upstream-State: ...` (any letter case) is
# refused here and at the mail API. The postmaster honors it from a sender
# that is not a fleet agent only.
#
# Layout, under $FORK_SANDBOX_MAIL_ROOT (default
# /var/tmp/claude-scratch/agent-mail):
#
#   <root>/threads/<thread-id>/<NNN>-<uuid>.msg   # NNN = 3-digit arrival seq
#   <root>/threads/<thread-id>/attachments/<basename>
#   <root>/agents/<name>/seen                     # append-only message-id list
#   <root>/.postmaster/grants/<thread-id>.env     # per-thread k8s egress grant,
#                                                  # see the `grant` verb below
#   <root>/.postmaster/review-target/<thread-id>.env  # a review thread's
#                                                  # shared review target
#                                                  # (BRANCH/SHA/VERSION/
#                                                  # SET_BY/SET_AT), written by
#                                                  # `send --review-target`
#                                                  # here and moved by the
#                                                  # postmaster's `sets` seat
#                                                  # -- see docs/agent-mail.md
#   <root>/.postmaster/services-env/<thread-id>.env  # KEY=VAL lines the
#                                                  # postmaster passes to the
#                                                  # thread's local seats'
#                                                  # services hook, written by
#                                                  # `send --services-env`
#
# <thread-id> is the Message-ID of the thread's root message (the message
# `send` created it with). NNN starts at 001 and counts arrival order within
# the thread.
#
# Message format is RFC 5322-shaped: a header block, a blank line, then the
# body verbatim. Headers, in this order:
#
#   Message-ID: <uuid>            generated here, never caller-supplied
#   Thread-ID: <root uuid>        equals Message-ID on a thread root
#   Date: <RFC 2822 date, UTC>
#   From: @<name>
#   To: @<name>[, @<name>...]     reply, if --to is omitted, defaults to
#                                 reply-all: the parent's From + To + Cc,
#                                 deduped, minus the replying sender
#   Cc: @<name>[, @<name>...]     omitted entirely when there is no Cc
#   Subject: <text>               replies default to "Re: <parent subject>"
#   In-Reply-To: <parent uuid>    replies only
#   References: <uuid> <uuid>...  replies only: parent's References, then
#                                 the parent's own id, root-to-parent order
#   X-Hops: <int>                 default 8 on a new thread; a reply COPIES
#                                 the parent's value verbatim unless --hops
#                                 overrides it -- decrementing on an
#                                 ordinary reply is the ROUTER's job (round
#                                 3), not this store's; --hops just gives
#                                 it (or an operator) the override to do it
#                                 with
#   X-Thread-Budget: <n>          `send --budget <n>` only (a positive
#                                 integer, no leading zero, refused before
#                                 the thread exists): this thread's own cap
#                                 on seat spawns, on the thread's root
#                                 only. The postmaster uses the lower of it
#                                 and its global budget; absent means the
#                                 global one (docs/agent-mail.md)
#   X-Grant: none                 `send --no-grant` only (refused together
#                                 with any grant flag), on the thread's
#                                 root only: this thread has no
#                                 environment, so a `grant: required` k8s
#                                 seat spawns with no grant flags instead
#                                 of holding, and `grant <tid> <values>`
#                                 refuses the thread. Absent never means
#                                 "no environment" (docs/agent-mail.md)
#   X-<Name>: <value>             any number of caller-supplied custom
#                                 headers, via a repeatable --header
#                                 'X-Name: value' flag on send/reply. Name
#                                 must match ^X-[A-Za-z0-9-]+$ (only custom
#                                 X- headers may be set this way; core
#                                 headers are refused by the name pattern
#                                 alone) and may not be X-Hops,
#                                 X-Attachment, X-Upstream-Head,
#                                 X-Upstream-State, X-Thread-Budget or
#                                 X-Grant (any letter case), which this
#                                 store writes itself (the upstream ones
#                                 only via `reply --upstream-head` and
#                                 `reply --upstream-state`, the budget only
#                                 via `send --budget`, X-Grant only via
#                                 `send --no-grant`). --header
#                                 does not refuse
#                                 X-Review-Target/X-Review-Target-Set/
#                                 X-Version -- those are stamped by
#                                 `send --review-target` and by the
#                                 postmaster (see docs/agent-mail.md); a
#                                 remote client is refused them at the mail
#                                 API instead (docs/mail-api.md).
#   X-Attachment: attachments/<basename>   one line per attachment
#   X-Review-Target-Set: <branch> <sha>    `send --review-target
#                                 <branch>:<sha>` only: the message that
#                                 opened this thread's shared review
#                                 target, VERSION 1 (see the state-file
#                                 layout above and docs/agent-mail.md)
#   X-Review-Target: <branch> <sha>        the same value, present on
#                                 every message about the target -- see
#                                 docs/agent-mail.md's header contract
#   X-Version: <n>                the review target's version this
#                                 message belongs to; 1 on the message
#                                 that opened the thread
#   X-Upstream-Head: <branch> <sha>        `reply --upstream-head
#                                 <branch>:<sha>` only: the upstream moved
#                                 to that commit -- see the paragraph on
#                                 `reply --upstream-head` above
#   X-Upstream-State: closed|open          `reply --upstream-state` only: the
#                                 upstream pull request was closed or
#                                 reopened -- see the paragraph on
#                                 `reply --upstream-state` above
#
# Unlike the RFC-2822-style angle-bracket/domain ids this repo's old
# lkml-mailbox.sh used, ids here are bare uuids with no "<...>" wrapping and
# no "@domain" suffix -- Message-ID and Thread-ID are literal uuid values.
#
# Addressing. Every address (in --from/--to/--cc) is `@name` or
# `@name:host`. The name must match [a-z0-9][a-z0-9-]* -- lowercase alnum,
# hyphens allowed, no leading hyphen; a host (a lane-mail peer name) matches
# [a-z0-9][a-z0-9.-]*. Anything else is refused with a one-line error. A
# bare `@name` means this host. An address naming this host's own peer name
# (LANE_MAIL_PEER_NAME in the config dir's lane-mail.env, default the short
# hostname; see lane-mail-lib.sh) is stored in the bare form, so inboxes,
# `seen` and watchers see one spelling. `inbox` and `seen` take a bare lane
# name only. This store does not route: an `@name:host` address is just text
# here (lane-mail.sh does the delivery), and the fleet postmaster treats one
# like any name it cannot resolve. There is no
# registry: this script does not know or care whether a name refers to a
# live agent. --to and --cc each take a comma-separated list and may be
# repeated; repeats accumulate, so `--to @a --to @b` is `--to @a,@b`.
#
# Privacy is addressing, not access control. This store has no ACLs at all:
# `show`, `tree`, `list` and a raw grep of the store see every message
# regardless of who it was addressed to -- they are host-side operator
# tools. The ONLY privacy mechanism is `inbox <name>`, which surfaces just
# the messages that name @<name> in their To or Cc. An agent that only ever
# calls `inbox` for its own name sees only its own mail; anything with
# filesystem access to the store sees everything.
#
# NNN allocation and concurrency. Two posts landing in the same thread at
# once race for the same NNN. This is resolved with an `mkdir`-based lock,
# not a check-then-write: for a candidate NNN, `mkdir` a reservation
# directory named "<NNN>.seq" that carries no uuid, so two posters
# guessing the same NNN are contending for the exact same path and `mkdir`
# fails atomically with EEXIST for the loser -- there is no window where
# both could believe they own the NNN. The loser bumps NNN and retries,
# up to a bounded number of attempts; a failure that is not "the slot is
# taken" (permission denied, ENOSPC, a read-only thread dir) aborts with a
# diagnostic instead of retrying forever, since nothing about those is
# fixed by trying again. Once a reservation directory is won, the message
# (already written in full to a temp file) is renamed into place at
# "<NNN>-<uuid>.msg" -- a plain `mv`, safe because the NNN is now
# exclusively ours. Reservation directories are never removed: doing so
# would free the NNN for reuse while a message still occupies it,
# recreating the duplicate-NNN bug this scheme exists to prevent.
#
# Attachments are copied into <thread-id>/attachments/, capped at 4 MiB
# each. A basename already staged with different content is refused --
# the attachments directory is flat and keyed on basename alone, so
# silently overwriting it would leave an earlier message's X-Attachment
# header pointing at the wrong file. Identical content under the same
# basename is accepted silently (two messages may legitimately share one
# attachment). Two --attach arguments in one command that share a
# basename but differ in content are refused for the same reason -- the
# second `cp` would clobber the first. A basename containing a newline is
# refused too: the staged basename list is '/'-joined and split back
# apart with `read -ra`, which stops at the first newline and would
# silently truncate the list.
#
# A cross-host bundle (--emit with --attach; see "Lane mail between hosts"
# in docs/agent-mail.md) applies a stricter basename rule on both ends,
# since the receiving `ingest` trusts a peer less than a local caller:
# non-empty, at most 255 bytes, not "." or "..", no "/", no control
# character (a newline included), and no leading "-". The same collision
# and dedup rules apply, plus one more: two attachment frames in one
# bundle sharing a basename are refused unless byte-identical, same as two
# --attach arguments sharing a basename locally.

set -euo pipefail

MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"
MAIL_ATTACH_MAX_BYTES=$(( 4 * 1024 * 1024 ))
# An address is `@lane` (this host) or `@lane:host` (a peer's lane; see
# "Addressing" in the header). Same lane and host shapes as
# LANE_MAIL_LANE_RE / LANE_MAIL_HOST_RE in lane-mail-lib.sh.
MAIL_ADDR_RE='^@[a-z0-9][a-z0-9-]*(:[a-z0-9][a-z0-9.-]*)?$'
MAIL_INGEST_MAX_BYTES=$(( 1024 * 1024 ))
# A LANE-MAIL-BUNDLE carries at most this many attachments (sender and
# receiver both enforce it; see docs/agent-mail.md, "Lane mail between
# hosts"). MAIL_BUNDLE_MAX_BYTES bounds the whole wire stream `ingest` will
# ever read for one delivery -- the message cap, plus the worst case of
# attachments at the count and size caps, plus generous slack for frame
# lines -- so a sender that never stops sending can't make `ingest` read an
# unbounded amount.
MAIL_ATTACH_MAX_COUNT=8
MAIL_BUNDLE_MAX_BYTES=$(( MAIL_INGEST_MAX_BYTES + MAIL_ATTACH_MAX_COUNT * MAIL_ATTACH_MAX_BYTES + 8192 ))
# Same hex-id shape as fork-sandbox.sh's own session-id check: no slashes,
# no dots, no leading hyphen. mail_new_uuid never generates anything else,
# so a caller-supplied id failing this shape is not a thread id this store
# could have created.
MAIL_ID_RE='^[0-9a-f][0-9a-f-]{7,63}$'
MAIL_SEQ_MAX_TRIES=10000

# Scripts are symlinked into ~/.claude/scripts, so a plain "dirname $0" is
# wrong; this matches how fork-sandbox.sh and fork-sandbox-fleet.sh locate
# their own siblings.
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/lane-mail-lib.sh"

usage() {
    # The header block is the documentation: print it from line 2 down to
    # the first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

mail_threads_dir() {
    printf '%s/threads' "$MAIL_ROOT"
}

mail_thread_dir() {
    printf '%s/threads/%s' "$MAIL_ROOT" "$1"
}

mail_validate_addr() {
    if [[ ! "$1" =~ $MAIL_ADDR_RE ]]; then
        echo "Error: '$1' is not a valid address; addresses look like" >&2
        echo "'@name' or '@name:host', lowercase alphanumeric and '-' only in" >&2
        echo "the name (no leading '-'); a host may also contain '.'." >&2
        return 1
    fi
    return 0
}

# An inbox or seen-list belongs to a lane on THIS host: a bare name only.
# `@lane:host` is a valid address but never a mailbox here -- a remote inbox
# is read on the remote host.
mail_validate_inbox_name() {
    local name="$1" verb="$2"
    if [[ "$name" == *:* ]]; then
        echo "Error: $verb: '$name' names another host; $verb works on this host's" >&2
        echo "lanes only (use the bare lane name)." >&2
        return 1
    fi
    mail_validate_addr "@$name"
}

# Rejects a value containing a raw newline. Header values are joined into
# the header block with newlines and everything up to the first blank
# line is parsed as a header, so a newline inside a value (e.g. a
# caller-supplied --subject) would forge or truncate header lines. A bare
# CR counts too: the renderer reads the store with universal newlines, so
# it splits there and shows the rest as a header line of its own.
mail_validate_no_newline() {
    local val="$1" field="$2"
    if [[ "$val" == *[$'\n\r']* ]]; then
        echo "Error: $field must not contain a newline or carriage return." >&2
        return 1
    fi
    return 0
}

# Validates one --header 'X-Name: value' argument and prints it back as a
# normalized "X-Name: value" header line. Refuses a raw newline (would
# forge or truncate header lines, same reasoning as mail_validate_no_newline),
# any name that isn't ^X-[A-Za-z0-9-]+$ (core, non-X headers are refused by
# this pattern alone -- only custom X- headers may be set this way), and the
# reserved names this store writes itself (X-Hops, X-Attachment,
# X-Upstream-Head, X-Upstream-State, X-Thread-Budget, X-Grant), in any letter case.
mail_validate_header() {
    local raw="$1" name value
    mail_validate_no_newline "$raw" "--header" || return 1
    if [[ "$raw" != *:* ]]; then
        echo "Error: --header '$raw' must look like 'X-Name: value'." >&2
        return 1
    fi
    name="${raw%%:*}"
    value="${raw#*:}"
    value="${value# }"
    if [[ ! "$name" =~ ^X-[A-Za-z0-9-]+$ ]]; then
        echo "Error: --header name '$name' must match 'X-[A-Za-z0-9-]+' -- only custom X- headers may be set." >&2
        return 1
    fi
    case "${name^^}" in
        X-HOPS|X-ATTACHMENT|X-UPSTREAM-HEAD|X-UPSTREAM-STATE|X-THREAD-BUDGET|X-GRANT)
            echo "Error: --header may not set reserved header '$name'." >&2
            return 1
            ;;
    esac
    printf '%s: %s' "$name" "$value"
}

# Strips leading/trailing whitespace and prints the result.
mail_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Prints a validated address in this store's own terms: an address naming
# this host (`@lane:<self>`) becomes the bare `@lane`, so inboxes, `seen`
# and watchers see one spelling. Anything else passes through. When this
# host's peer name cannot be determined nothing can match it, so nothing
# is rewritten.
mail_norm_addr() {
    local a="$1" self
    if [[ "$a" == *:* ]] && self="$(lane_mail_self_name)" && [[ "${a#*:}" == "$self" ]]; then
        a="${a%%:*}"
    fi
    printf '%s' "$a"
}

# Prints address $1 qualified with host $2 unless it already names a host.
mail_qualify_addr() {
    if [[ "$1" == *:* ]]; then
        printf '%s' "$1"
    else
        printf '%s:%s' "$1" "$2"
    fi
}

# Prints the comma-separated list $1 ", "-joined with every bare address
# qualified with host $2. Empty elements are kept so that validation, which
# runs afterwards, still refuses them.
mail_qualify_list() {
    local list="$1" host="$2" p out="" first=1
    local -a parts
    IFS=',' read -ra parts <<< "$list"
    for p in "${parts[@]}"; do
        p="$(mail_trim "$p")"
        [[ -z "$p" ]] || p="$(mail_qualify_addr "$p" "$host")"
        if (( first )); then out="$p"; first=0; else out="$out, $p"; fi
    done
    printf '%s' "$out"
}

# Validates a comma-separated list of addresses and prints it back
# normalized as ", "-joined, or nothing for an empty list.
mail_validate_addr_list() {
    local list="$1"
    [[ -n "$list" ]] || return 0
    local -a parts
    IFS=',' read -ra parts <<< "$list"
    local p out=""
    for p in "${parts[@]}"; do
        p="$(mail_trim "$p")"
        mail_validate_addr "$p" || return 1
        p="$(mail_norm_addr "$p")"
        out="${out:+$out, }$p"
    done
    printf '%s' "$out"
}

mail_new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

# Prints one header's value from a message file, or nothing if absent.
# Reads only up to the first blank line, which is where headers end.
mail_header() {
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

# Counts how many header lines named $2 a message file $1 carries -- for
# X-Attachment, which may legitimately repeat once per attached file.
mail_count_header() {
    local file="$1" name="$2" line count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        [[ "$line" == "$name:"* ]] && count=$(( count + 1 ))
    done < "$file"
    printf '%s' "$count"
}

# Finds the message file whose Message-ID equals $1, across every thread.
# Prints its path on stdout, or returns 1 if there is no such message.
mail_find_by_id() {
    local id="$1" dir f
    dir="$(mail_threads_dir)"
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/*/*.msg; do
        [[ -e "$f" ]] || continue
        if [[ "$(mail_header "$f" Message-ID)" == "$id" ]]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# Confirms $1 names an existing thread ROOT (a message whose own
# Message-ID equals its Thread-ID) without ever building a path from the
# caller-supplied id directly: mail_find_by_id locates the file by
# scanning and comparing header content, so an id shaped like a path
# traversal can't escape the store.
mail_thread_root_exists() {
    local tid="$1" f
    f="$(mail_find_by_id "$tid")" || return 1
    [[ "$(mail_header "$f" Thread-ID)" == "$tid" ]]
}

# Rejects a thread id that isn't shaped like a Message-ID this store would
# ever generate (mail_new_uuid) -- required before the id is ever used to
# build a path directly (the grant file, e.g.) rather than routed through
# mail_find_by_id's scan-and-compare, since mail_thread_root_exists above
# only confirms a message with that id-as-header-text exists, not that the
# id is itself path-safe.
mail_validate_thread_id() {
    if [[ ! "$1" =~ $MAIL_ID_RE ]]; then
        echo "Error: ${2:-grant}: '$1' is not a valid thread id." >&2
        return 1
    fi
    return 0
}

# Runs check-grant on the given args, mapping its exit status to this
# store's grant-flag contract: 2 = refused value, 1 = usage/other
# failure. Prints check-grant's stdout on success; its stderr passes
# through to this script's own stderr either way.
mail_check_grant() {
    local out rc=0
    out="$("$script_dir/fork-sandbox-k8s.sh" check-grant "$@")" || rc=$?
    if (( rc == 2 )); then
        return 2
    elif (( rc != 0 )); then
        return 1
    fi
    printf '%s' "$out"
    return 0
}

# Writes the per-thread grant file for <tid> from check-grant's output,
# atomically (mktemp in the same dir, then mv) and idempotently: an
# unchanged grant leaves the file's mtime alone, a changed one replaces
# it wholesale (never merges). This is the one place outside the
# postmaster that writes postmaster state (.postmaster/grants/); a
# single store-tool writing one postmaster-state file is an accepted
# coupling.
mail_write_grant() {
    local tid="$1"; shift
    local out
    out="$(mail_check_grant "$@")" || return $?
    local grants_dir="$MAIL_ROOT/.postmaster/grants"
    mkdir -p -- "$grants_dir" || return 1
    local dest="$grants_dir/$tid.env"
    local tmp
    tmp="$(mktemp "$grants_dir/.grant.XXXXXX")" || return 1
    printf '%s\n' "$out" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    if [[ -f "$dest" ]] && cmp -s -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
    else
        mv -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
    fi
    return 0
}

# Checks --services-env values with the lib's fs_services_env_check, against
# the allowlist in this host's fork-sandbox config dir. A subshell, so the
# lib's globals stay out of this store tool.
mail_check_services_env() {
    (
        # Not followed: the lib's own globals, set only in this subshell,
        # would read to shellcheck as this script's.
        # shellcheck source=/dev/null
        source "$script_dir/fork-sandbox-lib.sh"
        fs_services_env_check "${FORK_SANDBOX_CONFIG_DIR:-$HOME/.config/fork-sandbox}" "$@"
    )
}

# Writes the per-thread services-env file for <tid>, one KEY=VAL per line in
# the order given, atomically -- send-only, so always a fresh write, as
# mail_write_review_target.
mail_write_services_env() {
    local tid="$1"; shift
    local se_dir="$MAIL_ROOT/.postmaster/services-env"
    mkdir -p -- "$se_dir" || return 1
    local tmp
    tmp="$(mktemp "$se_dir/.services-env.XXXXXX")" || return 1
    printf '%s\n' "$@" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$se_dir/$tid.env" || { rm -f -- "$tmp"; return 1; }
}

# Validates a `--review-target <branch>:<sha>` value, split on the LAST
# ':' -- a branch name cannot itself contain ':' (git check-ref-format),
# so the split is unambiguous. Prints "<branch>\t<sha>" on success. This
# store never resolves refs or runs git against a project (see the header
# comment): check-ref-format validates the branch NAME's shape only, no
# repository required, so it stays within that rule.
mail_validate_review_target() {
    local raw="$1" branch sha
    mail_validate_no_newline "$raw" "--review-target" || return 1
    if [[ "$raw" != *:* ]]; then
        echo "Error: --review-target '$raw' must look like '<branch>:<sha>'." >&2
        return 1
    fi
    branch="${raw%:*}"
    sha="${raw##*:}"
    if [[ -z "$branch" ]] || [[ "$branch" == *[[:space:]]* ]] || \
       ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        echo "Error: --review-target: '$branch' is not a valid branch name." >&2
        return 1
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: --review-target: '$sha' must be a 40- or 64-character" >&2
        echo "lowercase hex sha." >&2
        return 1
    fi
    printf '%s\t%s' "$branch" "$sha"
}

# Validates a `--upstream-head <branch>:<sha>` value, split on the LAST ':'
# (see mail_validate_review_target). Stricter than a review target: the sha
# must be a full 40-hex commit sha. Prints "<branch>\t<sha>" on success.
mail_validate_upstream_head() {
    local raw="$1" branch sha
    mail_validate_no_newline "$raw" "--upstream-head" || return 1
    if [[ "$raw" != *:* ]]; then
        echo "Error: --upstream-head '$raw' must look like '<branch>:<sha>'." >&2
        return 1
    fi
    branch="${raw%:*}"
    sha="${raw##*:}"
    if [[ -z "$branch" ]] || [[ "$branch" == *[[:space:]]* ]] || \
       ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        echo "Error: --upstream-head: '$branch' is not a valid branch name." >&2
        return 1
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: --upstream-head: '$sha' must be a full 40-character" >&2
        echo "lowercase hex commit sha." >&2
        return 1
    fi
    printf '%s\t%s' "$branch" "$sha"
}

# Validates a `--upstream-state <closed|open>` value and prints it back.
mail_validate_upstream_state() {
    local raw="$1"
    mail_validate_no_newline "$raw" "--upstream-state" || return 1
    if [[ "$raw" != closed && "$raw" != open ]]; then
        echo "Error: --upstream-state '$raw' must be 'closed' or 'open'." >&2
        return 1
    fi
    printf '%s' "$raw"
}

# Writes the per-thread review-target state file for <tid>, atomically
# (mktemp in the same dir, then mv) -- mirrors mail_write_grant, but this
# is always a fresh write for a brand-new thread id (send-only, see
# cmd_send), never a replace of an existing file.
mail_write_review_target() {
    local tid="$1" branch="$2" sha="$3" version="$4" set_by="$5"
    local rt_dir="$MAIL_ROOT/.postmaster/review-target"
    mkdir -p -- "$rt_dir" || return 1
    local dest="$rt_dir/$tid.env"
    local tmp
    tmp="$(mktemp "$rt_dir/.review-target.XXXXXX")" || return 1
    {
        printf 'BRANCH=%s\n' "$branch"
        printf 'SHA=%s\n' "$sha"
        printf 'VERSION=%s\n' "$version"
        printf 'SET_BY=%s\n' "$set_by"
        printf 'SET_AT=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# Escapes a string for embedding in a JSON string context. Grant values
# are shell tokens the k8s validators have already shape-checked (a
# thread id, an NS[:PORT], a HOST:PORT, or a realpath) but
# validate_context_ro_dir only checks path shape, not byte content, so a
# directory basename may legally carry any control byte a filesystem
# allows; every U+0000-U+001F byte is escaped here, not just the common
# ones, so --show --json always emits valid JSON.
mail_json_escape() {
    local s="$1" out="" i n c code esc
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        case "$c" in
            $'\n') out+='\n'; continue ;;
            $'\r') out+='\r'; continue ;;
            $'\t') out+='\t'; continue ;;
        esac
        LC_ALL=C printf -v code '%d' "'$c"
        if (( code < 0x20 )); then
            printf -v esc '\\u%04x' "$code"
            out+="$esc"
        else
            out+="$c"
        fi
    done
    printf '%s' "$out"
}

# Prints a JSON array of already-escaped double-quoted strings from a
# nameref array, e.g. ("a" "b") -> ["a", "b"], () -> [].
mail_json_string_array() {
    local -n arr_ref="$1"
    if (( ${#arr_ref[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    local out="[" first=1 v
    for v in "${arr_ref[@]}"; do
        if (( first )); then first=0; else out+=", "; fi
        out+="\"$v\""
    done
    out+="]"
    printf '%s' "$out"
}

# Prints the JSON form of thread $1's grant file $2 (or the literal null
# when there is none), for `grant --show --json`.
mail_grant_print_json() {
    local tid="$1" grant_file="$2"
    if [[ ! -f "$grant_file" ]]; then
        printf 'null\n'
        return 0
    fi
    local -a ns=() probe=() host_aliases=() seat_resources=()
    local ctx="null" ctx_secret="null" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            ALLOW_NAMESPACE=*) ns+=("$(mail_json_escape "${line#ALLOW_NAMESPACE=}")") ;;
            REACH_PROBE=*) probe+=("$(mail_json_escape "${line#REACH_PROBE=}")") ;;
            HOST_ALIAS=*) host_aliases+=("$(mail_json_escape "${line#HOST_ALIAS=}")") ;;
            SEAT_RESOURCES=*) seat_resources+=("$(mail_json_escape "${line#SEAT_RESOURCES=}")") ;;
            CONTEXT_RO=*) ctx="\"$(mail_json_escape "${line#CONTEXT_RO=}")\"" ;;
            CONTEXT_SECRET=*) ctx_secret="\"$(mail_json_escape "${line#CONTEXT_SECRET=}")\"" ;;
        esac
    done < "$grant_file"
    printf '{"thread": "%s", "allow_namespace": %s, "reach_probe": %s, "host_alias": %s, "seat_resources": %s, "context_ro": %s, "context_secret": %s}\n' \
        "$(mail_json_escape "$tid")" "$(mail_json_string_array ns)" "$(mail_json_string_array probe)" \
        "$(mail_json_string_array host_aliases)" "$(mail_json_string_array seat_resources)" "$ctx" "$ctx_secret"
}

# Validates and copies each --attach file into <thread-dir>/attachments/,
# printing a '/'-separated list of one basename per *distinct staged file*
# on stdout (two --attach args with the same basename collapse to one
# entry once the validation loop below has proved they're byte-identical)
# -- '/' rather than ',' since a basename may legally contain a comma but,
# by construction of `basename`, never a '/'.
mail_stage_attachments() {
    local thread_dir="$1"; shift
    local dir="$thread_dir/attachments"
    local -a names=() seen_bases=() seen_files=()
    local f base size i

    # Validate every attachment before staging any of them: basename
    # (newline), existence, size cap, collision against a file already
    # staged by an earlier message in this thread, and collision against
    # another --attach in *this* invocation sharing the same basename.
    # None of these checks depends on a prior `cp`, so running them all
    # up front means a refusal here stages zero files and writes no
    # message -- no half-copied attachments left behind to poison a later,
    # unrelated message with the same basename.
    for f in "$@"; do
        base="$(basename -- "$f")"
        mail_validate_no_newline "$base" "--attach basename '$base'" || return 1
        [[ -f "$f" ]] || { echo "Error: --attach file '$f' not found." >&2; return 1; }
        size="$(wc -c < "$f" | tr -d '[:space:]')"
        if (( size > MAIL_ATTACH_MAX_BYTES )); then
            echo "Error: --attach file '$f' is $size bytes, over the" >&2
            echo "$MAIL_ATTACH_MAX_BYTES byte (4 MiB) cap." >&2
            return 1
        fi
        if [[ -e "$dir/$base" ]] && ! cmp -s -- "$f" "$dir/$base"; then
            echo "Error: --attach '$f' would overwrite attachments/$base," >&2
            echo "which already holds different content staged by an earlier" >&2
            echo "message in this thread. Rename the file and retry." >&2
            return 1
        fi
        for ((i = 0; i < ${#seen_bases[@]}; i++)); do
            if [[ "${seen_bases[i]}" == "$base" ]] && ! cmp -s -- "$f" "${seen_files[i]}"; then
                echo "Error: --attach '$f' and '${seen_files[i]}' both map to" >&2
                echo "attachments/$base but have different content; they were" >&2
                echo "given together in this command. Rename one and retry." >&2
                return 1
            fi
        done
        seen_bases+=("$base")
        seen_files+=("$f")
    done

    for f in "$@"; do
        base="$(basename -- "$f")"
        mkdir -p -- "$dir"
        cp -f -- "$f" "$dir/$base"
        # A second --attach with this basename is only still here because
        # the validation loop above let it through, which means its
        # content is byte-identical to the first (the cmp -s check would
        # have refused otherwise) -- so it's safe to cp every argument
        # but list the basename only once.
        local dup=0 n
        for n in "${names[@]:-}"; do
            [[ "$n" == "$base" ]] && { dup=1; break; }
        done
        (( dup )) || names+=("$base")
    done
    (IFS='/'; printf '%s' "${names[*]:-}")
}

# The basename rule a cross-host bundle attachment holds both ends to (see
# "Lane mail between hosts" in docs/agent-mail.md): non-empty, at most 255
# bytes, not "." or "..", no "/", no control character (a newline
# included), and no leading "-" (which a tool reading the staged file by
# name alone could otherwise read as an option). $2, if given, names the
# thing being validated for the error text (default "attachment"). The
# 255-byte limit is measured with `wc -c`, not bash's `${#base}`: the
# latter counts characters, and this script runs in whatever locale the
# caller (or, cross-host, the ssh session) has -- a multibyte basename
# could otherwise pass here and still be too long for the filesystem.
mail_validate_attach_basename() {
    local base="$1" what="${2:-attachment}" blen
    if [[ -z "$base" ]]; then
        echo "Error: $what basename must not be empty." >&2
        return 1
    fi
    blen="$(printf '%s' "$base" | wc -c)"
    if (( blen > 255 )); then
        echo "Error: $what basename '${base:0:60}...' is over 255 bytes." >&2
        return 1
    elif [[ "$base" == "." || "$base" == ".." ]]; then
        echo "Error: $what basename must not be '.' or '..'." >&2
        return 1
    elif [[ "$base" == */* ]]; then
        echo "Error: $what basename '$base' must not contain '/'." >&2
        return 1
    elif [[ "$base" == -* ]]; then
        echo "Error: $what basename '$base' must not start with '-'." >&2
        return 1
    elif [[ "$base" =~ [[:cntrl:]] ]]; then
        echo "Error: $what basename must not contain a newline or control character." >&2
        return 1
    fi
    return 0
}

# A hex sha256 of file $1, portable across the GNU/BSD/minimal split (same
# fallback chain as fork-sandbox-lib.sh's k8s_sha256_stdin, but over a file
# rather than stdin, since a cross-host attachment is hashed twice: once
# while building the bundle, once while verifying it on ingest).
mail_sha256_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$f" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$f" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 -- "$f" | sed 's/^.* //'
    else
        echo "Error: none of sha256sum, shasum or openssl found; one is needed" >&2
        echo "to checksum a cross-host mail attachment." >&2
        return 1
    fi
}

# Validates each --attach file for a LANE-MAIL-BUNDLE (see mail_emit_bundle)
# without touching the store: basename shape (mail_validate_attach_basename),
# existence, the size cap, and the same within-invocation collision/dedup
# rules as mail_stage_attachments. $1 is the sender's own thread dir for a
# reply ("" for a send): the sender's local copy of the bundle is ingested
# only after every remote host accepted it, so a collision there must be
# caught now, before ssh runs. Enforces the MAIL_ATTACH_MAX_COUNT cap here
# too. Prints one "<basename>\t<file>" line per distinct staged attachment,
# in --attach order.
mail_emit_validate_attach() {
    local thread_dir="$1"; shift
    local -a seen_bases=() seen_files=() out=()
    local f base size i dup
    if (( $# > MAIL_ATTACH_MAX_COUNT )); then
        echo "Error: --emit: a message may carry at most $MAIL_ATTACH_MAX_COUNT attachments." >&2
        return 1
    fi
    for f in "$@"; do
        base="$(basename -- "$f")"
        mail_validate_attach_basename "$base" "--attach basename" || return 1
        [[ -f "$f" ]] || { echo "Error: --attach file '$f' not found." >&2; return 1; }
        size="$(wc -c < "$f" | tr -d '[:space:]')"
        if (( size > MAIL_ATTACH_MAX_BYTES )); then
            echo "Error: --attach file '$f' is $size bytes, over the" >&2
            echo "$MAIL_ATTACH_MAX_BYTES byte (4 MiB) cap." >&2
            return 1
        fi
        if [[ -n "$thread_dir" && -e "$thread_dir/attachments/$base" ]] \
            && ! cmp -s -- "$f" "$thread_dir/attachments/$base"; then
            echo "Error: --attach '$f' would overwrite attachments/$base," >&2
            echo "which already holds different content staged by an earlier" >&2
            echo "message in this thread. Rename the file and retry." >&2
            return 1
        fi
        dup=0
        for ((i = 0; i < ${#seen_bases[@]}; i++)); do
            [[ "${seen_bases[i]}" == "$base" ]] || continue
            if ! cmp -s -- "$f" "${seen_files[i]}"; then
                echo "Error: --attach '$f' and '${seen_files[i]}' both map to" >&2
                echo "attachments/$base but have different content; they were" >&2
                echo "given together in this command. Rename one and retry." >&2
                return 1
            fi
            dup=1
            break
        done
        if (( ! dup )); then
            seen_bases+=("$base")
            seen_files+=("$f")
            out+=("$base"$'\t'"$f")
        fi
    done
    printf '%s\n' "${out[@]}"
}

# Writes headers + a blank line + the body (from $2, a file, copied
# verbatim) to a fresh temp file, then claims a NNN via the mkdir-lock
# scheme documented above and renames the temp file into place under $3
# (thread dir). Prints the final NNN-uuid basename on success.
mail_place_message() {
    local headers="$1" body_file="$2" thread_dir="$3" uuid="$4"
    local tmp
    tmp="$(mktemp "$MAIL_ROOT/.mail.XXXXXX")"
    {
        printf '%s\n' "$headers"
        printf '\n'
        cat -- "$body_file"
    } > "$tmp"
    local n lock tries=0
    n=$(( $(find "$thread_dir" -maxdepth 1 -name '*.msg' | wc -l) + 1 ))
    while :; do
        lock="$thread_dir/$(printf '%03d' "$n").seq"
        if mkdir -- "$lock" 2>/dev/null; then
            break
        fi
        if [[ ! -e "$lock" ]]; then
            rm -f -- "$tmp"
            echo "Error: could not reserve a sequence number in '$thread_dir'" >&2
            echo "(mkdir failed for a reason other than the slot being taken)." >&2
            return 1
        fi
        n=$(( n + 1 ))
        tries=$(( tries + 1 ))
        if (( tries > MAIL_SEQ_MAX_TRIES )); then
            rm -f -- "$tmp"
            echo "Error: could not allocate a sequence number in '$thread_dir'" >&2
            echo "after $tries attempts." >&2
            return 1
        fi
    done
    local dest; dest="$thread_dir/$(printf '%03d' "$n")-$uuid.msg"
    mv -- "$tmp" "$dest"
    printf '%s' "$(basename -- "$dest")"
}

# Copies the body into $2 verbatim. Deliberately not a command
# substitution: capturing output that way strips all trailing newlines,
# which would violate the "body stored verbatim" contract once that
# output is written back out.
mail_read_body_arg() {
    local body_arg="$1" dest="$2"
    if [[ "$body_arg" == "-" ]]; then
        cat > "$dest"
    else
        [[ -f "$body_arg" ]] || { echo "Error: body file '$body_arg' not found." >&2; return 1; }
        cat -- "$body_arg" > "$dest"
    fi
}

# Checks the body file directly for any non-space byte, rather than
# loading it into a shell variable first (see mail_read_body_arg above for
# why that would be lossy).
mail_body_is_empty() {
    ! grep -q '[^[:space:]]' -- "$1"
}

# --emit builds a message exactly as send/reply would but prints it instead
# of storing it, so a caller can ship it elsewhere before anything is
# written here. Attachments travel (as a LANE-MAIL-BUNDLE; see
# mail_emit_bundle); grants, a review target and the upstream flags stay in
# the local store regardless. Args: verb, the number of repeatable grant
# values given (every flag), and the concatenation of the single-valued
# flags that --emit cannot carry.
mail_emit_check() {
    local verb="$1" n_multi="$2" other="$3"
    if (( n_multi > 0 )) || [[ -n "$other" ]]; then
        echo "Error: $verb: --emit does not carry grants, a review target, a" >&2
        echo "thread budget, --no-grant, --services-env or upstream flags." >&2
        return 1
    fi
}

# Rewrites the From/To/Cc values named by the three variables ($1 $2 $3)
# into portable form: every bare address qualified with this host's peer
# name, so the message means the same thing on any other host.
mail_emit_addrs() {
    local -n from_ref="$1" to_ref="$2" cc_ref="$3"
    local self
    self="$(lane_mail_self_name)" || {
        echo "Error: --emit needs this host's peer name; set LANE_MAIL_PEER_NAME in" >&2
        echo "$(lane_mail_config_dir)/lane-mail.env (lowercase alphanumeric, '-' and '.')." >&2
        return 1
    }
    from_ref="$(mail_qualify_addr "$from_ref" "$self")"
    to_ref="$(mail_qualify_list "$to_ref" "$self")"
    [[ -z "$cc_ref" ]] || cc_ref="$(mail_qualify_list "$cc_ref" "$self")"
}

# Prints a finished message ($1 headers, $2 body file) and removes the body.
mail_emit_message() {
    printf '%s\n\n' "$1"
    cat -- "$2"
    rm -f -- "$2"
}

# Prints a LANE-MAIL-BUNDLE 1 (see docs/agent-mail.md, "Lane mail between
# hosts", for the exact grammar `ingest` holds a sender to): the plain
# message ($1 headers, $2 body file, removed after) framed with its byte
# count, then one "attachment <basename> <size> <sha256>" frame per
# "<basename>\t<file>" pair in $3..., each immediately followed by that
# many raw bytes and a single newline, then a final "end" line. Every
# frame line ends with "\n"; every payload is followed by exactly one
# "\n" before the next frame line -- the receiver reads both strictly.
mail_emit_bundle() {
    local headers="$1" body_file="$2"; shift 2
    local msg; msg="$(mktemp "$MAIL_ROOT/.mail.emit.XXXXXX")"
    { printf '%s\n\n' "$headers"; cat -- "$body_file"; } > "$msg"
    rm -f -- "$body_file"
    local msg_size; msg_size="$(wc -c < "$msg" | tr -d '[:space:]')"
    printf 'LANE-MAIL-BUNDLE 1\n'
    printf 'message %s\n' "$msg_size"
    cat -- "$msg"
    rm -f -- "$msg"
    printf '\n'
    local entry base f size sha
    for entry in "$@"; do
        base="${entry%%$'\t'*}"
        f="${entry#*$'\t'}"
        size="$(wc -c < "$f" | tr -d '[:space:]')"
        sha="$(mail_sha256_file "$f")" || return 1
        printf 'attachment %s %s %s\n' "$base" "$size" "$sha"
        cat -- "$f"
        printf '\n'
    done
    printf 'end\n'
}

cmd_send() {
    local from="" to="" cc="" subject="" body_arg="" hops=8
    local -a attach_files=() extra_headers=()
    local -a grant_allow_ns=() grant_reach_probe=() grant_host_alias=() grant_seat_resources=()
    local -a services_env=()
    local grant_context_ro="" grant_context_secret="" review_target_arg="" emit=0
    local budget="" no_grant=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --emit) emit=1; shift ;;
            --services-env) services_env+=("${2:?--services-env requires KEY=VALUE}"); shift 2 ;;
            --no-grant) no_grant=1; shift ;;
            --budget) budget="${2:?--budget requires a positive integer}"; shift 2 ;;
            --from) from="${2:?--from requires an address}"; shift 2 ;;
            --to) to="${to:+$to,}${2:?--to requires an address list}"; shift 2 ;;
            --cc) cc="${cc:+$cc,}${2:?--cc requires an address list}"; shift 2 ;;
            --subject) subject="${2:?--subject requires text}"; shift 2 ;;
            --body) body_arg="${2:?--body requires a file, or -}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            --hops) hops="${2:?--hops requires a number}"; shift 2 ;;
            --header) extra_headers+=("${2:?--header requires 'X-Name: value'}"); shift 2 ;;
            --allow-namespace) grant_allow_ns+=("${2:?--allow-namespace requires NS[:PORT]}"); shift 2 ;;
            --reach-probe) grant_reach_probe+=("${2:?--reach-probe requires HOST:PORT}"); shift 2 ;;
            --host-alias) grant_host_alias+=("${2:?--host-alias requires IP=HOST[,HOST...]}"); shift 2 ;;
            --seat-resources) grant_seat_resources+=("${2:?--seat-resources requires SEAT=cpu=QTY[,memory=QTY]}"); shift 2 ;;
            --context-ro) grant_context_ro="${2:?--context-ro requires a directory}"; shift 2 ;;
            --context-secret) grant_context_secret="${2:?--context-secret requires a Secret name}"; shift 2 ;;
            --review-target) review_target_arg="${2:?--review-target requires <branch>:<sha>}"; shift 2 ;;
            --upstream-head)
                echo "Error: send: --upstream-head applies to a reply only (mail reply); a new thread has no" >&2
                echo "upstream to move." >&2
                return 1
                ;;
            --upstream-state)
                echo "Error: send: --upstream-state applies to a reply only (mail reply); a new thread has no" >&2
                echo "upstream to close." >&2
                return 1
                ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: send: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: send: --from is required." >&2; return 1; }
    [[ -n "$to" ]] || { echo "Error: send: --to is required." >&2; return 1; }
    [[ -n "$subject" ]] || { echo "Error: send: --subject is required." >&2; return 1; }
    [[ -n "$body_arg" ]] || { echo "Error: send: --body is required." >&2; return 1; }
    [[ "$hops" =~ ^[0-9]+$ ]] || { echo "Error: send: --hops must be a non-negative integer." >&2; return 1; }
    if [[ -n "$budget" && ! "$budget" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: send: --budget must be a positive integer without a leading zero." >&2
        return 1
    fi
    if (( no_grant )) && { (( ${#grant_allow_ns[@]} > 0 )) || (( ${#grant_reach_probe[@]} > 0 )) \
            || (( ${#grant_host_alias[@]} > 0 )) || (( ${#grant_seat_resources[@]} > 0 )) \
            || [[ -n "$grant_context_ro$grant_context_secret" ]]; }; then
        echo "Error: send: --no-grant opens a thread with no environment and cannot be combined with" >&2
        echo "--allow-namespace, --reach-probe, --host-alias, --seat-resources, --context-ro or" >&2
        echo "--context-secret." >&2
        return 1
    fi
    mail_validate_no_newline "$subject" "--subject" || return 1
    local -a validated_headers=()
    local eh hline
    for eh in "${extra_headers[@]:-}"; do
        [[ -z "$eh" ]] && continue
        hline="$(mail_validate_header "$eh")" || return 1
        validated_headers+=("$hline")
    done

    mail_validate_addr "$from" || return 1
    from="$(mail_norm_addr "$from")"
    local to_norm cc_norm
    to_norm="$(mail_validate_addr_list "$to")" || return 1
    cc_norm=""
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }
    if (( emit )); then
        local no_grant_mark=""
        (( no_grant )) && no_grant_mark="no-grant"
        mail_emit_check send \
            "$(( ${#grant_allow_ns[@]} + ${#grant_reach_probe[@]} + ${#grant_host_alias[@]} + ${#grant_seat_resources[@]} + ${#services_env[@]} ))" \
            "$grant_context_ro$grant_context_secret$review_target_arg$budget$no_grant_mark" || return 1
    fi

    # A grant, if given, is checked before anything is written -- a
    # refused grant must leave no thread dir, no staged attachment, no
    # message -- and the grant file itself is written right after the
    # thread dir exists, before mail_place_message renames the message
    # into place, so a route pass can never see the thread without its
    # grant.
    local -a grant_args=()
    local gv
    for gv in "${grant_allow_ns[@]:-}"; do [[ -n "$gv" ]] && grant_args+=(--allow-namespace "$gv"); done
    for gv in "${grant_reach_probe[@]:-}"; do [[ -n "$gv" ]] && grant_args+=(--reach-probe "$gv"); done
    for gv in "${grant_host_alias[@]:-}"; do [[ -n "$gv" ]] && grant_args+=(--host-alias "$gv"); done
    for gv in "${grant_seat_resources[@]:-}"; do [[ -n "$gv" ]] && grant_args+=(--seat-resources "$gv"); done
    [[ -n "$grant_context_ro" ]] && grant_args+=(--context-ro "$grant_context_ro")
    [[ -n "$grant_context_secret" ]] && grant_args+=(--context-secret "$grant_context_secret")
    local saw_grant=0
    (( ${#grant_args[@]} > 0 )) && saw_grant=1
    if (( saw_grant )); then
        local grant_rc=0
        mail_check_grant "${grant_args[@]}" >/dev/null || grant_rc=$?
        (( grant_rc == 0 )) || return "$grant_rc"
    fi

    # A review target, if given, is validated before anything is written --
    # same reasoning as the grant check just above.
    local review_target_branch="" review_target_sha=""
    if [[ -n "$review_target_arg" ]]; then
        local rt_out
        rt_out="$(mail_validate_review_target "$review_target_arg")" || return 1
        review_target_branch="${rt_out%%$'\t'*}"
        review_target_sha="${rt_out#*$'\t'}"
    fi

    local saw_services_env=0
    if (( ${#services_env[@]} )); then
        mail_check_services_env "${services_env[@]}" || return 1
        saw_services_env=1
    fi

    local body_file; body_file="$(mktemp "$MAIL_ROOT/.mail.body.XXXXXX")"
    mail_read_body_arg "$body_arg" "$body_file" || { rm -f -- "$body_file"; return 1; }
    if mail_body_is_empty "$body_file"; then
        rm -f -- "$body_file"
        echo "Error: send: message body is empty." >&2
        return 1
    fi

    local uuid; uuid="$(mail_new_uuid)"
    local thread_dir; thread_dir="$(mail_thread_dir "$uuid")"
    (( emit )) || mkdir -p -- "$thread_dir"

    if (( saw_grant )); then
        local write_rc=0
        mail_write_grant "$uuid" "${grant_args[@]}" || write_rc=$?
        if (( write_rc != 0 )); then
            rm -f -- "$body_file"
            return "$write_rc"
        fi
    fi

    local saw_review_target=0
    [[ -n "$review_target_sha" ]] && saw_review_target=1
    if (( saw_review_target )); then
        if ! mail_write_review_target "$uuid" "$review_target_branch" \
                "$review_target_sha" 1 "$from"; then
            (( saw_grant )) && rm -f -- "$MAIL_ROOT/.postmaster/grants/$uuid.env"
            rm -f -- "$body_file"
            return 1
        fi
    fi

    if (( saw_services_env )) && ! mail_write_services_env "$uuid" "${services_env[@]}"; then
        (( saw_grant )) && rm -f -- "$MAIL_ROOT/.postmaster/grants/$uuid.env"
        (( saw_review_target )) && rm -f -- "$MAIL_ROOT/.postmaster/review-target/$uuid.env"
        rm -f -- "$body_file"
        return 1
    fi

    local attach_csv=""
    local -a attach_pairs=()
    if (( ${#attach_files[@]} > 0 )); then
        if (( emit )); then
            local pairs_out base f
            pairs_out="$(mail_emit_validate_attach "" "${attach_files[@]}")" || { rm -f -- "$body_file"; return 1; }
            local -a attach_bases=()
            while IFS=$'\t' read -r base f; do
                [[ -n "$base" ]] || continue
                attach_bases+=("$base")
                attach_pairs+=("$base"$'\t'"$f")
            done <<< "$pairs_out"
            attach_csv="$(IFS='/'; printf '%s' "${attach_bases[*]}")"
        else
            attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || {
                (( saw_grant )) && rm -f -- "$MAIL_ROOT/.postmaster/grants/$uuid.env"
                (( saw_review_target )) && rm -f -- "$MAIL_ROOT/.postmaster/review-target/$uuid.env"
                (( saw_services_env )) && rm -f -- "$MAIL_ROOT/.postmaster/services-env/$uuid.env"
                rm -f -- "$body_file"
                return 1
            }
        fi
    fi

    local from_hdr="$from" to_hdr="$to_norm" cc_hdr="$cc_norm"
    if (( emit )); then
        mail_emit_addrs from_hdr to_hdr cc_hdr || { rm -f -- "$body_file"; return 1; }
    fi
    local date_hdr; date_hdr="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
    local -a hlines=()
    hlines+=("Message-ID: $uuid")
    hlines+=("Thread-ID: $uuid")
    hlines+=("Date: $date_hdr")
    hlines+=("From: $from_hdr")
    hlines+=("To: $to_hdr")
    [[ -n "$cc_hdr" ]] && hlines+=("Cc: $cc_hdr")
    hlines+=("Subject: $subject")
    hlines+=("X-Hops: $hops")
    [[ -n "$budget" ]] && hlines+=("X-Thread-Budget: $budget")
    (( no_grant )) && hlines+=("X-Grant: none")
    if (( saw_review_target )); then
        # The setter signal, plus the ordinary per-message target headers
        # (every message about a commit carries X-Review-Target; see
        # docs/agent-mail.md's header contract).
        hlines+=("X-Review-Target-Set: $review_target_branch $review_target_sha")
        hlines+=("X-Review-Target: $review_target_branch $review_target_sha")
        hlines+=("X-Version: 1")
    fi
    for hline in "${validated_headers[@]:-}"; do
        [[ -n "$hline" ]] && hlines+=("$hline")
    done
    if [[ -n "$attach_csv" ]]; then
        local -a names=()
        IFS='/' read -ra names <<< "$attach_csv"
        local n
        for n in "${names[@]}"; do
            hlines+=("X-Attachment: attachments/$n")
        done
    fi
    local headers; headers="$(printf '%s\n' "${hlines[@]}")"

    if (( emit )); then
        if (( ${#attach_pairs[@]} > 0 )); then
            mail_emit_bundle "$headers" "$body_file" "${attach_pairs[@]}" || return 1
        else
            mail_emit_message "$headers" "$body_file"
        fi
        return 0
    fi

    mail_place_message "$headers" "$body_file" "$thread_dir" "$uuid" >/dev/null || {
        (( saw_grant )) && rm -f -- "$MAIL_ROOT/.postmaster/grants/$uuid.env"
        (( saw_review_target )) && rm -f -- "$MAIL_ROOT/.postmaster/review-target/$uuid.env"
        (( saw_services_env )) && rm -f -- "$MAIL_ROOT/.postmaster/services-env/$uuid.env"
        rm -f -- "$body_file"
        return 1
    }
    rm -f -- "$body_file"
    echo "fork-sandbox mail: sent ${uuid} as a new thread" >&2
    printf '%s\n' "$uuid"
}

cmd_reply() {
    local from="" reply_to="" body_arg="" to="" cc="" subject_override="" hops_override=""
    local -a attach_files=() extra_headers=()
    local upstream_head_arg="" upstream_state_arg="" emit=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --emit) emit=1; shift ;;
            --from) from="${2:?--from requires an address}"; shift 2 ;;
            --reply-to) reply_to="${2:?--reply-to requires a message id}"; shift 2 ;;
            --body) body_arg="${2:?--body requires a file, or -}"; shift 2 ;;
            --to) to="${to:+$to,}${2:?--to requires an address list}"; shift 2 ;;
            --cc) cc="${cc:+$cc,}${2:?--cc requires an address list}"; shift 2 ;;
            --subject) subject_override="${2:?--subject requires text}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            --hops) hops_override="${2:?--hops requires a number}"; shift 2 ;;
            --header) extra_headers+=("${2:?--header requires 'X-Name: value'}"); shift 2 ;;
            --upstream-head) upstream_head_arg="${2:?--upstream-head requires <branch>:<sha>}"; shift 2 ;;
            --upstream-state) upstream_state_arg="${2:?--upstream-state requires closed or open}"; shift 2 ;;
            --allow-namespace|--reach-probe|--host-alias|--seat-resources|--context-ro|--context-secret)
                echo "Error: reply: grant flags apply to a new thread only (mail send); for an existing thread use" >&2
                echo "fork-sandbox mail grant <thread-id> ..." >&2
                return 1
                ;;
            --no-grant)
                echo "Error: reply: --no-grant applies to a new thread only (mail send); a thread's environment" >&2
                echo "is chosen when it is opened." >&2
                return 1
                ;;
            --budget)
                echo "Error: reply: --budget applies to a new thread only (mail send); a thread's budget is" >&2
                echo "fixed when it is opened." >&2
                return 1
                ;;
            --review-target)
                echo "Error: reply: --review-target applies to a new thread only (mail send); a reply that moves" >&2
                echo "the target is the 'sets' seat's own Version: header instead." >&2
                return 1
                ;;
            --services-env)
                echo "Error: reply: --services-env applies to a new thread only (mail send); a thread's" >&2
                echo "services environment is chosen when it is opened." >&2
                return 1
                ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: reply: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: reply: --from is required." >&2; return 1; }
    [[ -n "$reply_to" ]] || { echo "Error: reply: --reply-to is required." >&2; return 1; }
    [[ -n "$body_arg" ]] || { echo "Error: reply: --body is required." >&2; return 1; }
    [[ -z "$subject_override" ]] || mail_validate_no_newline "$subject_override" "--subject" || return 1
    [[ -z "$hops_override" ]] || [[ "$hops_override" =~ ^[0-9]+$ ]] || { echo "Error: reply: --hops must be a non-negative integer." >&2; return 1; }
    local -a validated_headers=()
    local eh hline
    for eh in "${extra_headers[@]:-}"; do
        [[ -z "$eh" ]] && continue
        hline="$(mail_validate_header "$eh")" || return 1
        validated_headers+=("$hline")
    done
    local upstream_head_hline=""
    if [[ -n "$upstream_head_arg" ]]; then
        local uh_out
        uh_out="$(mail_validate_upstream_head "$upstream_head_arg")" || return 1
        upstream_head_hline="X-Upstream-Head: ${uh_out%%$'\t'*} ${uh_out#*$'\t'}"
    fi
    local upstream_state_hline=""
    if [[ -n "$upstream_state_arg" ]]; then
        local us_out
        us_out="$(mail_validate_upstream_state "$upstream_state_arg")" || return 1
        upstream_state_hline="X-Upstream-State: $us_out"
    fi

    mail_validate_addr "$from" || return 1
    from="$(mail_norm_addr "$from")"
    local to_norm="" cc_norm=""
    [[ -n "$to" ]] && { to_norm="$(mail_validate_addr_list "$to")" || return 1; }
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }
    if (( emit )); then
        mail_emit_check reply 0 "$upstream_head_arg$upstream_state_arg" || return 1
    fi

    local parent_file
    parent_file="$(mail_find_by_id "$reply_to")" || {
        echo "Error: reply: no message with id '$reply_to'." >&2
        return 1
    }

    local body_file; body_file="$(mktemp "$MAIL_ROOT/.mail.body.XXXXXX")"
    mail_read_body_arg "$body_arg" "$body_file" || { rm -f -- "$body_file"; return 1; }
    if mail_body_is_empty "$body_file"; then
        rm -f -- "$body_file"
        echo "Error: reply: message body is empty." >&2
        return 1
    fi

    local p_thread_id p_from p_to p_cc p_subject p_hops p_references p_id
    p_id="$(mail_header "$parent_file" Message-ID)"
    p_thread_id="$(mail_header "$parent_file" Thread-ID)"
    p_from="$(mail_header "$parent_file" From)"
    p_to="$(mail_header "$parent_file" To)"
    p_cc="$(mail_header "$parent_file" Cc)"
    p_subject="$(mail_header "$parent_file" Subject)"
    p_hops="$(mail_header "$parent_file" X-Hops)"
    p_references="$(mail_header "$parent_file" References)"

    if [[ -z "$to_norm" ]]; then
        # reply-all: dedup(parent's From + To + Cc) minus the sender.
        local -a candidates=() seen_addr=() result=()
        [[ -n "$p_from" ]] && candidates+=("$p_from")
        local rest="$p_to${p_cc:+, $p_cc}"
        if [[ -n "$rest" ]]; then
            local -a parts
            IFS=',' read -ra parts <<< "$rest"
            local a
            for a in "${parts[@]}"; do
                a="$(mail_trim "$a")"
                [[ -n "$a" ]] && candidates+=("$a")
            done
        fi
        local c dup
        for c in "${candidates[@]}"; do
            [[ "$c" == "$from" ]] && continue
            dup=0
            for a in "${seen_addr[@]:-}"; do
                [[ "$a" == "$c" ]] && { dup=1; break; }
            done
            (( dup )) && continue
            seen_addr+=("$c")
            result+=("$c")
        done
        local joined
        joined="$(IFS=','; printf '%s' "${result[*]:-}")"
        to_norm="$(mail_validate_addr_list "$joined")" || { rm -f -- "$body_file"; return 1; }
        [[ -n "$to_norm" ]] || { rm -f -- "$body_file"; echo "Error: reply: reply-all resolved to no recipients; pass --to explicitly." >&2; return 1; }
    fi

    local subject="$subject_override"
    if [[ -z "$subject" ]]; then
        case "$p_subject" in
            "Re: "*) subject="$p_subject" ;;
            *) subject="Re: $p_subject" ;;
        esac
    fi

    local references
    if [[ -n "$p_references" ]]; then
        references="$p_references $p_id"
    else
        references="$p_id"
    fi

    local thread_dir; thread_dir="$(mail_thread_dir "$p_thread_id")"
    local attach_csv=""
    local -a attach_pairs=()
    if (( ${#attach_files[@]} > 0 )); then
        if (( emit )); then
            local pairs_out base f
            pairs_out="$(mail_emit_validate_attach "$thread_dir" "${attach_files[@]}")" || { rm -f -- "$body_file"; return 1; }
            local -a attach_bases=()
            while IFS=$'\t' read -r base f; do
                [[ -n "$base" ]] || continue
                attach_bases+=("$base")
                attach_pairs+=("$base"$'\t'"$f")
            done <<< "$pairs_out"
            attach_csv="$(IFS='/'; printf '%s' "${attach_bases[*]}")"
        else
            attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || { rm -f -- "$body_file"; return 1; }
        fi
    fi

    local uuid; uuid="$(mail_new_uuid)"
    local from_hdr="$from" to_hdr="$to_norm" cc_hdr="$cc_norm"
    if (( emit )); then
        mail_emit_addrs from_hdr to_hdr cc_hdr || { rm -f -- "$body_file"; return 1; }
    fi
    local date_hdr; date_hdr="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
    local -a hlines=()
    hlines+=("Message-ID: $uuid")
    hlines+=("Thread-ID: $p_thread_id")
    hlines+=("Date: $date_hdr")
    hlines+=("From: $from_hdr")
    hlines+=("To: $to_hdr")
    [[ -n "$cc_hdr" ]] && hlines+=("Cc: $cc_hdr")
    hlines+=("Subject: $subject")
    hlines+=("In-Reply-To: $p_id")
    hlines+=("References: $references")
    hlines+=("X-Hops: ${hops_override:-$p_hops}")
    [[ -n "$upstream_head_hline" ]] && hlines+=("$upstream_head_hline")
    [[ -n "$upstream_state_hline" ]] && hlines+=("$upstream_state_hline")
    for hline in "${validated_headers[@]:-}"; do
        [[ -n "$hline" ]] && hlines+=("$hline")
    done
    if [[ -n "$attach_csv" ]]; then
        local -a names=()
        IFS='/' read -ra names <<< "$attach_csv"
        local n
        for n in "${names[@]}"; do
            hlines+=("X-Attachment: attachments/$n")
        done
    fi
    local headers; headers="$(printf '%s\n' "${hlines[@]}")"

    if (( emit )); then
        if (( ${#attach_pairs[@]} > 0 )); then
            mail_emit_bundle "$headers" "$body_file" "${attach_pairs[@]}" || return 1
        else
            mail_emit_message "$headers" "$body_file"
        fi
        return 0
    fi

    mail_place_message "$headers" "$body_file" "$thread_dir" "$uuid" >/dev/null || { rm -f -- "$body_file"; return 1; }
    rm -f -- "$body_file"
    echo "fork-sandbox mail: replied ${uuid} to ${p_id}" >&2
    printf '%s\n' "$uuid"
}

# Single-valued headers: a second copy would make mail_header (first match)
# and anything that reads the whole block disagree, so ingest refuses it.
MAIL_INGEST_SINGLETONS=(Message-ID Thread-ID Date From To Cc Subject In-Reply-To References X-Hops)
MAIL_INGEST_REQUIRED=(Message-ID Thread-ID Date From To Subject X-Hops)

mail_ingest_fail() {
    echo "Error: ingest: $*" >&2
    return 1
}

# Undoes a partial attachment placement from mail_ingest_message: removes
# the basenames named in nameref array $5 from directory $1, removes $1
# itself if $2 says this call created it, and removes thread dir $3 if $4
# says this call created that. Needed because mail_ingest_message runs
# inside callers that test its exit status in an `||` (cmd_ingest's
# `mail_ingest_bundle ... || rc=$?`, mail_ingest_bundle's own hand-off) --
# bash suspends `set -e` for the whole call chain while that test is live,
# so a late failure (another frame's mv, or mail_place_message) does not
# stop the shell on its own, and the "writes nothing visible until
# everything is validated" contract has to be enforced explicitly here.
mail_ingest_rollback_attachments() {
    local attach_dir="$1" attach_dir_created="$2" thread_dir="$3" thread_created="$4"
    local -n placed_ref="$5"
    local base
    for base in "${placed_ref[@]}"; do
        rm -f -- "$attach_dir/$base"
    done
    (( attach_dir_created )) && rmdir -- "$attach_dir" 2>/dev/null
    (( thread_created )) && rmdir -- "$thread_dir" 2>/dev/null
    return 0
}

# Validates the message in $2 (read bounded from stdin by cmd_ingest) and,
# if it is sound, places it in the store keeping its ids and headers. $1 is
# the peer name to stamp it as received from, or empty. $3 is a scratch file
# for the body. $4 and $5 name arrays (possibly empty): the attachment
# basenames a bundle's frames declared, in frame order, and the temp file
# holding each frame's already-size/sha-verified payload, same order. With
# both empty (the plain-message case, including every cross-host delivery
# before bundles existed) X-Attachment stays reserved and refused, exactly
# as before. Prints the message id.
mail_ingest_message() {
    local peer="$1" raw="$2" body_file="$3"
    local -n exp_bases_ref="$4" attach_srcs_ref="$5"
    local -a hdrs=()
    local line n=0 found_blank=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$(( n + 1 ))
        if [[ -z "$line" ]]; then found_blank=1; break; fi
        hdrs+=("$line")
    done < "$raw"
    (( found_blank )) || { mail_ingest_fail "no blank line ends the header block."; return 1; }
    (( ${#hdrs[@]} > 0 )) || { mail_ingest_fail "the message has no headers."; return 1; }
    [[ "$(head -n "$n" "$raw" | tr -d '\0' | wc -c)" == "$(head -n "$n" "$raw" | wc -c)" ]] ||
        { mail_ingest_fail "the header block contains a NUL byte."; return 1; }
    tail -n "+$(( n + 1 ))" "$raw" > "$body_file"
    if mail_body_is_empty "$body_file"; then
        mail_ingest_fail "message body is empty."
        return 1
    fi

    local -A hv=() hcount=()
    local -a seen_attach=()
    local name val k
    for line in "${hdrs[@]}"; do
        if [[ "$line" == *$'\r'* ]]; then
            mail_ingest_fail "a header line contains a carriage return."
            return 1
        fi
        if [[ ! "$line" =~ ^([A-Za-z][A-Za-z0-9-]*):(\ (.*))?$ ]]; then
            mail_ingest_fail "malformed header line '${line:0:60}'."
            return 1
        fi
        name="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[3]}"
        if [[ "${name^^}" == "X-ATTACHMENT" ]]; then
            seen_attach+=("$val")
            continue
        fi
        case "${name^^}" in
            X-UPSTREAM-HEAD|X-UPSTREAM-STATE|X-REVIEW-TARGET|X-REVIEW-TARGET-SET|X-VERSION|X-THREAD-BUDGET|X-GRANT)
                mail_ingest_fail "header '$name' is reserved and does not travel."
                return 1
                ;;
        esac
        for k in "${MAIL_INGEST_SINGLETONS[@]}"; do
            [[ "${name^^}" == "${k^^}" ]] || continue
            if [[ "$name" != "$k" ]]; then
                mail_ingest_fail "header '$name' must be spelled '$k'."
                return 1
            fi
            if (( ${hcount[$k]:-0} > 0 )); then
                mail_ingest_fail "header '$k' appears more than once."
                return 1
            fi
            hcount[$k]=1
            hv[$k]="$val"
        done
    done
    for k in "${MAIL_INGEST_REQUIRED[@]}"; do
        if (( ${hcount[$k]:-0} == 0 )); then
            mail_ingest_fail "header '$k' is missing."
            return 1
        fi
    done

    # X-Attachment either stays fully reserved (a plain message, or ingest
    # called with no bundle) or must match the bundle's attachment frames
    # exactly: same basenames, same order, same count -- the frames are
    # already size- and sha256-verified, but the headers are the sender's
    # own claim about what it attached, and the two must agree.
    if (( ${#exp_bases_ref[@]} == 0 )); then
        if (( ${#seen_attach[@]} > 0 )); then
            mail_ingest_fail "header 'X-Attachment' is reserved and does not travel."
            return 1
        fi
    else
        if (( ${#seen_attach[@]} != ${#exp_bases_ref[@]} )); then
            mail_ingest_fail "message carries ${#seen_attach[@]} X-Attachment header(s) but the bundle has ${#exp_bases_ref[@]} attachment frame(s)."
            return 1
        fi
        local idx want
        for idx in "${!exp_bases_ref[@]}"; do
            want="attachments/${exp_bases_ref[$idx]}"
            if [[ "${seen_attach[$idx]}" != "$want" ]]; then
                mail_ingest_fail "X-Attachment header '${seen_attach[$idx]}' does not match the bundle's attachment frame '$want' (same order required)."
                return 1
            fi
        done
    fi

    local mid="${hv[Message-ID]}" tid="${hv[Thread-ID]}"
    for k in Message-ID Thread-ID In-Reply-To; do
        [[ -z "${hcount[$k]:-}" || "${hv[$k]}" =~ $MAIL_ID_RE ]] ||
            { mail_ingest_fail "$k '${hv[$k]:0:60}' is not a valid id."; return 1; }
    done
    if [[ -n "${hcount[References]:-}" ]]; then
        local ref
        for ref in ${hv[References]}; do
            [[ "$ref" =~ $MAIL_ID_RE ]] || { mail_ingest_fail "References holds an invalid id."; return 1; }
        done
    fi
    [[ "${hv[X-Hops]}" =~ ^[0-9]+$ ]] || { mail_ingest_fail "X-Hops must be a non-negative integer."; return 1; }
    if [[ "$tid" != "$mid" && -z "${hcount[In-Reply-To]:-}" ]]; then
        mail_ingest_fail "a message in another message's thread must carry In-Reply-To."
        return 1
    fi

    # Addresses. With --peer, the message arrived from that peer: its From
    # must name that host (a bare From is that host's lane), and bare To/Cc
    # addresses are in the sender's frame, so they are that host's too.
    local from="${hv[From]}" to="${hv[To]}" cc="${hv[Cc]:-}"
    mail_validate_addr "$from" || return 1
    if [[ -n "$peer" ]]; then
        if [[ "$from" == *:* ]]; then
            if [[ "${from#*:}" != "$peer" ]]; then
                mail_ingest_fail "From host '${from#*:}' does not match the sending peer '$peer'."
                return 1
            fi
        else
            from="$(mail_qualify_addr "$from" "$peer")"
        fi
        to="$(mail_qualify_list "$to" "$peer")"
        [[ -z "$cc" ]] || cc="$(mail_qualify_list "$cc" "$peer")"
    fi
    from="$(mail_norm_addr "$from")"
    to="$(mail_validate_addr_list "$to")" || return 1
    [[ -n "$to" ]] || { mail_ingest_fail "To is empty."; return 1; }
    [[ -z "$cc" ]] || { cc="$(mail_validate_addr_list "$cc")" || return 1; }
    # A delivery from a peer must be for someone here: after normalisation at
    # least one To/Cc address is a bare lane. Otherwise the sender's name for
    # this host differs from ours, or the mail was never meant for us, and
    # storing it would report success for mail no inbox or watcher can see.
    if [[ -n "$peer" && ! ",$to,$cc," =~ ,\ *@[a-z0-9-]+\ *, ]]; then
        mail_ingest_fail "no To/Cc address is a lane on this host (this host's peer name is '$(lane_mail_self_name || echo unknown)'); the sender's peers file must name this host exactly that."
        return 1
    fi

    if mail_find_by_id "$mid" >/dev/null; then
        mail_ingest_fail "message $mid is already in this store."
        return 1
    fi

    local -a out=()
    for line in "${hdrs[@]}"; do
        case "$line" in
            "From:"*) out+=("From: $from") ;;
            "To:"*) out+=("To: $to") ;;
            "Cc:"*) out+=("Cc: $cc") ;;
            *) out+=("$line") ;;
        esac
    done
    local headers; headers="$(printf '%s\n' "${out[@]}")"

    local thread_dir created=0
    thread_dir="$(mail_thread_dir "$tid")"
    [[ -d "$thread_dir" ]] || created=1
    mkdir -p -- "$thread_dir"

    # A bundle's attachments are staged (and, where needed, moved into
    # place) before the message is ever written, so a reader who sees the
    # message already sees its attachments, and a refusal here leaves the
    # thread exactly as it was: no thread dir left behind for a brand-new
    # thread, and no empty attachments dir left behind for an existing
    # thread that had none yet. To get that, attach_dir is created only
    # once every frame has passed validation -- not up front -- and
    # anything moved into it before a later failure (another frame's mv,
    # or mail_place_message) is rolled back explicitly, since this
    # function cannot rely on `set -e` to stop it (see
    # mail_ingest_rollback_attachments).
    local attach_dir="" attach_dir_created=0
    local -a placed=()
    if (( ${#exp_bases_ref[@]} > 0 )); then
        attach_dir="$thread_dir/attachments"
        if [[ -L "$attach_dir" ]]; then
            mail_ingest_fail "attachments is a symlink in this thread; refusing."
            (( created )) && rmdir -- "$thread_dir" 2>/dev/null
            return 1
        elif [[ -e "$attach_dir" && ! -d "$attach_dir" ]]; then
            mail_ingest_fail "attachments is not a directory in this thread; refusing."
            (( created )) && rmdir -- "$thread_dir" 2>/dev/null
            return 1
        fi

        local -A within_src=()
        local i base src dest
        for i in "${!exp_bases_ref[@]}"; do
            base="${exp_bases_ref[$i]}"; src="${attach_srcs_ref[$i]}"
            if [[ -n "${within_src[$base]:-}" ]]; then
                if ! cmp -s -- "$src" "${within_src[$base]}"; then
                    mail_ingest_fail "two attachment frames named '$base' in this bundle have different content."
                    (( created )) && rmdir -- "$thread_dir" 2>/dev/null
                    return 1
                fi
                continue
            fi
            within_src[$base]="$src"
            dest="$attach_dir/$base"
            if [[ -e "$dest" || -L "$dest" ]]; then
                if [[ -L "$dest" || ! -f "$dest" ]]; then
                    mail_ingest_fail "attachments/$base exists and is not a plain file; refusing."
                    (( created )) && rmdir -- "$thread_dir" 2>/dev/null
                    return 1
                fi
                if ! cmp -s -- "$src" "$dest"; then
                    mail_ingest_fail "attachments/$base already holds different content."
                    (( created )) && rmdir -- "$thread_dir" 2>/dev/null
                    return 1
                fi
            fi
        done

        [[ -d "$attach_dir" ]] || attach_dir_created=1
        mkdir -p -- "$attach_dir"

        local -A moved=()
        for i in "${!exp_bases_ref[@]}"; do
            base="${exp_bases_ref[$i]}"; src="${attach_srcs_ref[$i]}"
            [[ -n "${moved[$base]:-}" ]] && continue
            moved[$base]=1
            dest="$attach_dir/$base"
            [[ -e "$dest" ]] && continue
            # -n (no-clobber): if a concurrent delivery placed attachments/
            # $base between the check above and this mv, mv leaves our copy
            # at $src untouched instead of overwriting -- closing the race
            # a plain `mv` would lose (last writer wins, silently).
            if ! mv -n -- "$src" "$dest"; then
                mail_ingest_fail "failed to place attachments/$base."
                mail_ingest_rollback_attachments "$attach_dir" "$attach_dir_created" "$thread_dir" "$created" placed
                return 1
            fi
            if [[ -e "$src" ]]; then
                if ! cmp -s -- "$src" "$dest"; then
                    rm -f -- "$src"
                    mail_ingest_fail "attachments/$base already holds different content."
                    mail_ingest_rollback_attachments "$attach_dir" "$attach_dir_created" "$thread_dir" "$created" placed
                    return 1
                fi
                rm -f -- "$src"
            else
                placed+=("$base")
            fi
        done
    fi

    if ! mail_place_message "$headers" "$body_file" "$thread_dir" "$mid" >/dev/null; then
        mail_ingest_rollback_attachments "$attach_dir" "$attach_dir_created" "$thread_dir" "$created" placed
        return 1
    fi
    printf '%s\n' "$mid"
}

# Reads exactly one byte from stdin and succeeds only if it was a newline
# -- the "exactly one \n before the next frame line" rule a bundle's
# payloads are held to. EOF, or any other byte, is a failure (truncated or
# malformed framing, told apart by the caller's own EOF handling).
mail_ingest_bundle_sep() {
    local sep rc=0
    IFS= read -r -n 1 sep || rc=$?
    [[ "$rc" -eq 0 && -z "$sep" ]]
}

# Parses a LANE-MAIL-BUNDLE 1 stream already fully captured, bounded, in
# file $2 (the marker line itself included) -- see docs/agent-mail.md,
# "Lane mail between hosts", for the exact grammar this enforces strictly:
# the message frame's declared byte count must be met exactly, each
# payload followed by exactly one newline, at most MAIL_ATTACH_MAX_COUNT
# attachment frames, at least one (a zero-attachment bundle is refused --
# send a plain message instead), "end" with nothing after it. $3 is a
# scratch dir, on the store's filesystem, for the message and attachment
# payloads (the caller owns it and cleans it up). On success, hands off to
# mail_ingest_message, which validates the rest and stages the
# attachments atomically.
mail_ingest_bundle() {
    local peer="$1" raw="$2" workdir="$3"
    exec 3< "$raw"
    local line
    if ! IFS= read -r line <&3 || [[ "$line" != "LANE-MAIL-BUNDLE 1" ]]; then
        exec 3<&-
        mail_ingest_fail "malformed bundle header line."
        return 1
    fi
    if ! IFS= read -r line <&3; then
        exec 3<&-
        mail_ingest_fail "truncated bundle: missing message frame."
        return 1
    fi
    if [[ ! "$line" =~ ^message\ ([0-9]+)$ ]]; then
        exec 3<&-
        mail_ingest_fail "malformed message frame line."
        return 1
    fi
    local msg_n="${BASH_REMATCH[1]}"
    if (( msg_n > MAIL_INGEST_MAX_BYTES )); then
        exec 3<&-
        mail_ingest_fail "bundle message frame is over the $MAIL_INGEST_MAX_BYTES byte cap."
        return 1
    fi
    local msg_file="$workdir/message"
    head -c "$msg_n" <&3 > "$msg_file"
    if [[ "$(wc -c < "$msg_file" | tr -d '[:space:]')" != "$msg_n" ]]; then
        exec 3<&-
        mail_ingest_fail "bundle message frame declared $msg_n bytes but the stream had fewer."
        return 1
    fi
    if ! mail_ingest_bundle_sep <&3; then
        exec 3<&-
        mail_ingest_fail "the message frame is not followed by exactly one newline."
        return 1
    fi

    local -a exp_bases=() attach_srcs=()
    local saw_end=0 n_attach=0 base fsize fsha att_file actual_sha
    while IFS= read -r line <&3; do
        if [[ "$line" == "end" ]]; then
            saw_end=1
            break
        fi
        if (( n_attach >= MAIL_ATTACH_MAX_COUNT )); then
            exec 3<&-
            mail_ingest_fail "bundle carries more than $MAIL_ATTACH_MAX_COUNT attachments."
            return 1
        fi
        if [[ ! "$line" =~ ^attachment\ (.+)\ ([0-9]+)\ ([0-9a-f]{64})$ ]]; then
            exec 3<&-
            mail_ingest_fail "malformed attachment frame line."
            return 1
        fi
        base="${BASH_REMATCH[1]}"; fsize="${BASH_REMATCH[2]}"; fsha="${BASH_REMATCH[3]}"
        if ! mail_validate_attach_basename "$base" "attachment frame"; then
            exec 3<&-
            return 1
        fi
        if (( fsize > MAIL_ATTACH_MAX_BYTES )); then
            exec 3<&-
            mail_ingest_fail "attachment '$base' is $fsize bytes, over the $MAIL_ATTACH_MAX_BYTES byte (4 MiB) cap."
            return 1
        fi
        n_attach=$(( n_attach + 1 ))
        att_file="$workdir/att.$n_attach"
        head -c "$fsize" <&3 > "$att_file"
        if [[ "$(wc -c < "$att_file" | tr -d '[:space:]')" != "$fsize" ]]; then
            exec 3<&-
            mail_ingest_fail "attachment '$base' declared $fsize bytes but the stream had fewer."
            return 1
        fi
        actual_sha="$(mail_sha256_file "$att_file")" || { exec 3<&-; return 1; }
        if [[ "$actual_sha" != "$fsha" ]]; then
            exec 3<&-
            mail_ingest_fail "attachment '$base': sha256 mismatch."
            return 1
        fi
        if ! mail_ingest_bundle_sep <&3; then
            exec 3<&-
            mail_ingest_fail "attachment '$base' is not followed by exactly one newline."
            return 1
        fi
        exp_bases+=("$base")
        attach_srcs+=("$att_file")
    done
    if (( ! saw_end )); then
        exec 3<&-
        mail_ingest_fail "truncated bundle: missing 'end'."
        return 1
    fi
    if (( n_attach == 0 )); then
        exec 3<&-
        mail_ingest_fail "a bundle must carry at least one attachment; send a plain message instead."
        return 1
    fi
    local trailing
    # shellcheck disable=SC2034  # only its presence (any byte read) matters
    if IFS= read -r -n 1 trailing <&3; then
        exec 3<&-
        mail_ingest_fail "trailing bytes after 'end'."
        return 1
    fi
    exec 3<&-

    local body_file="$workdir/body"
    mail_ingest_message "$peer" "$msg_file" "$body_file" exp_bases attach_srcs
}

# ingest --peer: the receiving end of a cross-host delivery. Writes one
# complete message or one LANE-MAIL-BUNDLE (as `send --emit` prints either)
# from stdin into this store, keeping its Message-ID, Thread-ID and every
# other header, normalising addresses that name this host to the bare
# form. Without --peer it is a local write (the sender's own copy of a
# message, or bundle, it just delivered).
cmd_ingest() {
    local peer=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --peer) peer="${2:?--peer requires a peer name}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: ingest: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    if [[ -n "$peer" && ! "$peer" =~ $LANE_MAIL_HOST_RE ]]; then
        mail_ingest_fail "--peer '$peer' is not a valid peer name."
        return 1
    fi
    local workdir rc=0 size raw marker=$'LANE-MAIL-BUNDLE 1\n' cap is_bundle=0
    workdir="$(mktemp -d "$MAIL_ROOT/.mail.ingest.XXXXXX")"
    raw="$workdir/raw"
    # Read just the marker's length first, so only a bundle gets the bundle
    # cap and a plain message is still read no further than 1 MiB. GNU head
    # -c reads exactly N bytes from a pipe; the second head continues there.
    head -c "${#marker}" > "$raw" || true
    printf '%s' "$marker" | cmp -s - "$raw" && is_bundle=1
    cap=$MAIL_INGEST_MAX_BYTES
    (( is_bundle )) && cap=$MAIL_BUNDLE_MAX_BYTES
    size="$(wc -c < "$raw" | tr -d '[:space:]')"
    head -c $(( cap + 1 - size )) >> "$raw" || true
    size="$(wc -c < "$raw" | tr -d '[:space:]')"
    if (( is_bundle && size > cap )); then
        mail_ingest_fail "bundle is over the $cap byte cap." || rc=1
    elif (( size > cap )); then
        mail_ingest_fail "message is over the $MAIL_INGEST_MAX_BYTES byte cap." || rc=1
    elif (( is_bundle )); then
        mail_ingest_bundle "$peer" "$raw" "$workdir" || rc=$?
    else
        # shellcheck disable=SC2034  # read via the namerefs in mail_ingest_message
        local -a no_bases=() no_files=()
        mail_ingest_message "$peer" "$raw" "$workdir/body" no_bases no_files || rc=$?
    fi
    rm -rf -- "$workdir"
    return "$rc"
}

cmd_show() {
    local id="${1:?Usage: fork-sandbox-mail.sh show <message-id>}"
    local file
    file="$(mail_find_by_id "$id")" || {
        echo "Error: show: no message with id '$id'." >&2
        return 1
    }
    cat -- "$file"
}

mail_tree_print() {
    local -n ids_ref="$1" parents_ref="$2" froms_ref="$3" subjects_ref="$4" attach_ref="$5" seqs_ref="$6"
    local id="$7" depth="$8" i indent attach_mark
    for i in "${!ids_ref[@]}"; do
        [[ "${ids_ref[$i]}" == "$id" ]] && break
    done
    indent="$(printf '%*s' $(( depth * 2 )) '')"
    attach_mark=""
    [[ "${attach_ref[$i]:-0}" -gt 0 ]] && attach_mark=" 📎"
    printf '%s%s  %-16s %s%s\n' "$indent" "${seqs_ref[$i]}" "${froms_ref[$i]}" "${subjects_ref[$i]}" "$attach_mark"
    local -a child_idx=()
    local j
    for j in "${!parents_ref[@]}"; do
        [[ "${parents_ref[$j]}" == "$id" ]] && child_idx+=("$j")
    done
    for j in "${child_idx[@]}"; do
        mail_tree_print "$1" "$2" "$3" "$4" "$5" "$6" "${ids_ref[$j]}" $(( depth + 1 ))
    done
}

cmd_tree() {
    local thread_id="${1:?Usage: fork-sandbox-mail.sh tree <thread-id>}"
    local thread_dir; thread_dir="$(mail_thread_dir "$thread_id")"
    [[ -d "$thread_dir" ]] || { echo "Error: tree: no thread '$thread_id'." >&2; return 1; }

    local -a files=()
    local f
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$thread_dir" -maxdepth 1 -name '*.msg' | sort)
    if (( ${#files[@]} == 0 )); then
        echo "(no messages)"
        return 0
    fi

    local -a ids=() parents=() froms=() subjects=() attach=() seqs=()
    for f in "${files[@]}"; do
        ids+=("$(mail_header "$f" Message-ID)")
        parents+=("$(mail_header "$f" In-Reply-To)")
        froms+=("$(mail_header "$f" From)")
        subjects+=("$(mail_header "$f" Subject)")
        attach+=("$(mail_count_header "$f" X-Attachment)")
        seqs+=("$(basename -- "$f" | cut -c1-3)")
    done

    local root=""
    local i
    for i in "${!ids[@]}"; do
        if [[ "${ids[$i]}" == "$thread_id" ]]; then
            root="${ids[$i]}"
            break
        fi
    done
    [[ -n "$root" ]] || root="${ids[0]}"
    mail_tree_print ids parents froms subjects attach seqs "$root" 0
}

cmd_export() {
    local tid="" json=0
    while (( $# )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) echo "Error: export: unknown option '$1'." >&2; return 1 ;;
            *)
                [[ -z "$tid" ]] || { echo "Error: export: exactly one thread id is allowed." >&2; return 1; }
                tid="$1"; shift ;;
        esac
    done
    [[ -n "$tid" ]] || { echo "Usage: fork-sandbox-mail.sh export <thread-id> --json" >&2; return 1; }
    (( json )) || { echo "Error: export: --json is required (it is the only export format)." >&2; return 1; }
    mail_validate_thread_id "$tid" export || return 1
    exec python3 "$script_dir/fork-sandbox-mail-render.py" --json "$MAIL_ROOT" --thread "$tid"
}

cmd_list() {
    if (( $# )); then
        exec python3 "$script_dir/fork-sandbox-mail-render.py" --list "$MAIL_ROOT" "$@"
    fi
    local threads_dir; threads_dir="$(mail_threads_dir)"
    [[ -d "$threads_dir" ]] || return 0
    local d thread_id
    for d in "$threads_dir"/*/; do
        [[ -d "$d" ]] || continue
        thread_id="$(basename -- "$d")"
        local -a files=()
        local f
        while IFS= read -r f; do
            files+=("$f")
        done < <(find "$d" -maxdepth 1 -name '*.msg' | sort)
        (( ${#files[@]} > 0 )) || continue
        local root_subject last_date
        root_subject="$(mail_header "${files[0]}" Subject)"
        last_date="$(mail_header "${files[-1]}" Date)"
        printf '%s\t%s\t%s\t%s\n' "$thread_id" "${#files[@]}" "$root_subject" "$last_date"
    done
}

cmd_inbox() {
    local name="${1:?Usage: fork-sandbox-mail.sh inbox <name> [--all]}"
    shift
    local all=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: inbox: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    local addr="@$name"
    mail_validate_inbox_name "$name" inbox || return 1

    local seen_file="$MAIL_ROOT/agents/$name/seen"
    local -a seen_ids=()
    if [[ -f "$seen_file" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && seen_ids+=("$line")
        done < "$seen_file"
    fi

    local threads_dir; threads_dir="$(mail_threads_dir)"
    [[ -d "$threads_dir" ]] || return 0
    local f
    for f in "$threads_dir"/*/*.msg; do
        [[ -e "$f" ]] || continue
        local to cc position=""
        to="$(mail_header "$f" To)"
        cc="$(mail_header "$f" Cc)"
        case ",$to," in
            *", $addr,"* | ",$addr,"*) position="To" ;;
        esac
        if [[ -z "$position" ]]; then
            case ",$cc," in
                *", $addr,"* | ",$addr,"*) position="Cc" ;;
            esac
        fi
        [[ -n "$position" ]] || continue

        local mid
        mid="$(mail_header "$f" Message-ID)"
        if (( ! all )); then
            local s already=0
            for s in "${seen_ids[@]:-}"; do
                [[ "$s" == "$mid" ]] && { already=1; break; }
            done
            (( already )) && continue
        fi

        local tid from subject
        tid="$(mail_header "$f" Thread-ID)"
        from="$(mail_header "$f" From)"
        subject="$(mail_header "$f" Subject)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$mid" "$tid" "$position" "$from" "$subject"
    done
}

cmd_grant() {
    local tid="${1:?Usage: fork-sandbox-mail.sh grant <thread-id> [options]}"
    shift
    local -a allow_ns=() reach_probe=() host_alias=() seat_resources=()
    local context_ro="" context_secret="" clear=0 show=0 json=0 saw_value=0
    while (( $# )); do
        case "$1" in
            --allow-namespace) allow_ns+=("${2:?--allow-namespace requires NS[:PORT]}"); saw_value=1; shift 2 ;;
            --reach-probe) reach_probe+=("${2:?--reach-probe requires HOST:PORT}"); saw_value=1; shift 2 ;;
            --host-alias) host_alias+=("${2:?--host-alias requires IP=HOST[,HOST...]}"); saw_value=1; shift 2 ;;
            --seat-resources) seat_resources+=("${2:?--seat-resources requires SEAT=cpu=QTY[,memory=QTY]}"); saw_value=1; shift 2 ;;
            --context-ro) context_ro="${2:?--context-ro requires a directory}"; saw_value=1; shift 2 ;;
            --context-secret) context_secret="${2:?--context-secret requires a Secret name}"; saw_value=1; shift 2 ;;
            --clear) clear=1; shift ;;
            --show) show=1; shift ;;
            --json) json=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: grant: unknown option '$1'." >&2; return 1 ;;
        esac
    done

    if (( json && ! show )); then
        echo "Error: grant: --json is only valid together with --show." >&2
        return 1
    fi
    if (( clear && (show || saw_value) )); then
        echo "Error: grant: --clear may not be combined with --show or a grant value." >&2
        return 1
    fi
    if (( show && saw_value )); then
        echo "Error: grant: --show may not be combined with a grant value." >&2
        return 1
    fi
    if (( ! clear && ! show && ! saw_value )); then
        echo "Error: grant: give --allow-namespace/--reach-probe/--host-alias/--seat-resources/--context-ro/" >&2
        echo "--context-secret, --clear or --show." >&2
        return 1
    fi

    mail_validate_thread_id "$tid" || return 1
    mail_thread_root_exists "$tid" || { echo "Error: grant: no such thread '$tid'." >&2; return 1; }

    local grant_file="$MAIL_ROOT/.postmaster/grants/$tid.env"

    if (( ! show && ! clear )) \
            && [[ "$(mail_header "$(mail_find_by_id "$tid")" X-Grant)" == "none" ]]; then
        echo "Error: grant: thread $tid was opened with --no-grant and takes no grant." >&2
        return 2
    fi

    if (( show )); then
        if (( json )); then
            mail_grant_print_json "$tid" "$grant_file"
        elif [[ -f "$grant_file" ]]; then
            cat -- "$grant_file"
        fi
        return 0
    fi

    if (( clear )); then
        rm -f -- "$grant_file"
        return 0
    fi

    local -a args=()
    local v
    for v in "${allow_ns[@]}"; do args+=(--allow-namespace "$v"); done
    for v in "${reach_probe[@]}"; do args+=(--reach-probe "$v"); done
    for v in "${host_alias[@]}"; do args+=(--host-alias "$v"); done
    for v in "${seat_resources[@]}"; do args+=(--seat-resources "$v"); done
    [[ -n "$context_ro" ]] && args+=(--context-ro "$context_ro")
    [[ -n "$context_secret" ]] && args+=(--context-secret "$context_secret")

    mail_write_grant "$tid" "${args[@]}"
}

cmd_seen() {
    local name="${1:?Usage: fork-sandbox-mail.sh seen <name> <message-id>...}"
    shift
    (( $# > 0 )) || { echo "Error: seen: at least one message id is required." >&2; return 1; }
    mail_validate_inbox_name "$name" seen || return 1

    local dir="$MAIL_ROOT/agents/$name"
    mkdir -p -- "$dir"
    local seen_file="$dir/seen"
    touch -- "$seen_file"

    local -a existing=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && existing+=("$line")
    done < "$seen_file"

    local id already e
    for id in "$@"; do
        already=0
        for e in "${existing[@]:-}"; do
            [[ "$e" == "$id" ]] && { already=1; break; }
        done
        if (( ! already )); then
            printf '%s\n' "$id" >> "$seen_file"
            existing+=("$id")
        fi
    done
}

# --remote runs the verb against the mail API server instead of this host's
# store (see fork-sandbox-mail-remote.py). It is checked before the local
# store dir is made: a remote client has no store of its own.
if [[ "${1-}" == "--remote" ]]; then
    shift
    exec "$script_dir/fork-sandbox-mail-remote.py" mail "$@"
fi

mkdir -p -- "$MAIL_ROOT"

case "${1-}" in
    -h|--help) usage; exit 0 ;;
    send) shift; cmd_send "$@" ;;
    reply) shift; cmd_reply "$@" ;;
    ingest) shift; cmd_ingest "$@" ;;
    show) shift; cmd_show "$@" ;;
    tree) shift; cmd_tree "$@" ;;
    export) shift; cmd_export "$@" ;;
    list) shift; cmd_list "$@" ;;
    inbox) shift; cmd_inbox "$@" ;;
    seen) shift; cmd_seen "$@" ;;
    grant) shift; cmd_grant "$@" ;;
    "")
        usage >&2
        exit 1
        ;;
    *)
        echo "Error: unknown verb '$1'." >&2
        usage >&2
        exit 1
        ;;
esac
