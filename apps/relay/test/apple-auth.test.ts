import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { IOS_BUNDLE_ID, PROTOCOL_VERSION } from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AppleIdentityTokens } from "../src/account/apple-identity-token.ts";
import { AppleIdentityProvider } from "../src/account/apple-identity.ts";
import { AppleNativeSignIn } from "../src/account/apple-native.ts";
import { GitHubIdentityProvider } from "../src/account/github-identity.ts";
import { SignInHandoff } from "../src/account/identity.ts";
import { AccountService } from "../src/account/service.ts";
import { WebSessions } from "../src/account/web-session.ts";
import { createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
    }
  }
}

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const now = new Date("2026-09-05T00:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const servicesId = "io.gotry.quota.web";
const teamId = "86Y537ZF24";
const keyId = "APPLEKEYID1";
const signingKid = "apple-signing-key";
const appleSubject = "001234.6f9a4c1b2d3e4f5a.0917";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions"),
    env.DB.prepare("DELETE FROM login_grants"),
    env.DB.prepare("DELETE FROM account_identities"),
    env.DB.prepare("DELETE FROM accounts"),
    env.DB.prepare("DELETE FROM rate_limit_counters"),
  ]);
});

describe("browser sign-in through Apple", () => {
  it("carries a cross-site handoff, spends a signed client secret, and opens one Account", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);

    const started = await relay.app.request(`${origin}/api/auth/apple/start`);
    expect(started.status).toBe(302);
    const authorize = new URL(started.headers.get("location") ?? "");
    expect(`${authorize.origin}${authorize.pathname}`).toBe(
      "https://appleid.apple.com/auth/authorize",
    );
    expect(authorize.searchParams.get("client_id")).toBe(servicesId);
    expect(authorize.searchParams.get("redirect_uri")).toBe(`${origin}/api/auth/apple/callback`);
    expect(authorize.searchParams.get("response_type")).toBe("code");
    // Asking for a name or an address is what makes Apple answer with a form POST.
    expect(authorize.searchParams.get("response_mode")).toBe("form_post");
    expect(authorize.searchParams.get("scope")).toBe("name email");
    const nonce = authorize.searchParams.get("nonce") ?? "";
    expect(nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const handoff = onlyCookie(started);
    expect(handoff.name).toBe("__Host-quota_oauth");
    expect(handoff.attributes).toContain("HttpOnly");
    expect(handoff.attributes).toContain("Secure");
    // A browser attaches no `SameSite=Lax` cookie to Apple's cross-site POST, so this one round
    // trip is sealed `None` — and it is still `__Host-`, signed, and ten minutes long.
    expect(handoff.attributes).toContain("SameSite=None");
    expect(handoff.attributes).toContain("Max-Age=600");

    apple.identityClaims = { nonce, email: "quota@privaterelay.appleid.com" };
    const callback = await postCallback(relay, handoff, {
      code: "apple-code",
      state: authorize.searchParams.get("state") ?? "",
      user: '{"name":{"firstName":"Ada"},"email":"quota@privaterelay.appleid.com"}',
    });
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe("/my");
    const cookies = setCookies(callback);
    expect(cookies.get("__Host-quota_session")?.value).toMatch(/^qw_[A-Za-z0-9_-]{43}$/);
    expect(cookies.get("__Host-quota_oauth")?.attributes).toContain("Max-Age=0");

    // The exchange named the Services ID and a client secret Relay signed for this one request.
    expect(apple.tokenForm?.get("client_id")).toBe(servicesId);
    expect(apple.tokenForm?.get("grant_type")).toBe("authorization_code");
    expect(apple.tokenForm?.get("redirect_uri")).toBe(`${origin}/api/auth/apple/callback`);
    const clientSecret = apple.tokenForm?.get("client_secret") ?? "";
    const [header, claims] = clientSecret.split(".").slice(0, 2).map(decodeSegment);
    expect(header).toMatchObject({ alg: "ES256", kid: keyId });
    expect(claims).toMatchObject({
      iss: teamId,
      sub: servicesId,
      aud: "https://appleid.apple.com",
    });
    expect(claims?.exp).toBeGreaterThan(Math.floor(now.getTime() / 1000));

    const account = await env.DB.prepare("SELECT id, display_label FROM accounts").first<{
      id: string;
      display_label: string;
    }>();
    // Apple states an address only while it is shared, and it may be a private relay address.
    expect(account?.display_label).toBe("quota@privaterelay.appleid.com");
    const identity = await env.DB.prepare(
      "SELECT account_id, provider, subject, label FROM account_identities",
    ).first<{ account_id: string; provider: string; subject: string; label: string }>();
    expect(identity).toMatchObject({ account_id: account?.id, provider: "apple" });
    expect(identity?.subject).toMatch(/^[0-9a-f]{64}$/);
    expect(identity?.subject).not.toContain(appleSubject);
  });

  it("names the channel after itself when Apple states no address", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    await signIn(relay, apple, { email: null });
    expect(
      (
        await env.DB.prepare("SELECT display_label FROM accounts").first<{
          display_label: string;
        }>()
      )?.display_label,
    ).toBe("Apple ID");
  });

  it("keeps the address a first sign-in stated when a later one states none", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);

    await signIn(relay, apple, { email: "ada@example.com" });
    expect(await storedLabels()).toEqual({
      account: "ada@example.com",
      identity: "ada@example.com",
    });

    // Apple hands over an address only while it is being shared, so a later sign-in can arrive
    // with nothing but the stand-in. It must not rename the channel.
    await signIn(relay, apple, { email: null });
    expect(await storedLabels()).toEqual({
      account: "ada@example.com",
      identity: "ada@example.com",
    });

    // A real address it does state still replaces the stored one.
    await signIn(relay, apple, { email: "ada@privaterelay.appleid.com" });
    expect(await storedLabels()).toEqual({
      account: "ada@privaterelay.appleid.com",
      identity: "ada@privaterelay.appleid.com",
    });
  });

  it("believes an identity token only when Apple signed exactly this one", async () => {
    for (const [name, damage] of [
      ["another key's signature", { signWithForeignKey: true }],
      ["another app's audience", { audience: "io.gotry.quota.someone-else" }],
      ["a nonce from another round trip", { nonce: "not-the-nonce-this-browser-sent" }],
      ["an expired token", { expiresAt: Math.floor(now.getTime() / 1000) - 1 }],
      ["an issuer that is not Apple", { issuer: "https://appleid.example.com" }],
    ] as const) {
      const apple = await fakeApple();
      const relay = await harness(apple);
      const failed = await signIn(relay, apple, damage);
      expect(failed.status, name).toBe(400);
      expect(
        await env.DB.prepare("SELECT COUNT(*) AS rows FROM accounts").first<{ rows: number }>(),
      ).toMatchObject({ rows: 0 });
    }
  });

  it("refuses a callback that is not the shape Apple posts", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    const started = await relay.app.request(`${origin}/api/auth/apple/start`);
    const handoff = onlyCookie(started);
    const authorize = new URL(started.headers.get("location") ?? "");
    apple.identityClaims = { nonce: authorize.searchParams.get("nonce") ?? "" };
    const state = authorize.searchParams.get("state") ?? "";

    // A redirect is not how Apple answers this provider, and a form POST is not how GitHub does.
    expect(
      (await relay.app.request(`${origin}/api/auth/apple/callback?code=c&state=${state}`)).status,
    ).toBe(404);
    expect(
      (
        await relay.app.request(`${origin}/api/auth/github/callback`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: "code=c",
        })
      ).status,
    ).toBe(404);
    // Apple cancels in the same POST it would have delivered a code in.
    expect((await postCallback(relay, handoff, { error: "user_cancelled_authorize" })).status).toBe(
      400,
    );
    // A key this provider does not name is not part of its callback.
    expect((await postCallback(relay, handoff, { code: "c", state, extra: "x" })).status).toBe(400);
  });

  it("seals SameSite=None for Apple alone", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    const github = onlyCookie(await relay.app.request(`${origin}/api/auth/github/start`));
    expect(github.attributes).toContain("SameSite=Lax");
    expect(github.attributes).not.toContain("SameSite=None");
  });

  it("refuses to bind Apple to a second Account, and changes nothing when it does", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    const firstAccount = await accountIdAfter(signIn(relay, apple, {}));

    // A second browser, signed in as its own Account through GitHub, asks for the same Apple id.
    const github = await signInWithGitHub(relay);
    const started = await relay.app.request(
      `${origin}/api/auth/apple/start?return_to=%2Fmy%2Fsettings&intent=link`,
      { headers: { Cookie: github } },
    );
    expect(started.status).toBe(302);
    const handoff = onlyCookie(started);
    const authorize = new URL(started.headers.get("location") ?? "");
    apple.identityClaims = { nonce: authorize.searchParams.get("nonce") ?? "" };
    const conflict = await postCallback(
      relay,
      handoff,
      { code: "apple-code", state: authorize.searchParams.get("state") ?? "" },
      { Cookie: `${github}; __Host-quota_oauth=${handoff.value}`, Accept: "application/json" },
    );
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toMatchObject({ error: { code: "conflict" } });
    const identities = await env.DB.prepare(
      "SELECT account_id, provider FROM account_identities ORDER BY provider",
    ).all<{ account_id: string; provider: string }>();
    expect(identities.results).toEqual([
      { account_id: firstAccount, provider: "apple" },
      {
        account_id: expect.not.stringMatching(firstAccount) as unknown as string,
        provider: "github",
      },
    ]);
  });
});

