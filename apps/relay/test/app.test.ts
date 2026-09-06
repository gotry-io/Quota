import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  MAXIMUM_USAGE_PERIOD_LEAVES,
  type OAuthTokenResponse,
  type SessionRefreshResponse,
} from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal, UsageUpload } from "@gotry-io/relay-core";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { signInReturnTo } from "./native-sign-in.ts";
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_watermark', ?1, ?1)",
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_agents', ?1, ?1)",
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_etag', ?1, ?1)",
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

    // Two routes answer with different bodies, and a different calendar puts a period around
    // different instants, so neither may reuse the other's validator.
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

    // The response carries the Account's display label, which a later sign-in rewrites without
    // touching a device or an observation.
    const afterObservation = afterUpload.headers.get("ETag") ?? "";
    await env.DB.prepare(
      "UPDATE accounts SET display_label = 'octocat', updated_at = ?2 WHERE id = ?1",
    )
      .bind("account_etag", new Date(now.getTime() + 1_000).toISOString())
      .run();
    const renamed = await app.request(summaryPath, {
      headers: { "If-None-Match": afterObservation },
    });
    expect(renamed.status).toBe(200);
    expect(renamed.headers.get("ETag")).not.toBe(afterObservation);

    // The reading that speaks for a subscription changes with the clock alone: past its own
    // validity boundary it stops describing current quota. A held answer must not outlive that.
    const later = appFor("account_etag", new Date(now.getTime() + 3_600_000));
    const nextHour = await later.request(summaryPath, {
      headers: { "If-None-Match": renamed.headers.get("ETag") ?? "" },
    });
    expect(nextHour.status).toBe(200);

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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_channels', ?1, ?1)",
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_history', ?1, ?1)",
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
      // The hours behind the two recent days, which is what a caller off UTC reads them from.
      usageHourInsert("codex", "openai_direct", "gpt-5.6-luna", "2026-08-09T12:00:00Z"),
      usageHourInsert("codex", "openai_direct", "gpt-5.6-sol", "2026-08-10T12:00:00Z"),
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

    // A calendar behind UTC moves where today begins without moving a stored day: seven hours
    // of 9 August UTC are still yesterday in Los Angeles, and the rest of today is 10 August.
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

  it("adds a day's agent tree only for a single UTC day asked with detail=agents", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_activity_detail', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_activity_detail', 'account_activity_detail', 'installation_activity_detail', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_activity_detail",
        date: "2026-08-10",
      }),
      usageDailyInsert("claude_code", "anthropic_direct", "claude-opus-4-6", {
        deviceID: "device_activity_detail",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_activity_detail");
    const dayPath =
      "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-10&to=2026-08-10";
    type ActivityAgent = {
      agent: string;
      providers: Array<{
        provider: string;
        models: Array<{ model: string; totals: { messages: number; total_tokens: number } }>;
      }>;
    };
    type ActivityDay = {
      date: string;
      totals: { messages: number; total_tokens: number };
      cost: { status: string };
      partial: boolean;
      agents?: ActivityAgent[];
    };
    type ActivityBody = { days: ActivityDay[] };

    const plainResponse = await app.request(dayPath);
    expect(plainResponse.status).toBe(200);
    const plain = (await plainResponse.json()) as ActivityBody;
    expect(plain.days).toHaveLength(1);
    expect(Object.hasOwn(plain.days[0] ?? {}, "agents")).toBe(false);

    const detailedResponse = await app.request(`${dayPath}&detail=agents`);
    expect(detailedResponse.status).toBe(200);
    const detailed = (await detailedResponse.json()) as ActivityBody;
    expect(detailed.days).toHaveLength(1);
    const day = detailed.days[0];
    expect(day?.date).toBe("2026-08-10");
    expect(day?.totals).toEqual(plain.days[0]?.totals);
    expect(day?.cost).toEqual(plain.days[0]?.cost);
    expect(day?.partial).toBe(plain.days[0]?.partial);
    const leafMessages = (day?.agents ?? []).reduce(
      (total, agent) =>
        total +
        agent.providers.reduce(
          (providerTotal, provider) =>
            providerTotal +
            provider.models.reduce((modelTotal, model) => modelTotal + model.totals.messages, 0),
          0,
        ),
      0,
    );
    expect(leafMessages).toBe(day?.totals.messages);

    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-01&to=2026-08-10&detail=agents",
        )
      ).status,
    ).toBe(400);
    expect((await app.request(`${dayPath}&detail=models`)).status).toBe(400);
  });

  it("keys the activity ETag on Usage and not on a quota snapshot", async () => {
    await seedDevice("activity_etag");
    const usage = new D1UsageState(env.DB);
    const principal = devicePrincipal("activity_etag", 1);
    await usage.recordUsage(
      principal,
      usageUpload([usageHour("2026-08-10T10:00:00Z", 1)]),
      now.toISOString(),
    );

    const statements: string[] = [];
    const app = appFor("account_activity_etag", now, recordingD1(statements));
    const path =
      "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-10&to=2026-08-10";
    const first = await app.request(path);
    expect(first.status).toBe(200);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(statements.join("\n")).not.toMatch(/quota_snapshots/);
    expect(statements.join("\n")).not.toMatch(/last_seen_at/);

    await env.DB.prepare(
      `INSERT INTO quota_snapshots (
         device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
       ) VALUES ('device_activity_etag', 'codex', 'fingerprint_activity_etag', ?1, ?2, ?1)`,
    )
      .bind(now.toISOString(), JSON.stringify(quotaSnapshotJson()))
      .run();
    const afterSnapshot = await app.request(path, { headers: { "If-None-Match": etag ?? "" } });
    expect(afterSnapshot.status).toBe(304);
    expect(afterSnapshot.headers.get("ETag")).toBe(etag);

    await usage.recordUsage(
      principal,
      usageUpload([usageHour("2026-08-10T11:00:00Z", 2)]),
      now.toISOString(),
    );
    const afterUsage = await app.request(path, { headers: { "If-None-Match": etag ?? "" } });
    expect(afterUsage.status).toBe(200);
    expect(afterUsage.headers.get("ETag")).not.toBe(etag);
  });

  it("turns the activity ETag over when daily retention cuts the asked range", async () => {
    await seedDevice("activity_retention");
    const from = utcDaysBefore(800);
    const to = utcDaysBefore(790);
    const path = `https://quota.gotry.io/api/v6/account/usage/activity?from=${from}&to=${to}`;
    const first = await appFor("account_activity_retention").request(path);
    expect(first.status).toBe(200);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);

    const nextDay = new Date(now.getTime() + 86_400_000);
    const later = await appFor("account_activity_retention", nextDay).request(path, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(later.status).toBe(200);
    expect(later.headers.get("ETag")).not.toBe(etag);
  });

  it("turns the activity ETag over when the Usage fold version changes", async () => {
    await seedDevice("activity_fold");
    const path =
      "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-10&to=2026-08-10";
    const first = await appFor("account_activity_fold").request(path);
    expect(first.status).toBe(200);
    const etag = first.headers.get("ETag");
    const bumped = await appFor("account_activity_fold", now, env.DB, {
      usageFoldVersion: 2,
    }).request(path, { headers: { "If-None-Match": etag ?? "" } });
    expect(bumped.status).toBe(200);
    expect(bumped.headers.get("ETag")).not.toBe(etag);
  });

  it("bounds a high-cardinality period without losing what it totals", async () => {
    const models = JSON.stringify(Array.from({ length: 1_001 }, (_, index) => index));
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_cardinality', ?1, ?1)",
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_unreadable', ?1, ?1)",
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
      "account_identities",
      "account_usage_folds",
      "accounts",
      "devices",
      "login_grants",
      "quota_snapshots",
      "rate_limit_counters",
      "sessions",
      "usage_daily",
      "usage_hour_scans",
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
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_retention', ?1, ?1)",
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

  it("reads all time as the window it names rather than as every retained day", async () => {
    const oldest = utcDaysBefore(729);
    const older = utcDaysBefore(730);
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_window', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_window', 'account_window', 'installation_window', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_window",
        date: oldest,
      }),
      usageDailyInsert("codex", "openai_direct", "claude-opus-5", {
        deviceID: "device_window",
        date: older,
      }),
    ]);

    const response = await appFor("account_window").request(
      "https://quota.gotry.io/api/v6/account/summary",
    );
    expect(response.status).toBe(200);
    const summary = (await response.json()) as {
      usage: {
        all: {
          totals: { messages: number };
          agents: Array<{ providers: Array<{ models: Array<{ model: string }> }> }>;
        };
      };
    };
    // The day one past the window is retained and not read; `all` is 730 days, not everything.
    expect(summary.usage.all.totals.messages).toBe(1);
    expect(
      summary.usage.all.agents.flatMap((agent) =>
        agent.providers.flatMap((provider) => provider.models.map((model) => model.model)),
      ),
    ).toEqual(["gpt-5.6-sol"]);
  });

  it("sweeps Usage older than retention, a bounded batch at a time", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_sweep', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_sweep', 'account_sweep', 'installation_sweep', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    // One hour and one day on each side of every bound, plus enough beyond it to prove the
    // batch stops rather than running the table down in a single pass.
    const expiredHours = Array.from({ length: 120 }, (_, index) =>
      new Date(Date.parse("2024-01-01T00:00:00Z") + index * 3_600_000).toISOString().slice(0, 19),
    ).map((instant) => `${instant}Z`);
    await env.DB.batch([
      ...[...expiredHours, "2026-08-09T00:00:00Z"].flatMap((bucket) => storedHour(bucket)),
      ...["2023-01-01", "2023-01-02", "2026-08-09"].map((date) => storedDay(date)),
    ]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));

    expect(await sweptHours()).toHaveLength(expiredHours.length - 100 + 1);
    expect(await sweptScans()).toHaveLength(expiredHours.length - 100 + 1);
    expect(await sweptDays()).toEqual(["2026-08-09"]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));
    expect(await sweptHours()).toEqual(["2026-08-09T00:00:00Z"]);
    expect(await sweptScans()).toEqual(["2026-08-09T00:00:00Z"]);
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
      `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES ('account_identity', 'Quota Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const webSessions = new SignedInWebSessionStub("account_identity", now);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: service,
      webSessions,
      hasher,
      now: () => now,
    });

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
    const started = await app.request(authorize);
    expect(started.status).toBe(302);

    const complete = await app.request(`https://quota.gotry.io${signInReturnTo(started)}`);
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
    expect(tokens.account_id).toBe("account_identity");
    // Signing in names the Account, so QuotaBar says whose account it reached before it has
    // read one.
    expect(tokens.display_label).toBe("Quota Tester");
    expect(
      await env.DB.prepare("SELECT display_label FROM accounts WHERE id = ?1")
        .bind(tokens.account_id)
        .first("display_label"),
    ).toBe(tokens.display_label);
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
    expect(await state.authorizeSession(oldAccessHash, now.toISOString(), true)).toMatchObject({
      device_id: tokens.device_id,
      device_generation: 1,
      client_kind: "quotabar",
      scopes: ["account:read", "device:write"],
    });
    // The one token reads the Account it was issued for, and writes only its own Device.
    const lastSeen = () =>
      env.DB.prepare("SELECT last_seen_at FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("last_seen_at");
    const before = "2026-08-09T00:00:00.000Z";
    await env.DB.prepare("UPDATE devices SET last_seen_at = ?2 WHERE id = ?1")
      .bind(tokens.device_id, before)
      .run();
    const summary = await app.request("https://quota.gotry.io/api/v6/account/summary", {
      headers: { Authorization: `Bearer ${tokens.session.access_token}` },
    });
    expect(summary.status).toBe(200);
    // Reading must not move `last_seen_at`. The validator for this very read is derived from it,
    // so a read that touched it could never be answered 304 — which is the whole point of a
    // client polling this route.
    expect(await lastSeen()).toBe(before);
    const validator = summary.headers.get("ETag") ?? "";
    expect(validator).not.toBe("");
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers: {
            Authorization: `Bearer ${tokens.session.access_token}`,
            "If-None-Match": validator,
          },
        })
      ).status,
    ).toBe(304);
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
    // A device route does move it: that is what "last seen" witnesses.
    expect(await lastSeen()).toBe(now.toISOString());
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
    expect(await state.authorizeSession(oldAccessHash, now.toISOString(), true)).toBeNull();

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
    expect(await state.authorizeSession(oldAccessHash, deletedAt, true)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 1)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 2)).toMatchObject({ generation: 2 });

    const unsafeStart = await app.request(authorize);
    expect(unsafeStart.status).toBe(302);
    await env.DB.prepare(
      "UPDATE login_grants SET redirect_uri = 'https://attacker.invalid/callback' WHERE completed_at IS NULL",
    ).run();
    const unsafeRedirect = await app.request(
      `https://quota.gotry.io${signInReturnTo(unsafeStart)}`,
    );
    expect(unsafeRedirect.status).toBe(400);
    expect(unsafeRedirect.headers.get("location")).toBeNull();
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM login_grants WHERE completed_at IS NOT NULL AND redirect_uri = 'https://attacker.invalid/callback'",
      ).first("count"),
    ).toBe(0);

    const deletedStart = await app.request(authorize);
    expect(deletedStart.status).toBe(302);
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(tokens.account_id).run();
    expect(
      (await app.request(`https://quota.gotry.io${signInReturnTo(deletedStart)}`)).status,
    ).toBe(401);
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

  it("accepts a same-instant restatement that only changes available to a failure", async () => {
    const { app } = await quotabarHarness("account_same_instant", { now });
    const tokens = await loginQuotabar(app);
    const headers = {
      Authorization: `Bearer ${tokens.session.access_token}`,
      "Content-Type": "application/json",
    };
    const observedAt = now.toISOString();
    const earlier = new Date(now.getTime() - 60_000).toISOString();
    const later = new Date(now.getTime() + 60_000).toISOString();
    const snapshot = (status: "available" | "auth_required", at: string, usedPercent: number) => ({
      provider: "codex" as const,
      account: { fingerprint: "fingerprint_same_instant", fingerprint_scope: "global" as const },
      windows: [{ id: "weekly", title: "Weekly", used_percent: usedPercent }],
      status,
      observed_at: at,
    });
    const put = async (status: "available" | "auth_required", at: string, usedPercent: number) => {
      const response = await app.request("https://quota.gotry.io/api/v6/device/snapshots", {
        method: "PUT",
        headers,
        body: JSON.stringify({
          protocol_version: 6,
          generation: tokens.device_generation,
          snapshots: [snapshot(status, at, usedPercent)],
        }),
      });
      expect(response.status).toBe(200);
      return (await response.json()) as { accepted: string[]; ignored: string[] };
    };
    const summarySnapshot = async () => {
      const response = await app.request("https://quota.gotry.io/api/v6/account/summary", {
        headers: { Authorization: `Bearer ${tokens.session.access_token}` },
      });
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        subscriptions: Array<{
          snapshot: {
            status: string;
            observed_at: string;
            windows: Array<{ used_percent: number }>;
          };
        }>;
      };
      return body.subscriptions[0]?.snapshot;
    };

    expect(await put("available", observedAt, 25)).toMatchObject({
      accepted: ["codex"],
      ignored: [],
    });
    expect(await put("auth_required", observedAt, 25)).toMatchObject({
      accepted: ["codex"],
      ignored: [],
    });
    expect(await summarySnapshot()).toMatchObject({
      status: "auth_required",
      observed_at: observedAt,
      windows: [{ used_percent: 25 }],
    });

    expect(await put("available", observedAt, 40)).toMatchObject({
      accepted: [],
      ignored: ["codex"],
    });
    expect(await summarySnapshot()).toMatchObject({
      status: "auth_required",
      observed_at: observedAt,
      windows: [{ used_percent: 25 }],
    });

    expect(await put("available", earlier, 10)).toMatchObject({
      accepted: [],
      ignored: ["codex"],
    });
    expect(await summarySnapshot()).toMatchObject({
      status: "auth_required",
      observed_at: observedAt,
      windows: [{ used_percent: 25 }],
    });

    expect(await put("available", later, 40)).toMatchObject({
      accepted: ["codex"],
      ignored: [],
    });
    expect(await summarySnapshot()).toMatchObject({
      status: "available",
      observed_at: later,
      windows: [{ used_percent: 40 }],
    });
  });

  it("a refresh whose answer was lost can be repeated with the token it replaced", async () => {
    const clock = { now };
    const { app } = await quotabarHarness("account_rotation_grace", clock);
    const login = await loginQuotabar(app);
    const r0 = login.session.refresh_token;

    const first = await refreshQuotabar(app, r0);
    expect(first.status).toBe(200);
    const rotated = (await first.json()) as SessionRefreshResponse;
    const a1 = rotated.session.access_token;
    const r1 = rotated.session.refresh_token;
    expect(a1).not.toBe(login.session.access_token);
    expect(r1).not.toBe(r0);

    const replay = await refreshQuotabar(app, r0);
    expect(replay.status).toBe(200);
    const recovered = (await replay.json()) as SessionRefreshResponse;
    const a2 = recovered.session.access_token;
    const r2 = recovered.session.refresh_token;
    expect(a2).not.toBe(a1);
    expect(r2).not.toBe(r1);

    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers: { Authorization: `Bearer ${a1}` },
        })
      ).status,
    ).toBe(401);

    clock.now = new Date(now.getTime() + 1_000);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers: { Authorization: `Bearer ${a2}` },
        })
      ).status,
    ).toBe(200);

    const spent = await refreshQuotabar(app, r0);
    expect(spent.status).toBe(400);
    expect(await spent.json()).toMatchObject({ error: { code: "invalid_grant" } });
    const predecessor = await refreshQuotabar(app, r1);
    expect(predecessor.status).toBe(400);
    expect(await predecessor.json()).toMatchObject({ error: { code: "invalid_grant" } });
  });

  it("the replaced token can end the family while its successor is unspent", async () => {
    const { app } = await quotabarHarness("account_rotation_revoke", { now });
    const login = await loginQuotabar(app);
    const first = await refreshQuotabar(app, login.session.refresh_token);
    expect(first.status).toBe(200);
    const rotated = (await first.json()) as SessionRefreshResponse;

    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${login.session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v6/account/summary", {
          headers: { Authorization: `Bearer ${rotated.session.access_token}` },
        })
      ).status,
    ).toBe(401);
    expect(
      await env.DB.prepare("SELECT signed_out_at FROM devices WHERE id = ?1")
        .bind(login.device_id)
        .first("signed_out_at"),
    ).toBe(now.toISOString());
  });

  it("serves a stored Usage fold when a snapshot upload moves the ETag", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_fold_etag', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at, last_seen_at
         ) VALUES ('device_fold_etag', 'account_fold_etag', 'installation_fold_etag', 1, ?1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_fold_etag",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_fold_etag");
    const summaryPath = "https://quota.gotry.io/api/v6/account/summary";
    const first = await app.request(summaryPath);
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as { usage: unknown };
    const stored = await usageFolds("account_fold_etag");
    expect(stored).toHaveLength(1);

    await env.DB.prepare(
      `INSERT INTO quota_snapshots (
         device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
       ) VALUES ('device_fold_etag', 'codex', 'fingerprint_fold_etag', ?1, ?2, ?1)`,
    )
      .bind(now.toISOString(), JSON.stringify(quotaSnapshotJson()))
      .run();
    const afterSnapshot = await app.request(summaryPath, {
      headers: { "If-None-Match": first.headers.get("ETag") ?? "" },
    });
    expect(afterSnapshot.status).toBe(200);
    expect(afterSnapshot.headers.get("ETag")).not.toBe(first.headers.get("ETag"));
    const afterBody = (await afterSnapshot.json()) as { usage: unknown };
    expect(afterBody.usage).toEqual(firstBody.usage);
    const unchanged = await usageFolds("account_fold_etag");
    expect(unchanged).toEqual(stored);
  });

  it("stores a new Usage fold when an accepted upload changes what the summary folds", async () => {
    await seedDevice("fold_usage");
    const usage = new D1UsageState(env.DB);
    const principal = devicePrincipal("fold_usage", 1);
    await usage.recordUsage(
      principal,
      usageUpload([usageHour("2026-08-10T10:00:00Z", 1)]),
      now.toISOString(),
    );
    const app = appFor("account_fold_usage");
    const summaryPath = "https://quota.gotry.io/api/v6/account/summary";
    const first = await app.request(summaryPath);
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as {
      usage: { all: { totals: { messages: number } } };
    };
    expect(firstBody.usage.all.totals.messages).toBe(1);
    const firstFold = await usageFolds("account_fold_usage");
    expect(firstFold).toHaveLength(1);

    await usage.recordUsage(
      principal,
      usageUpload([usageHour("2026-08-10T11:00:00Z", 2)]),
      now.toISOString(),
    );
    const second = await app.request(summaryPath);
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as {
      usage: { all: { totals: { messages: number } } };
    };
    expect(secondBody.usage.all.totals.messages).toBe(2);
    const folds = await usageFolds("account_fold_usage");
    expect(folds).toHaveLength(2);
    expect(folds.map((row) => row.fold_key)).toContain(firstFold[0]?.fold_key);
    expect(folds.some((row) => row.fold_key !== firstFold[0]?.fold_key)).toBe(true);
  });

  it("stores a different Usage fold for a different timezone", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_fold_tz', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_fold_tz', 'account_fold_tz', 'installation_fold_tz', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_fold_tz",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_fold_tz");
    expect((await app.request("https://quota.gotry.io/api/v6/account/summary")).status).toBe(200);
    expect(
      (await app.request("https://quota.gotry.io/api/v6/account/summary?tz=Asia/Singapore")).status,
    ).toBe(200);
    const folds = await usageFolds("account_fold_tz");
    expect(folds).toHaveLength(2);
    expect(folds[0]?.fold_key).not.toBe(folds[1]?.fold_key);
  });

  it("refolds a stored Usage fold the current contract cannot read", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_fold_stale', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_fold_stale', 'account_fold_stale', 'installation_fold_stale', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
        deviceID: "device_fold_stale",
        date: "2026-08-10",
      }),
    ]);
    const app = appFor("account_fold_stale");
    const summaryPath = "https://quota.gotry.io/api/v6/account/summary";
    const first = await app.request(summaryPath);
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as { usage: unknown };
    const stored = await usageFolds("account_fold_stale");
    expect(stored).toHaveLength(1);

    await env.DB.prepare(
      `UPDATE account_usage_folds SET usage_json = '{"stale":true}'
       WHERE account_id = ?1 AND fold_key = ?2`,
    )
      .bind("account_fold_stale", stored[0]?.fold_key)
      .run();

    const second = await app.request(summaryPath);
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as { usage: unknown };
    expect(secondBody.usage).toEqual(firstBody.usage);
    expect(
      await env.DB.prepare(
        "SELECT usage_json FROM account_usage_folds WHERE account_id = ?1 AND fold_key = ?2",
      )
        .bind("account_fold_stale", stored[0]?.fold_key)
        .first("usage_json"),
    ).not.toBe('{"stale":true}');
  });

  it("sweeps a Usage fold older than retention and keeps a newer one", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES ('account_fold_sweep', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO account_usage_folds (account_id, fold_key, usage_json, created_at)
         VALUES ('account_fold_sweep', 'old', '{}', '2026-08-07T00:00:00.000Z')`,
      ),
      env.DB.prepare(
        `INSERT INTO account_usage_folds (account_id, fold_key, usage_json, created_at)
         VALUES ('account_fold_sweep', 'new', '{}', '2026-08-09T00:00:00.000Z')`,
      ),
    ]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));

    expect(await usageFolds("account_fold_sweep")).toEqual([
      { fold_key: "new", created_at: "2026-08-09T00:00:00.000Z" },
    ]);
  });
});

async function seedDevice(name: string, generation = 1): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO accounts (id, created_at, updated_at)
       VALUES ('account_${name}', ?1, ?1)`,
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

function utcDaysBefore(days: number): string {
  return new Date(now.getTime() - days * 86_400_000).toISOString().slice(0, 10);
}

/** One stored hour of the retention fixture, with the scan version that owns it. */
function storedHour(bucket: string): D1PreparedStatement[] {
  return [
    env.DB.prepare(
      `INSERT INTO usage_hourly (
           device_id, agent, bucket_start_utc, scan_version, partial,
           billing_channel, channel_source, model, context_bucket,
           service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
           cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
           output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
           source_cost_microusd, source_cost_covered_requests
         ) VALUES (
           'device_sweep', 'codex', ?1, 1, 0,
           'openai_direct', 'agent_default', 'gpt-5.6-sol', 'le_128k',
           'unknown', 'unknown', 'unknown', 10, 0,
           0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
         )`,
    ).bind(bucket),
    env.DB.prepare(
      `INSERT INTO usage_hour_scans (device_id, agent, bucket_start_utc, scan_version)
       VALUES ('device_sweep', 'codex', ?1, 1)`,
    ).bind(bucket),
  ];
}

function storedDay(date: string): D1PreparedStatement {
  return usageDailyInsert("codex", "openai_direct", "gpt-5.6-sol", {
    deviceID: "device_sweep",
    date,
  });
}

function sweptHours(): Promise<string[]> {
  return sweptColumn("usage_hourly", "bucket_start_utc");
}

function sweptScans(): Promise<string[]> {
  return sweptColumn("usage_hour_scans", "bucket_start_utc");
}

function sweptDays(): Promise<string[]> {
  return sweptColumn("usage_daily", "utc_date");
}

async function sweptColumn(table: string, column: string): Promise<string[]> {
  const rows = await env.DB.prepare(
    `SELECT ${column} AS value FROM ${table} WHERE device_id = 'device_sweep' ORDER BY value`,
  ).all<{ value: string }>();
  return rows.results.map((row) => row.value);
}

/** One hour of the same fact `usageDailyInsert` rolls into a day, on the same device. */
function usageHourInsert(
  agent: string,
  channel: string,
  model: string,
  bucket: string,
): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_hourly (
         device_id, agent, bucket_start_utc, scan_version, partial,
         billing_channel, channel_source, model, context_bucket,
         service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
         output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
         source_cost_microusd, source_cost_covered_requests
       ) VALUES (
         'device_history', ?1, ?4, 1, 0,
         ?2, 'agent_default', ?3, 'le_128k',
         'unknown', 'unknown', 'unknown', 10, 0,
         0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
       )`,
  ).bind(agent, channel, model, bucket);
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
function appFor(
  accountId: string,
  readAt: Date = now,
  database: D1Database = env.DB,
  extras: { usageFoldVersion?: number } = {},
) {
  const state = new D1AccountState(database);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(database),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, readAt),
    hasher,
    now: () => readAt,
    ...extras,
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

async function quotabarHarness(accountId: string, clock: { now: Date }) {
  await env.DB.prepare(
    `INSERT INTO accounts (id, display_label, created_at, updated_at)
     VALUES (?1, 'Quota Tester', ?2, ?2)`,
  )
    .bind(accountId, clock.now.toISOString())
    .run();
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const app = createRelayApp({
    state,
    usageState: new D1UsageState(env.DB),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, clock.now),
    hasher,
    now: () => clock.now,
  });
  return { app, state, hasher };
}

async function loginQuotabar(app: ReturnType<typeof createRelayApp>): Promise<OAuthTokenResponse> {
  const verifier = "a".repeat(43);
  const challengeBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
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
  const started = await app.request(authorize);
  expect(started.status).toBe(302);
  const complete = await app.request(`https://quota.gotry.io${signInReturnTo(started)}`);
  expect(complete.status).toBe(302);
  const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
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
  return (await exchanged.json()) as OAuthTokenResponse;
}

function refreshQuotabar(app: ReturnType<typeof createRelayApp>, refreshToken: string) {
  return app.request("https://quota.gotry.io/oauth/v2/token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocol_version: 2,
      grant_type: "refresh_token",
      client_id: "quotabar",
      refresh_token: refreshToken,
    }),
  });
}

async function usageFolds(accountId: string) {
  const rows = await env.DB.prepare(
    `SELECT fold_key, created_at FROM account_usage_folds
     WHERE account_id = ?1 ORDER BY created_at, fold_key`,
  )
    .bind(accountId)
    .all<{ fold_key: string; created_at: string }>();
  return rows.results;
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
