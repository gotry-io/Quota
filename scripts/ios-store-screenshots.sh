#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

shots_root="dist/ios-store-screenshots"
derived="dist/ios-store-derived"
bundle_id="io.gotry.quota"
uitests_src="apps/ios/UITests/QuotaUITests.swift"
wanted_pngs="content usage-content subscription-detail settings no-devices"

find_udid() {
  xcrun simctl list devices available -j | QUOTA_SIM_NAME="$1" node -e '
const fs = require("fs");
const want = process.env.QUOTA_SIM_NAME;
const data = JSON.parse(fs.readFileSync(0, "utf8"));
for (const devices of Object.values(data.devices || {})) {
  for (const device of devices) {
    if (device.isAvailable === false) continue;
    if ((device.name || "") === want) {
      process.stdout.write(device.udid || "");
      process.exit(0);
    }
  }
}
process.exit(1);
'
}

first_iphone() {
  xcrun simctl list devices available -j | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
for (const devices of Object.values(data.devices || {})) {
  for (const device of devices) {
    if (device.isAvailable === false) continue;
    const name = device.name || "";
    if (!name.includes("iPhone")) continue;
    process.stdout.write((device.udid || "") + "\t" + name);
    process.exit(0);
  }
}
process.exit(1);
'
}

visual_fixture_known() {
  name="$1"
  [ -f apps/ios/Sources/VisualFixture.swift ] || return 1
  grep -Eq "\"${name}\"|case ${name}( *=|,|$)" apps/ios/Sources/VisualFixture.swift
}

resolve_slot() {
  slug="$1"
  names_csv="$2"
  first=$(printf "%s" "$names_csv" | cut -d, -f1)
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $names_csv
  IFS=$old_ifs
  for name in "$@"; do
    name=$(printf "%s" "$name" | sed 's/^ *//;s/ *$//')
    [ -n "$name" ] || continue
    udid=$(find_udid "$name" 2>/dev/null || true)
    if [ -n "${udid:-}" ]; then
      printf "%s\t%s" "$udid" "$name"
      if [ "$name" != "$first" ]; then
        printf "\tfallback"
      fi
      printf "\n"
      return 0
    fi
    echo "Skipping $name ($slug): simulator is not available." >&2
  done
  return 1
}

png_count_in() {
  dir="$1"
  found=0
  for name in $wanted_pngs; do
    if [ -f "$dir/$name.png" ] && [ -s "$dir/$name.png" ]; then
      found=$((found + 1))
    fi
  done
  echo "$found"
}

export_xcresult_pngs() {
  result="$1"
  dest="$2"
  export_dir="$(mktemp -d)"
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
const aliases = {
  "content": ["content", "overview-content"],
  "usage-content": ["usage-content"],
  "subscription-detail": ["subscription-detail"],
  "settings": ["settings"],
  "no-devices": ["no-devices", "overview-no-devices"],
};
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const found = new Map();
for (const test of manifest) {
  for (const attachment of test.attachments || []) {
    const raw = attachment.suggestedHumanReadableName || "";
    const stem = raw.replace(/\.png$/i, "").replace(/_\d+$/, "");
    for (const [outName, names] of Object.entries(aliases)) {
      if (found.has(outName)) continue;
      const hit = names.some(
        (n) => raw === n || raw === n + ".png" || raw.startsWith(n + "_") || stem === n,
      );
      if (!hit) continue;
      const src = path.join(srcDir, attachment.exportedFileName);
      if (!fs.existsSync(src)) {
        console.error("missing exported attachment:", src);
        process.exit(1);
      }
      found.set(outName, src);
    }
  }
}
fs.mkdirSync(destDir, { recursive: true });
for (const [name, src] of found) {
  fs.copyFileSync(src, path.join(destDir, name + ".png"));
  console.log("exported", name + ".png");
}
if (found.size === 0) process.exit(2);
' "$export_dir" "$dest"
  rm -rf "$export_dir"
}

capture_uitests() {
  udid="$1"
  dest="$2"
  result="$derived/xcresult-$(basename "$dest").xcresult"
  rm -rf "$result"
  mkdir -p "$dest"
  status=0
  xcodebuild \
    -project apps/ios/Quota.xcodeproj \
    -scheme Quota \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:QuotaUITests \
    -resultBundlePath "$result" \
    -derivedDataPath "$derived" \
    -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    test || status=$?
  if [ ! -d "$result" ]; then
    echo "xcodebuild did not write $result (exit $status)" >&2
    return 1
  fi
  export_status=0
  export_xcresult_pngs "$result" "$dest" || export_status=$?
  if [ "$export_status" -ne 0 ]; then
    echo "No store PNG attachments in $result" >&2
    return 1
  fi
  return 0
}

