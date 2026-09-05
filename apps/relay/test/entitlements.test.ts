import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
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
const webhookSecret = "rc-webhook-secret-value";
const restSecret = "rc-rest-secret-value";
const webPurchaseUrl = "https://pay.rev.cat/testtoken";
const accountId = "account_entitlement";
const origin = "https://quota.gotry.io";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
  await env.DB.batch(
    [
      "entitlement_events",
      "entitlements",
      "sessions",
      "quota_snapshots",
      "usage_daily",
      "usage_hourly",
      "usage_hour_scans",
      "devices",
      "accounts",
    ].map((table) => env.DB.prepare(`DELETE FROM ${table}`)),
  );
});

describe("RevenueCat entitlements", () => {
  it("refuses a webhook without the configured Authorization header", async () => {
    const { app } = harness();
    const missing = await webhook(app, event("INITIAL_PURCHASE"), { authorization: null });
    expect(missing.status).toBe(401);
    expect(await missing.json()).toMatchObject({ error: { code: "unauthorized" } });
    const wrong = await webhook(app, event("INITIAL_PURCHASE"), { authorization: "nope" });
    expect(wrong.status).toBe(401);
    expect(await wrong.text()).not.toContain("rc-");
  });

  it("folds each billed event type and ignores a duplicate id", async () => {
    await seedAccount();
    const { app } = harness();
    const cases: Array<{
      type:
        | "INITIAL_PURCHASE"
        | "RENEWAL"
        | "UNCANCELLATION"
        | "PRODUCT_CHANGE"
        | "TEST"
        | "CANCELLATION"
        | "EXPIRATION"
        | "BILLING_ISSUE";
      status: string;
      willRenew: number;
    }> = [
      { type: "INITIAL_PURCHASE", status: "active", willRenew: 1 },
      { type: "RENEWAL", status: "active", willRenew: 1 },
      { type: "UNCANCELLATION", status: "active", willRenew: 1 },
      { type: "PRODUCT_CHANGE", status: "active", willRenew: 1 },
      { type: "TEST", status: "active", willRenew: 1 },
      { type: "CANCELLATION", status: "active", willRenew: 0 },
      { type: "EXPIRATION", status: "expired", willRenew: 0 },
      { type: "BILLING_ISSUE", status: "grace", willRenew: 1 },
    ];
    for (const [index, testCase] of cases.entries()) {
      const body = event(testCase.type, { id: `evt_${testCase.type}_${index}` });
      const response = await webhook(app, body);
      expect(response.status, testCase.type).toBe(200);
      expect(await response.text()).toBe("");
      expect(await storedEntitlement()).toMatchObject({
        status: testCase.status,
        will_renew: testCase.willRenew,
        source: "webhook",
        last_event_id: `evt_${testCase.type}_${index}`,
      });
    }

    const duplicate = await webhook(app, event("EXPIRATION", { id: "evt_BILLING_ISSUE_7" }));
    expect(duplicate.status).toBe(200);
    expect(await storedEntitlement()).toMatchObject({
      status: "grace",
      last_event_id: "evt_BILLING_ISSUE_7",
    });
    expect(await eventCount()).toBe(cases.length);
  });

  it("accepts an unknown app_user_id with 202 and stores the event without creating an account", async () => {
    const { app } = harness();
    const response = await webhook(app, event("INITIAL_PURCHASE", { app_user_id: "missing" }));
    expect(response.status).toBe(202);
    expect(await response.text()).toBe("");
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts").first("count")).toBe(0);
    expect(await eventCount()).toBe(1);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM entitlements").first("count")).toBe(
      0,
    );
  });

  it("strips email and attributes from the stored webhook payload", async () => {
    await seedAccount();
    const { app } = harness();
    await webhook(
      app,
      event("INITIAL_PURCHASE", {
        email: "user@example.com",
        subscriber_attributes: { $email: { value: "user@example.com" } },
        attributes: { plan: "hidden" },
      }),
    );
    const payload = JSON.parse(
      (await env.DB.prepare("SELECT payload_json FROM entitlement_events").first(
        "payload_json",
      )) as string,
    ) as Record<string, unknown>;
    expect(payload).not.toHaveProperty("email");
    expect(payload).not.toHaveProperty("subscriber_attributes");
    expect(payload).not.toHaveProperty("attributes");
    expect(payload).toMatchObject({ type: "INITIAL_PURCHASE", app_user_id: accountId });
  });

  it("transfers the destination and clears known sources", async () => {
    await seedAccount();
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, created_at, updated_at)
       VALUES ('account_source', 'account_source', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const { app } = harness();
    const response = await webhook(
      app,
      event("TRANSFER", {
        transferred_from: ["account_source", "$RCAnonymousID:abc"],
        transferred_to: [accountId],
      }),
    );
    expect(response.status).toBe(200);
    expect(await storedEntitlement()).toMatchObject({ status: "active", account_id: accountId });
    expect(
      await env.DB.prepare(
        "SELECT status FROM entitlements WHERE account_id = 'account_source'",
      ).first("status"),
    ).toBe("none");
  });

  it("serves a fresh D1 row without REST and refreshes after 24h", async () => {
    await seedAccount();
    await seedPaidEntitlement(now);
    const rest = restMock({
      entitlements: {
        sync: {
          expires_date: "2026-10-01T00:00:00Z",
          product_identifier: "quota_sync_yearly",
        },
      },
      subscriptions: {
        quota_sync_yearly: { store: "app_store", unsubscribe_detected_at: null },
      },
    });
    const { app } = harness({ fetch: rest.fetch, clock: now });
    const headers = { Cookie: "web" };
    const first = await app.request(`${origin}/api/v2/account`, { headers });
    expect(first.status).toBe(200);
    expect(await first.json()).toMatchObject({
      entitlement: {
        status: "active",
        product_id: "quota_sync_monthly",
        stale: false,
      },
      purchase: { web_url: `${webPurchaseUrl}/${accountId}` },
    });
    expect(rest.calls).toEqual([]);

    const later = new Date(now.getTime() + 25 * 60 * 60 * 1000);
    const { app: staleApp } = harness({ fetch: rest.fetch, clock: later });
    const refreshed = await staleApp.request(`${origin}/api/v2/account`, { headers });
    expect(refreshed.status).toBe(200);
    expect(await refreshed.json()).toMatchObject({
      entitlement: {
        status: "active",
        product_id: "quota_sync_yearly",
        stale: false,
      },
    });
    expect(rest.calls).toHaveLength(1);
    expect(rest.calls[0]).toContain(`/v1/subscribers/${accountId}`);
  });

  it("marks stale when REST fails and keeps the stored row", async () => {
    await seedAccount();
    await seedPaidEntitlement(new Date(now.getTime() - 25 * 60 * 60 * 1000));
    const rest = restMock(null, { status: 500 });
    const { app } = harness({ fetch: rest.fetch });
    const response = await app.request(`${origin}/api/v2/account`, { headers: { Cookie: "web" } });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      entitlement: { status: "active", product_id: "quota_sync_monthly", stale: true },
    });
  });

  it("answers 402 on write routes without a paid entitlement and leaves a refusal log", async () => {
    await seedAccount();
    await seedDevice();
    const logged: string[] = [];
    const original = console.error;
    console.error = (value: unknown) => {
      logged.push(String(value));
    };
    const { app } = harness();
    const token = await bearerToken();
    const headers = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    };
    try {
      for (const [method, path] of [
        ["PUT", "/api/v6/device/snapshots"],
        ["PUT", "/api/v6/device/usage"],
        ["GET", "/api/v2/device/sync"],
        ["PUT", "/api/v2/device/profile"],
      ] as const) {
        const response = await app.request(
          `${origin}${path}`,
          method === "GET" ? { method, headers } : { method, headers, body: "{}" },
        );
        expect(response.status, path).toBe(402);
        expect(await response.json()).toMatchObject({
          error: { code: "subscription_required" },
        });
      }
    } finally {
      console.error = original;
    }
    expect(logged.some((line) => line.includes("relay_write_refused"))).toBe(true);
    expect(logged.some((line) => line.includes("subscription_required"))).toBe(true);

    const summary = await app.request(`${origin}/api/v6/account/summary`);
    expect(summary.status).toBe(200);
    expect(await summary.json()).toMatchObject({
      entitlement: { status: "none", stale: false },
    });
    const account = await app.request(`${origin}/api/v2/account`);
    expect(account.status).toBe(200);
  });

  it("allows snapshots in grace and moves the summary ETag when the entitlement changes", async () => {
    await seedAccount();
    await seedDevice();
    await seedPaidEntitlement(now, "grace");
    const { app } = harness();
    const token = await bearerToken();
    const uploaded = await app.request(`${origin}/api/v6/device/snapshots`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        protocol_version: 6,
        generation: 1,
        snapshots: [
          {
            provider: "codex",
            account: { fingerprint: "fp", fingerprint_scope: "global" },
            windows: [{ id: "weekly", title: "Weekly", used_percent: 10 }],
            status: "available",
            observed_at: now.toISOString(),
          },
        ],
      }),
    });
    expect(uploaded.status).toBe(200);

    const first = await app.request(`${origin}/api/v6/account/summary`);
    expect(first.status).toBe(200);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(await first.json()).toMatchObject({ entitlement: { status: "grace" } });
    expect(
      (
        await app.request(`${origin}/api/v6/account/summary`, {
          headers: { "If-None-Match": etag ?? "" },
        })
      ).status,
    ).toBe(304);

    await env.DB.prepare(
      "UPDATE entitlements SET status = 'active', updated_at = ?2 WHERE account_id = ?1",
    )
      .bind(accountId, "2026-08-10T01:00:00.000Z")
      .run();
    const moved = await app.request(`${origin}/api/v6/account/summary`);
    expect(moved.status).toBe(200);
    expect(moved.headers.get("ETag")).not.toBe(etag);
    expect(await moved.json()).toMatchObject({ entitlement: { status: "active" } });
  });
});

