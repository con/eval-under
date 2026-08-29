#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Provision an Ubuntu 24.04 VM to develop/test the eval-under harness:
#   - Docker CE + compose plugin                     (eval-under-beegfs)
#   - BeeGFS client kernel module (DKMS) + helperd   (eval-under-beegfs)
#   - nfs-kernel-server                              (eval-under-nfs)
#   - dosfstools + xfsprogs + btrfs-progs            (eval-under-loop, per fs)
#   - git-annex + git (Ubuntu apt versions, enough to smoke-test the wrapper)
#   - stress-ng + build deps for the git / pjdfstest targets
#     (the source builds themselves stay opt-in: run
#      `bin/ci/install-target.sh {git,pjdfstest}` inside the VM)
#
# Idempotent: safe to re-run via `vagrant provision`.

set -euo pipefail

BEEGFS_VERSION="${BEEGFS_VERSION:-7.4.6}"
# BeeGFS APT repo uses the full point-release in the path
# (e.g. beegfs_7.4.6/, not beegfs_7.4/).

log() { printf '\n=== %s ===\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

log "Base packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  build-essential dkms "linux-headers-$(uname -r)" \
  git git-annex jq

log "eval-under-nfs / eval-under-loop dependencies"
# nfs-kernel-server: provides exportfs + mount.nfs (eval-under-nfs).
# dosfstools:        mkfs.vfat (eval-under-loop --fs vfat, the default).
# xfsprogs:          mkfs.xfs  (eval-under-loop --fs xfs).
# btrfs-progs:       mkfs.btrfs (eval-under-loop --fs btrfs).
# e2fsprogs is preinstalled on Ubuntu (mkfs.ext4).
apt-get install -y --no-install-recommends \
  nfs-kernel-server \
  dosfstools xfsprogs btrfs-progs

log "eval-under-9p-tcp / eval-under-9p-virtio dependencies"
# diod:            9P2000.L server for eval-under-9p-tcp.
# virtme-ng:       boots the eval-under-9p-virtio guest (vng); the VM's
#                  nested KVM (Vagrantfile: lv.nested) accelerates it.
# qemu-system-x86: virtme-ng only Recommends it; --no-install-recommends.
# virtiofsd:       vng rootfs transport (falls back to 9p without it).
# busybox-static:  vng initramfs for pinned --kernel downloads.
# zstd:            mainline kernel debs ship .ko.zst modules.
# 9p client modules ship in the kernel's base linux-modules package.
apt-get install -y --no-install-recommends \
  diod virtme-ng qemu-system-x86 qemu-utils virtiofsd busybox-static zstd

log "eval-under test-target dependencies"
# stress-ng:                    bin/ci/target-stress-ng.sh (apt is the whole install).
# autoconf/automake/libtool:    building pjdfstest from its pinned tag.
# gettext + lib*-dev:           building git from its pinned tag.
# The clones + builds are deliberately NOT done here (minutes of
# provisioning for something not every VM needs) -- run
# `bin/ci/install-target.sh git` / `... pjdfstest` in the VM on demand.
apt-get install -y --no-install-recommends \
  stress-ng \
  autoconf automake libtool \
  gettext zlib1g-dev libssl-dev libcurl4-openssl-dev libexpat1-dev

log "Docker CE + compose plugin"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091  # /etc/os-release provided by the OS
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker vagrant || true
systemctl enable --now docker

log "BeeGFS APT repo (v${BEEGFS_VERSION})"
# Prefer a list file for the current Ubuntu codename; fall back to jammy
# if the newer codename isn't yet published (BeeGFS DKMS still builds).
# shellcheck disable=SC1091  # /etc/os-release provided by the OS
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
list_url="https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-${codename}.list"
if ! curl -fsI "$list_url" >/dev/null 2>&1; then
  echo "beegfs-${codename}.list not published upstream; falling back to jammy" >&2
  list_url="https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-jammy.list"
fi
curl -fsSL "$list_url" -o /etc/apt/sources.list.d/beegfs.list
curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/gpg/GPG-KEY-beegfs" \
  -o /etc/apt/trusted.gpg.d/beegfs.asc
apt-get update -qq

log "BeeGFS client (DKMS) + helperd + utils"
# Install with || true because the DKMS postinst occasionally fails on
# the first try (races with concurrent apt hooks); we recover below with
# an explicit `dkms install` + `dpkg --configure -a`.
apt-get install -y --no-install-recommends \
  beegfs-client-dkms beegfs-helperd beegfs-utils || true

if ! modinfo beegfs >/dev/null 2>&1; then
  echo "beegfs module not built yet; running dkms install explicitly" >&2
  # `dkms status` reports "beegfs/<ver>: added" when the source is there
  # but the module wasn't built for the running kernel.
  beegfs_ver="$(dkms status beegfs 2>/dev/null | awk -F'[/,: ]' '{print $2; exit}')"
  if [ -n "${beegfs_ver:-}" ]; then
    dkms install "beegfs/${beegfs_ver}" -k "$(uname -r)"
  fi
  dpkg --configure -a
fi

if ! modinfo beegfs >/dev/null 2>&1; then
  echo "ERROR: beegfs kernel module still not available after retry." >&2
  dkms status || true
  exit 1
fi

# helperd disabled by default — eval-under-beegfs starts it on demand.
systemctl disable --now beegfs-helperd || true

log "Provisioning complete"
echo "  git-annex : $(git-annex version | head -1)"
echo "  docker    : $(docker --version)"
echo "  beegfs mod: $(modinfo -F version beegfs 2>/dev/null || echo '?')"
echo "  stress-ng : $(stress-ng --version 2>/dev/null | head -1 || echo missing)"
echo "  mkfs.vfat : $(command -v mkfs.vfat || echo missing)"
echo "  mkfs.xfs  : $(command -v mkfs.xfs  || echo missing)"
echo "  exportfs  : $(command -v exportfs  || echo missing)"
