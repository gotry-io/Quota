import Database, { type Database as Connection, type Statement } from "better-sqlite3";
import type { RelayDatabase, RelayResult, RelayStatement } from "./database.ts";

/**
 * `RelayDatabase` over a local SQLite file, for the Node deployment.
 *
 * better-sqlite3 is synchronous, so a batch is a real SQLite transaction rather than a queue of
 * promises: the whole batch commits or the first failure rolls it back, which is what D1's batch
 * gives the same statements ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)).
 * SQLite's own error text reaches the caller unchanged, because the account state reads
 * `UNIQUE constraint failed` out of it to tell a taken identity from a broken write.
 */
export class SqliteDatabase implements RelayDatabase {
  private readonly connection: Connection;
  private readonly prepared = new Map<string, Statement>();

  constructor(path: string) {
    this.connection = new Database(path);
    this.connection.pragma("journal_mode = WAL");
    this.connection.pragma("foreign_keys = ON");
  }

  prepare(sql: string): RelayStatement {
    return new SqliteStatement(this, sql, {});
  }

  async batch<T = unknown>(statements: RelayStatement[]): Promise<RelayResult<T>[]> {
    const commit = this.connection.transaction(() =>
      statements.map((statement) => (statement as SqliteStatement).execute<T>()),
    );
    return commit();
  }

  async exec(sql: string): Promise<void> {
    this.connection.exec(sql);
  }

  close(): void {
    this.connection.close();
  }

  /** @internal Shared by every statement this database prepared. */
  statement(sql: string): Statement {
    const cached = this.prepared.get(sql);
    if (cached) return cached;
    const compiled = this.connection.prepare(sql);
    this.prepared.set(sql, compiled);
    return compiled;
  }

  /** @internal What the statement that just ran changed, for one that also returned rows. */
  writeMeta(): { changes: number; last_row_id: number } {
    const row = this.statement(
      "SELECT changes() AS changes, last_insert_rowid() AS last_row_id",
    ).get() as { changes: number; last_row_id: number };
    return { changes: Number(row.changes), last_row_id: Number(row.last_row_id) };
  }
}

class SqliteStatement implements RelayStatement {
  constructor(
    private readonly database: SqliteDatabase,
    private readonly sql: string,
    private readonly values: Record<string, unknown>,
  ) {}

  bind(...values: unknown[]): RelayStatement {
    return new SqliteStatement(
      this.database,
      this.sql,
      Object.fromEntries(values.map((value, index) => [String(index + 1), value])),
    );
  }

  first<T = unknown>(column: string): Promise<T | null>;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  async first<T>(column?: string): Promise<T | null> {
    const row = this.database.statement(this.sql).get(this.values) as
      | Record<string, unknown>
      | undefined;
    if (row === undefined) return null;
    if (column === undefined) return row as T;
    return (row[column] ?? null) as T | null;
  }

  async all<T = Record<string, unknown>>(): Promise<RelayResult<T>> {
    return this.execute<T>();
  }

  async run<T = Record<string, unknown>>(): Promise<RelayResult<T>> {
    return this.execute<T>();
  }

  /**
   * @internal One synchronous execution, so a batch can hold several inside one transaction.
   *
   * A statement that returns rows is read with `all`, and one that returns none with `run`;
   * `INSERT … RETURNING` is both, so its changed-row count is read back from SQLite rather than
   * from the empty `run` result better-sqlite3 would refuse to produce for it.
   */
  execute<T>(): RelayResult<T> {
    const statement = this.database.statement(this.sql);
    if (!statement.reader) {
      const info = statement.run(this.values);
      return {
        results: [],
        success: true,
        meta: { changes: info.changes, last_row_id: Number(info.lastInsertRowid) },
      };
    }
    const results = statement.all(this.values) as T[];
    return {
      results,
      success: true,
      meta: statement.readonly ? { changes: 0, last_row_id: 0 } : this.database.writeMeta(),
    };
  }
}
