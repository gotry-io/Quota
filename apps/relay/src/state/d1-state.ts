import { QuotaSnapshotSchema, type QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";
import type {
  DeviceRecord,
  RegisterDeviceInput,
  RelayState,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";

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

  async ensureOwner(ownerId: string, createdAt: string): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO users (id, created_at)
         VALUES (?1, ?2)
         ON CONFLICT(id) DO NOTHING`,
      )
      .bind(ownerId, createdAt)
      .run();
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

  async recordSnapshot(envelope: QuotaSnapshotEnvelope): Promise<void> {
    const updatedAt = new Date().toISOString();
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
            updatedAt,
          ),
      ),
      this.database
        .prepare(
          `UPDATE devices
           SET last_seen_at = ?2, last_sequence = ?3
           WHERE id = ?1 AND revoked_at IS NULL AND last_sequence < ?3`,
        )
        .bind(envelope.device_id, updatedAt, envelope.sequence),
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
  }

  async listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]> {
    const result = await this.database
      .prepare(
        `SELECT snapshots.device_id, snapshots.sequence, snapshots.captured_at,
                snapshots.snapshot_json, snapshots.updated_at
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.owner_id = ?1
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
}
