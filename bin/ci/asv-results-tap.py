#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Turn one asv results file into TAP: one point per benchmark, and per
# parameter combination of a parameterized one. Used by
# bin/ci/target-datalad-benchmarks.sh, so bin/ci/collect-results.py can
# score the cell like any other TAP-speaking target.
#
# The id is the benchmark's dotted name, plus "(v1,v2)" for a
# parameterized one -- parentheses, not brackets, so the id pasted into
# evals/known-issues.yaml stays a literal rather than a glob character
# class. The rest of the description is the timing, for the log.
#
# asv's own encoding (asv/results.py, asv_runner/run.py): a result of
# null is a benchmark that failed (raised, or timed out), NaN one that
# skipped itself (NotImplementedError in setup). Values are in the unit
# benchmarks.json declares, seconds for every time_* benchmark.
#
# A benchmark asv did not finish and save has no entry at all. With
# --expect, every benchmark in benchmarks.json the regex selects is
# reported regardless, a missing one as "not ok ... not run" -- what is
# left of a pass that target-datalad-benchmarks.sh stopped at its
# deadline (asv saves a pass's results only when the pass ends).
#
# Stdlib only: it runs under whatever python3 the runner has, not the
# benchmark venv. Exits 1 if any point is "not ok", else 0 -- the exit
# status has to agree with the parse (see classify() in known_issues.py).

from __future__ import annotations

import argparse
import itertools
import json
import math
import re
import sys
from pathlib import Path

SPACE = re.compile(r"\s+")
NOT_RUN = "not run: asv stopped before recording it (out of time? see DEADLINE above)"


def human(value: float, unit: str) -> str:
    if unit == "seconds":
        for scale, suffix in ((1, "s"), (1e-3, "ms"), (1e-6, "us")):
            if abs(value) >= scale:
                return f"{value / scale:.3g}{suffix}"
        return f"{value * 1e9:.3g}ns"
    if unit == "bytes":
        for scale, suffix in ((2**30, "GiB"), (2**20, "MiB"), (2**10, "KiB")):
            if abs(value) >= scale:
                return f"{value / scale:.3g}{suffix}"
        return f"{value:.0f}B"
    return f"{value:.4g} {unit}".rstrip()


def ident(name: str, combo: tuple) -> str:
    if not combo:
        return name
    return name + "(" + ",".join(SPACE.sub("", str(c)) for c in combo) + ")"


def column(row: list, columns: list[str], name: str):
    """A results row is positional, trailing nulls dropped."""
    i = columns.index(name) if name in columns else len(row)
    return row[i] if i < len(row) else None


def points(results: dict, benchmarks: dict, expect: str | None):
    """(id, outcome, detail) per benchmark x parameter combination."""
    columns = results["result_columns"]
    names = set(results["results"])
    if expect is not None:
        names |= {k for k, v in benchmarks.items()
                  if isinstance(v, dict) and re.search(expect, k)}
    for name in sorted(names):
        if name not in results["results"]:
            params = benchmarks[name].get("params") or []
            for combo in itertools.product(*params):
                yield ident(name, combo), "fail", NOT_RUN
            continue
        row = results["results"][name]
        params = column(row, columns, "params") or []
        combos = [()] if not params else list(itertools.product(*params))
        values = column(row, columns, "result") or [None] * len(combos)
        q25 = column(row, columns, "stats_q_25") or [None] * len(combos)
        q75 = column(row, columns, "stats_q_75") or [None] * len(combos)
        nrep = column(row, columns, "stats_repeat") or [None] * len(combos)
        unit = benchmarks.get(name, {}).get("unit", "seconds")
        if len(values) != len(combos):
            raise SystemExit(f"{name}: {len(values)} result(s) for {len(combos)} "
                             f"parameter combination(s)")
        for k, combo in enumerate(combos):
            tid = ident(name, combo)
            v = values[k]
            if v is None:
                yield tid, "fail", "failed (see the asv output above)"
            elif isinstance(v, float) and math.isnan(v):
                yield tid, "skip", "the benchmark skipped itself"
            else:
                detail = human(v, unit)
                if q25[k] is not None and q75[k] is not None:
                    detail += f" (IQR {human(q25[k], unit)}..{human(q75[k], unit)}"
                    detail += f", {nrep[k]} samples)" if nrep[k] else ")"
                yield tid, "pass", detail


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Print an asv results file as TAP; exit 1 if any benchmark failed.")
    ap.add_argument("results", type=Path,
                    help="<results_dir>/<machine>/<commit>-<env>.json")
    ap.add_argument("--benchmarks", type=Path,
                    help="benchmarks.json, for units and --expect "
                         "(default: <results_dir>/benchmarks.json)")
    ap.add_argument("--expect", metavar="REGEX",
                    help="report every benchmark REGEX matches (re.search, "
                         "as asv --bench does; '' for all), run or not")
    a = ap.parse_args()

    results = json.loads(a.results.read_text())
    bfile = a.benchmarks or a.results.parent.parent / "benchmarks.json"
    if bfile.is_file():
        benchmarks = json.loads(bfile.read_text())
    elif a.expect is None:
        benchmarks = {}
    else:
        raise SystemExit(f"--expect needs {bfile}")

    pts = list(points(results, benchmarks, a.expect))
    print(f"1..{len(pts)}")
    rc = 0
    for n, (tid, outcome, detail) in enumerate(pts, 1):
        if outcome == "fail":
            print(f"not ok {n} - {tid} {detail}")
            rc = 1
        elif outcome == "skip":
            print(f"ok {n} - {tid} # SKIP {detail}")
        else:
            print(f"ok {n} - {tid} {detail}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
