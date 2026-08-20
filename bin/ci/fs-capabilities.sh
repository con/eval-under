#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Report the POSIX-ish capabilities of a directory's filesystem, in the
# specific dimensions that git-annex / DataLad are known to trip over.
#
# Every check here corresponds to a real reported failure -- see
# FILESYSTEMS.md for the issue each one maps to. The point is that
# a capability profile is orders of magnitude cheaper than `git annex
# test` and usually explains its result:
#
#   sqlite-wal=no       -> "SQLite3 returned ErrorIO" (Lustre, WSL, CIFS)
#   fcntl-lock=no       -> git-annex falls back to annex.pidlock (NFS)
#   link-eexist=no      -> pidlock is unsafe: two files, one name (Lustre)
#   symlink=no          -> crippled filesystem, adjusted branch (vfat)
#   hardlink-same-inode=no -> "failed to link to annex" (sshfs): link()
#                          works but the link is not observable as one
#   exec-bit=no         -> vfat/ntfs: every file looks executable
#
# usage:
#   bin/ci/fs-capabilities.sh [DIR]
#
#   DIR   directory to probe (default: $EVAL_UNDER_MOUNT, else $TMPDIR,
#         else the current directory)
#
# Output is one `key=value` per line on stdout, plus a human-readable
# `fstype`/`mount` header on stderr. Always exits 0 unless DIR is
# unusable: an unsupported feature is a finding, not an error.

set -uo pipefail

DIR="${1:-${EVAL_UNDER_MOUNT:-${TMPDIR:-.}}}"

[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 2; }

work="$(mktemp -d "$DIR/fscaps-XXXXXX")" || {
    echo "cannot create a working directory under $DIR" >&2; exit 2; }
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

say() { printf '%s=%s\n' "$1" "$2"; }

# Run a check in a subshell; "yes" if it exits 0, "no" otherwise. Output
# is swallowed -- the verdict is the value.
check() {
    local key="$1"; shift
    if ( "$@" ) >/dev/null 2>&1; then say "$key" yes; else say "$key" no; fi
}

{
    echo "dir: $DIR"
    echo "fstype: $(stat -f -c %T "$DIR" 2>/dev/null || echo unknown)"
    findmnt -n -o SOURCE,FSTYPE,OPTIONS --target "$DIR" 2>/dev/null || true
} >&2

say fstype "$(stat -f -c %T "$DIR" 2>/dev/null || echo unknown)"

c_symlink() { ln -s target "$work/sl" && [ -L "$work/sl" ]; }
c_hardlink() { : > "$work/hl-a" && ln "$work/hl-a" "$work/hl-b"; }

