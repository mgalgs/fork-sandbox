#!/usr/bin/env bash
# fork-sandbox-mail-test.sh — Exercise fork-sandbox-mail.sh: send, reply,
# show, tree, list, inbox, seen, against a throwaway mail root.
#
# Usage: tests/fork-sandbox-mail-test.sh
#
# Runs entirely offline against a temp FORK_SANDBOX_MAIL_ROOT -- never the
# real default path.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
mail="$repo_dir/scripts/fork-sandbox-mail.sh"

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
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

refuses() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        no "$label" "it succeeded; output: $out"
    else
        ok "$label"
    fi
}

# Sets $1 to a fresh temp dir and registers it for cleanup. A nameref
# out-param, not a printf-and-capture return: "$(new_root)" would run the
# body in a command-substitution subshell, where "tmpdirs+=" only updates
# the subshell's copy and the dir would never actually get tracked.
new_root() {
    local -n out_ref="$1"
    out_ref="$(mktemp -d)"
    tmpdirs+=("$out_ref")
}

work="$(mktemp -d)"
tmpdirs+=("$work")
cd "$work" || exit 1

printf '== send ==\n'

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT

id1="$("$mail" send --from @alice --to @bob --subject "Hello" --body - <<< "hi there" 2>diag.txt)"
rc=$?
check "send exits 0" "0" "$rc"

thread_dir="$FORK_SANDBOX_MAIL_ROOT/threads/$id1"
check "thread dir exists, named after the root id" "1" "$([[ -d "$thread_dir" ]] && echo 1 || echo 0)"
check "one message file, 001- prefixed" "1" "$(find "$thread_dir" -maxdepth 1 -name "001-*.msg" | wc -l)"

raw1="$("$mail" show "$id1")"
contains "header: Message-ID" "$raw1" "Message-ID: $id1"
contains "header: Thread-ID equals Message-ID on a root" "$raw1" "Thread-ID: $id1"
contains "header: From" "$raw1" "From: @alice"
contains "header: To" "$raw1" "To: @bob"
contains "header: Subject" "$raw1" "Subject: Hello"
contains "header: X-Hops defaults to 8" "$raw1" "X-Hops: 8"
contains "body carries through" "$raw1" "hi there"
case "$raw1" in
    *"In-Reply-To:"*) no "a new thread has no In-Reply-To" ;;
    *) ok "a new thread has no In-Reply-To" ;;
esac

printf '\n== send: Cc, --hops, body from a file ==\n'

echo "file body" > body.txt
id_cc="$("$mail" send --from @alice --to @bob --cc @carol --subject "Cc'd" --body body.txt --hops 3 2>diag.txt)"
raw_cc="$("$mail" show "$id_cc")"
contains "Cc header present" "$raw_cc" "Cc: @carol"
contains "--hops override" "$raw_cc" "X-Hops: 3"
contains "body from a file matches body from stdin behavior" "$raw_cc" "file body"

printf '\n== reply threading ==\n'

id2="$("$mail" reply --from @bob --reply-to "$id1" --body - <<< "hi back" 2>diag.txt)"
rc=$?
check "reply exits 0" "0" "$rc"
check "reply lands in the same thread dir" "1" "$([[ -d "$thread_dir" ]] && find "$thread_dir" -maxdepth 1 -name "002-*.msg" | wc -l)"

raw2="$("$mail" show "$id2")"
contains "reply: Thread-ID equals the root" "$raw2" "Thread-ID: $id1"
contains "reply: In-Reply-To names the parent" "$raw2" "In-Reply-To: $id1"
contains "reply: References carries the parent" "$raw2" "References: $id1"
contains "reply: default subject prefixes Re: once" "$raw2" "Subject: Re: Hello"
contains "reply: reply-all default To is the sender minus itself" "$raw2" "To: @alice"

