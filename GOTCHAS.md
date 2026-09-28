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
| Image size | per target, `loop-size-mb` in `evals/matrix.yaml` | `git annex test` needs room for many small objects; the other three do not. |
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

### sshfs (`bin/eval-under-sshfs`)

A throwaway sshd is started on the first free port at or above 2222 --
its own host key, its own `authorized_keys`, its own pid file, all inside
the run's scratch directory -- and a fresh backing directory is
sshfs-mounted back over it. The system sshd is not used and
`~/.ssh/authorized_keys` is never written to. With `--host` it mounts a
real remote instead, using the caller's ssh config.

| Knob | Value | Why |
| --- | --- | --- |
| Port | first free `>= 2222` | Two runs at once (a reproduction while a suite is going, two CI cells on one runner) must not collide. `--port` pins it. |
| `-o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3` | always | A dropped connection should fail the command, not wedge it forever. |
| `-o cache=no` | only with `--no-cache` | sshfs caches attributes by default, which hides stale-stat behaviour. This turns off sshfs's own cache, not all caching -- the kernel's 1-second attribute timeout still applies, and the stale-size effect above survives it. On is what users actually have. |
| `-o workaround=rename` | only with `--workaround rename` | Makes sshfs emulate rename-over-existing by unlinking first -- non-atomic, which is what SFTP servers without the POSIX-rename extension force. |
| Mount/command user | the invoking user | A FUSE mount belongs to whoever ran `sshfs`; root cannot read it without `allow_other`. Same treatment `eval-under-nfs` gives `root_squash`. |

**Hardlinks exist but are not observable, and that is the whole story
for git-annex.** `ln a b` succeeds over SFTP, and then `a` and `b` report
*different* inode numbers and `nlink=1` each:

```
ext4     name=a ino=1884275 nlink=2      name=b ino=1884275 nlink=2
sshfs    name=a ino=3       nlink=1      name=b ino=4       nlink=1
```

This is not a misconfiguration, and the link is not fake: in the backing
directory on the server both names really do share one inode with
`nlink=2`. What SFTP cannot carry is *identity* -- its attribute record
has neither an inode number nor a link count -- so sshfs synthesises an
`st_ino` per path and reports `nlink=1` for everything. There is no knob
for it: `use_ino` (removed in libfuse 3) only ever passed through inode
numbers that a filesystem supplies, and sshfs has none to supply, so it
would not have helped under FUSE2 either; sshfs 3.7 offers only
`disable_hardlink`, which makes `link()` fail outright.

Worse than invisible, and worth knowing when a report mentions truncated
files: immediately after writing one name, the *other* name still reads
back with size 0 through the mount -- with `-o cache=no` as well. The
capability probe reports the inode half as
`hardlink-same-inode=no` / `hardlink-nlink=no` while `hardlink=yes` --
which is exactly why those two checks exist. `hardlink` alone called
sshfs healthy.

What it costs, measured with git-annex 10.20240129:

- `git annex add` on a **locked** branch: fine. The file becomes a
  symlink into `.git/annex/objects`, and symlinks work.
- **Any unlocked `git annex add`: fails** -- `foo failed to link to
  annex`. add hardlinks the content into the annex and then verifies the
  link, and the verification cannot succeed on a filesystem where the
  link is invisible. This is not limited to an adjusted branch: a plain
  v10 repo fails identically with `annex.addunlocked=true` in git
  config, set through `git annex config`, or passed as `-c`.
- `git add` through git's own filter (with `annex.largefiles` matching):
  **fine** -- the pointer is committed and `git annex fsck` is clean.
  So is `git annex unlock` of an already-committed file.
- `git clone` of a local repo: **fails** --
  `fatal: hardlink different from source at '...'`. git's local-clone
  path hardlinks objects and runs the same check.

So the boundary is not locked-vs-unlocked, and not adjusted-vs-plain:
it is **who does the ingest**. git-annex hardlinking content into the
annex fails; git's filter writing a pointer does not.

