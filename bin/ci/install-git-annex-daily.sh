#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Download the latest successful git-annex build artifact from
# con/git-annex's "Build git-annex on Ubuntu" workflow and install it.
# Appends the git-annex-standalone bin dir to $GITHUB_PATH so subsequent
# steps see it.
#
# usage:
#   bin/ci/install-git-annex-daily.sh
#
# Requires GH_TOKEN in the environment (for the actions REST API).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${GH_TOKEN:?GH_TOKEN must be set (secrets.GITHUB_TOKEN in a workflow)}"

# `gh run list --status success --workflow "..."` has been observed
# returning stale (expired-artifact) runs on the runner's gh version.
# Use REST directly -- it orders newest-first reliably.
runs="$(gh api \
    'repos/con/git-annex/actions/workflows/build-ubuntu.yaml/runs?status=success&per_page=10' \
    --jq '.workflow_runs[].id')"
if [ -z "$runs" ]; then
    echo "no successful con/git-annex runs found" >&2
    exit 1
fi

run_id=""
for r in $runs; do
    n="$(gh api "repos/con/git-annex/actions/runs/$r/artifacts" \
        --jq '[.artifacts[] | select(.expired==false and (.name | startswith("git-annex-debianstandalone-packages_")))] | length')"
    if [ "$n" -gt 0 ]; then
        run_id="$r"
        break
    fi
done
if [ -z "$run_id" ]; then
    echo "no run with unexpired debianstandalone artifact" >&2
    exit 1
fi

echo "downloading from run $run_id"
mkdir -p /tmp/ga
gh run download --repo con/git-annex "$run_id" --dir /tmp/ga \
    --pattern 'git-annex-debianstandalone*'

deb="$(find /tmp/ga -name '*.deb' -print -quit)"
if [ -z "$deb" ]; then
    echo "no .deb in artifact" >&2
    exit 1
fi
echo "installing $deb"
sudo apt-get -o "DPkg::Lock::Timeout=60" install -y "$deb"

git-annex version | head -3

# Add the standalone bundle's bin dir to PATH for subsequent steps.
if [ -n "${GITHUB_PATH:-}" ]; then
    dpkg -L git-annex-standalone \
        | grep -E '/bin/git-annex$' \
        | xargs -r dirname \
        >> "$GITHUB_PATH"
fi
