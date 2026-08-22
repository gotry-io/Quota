#!/bin/bash
# Point git at the checked-in .githooks directory. Runs from pnpm's prepare lifecycle,
# so a normal `pnpm install` in a clone is enough to arm the hooks.

set -euo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0 # not a git checkout: nothing to arm
fi

CURRENT="$(git config --get core.hooksPath || true)"
if [ -n "$CURRENT" ] && [ "$CURRENT" != .githooks ]; then
  # Every install would otherwise silently disarm another hook manager.
  echo "install-git-hooks: leaving core.hooksPath at ${CURRENT}" >&2
  echo "install-git-hooks: run 'git config core.hooksPath .githooks' to use the repository hooks" >&2
  exit 0
fi

git config core.hooksPath .githooks
