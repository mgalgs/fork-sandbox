#!/usr/bin/env bash
# fork-sandbox-mail-inbox-equivalence-test.sh -- Pin inbox TSV and header quirks.
# Usage: tests/fork-sandbox-mail-inbox-equivalence-test.sh

set -euo pipefail
repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/scripts" "$work/root/threads" "$work/root/agents/iris"
cp "$repo_dir/scripts/fork-sandbox-mail.sh" "$repo_dir/scripts/fork-sandbox-mail-inbox.py" "$work/scripts/"
sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$work/root|" \
    "$repo_dir/scripts/lane-mail-lib.sh" > "$work/scripts/lane-mail-lib.sh"
mail="$work/scripts/fork-sandbox-mail.sh"
export FORK_SANDBOX_MAIL_ROOT="$work/root"
pass=0
fail=0
check() {
    local label="$1" expected="$2" actual="$3"
    if cmp -s "$expected" "$actual"; then
        printf '  ok    %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$label"
        diff -u "$expected" "$actual" || true
        fail=$((fail + 1))
    fi
}
message() {
    local file="$1" id="$2" to="$3" cc="$4" from="$5" subject="$6" broadcast="${7:-}"
    mkdir -p "$work/root/threads/${file%%/*}"
    {
        printf 'Message-ID: %s\nThread-ID: thread-%s\nFrom: %s\nTo: %s\nCc: %s\nSubject: %s\n' \
            "$id" "$id" "$from" "$to" "$cc" "$subject"
        [[ -z "$broadcast" ]] || printf 'X-Lane-Broadcast: %s\n' "$broadcast"
        printf '\nbody\n'
    } > "$work/root/threads/$file"
}

: > "$work/empty"
"$mail" inbox iris > "$work/actual"
check 'empty store' "$work/empty" "$work/actual"

message 'a/01.msg' one '@iris' '' '@oak' 'to'
message 'a/02.msg' two '@oak' '@iris' '@oak' 'cc'
message 'a/03.msg' three '@iris' '@iris' '@oak' 'both'
message 'a/04.msg' four '@oak' '@elm' '@oak' 'other'
message 'b/01.msg' five '@all' '' '@oak' 'broadcast to' '@iris, @elm'
message 'b/02.msg' six '@oak' '@all' '@oak' 'broadcast cc' '@iris'
message 'b/03.msg' seven '@all' '' '@oak' 'unlisted to' '@elm'
message 'b/04.msg' eight '@oak' '@all' '@oak' 'unlisted cc' '@elm'
message 'b/05.msg' nine '@all' '' '@oak:xhost' 'remote' '@iris'
message 'b/06.msg' sixteen '@all' '' '@oak' 'broadcast unspaced list' '@elm,@iris'
message 'b/07.msg' seventeen '@elm,@all' '@all' '@oak' 'broadcast unspaced to' '@iris'
message 'c/01.msg' ten '@oak' '' '@oak' 'no space'
sed -i 's/^To: @oak$/To:@iris/' "$work/root/threads/c/01.msg"
message 'c/02.msg' eleven '@iris' '' '@oak' 'first header'
sed -i '/^To: @iris$/a To: @elm' "$work/root/threads/c/02.msg"
message 'c/03.msg' twelve '@oak' '' '@oak' 'body header'
printf 'To: @iris\n' >> "$work/root/threads/c/03.msg"
message 'c/04.msg' thirteen '@iris' '' '@oak' 'seen'
message 'c/05.msg' fourteen '@irisa' '' '@oak' 'partial address'
printf 'thirteen\n' > "$work/root/agents/iris/seen"
message 'c/06.msg' fifteen '@iris' '' '@oak' 'missing id'
sed -i '/^Message-ID:/d' "$work/root/threads/c/06.msg"
message 'c/07.msg' eighteen '@elm,@iris' '@iris' '@oak' 'unspaced to with cc'

cat > "$work/expected" <<'EXPECTED'
one	thread-one	To	@oak	to
two	thread-two	Cc	@oak	cc
three	thread-three	To	@oak	both
five	thread-five	To	@oak	broadcast to
six	thread-six	Cc	@oak	broadcast cc
seventeen	thread-seventeen	Cc	@oak	broadcast unspaced to
eleven	thread-eleven	To	@oak	first header
	thread-fifteen	To	@oak	missing id
eighteen	thread-eighteen	Cc	@oak	unspaced to with cc
EXPECTED
# Convert the visible separators to literal tabs while keeping the final newline.
sed -i $'s/\\t/\t/g' "$work/expected"
"$mail" inbox iris > "$work/actual"
check 'recipient, broadcast and header equivalence' "$work/expected" "$work/actual"
sed -i '$d' "$work/expected"
sed -i '$d' "$work/expected"
printf 'thirteen\tthread-thirteen\tTo\t@oak\tseen\n\tthread-fifteen\tTo\t@oak\tmissing id\n' >> "$work/expected"
printf 'eighteen\tthread-eighteen\tCc\t@oak\tunspaced to with cc\n' >> "$work/expected"
"$mail" inbox iris --all > "$work/actual"
check '--all includes seen message' "$work/expected" "$work/actual"

printf '%s ok / %s fail\n' "$pass" "$fail"
((fail == 0))
