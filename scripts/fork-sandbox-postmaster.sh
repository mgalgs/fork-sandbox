#!/usr/bin/env bash
# fork-sandbox-postmaster.sh — Host-side router: watches the mail store,
# wakes addressed agents by spawning fork-sandbox runs, harvests their
# replies back into the store, and enforces the fleet's stop rules
#
# Usage: fork-sandbox-postmaster.sh deliver --project <path> [--once]
#        fork-sandbox-postmaster.sh status
#        fork-sandbox-postmaster.sh flag <thread-id> [reason]
#        fork-sandbox-postmaster.sh unflag <thread-id>
#
# deliver scans fork-sandbox-mail.sh's store for unrouted messages, routes
# each one (see ROUTING RULES below), spawns a fork-sandbox.sh run per
# wake, and harvests the outbox of every run that has reached a terminal
# state. --once does one scan-route-harvest pass and exits (the test
# surface); without it, deliver loops -- scan, route, harvest, sleep
# $FORK_SANDBOX_POSTMASTER_INTERVAL seconds (default 15) -- until
# SIGTERM/SIGINT, then exits 0.
#
# status prints one screen: how many messages are unrouted, every live run
# (agent, thread, run dir), every thread flagged needs-operator with its
# reason, and each thread's spawn count.
#
# flag/unflag set or clear a thread's needs-operator flag by hand, e.g. to
# silence a thread the operator intends to leave alone, or to re-arm one
# after fixing whatever tripped a flag automatically.
#
# THE MODEL
#
# Spawn-on-delivery. An agent is a (persona, mailbox) pair; a wake is one
# fork-sandbox.sh run carrying the persona, the full thread, and reply
# instructions in a generated handoff. Only a message's To: recipients
# wake -- Cc: recipients never spawn; their visibility is `mail inbox` and
# the full thread arriving in the prompt whenever they are later woken.
# Privacy is addressing: a woken agent receives ONLY the thread it is
# being woken for -- the sandbox has no mail tooling and no store access,
# so the thread embedded in its handoff is that agent's entire world for
# the run.
#
# ROUTING RULES (applied in this order to each unrouted message M in
# thread T; a message is routed exactly once, decided before any wake is
# spawned for it):
#
#   0. Expand M's To via fleet expand, one address at a time (an unknown
#      address anywhere else in the same To: would otherwise fail the
#      whole batch) -- every expanded name that resolves as a fleet agent
#      is a wake candidate. A name that does not resolve (unknown or
#      external, e.g. the operator's own address) is skipped silently:
#      external senders receive mail only in the archive. M's own From is
#      never a wake candidate, even when it only reaches the list via a
#      list address M's To: expands through -- a sender never wakes on a
#      message it sent itself.
#   1. Operator reset: if M's From does NOT resolve as a fleet agent, M is
#      operator/external mail -- clear T's needs-operator flag and reset
#      T's spawn count to 0 BEFORE applying rules 2-3 to M. The operator
#      re-arms a stalled thread just by mailing into it. Raising hops
#      (rather than the harvester's automatic per-wake decrement) needs
#      `mail send --hops` on a fresh thread: an operator's own `mail
#      reply` still copies the parent's X-Hops verbatim, since only the
#      harvester's reply-posting call (below) passes --hops.
#   2. X-Hops gate: M's X-Hops == 0 means no wakes from M -- flag T
#      needs-operator, reason "hops exhausted at <message-id>".
#   3. Thread budget: spawns-so-far(T) >= budget (default 12,
#      $FORK_SANDBOX_THREAD_BUDGET overrides) means no wake -- flag T,
#      reason "thread budget <n> exhausted". Checked once per message,
#      not once per candidate: a message addressing several agents with
#      one budget slot left still spawns all of them (v1 does not ration
#      within a single message).
#   4. One wake per (agent, message): an agent named in To twice (directly
#      and via a list) wakes once. An agent already running a wake for
#      thread T (a live, not-yet-harvested run) does not get a second
#      spawn -- the new message-id is recorded on that run as a pending
#      message; after harvesting that run's reply, rules 2-3 are
#      re-checked and a follow-up wake is spawned for the newest pending
#      message if they still pass.
#
# THE WAKE
#
# Spawned via `fork-sandbox.sh --branch <b> --harness <h> [--model <m>]
# [--network <n>] [--pi-args "--thinking <level>"] <project> <handoff>`,
# with NO --review-loop and NO --maintainer-loop: the fleet IS the review
# here, scrutiny comes from other agents reading the reply on the thread.
# Seat (harness/model/thinking/network) comes from `fleet resolve <agent>`;
# unset harness/network default to claude/pinned. An unset model defaults
# to sonnet ONLY on the claude harness -- "sonnet" is a claude alias, so
# defaulting it for pi/codex would hand a bogus model to a harness that
# does not know the name (codex) or defeat fork-sandbox.sh's own
# model-less-pi guard and a sealed seat's model discovery (pi); those
# harnesses get no --model flag at all when unset, so fork-sandbox.sh's
# own resolution/refusal applies exactly as it would for any other caller.
# thinking is passed as --pi-args only when the harness is pi. Branch name
# is sbx-mail-<first8-of-thread-id>-<agent>-<seq>, seq counting from a
# thread-lifetime spawn sequence that is NEVER reset (unlike the budget
# counter rule 1 resets on an operator message -- see STATE below), so a
# branch name can never repeat within a thread. A wake that commits
# nothing is normal (an analysis reply has no code) -- fork-sandbox.sh
# itself deletes empty branches.
#
# The generated handoff embeds everything the sandbox needs and nothing
# it can reach on its own: "You are @<agent>." plus the persona's markdown
# body (frontmatter stripped), the full thread oldest-first (each
# message's header block and body, verbatim), the triggering message-id
# called out, the reply-file format, the transparency norm (private
# side-channels are fine but say so on-thread if they shaped your reply),
# and "no reply is a valid outcome, end your turn" -- an agent is one
# voice on a team, not obligated to speak every time it is woken.
#
# REPLY HARVEST
#
# A wake replies by writing one file per outgoing message to its run's
# artifact outbox, named mail-*.md:
#
#   To: @a, @b          # optional; default is reply-all to the trigger
#   Cc: @c              # optional
#   Subject: ...        # optional; default "Re: " + the trigger's subject
#   Reply-To-Id: <id>   # optional; default is the triggering message-id;
#                       # the literal string "new" starts a NEW thread
#                       # instead (requires To and Subject -- there is no
#                       # parent to reply-all from)
#   <blank line>
#   body...
#
# Once a run reaches terminal state -- its run dir has a summary.json
# file (fork-sandbox.sh's last artifact, written after run_cleanup and the
# branch fetch-back), or its pid has gone dead without one ever landing
# (see pm_wake_is_dead) -- the harvester posts each mail-*.md via
# fork-sandbox-mail.sh as
# --from @<agent>, passing --hops explicitly as (trigger's X-Hops - 1) on
# BOTH the ordinary reply path and the new-thread path -- `mail.sh reply`
# takes a --hops override for exactly this (round 3 is this script, per
# fork-sandbox-mail.sh's own header comment). A non-zero exit code, and a
# wake that died without ever writing one, are both harvested the same as
# a zero exit code (their outbox, if any, is still posted) but also flag
# the thread, since an empty outbox from a crashed wake is not the
# documented "no reply is a valid outcome" and needs an operator's eyes.
# A malformed reply file (bad address, unparseable stanza, or a
# `mail.sh` call that itself fails) is skipped and flags the thread with
# the filename and the reason -- it never costs the run's other,
# well-formed replies. The run is then marked harvested exactly once.
# Posted replies are new unrouted messages; the next scan routes them --
# that loop is the whole conversation.
#
# STATE, under $FORK_SANDBOX_MAIL_ROOT/.postmaster/ (dot-prefixed so the
# store's own thread scans never see it). $FORK_SANDBOX_MAIL_ROOT must
# itself resolve under /var/tmp/claude-scratch (or the /tmp/claude-scratch
# compat symlink) and not under its forks/ subtree -- handoffs/ below is
# where every wake stages the document fork-sandbox.sh reads into a
# session's prompt, and that script refuses any handoff outside those
# bounds (fs_require_scratch_handoff, fork-sandbox-lib.sh). `deliver`
# checks this once at startup rather than let every spawn fail one at a
# time with the real reason:
#
#   lock                           a flock(1)'d file; the holder's pid is
#                                   written into it for status/error
#                                   messages only -- the actual mutual
#                                   exclusion is the kernel's advisory
#                                   lock on the open file description, not
#                                   the file's content, so a killed
#                                   postmaster can never leave a stale
#                                   hold for a successor to race against
#   routed/<message-id>            marker: routing already decided for
#                                   this message (created before any
#                                   spawn it triggers, so a crash between
#                                   marker and spawn loses at most that
#                                   one wake -- `status` shows the gap;
#                                   v1 has no repair machinery for it)
#   runs/<run-id>.env               one spawned wake: AGENT, THREAD,
#                                   TRIGGER, RUN_DIR, BRANCH, RESUMED (the
#                                   session id this wake was launched to
#                                   resume, empty for a fresh one -- what
#                                   `status` prints in its session column),
#                                   PENDING_MSGS (comma list, may be empty)
#   harvested/<run-id>             marker: this run's outbox is collected
#   needs-operator/<thread-id>     flag file; content is the reason
#   spawns/<thread-id>             one line appended per spawn, reset to
#                                   empty by rule 1 -- line count is the
#                                   thread's BUDGET count (rule 3)
#   seq/<thread-id>                one line appended per spawn, NEVER
#                                   reset -- line count feeds the branch
#                                   name's sequence number, so a name can
#                                   never repeat within a thread even
#                                   across a rule-1 budget reset
#   handoffs/<run-id>.md           the generated handoff passed to a wake
#   state/<thread-id>/<agent>/     the claude CLI's transcript store for
#                                   that one (thread, agent) pair, bound
#                                   into every wake of it with
#                                   --session-state so the conversation
#                                   outlives the run. claude seats only
#                                   (pi and codex keep their sessions
#                                   elsewhere and stay fresh-wake)
#   sessions/<thread-id>/<agent>   the session id the LAST wake of that
#                                   pair ended on, read out of the run's
#                                   summary.json at harvest. Present ->
#                                   the next wake resumes it; absent ->
#                                   the next wake is fresh. Cleared when a
#                                   wake fails outright, or ends cleanly
#                                   with a null/absent session_id, so a
#                                   broken or missing session can never
#                                   wedge a seat
#
# All state transitions are marker-file creation, never deletion of
# anything fork-sandbox-mail.sh owns.
#
# LIMITATIONS (v1 does not do these; a later round might):
#   - Session resume is claude-only: a pi or codex seat gets a fresh
#     session on every wake, with the thread in the prompt as its only
#     continuity. That prompt stays the correctness guarantee even for
#     claude -- resume is a continuity and cost optimization, and a wake
#     whose session is missing or unreadable still does the work.
#   - A resumed session is the only thing that crosses between wakes. The
#     sandbox does not: every wake gets a new work dir, so a new clone, a
#     new operator inbox and a new artifact outbox at fresh absolute paths,
#     and a new branch (the seq above guarantees the name is new) started at
#     the clone's own HEAD rather than at the previous wake's branch. A
#     resumed conversation therefore remembers paths that no longer exist
#     and commits that are not reachable from the HEAD it is now looking at
#     -- the earlier wake's branch came back to the origin, so the new clone
#     has it as a remote-tracking ref, but nothing merges it forward.
#     fork-sandbox.sh tells a resumed wake this, in a "This session is a
#     continuation" section it adds to the prompt whenever
#     --resume-session is given; carrying work forward across wakes is
#     still the agent's own git work, and nothing here automates it.
#   - No delivery of mail tooling into the sandbox, and no store access
#     from inside a run.
#   - No list-Cc delivery index.
#   - No repair of a routed-but-never-spawned wake after a crash.
#   - No renderer, no SMTP.
#   - A spawned wake whose process died without ever writing summary.json --
#     tmux session killed, host rebooted mid-run -- is detected at harvest
#     via its run dir's pid file (see pm_wake_is_dead): once that pid is
#     dead (or its pid file predates the current boot, per /proc/stat's
#     btime) and FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE seconds have
#     passed, the thread is flagged, the agent unblocks and the recorded
#     session id is cleared. Residual gap: a pid recycled by the OS onto a
#     live, unrelated process *within the same boot* reads as "alive"
#     here, so detection waits for THAT process to exit too --
#     vanishingly rare, and the same gap fork-sandbox-status.sh's
#     "abandoned" state already accepts for the identical check.