describe("Sign in with Apple inside the iOS app", () => {
  it("issues the viewer's one session without a browser round trip", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    const nonce = "quota-native-nonce-value-that-is-long-enough-01";
    apple.identityClaims = { nonce: await sha256Hex(nonce), audience: IOS_BUNDLE_ID };

    const response = await relay.app.request(`${origin}/oauth/v2/apple`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: PROTOCOL_VERSION,
        client_id: "quota-ios",
        identity_token: await apple.identityToken(),
        nonce,
      }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      account_id: string;
      display_label: string | null;
      session: { access_token: string; refresh_token: string };
    };
    expect(body.account_id).toMatch(/^account_[0-9a-f-]{36}$/);
    expect(body.session.access_token).toMatch(/^qia_[A-Za-z0-9_-]{43}$/);
    expect(body.session.refresh_token).toMatch(/^qiar_[A-Za-z0-9_-]{43}$/);
    // Apple never reached the token endpoint: the app had already proved this on the device.
    expect(apple.tokenForm).toBeUndefined();

    const stored = await env.DB.prepare(
      "SELECT client_kind, device_id, scopes_json FROM sessions",
    ).first<Record<string, unknown>>();
    expect(stored).toMatchObject({
      client_kind: "ios",
      device_id: null,
      scopes_json: '["account:read"]',
    });
    // The session it answered with is the one that reads the Account.
    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          headers: { Authorization: `Bearer ${body.session.access_token}` },
        })
      ).status,
    ).toBe(200);

    // The same Apple id signing in again reaches the Account it already opened.
    const again = await nativeSignIn(relay, apple, nonce);
    expect(again.status).toBe(200);
    expect(((await again.json()) as { account_id: string }).account_id).toBe(body.account_id);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS rows FROM accounts").first<{ rows: number }>(),
    ).toMatchObject({ rows: 1 });
  });

  it("refuses a token Apple did not sign for this app, this nonce, and this moment", async () => {
    const nonce = "quota-native-nonce-value-that-is-long-enough-01";
    for (const [name, claims] of [
      ["another key's signature", { signWithForeignKey: true }],
      ["the Services ID's audience", { audience: servicesId }],
      ["the raw nonce rather than its digest", { nonce }],
      ["an expired token", { expiresAt: Math.floor(now.getTime() / 1000) - 1 }],
    ] as const) {
      const apple = await fakeApple();
      const relay = await harness(apple);
      apple.identityClaims = {
        nonce: await sha256Hex(nonce),
        audience: IOS_BUNDLE_ID,
        ...claims,
      };
      const response = await nativeSignIn(relay, apple, nonce, { keepClaims: true });
      expect(response.status, name).toBe(400);
      expect(await response.json()).toMatchObject({ error: { code: "invalid_grant" } });
      expect(
        await env.DB.prepare("SELECT COUNT(*) AS rows FROM sessions").first<{ rows: number }>(),
      ).toMatchObject({ rows: 0 });
    }
  });

  it("binds Apple to the Account the session holding it names, and refuses a taken one", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple);
    const nonce = "quota-native-nonce-value-that-is-long-enough-01";
    const first = (await (await nativeSignIn(relay, apple, nonce)).json()) as {
      account_id: string;
      session: { access_token: string };
    };

    // Binding the same Apple id to the Account it already reaches is what a repeated bind is.
    const repeated = await nativeSignIn(relay, apple, nonce, {
      intent: "link",
      bearer: first.session.access_token,
    });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toMatchObject({ provider: "apple", status: "already_linked" });

    // Another Account's session asking for it is refused, and nothing moves.
    const other = await openIosSessionFor(relay, "account_other_native");
    const conflict = await nativeSignIn(relay, apple, nonce, { intent: "link", bearer: other });
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toMatchObject({ error: { code: "conflict" } });
    expect(
      await env.DB.prepare("SELECT account_id FROM account_identities").first<{
        account_id: string;
      }>(),
    ).toMatchObject({ account_id: first.account_id });

    // A link with no session at all writes nothing either.
    expect((await nativeSignIn(relay, apple, nonce, { intent: "link" })).status).toBe(401);
  });

  it("answers 404 where Apple is not configured", async () => {
    const apple = await fakeApple();
    const relay = await harness(apple, { withNativeApple: false });
    const response = await relay.app.request(`${origin}/oauth/v2/apple`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: PROTOCOL_VERSION,
        client_id: "quota-ios",
        identity_token: await apple.identityToken(),
        nonce: "quota-native-nonce-value-that-is-long-enough-01",
      }),
    });
    expect(response.status).toBe(404);
  });
});

