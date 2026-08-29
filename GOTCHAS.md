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

### `Loop ext4 / git-annex test`

Pre-dates the matrix; ext4 is the control row, so this one *is* a real
bug worth chasing rather than a filesystem property.

## Red that is not a finding

Distinct from the cells above: these are harness races, and the fix is in
this repo rather than in anything under test.

### BeeGFS: `chown: cannot access '/mnt/beegfs': Communication error on send`

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

## Reading a timing number

Timings come from `bin/ci/bench-matrix.sh` (see the README), never from
CI: each matrix cell runs on a different hosted runner, so two job
durations are two machines, not two filesystems. Even run locally, four
things decide whether a number means anything.

| Trap | What it does to the number | Handled by |
| --- | --- | --- |
| Scratch on `/tmp` | `/tmp` is tmpfs on many systems, so the loop backing image lives in RAM and the loop rows come out several times too fast | Default `--scratch /var/tmp`; `env.txt` records the scratch filesystem |
| Backend setup counted as suite time | BeeGFS spends ~60s booting its container cluster before the suite starts; charged to the filesystem it swamps a short target | `bin/ci/time-it.sh` runs inside the mount, setup lands in the report's `setup` column |
| A warm page cache | Whichever backend ran first pays for the cold cache, the rest inherit it | Caches dropped before each run unless `--no-drop-caches` |
| A red or timed-out cell | A suite that aborts early "finishes" quickly -- vfat looks like the fastest filesystem in the matrix | `status` column, plus the note under the table; raise `--timeout` and re-run |

What no local driver can subtract: the BeeGFS servers are containers on
the same host and NFS goes through the loopback stack, so those rows
include server CPU that the loop rows do not. A ratio measured here
describes this topology -- one box, everything colocated -- and not a
real cluster with the servers on the far side of a network.

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