set -euo pipefail

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
MAIL="$script_dir/fork-sandbox-mail.sh"
FLEET="$script_dir/fork-sandbox-fleet.sh"
# Resolved through script_dir like MAIL/FLEET above, not left to PATH: an
# uninstalled checkout (not yet on PATH) still has all three scripts
# sitting next to each other, but PATH lookup alone would fail. Overridable
# so the test suite can point this at a stub instead of the real launcher.
FORK_SANDBOX="${FORK_SANDBOX_POSTMASTER_LAUNCHER:-$script_dir/fork-sandbox.sh}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$script_dir/fork-sandbox-lib.sh"

# The harvest pass below reads a run dir's pid file with $FS_STAT -c %Y (the
# GNU form fork-sandbox-lib.sh resolves); the BSD stat of the same name takes
# different flags entirely, so say so here, before anything is created,
# rather than fail confusingly deep in a harvest pass.
fs_require_gnu_tools || exit 1

MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"
STATE="$MAIL_ROOT/.postmaster"
LOCK_FILE="$STATE/lock"
ROUTED="$STATE/routed"
RUNS="$STATE/runs"
HARVESTED="$STATE/harvested"
NEEDS_OPERATOR="$STATE/needs-operator"
SPAWNS="$STATE/spawns"
SEQ="$STATE/seq"
HANDOFFS="$STATE/handoffs"
PM_SESSION_STATE="$STATE/state"
PM_SESSIONS="$STATE/sessions"

