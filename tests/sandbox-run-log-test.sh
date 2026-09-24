#!/usr/bin/env bash
# sandbox-run-log-test.sh — Exercise sandbox-run-log.py's `network` field:
# record lifting it from summary.json and from a summary-missing run.env
# fallback, and read-time normalization of a historical harness="pi-local"
# row (from before harness and network were split) to harness="pi",
# network="sealed" -- without ever rewriting the log file on disk.
#
# Usage: tests/sandbox-run-log-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
runlog="$repo_dir/scripts/sandbox-run-log.py"

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
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "expected to find '$needle' in: $hay" ;;
    esac
}

not_contains() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$label" "did not expect to find '$needle' in: $hay" ;;
        *) ok "$label" ;;
    esac
}

tmp="$(mktemp -d)"
tmpdirs+=("$tmp")

log_home="$tmp/log-home"
mkdir -p "$log_home/.claude"
log_file="$log_home/.claude/sandbox-runs.jsonl"

record() {
    HOME="$log_home" python3 "$runlog" record --run-dir "$1"
}
query() {
    HOME="$log_home" python3 "$runlog" "$@"
}

mk_run_dir() {  # $1 = distinctive suffix
    mktemp -d "/var/tmp/claude-scratch/forks/claude-fork-sandbox.rlog-$1.XXXXXX"
}

quota_path() {  # $1 = run directory
    printf '%s/.claude/codex-quota/%s.jsonl' "$log_home" "$(basename "$1")"
}

record_field() {  # $1 = run id, $2 = field name
    python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    rec = json.loads(line)
    if rec.get("event") == "run_end" and rec.get("run_id") == sys.argv[2]:
        print(rec.get(sys.argv[3], ""))
        break
' "$log_file" "$1" "$2"
}

printf '== record: no Codex sessions is silent ==\n'
rd_no_sessions="$(mk_run_dir no-sessions)"
tmpdirs+=("$rd_no_sessions")
printf '0\n' > "$rd_no_sessions/exit-code"
record "$rd_no_sessions" >/dev/null 2>"$tmp/err"
check "a non-Codex run creates no quota directory" "no" \
    "$(test -d "$log_home/.claude/codex-quota" && echo yes || echo no)"
check "a non-Codex run creates no quota file" "no" \
    "$(test -e "$(quota_path "$rd_no_sessions")" && echo yes || echo no)"

printf '\n== record: Codex quota snapshots ==\n'
rd_one="$(mk_run_dir quota-one)"
tmpdirs+=("$rd_one")
mkdir -p "$rd_one/codex-sessions/2026/09/15"
one_first='{"timestamp":"2026-09-15T01:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.5}}}}'
one_middle='{"timestamp":"2026-09-15T01:01:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":3.75}}}}'
one_last='{"timestamp":"2026-09-15T01:02:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0}}}}'
printf '%s\n%s\n%s\n' "$one_first" "$one_middle" "$one_last" \
    > "$rd_one/codex-sessions/2026/09/15/rollout-one.jsonl"
record "$rd_one" >/dev/null 2>"$tmp/err"
printf '%s\n%s\n' "$one_first" "$one_last" > "$tmp/quota-one-expected"
check "one rollout contributes its first and last quota rows" "2" \
    "$(wc -l < "$(quota_path "$rd_one")" | tr -d ' ')"
check "archived quota rows retain their original bytes" "same" \
    "$(cmp -s "$tmp/quota-one-expected" "$(quota_path "$rd_one")" && echo same || echo different)"
check "the record reports the archived quota row count" "2" \
    "$(record_field "$(basename "$rd_one")" codex_quota_rows)"

rd_two="$(mk_run_dir quota-two)"
tmpdirs+=("$rd_two")
mkdir -p "$rd_two/codex-sessions/2026/09/15"
two_a_first='{"timestamp":"2026-09-15T02:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":20.0}}}}'
two_a_last='{"timestamp":"2026-09-15T04:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":40.0}}}}'
two_b_first='{"timestamp":"2026-09-15T01:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":10.0}}}}'
two_b_last='{"timestamp":"2026-09-15T05:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":50.0}}}}'
printf '%s\n%s\n' "$two_a_first" "$two_a_last" \
    > "$rd_two/codex-sessions/2026/09/15/rollout-a.jsonl"
