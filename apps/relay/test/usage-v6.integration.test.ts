import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { MAXIMUM_USAGE_ROWS_PER_HOUR } from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal, UsageUpload } from "@gotry-io/relay-core";
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

const now = new Date("2026-08-10T12:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const accountId = "account_v6";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
  // Migrations are applied once per worker, so each case clears what the last one wrote.
  await env.DB.batch(
    ["usage_daily", "usage_hourly", "quota_snapshots", "devices", "accounts"].map((table) =>
      env.DB.prepare(`DELETE FROM ${table}`),
    ),
  );
  await env.DB.prepare(
    `INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)`,
  )
    .bind(accountId, now.toISOString())
    .run();
});

describe("managed data v6 end to end", () => {
  it("keeps only the newest scan of an hour and ignores one already overtaken", async () => {
    await addDevice("alpha");
    const usage = new D1UsageState(env.DB);
    const hour = "2026-08-10T09:00:00Z";

    expect(
      await usage.recordUsage(
        principal("alpha"),
        upload([hourOf(hour, 4, ["gpt-5.6-sol", "gpt-5.6-luna"])]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "written", accepted: [hour], ignored: [] });

    expect(
      await usage.recordUsage(
        principal("alpha"),
        upload([hourOf(hour, 9, ["claude-opus-5"])]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "written", accepted: [hour], ignored: [] });

    expect(await storedModels("device_alpha")).toEqual(["claude-opus-5"]);

    // The scan that already stood, re-sent, is ignored rather than merged back in.
    expect(
      await usage.recordUsage(
        principal("alpha"),
        upload([hourOf(hour, 4, ["gpt-5.6-sol", "gpt-5.6-luna"])]),
        now.toISOString(),
      ),
    ).toEqual({ outcome: "written", accepted: [], ignored: [hour] });
    expect(await storedModels("device_alpha")).toEqual(["claude-opus-5"]);
  });

  it("leaves the daily rollup equal to a direct aggregation of the hours", async () => {
    await addDevice("alpha");
    await addDevice("beta");
    const usage = new D1UsageState(env.DB);
    await usage.recordUsage(
      principal("alpha"),
      upload([
        hourOf("2026-08-09T22:00:00Z", 1, ["gpt-5.6-sol"]),
        hourOf("2026-08-09T23:00:00Z", 1, ["gpt-5.6-sol"], true),
        hourOf("2026-08-10T00:00:00Z", 1, ["gpt-5.6-sol", "claude-opus-5"]),
      ]),
      now.toISOString(),
    );
    await usage.recordUsage(
      principal("beta"),
      upload([hourOf("2026-08-10T00:00:00Z", 1, ["gpt-5.6-sol"])]),
      now.toISOString(),
    );
    // Replacing one hour rewrites the dates it touches and leaves the rest alone.
    await usage.recordUsage(
      principal("alpha"),
      upload([hourOf("2026-08-09T23:00:00Z", 2, ["claude-opus-5"])]),
      now.toISOString(),
    );

    expect(await dailyDisagreements()).toEqual([]);
  });

  it("answers a summary from the daily rollup alone", async () => {
    await addDevice("alpha");
    const usage = new D1UsageState(env.DB);
    await usage.recordUsage(
      principal("alpha"),
      upload([
        hourOf("2026-08-10T09:00:00Z", 1, ["gpt-5.6-sol"]),
        hourOf("2026-08-09T09:00:00Z", 1, ["claude-opus-5"], true),
      ]),
      now.toISOString(),
    );

    const app = signedInApp();
    const before = await (
      await app.request("https://quota.gotry.io/api/v6/account/summary")
    ).text();
    expect(JSON.parse(before)).toMatchObject({
      usage: {
        all: { totals: { messages: 2 }, partial: true },
        today: { totals: { messages: 1 } },
      },
    });

    // With every hour deleted the summary is unchanged, which is the only way to say that the
    // read never reaches for one.
    await env.DB.prepare("DELETE FROM usage_hourly").run();
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_hourly").first("count")).toBe(
      0,
    );
    const after = await (await app.request("https://quota.gotry.io/api/v6/account/summary")).text();
    expect(after).toBe(before);

    const activity = await (
      await app.request(
        "https://quota.gotry.io/api/v6/account/usage/activity?from=2026-08-01&to=2026-08-10",
      )
    ).json();
    expect(activity).toMatchObject({
      days: [
        { date: "2026-08-09", partial: true, totals: { messages: 1 } },
        { date: "2026-08-10", partial: false, totals: { messages: 1 } },
      ],
    });
  });

  it("resolves one subscription for the three Macs that report it", async () => {
    for (const name of ["alpha", "beta", "gamma"]) {
      await addDevice(name);
    }
    const state = new D1AccountState(env.DB);
    for (const [index, name] of ["alpha", "beta", "gamma"].entries()) {
      const observedAt = new Date(now.getTime() - index * 60_000).toISOString();
      expect(
        await state.recordSnapshot(
          principal(name),
          {
            protocol_version: 6,
            generation: 1,
            snapshots: [
              {
                provider: "codex",
                account: { fingerprint: "one_account", fingerprint_scope: "global" },
                windows: [{ id: "weekly", title: "Weekly", used_percent: 25 }],
                status: "available",
                observed_at: observedAt,
              },
            ],
          },
          now.toISOString(),
        ),
      ).toEqual({ outcome: "written", accepted: ["codex"], ignored: [] });
    }

    const summary = (await (
      await signedInApp().request("https://quota.gotry.io/api/v6/account/summary")
    ).json()) as {
      subscriptions: Array<{
        key: string;
        provider: string;
        snapshot: { observed_at: string };
        sources: Array<{ device_id: string }>;
      }>;
      devices: Array<{ id: string; last_observed_at: string | null }>;
    };

    expect(summary.subscriptions).toHaveLength(1);
    expect(summary.subscriptions[0]?.key).toBe("codex|one_account|global|");
    // The newest reading speaks for the subscription; the other two stay attached to it.
    expect(summary.subscriptions[0]?.snapshot.observed_at).toBe(now.toISOString());
    expect(summary.subscriptions[0]?.sources.map((source) => source.device_id)).toEqual([
      "device_alpha",
      "device_beta",
      "device_gamma",
    ]);
    expect(summary.devices.every((device) => device.last_observed_at !== null)).toBe(true);
  });

  it("refuses a stale generation, an oversized hour, and a retired contract", async () => {
    await addDevice("alpha");
    const usage = new D1UsageState(env.DB);

    expect(
      await usage.recordUsage(
        { ...principal("alpha"), generation: 2 },
        { ...upload([hourOf("2026-08-10T09:00:00Z", 1)]), generation: 2 },
        now.toISOString(),
      ),
    ).toEqual({ outcome: "stale_device" });

    const app = signedInApp();
    const headers = {
      Authorization: `Bearer ${await bearerFor("alpha")}`,
      "Content-Type": "application/json",
    };
    const oversizedHour = (count: number) =>
      upload([
        hourOf(
          "2026-08-10T09:00:00Z",
          1,
          Array.from({ length: count }, (_, index) => `model-${index}`),
        ),
      ]);
    const accepted = await app.request("https://quota.gotry.io/api/v6/device/usage", {
      method: "PUT",
      headers,
      body: JSON.stringify(oversizedHour(MAXIMUM_USAGE_ROWS_PER_HOUR)),
    });
    expect(accepted.status).toBe(200);
    expect(await accepted.json()).toMatchObject({
      accepted: ["2026-08-10T09:00:00Z"],
      ignored: [],
    });
    // A scan that found more distinct rows in one hour folds the overflow into `other` before
    // uploading. Relay does not do that folding for it.
    const oversized = await app.request("https://quota.gotry.io/api/v6/device/usage", {
      method: "PUT",
      headers,
      body: JSON.stringify(oversizedHour(MAXIMUM_USAGE_ROWS_PER_HOUR + 1)),
    });
    expect(oversized.status).toBe(400);
    expect(await oversized.json()).toMatchObject({ error: { code: "invalid_request" } });

    const staleGeneration = await app.request("https://quota.gotry.io/api/v6/device/usage", {
      method: "PUT",
      headers,
      body: JSON.stringify({ ...upload([hourOf("2026-08-10T09:00:00Z", 5)]), generation: 2 }),
    });
    expect(staleGeneration.status).toBe(409);
    expect(await staleGeneration.json()).toMatchObject({ error: { code: "stale_generation" } });

    const retired = await app.request("https://quota.gotry.io/api/v5/account/summary");
    expect(retired.status).toBe(404);
    expect(await retired.json()).toMatchObject({ error: { code: "client_upgrade_required" } });
  });
});

async function addDevice(name: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO devices (
       id, account_id, installation_id_hash, generation, created_at, last_login_at
     ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
  )
    .bind(`device_${name}`, accountId, `installation_${name}`, now.toISOString())
    .run();
}

function principal(name: string): DeviceWriterPrincipal {
  return {
    session_id: `session_${name}`,
    family_id: `family_${name}`,
    account_id: accountId,
    device_id: `device_${name}`,
    device_generation: 1,
    client_kind: "quotabar",
    scopes: ["account:read", "device:write"],
    authenticated_at: now.toISOString(),
  };
}

function row(model: string) {
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

function hourOf(
  bucket: string,
  scanVersion: number,
  models: readonly string[] = ["gpt-5.6-sol"],
  partial = false,
) {
  return {
    bucket_start_utc: bucket,
    scan_version: scanVersion,
    partial,
    rows: models.map(row),
  };
}

function upload(hours: ReturnType<typeof hourOf>[]): UsageUpload {
  return { protocol_version: 6, generation: 1, agent: "codex", hours };
}

function signedInApp() {
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

/** A live session for one seeded device, and the bearer token that reaches it. */
async function bearerFor(name: string): Promise<string> {
  const token = `qb_${name.padEnd(43, "x").slice(0, 43)}`;
  await env.DB.prepare(
    `INSERT INTO sessions (
       id, family_id, account_id, device_id, device_generation, client_kind,
       access_token_hash, refresh_token_hash, scopes_json,
       authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
     ) VALUES (?1, ?1, ?2, ?3, 1, 'quotabar', ?4, ?5, ?6, ?8, ?7, ?7, ?8, ?8)`,
  )
    .bind(
      `session_${name}`,
      accountId,
      `device_${name}`,
      await new SecretHasher(secret).hash("quotabar-access", token),
      `refresh_${name}`,
      JSON.stringify(["account:read", "device:write"]),
      new Date(now.getTime() + 3_600_000).toISOString(),
      now.toISOString(),
    )
    .run();
  return token;
}

async function storedModels(deviceId: string): Promise<string[]> {
  const rows = await env.DB.prepare(
    "SELECT model FROM usage_hourly WHERE device_id = ?1 ORDER BY model",
  )
    .bind(deviceId)
    .all<{ model: string }>();
  return rows.results.map((item) => item.model);
}

/**
 * Every daily row that disagrees with the hours behind it, in either direction.
 *
 * A managed read never opens `usage_hourly`, so the upload that maintains both tables is the
 * only thing keeping them in step. This is the assertion that says so.
 */
async function dailyDisagreements(): Promise<unknown[]> {
  const expected = await env.DB.prepare(
    `SELECT device_id, substr(bucket_start_utc, 1, 10) AS utc_date, agent, billing_channel,
            channel_source, model, context_bucket, service_tier, speed, inference_geo,
            SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
            SUM(requests) AS requests, SUM(partial) AS partial_hours
     FROM usage_hourly
     GROUP BY device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel,
              channel_source, model, context_bucket, service_tier, speed, inference_geo
     ORDER BY device_id, utc_date, agent, model`,
  ).all<Record<string, unknown>>();
  const actual = await env.DB.prepare(
    `SELECT device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
            service_tier, speed, inference_geo, input_tokens, output_tokens, requests,
            partial_hours
     FROM usage_daily
     ORDER BY device_id, utc_date, agent, model`,
  ).all<Record<string, unknown>>();
  const rolled = expected.results.map((item) => JSON.stringify(item));
  const stored = actual.results.map((item) => JSON.stringify(item));
  expect(rolled.length).toBeGreaterThan(0);
  return [
    ...rolled.filter((item) => !stored.includes(item)),
    ...stored.filter((item) => !rolled.includes(item)),
  ];
}
