#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Download a git-annex build artifact from con/git-annex's "Build
# git-annex on Ubuntu" workflow and install it. Appends the
# git-annex-standalone bin dir to $GITHUB_PATH so subsequent steps see it,
# and records which build was tested in $GITHUB_STEP_SUMMARY.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

usage() {
    cat <<'USAGE'
usage: bin/ci/install-git-annex-daily.sh [run-id]

  run-id   con/git-annex build-ubuntu.yaml run to install from
           (default: bin/ci/pick-git-annex-build.sh picks the newest
           master build with a package)

env overrides:
  GIT_ANNEX_RUN_ID      same as the positional run-id
  GIT_ANNEX_BUILD_REPO  repo the run belongs to (default: con/git-annex)
  EXPECT_BUILD_FLAGS    space-separated flags `git annex version` must
                        list, else fail (default: "OsPath"; "" disables)
  GH_TOKEN              required, for the GitHub REST API
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[ $# -le 1 ] || { usage >&2; exit 2; }

: "${GH_TOKEN:?GH_TOKEN must be set (secrets.GITHUB_TOKEN in a workflow)}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="${GIT_ANNEX_BUILD_REPO:-con/git-annex}"
run_id="${1:-${GIT_ANNEX_RUN_ID:-}}"
if [ -z "$run_id" ]; then
    run_id="$(GIT_ANNEX_BUILD_REPO="$repo" GITHUB_OUTPUT='' "$here/pick-git-annex-build.sh")"
fi

echo "downloading from run $run_id"
mkdir -p /tmp/ga
gh run download --repo "$repo" "$run_id" --dir /tmp/ga \
    --pattern 'git-annex-debianstandalone*'

deb="$(find /tmp/ga -name '*.deb' -print -quit)"
if [ -z "$deb" ]; then
    echo "no .deb in artifact" >&2
    exit 1
fi
echo "installing $deb"
sudo apt-get -o "DPkg::Lock::Timeout=60" install -y "$deb"

version="$(git-annex version)"
head -3 <<< "$version"
flags="$(sed -n 's/^build flags: //p' <<< "$version")"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### git-annex under test"
        echo
        echo "- build: https://github.com/$repo/actions/runs/$run_id"
        echo "- package: \`$(basename "$deb")\`"
        echo
        echo '```'
        head -3 <<< "$version"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

# The build flags are not cosmetic: e.g. OsPath silently drops out when a
# build dependency is missing, and BeeGFS results differ with and without
# it. Fail here rather than let a cell quietly measure a different build.
missing=""
for f in ${EXPECT_BUILD_FLAGS-OsPath}; do
    case " $flags " in
        *" $f "*) ;;
        *) missing="$missing $f" ;;
    esac
done
if [ -n "$missing" ]; then
    echo "E: build from run $run_id lacks expected build flag(s):$missing" >&2
    echo "E: build flags: $flags" >&2
    exit 1
fi

# Add the standalone bundle's bin dir to PATH for subsequent steps.
if [ -n "${GITHUB_PATH:-}" ]; then
    dpkg -L git-annex-standalone \
        | grep -E '/bin/git-annex$' \
        | xargs -r dirname \
        >> "$GITHUB_PATH"
fi
