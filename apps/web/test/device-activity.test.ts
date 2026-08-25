import assert from "node:assert/strict";
import test from "node:test";
import { deviceActivity } from "../src/lib/device-activity.ts";

const now = new Date("2026-08-15T08:10:00Z");

function device(lastSeenAt: string | null, lastObservedAt: string | null = null) {
  return { last_seen_at: lastSeenAt, last_observed_at: lastObservedAt };
}

test("a device that spoke in the last half hour is active", () => {
  assert.equal(deviceActivity(device("2026-08-15T08:05:00Z"), now).label, "Active");
});

test("the newest reading counts even when the device last called earlier", () => {
  const result = deviceActivity(device("2026-08-14T08:00:00Z", "2026-08-15T08:00:00Z"), now);
  assert.equal(result.label, "Active");
  assert.equal(result.tone, "available");
});

test("a quiet day is idle and a longer silence stops reporting", () => {
  assert.equal(deviceActivity(device("2026-08-15T02:00:00Z"), now).label, "Idle");
  assert.equal(deviceActivity(device("2026-08-10T02:00:00Z"), now).label, "Not reporting");
  assert.equal(deviceActivity(device(null), now).label, "Not reporting");
});
