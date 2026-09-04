import {
  IOS_OAUTH_CLIENT_ID,
  type ProviderId,
  QuotaSnapshotSchema,
} from "@gotry-io/quota-protocol";
import type {
  AccountLoginGrantConsumeResult,
  AccountMaintenanceInput,
  AccountRecord,
  AccountState,
  AccountVersionStamp,
  CompleteIdentityLoginInput,
  CompleteIdentityLoginResult,
  ConsumeAccountLoginGrantInput,
  ConsumeLoginGrantInput,
  CreateLoginGrantInput,
  CreateWebSessionInput,
  DeleteDeviceResult,
  DeviceRecord,
  DeviceSyncControl,
  DeviceWriterPrincipal,
  LoginGrantConsumeResult,
  LoginGrantRecord,
  QuotaSnapshotSubmission,
  RateLimitInput,
  RateLimitResult,
  RefreshSessionInput,
  RevokeRefreshSessionInput,
  SessionClientKind,
  SessionPrincipal,
  SnapshotWriteResult,
  StoredQuotaSnapshot,
} from "@gotry-io/relay-core";
import {
  decodeSessionScopes,
  encodeScopes,
  IOS_SESSION_SCOPES,
  QUOTABAR_SESSION_SCOPES,
  type RateLimitRow,
  rateLimitResult,
  validateRateLimitInput,
  WEB_SESSION_SCOPES,
} from "./records.ts";

interface SessionPrincipalRow {
  id: string;
  family_id: string;
  account_id: string;
  device_id: string | null;
  device_generation: number | null;
  client_kind: string;
  scopes_json: string;
  authenticated_at: string;
}

interface SnapshotRow {
  device_id: string;
  snapshot_json: string;
}

interface StoredSnapshotCursor {
  observed_at: string;
  status: string | null;
}

/**
 * Same accept rule as the `ON CONFLICT … WHERE` in `recordSnapshot`: a newer `observed_at`
 * always wins; a same-instant restatement wins only when it changes `available` to a failure.
 */
