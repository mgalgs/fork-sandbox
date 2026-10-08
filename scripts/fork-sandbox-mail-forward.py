#!/usr/bin/env python3
"""fork-sandbox-mail-forward.py -- team access to the cluster mail API.

Usage: fork-sandbox-mail-forward.py --setup --context CTX --namespace NS
                                    --name @you [--port N] [--no-verify]
       fork-sandbox-mail-forward.py --status
       fork-sandbox-mail-forward.py --stop

Run `--setup` once per machine. After it, `fork-sandbox mail --remote <verb>
...` works with nothing else configured: read panel threads, post into them.

What the cluster side gives you (see docs/mail-api.md, "Team access"):
`install --postmaster` keeps a shared team token in a Secret in the
postmaster's namespace, and a Role that lets whoever it is bound to
port-forward to the mail API and read that one Secret. Having Kubernetes
access to the namespace is the authorization; there is nothing to mint and
nobody to ask.

--setup records three things in ${FORK_SANDBOX_CONFIG_DIR:-
$HOME/.config/fork-sandbox}/mail-team.env: the kube CONTEXT, the NAMESPACE and
your own @name (the default for --from). The context is always the one you
name here: the client never uses your kubeconfig's current context, because
that is often a production cluster, and it never runs kubectl without
--context. Unless --no-verify, setup first checks that your credentials can
read the team token, and writes nothing if they cannot. --port is the stable
local port the forward listens on (default 18765, 127.0.0.1 only).

After setup, `mail --remote` and `postmaster --remote`, when no
FORK_SANDBOX_MAIL_API_URL / K8S_MAIL_API_URL or token file is configured:

  * start `kubectl port-forward` to the mail API in the background, or reuse
    the one already running. It outlives the command, so the next call finds it,
    and one forward serves every call: there is never one per call. When the
    postmaster pod is replaced the forward dies with it, and the next call (or
    the retry of this one) starts a fresh forward. Starting is serialized by a
    lock, so two commands at once do not start two.
  * read the team token with your own kube credentials, once per command, and
    keep it in memory. It is never written to a file: the state kept in
    ${XDG_STATE_HOME:-$HOME/.local/state}/fork-sandbox/mail-forward/ holds the
    forward's pid, port and kubectl's log, nothing else.
  * use your @name for `send` and `reply` when you give no --from. An explicit
    --from wins. The team token is an operator token, so `--from @operator`
    works, and that is how you clear a NEEDS-OPERATOR flag.

Explicit configuration (a URL and a token file, in the environment or in
k8s.env) always wins over all of this.

--status prints whether the forward is running and healthy (exit 0), or not
(exit 1; exit 2 when --setup was never run). --stop ends it; the next
`mail --remote` starts it again.

Exit codes: 0 done, 1 not running (--status), 2 any error, one line on stderr.
"""

import base64
import contextlib
import errno
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request

PROG = "fork-sandbox mail-forward"
SETUP_FILE = "mail-team.env"
SECRET = "fork-sandbox-mail-api-team-token"
SERVICE = "svc/fork-sandbox-mail-api"
SERVICE_PORT = 80
DEFAULT_PORT = 18765
START_WAIT = 20.0
HEALTH_TIMEOUT = 3
KUBECTL_TIMEOUT = 30
KEYS = {
    "context": "MAIL_TEAM_CONTEXT",
    "namespace": "MAIL_TEAM_NAMESPACE",
    "name": "MAIL_TEAM_NAME",
    "port": "MAIL_TEAM_LOCAL_PORT",
}
NAME_RE = re.compile(r"@[a-z0-9][a-z0-9-]*")
NAMESPACE_RE = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?")
CONTEXT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@/+=-]*")
# What kubectl says when retrying cannot help: the caller's own rights, a
# port that something else holds, a Service that is not there.
PERMANENT_RE = re.compile(
    r"forbidden|unauthorized|address already in use|unable to listen|"
    r"not found|unknown flag|does not exist|no context", re.I)


class ForwardError(Exception):
    """A failure of the setup, the token read or the forward. retryable is
    True when waiting could cure it (a pod being replaced)."""

    def __init__(self, message, retryable=False):
        super().__init__(message)
        self.retryable = retryable


def config_dir():
    return (os.environ.get("FORK_SANDBOX_CONFIG_DIR")
            or os.path.join(os.path.expanduser("~"), ".config",
                            "fork-sandbox"))


def setup_path():
    return os.path.join(config_dir(), SETUP_FILE)


def state_dir():
    base = (os.environ.get("XDG_STATE_HOME")
            or os.path.join(os.path.expanduser("~"), ".local", "state"))
    return os.path.join(base, "fork-sandbox", "mail-forward")


def read_env_file(path):
    """KEY=value lines, first match wins, never sourced. None when absent."""
    try:
        with open(path, encoding="utf-8", newline="\n") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as e:
        raise ForwardError("cannot read %s (%s)" % (path, e.__class__.__name__))
    values = {}
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values.setdefault(key, value)
    return values


