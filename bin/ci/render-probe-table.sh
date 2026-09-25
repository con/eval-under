#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render the probe run's per-candidate SUMMARY lines as one Markdown
# table plus the raw capability profiles, so answering "which candidates
# came up?" does not mean opening two dozen job logs.
#
# Reads the artifacts that .github/workflows/probe-filesystems.yaml
# downloads, one summary.txt per candidate, each holding a single line:
#
#   SUMMARY|<runner>|<candidate>|<verdict>|<time>|<note>|<key=value ...>
#
# usage:
#   bin/ci/render-probe-table.sh [SUMMARIES_DIR]
#
#   SUMMARIES_DIR  directory of downloaded artifacts (default: summaries)
#
# Writes Markdown to stdout. The workflow tees that into
# $GITHUB_STEP_SUMMARY; run it locally against a directory of summary
# files to see exactly what CI will show.

set -euo pipefail

DIR="${1:-summaries}"

[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 2; }

# Nothing to roll up is worth saying out loud rather than rendering an
# empty table: it means every probe job failed before writing its line.
shopt -s nullglob
files=("$DIR"/*/summary.txt)
shopt -u nullglob
if [ "${#files[@]}" = 0 ]; then
    echo "No summary artifacts found under $DIR -- every probe job failed"
    echo "before recording a verdict."
    exit 0
fi

echo "| runner | candidate | verdict | time | note |"
echo "| --- | --- | --- | --- | --- |"
# Sort by verdict then candidate so the BOOTSTRAPPED block reads together.
sort -t'|' -k3,3 -k2,2 "${files[@]}" \
    | awk -F'|' '{printf "| %s | `%s` | **%s** | %s | %s |\n", $2, $3, $4, $5, $6}'

echo
echo "### Capability profiles"
echo
echo '```'
sort "${files[@]}"
echo '```'
