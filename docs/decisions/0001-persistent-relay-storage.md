# ADR 0001: Persistent managed Relay storage

- Status: Accepted (revised 2026-08-10)
- Related: [ADR 0006](./0006-managed-account-device-usage.md)

## Context

QuotaRelay must preserve account identity, device lifecycle controls, token hashes, normalized quota
observations, sparse hourly Usage facts, coverage, idempotency receipts, pricing metadata, and bounded
rate-limit counters across Worker restarts. Lifecycle operations must update related rows
transactionally. Provider credentials and raw agent logs are outside this storage boundary.

The current product has one managed Cloudflare deployment. The former self-hosted SQLite runtime was
an unreleased parallel implementation and added schema, security, test, and deployment complexity
without serving the accepted product boundary.

## Decision

Cloudflare D1 is QuotaRelay's only persistent store. Runtime-neutral account and Usage services
depend on narrow state contracts; the D1 adapters implement those contracts without leaking SQL or
Cloudflare bindings into domain code.

Every schema change is an explicit ordered migration. The account/Usage v2 cutover is destructive
for unreleased owner/pairing data and does not add a dual-read or migration compatibility path.

The checked-in pricing catalog is canonical application data. Calculated Usage cost is derived at
read time and is not persisted as an authoritative invoice value.

R2 is not used. Normalized rows fit relational access patterns and current retention needs. If
future measurements require large exports or immutable archives, that storage boundary needs a new
decision.

## Consequences

- Production persistence, local migration verification, and lifecycle transactions use one schema.
- Relay domain tests can use in-memory state implementations, while deployment verification uses a
  Wrangler dry run and local D1 migrations.
- There is no SQLite dependency, container image, Compose configuration, or self-hosted executable.
- Backups, retention, and deployment remain managed Cloudflare operational concerns.
