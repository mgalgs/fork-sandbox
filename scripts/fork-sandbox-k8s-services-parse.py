#!/usr/bin/env python3
"""Parse and validate one .agents/sandbox-services/services.yaml, for
fork-sandbox-k8s.sh.

Usage: fork-sandbox-k8s-services-parse.py <file> <out-dir> <max-services>
                                           <max-cpu> <max-memory>

The cluster path takes declarative data, never an executable hook: the repo
commits this file, and the harness (not the repo) synthesizes the Job's
sidecars from it, so it can guarantee the security context instead of
hoping the repo emitted one. Every field here is treated as hostile -- it
comes from a checkout the agent itself can edit -- so parsing is strict:
unknown keys are errors, not ignored, and there is no field for anything
that would let a service escape the harness's own security context (no
securityContext, hostPath, privileged, capabilities, hostNetwork or service
account -- not rejected, just not expressible).

<max-services>, <max-cpu> and <max-memory> are the per-run caps from
K8S_SERVICES_MAX / K8S_SERVICE_MAX_CPU / K8S_SERVICE_MAX_MEMORY in
k8s.env (fork-sandbox-k8s.sh resolves their defaults before calling this).

On success, writes into <out-dir> the already-rendered YAML/text fragments
fork-sandbox-k8s.sh splices into the Job it builds, so no further parsing
of this script's output is needed on the bash side:

    containers.yaml       initContainers entries, one per service (native
                           sidecars: restartPolicy: Always), or absent
    volumes.yaml           one emptyDir volume per writableDirs entry, or
                           absent
    sandbox-env            KEY=VALUE lines from `sandboxEnv`, or absent if
                           `sandboxEnv` was not given
    prompt-services.txt    "<name> 127.0.0.1:<port>" lines, or absent
    grace                  present (containing "10") iff at least one
                           service is defined

Absent output files mean "nothing to splice there" -- fork-sandbox-k8s.sh
tests for existence, not content, to decide whether to add a block.

Structural errors go to stderr, addressed by path (`services[0].port`), and
exit 1.

Requires PyYAML, this feature's one dependency beyond the stock python3 the
repo already uses; a machine without it gets a plain error naming the
package, not a traceback.
"""

import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: .agents/sandbox-services/services.yaml is YAML, and parsing\n"
        "it needs the PyYAML python module, which this machine does not\n"
        "have. Install it (commonly packaged as python-yaml or\n"
        "python3-yaml).\n"
    )
    sys.exit(1)

SPEC_PATH = ".agents/sandbox-services/services.yaml"
SUPPORTED_VERSIONS = (1,)
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
RESERVED_NAMES = ("egress-gate", "agent")

# 8/10/12/14-space indents matching the Job's existing initContainers /
# volumes blocks in fork-sandbox-k8s.sh -- see its own initContainers and
# volumes YAML for the shape these must slot into unchanged.
I2, I3, I4, I5 = "        ", "          ", "            ", "              "


class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys instead of silently
    keeping the last one -- a duplicated service would otherwise merge
    into one definition with no sign anything was lost."""


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
    sys.stderr.write(f"Error: {SPEC_PATH}: {msg}\n")
    sys.exit(1)


def text_field(value, path, yaml_safe=True):
    """A string-ish scalar. Every value the harness later embeds in the
    rendered Job's YAML is double-quoted, so yaml_safe values additionally
    refuse the characters that would let one break out of that quoting or
    corrupt a KEY=VALUE line in .env.sandbox."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        fail(f"{path}: expected a string, got {type(value).__name__}")
    value = str(value)
    if not value:
        fail(f"{path}: empty value")
    if "\t" in value or "\n" in value:
        fail(f"{path}: value may not contain tabs or newlines")
    if yaml_safe and ("'" in value or '"' in value or "\\" in value):
        fail(f"{path}: value may not contain a quote or a backslash")
    return value


def positive_int(value, path, lo=None, hi=None):
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"{path}: expected an integer, got {type(value).__name__}")
    if lo is not None and value < lo or hi is not None and value > hi:
        fail(f"{path}: must be between {lo} and {hi}, got {value}")
    return value


def parse_cpu(value, path):
    value = text_field(value, path)
    if re.fullmatch(r"[0-9]+m", value):
        return int(value[:-1])
    if re.fullmatch(r"[0-9]+(\.[0-9]+)?", value):
        return int(float(value) * 1000)
    fail(f"{path}: not a valid CPU quantity, e.g. '500m' or '1'")


MEMORY_RE = re.compile(r"^([0-9]+)(Ki|Mi|Gi|Ti|K|M|G|T)?$")
MEMORY_MULT = {
    None: 1,
    "K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4,
    "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
}


def parse_memory(value, path):
    value = text_field(value, path)
    m = MEMORY_RE.fullmatch(value)
    if not m:
        fail(f"{path}: not a valid memory quantity, e.g. '512Mi' or '1Gi'")
    return int(m.group(1)) * MEMORY_MULT[m.group(2)]


