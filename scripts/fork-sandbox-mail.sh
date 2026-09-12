#!/usr/bin/env bash
# fork-sandbox-mail.sh — A shared maildir-style message store for a fleet of
# asynchronous agents
#
# Usage: fork-sandbox-mail.sh send --from @a --to @b[,@c] [--cc @d[,@e]]
#                              --subject <s> (--body <file>|-)
#                              [--attach <file>]... [--hops <n>]
#        fork-sandbox-mail.sh reply --from @a --reply-to <message-id>
#                              (--body <file>|-) [--to @b[,@c]] [--cc @d[,@e]]
#                              [--subject <s>] [--attach <file>]... [--hops <n>]
#        fork-sandbox-mail.sh show <message-id>
#        fork-sandbox-mail.sh tree <thread-id>
#        fork-sandbox-mail.sh list
#        fork-sandbox-mail.sh inbox <name> [--all]
#        fork-sandbox-mail.sh seen <name> <message-id>...
#
# This is a store, not a router: `send`/`reply` write messages, `show`/
# `tree`/`list`/`inbox`/`seen` read them back. There is no agent spawning, no
# fleet registry, and no delivery beyond what `inbox` computes by scanning
# headers. Later rounds build a router and a registry on top of this.
#
# Layout, under $FORK_SANDBOX_MAIL_ROOT (default
# /var/tmp/claude-scratch/agent-mail):
#
#   <root>/threads/<thread-id>/<NNN>-<uuid>.msg   # NNN = 3-digit arrival seq
#   <root>/threads/<thread-id>/attachments/<basename>
#   <root>/agents/<name>/seen                     # append-only message-id list
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
#   X-Attachment: attachments/<basename>   one line per attachment
#
# Unlike the RFC-2822-style angle-bracket/domain ids this repo's old
# lkml-mailbox.sh used, ids here are bare uuids with no "<...>" wrapping and
# no "@domain" suffix -- Message-ID and Thread-ID are literal uuid values.
#
# Addressing. Every @name (in --from/--to/--cc, and in an inbox lookup) must
# match ^@[a-z0-9][a-z0-9-]*$ -- lowercase alnum, hyphens allowed, no leading
# hyphen. Anything else is refused with a one-line error. There is no
# registry: this script does not know or care whether a name refers to a
# live agent.
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
# attachment).

set -euo pipefail

MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"
MAIL_ATTACH_MAX_BYTES=$(( 4 * 1024 * 1024 ))
MAIL_ADDR_RE='^@[a-z0-9][a-z0-9-]*$'
MAIL_SEQ_MAX_TRIES=10000

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
        echo "'@name', lowercase alphanumeric and '-' only, no leading '-'." >&2
        return 1
    fi
    return 0
}

# Rejects a value containing a raw newline. Header values are joined into
# the header block with newlines and everything up to the first blank
# line is parsed as a header, so a newline inside a value (e.g. a
# caller-supplied --subject) would forge or truncate header lines.
mail_validate_no_newline() {
    local val="$1" field="$2"
    if [[ "$val" == *$'\n'* ]]; then
        echo "Error: $field must not contain a newline." >&2
        return 1
    fi
    return 0
}

# Strips leading/trailing whitespace and prints the result.
mail_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
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