function snapshotWriteIsAccepted(
  stored: StoredSnapshotCursor | undefined,
  incoming: { observed_at: string; status: string },
): boolean {
  if (stored === undefined) {
    return true;
  }
  if (incoming.observed_at > stored.observed_at) {
    return true;
  }
  return (
    incoming.observed_at === stored.observed_at &&
    stored.status === "available" &&
    incoming.status !== "available"
  );
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
          `DELETE FROM sessions WHERE id IN (
             SELECT id FROM sessions
             WHERE refresh_expires_at <= ?1 OR (revoked_at IS NOT NULL AND revoked_at <= ?2)
             ORDER BY COALESCE(revoked_at, refresh_expires_at) ASC, id ASC LIMIT ?3
           )`,
        )
        .bind(input.session_expired_before, input.session_revoked_before, input.limit),
      // By rowid, not by key_hash: a counter is one (key_hash, window_started_at) row, and a
      // subject whose previous window expired usually has a live one under the same hash.
      this.database
        .prepare(
          `DELETE FROM rate_limit_counters WHERE rowid IN (
             SELECT rowid FROM rate_limit_counters WHERE window_expires_at <= ?1
             ORDER BY window_expires_at ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.grant_expired_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM quota_snapshots WHERE rowid IN (
             SELECT rowid FROM quota_snapshots WHERE observed_at <= ?1
             ORDER BY observed_at ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.snapshot_observed_before, input.limit),
      // Usage is the only thing here an account accumulates without limit, so it is the only
      // thing that can make a read of it impossible. The hours go first and their versions with
      // them: a version outliving its hour would refuse an upload of an hour that is gone.
      this.database
        .prepare(
          `DELETE FROM usage_hourly WHERE rowid IN (
             SELECT rowid FROM usage_hourly WHERE bucket_start_utc < ?1
             ORDER BY bucket_start_utc ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.usage_hour_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM usage_hour_scans WHERE rowid IN (
             SELECT rowid FROM usage_hour_scans WHERE bucket_start_utc < ?1
             ORDER BY bucket_start_utc ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.usage_hour_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM usage_daily WHERE rowid IN (
             SELECT rowid FROM usage_daily WHERE utc_date < ?1
             ORDER BY utc_date ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.usage_day_before, input.limit),
      this.database
        .prepare(
          `DELETE FROM account_usage_folds WHERE rowid IN (
             SELECT rowid FROM account_usage_folds WHERE created_at <= ?1
             ORDER BY created_at ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.usage_fold_before, input.limit),
    ]);
  }

  async createLoginGrant(input: CreateLoginGrantInput): Promise<void> {
    await this.database
      .prepare(
        `INSERT INTO login_grants (
           id, client_id, login_token_hash, pkce_challenge, redirect_uri, client_state,
           expires_at, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .bind(
        input.id,
        input.client_id,
        input.login_token_hash,
        input.pkce_challenge,
        input.redirect_uri,
        input.client_state,
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
           AND completed_at IS NULL AND consumed_at IS NULL`,
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
               AND completed_at IS NULL AND consumed_at IS NULL
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
               completed_at = ?6
           WHERE id = ?1 AND login_token_hash = ?2 AND expires_at > ?6
             AND completed_at IS NULL AND consumed_at IS NULL
           RETURNING id, client_id, account_id, pkce_challenge, redirect_uri, client_state,
                     expires_at, completed_at, consumed_at`,
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
         WHERE code_hash = ?1 AND expires_at > ?2
           AND completed_at IS NOT NULL AND consumed_at IS NULL`,
      )
      .bind(hash, checkedAt)
      .first<LoginGrantRecord>();
  }

  /**
   * Turn a completed browser grant into this Device and the one session that speaks for it.
   *
   * The Device is found or created by installation, every session it already had is revoked, and
   * one row is written carrying both what this login may read and what it may write. A second
   * sign-in on the same Mac therefore leaves exactly one live token, not two families to keep in
   * step.
   */
  async consumeLoginGrant(input: ConsumeLoginGrantInput): Promise<LoginGrantConsumeResult> {
    const scopes = encodeScopes(QUOTABAR_SESSION_SCOPES);
    let results: D1Result<unknown>[];
    try {
      results = await this.database.batch([
        this.database
          .prepare(
            `UPDATE login_grants
           SET consumed_at = ?4, consume_nonce_hash = ?3
           WHERE id = ?1 AND code_hash = ?2
             AND account_id IS NOT NULL AND completed_at IS NOT NULL
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
                 AND grants.completed_at <= tombstone.deleted_at
             )
           ON CONFLICT(account_id, installation_id_hash) DO UPDATE SET
             display_name = excluded.display_name,
             platform = excluded.platform,
             last_login_at = excluded.last_login_at,
             last_seen_at = excluded.last_seen_at,
             signed_out_at = NULL,
             deleted_at = NULL
           RETURNING id, account_id, display_name, platform, generation,
                     usage_sync_revision, created_at, last_login_at,
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
        // Fenced by the consume nonce like every other statement in this batch: only a call
        // that actually consumed the grant may end the sessions this Device already had.
        this.database
          .prepare(
            `UPDATE sessions SET revoked_at = ?3
           WHERE device_id = (
             SELECT devices.id FROM devices
             INNER JOIN login_grants AS grants ON grants.account_id = devices.account_id
             WHERE grants.id = ?1 AND grants.consume_nonce_hash = ?4
               AND devices.installation_id_hash = ?2
           ) AND revoked_at IS NULL`,
          )
          .bind(
            input.grant_id,
            input.installation_id_hash,
            input.consumed_at,
            input.completion_nonce_hash,
          ),
        this.database
          .prepare(
            `INSERT INTO sessions (
             id, family_id, account_id, device_id, device_generation, client_kind,
             access_token_hash, refresh_token_hash, scopes_json,
             authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
           )
           SELECT ?1, ?2, grants.account_id, devices.id, devices.generation, 'quotabar',
                  ?3, ?4, ?5, ?6, ?7, ?8, ?6, ?6
           FROM login_grants AS grants
           INNER JOIN devices ON devices.account_id = grants.account_id
             AND devices.installation_id_hash = ?9
             AND devices.deleted_at IS NULL AND devices.signed_out_at IS NULL
           WHERE grants.id = ?10 AND grants.consume_nonce_hash = ?11`,
          )
          .bind(
            input.session.session_id,
            input.family_id,
            input.session.access_token_hash,
            input.session.refresh_token_hash,
            scopes,
            input.consumed_at,
            input.session.access_expires_at,
            input.session.refresh_expires_at,
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
        // What this Account is called, read in the batch that issued the session: the client
        // can name it the moment the exchange answers, without a second round trip.
        this.database
          .prepare(
            `SELECT accounts.display_label AS display_label
           FROM accounts
           INNER JOIN login_grants AS grants ON grants.account_id = accounts.id
           WHERE grants.id = ?1 AND grants.consume_nonce_hash = ?2`,
          )
          .bind(input.grant_id, input.completion_nonce_hash),
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
      return {
        outcome: "issued",
        account_id: device.account_id,
        display_label: displayLabelRow(results[5]),
        device,
      };
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
    return { outcome: "not_completed" };
  }

  async consumeAccountLoginGrant(
    input: ConsumeAccountLoginGrantInput,
  ): Promise<AccountLoginGrantConsumeResult> {
    const scopes = encodeScopes(IOS_SESSION_SCOPES);
    let results: D1Result<unknown>[];
    try {
      results = await this.database.batch([
        this.database
          .prepare(
            `UPDATE login_grants
           SET consumed_at = ?4, consume_nonce_hash = ?3
           WHERE id = ?1 AND code_hash = ?2
             AND account_id IS NOT NULL AND completed_at IS NOT NULL
             AND consumed_at IS NULL AND expires_at > ?4
             AND client_id = ?5
           RETURNING account_id`,
          )
          .bind(
            input.grant_id,
            input.credential_hash,
            input.completion_nonce_hash,
            input.consumed_at,
            IOS_OAUTH_CLIENT_ID,
          ),
        this.database
          .prepare(
            `INSERT INTO sessions (
             id, family_id, account_id, device_id, device_generation, client_kind,
             access_token_hash, refresh_token_hash, scopes_json,
             authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
           )
           SELECT ?1, ?2, grants.account_id, NULL, NULL, 'ios', ?3, ?4, ?5, ?6, ?7, ?8, ?6, ?6
           FROM login_grants AS grants
           WHERE grants.id = ?9 AND grants.consume_nonce_hash = ?10
             AND grants.client_id = ?11`,
          )
          .bind(
            input.session.session_id,
            input.family_id,
            input.session.access_token_hash,
            input.session.refresh_token_hash,
            scopes,
            input.consumed_at,
            input.session.access_expires_at,
            input.session.refresh_expires_at,
            input.grant_id,
            input.completion_nonce_hash,
            IOS_OAUTH_CLIENT_ID,
          ),
        this.database
          .prepare(
            `SELECT accounts.display_label AS display_label
           FROM accounts
           INNER JOIN login_grants AS grants ON grants.account_id = accounts.id
           WHERE grants.id = ?1 AND grants.consume_nonce_hash = ?2`,
          )
          .bind(input.grant_id, input.completion_nonce_hash),
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
    const account = resultRow<{ account_id: string }>(results[0]);
    if (resultChanged(results[0]) && resultChanged(results[1]) && account) {
      return {
        outcome: "issued",
        account_id: account.account_id,
        display_label: displayLabelRow(results[2]),
      };
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
    return { outcome: "not_completed" };
  }

  /**
   * Sign one browser in: find or create the Account behind this GitHub subject, then open its
   * session.
   *
   * The session is its own family. Nothing rotates into or out of a browser session — the cookie is
   * the whole credential — so revoking the family revokes exactly this cookie and no other client.
   */
  async createWebSession(input: CreateWebSessionInput): Promise<AccountRecord> {
    const results = await this.database.batch([
      this.database
        .prepare(
          `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
           VALUES (?1, ?1, ?2, ?3, ?3)
           ON CONFLICT(id) DO UPDATE SET
             display_label = excluded.display_label,
             updated_at = excluded.updated_at
           RETURNING id, identity_subject, display_label, created_at, updated_at`,
        )
        .bind(input.account_id, input.display_label, input.authenticated_at),
      this.database
        .prepare(
          `INSERT INTO sessions (
             id, family_id, account_id, device_id, device_generation, client_kind,
             access_token_hash, refresh_token_hash, scopes_json,
             authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
           ) VALUES (?1, ?1, ?2, NULL, NULL, 'web', ?3, NULL, ?4, ?5, ?6, ?6, ?5, ?5)`,
        )
        .bind(
          input.session_id,
          input.account_id,
          input.access_token_hash,
          encodeScopes(WEB_SESSION_SCOPES),
          input.authenticated_at,
          input.expires_at,
        ),
    ]);
    const account = resultRow<AccountRecord>(results[0]);
    if (!account) {
      throw new Error("Web sign-in did not resolve an account");
    }
    return account;
  }

  /**
   * Whoever holds this Bearer token, if the session behind it is still allowed to act.
   *
   * One query answers for every client. A session that names a Device carries the generation that
   * Device had when the session opened, and the join insists the Device still exists, is signed
   * in, and is still at that generation — so Delete Device, which advances the generation, ends
   * every token issued before it without having to find them. A session that names no Device
   * skips that condition rather than being answered by a second table.
   */
  async authorizeSession(
    accessTokenHash: string,
    checkedAt: string,
    marksDeviceSeen: boolean,
  ): Promise<SessionPrincipal | null> {
    const row = await this.database
      .prepare(
        `SELECT sessions.id, sessions.family_id, sessions.account_id, sessions.device_id,
                sessions.device_generation, sessions.client_kind, sessions.scopes_json,
                sessions.authenticated_at
         FROM sessions
         LEFT JOIN devices ON devices.id = sessions.device_id
         WHERE sessions.access_token_hash = ?1 AND sessions.revoked_at IS NULL
           AND sessions.expires_at > ?2
           AND (
             sessions.device_id IS NULL
             OR (devices.generation = sessions.device_generation
                 AND devices.account_id = sessions.account_id
                 AND devices.signed_out_at IS NULL AND devices.deleted_at IS NULL)
           )`,
      )
      .bind(accessTokenHash, checkedAt)
      .first<SessionPrincipalRow>();
    if (!row) {
      return null;
    }
    const statements = [
      this.database
        .prepare("UPDATE sessions SET last_used_at = ?2 WHERE id = ?1 AND revoked_at IS NULL")
        .bind(row.id, checkedAt),
    ];
    // Only a device route moves this instant; see `authorizeSession` on `AccountState`.
    if (marksDeviceSeen && row.device_id !== null) {
      statements.push(
        this.database
          .prepare(
            `UPDATE devices SET last_seen_at = ?3
             WHERE id = ?1 AND generation = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
          )
          .bind(row.device_id, row.device_generation, checkedAt),
      );
    }
    await this.database.batch(statements);
    return sessionPrincipal(row);
  }

  /**
   * See `AccountState.refreshSession`. Rotation is not the Device speaking for itself; the
   * request that spends the new token is.
   */
  async refreshSession(input: RefreshSessionInput): Promise<SessionPrincipal | null> {
    const current = await this.database
      .prepare(
        `UPDATE sessions
         SET access_token_hash = ?2, refresh_token_hash = ?3, expires_at = ?4,
             refresh_expires_at = ?5, last_used_at = ?6, previous_refresh_token_hash = ?1,
             rotated_at = ?6
         WHERE refresh_token_hash = ?1 AND revoked_at IS NULL AND refresh_expires_at > ?6
           AND ${sessionDeviceIsCurrent}
         RETURNING ${sessionPrincipalReturning}`,
      )
      .bind(
        input.refresh_token_hash,
        input.new_access_token_hash,
        input.new_refresh_token_hash,
        input.access_expires_at,
        input.refresh_expires_at,
        input.refreshed_at,
      )
      .first<SessionPrincipalRow>();
    if (current) {
      return sessionPrincipal(current);
    }
    const replaced = await this.database
      .prepare(
        `UPDATE sessions
         SET access_token_hash = ?2, refresh_token_hash = ?3, expires_at = ?4,
             refresh_expires_at = ?5, last_used_at = ?6, rotated_at = ?6
         WHERE previous_refresh_token_hash = ?1 AND revoked_at IS NULL AND refresh_expires_at > ?6
           AND last_used_at = rotated_at AND ${sessionDeviceIsCurrent}
         RETURNING ${sessionPrincipalReturning}`,
      )
      .bind(
        input.refresh_token_hash,
        input.new_access_token_hash,
        input.new_refresh_token_hash,
        input.access_expires_at,
        input.refresh_expires_at,
        input.refreshed_at,
      )
      .first<SessionPrincipalRow>();
    return replaced ? sessionPrincipal(replaced) : null;
  }

  /**
   * End the session behind this refresh token, and the Device it spoke for.
   *
   * Revoking by family rather than by row is what makes a rotation race safe to revoke: the token
   * presented may already have been replaced, and its successor belongs to the same family.
   */
  async revokeRefreshSession(input: RevokeRefreshSessionInput): Promise<void> {
    const presentedRefresh = `(refresh_token_hash = ?1 OR (previous_refresh_token_hash = ?1 AND last_used_at = rotated_at))`;
    const family = `SELECT family_id FROM sessions WHERE ${presentedRefresh}`;
    await this.database.batch([
      this.database
        .prepare(
          `UPDATE devices SET signed_out_at = ?2
           WHERE id = (
             SELECT device_id FROM sessions
             WHERE ${presentedRefresh} AND revoked_at IS NULL
           )
             AND generation = (
               SELECT device_generation FROM sessions
               WHERE ${presentedRefresh} AND revoked_at IS NULL
             )
             AND signed_out_at IS NULL AND deleted_at IS NULL`,
        )
        .bind(input.refresh_token_hash, input.revoked_at),
      this.database
        .prepare(
          `UPDATE sessions SET revoked_at = COALESCE(revoked_at, ?2)
           WHERE family_id = (${family})`,
        )
        .bind(input.refresh_token_hash, input.revoked_at),
    ]);
  }

  async revokePrincipalFamily(
    principal: SessionPrincipal,
    revokedAt: string,
    signOutDevice: boolean,
  ): Promise<void> {
    const statements = [
      this.database
        .prepare("UPDATE sessions SET revoked_at = ?2 WHERE family_id = ?1 AND revoked_at IS NULL")
        .bind(principal.family_id, revokedAt),
    ];
    if (signOutDevice && principal.device_id) {
      statements.push(
        this.database
          .prepare("UPDATE devices SET signed_out_at = ?2 WHERE id = ?1 AND deleted_at IS NULL")
          .bind(principal.device_id, revokedAt),
      );
    }
    await this.database.batch(statements);
  }

  async getAccount(accountId: string): Promise<AccountRecord | null> {
    return this.database
      .prepare(
        `SELECT id, identity_subject, display_label, created_at, updated_at
         FROM accounts WHERE id = ?1`,
      )
      .bind(accountId)
      .first<AccountRecord>();
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

  async getDeviceSyncControl(
    deviceId: string,
    generation: number,
  ): Promise<DeviceSyncControl | null> {
    const row = await this.database
      .prepare(
        `SELECT id AS device_id, generation,
                deleted_before AS usage_deleted_before, usage_sync_revision
         FROM devices
         WHERE id = ?1 AND generation = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(deviceId, generation)
      .first<DeviceSyncControl>();
    return row ?? null;
  }

  async updateDeviceProfile(
    deviceId: string,
    generation: number,
    displayName: string,
    platform: string,
    updatedAt: string,
  ): Promise<boolean> {
    const result = await this.database
      .prepare(
        `UPDATE devices
         SET display_name = ?3, platform = ?4, last_seen_at = ?5
         WHERE id = ?1 AND generation = ?2
           AND signed_out_at IS NULL AND deleted_at IS NULL
         RETURNING id`,
      )
      .bind(deviceId, generation, displayName, platform, updatedAt)
      .first<{ id: string }>();
    return result?.id === deviceId;
  }

  /**
   * Aggregates over the tables an Account read projects. They are the whole basis for the
   * conditional answer, so each one has to move whenever the response would: counts catch
   * deletion and retention, the newest instant catches replacement, and the summed per-device
   * usage revision catches an upload from any device rather than only the leading one. The
   * Account's own `updated_at` is here because the response carries its display label, which a
   * later GitHub sign-in rewrites without touching a device or an observation.
   */
  async accountVersionStamp(accountId: string, activeSince: string): Promise<AccountVersionStamp> {
    const [devices, snapshots, account] = await this.database.batch<Record<string, unknown>>([
      this.database
        .prepare(
          `SELECT COUNT(*) AS devices,
                  COALESCE(SUM(usage_sync_revision), 0) AS usage_revision,
                  COALESCE(MAX(generation), 0) AS device_generation,
                  MAX(last_seen_at) AS device_last_seen_at,
                  MAX(last_login_at) AS device_last_login_at,
                  MAX(signed_out_at) AS device_signed_out_at,
                  COALESCE(SUM(
                    CASE WHEN signed_out_at IS NULL AND last_seen_at > ?2 THEN 1 ELSE 0 END
                  ), 0) AS active_devices
           FROM devices
           WHERE account_id = ?1 AND deleted_at IS NULL`,
        )
        .bind(accountId, activeSince),
      this.database
        .prepare(
          `SELECT COUNT(*) AS snapshots, MAX(snapshots.updated_at) AS snapshot_updated_at
           FROM quota_snapshots AS snapshots
           INNER JOIN devices ON devices.id = snapshots.device_id
           WHERE devices.account_id = ?1 AND devices.deleted_at IS NULL`,
        )
        .bind(accountId),
      this.database
        .prepare("SELECT updated_at AS account_updated_at FROM accounts WHERE id = ?1")
        .bind(accountId),
    ]);
    const merged = {
      ...(devices?.results[0] ?? {}),
      ...(snapshots?.results[0] ?? {}),
      ...(account?.results[0] ?? {}),
    };
    return {
      account_updated_at: stampInstant(merged.account_updated_at),
      devices: stampCount(merged.devices),
      active_devices: stampCount(merged.active_devices),
      usage_revision: stampCount(merged.usage_revision),
      device_generation: stampCount(merged.device_generation),
      device_last_seen_at: stampInstant(merged.device_last_seen_at),
      device_last_login_at: stampInstant(merged.device_last_login_at),
      device_signed_out_at: stampInstant(merged.device_signed_out_at),
      snapshots: stampCount(merged.snapshots),
      snapshot_updated_at: stampInstant(merged.snapshot_updated_at),
    };
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
           SET generation = generation + 1, usage_sync_revision = usage_sync_revision + 1,
               display_name = NULL, platform = NULL, last_seen_at = NULL,
               signed_out_at = ?3, deleted_at = ?3, deleted_before = ?3
           WHERE account_id = ?1 AND id = ?2 AND deleted_at IS NULL
           RETURNING id AS device_id, generation, deleted_before`,
        )
        .bind(accountId, deviceId, deletedAt),
      this.database
        .prepare(
          `UPDATE sessions SET revoked_at = ?3
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
          `DELETE FROM usage_hour_scans WHERE device_id = ?2 AND EXISTS (
             SELECT 1 FROM devices WHERE id = ?2 AND account_id = ?1
           )`,
        )
        .bind(accountId, deviceId),
      this.database
        .prepare(
          `DELETE FROM usage_daily WHERE device_id = ?2 AND EXISTS (
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

  /**
   * Delete an Account and everything Relay keeps for it, in one batch.
   *
   * Children go first so the batch holds whether or not this connection enforces foreign keys, and
   * the Account row is deleted last and reports whether there was one to delete. Nothing survives
   * as a tombstone: a deleted Account's next sign-in is a new Account, because the GitHub subject
   * behind it only ever named a row that is gone.
   */
  async deleteAccountData(accountId: string): Promise<boolean> {
    const ownedDevices = "SELECT id FROM devices WHERE account_id = ?1";
    const results = await this.database.batch([
      this.database
        .prepare(`DELETE FROM usage_daily WHERE device_id IN (${ownedDevices})`)
        .bind(accountId),
      this.database
        .prepare(`DELETE FROM usage_hourly WHERE device_id IN (${ownedDevices})`)
        .bind(accountId),
      this.database
        .prepare(`DELETE FROM usage_hour_scans WHERE device_id IN (${ownedDevices})`)
        .bind(accountId),
      this.database
        .prepare(`DELETE FROM quota_snapshots WHERE device_id IN (${ownedDevices})`)
        .bind(accountId),
      this.database.prepare("DELETE FROM sessions WHERE account_id = ?1").bind(accountId),
      this.database.prepare("DELETE FROM login_grants WHERE account_id = ?1").bind(accountId),
      this.database
        .prepare("DELETE FROM account_usage_folds WHERE account_id = ?1")
        .bind(accountId),
      this.database.prepare("DELETE FROM devices WHERE account_id = ?1").bind(accountId),
      this.database.prepare("DELETE FROM accounts WHERE id = ?1 RETURNING id").bind(accountId),
    ]);
    return resultRow<{ id: string }>(results[results.length - 1]) !== null;
  }

  /**
   * Store this device's readings and drop the fingerprints it no longer sees.
   *
   * A reading is placed by `(provider, fingerprint)` and ordered by the instant it was observed,
   * so a reading older than the stored one cannot overwrite it. A restatement at the same instant
   * is ignored unless it only changes status from `available` to a failure, which is how a device
   * republishes a collection failure without pretending the numbers are newer. The envelope states
   * the fingerprints this device currently sees for each provider it names, so a subscription it
   * has stopped observing stops speaking for it here rather than waiting out retention.
   */
  async recordSnapshot(
    principal: DeviceWriterPrincipal,
    envelope: QuotaSnapshotSubmission,
    receivedAt: string,
  ): Promise<SnapshotWriteResult> {
    const control = await this.database
      .prepare(
        `SELECT generation
         FROM devices
         WHERE id = ?1 AND account_id = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.account_id)
      .first<{ generation: number }>();
    if (
      !control ||
      control.generation !== principal.device_generation ||
      envelope.generation !== principal.device_generation
    ) {
      return { outcome: "stale_device" };
    }

    const stored = await this.database
      .prepare(
        `SELECT provider, account_fingerprint AS fingerprint, observed_at,
                json_extract(snapshot_json, '$.status') AS status
         FROM quota_snapshots WHERE device_id = ?1`,
      )
      .bind(principal.device_id)
      .all<{ provider: string; fingerprint: string } & StoredSnapshotCursor>();
    const observed = new Map(
      stored.results.map((row) => [
        `${row.provider}\u0000${row.fingerprint}`,
        { observed_at: row.observed_at, status: row.status },
      ]),
    );

    const accepted = new Set<ProviderId>();
    const ignored = new Set<ProviderId>();
    const statements: D1PreparedStatement[] = [];
    for (const snapshot of envelope.snapshots) {
      const key = `${snapshot.provider}\u0000${snapshot.account.fingerprint}`;
      const current = observed.get(key);
      if (!snapshotWriteIsAccepted(current, snapshot)) {
        ignored.add(snapshot.provider);
        continue;
      }
      accepted.add(snapshot.provider);
      observed.set(key, { observed_at: snapshot.observed_at, status: snapshot.status });
      statements.push(
        this.database
          .prepare(
            `INSERT INTO quota_snapshots (
               device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
             )
             SELECT ?1, ?2, ?3, ?4, ?5, ?6
             WHERE EXISTS (
               SELECT 1 FROM devices
               WHERE id = ?1 AND account_id = ?7 AND generation = ?8
                 AND signed_out_at IS NULL AND deleted_at IS NULL
             )
             ON CONFLICT(device_id, provider, account_fingerprint) DO UPDATE SET
               observed_at = excluded.observed_at,
               snapshot_json = excluded.snapshot_json,
               updated_at = excluded.updated_at
             WHERE excluded.observed_at > quota_snapshots.observed_at
                OR (
                  excluded.observed_at = quota_snapshots.observed_at
                  AND json_extract(quota_snapshots.snapshot_json, '$.status') = 'available'
                  AND json_extract(excluded.snapshot_json, '$.status') != 'available'
                )`,
          )
          .bind(
            principal.device_id,
            snapshot.provider,
            snapshot.account.fingerprint,
            snapshot.observed_at,
            JSON.stringify(snapshot),
            receivedAt,
            principal.account_id,
            principal.device_generation,
          ),
      );
    }
    for (const provider of new Set(envelope.snapshots.map((snapshot) => snapshot.provider))) {
      const fingerprints = envelope.snapshots
        .filter((snapshot) => snapshot.provider === provider)
        .map((snapshot) => snapshot.account.fingerprint);
      statements.push(
        this.database
          .prepare(
            `DELETE FROM quota_snapshots
             WHERE device_id = ?1 AND provider = ?2
               AND account_fingerprint NOT IN (SELECT value FROM json_each(?3))`,
          )
          .bind(principal.device_id, provider, JSON.stringify(fingerprints)),
      );
    }
    statements.push(
      this.database
        .prepare(
          `UPDATE devices SET last_seen_at = ?3
           WHERE id = ?1 AND account_id = ?4 AND generation = ?2
             AND signed_out_at IS NULL AND deleted_at IS NULL`,
        )
        .bind(principal.device_id, principal.device_generation, receivedAt, principal.account_id),
    );
    await this.database.batch(statements);
    return {
      outcome: "written",
      accepted: [...accepted].sort(),
      ignored: [...ignored].filter((provider) => !accepted.has(provider)).sort(),
    };
  }

  async listLatestSnapshots(accountId: string): Promise<StoredQuotaSnapshot[]> {
    const rows = await this.database
      .prepare(
        `SELECT snapshots.device_id, snapshots.snapshot_json
         FROM quota_snapshots AS snapshots
         INNER JOIN devices ON devices.id = snapshots.device_id
         WHERE devices.account_id = ?1 AND devices.deleted_at IS NULL
         ORDER BY snapshots.device_id ASC, snapshots.provider ASC,
                  snapshots.account_fingerprint ASC
         LIMIT 8193`,
      )
      .bind(accountId)
      .all<SnapshotRow>();
    // A stored reading this build cannot read is one reading, not the account. Dropping it
    // keeps every other subscription answerable while a device that still writes a retired
    // shape is replaced or its rows age out.
    return rows.results.flatMap((row) => {
      const snapshot = QuotaSnapshotSchema.safeParse(JSON.parse(row.snapshot_json));
      if (!snapshot.success) return [];
      return [{ device_id: row.device_id, snapshot: snapshot.data }];
    });
  }

  async consumeRateLimit(input: RateLimitInput): Promise<RateLimitResult> {
    validateRateLimitInput(input);
    const results = await this.database.batch<RateLimitRow>([
      // Bounded like every other cleanup: this runs inside the request being limited, and an
      // unbounded delete over a table one burst can fill makes a rate-limited caller slow for
      // everybody. Expired rows this run does not reach are collected by the next.
      this.database
        .prepare(
          `DELETE FROM rate_limit_counters WHERE rowid IN (
             SELECT rowid FROM rate_limit_counters WHERE window_expires_at <= ?1
             ORDER BY window_expires_at ASC, rowid ASC LIMIT ?2
           )`,
        )
        .bind(input.checked_at, rateLimitCleanupBatchLimit),
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

  private async getLoginGrantByIdAndCredential(
    id: string,
    hash: string,
  ): Promise<LoginGrantRecord | null> {
    return this.database
      .prepare(`${loginGrantSelect} WHERE id = ?1 AND code_hash = ?2`)
      .bind(id, hash)
      .first<LoginGrantRecord>();
  }
}

const loginGrantSelect = `SELECT id, client_id, account_id, pkce_challenge, redirect_uri,
  client_state, expires_at, completed_at, consumed_at FROM login_grants`;

const deviceSelect = `SELECT id, account_id, display_name, platform, generation,
  usage_sync_revision, created_at, last_login_at, last_seen_at,
  signed_out_at, deleted_at, deleted_before FROM devices`;

const sessionPrincipalReturning = `id, family_id, account_id, device_id, device_generation,
  client_kind, scopes_json, authenticated_at`;

const sessionDeviceIsCurrent = `(
  device_id IS NULL
  OR EXISTS (
    SELECT 1 FROM devices
    WHERE devices.id = sessions.device_id
      AND devices.account_id = sessions.account_id
      AND devices.generation = sessions.device_generation
      AND devices.signed_out_at IS NULL AND devices.deleted_at IS NULL
  )
)`;

function sessionPrincipal(row: SessionPrincipalRow): SessionPrincipal {
  return {
    session_id: row.id,
    family_id: row.family_id,
    account_id: row.account_id,
    device_id: row.device_id,
    device_generation: row.device_generation,
    client_kind: sessionClientKind(row.client_kind),
    scopes: decodeSessionScopes(row.scopes_json),
    authenticated_at: row.authenticated_at,
  };
}

function sessionClientKind(value: string): SessionClientKind {
  if (value !== "web" && value !== "quotabar" && value !== "ios") {
    throw new Error("Persisted session names an unknown client kind");
  }
  return value;
}

function resultChanged(result: D1Result<unknown> | undefined): boolean {
  return (result?.meta.changes ?? 0) === 1;
}

function resultRow<T>(result: D1Result<unknown> | undefined): T | null {
  return (result?.results[0] as T | undefined) ?? null;
}

function displayLabelRow(result: D1Result<unknown> | undefined): string | null {
  const label = resultRow<{ display_label: string | null }>(result)?.display_label;
  return typeof label === "string" && label.length > 0 ? label : null;
}

function stampCount(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : 0;
}

function stampInstant(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

const rateLimitCleanupBatchLimit = 100;