# The shape fork-sandbox.sh accepts for --resume-session. Applied to what
# summary.json reported before it is recorded: a malformed id would make
# the launcher refuse EVERY later wake of that seat, which is a wedge, and
# the value comes from a filename this script never chose.
PM_SESSION_ID_RE='^[0-9a-f][0-9a-f-]{7,63}$'

PM_ADDR_RE='^@[a-z0-9][a-z0-9-]*$'

# ---- tiny header/store helpers (mail_header et al. are private to
# fork-sandbox-mail.sh and not sourceable -- same shape, reimplemented) ----

pm_header() {
    local file="$1" name="$2" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        if [[ "$line" == "$name:"* ]]; then
            printf '%s' "${line#"$name": }"
            return 0
        fi
    done < "$file"
    return 0
}

pm_find_by_id() {
    local id="$1" f
    for f in "$MAIL_ROOT"/threads/*/*.msg; do
        [[ -e "$f" ]] || continue
        if [[ "$(pm_header "$f" Message-ID)" == "$id" ]]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

pm_persona_body() {
    awk -- '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { infm=0; next }
        infm { next }
        { print }
    ' "$1"
}

pm_env_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n1
}

# Records / clears the session a (thread, agent) pair's next wake should
# resume. Clearing is the failure path's job: the next wake then starts
# fresh, which always works, rather than retrying a session that may be
# what broke the last one. Never a retry loop -- claude-sandboxed already
# retried once inside the run.
pm_session_record() {
    local tid="$1" agent="$2" sid="$3"
    mkdir -p -- "$PM_SESSIONS/$tid"
    printf '%s\n' "$sid" > "$PM_SESSIONS/$tid/$agent"
}

pm_session_clear() {
    local tid="$1" agent="$2"
    rm -f -- "$PM_SESSIONS/$tid/$agent"
}

pm_new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

pm_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Expands a To:/Cc:-shaped comma list one address at a time (fleet expand
# fails its WHOLE call on the first unknown address in a batch, so calling
# it once per address is required, not stylistic -- otherwise one stray
# unknown recipient in a reply-all To: would silently drop every valid
# one alongside it). Unknown/external addresses are skipped, not errors
# (rule 0). Output: one BARE agent name per line (fleet expand emits
# "@name"; resolve and branch-naming both want the bare name).
pm_expand_to() {
    local to_field="$1" a name
    local -a addrs=() result=()
    IFS=',' read -ra addrs <<< "$to_field"
    for a in "${addrs[@]}"; do
        a="$(pm_trim "$a")"
        [[ -n "$a" ]] || continue
        local expanded
        expanded="$("$FLEET" expand "$a" 2>/dev/null)" || continue
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            name="${name#@}"
            local dup=0 e
            for e in "${result[@]:-}"; do
                [[ "$e" == "$name" ]] && { dup=1; break; }
            done
            (( dup )) || result+=("$name")
        done <<< "$expanded"
    done
    printf '%s\n' "${result[@]:-}"
}

pm_spawn_count() {
    local tid="$1"
    [[ -f "$SPAWNS/$tid" ]] && wc -l < "$SPAWNS/$tid" || printf '0'
}

# Branch-naming sequence: unlike $SPAWNS/$tid (the budget counter, reset to
# empty by rule 1 on every operator/external message), $SEQ/$tid is never
# truncated, so seq is monotonic for the thread's whole lifetime and a
# branch name can never repeat -- even across a rule-1 reset landing two
# spawns back-to-back at the same (would-be) count+1.
pm_next_seq() {
    local tid="$1" n
    n="$([[ -f "$SEQ/$tid" ]] && wc -l < "$SEQ/$tid" || printf '0')"
    printf '%s' "$(( n + 1 ))"
}

pm_flag() {
    local tid="$1" reason="$2"
    mkdir -p -- "$NEEDS_OPERATOR"
    printf '%s\n' "$reason" > "$NEEDS_OPERATOR/$tid"
}

pm_unflag() {
    rm -f -- "$NEEDS_OPERATOR/$1"
}

# ---- lock ----
#
# flock(2) on a plain file, held for the life of this process (pm_lock_fd
# stays open until pm_lock_release or process exit closes it). This is
# deliberately NOT a "check a pid, then mkdir/rm-rf" scheme: kill -0 plus a
# separate rm -rf + mkdir is a TOCTOU race between any two postmasters that
# both see the same stale pid at the same time -- both proceed, both
# "win", and both then route and double-spawn every wake. A kernel advisory
# lock has no such window: it is acquired atomically, and a killed holder
# (however it died) can never leave a stale hold for a successor to race
# against, so there is no "stale lock" case left to detect or break.

pm_lock_acquire() {
    mkdir -p -- "$STATE"
    exec {pm_lock_fd}<>"$LOCK_FILE" || return 1
    if ! flock -n "$pm_lock_fd"; then
        local pid
        pid="$(cat -- "$LOCK_FILE" 2>/dev/null || true)"
        exec {pm_lock_fd}>&-
        echo "Error: postmaster: another deliver${pid:+" (pid $pid)"} holds the lock." >&2
        return 1
    fi
    printf '%s\n' "$$" > "$LOCK_FILE"
    return 0
}

pm_lock_release() {
    flock -u "$pm_lock_fd" 2>/dev/null || true
    exec {pm_lock_fd}>&- 2>/dev/null || true
}

# ---- handoff generation ----

pm_write_handoff() {
    local out="$1" agent="$2" persona_path="$3" tid="$4" trigger_mid="$5" f
    {
        printf 'You are @%s.\n\n' "$agent"
        if [[ -n "$persona_path" && -f "$persona_path" ]]; then
            pm_persona_body "$persona_path"
            printf '\n'
        fi
        printf '## Thread\n\n'
        for f in "$MAIL_ROOT/threads/$tid"/*.msg; do
            [[ -e "$f" ]] || continue
            printf '```\n'
            cat -- "$f"
            printf '\n```\n\n'
        done
        printf 'The triggering message for this wake is: %s\n\n' "$trigger_mid"
        cat <<'INSTR'
## Replying

To reply, write one file per outgoing message to your artifact outbox,
named `mail-*.md` (e.g. `mail-1.md`, `mail-2.md`). Each file is a small
header stanza, a blank line, then the body:

    To: @a, @b          # optional; default is reply-all to the triggering message
    Cc: @c              # optional
    Subject: ...        # optional; default is "Re: " + the triggering message's subject
    Reply-To-Id: <id>   # optional; default is the triggering message id above;
                        # the literal string "new" starts a brand new thread instead
                        # (a new thread requires To and Subject -- there is no
                        # reply-all to infer them from)

    body text here, verbatim.

No action needed is a valid outcome: write no reply files, and end your
turn. You are one voice on a team; reply when you have something to add.
INSTR
        printf '\nPrivate exchanges with other agents are allowed and unlogged on the\n'
        printf 'main thread, but when a side conversation shaped your position, say so\n'
        printf 'in your on-thread reply (e.g. "@x and I discussed this off-thread; we\n'
        printf 'concluded...").\n'
    } > "$out"
}

# ---- spawn ----

pm_find_live_run() {
    local agent="$1" tid="$2" f rid a t
    for f in "$RUNS"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$HARVESTED/$rid" ]] && continue
        a="$(pm_env_get "$f" AGENT)"
        t="$(pm_env_get "$f" THREAD)"
        if [[ "$a" == "$agent" && "$t" == "$tid" ]]; then
            printf '%s' "$rid"
            return 0
        fi
    done
    return 1
}

pm_append_pending() {
    local rid="$1" mid="$2"
    local f="$RUNS/$rid.env" existing
    existing="$(pm_env_get "$f" PENDING_MSGS)"
    case ",$existing," in
        *",$mid,"*) return 0 ;;
    esac
    local new="${existing:+$existing,}$mid"
    if grep -q '^PENDING_MSGS=' "$f"; then
        sed -i "s/^PENDING_MSGS=.*/PENDING_MSGS=$new/" "$f"
    else
        printf 'PENDING_MSGS=%s\n' "$new" >> "$f"
    fi
}

