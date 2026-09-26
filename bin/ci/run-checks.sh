#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# The repo's own checks: shellcheck over every script we ship, plus the
# bats suite for the CLI entry point. Neither needs root, a mount, or a
# backend -- this is the fast layer under the filesystem matrix, and the
# same command CI runs.
#
# usage:
#   bin/ci/run-checks.sh [what]
#
#   what = all | shellcheck | bats     (default: all)
#
# env overrides:
#   SHELLCHECK   shellcheck binary to use   (shellcheck)
#   BATS         bats binary to use         (bats)
#
# Installs nothing; see bin/ci/install-check-deps.sh for the runner-side
# apt step. Both tools are packaged: `apt-get install shellcheck bats`.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

WHAT="${1:-all}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
BATS="${BATS:-bats}"

case "$WHAT" in
  all|shellcheck|bats) ;;
  *) echo "unknown argument: $WHAT (expected: all|shellcheck|bats)" >&2; exit 2 ;;
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
  # Every tracked sh/bash script, found by shebang rather than by glob
  # (bin/ci/shellcheck.sh). The .bats files are not picked up: their
  # `#!/usr/bin/env bats` is no shell shebang, and shellcheck cannot
  # parse bats' @test syntax anyway.
  ( cd "$root" && SHELLCHECK="$SHELLCHECK" "$here/shellcheck.sh" )
}

run_bats() {
  need "$BATS" bats || return 1
  log "bats"
  ( cd "$root" && "$BATS" tests/ )
}

rc=0
case "$WHAT" in
  all)        run_shellcheck || rc=1; run_bats || rc=1 ;;
  shellcheck) run_shellcheck || rc=1 ;;
  bats)       run_bats || rc=1 ;;
esac

[ "$missing" -eq 0 ] || echo "(some checks were skipped: see above)" >&2
exit "$rc"
