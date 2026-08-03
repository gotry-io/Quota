import { Database } from "bun:sqlite";
import {
  DeviceListResponseSchema,
  OwnerSnapshotListResponseSchema,
  PairingCreateResponseSchema,
  PairingTokenIssuedResponseSchema,
  PairingTokenPendingResponseSchema,
  type RelayInfo,
} from "@gotry-io/quota-protocol";
import { describe, expect, it } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRelayApp } from "../src/app.ts";
import { sha256Hex } from "../src/security.ts";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

const ownerManageToken = "owner-manage-token-for-http-tests";
const ownerReadToken = "owner-read-token-for-http-tests";
const otherOwnerManageToken = "other-owner-manage-token-for-http-tests";

const relayInfo: RelayInfo = {
  instance_id: "http-test-relay",
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

describe("QuotaRelay HTTP v1 API", () => {
  it("pairs, authorizes, stores snapshots, lists devices, and revokes credentials", async () => {
    const fixture = await makeFixture();
    const pairing = await createPairing(fixture.app, "Edge Mac");

    const pendingResponse = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: pairing.device_code,
    });
    expect(pendingResponse.status).toBe(202);
    expect(PairingTokenPendingResponseSchema.parse(await pendingResponse.json())).toEqual({
      status: "pending",
      poll_interval_seconds: 5,
    });

    const approvalResponse = await postJSON(
      fixture.app,
      "/api/v1/pairings/approve",
      { user_code: pairing.user_code.toLowerCase() },
      ownerManageToken,
    );
    expect(approvalResponse.status).toBe(204);
    expect(await approvalResponse.text()).toBe("");

    const repeatedApproval = await postJSON(
      fixture.app,
      "/api/v1/pairings/approve",
      { user_code: pairing.user_code },
      otherOwnerManageToken,
    );
    expect(repeatedApproval.status).toBe(409);
    expect(await errorCode(repeatedApproval)).toBe("conflict");

    const repeatedDenial = await postJSON(
      fixture.app,
      "/api/v1/pairings/deny",
      { user_code: pairing.user_code },
      otherOwnerManageToken,
    );
    expect(repeatedDenial.status).toBe(409);
    expect(await errorCode(repeatedDenial)).toBe("conflict");

    const issuedResponse = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: pairing.device_code,
    });
    expect(issuedResponse.status).toBe(200);
    expect(issuedResponse.headers.get("Cache-Control")).toBe("no-store");
    const issued = PairingTokenIssuedResponseSchema.parse(await issuedResponse.json());
    expect(Object.keys(issued).sort()).toEqual(["device_id", "device_token"]);

    const consumedResponse = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: pairing.device_code,
    });
    expect(consumedResponse.status).toBe(409);
    expect(await errorCode(consumedResponse)).toBe("pairing_consumed");

    await expectOnlyHashesPersisted(
      fixture.databasePath,
      pairing.device_code,
      pairing.user_code,
      issued.device_token,
    );

    const impersonationResponse = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope("another-device", 1),
      issued.device_token,
    );
    expect(impersonationResponse.status).toBe(403);
    expect(await errorCode(impersonationResponse)).toBe("forbidden");

    const ownerCredentialOnDeviceRoute = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope(issued.device_id, 1),
      ownerManageToken,
    );
    expect(ownerCredentialOnDeviceRoute.status).toBe(401);

    const snapshotResponse = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope(issued.device_id, 1),
      issued.device_token,
    );
    expect(snapshotResponse.status).toBe(204);
    expect(await snapshotResponse.text()).toBe("");

    const wrongSnapshotScope = await getWithBearer(
      fixture.app,
      "/api/v1/snapshots",
      ownerManageToken,
    );
    expect(wrongSnapshotScope.status).toBe(403);

    const snapshotsResponse = await getWithBearer(fixture.app, "/api/v1/snapshots", ownerReadToken);
    expect(snapshotsResponse.status).toBe(200);
    expect(snapshotsResponse.headers.get("Cache-Control")).toBe("no-store");
    const snapshots = OwnerSnapshotListResponseSchema.parse(await snapshotsResponse.json());
    expect(snapshots.observations).toHaveLength(1);
    expect(snapshots.observations[0]?.device_id).toBe(issued.device_id);
    expect(snapshots.observations[0]?.snapshot.provider).toBe("codex");
    expect(snapshots.observations[0]).not.toHaveProperty("display_name");

    const deviceCredentialOnOwnerRoute = await getWithBearer(
      fixture.app,
      "/api/v1/snapshots",
      issued.device_token,
    );
    expect(deviceCredentialOnOwnerRoute.status).toBe(401);

    const wrongDeviceScope = await getWithBearer(fixture.app, "/api/v1/devices", ownerReadToken);
    expect(wrongDeviceScope.status).toBe(403);

    const devicesResponse = await getWithBearer(fixture.app, "/api/v1/devices", ownerManageToken);
    expect(devicesResponse.status).toBe(200);
    const devices = DeviceListResponseSchema.parse(await devicesResponse.json());
    expect(devices.devices).toHaveLength(1);
    expect(devices.devices[0]?.device_id).toBe(issued.device_id);
    expect(devices.devices[0]).not.toHaveProperty("owner_id");

    const revokeResponse = await fixture.app.request(`/api/v1/devices/${issued.device_id}`, {
      method: "DELETE",
      headers: bearerHeaders(ownerManageToken),
    });
    expect(revokeResponse.status).toBe(204);
    expect(await revokeResponse.text()).toBe("");

    const revokedUpload = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope(issued.device_id, 2),
      issued.device_token,
    );
    expect(revokedUpload.status).toBe(401);
  });

  it("returns explicit denied and expired pairing states and rejects oversized JSON", async () => {
    const fixture = await makeFixture();
    const deniedPairing = await createPairing(fixture.app, "Denied Edge");

    const denialResponse = await postJSON(
      fixture.app,
      "/api/v1/pairings/deny",
      { user_code: deniedPairing.user_code },
      ownerManageToken,
    );
    expect(denialResponse.status).toBe(204);
    expect(await denialResponse.text()).toBe("");

    const deniedPoll = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: deniedPairing.device_code,
    });
    expect(deniedPoll.status).toBe(409);
    expect(await errorCode(deniedPoll)).toBe("pairing_denied");

    const expiredPairing = await createPairing(fixture.app, "Expired Edge");
    fixture.setNow("2026-08-03T01:10:00Z");
    const expiredPoll = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: expiredPairing.device_code,
    });
    expect(expiredPoll.status).toBe(410);
    expect(await errorCode(expiredPoll)).toBe("pairing_expired");

    const oversizedResponse = await fixture.app.request("/api/v1/pairings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_display_name: "界".repeat(22_000) }),
    });
    expect(oversizedResponse.status).toBe(413);
    expect(await errorCode(oversizedResponse)).toBe("invalid_request");
  });

  it("does not trust forwarded client headers to bypass pairing creation limits", async () => {
    const fixture = await makeFixture();
    let response: Response | undefined;

    for (let index = 0; index < 300; index += 1) {
      response = await fixture.app.request("/api/v1/pairings", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Forwarded-For": `198.51.100.${index % 255}`,
          "X-Real-IP": `203.0.113.${index % 255}`,
        },
        body: JSON.stringify({ device_display_name: `Edge ${index}` }),
      });
      expect(response.status).toBe(201);
    }

    response = await fixture.app.request("/api/v1/pairings", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Forwarded-For": "192.0.2.200",
      },
      body: JSON.stringify({ device_display_name: "Rate-limited edge" }),
    });
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("600");
    expect(await errorCode(response)).toBe("rate_limited");
  });
});

