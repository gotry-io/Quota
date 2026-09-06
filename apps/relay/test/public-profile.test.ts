import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  MODEL_CATALOG,
  type PublicProfileResponse,
  type PublicUsageResponse,
} from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createWebDocumentPort } from "../src/account/web-document-port.ts";
import { createRelayApp } from "../src/app.ts";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";
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

const now = new Date("2026-09-06T12:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const webRequest = {
  headers: { Origin: origin, "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json" },
};

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("the public profile an Account may publish", () => {
  it("answers an Account that never published with an unpublished profile", async () => {
    await seedAccount("empty");
    const response = await appFor("account_empty").request(`${origin}/api/v2/account/profile`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      protocol_version: 2,
      profile: { handle: null, enabled: false, show_models: true, show_cost: false },
    });
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  // The whole reserved list and the pattern are the protocol's statement, and its own tests
  // answer for them. This is that Relay refuses what the contract refuses, at its boundary.
  it("refuses a handle the contract does not describe, and a reserved one", async () => {
    await seedAccount("rules");
    const app = appFor("account_rules");
    for (const handle of ["ab", "-lead", "UPPER", "under_score", "a".repeat(31), "admin"]) {
      const response = await put(app, handle);
      expect(response.status, handle).toBe(400);
      expect(await response.json()).toEqual({
        error: { code: "invalid_request", message: "The request is invalid." },
      });
    }
    expect(await storedProfiles("account_rules")).toBe(0);
  });

  it("stores a handle, keeps it across a takedown, and refuses one another Account holds", async () => {
    await seedAccount("owner");
    await seedAccount("rival");
    const owner = appFor("account_owner");

    const published = await put(owner, "owned-handle");
    expect(published.status).toBe(200);
    expect(((await published.json()) as PublicProfileResponse).profile).toEqual({
      handle: "owned-handle",
      enabled: true,
      show_models: true,
      show_cost: false,
    });

    // A handle is lowercase by contract, so an uppercase one is not a rival claim but a
    // request the contract does not describe.
    expect((await put(appFor("account_rival"), "Owned-Handle")).status).toBe(400);

    const contested = await put(appFor("account_rival"), "owned-handle");
    expect(contested.status).toBe(409);
    expect(await contested.json()).toEqual({
      error: { code: "conflict", message: "That handle is already taken." },
    });

    // Taking the page down keeps the handle, so a shared link cannot be claimed by someone else.
    expect((await put(owner, "owned-handle", { enabled: false })).status).toBe(200);
    expect((await put(appFor("account_rival"), "owned-handle")).status).toBe(409);

    expect(
      await env.DB.prepare(
        "SELECT account_id FROM public_profiles WHERE handle = 'owned-handle'",
      ).first("account_id"),
    ).toBe("account_owner");
  });

  it("takes the write only from a browser at this origin", async () => {
    await seedAccount("origin");
    const app = appFor("account_origin");
    const response = await app.request(`${origin}/api/v2/account/profile`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ protocol_version: 2, profile: profileBody("cross-origin") }),
    });

    expect(response.status).toBe(403);
    expect(await storedProfiles("account_origin")).toBe(0);
  });

  it("deletes the profile with the Account, releasing the handle", async () => {
    await seedAccount("gone");
    const app = appFor("account_gone");
    expect((await put(app, "leaving")).status).toBe(200);

    const deleted = await app.request(`${origin}/api/v2/account`, {
      method: "DELETE",
      headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" },
    });

    expect(deleted.status).toBe(204);
    expect(await storedProfiles("account_gone")).toBe(0);
  });
});

