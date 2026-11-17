#!/usr/bin/env bash
# shellcheck extended-analysis=false  # see shellcheck-memory-budget-test.sh
# tests/postmaster/26-malformed-clear.sh — fork-sandbox-postmaster.sh: a
# seat's malformed-reply flag carries the run that raised it, and that
# seat's next wake that posts a reply with nothing malformed clears it, as
# a clean exit clears a wake-exit flag -- a handler seat's included. Another
# seat's flag, a wake that is still partly malformed, a legacy reason with
# no run id, and the raising run's wake-exit record stay.
#
# Usage: tests/postmaster/26-malformed-clear.sh  (or all files at once:
# tests/fork-sandbox-postmaster-test.sh)

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

for mc_seat in mia max; do
    printf 'Malformed-clear fixture seat.\n' > "$FORK_SANDBOX_PERSONAS_DIR/$mc_seat.md"
done
new_root MC_HANDLERS_DIR
export FORK_SANDBOX_HANDLERS_DIR="$MC_HANDLERS_DIR"
MC_FLIP="$work/mc-flip"
export MC_FLIP
# A handler seat whose first wake writes a malformed reply and every later
# one a good one.
cat > "$MC_HANDLERS_DIR/flip-handler" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ -e "$MC_FLIP" ]]; then
    printf 'Subject: verdict\n\nlooks fine\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
else
    : > "$MC_FLIP"
    printf 'handler junk\n\nbody\n' > "$FS_HANDLER_OUTBOX/mail-1.md"
fi
STUB
chmod +x "$MC_HANDLERS_DIR/flip-handler"
sed -i 's/^agents:$/agents:\n  mia:\n    on-silence: retry\n  max:\n    on-silence: retry\n  flip:\n    handler: exec\n    command: flip-handler/' "$FORK_SANDBOX_FLEET_FILE"
"$FLEET" check >/dev/null 2>&1 || { echo "FATAL: malformed-clear fixture fleet fails check" >&2; exit 1; }

mc_store() {
    new_scratch_root FORK_SANDBOX_MAIL_ROOT
    export FORK_SANDBOX_MAIL_ROOT
    PM_STATE_DIR="$FORK_SANDBOX_MAIL_ROOT/.postmaster"
    : > "$STUB_ARGV_LOG"
}
mc_thread() {
    mc_store
    mc_mid="$(send_msg '@alice' "$1" "malformed topic $2" 'please answer' 8)"
    mc_tid="$(thread_of "$mc_mid")"; mc_short="${mc_tid:0:8}"
}
mc_rid() { basename "$(live_env_for_agent "$1")" .env; }
# mc_out <agent> <file> <content>: one reply file in the live run's outbox,
# and the run ends cleanly (call once per file, then mc_end).
mc_out() {
    local rd
    rd="$(env_val "$(live_env_for_agent "$1")" RUN_DIR)"
    mkdir -p -- "$rd/outbox"
    printf '%b' "$3" > "$rd/outbox/$2"
}
# mc_end <agent> [exit-code]
mc_end() {
    local rd
    rd="$(env_val "$(live_env_for_agent "$1")" RUN_DIR)"
    printf '%s\n' "${2:-0}" > "$rd/exit-code"
    printf '{}\n' > "$rd/summary.json"
}
mc_flag() { cat "$PM_STATE_DIR/needs-operator/$mc_tid" 2>/dev/null || true; }
mc_jcount() {
    awk -F'\t' -v k="$1" '$2=="clear" && $3==k' "$PM_STATE_DIR/needs-operator-journal/$mc_tid" 2>/dev/null | wc -l
}
mc_good='Subject: verdict\n\nlooks fine\n'

printf '\n== a seat whose retry posts a clean reply clears its malformed-reply flag ==\n'
mc_thread '@mia' one
once
mc_r1="$(mc_rid mia)"
# The quoted line names another run: the run id the clear reads is the
# postmaster's own suffix, the last one.
mc_out mia mail-1.md 'this line is not a header (run not-mine)\n\nbody\n'; mc_end mia
once
check "one: the flag reason ends with the run that raised it" \
    "malformed reply file mail-1.md: unparseable header stanza: this line is not a header (run not-mine) (run $mc_r1)" \
    "$(mc_flag)"
