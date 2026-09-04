#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

if [ -n "${QUOTA_IOS_SIMULATOR:-}" ]; then
  simulator_name="$QUOTA_IOS_SIMULATOR"
else
  simulator_name="$(
    xcrun simctl list devices available -j | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
for (const devices of Object.values(data.devices || {})) {
  for (const device of devices) {
    if (device.isAvailable === false) continue;
    const name = device.name || "";
    if (!name.includes("iPhone")) continue;
    process.stdout.write(name);
    process.exit(0);
  }
}
process.exit(1);
'
  )" || simulator_name=""
  if [ -z "$simulator_name" ]; then
    echo "No available iPhone simulator found." >&2
    exit 1
  fi
fi

result="dist/ios-ui.xcresult"
shots="dist/ios-ui-screenshots"
rm -rf "$result" "$shots"
mkdir -p "$shots"

status=0
xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination "platform=iOS Simulator,name=$simulator_name" \
  -only-testing:QuotaUITests \
  -resultBundlePath "$result" \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test || status=$?

if [ ! -d "$result" ]; then
  echo "xcodebuild did not write $result" >&2
  exit "${status:-1}"
fi

export_dir="$(mktemp -d)"
trap 'rm -rf "$export_dir"' EXIT
xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir"

node -e '
const fs = require("fs");
const path = require("path");
const srcDir = process.argv[1];
const destDir = process.argv[2];
const manifestPath = path.join(srcDir, "manifest.json");
if (!fs.existsSync(manifestPath)) {
  console.error("xcresulttool did not write manifest.json");
  process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const wanted = ["overview-content", "overview-no-devices", "connect-signed-out", "confirm-account", "usage-content", "usage-activity", "subscription-detail", "settings"];
const found = new Map();
for (const test of manifest) {
  for (const attachment of test.attachments || []) {
    const raw = attachment.suggestedHumanReadableName || "";
    const name = wanted.find(
      (candidate) =>
        raw === candidate ||
        raw === candidate + ".png" ||
        raw.startsWith(candidate + "_")
    );
    if (!name) continue;
    const src = path.join(srcDir, attachment.exportedFileName);
    if (!fs.existsSync(src)) {
      console.error("missing exported attachment:", src);
      process.exit(1);
    }
    if (!found.has(name)) found.set(name, src);
  }
}
for (const name of wanted) {
  const src = found.get(name);
  if (!src) {
    console.error("missing PNG attachment:", name);
    process.exit(1);
  }
  fs.copyFileSync(src, path.join(destDir, name + ".png"));
}
' "$export_dir" "$shots"

exit "$status"
