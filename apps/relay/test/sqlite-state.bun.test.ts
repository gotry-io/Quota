import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

describe("SQLiteRelayState", () => {
  it("stamps fresh databases at the current schema version", async () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-schema-test-"));
    const path = join(directory, "relay.db");
    const state = new SQLiteRelayState(path);

    await state.initialize();
    await state.initialize();

    const database = new Database(path, { readonly: true, strict: true });
    expect(
      database.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version,
    ).toBe(2);
    expect(
      database
        .query<{ sql: string }, []>(
          "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'quota_snapshots'",
        )
        .get()?.sql,
    ).not.toContain("provider IN");
    database.close();
  });

  it("migrates the released provider whitelist without losing snapshots", async () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-migration-test-"));
    const path = join(directory, "relay.db");
    const database = new Database(path, { create: true, strict: true });
    database.exec(readFileSync(new URL("../migrations/0001_initial.sql", import.meta.url), "utf8"));
    database
      .query("INSERT INTO owners (id, created_at) VALUES (?1, ?2)")
      .run("owner_01", "2026-08-02T00:00:00Z");
    database
      .query(
        `INSERT INTO devices
          (id, owner_id, display_name, token_hash, created_at, last_seen_at, last_sequence)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .run(
        "device_01",
        "owner_01",
        "Relay Mac",
        "test-token-hash",
        "2026-08-02T00:00:00Z",
        "2026-08-02T01:00:01Z",
        1,
      );
    const codexSnapshot = snapshot("codex", "codex_api", "2026-08-02T01:00:00Z");
    database
      .query(
        `INSERT INTO quota_snapshots
          (device_id, provider, account_fingerprint, sequence, captured_at,
           observed_at, snapshot_json, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .run(
        "device_01",
        codexSnapshot.provider,
        codexSnapshot.account.fingerprint,
        1,
        codexSnapshot.observed_at,
        codexSnapshot.observed_at,
        JSON.stringify(codexSnapshot),
        "2026-08-02T01:00:01Z",
      );
    database.close();

    const state = new SQLiteRelayState(path);
    await state.initialize();
    const deepseekSnapshot = snapshot("deepseek", "deepseek_balance_api", "2026-08-02T02:00:00Z");
    await state.recordSnapshot(
      {
        schema_version: 1,
        device_id: "device_01",
        sequence: 2,
        captured_at: deepseekSnapshot.observed_at,
        snapshots: [deepseekSnapshot],
      },
      "2026-08-02T02:00:01Z",
    );

    expect(
      (await state.listLatestSnapshots("owner_01")).map(({ snapshot }) => snapshot.provider),
    ).toEqual(["deepseek", "codex"]);
    const migrated = new Database(path, { readonly: true, strict: true });
    expect(
      migrated.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version,
    ).toBe(2);
    expect(migrated.query("PRAGMA foreign_key_check").all()).toEqual([]);
    migrated.close();
  });

  it("persists the latest normalized snapshot", async () => {
    const state = await makeState();
    await state.recordSnapshot(
      {
        schema_version: 1,
        device_id: "device_01",
        sequence: 1,
        captured_at: "2026-08-02T01:00:00Z",
        snapshots: [
          {
            provider: "codex",
            account: { fingerprint: "account_01", fingerprint_scope: "source" as const },
            windows: [{ id: "five_hour", title: "5 hour", used_percent: 20 }],
            source: "codex_api",
            status: "available",
            observed_at: "2026-08-02T01:00:00Z",
          },
        ],
      },
      "2026-08-02T01:00:01Z",
    );

    const snapshots = await state.listLatestSnapshots("owner_01");
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0]?.snapshot.provider).toBe("codex");
  });

  it("ignores replayed and out-of-order device sequences", async () => {
    const state = await makeState();

    await state.recordSnapshot(envelope(2, 20, "2026-08-02T02:00:00Z"), "2026-08-02T02:00:01Z");
    await state.recordSnapshot(envelope(2, 99, "2026-08-02T03:00:00Z"), "2026-08-02T03:00:01Z");
    await state.recordSnapshot(envelope(1, 10, "2026-08-02T01:00:00Z"), "2026-08-02T04:00:01Z");

    const snapshots = await state.listLatestSnapshots("owner_01");
    const device = await state.getDevice("device_01");
    expect(snapshots[0]?.snapshot.windows[0]?.used_percent).toBe(20);
    expect(device?.last_sequence).toBe(2);
    expect(device?.last_seen_at).toBe("2026-08-02T04:00:01Z");
  });

  it("keeps matching provider accounts from different devices as separate observations", async () => {
    const state = await makeState();
    await registerDevice(state, "device_02");

    await state.recordSnapshot(
      envelopeForDevice("device_01", 1, 20, "2026-08-02T01:00:00Z"),
      "2026-08-02T01:00:01Z",
    );
    await state.recordSnapshot(
      envelopeForDevice("device_02", 1, 40, "2026-08-02T01:05:00Z"),
      "2026-08-02T01:05:01Z",
    );

    const snapshots = await state.listLatestSnapshots("owner_01");
    expect(snapshots).toHaveLength(2);
    expect(snapshots.map((snapshot) => snapshot.device_id).sort()).toEqual([
      "device_01",
      "device_02",
    ]);
    expect(
      snapshots.every(
        ({ snapshot }) =>
          snapshot.provider === "codex" && snapshot.account.fingerprint === "account_01",
      ),
    ).toBe(true);
  });

  it("updates only the matching device observation", async () => {
    const state = await makeState();
    await registerDevice(state, "device_02");

    await state.recordSnapshot(
      envelopeForDevice("device_01", 1, 20, "2026-08-02T01:00:00Z"),
      "2026-08-02T01:00:01Z",
    );
    await state.recordSnapshot(
      envelopeForDevice("device_02", 1, 40, "2026-08-02T01:05:00Z"),
      "2026-08-02T01:05:01Z",
    );
    await state.recordSnapshot(
      envelopeForDevice("device_01", 2, 30, "2026-08-02T02:00:00Z"),
      "2026-08-02T02:00:01Z",
    );

    const snapshots = await state.listLatestSnapshots("owner_01");
    const firstDevice = snapshots.find((snapshot) => snapshot.device_id === "device_01");
    const secondDevice = snapshots.find((snapshot) => snapshot.device_id === "device_02");

    expect(snapshots).toHaveLength(2);
    expect(firstDevice?.sequence).toBe(2);
    expect(firstDevice?.captured_at).toBe("2026-08-02T02:00:00Z");
    expect(firstDevice?.snapshot.windows[0]?.used_percent).toBe(30);
    expect(secondDevice?.sequence).toBe(1);
    expect(secondDevice?.captured_at).toBe("2026-08-02T01:05:00Z");
    expect(secondDevice?.snapshot.windows[0]?.used_percent).toBe(40);
  });

  it("rejects snapshots from a revoked device", async () => {
    const state = await makeState();
    await state.revokeDevice("owner_01", "device_01", "2026-08-02T00:30:00Z");

    await expect(
      state.recordSnapshot(envelope(1, 20, "2026-08-02T01:00:00Z"), "2026-08-02T01:00:01Z"),
    ).rejects.toThrow("missing or revoked");
    expect(await state.listLatestSnapshots("owner_01")).toHaveLength(0);
  });

  it("approves and consumes a pairing session exactly once", async () => {
    const state = await makeState();
    await state.createPairingSession({
      id: "pairing_01",
      device_code_hash: "device-code-hash-01",
      user_code_hash: "user-code-hash-01",
      device_display_name: "Paired Relay Mac",
      expires_at: "2026-08-02T01:10:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    expect(
      await state.consumePairingSession({
        device_code_hash: "device-code-hash-01",
        device_id: "device_02",
        token_hash: "paired-token-hash-01",
        consumed_at: "2026-08-02T01:01:00Z",
      }),
    ).toBe("pending");
    expect(
      await state.decidePairingSession({
        user_code_hash: "user-code-hash-01",
        owner_id: "owner_01",
        decision: "approve",
        decided_at: "2026-08-02T01:02:00Z",
      }),
    ).toBe("approved");
    await expect(
      state.consumePairingSession({
        device_code_hash: "device-code-hash-01",
        device_id: "device_01",
        token_hash: "colliding-token-hash",
        consumed_at: "2026-08-02T01:03:00Z",
      }),
    ).rejects.toThrow();
    expect(
      await state.consumePairingSession({
        device_code_hash: "device-code-hash-01",
        device_id: "device_02",
        token_hash: "paired-token-hash-01",
        consumed_at: "2026-08-02T01:04:00Z",
      }),
    ).toBe("issued");
    expect(
      await state.consumePairingSession({
        device_code_hash: "device-code-hash-01",
        device_id: "device_03",
        token_hash: "paired-token-hash-02",
        consumed_at: "2026-08-02T01:05:00Z",
      }),
    ).toBe("consumed");

    const device = await state.getDeviceByTokenHash("paired-token-hash-01");
    expect(device?.id).toBe("device_02");
    expect(device?.owner_id).toBe("owner_01");
    expect(await state.getDevice("device_03")).toBeNull();
  });

  it("does not issue credentials for denied or expired pairing sessions", async () => {
    const state = await makeState();
    await state.createPairingSession({
      id: "pairing_denied",
      device_code_hash: "device-code-hash-denied",
      user_code_hash: "user-code-hash-denied",
      device_display_name: "Denied Device",
      expires_at: "2026-08-02T01:10:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });
    await state.createPairingSession({
      id: "pairing_expired",
      device_code_hash: "device-code-hash-expired",
      user_code_hash: "user-code-hash-expired",
      device_display_name: "Expired Device",
      expires_at: "2026-08-02T01:05:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    expect(
      await state.decidePairingSession({
        user_code_hash: "user-code-hash-denied",
        owner_id: "owner_01",
        decision: "deny",
        decided_at: "2026-08-02T01:01:00Z",
      }),
    ).toBe("denied");
    expect(
      await state.consumePairingSession({
        device_code_hash: "device-code-hash-denied",
        device_id: "device_denied",
        token_hash: "denied-token-hash",
        consumed_at: "2026-08-02T01:02:00Z",
      }),
    ).toBe("denied");
    expect(
      await state.decidePairingSession({
        user_code_hash: "user-code-hash-expired",
        owner_id: "owner_01",
        decision: "approve",
        decided_at: "2026-08-02T01:05:00Z",
      }),
    ).toBe("expired");
    expect(
      await state.consumePairingSession({
        device_code_hash: "device-code-hash-expired",
        device_id: "device_expired",
        token_hash: "expired-token-hash",
        consumed_at: "2026-08-02T01:06:00Z",
      }),
    ).toBe("expired");
    expect(await state.getDevice("device_denied")).toBeNull();
    expect(await state.getDevice("device_expired")).toBeNull();
  });

  it("looks up only active owner sessions with their exact scopes", async () => {
    const state = await makeState();
    await state.replaceOwnerSession({
      id: "auth_01",
      owner_id: "owner_01",
      token_hash: "owner-token-hash-01",
      scopes: ["quota:read", "device:manage"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    const session = await state.getActiveOwnerSessionByTokenHash(
      "owner-token-hash-01",
      "2026-08-02T01:30:00Z",
    );
    expect(session?.owner_id).toBe("owner_01");
    expect(session?.scopes).toEqual(["quota:read", "device:manage"]);
    expect(
      await state.getActiveOwnerSessionByTokenHash("owner-token-hash-01", "2026-08-02T02:00:00Z"),
    ).toBeNull();
  });

  it("does not transfer an authentication session to another owner", async () => {
    const state = await makeState();
    await state.ensureOwner("owner_02", "2026-08-02T00:00:00Z");
    await state.replaceOwnerSession({
      id: "auth_fixed",
      owner_id: "owner_01",
      token_hash: "owner-token-hash-01",
      scopes: ["quota:read"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    await expect(
      state.replaceOwnerSession({
        id: "auth_fixed",
        owner_id: "owner_02",
        token_hash: "owner-token-hash-02",
        scopes: ["device:manage"],
        expires_at: "2026-08-02T03:00:00Z",
        created_at: "2026-08-02T01:30:00Z",
      }),
    ).rejects.toThrow("does not match the owner");
    expect(
      await state.getActiveOwnerSessionByTokenHash("owner-token-hash-01", "2026-08-02T01:45:00Z"),
    ).toEqual({ owner_id: "owner_01", scopes: ["quota:read"] });
    expect(
      await state.getActiveOwnerSessionByTokenHash("owner-token-hash-02", "2026-08-02T01:45:00Z"),
    ).toBeNull();
  });

  it("persists and atomically counts fixed-window rate limits", async () => {
    const { path, state } = await makeStateWithPath();
    const request = {
      key_hash: "rate-limit-key-hash",
      window_started_at: "2026-08-02T01:00:00Z",
      window_expires_at: "2026-08-02T01:01:00Z",
      checked_at: "2026-08-02T01:00:30Z",
      limit: 2,
    };

    expect(await state.consumeRateLimit(request)).toEqual({ allowed: true, retry_after: 0 });
    expect(await state.consumeRateLimit(request)).toEqual({ allowed: true, retry_after: 0 });
    expect(await state.consumeRateLimit(request)).toEqual({ allowed: false, retry_after: 30 });
    expect(
      await state.consumeRateLimit({
        ...request,
        window_started_at: "2026-08-02T01:01:00Z",
        window_expires_at: "2026-08-02T01:02:00Z",
        checked_at: "2026-08-02T01:01:00Z",
      }),
    ).toEqual({ allowed: true, retry_after: 0 });

    const database = new Database(path, { readonly: true, strict: true });
    expect(
      database
        .query<{ count: number }, []>("SELECT COUNT(*) AS count FROM rate_limit_counters")
        .get()?.count,
    ).toBe(1);
    database.close();
  });

  it("rejects a revoked device token lookup", async () => {
    const state = await makeState();
    expect((await state.getDeviceByTokenHash("test-token-hash"))?.id).toBe("device_01");

    await state.revokeDevice("owner_01", "device_01", "2026-08-02T01:00:00Z");

    expect((await state.getDeviceByTokenHash("test-token-hash"))?.revoked_at).toBe(
      "2026-08-02T01:00:00Z",
    );
  });

  it("creates and deletes an owner with all dependent data", async () => {
    const state = await makeState();
    await state.createOwner({
      id: "owner_deletable",
      session_id: "owner_session_deletable",
      token_hash: "owner-token-hash-deletable",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-08-02T00:00:00Z",
    });
    await state.registerDevice({
      id: "device_deletable",
      owner_id: "owner_deletable",
      display_name: "Deletable Device",
      token_hash: "device-token-hash-deletable",
      created_at: "2026-08-02T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_deletable", 1, 20, "2026-08-02T01:00:00Z"),
      "2026-08-02T01:00:01Z",
    );

    expect(await state.deleteOwner("owner_deletable")).toBe(true);
    expect(await state.deleteOwner("owner_deletable")).toBe(false);
    expect(
      await state.getActiveOwnerSessionByTokenHash(
        "owner-token-hash-deletable",
        "2026-08-02T02:00:00Z",
      ),
    ).toBeNull();
    expect(await state.getDevice("device_deletable")).toBeNull();
    expect(await state.listLatestSnapshots("owner_deletable")).toEqual([]);
  });

  it("scopes request-time inactivity revocation across owner groups", async () => {
    const state = await makeState();
    // Younger owner so maintenance does not GC the group while testing device revoke.
    await state.ensureOwner("owner_02", "2026-08-20T00:00:00Z");
    await state.registerDevice({
      id: "device_02",
      owner_id: "owner_02",
      display_name: "Other owner device",
      token_hash: "other-owner-device-token-hash",
      created_at: "2026-08-01T00:00:00Z",
    });

    expect(
      await state.revokeInactiveDevicesForOwner(
        "owner_01",
        "2026-08-02T00:00:00Z",
        "2026-09-01T00:00:00Z",
      ),
    ).toBe(1);
    expect((await state.getDeviceByTokenHash("test-token-hash"))?.revoked_at).not.toBeNull();
    expect(await state.getDeviceByTokenHash("other-owner-device-token-hash")).not.toBeNull();

    await state.performMaintenance({
      inactive_before: "2026-08-02T00:00:00Z",
      pairing_expired_before: "2026-08-31T00:00:01Z",
      maintained_at: "2026-09-01T00:00:01Z",
    });
    expect((await state.getDeviceByTokenHash("other-owner-device-token-hash"))?.revoked_at).toBe(
      "2026-09-01T00:00:01Z",
    );
  });

  it("atomically preserves device activity refreshed after an inactivity read", async () => {
    const state = await makeState();
    await state.recordSnapshot(envelope(1, 20, "2026-09-01T00:00:00Z"), "2026-09-01T00:00:01Z");

    expect(
      await state.revokeDeviceIfInactive(
        "test-token-hash",
        "2026-08-02T00:00:00Z",
        "2026-09-01T00:00:02Z",
      ),
    ).toBe(false);
    expect((await state.getDeviceByTokenHash("test-token-hash"))?.revoked_at).toBeNull();
  });

  it("garbage-collects inactive owners and old pairing sessions", async () => {
    const { path, state } = await makeStateWithPath();
    await state.createOwner({
      id: "owner_abandoned",
      session_id: "session_abandoned",
      token_hash: "owner-token-hash-abandoned",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.createOwner({
      id: "owner_active",
      session_id: "session_active",
      token_hash: "owner-token-hash-active",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.createOwner({
      id: "owner_recently_active",
      session_id: "session_recently_active",
      token_hash: "owner-token-hash-recently-active",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.registerDevice({
      id: "device_active",
      owner_id: "owner_active",
      display_name: "Recently active device",
      token_hash: "device-token-hash-active",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_active", 1, 20, "2026-08-31T00:00:00Z"),
      "2026-08-31T00:00:01Z",
    );
    await state.registerDevice({
      id: "device_recently_active",
      owner_id: "owner_recently_active",
      display_name: "Recently revoked device",
      token_hash: "device-token-hash-recently-active",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_recently_active", 1, 20, "2026-08-31T00:00:00Z"),
      "2026-08-31T00:00:01Z",
    );
    expect(
      await state.revokeDevice(
        "owner_recently_active",
        "device_recently_active",
        "2026-08-31T01:00:00Z",
      ),
    ).toBe(true);
    await state.createPairingSession({
      id: "pairing_old",
      device_code_hash: "device-code-hash-old",
      user_code_hash: "user-code-hash-old",
      device_display_name: "Old pairing",
      expires_at: "2026-08-30T00:00:00Z",
      created_at: "2026-08-29T23:50:00Z",
    });
    await state.createPairingSession({
      id: "pairing_retained",
      device_code_hash: "device-code-hash-retained",
      user_code_hash: "user-code-hash-retained",
      device_display_name: "Retained pairing",
      expires_at: "2026-08-31T00:00:01Z",
      created_at: "2026-08-30T23:50:01Z",
    });

    await state.performMaintenance({
      inactive_before: "2026-08-02T00:00:00Z",
      pairing_expired_before: "2026-08-31T00:00:00Z",
      maintained_at: "2026-09-01T00:00:00Z",
    });

    const database = new Database(path, { readonly: true, strict: true });
    // owner_01 and owner_abandoned are inactive and GC'd; active owners remain.
    expect(database.query<{ id: string }, []>("SELECT id FROM owners ORDER BY id").all()).toEqual([
      { id: "owner_active" },
      { id: "owner_recently_active" },
    ]);
    expect(
      database.query<{ id: string }, []>("SELECT id FROM pairing_sessions ORDER BY id").all(),
    ).toEqual([{ id: "pairing_retained" }]);
    expect(database.query("PRAGMA foreign_key_check").all()).toEqual([]);
    database.close();
  });
});

async function makeState(): Promise<SQLiteRelayState> {
  return (await makeStateWithPath()).state;
}

async function makeStateWithPath(): Promise<{ path: string; state: SQLiteRelayState }> {
  const directory = mkdtempSync(join(tmpdir(), "quota-relay-test-"));
  const path = join(directory, "relay.db");
  const state = new SQLiteRelayState(path);
  await state.initialize();
  await state.ensureOwner("owner_01", "2026-08-02T00:00:00Z");
  await state.registerDevice({
    id: "device_01",
    owner_id: "owner_01",
    display_name: "Relay Mac",
    token_hash: "test-token-hash",
    created_at: "2026-08-02T00:00:00Z",
  });
  return { path, state };
}

async function registerDevice(state: SQLiteRelayState, deviceId: string): Promise<void> {
  await state.registerDevice({
    id: deviceId,
    owner_id: "owner_01",
    display_name: "Second Relay Mac",
    token_hash: `test-token-hash-${deviceId}`,
    created_at: "2026-08-02T00:00:00Z",
  });
}

function envelope(sequence: number, usedPercent: number, capturedAt: string) {
  return envelopeForDevice("device_01", sequence, usedPercent, capturedAt);
}

function envelopeForDevice(
  deviceId: string,
  sequence: number,
  usedPercent: number,
  capturedAt: string,
) {
  return {
    schema_version: 1 as const,
    device_id: deviceId,
    sequence,
    captured_at: capturedAt,
    snapshots: [
      {
        provider: "codex" as const,
        account: { fingerprint: "account_01", fingerprint_scope: "source" as const },
        windows: [{ id: "five_hour", title: "5 hour", used_percent: usedPercent }],
        source: "codex_api",
        status: "available" as const,
        observed_at: capturedAt,
      },
    ],
  };
}

function snapshot(
  provider: "codex" | "deepseek",
  source: "codex_api" | "deepseek_balance_api",
  observedAt: string,
) {
  return {
    provider,
    account: { fingerprint: `account_${provider}`, fingerprint_scope: "source" as const },
    windows: [{ id: "balance", title: "Balance", used_percent: 20 }],
    source,
    status: "available" as const,
    observed_at: observedAt,
  };
}
