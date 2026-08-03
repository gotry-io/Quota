import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ControllerCreateResponseSchema,
  ControllerSnapshotListResponseSchema,
  DeviceListResponseSchema,
  PairingCreateResponseSchema,
  PairingTokenIssuedResponseSchema,
  PairingTokenPendingResponseSchema,
  type QuotaSnapshotEnvelope,
  type RelayInfo,
} from "@gotry-io/quota-protocol";
import { createRelayApp, performRelayMaintenance } from "../src/app.ts";
import { managedRelayInfo } from "../src/config.ts";
import { sha256Hex } from "../src/security.ts";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

const controllerManageToken = "controller-manage-token-for-http-tests";
const controllerReadToken = "controller-read-token-for-http-tests";
const otherControllerManageToken = "other-controller-manage-token-for-http-tests";

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
    const pairing = await createPairing(fixture.app, "Relay Mac");

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
      controllerManageToken,
    );
    expect(approvalResponse.status).toBe(204);
    expect(await approvalResponse.text()).toBe("");

    const repeatedApproval = await postJSON(
      fixture.app,
      "/api/v1/pairings/approve",
      { user_code: pairing.user_code },
      otherControllerManageToken,
    );
    expect(repeatedApproval.status).toBe(409);
    expect(await errorCode(repeatedApproval)).toBe("conflict");

    const repeatedDenial = await postJSON(
      fixture.app,
      "/api/v1/pairings/deny",
      { user_code: pairing.user_code },
      otherControllerManageToken,
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

    const controllerCredentialOnDeviceRoute = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope(issued.device_id, 1),
      controllerManageToken,
    );
    expect(controllerCredentialOnDeviceRoute.status).toBe(401);

    const snapshotResponse = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope(issued.device_id, 1),
      issued.device_token,
    );
    expect(snapshotResponse.status).toBe(204);
    expect(await snapshotResponse.text()).toBe("");
    expect((await fixture.state.getDevice(issued.device_id))?.last_seen_at).toBe(
      "2026-08-03T01:00:00.000Z",
    );

    const wrongSnapshotScope = await getWithBearer(
      fixture.app,
      "/api/v1/snapshots",
      controllerManageToken,
    );
    expect(wrongSnapshotScope.status).toBe(403);

    const snapshotsResponse = await getWithBearer(
      fixture.app,
      "/api/v1/snapshots",
      controllerReadToken,
    );
    expect(snapshotsResponse.status).toBe(200);
    expect(snapshotsResponse.headers.get("Cache-Control")).toBe("no-store");
    const snapshots = ControllerSnapshotListResponseSchema.parse(await snapshotsResponse.json());
    expect(snapshots.observations).toHaveLength(1);
    expect(snapshots.observations[0]?.device_id).toBe(issued.device_id);
    expect(snapshots.observations[0]?.snapshot.provider).toBe("codex");
    expect(snapshots.observations[0]).not.toHaveProperty("display_name");

    const deviceCredentialOnControllerRoute = await getWithBearer(
      fixture.app,
      "/api/v1/snapshots",
      issued.device_token,
    );
    expect(deviceCredentialOnControllerRoute.status).toBe(401);

    const wrongDeviceScope = await getWithBearer(
      fixture.app,
      "/api/v1/devices",
      controllerReadToken,
    );
    expect(wrongDeviceScope.status).toBe(403);

    const devicesResponse = await getWithBearer(
      fixture.app,
      "/api/v1/devices",
      controllerManageToken,
    );
    expect(devicesResponse.status).toBe(200);
    const devices = DeviceListResponseSchema.parse(await devicesResponse.json());
    expect(devices.devices).toHaveLength(1);
    expect(devices.devices[0]?.device_id).toBe(issued.device_id);
    expect(devices.devices[0]).not.toHaveProperty("controller_id");

    const revokeResponse = await fixture.app.request(`/api/v1/devices/${issued.device_id}`, {
      method: "DELETE",
      headers: bearerHeaders(controllerManageToken),
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
    const deniedPairing = await createPairing(fixture.app, "Denied Device");

    const denialResponse = await postJSON(
      fixture.app,
      "/api/v1/pairings/deny",
      { user_code: deniedPairing.user_code },
      controllerManageToken,
    );
    expect(denialResponse.status).toBe(204);
    expect(await denialResponse.text()).toBe("");

    const deniedPoll = await postJSON(fixture.app, "/api/v1/pairings/token", {
      device_code: deniedPairing.device_code,
    });
    expect(deniedPoll.status).toBe(409);
    expect(await errorCode(deniedPoll)).toBe("pairing_denied");

    const expiredPairing = await createPairing(fixture.app, "Expired Device");
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
          "CF-Connecting-IP": `192.0.2.${index % 255}`,
        },
        body: JSON.stringify({ device_display_name: `Relay ` }),
      });
      expect(response.status).toBe(201);
    }

    response = await fixture.app.request("/api/v1/pairings", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Forwarded-For": "192.0.2.200",
      },
      body: JSON.stringify({ device_display_name: "Rate-limited device" }),
    });
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("600");
    expect(await errorCode(response)).toBe("rate_limited");
  });

  it("isolates managed pairing creation limits by trusted client address", async () => {
    const fixture = await makeManagedFixture();
    for (let index = 0; index < 300; index += 1) {
      const response = await fixture.app.request("/api/v1/pairings", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "192.0.2.10",
        },
        body: JSON.stringify({ device_display_name: `Managed device ${index}` }),
      });
      expect(response.status).toBe(201);
    }

    expect(
      (
        await fixture.app.request("/api/v1/pairings", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "CF-Connecting-IP": "192.0.2.10",
          },
          body: JSON.stringify({ device_display_name: "Limited device" }),
        })
      ).status,
    ).toBe(429);
    expect(
      (
        await fixture.app.request("/api/v1/pairings", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "CF-Connecting-IP": "192.0.2.11",
          },
          body: JSON.stringify({ device_display_name: "Other client device" }),
        })
      ).status,
    ).toBe(201);
  });

  it("creates and permanently deletes an anonymous managed controller", async () => {
    const fixture = await makeManagedFixture();
    const createResponse = await fixture.app.request("/api/v1/controllers", { method: "POST" });

    expect(createResponse.status).toBe(201);
    expect(createResponse.headers.get("Cache-Control")).toBe("no-store");
    const { controller_token: controllerToken } = ControllerCreateResponseSchema.parse(
      await createResponse.json(),
    );
    expect(controllerToken.length).toBeGreaterThanOrEqual(32);

    const database = new Database(fixture.databasePath, { readonly: true, strict: true });
    const persisted = database
      .query<{ id: string; token_hash: string }, []>(
        `SELECT controllers.id, controller_sessions.token_hash
         FROM controllers
         INNER JOIN controller_sessions ON controller_sessions.controller_id = controllers.id`,
      )
      .get();
    expect(persisted?.id.startsWith("controller_")).toBe(true);
    expect(persisted?.token_hash).toHaveLength(64);
    expect(persisted?.token_hash).not.toBe(controllerToken);
    database.close();

    await fixture.state.registerDevice({
      id: "device_managed_delete",
      controller_id: persisted?.id ?? "",
      display_name: "Managed deletable device",
      token_hash: "managed-device-token-hash",
      created_at: "2026-08-03T01:00:00Z",
    });
    await fixture.state.recordSnapshot(
      snapshotEnvelope("device_managed_delete", 1),
      "2026-08-03T01:05:01Z",
    );

    const deleteResponse = await fixture.app.request("/api/v1/controllers/self", {
      method: "DELETE",
      headers: bearerHeaders(controllerToken),
    });
    expect(deleteResponse.status).toBe(204);
    expect(await getWithBearer(fixture.app, "/api/v1/devices", controllerToken)).toMatchObject({
      status: 401,
    });

    const deleted = new Database(fixture.databasePath, { readonly: true, strict: true });
    for (const table of ["controllers", "controller_sessions", "devices", "quota_snapshots"]) {
      expect(
        deleted.query<{ count: number }, []>(`SELECT COUNT(*) AS count FROM ${table}`).get()?.count,
      ).toBe(0);
    }
    deleted.close();

    const selfHosted = await makeFixture();
    expect((await selfHosted.app.request("/api/v1/controllers", { method: "POST" })).status).toBe(
      404,
    );
    expect(
      (
        await selfHosted.app.request("/api/v1/controllers/self", {
          method: "DELETE",
          headers: bearerHeaders(controllerManageToken),
        })
      ).status,
    ).toBe(404);
  });

  it("persistently limits anonymous controller creation by trusted client address", async () => {
    const fixture = await makeManagedFixture();
    for (let index = 0; index < 10; index += 1) {
      const response = await fixture.app.request("/api/v1/controllers", {
        method: "POST",
        headers: { "CF-Connecting-IP": "192.0.2.10" },
      });
      expect(response.status).toBe(201);
    }

    const limited = await fixture.app.request("/api/v1/controllers", {
      method: "POST",
      headers: {
        "CF-Connecting-IP": "192.0.2.10",
        "X-Forwarded-For": "198.51.100.20",
      },
    });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("3600");

    const otherClient = await fixture.app.request("/api/v1/controllers", {
      method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.11" },
    });
    expect(otherClient.status).toBe(201);
  });

  it("lets a device revoke only itself", async () => {
    const fixture = await makeFixture();
    const selfToken = "self-revoking-device-token";
    const otherToken = "other-device-token";
    await fixture.state.registerDevice({
      id: "device_self",
      controller_id: "controller_http",
      display_name: "Self-revoking device",
      token_hash: await sha256Hex(selfToken),
      created_at: "2026-08-03T01:00:00Z",
    });
    await fixture.state.registerDevice({
      id: "device_other",
      controller_id: "controller_http",
      display_name: "Other device",
      token_hash: await sha256Hex(otherToken),
      created_at: "2026-08-03T01:00:00Z",
    });

    const otherDeviceAttempt = await fixture.app.request("/api/v1/devices/device_other", {
      method: "DELETE",
      headers: bearerHeaders(selfToken),
    });
    expect(otherDeviceAttempt.status).toBe(401);

    const selfRevoke = await fixture.app.request("/api/v1/devices/self", {
      method: "DELETE",
      headers: bearerHeaders(selfToken),
    });
    expect(selfRevoke.status).toBe(204);
    expect(
      (await fixture.state.getDeviceByTokenHash(await sha256Hex(selfToken)))?.revoked_at,
    ).not.toBeNull();
    expect(await fixture.state.getDeviceByTokenHash(await sha256Hex(otherToken))).not.toBeNull();

    const repeatedSelfRevoke = await fixture.app.request("/api/v1/devices/self", {
      method: "DELETE",
      headers: bearerHeaders(selfToken),
    });
    expect(repeatedSelfRevoke.status).toBe(204);
    expect(
      (
        await fixture.app.request("/api/v1/devices/self", {
          method: "DELETE",
          headers: bearerHeaders("unknown-device-token"),
        })
      ).status,
    ).toBe(401);
  });

  it("expires devices at 30 days without sweeping another controller on request paths", async () => {
    const fixture = await makeFixture();
    const staleToken = "stale-device-token";
    const otherStaleToken = "other-stale-device-token";
    await fixture.state.registerDevice({
      id: "device_stale",
      controller_id: "controller_http",
      display_name: "Stale device",
      token_hash: await sha256Hex(staleToken),
      created_at: "2026-07-04T01:00:00Z",
    });
    await fixture.state.registerDevice({
      id: "device_other_stale",
      controller_id: "controller_other",
      display_name: "Other stale device",
      token_hash: await sha256Hex(otherStaleToken),
      created_at: "2026-07-04T01:00:00Z",
    });

    const expiredUpload = await postJSON(
      fixture.app,
      "/api/v1/snapshots",
      snapshotEnvelope("device_stale", 1),
      staleToken,
    );
    expect(expiredUpload.status).toBe(401);
    expect(
      (await fixture.state.getDeviceByTokenHash(await sha256Hex(staleToken)))?.revoked_at,
    ).not.toBeNull();
    expect(
      await fixture.state.getDeviceByTokenHash(await sha256Hex(otherStaleToken)),
    ).not.toBeNull();

    const controllerRead = await getWithBearer(
      fixture.app,
      "/api/v1/devices",
      controllerManageToken,
    );
    expect(controllerRead.status).toBe(200);
    expect(
      await fixture.state.getDeviceByTokenHash(await sha256Hex(otherStaleToken)),
    ).not.toBeNull();
  });

  it("reclaims abandoned managed controllers and old pairing sessions", async () => {
    const fixture = await makeManagedFixture();
    const controllerResponse = await fixture.app.request("/api/v1/controllers", {
      method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.10" },
    });
    const { controller_token: controllerToken } = ControllerCreateResponseSchema.parse(
      await controllerResponse.json(),
    );
    await createPairing(fixture.app, "Abandoned pairing");

    await performRelayMaintenance(fixture.state, new Date("2026-09-03T01:11:00Z"));

    expect(await getWithBearer(fixture.app, "/api/v1/devices", controllerToken)).toMatchObject({
      status: 401,
    });
    const database = new Database(fixture.databasePath, { readonly: true, strict: true });
    expect(
      database.query<{ count: number }, []>("SELECT COUNT(*) AS count FROM controllers").get()
        ?.count,
    ).toBe(0);
    expect(
      database.query<{ count: number }, []>("SELECT COUNT(*) AS count FROM pairing_sessions").get()
        ?.count,
    ).toBe(0);
    database.close();
  });
});

