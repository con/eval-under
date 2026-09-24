#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# eval-under *target*: does this filesystem keep a file's stat data
# stable while the file is not being written to?
#
# git-annex records (inode, size, high-resolution mtime) for a file,
# copies it, then stats it again and compares the two exactly; if they
# differ it concludes the file changed under it, deletes the
# destination and fails the operation. On NFS with attribute caching
# the two stats of an *unmodified* file can disagree -- sub-second
# within the same second, or by up to `acregmax` when a cached
# attribute goes stale -- which is what surfaces as "failed to link to
# annex" / "unlock failed" / "content changed while it was being sent".
# See con/git-annex#293.
#
# This target measures that property directly, with no git-annex
# involved, so a red cell says "the filesystem", not "the application".
#
# Runs INSIDE the eval-under wrapper, i.e. with TMPDIR / HOME already
# pointing at the filesystem under test. Do not invoke directly for CI
# purposes -- go through bin/ci/run-under.sh <backend> <version> \
# mtime-stability.
#
# usage:
#   bin/ci/target-mtime-stability.sh
#
# env (set by eval-under, honoured here):
#   HOME    <mount>/home   -- the probe runs here
#   TMPDIR  <mount>
#
# env (optional, for hunting a rare case by hand):
#   EVAL_UNDER_MTIME_ROUNDS   rounds per worker (default 500)
#   EVAL_UNDER_MTIME_JOBS     concurrent workers (default 4)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

ROUNDS="${EVAL_UNDER_MTIME_ROUNDS:-500}"
JOBS="${EVAL_UNDER_MTIME_JOBS:-4}"

cd "$HOME"

# Under load, because the race is a timing one: a single sequential
# worker on an idle mount can miss it for a long time.
exec "$here/mtime-stability.py" --dir "$HOME" --rounds "$ROUNDS" --jobs "$JOBS"
