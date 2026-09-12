#!/usr/bin/env bash
# fork-sandbox-mail.sh — A shared maildir-style message store for a fleet of
# asynchronous agents
#
# Usage: fork-sandbox-mail.sh send --from @a --to @b[,@c] [--cc @d[,@e]]
#                              --subject <s> (--body <file>|-)
#                              [--attach <file>]... [--hops <n>]
#        fork-sandbox-mail.sh reply --from @a --reply-to <message-id>
#                              (--body <file>|-) [--to @b[,@c]] [--cc @d[,@e]]
#                              [--subject <s>] [--attach <file>]...
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
#   To: @<name>[, @<name>...]
#   Cc: @<name>[, @<name>...]     omitted entirely when there is no Cc
#   Subject: <text>               replies default to "Re: <parent subject>"
#   In-Reply-To: <parent uuid>    replies only
#   References: <uuid> <uuid>...  replies only: parent's References, then
#                                 the parent's own id, root-to-parent order
#   X-Hops: <int>                 default 8 on a new thread; a reply COPIES
#                                 the parent's value verbatim -- decrementing
#                                 it is the ROUTER's job (round 3), not the
#                                 store's
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
# once race for the same NNN. This is resolved with a hardlink-based retry
# loop, not a plain rename: the message is first written in full to a temp
# file, then `ln` (not `mv`) is used to place it at
# "<NNN>-<uuid>.msg" -- `ln` fails atomically with EEXIST if that name is
# already taken, with no window where a check-then-write race could let two
# posters both believe they own the same NNN. On EEXIST the NNN is
# incremented and the link retried; the temp file is only removed once a
# link attempt succeeds. Since the filename also embeds a fresh uuid, two
# posters can never collide on the final path even if they briefly guess the
# same NNN -- the loop exists to keep NNNs themselves gap-free and
# ordered, not to prevent data loss.
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

