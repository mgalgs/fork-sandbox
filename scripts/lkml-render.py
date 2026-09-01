#!/usr/bin/env python3
"""lkml-render.py — render one or more lkml-mode series mailboxes as a
single self-contained HTML page: a threaded archive with a per-version
tally, patch bodies folded, quotes and trailers styled.

Usage: lkml-render.py <series-dir> [<series-dir> ...] > out.html

A series dir is $LKML_MAILBOX_ROOT/<series> (it holds cur/*.msg). Reads
only; never runs git.
"""
import html
import base64
import mimetypes
import os
import re
import sys
import argparse
from datetime import datetime
from email.utils import parsedate_to_datetime

TAG_ORDER = ["Reviewed-by", "Acked-by", "Tested-by", "Changes-requested", "Question", "NAK"]
TAG_CLASS = {
    "Reviewed-by": "t-rev", "Acked-by": "t-ack", "Tested-by": "t-test", "Changes-requested": "t-chg",
    "Question": "t-q", "NAK": "t-nak",
}
TAG_GLYPH = {"Reviewed-by": "R", "Acked-by": "A", "Tested-by": "T", "Changes-requested": "C",
             "Question": "?", "NAK": "N"}


def read_msg(path, attachment_root):
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    head, _, body = raw.partition("\n\n")
    hdr = {}
    attachments = []
    for line in head.splitlines():
        k, _, v = line.partition(": ")
        if k == "X-Attachment":
            attachments.append(v.strip())
        else:
            hdr[k] = v
    mid = strip_id(hdr.get("Message-ID", ""))
    parent = strip_id(hdr.get("In-Reply-To", ""))
    try:
        seq = int(hdr.get("X-Seq", "0"))
    except ValueError:
        seq = 0
    try:
        date = parsedate_to_datetime(hdr.get("Date", ""))
    except Exception:
        date = None
    tags = [t.strip() for t in hdr.get("X-Tags", "").split(",") if t.strip()]
    rendered_attachments = []
    for ref in attachments:
        # The mailbox writes attachments/<basename>. Keep this defensive in
        # case a hand-written message contains an unsafe or stale reference.
        rel = ref.removeprefix("attachments/") if ref.startswith("attachments/") else ""
        candidate = os.path.normpath(os.path.join(attachment_root, rel)) if rel else ""
        root_real = os.path.realpath(attachment_root)
        candidate_real = os.path.realpath(candidate) if candidate else ""
        inside = candidate and os.path.commonpath((candidate_real, root_real)) == root_real
        href = None
        mime = "application/octet-stream"
        if inside and os.path.isfile(candidate_real):
            with open(candidate_real, "rb") as f:
                data = f.read()
            mime = mimetypes.guess_type(candidate_real)[0] or mime
            href = f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"
        rendered_attachments.append({"ref": ref, "href": href, "mime": mime})
    return {
        "id": mid, "parent": parent, "seq": seq, "date": date,
        "from": hdr.get("From", ""), "subject": hdr.get("Subject", ""),
        "persona": hdr.get("X-AI-Persona", ""), "harness": hdr.get("X-AI-Harness", ""),
        "model": hdr.get("X-AI-Model", ""), "version": int(hdr.get("X-Version", "1") or 1),
        "depth": int(hdr.get("X-Depth", "0") or 0), "tags": tags, "body": body,
        "attachments": rendered_attachments,
        "children": [],
    }


def strip_id(v):
    v = v.strip()
    if v.startswith("<"):
        v = v[1:]
    if v.endswith(">"):
        v = v[:-1]
    return v.split("@", 1)[0]


def esc(s):
    return html.escape(s, quote=True)


