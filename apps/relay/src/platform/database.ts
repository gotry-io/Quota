/**
 * The database surface Relay's SQL speaks, which is D1's.
 *
 * Every statement in `src/state/` is written against these three types and nothing else, so the
 * same SQL runs against Cloudflare D1 and against a local SQLite file
 * ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)). Cloudflare's
 * `D1Database` satisfies it structurally: this is the intersection the business code already
 * used, written down, not a wrapper D1 has to be adapted to.
 */
export interface RelayDatabase {
  prepare(sql: string): RelayStatement;
  /** One transaction: every statement commits, or the first failure rolls all of them back. */
  batch<T = unknown>(statements: RelayStatement[]): Promise<RelayResult<T>[]>;
  /** Run a script of statements. Nothing reads the result; D1's is a diagnostic. */
  exec(sql: string): Promise<unknown>;
}

export interface RelayStatement {
  /** Values for `?1`…`?n`, in order. Relay's SQL numbers every placeholder. */
  bind(...values: unknown[]): RelayStatement;
  first<T = unknown>(column: string): Promise<T | null>;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<RelayResult<T>>;
  run<T = Record<string, unknown>>(): Promise<RelayResult<T>>;
}

export interface RelayResult<T = unknown> {
  results: T[];
  success: true;
  meta: { changes: number; last_row_id: number };
}
