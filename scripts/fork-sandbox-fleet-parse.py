#!/usr/bin/env python3
"""Parse and validate fork-sandbox's fleet file and persona frontmatter, for
fork-sandbox-fleet.sh.

Usage: fork-sandbox-fleet-parse.py check <fleet-file> <label> <personas-dir>
       fork-sandbox-fleet-parse.py dump <fleet-file> <label>
       fork-sandbox-fleet-parse.py frontmatter <persona-file> <label>

"all" (the built-in @all list) and "operator" (the human operator's mail
address -- see docs/agent-mail.md) are always-reserved names: no agent or
list may be defined with either, on either side of the agents/lists
divide, so neither can resolve as a fleet seat.

A fleet file is a YAML mapping of `agents` (name -> optional persona/
harness/model/network/thinking/description/wake-on-cc/refresh-at/triage/
handler/command overrides), `lists` (name -> `members`, a list of agent
names), and an optional top-level `triage` block (harness/model for the
wake classifier's own sandbox seat -- absent means triage is off fleet-wide.
No `network` field: the classifier's own launch path fixes its network
by harness -- sealed for pi, pinned for claude -- with nothing in the
fleet file left to override it).
A persona file is markdown with an optional YAML frontmatter block
(delimited by `---` lines) carrying the same per-agent seat keys plus
`description`, EXCEPT `handler`/`command` -- a handler seat is host
config (see below), not content, so those two are fleet.yaml-only and
refused (as unknown keys) in frontmatter; the body is opaque to this
script.

`handler: exec` marks an agent as a deterministic script seat rather
than an LLM seat: `command` (a bare name, resolved host-side against the
operator's handlers directory -- see fork-sandbox-postmaster.sh) is then
required, and none of `harness`/`model`/`network`/`thinking`/`triage` may
be set on the same agent -- those tune an LLM seat, which a handler is
not. `handler`, when present, is always the literal string `exec`;
nothing else validates.

This script owns every validation rule for both documents -- YAML
validity, the schema, name shape, the harness/network enums (including
refusing `pi-local`, which fork-sandbox-preset-parse.py accepts but this
registry does not: the two-axis spelling `harness: pi` + `network: sealed`
is the only one here), the requirement that `network: sealed` only ever
resolves against harness `pi` (checked both within one document and, in
`check`, against the fleet.yaml/frontmatter-merged result, since either
document can be individually valid and still combine into an illegal
pair), the agent/list namespace, list membership, and persona-file
existence -- and reports every error it finds, not just the first,
addressed by path (`agents.reviewer.modle`).

`check` accumulates every error across the whole fleet file and every
persona it declares, prints them all to stderr, and exits 1; exits 0 with
no output when everything is clean. `dump` and `frontmatter` are for the
bash side's `resolve`/`expand`/`roster` verbs: same validation, but since
each is asked about one document at a time, printing every accumulated
error before exiting 1 is just as correct and keeps one validation
routine instead of two.

`dump` emits tab-separated facts about the fleet file:

    agent\t<name>\tpersona\t<value>        (eleven lines per agent, always,
    agent\t<name>\tharness\t<value>         empty value when unset -- the
    agent\t<name>\tmodel\t<value>           bash side treats unset and
    agent\t<name>\tnetwork\t<value>         empty identically via ${x:-y})
    agent\t<name>\tthinking\t<value>
    agent\t<name>\tdescription\t<value>
    agent\t<name>\twake-on-cc\t<value>
    agent\t<name>\trefresh-at\t<value>
    agent\t<name>\ttriage\t<value>
    agent\t<name>\thandler\t<value>
    agent\t<name>\tcommand\t<value>
    list\t<name>                           (once per list, so an empty
    list_member\t<name>\t<member>           list still appears; members
                                             in file order)
    triage\t<field>\t<value>               (harness/model, two lines,
                                             only when a top-level
                                             `triage:` block is present;
                                             zero lines when the fleet
                                             file has no such block)

`frontmatter` emits, for one persona file:

    field\tharness\t<value>
    field\tmodel\t<value>
    field\tnetwork\t<value>
    field\tthinking\t<value>
    field\tdescription\t<value>
    field\twake-on-cc\t<value>
    field\trefresh-at\t<value>
    field\ttriage\t<value>

always eight lines, empty value when unset. A persona file with no leading
`---` frontmatter block is valid and reported as all-empty, not an error.

Requires PyYAML, like fork-sandbox-preset-parse.py; a machine without it
gets a plain error naming the package, not a traceback.
"""

