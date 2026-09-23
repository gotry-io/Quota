#!/usr/bin/env python3
"""Which Xcode and iOS Simulator the Quota tests and screenshots run on.

The Xcode, the model and the runtime decide how the app lays out and what the accessibility
auditor reports, so "whichever one happened to be default or listed first" is a difference between
two runs that nothing records. One answer, used by scripts/test-ios.sh,
scripts/ios-ui-screenshots.sh and scripts/ios-store-screenshots.sh, so a screenshot and the test
that audits the same screen are taken on the same device.

Usage: ios-simulator.py [udid|name|tuple|xcode]     (default: udid)
  udid | name   the chosen simulator
  tuple         one tab-separated line: udid, name, runtime version, runtime build
  xcode         the Developer directory of the chosen Xcode

  QUOTA_IOS_XCODE=<Xcode.app or its Developer dir>  pins the Xcode; otherwise the newest
                                                   /Applications/Xcode*.app by version.
  QUOTA_IOS_RUNTIME=<version, e.g. 26.3>            pins the runtime (a prefix of its version);
                                                   otherwise the newest available.
  QUOTA_IOS_SIMULATOR=<device name>                 pins the device; otherwise the first
                                                   PREFERRED model on the chosen runtime.
"""

import glob
import json
import os
import plistlib
import re
import subprocess
import sys

# First match wins. Anything unlisted sorts after these, newest-looking name first, so a runner
# image that drops every preferred model still chooses the same device twice running.
PREFERRED = (
    "iPhone 17 Pro",
    "iPhone 17",
    "iPhone 16 Pro",
    "iPhone 16",
    "iPhone 15 Pro",
    "iPhone 15",
)


def fail(message):
    sys.stderr.write(message + "\n")
    raise SystemExit(1)


def version_key(text):
    return tuple(int(part) for part in re.findall(r"\d+", text or ""))


def preference(name):
    try:
        return (0, PREFERRED.index(name), [])
    except ValueError:
        return (1, 0, [-ord(c) for c in name])


def xcode_version(developer_dir):
    """(short version, build) of the Xcode that owns a Developer directory."""
    plist = os.path.join(os.path.dirname(developer_dir), "version.plist")
    try:
        with open(plist, "rb") as handle:
            data = plistlib.load(handle)
    except OSError:
        return None
    return data.get("CFBundleShortVersionString") or "", data.get("ProductBuildVersion") or ""


def choose_xcode():
    override = (os.environ.get("QUOTA_IOS_XCODE") or "").strip()
    if override:
        developer = override
        if developer.endswith(".app") or developer.endswith(".app/"):
            developer = os.path.join(developer.rstrip("/"), "Contents", "Developer")
        if xcode_version(developer) is None:
            fail("Xcode %r (QUOTA_IOS_XCODE) is not an installed Xcode." % override)
        return developer
    found = []
    for app in glob.glob("/Applications/Xcode*.app"):
        developer = os.path.join(app, "Contents", "Developer")
        version = xcode_version(developer)
        if version is not None:
            found.append((version_key(version[0]), version[1], developer))
    if not found:
        fail("No /Applications/Xcode*.app is installed; set QUOTA_IOS_XCODE.")
    # Newest version; the same version twice is ordered by build, then path, so the answer does not
    # depend on the order the directory was listed in.
    return max(found)[2]


def simctl_json(*arguments):
    raw = subprocess.run(
        ["xcrun", "simctl", "list", *arguments, "-j"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail("Could not parse `xcrun simctl list %s -j`: %s" % (" ".join(arguments), exc))


def available():
    """Every available iPhone-family simulator, as (version key, version, build, name, udid)."""
    runtimes = {}
    for runtime in simctl_json("runtimes").get("runtimes") or []:
        if runtime.get("platform", "iOS") != "iOS" or runtime.get("isAvailable") is False:
            continue
        identifier = runtime.get("identifier") or ""
        version = runtime.get("version") or ""
        runtimes[identifier] = (version, runtime.get("buildversion") or "")

    rows = []
    for identifier, devices in (simctl_json("devices", "available").get("devices") or {}).items():
        if identifier not in runtimes:
            continue
        version, build = runtimes[identifier]
        for device in devices:
            if device.get("isAvailable") is False:
                continue
            name, udid = device.get("name") or "", device.get("udid") or ""
            if name and udid:
                rows.append((version_key(version), version, build, name, udid))
    return rows


def choose():
    rows = available()
    if not rows:
        fail("No available iOS simulator was listed by simctl.")

    runtime = (os.environ.get("QUOTA_IOS_RUNTIME") or "").strip()
    if runtime:
        wanted = version_key(runtime)
        rows = [row for row in rows if row[0][: len(wanted)] == wanted]
        if not rows:
            fail("No simulator on iOS %s (QUOTA_IOS_RUNTIME) is available." % runtime)

    override = (os.environ.get("QUOTA_IOS_SIMULATOR") or "").strip()
    if override:
        matched = [row for row in rows if row[3] == override]
        if not matched:
            names = sorted({row[3] for row in rows})
            fail(
                "Simulator %r (QUOTA_IOS_SIMULATOR) is not available.\nAvailable: %s"
                % (override, ", ".join(names) or "none")
            )
        latest = max(row[0] for row in matched)
        # Two devices of the same model on the same runtime: order by udid so the answer does not
        # depend on the order simctl listed them in.
        return min((row for row in matched if row[0] == latest), key=lambda row: row[4])

    iphones = [row for row in rows if "iPhone" in row[3]]
    if not iphones:
        fail("No available iPhone simulator was listed by simctl.")
    latest = max(row[0] for row in iphones)
    newest = [row for row in iphones if row[0] == latest]
    if not any(row[3] in PREFERRED for row in newest):
        sys.stderr.write(
            "None of the preferred simulators are available (%s); update PREFERRED in "
            "scripts/ios-simulator.py.\n" % ", ".join(PREFERRED)
        )
    return min(newest, key=lambda row: (preference(row[3]), row[4]))


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else "udid"
    if want not in {"udid", "name", "tuple", "xcode"}:
        sys.stderr.write("usage: ios-simulator.py [udid|name|tuple|xcode]\n")
        raise SystemExit(2)
    if want == "xcode":
        developer = choose_xcode()
        version, build = xcode_version(developer)
        sys.stderr.write("Using Xcode %s (%s) at %s\n" % (version, build, developer))
        sys.stdout.write("%s\n" % developer)
        return
    _, version, build, name, udid = choose()
    sys.stderr.write("Using iOS Simulator: %s on iOS %s %s (%s)\n" % (name, version, build, udid))
    if want == "tuple":
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (udid, name, version, build))
    else:
        sys.stdout.write("%s\n" % (udid if want == "udid" else name))


if __name__ == "__main__":
    main()
