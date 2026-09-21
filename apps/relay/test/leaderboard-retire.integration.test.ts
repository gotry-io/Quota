import { describe, expect, it } from "vitest";
import type { RelayDatabase } from "../src/platform/database.ts";
import { ladderAfter } from "./migration-ladder.ts";
import { applyTestMigrations, testDatabase, testMigrations } from "./support/database.ts";

const PUBLIC_PROFILE_LEADERBOARD_MIGRATION = "0029_public_profile_leaderboard.sql";

describe("0032 drops what only the board used", () => {
  it("keeps an opted-in public page and removes the board column from an 0029-era database", async () => {
    const migrations = await testMigrations();
    const leaderboardIndex = migrations.findIndex((migration) =>
      migration.name.endsWith(PUBLIC_PROFILE_LEADERBOARD_MIGRATION),
    );
    expect(leaderboardIndex).toBeGreaterThan(0);

    const db: RelayDatabase = await testDatabase(migrations.slice(0, leaderboardIndex + 1));
    await db
      .prepare(
        `INSERT INTO accounts (id, display_label, created_at, updated_at)
         VALUES ('account_listed', 'Listed', '2026-09-06T00:00:00Z', '2026-09-06T00:00:00Z')`,
      )
      .run();
    await db
      .prepare(
        `INSERT INTO public_profiles (
           account_id, handle, enabled, show_models, show_cost, on_leaderboard,
           created_at, updated_at
         ) VALUES (
           'account_listed', 'listed', 1, 1, 0, 1,
           '2026-09-06T00:00:00Z', '2026-09-06T00:00:00Z'
         )`,
      )
      .run();
    expect(
      await db
        .prepare("SELECT on_leaderboard FROM public_profiles WHERE account_id = 'account_listed'")
        .first<number>("on_leaderboard"),
    ).toBe(1);

    await applyTestMigrations(db, ladderAfter(migrations, PUBLIC_PROFILE_LEADERBOARD_MIGRATION));

    const columns = await db.prepare("PRAGMA table_info(public_profiles)").all<{ name: string }>();
    expect(columns.results.map((column) => column.name)).toEqual([
      "account_id",
      "handle",
      "enabled",
      "show_models",
      "show_cost",
      "created_at",
      "updated_at",
    ]);
    const indexes = await db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'public_profiles'",
      )
      .all<{ name: string | null }>();
    expect(indexes.results.map((row) => row.name)).not.toContain("public_profiles_on_leaderboard");
    expect(
      await db
        .prepare(
          `SELECT handle, enabled, show_models, show_cost
             FROM public_profiles WHERE account_id = 'account_listed'`,
        )
        .first<{ handle: string; enabled: number; show_models: number; show_cost: number }>(),
    ).toEqual({
      handle: "listed",
      enabled: 1,
      show_models: 1,
      show_cost: 0,
    });
  });
});
