import type { QuotaSnapshot, QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";

export interface DeviceRecord {
  id: string;
  owner_id: string;
  display_name: string;
  created_at: string;
  last_seen_at: string | null;
  last_sequence: number;
  revoked_at: string | null;
}

export interface RegisterDeviceInput {
  id: string;
  owner_id: string;
  display_name: string;
  token_hash: string;
  created_at: string;
}

export interface StoredQuotaSnapshot {
  device_id: string;
  sequence: number;
  captured_at: string;
  snapshot: QuotaSnapshot;
  updated_at: string;
}

export interface RelayState {
  initialize(): Promise<void>;
  ping(): Promise<void>;
  ensureOwner(ownerId: string, createdAt: string): Promise<void>;
  registerDevice(input: RegisterDeviceInput): Promise<void>;
  getDevice(deviceId: string): Promise<DeviceRecord | null>;
  listDevices(ownerId: string): Promise<DeviceRecord[]>;
  revokeDevice(ownerId: string, deviceId: string, revokedAt: string): Promise<boolean>;
  recordSnapshot(envelope: QuotaSnapshotEnvelope): Promise<void>;
  listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]>;
}
