#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Answer one question empirically, for one candidate filesystem:
#
#   can a throwaway instance of it be stood up on a stock GitHub-hosted
#   Ubuntu runner, and if so, what does it actually support?
#
# This is *reconnaissance*, not a backend. A candidate that comes up
# green here is a candidate for a real `bin/eval-under-<name>`; one that
# comes up red tells us why (no kernel module / no package / needs a
# cluster / needs a VM) without anyone having to write the backend
# first. See FILESYSTEMS.md for the survey this feeds.
#
# usage:
#   bin/ci/probe-backend.sh CANDIDATE
#   bin/ci/probe-backend.sh --list
#
#   CANDIDATE  one of the names printed by --list
#
# env:
#   EVAL_UNDER_PROBE_DIR   scratch directory (default /var/tmp/eu-probe)
#   EVAL_UNDER_PROBE_KEEP  non-empty: skip teardown (local debugging)
#
# Exit status is the finding: 0 = the filesystem mounted and was
# probed, 1 = it could not be brought up here. Either way the log says
# how far it got, and a one-line verdict lands in $GITHUB_STEP_SUMMARY.

# Deliberately no `-e`: a probe that dies on the first failed command
# reports nothing. Failures are caught per step and turned into a
# verdict instead.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

HERE="$(cd "$(dirname "$0")" && pwd)"

CANDIDATES=(
    gfs2 ocfs2 f2fs exfat ntfs3 udf nilfs2 bcachefs zfs overlay
    glusterfs cephfs cifs sshfs gocryptfs encfs ecryptfs s3-rclone
    lustre-client openafs vm-only
)

usage() {
    cat <<EOF
Usage: bin/ci/probe-backend.sh CANDIDATE
       bin/ci/probe-backend.sh --list

Try to bring up CANDIDATE on this machine, run bin/ci/fs-capabilities.sh
on the resulting mount, then tear it down.

Candidates: ${CANDIDATES[*]}

Env: EVAL_UNDER_PROBE_DIR (scratch dir), EVAL_UNDER_PROBE_KEEP (skip teardown).
EOF
}

case "${1:-}" in
    ''|-h|--help) usage; exit 2 ;;
    --list) printf '%s\n' "${CANDIDATES[@]}"; exit 0 ;;
esac

CANDIDATE="$1"
PROBE_DIR="${EVAL_UNDER_PROBE_DIR:-/var/tmp/eu-probe}"
MNT="$PROBE_DIR/mnt"
NOTE=""

mkdir -p "$MNT"

APT_LOCK_TIMEOUT=(-o "DPkg::Lock::Timeout=120")
apt_update() { sudo apt-get "${APT_LOCK_TIMEOUT[@]}" update -qq; }
apt_install() {
    apt_update || true
    sudo apt-get "${APT_LOCK_TIMEOUT[@]}" install -y --no-install-recommends "$@"
}

