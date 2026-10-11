#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# eval-under *target*: DataLad's own asv benchmark suite, from the pinned
# release's sdist, timed on the filesystem under test.
#
# The other targets answer "does it break?"; this one answers "what does
# the filesystem cost a DataLad user?" -- create, save, clone, status,
# run, over datasets up to 10 subdatasets x 1000 files. A benchmark that
# errors, times out, or is not reached within the cell's time budget is
# a failure; one that finishes is a pass, and its timing goes to the log
# and, as asv's own JSON, to the cell's logs artifact under asv-results/.
# The asv "machine" is the backend slug and the commit is the same in
# every cell, so the cells' asv-results/ trees merge without colliding.
#
# git-annex is the daily build the git-annex cells of the same run test
# (needs-git-annex in evals/matrix.yaml); DataLad and the benchmarks are
# whatever bin/ci/install-target.sh datalad-benchmarks put in
# $EVAL_UNDER_SRC_DIR.
#
# Runs INSIDE the eval-under wrapper, i.e. with TMPDIR / HOME already
# pointing at the filesystem under test. Do not invoke directly for CI
# purposes -- go through bin/ci/run-under.sh <backend> <version> \
# datalad-benchmarks.
#
# usage:
#   bin/ci/target-datalad-benchmarks.sh
#
# env (set by eval-under / run-under.sh, honoured here):
#   HOME     <mount>/home
#   TMPDIR   <mount> -- every benchmark makes its datasets under here,
#            via tempfile, and so does asv's setup_cache
#   EVAL_UNDER_OUTPUT_DIR    the cell's output dir; results go to its
#                            asv-results/ (default: $HOME, i.e. lost on
#                            teardown)
#   EVAL_UNDER_BACKEND_SLUG  asv machine name (default: hostname)
#   EVAL_UNDER_TIMEOUT       the cell's time budget, in seconds (default:
#                            the target's timeout in evals/matrix.yaml)
#
# env (optional):
#   EVAL_UNDER_ASV_BENCH   regex: run only the benchmarks it matches
#                          (asv run --bench), e.g. '^save_run\.', in one
#                          pass
#   EVAL_UNDER_ASV_LAST    regex: benchmarks to run last, in a pass of their
#                          own (default: '_heavy_'; '' for a single pass)
#   EVAL_UNDER_ASV_ATTRS   space-separated benchmark attribute overrides
#                          (asv run --attribute), e.g. 'rounds=1 repeat=1'
#                          for a smoke run. Default: see ATTRS below.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# matrix.sh is a sourced library, resolved at runtime relative to $here.
# shellcheck source=bin/ci/matrix.sh disable=SC1091
. "$here/matrix.sh"

SRC="$EVAL_UNDER_SRC_DIR/datalad"
VENV="$EVAL_UNDER_SRC_DIR/datalad-venv"
OUT="${EVAL_UNDER_OUTPUT_DIR:-$HOME}"
MACHINE="${EVAL_UNDER_BACKEND_SLUG:-$(hostname -s)}"
BENCH="${EVAL_UNDER_ASV_BENCH:-}"
LAST="${EVAL_UNDER_ASV_LAST-_heavy_}"
BUDGET="${EVAL_UNDER_TIMEOUT:-$(target_timeout datalad-benchmarks)}"
# Half asv's default budget, to fit the slow backends into the cell's
# timeout: one round (process) per benchmark instead of two, sampling it
# up to 5 times or for 10s. asv's default is 10 samples or 20s, split
# over two rounds; each round also runs the benchmark at least twice
# (min_run_count) whatever its time cap, which is what a slow backend
# pays for the 10 x 1000-file hierarchy. repeat is spelled out because
# `rounds=1` alone still leaves asv sizing each round for two.
ATTRS="${EVAL_UNDER_ASV_ATTRS-rounds=1 repeat=(1,5,10.0)}"

# The stamp install-target.sh writes once the venv is complete.
if [ ! -r "$VENV/eval-under-pins" ] || [ ! -r "$SRC/PKG-INFO" ]; then
    echo "ERROR: no datalad benchmarks under $EVAL_UNDER_SRC_DIR --" \
         "run bin/ci/install-target.sh datalad-benchmarks first" >&2
    exit 3
fi

cd "$HOME"

# Same reason as target-git-annex.sh: --set-home repoints HOME at the
# mount, so the runner's ~/.gitconfig is out of scope, and every
# benchmark commits.
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email test@github.land
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name "GitHub Almighty"

# The CLI benchmarks run `datalad` by name.
export PATH="$VENV/bin:$PATH"

# Everything but the plan and the points is a TAP comment, or
# bin/ci/collect-results.py would try to read it.
echo "# $(datalad --version) (PyPI sdist $EVAL_UNDER_DATALAD_REF)," \
     "asv $EVAL_UNDER_ASV_REF, asv-runner $EVAL_UNDER_ASV_RUNNER_REF"
git annex version | head -1 | sed 's/^/# /'

work="$(mktemp -d "${TMPDIR:-/tmp}/datalad-asv-XXXXXX")"
trap 'rm -rf "$work"' EXIT

