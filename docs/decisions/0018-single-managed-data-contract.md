# ADR 0018: Serve one managed data contract

> Status: Partially superseded by [ADR 0023](./0023-strict-writes-tolerant-reads.md) on 2026-08-25.
> A client too old to read a field is no longer a reason to move the contract version.

- Status: accepted
- Date: 2026-08-24
- Supersedes the compatibility half of [ADR 0012](0012-managed-data-v3.md)

## Decision

Relay serves one managed data contract, and its shape changed, so it advances to **managed-data v4**
on `/api/v4/*` with `protocol_version: 4`. The parallel v2 data routes are deleted:

- `GET /api/v2/account/snapshots`, `/api/v2/account/summary`, `/api/v2/account/usage`,
  `/api/v2/account/usage/summary`, and `/api/v2/account/usage/hourly`;
- `PUT /api/v2/device/snapshots` and `/api/v2/device/usage`.

OAuth, Device authorization and control, account metadata, public profiles, pricing catalog, and
model catalog keep their v2 paths. Those are the current version of those endpoints rather than a
retained older shape. The catalog payloads carry their own `schema_version`, which is how the
model catalog's `agent` rename is expressed.

Three compatibility mechanisms that existed only to keep released clients working go with them:

- **Duplicated schemas.** Every `*V3` protocol type replaces the v2 type it extended, so there is one
  `QuotaSnapshot`, one `UsageSubmission`, one `AccountSummary`, one `BillingAgent` set, and one
  managed `ProviderId` set.
- **Per-provider protocol gating.** `account_sync_protocol` is removed from the provider catalog;
  `account_sync` alone decides whether a provider reaches the Account.
- **Channel narrowing.** Relay no longer rewrites a billing channel newer than menubar-v0.0.19 to
  `unknown`, and `usage_channels=1` is no longer a query parameter. Every stored channel is reported
  as stored.
- **Read opt-ins that existed so a released strict client would not meet an unknown field.**
  The per-device health, `model_catalog=1`, and `usage_clients=1` opt-ins are gone: an Account
  summary always carries the model-catalog revision and the agent groups, and carried the health
  shape until [ADR 0022](0022-minimal-diagnostics.md) removed it. The native client's
  retry-without-opt-ins fallback is gone with them, so a Relay that rejects a read is reported as
  the error it is rather than answered with a quietly smaller summary.

A client that speaks a retired shape is refused, not translated.

## Rationale

Compatibility was scoped to a shipped boundary, but the boundary never closed on its own: each
addition had to be expressed twice, once for the current contract and once for the released one, and
a reader could satisfy its own tests while disagreeing with the other copy. The duplication also hid
a real defect. `AccountSummary` existed in two shapes, and the reader that resolved observations into
subscriptions was written against neither, which is how one account collected on three Macs reached
the dashboard as three cards.

Keeping released clients working is worth compatibility only while those clients are the ones people
run. QuotaBar ships with an in-app updater on a repository `latest` alias, so the supported recovery
for a client that cannot speak the current contract is to update, which it does on its own.

## Consequences

- A device on a release older than this change cannot upload quota or Usage, and cannot read Account
  data, until it updates. Its stored observations remain and expire on their own terms.
- The exported JSON Schemas lose their version suffixes: `quota-snapshot.json`, `usage.json`,
  `account-http.json`, `local-usage.json`, and `quota-collection-report.json`. Separately versioned
  catalogs keep theirs.
- `PROTOCOL_VERSION` remains 2 for the control plane, `LOCAL_USAGE_PROTOCOL_VERSION` remains 3 for
  the private local report, and `MANAGED_DATA_PROTOCOL_VERSION` becomes 4. Each runtime names its
  contract version once — `packages/protocol`, `WireCodec`, and `packages/service`'s `protocol`
  module — so a payload cannot carry a magic number that disagrees with the check that reads it.
- A device that speaks v3 is refused by version rather than by a puzzling field error: the route is
  gone and the version literal no longer matches.
- Local SQLite migration v9 promotes staged v3 Usage outbox payloads to v4 in place, because v4 kept
  the shape v3 had for a submission, and discards the derived Account presentation and Account
  period caches so the first v4 read rebuilds them. That mirrors what migration v6 did for the
  v2-to-v3 cutover.
- D1 migration 0013 strips the retired `valid_until` stamp from stored observations so they parse
  under the single snapshot schema.