printf '%s\n%s\n' "$two_b_first" "$two_b_last" \
    > "$rd_two/codex-sessions/2026/09/15/rollout-b.jsonl"
record "$rd_two" >/dev/null 2>"$tmp/err"
printf '%s\n%s\n%s\n%s\n' "$two_b_first" "$two_a_first" "$two_a_last" "$two_b_last" \
    > "$tmp/quota-two-expected"
check "two rollout legs contribute four ordered quota rows" "same" \
    "$(cmp -s "$tmp/quota-two-expected" "$(quota_path "$rd_two")" && echo same || echo different)"

rd_single="$(mk_run_dir quota-single)"
tmpdirs+=("$rd_single")
mkdir -p "$rd_single/codex-sessions"
single_row='{"timestamp":"2026-09-15T06:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":60.0}}}}'
printf '%s\n' "$single_row" > "$rd_single/codex-sessions/rollout-single.jsonl"
record "$rd_single" >/dev/null 2>"$tmp/err"
check "a single quota row is archived once" "1" \
    "$(wc -l < "$(quota_path "$rd_single")" | tr -d ' ')"

rd_none="$(mk_run_dir quota-none)"
tmpdirs+=("$rd_none")
mkdir -p "$rd_none/codex-sessions"
printf '%s\n' '{"timestamp":"2026-09-15T07:00:00.000Z","payload":{"type":"token_count"}}' \
    > "$rd_none/codex-sessions/rollout-none.jsonl"
record "$rd_none" >/dev/null 2>"$tmp/err"
check "rows without rate limits do not create an archive" "no" \
    "$(test -e "$(quota_path "$rd_none")" && echo yes || echo no)"
check "rows without rate limits omit quota fields from the record" "" \
    "$(record_field "$(basename "$rd_none")" codex_quota_rows)"

rd_bad="$(mk_run_dir quota-malformed)"
tmpdirs+=("$rd_bad")
mkdir -p "$rd_bad/codex-sessions"
bad_first='{"timestamp":"2026-09-15T08:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":70.0}}}}'
bad_last='{"timestamp":"2026-09-15T09:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":80.0}}}}'
printf '%s\n%s\n%s\n' "$bad_first" '{not json' "$bad_last" \
    > "$rd_bad/codex-sessions/rollout-bad.jsonl"
record "$rd_bad" >/dev/null 2>"$tmp/err"
printf '%s\n%s\n' "$bad_first" "$bad_last" > "$tmp/quota-bad-expected"
check "a malformed rollout line does not discard good quota rows" "same" \
    "$(cmp -s "$tmp/quota-bad-expected" "$(quota_path "$rd_bad")" && echo same || echo different)"
check "a malformed rollout line still appends the run record" "2" \
    "$(record_field "$(basename "$rd_bad")" codex_quota_rows)"

lines_all_parse() {  # $1 = file path
    python3 -c '
import json, sys
try:
    with open(sys.argv[1], "rb") as f:
        for line in f:
            json.loads(line)
except Exception:
    print("no")
    sys.exit(0)
print("yes")
' "$1"
}

printf '\n== record: a row without a trailing newline does not corrupt the archive ==\n'
rd_no_trailing_nl="$(mk_run_dir quota-no-trailing-nl)"
tmpdirs+=("$rd_no_trailing_nl")
mkdir -p "$rd_no_trailing_nl/codex-sessions"
nonl_a='{"timestamp":"2026-09-15T10:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":90.0}}}}'
nonl_b_first='{"timestamp":"2026-09-15T11:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":91.0}}}}'
nonl_b_last='{"timestamp":"2026-09-15T12:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":92.0}}}}'
# Leg A's only qualifying row has no trailing newline -- what a rollout log
# cut short by a crash or a mid-run quota kill looks like. It sorts first
# (earliest timestamp), directly ahead of leg B's two properly terminated
# rows, so an unfixed writer fuses it onto the row that follows.
printf '%s' "$nonl_a" > "$rd_no_trailing_nl/codex-sessions/rollout-a.jsonl"
printf '%s\n%s\n' "$nonl_b_first" "$nonl_b_last" \
    > "$rd_no_trailing_nl/codex-sessions/rollout-b.jsonl"
