import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import {
  formatRedemptionCode,
  generateRedemptionCodeBodies,
  normalizeRedemptionCode,
} from "../src/redemption.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub, signedOutWebSessions } from "./web-session-stub.ts";

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
const adminSecret = "rc-admin-secret-value-that-is-long-enough";
const restSecret = "rc-rest-secret-value";
const webPurchaseUrl = "https://pay.rev.cat/testtoken";
const accountId = "account_redeem";
const origin = "https://quota.gotry.io";
const codeBody = "ABCDEFGHJKMNPQRS";
const formattedCode = "QUOTA-ABCD-EFGH-JKMN-PQRS";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
  await env.DB.batch(
    [
      "code_redemptions",
      "redemption_codes",
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

describe("redemption codes", () => {
  it("normalizes prefix, hyphens, and case to the 16-character body", () => {
    expect(normalizeRedemptionCode(formattedCode)).toBe(codeBody);
    expect(normalizeRedemptionCode("quota-abcd-efgh-jkmn-pqrs")).toBe(codeBody);
    expect(normalizeRedemptionCode(codeBody.toLowerCase())).toBe(codeBody);
    expect(formatRedemptionCode(codeBody)).toBe(formattedCode);
    const bodies = generateRedemptionCodeBodies(3);
    expect(bodies).toHaveLength(3);
    expect(new Set(bodies).size).toBe(3);
    for (const body of bodies) {
      expect(body).toMatch(/^[0-9A-HJKMNP-TV-Z]{16}$/);
    }
  });

  it("refuses to issue codes without the configured admin secret", async () => {
    const { app } = harness();
    const missing = await issue(app, { authorization: null });
    expect(missing.status).toBe(401);
    expect(await missing.json()).toMatchObject({ error: { code: "unauthorized" } });
    const wrong = await issue(app, { authorization: "Bearer nope" });
    expect(wrong.status).toBe(401);
    const emptySecret = harness({ adminSecret: "" });
    const unconfigured = await issue(emptySecret.app, {
      authorization: `Bearer ${adminSecret}`,
    });
    expect(unconfigured.status).toBe(401);
  });

  it("issues formatted codes and stores the 16-character body", async () => {
    const { app, state } = harness();
    const response = await issue(app, {
      body: {
        campaign: "beta",
        duration: "monthly",
        count: 2,
        max_redemptions: 3,
        note: "friends",
      },
    });
    expect(response.status).toBe(200);
    const payload = (await response.json()) as {
      codes: string[];
      campaign: string;
      duration: string;
      expires_at: string | null;
    };
    expect(payload.campaign).toBe("beta");
    expect(payload.duration).toBe("monthly");
    expect(payload.expires_at).toBeNull();
    expect(payload.codes).toHaveLength(2);
    for (const code of payload.codes) {
      expect(code).toMatch(/^QUOTA-[0-9A-HJKMNP-TV-Z]{4}(?:-[0-9A-HJKMNP-TV-Z]{4}){3}$/);
      const row = await state.getRedemptionCode(normalizeRedemptionCode(code));
      expect(row).toMatchObject({
        campaign: "beta",
        grant_duration: "monthly",
        max_redemptions: 3,
        redeemed_count: 0,
        note: "friends",
      });
    }
  });

  it("redeems a code through RevenueCat and records the grant", async () => {
    await seedAccount();
    await seedCode();
    const rest = promotionalMock();
    const logged: string[] = [];
    const original = console.log;
    console.log = (value: unknown) => {
      logged.push(String(value));
    };
    const { app, state } = harness({ fetch: rest.fetch });
    try {
      const response = await redeem(app, "quota-abcd-efgh-jkmn-pqrs");
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        protocol_version: 2,
        entitlement: {
          status: "active",
          expires_at: "2026-09-09T00:00:00.000Z",
          will_renew: true,
          stale: false,
        },
        granted: { duration: "monthly", campaign: "beta" },
      });
    } finally {
      console.log = original;
    }
    expect(rest.calls).toEqual([
      `https://api.revenuecat.com/v1/subscribers/${accountId}/entitlements/pro/promotional`,
    ]);
    expect(rest.bodies).toEqual([{ duration: "monthly" }]);
    expect(await state.hasRedeemedCode(codeBody, accountId)).toBe(true);
    expect(await state.getRedemptionCode(codeBody)).toMatchObject({ redeemed_count: 1 });
    expect(logged.some((line) => line.includes("relay_code_redeemed"))).toBe(true);
    expect(logged.some((line) => line.includes(codeBody) || line.includes(formattedCode))).toBe(
      false,
    );
  });

  it("refuses invalid, expired, already redeemed, and exhausted codes before billing", async () => {
    await seedAccount();
    const rest = promotionalMock();
    const { app } = harness({ fetch: rest.fetch });
    const missing = await redeem(app, formattedCode);
    expect(missing.status).toBe(404);
    expect(await missing.json()).toMatchObject({ error: { code: "code_invalid" } });

    await seedCode({ expires_at: "2026-08-01T00:00:00.000Z" });
    const expired = await redeem(app, formattedCode);
    expect(expired.status).toBe(410);
    expect(await expired.json()).toMatchObject({ error: { code: "code_expired" } });

    await env.DB.prepare("UPDATE redemption_codes SET expires_at = NULL WHERE code = ?1")
      .bind(codeBody)
      .run();
    await env.DB.prepare(
      "INSERT INTO code_redemptions (code, account_id, redeemed_at) VALUES (?1, ?2, ?3)",
    )
      .bind(codeBody, accountId, now.toISOString())
      .run();
    const already = await redeem(app, formattedCode);
    expect(already.status).toBe(409);
    expect(await already.json()).toMatchObject({ error: { code: "code_already_redeemed" } });

    await env.DB.prepare("DELETE FROM code_redemptions WHERE code = ?1").bind(codeBody).run();
    await env.DB.prepare(
      "UPDATE redemption_codes SET redeemed_count = max_redemptions WHERE code = ?1",
    )
      .bind(codeBody)
      .run();
    const exhausted = await redeem(app, formattedCode);
    expect(exhausted.status).toBe(409);
    expect(await exhausted.json()).toMatchObject({ error: { code: "code_exhausted" } });
    expect(rest.calls).toEqual([]);
  });

  it("does not record a redemption when RevenueCat fails", async () => {
    await seedAccount();
    await seedCode();
    const logged: string[] = [];
    const original = console.error;
    console.error = (value: unknown) => {
      logged.push(String(value));
    };
    const rest = promotionalMock({ status: 500 });
    const { app, state } = harness({ fetch: rest.fetch });
    try {
      const response = await redeem(app, formattedCode);
      expect(response.status).toBe(502);
      expect(await response.json()).toMatchObject({ error: { code: "billing_unavailable" } });
    } finally {
      console.error = original;
    }
    expect(await state.hasRedeemedCode(codeBody, accountId)).toBe(false);
    expect(await state.getRedemptionCode(codeBody)).toMatchObject({ redeemed_count: 0 });
    expect(logged.some((line) => line.includes("relay_redeem_failed"))).toBe(true);
  });

  it("answers 503 when billing is not configured", async () => {
    await seedAccount();
    await seedCode();
    const { app } = harness();
    const response = await redeem(app, formattedCode);
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: { code: "billing_unavailable" } });
  });

  it("refuses redeem without an Account session", async () => {
    await seedCode();
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webSessions: signedOutWebSessions,
      hasher,
      now: () => now,
      billing: {
        webhookSecret: "",
        restSecret,
        webPurchaseUrl,
        redemptionAdminSecret: adminSecret,
      },
    });
    const response = await redeem(app, formattedCode);
    expect(response.status).toBe(401);
  });

  it("records, rejects a repeat, then exhausts the last remaining redemption", async () => {
    await seedAccount();
    await env.DB.prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?1, ?2, ?2)")
      .bind("account_other", now.toISOString())
      .run();
    const state = new D1AccountState(env.DB);
    await seedCode({ max_redemptions: 2 });
    expect(await state.recordRedemption(codeBody, accountId, now.toISOString())).toBe("recorded");
    expect(await state.recordRedemption(codeBody, accountId, now.toISOString())).toBe(
      "already_redeemed",
    );
    expect(await state.getRedemptionCode(codeBody)).toMatchObject({ redeemed_count: 1 });
    expect(await state.recordRedemption(codeBody, "account_other", now.toISOString())).toBe(
      "recorded",
    );
    expect(await state.recordRedemption(codeBody, "account_third", now.toISOString())).toBe(
      "exhausted",
    );
    expect(await state.getRedemptionCode(codeBody)).toMatchObject({ redeemed_count: 2 });
  });

  it("drops an Account's redemptions without deleting the code", async () => {
    await seedAccount();
    await seedCode();
    const state = new D1AccountState(env.DB);
    expect(await state.recordRedemption(codeBody, accountId, now.toISOString())).toBe("recorded");
    expect(await state.deleteAccountData(accountId)).toBe(true);
    expect(await state.hasRedeemedCode(codeBody, accountId)).toBe(false);
    expect(await state.getRedemptionCode(codeBody)).toMatchObject({
      campaign: "beta",
      redeemed_count: 1,
    });
  });
});

