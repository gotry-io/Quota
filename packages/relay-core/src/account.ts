import type { ProviderId, QuotaSnapshot, QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";

/**
 * Everything a session can be allowed to do.
 *
 * One vocabulary, because there is one session table. `device:write` is the whole write side of a
 * collection client — quota, Usage, and the device profile and sync control behind them — and it
 * is meaningful only on a session that names a Device. Ending a session is not a scope: holding
 * its refresh token is the proof, which is what `POST /oauth/v2/revoke` asks for.
 */
export const SESSION_SCOPES = ["account:read", "account:manage", "device:write"] as const;
export type SessionScope = (typeof SESSION_SCOPES)[number];

/** Which client holds a session. It decides the rules, not what the session is stored in. */
export type SessionClientKind = "web" | "quotabar" | "ios";

export interface AccountRecord {
  id: string;
  identity_subject: string;
  display_label: string | null;
  created_at: string;
  updated_at: string;
}

export interface DeviceRecord {
  id: string;
  account_id: string;
  display_name: string | null;
  platform: string | null;
  generation: number;
  usage_sync_revision: number;
  created_at: string;
  last_login_at: string;
  last_seen_at: string | null;
  signed_out_at: string | null;
  deleted_at: string | null;
  deleted_before: string | null;
}

/**
 * Whoever is making this request, as one session row states them.
 *
 * A browser cookie, QuotaBar's Bearer token, and the iOS viewer's Bearer token all resolve to
 * this. `device_id` and `device_generation` are set together or not at all: a session either
 * names the Device it speaks for, at the generation that Device had when the session opened, or
 * it names none.
 */
export interface SessionPrincipal {
  session_id: string;
  family_id: string;
  account_id: string;
  device_id: string | null;
  device_generation: number | null;
  client_kind: SessionClientKind;
  scopes: SessionScope[];
  authenticated_at: string;
}

/** A principal that carries `device:write` and the Device it carries it for. */
export interface DeviceWriterPrincipal extends SessionPrincipal {
  device_id: string;
  device_generation: number;
}

/**
 * One browser sign-in in flight, on its way to an authorization code.
 *
 * Authorization Code with PKCE over a loopback callback is the only grant Relay issues, so a
 * grant is one shape: the login token that identifies it while the browser is at GitHub, the
 * challenge the exchange must answer, and where the code goes.
 */
export interface CreateLoginGrantInput {
  id: string;
  client_id: string;
  login_token_hash: string;
  pkce_challenge: string;
  redirect_uri: string;
  client_state: string;
  expires_at: string;
  created_at: string;
}

export interface LoginGrantRecord {
  id: string;
  client_id: string;
  account_id: string | null;
  pkce_challenge: string | null;
  redirect_uri: string | null;
  client_state: string | null;
  expires_at: string;
  completed_at: string | null;
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

export interface ConsumeLoginGrantInput {
  grant_id: string;
  credential_hash: string;
  completion_nonce_hash: string;
  installation_id_hash: string;
  device_id: string;
  display_name: string;
  platform: string;
  family_id: string;
  session: SessionCredentialHashes;
  consumed_at: string;
}

export type LoginGrantConsumeResult =
  | {
      outcome: "issued";
      account_id: string;
      device: DeviceRecord;
    }
  | { outcome: "not_found" | "expired" | "consumed" | "not_completed" };

/**
 * One browser sign-in, as Relay stores it.
 *
 * The Account is found or created in the same batch: a first GitHub sign-in and a return visit
 * differ only in whether the row was already there.
 */
export interface CreateWebSessionInput {
  session_id: string;
  account_id: string;
  display_label: string;
  access_token_hash: string;
  authenticated_at: string;
  expires_at: string;
}

export interface ConsumeAccountLoginGrantInput {
  grant_id: string;
  credential_hash: string;
  completion_nonce_hash: string;
  family_id: string;
  session: SessionCredentialHashes;
  consumed_at: string;
}

export type AccountLoginGrantConsumeResult =
  | { outcome: "issued"; account_id: string }
  | { outcome: "not_found" | "expired" | "consumed" | "not_completed" };

export interface RefreshSessionInput {
  refresh_token_hash: string;
  new_access_token_hash: string;
  new_refresh_token_hash: string;
  access_expires_at: string;
  refresh_expires_at: string;
  refreshed_at: string;
}

export interface RevokeRefreshSessionInput {
  refresh_token_hash: string;
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

/**
 * Everything an Account read depends on, collapsed to numbers a reader can compare.
 *
 * Account reads are polled on a timer and are almost always unchanged, so they answer a
 * conditional request from this stamp instead of aggregating Usage again. Each field either
 * counts rows or takes the newest instant of a table the response reads, so any write that
 * could change a byte of the response moves at least one of them. `usage_revision` sums the
 * per-device counters rather than taking their maximum: each accepted upload increments one
 * device, and a maximum would not move when the device that uploaded is not the leader.
 * `active_devices` is here because the device status the response reports is derived from the
 * read instant, not from a stored column, so it changes with no write at all.
 */
export interface AccountVersionStamp {
  devices: number;
  active_devices: number;
  usage_revision: number;
  device_generation: number;
  device_last_seen_at: string | null;
  device_last_login_at: string | null;
  device_signed_out_at: string | null;
  snapshots: number;
  snapshot_updated_at: string | null;
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
  snapshot: QuotaSnapshot;
}

/**
 * What one snapshot upload did to the providers it named.
 *
 * A provider is accepted when at least one of its readings was newer than the one already stored.
 * Either way the envelope states the fingerprints this device now sees for that provider, so the
 * ones it no longer names are dropped.
 */
export type SnapshotWriteResult =
  | { outcome: "stale_device" }
  | { outcome: "written"; accepted: ProviderId[]; ignored: ProviderId[] };

export interface DeviceSyncControl {
  device_id: string;
  generation: number;
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
  consumeLoginGrant(input: ConsumeLoginGrantInput): Promise<LoginGrantConsumeResult>;
  consumeAccountLoginGrant(
    input: ConsumeAccountLoginGrantInput,
  ): Promise<AccountLoginGrantConsumeResult>;
  createWebSession(input: CreateWebSessionInput): Promise<AccountRecord>;
  /**
   * Resolve a Bearer token to its session.
   *
   * `marksDeviceSeen` is what a device route passes: a Device is "last seen" when it uses the
   * session that speaks for it. An Account read must not move that instant, because the
   * conditional answer to that read is derived from it — a read that changed its own validator
   * could never be answered 304.
   */
  authorizeSession(
    accessTokenHash: string,
    checkedAt: string,
    marksDeviceSeen: boolean,
  ): Promise<SessionPrincipal | null>;
  refreshSession(input: RefreshSessionInput): Promise<SessionPrincipal | null>;
  revokeRefreshSession(input: RevokeRefreshSessionInput): Promise<void>;
  revokePrincipalFamily(
    principal: SessionPrincipal,
    revokedAt: string,
    signOutDevice: boolean,
  ): Promise<void>;
  getAccount(accountId: string): Promise<AccountRecord | null>;
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
  accountVersionStamp(accountId: string, activeSince: string): Promise<AccountVersionStamp>;
  deleteDeviceData(
    accountId: string,
    deviceId: string,
    deletedAt: string,
  ): Promise<DeleteDeviceResult | null>;
  deleteAccountData(accountId: string): Promise<boolean>;
  recordSnapshot(
    principal: DeviceWriterPrincipal,
    envelope: QuotaSnapshotSubmission,
    receivedAt: string,
  ): Promise<SnapshotWriteResult>;
  listLatestSnapshots(accountId: string): Promise<StoredQuotaSnapshot[]>;
  consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult>;
}
