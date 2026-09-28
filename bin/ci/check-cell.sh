#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Judge one cell's run (after bin/ci/run-under.sh) against
# evals/known-issues.yaml; the exit status is the job's verdict.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: bin/ci/check-cell.sh <backend> <version> <target>

env overrides:
  EVAL_UNDER_OUTPUT_DIR   the cell's output dir (default: see matrix.sh)
  EVAL_UNDER_SRC_DIR      where install-target.sh built the suites
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[ $# -eq 3 ] || { usage >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

out="$(cell_output_dir "$1" "$2" "$3")"
mkdir -p "$out"

# A collector crash leaves no results.tsv, which the check reports as incomplete.
rm -f "$out/results.tsv"
"$here/collect-results.py" "$3" "$out" --git-t "$EVAL_UNDER_SRC_DIR/git/t" \
    || echo "W: collect-results.py exited $?" >&2
exec "$here/known_issues.py" check "$1" "$2" "$3" "$out"