pm_spawn_wake() {
    local project="$1" agent="$2" tid="$3" mid="$4"
    local harness model thinking network persona_path description
    # description (resolve's 6th line) is read to keep the fixed 6-line
    # contract explicit but is not needed by a wake.
    # shellcheck disable=SC2034
    if ! { read -r harness; read -r model; read -r thinking; read -r network; \
           read -r persona_path; read -r description; } < <("$FLEET" resolve "$agent" 2>/dev/null); then
        pm_flag "$tid" "seat resolution failed for $agent: $mid"
        return 0
    fi
    harness="${harness:-claude}"
    # "sonnet" is a claude alias; defaulting it for any other harness sends
    # a bogus model id (codex does not know the name) or, worse, defeats
    # fork-sandbox.sh's own model-less-pi guard and a sealed pi seat's
    # model discovery. Only claude gets a default -- everyone else gets no
    # --model flag at all when unset, so fork-sandbox.sh's own resolution
    # (or refusal) applies exactly as it would for any other caller.
    if [[ "$harness" == claude ]]; then
        model="${model:-sonnet}"
    fi
    network="${network:-pinned}"

    local run_id
    run_id="$(pm_new_uuid)"
    mkdir -p -- "$SEQ"
    local seq
    seq="$(pm_next_seq "$tid")"
    local branch="sbx-mail-${tid:0:8}-${agent}-${seq}"

    mkdir -p -- "$HANDOFFS"
    local handoff_file="$HANDOFFS/$run_id.md"
    pm_write_handoff "$handoff_file" "$agent" "$persona_path" "$tid" "$mid"

    local -a spawn_args=(--branch "$branch" --harness "$harness" --network "$network")
    [[ -n "$model" ]] && spawn_args+=(--model "$model")
    if [[ "$harness" == pi && -n "$thinking" ]]; then
        spawn_args+=(--pi-args "--thinking $thinking")
    fi

    # An agent woken again and again on one thread should be ONE
    # conversation, not a series of amnesiacs. The transcript store for
    # this (thread, agent) pair is bound into every claude wake of it; the
    # id the last wake ended on, if harvest recorded one, resumes it.
    # Other harnesses get neither flag -- fork-sandbox.sh refuses both
    # there.
    local resumed=""
    if [[ "$harness" == claude ]]; then
        spawn_args+=(--session-state "$PM_SESSION_STATE/$tid/$agent")
        local sid_file="$PM_SESSIONS/$tid/$agent" sid
        if [[ -f "$sid_file" ]]; then
            sid="$(pm_trim "$(cat -- "$sid_file" 2>/dev/null)")"
            if [[ "$sid" =~ $PM_SESSION_ID_RE ]]; then
                spawn_args+=(--resume-session "$sid")
                resumed="$sid"
            fi
        fi
    fi

    local launch_out rc run_dir
    set +e
    launch_out="$("$FORK_SANDBOX" "${spawn_args[@]}" "$project" "$handoff_file" 2>&1)"
    rc=$?
    set -e
    run_dir="$(printf '%s\n' "$launch_out" | sed -n 's/^  run dir:  *//p' | head -n1)"
    if (( rc != 0 )) || [[ -z "$run_dir" ]]; then
        echo "Error: postmaster: launching $agent for thread $tid failed:" >&2
        printf '%s\n' "$launch_out" >&2
        pm_flag "$tid" "spawn failed for $agent: $mid"
        return 0
    fi

    mkdir -p -- "$RUNS"
    {
        printf 'AGENT=%s\n' "$agent"
        printf 'THREAD=%s\n' "$tid"
        printf 'TRIGGER=%s\n' "$mid"
        printf 'RUN_DIR=%s\n' "$run_dir"
        printf 'BRANCH=%s\n' "$branch"
        printf 'RESUMED=%s\n' "$resumed"
        printf 'PENDING_MSGS=\n'
    } > "$RUNS/$run_id.env"
    mkdir -p -- "$SPAWNS" "$SEQ"
    printf '%s\n' "$run_id" >> "$SPAWNS/$tid"
    printf '%s\n' "$run_id" >> "$SEQ/$tid"
}

