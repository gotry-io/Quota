#!/bin/bash
# Sign Sparkle.framework inside a packaged QuotaBar.app (inside-out).

set -euo pipefail

APP_PATH="${1:-}"
IDENTITY="${2:--}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "usage: $0 /path/to/QuotaBar.app [codesign-identity]" >&2
  exit 1
fi

FRAMEWORK_B="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_item() {
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$1"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
  fi
}

sign_item "$FRAMEWORK_B/XPCServices/Downloader.xpc"
sign_item "$FRAMEWORK_B/XPCServices/Installer.xpc"
sign_item "$FRAMEWORK_B/Updater.app"
sign_item "$FRAMEWORK_B/Autoupdate"
sign_item "$APP_PATH/Contents/Frameworks/Sparkle.framework"
