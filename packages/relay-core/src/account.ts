import type {
  AccountDeviceHealth,
  DeviceHealthUploadRequest,
  QuotaSnapshot,
  QuotaSnapshotEnvelope,
} from "@gotry-io/quota-protocol";

export const ACCOUNT_SCOPES = ["account:read", "account:manage", "session:revoke:self"] as const;
export type AccountScope = (typeof ACCOUNT_SCOPES)[number];

export const DEVICE_SCOPES = [
  "quota:write:self",
  "usage:write:self",
  "sync:read:self",
  "session:revoke:self",
] as const;
export type DeviceScope = (typeof DEVICE_SCOPES)[number];
export type AccountClientKind = "web" | "cli" | "ios";
export type LoginGrantKind = "browser_pkce" | "device_code";

export interface AccountRecord {
  id: string;
  identity_subject: string;
  display_label: string | null;
  created_at: string;
  updated_at: string;
  public_profile_enabled?: number | null;
  public_profile_slug?: string | null;
}

export interface DeviceRecord {
  id: string;
  account_id: string;
  display_name: string | null;
  platform: string | null;
  generation: number;
  last_sequence: number;
  last_usage_sequence: number;
  usage_sync_revision: number;
  created_at: string;
  last_login_at: string;
  last_seen_at: string | null;
  signed_out_at: string | null;
  deleted_at: string | null;
  deleted_before: string | null;
}

export interface StoredDeviceHealth extends AccountDeviceHealth {
  device_id: string;
  device_generation: number;
}

export type DeviceHealthWriteOutcome = "updated" | "ignored_stale" | "unauthorized";

export interface AccountPrincipal {
  kind: "account";
  session_id: string;
  family_id: string;
  account_id: string;
  device_id: string | null;
  client_kind: AccountClientKind;
  scopes: AccountScope[];
  authenticated_at: string;
}

export interface DevicePrincipal {
  kind: "device";
  session_id: string;
  family_id: string;
  account_id: string;
  device_id: string;
  generation: number;
  scopes: DeviceScope[];
}

export interface CreateLoginGrantInput {
  id: string;
  grant_kind: LoginGrantKind;
  client_id: string;
  login_token_hash: string | null;
  device_code_hash: string | null;
  user_code_hash: string | null;
  installation_id_hash: string | null;
  device_display_name: string | null;
  platform: string | null;
  pkce_challenge: string | null;
  redirect_uri: string | null;
  client_state: string | null;
  poll_interval_seconds: number | null;
  expires_at: string;
  created_at: string;
}

export interface LoginGrantRecord {
  id: string;
  grant_kind: LoginGrantKind;
  client_id: string;
  account_id: string | null;
  installation_id_hash: string | null;
  device_display_name: string | null;
  platform: string | null;
  pkce_challenge: string | null;
  redirect_uri: string | null;
  client_state: string | null;
  expires_at: string;
  approved_at: string | null;
  denied_at: string | null;
  consumed_at: string | null;
}

export interface SessionCredentialHashes {
  session_id: string;
  access_token_hash: string;
  refresh_token_hash: string;
  access_expires_at: string;
  refresh_expires_at: string;
}

export interface CompleteIdentityLoginInput {
  grant_id: string;
  login_token_hash: string;
  completion_nonce_hash: string;
  display_label: string | null;
  account_id: string;
  completed_at: string;
  authorization_code_hash: string | null;
}

export interface CompleteIdentityLoginResult {
  outcome: "completed" | "not_found" | "expired" | "already_completed";
  grant: LoginGrantRecord | null;
  account: AccountRecord | null;
}

export interface AuthorizeDeviceGrantInput {
  user_code_hash: string;
  account_id: string;
  decision: "approve" | "deny";
  decided_at: string;
}

export type DeviceGrantDecisionOutcome =
  | "approved"
  | "denied"
  | "not_found"
  | "expired"
  | "already_decided"
  | "consumed";

export type DeviceGrantPollResult =
  | { outcome: "ready"; grant: LoginGrantRecord; poll_interval_seconds: number }
  | {
      outcome: "pending" | "slow_down" | "denied" | "expired" | "consumed" | "not_found";
      poll_interval_seconds: number;
    };

export interface ConsumeLoginGrantInput {
  grant_id: string;
  credential_hash: string;
  completion_nonce_hash: string;
  installation_id_hash: string;
  device_id: string;
  display_name: string;
  platform: string;
  family_id: string;
  account_session: SessionCredentialHashes;
  device_session: SessionCredentialHashes;
  consumed_at: string;
}

export type LoginGrantConsumeResult =
  | {
      outcome: "issued";
      account_id: string;
      device: DeviceRecord;
    }
  | { outcome: "not_found" | "expired" | "consumed" | "not_approved" };

export interface ConsumeAccountLoginGrantInput {
  grant_id: string;
  credential_hash: string;
  completion_nonce_hash: string;
  family_id: string;
  account_session: SessionCredentialHashes;
  consumed_at: string;
}

export type AccountLoginGrantConsumeResult =
  | { outcome: "issued"; account_id: string }
  | { outcome: "not_found" | "expired" | "consumed" | "not_approved" };

