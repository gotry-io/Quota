#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

iconset="apps/ios/Resources/Assets.xcassets/AppIcon.appiconset"
contents="$iconset/Contents.json"

if [ ! -f "$contents" ]; then
  echo "missing $contents" >&2
  exit 1
fi

# Walk images[] in Contents.json: every entry must name an existing file.
node --input-type=module <<'NODE'
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const iconset = "apps/ios/Resources/Assets.xcassets/AppIcon.appiconset";
const contentsPath = path.join(iconset, "Contents.json");
const json = JSON.parse(readFileSync(contentsPath, "utf8"));
const images = json.images;
if (!Array.isArray(images) || images.length === 0) {
  console.error(`${contentsPath}: images[] must be a non-empty array`);
  process.exit(1);
}

let failed = false;
for (const [index, image] of images.entries()) {
  const filename = image?.filename;
  if (typeof filename !== "string" || filename.length === 0) {
    console.error(`${contentsPath}: images[${index}] is missing filename`);
    failed = true;
    continue;
  }
  const filePath = path.join(iconset, filename);
  if (!existsSync(filePath)) {
    console.error(`${contentsPath}: images[${index}] filename does not exist: ${filePath}`);
    failed = true;
  }
}
if (failed) {
  process.exit(1);
}
NODE

check_png() {
  file="$1"
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth:/{print $2}')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight:/{print $2}')"
  alpha="$(sips -g hasAlpha "$file" | awk '/hasAlpha:/{print $2}')"
  if [ "$width" != "1024" ] || [ "$height" != "1024" ]; then
    echo "$file must be 1024x1024 (got ${width}x${height})." >&2
    exit 1
  fi
  if [ "$alpha" != "no" ]; then
    echo "$file must have hasAlpha: no (got ${alpha})." >&2
    exit 1
  fi
}

for png in "$iconset"/*.png; do
  check_png "$png"
done

check_export_compliance() {
  plist="$1"
  if [ ! -f "$plist" ]; then
    echo "missing $plist" >&2
    exit 1
  fi
  value="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist")"
  if [ "$value" != "false" ]; then
    echo "$plist ITSAppUsesNonExemptEncryption must be false (got ${value})." >&2
    exit 1
  fi
}

check_export_compliance "apps/ios/Sources/Info.plist"
check_export_compliance "apps/ios/Widgets/Info.plist"
