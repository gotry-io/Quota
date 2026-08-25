import type { AccountState } from "@gotry-io/relay-core";
import type {
  AccountSummaryDocumentResult,
  WebDocumentPort,
  WebDocumentViewer,
} from "../../../web/src/lib/server/document-port.ts";
import type { WebAccountAuth } from "./better-auth.ts";

const sessionCookiePattern = /(?:^|;\s*)(?:__Secure-)?quota\.session_token=/;

export function hasWebSessionCookie(cookieHeader: string | null): boolean {
  return cookieHeader !== null && sessionCookiePattern.test(cookieHeader);
}

export function createWebDocumentPort(input: {
  webAuth: WebAccountAuth;
  state: Pick<AccountState, "getAccount">;
  getAccountSummary?: (headers: Headers) => Promise<AccountSummaryDocumentResult>;
}): WebDocumentPort {
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
  };
}
