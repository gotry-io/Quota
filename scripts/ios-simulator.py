#!/usr/bin/env python3
"""Which iOS Simulator the Quota tests and screenshots run on.

The model and the runtime decide how the app lays out and what the accessibility auditor reports,
so "whichever one `simctl` happened to list first" is a difference between two runs that nothing
records. One answer, used by scripts/test-ios.sh, scripts/ios-ui-screenshots.sh and
scripts/ios-store-screenshots.sh, so a screenshot and the test that audits the same screen are
taken on the same device.

Usage: ios-simulator.py [udid|name]     (default: udid)
       QUOTA_IOS_SIMULATOR=<model name> pins the model; the newest runtime carrying it wins.
"""

import json
import os
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


def preference(name):
    try:
        return (0, PREFERRED.index(name), [])
    except ValueError:
        return (1, 0, [-ord(c) for c in name])


def available():
    """Every available iPhone simulator, as (runtime version, name, udid)."""
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write("Could not parse `xcrun simctl list devices available -j`: %s\n" % exc)
        raise SystemExit(1)

    rows = []
    for runtime, devices in (data.get("devices") or {}).items():
        match = re.search(r"iOS[- ](\d+)(?:[.-](\d+))?(?:[.-](\d+))?", runtime)
        if not match:
            continue
        version = tuple(int(part) if part else 0 for part in match.groups())
        for device in devices:
            if device.get("isAvailable") is False:
                continue
            name, udid = device.get("name") or "", device.get("udid") or ""
            if name and udid:
                rows.append((version, name, udid))
    return rows


def choose():
    rows = available()
    override = (os.environ.get("QUOTA_IOS_SIMULATOR") or "").strip()
    if override:
        matched = [row for row in rows if row[1] == override]
        if not matched:
            names = sorted({row[1] for row in rows})
            sys.stderr.write(
                "Simulator %r (QUOTA_IOS_SIMULATOR) is not available.\nAvailable: %s\n"
                % (override, ", ".join(names) or "none")
            )
            raise SystemExit(1)
        latest = max(row[0] for row in matched)
        # Two devices of the same model on the same runtime: order by udid so the answer does not
        # depend on the order simctl listed them in.
        return min((row for row in matched if row[0] == latest), key=lambda row: row[2])

    iphones = [row for row in rows if "iPhone" in row[1]]
    if not iphones:
        sys.stderr.write("No available iPhone simulator was listed by simctl.\n")
        raise SystemExit(1)
    latest = max(row[0] for row in iphones)
    newest = [row for row in iphones if row[0] == latest]
    if not any(row[1] in PREFERRED for row in newest):
        sys.stderr.write(
            "None of the preferred simulators are available (%s); update PREFERRED in "
            "scripts/ios-simulator.py.\n" % ", ".join(PREFERRED)
        )
    return min(newest, key=lambda row: (preference(row[1]), row[2]))


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else "udid"
    if want not in {"udid", "name"}:
        sys.stderr.write("usage: ios-simulator.py [udid|name]\n")
        raise SystemExit(2)
    version, name, udid = choose()
    sys.stderr.write(
        "Using iOS Simulator: %s on iOS %s (%s)\n"
        % (name, ".".join(str(part) for part in version), udid)
    )
    sys.stdout.write("%s\n" % (udid if want == "udid" else name))


if __name__ == "__main__":
    main()
