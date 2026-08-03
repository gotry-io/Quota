import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

describe("SQLiteRelayState", () => {
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
            account: { fingerprint: "account_01" },
            windows: [{ id: "five_hour", title: "5 hour", used_percent: 20 }],
            source: "codex_api",
            status: "available",
            observed_at: "2026-08-02T01:00:00Z",
          },
        ],
      },
      "2026-08-02T01:00:01Z",
    );

    const snapshots = await state.listLatestSnapshots("controller_01");
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0]?.snapshot.provider).toBe("codex");
  });

  it("ignores replayed and out-of-order device sequences", async () => {
    const state = await makeState();

    await state.recordSnapshot(envelope(2, 20, "2026-08-02T02:00:00Z"), "2026-08-02T02:00:01Z");
    await state.recordSnapshot(envelope(2, 99, "2026-08-02T03:00:00Z"), "2026-08-02T03:00:01Z");
    await state.recordSnapshot(envelope(1, 10, "2026-08-02T01:00:00Z"), "2026-08-02T04:00:01Z");

    const snapshots = await state.listLatestSnapshots("controller_01");
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

    const snapshots = await state.listLatestSnapshots("controller_01");
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

    const snapshots = await state.listLatestSnapshots("controller_01");
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
    await state.revokeDevice("controller_01", "device_01", "2026-08-02T00:30:00Z");

    await expect(
      state.recordSnapshot(envelope(1, 20, "2026-08-02T01:00:00Z"), "2026-08-02T01:00:01Z"),
    ).rejects.toThrow("missing or revoked");
    expect(await state.listLatestSnapshots("controller_01")).toHaveLength(0);
  });

  it("approves and consumes a pairing session exactly once", async () => {
    const state = await makeState();
    await state.createPairingSession({
      id: "pairing_01",
      device_code_hash: "device-code-hash-01",
      user_code_hash: "user-code-hash-01",
      device_display_name: "Paired Edge Mac",
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
        controller_id: "controller_01",
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
    expect(device?.controller_id).toBe("controller_01");
    expect(await state.getDevice("device_03")).toBeNull();
  });

  it("does not issue credentials for denied or expired pairing sessions", async () => {
    const state = await makeState();
    await state.createPairingSession({
      id: "pairing_denied",
      device_code_hash: "device-code-hash-denied",
      user_code_hash: "user-code-hash-denied",
      device_display_name: "Denied Edge",
      expires_at: "2026-08-02T01:10:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });
    await state.createPairingSession({
      id: "pairing_expired",
      device_code_hash: "device-code-hash-expired",
      user_code_hash: "user-code-hash-expired",
      device_display_name: "Expired Edge",
      expires_at: "2026-08-02T01:05:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    expect(
      await state.decidePairingSession({
        user_code_hash: "user-code-hash-denied",
        controller_id: "controller_01",
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
        controller_id: "controller_01",
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

  it("looks up only active controller sessions with their exact scopes", async () => {
    const state = await makeState();
    await state.replaceControllerSession({
      id: "auth_01",
      controller_id: "controller_01",
      token_hash: "controller-token-hash-01",
      scopes: ["quota:read", "device:manage"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    const session = await state.getActiveControllerSessionByTokenHash(
      "controller-token-hash-01",
      "2026-08-02T01:30:00Z",
    );
    expect(session?.controller_id).toBe("controller_01");
    expect(session?.scopes).toEqual(["quota:read", "device:manage"]);
    expect(
      await state.getActiveControllerSessionByTokenHash(
        "controller-token-hash-01",
        "2026-08-02T02:00:00Z",
      ),
    ).toBeNull();
  });

  it("does not transfer an authentication session to another controller", async () => {
    const state = await makeState();
    await state.ensureController("controller_02", "permanent", "2026-08-02T00:00:00Z");
    await state.replaceControllerSession({
      id: "auth_fixed",
      controller_id: "controller_01",
      token_hash: "controller-token-hash-01",
      scopes: ["quota:read"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    await expect(
      state.replaceControllerSession({
        id: "auth_fixed",
        controller_id: "controller_02",
        token_hash: "controller-token-hash-02",
        scopes: ["device:manage"],
        expires_at: "2026-08-02T03:00:00Z",
        created_at: "2026-08-02T01:30:00Z",
      }),
    ).rejects.toThrow("does not match the controller");
    expect(
      await state.getActiveControllerSessionByTokenHash(
        "controller-token-hash-01",
        "2026-08-02T01:45:00Z",
      ),
    ).toEqual({ controller_id: "controller_01", scopes: ["quota:read"] });
    expect(
      await state.getActiveControllerSessionByTokenHash(
        "controller-token-hash-02",
        "2026-08-02T01:45:00Z",
      ),
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

    await state.revokeDevice("controller_01", "device_01", "2026-08-02T01:00:00Z");

    expect((await state.getDeviceByTokenHash("test-token-hash"))?.revoked_at).toBe(
      "2026-08-02T01:00:00Z",
    );
  });

  it("creates and deletes a controller with all dependent data", async () => {
    const state = await makeState();
    await state.createController({
      id: "controller_deletable",
      kind: "managed",
      session_id: "controller_session_deletable",
      token_hash: "controller-token-hash-deletable",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-08-02T00:00:00Z",
    });
    await state.registerDevice({
      id: "device_deletable",
      controller_id: "controller_deletable",
      display_name: "Deletable Edge",
      token_hash: "device-token-hash-deletable",
      created_at: "2026-08-02T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_deletable", 1, 20, "2026-08-02T01:00:00Z"),
      "2026-08-02T01:00:01Z",
    );

    expect(await state.deleteController("controller_deletable")).toBe(true);
    expect(await state.deleteController("controller_deletable")).toBe(false);
    expect(
      await state.getActiveControllerSessionByTokenHash(
        "controller-token-hash-deletable",
        "2026-08-02T02:00:00Z",
      ),
    ).toBeNull();
    expect(await state.getDevice("device_deletable")).toBeNull();
    expect(await state.listLatestSnapshots("controller_deletable")).toEqual([]);
  });

  it("scopes request-time inactivity revocation and keeps permanent controllers in maintenance", async () => {
    const state = await makeState();
    await state.ensureController("controller_02", "permanent", "2026-08-02T00:00:00Z");
    await state.registerDevice({
      id: "device_02",
      controller_id: "controller_02",
      display_name: "Other controller edge",
      token_hash: "other-controller-device-token-hash",
      created_at: "2026-08-02T00:00:00Z",
    });

    expect(
      await state.revokeInactiveDevicesForController(
        "controller_01",
        "2026-08-02T00:00:00Z",
        "2026-09-01T00:00:00Z",
      ),
    ).toBe(1);
    expect((await state.getDeviceByTokenHash("test-token-hash"))?.revoked_at).not.toBeNull();
    expect(await state.getDeviceByTokenHash("other-controller-device-token-hash")).not.toBeNull();

    await state.performMaintenance({
      inactive_before: "2026-08-02T00:00:00Z",
      pairing_expired_before: "2026-08-31T00:00:01Z",
      maintained_at: "2026-09-01T00:00:01Z",
    });
    expect(
      (await state.getDeviceByTokenHash("other-controller-device-token-hash"))?.revoked_at,
    ).toBe("2026-09-01T00:00:01Z");
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

  it("garbage-collects old managed controllers and pairing sessions only", async () => {
    const { path, state } = await makeStateWithPath();
    await state.createController({
      id: "controller_abandoned",
      kind: "managed",
      session_id: "session_abandoned",
      token_hash: "controller-token-hash-abandoned",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.createController({
      id: "controller_active",
      kind: "managed",
      session_id: "session_active",
      token_hash: "controller-token-hash-active",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.createController({
      id: "controller_recently_active",
      kind: "managed",
      session_id: "session_recently_active",
      token_hash: "controller-token-hash-recently-active",
      scopes: ["quota:read", "device:manage"],
      expires_at: "9999-12-31T23:59:59.999Z",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.registerDevice({
      id: "device_active",
      controller_id: "controller_active",
      display_name: "Recently active edge",
      token_hash: "device-token-hash-active",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_active", 1, 20, "2026-08-31T00:00:00Z"),
      "2026-08-31T00:00:01Z",
    );
    await state.registerDevice({
      id: "device_recently_active",
      controller_id: "controller_recently_active",
      display_name: "Recently revoked edge",
      token_hash: "device-token-hash-recently-active",
      created_at: "2026-07-01T00:00:00Z",
    });
    await state.recordSnapshot(
      envelopeForDevice("device_recently_active", 1, 20, "2026-08-31T00:00:00Z"),
      "2026-08-31T00:00:01Z",
    );
    expect(
      await state.revokeDevice(
        "controller_recently_active",
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
    expect(
      database.query<{ id: string }, []>("SELECT id FROM controllers ORDER BY id").all(),
    ).toEqual([
      { id: "controller_01" },
      { id: "controller_active" },
      { id: "controller_recently_active" },
    ]);
    expect(
      database.query<{ id: string }, []>("SELECT id FROM pairing_sessions ORDER BY id").all(),
    ).toEqual([{ id: "pairing_retained" }]);
    expect(database.query("PRAGMA foreign_key_check").all()).toEqual([]);
    database.close();
  });
});

describe("QuotaRelay SQLite migrations", () => {
  it("upgrades 0001 and 0002 data to anonymous controllers without losing relationships", async () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-migration-test-"));
    const databasePath = join(directory, "relay.db");
    const database = new Database(databasePath, { create: true, strict: true });
    const initialMigration = readFileSync(
      new URL("../migrations/0001_initial.sql", import.meta.url),
      "utf8",
    );
    const pairingAuthMigration = readFileSync(
      new URL("../migrations/0002_pairing_auth_api.sql", import.meta.url),
      "utf8",
    );

    database.exec(initialMigration);
    database
      .query("INSERT INTO users (id, external_subject, created_at) VALUES (?1, ?2, ?3)")
      .run("legacy_identity", "legacy-subject", "2026-08-03T00:00:00Z");
    database
      .query(
        `INSERT INTO pairing_sessions
          (id, owner_id, device_code_hash, user_code_hash, device_display_name, expires_at,
           approved_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .run(
        "pairing_migration",
        "legacy_identity",
        "device-code-hash-migration",
        "user-code-hash-migration",
        "Migrated pairing",
        "2026-08-03T01:10:00Z",
        "2026-08-03T01:01:00Z",
        "2026-08-03T01:00:00Z",
      );
    database
      .query(
        `INSERT INTO devices (id, owner_id, display_name, token_hash, created_at, last_seen_at,
                              last_sequence)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .run(
        "device_migration",
        "legacy_identity",
        "Existing device",
        "existing-device-token-hash",
        "2026-08-03T00:00:00Z",
        "2026-08-03T01:05:00Z",
        4,
      );
    database
      .query(
        `INSERT INTO auth_sessions (id, owner_id, token_hash, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .run(
        "session_migration",
        "legacy_identity",
        "existing-controller-token-hash",
        "2026-08-04T00:00:00Z",
        "2026-08-03T00:00:00Z",
      );
    database
      .query(
        `INSERT INTO quota_snapshots
          (device_id, provider, account_fingerprint, sequence, captured_at, observed_at,
           snapshot_json, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .run(
        "device_migration",
        "codex",
        "account_migration",
        4,
        "2026-08-03T01:05:00Z",
        "2026-08-03T01:05:00Z",
        JSON.stringify({
          provider: "codex",
          account: { fingerprint: "account_migration" },
          windows: [{ id: "five_hour", title: "5 hour", used_percent: 25 }],
          source: "codex_api",
          status: "available",
          observed_at: "2026-08-03T01:05:00Z",
        }),
        "2026-08-03T01:05:01Z",
      );

    database.exec(pairingAuthMigration);
    database
      .query("UPDATE devices SET pairing_session_id = ?2 WHERE id = ?1")
      .run("device_migration", "pairing_migration");
    database
      .query("UPDATE auth_sessions SET scopes_json = ?2 WHERE id = ?1")
      .run("session_migration", '["quota:read","device:manage"]');
    database.close();

    const state = new SQLiteRelayState(databasePath);
    await state.initialize();

    expect(
      await state.getActiveControllerSessionByTokenHash(
        "existing-controller-token-hash",
        "2026-08-03T02:00:00Z",
      ),
    ).toEqual({
      controller_id: "legacy_identity",
      scopes: ["quota:read", "device:manage"],
    });
    expect(await state.getDevice("device_migration")).toMatchObject({
      controller_id: "legacy_identity",
      last_seen_at: "2026-08-03T01:05:00Z",
      last_sequence: 4,
    });
    expect(await state.listLatestSnapshots("legacy_identity")).toHaveLength(1);

    const migrated = new Database(databasePath, { readonly: true, strict: true });
    expect(
      migrated
        .query<{ id: string; kind: string; created_at: string }, []>(
          "SELECT id, kind, created_at FROM controllers",
        )
        .get(),
    ).toEqual({
      id: "legacy_identity",
      kind: "permanent",
      created_at: "2026-08-03T00:00:00Z",
    });
    expect(
      migrated
        .query<{ controller_id: string }, []>(
          "SELECT controller_id FROM pairing_sessions WHERE id = 'pairing_migration'",
        )
        .get()?.controller_id,
    ).toBe("legacy_identity");
    expect(
      migrated
        .query<{ pairing_session_id: string | null }, []>(
          "SELECT pairing_session_id FROM devices WHERE id = 'device_migration'",
        )
        .get()?.pairing_session_id,
    ).toBe("pairing_migration");
    expect(
      migrated
        .query<{ name: string }, []>(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('users', 'auth_sessions')",
        )
        .all(),
    ).toEqual([]);
    expect(
      migrated
        .query<{ name: string }, []>("PRAGMA table_info(controllers)")
        .all()
        .map(({ name }) => name),
    ).toEqual(["id", "kind", "created_at"]);
    expect(migrated.query("PRAGMA foreign_key_check").all()).toEqual([]);
    migrated.close();
  });

  it("rolls back the controller rebuild when migration fails", async () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-migration-rollback-test-"));
    const databasePath = join(directory, "relay.db");
    const database = new Database(databasePath, { create: true, strict: true });
    database.exec(readFileSync(new URL("../migrations/0001_initial.sql", import.meta.url), "utf8"));
    database.exec(
      readFileSync(new URL("../migrations/0002_pairing_auth_api.sql", import.meta.url), "utf8"),
    );
    database.query("DROP TABLE auth_sessions").run();
    database.close();

    const state = new SQLiteRelayState(databasePath);
    await expect(state.initialize()).rejects.toThrow();

    const rolledBack = new Database(databasePath, { readonly: true, strict: true });
    const tableNames = rolledBack
      .query<{ name: string }, []>(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      )
      .all()
      .map(({ name }) => name);
    expect(tableNames).toContain("users");
    expect(tableNames).toContain("devices");
    expect(tableNames).not.toContain("controllers");
    expect(tableNames.some((name) => name.endsWith("_legacy"))).toBe(false);
    rolledBack.close();
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
  await state.ensureController("controller_01", "permanent", "2026-08-02T00:00:00Z");
  await state.registerDevice({
    id: "device_01",
    controller_id: "controller_01",
    display_name: "Edge Mac",
    token_hash: "test-token-hash",
    created_at: "2026-08-02T00:00:00Z",
  });
  return { path, state };
}

async function registerDevice(state: SQLiteRelayState, deviceId: string): Promise<void> {
  await state.registerDevice({
    id: deviceId,
    controller_id: "controller_01",
    display_name: "Second Edge Mac",
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
        account: { fingerprint: "account_01" },
        windows: [{ id: "five_hour", title: "5 hour", used_percent: usedPercent }],
        source: "codex_api",
        status: "available" as const,
        observed_at: capturedAt,
      },
    ],
  };
}
