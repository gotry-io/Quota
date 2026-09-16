#!/bin/bash
# Run every Swift package's tests, smallest first so a shared-layer break reports before the app.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for package in packages/apple-shared packages/apple-client apps/menubar; do
  echo "swift test --package-path $package"
  swift test --package-path "$package"
done

# The Visual QA matrix renders every QuotaBar route and would starve the app's wait-loop tests
# if it ran inside the parallel suite above, so it runs alone, afterwards, with capture on.
SHOTS_DIR="${QUOTABAR_SCREENSHOTS:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/quotabar-screenshots}"
echo "QUOTABAR_SCREENSHOTS=$SHOTS_DIR swift test --package-path apps/menubar --filter VisualMatrixScreenshotTests"
QUOTABAR_SCREENSHOTS="$SHOTS_DIR" swift test --package-path apps/menubar --filter VisualMatrixScreenshotTests
