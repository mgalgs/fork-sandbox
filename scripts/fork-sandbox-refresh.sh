#!/usr/bin/env bash
# fork-sandbox-refresh.sh — Shared --refresh-at loop logic (sourced library, not a command)
#
# Usage: source "$script_dir/fork-sandbox-refresh.sh"
#
# The pure half of the context-refresh loop: taking a session's hand-off out
# of the outbox, judging it stale, archiving delivered addenda, and building
# the continuation prompt. Sourced by the fork-sandbox.sh runner (locally)
# and shipped to the pod as ConfigMap key `refresh.sh`, where the k8s
# entrypoint sources it. One implementation, so the two paths cannot drift.
#
# Self-contained on purpose: no fork-sandbox-lib.sh dependency, no globals
# read, no top-level side effects. Everything a function needs is an
# argument. Every line stays within 96 columns: ConfigMap keys are indented
# four columns and the YAML is limited to 100.

# True iff the leg that wrote <events-file> was nudged to hand off. The tag
# is the inbox hook's own stderr line, which --include-hook-events folds
# into the leg's event stream as a hook_response event.
fs_refresh_leg_was_nudged() {
    grep -q 'fork-sandbox-refresh: nudged' "$1" 2>/dev/null
}

# Move the hand-off out of the outbox into the run record, refusing what
# is not a usable hand-off. $1 outbox dir, $2 record dir, $3 the number
# the taken hand-off will carry (handoff-<n>.md), $4 log file for refusal
# messages. Prints the taken path and returns 0, or prints nothing and
# returns 1 on a refusal.
fs_refresh_take_handoff() {
    local outbox_dir="$1" record_dir="$2" next_n="$3" log="$4"
    local src="$outbox_dir/handoff.md" record_name="handoff-$next_n.md" bytes
    # A session wrote this, so a symlink here is not a hand-off: refuse it
    # rather than follow it out of the clone.
    if [[ -L "$src" ]]; then
        printf 'fork-sandbox: outbox handoff.md is a symlink; refusing it.\n' \
            >> "$log"
        rm -f -- "$src" 2>/dev/null
        return 1
    fi
    # An oversized hand-off is moved aside so it is not silently
    # reconsidered on the next check.
    bytes="$(wc -c < "$src" 2>/dev/null || printf 0)"
    if (( bytes > 65536 )); then
        {
            printf 'fork-sandbox: outbox handoff.md is %s bytes, ' "$bytes"
            printf 'over the 64 KiB cap; refusing it.\n'
        } >> "$log"
        mv -f -- "$src" "$record_dir/handoff-refused-too-large.md" 2>/dev/null
        return 1
    fi
    # An empty or dangling hand-off (wc -c failing falls back to 0, which
    # passes the cap above) would launch a continuation with no task.
    if [[ ! -s "$src" ]]; then
        printf 'fork-sandbox: outbox handoff.md is empty; refusing it.\n' \
            >> "$log"
        mv -f -- "$src" "$record_dir/handoff-refused-empty.md" 2>/dev/null
        return 1
    fi
    mv -f -- "$src" "$record_dir/$record_name"
    # Guard the window between the checks above and the mv: what gets
    # cat'd into the prompt must be a plain file that landed in the record
    # dir, never a symlink followed here.
    if [[ -L "$record_dir/$record_name" || ! -f "$record_dir/$record_name" ]]; then
        printf 'fork-sandbox: %s is not a regular file after the move; refusing it.\n' \
            "$record_name" >> "$log"
        rm -f -- "$record_dir/$record_name" 2>/dev/null
        return 1
    fi
    printf '%s\n' "$record_dir/$record_name"
}

# True iff <handoff> predates the clone's last commit. Reads an mtime only;
# it never runs git in the clone. The move preserved mtime, so pass the
# RECORD, not the outbox path it came from.
fs_refresh_handoff_stale() {
    [[ -f "$1/.git/logs/HEAD" && "$1/.git/logs/HEAD" -nt "$2" ]]
}

# Every addendum archived out of an earlier leg, oldest first, one line per
# inbox-delivered leg directory. Sorted by leg number, not directory name:
# "leg-10" must not sort before "leg-2". $1 record dir.
fs_refresh_addenda_dirs() {
    local d leg_n
    for d in "$1"/inbox-delivered/leg-*; do
        [[ -d "$d" && ! -L "$d" ]] || continue
        leg_n="${d##*/leg-}"
        printf '%s %s\n' "$leg_n" "$d"
    done | sort -n -k1,1 | cut -d' ' -f2-
}

