import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  IOS_OAUTH_CLIENT_ID,
  IOS_OAUTH_REDIRECT_URI,
  type IosOAuthTokenResponse,
  IosOAuthTokenResponseSchema,
  type OAuthTokenResponse,
  OAuthTokenResponseSchema,
  IosSessionRefreshResponseSchema,
} from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";

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

const now = new Date("2026-08-10T00:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
let harnessSequence = 0;

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("quota-ios read-only account client", () => {
  it("rejects exact client and redirect mismatches before GitHub", async () => {
    const harness = await createHarness();
    const { challenge } = await pkcePair();
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(302);

    expect(
      (
        await authorize(harness, {
          client_id: "unknown-client",
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: "http://127.0.0.1:43210/callback",
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: "io.gotry.quota://oauth/callback",
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await authorize(harness, {
          client_id: "quotabar",
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(400);
  });

  it("rejects invalid PKCE and state on authorize", async () => {
    const harness = await createHarness();
    const { challenge } = await pkcePair();
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "short-state",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
          code_challenge_method: "plain",
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: "short-challenge",
        })
      ).status,
    ).toBe(400);
  });

  it("exchanges an account session without creating a Device", async () => {
    const harness = await createHarness();
    const { verifier, challenge } = await pkcePair();
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(302);

    const complete = await harness.app.request(harness.callbackURL);
    expect(complete.status).toBe(302);
    const location = complete.headers.get("location") ?? "";
    expect(location.startsWith(`${IOS_OAUTH_REDIRECT_URI}?`)).toBe(true);
    const redirected = new URL(location);
    expect(redirected.searchParams.get("state")).toBe("client-state-123456789");
    const code = redirected.searchParams.get("code");
    expect(code).toBeTruthy();

    const exchanged = await exchangeIos(harness, { code: code ?? "", code_verifier: verifier });
    expect(exchanged.status).toBe(200);
    const tokens = IosOAuthTokenResponseSchema.parse(await exchanged.json());
    expect(tokens.account_id).toBe(harness.accountId);
    // The exchange names the Account it signed in to; it still names no Device.
    expect(tokens.display_label).toBe("iOS Tester");
    expect(
      await env.DB.prepare("SELECT display_label FROM accounts WHERE id = ?1")
        .bind(harness.accountId)
        .first("display_label"),
    ).toBe(tokens.display_label);
    expect(Object.keys(tokens).sort()).toEqual([
      "account_id",
      "display_label",
      "protocol_version",
      "session",
      "token_type",
    ]);
    expect(tokens.session.access_token).toMatch(/^qia_/);
    expect(tokens.session.refresh_token).toMatch(/^qiar_/);
    expect(tokens.session.access_token).not.toMatch(/^qb_/);
    expect(tokens.session.refresh_token).not.toMatch(/^qbr_/);
    expect(OAuthTokenResponseSchema.safeParse(tokens).success).toBe(false);
    expect(JSON.stringify(tokens)).not.toContain("device_id");
    expect(JSON.stringify(tokens)).not.toContain("installation");

    expect(await deviceCount(harness.accountId)).toBe(0);
    expect(await deviceSessionCount(harness.accountId)).toBe(0);
    expect(
      await env.DB.prepare("SELECT device_id FROM sessions WHERE account_id = ?1")
        .bind(harness.accountId)
        .first("device_id"),
    ).toBeNull();

    const summary = await harness.app.request("https://quota.gotry.io/api/v6/account/summary", {
      headers: { Authorization: `Bearer ${tokens.session.access_token}` },
    });
    expect(summary.status).toBe(200);
    const body = (await summary.json()) as { devices: unknown[] };
    expect(body.devices).toEqual([]);
  });

  it("rejects device fields, a wrong verifier, and replay", async () => {
    const harness = await createHarness();
    const { verifier, challenge } = await pkcePair();
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(302);
    const complete = await harness.app.request(harness.callbackURL);
    const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
    expect(code).toBeTruthy();

    const withDeviceFields = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "authorization_code",
        client_id: IOS_OAUTH_CLIENT_ID,
        code,
        code_verifier: verifier,
        redirect_uri: IOS_OAUTH_REDIRECT_URI,
        installation_id: "4a7f950d-89ea-4f64-a7c1-b4aeb46a67f8",
        device_display_name: "iPhone",
        platform: "ios",
      }),
    });
    expect(withDeviceFields.status).toBe(400);
    expect(await withDeviceFields.json()).toMatchObject({ error: { code: "invalid_request" } });

    const wrongVerifier = await exchangeIos(harness, {
      code: code ?? "",
      code_verifier: "b".repeat(43),
    });
    expect(wrongVerifier.status).toBe(400);
    const wrongBody = await wrongVerifier.json();
    expect(wrongBody).toMatchObject({ error: { code: "invalid_grant" } });
    expect(JSON.stringify(wrongBody)).not.toContain(code);
    expect(JSON.stringify(wrongBody)).not.toContain(verifier);

    const first = await exchangeIos(harness, { code: code ?? "", code_verifier: verifier });
    expect(first.status).toBe(200);
    const replay = await exchangeIos(harness, { code: code ?? "", code_verifier: verifier });
    expect(replay.status).toBe(400);
    expect(await replay.json()).toMatchObject({ error: { code: "invalid_grant" } });
    expect(await deviceCount(harness.accountId)).toBe(0);
  });

  it("rejects an expired authorization code without creating a Device", async () => {
    const harness = await createHarness();
    const { verifier, challenge } = await pkcePair();
    expect(
      (
        await authorize(harness, {
          client_id: IOS_OAUTH_CLIENT_ID,
          redirect_uri: IOS_OAUTH_REDIRECT_URI,
          state: "client-state-123456789",
          code_challenge: challenge,
        })
      ).status,
    ).toBe(302);
    const complete = await harness.app.request(harness.callbackURL);
    const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
    harness.checkedAt = new Date(now.getTime() + 11 * 60 * 1000);
    const expiredExchange = await exchangeIos(harness, {
      code: code ?? "",
      code_verifier: verifier,
    });
    expect(expiredExchange.status).toBe(400);
    expect(await expiredExchange.json()).toMatchObject({ error: { code: "invalid_grant" } });
    expect(await deviceCount(harness.accountId)).toBe(0);
  });

  it("rotates account refresh tokens and revokes the family", async () => {
    const harness = await createHarness();
    const tokens = await loginIos(harness);

    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${tokens.session.access_token}` },
        })
      ).status,
    ).toBe(200);

    // A refresh request naming a token audience is a request from a build that still thinks
    // there are two, and there is no field for it to name.
    const audienced = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: tokens.session.refresh_token,
      }),
    });
    expect(audienced.status).toBe(400);
    expect(await audienced.json()).toMatchObject({ error: { code: "invalid_request" } });

    const refreshed = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        refresh_token: tokens.session.refresh_token,
      }),
    });
    expect(refreshed.status).toBe(200);
    const rotated = IosSessionRefreshResponseSchema.parse(await refreshed.json());
    expect(rotated.session.access_token).not.toBe(tokens.session.access_token);
    expect(rotated.session.refresh_token).not.toBe(tokens.session.refresh_token);
    expect(rotated.session.access_token).toMatch(/^qia_/);
    expect(rotated.session.refresh_token).toMatch(/^qiar_/);
    expect("device_id" in rotated).toBe(false);

    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${tokens.session.access_token}` },
        })
      ).status,
    ).toBe(401);
    // The replaced token stays usable until the successor is spent. Spend it at a later
    // instant so last_used_at moves off rotated_at.
    harness.checkedAt = new Date(now.getTime() + 1_000);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${rotated.session.access_token}` },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            protocol_version: 2,
            grant_type: "refresh_token",
            client_id: IOS_OAUTH_CLIENT_ID,
            refresh_token: tokens.session.refresh_token,
          }),
        })
      ).status,
    ).toBe(400);

    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${rotated.session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${rotated.session.access_token}` },
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            protocol_version: 2,
            grant_type: "refresh_token",
            client_id: IOS_OAUTH_CLIENT_ID,
            refresh_token: rotated.session.refresh_token,
          }),
        })
      ).status,
    ).toBe(400);
  });

  it("rejects refresh tokens presented to the other public client", async () => {
    const harness = await createHarness();
    const iosTokens = await loginIos(harness);
    const barTokens = await loginQuotabar(harness);
    const refresh = (clientId: string, refreshToken: string) =>
      harness.app.request("https://quota.gotry.io/oauth/v2/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          protocol_version: 2,
          grant_type: "refresh_token",
          client_id: clientId,
          refresh_token: refreshToken,
        }),
      });

    // One table holds both, and the token's own shape is what keeps them apart.
    const iosAsBar = await refresh("quotabar", iosTokens.session.refresh_token);
    expect(iosAsBar.status).toBe(400);
    expect(await iosAsBar.json()).toMatchObject({ error: { code: "invalid_grant" } });
    const barAsIos = await refresh(IOS_OAUTH_CLIENT_ID, barTokens.session.refresh_token);
    expect(barAsIos.status).toBe(400);
    expect(await barAsIos.json()).toMatchObject({ error: { code: "invalid_grant" } });

    expect((await refresh(IOS_OAUTH_CLIENT_ID, iosTokens.session.refresh_token)).status).toBe(200);
    expect((await refresh("quotabar", barTokens.session.refresh_token)).status).toBe(200);
  });

  it("cannot write snapshots or Usage and cannot call Web-only routes", async () => {
    const harness = await createHarness();
    const tokens = await loginIos(harness);
    const headers = {
      Authorization: `Bearer ${tokens.session.access_token}`,
      "Content-Type": "application/json",
    };

    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v6/device/snapshots", {
          method: "PUT",
          headers,
          body: JSON.stringify({}),
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v6/device/usage", {
          method: "PUT",
          headers,
          body: JSON.stringify({}),
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/device/sync", {
          headers,
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account/devices/device_missing", {
          method: "DELETE",
          headers: {
            ...headers,
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
        })
      ).status,
    ).toBe(403);
    // The viewer's token reads the Account it was issued for and nothing else.
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers,
        })
      ).status,
    ).toBe(200);
  });

  it("keeps the QuotaBar loopback exchange working beside the viewer", async () => {
    const harness = await createHarness();
    const { verifier, challenge } = await pkcePair();
    const authorizeUrl = new URL("https://quota.gotry.io/oauth/v2/authorize");
    authorizeUrl.search = new URLSearchParams({
      response_type: "code",
      client_id: "quotabar",
      redirect_uri: "http://127.0.0.1:43210/callback",
      state: "client-state-123456789",
      code_challenge: challenge,
      code_challenge_method: "S256",
    }).toString();
    expect((await harness.app.request(authorizeUrl)).status).toBe(302);
    const complete = await harness.app.request(harness.callbackURL);
    expect(complete.status).toBe(302);
    const location = complete.headers.get("location") ?? "";
    expect(location.startsWith("http://127.0.0.1:43210/callback?")).toBe(true);
    const code = new URL(location).searchParams.get("code");

    const exchanged = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "authorization_code",
        client_id: "quotabar",
        code,
        code_verifier: verifier,
        redirect_uri: "http://127.0.0.1:43210/callback",
        installation_id: "4a7f950d-89ea-4f64-a7c1-b4aeb46a67f8",
        device_display_name: "Test Mac",
        platform: "macos",
      }),
    });
    expect(exchanged.status).toBe(200);
    const tokens = (await exchanged.json()) as OAuthTokenResponse;
    expect(OAuthTokenResponseSchema.parse(tokens)).toEqual(tokens);
    expect(tokens.device_generation).toBe(1);
    expect(tokens.session.access_token).toMatch(/^qb_/);
    expect(tokens.session.refresh_token).toMatch(/^qbr_/);
    expect(tokens.session.access_token).not.toMatch(/^qia_/);
    expect(tokens.session.refresh_token).not.toMatch(/^qiar_/);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);

    const iosAfterCli = await loginIos(harness);
    expect(IosOAuthTokenResponseSchema.parse(iosAfterCli).account_id).toBe(harness.accountId);
    expect(await deviceCount(harness.accountId)).toBe(1);
    const summary = await harness.app.request("https://quota.gotry.io/api/v6/account/summary", {
      headers: { Authorization: `Bearer ${iosAfterCli.session.access_token}` },
    });
    const body = (await summary.json()) as { devices: { id: string; platform: string }[] };
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0]?.id).toBe(tokens.device_id);
    expect(body.devices[0]?.platform).toBe("macos");
    expect(body.devices.some((device) => device.platform === "ios")).toBe(false);
  });
});

