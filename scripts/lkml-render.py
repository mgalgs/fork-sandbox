#!/usr/bin/env python3
"""lkml-render.py — render one or more lkml-mode series mailboxes as a
single self-contained HTML page: a threaded archive with a per-version
tally, patch bodies folded, quotes and trailers styled.

Usage: lkml-render.py <series-dir> [<series-dir> ...] > out.html
       lkml-render.py --text <series-dir> [<series-dir> ...] > out.txt

The default HTML render is the human view. --text is the agent view:
the same thread selection and ordering as plain text on stdout, with
message bodies indented under their headers (so a body cannot forge a
message header) and [PATCH] message bodies cut at their first
diff --git line, so the commit message and diffstat stay and the
diff goes (it lives in the series branch).

A series dir is $LKML_MAILBOX_ROOT/<series> (it holds cur/*.msg). Reads
only; never runs git.

When a series dir holds results-v<N>.md (the per-version results file,
written by the summarizer; a results-v<N>.json may sit next to it and is
ignored), the HTML render adds a per-version Results card between the
Reviewers panel and the Thread Index: the "# Summary" section sits
outside a native <details>, the "# Details" section inside it, and
7-hex message-id tokens that match a message in the mailbox link to
that message. --text prints the same sections as a bare 'results'
block (no links); an empty section is omitted in both backends.
Without the file there is no card and the render is
byte-identical to a mailbox without results.

When a series dir holds results-series.md (the whole-series narrative,
written by the summarizer's --series mode), the HTML render adds a
page-level card immediately after the masthead, before the first
series section -- the same treatment, but the eyebrow reads
'series summary' and the wrapper class is 'results results-series'
so the card can be styled independently later. Its id autolink map
covers ALL versions' messages in the series dir. --text prints it as
a 'series-summary' block at the very top, before the first version
section. Without the file the render is byte-identical to a mailbox
without it.
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
# Max characters for an HTML tally row label. The .tally table is in auto
# layout, where a browser treats max-width on a <th> as a suggestion and
# grows the column to fit the content, so the CSS ellipsis is not a
# reliable cap; the label is capped here instead, mirroring the text
# tally's column budget. The full label stays on hover via the title
# attribute.
HTML_TALLY_LABEL_CAP = 64


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


def patch_label(m):
    """The patch subject in canonical lore style: '[PATCH vN i/M] subject'.
    N comes from the subject's own prefix; a series posted as bare
    '[PATCH i/M]' (no version) falls back to the message's own X-Version.
    i is zero-padded to the width of M, lore-style (02/14, 03/24), even
    when the source subject was not padded. An already-canonical subject
    round-trips byte-identical; a subject with no [PATCH] prefix is
    returned verbatim.

    A subject wrapped in a 'Re: ' carrier (a reply whose stored subject is
    'Re: [PATCH ...]', however many 'Re: ' layers deep) is normalized the
    same way and comes back under a single 'Re: '. Collapsing the Re: run
    is part of the PATCH normalization: a no-prefix subject stays verbatim,
    'Re: Re: ' and all."""
    subj = m["subject"]
    re_prefix = ""
    while subj.startswith("Re: "):
        re_prefix = "Re: "
        subj = subj[4:]
    mm = re.match(r"^\[PATCH (?:v(\d+) )?(\d+)/(\d+)\]\s*(.*)$", subj)
    if not mm:
        return m["subject"]
    version = mm.group(1) or str(m["version"])
    idx = mm.group(2).zfill(len(mm.group(3)))
    return re_prefix + f"[PATCH v{version} {idx}/{mm.group(3)}] {mm.group(4)}"


def is_patch(m):
    return m["depth"] == 1 and m["subject"].startswith("[PATCH") and m["body"].startswith("From ")


def who_of(m):
    return esc(m["from"].split(" (AI persona)")[0].split(" <")[0]) or esc(m["persona"])


def reviewer_rollup(version_msgs, author, tally_rows):
    """One entry per non-author persona, sorted by persona slug (the same
    order the matrix's columns are in): display name, harness, model,
    message count in this version, and how many patches
    their LATEST tag is a Reviewed-by / NAK. The verdict counts reuse the
    tally's latest-tag-per-persona-per-patch supersession instead of
    counting every tag ever posted -- a NAK withdrawn by a later
    Reviewed-by on the same patch is not an open NAK, and this page
    reports current state, not history."""
    open_verdicts = {}
    for _t, latest in tally_rows:
        for p, (_seq, _mid, tags) in latest.items():
            v = open_verdicts.setdefault(p, [0, 0])
            if "Reviewed-by" in tags:
                v[0] += 1
            if "NAK" in tags:
                v[1] += 1
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
    for r in out:
        if not r["name"]:
            r["name"] = r["persona"]
        r["rev"], r["nak"] = open_verdicts.get(r["persona"], (0, 0))
    out.sort(key=lambda r: r["persona"])
    return out


def strip_frontmatter(text):
    """Drop a leading '---' ... '---' YAML frontmatter block, if present.
    The archived persona file's frontmatter names the persona's DEFAULT
    harness/model; under lkml-round.sh --model-override (the documented
    cheap smoke round) the messages in the version were in fact run on a
    different one, so printing the block next to the message headers'
    harness/model line would state two different models for the same
    reviewer."""
    m = re.match(r"\A---\n.*?\n---\n?", text, re.DOTALL)
    if m:
        return text[m.end():].lstrip("\n")
    return text


def persona_brief_path(series_dir, persona):
    """The on-disk persona brief for a message's X-AI-Persona value, or
    None. The header comes straight out of the .msg file, which a
    hand-written message can set to anything, including traversal or an
    absolute path; keep the read inside <series>/personas/ the way the
    attachment reader does."""
    personas_dir = os.path.join(series_dir, "personas")
    brief_path = os.path.normpath(os.path.join(personas_dir, persona + ".md"))
    personas_real = os.path.realpath(personas_dir)
    brief_real = os.path.realpath(brief_path)
    if (os.path.commonpath((brief_real, personas_real)) == personas_real
            and os.path.isfile(brief_real)):
        return brief_real
    return None


def read_results_file(series_dir, filename):
    """A results markdown file in <series> split into ("# Summary" body,
    "# Details" body), or None when absent. The filename is fixed by
    the caller (never a message-derived value), and the path is
    realpath-contained in the series dir the way persona_brief_path and
    the attachment reader contain theirs, so a file planted as a
    symlink outside the mailbox cannot steer the read."""
    path = os.path.join(series_dir, filename)
    series_real = os.path.realpath(series_dir)
    path_real = os.path.realpath(path)
    if (os.path.commonpath((path_real, series_real)) == series_real
            and os.path.isfile(path_real)):
        with open(path_real, encoding="utf-8", errors="replace") as f:
            return split_results(f.read())
    return None


def read_results(series_dir, version):
    """The per-version results file <series>/results-v<N>.md (N built
    from the integer version), or None when absent. A companion
    results-v<N>.json is ignored: the card renders the .md only."""
    return read_results_file(series_dir, f"results-v{version}.md")


def read_series_results(series_dir):
    """The whole-series results file <series>/results-series.md (written
    by the summarizer's --series mode), or None when absent."""
    return read_results_file(series_dir, "results-series.md")


def split_results(text):
    """Split a results file into ("# Summary" body, "# Details" body).
    The bodies are verbatim, stripped of nothing but trailing newlines.
    A missing '# Summary' means the summary is everything above the
    '# Details' header (the whole file when there is no header at
    all); a missing '# Details' means the details body is empty.
    Each body ends where the other section's header sits,
    in either order, so a # Details that precedes # Summary cannot
    swallow the summary header and body into the details."""
    lines = text.splitlines()
    s = next((i for i, ln in enumerate(lines) if ln == "# Summary"), None)
    d = next((i for i, ln in enumerate(lines) if ln == "# Details"), None)
    if s is None:
        s = -1
    if d is None:
        d = len(lines)
    end_s = d if d > s else len(lines)
    end_d = s if s > d else len(lines)
    return "\n".join(lines[s + 1:end_s]).rstrip("\n"), "\n".join(lines[d + 1:end_d]).rstrip("\n")


def id_prefix_map(msgs):
    """Seven-hex message-id prefix to full id, for the results card's
    autolinker. Ambiguous prefixes (two messages sharing their first
    seven hex characters) are dropped rather than guessed at."""
    by_prefix = {}
    for m in msgs.values():
        p = m["id"][:7]
        if len(p) == 7:
            by_prefix.setdefault(p, set()).add(m["id"])
    return {p: next(iter(full)) for p, full in by_prefix.items() if len(full) == 1}


HEX_TOKEN_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-f]{7}(?![0-9a-fA-F])")


def link_ids(escaped, id_map):
    """Turn bare 7-hex message-id tokens in already-escaped text into
    links to the #m-<id> anchors the renderer itself constructs. The
    match runs on the ESCAPED text and inserts only those anchors, so a
    results file cannot smuggle markup through the linker; a token that
    matches no id (or matches ambiguously) stays plain text."""
    def sub(match):
        full = id_map.get(match.group(0))
        return f'<a href="#m-{esc(full)}">{match.group(0)}</a>' if full else match.group(0)
    return HEX_TOKEN_RE.sub(sub, escaped)


def render_results_card(series_dir, version, id_map):
    """The per-version Results card, placed between the Reviewers panel
    and the Thread Index: the Summary section is visible in the
    collapsed state, only Details sits inside the "show details"
    summary -- omitted entirely when the Details body is empty, the
    way the --text block omits its empty sections. Both sections are
    escaped preformatted text in the file's own layout (the
    persona-briefs treatment) -- never rendered or executed -- with
    7-hex message-id tokens autolinked. Returns "" when the results
    file is absent."""
    res = read_results(series_dir, version)
    if res is None:
        return ""
    summary, details = res
    card = (f'  <div class="results">\n'
            f'    <p class="eyebrow">results</p>\n'
            f'    <div class="results-summary">{link_ids(esc(summary), id_map)}</div>\n')
    if details:
        card += (f'    <details class="results-fold">\n'
                 f'      <summary>show details</summary>\n'
                 f'      <pre class="results-details">{link_ids(esc(details), id_map)}</pre>\n'
                 f'    </details>\n')
    return card + '  </div>'


def render_series_card(series_dir, id_map):
    """The page-level series summary card, placed immediately after
    the masthead, before the first series section: the same treatment
    as the per-version card (Summary outside the "show details"
    fold, Details inside it, escaped preformatted, autolinked, empty
    sections omitted). Two differences: the eyebrow reads 'series
    summary' and the wrapper class is 'results results-series', so
    the card can be styled independently later without markup surgery.
    The id_map must cover ALL versions' messages (the caller builds it
    over the whole series dir). Returns "" when the file is absent."""
    res = read_series_results(series_dir)
    if res is None:
        return ""
    summary, details = res
    card = (f'  <div class="results results-series">\n'
            f'    <p class="eyebrow">series summary</p>\n'
            f'    <div class="results-summary">{link_ids(esc(summary), id_map)}</div>\n')
    if details:
        card += (f'    <details class="results-fold">\n'
                 f'      <summary>show details</summary>\n'
                 f'      <pre class="results-details">{link_ids(esc(details), id_map)}</pre>\n'
                 f'    </details>\n')
    return card + '  </div>'


def render_reviewer(r, series_dir):
    brief = ""
    brief_real = persona_brief_path(series_dir, r["persona"])
    if brief_real:
        # The persona brief is plain markdown; inlined as escaped
        # preformatted text, never rendered or executed.
        with open(brief_real, encoding="utf-8", errors="replace") as f:
            brief = '<pre class="persona-brief">' + esc(strip_frontmatter(f.read())) + "</pre>"
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


def text_body(m):
    """The message body for --text mode. Cover letters and replies go
    out in full; a [PATCH] message (is_patch: a depth-1 [PATCH]-
    subjected message with a format-patch body) keeps the commit
    message and the diffstat -- the format-patch body separates them
    from the diff at the first 'diff --git' line, and the diff lives
    in git on the series branch, so it is summarized, not inlined. A
    reply that happens to carry a [PATCH] subject (the reply Subject:
    is optional and used verbatim) goes out in full. The cover letter
    is itself a [PATCH x 0/N] subject but, like every reply, goes out
    in full."""
    if not is_patch(m):
        return m["body"].rstrip("\n")
    lines = m["body"].splitlines()
    cut = next((i for i, ln in enumerate(lines) if ln == "---"), None)
    if cut is None:
        return m["body"].rstrip("\n")
    msg = lines[:cut]
    # drop format-patch's own From/From:/Date:/Subject: header block
    if msg and msg[0].startswith("From "):
        blank = next((i for i, ln in enumerate(msg) if not ln.strip()), 0)
        msg = msg[blank + 1:]
    # format-patch puts the diffstat between '---' and the first
    # 'diff --git'; keep it (the HTML render does) and summarize only
    # the diff itself. Trim only newlines: a diffstat's first line
    # carries the leading space its | column is aligned on, and
    # .strip() would dedent just that line.
    rest = lines[cut + 1:]
    d = next((i for i, ln in enumerate(rest) if ln.startswith("diff --git")), None)
    stat = "\n".join(rest[:d] if d is not None else rest).strip("\n")
    diff = rest[d:] if d is not None else []
    out = "\n".join(msg).strip("\n")
    if stat:
        out += "\n" + stat
    if diff:
        out += f"\n[diff omitted: {len(diff)} lines -- see the series branch]"
    return out


def render_text_message(out, m, nums, depth):
    """One message of the --text thread: separator, numbered header, the
    From/Subject/Tags lines, then the body. `nums` maps id to
    (number, parent number) from a pre-order walk, so this prints the
    thread in the same order the HTML render nests it in."""
    num, parent_num = nums[m["id"]]
    rel = f" · reply to #{parent_num}" if parent_num else ""
    out.append("-" * 72)
    out.append(f"== #{num}{rel} · depth {depth}")
    line = f"From: {m['from']}"
    meta = []
    if m["persona"]:
        meta.append(f"persona: {m['persona']}")
    if m["harness"]:
        meta.append(f"harness: {m['harness']}")
    if m["model"]:
        meta.append(f"model: {m['model']}")
    if meta:
        line += "  [" + " · ".join(meta) + "]"
    out.append(line)
    out.append(f"Subject: {patch_label(m)}")
    if m["tags"]:
        out.append("Tags: " + ", ".join(m["tags"]))
    if m["attachments"]:
        out.append("Attachments: " + ", ".join(a["ref"] for a in m["attachments"]))
    # The body is indented under its header: a message block here is
    # the 72-dash separator, the '== #' line, the From/Subject/Tags
    # lines, then the body, and a body that carried a line of 72
    # dashes and its own '== #99 ...' line would otherwise read as a
    # second message. Every body line is prefixed, so the header
    # grammar stays unforgeable from the body; the prefix is uniform,
    # so the diffstat's fixed-width alignment survives it.
    body = text_body(m)
    if body:
        out.extend("  " + ln for ln in body.split("\n"))
    else:
        out.append("")
    for c in m["children"]:
        render_text_message(out, c, nums, depth + 1)


def fit_tally_label(label, budget):
    """Truncate a text-tally row label to at most `budget` columns, always
    marking the cut with a trailing ellipsis. When the [PATCH vN i/M]
    prefix fits the budget it survives intact and the cut lands on the
    SUBJECT part; a smaller budget cuts the prefix itself, and a zero
    budget drops the label entirely (the tag columns, not the label,
    are the overflow then). Either way the returned label never takes
    more than `budget` columns. Never falls back to the bare 'Patch vN
    i/M' form."""
    if len(label) <= budget:
        return label
    if budget <= 0:
        return ""
    mm = re.match(r"^(\[PATCH v\d+ \d+/\d+\] )(.*)$", label)
    if mm and budget > len(mm.group(1)) + 1:
        keep = budget - len(mm.group(1)) - 1
        return mm.group(1) + mm.group(2)[:keep] + "\u2026"
    return label[:budget - 1] + "\u2026"


def render_text_tally(out, rows, pcols):
    """The per-version tally as a fixed-width table: a row per patch
    (same labels as the HTML rows), a column per listed reviewer, cells
    the same latest-tag-per-reviewer-per-patch letters. The first column
    sizes from the longest label; when that would push the table past
    ~120 columns, the subject part of the label is truncated (the
    prefix intact) rather than the table."""
    grid = [["patch"] + list(pcols)]
    for t, latest in rows:
        label = "cover" if t is rows[0][0] else patch_label(t)
        grid.append([label] + [TAG_GLYPH.get(latest[p][2][0], "·") if p in latest else "·" for p in pcols])
    widths = [max(len(row[i]) for row in grid) for i in range(len(grid[0]))]
    # Gap is two spaces between columns; the label column alone absorbs
    # the overflow, so the tag columns stay readable. Floor at zero: when
    # the tag columns alone eat the whole 120, no label can fit and the
    # overflow lives in the configured panel width, not in a mangled
    # label (a negative slice would chop the label's END and push the
    # rows far past 120).
    budget = max(0, 120 - sum(widths[1:]) - 2 * (len(widths) - 1))
    if widths[0] > budget:
        for row in grid:
            row[0] = fit_tally_label(row[0], budget)
        widths[0] = max(len(row[0]) for row in grid)
    out.append("Latest tag per reviewer per patch. R reviewed, A acked, "
               "C changes requested, ? question, N nak.")
    for row in grid:
        out.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip())


