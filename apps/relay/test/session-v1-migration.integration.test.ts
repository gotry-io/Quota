import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { describe, expect, inject, it } from "vitest";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const ONE_SESSION_MIGRATION = "0021_one_session_per_client.sql";
const stamp = "2026-08-01T00:00:00Z";

/**
 * Everything the two-table shape could hold, the way it held it.
 *
 * A collection login was two rows in two tables sharing a family: an account half that could read
 * the Account and a device half that could write the Device. A viewer login and a browser login
 * were one row each in the account table. Grants came in two kinds.
 */
async function seedRetainedSessions(): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO accounts(id, identity_subject, created_at, updated_at)
     VALUES ('account-1', 'subject-1', ?1, ?1)`,
  )
    .bind(stamp)
    .run();
  const device = env.DB.prepare(
    `INSERT INTO devices(
       id, account_id, installation_id_hash, platform, generation, created_at, last_login_at
     ) VALUES (?1, 'account-1', ?2, ?3, ?4, ?5, ?5)`,
  );
  const accountSession = env.DB.prepare(
    `INSERT INTO account_sessions(
       id, family_id, account_id, device_id, client_kind, access_token_hash, refresh_token_hash,
       scopes_json, authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
     ) VALUES (?1, ?2, 'account-1', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9, ?9)`,
  );
  const deviceSession = env.DB.prepare(
    `INSERT INTO device_sessions(
       id, family_id, device_id, device_generation, access_token_hash, refresh_token_hash,
       scopes_json, expires_at, refresh_expires_at, last_used_at, created_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '["device:write"]', ?7, ?7, ?7, ?7)`,
  );
  const grant = env.DB.prepare(
    `INSERT INTO login_grants(id, grant_kind, client_id, account_id, expires_at, created_at)
     VALUES (?1, ?2, ?3, 'account-1', ?4, ?4)`,
  );
  await env.DB.batch([
    device.bind("device-a", "installation-a", "linux", 1, stamp),
    device.bind("device-b", "installation-b", null, 2, stamp),
    // The account half of a collection login. Its instant is the only record of when the person
    // behind that login proved who they were.
    accountSession.bind(
      "session-account-a",
      "family-a",
      "device-a",
      "cli",
      "access-account-a",
      "refresh-account-a",
      '["account:read"]',
      "2026-08-02T09:30:00Z",
      stamp,
    ),
    accountSession.bind(
      "session-web",
      "family-web",
      null,
      "web",
      "access-web",
      null,
      '["account:read","account:manage"]',
      stamp,
      stamp,
    ),
    accountSession.bind(
      "session-ios",
      "family-ios",
      null,
      "ios",
      "access-ios",
      "refresh-ios",
      '["account:read"]',
      stamp,
      stamp,
    ),
    deviceSession.bind(
      "session-device-a",
      "family-a",
      "device-a",
      1,
      "access-device-a",
      "refresh-device-a",
      stamp,
    ),
    // A device half whose family never had an account half.
    deviceSession.bind(
      "session-device-b",
      "family-b",
      "device-b",
      2,
      "access-device-b",
      "refresh-device-b",
      "2026-08-05T00:00:00Z",
    ),
    grant.bind("grant-browser", "browser_pkce", "quotacli", stamp),
    grant.bind("grant-device-code", "device_code", "quotacli", stamp),
    grant.bind("grant-ios", "browser_pkce", "quota-ios", stamp),
  ]);
}

describe("0021 one session per client", () => {
  it("carries every retained login into one table and drops what no longer exists", async () => {
    const migrations = inject("TEST_MIGRATIONS");
    const index = migrations.findIndex((migration) =>
      migration.name.endsWith(ONE_SESSION_MIGRATION),
    );
    expect(index).toBeGreaterThan(0);

    await applyD1Migrations(env.DB, migrations.slice(0, index));
    await seedRetainedSessions();
    await applyD1Migrations(env.DB, migrations.slice(index));

    const sessions = await env.DB.prepare(
      `SELECT id, family_id, account_id, device_id, device_generation, client_kind,
              access_token_hash, scopes_json, authenticated_at,
              revoked_at IS NULL AS live
       FROM sessions ORDER BY id`,
    ).all<Record<string, unknown>>();
    expect(sessions.results).toEqual([
      // One collection login, one row: the device half is what survives, and it gains the read
      // its account half used to hold. The account half is gone, so one login has one token.
      {
        id: "session-device-a",
        family_id: "family-a",
        account_id: "account-1",
        device_id: "device-a",
        device_generation: 1,
        client_kind: "quotabar",
        access_token_hash: "access-device-a",
        scopes_json: '["account:read","device:write"]',
        // Taken from the account half, which is the only row that recorded it.
        authenticated_at: "2026-08-02T09:30:00Z",
        live: 0,
      },
      {
        id: "session-device-b",
        family_id: "family-b",
        account_id: "account-1",
        device_id: "device-b",
        device_generation: 2,
        client_kind: "quotabar",
        access_token_hash: "access-device-b",
        scopes_json: '["account:read","device:write"]',
        // No account half to take it from, so the row's own creation stands in.
        authenticated_at: "2026-08-05T00:00:00Z",
        live: 0,
      },
      {
        id: "session-ios",
        family_id: "family-ios",
        account_id: "account-1",
        device_id: null,
        device_generation: null,
        client_kind: "ios",
        access_token_hash: "access-ios",
        scopes_json: '["account:read"]',
        authenticated_at: stamp,
        live: 0,
      },
      // The browser's cookie is hashed under a domain this change does not rename, so it stays
      // signed in. Ending a session is no longer a scope.
      {
        id: "session-web",
        family_id: "family-web",
        account_id: "account-1",
        device_id: null,
        device_generation: null,
        client_kind: "web",
        access_token_hash: "access-web",
        scopes_json: '["account:read","account:manage"]',
        authenticated_at: stamp,
        live: 1,
      },
    ]);

    // Every carried-over native row is revoked, because its token was hashed under a domain this
    // change renames and can therefore never resolve again.
    const revoked = await env.DB.prepare(
      "SELECT revoked_at FROM sessions WHERE revoked_at IS NOT NULL",
    ).all<{ revoked_at: string }>();
    expect(revoked.results).toHaveLength(3);
    for (const row of revoked.results) {
      // Second precision, where an application write is milliseconds. Nothing compares the two
      // for equality; retention compares them as text, where this sorts a fraction of a second
      // late and is collected by the following sweep.
      expect(row.revoked_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    }

    // Authorization Code with PKCE over a loopback callback is the only grant left, and the
    // shared service is bundled inside QuotaBar rather than behind a command called quotacli.
    const grants = await env.DB.prepare("SELECT id, client_id FROM login_grants ORDER BY id").all<
      Record<string, unknown>
    >();
    expect(grants.results).toEqual([
      { id: "grant-browser", client_id: "quotabar" },
      { id: "grant-ios", client_id: "quota-ios" },
    ]);
    const grantColumns = await env.DB.prepare("PRAGMA table_info(login_grants)").all<{
      name: string;
    }>();
    const grantNames = grantColumns.results.map((column) => column.name);
    for (const retired of [
      "grant_kind",
      "device_code_hash",
      "user_code_hash",
      "installation_id_hash",
      "device_display_name",
      "platform",
      "poll_interval_seconds",
      "last_polled_at",
      "approved_at",
      "denied_at",
    ]) {
      expect(grantNames).not.toContain(retired);
    }

    // QuotaBar is the only client that registers a Device, so macos is the only platform a
    // Device can name — including one that named nothing.
    const platforms = await env.DB.prepare("SELECT id, platform FROM devices ORDER BY id").all<
      Record<string, unknown>
    >();
    expect(platforms.results).toEqual([
      { id: "device-a", platform: "macos" },
      { id: "device-b", platform: "macos" },
    ]);

    const tables = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ).all<{ name: string }>();
    const names = tables.results.map((table) => table.name);
    expect(names).not.toContain("account_sessions");
    expect(names).not.toContain("device_sessions");
    expect(names).toContain("sessions");
  });
});
