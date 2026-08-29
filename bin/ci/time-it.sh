#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Stopwatch wrapper: run CMD, append "<seconds>\t<exit code>" to FILE,
# and exit with CMD's own status.
#
# Exists so bin/ci/bench-matrix.sh can time the *suite* rather than the
# whole cell. It is invoked INSIDE the eval-under wrapper (see the
# EVAL_UNDER_TIME_FILE hook in bin/ci/run-under.sh), so everything the
# backend does around the suite -- dd + mkfs for loop, the BeeGFS
# container cluster's ~60s bring-up, the NFS export and mount, teardown
# -- falls outside the measured window. Comparing "how slow is `git
# annex test` on this filesystem" across backends is meaningless if a
# minute of cluster boot is folded into one of the numbers.
#
# usage:
#   bin/ci/time-it.sh <file> CMD [ARGS...]
#
# FILE must already exist and be writable by whoever CMD ends up running
# as: the NFS backend drops back to the invoking user for the wrapped
# command, so a root-created file needs to be world-writable.
# bench-matrix.sh creates it that way.
#
# Appends rather than truncates, so a caller that reuses one file across
# runs gets one line per run.

set -uo pipefail

FILE="${1:?output file required}"
shift
[ $# -gt 0 ] || { echo "time-it.sh: no command given" >&2; exit 2; }

now() {
    # bash 5 exposes EPOCHREALTIME without a fork. It is locale-formatted,
    # so a decimal comma is possible; normalise it. date(1) is the
    # fallback for anything older.
    if [ -n "${EPOCHREALTIME:-}" ]; then
        echo "${EPOCHREALTIME/,/.}"
    else
        date +%s.%N
    fi
}

start="$(now)"
"$@"
rc=$?
end="$(now)"

# awk rather than bash arithmetic: these are fractional seconds.
elapsed="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')"
printf '%s\t%s\n' "$elapsed" "$rc" >>"$FILE" \
    || echo "time-it.sh: could not write $FILE" >&2

exit "$rc"
