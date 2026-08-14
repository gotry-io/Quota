# ADR 0009: Versioned report-time model catalog

## Status

Accepted

## Context

Usage facts must remain auditable across provider naming changes. Rewriting a provider's model text
at collection time would lose evidence, make uploads differ from local source data, and require
retrofitting retained SQLite or Relay rows whenever a catalog is corrected. Pricing also has a
different matching contract and must not be changed by presentation cleanup.

## Decision

Keep the raw `model` value unchanged in local SQLite, Usage uploads, and Relay D1. Define a
language-neutral catalog in `packages/protocol/catalog/model-catalog.json`, validate it with the
generated `ModelCatalogSchema` artifact, and version it with `schema_version` and `revision`.
Canonical IDs are unique and aliases are explicit exact tuples of `reported_model` and inference
`provider`, optionally scoped by agent `client` and UTC
`[effective_from, effective_to)` dates. Resource limits, control-character/empty-value checks,
date-range checks, and overlap/ambiguity checks reject invalid catalogs. Regex aliases and automatic
case, trim, or fuzzy matching are not allowed.

The Rust service and Relay use equivalent resolvers only while constructing report summaries. Raw
facts are priced first. Resolved model groups use `canonical_id` as their stable model key;
unresolved groups use the raw model value. A catalog revision is included in newly opted-in
opted-in managed account summaries and is a required nullable field in local-v3 reports. The local SQLite
v4 migration drops only the cached derived v2 report and rebuilds it from retained facts; it does
not rewrite facts or the managed outbox.

Relay publishes the catalog through the independent read-only `GET /api/v2/model/catalog` endpoint,
using ETags and `public, max-age=300, must-revalidate` caching. The Rust client persists payload and
ETag atomically in a new append-only SQLite migration and keeps the last-known-good payload. Fetch
failure, a 304 without a cache, or invalid content never blocks collection, upload, totals, or report
generation; without a catalog, raw model keys are used.

Account summaries expose the revision only when a current client opts in with `model_catalog=1`, so
released strict clients do not receive unknown fields. Swift decodes the optional revision and
already-resolved breakdown key only; it does not resolve aliases or load the catalog. Diagnostics
expose revision availability, never model names.

During rollout, a 0.0.9 native client retries an account summary once without its automatically added
`model_catalog=1` and `usage_clients=1` opt-ins only when a released Relay returns
`400 invalid_request`. This narrow compatibility path is removed after QuotaBar and QuotaCLI 0.0.10
complete their release window; other failures are not retried.

## Consequences

Catalog updates are derived-view changes: the next report can regroup all retained raw rows without
reparsing source files or rewriting SQLite/D1 facts. Unknown or deliberately unlisted provider names
remain visible and auditable. A model can be normalized for grouping and still be unpriced. The
catalog is an additional cached component, but its failure is isolated from the Usage data path.
