import type { QuotaSnapshotEnvelope, RelayInfo } from "@gotry-io/quota-protocol";
import type {
  DeviceRecord,
  RegisterDeviceInput,
  RelayState,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import { describe, expect, it } from "vitest";
import { createRelayApp } from "../src/app.ts";

class TestRelayState implements RelayState {
  ready = true;

  async initialize(): Promise<void> {}

  async ping(): Promise<void> {
    if (!this.ready) {
      throw new Error("not ready");
    }
  }

  async ensureOwner(_ownerId: string, _createdAt: string): Promise<void> {}
  async registerDevice(_input: RegisterDeviceInput): Promise<void> {}
  async getDevice(_deviceId: string): Promise<DeviceRecord | null> {
    return null;
  }
  async listDevices(_ownerId: string): Promise<DeviceRecord[]> {
    return [];
  }
  async revokeDevice(_ownerId: string, _deviceId: string, _revokedAt: string): Promise<boolean> {
    return false;
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

  it("reports a storage readiness failure", async () => {
    const state = new TestRelayState();
    state.ready = false;
    const app = createRelayApp({ state, relayInfo });
    const response = await app.request("/readyz");

    expect(response.status).toBe(503);
  });
});
