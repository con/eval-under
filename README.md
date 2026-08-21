# eval-under

Reproducible test harness for running arbitrary commands under a
temporarily-mounted filesystem. Purpose-built for catching
filesystem-specific behaviour bugs (rename semantics, close-on-exec,
timestamp granularity, locking, permissions, adjusted-branch fallbacks,
`root_squash` interactions) in tools like git-annex, DataLad, and
rsync -- classes of bugs that don't show up in plain-ext4 CI.

git-annex is the immediate demo target: this repo runs the full
`git annex test` suite against every backend on every push. The harness
itself is backend-agnostic -- new backends are dropped in as
`bin/eval-under-<name>` scripts (see below).

## CI status

| Backend             | Status                                                                                                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BeeGFS 7.4.6        | [![BeeGFS 7.4.6](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-beegfs-7.4.6.yaml/badge.svg)](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-beegfs-7.4.6.yaml)                 |
| BeeGFS 8.1.0        | [![BeeGFS 8.1.0](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-beegfs-8.1.0.yaml/badge.svg)](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-beegfs-8.1.0.yaml)                 |
| NFS (localhost)     | [![NFS](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-nfs.yaml/badge.svg)](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-nfs.yaml)                                            |
| Loop vfat           | [![Loop vfat](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-loop-vfat.yaml/badge.svg)](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-loop-vfat.yaml)                          |
| Loop ext4           | [![Loop ext4](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-loop-ext4.yaml/badge.svg)](https://github.com/yarikoptic/beegfs-test/actions/workflows/test-loop-ext4.yaml)                          |

Each row runs the **full `git annex test`** against a fresh daily build
from [con/git-annex](https://github.com/con/git-annex).

## Motivation

A 2024 report of [35+ git-annex test failures on
BeeGFS 7.4.6](https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/)
tracked back to a rename-semantics quirk that BeeGFS exposes but
ext4/tmpfs usually mask. That's not a new class of story: DataLad's CI
has for years included NFS and vfat-loop flavours precisely because
those filesystems break git-annex assumptions in ways plain ext4
doesn't ([`eval_under_nfs`](https://github.com/datalad/datalad/blob/maint/tools/eval_under_nfs),
[`eval_under_testloopfs`](https://github.com/datalad/datalad/blob/maint/tools/eval_under_testloopfs)).

This repo consolidates and generalises that pattern: one dispatcher
(`bin/eval-under`), one reusable CI workflow (`_test-under.yaml`), and
a small backend script per filesystem. New filesystems slot in
uniformly; the git-annex-under-BeeGFS coverage that motivated the repo
is now just one of several dispatcher workflows.

## CLI usage

```bash
# git-annex smoke under BeeGFS 7.4.6, HOME on the mount
sudo bin/eval-under beegfs --set-home -- bash -c '
  cd "$HOME" && git init t && cd t && git annex init && git annex test
'

# Same, under a 200 MB xfs loop
sudo bin/eval-under loop --fs xfs --size 200 --set-home -- \
  bash -c 'cd "$HOME" && git annex test'

# Under a localhost NFS export (async by default; --sync to reproduce
# the fsync-heavy slow path)
sudo bin/eval-under nfs --set-home -- bash -c 'cd "$HOME" && git annex test'

# Skip teardown to poke around after a failure
sudo bin/eval-under beegfs --set-home --keep -- some-failing-command

# Discover backends / read backend help
bin/eval-under --list
bin/eval-under nfs --help
```

All backends accept `--mount-point`, `--set-home`, `--keep`, and their
own backend-specific options. See `bin/eval-under BACKEND --help` for
the full flag / env-var / default table per backend.

## File layout

| Path                                     | Purpose                                                                       |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `Vagrantfile` + `provision/`             | Ubuntu 24.04 libvirt VM with docker + BeeGFS + NFS + loop deps + git-annex    |
| `bin/eval-under`                         | Dispatcher: routes to `bin/eval-under-<backend>`                              |
| `bin/eval-under-beegfs`                  | BeeGFS backend (containerised cluster + kernel client mount)                  |
| `bin/eval-under-nfs`                     | NFS backend (localhost loopback export)                                       |
| `bin/eval-under-loop`                    | Loop-device backend (dd + losetup + mkfs.<fs> + mount)                        |
| `fixtures/beegfs/docker-compose-v7.yml`  | BeeGFS v7 test cluster (mgmtd + meta + storage), `network_mode: host`         |
| `fixtures/beegfs/docker-compose-v8.yml`  | Same, for BeeGFS v8.x (different mgmtd command style / gRPC control plane)    |
| `fixtures/beegfs/beegfs-*.conf.template` | Minimal client + helperd confs for the throwaway cluster                      |
| `.github/workflows/_test-under.yaml`     | Reusable workflow parameterised on `backend` + `backend-version`              |
| `.github/workflows/test-*.yaml`          | Per-flavour dispatchers (one badge each)                                      |
| `drafts/git-annex-test-beegfs.yaml`      | Copy-target workflow for `con/git-annex` (external PR target)             |

## Local iteration (VM)

The dev container this repo is usually edited in lacks `CAP_SYS_MODULE`
(no BeeGFS kmod) and doesn't run its own NFS server. Use the Vagrant VM:

```bash
vagrant up                              # first time: ~10 min
vagrant ssh
cd /vagrant

# Iterate on any backend:
sudo bin/eval-under beegfs --set-home -- bash -c '
  cd "$HOME" && git init t && cd t && git annex init && git annex fsck
'
sudo bin/eval-under nfs    --set-home -- git annex test
sudo bin/eval-under loop --fs vfat --set-home -- git annex test
```

Optional: install `act` in the VM to replay the GitHub workflow locally.

```bash
VAGRANT_INSTALL_ACT=1 vagrant provision
vagrant ssh -c 'cd /vagrant && act -j test'
```

`act` runs the workflow in a container, so it can validate the YAML
flow but cannot exercise the BeeGFS kernel module or the host's NFS
server -- useful for shaking out workflow bugs, not for actual
filesystem testing.

## Adding a new backend

1. Drop `bin/eval-under-<newbackend>` next to the existing backends.
   It's picked up automatically by `bin/eval-under --list`.
2. Follow the pattern: `set -eu`, `${SUDO[@]}` arrays for root, `trap
   teardown EXIT`, a here-doc'd `usage()`, `EVAL_UNDER_<BACKEND>_*` env
   vars for backend-specific options, and the common
   `--mount-point` / `--set-home` / `--keep` flags on top.
3. At the end, run the wrapped command with `TMPDIR`,
   `DATALAD_TESTS_TEMP_DIR`, and (if `--set-home`) `HOME` pointing at
   the mount.
4. Add a `.github/workflows/test-<newbackend>.yaml` dispatcher and a
   row to the CI badge table above.
5. Update `provision/setup.sh` if the backend needs new host packages.

## Upstream targets

- `bin/eval-under-beegfs` + `fixtures/beegfs/*` + a copy of
  `drafts/git-annex-test-beegfs.yaml` -> PR to
  [con/git-annex](https://github.com/con/git-annex) once
  validated, either as a new workflow or as a matrix flavour of
  `test-annex` in `build-ubuntu.yaml`.
- Optionally, a slimmed-down smoke workflow -> PR to
  [ThinkParQ/beegfs-containers](https://github.com/ThinkParQ/beegfs-containers)
  addressing their [issue #21](https://github.com/ThinkParQ/beegfs-containers/issues/21).

## Requirements (host, for Vagrant)

- libvirt + `vagrant-libvirt` plugin (Debian/Ubuntu:
  `apt install vagrant libvirt-daemon-system` then
  `vagrant plugin install vagrant-libvirt`)
- ~30 GB free disk, ~6 GB free RAM for the VM

Default box is `cloud-image/ubuntu-24.04` (Canonical's official image,
has a libvirt provider). To use virtualbox instead:
`VAGRANT_DEFAULT_PROVIDER=virtualbox vagrant up` -- that switches the
box to `bento/ubuntu-24.04` automatically.

## Licensing

Machine-readable per the [REUSE specification](https://reuse.software/):

- License texts live in `LICENSES/` (MIT for project-native files,
  Apache-2.0 for the ThinkParQ-derived BeeGFS Docker Compose fixtures).
- Path-to-license mappings live in `REUSE.toml`.
- Absorbed files preserve upstream attribution: `bin/eval-under-nfs`
  and `bin/eval-under-loop` credit the DataLad developers (MIT);
  `fixtures/beegfs/docker-compose-v{7,8}.yml` credit ThinkParQ GmbH
  (Apache-2.0).
- Validate with `uvx --from reuse reuse lint` (or `pip install reuse &&
  reuse lint`). This project ships 100% REUSE-compliant.

New files contributed to this repo don't need per-file SPDX headers;
they are covered by the `REUSE.toml` catchall block. Add per-file
headers (or an additional `[[annotations]]` block) only if the file
carries a different license or additional attribution.

## References

- Bug that motivated the BeeGFS coverage:
  <https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/>
- Datalad's original per-filesystem wrappers:
  [`tools/eval_under_nfs`](https://github.com/datalad/datalad/blob/maint/tools/eval_under_nfs),
  [`tools/eval_under_testloopfs`](https://github.com/datalad/datalad/blob/maint/tools/eval_under_testloopfs)
- BeeGFS containerisation guidance:
  <https://doc.beegfs.io/latest/advanced_topics/containers.html>
- BeeGFS CSI driver e2e workflow (client install patterns):
  <https://github.com/ThinkParQ/beegfs-csi-driver/blob/main/.github/workflows/build-test-publish.yaml>
