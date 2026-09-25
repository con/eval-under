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
#   ./nfs-annex-linkannex-loop.sh [-n ROUNDS] [-j WORKERS] [-m MODE] [-d DIR]
#
# exits non-zero if any round failed.

set -u -o pipefail

ROUNDS=200
WORKERS=1
MODE=unlock
DIR=.

usage() { sed -n '3,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--rounds)  ROUNDS="$2"; shift 2 ;;
    -j|--workers) WORKERS="$2"; shift 2 ;;
    -m|--mode)    MODE="$2"; shift 2 ;;
    -d|--dir)     DIR="$2"; shift 2 ;;
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
trap 'rm -rf "$work"' EXIT

echo "# dir:     $root"
echo "# mount:   $(findmnt -no FSTYPE,OPTIONS --target "$root" 2>/dev/null || echo '(findmnt unavailable)')"
echo "# version: $(git annex version --raw 2>/dev/null || echo unknown)"
echo "# plan:    $WORKERS worker(s) x $ROUNDS rounds, mode=$MODE"

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
  ) || { echo "worker $wid: repo setup failed" >&2; return 3; }

  cd "$repo" || return 3
  for ((i = 0; i < ROUNDS; i++)); do
    printf 'content %s %s\n' "$wid" "$i" > "f$i"
    if [ "$MODE" = add-unlocked ]; then
      out="$(git -c annex.addunlocked=true annex add "f$i" 2>&1)" || {
        failures=$((failures + 1))
        printf 'worker %s round %s: add failed\n%s\n' "$wid" "$i" "$out" >&2
        continue
      }
      # the To-direction failure is a warning + non-zero exit; also catch the
      # message in case a future version only warns
      case "$out" in *"failed to link to annex"*)
        failures=$((failures + 1))
        printf 'worker %s round %s:\n%s\n' "$wid" "$i" "$out" >&2 ;;
      esac
    else
      git annex add -q "f$i" >/dev/null 2>&1 || {
        failures=$((failures + 1))
        printf 'worker %s round %s: add failed\n' "$wid" "$i" >&2
        continue
      }
      out="$(git annex unlock "f$i" 2>&1)" || {
        failures=$((failures + 1))
        printf 'worker %s round %s:\n%s\n' "$wid" "$i" "$out" >&2
        continue
      }
      case "$out" in *"unlock failed"*)
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

[ "$total_failures" -eq 0 ] || exit 1
