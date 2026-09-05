import type { SessionPrincipal } from "@gotry-io/relay-core";
import type { WebSessionPort } from "../src/account/web-session.ts";

const github = { id: "github", callbackQueryKeys: ["code", "state", "iss"] } as const;

/** A browser already signed in as one Account, for the routes that only need a Web principal. */
export class SignedInWebSessionStub implements WebSessionPort {
  authenticatedAt: Date;

  constructor(
    private readonly accountId: string,
    authenticatedAt: Date,
  ) {
    this.authenticatedAt = authenticatedAt;
  }

  identityProvider(id: string) {
    return id === github.id ? { ...github } : null;
  }

  async beginSignIn(): Promise<{ location: string; handoff: string }> {
    return {
      location: "https://github.com/login/oauth/authorize",
      handoff: "__Host-quota_oauth=stub; Path=/; HttpOnly; Secure; SameSite=Lax",
    };
  }

  async completeSignIn(): Promise<{ outcome: "rejected"; reason: "handoff" }> {
    return { outcome: "rejected", reason: "handoff" };
  }

  async authorize(): Promise<SessionPrincipal | null> {
    return {
      session_id: `web_${this.accountId}`,
      family_id: `web_${this.accountId}`,
      account_id: this.accountId,
      device_id: null,
      device_generation: null,
      client_kind: "web",
      scopes: ["account:read", "account:manage"],
      authenticated_at: this.authenticatedAt.toISOString(),
    };
  }
}

/** A browser with no session at all. */
export const signedOutWebSessions: WebSessionPort = {
  identityProvider(id) {
    return id === github.id ? { ...github } : null;
  },
  async beginSignIn() {
    return {
      location: "https://github.com/login/oauth/authorize",
      handoff: "__Host-quota_oauth=stub",
    };
  },
  async completeSignIn() {
    return { outcome: "rejected", reason: "handoff" };
  },
  async authorize() {
    return null;
  },
};
