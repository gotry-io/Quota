import type {
  IdentityProvider,
  ProviderId,
  QuotaSnapshot,
  QuotaSnapshotEnvelope,
  RedemptionGrantDuration,
} from "@gotry-io/quota-protocol";

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
  /**
   * What this Account is called: the label of the identity it was opened with, kept current by
   * whichever identity was bound first ([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)).
   */
  display_label: string | null;
  created_at: string;
  updated_at: string;
}

/**
 * Every channel that can prove an identity, named the way the wire names it.
 *
 * The vocabulary is `packages/protocol`'s: what is stored and what is answered are the same set,
 * so a provider cannot exist in one and not the other.
 */
export type IdentityProviderId = IdentityProvider;

/**
 * One channel through which an Account can be reached.
 *
 * `subject` is the HMAC of what the provider proved — a GitHub numeric id, an Apple `sub`, a
 * normalized address — under `IDENTITY_SUBJECT_KEY`, so nothing here names a person. `label` is
 * what that channel calls them, and the earliest-bound identity's label is the Account's own.
 */
export interface AccountIdentityRecord {
  account_id: string;
  provider: IdentityProviderId;
  label: string | null;
  created_at: string;
}

/** A sign-in that has proved an identity, on its way to the Account behind it. */
export interface ResolveSignInIdentityInput {
  provider: IdentityProviderId;
  subject: string;
  label: string;
  /**
   * Whether `label` is the provider's stand-in rather than something it stated.
   *
   * Apple hands over an address only while the person is sharing one, so a later sign-in can
   * arrive with nothing but "Apple ID". A stand-in must not overwrite a name a channel once
   * really stated ([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)).
   */
  label_is_placeholder: boolean;
  /** The id the Account takes when this identity has never been seen before. */
  new_account_id: string;
  now: string;
}

export interface LinkIdentityInput {
  account_id: string;
  provider: IdentityProviderId;
  subject: string;
  label: string;
  now: string;
}

/**
 * What binding an identity to an Account did.
 *
 * `identity_taken` is a refusal, not a merge: the identity already belongs to another Account and
 * nothing is changed. `already_linked` is the same identity on the same Account, which is what a
 * repeated link is and is answered as success.
 */
export type LinkIdentityOutcome = "linked" | "already_linked" | "identity_taken";

/** Unbinding refuses to leave an Account no one can reach. */
export type UnlinkIdentityOutcome = "unlinked" | "not_found" | "last_identity";

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
 * grant is one shape: the login token that identifies it while the browser is signing in, the
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
  account_id: string;
  completed_at: string;
  authorization_code_hash: string | null;
}

export interface CompleteIdentityLoginResult {
  outcome: "completed" | "not_found" | "expired" | "already_completed";
  grant: LoginGrantRecord | null;
}

export interface ConsumeLoginGrantInput {
  grant_id: string;
  /** The public client whose grant this is. A grant is consumed by the client that opened it. */
  client_id: string;
  client_kind: SessionClientKind;
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
      display_label: string | null;
      device: DeviceRecord;
    }
  | { outcome: "not_found" | "expired" | "consumed" | "not_completed" };

/**
 * One browser sign-in, as Relay stores it.
 *
 * The Account is already resolved when this is written: the identity the sign-in proved decided
 * which Account it belongs to, or opened one.
 */
export interface CreateWebSessionInput {
  session_id: string;
  account_id: string;
  access_token_hash: string;
  authenticated_at: string;
  expires_at: string;
}

/**
 * The installation a phone presents when its session is to name a Device.
 *
 * The Device is found or created by installation exactly as a Mac's is, so a phone that signs in
 * twice is one Device with one live session rather than two
 * ([ADR 0041](../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
 */
export interface DeviceRegistrationInput {
  installation_id_hash: string;
  device_id: string;
  display_name: string;
  platform: string;
}

/**
 * The iOS app's one session, opened for an Account a native sign-in has already proved.
 *
 * Sign in with Apple proves who this is inside the app, so there is no browser round trip and no
 * grant to consume; what is written is the same `sessions` row `/oauth/v2/token` writes, with the
 * same scopes and the same credential domains ([ADR 0027](../../docs/decisions/0027-one-token-per-client.md)).
 * `device` is what the phone presented, and decides whether the row names a Device.
 */
export interface CreateIosSessionInput {
  account_id: string;
  family_id: string;
  session: SessionCredentialHashes;
  authenticated_at: string;
  device: DeviceRegistrationInput | null;
}

/** What opening a session answered: the Device it named, when one was presented. */
export interface CreateIosSessionResult {
  device: DeviceRecord | null;
}

/**
 * One mailed sign-in in flight.
 *
 * The address and the token are stored only as hashes. `intent_json` is the sealed decision
 * this challenge will complete — a sign-in, or a link on a named Account — and `return_to` is
 * the same-origin path the browser that opens the link is sent to.
 */
