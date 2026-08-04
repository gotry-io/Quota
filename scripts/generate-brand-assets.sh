#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="${ROOT_DIR}/apps/menubar/Support/QuotaBarIcon.svg"
SMALL_SOURCE_SVG="${ROOT_DIR}/apps/menubar/Support/QuotaBarSmallIcon.svg"
OUTPUT_ICNS="${ROOT_DIR}/apps/menubar/Support/QuotaBar.icns"
BRAND_TMP_DIR="$(mktemp -d)"
ICONSET_DIR="${BRAND_TMP_DIR}/QuotaBar.iconset"

trap 'rm -rf "$BRAND_TMP_DIR"' EXIT

mkdir -p "$ICONSET_DIR"
sips -s format png "$SOURCE_SVG" --out "${BRAND_TMP_DIR}/QuotaBar.png" >/dev/null
sips -s format png "$SMALL_SOURCE_SVG" --out "${BRAND_TMP_DIR}/QuotaBarSmall.png" >/dev/null

while read -r filename size source; do
  sips -z "$size" "$size" "${BRAND_TMP_DIR}/${source}.png" \
    --out "${ICONSET_DIR}/${filename}" >/dev/null
done <<'SIZES'
icon_16x16.png 16 QuotaBarSmall
icon_16x16@2x.png 32 QuotaBarSmall
icon_32x32.png 32 QuotaBarSmall
icon_32x32@2x.png 64 QuotaBarSmall
icon_128x128.png 128 QuotaBar
icon_128x128@2x.png 256 QuotaBar
icon_256x256.png 256 QuotaBar
icon_256x256@2x.png 512 QuotaBar
icon_512x512.png 512 QuotaBar
icon_512x512@2x.png 1024 QuotaBar
SIZES

iconutil -c icns "$ICONSET_DIR" -o "${BRAND_TMP_DIR}/QuotaBar.icns"
cp "${BRAND_TMP_DIR}/QuotaBar.icns" "$OUTPUT_ICNS"

printf '%s\n' "$OUTPUT_ICNS"
