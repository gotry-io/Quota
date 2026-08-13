import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import { normalizePublicSlug, publicProfileFromAccount } from "../src/public-profile.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import type { WebAccountAuth } from "../src/account/better-auth.ts";
import type { AccountUsageSummary } from "@gotry-io/quota-protocol";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const now = new Date("2026-08-13T12:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

const emptyCost = {
  mode: "calculate" as const,
  basis: "calculated" as const,
  status: "complete" as const,
  amount_microusd: "1000",
  catalog_revision: "pricing_1",
  calculated_rows: 1,
  reported_rows: 0,
  unpriced_rows: 0,
  assumptions: [],
  unpriced: [],
};

const emptyTotals = {
  input_tokens: 10,
  cache_read_tokens: 0,
  cache_write_5m_tokens: 0,
  cache_write_1h_tokens: 0,
  cache_write_inferred_tokens: 0,
  output_tokens: 4,
  reasoning_tokens: 0,
  requests: 1,
  web_search_requests: 0,
  web_fetch_requests: 0,
  source_cost_microusd: null,
  source_cost_covered_requests: 0,
};

function usageSummary(): AccountUsageSummary {
  return {
    range: { from: "2026-08-01", to: "2026-08-13" },
    totals: emptyTotals,
    cost: emptyCost,
    coverage: [
      {
        device_id: "device_secret",
        agent: "codex",
        start_at: "2026-08-13T00:00:00Z",
        end_at: "2026-08-13T01:00:00Z",
        status: "complete",
      },
    ],
    breakdowns: [
      {
        dimension: "model",
        key: "gpt-5",
        totals: emptyTotals,
        cost: emptyCost,
      },
    ],
  };
}

describe("public profile projection", () => {
  it("omits device identifiers from the shareable profile", () => {
    const profile = publicProfileFromAccount({
      slug: "octocat",
      displayLabel: "octocat",
      snapshots: [
        {
          device_id: "device_secret",
          sequence: 3,
          captured_at: now.toISOString(),
          updated_at: now.toISOString(),
          snapshot: {
            provider: "codex",
            account: {
              fingerprint: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              fingerprint_scope: "global",
              label: "hidden",
              plan: "Plus",
            },
            windows: [{ id: "weekly", title: "Weekly", used_percent: 20 }],
            source: "codex_rpc",
            status: "available",
            observed_at: now.toISOString(),
          },
        },
      ],
      usage: usageSummary(),
    });
    const serialized = JSON.stringify(profile);
    expect(profile.username).toBe("octocat");
    expect(profile.quota[0]?.windows[0]?.title).toBe("Weekly");
    expect(profile.usage.models[0]?.name).toBe("gpt-5");
    expect(serialized).not.toContain("device_secret");
    expect(serialized).not.toContain("aaaaaaaa");
  });

  it("normalizes opted-in slugs and rejects empty labels", () => {
    expect(normalizePublicSlug("OctoCat")).toBe("octocat");
    expect(normalizePublicSlug("  Ada Lovelace  ")).toBe("ada-lovelace");
    expect(normalizePublicSlug("***")).toBeNull();
  });
});

describe("public profile HTTP gate", () => {
  function app(sessionAccount = "account_public") {
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 404 }),
      getSession: async () => ({
        user: { id: sessionAccount, name: "Octocat" },
        session: {
          id: "web_session",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    return createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth,
      hasher,
      now: () => now,
    });
  }

  it("publishes GitHub usernames by default and ignores disable requests", async () => {
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('account_public', 'subject_public', 'octocat', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const headers = {
      Origin: "https://quota.gotry.io",
      "Sec-Fetch-Site": "same-origin",
      "Content-Type": "application/json",
    };
    const relay = app();
    const publicRead = await relay.request("https://quota.gotry.io/api/v2/public/profiles/octocat");
    expect(publicRead.status).toBe(200);
    const body = (await publicRead.json()) as { username: string; usage: { input_tokens: number } };
    expect(body.username).toBe("octocat");
    expect(body).not.toHaveProperty("devices");
    expect(
      (await relay.request("https://quota.gotry.io/api/v2/public/profiles/unknown")).status,
    ).toBe(404);
    const settings = await relay.request("https://quota.gotry.io/api/v2/account/public-profile", {
      headers,
    });
    expect(settings.status).toBe(200);
    expect(await settings.json()).toMatchObject({ enabled: true, slug: "octocat" });
    const disabled = await relay.request("https://quota.gotry.io/api/v2/account/public-profile", {
      method: "PUT",
      headers,
      body: JSON.stringify({ protocol_version: 2, enabled: false, slug: "custom-name" }),
    });
    expect(disabled.status).toBe(200);
    expect(await disabled.json()).toMatchObject({ enabled: true, slug: "octocat" });
    expect(
      (await relay.request("https://quota.gotry.io/api/v2/public/profiles/octocat")).status,
    ).toBe(200);
  });
});
