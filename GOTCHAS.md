# Gotchas

A result from this matrix only means something relative to *how* the
filesystem was made and mounted. `vfat` mounted with `fmask=0177`
behaves differently from `vfat` mounted with kernel defaults; NFS
exported `root_squash` behaves differently from `no_root_squash`. So
this file records two things:

1. **[The settings](#backend-settings)** each backend actually uses, and
   what each one implies for the suites running on top.
2. **[The known-red cells](#known-red-cells)** and their root causes, so
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

## Known-red cells

A red cell here is a finding, not a bug report against this repo. These
are the ones already run down.

### `Loop vfat / *` -- all four targets

vfat is not a POSIX filesystem. No symlinks, no ownership, no
permissions, no hardlinks, 2-second timestamp granularity,
case-insensitive names, and a restricted filename charset (`:` `?` `*`
`"` `<` `>` `|` are all illegal, and git's own test suite creates
filenames using several of them). Every target trips over some subset.
The row exists to show *which* subset, per layer.

### `Loop vfat / git testsuite` -- the interesting one

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
failures in that script.

**This is not a git bug and not a regression.** Nobody upstream runs
git's test suite on a vfat work tree, so an OS-derived `POSIXPERM` has
never cost them anything. It is a fair finding about the *test suite's*
portability assumptions rather than about git the program -- which is
precisely the kind of thing a backends × targets grid is for.

### `NFS (localhost) / pjdfstest`

Runs to completion (238 files, ~8800 assertions) and reports real
divergence, not a setup failure:

- `chown/00.t`: ~106 of 1280 failing, plus a batch of "TODO passed"
  assertions -- upstream expects those to fail and NFS passes them.
  Mostly setuid/setgid clearing behaviour on `chown`.
- `chmod/00.t`: 1 failure.
- `unlink/14.t`: 1 failure.

Note this cell runs `--no-root-squash` (see above); under the default
`root_squash` the suite refuses to start at all.

### `BeeGFS 7.4.6 / pjdfstest`, `BeeGFS 8.1.0 / pjdfstest`

Real failures on both versions, not yet broken down per assertion.

### `BeeGFS * / git-annex test`

The original motivating bug. Note the useful negative result now
available beside it: `BeeGFS * / git testsuite` **passes** on both
versions. Whatever BeeGFS does differently, it is not breaking git's
index, refs, or object plumbing -- so the cause sits in what git-annex
layers on top, or in the syscalls the pjdfstest column is flagging.

### `sshfs (loopback) / git-annex test`

Red by design, and the reason this backend is in the matrix. SFTP's
`ATTRS` carries no inode number and no link count, so sshfs synthesises
`st_ino` per path and reports `nlink=1`. `git annex add` hardlinks
content into `.git/annex/objects` and then verifies the link; the
verification cannot observe a link that the protocol does not express, so
the add fails with `failed to link to annex`. `hardlink=yes` with
`hardlink-same-inode=no` in `fs-capabilities.sh` is the same finding in
ten seconds rather than twenty minutes.

Not locked-vs-unlocked and not adjusted-vs-plain: what matters is who
does the ingest. `git add` through the annex filter writes a pointer and
succeeds, which is why git-annex's own `Repo Tests v10 unlocked` group is
green while `annex.addunlocked=true` in a plain v10 repo fails.

`-o disable_hardlink` fixes it, counter-intuitively: sshfs then fails
`link()` with `EPERM` instead of pretending, git-annex falls back to
copying, and the add succeeds. Measured on a loopback mount here:

| | sshfs default | sshfs `-o disable_hardlink` | ext4 |
| --- | --- | --- | --- |
| `git annex add` (locked) | ok | ok | ok |
| `git annex add`, `annex.addunlocked=true` | **failed to link to annex** | ok | ok |
| `git clone <local path>` | **fatal: hardlink different from source** | ok | ok |

Both rows marked failing here are red in CI as well, on the
`sshfs (loopback)` matrix cells, which is what those cells are for.

So a filesystem that advertises hardlinks it cannot express is worse than
one that admits it has none: every caller here has a copy fallback, and
only the honest failure reaches it. Worth suggesting to a reporter as a
mount option before anything else.

### `sshfs (loopback) / git testsuite`

Red, and not for the reason first assumed: git's suite *does* hardlink
into an object store. `git clone <local path>` hardlinks each object and
then sanity-checks the result, comparing `st_mode`, `st_ino`, `st_dev`,
`st_size`, `st_uid` and `st_gid` against the source
(`builtin/clone.c`). sshfs synthesises `st_ino` per path, so the
comparison fails and the clone dies:

```
$ git clone a b
fatal: hardlink different from source at 'b/.git/objects/a1/dffc7a...'
```

**Plain `git clone` of a local path does not work on sshfs at all.** That
is a broader statement than the git-annex one above, and the same
mechanism. `git clone --no-hardlinks` and `git clone file://...` both
work, as does `-o disable_hardlink` per the table above.

Two established causes account for most of it:

- **local clone hardlink verification** -- `t1507-rev-parse-upstream`
  (20), `t1013-read-tree-submodule` (58), `t0035-safe-bare-repository`
  (2). Each does a local clone or adds a submodule (which clones) in
  setup, so one failed setup cascades through the script.
- **no unix sockets** -- `t0301-credential-cache` (37), which reports
  `fatal: unable to bind to '.../credential/socket': Operation not
  permitted`, and `t0052-simple-ipc` (9/9), whose server never comes up.
  `unix-socket=no` in the capability profile predicts both.

Measured against an ext4 control, whole suite (174 scripts, 10366
assertions): 166 failed assertions in 24 scripts locally, 179 in the CI
run of the same commit. Treat the count as "of order 170", not exact --
it moves by ~10 between runs of the same tree, which is itself worth
knowing before reading a delta as a regression. The two causes above
dominate it either way. The remainder are small and **not** yet explained -- `t0003-attributes` (6),
`t1091-sparse-checkout-builtin` (8), `t0610-reftable-basics` (3),
`t0021-conversion` (3), and ten scripts with one each. Do not assume
they share a cause with the two above.

Reproduce a single script rather than the suite:

```bash
sudo bin/eval-under sshfs --set-home -- \
  env EVAL_UNDER_GIT_TESTS=t1507-rev-parse-upstream.sh bin/ci/target-git.sh
```

Two things this cell taught the harness, recorded so they are not
re-learned:

- `not ok N ... # TODO known breakage` is git's `test_expect_failure`, a
  TAP TODO directive that prove counts as an expected result. Counting
  those as failures had this cell reporting 351 failed assertions where
  prove saw 166, with `t1517-outside-repo` (104) and
  `t0450-txt-doc-vs-help` (54) -- both of which prove reports as **ok**
  -- looking like the worst offenders. `bin/ci/dump-failure-logs.sh` now
  excludes the directive.
- A script that fails only in the full run is not automatically a
  concurrency effect. Both scripts above pass in isolation *and* in the
  full suite; it was the counting that differed, not the filesystem.

### `sshfs (loopback) / stress-ng`, `sshfs (loopback) / pjdfstest` -- no cells

Not red, absent. A FUSE mount belongs to whoever mounted it and there is
no `--no-root-squash` equivalent, so these suites could only report on
privilege, not on the filesystem. `no-root: true` on the backend row in
`.github/matrix.yaml` drops the pair everywhere (workflow, README grid,
badges, report page), and `bin/ci/run-under.sh` refuses it outright with
exit 2 if asked directly.

### `Loop ext4 / git-annex test`

Pre-dates the matrix; ext4 is the control row, so this one *is* a real
bug worth chasing rather than a filesystem property.

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

1. Look at the summary block at the end of the job log. Every target
   ends with a machine-countable one: `prove`'s `Test Summary Report`
   for `git` and `pjdfstest`, a pass/skip/fail tally for `stress-ng`.
2. Then the `=== ... failures ===` dump printed by
   `bin/ci/dump-failure-logs.sh`, which names the failing assertions and
   their output.
3. Then the uploaded `logs-<backend>-<version>-<target>` artifact, which
   carries the per-script `.out` files in full.

If a cell produces no summary at all, the suite died before finishing --
check the mount actually came up.

## Not yet covered

- **NFS variants.** One localhost export with kernel-negotiated defaults
  is a thin proxy for "NFS". The settings that actually bite on HPC are
  protocol version (v3 vs v4.x), attribute caching (`ac` vs `noac` /
  `actimeo=0`), locking (`lock` vs `nolock`, and whether `rpc.statd` is
  even up), `sync` vs `async` on the export, and squashing. Each is a
  plausible row of its own.
- **Per-assertion breakdown** of the BeeGFS pjdfstest failures.
- **A `Loop vfat` mask variant**, if we ever want to separate "vfat is
  not POSIX" from "vfat mounted with defaults is not POSIX".
