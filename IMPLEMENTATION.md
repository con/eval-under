# IMPLEMENTATION: eval-under as a reusable GitHub Action

> **Keep this in sync with [DESIGN.md](DESIGN.md).**
> DESIGN.md holds *what and why*; this file holds *how*, plus the
> measurements and constraints already established so nobody re-derives
> them. Any change to an interface, constraint, or rollout order must
> land in both files in the same commit. If the two disagree, DESIGN.md
> wins and this file is the bug.

**Status:** nothing implemented yet. Everything below is either an
established fact (marked **[verified]**, with how) or a decision already
taken in design discussion.

## 1. Established facts

### 1.1 The backends already run the wrapped command as the invoker

**[verified: read of `bin/eval-under-{loop,nfs,beegfs}`]** All three do
`SUDO=(sudo)` when `id -u` != 0 and use it only for the privileged bits
(losetup/mkfs/mount, exportfs, docker compose). The wrapped command runs
as the invoking user.

`bin/eval-under-nfs` goes further: unless `--no-root-squash`, it drops
back to the pre-sudo user via `sudo -u "$INVOKER_USER" -E env ...`,
because a root process cannot write to a user-owned mount root under
`root_squash`.

**Consequence:** the action must invoke `bin/eval-under` *plain*, not
under `sudo -E` the way `bin/ci/run-under.sh` is invoked from our own
workflow. Called plain on a hosted runner (passwordless sudo), the
wrapped `pytest` keeps the `runner` user, its venv and its `$HOME` from
prior steps -- which is precisely the "reuse all prior setup" property
the whole feature exists for. This difference from our own CI needs a
line in the action's README.

Corollary for datalad's `PYTEST_WRAPPER: "sudo -E"` job: sudo goes
*inside* the `run:` input (`eval-under nfs -- sudo -E pytest`), never
around the action.

### 1.2 GitHub Actions constraints

- **[verified: documented behaviour]** Expressions are not supported in
  `uses:` at step level. `uses: con/eval-under/actions/run@${{ github.sha }}`
  is invalid, so a PR cannot dynamically pin the action to its own ref.
- **[verified: documented behaviour]** `uses: ./actions/run` resolves
  relative to `$GITHUB_WORKSPACE` after `actions/checkout`, so in-repo
  self-tests automatically exercise the PR's version. This is the
  answer to the pinning problem for everything except the download path.
- **[verified: documented behaviour]** Composite actions have no `post:`
  step (`runs.post` is JavaScript-only; Docker actions have
  `post-entrypoint`). Rules out a mount-now/teardown-later setup action
  without writing a JS action and splitting every backend into
  mount/umount halves.
- **[verified: documented behaviour]** Composite actions do **not**
  expose inputs as `INPUT_*` environment variables -- that is
  JS/Docker-action behaviour. In a composite you must interpolate
  `${{ inputs.x }}`. So `action.yml` maps each input to `env:` on the one
  step, and `bin/ci/action-run.sh` reads env only. This is also the
  injection-safe way to carry the multi-line `run:` input.
- A job's `strategy.matrix` can only be fed from a prior job's outputs,
  so the dynamic sweep requires a `needs:` edge.
- `actions/upload-artifact` rejects slashes in artifact names -- already
  why `cell_slug()` exists (see the comment in `bin/ci/matrix.sh`).

### 1.3 Consumer inventory

**fscacher** (`con/fscacher`, `.github/workflows/test.yml`):
- Plain `os x python-version x toxenv` matrix with two `include:` rows;
  macOS and Windows present, so fs rows must be `os: ubuntu-*`.
- Tests run via `tox -e py`.
- **[verified: `tox.tox_env.api.ToxEnv._default_pass_env` source
  inspection, tox 4]** tox passes `TMPDIR` and `HOME` through by default
  on non-Windows. So fscacher needs **no** `tox.ini` change. But tox
  passes no *custom* variables -- anything eval-under sets beyond those
  (`DATALAD_TESTS_TEMP_DIR`, a future `DANDI_TESTS_TEMP_DIR`,
  `EVAL_UNDER_FS_FEATURES`) needs an explicit `passenv` entry. Document
  this in the action README; all three adopters will hit it.