# Deferred teardown: commands are run in reverse registration order.
CLEANUPS=()
defer() { CLEANUPS+=("$1"); }
# shellcheck disable=SC2317  # invoked from the EXIT trap, not inline
run_cleanups() {
    [ -n "${EVAL_UNDER_PROBE_KEEP:-}" ] && { echo "I: --keep: leaving $MNT"; return; }
    local i
    for (( i=${#CLEANUPS[@]}-1; i>=0; i-- )); do
        echo "I: cleanup: ${CLEANUPS[$i]}"
        # shellcheck disable=SC2086  # cleanup entries are our own literals
        eval "${CLEANUPS[$i]}" || true
    done
}
trap run_cleanups EXIT

# Fail a probe with a reason that ends up in the summary line.
give_up() { NOTE="$*"; echo "E: $*" >&2; return 1; }

# Load a kernel module, installing the runner's modules-extra package
# first if the module is not there at all. On GitHub-hosted runners the
# kernel is linux-azure and several filesystems live in
# linux-modules-extra-<uname -r>, which is *not* always preinstalled.
need_module() {
    local mod="$1"
    if sudo modprobe "$mod" 2>/dev/null; then return 0; fi
    echo "I: modprobe $mod failed, trying linux-modules-extra-$(uname -r)"
    apt_install "linux-modules-extra-$(uname -r)" || true
    sudo modprobe "$mod" 2>/dev/null || give_up "no kernel module: $mod"
}

# A loop device backed by a sparse file. Sets $LOOP rather than echoing
# it: command substitution would run this in a subshell and the `defer`
# registration would be lost with it.
LOOP=""
make_loop() {
    local size="${1:-1G}" img="$PROBE_DIR/img.$$"
    truncate -s "$size" "$img" || return 1
    LOOP="$(sudo losetup --find --show "$img")" || return 1
    defer "sudo losetup -d $LOOP; rm -f $img"
}

mount_and_own() {
    sudo mount "$@" || return 1
    defer "sudo umount -l $MNT"
    sudo chown "$(id -u):$(id -g)" "$MNT" 2>/dev/null || true
}

# ---------------------------------------------------------------- probes

# GFS2 and OCFS2 are cluster filesystems, but both have a single-node
# locking mode meant for exactly this: no corosync/dlm, no pacemaker,
# just a block device. Red Hat and Oracle both document it as
# test/development-only, which is what we are.
setup_gfs2() {
    apt_install gfs2-utils || give_up "gfs2-utils not installable" || return 1
    need_module gfs2 || return 1
    local loop; make_loop 1G || return 1; loop="$LOOP"
    sudo mkfs.gfs2 -O -p lock_nolock -j 1 "$loop" || give_up "mkfs.gfs2 failed" || return 1
    mount_and_own -t gfs2 -o lockproto=lock_nolock "$loop" "$MNT"
}

setup_ocfs2() {
    apt_install ocfs2-tools || give_up "ocfs2-tools not installable" || return 1
    need_module ocfs2 || return 1
    local loop; make_loop 1G || return 1; loop="$LOOP"
    sudo mkfs.ocfs2 -F -b 4K -C 32K -N 1 -M local "$loop" \
        || give_up "mkfs.ocfs2 failed" || return 1
    mount_and_own -t ocfs2 "$loop" "$MNT"
}

# Plain loop filesystems the existing `loop` backend does not cover yet.
setup_loopfs() {
    local fs="$1" pkg="$2" mkfs_opts="$3" mount_opts="${4:-}"
    apt_install "$pkg" || give_up "$pkg not installable" || return 1
    need_module "$fs" || return 1
    local loop; make_loop 1G || return 1; loop="$LOOP"
    # shellcheck disable=SC2086  # mkfs_opts is a deliberate word list
    sudo "mkfs.$fs" $mkfs_opts "$loop" || give_up "mkfs.$fs failed" || return 1
    if [ -n "$mount_opts" ]; then
        mount_and_own -t "$fs" -o "$mount_opts" "$loop" "$MNT"
    else
        mount_and_own -t "$fs" "$loop" "$MNT"
    fi
}

setup_f2fs()     { setup_loopfs f2fs f2fs-tools "-f"; }
setup_exfat()    { setup_loopfs exfat exfatprogs "" "uid=$(id -u),gid=$(id -g)"; }
setup_nilfs2()   { setup_loopfs nilfs2 nilfs-tools "-f"; }
setup_bcachefs() { setup_loopfs bcachefs bcachefs-tools "-f"; }

setup_ntfs3() {
    apt_install ntfs-3g || give_up "ntfs-3g not installable" || return 1
    need_module ntfs3 || return 1
    local loop; make_loop 1G || return 1; loop="$LOOP"
    sudo mkfs.ntfs -F -Q "$loop" || give_up "mkfs.ntfs failed" || return 1
    mount_and_own -t ntfs3 -o "uid=$(id -u),gid=$(id -g)" "$loop" "$MNT"
}

setup_udf() {
    apt_install udftools || give_up "udftools not installable" || return 1
    need_module udf || return 1
    local loop; make_loop 1G || return 1; loop="$LOOP"
    sudo mkudffs --media-type=hd "$loop" || give_up "mkudffs failed" || return 1
    mount_and_own -t udf "$loop" "$MNT"
}

setup_zfs() {
    apt_install zfsutils-linux || give_up "zfsutils-linux not installable" || return 1
    need_module zfs || return 1
    local img="$PROBE_DIR/zfs.img"
    truncate -s 2G "$img" || return 1
    sudo zpool create -f -m "$MNT" eu_probe "$img" || give_up "zpool create failed" || return 1
    defer "sudo zpool destroy eu_probe; rm -f $img"
    sudo chown "$(id -u):$(id -g)" "$MNT"
}

# The filesystem every containerised CI job is already sitting on.
setup_overlay() {
    local base="$PROBE_DIR/ovl"
    mkdir -p "$base"/{lower,upper,work}
    mount_and_own -t overlay overlay \
        -o "lowerdir=$base/lower,upperdir=$base/upper,workdir=$base/work" "$MNT"
}

# Single-node Gluster: one brick, one replica-1 volume, FUSE-mounted
# back over localhost. `force` is needed because the brick is on the
# root filesystem, which Gluster otherwise refuses.
setup_glusterfs() {
    apt_install glusterfs-server || give_up "glusterfs-server not installable" || return 1
    sudo systemctl start glusterd || sudo glusterd || give_up "glusterd will not start" || return 1
    defer "sudo systemctl stop glusterd || true"
    sudo systemctl --no-pager status glusterd 2>&1 | head -5 || true
    local brick="$PROBE_DIR/brick" host
    # Gluster records the brick's host in the volfile and insists it be a
    # peer; the node's own hostname is always one, 127.0.0.1 need not be.
    host="$(hostname -s)"
    sudo mkdir -p "$brick"
    sudo gluster --mode=script volume create eu_probe "$host:$brick" force \
        || give_up "volume create failed (see output above)" || return 1
    defer "sudo gluster --mode=script volume stop eu_probe; sudo gluster --mode=script volume delete eu_probe"
    sudo gluster --mode=script volume start eu_probe || give_up "volume start failed" || return 1
    sudo gluster volume info eu_probe || true
    mount_and_own -t glusterfs "$host:/eu_probe" "$MNT"
}

# CephFS via the upstream all-in-one demo container: a MON/MGR/OSD/MDS
# in one image, then the in-kernel client. Heavier than the others but
# still a single `docker run`.
setup_cephfs() {
    command -v docker >/dev/null || give_up "no docker" || return 1
    apt_install ceph-common ceph-fuse || give_up "ceph-common not installable" || return 1
    sudo docker run -d --name eu-ceph --net=host \
        -e MON_IP=127.0.0.1 -e CEPH_PUBLIC_NETWORK=127.0.0.1/32 \
        -e CEPH_DEMO_UID=eu -e DEMO_DAEMONS="mon,mgr,osd,mds" \
        -v /etc/ceph:/etc/ceph -v /var/lib/ceph:/var/lib/ceph \
        quay.io/ceph/demo || give_up "ceph demo container did not start" || return 1
    defer "sudo docker rm -f eu-ceph; sudo rm -rf /etc/ceph/* /var/lib/ceph/*"
    local i
    for i in $(seq 1 48); do
        [ -f /etc/ceph/ceph.conf ] && sudo ceph -s >/dev/null 2>&1 && break
        sleep 5
        # 4 minutes. Longer than this and the answer is "not on a runner",
        # which is a verdict -- not a reason to hold the whole run open
        # until the job timeout fires.
        [ "$i" = 48 ] && { sudo docker logs --tail 30 eu-ceph 2>&1 || true
                           give_up "ceph cluster never became responsive in 4min"; return 1; }
    done
    sudo ceph -s || true
    sudo ceph-fuse "$MNT" || give_up "ceph-fuse mount failed" || return 1
    defer "sudo umount -l $MNT"
    sudo chown "$(id -u):$(id -g)" "$MNT" || true
}

# SMB against a local Samba, i.e. what a user with a NAS or a Windows
# share actually has. Mounted with kernel defaults: no `nobrl`, no
# `noserverino` -- those are exactly the workarounds we would want a red
# cell to motivate.
setup_cifs() {
    apt_install samba cifs-utils || give_up "samba not installable" || return 1
    local share="$PROBE_DIR/share"
    sudo mkdir -p "$share"
    sudo chmod 777 "$share"
    sudo tee -a /etc/samba/smb.conf >/dev/null <<EOF

[euprobe]
   path = $share
   browseable = yes
   read only = no
   guest ok = no
   force user = root
EOF
    printf 'eupass\neupass\n' | sudo smbpasswd -s -a root || give_up "smbpasswd failed" || return 1
    sudo systemctl restart smbd || give_up "smbd will not start" || return 1
    defer "sudo systemctl stop smbd || true"
    mount_and_own -t cifs "//127.0.0.1/euprobe" \
        -o "username=root,password=eupass,uid=$(id -u),gid=$(id -g),vers=3.1.1" "$MNT"
}

setup_sshfs() {
    apt_install sshfs openssh-server || give_up "sshfs not installable" || return 1
    sudo systemctl start ssh || sudo systemctl start sshd || give_up "no sshd" || return 1
    local key="$HOME/.ssh/eu_probe"
    mkdir -p "$HOME/.ssh"
    [ -f "$key" ] || ssh-keygen -t ed25519 -N '' -f "$key" -q
    cat "$key.pub" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    local backing="$PROBE_DIR/sshfs-backing"
    mkdir -p "$backing"
    sshfs -o "IdentityFile=$key,StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null" \
        "$(id -un)@127.0.0.1:$backing" "$MNT" || give_up "sshfs mount failed" || return 1
    defer "fusermount3 -u $MNT || fusermount -u $MNT || sudo umount -l $MNT"
}

setup_gocryptfs() {
    apt_install gocryptfs || give_up "gocryptfs not installable" || return 1
    local cipher="$PROBE_DIR/cipher" pw="$PROBE_DIR/pw"
    mkdir -p "$cipher"
    echo eupassphrase > "$pw"
    gocryptfs -init -passfile "$pw" -q "$cipher" || give_up "gocryptfs init failed" || return 1
    gocryptfs -passfile "$pw" -q "$cipher" "$MNT" || give_up "gocryptfs mount failed" || return 1
    defer "fusermount3 -u $MNT || fusermount -u $MNT || sudo umount -l $MNT"
}

setup_encfs() {
    apt_install encfs || give_up "encfs not installable" || return 1
    local cipher="$PROBE_DIR/encfs-cipher"
    mkdir -p "$cipher"
    echo eupassphrase | encfs --standard --stdinpass "$cipher" "$MNT" \
        || give_up "encfs mount failed" || return 1
    defer "fusermount3 -u $MNT || fusermount -u $MNT || sudo umount -l $MNT"
}

setup_ecryptfs() {
    apt_install ecryptfs-utils keyutils || give_up "ecryptfs-utils not installable" || return 1
    need_module ecryptfs || return 1
    local lower="$PROBE_DIR/ecryptfs-lower" sig
    sudo mkdir -p "$lower"
    local sigout
    sigout="$(printf 'eupassphrase' | sudo ecryptfs-add-passphrase --fnek 2>&1)"
    echo "I: ecryptfs-add-passphrase said: $sigout"
    sig="$(echo "$sigout" | sed -n 's/.*\[\([0-9a-f]\{16\}\)\].*/\1/p' | head -1)"
    [ -n "$sig" ] || { give_up "ecryptfs-add-passphrase produced no signature"; return 1; }
    mount_and_own -t ecryptfs "$lower" "$MNT" \
        -o "key=passphrase:passphrase_passwd=eupassphrase,ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_sig=$sig,ecryptfs_unlink_sigs,no_sig_cache=yes"
}

# S3 seen as a filesystem: MinIO in a container, rclone's FUSE mount on
# top. This is the "my data lives in object storage" shape, which git
# and git-annex hate for reasons worth measuring rather than assuming.
setup_s3_rclone() {
    command -v docker >/dev/null || give_up "no docker" || return 1
    apt_install rclone || give_up "rclone not installable" || return 1
    sudo docker run -d --name eu-minio -p 9000:9000 \
        -e MINIO_ROOT_USER=euprobe -e MINIO_ROOT_PASSWORD=euprobe123 \
        quay.io/minio/minio server /data || give_up "minio did not start" || return 1
    defer "sudo docker rm -f eu-minio"
    local i
    for i in $(seq 1 30); do
        curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 && break
        sleep 2
        [ "$i" = 30 ] && { give_up "minio never became healthy"; return 1; }
    done
    export RCLONE_CONFIG_EU_TYPE=s3 RCLONE_CONFIG_EU_PROVIDER=Minio \
        RCLONE_CONFIG_EU_ACCESS_KEY_ID=euprobe \
        RCLONE_CONFIG_EU_SECRET_ACCESS_KEY=euprobe123 \
        RCLONE_CONFIG_EU_ENDPOINT=http://127.0.0.1:9000
    rclone mkdir eu:euprobe || give_up "rclone mkdir failed" || return 1
    rclone mount --vfs-cache-mode full --daemon eu:euprobe "$MNT" \
        || give_up "rclone mount failed" || return 1
    defer "fusermount3 -u $MNT || fusermount -u $MNT || sudo umount -l $MNT"
    sleep 3
}

# Lustre has no single-node story on a stock runner: the client is an
# out-of-tree DKMS module and the server needs either a patched kernel
# (ldiskfs) or ZFS. This probe answers only the first half -- do the
# client modules build against the runner's kernel at all? -- because
# that is the gate everything else is behind.
setup_lustre_client() {
    local codename repo
    # shellcheck disable=SC1091  # /etc/os-release is provided by the OS
    codename="$(. /etc/os-release && echo "$VERSION_ID" | tr -d .)"
    repo="https://downloads.whamcloud.com/public/lustre/latest-release/ubuntu${codename}/client"
    echo "I: checking $repo"
    if ! curl -fsI "$repo/" >/dev/null 2>&1; then
        give_up "no Whamcloud client repo for ubuntu${codename} (kernel $(uname -r))"
        return 1
    fi
    echo "I: module packages published in that repo:"
    curl -fsS "$repo/Packages" 2>/dev/null \
        | sed -n 's/^Package: \(lustre-client-modules.*\)/  \1/p' | sort -u | head -20
    apt_install dkms "linux-headers-$(uname -r)" || return 1
    echo "deb [trusted=yes] $repo/ ./" | sudo tee /etc/apt/sources.list.d/lustre.list >/dev/null
    defer "sudo rm -f /etc/apt/sources.list.d/lustre.list"
    apt_install lustre-client-modules-dkms lustre-client-utils \
        || give_up "lustre client DKMS build failed on kernel $(uname -r)" || return 1
    sudo modprobe lustre || give_up "lustre module built but will not load" || return 1
    NOTE="client modules load; no server (needs patched kernel or ZFS OSD)"
    # There is no filesystem to mount: a client without a server is as
    # far as a single runner goes. Report what we learned and stop.
    return 2
}

# OpenAFS is the other out-of-tree client in this space, and unlike
# Lustre it is packaged by Debian/Ubuntu themselves, so the module is
# built by DKMS against whatever kernel the runner has.
setup_openafs() {
    apt_install dkms "linux-headers-$(uname -r)" openafs-modules-dkms openafs-client \
        || give_up "openafs DKMS build failed on kernel $(uname -r)" || return 1
    sudo modprobe openafs || give_up "openafs module built but will not load" || return 1
    NOTE="client module builds and loads; a cell (server) is a separate problem"
    return 2
}

# Filesystems that categorically need a VM (or another machine) rather
# than a runner: report what the runner offers a VM-based backend.
setup_vm_only() {
    echo "I: /dev/kvm: $(test -e /dev/kvm && echo present || echo absent)"
    echo "I: qemu-system-x86_64: $(command -v qemu-system-x86_64 || echo absent)"
    echo "I: nested virt would be needed for: 9p, virtiofs, Lustre server, GPFS"
    NOTE="informational only"
    return 2
}

# ---------------------------------------------------------------- driver

echo "=== probing candidate: $CANDIDATE"
# shellcheck disable=SC1091  # /etc/os-release is provided by the OS
echo "=== runner: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"

start=$(date +%s)
case "$CANDIDATE" in
    gfs2)          setup_gfs2 ;;
    ocfs2)         setup_ocfs2 ;;
    f2fs)          setup_f2fs ;;
    exfat)         setup_exfat ;;
    ntfs3)         setup_ntfs3 ;;
    udf)           setup_udf ;;
    nilfs2)        setup_nilfs2 ;;
    bcachefs)      setup_bcachefs ;;
    zfs)           setup_zfs ;;
    overlay)       setup_overlay ;;
    glusterfs)     setup_glusterfs ;;
    cephfs)        setup_cephfs ;;
    cifs)          setup_cifs ;;
    sshfs)         setup_sshfs ;;
    gocryptfs)     setup_gocryptfs ;;
    encfs)         setup_encfs ;;
    ecryptfs)      setup_ecryptfs ;;
    s3-rclone)     setup_s3_rclone ;;
    lustre-client) setup_lustre_client ;;
    openafs)       setup_openafs ;;
    vm-only)       setup_vm_only ;;
    *) echo "unknown candidate: $CANDIDATE" >&2; usage >&2; exit 2 ;;
