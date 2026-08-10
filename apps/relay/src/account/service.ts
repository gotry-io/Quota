import type {
  AccountPrincipal,
  AccountState,
  DeviceGrantDecisionOutcome,
  DevicePrincipal,
  LoginGrantRecord,
  SessionCredentialHashes,
} from "@gotry-io/relay-core";
import {
  constantTimeEqual,
  hmacSha256Hex,
  normalizeUserCode,
  randomOpaqueSecret,
  randomUserCode,
  SecretHasher,
  sha256Base64Url,
} from "../security.ts";

const grantLifetimeMilliseconds = 10 * 60 * 1000;
const accessLifetimeMilliseconds = 15 * 60 * 1000;
const refreshLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;
const devicePollIntervalSeconds = 5;
export const nativeClientId = "quotacli";

interface PlainSessionCredentials extends SessionCredentialHashes {
  access_token: string;
  refresh_token: string;
}

export interface BrowserAuthorizationInput {
  client_id: string;
  redirect_uri: string;
  state: string;
  code_challenge: string;
  code_challenge_method: string;
}

export interface DeviceAuthorizationInput {
  client_id: string;
  installation_id: string;
  device_display_name: string;
  platform: string;
}

export interface AuthorizationCodeExchangeInput {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_verifier: string;
  installation_id: string;
  device_display_name: string;
  platform: string;
}

export interface NativeTokenResponse {
  token_type: "Bearer";
  account_id: string;
  device_id: string;
  device_generation: number;
  next_snapshot_sequence: number;
  next_usage_sequence: number;
  usage_deleted_before: string | null;
  usage_sync_revision: number;
  account_access_token: string;
  account_refresh_token: string;
  account_access_expires_at: string;
  account_refresh_expires_at: string;
  device_access_token: string;
  device_refresh_token: string;
  device_access_expires_at: string;
  device_refresh_expires_at: string;
}

export interface BrowserLoginCompletion {
  redirect_uri: string;
  client_state: string;
  code: string;
}

export type DeviceTokenPoll =
  | { outcome: "issued"; response: NativeTokenResponse }
  | {
      outcome: "authorization_pending" | "slow_down" | "access_denied" | "expired_token";
      interval: number;
    };

export class AccountService {
  constructor(
    private readonly state: AccountState,
    private readonly hasher: SecretHasher,
    private readonly installationKey: string,
  ) {
    if (installationKey.length < 32) {
      throw new Error("Account hashing keys must contain at least 32 characters");
    }
  }

  async beginBrowserLogin(
    input: BrowserAuthorizationInput,
    now: Date,
  ): Promise<{ login_token: string }> {
    if (
      input.client_id !== nativeClientId ||
      input.code_challenge_method !== "S256" ||
      !isPKCEChallenge(input.code_challenge) ||
      !isLoopbackRedirect(input.redirect_uri) ||
      !isOpaqueClientState(input.state)
    ) {
      throw new AccountFlowError("invalid_request");
    }
    const loginToken = randomOpaqueSecret("qlg_");
    await this.state.createLoginGrant({
      id: `grant_${crypto.randomUUID()}`,
      grant_kind: "browser_pkce",
      client_id: input.client_id,
      login_token_hash: await this.hasher.hash("login-token", loginToken),
      device_code_hash: null,
      user_code_hash: null,
      installation_id_hash: null,
      device_display_name: null,
      platform: null,
      pkce_challenge: input.code_challenge,
      redirect_uri: input.redirect_uri,
      client_state: input.state,
      poll_interval_seconds: null,
      expires_at: expiresAt(now, grantLifetimeMilliseconds),
      created_at: now.toISOString(),
    });
    return { login_token: loginToken };
  }

