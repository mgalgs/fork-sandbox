#!/usr/bin/env python3
"""fork-sandbox-mail-remote.py -- the client for the mail API server.

Usage: fork-sandbox-mail-remote.py <mail|postmaster> <verb> [args...]

Not called by hand: `fork-sandbox mail --remote <verb> ...` and
`fork-sandbox postmaster --remote <verb> ...` exec it, so a laptop and a CI
job run the same command line as on the store's host. It sends the verb to the
server in fork-sandbox-mail-api.py and behaves like the local verb: the reply's
stdout and stderr are written byte-exact and the exit code is the verb's.
Other failures (no config, no route, HTTP 4xx/5xx) print one line to stderr
and exit 2. `--remote --help` prints this text.

Config, from the environment, else from ${FORK_SANDBOX_CONFIG_DIR:-
$HOME/.config/fork-sandbox}/k8s.env (KEY=value lines, read, never sourced):

    FORK_SANDBOX_MAIL_API_URL         K8S_MAIL_API_URL          e.g. http://127.0.0.1:8080
    FORK_SANDBOX_MAIL_API_TOKEN_FILE  K8S_MAIL_API_TOKEN_FILE   a file holding the token

The token file's trailing whitespace is stripped.

For transport only, `send` and `reply` are rewritten: `--body <file>` becomes
`--body -` with the file's bytes as stdin, `--body -` sends this process's
stdin, and `--attach <path>` becomes `--attach <basename>` with the bytes
uploaded alongside. Two attachments with one basename are refused here. Nothing
else is validated: the server is the boundary.

The connection ignores http_proxy and friends and does not follow redirects,
so the token goes only to the configured URL.
"""

import base64
import http.client
import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT = 90
TOOLS = ("mail", "postmaster")
URL_KEYS = ("FORK_SANDBOX_MAIL_API_URL", "K8S_MAIL_API_URL")
TOKEN_KEYS = ("FORK_SANDBOX_MAIL_API_TOKEN_FILE", "K8S_MAIL_API_TOKEN_FILE")

# The flags of send and reply that take a value, so a value that reads
# "--body" is never taken for the flag.
VALUE_FLAGS = {
    "--from", "--to", "--cc", "--subject", "--body", "--attach", "--hops",
    "--header", "--allow-namespace", "--reach-probe", "--context-ro",
    "--context-secret", "--reply-to",
}


class Fail(Exception):
    def __init__(self, message, rc=2):
        super().__init__(message)
        self.rc = rc


def read_env_key(path, key):
    """One KEY=value line from an env file, the first match wins, None when
    the file or the key is absent. Parsed line by line like
    fork-sandbox-k8s.sh's read_env_value; never sourced."""
    try:
        with open(path, encoding="utf-8", newline="\n") as f:
            lines = f.read().split("\n")
    except OSError:
        return None
    for line in lines:
        if not line or line.startswith("#"):
            continue
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    return None


def k8s_env_path():
    config_dir = (os.environ.get("FORK_SANDBOX_CONFIG_DIR")
                  or os.path.join(os.path.expanduser("~"),
                                  ".config", "fork-sandbox"))
    return os.path.join(config_dir, "k8s.env")


def setting(keys):
    """The first of keys[0] in the environment, else keys[1] in k8s.env."""
    value = os.environ.get(keys[0])
    if not value:
        value = read_env_key(k8s_env_path(), keys[1])
    return (value or "").strip()


