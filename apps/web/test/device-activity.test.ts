import assert from "node:assert/strict";
import test from "node:test";
import {
  deviceActivity,
  platformIconKind,
  sortDevicesByLastSeen,
} from "../src/lib/device-activity.ts";

const now = new Date("2026-08-15T08:10:00Z");

function device(lastSeenAt: string | null, lastObservedAt: string | null = null) {
  return { last_seen_at: lastSeenAt, last_observed_at: lastObservedAt };
}

test("the newest reading counts even when the device last called earlier", () => {
  const result = deviceActivity(device("2026-08-14T08:00:00Z", "2026-08-15T08:00:00Z"), now);
  assert.equal(result.label, "Active");
  assert.equal(result.tone, "available");
  // The verdict carries the instant it came from, so the row states one age.
  assert.equal(result.since, "2026-08-15T08:00:00Z");
  assert.equal(deviceActivity(device(null), now).since, null);
});

test("active under half an hour, idle within a day, then not reporting", () => {
  assert.equal(deviceActivity(device("2026-08-15T08:05:00Z"), now).label, "Active");
  assert.equal(deviceActivity(device("2026-08-15T02:00:00Z"), now).label, "Idle");
  assert.equal(deviceActivity(device("2026-08-10T02:00:00Z"), now).label, "Not reporting");
  assert.equal(deviceActivity(device(null), now).label, "Not reporting");
});

test("sorts devices by last-seen, newest first, and never-seen last", () => {
  const rows = [
    { id: "old", last_seen_at: "2026-08-10T09:31:00Z" },
    { id: "new", last_seen_at: "2026-08-12T09:31:00Z" },
    { id: "none", last_seen_at: null },
  ];
  assert.deepEqual(
    sortDevicesByLastSeen(rows).map((row) => row.id),
    ["new", "old", "none"],
  );
});

test("platform icons name the two platforms a Device reports, and nothing else", () => {
  assert.equal(platformIconKind("macos"), "mac");
  assert.equal(platformIconKind("ios"), "iphone");
  // The wire member is `ios`; a value this build cannot name draws the generic device.
  assert.equal(platformIconKind("iphone"), "generic");
  assert.equal(platformIconKind("linux"), "generic");
});
