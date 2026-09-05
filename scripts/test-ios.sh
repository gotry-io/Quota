#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

swift test --package-path packages/apple-client

if ! command -v python3 >/dev/null 2>&1; then
  echo "Quota iOS tests require python3 to select an iOS Simulator." >&2
  exit 1
fi

udid="$(
  xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    sys.stderr.write(
        "Quota iOS tests failed to parse `xcrun simctl list devices available -j`: %s\n" % exc
    )
    sys.exit(1)

override = os.environ.get("QUOTA_IOS_SIMULATOR")
if override is not None:
    override = override.strip() or None

runtime_devices = data.get("devices") or {}
rows = []
for runtime, devices in runtime_devices.items():
    match = re.search(r"iOS[- ](\d+)(?:[.-](\d+))?(?:[.-](\d+))?", runtime)
    if not match:
        continue
    version = tuple(int(part) if part else 0 for part in match.groups())
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name") or ""
        udid = device.get("udid") or ""
        if not name or not udid:
            continue
        rows.append((version, name, udid))

def emit(row):
    sys.stderr.write("Using iOS Simulator: %s (%s)\n" % (row[1], row[2]))
    sys.stdout.write("%s\n" % row[2])

if override is not None:
    matched = [row for row in rows if row[1] == override]
    if not matched:
        sys.stderr.write(
            "Quota iOS tests require simulator %r (QUOTA_IOS_SIMULATOR); it is not available.\n"
            % (override,)
        )
        names = sorted({row[1] for row in rows})
        if names:
            sys.stderr.write("Available simulators: %s\n" % ", ".join(names))
        else:
            sys.stderr.write("No available iOS simulators were listed.\n")
        sys.exit(1)
    latest = max(row[0] for row in matched)
    for row in matched:
        if row[0] == latest:
            emit(row)
            break
    sys.exit(0)

iphones = [row for row in rows if "iPhone" in row[1]]
if not iphones:
    sys.stderr.write(
        "Quota iOS tests require an available iPhone simulator; none were listed by "
        "`xcrun simctl list devices available`.\n"
    )
    sys.exit(1)

latest = max(row[0] for row in iphones)
for row in iphones:
    if row[0] == latest:
        emit(row)
        break
'
)"

if [ -z "$udid" ]; then
  echo "Quota iOS tests failed to select an iOS Simulator." >&2
  exit 1
fi

destination="platform=iOS Simulator,id=$udid"

xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination "$destination" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
