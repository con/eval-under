#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Print the filename-safe slug for one matrix cell. Exists so the
# workflow YAML can name artifacts without reimplementing the "n/a"
# handling in GitHub expression syntax -- bin/ci/matrix.sh stays the
# single source of truth for how a cell is named.
#
# usage:
#   bin/ci/cell-slug.sh <backend> <version> <target>
#
# e.g.
#   bin/ci/cell-slug.sh nfs n/a git        -> nfs-git
#   bin/ci/cell-slug.sh loop vfat pjdfstest -> loop-vfat-pjdfstest

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

cell_slug "${1:?backend required}" "${2:?version required}" "${3:?target required}"
