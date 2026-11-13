#!/usr/bin/env python3
"""Scan inbox messages in Bash glob order, preserving mail_header semantics."""

import os
import sys


HEADERS = (b"To", b"Cc", b"Message-ID", b"Thread-ID", b"From", b"Subject", b"X-Lane-Broadcast")


def headers(path):
    found = {}
    with open(path, "rb") as message:
        for line in message:
            # Bash's read loop does not process a final unterminated line.
            if not line.endswith(b"\n"):
                break
            line = line[:-1].replace(b"\0", b"")
            if not line:
                break
            for name in HEADERS:
                prefix = name + b":"
                if name not in found and line.startswith(prefix):
                    spaced = prefix + b" "
                    found[name] = line[len(spaced):] if line.startswith(spaced) else line
    return found


def listed(value, address):
    wrapped = b"," + value + b","
    return b", " + address + b"," in wrapped or wrapped.startswith(b"," + address + b",")


def main():
    address = os.fsencode(sys.argv[1])
    seen_file = os.fsencode(sys.argv[2])
    show_all = sys.argv[3] == "1"
    lane_root = sys.argv[4] == "1"
    everyone = os.fsencode(sys.argv[5])
    seen = set()
    if os.path.isfile(seen_file):
        with open(seen_file, "rb") as file:
            for line in file:
                if line.endswith(b"\n") and line[:-1]:
                    seen.add(line[:-1].replace(b"\0", b""))

    output = sys.stdout.buffer
    for path in sys.stdin.buffer.read().split(b"\0"):
        if not path:
            continue
        fields = headers(path)
        to = fields.get(b"To", b"")
        cc = fields.get(b"Cc", b"")
        position = b"To" if listed(to, address) else b"Cc" if listed(cc, address) else b""
        if not position and lane_root and everyone in to + b"," + cc:
            sender = fields.get(b"From", b"")
            broadcast = fields.get(b"X-Lane-Broadcast", b"")
            if sender and b":" not in sender and listed(broadcast, address):
                position = b"To" if listed(to, everyone) else b"Cc" if listed(cc, everyone) else b""
        if not position:
            continue
        mid = fields.get(b"Message-ID", b"")
        if not show_all and (mid in seen or (not seen and not mid)):
            continue
        output.write(b"\t".join((mid, fields.get(b"Thread-ID", b""), position,
                                 fields.get(b"From", b""), fields.get(b"Subject", b""))) + b"\n")


if __name__ == "__main__":
    main()
