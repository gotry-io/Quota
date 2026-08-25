import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  IOS_OAUTH_CLIENT_ID,
  IOS_OAUTH_REDIRECT_URI,
  type IosOAuthTokenResponse,
  IosOAuthTokenResponseSchema,
  type OAuthTokenResponse,
  OAuthTokenResponseSchema,
  SessionRefreshResponseSchema,
} from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, inject, it } from "vitest";
import type { WebAccountAuth } from "../src/account/better-auth.ts";
import { AccountService } from "../src/account/service.ts";
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
          client_id: "quotacli",
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
    expect(Object.keys(tokens).sort()).toEqual([
      "account_id",
      "account_session",
      "protocol_version",
      "token_type",
    ]);
    expect(tokens.account_session.access_token).toMatch(/^qia_/);
    expect(tokens.account_session.refresh_token).toMatch(/^qiar_/);
    expect(tokens.account_session.access_token).not.toMatch(/^qa_/);
    expect(tokens.account_session.refresh_token).not.toMatch(/^qar_/);
    expect(OAuthTokenResponseSchema.safeParse(tokens).success).toBe(false);
    expect(JSON.stringify(tokens)).not.toContain("device_id");
    expect(JSON.stringify(tokens)).not.toContain("device_session");
    expect(JSON.stringify(tokens)).not.toContain("installation");

    expect(await deviceCount(harness.accountId)).toBe(0);
    expect(await deviceSessionCount(harness.accountId)).toBe(0);
    expect(
      await env.DB.prepare("SELECT device_id FROM account_sessions WHERE account_id = ?1")
        .bind(harness.accountId)
        .first("device_id"),
    ).toBeNull();

    const summary = await harness.app.request("https://quota.gotry.io/api/v5/account/summary", {
      headers: { Authorization: `Bearer ${tokens.account_session.access_token}` },
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
          headers: { Authorization: `Bearer ${tokens.account_session.access_token}` },
        })
      ).status,
    ).toBe(200);

    const deviceRefresh = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "device",
        refresh_token: tokens.account_session.refresh_token,
      }),
    });
    expect(deviceRefresh.status).toBe(400);
    expect(await deviceRefresh.json()).toMatchObject({ error: { code: "invalid_request" } });

    const refreshed = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: tokens.account_session.refresh_token,
      }),
    });
    expect(refreshed.status).toBe(200);
    const rotated = SessionRefreshResponseSchema.parse(await refreshed.json());
    expect(rotated.token_audience).toBe("account");
    if (rotated.token_audience !== "account") {
      throw new Error("expected account refresh");
    }
    expect(rotated.account_session.access_token).not.toBe(tokens.account_session.access_token);
    expect(rotated.account_session.refresh_token).not.toBe(tokens.account_session.refresh_token);
    expect(rotated.account_session.access_token).toMatch(/^qia_/);
    expect(rotated.account_session.refresh_token).toMatch(/^qiar_/);
    expect("device_session" in rotated).toBe(false);

    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${tokens.account_session.access_token}` },
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
            token_audience: "account",
            refresh_token: tokens.account_session.refresh_token,
          }),
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${rotated.account_session.access_token}` },
        })
      ).status,
    ).toBe(200);

    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${rotated.account_session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account", {
          headers: { Authorization: `Bearer ${rotated.account_session.access_token}` },
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
            token_audience: "account",
            refresh_token: rotated.account_session.refresh_token,
          }),
        })
      ).status,
    ).toBe(400);
  });

  it("rejects refresh tokens presented to the other public client", async () => {
    const harness = await createHarness();
    const iosTokens = await loginIos(harness);
    const cliTokens = await loginQuotacli(harness);

    const iosAsCli = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: "quotacli",
        token_audience: "account",
        refresh_token: iosTokens.account_session.refresh_token,
      }),
    });
    expect(iosAsCli.status).toBe(400);
    expect(await iosAsCli.json()).toMatchObject({ error: { code: "invalid_grant" } });

    const cliAsIos = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: cliTokens.account_session.refresh_token,
      }),
    });
    expect(cliAsIos.status).toBe(400);
    expect(await cliAsIos.json()).toMatchObject({ error: { code: "invalid_grant" } });

    const iosStillValid = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: iosTokens.account_session.refresh_token,
      }),
    });
    expect(iosStillValid.status).toBe(200);
    const cliStillValid = await harness.app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: "quotacli",
        token_audience: "account",
        refresh_token: cliTokens.account_session.refresh_token,
      }),
    });
    expect(cliStillValid.status).toBe(200);
  });

  it("cannot write snapshots or Usage and cannot call Web-only routes", async () => {
    const harness = await createHarness();
    const tokens = await loginIos(harness);
    const headers = {
      Authorization: `Bearer ${tokens.account_session.access_token}`,
      "Content-Type": "application/json",
    };

    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v5/device/snapshots", {
          method: "PUT",
          headers,
          body: JSON.stringify({}),
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v5/device/usage", {
          method: "PUT",
          headers,
          body: JSON.stringify({}),
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v5/device/health", {
          method: "PUT",
          headers,
          body: JSON.stringify({}),
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/device/sync", {
          headers,
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/device/logout", {
          method: "POST",
          headers,
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: {
            ...headers,
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: JSON.stringify({
            protocol_version: 2,
            user_code: "ABCD-EFGH",
            decision: "approve",
          }),
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
    expect(
      (
        await harness.app.request("https://quota.gotry.io/api/v2/account/public-profile", {
          method: "PUT",
          headers: {
            ...headers,
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: JSON.stringify({ protocol_version: 2, enabled: true }),
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await harness.app.request("https://quota.gotry.io/oauth/v2/device/code", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            protocol_version: 2,
            client_id: IOS_OAUTH_CLIENT_ID,
            installation_id: "dd4e60c6-fd44-4ac4-ad1f-28f2eeb52ca1",
            device_display_name: "iPhone",
            platform: "ios",
          }),
        })
      ).status,
    ).toBe(400);
  });

  it("keeps the released quotacli loopback exchange byte-compatible", async () => {
    const harness = await createHarness();
    const { verifier, challenge } = await pkcePair();
    const authorizeUrl = new URL("https://quota.gotry.io/oauth/v2/authorize");
    authorizeUrl.search = new URLSearchParams({
      response_type: "code",
      client_id: "quotacli",
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
        client_id: "quotacli",
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
    expect(tokens.account_session.access_token).toMatch(/^qa_/);
    expect(tokens.account_session.refresh_token).toMatch(/^qar_/);
    expect(tokens.device_session.access_token).toMatch(/^qd_/);
    expect(tokens.device_session.refresh_token).toMatch(/^qdr_/);
    expect(tokens.account_session.access_token).not.toMatch(/^qia_/);
    expect(tokens.account_session.refresh_token).not.toMatch(/^qiar_/);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);

    const iosAfterCli = await loginIos(harness);
    expect(IosOAuthTokenResponseSchema.parse(iosAfterCli).account_id).toBe(harness.accountId);
    expect(await deviceCount(harness.accountId)).toBe(1);
    const summary = await harness.app.request("https://quota.gotry.io/api/v5/account/summary", {
      headers: { Authorization: `Bearer ${iosAfterCli.account_session.access_token}` },
    });
    const body = (await summary.json()) as { devices: { device_id: string; platform: string }[] };
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0]?.device_id).toBe(tokens.device_id);
    expect(body.devices[0]?.platform).toBe("macos");
    expect(body.devices.some((device) => device.platform === "ios")).toBe(false);
  });

  it("carries health on every summary Device, refreshes same-revision health, ignores older revisions, and cascades deletion", async () => {
    const harness = await createHarness();
    const device = await loginQuotacli(harness);
    const ios = await loginIos(harness);
    const accountHeaders = { Authorization: `Bearer ${ios.account_session.access_token}` };

    const optedBefore = (await (
      await harness.app.request("https://quota.gotry.io/api/v5/account/summary", {
        headers: accountHeaders,
      })
    ).json()) as { devices: Array<{ health: unknown }> };
    expect(optedBefore.devices[0]?.health).toBeNull();

    const healthy = {
      protocol_version: 5,
      schema_version: 1,
      client_product: "quotacli",
      client_version: "0.0.16",
      platform: "macos",
      observed_at: harness.checkedAt.toISOString(),
      refresh_revision: 9,
      last_completed_refresh_at: harness.checkedAt.toISOString(),
      last_successful_account_sync_at: null,
      summary: { operation: "healthy", data: "empty", attention: "none" },
      top_code: null,
      consecutive_failures: 0,
      usage_upload_enabled: false,
    };
    const upload = await harness.app.request("https://quota.gotry.io/api/v5/device/health", {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${device.device_session.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(healthy),
    });
    expect(upload.status).toBe(200);
    expect(await upload.json()).toEqual({
      protocol_version: 5,
      status: "updated",
      received_at: harness.checkedAt.toISOString(),
      fresh_until: new Date(harness.checkedAt.getTime() + 20 * 60_000).toISOString(),
    });

    const optedAfter = (await (
      await harness.app.request("https://quota.gotry.io/api/v5/account/summary", {
        headers: accountHeaders,
      })
    ).json()) as {
      devices: Array<{ device_id: string; health: Record<string, unknown> | null }>;
    };
    expect(optedAfter.devices[0]).toMatchObject({
      device_id: device.device_id,
      health: {
        client_product: "quotacli",
        client_version: "0.0.16",
        refresh_revision: 9,
        received_at: harness.checkedAt.toISOString(),
        usage_upload_enabled: false,
        summary: { operation: "healthy", data: "empty", attention: "none" },
      },
    });

    harness.checkedAt = new Date(harness.checkedAt.getTime() + 30_000);
    const heartbeat = await harness.app.request("https://quota.gotry.io/api/v5/device/health", {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${device.device_session.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        ...healthy,
        observed_at: harness.checkedAt.toISOString(),
        client_version: "0.0.17",
      }),
    });
    expect(heartbeat.status).toBe(200);
    expect(await heartbeat.json()).toEqual({
      protocol_version: 5,
      status: "updated",
      received_at: harness.checkedAt.toISOString(),
      fresh_until: new Date(harness.checkedAt.getTime() + 20 * 60_000).toISOString(),
    });
    const heartbeatAt = harness.checkedAt;

    harness.checkedAt = new Date(harness.checkedAt.getTime() + 30_000);
    const stale = await harness.app.request("https://quota.gotry.io/api/v5/device/health", {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${device.device_session.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        ...healthy,
        observed_at: harness.checkedAt.toISOString(),
        refresh_revision: 8,
        client_version: "0.0.1",
        summary: { operation: "degraded", data: "stale", attention: "required" },
        top_code: "refresh_failed",
        consecutive_failures: 1,
      }),
    });
    expect(stale.status).toBe(200);
    expect(await stale.json()).toMatchObject({
      status: "ignored_stale",
      received_at: heartbeatAt.toISOString(),
      fresh_until: new Date(heartbeatAt.getTime() + 20 * 60_000).toISOString(),
    });
    const afterStale = (await (
      await harness.app.request("https://quota.gotry.io/api/v5/account/summary", {
        headers: accountHeaders,
      })
    ).json()) as { devices: Array<{ health: Record<string, unknown> | null }> };
    expect(afterStale.devices[0]?.health).toMatchObject({
      client_version: "0.0.17",
      refresh_revision: 9,
      summary: { operation: "healthy" },
    });

    const selectedDevice = await harness.app.request(
      "https://quota.gotry.io/api/v5/device/health",
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${device.device_session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ...healthy, device_id: "device_other" }),
      },
    );
    expect(selectedDevice.status).toBe(400);

    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, display_name, platform, generation,
           created_at, last_login_at
         ) VALUES ('device_account_cascade', ?1, 'installation_account_cascade',
           'Cascade Mac', 'macos', 1, ?2, ?2)`,
      ).bind(device.account_id, harness.checkedAt.toISOString()),
      env.DB.prepare(
        `INSERT INTO device_health (
           device_id, device_generation, schema_version, client_product, client_version,
           platform, observed_at, refresh_revision, received_at, fresh_until,
           last_completed_refresh_at, last_successful_account_sync_at, operation, data_state,
           attention, top_code, consecutive_failures, usage_upload_enabled
         ) VALUES ('device_account_cascade', 1, 1, 'quotabar', '0.0.16', 'macos',
           ?1, 1, ?1, ?2, ?1, NULL, 'healthy', 'empty', 'none', NULL, 0, 0)`,
      ).bind(
        harness.checkedAt.toISOString(),
        new Date(harness.checkedAt.getTime() + 20 * 60_000).toISOString(),
      ),
    ]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_health").first("count")).toBe(
      2,
    );

    expect(
      await new D1AccountState(env.DB).deleteDeviceData(
        device.account_id,
        device.device_id,
        harness.checkedAt.toISOString(),
      ),
    ).toMatchObject({ device_id: device.device_id });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_health").first("count")).toBe(
      1,
    );
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(device.account_id).run();
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_health").first("count")).toBe(
      0,
    );
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
  let callbackURL = "";
  const checked = { at: now };
  const webAuth: WebAccountAuth = {
    handler: async () => new Response(null, { status: 404 }),
    beginGitHubSignIn: async (_headers, callback) => {
      callbackURL = callback;
      return Response.redirect("https://github.com/login/oauth/authorize", 302);
    },
    getSession: async () => ({
      user: { id: accountId, name: "iOS Tester" },
      session: {
        id: "ios_web_session",
        createdAt: now,
        expiresAt: new Date(now.getTime() + 60_000),
      },
    }),
  };
  const app = createRelayApp({
    state,
    usageState: new D1UsageState(env.DB),
    accountService: new AccountService(state, hasher, secret),
    webAuth,
    hasher,
    now: () => checked.at,
  });
  return {
    app,
    accountId,
    get callbackURL() {
      return callbackURL;
    },
    get checkedAt() {
      return checked.at;
    },
    set checkedAt(value: Date) {
      checked.at = value;
    },
  };
}

async function loginQuotacli(harness: TestHarness): Promise<OAuthTokenResponse> {
  const { verifier, challenge } = await pkcePair();
  const authorizeUrl = new URL("https://quota.gotry.io/oauth/v2/authorize");
  authorizeUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: "quotacli",
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
      client_id: "quotacli",
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
    `SELECT COUNT(*) AS count FROM device_sessions
     WHERE device_id IN (SELECT id FROM devices WHERE account_id = ?1)`,
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
