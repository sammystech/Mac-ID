#!/usr/bin/env python3
"""
One source for the Terms of Use: Terms.md -> web/terms.html and the copy bundled in the app.

Keeping a single source is the point: the page people read on macid.net and the text they agree to
inside the app must never disagree. Handles exactly the Markdown the terms use: # and ## headings,
> callouts, - lists, paragraphs, **bold**, and the support address.
"""
import html, re, shutil, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]                       # ~/mac-id
SRC = HERE / "Terms.md"
WEB = ROOT / "web" / "terms.html"
APP = ROOT / "src" / "glance" / "Resources" / "Terms.md"


def inline(text):
    t = html.escape(text)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    return t.replace("support@macid.net", '<a href="mailto:support@macid.net">support@macid.net</a>')


def to_html(md):
    out, para, items = [], [], []
    def flush():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>"); para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>"); items.clear()
    for line in md.splitlines():
        s = line.strip()
        if not s:
            flush(); continue
        if s.startswith("# "):
            flush(); out.append(f"<h1>{inline(s[2:])}</h1>")
        elif s.startswith("## "):
            flush()
            slug = re.sub(r"[^a-z0-9]+", "-", s[3:].lower()).strip("-")
            out.append(f'<h2 id="{slug}">{inline(s[3:])}</h2>')
        elif s.startswith("> "):
            flush(); out.append(f'<aside class="summary">{inline(s[2:])}</aside>')
        elif s.startswith("- "):
            if para: flush()
            items.append(s[2:])
        else:
            if items: flush()
            para.append(s)
    flush()
    return "\n".join(out)


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Terms of Use · Mac ID</title>
<meta name="description" content="The terms for downloading, buying and using Mac ID.">
<style>
:root {{ --bg:#0B0A12; --ink:#F4F3FA; --dim:#A8A4C0; --faint:#726E8C; --line:rgba(255,255,255,.10); --accent:#8E72FF; }}
@media (prefers-color-scheme: light) {{ :root {{ --bg:#FBFAFE; --ink:#18152B; --dim:#4C4866; --faint:#7A7694; --line:rgba(24,21,43,.12); --accent:#5B3BE8; }} }}
* {{ box-sizing:border-box; }}
html {{ -webkit-text-size-adjust:100%; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:16px/1.65 Inter,-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif; }}
main {{ max-width:720px; margin:0 auto; padding:56px 20px 96px; }}
.back {{ display:inline-block; margin-bottom:36px; color:var(--dim); text-decoration:none; font-size:14px; }}
.back:hover {{ color:var(--ink); }}
h1 {{ font-size:clamp(30px,5vw,40px); line-height:1.15; letter-spacing:-.02em; margin:0 0 6px; }}
h1 + p {{ color:var(--faint); font-size:14px; margin:0 0 32px; }}
h2 {{ font-size:19px; letter-spacing:-.01em; margin:44px 0 10px; padding-top:22px; border-top:1px solid var(--line); }}
p, li {{ color:var(--dim); }}
strong {{ color:var(--ink); font-weight:600; }}
ul {{ padding-left:20px; }} li {{ margin:8px 0; }}
a {{ color:var(--accent); }}
.summary {{ margin:0 0 8px; padding:18px 20px; border:1px solid var(--line); border-left:3px solid var(--accent); border-radius:10px; color:var(--dim); }}
footer {{ margin-top:56px; color:var(--faint); font-size:13px; }}
</style>
</head>
<body>
<main>
<a class="back" href="/">&larr; Mac ID</a>
{body}
<footer>Mac ID · <a href="mailto:support@macid.net">support@macid.net</a></footer>
</main>
</body>
</html>
"""

if __name__ == "__main__":
    md = SRC.read_text()
    WEB.write_text(PAGE.format(body=to_html(md)))
    shutil.copyfile(SRC, APP)
    version = re.search(r"Version (\d{4}-\d{2}-\d{2})", md).group(1)
    print(f"terms {version}: wrote {WEB.relative_to(ROOT)} and {APP.relative_to(ROOT)}")