record "$rd_no_trailing_nl" >/dev/null 2>"$tmp/err"
printf '%s\n%s\n%s\n' "$nonl_a" "$nonl_b_first" "$nonl_b_last" \
    > "$tmp/quota-no-trailing-nl-expected"
check "an unterminated row gets its own line instead of fusing with the next" \
    "same" \
    "$(cmp -s "$tmp/quota-no-trailing-nl-expected" "$(quota_path "$rd_no_trailing_nl")" && echo same || echo different)"
check "every physical line in the archived file parses as JSON" "yes" \
    "$(lines_all_parse "$(quota_path "$rd_no_trailing_nl")")"
check "the record's row count is the expected 3, not vacuously empty" "3" \
    "$(record_field "$(basename "$rd_no_trailing_nl")" codex_quota_rows)"
check "the archived file's line count matches the record's row count" \
    "$(record_field "$(basename "$rd_no_trailing_nl")" codex_quota_rows)" \
    "$(wc -l < "$(quota_path "$rd_no_trailing_nl")" | tr -d ' ')"

rd_single_no_nl="$(mk_run_dir quota-single-no-nl)"
tmpdirs+=("$rd_single_no_nl")
mkdir -p "$rd_single_no_nl/codex-sessions"
single_nonl='{"timestamp":"2026-09-15T13:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":93.0}}}}'
printf '%s' "$single_nonl" > "$rd_single_no_nl/codex-sessions/rollout-single.jsonl"
record "$rd_single_no_nl" >/dev/null 2>"$tmp/err"
check "the only row lacking a trailing newline still gets one" "1" \
    "$(tail -c1 "$(quota_path "$rd_single_no_nl")" | wc -l | tr -d ' ')"

printf '== record: network is lifted from summary.json ==\n'
rd_sealed="$(mk_run_dir sealed)"
tmpdirs+=("$rd_sealed")
cat > "$rd_sealed/summary.json" <<'EOF'
{"harness":"pi","network":"sealed","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"usage":{"input_tokens":10,"output_tokens":1},"duration_seconds":0}
EOF
printf '0\n' > "$rd_sealed/exit-code"
record "$rd_sealed" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_sealed")")"
contains "a sealed run's network field is recorded" '"network": "sealed"' "$out"
contains "its harness stays pi (the binary), not folded into network" \
    '"harness": "pi"' "$out"

printf '\n== record: network from a summary-missing run.env fallback ==\n'
rd_env="$(mk_run_dir env)"
tmpdirs+=("$rd_env")
cat > "$rd_env/run.env" <<'EOF'
harness=pi
network=sealed
model=
branch=fixture-branch
origin_repo=/var/tmp/claude-scratch/forks/fixture-origin
base_sha=0123456789abcdef0123456789abcdef01234567
EOF
printf '0\n' > "$rd_env/exit-code"
record "$rd_env" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_env")")"
contains "run.env fallback still carries network" '"network": "sealed"' "$out"
contains "run.env fallback marks summary_missing" '"summary_missing": true' "$out"

printf '\n== record: agent_kit is lifted from summary.json ==\n'
rd_kit="$(mk_run_dir kit)"
tmpdirs+=("$rd_kit")
cat > "$rd_kit/summary.json" <<'EOF'
{"harness":"claude","network":"pinned","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","agent_kit":["kit-alpha","kit-beta"],"exit_code":0,"commits":0,"cost_usd":0.0,"usage":{"input_tokens":10,"output_tokens":1},"duration_seconds":0}
EOF
printf '0\n' > "$rd_kit/exit-code"
record "$rd_kit" >/dev/null 2>"$tmp/err"
check "a run's agent_kit is recorded as a list" '["kit-alpha","kit-beta"]' \
    "$(query show "$(basename "$rd_kit")" | jq -c '.agent_kit')"

