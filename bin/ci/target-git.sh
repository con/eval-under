#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: a subset of git's own testsuite.
#
# Rationale: git-annex sits on top of git plumbing, so a filesystem that
# breaks git's index/refs/object handling breaks git-annex in ways that
# `git annex test` reports only indirectly. Git's suite is the canonical
# filesystem-picky testbed and is far more rigorously maintained than
# anything we could hand-write.
#
# The git build lives on the runner's disk (bin/ci/install-target.sh);
# only the trash directories -- where every test's actual file operation
# happens -- are placed on the filesystem under test, via the suite's
# own `--root` option.
#
# Runs INSIDE the eval-under wrapper. Go through
# bin/ci/run-under.sh <backend> <version> git.
#
# usage:
#   bin/ci/target-git.sh
#
# env:
#   EVAL_UNDER_SRC_DIR    where install-target.sh built git
#   EVAL_UNDER_GIT_TESTS  glob(s) selecting the subset, evaluated inside
#                         git's t/ directory. Default: 't0*.sh t1*.sh'
#                         -- 174 scripts / ~10k assertions covering
#                         plumbing (t0xxx: init, index, attributes,
#                         object store) and the porcelain layer built
#                         straight on it (t1xxx: refs, config, fsck,
#                         worktrees, sparse-checkout). That is exactly
#                         the layer git-annex stands on, and it runs in
#                         under two minutes on ext4. Space-separated
#                         globs, e.g. 't00*.sh t13*.sh', to narrow it.
#   EVAL_UNDER_GIT_JOBS   parallel test jobs (default: nproc)
#   TMPDIR                <mount> -- trash directories go under here

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

SRC="$EVAL_UNDER_SRC_DIR/git"
TESTS_GLOB="${EVAL_UNDER_GIT_TESTS:-t0*.sh t1*.sh}"
JOBS="${EVAL_UNDER_GIT_JOBS:-$(nproc)}"

[ -x "$SRC/git" ] || {
    echo "ERROR: no git build at $SRC -- run bin/ci/install-target.sh git first" >&2
    exit 3
}

# Trash directories (one per test script) on the filesystem under test.
root="${TMPDIR:-/tmp}/git-testsuite"
mkdir -p "$root"

# Expand the glob ourselves inside t/ and hand `make` an explicit list.
# Passing the raw glob as T= happens to work via GNU make's wildcard
# expansion of prerequisites, but an explicit list fails loudly (empty
# selection) instead of silently running the whole suite.
cd "$SRC/t"
shopt -s nullglob
# shellcheck disable=SC2206  # deliberate word-split + glob of the pattern
selected=( $TESTS_GLOB )
shopt -u nullglob

if [ "${#selected[@]}" -eq 0 ]; then
    echo "ERROR: EVAL_UNDER_GIT_TESTS='$TESTS_GLOB' matched no tests in $SRC/t" >&2
    exit 3
fi

echo "I: git $("$SRC/git" --version | awk '{print $3}') @ ${EVAL_UNDER_GIT_REF}"
echo "I: ${#selected[@]} test scripts selected by '$TESTS_GLOB'"
echo "I: trash directories under $root"

# `make -C t` runs each selected script and aggregates. --root puts the
# per-test trash directory on the mount; test-results/ stays on the
# runner disk (it is bookkeeping, not filesystem exercise).
#
# Note: the suite runs as root here (eval-under needs root to mount), so
# git's SANITY prerequisite is off and the handful of tests asserting
# "cannot write to a chmod-000 path" are skipped upstream-style rather
# than failing.
exec make -j"$JOBS" T="${selected[*]}" GIT_TEST_OPTS="--root=$root"
