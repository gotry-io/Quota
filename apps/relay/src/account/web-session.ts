import type { AccountState, IdentityProviderId, SessionPrincipal } from "@gotry-io/relay-core";
import { CANONICAL_ORIGIN } from "../config.ts";
import { hmacSha256Hex, randomOpaqueSecret, type SecretHasher } from "../security.ts";
import {
  clearedHandoffCookie,
  HANDOFF_COOKIE,
  type IdentityBegin,
  type IdentityProof,
  type IdentityProvider,
  type IdentityRefusalReason,
  isIdentityRefusal,
  readCookie,
  type SignInHandoff,
  type SignInIntent,
} from "./identity.ts";

/**
 * The browser's whole credential. It is opaque, HttpOnly, and stored only as an HMAC.
 *
 * Both this and the handoff cookie carry the `__Host-` prefix, which a browser honours only when
 * the cookie is `Secure`, `Path=/`, and carries no `Domain`. That last part is the point: without
 * it, anything able to write a cookie for a sibling `*.gotry.io` host could plant one of these on
 * this origin.
 */
export const SESSION_COOKIE = "__Host-quota_session";
/** Where the browser lands after a provider, when the caller named nowhere safe. */
export const DEFAULT_RETURN_PATH = "/my";
const webSessionSeconds = 90 * 24 * 60 * 60;
const maximumReturnPathLength = 512;
const sessionTokenPattern = /^qw_[A-Za-z0-9_-]{43}$/;

export interface WebCallbackRequest {
  headers: Headers;
  query: URLSearchParams;
}

export type WebSignInResult =
  | { outcome: "signed_in"; session: string; handoff: string; return_to: string }
  /** A channel was bound to the Account that asked for it. The browser keeps the session it had. */
  | { outcome: "linked"; handoff: string; return_to: string }
  /** Nothing about this callback proves it belongs to a sign-in this browser started. */
  | { outcome: "rejected"; reason: WebSignInRejection };

/** Why a callback was refused — a category for the log line, never a secret or a value. */
export type WebSignInRejection =
  | IdentityRefusalReason
  | "handoff"
  /** The channel is already how another Account is reached, so binding it would take it away. */
  | "identity_taken"
  /** A link came back to a browser that is no longer signed in as the Account that started it. */
  | "link_session";

/** What a route needs to know about a provider before it dispatches to one. */
export interface RegisteredIdentityProvider {
  id: IdentityProviderId;
  callbackQueryKeys: readonly string[];
}

export interface WebSessionPort {
  /** The provider registered under this id, or null when Relay speaks no such channel. */
  identityProvider(id: string): RegisteredIdentityProvider | null;
  beginSignIn(
    provider: IdentityProviderId,
    intent: SignInIntent,
    returnTo: string,
    now: Date,
  ): Promise<IdentityBegin>;
  completeSignIn(
    provider: IdentityProviderId,
    request: WebCallbackRequest,
    now: Date,
  ): Promise<WebSignInResult>;
  /**
   * Apply a proved identity the way a provider callback does, without a handoff cookie.
   *
   * Email verify uses this: the mailed token is the credential, so the browser that opens it
   * may not be the one that asked, and there is no cookie to open.
   */
  completeProvedIdentity(
    provider: IdentityProviderId,
    proof: IdentityProof,
    intent: SignInIntent,
    returnTo: string,
    headers: Headers,
    now: Date,
  ): Promise<WebSignInResult>;
  authorize(headers: Headers, checkedAt: Date): Promise<SessionPrincipal | null>;
}

export interface WebSessionEnvironment {
  state: Pick<
    AccountState,
    "createWebSession" | "authorizeSession" | "resolveSignInIdentity" | "linkIdentity"
  >;
  hasher: SecretHasher;
  handoff: SignInHandoff;
  /** The HMAC key every provider's subject is stored under. */
  identitySubjectKey: string;
  providers: readonly IdentityProvider[];
}

/**
 * Quota's browser sessions, and what a proved identity means for one.
 *
 * Nothing here knows GitHub. A provider proves a subject and a label; this decides which Account
 * that reaches — the one already bound to it, a new one, or the signed-in one a link names — and
 * writes the session. The session it opens is an ordinary `sessions` row, the same table QuotaBar
 * and the iOS viewer use, so there is one place a session can be revoked, expired, or swept
 * ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 */
export class WebSessions implements WebSessionPort {
  readonly #providers: Map<string, IdentityProvider>;

  constructor(private readonly environment: WebSessionEnvironment) {
    this.#providers = new Map(environment.providers.map((provider) => [provider.id, provider]));
  }

  identityProvider(id: string): RegisteredIdentityProvider | null {
    const provider = this.#providers.get(id);
    return provider ? { id: provider.id, callbackQueryKeys: provider.callbackQueryKeys } : null;
  }

  beginSignIn(
    provider: IdentityProviderId,
    intent: SignInIntent,
    returnTo: string,
    now: Date,
  ): Promise<IdentityBegin> {
    return this.#require(provider).begin(intent, returnTo, now);
  }

