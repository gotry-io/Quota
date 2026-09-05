#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

# Optional:
#   QUOTA_IOS_SIMULATOR     dedicated simulator name
#   QUOTA_IOS_TEXT_SIZE     Dynamic Type size (e.g. accessibilityExtraLarge)
#   QUOTA_IOS_APPEARANCE    light | dark
#   QUOTA_IOS_SCREENSHOTS_DIR  override output directory

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
if [ -n "${QUOTA_IOS_SCREENSHOTS_DIR:-}" ]; then
  shots="$QUOTA_IOS_SCREENSHOTS_DIR"
else
  shots="dist/ios-ui-screenshots"
  variant=""
  if [ -n "${QUOTA_IOS_APPEARANCE:-}" ]; then
    variant="$QUOTA_IOS_APPEARANCE"
  fi
  if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
    if [ -n "$variant" ]; then
      variant="$variant-"
    fi
    variant="$variant$QUOTA_IOS_TEXT_SIZE"
  fi
  if [ -n "$variant" ]; then
    shots="dist/ios-ui-screenshots/$variant"
  fi
fi

rm -rf "$result"
if [ "$shots" = "dist/ios-ui-screenshots" ]; then
  mkdir -p "$shots"
  find "$shots" -maxdepth 1 -name '*.png' -delete
else
  rm -rf "$shots"
  mkdir -p "$shots"
fi

# TEST_RUNNER_* in the process environment is forwarded to XCTest with the prefix stripped.
# The files are a second channel if the prefix is not forwarded.
appearance_file=/tmp/quota-ios-uitest-appearance
text_size_file=/tmp/quota-ios-uitest-text-size
: >"$appearance_file"
: >"$text_size_file"
# Never leave an override behind: a stale file would silently re-run every later UI test at
# that size or appearance.
trap 'rm -f "$appearance_file" "$text_size_file"' EXIT
if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
  export TEST_RUNNER_QUOTA_IOS_TEXT_SIZE="$QUOTA_IOS_TEXT_SIZE"
  printf '%s' "$QUOTA_IOS_TEXT_SIZE" >"$text_size_file"
fi
if [ -n "${QUOTA_IOS_APPEARANCE:-}" ]; then
  export TEST_RUNNER_QUOTA_IOS_APPEARANCE="$QUOTA_IOS_APPEARANCE"
  printf '%s' "$QUOTA_IOS_APPEARANCE" >"$appearance_file"
  case "$QUOTA_IOS_APPEARANCE" in
    dark) xcrun simctl ui "$simulator_name" appearance dark >/dev/null 2>&1 || true ;;
    light) xcrun simctl ui "$simulator_name" appearance light >/dev/null 2>&1 || true ;;
  esac
else
  xcrun simctl ui "$simulator_name" appearance light >/dev/null 2>&1 || true
fi

status=0
xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination "platform=iOS Simulator,name=$simulator_name" \
  -only-testing:QuotaUITests \
  -parallel-testing-enabled NO \
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
trap 'rm -rf "$export_dir"; rm -f "$appearance_file" "$text_size_file"' EXIT
xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir"

node -e '
const fs = require("fs");
const path = require("path");
const srcDir = process.argv[1];
const destDir = process.argv[2];
const allowMissing = process.argv[3] === "allow-missing";
const manifestPath = path.join(srcDir, "manifest.json");
if (!fs.existsSync(manifestPath)) {
  console.error("xcresulttool did not write manifest.json");
  process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const wanted = [
  "overview-content",
  "overview-no-devices",
  "overview-empty",
  "overview-cached-error",
  "overview-scrolled",
  "connect-signed-out",
  "connect-connecting",
  "connect-error",
  "connect-expired",
  "connect-refresh-failed",
  "root-loading",
  "confirm-account",
  "usage-content",
  "usage-activity",
  "usage-activity-loading",
  "usage-activity-failed",
  "usage-empty",
  "usage-day",
  "usage-day-empty",
  "usage-day-failed",
  "subscription-detail",
  "devices-content",
  "devices-empty",
  "settings-main",
  "settings-notifications",
  "settings-appearance",
  "settings-about",
];
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
    if (allowMissing) {
      console.error("warning: missing PNG attachment:", name);
      continue;
    }
    console.error("missing PNG attachment:", name);
    process.exit(1);
  }
  fs.copyFileSync(src, path.join(destDir, name + ".png"));
}
' "$export_dir" "$shots" "${QUOTA_IOS_TEXT_SIZE:+allow-missing}"

if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
  missing=""
  for name in connect-signed-out confirm-account overview-content usage-content devices-content subscription-detail settings-main settings-notifications settings-appearance settings-about; do
    if [ ! -f "$shots/$name.png" ]; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    echo "missing accessibility PNG:$missing" >&2
    exit 1
  fi
  exit 0
fi

exit "$status"
