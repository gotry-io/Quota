#!/bin/bash
# Run every Swift package's tests, smallest first so a shared-layer break reports before the app.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for package in packages/apple-shared packages/apple-client apps/menubar; do
  echo "swift test --package-path $package"
  swift test --package-path "$package"
done
