#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# git-annex-level reproducer for the NFS LinkAnnexFailed flake
# (con/git-annex#293): loops the two operations that go through
# Annex/Content.hs:linkAnnex and counts how often they fail.
#
#   unlock      (default)  git annex add + git annex unlock
#                          -> linkFromAnnex', the "unlock failed" case
#   add-unlocked           git -c annex.addunlocked=true annex add
#                          -> linkToAnnex, the "failed to link to annex" case
#
# Run it with cwd on the filesystem under test; it creates its own repos.
# Minutes rather than the ~20 that a full `git annex test` takes, and it
# reports a rate instead of a single pass/fail.
#
# usage:
#   linkannex-loop.sh [-n ROUNDS] [-j WORKERS] [-m MODE] [-d DIR] [--report FILE]
#
# --report writes "<failures>\t<total>" to FILE, so a caller can turn the
# result into TAP without parsing this script's prose.
#
# exit status:
#   0  every round linked cleanly
#   1  some rounds failed in linkAnnex -- the finding this looks for
#   2  bad usage
#   3  the harness could not run (repo setup, a worker that vanished)
#   4  the filesystem filled up, so the run measures free space rather
#      than linkAnnex; the rate is withheld deliberately

set -u -o pipefail

ROUNDS=200
WORKERS=1
MODE=unlock
DIR=.
REPORT=

usage() { sed -n '3,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--rounds)  ROUNDS="$2"; shift 2 ;;
    -j|--workers) WORKERS="$2"; shift 2 ;;
    -m|--mode)    MODE="$2"; shift 2 ;;
    -d|--dir)     DIR="$2"; shift 2 ;;
    --report)     REPORT="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  unlock|add-unlocked) ;;
  *) echo "unknown mode: $MODE (expected unlock or add-unlocked)" >&2; exit 2 ;;
esac

command -v git-annex >/dev/null 2>&1 || command -v git >/dev/null 2>&1 || {
  echo "git-annex not found in PATH" >&2; exit 3; }

mkdir -p "$DIR"
root="$(cd "$DIR" && pwd)"
work="$(mktemp -d "$root/linkannex-loop-XXXXXX")"

# git-annex makes each object's directory read-only (dr-xr-xr-x), and
# nothing can unlink through a directory it cannot write. As root that is
# invisible; under a root-squashed NFS export it is not, and a plain
# `rm -rf` then printed a screenful of "Permission denied" into the cell
# log -- burying the TAP output of a target whose only job is to be read
# -- and left the probe repos on the mount for the next mode's rounds to
# squeeze past. Make them writable first, as git-annex's own test suite
# does.
cleanup() {
  chmod -R u+w "$work" 2>/dev/null || :
  rm -rf "$work"
}
trap cleanup EXIT

echo "# dir:     $root"
echo "# mount:   $(findmnt -no FSTYPE,OPTIONS --target "$root" 2>/dev/null || echo '(findmnt unavailable)')"
echo "# version: $(git annex version --raw 2>/dev/null || echo unknown)"
echo "# plan:    $WORKERS worker(s) x $ROUNDS rounds, mode=$MODE"

# A full filesystem produces the very same "failed to link to annex" /
# "unlock failed" lines as the inode-cache mismatch this loop exists to
# measure -- git-annex reports both as a failure to link. Counting them
# would report a filesystem that merely ran out of room as a 100%
# linkAnnex failure rate, which is exactly what a 100MB loop image did
# on ext4 (con/eval-under#11): 800/800 "failures", none of them real.
# So they abort the run instead of being tallied.
is_space_failure() {
  case "$1" in
    *"not enough free space"*|*"No space left on device"*|*"no space left on device"*)
      return 0 ;;
  esac
  return 1
}

# Called from a worker on a space failure: mark it, so the aggregation
# below can refuse to report a rate, and stop this worker.
abort_no_space() {
  printf 'worker %s round %s: OUT OF SPACE -- not a linkAnnex failure, aborting\n%s\n' \
    "$1" "$2" "$3" >&2
  : > "$work/nospace.$1"
}

