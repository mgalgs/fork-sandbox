#!/usr/bin/env python3
"""fork-sandbox-mail-api.py -- an HTTP API in front of the mail store and the
postmaster, for callers that must not have a shell on the store's host.

Usage: fork-sandbox-mail-api.py serve --tokens <file> [--listen 0.0.0.0:8080]
       fork-sandbox-mail-api.py check --tokens <file>
       fork-sandbox-mail-api.py mint --role operator|client --label <label>
                                [--as @a[,@b]] [--caps read,grant,seen,target]

The server runs ONLY the existing verbs of fork-sandbox-mail.sh (mail) and
fork-sandbox-postmaster.sh (postmaster), from a fixed allowlist, and
authenticates each request with a bearer token. It uses the Python standard
library only. It speaks plain HTTP: put it behind in-cluster traffic or
`kubectl port-forward`; a site that wants TLS fronts it itself. See
docs/mail-api.md.

serve reads the tokens file once, at startup. Rotation is a restart. It runs
the scripts by absolute path from its own directory, with the environment it
was started with (so FORK_SANDBOX_MAIL_ROOT passes through), without a shell.

check runs the loader serve runs on the tokens file and exits: it prints
"ok: <n> entries (<k> operator, <m> client)" and exits 0, or prints the one
line serve would and exits 2. It never prints a hash or a token.

The operator list is $FORK_SANDBOX_OPERATORS, the same variable the
postmaster reads: comma-separated @names, no spaces, no empty elements;
unset or empty means @operator. serve, check and mint all apply it, and a
malformed value refuses them with exit 2.

mint makes a token. It prints the raw token alone on the first line of stdout
and the tokens-file line on the second. It never writes a file, and it checks
its arguments with the same rules serve applies to the file.

Tokens file, one entry per line ('#' comments and blank lines ignored):

    <role> <sha256-hex-of-token> <label> <identities|-> <caps|->

    operator 9f86...08  laptop      -            -
    client   2c26...ae  ci-kickoff  @ci-kickoff  read,grant

The file holds the SHA-256 of each token, never the token. An operator may run
any verb and use any identity; its identities and caps must be '-'. A client
lists the @names it may use as --from (or '-') and its caps, a subset of
read, grant, seen and target (or '-'). Startup refuses the file (exit 2, one line
naming the label, never the hash) on a malformed line, an unknown role or
cap, a malformed identity, a shared hash or label, an empty table, an
operator entry with identities or caps, or a client entry that lists a name
on the operator list. Only an operator token may post as a name on the
operator list; what a client's mail can do to a thread is the postmaster's
rule 1, which in cluster mode gives authority only to that list (see
docs/mail-api.md).

HTTP:

    GET  /healthz    no auth; 200 "ok"
    POST /v1/exec    Authorization: Bearer <token>; JSON body, at most 24 MiB:
      {"tool": "mail"|"postmaster", "argv": ["send", "--from", "@a", ...],
       "stdin_b64": "<base64, optional>", "files": {"name": "<base64>"}}

The reply is always JSON. 200 {"rc", "stdout_b64", "stderr_b64"} when the verb
ran, whatever its exit code. Otherwise {"error": "<one line>"}: 400 bad
request, 401 no or bad token, 403 not allowed, 404/405 wrong path or method,
411/413 missing or oversized length or upload, 504 the verb ran over 60 s and
was killed.

Allowlist (verb: positionals; flags; who may run it). A flag is matched
exactly (no --flag=value, no abbreviation, no combined short flags); its value
is the next argv element. A lone '-' is a positional; any other token that
starts with '-' is a flag, so a positional that starts with '-' is refused.
mail:
    send    0; --from --to --cc --subject --body --attach* --hops --header*
            --allow-namespace* --reach-probe* --review-target; --from in the
            token's identities (the two grant flags also need cap grant,
            --review-target needs cap target)
    reply   0; --from --reply-to --body --to --cc --subject --attach* --hops
            --header*; --from in the token's identities
    show tree list export inbox: read (export needs --json; inbox takes --all)
    seen    1+; the first positional in the identities, and cap seen
    grant   1; --allow-namespace* --reach-probe* --clear --show --json;
            --show needs read, anything else needs grant
postmaster:
    status  0; --thread --json; read
    flag unflag: operator only
(* = repeatable.) On mail send and mail reply, --header may not set
X-Version or a name that starts with X-Review-Target (case-insensitively):
those headers are the review-target contract, and only mail's own
--review-target flag and the postmaster may write them -- this refusal
applies to an operator token too. An operator passes every other check.
--body must be '-': the
body comes in stdin_b64. --attach names a key of "files" (a plain basename,
at most 4 MiB decoded, at most 16 files, no unreferenced keys); the server
writes each file to a private temp directory and deletes it after the call.
stdin_b64 is at most 4 MiB decoded and stdin is empty when it is absent.

One log line per request goes to stderr: time, label, tool, verb, status, rc.
It never holds a token, a body, a file or an argv value.
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import http.server
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

PROG = "fork-sandbox-mail-api"
ROLES = ("operator", "client")
CAPS = ("read", "grant", "seen", "target")
ADDR_RE = re.compile(r"@[a-z0-9][a-z0-9-]*")
OPERATORS_ENV = "FORK_SANDBOX_OPERATORS"
LABEL_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
HASH_RE = re.compile(r"[0-9a-fA-F]{64}")

MAX_BODY = 24 * 1024 * 1024
MAX_FILE = 4 * 1024 * 1024
MAX_STDIN = 4 * 1024 * 1024
MAX_FILES = 16
MAX_ARGV = 1024
EXEC_TIMEOUT = 60

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
TOOL_SCRIPTS = {
    "mail": os.path.join(SCRIPT_DIR, "fork-sandbox-mail.sh"),
    "postmaster": os.path.join(SCRIPT_DIR, "fork-sandbox-postmaster.sh"),
}

BOOL, VALUE, MULTI = "bool", "value", "multi"

# tool -> verb -> (min positionals, max positionals or None, flag kinds).
# Only the shape of argv is checked here. The values are left to the scripts,
# which already validate them.
SPEC = {
    "mail": {
        "send": (0, 0, {
            "--from": VALUE, "--to": VALUE, "--cc": VALUE,
            "--subject": VALUE, "--body": VALUE, "--attach": MULTI,
            "--hops": VALUE, "--header": MULTI,
            "--allow-namespace": MULTI, "--reach-probe": MULTI,
            "--review-target": VALUE}),
        "reply": (0, 0, {
            "--from": VALUE, "--reply-to": VALUE, "--body": VALUE,
            "--to": VALUE, "--cc": VALUE, "--subject": VALUE,
            "--attach": MULTI, "--hops": VALUE, "--header": MULTI}),
        "show": (1, 1, {}),
        "tree": (1, 1, {}),
        "list": (0, 0, {}),
        "inbox": (1, 1, {"--all": BOOL}),
        "export": (1, 1, {"--json": BOOL}),
        "seen": (1, None, {}),
        "grant": (1, 1, {
            "--allow-namespace": MULTI, "--reach-probe": MULTI,
            "--clear": BOOL, "--show": BOOL, "--json": BOOL}),
    },
    "postmaster": {
        "status": (0, 0, {"--thread": VALUE, "--json": BOOL}),
        "flag": (1, 2, {}),
        "unflag": (1, 1, {}),
    },
}

# --context-ro takes a host directory to mount read-only into a run. A path
# on the server's host means nothing to a remote caller, and would let one
# name a directory of the store's host, so it is refused outright.
REFUSED_FLAGS = {
    ("mail", "send"): {"--context-ro"},
    ("mail", "grant"): {"--context-ro"},
}
REFUSED_WHY = "a host path has no meaning over the API"

# The review-target contract's headers: only mail's own --review-target
# flag and the postmaster may write them, so --header is refused for both
# names, for every caller including the operator (see authorize(), which
# returns immediately for an operator and so cannot enforce this).
REVIEW_TARGET_HEADER_WHY = (
    "--header may not set a review-target header: only --review-target "
    "and the postmaster may set it")


def refused_header_name(raw):
    name = raw.split(":", 1)[0].strip().upper()
    return name == "X-VERSION" or name.startswith("X-REVIEW-TARGET")


OPERATORS = frozenset(["@operator"])

OPERATOR_ONLY = {("postmaster", "flag"), ("postmaster", "unflag")}
GRANT_FLAGS = ("--allow-namespace", "--reach-probe")


class ConfigError(Exception):
    pass


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Entry:
    def __init__(self, role, digest, label, identities, caps):
        self.role = role
        self.digest = digest
        self.label = label
        self.identities = frozenset(identities)
        self.caps = frozenset(caps)

    def is_operator(self):
        return self.role == "operator"

    def can(self, cap):
        return self.is_operator() or cap in self.caps


def parse_list(field):
    if field == "-":
        return []
    return field.split(",")


def operator_names():
    """The operator list from $FORK_SANDBOX_OPERATORS, parsed and validated
    as the postmaster does: comma-separated @names, no spaces, no empty
    elements; unset or empty means @operator."""
    raw = os.environ.get(OPERATORS_ENV, "")
    if not raw:
        return frozenset(["@operator"])
    names = raw.split(",")
    for name in names:
        if not ADDR_RE.fullmatch(name):
            raise ConfigError(
                "$%s element %s is not an @name (comma-separated, no "
                "spaces, no empty elements)" % (OPERATORS_ENV, ascii(name)))
    return frozenset(names)


def validate_entry(role, digest, label, identities, caps, operators):
    """The one rule set for a tokens-file entry, shared by the loader and
    mint. Fields are strings as they appear in the file ('-' for none).
    Returns an Entry or raises ConfigError. A message never carries the
    hash, and never echoes a field other than the label."""
    if not (LABEL_RE.fullmatch(label) and not HASH_RE.fullmatch(label)):
        raise ConfigError("malformed label")
    if role not in ROLES:
        raise ConfigError("unknown role")
    if not HASH_RE.fullmatch(digest):
        raise ConfigError("malformed token hash")
    ids = parse_list(identities)
    cap_list = parse_list(caps)
    if role == "operator":
        if identities != "-" or caps != "-":
            raise ConfigError(
                "an operator entry must have '-' for identities and caps")
    else:
        for ident in ids:
            if not ADDR_RE.fullmatch(ident):
                raise ConfigError("malformed identity")
            if ident in operators:
                raise ConfigError(
                    "a client entry may not list %s: only an operator "
                    "token may post as a name on the operator list" % ident)
        for cap in cap_list:
            if cap not in CAPS:
                raise ConfigError("unknown cap")
    return Entry(role, digest.lower(), label, ids, cap_list)


def load_tokens(path, operators):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise ConfigError("cannot read tokens file: %s" % e.__class__.__name__)
    entries = []
    by_digest = {}
    by_label = {}
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        where = "line %d" % number
        if len(fields) != 5:
            raise ConfigError("%s: malformed (want 5 fields)" % where)
        role, digest, label, identities, caps = fields
        if LABEL_RE.fullmatch(label) and not HASH_RE.fullmatch(label):
            where = "entry '%s'" % label
        try:
            entry = validate_entry(role, digest, label, identities, caps,
                                   operators)
        except ConfigError as e:
            raise ConfigError("%s: %s" % (where, e))
        if entry.label in by_label:
            raise ConfigError("duplicate label '%s'" % entry.label)
        if entry.digest in by_digest:
            raise ConfigError("entries '%s' and '%s' share a token hash"
                              % (by_digest[entry.digest], entry.label))
        by_label[entry.label] = True
        by_digest[entry.digest] = entry.label
        entries.append(entry)
    if not entries:
        raise ConfigError("no entries in the tokens file")
    return entries


def die(message):
    sys.stderr.write("%s: %s\n" % (PROG, message))
    sys.exit(2)


# ---------------------------------------------------------------- allowlist

def shown(text):
    """A short, one-line, printable form of a caller-supplied string for an
    error reply. Never for the log."""
    out = ascii(str(text))
    return out if len(out) <= 48 else out[:45] + "..."


def parse_argv(tool, argv):
    """Split argv into (verb, positionals, flags, attach_at), checking only
    its shape. flags maps a flag to the list of its values ([] for a bool
    flag); attach_at lists the argv indexes holding an --attach value."""
    verb = argv[0]
    verbs = SPEC[tool]
    if verb not in verbs:
        raise ApiError(403, "verb %s is not allowed for %s"
                       % (shown(verb), tool))
    min_pos, max_pos, kinds = verbs[verb]
    refused = REFUSED_FLAGS.get((tool, verb), ())
    positionals = []
    flags = {}
    attach_at = []
    i = 1
    while i < len(argv):
        tok = argv[i]
        i += 1
        if not (tok.startswith("-") and len(tok) > 1):
            positionals.append(tok)
            continue
        if tok in refused:
            raise ApiError(403, "%s %s: %s: %s"
                           % (tool, verb, tok, REFUSED_WHY))
        kind = kinds.get(tok)
        if kind is None:
            raise ApiError(403, "%s %s: flag %s is not allowed"
                           % (tool, verb, shown(tok)))
        if kind != BOOL:
            if i >= len(argv):
                raise ApiError(400, "%s %s: %s needs a value"
                               % (tool, verb, tok))
            value = argv[i]
            if tok == "--attach":
                attach_at.append(i)
            i += 1
            values = flags.setdefault(tok, [])
            if values and kind != MULTI:
                raise ApiError(400, "%s %s: %s given twice"
                               % (tool, verb, tok))
            values.append(value)
        else:
            if tok in flags:
                raise ApiError(400, "%s %s: %s given twice"
                               % (tool, verb, tok))
            flags[tok] = []
    n = len(positionals)
    if n < min_pos or (max_pos is not None and n > max_pos):
        raise ApiError(400, "%s %s: wrong number of arguments" % (tool, verb))
    return verb, positionals, flags, attach_at


def authorize(entry, tool, verb, positionals, flags):
    """Raise ApiError(403) unless this token may run this call. Client
    identity checks compare the flag's value to the entry's identities
    exactly; a client entry never holds an operator-list name (the loader
    refuses it), so a client can never post as one."""
    if entry.is_operator():
        return
    key = (tool, verb)
    if key in OPERATOR_ONLY:
        raise ApiError(403, "%s %s needs an operator token" % key)
    if key in (("mail", "send"), ("mail", "reply")):
        sender = flags.get("--from")
        if sender is not None and sender[0] in OPERATORS:
            raise ApiError(403, "only an operator token may post as a name "
                                "on the operator list")
        if sender is not None and sender[0] not in entry.identities:
            raise ApiError(403, "--from is not one of this token's identities")
        if key == ("mail", "send") and any(f in flags for f in GRANT_FLAGS):
            need(entry, "grant")
        if key == ("mail", "send") and "--review-target" in flags:
            need(entry, "target")
        return
    if key == ("mail", "seen"):
        if "@" + positionals[0] not in entry.identities:
            raise ApiError(403, "that name is not one of this token's "
                                "identities")
        need(entry, "seen")
        return
    if key == ("mail", "grant"):
        writes = any(f in flags for f in
                     GRANT_FLAGS + ("--clear",))
        if "--show" in flags:
            need(entry, "read")
        if writes or "--show" not in flags:
            need(entry, "grant")
        return
    need(entry, "read")


def need(entry, cap):
    if not entry.can(cap):
        raise ApiError(403, "this token lacks the '%s' cap" % cap)


def plain_basename(name):
    return bool(name) and not name.startswith(".") \
        and "/" not in name and "\0" not in name and "\n" not in name \
        and len(name.encode("utf-8", "surrogatepass")) <= 255


def decode_b64(text, what):
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        raise ApiError(400, "%s is not valid base64" % what)


# ---------------------------------------------------------------- execution

def run_tool(tool, argv, stdin):
    """Run the script and return (rc, stdout, stderr). The child gets its
    own session so a timeout can kill its whole process group, not just the
    shell (subprocess.run would leave grandchildren holding the pipes)."""
    proc = subprocess.Popen(
        [TOOL_SCRIPTS[tool]] + argv, shell=False, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    try:
        out, err = proc.communicate(stdin, timeout=EXEC_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        raise ApiError(504, "the command ran over %d s and was killed"
                       % EXEC_TIMEOUT)
    rc = proc.returncode
    if rc < 0:
        rc = 128 - rc
    return rc, out, err


def handle_exec(entry, raw, ctx):
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise ApiError(400, "the body is not valid JSON")
    if not isinstance(data, dict):
        raise ApiError(400, "the body must be a JSON object")
    if set(data) - {"tool", "argv", "stdin_b64", "files"}:
        raise ApiError(400, "unknown key in the request")
    tool = data.get("tool")
    if not isinstance(tool, str):
        raise ApiError(400, "tool must be a string")
    if tool not in SPEC:
        raise ApiError(403, "tool %s is not allowed" % shown(tool))
    ctx["tool"] = tool
    argv = data.get("argv")
    if not (isinstance(argv, list) and argv
            and len(argv) <= MAX_ARGV
            and all(isinstance(a, str) for a in argv) and argv[0]):
        raise ApiError(400, "argv must be a non-empty list of strings "
                            "starting with a verb")
    if any("\0" in a for a in argv):
        raise ApiError(400, "argv may not contain a NUL byte")
    stdin_b64 = data.get("stdin_b64")
    if stdin_b64 is not None and not isinstance(stdin_b64, str):
        raise ApiError(400, "stdin_b64 must be a string")
    files = data.get("files")
    if files is None:
        files = {}
    if not (isinstance(files, dict)
            and all(isinstance(v, str) for v in files.values())):
        raise ApiError(400, "files must be an object of base64 strings")

    verb, positionals, flags, attach_at = parse_argv(tool, argv)
    ctx["verb"] = verb
    authorize(entry, tool, verb, positionals, flags)

    if (tool, verb) in (("mail", "send"), ("mail", "reply")):
        for raw in flags.get("--header", []):
            if refused_header_name(raw):
                raise ApiError(403, REVIEW_TARGET_HEADER_WHY)
        if flags.get("--body", ["-"]) != ["-"]:
            raise ApiError(400, "--body must be '-' over the API; send the "
                                "body as stdin_b64")
    attach = flags.get("--attach", [])
    if len(set(attach)) != len(attach):
        raise ApiError(400, "--attach names the same file twice")
    for name in attach:
        if not plain_basename(name):
            raise ApiError(400, "--attach must be a plain file name")
        if name not in files:
            raise ApiError(400, "--attach names a file that was not uploaded")
    if set(files) - set(attach):
        raise ApiError(400, "files holds a key that no --attach names")
    if len(files) > MAX_FILES:
        raise ApiError(413, "at most %d files" % MAX_FILES)
    stdin = b""
    if stdin_b64:
        stdin = decode_b64(stdin_b64, "stdin_b64")
        if len(stdin) > MAX_STDIN:
            raise ApiError(413, "stdin is over %d bytes" % MAX_STDIN)
    blobs = {}
    for name, text in files.items():
        blobs[name] = decode_b64(text, "a file")
        if len(blobs[name]) > MAX_FILE:
            raise ApiError(413, "a file is over %d bytes" % MAX_FILE)

    tmp = tempfile.mkdtemp(prefix="fork-sandbox-mail-api.")
    try:
        paths = {}
        for name, blob in blobs.items():
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "wb") as f:
                f.write(blob)
        run_argv = list(argv)
        for i in attach_at:
            run_argv[i] = paths[argv[i]]
        return run_tool(tool, run_argv, stdin)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------- server

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fork-sandbox-mail-api"
    sys_version = ""
    timeout = 120
    entries = ()
    log_lock = threading.Lock()

    def setup(self):
        super().setup()
        self.ctx = {"label": "-", "tool": "-", "verb": "-", "rc": "-"}
        self.logged = False

    def log_message(self, *args):
        pass

    def respond(self, status, body, ctype, headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)
        if not self.logged:
            self.logged = True
            c = self.ctx
            line = "%s %s %s %s %d rc=%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                c["label"], c["tool"], c["verb"], status, c["rc"])
            with Handler.log_lock:
                sys.stderr.write(line)
                sys.stderr.flush()

    def send_json(self, status, obj, headers=()):
        body = (json.dumps(obj) + "\n").encode("ascii")
        self.respond(status, body, "application/json", headers)

    def send_error(self, code, message=None, explain=None):
        if code == 501:
            code = 405
        self.close_connection = True
        self.send_json(code, {"error": (message or "request refused")
                              .splitlines()[0]})

    def authenticate(self):
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        found = None
        if scheme.lower() == "bearer" and token.strip():
            digest = hashlib.sha256(
                token.strip().encode("latin-1", "replace")).hexdigest()
            for entry in self.entries:
                if hmac.compare_digest(digest, entry.digest):
                    found = entry
        return found

    def method_not_allowed(self, allow):
        self.send_json(405, {"error": "method not allowed"},
                       [("Allow", allow)])

    def do_GET(self):
        if self.path == "/healthz":
            self.respond(200, b"ok\n", "text/plain")
        elif self.path == "/v1/exec":
            self.method_not_allowed("POST")
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/healthz":
            return self.method_not_allowed("GET")
        if self.path != "/v1/exec":
            return self.send_json(404, {"error": "not found"})
        try:
            self.exec_request()
        except ApiError as e:
            self.send_json(e.status, {"error": e.message},
                           [("WWW-Authenticate", "Bearer")]
                           if e.status == 401 else ())
        except Exception:
            self.send_json(500, {"error": "internal error"})

    def exec_request(self):
        entry = self.authenticate()
        if entry is None:
            raise ApiError(401, "missing or bad token")
        self.ctx["label"] = entry.label
        length = self.headers.get("Content-Length")
        if length is None:
            raise ApiError(411, "Content-Length is required")
        if not re.fullmatch(r"[0-9]{1,12}", length):
            raise ApiError(400, "bad Content-Length")
        length = int(length)
        if length > MAX_BODY:
            raise ApiError(413, "the body is over %d bytes" % MAX_BODY)
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise ApiError(400, "the body ended early")
        rc, out, err = handle_exec(entry, raw, self.ctx)
        self.ctx["rc"] = str(rc)
        self.send_json(200, {
            "rc": rc,
            "stdout_b64": base64.b64encode(out).decode("ascii"),
            "stderr_b64": base64.b64encode(err).decode("ascii")})

    def do_PUT(self):
        self.method_not_allowed("GET, POST")

    do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_PUT


def parse_listen(text):
    host, sep, port = text.rpartition(":")
    if not sep or not port.isascii() or not port.isdigit() \
            or int(port) > 65535:
        die("--listen wants HOST:PORT")
    return host.strip("[]") or "0.0.0.0", int(port)


def load_or_die(path):
    """Load the tokens file under the env operator list, or exit 2 with one
    line. Returns (entries, operators)."""
    try:
        operators = operator_names()
        return load_tokens(path, operators), operators
    except ConfigError as e:
        die("%s: %s" % (path, e))


def cmd_check(args):
    entries, _ = load_or_die(args.tokens)
    ops = sum(1 for e in entries if e.is_operator())
    sys.stdout.write("ok: %d entries (%d operator, %d client)\n"
                     % (len(entries), ops, len(entries) - ops))
    return 0


def cmd_serve(args):
    global OPERATORS
    entries, OPERATORS = load_or_die(args.tokens)
    for path in TOOL_SCRIPTS.values():
        if not os.access(path, os.X_OK):
            die("%s is not executable" % path)
    host, port = parse_listen(args.listen)
    Handler.entries = tuple(entries)
    try:
        httpd = http.server.ThreadingHTTPServer((host, port), Handler)
    except OSError as e:
        die("cannot listen on %s: %s" % (args.listen, e))

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    sys.stderr.write("listening on %s:%d\n" % (host, httpd.server_port))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


def cmd_mint(args):
    import secrets
    ids = args.identities if args.identities is not None else "-"
    caps = args.caps if args.caps is not None else "-"
    token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(token.encode("ascii")).hexdigest()
    try:
        validate_entry(args.role, digest, args.label, ids or "-", caps or "-",
                       operator_names())
    except ConfigError as e:
        die("mint: %s" % e)
    sys.stdout.write("%s\n%s %s %s %s %s\n"
                     % (token, args.role, digest, args.label,
                        ids or "-", caps or "-"))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help") \
            or "-h" in argv[2:] or "--help" in argv[2:]:
        out = sys.stdout if len(argv) >= 2 else sys.stderr
        out.write(__doc__)
        return 0 if len(argv) >= 2 else 2
    parser = argparse.ArgumentParser(prog=PROG, add_help=False,
                                     allow_abbrev=False)
    sub = parser.add_subparsers(dest="cmd")
    serve = sub.add_parser("serve", add_help=False, allow_abbrev=False)
    serve.add_argument("--tokens", required=True)
    serve.add_argument("--listen", default="0.0.0.0:8080")
    check = sub.add_parser("check", add_help=False, allow_abbrev=False)
    check.add_argument("--tokens", required=True)
    mint = sub.add_parser("mint", add_help=False, allow_abbrev=False)
    mint.add_argument("--role", required=True)
    mint.add_argument("--label", required=True)
    mint.add_argument("--as", dest="identities")
    mint.add_argument("--caps")
    args = parser.parse_args(argv[1:])
    if args.cmd == "serve":
        return cmd_serve(args)
    if args.cmd == "check":
        return cmd_check(args)
    if args.cmd == "mint":
        return cmd_mint(args)
    parser.error("expected serve, check or mint")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