function harness(overrides: { fetch?: typeof fetch; clock?: Date } = {}) {
  const clock = overrides.clock ?? now;
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const app = createRelayApp({
    state,
    usageState: new D1UsageState(env.DB),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, clock),
    hasher,
    now: () => clock,
    billing: {
      webhookSecret,
      restSecret: overrides.fetch === undefined ? "" : restSecret,
      webPurchaseUrl,
      ...(overrides.fetch === undefined ? {} : { fetch: overrides.fetch }),
    },
  });
  return { app };
}

async function seedAccount(): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO accounts (id, identity_subject, created_at, updated_at)
     VALUES (?1, ?1, ?2, ?2)`,
  )
    .bind(accountId, now.toISOString())
    .run();
}

async function seedDevice(): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO devices (
       id, account_id, installation_id_hash, generation, created_at, last_login_at
     ) VALUES ('device_entitlement', ?1, 'installation_entitlement', 1, ?2, ?2)`,
  )
    .bind(accountId, now.toISOString())
    .run();
}

async function seedPaidEntitlement(
  updatedAt: Date,
  status: "active" | "grace" = "active",
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO entitlements (
       account_id, status, product_id, store, expires_at, will_renew, source, last_event_id, updated_at
     ) VALUES (?1, ?2, 'quota_sync_monthly', 'app_store', ?3, 1, 'webhook', NULL, ?4)`,
  )
    .bind(
      accountId,
      status,
      new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString(),
      updatedAt.toISOString(),
    )
    .run();
}

async function bearerToken(): Promise<string> {
  const token = `qb_${"entitlement".padEnd(43, "x").slice(0, 43)}`;
  await env.DB.prepare(
    `INSERT INTO sessions (
       id, family_id, account_id, device_id, device_generation, client_kind,
       access_token_hash, refresh_token_hash, scopes_json,
       authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
     ) VALUES (?1, ?1, ?2, 'device_entitlement', 1, 'quotabar', ?3, ?4, ?5, ?7, ?6, ?6, ?7, ?7)`,
  )
    .bind(
      "session_entitlement",
      accountId,
      await new SecretHasher(secret).hash("quotabar-access", token),
      "refresh_entitlement",
      JSON.stringify(["account:read", "device:write"]),
      new Date(now.getTime() + 3_600_000).toISOString(),
      now.toISOString(),
    )
    .run();
  return token;
}

function event(
  type: string,
  extra: Record<string, unknown> = {},
): { api_version: string; event: Record<string, unknown> } {
  return {
    api_version: "1.0",
    event: {
      id: extra.id ?? `evt_${type}`,
      type,
      app_user_id: extra.app_user_id ?? accountId,
      product_id: extra.product_id ?? "quota_sync_monthly",
      store: extra.store ?? "APP_STORE",
      entitlement_ids: extra.entitlement_ids ?? ["sync"],
      expiration_at_ms: extra.expiration_at_ms ?? Date.parse("2026-09-09T00:00:00.000Z"),
      event_timestamp_ms: now.getTime(),
      environment: "PRODUCTION",
      ...extra,
    },
  };
}

async function webhook(
  app: ReturnType<typeof createRelayApp>,
  body: unknown,
  options: { authorization?: string | null } = {},
): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (options.authorization !== null) {
    headers.Authorization = options.authorization ?? webhookSecret;
  }
  return app.request(`${origin}/api/billing/revenuecat/webhook`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function restMock(subscriber: unknown, options: { status?: number } = {}) {
  const calls: string[] = [];
  return {
    calls,
    fetch: (async (input: RequestInfo | URL) => {
      calls.push(String(input));
      const status = options.status ?? 200;
      if (status !== 200) {
        return new Response("nope", { status });
      }
      return Response.json({ subscriber });
    }) as typeof fetch,
  };
}

async function storedEntitlement() {
  return env.DB.prepare(
    "SELECT account_id, status, will_renew, source, last_event_id, product_id FROM entitlements WHERE account_id = ?1",
  )
    .bind(accountId)
    .first();
}

async function eventCount(): Promise<number> {
  return (await env.DB.prepare("SELECT COUNT(*) AS count FROM entitlement_events").first(
    "count",
  )) as number;
}
