#!/usr/bin/env python3
"""Parse and validate one fork-sandbox preset file, for fork-sandbox.sh.

Usage: fork-sandbox-preset-parse.py [--drop-code] <file> <name> <label>

A preset is a YAML document shaped like a CI workflow file: an `agents`
mapping and a `pipeline` list of steps -- each `action: code`, `review`,
`maintain` or `plan`, in any order and any count, so long as there is at
least one. A `code` step is a coding leg; a `review`/`maintain` step is a
loop with a `repeat` cap and an optional `fix_agent` of its own (see
docs/presets.md). A `plan` step is a one-shot leg that writes a plan and
commits nothing; it takes `agent` and an optional `repeat`, which must be
1, and every `plan` step must come before the pipeline's first `code`
step -- a pipeline with a `plan` step and no `code` step is refused.
A pipeline with no code step and no fix_agent is read-only: each step
writes its verdict once. --drop-code (for --review-only) removes the code
steps and fix seats, making any pipeline read-only; a `plan` step has no
place in a read-only pipeline either, and --drop-code refuses one outright.
This script owns everything about the FILE -- YAML validity, the schema,
the pipeline structure, the engine-shape rules -- and emits the result as
tab-separated lines on stdout for fork-sandbox.sh to compile into its own
ordered step list:

    agent <name> harness <value>
    agent <name> model <value>          (empty value when unset)
    agent <name> claude_args <value>
    agent <name> pi_args <value>
    agent <name> codex_args <value>
    agent <name> endpoint <value>       (empty value when unset)
    agent <name> network <value>        (empty value when unset)
    pipeline steps <n>                  (the number of pipeline steps)
    pipeline readonly 1                 (read-only: no fix_* step lines)
    step <k> action <code|review|maintain|plan>   (k is 1-based, pipeline order)
    step <k> agent <name>
    step <k> repeat <n>                 (code step only, when != 1)
    step <k> refresh_at <value>         (the first code step only, when set)
    step <k> refresh_max <value>        (the first code step only, when set)
    step <k> max <n>                    (review/maintain: the loop cap)
    step <k> fix_default 1              (review/maintain, fix_agent omitted)
    step <k> fix_agent <name>           (review/maintain, fix_agent given)
    step <k> fix_harness <value>        (the effective fix agent's, resolved)
    step <k> fix_model <value>
    step <k> fix_repeat <n>
    step <k> fix_network <value>        (empty value when unset)
    step <k> fix_args <value>           (the effective fix agent's, of its
                                          own harness kind; empty when unset)
    step <k> self_coded 1               (read-only only: this step's agent
                                          also sat a code step --drop-code
                                          removed, so its own leg must not
                                          pick up that dropped leg's
                                          arguments)
    warn <message>                      (advisory; fork-sandbox.sh prints it)

Step-indexed rather than the old tier names (review/maintain), since a
pipeline may hold more than one review or maintain step and tier names
would collide.

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

# Which agent property carries a harness's own extra-argument flag.
ARGS_KEY_FOR_HARNESS = {"claude": "claude_args", "pi": "pi_args",
                        "pi-local": "pi_args", "codex": "codex_args"}

STEP_ACTIONS = ("code", "review", "maintain", "plan")


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
        fail("'pipeline' must be a list of at least one step")

    # ---- agents ----
    agents = {}
    for name, props in agents_doc.items():
        name = scalar(name, "agents")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name):
            fail(f"agents.{name}: agent names match ^[a-z0-9][a-z0-9_-]*$")
        if not isinstance(props, dict):
            fail(f"agents.{name}: expected a mapping of properties")
        agent = {"harness": "", "model": "", "claude_args": "", "pi_args": "",
                 "codex_args": "",
                 "repeat": 1, "refresh_at": "", "refresh_max": "",
                 "endpoint": "", "network": ""}
        for prop, value in props.items():
            path = f"agents.{name}.{prop}"
            if prop == "harness":
                value = scalar(value, path)
                # The combined harness/model form the flags accept works
                # here too, split at the first slash for the same reason
                # (an OpenRouter model id carries its own slash).
                harness, _, combined = value.partition("/")
                if harness not in HARNESSES:
                    fail(f"{path}: takes 'claude', 'pi' or 'codex', not "
                         f"'{harness}'")
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
            elif prop in ("claude-args", "pi-args", "codex-args"):
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
                # the first code seat's agent only.
                value = scalar(value, path)
                # The RFC 1123 label shape fork-sandbox-k8s.sh's
                # parse_proxy_endpoints registers names under: no
                # underscore, no trailing hyphen.
                if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", value):
                    fail(f"{path}: endpoint names match "
                         f"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
                agent["endpoint"] = value
            elif prop == "network":
                # An axis independent of harness in the pinned case (see
                # docs/presets.md), but 'sealed' still requires harness 'pi'
                # (or 'pi-local') -- checked once every agent's harness is
                # known, below.
                value = scalar(value, path)
                if value not in ("pinned", "sealed"):
                    fail(f"{path}: takes 'pinned' or 'sealed', not "
                         f"'{value}'")
                agent["network"] = value
            else:
                fail(f"{path}: unknown agent property; agents take 'harness', "
                     f"'model', 'claude-args', 'pi-args', 'codex-args', 'repeat', "
                     f"'refresh-at', 'refresh-max', 'endpoint' and 'network'")
        if not agent["harness"]:
            fail(f"agents.{name}: has no harness")
        agents[name] = agent

    def known(ref, path):
        ref = scalar(ref, path)
        if ref not in agents:
            fail(f"{path}: names undefined agent '{ref}'; define it under "
                 f"'agents' first")
        return ref

    # ---- pipeline: pass 1, per-step structural validation ----
    # No ordering or count constraints on code/review/maintain steps, so
    # long as there is at least one (already checked above). A review step
    # over an empty diff approves trivially; that is documented behavior
    # (docs/presets.md), not something this parser enforces. A `plan` step
    # is the one exception with an ordering rule of its own -- checked
    # below, once every step's action is known.
    steps = []
    for i, item in enumerate(pipeline):
        path = f"pipeline[{i}]"
        item = step_map(item, path)
        verb = item.get("action")
        if verb not in STEP_ACTIONS:
            fail(f"{path}: 'action' must be 'code', 'review', 'maintain' "
                 f"or 'plan', not '{verb}'")
        if verb == "code":
            agent_ref = ""
            repeat_val = None
            for prop, value in item.items():
                ppath = f"{path}.{prop}"
                if prop == "action":
                    continue
                if prop == "agent":
                    agent_ref = known(value, ppath)
                elif prop == "repeat":
                    repeat_val = positive_int(value, ppath)
                elif prop in ("refresh-at", "refresh-max"):
                    fail(f"{ppath}: '{prop}' is an agent property now -- put "
                         f"it on the agent under 'agents'")
                else:
                    fail(f"{ppath}: unknown code-step key; it takes 'agent' "
                         f"and 'repeat'")
            if not agent_ref:
                fail(f"{path}: the code step needs an agent")
            steps.append({"index": i, "action": "code", "agent": agent_ref,
                          "repeat": repeat_val})
        elif verb == "plan":
            agent_ref = ""
            repeat_val = None
            for prop, value in item.items():
                ppath = f"{path}.{prop}"
                if prop == "action":
                    continue
                if prop == "agent":
                    agent_ref = known(value, ppath)
                elif prop == "repeat":
                    repeat_val = positive_int(value, ppath)
                    if repeat_val != 1:
                        fail(f"{ppath}: the repeat count on a plan step "
                             f"must be 1 for now")
                else:
                    fail(f"{ppath}: unknown plan-step key; it takes "
                         f"'agent' and 'repeat'")
            if not agent_ref:
                fail(f"{path}: the plan step needs an agent")
            steps.append({"index": i, "action": "plan", "agent": agent_ref})
        else:
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
                    fail(f"{ppath}: unknown {verb}-step key; it takes "
                         f"'agent', 'repeat' and 'fix_agent'")
            if not reviewer:
                fail(f"{path}: the {verb} step needs an agent")
            if cap is None:
                fail(f"{path}: the {verb} step needs 'repeat', its loop "
                     f"cap -- the loop runs until the {verb} approves, the "
                     f"cap is reached, or a fix pass makes no progress")
            steps.append({"index": i, "action": verb, "agent": reviewer,
                          "cap": cap, "fix_ref": fix_ref})

    # ---- plan steps: an ordering rule of their own ----
    # A plan step plans for the code that follows it, so it must come
    # before the pipeline's first code step, and a pipeline that never
    # codes has nothing for a plan step to plan for.
    plan_steps = [s for s in steps if s["action"] == "plan"]
    if plan_steps:
        first_code_idx = next((s["index"] for s in steps
                                if s["action"] == "code"), None)
        if first_code_idx is None:
            fail("a pipeline with a 'plan' step needs a 'code' step; add "
                 "one or drop the plan step")
        out_of_order = [s for s in plan_steps if s["index"] > first_code_idx]
        if out_of_order:
            fail(f"pipeline[{out_of_order[0]['index']}]: a 'plan' step "
                 f"must come before the pipeline's first 'code' step")

    # ---- read-only pipelines ----
    # With no code step and no fix_agent, nothing can act on a finding, so
    # the pipeline reviews an existing branch: each step writes its verdict
    # once. --drop-code (fork-sandbox.sh's --review-only over a preset)
    # makes any pipeline read-only by dropping its code steps and fix seats.
    # A 'plan' step has no place there: dropping the code step it plans for
    # leaves it planning for nothing, so the combination is refused outright
    # rather than silently becoming the no-code case above.
    dropped_agents = set()
    dropped_code_agents = set()
    early_warns = []
    if DROP_CODE:
        if plan_steps:
            fail("--review-only is refused when the pipeline has a 'plan' "
                 "step: it drops the code step the plan was written for")
        dropped_code_agents = {s["agent"] for s in steps if s["action"] == "code"}
        dropped_agents = set(dropped_code_agents)
        dropped_agents |= {s["fix_ref"] for s in steps
                           if s["action"] not in ("code", "plan") and s["fix_ref"]}
        steps = [s for s in steps if s["action"] != "code"]
        if not steps:
            fail("--review-only drops the code step, and this pipeline has "
                 "no review or maintain step left to run")
        for s in steps:
            s["fix_ref"] = None
    read_only = (all(s["action"] != "code" for s in steps)
                 and all(s["fix_ref"] is None for s in steps))
    if read_only:
        for s in steps:
            if s["cap"] != 1:
                if not DROP_CODE:
                    fail(f"pipeline[{s['index']}]: 'repeat' is {s['cap']} on "
                         f"a read-only {s['action']} step -- with no fix "
                         f"leg there is nothing to loop on; use 1")
                early_warns.append(f"--review-only runs the {s['action']} "
                                   f"step once, not its repeat of {s['cap']}")
                s["cap"] = 1
        # Seats count from what remains: an agent that only sat a dropped
        # code step is neither checked nor warned about, and a kept one's
        # coding-only properties (repeat, refresh, endpoint) have nothing
        # left to apply to. Its extra arguments stay: a kept step's leg
        # honors them, unless the agent also sat the dropped code step
        # (self_coded), whose arguments fork-sandbox.sh blanks.
        for s in steps:
            s["self_coded"] = s["agent"] in dropped_code_agents
        seated_ro = {s["agent"] for s in steps}
        agents = {n: a for n, a in agents.items()
                  if n in seated_ro or n not in dropped_agents}
        if DROP_CODE:
            for agent in agents.values():
                agent.update(repeat=1, refresh_at="", refresh_max="",
                             endpoint="")

    # ---- pipeline: pass 2, seat resolution ----
    # Fix seats default to the first code step's agent, in pipeline order,
    # regardless of where the review/maintain step needing one sits --
    # a review-first pipeline is well-defined (it reviews the branch as it
    # stands) and its fix seat still defaults to the coder that follows it.
    first_code_agent = ""
    first_code_index = None
    for s in steps:
        if s["action"] == "code":
            first_code_agent = s["agent"]
            first_code_index = s["index"]
            break

    for s in steps:
        if s["action"] == "code":
            s["repeat_eff"] = (s["repeat"] if s["repeat"] is not None
                                else agents[s["agent"]]["repeat"])
        elif s["action"] == "plan":
            pass
        elif read_only:
            s["fix_resolved"] = None
        else:
            if s["fix_ref"] is None:
                if not first_code_agent:
                    fail(f"pipeline[{s['index']}]: the {s['action']} step "
                         f"needs 'fix_agent' -- this pipeline has no code "
                         f"step, so there is no default fix seat")
                s["fix_resolved"] = first_code_agent
                s["fix_default"] = True
            else:
                s["fix_resolved"] = s["fix_ref"]
                s["fix_default"] = False

    # ---- engine-shape rules that need the seats ----
    code_step_agents = {s["agent"] for s in steps if s["action"] == "code"}
    fix_agents = {s["fix_resolved"] for s in steps
                  if s["action"] in ("review", "maintain")} - {None}
    coding = code_step_agents | fix_agents
    seated = coding | {s["agent"] for s in steps
                        if s["action"] in ("review", "maintain", "plan")}
    if first_code_agent:
        impl = agents[first_code_agent]
        if (impl["refresh_at"] or impl["refresh_max"]) \
                and impl["harness"] != "claude":
            fail(f"agents.{first_code_agent}: refresh keys on a code seat "
                 f"whose harness is '{impl['harness']}' -- context refresh "
                 f"is claude-only")
    warns = early_warns
    for name, agent in agents.items():
        if agent["claude_args"] and ARGS_KEY_FOR_HARNESS[agent["harness"]] != "claude_args":
            fail(f"agents.{name}: claude-args passes flags to the claude "
                 f"CLI, which a '{agent['harness']}' seat never starts")
        if agent["pi_args"] and ARGS_KEY_FOR_HARNESS[agent["harness"]] != "pi_args":
            fail(f"agents.{name}: pi-args passes flags to pi, which a "
                 f"'{agent['harness']}' seat never starts")
        if agent["codex_args"] and ARGS_KEY_FOR_HARNESS[agent["harness"]] != "codex_args":
            fail(f"agents.{name}: codex-args passes flags to codex exec, "
                 f"which a '{agent['harness']}' seat never starts")
        if name not in seated and (agent["claude_args"] or agent["pi_args"]
                                   or agent["codex_args"]):
            fail(f"agents.{name}: has extra arguments but sits no seat in "
                 f"the pipeline; claude-args/pi-args/codex-args reach a leg "
                 f"only when the agent runs one")
        if name != first_code_agent and (agent["refresh_at"] or agent["refresh_max"]):
            fail(f"agents.{name}: has refresh keys but does not sit the "
                 f"first code seat; there is no per-seat refresh plumbing "
                 f"-- refresh-at/refresh-max becomes the run's own single "
                 f"setting wherever it is set, and today only the first "
                 f"code seat may set it")
        if agent["repeat"] != 1 and name not in coding:
            fail(f"agents.{name}: has 'repeat' but never codes -- repeat "
                 f"re-runs coding legs, and this agent sits neither the "
                 f"code seat nor a fix seat")
        if agent["endpoint"] and name != first_code_agent:
            fail(f"agents.{name}: has 'endpoint' but does not sit the "
                 f"first code seat -- the run has one proxy base URL for "
                 f"the whole run, so only the first code seat's endpoint "
                 f"can be honored")
        if agent["harness"] == "pi" and agent["network"] != "sealed" \
                and not agent["model"] and name in seated:
            fail(f"agents.{name}: harness pi needs a model -- pi has no "
                 f"default of its own")
        if agent["harness"] == "pi-local" and agent["network"] not in (
                "", "sealed"):
            fail(f"agents.{name}: harness 'pi-local' is already sealed; "
                 f"its 'network' key can only be 'sealed' or omitted, not "
                 f"'{agent['network']}'")
        if agent["network"] == "sealed" and agent["harness"] not in (
                "pi", "pi-local"):
            fail(f"agents.{name}: network 'sealed' requires harness 'pi' "
                 f"(or 'pi-local'); '{agent['harness']}' has no "
                 f"self-hosted-endpoint path")
        if name not in seated:
            warns.append(f"agent '{name}' is defined but sits no seat")

    # ---- emit ----
    out = []
    for name, agent in agents.items():
        for prop in ("harness", "model", "claude_args", "pi_args", "codex_args",
                    "endpoint", "network"):
            out.append(f"agent\t{name}\t{prop}\t{agent[prop]}")
    out.append(f"pipeline\tsteps\t{len(steps)}")
    if read_only:
        out.append("pipeline\treadonly\t1")
    for k, s in enumerate(steps, 1):
        out.append(f"step\t{k}\taction\t{s['action']}")
        out.append(f"step\t{k}\tagent\t{s['agent']}")
        if read_only and s.get("self_coded"):
            out.append(f"step\t{k}\tself_coded\t1")
        if s["action"] == "code":
            if s["repeat_eff"] != 1:
                out.append(f"step\t{k}\trepeat\t{s['repeat_eff']}")
            if s["index"] == first_code_index:
                impl = agents[s["agent"]]
                if impl["refresh_at"]:
                    out.append(f"step\t{k}\trefresh_at\t{impl['refresh_at']}")
                if impl["refresh_max"]:
                    out.append(f"step\t{k}\trefresh_max\t{impl['refresh_max']}")
        elif s["action"] == "plan":
            pass
        elif read_only:
            out.append(f"step\t{k}\tmax\t{s['cap']}")
        else:
            out.append(f"step\t{k}\tmax\t{s['cap']}")
            fixer = agents[s["fix_resolved"]]
            if s["fix_default"]:
                out.append(f"step\t{k}\tfix_default\t1")
            else:
                out.append(f"step\t{k}\tfix_agent\t{s['fix_resolved']}")
            out.append(f"step\t{k}\tfix_harness\t{fixer['harness']}")
            out.append(f"step\t{k}\tfix_model\t{fixer['model']}")
            out.append(f"step\t{k}\tfix_repeat\t{fixer['repeat']}")
            out.append(f"step\t{k}\tfix_network\t{fixer['network']}")
            out.append(f"step\t{k}\tfix_args\t"
                       f"{fixer[ARGS_KEY_FOR_HARNESS[fixer['harness']]]}")
    for warn in warns:
        out.append(f"warn\t{warn}")
    sys.stdout.write("".join(line + "\n" for line in out))


if __name__ == "__main__":
    argv = sys.argv[1:]
    DROP_CODE = bool(argv) and argv[0] == "--drop-code"
    if DROP_CODE:
        argv = argv[1:]
    if len(argv) != 3:
        sys.stderr.write("Usage: fork-sandbox-preset-parse.py [--drop-code] "
                         "<file> <name> <label>\n")
        sys.exit(1)
    FILE, NAME, LABEL = argv
    main()
