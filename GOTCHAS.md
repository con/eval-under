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
| `mkfs` options | none -- distro defaults | Whatever a user gets from `mkfs.ext4 /dev/sdX`, deliberately. |
| Image size | per target, `target_loop_size_mb()` in `bin/ci/matrix.sh` | `git annex test` needs room for many small objects; the other three do not. |
| Mount (vfat, msdos, exfat, ntfs) | `-o uid=<invoker>,gid=<invoker>` | These filesystems store no ownership. Without `uid=`, everything belongs to root and an unprivileged wrapped command cannot write. |
| Mount (everything else) | plain `mount`, then `chown <invoker>` on the mountpoint | ext4/xfs/btrfs carry real ownership; setting it once on the root is enough. |

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
entry in [`.github/known-issues.yaml`](.github/known-issues.yaml), which
names the cells and the individual tests it covers, tags its kind of
cause, and links to the evidence. That file drives the CI verdicts: a
cell whose failures are all covered keeps its job green (while its badge
still honestly reads "failing"), and a failure no issue covers turns the
job red. The list below is generated from it -- edit the YAML, not this
section.

<!-- BEGIN KNOWN ISSUES (generated by bin/ci/known_issues.py gotchas) -->

Generated from [`.github/known-issues.yaml`](.github/known-issues.yaml);
edit that file, then run `bin/ci/known_issues.py gotchas`.

| Tag | Meaning |
| --- | --- |
| `fs-limitation` | The filesystem lacks the feature by design (vfat has no symlinks); will not change. |
| `fs-divergence` | The filesystem performs the operation, but not the way POSIX or a local filesystem does. |
| `tool-bug` | A bug in the tool under test. |
| `test-assumption` | The test suite assumes something the filesystem need not provide. |
| `build-config` | Our build of the tool (flags, dependencies), not the tool itself. |
| `harness` | eval-under's own setup (image sizes, mount options, ...), not the filesystem. |
| `fixed-upstream` | Fixed upstream; waiting for the fix to reach what we run. |
| `needs-triage` | Acknowledged, root cause not yet run down. |

<a id="vfat-not-posix"></a>
### `vfat-not-posix`: vfat is not a POSIX filesystem (pjdfstest)

**Cells:** `loop-vfat-pjdfstest` \
**Expect:** fail -- whole cell, not yet narrowed to named tests \
**Tags:** `fs-limitation`

About half of pjdfstest's files fail, and the run ends in a bail-out
rather than a summary. Worth narrowing only if we ever want to diff
vfat mount-option variants against each other.

