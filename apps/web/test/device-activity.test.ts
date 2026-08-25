import type { AccountDevice, AccountQuotaObservation } from "@gotry-io/quota-protocol";
import assert from "node:assert/strict";
import test from "node:test";
import { deviceActivity } from "../src/lib/device-activity.ts";

const now = new Date("2026-08-15T08:10:00Z");

function device(
  lastSeenAt: string | null,
  status: AccountDevice["status"] = "active",
): AccountDevice {
  return {
    device_id: "device_01",
    display_name: "Studio Mac",
    platform: "macos",
    device_generation: 1,
    status,
    created_at: "2026-08-01T00:00:00Z",
    last_login_at: "2026-08-15T08:00:00Z",
    last_seen_at: lastSeenAt,
    signed_out_at: status === "signed_out" ? "2026-08-15T08:05:00Z" : null,
  };
}

function observation(deviceId: string, observedAt: string): AccountQuotaObservation {
  return {
    device_id: deviceId,
    snapshot: {
      provider: "codex",
      account: { fingerprint: "fp", fingerprint_scope: "global" },
      windows: [{ id: "weekly", title: "Weekly", used_percent: 10 }],
      status: "available",
      observed_at: observedAt,
    },
  } as AccountQuotaObservation;
}

test("a device that spoke in the last half hour is active", () => {
  assert.equal(deviceActivity(device("2026-08-15T08:05:00Z"), [], now).label, "Active");
});

test("the newest reading counts even when the device last called earlier", () => {
  const result = deviceActivity(
    device("2026-08-14T08:00:00Z"),
    [
      observation("device_01", "2026-08-15T08:00:00Z"),
      observation("other", "2026-08-01T00:00:00Z"),
    ],
    now,
  );
  assert.equal(result.label, "Active");
  assert.equal(result.lastReadingAt, "2026-08-15T08:00:00Z");
});

test("a quiet day is idle and a longer silence stops reporting", () => {
  assert.equal(deviceActivity(device("2026-08-15T02:00:00Z"), [], now).label, "Idle");
  assert.equal(deviceActivity(device("2026-08-10T02:00:00Z"), [], now).label, "Not reporting");
  assert.equal(deviceActivity(device(null), [], now).label, "Not reporting");
});

test("a signed-out device says so instead of guessing at activity", () => {
  assert.equal(
    deviceActivity(device("2026-08-15T08:05:00Z", "signed_out"), [], now).label,
    "Signed out",
  );
});
