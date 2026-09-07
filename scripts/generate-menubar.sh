#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to generate apps/menubar/QuotaBar.xcodeproj" >&2
  exit 1
fi
xcodegen generate --spec apps/menubar/project.yml --project apps/menubar
