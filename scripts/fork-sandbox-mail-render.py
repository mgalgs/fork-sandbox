#!/usr/bin/env python3
"""fork-sandbox-mail-render.py -- render an agent-mail store as a
single-file HTML thread archive, or as plain text for agents.

Usage: fork-sandbox-mail-render.py <mail-root> -o threads.html
       fork-sandbox-mail-render.py <mail-root> --thread <id> -o t.html
       fork-sandbox-mail-render.py --text <mail-root> [--thread <id>] [--message <id>]
       fork-sandbox-mail-render.py <mail-root> -o threads.html --live [SECONDS]
       fork-sandbox-mail-render.py --json <mail-root> --thread <id>

Reads the store fork-sandbox-mail.sh writes under <mail-root>/threads/
(<thread-id>/NNN-<uuid>.msg -- an RFC 5322-shaped header block, a blank
line, then the body verbatim); this script never runs
fork-sandbox-mail.sh and never writes to the store. A malformed .msg
file (unreadable, or missing its Message-ID) renders as an error card
in place rather than aborting the whole run. Dot-directories (e.g.
.postmaster/, router state under the mail root, not mail) are ignored
entirely.

Threading is by In-Reply-To within a thread directory, falling back to
the last id in References when In-Reply-To is absent; a reply whose
parent cannot be found in the same thread attaches to the thread root
instead, marked as orphaned. A reference cycle among non-root messages
(In-Reply-To chains that loop without ever reaching the thread root) is
treated the same way -- attached to the root and marked orphaned --
rather than being silently dropped from the render. Ties (and top-level
orphans) sort by the NNN arrival sequence baked into each message's own
filename.

HTML output is a single self-contained file: inline CSS, both a light
and a dark theme via prefers-color-scheme, and no external asset beyond
the Google Fonts CDN. Every value pulled from the store -- subjects,
bodies, addresses, attachment names -- is agent-written and
hostile-until-proven, so it is html-escaped before it ever touches an
f-string. Attachments are listed by name only; their bytes are never
read.

--text is the agent view: oldest-first, a '---' separator line between
messages, reply nesting shown by indentation, headers abbreviated to
Message-ID/From/To/Cc/Subject/hops (deliberately no Date, to save prompt
tokens); From carries a bracketed [X-AI-* attribution] suffix when the
message has one (see attribution_str), byte-identical to before that
existed when it doesn't. The Message-ID is included even though nothing
else needs it, because it is the handle every id-taking verb (reply
--reply-to, show, seen) requires, and a view an agent cannot act on is
not a view. Body
lines are verbatim but each is prefixed with the thread indent plus a
literal '> ' (real-email quoting: a body line that already starts with
'> ' becomes '> > ', standard reply-nesting), so a body cannot forge the
separator or header lines of a message that never existed: the
renderer's own grammar never emits an unquoted line from a body, so
anything carrying a leading '> ' reads as quoted body text no matter
what it says.

--json is the raw export for dashboards: one JSON object on stdout for a
single thread (--thread is required; an unknown thread exits 1 with a
one-line error). It carries "thread", "messages" (NNN arrival order; each
with seq, id, every header line in file order as [name, value] pairs,
from, to and cc as lists, subject, date, in_reply_to or null, the body
verbatim, and attachments as {name, bytes}), "senders" (messages per From)
and "addressed" (the sorted union of every To and Cc). An attachment's
"bytes" is the size of <thread>/attachments/<name>, or null when that
file is missing or the name is not a plain basename; the bytes are never
read. A malformed .msg appears in place as {"seq", "error", "file"}. The
body is read without newline translation and decoded as UTF-8 with
errors="replace", so bytes that are not valid UTF-8 become U+FFFD. The
JSON is ASCII-only (non-ASCII text is \\u-escaped), so it survives any
stdout encoding.

--live [SECONDS] turns this into a standing process for watching an
in-progress thread in a browser: render, write the output file
atomically (temp file in the same directory, then os.replace -- the
browser's meta-refresh fetches on its own schedule and must never see
a half-written file), sleep SECONDS (default 15, minimum 2), and
repeat until SIGINT/SIGTERM. Each cycle re-scans the store, so new
messages and new threads appear as they land. Requires -o/--output (a
live loop needs a stable path to poll) and is refused with --text
(that path feeds postmaster wake prompts -- see the anti-forgery note
above -- and a looping text dump to stdout serves nobody). Under
--live only, the HTML gains a <meta http-equiv="refresh"> tag and a
banner reporting the render time, message count, and any currently
live postmaster wakes, read from <mail-root>/.postmaster/ (the same
state `postmaster status` reads). That state is read-only and
best-effort: a missing or unreadable .postmaster/ just omits the
live-wakes clause from the banner, never a crash. A bad render
mid-loop (e.g. a message file mid-write by a concurrent harvest) skips
that cycle rather than exiting; a bad mail-root at startup still fails
fast, as without --live. --live-cycles N and --live-render-delay
SECONDS are hidden, test-only hooks: the former stops the loop after N
cycles instead of running forever, the latter pads every render with a
sleep so a test can land a signal inside the render window on purpose.
"""
import argparse
import html
import json
import os
import signal
import stat
import sys
import tempfile
import time


