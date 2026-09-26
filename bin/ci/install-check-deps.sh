#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Runner-side install of what bin/ci/run-checks.sh needs: shellcheck and
# bats. Both are packaged everywhere we care about (Debian, Ubuntu), so
# this is deliberately apt-only -- no vendored bats-core submodule, no
# bats-assert / bats-support.
#
# usage:
#   bin/ci/install-check-deps.sh
#
# env overrides:
#   EVAL_UNDER_CHECK_PKGS   packages to install   (shellcheck bats python3-yaml)
#
# Idempotent: already-installed packages are left alone by apt-get.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

read -r -a PKGS <<<"${EVAL_UNDER_CHECK_PKGS:-shellcheck bats python3-yaml}"

SUDO=()
[ "$(id -u)" -eq 0 ] || SUDO=(sudo)

# Same dpkg-lock accommodation as install-backend.sh: ubuntu-22.04
# runners run unattended-upgrades for a minute or so after boot.
APT_LOCK_TIMEOUT=(-o "DPkg::Lock::Timeout=60")

"${SUDO[@]}" apt-get "${APT_LOCK_TIMEOUT[@]}" update
"${SUDO[@]}" apt-get "${APT_LOCK_TIMEOUT[@]}" install -y --no-install-recommends "${PKGS[@]}"

shellcheck --version | sed -n '2p'
bats --version