async function makeFixture() {
  const directory = mkdtempSync(join(tmpdir(), "quota-relay-http-test-"));
  const databasePath = join(directory, "relay.db");
  const state = new SQLiteRelayState(databasePath);
  await state.initialize();
  await state.ensureOwner("owner_http", "2026-08-03T00:00:00Z");
  await state.ensureOwner("owner_other", "2026-08-03T00:00:00Z");
  await state.replaceAuthSession({
    id: "auth_manage",
    owner_id: "owner_http",
    token_hash: await sha256Hex(ownerManageToken),
    scopes: ["device:manage"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });
  await state.replaceAuthSession({
    id: "auth_other_manage",
    owner_id: "owner_other",
    token_hash: await sha256Hex(otherOwnerManageToken),
    scopes: ["device:manage"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });
  await state.replaceAuthSession({
    id: "auth_read",
    owner_id: "owner_http",
    token_hash: await sha256Hex(ownerReadToken),
    scopes: ["quota:read"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });

  let currentTime = new Date("2026-08-03T01:00:00Z");
  return {
    app: createRelayApp({ state, relayInfo, now: () => currentTime }),
    databasePath,
    setNow(value: string) {
      currentTime = new Date(value);
    },
  };
}

async function createPairing(app: ReturnType<typeof createRelayApp>, displayName: string) {
  const response = await postJSON(app, "/api/v1/pairings", {
    device_display_name: displayName,
  });
  expect(response.status).toBe(201);
  const pairing = PairingCreateResponseSchema.parse(await response.json());
  expect(Object.keys(pairing).sort()).toEqual([
    "device_code",
    "expires_at",
    "poll_interval_seconds",
    "user_code",
  ]);
  return pairing;
}

async function postJSON(
  app: ReturnType<typeof createRelayApp>,
  path: string,
  body: unknown,
  token?: string,
): Promise<Response> {
  return await app.request(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? bearerHeaders(token) : {}),
    },
    body: JSON.stringify(body),
  });
}

