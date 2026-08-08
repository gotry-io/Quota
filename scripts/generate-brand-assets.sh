#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="${ROOT_DIR}/apps/menubar/Support/QuotaBarIcon.svg"
SMALL_SOURCE_SVG="${ROOT_DIR}/apps/menubar/Support/QuotaBarSmallIcon.svg"
OUTPUT_ICNS="${ROOT_DIR}/apps/menubar/Support/QuotaBar.icns"
BRAND_TMP_DIR="$(mktemp -d)"
ICONSET_DIR="${BRAND_TMP_DIR}/QuotaBar.iconset"
SHADOW_SWIFT="${BRAND_TMP_DIR}/bake-icon-shadow.swift"

trap 'rm -rf "$BRAND_TMP_DIR"' EXIT

# Masters are transparent 1024 canvases with an inset rounded brand-surface plate + optical glyph.
# Bake a macOS-style soft drop shadow (as in News/Photos icns) after rasterization,
# because sips does not reliably render SVG filters.
mkdir -p "$ICONSET_DIR"
sips -s format png "$SOURCE_SVG" --out "${BRAND_TMP_DIR}/QuotaBar-raw.png" >/dev/null
sips -s format png "$SMALL_SOURCE_SVG" --out "${BRAND_TMP_DIR}/QuotaBarSmall-raw.png" >/dev/null

cat > "$SHADOW_SWIFT" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("usage: bake-icon-shadow <in.png> <out.png>\n", stderr)
  exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
  let inputImage = NSImage(contentsOf: inputURL),
  let inputTIFF = inputImage.tiffRepresentation,
  let inputRep = NSBitmapImageRep(data: inputTIFF)
else {
  fputs("could not read input icon\n", stderr)
  exit(1)
}

let width = inputRep.pixelsWide
let height = inputRep.pixelsHigh
// Match system app icons: soft contact shadow under the inset plate.
// Values are relative to a 1024 master and scale with the bitmap.
let scale = CGFloat(width) / 1024.0
let shadowBlur = 28.0 * scale
let shadowOffset = CGSize(width: 0.0, height: -10.0 * scale)
let shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.42)

guard
  let outputRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )
else {
  fputs("could not create output bitmap\n", stderr)
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: outputRep) else {
  fputs("could not create graphics context\n", stderr)
  exit(1)
}
NSGraphicsContext.current = context
let cg = context.cgContext
cg.setShouldAntialias(true)
cg.interpolationQuality = .high
cg.clear(CGRect(x: 0, y: 0, width: width, height: height))

// Draw the already-transparent plate image with a CoreGraphics drop shadow.
cg.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor.cgColor)
if let cgImage = inputRep.cgImage {
  cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
} else {
  fputs("could not get CGImage\n", stderr)
  exit(1)
}
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = outputRep.representation(using: .png, properties: [:]) else {
  fputs("could not encode png\n", stderr)
  exit(1)
}
try png.write(to: outputURL)
SWIFT

swift "$SHADOW_SWIFT" \
  "${BRAND_TMP_DIR}/QuotaBar-raw.png" \
  "${BRAND_TMP_DIR}/QuotaBar.png"
swift "$SHADOW_SWIFT" \
  "${BRAND_TMP_DIR}/QuotaBarSmall-raw.png" \
  "${BRAND_TMP_DIR}/QuotaBarSmall.png"

for master in QuotaBar QuotaBarSmall; do
  width="$(sips -g pixelWidth "${BRAND_TMP_DIR}/${master}.png" 2>/dev/null | awk '/pixelWidth:/{print $2}')"
  height="$(sips -g pixelHeight "${BRAND_TMP_DIR}/${master}.png" 2>/dev/null | awk '/pixelHeight:/{print $2}')"
  alpha="$(sips -g hasAlpha "${BRAND_TMP_DIR}/${master}.png" 2>/dev/null | awk '/hasAlpha:/{print $2}')"
  if [[ "$width" != "1024" || "$height" != "1024" ]]; then
    echo "${master} master must be 1024x1024 (got ${width}x${height})." >&2
    exit 1
  fi
  if [[ "$alpha" != "yes" ]]; then
    echo "${master} master must keep transparent margins outside the rounded plate." >&2
    exit 1
  fi
done

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
