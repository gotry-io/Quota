# ADR 0009: Versioned report-time model catalog

- Status: Accepted
- Date: 2026-08-12

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

Account summaries exposed the revision only behind a `model_catalog=1` opt-in so released strict
clients did not receive unknown fields, and a native client retried once without its opt-ins when an
older Relay rejected them. Swift decodes the optional revision and already-resolved breakdown key
only; it does not resolve aliases or load the catalog. Diagnostics expose revision availability,
never model names.

**Updated 2026-08-24:** [ADR 0018](0018-single-managed-data-contract.md) removed the opt-ins and the
retry. Account summaries always carry the catalog revision and the agent groups, and a rejected
read is reported as the error it is.

**Updated 2026-08-27:** the catalog also names the vendor a model belongs to. A Usage summary's
`provider` is the company whose model answered — OpenAI, Anthropic, Google, xAI, Moonshot,
DeepSeek, Cursor — resolved from the raw model name by the catalog's `families`: explicit lowercase
prefixes, matched ASCII case-insensitively, longest prefix winning. A name no family claims is
`unknown`. The billing channel stays on the fact for pricing and audit and never chooses the
group: it says who was paid, not who made the model, so an endpoint alias reached through a
vendor's own provider id is still unknown, and a gateway (OpenRouter, Bedrock, Vertex, Azure) is
never a group of its own. Aliases are still exact tuples; the case-insensitive rule is the family list's alone, because
a family is a reviewed statement about a name, not a guess. The Rust service ships the checked-in
catalog and uses it until Relay's has been read, so a first launch groups the same way.

## Consequences

Catalog updates are derived-view changes: the next report can regroup all retained raw rows without
reparsing source files or rewriting SQLite/D1 facts. Unknown or deliberately unlisted provider names
remain visible and auditable. A model can be normalized for grouping and still be unpriced. The
catalog is an additional cached component, but its failure is isolated from the Usage data path.