# Validates and copies each --attach file into <thread-dir>/attachments/,
# printing a '/'-separated list of basenames on stdout -- '/' rather than
# ',' since a basename may legally contain a comma but, by construction of
# `basename`, never a '/'.
mail_stage_attachments() {
    local thread_dir="$1"; shift
    local dir="$thread_dir/attachments"
    local -a names=()
    local f base size

    # Validate every attachment's basename before staging any of them. The
    # basenames come back '/'-joined (see above) and the callers split them
    # with `read -ra`, which stops at the first newline -- a newline in a
    # basename would silently truncate the list, dropping a later
    # attachment's X-Attachment header. Checking all of them up front means
    # a refusal here stages zero files and writes no message.
    for f in "$@"; do
        base="$(basename -- "$f")"
        if [[ "$base" == *$'\n'* ]]; then
            echo "Error: --attach file '$f' has a newline in its basename;" >&2
            echo "refusing." >&2
            return 1
        fi
    done

    for f in "$@"; do
        [[ -f "$f" ]] || { echo "Error: --attach file '$f' not found." >&2; return 1; }
        size="$(wc -c < "$f" | tr -d '[:space:]')"
        if (( size > MAIL_ATTACH_MAX_BYTES )); then
            echo "Error: --attach file '$f' is $size bytes, over the" >&2
            echo "$MAIL_ATTACH_MAX_BYTES byte (4 MiB) cap." >&2
            return 1
        fi
        mkdir -p -- "$dir"
        base="$(basename -- "$f")"
        if [[ -e "$dir/$base" ]] && ! cmp -s -- "$f" "$dir/$base"; then
            echo "Error: --attach '$f' would overwrite attachments/$base," >&2
            echo "which already holds different content staged by an earlier" >&2
            echo "message in this thread. Rename the file and retry." >&2
            return 1
        fi
        cp -f -- "$f" "$dir/$base"
        names+=("$base")
    done
    (IFS='/'; printf '%s' "${names[*]:-}")
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

cmd_send() {
    local from="" to="" cc="" subject="" body_arg="" hops=8
    local -a attach_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:?--from requires an address}"; shift 2 ;;
            --to) to="${2:?--to requires an address list}"; shift 2 ;;
            --cc) cc="${2:?--cc requires an address list}"; shift 2 ;;
            --subject) subject="${2:?--subject requires text}"; shift 2 ;;
            --body) body_arg="${2:?--body requires a file, or -}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            --hops) hops="${2:?--hops requires a number}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: send: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: send: --from is required." >&2; return 1; }
    [[ -n "$to" ]] || { echo "Error: send: --to is required." >&2; return 1; }
    [[ -n "$subject" ]] || { echo "Error: send: --subject is required." >&2; return 1; }
    [[ -n "$body_arg" ]] || { echo "Error: send: --body is required." >&2; return 1; }
    [[ "$hops" =~ ^[0-9]+$ ]] || { echo "Error: send: --hops must be a non-negative integer." >&2; return 1; }
    mail_validate_no_newline "$subject" "--subject" || return 1

    mail_validate_addr "$from" || return 1
    local to_norm cc_norm
    to_norm="$(mail_validate_addr_list "$to")" || return 1
    cc_norm=""
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }

    local body_file; body_file="$(mktemp "$MAIL_ROOT/.mail.body.XXXXXX")"
    mail_read_body_arg "$body_arg" "$body_file" || { rm -f -- "$body_file"; return 1; }
    if mail_body_is_empty "$body_file"; then
        rm -f -- "$body_file"
        echo "Error: send: message body is empty." >&2
        return 1
    fi

    local uuid; uuid="$(mail_new_uuid)"
    local thread_dir; thread_dir="$(mail_thread_dir "$uuid")"
    mkdir -p -- "$thread_dir"

    local attach_csv=""
    if (( ${#attach_files[@]} > 0 )); then
        attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || { rm -f -- "$body_file"; return 1; }
    fi

    local date_hdr; date_hdr="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
    local -a hlines=()
    hlines+=("Message-ID: $uuid")
    hlines+=("Thread-ID: $uuid")
    hlines+=("Date: $date_hdr")
    hlines+=("From: $from")
    hlines+=("To: $to_norm")
    [[ -n "$cc_norm" ]] && hlines+=("Cc: $cc_norm")
    hlines+=("Subject: $subject")
    hlines+=("X-Hops: $hops")
    if [[ -n "$attach_csv" ]]; then
        local -a names=()
        IFS='/' read -ra names <<< "$attach_csv"
        local n
        for n in "${names[@]}"; do
            hlines+=("X-Attachment: attachments/$n")
        done
    fi
    local headers; headers="$(printf '%s\n' "${hlines[@]}")"

    mail_place_message "$headers" "$body_file" "$thread_dir" "$uuid" >/dev/null || { rm -f -- "$body_file"; return 1; }
    rm -f -- "$body_file"
    echo "fork-sandbox mail: sent ${uuid} as a new thread" >&2
    printf '%s\n' "$uuid"
}

cmd_reply() {
    local from="" reply_to="" body_arg="" to="" cc="" subject_override="" hops_override=""
    local -a attach_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:?--from requires an address}"; shift 2 ;;
            --reply-to) reply_to="${2:?--reply-to requires a message id}"; shift 2 ;;
            --body) body_arg="${2:?--body requires a file, or -}"; shift 2 ;;
            --to) to="${2:?--to requires an address list}"; shift 2 ;;
            --cc) cc="${2:?--cc requires an address list}"; shift 2 ;;
            --subject) subject_override="${2:?--subject requires text}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            --hops) hops_override="${2:?--hops requires a number}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: reply: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: reply: --from is required." >&2; return 1; }
    [[ -n "$reply_to" ]] || { echo "Error: reply: --reply-to is required." >&2; return 1; }
    [[ -n "$body_arg" ]] || { echo "Error: reply: --body is required." >&2; return 1; }
    [[ -z "$subject_override" ]] || mail_validate_no_newline "$subject_override" "--subject" || return 1
    [[ -z "$hops_override" ]] || [[ "$hops_override" =~ ^[0-9]+$ ]] || { echo "Error: reply: --hops must be a non-negative integer." >&2; return 1; }

    mail_validate_addr "$from" || return 1
    local to_norm="" cc_norm=""
    [[ -n "$to" ]] && { to_norm="$(mail_validate_addr_list "$to")" || return 1; }
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }

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
    if (( ${#attach_files[@]} > 0 )); then
        attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || { rm -f -- "$body_file"; return 1; }
    fi

    local uuid; uuid="$(mail_new_uuid)"
    local date_hdr; date_hdr="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
    local -a hlines=()
    hlines+=("Message-ID: $uuid")
    hlines+=("Thread-ID: $p_thread_id")
    hlines+=("Date: $date_hdr")
    hlines+=("From: $from")
    hlines+=("To: $to_norm")
    [[ -n "$cc_norm" ]] && hlines+=("Cc: $cc_norm")
    hlines+=("Subject: $subject")
    hlines+=("In-Reply-To: $p_id")
    hlines+=("References: $references")
    hlines+=("X-Hops: ${hops_override:-$p_hops}")
    if [[ -n "$attach_csv" ]]; then
        local -a names=()
        IFS='/' read -ra names <<< "$attach_csv"
        local n
        for n in "${names[@]}"; do
            hlines+=("X-Attachment: attachments/$n")
        done
    fi
    local headers; headers="$(printf '%s\n' "${hlines[@]}")"

    mail_place_message "$headers" "$body_file" "$thread_dir" "$uuid" >/dev/null || { rm -f -- "$body_file"; return 1; }
    rm -f -- "$body_file"
    echo "fork-sandbox mail: replied ${uuid} to ${p_id}" >&2
    printf '%s\n' "$uuid"
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

cmd_list() {
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
    mail_validate_addr "$addr" || return 1

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

cmd_seen() {
    local name="${1:?Usage: fork-sandbox-mail.sh seen <name> <message-id>...}"
    shift
    (( $# > 0 )) || { echo "Error: seen: at least one message id is required." >&2; return 1; }
    local addr="@$name"
    mail_validate_addr "$addr" || return 1

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

mkdir -p -- "$MAIL_ROOT"

case "${1-}" in
    -h|--help) usage; exit 0 ;;
    send) shift; cmd_send "$@" ;;
    reply) shift; cmd_reply "$@" ;;
    show) shift; cmd_show "$@" ;;
    tree) shift; cmd_tree "$@" ;;
    list) shift; cmd_list "$@" ;;
    inbox) shift; cmd_inbox "$@" ;;
    seen) shift; cmd_seen "$@" ;;
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