async function getWithBearer(
  app: ReturnType<typeof createRelayApp>,
  path: string,
  token: string,
): Promise<Response> {
  return await app.request(path, { headers: bearerHeaders(token) });
}

function bearerHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

function snapshotEnvelope(deviceID: string, sequence: number) {
  return {
    schema_version: 1,
    device_id: deviceID,
    sequence,
    captured_at: "2026-08-03T01:05:00Z",
    snapshots: [
      {
        provider: "codex",
        account: { fingerprint: "account_http" },
        windows: [{ id: "five_hour", title: "5 hour", used_percent: 20 }],
        source: "codex_api",
        status: "available",
        observed_at: "2026-08-03T01:05:00Z",
      },
    ],
  };
}

async function errorCode(response: Response): Promise<string | undefined> {
  const value = (await response.json()) as { error?: { code?: string } };
  return value.error?.code;
}

async function expectOnlyHashesPersisted(
  databasePath: string,
  rawDeviceCode: string,
  rawUserCode: string,
  rawDeviceToken: string,
): Promise<void> {
  const database = new Database(databasePath, { readonly: true, strict: true });
  const pairing = database
    .query<{ device_code_hash: string; user_code_hash: string }, []>(
      "SELECT device_code_hash, user_code_hash FROM pairing_sessions LIMIT 1",
    )
    .get();
  const device = database
    .query<{ token_hash: string }, []>("SELECT token_hash FROM devices LIMIT 1")
    .get();
  const auth = database
    .query<{ token_hash: string }, []>("SELECT token_hash FROM auth_sessions ORDER BY id")
    .all();

  expect(pairing?.device_code_hash).not.toBe(rawDeviceCode);
  expect(pairing?.user_code_hash).not.toBe(rawUserCode);
  expect(pairing?.device_code_hash).toHaveLength(64);
  expect(pairing?.user_code_hash).toHaveLength(64);
  expect(device?.token_hash).not.toBe(rawDeviceToken);
  expect(device?.token_hash).toHaveLength(64);
  expect(auth.every(({ token_hash }) => token_hash.length === 64)).toBe(true);
  expect(auth.some(({ token_hash }) => token_hash === ownerManageToken)).toBe(false);
  expect(auth.some(({ token_hash }) => token_hash === ownerReadToken)).toBe(false);
  database.close();
}
