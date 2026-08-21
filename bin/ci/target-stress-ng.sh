#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: curated stress-ng filesystem stressors.
#
# Cheapest cell in the matrix (apt package, no build) and the broadest:
# stress-ng hammers the syscall surface git-annex depends on -- rename,
# link/symlink, locking, xattr, chmod/chown, utime -- with verification
# enabled, so a filesystem that returns success while doing the wrong
# thing is caught here rather than three layers up in a testsuite.
#
# Each stressor runs on its own so one unsupported operation (say xattr
# on vfat) is reported as a skip instead of poisoning the whole run.
#
# Runs INSIDE the eval-under wrapper. Go through
# bin/ci/run-under.sh <backend> <version> stress-ng.
#
# usage:
#   bin/ci/target-stress-ng.sh
#
# env:
#   EVAL_UNDER_STRESS_NG_SECONDS   per-stressor runtime (default 5)
#   EVAL_UNDER_STRESS_NG_WORKERS   workers per stressor (default 1)
#   EVAL_UNDER_STRESS_NG_ONLY      space-separated subset of stressor
#                                  names to run (default: all below)
#   TMPDIR                         <mount> -- scratch files go under here
#
# Exit status: 0 if every stressor passed or skipped, 1 if any failed.

set -uo pipefail

SECONDS_PER="${EVAL_UNDER_STRESS_NG_SECONDS:-5}"
WORKERS="${EVAL_UNDER_STRESS_NG_WORKERS:-1}"

command -v stress-ng >/dev/null || {
    echo "ERROR: stress-ng not installed -- run bin/ci/install-target.sh stress-ng" >&2
    exit 3
}

# "<stressor>|<extra options>". Only stressors that operate on
# --temp-path (i.e. on the filesystem under test) are listed; the CPU /
# VM / kernel-surface classes tell us nothing about a filesystem.
#
# Byte-size caps are deliberate: the loop backend's backing image is a
# few hundred MB, and a stressor that fills it reports ENOSPC noise
# rather than a semantics bug.
STRESSORS=(
    "chmod|"
    "chown|"
    "copy-file|--copy-file-bytes 128M"  # 128M is stress-ng's minimum
    "dentry|--dentries 1024"
    "dir|"
    "fallocate|--fallocate-bytes 8M"
    "fcntl|"
    "filename|"
    "hdd|--hdd-bytes 8M"
    "link|"
    "locka|"
    "lockf|"
    "mknod|"
    "open|"
    "rename|"
    "seek|--seek-size 8M"
    "symlink|"
    "sync-file|--sync-file-bytes 8M"
    "utime|"
    "xattr|"
)

work="${TMPDIR:-/tmp}/stress-ng"
mkdir -p "$work"
cd "$work" || exit 3

echo "I: $(stress-ng --version)"
echo "I: temp-path $work (${SECONDS_PER}s x ${WORKERS} worker(s) per stressor)"

# The runner's stress-ng is whatever its distro ships (0.13.x on
# ubuntu-22.04, 0.17.x on 24.04), and both the stressor set and the
# tuning options drift between releases. Ask the binary what it supports
# rather than pinning our list to one version: a stressor this build
# lacks is a skip, and a tuning option it lacks is simply dropped.
AVAILABLE="$(stress-ng --stressors 2>/dev/null || true)"
HELP_TEXT="$(stress-ng --help 2>&1 || true)"

supported_stressor() {
    # An empty --stressors listing means this build predates the option;
    # in that case assume everything is available and let it fail loudly.
    [ -z "$AVAILABLE" ] && return 0
    [[ " $AVAILABLE " == *" $1 "* ]]
}

# Echo only the "--opt value" pairs this build actually knows about.
filter_opts() {
    local out=() opt val
    while [ $# -gt 0 ]; do
        opt="$1"; val="${2:-}"; shift 2 || shift
        if [[ " $HELP_TEXT " == *" $opt "* ]]; then
            out+=("$opt" "$val")
        else
            echo "I: dropping unsupported option $opt" >&2
        fi
    done
    printf '%s ' "${out[@]:-}"
}

declare -a passed=() skipped=() failed=()

run_one() {
    local name="$1" extra="$2" rc
    echo
    echo "=== stress-ng --$name ==="
    if ! supported_stressor "$name"; then
        echo "I: not in this stress-ng build; skipping"
        skipped+=("$name (not built)")
        return 0
    fi
    # shellcheck disable=SC2086  # both are deliberate option lists
    extra="$(filter_opts $extra)"
    # shellcheck disable=SC2086  # $extra is a deliberate option list
    stress-ng "--$name" "$WORKERS" \
        --timeout "$SECONDS_PER" \
        --verify --metrics-brief \
        --temp-path "$work" \
        $extra
    rc=$?
    case "$rc" in
        0) passed+=("$name") ;;
        # 3 = EXIT_NO_RESOURCE, 4 = EXIT_NOT_IMPLEMENTED. Both mean "this
        # filesystem/kernel cannot do it", which is information, not a
        # regression -- vfat has no xattrs and never will.
        3|4) skipped+=("$name (rc=$rc)") ;;
        *) failed+=("$name (rc=$rc)") ;;
    esac
}

only="${EVAL_UNDER_STRESS_NG_ONLY:-}"
for entry in "${STRESSORS[@]}"; do
    name="${entry%%|*}"
    extra="${entry#*|}"
    if [ -n "$only" ] && [[ " $only " != *" $name "* ]]; then
        continue
    fi
    run_one "$name" "$extra"
done

echo
echo "=== stress-ng summary ($work) ==="
printf 'passed  (%2d): %s\n' "${#passed[@]}"  "${passed[*]:-none}"
printf 'skipped (%2d): %s\n' "${#skipped[@]}" "${skipped[*]:-none}"
printf 'failed  (%2d): %s\n' "${#failed[@]}"  "${failed[*]:-none}"

[ "${#failed[@]}" -eq 0 ]
