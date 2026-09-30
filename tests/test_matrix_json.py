# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# bin/ci/matrix-json.sh against evals/matrix.yaml, and the workflow's
# side of that contract.
#
# evals/matrix.yaml is the single source of truth for the matrix, and
# matrix-json.sh's promise is that "each entry carries everything the job
# body needs, so the workflow never has to recompute anything about a
# cell". These tests hold it to that, because a workflow that recomputes
# a cell's properties from the target *name* is how the
# git-annex-linkannex cells first ran without git-annex installed: they
# declared needs-git-annex, but the fetch step tested
# `matrix.target == 'git-annex'`, so it never ran and every such cell
# died with "git: 'annex' is not a git command".

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/test.yaml"
sys.path.insert(0, str(ROOT / "bin" / "ci"))

import evals  # noqa: E402


def cells() -> list[dict]:
    out = subprocess.run([ROOT / "bin/ci/matrix-json.sh"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)["include"]


class TestMatrixJson(unittest.TestCase):
    def setUp(self):
        self.matrix = evals.load_matrix()
        self.cells = cells()

    def test_every_backend_times_every_target(self):
        want = len(self.matrix["backends"]) * len(self.matrix["targets"])
        self.assertEqual(want, len(self.cells))
        self.assertEqual(len({c["slug"] for c in self.cells}), want,
                         "cell slugs must be unique -- they name artifacts")

    def test_needs_git_annex_matches_the_data_file(self):
        """The flag the workflow gates the daily build on comes from the
        data file, for every cell, not just the ones we remembered."""
        declared = {t["name"]: bool(t["needs-git-annex"])
                    for t in self.matrix["targets"]}
        self.assertTrue(any(declared.values()), "fixture check: someone needs it")
        for c in self.cells:
            with self.subTest(cell=c["slug"]):
                self.assertIn("needs-git-annex", c)
                self.assertEqual(c["needs-git-annex"], declared[c["target"]])

    def test_needs_git_annex_is_a_json_boolean(self):
        """`if:` reads this directly, and the *string* "0" is truthy in a
        GitHub expression -- it would fetch git-annex for every cell."""
        for c in self.cells:
            with self.subTest(cell=c["slug"]):
                self.assertIsInstance(c["needs-git-annex"], bool)


class TestWorkflowReadsTheFlag(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()

    def test_daily_build_is_gated_on_the_flag(self):
        self.assertIn("matrix['needs-git-annex']", self.workflow)

    def test_no_step_is_gated_on_a_target_name(self):
        """Any per-target behaviour belongs in evals/matrix.yaml as a
        flag, so adding a target cannot silently skip a step it needs."""
        hits = re.findall(r"matrix\.target\s*[=!]=.*", self.workflow)
        self.assertEqual(hits, [], "gate on a matrix.yaml flag instead")


if __name__ == "__main__":
    unittest.main()
