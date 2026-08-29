#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render .github/matrix.yaml as the value of a GitHub Actions `matrix:`
# key -- i.e. {"include": [ {...}, ... ]} -- for consumption via
# fromJson() in .github/workflows/test.yaml.
#
# Each entry carries everything the job body needs, so the workflow
# never has to recompute anything about a cell:
#
#   name     job name, e.g. "BeeGFS 7.4.6 / git testsuite". Set as the
#            job's `name:` so the checks list reads like the README grid
#            instead of GitHub's default "test (beegfs, 7.4.6, git)".
#   backend  eval-under backend        (beegfs | nfs | loop | 9p-*)
#   version  backend version, or "n/a"
#   target   suite to run under it
#   slug     filename-safe cell id, for artifact names
#   runs-on  runner image for this cell (per-backend in matrix.yaml,
#            default ubuntu-22.04)
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
    IFS='|' read -r backend version label runs_on <<< "$cell"
    for target in "${EVAL_UNDER_TARGETS[@]}"; do
        entries+=("$backend|$version|$label|$runs_on|$target|$(target_label "$target")|$(cell_slug "$backend" "$version" "$target")")
    done
done

printf '%s\n' "${entries[@]}" | python3 -c '
import json, sys

include = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    backend, version, blabel, runs_on, target, tlabel, slug = line.split("|")
    include.append({
        "name": "%s / %s" % (blabel, tlabel),
        "backend": backend,
        "version": version,
        "target": target,
        "slug": slug,
        "runs-on": runs_on,
    })

if not include:
    sys.exit("matrix-json: no cells produced")
print(json.dumps({"include": include}, separators=(",", ":")))
'
