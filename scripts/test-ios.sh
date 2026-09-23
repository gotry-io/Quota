#!/bin/bash
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Quota iOS tests require python3 to select Xcode and an iOS Simulator." >&2
  exit 1
fi

# The run's configuration is a tuple — Xcode, runtime, device, text size, appearance — chosen
# explicitly and printed, because each of them changes the layout the tests see and the audits
# report. QUOTA_IOS_XCODE, QUOTA_IOS_RUNTIME and QUOTA_IOS_SIMULATOR pin the first three;
# otherwise scripts/ios-simulator.py chooses the newest Xcode, the newest runtime, and the first
# preferred model on it. The UI tests launch at the standard size (`large`) and light appearance
# unless QUOTA_IOS_TEXT_SIZE / QUOTA_IOS_APPEARANCE name a profile.
DEVELOPER_DIR="$(python3 scripts/ios-simulator.py xcode)"
export DEVELOPER_DIR
tuple="$(python3 scripts/ios-simulator.py tuple)"
IFS="$(printf '\t')" read -r udid simulator_name runtime_version runtime_build <<EOF_TUPLE
$tuple
EOF_TUPLE

if [ -z "${udid:-}" ]; then
  echo "Quota iOS tests failed to select an iOS Simulator." >&2
  exit 1
fi

xcode_line="$(xcodebuild -version | paste -sd ' ' -)"
configuration="Xcode: $xcode_line ($DEVELOPER_DIR)
Runtime: iOS $runtime_version ($runtime_build)
Device: $simulator_name ($udid)
Text size: ${QUOTA_IOS_TEXT_SIZE:-large (standard)}
Appearance: ${QUOTA_IOS_APPEARANCE:-light}
Selection: ${QUOTA_IOS_ONLY_TESTING:-whole scheme}"

destination="platform=iOS Simulator,id=$udid"

# The app embeds packages/apple-client, so a local run tests it first. In CI the macOS `verify`
# job already runs every Swift package once (scripts/test-swift.sh); QUOTA_IOS_SKIP_PACKAGE_TESTS=1
# lets the two iOS jobs skip that second and third compile of the same package.
if [ "${QUOTA_IOS_SKIP_PACKAGE_TESTS:-}" = "1" ]; then
  echo "test-ios: skipping packages/apple-client tests (QUOTA_IOS_SKIP_PACKAGE_TESTS=1)"
else
  swift test --package-path packages/apple-client
fi

# QUOTA_IOS_ONLY_TESTING names a target, or a target/class ("QuotaUITests/QuotaSmokeUITests"), so
# CI can run the unit tests, the required journeys and the advisory screen census separately;
# unset, the whole scheme runs as before.
only_testing=()
if [ -n "${QUOTA_IOS_ONLY_TESTING:-}" ]; then
  only_testing=("-only-testing:${QUOTA_IOS_ONLY_TESTING}")
fi

# QUOTA_IOS_RESULT_BUNDLE is the xcresult path (CI's verify-ios-ui and local audit summary).
result_args=()
log_path=""
if [ -n "${QUOTA_IOS_RESULT_BUNDLE:-}" ]; then
  mkdir -p "$(dirname -- "$QUOTA_IOS_RESULT_BUNDLE")"
  rm -rf -- "$QUOTA_IOS_RESULT_BUNDLE"
  result_args=(-resultBundlePath "$QUOTA_IOS_RESULT_BUNDLE")
  # The run's own log beside its bundle. The tests print one line per interaction they had to
  # repeat, and a job summary counts those lines without opening the bundle.
  bundle_path="${QUOTA_IOS_RESULT_BUNDLE%/}"
  log_path="${bundle_path%.xcresult}.log"
  : >"$log_path"
fi

# The simulator is booted, and has finished booting, before any test launches the app. Left to
# `xcodebuild`, it boots lazily when the first test asks for the app, and that first launch races
# the system coming up: on a cold CI runner it timed out ("Failed to launch") after most of a
# minute and took the next test down with it, while every test after them passed. The screen census
# never saw this only because setting an appearance happened to boot the simulator first.
# `bootstatus -b` returns once the boot, including data migration, is complete.
xcrun simctl boot "$udid" >/dev/null 2>&1 || true
if ! xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1; then
  echo "Quota iOS tests could not confirm that simulator $udid finished booting." >&2
  exit 1
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
    xcrun simctl ui "$udid" appearance "$QUOTA_IOS_APPEARANCE" >/dev/null 2>&1 || true
  fi
  if [ -n "${QUOTA_IOS_TEXT_SIZE:-}" ]; then
    TEST_RUNNER_QUOTA_IOS_TEXT_SIZE="$QUOTA_IOS_TEXT_SIZE"
    export TEST_RUNNER_QUOTA_IOS_TEXT_SIZE
    printf '%s' "$QUOTA_IOS_TEXT_SIZE" >"$text_size_file"
  fi
fi

# The runner's SwiftPM caches can be left corrupt by an earlier job ("disk I/O error" reading
# the cached manifest database), and then every xcodebuild on the machine fails before a test
# runs. Resolving first, and once more from clean caches when that fails, makes that a one-line
# note in the log instead of a red merge-group run.
resolve_packages() {
  xcodebuild \
    -project apps/ios/Quota.xcodeproj \
    -scheme Quota \
    -destination "$destination" \
    -resolvePackageDependencies
}
if ! resolve_packages; then
  echo "test-ios: package resolution failed; clearing SwiftPM caches and resolving once more" >&2
  rm -rf "$HOME/Library/Caches/org.swift.swiftpm" \
    "$HOME/Library/org.swift.swiftpm" \
    "$HOME"/Library/Developer/Xcode/DerivedData/Quota-*/SourcePackages
  resolve_packages
fi

# The configuration goes to the job's step summary as well as the log, so two runs that disagree
# can be told apart without opening either bundle.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### iOS test configuration"
    echo ""
    printf '%s\n' "$configuration" | sed 's/^/- /'
    echo ""
  } >>"$GITHUB_STEP_SUMMARY"
fi

run_xcodebuild() {
  # The toolchain and the simulator are part of the result: a layout or an audit that differs
  # between two machines is usually these lines differing. They are printed here, inside whatever
  # the run's log captures, rather than before it.
  printf 'iOS test configuration\n%s\n' "$configuration"
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
}

if [ -n "$log_path" ]; then
  set -o pipefail
  run_xcodebuild 2>&1 | tee "$log_path"
else
  run_xcodebuild
fi
