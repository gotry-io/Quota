import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  type DeviceAuthorizationResponse,
  MAXIMUM_USAGE_COVERAGE_HOURS,
  type OAuthTokenResponse,
  UsageCoverageSummaryItemSchema,
} from "@gotry-io/quota-protocol";
import type { DevicePrincipal, UsageSubmission } from "@gotry-io/relay-core";
import { beforeEach, describe, expect, inject, it } from "vitest";
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
  it("floors RFC3339 deletion watermarks with SQLite before accepting Usage", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_watermark', 'subject_watermark', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, deleted_before,
             created_at, last_login_at
           ) VALUES ('device_watermark', 'account_watermark', 'installation_watermark', 2,
             '2026-08-10T10:05:00Z', ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_test",
      family_id: "family_test",
      account_id: "account_watermark",
      device_id: "device_watermark",
      generation: 2,
      scopes: ["usage:write:self"],
    };
    const submission: UsageSubmission = {
      protocol_version: 2,
      submission_id: "submission_old",
      device_id: "device_watermark",
      generation: 2,
      sequence: 0,
      parser_revision: "parser_test",
      aggregation_timezone: "UTC",
      coverage: {
        agent: "codex",
        start_at: "2026-08-10T09:00:00.000Z",
        end_at: "2026-08-10T10:00:00.000Z",
        status: "complete",
      },
      rows: [],
    };
    const usage = new D1UsageState(env.DB);
    expect(await usage.recordUsage(principal, submission, now.toISOString())).toEqual({
      outcome: "deleted_range",
    });
    expect(
      await usage.recordUsage(
        principal,
        {
          ...submission,
          submission_id: "submission_current",
          coverage: {
            ...submission.coverage,
            start_at: "2026-08-10T10:00:00.000Z",
            end_at: "2026-08-10T11:00:00.000Z",
          },
        },
        now.toISOString(),
      ),
    ).toMatchObject({ outcome: "accepted", next_sequence: 1 });
  });

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

  it("accepts a shipped unknown-model submission while discarding its invalid row", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_legacy', 'subject_legacy', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_legacy', 'account_legacy', 'installation_legacy', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_legacy",
      family_id: "family_legacy",
      account_id: "account_legacy",
      device_id: "device_legacy",
      generation: 1,
      scopes: ["usage:write:self"],
    };
    const submission = legacyUnknownSubmission();
    const usage = new D1UsageState(env.DB);

    expect(await usage.recordUsage(principal, submission, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 1,
    });
    expect(await usage.recordUsage(principal, submission, now.toISOString())).toMatchObject({
      outcome: "duplicate",
      next_sequence: 1,
    });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_hourly").first("count")).toBe(
      0,
    );
  });

  it("filters additive Usage agents for released v2 clients", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_agents', 'subject_agents', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_agents', 'account_agents', 'installation_agents', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageFactInsert("codex", "openai_direct", "gpt-5.6-sol"),
      usageFactInsert("grok", "xai_direct", "grok-4.5"),
    ]);

    const state = new D1UsageState(env.DB);
    const legacy = await state.queryAccountUsage("account_agents", {
      agents: ["codex", "claude_code"],
      limit: 100,
    });
    const expanded = await state.queryAccountUsage("account_agents", {
      agents: ["codex", "claude_code", "grok", "opencode", "pi"],
      limit: 100,
    });

    expect(legacy.rows.map((row) => row.agent)).toEqual(["codex"]);
    expect(expanded.rows.map((row) => row.agent)).toEqual(["codex", "grok"]);
  });

  it("keeps additive pricing channels behind the v2 opt-in", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth: createWebAccountAuth({
        database: env.DB,
        githubClientId: "github-client",
        githubClientSecret: "github-secret",
        githubSubjectKey: secret,
        authSecret: secret,
        origin: "https://quota.gotry.io",
      }),
      hasher,
      now: () => now,
    });

    const legacy = (await (
      await app.request("https://quota.gotry.io/api/v2/pricing/catalog")
    ).json()) as { entries: Array<{ billing_channel: string }> };
    const expanded = (await (
      await app.request("https://quota.gotry.io/api/v2/pricing/catalog?usage_agents=all")
    ).json()) as { entries: Array<{ billing_channel: string }> };
    const invalid = await app.request(
      "https://quota.gotry.io/api/v2/pricing/catalog?usage_agents=codex",
    );

    expect(legacy.entries.some((entry) => entry.billing_channel === "xai_direct")).toBe(false);
    expect(expanded.entries.some((entry) => entry.billing_channel === "xai_direct")).toBe(true);
    expect(invalid.status).toBe(400);
  });

  it("keeps the shipped summary range while new clients opt into retained history", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_history', 'account_history', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_history', 'account_history', 'installation_history', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageFactInsertAt("device_history", "2025-01-01T00:00:00Z", "2025-01-01"),
      usageFactInsertAt("device_history", "2026-08-09T00:00:00Z", "2026-08-09"),
    ]);
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "account_history", name: "Quota Tester" },
        session: {
          id: "web_history",
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
      now: () => now,
    });

    const legacy = (await (
      await app.request("https://quota.gotry.io/api/v2/account/summary")
    ).json()) as {
      usage: { range: { from: string; to: string }; totals: { requests: number } };
    };
    const expanded = (await (
      await app.request("https://quota.gotry.io/api/v2/account/summary?usage_agents=all")
    ).json()) as {
      usage: {
        range: { from: string; to: string };
        totals: { requests: number };
        breakdowns: Array<{ dimension: string }>;
      };
    };

    expect(legacy.usage).toMatchObject({
      range: { from: "2026-07-12", to: "2026-08-10" },
      totals: { requests: 1 },
    });
    expect(expanded.usage).toMatchObject({
      range: { from: "2025-01-01", to: "2026-08-09" },
      totals: { requests: 2 },
    });
    expect(
      expanded.usage.breakdowns.some(
        ({ dimension }) => dimension === "usage_date" || dimension === "bucket_start_utc",
      ),
    ).toBe(false);
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v2/account/summary?from=2025-01-01&to=2026-08-10",
        )
      ).status,
    ).toBe(400);
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v2/account/summary?usage_agents=all&from=2025-01-01&to=2026-08-10",
        )
      ).status,
    ).toBe(200);
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
    const nativeResponse = await auth.beginGitHubSignIn(
      new Headers({ Origin: "https://quota.gotry.io" }),
      "https://quota.gotry.io/oauth/v2/complete?login_token=synthetic",
    );
    expect(nativeResponse.status).toBe(302);
    expect(nativeResponse.headers.get("location")).toContain("github.com/login/oauth/authorize");
    expect(nativeResponse.headers.get("set-cookie")).toContain("quota");
    expect(nativeResponse.headers.get("cache-control")).toBe("no-store");
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM auth_identities").first("count"),
    ).toBe(0);
  });

  it("completes browser PKCE through a Better Auth Web principal and issues device tokens", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const service = new AccountService(state, hasher, secret);
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('identity_subject', 'identity_subject', 'Quota Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    let callbackURL = "";
    let sessionCreatedAt = now;
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async (_headers, callback) => {
        callbackURL = callback;
        return Response.redirect("https://github.com/login/oauth/authorize", 302);
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
    expect((await app.request(authorize)).status).toBe(302);

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

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare(
      "UPDATE login_grants SET redirect_uri = 'https://attacker.invalid/callback' WHERE completed_at IS NULL",
    ).run();
    const unsafeRedirect = await app.request(callbackURL);
    expect(unsafeRedirect.status).toBe(400);
    expect(unsafeRedirect.headers.get("location")).toBeNull();
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM login_grants WHERE completed_at IS NOT NULL AND redirect_uri = 'https://attacker.invalid/callback'",
      ).first("count"),
    ).toBe(0);

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(tokens.account_id).run();
    expect((await app.request(callbackURL)).status).toBe(401);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v2/account/devices", {
          headers: { Origin: "https://quota.gotry.io" },
        })
      ).status,
    ).toBe(401);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts WHERE id = ?1")
        .bind(tokens.account_id)
        .first("count"),
    ).toBe(0);
  });

  it("completes the headless device authorization grant", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    let checkedAt = now;
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('device_account', 'device_account', 'Device Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "device_account", name: "Device Tester" },
        session: {
          id: "device_web_session",
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
      now: () => checkedAt,
    });

    const started = await app.request("https://quota.gotry.io/oauth/v2/device/code", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        client_id: "quotacli",
        installation_id: "dd4e60c6-fd44-4ac4-ad1f-28f2eeb52ca1",
        device_display_name: "Headless Linux",
        platform: "linux",
      }),
    });
    expect(started.status).toBe(201);
    const grant = (await started.json()) as DeviceAuthorizationResponse;
    expect(grant.verification_uri).toBe("https://quota.gotry.io/activate");
    expect(grant.verification_uri_complete).toContain(encodeURIComponent(grant.user_code));

    const tokenBody = JSON.stringify({
      protocol_version: 2,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      client_id: "quotacli",
      device_code: grant.device_code,
    });
    const pending = await app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: tokenBody,
    });
    expect(pending.status).toBe(400);
    expect(pending.headers.get("Retry-After")).toBe(String(grant.interval));
    expect(await pending.json()).toMatchObject({ error: { code: "authorization_pending" } });

    const approved = await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://quota.gotry.io",
        "Sec-Fetch-Site": "same-origin",
      },
      body: JSON.stringify({
        protocol_version: 2,
        user_code: grant.user_code,
        decision: "approve",
      }),
    });
    expect(approved.status).toBe(204);

    checkedAt = new Date(now.getTime() + grant.interval * 1_000);
    const exchanged = await app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: tokenBody,
    });
    expect(exchanged.status).toBe(200);
    const tokens = (await exchanged.json()) as OAuthTokenResponse;
    expect(tokens.account_id).toBe("device_account");
    expect(tokens.device_generation).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);
  });
});

