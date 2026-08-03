import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

describe("SQLiteRelayState", () => {
  it("persists the latest normalized snapshot", async () => {
    const state = await makeState();
    await state.recordSnapshot({
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
    });

    const snapshots = await state.listLatestSnapshots("owner_01");
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0]?.snapshot.provider).toBe("codex");
  });

  it("ignores replayed and out-of-order device sequences", async () => {
    const state = await makeState();

    await state.recordSnapshot(envelope(2, 20, "2026-08-02T02:00:00Z"));
    await state.recordSnapshot(envelope(2, 99, "2026-08-02T03:00:00Z"));
    await state.recordSnapshot(envelope(1, 10, "2026-08-02T01:00:00Z"));

    const snapshots = await state.listLatestSnapshots("owner_01");
    const device = await state.getDevice("device_01");
    expect(snapshots[0]?.snapshot.windows[0]?.used_percent).toBe(20);
    expect(device?.last_sequence).toBe(2);
    expect(device?.last_seen_at).not.toBe("2026-08-02T01:00:00Z");
  });

  it("keeps matching provider accounts from different devices as separate observations", async () => {
    const state = await makeState();
    await registerDevice(state, "device_02");

    await state.recordSnapshot(envelopeForDevice("device_01", 1, 20, "2026-08-02T01:00:00Z"));
    await state.recordSnapshot(envelopeForDevice("device_02", 1, 40, "2026-08-02T01:05:00Z"));

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

    await state.recordSnapshot(envelopeForDevice("device_01", 1, 20, "2026-08-02T01:00:00Z"));
    await state.recordSnapshot(envelopeForDevice("device_02", 1, 40, "2026-08-02T01:05:00Z"));
    await state.recordSnapshot(envelopeForDevice("device_01", 2, 30, "2026-08-02T02:00:00Z"));

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

    await expect(state.recordSnapshot(envelope(1, 20, "2026-08-02T01:00:00Z"))).rejects.toThrow(
      "missing or revoked",
    );
    expect(await state.listLatestSnapshots("owner_01")).toHaveLength(0);
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

    const device = await state.getActiveDeviceByTokenHash("paired-token-hash-01");
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
    await state.replaceAuthSession({
      id: "auth_01",
      owner_id: "owner_01",
      token_hash: "owner-token-hash-01",
      scopes: ["quota:read", "device:manage"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    const session = await state.getActiveAuthSessionByTokenHash(
      "owner-token-hash-01",
      "2026-08-02T01:30:00Z",
    );
    expect(session?.owner_id).toBe("owner_01");
    expect(session?.scopes).toEqual(["quota:read", "device:manage"]);
    expect(
      await state.getActiveAuthSessionByTokenHash("owner-token-hash-01", "2026-08-02T02:00:00Z"),
    ).toBeNull();
  });

  it("does not transfer an authentication session to another owner", async () => {
    const state = await makeState();
    await state.ensureOwner("owner_02", "2026-08-02T00:00:00Z");
    await state.replaceAuthSession({
      id: "auth_fixed",
      owner_id: "owner_01",
      token_hash: "owner-token-hash-01",
      scopes: ["quota:read"],
      expires_at: "2026-08-02T02:00:00Z",
      created_at: "2026-08-02T01:00:00Z",
    });

    await expect(
      state.replaceAuthSession({
        id: "auth_fixed",
        owner_id: "owner_02",
        token_hash: "owner-token-hash-02",
        scopes: ["device:manage"],
        expires_at: "2026-08-02T03:00:00Z",
        created_at: "2026-08-02T01:30:00Z",
      }),
    ).rejects.toThrow("owner does not match");
    expect(
      await state.getActiveAuthSessionByTokenHash("owner-token-hash-01", "2026-08-02T01:45:00Z"),
    ).toEqual({ owner_id: "owner_01", scopes: ["quota:read"] });
    expect(
      await state.getActiveAuthSessionByTokenHash("owner-token-hash-02", "2026-08-02T01:45:00Z"),
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
    expect((await state.getActiveDeviceByTokenHash("test-token-hash"))?.id).toBe("device_01");

    await state.revokeDevice("owner_01", "device_01", "2026-08-02T01:00:00Z");

    expect(await state.getActiveDeviceByTokenHash("test-token-hash")).toBeNull();
  });
});

describe("QuotaRelay SQLite migrations", () => {
  it("applies 0001 then 0002 with usable constraints and migrated auth scopes", () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-migration-test-"));
    const database = new Database(join(directory, "relay.db"), { create: true, strict: true });
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
      .query("INSERT INTO users (id, created_at) VALUES (?1, ?2)")
      .run("owner_migration", "2026-08-03T00:00:00Z");
    database
      .query(
        `INSERT INTO devices (id, owner_id, display_name, token_hash, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .run(
        "device_migration",
        "owner_migration",
        "Existing device",
        "existing-device-token-hash",
        "2026-08-03T00:00:00Z",
      );
    database
      .query(
        `INSERT INTO auth_sessions (id, owner_id, token_hash, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .run(
        "auth_migration",
        "owner_migration",
        "existing-owner-token-hash",
        "2026-08-04T00:00:00Z",
        "2026-08-03T00:00:00Z",
      );

    database.exec(pairingAuthMigration);

    const deviceColumns = database.query<{ name: string }, []>("PRAGMA table_info(devices)").all();
    const authColumns = database
      .query<{ name: string }, []>("PRAGMA table_info(auth_sessions)")
      .all();
    expect(deviceColumns.some(({ name }) => name === "pairing_session_id")).toBe(true);
    expect(authColumns.some(({ name }) => name === "scopes_json")).toBe(true);
    expect(
      database
        .query<{ scopes_json: string }, []>(
          "SELECT scopes_json FROM auth_sessions WHERE id = 'auth_migration'",
        )
        .get()?.scopes_json,
    ).toBe("[]");

    const pairingForeignKey = database
      .query<{ table: string; from: string; to: string; on_delete: string }, []>(
        "PRAGMA foreign_key_list(devices)",
      )
      .all()
      .find(({ from }) => from === "pairing_session_id");
    expect(pairingForeignKey).toMatchObject({
      table: "pairing_sessions",
      from: "pairing_session_id",
      to: "id",
      on_delete: "SET NULL",
    });

    const pairingIndex = database
      .query<{ name: string; unique: number; partial: number }, []>("PRAGMA index_list(devices)")
      .all()
      .find(({ name }) => name === "devices_pairing_session_id_idx");
    expect(pairingIndex).toMatchObject({ unique: 1, partial: 1 });

    database
      .query(
        `INSERT INTO pairing_sessions
          (id, device_code_hash, user_code_hash, device_display_name, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
      )
      .run(
        "pairing_migration",
        "device-code-hash-migration",
        "user-code-hash-migration",
        "Migrated pairing",
        "2026-08-03T01:10:00Z",
        "2026-08-03T01:00:00Z",
      );
    database
      .query("UPDATE devices SET pairing_session_id = ?2 WHERE id = ?1")
      .run("device_migration", "pairing_migration");
    expect(() =>
      database
        .query(
          `INSERT INTO devices
            (id, owner_id, display_name, token_hash, pairing_session_id, created_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
        )
        .run(
          "device_duplicate_pairing",
          "owner_migration",
          "Duplicate pairing device",
          "duplicate-pairing-token-hash",
          "pairing_migration",
          "2026-08-03T01:00:00Z",
        ),
    ).toThrow();

    database
      .query(
        `INSERT INTO rate_limit_counters
          (key_hash, window_started_at, window_expires_at, request_count)
         VALUES (?1, ?2, ?3, ?4)`,
      )
      .run("rate-limit-key-hash-migration", "2026-08-03T01:00:00Z", "2026-08-03T01:10:00Z", 1);
    expect(
      database
        .query<{ request_count: number }, []>(
          "SELECT request_count FROM rate_limit_counters WHERE key_hash = 'rate-limit-key-hash-migration'",
        )
        .get()?.request_count,
    ).toBe(1);

    database.query("DELETE FROM pairing_sessions WHERE id = ?1").run("pairing_migration");
    expect(
      database
        .query<{ pairing_session_id: string | null }, []>(
          "SELECT pairing_session_id FROM devices WHERE id = 'device_migration'",
        )
        .get()?.pairing_session_id,
    ).toBeNull();
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
    display_name: "Edge Mac",
    token_hash: "test-token-hash",
    created_at: "2026-08-02T00:00:00Z",
  });
  return { path, state };
}

async function registerDevice(state: SQLiteRelayState, deviceId: string): Promise<void> {
  await state.registerDevice({
    id: deviceId,
    owner_id: "owner_01",
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
