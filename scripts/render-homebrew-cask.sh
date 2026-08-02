#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?version is required}"
SHA256="${2:?sha256 is required}"
URL="${3:?release URL is required}"
OUTPUT="${4:?output path is required}"

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$'; then
  echo "invalid version: $VERSION" >&2
  exit 1
fi
if ! printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "invalid SHA-256: $SHA256" >&2
  exit 1
fi
EXPECTED_URL="https://github.com/gotry-io/Quota/releases/download/v${VERSION}/QuotaBar-${VERSION}-macos-arm64.zip"
if [[ "$URL" != "$EXPECTED_URL" ]]; then
  echo "unexpected release URL: $URL" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
sed \
  -e "s|@VERSION@|${VERSION}|g" \
  -e "s|@SHA256@|${SHA256}|g" \
  -e "s|@URL@|${URL}|g" \
  "$ROOT_DIR/apps/menubar/Support/quotabar.rb.template" > "$OUTPUT"

if grep -Eq '@(VERSION|SHA256|URL)@' "$OUTPUT"; then
  echo "unresolved Cask template placeholder" >&2
  exit 1
fi
ruby -c "$OUTPUT" >/dev/null
