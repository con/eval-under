#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Turn one suite's own output into per-test results.tsv, the input to
# `known_issues.py check`.
#
# Every suite here already speaks something standard or close to it, so
# each adapter is small and parses a format rather than scraping prose:
#
#   git        TAP, one file per script: t/test-results/<script>.tap (the
#              stream prove parsed, kept by bin/ci/git-prove-exec.sh),
#              plus <script>.exit
#   pjdfstest  TAP, as echoed by `prove -v` into suite.log
#   stress-ng  TAP, emitted by our own target-stress-ng.sh into suite.log
#   git-annex  tasty's console tree in suite.log. git-annex runs its test
#              groups as parallel subprocesses, and tasty-rerun's
#              --rerun-log-file is overwritten by each of them, so the
#              console is the only complete record. Upstream TODO for a
#              TAP log instead:
#              https://git-annex.branchable.com/todo/provide_TAP_protocol_logging_for___39__annex_test__39__/
#
# Robustness does not come from the parsers being clever. It comes from
# cross-checking each one against the totals the suite prints itself
# (prove's "Files=N, Tests=M", tasty's "N out of M tests failed"): any
# disagreement marks the results incomplete, and known_issues.py turns
# incomplete into a red job. A parser that drifts after a ref bump or an
# upstream format change therefore fails loudly instead of silently
# hiding failures.
#
# Test ids:
#   git        t0001-init.sh#13
#   pjdfstest  chown/00.t#412
#   stress-ng  rename
#   git-annex  Tests.Repo Tests v10 unlocked.Init Tests.add
#              (the dotted form `git annex test --list-tests` prints)
# plus, for TAP suites, per-file pseudo-tests: <file>#plan (plan missing or
# not matching what ran) and <file>#exit (non-zero exit with no failing
# assertion). Those are what a script that dies half-way reports as, and
# they can be listed in known-issues.yaml like any other test.
#
# usage:
#   bin/ci/collect-results.py <target> <cell-dir> [--git-t DIR]
#
#   --git-t   git's t/ directory (default /opt/eval-under-src/git/t)
#
# Reads <cell-dir>/suite.log, writes <cell-dir>/results.tsv. Exits 0 even
# for incomplete results: incompleteness is recorded in the file, and it
# is known_issues.py's job to decide what it means.

from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
TAP_LINE = re.compile(
    r"^(?P<not>not )?ok (?P<num>\d+)\b(?: -)? ?(?P<desc>.*?)"
    r"(?:\s*#\s*(?P<dir>TODO|SKIP)\b\s*(?P<why>.*))?$", re.IGNORECASE)
TAP_PLAN = re.compile(r"^1\.\.(?P<n>\d+)(?:\s+#\s*(?P<skip>SKIP.*))?$", re.IGNORECASE)
TAP_BAIL = re.compile(r"^Bail out!\s*(?P<why>.*)$")
# What prove prints (to stderr, so anywhere in the log) instead of
# passing the TAP "Bail out!" line through.
PROVE_BAIL = re.compile(r"^Bailout called\.\s+Further testing stopped:\s*(?P<why>.*)$")
PROVE_TOTALS = re.compile(r"^Files=(?P<files>\d+), Tests=(?P<tests>\d+),")


class Incomplete(Exception):
    pass


def clean_lines(path: Path) -> list[str]:
    text = path.read_text(errors="replace")
    return [ANSI.sub("", ln).replace("\r", "") for ln in text.split("\n")]


def tap_outcome(m: re.Match) -> str:
    d = (m.group("dir") or "").upper()
    failed = bool(m.group("not"))
    if d == "SKIP":
        return "skip"
    if d == "TODO":
        return "todo" if failed else "todo-pass"
    return "fail" if failed else "pass"


