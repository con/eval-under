#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Tests for the `eval-under` dispatcher: option handling, backend
# discovery, dispatch, and version reporting.
#
# Everything here is unprivileged and mounts nothing -- it covers the
# entry point, not the backends' actual mount/teardown logic (that needs
# root, a kernel module, and a live cluster; see the CI matrix). The
# dispatcher is exercised against throwaway trees of stub backends, so
# the suite does not change shape every time a real backend is added.
#
#   bats tests/            # or bin/ci/run-checks.sh
#
# Written against plain bats-core, no bats-assert / bats-support, so
# `apt-get install bats` is the whole setup.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DISPATCHER="$REPO_ROOT/bin/eval-under"

  # Throwaway repos must not inherit the developer's git identity,
  # commit hooks, or `tag.gpgSign`.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="eval-under tests"
  export GIT_AUTHOR_EMAIL="tests@example.com"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
}

# A throwaway <dir>/bin/ holding the real dispatcher plus one stub
# backend per name given. Each stub echoes the argv it was handed, which
# is what the dispatch tests assert on.
make_tree() {
  local dir="$BATS_TEST_TMPDIR/inst" name
  mkdir -p "$dir/bin"
  cp "$DISPATCHER" "$dir/bin/eval-under"
  for name in "$@"; do
    cat >"$dir/bin/eval-under-$name" <<'STUB'
#!/bin/bash
echo "stub $(basename "$0") argv: $*"
STUB
    chmod +x "$dir/bin/eval-under-$name"
  done
  echo "$dir"
}

# A throwaway git checkout with the dispatcher in $1 (default `bin`) and
# one committed file the -dirty tests can touch.
make_git_tree() {
  local dir="$BATS_TEST_TMPDIR/repo" sub="${1:-bin}"
  mkdir -p "$dir/$sub"
  cp "$DISPATCHER" "$dir/$sub/eval-under"
  echo "tracked" >"$dir/marker"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" commit -qm "initial"
  echo "$dir"
}

# The value an installed copy reports, read out of the script rather
# than hardcoded here, so bumping a release does not edit two places.
fallback_version() {
  sed -n 's/^VERSION_FALLBACK="\(.*\)"$/\1/p' "$DISPATCHER"
}

# ---------------------------------------------------------------- usage

@test "no arguments: usage on stderr, exit 2" {
  run bash -c "'$DISPATCHER' 2>'$BATS_TEST_TMPDIR/err' >'$BATS_TEST_TMPDIR/out'"
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -q "Usage: eval-under BACKEND" "$BATS_TEST_TMPDIR/err"
}

@test "--help: usage on stdout, exit 0" {
  run bash -c "'$DISPATCHER' --help 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
  [[ "$output" == *"Usage: eval-under BACKEND"* ]]
}

@test "-h is a synonym for --help" {
  run "$DISPATCHER" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: eval-under BACKEND"* ]]
}

@test "--help lists the backends actually present" {
  tree="$(make_tree alpha beta)"
  run "$tree/bin/eval-under" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"  - alpha"* ]]
  [[ "$output" == *"  - beta"* ]]
}

@test "unknown top-level option: exit 2, names the option" {
  run bash -c "'$DISPATCHER' --definitely-not-an-option 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown top-level option: --definitely-not-an-option"* ]]
}

# ------------------------------------------------------ backend listing