# Validates a comma-separated list of addresses and prints it back
# normalized as ", "-joined, or nothing for an empty list.
mail_validate_addr_list() {
    local list="$1"
    [[ -n "$list" ]] || return 0
    local -a parts
    IFS=',' read -ra parts <<< "$list"
    local p out=""
    for p in "${parts[@]}"; do
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

# Everything after the first blank line.
mail_body() {
    awk 'f{print} /^$/{f=1}' "$1"
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

# Prints every value of a repeating header, one per line.
mail_header_all() {
    local file="$1" name="$2" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        [[ "$line" == "$name:"* ]] && printf '%s\n' "${line#"$name": }"
    done < "$file"
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

# Writes the message body ($1 = headers already newline-joined and ending in
# a trailing blank line, $2 = body text) to a fresh temp file, then links it
# into place under $3 (thread dir) with the NNN-retry loop documented in the
# header comment above. Prints the final NNN-uuid basename on success.
mail_place_message() {
    local headers="$1" body="$2" thread_dir="$3" uuid="$4"
    local tmp
    tmp="$(mktemp "$MAIL_ROOT/.mail.XXXXXX")"
    {
        printf '%s\n' "$headers"
        printf '\n'
        printf '%s\n' "$body"
    } > "$tmp"
    local n
    n=$(find "$thread_dir" -maxdepth 1 -name '*.msg' | wc -l)
    n=$(( n + 1 ))
    local dest
    while :; do
        dest="$thread_dir/$(printf '%03d' "$n")-$uuid.msg"
        if ln -- "$tmp" "$dest" 2>/dev/null; then
            rm -f -- "$tmp"
            printf '%s' "$(basename -- "$dest")"
            return 0
        fi
        n=$(( n + 1 ))
    done
}

mail_read_body_arg() {
    local body_arg="$1"
    if [[ "$body_arg" == "-" ]]; then
        cat
    else
        [[ -f "$body_arg" ]] || { echo "Error: body file '$body_arg' not found." >&2; return 1; }
        cat -- "$body_arg"
    fi
}

# A regex find-one-non-space, not a whole-string glob substitution: the
# latter walks the body per multibyte character under a UTF-8 locale, which
# makes posting a long quoted reply quadratically slow (measured elsewhere
# in this repo's history: 7.5s@64KB, 33s@128KB, 139s@256KB).
mail_body_is_empty() {
    [[ ! "$1" =~ [^[:space:]] ]]
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

    mail_validate_addr "$from" || return 1
    local to_norm cc_norm
    to_norm="$(mail_validate_addr_list "$to")" || return 1
    cc_norm=""
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }

    local body
    body="$(mail_read_body_arg "$body_arg")" || return 1
    mail_body_is_empty "$body" && { echo "Error: send: message body is empty." >&2; return 1; }

    local uuid; uuid="$(mail_new_uuid)"
    local thread_dir; thread_dir="$(mail_thread_dir "$uuid")"
    mkdir -p -- "$thread_dir"

    local attach_csv=""
    if (( ${#attach_files[@]} > 0 )); then
        attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || return 1
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

    mail_place_message "$headers" "$body" "$thread_dir" "$uuid" >/dev/null
    echo "fork-sandbox mail: sent ${uuid} as a new thread" >&2
    printf '%s\n' "$uuid"
}

cmd_reply() {
    local from="" reply_to="" body_arg="" to="" cc="" subject_override=""
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
            -h|--help) usage; exit 0 ;;
            *) echo "Error: reply: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: reply: --from is required." >&2; return 1; }
    [[ -n "$reply_to" ]] || { echo "Error: reply: --reply-to is required." >&2; return 1; }
    [[ -n "$body_arg" ]] || { echo "Error: reply: --body is required." >&2; return 1; }

    mail_validate_addr "$from" || return 1
    local to_norm="" cc_norm=""
    [[ -n "$to" ]] && { to_norm="$(mail_validate_addr_list "$to")" || return 1; }
    [[ -n "$cc" ]] && { cc_norm="$(mail_validate_addr_list "$cc")" || return 1; }

    local parent_file
    parent_file="$(mail_find_by_id "$reply_to")" || {
        echo "Error: reply: no message with id '$reply_to'." >&2
        return 1
    }

    local body
    body="$(mail_read_body_arg "$body_arg")" || return 1
    mail_body_is_empty "$body" && { echo "Error: reply: message body is empty." >&2; return 1; }

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
                a="${a#"${a%%[![:space:]]*}"}"
                a="${a%"${a##*[![:space:]]}"}"
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
        to_norm="$(mail_validate_addr_list "$joined")" || return 1
        [[ -n "$to_norm" ]] || { echo "Error: reply: reply-all resolved to no recipients; pass --to explicitly." >&2; return 1; }
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
        attach_csv="$(mail_stage_attachments "$thread_dir" "${attach_files[@]}")" || return 1
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
    hlines+=("X-Hops: $p_hops")
    if [[ -n "$attach_csv" ]]; then
        local -a names=()
        IFS='/' read -ra names <<< "$attach_csv"
        local n
        for n in "${names[@]}"; do
            hlines+=("X-Attachment: attachments/$n")
        done
    fi
    local headers; headers="$(printf '%s\n' "${hlines[@]}")"

    mail_place_message "$headers" "$body" "$thread_dir" "$uuid" >/dev/null
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
    local -n ids_ref="$1" parents_ref="$2" froms_ref="$3" subjects_ref="$4" attach_ref="$5"
    local id="$6" depth="$7" i indent attach_mark
    for i in "${!ids_ref[@]}"; do
        [[ "${ids_ref[$i]}" == "$id" ]] && break
    done
    indent="$(printf '%*s' $(( depth * 2 )) '')"
    attach_mark=""
    [[ "${attach_ref[$i]:-0}" -gt 0 ]] && attach_mark=" 📎"
    printf '%s%03d  %-16s %s%s\n' "$indent" $(( i + 1 )) "${froms_ref[$i]}" "${subjects_ref[$i]}" "$attach_mark"
    local -a child_idx=()
    local j
    for j in "${!parents_ref[@]}"; do
        [[ "${parents_ref[$j]}" == "$id" ]] && child_idx+=("$j")
    done
    for j in "${child_idx[@]}"; do
        mail_tree_print "$1" "$2" "$3" "$4" "$5" "${ids_ref[$j]}" $(( depth + 1 ))
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

    local -a ids=() parents=() froms=() subjects=() attach=()
    for f in "${files[@]}"; do
        ids+=("$(mail_header "$f" Message-ID)")
        parents+=("$(mail_header "$f" In-Reply-To)")
        froms+=("$(mail_header "$f" From)")
        subjects+=("$(mail_header "$f" Subject)")
        attach+=("$(mail_count_header "$f" X-Attachment)")
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
    mail_tree_print ids parents froms subjects attach "$root" 0
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
