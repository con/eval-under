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
# It also carries what a badge cannot: which run, how long ago, and the
# standing explanation for a cell that is red on purpose.
#
# usage:
#   bin/ci/render-report.py <status.json> <output-dir>

from __future__ import annotations

import argparse
import html
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

# Cells that are red for a known, documented reason. Keeps the page
# honest: a red cell here is a finding, not a regression to chase.
# Keyed by slug; kept in sync with GOTCHAS.md by hand (there are ten).
KNOWN_RED = {
    "loop-vfat-git-annex": "vfat has no symlinks or ownership",
    "loop-vfat-git": "git's POSIXPERM prereq is set from uname, never probed",
    "loop-vfat-stress-ng": "vfat lacks chown/xattr/hardlink semantics",
    "loop-vfat-pjdfstest": "vfat is not a POSIX filesystem",
    "beegfs-7.4.6-pjdfstest": "BeeGFS POSIX conformance gaps",
    "beegfs-8.1.0-pjdfstest": "BeeGFS POSIX conformance gaps",
    "beegfs-7.4.6-git-annex": "the bug this repo exists to characterise",
    "beegfs-8.1.0-git-annex": "the bug this repo exists to characterise",
    "nfs-pjdfstest": "NFS chown/setuid divergence (106 of 1280 assertions)",
    "loop-ext4-git-annex": "pre-existing, predates this harness",
}

STATE = {
    "success": ("passing", "#4c1"),
    "failure": ("failing", "#e05d44"),
    "cancelled": ("cancelled", "#9f9f9f"),
    "skipped": ("skipped", "#9f9f9f"),
}

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
.why { display:block; font-size:.75rem; color:var(--muted); font-style:italic; margin-top:.15rem }
footer { margin-top:2rem; padding-top:1rem; border-top:1px solid var(--line);
  color:var(--muted); font-size:.85rem }
"""


def render_badge(conclusion: str, title: str, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [str(HERE / "render-badge.sh"), conclusion, title],
        capture_output=True, text=True, check=True,
    )
    out.write_text(r.stdout)


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

    # Preserve matrix order rather than sorting: the page should read like
    # the README grid.
    with (ROOT / ".github/matrix.yaml").open() as fh:
        import yaml
        m = yaml.safe_load(fh)
    backends = [(b["backend"] if b["version"] == "n/a" else f"{b['backend']}-{b['version']}",
                 b["label"]) for b in m["backends"]]
    targets = [(t["name"], t["label"]) for t in m["targets"]]

    npass = sum(1 for c in cells.values() if c.get("conclusion") == "success")
    total = len(cells)
    overall = "success" if npass == total else "failure"
    render_badge(overall, f"eval-under: {npass}/{total} cells passing",
                 args.outdir / "badges" / "overall.svg")

    rows = []
    for bslug, blabel in backends:
        tds = [f"<th scope=row>{html.escape(blabel)}</th>"]
        for tname, tlabel in targets:
            slug = f"{bslug}-{tname}"
            c = cells.get(slug, {"conclusion": "unknown"})
            concl = c.get("conclusion", "unknown")
            label = c.get("label", slug)
            render_badge(concl, label, args.outdir / "badges" / f"{slug}.svg")

            text, _ = STATE.get(concl, ("unknown", "#9f9f9f"))
            img = (f'<img src="badges/{slug}.svg" alt="{html.escape(label)}: {text}" '
                   f'height="20">')
            url = c.get("job_url", "")
            body = f'<a href="{html.escape(url)}">{img}</a>' if url else img

            meta = ""
            if c.get("run_number"):
                attempt = c.get("run_attempt", 1)
                run = f"#{c['run_number']}" + (f".{attempt}" if attempt > 1 else "")
                meta = (f'<span class=meta>{run} &middot; {ago(c.get("updated", ""))}</span>')
            why = ""
            if concl == "failure" and slug in KNOWN_RED:
                why = f'<span class=why>expected: {html.escape(KNOWN_RED[slug])}</span>'
            tds.append(f'<td class=cell id="{slug}">{body}{meta}{why}</td>')
        rows.append("<tr>" + "".join(tds) + "</tr>")

    head = "".join(f"<th>{html.escape(l)}</th>" for _, l in targets)
    repo = "con/eval-under"
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