@test "--list names every executable backend, one per line" {
  tree="$(make_tree alpha beta)"
  run "$tree/bin/eval-under" --list
  [ "$status" -eq 0 ]
  [ "$output" = "alpha
beta" ]
}

@test "--list skips a non-executable eval-under-* sibling" {
  # Room for a sourced helper or a note file next to the dispatcher
  # without it being mistaken for a backend.
  tree="$(make_tree alpha)"
  touch "$tree/bin/eval-under-common.sh"
  run "$tree/bin/eval-under" --list
  [ "$status" -eq 0 ]
  [ "$output" = "alpha" ]
}

@test "--list is empty, not an error, with no backends installed" {
  # The unmatched glob must not leak through as a literal name.
  tree="$(make_tree)"
  run "$tree/bin/eval-under" --list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------- dispatch

@test "dispatch: the backend gets the remaining argv verbatim" {
  tree="$(make_tree alpha)"
  run "$tree/bin/eval-under" alpha --set-home -- echo hi
  [ "$status" -eq 0 ]
  [ "$output" = "stub eval-under-alpha argv: --set-home -- echo hi" ]
}

@test "dispatch: --help after a backend name goes to the backend" {
  tree="$(make_tree alpha)"
  run "$tree/bin/eval-under" alpha --help
  [ "$status" -eq 0 ]
  [ "$output" = "stub eval-under-alpha argv: --help" ]
}

@test "dispatch: argv with spaces survives the exec" {
  tree="$(make_tree alpha)"
  run "$tree/bin/eval-under" alpha -- sh -c "echo one two"
  [ "$output" = "stub eval-under-alpha argv: -- sh -c echo one two" ]
}

@test "dispatch: the backend's exit status is the dispatcher's" {
  tree="$(make_tree)"
  printf '#!/bin/bash\nexit 42\n' >"$tree/bin/eval-under-picky"
  chmod +x "$tree/bin/eval-under-picky"
  run "$tree/bin/eval-under" picky
  [ "$status" -eq 42 ]
}

@test "unknown backend: exit 2, names the available ones" {
  tree="$(make_tree alpha beta)"
  run bash -c "'$tree/bin/eval-under' nosuch -- true 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown backend 'nosuch'"* ]]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "a non-executable backend file is not dispatchable" {
  tree="$(make_tree alpha)"
  chmod -x "$tree/bin/eval-under-alpha"
  run bash -c "'$tree/bin/eval-under' alpha -- true 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown backend 'alpha'"* ]]
}

# -------------------------------------------------------------- version

@test "--version: an exact tag reports just the tag" {
  repo="$(make_git_tree)"
  git -C "$repo" tag -a 1.2.3 -m 1.2.3
  run "$repo/bin/eval-under" --version
  [ "$status" -eq 0 ]
  [ "$output" = "eval-under 1.2.3" ]
}

@test "-V is a synonym for --version" {
  repo="$(make_git_tree)"
  git -C "$repo" tag -a 1.2.3 -m 1.2.3
  run "$repo/bin/eval-under" -V
  [ "$status" -eq 0 ]
  [ "$output" = "eval-under 1.2.3" ]
}

@test "--version: lightweight tags count too" {
  # i.e. --tags is really being passed to git describe.
  repo="$(make_git_tree)"
  git -C "$repo" tag 1.2.3
  run "$repo/bin/eval-under" --version
  [ "$output" = "eval-under 1.2.3" ]
}

@test "--version: commits past a tag get describe's -N-g<sha> suffix" {
  repo="$(make_git_tree)"
  git -C "$repo" tag -a 1.2.3 -m 1.2.3
  git -C "$repo" commit -q --allow-empty -m later
  run "$repo/bin/eval-under" --version
  [[ "$output" =~ ^eval-under\ 1\.2\.3-1-g[0-9a-f]+$ ]]
}

@test "--version: a modified checkout is reported -dirty" {
  repo="$(make_git_tree)"
  git -C "$repo" tag -a 1.2.3 -m 1.2.3
  echo "poked" >"$repo/marker"
  run "$repo/bin/eval-under" --version
  [ "$output" = "eval-under 1.2.3-dirty" ]
}

@test "--version: an untagged checkout reports the commit, not the fallback" {
  repo="$(make_git_tree)"
  run "$repo/bin/eval-under" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^eval-under\ ([0-9a-f]+)$ ]]
  # Whatever abbreviation length git chose, it must prefix HEAD.
  [[ "$(git -C "$repo" rev-parse HEAD)" == "${BASH_REMATCH[1]}"* ]]
}

