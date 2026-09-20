#!/usr/bin/env bash
# Answers whether a CI job has anything to do, from the paths a push or pull request changed.
#
#   ci-changed-paths.sh any <regex>   run=true when at least one changed path matches
#   ci-changed-paths.sh all <regex>   run=false when every changed path matches (nothing else moved)
#
# Reads the event name, and the base SHA of a pull request, the base SHA of a merge group, or the
# before SHA of a push, from the environment the workflow passes in. When there is nothing to diff
# against (a new branch, a manual run, a failed diff) the answer is run=true: an unknown change is
# verified, not skipped.
#
# One content rule sits above the path rule. A change that moves nothing but a product's version
# string — the bump `release-menubar` and `release-ios` open after a release — answers run=false
# for every caller: the tree it produces was verified when the code in it merged, and a bump that
# waits twenty minutes for the iOS suites is a bump every other merge overtakes. "Nothing but"
# is judged line by line, so a version edit riding along with any other change is verified.
set -euo pipefail

mode="${1:?any|all}"
pattern="${2:?regex}"
from=""
if [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${BASE_SHA:-}" ]; then
  from="$BASE_SHA"
elif [ "${EVENT_NAME:-}" = "merge_group" ] && [ -n "${MERGE_GROUP_BASE_SHA:-}" ]; then
  from="$MERGE_GROUP_BASE_SHA"
elif [ "${EVENT_NAME:-}" = "push" ] && [ -n "${BEFORE_SHA:-}" ] \
  && [ "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]; then
  from="$BEFORE_SHA"
fi

# Every changed file is one a version bump writes, and with its version line blanked each of them
# is byte for byte what it was. Blanking names the line by what it is — the string under
# CFBundleShortVersionString, MARKETING_VERSION — so another three-part number in the same file
# (a deployment target) is not mistaken for the product's version.
blank_version() {
  case "$1" in
    apps/menubar/Support/Info.plist)
      awk 'previous ~ /<key>CFBundleShortVersionString<\/key>/ { sub(/<string>[^<]*<\/string>/, "<string>@</string>") } { print; previous = $0 }'
      ;;
    apps/ios/project.yml)
      sed -E 's/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*$/\1@/'
      ;;
    apps/ios/Quota.xcodeproj/project.pbxproj)
      sed -E 's/^([[:space:]]*MARKETING_VERSION = )[^;]*;/\1@;/'
      ;;
  esac
}

version_only() {
  local from="$1" changed path
  changed=$(git diff --name-only "$from" HEAD) || return 1
  [ -n "$changed" ] || return 1
  while IFS= read -r path; do
    case "$path" in
      apps/menubar/Support/Info.plist | apps/ios/project.yml | apps/ios/Quota.xcodeproj/project.pbxproj) ;;
      *) return 1 ;;
    esac
    # A file added or removed has no counterpart to compare with, and is not a bump.
    git cat-file -e "$from:$path" 2>/dev/null || return 1
    git cat-file -e "HEAD:$path" 2>/dev/null || return 1
    if [ "$(git show "$from:$path" | blank_version "$path")" != "$(git show "HEAD:$path" | blank_version "$path")" ]; then
      return 1
    fi
  done <<<"$changed"
  return 0
}

run=true
if [ -n "$from" ] && version_only "$from"; then
  echo "Only a product version string changed; skipping."
  echo "run=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi
if [ -n "$from" ]; then
  if changed=$(git diff --name-only "$from" HEAD); then
    # grep answers 0 for a match and 1 for none; anything else (a pattern it cannot compile, for
    # one) is not an answer, and treating it as "no match" would quietly skip verification. Those
    # exit with the selection unmade rather than with run=false.
    case "$mode" in
      any)
        printf '%s\n' "$changed" | grep -E -q "$pattern" && matched=0 || matched=$?
        case "$matched" in
          0) ;;
          1) run=false ;;
          *)
            echo "grep could not judge the selection (exit $matched): $pattern" >&2
            exit 2
            ;;
        esac
        ;;
      all)
        if [ -n "$changed" ]; then
          printf '%s\n' "$changed" | grep -E -v -q "$pattern" && unmatched=0 || unmatched=$?
          case "$unmatched" in
            0) ;;
            1) run=false ;;
            *)
              echo "grep could not judge the selection (exit $unmatched): $pattern" >&2
              exit 2
              ;;
          esac
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
