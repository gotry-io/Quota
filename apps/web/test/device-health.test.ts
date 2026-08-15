import type { AccountDeviceWithHealth } from "@gotry-io/quota-protocol";
import assert from "node:assert/strict";
import test from "node:test";
import { deviceHealthStatus } from "../src/lib/device-health.ts";

const now = new Date("2026-08-15T08:10:00Z");

function device(
  health: AccountDeviceWithHealth["health"] = {
    schema_version: 1,
    client_product: "quotabar",
    client_version: "0.0.16",
    platform: "macos",
    observed_at: "2026-08-15T08:00:00Z",
    refresh_revision: 9,
    last_completed_refresh_at: "2026-08-15T08:00:00Z",
    last_successful_account_sync_at: null,
    summary: { operation: "healthy", data: "current", attention: "none" },
    top_code: null,
    consecutive_failures: 0,
    usage_upload_enabled: true,
    received_at: "2026-08-15T08:00:05Z",
    fresh_until: "2026-08-15T08:20:05Z",
  },
  status: AccountDeviceWithHealth["status"] = "active",
): AccountDeviceWithHealth {
  return {
    device_id: "device_01",
    display_name: "Studio Mac",
    platform: "macos",
    device_generation: 1,
    status,
    created_at: "2026-08-01T00:00:00Z",
    last_login_at: "2026-08-15T08:00:00Z",
    last_seen_at: "2026-08-15T08:00:05Z",
    signed_out_at: status === "signed_out" ? "2026-08-15T08:05:00Z" : null,
    health,
  };
}

test("remote Device Health uses freshness plus all three server-owned summary axes", () => {
  assert.equal(deviceHealthStatus(device(), now).label, "Healthy");
  assert.equal(
    deviceHealthStatus(
      device({
        ...device().health!,
        summary: { operation: "healthy", data: "partial", attention: "none" },
      }),
      now,
    ).label,
    "Needs attention",
  );
  assert.equal(
    deviceHealthStatus(
      device({
        ...device().health!,
        summary: { operation: "healthy", data: "current", attention: "required" },
      }),
      now,
    ).label,
    "Needs attention",
  );
  assert.equal(
    deviceHealthStatus(device({ ...device().health!, fresh_until: "2026-08-15T08:09:59Z" }), now)
      .label,
    "Not recently active",
  );
  assert.equal(deviceHealthStatus(device(null), now).label, "Unknown");
  assert.equal(deviceHealthStatus(device(null, "signed_out"), now).label, "Signed out");
});
