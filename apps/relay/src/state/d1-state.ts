import { type QuotaSnapshotEnvelope, QuotaSnapshotSchema } from "@gotry-io/quota-protocol";
import type {
  ConsumePairingSessionInput,
  OwnerSessionRecord,
  CreateOwnerInput,
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
  ReplaceOwnerSessionInput,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import {
  type OwnerSessionRow,
  decodeOwnerSession,
  encodeOwnerScopes,
  type PairingSessionRow,
  pairingDecisionOutcome,
  pairingUnavailableConsumeOutcome,
  type RateLimitRow,
  rateLimitResult,
  validateRateLimitInput,
} from "./records.ts";

interface SnapshotRow {
  device_id: string;
  sequence: number;
  captured_at: string;
  snapshot_json: string;
  updated_at: string;
}

export class D1RelayState implements RelayState {
  constructor(private readonly database: D1Database) {}

  async initialize(): Promise<void> {
    // D1 schema changes are applied explicitly through Wrangler migrations.
  }

  async ping(): Promise<void> {
    await this.database.prepare("SELECT 1 AS ready").first();
  }

  async createOwner(input: CreateOwnerInput): Promise<void> {
    await this.database.batch([
      this.database
        .prepare(
          `INSERT INTO owners (id, created_at)
           VALUES (?1, ?2)`,
        )
        .bind(input.id, input.created_at),
      this.database
        .prepare(
          `INSERT INTO owner_sessions
            (id, owner_id, token_hash, scopes_json, expires_at, created_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
        )
        .bind(
          input.session_id,
          input.id,
          input.token_hash,
          encodeOwnerScopes(input.scopes),
          input.expires_at,
          input.created_at,
        ),
    ]);
  }

  async deleteOwner(ownerId: string): Promise<boolean> {
    const result = await this.database
      .prepare("DELETE FROM owners WHERE id = ?1")
      .bind(ownerId)
      .run();
    return result.meta.changes > 0;
  }

  async ensureOwner(ownerId: string, createdAt: string): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO owners (id, created_at)
         VALUES (?1, ?2)
         ON CONFLICT(id) DO NOTHING`,
      )
      .bind(ownerId, createdAt)
      .run();
  }

  async replaceOwnerSession(input: ReplaceOwnerSessionInput): Promise<void> {
    const result = await this.database
      .prepare(
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
      .bind(
        input.id,
        input.owner_id,
        input.token_hash,
        encodeOwnerScopes(input.scopes),
        input.expires_at,
        input.created_at,
      )
      .run();
    if (result.meta.changes !== 1) {
      throw new Error("Owner session does not match the owner");
    }
  }

  async getActiveOwnerSessionByTokenHash(
    tokenHash: string,
    checkedAt: string,
  ): Promise<OwnerSessionRecord | null> {
    const row = await this.database
      .prepare(
        `SELECT owner_id, scopes_json
         FROM owner_sessions
         WHERE token_hash = ?1 AND revoked_at IS NULL AND expires_at > ?2`,
      )
      .bind(tokenHash, checkedAt)
      .first<OwnerSessionRow>();

    return row ? decodeOwnerSession(row) : null;
  }

  async registerDevice(input: RegisterDeviceInput): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO devices
          (id, owner_id, display_name, token_hash, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .bind(input.id, input.owner_id, input.display_name, input.token_hash, input.created_at)
      .run();
  }

  async getDevice(deviceId: string): Promise<DeviceRecord | null> {
    return this.database
      .prepare(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
         WHERE id = ?1`,
      )
      .bind(deviceId)
      .first<DeviceRecord>();
  }

  async getDeviceByTokenHash(tokenHash: string): Promise<DeviceRecord | null> {
    return this.database
      .prepare(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
         WHERE token_hash = ?1`,
      )
      .bind(tokenHash)
      .first<DeviceRecord>();
  }

  async listDevices(ownerId: string): Promise<DeviceRecord[]> {
    const result = await this.database
      .prepare(
        `SELECT id, owner_id, display_name, created_at, last_seen_at,
                last_sequence, revoked_at
         FROM devices
         WHERE owner_id = ?1
         ORDER BY created_at ASC`,
      )
      .bind(ownerId)
      .all<DeviceRecord>();

    return result.results;
  }

  async revokeDevice(ownerId: string, deviceId: string, revokedAt: string): Promise<boolean> {
    const result = await this.database
      .prepare(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE owner_id = ?1 AND id = ?2 AND revoked_at IS NULL`,
      )
      .bind(ownerId, deviceId, revokedAt)
      .run();

    return result.meta.changes > 0;
  }

  async revokeDeviceIfInactive(
    tokenHash: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<boolean> {
    const result = await this.database
      .prepare(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE token_hash = ?1 AND revoked_at IS NULL
           AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?2)`,
      )
      .bind(tokenHash, inactiveBefore, revokedAt)
      .run();

    return result.meta.changes > 0;
  }

  async revokeInactiveDevicesForOwner(
    ownerId: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<number> {
    const result = await this.database
      .prepare(
        `UPDATE devices
         SET revoked_at = ?3
         WHERE owner_id = ?1 AND revoked_at IS NULL
           AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?2)`,
      )
      .bind(ownerId, inactiveBefore, revokedAt)
      .run();

    return result.meta.changes;
  }

  async performMaintenance(input: RelayMaintenanceInput): Promise<void> {
    await this.database.batch([
      this.database
        .prepare(
          `UPDATE devices
           SET revoked_at = ?2
           WHERE revoked_at IS NULL
             AND julianday(COALESCE(last_seen_at, created_at)) <= julianday(?1)`,
        )
        .bind(input.inactive_before, input.maintained_at),
      this.database
        .prepare(
          `DELETE FROM owners
           WHERE julianday(created_at) <= julianday(?1)
             AND NOT EXISTS (
               SELECT 1 FROM devices
               WHERE devices.owner_id = owners.id
                 AND julianday(COALESCE(devices.last_seen_at, devices.created_at)) > julianday(?1)
             )`,
        )
        .bind(input.inactive_before),
      this.database
        .prepare("DELETE FROM pairing_sessions WHERE julianday(expires_at) <= julianday(?1)")
        .bind(input.pairing_expired_before),
    ]);
  }

  async createPairingSession(input: CreatePairingSessionInput): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO pairing_sessions
          (id, device_code_hash, user_code_hash, device_display_name, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
      )
      .bind(
        input.id,
        input.device_code_hash,
        input.user_code_hash,
        input.device_display_name,
        input.expires_at,
        input.created_at,
      )
      .run();
  }

  async decidePairingSession(input: DecidePairingSessionInput): Promise<PairingDecisionOutcome> {
    const existing = await this.getPairingByUserCode(input.user_code_hash);
    const existingOutcome = pairingDecisionOutcome(existing, input.decided_at);
    if (existingOutcome) {
      return existingOutcome;
    }

    const result = await this.database
      .prepare(
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
      )
      .bind(input.user_code_hash, input.owner_id, input.decided_at)
      .run();

    if (result.meta.changes === 1) {
      return input.decision === "approve" ? "approved" : "denied";
    }
    const current = await this.getPairingByUserCode(input.user_code_hash);
    return pairingDecisionOutcome(current, input.decided_at) ?? "not_found";
  }

  async consumePairingSession(input: ConsumePairingSessionInput): Promise<PairingConsumeOutcome> {
    const existing = await this.getPairingByDeviceCode(input.device_code_hash);
    const unavailable = pairingUnavailableConsumeOutcome(existing, input.consumed_at);
    if (unavailable) {
      return unavailable;
    }

    try {
      const results = await this.database.batch([
        this.database
          .prepare(
            `INSERT INTO devices
              (id, owner_id, display_name, token_hash, pairing_session_id, created_at)
             SELECT ?2, owner_id, device_display_name, ?3, id, ?4
             FROM pairing_sessions
             WHERE device_code_hash = ?1 AND owner_id IS NOT NULL
               AND approved_at IS NOT NULL AND denied_at IS NULL AND consumed_at IS NULL
               AND expires_at > ?4`,
          )
          .bind(input.device_code_hash, input.device_id, input.token_hash, input.consumed_at),
        this.database
          .prepare(
            `UPDATE pairing_sessions
             SET consumed_at = ?2
             WHERE device_code_hash = ?1 AND consumed_at IS NULL
               AND EXISTS (
                 SELECT 1 FROM devices
                 WHERE devices.pairing_session_id = pairing_sessions.id
                   AND devices.id = ?3 AND devices.token_hash = ?4
               )`,
          )
          .bind(input.device_code_hash, input.consumed_at, input.device_id, input.token_hash),
      ]);

      if (results[0]?.meta.changes === 1 && results[1]?.meta.changes === 1) {
        return "issued";
      }
    } catch (error) {
      const current = await this.getPairingByDeviceCode(input.device_code_hash);
      const currentOutcome = pairingUnavailableConsumeOutcome(current, input.consumed_at);
      if (currentOutcome) {
        return currentOutcome;
      }
      throw error;
    }

    const current = await this.getPairingByDeviceCode(input.device_code_hash);
    const currentOutcome = pairingUnavailableConsumeOutcome(current, input.consumed_at);
    if (currentOutcome) {
      return currentOutcome;
    }
    throw new Error("Pairing session credential issuance was not atomic");
  }

  async consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult> {
    validateRateLimitInput(input);
    const results = await this.database.batch<RateLimitRow>([
      this.database
        .prepare(
          `DELETE FROM rate_limit_counters
           WHERE window_expires_at <= ?1`,
        )
        .bind(input.checked_at),
      this.database
        .prepare(
          `INSERT INTO rate_limit_counters
            (key_hash, window_started_at, window_expires_at, request_count)
           VALUES (?1, ?2, ?3, 1)
           ON CONFLICT(key_hash, window_started_at) DO UPDATE SET
             request_count = rate_limit_counters.request_count + 1
           WHERE rate_limit_counters.window_expires_at = excluded.window_expires_at
           RETURNING request_count, window_expires_at`,
        )
        .bind(input.key_hash, input.window_started_at, input.window_expires_at),
    ]);
    const row = results[1]?.results[0];
    if (!row) {
      throw new Error("Rate-limit fixed window does not match persisted state");
    }
    return rateLimitResult(row, input);
  }

  async recordSnapshot(envelope: QuotaSnapshotEnvelope, receivedAt: string): Promise<void> {
    const statements = [
      ...envelope.snapshots.map((snapshot) =>
        this.database
          .prepare(
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
          )
          .bind(
            envelope.device_id,
            snapshot.provider,
            snapshot.account.fingerprint,
            envelope.sequence,
            envelope.captured_at,
            snapshot.observed_at,
            JSON.stringify(snapshot),
            receivedAt,
          ),
      ),
      this.database
        .prepare(
          `UPDATE devices
           SET last_seen_at = ?2, last_sequence = ?3
           WHERE id = ?1 AND revoked_at IS NULL AND last_sequence < ?3`,
        )
        .bind(envelope.device_id, receivedAt, envelope.sequence),
    ];

    const results = await this.database.batch(statements);
    const updateResult = results.at(-1);
    if (updateResult?.meta.changes === 1) {
      return;
    }

    const device = await this.getDevice(envelope.device_id);
    if (!device || device.revoked_at) {
      throw new Error("Device is missing or revoked");
    }
    const touched = await this.database
      .prepare(
        `UPDATE devices
         SET last_seen_at = ?2
         WHERE id = ?1 AND revoked_at IS NULL`,
      )
      .bind(envelope.device_id, receivedAt)
      .run();
    if (touched.meta.changes !== 1) {
      throw new Error("Device activity could not be recorded");
    }
  }

  async listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]> {
    const result = await this.database
      .prepare(
        `SELECT snapshots.device_id, snapshots.sequence, snapshots.captured_at,
                snapshots.snapshot_json, snapshots.updated_at
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.owner_id = ?1 AND devices.revoked_at IS NULL
         ORDER BY snapshots.updated_at DESC`,
      )
      .bind(ownerId)
      .all<SnapshotRow>();

    return result.results.map((row) => ({
      device_id: row.device_id,
      sequence: row.sequence,
      captured_at: row.captured_at,
      snapshot: QuotaSnapshotSchema.parse(JSON.parse(row.snapshot_json)),
      updated_at: row.updated_at,
    }));
  }

  private async getPairingByUserCode(userCodeHash: string): Promise<PairingSessionRow | null> {
    return this.database
      .prepare(
        `SELECT expires_at, approved_at, denied_at, consumed_at
         FROM pairing_sessions
         WHERE user_code_hash = ?1`,
      )
      .bind(userCodeHash)
      .first<PairingSessionRow>();
  }

  private async getPairingByDeviceCode(deviceCodeHash: string): Promise<PairingSessionRow | null> {
    return this.database
      .prepare(
        `SELECT expires_at, approved_at, denied_at, consumed_at
         FROM pairing_sessions
         WHERE device_code_hash = ?1`,
      )
      .bind(deviceCodeHash)
      .first<PairingSessionRow>();
  }
}
