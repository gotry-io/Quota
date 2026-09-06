import { constantTimeEqual, randomOpaqueSecret, sha256Base64Url } from "../security.ts";
import type {
  IdentityBegin,
  IdentityCallback,
  IdentityProof,
  IdentityProvider,
  IdentityRefusal,
  SignInHandoff,
  SignInIntent,
} from "./identity.ts";

/** The issuer GitHub states in its authorization-code redirect (RFC 9207). */
const GITHUB_ISSUER = "https://github.com/login/oauth";
const authorizeUrl = "https://github.com/login/oauth/authorize";
const tokenUrl = "https://github.com/login/oauth/access_token";
const userUrl = "https://api.github.com/user";
const timeoutMilliseconds = 20_000;
const maximumProfileBytes = 64 * 1024;
const maximumAuthorizationCodeLength = 1_024;
const authorizationCodePattern = /^[A-Za-z0-9._~-]+$/;

export interface GitHubIdentityEnvironment {
  handoff: SignInHandoff;
  clientId: string;
  clientSecret: string;
  /** Where GitHub sends the browser back, which the code exchange must repeat. */
  callbackUrl: string;
  fetch?: typeof fetch;
}

/**
 * GitHub as one of the channels an Account can be reached through.
 *
 * Relay is the confidential client. A round trip generates a 256-bit `state` and a PKCE verifier,
 * keeps both in the sealed handoff cookie rather than in a table, and checks the callback against
 * that cookie before spending the authorization code. What comes back is read once for a numeric
 * id and a login name; the access token is used for that one request and never stored.
 */
export class GitHubIdentityProvider implements IdentityProvider {
  readonly id = "github" as const;
  readonly callbackQueryKeys = ["code", "state", "iss"] as const;
  readonly #fetch: typeof fetch;

  constructor(private readonly environment: GitHubIdentityEnvironment) {
    // `fetch` is a global that refuses to run as anyone's method: stored on this object and
    // called as `this.#fetch(...)`, workerd throws "Illegal invocation". Call it with the
    // global as its receiver, which is also what a test double is happy to receive.
    const implementation = environment.fetch ?? fetch;
    this.#fetch = (input, init) => implementation.call(globalThis, input, init);
  }

  async begin(intent: SignInIntent, returnTo: string, now: Date): Promise<IdentityBegin> {
    const state = randomOpaqueSecret();
    const verifier = randomOpaqueSecret();
    const url = new URL(authorizeUrl);
    url.searchParams.set("client_id", this.environment.clientId);
    url.searchParams.set("redirect_uri", this.environment.callbackUrl);
    url.searchParams.set("state", state);
    // No scope at all: Quota reads the public profile every GitHub token can already read, and
    // asks for nothing it would have to be trusted with.
    url.searchParams.set("scope", "");
    url.searchParams.set("code_challenge", await sha256Base64Url(verifier));
    url.searchParams.set("code_challenge_method", "S256");
    const handoff = await this.environment.handoff.seal(
      {
        provider: this.id,
        intent,
        return_to: returnTo,
        state,
        verifier,
        expires_at: this.environment.handoff.deadline(now),
      },
      "Lax",
    );
    return { location: url.toString(), handoff };
  }

  async complete(request: IdentityCallback): Promise<IdentityProof | IdentityRefusal> {
    // GitHub names itself in the redirect (`iss`, RFC 9207). A callback that names any other
    // issuer is not GitHub's; one that names none is an older GitHub and still is.
    const issuer = request.query.get("iss");
    if (issuer !== null && issuer !== GITHUB_ISSUER) return { rejected: "state" };
    const state = request.query.get("state");
    if (!state || !constantTimeEqual(state, request.challenge.state)) {
      return { rejected: "state" };
    }
    const code = request.query.get("code");
    if (
      !code ||
      code.length > maximumAuthorizationCodeLength ||
      !authorizationCodePattern.test(code)
    ) {
      return { rejected: "code" };
    }
    const accessToken = await this.#exchangeCode(code, request.challenge.verifier);
    if (!accessToken) return { rejected: "exchange" };
    const profile = await this.#readProfile(accessToken);
    if (!profile) return { rejected: "profile" };
    return { subject_raw: String(profile.id), label: profile.label };
  }

  /**
   * Spend the authorization code once. GitHub answers a replayed or mismatched code with an
   * `error` body rather than a failing status, so both are read the same way and both mean no.
   */
  async #exchangeCode(code: string, verifier: string): Promise<string | null> {
    const response = await this.#fetch(tokenUrl, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "QuotaRelay",
      },
      body: new URLSearchParams({
        client_id: this.environment.clientId,
        client_secret: this.environment.clientSecret,
        code,
        redirect_uri: this.environment.callbackUrl,
        code_verifier: verifier,
      }).toString(),
      signal: AbortSignal.timeout(timeoutMilliseconds),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = await readBoundedJSON(response);
    return typeof body.access_token === "string" && body.access_token ? body.access_token : null;
  }

  async #readProfile(accessToken: string): Promise<{ id: number; label: string } | null> {
    const response = await this.#fetch(userUrl, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${accessToken}`,
        "User-Agent": "QuotaRelay",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      signal: AbortSignal.timeout(timeoutMilliseconds),
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
