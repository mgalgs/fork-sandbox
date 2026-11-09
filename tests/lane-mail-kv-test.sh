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

printf '== conditional writes ==\n'

kv set cond one
cv1="$(out_text)"
kv set cond two --if-version "$cv1"
cv2="$(out_text)"
check "--if-version with the current version succeeds" test "$rc" = 0
kv get cond
check "--if-version wrote the new value" out_is two
kv set cond three --if-version "$cv1"
if (( rc == 3 )) && [[ "$err" == *"--if-version"* ]]; then
    ok "--if-version with a stale version fails with 3, naming the precondition"
else
    no "--if-version with a stale version fails with 3, naming the precondition" "rc=$rc: $err"
fi
kv get --json cond
jv="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["value"], d["version"])' "$scratch/out")"
check "a failed --if-version leaves value and version unchanged" test "$jv" = "two $cv2"
kv set nosuch x --if-version "$cv2"
check "--if-version on an absent key fails with 3" test "$rc" = 3
kv get nosuch
check "a failed --if-version on an absent key creates nothing" test "$rc" = 1

kv set fresh first --if-absent
check "--if-absent on a new key succeeds" test "$rc" = 0
kv set fresh second --if-absent
if (( rc == 3 )) && [[ "$err" == *"--if-absent"* ]]; then
    ok "--if-absent on an existing key fails with 3, naming the precondition"
else
    no "--if-absent on an existing key fails with 3, naming the precondition" "rc=$rc: $err"
fi
kv get fresh
check "a failed --if-absent leaves the value unchanged" out_is first
kv set fresh x --if-absent --if-version "$cv2"
check "--if-absent with --if-version is a usage error" test "$rc" = 2
kv set fresh x --if-version
check "--if-version without a value is a usage error" test "$rc" = 2

kv del cond --if-version "$cv1"
check "del --if-version with a stale version fails with 3" test "$rc" = 3
kv get cond
check "a failed del --if-version leaves the key" out_is two
kv del cond --if-version "$cv2"
check "del --if-version with the current version succeeds" test "$rc" = 0
kv del cond --if-version "$cv2"
check "del --if-version of an absent key exits 1" test "$rc" = 1

# Every writer holds the same version; exactly one may win.
kv set race start
rv="$(out_text)"
n=12
mkdir -p "$scratch/race"
# A start barrier: each writer blocks reading the fifo until it is opened
# and closed below, so all of them start at once rather than staggered by
# their launch, and their check-then-write windows overlap.
mkfifo "$scratch/race/go"
for (( i = 0; i < n; i++ )); do
    ( read -r _ < "$scratch/race/go"
      r=0; "$lm" kv set race "writer-$i" --if-version "$rv" > "$scratch/race/$i.out" 2>/dev/null || r=$?
      echo "$r" > "$scratch/race/$i.rc" ) &
done
sleep 0.5
: > "$scratch/race/go"
wait
wins=0 losses=0 winner=""
for (( i = 0; i < n; i++ )); do
    case "$(cat "$scratch/race/$i.rc")" in
        0) wins=$(( wins + 1 )); winner="$i" ;;
        3) losses=$(( losses + 1 )) ;;
    esac
done
if (( wins == 1 && losses == n - 1 )); then
    ok "$n concurrent --if-version writers: exactly one exits 0, the rest 3"
else
    no "$n concurrent --if-version writers: exactly one exits 0, the rest 3" "wins=$wins losses=$losses"
fi
kv get --json race
jv="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["value"], d["version"])' "$scratch/out")"
check "the stored value and version are the winner's" test "$jv" = "writer-$winner $(cat "$scratch/race/$winner.out" 2>/dev/null)"

leftovers="$(find "$store" -name '.tmp-*' | wc -l)"
check "no temp files are left in the store" test "$leftovers" = 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