class TapFile:
    """Accumulates one TAP stream (one test script)."""

    def __init__(self, name: str):
        self.name = name
        self.points: dict[int, tuple[str, str]] = {}
        self.plan: int | None = None
        self.skip_all = ""
        self.dupes = 0
        self.bailout: str | None = None

    def feed(self, line: str) -> bool:
        m = TAP_BAIL.match(line)
        if m:
            self.bailout = m.group("why").strip()
            return True
        m = TAP_LINE.match(line)
        if m:
            n = int(m.group("num"))
            detail = (m.group("desc") or "").strip()
            if m.group("dir"):
                detail = f"{detail} # {m.group('dir').upper()} {m.group('why')}".strip()
            outcome = tap_outcome(m)
            if n in self.points:
                # A number reported twice means something other than the
                # suite printed TAP-looking lines. Never let the second
                # report hide a failure; the collectors also refuse the
                # whole cell (incomplete) when this happens.
                self.dupes += 1
                if self.points[n][0] == "fail":
                    return True
            self.points[n] = (outcome, detail)
            return True
        m = TAP_PLAN.match(line)
        if m:
            self.plan = int(m.group("n"))
            self.skip_all = m.group("skip") or ""
            return True
        return False

    def rows(self, exit_code: int | None) -> list[tuple[str, str, str]]:
        if self.plan == 0 and not self.points:
            return [(self.name, "skip", self.skip_all)]
        rows = [(f"{self.name}#{n}", o, d) for n, (o, d) in sorted(self.points.items())]
        if self.bailout is not None:
            # The suite chose to stop: a result in its own right (and one a
            # known issue can name), not a harness failure.
            return rows + [(f"{self.name}#bailout", "fail", self.bailout)]
        if self.plan is None or self.plan != len(self.points):
            rows.append((f"{self.name}#plan", "fail",
                         f"planned {self.plan}, ran {len(self.points)}"))
        if exit_code and not any(o == "fail" for o, _ in self.points.values()):
            rows.append((f"{self.name}#exit", "fail", f"exited {exit_code}"))
        return rows


def prove_totals(lines: list[str]) -> tuple[int, int]:
    for ln in reversed(lines):
        m = PROVE_TOTALS.match(ln)
        if m:
            return int(m.group("files")), int(m.group("tests"))
    raise Incomplete("no prove 'Files=N, Tests=M' summary in suite.log (suite died?)")


def check_no_dupes(files: list[TapFile]) -> None:
    bad = [f.name for f in files if f.dupes]
    if bad:
        raise Incomplete(f"duplicate TAP test numbers in {', '.join(bad[:5])} "
                         f"-- stray TAP-like output interleaved with the suite's?")


def check_tap_totals(files: list[TapFile], lines: list[str]) -> None:
    nfiles, ntests = prove_totals(lines)
    got = sum(len(f.points) for f in files)
    if nfiles != len(files) or ntests != got:
        raise Incomplete(f"prove reports {nfiles} file(s) / {ntests} test(s), "
                         f"parsed {len(files)} / {got}")


# --------------------------------------------------------------------------
# adapters: each returns (rows, version)

def collect_git(cell: Path, lines: list[str], git_t: Path) -> tuple[list, str]:
    """Per-test results from test-results/<script>.tap.

    Those are copies of exactly the TAP stream prove parsed, captured by
    bin/ci/git-prove-exec.sh. Not the --verbose-log .out files next to
    them: those interleave every command's output with the TAP (see that
    script for how that goes wrong).
    """
    results = git_t / "test-results"
    if not results.is_dir():
        raise Incomplete(f"no git test-results directory at {results}")
    files = []
    rows: list[tuple[str, str, str]] = []
    for tap in sorted(results.glob("t[0-9]*.tap")):
        tf = TapFile(tap.name[:-len(".tap")] + ".sh")
        for ln in clean_lines(tap):
            tf.feed(ln)
        ex = tap.with_suffix(".exit")
        code = int(ex.read_text().strip() or 0) if ex.is_file() else None
        files.append(tf)
        rows += tf.rows(code)
    if not files:
        raise Incomplete(f"no t*.tap files under {results} "
                         f"(was the suite run through bin/ci/git-prove-exec.sh?)")
    check_no_dupes(files)
    check_tap_totals(files, lines)
    version = ""
    for ln in lines:
        m = re.match(r"^I: git (\S+) @", ln)
        if m:
            version = f"git {m.group(1)}"
    return rows, version


PROVE_HEADER = re.compile(r"^(?:\[[\d:]+\]\s+)?(?P<file>\S+\.t) \.+\s*$")
# prove pads the file column, so any run of spaces before "(Wstat:".
PROVE_WSTAT = re.compile(r"^(?P<file>\S+\.t)\s+\(Wstat: (?P<wstat>\d+)")


