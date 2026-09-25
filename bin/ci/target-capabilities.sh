#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: the capability profile, nothing else.
#
# Runs INSIDE the eval-under wrapper. This is the on-demand target: when
# someone reports "git-annex misbehaves on my $FILESYSTEM", this answers
# "what does that filesystem actually support?" in seconds, and usually
# narrows the search before a multi-minute suite is worth starting.
#
# Not part of the scheduled backends x targets matrix -- see
# EVAL_UNDER_ONDEMAND_TARGETS in bin/ci/matrix.sh.
#
# usage:
#   bin/ci/target-capabilities.sh
#
# env (set by eval-under, honoured here):
#   TMPDIR  <mount>  -- the filesystem to profile

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

echo "I: capability profile of ${TMPDIR:?TMPDIR not set by eval-under}"
exec "$here/fs-capabilities.sh" "$TMPDIR"
