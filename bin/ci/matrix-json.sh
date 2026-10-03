#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render evals/matrix.yaml as the value of a GitHub Actions `matrix:`
# key -- i.e. {"include": [ {...}, ... ]} -- for consumption via
# fromJson() in .github/workflows/test.yaml.
#
# Each entry carries everything the job body needs, so the workflow
# never has to recompute anything about a cell:
#
#   name     job name, e.g. "BeeGFS 7.4.6 / git testsuite". Set as the
#            job's `name:` so the checks list reads like the README grid
#            instead of GitHub's default "test (beegfs, 7.4.6, git)".
#   backend  eval-under backend        (beegfs | nfs | loop)
#   version  backend version, or "n/a"
#   target   suite to run under it
#   slug     filename-safe cell id, for artifact names
#   needs-git-annex
#            whether this cell's suite needs the git-annex daily build,
#            straight from evals/matrix.yaml. The workflow gates the
#            fetch step on it, so adding a git-annex-using target stays
#            a data edit. Referenced as matrix['needs-git-annex'], the
#            documented index form for a property name with hyphens.
#
# usage:
#   bin/ci/matrix-json.sh            # all cells
#
# The output is a single line: GitHub's `fromJson` wants one value, and
# a multi-line $GITHUB_OUTPUT needs heredoc quoting for no benefit.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

entries=()
for cell in "${EVAL_UNDER_BACKENDS[@]}"; do
    IFS='|' read -r backend version label <<< "$cell"
    for target in "${EVAL_UNDER_TARGETS[@]}"; do
        # Not every backend x target pair is a cell -- see cell_enabled()
        # in matrix.sh.
        cell_enabled "$backend" "$version" "$target" || continue
        needs_ga=0
        target_needs_git_annex "$target" && needs_ga=1
        entries+=("$backend|$version|$label|$target|$(target_label "$target")|$(cell_slug "$backend" "$version" "$target")|$needs_ga")
    done
done

printf '%s\n' "${entries[@]}" | python3 -c '
import json, sys

include = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    backend, version, blabel, target, tlabel, slug, needs_ga = line.split("|")
    include.append({
        "name": "%s / %s" % (blabel, tlabel),
        "backend": backend,
        "version": version,
        "target": target,
        "slug": slug,
        "needs-git-annex": needs_ga == "1",
    })

if not include:
    sys.exit("matrix-json: no cells produced")
print(json.dumps({"include": include}, separators=(",", ":")))
'
