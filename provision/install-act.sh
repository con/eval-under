#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.63 / Claude Opus 4.7
#
# Opt-in: install nektos/act inside the VM for local GH workflow replays.
# Enable via `VAGRANT_INSTALL_ACT=1 vagrant up` (or `vagrant provision`).

set -euo pipefail

if command -v act >/dev/null; then
  echo "act already installed: $(act --version)"
  exit 0
fi

curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh \
  | bash -s -- -b /usr/local/bin

echo "installed: $(act --version)"
