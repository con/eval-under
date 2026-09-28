#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# The repo's own checks. None needs root, a mount, or a backend -- this is
# the fast layer under the filesystem matrix, and the same command CI
# runs. Installs nothing; see bin/ci/install-check-deps.sh.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: bin/ci/run-checks.sh [all | <check>]   (default: all)

checks:
  shellcheck     every shell script we ship (bin/ci/shellcheck.sh)
  pyflakes       every Python script under bin/ci and tests
  bats           the CLI entry point (tests/*.bats)
  known-issues   evals/known-issues.yaml, and GOTCHAS.md generated from it
  unit           unit tests of the bin/ci Python (tests/test_*.py)

env overrides:
  SHELLCHECK   shellcheck binary (default: shellcheck)
  PYFLAKES     pyflakes binary   (default: pyflakes3)
  BATS         bats binary       (default: bats)
USAGE
}

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

WHAT="${1:-all}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
PYFLAKES="${PYFLAKES:-pyflakes3}"
BATS="${BATS:-bats}"

case "$WHAT" in
    -h|--help) usage; exit 0 ;;
    all|shellcheck|pyflakes|bats|known-issues|unit) ;;
    *) usage >&2; exit 2 ;;
esac

log() { printf '\nI: %s\n' "$*"; }

missing=0
need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    echo "ERROR: $1 not found in PATH; see bin/ci/install-check-deps.sh" >&2
    missing=1
    return 1
}

run_shellcheck() {
    need "$SHELLCHECK" || return 1
    log "shellcheck"
    ( cd "$root" && SHELLCHECK="$SHELLCHECK" "$here/shellcheck.sh" )
}

run_pyflakes() {
    need "$PYFLAKES" || return 1
    log "pyflakes"
    ( cd "$root" && "$PYFLAKES" bin/ci/*.py tests/*.py )
}

run_bats() {
    need "$BATS" || return 1
    log "bats"
    ( cd "$root" && "$BATS" tests/ )
}

run_known_issues() {
    need python3 || return 1
    log "known issues"
    "$here/known_issues.py" validate
}

run_unit() {
    need python3 || return 1
    log "unit tests"
    ( cd "$root" && python3 -m unittest discover -s tests -p 'test_*.py' )
}

want() { [ "$WHAT" = all ] || [ "$WHAT" = "$1" ]; }

rc=0
if want shellcheck;   then run_shellcheck   || rc=1; fi
if want pyflakes;     then run_pyflakes     || rc=1; fi
if want bats;         then run_bats         || rc=1; fi
if want known-issues; then run_known_issues || rc=1; fi
if want unit;         then run_unit         || rc=1; fi

[ "$missing" -eq 0 ] || echo "(some checks were skipped: see above)" >&2
exit "$rc"
