#!/usr/bin/env python3
"""UserPromptSubmit hook: nudge to /freshly-forked when the context window fills.

When a session's context window crosses 35% (then 80%, 90%) usage, this injects a
short system nudge telling the model to run /freshly-forked at the next natural
break — handing off to a clean session before quality degrades (or before
auto-compaction mangles the transcript, where that is enabled).

It runs as a UserPromptSubmit hook, which is the *only* hook that can add text
to the model's context: PostToolUse and friends cannot inject, so the nudge
lands at turn boundaries (when the user submits a prompt), which is exactly the
"next natural break" we want it acted on anyway.

The hook input carries neither the context-window size nor the model id (the
transcript even strips the [1m] window marker), so the true window cannot be
computed from the hook payload alone. statusline-stash.sh — which Claude Code
hands the authoritative window size and percentage — stashes those numbers per
session under /tmp/claude-<uid>/context-nudge/ (CONTEXT_NUDGE_DIR overrides
this directory; test-only), and this reads them, so the nudge and the status
line never disagree. If that state file is absent (a brand new session, or a
customized statusLine command that does not wrap statusline-stash.sh), it
falls back to reading the tail of the transcript for the last assistant
message's token usage and estimating the window from the model id.

The nudge is rate-limited: at most once per session per severity step (80%,
90%), tracked in a per-session file. A large drop in usage (a /clear or
/compact) re-arms it.

Usage:
  context-nudge.py   # invoked automatically as a UserPromptSubmit hook;
                     # reads the hook JSON on stdin, prints a nudge on stdout
"""

import json
import os
import sys

# Severity steps (percent of the context window). The nudge fires once as each
# step is first crossed, most-severe-applicable only.
STEPS = [35, 80, 90]

# Below this, treat the context as freshly reset (/clear, /compact) and re-arm
# every step so a later climb nudges again.
REARM_BELOW = 30

# Model-id -> context window, used only in the transcript fallback path (the
# statusline-stash.sh state file carries the authoritative size otherwise).
# The transcript strips the [1m] marker, so 1M sessions fall through to the default
# here; that only matters when the status line never ran, which is rare.
DEFAULT_WINDOW = 200_000


def state_dir():
    # CONTEXT_NUDGE_DIR overrides this directory. Test-only -- leave it unset
    # in real use so this, statusline-stash.sh and context-usage.sh agree on
    # where to look.
    d = os.environ.get("CONTEXT_NUDGE_DIR") or f"/tmp/claude-{os.getuid()}/context-nudge"
    os.makedirs(d, exist_ok=True)
    return d


def window_for_model(model_id):
    if model_id:
        m = model_id.lower()
        if "[1m]" in m or "-1m" in m or ":1m" in m:
            return 1_000_000
    return DEFAULT_WINDOW


def read_state_file(session_id):
    """Authoritative window + percentage persisted by statusline-stash.sh, or None."""
    path = os.path.join(state_dir(), f"ctx-{session_id}.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    size = d.get("context_window_size")
    pct = d.get("used_percentage")
    if not isinstance(size, (int, float)) or size <= 0:
        return None
    if not isinstance(pct, (int, float)):
        return None
    return {"window": int(size), "pct": float(pct), "model": d.get("model")}


def last_assistant_usage(transcript_path):
    """Tail the transcript for the last assistant message's usage. Never loads
    the whole file — transcripts run to hundreds of MB."""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 500_000))
            chunk = f.read()
    except OSError:
        return None
    # A tail read may cut the first line mid-way; json.loads skips it.
    result = None
    for raw in chunk.decode("utf-8", "replace").splitlines():
        if '"assistant"' not in raw:
            continue
        line = raw.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") != "assistant":
            continue
        msg = d.get("message") or {}
        usage = msg.get("usage")
        if isinstance(usage, dict):
            result = (usage, msg.get("model"))
    return result


def occupancy_from_usage(usage):
    total = 0
    for key in ("input_tokens", "cache_read_input_tokens",
                "cache_creation_input_tokens"):
        v = usage.get(key)
        if isinstance(v, (int, float)):
            total += v
    return total


def assess(session_id, transcript_path):
    """Return (pct, used_tokens, window_tokens, model) or None if unknown."""
    state = read_state_file(session_id)
    if state:
        window = state["window"]
        pct = state["pct"]
        used = round(window * pct / 100)
        return pct, used, window, state["model"]

    if not transcript_path:
        return None
    found = last_assistant_usage(transcript_path)
    if not found:
        return None
    usage, model = found
    used = occupancy_from_usage(usage)
    window = window_for_model(model)
    if window <= 0:
        return None
    pct = used / window * 100
    return pct, used, window, model


def read_last_fired(session_id):
    path = os.path.join(state_dir(), f"fired-{session_id}")
    try:
        with open(path) as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def write_last_fired(session_id, step):
    path = os.path.join(state_dir(), f"fired-{session_id}")
    try:
        with open(path, "w") as f:
            f.write(str(step))
    except OSError:
        pass


def build_nudge(pct, used, window, step):
    pct_disp = round(pct)
    used_k = round(used / 1000)
    window_k = round(window / 1000)
    lead = "🚨 URGENT — " if step >= 90 else "⚠️ "
    return (
        f"{lead}Automated context-usage nudge (this is a system notice, not a "
        f"message from the user): this session's context window is {pct_disp}% "
        f"full ({used_k}k of {window_k}k tokens). Run /freshly-forked at the "
        f"next natural break — it writes a thorough handoff doc and relaunches "
        f"a clean session in a split pane, so the work continues at full "
        f"context quality instead of degrading as the window fills (or being "
        f"mangled by auto-compaction, where that is enabled). Finish or "
        f"checkpoint the current step first, then hand off."
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return
    if not isinstance(payload, dict):
        return

    session_id = payload.get("session_id")
    if not session_id:
        # Without a session id we can't rate-limit, so stay silent rather than
        # risk nudging on every prompt.
        return
    transcript_path = payload.get("transcript_path")

    assessed = assess(session_id, transcript_path)
    if not assessed:
        return
    pct, used, window, _model = assessed

    last_fired = read_last_fired(session_id)

    # Context was reset (/clear, /compact): re-arm every step.
    if pct < REARM_BELOW and last_fired > 0:
        write_last_fired(session_id, 0)
        last_fired = 0

    if pct < STEPS[0]:
        return
    step = max(s for s in STEPS if pct >= s)
    if step <= last_fired:
        return

    write_last_fired(session_id, step)

    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": build_nudge(pct, used, window, step),
        }
    }
    print(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A hook must never break prompt submission. Any failure -> silent
        # exit 0 with no stdout (stray stdout would be injected as context).
        pass