export interface CreateEmailChallengeInput {
  id: string;
  email_hash: string;
  token_hash: string;
  intent_json: string;
  return_to: string;
  created_at: string;
  expires_at: string;
}

export interface EmailChallengeRecord {
  id: string;
  email_hash: string;
  intent_json: string;
  return_to: string;
  created_at: string;
  expires_at: string;
  consumed_at: string | null;
}

export type ConsumeEmailChallengeResult =
  | { outcome: "consumed"; challenge: EmailChallengeRecord }
  | { outcome: "expired" }
  | { outcome: "invalid" };

export interface ConsumeAccountLoginGrantInput {
  grant_id: string;
  credential_hash: string;
  completion_nonce_hash: string;
  family_id: string;
  session: SessionCredentialHashes;
  consumed_at: string;
}

export type AccountLoginGrantConsumeResult =
  | { outcome: "issued"; account_id: string; display_label: string | null }
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
  /** When the Account row last changed. The response carries its display label. */
  account_updated_at: string | null;
  devices: number;
  active_devices: number;
  usage_revision: number;
  device_generation: number;
  device_last_seen_at: string | null;
  device_last_login_at: string | null;
  device_signed_out_at: string | null;
  snapshots: number;
  snapshot_updated_at: string | null;
  /** When the Quota Pro entitlement row last changed, or null when none is stored. */
  entitlement_updated_at: string | null;
}

export type EntitlementStatus = "active" | "grace" | "expired" | "none";
export type EntitlementSource = "webhook" | "rest";

export interface StoredEntitlement {
  account_id: string;
  status: EntitlementStatus;
  product_id: string | null;
  store: string | null;
  expires_at: string | null;
  will_renew: boolean;
  source: EntitlementSource;
  last_event_id: string | null;
  updated_at: string;
}

export interface ApplyRevenueCatWebhookInput {
  event_id: string;
  account_id: string;
  type: string;
  received_at: string;
  payload_json: string;
  /** Folded entitlement for this account, or null when the account is unknown. */
  entitlement: StoredEntitlement | null;
  /** Accounts that lost the subscription in a TRANSFER. */
  transfer_sources: StoredEntitlement[];
}

export interface RedemptionCodeRow {
  code: string;
  campaign: string;
  grant_duration: RedemptionGrantDuration;
  max_redemptions: number;
  redeemed_count: number;
  expires_at: string | null;
  note: string | null;
  created_at: string;
}

/**
 * The aggregates an activity read's ETag depends on.
 *
 * Activity answers daily Usage totals, not devices or observations, so a quota snapshot must
 * not move this stamp. Device count, summed usage revision, and generation still catch
 * deletion and a Usage upload; the Account's `updated_at` is here because a later sign-in can
 * rewrite the row without touching Usage.
 */
export interface AccountUsageVersionStamp {
  account_updated_at: string | null;
  devices: number;
  usage_revision: number;
  device_generation: number;
}

/**
 * The aggregates the leaderboard's answer depends on, over every listed profile at once.
 *
 * The board is not one Account's read, so its stamp is not one Account's either: it is the
 * shape of the listed set plus everything those Accounts have uploaded.
 */
export interface LeaderboardVersionStamp {
  profiles: number;
  profile_updated_at: string | null;
  usage_revision: number;
}

/** One place on the board, as the store folds it. */
export interface LeaderboardRow {
  handle: string;
  total_tokens: number;
  messages: number;
}

/**
 * One Account's public page, as Relay stores it.
 *
 * The row exists as soon as a handle is chosen, whether or not the page is on: turning a page
 * off must not release the handle, or a reader following an old link would land on someone
 * else's Usage.
 */
export interface PublicProfileRecord {
  account_id: string;
  handle: string;
  enabled: boolean;
  show_models: boolean;
  show_cost: boolean;
  /** Whether this page asked to be ranked against everyone else's. */
  on_leaderboard: boolean;
  created_at: string;
  updated_at: string;
}

export interface PublicProfileWriteInput {
  account_id: string;
  handle: string;
  enabled: boolean;
  show_models: boolean;
  show_cost: boolean;
  on_leaderboard: boolean;
  written_at: string;
}

