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
#   backend  = beegfs | nfs | loop | 9p-tcp | 9p-virtio
#   version  = for beegfs:    point release (e.g. 7.4.6, 8.1.0)
#              for loop:      filesystem type (e.g. vfat, ext4, xfs, btrfs)
#              for nfs:       literal "n/a"
#              for 9p-tcp:    literal "n/a"
#              for 9p-virtio: security-model row (mapped, passthrough) --
#                             same packages either way
#
# Idempotent enough for CI re-runs; not a full package manager.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library (pinned refs, e.g. the 9p guest
# kernel), resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

BACKEND="${1:?backend required (beegfs|nfs|loop|9p-tcp|9p-virtio)}"
VERSION="${2:?version required (BeeGFS version | loop fs name | 9p variant | 'n/a')}"

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

install_loop() {
    local pkg
    case "$VERSION" in
        vfat|msdos)         pkg=dosfstools ;;
        xfs)                pkg=xfsprogs ;;
        btrfs)              pkg=btrfs-progs ;;
        ext2|ext3|ext4)     pkg=e2fsprogs ;;  # usually preinstalled
        *) echo "unknown loop filesystem: $VERSION" >&2; exit 1 ;;
    esac
    apt_update
    apt_install "$pkg"
    command -v "mkfs.$VERSION"
}

install_9p_tcp() {
    apt_update
    apt_install diod
    command -v diod
    # 9p client modules ship in the kernel's base linux-modules package
    # on generic, virtual and azure flavours alike -- no modules-extra
    # needed. Load and prove the filesystem is registered now, so a
    # missing module is an install-step error, not a mid-suite one.
    sudo modprobe -a 9p 9pnet_fd
    grep -w 9p /proc/filesystems
}

install_9p_virtio() {
    apt_update
    # virtme-ng only Recommends qemu and Suggests virtiofsd, and this
    # script installs with --no-install-recommends -- list everything
    # explicitly. busybox-static: vng builds an initramfs for a pinned
    # --run kernel and finds no busybox on the runner images otherwise.
    # zstd: the mainline kernel debs ship .ko.zst modules and vng shells
    # out to zstd for them (a guest that dies with vng's 255 sentinel
    # after "zstd: not found" is this). Without virtiofsd, vng silently
    # serves the rootfs over 9p instead (works, but slower and it
    # shares the transport under test).
    apt_install qemu-system-x86 qemu-utils virtme-ng virtiofsd busybox-static zstd
    vng --version

    # KVM node permissions for the unprivileged prewarm below (the
    # run-under.sh invocation is root via sudo -E and needs only the
    # node to exist). Standard GitHub Linux runners have had KVM since
    # 2024; this is the documented enablement.
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
        | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
    ls -l /dev/kvm

    # Pre-warm outside the suite's timeout: the pinned mainline kernel
    # is a ~180 MB one-time download into ~/.cache/virtme-ng (the
    # sudo -E run later resolves to the same HOME), and this doubles as
    # a boot smoke test -- a vng/KVM problem fails the install step
    # with its own logs instead of a red cell mid-matrix.
    timeout 600 vng --run "$EVAL_UNDER_9P_KERNEL_REF" --disable-microvm \
        --memory 1G -- true
}

case "$BACKEND" in
    beegfs)    install_beegfs ;;
    nfs)       install_nfs ;;
    loop)      install_loop ;;
    9p-tcp)    install_9p_tcp ;;
    9p-virtio) install_9p_virtio ;;
    *) echo "unknown backend: $BACKEND (expected beegfs|nfs|loop|9p-tcp|9p-virtio)" >&2; exit 1 ;;
esac
