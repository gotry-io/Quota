import type { AccountPrincipal, AccountState } from "@gotry-io/relay-core";
import { CANONICAL_ORIGIN } from "../config.ts";
import {
  constantTimeEqual,
  decodeBase64UrlJSON,
  encodeBase64UrlJSON,
  hmacSha256Hex,
  randomOpaqueSecret,
  type SecretHasher,
  sha256Base64Url,
} from "../security.ts";

/**
 * The browser's whole credential. It is opaque, HttpOnly, and stored only as an HMAC.
 *
 * Both cookies carry the `__Host-` prefix, which a browser honours only when the cookie is
 * `Secure`, `Path=/`, and carries no `Domain`. That last part is the point: without it, anything
 * able to write a cookie for a sibling `*.gotry.io` host could plant one of these on this origin,
 * which is how a signed handoff cookie still ends in a login-CSRF. The prefix costs a wider path
 * on the handoff cookie, which is worth it.
 */
export const SESSION_COOKIE = "__Host-quota_session";
/** What one sign-in in flight needs to remember. Nothing outside the GitHub round trip reads it. */
export const HANDOFF_COOKIE = "__Host-quota_oauth";
/** Where the browser lands after GitHub, when the caller named nowhere safe. */
export const DEFAULT_RETURN_PATH = "/my";
const handoffSeconds = 10 * 60;
const webSessionSeconds = 90 * 24 * 60 * 60;
const githubAuthorizeUrl = "https://github.com/login/oauth/authorize";
const githubTokenUrl = "https://github.com/login/oauth/access_token";
const githubUserUrl = "https://api.github.com/user";
const githubTimeoutMilliseconds = 20_000;
const maximumProfileBytes = 64 * 1024;
const maximumAuthorizationCodeLength = 1_024;
const maximumReturnPathLength = 512;
const sessionTokenPattern = /^qw_[A-Za-z0-9_-]{43}$/;
const authorizationCodePattern = /^[A-Za-z0-9._~-]+$/;

export interface WebSignInStart {
  /** The GitHub authorize URL to send the browser to. */
  location: string;
  /** The `Set-Cookie` that carries the state and verifier this sign-in will be checked against. */
  handoff: string;
}

export interface WebCallbackRequest {
  cookie: string | null;
  state: string | null;
  code: string | null;
}

export type WebSignInResult =
  | { outcome: "signed_in"; session: string; handoff: string; return_to: string }
  /** Nothing about this callback proves it belongs to a sign-in this browser started. */
  | { outcome: "rejected" };

export interface WebSessionPort {
  beginSignIn(returnTo: string, now: Date): Promise<WebSignInStart>;
  completeSignIn(request: WebCallbackRequest, now: Date): Promise<WebSignInResult>;
  authorize(headers: Headers, checkedAt: Date): Promise<AccountPrincipal | null>;
}

export interface WebSessionEnvironment {
  state: Pick<AccountState, "createWebSession" | "authorizeAccountSession">;
  hasher: SecretHasher;
  githubClientId: string;
  githubClientSecret: string;
  githubSubjectKey: string;
  origin?: string;
  fetch?: typeof fetch;
}

interface HandoffPayload {
  state: string;
  verifier: string;
  return_to: string;
  expires_at: string;
}

/**
 * Quota's browser sessions, and the GitHub OAuth round trip that opens them.
 *
 * Relay is the confidential client. A sign-in generates a 256-bit `state` and a PKCE verifier,
 * keeps both in a signed, short-lived, HttpOnly cookie rather than in a table, and checks the
 * callback against that cookie before spending the authorization code. What comes back from GitHub
 * is read once for a numeric id and a login name; the access token is used for that one request and
 * never stored. The session it opens is an ordinary `account_sessions` row — the same table the
 * native clients use, so there is one place a session can be revoked, expired, or swept.
 */
export class GitHubWebSessions implements WebSessionPort {
  readonly #origin: string;
  readonly #fetch: typeof fetch;

  constructor(private readonly environment: WebSessionEnvironment) {
    this.#origin = environment.origin ?? CANONICAL_ORIGIN;
    this.#fetch = environment.fetch ?? fetch;
  }

