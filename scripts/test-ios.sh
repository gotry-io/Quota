#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

swift test --package-path packages/apple-client

destination='platform=iOS Simulator,name=iPhone 17 Pro'
if ! xcrun simctl list devices available | grep -q 'iPhone 17 Pro'; then
  echo "Skipping Quota iOS tests: iPhone 17 Pro simulator is not available."
  exit 0
fi

xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
