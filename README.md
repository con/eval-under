# beegfs-test

Development harness for testing git-annex (and, later, DataLad) under
[BeeGFS](https://www.beegfs.io/), driven from GitHub Actions. Scratch repo
for iteration; the parts destined for upstream get PR'd to their real
homes (see below).

**Why**. A 2024 report of [35+ git-annex test failures on
BeeGFS 7.4.6](https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/)
tracked back to file-descriptor leakage across `rename()` — a class of bug
that BeeGFS's rename semantics expose but ext4/tmpfs/NFS usually mask. We
want ongoing CI coverage on BeeGFS so the next regression of this class
gets caught. Related upstream ask:
[ThinkParQ/beegfs-containers#21](https://github.com/ThinkParQ/beegfs-containers/issues/21).

## Layout

| Path                                     | Purpose                                                                       |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `Vagrantfile` + `provision/`             | Ubuntu 24.04 libvirt VM with docker + BeeGFS client + git-annex               |
| `beegfs/docker-compose-v7.yml`           | BeeGFS v7 test cluster (mgmtd + meta + storage), `network_mode: host`         |
| `beegfs/docker-compose-v8.yml`           | Same, for BeeGFS v8.x (different mgmtd command style / gRPC control plane)    |
| `beegfs/beegfs-client.conf.template`     | Minimal client conf pointing at localhost, no auth                            |
| `beegfs/beegfs-helperd.conf.template`    | Minimal helperd conf (distinct schema from client)                            |
| `tools/eval_under_beegfs`                | Wrapper: bring up cluster, mount, run cmd with `TMPDIR` on BeeGFS             |
| `.github/workflows/beegfs-test.yaml`     | Matrix of BeeGFS versions, runs `git annex test` against con/git-annex daily  |
| `drafts/git-annex-test-beegfs.yaml`      | Copy-target workflow for `datalad/git-annex`                                  |

## Local iteration (VM)

The dev container this repo is usually edited in lacks `CAP_SYS_MODULE`, so
the BeeGFS client kmod cannot be loaded there. Use the Vagrant VM:

```bash
vagrant up                              # first time: ~10 min
vagrant ssh
cd /vagrant

# Smoke:
sudo ./tools/eval_under_beegfs --set-home -- bash -c '
  cd "$HOME"
  git init t && cd t
  git annex init && echo hi > f && git annex add f && git annex fsck
'

# Full run (may find real bugs -- that IS the point):
sudo ./tools/eval_under_beegfs --set-home -- timeout 3600 bash -c 'cd "$HOME" && git annex test'
```

Optional: install `act` in the VM to replay the GitHub workflow locally.

```bash
VAGRANT_INSTALL_ACT=1 vagrant provision
vagrant ssh -c 'cd /vagrant && act -j smoke'
```

`act` runs the workflow in a container, so it can validate the YAML flow
but cannot exercise the BeeGFS kernel module — it's useful for shaking out
workflow bugs, not for actual filesystem testing.

## `eval_under_beegfs` in one paragraph

Mirrors the shape of [`datalad/datalad
tools/eval_under_nfs`](https://github.com/datalad/datalad/blob/maint/tools/eval_under_nfs):
takes a command, wraps setup + teardown around it, and runs the command
with `TMPDIR`, `DATALAD_TESTS_TEMP_DIR` (and optionally `HOME`) pointing
at the BeeGFS mount. Exit code passes through. Teardown runs from a
`trap` on any exit. Use `--keep` to inspect state after a failure.

## Upstream targets

- `tools/eval_under_beegfs` + `beegfs/*` + a copy of
  `drafts/git-annex-test-beegfs.yaml` → PR to
  [datalad/git-annex](https://github.com/datalad/git-annex) once validated,
  either as a new workflow or as a matrix flavor of
  `test-annex` in `build-ubuntu.yaml`.
- Optionally, a slimmed-down smoke workflow → PR to
  [ThinkParQ/beegfs-containers](https://github.com/ThinkParQ/beegfs-containers)
  addressing their [issue #21](https://github.com/ThinkParQ/beegfs-containers/issues/21).

## Requirements (host, for Vagrant)

- libvirt + `vagrant-libvirt` plugin (Debian/Ubuntu:
  `apt install vagrant libvirt-daemon-system` then
  `vagrant plugin install vagrant-libvirt`)
- ~30 GB free disk, ~6 GB free RAM for the VM

Default box is `cloud-image/ubuntu-24.04` (Canonical's official image, has a
libvirt provider). To use virtualbox instead:
`VAGRANT_DEFAULT_PROVIDER=virtualbox vagrant up` — that switches the box to
`bento/ubuntu-24.04` automatically.

## References

- Bug that motivated this: <https://git-annex.branchable.com/bugs/35_failed_tests_on_beegfs/>
- BeeGFS containerisation guidance: <https://doc.beegfs.io/latest/advanced_topics/containers.html>
- BeeGFS CSI driver e2e workflow (client install patterns):
  <https://github.com/ThinkParQ/beegfs-csi-driver/blob/main/.github/workflows/build-test-publish.yaml>