def esc(s):
    return html.escape(s, quote=True)


def parse_msg(path, seq, fn, newline=None):
    """Parses one .msg file defensively. Returns a dict; entries that
    fail to parse carry ok=False and an "error" message instead of
    raising, so one bad file never aborts the whole render."""
    entry = {"seq": seq, "fn": fn, "ok": False, "error": None}
    try:
        with open(path, encoding="utf-8", errors="replace", newline=newline) as f:
            raw = f.read()
    except OSError as e:
        entry["error"] = f"could not read {fn}: {e}"
        return entry
    head, sep, body = raw.partition("\n\n")
    if not sep:
        # Retain a discoverable Message-ID for a malformed entry.  The
        # postmaster obtains the trigger id from this same header, and the
        # text renderer must be able to show its error card for that wake.
        for line in head.splitlines():
            name, part, value = line.partition(": ")
            if part and name == "Message-ID":
                entry["id"] = value.strip()
                break
        entry["error"] = f"{fn}: no blank line separating headers from body"
        return entry
    hdr = {}
    attachments = []
    header_lines = []
    for line in head.split("\n"):
        hname, hsep, hvalue = line.partition(":")
        if hsep:
            header_lines.append([hname, hvalue.strip()])
    for line in head.splitlines():
        name, part, value = line.partition(": ")
        if not part:
            continue
        if name == "X-Attachment":
            attachments.append(value.strip())
        elif name not in hdr:
            hdr[name] = value.strip()
    mid = hdr.get("Message-ID", "")
    if not mid:
        entry["error"] = f"{fn}: missing Message-ID header"
        return entry
    entry.update({
        "ok": True,
        "id": mid,
        "in_reply_to": hdr.get("In-Reply-To", ""),
        "references": hdr.get("References", "").split(),
        "date": hdr.get("Date", ""),
        "from": hdr.get("From", ""),
        "to": hdr.get("To", ""),
        "cc": hdr.get("Cc", ""),
        "subject": hdr.get("Subject", ""),
        "hops": hdr.get("X-Hops", ""),
        "attachments": attachments,
        "headers": header_lines,
        "body": body,
        "ai_harness": hdr.get("X-AI-Harness", ""),
        "ai_model": hdr.get("X-AI-Model", ""),
        "ai_network": hdr.get("X-AI-Network", ""),
    })
    return entry