  async completeSignIn(
    provider: IdentityProviderId,
    request: WebCallbackRequest,
    now: Date,
  ): Promise<WebSignInResult> {
    const handoff = await this.environment.handoff.open(
      readCookie(request.headers.get("Cookie"), HANDOFF_COOKIE),
      now,
    );
    // The cookie states which provider this browser left for. A callback delivered to another
    // provider's route is not the round trip that cookie was sealed for.
    if (!handoff || handoff.provider !== provider) {
      return { outcome: "rejected", reason: "handoff" };
    }
    const proved = await this.#require(provider).complete(
      { query: request.query, challenge: { state: handoff.state, verifier: handoff.verifier } },
      now,
    );
    if (isIdentityRefusal(proved)) {
      return { outcome: "rejected", reason: proved.rejected };
    }
    return this.completeProvedIdentity(
      provider,
      proved,
      handoff.intent,
      handoff.return_to,
      request.headers,
      now,
    );
  }

  async completeProvedIdentity(
    provider: IdentityProviderId,
    proof: IdentityProof,
    intent: SignInIntent,
    returnTo: string,
    headers: Headers,
    now: Date,
  ): Promise<WebSignInResult> {
    const subject = await hmacSha256Hex(
      this.environment.identitySubjectKey,
      `${provider}:${proof.subject_raw}`,
    );
    if (intent.kind === "link") {
      // The intent is sealed, but the session behind it may have ended while the browser was
      // away, and a link writes to the Account that session names.
      const principal = await this.authorize(headers, now);
      if (!principal || principal.account_id !== intent.account_id) {
        return { outcome: "rejected", reason: "link_session" };
      }
      const outcome = await this.environment.state.linkIdentity({
        account_id: principal.account_id,
        provider,
        subject,
        label: proof.label,
        now: now.toISOString(),
      });
      if (outcome === "identity_taken") {
        return { outcome: "rejected", reason: "identity_taken" };
      }
      return {
        outcome: "linked",
        handoff: clearedHandoffCookie(),
        return_to: returnTo,
      };
    }
    const account = await this.environment.state.resolveSignInIdentity({
      provider,
      subject,
      label: proof.label,
      new_account_id: `account_${crypto.randomUUID()}`,
      now: now.toISOString(),
    });
    const token = randomOpaqueSecret("qw_");
    await this.environment.state.createWebSession({
      session_id: `session_${crypto.randomUUID()}`,
      account_id: account.id,
      access_token_hash: await this.#sessionTokenHash(token),
      authenticated_at: now.toISOString(),
      expires_at: new Date(now.getTime() + webSessionSeconds * 1000).toISOString(),
    });
    return {
      outcome: "signed_in",
      session: sessionCookie(token),
      handoff: clearedHandoffCookie(),
      return_to: returnTo,
    };
  }

  async authorize(headers: Headers, checkedAt: Date): Promise<SessionPrincipal | null> {
    const token = readCookie(headers.get("Cookie"), SESSION_COOKIE);
    // Shape first: a document request carrying no plausible session must not reach D1 at all.
    if (!token || !sessionTokenPattern.test(token)) {
      return null;
    }
    const principal = await this.environment.state.authorizeSession(
      await this.#sessionTokenHash(token),
      checkedAt.toISOString(),
      false,
    );
    return principal?.client_kind === "web" ? principal : null;
  }

  #require(id: IdentityProviderId): IdentityProvider {
    const provider = this.#providers.get(id);
    if (!provider) throw new Error("No identity provider is registered under that id");
    return provider;
  }

  /**
   * The session token is hashed under its own label, so a cookie cannot be replayed as a Bearer
   * token and a native access token cannot be replayed as a cookie.
   */
  #sessionTokenHash(token: string): Promise<string> {
    return this.environment.hasher.hash("web-access", token);
  }
}

/**
 * One session read per request, shared by the document render and the Account read it streams.
 *
 * Both run inside the same Worker invocation against the same cookie, and the second would
 * otherwise repeat the first's D1 round trip.
 */
export function memoizeWebSessionAuthorization(inner: WebSessionPort): WebSessionPort {
  let principal: Promise<SessionPrincipal | null> | undefined;
  return {
    identityProvider: (id) => inner.identityProvider(id),
    beginSignIn: (provider, intent, returnTo, now) =>
      inner.beginSignIn(provider, intent, returnTo, now),
    completeSignIn: (provider, request, now) => inner.completeSignIn(provider, request, now),
    completeProvedIdentity: (provider, proof, intent, returnTo, headers, now) =>
      inner.completeProvedIdentity(provider, proof, intent, returnTo, headers, now),
    authorize(headers, checkedAt) {
      principal ??= inner.authorize(headers, checkedAt);
      return principal;
    },
  };
}

/**
 * The same-origin path a sign-in may return to, or null when the caller named anything else.
 *
 * A redirect target that survives a round trip through a provider is exactly the shape an open
 * redirect takes, so only an absolute path on this origin is accepted — never a host, a scheme, or
 * a protocol-relative `//elsewhere`.
 */
export function safeReturnPath(value: string, origin = CANONICAL_ORIGIN): string | null {
  if (
    value.length > maximumReturnPathLength ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    /[\\\s]/.test(value)
  ) {
    return null;
  }
  try {
    const url = new URL(value, origin);
    return url.origin === origin ? `${url.pathname}${url.search}` : null;
  } catch {
    return null;
  }
}

export function clearedSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

function sessionCookie(token: string): string {
  return `${SESSION_COOKIE}=${token}; Path=/; Max-Age=${webSessionSeconds}; HttpOnly; Secure; SameSite=Lax`;
}
