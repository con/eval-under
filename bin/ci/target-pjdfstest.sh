#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: pjdfstest, the POSIX filesystem conformance suite.
#
# ~8500 assertions over chmod/chown/link/mkdir/mknod/open/rename/rmdir/
# symlink/truncate/unlink -- i.e. exactly the syscalls whose corner cases
# (EEXIST vs ENOTEMPTY, sticky-bit rules, ctime updates, rename-onto-open-fd)
# break git-annex on network filesystems. Where `git annex test` says
# "something is wrong", pjdfstest says which syscall and which errno.
#
# Runs INSIDE the eval-under wrapper, and must run as root: most of the
# suite is about privileged-vs-unprivileged behaviour and it refuses to
# produce meaningful results otherwise.
#
# Go through bin/ci/run-under.sh <backend> <version> pjdfstest.
#
# usage:
#   bin/ci/target-pjdfstest.sh
#
# env:
#   EVAL_UNDER_SRC_DIR         where install-target.sh built pjdfstest
#   EVAL_UNDER_PJDFSTEST_ARGS  extra `prove` args (default: -r, add -v
#                              for the per-assertion firehose)
#   TMPDIR                     <mount> -- the suite runs with cwd here

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

SRC="$EVAL_UNDER_SRC_DIR/pjdfstest"
PROVE_ARGS="${EVAL_UNDER_PJDFSTEST_ARGS:--r}"

[ -x "$SRC/pjdfstest" ] || {
    echo "ERROR: no pjdfstest build at $SRC -- run bin/ci/install-target.sh pjdfstest first" >&2
    exit 3
}
[ "$(id -u)" -eq 0 ] || {
    echo "ERROR: pjdfstest must run as root (privileged-vs-not is half the suite)" >&2
    exit 3
}
command -v prove >/dev/null || {
    echo "ERROR: prove(1) not found -- install perl" >&2
    exit 3
}

# The suite operates on the current working directory, so cwd *is* the
# filesystem under test. A dedicated subdirectory keeps its debris away
# from anything else the mount holds.
work="${TMPDIR:-/tmp}/pjdfstest"
mkdir -p "$work"
cd "$work"

echo "I: pjdfstest @ ${EVAL_UNDER_PJDFSTEST_REF} ($SRC)"
echo "I: running in $work on $(stat -f -c %T . 2>/dev/null || echo 'unknown fs')"

# prove exits non-zero if any assertion fails. Failures on a crippled
# filesystem (vfat has no ownership, no symlinks, no sub-second times)
# are expected and are the signal, not a flake.
# shellcheck disable=SC2086  # $PROVE_ARGS is a deliberate option list
exec prove $PROVE_ARGS "$SRC/tests"