import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: the fleet file is YAML, and parsing it needs the PyYAML\n"
        "python module, which this machine does not have. Install it\n"
        "(commonly packaged as python-yaml or python3-yaml).\n"
    )
    sys.exit(1)

HARNESSES = ("claude", "pi", "codex")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
FIELDS = ("persona", "harness", "model", "network", "thinking",
          "description", "wake-on-cc", "refresh-at", "triage",
          "handler", "command")
# handler/command are deliberately absent here -- see the module
# docstring's "handler: exec" paragraph: a handler seat is host config,
# fleet.yaml-only, and refused as an unknown key in persona frontmatter.
FRONTMATTER_FIELDS = ("harness", "model", "network", "thinking",
                       "description", "wake-on-cc", "refresh-at", "triage")
# LLM-seat-only fields: refused alongside `handler: exec` (decision: a
# handler is a script seat, not an LLM seat to tune).
LLM_ONLY_FIELDS = ("harness", "model", "network", "thinking", "triage")
# Only these two are wired up on the postmaster side (pm_triage_wake's
# pi and claude arms); a triage seat naming any other harness would
# validate here and then silently run as claude at launch, so the
# enum for this one field is narrower than the general HARNESSES tuple.
TRIAGE_HARNESSES = ("claude", "pi")
TRIAGE_SEAT_FIELDS = ("harness", "model")
# No default for `model`: unlike a real agent seat, the classifier's
# model default is harness-gated on the bash side (pm_triage_wake),
# because a flat default here would hand a claude-only alias to a pi
# seat's local endpoint. See fork-sandbox-postmaster.sh's pm_spawn_wake
# for the identical reasoning on a per-agent seat's own model default.
# "model": "" is not a real default (nothing runs with an empty --model
# flag) -- it just gives dump()'s `triage[field]` lookup a key to find
# for every TRIAGE_SEAT_FIELDS entry, the same way an unset per-agent
# field resolves to an empty line rather than a missing one.
TRIAGE_SEAT_DEFAULTS = {"harness": "claude", "model": ""}

# Names no agent or list may take, mapped to why. Both are reserved
# everywhere (`check` and `dump` share this, so a broken fleet file
# defining either is caught the same way regardless of which verb reads
# it first): "all" because fork-sandbox-fleet.sh's `expand` treats @all
# as the built-in every-agent address, not a lookup; "operator" because
# every documented `mail send`/`mail reply` sends operator mail as the
# literal address @operator, and an agent or list resolving that name
# would let it stand in for the real operator -- breaking rule 1's
# operator reset and the kit's "mail from @operator outranks everything"
# framing.
BUILTIN_RESERVED = {
    "all": "the built-in @all list",
    "operator": "the human operator's mail address",
}


def reserved_names():
    return dict(BUILTIN_RESERVED)


def check_reserved(name, path, reserved, errors):
    if name in reserved:
        errors.append(f"{path}: '{name}' is reserved ({reserved[name]}); "
                       f"choose a different name")

# Mirrors fork-sandbox.sh line 2795's --refresh-at grammar exactly -- one
# grammar in two places is a bug, so if that regex ever changes, this one
# must change with it.
REFRESH_AT_RE = re.compile(r"^[0-9]+(\.[0-9]+)?$")


class DupKeyError(ValueError):
    """Raised in place of exiting, so callers can accumulate this alongside
    every other error instead of losing the rest of the document."""


class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys instead of silently
    keeping the last one -- a duplicated agent would otherwise merge into
    one definition with no sign anything was lost. Duplicated verbatim
    from fork-sandbox-preset-parse.py rather than shared, per that file's
    own convention of keeping each parser self-contained."""


def _no_dup_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise DupKeyError(
                f"duplicate key '{key}' (line {key_node.start_mark.line + 1})"
            )
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping
)


def scalar(value, path, errors):
    """A string-ish scalar, with the characters that would corrupt the
    tab-separated output refused here rather than mangled downstream.
    Appends to `errors` and returns None on failure, rather than exiting,
    so a caller can keep validating the rest of the document."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        errors.append(f"{path}: expected a string, got {type(value).__name__}")
        return None
    value = str(value)
    if not value:
        errors.append(f"{path}: empty value")
        return None
    if "\t" in value or "\n" in value:
        errors.append(f"{path}: value may not contain tabs or newlines")
        return None
    return value


