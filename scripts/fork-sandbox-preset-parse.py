#!/usr/bin/env python3
"""Parse and validate one fork-sandbox preset file, for fork-sandbox.sh.

Usage: fork-sandbox-preset-parse.py <file> <name> <label>

A preset is a YAML document shaped like a CI workflow file: an `agents`
mapping and a `pipeline` list of uniform action steps -- a code step,
then at most one review step and one maintain step, each a loop with a
`repeat` cap and an optional `fix_agent` of its own (see
docs/presets.md). This script owns everything about the FILE -- YAML
validity, the schema, the pipeline structure, the engine-shape rules --
and emits the result as tab-separated lines on stdout for
fork-sandbox.sh to compile onto its flag variables:

    agent <name> harness <value>
    agent <name> model <value>          (empty value when unset)
    agent <name> claude_args <value>
    agent <name> pi_args <value>
    agent <name> endpoint <value>       (empty value when unset)
    implement agent <name>
    implement repeat <n>                (only when the code agent repeats)
    implement refresh_at <value>        (from the code agent, when set)
    implement refresh_max <value>
    review agent <name>                 (only when the pipeline has the loop)
    review max <n>
    review fix_default 1                (only when fix_agent was omitted)
    review fix_agent <name>             (only when fix_agent was given)
    review fix_harness <value>          (the effective fix agent's, resolved)
    review fix_model <value>
    review fix_repeat <n>
    maintain agent <name>               (same shape as review)
    ...
    warn <message>                      (advisory; fork-sandbox.sh prints it)

Structural errors go to stderr, addressed by path (`pipeline[1]`), and
exit 1. <name> and <label> are only for those messages: the preset's
name and the path to print for it (fork-sandbox.sh passes a ~-shortened
one).

Requires PyYAML, this feature's one dependency beyond the stock python3
the repo already uses; a machine without it gets a plain error naming the
package, not a traceback.
"""

import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: presets are YAML, and parsing them needs the PyYAML python\n"
        "module, which this machine does not have. Install it (commonly\n"
        "packaged as python-yaml or python3-yaml) or launch without\n"
        "--preset.\n"
    )
    sys.exit(1)

HARNESSES = ("claude", "pi", "pi-local", "codex")