rd_nokit="$(mk_run_dir nokit)"
tmpdirs+=("$rd_nokit")
sed 's/"agent_kit":\["kit-alpha","kit-beta"\]/"agent_kit":[]/' "$rd_kit/summary.json" > "$rd_nokit/summary.json"
printf '0\n' > "$rd_nokit/exit-code"
record "$rd_nokit" >/dev/null 2>"$tmp/err"
check "an empty agent_kit is recorded as an empty list" '[]' \
    "$(query show "$(basename "$rd_nokit")" | jq -c '.agent_kit')"

out="$(query stats --by agent_kit 2>/dev/null)"
contains "stats --by agent_kit groups on the joined names" "kit-alpha kit-beta" "$out"
case "$out" in
    *"["*) no "stats --by agent_kit does not print a list repr" "$out" ;;
    *) ok "stats --by agent_kit does not print a list repr" ;;
esac

rd_kit_env="$(mk_run_dir kitenv)"
tmpdirs+=("$rd_kit_env")
cat > "$rd_kit_env/run.env" <<'EOF'
harness=claude
network=pinned
branch=fixture-branch
origin_repo=/var/tmp/claude-scratch/forks/fixture-origin
base_sha=0123456789abcdef0123456789abcdef01234567
agent_kit=kit-alpha kit-beta
EOF
printf '0\n' > "$rd_kit_env/exit-code"
record "$rd_kit_env" >/dev/null 2>"$tmp/err"
check "the run.env fallback carries agent_kit as a list" '["kit-alpha","kit-beta"]' \
    "$(query show "$(basename "$rd_kit_env")" | jq -c '.agent_kit')"

printf '\n== read-time normalization of a historical pi-local row ==\n'
before_bytes="$(cat "$log_file")"
# A row shaped exactly like a run recorded before this round: harness is
# the literal string "pi-local", and there is no network key at all.
printf '%s\n' '{"v":1,"event":"run_end","run_id":"claude-fork-sandbox.histfix","ts":"2025-01-01T00:00:00+00:00","source":"fork-sandbox","harness":"pi-local","model":null,"exit_code":0,"commits":1,"cost_usd":0.01}' >> "$log_file"

out="$(query show claude-fork-sandbox.histfix)"
contains "show normalizes a historical pi-local row's harness to pi" \
    '"harness": "pi"' "$out"
contains "show normalizes a historical pi-local row's network to sealed" \
    '"network": "sealed"' "$out"

out="$(query list 2>/dev/null)"
not_contains "list does not show the unnormalized pi-local harness" \
    "pi-local" "$out"
contains "list shows the normalized harness cell as exactly pi" \
    "pi       -" "$out"

out="$(query stats --by network 2>/dev/null)"
contains "stats --by network groups the historical row under sealed" \
    "sealed" "$out"