def check_harness(value, path, errors):
    if value == "pi-local":
        errors.append(
            f"{path}: 'pi-local' is not a harness here; use 'harness: pi' "
            f"together with 'network: sealed'"
        )
        return ""
    if value not in HARNESSES:
        errors.append(
            f"{path}: takes 'claude', 'pi' or 'codex', not '{value}'"
        )
        return ""
    return value


def check_network(value, path, errors):
    if value not in ("pinned", "sealed"):
        errors.append(f"{path}: takes 'pinned' or 'sealed', not '{value}'")
        return ""
    return value


def check_network_harness_pair(harness, network, path, errors):
    """'sealed' is a property of the harness (only 'pi' has a self-hosted
    endpoint to seal), not of either file format, so this runs both on a
    single document's own fields and, from cmd_check, on the two fields
    after fleet.yaml/frontmatter precedence is applied -- an agent can be
    individually valid in both documents and still resolve to an illegal
    pair. An empty harness is left alone: unspecified defers to whatever
    consumes the registry, per the header's no-defaulting rule."""
    if network == "sealed" and harness not in ("", "pi"):
        errors.append(f"{path}: network 'sealed' requires harness 'pi'; "
                       f"'{harness}' has no self-hosted-endpoint path")


def check_triage_seat(value, label, errors):
    """Validates the top-level `triage:` block -- the wake classifier's own
    sandbox seat, distinct from the per-agent `triage: false` opt-out
    checked by check_triage_field. Presence of the key (even `triage: {}`
    or `triage:` with no value) turns triage on fleet-wide, defaulted from
    TRIAGE_SEAT_DEFAULTS; absence of the key entirely means triage stays
    off, which the caller checks before ever calling this.

    No `network` key: pm_triage_wake's pi arm always launches through
    agent-sandboxed, which is unconditionally sealed and refuses any
    egress flag, and its claude arm can never be sealed (a sealed claude
    session cannot reach the Anthropic API). Either harness's network is
    therefore a fixed fact about that harness, not something a fleet
    file can configure -- so there is nothing here for `network` to mean."""
    path = f"{label}: triage"
    if value is None:
        value = {}
    if not isinstance(value, dict):
        errors.append(f"{path}: must be a mapping of harness/model")
        value = {}
    seat = dict(TRIAGE_SEAT_DEFAULTS)
    for key, v in value.items():
        field_path = f"{path}.{key}"
        if key == "harness":
            sv = scalar(v, field_path, errors)
            if sv is not None:
                if sv in TRIAGE_HARNESSES:
                    seat["harness"] = sv
                else:
                    errors.append(
                        f"{field_path}: takes 'claude' or 'pi' -- the only "
                        f"harnesses the triage classifier launches, not "
                        f"'{sv}'"
                    )
        elif key == "model":
            sv = scalar(v, field_path, errors)
            if sv is not None:
                seat["model"] = sv
        else:
            errors.append(f"{field_path}: unknown key")
    return seat


def check_wake_on_cc(value, path, errors):
    """Unlike every other seat field, this one must be a YAML boolean, not
    a string -- so it is checked directly against the raw YAML value
    rather than going through scalar() first, which explicitly rejects
    bool."""
    if not isinstance(value, bool):
        errors.append(f"{path}: must be a YAML boolean")
        return ""
    return "true" if value else "false"


def check_triage_field(value, path, errors):
    """The per-agent triage opt-out, `triage: false`: a YAML boolean, not a
    string, same shape as check_wake_on_cc and kept separate rather than
    shared, matching this file's small-single-purpose-checkers
    convention."""
    if not isinstance(value, bool):
        errors.append(f"{path}: must be a YAML boolean")
        return ""
    return "true" if value else "false"


def check_refresh_at(value, path, errors):
    if not REFRESH_AT_RE.fullmatch(value):
        errors.append(f"{path}: must be a fraction like 0.5 or an "
                       f"absolute token count, not '{value}'")
        return ""
    return value


