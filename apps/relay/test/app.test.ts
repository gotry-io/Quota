import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { MAXIMUM_USAGE_PERIOD_LEAVES, type OAuthTokenResponse } from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal, UsageUpload } from "@gotry-io/relay-core";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
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

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("managed Relay on real Workers and D1", () => {
  it("refuses to rebuild an hour this device's deletion watermark covers", async () => {
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
    const usage = new D1UsageState(env.DB);
    const written = await usage.recordUsage(
      devicePrincipal("watermark", 2),
      usageUpload(
        [
          usageHour("2026-08-10T09:00:00Z", 1),
          // The watermark falls inside this hour, so a new generation may rebuild it.
          usageHour("2026-08-10T10:00:00Z", 1),
        ],
        2,
      ),
      now.toISOString(),
    );

    expect(written).toEqual({
      outcome: "written",
      accepted: ["2026-08-10T10:00:00Z"],
      ignored: ["2026-08-10T09:00:00Z"],
    });
    expect(
      await env.DB.prepare(
        "SELECT bucket_start_utc FROM usage_hourly WHERE device_id = 'device_watermark'",
      ).all<{ bucket_start_utc: string }>(),
    ).toMatchObject({ results: [{ bucket_start_utc: "2026-08-10T10:00:00Z" }] });
  });

  it("replaces an hour only for a scan that read it more recently", async () => {
    await seedDevice("replace");
    const usage = new D1UsageState(env.DB);
    const principal = devicePrincipal("replace", 1);
    const hour = "2026-08-10T10:00:00Z";
    const models = async () =>
      (
        await env.DB.prepare(
          "SELECT model FROM usage_hourly WHERE device_id = 'device_replace' ORDER BY model",
        ).all<{ model: string }>()
      ).results.map((row) => row.model);

    expect(
      await usage.recordUsage(
        principal,
        usageUpload([usageHour(hour, 3, ["first-model"])]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "written", accepted: [hour], ignored: [] });
    expect(await models()).toEqual(["first-model"]);

    // A newer scan of the same hour replaces every row it found before.
    expect(
      await usage.recordUsage(
        principal,
        usageUpload([usageHour(hour, 4, ["second-model"])]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "written", accepted: [hour], ignored: [] });
    expect(await models()).toEqual(["second-model"]);

    // An older or repeated scan is a comparison, not a write.
    for (const version of [3, 4]) {
      expect(
        await usage.recordUsage(
          principal,
          usageUpload([usageHour(hour, version, ["third-model"])]),
          now.toISOString(),
        ),
      ).toEqual({ outcome: "written", accepted: [], ignored: [hour] });
    }
    expect(await models()).toEqual(["second-model"]);
  });

  it("keeps the daily rollup equal to the hours behind it", async () => {
    await seedDevice("rollup");
    const usage = new D1UsageState(env.DB);
    const principal = devicePrincipal("rollup", 1);
    await usage.recordUsage(
      principal,
      usageUpload([
        usageHour("2026-08-09T23:00:00Z", 1, ["gpt-5.6-sol"]),
        usageHour("2026-08-10T00:00:00Z", 1, ["gpt-5.6-sol"]),
        usageHour("2026-08-10T01:00:00Z", 1, ["gpt-5.6-sol", "claude-opus-5"], true),
      ]),
      now.toISOString(),
    );

    expect(await dailyMismatch()).toEqual([]);
    const daily = await env.DB.prepare(
      `SELECT utc_date, model, requests, partial_hours FROM usage_daily
       WHERE device_id = 'device_rollup' ORDER BY utc_date, model`,
    ).all<{ utc_date: string; model: string; requests: number; partial_hours: number }>();
    expect(daily.results).toEqual([
      { utc_date: "2026-08-09", model: "gpt-5.6-sol", requests: 1, partial_hours: 0 },
      { utc_date: "2026-08-10", model: "claude-opus-5", requests: 1, partial_hours: 1 },
      { utc_date: "2026-08-10", model: "gpt-5.6-sol", requests: 2, partial_hours: 1 },
    ]);

    // Rescanning one hour rewrites only the dates that hour touches.
    await usage.recordUsage(
      principal,
      usageUpload([usageHour("2026-08-10T01:00:00Z", 2, ["gpt-5.6-sol"])]),
      now.toISOString(),
    );
    expect(await dailyMismatch()).toEqual([]);
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_daily WHERE device_id = 'device_rollup'",
      ).first("count"),
    ).toBe(2);
  });

  it("refuses an upload from a generation the device has moved past", async () => {
    await seedDevice("stale");
    const usage = new D1UsageState(env.DB);
    expect(
      await usage.recordUsage(
        devicePrincipal("stale", 2),
        usageUpload([usageHour("2026-08-10T10:00:00Z", 1)]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "stale_device" });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_hourly WHERE device_id = 'device_stale'",
      ).first("count"),
    ).toBe(0);
  });

  it("serves every managed provider and agent from the one summary contract", async () => {
    const quotaSnapshot = (provider: "codex" | "cursor", fingerprint: string) =>
      JSON.stringify({
        provider,
        account: { fingerprint, fingerprint_scope: "global" },
        windows: [],
        status: "available",
        observed_at: now.toISOString(),
      });
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_agents', 'subject_agents', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_agents', 'account_agents', 'installation_agents', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol"),
      usageDailyInsert("grok", "xai_direct", "grok-4.5"),
      usageDailyInsert("cursor", "openai_direct", "cursor-small"),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
           ) VALUES ('device_agents', ?1, ?2, ?3, ?4, ?3)`,
      ).bind(
        "codex",
        "codex_fingerprint",
        now.toISOString(),
        quotaSnapshot("codex", "codex_fingerprint"),
      ),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
           ) VALUES ('device_agents', ?1, ?2, ?3, ?4, ?3)`,
      ).bind(
        "cursor",
        "cursor_fingerprint",
        now.toISOString(),
        quotaSnapshot("cursor", "cursor_fingerprint"),
      ),
    ]);

    const app = appFor("account_agents");
    const summary = (await (
      await app.request("https://quota.gotry.io/api/v6/account/summary")
    ).json()) as {
      protocol_version: number;
      subscriptions: Array<{ provider: string }>;
      usage: { all: { totals: { messages: number }; agents: Array<{ agent: string }> } };
    };

    expect(summary).toMatchObject({ protocol_version: 6 });
    expect(summary.usage.all.totals.messages).toBe(3);
    expect(summary.usage.all.agents.map((agent) => agent.agent)).toEqual([
      "codex",
      "cursor",
      "grok",
    ]);
    expect(summary.subscriptions.map((subscription) => subscription.provider)).toEqual([
      "codex",
      "cursor",
    ]);

    // The retired data routes are gone rather than kept answering an older shape, and they say
    // so as the one thing a caller on them can do: a version this deployment no longer serves
    // cannot be retried back into existence.
    for (const retired of ["/api/v3/account/summary", "/api/v5/account/summary"]) {
      const response = await app.request(`https://quota.gotry.io${retired}`);
      expect(response.status).toBe(404);
      expect(await response.json()).toMatchObject({
        error: { code: "client_upgrade_required" },
      });
    }

    // A version this deployment does serve, spelled wrong, is a wrong path and stays one, so a
    // routing mistake of our own cannot hide behind an upgrade prompt.
    const wrong = await app.request("https://quota.gotry.io/api/v2/account/snapshots");
    expect(wrong.status).toBe(404);
    expect(await wrong.json()).toMatchObject({ error: { code: "not_found" } });
    const mistyped = await app.request("https://quota.gotry.io/api/v6/account/sumary");
    expect(await mistyped.json()).toMatchObject({ error: { code: "not_found" } });
  });

  it("answers an unchanged Account read from its validator instead of folding Usage again", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_etag', 'subject_etag', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at, last_seen_at
         ) VALUES ('device_etag', 'account_etag', 'installation_etag', 1, ?1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_etag",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_etag");

    const summaryPath = "https://quota.gotry.io/api/v6/account/summary";
    const first = await app.request(summaryPath);
    expect(first.status).toBe(200);
    // `no-cache` is what makes the second request conditional at all: the browser may keep the
    // body as long as it revalidates before showing it.
    expect(first.headers.get("Cache-Control")).toBe("private, no-cache");
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);

    const unchanged = await app.request(summaryPath, { headers: { "If-None-Match": etag ?? "" } });
    expect(unchanged.status).toBe(304);
    expect(unchanged.headers.get("ETag")).toBe(etag);
    expect(await unchanged.text()).toBe("");

    // Two routes answer with different bodies, and a different calendar names different days,
    // so neither may reuse the other's validator.
    const activity = await app.request(
      "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-01&to=2026-08-10",
    );
    expect(activity.status).toBe(200);
    expect(activity.headers.get("ETag")).not.toBe(etag);
    const elsewhere = await app.request(`${summaryPath}?tz=Asia/Singapore`);
    expect(elsewhere.headers.get("ETag")).not.toBe(etag);

    // A new observation is a new answer even though no Usage fact moved.
    await env.DB.prepare(
      `INSERT INTO quota_snapshots (
         device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
       ) VALUES ('device_etag', 'codex', 'fingerprint_etag', ?1, ?2, ?1)`,
    )
      .bind(now.toISOString(), JSON.stringify(quotaSnapshotJson()))
      .run();
    const afterUpload = await app.request(summaryPath, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(afterUpload.status).toBe(200);
    expect(afterUpload.headers.get("ETag")).not.toBe(etag);

    // A query key this route does not serve is still refused rather than validated.
    const bogus = await app.request(`${summaryPath}?nonsense=1`, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(bogus.status).toBe(400);
    expect(bogus.headers.get("ETag")).toBeNull();
    // So is a timezone that names no calendar.
    expect((await app.request(`${summaryPath}?tz=Mars/Olympus_Mons`)).status).toBe(400);
  });

  it("reports every billing channel it stores without an opt-in", async () => {
    const channelFact = (channel: string, channelSource: string, model: string) =>
      usageDailyInsert("opencode", channel, model, {
        deviceID: "device_channels",
        channelSource,
      });
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_channels', 'subject_channels', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_channels', 'account_channels', 'installation_channels', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      channelFact("moonshot_direct", "explicit", "k2p5"),
      channelFact("deepseek_direct", "explicit", "deepseek-v4-flash"),
      // Already unknown, so a narrowed row must fold into this group instead of
      // producing a second `unknown` provider.
      channelFact("unknown", "unknown", "big-pickle"),
    ]);
    const app = appFor("account_channels");
    const response = await app.request("https://quota.gotry.io/api/v6/account/summary");
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      usage: { all: { agents: Array<{ providers: Array<{ provider: string }> }> } };
    };
    expect(
      body.usage.all.agents.flatMap((agent) => agent.providers.map(({ provider }) => provider)),
    ).toEqual(["deepseek", "moonshot", "unknown"]);

    // The retired opt-in is not a query key any more.
    expect(
      (await app.request("https://quota.gotry.io/api/v6/account/summary?usage_channels=1")).status,
    ).toBe(400);
  });

  it("serves the current pricing and model catalogs", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webSessions: new SignedInWebSessionStub("account_catalogs", now),
      hasher,
      now: () => now,
    });

    const pricing = (await (
      await app.request("https://quota.gotry.io/api/v2/pricing/catalog")
    ).json()) as { entries: Array<{ billing_channel: string }> };
    const invalid = await app.request(
      "https://quota.gotry.io/api/v2/pricing/catalog?usage_agents=all",
    );

    expect(pricing.entries.some((entry) => entry.billing_channel === "xai_direct")).toBe(true);
    expect(invalid.status).toBe(400);

    const modelCatalog = await app.request("https://quota.gotry.io/api/v2/model/catalog");
    expect(modelCatalog.status).toBe(200);
    expect(modelCatalog.headers.get("cache-control")).toBe("public, max-age=300, must-revalidate");
    const modelETag = modelCatalog.headers.get("etag");
    expect(modelETag).toBeTruthy();
    expect((await modelCatalog.json()) as { revision: string }).toMatchObject({
      revision: expect.any(String),
    });
    const modelNotModified = await app.request("https://quota.gotry.io/api/v2/model/catalog", {
      headers: { "If-None-Match": modelETag ?? "" },
    });
    expect(modelNotModified.status).toBe(304);
    expect(
      (await app.request("https://quota.gotry.io/api/v2/model/catalog?unexpected=1")).status,
    ).toBe(400);
  });

  it("answers every retained day and the trailing windows the caller's calendar names", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_history', 'account_history', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_history', 'account_history', 'installation_history', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_history",
        date: "2025-01-01",
      }),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-luna", {
        deviceID: "device_history",
        date: "2026-08-09",
      }),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_history",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_history");

    const summary = (await (
      await app.request("https://quota.gotry.io/api/v6/account/summary")
    ).json()) as {
      usage: Record<
        string,
        {
          totals: { messages: number };
          agents: Array<{ providers: Array<{ models: Array<{ model: string }> }> }>;
        }
      >;
      pricing_revision: string;
      model_catalog_revision: string;
    };

    expect(summary.usage.today?.totals.messages).toBe(1);
    expect(summary.usage.last_7_days?.totals.messages).toBe(2);
    expect(summary.usage.last_30_days?.totals.messages).toBe(2);
    expect(summary.usage.all?.totals.messages).toBe(3);
    // The agent tree is part of the contract, not something a caller asks for.
    expect(summary.usage.all?.agents).toMatchObject([
      { agent: "codex", providers: [{ provider: "openai" }] },
    ]);
    expect(summary.pricing_revision).toEqual(expect.any(String));
    expect(summary.model_catalog_revision).toEqual(expect.any(String));

    const models = (
      period:
        | { agents: Array<{ providers: Array<{ models: Array<{ model: string }> }> }> }
        | undefined,
    ) =>
      (period?.agents ?? []).flatMap((agent) =>
        agent.providers.flatMap((provider) => provider.models.map((model) => model.model)),
      );
    expect(models(summary.usage.today)).toEqual(["gpt-5.6-sol"]);

    // A calendar behind UTC moves which day `today` names without moving a stored day.
    const behind = (await (
      await app.request("https://quota.gotry.io/api/v6/account/summary?tz=America/Los_Angeles")
    ).json()) as {
      usage: Record<
        string,
        { agents: Array<{ providers: Array<{ models: Array<{ model: string }> }> }> }
      >;
    };
    expect(models(behind.usage.today)).toEqual(["gpt-5.6-luna"]);

    const activity = (await (
      await app.request(
        "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-01&to=2026-08-10",
      )
    ).json()) as { days: Array<{ date: string; totals: { messages: number } }> };
    expect(activity.days.map((day) => day.date)).toEqual(["2026-08-09", "2026-08-10"]);

    // A range longer than the read answers, and a reversed one, are refused rather than capped.
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v6/account/usage/activity?from=2024-01-01&to=2026-08-10",
        )
      ).status,
    ).toBe(400);
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-10&to=2026-08-01",
        )
      ).status,
    ).toBe(400);
  });

  it("bounds a high-cardinality period without losing what it totals", async () => {
    const models = JSON.stringify(Array.from({ length: 1_001 }, (_, index) => index));
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_cardinality', 'subject_cardinality', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_cardinality', 'account_cardinality', 'installation_cardinality', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO usage_daily (
           device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
           service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
           cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
           output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
           source_cost_microusd, source_cost_covered_requests, partial_hours
         )
         SELECT 'device_cardinality', '2026-08-09', 'codex', 'openai_direct', 'agent_default',
                'model-' || value, 'le_128k', 'unknown', 'unknown', 'unknown',
                10, 0, 0, 0, 0, 2, 0, 1, 0, 0, NULL, 0, 0
         FROM json_each(?1)`,
      ).bind(models),
    ]);
    const app = appFor("account_cardinality");

    const response = await app.request("https://quota.gotry.io/api/v6/account/summary");
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      usage: {
        all: {
          totals: { messages: number };
          cost: { unpriced_truncated?: boolean };
          agents: Array<{ providers: Array<{ models: Array<{ model: string }> }> }>;
        };
      };
    };
    const leaves = body.usage.all.agents.flatMap((agent) =>
      agent.providers.flatMap((provider) => provider.models),
    );
    expect(body.usage.all.totals.messages).toBe(1_001);
    expect(leaves.length).toBeLessThanOrEqual(MAXIMUM_USAGE_PERIOD_LEAVES);
    expect(leaves.some((leaf) => leaf.model === "other")).toBe(true);
    expect(body.usage.all.cost.unpriced_truncated).toBe(true);
  });

  it("answers an account whose stored reading this build cannot read", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_unreadable', 'subject_unreadable', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_unreadable', 'account_unreadable', 'installation_unreadable', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      // A row a retired build wrote, still carrying the fields this contract removed.
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
           ) VALUES ('device_unreadable', 'codex', 'fingerprint', ?1, ?2, ?1)`,
      ).bind(
        now.toISOString(),
        JSON.stringify({
          provider: "codex",
          account: { fingerprint: "fingerprint", fingerprint_scope: "global" },
          windows: [],
          source: "chatgpt_usage_api",
          status: "available",
          observed_at: now.toISOString(),
          valid_until: now.toISOString(),
        }),
      ),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
           ) VALUES ('device_unreadable', 'cursor', 'fingerprint', ?1, ?2, ?1)`,
      ).bind(
        now.toISOString(),
        JSON.stringify({
          provider: "cursor",
          account: { fingerprint: "fingerprint", fingerprint_scope: "global" },
          windows: [],
          status: "available",
          observed_at: now.toISOString(),
        }),
      ),
    ]);

    const stored = await new D1AccountState(env.DB).listLatestSnapshots("account_unreadable");

    // The reading it can read is answered; the one it cannot is dropped, not raised.
    expect(stored.map((observation) => observation.snapshot.provider)).toEqual(["cursor"]);
  });

  it("keeps every session in one table", async () => {
    // `d1_migrations` is the ladder itself, not storage this deployment designed.
    const tables = await env.DB.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'
         AND name <> 'd1_migrations'
       ORDER BY name`,
    ).all<{ name: string }>();
    expect(tables.results.map((row) => row.name)).toEqual([
      "accounts",
      "devices",
      "login_grants",
      "quota_snapshots",
      "rate_limit_counters",
      "sessions",
      "usage_daily",
      "usage_hourly",
    ]);
  });

  it("no longer stores anything an unauthenticated reader could have asked for", async () => {
    const columns = await env.DB.prepare("PRAGMA table_info(accounts)").all<{ name: string }>();
    const names = columns.results.map((column) => column.name);
    expect(names).not.toContain("public_profile_enabled");
    expect(names).not.toContain("public_profile_slug");
    const indexes = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'accounts'",
    ).all<{ name: string }>();
    expect(indexes.results.map((index) => index.name)).not.toContain(
      "accounts_public_profile_slug",
    );
  });

  it("keeps a sleeping device's reading and deletes one nothing will read again", async () => {
    const snapshot = (provider: string, observedAt: string) =>
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
           ) VALUES ('device_retention', ?1, 'fingerprint', ?2, '{}', ?3)`,
      ).bind(provider, observedAt, now.toISOString());
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_retention', 'subject_retention', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_retention', 'account_retention', 'installation_retention', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      // A Mac that has been closed for two days: still the account's only reading of it.
      snapshot("codex", "2026-08-08T00:00:00Z"),
      // A provider this device stopped collecting long enough ago that nothing reads it.
      snapshot("cursor", "2026-08-01T00:00:00Z"),
    ]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));

    const remaining = await env.DB.prepare(
      "SELECT provider FROM quota_snapshots WHERE device_id = 'device_retention' ORDER BY provider",
    ).all<{ provider: string }>();
    expect(remaining.results.map((row) => row.provider)).toEqual(["codex"]);
  });

  it("expires one rate-limit window without resetting that subject's live one", async () => {
    const state = new D1AccountState(env.DB);
    const counter = (startedAt: string, expiresAt: string) =>
      env.DB.prepare(
        `INSERT INTO rate_limit_counters (key_hash, window_started_at, window_expires_at, request_count)
         VALUES ('subject_hash', ?1, ?2, 5)`,
      ).bind(startedAt, expiresAt);
    await env.DB.batch([
      counter("2026-08-09T23:00:00.000Z", "2026-08-09T23:10:00.000Z"),
      counter("2026-08-10T00:00:00.000Z", "2026-08-10T00:10:00.000Z"),
    ]);

    // Consuming the live window also collects expired rows; the live counter must survive, or
    // an exhausted subject buys a fresh allowance by making one more request.
    const result = await state.consumeRateLimit({
      key_hash: "subject_hash",
      window_started_at: "2026-08-10T00:00:00.000Z",
      window_expires_at: "2026-08-10T00:10:00.000Z",
      checked_at: now.toISOString(),
      limit: 10,
    });
    expect(result.allowed).toBe(true);
    const exhausted = await state.consumeRateLimit({
      key_hash: "subject_hash",
      window_started_at: "2026-08-10T00:00:00.000Z",
      window_expires_at: "2026-08-10T00:10:00.000Z",
      checked_at: now.toISOString(),
      limit: 6,
    });
    expect(exhausted.allowed).toBe(false);
    const rows = await env.DB.prepare(
      "SELECT window_started_at FROM rate_limit_counters ORDER BY window_started_at",
    ).all<{ window_started_at: string }>();
    expect(rows.results.map((row) => row.window_started_at)).toEqual(["2026-08-10T00:00:00.000Z"]);
  });

  it("completes browser PKCE through a Web principal and issues one session", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const service = new AccountService(state, hasher, secret);
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('identity_subject', 'identity_subject', 'Quota Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const webSessions = new SignedInWebSessionStub("identity_subject", now);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: service,
      webSessions,
      hasher,
      now: () => now,
    });
    const callbackURL = (): string => `https://quota.gotry.io${webSessions.returnTo}`;

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
      client_id: "quotabar",
      redirect_uri: "http://127.0.0.1:43210/callback",
      state: "client-state-123456789",
      code_challenge: challenge,
      code_challenge_method: "S256",
    }).toString();
    expect((await app.request(authorize)).status).toBe(302);

    const complete = await app.request(callbackURL());
    expect(complete.status).toBe(302);
    const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
    expect(code).toBeTruthy();

    const exchanged = await app.request("https://quota.gotry.io/oauth/v2/token", {
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
    expect(tokens.account_id).toBe("identity_subject");
    expect(tokens.device_generation).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);
    // One login, one row, and it carries both halves of what that login is for.
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM sessions WHERE device_id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);

    const oldAccessHash = await hasher.hash("quotabar-access", tokens.session.access_token);
    expect(await state.authorizeSession(oldAccessHash, now.toISOString())).toMatchObject({
      device_id: tokens.device_id,
      device_generation: 1,
      client_kind: "quotabar",
      scopes: ["account:read", "device:write"],
    });
    // The one token reads the Account it was issued for, and writes only its own Device.
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers: { Authorization: `Bearer ${tokens.session.access_token}` },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v2/device/profile", {
          method: "PUT",
          headers: {
            Authorization: `Bearer ${tokens.session.access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            protocol_version: 2,
            display_name: "Kyle's Mac mini",
            platform: "macos",
          }),
        })
      ).status,
    ).toBe(200);
    expect(
      await env.DB.prepare("SELECT display_name FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("display_name"),
    ).toBe("Kyle's Mac mini");
    // Reads are tolerant of a field this build cannot name; a write is not. (ADR 0023)
    const deviceHeaders = {
      Authorization: `Bearer ${tokens.session.access_token}`,
      "Content-Type": "application/json",
    };
    expect(
      (
        await app.request("https://quota.gotry.io/api/v2/device/profile", {
          method: "PUT",
          headers: deviceHeaders,
          body: JSON.stringify({
            protocol_version: 2,
            display_name: "Kyle's Mac mini",
            platform: "macos",
            reported_at: now.toISOString(),
          }),
        })
      ).status,
    ).toBe(400);
    const envelope = {
      protocol_version: 6,
      generation: tokens.device_generation,
      snapshots: [
        {
          provider: "codex",
          account: { fingerprint: "fingerprint_strict", fingerprint_scope: "global" },
          windows: [{ id: "weekly", title: "Weekly", used_percent: 25 }],
          status: "available",
          observed_at: now.toISOString(),
        },
      ],
    };
    const uploaded = await app.request("https://quota.gotry.io/api/v6/device/snapshots", {
      method: "PUT",
      headers: deviceHeaders,
      body: JSON.stringify(envelope),
    });
    expect(uploaded.status).toBe(200);
    expect(await uploaded.json()).toMatchObject({ accepted: ["codex"], ignored: [] });
    // The same reading again is a comparison, not a write, and says so.
    const again = await app.request("https://quota.gotry.io/api/v6/device/snapshots", {
      method: "PUT",
      headers: deviceHeaders,
      body: JSON.stringify(envelope),
    });
    expect(await again.json()).toMatchObject({ accepted: [], ignored: ["codex"] });
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/device/snapshots", {
          method: "PUT",
          headers: deviceHeaders,
          body: JSON.stringify({ ...envelope, uploaded_at: now.toISOString() }),
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${tokens.session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeSession(oldAccessHash, now.toISOString())).toBeNull();

    // Delete Device advances the generation, and a token issued at the old one is refused even
    // with every other reason to refuse it removed.
    const deletedAt = new Date(now.getTime() + 1_000).toISOString();
    expect(
      await state.deleteDeviceData(tokens.account_id, tokens.device_id, deletedAt),
    ).toMatchObject({ device_id: tokens.device_id, generation: 2 });
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL, deleted_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    await env.DB.prepare("UPDATE sessions SET revoked_at = NULL WHERE device_id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeSession(oldAccessHash, deletedAt)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 1)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 2)).toMatchObject({ generation: 2 });

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare(
      "UPDATE login_grants SET redirect_uri = 'https://attacker.invalid/callback' WHERE completed_at IS NULL",
    ).run();
    const unsafeRedirect = await app.request(callbackURL());
    expect(unsafeRedirect.status).toBe(400);
    expect(unsafeRedirect.headers.get("location")).toBeNull();
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM login_grants WHERE completed_at IS NOT NULL AND redirect_uri = 'https://attacker.invalid/callback'",
      ).first("count"),
    ).toBe(0);

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(tokens.account_id).run();
    expect((await app.request(callbackURL())).status).toBe(401);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
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
});

async function seedDevice(name: string, generation = 1): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, created_at, updated_at)
       VALUES ('account_${name}', 'subject_${name}', ?1, ?1)`,
    ).bind(now.toISOString()),
    env.DB.prepare(
      `INSERT INTO devices (
         id, account_id, installation_id_hash, generation, created_at, last_login_at
       ) VALUES ('device_${name}', 'account_${name}', 'installation_${name}', ${generation}, ?1, ?1)`,
    ).bind(now.toISOString()),
  ]);
}