pm_wake_or_pend() {
    local project="$1" agent="$2" tid="$3" mid="$4"
    local run_id
    if run_id="$(pm_find_live_run "$agent" "$tid")"; then
        pm_append_pending "$run_id" "$mid"
    else
        pm_spawn_wake "$project" "$agent" "$tid" "$mid"
    fi
}

# ---- route pass ----

pm_process_message() {
    local project="$1" f="$2"
    local mid tid from to x_hops
    mkdir -p -- "$ROUTED"
    mid="$(pm_header "$f" Message-ID)"
    [[ -e "$ROUTED/$mid" ]] && return 0
    tid="$(pm_header "$f" Thread-ID)"
    from="$(pm_header "$f" From)"
    to="$(pm_header "$f" To)"
    x_hops="$(pm_header "$f" X-Hops)"
    local from_name="${from#@}"

    if ! "$FLEET" resolve "$from_name" >/dev/null 2>&1; then
        # rule 1: operator/external mail resets the thread before rules 2-3.
        pm_unflag "$tid"
        mkdir -p -- "$SPAWNS"
        : > "$SPAWNS/$tid"
    fi

    local gate_reason=""
    if [[ "$x_hops" == "0" ]]; then
        gate_reason="hops exhausted at $mid"
    else
        local budget="${FORK_SANDBOX_THREAD_BUDGET:-12}" count
        count="$(pm_spawn_count "$tid")"
        if (( count >= budget )); then
            gate_reason="thread budget $budget exhausted"
        fi
    fi

    local -a candidates=()
    if [[ -z "$gate_reason" ]]; then
        local -a expanded=()
        mapfile -t expanded < <(pm_expand_to "$to")
        local cand
        for cand in "${expanded[@]}"; do
            [[ -n "$cand" ]] || continue
            [[ "$cand" == "$from_name" ]] && continue
            candidates+=("$cand")
        done
    fi

    : > "$ROUTED/$mid"

    if [[ -n "$gate_reason" ]]; then
        pm_flag "$tid" "$gate_reason"
        return 0
    fi

    local agent
    for agent in "${candidates[@]}"; do
        [[ -n "$agent" ]] || continue
        pm_wake_or_pend "$project" "$agent" "$tid" "$mid"
    done
}

