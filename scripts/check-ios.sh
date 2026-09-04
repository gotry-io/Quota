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
if grep -F '"1,2"' apps/ios/project.yml >/dev/null; then
  echo 'apps/ios/project.yml still targets iPad (TARGETED_DEVICE_FAMILY "1,2").' >&2
  exit 1
fi