@test "--version: outside any checkout, the baked-in fallback" {
  dir="$BATS_TEST_TMPDIR/installed/bin"
  mkdir -p "$dir"
  cp "$DISPATCHER" "$dir/eval-under"
  run "$dir/eval-under" --version
  [ "$status" -eq 0 ]
  [ "$output" = "eval-under $(fallback_version)" ]
}

@test "--version: a copy inside an unrelated checkout does not borrow its tags" {
  # Installed at <repo>/tools/, so the $top/bin guard must reject it.
  repo="$(make_git_tree tools)"
  git -C "$repo" tag -a 9.9.9 -m 9.9.9
  run "$repo/tools/eval-under" --version
  [ "$status" -eq 0 ]
  [ "$output" = "eval-under $(fallback_version)" ]
}

@test "--version: a git that refuses the repo still answers, quietly" {
  # A safe.directory refusal (or any other git failure) must degrade to
  # the fallback, not leak git's complaint or a non-zero exit.
  repo="$(make_git_tree)"
  git -C "$repo" tag -a 1.2.3 -m 1.2.3
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat >"$BATS_TEST_TMPDIR/fakebin/git" <<'FAKE'
#!/bin/bash
echo "fatal: detected dubious ownership in repository" >&2
exit 128
FAKE
  chmod +x "$BATS_TEST_TMPDIR/fakebin/git"
  run bash -c "PATH='$BATS_TEST_TMPDIR/fakebin:$PATH' '$repo/bin/eval-under' --version 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
  [ "$output" = "eval-under $(fallback_version)" ]
}

@test "VERSION_FALLBACK matches the newest tag in this checkout" {
  # The fallback is what a packaged copy reports, so it is only correct
  # while it tracks the latest release tag.
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || skip "not running from a git checkout"
  latest="$(git -C "$REPO_ROOT" tag --sort=-v:refname | head -1)"
  [ -n "$latest" ] || skip "no tags in this checkout (shallow clone?)"
  [ "$(fallback_version)" = "$latest" ]
}

# ------------------------------------------------- installed backends

# These run against the real bin/, but only reach each backend's option
# parser -- every one of them exits before its root check.

@test "every installed backend answers --help with its own usage" {
  local b
  for b in $("$DISPATCHER" --list); do
    run "$REPO_ROOT/bin/eval-under-$b" --help
    if [ "$status" -ne 0 ]; then
      echo "backend $b: --help exited $status" >&2
      return 1
    fi
    if [[ "$output" != *"Usage: eval-under-$b"* ]]; then
      echo "backend $b: --help printed no 'Usage: eval-under-$b' line" >&2
      return 1
    fi
  done
}

@test "every installed backend rejects an unknown option with exit 2" {
  local b
  for b in $("$DISPATCHER" --list); do
    run bash -c "'$REPO_ROOT/bin/eval-under-$b' --definitely-not-an-option 2>&1"
    if [ "$status" -ne 2 ] || [[ "$output" != *"unknown arg"* ]]; then
      echo "backend $b: expected exit 2 + 'unknown arg', got $status: $output" >&2
      return 1
    fi
  done
}

@test "every installed backend requires a command after --" {
  local b
  for b in $("$DISPATCHER" --list); do
    run bash -c "'$REPO_ROOT/bin/eval-under-$b' -- 2>&1"
    if [ "$status" -ne 2 ] || [[ "$output" != *"no command given"* ]]; then
      echo "backend $b: expected exit 2 + 'no command given', got $status: $output" >&2
      return 1
    fi
  done
}

@test "every installed backend documents the common options" {
  local b opt
  for b in $("$DISPATCHER" --list); do
    run "$REPO_ROOT/bin/eval-under-$b" --help
    for opt in --mount-point --set-home --keep; do
      if [[ "$output" != *"$opt"* ]]; then
        echo "backend $b: --help does not mention $opt" >&2
        return 1
      fi
    done
  done
}
