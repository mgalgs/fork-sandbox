#!/usr/bin/env bash
# lane-complete-list-lanes-test.sh -- Exercise mods/lane-complete/bin/list-lanes.sh,
# the lane list the lane-complete mod refreshes in the background.
#
# No real lane-mail root, config dir or registry. The script is copied beside
# a scratch copy of the two lane-mail files it reads (mods/lane-complete/bin
# next to scripts/), with the fixed root line in lane-mail-lib.sh pointed at
# a temp dir and the registry directory name in lane-mail.sh made unique; the
# scripts themselves gain no override. The registry lives under the user's
# /tmp/claude-<uid>, so the test removes its own directory on exit.
#
# Usage: tests/lane-complete-list-lanes-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}

scratch="$(mktemp -d)"
reg_name="lane-complete-test-$$"
reg_dir="/tmp/claude-$(id -u)/$reg_name"
trap 'rm -rf -- "$scratch" "$reg_dir"' EXIT

mkdir -p "$scratch/scripts" "$scratch/mods/lane-complete/bin" \
    "$scratch/root/agents" "$scratch/config" "$reg_dir"
cp "$repo_dir/mods/lane-complete/bin/list-lanes.sh" "$scratch/mods/lane-complete/bin/"
sed "s|^LANE_MAIL_ROOT=.*|LANE_MAIL_ROOT=$scratch/root|" \
    "$repo_dir/scripts/lane-mail-lib.sh" > "$scratch/scripts/lane-mail-lib.sh"
sed "s|^LANES_DIR=.*|LANES_DIR=\"/tmp/claude-\$(id -u)/$reg_name\"|" \
    "$repo_dir/scripts/lane-mail.sh" > "$scratch/scripts/lane-mail.sh"
if grep -q "^LANES_DIR=\"/tmp/claude-\\\$(id -u)/$reg_name\"\$" "$scratch/scripts/lane-mail.sh"; then
    ok "scratch lane-mail.sh carries the test registry dir"
else
    no "scratch lane-mail.sh carries the test registry dir"
fi
printf 'LANE_MAIL_PEER_NAME=selfhost\n' > "$scratch/config/lane-mail.env"

list() {
    FORK_SANDBOX_CONFIG_DIR="$scratch/config" "$scratch/mods/lane-complete/bin/list-lanes.sh" "$@"
}
tab=$'\t'

check "nothing known prints nothing" "" "$(list)"

# sess-1 is owned by this shell (alive); sess-2 is a legacy one-line file
# (no owner: not live) seen more recently, so alpha is live and its last
# seen is sess-2's.
read -r stat < "/proc/$$/stat"; stat="${stat##*) }"
# shellcheck disable=SC2086  # split on purpose
set -- $stat
printf 'alpha\nowner_pid=%s\nowner_start=%s\n' "$$" "${20}" > "$reg_dir/sess-1"
printf 'alpha\n' > "$reg_dir/sess-2"
touch -d '2026-01-02 03:04' "$reg_dir/sess-1"
touch -d '2026-01-05 06:07' "$reg_dir/sess-2"
seen='2026-01-05 06:07'
printf 'Bad Lane\n' > "$reg_dir/sess-3"
mkdir -p "$scratch/root/agents/alpha" "$scratch/root/agents/beta" "$scratch/root/agents/-bad"
printf '# peers\nhostone ssh.example.test\nselfhost ssh.example.test\nBAD host\n' \
    > "$scratch/config/lane-mail-peers"

want="live${tab}alpha${tab}${tab}$seen
mailbox${tab}beta${tab}${tab}
peer${tab}hostone${tab}${tab}"
check "live first, then mailbox-only, then peers; deduped; invalid and self dropped" \
    "$want" "$(list)"

# Remote lanes: the From: of a stored message, header block only.
msg() {  # msg <thread> <file>; the message on stdin
    mkdir -p "$scratch/root/threads/$1"
    cat > "$scratch/root/threads/$1/$2.msg"
}
msg t1 001-a <<'EOF'
Message-ID: m1
From: @builder:hostb
To: @alpha
Subject: hello

Plain body.
EOF
msg t1 002-b <<'EOF'
Message-ID: m2
From: @builder:hostb
To: @alpha
Subject: again

Duplicate sender.
EOF
msg t2 001-c <<'EOF'
Message-ID: m3
From: @alpha
To: @onlyto:farhost, @mistyped:otherhost
Cc: @onlycc:ccghost
Subject: nobody answers

From: @inbody:bodyhost
EOF
msg t3 001-d <<'EOF'
Message-ID: m4
From: @ownlane:selfhost
To: @alpha
Subject: from this host

EOF
msg t4 001-e <<'EOF'
Message-ID: m5
From: @Bad Lane:hostx
To: @alpha
Subject: bad names

EOF
msg t4 002-f <<'EOF'
Message-ID: m6
From: @good-lane:-badhost
To: @alpha
Subject: bad host

EOF
msg t5 001-g <<'EOF'
Message-ID: m7
From: @second:hosttwo
Subject: another sender