boot_device() {
  udid="$1"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

screenshot_launch() {
  udid="$1"
  dest="$2"
  fixture="$3"
  png_name="$4"
  note="$5"
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl launch "$udid" "$bundle_id" --visual-fixture "$fixture" >/dev/null
  sleep 5
  xcrun simctl io "$udid" screenshot "$dest/$png_name.png"
  if [ -n "$note" ]; then
    echo "wrote $dest/$png_name.png (fixture $fixture; $note)"
  else
    echo "wrote $dest/$png_name.png (fixture $fixture)"
  fi
}

capture_simctl() {
  udid="$1"
  dest="$2"
  app="$derived/Build/Products/Debug-iphonesimulator/Quota.app"
  if [ ! -d "$app" ]; then
    echo "Building DEBUG Quota.app for simulator $udid" >&2
    xcodebuild \
      -project apps/ios/Quota.xcodeproj \
      -scheme Quota \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$derived" \
      -configuration Debug \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      build
  fi
  if [ ! -d "$app" ]; then
    echo "DEBUG Quota.app missing at $app" >&2
    return 1
  fi
  boot_device "$udid"
  xcrun simctl install "$udid" "$app"
  mkdir -p "$dest"

  if visual_fixture_known content; then
    screenshot_launch "$udid" "$dest" content content ""
  else
    echo "Skipping content: --visual-fixture content is not in VisualFixture.swift" >&2
  fi

  if visual_fixture_known usage-content; then
    screenshot_launch "$udid" "$dest" usage-content usage-content ""
  else
    echo "Skipping usage-content: no Usage screen / fixture on this branch." >&2
  fi

  if visual_fixture_known subscription-detail; then
    screenshot_launch "$udid" "$dest" subscription-detail subscription-detail ""
  else
    echo "Skipping subscription-detail: no subscription detail screen / fixture on this branch." >&2
  fi

  if visual_fixture_known settings; then
    screenshot_launch "$udid" "$dest" settings settings ""
  else
    echo "Skipping settings: no Settings screen / fixture on this branch." >&2
  fi

  if visual_fixture_known no-devices; then
    screenshot_launch "$udid" "$dest" no-devices no-devices ""
  elif visual_fixture_known empty; then
    screenshot_launch "$udid" "$dest" empty no-devices "mapped from empty (no devices[])"
  else
    echo "Skipping no-devices: neither no-devices nor empty fixture exists." >&2
  fi
}

capture_device() {
  udid="$1"
  dest="$2"
  sim_name="$3"
  extra="$4"
  rm -rf "$dest"
  mkdir -p "$dest"
  echo "Capturing $sim_name → $dest${extra:+ ($extra)}"
  captured=0
  if [ -f "$uitests_src" ]; then
    if capture_uitests "$udid" "$dest"; then
      captured=1
    else
      echo "UITests export produced no PNGs for $sim_name; using visual fixtures." >&2
    fi
  fi
  if [ "$captured" -eq 0 ]; then
    capture_simctl "$udid" "$dest"
  fi
}

rm -rf "$shots_root"
mkdir -p "$shots_root"
produced=0
captured_slots=0

capture_slot() {
  slug="$1"
  label="$2"
  names="$3"
  resolved=$(resolve_slot "$slug" "$names" || true)
  if [ -z "$resolved" ]; then
    echo "No simulator available for $label slot ($slug)." >&2
    return 0
  fi
  udid=$(printf "%s" "$resolved" | cut -f1)
  sim_name=$(printf "%s" "$resolved" | cut -f2)
  kind=$(printf "%s" "$resolved" | cut -f3)
  dest="$shots_root/$slug"
  extra=""
  if [ -n "$kind" ]; then
    extra="fallback for $label"
  else
    extra="$label"
  fi
  capture_device "$udid" "$dest" "$sim_name" "$extra"
  count=$(png_count_in "$dest")
  if [ "$count" -gt 0 ]; then
    produced=$((produced + count))
    captured_slots=$((captured_slots + 1))
  else
    echo "No PNGs written for $slug." >&2
  fi
}

capture_slot "iphone-17-pro-max" "6.9 in" "iPhone 17 Pro Max,iPhone 16 Pro Max,iPhone 15 Pro Max"
capture_slot "iphone-17" "6.3 in" "iPhone 17,iPhone 17 Pro,iPhone 16 Pro,iPhone 16"

if [ "$captured_slots" -eq 0 ]; then
  echo "Preferred store simulators missing; trying the first available iPhone." >&2
  pair=$(first_iphone || true)
  if [ -z "$pair" ]; then
    echo "No available iPhone simulator found." >&2
    exit 1
  fi
  udid=$(printf "%s" "$pair" | cut -f1)
  sim_name=$(printf "%s" "$pair" | cut -f2)
  slug=$(printf "%s" "$sim_name" | tr "[:upper:] " "[:lower:]-")
  dest="$shots_root/$slug"
  capture_device "$udid" "$dest" "$sim_name" "last-resort fallback"
  count=$(png_count_in "$dest")
  produced=$((produced + count))
fi

echo "Store screenshot PNGs:"
find "$shots_root" -name "*.png" -print | sort
if [ "$produced" -eq 0 ]; then
  echo "No store screenshot PNGs were produced." >&2
  exit 1
fi
echo "produced=$produced"
exit 0