after_bytes="$(cat "$log_file")"
check "the log file itself is never rewritten by normalization" \
    "$before_bytes
{\"v\":1,\"event\":\"run_end\",\"run_id\":\"claude-fork-sandbox.histfix\",\"ts\":\"2025-01-01T00:00:00+00:00\",\"source\":\"fork-sandbox\",\"harness\":\"pi-local\",\"model\":null,\"exit_code\":0,\"commits\":1,\"cost_usd\":0.01}" \
    "$after_bytes"

# A record that already carries network (post-round) must not be touched
# by the normalizer even if its harness happened to be "pi-local" (should
# never occur in practice, but the guard is "no network key", not "no
# harness value", so this proves the guard does not also fire here).
printf '%s\n' '{"v":1,"event":"run_end","run_id":"claude-fork-sandbox.histpinned","ts":"2025-01-01T00:00:00+00:00","source":"fork-sandbox","harness":"pi-local","network":"pinned","model":null,"exit_code":0,"commits":0}' >> "$log_file"
out="$(query show claude-fork-sandbox.histpinned)"
contains "a row that already carries network is left alone" \
    '"network": "pinned"' "$out"

printf '\n== list: a present-and-null exit_code/commits renders as "-", never "None" ==\n'
# dict.get(k, default) only falls back when the key is ABSENT. commits:
# null is the deliberate "not measured" value cmd_collect writes when a
# commit count is undecidable (see fork-sandbox-k8s.sh), and exit_code:
# null is reachable the same way (cmd_collect's --argjson exit_code
# "${agent_exit_code:-null}"). A key present with JSON null comes back as
# Python None, and str(None) is the four-character string "None" -- this
# row would print it in both the EXIT and CMTS columns if list regressed
# to r.get(k, "-").
printf '%s\n' '{"v":1,"event":"run_end","run_id":"claude-fork-sandbox.nullrender","ts":"2025-01-01T00:00:00+00:00","source":"fork-sandbox","harness":"pi","network":"cluster","model":null,"exit_code":null,"commits":null}' >> "$log_file"
out="$(query list 2>/dev/null)"
nullrender_line="$(grep 'claude-fork-sandbox.nullrender' <<< "$out")"
not_contains "list never renders a present-and-null exit_code/commits as the literal string None" \
    "None" "$nullrender_line"

printf '\n== record: present-and-null fields use confirmation placeholders ==\n'
rd_null_confirmation="$(mk_run_dir null-confirmation)"
tmpdirs+=("$rd_null_confirmation")
printf '%s\n' '{"harness":null,"model":null,"exit_code":null,"commits":null}' \
    > "$rd_null_confirmation/summary.json"
out="$(record "$rd_null_confirmation")"
not_contains "record confirmation never renders present-and-null fields as None" \
    "None" "$out"
contains "record confirmation renders unknown exit and commit values as question marks" \
    "exit ?, ? commit(s)" "$out"

printf '\n== record: composition/composition_short from pipeline.json ==\n'
# Two runs with byte-identical `steps` content but launched from
# differently-NAMED preset files -- the rename-stranding case item 62
# exists to fix. Both models hit the registered letter table (sonnet),
# so neither shortname gets the collision-warning hash suffix.
pipeline_cs2_rs2='{"steps":[
  {"action":"code","harness":"claude","model":"claude-sonnet-4-5-20250929","repeat":1,"network":null,"fix":null},
  {"action":"review","harness":"claude","model":"claude-sonnet-4-5-20250929","repeat":2,"network":null,"fix":null}
]}'

rd_comp_a="$(mk_run_dir comp-rename-a)"
tmpdirs+=("$rd_comp_a")
printf '%s\n' "$pipeline_cs2_rs2" > "$rd_comp_a/pipeline.json"
printf '0\n' > "$rd_comp_a/exit-code"
record "$rd_comp_a" >/dev/null 2>"$tmp/err"

rd_comp_b="$(mk_run_dir comp-rename-b)"
tmpdirs+=("$rd_comp_b")
printf '%s\n' "$pipeline_cs2_rs2" > "$rd_comp_b/pipeline.json"
printf '0\n' > "$rd_comp_b/exit-code"
record "$rd_comp_b" >/dev/null 2>"$tmp/err"

comp_a="$(record_field "$(basename "$rd_comp_a")" composition)"
comp_b="$(record_field "$(basename "$rd_comp_b")" composition)"
check "identical steps content yields an identical composition regardless of preset filename" \
    "$comp_a" "$comp_b"
check "composition_short has no hash suffix when every model hits the alias table" \
    "csonnet1-rsonnet2" "$(record_field "$(basename "$rd_comp_a")" composition_short)"

