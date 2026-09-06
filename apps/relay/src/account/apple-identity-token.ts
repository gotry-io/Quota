import { constantTimeEqual, decodeBase64Url } from "../security.ts";
import { readBoundedJSON } from "./bounded-json.ts";

/** The issuer Apple names in every identity token it signs. */
export const APPLE_ISSUER = "https://appleid.apple.com";
const jwksUrl = `${APPLE_ISSUER}/auth/keys`;
/**
 * How long one fetch of Apple's public keys is reused.
 *
 * Apple rotates these keys and publishes the successor long before it signs with it, so a day-old
 * set is still the set that signed this token; a token whose `kid` is not in the cached set is
 * what forces a refetch, rather than the clock alone.
 */
const jwksCacheMilliseconds = 24 * 60 * 60 * 1000;
const timeoutMilliseconds = 20_000;
const maximumJwksBytes = 64 * 1024;
const maximumEmailLength = 320;

/** What one Apple identity token proves once it has been checked against Apple's own keys. */
export interface AppleIdentityClaims {
  /** Apple's stable user id, the same value for the Web and native flows of one Team. */
  subject: string;
  /** The address Apple states for this sign-in, which may be a private relay address. */
  email: string | null;
}

export interface AppleIdentityTokenEnvironment {
  fetch?: typeof fetch;
}

/**
 * Apple's identity tokens, and the keys that decide whether one is Apple's.
 *
 * Both flows a Team has — the Web round trip and the token `ASAuthorizationAppleIDProvider` hands
 * a native app — end in the same RS256 JWS, so both are read here. Nothing inside a token is
 * believed before its signature, issuer, audience, expiry, and nonce have all been checked: `sub`
 * is what names an Account, so a token that proves anything less names nobody.
 */
export class AppleIdentityTokens {
  readonly #fetch: typeof fetch;
  #keys: Map<string, CryptoKey> = new Map();
  #fetchedAt = 0;

  constructor(environment: AppleIdentityTokenEnvironment = {}) {
    // `fetch` refuses to run as anyone's method: called through the global, which is also what a
    // test double is happy to receive.
    const implementation = environment.fetch ?? fetch;
    this.#fetch = (input, init) => implementation.call(globalThis, input, init);
  }

  /**
   * The claims this token proves, or null when it proves nothing.
   *
   * `nonce` is the exact value the `nonce` claim must carry: the Web flow sends a random value
   * and reads it back, and a native app sends the SHA-256 of the one it generated, so the caller
   * states what it expects rather than this deciding for it.
   */
  async verify(
    token: string,
    expected: { audience: string; nonce: string; now: Date },
  ): Promise<AppleIdentityClaims | null> {
    const segments = token.split(".");
    if (segments.length !== 3) return null;
    const [encodedHeader, encodedPayload, encodedSignature] = segments as [string, string, string];
    const header = decodeSegment(encodedHeader);
    if (!header || header.alg !== "RS256" || typeof header.kid !== "string") return null;
    const key = await this.#key(header.kid, expected.now);
    if (!key) return null;
    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      decodeBase64Url(encodedSignature),
      new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
    );
    if (!verified) return null;
    const payload = decodeSegment(encodedPayload);
    if (
      !payload ||
      payload.iss !== APPLE_ISSUER ||
      payload.aud !== expected.audience ||
      typeof payload.sub !== "string" ||
      !payload.sub ||
      payload.sub.length > 256 ||
      typeof payload.exp !== "number" ||
      payload.exp * 1000 <= expected.now.getTime() ||
      typeof payload.nonce !== "string" ||
      !constantTimeEqual(payload.nonce, expected.nonce)
    ) {
      return null;
    }
    const email =
      typeof payload.email === "string" &&
      payload.email.length > 0 &&
      payload.email.length <= maximumEmailLength
        ? payload.email
        : null;
    return { subject: payload.sub, email };
  }

  /**
   * The key this `kid` names. A `kid` the cached set does not hold is what a rotation looks like,
   * so the set is refetched once for it rather than only when the cache has aged out.
   */
  async #key(kid: string, now: Date): Promise<CryptoKey | null> {
    const cached = this.#keys.get(kid);
    if (cached && now.getTime() - this.#fetchedAt < jwksCacheMilliseconds) return cached;
    const fetched = await this.#fetchKeys();
    if (!fetched) return cached ?? null;
    this.#keys = fetched;
    this.#fetchedAt = now.getTime();
    return fetched.get(kid) ?? null;
  }

  async #fetchKeys(): Promise<Map<string, CryptoKey> | null> {
    const response = await this.#fetch(jwksUrl, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(timeoutMilliseconds),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = await readBoundedJSON(response, maximumJwksBytes);
    if (!Array.isArray(body.keys)) return null;
    const keys = new Map<string, CryptoKey>();
    for (const entry of body.keys) {
      if (entry === null || typeof entry !== "object") continue;
      const jwk = entry as Record<string, unknown>;
      if (
        jwk.kty !== "RSA" ||
        jwk.alg !== "RS256" ||
        typeof jwk.kid !== "string" ||
        typeof jwk.n !== "string" ||
        typeof jwk.e !== "string"
      ) {
        continue;
      }
      const key = await crypto.subtle
        .importKey(
          "jwk",
          { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
          { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
          false,
          ["verify"],
        )
        .catch(() => null);
      if (key) keys.set(jwk.kid, key);
    }
    return keys.size > 0 ? keys : null;
  }
}

/** The `nonce` claim a native sign-in must carry: the SHA-256 of the value the app generated. */
export async function appleNativeNonceClaim(nonce: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(nonce));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function decodeSegment(segment: string): Record<string, unknown> | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(decodeBase64Url(segment)));
  } catch {
    return null;
  }
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : null;
}