def inline(s):
    s = esc(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


TRAILER_RE = re.compile(r"^(Reviewed-by|Acked-by|Tested-by|Reported-by|Changes-requested|Question)(:.*)?$")
NAK_RE = re.compile(r"^NAK([\s:.!,].*)?$")


def render_prose(text):
    """Small markdown: headings, fences, quotes, lists, paragraphs, trailers."""
    out = []
    lines = text.splitlines()
    i = 0
    para = []

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + " ".join(inline(x) for x in para) + "</p>")
            para = []

    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            flush_para()
            j = i + 1
            block = []
            while j < len(lines) and not lines[j].startswith("```"):
                block.append(lines[j])
                j += 1
            out.append("<pre class=\"code\">" + esc("\n".join(block)) + "</pre>")
            i = j + 1
            continue
        if ln.startswith(">"):
            flush_para()
            block = []
            while i < len(lines) and lines[i].startswith(">"):
                block.append(re.sub(r"^>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>" + render_prose("\n".join(block)) + "</blockquote>")
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", ln)
        if m:
            flush_para()
            lvl = min(len(m.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            i += 1
            continue
        if re.match(r"^\s*([-*]|\d+\.)\s+", ln):
            flush_para()
            items = []
            ordered = bool(re.match(r"^\s*\d+\.", ln))
            while i < len(lines) and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i]):
                item = re.sub(r"^\s*([-*]|\d+\.)\s+", "", lines[i])
                i += 1
                while i < len(lines) and lines[i].startswith(("  ", "\t")) and lines[i].strip():
                    item += " " + lines[i].strip()
                    i += 1
                items.append("<li>" + inline(item) + "</li>")
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(items) + f"</{tag}>")
            continue
        if TRAILER_RE.match(ln) or NAK_RE.match(ln):
            flush_para()
            name = ln.split(":", 1)[0].split(" ", 1)[0]
            cls = TAG_CLASS.get(name, "t-q")
            out.append(f"<p class=\"trailer {cls}\">{esc(ln)}</p>")
            i += 1
            continue
        if not ln.strip():
            flush_para()
            i += 1
            continue
        para.append(ln)
        i += 1
    flush_para()
    return "\n".join(out)


def render_diff(text):
    out = []
    for ln in text.splitlines():
        cls = ""
        if ln.startswith("diff --git"):
            cls = "d-file"
        elif ln.startswith("+++") or ln.startswith("---"):
            cls = "d-meta"
        elif ln.startswith("@@"):
            cls = "d-hunk"
        elif ln.startswith("+"):
            cls = "d-add"
        elif ln.startswith("-"):
            cls = "d-del"
        out.append(f"<span class=\"{cls}\">{esc(ln)}</span>" if cls else esc(ln))
    return "<pre class=\"diff\">" + "\n".join(out) + "</pre>"


def render_patch_body(body):
    """A [PATCH] message body is format-patch output: mail headers, commit
    message, '---', diffstat + diff. Show the message as prose and fold
    the diff."""
    msg, sep, diff = body.partition("\n---\n")
    # drop format-patch's own From/From:/Date:/Subject: header block
    parts = msg.split("\n\n", 1)
    commit_msg = parts[1] if len(parts) == 2 and parts[0].startswith("From ") else msg
    out = [render_prose(commit_msg)]
    if sep:
        stat, _, rest = diff.partition("\n\ndiff --git")
        out.append("<pre class=\"stat\">" + esc(stat.strip()) + "</pre>")
        if rest:
            out.append("<details class=\"fold\"><summary>show diff</summary>"
                       + render_diff("diff --git" + rest) + "</details>")
    return "\n".join(out)


def fmt_date(d):
    if not d:
        return ""
    return d.strftime("%b %d %H:%M")


def persona_class(p):
    return "p-" + re.sub(r"[^a-z0-9]+", "-", p.lower())


def build(series_dir):
    name = os.path.basename(series_dir.rstrip("/"))
    cur = os.path.join(series_dir, "cur")
    msgs = {}
    for fn in sorted(os.listdir(cur)):
        if fn.endswith(".msg"):
            m = read_msg(os.path.join(cur, fn), os.path.join(series_dir, "attachments"))
            msgs[m["id"]] = m
    roots = []
    for m in msgs.values():
        p = msgs.get(m["parent"]) if m["parent"] else None
        if p:
            p["children"].append(m)
        else:
            roots.append(m)
    for m in msgs.values():
        m["children"].sort(key=lambda x: (x["seq"], x["date"] or datetime.min))
    roots.sort(key=lambda x: (x["version"], x["seq"]))
    return name, msgs, roots


