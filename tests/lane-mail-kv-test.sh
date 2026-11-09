#!/usr/bin/env bash
# lane-mail-kv-test.sh -- Exercise `lane-mail.sh kv`: the key/value store
# under the lane-mail root.
#
# The root is a constant in lane-mail-lib.sh, so this runs a scratch copy of
# the scripts with that line pointed at a temp dir, the way
# lane-mail-test.sh does. Nothing touches the real store.
#
# Usage: tests/lane-mail-kv-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {  # check <name> <command...>: ok when the command succeeds
    local name="$1"; shift
    if "$@"; then ok "$name"; else no "$name"; fi
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
cp -r "$repo_dir/scripts" "$scratch/scripts"
mkdir -p "$scratch/root"
sed -i "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$scratch/root|" "$scratch/scripts/lane-mail-lib.sh"
lm="$scratch/scripts/lane-mail.sh"
store="$scratch/root/kv"

# Runs `lane-mail.sh kv "$@"`; sets out (stdout, byte-exact via a file),
# err and rc.
kv() {
    rc=0
    "$lm" kv "$@" > "$scratch/out" 2> "$scratch/err" || rc=$?
    err="$(cat "$scratch/err")"
}
out_is() { cmp -s "$scratch/out" <(printf '%s' "$1"); }
out_text() { cat "$scratch/out"; }

printf '== set / get ==\n'

check "the store does not exist before the first write" test ! -e "$store"
kv set greeting hello
check "set exits 0" test "$rc" = 0
v1="$(out_text)"
check "set prints a version" test -n "$v1"
check "the store is created on first write, under the mail root" test -d "$store"
kv get greeting
check "get prints the value with no added newline" out_is hello

val=$'line one\n\tindented\nlast line\n'
kv set multi "$val"
kv get multi
if (( rc == 0 )) && out_is "$val"; then
    ok "a value with a tab, embedded newlines and a trailing newline round-trips"
else
    no "a value with a tab, embedded newlines and a trailing newline round-trips" "rc=$rc"
fi

kv set empty ""
kv get empty
if (( rc == 0 )) && [[ ! -s "$scratch/out" ]]; then ok "an empty value round-trips"; else no "an empty value round-trips" "rc=$rc"; fi

printf 'from stdin\n\n' | "$lm" kv set piped - >/dev/null
kv get piped
check "set <key> - reads the value from stdin, byte-exact" out_is $'from stdin\n\n'

kv get nosuchkey
if (( rc == 1 )) && [[ ! -s "$scratch/out" ]]; then
    ok "get of an absent key exits 1 and prints nothing"
else
    no "get of an absent key exits 1 and prints nothing" "rc=$rc"
fi

printf '== get --json ==\n'

kv get --json multi
json_ok="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["key"] == "multi" and d["value"] == sys.argv[2] and set(d) == {"key", "value", "version"})
' "$scratch/out" "$val" 2>&1)"
check "get --json returns key and the stored value" test "$json_ok" = True

kv set greeting hello
v2="$(out_text)"
kv get --json greeting
jv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$scratch/out")"
check "get --json returns the version set printed" test "$jv" = "$v2"
check "a second set changes the version" test "$v1" != "$v2"
kv get --json nosuchkey
check "get --json of an absent key exits 1" test "$rc" = 1

printf '== del ==\n'

kv del greeting
check "del exits 0" test "$rc" = 0
kv get greeting
check "a deleted key is absent" test "$rc" = 1
kv del greeting
check "del of an absent key exits 1" test "$rc" = 1
kv set greeting hello
v3="$(out_text)"
if [[ "$v3" != "$v1" && "$v3" != "$v2" ]]; then
    ok "delete-then-recreate yields a version different from every earlier one"
else
    no "delete-then-recreate yields a version different from every earlier one" "$v1 $v2 $v3"
fi

printf '== keys and values ==\n'

kv set 'pr:org/repo#2778' '@lane:host'
kv get 'pr:org/repo#2778'
check "a key with ':', '/' and '#' is accepted" out_is '@lane:host'
kv set 'owner:@lane:host' x
check "a key like owner:@lane:host is accepted" test "$rc" = 0

key200="k$(printf 'a%.0s' {1..199})"
kv set "$key200" x
check "a 200-character key is accepted" test "$rc" = 0
kv set "${key200}a" x
check "a 201-character key is refused with 2" test "$rc" = 2
for bad in '../x' '' 'has space' '.hidden' '-dash'; do
    kv set "$bad" x
    check "key '$bad' is refused with 2" test "$rc" = 2
done
check "a refused key is named on stderr" test -n "$err"
kv get '../x'
check "get with a bad key is refused with 2" test "$rc" = 2

# a/../b passes the key regex; it must still name one file inside the store.
before="$(find "$scratch" -path "$store" -prune -o -print | sort)"
kv set 'a/../b' traversal
check "a/../b is accepted as a key" test "$rc" = 0
after="$(find "$scratch" -path "$store" -prune -o -print | sort)"
check "a/../b writes no file outside the store" test "$before" = "$after"
check "a/../b is one plain file directly in the store" test -f "$store/a%..%b"
kv get 'b'
check "a/../b does not alias the key b" test "$rc" = 1
kv get 'a/../b'
check "a/../b reads back" out_is traversal

printf 'a\0b' | "$lm" kv set nul - >/dev/null 2>&1; rc=$?
check "a value with a NUL is refused with 2" test "$rc" = 2
kv get nul
check "a refused NUL value is not stored" test "$rc" = 1

head -c 65536 /dev/zero | tr '\0' x > "$scratch/max"
"$lm" kv set big - < "$scratch/max" >/dev/null 2>&1; rc=$?
check "a 64 KiB value is accepted" test "$rc" = 0
printf 'y' >> "$scratch/max"
"$lm" kv set big - < "$scratch/max" >/dev/null 2>&1; rc=$?
check "a value over 64 KiB is refused with 2" test "$rc" = 2
kv set big2 "$(cat "$scratch/max")"
check "an argument value over 64 KiB is refused with 2" test "$rc" = 2
kv get big2
check "a refused oversize value is not stored" test "$rc" = 1

kv set onlykey
check "set without a value is a usage error" test "$rc" = 2
kv frob x
check "an unknown kv verb is a usage error" test "$rc" = 2
kv set k v --bogus
check "an unknown option is a usage error" test "$rc" = 2
kv set dashval -- --x
kv get dashval
check "-- lets a value start with --" out_is --x

leftovers="$(find "$store" -name '.tmp-*' | wc -l)"
check "no temp files are left in the store" test "$leftovers" = 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
