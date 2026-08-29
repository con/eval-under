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
#   backend = beegfs | nfs | loop | 9p-tcp | 9p-virtio
#   version = for beegfs:    point release (e.g. 7.4.6, 8.1.0)
#             for loop:      filesystem type (e.g. vfat, ext4)
#             for nfs:       literal "n/a"
#             for 9p-tcp:    literal "n/a"
#             for 9p-virtio: QEMU virtfs security model row
#                            (mapped -> mapped-xattr, passthrough)
#   target  = git-annex (default) | git | stress-ng | pjdfstest
#
# env overrides:
#   EVAL_UNDER_TIMEOUT         seconds for the wrapped suite
#   EVAL_UNDER_LOOP_SIZE_MB    loop backing image size
#   EVAL_UNDER_SRC_DIR         where install-target.sh built the suites
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
    9p-tcp)
            opts=()
            # Same shape as NFS: the default is diod's single-user mode
            # with the command dropped to the invoker; root-requiring
            # suites need the multi-user export and their privileges.
            target_needs_root "$TARGET" && opts=(--run-as-root) ;;
    9p-virtio)
            # The version token is the QEMU virtfs security-model row.
            case "$VERSION" in
                mapped)      secmodel=mapped-xattr ;;
                passthrough) secmodel=passthrough ;;
                *) echo "unknown 9p-virtio variant: $VERSION" >&2; exit 1 ;;
            esac
            # Pinned guest kernel: handed over explicitly, so the backend
            # stays matrix-free and defaults to the host kernel locally.
            # The VM timeout guards boot/mount hangs the in-guest
            # per-target timeout cannot see; memory is CI-sized (the
            # script's own default suits laptops).
            opts=(--security-model "$secmodel"
                  --kernel "$EVAL_UNDER_9P_KERNEL_REF"
                  --memory 4G
                  --vm-timeout $((TIMEOUT + 300)))
            # Suites that write results onto the runner's disk (git's
            # t/test-results) need that dir shared read-write into the
            # guest; everything else in the guest's overlay evaporates.
            [ -d "$EVAL_UNDER_SRC_DIR" ] && opts+=(--share-rw "$EVAL_UNDER_SRC_DIR")
            target_needs_root "$TARGET" && opts+=(--run-as-root) ;;
    *) echo "unknown backend: $BACKEND" >&2; exit 1 ;;
esac

runner="$here/target-$TARGET.sh"
[ -x "$runner" ] || { echo "no target runner at $runner" >&2; exit 1; }

echo "I: $(target_label "$TARGET") under $BACKEND/$VERSION (timeout ${TIMEOUT}s)"

# Sudo is expected to be in place already (workflow uses `sudo -E`); the
# script itself just forwards. The timeout keeps a runaway suite from
# hitting the workflow-level timeout with no signal of its own.
exec "$here/../eval-under" "$BACKEND" "${opts[@]}" --set-home -- \
    timeout "$TIMEOUT" "$runner"