export interface RefreshSessionInput {
  refresh_token_hash: string;
  new_access_token_hash: string;
  new_refresh_token_hash: string;
  access_expires_at: string;
  refresh_expires_at: string;
  refreshed_at: string;
}

export type SessionTokenAudience = "account" | "device";

export interface RevokeRefreshSessionInput {
  refresh_token_hash: string;
  token_audience: SessionTokenAudience;
  revoked_at: string;
}

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

export interface AccountMaintenanceInput {
  grant_expired_before: string;
  session_expired_before: string;
  session_revoked_before: string;
  /**
   * Observations this old are deleted. A device that stops reporting a provider leaves its
   * last reading behind, and nothing in an upload says that reading was the last one, so
   * retention is what bounds it. Readers stop presenting a reading as current long before
   * this; this is when Relay stops keeping it at all.
   */
  snapshot_observed_before: string;
  limit: number;
}

export type QuotaSnapshotSubmission = QuotaSnapshotEnvelope;

export interface StoredQuotaSnapshot {
  device_id: string;
  sequence: number;
  captured_at: string;
  snapshot: QuotaSnapshot;
  updated_at: string;
}

export type SnapshotWriteOutcome = "accepted" | "duplicate" | "sequence_conflict" | "stale_device";

export interface DeviceSyncControl {
  device_id: string;
  generation: number;
  next_snapshot_sequence: number;
  next_usage_sequence: number;
  usage_deleted_before: string | null;
  usage_sync_revision: number;
}

export interface DeleteDeviceResult {
  device_id: string;
  generation: number;
  deleted_before: string;
}

export interface AccountState {
  ping(): Promise<void>;
  performMaintenance(input: AccountMaintenanceInput): Promise<void>;
  createLoginGrant(input: CreateLoginGrantInput): Promise<void>;
  getLoginGrantByLoginTokenHash(hash: string, checkedAt: string): Promise<LoginGrantRecord | null>;
  completeIdentityLogin(input: CompleteIdentityLoginInput): Promise<CompleteIdentityLoginResult>;
  getLoginGrantByAuthorizationCodeHash(
    hash: string,
    checkedAt: string,
  ): Promise<LoginGrantRecord | null>;
  authorizeDeviceGrant(input: AuthorizeDeviceGrantInput): Promise<DeviceGrantDecisionOutcome>;
  pollDeviceGrant(hash: string, checkedAt: string): Promise<DeviceGrantPollResult>;
  consumeLoginGrant(input: ConsumeLoginGrantInput): Promise<LoginGrantConsumeResult>;
  consumeAccountLoginGrant(
    input: ConsumeAccountLoginGrantInput,
  ): Promise<AccountLoginGrantConsumeResult>;
  authorizeAccountSession(
    accessTokenHash: string,
    checkedAt: string,
  ): Promise<AccountPrincipal | null>;
  authorizeDeviceSession(
    accessTokenHash: string,
    checkedAt: string,
  ): Promise<DevicePrincipal | null>;
  refreshAccountSession(input: RefreshSessionInput): Promise<AccountPrincipal | null>;
  refreshAccountOnlySession(input: RefreshSessionInput): Promise<AccountPrincipal | null>;
  refreshDeviceSession(input: RefreshSessionInput): Promise<DevicePrincipal | null>;
  revokeRefreshSession(input: RevokeRefreshSessionInput): Promise<void>;
  revokePrincipalFamily(
    principal: AccountPrincipal | DevicePrincipal,
    revokedAt: string,
    signOutDevice: boolean,
  ): Promise<void>;
  getAccount(accountId: string): Promise<AccountRecord | null>;
  getAccountByPublicSlug(slug: string): Promise<AccountRecord | null>;
  setPublicProfile(
    accountId: string,
    enabled: boolean,
    slug: string | null,
    updatedAt: string,
  ): Promise<"ok" | "conflict">;
  listAccountDevices(accountId: string): Promise<DeviceRecord[]>;
  accountOwnsVisibleDevice(accountId: string, deviceId: string): Promise<boolean>;
  getDeviceSyncControl(deviceId: string, generation: number): Promise<DeviceSyncControl | null>;
  updateDeviceProfile(
    deviceId: string,
    generation: number,
    displayName: string,
    platform: string,
    updatedAt: string,
  ): Promise<boolean>;
  recordDeviceHealth(
    principal: DevicePrincipal,
    health: DeviceHealthUploadRequest,
    receivedAt: string,
    freshUntil: string,
  ): Promise<DeviceHealthWriteOutcome>;
  listDeviceHealth(accountId: string): Promise<StoredDeviceHealth[]>;
  deleteDeviceData(
    accountId: string,
    deviceId: string,
    deletedAt: string,
  ): Promise<DeleteDeviceResult | null>;
  recordSnapshot(
    principal: DevicePrincipal,
    envelope: QuotaSnapshotSubmission,
    receivedAt: string,
  ): Promise<SnapshotWriteOutcome>;
  listLatestSnapshots(accountId: string): Promise<StoredQuotaSnapshot[]>;
  consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult>;
}
