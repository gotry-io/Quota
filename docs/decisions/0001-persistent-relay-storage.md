# ADR 0001: Persistent Relay storage

- Status: accepted
- Date: 2026-08-02

## Decision

QuotaRelay has no stateless production mode.

- The gotry-managed Cloudflare deployment uses D1 as its source of truth.
- Self-hosted deployments use an embedded SQLite database by default.
- Durable Objects are not part of v1. They may later coordinate Cloudflare WebSocket connections if
  polling proves insufficient, but never replace D1 business data.
- R2 is not part of the core request path.

## Rationale

Controllers, devices, pairing sessions, revocations, capability credentials, and current quota
snapshots are small, structured, mutable records with relational constraints. SQL provides indexes,
unique constraints, joins, and transactional device lifecycle operations. D1 and SQLite also allow
the managed and self-hosted runtimes to share one logical schema. Controllers are anonymous
authorization boundaries as defined in
[`0004-anonymous-relay-controllers.md`](0004-anonymous-relay-controllers.md), not user identities.

R2 is object storage. Using it for core state would require application-managed indexes, relations,
and multi-object concurrency control.

## Consequences

- Every production deployment must configure persistent storage.
- A self-hosted Relay must mount its SQLite data directory to durable storage.
- Revocation and last-known snapshots survive process restarts.
- R2 may be added later for large exports, diagnostics, or cold historical data without changing the
  primary state model.
