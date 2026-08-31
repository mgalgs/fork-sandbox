#!/usr/bin/env bash
# lkml-mailbox.sh — A Maildir-like message store for one lkml-mode series
#
# Usage: lkml-mailbox.sh init <series> --cover <file> --patches <dir> --from <persona> [--display <name>] [--version <n>] [--harness <h>] [--model <m>] [--attach <file>]... [--diffstat <range>] [--smoke <file>]
#        lkml-mailbox.sh post <series> --from <persona> --reply-to <id> --file <file|-> [--display <name>] [--subject <s>] [--tags <t1,t2>] [--harness <h>] [--model <m>] [--attach <file>]...
#        lkml-mailbox.sh tree <series>
#        lkml-mailbox.sh cover <series>
#        lkml-mailbox.sh show <series> <id>
#        lkml-mailbox.sh open <series> [--version <n>]
#        lkml-mailbox.sh tally <series> --version <n>
#
# --diffstat <range> and --smoke <file>, on `init` only, each append a
# section to the cover letter body AFTER whatever --cover already contains:
# `--diffstat` appends "## Diffstat" with the output of `git diff --stat
# <range>`, run with NO `-C` flag -- it uses THIS PROCESS'S current working
# directory, since this script takes no --project flag. A caller that wants
# the diffstat computed against a project other than its own cwd must `cd`
# into that project before invoking `init`, e.g. `(cd "$project" && "$mailbox"
# init ... --diffstat "$base..$branch")` -- which also means every OTHER path
# argument to that same `init` call (--cover, --patches, --smoke, --attach)
# must already be absolute. `--smoke <file>` appends "## Test results" with
# that file's contents verbatim. Refuses cleanly if the range fails to diff
# (e.g. cwd is not a git repo, or the range is nonsense) or the smoke file
# does not exist.
#
# Attachments. --attach <file> may repeat on `init` (attaches to the cover
# letter) or `post` (attaches to that one reply). Each file is copied into
# <series>/attachments/<basename> and the message gets one
# "X-Attachment: attachments/<basename>" header per file, alongside the
# other X-* headers -- so `show`, which just cats the whole message file,
# prints them as part of the header block it always printed, no special
# rendering needed. `tree` marks any message carrying at least one
# attachment with a trailing "📎" so a reader can tell at a glance that
# there is something outside the text to go look at (e.g. a screenshot a
# reviewer persona should look at, per the lkml-mode skill). Refused outright
# over 4 MiB -- this is a message store, not a file server. A basename that
# already exists under attachments/ with DIFFERENT content is refused too --
# the namespace is flat and keyed only on basename, so silently overwriting
# it would leave an earlier message's X-Attachment header pointing at the
# wrong file.
#
# One series lives under $LKML_MAILBOX_ROOT/<series>/cur/ (default
# /var/tmp/claude-scratch/lkml/<series>/cur), one file per message, named
# <uuid>.msg, written atomically (temp file + rename) so a concurrent reader
# never sees a half-written message and two concurrent posters never clobber
# each other -- each mints its own uuid.
#
# A message is RFC-822-shaped:
#
#   Message-ID: <uuid@lkml.local>
#   In-Reply-To: <parent-uuid@lkml.local>     (absent on a top-level post)
#   References: <id1@lkml.local> <id2@lkml.local> ...
#   Date: RFC-2822
#   From: <Display Name> (AI persona) <persona.ai@lkml.local>
#   Subject: ...
#   X-AI-Persona: <persona>
#   X-AI-Harness: <harness>
#   X-AI-Model: <model>
#   X-Series: <series>
#   X-Version: <n>
#   X-Depth: <n>
#   X-Tags: <comma-separated subset of Reviewed-by, Acked-by, NAK,
#            Changes-requested, Question -- empty when none apply>
#   X-Seq: <nanosecond epoch, for ordering only>
#
# X-Seq is not part of the human-facing schema above and its format is not a
# contract -- it exists solely because Date is RFC-2822 (one-second
# resolution), and a fast automated round can easily post several messages
# inside the same second, which would otherwise make "latest tag" and
# thread ordering depend on filesystem glob order rather than the order
# they actually happened in.
#
#   <body>
#
# lkml_post_raw() is the ONLY place a message file is ever written, and it
# unconditionally bakes "(AI persona)" into the From header. That is the
# whole enforcement of this project's non-negotiable AI-attribution rule --
# it lives here, in the one function that writes the data, not in any
# persona's good behavior.
#
# id7: every command that prints or renders a message id truncates it to 7
# characters for display, exactly like a short git sha. `post --reply-to`,
# `show <id>` and any id argument accept the full id or any unambiguous
# prefix of it.
#
# Depth. A top-level post (the cover letter `init` writes) is depth 0. Each
# of `init`'s patches is a direct child of the cover, depth 1. `post
# --reply-to` always inherits the version of the message it replies to, and
# sets its own depth to the parent's depth + 1 -- refusing outright, with a
# clear message, when that would exceed depth 30. There is no cap on the
# NUMBER of replies in a thread, only on how deep one chain of them may go.
#
# Version. `init` posts a new top-level thread. Its version defaults to one
# past the highest version already in the series (so `init` with no
# --version IS how v2, v3, ... get posted), or an explicit --version that
# must not already exist. `post` never creates a version; it always inherits
# the version of the thread it replies to.
#
# Design decision -- "open": a thread is open when its tip carries Question,
# Changes-requested or NAK, and no direct reply to it comes from a DIFFERENT
# persona than the one who tagged it. This mailbox has no way to know who a
# tagged message was addressed to -- that lives in prose -- so it uses the
# closest computable proxy: silence from anyone else. Deciding who should
# actually answer an open thread is the orchestrator's job, not this
# script's; `open` only points at candidates. With no --version, `open`
# scans the whole series, including earlier versions -- pass --version to
# scope it to one version, which is what "open is empty" as a convergence
# check (see SKILL.md) needs: an unanswered item from a superseded version
# should not keep the current version from converging.
#
# Design decision -- "tally": counts the LATEST tag per persona per patch
# (by Date), not every tag ever applied, since a Changes-requested is
# routinely superseded by a later Reviewed-by from the same reviewer once
# the request is met, and counting both would make convergence look stuck
# forever.
#
# This is deliberately not a daemon and takes no lock beyond the atomic
# rename: two posts landing in the same second get two different uuids and
# two different files, so there is nothing to serialize.