interface IdentityClaimsOverride {
  nonce?: string;
  audience?: string;
  issuer?: string;
  email?: string | null;
  expiresAt?: number;
  signWithForeignKey?: boolean;
}

interface AppleStub {
  fetch: typeof fetch;
  privateKeyPem: string;
  identityClaims: IdentityClaimsOverride;
  identityToken(): Promise<string>;
  tokenForm?: URLSearchParams;
}

/** Apple's keys, its token endpoint, and the identity tokens both flows end in. */
async function fakeApple(): Promise<AppleStub> {
  const signing = (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const foreign = (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const publicJwk = await crypto.subtle.exportKey("jwk", signing.publicKey);
  const clientKey = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", clientKey.privateKey));

  const stub: AppleStub = {
    privateKeyPem: `-----BEGIN PRIVATE KEY-----\n${chunked(base64(pkcs8))}\n-----END PRIVATE KEY-----\n`,
    identityClaims: {},
    async identityToken() {
      const override = stub.identityClaims;
      const header = base64Url(
        new TextEncoder().encode(JSON.stringify({ alg: "RS256", kid: signingKid })),
      );
      const payload = base64Url(
        new TextEncoder().encode(
          JSON.stringify({
            iss: override.issuer ?? "https://appleid.apple.com",
            aud: override.audience ?? servicesId,
            sub: appleSubject,
            exp: override.expiresAt ?? Math.floor(now.getTime() / 1000) + 600,
            iat: Math.floor(now.getTime() / 1000),
            nonce: override.nonce ?? "",
            ...(override.email === null ? {} : { email: override.email ?? "ada@example.com" }),
          }),
        ),
      );
      const signature = await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        override.signWithForeignKey ? foreign.privateKey : signing.privateKey,
        new TextEncoder().encode(`${header}.${payload}`),
      );
      return `${header}.${payload}.${base64Url(new Uint8Array(signature))}`;
    },
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url === "https://appleid.apple.com/auth/keys") {
        return Response.json({
          keys: [
            {
              kty: "RSA",
              alg: "RS256",
              use: "sig",
              kid: signingKid,
              n: publicJwk.n,
              e: publicJwk.e,
            },
          ],
        });
      }
      if (url === "https://appleid.apple.com/auth/token") {
        stub.tokenForm = new URLSearchParams(String(init?.body ?? ""));
        return Response.json({ id_token: await stub.identityToken() });
      }
      throw new Error(`unexpected fetch: ${url}`);
    }) as typeof fetch,
  };
  return stub;
}