def validate(context, namespace, name, port):
    """Raise ForwardError unless all four are acceptable. Returns port as an
    int."""
    if not CONTEXT_RE.fullmatch(context or ""):
        raise ForwardError("the context must be a kube context name, got %s"
                           % ascii(context))
    if len(namespace or "") > 63 or not NAMESPACE_RE.fullmatch(namespace or ""):
        raise ForwardError("the namespace must be a Kubernetes namespace "
                           "name, got %s" % ascii(namespace))
    if not NAME_RE.fullmatch(name or ""):
        raise ForwardError("the name must be your @name (lower-case "
                           "letters, digits and '-', after an '@'), got %s"
                           % ascii(name))
    text = str(port)
    if not (text.isascii() and text.isdigit() and 1024 <= int(text) <= 65535):
        raise ForwardError("the port must be a whole number from 1024 to "
                           "65535, got %s" % ascii(text))
    return int(text)


def load_setup():
    """The recorded setup as a dict, or None when --setup was never run. A
    file that exists but is damaged is an error, not 'never run'."""
    values = read_env_file(setup_path())
    if values is None:
        return None
    got = {k: values.get(v, "") for k, v in KEYS.items()}
    port = got["port"] or str(DEFAULT_PORT)
    try:
        got["port"] = validate(got["context"], got["namespace"], got["name"],
                               port)
    except ForwardError as e:
        raise ForwardError("%s is damaged: %s; run `fork-sandbox "
                           "mail-forward --setup` again" % (setup_path(), e))
    return got


def kubectl_argv(setup, *args):
    """Every kubectl this client runs comes from here, so every one carries
    the configured --context and namespace and none can fall back to the
    kubeconfig's current context. The context goes in --context=CTX form, so
    a value can never be read as another option."""
    return ["kubectl", "--context=%s" % setup["context"],
            "--namespace=%s" % setup["namespace"]] + list(args)


def last_line(text):
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1] if lines else "no detail"


