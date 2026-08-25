# ADR 0012: Managed-data v3

- Status: Superseded by [ADR 0018](./0018-single-managed-data-contract.md) and
  [ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md)
- Date: 2026-08-14

menubar-v0.0.9 shipped network v2 with closed provider and `BillingAgent` enums, so adding Cursor —
by then both a quota provider and a local Usage source — would have made otherwise valid Account
summaries undecodable by every released client. Quota therefore introduced managed-data v3 for the
contracts that can carry a provider or a Usage agent (`/api/v3/device/snapshots`,
`/api/v3/device/usage`, `/api/v3/account/snapshots`, `/api/v3/account/usage*`,
`/api/v3/account/summary`) and left OAuth, Device control, pricing, and the independently versioned
model catalog where they were. Relay served the shipped v2 data routes alongside v3, with the v2
schemas rejecting Cursor and v2 reads filtered to the v2 sets; the provider catalog recorded both
`account_sync` and the first version that accepted a provider; and local SQLite migration v6 promoted
already-staged v2 outbox payloads by changing only their protocol version, because v3 was otherwise a
strict superset for their agents. The rule it set was that a closed-enum addition declares a new
protocol version rather than a second concurrent shape.

It was replaced twice over: [ADR 0018](./0018-single-managed-data-contract.md) deleted the
compatibility half — one contract is served at a time, and a client that cannot read it updates — and
[ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md) changed the shape again, so managed data
is now v6 and none of the routes, sequences, or opt-ins recorded here exist.
