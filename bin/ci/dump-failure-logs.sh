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
#   bin/ci/dump-failure-logs.sh <backend> <version> [target]
#
# backend side:
#   beegfs:    `docker compose logs` + dmesg-filtered-for-beegfs
#   nfs/loop:  filtered dmesg tail
#   9p-tcp:    filtered dmesg tail (the v9fs client logs there)
#   9p-virtio: tail of the guest console/suite log the backend tees to
#              /var/log/eval-under-9p-virtio.log (guest dmesg included
#              on failure; the guest itself is gone by now)
# target side:
#   git:      the failing assertions + output from t/test-results/*.out

set -uo pipefail

BACKEND="${1:?backend required}"
VERSION="${2:-}"
TARGET="${3:-}"
SRC_DIR="${EVAL_UNDER_SRC_DIR:-/opt/eval-under-src}"

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
    nfs|loop|9p-tcp)
        # Filtered rather than `dmesg | tail -100`: on a hosted runner the
        # last 100 kernel lines are almost entirely boot spam (hyperv, pci,
        # apparmor), which buries the failure in the job log. Warnings and
        # errors plus anything naming the filesystem under test is what
        # actually matters here.
        echo "=== dmesg (warnings and errors, last 40) ==="
        sudo dmesg --level=emerg,alert,crit,err,warn 2>/dev/null | tail -40 || true
        echo "=== dmesg (mentioning $BACKEND/$VERSION, last 30) ==="
        sudo dmesg 2>/dev/null \
            | grep -iE "loop|nfs|9p|${VERSION:-nomatch}" \
            | tail -30 || true
        ;;
    9p-virtio)
        # The suite ran inside a virtme-ng guest that no longer exists;
        # what survives is the console/suite log the backend tees on the
        # host (stage2 appends the guest dmesg tail there on failure).
        log="${EVAL_UNDER_9P_VIRTIO_LOG:-/var/log/eval-under-9p-virtio.log}"
        echo "=== 9p-virtio guest log (last 120 lines of $log) ==="
        if [ -r "$log" ]; then
            tail -120 "$log" || true
        else
            echo "no log at $log (the guest never started?)"
        fi
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        ;;
esac

# git's testsuite runs under `prove` here (see bin/ci/target-git.sh), so
# there are no .counts files -- test-lib.sh only writes those when no TAP
# harness is active. What --verbose-log leaves behind is one .out per
# script, holding that script's full TAP stream.
#
# prove's own Test Summary Report is in the job log above this dump, but
# on a filesystem that fails broadly (vfat) this dump is thousands of
# lines, which scrolls that summary out of reach. So: detail for the
# first few failing scripts, and a compact roll-up printed LAST, so the
# end of the job log always answers "how many, and where" without
# scrolling.
GIT_DUMP_MAX_SCRIPTS="${EVAL_UNDER_GIT_DUMP_MAX_SCRIPTS:-8}"
GIT_DUMP_TAIL_LINES="${EVAL_UNDER_GIT_DUMP_TAIL_LINES:-30}"

if [ "$TARGET" = "git" ]; then
    results="$SRC_DIR/git/t/test-results"
    echo "=== git testsuite failures ($results) ==="
    if [ -d "$results" ]; then
        # Pass 1: which scripts failed, and how badly.
        names=() counts=()
        for out in "$results"/*.out; do
            [ -e "$out" ] || continue
            n="$(grep -c '^not ok ' "$out" 2>/dev/null || true)"
            [ "${n:-0}" -gt 0 ] || continue
            names+=("$(basename "${out%.out}")")
            counts+=("$n")
        done

        if [ "${#names[@]}" -eq 0 ]; then
            echo "no .out file recorded a failure (crash or setup failure?)"
        else
            # Pass 2: detail, for the first few only. The rest are in the
            # uploaded artifact -- dumping 100 scripts inline helps nobody.
            shown=0
            for i in "${!names[@]}"; do
                [ "$shown" -lt "$GIT_DUMP_MAX_SCRIPTS" ] || break
                shown=$((shown + 1))
                out="$results/${names[$i]}.out"
                echo "--- ${names[$i]}: ${counts[$i]} failed ---"
                grep '^not ok ' "$out" | head -40 || true
                echo "  ... last $GIT_DUMP_TAIL_LINES lines of ${names[$i]}.out:"
                tail -"$GIT_DUMP_TAIL_LINES" "$out" | sed 's/^/  | /' || true
                echo
            done
            if [ "${#names[@]}" -gt "$shown" ]; then
                echo "($(( ${#names[@]} - shown )) further failing script(s) not detailed here"
                echo " -- full .out files are in the uploaded logs-* artifact)"
                echo
            fi

            # Pass 3: the roll-up, deliberately last.
            total=0
            echo "=== git testsuite summary: ${#names[@]} script(s) with failures ==="
            for i in "${!names[@]}"; do
                printf '  %-40s %s failed\n' "${names[$i]}" "${counts[$i]}"
                total=$((total + counts[i]))
            done
            echo "  $(printf '%-40s %s' 'TOTAL' "$total") failed assertion(s)"
        fi
    else
        echo "no test-results directory (the suite never started?)"
    fi
fi

exit 0