id3="$("$mail" reply --from @alice --reply-to "$id2" --body - <<< "again" 2>diag.txt)"
raw3="$("$mail" show "$id3")"
contains "grandchild: In-Reply-To names its direct parent" "$raw3" "In-Reply-To: $id2"
contains "grandchild: References has both ancestors" "$raw3" "References: $id1 $id2"
contains "grandchild: Re: is not doubled" "$raw3" "Subject: Re: Hello"
case "$raw3" in
    *"Re: Re:"*) no "grandchild subject has no doubled Re:" ;;
    *) ok "grandchild subject has no doubled Re:" ;;
esac
check "grandchild lands as 003" "1" "$(find "$thread_dir" -maxdepth 1 -name "003-*.msg" | wc -l)"

printf '\n== reply-all and explicit --to ==\n'

id_multi="$("$mail" send --from @alice --to @bob,@dave --cc @carol --subject "Group" --body - <<< "hi all" 2>diag.txt)"
id_reply_all="$("$mail" reply --from @bob --reply-to "$id_multi" --body - <<< "reply all" 2>diag.txt)"
raw_ra="$("$mail" show "$id_reply_all")"
contains "reply-all includes original From" "$raw_ra" "@alice"
contains "reply-all includes other To addresses" "$raw_ra" "@dave"
contains "reply-all includes Cc addresses" "$raw_ra" "@carol"
case "$raw_ra" in
    *"To: "*"@bob"*) no "reply-all excludes the replying sender" "$raw_ra" ;;
    *) ok "reply-all excludes the replying sender" ;;
esac

id_explicit="$("$mail" reply --from @bob --reply-to "$id_multi" --to @dave --body - <<< "just dave" 2>diag.txt)"
raw_explicit="$("$mail" show "$id_explicit")"
check "explicit --to overrides reply-all" "To: @dave" "$(grep '^To:' <<< "$raw_explicit")"

printf '\n== X-Hops copy on reply ==\n'

id_hops="$("$mail" send --from @alice --to @bob --subject "Hops" --body - --hops 2 <<< "x" 2>diag.txt)"
id_hops_reply="$("$mail" reply --from @bob --reply-to "$id_hops" --body - <<< "y" 2>diag.txt)"
raw_hops_reply="$("$mail" show "$id_hops_reply")"
contains "reply copies parent's X-Hops verbatim" "$raw_hops_reply" "X-Hops: 2"

printf '\n== address validation ==\n'

refuses "rejects a bare name with no @" "$mail" send --from alice --to @bob --subject x --body -
refuses "rejects an uppercase address" "$mail" send --from @Alice --to @bob --subject x --body -
refuses "rejects a leading hyphen" "$mail" send --from @-alice --to @bob --subject x --body -
refuses "rejects an empty address" "$mail" send --from @ --to @bob --subject x --body -
refuses "rejects an address with embedded spaces" "$mail" send --from "@al ice" --to @bob --subject x --body -
refuses "rejects a malformed --to" "$mail" send --from @alice --to bob --subject x --body -
refuses "rejects a missing --from" "$mail" send --to @bob --subject x --body -

printf '\n== address list trimming ==\n'

id_trim_comma="$("$mail" send --from @alice --to "@bob, @carol" --subject x --body - <<< "y" 2>diag.txt)"
rc=$?
check "', '-separated --to is accepted" "0" "$rc"
raw_trim_comma="$("$mail" show "$id_trim_comma")"
check "', '-separated --to is stored normalized" "To: @bob, @carol" "$(grep '^To:' <<< "$raw_trim_comma")"

id_trim_tab="$("$mail" send --from @alice --to $'@bob,\t@carol' --cc $'@dave, \t@erin' --subject x --body - <<< "y" 2>diag.txt)"
rc=$?
check "tab-padded --to/--cc are accepted" "0" "$rc"
raw_trim_tab="$("$mail" show "$id_trim_tab")"
check "tab-padded --to is stored normalized" "To: @bob, @carol" "$(grep '^To:' <<< "$raw_trim_tab")"
check "tab-padded --cc is stored normalized" "Cc: @dave, @erin" "$(grep '^Cc:' <<< "$raw_trim_tab")"