# asv files results under a commit it resolves in a git repo, and an
# sdist is not one. So give it one: a single commit of the sdist's
# PKG-INFO, with identity, dates and mode fixed, so every cell, and every
# run of the same release, files under the same hash -- which is what
# lets the per-backend results merge. The date is PKG-INFO's mtime (tar
# keeps it): when the sdist was built, near enough the release.
repo="$work/repo"
git init -q "$repo"
cp "$SRC/PKG-INFO" "$repo/PKG-INFO"
git -C "$repo" add PKG-INFO
git -C "$repo" update-index --chmod=-x PKG-INFO    # vfat says everything is +x
stamp="@$(stat -c %Y "$SRC/PKG-INFO") +0000"
GIT_AUTHOR_NAME=eval-under GIT_AUTHOR_EMAIL=eval-under@localhost \
GIT_COMMITTER_NAME=eval-under GIT_COMMITTER_EMAIL=eval-under@localhost \
GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
    git -C "$repo" -c commit.gpgsign=false commit -q \
        -m "datalad $EVAL_UNDER_DATALAD_REF (PyPI sdist)"
commit="$(git -C "$repo" rev-parse HEAD)"

results="$OUT/asv-results"
# asv merges into an existing results file, so a rerun into the same
# output dir would otherwise report the last run's benchmarks as this one's.
rm -rf "$results"
mkdir -p "$results"

# Written by Python so a path cannot break the JSON. environment_type
# "existing" plus --python=same below: benchmark the venv as installed,
# no per-commit build.
python3 - "$work/asv.conf.json" "$repo" "$SRC/benchmarks" "$results" "$work" <<'PYEOF'
import json, sys
conf, repo, bench, results, work = sys.argv[1:]
with open(conf, "w") as fh:
    json.dump({
        "version": 1,
        "project": "datalad",
        "repo": repo,
        "branches": ["HEAD"],
        "environment_type": "existing",
        "benchmark_dir": bench,
        "results_dir": results,
        "env_dir": work + "/env",
        "html_dir": work + "/html",
    }, fh, indent=2)
PYEOF

# The host's cpu/ram/os, filed under the machine name in
# ~/.asv-machine.json (on the mount, gone with it); `asv run` copies it
# to $results/<machine>/machine.json. Not `asv machine --yes --machine
# NAME`: that records the name alone.
python3 - "$MACHINE" <<'PYEOF'
import sys
from asv.machine import Machine, MachineCollection
info = Machine.get_defaults()
info["machine"] = sys.argv[1]
MachineCollection.save(sys.argv[1], info)
PYEOF

# --launch-method spawn: asv's default forkserver talks over a Unix
# socket under $TMPDIR, i.e. on the mount, and vfat has none.
args=(--config "$work/asv.conf.json" --python=same
      --set-commit-hash "$commit" --machine "$MACHINE"
      --launch-method spawn --show-stderr)
for a in $ATTRS; do
    args+=(--attribute "$a")
done

# asv saves results only when a run ends, so a run cut short by the
# cell's timeout leaves nothing -- on exactly the slow backends this
# target is for. Hence passes, each stopped at a deadline of our own
# that leaves time to report: the cheap benchmarks first, then $LAST
# (DataLad's 10 x 1000-file hierarchy), which asv adds to the same
# results file. What a stopped pass had not finished is reported below
# as "not run".
deadline=$((SECONDS + BUDGET - 120))
asv_rc=0
asv_pass() {
    local what="$1" left=$((deadline - SECONDS)) rc=0 pgid n=0
    shift
    if [ "$left" -le 0 ]; then
        echo "# DEADLINE: no time left for $what"
        return
    fi
    echo "# === asv run: $what (stopped after ${left}s)"
    # SIGINT, not timeout's TERM: asv runs each benchmark in a process
    # group of its own, which a signal to timeout's group does not reach,
    # and only on an interrupt does asv take that group down with it. A
    # TERM kills asv outright, and the benchmark and its git-annex run on,
    # on the mount. Timeout's own group (pid recorded from the background,
    # for after timeout is gone) is drained below.
    { timeout -s INT -k 30 "$left" asv run "${args[@]}" "$@" 2>&1 &
      echo "$!" > "$work/pgid"
      wait "$!"; } | sed 's/^/# /' || rc=$?
    # The newline: asv may have been cut off mid-line.
    case "$rc" in
        124|137) printf '\n# DEADLINE: stopped %s after %ss\n' "$what" "$left" ;;
        # 2 is asv's "some benchmarks failed"; the points below say which.
        *) echo "# asv run exited $rc" ;;
    esac
    [ "$asv_rc" != 0 ] || asv_rc=$rc
    # Whatever is left must be gone before we are: eval-under unmounts the
    # moment we exit, and on BeeGFS a client still busy on a mount whose
    # servers are being stopped is a hung job, not a failed umount.
    pgid="$(cat "$work/pgid")"
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$n" -lt 30 ]; do
        sleep 1
        n=$((n + 1))
    done
    kill -KILL -- "-$pgid" 2>/dev/null || true
}
if [ -n "$BENCH" ]; then
    asv_pass "benchmarks matching $BENCH" --bench "$BENCH"
elif [ -n "$LAST" ]; then
    asv_pass "all benchmarks but $LAST" --bench "^(?!.*$LAST)"
    asv_pass "benchmarks matching $LAST" --bench "$LAST"
else
    asv_pass "all benchmarks"
fi

shopt -s nullglob
files=("$results/$MACHINE/${commit:0:8}"-*.json)
shopt -u nullglob
if [ "${#files[@]}" -ne 1 ]; then
    # No plan, so the cell comes out "incomplete": asv died before
    # saving, which is a harness problem, not a verdict on the filesystem.
    echo "# ABORT: expected one asv results file for $MACHINE/${commit:0:8}, found ${#files[@]}"
    exit $(( asv_rc ? asv_rc : 3 ))
fi

# Not exec: the EXIT trap still has $work to clean up.
rc=0
"$here/asv-results-tap.py" --expect "$BENCH" "${files[0]}" || rc=$?
exit "$rc"
