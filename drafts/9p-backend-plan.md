# Plan: a 9p backend (`bin/eval-under-9p`)

Status: **plan, not yet implemented**. This documents the design and the
sequencing for adding 9p as a matrix row, so the implementation PRs can
be reviewed against something. Move the durable parts (settings tables,
known-red reasoning) into GOTCHAS.md as they land; delete this file when
the last phase lands or is explicitly dropped.

## Why 9p

9p is the filesystem people get, usually without choosing it, whenever a
directory is shared *into* a VM or container boundary:

- **Vagrant + QEMU/libvirt**: `synced_folder ..., type: "9p"` in
  vagrant-libvirt is QEMU's virtio-9p device (`-virtfs local,...`) on
  the host side and the kernel's `v9fs` client (`mount -t 9p -o
  trans=virtio`) on the guest side. This is the concrete case that
  motivates the backend: our own Vagrantfile deliberately avoids 9p for
  syncing ("rsync is more portable than 9p/virtiofs and avoids
  permission surprises") -- those permission surprises are precisely
  what this harness exists to measure rather than avoid.
- **WSL2**: `/mnt/c` and friends are 9p (Microsoft's own server).
- **Chrome OS crostini**, **kata-containers** (pre-virtiofs), various
  lightweight-VM dev environments.

The quirk classes are distinct from anything the current rows cover:
cache-mode staleness (`cache=loose` shows other-writer changes late; the
default no-cache mode makes some mmap patterns impossible), byte-range /
BSD locking that historically returns `ENOLCK` or is faked
server-side, no inotify propagation, ownership semantics that depend on
the *server's* security model rather than the client mount, `msize`
throughput cliffs, no `O_TMPFILE`. git-annex leans on locking, mmap
(via git), and HOME-relative sockets -- a 9p row should light up in
informative ways, per layer, exactly like the vfat row does.

## The shape of the problem

Every existing backend mounts on the host and runs the suite on the
host. The *interesting* 9p deployment splits across a VM boundary: the
server is the QEMU process on the host, the client is `v9fs` in the
guest kernel, and the transport is virtio. Testing "9p as vagrant users
experience it" therefore means running the suite **inside a guest**.
There are two mechanisms worth having, and they share one backend
script:

### Transport `virtio` (primary -- the real vagrant/QEMU stack)

Naively this inverts the harness: targets are installed on the runner
(`install-target.sh` builds into `$EVAL_UNDER_SRC_DIR`), but the suite
would have to run in a guest that has none of that. **virtme-ng**
dissolves the inversion: `vng` boots a QEMU guest whose root filesystem
is a copy-on-write view of the *host's own* root (virtiofs by default,
`--force-9p` as fallback), so runner-installed targets, the git-annex
daily build, `~/.gitconfig`, and the uid/gid layout all exist in the
guest unchanged. The backend then adds its own device for the
filesystem under test:

- host side: a fresh scratch dir exported via
  `-virtfs local,path=$ORIG,mount_tag=eval9p,security_model=<model>,id=eval9p`
  (passed through `vng --qemu-opts`);
- guest side: `mount -t 9p -o trans=virtio,version=9p2000.L[,msize=..][,cache=..]
  eval9p $MNT`, then run the wrapped command with `TMPDIR` /
  `DATALAD_TESTS_TEMP_DIR` / (`HOME` with `--set-home`) pointing at it.

stdout/stderr stream to the job log as usual and `vng` propagates the
wrapped command's exit status (verify this early -- it is
load-bearing for CI redness).

So the backend contract ("run CMD with TMPDIR on the mount") survives
intact; the only novelty is that CMD executes under a different kernel
instance. Writes to host paths *outside* the shared dirs land in the
CoW layer and evaporate -- which is a feature (free cleanup), except
for the git target's `t/test-results/**` that the workflow uploads:
pass `--rwdir "$EVAL_UNDER_SRC_DIR"` so those writes reach the host.

### Transport `tcp` (secondary -- no VM, mirrors `eval-under-nfs`)

`diod` (LLNL's 9P2000.L server; Ubuntu universe: 1.0.24-5 on jammy,
1.0.24-5.1 on noble) exports a fresh scratch dir on `127.0.0.1`, and
the host kernel mounts it:

    diod --foreground --no-auth --listen 127.0.0.1:5640 --export "$ORIG" &
    mount -t 9p -o trans=tcp,port=5640,aname=$ORIG,version=9p2000.L,uname=root,access=user \
        127.0.0.1 "$MNT"

Same architecture as the NFS backend (localhost server + kernel client),
so it drops into the harness with zero conceptual novelty. It exercises
the same `v9fs` client code but a *different server* than QEMU's virtfs
-- different bug surface, cheaper row. It requires the 9p client
modules in the **host** kernel (see risks: azure kernels).

**Recommendation:** implement `virtio` as the deliverable -- it is the
stack the backend exists to represent -- and `tcp` opportunistically;
the script skeleton (scratch dir, teardown trap, env plumbing, option
parsing) is shared, only `start_*`/`mount_*` differ per transport.

## Backend script: `bin/eval-under-9p`

House pattern (`set -eu`, `SUDO` arrays, `trap teardown EXIT`, here-doc
`usage()`, common flags on top). Backend-specific knobs, following the
"distro/kernel defaults on purpose, knobs to deviate" philosophy the
loop backend established:

| Flag | Env var | Default | Purpose |
| --- | --- | --- | --- |
| `--transport {virtio,tcp}` | `EVAL_UNDER_9P_TRANSPORT` | `virtio` | Which of the two stacks above. |
| `--security-model M` | `EVAL_UNDER_9P_SECURITY_MODEL` | `mapped-xattr` | virtio only. QEMU virtfs server model: `mapped-xattr` (ownership/mode faked in xattrs; what vagrant-libvirt `accessmode: "mapped"` gives), `passthrough` (real uids; QEMU must run as root), `none`. |
| `--cache MODE` | `EVAL_UNDER_9P_CACHE` | unset (kernel default) | v9fs client cache mode. Unset = whatever the guest kernel defaults to; a knob because `loose` vs default is the single biggest semantic axis users hit. |
| `--msize BYTES` | `EVAL_UNDER_9P_MSIZE` | unset (kernel default; 128 KiB since 5.15) | Client request size; a throughput knob, occasionally a correctness one. |
| `--kernel VER` | `EVAL_UNDER_9P_KERNEL` | pinned in `.github/matrix.yaml` | virtio only. Guest kernel for `vng --run`. See "pin the guest kernel" below. |
| `--memory MB` / `--cpus N` | `EVAL_UNDER_9P_{MEMORY,CPUS}` | 8192 / nproc | virtio only. Guest sizing; public-repo runners have 4 vCPU / 16 GB. |
| `--port P` | `EVAL_UNDER_9P_PORT` | 5640 | tcp only. Non-privileged, non-564 so nothing collides. |

Mount `version=9p2000.L` is fixed, not a knob: `.u` is legacy and diod
speaks only `.L`.

Semantics to preserve from the existing backends:

- **User identity.** Under `mapped-xattr` the server fabricates
  ownership, so run the wrapped command as the invoking user (NFS-style
  drop) -- that is what a vagrant user's synced folder looks like.
  `needs-root` targets (pjdfstest, stress-ng) run as root *in the
  guest*; under `mapped-xattr` their chown/mknod get absorbed into
  xattr mapping -- measuring that is the point, and GOTCHAS must say so
  before anyone reads those cells as kernel bugs. Under `passthrough`,
  QEMU itself runs as root (we already have `sudo -E` in the workflow).
- **`--keep`.** tcp: leave diod + mount up, as NFS does. virtio: the
  guest is gone when vng exits; keep the *host-side backing dir*
  (readable directly; under `mapped-xattr` the real metadata sits in
  `user.virtfs.*` xattrs) and echo the full `vng` command line so the
  session can be relaunched interactively for poking.
- **Failure diagnostics.** The v9fs client logs to the *guest* dmesg,
  which dies with the VM. Wrap the guest-side command so that on
  non-zero exit it appends `dmesg | tail -50` to a host-visible file
  (under the `--rwdir` or the 9p mount's backing dir), and teach
  `bin/ci/dump-failure-logs.sh` to print it. Same lesson as
  `wait_for_mount_usable()`: make the next red cell diagnosable from
  the job log alone.
- **Mount-usability probe.** Reuse the BeeGFS create+write+read-back
  probe inside the guest right after the mount, before handing over to
  the suite. 9p mounts fail late and weird; a probe converts that into
  an early loud error.

Guest-side execution sketch (virtio), all inside one `vng` invocation
so there is exactly one boot per cell:

    vng --run "$KERNEL" --cpus "$CPUS" --memory "$MEM" \
        --rwdir "$EVAL_UNDER_SRC_DIR" \
        --qemu-opts "-virtfs local,path=$ORIG,mount_tag=eval9p,security_model=$SECMODEL,id=eval9p" \
        -- bin/eval-under-9p --guest-stage2 ...

with `--guest-stage2` (hidden flag) doing: modprobe 9p/9pnet_virtio if
modular, mount, probe, mkdir RUN_HOME, exec the command with the env
trio, capture dmesg on failure. Re-entering the same script keeps the
host/guest halves in one reviewable file.

## Matrix integration

`.github/matrix.yaml` rows -- the `version` slot becomes the variant
token (slug-safe: no slashes, per the `cell_slug()` lesson):

    - backend: 9p
      version: virtio-mapped
      label: "9p virtio (mapped)"
    - backend: 9p
      version: virtio-passthrough
      label: "9p virtio (passthrough)"

Start by landing `virtio-mapped` only (4 new cells); add
`virtio-passthrough` once the first row's failure modes are understood,
and `tcp-diod` if/when the host-module probe says the runners can do it.
`run-under.sh` grows a `9p)` case that splits the version token into
`--transport` / `--security-model` flags, exactly parallel to the
`loop)` case translating `version` into `--fs`.

**Pin the guest kernel.** v9fs client behavior moves significantly
between kernel versions (the 6.6-6.8 cache rework renamed and
re-defaulted the cache modes). An unpinned guest kernel makes a
newly-red cell ambiguous in exactly the way the pinned `refs:` exist to
prevent -- so add e.g. `refs: { 9p-kernel: "6.8" }` and have the
backend default `--kernel` from it (`vng --run <version>` fetches a
prebuilt kernel; the host's running kernel remains an explicit opt-in
via `--kernel host`). Bump deliberately, and expect GOTCHAS entries to
be keyed to it.

**Per-row `runs-on`.** The `test` job is currently hard-coded to
ubuntu-22.04 for BeeGFS-DKMS reasons that do not bind the 9p rows, and
ubuntu-24.04 is a materially better host here: `virtme-ng` (1.22-1) and
rust `virtiofsd` are packaged, QEMU is 8.2, and the stock kernel is
newer. Add an optional `runs-on:` key per backend row (default
ubuntu-22.04), emit it from `matrix-json.sh`, and set
`runs-on: ${{ matrix.runs-on }}` in the workflow. Contained change,
keeps the BeeGFS rows untouched, and removes the need to pip-install
virtme-ng on jammy.

`bin/ci/install-backend.sh` gains `install_9p()`:

- `apt_install qemu-system-x86 qemu-utils virtme-ng` (24.04; on 22.04
  fall back to `pipx install virtme-ng`), plus `diod` when the tcp
  variant lands;
- best-effort `apt_install linux-modules-extra-$(uname -r)` --
  required for tcp host mounts and for `--kernel host` guests; known
  to transiently fail when the archive lags the runner image
  (actions/runner-images#8080), so don't hard-fail the virtio path on
  it;
- KVM enablement: the standard udev rule
  (`KERNEL=="kvm", GROUP="kvm", MODE="0666"` + udevadm reload/trigger).
  Since `run-under.sh` runs under `sudo -E` this is belt-and-braces;
  still verify `/dev/kvm` exists and warn loudly when falling back to
  TCG (a TCG git-annex run will blow the 2400 s budget -- treat TCG as
  boot-smoke only, and let the cell fail fast with a clear message
  rather than time out mutely).

Timeouts: reuse the per-target values initially; virtio adds ~10-20 s
of boot, and 9p latency sits between ext4 and sync-NFS. Adjust from
evidence, not in advance.

Rest of the standard checklist from "Adding a new backend" in the
README: `gen-readme-matrix.sh` regeneration, GOTCHAS "Backend settings"
section (mount options, security model, msize/cache defaults *as
measured*, guest kernel), README file-layout row, and
`shellcheck bin/ci/*.sh bin/eval-under*`. New files need no SPDX
headers (`bin/**`, `drafts/**`, `provision/**` are covered by
REUSE.toml's aggregate block).

## Vagrant / local iteration

- `provision/setup.sh`: add `qemu-system-x86 qemu-utils virtme-ng diod`
  and `linux-modules-extra-$(uname -r)` (the cloud image's `-virtual`
  kernel keeps 9p client modules there). Nested KVM already works: the
  Vagrantfile sets `lv.nested = true` + `cpu_mode = "host-passthrough"`,
  so `vng` inside the VM is hardware-accelerated.
- Vagrantfile, opt-in cross-check share: behind an env guard (say
  `VAGRANT_9P_SHARE=1`), add a *second* synced folder of
  `type: "9p"` at `/vagrant-9p` -- the genuine vagrant-libvirt article,
  for validating that `eval-under-9p --transport virtio` reproduces the
  semantics of the real thing (compare a pjdfstest run on both). The
  default stays rsync; the existing comment explaining why remains
  true for the *repo* share. Confirm vagrant-libvirt's current
  `accessmode` default and owner/group options at implementation time
  (docs were unreachable from the drafting environment).

Local usage after landing:

    sudo bin/eval-under 9p --set-home -- bash -c 'cd "$HOME" && git annex test'
    sudo bin/eval-under 9p --transport tcp --set-home -- git annex test
    sudo bin/eval-under 9p --cache loose -- ...      # the classic vagrant foot-gun
    sudo -E bin/ci/run-under.sh 9p virtio-mapped pjdfstest

## Phase 0: a probe, before any backend code

One `workflow_dispatch` job (script in `bin/ci/`, per house rules --
e.g. `bin/ci/probe-9p.sh`, kept afterwards as a doctor script), run on
both ubuntu-22.04 and ubuntu-24.04, reporting:

1. `/dev/kvm` presence and usability (as root and as the runner user
   with the udev rule);
2. whether `linux-modules-extra-$(uname -r)` installs, and whether
   `modprobe 9p 9pnet 9pnet_tcp 9pnet_virtio` then succeeds on the
   azure kernel (decides the tcp row's CI fate; the answer is genuinely
   unknown -- packages.ubuntu.com contents search draws a blank);
3. `vng --run <pinned> -- uname -a` boot smoke + a 5-line 9p
   mount-and-touch inside the guest, and confirmation that a non-zero
   guest exit propagates to the host.

This converts every open risk below into a fact for the cost of one CI
run, before the backend script exists.

## Risks and open questions

| Risk | Exposure | Mitigation |
| --- | --- | --- |
| Azure kernel lacks 9p client modules | tcp row on hosted runners only | Probe decides; virtio row is immune (pinned `vng` kernel ships its own modules); tcp stays available locally/VM regardless. |
| `modules-extra` transiently uninstallable (runner image vs archive lag) | tcp row, `--kernel host` | Best-effort install; virtio row does not depend on it. |
| KVM on standard runners is unofficial | whole virtio row | Works today (udev rule; root via `sudo` regardless); probe verifies per-image; TCG fallback = fail fast with a clear message. |
| `vng` exit-status / stdout plumbing quirks | CI signal integrity | Verified explicitly in Phase 0 item 3. |
| virtiofsd availability for the vng *root* on jammy | only if 9p rows stay on ubuntu-22.04 | Prefer per-row `runs-on: ubuntu-24.04`; `vng --force-9p` for the rootfs is the fallback (slower, and amusingly turns even `/usr` into 9p). |
| Suite behavior differs guest-vs-host for non-fs reasons (loopback services, sockets) | git-annex target mostly | `git annex test` is local-only; add `--net user` to vng only if a target proves to need it. |

## Sequencing

1. **PR 1 -- probe.** `bin/ci/probe-9p.sh` + a tiny dispatch workflow;
   record findings in the PR, then wire the answers into this plan.
2. **PR 2 -- the backend.** `bin/eval-under-9p` (virtio transport,
   `mapped-xattr`), `9p)` cases in `run-under.sh` +
   `install-backend.sh`, per-row `runs-on`, `9p-kernel` ref,
   matrix row `virtio-mapped`, GOTCHAS settings section, README regen,
   provision additions, `dump-failure-logs.sh` 9p case.
3. **PR 3 -- variants.** `virtio-passthrough` row; `tcp-diod` row if
   the probe cleared it; Vagrantfile opt-in 9p share for
   cross-validation.
4. **Later, own decisions:** `cache=loose` and msize variant rows
   (GOTCHAS "Not yet covered" until then), and a sibling
   `eval-under-virtiofs` backend -- the designated successor to 9p in
   the same vagrant/QEMU role, nearly free once the vng plumbing
   exists, and the natural control row for "is this 9p, or is this
   any-VM-shared-fs?".
