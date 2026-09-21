import { describe, expect, it } from "vitest";
import type { RelayDatabase } from "../src/platform/database.ts";
import { applyTestMigrations, testDatabase, testMigrations } from "./support/database.ts";

const SETTINGS_MIGRATION = "0033_account_settings.sql";
const stamp = "2026-09-21T00:00:00Z";

describe("0033 account settings", () => {
  it("creates the table and grants account:settings to live web, device, and reader sessions", async () => {
    const migrations = await testMigrations();
    const index = migrations.findIndex((migration) => migration.name.endsWith(SETTINGS_MIGRATION));
    expect(index).toBeGreaterThan(0);

    const db: RelayDatabase = await testDatabase(migrations.slice(0, index));
    await seedPreSettingsSessions(db);
    await applyTestMigrations(db, migrations.slice(index));

    const table = await db
      .prepare("SELECT sql FROM sqlite_master WHERE name = 'account_settings'")
      .first<string>("sql");
    expect(table).toContain("account_id TEXT PRIMARY KEY");
    expect(table).toContain("REFERENCES accounts(id) ON DELETE CASCADE");

    const sessions = await db
      .prepare("SELECT id, scopes_json, revoked_at IS NULL AS live FROM sessions ORDER BY id")
      .all<{ id: string; scopes_json: string; live: number }>();
    expect(sessions.results).toEqual([
      {
        id: "session-already",
        scopes_json: '["account:read","account:settings"]',
        live: 1,
      },
      {
        id: "session-device",
        scopes_json: '["account:read","device:write","account:settings"]',
        live: 1,
      },
      {
        id: "session-reader",
        scopes_json: '["account:read","account:settings"]',
        live: 1,
      },
      {
        id: "session-revoked",
        scopes_json: '["account:read","device:write"]',
        live: 0,
      },
      {
        id: "session-web",
        scopes_json: '["account:read","account:manage","account:settings"]',
        live: 1,
      },
    ]);
  });
});

async function seedPreSettingsSessions(db: RelayDatabase): Promise<void> {
  await db
    .prepare("INSERT INTO accounts(id, created_at, updated_at) VALUES ('account-1', ?1, ?1)")
    .bind(stamp)
    .run();
  await db
    .prepare(
      `INSERT INTO devices (
         id, account_id, installation_id_hash, generation, created_at, last_login_at
       ) VALUES ('device-1', 'account-1', 'installation-1', 1, ?1, ?1)`,
    )
    .bind(stamp)
    .run();
  const session = db.prepare(
    `INSERT INTO sessions (
       id, family_id, account_id, device_id, device_generation, client_kind,
       access_token_hash, refresh_token_hash, scopes_json,
       authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
     ) VALUES (?1, ?1, 'account-1', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?8, ?8, ?9, ?8)`,
  );
  await db.batch([
    session.bind(
      "session-web",
      null,
      null,
      "web",
      "access-web",
      null,
      '["account:read","account:manage"]',
      stamp,
      null,
    ),
    session.bind(
      "session-device",
      "device-1",
      1,
      "quotabar",
      "access-device",
      "refresh-device",
      '["account:read","device:write"]',
      stamp,
      null,
    ),
    session.bind(
      "session-reader",
      null,
      null,
      "ios",
      "access-reader",
      "refresh-reader",
      '["account:read"]',
      stamp,
      null,
    ),
    session.bind(
      "session-revoked",
      "device-1",
      1,
      "quotabar",
      "access-revoked",
      "refresh-revoked",
      '["account:read","device:write"]',
      stamp,
      stamp,
    ),
    session.bind(
      "session-already",
      null,
      null,
      "ios",
      "access-already",
      "refresh-already",
      '["account:read","account:settings"]',
      stamp,
      null,
    ),
  ]);
}