async function harness(apple: AppleStub, options: { withNativeApple?: boolean } = {}) {
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const handoff = new SignInHandoff(hasher);
  const tokens = new AppleIdentityTokens({ fetch: apple.fetch });
  const accountService = new AccountService(state, hasher, secret);
  const webSessions = new WebSessions({
    state,
    hasher,
    handoff,
    identitySubjectKey: secret,
    providers: [
      new GitHubIdentityProvider({
        handoff,
        clientId: "github-client",
        clientSecret: "github-secret",
        callbackUrl: `${origin}/api/auth/github/callback`,
        fetch: fakeGitHub(),
      }),
      new AppleIdentityProvider({
        handoff,
        tokens,
        teamId,
        servicesId,
        keyId,
        privateKeyPem: apple.privateKeyPem,
        callbackUrl: `${origin}/api/auth/apple/callback`,
        fetch: apple.fetch,
      }),
    ],
  });
  return {
    accountService,
    app: createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService,
      webSessions,
      ...(options.withNativeApple === false
        ? {}
        : {
            appleNativeSignIn: new AppleNativeSignIn({
              tokens,
              state,
              accountService,
              identitySubjectKey: secret,
              audience: IOS_BUNDLE_ID,
            }),
          }),
      hasher,
      now: () => now,
    }),
  };
}

