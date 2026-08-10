import { applyD1Migrations, env } from "cloudflare:test";
import { beforeEach, describe, expect, inject, it } from "vitest";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  MAXIMUM_USAGE_COVERAGE_HOURS,
  type OAuthTokenResponse,
  UsageCoverageSummaryItemSchema,
} from "@gotry-io/quota-protocol";
import { createWebAccountAuth, type WebAccountAuth } from "../src/account/better-auth.ts";
import { D1EncryptedAuthStorage } from "../src/account/better-auth-storage.ts";
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
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

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("managed Relay on real Workers and D1", () => {
  it("keeps adjacent Usage coverage inside the wire range limit", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_test', 'subject_test', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_test', 'account_test', 'installation_test', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO usage_coverage (
             device_id, agent, start_at, end_at, parser_revision, submission_id, accepted_at
           ) VALUES ('device_test', 'codex', '2026-06-01T00:00:00Z',
             '2026-07-02T00:00:00Z', 'parser_test', 'submission_1', ?1)`,
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO usage_coverage (
             device_id, agent, start_at, end_at, parser_revision, submission_id, accepted_at
           ) VALUES ('device_test', 'codex', '2026-07-02T00:00:00Z',
             '2026-08-02T00:00:00Z', 'parser_test', 'submission_2', ?1)`,
      ).bind(now.toISOString()),
    ]);

    const result = await new D1UsageState(env.DB).queryAccountUsage("account_test", {
      start_at: "2026-06-01T00:00:00Z",
      end_at: "2026-08-03T00:00:00Z",
      limit: 1_000,
    });

    expect(result.truncated).toBe(false);
    expect(result.coverage).toHaveLength(2);
    for (const item of result.coverage) {
      expect(
        UsageCoverageSummaryItemSchema.safeParse({
          device_id: item.device_id,
          agent: item.agent,
          start_at: item.start_at,
          end_at: item.end_at,
          status: item.status,
        }).success,
      ).toBe(true);
      expect(item.status).toBe("complete");
      expect((Date.parse(item.end_at) - Date.parse(item.start_at)) / 3_600_000).toBeLessThanOrEqual(
        MAXIMUM_USAGE_COVERAGE_HOURS,
      );
    }
  });

  it("stores Better Auth sessions encrypted behind hashed keys", async () => {
    const storage = new D1EncryptedAuthStorage(env.DB, secret);
    await storage.set("raw-session-token", JSON.stringify({ token: "raw-session-token" }), 60);

    const row = await env.DB.prepare(
      "SELECT key_hash, value_ciphertext FROM auth_session_store",
    ).first<{ key_hash: string; value_ciphertext: string }>();
    expect(row?.key_hash).not.toContain("raw-session-token");
    expect(row?.value_ciphertext).not.toContain("raw-session-token");
    expect(await storage.get("raw-session-token")).toContain("raw-session-token");

    const expiredKeyHash = await new SecretHasher(secret).hash(
      "better-auth-storage",
      "expired-session-token",
    );
    await env.DB.prepare(
      "INSERT INTO auth_session_store (key_hash, value_ciphertext, expires_at) VALUES (?1, 'expired', ?2)",
    )
      .bind(expiredKeyHash, "2026-08-09T00:00:00.000Z")
      .run();
    expect(await storage.getAndDelete("expired-session-token")).toBeNull();
    await env.DB.prepare(
      "INSERT INTO auth_session_store (key_hash, value_ciphertext, expires_at) VALUES ('expired', 'expired', ?1)",
    )
      .bind("2026-08-09T00:00:00.000Z")
      .run();
    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM auth_session_store WHERE key_hash = 'expired'",
      ).first("count"),
    ).toBe(0);
  });

  it("uses Better Auth's standard GitHub redirect and stores no provider token", async () => {
    const auth = createWebAccountAuth({
      database: env.DB,
      githubClientId: "github-client",
      githubClientSecret: "github-secret",
      githubSubjectKey: secret,
      authSecret: secret,
      origin: "https://quota.gotry.io",
    });
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth: auth,
      hasher,
      now: () => now,
    });
    const response = await app.request("https://quota.gotry.io/api/auth/v2/sign-in/social", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://quota.gotry.io",
        "cf-connecting-ip": "203.0.113.10",
      },
      body: JSON.stringify({ provider: "github", callbackURL: "/app" }),
    });
    const body = (await response.json()) as { url?: string };
    expect(body.url).toContain("github.com/login/oauth/authorize");
    expect(body.url).toContain("scope=");
    expect(response.headers.get("set-cookie")).toContain("quota");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM auth_identities").first("count"),
    ).toBe(0);
  });

  it("completes browser PKCE through a Better Auth Web principal and issues device tokens", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const service = new AccountService(state, hasher, secret);
    let callbackURL = "";
    let sessionCreatedAt = now;
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async (_headers, callback) => {
        callbackURL = callback;
        return Response.json({ url: "https://github.com/login/oauth/authorize", redirect: true });
      },
      getSession: async () => ({
        user: { id: "identity_subject", name: "Quota Tester" },
        session: {
          id: "web_session",
          createdAt: sessionCreatedAt,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: service,
      webAuth,
      hasher,
      now: () => now,
    });
    const decisionBody = JSON.stringify({
      protocol_version: 2,
      user_code: "ABCD-EFGH",
      decision: "approve",
    });
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: decisionBody,
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: decisionBody,
        })
      ).status,
    ).toBe(404);
    sessionCreatedAt = new Date(now.getTime() - 10 * 60_000 - 1);
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: decisionBody,
        })
      ).status,
    ).toBe(403);
    sessionCreatedAt = now;

    const verifier = "a".repeat(43);
    const challengeBuffer = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(verifier),
    );
    const challenge = btoa(String.fromCharCode(...new Uint8Array(challengeBuffer)))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replace(/=+$/, "");
    const authorize = new URL("https://quota.gotry.io/oauth/v2/authorize");
    authorize.search = new URLSearchParams({
      response_type: "code",
      client_id: "quotacli",
      redirect_uri: "http://127.0.0.1:43210/callback",
      state: "client-state-123456789",
      code_challenge: challenge,
      code_challenge_method: "S256",
    }).toString();
    expect((await app.request(authorize)).status).toBe(200);

    const complete = await app.request(callbackURL);
    expect(complete.status).toBe(302);
    const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
    expect(code).toBeTruthy();

    const exchanged = await app.request("https://quota.gotry.io/oauth/v2/token", {
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
    expect(tokens.account_id).toBe("identity_subject");
    expect(tokens.device_generation).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);

    const oldAccessHash = await hasher.hash("device-access", tokens.device_session.access_token);
    expect(await state.authorizeDeviceSession(oldAccessHash, now.toISOString())).toMatchObject({
      device_id: tokens.device_id,
      generation: 1,
    });
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${tokens.device_session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeDeviceSession(oldAccessHash, now.toISOString())).toBeNull();

    const deletedAt = new Date(now.getTime() + 1_000).toISOString();
    expect(
      await state.deleteDeviceData(tokens.account_id, tokens.device_id, deletedAt),
    ).toMatchObject({ device_id: tokens.device_id, generation: 2 });
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL, deleted_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeDeviceSession(oldAccessHash, deletedAt)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 1)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 2)).toMatchObject({ generation: 2 });
  });
});
