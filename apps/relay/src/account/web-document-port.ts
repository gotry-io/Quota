import type { AccountState } from "@gotry-io/relay-core";
import type {
  PublicProfileDocumentResult,
  AccountSummaryDocumentResult,
  WebDocumentPort,
  WebDocumentViewer,
} from "../../../web/src/lib/server/document-port.ts";
import { normalizePublicSlug } from "../public-profile.ts";
import type { SecretHasher } from "../security.ts";
import type { WebAccountAuth } from "./better-auth.ts";
import { consumeNamedRateLimit, publicProfileRateLimit } from "./rate-limit.ts";

const sessionCookiePattern = /(?:^|;\s*)(?:__Secure-)?quota\.session_token=/;

export function hasWebSessionCookie(cookieHeader: string | null): boolean {
  return cookieHeader !== null && sessionCookiePattern.test(cookieHeader);
}

export function createWebDocumentPort(input: {
  webAuth: WebAccountAuth;
  state: Pick<AccountState, "getAccount" | "getAccountByPublicSlug" | "consumeRateLimit">;
  hasher: SecretHasher;
  getAccountSummary?: (headers: Headers) => Promise<AccountSummaryDocumentResult>;
  now?: () => Date;
}): WebDocumentPort {
  const now = input.now ?? (() => new Date());
  const getAccountSummary = input.getAccountSummary;
  return {
    async getViewer(headers: Headers): Promise<WebDocumentViewer | null> {
      if (!hasWebSessionCookie(headers.get("Cookie"))) return null;
      const session = await input.webAuth.getSession(headers);
      if (!session) return null;
      const account = await input.state.getAccount(session.user.id);
      if (!account) return null;
      const label = account.display_label?.trim() || session.user.name.trim();
      return { displayLabel: label || "Account" };
    },
    ...(getAccountSummary
      ? {
          getAccountSummary(headers: Headers) {
            return getAccountSummary(headers);
          },
        }
      : {}),
    async lookupPublicProfile(username: string): Promise<PublicProfileDocumentResult> {
      const slug = normalizePublicSlug(username);
      if (!slug) return { status: "missing" };
      const limited = await consumeNamedRateLimit(
        input.state,
        input.hasher,
        "public-profile",
        slug,
        publicProfileRateLimit,
        now(),
      );
      if (!limited.allowed) {
        return { status: "rate_limited", retryAfterSeconds: limited.retryAfterSeconds };
      }
      const account = await input.state.getAccountByPublicSlug(slug);
      return account ? { status: "exists" } : { status: "missing" };
    },
  };
}
