# Project conventions

## CI: shell logic lives in `bin/ci/`, NOT inline in workflow YAML

Workflow files under `.github/workflows/` (and any equivalent under
`.forgejo/workflows/` if we ever add one) MUST stay thin. They are for:

- declaring the trigger + matrix
- setting up runner-level context (checkout, permissions, timeouts)
- invoking scripts

Any actual shell logic goes into `bin/ci/<action>.sh` and is invoked
from the workflow. Rationale:

- **Testable.** Scripts can be run locally (in the Vagrant VM, or on any
  Ubuntu box) with the same env the runner sees. Inline YAML shell can
  only be tested by pushing.
- **Reviewable.** A 60-line `bin/ci/install-backend.sh` reads as bash;
  the same logic embedded in a workflow reads as YAML-with-strings and
  is nearly impossible to skim.
- **Lintable.** `shellcheck bin/ci/*.sh` catches the class of bugs
  (unquoted expansions, missing `set -eu`, dead branches) that inline
  YAML hides.
- **Reusable across triggers / workflows.** The same install step can
  be called from a scheduled workflow, a workflow_dispatch, or a
  release workflow, without duplicating shell.

### Rules

1. If a step's `run:` block is more than ~10 lines OR contains a
   `case`/`if` branch, extract to `bin/ci/<verb>-<noun>.sh`.
2. Scripts start with:
   ```bash
   #!/bin/bash
   set -euo pipefail
   ```
   plus, for anything that calls `apt-get`:
   ```bash
   export DEBIAN_FRONTEND=noninteractive
   ```
   and prefer `apt-get -o DPkg::Lock::Timeout=60 ...` to survive the
   post-boot `unattended-upgrades` dpkg-lock window on ubuntu-22.04
   runners.
3. Scripts pass `shellcheck` cleanly. Run `shellcheck bin/ci/*.sh
   bin/eval-under*` before committing. If a warning is a genuine
   false positive, silence with a targeted `# shellcheck disable=SCxxxx`
   annotation and a one-line comment explaining why -- do not blanket-
   suppress at file scope.
4. Positional args first, env vars as override. Document both at the
   top of the script in a short `usage()` heredoc.
5. Scripts under `bin/ci/` are runner-side helpers, distinct from
   `bin/eval-under*` which are the framework's user-facing CLI. They
   should not be documented in the README's "CLI usage" section.

### Trivial exception

A 1- or 2-line `run:` block (e.g. `git config --global user.email ...`;
a `sudo dmesg | tail`) may stay inline. The bar is "would this benefit
from `shellcheck` + local testability" -- if the answer is clearly no,
inline is fine.

## DESIGN.md and IMPLEMENTATION.md must stay in sync

`DESIGN.md` (what and why) and `IMPLEMENTATION.md` (how, plus the
measurements and constraints already established) describe one feature
from two altitudes. They are a pair:

- A change to an interface, a constraint, or the rollout order in one
  **must** be reflected in the other in the same commit.
- If they disagree, `DESIGN.md` wins and `IMPLEMENTATION.md` is the bug.
- Facts recorded in `IMPLEMENTATION.md` carry their provenance --
  `[verified: how]` or `[unverified]`. Do not promote an unverified
  claim without actually verifying it, and do not silently drop one.