# Move the addenda a finished leg had delivered out of the live inbox, so
# the next leg's sandbox does not see them again as new. $1 inbox dir, $2
# record dir, $3 leg number, $4 log file. Mail banners are split into
# mail-delivered/: a banner is new thread information from the postmaster,
# not an operator instruction, and archiving it beside real addenda would
# re-surface it later under the addenda's authority.
fs_refresh_archive_inbox() {
    local inbox_dir="$1" record_dir="$2" leg_no="$3" log="$4" \
        dest="" mail_dest="" f moved=0
    for f in "$inbox_dir"/*.md; do
        [[ -e "$f" || -L "$f" ]] || continue
        if [[ -L "$f" ]]; then
            printf 'fork-sandbox: %s is a symlink; refusing to archive it.\n' \
                "$f" >> "$log"
            continue
        fi
        [[ -f "$f" ]] || continue
        if [[ "${f##*/}" == mail-banner-* ]]; then
            if [[ -z "$mail_dest" ]]; then
                mail_dest="$record_dir/mail-delivered/leg-$leg_no"
                mkdir -p "$mail_dest"
            fi
            mv -f -- "$f" "$mail_dest/"
            continue
        fi
        if (( ! moved )); then
            dest="$record_dir/inbox-delivered/leg-$leg_no"
            mkdir -p "$dest"
        fi
        mv -f -- "$f" "$dest/"
        moved=1
    done
}

# Build continuation <n>'s prompt. $1 continuation number (1 for the first
# continuation, the count named in handoff-N.md and continuation-prompt-N.md),
# $2 the hand-off, already moved to its record, $3 the destination path, $4
# whether the hand-off is stale (0|1), $5 the header file (the static
# preamble), $6 the original brief, $7 the record dir the addenda were
# archived under. Order: header, framing, original brief, operator addenda
# from earlier legs, a stale warning when $4 is 1, the previous hand-off.
# shellcheck disable=SC2016  # the backticks are literal prompt text
fs_refresh_build_prompt() {
    local n="$1" handoff="$2" out="$3" stale="${4:-0}" header="$5" \
        brief="$6" record_dir="$7" addenda_list d f
    addenda_list="$(fs_refresh_addenda_dirs "$record_dir")"
    {
        cat -- "$header"
        printf '\n---\n\n# This is continuation %s of a run that refreshed its context\n\n' "$n"
        printf 'A previous session, in this same clone and on this same branch, used up\n'
        printf 'most of its context window and wrote a hand-off for a fresh session to\n'
        printf 'continue from. You are that fresh session, with none of its memory.\n'
        if [[ -n "$addenda_list" ]]; then
            printf 'Three documents follow: the original brief this run was launched\n'
            printf 'with, any operator addenda delivered to earlier legs of this run,\n'
            printf 'and the hand-off the previous leg wrote against it.\n\n'
        else
            printf 'Two documents follow: the original brief this run was launched with,\n'
            printf 'and the hand-off the previous leg wrote against it.\n\n'
        fi
        printf 'The brief is authoritative for what the task IS -- check its own list\n'
        printf 'of items, not the hand-off'"'"'s account of it, to decide what is left.\n'
        if [[ -n "$addenda_list" ]]; then
            printf 'The addenda carry the same authority as the brief and outrank it\n'
            printf 'where the two conflict -- see their own section below for what each\n'
            printf 'one asked for.\n'
        fi
        printf 'The hand-off is authoritative for what has been done against the brief\n'
        printf 'so far. Where the hand-off summarises, abbreviates or omits items the\n'
        printf 'brief contains, the brief wins.\n\n'
        printf '\n---\n\n## The original brief\n\n'
        cat -- "$brief"
        if [[ -n "$addenda_list" ]]; then
            printf '\n---\n\n## Operator addenda delivered to earlier legs\n\n'
            printf 'The operator sent the messages below to an earlier leg of this same\n'
            printf 'run, oldest first. They carry the same authority as the brief above\n'
            printf 'and outrank it where the two conflict. Where a message asks for\n'
            printf 'something to be done, the leg that received it has most likely\n'
            printf 'already done it -- check `git log --oneline` before redoing any of\n'
            printf 'it. Where a message is a constraint or a correction, it still binds.\n'
            while IFS= read -r d; do
                [[ -n "$d" ]] || continue
                for f in "$d"/*.md; do
                    [[ -f "$f" ]] || continue
                    printf '\n### %s\n\n' "${f##*/}"
                    cat -- "$f"
                done
            done <<< "$addenda_list"
        fi
        if (( stale )); then
            printf '\n---\n\n## Warning: this hand-off is stale\n\n'
            printf 'It was written before the last commit on this branch, so its "done"\n'
            printf 'and "left" lists may be wrong. Run `git log --oneline` and `git status`\n'
            printf 'first and reconcile against the brief above before doing anything.\n'
        fi
        printf '\n---\n\n## Hand-off from the previous leg\n\n'
        cat -- "$handoff"
    } > "$out.part"
    mv -- "$out.part" "$out"
}