function usageFactInsert(agent: string, channel: string, model: string): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_hourly (
         device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
         agent, billing_channel, channel_source, model, context_bucket,
         service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
         output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
         source_cost_microusd, source_cost_covered_requests
       ) VALUES (
         'device_agents', '2026-08-10T00:00:00Z', '2026-08-10', 8, 'Asia/Singapore',
         ?1, ?2, 'agent_default', ?3, 'le_128k',
         'unknown', 'unknown', 'unknown', 10, 0,
         0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
       )`,
  ).bind(agent, channel, model);
}

function usageFactInsertAt(
  deviceID: string,
  bucketStart: string,
  usageDate: string,
): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_hourly (
       device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
       agent, billing_channel, channel_source, model, context_bucket,
       service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
       cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
       output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
       source_cost_microusd, source_cost_covered_requests
     ) VALUES (
       ?1, ?2, ?3, 0, 'UTC', 'codex', 'openai_direct', 'agent_default',
       'gpt-5.6-sol', 'le_128k', 'unknown', 'unknown', 'unknown', 10, 0,
       0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
     )`,
  ).bind(deviceID, bucketStart, usageDate);
}

function legacyUnknownSubmission(): UsageSubmission {
  return {
    protocol_version: 2,
    submission_id: "submission_legacy_unknown",
    device_id: "device_legacy",
    generation: 1,
    sequence: 0,
    parser_revision: "quota-usage-4",
    aggregation_timezone: "UTC",
    coverage: {
      agent: "codex",
      start_at: "2026-08-09T10:00:00Z",
      end_at: "2026-08-09T11:00:00Z",
      status: "complete",
    },
    rows: [
      {
        bucket_start_utc: "2026-08-09T10:00:00Z",
        usage_date: "2026-08-09",
        usage_hour: 10,
        agent: "codex",
        billing_channel: "openai_direct",
        channel_source: "agent_default",
        model: "unknown",
        context_bucket: "le_128k",
        service_tier: "unknown",
        speed: "unknown",
        inference_geo: "unknown",
        input_tokens: 10,
        cache_read_tokens: 0,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0,
        cache_write_inferred_tokens: 0,
        output_tokens: 2,
        reasoning_tokens: 0,
        requests: 1,
        web_search_requests: 0,
        web_fetch_requests: 0,
        source_cost_covered_requests: 0,
      },
    ],
  };
}
