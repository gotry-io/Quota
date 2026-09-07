#!/usr/bin/env bash
# Answers whether a CI job has anything to do, from the paths a push or pull request changed.
#
#   ci-changed-paths.sh any <regex>   run=true when at least one changed path matches
#   ci-changed-paths.sh all <regex>   run=false when every changed path matches (nothing else moved)
#
# Reads GITHUB_EVENT_NAME, and the base SHA of a pull request or the before SHA of a push, from
# the environment the workflow passes in. When there is nothing to diff against (a new branch,
# a manual run, a failed diff) the answer is run=true: an unknown change is verified, not skipped.
set -euo pipefail

mode="${1:?any|all}"
pattern="${2:?regex}"
from=""
if [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${BASE_SHA:-}" ]; then
  from="$BASE_SHA"
elif [ "${EVENT_NAME:-}" = "push" ] && [ -n "${BEFORE_SHA:-}" ] \
  && [ "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]; then
  from="$BEFORE_SHA"
fi

run=true
if [ -n "$from" ]; then
  if changed=$(git diff --name-only "$from" HEAD); then
    case "$mode" in
      any)
        if ! printf '%s\n' "$changed" | grep -E -q "$pattern"; then
          run=false
        fi
        ;;
      all)
        if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -E -v -q "$pattern"; then
          run=false
        fi
        ;;
      *)
        echo "unknown mode: $mode" >&2
        exit 2
        ;;
    esac
  else
    echo "Could not diff against $from; running verification."
  fi
fi
if [ "$run" = false ]; then
  echo "No relevant path changes; skipping."
fi
echo "run=$run" >> "${GITHUB_OUTPUT:-/dev/stdout}"
