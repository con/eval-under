# DESIGN: eval-under as a reusable GitHub Action

> **Keep this in sync with [IMPLEMENTATION.md](IMPLEMENTATION.md).**
> This file holds *what and why*; IMPLEMENTATION.md holds *how*, plus the
> measurements and constraints already established. Any change here that
> alters an interface, a constraint, or the rollout order **must** be
> reflected there in the same commit -- and vice versa. If the two
> disagree, DESIGN.md wins and IMPLEMENTATION.md is the bug.

**Status:** design draft, nothing implemented yet.

## Problem

`bin/eval-under` already does the hard part -- mount a filesystem, run a
command against it, tear it down -- but the only consumer is this repo's
own matrix. Every downstream project that cares about
filesystem-specific behaviour has hand-rolled a worse version of the same
thing:

| Project | What it hand-rolls today |
| --- | --- |
| `datalad/datalad` | `.github/workflows/test_crippled.yml` (dd + `mkfs.vfat` + mount, i.e. `eval-under-loop --fs vfat --size 500` verbatim); an NFS export/mount block in `test.yml` triggered by a *regex on a path string* |
| `dandi/dandi-cli` | `mode: nfs` matrix cell: `mkdir` + `exportfs` + `mount -t nfs` + `TMPDIR`/`HOME` into `$GITHUB_ENV` |
| `con/fscacher` | nothing -- it has no filesystem coverage at all, despite its core datum being four filesystem-dependent `stat` fields |

Each covers one or two filesystems, none can sweep, and all of them
duplicate teardown-less setup that only works because hosted runners are
ephemeral.

## Goals

1. A downstream project can run its own test command under any
   eval-under backend by adding **one step**, reusing all of its existing
   per-job setup (venv, installed package, git config, caches) and all of
   its existing reporting (annotations, artifacts, codecov).
2. Sweeping across *all* known backends is a matrix concern, not an
   action concern -- so cells stay independently parallel, attributable,
   and re-runnable.
3. Consumers can **scope** a sweep by filesystem capability (skip vfat
   when the tests need symlinks) and by name regex (skip BeeGFS on PRs
   because DKMS is slow).
4. Capability data is **static, committed, and reviewed**. Consumers'
   CI must not become nondeterministic because a filesystem changed
   behaviour upstream.
5. The action is testable -- by this repo, on every backend, without a
   parallel test matrix.

## Non-goals

- Replacing this repo's own targets (`git-annex`, `git`, `pjdfstest`,
  `stress-ng`). Those stay private to eval-under; only the **backend**
  catalog is a public contract.
- Cross-platform support. Every backend needs Linux mount privileges;
  macOS and Windows runners are out of scope and must fail loudly rather
  than silently no-op.
- Persisting a mount across job steps (see *Constraints*).

## Target consumers

Adoption order is **fscacher -> datalad -> dandi-cli**, chosen by
feedback-loop length rather than by value.

### 1. `con/fscacher` -- the pilot

The whole library is `FileFingerprint(mtime_ns, ctime_ns, size, inode)`
guarded by a hardcoded `_min_dtime = 0.01`. All four fingerprint fields
are filesystem-dependent, and the constant assumes a resolution not every
filesystem has -- which makes fscacher the purest available test of the
premise. Its suite runs in **0.86 s**, so a red cell is diagnosable in
one CI round instead of the 40+ minutes a datalad NFS chunk costs.

Adoption cost: ~10 lines of YAML, no source change, no `tox.ini` change.

### 2. `datalad/datalad` -- the validation case

Already builds the dynamic-matrix pattern this design needs (a `filter`
job renders `tools/ci/test-jobs.yml` to JSON; `test` already has
`needs: filter`). So the auto-tracking sweep costs datalad **no new job
and no new wiring** -- it is the right place to prove that half of the
design. Exercises every hard case: `sudo -E` inside the mount, xdist,
per-cell timeouts, `allow-failure`.

Payoff: deletes `test_crippled.yml`, the NFS block in `test.yml`, and
`tools/eval_under_{nfs,testloopfs}` (from which our loop and NFS
backends were absorbed in the first place -- this is repatriation).

### 3. `dandi/dandi-cli` -- the motivating case

PR #1910 simulates coarse mtimes by monkeypatching `os.utime`, because
"real (ext4/XFS/tmpfs) temporary directories store mtimes with
nanosecond resolution and so cannot exercise this behavior". FAT stores
mtime at 2 s granularity for real, so `loop --fs vfat` reproduces issue
\#1907 without patching, and the simulation becomes a fast proxy
*validated against* a real filesystem. Goes last: it carries the most
incidental weight (docker-compose fixtures, codecov, five OSes).

