#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Shared CI matrix definition for eval-under. Sourced (not executed) by
# bin/ci/{install-target,run-under,target-*,gen-dispatchers}.sh so the
# cell list, the pinned upstream refs, and the per-target knobs live in
# exactly one place.
#
# The matrix is backends x targets. A "backend" answers "which
# filesystem?" (bin/eval-under-<backend>); a "target" answers "which test
# suite do we run under it?" (bin/ci/target-<target>.sh).
#
#   git-annex   full `git annex test` (the suite that motivated the repo)
#   git         a subset of git's own testsuite, built from a pinned tag
#   stress-ng   curated filesystem-class stressors, one at a time
#   pjdfstest   POSIX filesystem conformance suite, at a pinned tag
#
# shellcheck shell=bash

# Order matters: it is the column order of the README CI matrix.
EVAL_UNDER_TARGETS=(git-annex git stress-ng pjdfstest)

# Backend cells, "<backend>|<version>|<README row label>". Order matters:
# it is the row order of the README CI matrix. Version is the literal
# "n/a" for backends with nothing to pin (see bin/ci/install-backend.sh).
# Consumed only by bin/ci/gen-dispatchers.sh, hence "unused" here.
# shellcheck disable=SC2034
EVAL_UNDER_BACKENDS=(
    "beegfs|7.4.6|BeeGFS 7.4.6"
    "beegfs|8.1.0|BeeGFS 8.1.0"
    "nfs|n/a|NFS (localhost)"
    "loop|vfat|Loop vfat"
    "loop|ext4|Loop ext4"
)

# GitHub repo the README badges point at. Consumed by gen-dispatchers.sh.
# shellcheck disable=SC2034
EVAL_UNDER_REPO_SLUG="${EVAL_UNDER_REPO_SLUG:-con/eval-under}"

# Where install-target.sh unpacks/builds source trees on the *runner*
# (deliberately not on the filesystem under test -- we want the build to
# be fast and the suite's I/O to be the only thing hitting the mount).
EVAL_UNDER_SRC_DIR="${EVAL_UNDER_SRC_DIR:-/opt/eval-under-src}"

# Pinned upstream refs. Bump deliberately, never "latest": a moving
# testsuite makes a red cell ambiguous (did the filesystem regress, or
# did upstream add a test?).
EVAL_UNDER_GIT_REF="${EVAL_UNDER_GIT_REF:-v2.55.0}"
# pjd/pjdfstest carries exactly one tag upstream, "0.1" (2016), and it no
# longer builds: major()/minor()/makedev() moved to <sys/sysmacros.h> in
# glibc 2.28 and the tree compiles with -Werror, so the implicit
# declarations are hard errors on anything modern. Master builds clean,
# so pin a commit on master instead -- same determinism, minus the patch
# we would otherwise have to carry. Bump deliberately.
EVAL_UNDER_PJDFSTEST_REF="${EVAL_UNDER_PJDFSTEST_REF:-85a8aea9e685999ef0540392fd80535f873d7ff7}"

# Filename-safe identifier for a backend cell: "beegfs-7.4.6", "nfs",
# "loop-vfat". Used for workflow filenames and concurrency groups.
backend_slug() {
    local backend="$1" version="$2"
    if [ "$version" = "n/a" ]; then
        echo "$backend"
    else
        echo "$backend-$version"
    fi
}

# Filename-safe identifier for a whole matrix cell: "beegfs-7.4.6-git",
# "nfs-pjdfstest", "loop-vfat-stress-ng".
#
# Exists because the NFS backend's version is the literal "n/a", and a
# naive "<backend>-<version>-<target>" therefore contains a slash.
# actions/upload-artifact rejects slashes in artifact names outright, so
# `logs-nfs-n/a-git` is a hard error -- one that stayed invisible until
# the git target started producing files to upload at all (before that,
# `if-no-files-found: ignore` short-circuited before the name was ever
# validated).
cell_slug() {
    local backend="$1" version="$2" target="$3"
    echo "$(backend_slug "$backend" "$version")-$target"
}

target_known() {
    local t
    for t in "${EVAL_UNDER_TARGETS[@]}"; do
        [ "$t" = "$1" ] && return 0
    done
    return 1
}

# Human-readable column header / workflow-name fragment.
target_label() {
    case "$1" in
        git-annex) echo "git-annex test" ;;
        git)       echo "git testsuite" ;;
        stress-ng) echo "stress-ng" ;;
        pjdfstest) echo "pjdfstest" ;;
        *)         echo "$1" ;;
    esac
}

# Wall-clock budget for the wrapped suite, in seconds. Kept below the
# workflow-level timeout so a runaway suite produces a `timeout` exit
# code (and our logs) rather than a bare GitHub cancellation.
target_timeout() {
    case "$1" in
        git-annex) echo 2400 ;;
        # 174 scripts, ~2 min on ext4; a sync-heavy backend is far slower.
        git)       echo 2400 ;;
        stress-ng) echo  900 ;;
        # ~8500 assertions, run serially; ext4 does it in minutes but a
        # sync-heavy NFS or BeeGFS mount is an order of magnitude slower.
        pjdfstest) echo 2400 ;;
        *)         echo 1800 ;;
    esac
}

# Loop-backing-image size (MB) for `eval-under loop --size`. git-annex
# keeps the historical 100MB; the others need more room (git's trash
# directories, stress-ng's scratch files) or are I/O-bound on inode
# count rather than bytes.
target_loop_size_mb() {
    case "$1" in
        git-annex) echo 100 ;;
        git)       echo 512 ;;
        # copy-file's minimum --copy-file-bytes is 128M, and it needs
        # source + destination, so 512 leaves uncomfortably little slack.
        stress-ng) echo 768 ;;
        pjdfstest) echo 256 ;;
        *)         echo 100 ;;
    esac
}

# Minute-of-hour for a target's weekly schedule, so the 20 cells do not
# all stampede the runner pool at 05:17 Monday.
target_cron_minute() {
    case "$1" in
        git-annex) echo 17 ;;
        git)       echo 32 ;;
        stress-ng) echo 47 ;;
        pjdfstest) echo  2 ;;
        *)         echo 17 ;;
    esac
}

# Does this target need to run as root to mean anything?
#
# pjdfstest is half privileged-vs-unprivileged assertions and refuses to
# run otherwise; stress-ng's chown/mknod stressors need CAP_CHOWN /
# CAP_MKNOD. The loop and beegfs backends already run the wrapped command
# as root, but the NFS backend deliberately drops back to the invoking
# user and exports with root_squash -- which is exactly right for
# git-annex/git and useless for these two. run-under.sh passes
# --no-root-squash for them.
target_needs_root() {
    case "$1" in
        pjdfstest|stress-ng) return 0 ;;
        *) return 1 ;;
    esac
}

# Does this target need the git-annex daily build installed on the runner?
target_needs_git_annex() {
    [ "$1" = "git-annex" ]
}