function harness(overrides: { fetch?: typeof fetch; adminSecret?: string; clock?: Date } = {}) {
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
      webhookSecret: "",
      restSecret: overrides.fetch === undefined ? "" : restSecret,
      webPurchaseUrl,
      redemptionAdminSecret: overrides.adminSecret ?? adminSecret,
      ...(overrides.fetch === undefined ? {} : { fetch: overrides.fetch }),
    },
  });
  return { app, state };
}

async function seedAccount(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES (?1, 'octocat', ?2, ?2)`,
    ).bind(accountId, now.toISOString()),
    env.DB.prepare(
      `INSERT INTO account_identities (account_id, provider, subject, label, created_at)
       VALUES (?1, 'github', ?2, 'octocat', ?3)`,
    ).bind(accountId, `github-subject-${accountId}`, now.toISOString()),
  ]);
}

async function seedCode(
  extra: { expires_at?: string | null; max_redemptions?: number } = {},
): Promise<void> {
  await new D1AccountState(env.DB).createRedemptionCodes([
    {
      code: codeBody,
      campaign: "beta",
      grant_duration: "monthly",
      max_redemptions: extra.max_redemptions ?? 1,
      redeemed_count: 0,
      expires_at: extra.expires_at === undefined ? null : extra.expires_at,
      note: null,
      created_at: now.toISOString(),
    },
  ]);
}

async function issue(
  app: ReturnType<typeof createRelayApp>,
  options: { authorization?: string | null; body?: Record<string, unknown> } = {},
): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (options.authorization !== null) {
    headers.Authorization = options.authorization ?? `Bearer ${adminSecret}`;
  }
  return app.request(`${origin}/api/admin/redemption-codes`, {
    method: "POST",
    headers,
    body: JSON.stringify(options.body ?? { campaign: "beta", duration: "monthly", count: 1 }),
  });
}

async function redeem(app: ReturnType<typeof createRelayApp>, code: string): Promise<Response> {
  return app.request(`${origin}/api/v2/account/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Cookie: "web" },
    body: JSON.stringify({ code }),
  });
}

function promotionalMock(options: { status?: number } = {}) {
  const calls: string[] = [];
  const bodies: unknown[] = [];
  return {
    calls,
    bodies,
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push(String(input));
      if (typeof init?.body === "string") {
        bodies.push(JSON.parse(init.body));
      }
      const status = options.status ?? 200;
      if (status !== 200) {
        return new Response("nope", { status });
      }
      return Response.json({
        subscriber: {
          entitlements: {
            pro: {
              expires_date: "2026-09-09T00:00:00.000Z",
              product_identifier: "rc_promo_pro_monthly",
            },
          },
          subscriptions: {},
        },
      });
    }) as typeof fetch,
  };
}
