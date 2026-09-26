#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Judge one cell's run against evals/known-issues.yaml: turn the
# suite's output into per-test results (collect-results.py), then
# classify them (known_issues.py check). The exit status is the job's
# verdict: 0 when every failure is covered by a known issue, 1 on a new
# failure or a run that did not complete.
#
# Run after bin/ci/run-under.sh, which leaves suite.log and suite.rc in
# the cell's output directory. Works without them, too (a suite that
# never ran is "incomplete", i.e. red).
#
# usage:
#   bin/ci/check-cell.sh <backend> <version> <target>
#
# env overrides:
#   EVAL_UNDER_OUTPUT_DIR   the cell's output dir (default: see matrix.sh)
#   EVAL_UNDER_SRC_DIR      where install-target.sh built the suites
#                           (git's test-results/ is read from there)
#
# Writes <output-dir>/results.tsv and verdict.json, and appends a summary
# to $GITHUB_STEP_SUMMARY when set.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

usage() {
    sed -n '/^# usage:/,/^# Writes/{s/^# \{0,1\}//;p}' "$0"
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

BACKEND="${1:?backend required}"
VERSION="${2:?version required}"
TARGET="${3:?target required}"

out="$(cell_output_dir "$BACKEND" "$VERSION" "$TARGET")"
mkdir -p "$out"

"$here/collect-results.py" "$TARGET" "$out" \
    --git-t "$EVAL_UNDER_SRC_DIR/git/t"
exec "$here/known_issues.py" check "$BACKEND" "$VERSION" "$TARGET" "$out"
