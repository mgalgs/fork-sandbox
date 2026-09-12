#!/usr/bin/env python3
"""fork-sandbox-mail-render.py -- render an agent-mail store as a
single-file HTML thread archive, or as plain text for agents.

Usage: fork-sandbox-mail-render.py <mail-root> -o threads.html
       fork-sandbox-mail-render.py <mail-root> --thread <id> -o t.html
       fork-sandbox-mail-render.py --text <mail-root> [--thread <id>]

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
tokens). The Message-ID is included even though nothing else needs it,
because it is the handle every id-taking verb (reply --reply-to, show,
seen) requires, and a view an agent cannot act on is not a view. Body
lines are verbatim but each is prefixed with the thread indent plus a
literal '| ', so a body cannot forge the separator or header lines of a
message that never existed: the renderer's own grammar never emits a
'| '-prefixed line, so anything carrying that prefix reads as quoted
body text no matter what it says.
"""
import argparse
import html
import os
import sys


def esc(s):
    return html.escape(s, quote=True)


def parse_msg(path, seq, fn):
    """Parses one .msg file defensively. Returns a dict; entries that
    fail to parse carry ok=False and an "error" message instead of
    raising, so one bad file never aborts the whole render."""
    entry = {"seq": seq, "fn": fn, "ok": False, "error": None}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            raw = f.read()
    except OSError as e:
        entry["error"] = f"could not read {fn}: {e}"
        return entry
    head, sep, body = raw.partition("\n\n")
    if not sep:
        entry["error"] = f"{fn}: no blank line separating headers from body"
        return entry
    hdr = {}
    attachments = []
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
        "body": body,
    })
    return entry


def load_thread(thread_dir):
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
        entries.append(parse_msg(path, seq, fn))
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
    tuples suitable for indented rendering. A malformed entry carries no
    id to thread by, so it is listed at the top level, in NNN order
    alongside any true orphans, rather than nested anywhere."""
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


def render_thread_data(mail_root, thread_id):
    thread_dir = os.path.join(mail_root, "threads", thread_id)
    entries = load_thread(thread_dir)
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
        f'    <span class="from">{esc(e["from"])}</span>{orphan_html}\n'
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
.badge.orphan { background: var(--surface-2); color: var(--ink-2); border: 1px solid var(--rule); }
.badge.err { background: var(--crit); color: #fff; }
.msg.error { border-color: var(--crit); }
.attachments { margin-top: 6px; font-size: 12.5px; color: var(--ink-2); }
.attachments ul { margin: .25rem 0 0; padding-left: 1.2rem; }
"""


def build_html(mail_root, thread_ids, title):
    datas = [render_thread_data(mail_root, tid) for tid in thread_ids]
    summaries = [thread_summary(d) for d in datas]
    index_html = render_index(summaries)
    threads_html = "\n".join(
        render_thread_section(d, s) for d, s in zip(datas, summaries)
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap">
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<h1>{esc(title)}</h1>
{index_html}
{threads_html}
</div>
</body>
</html>
"""


def render_text_message(e, depth, orphaned, is_error, out):
    indent = "  " * depth
    if out:
        out.append("---")
    if is_error:
        out.append(f"{indent}[error: {e['error']}]")
        return
    orphan_suffix = " [orphaned]" if orphaned else ""
    out.append(f"{indent}Message-ID: {e['id']}")
    out.append(f"{indent}From: {e['from']}{orphan_suffix}")
    out.append(f"{indent}To: {e['to']}")
    if e["cc"]:
        out.append(f"{indent}Cc: {e['cc']}")
    out.append(f"{indent}Subject: {e['subject']}")
    out.append(f"{indent}Hops: {e['hops']}")
    if e["attachments"]:
        out.append(f"{indent}Attachments: " + ", ".join(e["attachments"]))
    out.append("")
    for ln in e["body"].split("\n"):
        out.append(f"{indent}| {ln}" if ln else f"{indent}|")


def render_text(mail_root, thread_ids):
    out = []
    for tid in thread_ids:
        data = render_thread_data(mail_root, tid)
        for e, depth, orphaned, is_error in data["trace"]:
            render_text_message(e, depth, orphaned, is_error, out)
    return "\n".join(out) + ("\n" if out else "")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mail_root", help="fork-sandbox-mail.sh store root")
    parser.add_argument("--thread", metavar="ID", help="render only this thread id")
    parser.add_argument("-o", "--output", metavar="FILE", help="write HTML to FILE instead of stdout")
    parser.add_argument("--text", action="store_true", help="render as plain text to stdout instead of HTML")
    parser.add_argument("--title", default="Mail threads", help="HTML page title (default: %(default)s)")
    args = parser.parse_args(argv)

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

    if args.text:
        if args.output:
            print("Error: --text renders to stdout and cannot be combined with -o/--output", file=sys.stderr)
            return 1
        sys.stdout.write(render_text(args.mail_root, thread_ids))
        return 0

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