interface TestHarness {
  app: ReturnType<typeof createRelayApp>;
  accountId: string;
  callbackURL: string;
  checkedAt: Date;
}

async function createHarness(): Promise<TestHarness> {
  harnessSequence += 1;
  const accountId = `ios_account_${harnessSequence}`;
  await env.DB.prepare(
    `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
     VALUES (?1, ?1, 'iOS Tester', ?2, ?2)`,
  )
    .bind(accountId, now.toISOString())
    .run();
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const checked = { at: now };
  const webSessions = new SignedInWebSessionStub(accountId, now);
  const app = createRelayApp({
    state,
    usageState: new D1UsageState(env.DB),
    accountService: new AccountService(state, hasher, secret),
    webSessions,
    hasher,
    now: () => checked.at,
  });
  return {
    app,
    accountId,
    get callbackURL() {
      return `https://quota.gotry.io${webSessions.returnTo}`;
    },
    get checkedAt() {
      return checked.at;
    },
    set checkedAt(value: Date) {
      checked.at = value;
    },
  };
}

async function loginQuotabar(harness: TestHarness): Promise<OAuthTokenResponse> {
  const { verifier, challenge } = await pkcePair();
  const authorizeUrl = new URL("https://quota.gotry.io/oauth/v2/authorize");
  authorizeUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: "quotabar",
    redirect_uri: "http://127.0.0.1:43210/callback",
    state: "client-state-123456789",
    code_challenge: challenge,
    code_challenge_method: "S256",
  }).toString();
  expect((await harness.app.request(authorizeUrl)).status).toBe(302);
  const complete = await harness.app.request(harness.callbackURL);
  expect(complete.status).toBe(302);
  const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
  const exchanged = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: "quotabar",
      code,
      code_verifier: verifier,
      redirect_uri: "http://127.0.0.1:43210/callback",
      installation_id: "4a7f950d-89ea-4f64-a7c1-b4aeb46a67f8",
      device_display_name: "Test Mac",
      platform: "macos",
    }),
  });
  expect(exchanged.status).toBe(200);
  return OAuthTokenResponseSchema.parse(await exchanged.json());
}