# `ln` succeeding is not the same as the link being observable. sshfs
# creates the link over SFTP but reports a distinct inode and nlink=1 for
# each name -- so the two names are indistinguishable from two copies.
# git-annex's add (adjusted unlocked branch) hardlinks the file into
# .git/annex/objects and then verifies it, and git's own local clone does
# the same check, so both fail on such a filesystem while `ln` looks fine.
# These two checks are what predict that, and c_hardlink alone does not.
c_hardlink_same_inode() {
    : > "$work/hli-a" && ln "$work/hli-a" "$work/hli-b" || return 1
    local ia ib
    ia="$(stat -c %i "$work/hli-a")" && ib="$(stat -c %i "$work/hli-b")" || return 1
    [ "$ia" = "$ib" ]
}
c_hardlink_nlink() {
    : > "$work/hln-a" && ln "$work/hln-a" "$work/hln-b" || return 1
    [ "$(stat -c %h "$work/hln-a")" = 2 ]
}
c_fifo() { mkfifo "$work/fifo"; }
c_unix_socket() { python3 -c '
import socket, sys, os
s = socket.socket(socket.AF_UNIX)
s.bind(os.path.join(sys.argv[1], "sock"))
' "$work"; }

# vfat & friends: mode bits are synthesised from mount options, so a
# freshly-created 0644 file reads back as executable and chmod is a no-op.
c_exec_bit() {
    : > "$work/x"; chmod 644 "$work/x"; [ ! -x "$work/x" ] || return 1
    chmod 755 "$work/x"; [ -x "$work/x" ]
}
c_perm_bits() {
    : > "$work/p"; chmod 600 "$work/p"
    [ "$(stat -c %a "$work/p")" = "600" ]
}

# POSIX: link() must fail with EEXIST if newpath exists. Lustre has been
# observed to succeed here and end up with two directory entries of the
# same name -- which is what makes annex.pidlock unsafe on it.
c_link_eexist() {
    : > "$work/le-a"; : > "$work/le-b"
    ! ln "$work/le-a" "$work/le-b" 2>/dev/null
}
c_rename_over() {
    echo a > "$work/ro-a"; echo b > "$work/ro-b"
    mv -f "$work/ro-a" "$work/ro-b" && [ "$(cat "$work/ro-b")" = a ]
}
# Deleting an open file: NFS silly-renames it (.nfsXXXX), most local
# filesystems just unlink it.
c_unlink_open() { python3 -c '
import os, sys
p = os.path.join(sys.argv[1], "uo")
fh = open(p, "w")
os.unlink(p)
fh.write("still writable")
fh.close()
sys.exit(0 if not os.path.exists(p) else 1)
' "$work"; }

c_fcntl_lock() { python3 -c '
import fcntl, os, sys
fh = open(os.path.join(sys.argv[1], "fl"), "w")
fcntl.lockf(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
fcntl.lockf(fh, fcntl.LOCK_UN)
' "$work"; }
c_flock() { python3 -c '
import fcntl, os, sys
fh = open(os.path.join(sys.argv[1], "fk"), "w")
fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
fcntl.flock(fh, fcntl.LOCK_UN)
' "$work"; }

# The single most predictive check for git-annex: its keys database is
# SQLite in WAL mode, and WAL needs shared memory + byte-range locks.
c_sqlite_wal() { python3 -c '
import os, sqlite3, sys
db = os.path.join(sys.argv[1], "wal.db")
con = sqlite3.connect(db)
mode = con.execute("PRAGMA journal_mode=WAL;").fetchone()[0]
if mode.lower() != "wal":
    sys.exit(1)
con.execute("CREATE TABLE t (a int);")
con.execute("INSERT INTO t VALUES (1);")
con.commit()
con.close()
sqlite3.connect(db).execute("SELECT * FROM t;").fetchall()
' "$work"; }
c_sqlite_delete_mode() { python3 -c '
import os, sqlite3, sys
con = sqlite3.connect(os.path.join(sys.argv[1], "del.db"))
con.execute("PRAGMA journal_mode=DELETE;")
con.execute("CREATE TABLE t (a int);")
con.execute("INSERT INTO t VALUES (1);")
con.commit()
' "$work"; }

c_xattr_user() { python3 -c '
import os, sys
p = os.path.join(sys.argv[1], "xa")
open(p, "w").close()
os.setxattr(p, "user.eval_under", b"1")
os.getxattr(p, "user.eval_under")
' "$work"; }
c_chown() { : > "$work/co" && chown 1:1 "$work/co"; }
c_case_sensitive() {
    : > "$work/CaseA"; [ ! -e "$work/casea" ]
}
c_long_name() { : > "$work/$(printf 'n%.0s' $(seq 1 255))"; }
# git-annex writes keys containing characters some filesystems reject.
c_special_chars() { : > "$work/a:b*c?d"; }
c_trailing_space() { : > "$work/trailing "; }

check symlink            c_symlink
check hardlink           c_hardlink
check hardlink-same-inode c_hardlink_same_inode
check hardlink-nlink     c_hardlink_nlink
check fifo               c_fifo
check unix-socket        c_unix_socket
check exec-bit           c_exec_bit
check perm-bits          c_perm_bits
check link-eexist        c_link_eexist
check rename-over        c_rename_over
check unlink-open        c_unlink_open
check fcntl-lock         c_fcntl_lock
check flock              c_flock
check sqlite-wal         c_sqlite_wal
check sqlite-delete-mode c_sqlite_delete_mode
check xattr-user         c_xattr_user
if [ "$(id -u)" = 0 ]; then
    check chown c_chown
else
    # chown(2) is restricted to root regardless of the filesystem, so a
    # "no" here would say nothing about the filesystem.
    say chown "n/a-not-root"
fi
check case-sensitive     c_case_sensitive
check long-name-255      c_long_name
check special-chars      c_special_chars
check trailing-space     c_trailing_space

# Timestamp granularity: how many distinct mtimes we see across rapid
# writes. vfat rounds to 2s, which is enough to hide a modification from
# a stat-based dirty check.
mtimes="$(for i in 1 2 3 4 5; do
    : > "$work/ts$i"
    stat -c %.9Y "$work/ts$i" 2>/dev/null || stat -c %Y "$work/ts$i"
    sleep 0.05
done | sort -u | wc -l)"
say mtime-distinct-of-5 "$mtimes"

df -P -k "$DIR" | awk 'NR==2 {print "free-kb=" $4}'
