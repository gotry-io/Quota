import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { describe, expect, inject, it } from "vitest";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const ZERO_USAGE_MIGRATION = "0011_drop_zero_usage_facts.sql";

async function seedZeroUsageFacts(): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO accounts(id, identity_subject, created_at, updated_at)
     VALUES ('account-1', 'subject-hash-1', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')`,
  ).run();
  await env.DB.prepare(
    `INSERT INTO devices(id, account_id, installation_id_hash, created_at, last_login_at)
     VALUES ('device-1', 'account-1', 'installation-hash-1', '2026-08-01T00:00:00Z',
             '2026-08-01T00:00:00Z')`,
  ).run();
  // Only the columns a case varies are bound; the rest describe one fixed hour.
  const insert = env.DB.prepare(
    `INSERT INTO usage_hourly(
       device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
       agent, billing_channel, channel_source, model, context_bucket,
       service_tier, speed, inference_geo,
       input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
       cache_write_inferred_tokens, output_tokens, reasoning_tokens, requests,
       web_search_requests, web_fetch_requests, source_cost_microusd,
       source_cost_covered_requests
     ) VALUES (
       'device-1', '2026-08-03T12:00:00Z', '2026-08-03', 12, 'UTC',
       'claude_code', ?1, 'agent_default', ?2, 'le_128k',
       'unknown', 'unknown', 'unknown',
       ?3, 0, 0, 0, 0, ?4, 0, 2, ?5, 0, ?6, 0
     )`,
  );
  await env.DB.batch([
    // The legacy fact this migration exists to remove.
    insert.bind("anthropic_direct", "synthetic", 0, 0, 0, null),
    insert.bind("anthropic_direct", "claude-opus-5", 1_000, 500, 0, null),
    // A zero-token fact is still real usage when it carries a billable tool
    // request or a source-reported cost.
    insert.bind("unknown", "claude-opus-5", 0, 0, 3, null),
    insert.bind("xai_direct", "grok-4.6", 0, 0, 0, "1250"),
  ]);
}

describe("0011 zero-usage fact cleanup", () => {
  it("removes only facts with no tokens, tool requests, or source cost", async () => {
    const migrations = inject("TEST_MIGRATIONS");
    const cleanupIndex = migrations.findIndex((migration) =>
      migration.name.endsWith(ZERO_USAGE_MIGRATION),
    );
    expect(cleanupIndex).toBeGreaterThan(0);

    await applyD1Migrations(env.DB, migrations.slice(0, cleanupIndex));
    await seedZeroUsageFacts();
    expect(
      await env.DB.prepare("SELECT count(*) AS total FROM usage_hourly").first<{ total: number }>(),
    ).toMatchObject({ total: 4 });

    await applyD1Migrations(env.DB, migrations.slice(cleanupIndex));

    const remaining = await env.DB.prepare(
      "SELECT model, billing_channel FROM usage_hourly ORDER BY model, billing_channel",
    ).all<{ model: string; billing_channel: string }>();
    expect(remaining.results).toEqual([
      { model: "claude-opus-5", billing_channel: "anthropic_direct" },
      { model: "claude-opus-5", billing_channel: "unknown" },
      { model: "grok-4.6", billing_channel: "xai_direct" },
    ]);
  });
});
