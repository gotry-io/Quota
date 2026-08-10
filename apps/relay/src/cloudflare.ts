import { createWebAccountAuth } from "./account/better-auth.ts";
import { AccountService } from "./account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "./app.ts";
import { CANONICAL_ORIGIN } from "./config.ts";
import { SecretHasher } from "./security.ts";
import { D1AccountState } from "./state/d1-account-state.ts";
import { D1UsageState } from "./state/d1-usage-state.ts";

export interface CloudflareBindings {
  DB: D1Database;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  GITHUB_SUBJECT_KEY: string;
  QUOTA_INSTALLATION_KEY: string;
  QUOTA_SESSION_HASH_KEY: string;
  BETTER_AUTH_SECRET: string;
}

export default {
  async fetch(request, environment): Promise<Response> {
    const state = new D1AccountState(environment.DB);
    const hasher = new SecretHasher(environment.QUOTA_SESSION_HASH_KEY);
    const accountService = new AccountService(state, hasher, environment.QUOTA_INSTALLATION_KEY);
    const webAuth = createWebAccountAuth({
      database: environment.DB,
      githubClientId: environment.GITHUB_CLIENT_ID,
      githubClientSecret: environment.GITHUB_CLIENT_SECRET,
      githubSubjectKey: environment.GITHUB_SUBJECT_KEY,
      authSecret: environment.BETTER_AUTH_SECRET,
      origin: CANONICAL_ORIGIN,
    });
    return createRelayApp({
      state,
      usageState: new D1UsageState(environment.DB),
      accountService,
      webAuth,
      hasher,
    }).fetch(request);
  },
  async scheduled(_controller, environment): Promise<void> {
    await new D1AccountState(environment.DB).performMaintenance(
      accountMaintenanceInput(new Date()),
    );
  },
} satisfies ExportedHandler<CloudflareBindings>;
