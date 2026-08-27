# ADR 0018: Serve one managed data contract

- Status: Partially superseded by [ADR 0023](./0023-strict-writes-tolerant-reads.md) on 2026-08-25
- Date: 2026-08-24
- Supersedes the compatibility half of [ADR 0012](./0012-managed-data-v3.md)

Relay serves one managed data contract and refuses a client that speaks a retired one rather than
translating for it. The shape changed here, so the contract advanced to v4 on `/api/v4/*` and the
parallel v2 data routes were deleted, while OAuth, Device authorization and control, account
metadata, and the separately versioned pricing and model catalogs kept their own paths. Four
compatibility mechanisms went with those routes: duplicated `*V3` schemas collapsed into one
`QuotaSnapshot`, `UsageSubmission`, `AccountSummary`, `BillingAgent`, and managed `ProviderId`;
per-provider protocol gating, so `account_sync` alone decides whether a provider reaches the Account;
channel narrowing, so every stored billing channel is reported as stored; and the read opt-ins
(`device_health=1`, `model_catalog=1`, `usage_clients=1`) that existed only so a released strict
client would not meet an unknown field — together with the native client's retry-without-opt-ins
fallback, so a Relay that rejects a read is reported as the error it is. The rationale was that each
addition otherwise had to be expressed twice and a reader could satisfy its own tests while
disagreeing with the other copy; that duplication is how one account collected on three Macs reached
the dashboard as three cards. `PROTOCOL_VERSION` stays 2 for the control plane, each runtime names
its managed-data version exactly once, and the exported JSON Schemas lost their version suffixes.

The half [ADR 0023](./0023-strict-writes-tolerant-reads.md) replaced is the reason for a version
bump: a client too old to read a *field* now ignores it instead, and only a change of shape moves the
version — which it has done twice since, to v5 by [ADR 0020](./0020-coverage-is-a-verdict.md) and to
**v6** by [ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md).