describe("the page a published handle answers", () => {
  it("publishes totals, shares, and a year of intensity, with no session anywhere", async () => {
    await seedAccount("page");
    await seedUsage("page");
    const app = appFor("account_page");
    expect((await put(app, "page-handle")).status).toBe(200);

    // A link retyped in another case reaches the same page, under its published handle.
    expect((await app.request(`${origin}/api/v6/public/Page-Handle/usage`)).status).toBe(200);

    const response = await app.request(`${origin}/api/v6/public/page-handle/usage`);
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
    const body = (await response.json()) as PublicUsageResponse;

    expect(Object.keys(body).sort()).toEqual([
      "activity",
      "all",
      "generated_at",
      "handle",
      "last_30_days",
      "protocol_version",
      "published_at",
    ]);
    expect(body.handle).toBe("page-handle");
    // Two days inside 30, one older: only `all` folds the third.
    expect(body.last_30_days.totals).toEqual({
      total_tokens: 24,
      input_tokens: 20,
      output_tokens: 4,
      messages: 2,
    });
    expect(body.all.totals.total_tokens).toBe(36);
    expect(body.last_30_days.providers).toEqual([
      { provider: "anthropic", total_tokens: 12, share_permille: 500 },
      { provider: "openai", total_tokens: 12, share_permille: 500 },
    ]);
    expect(body.last_30_days.models).toEqual([
      { provider: "anthropic", model: "claude-opus-5", total_tokens: 12, share_permille: 500 },
      { provider: "openai", model: "gpt-5.6-sol", total_tokens: 12, share_permille: 500 },
    ]);
    expect(body.activity).toEqual([
      { date: "2026-03-01", level: 4 },
      { date: "2026-09-05", level: 4 },
      { date: "2026-09-06", level: 4 },
    ]);

    // Nothing an anonymous reader may not see is anywhere in the body.
    const serialized = JSON.stringify(body);
    for (const forbidden of ["device", "agent", "codex", "account", "Quota Tester", "cost"]) {
      expect(serialized, forbidden).not.toContain(forbidden);
    }
  });

  it("names cost only while the owner asks for it", async () => {
    await seedAccount("cost");
    await seedUsage("cost");
    const app = appFor("account_cost");
    expect((await put(app, "priced", { showCost: true, showModels: false })).status).toBe(200);

    const body = (await (
      await app.request(`${origin}/api/v6/public/priced/usage`)
    ).json()) as PublicUsageResponse;

    expect(body.last_30_days.cost).toEqual({ amount_microusd: "210", status: "complete" });
    expect(body.last_30_days.models).toBeUndefined();
    expect(body.last_30_days.providers).toHaveLength(2);

    expect((await put(app, "priced", { showCost: false, showModels: false })).status).toBe(200);
    const quiet = (await (
      await app.request(`${origin}/api/v6/public/priced/usage`)
    ).json()) as PublicUsageResponse;
    expect(quiet.last_30_days.cost).toBeUndefined();
    expect(quiet.all.cost).toBeUndefined();
  });

  it("answers a malformed, unclaimed, or disabled handle with one 404", async () => {
    await seedAccount("hidden");
    const app = appFor("account_hidden");
    expect((await put(app, "shy-handle", { enabled: false })).status).toBe(200);

    const bodies = [];
    for (const handle of ["shy-handle", "nobody-at-all", "not a handle", "ab", "my"]) {
      const response = await app.request(`${origin}/api/v6/public/${handle}/usage`);
      expect(response.status, handle).toBe(404);
      expect(response.headers.get("Cache-Control"), handle).not.toBe("public, max-age=300");
      bodies.push(await response.json());
    }

    expect(new Set(bodies.map((body) => JSON.stringify(body))).size).toBe(1);
    expect(bodies[0]).toEqual({
      error: { code: "not_found", message: "The requested resource was not found." },
    });
  });

  it("answers a held validator with 304 and reads no Usage to do it", async () => {
    await seedAccount("etag");
    await seedUsage("etag");
    const statements: string[] = [];
    const app = appFor("account_etag", recordingD1(statements));
    expect((await put(app, "cached")).status).toBe(200);

    const first = await app.request(`${origin}/api/v6/public/cached/usage`);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);

    statements.length = 0;
    const second = await app.request(`${origin}/api/v6/public/cached/usage`, {
      headers: { "If-None-Match": etag ?? "" },
    });

    expect(second.status).toBe(304);
    expect(second.headers.get("Cache-Control")).toBe("public, max-age=300");
    expect(statements.filter((sql) => sql.includes("usage_daily"))).toEqual([]);
  });

  it("renders the same page through the document port a public document loads from", async () => {
    await seedAccount("ssr");
    await seedUsage("ssr");
    expect((await put(appFor("account_ssr"), "rendered")).status).toBe(200);

    const port = createWebDocumentPort({
      webSessions: signedOutWebSessions,
      state: new D1AccountState(env.DB),
      usageState: new D1UsageState(env.DB),
      catalog: PRICING_CATALOG,
      modelCatalog: MODEL_CATALOG,
      now: () => now,
    });

    expect(await port.getViewer(new Headers())).toBeNull();
    expect((await port.readPublicProfile("rendered"))?.handle).toBe("rendered");
    expect(await port.readPublicProfile("someone-else")).toBeNull();
  });
});