printf '\n== record: a model id containing both / and : does not collide ==\n'
# The separator trap docs/presets.md 3b warns about: an OpenRouter-shaped
# id with a colon in the tag. JSON serialization must not confuse this
# with a joined string built from a different step split at the same
# character.
rd_slash_colon="$(mk_run_dir comp-slashcolon)"
tmpdirs+=("$rd_slash_colon")
cat > "$rd_slash_colon/pipeline.json" <<'EOF'
{"steps":[
  {"action":"code","harness":"pi","model":"vendor/model:tag","repeat":1,"network":"sealed","fix":null}
]}
EOF
printf '0\n' > "$rd_slash_colon/exit-code"
record "$rd_slash_colon" >/dev/null 2>"$tmp/err"
contains "a model id with both / and : serializes without error" \
    "vendor/model:tag" \
    "$(record_field "$(basename "$rd_slash_colon")" composition)"
short_slashcolon="$(record_field "$(basename "$rd_slash_colon")" composition_short)"
case "$short_slashcolon" in
    c*-????) ok "shortname with an unmapped model carries a 4-char hash suffix" ;;
    *) no "shortname with an unmapped model carries a 4-char hash suffix" "got '$short_slashcolon'" ;;
esac

printf '\n== record: an unmapped model with non-ASCII letters slugs to [a-z0-9] only ==\n'
# docs/presets.md 3c's slug rule is "[a-z0-9] after lowercasing", not
# str.isalnum() -- Unicode letters and digits pass isalnum() but are not
# in [a-z0-9], so a naive isalnum() filter would leak non-ASCII bytes into
# a value the contract says is display-safe ASCII. Built via \xHH escapes,
# not a literal non-ASCII byte in this source file.
model_unicode=$'vendor/m\xc3\xb6d\xc3\xa9l-7'
rd_unicode="$(mk_run_dir comp-unicode)"
tmpdirs+=("$rd_unicode")
cat > "$rd_unicode/pipeline.json" <<EOF
{"steps":[
  {"action":"code","harness":"pi","model":"$model_unicode","repeat":1,"network":"sealed","fix":null}
]}
EOF
printf '0\n' > "$rd_unicode/exit-code"
record "$rd_unicode" >/dev/null 2>"$tmp/err"
short_unicode="$(record_field "$(basename "$rd_unicode")" composition_short)"
case "$short_unicode" in
    cmdl71-????) ok "unmapped-model slug keeps only [a-z0-9] and drops non-ASCII" ;;
    *) no "unmapped-model slug keeps only [a-z0-9] and drops non-ASCII" "got '$short_unicode'" ;;
esac

printf '\n== record: a flag-driven run (no pipeline.json) gets neither field ==\n'
rd_flagdriven="$(mk_run_dir comp-flagdriven)"
tmpdirs+=("$rd_flagdriven")
cat > "$rd_flagdriven/review-loop.json" <<'EOF'
{"cap":3,"review_model":null,"review_harness":null,"fix_harness":null,"fix_model":null,"fix_repeat":null,"ended":"approved","detail":null,"coding_exit_code":0,"iterations":[]}
EOF
printf '0\n' > "$rd_flagdriven/exit-code"
record "$rd_flagdriven" >/dev/null 2>"$tmp/err"
check "a flag-driven run has no composition field" \
    "" "$(record_field "$(basename "$rd_flagdriven")" composition)"
check "a flag-driven run has no composition_short field" \
    "" "$(record_field "$(basename "$rd_flagdriven")" composition_short)"
out="$(query show "$(basename "$rd_flagdriven")")"
contains "a flag-driven run's review_loop is recorded as before" \
    '"review_loop"' "$out"

printf '\n== record: steps -- composed per-step loop records, keyed off pipeline.json ==\n'
rd_steps="$(mk_run_dir comp-steps)"
tmpdirs+=("$rd_steps")
cat > "$rd_steps/pipeline.json" <<'EOF'
{"steps":[
  {"action":"code","harness":"claude","model":"claude-sonnet-4-5-20250929","repeat":1,"network":null,"fix":null},
  {"action":"maintain","harness":"claude","model":"claude-opus-4-5-20250929","repeat":1,"network":null,"fix":null}
]}
EOF
cat > "$rd_steps/step-2-loop.json" <<'EOF'
{"cap":1,"review_model":"claude-opus-4-5-20250929","review_harness":"claude","fix_harness":null,"fix_model":null,"fix_repeat":null,"ended":"approved","detail":null,"coding_exit_code":0,"iterations":[]}
EOF
printf '0\n' > "$rd_steps/exit-code"
record "$rd_steps" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_steps")")"
contains "a composed maintain step's record is labeled action=maintain, not review" \
    '"action": "maintain"' "$out"
