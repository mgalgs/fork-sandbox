#!/usr/bin/env python3
"""lane-mail-kv.py -- the key/value store behind `lane-mail.sh kv`.

Usage: lane-mail-kv.py <store-dir> get [--json] <key>
       lane-mail-kv.py <store-dir> set <key> <value|-> [--if-version <v> | --if-absent]
       lane-mail-kv.py <store-dir> del <key> [--if-version <v>]
       lane-mail-kv.py <store-dir> list [--json] [--prefix <p>]

Plumbing: run it through `lane-mail.sh kv`, which passes the store
directory (<LANE_MAIL_ROOT>/kv) itself. The verbs, exit codes, key and
value rules and version semantics are documented in lane-mail.sh's
header; this one only records how the store is laid out.

Layout. One file per key, directly in <store-dir>. Its name is the key
with every '/' replaced by '%': '%' is not in the key alphabet, so the
mapping is injective and reversible, and since a key cannot start with
'.', no name is '.', '..' or a dot-file. Keys never become paths with
more than one component, so no key can address anything outside the
store. Hex was not used because a 200-character key would hex-encode to
400 bytes, past the 255-byte file-name limit. Dot-files are the store's
own: '.lock' and '.tmp-*' temp files.

Record. The file holds '<version>\\n' followed by the value's bytes
verbatim. A write builds the record in a temp file in the same
directory and renames it over the key's file, so a reader -- which
takes no lock -- sees either the old record or the new one, never a mix.

Writes. Every set and del, including the precondition check of a
conditional one, runs under one exclusive flock on <store-dir>/.lock;
the check and the write happen under the same hold.

Versions. '<ns since epoch, hex>-<16 random hex digits>', new on every
write and never derived from the key or value, so deleting and
recreating a key never reissues a token a stale client may hold.
"""

import fcntl
import json
import os
import re
import secrets
import sys
import tempfile
import time

KEY_RE = re.compile(r"[A-Za-z0-9@][A-Za-z0-9._:/#@+=-]{0,199}")
MAX_VALUE = 64 * 1024
LOCK_NAME = ".lock"

EXIT_ABSENT = 1
EXIT_USAGE = 2
EXIT_PRECONDITION = 3


class Fail(Exception):
    def __init__(self, code, msg=""):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def usage(msg):
    raise Fail(EXIT_USAGE, msg)


def check_key(key):
    if not KEY_RE.fullmatch(key):
        usage("bad key %r (want ^[A-Za-z0-9@][A-Za-z0-9._:/#@+=-]{0,199}$)" % key)


def file_name(key):
    return key.replace("/", "%")


def key_of(name):
    return name.replace("%", "/")