def render_text_reviewers(out, name, series_dir, reviewer_entries):
    """One block per reviewer, in the box's order. No brief inlining in
    text mode -- just a pointer to the file, when it exists."""
    out.append("reviewers")
    for r in reviewer_entries:
        out.append(f"  {r['name']} ({r['persona']})")
        meta = " · ".join(x for x in (r["harness"], r["model"]) if x)
        if meta:
            out.append(f"    {meta}")
        counts = [f"{r['count']} message" + ("s" if r["count"] != 1 else "")]
        if r["rev"]:
            counts.append(f"{r['rev']} Reviewed-by")
        if r["nak"]:
            counts.append(f"{r['nak']} NAK")
        out.append(f"    {', '.join(counts)}")
        if persona_brief_path(series_dir, r["persona"]):
            out.append(f"    brief: {name}/personas/{r['persona']}.md")


def render_text_series(series_dir):
    """One series dir as plain text: a header with the same counts the
    HTML header shows, then every message in thread order."""
    name, msgs, roots = build(series_dir)
    sections = []
    # The whole-series results file, if any: a 'series-summary' block
    # at the very top, before the first version section, with the same
    # column-0 labels / two-space body rules as the per-version
    # 'results' block (a body line cannot forge a label, no links in
    # text mode, empty sections omit their label and body).
    series_res = read_series_results(series_dir)
    if series_res is not None:
        lines = ["series-summary"]
        if series_res[0]:
            lines.append("# Summary")
            lines.extend("  " + ln for ln in series_res[0].split("\n"))
        if series_res[1]:
            if series_res[0]:
                lines.append("")
            lines.append("# Details")
            lines.extend("  " + ln for ln in series_res[1].split("\n"))
        sections.append("\n".join(lines))
    covers = [r for r in roots if r["depth"] == 0 and r["subject"].startswith("[PATCH")]
    for cover in covers:
        v = cover["version"]
        version_roots = [r for r in roots if r["version"] == v]
        version_msgs = [m for root in version_roots for m in subtree(root)]
        rows, personas = tally(cover)
        # The same counts the HTML header shows, computed the same way:
        # patches from the tally's targets, replies as everything at
        # depth >= 1 that is not a patch.
        n_replies = sum(1 for m in version_msgs if m["depth"] >= 1 and not is_patch(m))
        n_patches = len(rows) - 1
        reviewer_entries = reviewer_rollup(version_msgs, cover["persona"], rows)
        # One matrix column per reviewer the box lists, same set and
        # (alphabetical) order as the HTML table.
        pcols = sorted(set(personas) | {r["persona"] for r in reviewer_entries})
        lines = [f"{name} v{v}",
                 f"{n_patches} patches · {n_replies} replies · {len(reviewer_entries)} reviewers",
                 ""]
        render_text_tally(lines, rows, pcols)
        lines.append("")
        if reviewer_entries:
            render_text_reviewers(lines, name, series_dir, reviewer_entries)
            lines.append("")
        # The Results card's sections as a text block in the same
        # position: bare 'results' header, then the section labels
        # ('# Summary', '# Details') and the verbatim bodies. The
        # labels sit at column 0 -- like the 'results' header and the
        # message headers -- while every body line carries its
        # two-space prefix, so a body line that reads '# Summary' or
        # '# Details' cannot forge a label (the same rule that keeps a
        # body line from forging a message header). An empty section
        # omits its label and body, the way the HTML card omits its
        # empty details fold. No links in text mode.
        res = read_results(series_dir, v)
        if res is not None:
            lines.append("results")
            if res[0]:
                lines.append("# Summary")
                lines.extend("  " + ln for ln in res[0].split("\n"))
            if res[1]:
                if res[0]:
                    lines.append("")
                lines.append("# Details")
                lines.extend("  " + ln for ln in res[1].split("\n"))
            lines.append("")
        # Number the thread pre-order, matching the HTML nesting order.
        nums = {}
        counter = [0]

        def assign(m, parent_id):
            counter[0] += 1
            nums[m["id"]] = (counter[0], parent_id and nums[parent_id][0])
            for c in m["children"]:
                assign(c, m["id"])

        for root in version_roots:
            assign(root, None)
        for root in version_roots:
            render_text_message(lines, root, nums, 0)
        sections.append("\n".join(lines))
    return "\n\n".join(sections) + ("\n" if sections else "")


