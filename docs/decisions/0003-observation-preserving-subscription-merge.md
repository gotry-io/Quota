# ADR 0003: Preserve observations and merge subscriptions for presentation

- Status: accepted
- Date: 2026-08-03
- Updated: 2026-08-04

## Decision

QuotaRelay stores the latest quota observation for each `(device_id, provider, fingerprint)` and
does not globally deduplicate subscriptions. QuotaBar groups those observations only when building
its presentation model.

Every account carries an explicit `account.fingerprint_scope`:

- `global` groups the same provider and fingerprint across observation sources.
- `source` groups only when provider, fingerprint, and caller-owned source identity match.

Local source identity is stable within QuotaBar. Remote source identity contains both Relay instance
ID and device ID. Provider-specific global identity candidates remain defined in
[`provider-collection.md`](../provider-collection.md).

When a subscription has multiple observations, QuotaBar selects one snapshot rather than averaging
or accumulating quota values. It prefers an available, unexpired snapshot, then the newest
`observed_at`, then local, and finally a deterministic source ID. The presentation retains every
unique source attached to the subscription.

## Rationale

Relay-side deduplication would discard device provenance, couple retention to provider identity
quality, and make revocation or device-specific troubleshooting ambiguous. Conflicting quota
observations are also not additive measurements; combining their numeric values would fabricate a
quota state. Presentation-time resolution preserves the evidence while showing one stable
subscription card.

An explicit source scope keeps usable quota visible when profile enrichment cannot identify the
quota owner and prevents weak fingerprints from merging unrelated subscriptions across machines.

## Consequences

- A single subscription may occupy one current row per reporting device.
- Protocol v1 requires `fingerprint_scope`; producers and Swift decoding use the same direct model.
- QuotaBar carries source identity alongside every local or remote snapshot before resolving it.
- Relay authentication and remote snapshot fetching remain separate work; this decision does not
  introduce a network API.
