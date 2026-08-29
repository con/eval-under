#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Invoke `bin/eval-under BACKEND [OPTS] --set-home` around one of the
# test targets in bin/ci/target-<target>.sh. Handles the per-backend
# option translation (--version for beegfs, --fs/--size for loop,
# nothing for nfs) and the per-target timeout, so the workflow YAML
# doesn't need a case.
#
# usage:
#   bin/ci/run-under.sh <backend> <version> [target]
#
#   backend = beegfs | nfs | loop | sshfs
#   version = for beegfs: point release (e.g. 7.4.6, 8.1.0)
#             for loop:   filesystem type (e.g. vfat, ext4)
#             for nfs:    literal "n/a"
#             for sshfs:  literal "n/a"
#   target  = git-annex (default) | git | stress-ng | pjdfstest
#
# env overrides:
#   EVAL_UNDER_TIMEOUT         seconds for the wrapped suite
#   EVAL_UNDER_LOOP_SIZE_MB    loop backing image size
#   EVAL_UNDER_SRC_DIR         where install-target.sh built the suites
#   EVAL_UNDER_BACKEND_OPTS    extra backend flags, word-split (e.g.
#                              "--no-cache --workaround rename"). Used by
#                              the on-demand reproduce workflow.
#
# Runs as the current user; expects to be launched under sudo when the
# backend requires root (beegfs/loop mount, NFS server bring-up).

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

BACKEND="${1:?backend required}"
VERSION="${2:?version required}"
TARGET="${3:-git-annex}"

target_known "$TARGET" || {
    echo "unknown target: $TARGET (expected: ${EVAL_UNDER_TARGETS[*]})" >&2
    exit 1
}

# The target scripts re-derive their own defaults from matrix.sh, but an
# override handed to us must survive into the wrapped child.
export EVAL_UNDER_SRC_DIR

TIMEOUT="${EVAL_UNDER_TIMEOUT:-$(target_timeout "$TARGET")}"

opts=()
case "$BACKEND" in
    beegfs) opts=(--version "$VERSION") ;;
    loop)   opts=(--fs "$VERSION"
                  --size "${EVAL_UNDER_LOOP_SIZE_MB:-$(target_loop_size_mb "$TARGET")}") ;;
    nfs)    opts=()
            # See target_needs_root() in matrix.sh: root-requiring suites
            # need an export that does not squash root, and need to keep
            # their privileges rather than being dropped to the invoker.
            target_needs_root "$TARGET" && opts=(--no-root-squash) ;;
    sshfs)  opts=() ;;
    *) echo "unknown backend: $BACKEND" >&2; exit 1 ;;
esac

# Caller-supplied backend flags, deliberately word-split: this is how the
# reproduce workflow passes a reporter's exact mount options through.
if [ -n "${EVAL_UNDER_BACKEND_OPTS:-}" ]; then
    # shellcheck disable=SC2206  # word-splitting is the point
    opts+=(${EVAL_UNDER_BACKEND_OPTS})
fi

runner="$here/target-$TARGET.sh"
[ -x "$runner" ] || { echo "no target runner at $runner" >&2; exit 1; }

echo "I: $(target_label "$TARGET") under $BACKEND/$VERSION (timeout ${TIMEOUT}s)"

# Sudo is expected to be in place already (workflow uses `sudo -E`); the
# script itself just forwards. The timeout keeps a runaway suite from
# hitting the workflow-level timeout with no signal of its own.
exec "$here/../eval-under" "$BACKEND" "${opts[@]}" --set-home -- \
    timeout "$TIMEOUT" "$runner"