/** A handle another Account already holds is the one refusal this write has to state. */
export type PublicProfileWriteResult =
  | { outcome: "written"; profile: PublicProfileRecord }
  | { outcome: "handle_taken" };

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
  /**
   * The `bucket_start_utc` before which stored hours are deleted.
   *
   * Hours exist to answer the UTC day a local period's edge cuts, which is never more than a
   * day or two back. They are kept far longer than that so a device returning from a long
   * absence can still be told its old hours are already stored, and no longer.
   */
  usage_hour_before: string;
  /**
   * The `utc_date` before which stored days are deleted. The daily rollup is what a long read
   * folds, so it outlives both the hours behind it and the widest window `all` covers.
   */
  usage_day_before: string;
  /**
   * Folds this old are deleted; a fold never outlives the local date in its key by more than
   * retention.
   */
  usage_fold_before: string;
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
  createWebSession(input: CreateWebSessionInput): Promise<void>;
  createIosSession(input: CreateIosSessionInput): Promise<CreateIosSessionResult>;
  createEmailChallenge(input: CreateEmailChallengeInput): Promise<void>;
  /**
   * Spend a mailed token once. An unknown, already-spent, or unreadable hash is `invalid`; a
   * hash whose row has passed `expires_at` is `expired`, even if it was never opened.
   */
  consumeEmailChallenge(tokenHash: string, now: string): Promise<ConsumeEmailChallengeResult>;
  /**
   * The Account this identity reaches, opened when nothing has reached it before.
   *
   * The label the provider states now replaces the one stored for that identity, and the Account's
   * own label follows the identity it was opened with, so a renamed GitHub login or a changed
   * Apple address is not left frozen at whatever it was on the first sign-in. A stand-in label is
   * the exception: it fills an empty one and never replaces a name the channel once stated.
   */
  resolveSignInIdentity(input: ResolveSignInIdentityInput): Promise<AccountRecord>;
  linkIdentity(input: LinkIdentityInput): Promise<LinkIdentityOutcome>;
  listAccountIdentities(accountId: string): Promise<AccountIdentityRecord[]>;
  unlinkIdentity(
    accountId: string,
    provider: IdentityProviderId,
    now: string,
  ): Promise<UnlinkIdentityOutcome>;
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
  /**
   * A rotation whose successor was never presented did not happen from the client's point of
   * view. The row remembers the refresh token it replaced and when. While the successor is
   * unspent (`last_used_at = rotated_at`), the replaced token is accepted wherever the current
   * one is: a refresh with it rotates the family again (the unspent successor dies), a revoke
   * with it ends the family. Once the successor has been spent, the replaced token is dead for
   * every purpose. There is no time bound: the predicate is "unspent". Rotation returns its
   * principal from the write; there is no read after it.
   */
  refreshSession(input: RefreshSessionInput): Promise<SessionPrincipal | null>;
  revokeRefreshSession(input: RevokeRefreshSessionInput): Promise<void>;
  revokePrincipalFamily(
    principal: SessionPrincipal,
    revokedAt: string,
    signOutDevice: boolean,
  ): Promise<void>;
  getAccount(accountId: string): Promise<AccountRecord | null>;
  listAccountDevices(accountId: string): Promise<DeviceRecord[]>;
  getDeviceSyncControl(deviceId: string, generation: number): Promise<DeviceSyncControl | null>;
  updateDeviceProfile(
    deviceId: string,
    generation: number,
    displayName: string,
    platform: string,
    updatedAt: string,
  ): Promise<boolean>;
  /** This Account's public page, or null when it has never chosen a handle. */
  getPublicProfile(accountId: string): Promise<PublicProfileRecord | null>;
  /** Claim or restate this Account's handle and switches, refusing a handle already claimed. */
  writePublicProfile(input: PublicProfileWriteInput): Promise<PublicProfileWriteResult>;
  /**
   * The Account behind a published handle, matched without regard to case.
   *
   * A disabled page answers null here rather than being filtered by the caller: the anonymous
   * read must not be able to tell a handle that was turned off from one that never existed.
   */
  findEnabledPublicProfile(handle: string): Promise<PublicProfileRecord | null>;
  /**
   * What the leaderboard's answer turns over on, read without touching the rollup.
   *
   * The board is one answer for everyone, so its validator is computed before the fold runs,
   * the same way a public page's is. It has to move whenever the board would: a profile
   * joining, leaving, or renaming moves the count and the newest `updated_at`, and an upload
   * from any device of any listed Account moves the summed sync revision.
   */
  leaderboardVersionStamp(): Promise<LeaderboardVersionStamp>;
  accountVersionStamp(accountId: string, activeSince: string): Promise<AccountVersionStamp>;
  accountUsageVersionStamp(accountId: string): Promise<AccountUsageVersionStamp>;
  getEntitlement(accountId: string): Promise<StoredEntitlement | null>;
  putEntitlement(row: StoredEntitlement): Promise<void>;
  applyRevenueCatWebhook(input: ApplyRevenueCatWebhookInput): Promise<"applied" | "duplicate">;
  createRedemptionCodes(rows: RedemptionCodeRow[]): Promise<void>;
  getRedemptionCode(code: string): Promise<RedemptionCodeRow | null>;
  hasRedeemedCode(code: string, accountId: string): Promise<boolean>;
  /**
   * Reserve one redemption: increment the count and write code_redemptions atomically, so two
   * concurrent redeems of a one-use code cannot both pass. Excess or a repeat is a result.
   */
  recordRedemption(
    code: string,
    accountId: string,
    redeemedAt: string,
  ): Promise<"recorded" | "exhausted" | "already_redeemed">;
  /** Give a reservation back when the grant it was made for did not happen. */
  releaseRedemption(code: string, accountId: string): Promise<void>;
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