refuses "an empty element between commas is still rejected" "$mail" send --from @alice --to "@bob,,@carol" --subject x --body -
refuses "a whitespace-only element between commas is still rejected" "$mail" send --from @alice --to "@bob, ,@carol" --subject x --body -

id_trim_reply="$("$mail" reply --from @bob --reply-to "$id1" --to "@alice, @carol" --body - <<< "z" 2>diag.txt)"
rc=$?
check "', '-separated reply --to is accepted" "0" "$rc"
raw_trim_reply="$("$mail" show "$id_trim_reply")"
check "', '-separated reply --to is stored normalized" "To: @alice, @carol" "$(grep '^To:' <<< "$raw_trim_reply")"

printf '\n== inbox and seen ==\n'

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
i1="$("$mail" send --from @alice --to @bob --subject "To bob" --body - <<< "m1" 2>diag.txt)"
i2="$("$mail" send --from @alice --to @carol --cc @bob --subject "Cc bob" --body - <<< "m2" 2>diag.txt)"
i3="$("$mail" send --from @alice --to @dave --subject "Not for bob" --body - <<< "m3" 2>diag.txt)"

inbox_bob="$("$mail" inbox bob)"
contains "inbox: message addressed via To shows To" "$inbox_bob" "$(printf '%s\t%s\tTo' "$i1" "$i1")"
contains "inbox: message addressed via Cc shows Cc" "$inbox_bob" "$(printf '%s\t%s\tCc' "$i2" "$i2")"
case "$inbox_bob" in
    *"$i3"*) no "inbox: unaddressed message is excluded" "$inbox_bob" ;;
    *) ok "inbox: unaddressed message is excluded" ;;
esac

check "inbox for an unknown agent is empty, not an error" "" "$("$mail" inbox nobody)"

"$mail" seen bob "$i1"
inbox_bob2="$("$mail" inbox bob)"
case "$inbox_bob2" in
    *"$i1"*) no "seen: a seen message is filtered from inbox" "$inbox_bob2" ;;
    *) ok "seen: a seen message is filtered from inbox" ;;
esac
contains "inbox --all still shows seen messages" "$("$mail" inbox bob --all)" "$i1"

"$mail" seen bob "$i1" "$i2"
seen_file="$FORK_SANDBOX_MAIL_ROOT/agents/bob/seen"
check "seen: creates the agent's seen path" "1" "$([[ -f "$seen_file" ]] && echo 1 || echo 0)"
check "seen: dedups repeated ids" "1" "$(grep -c "^$i1\$" "$seen_file")"
check "seen: records multiple ids" "2" "$(wc -l < "$seen_file")"

printf '\n== attachments ==\n'

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
echo "a screenshot, pretend" > shot.png
att_id="$("$mail" send --from @alice --to @bob --subject "With attachment" --body - --attach shot.png <<< "see attached" 2>diag.txt)"
rc=$?
check "send --attach exits 0" "0" "$rc"
check "attachment is copied into the thread's attachments dir" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/threads/$att_id/attachments" -name 'shot.png' | wc -l)"
raw_att="$("$mail" show "$att_id")"
contains "X-Attachment header names the file" "$raw_att" "X-Attachment: attachments/shot.png"

tree_att="$("$mail" tree "$att_id")"
contains "tree marks the attachment with 📎" "$tree_att" "📎"

big="$work/big-attachment.bin"
dd if=/dev/zero of="$big" bs=1M count=5 >/dev/null 2>&1
out="$("$mail" send --from @alice --to @bob --subject "Too big" --body - --attach "$big" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "refuses an attachment over the 4 MiB cap"; else no "refuses an attachment over the 4 MiB cap" "it succeeded"; fi
contains "the cap refusal names the byte cap" "$out" "4194304"

"$mail" reply --from @bob --reply-to "$att_id" --body - --attach shot.png <<< "same content" >/dev/null 2>diag.txt
rc=$?
check "same-basename-same-content attachment is accepted" "0" "$rc"

echo "different content" > shot2.png
mv shot2.png shot.png
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - --attach shot.png <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses a same-basename attachment with different content"
else
    no "refuses a same-basename attachment with different content" "it succeeded"