def attribution_str(e):
    """A compact '<harness> · <model> · <network>' string from a message's
    X-AI-* headers, omitting empty parts, or "" when none are set -- a
    message from before this stamping existed (or a handler-seat reply,
    which carries X-AI-Persona but no harness/model/network) renders with
    no attribution at all, byte-identical to before this existed."""
    parts = [p for p in (e.get("ai_harness"), e.get("ai_model"), e.get("ai_network")) if p]
    return " · ".join(parts)


def load_thread(thread_dir, newline=None):
    """Every NNN-<uuid>.msg entry in a thread dir, in NNN order. Only
    files ending in .msg are considered, which naturally skips the
    NNN.seq reservation directories the store leaves behind."""
    entries = []
    try:
        names = os.listdir(thread_dir)
    except OSError:
        return entries
    for fn in sorted(n for n in names if n.endswith(".msg")):
        path = os.path.join(thread_dir, fn)
        if not os.path.isfile(path):
            continue
        try:
            seq = int(fn.split("-", 1)[0])
        except ValueError:
            seq = 0
        entries.append(parse_msg(path, seq, fn, newline))
    entries.sort(key=lambda e: e["seq"])
    return entries


def resolve_parent(e, by_id, root):
    """e's immediate parent, or (root, True) when e's In-Reply-To/
    References is missing, unknown, self-referential, or part of a
    reference cycle among non-root messages. Without the cycle check, two
    messages whose In-Reply-To headers name each other both resolve to a
    real parent and neither is ever reachable by walking from root -- the
    walk would simply never find them. Following the chain up to root (or
    until an id repeats) catches that before it happens."""
    parent_id = e["in_reply_to"] or (e["references"][-1] if e["references"] else "")
    parent = by_id.get(parent_id) if parent_id else None
    if parent is None or parent is e:
        return root, True
    seen = {id(e)}
    node = parent
    while node is not root:
        if id(node) in seen:
            return root, True
        seen.add(id(node))
        next_id = node["in_reply_to"] or (node["references"][-1] if node["references"] else "")
        node = by_id.get(next_id) if next_id else None
        if node is None:
            break
    return parent, False


def build_thread(thread_id, entries):
    """Threads the entries of one directory into (root, trace): root is
    the entry whose id equals the directory's own thread id (or the
    lowest-seq valid entry, when even the root failed to parse), and
    trace is a flat pre-order walk of (entry, depth, orphaned, is_error)
    tuples suitable for indented rendering. A malformed entry may retain
    its Message-ID so a single-message render can show its error card, but
    only valid entries are indexed for threading; malformed entries are
    listed at the top level, in NNN order alongside any true orphans."""
    valid = [e for e in entries if e["ok"]]
    invalid = [e for e in entries if not e["ok"]]
    by_id = {e["id"]: e for e in valid}
    root = by_id.get(thread_id)
    if root is None and valid:
        root = min(valid, key=lambda e: e["seq"])

    children = {}
    top = []  # (entry, orphaned, is_error)
    for e in valid:
        if e is root:
            continue
        parent, orphaned = resolve_parent(e, by_id, root)
        children.setdefault(id(parent), []).append((e, orphaned, False))
    for e in invalid:
        top.append((e, False, True))
    for lst in children.values():
        lst.sort(key=lambda t: t[0]["seq"])
    top.sort(key=lambda t: t[0]["seq"])

    trace = []

    def walk(e, depth, orphaned, is_error):
        trace.append((e, depth, orphaned, is_error))
        if is_error:
            return
        for child, child_orphaned, child_error in children.get(id(e), []):
            walk(child, depth + 1, child_orphaned, child_error)

    if root is not None:
        walk(root, 0, False, False)
    for e, orphaned, is_error in top:
        walk(e, 0, orphaned, is_error)
    return root, trace


def list_thread_ids(mail_root):
    threads_dir = os.path.join(mail_root, "threads")
    if not os.path.isdir(threads_dir):
        return []
    return sorted(
        n for n in os.listdir(threads_dir)
        if not n.startswith(".") and os.path.isdir(os.path.join(threads_dir, n))
    )


