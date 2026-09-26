# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# bin/ci/collect-results.py on trimmed real suite output (tests/data/).

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "tests" / "data"
sys.path.insert(0, str(ROOT / "bin" / "ci"))

import evals  # noqa: E402


def collect(target: str, log: Path, *extra: str) -> tuple[dict, dict]:
    """Run the collector on a copy of `log`: (header, {id: outcome})."""
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(log, Path(tmp) / "suite.log")
        subprocess.run([sys.executable, ROOT / "bin/ci/collect-results.py", target, tmp, *extra],
                       check=True, capture_output=True)
        header, rows = evals.read_results(Path(tmp) / "results.tsv")
    return header, dict(rows)


class TestGit(unittest.TestCase):
    def test_outcomes(self):
        h, r = collect("git", DATA / "git/suite.log", "--git-t", str(DATA / "git/t"))
        self.assertEqual(h["complete"], "yes", h.get("reason"))
        self.assertEqual(r["t0202-gettext-perl.sh#1"], "pass")
        self.assertEqual(r["t1990-fake.sh#2"], "fail")
        self.assertEqual(r["t1990-fake.sh#3"], "todo-pass")
        self.assertEqual(r["t1990-fake.sh#4"], "todo")
        self.assertEqual(r["t1991-skipall.sh"], "skip")
        self.assertEqual(r["t1992-dies.sh#plan"], "fail")
        self.assertEqual(r["t1992-dies.sh#exit"], "fail")

    def test_totals_mismatch_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "suite.log"
            log.write_text((DATA / "git/suite.log").read_text().replace("Tests=6", "Tests=7"))
            h, r = collect("git", log, "--git-t", str(DATA / "git/t"))
        self.assertEqual(h["complete"], "no")
        self.assertIn("prove reports", h["reason"])

    def test_repeated_number_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = Path(tmp) / "t/test-results"
            res.mkdir(parents=True)
            (res / "t0000-x.tap").write_text("ok 1\nnot ok 2 - real\nok 2 - stray\n1..2\n")
            (res / "t0000-x.exit").write_text("1\n")
            log = Path(tmp) / "suite.log"
            log.write_text("Files=1, Tests=2, 0 wallclock secs\n")
            h, _ = collect("git", log, "--git-t", str(Path(tmp) / "t"))
        self.assertEqual(h["complete"], "no")
        self.assertIn("duplicate TAP test numbers", h["reason"])

    def test_no_git_t_is_incomplete(self):
        h, _ = collect("git", DATA / "git/suite.log")
        self.assertEqual(h["complete"], "no")


class TestPjdfstest(unittest.TestCase):
    def test_outcomes(self):
        h, r = collect("pjdfstest", DATA / "pjdfstest/suite.log")
        self.assertEqual(h["complete"], "yes", h.get("reason"))
        self.assertEqual(r["chown/00.t#2"], "fail")
        self.assertEqual(r["chown/00.t#3"], "todo")
        self.assertEqual(r["chown/00.t#4"], "todo-pass")
        self.assertEqual(r["unlink/14.t#plan"], "fail")
        self.assertEqual(r["unlink/14.t#exit"], "fail")

    def test_bailout(self):
        h, r = collect("pjdfstest", DATA / "pjdfstest-bailout/suite.log")
        self.assertEqual(h["complete"], "yes", h.get("reason"))
        self.assertEqual(r["a/01.t#bailout"], "fail")


class TestResultsFile(unittest.TestCase):
    def test_round_trip_and_bad_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "results.tsv"
            evals.write_results(f, [("#odd", "pass", "a\tb"), ("x", "fail", "")])
            self.assertEqual(evals.read_results(f),
                             ({"complete": "yes"}, [("#odd", "pass"), ("x", "fail")]))
            f.write_text(f.read_text() + "y\tbogus\n")
            h, rows = evals.read_results(f)
        self.assertEqual(h["complete"], "no")
        self.assertIn("bogus", h["reason"])
        self.assertEqual(len(rows), 2)


class TestStressNg(unittest.TestCase):
    def test_outcomes(self):
        h, r = collect("stress-ng", DATA / "stress-ng/suite.log")
        self.assertEqual(h["complete"], "yes", h.get("reason"))
        self.assertEqual(r, {"chmod": "pass", "utime": "fail", "xattr": "skip"})


class TestGitAnnex(unittest.TestCase):
    def test_outcomes(self):
        h, r = collect("git-annex", DATA / "git-annex/suite.log")
        self.assertEqual(h["complete"], "yes", h.get("reason"))
        git = "Tests.Remote Tests.testremote type git."
        self.assertEqual(r[git + "unavailable remote.retrieveKeyFile"], "pass")
        # Follows stderr noise at group-header indentation.
        self.assertEqual(r[git + "key size 1048576; git remote.storeKey when already present"],
                         "fail")
        self.assertNotIn(git + "unavailable remote.storeKey when already present", r)
        # Two subprocess runs repeat Init Tests; kept once, worst outcome.
        self.assertEqual(r["Tests.Repo Tests v10 adjusted unlocked branch.Init Tests.add"], "fail")

    def test_unknown_target_is_incomplete(self):
        h, _ = collect("nope", DATA / "stress-ng/suite.log")
        self.assertEqual(h["complete"], "no")


if __name__ == "__main__":
    unittest.main()
