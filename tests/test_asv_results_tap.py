# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# bin/ci/asv-results-tap.py on a trimmed real asv results tree
# (tests/data/datalad-benchmarks/asv-results/), and the collector on
# what target-datalad-benchmarks.sh printed around it.

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "tests" / "data" / "datalad-benchmarks"
TAP = ROOT / "bin" / "ci" / "asv-results-tap.py"
sys.path.insert(0, str(ROOT / "bin" / "ci"))

import evals  # noqa: E402


def results_file() -> Path:
    files = sorted((DATA / "asv-results").glob("*/*-*.json"))
    assert len(files) == 1, files
    return files[0]


def tap(path: Path, *args: str) -> tuple[int, list[str]]:
    p = subprocess.run([sys.executable, TAP, *args, path], capture_output=True, text=True)
    return p.returncode, p.stdout.splitlines()


def with_results(edit, *args: str) -> tuple[int, list[str]]:
    """tap() on a copy of the fixture tree whose results edit() changed."""
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / "asv-results"
        shutil.copytree(DATA / "asv-results", tree)
        f = tree / results_file().relative_to(DATA / "asv-results")
        d = json.loads(f.read_text())
        edit(d)
        f.write_text(json.dumps(d))
        return tap(f, *args)


class TestAsvResultsTap(unittest.TestCase):
    def test_all_pass(self):
        rc, lines = tap(results_file())
        self.assertEqual(rc, 0, lines)
        self.assertRegex(lines[0], r"^1\.\.\d+$")
        self.assertEqual(int(lines[0][3:]), len(lines) - 1)
        self.assertTrue(all(ln.startswith("ok ") for ln in lines[1:]), lines)
        # One point per parameter combination, the values in the id.
        ids = [ln.split()[3] for ln in lines[1:]]
        self.assertIn("save_run.save_since_flat.time_save_since(5)", ids)
        self.assertIn("plugins.addurls.addurls1.time_addurls('*')", ids)
        self.assertIn("core.startup.time_import", ids)
        self.assertEqual(len(ids), len(set(ids)))

    def test_timing_in_detail(self):
        _, lines = tap(results_file())
        line = next(ln for ln in lines if " core.startup.time_import " in ln)
        self.assertRegex(line, r" \d[\d.]*(s|ms|us) \(IQR ")

    def test_null_is_a_failure_nan_a_skip(self):
        def edit(d):
            d["results"]["core.startup.time_import"][0] = None
            d["results"]["save_run.save_since_flat.time_save_since"][0][1] = float("nan")
        rc, lines = with_results(edit)
        self.assertEqual(rc, 1)
        self.assertIn("not ok", next(ln for ln in lines if "core.startup.time_import" in ln))
        skip = next(ln for ln in lines if "time_save_since(5)" in ln)
        self.assertRegex(skip, r"^ok \d+ - \S+ # SKIP ")
        self.assertRegex(next(ln for ln in lines if "time_save_since(1)" in ln), r"^ok ")

    def test_all_combinations_failed(self):
        def edit(d):
            row = d["results"]["save_run.save_since_flat.time_save_since"]
            row[0] = None
            del row[d["result_columns"].index("stats_ci_99_a"):]
        rc, lines = with_results(edit)
        self.assertEqual(rc, 1)
        bad = [ln for ln in lines if "save_since_flat.time_save_since(" in ln]
        self.assertEqual(len(bad), 3)
        self.assertTrue(all(ln.startswith("not ok ") for ln in bad), bad)


    def test_expect_reports_what_asv_never_reached(self):
        def edit(d):
            del d["results"]["save_run.save_since_flat.time_save_since"]
        # Without --expect a missing benchmark is simply not there...
        rc, lines = with_results(edit)
        self.assertEqual(rc, 0)
        self.assertFalse([ln for ln in lines if "save_since_flat" in ln])
        # ...with it, each of its parameter combinations is a failure.
        rc, lines = with_results(edit, "--expect", "")
        self.assertEqual(rc, 1)
        self.assertEqual(int(lines[0][3:]), 7)
        bad = [ln for ln in lines if "save_since_flat" in ln]
        self.assertEqual(len(bad), 3)
        self.assertTrue(all(ln.startswith("not ok ") and "not run" in ln for ln in bad), bad)


class TestCollect(unittest.TestCase):
    def test_suite_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copy(DATA / "suite.log", Path(tmp) / "suite.log")
            subprocess.run([sys.executable, ROOT / "bin/ci/collect-results.py",
                            "datalad-benchmarks", tmp], check=True, capture_output=True)
            header, rows = evals.read_results(Path(tmp) / "results.tsv")
        self.assertEqual(header["complete"], "yes", header.get("reason"))
        r = dict(rows)
        self.assertEqual(r["core.startup.time_import"], "pass")
        self.assertEqual(r["save_run.save_since_flat.time_save_since(5)"], "pass")


if __name__ == "__main__":
    unittest.main()