fi
contains "the collision refusal names the colliding path" "$out" "attachments/shot.png"

printf '\n== attachments: a later refusal stages nothing, not even an earlier clean attachment ==\n'

# All of send/reply's attachment refusals are checked before any `cp` runs
# (fork-sandbox-mail.sh's mail_stage_attachments), so a reply with a clean
# attachment followed by one that gets refused must stage *neither* -- if
# the hoist ever regresses to a per-attachment check-then-cp loop, the
# first, clean attachment would already be copied by the time the second
# one's check fails. A single-attachment refusal can't witness that
# regression (its own check already ran before its own cp, hoisted or
# not), so each case here pairs a fresh clean attachment with the failing
# one. Reusing $att_id (an existing thread) makes the leak permanent and
# visible, unlike testing against a brand-new thread with nothing staged.
attach_files_before="$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

echo "clean, not-found case" > "$work/clean-notfound.txt"
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - \
    --attach "$work/clean-notfound.txt" --attach "$work/does-not-exist.bin" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "reply refuses an attachment that does not exist"
else
    no "reply refuses an attachment that does not exist" "it succeeded"
fi
check "the not-found refusal staged no attachment, including the earlier clean one" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

echo "clean, over-cap case" > "$work/clean-overcap.txt"
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - \
    --attach "$work/clean-overcap.txt" --attach "$big" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "reply refuses an attachment over the 4 MiB cap"
else
    no "reply refuses an attachment over the 4 MiB cap" "it succeeded"
fi
check "the over-cap refusal staged no attachment, including the earlier clean one" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

# shot.png (in $work) holds "different content" from earlier in this file --
# still a cross-message collision against attachments/shot.png.
echo "clean, collision case" > "$work/clean-collision.txt"
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - \
    --attach "$work/clean-collision.txt" --attach shot.png <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "reply refuses a cross-message basename collision"
else
    no "reply refuses a cross-message basename collision" "it succeeded"
fi
check "the cross-message collision refusal staged no attachment, including the earlier clean one" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

printf '\n== attachments: two --attach args in one command sharing a basename are refused ==\n'

mkdir -p "$work/dup-a" "$work/dup-b"
echo "dup content a" > "$work/dup-a/dup.txt"
echo "dup content b" > "$work/dup-b/dup.txt"
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - \
    --attach "$work/dup-a/dup.txt" --attach "$work/dup-b/dup.txt" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "refuses two --attach args in one command sharing a basename with different content"
else
    no "refuses two --attach args in one command sharing a basename with different content" "it succeeded"
fi
contains "the same-invocation collision refusal names the shared basename" "$out" "attachments/dup.txt"
check "the same-invocation collision refusal staged no attachment" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

printf '\n== attachments: two --attach args in one command sharing a basename with IDENTICAL content is allowed and de-duplicated ==\n'

mkdir -p "$work/samedup-a" "$work/samedup-b"
echo "same bytes" > "$work/samedup-a/samedup.txt"
echo "same bytes" > "$work/samedup-b/samedup.txt"
samedup_id="$("$mail" reply --from @bob --reply-to "$att_id" --body - \
    --attach "$work/samedup-a/samedup.txt" --attach "$work/samedup-b/samedup.txt" <<< "x" 2>diag.txt)"
rc=$?
check "identical-content duplicate --attach exits 0" "0" "$rc"
raw_samedup="$("$mail" show "$samedup_id")"
check "identical-content duplicate --attach yields exactly one X-Attachment header" "1" \
    "$(grep -c '^X-Attachment:' <<< "$raw_samedup")"
contains "the X-Attachment header names the shared basename" "$raw_samedup" "X-Attachment: attachments/samedup.txt"
check "exactly one file is staged for the shared basename" "1" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/samedup.txt' -type f | wc -l)"

printf '\n== attachments: multiple clean attachments ==\n'

echo "file a" > "attach,a.txt"
echo "file b" > "attach b.txt"
multi_id="$("$mail" send --from @alice --to @bob --subject "Two attachments" --body - \
    --attach "attach,a.txt" --attach "attach b.txt" <<< "see both" 2>diag.txt)"
