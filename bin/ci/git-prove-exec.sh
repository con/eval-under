#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# prove --exec hook for git's testsuite (see bin/ci/target-git.sh): runs
# each test through git's own t/run-test.sh, keeping its TAP -- exactly
# what prove parses -- in test-results/<script>.tap for
# bin/ci/collect-results.py. The exit status beside it,
# test-results/<script>.exit, git writes itself (--verbose-log implies
# --tee).
#
# Why not git's own .out: --verbose-log interleaves command output with
# the TAP there, and --write-junit-xml breaks skip-all scripts (as of
# v2.55.0).

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: git-prove-exec.sh <test-script> [test options...]
(run by prove, with cwd = git's t/)
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    *.sh) ;;
    *) usage >&2; exit 2 ;;
esac

mkdir -p test-results
./run-test.sh "$@" | tee "test-results/$(basename "$1" .sh).tap"
