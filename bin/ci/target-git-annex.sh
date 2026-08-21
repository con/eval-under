#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: the full `git annex test` suite.
#
# Runs INSIDE the eval-under wrapper, i.e. with TMPDIR / HOME already
# pointing at the filesystem under test. Do not invoke directly for CI
# purposes -- go through bin/ci/run-under.sh <backend> <version> git-annex.
#
# usage:
#   bin/ci/target-git-annex.sh
#
# env (set by eval-under, honoured here):
#   HOME    <mount>/home   -- the suite runs here, so every repo it
#                             creates lives on the filesystem under test
#   TMPDIR  <mount>

set -euo pipefail

cd "$HOME"

# `git annex test` builds real repos and needs a committer identity. The
# workflow configures one for the runner user, but eval-under --set-home
# repoints HOME at the mount, so the runner's ~/.gitconfig is out of
# scope. Seed one here rather than depend on the caller's HOME.
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email test@github.land
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name "GitHub Almighty"

git annex version | head -1

exec git annex test
