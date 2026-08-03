import type { QuotaSnapshotEnvelope, RelayInfo } from "@gotry-io/quota-protocol";
import type {
  ConsumePairingSessionInput,
  ControllerKind,
  ControllerSessionRecord,
  CreateControllerInput,
  CreatePairingSessionInput,
  DecidePairingSessionInput,
  DeviceRecord,
  PairingConsumeOutcome,
  PairingDecisionOutcome,
  RateLimitInput,
  RateLimitResult,
  RegisterDeviceInput,
  RelayMaintenanceInput,
  RelayState,
  ReplaceControllerSessionInput,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import { describe, expect, it } from "vitest";
import { createRelayApp } from "../src/app.ts";
import { managedRelayInfo } from "../src/config.ts";

class TestRelayState implements RelayState {
  ready = true;
  rateLimitInputs: RateLimitInput[] = [];

  async initialize(): Promise<void> {}

  async ping(): Promise<void> {
    if (!this.ready) {
      throw new Error("not ready");
    }
  }

  async createController(_input: CreateControllerInput): Promise<void> {}
  async deleteController(_controllerId: string): Promise<boolean> {
    return false;
  }
  async ensureController(
    _controllerId: string,
    _kind: ControllerKind,
    _createdAt: string,
  ): Promise<void> {}
  async replaceControllerSession(_input: ReplaceControllerSessionInput): Promise<void> {}
  async getActiveControllerSessionByTokenHash(
    _tokenHash: string,
    _checkedAt: string,
  ): Promise<ControllerSessionRecord | null> {
    return null;
  }
  async registerDevice(_input: RegisterDeviceInput): Promise<void> {}
  async getDevice(_deviceId: string): Promise<DeviceRecord | null> {
    return null;
  }
  async getDeviceByTokenHash(_tokenHash: string): Promise<DeviceRecord | null> {
    return null;
  }
  async listDevices(_controllerId: string): Promise<DeviceRecord[]> {
    return [];
  }
  async revokeDevice(
    _controllerId: string,
    _deviceId: string,
    _revokedAt: string,
  ): Promise<boolean> {
    return false;
  }
  async revokeDeviceIfInactive(
    _tokenHash: string,
    _inactiveBefore: string,
    _revokedAt: string,
  ): Promise<boolean> {
    return false;
  }
  async revokeInactiveDevicesForController(
    _controllerId: string,
    _inactiveBefore: string,
    _revokedAt: string,
  ): Promise<number> {
    return 0;
  }
  async performMaintenance(_input: RelayMaintenanceInput): Promise<void> {}
  async createPairingSession(_input: CreatePairingSessionInput): Promise<void> {}
  async decidePairingSession(_input: DecidePairingSessionInput): Promise<PairingDecisionOutcome> {
    return "not_found";
  }
  async consumePairingSession(_input: ConsumePairingSessionInput): Promise<PairingConsumeOutcome> {
    return "not_found";
  }
  async consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult> {
    this.rateLimitInputs.push(input);
    return { allowed: true, retry_after: 0 };
  }
  async recordSnapshot(_envelope: QuotaSnapshotEnvelope, _receivedAt: string): Promise<void> {}
  async listLatestSnapshots(_controllerId: string): Promise<StoredQuotaSnapshot[]> {
    return [];
  }
}

class ActivityRaceRelayState extends TestRelayState {
  device: DeviceRecord = {
    id: "device_race",
    controller_id: "controller_race",
    display_name: "Racing device",
    created_at: "2026-07-04T01:00:00Z",
    last_seen_at: null,
    last_sequence: -1,
    revoked_at: null,
  };
  snapshotRecorded = false;

  override async getDeviceByTokenHash(_tokenHash: string): Promise<DeviceRecord | null> {
    return { ...this.device };
  }

  override async revokeDeviceIfInactive(
    _tokenHash: string,
    _inactiveBefore: string,
    _revokedAt: string,
  ): Promise<boolean> {
    this.device.last_seen_at = "2026-08-03T01:00:00Z";
    return false;
  }

  override async recordSnapshot(
    _envelope: QuotaSnapshotEnvelope,
    _receivedAt: string,
  ): Promise<void> {
    this.snapshotRecorded = true;
  }
}

const relayInfo: RelayInfo = {
  instance_id: "test-relay",
  mode: "self_hosted",
  version: "0.1.0",
  api_versions: [1],
  auth_methods: [],
  capabilities: {
    realtime: false,
    persistent_snapshots: false,
    instant_device_revocation: false,
    history: false,
    multi_tenant: false,
  },
};

describe("QuotaRelay app", () => {
  it("publishes only its implemented bootstrap capabilities", async () => {
    const app = createRelayApp({ state: new TestRelayState(), relayInfo });
    const response = await app.request("/.well-known/quotabar-relay");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(relayInfo);
  });

  it("publishes the managed controller capabilities", async () => {
    const app = createRelayApp({
      state: new TestRelayState(),
      relayInfo: managedRelayInfo("managed-test"),
    });
    const response = await app.request("/.well-known/quotabar-relay");
    const discovery = (await response.json()) as RelayInfo;

    expect(discovery.auth_methods).toEqual(["bearer"]);
    expect(discovery.capabilities).toEqual({
      realtime: false,
      persistent_snapshots: true,
      instant_device_revocation: true,
      history: false,
      multi_tenant: true,
    });
  });

  it("reports a storage readiness failure", async () => {
    const state = new TestRelayState();
    state.ready = false;
    const app = createRelayApp({ state, relayInfo });
    const response = await app.request("/readyz");

    expect(response.status).toBe(503);
  });

  it("guards pairing polls with distinct client and per-code persistent limits", async () => {
    const state = new TestRelayState();
    const app = createRelayApp({
      state,
      relayInfo,
      now: () => new Date("2026-08-03T01:00:00Z"),
    });
    const response = await app.request("/api/v1/pairings/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_code: "unknown-device-code" }),
    });

    expect(response.status).toBe(404);
    expect(state.rateLimitInputs.map(({ limit }) => limit)).toEqual([10_000, 130]);
    expect(state.rateLimitInputs[0]?.key_hash).not.toBe(state.rateLimitInputs[1]?.key_hash);
  });

  it("isolates managed pairing limits by the trusted Cloudflare client address", async () => {
    const state = new TestRelayState();
    const app = createRelayApp({
      state,
      relayInfo: managedRelayInfo("managed-test"),
      now: () => new Date("2026-08-03T01:00:00Z"),
    });

    for (const clientAddress of ["192.0.2.10", "192.0.2.11"]) {
      expect(
        (
          await app.request("/api/v1/pairings", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "CF-Connecting-IP": clientAddress,
            },
            body: JSON.stringify({ device_display_name: "Managed device" }),
          })
        ).status,
      ).toBe(201);
      expect(
        (
          await app.request("/api/v1/pairings/token", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "CF-Connecting-IP": clientAddress,
            },
            body: JSON.stringify({ device_code: "same-device-code" }),
          })
        ).status,
      ).toBe(404);
    }

    expect(state.rateLimitInputs).toHaveLength(6);
    expect(state.rateLimitInputs[0]?.key_hash).not.toBe(state.rateLimitInputs[3]?.key_hash);
    expect(state.rateLimitInputs[1]?.key_hash).not.toBe(state.rateLimitInputs[4]?.key_hash);
    expect(state.rateLimitInputs[2]?.key_hash).toBe(state.rateLimitInputs[5]?.key_hash);
  });

  it("does not revoke a device refreshed during the inactivity authorization check", async () => {
    const state = new ActivityRaceRelayState();
    const app = createRelayApp({
      state,
      relayInfo,
      now: () => new Date("2026-08-03T01:00:00Z"),
    });
    const response = await app.request("/api/v1/snapshots", {
      method: "POST",
      headers: {
        Authorization: "Bearer racing-device-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        schema_version: 1,
        device_id: "device_race",
        sequence: 0,
        captured_at: "2026-08-03T01:00:00Z",
        snapshots: [],
      }),
    });

    expect(response.status).toBe(204);
    expect(state.snapshotRecorded).toBe(true);
    expect(state.device.revoked_at).toBeNull();
  });
});
