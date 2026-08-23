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

Managed-data v3 itself shipped with QuotaBar 0.0.12, including a strict Device shape in Account
summary. Device Health therefore does not add a field to the default response. A new client requests
`GET /api/v3/account/summary?device_health=1`; only that opt-in response uses the strict extended
Device shape where `health` is required but nullable. Without the opt-in the `health` key is absent,
preserving the released response exactly. QuotaBar, Quota Web, and the read-only iOS Account client
opt in; write authority remains limited to the authenticated collection Device. The health contract
is defined by [ADR 0015](0015-diagnostic-attempts-and-device-health.md).

Because a packaged native client can update before Relay, ADR 0015 also defines the narrow released-
Relay fallback for `400 invalid_request`. The fallback retries the unchanged default v3 response and
locally represents its absent health as unknown; it does not weaken the opted-in wire schema.

The protocol-version key expresses a closed-enum addition only while some supported client is still
on the older version. `BillingChannel` is the case where it cannot: menubar-v0.0.19 already speaks
v3 and decodes the channel and its inference provider with exhaustive Swift enums, so an unknown
member fails to decode rather than degrading, and no v2/v3 split separates it. Such an addition
therefore reuses the query opt-in instead: the enum widens once, and a response narrows any member
outside the released set to `unknown` unless the caller sends `usage_channels=1`. Narrowing moves
`channel_source` with the channel and happens before grouping, so a narrowed row folds into the
existing unknown provider. Released v2 routes reject the opt-in and always narrow. The released
member list is derived from the widened enum in `packages/protocol`, never restated, and is removed
once no supported client predates the addition.

## Consequences

- Released v2 clients continue to decode every response they can receive.
- Current clients synchronize and display Cursor quota and Usage end to end.
- Upgrading a released v2 local state preserves pending Usage uploads without letting a stale
  derived Account presentation make local quota unavailable.
- A future closed-enum addition declares a new first-supported protocol version instead of
  mutating a shipped enum. When every supported client already speaks the newest version, that key
  cannot express the boundary, and the addition uses a query opt-in with server-side narrowing
  instead; `usage_channels=1` is the current example.
- Optional response expansion must remain explicit when a released strict client would reject an
  unknown field; Device Health's query opt-in is the current example.
- V2 remains only for concrete shipped compatibility; new feature work targets v3.