set -euo pipefail

LKML_ROOT="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"
LKML_ATTACH_MAX_BYTES=$(( 4 * 1024 * 1024 ))

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

lkml_series_dir() {
    printf '%s/%s' "$LKML_ROOT" "$1"
}

lkml_validate_series_name() {
    if [[ ! "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: series name must start with a lowercase letter or digit" >&2
        echo "and contain only lowercase letters, digits, '-' and '_' -- got '$1'." >&2
        return 1
    fi
    return 0
}

# Prints one header's value from a message file, or nothing if it is absent.
# Reads only up to the first blank line, which is where headers end.
lkml_header() {
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
lkml_body() {
    awk 'f{print} /^$/{f=1}' "$1"
}

# Strips "<", ">" and "@lkml.local" from a Message-ID/In-Reply-To value,
# leaving the bare uuid this script uses as an id everywhere else.
lkml_strip_id() {
    local v="$1"
    v="${v#<}"
    v="${v%>}"
    v="${v%%@*}"
    printf '%s' "$v"
}

lkml_new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

# A nanosecond-ish epoch for X-Seq (ordering only, not a contract -- see the
# header comment above). `date +%s%N` is GNU-only: BSD/macOS date leaves the
# literal "N" in place, which is why the result is checked rather than
# trusted outright. Falls back to python3 (already this script's fallback
# for uuidgen above), and finally to whole seconds -- which only degrades
# same-second ordering to filesystem glob order, the pre-X-Seq behavior.
lkml_now_seq() {
    local v; v="$(date +%s%N 2>/dev/null)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1e9))'
    else
        date +%s
    fi
}

lkml_default_display() {
    local p="${1//-/ }"
    printf '%s' "${p^}"
}

lkml_validate_tags() {
    local tags="$1" t
    [[ -z "$tags" ]] && return 0
    local -a parts
    IFS=',' read -ra parts <<< "$tags"
    for t in "${parts[@]}"; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        case "$t" in
            Reviewed-by|Acked-by|NAK|Changes-requested|Question) ;;
            *)
                echo "Error: unknown tag '$t'. Valid tags: Reviewed-by, Acked-by," >&2
                echo "NAK, Changes-requested, Question." >&2
                return 1
                ;;
        esac
    done
    return 0
}

# The only place a message is ever written. $3 is the parent's bare id (or
# "" for a top-level post); $4 is the FULL References value already
# computed by the caller (or "" for a top-level post / a direct child of a
# top-level post, whose References is just the parent's own Message-ID).
# $14 is an optional '/'-separated list of attachment basenames (see
# lkml_stage_attachments -- '/' rather than ',' since a basename may
# contain a comma but never a '/'), already copied into
# <series>/attachments/ by the caller -- this function only writes the
# X-Attachment header per name, it does not touch the filesystem beyond the
# message file itself.
lkml_post_raw() {
    local series="$1" id="$2" parent_id="$3" references="$4" version="$5" depth="$6"
    local persona="$7" display_override="$8" harness="$9" model="${10}"
    local subject="${11}" tags="${12}" body="${13}" attachments="${14:-}"
    local dir; dir="$(lkml_series_dir "$series")/cur"
    local display="${display_override:-$(lkml_default_display "$persona")}"
    local email="${persona}.ai@lkml.local"
    # RFC-2822 by hand, not `date -R`: that flag is a GNU extension BSD/macOS
    # date does not have, while %a/%d/%b/%Y/%H/%M/%S/%z are plain strftime(3)
    # conversions both implementations support.
    local date_hdr; date_hdr="$(date +'%a, %d %b %Y %H:%M:%S %z')"
    local tmp="$dir/.$id.msg.tmp"
    {
        printf 'Message-ID: <%s@lkml.local>\n' "$id"
        [[ -n "$parent_id" ]] && printf 'In-Reply-To: <%s@lkml.local>\n' "$parent_id"
        [[ -n "$references" ]] && printf 'References: %s\n' "$references"
        printf 'Date: %s\n' "$date_hdr"
        printf 'From: %s (AI persona) <%s>\n' "$display" "$email"
        printf 'Subject: %s\n' "$subject"
        printf 'X-AI-Persona: %s\n' "$persona"
        printf 'X-AI-Harness: %s\n' "$harness"
        printf 'X-AI-Model: %s\n' "$model"
        printf 'X-Series: %s\n' "$series"
        printf 'X-Version: %s\n' "$version"
        printf 'X-Depth: %s\n' "$depth"
        printf 'X-Tags: %s\n' "$tags"
        if [[ -n "$attachments" ]]; then
            local _att_name
            local -a _att_names=()
            IFS='/' read -ra _att_names <<< "$attachments"
            for _att_name in "${_att_names[@]}"; do
                printf 'X-Attachment: attachments/%s\n' "$_att_name"
            done
        fi
        printf 'X-Seq: %s\n' "$(lkml_now_seq)"
        printf '\n'
        printf '%s\n' "$body"
    } > "$tmp"
    mv -- "$tmp" "$dir/$id.msg"
}

# Validates and copies each --attach file into <series>/attachments/,
# printing a '/'-separated list of basenames on stdout for the caller to
# hand to lkml_post_raw -- '/' rather than ',' because a basename can
# legally contain a comma but, by construction of `basename`, never a '/'.
# Errors (missing file, over the size cap, a basename collision with
# different content already staged) abort the whole post -- an attachment
# named on the command line that silently failed to land, or silently
# overwrote another message's attachment, would leave an X-Attachment
# header pointing at the wrong thing.
lkml_stage_attachments() {
    local series="$1"; shift
    local dir; dir="$(lkml_series_dir "$series")/attachments"
    local -a names=()
    local f base size
    for f in "$@"; do
        [[ -f "$f" ]] || { echo "Error: --attach file '$f' not found." >&2; return 1; }
        size="$(wc -c < "$f" | tr -d '[:space:]')"
        if (( size > LKML_ATTACH_MAX_BYTES )); then
            echo "Error: --attach file '$f' is $size bytes, over the" >&2
            echo "$LKML_ATTACH_MAX_BYTES byte (4 MiB) cap." >&2
            return 1
        fi
        mkdir -p -- "$dir"
        base="$(basename -- "$f")"
        if [[ -e "$dir/$base" ]] && ! cmp -s -- "$f" "$dir/$base"; then
            echo "Error: --attach '$f' would overwrite attachments/$base," >&2
            echo "which already holds different content staged by an earlier" >&2
            echo "message in this series. Rename the file and retry." >&2
            return 1
        fi
        cp -f -- "$f" "$dir/$base"
        names+=("$base")
    done
    (IFS='/'; printf '%s' "${names[*]:-}")
}

# Counts how many header lines named $2 a message file $1 carries -- unlike
# lkml_header, which returns only the first, this is for X-Attachment, which
# may legitimately repeat once per attached file.
lkml_count_header() {
    local file="$1" name="$2" line count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        [[ "$line" == "$name:"* ]] && count=$(( count + 1 ))
    done < "$file"
    printf '%s' "$count"
}

# Loads every message in a series into the parallel LKML_* arrays below,
# indexed identically -- the same convention fork-sandbox.sh's configure
# picker uses for its FS_CAND_* candidate table.
LKML_ID=(); LKML_PARENT=(); LKML_DEPTH=(); LKML_VERSION=(); LKML_PERSONA=()
LKML_HARNESS=(); LKML_MODEL=(); LKML_SUBJECT=(); LKML_TAGS=()
LKML_SEQ=(); LKML_FILE=(); LKML_ATTACH=()

lkml_load_series() {
    local series="$1" dir f id parent depth version persona harness model
    local subject tags seq attach
    LKML_ID=(); LKML_PARENT=(); LKML_DEPTH=(); LKML_VERSION=(); LKML_PERSONA=()
    LKML_HARNESS=(); LKML_MODEL=(); LKML_SUBJECT=(); LKML_TAGS=()
    LKML_SEQ=(); LKML_FILE=(); LKML_ATTACH=()
    dir="$(lkml_series_dir "$series")/cur"
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.msg; do
        [[ -e "$f" ]] || continue
        id="$(lkml_strip_id "$(lkml_header "$f" Message-ID)")"
        parent="$(lkml_strip_id "$(lkml_header "$f" In-Reply-To)")"
        depth="$(lkml_header "$f" X-Depth)"
        version="$(lkml_header "$f" X-Version)"
        persona="$(lkml_header "$f" X-AI-Persona)"
        harness="$(lkml_header "$f" X-AI-Harness)"
        model="$(lkml_header "$f" X-AI-Model)"
        subject="$(lkml_header "$f" Subject)"
        tags="$(lkml_header "$f" X-Tags)"
        seq="$(lkml_header "$f" X-Seq)"
        attach="$(lkml_count_header "$f" X-Attachment)"
        [[ -n "$seq" ]] || seq=0
        LKML_ID+=("$id"); LKML_PARENT+=("$parent"); LKML_DEPTH+=("$depth")
        LKML_VERSION+=("$version"); LKML_PERSONA+=("$persona")
        LKML_HARNESS+=("$harness"); LKML_MODEL+=("$model"); LKML_SUBJECT+=("$subject")
        LKML_TAGS+=("$tags"); LKML_SEQ+=("$seq"); LKML_FILE+=("$f"); LKML_ATTACH+=("$attach")
    done
}

lkml_index_of() {
    local id="$1" i
    for i in "${!LKML_ID[@]}"; do
        if [[ "${LKML_ID[$i]}" == "$id" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# Resolves a (possibly abbreviated) id against the currently loaded series
# into LKML_RESOLVED, or errors -- not found, or ambiguous.
LKML_RESOLVED=""
lkml_resolve_id() {
    local prefix="$1" match="" count=0 i
    for i in "${!LKML_ID[@]}"; do
        if [[ "${LKML_ID[$i]}" == "$prefix"* ]]; then
            match="${LKML_ID[$i]}"
            count=$(( count + 1 ))
        fi
    done
    if (( count == 0 )) && [[ "$prefix" =~ ^[0-9a-f]{7,40}$ ]]; then
        # Not a message id, but it could be a commit sha -- which is what a
        # reviewer that has been reading `git log` reaches for, whatever the
        # handoff says. Every [PATCH] message body opens with format-patch's
        # own "From <sha> <date>" line, so a sha names the patch that carries
        # it. When several versions carry the same commit, the newest wins:
        # that is the one under review.
        local best_version=-1
        for i in "${!LKML_ID[@]}"; do
            if grep -qE "^From ${prefix}[0-9a-f]* " "${LKML_FILE[$i]}" 2>/dev/null; then
                if (( LKML_VERSION[i] > best_version )); then
                    best_version="${LKML_VERSION[$i]}"
                    match="${LKML_ID[$i]}"
                    count=1
                fi
            fi
        done
        if (( count == 1 )); then
            echo "lkml: '$prefix' is a commit sha, not a message id; taking the patch that carries it, ${match:0:7}." >&2
        fi
    fi
    if (( count == 0 )); then
        echo "Error: no message matching id '$prefix' in this series." >&2
        return 1
    fi
    if (( count > 1 )); then
        echo "Error: id '$prefix' matches more than one message; use more characters." >&2
        return 1
    fi
    LKML_RESOLVED="$match"
    return 0
}

cmd_init() {
    local series="${1:?Usage: lkml-mailbox.sh init <series> --cover <file> --patches <dir> --from <persona>}"
    shift
    local cover="" patches="" from="" display="" version="" harness="unknown" model="unknown"
    local diffstat_range="" smoke_file=""
    local -a attach_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cover) cover="${2:?--cover requires a file}"; shift 2 ;;
            --patches) patches="${2:?--patches requires a directory}"; shift 2 ;;
            --from) from="${2:?--from requires a persona name}"; shift 2 ;;
            --display) display="${2:?--display requires a name}"; shift 2 ;;
            --version) version="${2:?--version requires a number}"; shift 2 ;;
            --harness) harness="${2:?--harness requires a value}"; shift 2 ;;
            --model) model="${2:?--model requires a value}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            --diffstat) diffstat_range="${2:?--diffstat requires a range}"; shift 2 ;;
            --smoke) smoke_file="${2:?--smoke requires a file}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: init: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    lkml_validate_series_name "$series" || return 1
    [[ -n "$from" ]] || { echo "Error: init: --from is required (the persona posting the cover letter)." >&2; return 1; }
    [[ -f "$cover" ]] || { echo "Error: init: --cover file '$cover' not found." >&2; return 1; }
    [[ -d "$patches" ]] || { echo "Error: init: --patches directory '$patches' not found." >&2; return 1; }

    local dir; dir="$(lkml_series_dir "$series")"
    mkdir -p -- "$dir/cur"

    lkml_load_series "$series"
    local maxv=0 i
    for i in "${!LKML_VERSION[@]}"; do
        (( LKML_VERSION[i] > maxv )) && maxv="${LKML_VERSION[$i]}"
    done
    if [[ -z "$version" ]]; then
        version=$(( maxv + 1 ))
    else
        for i in "${!LKML_VERSION[@]}"; do
            if [[ "${LKML_VERSION[$i]}" == "$version" ]]; then
                echo "Error: init: version $version already exists in series '$series'." >&2
                return 1
            fi
        done
    fi

    local -a patch_files=()
    while IFS= read -r f; do
        patch_files+=("$f")
    done < <(find "$patches" -maxdepth 1 -type f -name '*.patch' | sort)
    local m="${#patch_files[@]}"
    if (( m == 0 )); then
        echo "Error: init: no *.patch files found in '$patches'." >&2
        return 1
    fi

    local attach_csv=""
    if (( ${#attach_files[@]} > 0 )); then
        attach_csv="$(lkml_stage_attachments "$series" "${attach_files[@]}")" || return 1
    fi

    local cover_id cover_subject cover_body cover_first_line
    cover_id="$(lkml_new_uuid)"
    cover_first_line="$(head -n1 -- "$cover" | sed 's/[[:space:]]*$//')"
    cover_subject="[PATCH v$version 0/$m] $cover_first_line"
    cover_body="$(cat -- "$cover")"
    if [[ -n "$diffstat_range" ]]; then
        local diffstat_out
        if ! diffstat_out="$(git diff --stat "$diffstat_range" 2>&1)"; then
            echo "Error: init: --diffstat range '$diffstat_range' failed:" >&2
            echo "$diffstat_out" >&2
            return 1
        fi
        cover_body="$(printf '%s\n\n## Diffstat\n\n%s\n' "$cover_body" "$diffstat_out")"
    fi
    if [[ -n "$smoke_file" ]]; then
        [[ -f "$smoke_file" ]] || { echo "Error: init: --smoke file '$smoke_file' not found." >&2; return 1; }
        cover_body="$(printf '%s\n\n## Test results\n\n%s\n' "$cover_body" "$(cat -- "$smoke_file")")"
    fi
    lkml_post_raw "$series" "$cover_id" "" "" "$version" 0 \
        "$from" "$display" "$harness" "$model" "$cover_subject" "" "$cover_body" "$attach_csv"
    echo "fork-sandbox lkml: posted cover ${cover_id:0:7} as v$version 0/$m" >&2

    local n=0 pf subj body id
    for pf in "${patch_files[@]}"; do
        n=$(( n + 1 ))
        subj="$(grep -m1 '^Subject: ' -- "$pf" | sed 's/^Subject: //; s/^\[PATCH[^]]*\] *//')"
        [[ -n "$subj" ]] || subj="$(basename -- "$pf")"
        body="$(cat -- "$pf")"
        id="$(lkml_new_uuid)"
        lkml_post_raw "$series" "$id" "$cover_id" "<$cover_id@lkml.local>" "$version" 1 \
            "$from" "$display" "$harness" "$model" "[PATCH v$version $n/$m] $subj" "" "$body"
        echo "fork-sandbox lkml: posted patch ${id:0:7} as v$version $n/$m" >&2
    done
    printf '%s\n' "$cover_id"
}

cmd_post() {
    local series="${1:?Usage: lkml-mailbox.sh post <series> --from <persona> --reply-to <id> --file <file>}"
    shift
    local from="" display="" reply_to="" file="" subject_override="" tags="" harness="unknown" model="unknown"
    local -a attach_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:?--from requires a persona name}"; shift 2 ;;
            --display) display="${2:?--display requires a name}"; shift 2 ;;
            --reply-to) reply_to="${2:?--reply-to requires an id}"; shift 2 ;;
            --file) file="${2:?--file requires a path, or -}"; shift 2 ;;
            --subject) subject_override="${2:?--subject requires text}"; shift 2 ;;
            --tags) tags="${2:?--tags requires a comma-separated list}"; shift 2 ;;
            --harness) harness="${2:?--harness requires a value}"; shift 2 ;;
            --model) model="${2:?--model requires a value}"; shift 2 ;;
            --attach) attach_files+=("${2:?--attach requires a file}"); shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: post: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$from" ]] || { echo "Error: post: --from is required." >&2; return 1; }
    [[ -n "$reply_to" ]] || { echo "Error: post: --reply-to is required." >&2; return 1; }
    [[ -n "$file" ]] || { echo "Error: post: --file is required." >&2; return 1; }

    local dir; dir="$(lkml_series_dir "$series")"
    [[ -d "$dir/cur" ]] || { echo "Error: post: series '$series' does not exist. Run init first." >&2; return 1; }

    lkml_validate_tags "$tags" || return 1

    local attach_csv=""
    if (( ${#attach_files[@]} > 0 )); then
        attach_csv="$(lkml_stage_attachments "$series" "${attach_files[@]}")" || return 1
    fi

    lkml_load_series "$series"
    lkml_resolve_id "$reply_to" || return 1
    local parent="$LKML_RESOLVED"
    local pi; pi="$(lkml_index_of "$parent")"
    local pdepth="${LKML_DEPTH[$pi]}" pversion="${LKML_VERSION[$pi]}" psubject="${LKML_SUBJECT[$pi]}"
    local pmsgid="<$parent@lkml.local>"

    local newdepth=$(( pdepth + 1 ))
    if (( newdepth > 30 )); then
        echo "Error: post: this reply would land at depth $newdepth, past the 30-deep" >&2
        echo "limit enforced per thread. Start a new thread instead of extending this one." >&2
        return 1
    fi

    local body
    if [[ "$file" == "-" ]]; then
        body="$(cat)"
    else
        [[ -f "$file" ]] || { echo "Error: post: --file '$file' not found." >&2; return 1; }
        body="$(cat -- "$file")"
    fi
    if [[ -z "${body//[[:space:]]/}" ]]; then
        echo "Error: post: message body is empty." >&2
        return 1
    fi
    if [[ -z "$tags" ]]; then
        # No --tags. Personas write their verdict the way the list they are
        # imitating does -- a line-initial trailer in the body, "Acked-by: The
        # Security Reviewer", or a bare "NAK" opening a line -- rather than
        # in an X-Tags header, and a tag the tally never sees is a review
        # that never happened. Read the body's trailers. A quoted one
        # ("> Acked-by: ...") starts with ">" and does not count.
        local inferred="" t
        for t in Reviewed-by Acked-by; do
            if grep -qE "^$t:" <<<"$body"; then
                inferred+="${inferred:+,}$t"
            fi
        done
        # The two request tags and NAK are verdicts more than trailers,
        # and reviewers write them as sentences: "Changes-requested for the
        # gaps above." A verdict opens a reply or closes it, though; words
        # in the middle of the body are ordinary prose about the review.
        # Ignore quoted lines so a quoted verdict is not attributed to this
        # reply. A line-initial word with a space, colon or punctuation after
        # it is the tag; "Questionable" is not.
        local first_verdict_line last_verdict_line
        first_verdict_line="$(awk 'NF && $0 !~ /^[[:space:]]*>/ { print; exit }' <<<"$body")"
        last_verdict_line="$(awk 'NF && $0 !~ /^[[:space:]]*>/ { last=$0 } END { print last }' <<<"$body")"
        for t in Changes-requested Question NAK; do
            if [[ "$first_verdict_line" =~ ^$t([[:space:]:.!,]|$) ||
                  "$last_verdict_line" =~ ^$t([[:space:]:.!,]|$) ]]; then
                inferred+="${inferred:+,}$t"
            fi
        done
        tags="$inferred"
    fi

    local subject="$subject_override"
    if [[ -z "$subject" ]]; then
        case "$psubject" in
            "Re: "*) subject="$psubject" ;;
            *) subject="Re: $psubject" ;;
        esac
    fi

    local prefs newrefs
    prefs="$(lkml_header "${LKML_FILE[$pi]}" References)"
    if [[ -n "$prefs" ]]; then
        newrefs="$prefs $pmsgid"
    else
        newrefs="$pmsgid"
    fi

    local id; id="$(lkml_new_uuid)"
    lkml_post_raw "$series" "$id" "$parent" "$newrefs" "$pversion" "$newdepth" \
        "$from" "$display" "$harness" "$model" "$subject" "$tags" "$body" "$attach_csv"
    echo "fork-sandbox lkml: posted ${id:0:7} as reply to ${parent:0:7} (depth $newdepth)" >&2
    printf '%s\n' "$id"
}