def parse_doc(doc):
    if not isinstance(doc, dict):
        fail("the document must be a mapping with 'version' and 'services'")
    for key in doc:
        if key not in ("version", "services", "sandboxEnv"):
            fail(f"unknown top-level key '{key}'; this schema has 'version', "
                 f"'services' and 'sandboxEnv'")

    version = doc.get("version")
    if version not in SUPPORTED_VERSIONS:
        supported = ", ".join(str(v) for v in SUPPORTED_VERSIONS)
        fail(f"version: must be one of [{supported}], got {version!r}")

    services_doc = doc.get("services", [])
    if not isinstance(services_doc, list):
        fail("'services' must be a list of service mappings")

    if len(services_doc) > MAX_SERVICES:
        fail(f"services: {len(services_doc)} services given, more than the "
             f"{MAX_SERVICES} allowed (K8S_SERVICES_MAX in k8s.env)")

    services = []
    seen_names = set()
    seen_ports = {}
    for i, item in enumerate(services_doc):
        path = f"services[{i}]"
        if not isinstance(item, dict):
            fail(f"{path}: expected a service mapping")
        for key in item:
            if key not in ("name", "image", "port", "env", "writableDirs",
                           "readyWhen", "resources"):
                fail(f"{path}: unknown key '{key}'; a service takes 'name', "
                     f"'image', 'port', 'env', 'writableDirs', 'readyWhen' "
                     f"and 'resources'")

        if "name" not in item:
            fail(f"{path}: needs a 'name'")
        name = text_field(item["name"], f"{path}.name")
        if not NAME_RE.fullmatch(name):
            fail(f"{path}.name: '{name}' must match "
                 f"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
        if name in RESERVED_NAMES:
            fail(f"{path}.name: '{name}' is reserved by the harness's own "
                 f"pod containers")
        if name in seen_names:
            fail(f"{path}.name: '{name}' is used by more than one service; "
                 f"names must be unique")
        seen_names.add(name)
        path = f"services[{i}] ('{name}')"

        if "image" not in item:
            fail(f"{path}.image: needs an image")
        # Embedded unquoted in the rendered container spec, the same as
        # $K8S_IMAGE already is -- a newline there could inject extra YAML
        # keys, so this refuses exactly what fs_reject_unsafe_chars refuses
        # for --branch and --model, plus the stronger yaml_safe check this
        # script applies everywhere it double-quotes a value instead.
        image = text_field(item["image"], f"{path}.image")

        if "port" not in item:
            fail(f"{path}.port: needs a port")
        port = positive_int(item["port"], f"{path}.port", 1025, 65535)
        if port in seen_ports:
            fail(f"{path}.port: {port} is also used by service "
                 f"'{seen_ports[port]}'; ports must be unique")
        seen_ports[port] = name

        env = {}
        if "env" in item:
            env_doc = item["env"]
            if not isinstance(env_doc, dict):
                fail(f"{path}.env: must be a mapping of env var name to value")
            for key, value in env_doc.items():
                key = text_field(key, f"{path}.env", yaml_safe=False)
                if not ENV_KEY_RE.fullmatch(key):
                    fail(f"{path}.env.{key}: env var names match "
                         f"^[A-Za-z_][A-Za-z0-9_]*$")
                env[key] = text_field(value, f"{path}.env.{key}")

        writable_dirs = []
        if "writableDirs" in item:
            wd_doc = item["writableDirs"]
            if not isinstance(wd_doc, list):
                fail(f"{path}.writableDirs: must be a list of absolute paths")
            seen_dirs = set()
            for j, entry in enumerate(wd_doc):
                wpath = f"{path}.writableDirs[{j}]"
                entry = text_field(entry, wpath)
                if not entry.startswith("/"):
                    fail(f"{wpath}: '{entry}' must be an absolute path")
                if entry == "/":
                    fail(f"{wpath}: must not be '/'")
                if ".." in entry.split("/"):
                    fail(f"{wpath}: '{entry}' must not contain '..'")
                if entry in seen_dirs:
                    fail(f"{wpath}: '{entry}' is already listed for this "
                         f"service")
                seen_dirs.add(entry)
                writable_dirs.append(entry)

        ready_tcp_port = None
        if "readyWhen" in item:
            rw_doc = item["readyWhen"]
            if not isinstance(rw_doc, dict):
                fail(f"{path}.readyWhen: must be a mapping")
            for key in rw_doc:
                if key != "tcpPort":
                    fail(f"{path}.readyWhen: unknown key '{key}'; only "
                         f"'tcpPort' is supported -- there is no 'exec' "
                         f"form, since a command here would be "
                         f"repo-controlled execution")
            if "tcpPort" not in rw_doc:
                fail(f"{path}.readyWhen: needs 'tcpPort'")
            ready_tcp_port = positive_int(
                rw_doc["tcpPort"], f"{path}.readyWhen.tcpPort", 1, 65535)

        cpu = memory = None
        if "resources" in item:
            res_doc = item["resources"]
            if not isinstance(res_doc, dict):
                fail(f"{path}.resources: must be a mapping")
            for key in res_doc:
                if key not in ("cpu", "memory"):
                    fail(f"{path}.resources: unknown key '{key}'; only "
                         f"'cpu' and 'memory' are supported")
            if "cpu" in res_doc:
                cpu = text_field(res_doc["cpu"], f"{path}.resources.cpu")
                if parse_cpu(cpu, f"{path}.resources.cpu") > parse_cpu(
                        MAX_CPU, "K8S_SERVICE_MAX_CPU"):
                    fail(f"{path}.resources.cpu: '{cpu}' exceeds the "
                         f"per-service cap {MAX_CPU} (K8S_SERVICE_MAX_CPU "
                         f"in k8s.env)")
            if "memory" in res_doc:
                memory = text_field(res_doc["memory"], f"{path}.resources.memory")
                if parse_memory(memory, f"{path}.resources.memory") > parse_memory(
                        MAX_MEMORY, "K8S_SERVICE_MAX_MEMORY"):
                    fail(f"{path}.resources.memory: '{memory}' exceeds the "
                         f"per-service cap {MAX_MEMORY} "
                         f"(K8S_SERVICE_MAX_MEMORY in k8s.env)")

        services.append({
            "name": name, "image": image, "port": port, "env": env,
            "writableDirs": writable_dirs, "readyTcpPort": ready_tcp_port,
            "cpu": cpu, "memory": memory,
        })

    sandbox_env = {}
    if "sandboxEnv" in doc:
        se_doc = doc["sandboxEnv"]
        if not isinstance(se_doc, dict):
            fail("'sandboxEnv' must be a mapping of env var name to value")
        for key, value in se_doc.items():
            key = text_field(key, "sandboxEnv", yaml_safe=False)
            if not ENV_KEY_RE.fullmatch(key):
                fail(f"sandboxEnv.{key}: env var names match "
                     f"^[A-Za-z_][A-Za-z0-9_]*$")
            sandbox_env[key] = text_field(value, f"sandboxEnv.{key}")

    return services, sandbox_env


def render_container(svc):
    lines = [f'{I2}- name: {svc["name"]}',
             f'{I3}image: "{svc["image"]}"',
             f'{I3}restartPolicy: Always']
    if svc["env"]:
        lines.append(f"{I3}env:")
        for key, value in svc["env"].items():
            lines.append(f"{I4}- name: {key}")
            lines.append(f'{I5}value: "{value}"')
    lines += [f"{I3}securityContext:",
              f"{I4}allowPrivilegeEscalation: false",
              f"{I4}readOnlyRootFilesystem: true",
              f"{I4}capabilities:",
              f'{I5}drop: ["ALL"]']
    if svc["writableDirs"]:
        lines.append(f"{I3}volumeMounts:")
        for j, wdir in enumerate(svc["writableDirs"]):
            lines.append(f'{I4}- name: {svc["name"]}-wd{j}')
            lines.append(f'{I5}mountPath: "{wdir}"')
    if svc["readyTcpPort"] is not None:
        lines += [f"{I3}startupProbe:",
                  f"{I4}tcpSocket:",
                  f'{I5}port: {svc["readyTcpPort"]}']
    if svc["cpu"] or svc["memory"]:
        lines.append(f"{I3}resources:")
        for block in ("requests", "limits"):
            lines.append(f"{I4}{block}:")
            if svc["cpu"]:
                lines.append(f'{I5}cpu: "{svc["cpu"]}"')
            if svc["memory"]:
                lines.append(f'{I5}memory: "{svc["memory"]}"')
    return "\n".join(lines)


def render_volumes(svc):
    lines = []
    for j in range(len(svc["writableDirs"])):
        lines.append(f'{I2}- name: {svc["name"]}-wd{j}')
        lines.append(f"{I3}emptyDir: {{}}")
    return "\n".join(lines)


def write_if(path, content):
    if content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
            if not content.endswith("\n"):
                f.write("\n")


def main():
    try:
        with open(FILE, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=DupKeyLoader)
    except OSError as e:
        fail(f"unreadable: {e}")
    except yaml.YAMLError as e:
        fail(f"not valid YAML: {e}")

    services, sandbox_env = parse_doc(doc)

    os.makedirs(OUT_DIR, exist_ok=True)
    write_if(os.path.join(OUT_DIR, "containers.yaml"),
              "\n".join(render_container(s) for s in services))
    write_if(os.path.join(OUT_DIR, "volumes.yaml"),
              "\n".join(render_volumes(s) for s in services if s["writableDirs"]))
    write_if(os.path.join(OUT_DIR, "sandbox-env"),
              "".join(f"{k}={v}\n" for k, v in sandbox_env.items()))
    write_if(os.path.join(OUT_DIR, "prompt-services.txt"),
              "".join(f'{s["name"]} 127.0.0.1:{s["port"]}\n' for s in services))
    write_if(os.path.join(OUT_DIR, "grace"), "10\n" if services else "")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.stderr.write(
            "Usage: fork-sandbox-k8s-services-parse.py <file> <out-dir> "
            "<max-services> <max-cpu> <max-memory>\n")
        sys.exit(1)
    FILE, OUT_DIR = sys.argv[1], sys.argv[2]
    MAX_SERVICES = int(sys.argv[3])
    MAX_CPU, MAX_MEMORY = sys.argv[4], sys.argv[5]
    main()
