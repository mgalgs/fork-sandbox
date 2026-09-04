#!/usr/bin/env python3
"""lkml-render.py — render one or more lkml-mode series mailboxes as a
single self-contained HTML page, or as plain text for agents.

Usage: lkml-render.py <series-dir> [<series-dir> ...] > out.html
       lkml-render.py --text <series-dir> [<series-dir> ...] > out.txt

The default HTML render is the human view: a sticky state rail (the
version list with the current version marked aria-current, a
reviewer-to-verdict matrix, a per-patch verdict matrix, and an
open-thread counter block) beside a main column that carries, in
order, a blocking banner (a standing NAK, or every open thread sitting
on one patch), the auto-summary card when a per-version results file
exists, and the thread itself. The thread is an expandable trace: every
message collapses to one scannable line (persona monogram, name, short
id, verdict chip, subject) and opens in place. Depth is an indent plus
a hairline rail. Patch bodies show the stat line with the diff folded.
Verdicts are chips that encode strength in form as well as hue: a
solid green Reviewed-by, the same hue hollow for the weaker Acked-by,
amber for Changes-requested, hollow amber for a Question, and a solid
red NAK. The blue accent is structural chrome only, never a verdict.
An unrecorded model is stamped 'model unknown' in the warning colour on
purpose -- surfacing a real defect, not hiding it.

--text is the agent view and a stable interface consumed by
lkml-round.sh and lkml-summarize.sh: the same thread selection and
ordering as plain text on stdout, with message bodies indented under
their headers (so a body cannot forge a message header) and [PATCH]
message bodies cut at their first diff --git line, so the commit
message and diffstat stay and the diff goes (it lives in the series
branch). The HTML path may be redesigned freely; --text must not
change out from under the panel scripts.

A series dir is $LKML_MAILBOX_ROOT/<series> (it holds cur/*.msg). Reads
only; never runs git.

When a series dir holds results-v<N>.md (the per-version results file,
written by the summarizer; a results-v<N>.json may sit next to it and
is ignored except for the card's presence when the .md is absent), the
HTML render adds an auto-summary card above the thread: the "# Summary"
section sits in the visible card head, the "# Details" section inside a
fold, and 7-hex message-id tokens that match a message in the mailbox
link to that message. --text prints the same sections as a bare
'results' block (no links); an empty section is omitted in both
backends. Without any results file there is no card at all.

When a series dir holds results-series.md (the whole-series narrative,
written by the summarizer's --series mode), the HTML render adds a
page-level card directly above the series' own shell. Its id autolink
map covers ALL versions' messages in the series dir. --text prints it
as a 'series-summary' block at the very top, before the first version
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
# Verdict strength order, strongest first: a NAK outranks a
# Changes-requested, which outranks a Question, which outranks a sign-off.
TAG_PRIORITY = ["NAK", "Changes-requested", "Question", "Acked-by", "Tested-by", "Reviewed-by"]
# Tags that close a thread (the sign-offs). A thread whose subtree
# carries none of these is still open.
POSITIVE_TAGS = {"Reviewed-by", "Acked-by", "Tested-by"}
# Chip class and label per tag. Strength is encoded in form as well as
# hue: Reviewed-by is solid green, Acked-by the same hue but hollow,
# Changes-requested amber, Question hollow amber, NAK solid red.
CHIP_CLASS = {
    "Reviewed-by": "reviewed", "Acked-by": "acked", "Tested-by": "tested",
    "Changes-requested": "changes", "Question": "question", "NAK": "nak",
}
CHIP_LABEL = {
    "Reviewed-by": "reviewed-by", "Acked-by": "acked-by", "Tested-by": "tested-by",
    "Changes-requested": "changes", "Question": "question", "NAK": "nak",
}
# A small hand-picked palette for persona monograms: a stable hash of the
# persona name picks one, so any roster renders, the same persona gets
# the same colour twice in one page, and the colour is stable between
# runs for the same persona (djb2 over the name, not the per-process
# randomized hash()).
MONOGRAM_PALETTE = [
    "#6d3fb8", "#1f7a5f", "#b4560e", "#2b3a42",
    "#b32218", "#2f6fec", "#7a5c10", "#5c3d7a",
]


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


def strongest_tag(tags):
    """The strongest tag in a set, per TAG_PRIORITY, or None."""
    for t in TAG_PRIORITY:
        if t in tags:
            return t
    return None


def chip_html(tag):
    """The verdict chip for one tag; '' when the tag maps to no chip.
    A message with no verdict renders no chip at all, never an empty
    one."""
    cls = CHIP_CLASS.get(tag)
    if not cls:
        return ""
    return f'<span class="chip {cls}">{CHIP_LABEL[tag]}</span>'


def mono_color(persona):
    """A stable palette index per persona name (djb2; not hash(), which
    is salted per process)."""
    if not persona:
        return 0
    h = 5381
    for ch in persona:
        h = ((h * 33) + ord(ch)) & 0xFFFFFFFF
    return h % len(MONOGRAM_PALETTE)


def monogram(persona):
    """The monogram letters for a persona: the first letter of each
    word, two wide ('core-team' -> 'CT'), or the first two characters
    of one long word; 'AI' for an un-stamped message."""
    if not persona:
        return "AI"
    words = [w for w in re.split(r"[-_ ]+", persona) if w]
    letters = "".join(w[0] for w in words)[:2] or persona[:2]
    return letters.upper()


def badge(persona):
    cls = "" if persona else " mono-none"
    return f'<span class="mono-badge{cls} p-color-{mono_color(persona)}">{esc(monogram(persona))}</span>'


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
    """The page-level series summary card, placed directly above the
    series' own section (right after the masthead when a single dir
    is rendered): the same treatment
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
    # id_map is returned, not recomputed by the caller: it covers ALL
    # versions' messages in the series dir (build() read every .msg
    # file), which is exactly the map the series card needs, and a
    # second build() would re-parse the whole mailbox for it.
    return name, "\n".join(sections), id_map


