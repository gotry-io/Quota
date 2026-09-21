import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { RelayDatabase } from "../../src/platform/database.ts";
import { applyMigrations } from "../../src/platform/migrations.ts";
import { SqliteDatabase } from "../../src/platform/sqlite-database.ts";

/** One migration as the Node runner applies it: the file name and its SQL. */
export interface TestMigration {
  name: string;
  queries: string[];
}

/**
 * A `RelayDatabase` for this test: a fresh in-memory SQLite file with the ledger applied.
 *
 * Ladder tests that have to seed a retired shape pass a prefix so the later migration still
 * has something to carry; everyone else omits it and gets the whole ledger.
 */
export async function testDatabase(migrations?: TestMigration[]): Promise<RelayDatabase> {
  const database = new SqliteDatabase(":memory:");
  if (migrations === undefined) {
    await applyMigrations(database, fileURLToPath(new URL("../../migrations", import.meta.url)));
  } else {
    await applyListedMigrations(database, migrations);
  }
  return database;
}

/** Apply a further slice of the ladder to a database `testDatabase` already opened. */
export async function applyTestMigrations(
  database: RelayDatabase,
  migrations: TestMigration[],
): Promise<void> {
  await applyListedMigrations(database, migrations);
}

/** The ledger, in file-name order, so a ladder test can stop before a cutover. */
export async function testMigrations(): Promise<TestMigration[]> {
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

/**
 * The ledger table Node writes, copied from `src/platform/migrations.ts` so a prefix apply
 * matches the production runner. Byte-for-byte the same DDL.
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
