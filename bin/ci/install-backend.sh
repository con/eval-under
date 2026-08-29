#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code 2.1.233 / Claude Opus 4.7
#
# Runner-side install of eval-under backend client dependencies.
#
# usage:
#   bin/ci/install-backend.sh <backend> <version>
#
#   backend  = beegfs | nfs | loop | sshfs
#   version  = for beegfs: point release (e.g. 7.4.6, 8.1.0)
#              for loop:   filesystem type (e.g. vfat, ext4, xfs, btrfs)
#              for nfs:    literal "n/a"
#              for sshfs:  literal "n/a"
#
# Idempotent enough for CI re-runs; not a full package manager.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

BACKEND="${1:?backend required (beegfs|nfs|loop|sshfs)}"
VERSION="${2:?version required (BeeGFS version | loop fs name | 'n/a' for nfs)}"

# Give unattended-upgrades a moment on ubuntu-22.04 runners rather than
# hard-failing on a dpkg lock.
APT_LOCK_TIMEOUT=(-o "DPkg::Lock::Timeout=60")

apt_install() {
    sudo apt-get "${APT_LOCK_TIMEOUT[@]}" install -y --no-install-recommends "$@"
}

apt_update() {
    sudo apt-get "${APT_LOCK_TIMEOUT[@]}" update -qq
}

install_beegfs() {
    local codename list_url major pkgs
    # shellcheck disable=SC1091  # /etc/os-release provided by the OS
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    list_url="https://www.beegfs.io/release/beegfs_${VERSION}/dists/beegfs-${codename}.list"
    if ! curl -fsI "$list_url" >/dev/null 2>&1; then
        list_url="https://www.beegfs.io/release/beegfs_${VERSION}/dists/beegfs-jammy.list"
    fi
    sudo curl -fsSL "$list_url" -o /etc/apt/sources.list.d/beegfs.list
    sudo curl -fsSL "https://www.beegfs.io/release/beegfs_${VERSION}/gpg/GPG-KEY-beegfs" \
        -o /etc/apt/trusted.gpg.d/beegfs.asc
    apt_update

    # v8 dropped `beegfs-helperd` as a standalone package and renamed
    # `beegfs-utils` -> `beegfs-tools`. In v8, `beegfs-client` and
    # `beegfs-client-dkms` mutually Conflict: pick one. We want DKMS to
    # build against the runner's kernel, so `beegfs-client-dkms` -- helperd
    # absence is handled inside `bin/eval-under-beegfs` (skips startup +
    # disables the mount sanity check).
    major="${VERSION%%.*}"
    if [ "$major" = "7" ]; then
        pkgs=(beegfs-client-dkms beegfs-helperd beegfs-utils)
    else
        pkgs=(beegfs-client-dkms beegfs-tools)
    fi
    apt_install dkms "linux-headers-$(uname -r)" "${pkgs[@]}"
    modinfo beegfs
    # Diagnostic listing of installed BeeGFS bins.
    # shellcheck disable=SC2012  # ls output is human-facing, not parsed
    ls /opt/beegfs/sbin/ 2>&1 | head
}

install_nfs() {
    apt_update
    apt_install nfs-kernel-server
    command -v exportfs
}

install_sshfs() {
    apt_update
    # openssh-sftp-server is what actually serves the mount; on Ubuntu it
    # is pulled in by openssh-server, but name it so a slimmer image
    # cannot leave us without an sftp-server binary.
    apt_install sshfs openssh-server openssh-sftp-server
    command -v sshfs
    # The backend starts its own sshd, so the system one need not run --
    # but its privilege-separation directory must exist.
    sudo mkdir -p /run/sshd
}

install_loop() {
    local pkg
    case "$VERSION" in
        vfat|msdos)         pkg=dosfstools ;;
        xfs)                pkg=xfsprogs ;;
        btrfs)              pkg=btrfs-progs ;;
        ext2|ext3|ext4)     pkg=e2fsprogs ;;  # usually preinstalled
        gfs2)               pkg=gfs2-utils ;;
        ocfs2)              pkg=ocfs2-tools ;;
        f2fs)               pkg=f2fs-tools ;;
        exfat)              pkg=exfatprogs ;;
        nilfs2)             pkg=nilfs-tools ;;
        bcachefs)           pkg=bcachefs-tools ;;
        *) echo "unknown loop filesystem: $VERSION" >&2; exit 1 ;;
    esac
    apt_update
    apt_install "$pkg"
    command -v "mkfs.$VERSION"

    # gfs2 and ocfs2 ship in linux-modules-extra rather than the base
    # kernel package. It is present on GitHub-hosted runners, but say so
    # out loud here rather than discovering it as an "unknown filesystem
    # type" at mount time.
    case "$VERSION" in
        gfs2|ocfs2)
            if ! sudo modprobe "$VERSION"; then
                apt_install "linux-modules-extra-$(uname -r)"
                sudo modprobe "$VERSION"
            fi
            ;;
    esac
}

case "$BACKEND" in
    beegfs) install_beegfs ;;
    nfs)    install_nfs ;;
    loop)   install_loop ;;
    sshfs)  install_sshfs ;;
    *) echo "unknown backend: $BACKEND (expected beegfs|nfs|loop|sshfs)" >&2; exit 1 ;;
esac
