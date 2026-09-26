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
#   backend = beegfs | nfs | loop
#   version = for beegfs: point release (e.g. 7.4.6, 8.1.0)
#             for loop:   filesystem type (e.g. vfat, ext4)
#             for nfs:    literal "n/a"
#   target  = git-annex (default) | git | stress-ng | pjdfstest
#
# env overrides:
#   EVAL_UNDER_TIMEOUT         seconds for the wrapped suite
#   EVAL_UNDER_LOOP_SIZE_MB    loop backing image size
#   EVAL_UNDER_SRC_DIR         where install-target.sh built the suites
#   EVAL_UNDER_OUTPUT_DIR      the cell's output dir (see matrix.sh)
#
# Exits with the suite's own status.
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
    *) echo "unknown backend: $BACKEND" >&2; exit 1 ;;
esac

runner="$here/target-$TARGET.sh"
[ -x "$runner" ] || { echo "no target runner at $runner" >&2; exit 1; }

echo "I: $(target_label "$TARGET") under $BACKEND/$VERSION (timeout ${TIMEOUT}s)"

out="$(cell_output_dir "$BACKEND" "$VERSION" "$TARGET")"
mkdir -p "$out"
rm -f "$out/suite.rc" "$out/results.tsv" "$out/verdict.json"
# We run under sudo, but the checker that reads and adds to this directory
# runs as the invoking user. Hand the directory over now, not at the end,
# so the checker can still write its verdict if this script is killed.
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"
fi

# Sudo is expected to be in place already (workflow uses `sudo -E`); the
# script itself just forwards. The timeout keeps a runaway suite from
# hitting the workflow-level timeout with no signal of its own.
set +e
# stdout only: every suite reports there, and merging stderr would splice
# tool messages into half-written result lines (tasty's "name: ... OK").
"$here/../eval-under" "$BACKEND" "${opts[@]}" --set-home -- \
    timeout "$TIMEOUT" "$runner" | tee "$out/suite.log"
rc=${PIPESTATUS[0]}
set -e
echo "$rc" > "$out/suite.rc"

# Only the files this script wrote: $out may be an override
# (EVAL_UNDER_OUTPUT_DIR survives `sudo -E`), so no recursive chown.
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out/suite.log" "$out/suite.rc"
fi
exit "$rc"
