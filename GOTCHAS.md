# Gotchas

A result from this matrix only means something relative to *how* the
filesystem was made and mounted. `vfat` mounted with `fmask=0177`
behaves differently from `vfat` mounted with kernel defaults; NFS
exported `root_squash` behaves differently from `no_root_squash`. So
this file records two things:

1. **[The settings](#backend-settings)** each backend actually uses, and
   what each one implies for the suites running on top.
2. **[The known issues](#known-issues)** and their root causes, so
   nobody re-investigates a failure that is already understood.

If you add a backend or change a mount option, update this file in the
same commit. A knob that is not written down here is a knob that will be
rediscovered the hard way.

## Backend settings

### Loop (`bin/eval-under-loop`)

A sparse backing image is `dd`'d, `mkfs.<fs>`'d, and loop-mounted.

| Knob | Value | Why |
| --- | --- | --- |
| `mkfs` options | none -- distro defaults -- **except** the filesystems below | Whatever a user gets from `mkfs.ext4 /dev/sdX`, deliberately. |
| `mkfs.gfs2` | `-O -p lock_nolock -j 1 -J 8` | `lock_nolock` is GFS2's single-node lock module: no dlm, no corosync, no pacemaker. One journal because one node mounts it; `-J 8` because the 128MB default journal does not fit in a test-sized image. |
| `mkfs.ocfs2` | `-F -M local -N 1 -b 4K -C 8K --fs-features=local -q` | `-M local` is OCFS2's equivalent: a local mount needs no o2cb cluster stack. |
| Image size | per target, `loop-size-mb` in `evals/matrix.yaml`, raised to a per-filesystem floor | `git annex test` needs room for many small objects; the other three do not. A *default* `mkfs.gfs2` wants a 128MB journal, which will not fit in a 100MB image; with this backend's `-J 8` it does fit -- measured -- but 100MB then leaves `git annex test` almost no room, so gfs2 and ocfs2 are floored at 256MB (btrfs at 120MB). The floor is applied unconditionally and logged: `run-under.sh` always passes a `--size` chosen for the target, and no caller knows every filesystem's journal overhead. |
| Mount (vfat, msdos, exfat, ntfs) | `-o uid=<invoker>,gid=<invoker>` | These filesystems store no ownership. Without `uid=`, everything belongs to root and an unprivileged wrapped command cannot write. |
| Mount (gfs2) | `-t gfs2 -o lockproto=lock_nolock`, then `chown` | Named again at mount time so an image labelled for a cluster still mounts single-node. |
| Mount (everything else) | plain `mount`, then `chown <invoker>` on the mountpoint | ext4/xfs/btrfs carry real ownership; setting it once on the root is enough. |

**Single-node cluster filesystems are a deliberate approximation.** The
two vendors say different things about it, and neither says quite what an
earlier revision of this file claimed ("development-and-test-only"): Red
Hat does not support GFS2 as a single-node filesystem *at all*, outside
backup / secondary-site DR and existing single-node customers, and points
at a local filesystem instead; Oracle documents a local OCFS2 mount as a
supported configuration you can later migrate into a cluster, not as a
test-only mode. Either way, neither mode exercises the distributed lock
manager -- which is exactly the part a real GFS2 or OCFS2 deployment
would stress. What the row *does* buy is a cluster filesystem's on-disk
and VFS behaviour under git-annex, at loop-device cost. Read a green
cell as "nothing here is broken by the filesystem itself", not as "GFS2
is fine in a cluster".

**The vfat consequence worth knowing.** `fmask`, `dmask` and `umask` are
left at kernel defaults, so every file on the mount reads as mode `0755`
and every directory as `0755`. `chmod` cannot change that -- vfat has one
`read-only` bit and nothing else. Two things follow:

- Every file on a vfat mount is *executable* as far as `test -x` is
  concerned. This is not a detail; it is the direct cause of most of the
  `Loop vfat / git testsuite` failures (see below).
- Mounting instead with `fmask=0177,dmask=0077`, or with `showexec` (which
  restricts the execute bit to `.com`/`.exe`/`.bat`), would make several of
  those failures disappear. We do **not** do that: the point of the vfat
  row is to show what a default-mounted vfat does to a POSIX-assuming
  tool. Changing the mask would be measuring a different filesystem.

### NFS (`bin/eval-under-nfs`)

A local directory is exported to `localhost` and re-mounted over NFS.

| Knob | Value | Why |
| --- | --- | --- |
| Export | `exportfs -o rw,async localhost:<dir>` | `--sync` switches to `rw,sync`. |
| Mount | `mount -t nfs -o rw,async localhost:<dir>` | |
| Protocol version | whatever the kernel negotiates (4.2 on ubuntu-22.04 runners) | **Not pinned** -- see [Not yet covered](#not-yet-covered). |
| Squashing | `root_squash` (the kernel default), *except* for targets that opt out | |

**Export options and mount options are different namespaces.** `sync` and
`async` are valid in both; `no_root_squash` is export-only and `mount(8)`
rejects it outright. The script builds the two option strings separately
for exactly this reason -- if you add an option, work out which side it
belongs on first.

**`root_squash` is the default on purpose.** A normal user's NFS home is
squashed, and reproducing that is half the reason the NFS backend exists.
But two targets cannot measure anything under it:

- **pjdfstest** is largely a set of privileged-vs-unprivileged assertions
  and refuses to run as non-root at all.
- **stress-ng**'s `chown` and `mknod` stressors need `CAP_CHOWN` /
  `CAP_MKNOD`.

So `--no-root-squash` (env: `EVAL_UNDER_NFS_NO_ROOT_SQUASH`) exports with
`no_root_squash` *and* keeps the wrapped command running as root.
`target_needs_root()` in `bin/ci/matrix.sh` decides which targets get it;
`git` and `git-annex` deliberately do not, and run squashed like a real
user would. The loop and BeeGFS backends already run the wrapped command
as root, so the flag is a no-op there.

### BeeGFS (`bin/eval-under-beegfs`)

A containerised cluster (`fixtures/beegfs/docker-compose-v{7,8}.yml`) plus
a kernel module built against the runner's kernel.

| Knob | Value | Why |
| --- | --- | --- |
| Mount | `mount -t beegfs beegfs_nodev <mnt> -o cfgFile=<conf>` | |
| Client conf | `fixtures/beegfs/beegfs-client.conf.template` | Auth disabled, all daemons on `127.0.0.1`, non-default ports (8004-8008) so nothing collides with the runner. |
| `sysMountSanityCheckMS` | `0` **on v8 only** | BeeGFS v8 dropped the standalone `beegfs-helperd` binary; with no helperd the sanity check cannot complete and the mount would hang. v7 keeps the check. |

## Known issues

Every failure already understood -- or at least acknowledged -- is an
entry in `evals/known-issues.yaml`; what that means for CI is in
[README.md](README.md#known-issues).

<!-- BEGIN KNOWN ISSUES (generated by bin/ci/known_issues.py gotchas) -->

| Tag | Meaning |
| --- | --- |
| `fs-limitation` | The filesystem lacks the feature by design (vfat has no symlinks); will not change. |
| `fs-divergence` | The filesystem performs the operation, but not the way POSIX or a local filesystem does. |
| `test-assumption` | The test suite assumes something the filesystem need not provide. |
| `harness` | eval-under's own setup (image sizes, mount options, ...), not the filesystem. |
| `needs-triage` | Acknowledged, root cause not yet run down. |

<a id="vfat-not-posix"></a>
### `vfat-not-posix`: vfat is not a POSIX filesystem (pjdfstest)

**Cells:** `loop-vfat-pjdfstest` \
**Tags:** `fs-limitation` \
**Tests:** all (whole cell, not yet narrowed down)

About half of pjdfstest's files fail, and the run ends in a bail-out
rather than a summary.

See: [Loop vfat is not a POSIX filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-utime"></a>
### `vfat-utime`: stress-ng utime verification fails on vfat

**Cells:** `loop-vfat-stress-ng` \
**Tags:** `fs-limitation`, `needs-triage` \
**Tests:** `utime`

Presumably vfat's 2-second mtime granularity (and lack of atime)
tripping `--verify`.

See: [Loop vfat is not a POSIX filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-git-posixperm"></a>
### `vfat-git-posixperm`: git sets POSIXPERM from uname, never probes the work tree

**Cells:** `loop-vfat-git` \
**Tags:** `test-assumption` \
**Tests:** `t0001-init.sh#1-5,8,10-13,20-21,28`, `t1301-shared-repo.sh#2-3,5-22`

See: [Loop vfat / git testsuite: POSIXPERM](#loop-vfat--git-testsuite-posixperm)

<a id="vfat-git-no-unix-sockets"></a>
### `vfat-git-no-unix-sockets`: git's IPC and credential-cache tests need Unix sockets on the work tree

**Cells:** `loop-vfat-git` \
**Tags:** `fs-limitation`, `needs-triage` \
**Tests:** `t0052-simple-ipc.sh#1-9`, `t0301-credential-cache.sh#2-3,7-8,10-11,13-23,25-26,28,30,32-33,37-38,40-41,43-50,52`

Both create a Unix-domain socket under the trash directory, which
vfat cannot hold.

See: [Loop vfat is not a POSIX filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-git-untriaged"></a>
### `vfat-git-untriaged`: remaining git testsuite failures on vfat

**Cells:** `loop-vfat-git` \
**Tags:** `needs-triage` \
**Tests:** `t0003-attributes.sh#48,54`, `t0008-ignores.sh#391-392`, `t0024-crlf-archive.sh#2`, `t0033-safe-directory.sh#16`, `t0061-run-command.sh#8-9`, `t0600-reffiles-backend.sh#31`, `t0610-reftable-basics.sh#8-25`, `t1060-object-corruption.sh#12`, `t1091-sparse-checkout-builtin.sh#49`, `t1300-config.sh#201,209-210,458,466-467`, `t1700-split-index.sh#23-24,26`

See: [Loop vfat is not a POSIX filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="nfs-chown-setid"></a>
### `nfs-chown-setid`: NFS does not clear setuid/setgid on chown the way pjdfstest expects

**Cells:** `nfs-pjdfstest` \
**Tags:** `fs-divergence` \
**Tests:** `chown/00.t#107-108,118-120,129-130,137-138,148-150,159-160,167-168,178-180,189-190,197-198,208-210,219-220,227-228,238-240,249-250,257-258,268-270,279-280,287-288,598-599,601,613-615,617-618,634-635,637,649,652,664,668-669,685,688,700-701,703,715-717,719-720,736-737,739,751-752,754,766-768,770-771,787-788,790,802-803,805,817-819,821-822,838-839,841,853-854,856,868-870,872-873,889-890,892`

106 of chown/00.t's 1280 assertions.

See: [NFS (`bin/eval-under-nfs`)](#nfs-bineval-under-nfs)

<a id="nfs-pjdfstest-untriaged"></a>
### `nfs-pjdfstest-untriaged`: remaining pjdfstest failures on NFS

**Cells:** `nfs-pjdfstest` \
**Tags:** `fs-divergence`, `needs-triage` \
**Tests:** `chmod/00.t#117`, `unlink/14.t#4`

See: [NFS (`bin/eval-under-nfs`)](#nfs-bineval-under-nfs)

<a id="beegfs-pjdfstest"></a>
### `beegfs-pjdfstest`: BeeGFS POSIX conformance gaps (link, mknod, rename, utimensat)

**Cells:** `beegfs-7.4.6-pjdfstest`, `beegfs-8.1.0-pjdfstest` \
**Tags:** `fs-divergence`, `needs-triage` \
**Tests:** `link/00.t#135-136,142-143,149-150,156-157,163-164`, `mknod/11.t#4,17`, `rename/09.t#2259-2261,2264,2279-2281,2284,2299-2301,2304,2311-2313,2316,2323-2325,2328`, `rename/10.t#2049-2051,2054,2056-2058,2061,2063-2065,2068,2070-2072,2075,2077-2079,2082`, `rename/24.t#4,9`, `utimensat/02.t#5,7`, `utimensat/08.t#5-6`

Identical assertions fail on 7.4.6 and 8.1.0.

See: [BeeGFS (`bin/eval-under-beegfs`)](#beegfs-bineval-under-beegfs)

<a id="loop-annex-diskreserve"></a>
### `loop-annex-diskreserve`: git-annex test on a loop image no larger than annex.diskreserve

**Cells:** `loop-vfat-git-annex`, `loop-ext4-git-annex` \
**Tags:** `harness`, `needs-triage` \
**Tests:** all (whole cell, not yet narrowed down)

See: [Loop git-annex cells: annex.diskreserve](#loop-git-annex-cells-annexdiskreserve)

<!-- END KNOWN ISSUES -->

## Root-cause notes

The longer write-ups the issues above link to.

### Loop vfat is not a POSIX filesystem

vfat is not a POSIX filesystem. No symlinks, no ownership, no
permissions, no hardlinks, 2-second timestamp granularity,
case-insensitive names, and a restricted filename charset (`:` `?` `*`
`"` `<` `>` `|` are all illegal, and git's own test suite creates
filenames using several of them). Every target trips over some subset.
The row exists to show *which* subset, per layer.

### Loop vfat / git testsuite: POSIXPERM

Worth spelling out, because the obvious reaction is "surely git's own
suite handles this?"

Git *does* probe the filesystem for some of its prerequisites --
`SYMLINKS` is `ln -s x y && test -h y`, `CASE_INSENSITIVE_FS` writes
`CamelCase` and reads back `camelcase`, `FILEMODE` consults
`core.filemode`, which git auto-detects. Those all come out correct on
vfat, and the tests gated on them skip cleanly.

`POSIXPERM` is not one of them. In `t/test-lib.sh` it is set from
`uname -s`:

```sh
case $uname_s in
Darwin)   test_set_prereq POSIXPERM ;;
*MINGW*)  # no POSIX permissions
          ;;
*CYGWIN*) test_set_prereq POSIXPERM ;;
*)        test_set_prereq POSIXPERM ;;   # <-- Linux lands here, always
esac
```

On Linux `POSIXPERM` is unconditionally true, whatever the work tree is
sitting on. So on vfat git runs every permission-dependent assertion
against a filesystem that reports mode `0755` for everything.

The clearest instance is `t0001-init.sh`, whose `check_config()` helper
contains:

```sh
if test_have_prereq POSIXPERM && test -x "$1/config"
then
	echo "$1/config is executable?"
	return 1
fi
```

On vfat `.git/config` *is* executable, so `check_config` fails. It has 13
call sites in `t0001-init.sh`, and the vfat cell reports exactly 13
failures in that script. `t1301-shared-repo.sh` gates its
`core.sharedRepository` permission-bit checks on the same prerequisite;
both make up issue `vfat-git-posixperm`.

**This is not a git bug and not a regression.** Nobody upstream runs
git's test suite on a vfat work tree, so an OS-derived `POSIXPERM` has
never cost them anything. It is a fair finding about the *test suite's*
portability assumptions rather than about git the program -- which is
precisely the kind of thing a backends × targets grid is for.

### Loop git-annex cells: annex.diskreserve

git-annex will not store or fetch content if that would leave less than
`annex.diskreserve` free -- 100 MB by default. The git-annex cells' loop
image is also 100 MB (`loop-size-mb` in `evals/matrix.yaml`), so from
the first transfer onward git-annex declines with

```
not enough free space, need 26.44 MB more (use --force to override this check or adjust annex.diskreserve)
```

and tests that move content fail: the whole `Remote Tests` tree
(storeKey, retrieveKeyFile, fsck downloaded object, ...) and, in the
ext4 control row, a broad sweep of `Repo Tests v10 locked`. That makes
it the prime suspect for the ext4 control row's failure -- a property
of our harness, not of ext4 or vfat -- but it is not proven: only ~61
of the ~466 ext4 failure messages mention free space directly.

Until the image is enlarged or the reserve lowered for the test run,
`loop-annex-diskreserve` covers both loop rows whole-cell, so the ext4
control row cannot catch a git-annex regression.

### BeeGFS / git-annex test

The original motivating bug: 8 of the 9 (repo mode x test) combinations
of `export and import`, `export and import of subdir` and
`git-remote-annex exporttree` failed on both BeeGFS versions, with

    git-annex: renamePath:rename '.git/annex/othertmp/...' to '.git/annex/export.ex/...': resource busy (Device or resource busy)

(plus the same EBUSY from `mv`), and on 8.1.0 the suite could also hang
in `Repo Tests v10 unlocked` at `conflict resolution (removed file)`
until the 2400s timeout.

**Resolved by building git-annex with OsPath**, as the upstream report
<https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/>
said. Our con/git-annex standalone had silently been built without it:
the flag is on by default but automatic, and its `file-io >= 0.2.0`
dependency was missing from the build image (con/git-annex#295 adds it;
con/git-annex#296 makes that CI require the flag). With the first OsPath
build (con/git-annex run 36399800528, `10.20260901+git71`), both
`BeeGFS * / git-annex test` cells pass all 26 test groups -- `pass 838
fail 0`, no EBUSY, no hang -- where the same 2026-09-28 matrix on the
non-OsPath git42/git47 builds failed exactly those tests (eval-under runs
36417303910 vs 36475373813). git47..git71 upstream touches nothing in
the export or rename paths, so the build flag is the difference.

So the known issue is gone, and a return of those failures is a real
regression. `bin/ci/install-git-annex-daily.sh` refuses a build lacking
`OsPath` (`EXPECT_BUILD_FLAGS`), so these cells cannot quietly go back
to measuring a build without it.

Two things still worth knowing:

- `BeeGFS * / git testsuite` passes on both versions too: BeeGFS does
  not break git's index, refs or object plumbing.
- On 7.4.6 one run stalled ~9.5 minutes across several concurrent tests
  (`storeKey`, `sync`, `add`, ... each ~560-600s) and then passed; the
  suite took 22m instead of ~6m. Not a failure, but it eats into the
  2400s budget if it recurs.

## Red that is not a finding

Distinct from the cells above: these are harness races, and the fix is in
this repo rather than in anything under test.

### BeeGFS: `chown: cannot access '<mount>': Communication error on send`

`mount -t beegfs` returns as soon as the client module has registered
with mgmtd and downloaded the node groups. That is not the same as its
connections to the meta and storage nodes being usable: the kernel logs
`BeeGFS mount ready` and the very next metadata operation can still fail
with `ECOMM`. `start_cluster()` waiting for the three daemons to bind
does not help -- a listening port only proves the *server* side is up.

It presents as a cell that was green last run and red this one, with a
single-line error and no suite output at all, which reads like a finding
about the filesystem and is not.

`wait_for_mount_usable()` in `bin/eval-under-beegfs` now probes a fresh
mount with a real create + write + read-back (meta node for the create, a
storage target for the write) and only proceeds once that succeeds, up to
`--mount-ready-wait` / `EVAL_UNDER_BEEGFS_MOUNT_READY_WAIT` seconds. If
it ever does time out, the error carries the last probe failure and a
`dmesg | grep beegfs` tail, so the next occurrence is diagnosable from
the job log alone.

## Reading a red cell

1. Look at the job's step summary (written by "Check against known
   issues"): how many failures each known issue covered, and any new
   failure no issue covers, by test id.
2. Then the suite's own summary block in the log: `prove`'s `Test
   Summary Report` for `git` and `pjdfstest`, the pass/skip/fail tally
   for `stress-ng`, tasty's `N out of M tests failed` for `git-annex`.
3. Then the `=== ... failures ===` dump printed by
   `bin/ci/dump-failure-logs.sh`, which names the failing assertions and
   their output.
4. Then the uploaded `logs-<cell>` artifact (e.g. `logs-nfs-git`), which
   has every test's outcome in `results.tsv` besides the full logs.

An `incomplete` cell ([README](README.md#known-issues)) never counts as
known. Check the mount actually came up, then whether the suite's output
format changed under the parser.

## Not yet covered

- **NFS variants.** One localhost export with kernel-negotiated defaults
  is a thin proxy for "NFS". The settings that actually bite on HPC are
  protocol version (v3 vs v4.x), attribute caching (`ac` vs `noac` /
  `actimeo=0`), locking (`lock` vs `nolock`, and whether `rpc.statd` is
  even up), `sync` vs `async` on the export, and squashing. Each is a
  plausible row of its own.
- **A `Loop vfat` mask variant**, if we ever want to separate "vfat is
  not POSIX" from "vfat mounted with defaults is not POSIX".
