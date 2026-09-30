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
#   EVAL_UNDER_LINKANNEX_ROUNDS    rounds per worker (default 50)
#   EVAL_UNDER_LINKANNEX_WORKERS   concurrent repos (default 4)
#
# 50 x 4 = 200 rounds per mode. Sized by the slowest backend: BeeGFS
# 8.1.0 took 967s for one mode at 200 x 4 (con/eval-under#11, run
# 36776837242), so two modes did not fit the 1200s budget and the cell
# timed out with only mode 1 reported -- while NFS, ext4 and vfat each
# finished a mode in 100-200s. A quarter of the rounds brings BeeGFS to
# roughly 240s per mode and keeps this target's point: a rate in
# minutes, not a pass/fail after twenty.
#
# The cost is detection power, and it is the reason to raise this rather
# than the timeout when hunting something rare: 200 rounds per mode will
# not reliably show a failure rate below ~1%. For that, run the loop by
# hand with more rounds (bin/ci/linkannex-loop.sh -n) instead of waiting
# on a matrix cell.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

ROUNDS="${EVAL_UNDER_LINKANNEX_ROUNDS:-50}"
WORKERS="${EVAL_UNDER_LINKANNEX_WORKERS:-4}"

cd "$HOME"

# Same reason as target-git-annex.sh: --set-home repoints HOME at the
# mount, so the runner's ~/.gitconfig is out of scope and `git commit`
# inside the loop would fail without an identity.
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email test@github.land
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name "GitHub Almighty"

# As a TAP comment: everything this target prints but the plan and the
# points has to be a comment, or the collector would try to read it.
git annex version | head -1 | sed 's/^/# /'

# Both directions, reported separately: `unlock` exercises linkAnnex
# From (annex object -> worktree), `add-unlocked` exercises To. Each
# mode becomes one TAP point, named after the mode so the id is stable
# and a known issue can name it; bin/ci/collect-results.py scores them.
reportdir="$(mktemp -d)"
trap 'rm -rf "$reportdir"' EXIT

modes=(unlock add-unlocked)
rc=0
for mode in "${modes[@]}"; do
    echo "# === mode: $mode"
    # pipefail is on and sed always succeeds, so the pipeline's status is
    # the loop's own -- including its exit 4 for "out of space".
    loop_rc=0
    "$here/linkannex-loop.sh" --dir "$HOME" --mode "$mode" \
        --rounds "$ROUNDS" --workers "$WORKERS" \
        --report "$reportdir/$mode" 2>&1 | sed 's/^/# /' || loop_rc=$?
    if [ "$loop_rc" = 4 ]; then
        # Out of space. Exit without a plan, so the cell comes out
        # "incomplete" (a harness problem, which it is) rather than
        # pinning a verdict on the filesystem that the run cannot
        # support -- see the exit-status list in linkannex-loop.sh.
        echo "# ABORT: $mode ran out of disk space; no verdict from this cell"
        exit 4
    fi
    [ "$loop_rc" = 0 ] || rc=1
done

echo "1..${#modes[@]}"
n=0
for mode in "${modes[@]}"; do
    n=$((n + 1))
    if [ -r "$reportdir/$mode" ]; then
        read -r failures total < "$reportdir/$mode"
    else
        failures=; total=
    fi
    if [ -z "${total:-}" ]; then
        # The loop died before reporting: a result, not a harness error.
        echo "not ok $n - $mode loop did not report (died before finishing?)"
        rc=1
    elif [ "$failures" -eq 0 ]; then
        echo "ok $n - $mode 0/$total rounds failed"
    else
        pct="$(awk -v a="$failures" -v b="$total" 'BEGIN{printf "%.2f", b ? 100*a/b : 0}')"
        echo "not ok $n - $mode $failures/$total rounds failed ($pct%)"
    fi
done
exit "$rc"