pm_route_pass() {
    local project="$1" f
    for f in "$MAIL_ROOT"/threads/*/*.msg; do
        [[ -e "$f" ]] || continue
        pm_process_message "$project" "$f"
    done
}

# ---- harvest pass ----

# Parses one mail-*.md reply file: header stanza (To/Cc/Subject/
# Reply-To-Id, each optional), a blank line, then the body verbatim.
# Prints four tab-separated fields (to, cc, subject, reply_to_id) on
# success and writes the body to $2; returns 1 on any parse problem.
pm_parse_reply_file() {
    local mf="$1" body_out="$2"
    local to="" cc="" subject="" reply_to_id="" line in_body=0
    : > "$body_out"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( in_body )); then
            printf '%s\n' "$line" >> "$body_out"
            continue
        fi
        if [[ -z "$line" ]]; then
            in_body=1
            continue
        fi
        case "$line" in
            To:*) to="$(pm_trim "${line#To:}")" ;;
            Cc:*) cc="$(pm_trim "${line#Cc:}")" ;;
            Subject:*) subject="$(pm_trim "${line#Subject:}")" ;;
            Reply-To-Id:*) reply_to_id="$(pm_trim "${line#Reply-To-Id:}")" ;;
            *) return 1 ;;
        esac
    done < "$mf"
    (( in_body )) || return 1
    if [[ -n "$to" ]]; then
        local -a parts a
        IFS=',' read -ra parts <<< "$to"
        for a in "${parts[@]}"; do
            [[ "$(pm_trim "$a")" =~ $PM_ADDR_RE ]] || return 1
        done
    fi
    if [[ -n "$cc" ]]; then
        local -a partsc ac
        IFS=',' read -ra partsc <<< "$cc"
        for ac in "${partsc[@]}"; do
            [[ "$(pm_trim "$ac")" =~ $PM_ADDR_RE ]] || return 1
        done
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$to" "$cc" "$subject" "$reply_to_id"
    return 0
}

pm_harvest_one_file() {
    local mf="$1" agent="$2" tid="$3" trigger="$4" decremented="$5"
    local body_file parsed
    body_file="$(mktemp "$MAIL_ROOT/.postmaster.body.XXXXXX")"
    if ! parsed="$(pm_parse_reply_file "$mf" "$body_file")"; then
        rm -f -- "$body_file"
        pm_flag "$tid" "malformed reply file $(basename -- "$mf"): unparseable header stanza"
        return 0
    fi
    local to cc subject reply_to_id
    # \x1f, not \t: bash's `read` collapses runs of IFS-whitespace
    # delimiters (tab counts, even set alone), so an empty Cc field would
    # merge with its neighboring delimiter and shift every field after it.
    IFS=$'\x1f' read -r to cc subject reply_to_id <<< "$parsed"
    [[ -n "$reply_to_id" ]] || reply_to_id="$trigger"

    local -a cmd=()
    local rc=0
    if [[ "$reply_to_id" == "new" ]]; then
        if [[ -z "$to" || -z "$subject" ]]; then
            rm -f -- "$body_file"
            pm_flag "$tid" "malformed reply file $(basename -- "$mf"): Reply-To-Id: new requires To and Subject"
            return 0
        fi
        cmd=("$MAIL" send --from "@$agent" --to "$to" --subject "$subject" --body "$body_file" --hops "$decremented")
        [[ -n "$cc" ]] && cmd+=(--cc "$cc")
    else
        cmd=("$MAIL" reply --from "@$agent" --reply-to "$reply_to_id" --body "$body_file" --hops "$decremented")
        [[ -n "$to" ]] && cmd+=(--to "$to")
        [[ -n "$cc" ]] && cmd+=(--cc "$cc")
        [[ -n "$subject" ]] && cmd+=(--subject "$subject")
    fi

    if ! "${cmd[@]}" >/dev/null 2>"$body_file.err"; then
        rc=1
    fi
    local err_out=""
    [[ -f "$body_file.err" ]] && err_out="$(cat -- "$body_file.err")"
    rm -f -- "$body_file" "$body_file.err"

    if (( rc != 0 )); then
        pm_flag "$tid" "malformed reply file $(basename -- "$mf"): $err_out"
    fi
}

pm_followup_wake() {
    local project="$1" agent="$2" tid="$3" mid="$4" f
    f="$(pm_find_by_id "$mid" || true)"
    if [[ -z "$f" ]]; then
        pm_flag "$tid" "pending message $mid vanished before follow-up wake"
        return 0
    fi
    local x_hops
    x_hops="$(pm_header "$f" X-Hops)"
    if [[ "$x_hops" == "0" ]]; then
        pm_flag "$tid" "hops exhausted at $mid"
        return 0
    fi
    local budget="${FORK_SANDBOX_THREAD_BUDGET:-12}" count
    count="$(pm_spawn_count "$tid")"
    if (( count >= budget )); then
        pm_flag "$tid" "thread budget $budget exhausted"
        return 0
    fi
    pm_spawn_wake "$project" "$agent" "$tid" "$mid"
}

# A tracked run's pid file, once dead and past a grace period, is the one
# other crash shape this script can tell apart from "still running": a wake
# whose tmux session was killed, or whose host rebooted, never writes
# exit-code, so a naive "does exit-code exist yet" check would leave
# pm_find_live_run treating it as live forever. The grace (default 60s,
# overridable for tests) covers an exit-code write still in flight when this
# runs -- fork-sandbox.sh writes the pid file once, at the very start of the
# run, and exit-code strictly before its process exits, so a fresh run
# reads as "recent" here even though kill -0 has nothing to check yet.
#
# Residual gap: a pid recycled by the OS onto a live, unrelated process
# *within the same boot* reads as "alive" here, so detection waits for
# THAT process to exit too. Vanishingly rare in practice (pid reuse needs
# the full pid space to wrap), and the same gap `fork-sandbox-status.sh`'s
# "abandoned" state and `fork-sandbox-say.sh` already accept for the
# identical check. A reboot does NOT fall into this residual gap even
# though the pid counter restarts from the bottom: run dirs live under
# /var/tmp/claude-scratch and survive a reboot, so the check below also
# rejects a pid file older than the current boot outright, since whatever
# it names now cannot be the process that wrote it.
FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE="${FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE:-60}"

# /proc/stat's own boot time, read from the real file by default;
# overridable so the test suite can fake a reboot with a fixture file
# instead of actually rebooting the host it runs on.
FORK_SANDBOX_POSTMASTER_PROC_STAT="${FORK_SANDBOX_POSTMASTER_PROC_STAT:-/proc/stat}"

pm_wake_is_dead() {
    local run_dir="$1" env_file="$2"
    local pid_file="$run_dir/pid" now ref_mtime pid btime
    now="$(date +%s)"
    btime="$(awk '/^btime /{print $2}' "$FORK_SANDBOX_POSTMASTER_PROC_STAT" 2>/dev/null)"
    [[ "$btime" =~ ^[0-9]+$ ]] || btime=""
    if pid="$(cat -- "$pid_file" 2>/dev/null)"; then
        pid="$(pm_trim "$pid")"
        ref_mtime="$("$FS_STAT" -c %Y -- "$pid_file" 2>/dev/null)" || ref_mtime="$now"
        if [[ -n "$btime" && "$ref_mtime" -lt "$btime" ]]; then
            : # pid file predates this boot; the pid it names, even if
              # live, belongs to a different boot's process table and
              # cannot be this run's own process.
        elif [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
    else
        # Missing or unreadable: no pid was ever recorded. Age it off the
        # .env file instead, written at spawn time, moments before the run
        # itself would have written the pid file.
        ref_mtime="$("$FS_STAT" -c %Y -- "$env_file" 2>/dev/null)" || ref_mtime="$now"
    fi
    (( now - ref_mtime >= FORK_SANDBOX_POSTMASTER_WAKE_DEAD_GRACE ))
}

pm_harvest_run() {
    local project="$1" rid="$2"
    local f="$RUNS/$rid.env"
    local agent tid trigger run_dir
    agent="$(pm_env_get "$f" AGENT)"
    tid="$(pm_env_get "$f" THREAD)"
    trigger="$(pm_env_get "$f" TRIGGER)"
    run_dir="$(pm_env_get "$f" RUN_DIR)"
    if [[ ! -d "$run_dir" ]]; then
        # Vanished (scratch root cleaned up, or never existed) rather than
        # merely still running -- this is the one crash shape distinct
        # from "not done yet" that this script can actually detect without
        # a timeout or a tracked pid (see LIMITATIONS), so it is treated
        # as a terminal failure: flag the thread and unblock the agent
        # instead of leaving pm_find_live_run wedged on it forever.
        pm_flag "$tid" "run dir for $agent vanished before exit-code appeared (run $rid)"
        # No summary.json to read, and the store this seat resumes from
        # sits under the same scratch root that just lost the run dir.
        # Start the next wake fresh rather than point it at an id nothing
        # can be said about.
        pm_session_clear "$tid" "$agent"
        mkdir -p -- "$HARVESTED"
        : > "$HARVESTED/$rid"
        return 0
    fi
    if [[ ! -f "$run_dir/summary.json" ]]; then
        # summary.json is fork-sandbox.sh's last artifact -- written after
        # run_cleanup and the branch fetch-back, well after exit-code (and,
        # for a --review-loop run, after exit-code is even published). A
        # run can sit with exit-code present and summary.json still absent
        # while it finishes archiving and fetching back; that window is
        # "not done yet", exactly like no exit-code at all, not a crash.
        if ! pm_wake_is_dead "$run_dir" "$f"; then
            return 0
        fi
        # Same crash shape as a non-zero exit code below -- no summary.json
        # ever landed, but the outbox is a host directory bind-mounted rw
        # into the sandbox, so a reply the agent finished composing before
        # the runner died is already on disk. Flag the thread, forget the
        # session (a wake that never finished is exactly the case where
        # the recorded id is the suspect), and fall through to the shared
        # outbox-harvest and pending-message handling below rather than
        # discarding both.
        pm_flag "$tid" "wake died without exit-code: $rid"
        pm_session_clear "$tid" "$agent"
    else
        local exit_code
        exit_code="$(pm_trim "$(cat -- "$run_dir/exit-code" 2>/dev/null)")"
        if [[ "$exit_code" != "0" ]]; then
            # Harvest whatever outbox there is (a crash mid-reply may still
            # have written a file), but flag regardless: an empty outbox from
            # a non-zero exit is a failure, not the documented "no reply is a
            # valid outcome".
            pm_flag "$tid" "wake for $agent exited $exit_code (run $rid); outbox may be incomplete"
            # ...and forget the session, so the next wake of this seat is a
            # fresh one. A failed resumed wake is exactly the case where the
            # recorded id is the suspect.
            pm_session_clear "$tid" "$agent"
        else
            # Which session the next wake should resume. Absent (no
            # --session-state on this seat, or no jq on the host) or null
            # clears the recorded id outright -- a resume pointer with no
            # transcript behind it is worse than a fresh wake. A malformed
            # (present but not id-shaped) value leaves whatever was
            # recorded before standing, since that shape should never come
            # from the launcher itself.
            local sid
            sid="$(pm_trim "$(jq -r '.session_id // empty' \
                "$run_dir/summary.json" 2>/dev/null || true)")"
            if [[ "$sid" =~ $PM_SESSION_ID_RE ]]; then
                pm_session_record "$tid" "$agent" "$sid"
            elif [[ -z "$sid" ]]; then
                pm_session_clear "$tid" "$agent"
            fi
        fi
    fi

    local trigger_file trigger_hops decremented
    trigger_file="$(pm_find_by_id "$trigger" || true)"
    trigger_hops="0"
    [[ -n "$trigger_file" ]] && trigger_hops="$(pm_header "$trigger_file" X-Hops)"
    [[ "$trigger_hops" =~ ^[0-9]+$ ]] || trigger_hops=0
    decremented=$(( trigger_hops > 0 ? trigger_hops - 1 : 0 ))

    local mf
    for mf in "$run_dir/outbox"/mail-*.md; do
        [[ -e "$mf" ]] || continue
        pm_harvest_one_file "$mf" "$agent" "$tid" "$trigger" "$decremented"
    done

    mkdir -p -- "$HARVESTED"
    : > "$HARVESTED/$rid"

    local pending
    pending="$(pm_env_get "$f" PENDING_MSGS)"
    if [[ -n "$pending" ]]; then
        local newest="${pending##*,}"
        pm_followup_wake "$project" "$agent" "$tid" "$newest"
    fi
}

pm_harvest_pass() {
    local project="$1" f rid
    mkdir -p -- "$RUNS" "$HARVESTED"
    for f in "$RUNS"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$HARVESTED/$rid" ]] && continue
        pm_harvest_run "$project" "$rid"
    done
}

# ---- verbs ----

cmd_deliver() {
    local project="" once=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="${2:?--project requires a path}"; shift 2 ;;
            --once) once=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Error: deliver: unknown option '$1'." >&2; return 1 ;;
        esac
    done
    [[ -n "$project" ]] || { echo "Error: deliver: --project is required." >&2; return 1; }

    # HANDOFFS sits under $FORK_SANDBOX_MAIL_ROOT, a first-class env key an
    # operator can point anywhere -- but every wake stages its handoff there
    # and hands it to fork-sandbox.sh, which refuses any handoff outside
    # /var/tmp/claude-scratch (or the /tmp/claude-scratch compat symlink) and
    # excludes forks/ within it (fs_require_scratch_handoff, fork-sandbox-lib.sh).
    # Checked once here, at startup, so a bad root fails with this explanation
    # instead of every single spawn dying with "spawn failed for <agent>: <mid>"
    # and the real reason buried in the deliver loop's stderr.
    fs_require_scratch_handoff "$HANDOFFS/probe.md" || return 1

    mkdir -p -- "$MAIL_ROOT" "$STATE"
    pm_lock_acquire || return 1
    trap pm_lock_release EXIT

    if (( once )); then
        pm_route_pass "$project"
        pm_harvest_pass "$project"
        return 0
    fi

    local stop=0
    trap 'stop=1' TERM INT
    while (( ! stop )); do
        pm_route_pass "$project"
        pm_harvest_pass "$project"
        (( stop )) && break
        sleep "${FORK_SANDBOX_POSTMASTER_INTERVAL:-15}" || true
    done
    pm_lock_release
    trap - EXIT TERM INT
    exit 0
}

cmd_status() {
    mkdir -p -- "$MAIL_ROOT" "$ROUTED" "$RUNS" "$HARVESTED" "$NEEDS_OPERATOR" "$SPAWNS"

    local total=0 routed_count=0 f
    for f in "$MAIL_ROOT"/threads/*/*.msg; do
        [[ -e "$f" ]] || continue
        total=$(( total + 1 ))
    done
    for f in "$ROUTED"/*; do
        [[ -e "$f" ]] || continue
        routed_count=$(( routed_count + 1 ))
    done
    printf 'unrouted: %s\n' "$(( total - routed_count ))"

    printf '\nlive runs:\n'
    local any_live=0 rid agent tid run_dir resumed session
    for f in "$RUNS"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$HARVESTED/$rid" ]] && continue
        agent="$(pm_env_get "$f" AGENT)"
        tid="$(pm_env_get "$f" THREAD)"
        run_dir="$(pm_env_get "$f" RUN_DIR)"
        # Read off the .env the spawn wrote, not the sessions file: that
        # one moves under a live run, and what this column reports is how
        # THIS wake was launched. A run spawned before the field existed
        # has no RESUMED line and reads as fresh, which it was.
        resumed="$(pm_env_get "$f" RESUMED)"
        if [[ -n "$resumed" ]]; then
            session="resumed=$resumed"
        else
            session="session=fresh"
        fi
        printf '  %s  agent=%s thread=%s %s run_dir=%s\n' \
            "$rid" "$agent" "$tid" "$session" "$run_dir"
        any_live=1
    done
    (( any_live )) || printf '  (none)\n'

    printf '\nneeds-operator:\n'
    local any_flag=0 tid_f reason
    for f in "$NEEDS_OPERATOR"/*; do
        [[ -e "$f" ]] || continue
        tid_f="$(basename -- "$f")"
        reason="$(cat -- "$f")"
        printf '  %s: %s\n' "$tid_f" "$reason"
        any_flag=1
    done
    (( any_flag )) || printf '  (none)\n'

    printf '\nspawns per thread:\n'
    local any_spawn=0 n
    for f in "$SPAWNS"/*; do
        [[ -e "$f" ]] || continue
        tid_f="$(basename -- "$f")"
        n="$(wc -l < "$f")"
        printf '  %s: %s spawns\n' "$tid_f" "$n"
        any_spawn=1
    done
    (( any_spawn )) || printf '  (none)\n'
}

cmd_flag() {
    local tid="${1:?Usage: fork-sandbox-postmaster.sh flag <thread-id> [reason]}"
    local reason="${2:-flagged by operator}"
    mkdir -p -- "$STATE"
    pm_flag "$tid" "$reason"
}

cmd_unflag() {
    local tid="${1:?Usage: fork-sandbox-postmaster.sh unflag <thread-id>}"
    mkdir -p -- "$STATE"
    pm_unflag "$tid"
}

if (($# == 0)); then
    usage >&2
    exit 2
fi

if [[ "$1" == '-h' || "$1" == '--help' ]]; then
    usage
    exit 0
fi

verb="$1"
shift

case "$verb" in
    deliver) cmd_deliver "$@" ;;
    status) cmd_status "$@" ;;
    flag) cmd_flag "$@" ;;
    unflag) cmd_unflag "$@" ;;
    *)
        printf "fork-sandbox-postmaster: unknown verb '%s'\n" "$verb" >&2
        printf '%s\n' 'Verbs: deliver status flag unflag' >&2
        exit 2
        ;;
esac