once
mc_r2="$(mc_rid mia)"
check "one: the retry is a malformed retry of the first run" "malformed $mc_r1" \
    "$(env_val "$(live_env_for_agent mia)" RETRY_KIND) $(env_val "$(live_env_for_agent mia)" RETRY_OF)"
mc_out mia mail-1.md "$mc_good"; mc_end mia
once
check "one: the clean reply clears the flag" "" "$(mc_flag)"
check "one: the journal has one malformed-reply clear line" 1 "$(mc_jcount malformed-reply)"
contains "one: the clear line names the reason and the recovering run" \
    "$(cat "$PM_STATE_DIR/needs-operator-journal/$mc_tid")" "(run $mc_r1) cleared by run $mc_r2"
contains "one: a flag-clear event with reason=malformed-reply" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=mia reason=malformed-reply run=$mc_r1 by=$mc_r2 flagged=no"

printf '\n== two seats each malformed; only the one that recovers is cleared ==\n'
mc_thread '@mia, @max' two
once
mc_ra="$(mc_rid mia)"; mc_rb="$(mc_rid max)"
mc_out max mail-1.md 'max wrote junk\n\nbody\n'; mc_end max
once
mc_out mia mail-1.md 'mia wrote junk\n\nbody\n'; mc_end mia
once
check "two: the flag shows the newest, mia's" \
    "malformed reply file mail-1.md: unparseable header stanza: mia wrote junk (run $mc_ra)" "$(mc_flag)"
once
mc_ra2="$(mc_rid mia)"
mc_out mia mail-1.md "$mc_good"; mc_end mia
once
check "two: mia's recovery leaves max's flag standing" \
    "malformed reply file mail-1.md: unparseable header stanza: max wrote junk (run $mc_rb)" "$(mc_flag)"
check "two: exactly one clear line, mia's" 1 "$(mc_jcount malformed-reply)"
not_contains "two: max's reason has no clear line" \
    "$(awk -F'\t' '$2=="clear"' "$PM_STATE_DIR/needs-operator-journal/$mc_tid")" "(run $mc_rb)"
contains "two: the event says the thread is still flagged" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=mia reason=malformed-reply run=$mc_ra by=$mc_ra2 flagged=yes"

printf '\n== a wake with one good reply and one malformed file clears nothing ==\n'
mc_thread '@mia' three
once
mc_r1="$(mc_rid mia)"
mc_out mia mail-1.md 'first junk\n\nbody\n'; mc_end mia
once
once
mc_r2="$(mc_rid mia)"
mc_out mia mail-1.md "$mc_good"
mc_out mia mail-2.md 'second junk\n\nbody\n'; mc_end mia
once
check "three: the good reply posted" "pm harvest thread=$mc_short agent=mia replies=1" \
    "$(grep -o "pm harvest thread=$mc_short agent=mia replies=[0-9]*" "$work/once.out")"
check "three: no clear line" 0 "$(mc_jcount malformed-reply)"
not_contains "three: no flag-clear event" "$(cat "$work/once.out")" "pm flag-clear"
check "three: the flag shows the new malformed file" \
    "malformed reply file mail-2.md: unparseable header stanza: second junk (run $mc_r2)" "$(mc_flag)"

printf '\n== the Version: header discard carries the run and is cleared the same way ==\n'
mc_thread '@mia' four
once
mc_r1="$(mc_rid mia)"
mc_out mia mail-1.md 'Version: 2\nSubject: moving it\n\nbody\n'; mc_end mia
once
check "four: the Version: discard reason carries the run id" \
    "malformed reply file mail-1.md: Version: header from a seat without review-target: sets (run $mc_r1)" \
    "$(mc_flag)"
once
mc_r2="$(mc_rid mia)"
mc_out mia mail-1.md "$mc_good"; mc_end mia
once
check "four: the clean retry clears it" "" "$(mc_flag)"
contains "four: with a flag-clear event" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=mia reason=malformed-reply run=$mc_r1 by=$mc_r2 flagged=no"

