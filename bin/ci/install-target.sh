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
#   target = git-annex | git-annex-linkannex | git | stress-ng
#            | mtime-stability | pjdfstest | datalad-benchmarks
#
# env overrides:
#   EVAL_UNDER_SRC_DIR         where to clone/build   (/opt/eval-under-src)
#   EVAL_UNDER_GIT_REF         git tag to build       (see bin/ci/matrix.sh)
#   EVAL_UNDER_PJDFSTEST_REF   pjdfstest tag to build (see bin/ci/matrix.sh)
#   EVAL_UNDER_DATALAD_REF     DataLad release whose PyPI sdist to install
#   EVAL_UNDER_DATALAD_DEPRECATED_REF, EVAL_UNDER_ASV_REF,
#   EVAL_UNDER_ASV_RUNNER_REF  versions installed next to it
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

# No target list spelled out here: target_known below rejects an unknown
# one and prints the live list from evals/matrix.yaml, which cannot go
# stale the way this message just did.
TARGET="${1:?target required (see targets in evals/matrix.yaml)}"
target_known "$TARGET" || {
    echo "unknown target: $TARGET (expected: ${EVAL_UNDER_TARGETS[*]})" >&2
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

own_src_dir() {
    sudo mkdir -p "$EVAL_UNDER_SRC_DIR"
    sudo chown "$(id -u):$(id -g)" "$EVAL_UNDER_SRC_DIR"
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
    own_src_dir
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

# DataLad from its release sdist, into a venv of its own, with the
# sdist also unpacked next to it: the benchmarks/ directory
# bin/ci/target-datalad-benchmarks.sh runs ships in that tarball, not in
# the installed package. Only the four packages named here are pinned;
# DataLad's own dependencies resolve at install time, so the resolved
# set is printed for the record.
install_datalad_benchmarks() {
    local ver="$EVAL_UNDER_DATALAD_REF"
    local sdist="$EVAL_UNDER_SRC_DIR/datalad-$ver.tar.gz"
    local src="$EVAL_UNDER_SRC_DIR/datalad"
    local venv="$EVAL_UNDER_SRC_DIR/datalad-venv"
    local pins=("datalad-deprecated==$EVAL_UNDER_DATALAD_DEPRECATED_REF"
                "asv==$EVAL_UNDER_ASV_REF"
                "asv-runner==$EVAL_UNDER_ASV_RUNNER_REF")
    local stamp
    stamp="$(printf '%s\n' "datalad==$ver" "${pins[@]}")"

    # Written last, so it also stands for "the install finished".
    if [ "$(cat "$venv/eval-under-pins" 2>/dev/null)" = "$stamp" ]; then
        echo "I: datalad $ver benchmarks already installed ($venv)"
        return 0
    fi
    apt_update
    # ubuntu's python3 has no ensurepip, hence no `-m venv`, without it
    apt_install python3-venv

    own_src_dir
    # files.pythonhosted.org's /packages/source/ path is PyPI's stable
    # redirect to a release's sdist by name and version.
    echo "I: fetching datalad $ver sdist from PyPI"
    curl -fsSL --retry 3 -o "$sdist" \
        "https://files.pythonhosted.org/packages/source/d/datalad/datalad-$ver.tar.gz"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xzf "$sdist" -C "$src" --strip-components=1
    test -d "$src/benchmarks" || {
        echo "ERROR: datalad $ver sdist carries no benchmarks/" >&2
        exit 3
    }

    rm -rf "$venv"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip
    # The tarball itself rather than datalad==$ver, which pip could
    # equally satisfy from the wheel.
    "$venv/bin/pip" install -q "$sdist" "${pins[@]}"
    "$venv/bin/pip" freeze --all | sed 's/^/I: installed /'
    "$venv/bin/datalad" --version
    echo "$stamp" > "$venv/eval-under-pins"
}

case "$TARGET" in
    git-annex|git-annex-linkannex) install_git_annex ;;
    datalad-benchmarks) install_datalad_benchmarks ;;
    # mtime-stability ships with this repo and needs nothing installed
    mtime-stability) ;;
    git)       install_git ;;
    stress-ng) install_stress_ng ;;
    pjdfstest) install_pjdfstest ;;
esac