- **[verified: run locally]** Full suite is **26 passed, 1 skipped in
  0.86 s** on ext4.
- Core datum, `src/fscacher/cache.py`:
  `FileFingerprint(namedtuple(..., "mtime_ns ctime_ns size inode"))`,
  built from `os.stat(path, follow_symlinks=True)`, plus
  `_min_dtime = 0.01`. Tests do `time.sleep(cache._min_dtime * 1.1)`
  (11 ms) to step past the "too recently modified to trust" window.
- Symlink coverage is guarded by `if op.islink(symlink1)` after a Windows
  check -- an OS-keyed guard doing filesystem-keyed work; on Linux+vfat
  `os.symlink` raises before the guard is reached.

**datalad** (`datalad/datalad`):
- `.github/workflows/test.yml` already renders its matrix dynamically:
  a `filter` job runs `yq` over `tools/ci/test-jobs.yml`, and `test` has
  `needs: filter`. The `needs:` cost of a dynamic sweep is already paid.
  (`actions/list` should emit JSON directly so consumers need no `yq`.)
- Job entries carry `extra-envs`, `allow-failure`, `cron-only` -- the
  natural place for an `fs:` key.
- NFS setup lives in a step named "Configure _DL_TMPDIR before installing
  git-annex", triggered by `[[ "${_DL_TMPDIR:-}" =~ .*/nfsmount ]]`.
  Same step also handles `.*/sym\ link` and `.*/d\ i\ r` -- odd *paths*,
  not odd filesystems.
- `.github/workflows/test_crippled.yml` is `dd` 500 MB -> `mkfs.vfat` ->
  `mount -o uid=,gid=` -> `TMPDIR=/crippledfs`, i.e.
  `eval-under-loop --fs vfat --size 500` verbatim. Our loop and NFS
  backends were absorbed *from* `tools/eval_under_{testloopfs,nfs}`;
  adopting the action is repatriation, and those tools can then go.
- Sets only `TMPDIR`, never `HOME` -> `set-home: false`. (dandi-cli sets
  both -> must be an input.)
- NFS chunks are split with `allow-failure: true` because the full suite
  hits GitHub's 6 h job timeout. Our `matrix.yaml` already carries the
  lesson (per-target `timeout` so a runaway suite yields an exit code and
  logs rather than a bare cancellation) -> the action needs a `timeout`
  input.

**dandi-cli** (`dandi/dandi-cli`, `.github/workflows/run-tests.yml`):
- Discriminates on `mode:` with `include:` rows; `mode: nfs` already
  exists and is a hand-rolled version of this action (sets `TMPDIR`,
  `HOME`, and `DANDI_DEVEL_INSTRUMENT_REQUESTS_SUPERLEN` into
  `$GITHUB_ENV`).
- Uses `ubuntu-latest`; BeeGFS cells need `ubuntu-22.04` (our workflow
  comment: 24.04 runners ship 6.17-azure, which BeeGFS DKMS cannot build
  against).
- PR #1910 adds a `coarse_mtime_fs` fixture monkeypatching `os.utime` to
  quantize, parametrized over `[0.0, 1.0, 2.0]`, with the docstring
  noting real ext4/XFS/tmpfs "cannot exercise this behavior".

### 1.4 The vfat experiment, and why it argues for the whole project

Trying to validate "fscacher goes stale on vfat" without a vfat mount
produced **two models that disagreed**:

- *Model 1* -- quantize `st_mtime_ns` to 2 s on ext4, leave everything
  else: **cache correctly invalidated**. Rescued by ext4's nanosecond
  `ctime`, which advances on write.
- *Model 2* -- also model that vfat has no ctime (Linux reports the FAT
  *creation* time, 10 ms granularity, which does not advance on
  modification): `read1='v1' read2='v1' on-disk='v2' calls=1` --
  **stale cache hit**.

Same library, same prediction, opposite answers, differing by one detail
of how FAT stores `ctime`. **[unverified against a real vfat mount]** --
this container's kernel has no `vfat` in `/proc/filesystems`.