/** GitHub, for the one Account this file needs that Apple did not open. */
function fakeGitHub(): typeof fetch {
  return (async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url === "https://github.com/login/oauth/access_token") {
      return Response.json({ access_token: "github-access-token" });
    }
    return Response.json({ id: 4_242, login: "octocat" });
  }) as typeof fetch;
}

async function signIn(
  relay: Awaited<ReturnType<typeof harness>>,
  apple: AppleStub,
  claims: IdentityClaimsOverride,
): Promise<Response> {
  const started = await relay.app.request(`${origin}/api/auth/apple/start`);
  const handoff = onlyCookie(started);
  const authorize = new URL(started.headers.get("location") ?? "");
  apple.identityClaims = {
    nonce: authorize.searchParams.get("nonce") ?? "",
    ...claims,
  };
  return postCallback(relay, handoff, {
    code: "apple-code",
    state: authorize.searchParams.get("state") ?? "",
  });
}

async function signInWithGitHub(relay: Awaited<ReturnType<typeof harness>>): Promise<string> {
  const started = await relay.app.request(`${origin}/api/auth/github/start`);
  const handoff = onlyCookie(started);
  const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
  const callback = await relay.app.request(
    `${origin}/api/auth/github/callback?code=github-code&state=${encodeURIComponent(state)}`,
    { headers: { Cookie: `${handoff.name}=${handoff.value}` } },
  );
  const session = setCookies(callback).get("__Host-quota_session");
  return `__Host-quota_session=${session?.value}`;
}

