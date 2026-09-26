#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render the status file into the published site: one badge SVG per cell
# plus an index.html carrying the grid.
#
# The page is what makes the badges clickable in a useful way. GitHub
# publishes one badge per workflow *file*, and there is no stable URL for
# "the latest job of this matrix cell" -- so a per-cell link has to come
# from somewhere we control. Each cell here anchors as #<slug> and links
# to the exact job log of the run that produced its current state, the
# same shape as con/git-annex's con.github.io/git-annex-ci-reports.
#
# It also carries what a badge cannot: which run, how long ago, which
# known issues (evals/known-issues.yaml) a red cell's failures fall
# under, and which failures are new.
#
# usage:
#   bin/ci/render-report.py <status.json> <output-dir>

from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import known_issues

HERE = Path(__file__).resolve().parent

# Badge text per cell state. A cell without a state (no verdict.json:
# cancelled, or last run before verdicts existed) falls back to its job
# conclusion. render-badge.sh maps the same keys to colours.
BADGE_TEXT = {
    "passing": "passing",
    "failing-known": "failing (known)",
    "failing-new": "{new} new failing",
    "incomplete": "incomplete",
    "success": "passing",
    "failure": "failing",
    "cancelled": "cancelled",
    "skipped": "skipped",
}
MAX_NOTE_IDS = 3        # new-failure ids shown under a badge

CSS = """
:root { color-scheme: light dark;
  --fg:#1f2328; --bg:#fff; --muted:#59636e; --line:#d1d9e0; --accent:#0969da; --hl:#fff8c5; }
@media (prefers-color-scheme: dark) { :root {
  --fg:#f0f6fc; --bg:#0d1117; --muted:#9198a1; --line:#3d444d; --accent:#4493f8; --hl:#2d2a1f; } }
* { box-sizing:border-box }
body { margin:0; padding:2rem 1rem; background:var(--bg); color:var(--fg);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
main { max-width:60rem; margin:0 auto }
h1 { font-size:1.5rem; margin:0 0 .25rem }
.sub { color:var(--muted); margin:0 0 1.5rem }
.wrap { overflow-x:auto; border:1px solid var(--line); border-radius:6px }
table { border-collapse:collapse; width:100%; min-width:44rem }
th,td { padding:.6rem .75rem; text-align:left; border-bottom:1px solid var(--line); vertical-align:top }
th { font-size:.8rem; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); font-weight:600 }
tr:last-child td { border-bottom:0 }
td.cell:target { background:var(--hl); }
a { color:var(--accent); text-decoration:none }
a:hover { text-decoration:underline }
.meta { display:block; font-size:.75rem; color:var(--muted); margin-top:.3rem }
.why { display:block; font-size:.75rem; color:var(--muted); margin-top:.15rem }
.why.new { color:#cf222e; font-weight:600 }
.why.fixed { color:var(--accent) }
.issue { margin:1.5rem 0; padding-top:.5rem; border-top:1px solid var(--line) }
.issue:target { background:var(--hl) }
.issue h3 { font-size:1rem; margin:.2rem 0 }
.tag { display:inline-block; font-size:.7rem; padding:0 .4rem; border:1px solid var(--line);
  border-radius:1rem; color:var(--muted); margin-right:.25rem }
code { font-size:.85em }
footer { margin-top:2rem; padding-top:1rem; border-top:1px solid var(--line);
  color:var(--muted); font-size:.85rem }
"""


def render_badge(status: str, title: str, out: Path, text: str = "") -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [str(HERE / "render-badge.sh"), status, title] + ([text] if text else []),
        capture_output=True, text=True, check=True,
    )
    out.write_text(r.stdout)


