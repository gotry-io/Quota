#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?version is required}"
APP_PATH="${2:-${ROOT_DIR}/dist/menubar/QuotaBar.app}"
OUTPUT="${3:-${ROOT_DIR}/dist/release/QuotaBar-${VERSION}-macos-arm64.dmg}"
VOLUME_NAME="QuotaBar ${VERSION}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "missing QuotaBar.app: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/QuotaBar"
cp -R "$APP_PATH" "$STAGE/QuotaBar/QuotaBar.app"
ln -s /Applications "$STAGE/QuotaBar/Applications"

rm -f "$OUTPUT"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE/QuotaBar" \
  -ov \
  -format UDZO \
  "$OUTPUT" >/dev/null
chmod 644 "$OUTPUT"
printf '%s\n' "$OUTPUT"