See: [#loop-vfat-is-not-a-posix-filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-utime"></a>
### `vfat-utime`: stress-ng utime verification fails on vfat

**Cells:** `loop-vfat-stress-ng` \
**Expect:** fail \
**Tags:** `fs-limitation`, `needs-triage`

Tests: `utime`

Presumably vfat's 2-second mtime granularity (and lack of atime)
tripping `--verify`; not yet confirmed from the stressor's output.

See: [#loop-vfat-is-not-a-posix-filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-git-posixperm"></a>
### `vfat-git-posixperm`: git sets POSIXPERM from uname, never probes the work tree

**Cells:** `loop-vfat-git` \
**Expect:** fail \
**Tags:** `test-assumption`

Tests: `t0001-init.sh#1-5,8,10-13,20-21,28`, `t1301-shared-repo.sh#2-3,5-22`

vfat reports mode 0755 for everything, so every permission assertion
fails. t0001's 13 are exactly the 13 `check_config` call sites;
t1301 (core.sharedRepository) is permission checks throughout.

See: [#loop-vfat--git-testsuite-posixperm](#loop-vfat--git-testsuite-posixperm)

<a id="vfat-git-no-unix-sockets"></a>
### `vfat-git-no-unix-sockets`: git's IPC and credential-cache tests need Unix sockets on the work tree

**Cells:** `loop-vfat-git` \
**Expect:** fail \
**Tags:** `fs-limitation`, `needs-triage`

Tests: `t0052-simple-ipc.sh#1-9`, `t0301-credential-cache.sh#2-3,7-8,10-11,13-23,25-26,28,30,32-33,37-38,40-41,43-50,52`

Both create a Unix-domain socket under the trash directory, which
vfat cannot hold. Hypothesis from the test names; not yet confirmed
from the .out files.

See: [#loop-vfat-is-not-a-posix-filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="vfat-git-untriaged"></a>
### `vfat-git-untriaged`: remaining git testsuite failures on vfat

**Cells:** `loop-vfat-git` \
**Expect:** fail \
**Tags:** `needs-triage`

Tests: `t0003-attributes.sh#48,54`, `t0008-ignores.sh#391-392`, `t0024-crlf-archive.sh#2`, `t0033-safe-directory.sh#16`, `t0061-run-command.sh#8-9`, `t0600-reffiles-backend.sh#31`, `t0610-reftable-basics.sh#8-25`, `t1060-object-corruption.sh#12`, `t1091-sparse-checkout-builtin.sh#49`, `t1300-config.sh#201,209-210,458,466-467`, `t1700-split-index.sh#23-24,26`

Seeded from run 36050917994 (git v2.55.0). Split off into their own
issues as root causes are found.

See: [#loop-vfat-is-not-a-posix-filesystem](#loop-vfat-is-not-a-posix-filesystem)

<a id="nfs-chown-setid"></a>
### `nfs-chown-setid`: NFS does not clear setuid/setgid on chown the way pjdfstest expects

**Cells:** `nfs-pjdfstest` \
**Expect:** fail \
**Tags:** `fs-divergence`

Tests: `chown/00.t#107-108,118-120,129-130,137-138,148-150,159-160,167-168,178-180,189-190,197-198,208-210,219-220,227-228,238-240,249-250,257-258,268-270,279-280,287-288,598-599,601,613-615,617-618,634-635,637,649,652,664,668-669,685,688,700-701,703,715-717,719-720,736-737,739,751-752,754,766-768,770-771,787-788,790,802-803,805,817-819,821-822,838-839,841,853-854,856,868-870,872-873,889-890,892`

106 of chown/00.t's 1280 assertions. The cell runs `--no-root-squash`;
under the default `root_squash` pjdfstest refuses to start at all.

See: [#nfs-bineval-under-nfs](#nfs-bineval-under-nfs)

<a id="nfs-pjdfstest-untriaged"></a>
### `nfs-pjdfstest-untriaged`: remaining pjdfstest failures on NFS

**Cells:** `nfs-pjdfstest` \
**Expect:** fail \
**Tags:** `fs-divergence`, `needs-triage`

Tests: `chmod/00.t#117`, `unlink/14.t#4`

See: [#nfs-bineval-under-nfs](#nfs-bineval-under-nfs)

<a id="beegfs-pjdfstest"></a>
### `beegfs-pjdfstest`: BeeGFS POSIX conformance gaps (link, mknod, rename, utimensat)

**Cells:** `beegfs-7.4.6-pjdfstest`, `beegfs-8.1.0-pjdfstest` \
**Expect:** fail \
**Tags:** `fs-divergence`, `needs-triage`

Tests: `link/00.t#135-136,142-143,149-150,156-157,163-164`, `mknod/11.t#4,17`, `rename/09.t#2259-2261,2264,2279-2281,2284,2299-2301,2304,2311-2313,2316,2323-2325,2328`, `rename/10.t#2049-2051,2054,2056-2058,2061,2063-2065,2068,2070-2072,2075,2077-2079,2082`, `rename/24.t#4,9`, `utimensat/02.t#5,7`, `utimensat/08.t#5-6`

Identical assertions fail on 7.4.6 and 8.1.0. Seeded from run
36050917994; split by syscall once each is understood.

See: [#beegfs-bineval-under-beegfs](#beegfs-bineval-under-beegfs)

<a id="beegfs-annex-export-busy"></a>
### `beegfs-annex-export-busy`: git-annex export/import fails on BeeGFS with EBUSY on rename

**Cells:** `beegfs-7.4.6-git-annex`, `beegfs-8.1.0-git-annex` \
**Expect:** fail \
**Tags:** `build-config`, `fixed-upstream`

Tests: `Tests.Repo Tests v10 *.export and import`, `Tests.Repo Tests v10 *.export and import of subdir`, `Tests.Repo Tests v10 *.git-remote-annex exporttree`

The same 8 of the 9 (repo mode x test) combinations fail on both
BeeGFS versions (unlocked mode's `git-remote-annex exporttree`
passes), with `renamePath:rename ... resource busy` / `mv: cannot
move ... Device or resource busy`.
Working hypothesis, under investigation: our git-annex build lacks
OsPath support, which upstream's builds have -- i.e. a build
configuration issue already addressed upstream, not a BeeGFS one.
Add `fixed-in:` once the version is known.

See: <https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/>, [#beegfs--git-annex-test](#beegfs--git-annex-test)

<a id="loop-annex-diskreserve"></a>
### `loop-annex-diskreserve`: git-annex test on a 100 MB loop image runs into annex.diskreserve

**Cells:** `loop-vfat-git-annex`, `loop-ext4-git-annex` \
**Expect:** fail -- whole cell, not yet narrowed to named tests \
**Tags:** `harness`

git-annex refuses to store or fetch content when that would leave
less than `annex.diskreserve` (default 100 MB) free, and the git-annex
cells' loop image is 100 MB (`loop-size-mb` in matrix.yaml). Both loop
cells log well over a hundred "not enough free space" messages; the
ext4 control row fails for this reason, not an ext4 one. Whole-cell
until the image is enlarged (or diskreserve lowered for the test
run), which will also reveal what is genuinely vfat-specific.

See: [#loop-git-annex-cells-annexdiskreserve](#loop-git-annex-cells-annexdiskreserve)

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
failures in that script (issue `vfat-git-posixperm`).

**This is not a git bug and not a regression.** Nobody upstream runs
git's test suite on a vfat work tree, so an OS-derived `POSIXPERM` has
never cost them anything. It is a fair finding about the *test suite's*
portability assumptions rather than about git the program -- which is
precisely the kind of thing a backends × targets grid is for.

### Loop git-annex cells: annex.diskreserve

git-annex will not store or fetch content if that would leave less than
`annex.diskreserve` free -- 100 MB by default. The git-annex cells' loop
image is also 100 MB (`loop-size-mb` in `.github/matrix.yaml`), so from
the first transfer onward git-annex declines with

```
not enough free space, need 26.44 MB more (use --force to override this check or adjust annex.diskreserve)
```

and every test that moves content fails: the whole `Remote Tests` tree
(storeKey, retrieveKeyFile, fsck downloaded object, ...) and, in the
ext4 control row, a broad sweep of `Repo Tests v10 locked`. This is what
the "pre-existing" `Loop ext4 / git-annex test` failure was. It is a
property of our harness, not of ext4 or vfat -- hence tag `harness` on
`loop-annex-diskreserve`, which covers both loop rows whole-cell until
the image is enlarged or the reserve lowered for the test run.

### BeeGFS / git-annex test

The original motivating bug. As of run 36050917994 it is down to 8
tests on both versions -- the `export and import`, `export and import of
subdir` and `git-remote-annex exporttree` repo tests -- failing with
`resource busy` on rename (issue `beegfs-annex-export-busy`).

Note the useful negative result beside it: `BeeGFS * / git testsuite`
**passes** on both versions. Whatever BeeGFS does differently, it is not
breaking git's index, refs, or object plumbing -- so the cause sits in
what git-annex layers on top, in how our git-annex is built, or in the
syscalls the pjdfstest column is flagging.

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

1. Look at the job's **step summary** (the "Check against known issues"
   step writes it): how many failures there were, how many each known
   issue covered, and -- the part that matters -- any **new** failure no
   issue covers, by test id. Annotations on the run flag known issues
   that did not reproduce (fixed?) or matched nothing (stale pattern?).
2. Then the suite's own summary block in the log: `prove`'s `Test
   Summary Report` for `git` and `pjdfstest`, the pass/skip/fail tally
   for `stress-ng`, tasty's `N out of M tests failed` for `git-annex`.
3. Then the `=== ... failures ===` dump printed by
   `bin/ci/dump-failure-logs.sh`, which names the failing assertions and
   their output.
4. Then the uploaded `logs-<backend>-<version>-<target>` artifact: the
   suite log, `results.tsv` (every test's outcome), `verdict.json`, and
   for `git` the per-script `.out` files in full.

A cell marked **incomplete** never counts as known: the suite timed
out, died before its summary, or printed totals that disagree with what
`bin/ci/collect-results.py` parsed. Check the mount actually came up,
then whether the suite's output format changed under the parser.

## Not yet covered

- **NFS variants.** One localhost export with kernel-negotiated defaults
  is a thin proxy for "NFS". The settings that actually bite on HPC are
  protocol version (v3 vs v4.x), attribute caching (`ac` vs `noac` /
  `actimeo=0`), locking (`lock` vs `nolock`, and whether `rpc.statd` is
  even up), `sync` vs `async` on the export, and squashing. Each is a
  plausible row of its own.
- **A `Loop vfat` mask variant**, if we ever want to separate "vfat is
  not POSIX" from "vfat mounted with defaults is not POSIX".