def read_record(store, key):
    """Returns (version, value bytes), or None when the key is absent."""
    try:
        with open(os.path.join(store, file_name(key)), "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return None
    version, _, value = data.partition(b"\n")
    return version.decode("ascii"), value


def new_version():
    return "%x-%s" % (time.time_ns(), secrets.token_hex(8))


def as_text(value):
    # JSON strings cannot carry arbitrary bytes; plain `get` is the
    # byte-exact path.
    return value.decode("utf-8", errors="replace")


class Locked:
    def __init__(self, store):
        self.store = store
        self.fd = -1

    def __enter__(self):
        os.makedirs(self.store, exist_ok=True)
        self.fd = os.open(os.path.join(self.store, LOCK_NAME), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        os.close(self.fd)  # releases the flock


def write_record(store, key, version, value):
    fd, tmp = tempfile.mkstemp(dir=store, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(version.encode("ascii") + b"\n" + value)
        os.rename(tmp, os.path.join(store, file_name(key)))
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def check_version(store, key, want, verb):
    rec = read_record(store, key)
    if rec is None:
        raise Fail(EXIT_PRECONDITION, "%s %s: --if-version %s failed: the key does not exist" % (verb, key, want))
    if rec[0] != want:
        raise Fail(EXIT_PRECONDITION, "%s %s: --if-version %s failed: the current version is %s" % (verb, key, want, rec[0]))


def parse(args, flags, valued):
    """Splits args into positionals and a dict of flags. `flags` are
    switches, `valued` take one argument; `--` ends flag parsing."""
    pos, opts = [], {}
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a in flags:
            opts[a] = True
        elif a in valued:
            if i + 1 >= len(args):
                usage("%s needs a value" % a)
            opts[a] = args[i + 1]
            i += 1
        elif a.startswith("--"):
            usage("unknown option %s" % a)
        else:
            pos.append(a)
        i += 1
    return pos, opts


def cmd_get(store, args):
    pos, opts = parse(args, {"--json"}, set())
    if len(pos) != 1:
        usage("usage: kv get [--json] <key>")
    key = pos[0]
    check_key(key)
    rec = read_record(store, key)
    if rec is None:
        raise Fail(EXIT_ABSENT)
    version, value = rec
    if "--json" in opts:
        print(json.dumps({"key": key, "value": as_text(value), "version": version}))
    else:
        sys.stdout.buffer.write(value)
        sys.stdout.buffer.flush()


def cmd_set(store, args):
    pos, opts = parse(args, {"--if-absent"}, {"--if-version"})
    if len(pos) != 2:
        usage("usage: kv set <key> <value|-> [--if-version <v> | --if-absent]")
    if "--if-absent" in opts and "--if-version" in opts:
        usage("--if-version and --if-absent are mutually exclusive")
    key = pos[0]
    check_key(key)
    if pos[1] == "-":
        value = sys.stdin.buffer.read(MAX_VALUE + 1)
    else:
        value = os.fsencode(pos[1])
    if len(value) > MAX_VALUE:
        usage("value is over %d bytes" % MAX_VALUE)
    if b"\0" in value:
        usage("value contains a NUL byte")
    with Locked(store):
        if "--if-absent" in opts:
            rec = read_record(store, key)
            if rec is not None:
                raise Fail(EXIT_PRECONDITION, "set %s: --if-absent failed: the key exists (version %s)" % (key, rec[0]))
        elif "--if-version" in opts:
            check_version(store, key, opts["--if-version"], "set")
        version = new_version()
        write_record(store, key, version, value)
    print(version)


def cmd_del(store, args):
    pos, opts = parse(args, set(), {"--if-version"})
    if len(pos) != 1:
        usage("usage: kv del <key> [--if-version <v>]")
    key = pos[0]
    check_key(key)
    if not os.path.isdir(store):
        raise Fail(EXIT_ABSENT)
    with Locked(store):
        if read_record(store, key) is None:
            raise Fail(EXIT_ABSENT)
        if "--if-version" in opts:
            check_version(store, key, opts["--if-version"], "del")
        os.unlink(os.path.join(store, file_name(key)))


def cmd_list(store, args):
    pos, opts = parse(args, {"--json"}, {"--prefix"})
    if pos:
        usage("usage: kv list [--json] [--prefix <p>]")
    prefix = opts.get("--prefix", "")
    try:
        names = os.listdir(store)
    except FileNotFoundError:
        names = []
    keys = sorted(k for k in (key_of(n) for n in names if not n.startswith("."))
                  if k.startswith(prefix))
    if "--json" not in opts:
        for k in keys:
            print(k)
        return
    out = {}
    for k in keys:
        rec = read_record(store, k)
        if rec is not None:  # deleted since the listing
            out[k] = as_text(rec[1])
    print(json.dumps(out, sort_keys=True))


VERBS = {"get": cmd_get, "set": cmd_set, "del": cmd_del, "list": cmd_list}


def main(argv):
    if len(argv) < 3 or argv[2] not in VERBS:
        sys.stderr.write("lane-mail: usage: kv get|set|del|list ... (see lane-mail.sh --help)\n")
        return EXIT_USAGE
    try:
        VERBS[argv[2]](argv[1], argv[3:])
    except Fail as e:
        if e.msg:
            sys.stderr.write("lane-mail: kv: %s\n" % e.msg)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
