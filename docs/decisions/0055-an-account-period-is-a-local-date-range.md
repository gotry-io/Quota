# ADR 0055: An Account period is a local-date range on the hour grid

- Status: Accepted
- Date: 2026-09-19
- Extends [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md) and
  [ADR 0040](0040-a-period-is-folded-where-its-days-already-are.md)
- Supersedes the sentence in ADR 0040 that Relay gains no period route

## Context

[ADR 0040](0040-a-period-is-folded-where-its-days-already-are.md) left custom Account ranges to
whoever already held the days: the website and Quota iOS folded UTC activity days in the client,
and QuotaBar refused the question on Account. Those UTC days are not the caller's calendar. In a
zone such as UTC+8, summary Today and a custom range of today's local date disagree by the offset.

A4a measured the rollup-plus-boundary query: a year of a heavy-personal shape is ~35 ms on 1 vCPU,
inside the 192 MiB box, without a new persistent table. The hour-grid rule that `startOfLocalHour`
already implements is the one sentence every producer and consumer of a local period must share.

## Decision

**Relay answers `GET /api/v6/account/usage/period?from&to&timezone=` as an additive v6 Account
read.** Inclusive local dates in a required IANA timezone, at most 366 local days. Totals, cost,
and `cache_saved` come from interior `usage_daily` plus edge `usage_hourly`. `days[]` is one bucket
per local date, grouped in SQL over the local-day windows (one row per date and pricing
identity), never per-hour identity rows, so a year stays a few hundred rows inside the heap cap.
Gaps are omitted.

**A local day begins at the first whole UTC hour whose civil date in `timezone` is that local date.
The UTC hour that contains a fractional-offset midnight is assigned to the previous local day.
Counts are never prorated. A DST skip starts at the first hour the zone reads as that date; a DST
repeat counts both copies.**

**Presets are the same read.** `today` is `from=to=localDate`; `last_7_days` is `from=localDate-6`;
`last_30_days` is `from=localDate-29`. `all` stays the existing 730 UTC-day summary window.
Optional `breakdown=1` carries the agent tree, bounded like the summary.

**Missing ≠ zero.** A local day with no stored hour is omitted from `days[]`. Totals do not gain a
synthetic $0 / 0-token day. Unpriced cost stays unpriced, never `"0"`.

**Retention is coverage, not invention.** `coverage.truncated_by_retention` is true when the asked
range is not fully inside retention. `daily_retained_from` / `hourly_retained_from` are set only
when that cutoff cuts this range. Totals are only over what remains. Deleted devices
(`deleted_at IS NULL` on every usage read) do not linger.

**The cache is the ETag we already have.** Keyed by account, path, query (`from`, `to`, `timezone`,
`breakdown`), usage version stamp, catalog revisions, fold version, and a retention cutoff only
when it cuts the range. Explicit `{from,to}` does not roll over with the wall clock. A matching
`If-None-Match` returns 304 before any Usage SQL. There is no local-day rollup table.

The contract is `packages/protocol` (`AccountUsagePeriodResponseSchema`) and
`packages/protocol/fixtures/usage-period-conformance.json`. v6 summary and activity JSON do not
change. Clients switch onto this read in a later change.

## Consequences

QuotaBar can offer Account week / month / custom without folding UTC days. iOS and web can delete
the UTC-day fold that disagreed with summary Today. The four summary periods stay on
`GET /api/v6/account/summary?tz=` so a poll that only needs those four still pays one stored fold.
The period read is compute-on-demand. Local `days[]` are grouped in SQL: the handler builds one
hour-grid `[start, end)` per local date, joins `usage_hourly` onto that table, and groups by the
local date plus the dimensions pricing reads, so a dense year returns hundreds of rows rather than
tens of thousands of hour-identity rows. The response still carries at most 366 day buckets.

A malformed date, `from > to`, a span over 366 local days, or an unknown IANA zone is 400.
