# 9p backends: design record

Status: **implemented** (both backends, CI rows `9p-tcp / n/a` and
`9p-virtio / mapped`). This file is the decision record from the design
review; the operational truth lives where it belongs -- settings and
semantics in [GOTCHAS.md](../GOTCHAS.md), knobs in each script's
`--help`, deferred rows in GOTCHAS "Not yet covered". Delete this file
once those deferred rows have either landed or been rejected.

## Why 9p

9p is the filesystem people get, usually without choosing it, when a
directory is shared across a VM boundary: Vagrant + QEMU/libvirt
`type: "9p"` synced folders (QEMU's virtfs server + the kernel v9fs
client over virtio), WSL2's `/mnt/c` (Microsoft's 9p server), Chrome OS
crostini, pre-virtiofs kata. Its quirk classes -- cache staleness,
server-faked or whole-file locking, absorbed chown/mknod under mapped
security models, msize cliffs, no `O_TMPFILE`, no remote change
notification -- are disjoint from every existing row, and our own
Vagrantfile dodges them ("rsync ... avoids permission surprises")
rather than measuring them.

## The two mechanisms, and why both exist

- **`bin/eval-under-9p-tcp`** -- diod (9P2000.L) on localhost TCP,
  kernel client mount on the same host. Architecturally the NFS
  backend's sibling; no VM, no KVM, server runs unprivileged. The
  everyday local-debugging 9p, and the cheap CI row.
- **`bin/eval-under-9p-virtio`** -- QEMU `-virtfs local,...` into a
  virtme-ng guest booted from the host's own rootfs, suite runs inside
  the guest. The only way to exercise the *actual* server vagrant users
  hit; virtme-ng is what makes it fit the harness (host-installed
  targets exist in the guest unchanged, exit status and stdio are
  plumbed out over virtio-serial).

Two scripts rather than one `--transport` flag: they share the string
"9p" and the env-trio contract and nothing else -- different daemon vs
hypervisor, privilege model, teardown, diagnostics (host dmesg vs a
guest that no longer exists). One mechanism per script is the house
pattern (loop parametrizes filesystems, beegfs parametrizes versions;
neither multiplexes mechanisms).

## Decisions of record

Two independent design reviews (one systems-mechanics, one
harness-fit) converged on the shape that got implemented. The calls,
and what settled them:

1. **Both transports landed together, tcp as the low-risk row.** The
   interesting client semantics are identical across both (same v9fs);
   the servers differ instructively (diod: whole-file `flock`; QEMU:
   TLOCK-always-succeeds). The virtio row carries the CI unknowns, so
   the tcp row guarantees the matrix gains a working 9p row even if
   virtio needs iteration.
2. **Backends never read `.github/matrix.yaml`.** That line is what
   keeps `bin/eval-under-*` first-class local tools. The pinned guest
   kernel (`refs: 9p-kernel`, mainline build fetched by `vng --run`)
   is handed to the backend *by `bin/ci/run-under.sh`*, exactly like
   `--size` and `--no-root-squash`; the script's own default is the
   host kernel -- zero downloads, works offline.
3. **Guest kernel pinned in CI, host kernel locally.** The v9fs client
   *is* the kernel and moved substantially in 6.4 (cache-mode rework)
   and 6.8 (netfs buffered writes); unpinned, a newly-red cell cannot
   distinguish filesystem regression from client drift. This is a
   deliberate departure from the "distro defaults, not pinned"
   environment philosophy (NFS protocol version is deliberately
   unpinned) -- argued, not smuggled: for 9p the client is the thing
   under test's other half.
4. **`--disable-microvm`.** vng's microvm machine has no PCI bus the
   stock Ubuntu/mainline guest kernels can enumerate, and `-virtfs` is
   virtio-9p-pci -- on the exact recommended path (24.04 + KVM +
   virtiofsd) the mount tag would silently never appear.
