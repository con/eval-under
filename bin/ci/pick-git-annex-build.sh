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
# Why sort here rather than trust the API's order: the runs endpoint
# does not document its ordering, and in eval-under run 36491628696 the
# first schedule/workflow_dispatch run it handed us was 35319817132
# (2026-09-18) although 36399800528 (2026-09-28) had been first an hour
# earlier. So: one query per event (filtered server-side, so $scan
# covers more history), merged and sorted by created_at here, and the
# raw listing is summarised in the log so a stale answer can be told
# apart from a mis-ordered one.
#
# GIT_ANNEX_RUN_ID pins a run instead (test.yaml's workflow_dispatch
# input), e.g. to rerun the matrix on a known build while the listing
# misbehaves; it is still checked for a package artifact.
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
  GIT_ANNEX_BUILD_SCAN     how many recent runs to fetch per event
                           (default: 30)
  GIT_ANNEX_BUILD_MAX_AGE  warn when the picked run is older than this
                           many days (default: 3; the build is daily)
  GIT_ANNEX_RUN_ID         pin this run instead of picking (empty: pick)
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
max_age="${GIT_ANNEX_BUILD_MAX_AGE:-3}"
pin="${GIT_ANNEX_RUN_ID:-}"

: "${GH_TOKEN:?GH_TOKEN must be set (secrets.GITHUB_TOKEN in a workflow)}"

# One line per run: "created_at id event state". ISO-8601 UTC sorts
# lexicographically, so `sort -r` puts the newest first.
fields='"\(.created_at) \(.id) \(.event) \(.conclusion // .status)"'
runs=""
if [ -n "$pin" ]; then
    runs="$(gh api "repos/$repo/actions/runs/$pin" --jq "$fields" </dev/null)"
    echo "I: using pinned $repo run $pin" >&2
    events=""
fi
for event in $events; do
    page="$(gh api \
        "repos/$repo/actions/workflows/build-ubuntu.yaml/runs?branch=$branch&event=$event&per_page=$scan" \
        --jq ".workflow_runs[] | $fields" \
        </dev/null)"
    n="$(grep -c . <<< "$page" || true)"
    newest="$(sort -r <<< "$page" | head -1 | cut -d' ' -f1-2)"
    echo "I: $repo $branch $event runs listed: $n, newest: ${newest:-none}" >&2
    runs+="$page"$'\n'
done
runs="$(sort -r -u <<< "$runs" | grep . || true)"
if [ -z "$runs" ]; then
    echo "E: no $repo build-ubuntu.yaml ${pin:-$events} runs on $branch" >&2
    exit 1
fi

# An array, not `while read ... <<< "$runs"`: gh inside such a loop
# shares its stdin and can swallow the remaining lines. </dev/null too.
mapfile -t candidates <<< "$runs"
run_id=""
for line in "${candidates[@]}"; do
    read -r created id event state <<< "$line"
    n="$(gh api "repos/$repo/actions/runs/$id/artifacts" \
        --jq '[.artifacts[] | select(.expired==false and (.name | startswith("git-annex-debianstandalone-packages_")))] | length' \
        </dev/null)"
    # The run's own conclusion is informational only (see header).
    echo "I: $repo run $id ($event, $created, run $state): $n package artifact(s)" >&2
    if [ "$n" -gt 0 ]; then
        run_id="$id"
        break
    fi
done

if [ -z "$run_id" ]; then
    echo "E: none of the listed $branch runs (${pin:-$events}) has an unexpired debianstandalone artifact" >&2
    exit 1
fi

# Not fatal: the build may genuinely have been failing for days. But
# a pick this old is what an incomplete/stale listing looks like too.
age_days=$(( ($(date -u +%s) - $(date -u -d "$created" +%s)) / 86400 ))
if [ -z "$pin" ] && [ "$age_days" -gt "$max_age" ]; then
    echo "::warning::picked $repo run $run_id is $age_days days old ($created); newer builds failed or the API listing is stale" >&2
fi

echo "$run_id"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "run_id=$run_id" >> "$GITHUB_OUTPUT"
fi