def code(text: str) -> str:
    """Escape, then render Markdown `code` spans -- all notes ever use."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text))


def cell_notes(c: dict, st: str, fixed: list[str]) -> str:
    """The lines under a badge: which issues, what is new, what is fixed."""
    out = []
    if st == "incomplete" and c.get("reason"):
        out.append(f'<span class="why new">incomplete: {html.escape(c["reason"])}</span>')
    new = c.get("new_failures", [])
    if new:
        more = c.get("counts", {}).get("new_fail", len(new)) - len(new[:MAX_NOTE_IDS])
        out.append('<span class="why new">new: ' + ", ".join(
            f"<code>{html.escape(t)}</code>" for t in new[:MAX_NOTE_IDS])
            + (f" and {more} more" if more > 0 else "") + "</span>")
    for iid, e in c.get("issues", {}).items():
        if e.get("status") == "reproduced":
            n = e.get("fail", 0)
            out.append(f'<span class=why>known: <a href="#issue-{iid}">{iid}</a>'
                       f' ({n} test{"s" if n != 1 else ""})</span>')
    for iid in fixed:
        out.append(f'<span class="why fixed">not reproduced: <a href="#issue-{iid}">{iid}</a> '
                   f'&mdash; fixed?</span>')
    return "".join(out)


def render_issue(i: known_issues.Issue, cells: dict, repo: str) -> str:
    def href(link: str) -> str:
        return link if "://" in link else f"https://github.com/{repo}/blob/master/{link}"

    where = []
    for slug, c in cells.items():
        e = c.get("issues", {}).get(i.id)
        if e is not None:
            where.append(f'<a href="#{slug}">{html.escape(slug)}</a>: '
                         f'{html.escape(e.get("status", "?"))}'
                         + (f' ({e["fail"]} failed)' if e.get("fail") else ""))
    tags = "".join(f"<span class=tag>{html.escape(t)}</span>" for t in i.tags)
    scope = "whole cell" if i.coarse else f"{len(i.patterns)} tests named"
    links = ", ".join(f'<a href="{html.escape(href(link))}">{html.escape(link)}</a>'
                      for link in i.links)
    notes = f"<p>{code(i.notes.strip())}</p>" if i.notes else ""
    return (f'<div class=issue id="issue-{i.id}"><h3><code>{i.id}</code>: '
            f'{html.escape(i.title)}</h3>{tags}'
            f'<span class=meta>{scope}</span>'
            f'<span class=meta>{"; ".join(where) or "no cell has reported on it yet"}</span>'
            f'{notes}<span class=meta>see {links}</span></div>\n')


def ago(iso: str) -> str:
    if not iso:
        return "never"
    try:
        then = datetime.fromisoformat(iso)
    except ValueError:
        return iso
    secs = (datetime.now(timezone.utc) - then).total_seconds()
    for div, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if secs >= div:
            return f"{int(secs // div)}{unit} ago"
    return "just now"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("status_file", type=Path)
    ap.add_argument("outdir", type=Path)
    args = ap.parse_args()

    status = json.loads(args.status_file.read_text())
    cells = status["cells"]

    # Matrix order, so the page reads like the README grid.
    m = known_issues.load_matrix()
    backends = [(known_issues.backend_slug(b["backend"], b["version"]), b["label"])
                for b in m["backends"]]
    targets = [(t["name"], t["label"]) for t in m["targets"]]
    issues = known_issues.parse(known_issues.load())

    def state(c: dict) -> str:
        return c.get("state") or c.get("conclusion", "unknown")

    npass = sum(1 for c in cells.values() if state(c) in ("passing", "success"))
    # Unexpected: anything not passing or fully covered by known issues.
    nnew = sum(1 for c in cells.values()
               if state(c) not in known_issues.OK_STATES + ("success",))
    total = len(cells)
    overall = "passing" if npass == total else ("failing-new" if nnew else "failing-known")
    render_badge(overall, f"eval-under: {npass}/{total} cells passing, {nnew} unexpected",
                 args.outdir / "badges" / "overall.svg",
                 f"{npass}/{total} passing" + (f", {nnew} unexpected" if nnew else ""))

    rows = []
    for bslug, blabel in backends:
        tds = [f"<th scope=row>{html.escape(blabel)}</th>"]
        for tname, tlabel in targets:
            slug = f"{bslug}-{tname}"
            c = cells.get(slug, {"conclusion": "unknown"})
            st = state(c)
            label = c.get("label", slug)
            cissues = c.get("issues", {})
            fixed = [i for i, e in cissues.items() if e.get("status") == "not-reproduced"]
            text = BADGE_TEXT.get(st, "unknown").format(
                new=c.get("counts", {}).get("new_fail", "?"))
            if fixed:
                text += f" +{len(fixed)} fixed?"
            render_badge(st, label, args.outdir / "badges" / f"{slug}.svg", text)

            img = (f'<img src="badges/{slug}.svg" alt="{html.escape(label)}: {html.escape(text)}" '
                   f'height="20">')
            url = c.get("job_url", "")
            body = f'<a href="{html.escape(url)}">{img}</a>' if url else img

            meta = ""
            if c.get("run_number"):
                attempt = c.get("run_attempt", 1)
                run = f"#{c['run_number']}" + (f".{attempt}" if attempt > 1 else "")
                meta = (f'<span class=meta>{run} &middot; {ago(c.get("updated", ""))}</span>')
            tds.append(f'<td class=cell id="{slug}">{body}{meta}{cell_notes(c, st, fixed)}</td>')
        rows.append("<tr>" + "".join(tds) + "</tr>")

    head = "".join(f"<th>{html.escape(l)}</th>" for _, l in targets)
    repo = m.get("repo-slug", "con/eval-under")
    doc = f"""<!doctype html>
<html lang=en>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>eval-under CI status</title>
<style>{CSS}</style>
<main>
<h1>eval-under CI status</h1>
<p class=sub><strong>{npass}/{total}</strong> cells passing &middot;
run #{status.get('run_number', '?')} &middot;
updated {ago(status.get('updated', ''))}</p>
<div class=wrap>
<table>
<thead><tr><th>Backend</th>{head}</tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</div>
<h2>Known issues</h2>
<p class=sub>From <a href="https://github.com/{repo}/blob/master/evals/known-issues.yaml">evals/known-issues.yaml</a>.
A cell whose failures are all covered here still shows as failing, but
its CI job stays green; a failure none of these cover turns it red.</p>
{"".join(render_issue(i, cells, repo) for i in issues)}
<footer>
Rows are backends (which filesystem), columns are targets (which suite).
Each badge links to that cell's job log from the run that produced its
current state. A red cell is not automatically a bug &mdash; see
<a href="https://github.com/{repo}/blob/master/GOTCHAS.md">GOTCHAS.md</a>.
Generated by <code>bin/ci/render-report.py</code> from
<a href="status.json">status.json</a>;
source at <a href="https://github.com/{repo}">{repo}</a>.
</footer>
</main>
"""
    args.outdir.mkdir(parents=True, exist_ok=True)
    (args.outdir / "index.html").write_text(doc)
    print(f"I: wrote {args.outdir}/index.html and {total + 1} badge(s) "
          f"({npass}/{total} passing)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
