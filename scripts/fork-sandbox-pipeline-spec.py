#!/usr/bin/env python3
"""Compile a --pipeline spec into a preset document, for fork-sandbox.sh.

Usage: fork-sandbox-pipeline-spec.py <spec>

A spec is a preset's composition name used as the preset itself:
`-`-joined segments `<stage><model>[<harness>][<repeat>]`, e.g.
`csonnet2-rsol2-mopus2` (code sonnet x2, review sol x2, maintain opus x2),
or `ropus-msonnet` (opus review, sonnet maintain -- no code step at all).

    stage    c (code), r (review), m (maintain) or p (plan), in any order
             and any count, exactly as a preset file's pipeline allows --
             UNLESS there is no c segment: a codeless spec compiles to a
             read-only pipeline (see fork-sandbox-preset-parse.py), which
             reviews an existing branch and runs each r and m step once,
             so every repeat in it must be 1. A p segment is further
             restricted: it must come before the first c segment, a spec
             with p and no c is refused, and its own repeat must be 1.
    model    a name from MODELS below. It runs on its native harness, the
             first one listed for it.
    harness  optional: claude, codex or pi, to seat the model on a
             non-native harness (`csolpi2`). The model needs an id for that
             harness in MODELS.
    repeat   optional, default 1. On the code step it is the agent's
             repeat, so it reaches the fix legs too, as in a hand-written
             preset; on a review or maintain step it is the loop cap; on
             a plan step it must be 1 -- there is no loop to cap.

Each segment compiles to its own agent and its own pipeline step. A
stage's first segment names its agent the plain way ("coder", "reviewer",
"maintainer", "planner"); a second and later segment of the same stage
numbers it from there ("reviewer2", "reviewer3", ...) -- deterministic on
the spec's own segment order, not on the model or harness a segment names.

Fix legs ride the first code seat: no step names a fix_agent, so the
preset parser's default applies. Anything the
grammar cannot say (fix_agent, per-seat arguments on another seat, network)
stays a preset file.

The document is printed on stdout as YAML, and fork-sandbox.sh hands it
to fork-sandbox-preset-parse.py like any preset file, so every schema and
engine-shape rule is enforced in one place. Errors go to stderr and exit 1.
"""

import re
import sys

# Model name -> {harness: model id}. The first harness is the native one.
# Names are lowercase letters only: trailing digits are the repeat count.
#
# A codex id here is a bare tier name, not a generation-pinned slug:
# fork-sandbox.sh's resolve_model turns it into a real model id at launch,
# consulting aliases.conf first and falling back to the codex model cache.
# Bumping codex to a new generation is a one-line edit to aliases.conf, not
# to this table -- see docs/presets.md.
MODELS = {
    "haiku": {"claude": "haiku"},
    "sonnet": {"claude": "sonnet"},
    "opus": {"claude": "opus"},
    "fable": {"claude": "fable"},
    "luna": {"codex": "luna"},
    "terra": {"codex": "terra"},
    "sol": {"codex": "sol"},
    "astra": {"codex": "astra"},
}

HARNESSES = ("claude", "codex", "pi")

STAGES = {"c": "code", "r": "review", "m": "maintain", "p": "plan"}

AGENT_NAMES = {"c": "coder", "r": "reviewer", "m": "maintainer", "p": "planner"}


def fail(spec, msg):
    sys.stderr.write(f"Error: --pipeline '{spec}': {msg}\n")
    sys.exit(1)


def parse_seat(spec, seg, body):
    """Split a segment's model[harness] body into (harness, model id)."""
    if body in MODELS:
        harness, model_id = next(iter(MODELS[body].items()))
        return harness, model_id
    for harness in HARNESSES:
        name = body[: -len(harness)]
        if body.endswith(harness) and name in MODELS:
            ids = MODELS[name]
            if harness not in ids:
                fail(spec, f"segment '{seg}': model '{name}' has no "
                           f"{harness} id; it runs on "
                           f"{', '.join(ids)}")
            return harness, ids[harness]
    fail(spec, f"segment '{seg}': unknown model '{body}'; known models: "
               f"{', '.join(MODELS)}")


def compile_spec(spec):
    segments = spec.split("-")
    seats = []
    occurrences = {"c": 0, "r": 0, "m": 0, "p": 0}
    seen_code = False
    saw_plan = False
    for seg in segments:
        m = re.fullmatch(r"([a-z])([a-z]+)([0-9]*)", seg)
        if not m:
            fail(spec, f"segment '{seg}' is not <stage><model>[<repeat>], "
                       f"e.g. csonnet2")
        stage, body, digits = m.groups()
        if stage not in STAGES:
            fail(spec, f"segment '{seg}': stage '{stage}' is not c (code), "
                       f"r (review), m (maintain) or p (plan)")
        if digits and (digits.startswith("0")):
            fail(spec, f"segment '{seg}': the repeat count is a positive "
                       f"integer without a leading zero")
        repeat = int(digits) if digits else 1
        if stage == "p":
            saw_plan = True
            if seen_code:
                fail(spec, f"segment '{seg}': a plan segment must come "
                           f"before the pipeline's first code segment")
            if repeat != 1:
                fail(spec, f"segment '{seg}': the repeat count on a plan "
                           f"segment must be 1 for now")
        elif stage == "c":
            seen_code = True
        harness, model_id = parse_seat(spec, seg, body)
        occurrences[stage] += 1
        occurrence = occurrences[stage]
        agent = (AGENT_NAMES[stage] if occurrence == 1
                 else f"{AGENT_NAMES[stage]}{occurrence}")
        seats.append((stage, harness, model_id, repeat, agent))

    if saw_plan and not seen_code:
        fail(spec, "a pipeline with a plan segment needs a code segment; "
                   "add one or drop the plan segment")

    lines = [f"# Compiled from --pipeline {spec}", "agents:"]
    for stage, harness, model_id, repeat, agent in seats:
        lines += [f"  {agent}:",
                  f"    harness: {harness}",
                  f"    model: {model_id}"]
        if stage == "c" and repeat != 1:
            lines.append(f"    repeat: {repeat}")
    lines.append("pipeline:")
    for stage, _, _, repeat, agent in seats:
        lines += [f"  - action: {STAGES[stage]}",
                  f"    agent: {agent}"]
        if stage not in ("c", "p"):
            lines.append(f"    repeat: {repeat}")
    return "".join(line + "\n" for line in lines)


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        sys.exit(0)
    if len(sys.argv) != 2 or not sys.argv[1]:
        sys.stderr.write("Usage: fork-sandbox-pipeline-spec.py <spec>\n")
        sys.exit(1)
    sys.stdout.write(compile_spec(sys.argv[1]))