## Design

### Two actions, one identity

**`actions/run`** wraps one command under one backend. It is
`bin/eval-under` with an `action.yml` around it; no new lifecycle code.

**`actions/list`** emits the backend catalog as a `fromJson`-able matrix,
filtered by capability and by name regex. GitHub's matrix does the
looping; eval-under only supplies data.

Both speak the **backend slug** (`nfs`, `loop-vfat`, `beegfs-7.4.6`) that
`backend_slug()` in `bin/ci/matrix.sh` already produces. One matrix key
(`fs: loop-vfat`) instead of three parallel ones, and job names, artifact
names and cell ids line up across all four repos for free.

### Capability tags

`backends:` rows in `.github/matrix.yaml` gain a `features:` map, mixing
booleans (`symlinks`, `hardlinks`, `xattrs`, `permissions`, `ownership`,
`stable-inodes`, `ctime-advances-on-write`) with scalars
(`mtime-granularity: 2s`, `case-sensitive: false`) -- because "how
coarse" is the question fscacher and dandi-cli actually ask.

Three layers of use, coarse to fine:

1. `actions/list` drops cells that are *wholly* pointless (`require:` /
   `exclude:` inputs).
2. The action exports the committed feature set into the run
   (`EVAL_UNDER_FS_FEATURES`) so a suite can `skipif` per test rather
   than losing the whole cell.
3. `continue-on-error` at the job level for cells red for a known reason
   (GOTCHAS.md; datalad already has `allow-failure`).

**Tags scope a sweep; they never predict its outcome.** A consumer that
excludes every backend lacking a feature will never find the bug where
its code wrongly assumed that feature.

### Keeping the tags honest

Declared capabilities rot. So they are **measured in eval-under's own CI
and committed**:

- A probe runs in cells we already run -- after mount, before the suite,
  ~1 s -- and uploads `features-<slug>.json` beside the existing
  `result-<slug>`. No new jobs, reusing the fan-out/fan-in already built
  for the badges.
- Each backend appears in every target cell, so one run yields several
  independent measurements per backend. Unanimity is required before a
  change is believed; disagreement means a flaky probe, visibly.
- The existing `publish` job reconciles measured against committed. On a
  PR it **fails with the diff**; on master/schedule it **opens a PR**
  against eval-under. Same discipline as `gen-readme-matrix.sh`:
  generated data is committed, CI verifies it is current, drift arrives
  as a reviewable diff.
- Per-feature provenance. `source: measured` only for structurally
  determined properties. Timing-dependent ones (NFS attribute-cache
  windows) are `source: declared`, cite GOTCHAS.md, and are never
  overwritten by a probe.

Consumers read only the committed table, pinned by tag, and never probe.
An opt-in `probe: true` exists for someone running against an
untabulated real-world NAS, where there is no row to trust anyway.

**Capabilities belong to the mount configuration, not the filesystem.**
`nfs` and `nfs --no-root-squash` differ in `ownership`. The action must
compare the options it was given against the row's pinned options and
**fail loudly on divergence** -- that is the one way a static table
silently becomes a lie.

### New backends

- `bin/eval-under-none` -- runs the command with nothing mounted. Gives
  consumers one uniform step for wrapped and unwrapped runs, gives this
  repo a baseline row that distinguishes "BeeGFS-specific" from "red
  everywhere", and is what makes act compatibility achievable at all.
- Optional, if datalad's mechanism is to be absorbed whole rather than
  halved: `bin/eval-under-symlink` and `bin/eval-under-spaces` for odd
  *paths* (`/var/tmp/sym link`, `/var/tmp/d i r`). eval-under's real
  contract is "point TMPDIR somewhere hostile and run"; the filesystem is
  just the interesting case.

## Constraints that shape the design

| Constraint | Consequence |
| --- | --- |
| Composite actions have no `post:` step | No "mount now, teardown later" setup action. The `run:`-input exec-wrapper shape is the only one that keeps `trap teardown EXIT`. |
| Expressions are not allowed in `uses:` | A PR cannot pin the action to its own branch. Self-tests use `uses: ./actions/run`, which resolves against `$GITHUB_WORKSPACE` and *is* the PR's version. |
| A job's `strategy.matrix` can only come from a prior job's outputs | The dynamic sweep needs a `needs:` edge. Free for datalad (already has one), a real cost for dandi-cli. |
| `sudo` must not wrap the action | All backends already sudo internally and run the wrapped command as the invoker. `sudo -E eval-under nfs` would defeat the root_squash drop-back. Consumers put sudo *inside* the `run:` input. |
| Project rule: no shell logic in workflow YAML (`.claude/CLAUDE.md`) | A composite action's `run:` blocks are exactly that. All logic lives in `bin/ci/action-*.sh`; `action.yml` is a thin invoker. Keeps shellcheck and local testability. |
| BeeGFS needs `ubuntu-22.04` | The runner OS is a per-backend property, not a consumer's guess. `actions/list` emits it. |

