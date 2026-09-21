import { describe, expect, it } from "vitest";
import type { RelayDatabase } from "../src/platform/database.ts";
import { applyTestMigrations, testDatabase, testMigrations } from "./support/database.ts";

const HISTORY_MIGRATION = "0034_quota_history.sql";
const stamp = "2026-09-21T00:00:00Z";

describe("0034 quota history", () => {
  it("creates the table and backfills history.sync false onto shipped settings rows", async () => {
    const migrations = await testMigrations();
    const index = migrations.findIndex((migration) => migration.name.endsWith(HISTORY_MIGRATION));
    expect(index).toBeGreaterThan(0);

    const db: RelayDatabase = await testDatabase(migrations.slice(0, index));
    await db
      .prepare("INSERT INTO accounts(id, created_at, updated_at) VALUES ('account-1', ?1, ?1)")
      .bind(stamp)
      .run();
    await db
      .prepare(
        `INSERT INTO account_settings (account_id, revision, settings_json, created_at, updated_at)
         VALUES ('account-1', 1, ?1, ?2, ?2)`,
      )
      .bind(
        JSON.stringify({
          alerts: { reset_reminders: true, pace_alerts: true, thresholds: {} },
          budget: { amount_usd: null, alerts: true },
        }),
        stamp,
      )
      .run();
    await applyTestMigrations(db, migrations.slice(index));

    const table = await db
      .prepare("SELECT sql FROM sqlite_master WHERE name = 'quota_history'")
      .first<string>("sql");
    expect(table).toContain("PRIMARY KEY");
    expect(table).toContain("REFERENCES devices(id) ON DELETE CASCADE");

    const indexes = await db
      .prepare(
        `SELECT name FROM sqlite_master
         WHERE type = 'index' AND tbl_name = 'quota_history' AND name NOT LIKE 'sqlite_%'
         ORDER BY name`,
      )
      .all<{ name: string }>();
    expect(indexes.results.map((indexRow) => indexRow.name)).toEqual([
      "quota_history_expires_idx",
      "quota_history_read_idx",
    ]);
    expect(table).toContain("expires_at");

    const json = await db
      .prepare("SELECT settings_json FROM account_settings WHERE account_id = 'account-1'")
      .first<string>("settings_json");
    expect(JSON.parse(json ?? "{}")).toMatchObject({ history: { sync: false } });
  });
});