rc=$?
check "send with two --attach exits 0" "0" "$rc"
raw_multi="$("$mail" show "$multi_id")"
check "one X-Attachment header per file" "2" \
    "$(grep -c '^X-Attachment:' <<< "$raw_multi")"
contains "X-Attachment header names the first file (basename has a comma)" "$raw_multi" "X-Attachment: attachments/attach,a.txt"
contains "X-Attachment header names the second file (basename has a space)" "$raw_multi" "X-Attachment: attachments/attach b.txt"

printf '\n== attachments: a newline in the basename is refused ==\n'

# `read -ra` (used to split the '/'-joined staged-basename list back apart)
# stops at the first newline, so a newline inside a basename would
# silently truncate that list and drop a later attachment's header.
nl_file="$work/$(printf 'evil\nname.txt')"
printf 'content\n' > "$nl_file"

msgs_before="$(find "$FORK_SANDBOX_MAIL_ROOT" -name '*.msg' | wc -l)"
attach_files_before="$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

out="$("$mail" send --from @alice --to @bob --subject "NL attach" --body - --attach "$nl_file" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "send refuses an attachment with a newline in its basename"
else
    no "send refuses an attachment with a newline in its basename" "it succeeded"
fi
check "the refused send wrote no new message" "$msgs_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -name '*.msg' | wc -l)"
check "the refused send staged no attachment" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

reply_msgs_before="$(find "$FORK_SANDBOX_MAIL_ROOT/threads/$att_id" -maxdepth 1 -name '*.msg' | wc -l)"
out="$("$mail" reply --from @bob --reply-to "$att_id" --body - --attach "$nl_file" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "reply refuses an attachment with a newline in its basename"
else
    no "reply refuses an attachment with a newline in its basename" "it succeeded"
fi
check "the refused reply wrote no new message in the thread" "$reply_msgs_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/threads/$att_id" -maxdepth 1 -name '*.msg' | wc -l)"
check "the refused reply staged no attachment" "$attach_files_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -path '*/attachments/*' -type f | wc -l)"

printf '\n== show on a missing id ==\n'

refuses "show fails on an id that matches nothing" "$mail" show "not-a-real-id"

printf '\n== body from stdin vs from a file ==\n'

echo "same body" > samebody.txt
id_file="$("$mail" send --from @alice --to @bob --subject "Via file" --body samebody.txt 2>diag.txt)"
id_stdin="$("$mail" send --from @alice --to @bob --subject "Via stdin" --body - <<< "same body" 2>diag.txt)"
body_file="$("$mail" show "$id_file" | tail -n1)"
body_stdin="$("$mail" show "$id_stdin" | tail -n1)"
check "stdin and file bodies produce identical content" "$body_file" "$body_stdin"

printf '\n== sequential replies get distinct, increasing seq numbers ==\n'

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
root_id="$("$mail" send --from @alice --to @bob --subject "Seq" --body - <<< "root" 2>diag.txt)"
for _ in 1 2 3 4; do
    "$mail" reply --from @bob --reply-to "$root_id" --body - <<< "reply" >/dev/null 2>diag.txt
done
mapfile -t seqs < <(find "$FORK_SANDBOX_MAIL_ROOT/threads/$root_id" -maxdepth 1 -name '*.msg' -printf '%f\n' | sort | sed -n 's/^\([0-9]\{3\}\)-.*/\1/p')
check "five messages produced five distinct seq prefixes" "5" "${#seqs[@]}"
expected=("001" "002" "003" "004" "005")
if [[ "${seqs[*]}" == "${expected[*]}" ]]; then
    ok "seq numbers are strictly increasing and gap-free"
else
    no "seq numbers are strictly increasing and gap-free" "got: ${seqs[*]}"
fi

printf '\n== concurrent replies still get distinct, gap-free seq numbers ==\n'

