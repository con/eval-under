#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Run shellcheck on every shell script tracked in the repository.
#
# Scripts are found by what they are, not where they live: any tracked
# file whose *first line* is a sh/bash/dash/ksh shebang (or a
# `# shellcheck shell=...` directive). A fixed glob like `bin/ci/*.sh`
# silently misses provision/*.sh and the extension-less bin/eval-under*.
# Same discovery as yarikoptic/improveit's shellcheckit.
#
# usage:
#   bin/ci/shellcheck.sh [--list] [shellcheck options...]
#
#   --list   only print the scripts that would be checked
#
# Extra arguments go to shellcheck, e.g. `bin/ci/shellcheck.sh -S style`.
# Run from anywhere inside the repository.

set -euo pipefail

usage() {
    sed -n '/^# usage:/,/^# Run from/{s/^# \{0,1\}//;p}' "$0"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

cd "$(git rev-parse --show-toplevel)"

# Deliberately narrow: zsh (and `env zsh`) scripts are not shellcheck's.
shebang='^#\( *shellcheck \|!\(/bin/\|/usr/bin/env \)\(sh\|bash\|dash\|ksh\)\)'

mapfile -t scripts < <(
    git grep -n "$shebang" -- ':!*.md' ':!*.txt' \
        | sed -n -e 's,^\([^:]*\):1:#.*,\1,p'
)

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${scripts[@]}"
    exit 0
fi

[ "${#scripts[@]}" -gt 0 ] || { echo "no shell scripts found" >&2; exit 1; }
command -v shellcheck >/dev/null || {
    echo "shellcheck not found -- apt-get install shellcheck" >&2
    exit 1
}

echo "I: $(shellcheck --version | sed -n 's/^version: //p'): ${#scripts[@]} script(s)"
shellcheck "$@" "${scripts[@]}"
echo "I: all clean"
