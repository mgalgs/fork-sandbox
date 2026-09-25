#!/usr/bin/env bash
# Tests for lane-jump.sh's join logic (lane registry x pane map x live tmux
# panes), driven against fixture dirs and a stub tmux -- no real tmux server
# needed.
#
# Run: tests/lane-jump-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCRIPT="$repo_root/scripts/lane-jump.sh"

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/       /' "$out"; fail=1; }

out="$tmpdir/out"
lanes_dir="$tmpdir/lanes"
panes_dir="$tmpdir/panes"
tmux_panes="$tmpdir/tmux-panes.tsv"
tmux_calls="$tmpdir/tmux-calls"
fake_tmux="$tmpdir/fake-tmux"

mkdir -p "$lanes_dir" "$panes_dir"
: > "$tmux_calls"

# A stand-in for the tmux binary: "list-panes -a -F ..." replays a canned
# pane table (the -F format string is fixed by the caller, so the fixture
# just ignores it); "switch-client -t TARGET" logs the target instead of
# touching a real client.
cat > "$fake_tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list-panes)
        cat "$FAKE_TMUX_PANES"
        ;;
    switch-client)
        shift
        target=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -t) target="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s\n' "$target" >> "$FAKE_TMUX_CALLS"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$fake_tmux"

export LANE_JUMP_LANES_DIR="$lanes_dir"
export LANE_JUMP_PANES_DIR="$panes_dir"
export LANE_JUMP_TMUX="$fake_tmux"
export FAKE_TMUX_PANES="$tmux_panes"
export FAKE_TMUX_CALLS="$tmux_calls"

transcript_for() { # transcript_for <session-id> -> fake transcript path
    echo "$tmpdir/transcripts/$1.jsonl"
}

register_lane() { # register_lane <session-id> <lane>
    printf '%s\n' "$2" > "$lanes_dir/$1"
}

map_pane() { # map_pane <pane-id> <session-id>
    local key
    key=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')
    mkdir -p "$panes_dir"
    printf '%s\n' "$(transcript_for "$2")" > "$panes_dir/$key"
}

# --- fixture: a live pane, a dead pane's map file, a stale lane file, two
#     panes sharing a lane, and a pane whose session never registered ------

register_lane s1 rag
map_pane %1 s1

register_lane s2 dead-lane
map_pane %2 s2                       # %2 is NOT in the live pane list below

register_lane s3 stale                # no pane maps to s3 at all

register_lane s4 dup
map_pane %3 s4
register_lane s5 dup
map_pane %4 s5

map_pane %5 s6                        # s6 never registered a lane

register_lane s7 noname
map_pane %6 s7                        # %6 has an empty window_name field

# Live pane list (pane_id, session, window_index, pane_index, window_name,
# cwd), \x01-delimited like the real tmux -F output the script requests --
# tab would be collapsed by `read`'s IFS-whitespace handling and swallow
# %6's empty window_name field.
SEP=$'\x01'
printf '%s\n' \
    "%1${SEP}work${SEP}0${SEP}0${SEP}editor${SEP}$HOME/proj" \
    "%3${SEP}work${SEP}1${SEP}0${SEP}agents${SEP}$HOME/a" \
    "%4${SEP}work${SEP}2${SEP}0${SEP}agents${SEP}$HOME/b" \
    "%5${SEP}work${SEP}3${SEP}0${SEP}misc${SEP}$HOME/misc" \
    "%6${SEP}work${SEP}4${SEP}0${SEP}${SEP}$HOME/noname" \
    > "$tmux_panes"

rows="$("$SCRIPT" --list 2>"$out")"
rc=$?

if [[ "$rc" == 0 ]]; then ok "--list exits 0 with live rows"; else bad "--list exit code ($rc)"; fi

if grep -qF $'@rag\twork:0.0\teditor\t~/proj' <<<"$rows"; then
    ok "live registered pane appears with expected fields"
else
    { echo "$rows"; cat "$out"; } > "$out.tmp"; mv "$out.tmp" "$out"
    bad "live registered pane missing/wrong"
fi

if grep -qF $'@noname\twork:4.0\t\t~/noname' <<<"$rows"; then
    ok "pane with an empty window_name keeps its cwd in the right column"
else
    { echo "$rows"; cat "$out"; } > "$out.tmp"; mv "$out.tmp" "$out"
    bad "empty window_name field was collapsed into cwd"
fi

if grep -q '@dead-lane' <<<"$rows"; then
    { echo "$rows"; } > "$out"; bad "dead pane's map file was not ignored"
else
    ok "dead pane's map file ignored"
fi

if grep -q '@stale' <<<"$rows"; then
    { echo "$rows"; } > "$out"; bad "stale lane file with no pane was not ignored"
else
    ok "stale lane file with no pane ignored"
fi

dup_count=$(grep -c '^@dup' <<<"$rows")
if [[ "$dup_count" == 2 ]]; then
    ok "two sessions on one lane both appear"
else
    { echo "$rows"; } > "$out"; bad "expected 2 @dup rows, got $dup_count"
fi

if grep -qF '%5' <<<"$rows" || grep -q 'misc' <<<"$rows"; then
    { echo "$rows"; } > "$out"; bad "pane whose session is unregistered was not ignored"
else
    ok "pane whose session is unregistered ignored"
fi

# --- exactly one match on a lane name jumps straight there, no fzf --------

: > "$tmux_calls"
export TMUX=fake-client-marker
if "$SCRIPT" rag > "$out" 2>&1; then
    ok "single-match lane arg exits 0"
else
    bad "single-match lane arg failed"
fi
if [[ "$(cat "$tmux_calls")" == "%1" ]]; then
    ok "single-match lane jumps straight to the right pane, no fzf"
else
    { echo "calls: $(cat "$tmux_calls")"; } > "$out"
    bad "single-match lane did not switch to the expected target"
fi

# Leading '@' is accepted too.
: > "$tmux_calls"
if "$SCRIPT" @rag > "$out" 2>&1 && [[ "$(cat "$tmux_calls")" == "%1" ]]; then
    ok "leading @ on the lane argument is accepted"
else
    bad "leading @ on the lane argument mishandled"
fi

# --- a lane with no live pane is a clear, non-zero error -------------------

if "$SCRIPT" no-such-lane > "$out" 2>&1; then
    bad "unknown lane should have failed"
else
    if grep -qi 'no-such-lane' "$out"; then
        ok "unknown lane names itself in the error"
    else
        bad "unknown lane error did not name the lane"
    fi
fi

# --- empty result set is a clear, non-zero error ---------------------------

: > "$tmux_panes"
if "$SCRIPT" --list > "$out" 2>&1; then
    bad "--list with no live lane panes should exit non-zero"
else
    if grep -qi 'no live lane' "$out"; then
        ok "--list with no live lane panes reports it clearly"
    else
        bad "--list empty-result message unclear"
    fi
fi

# --- not inside tmux is a clear, non-zero error (restore a live pane) -----

printf '%s\n' "%1${SEP}work${SEP}0${SEP}0${SEP}editor${SEP}$HOME/proj" > "$tmux_panes"
unset TMUX
if "$SCRIPT" > "$out" 2>&1; then
    bad "running outside tmux should have failed"
else
    if grep -qi 'tmux' "$out"; then
        ok "running outside tmux reports it clearly"
    else
        bad "outside-tmux error message unclear"
    fi
fi

echo
[[ "$fail" == 0 ]] && echo "all tests passed" || echo "some tests FAILED"
exit "$fail"
