#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Publish the CI status site: merge this run's per-cell results into the
# persistent status file, re-render the badges and the report page, and
# push the result to the site branch (default: gh-pages).
#
# Replaces the earlier publish-badges.sh, which derived the whole grid
# from a single run's artifacts. That was wrong for any run that does not
# cover every cell -- "Re-run failed jobs" being the obvious one -- and
# would have rewritten the untouched cells' badges to "unknown". State
# now lives in status.json on the site branch and is merged into, the
# same shape con/git-annex uses for its client badges.
#
# History on the site branch is kept rather than force-pushed: status.json
# then doubles as a log of when each cell changed state.
#
# usage:
#   bin/ci/publish-status.sh [--dry-run]
#
# env:
#   GH_TOKEN                 token with contents:write (required unless --dry-run)
#   GITHUB_REPOSITORY        owner/repo (default: repo-slug from matrix.yaml)
#   GITHUB_RUN_ID            used to fetch job URLs, and recorded per cell
#   GITHUB_RUN_NUMBER        }  the per-cell monotonic guard
#   GITHUB_RUN_ATTEMPT       }
#   EVAL_UNDER_SITE_BRANCH   branch to publish to (default: gh-pages)
#   EVAL_UNDER_RESULTS_DIR   downloaded result-* artifacts (default: results)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

BRANCH="${EVAL_UNDER_SITE_BRANCH:-gh-pages}"
REPO="${GITHUB_REPOSITORY:-$EVAL_UNDER_REPO_SLUG}"
RESULTS="${EVAL_UNDER_RESULTS_DIR:-results}"

work="$(mktemp -d)"
jobs_json="$(mktemp)"
trap 'rm -rf "$work" "$jobs_json"' EXIT

# Existing site, so status.json can be merged into rather than replaced.
# A first run (no branch yet) starts from an empty tree.
remote="https://github.com/${REPO}"
[ -n "${GH_TOKEN:-}" ] && remote="https://x-access-token:${GH_TOKEN}@github.com/${REPO}"
if git clone -q --depth 1 --branch "$BRANCH" "$remote" "$work" 2>/dev/null; then
    echo "I: cloned existing $BRANCH"
else
    echo "I: $BRANCH does not exist yet; starting a fresh site"
    rm -rf "$work"; mkdir -p "$work"
    git init -q "$work"
fi

# Per-cell log URLs. Job names come straight from the matrix entry's
# `name`, so they match exactly -- same resolution trick as
# con/git-annex's .github/workflows/tools/set-pr-status.
if [ -n "${GITHUB_RUN_ID:-}" ] && command -v gh >/dev/null 2>&1; then
    if gh api --paginate "repos/${REPO}/actions/runs/${GITHUB_RUN_ID}/jobs" \
         > "$jobs_json" 2>/dev/null; then
        echo "I: fetched job list for run ${GITHUB_RUN_ID}"
    else
        echo "W: could not fetch job list; report links will be empty" >&2
        : > "$jobs_json"
    fi
else
    echo "I: no run id or no gh; skipping job-URL resolution"
    : > "$jobs_json"
fi

"$here/update-status.py" "$work/status.json" "$RESULTS" --jobs "$jobs_json"
"$here/render-report.py" "$work/status.json" "$work"

if [ "$DRY_RUN" = 1 ]; then
    echo "I: --dry-run; site left in $work"
    trap - EXIT
    rm -f "$jobs_json"
    exit 0
fi

: "${GH_TOKEN:?GH_TOKEN required to push (or pass --dry-run)}"

cd "$work"
git config user.email "actions@github.com"
git config user.name  "eval-under CI"
git add -A
if git diff --cached --quiet; then
    echo "I: nothing changed; not pushing"
    exit 0
fi
git commit -q -m "Status for run ${GITHUB_RUN_NUMBER:-?} (${GITHUB_RUN_ID:-local})"
echo "I: pushing to $BRANCH"
git push -q "$remote" "HEAD:refs/heads/$BRANCH"
echo "I: published https://${REPO%%/*}.github.io/${REPO#*/}/"
