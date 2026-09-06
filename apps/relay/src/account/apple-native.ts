import type { AccountState, LinkIdentityOutcome } from "@gotry-io/relay-core";
import { appleNativeNonceClaim, type AppleIdentityTokens } from "./apple-identity-token.ts";
import { appleLabel } from "./apple-identity.ts";
import type { AccountService, AccountTokenResponse } from "./service.ts";
import { identitySubjectHash } from "./identity.ts";

/** The token proved nothing: a bad signature, the wrong audience, a stale nonce, an expiry. */
export interface NativeIdentityRefusal {
  rejected: "identity";
}

export interface AppleNativeEnvironment {
  tokens: AppleIdentityTokens;
  state: Pick<AccountState, "resolveSignInIdentity" | "linkIdentity">;
  accountService: Pick<AccountService, "openIosSession">;
  /** The HMAC key every provider's subject is stored under. */
  identitySubjectKey: string;
  /** The audience Apple states for this app: its bundle identifier. */
  audience: string;
}

/**
 * Sign in with Apple as the iOS app performs it, without a browser round trip.
 *
 * `ASAuthorizationAppleIDProvider` already proves who this is on the device, so sending the app
 * out to a web page to prove it again would ask the same question twice and hand the answer back
 * through a redirect. The app posts the identity token instead; this checks it against Apple's
 * own keys and answers with the viewer's one session
 * ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 *
 * The `sub` Apple states is the same value the Web flow proves for the same person under the same
 * Team, so an Account reached through the website and one reached in the app are one Account.
 */
export class AppleNativeSignIn {
  constructor(private readonly environment: AppleNativeEnvironment) {}

  /** The Account this token reaches, opening one when it reaches none. */
  async signIn(
    identityToken: string,
    nonce: string,
    now: Date,
  ): Promise<AccountTokenResponse | NativeIdentityRefusal> {
    const identity = await this.#prove(identityToken, nonce, now);
    if (!identity) return { rejected: "identity" };
    const account = await this.environment.state.resolveSignInIdentity({
      provider: "apple",
      subject: identity.subject,
      label: identity.label,
      label_is_placeholder: identity.label_is_placeholder,
      new_account_id: `account_${crypto.randomUUID()}`,
      now: now.toISOString(),
    });
    return this.environment.accountService.openIosSession(account.id, account.display_label, now);
  }

  /** Bind Apple to the Account this session already names. */
  async link(
    accountId: string,
    identityToken: string,
    nonce: string,
    now: Date,
  ): Promise<LinkIdentityOutcome | NativeIdentityRefusal> {
    const identity = await this.#prove(identityToken, nonce, now);
    if (!identity) return { rejected: "identity" };
    return this.environment.state.linkIdentity({
      account_id: accountId,
      provider: "apple",
      subject: identity.subject,
      label: identity.label,
      now: now.toISOString(),
    });
  }

  async #prove(
    identityToken: string,
    nonce: string,
    now: Date,
  ): Promise<{ subject: string; label: string; label_is_placeholder: boolean } | null> {
    const claims = await this.environment.tokens.verify(identityToken, {
      audience: this.environment.audience,
      // The app sends Apple the digest and keeps the value; the claim is the digest, so this is
      // what proves the token answers the request this device made rather than an older one.
      nonce: await appleNativeNonceClaim(nonce),
      now,
    });
    if (!claims) return null;
    return {
      subject: await identitySubjectHash(
        this.environment.identitySubjectKey,
        "apple",
        claims.subject,
      ),
      ...appleLabel(claims.email),
    };
  }
}

export function isNativeIdentityRefusal<T>(
  result: T | NativeIdentityRefusal,
): result is NativeIdentityRefusal {
  return typeof result === "object" && result !== null && "rejected" in result;
}
