# ADR 0031: The Usage fold of an Account summary is stored, keyed by what it depends on

- Status: Accepted
- Date: 2026-09-02
- Extends [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md)

## Context

On 2026-09-01 the free-tier D1 daily row budget was exhausted by two Account-path reads.
`storedScanVersions` joined `usage_hour_scans` to `json_each` and compared every stored hour of
the (device, agent) against every wanted hour: about 96,000 rows read per call, about 10 million
rows/day over about 100 calls, about 80% of all D1 rows read. `GET /api/v6/account/summary`
recomputed the Usage fold — `queryDailyUsage` over 730 days plus `queryBoundaryHours` plus
`buildAccountUsage` — on every read whose ETag moved. The ETag also covers devices and
observations, which move with every device's every 5-minute upload, so the fold ran about 730
times, each reading the whole `usage_daily` table (about 1,235 rows): about 1.8 million rows/day,
about 15% of D1 reads, growing with history. The fold itself only changes with `usage_revision`
(the sum of `devices.usage_sync_revision`, bumped by accepted Usage uploads, about 34/day), the
device set/generation, the caller's `tz` and local date, and the two catalog revisions.

## Decision

**The folded `usage` object of a summary is stored in D1, keyed by a digest of exactly what it
depends on.** A read whose key matches serves the stored fold; a miss folds and stores. The key is
a canonical-JSON SHA-256 of `{fold, account, tz, local_date, all_from, devices, device_generation,
usage_revision, pricing_revision, model_catalog_revision}`. `fold` is `USAGE_FOLD_VERSION` (1),
bumped when `buildAccountUsage` changes the meaning of what it folds without changing its shape.
Retention sweeps folds whose `created_at` is older than two days; a fold never outlives the local
date in its key by more than retention. Nothing on the wire changes.

## Consequences

A retention sweep of `usage_daily` (800 days) is not in the key, so a fold can be at most one local
day stale with respect to it. Folds are per (account, key), so devices in different zones do not
evict each other. A stored fold is checked against the current `AccountUsage` contract on read and
refolded when it does not match, so a deploy that changes the shape needs no version bump.
