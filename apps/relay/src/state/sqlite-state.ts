import { Database } from "bun:sqlite";
import { QuotaSnapshotSchema, type QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";
import type {
  DeviceRecord,
  RegisterDeviceInput,
  RelayState,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import { SQLITE_SCHEMA } from "./schema.ts";

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
    this.database.exec(SQLITE_SCHEMA);
  }

  async ping(): Promise<void> {
    this.database.query("SELECT 1 AS ready").get();
  }

  async ensureOwner(ownerId: string, createdAt: string): Promise<void> {
    this.database
      .query(
        `INSERT INTO users (id, created_at)
         VALUES (?1, ?2)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(ownerId, createdAt);
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

  async recordSnapshot(envelope: QuotaSnapshotEnvelope): Promise<void> {
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
    const transaction = this.database.transaction((value: QuotaSnapshotEnvelope) => {
      const device = getDevice.get(value.device_id);
      if (!device || device.revoked_at) {
        throw new Error("Device is missing or revoked");
      }
      if (value.sequence <= device.last_sequence) {
        return;
      }

      const updatedAt = new Date().toISOString();
      for (const snapshot of value.snapshots) {
        upsertSnapshot.run(
          value.device_id,
          snapshot.provider,
          snapshot.account.fingerprint,
          value.sequence,
          value.captured_at,
          snapshot.observed_at,
          JSON.stringify(snapshot),
          updatedAt,
        );
      }
      const result = updateDevice.run(value.device_id, updatedAt, value.sequence);
      if (result.changes !== 1) {
        throw new Error("Device snapshot sequence was not accepted");
      }
    });

    transaction(envelope);
  }

  async listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]> {
    const rows = this.database
      .query<SnapshotRow, [string]>(
        `SELECT snapshots.device_id, snapshots.sequence, snapshots.captured_at,
                snapshots.snapshot_json, snapshots.updated_at
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.owner_id = ?1
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
}
