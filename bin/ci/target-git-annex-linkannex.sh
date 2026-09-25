#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# eval-under *target*: the git-annex operations that go through
# Annex/Content.hs:linkAnnex, looped, reported as a failure rate.
#
# The full `git annex test` suite answers "did anything break?" in
# ~20 minutes and hides how often. This target loops just the two
# commands that hit the inode-cache comparison -- `git annex unlock`
# (linkFromAnnex') and an unlocked `git annex add` (linkToAnnex) --
# so a filesystem that trips it shows up as a percentage in minutes.
# See con/git-annex#293 and bin/ci/target-mtime-stability.sh, which
# measures the same property without git-annex.
#
# Runs INSIDE the eval-under wrapper, i.e. with TMPDIR / HOME already
# pointing at the filesystem under test. Do not invoke directly for CI
# purposes -- go through bin/ci/run-under.sh <backend> <version> \
# git-annex-linkannex.
#
# usage:
#   bin/ci/target-git-annex-linkannex.sh
#
# env (set by eval-under, honoured here):
#   HOME    <mount>/home   -- the repos are created here, so they live
#                             on the filesystem under test
#   TMPDIR  <mount>
#
# env (optional):
#   EVAL_UNDER_LINKANNEX_ROUNDS    rounds per worker (default 200)
#   EVAL_UNDER_LINKANNEX_WORKERS   concurrent repos (default 4)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

ROUNDS="${EVAL_UNDER_LINKANNEX_ROUNDS:-200}"
WORKERS="${EVAL_UNDER_LINKANNEX_WORKERS:-4}"

cd "$HOME"

# Same reason as target-git-annex.sh: --set-home repoints HOME at the
# mount, so the runner's ~/.gitconfig is out of scope and `git commit`
# inside the loop would fail without an identity.
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email test@github.land
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name "GitHub Almighty"

git annex version | head -1

rc=0
# Both directions, reported separately: `unlock` exercises linkAnnex
# From (annex object -> worktree), `add-unlocked` exercises To.
for mode in unlock add-unlocked; do
    echo
    echo "=== mode: $mode"
    "$here/linkannex-loop.sh" --dir "$HOME" --mode "$mode" \
        --rounds "$ROUNDS" --workers "$WORKERS" || rc=1
done
exit "$rc"
