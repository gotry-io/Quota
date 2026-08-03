# ADR 0003: Preserve observations and merge subscriptions for presentation

- Status: accepted
- Date: 2026-08-03

## Decision

QuotaRelay stores the latest quota observation for each `(device_id, provider, fingerprint)` and
does not globally deduplicate subscriptions. QuotaBar groups those observations only when building
its presentation model.

An explicit `account.fingerprint_scope` controls grouping:

- `global` groups the same provider and fingerprint across observation sources.
- `source` groups only when provider, fingerprint, and caller-owned source identity match.
- A missing scope is interpreted as `source` so version 1 snapshots created before the field existed
  cannot be merged across devices accidentally.

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

Source-scoped fallback keeps usable quota visible when profile enrichment cannot identify the quota
owner. It also prevents a weak fallback or released v1 snapshot from merging unrelated subscriptions
across machines.

## Consequences

- The existing Relay primary key and migrations remain unchanged.
- A single subscription may occupy one current row per reporting device.
- QuotaCLI 0.1.0 already published version 1 reports without `fingerprint_scope`, so the field
  remains optional and no protocol version bump is required.
- QuotaBar must carry source identity alongside every local or remote snapshot before resolving it.
- Relay authentication and remote snapshot fetching remain separate work; this decision does not
  introduce a network API.