async function makeFixture() {
  const directory = mkdtempSync(join(tmpdir(), "quota-relay-http-test-"));
  const databasePath = join(directory, "relay.db");
  const state = new SQLiteRelayState(databasePath);
  await state.initialize();
  await state.ensureController("controller_http", "permanent", "2026-08-03T00:00:00Z");
  await state.ensureController("controller_other", "permanent", "2026-08-03T00:00:00Z");
  await state.replaceControllerSession({
    id: "auth_manage",
    controller_id: "controller_http",
    token_hash: await sha256Hex(controllerManageToken),
    scopes: ["device:manage"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });
  await state.replaceControllerSession({
    id: "auth_other_manage",
    controller_id: "controller_other",
    token_hash: await sha256Hex(otherControllerManageToken),
    scopes: ["device:manage"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });
  await state.replaceControllerSession({
    id: "auth_read",
    controller_id: "controller_http",
    token_hash: await sha256Hex(controllerReadToken),
    scopes: ["quota:read"],
    expires_at: "2026-08-04T00:00:00Z",
    created_at: "2026-08-03T00:00:00Z",
  });

  let currentTime = new Date("2026-08-03T01:00:00Z");
  return {
    app: createRelayApp({ state, relayInfo, now: () => currentTime }),
    databasePath,
    state,
    setNow(value: string) {
      currentTime = new Date(value);
    },
  };
}

async function makeManagedFixture() {
  const directory = mkdtempSync(join(tmpdir(), "quota-relay-managed-http-test-"));
  const databasePath = join(directory, "relay.db");
  const state = new SQLiteRelayState(databasePath);
  await state.initialize();
  return {
    app: createRelayApp({
      state,
      relayInfo: managedRelayInfo("managed-http-test"),
      now: () => new Date("2026-08-03T01:00:00Z"),
    }),
    databasePath,
    state,
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

function snapshotEnvelope(deviceID: string, sequence: number): QuotaSnapshotEnvelope {
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
    .query<{ token_hash: string }, []>("SELECT token_hash FROM controller_sessions ORDER BY id")
    .all();

  expect(pairing?.device_code_hash).not.toBe(rawDeviceCode);
  expect(pairing?.user_code_hash).not.toBe(rawUserCode);
  expect(pairing?.device_code_hash).toHaveLength(64);
  expect(pairing?.user_code_hash).toHaveLength(64);
  expect(device?.token_hash).not.toBe(rawDeviceToken);
  expect(device?.token_hash).toHaveLength(64);
  expect(auth.every(({ token_hash }) => token_hash.length === 64)).toBe(true);
  expect(auth.some(({ token_hash }) => token_hash === controllerManageToken)).toBe(false);
  expect(auth.some(({ token_hash }) => token_hash === controllerReadToken)).toBe(false);
  database.close();
}