def render_thread_data(mail_root, thread_id, newline=None):
    thread_dir = os.path.join(mail_root, "threads", thread_id)
    entries = load_thread(thread_dir, newline)
    root, trace = build_thread(thread_id, entries)
    return {"thread_id": thread_id, "entries": entries, "root": root, "trace": trace}


def addr_list(s):
    return [a.strip() for a in s.split(",") if a.strip()]


def thread_summary(data):
    """Subject, participants, message count, last date and the newest
    message's remaining X-Hops, for one thread's index row."""
    entries = data["entries"]
    valid = [e for e in entries if e["ok"]]
    root = data["root"]
    if root is not None:
        subject = root["subject"]
    elif valid:
        subject = valid[0]["subject"]
    else:
        subject = "(no valid messages)"
    participants = []
    seen = set()
    for e in valid:
        for a in addr_list(e["from"]) + addr_list(e["to"]) + addr_list(e["cc"]):
            if a not in seen:
                seen.add(a)
                participants.append(a)
    newest = max(valid, key=lambda e: e["seq"]) if valid else None
    return {
        "thread_id": data["thread_id"],
        "subject": subject,
        "participants": participants,
        "count": len(entries),
        "last_date": newest["date"] if newest else "",
        "hops": newest["hops"] if newest else "",
    }


def render_message_card(e, depth, orphaned, is_error):
    style = f' style="margin-left:{depth * 1.5}em"' if depth else ""
    if is_error:
        return (
            f'<div class="msg error"{style}>\n'
            f'  <div class="msg-head"><span class="badge err">error</span> '
            f'<span class="fn">{esc(e["fn"])}</span></div>\n'
            f'  <div class="msg-body">{esc(e["error"])}</div>\n'
            f'</div>'
        )
    orphan_html = ' <span class="badge orphan">orphaned</span>' if orphaned else ""
    attrib = attribution_str(e)
    attrib_html = f' <span class="attribution">[{esc(attrib)}]</span>' if attrib else ""
    attach_html = ""
    if e["attachments"]:
        items = "".join(f"<li>{esc(a)}</li>" for a in e["attachments"])
        attach_html = (
            f'<div class="attachments"><span class="label">attachments</span>'
            f'<ul>{items}</ul></div>'
        )
    cc_html = f'    <span>Cc: {esc(e["cc"])}</span>\n' if e["cc"] else ""
    return (
        f'<div class="msg" id="m-{esc(e["id"])}"{style}>\n'
        f'  <div class="msg-head">\n'
        f'    <span class="from">{esc(e["from"])}</span>{attrib_html}{orphan_html}\n'
        f'    <span class="hops">hops {esc(e["hops"])}</span>\n'
        f'  </div>\n'
        f'  <div class="msg-meta">\n'
        f'    <span>To: {esc(e["to"])}</span>\n'
        f'{cc_html}'
        f'    <span>Date: {esc(e["date"])}</span>\n'
        f'  </div>\n'
        f'  <pre class="msg-body">{esc(e["body"])}</pre>\n'
        f'  {attach_html}\n'
        f'</div>'
    )


def render_thread_section(data, summ):
    msgs = "\n".join(
        render_message_card(e, depth, orphaned, is_error)
        for e, depth, orphaned, is_error in data["trace"]
    )
    return (
        f'<section class="thread" id="thread-{esc(data["thread_id"])}">\n'
        f'  <h2>{esc(summ["subject"])}</h2>\n'
        f'  <div class="thread-meta">{esc(", ".join(summ["participants"]))}'
        f' &middot; {summ["count"]} messages'
        f' &middot; {esc(summ["last_date"])}'
        f' &middot; hops {esc(summ["hops"])}</div>\n'
        f'  {msgs}\n'
        f'</section>'
    )


