#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Shared CI matrix accessors for eval-under. Sourced (not executed) by
# bin/ci/{install-target,run-under,target-*,matrix-json,...}.sh.
#
# This file used to *hold* the matrix. It now *reads* it, from
# .github/matrix.yaml -- so the workflow and these scripts cannot drift
# apart, because both parse the same file. Everything here is accessors
# over that data plus the naming rules.
#
# shellcheck shell=bash

# Repo root, resolved from this file's location so callers can be run
# from anywhere (CI checks out to a different path than the Vagrant VM).
EVAL_UNDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVAL_UNDER_MATRIX_FILE="${EVAL_UNDER_MATRIX_FILE:-$EVAL_UNDER_ROOT/.github/matrix.yaml}"

[ -r "$EVAL_UNDER_MATRIX_FILE" ] || {
    echo "matrix.sh: cannot read $EVAL_UNDER_MATRIX_FILE" >&2
    # Sourced normally, so `return` is the live path; the `exit` is the
    # fallback for anyone who runs this file directly. shellcheck only
    # sees the static text and calls the second half unreachable.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
}

# Parse once, into shell. python3 + PyYAML rather than `yq`: both are
# present on GitHub's ubuntu images, but python3 is also what every
# developer box and the Vagrant VM already have, and it lets us fail
# loudly on a malformed file instead of silently yielding "null".
#
# Emits assignments only; anything unexpected is a parse error there,
# not a surprise `eval` here.
eval "$(python3 - "$EVAL_UNDER_MATRIX_FILE" <<'PYEOF'
import sys, shlex, yaml

with open(sys.argv[1]) as fh:
    d = yaml.safe_load(fh)

targets = d["targets"]
backends = d["backends"]
if not targets or not backends:
    sys.exit("matrix.yaml: empty targets or backends")

def q(v):
    return shlex.quote(str(v))

out = []
out.append("EVAL_UNDER_TARGETS=(%s)" % " ".join(q(t["name"]) for t in targets))
out.append("EVAL_UNDER_BACKENDS=(%s)" % " ".join(
    q("%s|%s|%s" % (b["backend"], b["version"], b["label"])) for b in backends))

out.append("declare -A _EU_LABEL=(%s)" % " ".join(
    "[%s]=%s" % (q(t["name"]), q(t["label"])) for t in targets))
out.append("declare -A _EU_TIMEOUT=(%s)" % " ".join(
    "[%s]=%s" % (q(t["name"]), q(t["timeout"])) for t in targets))
out.append("declare -A _EU_LOOP_MB=(%s)" % " ".join(
    "[%s]=%s" % (q(t["name"]), q(t["loop-size-mb"])) for t in targets))
out.append("declare -A _EU_NEEDS_ROOT=(%s)" % " ".join(
    "[%s]=%s" % (q(t["name"]), q(int(bool(t["needs-root"])))) for t in targets))
out.append("declare -A _EU_NEEDS_GA=(%s)" % " ".join(
    "[%s]=%s" % (q(t["name"]), q(int(bool(t["needs-git-annex"])))) for t in targets))

# Env overrides win, so these are defaults only.
out.append(": \"${EVAL_UNDER_REPO_SLUG:=%s}\"" % q(d["repo-slug"]))
out.append(": \"${EVAL_UNDER_SRC_DIR:=%s}\"" % q(d["src-dir"]))
out.append(": \"${EVAL_UNDER_GIT_REF:=%s}\"" % q(d["refs"]["git"]))
out.append(": \"${EVAL_UNDER_PJDFSTEST_REF:=%s}\"" % q(d["refs"]["pjdfstest"]))

print("\n".join(out))
PYEOF
)" || {
    echo "matrix.sh: failed to parse $EVAL_UNDER_MATRIX_FILE" >&2
    # Sourced normally, so `return` is the live path; the `exit` is the
    # fallback for anyone who runs this file directly. shellcheck only
    # sees the static text and calls the second half unreachable.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
}

export EVAL_UNDER_REPO_SLUG EVAL_UNDER_SRC_DIR
export EVAL_UNDER_GIT_REF EVAL_UNDER_PJDFSTEST_REF

# Filename-safe identifier for a backend cell: "beegfs-7.4.6", "nfs",
# "loop-vfat".
backend_slug() {
    local backend="$1" version="$2"
    if [ "$version" = "n/a" ]; then
        echo "$backend"
    else
        echo "$backend-$version"
    fi
}

# Filename-safe identifier for a whole matrix cell: "beegfs-7.4.6-git",
# "nfs-pjdfstest", "loop-vfat-stress-ng".
#
# Exists because the NFS backend's version is the literal "n/a", and a
# naive "<backend>-<version>-<target>" therefore contains a slash.
# actions/upload-artifact rejects slashes in artifact names outright, so
# `logs-nfs-n/a-git` is a hard error -- one that stayed invisible until
# the git target started producing files to upload at all (before that,
# `if-no-files-found: ignore` short-circuited before the name was ever
# validated).
cell_slug() {
    local backend="$1" version="$2" target="$3"
    echo "$(backend_slug "$backend" "$version")-$target"
}

target_known() {
    local t
    for t in "${EVAL_UNDER_TARGETS[@]}"; do
        [ "$t" = "$1" ] && return 0
    done
    return 1
}

# Human-readable column header / job-name fragment.
target_label()        { echo "${_EU_LABEL[$1]:-$1}"; }
target_timeout()      { echo "${_EU_TIMEOUT[$1]:-1800}"; }
target_loop_size_mb() { echo "${_EU_LOOP_MB[$1]:-100}"; }

# Does this target need to run as root to mean anything? The loop and
# beegfs backends already run the wrapped command as root, but the NFS
# backend deliberately drops back to the invoking user and exports with
# root_squash -- exactly right for git-annex/git, useless for the other
# two. run-under.sh passes --no-root-squash for these.
target_needs_root()      { [ "${_EU_NEEDS_ROOT[$1]:-0}" = 1 ]; }
target_needs_git_annex() { [ "${_EU_NEEDS_GA[$1]:-0}" = 1 ]; }