seq_root="$FORK_SANDBOX_MAIL_ROOT"
new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
conc_root="$("$mail" send --from @alice --to @bob --subject "Concurrent" --body - <<< "root" 2>diag.txt)"
conc_n=12
for _ in $(seq 1 "$conc_n"); do
    "$mail" reply --from @bob --reply-to "$conc_root" --body - <<< "reply" >/dev/null 2>diag.txt &
done
wait
mapfile -t conc_seqs < <(find "$FORK_SANDBOX_MAIL_ROOT/threads/$conc_root" -maxdepth 1 -name '*.msg' -printf '%f\n' | sort | sed -n 's/^\([0-9]\{3\}\)-.*/\1/p')
conc_expected=()
for i in $(seq 1 "$(( conc_n + 1 ))"); do
    conc_expected+=("$(printf '%03d' "$i")")
done
check "concurrent replies produce as many distinct seq prefixes as messages" "$(( conc_n + 1 ))" "${#conc_seqs[@]}"
if [[ "${conc_seqs[*]}" == "${conc_expected[*]}" ]]; then
    ok "concurrent seq numbers are exactly 001..00N, no dupes or gaps"
else
    no "concurrent seq numbers are exactly 001..00N, no dupes or gaps" "got: ${conc_seqs[*]}"
fi
export FORK_SANDBOX_MAIL_ROOT="$seq_root"

printf '\n== list ==\n'

list_out="$("$mail" list)"
contains "list shows the thread id" "$list_out" "$root_id"
contains "list shows the message count" "$list_out" "$(printf '%s\t5\t' "$root_id")"

printf '\n== dispatcher wiring ==\n'

dispatcher="$repo_dir/scripts/fork-sandbox"
if [[ -x "$dispatcher" ]]; then
    disp_list_out="$("$dispatcher" mail list 2>diag.txt)"
    check "fork-sandbox mail list routes to the mail script" "$list_out" "$disp_list_out"
    disp_help="$("$dispatcher" mail --help 2>&1)"
    contains "fork-sandbox mail --help reaches the mail script's header" "$disp_help" "fork-sandbox-mail.sh"
else
    no "dispatcher wiring" "scripts/fork-sandbox is not executable"
fi

printf '\n== --header: repeatable custom X- headers on send ==\n'

hdr_id="$("$mail" send --from @alice --to @bob --subject "With headers" --body - \
    --header 'X-AI-Persona: reviewer' --header 'X-AI-Model: test-model' <<< "see headers" 2>diag.txt)"
rc=$?
check "send with two --header exits 0" "0" "$rc"
raw_hdr="$("$mail" show "$hdr_id")"
contains "stored message carries the first --header" "$raw_hdr" "X-AI-Persona: reviewer"
contains "stored message carries the second --header" "$raw_hdr" "X-AI-Model: test-model"

printf '\n== --header: a newline in the value is refused ==\n'

msgs_before="$(find "$FORK_SANDBOX_MAIL_ROOT" -name '*.msg' | wc -l)"
out="$("$mail" send --from @alice --to @bob --subject "NL header" --body - \
    --header "$(printf 'X-AI-Persona: bad\nvalue')" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "send refuses a --header value containing a newline"
else
    no "send refuses a --header value containing a newline" "it succeeded"
fi
check "the refused send wrote no new message" "$msgs_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT" -name '*.msg' | wc -l)"

printf '\n== --header: a non-X header name is refused ==\n'

refuses "send refuses --header naming a core header (Subject)" \
    "$mail" send --from @alice --to @bob --subject "Bad header" --body - --header 'Subject: hijack' <<< "x"

printf '\n== --header: reserved header names are refused ==\n'

refuses "send refuses --header X-Hops (store-owned)" \
    "$mail" send --from @alice --to @bob --subject "Reserved" --body - --header 'X-Hops: 99' <<< "x"
refuses "send refuses --header X-Attachment (store-owned)" \
    "$mail" send --from @alice --to @bob --subject "Reserved" --body - --header 'X-Attachment: attachments/x' <<< "x"

printf '\n== --header: same validation applies on reply ==\n'