def subtree(m):
    yield m
    for c in m["children"]:
        yield from subtree(c)


def subtree_before(m, stop_ids):
    """Walk a thread, stopping before any nested patch root."""
    yield m
    for c in m["children"]:
        if c["id"] in stop_ids:
            continue
        yield from subtree_before(c, stop_ids)


def tally(cover):
    """Latest tag per persona per patch (and the cover), in cover order."""
    rows = []
    personas = {}
    targets = [cover] + [c for c in cover["children"] if c["subject"].startswith("[PATCH")]
    patch_roots = {c["id"] for c in targets[1:]}
    for t in targets:
        latest = {}
        walk = subtree_before(t, patch_roots) if t is cover else subtree(t)
        for m in walk:
            if m is t or not m["tags"] or m["persona"] == t["persona"]:
                continue
            if m["persona"] not in latest or m["seq"] > latest[m["persona"]][0]:
                latest[m["persona"]] = (m["seq"], m["id"], m["tags"])
            personas[m["persona"]] = (m["harness"], m["model"])
        rows.append((t, latest))
    return rows, personas


def short_subject(s):
    return re.sub(r"^\[PATCH v\d+ \d+/\d+\]\s*", "", s)


def patch_label(m):
    """Standard series numbering for a patch row label: 'Patch vN i/M'.
    Tolerates prefixes with no explicit version and zero-padded numbering;
    falls back to the message's own X-Version for those."""
    mm = re.match(r"^\[PATCH (?:v(\d+) )?(\d+)/(\d+)\]", m["subject"])
    if not mm:
        return short_subject(m["subject"])
    return f"Patch v{mm.group(1) or m['version']} {mm.group(2)}/{mm.group(3)}"


def is_patch(m):
    return m["depth"] == 1 and m["subject"].startswith("[PATCH") and m["body"].startswith("From ")


def who_of(m):
    return esc(m["from"].split(" (AI persona)")[0].split(" <")[0]) or esc(m["persona"])


def reviewer_rollup(version_msgs, author):
    """One entry per non-author persona, in first-seen order: display name,
    harness, model, message count in this version, and how many
    Reviewed-by / NAK tags they issued (from the already-parsed X-Tags)."""
    out = []
    for m in version_msgs:
        p = m["persona"]
        if not p or p == author:
            continue
        r = next((x for x in out if x["persona"] == p), None)
        if r is None:
            r = {"persona": p, "name": "", "harness": m["harness"], "model": m["model"],
                 "count": 0, "rev": 0, "nak": 0}
            out.append(r)
        if not r["name"]:
            r["name"] = m["from"].split(" (AI persona)")[0].split(" <")[0]
        r["count"] += 1
        for t in m["tags"]:
            if t == "Reviewed-by":
                r["rev"] += 1
            elif t == "NAK":
                r["nak"] += 1
    for r in out:
        if not r["name"]:
            r["name"] = r["persona"]
    return out


def render_reviewer(r, series_dir):
    brief = ""
    personas_dir = os.path.join(series_dir, "personas")
    # The X-AI-Persona header comes straight out of the .msg file, which a
    # hand-written message can set to anything, including traversal or an
    # absolute path. Keep the brief read inside <series>/personas/ the way
    # the attachment reader does.
    brief_path = os.path.normpath(os.path.join(personas_dir, r["persona"] + ".md"))
    personas_real = os.path.realpath(personas_dir)
    brief_real = os.path.realpath(brief_path)
    if (os.path.commonpath((brief_real, personas_real)) == personas_real
            and os.path.isfile(brief_real)):
        # The persona brief is plain markdown; inlined as escaped
        # preformatted text, never rendered or executed.
        with open(brief_real, encoding="utf-8", errors="replace") as f:
            brief = '<pre class="persona-brief">' + esc(f.read()) + "</pre>"
    counts = [f"{r['count']} message" + ("s" if r["count"] != 1 else "")]
    if r["rev"]:
        counts.append(f"{r['rev']} Reviewed-by")
    if r["nak"]:
        counts.append(f"{r['nak']} NAK")
    meta = " · ".join(x for x in (esc(r["harness"]), esc(r["model"])) if x)
    body = (f'<p class="rv-line mono">{meta}</p>'
            f'<p class="counts">{"".join(f"<span>{c}</span>" for c in counts)}</p>{brief}')
    return (f'<details class="reviewer">'
            f'<summary><span class="who">{esc(r["name"])}</span> '
            f'<span class="slug mono">{esc(r["persona"])}</span></summary>'
            f'<div class="reviewer-body">{body}</div></details>')


