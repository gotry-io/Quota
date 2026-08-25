# ADR 0003: Preserve observations and merge subscriptions for presentation

- Status: accepted
- Date: 2026-08-03
- Updated: 2026-08-26

## Decision

QuotaRelay stores the latest quota observation for each `(device_id, provider, fingerprint)` and
does not globally deduplicate them in storage. **Since [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md)
it resolves them once, on the read**: `GET /api/v6/account/summary` answers `subscriptions[]`, one
row per subscription key, carrying the chosen reading and every source behind it. The rule below is
what that resolution follows, and it lives in `packages/quota-model`. No client restates it. Only
QuotaBar's Rust service still merges, and only two ways: the resolved row against its own local
reading, because local collection is the only authority for the machine in front of you.

Every account carries an explicit `account.fingerprint_scope`:

- `global` groups the same provider and fingerprint across observation sources.
- `source` groups only when provider, fingerprint, and caller-owned source identity match.

Local source identity is stable within the service. Remote source identity contains the Device ID.
Provider-specific global identity candidates remain defined in
[`provider-collection.md`](../provider-collection.md).

When a subscription has multiple observations, a reader selects one snapshot rather than averaging
or accumulating quota values. It prefers an available, unexpired snapshot, then the newest
`observed_at`, then local, and finally a deterministic source ID. The presentation retains every
unique source attached to the subscription.

`updated_at` takes no part in that order. It records when Relay last wrote the row, which a device
re-uploading a reading it already knows moves without making that reading newer, so ranking by it
lets the most stale reading win.

Only QuotaBar collects locally, so only its service can reach the local-source step. The order is
stated once as `packages/protocol/fixtures/quota-observation-conformance.json`, which Relay's
TypeScript implementation and the Rust one both answer, so neither can drift from the rule while
still passing its own tests.

## Rationale

Relay-side deduplication would discard device provenance, couple retention to provider identity
quality, and make revocation or device-specific troubleshooting ambiguous. Conflicting quota
observations are also not additive measurements; combining their numeric values would fabricate a
quota state. Presentation-time resolution preserves the evidence while showing one stable
subscription card.

An explicit source scope keeps usable quota visible when profile enrichment cannot identify the
quota owner and prevents weak fingerprints from merging unrelated subscriptions across machines.

## Consequences

- A single subscription may occupy one current row per reporting device, and Relay collapses those
  rows to one entry rather than sending the same account once per Mac.
- Protocol v2 requires `fingerprint_scope`; producers and Swift decoding use the same direct model.
- The service carries source identity alongside every local or remote snapshot before resolving it;
  Swift consumes the resolved result.
- Relay authentication and remote snapshot fetching remain separate work; this decision does not
  introduce a network API.