### act compatibility: attempted, with a bounded promise

**Yes, but scoped to plumbing, not filesystems** -- the same line the
README already draws for the existing workflow. act runs jobs in
containers; it cannot exercise a BeeGFS kernel module or a host NFS
server, and pretending otherwise would be a worse promise than a narrow
one kept.

What makes the narrow promise real is `backend: none`: a flow test that
mounts nothing needs no privileges, no kernel modules, no host services,
so it runs anywhere. Rules that follow, and that we accept as design
constraints:

- **No `uses:` inside the composite** -- pure `shell: bash` steps.
  (Hence dependency install is our own script, not a marketplace action.)
- **Inputs passed through `env:`, never interpolated into a script
  body.** Injection-safe *and* sidesteps act's multi-line-input quoting
  differences. One fix, two problems.
- **No `actions/upload-artifact` inside the action** -- artifacts are the
  consumer's business; under act they need `--artifact-server-path`.
- **Assert `$GITHUB_ACTION_PATH` early** with a clear error; it is the
  most likely point of divergence.

The loop backend *may* additionally work under `act --privileged` on a
host kernel carrying the module. BeeGFS and NFS are explicitly out of
scope under act.

## Testing the action

The structural move: **the action's contract test is a new target row**
(`selftest`), not a parallel matrix. `bin/ci/target-selftest.sh` asserts
what consumers depend on -- `TMPDIR` is on the mount, `HOME` is untouched
unless `set-home`, the command runs as the invoker and not root, prior
step env survived, a failing command propagates its exit code, teardown
ran. Every backend then tests the action automatically, and adding a
backend tests the action there for free.

Layers, cheapest first:

1. `shellcheck bin/ci/action-*.sh` (existing house rule) + `actionlint`
   over workflows and `action.yml` (also catches expression-in-`uses`).
2. Pure-data tests of `actions/list` filtering against fixture matrix
   files. Milliseconds, no mounts -- and the filter is where
   consumer-visible bugs will live.
3. The `selftest` target above, on every backend.
4. Route this repo's existing 20 cells through `./actions/run`, making
   them the action's integration test at zero extra job cost.
5. Negative tests: unknown backend, missing `run`, non-Linux runner,
   options diverging from the pinned feature row. Assert the *message*,
   not just the exit code.

For the one thing `./actions/run` cannot cover -- whether
`owner/repo/subdir@ref` resolves for a stranger -- in order of value: an
act-driven synthetic consumer referencing a subdirectory checkout of the
PR; a scheduled tag canary using `@v1`; and, once fscacher adopts it, its
nightly as the real external integration test.

## Extra infrastructure needed

- **Vagrant VM** (`Vagrantfile` + `provision/`, already present) is the
  only place act can be exercised: the dev container this repo is edited
  in has no docker daemon and a kernel with no `vfat`, so neither act nor
  the loop backend can run there. `provision/install-act.sh` already
  exists behind `VAGRANT_INSTALL_ACT=1`.
- **`bin/ci/act-selftest.sh`** so the act invocation is one command and
  gets shellcheck'd, rather than a README incantation. Running act
  *inside* GitHub Actions is possible but slow and fragile -- not worth
  it.
- **`actionlint`** in CI (no docker needed).
- **A `features` target + reconciliation in `publish`** for the
  capability table.
- A `v1` tag and a moving major tag once the interface settles.

## Open questions

1. Do the odd-*path* backends (`symlink`, `spaces`) belong here, or is
   that scope creep past "filesystems"?
2. Should `.github/matrix.yaml` split into a public `backends.yaml` and a
   private `targets.yaml`, or is a documented "only `backends:` is
   contract" note enough?
3. Does the feature table live in `matrix.yaml` beside each backend row,
   or in a generated `features.json` that CI regenerates? (The latter
   makes the "CI opens a PR" flow cleaner; the former keeps one source of
   truth.)
4. `mtime-granularity` as a probed scalar is the direct input to
   dandi-cli's `coarse_mtime_fs` parametrization -- worth exporting in a
   consumable form, or leave it to the consumer to read the table?
