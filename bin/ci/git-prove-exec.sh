#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# prove --exec hook for git's testsuite: run each test exactly as git's
# own t/run-test.sh would, and keep a copy of its stdout -- the TAP
# stream prove itself parses -- in test-results/<script>.tap.
#
# Why: that stream is the only clean per-test record. --verbose-log's
# test-results/<script>.out mixes in every command's output (a test that
# runs its own TAP producer, like t0202's Test::More script, adds a second
# numbering; output lacking a final newline glues onto the next "ok N"
# line), and git's --write-junit-xml breaks scripts that skip everything
# (v2.55.0 calls an undefined write_junit_xml_testcase).
#
# Wired in by bin/ci/target-git.sh via GIT_PROVE_OPTS="--exec <this>";
# prove honours the last --exec, overriding the Makefile's ./run-test.sh.
# Runs with cwd = git's t/ directory, like run-test.sh.
#
# usage:
#   git-prove-exec.sh <test-script> [test options...]

set -euo pipefail

usage() {
    sed -n '/^# usage:/,/^$/{s/^# \{0,1\}//;p}' "$0"
}

case "${1:-}" in
    ""|-h|--help) usage; exit 2 ;;
    *.sh) ;;
    *) exec ./run-test.sh "$@" ;;       # unit tests: nothing to capture
esac

name="${1##*/}"
mkdir -p test-results
# pipefail: prove must see the test's own exit status, not tee's.
./run-test.sh "$@" | tee "test-results/${name%.sh}.tap"
