import { IDENTITY_PROVIDERS } from "@gotry-io/quota-protocol";
import type { IdentityProviderId } from "@gotry-io/relay-core";
import {
  constantTimeEqual,
  decodeBase64UrlJSON,
  encodeBase64UrlJSON,
  type SecretHasher,
} from "../security.ts";

/** What one sign-in in flight needs to remember. Nothing outside the round trip reads it. */
export const HANDOFF_COOKIE = "__Host-quota_oauth";
const handoffSeconds = 10 * 60;

/**
 * Why this browser left for a provider.
 *
 * A sign-in asks who this is; a link asks a signed-in Account to take another channel. The
 * difference decides what the callback writes, so it travels in the sealed cookie rather than in
 * a query parameter the browser could rewrite ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 */
export type SignInIntent = { kind: "sign_in" } | { kind: "link"; account_id: string };

export interface HandoffPayload {
  provider: IdentityProviderId;
  intent: SignInIntent;
  return_to: string;
  /** The 256-bit value the callback must come back carrying. */
  state: string;
  /** The PKCE verifier the code exchange is bound to. */
  verifier: string;
  expires_at: string;
}

/** What the sealed cookie proves about the callback now arriving. */
export interface HandoffChallenge {
  state: string;
  verifier: string;
}

export interface IdentityBegin {
  /** Where to send the browser. */
  location: string;
  /** The `Set-Cookie` that carries what this sign-in will be checked against. */
  handoff: string;
}

/** One callback, as the provider that started it reads it. */
export interface IdentityCallback {
  query: URLSearchParams;
  challenge: HandoffChallenge;
}

/** Who the provider proved this browser is: the subject as it stated it, and what it calls them. */
export interface IdentityProof {
  /** The provider's own identifier — never stored as it stands, only its HMAC. */
  subject_raw: string;
  label: string;
}

/** Why a callback was refused — a category for the log line, never a secret or a value. */
export type IdentityRefusalReason = "state" | "code" | "exchange" | "profile";

export interface IdentityRefusal {
  rejected: IdentityRefusalReason;
}

/**
 * One channel that can prove who a browser is.
 *
 * A provider owns its own round trip and nothing else: it does not know what an Account is, which
 * one is signed in, or whether this browser is signing in or binding another channel. `begin`
 * seals that decision into the handoff cookie for it, and `complete` answers with the subject and
 * label it proved, or with why it would not. Email is a mailed token rather than this port; it
 * still ends in `WebSessions.completeProvedIdentity`.
 */
export interface IdentityProvider {
  readonly id: IdentityProviderId;
  /** The query keys this provider's callback may carry; anything else is not its callback. */
  readonly callbackQueryKeys: readonly string[];
  begin(intent: SignInIntent, returnTo: string, now: Date): Promise<IdentityBegin>;
  complete(request: IdentityCallback, now: Date): Promise<IdentityProof | IdentityRefusal>;
}

export function isIdentityRefusal(
  result: IdentityProof | IdentityRefusal,
): result is IdentityRefusal {
  return "rejected" in result;
}

/**
 * The signed, short-lived cookie a sign-in in flight is checked against.
 *
 * State and verifier live here rather than in a table because a sign-in that never comes back
 * should cost nothing to forget. The `__Host-` prefix is what makes a signed cookie enough: a
 * browser honours it only for a `Secure`, `Path=/` cookie with no `Domain`, so nothing able to
 * write a cookie for a sibling `gotry.io` host can plant one of these on this origin.
 *
 * `sameSite` is a parameter because a provider that answers its callback with a cross-site form
 * POST cannot be given a `Lax` cookie; the providers that redirect take `Lax`.
 */
export class SignInHandoff {
  constructor(private readonly hasher: SecretHasher) {}

  async seal(payload: HandoffPayload, sameSite: "Lax" | "None"): Promise<string> {
    const encoded = encodeBase64UrlJSON(payload);
    const signature = await this.hasher.hash("oauth-handoff", encoded);
    return `${HANDOFF_COOKIE}=${encoded}.${signature}; Path=/; Max-Age=${handoffSeconds}; HttpOnly; Secure; SameSite=${sameSite}`;
  }

  /** When this sign-in expires, for a provider filling in the payload it is about to seal. */
  deadline(now: Date): string {
    return new Date(now.getTime() + handoffSeconds * 1000).toISOString();
  }

  async open(value: string | null, now: Date): Promise<HandoffPayload | null> {
    if (!value) return null;
    const separator = value.lastIndexOf(".");
    if (separator < 1) return null;
    const encoded = value.slice(0, separator);
    const expected = await this.hasher.hash("oauth-handoff", encoded);
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
    const intent = readSignInIntent(candidate.intent);
    if (
      !isIdentityProviderId(candidate.provider) ||
      intent === null ||
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
      provider: candidate.provider,
      intent,
      return_to: candidate.return_to,
      state: candidate.state,
      verifier: candidate.verifier,
      expires_at: candidate.expires_at,
    };
  }
}

export function clearedHandoffCookie(): string {
  return `${HANDOFF_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

export function readCookie(header: string | null, name: string): string | null {
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

function isIdentityProviderId(value: unknown): value is IdentityProviderId {
  return IDENTITY_PROVIDERS.some((provider) => provider === value);
}

/** The intent a sealed handoff or a stored email challenge is carrying, or null if it is not one. */
export function readSignInIntent(value: unknown): SignInIntent | null {
  if (value === null || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.kind === "sign_in") return { kind: "sign_in" };
  if (candidate.kind === "link" && typeof candidate.account_id === "string") {
    return { kind: "link", account_id: candidate.account_id };
  }
  return null;
}
