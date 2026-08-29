# Which filesystem next?

This repo can run any suite under any filesystem it can mount. That
raises two separate questions, and they have different answers:

1. **Which filesystems have actually broken git-annex or DataLad for
   real users?** -- answered from bug trackers, below.
2. **Which of those can we stand up in CI?** -- answered by *measuring*
   it: `bin/ci/probe-backend.sh` tries to bring a candidate up on a stock
   GitHub-hosted runner and reports what it got.

A filesystem is worth a matrix row when both answers are yes. This file
records both columns so the next person does not redo either.

> Re-run the measurements any time: the **Probe candidate filesystems**
> workflow (`workflow_dispatch`, or push a change to
> `bin/ci/probe-backend.sh`). Its roll-up job prints the whole table.

## Part 1 -- what users actually hit

Sorted by how much evidence there is, not by how exotic the filesystem
is. The "breaks" column names the *mechanism*, because the mechanism is
what a test has to reproduce.

| Filesystem | What breaks | Evidence |
| --- | --- | --- |
| **NFS** | POSIX record locks unreliable or absent, so `git-annex` falls back to `annex.pidlock`; close-to-open consistency makes freshly-created files invisible for seconds; deleting an open file silly-renames to `.nfsXXXX` | [`waitToSetLock: resource exhausted (No locks available)`][nfs1], [infinite hang on `git status` with v10][nfs2], [`git annex drop` does not free space][nfs3], DataLad [xfails archive tests on NFS][nfs4] and [gives NFS runs 20x the time budget][nfs5] |
| **Lustre** | SQLite in WAL mode returns `disk I/O error`; POSIX locks missing, so pidlock again; and `link()` **succeeds over an existing name**, leaving two directory entries with one name -- which is what pidlock relies on being atomic | [drop blows on lustre: SQLite3 returned ErrorIO][lus1], [day 336: pid locks][lus2], [day 337: who needs POSIX][lus3] |
| **BeeGFS** | rename semantics; 35+ test failures on 7.4.6 | [35 failed tests on beegfs][bee1] -- the report this repo was built for |
| **CIFS / SMB** | SQLite locking fails against the server's ownership model (workaround: mount `nobrl`); `git annex init` cannot remove a named pipe with unix extensions on; case-insensitive | [git-annex on Samba share][smb1] |
| **vfat / exFAT / NTFS / WSL DrvFs** | no symlinks, no ownership, no exec bit -- git-annex switches to an adjusted branch, and that path has its own bugs | [WSL1: git-annex-add fails in DrvFs][crip1], [WSL adjusted branches: smudge fails, sqlite locking protocol][crip2], [crippled fs (pidlock) leads to SQLite3 error][crip3], [files unaccessible in views on a crippled filesystem][crip4], DataLad [#258][crip5], [#4777][crip6] |
| **Isilon (NFS server)** | `cp -a` preserving the server's xattrs breaks the suite; 357/984 tests failed | ["357 out of 984 tests failed"][iso1] |
| **GlusterFS** | SQLite WAL does not work on Gluster -- the same mechanism as Lustre, reported on the Gluster side | [Gluster-users: Locking and SQLite][glu1] |
| **GPFS / IBM Storage Scale** | inode budget exhaustion with many annexed files; transfer-lock errors reported on HPC | [DataLad #5589][gpf1], [handbook: HPC installation notes][gpf2]. *No first-party git-annex bug report found* -- the GPFS reports are user-forum-shaped, which is itself a finding: nobody has run the suite there. |
| **ZFS** | not a breakage: `cp --reflink` unsupported, and `copy_file_range` behaviour over NFS+ZFS is a known open design question | [use copy_file_range for get and copy][zfs1] |

[nfs1]: https://git-annex.branchable.com/projects/datalad/bugs-done/git_annex_info_fails_on_NFS__58___waitToSetLock__58___resource_exhausted___40__No_locks_available__41__/
[nfs2]: https://git-annex.branchable.com/bugs/infinite_hang_on_git_status_with_v10___38___nfs/
[nfs3]: https://github.com/datalad/datalad/issues/3929
[nfs4]: https://github.com/datalad/datalad/pull/6912
[nfs5]: https://github.com/datalad/datalad/pull/7749
[lus1]: https://git-annex.branchable.com/bugs/drop_blows_on_lustre__58___SQLite3_returned_ErrorIO/
[lus2]: https://git-annex.branchable.com/devblog/day_336__pid_locks/
[lus3]: https://git-annex.branchable.com/devblog/day_337__who_needs_POSIX/
[bee1]: https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/
[smb1]: https://git-annex.branchable.com/forum/git-annex_on_Samba_share/
[crip1]: https://git-annex.branchable.com/bugs/WSL1__58___git-annex-add_fails_in_DrvFs_filesystem/
[crip2]: https://git-annex.branchable.com/bugs/WSL_adjusted_braches__58___smudge_fails_with_sqlite_thread_crashed_-_locking_protocol/
[crip3]: https://git-annex.branchable.com/bugs/crippled_fs___40__pidlock__41___leads_to_git-annex__58___SQLite3_error/
[crip4]: https://git-annex.branchable.com/bugs/Files_unaccessible_in___40__some__63____41___views_on_a_crippled_filesystem/
[crip5]: https://github.com/datalad/datalad/issues/258
[crip6]: https://github.com/datalad/datalad/issues/4777
[iso1]: https://git-annex.branchable.com/projects/datalad/bugs-done/__34__357_out_of_984_tests_failed__34___on_NFS_lustre_mount/
[glu1]: https://lists.gluster.org/pipermail/gluster-users/2015-May/021927.html
[gpf1]: https://github.com/datalad/datalad/issues/5589
[gpf2]: https://handbook.datalad.org/en/inm7/intro/installation.html
[zfs1]: https://git-annex.branchable.com/todo/use_copy__95__file__95__range_for_get_and_copy/

### The pattern

Four mechanisms account for nearly every report above:

1. **SQLite cannot lock.** git-annex keeps its keys database in SQLite,
   in WAL mode, which needs shared memory plus byte-range locks. Lustre,
   CIFS, Gluster and WSL all fail this, and all produce the same
   `SQLite3 returned ErrorIO` / `ErrorBusy` symptom. Joey's fix was
   `annex.dbdir`, to move the database somewhere that works.
2. **POSIX record locks are missing or lying**, so git-annex falls back
   to `annex.pidlock`.
3. **`link()` does not refuse an existing name** -- Lustre. That breaks
   the pidlock fallback itself, which is why it is worth a check of its
   own rather than being lumped in with (2).
4. **No symlinks / no exec bit / no ownership** -- the crippled-filesystem
   path and adjusted branches.

`bin/ci/fs-capabilities.sh` checks exactly these, plus the usual
suspects, and takes about a second. That matters for the recommendation
below: **a capability profile is a cheap approximation of a full `git
annex test` run**, and it can be collected for filesystems we cannot
afford to run the whole suite on.

## Part 2 -- what can be bootstrapped, measured

Every row below was produced by `bin/ci/probe-backend.sh <candidate>` on
a GitHub-hosted runner, not from documentation. `BOOTSTRAPPED` means it
mounted and was probed; `PARTIAL` means the interesting half is out of
reach on a runner; failures carry their reason. Times are the whole
bring-up: package install, mkfs or server start, mount.

Run 5 of the probe workflow, ubuntu-24.04 unless noted, kernel
`6.17.0-1022-azure` (`6.8.0-1064-azure` on the 22.04 image).

| Candidate | Verdict | Time | What the capability probe found |
| --- | --- | --- | --- |
| `gfs2` | **BOOTSTRAPPED** | 28s (61s on 22.04) | Everything green: symlinks, fcntl locks, SQLite WAL, xattrs, `link()` correctly refusing an existing name |
| `ocfs2` | **BOOTSTRAPPED** | 39s (52s on 22.04) | Same -- a full POSIX profile |
| `cifs` | **BOOTSTRAPPED** | 26s | **`sqlite-wal=no`, `sqlite-delete-mode=no`**, `symlink=no`, `fifo=no`, `exec-bit=no`, `perm-bits=no`, `case-sensitive=no` |
| `exfat` | **BOOTSTRAPPED** | 25s | Crippled as expected: no symlinks, hardlinks, fifos, exec bit, xattrs; case-insensitive; **rejects `:*?` in names** |
| `s3-rclone` | **BOOTSTRAPPED** | 46s | Crippled in the same shape as exfat -- but SQLite works |
| `sshfs` | **BOOTSTRAPPED** | 10s | **`hardlink-same-inode=no`** (link() succeeds, the link is invisible), no fifos, no unix sockets, no xattrs, and **1-second timestamp granularity** (1 distinct mtime across 5 rapid creates, vs 5 everywhere else) |
| `glusterfs` | **BOOTSTRAPPED** | 18s | Full POSIX profile through the FUSE client, SQLite WAL included |
| `zfs` | **BOOTSTRAPPED** | 13s | Full POSIX profile |
| `f2fs` | **BOOTSTRAPPED** | 39s | Full POSIX profile |
| `ntfs3` | **BOOTSTRAPPED** | 22s | Full POSIX profile -- the in-kernel driver carries symlinks and mode bits, unlike vfat |
| `nilfs2` | **BOOTSTRAPPED** | 27s | Full profile except `xattr-user=no` |
| `udf` | **BOOTSTRAPPED** | 9s | Full profile except xattrs and **255-character names** |
| `bcachefs` | **BOOTSTRAPPED** | 33s | Full POSIX profile |
| `overlay` | **BOOTSTRAPPED** | 0s | Full POSIX profile |
| `gocryptfs` | **BOOTSTRAPPED** | 9s | Full POSIX profile |
| `encfs` | **BOOTSTRAPPED** | 9s | Full profile except **255-character names** -- encryption inflates the name past the underlying limit |
| `vm-only` | *informational* | 0s | `/dev/kvm` **present**; `qemu-system-x86_64` not installed but one `apt install` away |
| `ecryptfs` | **NOT BOOTSTRAPPABLE** | 14s | `mount -t ecryptfs` refused with the key options the probe passes |
| `openafs` | **NOT BOOTSTRAPPABLE** | 295s | `openafs-modules-dkms` fails to build against `6.17.0-1022-azure` |
| `cephfs` | **NOT BOOTSTRAPPABLE** | 382s | The all-in-one demo container starts, the cluster never becomes responsive |
| `lustre-client` | **NOT BOOTSTRAPPABLE** | 15s / 0s | 22.04: no `lustre-client-modules-dkms` in the ubuntu2204 repo. 24.04: no ubuntu2404 client repo at all |

Three of those measurements are worth pulling out, because they change
what the rows would be *for*:

- **CIFS is both crippled and SQLite-hostile.** It is the only candidate
  that fails `sqlite-wal` *and* `sqlite-delete-mode`, which is precisely
  the [Samba report][smb1] and the same mechanism as the Lustre one --
  reproduced locally, in 26 seconds, with no HPC site involved.
- **sshfs quantises timestamps to a second.** Everything else on this
  list resolves five rapid creates into five distinct mtimes; sshfs
  resolves them into one. That is the shape of bug that makes git's
  racy-timestamp handling matter, and no filesystem currently in the
  matrix exhibits it.
- **sshfs creates hardlinks that cannot be seen as hardlinks.** `ln`
  succeeds; both names then report distinct inodes and `nlink=1`,
  because SFTP has no way to say otherwise. This one was found the
  expensive way -- `hardlink=yes` called sshfs healthy, and it took a
  real `git annex test` run to discover that `add` on an adjusted
  unlocked branch fails on it. The probe now measures
  `hardlink-same-inode` and `hardlink-nlink` directly, which turns a
  20-minute suite run into a 10-second answer. See GOTCHAS.md.
- **`ntfs3` is not vfat.** The in-kernel NTFS driver reports symlinks,
  mode bits and xattrs, so it would *not* be a second crippled-filesystem
  row -- it would be a row testing a driver users reach through WSL and
  external drives, with POSIX mostly intact.

Also worth recording as a negative: **every single-node filesystem here
passes `link-eexist`**, the POSIX rule Lustre is reported to break. The
check is cheap and stays in the probe, but nothing reachable from a
runner reproduces that particular Lustre behaviour -- if we want it
tested, it has to be Lustre.

## Part 3 -- the two that were asked about

### "GFS" is three different filesystems

Worth disambiguating before deciding anything, because the three have
completely different answers:

| Reading | What it is | Can we test it? |
| --- | --- | --- |
| **GFS2** | Red Hat's cluster filesystem, in the mainline kernel | **Yes, trivially.** `mkfs.gfs2 -p lock_nolock -j 1` needs no cluster stack at all, the module ships in `linux-modules-extra`, and the whole thing is a loop device. Measured at well under a minute end to end. |
| **GlusterFS** | userspace scale-out filesystem, FUSE client | **Yes.** One brick, one replica-1 volume, `mount -t glusterfs` back over the loopback -- all from Ubuntu packages. |
| **GPFS / IBM Storage Scale** | IBM's proprietary parallel filesystem | **Not in public CI.** See below. |

Given the HPC context the question came from, GPFS is the likely
intended reading -- and it is the one we cannot do. But GFS2 is nearly
free and exercises *cluster-filesystem locking*, which is the property
that breaks git-annex on the parallel filesystems we cannot run. That
makes it a genuine, if partial, stand-in rather than a consolation prize.

**GPFS specifically.** IBM ships a [Storage Scale Developer
Edition](https://www.ibm.com/docs/en/storage-scale/5.1.7?topic=overview-spectrum-scale-product-editions)
free for non-production use, capped at 12 TiB. It is a real option for a
*self-hosted* runner or a lab VM: it is a normal cluster install plus a
portability-layer kernel module built against the running kernel. It is
not an option for this repo's public CI -- the download is behind an IBM
ID, the license does not permit redistribution, and there is no apt repo
to point a workflow at. If GPFS coverage matters, the realistic path is
a self-hosted runner inside an institution that already licenses it.

### Lustre

**The client is the wall, and it is a hard one.** Lustre's client is an
out-of-tree kernel module. Whamcloud publishes Ubuntu packages, but as
modules *prebuilt per kernel* -- their ubuntu2204 index lists names like
[`lustre-client-modules-5.15.0-39-generic`][lpkg] -- and GitHub's runners
do not run those kernels -- measured, the runner is on
`6.8.0-1064-azure` (ubuntu-22.04 image) or `6.17.0-1022-azure`
(ubuntu-24.04). Also measured: `latest-release/ubuntu2204/client` has no
`lustre-client-modules-dkms` to build from source against it, and there
is no `ubuntu2404` client repo published at all. So neither the prebuilt
route nor the DKMS route is open on a GitHub-hosted runner, and that is
before the server question.

**The server is a second wall.** Lustre's ldiskfs OSD needs a *patched*
kernel; only the ZFS OSD runs on an unpatched one. So even with a
working client, a single-node Lustre means a ZFS-backed MGS/MDT/OST --
which is a documented configuration ([ZFS OSD][zfsosd]), just not a small
one.

**What does work, and is the recommended path:** Lustre's own test suite
ships `lustre/tests/llmount.sh` with a `cfg/local.sh` that builds a
complete single-node filesystem on **loopback devices**, no extra
hardware and no second machine ([Testing a Lustre filesystem][ltest]).
That is precisely an `eval-under` backend -- but it has to run somewhere
with a kernel Lustre supports. Three ways to get one, in increasing
order of effort:

1. **A VM on the runner.** GitHub-hosted Linux runners *do* expose
   `/dev/kvm` -- the `vm-only` probe reports it present, and the kernel
   log shows `kvm_amd: Nested Virtualization enabled`. `qemu-system-x86_64`
   is not preinstalled but is one `apt install` away. A Rocky/AlmaLinux 8 or 9 guest with
   Whamcloud's repos, `llmount.sh` inside it, and the suite driven over
   SSH is entirely feasible. Cost: several minutes of boot and install
   per run, and a new `bin/eval-under-lustre` that is really "run this
   inside a VM". The generic half of that (a `vm` backend that any
   kernel-module filesystem could reuse -- Lustre today, GPFS on a
   self-hosted runner tomorrow) is the part worth building.
2. **Extend the existing Vagrant VM.** `Vagrantfile` already provisions
   a local box for BeeGFS work that CI cannot do. Adding a Lustre
   flavour there gets a reproducible local target immediately, with no
   CI cost, and is the cheapest way to find out what `git annex test`
   does on Lustre. Prior art: the Lustre wiki's [Vagrant HPC storage
   cluster][lvag] and [`dtrudg/vagrant-lustre-tutorial`][lvag2].
3. **A real filesystem.** Amazon FSx for Lustre, or a self-hosted runner
   at a site that already has Lustre. Highest fidelity, needs money or
   institutional access, and cannot be a required check on a public PR.

Recommendation: **(2) first** -- it costs a Vagrantfile stanza and
answers the actual question ("what breaks on Lustre?") for a human
sitting at a terminal. Promote to (1) only if the answer turns out to be
interesting enough to want a badge for.

[lpkg]: https://downloads.whamcloud.com/public/lustre/lustre-2.15.1/ubuntu2204/client/Packages
[zfsosd]: https://wiki.lustre.org/ZFS_OSD
[ltest]: https://wiki.whamcloud.com/display/PUB/Testing+a+Lustre+filesystem
[lvag]: https://wiki.lustre.org/Create_a_Virtual_HPC_Storage_Cluster_with_Vagrant
[lvag2]: https://github.com/dtrudg/vagrant-lustre-tutorial

## Part 4 -- recommendation

**Tier 1 -- add as matrix rows.** Documented breakage, and they come up
on a stock runner in under a minute.

- **`cifs`** (localhost Samba). The highest-value row on this list: it
  reproduces the SQLite failure mode *directly* -- the probe measured
  `sqlite-wal=no` and `sqlite-delete-mode=no` on it -- and SMB shares are
  something ordinary users have, not just HPC sites.
- **`loop --fs gfs2`** and **`loop --fs ocfs2`**. Cluster-filesystem
  locking, no cluster. Already implemented in `bin/eval-under-loop`.

**Tier 2 -- each adds an axis the matrix does not have yet.**

- **`sshfs`**, now the strongest candidate on this list: it is the only
  one measured that breaks a documented git-annex operation outright
  (`add` on an adjusted unlocked branch, via invisible hardlinks), *and*
  it is the only one with a one-second clock. Backend implemented --
  `bin/eval-under-sshfs`.
- **`loop --fs exfat`**, the crippled row that is *not* vfat: it also
  rejects `:`, `*` and `?` in filenames, which vfat-with-defaults does
  not surface, and it is what is on every USB drive.
- **`loop --fs ntfs3`**, which the probe shows is *not* a crippled
  filesystem -- symlinks, mode bits and xattrs all work. That makes it a
  test of the in-kernel NTFS driver users reach through WSL and external
  drives, not a second vfat.
- **`s3-rclone`**, object storage seen as a filesystem: crippled in the
  exfat shape but with SQLite working, which is a combination nothing
  else on the list produces.

**Tier 3 -- worth doing, not trivially.** `glusterfs` bootstraps in 18s
and shows a clean POSIX profile, so the interesting question there is
what `git annex test` does to it, not whether it runs -- but it needs
its own `bin/eval-under-glusterfs` rather than a loop flavour. `cephfs`
and Lustre both need more machine than a runner gives (see above).

**Not feasible on GitHub-hosted runners.** GPFS (license), Lustre and
OpenAFS (out-of-tree modules that do not build against the runners'
Azure kernels). All three are feasible in a VM or on a self-hosted
runner, which is the same conclusion arrived at three different ways.

### Promoting a candidate to a matrix row

For anything the `loop` backend already handles, it is a data edit in
`.github/matrix.yaml` plus a regeneration:

```yaml
# under `backends:`, next to the existing loop rows:
  - backend: loop
    version: gfs2
    label: Loop gfs2
  - backend: loop
    version: ocfs2
    label: Loop ocfs2
```

```bash
bin/ci/gen-readme-matrix.sh        # refreshes the README badge grid
```

That is deliberately *not* done in this change: each row is four more
cells, four more badges and four more weekly runs against the shared
runner pool, and that is a call for whoever owns the CI budget. The
backend work is done; the matrix stays as it is until someone says go.

A filesystem the loop backend cannot make (cifs, glusterfs, cephfs)
needs a `bin/eval-under-<name>` first. `bin/ci/probe-backend.sh` already
contains a working bring-up sequence for each of them -- the `setup_*`
function is the backend, minus the flag handling.

### The cheap target

`bin/ci/fs-capabilities.sh` is now a target in its own right,
`capabilities`, alongside `git-annex`, `git`, `stress-ng` and
`pjdfstest`. It runs in about a second and answers "what does this
filesystem support?" for any backend, including the ones where the full
suite is too slow to run often. Where `pjdfstest` says which syscall
violates POSIX, this says which of the git-annex-specific mechanisms is
present.

It is marked `on-demand: true` in `.github/matrix.yaml`, so it is
runnable but is not a matrix cell -- it adds no badges and no weekly
runs, and it is the default target of the reproduce workflow. Promoting
it to a scheduled column later is a one-line data edit: drop the flag.

## Part 5 -- what this does not cover

- **AFS.** No reports found either way, and the client half is now
  measured as unavailable here: `openafs-modules-dkms` does not build
  against the runner's `6.17.0-1022-azure` kernel. Same shape as Lustre,
  same answer -- it needs a VM with a kernel the module supports.
- **9p and virtiofs** -- the WSL2 and VM-shared-folder paths, and a real
  source of user reports. Both need a VM, so they land in the same
  bucket as Lustre.
- **NFS variants.** Still the biggest gap, and it is about *options*
  rather than filesystems: v3 vs v4.x, `actimeo=0`, `nolock`, `sync`.
  See GOTCHAS.md, "Not yet covered".
- **eCryptfs.** Probed; `mount -t ecryptfs` refuses the key options the
  probe passes, so the bring-up is a scripting problem rather than a
  proven impossibility. Worth one more look, since it is the filesystem
  behind Ubuntu's old encrypted-home feature and has a long history of
  filename-length surprises -- and `encfs`, which *does* come up, already
  shows that shape (`long-name-255=no`).
- **CephFS.** The demo container starts but the cluster never becomes
  responsive inside the probe's budget on a 4-core runner. Not proven
  impossible; proven not-cheap.