Two takeaways worth keeping:
1. Model 2 is believed closer, so the fscacher pilot's headline
   prediction stands -- but as a hypothesis to test on a real mount, not
   a result.
2. `ctime-advances-on-write` is a capability nobody would think to
   declare by hand, and it is the field that decided the outcome. It
   belongs in the probed feature set.

### 1.5 Dev-container limits (why the Vagrant VM is required)

**[verified: run locally]** The container this repo is usually edited in:
- has `cap_sys_admin` and a working `losetup`, but `/proc/filesystems`
  lists only ext2/3/4, squashfs, erofs, fuseblk and the virtual
  filesystems -- **no `vfat`**, and no `/lib/modules` to load one from.
  `mount -o loop` of a `mkfs.vfat` image fails with "unknown filesystem
  type 'vfat'".
- has the `docker` client but **no docker daemon**, so act cannot run
  here at all.
- has no `shellcheck` and no `bats` installed.

So: loop-backend and act work must happen in the Vagrant VM. The
existing README already says as much for BeeGFS/NFS; extend that note to
cover `vfat` and act explicitly.

## 2. Component sketches

### 2.1 `actions/run/action.yml`

Thin by house rule (`.claude/CLAUDE.md`: no shell logic in workflow
YAML -- a composite `run:` block is exactly that). All logic in
`bin/ci/action-run.sh`.

```yaml
name: eval-under
description: Run a command with TMPDIR on a temporarily-mounted filesystem
inputs:
  backend:      {required: true}    # slug: nfs | loop-vfat | beegfs-7.4.6 | none
  set-home:     {default: 'false'}
  size-mb:      {default: ''}       # loop only; default from matrix.yaml
  timeout:      {default: '0'}
  install-deps: {default: 'true'}
  probe:        {default: 'false'}  # opt-in live probe; off by default
  run:          {required: true}
outputs:
  mount: {value: "${{ steps.eu.outputs.mount }}"}
runs:
  using: composite
  steps:
    - id: eu
      shell: bash
      env:                          # inputs via env, never interpolated
        EU_BACKEND: ${{ inputs.backend }}
        EU_SET_HOME: ${{ inputs.set-home }}
        EU_SIZE_MB: ${{ inputs.size-mb }}
        EU_TIMEOUT: ${{ inputs.timeout }}
        EU_INSTALL_DEPS: ${{ inputs.install-deps }}
        EU_PROBE: ${{ inputs.probe }}
        EU_RUN: ${{ inputs.run }}
      run: "$GITHUB_ACTION_PATH/../../bin/ci/action-run.sh"
```

`$GITHUB_ACTION_PATH` is `<checkout>/actions/run`, so `../../bin` is the
repo's `bin/`. Assert its existence early with a clear message -- it is
the most likely act divergence.

`bin/ci/action-run.sh` responsibilities: validate the slug against
`matrix.yaml`; refuse non-Linux; split slug -> backend + version;
translate to backend flags (`--fs`/`--size` for loop, `--version` for
beegfs, `--no-root-squash` where the row pins it); fail if given options
that diverge from the row's pinned options (see DESIGN.md, capability
table integrity); write `$EU_RUN` to a script under `$RUNNER_TEMP`; exec
`bin/eval-under <backend> ... -- [timeout N] bash -e <script>`.

### 2.2 `actions/list/action.yml`

Wraps `bin/ci/backends-json.sh`, which reads `backends:` from
`.github/matrix.yaml` and applies:
- `require:` / `exclude-features:` over the `features:` map,
- `include:` / `exclude:` regexes over the backend slug,
- an `os:` filter, since `runs-on` becomes a per-backend field.

Emits `{"include": [{slug, backend, version, label, os, features}, ...]}`
on one line (GitHub's `fromJson` wants one value; a multi-line
`$GITHUB_OUTPUT` needs heredoc quoting for no benefit -- same reasoning
as `bin/ci/matrix-json.sh`).

Reuse `bin/ci/matrix.sh` accessors; do not add a second parser.

### 2.3 `bin/eval-under-none`