def check_persona(value, path, errors):
    """A persona: override names a file directly under personas-dir
    (<personas-dir>/<name>.md, per the header contract), never a path --
    an absolute value or one with a '/' would resolve differently on the
    bash side (plain string concatenation) than here (os.path.join,
    which silently discards personas_dir for an absolute value)."""
    if value != os.path.basename(value) or value in (".", ".."):
        errors.append(f"{path}: must be a bare filename within the "
                       f"personas directory, not a path, got '{value}'")
        return ""
    return value


def check_handler(value, path, errors):
    """The only accepted value is the literal string 'exec' -- a handler
    seat is a deterministic script, not an LLM seat with a choice of
    harnesses, so there is nothing else for this field to mean."""
    if value != "exec":
        errors.append(f"{path}: takes 'exec', not '{value}'")
        return ""
    return value


def check_command(value, path, errors):
    """Mirrors check_persona: a bare name only, never a path -- resolution
    happens entirely host-side (fork-sandbox-postmaster.sh), against the
    operator's own handlers directory, never PATH or a repo/clone, so
    anything that could escape a single path component is refused here
    at the earliest possible point."""
    if value != os.path.basename(value) or value in (".", ".."):
        errors.append(f"{path}: must be a bare command name, not a "
                       f"path, got '{value}'")
        return ""
    return value


def load_and_validate(fleet_file, label, errors):
    """Returns (agents, lists, triage), best-effort -- callers only trust
    them when `errors` is still empty afterward. `triage` is None when the
    fleet file has no top-level `triage:` key at all (triage off
    fleet-wide); otherwise a fully-defaulted {"harness", "model"} dict
    (see check_triage_seat for why there is no `network` key), even for
    `triage: {}` -- presence of the key, not its contents, is what turns
    triage on."""
    reserved = reserved_names()
    try:
        with open(fleet_file, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=DupKeyLoader)
    except OSError as e:
        errors.append(f"{label}: unreadable: {e}")
        return {}, {}, None
    except (yaml.YAMLError, DupKeyError) as e:
        errors.append(f"{label}: not valid YAML: {e}")
        return {}, {}, None

    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        errors.append(f"{label}: the document must be a mapping with "
                       f"'agents' and/or 'lists'")
        return {}, {}, None
    for key in doc:
        if key not in ("agents", "lists", "triage"):
            errors.append(f"{label}: unknown top-level key '{key}'; a "
                           f"fleet file has 'agents', 'lists' and 'triage'")

    triage = check_triage_seat(doc.get("triage"), label, errors) \
        if "triage" in doc else None

    agents_doc = doc.get("agents") or {}
    lists_doc = doc.get("lists") or {}
    if not isinstance(agents_doc, dict):
        errors.append(f"{label}: 'agents' must be a mapping of agent name "
                       f"to definition")
        agents_doc = {}
    if not isinstance(lists_doc, dict):
        errors.append(f"{label}: 'lists' must be a mapping of list name "
                       f"to definition")
        lists_doc = {}

    agents = {}
    for name, props in agents_doc.items():
        name = str(name)
        if not NAME_RE.fullmatch(name):
            errors.append(f"{label}: agents.{name}: agent names match "
                           f"^[a-z0-9][a-z0-9-]*$")
            continue
        if name in reserved:
            check_reserved(name, f"{label}: agents.{name}", reserved, errors)
            continue
        if not isinstance(props, dict):
            errors.append(f"{label}: agents.{name}: expected a mapping of "
                           f"properties")
            continue
        agent = dict.fromkeys(FIELDS, "")
        for prop, value in (props or {}).items():
            path = f"agents.{name}.{prop}"
            if prop == "persona":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["persona"] = check_persona(v, path, errors)
            elif prop in ("model", "thinking", "description"):
                v = scalar(value, path, errors)
                if v is not None:
                    agent[prop] = v
            elif prop == "harness":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["harness"] = check_harness(v, path, errors)
            elif prop == "network":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["network"] = check_network(v, path, errors)
            elif prop == "wake-on-cc":
                agent["wake-on-cc"] = check_wake_on_cc(value, path, errors)
            elif prop == "triage":
                agent["triage"] = check_triage_field(value, path, errors)
            elif prop == "refresh-at":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["refresh-at"] = check_refresh_at(v, path, errors)
            elif prop == "handler":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["handler"] = check_handler(v, path, errors)
            elif prop == "command":
                v = scalar(value, path, errors)
                if v is not None:
                    agent["command"] = check_command(v, path, errors)
            else:
                errors.append(f"{label}: {path}: unknown key")
        check_network_harness_pair(agent["harness"], agent["network"],
                                    f"{label}: agents.{name}", errors)
        if agent["handler"]:
            if not agent["command"]:
                errors.append(f"{label}: agents.{name}.command: required "
                               f"when 'handler' is set")
            for field in LLM_ONLY_FIELDS:
                if agent[field]:
                    errors.append(
                        f"{label}: agents.{name}.{field}: not allowed "
                        f"alongside 'handler: exec' -- a handler seat is "
                        f"a script, not an LLM seat to tune")
        elif agent["command"]:
            errors.append(f"{label}: agents.{name}.handler: 'command' "
                           f"requires 'handler: exec'")
        agents[name] = agent

    lists = {}
    for name, props in lists_doc.items():
        name = str(name)
        if not NAME_RE.fullmatch(name):
            errors.append(f"{label}: lists.{name}: list names match "
                           f"^[a-z0-9][a-z0-9-]*$")
            continue
        if name in reserved:
            check_reserved(name, f"{label}: lists.{name}", reserved, errors)
            continue
        if not isinstance(props, dict):
            errors.append(f"{label}: lists.{name}: expected a mapping "
                           f"with 'members'")
            continue
        members = []
        saw_members = False
        for prop, value in (props or {}).items():
            if prop != "members":
                errors.append(f"{label}: lists.{name}.{prop}: unknown key")
                continue
            saw_members = True
            if not isinstance(value, list) or not value:
                errors.append(f"{label}: lists.{name}.members: must be a "
                               f"non-empty list of agent names")
                continue
            for i, m in enumerate(value):
                mv = scalar(m, f"lists.{name}.members[{i}]", errors)
                if mv is not None:
                    members.append(mv)
        if not saw_members:
            errors.append(f"{label}: lists.{name}: needs 'members'")
        lists[name] = members

    for name in agents:
        if name in lists:
            errors.append(f"{label}: '{name}' is defined as both an "
                           f"agent and a list")

    for name, members in lists.items():
        for m in members:
            if m in lists:
                errors.append(f"{label}: lists.{name}.members: '{m}' "
                               f"names a list; lists cannot contain lists")
            elif m not in agents:
                errors.append(f"{label}: lists.{name}.members: '{m}' is "
                               f"not a defined agent")

    return agents, lists, triage