5. **Root only where root is needed.** tcp: diod runs unprivileged in
   single-user mode, sudo is for mount/umount; virtio: nothing on the
   host needs root at all (mounting happens inside the guest, QEMU and
   vng run unprivileged). Guest scripts run as root, so the wrapped
   command is *dropped* to the invoking user via `runuser` -- vng's
   default would otherwise measure root-in-a-VM. `--run-as-root` (both
   scripts) is the 9p analog of NFS `--no-root-squash`, wired to
   `target_needs_root()` in run-under.sh; without it the pjdfstest
   cell would be a contentless setup-failure red.
6. **Guest mountpoint defaults to `/tmp/eval-under-9p`.** vng's rootfs
   is read-only outside its overlay set; `/mnt` would EROFS. Overlay
   writes evaporate with the guest, and vng's `--rwdir` shares turned
   out not to be uid-faithful (measured; see GOTCHAS) -- so git's
   `t/test-results/**` reaches the runner via the backend's
   `--copy-out`, which ferries guest paths back through the 9p export
   itself with ownership normalized.
7. **Host-side `--vm-timeout` around the whole guest.** The per-target
   `timeout` that run-under.sh wraps around the suite travels *into*
   the guest and cannot catch a boot or mount hang; CI passes
   target-timeout + 300s.
8. **Diagnostics survive the guest.** All guest output is teed to
   `/var/log/eval-under-9p-virtio.log` (in the artifact list), stage2
   appends the guest dmesg tail on failure, and the backend
   disambiguates vng's exit sentinels (124 = VM killed by
   `--vm-timeout`; 255 = crash-or-genuine-255). The backing dir is
   teardown-deleted before `dump-failure-logs.sh` runs, so nothing
   diagnostic may live only there.
9. **Per-row `runs-on` in matrix.yaml** (default ubuntu-22.04; 9p rows
   ubuntu-24.04, where virtme-ng/virtiofsd are packaged). Costed
   knowingly: the backend tuple grew a fourth field across matrix.sh /
   matrix-json.sh / gen-readme-matrix.sh, and rows on different images
   differ in host kernel and tool versions -- acceptable here because
   the virtio row's client kernel is pinned anyway, recorded so the
   next person prices it too.
10. **No separate probe workflow.** The durable assertions live in
    `install-backend.sh` (modprobe + /proc/filesystems for tcp; udev
    KVM rule, `vng --version`, and a pre-warm boot of the pinned
    kernel for virtio -- which doubles as the boot smoke and moves the
    ~180 MB mainline download outside the suite's timeout). The PR's
    own matrix run is the integration probe.

## Facts the reviews settled (so nobody re-derives them)

- 9p client modules (`9p`, `9pnet`, `9pnet_fd`, `9pnet_virtio`) ship in
  the kernel's **base `linux-modules`** package on Ubuntu generic,
  virtual and azure flavours alike -- `linux-modules-extra` is NOT
  needed anywhere in this design. (`9pnet_tcp` does not exist;
  `trans=tcp` lives in `9pnet_fd`.)
- Standard GitHub-hosted Linux runners have KVM (officially since
  2024); the udev rule in `install_9p_virtio()` is the documented
  enablement for non-root use.
- `vng --run` wants a tag-shaped version (`v6.8`), downloads the Ubuntu
  mainline image+modules (~180 MB, cached in `~/.cache/virtme-ng`),
  and those builds carry the 9p modules; vng propagates the guest
  command's exit code over a dedicated channel, with 255 as its
  crash sentinel.
- vagrant-libvirt's *default* accessmode is `passthrough` under an
  unprivileged QEMU -- neither of the first two virtio rows; recorded
  with a local repro recipe in GOTCHAS "Not yet covered".
- diod caps msize at 64 KiB and implements Tlock as whole-file
  `flock()`; QEMU's virtfs answers every TLOCK with success. Same
  client, two instructively different servers.

## Deferred (tracked in GOTCHAS "Not yet covered")

`9p-virtio / passthrough` (root QEMU) and the true vagrant default
(passthrough, unprivileged QEMU); `cache=loose` and small-msize
variants; an `eval-under-virtiofs` sibling backend as the "is this 9p
or any VM-shared fs?" control row. All are flag-reachable locally
today; each becomes one matrix line when promoted.
