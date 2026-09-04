#!/bin/sh
# Refuse an ios-v* tag whose X.Y.Z does not match apps/ios/project.yml MARKETING_VERSION.
set -eu

usage() {
  echo "usage: $0 <tag>" >&2
  echo "  tag is ios-vX.Y.Z or X.Y.Z and must match apps/ios/project.yml MARKETING_VERSION" >&2
  exit 2
}

tag="${1:-}"
[ -n "$tag" ] || usage

case "$tag" in
  ios-v*) version="${tag#ios-v}" ;;
  *) version="$tag" ;;
esac

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$'; then
  echo "invalid version: $version" >&2
  exit 1
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
project="${QUOTA_IOS_PROJECT_YML:-$root/apps/ios/project.yml}"

if [ ! -f "$project" ]; then
  echo "missing project.yml: $project" >&2
  exit 1
fi

source_version="$(
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*MARKETING_VERSION:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*MARKETING_VERSION:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$project"
)"

if [ -z "$source_version" ]; then
  echo "MARKETING_VERSION not found in $project" >&2
  exit 1
fi

if [ "$source_version" != "$version" ]; then
  echo "ios-v${version} does not match Quota iOS MARKETING_VERSION (${source_version})" >&2
  echo "bump and commit the Quota iOS version before creating the release tag" >&2
  exit 1
fi
