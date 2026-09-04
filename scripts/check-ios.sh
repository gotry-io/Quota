#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
./scripts/generate-ios.sh
swift build --package-path packages/apple-client
xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination 'generic/platform=iOS Simulator' \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
./scripts/check-ios-assets.sh
