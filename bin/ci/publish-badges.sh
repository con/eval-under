#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render one badge per matrix cell and publish them to a dedicated
# branch (default: `badges`), which the README then points at.
#
# Why a branch: GitHub publishes one badge per *workflow file*, so the
# 20-cell grid used to need 20 near-identical workflow files. With a
# single matrix workflow there is exactly one built-in badge, so the
# per-cell grid has to come from somewhere else. Committing our own
# SVGs to an orphan branch keeps the grid, adds no third-party
# dependency, and costs one commit per run on master.
#
# The branch is orphan and force-pushed: it holds generated state, not
# history. Nothing is ever merged from it, and `badges` never appears
# in the main line's history.
#
# Each matrix cell uploads a `result-<slug>` artifact holding its own
# conclusion; this reads them back. A cell with no artifact renders as
# "unknown" rather than being silently dropped -- a vanished cell is a
# worse failure than a red one, so it has to be visible.
#
# usage:
#   bin/ci/publish-badges.sh <results-dir> [--dry-run]
#
# env:
#   EVAL_UNDER_BADGE_BRANCH   branch to publish to     (badges)
#   GH_TOKEN                  token with contents:write (required
#                             unless --dry-run)
#   GITHUB_REPOSITORY         owner/repo               (falls back to
#                             repo-slug from .github/matrix.yaml)
#   GITHUB_RUN_ID             recorded in the commit message, so a
#                             badge can be traced back to its run

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

RESULTS_DIR="${1:?results directory required}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

BRANCH="${EVAL_UNDER_BADGE_BRANCH:-badges}"
REPO="${GITHUB_REPOSITORY:-$EVAL_UNDER_REPO_SLUG}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# actions/download-artifact drops each artifact into its own
# subdirectory, so a cell's conclusion lands at
# <results-dir>/result-<slug>/conclusion. Accept a flat layout too, so
# the script can be exercised locally without faking that structure.
read_conclusion() {
    local slug="$1" f
    for f in "$RESULTS_DIR/result-$slug/conclusion" "$RESULTS_DIR/$slug"; do
        if [ -r "$f" ]; then
            tr -d '[:space:]' < "$f"
            return 0
        fi
    done
    echo "unknown"
}

count=0 missing=0
for cell in "${EVAL_UNDER_BACKENDS[@]}"; do
    IFS='|' read -r backend version blabel <<< "$cell"
    for target in "${EVAL_UNDER_TARGETS[@]}"; do
        slug="$(cell_slug "$backend" "$version" "$target")"
        conclusion="$(read_conclusion "$slug")"
        [ "$conclusion" = "unknown" ] && missing=$(( missing + 1 ))
        "$here/render-badge.sh" "$conclusion" \
            "$blabel / $(target_label "$target")" > "$staging/$slug.svg"
        count=$(( count + 1 ))
        printf 'I: %-28s %s\n' "$slug" "$conclusion"
    done
done

echo "I: rendered $count badge(s), $missing without a result artifact"

if [ "$DRY_RUN" = 1 ]; then
    echo "I: --dry-run; badges left in $staging"
    trap - EXIT
    exit 0
fi

: "${GH_TOKEN:?GH_TOKEN required to push (or pass --dry-run)}"

work="$(mktemp -d)"
trap 'rm -rf "$staging" "$work"' EXIT

cp "$staging"/*.svg "$work/"
cd "$work"
git init -q
git config user.email "actions@github.com"
git config user.name  "eval-under CI"
git add -A
git commit -q -m "Badges for ${GITHUB_RUN_ID:-local} ($count cells, $missing unknown)"
echo "I: pushing $count badge(s) to $BRANCH"
git push -q --force \
    "https://x-access-token:${GH_TOKEN}@github.com/${REPO}" \
    "HEAD:refs/heads/$BRANCH"
echo "I: published to https://github.com/$REPO/tree/$BRANCH"
