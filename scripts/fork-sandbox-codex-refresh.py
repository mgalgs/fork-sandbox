#!/usr/bin/env python3
"""Refresh host Codex auth through Codex itself; never copy auth.json to a pod.

Usage: fork-sandbox-codex-refresh.py AUTH_JSON

The app-server account/read RPC with refreshToken=true uses the CLI's own
OAuth refresh handling. We inspect only the resulting access token lifetime;
no credential is passed on argv or printed. This process runs on the host.
"""

import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def token_exp(path: Path) -> int:
    try:
        token = json.loads(path.read_text())["tokens"]["access_token"]
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return int(json.loads(base64.urlsafe_b64decode(payload))["exp"])
    except (OSError, KeyError, ValueError, IndexError, TypeError):
        return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: fork-sandbox-codex-refresh.py AUTH_JSON", file=sys.stderr)
        return 2
    auth_path = Path(sys.argv[1]).resolve()
    if token_exp(auth_path) > time.time() + 900:
        return 0
    env = dict(os.environ)
    env["CODEX_HOME"] = str(auth_path.parent)
    try:
        process = subprocess.Popen(
            ["codex", "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        assert process.stdin is not None
        for message in (
            {"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "fork_sandbox", "title": "fork-sandbox", "version": "1"}}},
            {"method": "initialized", "params": {}},
            {"id": 2, "method": "account/read", "params": {"refreshToken": True}},
        ):
            process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and process.poll() is None:
            if token_exp(auth_path) > time.time() + 900:
                return 0
            time.sleep(0.5)
        return 0 if token_exp(auth_path) > time.time() + 900 else 1
    except (OSError, BrokenPipeError):
        return 1
    finally:
        if "process" in locals():
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    sys.exit(main())