def count_subtree(m):
    return sum(1 for _ in subtree(m)) - 1


def render_index(m, depth=0):
    """The thread as an indented list of one-liners, lore-style: every
    message in reply order, click to jump."""
    glyphs = "".join(f"<span class=\"g {TAG_CLASS.get(t,'t-q')}\" title=\"{esc(t)}\">{TAG_GLYPH.get(t,'·')}</span>" for t in m["tags"])
    subj = short_subject(m["subject"]) if is_patch(m) else m["subject"]
    if depth > 1 and subj.startswith("Re: "):
        subj = "Re: …" if len(subj) > 70 else subj
    label = "cover" if depth == 0 else ""
    row = (f"<li style=\"--d:{min(depth, 8)}\" class=\"{'ix-patch' if is_patch(m) else ''}\">"
           f"<a href=\"#m-{esc(m['id'])}\"><span class=\"ix-id\">{esc(m['id'][:7])}</span>"
           f"<span class=\"ix-who\">{who_of(m)}</span>{glyphs}"
           f"<span class=\"ix-subj\">{esc(label or subj)}</span></a></li>")
    return row + "".join(render_index(c, depth + 1) for c in m["children"])


def render_message(m, depth=0):
    tagchips = "".join(f"<span class=\"tag {TAG_CLASS.get(t, 't-q')}\">{esc(t)}</span>" for t in m["tags"])
    meta = f"{esc(m['harness'])}/{esc(m['model'])}" if m["harness"] else ""
    body = render_patch_body(m["body"]) if is_patch(m) else render_prose(m["body"])
    attachment_html = ""
    if m["attachments"]:
        items = []
        for attachment in m["attachments"]:
            label = esc(attachment["ref"])
            if attachment["href"]:
                link = (f'<a download href="{esc(attachment["href"])}">{label}</a>'
                        f' <span class="attachment-type">({esc(attachment["mime"])})</span>')
                if attachment["mime"].startswith("image/") and attachment["mime"] != "image/svg+xml":
                    link += f'<br><img class="attachment-preview" src="{esc(attachment["href"])}" alt="{label}">'
            else:
                link = f"{label} <span class=\"attachment-missing\">(unavailable)</span>"
            items.append(f"<li>{link}</li>")
        attachment_html = '<div class="attachments"><span class="attachment-label">attachments</span><ul>' + "".join(items) + "</ul></div>"
    kids = "".join(render_message(c, depth + 1) for c in m["children"])
    n = count_subtree(m)
    fold = ""
    if kids:
        word = "reply" if n == 1 else "replies"
        fold = (f"<details class=\"thread-fold\" open><summary>{n} {word} in this thread</summary>"
                f"<div class=\"replies\">{kids}</div></details>")
    return (
        f"<article class=\"msg d{min(depth, 8)} {persona_class(m['persona'])}{' patch' if is_patch(m) else ''}\" id=\"m-{esc(m['id'])}\">"
        f"<header><span class=\"who\">{who_of(m)}</span>"
        f"<span class=\"meta\">{meta}</span>{tagchips}"
        f"<time>{fmt_date(m['date'])}</time><a class=\"mid\" href=\"#m-{esc(m['id'])}\">{esc(m['id'][:7])}</a></header>"
        f"<h3 class=\"subj\">{esc(m['subject'])}</h3>"
        f"<div class=\"body\">{body}{attachment_html}</div>"
        f"{fold}"
        f"</article>"
    )