printf '\n== a legacy malformed-reply reason with no run id is left alone ==\n'
mc_thread '@mia' five
once
mc_legacy='malformed reply file mail-1.md: unparseable header stanza: old junk'
mkdir -p -- "$PM_STATE_DIR/needs-operator" "$PM_STATE_DIR/needs-operator-journal"
printf '%s\n' "$mc_legacy" > "$PM_STATE_DIR/needs-operator/$mc_tid"
printf '2026-01-01T00:00:00Z\tflag\tmalformed-reply\t%s\n' "$mc_legacy" \
    >> "$PM_STATE_DIR/needs-operator-journal/$mc_tid"
mc_out mia mail-1.md "$mc_good"; mc_end mia
once
check "five: the reply posted" "pm harvest thread=$mc_short agent=mia replies=1" \
    "$(grep -o "pm harvest thread=$mc_short agent=mia replies=[0-9]*" "$work/once.out")"
check "five: the legacy flag stands" "$mc_legacy" "$(mc_flag)"
check "five: no clear line" 0 "$(mc_jcount malformed-reply)"

printf '\n== a recovering run that itself failed leaves the wake-exit record open ==\n'
mc_thread '@mia' six
once
mc_r1="$(mc_rid mia)"
mc_out mia mail-1.md 'six junk\n\nbody\n'; mc_end mia 1
once
mc_we="$PM_STATE_DIR/wake-exits/$mc_tid/mia"
check "six: the failed malformed run has a wake-exit record" 1 \
    "$([[ -f "$mc_we/$mc_r1.json" ]] && echo 1 || echo 0)"
[[ -n "$(live_env_for_agent mia)" ]] || reply_msg '@alice' "$mc_mid" 'try again' --to '@mia' >/dev/null
once
mc_r2="$(mc_rid mia)"
mc_out mia mail-1.md "$mc_good"; mc_end mia 1
once
contains "six: the failed run's good reply clears the malformed-reply flag" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=mia reason=malformed-reply run=$mc_r1 by=$mc_r2"
check "six: but does not mark the first run's wake-exit record cleared" 0 \
    "$([[ -e "$mc_we/$mc_r1.cleared" ]] && echo 1 || echo 0)"
check "six: and the first run's wake-exit flag has no clear line" 0 "$(mc_jcount wake-exit)"
contains "six: so the flag falls back to an open wake-exit reason" "$(mc_flag)" "wake for mia exited 1"

printf '\n== quoted text with an unclosed "(run " does not hide the run id ==\n'
mc_thread '@mia' seven
once
mc_r1="$(mc_rid mia)"
mc_out mia mail-1.md 'retry (run 2 of 3\n\nbody\n'; mc_end mia
once
check "seven: the reason quotes the unclosed text, then the run" \
    "malformed reply file mail-1.md: unparseable header stanza: retry (run 2 of 3 (run $mc_r1)" "$(mc_flag)"
once
mc_r2="$(mc_rid mia)"
mc_out mia mail-1.md "$mc_good"; mc_end mia
once
check "seven: the clean retry clears it" "" "$(mc_flag)"
contains "seven: with a flag-clear event naming the right run" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=mia reason=malformed-reply run=$mc_r1 by=$mc_r2 flagged=no"

printf '\n== a handler seat whose next wake posts a clean reply is cleared too ==\n'
rm -f -- "$MC_FLIP"
mc_thread '@flip' eight
once
contains "eight: the handler's malformed reply flags with its run id" "$(mc_flag)" \
    "malformed reply file mail-1.md: unparseable header stanza: handler junk (run "
reply_msg '@alice' "$mc_mid" 'try again' --to '@flip' >/dev/null
once
check "eight: the handler's clean reply posted" "pm harvest thread=$mc_short agent=flip replies=1" \
    "$(grep -o "pm harvest thread=$mc_short agent=flip replies=[0-9]*" "$work/once.out")"
check "eight: and cleared its flag" "" "$(mc_flag)"
check "eight: one malformed-reply clear line" 1 "$(mc_jcount malformed-reply)"
contains "eight: with a flag-clear event" "$(cat "$work/once.out")" \
    "pm flag-clear thread=$mc_short agent=flip reason=malformed-reply run="

finish_suite
