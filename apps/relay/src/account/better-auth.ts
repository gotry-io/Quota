import { betterAuth } from "better-auth";
import { CANONICAL_ORIGIN } from "../config.ts";
import { hmacSha256Hex } from "../security.ts";
import { D1EncryptedAuthStorage } from "./better-auth-storage.ts";

const webSessionSeconds = 90 * 24 * 60 * 60;
const recentAuthenticationSeconds = 10 * 60;

export interface WebAccountSession {
  user: { id: string; name: string };
  session: { id: string; createdAt: Date; expiresAt: Date };
}

export interface WebAccountAuth {
  handler(request: Request): Promise<Response>;
  beginGitHubSignIn(headers: Headers, callbackURL: string): Promise<Response>;
  getSession(headers: Headers): Promise<WebAccountSession | null>;
}

export interface BetterAuthEnvironment {
  database: D1Database;
  githubClientId: string;
  githubClientSecret: string;
  githubSubjectKey: string;
  authSecret: string;
  origin?: string;
  fetch?: typeof fetch;
}

export function createWebAccountAuth(environment: BetterAuthEnvironment): WebAccountAuth {
  const origin = environment.origin ?? CANONICAL_ORIGIN;
  const githubFetch = environment.fetch ?? fetch;
  const auth = betterAuth({
    appName: "Quota",
    baseURL: origin,
    basePath: "/api/auth/v2",
    secret: environment.authSecret,
    database: environment.database,
    secondaryStorage: new D1EncryptedAuthStorage(environment.database, environment.authSecret),
    emailAndPassword: { enabled: false },
    socialProviders: {
      github: {
        clientId: environment.githubClientId,
        clientSecret: environment.githubClientSecret,
        disableDefaultScope: true,
        scope: [],
        getUserInfo: async (tokens) => {
          if (!tokens.accessToken) return null;
          const response = await githubFetch("https://api.github.com/user", {
            headers: {
              Accept: "application/vnd.github+json",
              Authorization: `Bearer ${tokens.accessToken}`,
              "User-Agent": "QuotaRelay",
              "X-GitHub-Api-Version": "2022-11-28",
            },
            signal: AbortSignal.timeout(20_000),
          });
          if (!response.ok) return null;
          const profile = await readBoundedJSON(response);
          if (typeof profile.id !== "number" || !Number.isSafeInteger(profile.id)) return null;
          const subject = await hmacSha256Hex(environment.githubSubjectKey, `github:${profile.id}`);
          const label =
            typeof profile.name === "string" && profile.name.trim()
              ? profile.name.trim().slice(0, 64)
              : typeof profile.login === "string" && profile.login.trim()
                ? profile.login.trim().slice(0, 64)
                : "GitHub account";
          return {
            user: {
              id: subject,
              name: label,
              email: `${subject}@users.invalid`,
              emailVerified: false,
            },
            data: {},
          };
        },
      },
    },
    user: { modelName: "auth_users", deleteUser: { enabled: true } },
    session: {
      modelName: "auth_sessions",
      expiresIn: webSessionSeconds,
      updateAge: 15 * 60,
      freshAge: recentAuthenticationSeconds,
      storeSessionInDatabase: false,
    },
    account: {
      modelName: "auth_identities",
      updateAccountOnSignIn: false,
      encryptOAuthTokens: true,
      accountLinking: {
        enabled: false,
      },
    },
    verification: {
      modelName: "auth_verifications",
      storeIdentifier: "hashed",
    },
    rateLimit: {
      enabled: true,
      storage: "database",
      modelName: "auth_rate_limits",
    },
    trustedOrigins: [origin],
    advanced: {
      useSecureCookies: true,
      cookiePrefix: "quota",
      database: { generateId: "uuid" },
      ipAddress: { ipAddressHeaders: ["cf-connecting-ip"] },
    },
    databaseHooks: {
      user: {
        create: {
          after: async (user) => {
            await upsertDomainAccount(environment.database, user.id, user.name, user.createdAt);
          },
        },
        update: {
          after: async (user) => {
            await upsertDomainAccount(environment.database, user.id, user.name, user.createdAt);
          },
        },
        delete: {
          after: async (user) => {
            await environment.database
              .prepare("DELETE FROM accounts WHERE id = ?1")
              .bind(user.id)
              .run();
          },
        },
      },
      account: {
        create: { before: async (account) => ({ data: withoutProviderTokens(account) }) },
        update: { before: async (account) => ({ data: withoutProviderTokens(account) }) },
      },
    },
  });

  return {
    handler: (request) => auth.handler(request),
    beginGitHubSignIn: async (headers, callbackURL) =>
      await auth.api.signInSocial({
        body: { provider: "github", callbackURL },
        headers,
        asResponse: true,
      }),
    getSession: async (headers) => {
      const session = await auth.api.getSession({ headers });
      if (!session) return null;
      await upsertDomainAccount(
        environment.database,
        session.user.id,
        session.user.name,
        session.user.createdAt,
      );
      return {
        user: { id: session.user.id, name: session.user.name },
        session: {
          id: session.session.id,
          createdAt: session.session.createdAt,
          expiresAt: session.session.expiresAt,
        },
      };
    },
  };
}

async function readBoundedJSON(response: Response): Promise<Record<string, unknown>> {
  const maximumBytes = 1024 * 1024;
  const reader = response.body?.getReader();
  if (!reader) return {};
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumBytes) {
      await reader.cancel();
      return {};
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : {};
}

function withoutProviderTokens<Account extends Record<string, unknown>>(account: Account): Account {
  return {
    ...account,
    accessToken: null,
    refreshToken: null,
    idToken: null,
    accessTokenExpiresAt: null,
    refreshTokenExpiresAt: null,
    scope: null,
  };
}

async function upsertDomainAccount(
  database: D1Database,
  id: string,
  displayLabel: string,
  createdAt: Date,
): Promise<void> {
  const timestamp = createdAt.toISOString();
  await database
    .prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES (?1, ?1, ?2, ?3, ?3)
       ON CONFLICT(id) DO UPDATE SET
         display_label = excluded.display_label,
         updated_at = excluded.updated_at`,
    )
    .bind(id, displayLabel.slice(0, 64), timestamp)
    .run();
}
