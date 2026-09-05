import type { D1Migration } from "@cloudflare/vitest-pool-workers";

/**
 * Where the ladder stops for a migration that has to preserve what it carries.
 *
 * `0025_account_identities.sql` empties every Account and everything hanging off one — the
 * cutover an Account owning its identities is ([ADR 0032](../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 * A test asking what an earlier migration did to rows it kept therefore runs the ladder up to
 * that cutover, not past it.
 */
const ACCOUNT_IDENTITIES_MIGRATION = "0025_account_identities.sql";

export function ladderThroughCutover(migrations: D1Migration[], from: number): D1Migration[] {
  const cutover = migrations.findIndex((migration) =>
    migration.name.endsWith(ACCOUNT_IDENTITIES_MIGRATION),
  );
  if (cutover < 0) throw new Error("The account identities cutover is missing from the ladder");
  return migrations.slice(from, cutover);
}
