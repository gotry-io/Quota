import { AccountService } from "./account/service.ts";
import { createWebDocumentPort } from "./account/web-document-port.ts";
import { GitHubWebSessions, memoizeWebSessionAuthorization } from "./account/web-session.ts";
import { accountMaintenanceInput, createRelayApp } from "./app.ts";
import { CANONICAL_ORIGIN } from "./config.ts";
import { isRelayApiPath } from "./relay-paths.ts";
import { SecretHasher } from "./security.ts";
import { D1AccountState } from "./state/d1-account-state.ts";
import { D1UsageState } from "./state/d1-usage-state.ts";
import { respondWithWebDocument } from "./web-document.ts";

export interface CloudflareBindings {
  DB: D1Database;
  ASSETS: Fetcher;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  GITHUB_SUBJECT_KEY: string;
  QUOTA_INSTALLATION_KEY: string;
  QUOTA_SESSION_HASH_KEY: string;
}

export default {
  async fetch(request, environment, context): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const state = new D1AccountState(environment.DB);
    const hasher = new SecretHasher(environment.QUOTA_SESSION_HASH_KEY);
    const webSessions = memoizeWebSessionAuthorization(
      new GitHubWebSessions({
        state,
        hasher,
        githubClientId: environment.GITHUB_CLIENT_ID,
        githubClientSecret: environment.GITHUB_CLIENT_SECRET,
        githubSubjectKey: environment.GITHUB_SUBJECT_KEY,
        origin: CANONICAL_ORIGIN,
      }),
    );
    const usageState = new D1UsageState(environment.DB);
    const relay = createRelayApp({
      state,
      usageState,
      accountService: new AccountService(state, hasher, environment.QUOTA_INSTALLATION_KEY),
      webSessions,
      hasher,
    });

    if (isRelayApiPath(pathname)) {
      return relay.fetch(request);
    }

    return respondWithWebDocument(request, environment, context, {
      document: createWebDocumentPort({ webSessions, state }),
    });
  },
  async scheduled(_controller, environment): Promise<void> {
    await new D1AccountState(environment.DB).performMaintenance(
      accountMaintenanceInput(new Date()),
    );
  },
} satisfies ExportedHandler<CloudflareBindings>;