def count_subtree(m):
    return sum(1 for _ in subtree(m)) - 1


def render_index(m, depth=0):
    """The thread as an indented list of one-liners, lore-style: every
    message in reply order, click to jump."""
    glyphs = "".join(f"<span class=\"g {TAG_CLASS.get(t,'t-q')}\" title=\"{esc(t)}\">{TAG_GLYPH.get(t,'·')}</span>" for t in m["tags"])
    # Like the tally rows, a patch row carries the full lore-style
    # subject (numbering as prefix), lore's index-style. Replies go
    # through the same normalizer: a 'Re: [PATCH ...]' subject comes back
    # padded under a single 'Re: '; anything else is verbatim.
    subj = patch_label(m)
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
        f"<h3 class=\"subj\">{esc(patch_label(m))}</h3>"
        f"<div class=\"body\">{body}{attachment_html}</div>"
        f"{fold}"
        f"</article>"
    )


def render_series(series_dir):
    name, msgs, roots = build(series_dir)
    sections = []
    covers = [r for r in roots if r["depth"] == 0 and r["subject"].startswith("[PATCH")]
    id_map = id_prefix_map(msgs)
    for cover in covers:
        v = cover["version"]
        version_roots = [r for r in roots if r["version"] == v]
        rows, personas = tally(cover)
        version_msgs = [m for root in version_roots for m in subtree(root)]
        n_replies = sum(1 for m in version_msgs if m["depth"] >= 1 and not is_patch(m))
        reviewer_entries = reviewer_rollup(version_msgs, cover["persona"], rows)
        # One matrix column per reviewer the box lists -- including
        # reviewers who commented without attaching a tag, whose column
        # is all dots ("reviewed, no verdict yet"). That way the header
        # count, the table's columns and the box describe the same set
        # in the same (alphabetical) order, so all three read off against
        # each other.
        pcols = sorted(set(personas) | {r["persona"] for r in reviewer_entries})
        entry_info = {r["persona"]: (r["harness"], r["model"]) for r in reviewer_entries}
        col_info = {p: personas.get(p, entry_info.get(p, ("", ""))) for p in pcols}
        thead = "".join(f"<th title=\"{esc(col_info[p][0])}/{esc(col_info[p][1])}\">{esc(p)}</th>" for p in pcols)
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
                # The full lore-style subject (numbering as prefix) is the
                # row text, capped to HTML_TALLY_LABEL_CAP like the text
                # tally caps its rows: in the table's auto layout the CSS
                # max-width on the <th> is only a suggestion, so an
                # uncapped subject would overflow .tally-wrap's scroller
                # at full width and make the title tooltip duplicate
                # fully visible text. The cut is marked with an
                # ellipsis and the full label stays on hover.
                label = patch_label(t)
                rowcell = (f'<th scope="row" title="{esc(label)}">'
                           f'<a href="#m-{esc(t["id"])}">{esc(fit_tally_label(label, HTML_TALLY_LABEL_CAP))}</a></th>')
            trows.append(f"<tr>{rowcell}{''.join(cells)}</tr>")
        n_patches = len(rows) - 1
        index = "".join(render_index(root) for root in version_roots)
        thread = "".join(render_message(root) for root in version_roots)
        n_messages = len(version_msgs)
        reviewers = "".join(render_reviewer(r, series_dir) for r in reviewer_entries)
        reviewers_block = ""
        if reviewer_entries:
            reviewers_block = (f'  <div class="reviewers">\n'
                               f'    <p class="eyebrow">reviewers</p>\n'
                               f'    {reviewers}\n  </div>')
        # The card is its own block; with no results file it is the empty
        # string, so the section is byte-identical to a render without the
        # card (the results CSS below is likewise emitted only when at
        # least one card is present).
        results_block = render_results_card(series_dir, v, id_map)
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
  {reviewers_block}{results_block}
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
  font-family:system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;line-height:1.55;}
