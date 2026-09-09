import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it } from "vitest";
import { applyMigrations } from "../../src/platform/migrations.ts";
import { SqliteDatabase } from "../../src/platform/sqlite-database.ts";

const migrationsDirectory = fileURLToPath(new URL("../../migrations", import.meta.url));

let database: SqliteDatabase;

beforeEach(() => {
  database = new SqliteDatabase(":memory:");
});

/**
 * The SQLite driver answers what D1 answers.
 *
 * Every case here is a call `src/state/` already makes, read back the way that code reads it:
 * the two classes are shared by both runtimes, so a difference in these answers is a difference
 * in what Relay stores ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
describe("SqliteDatabase", () => {
  beforeEach(async () => {
    await database.exec(
      `CREATE TABLE rows (
         id TEXT PRIMARY KEY,
         label TEXT UNIQUE,
         count INTEGER NOT NULL
       )`,
    );
  });

  it("answers first(column) with the column, and null when nothing matched", async () => {
    await database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 4).run();
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM rows").first<number>("count"),
    ).toBe(1);
    expect(
      await database.prepare("SELECT label FROM rows WHERE id = ?1").bind("a").first(),
    ).toEqual({ label: "one" });
    expect(
      await database.prepare("SELECT label FROM rows WHERE id = ?1").bind("z").first("label"),
    ).toBeNull();
  });

  it("answers all() with results and run() with the rows it changed", async () => {
    const written = await database
      .prepare("INSERT INTO rows VALUES (?1, ?2, ?3)")
      .bind("a", "one", 4)
      .run();
    expect(written.success).toBe(true);
    expect(written.meta.changes).toBe(1);
    expect(written.results).toEqual([]);

    const missed = await database
      .prepare("UPDATE rows SET count = ?2 WHERE id = ?1")
      .bind("nobody", 9)
      .run();
    expect(missed.meta.changes).toBe(0);

    const read = await database.prepare("SELECT id, count FROM rows").all<{
      id: string;
      count: number;
    }>();
    expect(read.results).toEqual([{ id: "a", count: 4 }]);
    // A read changed nothing, whatever the write before it did.
    expect(read.meta.changes).toBe(0);
  });

  it("returns the RETURNING row and the count of what it changed", async () => {
    await database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 4).run();
    const updated = await database
      .prepare("UPDATE rows SET count = ?2 WHERE id = ?1 RETURNING count")
      .bind("a", 7)
      .run<{ count: number }>();
    expect(updated.results).toEqual([{ count: 7 }]);
    expect(updated.meta.changes).toBe(1);

    const refused = await database
      .prepare("UPDATE rows SET count = ?2 WHERE id = ?1 RETURNING count")
      .bind("gone", 7)
      .run<{ count: number }>();
    expect(refused.results).toEqual([]);
    expect(refused.meta.changes).toBe(0);
  });

  it("rolls the whole batch back when one statement fails", async () => {
    await expect(
      database.batch([
        database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 1),
        database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("b", "one", 2),
      ]),
    ).rejects.toThrow("UNIQUE constraint failed: rows.label");
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM rows").first<number>("count"),
    ).toBe(0);
  });

  it("commits a batch and reports each statement's own result", async () => {
    const results = await database.batch([
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 1),
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3) RETURNING id").bind("b", "two", 2),
      database.prepare("SELECT id FROM rows ORDER BY id"),
    ]);
    expect(results[0]?.meta.changes).toBe(1);
    expect(results[1]?.results).toEqual([{ id: "b" }]);
    expect(results[2]?.results).toEqual([{ id: "a" }, { id: "b" }]);
  });

  it("keeps SQLite's own words for a unique conflict", async () => {
    await database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 1).run();
    await expect(
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("b", "one", 2).run(),
    ).rejects.toThrow(/UNIQUE constraint failed/);
  });

  it("binds a JSON array for json_each(?)", async () => {
    await database.batch([
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 1),
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("b", "two", 2),
      database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("c", "three", 3),
    ]);
    const wanted = await database
      .prepare("SELECT id FROM rows WHERE id IN (SELECT value FROM json_each(?1)) ORDER BY id")
      .bind(JSON.stringify(["a", "c"]))
      .all<{ id: string }>();
    expect(wanted.results).toEqual([{ id: "a" }, { id: "c" }]);
  });

  it("upserts through ON CONFLICT and moves the stored value forward only", async () => {
    const upsert = (id: string, count: number) =>
      database
        .prepare(
          `INSERT INTO rows (id, label, count) VALUES (?1, ?1, ?2)
           ON CONFLICT(id) DO UPDATE SET count = excluded.count
           WHERE excluded.count > rows.count`,
        )
        .bind(id, count)
        .run();
    await upsert("a", 3);
    await upsert("a", 5);
    expect(
      await database.prepare("SELECT count FROM rows WHERE id = ?1").bind("a").first("count"),
    ).toBe(5);
    await upsert("a", 2);
    expect(
      await database.prepare("SELECT count FROM rows WHERE id = ?1").bind("a").first("count"),
    ).toBe(5);
  });

  it("keeps integers as numbers", async () => {
    await database.prepare("INSERT INTO rows VALUES (?1, ?2, ?3)").bind("a", "one", 1234).run();
    const row = await database
      .prepare("SELECT count FROM rows WHERE id = ?1")
      .bind("a")
      .first<{ count: number }>();
    expect(typeof row?.count).toBe("number");
  });
});

describe("applyMigrations", () => {
  it("applies the ladder once and records it in wrangler's own table", async () => {
    const applied = await applyMigrations(database, migrationsDirectory);
    expect(applied[0]).toBe("0001_initial.sql");
    expect(applied).toEqual([...applied].sort((left, right) => left.localeCompare(right)));

    const ledger = await database
      .prepare("SELECT sql FROM sqlite_master WHERE name = 'd1_migrations'")
      .first<string>("sql");
    // `wrangler d1 migrations apply --local` writes exactly this, so a database exported from D1
    // and imported here is already migrated rather than replayed.
    expect(ledger).toBe(
      `CREATE TABLE d1_migrations(
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT UNIQUE,
		applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
)`,
    );

    const rows = await database
      .prepare("SELECT id, name, applied_at FROM d1_migrations ORDER BY id")
      .all<{ id: number; name: string; applied_at: string }>();
    expect(rows.results.map((row) => row.name)).toEqual(applied);
    expect(rows.results[0]?.id).toBe(1);
    expect(rows.results[0]?.applied_at).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);

    expect(await applyMigrations(database, migrationsDirectory)).toEqual([]);
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM d1_migrations").first<number>("count"),
    ).toBe(applied.length);
  });

  it("leaves a schema the state classes can write to", async () => {
    await applyMigrations(database, migrationsDirectory);
    await database
      .prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?1, ?2, ?2)")
      .bind("account_1", "2026-09-09T00:00:00.000Z")
      .run();
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM accounts").first<number>("count"),
    ).toBe(1);
  });
});