reply_hdr_id="$("$mail" reply --from @bob --reply-to "$hdr_id" --body - \
    --header 'X-AI-Persona: reviewer' <<< "reply with header" 2>diag.txt)"
rc=$?
check "reply with --header exits 0" "0" "$rc"
contains "reply's stored message carries --header" "$("$mail" show "$reply_hdr_id")" "X-AI-Persona: reviewer"

refuses "reply refuses --header naming a core header (Subject)" \
    "$mail" reply --from @bob --reply-to "$hdr_id" --body - --header 'Subject: hijack' <<< "x"
refuses "reply refuses --header X-Hops (store-owned)" \
    "$mail" reply --from @bob --reply-to "$hdr_id" --body - --header 'X-Hops: 99' <<< "x"
refuses "reply refuses a --header value containing a newline" \
    "$mail" reply --from @bob --reply-to "$hdr_id" --body - --header "$(printf 'X-AI-Persona: bad\nvalue')" <<< "x"

printf '\n== grant: per-thread k8s grants (real check-grant, no stub) ==\n'
# These use the REAL fork-sandbox-k8s.sh check-grant, with an empty temp
# config dir, so no k8s.env leaks in from a real ~/.config/fork-sandbox --
# this is what proves the "one grant parser" property, not a stub.

new_root FORK_SANDBOX_MAIL_ROOT; export FORK_SANDBOX_MAIL_ROOT
new_root FORK_SANDBOX_CONFIG_DIR; export FORK_SANDBOX_CONFIG_DIR
k8s_sh="$repo_dir/scripts/fork-sandbox-k8s.sh"

grant_tid="$("$mail" send --from @alice --to @bob --subject "Grant thread" --body - <<< "hi" 2>diag.txt)"

cg_ctx_dir_grant="/var/tmp/claude-scratch/forks/mail-grant-test.$$"
mkdir -p "$cg_ctx_dir_grant"; tmpdirs+=("$cg_ctx_dir_grant")

expected_grant="$("$k8s_sh" check-grant --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80)"
"$mail" grant "$grant_tid" --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80
rc=$?
check "grant happy path exits 0" "0" "$rc"
grant_file="$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants/$grant_tid.env"
check "grant file exists" "1" "$([[ -f "$grant_file" ]] && echo 1 || echo 0)"
check "grant file content matches check-grant's own output exactly" "$expected_grant" "$(cat -- "$grant_file")"

mtime1="$(stat -c %Y -- "$grant_file")"
sleep 1
"$mail" grant "$grant_tid" --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80
mtime2="$(stat -c %Y -- "$grant_file")"
check "writing the same grant values again leaves mtime unchanged" "$mtime1" "$mtime2"

"$mail" grant "$grant_tid" --allow-namespace preview-pr-7:80 --reach-probe svc.preview-pr-7:80
rc=$?
check "writing different grant values exits 0" "0" "$rc"
contains "different grant values replace the file's content" "$(cat -- "$grant_file")" "ALLOW_NAMESPACE=preview-pr-7:80"

"$mail" grant "$grant_tid" --clear
rc=$?
check "--clear exits 0" "0" "$rc"
check "--clear removes the grant file" "0" "$([[ -f "$grant_file" ]] && echo 1 || echo 0)"
"$mail" grant "$grant_tid" --clear
rc=$?
check "--clear exits 0 a second time with nothing to clear" "0" "$rc"

check "--show with no grant prints nothing" "" "$("$mail" grant "$grant_tid" --show)"
show_json_empty="$("$mail" grant "$grant_tid" --show --json)"
check "--show --json with no grant prints null" "null" "$show_json_empty"

"$mail" grant "$grant_tid" --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 --context-ro "$cg_ctx_dir_grant"
expected_grant_ctx="$("$k8s_sh" check-grant --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 --context-ro "$cg_ctx_dir_grant")"
check "--show with a grant prints the grant file content" "$expected_grant_ctx" "$("$mail" grant "$grant_tid" --show)"

