#!/bin/bash

# Package QuotaBar.app from apps/menubar/QuotaBar.xcodeproj, with its widget extension in
# Contents/PlugIns and the private Rust service in Contents/Helpers.
#
# With QUOTABAR_SIGNING_IDENTITY set to a Developer ID Application identity, this archives and
# exports through apps/menubar/ExportOptions.plist, so the app, its extension, and Sparkle carry
# that signature and the App Group entitlement. Without it, the archive is unsigned and the
# result is ad-hoc signed inside-out so a local build still launches — an ad-hoc signature
# carries no entitlements, so those builds publish no widget snapshot.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw "${ROOT_DIR}/apps/menubar/Support/Info.plist")}"
BUILD_NUMBER="${2:-1}"
OUTPUT_DIR="${3:-${ROOT_DIR}/dist/menubar}"

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$'; then
  echo "invalid version: $VERSION" >&2
  exit 1
fi
if ! printf '%s' "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
  echo "invalid build number: $BUILD_NUMBER" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="${OUTPUT_DIR}/QuotaBar.app"
if [[ "$APP_PATH" != */dist/menubar/QuotaBar.app && "$OUTPUT_DIR" == "$ROOT_DIR" ]]; then
  echo "refusing to package over the repository root" >&2
  exit 1
fi

cd "$ROOT_DIR"
PROJECT="apps/menubar/QuotaBar.xcodeproj"
if [[ ! -d "$PROJECT" ]]; then
  echo "missing $PROJECT; run pnpm generate:menubar" >&2
  exit 1
fi

QUOTABAR_VERSION="$VERSION" cargo build --locked --release --package quota-menubar-helper
cargo build --locked --release --package quota-service --bin quota
HELPER_BINARY="${ROOT_DIR}/target/release/quota-menubar-helper"
COMMAND_BINARY="${ROOT_DIR}/target/release/quota"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-package.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
ARCHIVE_PATH="${BUILD_ROOT}/QuotaBar.xcarchive"

SIGNING_IDENTITY="${QUOTABAR_SIGNING_IDENTITY:-}"
xcodebuild_args=(
  -project "$PROJECT"
  -scheme QuotaBar
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "${BUILD_ROOT}/DerivedData"
  # On the command line so the Swift package projects build one slice too, not just this project's
  # targets. QuotaBar ships Apple Silicon only.
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ -n "$SIGNING_IDENTITY" ]]; then
  # DEVELOPMENT_TEAM goes on the command line as well as through the project's variable: the
  # Swift package resource bundles (SweetCookieKit's) are signed by this archive too, take no
  # settings from project.yml, and refuse to sign without a team.
  xcodebuild_args+=(
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM=86Y537ZF24
    QUOTABAR_DEVELOPMENT_TEAM=86Y537ZF24
  )
else
  xcodebuild_args+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    CODE_SIGN_ENTITLEMENTS=""
  )
fi
xcodebuild "${xcodebuild_args[@]}" archive

rm -rf "$APP_PATH"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist apps/menubar/ExportOptions.plist \
    -exportPath "${BUILD_ROOT}/export"
  cp -R "${BUILD_ROOT}/export/QuotaBar.app" "$APP_PATH"
else
  cp -R "${ARCHIVE_PATH}/Products/Applications/QuotaBar.app" "$APP_PATH"
fi

APPEX_PATH="$APP_PATH/Contents/PlugIns/QuotaBarWidgets.appex"
for required in "$APP_PATH/Contents/MacOS/QuotaBar" "$APPEX_PATH" \
  "$APP_PATH/Contents/Frameworks/Sparkle.framework"; do
  if [[ ! -e "$required" ]]; then
    echo "missing from the exported app: $required" >&2
    exit 1
  fi
done

mkdir -p "$APP_PATH/Contents/Helpers"
cp "$HELPER_BINARY" "$APP_PATH/Contents/Helpers/quota-service"
# The public command ships beside the private service, in the same bundle and signed the same
# way, so what a person symlinks onto their PATH is the build QuotaBar is running.
cp "$COMMAND_BINARY" "$APP_PATH/Contents/Helpers/quota"
chmod 755 "$APP_PATH/Contents/MacOS/QuotaBar" "$APP_PATH/Contents/Helpers/quota-service" \
  "$APP_PATH/Contents/Helpers/quota"

for binary in "$APP_PATH/Contents/MacOS/QuotaBar" "$APP_PATH/Contents/Helpers/quota-service" \
  "$APP_PATH/Contents/Helpers/quota"; do
  if [[ "$(lipo -archs "$binary")" != "arm64" ]]; then
    echo "expected an arm64-only executable: $binary" >&2
    exit 1
  fi
done

# The app's version is Info.plist's, not a build setting's, so the released bundle says what
# apps/menubar/Support/Info.plist says. The extension follows it.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APPEX_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APPEX_PATH/Contents/Info.plist"

# Editing Info.plist and adding the helper invalidate what xcodebuild signed, so the app is
# always re-signed here, inside-out.
if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$APP_PATH/Contents/Helpers/quota-service"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$APP_PATH/Contents/Helpers/quota"
  codesign --force --options runtime --timestamp \
    --entitlements apps/menubar/Widgets/QuotaBarWidgets.entitlements \
    --sign "$SIGNING_IDENTITY" "$APPEX_PATH"
  codesign --force --options runtime --timestamp \
    --entitlements apps/menubar/Support/QuotaBar.entitlements \
    --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  # Keep local packages launchable. A release replaces these signatures with Developer ID.
  # An ad-hoc signature's designated requirement is the build's cdhash, so macOS treats every
  # rebuild as a new app: Full Disk Access, Removable Volumes, and the Chrome Safe Storage
  # Keychain ACL are asked for again. Set QUOTABAR_CODESIGN_IDENTITY to a self-signed
  # code-signing certificate from Keychain Access to keep those grants across local builds.
  CODESIGN_IDENTITY="${QUOTABAR_CODESIGN_IDENTITY:--}"
  chmod +x "${ROOT_DIR}/scripts/sign-sparkle-framework.sh"
  "${ROOT_DIR}/scripts/sign-sparkle-framework.sh" "$APP_PATH" "$CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP_PATH/Contents/Helpers/quota-service"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP_PATH/Contents/Helpers/quota"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APPEX_PATH"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/Helpers/quota-service"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/Helpers/quota"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

printf '%s\n' "$APP_PATH"
