# ADR 0012: Managed-data v3

- Status: Accepted
- Date: 2026-08-14

## Context

menubar-v0.0.9 shipped network v2 with closed provider and BillingAgent enums. Cursor later became
both a quota provider and a local Usage source. Adding it to v2 in place would make otherwise valid
Account summaries undecodable by released 0.0.9 through 0.0.11 clients.

OAuth grants, session tokens, Device control, and pricing do not contain either closed enum. The
model catalog remains on its independently versioned v1 contract; this change adds no Cursor-scoped
alias to that catalog.

## Decision

Quota introduces managed-data v3 for the contracts that can carry providers or Usage agents:

- `PUT /api/v3/device/snapshots` and `GET /api/v3/account/snapshots`;
- `PUT /api/v3/device/usage` and `GET /api/v3/account/usage*`;
- `GET /api/v3/account/summary`.

QuotaBar 0.0.12 and Quota Web use those routes with `protocol_version: 3`. OAuth, refresh, revoke,
Device authorization/control, pricing catalog, model catalog, account metadata, and Device
management remain on their existing v2 or independently versioned contracts.

QuotaBar 0.0.12 exposed one shipped-persistence constraint during this cutover: v2 Usage submissions
already staged in the durable local outbox failed the new v3 client validator before upload, which
also prevented a fresh Account summary from replacing the persisted v2 presentation. Local SQLite
migration v6, shipped by 0.0.13, promotes those v2 outbox payloads by changing only their protocol
version; managed-data v3 is otherwise a strict superset for their closed v2 agents and preserves the
same submission id, Device generation, sequence, coverage, and hourly facts. The migration clears
only the derived v2 Account summary and Account period caches so the first IPC state remains
decodable and Relay rebuilds current v3 presentation data.

Relay retains the shipped v2 data routes. V2 request schemas reject Cursor; v2 reads query only the
five v2 Usage agents and filter quota observations to the v2 provider set. Relay normalizes accepted
v2 writes into its current internal model. D1 migration 0009 expands the four Usage-agent
constraints without rewriting previous migrations.

The provider catalog records both whether a provider synchronizes (`account_sync`) and the first
managed-data version that accepts it (`account_sync_protocol`). Generated v2 and v3 provider enums
come from that source. Cursor starts at version 3.

## Consequences

- Released v2 clients continue to decode every response they can receive.
- Current clients synchronize and display Cursor quota and Usage end to end.
- Upgrading a released v2 local state preserves pending Usage uploads without letting a stale
  derived Account presentation make local quota unavailable.
- A future closed-enum addition must declare a new first-supported protocol version instead of
  mutating a shipped enum.
- V2 remains only for concrete shipped compatibility; new feature work targets v3.
