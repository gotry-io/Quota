import { IOS_BUNDLE_ID, MODEL_CATALOG } from "@gotry-io/quota-protocol";
import { AppleIdentityTokens } from "./account/apple-identity-token.ts";
import { AppleIdentityProvider } from "./account/apple-identity.ts";
import { AppleNativeSignIn } from "./account/apple-native.ts";
import { ResendEmailSender } from "./account/email-sender.ts";
import { GitHubIdentityProvider } from "./account/github-identity.ts";
import { SignInHandoff } from "./account/identity.ts";
import { AccountService } from "./account/service.ts";
import { createWebDocumentPort } from "./account/web-document-port.ts";
import { memoizeWebSessionAuthorization, WebSessions } from "./account/web-session.ts";
import { createRelayApp } from "./app.ts";
import { CANONICAL_ORIGIN } from "./config.ts";
import type { RelayDatabase } from "./platform/database.ts";
import type { LastReadingCache } from "./platform/reading-cache.ts";
import type { StaticFiles } from "./platform/static-files.ts";
import { PRICING_CATALOG } from "./pricing-catalog.ts";
import { isRelayApiPath } from "./relay-paths.ts";
import { SecretHasher } from "./security.ts";
import { D1AccountState } from "./state/d1-account-state.ts";
import { D1UsageState } from "./state/d1-usage-state.ts";
import { respondWithWebDocument } from "./web-document.ts";

/** The configuration a deployment holds, whatever it runs on. Node reads these from the process. */
export interface RelaySecrets {
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
}

/** What a runtime supplies: a database, the built website's files, and a place to cache readings. */
export interface RelayPlatform {
  database: RelayDatabase;
  assets: StaticFiles;
  statusCache: LastReadingCache;
  secrets: RelaySecrets;
}

/**
 * One request, answered by the API or by a rendered document.
 *
 * The assembly is per request rather than per process because the pieces it memoizes — the
 * session authorization and the document port — are answers about the caller in front of it, not
 * about the deployment. Both entry points call this, so neither carries the wiring
 * ([ADR 0049](../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
export async function respondAsRelay(
  request: Request,
  platform: RelayPlatform,
  context: ExecutionContext | undefined,
): Promise<Response> {
  const secrets = platform.secrets;
  const state = new D1AccountState(platform.database);
  const hasher = new SecretHasher(secrets.QUOTA_SESSION_HASH_KEY);
  const handoff = new SignInHandoff(hasher);
  // One verifier for both Apple flows: the Web round trip and the token the iOS app posts are
  // signed by the same keys, so they read them from the same cache.
  const appleTokens = new AppleIdentityTokens();
  const webSessions = memoizeWebSessionAuthorization(
    new WebSessions({
      state,
      hasher,
      handoff,
      identitySubjectKey: secrets.IDENTITY_SUBJECT_KEY,
      providers: [
        new GitHubIdentityProvider({
          handoff,
          clientId: secrets.GITHUB_CLIENT_ID,
          clientSecret: secrets.GITHUB_CLIENT_SECRET,
          callbackUrl: `${CANONICAL_ORIGIN}/api/auth/github/callback`,
        }),
        new AppleIdentityProvider({
          handoff,
          tokens: appleTokens,
          teamId: secrets.APPLE_SIGNIN_TEAM_ID,
          servicesId: secrets.APPLE_SIGNIN_SERVICES_ID,
          keyId: secrets.APPLE_SIGNIN_KEY_ID,
          privateKeyPem: secrets.APPLE_SIGNIN_PRIVATE_KEY,
          // The one Return URL Apple accepts for this Services ID.
          callbackUrl: `${CANONICAL_ORIGIN}/api/auth/apple/callback`,
        }),
      ],
    }),
  );
  const usageState = new D1UsageState(platform.database);
  const accountService = new AccountService(state, hasher, secrets.QUOTA_INSTALLATION_KEY);

  if (isRelayApiPath(new URL(request.url).pathname)) {
    return await createRelayApp({
      state,
      usageState,
      accountService,
      webSessions,
      appleNativeSignIn: new AppleNativeSignIn({
        tokens: appleTokens,
        state,
        accountService,
        identitySubjectKey: secrets.IDENTITY_SUBJECT_KEY,
        audience: IOS_BUNDLE_ID,
      }),
      hasher,
      emailSender: new ResendEmailSender({ apiKey: secrets.RESEND_API_KEY }),
      providerStatusCache: platform.statusCache,
    }).fetch(request);
  }

  return respondWithWebDocument(request, platform.assets, context, {
    document: createWebDocumentPort({
      webSessions,
      state,
      usageState,
      catalog: PRICING_CATALOG,
      modelCatalog: MODEL_CATALOG,
    }),
  });
}
