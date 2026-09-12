#!/usr/bin/env bash
# fork-sandbox-fleet.sh — Registry of who the fleet's agents are: what
# harness/model/network/thinking seat each runs on, and which lists name
# groups of them
#
# Usage: fork-sandbox-fleet.sh check
#        fork-sandbox-fleet.sh resolve <name>
#        fork-sandbox-fleet.sh expand <addr>[,<addr>...]
#        fork-sandbox-fleet.sh roster
#        fork-sandbox-fleet.sh teardown <agent> [--thread <id>]
#        fork-sandbox-fleet.sh teardown --all
#
# Two sources of truth, machine config over content:
#
#   - Persona files, <personas-dir>/<name>.md: a markdown body (the
#     agent's standing instructions, opaque to this script) with an
#     optional YAML frontmatter block carrying `description`, `harness`,
#     `model`, `network` (pinned|sealed) and `thinking`.
#     $FORK_SANDBOX_PERSONAS_DIR, default ~/.config/fork-sandbox/personas.
#   - The fleet file, a YAML mapping of `agents` (name -> optional
#     persona/harness/model/network/thinking overrides) and `lists`
#     (name -> members, a list of agent names). $FORK_SANDBOX_FLEET_FILE,
#     default ~/.config/fork-sandbox/fleet.yaml.
#
# Precedence per seat field is fleet.yaml agent entry, then persona
# frontmatter, then empty -- applied here in bash, not by the parser.
# Resolution reports what is configured and applies no defaults; a
# defaulting policy belongs to whatever consults this registry, not to
# it. An agent may resolve with every field empty; that is valid output,
# not an error.
#
# This is a registry, not a router or a store: it has no idea what
# fork-sandbox-mail.sh's message store holds, and never touches it.
# `expand` turns a `@list` address into its member `@agent` addresses
# ONLY at the moment it is called -- a message already sitting in the
# mail store keeps whatever address it was sent `To:`, list or agent,
# unexpanded, exactly like a real mailing-list archive keeps
# "To: list@example.com" rather than rewriting it to every subscriber.
# Expanding at send time or at read time is a router's job (a later
# round), not this script's.
#
# Verbs:
#
#   check          Validate the fleet file, every persona file it
#                  declares, and every bare <name>.md in the personas
#                  directory that makes `name` an agent on its own (see
#                  fleet_is_agent below). Exits 0 silently if clean;
#                  otherwise prints every error found (not just the
#                  first) and exits 1.
#   resolve <name> Print exactly six lines for one agent: harness, model,
#                  thinking, network, persona-path, description. A field
#                  with nothing configured anywhere prints as an empty
#                  line -- output is always six lines, never fewer.
#   expand <addr>[,<addr>...]
#                  Expand a comma-separated list of @-addresses: a
#                  `@list` becomes its members' `@agent` addresses, a
#                  `@agent` passes through unchanged. Output is deduped
#                  by first-seen position, one address per line.
#   roster         Human-readable summary: every agent with its resolved
#                  seat, every list with its members.
#   teardown <agent> [--thread <id>]
#   teardown --all
#                  Destroy persistent (thread, agent) seat state: the
#                  workspace clone, the session record, and the session
#                  state dir under the postmaster's mail root (see
#                  fork-sandbox-postmaster.sh's STATE table). <agent> alone
#                  tears down every thread that agent has a seat on;
#                  --thread narrows to one seat (validated the same way
#                  <agent> is -- a single path component, so it cannot walk
#                  the removal outside the state tree); --all tears down
#                  every seat found. Refuses (naming the run) any seat with
#                  a live, not-yet-harvested run rather than pull a
#                  workspace out from under a running sandbox; a --all or
#                  bare-<agent> sweep still tears down every OTHER named
#                  seat and reports the refusal alongside them. That check
#                  is bookkeeping (runs/*.env), which the postmaster writes
#                  only after a spawn returns, so it is backstopped by a
#                  non-blocking probe of the workspace's OWN flock (the same
#                  one fork-sandbox.sh takes for the run's lifetime) --
#                  authoritative for a workspace already mid-clone, when no
#                  runs/*.env exists yet to read. The whole verb also holds
#                  the postmaster's own lock for its duration, so it cannot
#                  run against a mid-flight routing pass. Removing nothing
#                  is success, not an error. This is the one verb in this
#                  script that reads postmaster state
#                  ($FORK_SANDBOX_MAIL_ROOT/.postmaster) -- a deliberate,
#                  narrow exception (it is a fleet-lifecycle operation a
#                  user looks for on the fleet verb); no other verb here
#                  knows the store or the router exist.
#
# A missing fleet file is not an error by itself: `expand`/`resolve` of a
# bare agent still work from persona files alone (a personas directory
# with no fleet file is a valid fleet of unlisted agents). `check` and
# `roster`, which report on the fleet file as a whole, require it to
# exist and fail otherwise. Symmetrically, a missing personas directory
# only matters to the verbs that need to read a persona file.