  async beginDeviceLogin(input: DeviceAuthorizationInput, now: Date) {
    if (input.client_id !== nativeClientId) {
      throw new AccountFlowError("invalid_client");
    }
    const deviceCode = randomOpaqueSecret("qdc_");
    const userCode = randomUserCode();
    const expires = expiresAt(now, grantLifetimeMilliseconds);
    await this.state.createLoginGrant({
      id: `grant_${crypto.randomUUID()}`,
      grant_kind: "device_code",
      client_id: input.client_id,
      login_token_hash: null,
      device_code_hash: await this.hasher.hash("device-code", deviceCode),
      user_code_hash: await this.hasher.hash("user-code", normalizeUserCode(userCode)),
      installation_id_hash: await this.installationDigest(input.installation_id),
      device_display_name: sanitizeLabel(input.device_display_name, 128),
      platform: sanitizeLabel(input.platform, 64),
      pkce_challenge: null,
      redirect_uri: null,
      client_state: null,
      poll_interval_seconds: devicePollIntervalSeconds,
      expires_at: expires,
      created_at: now.toISOString(),
    });
    return {
      device_code: deviceCode,
      user_code: userCode,
      verification_uri: "https://quota.gotry.io/activate",
      verification_uri_complete: `https://quota.gotry.io/activate?user_code=${encodeURIComponent(userCode)}`,
      expires_at: expires,
      interval: devicePollIntervalSeconds,
    };
  }

  async completeBrowserLogin(
    loginToken: string,
    accountId: string,
    displayLabel: string,
    now: Date,
  ): Promise<BrowserLoginCompletion> {
    const tokenHash = await this.hasher.hash("login-token", loginToken);
    const grant = await this.state.getLoginGrantByLoginTokenHash(tokenHash, now.toISOString());
    if (
      !grant ||
      grant.grant_kind !== "browser_pkce" ||
      !grant.redirect_uri ||
      !grant.client_state
    ) {
      throw new AccountFlowError("invalid_state");
    }
    const authorizationCode = randomOpaqueSecret("qac_");
    const result = await this.state.completeIdentityLogin({
      grant_id: grant.id,
      login_token_hash: tokenHash,
      completion_nonce_hash: await this.hasher.hash("completion", randomOpaqueSecret()),
      display_label: sanitizeLabel(displayLabel, 64),
      account_id: accountId,
      completed_at: now.toISOString(),
      authorization_code_hash: await this.hasher.hash("authorization-code", authorizationCode),
    });
    if (result.outcome !== "completed") {
      throw new AccountFlowError(result.outcome === "expired" ? "expired_state" : "invalid_state");
    }
    return {
      redirect_uri: grant.redirect_uri,
      client_state: grant.client_state,
      code: authorizationCode,
    };
  }

  async decideDeviceGrant(
    userCode: string,
    accountId: string,
    decision: "approve" | "deny",
    now: Date,
  ): Promise<DeviceGrantDecisionOutcome> {
    return this.state.authorizeDeviceGrant({
      user_code_hash: await this.hasher.hash("user-code", normalizeUserCode(userCode)),
      account_id: accountId,
      decision,
      decided_at: now.toISOString(),
    });
  }

  async exchangeAuthorizationCode(
    input: AuthorizationCodeExchangeInput,
    now: Date,
  ): Promise<NativeTokenResponse> {
    const codeHash = await this.hasher.hash("authorization-code", input.code);
    const grant = await this.state.getLoginGrantByAuthorizationCodeHash(
      codeHash,
      now.toISOString(),
    );
    if (
      !grant ||
      grant.client_id !== input.client_id ||
      grant.redirect_uri !== input.redirect_uri ||
      !grant.pkce_challenge ||
      !isPKCEVerifier(input.code_verifier) ||
      !constantTimeEqual(await sha256Base64Url(input.code_verifier), grant.pkce_challenge)
    ) {
      throw new AccountFlowError("invalid_grant");
    }
    if (!grant.account_id) {
      throw new AccountFlowError("invalid_grant");
    }
    const installationHash = await this.accountInstallationHash(
      grant.account_id,
      await this.installationDigest(input.installation_id),
    );
    return this.consumeNativeGrant(
      grant,
      codeHash,
      installationHash,
      sanitizeLabel(input.device_display_name, 128),
      sanitizeLabel(input.platform, 64),
      now,
    );
  }