async function loginIos(harness: TestHarness): Promise<IosOAuthTokenResponse> {
  const { verifier, challenge } = await pkcePair();
  expect(
    (
      await authorize(harness, {
        client_id: IOS_OAUTH_CLIENT_ID,
        redirect_uri: IOS_OAUTH_REDIRECT_URI,
        state: "client-state-123456789",
        code_challenge: challenge,
      })
    ).status,
  ).toBe(302);
  const complete = await harness.app.request(harness.callbackURL);
  expect(complete.status).toBe(302);
  const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
  const exchanged = await exchangeIos(harness, { code: code ?? "", code_verifier: verifier });
  expect(exchanged.status).toBe(200);
  return IosOAuthTokenResponseSchema.parse(await exchanged.json());
}

async function authorize(
  harness: TestHarness,
  input: {
    client_id: string;
    redirect_uri: string;
    state: string;
    code_challenge: string;
    code_challenge_method?: string;
  },
) {
  const url = new URL("https://quota.gotry.io/oauth/v2/authorize");
  url.search = new URLSearchParams({
    response_type: "code",
    client_id: input.client_id,
    redirect_uri: input.redirect_uri,
    state: input.state,
    code_challenge: input.code_challenge,
    code_challenge_method: input.code_challenge_method ?? "S256",
  }).toString();
  return harness.app.request(url);
}

async function exchangeIos(harness: TestHarness, input: { code: string; code_verifier: string }) {
  return harness.app.request("https://quota.gotry.io/oauth/v2/token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: IOS_OAUTH_CLIENT_ID,
      code: input.code,
      code_verifier: input.code_verifier,
      redirect_uri: IOS_OAUTH_REDIRECT_URI,
    }),
  });
}

async function deviceCount(accountId: string) {
  return env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE account_id = ?1")
    .bind(accountId)
    .first("count");
}

async function deviceSessionCount(accountId: string) {
  return env.DB.prepare(
    "SELECT COUNT(*) AS count FROM sessions WHERE account_id = ?1 AND device_id IS NOT NULL",
  )
    .bind(accountId)
    .first("count");
}

async function pkcePair() {
  const verifier = "a".repeat(43);
  const challengeBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(challengeBuffer)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
  return { verifier, challenge };
}