def collect_pjdfstest(cell: Path, lines: list[str]) -> tuple[list, str]:
    def rel(p: str) -> str:
        return p.split("/tests/", 1)[-1]

    files: dict[str, TapFile] = {}
    cur: TapFile | None = None
    last: TapFile | None = None
    in_summary = False
    exit_codes: dict[str, int] = {}
    for ln in lines:
        if ln.startswith("Test Summary Report"):
            in_summary, cur = True, None
            continue
        if in_summary:
            m = PROVE_WSTAT.match(ln)
            if m and int(m.group("wstat")):
                exit_codes[rel(m.group("file"))] = int(m.group("wstat")) >> 8 or 1
            continue
        m = PROVE_HEADER.match(ln)
        if m:
            name = rel(m.group("file"))
            cur = last = files.setdefault(name, TapFile(name))
            continue
        if cur is not None:
            cur.feed(ln)
    if not files:
        raise Incomplete("no `prove -v` per-file output in suite.log")
    check_no_dupes(list(files.values()))
    bail = next((m for m in map(PROVE_BAIL.match, lines) if m), None)
    if bail and last is not None:
        # prove stops right after the file that bailed, so it is the last
        # one it started.
        last.bailout = bail.group("why").strip() or "(no reason given)"
    # A bail-out stops prove before it prints any totals, so there is
    # nothing to cross-check against; the #bailout row carries the verdict.
    if not any(f.bailout is not None for f in files.values()):
        check_tap_totals(list(files.values()), lines)
    rows = []
    for name, tf in files.items():
        rows += tf.rows(exit_codes.get(name))
    version = ""
    for ln in lines:
        m = re.match(r"^I: pjdfstest @ (\S+)", ln)
        if m:
            version = f"pjdfstest {m.group(1)}"
    return rows, version


def collect_stress_ng(cell: Path, lines: list[str]) -> tuple[list, str]:
    tf = TapFile("stress-ng")
    for ln in lines:
        tf.feed(ln)
    if tf.plan is None:
        raise Incomplete("no TAP plan from target-stress-ng.sh (suite died?)")
    if tf.plan != len(tf.points) or tf.dupes:
        raise Incomplete(f"stress-ng TAP planned {tf.plan}, parsed {len(tf.points)}")
    # One stressor is one test, and its TAP description is its name.
    rows = [(d.split()[0] if d else f"stress-ng#{n}", o, d.partition(" ")[2])
            for n, (o, d) in sorted(tf.points.items())]
    version = ""
    for ln in lines:
        m = re.match(r"^I: stress-ng, version (\S+)", ln)
        if m:
            version = f"stress-ng {m.group(1)}"
    return rows, version


TASTY_RESULT = re.compile(r"^(?P<ind> *)(?P<name>\S.*?):\s+(?P<res>OK|FAIL|SKIP)\b")
TASTY_GROUP_SUMMARY = re.compile(
    r"^(?:All (?P<all>\d+) tests passed|(?P<nf>\d+) out of (?P<nt>\d+) tests failed)")
# tasty's own rerun hint; when it is an exact match on the full path it
# is authoritative, so it overrides whatever the indentation suggested.
TASTY_RERUN_PATH = re.compile(r"Use -p '\$0==\"(?P<path>[^\"]+)\"'")
WORST = {"fail": 3, "skip": 2, "pass": 1}


def indent(ln: str) -> int:
    return len(ln) - len(ln.lstrip(" "))


def child_indent(lines: list[str], k: int, ind: int) -> int | None:
    """Indent of the first line after lines[k] that is nested under it.

    Skips the stderr noise that can sit between a group header and its
    first child (at indent <= ind), but gives up at the first sibling or
    ancestor *result*, which proves lines[k] has no children.
    """
    for x in lines[k + 1:k + 50]:
        if not x.strip():
            continue
        i = indent(x)
        if i > ind:
            return i
        if TASTY_RESULT.match(x) or x == "Tests":
            return None
    return None


