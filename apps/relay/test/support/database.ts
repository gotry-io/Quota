import type { RelayDatabase } from "../../src/platform/database.ts";

declare global {
  interface ImportMeta {
    readonly env: { readonly RELAY_TEST_DRIVER?: string };
  }
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
    }
  }
}

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: TestMigration[];
  }
}

/**
 * Which driver this Vitest run is exercising.
 *
 * `vitest.node*.config.ts` defines this as `"sqlite"` so the Node run never loads
 * `cloudflare:test`. The Workers configs define it as `"d1"`, so the same files talk to Miniflare's D1.
 * Both sides of the branch are dynamic imports: a static `cloudflare:test` import fails to
 * resolve under Node, and a static `better-sqlite3` import fails to load inside workerd.
 */
const sqliteDriver = import.meta.env.RELAY_TEST_DRIVER === "sqlite";

/** One migration as wrangler's `readD1Migrations()` answers it. */
export interface TestMigration {
  name: string;
  queries: string[];
}

/**
 * A `RelayDatabase` for this test: Miniflare's D1 with the ledger applied, or a fresh
 * in-memory SQLite file with the same migrations.
 *
 * Ladder tests that have to seed a retired shape pass a prefix so the later migration still
 * has something to carry; everyone else omits it and gets the whole ledger.
 */
export async function testDatabase(migrations?: TestMigration[]): Promise<RelayDatabase> {
  if (sqliteDriver) {
    const database = await openSqlite();
    if (migrations === undefined) {
      const { applyMigrations } = await import("../../src/platform/migrations.ts");
      const { fileURLToPath } = await import("node:url");
      await applyMigrations(database, fileURLToPath(new URL("../../migrations", import.meta.url)));
    } else {
      await applyListedMigrations(database, migrations);
    }
    return database;
  }
  const { applyD1Migrations, env } = await import("cloudflare:test");
  await applyD1Migrations(env.DB, migrations ?? (await testMigrations()));
  return env.DB;
}

/** Apply a further slice of the ladder to a database `testDatabase` already opened. */
export async function applyTestMigrations(
  database: RelayDatabase,
  migrations: TestMigration[],
): Promise<void> {
  if (sqliteDriver) {
    await applyListedMigrations(database, migrations);
    return;
  }
  const { applyD1Migrations } = await import("cloudflare:test");
  await applyD1Migrations(database as D1Database, migrations);
}

/** The ledger, in file-name order, so a ladder test can stop before a cutover. */
export async function testMigrations(): Promise<TestMigration[]> {
  if (sqliteDriver) {
    const { readdir, readFile } = await import("node:fs/promises");
    const { join } = await import("node:path");
    const { fileURLToPath } = await import("node:url");
    const directory = fileURLToPath(new URL("../../migrations", import.meta.url));
    const names = (await readdir(directory))
      .filter((name) => name.endsWith(".sql"))
      .sort((left, right) => left.localeCompare(right));
    return Promise.all(
      names.map(async (name) => ({
        name,
        queries: [await readFile(join(directory, name), "utf8")],
      })),
    );
  }
  const { inject } = await import("vitest");
  return inject("TEST_MIGRATIONS");
}

async function openSqlite(): Promise<RelayDatabase> {
  const { SqliteDatabase } = await import("../../src/platform/sqlite-database.ts");
  return new SqliteDatabase(":memory:");
}

/**
 * Wrangler's ledger table, copied from `src/platform/migrations.ts` so this helper does not
 * import `node:fs` into the Workers bundle. Byte-for-byte the same DDL.
 */
const MIGRATIONS_TABLE = `CREATE TABLE IF NOT EXISTS d1_migrations(
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT UNIQUE,
		applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
)`;

async function applyListedMigrations(
  database: RelayDatabase,
  migrations: TestMigration[],
): Promise<void> {
  await database.exec(MIGRATIONS_TABLE);
  const applied = new Set(
    (await database.prepare("SELECT name FROM d1_migrations").all<{ name: string }>()).results.map(
      (row) => row.name,
    ),
  );
  for (const migration of migrations) {
    if (applied.has(migration.name)) continue;
    await database.exec(migration.queries.join(";\n"));
    await database
      .prepare("INSERT INTO d1_migrations (name) VALUES (?1)")
      .bind(migration.name)
      .run();
  }
}