EOF
want="live${tab}alpha${tab}${tab}$seen
mailbox${tab}beta${tab}${tab}
remote${tab}builder:hostb${tab}${tab}
remote${tab}second:hosttwo${tab}${tab}
peer${tab}hostone${tab}${tab}"
check "remote lanes: From: headers only; own host, dups, malformed, To, Cc, body excluded" \
    "$want" "$(list)"
printf 'From: @notamsg:hostz\n' > "$scratch/root/threads/t5/note.txt"
check "non-message files in the store are ignored" "$want" "$(list)"
rm -rf "$scratch/root/threads"
check "no thread store: only the original sources" "live${tab}alpha${tab}${tab}$seen
mailbox${tab}beta${tab}${tab}
peer${tab}hostone${tab}${tab}" "$(list)"

check "--help prints the header" "list-lanes.sh -- Print the lane-mail lanes the lane-complete mod can offer" \
    "$(list --help | head -1)"
list --bogus >/dev/null 2>&1; check "unknown argument exits 1" "1" "$?"

# No lane-mail scripts beside the mod and none on PATH: fail with a reason.
mkdir -p "$scratch/lone/mods/lane-complete/bin"
cp "$repo_dir/mods/lane-complete/bin/list-lanes.sh" "$scratch/lone/mods/lane-complete/bin/"
err="$(PATH=/usr/bin:/bin "$scratch/lone/mods/lane-complete/bin/list-lanes.sh" 2>&1 >/dev/null)"
check "missing scripts exits 1" "1" "$?"
case "$err" in *"lane-mail scripts not found"*) ok "missing scripts says so" ;; *) no "missing scripts says so" "$err" ;; esac

# Descriptions: the third column, from <root>/agents/<lane>/about.
printf 'the alpha widget repo\n' > "$scratch/root/agents/alpha/about"
printf 'beta tab\there\r\nsecond line\n' > "$scratch/root/agents/beta/about"
printf 'orphan\n' > "$scratch/root/agents/-bad/about"
want="live${tab}alpha${tab}the alpha widget repo${tab}$seen
mailbox${tab}beta${tab}beta tab here${tab}
peer${tab}hostone${tab}${tab}"
check "a described lane carries its first line as the third column; tabs flattened" \
    "$want" "$(list)"
check "the first two fields are unchanged by descriptions" \
    "live${tab}alpha
mailbox${tab}beta
peer${tab}hostone" "$(list | cut -f1,2)"
mkdir -p "$scratch/root/agents/alpha" "$scratch/root/agents/gamma"
printf 'gamma\n' > "$reg_dir/sess-4"
check "a live lane's description survives its session being replaced" \
    "the alpha widget repo" "$(rm -f "$reg_dir/sess-1" "$reg_dir/sess-2"; printf 'alpha\n' > "$reg_dir/sess-9"; list | awk -F'\t' '$2 == "alpha" { print $3 }')"
touch -d '2026-02-03 04:05' "$reg_dir/sess-4"
check "an undescribed lane has an empty third column" \
    "stale${tab}gamma${tab}${tab}2026-02-03 04:05" "$(list | grep -P '\tgamma\t')"
check "a lane whose only registration has no owner is stale, described" \
    "stale${tab}alpha${tab}the alpha widget repo" "$(list | grep -P '\talpha\t' | cut -f1-3)"

# Liveness: a registration is live only while its recorded process exists
# with the recorded start time.
rm -f "$reg_dir"/*
sleep 30 & dead_pid=$!
read -r stat < "/proc/$dead_pid/stat"; stat="${stat##*) }"
# shellcheck disable=SC2086
set -- $stat
dead_start="${20}"
printf 'delta\nowner_pid=%s\nowner_start=%s\n' "$dead_pid" "$dead_start" > "$reg_dir/sess-d"
check "a registration whose process runs is live" live "$(list | awk -F'\t' '$2 == "delta" { print $1 }')"
printf 'delta\nowner_pid=%s\nowner_start=%s\n' "$dead_pid" "$(( dead_start + 1 ))" > "$reg_dir/sess-d"
check "the same pid with another start time (a reused pid) is stale" \
    stale "$(list | awk -F'\t' '$2 == "delta" { print $1 }')"
printf 'delta\nowner_pid=%s\nowner_start=%s\n' "$dead_pid" "$dead_start" > "$reg_dir/sess-d"
kill "$dead_pid"; wait "$dead_pid" 2>/dev/null
touch -d '2026-03-04 05:06' "$reg_dir/sess-d"
check "once that process is gone the lane is stale, with its last seen" \
    "stale${tab}delta${tab}${tab}2026-03-04 05:06" "$(list | grep -P '\tdelta\t')"
mkdir -p "$scratch/root/agents/delta" "$scratch/root/agents/epsilon"
check "stale is listed once, ahead of mailbox-only lanes" \
    "stale${tab}delta
mailbox${tab}alpha
mailbox${tab}beta
mailbox${tab}epsilon
mailbox${tab}gamma" "$(list | grep -v '^peer' | cut -f1,2)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
