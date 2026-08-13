#!/bin/bash
# Write a one-item Sparkle appcast for a signed QuotaBar disk image.

set -euo pipefail

VERSION="${1:-}"
BUILD_VERSION="${2:-}"
DMG_NAME="${3:-}"
SIGNATURE="${4:-}"
LENGTH="${5:-}"
OUTPUT="${6:-}"

if [[ -z "$VERSION" || -z "$BUILD_VERSION" || -z "$DMG_NAME" || -z "$SIGNATURE" || -z "$LENGTH" || -z "$OUTPUT" ]]; then
  echo "usage: $0 <version> <build> <dmg-name> <ed-signature> <length> <output-xml>" >&2
  exit 1
fi

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
cat > "$OUTPUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>QuotaBar</title>
    <item>
      <title>QuotaBar ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/gotry-io/Quota/releases/download/menubar-v${VERSION}/${DMG_NAME}"
        sparkle:edSignature="${SIGNATURE}"
        sparkle:os="macos"
        length="${LENGTH}"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