function devicePrincipal(name: string, generation: number): DeviceWriterPrincipal {
  return {
    session_id: `session_${name}`,
    family_id: `family_${name}`,
    account_id: `account_${name}`,
    device_id: `device_${name}`,
    device_generation: generation,
    client_kind: "quotabar",
    scopes: ["account:read", "device:write"],
    authenticated_at: now.toISOString(),
  };
}

function usageRow(model: string) {
  return {
    agent: "codex" as const,
    billing_channel: "openai_direct" as const,
    channel_source: "agent_default" as const,
    model,
    context_bucket: "le_128k" as const,
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
  };
}

function usageHour(
  bucket: string,
  scanVersion: number,
  models: readonly string[] = ["gpt-5.6-sol"],
  partial = false,
) {
  return {
    bucket_start_utc: bucket,
    scan_version: scanVersion,
    partial,
    rows: models.map(usageRow),
  };
}

function usageUpload(hours: ReturnType<typeof usageHour>[], generation = 1): UsageUpload {
  return { protocol_version: 6, generation, agent: "codex", hours };
}

/**
 * Every daily row that disagrees with the hours behind it.
 *
 * The read never opens `usage_hourly`, so the only thing keeping the two in step is the upload
 * that maintains both. This is how a test says so.
 */
async function dailyMismatch(): Promise<unknown[]> {
  const rolled = await env.DB.prepare(
    `SELECT device_id, substr(bucket_start_utc, 1, 10) AS utc_date, agent, billing_channel,
            channel_source, model, context_bucket, service_tier, speed, inference_geo,
            SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
            SUM(requests) AS requests, SUM(partial) AS partial_hours
     FROM usage_hourly
     GROUP BY device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel,
              channel_source, model, context_bucket, service_tier, speed, inference_geo
     ORDER BY device_id, utc_date, agent, model`,
  ).all<Record<string, unknown>>();
  const stored = await env.DB.prepare(
    `SELECT device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
            service_tier, speed, inference_geo, input_tokens, output_tokens, requests,
            partial_hours
     FROM usage_daily
     ORDER BY device_id, utc_date, agent, model`,
  ).all<Record<string, unknown>>();
  const key = (row: Record<string, unknown>) => JSON.stringify(row);
  const expected = rolled.results.map(key);
  const actual = stored.results.map(key);
  return [
    ...expected.filter((row) => !actual.includes(row)),
    ...actual.filter((row) => !expected.includes(row)),
  ];
}

