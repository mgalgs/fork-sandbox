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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