def render_index(summaries):
    rows = []
    for s in summaries:
        rows.append(
            f'<tr><td><a href="#thread-{esc(s["thread_id"])}">{esc(s["subject"])}</a></td>'
            f'<td>{esc(", ".join(s["participants"]))}</td>'
            f'<td>{s["count"]}</td>'
            f'<td>{esc(s["last_date"])}</td>'
            f'<td>{esc(s["hops"])}</td></tr>'
        )
    return (
        '<table class="index"><thead><tr>'
        '<th>Subject</th><th>Participants</th><th>Messages</th>'
        '<th>Last date</th><th>Hops</th></tr></thead><tbody>'
        + "".join(rows) + '</tbody></table>'
    )


CSS = """
:root {
  --ground:    #f6f8f9;
  --surface:   #ffffff;
  --surface-2: #eef1f3;
  --ink:       #0f1417;
  --ink-2:     #47555c;
  --ink-3:     #71828b;
  --rule:      #d9e0e4;
  --accent:    #2f6fec;
  --crit:      #b32218;
  --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
  --ui:   "Archivo", ui-sans-serif, system-ui, sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground:    #0b1013;
    --surface:   #121a1e;
    --surface-2: #182328;
    --ink:       #e7eef1;
    --ink-2:     #a2b2ba;
    --ink-3:     #778890;
    --rule:      #24333a;
    --accent:    #7ea8ff;
    --crit:      #f08b80;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--ground); color: var(--ink);
  font-family: var(--ui); font-size: 15px; line-height: 1.5;
}
a { color: var(--accent); }
.wrap { max-width: 980px; margin: 0 auto; padding: 24px; }
table.index { width: 100%; border-collapse: collapse; margin-bottom: 2rem; }
table.index th, table.index td {
  text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--rule);
  font-size: 13px;
}
.thread { border-top: 2px solid var(--rule); padding-top: 1rem; margin-top: 2rem; }
.thread h2 { margin: 0 0 .25rem; }
.thread-meta { color: var(--ink-3); font-size: 12.5px; margin-bottom: 1rem; }
.msg {
  background: var(--surface); border: 1px solid var(--rule);
  border-radius: 8px; padding: 10px 14px; margin: 10px 0;
}
.msg-head { display: flex; justify-content: space-between; align-items: center; font-weight: 600; }
.msg-meta {
  color: var(--ink-2); font-size: 12.5px; display: flex; gap: 14px;
  flex-wrap: wrap; margin: 4px 0;
}
.msg-body {
  white-space: pre-wrap; font-family: var(--mono); font-size: 13px;
  background: var(--surface-2); border-radius: 6px; padding: 10px; margin: 6px 0 0;
}
.badge {
  font-size: 11px; text-transform: uppercase; letter-spacing: .04em;
  border-radius: 999px; padding: 1px 8px; margin-left: 6px;
}
.attribution { font-weight: 400; color: var(--ink-3); font-size: 12.5px; }
.badge.orphan { background: var(--surface-2); color: var(--ink-2); border: 1px solid var(--rule); }
.badge.err { background: var(--crit); color: #fff; }
.msg.error { border-color: var(--crit); }
.attachments { margin-top: 6px; font-size: 12.5px; color: var(--ink-2); }
.attachments ul { margin: .25rem 0 0; padding-left: 1.2rem; }
.live-banner {
  background: var(--surface-2); border: 1px solid var(--rule); border-radius: 6px;
  padding: 6px 12px; margin-bottom: 1rem; font-size: 12.5px; color: var(--ink-2);
  font-family: var(--mono);
}
"""


def render_live_banner(rendered_at, count, live_wakes):
    """live_wakes is None when postmaster state could not be read at all
    (the clause is omitted), an empty list when it was read and nothing
    is live, or a list of 'agent@thread-short-id' strings."""
    text = f"LIVE · rendered {rendered_at} · {count} messages"
    if live_wakes is not None:
        if live_wakes:
            text += " · live wakes: " + ", ".join(live_wakes)
        else:
            text += " · no live wakes"
    return f'<div class="live-banner">{esc(text)}</div>'