That distinction is easy to get backwards from the test suite alone,
because `git annex test` shows `Repo Tests v10 unlocked` **green** and
only `v10 adjusted unlocked branch` red (11 of 12 in its Init Tests
group, once `add` fails). The green group is not evidence that unlocked
repos are fine here -- the suite's unlocked mode ingests with `git add`.
An earlier revision of this file drew exactly that inference and was
wrong.

It matters for DataLad, which calls `git annex add`: plain v10 unlocked
repos break for it too, not just adjusted ones.

**`git annex test` wedges partway through, reproducibly.** Both
full-suite runs stopped at the same place -- `Remote Tests / unavailable
remote / removeKey` -- and sat there until killed (15+ minutes on the
second). On ext4 that same test takes **0.02s and passes**, and the whole
suite finishes in 1m21s.

It is not an I/O hang. While wedged:

- the mount stays responsive (`ls` returns immediately),
- git-annex holds **no open files on the mount and no sockets**,
- its threads sit in `futex_do_wait` / `ep_poll`, with no child
  processes outstanding.

That is a process waiting on something internal, not one blocked on the
filesystem. Note also that git-annex sets `annex.sshcaching = false` here
on its own, because ssh control sockets need unix sockets and this mount
has none -- so the run is already on a different code path from a normal
one.

Two caveats before anyone reports this upstream: the same test passes in
seconds when selected on its own with `-p '/unavailable remote/'`, so it
needs the full-suite context; and this was git-annex 10.20240129 from
Ubuntu 24.04, not a daily build. Re-run it through the reproduce
workflow, which installs the daily build from con/git-annex, before
filing anything.

**Timestamps are quantised to the second.** Five files created back to
back get one or two distinct mtimes, where every other filesystem
measured gives five. Nothing else in the matrix has a clock this coarse,
which makes sshfs the row that exercises git's racy-timestamp handling.

**No fifos, no unix sockets.** git-annex says so itself at init
("Detected a filesystem without fifo support") and adapts. Worth knowing
before reading it as a failure.

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

<a id="sshfs-git-local-clone-hardlink"></a>
### `sshfs-git-local-clone-hardlink`: local `git clone` verifies its hardlinks, and sshfs synthesises st_ino

**Cells:** `sshfs-git` \
**Tags:** `fs-divergence` \
**Tests:** `t0001-init.sh#37`, `t0003-attributes.sh#24-25,29,32-34`, `t0021-conversion.sh#28-30`, `t0033-safe-directory.sh#16`, `t0035-safe-bare-repository.sh#1,13`, `t0410-partial-clone.sh#34,38`, `t0610-reftable-basics.sh#26-28`, `t1013-read-tree-submodule.sh#1-8,10-15,18-28,30-48,51-60,65-68`, `t1060-object-corruption.sh#12`, `t1091-sparse-checkout-builtin.sh#31-32,36-38,49,77`, `t1350-config-hooks-path.sh#4`, `t1423-ref-backend.sh#36`, `t1460-refs-migrate.sh#9,24`, `t1500-rev-parse.sh#77`, `t1507-rev-parse-upstream.sh#1-7,9-11,13-14,17-18,21,23-27`, `t1600-index.sh#6`

SFTP's `ATTRS` carries no inode number, so sshfs synthesises `st_ino`
per path. `git clone <local path>` hardlinks each object and then
compares `st_mode`/`st_ino`/`st_dev`/`st_size`/`st_uid`/`st_gid`
against the source (`builtin/clone.c`), so the check fails and the
clone dies with `fatal: hardlink different from source`. **Plain
`git clone` of a local path does not work on sshfs at all.**

Each script here clones, or adds a submodule (which clones), in its
setup, so one failed setup cascades through the script; the scripts
were attributed by that message appearing in their own logs.
`git clone --no-hardlinks`, `git clone file://...` and mounting with
`-o disable_hardlink` all work -- with the option, sshfs fails
`link()` with `EPERM` instead of pretending, and git falls back to
copying.