def collect_git_annex(cell: Path, lines: list[str]) -> tuple[list, str]:
    """Parse tasty's console tree.

    `git annex test` prints several independent tasty runs (it splits the
    suite across subprocesses), each opening with a column-0 `Tests` and
    closing with its own count line. Inside a run, two kinds of noise
    have to be kept out of the group path:

    - git-annex's own stderr ("not enough free space ...", "Detected a
      crippled filesystem.") lands at a group header's indentation. A
      real header is always followed by a line one level (2 spaces)
      deeper; stderr is not, so that lookahead is the test.
    - failure transcripts contain column-0 lines ("failed", progress
      bars). Nothing legitimate inside a run sits at column 0.
    """
    raw: list[list[str]] = []           # [id, outcome]
    stack: list[tuple[int, str]] = []    # (indent, group name)
    msg_indent: int | None = None        # lines deeper than this are messages
    last_failed: int | None = None       # raw index of the latest FAIL/SKIP
    expected_total = expected_failed = groups = 0
    in_run = False
    for k, ln in enumerate(lines):
        m = TASTY_GROUP_SUMMARY.match(ln)
        if m:
            groups += 1
            if m.group("all") is not None:
                expected_total += int(m.group("all"))
            else:
                expected_failed += int(m.group("nf"))
                expected_total += int(m.group("nt"))
            in_run, stack, msg_indent, last_failed = False, [], None, None
            continue
        if ln == "Tests":
            in_run, stack, msg_indent, last_failed = True, [(0, "Tests")], None, None
            continue
        if not in_run or not ln.strip():
            continue
        ind = indent(ln)
        if msg_indent is not None and ind > msg_indent:
            m = TASTY_RERUN_PATH.search(ln)
            if m and last_failed is not None:
                raw[last_failed][0] = m.group("path")
            continue
        if ind == 0:
            continue
        m = TASTY_RESULT.match(ln)
        if m:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            outcome = {"OK": "pass", "FAIL": "fail", "SKIP": "skip"}[m.group("res")]
            raw.append([".".join([g for _, g in stack] + [m.group("name")]), outcome])
            last_failed = len(raw) - 1 if outcome != "pass" else None
            msg_indent = ind
            continue
        if child_indent(lines, k, ind) != ind + 2:
            continue                     # stderr noise, not a group header
        while stack and stack[-1][0] >= ind:
            stack.pop()
        stack.append((ind, ln.strip()))
        msg_indent = last_failed = None
    if not groups:
        raise Incomplete("no tasty 'All N tests passed' / 'N out of M tests failed' "
                         "line in suite.log (suite died?)")
    counted = Counter(o for _, o in raw)
    # tasty counts a SKIP (a test whose dependency failed) as a failure.
    if len(raw) != expected_total or counted["fail"] + counted["skip"] != expected_failed:
        raise Incomplete(f"tasty reports {expected_failed} of {expected_total} failed, "
                         f"parsed {counted['fail']} failed + {counted['skip']} skipped "
                         f"of {len(raw)}")
    # The same path legitimately recurs: each subprocess run re-runs the
    # `Init Tests` its other tests depend on, and a few names repeat
    # within one group. Keep one row per id, with its worst outcome.
    best: dict[str, str] = {}
    for tid, o in raw:
        if WORST[o] > WORST.get(best.get(tid, ""), 0):
            best[tid] = o
    rows = [(tid, o, "") for tid, o in best.items()]
    version = ""
    for ln in lines:
        m = re.match(r"^git-annex version: (\S+)", ln)
        if m:
            version = f"git-annex {m.group(1)}"
    return rows, version


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("cell_dir", type=Path)
    ap.add_argument("--git-t", type=Path,
                    default=Path("/opt/eval-under-src/git/t"))
    a = ap.parse_args()

    log = a.cell_dir / "suite.log"
    rows, version, reason = [], "", ""
    try:
        if not log.is_file():
            raise Incomplete(f"no {log}")
        lines = clean_lines(log)
        if a.target == "git":
            rows, version = collect_git(a.cell_dir, lines, a.git_t)
        elif a.target == "pjdfstest":
            rows, version = collect_pjdfstest(a.cell_dir, lines)
        elif a.target == "stress-ng":
            rows, version = collect_stress_ng(a.cell_dir, lines)
        elif a.target == "git-annex":
            rows, version = collect_git_annex(a.cell_dir, lines)
        else:
            raise Incomplete(f"no results adapter for target {a.target!r}")
    except Incomplete as e:
        reason = str(e)

    ids = Counter(r[0] for r in rows)
    dup = [i for i, n in ids.items() if n > 1]
    if dup and not reason:
        reason = f"{len(dup)} duplicate test id(s), e.g. {dup[0]!r}"

    out = a.cell_dir / "results.tsv"
    with out.open("w") as fh:
        fh.write(f"# target: {a.target}\n")
        fh.write(f"# complete: {'no' if reason else 'yes'}\n")
        if reason:
            fh.write(f"# reason: {reason}\n")
        if version:
            fh.write(f"# version: {version}\n")
        for tid, outcome, detail in rows:
            detail = detail.replace("\t", " ")
            fh.write(f"{tid}\t{outcome}" + (f"\t{detail}" if detail else "") + "\n")
    c = Counter(r[1] for r in rows)
    print(f"I: {out}: {len(rows)} result(s) "
          + " ".join(f"{k}={v}" for k, v in sorted(c.items()))
          + (f" -- INCOMPLETE: {reason}" if reason else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