class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys instead of silently
    keeping the last one -- a duplicated agent would otherwise merge into
    one definition with no sign anything was lost."""


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
    sys.stderr.write(f"Error: preset '{NAME}' ({LABEL}): {msg}\n")
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


def positive_int(value, path):
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        fail(f"{path}: takes a positive integer")
    return value


def step_map(item, path):
    if not isinstance(item, dict):
        fail(f"{path}: expected a step mapping")
    return item


def main():
    try:
        with open(FILE, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=DupKeyLoader)
    except OSError as e:
        fail(f"unreadable: {e}")
    except yaml.YAMLError as e:
        fail(f"not valid YAML: {e}")

    if not isinstance(doc, dict):
        fail("the document must be a mapping with 'agents' and 'pipeline'")
    for key in doc:
        if key not in ("agents", "pipeline"):
            fail(f"unknown top-level key '{key}'; a preset has 'agents' and "
                 f"'pipeline'")
    agents_doc = doc.get("agents")
    pipeline = doc.get("pipeline")
    if not isinstance(agents_doc, dict) or not agents_doc:
        fail("'agents' must be a mapping of agent name to definition")
    if not isinstance(pipeline, list) or not pipeline:
        fail("'pipeline' must be a list starting with a code step")

    # ---- agents ----
    agents = {}
    for name, props in agents_doc.items():
        name = scalar(name, "agents")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name):
            fail(f"agents.{name}: agent names match ^[a-z0-9][a-z0-9_-]*$")
        if not isinstance(props, dict):
            fail(f"agents.{name}: expected a mapping of properties")
        agent = {"harness": "", "model": "", "claude_args": "", "pi_args": "",
                 "repeat": 1, "refresh_at": "", "refresh_max": "",
                 "endpoint": ""}
        for prop, value in props.items():
            path = f"agents.{name}.{prop}"
            if prop == "harness":
                value = scalar(value, path)
                # The combined harness/model form the flags accept works
                # here too, split at the first slash for the same reason
                # (an OpenRouter model id carries its own slash).
                harness, _, combined = value.partition("/")
                if harness not in HARNESSES:
                    fail(f"{path}: takes 'claude', 'pi', 'pi-local' or "
                         f"'codex', not '{harness}'")
                agent["harness"] = harness
                if combined:
                    if agent["model"]:
                        fail(f"{path}: combined harness model '{combined}' "
                             f"conflicts with the 'model' key")
                    agent["model"] = combined
            elif prop == "model":
                value = scalar(value, path)
                if agent["model"]:
                    fail(f"{path}: this agent already has a model from its "
                         f"combined harness form")
                agent["model"] = value
            elif prop in ("claude-args", "pi-args"):
                agent[prop.replace("-", "_")] = scalar(value, path)
            elif prop == "repeat":
                # Every coding leg this agent runs becomes this many passes,
                # deliberately without an early exit -- see docs/presets.md.
                agent["repeat"] = positive_int(value, path)
            elif prop in ("refresh-at", "refresh-max"):
                agent[prop.replace("-", "_")] = scalar(value, path)
            elif prop == "endpoint":
                # The named K8S_PROXY_ENDPOINTS entry this seat talks to on a
                # --k8s run; the engine-shape rule below is what keeps it on
                # the code seat's agent only.
                value = scalar(value, path)
                if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", value):
                    fail(f"{path}: endpoint names match "
                         f"^[a-z0-9][a-z0-9_-]*$")
                agent["endpoint"] = value
            else:
                fail(f"{path}: unknown agent property; agents take 'harness', "
                     f"'model', 'claude-args', 'pi-args', 'repeat', "
                     f"'refresh-at', 'refresh-max' and 'endpoint'")
        if not agent["harness"]:
            fail(f"agents.{name}: has no harness")
        agents[name] = agent

    def known(ref, path):
        ref = scalar(ref, path)
        if ref not in agents:
            fail(f"{path}: names undefined agent '{ref}'; define it under "
                 f"'agents' first")
        return ref

    # ---- pipeline ----
    # The first item is the code step; then at most one review step and one
    # maintain step, in that order -- each a loop of up to `repeat` passes
    # whose findings re-run its fix agent (the code seat's agent unless
    # `fix_agent` names another).
    impl_agent = ""
    loops = []  # (kind, agent, cap, fix_agent_or_None)

    step0 = step_map(pipeline[0], "pipeline[0]")
    if step0.get("action") != "code":
        fail("pipeline[0]: the pipeline starts with the code step "
             "(action: code)")
    for prop, value in step0.items():
        path = f"pipeline[0].{prop}"
        if prop == "action":
            continue
        if prop == "agent":
            impl_agent = known(value, path)
        elif prop in ("refresh-at", "refresh-max", "repeat"):
            fail(f"{path}: '{prop}' is an agent property now -- put it on "
                 f"the agent under 'agents'")
        else:
            fail(f"{path}: unknown code-step key; it takes 'agent'")
    if not impl_agent:
        fail("pipeline[0]: the code step needs an agent")

    for i, item in enumerate(pipeline[1:], start=1):
        path = f"pipeline[{i}]"
        item = step_map(item, path)
        verb = item.get("action")
        if verb == "code":
            fail(f"{path}: a preset has one code step, first; repeated "
                 f"coding is the agent's 'repeat' property")
        if verb not in ("review", "maintain"):
            fail(f"{path}: after the code step come 'action: review' and "
                 f"'action: maintain' steps, not '{verb}'")
        reviewer = ""
        cap = None
        fix_ref = None
        for prop, value in item.items():
            ppath = f"{path}.{prop}"
            if prop == "action":
                continue
            if prop == "agent":
                reviewer = known(value, ppath)
            elif prop == "repeat":
                cap = positive_int(value, ppath)
            elif prop == "fix_agent":
                fix_ref = known(value, ppath)
            else:
                fail(f"{ppath}: unknown {verb}-step key; it takes 'agent', "
                     f"'repeat' and 'fix_agent'")
        if not reviewer:
            fail(f"{path}: the {verb} step needs an agent")
        if cap is None:
            fail(f"{path}: the {verb} step needs 'repeat', its loop cap -- "
                 f"the loop runs until the {verb} approves, the cap is "
                 f"reached, or a fix pass makes no progress")
        loops.append((verb, reviewer, cap, fix_ref))

    kinds = [kind for kind, _, _, _ in loops]
    if kinds.count("review") > 1 or kinds.count("maintain") > 1:
        fail("pipeline: at most one review step and one maintain step -- "
             "more tiers belong to the pipeline-as-data design parked in "
             "docs/ideas.md")
    if kinds == ["maintain", "review"]:
        fail("pipeline[2]: the review step comes before the maintain step -- "
             "the maintain tier builds on the review tier's final verdict, "
             "not the other way around")

    # ---- engine-shape rules that need the seats ----
    fix_agents = [fix_ref or impl_agent for _, _, _, fix_ref in loops]
    coding = {impl_agent} | set(fix_agents)
    seated = coding | {agent for _, agent, _, _ in loops}
    impl = agents[impl_agent]
    if (impl["refresh_at"] or impl["refresh_max"]) \
            and impl["harness"] != "claude":
        fail(f"agents.{impl_agent}: refresh keys on a code seat whose "
             f"harness is '{impl['harness']}' -- context refresh is "
             f"claude-only")
    warns = []
    for name, agent in agents.items():
        if name != impl_agent and (agent["claude_args"] or agent["pi_args"]):
            fail(f"agents.{name}: has extra arguments but does not sit the "
                 f"first code seat; claude-args and pi-args reach only that "
                 f"seat's legs today -- there is no per-seat argument "
                 f"plumbing for any other leg yet")
        if name != impl_agent and (agent["refresh_at"] or agent["refresh_max"]):
            fail(f"agents.{name}: has refresh keys but does not sit the "
                 f"first code seat; context refresh reaches only that "
                 f"seat's first pass today")
        if agent["repeat"] != 1 and name not in coding:
            fail(f"agents.{name}: has 'repeat' but never codes -- repeat "
                 f"re-runs coding legs, and this agent sits neither the "
                 f"code seat nor a fix seat")
        if agent["endpoint"] and name != impl_agent:
            fail(f"agents.{name}: has 'endpoint' but does not sit the code "
                 f"seat -- the run has one proxy base URL for the whole "
                 f"run, so only the code seat's endpoint can be honored")
        if agent["harness"] == "pi" and not agent["model"] and name in seated:
            fail(f"agents.{name}: harness pi needs a model -- pi has no "
                 f"default of its own")
        if name not in seated:
            warns.append(f"agent '{name}' is defined but sits no seat")

    # ---- emit ----
    out = []
    for name, agent in agents.items():
        for prop in ("harness", "model", "claude_args", "pi_args",
                    "endpoint"):
            out.append(f"agent\t{name}\t{prop}\t{agent[prop]}")
    out.append(f"implement\tagent\t{impl_agent}")
    if impl["repeat"] != 1:
        out.append(f"implement\trepeat\t{impl['repeat']}")
    if impl["refresh_at"]:
        out.append(f"implement\trefresh_at\t{impl['refresh_at']}")
    if impl["refresh_max"]:
        out.append(f"implement\trefresh_max\t{impl['refresh_max']}")
    for kind, agent, cap, fix_ref in loops:
        out.append(f"{kind}\tagent\t{agent}")
        out.append(f"{kind}\tmax\t{cap}")
        fixer = agents[fix_ref or impl_agent]
        if fix_ref is None:
            out.append(f"{kind}\tfix_default\t1")
        else:
            out.append(f"{kind}\tfix_agent\t{fix_ref}")
        out.append(f"{kind}\tfix_harness\t{fixer['harness']}")
        out.append(f"{kind}\tfix_model\t{fixer['model']}")
        out.append(f"{kind}\tfix_repeat\t{fixer['repeat']}")
    for warn in warns:
        out.append(f"warn\t{warn}")
    sys.stdout.write("".join(line + "\n" for line in out))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.stderr.write(
            "Usage: fork-sandbox-preset-parse.py <file> <name> <label>\n")
        sys.exit(1)
    FILE, NAME, LABEL = sys.argv[1], sys.argv[2], sys.argv[3]
    main()
