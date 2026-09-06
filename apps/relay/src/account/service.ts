import { IOS_OAUTH_CLIENT_ID, IOS_OAUTH_REDIRECT_URI } from "@gotry-io/quota-protocol";
import type {
  AccountState,
  LoginGrantRecord,
  SessionCredentialHashes,
  SessionPrincipal,
} from "@gotry-io/relay-core";
import {
  constantTimeEqual,
  hmacSha256Hex,
  randomOpaqueSecret,
  type SecretHasher,
  sha256Base64Url,
} from "../security.ts";

const grantLifetimeMilliseconds = 10 * 60 * 1000;
const accessLifetimeMilliseconds = 15 * 60 * 1000;
const refreshLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;
export const nativeClientId = "quotabar";
export const iosClientId = IOS_OAUTH_CLIENT_ID;
export const iosRedirectUri = IOS_OAUTH_REDIRECT_URI;

/**
 * What each client's one token looks like, and the HMAC domain it is stored under.
 *
 * One session table does not mean one credential domain. A token is hashed under the domain its
 * prefix names, so a token issued to QuotaBar cannot be presented as the iOS viewer's, and
 * neither can be presented as the browser cookie, which has its own domain again
 * ([ADR 0025](../../../../docs/decisions/0025-one-session-system.md)). The prefix is what selects
 * the domain, so one lookup answers for every Bearer token.
 */
export const CLIENT_CREDENTIALS = {
  [nativeClientId]: {
    accessPrefix: "qb_",
    refreshPrefix: "qbr_",
    accessDomain: "quotabar-access",
    refreshDomain: "quotabar-refresh",
    refreshPattern: /^qbr_[A-Za-z0-9_-]{43}$/,
  },
  [iosClientId]: {
    accessPrefix: "qia_",
    refreshPrefix: "qiar_",
    accessDomain: "ios-access",
    refreshDomain: "ios-refresh",
    refreshPattern: /^qiar_[A-Za-z0-9_-]{43}$/,
  },
} as const;

type RegisteredClientId = keyof typeof CLIENT_CREDENTIALS;

/** The domain a Bearer access token is checked under, or null when no client issues that shape. */
export function accessTokenDomain(token: string): string | null {
  for (const credentials of Object.values(CLIENT_CREDENTIALS)) {
    if (new RegExp(`^${credentials.accessPrefix}[A-Za-z0-9_-]{43}$`).test(token)) {
      return credentials.accessDomain;
    }
  }
  return null;
}

/** The domain a refresh token is checked under, or null when no client issues that shape. */
export function refreshTokenDomain(token: string): string | null {
  for (const credentials of Object.values(CLIENT_CREDENTIALS)) {
    if (credentials.refreshPattern.test(token)) {
      return credentials.refreshDomain;
    }
  }
  return null;
}

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

export interface AuthorizationCodeExchangeInput {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_verifier: string;
  installation_id: string;
  device_display_name: string;
  platform: string;
}

export interface IosAuthorizationCodeExchangeInput {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_verifier: string;
}

export interface IssuedSession {
  access_token: string;
  refresh_token: string;
  access_expires_at: string;
  refresh_expires_at: string;
}

export interface NativeTokenResponse {
  token_type: "Bearer";
  account_id: string;
  display_label: string | null;
  device_id: string;
  device_generation: number;
  usage_deleted_before: string | null;
  usage_sync_revision: number;
  session: IssuedSession;
}

export interface AccountTokenResponse {
  token_type: "Bearer";
  account_id: string;
  display_label: string | null;
  session: IssuedSession;
}

