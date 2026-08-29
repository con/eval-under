#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Runner-side install/build of an eval-under *test target* (the suite we
# run under the backend filesystem). Counterpart of install-backend.sh,
# which installs the backend (the filesystem) instead.
#
# Everything built here lands on the runner's own disk
# ($EVAL_UNDER_SRC_DIR), never on the filesystem under test -- only the
# suite's own I/O should exercise the mount.
#
# usage:
#   bin/ci/install-target.sh <target>
#
#   target = git-annex | git | stress-ng | pjdfstest
#
# env overrides:
#   EVAL_UNDER_SRC_DIR         where to clone/build   (/opt/eval-under-src)
#   EVAL_UNDER_GIT_REF         git tag to build       (see bin/ci/matrix.sh)
#   EVAL_UNDER_PJDFSTEST_REF   pjdfstest tag to build (see bin/ci/matrix.sh)
#
# Idempotent enough for CI re-runs: an already-built tree is left alone.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# SC1091 is only silenceable by running shellcheck with -x; disable it
# here so a plain `shellcheck bin/ci/*.sh` stays clean.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

TARGET="${1:?target required (git-annex|git|stress-ng|pjdfstest)}"
target_known "$TARGET" || {
    echo "unknown target: $TARGET (expected: ${EVAL_UNDER_TARGETS[*]}" \
         "${EVAL_UNDER_ONDEMAND_TARGETS[*]})" >&2
    exit 1
}

# Give unattended-upgrades a moment on ubuntu-22.04 runners rather than
# hard-failing on a dpkg lock (same rationale as install-backend.sh).
APT_LOCK_TIMEOUT=(-o "DPkg::Lock::Timeout=60")

apt_install() {
    sudo apt-get "${APT_LOCK_TIMEOUT[@]}" install -y --no-install-recommends "$@"
}

apt_update() {
    sudo apt-get "${APT_LOCK_TIMEOUT[@]}" update -qq
}

# Shallow-fetch a pinned ref into $EVAL_UNDER_SRC_DIR/<name>, or report
# that it is already there. Sets $checkout.
#
# init + fetch + checkout rather than `clone --branch`, because --branch
# only accepts a branch or tag name: this way a ref can equally be a
# commit SHA (which is what pjdfstest needs -- see EVAL_UNDER_PJDFSTEST_REF
# in bin/ci/matrix.sh).
checkout=""
fetch_pinned() {
    local name="$1" url="$2" ref="$3"
    checkout="$EVAL_UNDER_SRC_DIR/$name"
    if [ -d "$checkout/.git" ]; then
        echo "I: $name already checked out at $checkout"
        return 0
    fi
    sudo mkdir -p "$EVAL_UNDER_SRC_DIR"
    sudo chown "$(id -u):$(id -g)" "$EVAL_UNDER_SRC_DIR"
    echo "I: fetching $url @ $ref -> $checkout"
    mkdir -p "$checkout"
    git -C "$checkout" init -q
    git -C "$checkout" remote add origin "$url"
    git -C "$checkout" fetch -q --depth 1 origin "$ref"
    git -C "$checkout" checkout -q FETCH_HEAD
    git -C "$checkout" --no-pager log -1 --format='I: %H %s'
}

install_git_annex() {
    # Nothing to build: the daily git-annex build is installed by
    # bin/ci/install-git-annex-daily.sh, which needs a GH token and so
    # stays a separate workflow step.
    echo "I: target git-annex needs no extra build step here"
    echo "I: (git-annex itself comes from bin/ci/install-git-annex-daily.sh)"
}

install_git() {
    apt_update
    # Build deps for a functional git (curl/expat/gettext matter for the
    # t0xxx/t1xxx range: without them the corresponding tests silently skip).
    apt_install build-essential gettext perl \
        zlib1g-dev libssl-dev libcurl4-openssl-dev libexpat1-dev

    # bin/ci/target-git.sh drives the suite through `make prove`, so the
    # TAP harness itself is a hard dependency. It ships in perl-modules
    # (pulled in by perl above), but assert it here: a missing prove
    # would otherwise surface as an opaque make failure minutes into the
    # run, on the mount, after the whole build.
    command -v prove >/dev/null || {
        echo "ERROR: prove not found -- install perl-modules (TAP harness)" >&2
        exit 3
    }

    fetch_pinned git https://github.com/git/git "$EVAL_UNDER_GIT_REF"

    if [ -x "$checkout/git" ]; then
        echo "I: git already built ($("$checkout/git" --version))"
        return 0
    fi
    # NO_TCLTK: gitk/git-gui are irrelevant here and pull in a tcl
    # toolchain. Everything else stays default so the testsuite's
    # prerequisites resolve the way upstream CI sees them.
    make -C "$checkout" -j"$(nproc)" NO_TCLTK=1
    "$checkout/git" --version
}

install_stress_ng() {
    apt_update
    apt_install stress-ng
    stress-ng --version
}

install_pjdfstest() {
    apt_update
    apt_install build-essential autoconf automake libtool perl

    fetch_pinned pjdfstest https://github.com/pjd/pjdfstest "$EVAL_UNDER_PJDFSTEST_REF"

    if [ -x "$checkout/pjdfstest" ]; then
        echo "I: pjdfstest already built"
        return 0
    fi
    ( cd "$checkout" && autoreconf -ifs && ./configure && make pjdfstest )
    test -x "$checkout/pjdfstest"
}

case "$TARGET" in
    git-annex) install_git_annex ;;
    git)       install_git ;;
    stress-ng) install_stress_ng ;;
    pjdfstest) install_pjdfstest ;;
    # Needs nothing installed: it is bin/ci/fs-capabilities.sh, which is
    # in this repo and uses only coreutils + sqlite3 if present.
    capabilities) echo "I: $TARGET needs no runner-side install" ;;
esac