def parse_frontmatter(path, label, errors):
    """Returns a dict of the five frontmatter fields (empty string when
    unset). A file with no leading '---' block is valid: all fields
    empty, nothing appended to errors."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        errors.append(f"persona '{label}': unreadable: {e}")
        return dict.fromkeys(FRONTMATTER_FIELDS, "")

    fm = dict.fromkeys(FRONTMATTER_FIELDS, "")
    lines = text.split("\n")
    if not lines or lines[0].rstrip("\r") != "---":
        return fm

    end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r") == "---":
            end = i
            break
    if end is None:
        errors.append(f"persona '{label}': frontmatter opens with '---' "
                       f"but never closes")
        return fm

    block = "\n".join(lines[1:end])
    try:
        doc = yaml.load(block, Loader=DupKeyLoader) if block.strip() else {}
    except (yaml.YAMLError, DupKeyError) as e:
        errors.append(f"persona '{label}': frontmatter is not valid "
                       f"YAML: {e}")
        return fm
    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        errors.append(f"persona '{label}': frontmatter must be a mapping")
        return fm

    for key, value in doc.items():
        path_ = f"persona '{label}' frontmatter.{key}"
        if key in ("model", "thinking", "description"):
            v = scalar(value, path_, errors)
            if v is not None:
                fm[key] = v
        elif key == "harness":
            v = scalar(value, path_, errors)
            if v is not None:
                fm["harness"] = check_harness(v, path_, errors)
        elif key == "network":
            v = scalar(value, path_, errors)
            if v is not None:
                fm["network"] = check_network(v, path_, errors)
        elif key == "wake-on-cc":
            fm["wake-on-cc"] = check_wake_on_cc(value, path_, errors)
        elif key == "triage":
            fm["triage"] = check_triage_field(value, path_, errors)
        elif key == "refresh-at":
            v = scalar(value, path_, errors)
            if v is not None:
                fm["refresh-at"] = check_refresh_at(v, path_, errors)
        else:
            errors.append(f"{path_}: unknown key")
    check_network_harness_pair(fm["harness"], fm["network"],
                                f"persona '{label}' frontmatter", errors)
    return fm


def cmd_check(fleet_file, label, personas_dir):
    errors = []
    reserved = reserved_names()
    agents, lists, _triage = load_and_validate(fleet_file, label, errors)
    if not errors:
        for name, agent in agents.items():
            # A handler seat is a script, not an LLM seat -- the wake
            # contract never injects a persona body into it (stdin is
            # just the rendered thread), so it needs no persona file at
            # all; requiring one here would fail `check` for the wrong
            # reason.
            if agent["handler"] == "exec":
                continue
            persona_name = agent["persona"] or f"{name}.md"
            persona_path = os.path.join(personas_dir, persona_name)
            if not os.path.isfile(persona_path):
                errors.append(f"agents.{name}: persona file "
                               f"'{persona_path}' does not exist")
                continue
            fm = parse_frontmatter(persona_path, persona_path, errors)
            check_network_harness_pair(
                agent["harness"] or fm["harness"],
                agent["network"] or fm["network"],
                f"agents.{name}", errors)
        # The bash side (fleet_is_agent) treats a bare <name>.md under
        # personas-dir as making `name` an agent even with no fleet.yaml
        # entry at all -- so a list sharing that name is the same
        # agent/list collision the check above catches within fleet.yaml,
        # just with one half of it living on disk instead.
        for name in lists:
            persona_path = os.path.join(personas_dir, f"{name}.md")
            if os.path.isfile(persona_path):
                errors.append(f"lists.{name}: '{name}' is defined as a "
                               f"list, but persona file '{persona_path}' "
                               f"also makes it a valid agent name")
        # Symmetrically, that same bare-<name>.md rule makes a persona
        # file with no fleet.yaml entry at all a real agent too -- one
        # `check` must validate, or it stays silent on exactly the
        # frontmatter errors `resolve`/`expand` then hit later.
        try:
            persona_files = sorted(os.listdir(personas_dir))
        except OSError as e:
            errors.append(f"{label}: personas dir '{personas_dir}': "
                           f"unreadable: {e}")
            persona_files = []
        for fname in persona_files:
            if not fname.endswith(".md"):
                continue
            name = fname[:-len(".md")]
            if name in agents or name in lists or not NAME_RE.fullmatch(name):
                continue
            persona_path = os.path.join(personas_dir, fname)
            if name in reserved:
                check_reserved(name, persona_path, reserved, errors)
                continue
            parse_frontmatter(persona_path, persona_path, errors)
    if errors:
        for e in errors:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
    sys.exit(0)


def cmd_dump(fleet_file, label):
    errors = []
    agents, lists, triage = load_and_validate(fleet_file, label, errors)
    if errors:
        for e in errors:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
    out = []
    for name, agent in agents.items():
        for field in FIELDS:
            out.append(f"agent\t{name}\t{field}\t{agent[field]}")
    for name, members in lists.items():
        out.append(f"list\t{name}")
        for m in members:
            out.append(f"list_member\t{name}\t{m}")
    if triage is not None:
        for field in TRIAGE_SEAT_FIELDS:
            out.append(f"triage\t{field}\t{triage[field]}")
    sys.stdout.write("".join(line + "\n" for line in out))
    sys.exit(0)


def cmd_frontmatter(persona_file, label):
    errors = []
    fm = parse_frontmatter(persona_file, label, errors)
    if errors:
        for e in errors:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
    out = [f"field\t{field}\t{fm[field]}" for field in FRONTMATTER_FIELDS]
    sys.stdout.write("".join(line + "\n" for line in out))
    sys.exit(0)


def usage_exit():
    sys.stderr.write(
        "Usage: fork-sandbox-fleet-parse.py check <fleet-file> <label> "
        "<personas-dir>\n"
        "       fork-sandbox-fleet-parse.py dump <fleet-file> <label>\n"
        "       fork-sandbox-fleet-parse.py frontmatter <persona-file> "
        "<label>\n"
    )
    sys.exit(1)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "check" and len(sys.argv) == 5:
        cmd_check(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "dump" and len(sys.argv) == 4:
        cmd_dump(sys.argv[2], sys.argv[3])
    elif mode == "frontmatter" and len(sys.argv) == 4:
        cmd_frontmatter(sys.argv[2], sys.argv[3])
    else:
        usage_exit()


if __name__ == "__main__":
    main()
