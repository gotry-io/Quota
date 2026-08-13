import { QuotaSnapshotSchema } from "@gotry-io/quota-protocol";
import {
  ACCOUNT_SCOPES,
  type AccountMaintenanceInput,
  type AccountPrincipal,
  type AccountRecord,
  type AccountState,
  type AuthorizeDeviceGrantInput,
  type CompleteIdentityLoginInput,
  type CompleteIdentityLoginResult,
  type ConsumeLoginGrantInput,
  type CreateLoginGrantInput,
  DEVICE_SCOPES,
  type DeleteDeviceResult,
  type DeviceGrantDecisionOutcome,
  type DeviceGrantPollResult,
  type DevicePrincipal,
  type DeviceRecord,
  type DeviceSyncControl,
  type LoginGrantConsumeResult,
  type LoginGrantRecord,
  type QuotaSnapshotSubmission,
  type RateLimitInput,
  type RateLimitResult,
  type RefreshSessionInput,
  type RevokeRefreshSessionInput,
  type SnapshotWriteOutcome,
  type StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import { canonicalRequestDigest } from "../security.ts";
import {
  decodeAccountScopes,
  decodeDeviceScopes,
  encodeScopes,
  type RateLimitRow,
  rateLimitResult,
  validateRateLimitInput,
} from "./records.ts";

interface AccountPrincipalRow {
  id: string;
  family_id: string;
  account_id: string;
  device_id: string | null;
  scopes_json: string;
  authenticated_at: string;
}

interface DevicePrincipalRow {
  id: string;
  family_id: string;
  account_id: string;
  device_id: string;
  device_generation: number;
  scopes_json: string;
}

interface SnapshotRow {
  device_id: string;
  sequence: number;
  captured_at: string;
  snapshot_json: string;
  updated_at: string;
}

interface SnapshotControlRow {
  generation: number;
  last_sequence: number;
  last_snapshot_digest: string | null;
}

export class D1AccountState implements AccountState {
  constructor(private readonly database: D1Database) {}

  async ping(): Promise<void> {
    await this.database.prepare("SELECT 1 AS ready").first();
  }

  async performMaintenance(input: AccountMaintenanceInput): Promise<void> {
    if (!Number.isSafeInteger(input.limit) || input.limit < 1 || input.limit > 1_000) {
      throw new Error("Invalid maintenance limit");
    }
    await this.database.batch([
      this.database
        .prepare(
          `DELETE FROM login_grants WHERE id IN (
             SELECT id FROM login_grants WHERE expires_at <= ?1
             ORDER BY expires_at ASC, id ASC LIMIT ?2
           )`,
        )
        .bind(input.grant_expired_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM account_sessions WHERE id IN (
             SELECT id FROM account_sessions
             WHERE refresh_expires_at <= ?1 OR (revoked_at IS NOT NULL AND revoked_at <= ?2)
             ORDER BY COALESCE(revoked_at, refresh_expires_at) ASC, id ASC LIMIT ?3
           )`,
        )
        .bind(input.session_expired_before, input.session_revoked_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM device_sessions WHERE id IN (
             SELECT id FROM device_sessions
             WHERE refresh_expires_at <= ?1 OR (revoked_at IS NOT NULL AND revoked_at <= ?2)
             ORDER BY COALESCE(revoked_at, refresh_expires_at) ASC, id ASC LIMIT ?3
           )`,
        )
        .bind(input.session_expired_before, input.session_revoked_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM rate_limit_counters WHERE key_hash IN (
             SELECT key_hash FROM rate_limit_counters WHERE window_expires_at <= ?1
             ORDER BY window_expires_at ASC, key_hash ASC LIMIT ?2
           )`,
        )
        .bind(input.grant_expired_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM auth_session_store WHERE key_hash IN (
             SELECT key_hash FROM auth_session_store WHERE expires_at <= ?1
             ORDER BY expires_at ASC, key_hash ASC LIMIT ?2
           )`,
        )
        .bind(input.grant_expired_before, input.limit),
    ]);
  }

  async createLoginGrant(input: CreateLoginGrantInput): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO login_grants (
           id, grant_kind, client_id, login_token_hash,
           device_code_hash, user_code_hash, installation_id_hash, device_display_name, platform,
           pkce_challenge, redirect_uri, client_state, poll_interval_seconds, expires_at, created_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15
         )`,
      )
      .bind(
        input.id,
        input.grant_kind,
        input.client_id,
        input.login_token_hash,
        input.device_code_hash,
        input.user_code_hash,
        input.installation_id_hash,
        input.device_display_name,
        input.platform,
        input.pkce_challenge,
        input.redirect_uri,
        input.client_state,
        input.poll_interval_seconds,
        input.expires_at,
        input.created_at,
      )
      .run();
  }

  async getLoginGrantByLoginTokenHash(
    hash: string,
    checkedAt: string,
  ): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(
        `${loginGrantSelect}
         WHERE login_token_hash = ?1 AND expires_at > ?2
           AND completed_at IS NULL AND consumed_at IS NULL AND denied_at IS NULL`,
      )
      .bind(hash, checkedAt)
      .first<LoginGrantRecord>();
  }

  async completeIdentityLogin(
    input: CompleteIdentityLoginInput,
  ): Promise<CompleteIdentityLoginResult> {
    const results = await this.database.batch([
      this.database
        .prepare(
          `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
           SELECT ?4, ?4, ?5, ?6, ?6
           WHERE EXISTS (
             SELECT 1 FROM login_grants
             WHERE id = ?1 AND login_token_hash = ?2 AND expires_at > ?6
               AND completed_at IS NULL AND consumed_at IS NULL AND denied_at IS NULL
           )
           ON CONFLICT(id) DO UPDATE SET
             display_label = excluded.display_label,
             updated_at = excluded.updated_at
           RETURNING id, identity_subject, display_label, created_at, updated_at`,
        )
        .bind(
          input.grant_id,
          input.login_token_hash,
          input.completion_nonce_hash,
          input.account_id,
          input.display_label,
          input.completed_at,
        ),
      this.database
        .prepare(
          `UPDATE login_grants
           SET account_id = ?4,
               code_hash = ?5,
               completion_nonce_hash = ?3,
               approved_at = ?6,
               completed_at = ?6
           WHERE id = ?1 AND login_token_hash = ?2 AND expires_at > ?6
             AND completed_at IS NULL AND consumed_at IS NULL AND denied_at IS NULL
           RETURNING id, grant_kind, client_id, account_id, installation_id_hash,
                     device_display_name, platform, pkce_challenge, redirect_uri, client_state, expires_at,
                     approved_at, denied_at, consumed_at`,
        )
        .bind(
          input.grant_id,
          input.login_token_hash,
          input.completion_nonce_hash,
          input.account_id,
          input.authorization_code_hash,
          input.completed_at,
        ),
    ]);
    const account = resultRow<AccountRecord>(results[0]);
    const grant = resultRow<LoginGrantRecord>(results[1]);
    if (account && grant) {
      return { outcome: "completed", account, grant };
    }

    const existing = await this.getLoginGrantById(input.grant_id);
    if (!existing) {
      return { outcome: "not_found", account: null, grant: null };
    }
    if (Date.parse(existing.expires_at) <= Date.parse(input.completed_at)) {
      return { outcome: "expired", account: null, grant: existing };
    }
    return { outcome: "already_completed", account: null, grant: existing };
  }

  async getLoginGrantByAuthorizationCodeHash(
    hash: string,
    checkedAt: string,
  ): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(
        `${loginGrantSelect}
         WHERE code_hash = ?1 AND expires_at > ?2 AND approved_at IS NOT NULL
           AND denied_at IS NULL AND consumed_at IS NULL`,
      )
      .bind(hash, checkedAt)
      .first<LoginGrantRecord>();
  }

  async authorizeDeviceGrant(
    input: AuthorizeDeviceGrantInput,
  ): Promise<DeviceGrantDecisionOutcome> {
    const existing = await this.getLoginGrantByUserCode(input.user_code_hash);
    if (!existing) {
      return "not_found";
    }
    if (existing.consumed_at) {
      return "consumed";
    }
    if (existing.approved_at || existing.denied_at) {
      return "already_decided";
    }
    if (Date.parse(existing.expires_at) <= Date.parse(input.decided_at)) {
      return "expired";
    }
    const column = input.decision === "approve" ? "approved_at" : "denied_at";
    const result = await this.database
      .prepare(
        `UPDATE login_grants
         SET account_id = ?2, ${column} = ?3
         WHERE user_code_hash = ?1 AND grant_kind = 'device_code' AND expires_at > ?3
           AND approved_at IS NULL AND denied_at IS NULL AND consumed_at IS NULL`,
      )
      .bind(input.user_code_hash, input.account_id, input.decided_at)
      .run();
    if (result.meta.changes === 1) {
      return input.decision === "approve" ? "approved" : "denied";
    }
    return "already_decided";
  }

  async pollDeviceGrant(hash: string, checkedAt: string): Promise<DeviceGrantPollResult> {
    const row = await this.database
      .prepare(
        `SELECT id, grant_kind, client_id, account_id, installation_id_hash,
                device_display_name, platform, pkce_challenge, redirect_uri, client_state, expires_at,
                approved_at, denied_at, consumed_at, poll_interval_seconds, last_polled_at
         FROM login_grants WHERE device_code_hash = ?1 AND grant_kind = 'device_code'`,
      )
      .bind(hash)
      .first<LoginGrantRecord & { poll_interval_seconds: number; last_polled_at: string | null }>();
    if (!row) {
      return { outcome: "not_found", poll_interval_seconds: 5 };
    }
    const interval = row.poll_interval_seconds;
    if (row.consumed_at) {
      return { outcome: "consumed", poll_interval_seconds: interval };
    }
    if (row.denied_at) {
      return { outcome: "denied", poll_interval_seconds: interval };
    }
    if (Date.parse(row.expires_at) <= Date.parse(checkedAt)) {
      return { outcome: "expired", poll_interval_seconds: interval };
    }
    if (
      row.last_polled_at &&
      Date.parse(checkedAt) < Date.parse(row.last_polled_at) + interval * 1000
    ) {
      const slowedInterval = interval + 5;
      await this.database
        .prepare(
          `UPDATE login_grants
           SET poll_interval_seconds = ?2, last_polled_at = ?3
           WHERE id = ?1 AND consumed_at IS NULL`,
        )
        .bind(row.id, slowedInterval, checkedAt)
        .run();
      return { outcome: "slow_down", poll_interval_seconds: slowedInterval };
    }
    await this.database
      .prepare("UPDATE login_grants SET last_polled_at = ?2 WHERE id = ?1 AND consumed_at IS NULL")
      .bind(row.id, checkedAt)
      .run();
    if (!row.approved_at || !row.account_id) {
      return { outcome: "pending", poll_interval_seconds: interval };
    }
    return { outcome: "ready", grant: row, poll_interval_seconds: interval };
  }

  async consumeLoginGrant(input: ConsumeLoginGrantInput): Promise<LoginGrantConsumeResult> {
    const accountScopes = encodeScopes(["account:read", "session:revoke:self"], ACCOUNT_SCOPES);
    const deviceScopes = encodeScopes(DEVICE_SCOPES, DEVICE_SCOPES);
    let results: D1Result<unknown>[];
    try {
      results = await this.database.batch([
        this.database
          .prepare(
            `UPDATE login_grants
           SET consumed_at = ?4, consume_nonce_hash = ?3
           WHERE id = ?1 AND (code_hash = ?2 OR device_code_hash = ?2)
             AND account_id IS NOT NULL AND approved_at IS NOT NULL AND denied_at IS NULL
             AND consumed_at IS NULL AND expires_at > ?4
           RETURNING account_id`,
          )
          .bind(
            input.grant_id,
            input.credential_hash,
            input.completion_nonce_hash,
            input.consumed_at,
          ),
        this.database
          .prepare(
            `INSERT INTO devices (
             id, account_id, installation_id_hash, display_name, platform,
             created_at, last_login_at, last_seen_at
           )
           SELECT ?1, grants.account_id, ?2, ?3, ?4, ?5, ?5, ?5
           FROM login_grants AS grants
           WHERE grants.id = ?6 AND grants.consume_nonce_hash = ?7
             AND NOT EXISTS (
               SELECT 1 FROM devices AS tombstone
               WHERE tombstone.account_id = grants.account_id
                 AND tombstone.installation_id_hash = ?2
                 AND tombstone.deleted_at IS NOT NULL
                 AND grants.approved_at <= tombstone.deleted_at
             )
           ON CONFLICT(account_id, installation_id_hash) DO UPDATE SET
             display_name = excluded.display_name,
             platform = excluded.platform,
             last_login_at = excluded.last_login_at,
             last_seen_at = excluded.last_seen_at,
             signed_out_at = NULL,
             deleted_at = NULL
           RETURNING id, account_id, display_name, platform, generation, last_sequence,
                     last_usage_sequence, usage_sync_revision, created_at, last_login_at,
                     last_seen_at, signed_out_at, deleted_at, deleted_before`,
          )
          .bind(
            input.device_id,
            input.installation_id_hash,
            input.display_name,
            input.platform,
            input.consumed_at,
            input.grant_id,
            input.completion_nonce_hash,
          ),
        this.database
          .prepare(
            `UPDATE account_sessions SET revoked_at = ?3
           WHERE device_id = (
             SELECT id FROM devices WHERE account_id = (
               SELECT account_id FROM login_grants WHERE id = ?1
             ) AND installation_id_hash = ?2
           ) AND revoked_at IS NULL`,
          )
          .bind(input.grant_id, input.installation_id_hash, input.consumed_at),
        this.database
          .prepare(
            `UPDATE device_sessions SET revoked_at = ?3
           WHERE device_id = (
             SELECT id FROM devices WHERE account_id = (
               SELECT account_id FROM login_grants WHERE id = ?1
             ) AND installation_id_hash = ?2
           ) AND revoked_at IS NULL`,
          )
          .bind(input.grant_id, input.installation_id_hash, input.consumed_at),
        this.database
          .prepare(
            `INSERT INTO account_sessions (
             id, family_id, account_id, device_id, access_token_hash, refresh_token_hash,
             scopes_json, authenticated_at, expires_at, refresh_expires_at,
             last_used_at, created_at
           )
           SELECT ?1, ?2, grants.account_id, devices.id, ?3, ?4, ?5, ?6, ?7, ?8, ?6, ?6
           FROM login_grants AS grants
           INNER JOIN devices ON devices.account_id = grants.account_id
             AND devices.installation_id_hash = ?9
             AND devices.deleted_at IS NULL AND devices.signed_out_at IS NULL
           WHERE grants.id = ?10 AND grants.consume_nonce_hash = ?11`,
          )
          .bind(
            input.account_session.session_id,
            input.family_id,
            input.account_session.access_token_hash,
            input.account_session.refresh_token_hash,
            accountScopes,
            input.consumed_at,
            input.account_session.access_expires_at,
            input.account_session.refresh_expires_at,
            input.installation_id_hash,
            input.grant_id,
            input.completion_nonce_hash,
          ),
        this.database
          .prepare(
            `INSERT INTO device_sessions (
             id, family_id, device_id, device_generation, access_token_hash, refresh_token_hash,
             scopes_json, expires_at, refresh_expires_at, last_used_at, created_at
           )
           SELECT ?1, ?2, devices.id, devices.generation, ?3, ?4, ?5, ?6, ?7, ?8, ?8
           FROM login_grants AS grants
           INNER JOIN devices ON devices.account_id = grants.account_id
             AND devices.installation_id_hash = ?9
             AND devices.deleted_at IS NULL AND devices.signed_out_at IS NULL
           WHERE grants.id = ?10 AND grants.consume_nonce_hash = ?11`,
          )
          .bind(
            input.device_session.session_id,
            input.family_id,
            input.device_session.access_token_hash,
            input.device_session.refresh_token_hash,
            deviceScopes,
            input.device_session.access_expires_at,
            input.device_session.refresh_expires_at,
            input.consumed_at,
            input.installation_id_hash,
            input.grant_id,
            input.completion_nonce_hash,
          ),
        this.database
          .prepare(
            `UPDATE login_grants
           SET device_id = (
             SELECT id FROM devices WHERE account_id = login_grants.account_id
               AND installation_id_hash = ?2 AND deleted_at IS NULL
           )
           WHERE id = ?1 AND consume_nonce_hash = ?3`,
          )
          .bind(input.grant_id, input.installation_id_hash, input.completion_nonce_hash),
      ]);
    } catch (error) {
      const concurrent = await this.getLoginGrantByIdAndCredential(
        input.grant_id,
        input.credential_hash,
      );
      if (concurrent?.consumed_at) {
        return { outcome: "consumed" };
      }
      throw error;
    }
    const device = resultRow<DeviceRecord>(results[1]);
    if (resultChanged(results[0]) && device) {
      return { outcome: "issued", account_id: device.account_id, device };
    }
    const grant = await this.getLoginGrantByIdAndCredential(input.grant_id, input.credential_hash);
    if (!grant) {
      return { outcome: "not_found" };
    }
    if (grant.consumed_at) {
      return { outcome: "consumed" };
    }
    if (Date.parse(grant.expires_at) <= Date.parse(input.consumed_at)) {
      return { outcome: "expired" };
    }
    return { outcome: "not_approved" };
  }

  async authorizeAccountSession(
    accessTokenHash: string,
    checkedAt: string,
  ): Promise<AccountPrincipal | null> {
    const row = await this.database
      .prepare(
        `SELECT id, family_id, account_id, device_id, scopes_json, authenticated_at
         FROM account_sessions
         WHERE access_token_hash = ?1 AND revoked_at IS NULL AND expires_at > ?2`,
      )
      .bind(accessTokenHash, checkedAt)
      .first<AccountPrincipalRow>();
    if (!row) {
      return null;
    }
    await this.database
      .prepare("UPDATE account_sessions SET last_used_at = ?2 WHERE id = ?1 AND revoked_at IS NULL")
      .bind(row.id, checkedAt)
      .run();
    return accountPrincipal(row);
  }

  async authorizeDeviceSession(
    accessTokenHash: string,
    checkedAt: string,
  ): Promise<DevicePrincipal | null> {
    const row = await this.database
      .prepare(
        `SELECT sessions.id, sessions.family_id, devices.account_id,
                sessions.device_id, sessions.device_generation, sessions.scopes_json
         FROM device_sessions AS sessions
         INNER JOIN devices ON devices.id = sessions.device_id
         WHERE sessions.access_token_hash = ?1 AND sessions.revoked_at IS NULL
           AND sessions.expires_at > ?2 AND sessions.device_generation = devices.generation
           AND devices.signed_out_at IS NULL AND devices.deleted_at IS NULL`,
      )
      .bind(accessTokenHash, checkedAt)
      .first<DevicePrincipalRow>();
    if (!row) {
      return null;
    }
    await this.database.batch([
      this.database
        .prepare(
          "UPDATE device_sessions SET last_used_at = ?2 WHERE id = ?1 AND revoked_at IS NULL",
        )
        .bind(row.id, checkedAt),
      this.database
        .prepare(
          `UPDATE devices SET last_seen_at = ?3
           WHERE id = ?1 AND generation = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
        )
        .bind(row.device_id, row.device_generation, checkedAt),
    ]);
    return devicePrincipal(row);
  }

  async refreshAccountSession(input: RefreshSessionInput): Promise<AccountPrincipal | null> {
    const row = await this.database
      .prepare(
        `UPDATE account_sessions
         SET access_token_hash = ?2, refresh_token_hash = ?3, expires_at = ?4,
             refresh_expires_at = ?5, last_used_at = ?6
         WHERE refresh_token_hash = ?1 AND revoked_at IS NULL AND refresh_expires_at > ?6
         RETURNING id, family_id, account_id, device_id, scopes_json, authenticated_at`,
      )
      .bind(
        input.refresh_token_hash,
        input.new_access_token_hash,
        input.new_refresh_token_hash,
        input.access_expires_at,
        input.refresh_expires_at,
        input.refreshed_at,
      )
      .first<AccountPrincipalRow>();
    return row ? accountPrincipal(row) : null;
  }

  async refreshDeviceSession(input: RefreshSessionInput): Promise<DevicePrincipal | null> {
    const updated = await this.database
      .prepare(
        `UPDATE device_sessions
         SET access_token_hash = ?2, refresh_token_hash = ?3, expires_at = ?4,
             refresh_expires_at = ?5, last_used_at = ?6
         WHERE refresh_token_hash = ?1 AND revoked_at IS NULL AND refresh_expires_at > ?6
           AND EXISTS (
             SELECT 1 FROM devices
             WHERE devices.id = device_sessions.device_id
               AND devices.generation = device_sessions.device_generation
               AND devices.signed_out_at IS NULL AND devices.deleted_at IS NULL
           )`,
      )
      .bind(
        input.refresh_token_hash,
        input.new_access_token_hash,
        input.new_refresh_token_hash,
        input.access_expires_at,
        input.refresh_expires_at,
        input.refreshed_at,
      )
      .run();
    if (updated.meta.changes !== 1) {
      return null;
    }
    return this.authorizeDeviceSession(input.new_access_token_hash, input.refreshed_at);
  }

  async revokeRefreshSession(input: RevokeRefreshSessionInput): Promise<void> {
    const accountAudience = input.token_audience === "account";
    const familySelect = accountAudience
      ? "SELECT family_id FROM account_sessions WHERE refresh_token_hash = ?1"
      : "SELECT family_id FROM device_sessions WHERE refresh_token_hash = ?1";
    const signOutDevice = accountAudience
      ? this.database
          .prepare(
            `UPDATE devices SET signed_out_at = ?2
             WHERE id = (
               SELECT device_id FROM account_sessions
               WHERE refresh_token_hash = ?1 AND revoked_at IS NULL
             )
               AND generation = (
                 SELECT device_generation FROM device_sessions
                 WHERE family_id = (${familySelect}) AND revoked_at IS NULL
                 LIMIT 1
               )
               AND signed_out_at IS NULL AND deleted_at IS NULL`,
          )
          .bind(input.refresh_token_hash, input.revoked_at)
      : this.database
          .prepare(
            `UPDATE devices SET signed_out_at = ?2
             WHERE id = (
               SELECT device_id FROM device_sessions
               WHERE refresh_token_hash = ?1 AND revoked_at IS NULL
             )
               AND generation = (
                 SELECT device_generation FROM device_sessions
                 WHERE refresh_token_hash = ?1 AND revoked_at IS NULL
               )
               AND signed_out_at IS NULL AND deleted_at IS NULL`,
          )
          .bind(input.refresh_token_hash, input.revoked_at);
    await this.database.batch([
      signOutDevice,
      this.database
        .prepare(
          `UPDATE account_sessions SET revoked_at = COALESCE(revoked_at, ?2)
           WHERE family_id = (${familySelect})`,
        )
        .bind(input.refresh_token_hash, input.revoked_at),
      this.database
        .prepare(
          `UPDATE device_sessions SET revoked_at = COALESCE(revoked_at, ?2)
           WHERE family_id = (${familySelect})`,
        )
        .bind(input.refresh_token_hash, input.revoked_at),
    ]);
  }

  async revokePrincipalFamily(
    principal: AccountPrincipal | DevicePrincipal,
    revokedAt: string,
    signOutDevice: boolean,
  ): Promise<void> {
    const deviceId = principal.kind === "device" ? principal.device_id : principal.device_id;
    const statements = [
      this.database
        .prepare(
          "UPDATE account_sessions SET revoked_at = ?2 WHERE family_id = ?1 AND revoked_at IS NULL",
        )
        .bind(principal.family_id, revokedAt),
      this.database
        .prepare(
          "UPDATE device_sessions SET revoked_at = ?2 WHERE family_id = ?1 AND revoked_at IS NULL",
        )
        .bind(principal.family_id, revokedAt),
    ];
    if (signOutDevice && deviceId) {
      statements.push(
        this.database
          .prepare("UPDATE devices SET signed_out_at = ?2 WHERE id = ?1 AND deleted_at IS NULL")
          .bind(deviceId, revokedAt),
      );
    }
    await this.database.batch(statements);
  }

  async getAccount(accountId: string): Promise<AccountRecord | null> {
    return this.database
      .prepare(
        `SELECT id, identity_subject, display_label, created_at, updated_at,
                public_profile_enabled, public_profile_slug
         FROM accounts WHERE id = ?1`,
      )
      .bind(accountId)
      .first<AccountRecord>();
  }

  async getAccountByPublicSlug(slug: string): Promise<AccountRecord | null> {
    return this.database
      .prepare(
        `SELECT id, identity_subject, display_label, created_at, updated_at,
                public_profile_enabled, public_profile_slug
         FROM accounts
         WHERE public_profile_slug = ?1 OR LOWER(display_label) = ?1
         ORDER BY CASE WHEN LOWER(display_label) = ?1 THEN 0 ELSE 1 END, created_at ASC
         LIMIT 1`,
      )
      .bind(slug)
      .first<AccountRecord>();
  }

  async setPublicProfile(
    accountId: string,
    enabled: boolean,
    slug: string | null,
    updatedAt: string,
  ): Promise<"ok" | "conflict"> {
    if (slug) {
      const taken = await this.database
        .prepare("SELECT id FROM accounts WHERE public_profile_slug = ?1 AND id != ?2 LIMIT 1")
        .bind(slug, accountId)
        .first<{ id: string }>();
      if (taken) return "conflict";
    }
    await this.database
      .prepare(
        `UPDATE accounts
         SET public_profile_enabled = ?2, public_profile_slug = ?3, updated_at = ?4
         WHERE id = ?1`,
      )
      .bind(accountId, enabled ? 1 : 0, slug, updatedAt)
      .run();
    return "ok";
  }

  async listAccountDevices(accountId: string): Promise<DeviceRecord[]> {
    const rows = await this.database
      .prepare(
        `${deviceSelect}
         WHERE account_id = ?1 AND deleted_at IS NULL
         ORDER BY created_at ASC, id ASC LIMIT 257`,
      )
      .bind(accountId)
      .all<DeviceRecord>();
    return rows.results;
  }

  async accountOwnsVisibleDevice(accountId: string, deviceId: string): Promise<boolean> {
    const row = await this.database
      .prepare(
        "SELECT 1 AS found FROM devices WHERE account_id = ?1 AND id = ?2 AND deleted_at IS NULL",
      )
      .bind(accountId, deviceId)
      .first<{ found: number }>();
    return row?.found === 1;
  }

  async getDeviceSyncControl(
    deviceId: string,
    generation: number,
  ): Promise<DeviceSyncControl | null> {
    const row = await this.database
      .prepare(
        `SELECT id AS device_id, generation, last_sequence + 1 AS next_snapshot_sequence,
                last_usage_sequence + 1 AS next_usage_sequence,
                deleted_before AS usage_deleted_before, usage_sync_revision
         FROM devices
         WHERE id = ?1 AND generation = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(deviceId, generation)
      .first<DeviceSyncControl>();
    return row ?? null;
  }

  async deleteDeviceData(
    accountId: string,
    deviceId: string,
    deletedAt: string,
  ): Promise<DeleteDeviceResult | null> {
    const results = await this.database.batch([
      this.database
        .prepare(
          `UPDATE devices
           SET generation = generation + 1, last_sequence = -1, last_snapshot_digest = NULL,
               last_usage_sequence = -1, usage_sync_revision = usage_sync_revision + 1,
               display_name = NULL, platform = NULL, last_seen_at = NULL,
               signed_out_at = ?3, deleted_at = ?3, deleted_before = ?3
           WHERE account_id = ?1 AND id = ?2 AND deleted_at IS NULL
           RETURNING id AS device_id, generation, deleted_before`,
        )
        .bind(accountId, deviceId, deletedAt),
      this.database
        .prepare(
          `UPDATE device_sessions SET revoked_at = ?3
           WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           ) AND revoked_at IS NULL`,
        )
        .bind(accountId, deviceId, deletedAt),
      this.database
        .prepare(
          `UPDATE account_sessions SET revoked_at = ?3
           WHERE device_id = ?2 AND account_id = ?1 AND revoked_at IS NULL`,
        )
        .bind(accountId, deviceId, deletedAt),
      this.database
        .prepare(
          `DELETE FROM quota_snapshots WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(
          `DELETE FROM usage_hourly WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(
          `DELETE FROM usage_coverage WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(
          `DELETE FROM usage_submissions WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(
          `DELETE FROM usage_submission_parts WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(`DELETE FROM login_grants WHERE device_id = ?2 AND account_id = ?1`)
        .bind(accountId, deviceId),
    ]);
    return resultRow<DeleteDeviceResult>(results[0]);
  }

  async recordSnapshot(
    principal: DevicePrincipal,
    envelope: QuotaSnapshotSubmission,
    receivedAt: string,
  ): Promise<SnapshotWriteOutcome> {
    const digest = await canonicalRequestDigest(envelope);
    const control = await this.database
      .prepare(
        `SELECT generation, last_sequence, last_snapshot_digest
         FROM devices
         WHERE id = ?1 AND account_id = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.account_id)
      .first<SnapshotControlRow>();
    if (
      !control ||
      control.generation !== principal.generation ||
      envelope.generation !== principal.generation
    ) {
      return "stale_device";
    }
    if (envelope.sequence === control.last_sequence) {
      return digest === control.last_snapshot_digest ? "duplicate" : "sequence_conflict";
    }
    if (envelope.sequence !== control.last_sequence + 1) {
      return "sequence_conflict";
    }
    const statements = [
      this.database
        .prepare(
          `UPDATE devices
           SET last_sequence = ?3, last_seen_at = ?4, last_snapshot_digest = ?5
           WHERE id = ?1 AND generation = ?2 AND deleted_at IS NULL AND signed_out_at IS NULL
             AND last_sequence = ?3 - 1`,
        )
        .bind(principal.device_id, principal.generation, envelope.sequence, receivedAt, digest),
      ...envelope.snapshots.map((snapshot) =>
        this.database
          .prepare(
            `INSERT INTO quota_snapshots (
               device_id, provider, account_fingerprint, sequence, captured_at,
               observed_at, snapshot_json, updated_at
             )
             SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
             WHERE EXISTS (
               SELECT 1 FROM devices
               WHERE id = ?1 AND last_sequence = ?4 AND last_snapshot_digest = ?9
             )
             ON CONFLICT(device_id, provider, account_fingerprint) DO UPDATE SET
               sequence = excluded.sequence,
               captured_at = excluded.captured_at,
               observed_at = excluded.observed_at,
               snapshot_json = excluded.snapshot_json,
               updated_at = excluded.updated_at`,
          )
          .bind(
            principal.device_id,
            snapshot.provider,
            snapshot.account.fingerprint,
            envelope.sequence,
            envelope.captured_at,
            snapshot.observed_at,
            JSON.stringify(snapshot),
            receivedAt,
            digest,
          ),
      ),
    ];
    const results = await this.database.batch(statements);
    if (resultChanged(results[0])) {
      return "accepted";
    }
    const concurrent = await this.database
      .prepare(
        `SELECT last_sequence, last_snapshot_digest
         FROM devices WHERE id = ?1 AND generation = ?2 AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.generation)
      .first<Pick<SnapshotControlRow, "last_sequence" | "last_snapshot_digest">>();
    return concurrent?.last_sequence === envelope.sequence &&
      concurrent.last_snapshot_digest === digest
      ? "duplicate"
      : "sequence_conflict";
  }

  async listLatestSnapshots(accountId: string): Promise<StoredQuotaSnapshot[]> {
    const rows = await this.database
      .prepare(
        `SELECT snapshots.device_id, snapshots.sequence, snapshots.captured_at,
                snapshots.snapshot_json, snapshots.updated_at
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.account_id = ?1 AND devices.deleted_at IS NULL
         ORDER BY snapshots.updated_at DESC, snapshots.device_id ASC,
                  snapshots.provider ASC, snapshots.account_fingerprint ASC
         LIMIT 8193`,
      )
      .bind(accountId)
      .all<SnapshotRow>();
    return rows.results.map((row) => ({
      device_id: row.device_id,
      sequence: row.sequence,
      captured_at: row.captured_at,
      snapshot: QuotaSnapshotSchema.parse(JSON.parse(row.snapshot_json)),
      updated_at: row.updated_at,
    }));
  }

  async consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult> {
    validateRateLimitInput(input);
    const results = await this.database.batch<RateLimitRow>([
      this.database
        .prepare("DELETE FROM rate_limit_counters WHERE window_expires_at <= ?1")
        .bind(input.checked_at),
      this.database
        .prepare(
          `INSERT INTO rate_limit_counters (
             key_hash, window_started_at, window_expires_at, request_count
           ) VALUES (?1, ?2, ?3, 1)
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

  private async getLoginGrantById(id: string): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(`${loginGrantSelect} WHERE id = ?1`)
      .bind(id)
      .first<LoginGrantRecord>();
  }

  private async getLoginGrantByUserCode(hash: string): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(`${loginGrantSelect} WHERE user_code_hash = ?1 AND grant_kind = 'device_code'`)
      .bind(hash)
      .first<LoginGrantRecord>();
  }

  private async getLoginGrantByIdAndCredential(
    id: string,
    hash: string,
  ): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(`${loginGrantSelect} WHERE id = ?1 AND (code_hash = ?2 OR device_code_hash = ?2)`)
      .bind(id, hash)
      .first<LoginGrantRecord>();
  }
}

const loginGrantSelect = `SELECT id, grant_kind, client_id, account_id, installation_id_hash,
  device_display_name, platform, pkce_challenge, redirect_uri, client_state, expires_at,
  approved_at, denied_at, consumed_at FROM login_grants`;

const deviceSelect = `SELECT id, account_id, display_name, platform, generation, last_sequence,
  last_usage_sequence, usage_sync_revision, created_at, last_login_at, last_seen_at,
  signed_out_at, deleted_at, deleted_before FROM devices`;

function accountPrincipal(row: AccountPrincipalRow): AccountPrincipal {
  return {
    kind: "account",
    session_id: row.id,
    family_id: row.family_id,
    account_id: row.account_id,
    device_id: row.device_id,
    client_kind: "cli",
    scopes: decodeAccountScopes(row.scopes_json),
    authenticated_at: row.authenticated_at,
  };
}

function devicePrincipal(row: DevicePrincipalRow): DevicePrincipal {
  return {
    kind: "device",
    session_id: row.id,
    family_id: row.family_id,
    account_id: row.account_id,
    device_id: row.device_id,
    generation: row.device_generation,
    scopes: decodeDeviceScopes(row.scopes_json),
  };
}

function resultChanged(result: D1Result<unknown> | undefined): boolean {
  return (result?.meta.changes ?? 0) === 1;
}

function resultRow<T>(result: D1Result<unknown> | undefined): T | null {
  return (result?.results[0] as T | undefined) ?? null;
}
