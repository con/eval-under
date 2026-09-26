#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Merge one CI run's per-cell results into the persistent status file that
# drives the badge grid and the report page.
#
# Why a persistent file rather than just reading the current run: a run
# does not necessarily cover every cell. GitHub's "Re-run failed jobs"
# re-executes only the red ones, so a run's artifacts can describe 10 of
# 20 cells. Deriving the whole grid from one run would rewrite the other
# 10 badges to "unknown" and destroy good state. So results are merged,
# and a cell absent from this run keeps whatever it last reported.
#
# (This is a deliberate divergence from con/git-annex's update.py, which
# sets absent tests to UNKNOWN. There, a client that stops reporting a
# test genuinely has unknown status. Here, absent means "this run did not
# re-run that cell", which is not the same claim.)
#
# usage:
#   bin/ci/update-status.py <status.json> <results-dir> [--jobs jobs.json]
#
# <results-dir> holds the downloaded result-<slug> artifacts (see the
# "Record cell result" step in test.yaml).
#
# --jobs takes the output of
#     gh api --paginate repos/$REPO/actions/runs/$RUN_ID/jobs
# and is what turns a cell into a deep link to its own log: job names are
# set from the matrix entry's `name`, so they match exactly. Same trick as
# con/git-annex's .github/workflows/tools/set-pr-status.
#
# env:
#   GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_RUN_ATTEMPT, GITHUB_SHA
#   EVAL_UNDER_MATRIX_FILE   (default: evals/matrix.yaml)

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from evals import load_matrix, matrix_cells

STATUS_NEW_FAILURES = 10    # new-failure ids kept per cell in status.json


def verdict_fields(v: dict | None) -> dict:
    """The slice of a verdict worth keeping in status.json.

    status.json doubles as history (see publish-status.sh), so per-test
    lists stay short.
    """
    if not v:
        return {}
    return {
        "state": v["state"],
        "reason": v["reason"],
        "counts": v["counts"],
        "new_failures": v["new_failures"][:STATUS_NEW_FAILURES],
        "issues": {iid: {k: e[k] for k in ("status", "fail")}
                   for iid, e in v["issues"].items()},
    }


def read_results(results_dir: Path) -> dict[str, tuple[str, dict | None]]:
    """slug -> (conclusion, verdict.json or None).

    actions/download-artifact gives each artifact its own subdirectory; a
    flat layout of conclusion files is accepted too so this can be
    exercised locally.
    """
    out = {}
    if not results_dir.is_dir():
        return out
    for p in sorted(results_dir.iterdir()):
        if p.is_dir() and p.name.startswith("result-"):
            f = p / "conclusion"
            if not f.is_file():
                continue
            verdict = None
            vf = p / "verdict.json"
            if vf.is_file():
                try:
                    verdict = json.loads(vf.read_text())
                except ValueError as e:
                    print(f"W: {vf}: {e}", file=sys.stderr)
            out[p.name[len("result-"):]] = (f.read_text().strip(), verdict)
        elif p.is_file():
            out[p.name] = (p.read_text().strip(), None)
    return out


def job_urls(jobs_file: Path | None) -> dict[str, str]:
    """job name -> html_url, so each cell can deep-link to its own log."""
    if jobs_file is None or not jobs_file.is_file():
        return {}
    text = jobs_file.read_text().strip()
    if not text:
        return {}
    urls = {}
    # `gh api --paginate` concatenates one JSON object per page.
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(text):
        obj, end = decoder.raw_decode(text, idx)
        for job in obj.get("jobs", []):
            if job.get("name") and job.get("html_url"):
                urls[job["name"]] = job["html_url"]
        idx = end
        while idx < len(text) and text[idx] in " \t\r\n":
            idx += 1
    return urls


def env_int(name: str, default: int) -> int:
    """int() of an env var, tolerating unset *and* set-but-empty.

    A workflow that passes `FOO: ${{ github.event.x }}` for a missing
    value exports the empty string, not nothing -- so the default
    argument of os.environ.get never fires and int("") raises.
    """
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else default


def newer(new: tuple[int, int], old: tuple[int, int]) -> bool:
    """Monotonic guard, per cell.

    "Re-run failed jobs" keeps run_number and bumps run_attempt, so the
    pair orders correctly for both a fresh run and a re-run. Guarding per
    cell rather than globally (as con/git-annex does with highest_build)
    is what lets a partial re-run update just its own cells.
    """
    return new > old


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("status_file", type=Path)
    ap.add_argument("results_dir", type=Path)
    ap.add_argument("--jobs", type=Path, default=None)
    args = ap.parse_args()

    cells = matrix_cells(load_matrix())

    run_id = env_int("GITHUB_RUN_ID", 0)
    run_number = env_int("GITHUB_RUN_NUMBER", 0)
    run_attempt = env_int("GITHUB_RUN_ATTEMPT", 1)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")

    if args.status_file.is_file():
        status = json.loads(args.status_file.read_text())
    else:
        status = {"cells": {}}
    prior = status.get("cells", {})

    results = read_results(args.results_dir)
    urls = job_urls(args.jobs)

    merged, updated, kept, pruned = {}, 0, 0, 0
    for slug, meta in cells.items():
        old = prior.get(slug)
        if slug in results:
            conclusion, verdict = results[slug]
            old_key = (old.get("run_number", -1), old.get("run_attempt", -1)) if old else (-1, -1)
            if old is None or newer((run_number, run_attempt), old_key):
                merged[slug] = {
                    **meta,
                    **verdict_fields(verdict),
                    "conclusion": conclusion,
                    "run_id": run_id,
                    "run_number": run_number,
                    "run_attempt": run_attempt,
                    "sha": os.environ.get("GITHUB_SHA", ""),
                    "job_url": urls.get(meta["label"], ""),
                    "updated": now,
                }
                updated += 1
                continue
            print(f"I: {slug}: ignoring older result "
                  f"({run_number}.{run_attempt} <= {old_key[0]}.{old_key[1]})")
        if old is not None:
            # Not in this run (or older): keep what it last reported.
            merged[slug] = {**old, **meta}
            kept += 1
        else:
            merged[slug] = {**meta, "conclusion": "unknown", "updated": now}

    # A cell dropped from the matrix should not linger in the grid.
    for slug in prior:
        if slug not in cells:
            pruned += 1
            print(f"I: pruning {slug} (no longer in the matrix)")

    status = {
        "updated": now,
        "run_id": run_id,
        "run_number": run_number,
        "run_attempt": run_attempt,
        "cells": merged,
    }
    args.status_file.parent.mkdir(parents=True, exist_ok=True)
    args.status_file.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")

    print(f"I: {len(merged)} cell(s): {updated} updated from this run, "
          f"{kept} carried over, {pruned} pruned")
    if not urls and results:
        print("W: no job URLs resolved -- report links will be empty", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
