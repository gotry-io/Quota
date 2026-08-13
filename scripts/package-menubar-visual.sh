#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIR}/dist/menubar-visual}"
VERSION="$(plutil -extract CFBundleShortVersionString raw "${ROOT_DIR}/apps/menubar/Support/Info.plist")"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="${OUTPUT_DIR}/QuotaBarVisual.app"

cd "$ROOT_DIR"
QUOTABAR_VERSION="$VERSION" cargo build --locked --package quota-menubar-helper
swift build \
  --package-path apps/menubar \
  --configuration debug \
  --arch arm64 \
  --product QuotaBar \
  -Xswiftc -DVISUAL_TEST

SWIFT_BIN_DIR="$(
  swift build \
    --package-path apps/menubar \
    --configuration debug \
    --arch arm64 \
    --show-bin-path
)"
APP_BINARY="${SWIFT_BIN_DIR}/QuotaBar"
HELPER_BINARY="${ROOT_DIR}/target/debug/quota-menubar-helper"

for binary in "$APP_BINARY" "$HELPER_BINARY"; do
  if [[ ! -x "$binary" ]]; then
    echo "missing executable: $binary" >&2
    exit 1
  fi
  if [[ "$(lipo -archs "$binary")" != "arm64" ]]; then
    echo "expected an arm64-only executable: $binary" >&2
    exit 1
  fi
done

rm -rf "$APP_PATH"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Helpers" \
  "$APP_PATH/Contents/Resources/BrandIcons"

cp "$APP_BINARY" "$APP_PATH/Contents/MacOS/QuotaBar"
cp "$HELPER_BINARY" "$APP_PATH/Contents/Helpers/quota-service"
chmod +x "${ROOT_DIR}/scripts/embed-sparkle-framework.sh"
"${ROOT_DIR}/scripts/embed-sparkle-framework.sh" "$APP_PATH"
cp apps/menubar/Support/Info.plist "$APP_PATH/Contents/Info.plist"
cp apps/menubar/Support/QuotaBar.icns "$APP_PATH/Contents/Resources/QuotaBar.icns"
cp apps/menubar/Sources/QuotaBar/Resources/BrandIcons/*.svg \
  "$APP_PATH/Contents/Resources/BrandIcons/"
cp apps/menubar/Sources/QuotaBar/Resources/THIRD_PARTY_NOTICES.md \
  "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"

plutil -replace CFBundleDisplayName -string "QuotaBar Visual QA" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "io.gotry.quotabar.visualtest" \
  "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "QuotaBar Visual QA" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "1" "$APP_PATH/Contents/Info.plist"
plutil -replace LSUIElement -bool false "$APP_PATH/Contents/Info.plist"

chmod 755 "$APP_PATH/Contents/MacOS/QuotaBar" "$APP_PATH/Contents/Helpers/quota-service"
chmod +x "${ROOT_DIR}/scripts/sign-sparkle-framework.sh"
"${ROOT_DIR}/scripts/sign-sparkle-framework.sh" "$APP_PATH" "-"
codesign --force --sign - "$APP_PATH/Contents/Helpers/quota-service"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/Helpers/quota-service"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

printf '%s\n' "$APP_PATH"
