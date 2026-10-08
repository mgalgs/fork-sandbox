#!/usr/bin/env python3
"""Offline host-side refresh checks; no real Codex credential or network."""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/fork-sandbox-codex-refresh.py"


def auth(exp: int) -> str:
    payload = base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode()
    token = "stub." + payload.rstrip("=") + ".stub"
    return json.dumps({"auth_mode": "chatgpt", "tokens": {
        "access_token": token, "refresh_token": "fixture-only"}})


def run_case(exp: int, replacement: bool) -> tuple[int, str, bool]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        home = root / "codex-home"
        bin_dir = root / "bin"
        home.mkdir()
        bin_dir.mkdir()
        (home / "auth.json").write_text(auth(exp))
        new_auth = root / "replacement.json"
        new_auth.write_text(auth(int(time.time()) + 3600))
        marker = root / "called"
        stub = bin_dir / "codex"
        stub.write_text(
            "#!/bin/sh\n"
            'touch "$FAKE_CODEX_CALLED"\n'
            + ('cp "$FAKE_CODEX_REPLACEMENT" "$CODEX_HOME/auth.json"\n' if replacement else "")
        )
        stub.chmod(0o755)
        env = dict(os.environ)
        env.update({
            "PATH": str(bin_dir) + os.pathsep + env["PATH"],
            "FAKE_CODEX_CALLED": str(marker),
            "FAKE_CODEX_REPLACEMENT": str(new_auth),
        })
        result = subprocess.run(
            ["python3", str(HELPER), str(home / "auth.json")],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        return result.returncode, result.stdout + result.stderr, marker.exists()


def main() -> None:
    fresh = run_case(int(time.time()) + 3600, False)
    assert fresh == (0, "", False), fresh
    refreshed = run_case(int(time.time()) + 60, True)
    assert refreshed == (0, "", True), refreshed
    failed = run_case(int(time.time()) + 60, False)
    assert failed == (1, "", True), failed
    print("3 passed, 0 failed")


if __name__ == "__main__":
    main()