def render_series(series_dir):
    name, msgs, roots = build(series_dir)
    sections = []
    covers = [r for r in roots if r["depth"] == 0 and r["subject"].startswith("[PATCH")]
    for cover in covers:
        v = cover["version"]
        version_roots = [r for r in roots if r["version"] == v]
        rows, personas = tally(cover)
        pcols = sorted(personas)
        thead = "".join(f"<th title=\"{esc(personas[p][0])}/{esc(personas[p][1])}\">{esc(p)}</th>" for p in pcols)
        trows = []
        for t, latest in rows:
            cells = []
            for p in pcols:
                if p in latest:
                    tg = latest[p][2][0]
                    cells.append(f"<td><a class=\"cell {TAG_CLASS.get(tg,'t-q')}\" href=\"#m-{esc(latest[p][1])}\" title=\"{esc(tg)}\">{TAG_GLYPH.get(tg,'·')}</a></td>")
                else:
                    cells.append("<td><span class=\"cell none\">·</span></td>")
            if t is cover:
                rowcell = f'<th scope="row"><a href="#m-{esc(t["id"])}">cover</a></th>'
            else:
                # Standard series numbering as the row label; the full
                # subject stays on the row for hover.
                rowcell = (f'<th scope="row" title="{esc(t["subject"])}">'
                           f'<a href="#m-{esc(t["id"])}">{esc(patch_label(t))}</a></th>')
            trows.append(f"<tr>{rowcell}{''.join(cells)}</tr>")
        n_patches = len(rows) - 1
        version_msgs = [m for root in version_roots for m in subtree(root)]
        n_replies = sum(1 for m in version_msgs if m["depth"] >= 1 and not is_patch(m))
        index = "".join(render_index(root) for root in version_roots)
        thread = "".join(render_message(root) for root in version_roots)
        n_messages = len(version_msgs)
        # Count the same set the box below lists: every non-author persona
        # that posted in this version, not just the ones that tagged a
        # patch (the tally's set), so header and box never disagree.
        reviewer_entries = reviewer_rollup(version_msgs, cover["persona"])
        reviewers = "".join(render_reviewer(r, series_dir) for r in reviewer_entries)
        reviewers_block = ""
        if reviewer_entries:
            reviewers_block = (f'  <div class="reviewers">\n'
                               f'    <p class="eyebrow">reviewers</p>\n'
                               f'    {reviewers}\n  </div>')
        sections.append(f"""
<section class="series" id="{esc(name)}-v{v}">
  <div class="series-head">
    <p class="eyebrow">series</p>
    <h2>{esc(name)} <span class="v">v{v}</span></h2>
    <p class="counts"><span>{n_patches} patches</span><span>{n_replies} replies</span><span>{len(reviewer_entries)} reviewers</span></p>
  </div>
  <div class="tally-wrap">
    <table class="tally">
      <caption>Latest tag per reviewer per patch. R reviewed, A acked, C changes requested, ? question, N nak.</caption>
      <thead><tr><th scope="col">patch</th>{thead}</tr></thead>
      <tbody>{''.join(trows)}</tbody>
    </table>
  </div>
  {reviewers_block}
  <details class="index-fold" open>
    <summary>thread index — {n_messages} messages</summary>
    <div class="index-wrap"><ol class="tidx">{index}</ol></div>
  </details>
  <div class="thread">{thread}</div>
</section>""")
    return name, "\n".join(sections)