lkml_tree_print() {
    local id="$1" depth="$2" i indent tags attach_mark
    i="$(lkml_index_of "$id")" || return 0
    indent="$(printf '%*s' $(( depth * 2 )) '')"
    tags="${LKML_TAGS[$i]}"
    [[ -n "$tags" ]] || tags="-"
    attach_mark=""
    [[ "${LKML_ATTACH[$i]:-0}" -gt 0 ]] && attach_mark=" 📎"
    printf '%s%s  %-14s %-16s %-20s %s%s\n' "$indent" "${id:0:7}" \
        "${LKML_PERSONA[$i]}" "(${LKML_HARNESS[$i]}/${LKML_MODEL[$i]})" "$tags" "${LKML_SUBJECT[$i]}" "$attach_mark"
    local -a child_idx=()
    local j
    for j in "${!LKML_PARENT[@]}"; do
        [[ "${LKML_PARENT[$j]}" == "$id" ]] && child_idx+=("$j")
    done
    (( ${#child_idx[@]} == 0 )) && return 0
    local -a ordered
    mapfile -t ordered < <(for j in "${child_idx[@]}"; do printf '%s\t%s\n' "${LKML_SEQ[$j]}" "$j"; done | sort -n | cut -f2)
    for j in "${ordered[@]}"; do
        lkml_tree_print "${LKML_ID[$j]}" $(( depth + 1 ))
    done
}

cmd_tree() {
    local series="${1:?Usage: lkml-mailbox.sh tree <series>}"
    local dir; dir="$(lkml_series_dir "$series")"
    [[ -d "$dir/cur" ]] || { echo "Error: tree: series '$series' does not exist." >&2; return 1; }
    lkml_load_series "$series"
    if (( ${#LKML_ID[@]} == 0 )); then
        echo "(no messages)"
        return 0
    fi
    local -a versions=() seen=()
    local i v v2 already
    for i in "${!LKML_VERSION[@]}"; do
        v="${LKML_VERSION[$i]}"
        already=0
        for v2 in "${seen[@]:-}"; do
            [[ "$v2" == "$v" ]] && already=1
        done
        (( already )) || { versions+=("$v"); seen+=("$v"); }
    done
    local -a sorted_versions
    mapfile -t sorted_versions < <(printf '%s\n' "${versions[@]}" | sort -n)
    for v in "${sorted_versions[@]}"; do
        printf '=== v%s ===\n' "$v"
        local root=""
        for i in "${!LKML_ID[@]}"; do
            if [[ "${LKML_VERSION[$i]}" == "$v" && "${LKML_DEPTH[$i]}" == "0" ]]; then
                root="${LKML_ID[$i]}"
            fi
        done
        [[ -n "$root" ]] && lkml_tree_print "$root" 0
    done
}

cmd_cover() {
    local series="${1:?Usage: lkml-mailbox.sh cover <series>}"
    lkml_load_series "$series"
    if (( ${#LKML_ID[@]} == 0 )); then
        echo "Error: cover: series '$series' has no messages." >&2
        return 1
    fi
    local maxv=-1 best=-1 i
    for i in "${!LKML_VERSION[@]}"; do
        if [[ "${LKML_DEPTH[$i]}" == "0" ]] && (( LKML_VERSION[i] > maxv )); then
            maxv="${LKML_VERSION[$i]}"
            best="$i"
        fi
    done
    if (( best < 0 )); then
        echo "Error: cover: no cover letter found." >&2
        return 1
    fi
    lkml_body "${LKML_FILE[$best]}"
}

cmd_show() {
    local series="${1:?Usage: lkml-mailbox.sh show <series> <id>}"
    local id="${2:?Usage: lkml-mailbox.sh show <series> <id>}"
    lkml_load_series "$series"
    lkml_resolve_id "$id" || return 1
    local i; i="$(lkml_index_of "$LKML_RESOLVED")"
    cat -- "${LKML_FILE[$i]}"
}

cmd_open() {
    local series="${1:?Usage: lkml-mailbox.sh open <series>}"
    shift
    local version=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="${2:?--version requires a number}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: open: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    local dir; dir="$(lkml_series_dir "$series")"
    [[ -d "$dir/cur" ]] || { echo "Error: open: series '$series' does not exist." >&2; return 1; }
    lkml_load_series "$series"
    local i j found=0 answered
    for i in "${!LKML_ID[@]}"; do
        [[ -z "$version" || "${LKML_VERSION[$i]}" == "$version" ]] || continue
        case "${LKML_TAGS[$i]}" in
            *Question*|*Changes-requested*|*NAK*) ;;
            *) continue ;;
        esac
        answered=0
        for j in "${!LKML_PARENT[@]}"; do
            if [[ "${LKML_PARENT[$j]}" == "${LKML_ID[$i]}" && "${LKML_PERSONA[$j]}" != "${LKML_PERSONA[$i]}" ]]; then
                answered=1
                break
            fi
        done
        if (( ! answered )); then
            found=1
            printf 'v%s  %s  %-14s %-20s %s\n' "${LKML_VERSION[$i]}" "${LKML_ID[$i]:0:7}" \
                "${LKML_PERSONA[$i]}" "${LKML_TAGS[$i]}" "${LKML_SUBJECT[$i]}"
        fi
    done
    (( found )) || echo "(no open threads)"
    return 0
}

cmd_tally() {
    local series="${1:?Usage: lkml-mailbox.sh tally <series> --version <n>}"
    shift
    local version=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="${2:?--version requires a number}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: tally: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$version" ]] || { echo "Error: tally: --version is required." >&2; return 1; }
    lkml_load_series "$series"
    if (( ${#LKML_ID[@]} == 0 )); then
        echo "Error: tally: series '$series' has no messages." >&2
        return 1
    fi

    local -A patch_by_num=() label_by_num=()
    local i subj num
    for i in "${!LKML_ID[@]}"; do
        [[ "${LKML_VERSION[$i]}" == "$version" ]] || continue
        subj="${LKML_SUBJECT[$i]}"
        num=""
        if [[ "${LKML_DEPTH[$i]}" == "0" ]]; then
            num=0
        elif [[ "${LKML_DEPTH[$i]}" == "1" && "$subj" != "Re: "* \
            && "$subj" =~ ^\[PATCH\ v[0-9]+\ ([0-9]+)/[0-9]+\] ]]; then
            num="${BASH_REMATCH[1]}"
        fi
        [[ -n "$num" ]] || continue
        patch_by_num[$num]="${LKML_ID[$i]}"
        label_by_num[$num]="$subj"
    done
    if (( ${#patch_by_num[@]} == 0 )); then
        echo "Error: tally: version $version not found in series '$series'." >&2
        return 1
    fi

    printf 'Series: %s  Version: %s\n' "$series" "$version"
    local -a nums
    mapfile -t nums < <(printf '%s\n' "${!patch_by_num[@]}" | sort -n)
    local p root label
    # Every patch's root is a direct child of the cover, so a plain
    # descendant walk from the cover's id reaches every patch's whole
    # subtree too -- patch 0's tally would then roll up every persona's
    # LATEST tag anywhere in the series, not just tags about the cover
    # itself. Stop the walk at another patch's own root so each patch
    # (cover included) is tallied only from what was actually said about it.
    local -A is_patch_root=()
    for p in "${nums[@]}"; do
        is_patch_root["${patch_by_num[$p]}"]=1
    done
    for p in "${nums[@]}"; do
        root="${patch_by_num[$p]}"
        label="${label_by_num[$p]}"
        [[ "$p" == "0" ]] && label="(cover) $label"

        local -a subtree=("$root")
        local k=0 cur j child
        while (( k < ${#subtree[@]} )); do
            cur="${subtree[$k]}"
            for j in "${!LKML_PARENT[@]}"; do
                [[ "${LKML_PARENT[$j]}" == "$cur" ]] || continue
                child="${LKML_ID[$j]}"
                [[ "$child" == "$root" || -z "${is_patch_root[$child]+x}" ]] || continue
                subtree+=("$child")
            done
            k=$(( k + 1 ))
        done

        local -A latest_seq=() latest_tags=()
        local mid person s in_subtree
        for i in "${!LKML_ID[@]}"; do
            mid="${LKML_ID[$i]}"
            in_subtree=0
            for s in "${subtree[@]}"; do
                [[ "$s" == "$mid" ]] && { in_subtree=1; break; }
            done
            (( in_subtree )) || continue
            [[ -n "${LKML_TAGS[$i]}" ]] || continue
            person="${LKML_PERSONA[$i]}"
            if [[ -z "${latest_seq[$person]+x}" ]] || (( LKML_SEQ[i] >= latest_seq[$person] )); then
                latest_seq[$person]="${LKML_SEQ[$i]}"
                latest_tags[$person]="${LKML_TAGS[$i]}"
            fi
        done

        printf 'Patch %s: %s\n' "$p" "$label"
        if (( ${#latest_tags[@]} == 0 )); then
            printf '  no tags\n'
        else
            for person in "${!latest_tags[@]}"; do
                printf '  %-14s %s\n' "$person" "${latest_tags[$person]}"
            done
        fi
    done
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
    init) shift; cmd_init "$@" ;;
    post) shift; cmd_post "$@" ;;
    tree) shift; cmd_tree "$@" ;;
    cover) shift; cmd_cover "$@" ;;
    show) shift; cmd_show "$@" ;;
    open) shift; cmd_open "$@" ;;
    tally) shift; cmd_tally "$@" ;;
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