  async pollDeviceToken(deviceCode: string, clientId: string, now: Date): Promise<DeviceTokenPoll> {
    if (clientId !== nativeClientId) {
      throw new AccountFlowError("invalid_client");
    }
    const codeHash = await this.hasher.hash("device-code", deviceCode);
    const polled = await this.state.pollDeviceGrant(codeHash, now.toISOString());
    switch (polled.outcome) {
      case "pending":
        return { outcome: "authorization_pending", interval: polled.poll_interval_seconds };
      case "slow_down":
        return { outcome: "slow_down", interval: polled.poll_interval_seconds };
      case "denied":
        return { outcome: "access_denied", interval: polled.poll_interval_seconds };
      case "expired":
      case "consumed":
      case "not_found":
        return { outcome: "expired_token", interval: polled.poll_interval_seconds };
      case "ready": {
        const grant = polled.grant;
        if (!grant.account_id || !grant.installation_id_hash) {
          throw new AccountFlowError("invalid_grant");
        }
        const installationHash = await this.accountInstallationHash(
          grant.account_id,
          grant.installation_id_hash,
        );
        return {
          outcome: "issued",
          response: await this.consumeNativeGrant(
            grant,
            codeHash,
            installationHash,
            grant.device_display_name ?? "QuotaCLI",
            grant.platform ?? "unknown",
            now,
          ),
        };
      }
    }
  }

  async refresh(
    refreshToken: string,
    tokenClass: "account" | "device",
    now: Date,
  ): Promise<{
    access_token: string;
    refresh_token: string;
    access_expires_at: string;
    refresh_expires_at: string;
    principal: AccountPrincipal | DevicePrincipal;
  }> {
    const credentials = await this.newSessionCredentials(
      tokenClass === "account" ? "qa_" : "qd_",
      tokenClass === "account" ? "qar_" : "qdr_",
      now,
    );
    const input = {
      refresh_token_hash: await this.hasher.hash(`${tokenClass}-refresh`, refreshToken),
      new_access_token_hash: await this.hasher.hash(
        `${tokenClass}-access`,
        credentials.access_token,
      ),
      new_refresh_token_hash: await this.hasher.hash(
        `${tokenClass}-refresh`,
        credentials.refresh_token,
      ),
      access_expires_at: credentials.access_expires_at,
      refresh_expires_at: credentials.refresh_expires_at,
      refreshed_at: now.toISOString(),
    };
    const principal =
      tokenClass === "account"
        ? await this.state.refreshAccountSession(input)
        : await this.state.refreshDeviceSession(input);
    if (!principal) {
      throw new AccountFlowError("invalid_grant");
    }
    return { ...credentials, principal };
  }