esac
rc=$?
elapsed=$(( $(date +%s) - start ))

caps=""
case "$rc" in
    0)
        echo "=== mounted, collecting capabilities"
        findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS "$MNT" || true
        caps="$("$HERE/fs-capabilities.sh" "$MNT" 2>&1)"
        echo "$caps"
        verdict="BOOTSTRAPPED"
        ;;
    2)  verdict="PARTIAL" ;;
    *)  verdict="NOT BOOTSTRAPPABLE" ;;
esac

echo "=== $CANDIDATE: $verdict (${elapsed}s) ${NOTE:+-- $NOTE}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### \`$CANDIDATE\`: $verdict (${elapsed}s)"
        [ -n "$NOTE" ] && echo "$NOTE"
        if [ -n "$caps" ]; then
            echo
            echo '```'
            echo "$caps"
            echo '```'
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

# One machine-readable line, last, so `tail` of a CI log carries the
# entire finding without scrolling back through apt output.
echo "SUMMARY|$CANDIDATE|$verdict|${elapsed}s|${NOTE:--}|$(echo "$caps" \
    | grep -E '^[a-z0-9-]+=' | tr '\n' ' ')"

# PARTIAL is a finding, not a failure: the job stays green so the
# summary is what gets read, not the red X.
[ "$rc" = 1 ] && exit 1
exit 0
