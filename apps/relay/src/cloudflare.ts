import { IOS_BUNDLE_ID } from "@gotry-io/quota-protocol";
import { AppleIdentityTokens } from "./account/apple-identity-token.ts";
import { AppleIdentityProvider } from "./account/apple-identity.ts";
import { AppleNativeSignIn } from "./account/apple-native.ts";
import { ResendEmailSender } from "./account/email-sender.ts";
import { GitHubIdentityProvider } from "./account/github-identity.ts";
import { SignInHandoff } from "./account/identity.ts";
import { MODEL_CATALOG } from "@gotry-io/quota-protocol";
import { AccountService } from "./account/service.ts";
import { createWebDocumentPort } from "./account/web-document-port.ts";
import { memoizeWebSessionAuthorization, WebSessions } from "./account/web-session.ts";
import { accountMaintenanceInput, createRelayApp } from "./app.ts";
import { CANONICAL_ORIGIN } from "./config.ts";
import { PRICING_CATALOG } from "./pricing-catalog.ts";
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
  APPLE_SIGNIN_TEAM_ID: string;
  APPLE_SIGNIN_SERVICES_ID: string;
  APPLE_SIGNIN_KEY_ID: string;
  APPLE_SIGNIN_PRIVATE_KEY: string;
  IDENTITY_SUBJECT_KEY: string;
  QUOTA_INSTALLATION_KEY: string;
  QUOTA_SESSION_HASH_KEY: string;
  RESEND_API_KEY: string;
  REVENUECAT_WEBHOOK_SECRET?: string;
  REVENUECAT_SECRET_KEY?: string;
  REVENUECAT_WEB_PURCHASE_URL?: string;
}

export default {
  async fetch(request, environment, context): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const state = new D1AccountState(environment.DB);
    const hasher = new SecretHasher(environment.QUOTA_SESSION_HASH_KEY);
    const handoff = new SignInHandoff(hasher);
    // One verifier for both Apple flows: the Web round trip and the token the iOS app posts are
    // signed by the same keys, so they read them from the same cache.
    const appleTokens = new AppleIdentityTokens();
    const webSessions = memoizeWebSessionAuthorization(
      new WebSessions({
        state,
        hasher,
        handoff,
        identitySubjectKey: environment.IDENTITY_SUBJECT_KEY,
        providers: [
          new GitHubIdentityProvider({
            handoff,
            clientId: environment.GITHUB_CLIENT_ID,
            clientSecret: environment.GITHUB_CLIENT_SECRET,
            callbackUrl: `${CANONICAL_ORIGIN}/api/auth/github/callback`,
          }),
          new AppleIdentityProvider({
            handoff,
            tokens: appleTokens,
            teamId: environment.APPLE_SIGNIN_TEAM_ID,
            servicesId: environment.APPLE_SIGNIN_SERVICES_ID,
            keyId: environment.APPLE_SIGNIN_KEY_ID,
            privateKeyPem: environment.APPLE_SIGNIN_PRIVATE_KEY,
            // The one Return URL Apple accepts for this Services ID.
            callbackUrl: `${CANONICAL_ORIGIN}/api/auth/apple/callback`,
          }),
        ],
      }),
    );
    const usageState = new D1UsageState(environment.DB);
    const accountService = new AccountService(state, hasher, environment.QUOTA_INSTALLATION_KEY);
    const relay = createRelayApp({
      state,
      usageState,
      accountService,
      webSessions,
      appleNativeSignIn: new AppleNativeSignIn({
        tokens: appleTokens,
        state,
        accountService,
        identitySubjectKey: environment.IDENTITY_SUBJECT_KEY,
        audience: IOS_BUNDLE_ID,
      }),
      hasher,
      emailSender: new ResendEmailSender({ apiKey: environment.RESEND_API_KEY }),
      billing: {
        webhookSecret: environment.REVENUECAT_WEBHOOK_SECRET ?? "",
        restSecret: environment.REVENUECAT_SECRET_KEY ?? "",
        webPurchaseUrl: environment.REVENUECAT_WEB_PURCHASE_URL ?? "",
      },
    });

    if (isRelayApiPath(pathname)) {
      return relay.fetch(request);
    }

    return respondWithWebDocument(request, environment, context, {
      document: createWebDocumentPort({
        webSessions,
        state,
        usageState,
        catalog: PRICING_CATALOG,
        modelCatalog: MODEL_CATALOG,
      }),
    });
  },
  async scheduled(_controller, environment): Promise<void> {
    await new D1AccountState(environment.DB).performMaintenance(
      accountMaintenanceInput(new Date()),
    );
  },
} satisfies ExportedHandler<CloudflareBindings>;
