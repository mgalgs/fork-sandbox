#!/usr/bin/env python3
"""Parse and validate one lkml-mode machine seats file, for the
lkml-seats-resolve helper.

Usage: lkml-seats-parse.py <file> <label> <personas-dir>

A seats file is the per-machine override for which harness/model each
lkml-mode persona seat runs on: an optional `default` entry plus a
`personas` mapping, each carrying only the seat facts a persona's
frontmatter carries -- `harness`, `model` and `thinking` (see
skills/lkml-mode/SKILL.md, "Building a panel"). This script owns
everything about the FILE -- YAML validity, the schema, and the check
that every name under `personas` names a real
<personas-dir>/<name>.md (a typo'd name must refuse, not silently apply
to no seat) -- and emits the result as tab-separated lines for
lkml-seats-resolve to apply its precedence rules:

    default	harness	<value>             (only when the key is set)
    default	model	<value>
    default	thinking	<value>
    personas	<name>	harness	<value>
    personas	<name>	model	<value>
    personas	<name>	thinking	<value>

Keys are emitted only when the file sets them -- the consumer must be
able to tell "not mentioned" from "set to nothing" (there is no "set to
nothing"; empty values are refused here).

A missing file is NOT an error -- the launcher checks for existence
before calling this, and a missing seats file means the persona
frontmatter pins stand. An unreadable or unparseable file IS one, and
so is any schema violation: a typo in the seats file must refuse loudly
rather than silently fall back to the frontmatter pins (on a machine
that moved its panel to a cheap endpoint, that fallback is a silent
bill for the expensive one). Structural errors go to stderr, addressed
by path (`personas.author.thinking`), and exit 1; <label> is the path
to print for the file.

Follows fork-sandbox-preset-parse.py's precedent: the same DupKeyLoader
(duplicated, not sourced -- the two files are separately-reviewed
surfaces, the same way the lkml scripts duplicate their frontmatter
readers) and the same "plain error naming PyYAML, not a traceback"
guard.
"""

import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: the lkml-mode seats file is YAML, and parsing it needs the\n"
        "PyYAML python module, which this machine does not have. Install it\n"
        "(commonly packaged as python-yaml or python3-yaml) or delete the\n"
        "seats file so the persona frontmatter pins stand.\n"
    )
    sys.exit(1)

HARNESSES = ("claude", "pi", "pi-local", "codex")
SEAT_KEYS = ("harness", "model", "thinking")


class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys instead of silently
    keeping the last one -- a duplicated `harness:` would otherwise be
    a typo the operator never sees, and it is exactly the class of typo
    this file's loud-refusal rule exists to catch."""


def _no_dup_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            fail(f"duplicate key '{key}' (line {key_node.start_mark.line + 1})")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping
)


def fail(msg):
    sys.stderr.write(f"Error: seats file '{LABEL}': {msg}\n")
    sys.exit(1)


def scalar(value, path):
    """A string-ish scalar, with the characters that would corrupt the
    tab-separated output refused here rather than mangled downstream."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        fail(f"{path}: expected a string, got {type(value).__name__}")
    value = str(value)
    if not value:
        fail(f"{path}: empty value")
    if "\t" in value or "\n" in value:
        fail(f"{path}: value may not contain tabs or newlines")
    return value


def entry(entry_doc, path):
    """Validate one `default:` or `personas.<name>:` entry and return its
    set keys in canonical order, for the emit below."""
    if not isinstance(entry_doc, dict):
        fail(f"{path}: expected a mapping of 'harness', 'model' and 'thinking'")
    if not entry_doc:
        fail(f"{path}: sets no key; an entry carries at least one of "
             f"'harness', 'model' or 'thinking'")
    set_keys = []
    for prop, value in entry_doc.items():
        ppath = f"{path}.{prop}"
        if prop not in SEAT_KEYS:
            fail(f"{ppath}: unknown key; a seats entry takes 'harness', "
                 f"'model' and 'thinking'")
        if prop == "harness":
            value = scalar(value, ppath)
            if value not in HARNESSES:
                fail(f"{ppath}: takes 'claude', 'pi', 'pi-local' or 'codex', "
                     f"not '{value}'")
        else:
            scalar(value, ppath)
        set_keys.append(prop)
    return sorted(set_keys, key=SEAT_KEYS.index)


def main():
    try:
        with open(FILE, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=DupKeyLoader)
    except OSError as e:
        fail(f"unreadable: {e}")
    except yaml.YAMLError as e:
        fail(f"not valid YAML: {e}")

    if not isinstance(doc, dict) or not doc:
        fail("the file is empty or not a mapping; a seats file has a "
             "'default' entry and/or a 'personas' mapping")
    for key in doc:
        if key not in ("default", "personas"):
            fail(f"unknown top-level key '{key}'; a seats file has 'default' "
                 f"and 'personas'")

    lines = []
    if "default" in doc:
        for prop in entry(doc["default"], "default"):
            lines.append(f"default\t{prop}\t{doc['default'][prop]}")
    if "personas" in doc:
        personas_doc = doc["personas"]
        if not isinstance(personas_doc, dict) or not personas_doc:
            fail("'personas' must be a mapping of persona name to entry")
        for name, props in personas_doc.items():
            name = scalar(name, "personas")
            if not os.path.isfile(os.path.join(PERSONAS_DIR, f"{name}.md")):
                fail(f"personas.{name}: no persona file "
                     f"{os.path.join(PERSONAS_DIR, name + '.md')} -- the "
                     f"name must match a file in the personas directory "
                     f"this invocation uses")
            for prop in entry(props, f"personas.{name}"):
                lines.append(f"personas\t{name}\t{prop}\t{props[prop]}")

    sys.stdout.write("".join(line + "\n" for line in lines))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.stderr.write(
            "Usage: lkml-seats-parse.py <file> <label> <personas-dir>\n")
        sys.exit(1)
    FILE, LABEL, PERSONAS_DIR = sys.argv[1], sys.argv[2], sys.argv[3]
    main()