function usageDailyInsert(
  agent: string,
  channel: string,
  model: string,
  overrides: { deviceID?: string; channelSource?: string; date?: string } = {},
): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_daily (
         device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
         service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
         output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
         source_cost_microusd, source_cost_covered_requests, partial_hours
       ) VALUES (
         ?4, ?5, ?1, ?2, ?6, ?3, 'le_128k',
         'unknown', 'unknown', 'unknown', 10, 0,
         0, 0, 0, 2, 0, 1, 0, 0, NULL, 0, 0
       )`,
  ).bind(
    agent,
    channel,
    model,
    overrides.deviceID ?? "device_agents",
    overrides.date ?? "2026-08-10",
    overrides.channelSource ?? "agent_default",
  );
}

/** An app answering as the signed-in owner of one account. */
function appFor(accountId: string) {
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(env.DB),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, now),
    hasher,
    now: () => now,
  });
}

function quotaSnapshotJson() {
  return {
    provider: "codex",
    status: "available",
    observed_at: now.toISOString(),
    account: { fingerprint: "fingerprint_etag", fingerprint_scope: "global", plan: "Plus" },
    windows: [
      {
        id: "weekly",
        title: "Weekly",
        used_percent: 25,
        resets_at: new Date(now.getTime() + 86_400_000).toISOString(),
      },
    ],
  };
}
