import type { QuotaSnapshotEnvelope, RelayInfo } from "@gotry-io/quota-protocol";
import type {
  AuthSessionRecord,
  ConsumePairingSessionInput,
  CreatePairingSessionInput,
  DecidePairingSessionInput,
  DeviceRecord,
  PairingConsumeOutcome,
  PairingDecisionOutcome,
  RateLimitInput,
  RateLimitResult,
  RegisterDeviceInput,
  RelayState,
  ReplaceAuthSessionInput,
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

  async ensureOwner(_ownerId: string, _createdAt: string): Promise<void> {}
  async replaceAuthSession(_input: ReplaceAuthSessionInput): Promise<void> {}
  async getActiveAuthSessionByTokenHash(
    _tokenHash: string,
    _checkedAt: string,
  ): Promise<AuthSessionRecord | null> {
    return null;
  }
  async registerDevice(_input: RegisterDeviceInput): Promise<void> {}
  async getDevice(_deviceId: string): Promise<DeviceRecord | null> {
    return null;
  }
  async getActiveDeviceByTokenHash(_tokenHash: string): Promise<DeviceRecord | null> {
    return null;
  }
  async listDevices(_ownerId: string): Promise<DeviceRecord[]> {
    return [];
  }
  async revokeDevice(_ownerId: string, _deviceId: string, _revokedAt: string): Promise<boolean> {
    return false;
  }
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
  async recordSnapshot(_envelope: QuotaSnapshotEnvelope): Promise<void> {}
  async listLatestSnapshots(_ownerId: string): Promise<StoredQuotaSnapshot[]> {
    return [];
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

  it("keeps managed discovery authentication and persistence capabilities disabled", async () => {
    const app = createRelayApp({
      state: new TestRelayState(),
      relayInfo: managedRelayInfo("managed-test"),
    });
    const response = await app.request("/.well-known/quotabar-relay");
    const discovery = (await response.json()) as RelayInfo;

    expect(discovery.auth_methods).toEqual([]);
    expect(discovery.capabilities).toEqual({
      realtime: false,
      persistent_snapshots: false,
      instant_device_revocation: false,
      history: false,
      multi_tenant: false,
    });
  });

  it("reports a storage readiness failure", async () => {
    const state = new TestRelayState();
    state.ready = false;
    const app = createRelayApp({ state, relayInfo });
    const response = await app.request("/readyz");

    expect(response.status).toBe(503);
  });

  it("guards pairing polls with distinct global and per-code persistent limits", async () => {
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
});
