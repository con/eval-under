#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Minimal reproducer for the git-annex "failed to link to annex" /
# "unlock failed" flake seen on NFS (con/git-annex#293).
#
# git-annex's Annex/Content.hs:linkAnnex stats the source file, copies it,
# then stats it again and compares the two InodeCaches with compareStrong,
# i.e. exact equality of (inode, size, high-resolution mtime).  If they
# differ it assumes the file changed under it, deletes the destination and
# fails.  On NFS the two stats of an *unmodified* file can disagree in the
# mtime, which is what this script measures -- no git-annex needed.
#
# Run it on the filesystem under test:
#
#     ./nfs-mtime-stability.py -n 200            # in cwd
#     ./nfs-mtime-stability.py -n 200 -j 8       # under parallel load
#     ./nfs-mtime-stability.py -n 50 --delay 5   # let the attribute cache age
#
# Exits non-zero if any mismatch was observed, so it can be used as a check.

from __future__ import annotations

import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class InodeCache:
    """What git-annex stores and compares (Utility/InodeCache.hs)."""

    inode: int
    size: int
    mtime_ns: int

    @classmethod
    def of(cls, path: str) -> "InodeCache":
        # git-annex uses lstat (getSymbolicLinkStatus) + modificationTimeHiRes
        st = os.lstat(path)
        return cls(st.st_ino, st.st_size, st.st_mtime_ns)

    def show(self) -> str:
        # same field order git-annex's showInodeCache prints:
        # "<inode> <size> <seconds> <nanoseconds>"
        return f"{self.inode} {self.size} {self.mtime_ns // 10**9} {self.mtime_ns % 10**9}"


def compare_strong(a: InodeCache, b: InodeCache) -> bool:
    return a == b


def differing_fields(a: InodeCache, b: InodeCache) -> list[str]:
    out = []
    if a.inode != b.inode:
        out.append("inode")
    if a.size != b.size:
        out.append("size")
    if a.mtime_ns != b.mtime_ns:
        out.append("mtime")
    return out


def copy_like_git_annex(src: str, dest: str) -> None:
    """Utility/CopyFile.hs:copyFileExternal CopyAllMetaData."""
    subprocess.run(
        ["cp", "--reflink=auto", "-a", "--no-preserve=xattr", src, dest],
        check=True,
        capture_output=True,
    )


@dataclass
class Mismatch:
    phase: str
    path: str
    before: InodeCache
    after: InodeCache

    def describe(self) -> str:
        fields = "+".join(differing_fields(self.before, self.after))
        delta_ns = self.after.mtime_ns - self.before.mtime_ns
        return (
            f"  [{self.phase}] {self.path}: {fields} changed; "
            f"before: {self.before.show()}; after: {self.after.show()}"
            f"  (mtime delta {delta_ns / 1e9:+.9f}s)"
        )


def one_round(workdir: str, index: int, size: int, delay: float, do_copy: bool) -> list[Mismatch]:
    """Write a file, stat it, copy it (as git-annex does), stat it again."""
    src = os.path.join(workdir, f"src-{index}")
    dest = os.path.join(workdir, f"dest-{index}")
    with open(src, "wb") as fh:
        fh.write(os.urandom(size))
        # NFS flushes on close; git-annex's callers see the file after close too.

    if delay:
        time.sleep(delay)

    before = InodeCache.of(src)

    if do_copy:
        copy_like_git_annex(src, dest)
    else:
        # control: same wait, no copy, to tell "the copy revalidates" from
        # "the attribute cache expires on its own"
        time.sleep(0.05)

    after = InodeCache.of(src)

    found = []
    if not compare_strong(before, after):
        found.append(
            Mismatch("copy" if do_copy else "no-copy", os.path.relpath(src, workdir), before, after)
        )

    for f in (src, dest):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    return found


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-d", "--dir", default=".", help="directory on the filesystem under test (default: cwd)")
    p.add_argument("-n", "--rounds", type=int, default=200, help="rounds per worker (default: 200)")
    p.add_argument("-j", "--jobs", type=int, default=1, help="concurrent workers (default: 1)")
    p.add_argument("-s", "--size", type=int, default=16, help="file size in bytes (default: 16)")
    p.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="seconds to wait between writing and the first stat; >3 exceeds the "
        "default acregmin, >60 the default acregmax",
    )
    p.add_argument("--no-copy", action="store_true", help="control run: stat twice without copying")
    p.add_argument("--quiet", action="store_true", help="only print the summary")
    args = p.parse_args()

    root = os.path.abspath(args.dir)
    os.makedirs(root, exist_ok=True)
    workroot = tempfile.mkdtemp(prefix="mtime-stability-", dir=root)

    fsinfo = subprocess.run(
        ["findmnt", "-no", "FSTYPE,OPTIONS", "--target", root],
        capture_output=True,
        text=True,
    ).stdout.strip()
    print(f"# directory: {root}")
    print(f"# mount:     {fsinfo or '(findmnt unavailable)'}")
    print(
        f"# plan:      {args.jobs} worker(s) x {args.rounds} rounds, {args.size}B files, "
        f"delay={args.delay}s, {'no copy (control)' if args.no_copy else 'copy via cp'}"
    )

    started = time.time()
    mismatches: list[Mismatch] = []
    try:
        def worker(wid: int) -> list[Mismatch]:
            wdir = os.path.join(workroot, f"w{wid}")
            os.makedirs(wdir, exist_ok=True)
            found = []
            for i in range(args.rounds):
                found.extend(one_round(wdir, i, args.size, args.delay, not args.no_copy))
            return found

        if args.jobs > 1:
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                for res in pool.map(worker, range(args.jobs)):
                    mismatches.extend(res)
        else:
            mismatches.extend(worker(0))
    finally:
        shutil.rmtree(workroot, ignore_errors=True)

    total = args.jobs * args.rounds
    elapsed = time.time() - started
    if mismatches and not args.quiet:
        print(f"\n# mismatches ({len(mismatches)}):")
        for m in mismatches:
            print(m.describe())

    rate = 100.0 * len(mismatches) / total if total else 0.0
    print(
        f"\n{len(mismatches)}/{total} rounds saw the inode cache change under an "
        f"unmodified file ({rate:.2f}%), in {elapsed:.1f}s"
    )
    if mismatches:
        worst = max(abs(m.after.mtime_ns - m.before.mtime_ns) for m in mismatches)
        print(f"largest mtime jump: {worst / 1e9:.9f}s")
        print("This is what makes git-annex report 'failed to link to annex' / 'unlock failed'.")
        return 1
    print("No mismatch seen: compareStrong would have held for every round.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
