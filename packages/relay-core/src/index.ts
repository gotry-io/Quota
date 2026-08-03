import type { QuotaSnapshot, QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";

export interface DeviceRecord {
  id: string;
  controller_id: string;
  display_name: string;
  created_at: string;
  last_seen_at: string | null;
  last_sequence: number;
  revoked_at: string | null;
}

export interface RegisterDeviceInput {
  id: string;
  controller_id: string;
  display_name: string;
  token_hash: string;
  created_at: string;
}

export const CONTROLLER_AUTH_SCOPES = ["quota:read", "device:manage"] as const;

export type ControllerAuthScope = (typeof CONTROLLER_AUTH_SCOPES)[number];

export interface ControllerSessionRecord {
  controller_id: string;
  scopes: ControllerAuthScope[];
}

export interface ReplaceControllerSessionInput {
  id: string;
  controller_id: string;
  token_hash: string;
  scopes: ControllerAuthScope[];
  expires_at: string;
  created_at: string;
}

export interface CreateControllerInput {
  id: string;
  kind: ControllerKind;
  session_id: string;
  token_hash: string;
  scopes: ControllerAuthScope[];
  expires_at: string;
  created_at: string;
}

export type ControllerKind = "managed" | "permanent";

export interface RelayMaintenanceInput {
  inactive_before: string;
  pairing_expired_before: string;
  maintained_at: string;
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
  controller_id: string;
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
  createController(input: CreateControllerInput): Promise<void>;
  deleteController(controllerId: string): Promise<boolean>;
  ensureController(controllerId: string, kind: ControllerKind, createdAt: string): Promise<void>;
  replaceControllerSession(input: ReplaceControllerSessionInput): Promise<void>;
  getActiveControllerSessionByTokenHash(
    tokenHash: string,
    checkedAt: string,
  ): Promise<ControllerSessionRecord | null>;
  registerDevice(input: RegisterDeviceInput): Promise<void>;
  getDevice(deviceId: string): Promise<DeviceRecord | null>;
  getDeviceByTokenHash(tokenHash: string): Promise<DeviceRecord | null>;
  listDevices(controllerId: string): Promise<DeviceRecord[]>;
  revokeDevice(controllerId: string, deviceId: string, revokedAt: string): Promise<boolean>;
  revokeDeviceIfInactive(
    tokenHash: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<boolean>;
  revokeInactiveDevicesForController(
    controllerId: string,
    inactiveBefore: string,
    revokedAt: string,
  ): Promise<number>;
  performMaintenance(input: RelayMaintenanceInput): Promise<void>;
  createPairingSession(input: CreatePairingSessionInput): Promise<void>;
  decidePairingSession(input: DecidePairingSessionInput): Promise<PairingDecisionOutcome>;
  consumePairingSession(input: ConsumePairingSessionInput): Promise<PairingConsumeOutcome>;
  consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult>;
  recordSnapshot(envelope: QuotaSnapshotEnvelope, receivedAt: string): Promise<void>;
  listLatestSnapshots(controllerId: string): Promise<StoredQuotaSnapshot[]>;
}