def run_kubectl(setup, *args, timeout=KUBECTL_TIMEOUT):
    try:
        return subprocess.run(kubectl_argv(setup, *args), capture_output=True,
                              text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise ForwardError("kubectl is not installed or not on PATH")
    except subprocess.TimeoutExpired:
        raise ForwardError("kubectl timed out after %d s" % timeout)


def fetch_token(setup):
    """The team token, read with the caller's own kube credentials. It stays
    in memory: it is not written anywhere and not logged."""
    done = run_kubectl(setup, "get", "secret", SECRET,
                       "-o", "jsonpath={.data.token}")
    if done.returncode != 0:
        raise ForwardError("cannot read the team token (secret %s in "
                           "namespace %s, context %s): %s"
                           % (SECRET, setup["namespace"], setup["context"],
                              last_line(done.stderr)))
    try:
        token = base64.b64decode(done.stdout.strip(), validate=True) \
            .decode("utf-8").strip()
    except (ValueError, UnicodeDecodeError):
        token = ""
    if not token:
        raise ForwardError("secret %s has no usable token (has `install "
                           "--postmaster` run with the mail API enabled?)"
                           % SECRET)
    return token


def url_for(setup):
    return "http://127.0.0.1:%d" % setup["port"]


def healthy(setup):
    """True when /healthz answers 'ok' through the forward. No proxy, no
    redirect: nothing here carries a token anyway."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url_for(setup) + "/healthz",
                         timeout=HEALTH_TIMEOUT) as resp:
            return resp.status == 200 and resp.read().strip() == b"ok"
    except Exception:  # refused, reset, timed out, not HTTP: not healthy
        return False


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM
    with contextlib.suppress(OSError):
        done, _ = os.waitpid(pid, os.WNOHANG)  # reap our own child
        if done == pid:
            return False
    return True


def is_our_forward(pid, port):
    """True when pid is a live kubectl port-forward on our port. A recorded
    pid alone proves nothing: it may have been reused by anything."""
    if not alive(pid):
        return False
    try:
        out = subprocess.run(["ps", "-o", "args=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "port-forward" in out and ("%d:%d" % (port, SERVICE_PORT)) in out


def terminate(pid):
    for sig, wait in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 3.0)):
        with contextlib.suppress(OSError):
            os.kill(pid, sig)
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if not alive(pid):
                return
            time.sleep(0.05)


def state_file():
    return os.path.join(state_dir(), "forward.json")


def read_state():
    try:
        with open(state_file(), encoding="utf-8") as f:
            data = json.load(f)
        return {"pid": int(data["pid"]), "port": int(data["port"]),
                "context": str(data["context"]),
                "namespace": str(data["namespace"])}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def write_state(setup, pid):
    path = state_file()
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"pid": pid, "port": setup["port"],
                   "context": setup["context"],
                   "namespace": setup["namespace"]}, f)
    os.replace(tmp, path)


@contextlib.contextmanager
def locked():
    os.makedirs(state_dir(), mode=0o700, exist_ok=True)
    with open(os.path.join(state_dir(), "forward.lock"), "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def current(setup):
    """The recorded forward when it is ours, matches this setup and is
    alive, else None."""
    st = read_state()
    if (st and st["port"] == setup["port"] and st["context"] == setup["context"]
            and st["namespace"] == setup["namespace"]
            and is_our_forward(st["pid"], st["port"])):
        return st
    return None


def drop_stale(setup):
    """End a recorded forward that is unusable (wrong setup, or sick), but
    only ever a process that is verifiably our kubectl port-forward."""
    st = read_state()
    if st and is_our_forward(st["pid"], st["port"]):
        terminate(st["pid"])
    with contextlib.suppress(OSError):
        os.unlink(state_file())


def start(setup):
    log_path = os.path.join(state_dir(), "forward.log")
    log = open(log_path, "wb")
    os.chmod(log_path, 0o600)
    cmd = kubectl_argv(setup, "port-forward", SERVICE, "--address", "127.0.0.1",
                       "%d:%d" % (setup["port"], SERVICE_PORT))
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, close_fds=True,
                                start_new_session=True)
    except FileNotFoundError:
        raise ForwardError("kubectl is not installed or not on PATH")
    finally:
        log.close()
    write_state(setup, proc.pid)
    deadline = time.monotonic() + START_WAIT
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                detail = last_line(f.read())
            with contextlib.suppress(OSError):
                os.unlink(state_file())
            if "address already in use" in detail or "unable to listen" in detail:
                raise ForwardError(
                    "local port %d is in use by something else (%s); pick "
                    "another with `fork-sandbox mail-forward --setup ... "
                    "--port N`" % (setup["port"], detail))
            raise ForwardError(
                "kubectl port-forward exited: %s" % detail,
                retryable=not PERMANENT_RE.search(detail))
        if healthy(setup):
            return
        time.sleep(0.2)
    # Still running, not answering: leave it. The caller's request will fail
    # retryably if the pod is not ready, and the next ensure replaces it.


def ensure_forward(setup):
    """Make sure one working forward is listening, starting or replacing it
    when needed. Returns the base URL. Serialized, so concurrent commands
    share one forward."""
    with locked():
        if current(setup) and healthy(setup):
            return url_for(setup)
        drop_stale(setup)
        start(setup)
    return url_for(setup)


def stop_forward(setup):
    with locked():
        st = read_state()
        running = bool(st and is_our_forward(st["pid"], st["port"]))
        drop_stale(setup)
    return running


def die(message, rc=2):
    sys.stderr.write("%s: %s\n" % (PROG, message))
    return rc


def cmd_setup(args):
    opts = {"context": None, "namespace": None, "name": None,
            "port": str(DEFAULT_PORT)}
    verify = True
    flags = {"--context": "context", "--namespace": "namespace",
             "--name": "name", "--port": "port"}
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--no-verify":
            verify = False
            i += 1
        elif tok in flags and i + 1 < len(args):
            opts[flags[tok]] = args[i + 1]
            i += 2
        else:
            return die("--setup: unknown or incomplete option %s" % ascii(tok))
    for flag, key in flags.items():
        if opts[key] is None:
            return die("--setup needs %s (it is never taken from your "
                       "kubeconfig's current context)" % flag)
    try:
        port = validate(opts["context"], opts["namespace"], opts["name"],
                        opts["port"])
        setup = {"context": opts["context"], "namespace": opts["namespace"],
                 "name": opts["name"], "port": port}
        if verify:
            fetch_token(setup)
    except ForwardError as e:
        return die("--setup: %s" % e)
    path = setup_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Written by `fork-sandbox mail-forward --setup`: how "
                "`fork-sandbox mail --remote`\n# reaches the cluster mail API. "
                "No token is kept here or anywhere on this machine.\n")
        for key, env in KEYS.items():
            f.write("%s=%s\n" % (env, setup[key]))
    os.replace(tmp, path)
    sys.stdout.write("mail --remote is set up as %s: context %s, namespace "
                     "%s, local port %d\n"
                     % (setup["name"], setup["context"], setup["namespace"],
                        setup["port"]))
    return 0


def need_setup():
    try:
        setup = load_setup()
    except ForwardError as e:
        return None, die(str(e))
    if setup is None:
        return None, die("not set up: run `fork-sandbox mail-forward --setup "
                         "--context CTX --namespace NS --name @you`")
    return setup, 0


def cmd_status():
    setup, rc = need_setup()
    if setup is None:
        return rc
    st = current(setup)
    if st and healthy(setup):
        sys.stdout.write("running: pid %d, %s (context %s, namespace %s)\n"
                         % (st["pid"], url_for(setup), setup["context"],
                            setup["namespace"]))
        return 0
    sys.stdout.write("not running (the next `mail --remote` starts it)\n")
    return 1


def cmd_stop():
    setup, rc = need_setup()
    if setup is None:
        return rc
    stopped = stop_forward(setup)
    sys.stdout.write("stopped\n" if stopped else "not running\n")
    return 0


def main(args):
    if not args or args[0] in ("-h", "--help"):
        out = sys.stdout if args else sys.stderr
        out.write(__doc__)
        return 0 if args else 2
    if args[0] == "--setup":
        return cmd_setup(args[1:])
    if args[0] == "--status" and len(args) == 1:
        return cmd_status()
    if args[0] == "--stop" and len(args) == 1:
        return cmd_stop()
    return die("unknown option %s (see --help)" % ascii(args[0]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
