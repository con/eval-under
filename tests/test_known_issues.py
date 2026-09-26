# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "ci"))

import known_issues as ki  # noqa: E402

MATRIX = {
    "backends": [{"backend": "nfs", "version": "n/a", "label": "NFS"},
                 {"backend": "beegfs", "version": "7.4.6", "label": "BeeGFS 7.4.6"}],
    "targets": [{"name": "git", "label": "git testsuite"}],
}
COMPLETE = {"complete": "yes"}


def issue(**kw) -> ki.Issue:
    return ki.Issue(**{"id": "x", "title": "t", "backends": ["nfs"], "targets": ["git"],
                       "tests": ["a#1-2"], "links": ["l"], **kw})


class TestExpand(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual(ki.expand(["f#1-3,7", "g#*", "h#5"]),
                         ["f#1", "f#2", "f#3", "f#7", "g#*", "h#5"])

    def test_reversed(self):
        with self.assertRaises(ValueError):
            ki.expand(["f#5-3"])


class TestValidate(unittest.TestCase):
    def errors(self, **kw):
        raw = {"tags": {"harness": "..."},
               "issues": [{"id": "x", "title": "t", "backends": ["nfs"], "targets": ["git"],
                           "tests": ["a"], "links": ["l"], **kw}]}
        return ki.validate(raw, MATRIX)

    def test_valid(self):
        self.assertEqual(self.errors(tags=["harness"]), [])

    def test_problems(self):
        self.assertTrue(self.errors(tags=["nope"]))
        self.assertTrue(self.errors(backends=["loop-*"]))
        self.assertTrue(self.errors(targets=["pjdfstest"]))
        self.assertTrue(self.errors(tests=["a#5-3"]))
        self.assertTrue(self.errors(expect="flaky"))

    def test_repo_file(self):
        self.assertEqual(ki.validate(ki.load(), ki.load_matrix()), [])


class TestMatrixCells(unittest.TestCase):
    def test_slugs_and_labels(self):
        cells = ki.matrix_cells(MATRIX)
        self.assertEqual(list(cells), ["nfs-git", "beegfs-7.4.6-git"])
        self.assertEqual(cells["beegfs-7.4.6-git"]["label"], "BeeGFS 7.4.6 / git testsuite")


class TestClassify(unittest.TestCase):
    def classify(self, rows, rc=1, header=COMPLETE, issues=None):
        return ki.classify(issues or [issue()], "nfs", "git", rc, header, rows)

    def test_known(self):
        v = self.classify([("a#1", "fail"), ("a#2", "pass")])
        self.assertEqual((v["state"], v["conclusion"]), ("failing-known", "success"))
        self.assertEqual(v["issues"]["x"]["status"], "reproduced")
        self.assertEqual(v["issues"]["x"]["passed_exact"], ["a#2"])

    def test_new(self):
        v = self.classify([("b#1", "fail")])
        self.assertEqual((v["state"], v["conclusion"]), ("failing-new", "failure"))
        self.assertEqual(v["new_failures"], ["b#1"])
        self.assertEqual(v["issues"]["x"]["status"], "stale")

    def test_not_reproduced(self):
        v = self.classify([("a#1", "pass")], rc=0)
        self.assertEqual(v["state"], "passing")
        self.assertEqual(v["issues"]["x"]["status"], "not-reproduced")

    def test_issue_for_other_cell_ignored(self):
        v = self.classify([("a#1", "fail")], issues=[issue(backends=["beegfs-*"])])
        self.assertEqual(v["state"], "failing-new")

    def test_incomplete(self):
        for rc, header, rows in [
            (None, COMPLETE, []),                          # never ran
            (124, COMPLETE, [("a#1", "fail")]),            # timed out
            (1, COMPLETE, [("a#1", "pass")]),              # rc and parse disagree
            (1, {"complete": "no", "reason": "r"}, []),   # collector gave up
        ]:
            v = self.classify(rows, rc=rc, header=header)
            self.assertEqual((v["state"], v["conclusion"]), ("incomplete", "failure"), rc)


if __name__ == "__main__":
    unittest.main()