show_json="$("$mail" grant "$grant_tid" --show --json)"
contains "--show --json names the thread" "$show_json" "\"thread\": \"$grant_tid\""
contains "--show --json carries the namespace value" "$show_json" "preview-pr-7"
contains "--show --json carries the probe value" "$show_json" "svc.preview-pr-7:80"
"$mail" grant "$grant_tid" --clear

refuses "grant on an unknown thread exits 1" "$mail" grant "not-a-real-thread-id" --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80

# A thread id is only ever mail_new_uuid output, never caller-supplied --
# but a hand-placed (not `send`-generated) root message could carry any
# byte string as its Message-ID/Thread-ID, so a caller passing that string
# to `grant` must not have it built straight into a path. Craft such a
# root directly (bypassing `send`, the only path that would normally
# create one) and confirm the traversal id is refused by shape before any
# path outside the grants dir is touched.
traversal_thread_dir="$FORK_SANDBOX_MAIL_ROOT/threads/traversal-root"
mkdir -p "$traversal_thread_dir"
cat > "$traversal_thread_dir/001-traversal.msg" <<'EOF'
Message-ID: ../../evil
Thread-ID: ../../evil
Date: Mon, 01 Jan 2024 00:00:00 +0000
From: @alice
To: @bob
Subject: traversal

hi
EOF
victim_file="$FORK_SANDBOX_MAIL_ROOT/evil.env"
: > "$victim_file"
out="$("$mail" grant '../../evil' --clear 2>&1)"
rc=$?
check "grant with a path-traversal-shaped thread id exits 1" "1" "$rc"
check "the path-traversal id is refused before deleting anything outside the grants dir" "1" \
    "$([[ -f "$victim_file" ]] && echo 1 || echo 0)"
rm -f -- "$victim_file"
rm -rf -- "$traversal_thread_dir"

grant_before="$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"
out="$("$mail" grant "$grant_tid" --reach-probe svc.preview-pr-7:80 2>&1)"
rc=$?
check "a refused grant value (probe without ns) exits 2" "2" "$rc"
check "a refused grant value writes no file" "$grant_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"

printf '\n== send: grant flags ==\n'

send_out="$("$mail" send --from @alice --to @bob --subject "Send with grant" --body - \
    --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 <<< "hi" 2>diag.txt)"
rc=$?
check "send with valid grant flags exits 0" "0" "$rc"
send_grant_file="$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants/$send_out.env"
check "send with valid grant flags writes a grant file for the printed uuid" "1" \
    "$([[ -f "$send_grant_file" ]] && echo 1 || echo 0)"
check "the grant file's content is right" "$expected_grant" "$(cat -- "$send_grant_file")"

threads_before="$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -maxdepth 1 -type d | wc -l)"
grants_before="$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"
out="$("$mail" send --from @alice --to @bob --subject "Send with bad grant" --body - \
    --reach-probe svc.preview-pr-7:80 <<< "hi" 2>&1)"
rc=$?
check "send with a refused grant value exits 2" "2" "$rc"
check "send with a refused grant value creates no new thread dir" "$threads_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/threads" -maxdepth 1 -type d | wc -l)"
check "send with a refused grant value writes no grant file" "$grants_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"

grants_before="$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"
out="$("$mail" send --from @alice --to @bob --subject "Send with big attach" --body - \
    --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 \
    --attach "$big" <<< "x" 2>&1)"
rc=$?
if (( rc != 0 )); then
    ok "send with a valid grant but a failing attachment fails"
else
    no "send with a valid grant but a failing attachment fails" "it succeeded"
fi
check "no orphaned grant file is left behind" "$grants_before" \
    "$(find "$FORK_SANDBOX_MAIL_ROOT/.postmaster/grants" -name '*.env' 2>/dev/null | wc -l)"

printf '\n== reply: grant flags are refused ==\n'

out="$("$mail" reply --from @bob --reply-to "$grant_tid" --body - \
    --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 <<< "x" 2>&1)"
rc=$?
check "reply with a grant flag exits 1" "1" "$rc"
contains "reply's refusal names send as the way to set a grant" "$out" "grant flags apply to a new thread only"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
