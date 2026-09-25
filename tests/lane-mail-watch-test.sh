#!/usr/bin/env bash
# lane-mail-watch-test.sh -- Exercise lane-mail-watch.sh's --wait mode: the
# one-shot blocking wake, alongside its unchanged --once streaming behavior.
#
# lane-mail.sh's mail root is a fixed constant on purpose (see its own
# header), so this never adds a root override. Instead a stub lane-mail.sh
# sits first on PATH: it serves TSV inbox lines from a file this test
# controls, and can be made to fail on demand via a countdown file, so the
# consecutive-failure behavior can be driven deterministically.
#
# Usage: tests/lane-mail-watch-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
watcher="$repo_dir/scripts/lane-mail-watch.sh"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

stub_bin="$scratch/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/lane-mail.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub: serves TSV inbox lines from $INBOX_FILE. $FAIL_COUNTDOWN, if
# set to a positive integer, is decremented on every call and makes that
# call fail (nonzero exit, message on stderr) until it reaches zero.
set -uo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
    inbox)
        countdown_file="${FAIL_COUNTDOWN_FILE:-}"
        if [[ -n "$countdown_file" && -f "$countdown_file" ]]; then
            n="$(cat "$countdown_file")"
            if (( n > 0 )); then
                echo $(( n - 1 )) > "$countdown_file"
                echo "stub: simulated inbox failure" >&2
                exit 1
            fi
        fi
        cat "${INBOX_FILE:?INBOX_FILE not set}" 2>/dev/null
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$stub_bin/lane-mail.sh"

# New env per case, so a background case from an earlier test can't leak
# state into a later one.
new_env() {
    local dir="$1"
    mkdir -p "$dir"
    : >"$dir/inbox.tsv"
    : >"$dir/countdown"
}

run_wait() {
    # run_wait <dir> [extra watcher args...]
    local dir="$1"; shift
    PATH="$stub_bin:$PATH" INBOX_FILE="$dir/inbox.tsv" FAIL_COUNTDOWN_FILE="$dir/countdown" \
        timeout 10 "$watcher" testlane --interval 0.1 --wait "$@"
}

expect_line() {
    printf '[lane-mail] @testlane new: %s -- %s (id %s)\n' "$3" "$4" "$2"
}

echo "== immediate unread exits 0 with the lines =="
dir1="$scratch/case1"; new_env "$dir1"
printf 'm1\tt1\t0\t@sender\tSubject one\nm2\tt1\t1\t@sender\tSubject two\n' >"$dir1/inbox.tsv"
out1="$(run_wait "$dir1")"; rc1=$?
want1="$(expect_line x m1 @sender 'Subject one')"$'\n'"$(expect_line x m2 @sender 'Subject two')"
if (( rc1 == 0 )) && [[ "$out1" == "$want1" ]]; then
    ok "immediate unread: exits 0 with one line per message"
else
    no "immediate unread: exits 0 with one line per message" "rc=$rc1 out=$out1"
fi

echo "== an empty inbox that gets mail after ~0.5s exits 0 with it =="
dir2="$scratch/case2"; new_env "$dir2"
tmp_out2="$scratch/case2.out"
( run_wait "$dir2" >"$tmp_out2" 2>&1; echo $? >"$scratch/case2.rc" ) &
bg2=$!
sleep 0.5
printf 'm3\tt2\t0\t@other\tLate subject\n' >"$dir2/inbox.tsv"
wait "$bg2" 2>/dev/null
rc2="$(cat "$scratch/case2.rc")"
out2="$(cat "$tmp_out2")"
want2="$(expect_line x m3 @other 'Late subject')"
if (( rc2 == 0 )) && [[ "$out2" == "$want2" ]]; then
    ok "mail arriving later still wakes --wait and exits 0"
else
    no "mail arriving later still wakes --wait and exits 0" "rc=$rc2 out=$out2"
fi

echo "== 5 consecutive failures exit 1 =="
dir3="$scratch/case3"; new_env "$dir3"
echo 100 >"$dir3/countdown"
out3="$(run_wait "$dir3" 2>&1)"; rc3=$?
if (( rc3 == 1 )) && [[ "$out3" == *"inbox scan failed"* ]]; then
    ok "5 consecutive failures: exits 1 with the error line"
else
    no "5 consecutive failures: exits 1 with the error line" "rc=$rc3 out=$out3"
fi

echo "== 3 failures then mail exits 0 =="
dir4="$scratch/case4"; new_env "$dir4"
echo 3 >"$dir4/countdown"
printf 'm4\tt3\t0\t@third\tRecovered\n' >"$dir4/inbox.tsv"
out4="$(run_wait "$dir4" 2>&1)"; rc4=$?
want4="$(expect_line x m4 @third Recovered)"
if (( rc4 == 0 )) && [[ "$out4" == "$want4" ]]; then
    ok "3 failures under the limit then mail: exits 0 with the lines"
else
    no "3 failures under the limit then mail: exits 0 with the lines" "rc=$rc4 out=$out4"
fi

echo "== --wait --once is refused =="
dir5="$scratch/case5"; new_env "$dir5"
out5="$(PATH="$stub_bin:$PATH" INBOX_FILE="$dir5/inbox.tsv" FAIL_COUNTDOWN_FILE="$dir5/countdown" \
    timeout 10 "$watcher" testlane --wait --once 2>&1)"; rc5=$?
if (( rc5 == 2 )); then
    ok "--wait --once exits 2"
else
    no "--wait --once exits 2" "rc=$rc5 out=$out5"
fi

echo "== a bad lane name exits 2 =="
dir6="$scratch/case6"; new_env "$dir6"
out6="$(PATH="$stub_bin:$PATH" INBOX_FILE="$dir6/inbox.tsv" FAIL_COUNTDOWN_FILE="$dir6/countdown" \
    timeout 10 "$watcher" "Not A Lane" --wait 2>&1)"; rc6=$?
if (( rc6 == 2 )); then
    ok "a bad lane name exits 2"
else
    no "a bad lane name exits 2" "rc=$rc6 out=$out6"
fi

echo "== --once streaming output is unchanged =="
dir7="$scratch/case7"; new_env "$dir7"
printf 'm5\tt4\t0\t@fourth\tStreamed\n' >"$dir7/inbox.tsv"
out7="$(PATH="$stub_bin:$PATH" INBOX_FILE="$dir7/inbox.tsv" FAIL_COUNTDOWN_FILE="$dir7/countdown" \
    timeout 10 "$watcher" testlane --once 2>&1)"; rc7=$?
want7="$(expect_line x m5 @fourth Streamed)"
if (( rc7 == 0 )) && [[ "$out7" == "$want7" ]]; then
    ok "--once streaming output is unchanged"
else
    no "--once streaming output is unchanged" "rc=$rc7 out=$out7"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