async function postCallback(
  relay: Awaited<ReturnType<typeof harness>>,
  handoff: ParsedCookie,
  form: Record<string, string>,
  headers: Record<string, string> = {},
): Promise<Response> {
  return relay.app.request(`${origin}/api/auth/apple/callback`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Cookie: `${handoff.name}=${handoff.value}`,
      ...headers,
    },
    body: new URLSearchParams(form).toString(),
  });
}

async function nativeSignIn(
  relay: Awaited<ReturnType<typeof harness>>,
  apple: AppleStub,
  nonce: string,
  options: { intent?: "link"; bearer?: string; keepClaims?: boolean } = {},
): Promise<Response> {
  if (!options.keepClaims) {
    apple.identityClaims = { nonce: await sha256Hex(nonce), audience: IOS_BUNDLE_ID };
  }
  return relay.app.request(`${origin}/oauth/v2/apple`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(options.bearer ? { Authorization: `Bearer ${options.bearer}` } : {}),
    },
    body: JSON.stringify({
      protocol_version: PROTOCOL_VERSION,
      client_id: "quota-ios",
      identity_token: await apple.identityToken(),
      nonce,
      ...(options.intent ? { intent: options.intent } : {}),
    }),
  });
}

/** An iOS session on an Account of its own, for the refusal a taken identity is. */
async function openIosSessionFor(
  relay: Awaited<ReturnType<typeof harness>>,
  accountId: string,
): Promise<string> {
  await env.DB.prepare(
    "INSERT INTO accounts (id, display_label, created_at, updated_at) VALUES (?1, 'Other', ?2, ?2)",
  )
    .bind(accountId, now.toISOString())
    .run();
  await env.DB.prepare(
    `INSERT INTO account_identities (account_id, provider, subject, label, created_at)
     VALUES (?1, 'github', 'other-subject', 'other', ?2)`,
  )
    .bind(accountId, now.toISOString())
    .run();
  const issued = await relay.accountService.openIosSession(accountId, "Other", now);
  return issued.session.access_token;
}

async function storedLabels(): Promise<{ account: string | null; identity: string | null }> {
  const account = await env.DB.prepare("SELECT display_label FROM accounts").first<{
    display_label: string | null;
  }>();
  const identity = await env.DB.prepare(
    "SELECT label FROM account_identities WHERE provider = 'apple'",
  ).first<{ label: string | null }>();
  return { account: account?.display_label ?? null, identity: identity?.label ?? null };
}

async function accountIdAfter(response: Promise<Response>): Promise<string> {
  expect((await response).status).toBe(302);
  const account = await env.DB.prepare("SELECT id FROM accounts").first<{ id: string }>();
  return account?.id ?? "";
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function decodeSegment(segment: string): Record<string, number & string> | undefined {
  const normalized = segment.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(`${normalized}${"=".repeat((4 - (normalized.length % 4)) % 4)}`);
  return JSON.parse(
    new TextDecoder().decode(Uint8Array.from(binary, (character) => character.charCodeAt(0))),
  );
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64Url(bytes: Uint8Array): string {
  return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function chunked(value: string): string {
  return (value.match(/.{1,64}/g) ?? []).join("\n");
}

interface ParsedCookie {
  name: string;
  value: string;
  attributes: string;
}

function setCookies(response: Response): Map<string, ParsedCookie> {
  const jar = new Map<string, ParsedCookie>();
  for (const raw of response.headers.getSetCookie()) {
    const separator = raw.indexOf(";");
    const pair = separator < 0 ? raw : raw.slice(0, separator);
    const equals = pair.indexOf("=");
    const name = pair.slice(0, equals).trim();
    jar.set(name, {
      name,
      value: pair.slice(equals + 1).trim(),
      attributes: separator < 0 ? "" : raw.slice(separator + 1),
    });
  }
  return jar;
}

function onlyCookie(response: Response): ParsedCookie {
  const cookies = [...setCookies(response).values()];
  expect(cookies).toHaveLength(1);
  const cookie = cookies[0];
  if (!cookie) throw new Error("response set no cookie");
  return cookie;
}
