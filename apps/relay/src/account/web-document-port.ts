import type { AccountState } from "@gotry-io/relay-core";
import type {
  WebDocumentPort,
  WebDocumentViewer,
} from "../../../web/src/lib/server/document-port.ts";
import type { WebSessionPort } from "./web-session.ts";

export function createWebDocumentPort(input: {
  webSessions: WebSessionPort;
  state: Pick<AccountState, "getAccount">;
  now?: () => Date;
}): WebDocumentPort {
  const now = input.now ?? (() => new Date());
  return {
    async getViewer(headers: Headers): Promise<WebDocumentViewer | null> {
      const principal = await input.webSessions.authorize(headers, now());
      if (!principal) return null;
      const account = await input.state.getAccount(principal.account_id);
      if (!account) return null;
      return { displayLabel: account.display_label?.trim() || "Account" };
    },
  };
}