set -euo pipefail

FLEET_FILE="${FORK_SANDBOX_FLEET_FILE:-$HOME/.config/fork-sandbox/fleet.yaml}"
PERSONAS_DIR="${FORK_SANDBOX_PERSONAS_DIR:-$HOME/.config/fork-sandbox/personas}"
FLEET_NAME_RE='^[a-z0-9][a-z0-9-]*$'
FLEET_ADDR_RE='^@[a-z0-9][a-z0-9-]*$'

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PARSE="$script_dir/fork-sandbox-fleet-parse.py"

usage() {
    # The header block is the documentation: print it from line 2 down to
    # the first non-comment line.
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
}

fleet_validate_name() {
    if [[ ! "$1" =~ $FLEET_NAME_RE ]]; then
        echo "Error: '$1' is not a valid name; names are lowercase" >&2
        echo "alphanumeric and '-' only, no leading '-'." >&2
        return 1
    fi
    return 0
}

# --thread is used as a single path component under three state trees
# (PM_WORKSPACES/$tid/$agent and friends), the same way <agent> is. Unlike
# an agent name, a thread id is not this script's to shape -- it comes from
# whatever mail source the postmaster reads -- so this only rejects what
# would escape that one path component, not what it may contain otherwise.
fleet_validate_thread() {
    if [[ -z "$1" || "$1" == */* || "$1" == "." || "$1" == ".." ]]; then
        echo "Error: '$1' is not a valid thread id; it must be a single" >&2
        echo "path component -- no '/', and not '.' or '..'." >&2
        return 1
    fi
    return 0
}

cmd_check() {
    if [[ ! -f "$FLEET_FILE" ]]; then
        echo "Error: check: no fleet file at '$FLEET_FILE'." >&2
        return 1
    fi
    if [[ ! -d "$PERSONAS_DIR" ]]; then
        echo "Error: check: no personas dir at '$PERSONAS_DIR'." >&2
        return 1
    fi
    python3 "$PARSE" check "$FLEET_FILE" "$FLEET_FILE" "$PERSONAS_DIR"
}

# Runs `dump` against $FLEET_FILE if it exists, else prints nothing. Both
# `resolve` and `expand` need this same TSV once each.
fleet_dump() {
    [[ -f "$FLEET_FILE" ]] || return 0
    python3 "$PARSE" dump "$FLEET_FILE" "$FLEET_FILE"
}

# Populates fleet_<field> globals from a dump for one agent name. Sets
# agent_declared=1 if the name appears in the dump as an agent at all.
fleet_read_agent() {
    local dump="$1" name="$2" kind aname field value
    fleet_persona="" fleet_harness="" fleet_model=""
    fleet_network="" fleet_thinking="" fleet_description=""
    agent_declared=0
    [[ -n "$dump" ]] || return 0
    while IFS=$'\t' read -r kind aname field value; do
        [[ "$kind" == agent && "$aname" == "$name" ]] || continue
        agent_declared=1
        case "$field" in
            persona) fleet_persona="$value" ;;
            harness) fleet_harness="$value" ;;
            model) fleet_model="$value" ;;
            network) fleet_network="$value" ;;
            thinking) fleet_thinking="$value" ;;
            description) fleet_description="$value" ;;
        esac
    done <<< "$dump"
}

# Populates fm_<field> globals from a persona file's frontmatter.
fleet_read_frontmatter() {
    local persona_path="$1" out field value
    fm_harness="" fm_model="" fm_network="" fm_thinking="" fm_description=""
    out="$(python3 "$PARSE" frontmatter "$persona_path" "$persona_path")"
    while IFS=$'\t' read -r _ field value; do
        case "$field" in
            harness) fm_harness="$value" ;;
            model) fm_model="$value" ;;
            network) fm_network="$value" ;;
            thinking) fm_thinking="$value" ;;
            description) fm_description="$value" ;;
        esac
    done <<< "$out"
}

# Core of `resolve`, given an already-computed dump (a caller doing many
# resolutions, like `roster`, computes the dump once and passes it here
# instead of paying a full YAML parse per agent).
resolve_with_dump() {
    local dump="$1" name="$2"
    fleet_validate_name "$name" || return 1

    fleet_read_agent "$dump" "$name"

    local persona_path="$PERSONAS_DIR/${fleet_persona:-$name.md}"
    local fm_harness="" fm_model="" fm_network="" fm_thinking="" fm_description=""
    if [[ -f "$persona_path" ]]; then
        fleet_read_frontmatter "$persona_path"
    elif (( ! agent_declared )); then
        echo "Error: resolve: unknown agent '$name' (no fleet.yaml entry" >&2
        echo "and no persona file '$persona_path')." >&2
        return 1
    fi

    printf '%s\n' "${fleet_harness:-$fm_harness}"
    printf '%s\n' "${fleet_model:-$fm_model}"
    printf '%s\n' "${fleet_thinking:-$fm_thinking}"
    printf '%s\n' "${fleet_network:-$fm_network}"
    printf '%s\n' "$persona_path"
    printf '%s\n' "${fleet_description:-$fm_description}"
}

cmd_resolve() {
    local name="${1:?Usage: fork-sandbox-fleet.sh resolve <name>}"
    local dump; dump="$(fleet_dump)"
    resolve_with_dump "$dump" "$name"
}

fleet_is_list() {
    local dump="$1" name="$2"
    [[ -n "$dump" ]] && grep -qx "list"$'\t'"$name" <<< "$dump"
}

fleet_is_agent() {
    local dump="$1" name="$2"
    { [[ -n "$dump" ]] && grep -q "^agent"$'\t'"$name"$'\t' <<< "$dump"; } \
        || [[ -f "$PERSONAS_DIR/$name.md" ]]
}

fleet_list_members() {
    local dump="$1" name="$2"
    grep "^list_member"$'\t'"$name"$'\t' <<< "$dump" | cut -f3
}

cmd_expand() {
    local input="${1:?Usage: fork-sandbox-fleet.sh expand <addr>[,<addr>...]}"
    local dump; dump="$(fleet_dump)"

    local -a addrs result=()
    IFS=',' read -ra addrs <<< "$input"
    local addr name already existing m
    for addr in "${addrs[@]}"; do
        # mail_validate_addr_list (fork-sandbox-mail.sh) normalizes stored
        # To:/Cc: headers as ", "-joined; strip that surrounding
        # whitespace here so expand can consume its own canonical input.
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"
        if [[ ! "$addr" =~ $FLEET_ADDR_RE ]]; then
            echo "Error: expand: '$addr' is not a valid address; addresses" >&2
            echo "look like '@name', lowercase alphanumeric and '-' only." >&2
            return 1
        fi
        name="${addr#@}"
        if fleet_is_list "$dump" "$name"; then
            while IFS= read -r m; do
                [[ -n "$m" ]] || continue
                already=0
                for existing in "${result[@]:-}"; do
                    [[ "$existing" == "@$m" ]] && { already=1; break; }
                done
                (( already )) || result+=("@$m")
            done < <(fleet_list_members "$dump" "$name")
        elif fleet_is_agent "$dump" "$name"; then
            already=0
            for existing in "${result[@]:-}"; do
                [[ "$existing" == "$addr" ]] && { already=1; break; }
            done
            (( already )) || result+=("$addr")
        else
            echo "Error: expand: unknown address '$addr'." >&2
            return 1
        fi
    done
    printf '%s\n' "${result[@]:-}"
}

cmd_roster() {
    if [[ ! -f "$FLEET_FILE" ]]; then
        echo "Error: roster: no fleet file at '$FLEET_FILE'." >&2
        return 1
    fi
    if [[ ! -d "$PERSONAS_DIR" ]]; then
        echo "Error: roster: no personas dir at '$PERSONAS_DIR'." >&2
        return 1
    fi
    local dump; dump="$(fleet_dump)"

    local -a agent_names=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && agent_names+=("$n")
    done < <(awk -F'\t' '$1=="agent"{print $2}' <<< "$dump" | awk '!seen[$0]++')

    # fleet_is_agent treats a bare <name>.md under personas-dir as making
    # `name` an agent with no fleet.yaml entry at all; roster's "every
    # agent" promise needs those names too, or they stay invisible here
    # exactly like they do in `check`.
    local f loner already existing
    for f in "$PERSONAS_DIR"/*.md; do
        [[ -e "$f" ]] || continue
        loner="$(basename "$f" .md)"
        [[ "$loner" =~ $FLEET_NAME_RE ]] || continue
        fleet_is_list "$dump" "$loner" && continue
        already=0
        for existing in "${agent_names[@]:-}"; do
            [[ "$existing" == "$loner" ]] && { already=1; break; }
        done
        (( already )) || agent_names+=("$loner")
    done

    echo "Agents:"
    local name harness model thinking network persona description
    for name in "${agent_names[@]}"; do
        { read -r harness; read -r model; read -r thinking; read -r network; \
          read -r persona; read -r description; } < <(resolve_with_dump "$dump" "$name")
        printf '  %-20s harness=%-8s model=%-12s thinking=%-8s network=%-8s persona=%s%s\n' \
            "$name" "${harness:--}" "${model:--}" "${thinking:--}" \
            "${network:--}" "$persona" "${description:+  # $description}"
    done

    local -a list_names=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && list_names+=("$n")
    done < <(awk -F'\t' '$1=="list"{print $2}' <<< "$dump" | awk '!seen[$0]++')

    echo "Lists:"
    local members
    for name in "${list_names[@]}"; do
        members="$(fleet_list_members "$dump" "$name" | paste -sd, -)"
        printf '  %-20s members=%s\n' "$name" "$members"
    done
}

# ---- teardown (decision: the one narrow exception where this registry
# reads postmaster state -- see the header comment above cmd_teardown's
# entry in the Verbs: list) ----

# Sets MAIL_ROOT/STATE and the postmaster state paths teardown needs.
# Mirrors the same-named assignments in fork-sandbox-postmaster.sh
# exactly; duplicated rather than sourced, since sourcing that script
# would also pull in its own usage()/dispatch (decision 6: keep the
# coupling to exactly this verb).
teardown_state_paths() {
    MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"
    STATE="$MAIL_ROOT/.postmaster"
    LOCK_FILE="$STATE/lock"
    RUNS="$STATE/runs"
    HARVESTED="$STATE/harvested"
    PM_SESSION_STATE="$STATE/state"
    PM_SESSIONS="$STATE/sessions"
    PM_WORKSPACES="$STATE/workspaces"
}

# Mirrors pm_lock_acquire/pm_lock_release (fork-sandbox-postmaster.sh)
# exactly: the same flock(2) on the same file, so teardown and a routing
# pass cannot run at the same time. Non-blocking -- an operator running
# this interactively should see the conflict, not hang behind a router
# that could be mid-spawn for a while.
teardown_lock_acquire() {
    mkdir -p -- "$STATE"
    exec {teardown_lock_fd}<>"$LOCK_FILE" || return 1
    if ! flock -n "$teardown_lock_fd"; then
        local pid
        pid="$(cat -- "$LOCK_FILE" 2>/dev/null || true)"
        exec {teardown_lock_fd}>&-
        echo "Error: teardown: postmaster${pid:+" (pid $pid)"} holds the lock; try again shortly." >&2
        return 1
    fi
    # Same courtesy pm_lock_acquire extends: leave our own pid behind so a
    # postmaster that loses the race to us reports an accurate holder
    # rather than whatever pid was last written here.
    printf '%s\n' "$$" > "$LOCK_FILE"
    return 0
}

teardown_lock_release() {
    [[ -n "${teardown_lock_fd:-}" ]] || return 0
    flock -u "$teardown_lock_fd" 2>/dev/null || true
    exec {teardown_lock_fd}>&- 2>/dev/null || true
}

# A workspace's own flock (see fs_lock_clone_dir, fork-sandbox.sh) is the
# authoritative liveness signal for it: a live run holds it for its whole
# lifetime, starting BEFORE it touches the workspace's git state at all.
# runs/*.env (teardown_live_run) is written only after a spawn returns,
# i.e. after a wake may already be cloning or fetching into the workspace,
# so it alone would let a teardown race a run that has started but not yet
# been recorded. No .git yet (the workspace does not exist, or a first
# wake has not created it) means nothing to hold the lock, so there is
# nothing to probe -- not a live run.
teardown_workspace_locked() {
    local ws="$1" fd
    [[ -e "$ws/.git" ]] || return 1
    # A bare `exec {fd}<>file 2>/dev/null` redirects the WHOLE shell's
    # stderr from here on, not just this open -- exec with only
    # redirections and no command applies them to the current shell
    # permanently. Braces scope the redirect to just this open, the same
    # way a subshell would, but without losing the fd for the caller.
    { exec {fd}<>"$ws/.git/fork-sandbox-lock"; } 2>/dev/null || return 1
    if flock -n "$fd"; then
        flock -u "$fd"
        exec {fd}>&-
        return 1
    fi
    exec {fd}>&-
    return 0
}

teardown_env_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n1
}

# Prints a live run's id for (agent, tid) and returns 0, or returns 1.
# Mirrors pm_find_live_run (fork-sandbox-postmaster.sh) exactly.
teardown_live_run() {
    local agent="$1" tid="$2" f rid a t
    for f in "$RUNS"/*.env; do
        [[ -e "$f" ]] || continue
        rid="$(basename -- "$f" .env)"
        [[ -e "$HARVESTED/$rid" ]] && continue
        a="$(teardown_env_get "$f" AGENT)"
        t="$(teardown_env_get "$f" THREAD)"
        if [[ "$a" == "$agent" && "$t" == "$tid" ]]; then
            printf '%s' "$rid"
            return 0
        fi
    done
    return 1
}

# Prints "<tid>\t<agent>" for every seat found under the workspace,
# session, or session-state trees, deduped. want_agent="" means any agent
# (the --all sweep); otherwise only that agent's seats.
teardown_find_seats() {
    local want_agent="$1" base d tid agent
    local -A seen=()
    for base in "$PM_WORKSPACES" "$PM_SESSIONS" "$PM_SESSION_STATE"; do
        for d in "$base"/*/*; do
            [[ -e "$d" ]] || continue
            tid="$(basename -- "$(dirname -- "$d")")"
            agent="$(basename -- "$d")"
            [[ -n "$want_agent" && "$agent" != "$want_agent" ]] && continue
            [[ -n "${seen["$tid"$'\t'"$agent"]:-}" ]] && continue
            seen["$tid"$'\t'"$agent"]=1
            printf '%s\t%s\n' "$tid" "$agent"
        done
    done
}

# Tears down one (thread, agent) seat: the workspace clone, the session
# record, and the session state dir. Refuses a seat with a live,
# not-yet-harvested run, naming it, rather than pull a clone out from
# under a running sandbox. Always prints one line for the seat --
# "nothing to remove" is success, not silence, so an operator running
# this interactively sees confirmation either way.
teardown_seat() {
    local tid="$1" agent="$2" run_id
    local -a removed=()
    local ws="$PM_WORKSPACES/$tid/$agent"
    if run_id="$(teardown_live_run "$agent" "$tid")"; then
        echo "Error: $agent/$tid: refusing, run '$run_id' is still live." >&2
        return 1
    fi
    if teardown_workspace_locked "$ws"; then
        echo "Error: $agent/$tid: refusing, workspace '$ws' is locked by a" >&2
        echo "live run (no runs/*.env for it yet)." >&2
        return 1
    fi
    local sess="$PM_SESSIONS/$tid/$agent"
    local st="$PM_SESSION_STATE/$tid/$agent"
    [[ -e "$ws" ]] && { rm -rf -- "$ws"; removed+=("workspace"); }
    [[ -e "$sess" ]] && { rm -f -- "$sess"; removed+=("session record"); }
    [[ -e "$st" ]] && { rm -rf -- "$st"; removed+=("session state"); }
    if (( ${#removed[@]} )); then
        local joined; joined="$(IFS=', '; echo "${removed[*]}")"
        printf '%s/%s: removed %s\n' "$agent" "$tid" "$joined"
    else
        printf '%s/%s: nothing to remove\n' "$agent" "$tid"
    fi
}

cmd_teardown() {
    teardown_state_paths
    local agent="" thread=""

    if [[ "${1-}" == "--all" ]]; then
        shift
        if (( $# > 0 )); then
            echo "Error: teardown --all takes no other arguments." >&2
            return 1
        fi
    else
        agent="${1:?Usage: fork-sandbox-fleet.sh teardown <agent> [--thread <id>] | teardown --all}"
        shift
        fleet_validate_name "$agent" || return 1
        while (( $# > 0 )); do
            case "$1" in
                --thread)
                    thread="${2:?Usage: fork-sandbox-fleet.sh teardown <agent> --thread <id>}"
                    fleet_validate_thread "$thread" || return 1
                    shift 2
                    ;;
                *)
                    echo "Error: teardown: unexpected argument '$1'." >&2
                    return 1
                    ;;
            esac
        done
    fi

    local -a seats=()
    if [[ -n "$thread" ]]; then
        seats=("$thread"$'\t'"$agent")
    else
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && seats+=("$line")
        done < <(teardown_find_seats "$agent")
    fi

    if (( ${#seats[@]} == 0 )); then
        printf 'nothing to tear down.\n'
        return 0
    fi

    # Held for the whole sweep, not just its lookups: a routing pass that
    # starts partway through would otherwise see whatever half-torn-down
    # state this leaves behind.
    teardown_lock_acquire || return 1
    trap teardown_lock_release EXIT

    local rc=0 seat tid a
    for seat in "${seats[@]}"; do
        IFS=$'\t' read -r tid a <<< "$seat"
        teardown_seat "$tid" "$a" || rc=1
    done
    return "$rc"
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
    check) shift; cmd_check "$@" ;;
    resolve) shift; cmd_resolve "$@" ;;
    expand) shift; cmd_expand "$@" ;;
    roster) shift; cmd_roster "$@" ;;
    teardown) shift; cmd_teardown "$@" ;;
    "")
        usage >&2
        exit 1
        ;;
    *)
        echo "Error: unknown verb '$1'." >&2
        usage >&2
        exit 1
        ;;
esac