def config(tool):
    prefix = "fork-sandbox %s --remote: " % tool
    url = setting(URL_KEYS)
    if not url:
        raise Fail("%sno API URL: set %s or %s in %s"
                   % (prefix, URL_KEYS[0], URL_KEYS[1], k8s_env_path()))
    if not url.startswith(("http://", "https://")):
        raise Fail("%sthe API URL must start with http:// or https://"
                   % prefix)
    token_file = setting(TOKEN_KEYS)
    if not token_file:
        raise Fail("%sno token file: set %s or %s in %s"
                   % (prefix, TOKEN_KEYS[0], TOKEN_KEYS[1], k8s_env_path()))
    try:
        with open(token_file, encoding="utf-8") as f:
            token = f.read().rstrip()
    except (OSError, UnicodeDecodeError) as e:
        raise Fail("%sno token: cannot read the token file (%s)"
                   % (prefix, e.__class__.__name__))
    if not token:
        raise Fail("%sno token: the token file is empty (%s or %s)"
                   % (prefix, TOKEN_KEYS[0], TOKEN_KEYS[1]))
    return url.rstrip("/") + "/v1/exec", token


def read_file(path, what):
    if not os.path.isfile(path):
        raise Fail("Error: %s '%s' not found." % (what, path), rc=1)
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        raise Fail("Error: %s '%s' is unreadable: %s"
                   % (what, path, e.strerror), rc=1)


def rewrite(tool, argv):
    """Rewrite send/reply's --body and --attach for transport. Returns
    (argv, stdin bytes or None, files)."""
    if tool != "mail" or not argv or argv[0] not in ("send", "reply"):
        return argv, None, {}
    out = [argv[0]]
    stdin = None
    files = {}
    i = 1
    while i < len(argv):
        tok = argv[i]
        out.append(tok)
        i += 1
        if tok not in VALUE_FLAGS or i >= len(argv):
            continue
        value = argv[i]
        i += 1
        if tok == "--body":
            if value == "-":
                if stdin is None:
                    stdin = sys.stdin.buffer.read()
            else:
                stdin = read_file(value, "body file")
            value = "-"
        elif tok == "--attach":
            base = os.path.basename(value)
            data = read_file(value, "--attach file")
            if base in files:
                raise Fail("fork-sandbox mail --remote: two --attach files "
                           "share the name '%s'" % base)
            files[base] = data
            value = base
        out.append(value)
    return out, stdin, files


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def post(tool, url, token, request):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect)
    req = urllib.request.Request(
        url, data=json.dumps(request).encode("ascii"), method="POST",
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"})
    prefix = "fork-sandbox %s --remote: " % tool
    try:
        with opener.open(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            message = str(json.loads(e.read())["error"])
        except (ValueError, KeyError, TypeError, OSError):
            message = e.reason or "no detail"
        message = " ".join(message.split()) or "no detail"
        raise Fail("%sHTTP %d: %s" % (prefix, e.code, message))
    except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
        reason = getattr(e, "reason", None) or e
        raise Fail("%scannot reach %s: %s"
                   % (prefix, url.rsplit("/v1/exec", 1)[0],
                      " ".join(str(reason).split())))
    except ValueError:
        raise Fail("%sthe server sent a reply that is not JSON" % prefix)


def run(tool, argv):
    url, token = config(tool)
    argv, stdin, files = rewrite(tool, argv)
    request = {"tool": tool, "argv": argv}
    if stdin is not None:
        request["stdin_b64"] = base64.b64encode(stdin).decode("ascii")
    if files:
        request["files"] = {name: base64.b64encode(data).decode("ascii")
                            for name, data in files.items()}
    reply = post(tool, url, token, request)
    try:
        rc = int(reply["rc"])
        out = base64.b64decode(reply["stdout_b64"])
        err = base64.b64decode(reply["stderr_b64"])
    except (KeyError, TypeError, ValueError):
        raise Fail("fork-sandbox %s --remote: the server sent a malformed "
                   "reply" % tool)
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    return rc


def main(args):
    if (args[:1] in (["-h"], ["--help"])
            or (len(args) == 2 and args[1] in ("-h", "--help"))):
        sys.stdout.write(__doc__)
        return 0
    if len(args) < 2 or args[0] not in TOOLS:
        sys.stderr.write("usage: fork-sandbox-mail-remote.py "
                         "<mail|postmaster> <verb> [args...]\n")
        return 2
    try:
        return run(args[0], args[1:])
    except Fail as e:
        sys.stderr.write("%s\n" % e)
        return e.rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
