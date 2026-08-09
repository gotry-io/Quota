import { Database } from "bun:sqlite";
import { type QuotaSnapshotEnvelope, QuotaSnapshotSchema } from "@gotry-io/quota-protocol";
import type {
  ConsumePairingSessionInput,
  CreateOwnerInput,
  CreatePairingSessionInput,
  DecidePairingSessionInput,
  DeviceRecord,
  OwnerSessionRecord,
  PairingConsumeOutcome,
  PairingDecisionOutcome,
  RateLimitInput,
  RateLimitResult,
  RegisterDeviceInput,
  RelayMaintenanceInput,
  RelayState,
  ReplaceOwnerSessionInput,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import {
  decodeOwnerSession,
  encodeOwnerScopes,
  type OwnerSessionRow,
  type PairingSessionRow,
  pairingDecisionOutcome,
  pairingUnavailableConsumeOutcome,
  type RateLimitRow,
  rateLimitResult,
  validateRateLimitInput,
} from "./records.ts";
import { SQLITE_MIGRATION_0002, SQLITE_SCHEMA, SQLITE_SCHEMA_VERSION } from "./schema.ts";

interface SnapshotRow {
  device_id: string;
  sequence: number;
  captured_at: string;
  snapshot_json: string;
  updated_at: string;
}

export class SQLiteRelayState implements RelayState {
  private readonly database: Database;

  constructor(path: string) {
    this.database = new Database(path, { create: true, strict: true });
  }

  async initialize(): Promise<void> {
    this.database.exec("PRAGMA foreign_keys = ON");
    const schemaVersion = this.database
      .query<{ user_version: number }, []>("PRAGMA user_version")
      .get();
    if (!schemaVersion) {
      throw new Error("SQLite schema version is unavailable");
    }
    if (schemaVersion.user_version >= SQLITE_SCHEMA_VERSION) {
      return;
    }
    const existingTable = this.database
      .query<{ name: string }, []>(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1",
      )
      .get();
    this.database.transaction(() => {
      this.database.exec(existingTable ? SQLITE_MIGRATION_0002 : SQLITE_SCHEMA);
      this.database.exec(`PRAGMA user_version = ${SQLITE_SCHEMA_VERSION}`);
    })();
  }

  async ping(): Promise<void> {
    this.database.query("SELECT 1 AS ready").get();
  }

  async createOwner(input: CreateOwnerInput): Promise<void> {
    const insertOwner = this.database.query(
      `INSERT INTO owners (id, created_at)
       VALUES (?1, ?2)`,
    );
    const insertSession = this.database.query(
      `INSERT INTO owner_sessions
        (id, owner_id, token_hash, scopes_json, expires_at, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    );
    const transaction = this.database.transaction((value: CreateOwnerInput) => {
      insertOwner.run(value.id, value.created_at);
      insertSession.run(
        value.session_id,
        value.id,
        value.token_hash,
        encodeOwnerScopes(value.scopes),
        value.expires_at,
        value.created_at,
      );
    });
    transaction(input);
  }

  async deleteOwner(ownerId: string): Promise<boolean> {
    const result = this.database.query("DELETE FROM owners WHERE id = ?1").run(ownerId);
    return result.changes > 0;
  }

  async ensureOwner(ownerId: string, createdAt: string): Promise<void> {
    this.database
      .query(
        `INSERT INTO owners (id, created_at)
         VALUES (?1, ?2)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(ownerId, createdAt);
  }

  async replaceOwnerSession(input: ReplaceOwnerSessionInput): Promise<void> {
    const result = this.database
      .query(
        `INSERT INTO owner_sessions
          (id, owner_id, token_hash, scopes_json, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET
           token_hash = excluded.token_hash,
           scopes_json = excluded.scopes_json,
           expires_at = excluded.expires_at,
           revoked_at = NULL
         WHERE owner_sessions.owner_id = excluded.owner_id`,
      )
      .run(
        input.id,
        input.owner_id,
        input.token_hash,
        encodeOwnerScopes(input.scopes),
        input.expires_at,
        input.created_at,
      );
    if (result.changes !== 1) {
      throw new Error("Owner session does not match the owner");
    }
  }

  async getActiveOwnerSessionByTokenHash(
    tokenHash: string,
    checkedAt: string,
  ): Promise<OwnerSessionRecord | null> {
    const row = this.database
      .query<OwnerSessionRow, [string, string]>(
        `SELECT owner_id, scopes_json
         FROM owner_sessions
         WHERE token_hash = ?1 AND revoked_at IS NULL AND expires_at > ?2`,
      )
      .get(tokenHash, checkedAt);

    return row ? decodeOwnerSession(row) : null;
  }

  async registerDevice(input: RegisterDeviceInput): Promise<void> {
    this.database
      .query(
        `INSERT INTO devices
          (id, owner_id, display_name, token_hash, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .run(input.id, input.owner_id, input.display_name, input.token_hash, input.created_at);
  }

  async getDevice(deviceId: string): Promise<DeviceRecord | null> {
    return this.database
      .query<DeviceRecord, [string]>(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
         WHERE id = ?1`,
      )
      .get(deviceId);
  }

  async getDeviceByTokenHash(tokenHash: string): Promise<DeviceRecord | null> {
    return this.database
      .query<DeviceRecord, [string]>(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
       WHERE token_hash = ?1`,
      )
      .get(tokenHash);
  }

  async listDevices(ownerId: string): Promise<DeviceRecord[]> {
    return this.database
      .query<DeviceRecord, [string]>(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
         WHERE owner_id = ?1
         ORDER BY created_at ASC`,
      )
      .all(ownerId);
  }

  async revokeDevice(ownerId: string, deviceId: string, revokedAt: string): Promise<boolean> {
    const result = this.database
      .query(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE owner_id = ?1 AND id = ?2 AND revoked_at IS NULL`,
      )
      .run(ownerId, deviceId, revokedAt);

    return result.changes > 0;
  }

  async revokeDeviceIfInactive(
    tokenHash: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<boolean> {
    const result = this.database
      .query(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE token_hash = ?1 AND revoked_at IS NULL
           AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?2)`,
      )
      .run(tokenHash, inactiveBefore, revokedAt);

    return result.changes > 0;
  }

  async revokeInactiveDevicesForOwner(
    ownerId: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<number> {
    const result = this.database
      .query(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE owner_id = ?1 AND revoked_at IS NULL
           AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?2)`,
      )
      .run(ownerId, inactiveBefore, revokedAt);

    return result.changes;
  }

  async performMaintenance(input: RelayMaintenanceInput): Promise<void> {
    const revokeDevices = this.database.query(
      `UPDATE devices
       SET revoked_at = ?2
       WHERE revoked_at IS NULL
         AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?1)`,
    );
    const deleteOwners = this.database.query(
      `DELETE FROM owners
       WHERE julianday(created_at) <= julianday(?1)
         AND NOT EXISTS (
           SELECT 1 FROM devices
           WHERE devices.owner_id = owners.id
             AND julianday(COALESCE(devices.last_seen_at, devices.created_at)) > julianday(?1)
         )`,
    );
    const deletePairingSessions = this.database.query(
      "DELETE FROM pairing_sessions WHERE julianday(expires_at) <= julianday(?1)",
    );
    const transaction = this.database.transaction((value: RelayMaintenanceInput) => {
      revokeDevices.run(value.inactive_before, value.maintained_at);
      deleteOwners.run(value.inactive_before);
      deletePairingSessions.run(value.pairing_expired_before);
    });

    transaction(input);
  }

  async createPairingSession(input: CreatePairingSessionInput): Promise<void> {
    this.database
      .query(
        `INSERT INTO pairing_sessions
          (id, device_code_hash, user_code_hash, device_display_name, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
      )
      .run(
        input.id,
        input.device_code_hash,
        input.user_code_hash,
        input.device_display_name,
        input.expires_at,
        input.created_at,
      );
  }

  async decidePairingSession(input: DecidePairingSessionInput): Promise<PairingDecisionOutcome> {
    const updatePairing = this.database.query(
      input.decision === "approve"
        ? `UPDATE pairing_sessions
           SET owner_id = ?2, approved_at = ?3
           WHERE user_code_hash = ?1 AND owner_id IS NULL
             AND approved_at IS NULL AND denied_at IS NULL AND consumed_at IS NULL
             AND expires_at > ?3`
        : `UPDATE pairing_sessions
           SET owner_id = ?2, denied_at = ?3
           WHERE user_code_hash = ?1 AND owner_id IS NULL
             AND approved_at IS NULL AND denied_at IS NULL AND consumed_at IS NULL
             AND expires_at > ?3`,
    );
    const transaction = this.database.transaction((value: DecidePairingSessionInput) => {
      const existing = this.getPairingByUserCode(value.user_code_hash);
      const existingOutcome = pairingDecisionOutcome(existing, value.decided_at);
      if (existingOutcome) {
        return existingOutcome;
      }

      const result = updatePairing.run(value.user_code_hash, value.owner_id, value.decided_at);
      if (result.changes !== 1) {
        const current = this.getPairingByUserCode(value.user_code_hash);
        return pairingDecisionOutcome(current, value.decided_at) ?? "not_found";
      }
      return value.decision === "approve" ? "approved" : "denied";
    });

    return transaction(input);
  }

  async consumePairingSession(input: ConsumePairingSessionInput): Promise<PairingConsumeOutcome> {
    const insertDevice = this.database.query(
      `INSERT INTO devices
        (id, owner_id, display_name, token_hash, pairing_session_id, created_at)
       SELECT ?2, owner_id, device_display_name, ?3, id, ?4
       FROM pairing_sessions
       WHERE device_code_hash = ?1 AND owner_id IS NOT NULL
         AND approved_at IS NOT NULL AND denied_at IS NULL AND consumed_at IS NULL
         AND expires_at > ?4`,
    );
    const markConsumed = this.database.query(
      `UPDATE pairing_sessions
       SET consumed_at = ?2
       WHERE device_code_hash = ?1 AND consumed_at IS NULL
         AND EXISTS (
           SELECT 1 FROM devices
           WHERE devices.pairing_session_id = pairing_sessions.id
             AND devices.id = ?3 AND devices.token_hash = ?4
         )`,
    );
    const transaction = this.database.transaction((value: ConsumePairingSessionInput) => {
      const existing = this.getPairingByDeviceCode(value.device_code_hash);
      const unavailable = pairingUnavailableConsumeOutcome(existing, value.consumed_at);
      if (unavailable) {
        return unavailable;
      }

      const inserted = insertDevice.run(
        value.device_code_hash,
        value.device_id,
        value.token_hash,
        value.consumed_at,
      );
      const consumed = markConsumed.run(
        value.device_code_hash,
        value.consumed_at,
        value.device_id,
        value.token_hash,
      );
      if (inserted.changes !== 1 || consumed.changes !== 1) {
        throw new Error("Pairing session credential issuance was not atomic");
      }
      return "issued";
    });

    return transaction(input);
  }

  async consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult> {
    validateRateLimitInput(input);
    const deleteExpired = this.database.query(
      `DELETE FROM rate_limit_counters
       WHERE window_expires_at <= ?1`,
    );
    const increment = this.database.query<RateLimitRow, [string, string, string]>(
      `INSERT INTO rate_limit_counters
        (key_hash, window_started_at, window_expires_at, request_count)
       VALUES (?1, ?2, ?3, 1)
       ON CONFLICT(key_hash, window_started_at) DO UPDATE SET
         request_count = rate_limit_counters.request_count + 1
       WHERE rate_limit_counters.window_expires_at = excluded.window_expires_at
       RETURNING request_count, window_expires_at`,
    );
    const transaction = this.database.transaction((value: RateLimitInput) => {
      deleteExpired.run(value.checked_at);
      const row = increment.get(value.key_hash, value.window_started_at, value.window_expires_at);
      if (!row) {
        throw new Error("Rate-limit fixed window does not match persisted state");
      }
      return rateLimitResult(row, value);
    });

    return transaction(input);
  }

  async recordSnapshot(envelope: QuotaSnapshotEnvelope, receivedAt: string): Promise<void> {
    const getDevice = this.database.query<DeviceRecord, [string]>(
      `SELECT id, owner_id, display_name, created_at, last_seen_at,
              last_sequence, revoked_at
       FROM devices
       WHERE id = ?1`,
    );
    const upsertSnapshot = this.database.query(
      `INSERT INTO quota_snapshots
        (device_id, provider, account_fingerprint, sequence, captured_at,
         observed_at, snapshot_json, updated_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
       WHERE EXISTS (
         SELECT 1 FROM devices
         WHERE id = ?1 AND revoked_at IS NULL AND last_sequence < ?4
       )
       ON CONFLICT(device_id, provider, account_fingerprint) DO UPDATE SET
         sequence = excluded.sequence,
         captured_at = excluded.captured_at,
         observed_at = excluded.observed_at,
         snapshot_json = excluded.snapshot_json,
         updated_at = excluded.updated_at
       WHERE excluded.sequence > quota_snapshots.sequence`,
    );
    const updateDevice = this.database.query(
      `UPDATE devices
       SET last_seen_at = ?2, last_sequence = ?3
       WHERE id = ?1 AND revoked_at IS NULL AND last_sequence < ?3`,
    );
    const touchDevice = this.database.query(
      `UPDATE devices
       SET last_seen_at = ?2
       WHERE id = ?1 AND revoked_at IS NULL`,
    );
    const transaction = this.database.transaction(
      (value: { envelope: QuotaSnapshotEnvelope; receivedAt: string }) => {
        const report = value.envelope;
        const device = getDevice.get(report.device_id);
        if (!device || device.revoked_at) {
          throw new Error("Device is missing or revoked");
        }
        if (report.sequence <= device.last_sequence) {
          if (touchDevice.run(report.device_id, value.receivedAt).changes !== 1) {
            throw new Error("Device activity could not be recorded");
          }
          return;
        }

        for (const snapshot of report.snapshots) {
          upsertSnapshot.run(
            report.device_id,
            snapshot.provider,
            snapshot.account.fingerprint,
            report.sequence,
            report.captured_at,
            snapshot.observed_at,
            JSON.stringify(snapshot),
            value.receivedAt,
          );
        }
        const result = updateDevice.run(report.device_id, value.receivedAt, report.sequence);
        if (result.changes !== 1) {
          throw new Error("Device snapshot sequence was not accepted");
        }
      },
    );

    transaction({ envelope, receivedAt });
  }

  async listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]> {
    const rows = this.database
      .query<SnapshotRow, [string]>(
        `SELECT snapshots.device_id, snapshots.sequence, snapshots.captured_at,
                snapshots.snapshot_json, snapshots.updated_at
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.owner_id = ?1 AND devices.revoked_at IS NULL
         ORDER BY snapshots.updated_at DESC`,
      )
      .all(ownerId);

    return rows.map((row) => ({
      device_id: row.device_id,
      sequence: row.sequence,
      captured_at: row.captured_at,
      snapshot: QuotaSnapshotSchema.parse(JSON.parse(row.snapshot_json)),
      updated_at: row.updated_at,
    }));
  }

  private getPairingByUserCode(userCodeHash: string): PairingSessionRow | null {
    return this.database
      .query<PairingSessionRow, [string]>(
        `SELECT expires_at, approved_at, denied_at, consumed_at
         FROM pairing_sessions
         WHERE user_code_hash = ?1`,
      )
      .get(userCodeHash);
  }

  private getPairingByDeviceCode(deviceCodeHash: string): PairingSessionRow | null {
    return this.database
      .query<PairingSessionRow, [string]>(
        `SELECT expires_at, approved_at, denied_at, consumed_at
         FROM pairing_sessions
         WHERE device_code_hash = ?1`,
      )
      .get(deviceCodeHash);
  }
}