contains "a composed step's loop record keeps its review_model field flavor" \
    '"review_model": "claude-opus-4-5-20250929"' "$out"
not_contains "a composed run has no legacy maintainer_loop key" \
    '"maintainer_loop"' "$out"

printf '\n== stats: --by composition groups on the canonical value, prints the shortname ==\n'
out="$(query stats --by composition 2>/dev/null)"
contains "stats --by composition prints the shortname cell" "csonnet1-rsonnet2" "$out"
not_contains "stats --by composition does not print the raw canonical JSON" \
    '"action":"code"' "$out"

printf '\n== record: end_reason is lifted from summary.json when present ==\n'
rd_stopped="$(mk_run_dir end-reason-stopped)"
tmpdirs+=("$rd_stopped")
cat > "$rd_stopped/summary.json" <<'EOF'
{"harness":"pi","network":"sealed","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"end_reason":"stopped","duration_seconds":0}
EOF
printf '0\n' > "$rd_stopped/exit-code"
record "$rd_stopped" >/dev/null 2>"$tmp/err"
out="$(query show "$(basename "$rd_stopped")")"
contains "a stopped run's end_reason is recorded" '"end_reason": "stopped"' "$out"

printf '\n== record: end_reason is absent from the run_end record on a normal run ==\n'
rd_normal="$(mk_run_dir end-reason-absent)"
tmpdirs+=("$rd_normal")
cat > "$rd_normal/summary.json" <<'EOF'
{"harness":"pi","network":"sealed","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"duration_seconds":0}
EOF
printf '0\n' > "$rd_normal/exit-code"
record "$rd_normal" >/dev/null 2>"$tmp/err"
not_contains "a normal run's raw run_end record carries no end_reason key at all" \
    "end_reason" "$(grep -F "\"$(basename "$rd_normal")\"" "$log_file")"
out="$(query show "$(basename "$rd_normal")")"
not_contains "show prints no end_reason field for a normal run" "end_reason" "$out"

printf '\n== record: append creates a missing ~/.claude on a fresh HOME ==\n'
fresh_home="$tmp/fresh-home"
mkdir -p "$fresh_home"
tmpdirs+=("$fresh_home")
rd_fresh="$(mk_run_dir fresh-home)"
tmpdirs+=("$rd_fresh")
cat > "$rd_fresh/summary.json" <<'EOF'
{"harness":"pi","network":"sealed","model":null,"branch":"fixture-branch","origin_repo":"/var/tmp/claude-scratch/forks/fixture-origin","base_sha":"0123456789abcdef0123456789abcdef01234567","exit_code":0,"commits":0,"cost_usd":0.0,"duration_seconds":0}
EOF
printf '0\n' > "$rd_fresh/exit-code"
HOME="$fresh_home" python3 "$runlog" record --run-dir "$rd_fresh" \
    >/dev/null 2>"$tmp/fresh-err"
check "append succeeds under a HOME with no .claude" "0" "$?"
if [[ -d "$fresh_home/.claude" ]]; then
    ok "append creates the missing .claude directory"
else
    no "append creates the missing .claude directory" "not found: $fresh_home/.claude"
fi
if [[ -f "$fresh_home/.claude/sandbox-runs.jsonl" ]]; then
    ok "append creates sandbox-runs.jsonl under the fresh .claude"
else
    no "append creates sandbox-runs.jsonl under the fresh .claude" \
        "not found: $fresh_home/.claude/sandbox-runs.jsonl"
fi
contains "the fresh-HOME record is readable back" "\"$(basename "$rd_fresh")\"" \
    "$(cat "$fresh_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