  private async consumeNativeGrant(
    grant: LoginGrantRecord,
    credentialHash: string,
    installationHash: string,
    displayName: string,
    platform: string,
    now: Date,
  ): Promise<NativeTokenResponse> {
    const accountCredentials = await this.newSessionCredentials("qa_", "qar_", now);
    const deviceCredentials = await this.newSessionCredentials("qd_", "qdr_", now);
    const result = await this.state.consumeLoginGrant({
      grant_id: grant.id,
      credential_hash: credentialHash,
      completion_nonce_hash: await this.hasher.hash("consume", randomOpaqueSecret()),
      installation_id_hash: installationHash,
      device_id: `device_${crypto.randomUUID()}`,
      display_name: displayName,
      platform,
      family_id: `family_${crypto.randomUUID()}`,
      account_session: hashes(accountCredentials),
      device_session: hashes(deviceCredentials),
      consumed_at: now.toISOString(),
    });
    if (result.outcome !== "issued") {
      throw new AccountFlowError(result.outcome === "expired" ? "expired_token" : "invalid_grant");
    }
    return {
      token_type: "Bearer",
      account_id: result.account_id,
      device_id: result.device.id,
      device_generation: result.device.generation,
      next_snapshot_sequence: result.device.last_sequence + 1,
      next_usage_sequence: result.device.last_usage_sequence + 1,
      usage_deleted_before: result.device.deleted_before,
      usage_sync_revision: result.device.usage_sync_revision,
      account_access_token: accountCredentials.access_token,
      account_refresh_token: accountCredentials.refresh_token,
      account_access_expires_at: accountCredentials.access_expires_at,
      account_refresh_expires_at: accountCredentials.refresh_expires_at,
      device_access_token: deviceCredentials.access_token,
      device_refresh_token: deviceCredentials.refresh_token,
      device_access_expires_at: deviceCredentials.access_expires_at,
      device_refresh_expires_at: deviceCredentials.refresh_expires_at,
    };
  }

  private installationDigest(installationId: string): Promise<string> {
    return hmacSha256Hex(this.installationKey, `installation:${installationId}`);
  }

  private accountInstallationHash(accountId: string, installationDigest: string): Promise<string> {
    return hmacSha256Hex(
      this.installationKey,
      `account:${accountId}:installation-digest:${installationDigest}`,
    );
  }

  private async newSessionCredentials(
    accessPrefix: string,
    refreshPrefix: string,
    now: Date,
  ): Promise<PlainSessionCredentials> {
    const accessToken = randomOpaqueSecret(accessPrefix);
    const refreshToken = randomOpaqueSecret(refreshPrefix);
    const tokenClass = accessPrefix === "qa_" ? "account" : "device";
    return {
      session_id: `session_${crypto.randomUUID()}`,
      access_token: accessToken,
      refresh_token: refreshToken,
      access_token_hash: await this.hasher.hash(`${tokenClass}-access`, accessToken),
      refresh_token_hash: await this.hasher.hash(`${tokenClass}-refresh`, refreshToken),
      access_expires_at: expiresAt(now, accessLifetimeMilliseconds),
      refresh_expires_at: expiresAt(now, refreshLifetimeMilliseconds),
    };
  }
}

export class AccountFlowError extends Error {
  constructor(readonly code: string) {
    super("The account request could not be completed");
    this.name = "AccountFlowError";
  }
}

export function isLoopbackRedirect(value: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.protocol === "http:" &&
      (url.hostname === "127.0.0.1" || url.hostname === "[::1]" || url.hostname === "::1") &&
      url.port !== "" &&
      url.username === "" &&
      url.password === "" &&
      url.search === "" &&
      url.hash === ""
    );
  } catch {
    return false;
  }
}

function hashes(credentials: PlainSessionCredentials): SessionCredentialHashes {
  return {
    session_id: credentials.session_id,
    access_token_hash: credentials.access_token_hash,
    refresh_token_hash: credentials.refresh_token_hash,
    access_expires_at: credentials.access_expires_at,
    refresh_expires_at: credentials.refresh_expires_at,
  };
}

function expiresAt(now: Date, milliseconds: number): string {
  return new Date(now.getTime() + milliseconds).toISOString();
}

function sanitizeLabel(value: string, maximumLength: number): string {
  const sanitized = value
    .trim()
    .replace(/[^\p{L}\p{N} ._()\-]/gu, "")
    .slice(0, maximumLength);
  if (!sanitized) {
    throw new AccountFlowError("invalid_request");
  }
  return sanitized;
}

function isPKCEChallenge(value: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/.test(value);
}

function isPKCEVerifier(value: string): boolean {
  return /^[A-Za-z0-9._~-]{43,128}$/.test(value);
}

function isOpaqueClientState(value: string): boolean {
  return /^[A-Za-z0-9._~-]{16,256}$/.test(value);
}
