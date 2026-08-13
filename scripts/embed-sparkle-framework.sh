#!/bin/bash
# Copy Sparkle.framework into a packaged QuotaBar.app and point @rpath at Contents/Frameworks.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH/Contents/MacOS" ]]; then
  echo "usage: $0 /path/to/QuotaBar.app" >&2
  exit 1
fi

FRAMEWORK_SRC="${ROOT_DIR}/apps/menubar/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$FRAMEWORK_SRC" ]]; then
  echo "missing Sparkle.framework; resolve the menubar package first: $FRAMEWORK_SRC" >&2
  exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
cp -R "$FRAMEWORK_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"

BINARY="$APP_PATH/Contents/MacOS/QuotaBar"
if ! otool -l "$BINARY" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY"
fi
