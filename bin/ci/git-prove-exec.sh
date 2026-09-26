#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# prove --exec hook for git's testsuite (see bin/ci/target-git.sh): runs
# each test through git's own t/run-test.sh, keeping its TAP -- exactly
# what prove parses -- in test-results/<script>.tap and its exit status in
# <script>.exit, for bin/ci/collect-results.py.
#
# Why not git's own records: --verbose-log's .out files interleave command
# output with the TAP (nested TAP streams, lines glued to "ok N"), and
# --write-junit-xml breaks skip-all scripts (as of v2.55.0).

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: git-prove-exec.sh <test-script> [test options...]
(run by prove, with cwd = git's t/)
USAGE
}

case "${1:-}" in
    ""|-h|--help) usage; exit 2 ;;
    *.sh) ;;
    *) exec ./run-test.sh "$@" ;;       # unit tests: nothing to capture
esac

base="test-results/$(basename "$1" .sh)"
mkdir -p test-results
set +e
./run-test.sh "$@" | tee "$base.tap"
rc=${PIPESTATUS[0]}
set -e
echo "$rc" > "$base.exit"
exit "$rc"