.mono, header, .mid, .meta, .tag, .tally thead th, .eyebrow, .counts, time, .stat, .diff, .code, code, .trailer{
  font-family:"JetBrains Mono","SFMono-Regular",Menlo,Consolas,monospace;}
.page{max-width:76rem;margin:0 auto;padding:2.5rem 1.25rem 6rem}
.masthead{display:flex;flex-wrap:wrap;align-items:baseline;gap:.75rem 1.5rem;border-bottom:2px solid var(--ink);padding-bottom:1rem;margin-bottom:2.5rem}
.masthead h1{margin:0;font-size:1.75rem;font-weight:600;letter-spacing:-.01em;text-wrap:balance}
.masthead .sub{color:var(--muted);font-size:.9rem}
.eyebrow{margin:0;font-size:.75rem;letter-spacing:.14em;text-transform:uppercase;color:var(--muted)}
.series{margin-bottom:4rem}
.series-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:.5rem 1.25rem;margin-bottom:1rem}
.series-head h2{margin:0;font-size:1.5rem;font-weight:600}
.series-head .v{color:var(--accent);font-weight:500}
.counts{margin:0;display:flex;gap:1rem;font-size:.85rem;color:var(--muted)}
.tally-wrap{overflow-x:auto;margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.tally{border-collapse:collapse;font-size:.85rem;min-width:100%}
.tally caption{text-align:left;padding:.6rem .8rem;color:var(--muted);font-size:.78rem;border-bottom:1px solid var(--rule)}
.tally th,.tally td{padding:.4rem .6rem;border-bottom:1px solid var(--rule);text-align:left;white-space:nowrap}
.tally thead th{color:var(--muted);font-weight:500;font-size:.75rem;letter-spacing:.06em;text-transform:uppercase}
.tally tbody th{font-weight:500;max-width:34rem;overflow:hidden;text-overflow:ellipsis}
.tally tbody th a{color:inherit;text-decoration:none}
.tally tbody th a:hover{text-decoration:underline}
.tally td{text-align:center}
.cell{display:inline-block;min-width:1.6rem;padding:.05rem .3rem;border-radius:2px;text-decoration:none;font-weight:600}
.cell.none{color:var(--rule)}
.reviewers{margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.reviewers .eyebrow{padding:.6rem .8rem .35rem}
.reviewer{border-top:1px solid var(--rule)}
.reviewer>summary{cursor:pointer;display:flex;flex-wrap:wrap;align-items:baseline;gap:.15rem .5rem;padding:.55rem .8rem;font-size:.95rem}
.reviewer>summary .who{font-weight:600}
.reviewer>summary .slug{color:var(--accent);font-size:.8rem}
.reviewer-body{padding:0 .8rem .65rem;font-size:.9rem}
.rv-line{color:var(--muted);margin:0 0 .35rem;font-size:.85rem}
.persona-brief{margin:.5rem 0 0;padding:.6rem .8rem;background:var(--code-bg);font-size:.85rem;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere;border-radius:2px}
.t-rev{color:var(--rev);background:var(--rev-bg)}
.t-ack{color:var(--ack);background:var(--ack-bg)}
.t-test{color:var(--test);background:var(--test-bg)}
.t-chg{color:var(--chg);background:var(--chg-bg)}
.t-q{color:var(--q);background:var(--q-bg)}
.t-nak{color:var(--nak);background:var(--nak-bg)}
.thread{display:flex;flex-direction:column;gap:1rem}
.msg{background:var(--surface);border:1px solid var(--rule);padding:1rem 1.25rem 1.1rem;scroll-margin-top:1rem}
.msg header{display:flex;flex-wrap:wrap;align-items:center;gap:.4rem .7rem;font-size:.8rem;color:var(--muted);margin-bottom:.35rem}
.msg header .who{color:var(--ink);font-weight:600}
.msg header .meta{opacity:.85}
.msg header time{margin-left:auto}
.msg header .mid{color:var(--muted);text-decoration:none}
.msg header .mid:hover{color:var(--accent)}
.tag{padding:.05rem .4rem;border-radius:2px;font-size:.7rem;font-weight:600}
.subj{margin:0 0 .75rem;font-size:1.15rem;font-weight:600;line-height:1.3;text-wrap:balance}
.body{max-width:72ch;font-size:1rem;line-height:1.6}
.body p{margin:0 0 .8rem}
/* Markdown headings from a message body are content, not page chrome:
   they keep the message's own voice (prose family, normal case, inherited
   color). The uppercase-mono eyebrow treatment lives on .eyebrow, fold
   summaries, and tally headers only. */
.body h3{margin:1.2rem 0 .5rem;font-size:1.05rem;font-weight:650}
.body h4,.body h5,.body h6{margin:1.2rem 0 .5rem;font-size:.95rem;font-weight:650}
.body ul,.body ol{margin:0 0 .8rem;padding-left:1.4rem}
.body li{margin:.15rem 0}
.body code{font-size:.875em;background:var(--code-bg);padding:.1em .35em;border-radius:3px}
.body blockquote{margin:0 0 .9rem;padding:.4rem .9rem;background:var(--quote-bg);border-left:3px solid var(--quote-bar);color:var(--muted);font-size:.95rem}
.body blockquote p{margin:0 0 .4rem}
.body blockquote p:last-child{margin:0}
.attachments{margin-top:1rem;padding:.6rem .8rem;background:var(--code-bg);font-family:"JetBrains Mono","SFMono-Regular",Menlo,Consolas,monospace;font-size:.82rem}
.attachment-label{color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.attachments ul{margin:.35rem 0 0;padding-left:1.2rem}
.attachments a{color:var(--accent)}
.attachment-type,.attachment-missing{color:var(--muted)}
.attachment-preview{display:block;max-width:100%;max-height:24rem;margin-top:.5rem}
.code,.stat,.diff{margin:0 0 .9rem;padding:.7rem .9rem;background:var(--code-bg);font-size:.82rem;line-height:1.45;overflow-x:auto;border-radius:2px}
.diff{background:var(--diff-bg)}
.d-add{color:var(--add)} .d-del{color:var(--del)} .d-hunk{color:var(--hunk)} .d-file{font-weight:700} .d-meta{color:var(--muted)}
.trailer{font-size:.85rem;font-weight:600;padding:.15rem .5rem;display:inline-block;border-radius:2px;margin-right:.4rem}
.fold summary{cursor:pointer;font-family:"JetBrains Mono",monospace;font-size:.75rem;color:var(--accent);margin:0 0 .5rem}
.fold summary:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.index-fold{margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.index-fold summary{cursor:pointer;padding:.6rem .8rem;font-family:"JetBrains Mono",monospace;font-size:.75rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.index-wrap{overflow-x:auto;border-top:1px solid var(--rule)}
.tidx{list-style:none;margin:0;padding:.4rem 0;font-size:.85rem;line-height:1.6;min-width:max-content}
.tidx li{padding:.1rem .8rem .1rem calc(.8rem + var(--d) * 1.25rem);position:relative;white-space:nowrap}
.tidx li:hover{background:var(--code-bg)}
.tidx li a{color:inherit;text-decoration:none;display:inline-flex;align-items:center;gap:.55rem}
.tidx li a:hover .ix-subj{text-decoration:underline}
.tidx li[style*="--d:0"]{font-weight:600}
.tidx li:not([style*="--d:0"])::before{content:"";position:absolute;left:calc(.8rem + var(--d) * 1.25rem - .8rem);top:0;bottom:50%;width:.55rem;border-left:1px solid var(--quote-bar);border-bottom:1px solid var(--quote-bar)}
.tidx .ix-id{color:var(--muted)}
.tidx .ix-who{color:var(--accent);min-width:7.5rem}
.tidx .ix-patch .ix-who{color:var(--muted)}
.tidx .ix-subj{color:var(--ink)}
.tidx .g{display:inline-block;min-width:1.1rem;text-align:center;padding:0 .2rem;border-radius:2px;font-weight:700;font-size:.75rem}
.thread-fold{margin-top:1rem}
.thread-fold>summary{cursor:pointer;font-family:"JetBrains Mono",monospace;font-size:.75rem;color:var(--muted);letter-spacing:.04em;margin-bottom:.6rem}
.thread-fold>summary:hover{color:var(--accent)}
.replies{padding-left:1rem;border-left:2px solid var(--quote-bar);display:flex;flex-direction:column;gap:.9rem}
.msg.d0{border-color:var(--ink)}
.msg.patch{background:var(--bg)}
.msg.patch>header .who{color:var(--muted)}
.msg .msg{border-color:var(--rule)}
.p-core header .who{color:var(--accent)}
.foot{margin-top:4rem;padding-top:1rem;border-top:1px solid var(--rule);color:var(--muted);font-size:.85rem;max-width:68ch}
@media (max-width:640px){.page{padding:1.5rem .9rem 4rem}.msg{padding:.8rem .9rem}.replies{padding-left:.6rem}}
@media (prefers-reduced-motion: no-preference){html{scroll-behavior:smooth}}
"""
# Appended to CSS only when a results card is rendered, so a mailbox
# without results files renders byte-identically with and without this
# feature.
RESULTS_CSS = """
.results{margin:0 0 2rem;border:1px solid var(--rule);background:var(--surface)}
.results .eyebrow{padding:.6rem .8rem .35rem}
.results-summary{margin:0 0 .35rem;padding:0 .8rem;font-size:.95rem;white-space:pre-wrap;overflow-wrap:anywhere}
.results-fold{border-top:1px solid var(--rule)}
.results-fold summary{cursor:pointer;padding:.4rem .8rem;font-family:"JetBrains Mono",monospace;font-size:.75rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.results-details{margin:.4rem 0 .65rem;padding:0 .8rem;background:var(--code-bg);font-size:.78rem;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere}
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("series_dirs", nargs="+", metavar="SERIES_DIR",
                        help="lkml-mode series mailbox directory")
    parser.add_argument("--title", default="Review Threads",
                        help="document title and masthead (default: %(default)s)")
    parser.add_argument("-o", "--output", metavar="FILE",
                        help="write HTML to FILE instead of stdout")
    parser.add_argument("--text", action="store_true",
                        help="render the threads as plain text to stdout "
                             "(for agents; bodies indented under their headers, and "
                             "[PATCH] bodies keep the commit message and diffstat, "
                             "the diff cut at the first diff --git line)")
    args = parser.parse_args(argv)
    if args.text:
        # One flag, one backend: plain text to stdout, UTF-8, no ANSI.
        # -o is the HTML interface and is refused, not silently ignored;
        # --title is likewise ignored here.
        if args.output:
            parser.error("--text renders to stdout and cannot be combined with -o/--output")
        sys.stdout.reconfigure(encoding="utf-8")
        parts = [render_text_series(d).rstrip("\n") for d in args.series_dirs]
        # A blank line between series, like the one between version
        # sections within a series, so two series do not run together.
        sys.stdout.write("\n\n".join(parts) + ("\n" if parts else ""))
        return
    sections = []
    names = []
    for d in args.series_dirs:
        name, sec = render_series(d)
        names.append(name)
        sections.append(sec)
    # The page-level series card sits after the masthead, before the
    # first series section. Its id autolink map covers ALL versions'
    # messages in the series dir: build() reads every .msg file, so
    # the map an earlier version's card already uses is the one this
    # card needs (a union is only a union in a single series dir).
    series_cards = []
    for d in args.series_dirs:
        _name, all_msgs, _roots = build(d)
        card = render_series_card(d, id_prefix_map(all_msgs))
        if card:
            # Section strings lead with a newline (the masthead's own
            # trailing newline then ends its line); the card gets the
            # same lead so the page layout is unchanged.
            series_cards.append("\n" + card)
    # The card's rules ride on the card: without any results file the
    # document is byte-identical to a render without this feature.
    css = CSS + (RESULTS_CSS if any('class="results' in s for s in sections + series_cards) else "")
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    toc = " · ".join(f"<a href=\"#{esc(n)}-v1\">{esc(n)}</a>" for n in names)
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(args.title)}</title>
<style>{css}</style>
</head>
<body>
<div class="page">
  <div class="masthead">
    <h1>{esc(args.title)}</h1>
    <span class="sub mono">{toc}</span>
    <span class="sub mono">rendered {now}</span>
  </div>
  {''.join(series_cards + sections)}
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