  async beginSignIn(returnTo: string, now: Date): Promise<WebSignInStart> {
    const state = randomOpaqueSecret();
    const verifier = randomOpaqueSecret();
    const url = new URL(githubAuthorizeUrl);
    url.searchParams.set("client_id", this.environment.githubClientId);
    url.searchParams.set("redirect_uri", this.#callbackUrl());
    url.searchParams.set("state", state);
    // No scope at all: Quota reads the public profile every GitHub token can already read, and
    // asks for nothing it would have to be trusted with.
    url.searchParams.set("scope", "");
    url.searchParams.set("code_challenge", await sha256Base64Url(verifier));
    url.searchParams.set("code_challenge_method", "S256");
    const handoff = await this.#sealHandoff({
      state,
      verifier,
      return_to: returnTo,
      expires_at: new Date(now.getTime() + handoffSeconds * 1000).toISOString(),
    });
    return { location: url.toString(), handoff };
  }

  async completeSignIn(request: WebCallbackRequest, now: Date): Promise<WebSignInResult> {
    const handoff = await this.#openHandoff(readCookie(request.cookie, HANDOFF_COOKIE), now);
    if (
      !handoff ||
      !request.state ||
      !constantTimeEqual(request.state, handoff.state) ||
      !request.code ||
      request.code.length > maximumAuthorizationCodeLength ||
      !authorizationCodePattern.test(request.code)
    ) {
      return { outcome: "rejected" };
    }
    const accessToken = await this.#exchangeCode(request.code, handoff.verifier);
    if (!accessToken) {
      return { outcome: "rejected" };
    }
    const profile = await this.#readGitHubProfile(accessToken);
    if (!profile) {
      return { outcome: "rejected" };
    }
    const token = randomOpaqueSecret("qw_");
    await this.environment.state.createWebSession({
      session_id: `session_${crypto.randomUUID()}`,
      account_id: await hmacSha256Hex(this.environment.githubSubjectKey, `github:${profile.id}`),
      display_label: profile.label,
      access_token_hash: await this.#sessionTokenHash(token),
      authenticated_at: now.toISOString(),
      expires_at: new Date(now.getTime() + webSessionSeconds * 1000).toISOString(),
    });
    return {
      outcome: "signed_in",
      session: sessionCookie(token),
      handoff: clearedHandoffCookie(),
      return_to: handoff.return_to,
    };
  }

  async authorize(headers: Headers, checkedAt: Date): Promise<AccountPrincipal | null> {
    const token = readCookie(headers.get("Cookie"), SESSION_COOKIE);
    // Shape first: a document request carrying no plausible session must not reach D1 at all.
    if (!token || !sessionTokenPattern.test(token)) {
      return null;
    }
    const principal = await this.environment.state.authorizeAccountSession(
      await this.#sessionTokenHash(token),
      checkedAt.toISOString(),
    );
    return principal?.client_kind === "web" ? principal : null;
  }

  #callbackUrl(): string {
    return `${this.#origin}/api/auth/github/callback`;
  }

  /**
   * The session token is hashed under its own label, so a cookie cannot be replayed as a Bearer
   * token and a native access token cannot be replayed as a cookie.
   */
  #sessionTokenHash(token: string): Promise<string> {
    return this.environment.hasher.hash("web-access", token);
  }

  async #sealHandoff(payload: HandoffPayload): Promise<string> {
    const encoded = encodeBase64UrlJSON(payload);
    const signature = await this.environment.hasher.hash("oauth-handoff", encoded);
    return handoffCookie(`${encoded}.${signature}`);
  }

  async #openHandoff(value: string | null, now: Date): Promise<HandoffPayload | null> {
    if (!value) return null;
    const separator = value.lastIndexOf(".");
    if (separator < 1) return null;
    const encoded = value.slice(0, separator);
    const expected = await this.environment.hasher.hash("oauth-handoff", encoded);
    if (!constantTimeEqual(value.slice(separator + 1), expected)) return null;
    let payload: unknown;
    try {
      payload = decodeBase64UrlJSON(encoded);
    } catch {
      return null;
    }
    if (payload === null || typeof payload !== "object") return null;
    const candidate = payload as Record<string, unknown>;
    // An unreadable instant is not an unexpired one: `Date.parse` answers NaN, and every
    // comparison against NaN is false, so the deadline has to be proven rather than assumed.
    const expiresAt =
      typeof candidate.expires_at === "string" ? Date.parse(candidate.expires_at) : Number.NaN;
    if (
      typeof candidate.state !== "string" ||
      typeof candidate.verifier !== "string" ||
      typeof candidate.return_to !== "string" ||
      typeof candidate.expires_at !== "string" ||
      !Number.isFinite(expiresAt) ||
      expiresAt <= now.getTime()
    ) {
      return null;
    }
    return {
      state: candidate.state,
      verifier: candidate.verifier,
      return_to: candidate.return_to,
      expires_at: candidate.expires_at,
    };
  }

  /**
   * Spend the authorization code once. GitHub answers a replayed or mismatched code with an
   * `error` body rather than a failing status, so both are read the same way and both mean no.
   */
  async #exchangeCode(code: string, verifier: string): Promise<string | null> {
    const response = await this.#fetch(githubTokenUrl, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "QuotaRelay",
      },
      body: new URLSearchParams({
        client_id: this.environment.githubClientId,
        client_secret: this.environment.githubClientSecret,
        code,
        redirect_uri: this.#callbackUrl(),
        code_verifier: verifier,
      }).toString(),
      signal: AbortSignal.timeout(githubTimeoutMilliseconds),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = await readBoundedJSON(response);
    return typeof body.access_token === "string" && body.access_token ? body.access_token : null;
  }

  async #readGitHubProfile(accessToken: string): Promise<{ id: number; label: string } | null> {
    const response = await this.#fetch(githubUserUrl, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${accessToken}`,
        "User-Agent": "QuotaRelay",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      signal: AbortSignal.timeout(githubTimeoutMilliseconds),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const profile = await readBoundedJSON(response);
    if (typeof profile.id !== "number" || !Number.isSafeInteger(profile.id)) return null;
    const login = typeof profile.login === "string" ? profile.login.trim().slice(0, 64) : "";
    return { id: profile.id, label: login || "GitHub account" };
  }
}

