#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

# The app embeds packages/apple-client, so a local run tests it first. In CI the macOS `verify`
# job already runs every Swift package once (scripts/test-swift.sh); QUOTA_IOS_SKIP_PACKAGE_TESTS=1
# lets the two iOS jobs skip that second and third compile of the same package.
if [ "${QUOTA_IOS_SKIP_PACKAGE_TESTS:-}" = "1" ]; then
  echo "test-ios: skipping packages/apple-client tests (QUOTA_IOS_SKIP_PACKAGE_TESTS=1)"
else
  swift test --package-path packages/apple-client
fi

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

# Which iPhone, when several are available. The runtime and the model decide how the app lays
# out and what the accessibility auditor reports, so "whichever the list happened to put
# first" is a difference between two runs that nothing records. First match wins; anything
# unlisted is ordered by name so the choice stays the same on a machine that has none of these.
PREFERRED = (
    "iPhone 17 Pro",
    "iPhone 17",
    "iPhone 16 Pro",
    "iPhone 16",
    "iPhone 15 Pro",
    "iPhone 15",
)


def preference(name):
    try:
        return (0, PREFERRED.index(name), name)
    except ValueError:
        return (1, 0, name)


def emit(row):
    version = ".".join(str(part) for part in row[0])
    sys.stderr.write("Using iOS Simulator: %s on iOS %s (%s)\n" % (row[1], version, row[2]))
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
    emit(min((row for row in matched if row[0] == latest), key=lambda row: row[2]))
    sys.exit(0)

iphones = [row for row in rows if "iPhone" in row[1]]
if not iphones:
    sys.stderr.write(
        "Quota iOS tests require an available iPhone simulator; none were listed by "
        "`xcrun simctl list devices available`.\n"
    )
    sys.exit(1)

latest = max(row[0] for row in iphones)
newest = [row for row in iphones if row[0] == latest]
emit(min(newest, key=lambda row: preference(row[1])))
'
)"

if [ -z "$udid" ]; then
  echo "Quota iOS tests failed to select an iOS Simulator." >&2
  exit 1
fi

# The toolchain is part of the result: a layout or an audit that differs between two machines is
# usually this line differing, and a log that never said it cannot tell anyone that.
xcodebuild -version | tr '\n' ' '
echo


destination="platform=iOS Simulator,id=$udid"

# QUOTA_IOS_ONLY_TESTING names a target, or a target/class ("QuotaUITests/QuotaSmokeUITests"), so
# CI can run the unit tests, the required journeys and the advisory screen census separately;
# unset, the whole scheme runs as before.
only_testing=()
if [ -n "${QUOTA_IOS_ONLY_TESTING:-}" ]; then
  only_testing=("-only-testing:${QUOTA_IOS_ONLY_TESTING}")
fi

# QUOTA_IOS_RESULT_BUNDLE is the xcresult path (CI's verify-ios-ui and local audit summary).
result_args=()
if [ -n "${QUOTA_IOS_RESULT_BUNDLE:-}" ]; then
  mkdir -p "$(dirname -- "$QUOTA_IOS_RESULT_BUNDLE")"
  rm -rf -- "$QUOTA_IOS_RESULT_BUNDLE"
  result_args=(-resultBundlePath "$QUOTA_IOS_RESULT_BUNDLE")
fi

# The runner reads the appearance and the text size it should launch with. TEST_RUNNER_* reaches
# XCTest's environment; the files beside them are the fallback when a runner strips that prefix,
# the same two channels scripts/ios-ui-screenshots.sh uses. Both are cleared on exit so a later
# run on this machine cannot inherit them.
appearance_file=/tmp/quota-ios-uitest-appearance
text_size_file=/tmp/quota-ios-uitest-text-size
if [ -n "${QUOTA_IOS_APPEARANCE:-}" ] || [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
  : >"$appearance_file"
  : >"$text_size_file"
  trap 'rm -f "$appearance_file" "$text_size_file"' EXIT INT TERM
  if [ -n "${QUOTA_IOS_APPEARANCE:-}" ]; then
    TEST_RUNNER_QUOTA_IOS_APPEARANCE="$QUOTA_IOS_APPEARANCE"
    export TEST_RUNNER_QUOTA_IOS_APPEARANCE
    printf '%s' "$QUOTA_IOS_APPEARANCE" >"$appearance_file"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    xcrun simctl ui "$udid" appearance "$QUOTA_IOS_APPEARANCE" >/dev/null 2>&1 || true
  fi
  if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
    TEST_RUNNER_QUOTA_IOS_TEXT_SIZE="$QUOTA_IOS_TEXT_SIZE"
    export TEST_RUNNER_QUOTA_IOS_TEXT_SIZE
    printf '%s' "$QUOTA_IOS_TEXT_SIZE" >"$text_size_file"
  fi
fi

xcodebuild \
  -project apps/ios/Quota.xcodeproj \
  -scheme Quota \
  -destination "$destination" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ${only_testing[@]+"${only_testing[@]}"} \
  ${result_args[@]+"${result_args[@]}"} \
  test
