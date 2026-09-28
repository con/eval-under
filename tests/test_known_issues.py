# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin" / "ci"
sys.path.insert(0, str(BIN))

import evals  # noqa: E402
import known_issues as ki  # noqa: E402

MATRIX = {
    "backends": [{"backend": "nfs", "version": "n/a", "label": "NFS"},
                 {"backend": "beegfs", "version": "7.4.6", "label": "BeeGFS 7.4.6"}],
    "targets": [{"name": "git", "label": "git testsuite"}],
}
COMPLETE = {"complete": "yes"}


def issue(**kw) -> ki.Issue:
    return ki.Issue(**{"id": "x", "title": "t", "backends": ["nfs"], "targets": ["git"],
                       "tests": ["a#1-2"], **kw})


class TestExpand(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual(ki.expand(["f#1-3,7", "g#*", "h#5"]),
                         ["f#1", "f#2", "f#3", "f#7", "g#*", "h#5"])

    def test_reversed(self):
        with self.assertRaises(ValueError):
            ki.expand(["f#5-3"])


class TestValidate(unittest.TestCase):
    def errors(self, **kw):
        fields = {"id": "x", "title": "t", "backends": ["nfs"], "targets": ["git"],
                  "tests": ["a"], **kw}
        raw = {"tags": {"harness": "..."},
               "issues": [{k: v for k, v in fields.items() if v is not None}]}
        return ki.validate(raw, MATRIX)

    def test_valid(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(self.errors(tags=["harness"], links=["l"], notes="n"), [])

    def test_problems(self):
        for kw, expected in [
            ({"tags": ["nope"]}, "tag 'nope' is not declared"),
            ({"backends": ["loop-*"]}, "backend pattern 'loop-*' matches none"),
            ({"targets": ["pjdfstest"]}, "unknown target 'pjdfstest'"),
            ({"tests": ["a#5-3"]}, "reversed range"),
            ({"tests": None}, "tests must be a non-empty list"),
            ({"links": []}, "links must be a non-empty list"),
            ({"title": None}, "title is required"),
            ({"id": "X_1"}, "id must be lowercase"),
            ({"expect": "flaky"}, "unknown field 'expect'"),
            ({"id": ["x"]}, "id must be lowercase"),
            ({"title": "TODO: root cause"}, "placeholder 'TODO: root cause'"),
        ]:
            with self.subTest(**{k: str(v) for k, v in kw.items()}):
                errs = self.errors(**kw)
                self.assertEqual(len(errs), 1, errs)
                self.assertIn(expected, errs[0])

    def test_draft_needs_editing(self):
        v = {"cell": "nfs-git", "backend_slug": "nfs", "target": "git",
             "new_failures": ["t0001-init.sh#3"]}
        stubs = ki.draft([v, {**v, "new_failures": []}])
        self.assertEqual(len(stubs), 1)
        errs = ki.validate({"tags": {"needs-triage": "..."}, "issues": stubs}, MATRIX)
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("placeholder", errs[0])


class TestValidateShape(unittest.TestCase):
    def test_non_mapping_issue(self):
        self.assertEqual(ki.validate({"issues": ["x"]}, MATRIX), ["issues[0]: must be a mapping"])


class TestMatrixCells(unittest.TestCase):
    def test_slugs_and_labels(self):
        cells = evals.matrix_cells(MATRIX)
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

    def test_glob_does_not_cover_a_dying_script(self):
        glob = issue(tests=["a#*"])
        for tid in ("a#plan", "a#exit", "a#bailout"):
            with self.subTest(tid=tid):
                v = self.classify([(tid, "fail")], issues=[glob])
                self.assertEqual(v["state"], "failing-new")
                v = self.classify([(tid, "fail")], issues=[issue(tests=[tid])])
                self.assertEqual(v["state"], "failing-known")
                v = self.classify([(tid, "fail")], issues=[issue(tests=["*"])])
                self.assertEqual(v["state"], "failing-known")

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
            with self.subTest(rc=rc, header=header):
                v = self.classify(rows, rc=rc, header=header)
                self.assertEqual((v["state"], v["conclusion"]), ("incomplete", "failure"))


class TestCheck(unittest.TestCase):
    """`check` end to end: suite.rc and results.tsv in, verdict.json and exit status out."""

    def check(self, rc: str, results: str) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            cell = Path(tmp)
            (cell / "suite.rc").write_text(rc)
            (cell / "results.tsv").write_text(results)
            p = subprocess.run([sys.executable, BIN / "known_issues.py", "check",
                                "nfs", "n/a", "stress-ng", str(cell)],
                               capture_output=True, text=True, env={**os.environ,
                                                                    "GITHUB_STEP_SUMMARY": ""})
            return p.returncode, json.loads((cell / "verdict.json").read_text())

    def test_new_failure_fails_the_job(self):
        rc, v = self.check("1\n", "# complete: yes\nutime\tfail\nchmod\tpass\n")
        self.assertEqual((rc, v["state"], v["cell"]), (1, "failing-new", "nfs-stress-ng"))

    def test_passing(self):
        rc, v = self.check("0\n", "# complete: yes\nchmod\tpass\n")
        self.assertEqual((rc, v["state"]), (0, "passing"))


GOTCHAS_GOLDEN = """\
<!-- BEGIN KNOWN ISSUES (generated by bin/ci/known_issues.py gotchas) -->

| Tag | Meaning |
| --- | --- |
| `harness` | Ours. |

<a id="x"></a>
### `x`: t

**Cells:** `nfs-git` \\
**Tags:** `harness` \\
**Tests:** `a#1-2`

Why.

See: <https://example.org/bug>, [A section](#sec)

<a id="y"></a>
### `y`: u

**Cells:** `beegfs-7.4.6-git` \\
**Tests:** all (whole cell, not yet narrowed down)

<!-- END KNOWN ISSUES -->"""


class TestRenderGotchas(unittest.TestCase):
    def test_golden(self):
        issues = [issue(tags=["harness"], notes="Why.\n",
                        links=["https://example.org/bug", "GOTCHAS.md#sec"]),
                  issue(id="y", title="u", backends=["beegfs-*"], tests=["*"])]
        sections = ki.section_titles("# Top\n## A section\n")
        self.assertEqual(sections, {"top": "Top", "a-section": "A section"})
        sections["sec"] = "A section"
        self.assertEqual(ki.render_gotchas({"tags": {"harness": "Ours."}}, issues, MATRIX,
                                           sections), GOTCHAS_GOLDEN)

    def test_section_anchor_like_github(self):
        self.assertIn("nfs-bineval-under-nfs", ki.section_titles("### NFS (`bin/eval-under-nfs`)"))
        self.assertIn("loop-vfat--git-testsuite-posixperm",
                      ki.section_titles("### Loop vfat / git testsuite: POSIXPERM"))


if __name__ == "__main__":
    unittest.main()