/**
 * One session read per request, shared by the document render and the Account read it streams.
 *
 * Both run inside the same Worker invocation against the same cookie, and the second would
 * otherwise repeat the first's D1 round trip.
 */
export function memoizeWebSessionAuthorization(inner: WebSessionPort): WebSessionPort {
  let principal: Promise<AccountPrincipal | null> | undefined;
  return {
    beginSignIn: (returnTo, now) => inner.beginSignIn(returnTo, now),
    completeSignIn: (request, now) => inner.completeSignIn(request, now),
    authorize(headers, checkedAt) {
      principal ??= inner.authorize(headers, checkedAt);
      return principal;
    },
  };
}

/**
 * The same-origin path a sign-in may return to, or null when the caller named anything else.
 *
 * A redirect target that survives a round trip through GitHub is exactly the shape an open
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

export function clearedHandoffCookie(): string {
  return `${HANDOFF_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

function sessionCookie(token: string): string {
  return `${SESSION_COOKIE}=${token}; Path=/; Max-Age=${webSessionSeconds}; HttpOnly; Secure; SameSite=Lax`;
}

function handoffCookie(value: string): string {
  return `${HANDOFF_COOKIE}=${value}; Path=/; Max-Age=${handoffSeconds}; HttpOnly; Secure; SameSite=Lax`;
}

function readCookie(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const pair of header.split(";")) {
    const separator = pair.indexOf("=");
    if (separator < 0) continue;
    if (pair.slice(0, separator).trim() === name) {
      return pair.slice(separator + 1).trim();
    }
  }
  return null;
}

async function readBoundedJSON(response: Response): Promise<Record<string, unknown>> {
  const reader = response.body?.getReader();
  if (!reader) return {};
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumProfileBytes) {
      await reader.cancel();
      return {};
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return {};
  }
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : {};
}