# Each worker gets its own repo, the way `git annex test` runs its parts.
run_worker() {
  # Note: `local a=$1 b=$a` would expand $a before the assignment happens,
  # which trips `set -u`; keep the dependent ones on their own lines.
  local wid="$1"
  local repo="$work/w$wid"
  local failures=0 i out
  mkdir -p "$repo"
  (
    cd "$repo" || exit 3
    git init -q . 2>/dev/null
    git config user.email test@example.com
    git config user.name "NFS Probe"
    git annex init -q "probe-$wid" >/dev/null 2>&1
    # This loop measures the inode-cache comparison, not git-annex's
    # disk-space policy. Measured on a fresh ext4 image with 83MB free:
    # `git annex unlock` of a 14-byte file still refuses, with "not
    # enough free space, need 13.73 MB more" -- so it wanted ~97MB free
    # to rewrite 14 bytes, and on a small backing image every round
    # fails before linkAnnex is ever reached. (Whatever computes that
    # figure, it is far above the 1MB annex.diskreserve is documented to
    # default to; not investigated further, since this loop has no
    # business enforcing a reserve at all.) Genuine ENOSPC is still
    # caught -- see is_space_failure.
    git config annex.diskreserve 0
  ) || { echo "worker $wid: repo setup failed" >&2; return 3; }

  cd "$repo" || return 3
  for ((i = 0; i < ROUNDS; i++)); do
    printf 'content %s %s\n' "$wid" "$i" > "f$i"
    if [ "$MODE" = add-unlocked ]; then
      out="$(git -c annex.addunlocked=true annex add "f$i" 2>&1)" || {
        is_space_failure "$out" && { abort_no_space "$wid" "$i" "$out"; return 4; }
        failures=$((failures + 1))
        printf 'worker %s round %s: add failed\n%s\n' "$wid" "$i" "$out" >&2
        continue
      }
      # the To-direction failure is a warning + non-zero exit; also catch the
      # message in case a future version only warns
      case "$out" in *"failed to link to annex"*)
        is_space_failure "$out" && { abort_no_space "$wid" "$i" "$out"; return 4; }
        failures=$((failures + 1))
        printf 'worker %s round %s:\n%s\n' "$wid" "$i" "$out" >&2 ;;
      esac
    else
      out="$(git annex add -q "f$i" 2>&1)" || {
        is_space_failure "$out" && { abort_no_space "$wid" "$i" "$out"; return 4; }
        failures=$((failures + 1))
        printf 'worker %s round %s: add failed\n%s\n' "$wid" "$i" "$out" >&2
        continue
      }
      out="$(git annex unlock "f$i" 2>&1)" || {
        is_space_failure "$out" && { abort_no_space "$wid" "$i" "$out"; return 4; }
        failures=$((failures + 1))
        printf 'worker %s round %s:\n%s\n' "$wid" "$i" "$out" >&2
        continue
      }
      case "$out" in *"unlock failed"*)
        is_space_failure "$out" && { abort_no_space "$wid" "$i" "$out"; return 4; }
        failures=$((failures + 1))
        printf 'worker %s round %s:\n%s\n' "$wid" "$i" "$out" >&2 ;;
      esac
    fi
    git commit -qm "round $i" >/dev/null 2>&1 || :
  done
  echo "$failures" > "$work/failures.$wid"
}

start=$(date +%s)
for ((w = 0; w < WORKERS; w++)); do
  run_worker "$w" &
done
wait
end=$(date +%s)

# Exit 4, distinct from "some rounds failed" (1) and "the harness is
# broken" (3): the run is void rather than negative, and the caller
# (bin/ci/target-git-annex-linkannex.sh) turns it into an incomplete
# cell instead of a filesystem verdict the numbers do not support.
if compgen -G "$work/nospace.*" >/dev/null 2>&1; then
  {
    echo "ERROR: the filesystem under test ran out of space."
    echo "       Any rate from this run would measure free space, not linkAnnex."
    echo "       Give the cell a bigger backing image: loop-size-mb in"
    echo "       evals/matrix.yaml, or --size for bin/eval-under loop."
  } >&2
  exit 4
fi

total_failures=0
for ((w = 0; w < WORKERS; w++)); do
  if [ ! -e "$work/failures.$w" ]; then
    echo "worker $w did not finish; its output above says why" >&2
    exit 3
  fi
  f="$(cat "$work/failures.$w")"
  total_failures=$((total_failures + f))
done
total=$((ROUNDS * WORKERS))

printf '\n%s/%s rounds failed in linkAnnex (%s%%), in %ss\n' \
  "$total_failures" "$total" \
  "$(awk -v a="$total_failures" -v b="$total" 'BEGIN{printf "%.2f", b ? 100*a/b : 0}')" \
  "$((end - start))"

if [ -n "$REPORT" ]; then
  printf '%s\t%s\n' "$total_failures" "$total" > "$REPORT"
fi

[ "$total_failures" -eq 0 ] || exit 1
