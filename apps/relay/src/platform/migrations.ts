import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { RelayDatabase } from "./database.ts";

/**
 * Wrangler's own ledger table, byte for byte.
 *
 * A self-hosted deployment is expected to start from `wrangler d1 export`, so the imported file
 * already carries this table with every migration named in it; writing a differently shaped one
 * would make the Node runtime replay migrations D1 had already applied
 * ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
const MIGRATIONS_TABLE = `CREATE TABLE IF NOT EXISTS d1_migrations(
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT UNIQUE,
		applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
)`;

/** Apply every migration the ledger does not already name, in file-name order. */
export async function applyMigrations(
  database: RelayDatabase,
  directory: string,
): Promise<string[]> {
  await database.exec(MIGRATIONS_TABLE);
  const applied = new Set(
    (await database.prepare("SELECT name FROM d1_migrations").all<{ name: string }>()).results.map(
      (row) => row.name,
    ),
  );
  const pending = (await readdir(directory))
    .filter((name) => name.endsWith(".sql"))
    .sort((left, right) => left.localeCompare(right))
    .filter((name) => !applied.has(name));
  for (const name of pending) {
    await database.exec(await readFile(join(directory, name), "utf8"));
    await database.prepare("INSERT INTO d1_migrations (name) VALUES (?1)").bind(name).run();
  }
  return pending;
}