Test ids seeded from run 36476334300 (git v2.55.0), 110 assertions
across 16 scripts.

See: [sshfs (`bin/eval-under-sshfs`)](#sshfs-bineval-under-sshfs)

<a id="sshfs-git-no-unix-sockets"></a>
### `sshfs-git-no-unix-sockets`: git's IPC and credential-cache tests need Unix sockets on the work tree

**Cells:** `sshfs-git` \
**Tags:** `fs-limitation` \
**Tests:** `t0052-simple-ipc.sh#1-9`, `t0301-credential-cache.sh#2-3,7-8,10-11,13-23,25-26,28,30,32-33,37-38,40-41,43-52`

sshfs has no Unix sockets: `bind()` on the mount fails with
`Operation not permitted`, so the credential-cache daemon never
starts (`unable to bind to .../credential/socket`) and simple-ipc
finds `no server listening`. `unix-socket=no` in
`bin/ci/fs-capabilities.sh` predicts both. The same limitation is
recorded for vfat as `vfat-git-no-unix-sockets`.

See: [sshfs (`bin/eval-under-sshfs`)](#sshfs-bineval-under-sshfs)

<a id="sshfs-git-untriaged"></a>
### `sshfs-git-untriaged`: remaining git failures on sshfs, not yet attributed

**Cells:** `sshfs-git` \
**Tags:** `needs-triage` \
**Tests:** `t0003-attributes.sh#41,48`, `t0017-env-helper.sh#4`, `t0040-parse-options.sh#37`, `t0061-run-command.sh#6,18`, `t0302-credential-store.sh#57`, `t0450-txt-doc-vs-help.sh#131,647,797`, `t0610-reftable-basics.sh#61`, `t1091-sparse-checkout-builtin.sh#21,43,48`, `t1092-sparse-checkout-compatibility.sh#55`, `t1300-config.sh#194,197,237,285,494`, `t1403-show-ref.sh#9`, `t1430-bad-ref-name.sh#26`, `t1450-fsck.sh#36`, `t1461-refs-list.sh#415`, `t1503-rev-parse-verify.sh#4`, `t1700-split-index.sh#10-12,14-15`

**These are flaky, not fixed divergences, and this entry cannot
gate the cell.** Two mechanisms above are deterministic; this
residue is not. Measured three ways:

- The same cell on two CI runs of near-identical code
  (36476334300, then 36485450259) reported 12 and 18 residual
  failures with **no overlap**: every id the first run flagged
  passed in the second, and vice versa. The two mechanism entries
  meanwhile reproduced exactly both times, 110 and 46.
- Locally, six runs of `t0003 t0017 t0040 t1700` under sshfs:
  `t0003`'s six hardlink assertions failed in all six runs, while
  `t0017#4` failed in one and `t0040#37`, `t1700#10-15` and
  `t0003#41`/`#48` in none -- although CI has flagged each of them.
- `prove --jobs 1` is no cleaner than `--jobs 4`, and 14 runs of
  `t0017` alone were all clean, so it takes the fuller suite's
  concurrent load to show up at all.

Some of these tests touch no filesystem semantics whatsoever --
`t0040#37` "OPT_CALLBACK() and OPT_BIT() work" and `t0017#4`
"test-tool env-helper --type=ulong" parse arguments and
environment variables, and `t0450` compares documentation against
`-h` output. What they do share is capturing output into `>out` /
`2>err` inside the trash directory on the mount and then grepping
it, which points at the mount losing or delaying writes under
concurrent load rather than at any semantic divergence.

So a `script#N` list is the wrong instrument here: each run draws a
different sample, and pinning one run's sample is what made this
cell report `failing-new` twice. Untried candidates, in order:
mounting with `-o attr_timeout=0 -o entry_timeout=0` (and possibly
`-o max_conns=N` or `-o sync_read`) to see whether the residue
disappears, which would make the cell deterministic and properly
xfail-able.

See: [sshfs (`bin/eval-under-sshfs`)](#sshfs-bineval-under-sshfs)

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