function profileBody(
  handle: string,
  options: { enabled?: boolean; showModels?: boolean; showCost?: boolean } = {},
) {
  return {
    handle,
    enabled: options.enabled ?? true,
    show_models: options.showModels ?? true,
    show_cost: options.showCost ?? false,
  };
}

function put(
  app: ReturnType<typeof createRelayApp>,
  handle: string,
  options: { enabled?: boolean; showModels?: boolean; showCost?: boolean } = {},
) {
  return app.request(`${origin}/api/v2/account/profile`, {
    method: "PUT",
    ...webRequest,
    body: JSON.stringify({ protocol_version: 2, profile: profileBody(handle, options) }),
  });
}

async function seedAccount(name: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES ('account_${name}', 'Quota Tester', ?1, ?1)`,
    ).bind(now.toISOString()),
    env.DB.prepare(
      `INSERT INTO devices (
         id, account_id, installation_id_hash, generation, created_at, last_login_at
       ) VALUES ('device_${name}', 'account_${name}', 'installation_${name}', 1, ?1, ?1)`,
    ).bind(now.toISOString()),
  ]);
}

/** Two days inside the trailing 30 and one far outside it, on two providers. */
async function seedUsage(name: string): Promise<void> {
  await env.DB.batch([
    dailyRow(name, "2026-09-06", "claude-opus-5", "anthropic_direct"),
    dailyRow(name, "2026-09-05", "gpt-5.6-sol", "openai_direct"),
    dailyRow(name, "2026-03-01", "gpt-5.6-sol", "openai_direct"),
  ]);
}

function storedProfiles(accountId: string): Promise<unknown> {
  return env.DB.prepare("SELECT COUNT(*) AS count FROM public_profiles WHERE account_id = ?1")
    .bind(accountId)
    .first("count");
}

function dailyRow(name: string, date: string, model: string, channel: string): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_daily (
       device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
       service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
       cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
       output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
       source_cost_microusd, source_cost_covered_requests, partial_hours
     ) VALUES (
       'device_${name}', ?1, 'codex', ?3, 'agent_default', ?2, 'le_128k',
       'unknown', 'unknown', 'unknown', 10, 0,
       0, 0, 0, 2, 0, 1, 0, 0, NULL, 0, 0
     )`,
  ).bind(date, model, channel);
}

function appFor(accountId: string, database: D1Database = env.DB) {
  const state = new D1AccountState(database);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(database),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, now),
    hasher,
    now: () => now,
  });
}

function recordingD1(statements: string[]): D1Database {
  return new Proxy(env.DB, {
    get(target, property, receiver) {
      if (property === "prepare") {
        return (sql: string) => {
          statements.push(sql);
          return target.prepare(sql);
        };
      }
      const value = Reflect.get(target, property, receiver);
      return typeof value === "function"
        ? (value as (...args: never[]) => unknown).bind(target)
        : value;
    },
  });
}
