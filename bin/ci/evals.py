# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# What the bin/ci Python scripts share: the matrix (evals/matrix.yaml) and
# the per-cell results.tsv format.

from __future__ import annotations

import os
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MATRIX_FILE = Path(os.environ.get("EVAL_UNDER_MATRIX_FILE", ROOT / "evals/matrix.yaml"))


# --------------------------------------------------------------------------
# the matrix

def backend_slug(backend: str, version: str) -> str:
    # Keep in sync with backend_slug() in bin/ci/matrix.sh.
    return backend if version == "n/a" else f"{backend}-{version}"


def load_matrix(path: Path = MATRIX_FILE) -> dict:
    with path.open() as fh:
        return yaml.safe_load(fh)


def matrix_cells(m: dict) -> dict[str, dict]:
    """slug -> cell metadata, in matrix (row, column) order."""
    cells = {}
    for b in m["backends"]:
        bslug = backend_slug(b["backend"], b["version"])
        for t in m["targets"]:
            cells[f"{bslug}-{t['name']}"] = {
                "backend": b["backend"],
                "version": b["version"],
                "backend_slug": bslug,
                "backend_label": b["label"],
                "target": t["name"],
                "target_label": t["label"],
                "label": f"{b['label']} / {t['label']}",
            }
    return cells


# --------------------------------------------------------------------------
# results.tsv: `# key: value` header lines, then one test per line:
# id TAB outcome [TAB detail]

OUTCOMES = ("pass", "fail", "skip", "todo", "todo-pass")
# Only `# key: value`, so a test id starting with "#" still reads as a row.
HEADER = re.compile(r"^# (?P<k>[a-z][a-z-]*): ?(?P<v>.*)$")

Row = tuple[str, str, str]      # (id, outcome, detail)


def write_results(path: Path, rows: list[Row], reason: str = "") -> None:
    """reason non-empty marks the results incomplete."""
    with path.open("w") as fh:
        fh.write(f"# complete: {'no' if reason else 'yes'}\n")
        if reason:
            fh.write(f"# reason: {reason}\n")
        for tid, outcome, detail in rows:
            detail = detail.replace("\t", " ").replace("\n", " ")
            fh.write("\t".join([tid, outcome] + ([detail] if detail else [])) + "\n")


def read_results(path: Path) -> tuple[dict[str, str], list[tuple[str, str]]]:
    """(header, [(id, outcome)])."""
    if not path.is_file():
        return {"complete": "no", "reason": f"no {path.name} (results never collected)"}, []
    header: dict[str, str] = {}
    rows = []
    for line in path.read_text().splitlines():
        m = HEADER.match(line)
        if m:
            header[m.group("k")] = m.group("v").strip()
            continue
        if not line.strip():
            continue
        tid, _, rest = line.partition("\t")
        outcome = rest.partition("\t")[0]
        if outcome not in OUTCOMES:
            header.update(complete="no", reason=f"bad outcome {outcome!r} for {tid!r}")
            continue
        rows.append((tid, outcome))
    return header, rows
