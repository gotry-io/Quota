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

for privacy in \
  apps/ios/Sources/PrivacyInfo.xcprivacy \
  apps/ios/Widgets/PrivacyInfo.xcprivacy
do
  if [ ! -f "$privacy" ]; then
    echo "missing $privacy" >&2
    exit 1
  fi
  plutil -lint "$privacy"
  tracking="$(plutil -extract NSPrivacyTracking raw "$privacy")"
  if [ "$tracking" != "false" ]; then
    echo "$privacy: NSPrivacyTracking must be false, got: $tracking" >&2
    exit 1
  fi
done