Auto-discovered by the `eval-under-*` glob in `bin/eval-under`, so it
registers in `--list` for free. Runs the command with `TMPDIR` unchanged;
under `--set-home`, uses a `mktemp -d` so parity with the other backends
holds. Two jobs: uniform consumer step for wrapped/unwrapped runs, and
the act-compatible flow test.

### 2.4 Feature probe

New target `features` -> `bin/ci/target-features.sh`, emitting JSON.
Probes only structurally determined properties: symlink / hardlink /
xattr support, whether `chmod` sticks, whether `st_ino` survives a
rewrite, mtime granularity from a known-ns `utime` round trip, and
whether `ctime` advances on write (see 1.4). Timing-dependent properties
stay `source: declared`.

Runs as a ride-along in every existing cell (mount is already up, ~1 s),
uploaded as `features-<slug>.json` beside `result-<slug>`. `publish`
reconciles: unanimity across a backend's cells required; PR -> fail with
diff; master/schedule -> open a PR.

### 2.5 `bin/ci/target-selftest.sh`

New target row, so it runs on every backend. Asserts: `TMPDIR` is under
the mount; `HOME` unchanged unless `--set-home`; `id -u` is the invoker,
not root (except where the row pins `--no-root-squash`); an env var
exported by a prior step survived; a deliberately failing command
propagates its exit status; the mount is writable; teardown ran after.

## 3. act checklist (all **[unverified]** -- no docker daemon here)

Run in the Vagrant VM (`VAGRANT_INSTALL_ACT=1 vagrant provision`), via
`bin/ci/act-selftest.sh`:

1. Does `$GITHUB_ACTION_PATH` resolve correctly for a *local* composite
   action under the current act?
2. Does a multi-line input survive being passed through `env:` on a
   composite step?
3. Does `backend: none` complete end to end with no privileges?
4. Does `loop-ext4` work under `act --privileged` on a host kernel with
   the module -- and is that worth documenting, or a trap?
5. Which `-P` image mapping to pin (starting point:
   `-P ubuntu-22.04=catthehacker/ubuntu:act-22.04`). Note those images
   run as root, so backends take the `SUDO=()` path and no `sudo` binary
   is needed -- convenient, but it means act does *not* exercise the
   privilege-drop path that 1.1 describes. The `selftest` target must
   therefore run for real in GitHub CI, not only under act.

## 4. Decisions taken, with rationale

| Decision | Why |
| --- | --- |
| `run:`-input exec wrapper, not a setup action | Composite actions have no `post:`; the exec-wrapper shape is what `bin/eval-under` already is. |
| Backend **slug** as the public identifier | `backend_slug()` already exists; one matrix key instead of three; artifact/job names align across repos. |
| Logic in `bin/ci/action-*.sh`, not `action.yml` | House rule; buys shellcheck and local testability; also required for act sanity. |
| Inputs via `env:` | Script-injection safety *and* act multi-line quoting. |
| Committed feature table, never a live probe in consumer CI | Nondeterminism imported into dandi/datalad/fscacher CI would be unfixable from those repos. |
| Contract test as a `selftest` **target row** | Every backend tests the action for free; adding a backend extends coverage with no new code. |
| Adoption order fscacher -> datalad -> dandi-cli | Feedback-loop length: 0.86 s vs. multi-hour NFS chunks. |
| act: plumbing only | Honest narrow promise beats a broad one that a container cannot keep. |

## 5. Sequencing

First commit set, chosen because it is what makes everything else
testable:

1. `bin/eval-under-none` (+ `--list` picks it up, README row).
2. `bin/ci/action-run.sh` + `actions/run/action.yml`.
3. `bin/ci/target-selftest.sh` + `selftest` row in `.github/matrix.yaml`
   + regenerated README grid (`bin/ci/gen-readme-matrix.sh`).
4. `actionlint` in CI.

Then: `features:` rows + probe + reconciliation; `actions/list` with
filtering; `bin/ci/act-selftest.sh`; the fscacher snippet in the README;
`v1` tag.

Before each commit: `shellcheck bin/ci/*.sh bin/eval-under*` and
`codespell`.
