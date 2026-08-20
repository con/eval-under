#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# On-failure log dump for the CI. Never fails (all commands guarded
# with `|| true`) so it can safely be a workflow `if: failure()` step
# without masking the underlying failure.
#
# usage:
#   bin/ci/dump-failure-logs.sh <backend> <version>
#
# beegfs: `docker compose logs` + dmesg-filtered-for-beegfs
# nfs/loop: full dmesg tail

set -uo pipefail

BACKEND="${1:?backend required}"
VERSION="${2:-}"

case "$BACKEND" in
    beegfs)
        major="${VERSION%%.*}"
        compose_file="fixtures/beegfs/docker-compose-v${major}.yml"
        if [ -f "$compose_file" ]; then
            echo "=== docker compose logs ($compose_file) ==="
            sudo -E docker compose -f "$compose_file" logs --tail=500 || true
        else
            echo "=== compose file $compose_file not found (skipping) ==="
        fi
        echo "=== dmesg (beegfs-tagged, last 50) ==="
        sudo dmesg | grep -i beegfs | tail -50 || true
        ;;
    nfs|loop)
        echo "=== dmesg (last 100) ==="
        sudo dmesg | tail -100 || true
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        ;;
esac

exit 0