export interface BrowserLoginCompletion {
  redirect_uri: string;
  client_state: string;
  code: string;
}

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
      !isRegisteredPublicClient(input.client_id, input.redirect_uri) ||
      input.code_challenge_method !== "S256" ||
      !isPKCEChallenge(input.code_challenge) ||
      !isOpaqueClientState(input.state)
    ) {
      throw new AccountFlowError("invalid_request");
    }
    const loginToken = randomOpaqueSecret("qlg_");
    await this.state.createLoginGrant({
      id: `grant_${crypto.randomUUID()}`,
      client_id: input.client_id,
      login_token_hash: await this.hasher.hash("login-token", loginToken),
      pkce_challenge: input.code_challenge,
      redirect_uri: input.redirect_uri,
      client_state: input.state,
      expires_at: expiresAt(now, grantLifetimeMilliseconds),
      created_at: now.toISOString(),
    });
    return { login_token: loginToken };
  }

  async completeBrowserLogin(
    loginToken: string,
    accountId: string,
    now: Date,
  ): Promise<BrowserLoginCompletion> {
    const tokenHash = await this.hasher.hash("login-token", loginToken);
    const grant = await this.state.getLoginGrantByLoginTokenHash(tokenHash, now.toISOString());
    if (
      !grant ||
      !grant.redirect_uri ||
      !grant.client_state ||
      !isRegisteredPublicClient(grant.client_id, grant.redirect_uri)
    ) {
      throw new AccountFlowError("invalid_state");
    }
    const authorizationCode = randomOpaqueSecret("qac_");
    const result = await this.state.completeIdentityLogin({
      grant_id: grant.id,
      login_token_hash: tokenHash,
      completion_nonce_hash: await this.hasher.hash("completion", randomOpaqueSecret()),
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

  async exchangeAuthorizationCode(
    input: AuthorizationCodeExchangeInput,
    now: Date,
  ): Promise<NativeTokenResponse> {
    if (input.client_id !== nativeClientId) {
      throw new AccountFlowError("invalid_client");
    }
    const { grant, codeHash } = await this.loadAuthorizationCodeGrant(input, now);
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

  async exchangeIosAuthorizationCode(
    input: IosAuthorizationCodeExchangeInput,
    now: Date,
  ): Promise<AccountTokenResponse> {
    if (input.client_id !== iosClientId) {
      throw new AccountFlowError("invalid_client");
    }
    const { grant, codeHash } = await this.loadAuthorizationCodeGrant(input, now);
    return this.consumeAccountOnlyGrant(grant, codeHash, now);
  }

  /**
   * Rotate one client's one token.
   *
   * The refresh token must carry the shape its own client issues, so a token cannot be rotated
   * into another client's credential domain. Rotation itself is one compare-and-swap in the
   * session table, whichever client asked.
   */
  async refresh(
    refreshToken: string,
    clientId: string,
    now: Date,
  ): Promise<IssuedSession & { principal: SessionPrincipal }> {
    const client = registeredClient(clientId);
    if (!client.refreshPattern.test(refreshToken)) {
      throw new AccountFlowError("invalid_grant");
    }
    const credentials = await this.newSessionCredentials(client, now);
    const principal = await this.state.refreshSession({
      refresh_token_hash: await this.hasher.hash(client.refreshDomain, refreshToken),
      new_access_token_hash: credentials.access_token_hash,
      new_refresh_token_hash: credentials.refresh_token_hash,
      access_expires_at: credentials.access_expires_at,
      refresh_expires_at: credentials.refresh_expires_at,
      refreshed_at: now.toISOString(),
    });
    if (!principal) {
      throw new AccountFlowError("invalid_grant");
    }
    return { ...issued(credentials), principal };
  }

  private async loadAuthorizationCodeGrant(
    input: {
      code: string;
      client_id: string;
      redirect_uri: string;
      code_verifier: string;
    },
    now: Date,
  ): Promise<{ grant: LoginGrantRecord; codeHash: string }> {
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
    return { grant, codeHash };
  }

  private async consumeNativeGrant(
    grant: LoginGrantRecord,
    credentialHash: string,
    installationHash: string,
    displayName: string,
    platform: string,
    now: Date,
  ): Promise<NativeTokenResponse> {
    const credentials = await this.newSessionCredentials(CLIENT_CREDENTIALS[nativeClientId], now);
    const result = await this.state.consumeLoginGrant({
      grant_id: grant.id,
      credential_hash: credentialHash,
      completion_nonce_hash: await this.hasher.hash("consume", randomOpaqueSecret()),
      installation_id_hash: installationHash,
      device_id: `device_${crypto.randomUUID()}`,
      display_name: displayName,
      platform,
      family_id: `family_${crypto.randomUUID()}`,
      session: hashes(credentials),
      consumed_at: now.toISOString(),
    });
    if (result.outcome !== "issued") {
      throw new AccountFlowError(result.outcome === "expired" ? "expired_token" : "invalid_grant");
    }
    return {
      token_type: "Bearer",
      account_id: result.account_id,
      display_label: result.display_label,
      device_id: result.device.id,
      device_generation: result.device.generation,
      usage_deleted_before: result.device.deleted_before,
      usage_sync_revision: result.device.usage_sync_revision,
      session: issued(credentials),
    };
  }

  private async consumeAccountOnlyGrant(
    grant: LoginGrantRecord,
    credentialHash: string,
    now: Date,
  ): Promise<AccountTokenResponse> {
    const credentials = await this.newSessionCredentials(CLIENT_CREDENTIALS[iosClientId], now);
    const result = await this.state.consumeAccountLoginGrant({
      grant_id: grant.id,
      credential_hash: credentialHash,
      completion_nonce_hash: await this.hasher.hash("consume", randomOpaqueSecret()),
      family_id: `family_${crypto.randomUUID()}`,
      session: hashes(credentials),
      consumed_at: now.toISOString(),
    });
    if (result.outcome !== "issued") {
      throw new AccountFlowError(result.outcome === "expired" ? "expired_token" : "invalid_grant");
    }
    return {
      token_type: "Bearer",
      account_id: result.account_id,
      display_label: result.display_label,
      session: issued(credentials),
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
    client: (typeof CLIENT_CREDENTIALS)[RegisteredClientId],
    now: Date,
  ): Promise<PlainSessionCredentials> {
    const accessToken = randomOpaqueSecret(client.accessPrefix);
    const refreshToken = randomOpaqueSecret(client.refreshPrefix);
    return {
      session_id: `session_${crypto.randomUUID()}`,
      access_token: accessToken,
      refresh_token: refreshToken,
      access_token_hash: await this.hasher.hash(client.accessDomain, accessToken),
      refresh_token_hash: await this.hasher.hash(client.refreshDomain, refreshToken),
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

export function isIosRedirect(value: string): boolean {
  return value === iosRedirectUri;
}

function registeredClient(clientId: string): (typeof CLIENT_CREDENTIALS)[RegisteredClientId] {
  const client = Object.hasOwn(CLIENT_CREDENTIALS, clientId)
    ? CLIENT_CREDENTIALS[clientId as RegisteredClientId]
    : undefined;
  if (!client) {
    throw new AccountFlowError("invalid_client");
  }
  return client;
}

export function isRegisteredPublicClient(clientId: string, redirectUri: string): boolean {
  if (clientId === nativeClientId) {
    return isLoopbackRedirect(redirectUri);
  }
  if (clientId === iosClientId) {
    return isIosRedirect(redirectUri);
  }
  return false;
}

function issued(credentials: PlainSessionCredentials): IssuedSession {
  return {
    access_token: credentials.access_token,
    refresh_token: credentials.refresh_token,
    access_expires_at: credentials.access_expires_at,
    refresh_expires_at: credentials.refresh_expires_at,
  };
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
    .replace(/[^\p{L}\p{N} ._()-]/gu, "")
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
