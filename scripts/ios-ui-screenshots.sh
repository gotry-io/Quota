#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

# Optional:
#   QUOTA_IOS_SIMULATOR     dedicated simulator name
#   QUOTA_IOS_TEXT_SIZE     Dynamic Type size (e.g. accessibilityExtraLarge)
#   QUOTA_IOS_APPEARANCE    light | dark
#   QUOTA_IOS_SCREENSHOTS_DIR  override output directory

# One selection for the whole repo: the screenshot and the test that audits the same screen
# are taken on the same device. QUOTA_IOS_SIMULATOR still pins the model.
simulator_name="$(python3 scripts/ios-simulator.py name)"

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
# `simctl ui` only reaches a booted device; against a shut-down one it fails, and with the
# `|| true` below that failure used to leave a "dark" run rendering light.
xcrun simctl boot "$simulator_name" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_name" -b >/dev/null 2>&1 || true
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
  -only-testing:QuotaUITests/QuotaScreenUITests \
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

# The census names every capture in one place; this reads that list rather than keeping a second
# copy that goes stale whenever a screen is renamed.
screen_names="$(
  grep -o 'attachScreenshot(app, name: "[a-z0-9-]*"' apps/ios/UITests/QuotaScreenUITests.swift \
    | sed 's/.*name: "//;s/"//' | sort -u | paste -sd, -
)"
if [ -z "$screen_names" ]; then
  echo "Could not read the screen names from apps/ios/UITests/QuotaScreenUITests.swift" >&2
  exit 1
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
const wanted = process.argv[4].split(",").filter(Boolean);
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
' "$export_dir" "$shots" "${QUOTA_IOS_TEXT_SIZE:+allow-missing}" "$screen_names"

if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
  missing=""
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $screen_names
  IFS=$old_ifs
  for name in "$@"; do
    if [ ! -f "$shots/$name.png" ]; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    echo "missing accessibility PNG:$missing" >&2
    exit 1
  fi
fi

exit "${status:-0}"
