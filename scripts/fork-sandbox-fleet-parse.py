#!/usr/bin/env python3
"""Parse and validate fork-sandbox's fleet file and persona frontmatter, for
fork-sandbox-fleet.sh.

Usage: fork-sandbox-fleet-parse.py check <fleet-file> <label> <personas-dir>
       fork-sandbox-fleet-parse.py dump <fleet-file> <label>
       fork-sandbox-fleet-parse.py frontmatter <persona-file> <label>

A fleet file is a YAML mapping of `agents` (name -> optional persona/
harness/model/network/thinking/description overrides) and `lists` (name ->
`members`, a list of agent names). A persona file is markdown with an
optional YAML frontmatter block (delimited by `---` lines) carrying the
same seat keys plus `description`; the body is opaque to this script.

This script owns every validation rule for both documents -- YAML
validity, the schema, name shape, the harness/network enums (including
refusing `pi-local`, which fork-sandbox-preset-parse.py accepts but this
registry does not: the two-axis spelling `harness: pi` + `network: sealed`
is the only one here), the agent/list namespace, list membership, and
persona-file existence -- and reports every error it finds, not just the
first, addressed by path (`agents.reviewer.modle`).

`check` accumulates every error across the whole fleet file and every
persona it declares, prints them all to stderr, and exits 1; exits 0 with
no output when everything is clean. `dump` and `frontmatter` are for the
bash side's `resolve`/`expand`/`roster` verbs: same validation, but since
each is asked about one document at a time, printing every accumulated
error before exiting 1 is just as correct and keeps one validation
routine instead of two.

`dump` emits tab-separated facts about the fleet file:

    agent\t<name>\tpersona\t<value>        (six lines per agent, always,
    agent\t<name>\tharness\t<value>         empty value when unset -- the
    agent\t<name>\tmodel\t<value>           bash side treats unset and
    agent\t<name>\tnetwork\t<value>         empty identically via ${x:-y})
    agent\t<name>\tthinking\t<value>
    agent\t<name>\tdescription\t<value>
    list\t<name>                           (once per list, so an empty
    list_member\t<name>\t<member>           list still appears; members
                                             in file order)

`frontmatter` emits, for one persona file:

    field\tharness\t<value>
    field\tmodel\t<value>
    field\tnetwork\t<value>
    field\tthinking\t<value>
    field\tdescription\t<value>

always five lines, empty value when unset. A persona file with no leading
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
FIELDS = ("persona", "harness", "model", "network", "thinking", "description")
FRONTMATTER_FIELDS = ("harness", "model", "network", "thinking", "description")


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


def load_and_validate(fleet_file, label, errors):
    """Returns (agents, lists) dicts, best-effort -- callers only trust
    them when `errors` is still empty afterward."""
    try:
        with open(fleet_file, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=DupKeyLoader)
    except OSError as e:
        errors.append(f"{label}: unreadable: {e}")
        return {}, {}
    except (yaml.YAMLError, DupKeyError) as e:
        errors.append(f"{label}: not valid YAML: {e}")
        return {}, {}

    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        errors.append(f"{label}: the document must be a mapping with "
                       f"'agents' and/or 'lists'")
        return {}, {}
    for key in doc:
        if key not in ("agents", "lists"):
            errors.append(f"{label}: unknown top-level key '{key}'; a "
                           f"fleet file has 'agents' and 'lists'")

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
        if not isinstance(props, dict):
            errors.append(f"{label}: agents.{name}: expected a mapping of "
                           f"properties")
            continue
        agent = dict.fromkeys(FIELDS, "")
        for prop, value in (props or {}).items():
            path = f"agents.{name}.{prop}"
            if prop in ("persona", "model", "thinking", "description"):
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
            else:
                errors.append(f"{label}: {path}: unknown key")
        agents[name] = agent

    lists = {}
    for name, props in lists_doc.items():
        name = str(name)
        if not NAME_RE.fullmatch(name):
            errors.append(f"{label}: lists.{name}: list names match "
                           f"^[a-z0-9][a-z0-9-]*$")
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

    return agents, lists


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
        else:
            errors.append(f"{path_}: unknown key")
    return fm


def cmd_check(fleet_file, label, personas_dir):
    errors = []
    agents, _ = load_and_validate(fleet_file, label, errors)
    if not errors:
        for name, agent in agents.items():
            persona_name = agent["persona"] or f"{name}.md"
            persona_path = os.path.join(personas_dir, persona_name)
            if not os.path.isfile(persona_path):
                errors.append(f"agents.{name}: persona file "
                               f"'{persona_path}' does not exist")
                continue
            parse_frontmatter(persona_path, persona_path, errors)
    if errors:
        for e in errors:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
    sys.exit(0)


def cmd_dump(fleet_file, label):
    errors = []
    agents, lists = load_and_validate(fleet_file, label, errors)
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
