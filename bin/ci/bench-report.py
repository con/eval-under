#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render bin/ci/bench-matrix.sh's results.tsv as a per-target comparison
# of how long the suite took on each filesystem.
#
# Separate from the driver for the same reason render-report.py is
# separate from publish-status.sh: the measurement takes hours, the
# presentation of it should be re-runnable in a second. results.tsv is
# the artifact; this is just a view of it, so a bad column choice costs
# nothing to fix after the fact.
#
# usage:
#   bin/ci/bench-report.py <results.tsv> [--baseline SLUG] [--markdown]
#
#   --baseline SLUG   backend slug the ratio column is against
#                     (default: loop-ext4 if present, else the fastest)
#   --markdown        pipe-table output for pasting into an issue or
#                     GOTCHAS.md, instead of the aligned text table
#
# If an env.txt written by bench-matrix.sh sits next to results.tsv, its
# contents are reproduced in the header: a timing table detached from the
# machine that produced it is not a result anyone else can use.

from __future__ import annotations

import argparse
import csv
import statistics
import sys
from pathlib import Path

# Ordered worst-to-best so a cell's summary status is the worst rep in it.
STATUS_RANK = {"setup-error": 3, "timeout": 2, "fail": 1, "ok": 0}


def load(path: Path) -> list[dict]:
    with path.open(newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    if not rows:
        sys.exit(f"{path}: no rows")
    for r in rows:
        try:
            r["_suite"] = float(r["suite_s"])
        except (TypeError, ValueError):
            r["_suite"] = None  # setup-error: the suite never started
        try:
            r["_wall"] = float(r["wall_s"])
        except (TypeError, ValueError):
            r["_wall"] = None
    return rows


def summarize(reps: list[dict]) -> dict:
    """One cell (target x backend) across its repetitions."""
    times = [r["_suite"] for r in reps if r["_suite"] is not None]
    setups = [
        r["_wall"] - r["_suite"]
        for r in reps
        if r["_suite"] is not None and r["_wall"] is not None
    ]
    statuses = [r["status"] for r in reps]
    counts: dict[str, int] = {}
    for s in statuses:
        counts[s] = counts.get(s, 0) + 1
    worst = max(statuses, key=lambda s: STATUS_RANK.get(s, 9))
    if len(counts) == 1:
        status = statuses[0]
    else:
        status = ", ".join(f"{s}x{n}" for s, n in sorted(counts.items()))
    return {
        "n": len(reps),
        "n_timed": len(times),
        "min": min(times) if times else None,
        "median": statistics.median(times) if times else None,
        "max": max(times) if times else None,
        "setup": statistics.median(setups) if setups else None,
        "status": status,
        "worst": worst,
    }


def fmt_secs(v: float | None) -> str:
    if v is None:
        return "--"
    if v >= 6000:
        return f"{v / 60:.0f}m"
    if v >= 600:
        return f"{v / 60:.1f}m"
    return f"{v:.1f}"


def pick_baseline(cells: dict[str, dict], requested: str | None) -> str | None:
    """Slug whose median every other row is expressed against."""
    usable = {
        slug: c for slug, c in cells.items() if c["median"] and c["worst"] == "ok"
    }
    if requested:
        if requested in cells:
            return requested
        # Requested a backend that this run did not measure (or that only
        # failed): say so rather than silently ranking against something
        # else.
        print(f"note: baseline '{requested}' not in these results", file=sys.stderr)
    for slug in usable:
        if slug.endswith("loop-ext4") or slug == "loop-ext4":
            return slug
    if not usable:
        return None
    return min(usable, key=lambda s: usable[s]["median"])


def render(rows: list[dict], baseline_req: str | None, markdown: bool) -> str:
    out: list[str] = []
    targets = []
    for r in rows:
        if r["target"] not in targets:
            targets.append(r["target"])

    for target in targets:
        trows = [r for r in rows if r["target"] == target]
        cells: dict[str, dict] = {}
        for r in trows:
            # slug is "<backend>[-<version>]-<target>"; strip the target
            # so the row header names the filesystem, which is the axis
            # being compared.
            bslug = r["slug"][: -(len(target) + 1)]
            cells.setdefault(bslug, []).append(r)
        cells = {k: summarize(v) for k, v in cells.items()}

        baseline = pick_baseline(cells, baseline_req)
        base_median = cells[baseline]["median"] if baseline else None

        order = sorted(
            cells,
            key=lambda s: (cells[s]["median"] is None, cells[s]["median"] or 0),
        )

        header = ["backend", "n", "min", "median", "max", "setup", "status"]
        ratio_col = f"x {baseline}" if baseline else "x base"
        header.insert(5, ratio_col)

        body = []
        for slug in order:
            c = cells[slug]
            if c["median"] and base_median:
                ratio = f"{c['median'] / base_median:.2f}"
                if slug == baseline:
                    ratio = "1.00"
            else:
                ratio = "--"
            body.append(
                [
                    slug,
                    str(c["n"]),
                    fmt_secs(c["min"]),
                    fmt_secs(c["median"]),
                    fmt_secs(c["max"]),
                    ratio,
                    fmt_secs(c["setup"]),
                    c["status"],
                ]
            )

        title = f"{target}: suite seconds by backend"
        if markdown:
            out.append(f"### {title}\n")
            out.append("| " + " | ".join(header) + " |")
            out.append("| " + " | ".join("---" for _ in header) + " |")
            out += ["| " + " | ".join(r) + " |" for r in body]
        else:
            widths = [
                max(len(header[i]), *(len(r[i]) for r in body))
                for i in range(len(header))
            ]
            out.append(f"=== {title} ===")
            out.append("  ".join(h.ljust(w) for h, w in zip(header, widths)))
            out += ["  ".join(c.ljust(w) for c, w in zip(r, widths)) for r in body]

        dirty = [s for s in order if cells[s]["worst"] != "ok"]
        if dirty:
            note = (
                "note: "
                + ", ".join(dirty)
                + " did not pass; a suite that fails early or is killed at "
                "the timeout reports a truncated time, not a faster "
                "filesystem."
            )
            out.append("")
            out.append(note)
        out.append("")

    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("results", type=Path, help="results.tsv from bench-matrix.sh")
    ap.add_argument("--baseline", help="backend slug to express ratios against")
    ap.add_argument("--markdown", action="store_true", help="markdown tables")
    args = ap.parse_args()

    rows = load(args.results)

    head: list[str] = []
    env = args.results.parent / "env.txt"
    if env.is_file():
        text = env.read_text().rstrip()
        if args.markdown:
            head = ["### host", "", "```", text, "```", ""]
        else:
            head = [text, ""]

    print("\n".join(head) + render(rows, args.baseline, args.markdown))
    return 0


if __name__ == "__main__":
    sys.exit(main())
