#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Run one column of the matrix -- one test target, e.g. `git-annex`,
# across every backend -- on ONE machine, back to back, and record how
# long the suite took on each filesystem.
#
# Why this exists rather than reading the timings off CI: GitHub's
# hosted runners differ in CPU, disk and neighbours from run to run, and
# each matrix cell lands on a *different* runner. Those numbers say
# whether a cell passes; they cannot say "BeeGFS is 4x slower than ext4
# for `git annex test`" because nothing was held constant. Here every
# cell runs on the same box, same kernel, same git-annex build, in one
# sitting.
#
# What is measured is the *suite*, not the cell: bin/ci/time-it.sh runs
# inside the eval-under wrapper (see EVAL_UNDER_TIME_FILE in
# bin/ci/run-under.sh), so mkfs, the BeeGFS cluster bring-up and the NFS
# export land in the setup column instead of inflating the comparison.
#
# usage:
#   bin/ci/bench-matrix.sh [OPTIONS] [TARGET...]
#
#   TARGET...  targets to benchmark (default: git-annex).
#              Any of: see `targets:` in .github/matrix.yaml.
#
# options:
#   --backends LIST   space/comma-separated subset of backends, as
#                     <backend>[/<version>] (e.g. "loop/ext4 nfs
#                     beegfs/7.4.6"). Default: every row of matrix.yaml.
#   --repeat N        repetitions per cell (default 3). Reps are the
#                     OUTER loop -- every backend is run once, then
#                     again -- so slow drift on the box (thermal, a
#                     background process) spreads over all backends
#                     instead of penalising whichever ran last.
#   --outdir DIR      results directory
#                     (default /var/tmp/eval-under-bench/<UTC stamp>)
#   --scratch DIR     where the backends put their backing store: the
#                     loop image, the NFS export dir (default /var/tmp).
#                     Keep this on a real disk -- /tmp is tmpfs on many
#                     distros, and a RAM-backed loop image makes the
#                     loop rows look 10x better than the hardware is.
#   --timeout S       override every target's matrix timeout. Raise it
#                     for a slow backend: a suite killed at the timeout
#                     yields a lower bound, not a time.
#   --baseline SLUG   backend to express ratios against
#                     (default: loop-ext4 if benchmarked, else fastest).
#   --no-drop-caches  keep the page cache between runs. Default is to
#                     drop it (sync + /proc/sys/vm/drop_caches), so a
#                     backend does not inherit the previous one's cache.
#   --skip-install    do not run install-backend.sh / install-target.sh.
#   --list            print the planned cells and exit.
#   --dry-run         set everything up, print each command, run nothing.
#   -h, --help        this text.
#
# env overrides:
#   EVAL_UNDER_SRC_DIR   where install-target.sh built the suites
#   EVAL_UNDER_MATRIX_FILE   matrix definition (default .github/matrix.yaml)
#
# Needs root for the mounts, exactly like a CI cell: run it under sudo,
# or as root. Under sudo the NFS backend still drops the suite back to
# the invoking user, which is what CI measures too.
#
# Output ($OUTDIR):
#   results.tsv   one row per (target, backend, rep) -- the raw data
#   report.txt    the rendered comparison, also printed at the end
#   report.md     same, as markdown to paste into an issue
#   env.txt       host provenance: kernel, CPU, RAM, scratch filesystem,
#                 tool versions, repo commit
#   logs/         full output of every run

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

REPEAT=3
OUTDIR=""
SCRATCH="${EVAL_UNDER_BENCH_SCRATCH:-/var/tmp}"
TIMEOUT_OVERRIDE=""
BASELINE=""
DROP_CACHES=1
DO_INSTALL=1
LIST_ONLY=0
DRY_RUN=0
BACKEND_FILTER=""
declare -a TARGETS=()

usage() { sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --backends)       BACKEND_FILTER="$2"; shift 2 ;;
        --repeat)         REPEAT="$2"; shift 2 ;;
        --outdir)         OUTDIR="$2"; shift 2 ;;
        --scratch)        SCRATCH="$2"; shift 2 ;;
        --timeout)        TIMEOUT_OVERRIDE="$2"; shift 2 ;;
        --baseline)       BASELINE="$2"; shift 2 ;;
        --no-drop-caches) DROP_CACHES=0; shift ;;
        --skip-install)   DO_INSTALL=0; shift ;;
        --list)           LIST_ONLY=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)  TARGETS+=("$1"); shift ;;
    esac
done
TARGETS+=("$@")

[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=(git-annex)

for t in "${TARGETS[@]}"; do
    target_known "$t" || {
        echo "unknown target: $t (expected: ${EVAL_UNDER_TARGETS[*]})" >&2
        exit 2
    }
done

case "$REPEAT" in
    ''|*[!0-9]*) echo "--repeat wants a positive integer, got '$REPEAT'" >&2; exit 2 ;;
esac
[ "$REPEAT" -ge 1 ] || { echo "--repeat must be >= 1" >&2; exit 2; }

