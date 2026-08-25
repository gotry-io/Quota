import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import type { AccountUsageSummary } from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, inject, it } from "vitest";
import type { WebAccountAuth } from "../src/account/better-auth.ts";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import { normalizePublicSlug, publicProfileFromAccount } from "../src/public-profile.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";

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
    coverage: "complete",
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
            status: "available",
            observed_at: now.toISOString(),
          },
        },
      ],
      usage: usageSummary(),
      now,
    });
    const serialized = JSON.stringify(profile);
    expect(profile.username).toBe("octocat");
    expect(profile.quota[0]?.windows[0]?.title).toBe("Weekly");
    expect(profile.usage.models[0]?.name).toBe("gpt-5");
    expect(serialized).not.toContain("device_secret");
    expect(serialized).not.toContain("aaaaaaaa");
  });

  it("publishes the current reading for a provider and drops one that aged out", () => {
    const observation = (
      device_id: string,
      provider: "codex" | "cursor",
      observedAt: string,
      updatedAt: string,
    ) => ({
      device_id,
      sequence: 3,
      captured_at: observedAt,
      updated_at: updatedAt,
      snapshot: {
        provider,
        account: {
          fingerprint: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          fingerprint_scope: "global" as const,
          plan: provider,
        },
        windows: [{ id: "weekly", title: "Weekly", used_percent: 20 }],
        status: "available" as const,
        observed_at: observedAt,
      },
    });

    const profile = publicProfileFromAccount({
      slug: "octocat",
      displayLabel: "octocat",
      snapshots: [
        // Written to Relay a moment ago, but the reading itself is two days old: a device
        // re-uploading what it already knows does not make that reading current.
        observation("device_a", "cursor", "2026-08-11T12:00:00Z", now.toISOString()),
        observation("device_b", "cursor", "2026-08-13T11:00:00Z", "2026-08-13T11:00:05Z"),
        // The only device reporting Codex stopped collecting two days ago.
        observation("device_a", "codex", "2026-08-11T12:00:00Z", now.toISOString()),
      ],
      usage: usageSummary(),
      now,
    });

    expect(profile.quota.map((entry) => entry.provider)).toEqual(["cursor"]);
    expect(profile.quota[0]?.windows[0]?.used_percent).toBe(20);
  });

  it("publishes one row per subscription, so one provider can carry two accounts", () => {
    const observation = (fingerprint: string, plan: string, usedPercent: number) => ({
      device_id: "device_a",
      sequence: 3,
      captured_at: now.toISOString(),
      updated_at: now.toISOString(),
      snapshot: {
        provider: "cursor" as const,
        account: { fingerprint, fingerprint_scope: "global" as const, plan },
        windows: [{ id: "weekly", title: "Weekly", used_percent: usedPercent }],
        status: "available" as const,
        observed_at: now.toISOString(),
      },
    });

    const profile = publicProfileFromAccount({
      slug: "octocat",
      displayLabel: "octocat",
      snapshots: [
        observation(
          "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "ultra",
          20,
        ),
        observation("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "pro", 70),
      ],
      usage: usageSummary(),
      now,
    });

    // Ordered by the same identity comparator every reader sorts by, not by arrival.
    expect(profile.quota.map((entry) => [entry.provider, entry.plan])).toEqual([
      ["cursor", "pro"],
      ["cursor", "ultra"],
    ]);
    expect(JSON.stringify(profile)).not.toContain("bbbbbbbb");
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
