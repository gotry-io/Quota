import { ACCOUNT_SCOPES, type AccountPrincipal } from "@gotry-io/relay-core";
import type { WebSessionPort } from "../src/account/web-session.ts";

/**
 * A browser already signed in as one Account, for the routes that only need a Web principal.
 *
 * `beginSignIn` records where the sign-in was told to return to, which is how the native browser
 * grant hands its login token back to `/oauth/v2/complete`.
 */
export class SignedInWebSessionStub implements WebSessionPort {
  returnTo = "";
  authenticatedAt: Date;

  constructor(
    private readonly accountId: string,
    authenticatedAt: Date,
  ) {
    this.authenticatedAt = authenticatedAt;
  }

  async beginSignIn(returnTo: string): Promise<{ location: string; handoff: string }> {
    this.returnTo = returnTo;
    return {
      location: "https://github.com/login/oauth/authorize",
      handoff: "__Host-quota_oauth=stub; Path=/; HttpOnly; Secure; SameSite=Lax",
    };
  }

  async completeSignIn(): Promise<{ outcome: "rejected" }> {
    return { outcome: "rejected" };
  }

  async authorize(): Promise<AccountPrincipal | null> {
    return {
      kind: "account",
      session_id: `web_${this.accountId}`,
      family_id: `web_${this.accountId}`,
      account_id: this.accountId,
      device_id: null,
      client_kind: "web",
      scopes: [...ACCOUNT_SCOPES],
      authenticated_at: this.authenticatedAt.toISOString(),
    };
  }
}

/** A browser with no session at all. */
export const signedOutWebSessions: WebSessionPort = {
  async beginSignIn() {
    return {
      location: "https://github.com/login/oauth/authorize",
      handoff: "__Host-quota_oauth=stub",
    };
  },
  async completeSignIn() {
    return { outcome: "rejected" };
  },
  async authorize() {
    return null;
  },
};
