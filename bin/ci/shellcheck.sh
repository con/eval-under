#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Run shellcheck on every tracked file whose first line is an
# sh/bash/dash/ksh shebang or a `# shellcheck` directive -- wherever it
# lives. Same discovery as yarikoptic/improveit's shellcheckit.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: bin/ci/shellcheck.sh [--list] [shellcheck options...]

  --list   only print the scripts that would be checked

env overrides:
  SHELLCHECK   shellcheck binary (default: shellcheck)
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

cd "$(git rev-parse --show-toplevel)"

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
SHELLCHECK="${SHELLCHECK:-shellcheck}"
command -v "$SHELLCHECK" >/dev/null || {
    echo "shellcheck not found -- apt-get install shellcheck" >&2
    exit 1
}

echo "I: shellcheck $("$SHELLCHECK" --version | sed -n 's/^version: //p'): ${#scripts[@]} script(s)"
"$SHELLCHECK" "$@" "${scripts[@]}"
echo "I: all clean"
