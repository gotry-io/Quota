import type { ModelCatalog, PricingCatalog, PublicUsageResponse } from "@gotry-io/quota-protocol";
import type { AccountState, UsageState } from "@gotry-io/relay-core";
import type {
  WebDocumentPort,
  WebDocumentViewer,
  WebLeaderboardView,
} from "../../../web/src/lib/server/document-port.ts";
import { readLeaderboard } from "../leaderboard.ts";
import { readPublicProfile } from "../public-profile.ts";
import type { WebSessionPort } from "./web-session.ts";

export function createWebDocumentPort(input: {
  webSessions: WebSessionPort;
  state: Pick<
    AccountState,
    | "getAccount"
    | "getPublicProfile"
    | "findEnabledPublicProfile"
    | "accountUsageVersionStamp"
    | "leaderboardVersionStamp"
  >;
  usageState: Pick<UsageState, "queryDailyUsage" | "queryLeaderboard">;
  catalog: PricingCatalog;
  modelCatalog: ModelCatalog;
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
    async readPublicProfile(handle: string): Promise<PublicUsageResponse | null> {
      const read = await readPublicProfile({
        state: input.state,
        usageState: input.usageState,
        catalog: input.catalog,
        modelCatalog: input.modelCatalog,
        handle,
        checkedAt: now(),
      });
      return read === null ? null : read.payload();
    },
    async readLeaderboard(headers: Headers): Promise<WebLeaderboardView> {
      const read = await readLeaderboard({
        state: input.state,
        usageState: input.usageState,
        checkedAt: now(),
      });
      const principal = await input.webSessions.authorize(headers, now());
      const profile = principal ? await input.state.getPublicProfile(principal.account_id) : null;
      return { board: await read.payload(), viewerHandle: profile?.handle ?? null };
    },
  };
}