CSS = """
:root{
  --bg:#F4F5F7; --surface:#FFFFFF; --ink:#1C2130; --muted:#5C6478; --rule:#D9DCE3;
  --accent:#3B4A7A; --accent-ink:#FFFFFF; --quote-bg:#EEF0F4; --quote-bar:#B8C0D4;
  --code-bg:#EDEFF3; --diff-bg:#F7F8FA;
  --rev:#2E7D4F; --rev-bg:#E4F3EA; --ack:#3A7D5E; --ack-bg:#E9F4EE;
  --test:#357A75; --test-bg:#E2F2F0;
  --chg:#B26A00; --chg-bg:#FBF0DA; --q:#2F6FC1; --q-bg:#E6EEF9; --nak:#B3261E; --nak-bg:#FBE4E2;
  --add:#1F6E3D; --del:#A8261F; --hunk:#5A6C9E;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#14171F; --surface:#1B1F29; --ink:#E4E6EC; --muted:#9AA1B2; --rule:#2A2F3B;
    --accent:#8FA0D6; --accent-ink:#14171F; --quote-bg:#1F2430; --quote-bar:#3E4863;
    --code-bg:#222735; --diff-bg:#181C25;
    --rev:#6FCF97; --rev-bg:#1B2E24; --ack:#7CC9A3; --ack-bg:#1A2A22;
    --test:#78C8BF; --test-bg:#19302E;
    --chg:#F4B860; --chg-bg:#2E2618; --q:#8AB4F8; --q-bg:#1B2536; --nak:#F28B82; --nak-bg:#331D1B;
    --add:#7BD88F; --del:#F08A84; --hunk:#8FA0D6;
  }
}
:root[data-theme="dark"]{
  --bg:#14171F; --surface:#1B1F29; --ink:#E4E6EC; --muted:#9AA1B2; --rule:#2A2F3B;
  --accent:#8FA0D6; --accent-ink:#14171F; --quote-bg:#1F2430; --quote-bar:#3E4863;
  --code-bg:#222735; --diff-bg:#181C25;
  --rev:#6FCF97; --rev-bg:#1B2E24; --ack:#7CC9A3; --ack-bg:#1A2A22;
  --test:#78C8BF; --test-bg:#19302E;
  --chg:#F4B860; --chg-bg:#2E2618; --q:#8AB4F8; --q-bg:#1B2536; --nak:#F28B82; --nak-bg:#331D1B;
  --add:#7BD88F; --del:#F08A84; --hunk:#8FA0D6;
}
*{box-sizing:border-box}
html{font-size:16px}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"Source Serif 4",Georgia,"Times New Roman",serif;line-height:1.55;}
.mono, header, .mid, .meta, .tag, .tally, .eyebrow, .counts, time, .stat, .diff, .code, code, .trailer{
  font-family:"JetBrains Mono","SFMono-Regular",Menlo,Consolas,monospace;}
.page{max-width:76rem;margin:0 auto;padding:2.5rem 1.25rem 6rem}
.masthead{display:flex;flex-wrap:wrap;align-items:baseline;gap:.75rem 1.5rem;border-bottom:2px solid var(--ink);padding-bottom:1rem;margin-bottom:2.5rem}
.masthead h1{margin:0;font-size:1.75rem;font-weight:600;letter-spacing:-.01em;text-wrap:balance}
.masthead .sub{color:var(--muted);font-size:.85rem}
.eyebrow{margin:0;font-size:.7rem;letter-spacing:.14em;text-transform:uppercase;color:var(--muted)}
.series{margin-bottom:4rem}
.series-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:.5rem 1.25rem;margin-bottom:1rem}
.series-head h2{margin:0;font-size:1.5rem;font-weight:600}
.series-head .v{color:var(--accent);font-weight:500}
.counts{margin:0;display:flex;gap:1rem;font-size:.8rem;color:var(--muted)}
.tally-wrap{overflow-x:auto;margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.tally{border-collapse:collapse;font-size:.78rem;min-width:100%}
.tally caption{text-align:left;padding:.6rem .8rem;color:var(--muted);font-size:.72rem;border-bottom:1px solid var(--rule)}
.tally th,.tally td{padding:.4rem .6rem;border-bottom:1px solid var(--rule);text-align:left;white-space:nowrap}
.tally thead th{color:var(--muted);font-weight:500;font-size:.7rem;letter-spacing:.06em;text-transform:uppercase}
.tally tbody th{font-weight:500;max-width:34rem;overflow:hidden;text-overflow:ellipsis}
.tally tbody th a{color:inherit;text-decoration:none}
.tally tbody th a:hover{text-decoration:underline}
.tally td{text-align:center}
.cell{display:inline-block;min-width:1.6rem;padding:.05rem .3rem;border-radius:2px;text-decoration:none;font-weight:600}
.cell.none{color:var(--rule)}
.reviewers{margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.reviewers .eyebrow{padding:.6rem .8rem .35rem}
.reviewer{border-top:1px solid var(--rule)}
.reviewer>summary{cursor:pointer;display:flex;flex-wrap:wrap;align-items:baseline;gap:.15rem .5rem;padding:.55rem .8rem;font-size:.85rem}
.reviewer>summary .who{font-weight:600}
.reviewer>summary .slug{color:var(--accent);font-size:.75rem}
.reviewer-body{padding:0 .8rem .65rem;font-size:.82rem}
.rv-line{color:var(--muted);margin:0 0 .35rem;font-size:.78rem}
.persona-brief{margin:.5rem 0 0;padding:.6rem .8rem;background:var(--code-bg);font-size:.78rem;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere;border-radius:2px}
.t-rev{color:var(--rev);background:var(--rev-bg)}
.t-ack{color:var(--ack);background:var(--ack-bg)}
.t-test{color:var(--test);background:var(--test-bg)}
.t-chg{color:var(--chg);background:var(--chg-bg)}
.t-q{color:var(--q);background:var(--q-bg)}
.t-nak{color:var(--nak);background:var(--nak-bg)}
.thread{display:flex;flex-direction:column;gap:1rem}
.msg{background:var(--surface);border:1px solid var(--rule);padding:1rem 1.25rem 1.1rem;scroll-margin-top:1rem}
.msg header{display:flex;flex-wrap:wrap;align-items:center;gap:.4rem .7rem;font-size:.75rem;color:var(--muted);margin-bottom:.35rem}
.msg header .who{color:var(--ink);font-weight:600}
.msg header .meta{opacity:.85}
.msg header time{margin-left:auto}
.msg header .mid{color:var(--muted);text-decoration:none}
.msg header .mid:hover{color:var(--accent)}
.tag{padding:.05rem .4rem;border-radius:2px;font-size:.7rem;font-weight:600}
.subj{margin:0 0 .75rem;font-size:1.02rem;font-weight:600;line-height:1.3;text-wrap:balance}
.body{max-width:68ch;font-size:.98rem}
.body p{margin:0 0 .8rem}
.body h3,.body h4,.body h5,.body h6{margin:1.1rem 0 .4rem;font-size:.72rem;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);font-weight:600;font-family:"JetBrains Mono",monospace}
.body ul,.body ol{margin:0 0 .8rem;padding-left:1.4rem}
.body li{margin:.15rem 0}
.body code{font-size:.85em;background:var(--code-bg);padding:.05em .3em;border-radius:2px}
.body blockquote{margin:0 0 .9rem;padding:.4rem .9rem;background:var(--quote-bg);border-left:3px solid var(--quote-bar);color:var(--muted);font-size:.92rem}
.body blockquote p{margin:0 0 .4rem}
.body blockquote p:last-child{margin:0}
.attachments{margin-top:1rem;padding:.6rem .8rem;background:var(--code-bg);font-family:"JetBrains Mono","SFMono-Regular",Menlo,Consolas,monospace;font-size:.78rem}
.attachment-label{color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.attachments ul{margin:.35rem 0 0;padding-left:1.2rem}
.attachments a{color:var(--accent)}
.attachment-type,.attachment-missing{color:var(--muted)}
.attachment-preview{display:block;max-width:100%;max-height:24rem;margin-top:.5rem}
.code,.stat,.diff{margin:0 0 .9rem;padding:.7rem .9rem;background:var(--code-bg);font-size:.78rem;line-height:1.45;overflow-x:auto;border-radius:2px}
.diff{background:var(--diff-bg)}
.d-add{color:var(--add)} .d-del{color:var(--del)} .d-hunk{color:var(--hunk)} .d-file{font-weight:700} .d-meta{color:var(--muted)}
.trailer{font-size:.82rem;font-weight:600;padding:.15rem .5rem;display:inline-block;border-radius:2px;margin-right:.4rem}
.fold summary{cursor:pointer;font-family:"JetBrains Mono",monospace;font-size:.75rem;color:var(--accent);margin:0 0 .5rem}
.fold summary:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.index-fold{margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.index-fold summary{cursor:pointer;padding:.6rem .8rem;font-family:"JetBrains Mono",monospace;font-size:.72rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.index-wrap{overflow-x:auto;border-top:1px solid var(--rule)}
.tidx{list-style:none;margin:0;padding:.4rem 0;font-size:.76rem;min-width:max-content}
.tidx li{padding:.12rem .8rem .12rem calc(.8rem + var(--d) * 1.25rem);position:relative;white-space:nowrap}
.tidx li a{color:inherit;text-decoration:none;display:inline-flex;align-items:center;gap:.55rem}
.tidx li a:hover .ix-subj{text-decoration:underline}
.tidx li[style*="--d:0"]{font-weight:600}
.tidx li:not([style*="--d:0"])::before{content:"";position:absolute;left:calc(.8rem + var(--d) * 1.25rem - .8rem);top:0;bottom:50%;width:.55rem;border-left:1px solid var(--quote-bar);border-bottom:1px solid var(--quote-bar)}
.tidx .ix-id{color:var(--muted)}
.tidx .ix-who{color:var(--accent);min-width:7.5rem}
.tidx .ix-patch .ix-who{color:var(--muted)}
.tidx .ix-subj{color:var(--ink)}
.tidx .g{display:inline-block;min-width:1.1rem;text-align:center;padding:0 .2rem;border-radius:2px;font-weight:700;font-size:.68rem}
.thread-fold{margin-top:1rem}
.thread-fold>summary{cursor:pointer;font-family:"JetBrains Mono",monospace;font-size:.72rem;color:var(--muted);letter-spacing:.04em;margin-bottom:.6rem}
.thread-fold>summary:hover{color:var(--accent)}
.replies{padding-left:1rem;border-left:2px solid var(--quote-bar);display:flex;flex-direction:column;gap:.9rem}
.msg.d0{border-color:var(--ink)}
.msg.patch{background:var(--bg)}
.msg.patch>header .who{color:var(--muted)}
.msg .msg{border-color:var(--rule)}
.p-core header .who{color:var(--accent)}
.foot{margin-top:4rem;padding-top:1rem;border-top:1px solid var(--rule);color:var(--muted);font-size:.8rem;max-width:68ch}
@media (max-width:640px){.page{padding:1.5rem .9rem 4rem}.msg{padding:.8rem .9rem}.replies{padding-left:.6rem}}
@media (prefers-reduced-motion: no-preference){html{scroll-behavior:smooth}}
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("series_dirs", nargs="+", metavar="SERIES_DIR",
                        help="lkml-mode series mailbox directory")
    parser.add_argument("--title", default="Review Threads",
                        help="document title and masthead (default: %(default)s)")
    parser.add_argument("-o", "--output", metavar="FILE",
                        help="write HTML to FILE instead of stdout")
    args = parser.parse_args(argv)
    sections = []
    names = []
    for d in args.series_dirs:
        name, sec = render_series(d)
        names.append(name)
        sections.append(sec)
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    toc = " · ".join(f"<a href=\"#{esc(n)}-v1\">{esc(n)}</a>" for n in names)
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(args.title)}</title>
<style>{CSS}</style>
</head>
<body>
<div class="page">
  <div class="masthead">
    <h1>{esc(args.title)}</h1>
    <span class="sub mono">{toc}</span>
    <span class="sub mono">rendered {now}</span>
  </div>
  {''.join(sections)}
  <p class="foot">Every message on these threads is stamped by the mailbox with its persona, harness and model. Reviewers are AI personas running in sandboxed clones, and only the operator merges anything.</p>
</div>
</body>
</html>
"""
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(document)
    else:
        sys.stdout.write(document)


if __name__ == "__main__":
    main()
