#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# The repo's own checks: shellcheck over every script we ship, the bats
# suite for the CLI entry point, the known-issues file (and the GOTCHAS.md
# section generated from it), and unit tests of the bin/ci Python. None
# needs root, a mount, or a backend -- this is the fast layer under the
# filesystem matrix, and the same command CI runs.
#
# usage:
#   bin/ci/run-checks.sh [what]
#
#   what = all | shellcheck | bats | known-issues | unit   (default: all)
#
# env overrides:
#   SHELLCHECK   shellcheck binary to use   (shellcheck)
#   BATS         bats binary to use         (bats)
#
# Installs nothing; see bin/ci/install-check-deps.sh for the runner-side
# apt step: `apt-get install shellcheck bats python3-yaml`.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

WHAT="${1:-all}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
BATS="${BATS:-bats}"

case "$WHAT" in
  all|shellcheck|bats|known-issues|unit) ;;
  *) echo "unknown argument: $WHAT (expected: all|shellcheck|bats|known-issues|unit)" >&2
     exit 2 ;;
esac

log() { printf '\nI: %s\n' "$*"; }

missing=0
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "ERROR: $1 not found in PATH. Install with: apt-get install $2" >&2
  missing=1
  return 1
}

run_shellcheck() {
  need "$SHELLCHECK" shellcheck || return 1
  log "shellcheck"
  # .bats files have a bats shebang, so shellcheck.sh leaves them out.
  ( cd "$root" && SHELLCHECK="$SHELLCHECK" "$here/shellcheck.sh" )
}

run_bats() {
  need "$BATS" bats || return 1
  log "bats"
  ( cd "$root" && "$BATS" tests/ )
}

run_known_issues() {
  log "known issues"
  "$here/known_issues.py" validate --gotchas
}

run_unit() {
  log "unit tests"
  ( cd "$root" && python3 -m unittest discover -s tests -p 'test_*.py' )
}

rc=0
case "$WHAT" in
  all)
    run_shellcheck || rc=1
    run_bats || rc=1
    run_known_issues || rc=1
    run_unit || rc=1 ;;
  shellcheck)   run_shellcheck || rc=1 ;;
  bats)         run_bats || rc=1 ;;
  known-issues) run_known_issues || rc=1 ;;
  unit)         run_unit || rc=1 ;;
esac

[ "$missing" -eq 0 ] || echo "(some checks were skipped: see above)" >&2
exit "$rc"