# Select the backend rows. Entries are "<backend>|<version>|<label>" as
# built by matrix.sh; the filter matches "<backend>" or
# "<backend>/<version>" so `--backends "loop/ext4 nfs"` reads naturally.
declare -a CELLS=()
if [ -n "$BACKEND_FILTER" ]; then
    read -r -a wanted <<<"${BACKEND_FILTER//,/ }"
else
    wanted=()
fi

backend_wanted() {
    local backend="$1" version="$2" w
    [ "${#wanted[@]}" -eq 0 ] && return 0
    for w in "${wanted[@]}"; do
        [ "$w" = "$backend" ] && return 0
        [ "$w" = "$backend/$version" ] && return 0
        [ "$w" = "$(backend_slug "$backend" "$version")" ] && return 0
    done
    return 1
}

for row in "${EVAL_UNDER_BACKENDS[@]}"; do
    IFS='|' read -r backend version _ <<<"$row"
    backend_wanted "$backend" "$version" && CELLS+=("$row")
done

[ "${#CELLS[@]}" -gt 0 ] || {
    echo "no backend matched '$BACKEND_FILTER'; known:" >&2
    for row in "${EVAL_UNDER_BACKENDS[@]}"; do
        IFS='|' read -r backend version _ <<<"$row"
        echo "  $(backend_slug "$backend" "$version")" >&2
    done
    exit 2
}

if [ "$LIST_ONLY" = 1 ]; then
    echo "targets:  ${TARGETS[*]}"
    echo "repeats:  $REPEAT"
    echo "cells:"
    for t in "${TARGETS[@]}"; do
        for row in "${CELLS[@]}"; do
            IFS='|' read -r backend version label <<<"$row"
            printf '  %-24s %s (timeout %ss)\n' \
                "$(cell_slug "$backend" "$version" "$t")" \
                "$label / $(target_label "$t")" \
                "${TIMEOUT_OVERRIDE:-$(target_timeout "$t")}"
        done
    done
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || {
        echo "must run as root (or have sudo available): the backends mount" >&2
        exit 2
    }
    SUDO=(sudo)
else
    SUDO=()
fi

OUTDIR="${OUTDIR:-/var/tmp/eval-under-bench/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTDIR/logs" "$OUTDIR/times"
mkdir -p "$SCRATCH"
RESULTS="$OUTDIR/results.tsv"

log() { printf 'I: %s\n' "$*" >&2; }

# EVAL_UNDER_* variables the caller exported, to be re-established on the
# far side of sudo. ${!prefix@} lists matching *names*; the two we set
# per cell ourselves are skipped so a stale value cannot shadow them.
declare -a FORWARD_ENV=()
for _name in ${!EVAL_UNDER_@}; do
    case "$_name" in
        EVAL_UNDER_TIME_FILE|EVAL_UNDER_TIMEOUT) continue ;;
    esac
    FORWARD_ENV+=("$_name=${!_name}")
done

# Provenance. A timing table without the box it was measured on is not a
# result anybody can reuse, and "same hardware" is the entire premise.
write_env() {
    local f="$OUTDIR/env.txt"
    {
        echo "date:        $(date -uIseconds)"
        echo "host:        $(uname -n)"
        echo "kernel:      $(uname -sr)"
        # shellcheck disable=SC1091  # /etc/os-release provided by the OS
        echo "distro:      $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "cpu:         $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo) x $(nproc)"
        echo "mem:         $(awk '/^MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
        echo "scratch:     $SCRATCH ($(findmnt -no FSTYPE,SOURCE --target "$SCRATCH" 2>/dev/null | tr -s ' '))"
        echo "src-dir:     $EVAL_UNDER_SRC_DIR"
        echo "repeat:      $REPEAT"
        echo "drop-caches: $DROP_CACHES"
        echo "repo:        $(git -C "$EVAL_UNDER_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "git:         $(git --version 2>/dev/null || echo absent)"
        echo "git-annex:   $(git annex version 2>/dev/null | head -1 || echo absent)"
        echo "stress-ng:   $(stress-ng --version 2>/dev/null || echo absent)"
        echo "governor:    $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    } >"$f"
    sed 's/^/I: /' "$f" >&2
}

drop_caches() {
    [ "$DROP_CACHES" = 1 ] || return 0
    sync
    "${SUDO[@]}" sh -c 'echo 3 >/proc/sys/vm/drop_caches' 2>/dev/null \
        || log "could not drop caches (continuing; timings will be cache-warm)"
}

now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then echo "${EPOCHREALTIME/,/.}"; else date +%s.%N; fi
}

