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

export const OWNER_AUTH_SCOPES = ["quota:read", "device:manage"] as const;

export type OwnerAuthScope = (typeof OWNER_AUTH_SCOPES)[number];

export interface AuthSessionRecord {
  owner_id: string;
  scopes: OwnerAuthScope[];
}

export interface ReplaceAuthSessionInput {
  id: string;
  owner_id: string;
  token_hash: string;
  scopes: OwnerAuthScope[];
  expires_at: string;
  created_at: string;
}

export interface CreatePairingSessionInput {
  id: string;
  device_code_hash: string;
  user_code_hash: string;
  device_display_name: string;
  expires_at: string;
  created_at: string;
}

export interface DecidePairingSessionInput {
  user_code_hash: string;
  owner_id: string;
  decision: "approve" | "deny";
  decided_at: string;
}

export type PairingDecisionOutcome =
  | "approved"
  | "denied"
  | "already_decided"
  | "expired"
  | "consumed"
  | "not_found";

export interface ConsumePairingSessionInput {
  device_code_hash: string;
  device_id: string;
  token_hash: string;
  consumed_at: string;
}

export type PairingConsumeOutcome =
  | "issued"
  | "pending"
  | "denied"
  | "expired"
  | "consumed"
  | "not_found";

export interface RateLimitInput {
  key_hash: string;
  window_started_at: string;
  window_expires_at: string;
  checked_at: string;
  limit: number;
}

export interface RateLimitResult {
  allowed: boolean;
  retry_after: number;
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
  replaceAuthSession(input: ReplaceAuthSessionInput): Promise<void>;
  getActiveAuthSessionByTokenHash(
    tokenHash: string,
    checkedAt: string,
  ): Promise<AuthSessionRecord | null>;
  registerDevice(input: RegisterDeviceInput): Promise<void>;
  getDevice(deviceId: string): Promise<DeviceRecord | null>;
  getActiveDeviceByTokenHash(tokenHash: string): Promise<DeviceRecord | null>;
  listDevices(ownerId: string): Promise<DeviceRecord[]>;
  revokeDevice(ownerId: string, deviceId: string, revokedAt: string): Promise<boolean>;
  createPairingSession(input: CreatePairingSessionInput): Promise<void>;
  decidePairingSession(input: DecidePairingSessionInput): Promise<PairingDecisionOutcome>;
  consumePairingSession(input: ConsumePairingSessionInput): Promise<PairingConsumeOutcome>;
  consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult>;
  recordSnapshot(envelope: QuotaSnapshotEnvelope): Promise<void>;
  listLatestSnapshots(ownerId: string): Promise<StoredQuotaSnapshot[]>;
}
