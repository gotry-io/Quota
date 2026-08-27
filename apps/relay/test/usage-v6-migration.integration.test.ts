import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { describe, expect, inject, it } from "vitest";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const HOUR_VERSION_MIGRATION = "0018_hour_versioned_usage_and_daily_rollups.sql";

/**
 * One hour of retained facts as the previous shape kept them: split by the local date and hour
 * a device projected them through, which is why the same measurement can be here twice.
 */
async function seedRetainedFacts(): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO accounts(id, identity_subject, created_at, updated_at)
     VALUES ('account-1', 'subject-hash-1', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')`,
  ).run();
  await env.DB.prepare(
    `INSERT INTO devices(id, account_id, installation_id_hash, created_at, last_login_at)
     VALUES ('device-1', 'account-1', 'installation-hash-1', '2026-08-01T00:00:00Z',
             '2026-08-01T00:00:00Z')`,
  ).run();
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
       'device-1', ?1, ?2, ?3, ?4,
       'codex', 'openai_direct', 'agent_default', ?5, 'le_128k',
       'unknown', 'unknown', 'unknown',
       ?6, 0, 0, 0, 0, ?7, 0, ?8, 0, 0, ?9, ?10
     )`,
  );
  await env.DB.batch([
    // The same hour and the same measurement, projected through two timezones.
    insert.bind(
      "2026-08-03T12:00:00Z",
      "2026-08-03",
      20,
      "Asia/Singapore",
      "gpt-5",
      100,
      20,
      1,
      "7",
      1,
    ),
    insert.bind("2026-08-03T12:00:00Z", "2026-08-03", 12, "UTC", "gpt-5", 40, 8, 1, "3", 1),
    // A different model in the same hour, and one in the next UTC day.
    insert.bind(
      "2026-08-03T12:00:00Z",
      "2026-08-03",
      12,
      "UTC",
      "claude-opus-5",
      10,
      2,
      1,
      null,
      0,
    ),
    insert.bind("2026-08-04T00:00:00Z", "2026-08-04", 0, "UTC", "gpt-5", 5, 1, 1, null, 0),
  ]);
  await env.DB.prepare(
    `INSERT INTO usage_coverage(
       device_id, agent, start_at, end_at, parser_revision, submission_id, accepted_at, status
     ) VALUES ('device-1', 'codex', '2026-08-03T12:00:00Z', '2026-08-03T13:00:00Z',
               'parser-1', 'submission-1', '2026-08-03T13:00:00Z', 'complete')`,
  ).run();
}

describe("0018 hour-versioned facts and daily rollups", () => {
  it("collapses what only a local projection separated and backfills the days", async () => {
    const migrations = inject("TEST_MIGRATIONS");
    const index = migrations.findIndex((migration) =>
      migration.name.endsWith(HOUR_VERSION_MIGRATION),
    );
    expect(index).toBeGreaterThan(0);

    await applyD1Migrations(env.DB, migrations.slice(0, index));
    await seedRetainedFacts();
    await applyD1Migrations(env.DB, migrations.slice(index));

    const hourly = await env.DB.prepare(
      `SELECT bucket_start_utc, model, scan_version, partial, input_tokens, output_tokens,
              requests, source_cost_microusd, source_cost_covered_requests
       FROM usage_hourly ORDER BY bucket_start_utc, model`,
    ).all<Record<string, unknown>>();
    expect(hourly.results).toEqual([
      {
        bucket_start_utc: "2026-08-03T12:00:00Z",
        model: "claude-opus-5",
        // Retained facts arrive older than any scan a client can report, so the first upload
        // of that hour replaces them.
        scan_version: 0,
        partial: 0,
        input_tokens: 10,
        output_tokens: 2,
        requests: 1,
        source_cost_microusd: null,
        source_cost_covered_requests: 0,
      },
      {
        bucket_start_utc: "2026-08-03T12:00:00Z",
        model: "gpt-5",
        scan_version: 0,
        partial: 0,
        input_tokens: 140,
        output_tokens: 28,
        requests: 2,
        source_cost_microusd: "10",
        source_cost_covered_requests: 2,
      },
      {
        bucket_start_utc: "2026-08-04T00:00:00Z",
        model: "gpt-5",
        scan_version: 0,
        partial: 0,
        input_tokens: 5,
        output_tokens: 1,
        requests: 1,
        source_cost_microusd: null,
        source_cost_covered_requests: 0,
      },
    ]);

    const daily = await env.DB.prepare(
      `SELECT utc_date, model, input_tokens, output_tokens, requests, partial_hours
       FROM usage_daily ORDER BY utc_date, model`,
    ).all<Record<string, unknown>>();
    expect(daily.results).toEqual([
      {
        utc_date: "2026-08-03",
        model: "claude-opus-5",
        input_tokens: 10,
        output_tokens: 2,
        requests: 1,
        partial_hours: 0,
      },
      {
        utc_date: "2026-08-03",
        model: "gpt-5",
        input_tokens: 140,
        output_tokens: 28,
        requests: 2,
        partial_hours: 0,
      },
      {
        utc_date: "2026-08-04",
        model: "gpt-5",
        input_tokens: 5,
        output_tokens: 1,
        requests: 1,
        partial_hours: 0,
      },
    ]);

    const tables = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ).all<{ name: string }>();
    const names = tables.results.map((table) => table.name);
    expect(names).not.toContain("usage_coverage");
    expect(names).not.toContain("usage_submissions");
    expect(names).not.toContain("usage_submission_parts");

    const deviceColumns = await env.DB.prepare("PRAGMA table_info(devices)").all<{
      name: string;
    }>();
    const deviceNames = deviceColumns.results.map((column) => column.name);
    expect(deviceNames).not.toContain("last_sequence");
    expect(deviceNames).not.toContain("last_usage_sequence");
    expect(deviceNames).not.toContain("last_snapshot_digest");
    expect(deviceNames).toContain("usage_sync_revision");

    const snapshotColumns = await env.DB.prepare("PRAGMA table_info(quota_snapshots)").all<{
      name: string;
    }>();
    const snapshotNames = snapshotColumns.results.map((column) => column.name);
    expect(snapshotNames).not.toContain("sequence");
    expect(snapshotNames).not.toContain("captured_at");
    expect(snapshotNames).toContain("observed_at");
  });
});