install_deps() {
    [ "$DO_INSTALL" = 1 ] || { log "--skip-install: assuming backends and targets are installed"; return 0; }
    local row backend version t
    for row in "${CELLS[@]}"; do
        IFS='|' read -r backend version _ <<<"$row"
        log "install-backend.sh $backend $version"
        "$here/install-backend.sh" "$backend" "$version" >>"$OUTDIR/logs/install.log" 2>&1 || {
            echo "ERROR: install-backend.sh $backend $version failed; see $OUTDIR/logs/install.log" >&2
            exit 3
        }
    done
    for t in "${TARGETS[@]}"; do
        log "install-target.sh $t"
        "$here/install-target.sh" "$t" >>"$OUTDIR/logs/install.log" 2>&1 || {
            echo "ERROR: install-target.sh $t failed; see $OUTDIR/logs/install.log" >&2
            exit 3
        }
        if target_needs_git_annex "$t" && ! command -v git-annex >/dev/null; then
            echo "ERROR: target '$t' needs git-annex on PATH." >&2
            echo "  Install the same build you want measured (e.g." >&2
            echo "  GH_TOKEN=... bin/ci/install-git-annex-daily.sh) and re-run." >&2
            exit 3
        fi
    done
}

# One (target, backend, rep). Appends a results.tsv row; never aborts the
# benchmark -- a red cell is a data point, and half a table is worse than
# a table with a "fail" in it.
run_cell() {
    local target="$1" backend="$2" version="$3" rep="$4"
    local slug tfile logf started wall suite rc status env_args

    slug="$(cell_slug "$backend" "$version" "$target")"
    logf="$OUTDIR/logs/$slug.rep$rep.log"
    tfile="$OUTDIR/times/$slug.rep$rep"

    # Pre-create world-writable: under root_squash the NFS backend runs
    # the suite (and therefore time-it.sh) as the invoking user, so a
    # root-owned 0644 file would silently lose the measurement.
    : >"$tfile"
    chmod 0666 "$tfile"

    # sudo scrubs the environment, so the caller's own knobs have to be
    # carried across explicitly. Benchmarking a subset is a normal want:
    # EVAL_UNDER_GIT_TESTS='t00*.sh', EVAL_UNDER_STRESS_NG_SECONDS=2.
    # Ours come last, so they win over anything forwarded.
    env_args=("${FORWARD_ENV[@]}")
    env_args+=(
        TMPDIR="$SCRATCH"
        EVAL_UNDER_SRC_DIR="$EVAL_UNDER_SRC_DIR"
        EVAL_UNDER_MATRIX_FILE="$EVAL_UNDER_MATRIX_FILE"
        EVAL_UNDER_TIME_FILE="$tfile"
    )
    [ -n "$TIMEOUT_OVERRIDE" ] && env_args+=(EVAL_UNDER_TIMEOUT="$TIMEOUT_OVERRIDE")

    if [ "$DRY_RUN" = 1 ]; then
        echo "would run: ${SUDO[*]} env ${env_args[*]} $here/run-under.sh $backend $version $target"
        return 0
    fi

    drop_caches
    log "rep $rep/$REPEAT  $slug  -> $logf"
    started="$(now)"
    set +e
    "${SUDO[@]}" env "${env_args[@]}" \
        "$here/run-under.sh" "$backend" "$version" "$target" >"$logf" 2>&1
    rc=$?
    set -e
    wall="$(awk -v a="$started" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }')"

    # time-it.sh wrote "<seconds>\t<rc>" if the suite itself ran; an
    # empty file means the backend never got as far as starting it.
    suite=""
    if [ -s "$tfile" ]; then
        read -r suite _ <"$tfile"
    fi

    if [ -z "$suite" ]; then
        status="setup-error"
        suite="NA"
    elif [ "$rc" -eq 0 ]; then
        status="ok"
    elif [ "$rc" -eq 124 ]; then
        # timeout(1)'s own exit code: the suite was cut off, so its time
        # is a lower bound and the report must not average it in.
        status="timeout"
    else
        status="fail"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$target" "$backend" "$version" "$slug" "$rep" \
        "$status" "$rc" "$suite" "$wall" >>"$RESULTS"

    log "  -> $status rc=$rc suite=${suite}s cell=${wall}s"
}

write_env
install_deps

if [ "$DRY_RUN" != 1 ]; then
    printf 'target\tbackend\tversion\tslug\trep\tstatus\trc\tsuite_s\twall_s\n' >"$RESULTS"
fi

log "benchmarking ${TARGETS[*]} over ${#CELLS[@]} backend(s), $REPEAT rep(s) -> $OUTDIR"

# Reps outermost: see --repeat in the usage above.
for ((rep = 1; rep <= REPEAT; rep++)); do
    for target in "${TARGETS[@]}"; do
        for row in "${CELLS[@]}"; do
            IFS='|' read -r backend version _ <<<"$row"
            run_cell "$target" "$backend" "$version" "$rep"
        done
    done
done

[ "$DRY_RUN" = 1 ] && exit 0

report_args=()
[ -n "$BASELINE" ] && report_args+=(--baseline "$BASELINE")

"$here/bench-report.py" "$RESULTS" "${report_args[@]}" | tee "$OUTDIR/report.txt"
"$here/bench-report.py" "$RESULTS" "${report_args[@]}" --markdown >"$OUTDIR/report.md"

echo
echo "I: results  $RESULTS"
echo "I: report   $OUTDIR/report.txt (markdown: $OUTDIR/report.md)"
echo "I: logs     $OUTDIR/logs/"
