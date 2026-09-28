#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Pick the con/git-annex "Build git-annex on Ubuntu" run whose
# debianstandalone package the git-annex cells should install, and print
# its run id (also to $GITHUB_OUTPUT as run_id=..., when set).
#
# Why not simply `?status=success`: that is the *whole* run's
# conclusion, and one known-red test job (nfs-home, con/git-annex#293)
# marks every run failed, so filtering on it silently kept us on a
# weeks-old build. The package artifact is uploaded only once
# build-package succeeded, so "has an unexpired
# git-annex-debianstandalone-packages_* artifact" is the actual signal.
# Only master's scheduled/dispatched runs count: pull_request builds
# carry unmerged patches.
#
# Run once per workflow (the `matrix` job) and hand the id to every
# cell, so all cells of one run test the same build.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: bin/ci/pick-git-annex-build.sh [repo]

  repo     GitHub repo with the build-ubuntu.yaml workflow
           (default: con/git-annex)

env overrides:
  GIT_ANNEX_BUILD_REPO     same as the positional repo
  GIT_ANNEX_BUILD_BRANCH   branch to take runs from (default: master)
  GIT_ANNEX_BUILD_EVENTS   space-separated run events to accept
                           (default: "schedule workflow_dispatch")
  GIT_ANNEX_BUILD_SCAN     how many recent runs to consider (default: 30)
  GH_TOKEN                 required, for the GitHub REST API
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[ $# -le 1 ] || { usage >&2; exit 2; }

repo="${1:-${GIT_ANNEX_BUILD_REPO:-con/git-annex}}"
branch="${GIT_ANNEX_BUILD_BRANCH:-master}"
events="${GIT_ANNEX_BUILD_EVENTS:-schedule workflow_dispatch}"
scan="${GIT_ANNEX_BUILD_SCAN:-30}"

: "${GH_TOKEN:?GH_TOKEN must be set (secrets.GITHUB_TOKEN in a workflow)}"

# `gh run list` has been observed returning stale (expired-artifact)
# runs on the runner's gh version; REST orders newest-first reliably.
runs="$(gh api \
    "repos/$repo/actions/workflows/build-ubuntu.yaml/runs?branch=$branch&per_page=$scan" \
    --jq '.workflow_runs[] | "\(.id) \(.event) \(.conclusion // .status) \(.created_at)"')"
if [ -z "$runs" ]; then
    echo "E: no $repo build-ubuntu.yaml runs on $branch" >&2
    exit 1
fi

run_id=""
while read -r id event state created; do
    case " $events " in
        *" $event "*) ;;
        *) continue ;;
    esac
    n="$(gh api "repos/$repo/actions/runs/$id/artifacts" \
        --jq '[.artifacts[] | select(.expired==false and (.name | startswith("git-annex-debianstandalone-packages_")))] | length')"
    if [ "$n" -gt 0 ]; then
        run_id="$id"
        # The run's own conclusion is informational only (see header).
        echo "I: picked $repo run $id ($event, $created, run $state)" >&2
        break
    fi
done <<< "$runs"

if [ -z "$run_id" ]; then
    echo "E: none of the last $scan $branch runs ($events) has an unexpired debianstandalone artifact" >&2
    exit 1
fi

echo "$run_id"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "run_id=$run_id" >> "$GITHUB_OUTPUT"
fi