def get_live_wakes(mail_root):
    """Currently-live postmaster wakes, read from the same
    <mail-root>/.postmaster/{runs,harvested}/ state `postmaster status`
    reads. Returns None if that state cannot be read at all (missing
    dir, permission error); an unreadable or unparseable individual run
    record is skipped rather than aborting the whole read. Read-only:
    never writes, creates, or locks anything under .postmaster/."""
    runs_dir = os.path.join(mail_root, ".postmaster", "runs")
    harvested_dir = os.path.join(mail_root, ".postmaster", "harvested")
    try:
        names = os.listdir(runs_dir)
    except OSError:
        return None
    wakes = []
    for fn in sorted(names):
        if not fn.endswith(".env"):
            continue
        rid = fn[:-len(".env")]
        if os.path.exists(os.path.join(harvested_dir, rid)):
            continue
        agent = tid = None
        try:
            with open(os.path.join(runs_dir, fn), encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("AGENT="):
                        agent = line[len("AGENT="):].rstrip("\n")
                    elif line.startswith("THREAD="):
                        tid = line[len("THREAD="):].rstrip("\n")
        except OSError:
            continue
        if agent and tid:
            wakes.append(f"{agent}@{tid[:8]}")
    return wakes


def build_html(mail_root, thread_ids, title, live=None):
    """live, when given, is a dict with 'interval', 'rendered_at' and
    'live_wakes' (see get_live_wakes) and adds a meta-refresh tag plus a
    status banner. live=None (the default) renders byte-identical output
    to a plain, non-live run."""
    datas = [render_thread_data(mail_root, tid) for tid in thread_ids]
    summaries = [thread_summary(d) for d in datas]
    index_html = render_index(summaries)
    threads_html = "\n".join(
        render_thread_section(d, s) for d, s in zip(datas, summaries)
    )
    meta_refresh = ""
    banner_html = ""
    if live is not None:
        meta_refresh = f'<meta http-equiv="refresh" content="{live["interval"]}">\n'
        count = sum(len(d["entries"]) for d in datas)
        banner_html = render_live_banner(live["rendered_at"], count, live["live_wakes"]) + "\n"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{meta_refresh}<title>{esc(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap">
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
{banner_html}<h1>{esc(title)}</h1>
{index_html}
{threads_html}
</div>
</body>
</html>
"""


def render_text_message(e, depth, orphaned, is_error, out):
    # This quoting grammar is a wake trust boundary, not cosmetic: changing
    # body prefixes or emitting an unquoted body-derived line breaks the
    # anti-forgery property fork-sandbox-postmaster.sh depends on.
    indent = "  " * depth
    if out:
        out.append("---")
    if is_error:
        out.append(f"{indent}[error: {e['error']}]")
        return
    orphan_suffix = " [orphaned]" if orphaned else ""
    attrib = attribution_str(e)
    attrib_suffix = f" [{attrib}]" if attrib else ""
    out.append(f"{indent}Message-ID: {e['id']}")
    out.append(f"{indent}From: {e['from']}{attrib_suffix}{orphan_suffix}")
    out.append(f"{indent}To: {e['to']}")
    if e["cc"]:
        out.append(f"{indent}Cc: {e['cc']}")
    out.append(f"{indent}Subject: {e['subject']}")
    out.append(f"{indent}Hops: {e['hops']}")
    if e["attachments"]:
        out.append(f"{indent}Attachments: " + ", ".join(e["attachments"]))
    out.append("")
    for ln in e["body"].split("\n"):
        out.append(f"{indent}> {ln}" if ln else f"{indent}>")


def render_text(mail_root, thread_ids):
    out = []
    for tid in thread_ids:
        data = render_thread_data(mail_root, tid)
        for e, depth, orphaned, is_error in data["trace"]:
            render_text_message(e, depth, orphaned, is_error, out)
    return "\n".join(out) + ("\n" if out else "")


def attachment_size(thread_dir, ref):
    """Size in bytes of <thread>/attachments/<name> for an X-Attachment
    value, or None when the file is missing or the name is not a plain
    basename (the value is agent-written, so it is never used to walk out
    of attachments/). Never reads the file."""
    name = ref[len("attachments/"):] if ref.startswith("attachments/") else ref
    if not name or "/" in name or "\0" in name or name in (".", ".."):
        return None
    try:
        return os.stat(os.path.join(thread_dir, "attachments", name)).st_size
    except OSError:
        return None


def export_json(mail_root, thread_id):
    """The raw JSON export of one thread; see the --json note above."""
    thread_dir = os.path.join(mail_root, "threads", thread_id)
    data = render_thread_data(mail_root, thread_id, newline="")
    messages = []
    senders = {}
    addressed = set()
    for e in data["entries"]:
        if not e["ok"]:
            messages.append({"seq": e["seq"], "error": e["error"], "file": e["fn"]})
            continue
        attachments = []
        for ref in e["attachments"]:
            name = ref[len("attachments/"):] if ref.startswith("attachments/") else ref
            attachments.append({"name": name, "bytes": attachment_size(thread_dir, ref)})
        to = addr_list(e["to"])
        cc = addr_list(e["cc"])
        senders[e["from"]] = senders.get(e["from"], 0) + 1
        addressed.update(to)
        addressed.update(cc)
        messages.append({
            "seq": e["seq"],
            "id": e["id"],
            "headers": e["headers"],
            "from": e["from"],
            "to": to,
            "cc": cc,
            "subject": e["subject"],
            "date": e["date"],
            "in_reply_to": e["in_reply_to"] or None,
            "body": e["body"],
            "attachments": attachments,
        })
    return {
        "thread": thread_id,
        "messages": messages,
        "senders": senders,
        "addressed": sorted(addressed),
    }


def write_atomic(path, content):
    """Writes content to path via a temp file in the same directory plus
    os.replace, so a concurrent reader (the browser, on its meta-refresh
    timer) never observes a partially-written file."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".mail-render-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except OSError:
            umask = os.umask(0)
            os.umask(umask)
            mode = 0o666 & ~umask
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


class _StopLive(BaseException):
    """Raised from the SIGINT/SIGTERM handler to unwind run_live cleanly.

    Derives from BaseException, not Exception: the per-cycle `except
    Exception` guard in run_live's loop must never swallow this, or a
    signal landing mid-render gets reported as a render failure and the
    loop keeps going instead of stopping."""


def run_live(mail_root, output, title, thread_filter, interval, cycles, render_delay=0):
    """Renders in a loop: render, write atomically, sleep, repeat, until
    SIGINT/SIGTERM (cycles=None) or `cycles` renders have happened
    (cycles is the test-only escape hatch, see --live-cycles). The first
    cycle's write failure is fatal (a bad output path fails fast, same
    as a one-shot run); every cycle after that is caught and skipped so
    one bad render never kills the loop. render_delay is a second
    test-only hook (see --live-render-delay) that pads every render with
    a sleep, so a test can land a signal inside the render window on
    purpose instead of racing real render latency."""

    def raise_stop(signum, frame):
        raise _StopLive()

    signal.signal(signal.SIGINT, raise_stop)
    signal.signal(signal.SIGTERM, raise_stop)

    def render_once():
        if render_delay:
            time.sleep(render_delay)
        all_ids = list_thread_ids(mail_root)
        if thread_filter:
            thread_ids = [thread_filter] if thread_filter in all_ids else []
        else:
            thread_ids = all_ids
        live = {
            "interval": interval,
            "rendered_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "live_wakes": get_live_wakes(mail_root),
        }
        write_atomic(output, build_html(mail_root, thread_ids, title, live=live))

    try:
        render_once()
    except OSError as e:
        print(f"Error: could not write {output}: {e}", file=sys.stderr)
        return 1
    except _StopLive:
        return 0

    n = 1
    try:
        while cycles is None or n < cycles:
            time.sleep(interval)
            try:
                render_once()
            except Exception as e:
                print(f"Error: live render cycle failed, skipping: {e}", file=sys.stderr)
            n += 1
    except _StopLive:
        pass
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mail_root", help="fork-sandbox-mail.sh store root")
    parser.add_argument("--thread", metavar="ID", help="render only this thread id")
    parser.add_argument("--message", metavar="ID", help="render only this message (requires --text and --thread)")
    parser.add_argument("-o", "--output", metavar="FILE", help="write HTML to FILE instead of stdout")
    parser.add_argument("--text", action="store_true", help="render as plain text to stdout instead of HTML")
    parser.add_argument("--json", action="store_true", help="print one thread (--thread required) as a JSON object to stdout")
    parser.add_argument("--title", default="Mail threads", help="HTML page title (default: %(default)s)")
    parser.add_argument(
        "--live", metavar="SECONDS", nargs="?", type=int, const=15, default=None,
        help="re-render to -o/--output on an interval (default 15s, minimum 2s) until interrupted",
    )
    parser.add_argument("--live-cycles", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--live-render-delay", type=float, default=0, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.json:
        if not args.thread:
            print("Error: --json requires --thread", file=sys.stderr)
            return 1
        if args.text or args.output or args.message or args.live is not None:
            print("Error: --json cannot be combined with --text, --message, -o or --live", file=sys.stderr)
            return 1
    if args.message and not args.text:
        print("Error: --message requires --text", file=sys.stderr)
        return 1
    if args.message and not args.thread:
        print("Error: --message requires --thread", file=sys.stderr)
        return 1

    if args.live is not None:
        if args.live < 2:
            print("Error: --live SECONDS must be at least 2", file=sys.stderr)
            return 1
        if args.text:
            print("Error: --live cannot be combined with --text", file=sys.stderr)
            return 1
        if not args.output:
            print("Error: --live requires -o/--output", file=sys.stderr)
            return 1

    threads_dir = os.path.join(args.mail_root, "threads")
    if not os.path.isdir(threads_dir):
        print(f"Error: no such mail root (or no threads/ under it): {args.mail_root}", file=sys.stderr)
        return 1

    all_ids = list_thread_ids(args.mail_root)
    if args.thread:
        if args.thread not in all_ids:
            print(f"Error: no thread '{args.thread}' under {args.mail_root}", file=sys.stderr)
            return 1
        thread_ids = [args.thread]
    else:
        thread_ids = all_ids

    if args.json:
        json.dump(export_json(args.mail_root, args.thread), sys.stdout)
        sys.stdout.write("\n")
        return 0

    if args.text:
        if args.output:
            print("Error: --text renders to stdout and cannot be combined with -o/--output", file=sys.stderr)
            return 1
        if args.message:
            data = render_thread_data(args.mail_root, args.thread)
            match = next((item for item in data["trace"] if item[0].get("id") == args.message), None)
            if match is None:
                print(f"Error: no message '{args.message}' in thread '{args.thread}'", file=sys.stderr)
                return 1
            out = []
            e, _depth, orphaned, is_error = match
            render_text_message(e, 0, orphaned, is_error, out)
            sys.stdout.write("\n".join(out) + "\n")
        else:
            sys.stdout.write(render_text(args.mail_root, thread_ids))
        return 0

    if args.live is not None:
        return run_live(
            args.mail_root, args.output, args.title, args.thread, args.live,
            args.live_cycles, args.live_render_delay,
        )

    document = build_html(args.mail_root, thread_ids, args.title)
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(document)
        except OSError as e:
            print(f"Error: could not write {args.output}: {e}", file=sys.stderr)
            return 1
    else:
        sys.stdout.write(document)
    return 0


if __name__ == "__main__":
    sys.exit(main())