CSS = """
:root {
  --ground:      #f6f8f9;
  --surface:     #ffffff;
  --surface-2:   #eef1f3;
  --ink:         #0f1417;
  --ink-2:       #47555c;
  --ink-3:       #71828b;
  --rule:        #d9e0e4;
  --rule-soft:   #e8edef;

  --accent:      #2f6fec;
  --accent-soft: #e4ecfd;
  --ok:          #1f7a5f;
  --ok-soft:     #ddf1e9;
  --warn:        #b4560e;
  --warn-soft:   #fbeade;
  --crit:        #b32218;
  --crit-soft:   #fbe3e0;

  --add:         #1f6e3d;
  --del:         #a8261f;
  --hunk:        #5a6c9e;

  --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
  --ui:   "Archivo", ui-sans-serif, system-ui, sans-serif;
  --read: "Source Serif 4", Georgia, "Times New Roman", serif;

  --r: 10px;
  --shadow: 0 1px 2px rgba(15,20,23,.05), 0 8px 24px -16px rgba(15,20,23,.18);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground:      #0b1013;
    --surface:     #121a1e;
    --surface-2:   #182328;
    --ink:         #e7eef1;
    --ink-2:       #a2b2ba;
    --ink-3:       #778890;
    --rule:        #24333a;
    --rule-soft:   #1b262b;

    --accent:      #7ea8ff;
    --accent-soft: #16273f;
    --ok:          #63c9a4;
    --ok-soft:     #102a22;
    --warn:        #e79a5c;
    --warn-soft:   #2c1d11;
    --crit:        #f08b80;
    --crit-soft:   #2f1512;

    --add:         #7bd88f;
    --del:         #f08a84;
    --hunk:        #8fa0d6;

    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.7);
  }
}

:root[data-theme="dark"] {
    --ground:      #0b1013;
    --surface:     #121a1e;
    --surface-2:   #182328;
    --ink:         #e7eef1;
    --ink-2:       #a2b2ba;
    --ink-3:       #778890;
    --rule:        #24333a;
    --rule-soft:   #1b262b;

    --accent:      #7ea8ff;
    --accent-soft: #16273f;
    --ok:          #63c9a4;
    --ok-soft:     #102a22;
    --warn:        #e79a5c;
    --warn-soft:   #2c1d11;
    --crit:        #f08b80;
    --crit-soft:   #2f1512;

    --add:         #7bd88f;
    --del:         #f08a84;
    --hunk:        #8fa0d6;

    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.7);
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--ground);
  color: var(--ink);
  font-family: var(--ui);
  font-size: 15px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }

:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 4px; }

.eyebrow {
  font-size: 10.5px; font-weight: 600; letter-spacing: .1em;
  text-transform: uppercase; color: var(--ink-3); margin: 0;
}

.masthead { border-bottom: 1px solid var(--rule); background: var(--surface); }
.masthead-in {
  max-width: 1240px; margin: 0 auto; padding: 20px 24px 18px;
  display: flex; flex-wrap: wrap; gap: 16px 28px; align-items: flex-end;
}
.masthead h1 {
  font-size: 21px; font-weight: 700; letter-spacing: -.015em;
  margin: 4px 0 0; text-wrap: balance;
}
.masthead .sub { font-family: var(--mono); font-size: 12px; color: var(--ink-2); margin: 6px 0 0; }
.masthead .grow { flex: 1 1 260px; }

.facts { display: flex; gap: 22px; flex-wrap: wrap; }
.fact { display: flex; flex-direction: column; gap: 3px; }
.fact b { font-family: var(--mono); font-size: 13px; font-weight: 500; font-variant-numeric: tabular-nums; }

.series { scroll-margin-top: 1rem; }

.shell {
  max-width: 1240px; margin: 0 auto; padding: 22px 24px 40px;
  display: grid; grid-template-columns: 286px minmax(0, 1fr); gap: 26px; align-items: start;
}
@media (max-width: 900px) {
  .shell { grid-template-columns: minmax(0, 1fr); }
  .rail { position: static !important; }
}

.rail { position: sticky; top: 22px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }

.panel {
  background: var(--surface); border: 1px solid var(--rule);
  border-radius: var(--r); padding: 14px 15px; box-shadow: var(--shadow);
}
.panel > .eyebrow { margin-bottom: 11px; }

.versions { display: flex; flex-direction: column; gap: 2px; }
.vrow {
  display: grid; grid-template-columns: 30px minmax(0,1fr) auto;
  align-items: center; gap: 9px; padding: 7px 8px; border-radius: 7px;
  border: 1px solid transparent; font-size: 13px; color: var(--ink-2); text-decoration: none;
}
.vrow:hover { background: var(--surface-2); color: var(--ink); }
.vrow .vn { font-family: var(--mono); font-weight: 700; font-size: 12px; color: var(--ink-3); }
.vrow .vmeta { font-size: 11.5px; color: var(--ink-3); font-variant-numeric: tabular-nums; }
.vrow[aria-current="true"] {
  background: var(--accent-soft);
  border-color: color-mix(in srgb, var(--accent) 34%, transparent);
  color: var(--ink);
}
.vrow[aria-current="true"] .vn { color: var(--accent); }

.matrix { display: flex; flex-direction: column; gap: 1px; }
.mrow {
  display: grid; grid-template-columns: 22px minmax(0,1fr) auto;
  align-items: center; gap: 9px; padding: 6px 2px;
}
.mrow + .mrow { border-top: 1px solid var(--rule-soft); }
.who { font-size: 13px; font-weight: 500; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
.who small {
  display: block; font-size: 10.5px; font-weight: 400;
  color: var(--ink-3); letter-spacing: .01em;
}

.mono-badge {
  width: 22px; height: 22px; border-radius: 6px; display: grid; place-items: center;
  font-family: var(--mono); font-size: 10.5px; font-weight: 700;
  color: #fff; background: var(--ink-2); flex: none;
}
/* Stable persona monogram palette: one slot per persona name, chosen by
   a hash of the name (lkml-render.py's mono_color), so any roster
   renders and the colour is stable across a page and between runs. */
.p-color-0 { background: #6d3fb8; }
.p-color-1 { background: #1f7a5f; }
.p-color-2 { background: #b4560e; }
.p-color-3 { background: #2b3a42; }
.p-color-4 { background: #b32218; }
.p-color-5 { background: #2f6fec; }
.p-color-6 { background: #7a5c10; }
.p-color-7 { background: #5c3d7a; }
.mono-none { background: var(--ink-2); }

.chip {
  font-family: var(--ui); font-size: 10.5px; font-weight: 600; letter-spacing: .04em;
  text-transform: uppercase; padding: 3px 7px; border-radius: 999px;
  border: 1px solid transparent; white-space: nowrap; flex: none;
}
/* Strength is encoded in form as well as hue: Reviewed-by is solid
   green, Acked-by the same hue hollow (it is genuinely the weaker
   claim), Changes-requested amber, Question hollow amber, NAK solid
   red. The blue accent is chrome only, never a verdict. */
.chip.reviewed { background: var(--ok); color: #fff; border-color: var(--ok); }
.chip.acked    { background: var(--ok-soft); color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, transparent); }
.chip.changes  { background: var(--warn-soft); color: var(--warn); border-color: color-mix(in srgb, var(--warn) 40%, transparent); }
.chip.question { background: transparent; color: var(--warn); border-color: color-mix(in srgb, var(--warn) 40%, transparent); }
.chip.nak      { background: var(--crit); color: #fff; border-color: var(--crit); }
.chip.tested   { background: var(--surface-2); color: var(--ink-2); border-color: var(--rule); }
.chip.pending  { background: var(--surface-2); color: var(--ink-3); border-color: var(--rule); }

.counts { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.count { border: 1px solid var(--rule); border-radius: 8px; padding: 9px 10px; background: var(--surface); }
.count b {
  display: block; font-family: var(--mono); font-size: 19px; font-weight: 700;
  line-height: 1.1; font-variant-numeric: tabular-nums;
}
.count.is-warn { border-color: color-mix(in srgb, var(--warn) 40%, transparent); background: var(--warn-soft); }
.count.is-warn b { color: var(--warn); }
.count.is-ok { border-color: color-mix(in srgb, var(--ok) 40%, transparent); background: var(--ok-soft); }
.count.is-ok b { color: var(--ok); }
.count span { font-size: 11px; color: var(--ink-2); }

.main { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.section { display: flex; flex-direction: column; gap: 7px; min-width: 0; scroll-margin-top: 1rem; }

.banner {
  display: flex; gap: 12px; align-items: flex-start; border-radius: var(--r);
  padding: 13px 15px; border: 1px solid color-mix(in srgb, var(--warn) 42%, transparent);
  background: var(--warn-soft);
}
.banner .bar { width: 3px; align-self: stretch; border-radius: 2px; background: var(--warn); flex: none; }
.banner h2 { font-size: 13.5px; font-weight: 700; margin: 0 0 3px; color: var(--warn); letter-spacing: -.005em; }
.banner p { margin: 0; font-size: 13px; color: var(--ink-2); }
.banner.crit { border-color: color-mix(in srgb, var(--crit) 42%, transparent); background: var(--crit-soft); }
.banner.crit .bar { background: var(--crit); }
.banner.crit h2 { color: var(--crit); }

.summary { padding: 0; overflow: hidden; }
.summary-head {
  padding: 14px 17px 12px; border-bottom: 1px solid var(--rule-soft);
  display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;
}
.summary-head h2 { font-size: 15px; font-weight: 700; margin: 0; letter-spacing: -.01em; }
.summary-body {
  padding: 15px 17px; font-family: var(--read); font-size: 16.5px;
  line-height: 1.6; color: var(--ink); max-width: 68ch;
}
.summary-body p { margin: 0 0 .8em; }
.summary-body p:last-child { margin-bottom: 0; }
.summary-body strong { font-weight: 600; }
.results-fold { border-top: 1px solid var(--rule-soft); }
.results-fold summary {
  cursor: pointer; padding: 9px 17px; list-style: none;
  font-family: var(--mono); font-size: 11px; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3);
}
.results-fold summary:hover { background: var(--surface-2); }
.results-fold summary::-webkit-details-marker { display: none; }
.results-details {
  margin: 0 17px 15px; padding: 12px 14px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 11.5px; line-height: 1.5;
  white-space: pre-wrap; overflow-wrap: anywhere; color: var(--ink-2);
}

.trace { display: flex; flex-direction: column; gap: 7px; }
.trace-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 3px; }
.trace-head h2 { font-size: 15px; font-weight: 700; margin: 0; letter-spacing: -.01em; }

.msg {
  position: relative; background: var(--surface); border: 1px solid var(--rule);
  border-radius: 9px; box-shadow: var(--shadow);
}
.msg[data-depth="1"] { margin-left: 19px; }
.msg[data-depth="2"] { margin-left: 38px; }
.msg[data-depth="1"]::before, .msg[data-depth="2"]::before {
  content: ""; position: absolute; left: -10px; top: 15px; bottom: 15px;
  width: 1px; background: var(--rule);
}

.msg > summary {
  cursor: pointer; list-style: none; display: grid;
  grid-template-columns: 22px minmax(0, 1fr) auto;
  align-items: center; gap: 10px; padding: 10px 13px; border-radius: 9px;
}
.msg > summary::-webkit-details-marker { display: none; }
.msg > summary:hover { background: var(--surface-2); }
.msg[open] > summary { border-bottom: 1px solid var(--rule-soft); border-radius: 9px 9px 0 0; }

.line { min-width: 0; }
.line .from { font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 7px; flex-wrap: wrap; }
.line .from .id { font-family: var(--mono); font-size: 10.5px; font-weight: 400; color: var(--ink-3); }
.line .gist { font-size: 12.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.msg[open] .line .gist { white-space: normal; overflow: visible; }

.meta { display: flex; align-items: center; gap: 8px; }
.model {
  font-family: var(--mono); font-size: 10px; color: var(--ink-3);
  white-space: nowrap; border: 1px solid var(--rule); border-radius: 4px; padding: 2px 5px;
}
.model.unknown { color: var(--crit); border-color: color-mix(in srgb, var(--crit) 40%, transparent); }
@media (max-width: 700px) { .model { display: none; } }

.body { padding: 14px 15px 16px; font-family: var(--read); font-size: 16px; line-height: 1.62; max-width: 68ch; }
.body p { margin: 0 0 .75em; }
.body p:last-child { margin-bottom: 0; }
/* Markdown headings from a message body are content, not page chrome:
   they keep the message's own voice (prose family, normal case,
   inherited color). The uppercase-mono eyebrow treatment lives on
   .eyebrow, fold summaries, and panel heads only. */
.body h3 { margin: 1.2rem 0 .5rem; font-size: 1.05rem; font-weight: 600; }
.body h4,.body h5,.body h6 { margin: 1.2rem 0 .5rem; font-size: .95rem; font-weight: 600; }
.body ul,.body ol { margin: 0 0 .8rem; padding-left: 1.4rem; }
.body li { margin: .15rem 0; }
.body code,.body code.inline {
  font-family: var(--mono); font-size: .86em; background: var(--surface-2);
  border: 1px solid var(--rule-soft); border-radius: 4px; padding: .08em .32em;
}
.body blockquote {
  margin: 0 0 .8em; padding-left: 12px; border-left: 2px solid var(--rule);
  color: var(--ink-3); font-style: italic;
}
.body blockquote p { margin: 0 0 .5em; }
.body blockquote p:last-child { margin: 0; }
.body .placeholder { font-family: var(--ui); font-size: 12.5px; color: var(--ink-3); }
.body pre.code {
  margin: 0 0 .9rem; padding: 12px 14px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 12px; line-height: 1.5;
  overflow-x: auto;
}
pre.stat {
  margin: 0; font-family: var(--mono); font-size: 11.5px; line-height: 1.62;
  overflow-x: auto; padding: 12px 15px; background: var(--surface-2);
  color: var(--ink-2); border-radius: 9px 9px 0 0;
}
.fold summary {
  cursor: pointer; list-style: none; padding: 8px 15px;
  font-family: var(--mono); font-size: 11px; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3); background: var(--surface-2);
  border-bottom: 1px solid var(--rule-soft);
}
.fold summary::-webkit-details-marker { display: none; }
.fold summary:hover { color: var(--ink); }
.diff {
  margin: 0; padding: 12px 15px; font-family: var(--mono); font-size: 11.5px; line-height: 1.62;
  overflow-x: auto; background: var(--surface-2); color: var(--ink-2);
}
.d-add{color:var(--add)} .d-del{color:var(--del)} .d-hunk{color:var(--hunk)}
.d-file{font-weight:700;color:var(--ink)} .d-meta{color:var(--ink-3)}

/* Trailers in a body read as verdict chips in the same semantic
   colour; the blue accent never colours a verdict. */
.trailer {
  font-family: var(--ui); font-size: 11.5px; font-weight: 600; letter-spacing: .04em;
  text-transform: uppercase; padding: 2px 8px; border-radius: 999px;
  display: inline-block; margin: 0 0 .5em .4rem; border: 1px solid transparent;
}
.t-rev{background:var(--ok);color:#fff;border-color:var(--ok)}
.t-ack{background:var(--ok-soft);color:var(--ok);border-color:color-mix(in srgb, var(--ok) 40%, transparent)}
.t-test{background:var(--surface-2);color:var(--ink-2);border-color:var(--rule)}
.t-chg{background:var(--warn-soft);color:var(--warn);border-color:color-mix(in srgb, var(--warn) 40%, transparent)}
.t-q{background:transparent;color:var(--warn);border-color:color-mix(in srgb, var(--warn) 40%, transparent)}
.t-nak{background:var(--crit);color:#fff;border-color:var(--crit)}

.attachments {
  margin-top: 1rem; padding: 9px 11px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 11.5px;
}
.attachment-label {
  display: block; color: var(--ink-3); text-transform: uppercase;
  letter-spacing: .08em; font-size: 10.5px;
}
.attachments ul { margin: .4rem 0 0; padding-left: 1.1rem; }
.attachments a { color: var(--accent); }
.attachment-type, .attachment-missing { color: var(--ink-3); }
.attachment-preview { display: block; max-width: 100%; max-height: 24rem; margin-top: .5rem; }

footer.foot {
  max-width: 1240px; margin: 0 auto; padding: 24px 24px 40px;
  color: var(--ink-3); font-size: 11.5px; font-family: var(--mono);
}
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
        name, sec, id_map = render_series(d)
        names.append(name)
        # The page-level series card sits directly above THIS dir's own
        # section, as before; its render changes with the summary card
        # in a later step, its placement does not.
        card = render_series_card(d, id_map)
        if card:
            sec = "\n" + card + sec
        sections.append(sec)
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    if len(sections) == 1:
        head = ""
    else:
        toc = " \u00b7 ".join(f'<a href="#{esc(n)}">{esc(n)}</a>' for n in names)
        head = ('<div class="masthead">\n  <div class="masthead-in">\n'
                f'    <div class="grow"><h1>{esc(args.title)}</h1>'
                f'<p class="sub">{toc}</p></div>\n'
                f'    <div class="facts"><div class="fact">'
                f'<span class="eyebrow">rendered</span><b>{now}</b></div></div>\n'
                '  </div>\n</div>\n')
    footers = "  \u00b7  ".join(esc(n) for n in names)
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(args.title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;1,8..60,400&family=JetBrains+Mono:wght@400;500;700&display=swap">
<style>{CSS}</style>
</head>
<body>
{head}{''.join(sections)}
<footer class="foot">{esc(footers)} \u00b7 rendered {now}</footer>
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
