#!/usr/bin/env bash
# fork-sandbox-fleet.sh — Registry of who the fleet's agents are: what
# harness/model/network/thinking seat each runs on, and which lists name
# groups of them
#
# Usage: fork-sandbox-fleet.sh check
#        fork-sandbox-fleet.sh resolve <name>
#        fork-sandbox-fleet.sh expand <addr>[,<addr>...]
#        fork-sandbox-fleet.sh roster
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
#   check          Validate the fleet file and every persona file it
#                  declares. Exits 0 silently if clean; otherwise prints
#                  every error found (not just the first) and exits 1.
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

cmd_resolve() {
    local name="${1:?Usage: fork-sandbox-fleet.sh resolve <name>}"
    fleet_validate_name "$name" || return 1

    local dump; dump="$(fleet_dump)"
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

    echo "Agents:"
    local name harness model thinking network persona description
    for name in "${agent_names[@]}"; do
        { read -r harness; read -r model; read -r thinking; read -r network; \
          read -r persona; read -r description; } < <(cmd_resolve "$name")
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

case "${1-}" in
    -h|--help) usage; exit 0 ;;
    check) shift; cmd_check "$@" ;;
    resolve) shift; cmd_resolve "$@" ;;
    expand) shift; cmd_expand "$@" ;;
    roster) shift; cmd_roster "$@" ;;
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
