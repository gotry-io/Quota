import {
  bytesToBase64Url,
  constantTimeEqual,
  decodeBase64Url,
  randomOpaqueSecret,
} from "../security.ts";
import { APPLE_ISSUER, type AppleIdentityTokens } from "./apple-identity-token.ts";
import { readBoundedJSON } from "./bounded-json.ts";
import type {
  IdentityBegin,
  IdentityCallback,
  IdentityProof,
  IdentityProvider,
  IdentityRefusal,
  SignInHandoff,
  SignInIntent,
} from "./identity.ts";

const authorizeUrl = `${APPLE_ISSUER}/auth/authorize`;
const tokenUrl = `${APPLE_ISSUER}/auth/token`;
const timeoutMilliseconds = 20_000;
const maximumTokenBytes = 64 * 1024;
const maximumAuthorizationCodeLength = 1_024;
const authorizationCodePattern = /^[A-Za-z0-9._-]+$/;
/**
 * How long the client secret Relay signs is good for.
 *
 * Apple allows up to six months, but the secret is signed per exchange and spent within one round
 * trip, so it is minted for minutes: nothing keeps it, and nothing has to be rotated when the key
 * behind it is.
 */
const clientSecretSeconds = 5 * 60;

export interface AppleIdentityEnvironment {
  handoff: SignInHandoff;
  tokens: AppleIdentityTokens;
  /** The Apple Developer Team the Services ID and the signing key both belong to. */
  teamId: string;
  /** The Services ID, which is this flow's `client_id` and the audience Apple states. */
  servicesId: string;
  keyId: string;
  /** The Sign in with Apple signing key, as the PKCS#8 PEM Apple hands out once. */
  privateKeyPem: string;
  /** The one Return URL Apple will post a callback to. */
  callbackUrl: string;
  fetch?: typeof fetch;
}

/**
 * Apple as one of the channels an Account can be reached through.
 *
 * Apple answers a Web sign-in with a cross-site form POST rather than a redirect, because asking
 * for `name email` requires `response_mode=form_post`. A browser will not attach a `SameSite=Lax`
 * cookie to that POST, so this provider's handoff is the one sealed `SameSite=None` — still
 * `__Host-`, still signed, still ten minutes long
 * ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 *
 * Relay is the confidential client here too, but Apple's client secret is not a stored string: it
 * is an ES256 JWT this signs for each exchange from the Team's key.
 */
export class AppleIdentityProvider implements IdentityProvider {
  readonly id = "apple" as const;
  /**
   * `user` is Apple's own field, posted only on the first authorization and carrying the name and
   * address the person chose to share. It is accepted so that first callback is not refused as
   * malformed, and it is not read: everything this provider believes comes out of the signed
   * identity token instead.
   */
  readonly callbackParameterKeys = ["code", "state", "user", "error"] as const;
  readonly callbackDelivery = "form_post" as const;
  readonly #fetch: typeof fetch;

  constructor(private readonly environment: AppleIdentityEnvironment) {
    const implementation = environment.fetch ?? fetch;
    this.#fetch = (input, init) => implementation.call(globalThis, input, init);
  }

  async begin(intent: SignInIntent, returnTo: string, now: Date): Promise<IdentityBegin> {
    const state = randomOpaqueSecret();
    const nonce = randomOpaqueSecret();
    const url = new URL(authorizeUrl);
    url.searchParams.set("client_id", this.environment.servicesId);
    url.searchParams.set("redirect_uri", this.environment.callbackUrl);
    url.searchParams.set("response_type", "code");
    // Asking for a name or an address is what makes Apple answer with a cross-site form POST.
    url.searchParams.set("response_mode", "form_post");
    url.searchParams.set("scope", "name email");
    url.searchParams.set("state", state);
    url.searchParams.set("nonce", nonce);
    const handoff = await this.environment.handoff.seal(
      {
        provider: this.id,
        intent,
        return_to: returnTo,
        state,
        // Apple binds the exchange with a nonce it states back inside the identity token, which
        // is what the handoff's per-round-trip secret is for here.
        verifier: nonce,
        expires_at: this.environment.handoff.deadline(now),
      },
      "None",
    );
    return { location: url.toString(), handoff };
  }

  async complete(request: IdentityCallback, now: Date): Promise<IdentityProof | IdentityRefusal> {
    // Apple states a refusal in the same POST it would have delivered a code in: a person who
    // cancelled at Apple is not a browser whose sign-in was tampered with.
    if (request.parameters.get("error") !== null) return { rejected: "code" };
    const state = request.parameters.get("state");
    if (!state || !constantTimeEqual(state, request.challenge.state)) {
      return { rejected: "state" };
    }
    const code = request.parameters.get("code");
    if (
      !code ||
      code.length > maximumAuthorizationCodeLength ||
      !authorizationCodePattern.test(code)
    ) {
      return { rejected: "code" };
    }
    const identityToken = await this.#exchangeCode(code, now);
    if (!identityToken) return { rejected: "exchange" };
    const claims = await this.environment.tokens.verify(identityToken, {
      audience: this.environment.servicesId,
      nonce: request.challenge.verifier,
      now,
    });
    if (!claims) return { rejected: "profile" };
    return { subject_raw: claims.subject, ...appleLabel(claims.email) };
  }

  /** Spend the authorization code once, and read only the identity token out of the answer. */
  async #exchangeCode(code: string, now: Date): Promise<string | null> {
    const response = await this.#fetch(tokenUrl, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "QuotaRelay",
      },
      body: new URLSearchParams({
        client_id: this.environment.servicesId,
        client_secret: await this.#clientSecret(now),
        code,
        grant_type: "authorization_code",
        redirect_uri: this.environment.callbackUrl,
      }).toString(),
      signal: AbortSignal.timeout(timeoutMilliseconds),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = await readBoundedJSON(response, maximumTokenBytes);
    return typeof body.id_token === "string" && body.id_token ? body.id_token : null;
  }

  /**
   * The client secret Apple asks for: an ES256 JWT the Team signs for itself, naming the Services
   * ID as its subject and Apple as its audience.
   */
  async #clientSecret(now: Date): Promise<string> {
    const issuedAt = Math.floor(now.getTime() / 1000);
    const signingInput = `${encodeJwtSegment({
      alg: "ES256",
      kid: this.environment.keyId,
      typ: "JWT",
    })}.${encodeJwtSegment({
      iss: this.environment.teamId,
      iat: issuedAt,
      exp: issuedAt + clientSecretSeconds,
      aud: APPLE_ISSUER,
      sub: this.environment.servicesId,
    })}`;
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pkcs8FromPem(this.environment.privateKeyPem),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(signingInput),
    );
    return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
  }
}

/**
 * What Apple's channel is called on an Account.
 *
 * Apple states an address only while the person is sharing one, and it may be a private relay
 * address rather than theirs. When there is none, the channel is named after itself — and says so,
 * because that stand-in must not overwrite an address a earlier sign-in did state.
 */
export function appleLabel(email: string | null): {
  label: string;
  label_is_placeholder: boolean;
} {
  const trimmed = email?.trim() ?? "";
  return trimmed
    ? { label: trimmed.slice(0, 128), label_is_placeholder: false }
    : { label: "Apple ID", label_is_placeholder: true };
}

function pkcs8FromPem(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  return decodeBase64Url(body);
}

function encodeJwtSegment(value: unknown): string {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
}
