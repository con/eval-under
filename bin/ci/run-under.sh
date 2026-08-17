#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Invoke `bin/eval-under BACKEND [OPTS] --set-home` around a full
# `git annex test` run. Handles the per-backend option translation
# (--version for beegfs, --fs for loop, nothing for nfs) so the
# workflow YAML doesn't need a case.
#
# usage:
#   bin/ci/run-under.sh <backend> <version>
#
# Runs as the current user; expects to be launched under sudo when the
# backend requires root (beegfs/loop mount, NFS server bring-up).

set -euo pipefail

BACKEND="${1:?backend required}"
VERSION="${2:?version required}"

opts=()
case "$BACKEND" in
    beegfs) opts=(--version "$VERSION") ;;
    loop)   opts=(--fs "$VERSION") ;;
    nfs)    opts=() ;;
    *) echo "unknown backend: $BACKEND" >&2; exit 1 ;;
esac

# Sudo is expected to be in place already (workflow uses `sudo -E`); the
# script itself just forwards. Timeout keeps runaway `git annex test`
# invocations from hitting the workflow-level timeout with no signal.
# The single-quoted bash -c body is deliberate: $HOME must expand in the
# eval-under-launched child shell (where HOME=<mount>/home), not here.
# shellcheck disable=SC2016
exec ./bin/eval-under "$BACKEND" "${opts[@]}" --set-home -- \
    timeout 2400 bash -c 'cd "$HOME" && git annex version | head -1 && git annex test'
