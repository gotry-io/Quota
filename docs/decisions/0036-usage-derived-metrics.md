# ADR 0036: A derived Usage metric is one rule, answered by one fixture

- Status: Accepted
- Date: 2026-09-06
- Extends [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md)

## Decision

Two numbers are derived from Usage rather than collected with it, and each is stated once per
runtime against `packages/protocol/fixtures/usage-metrics-conformance.json`.

**The cache hit rate is one share of one whole.** `input_tokens` is every input token a request
was billed for, and `cache_read_input_tokens` is the part of it a cache answered, so the rate is
`cache_read_input_tokens / input_tokens` — not a ratio between two separate measurements. A period
with no input has **no** rate, which is different from a rate of zero. It is carried as integer
basis points, rounded half up, so `quota-model`, the Rust service, and `QuotaPresentation` agree
exactly rather than to within a rounding. Nothing puts it on the wire: every reader already holds
the two counts.

**A cache saving is priced through the entry the row's cost resolved to.** `cache_saved` is
`Σ max(0, round(cache_read × uncached_input_rate) − round(cache_read × cache_read_rate))` over the
rows of a period, each side rounded half up the way a cost is. Only rows that read from a cache
take part; a cache **write** is what buying the cache cost and is already inside the cost beside
this. A row whose entry states no rate for either side is counted in `unpriced_rows` rather than
guessed at, which is what separates `partial` from `complete`; a saving that could price nothing is
`unavailable` and states no amount. Because pricing needs the rows and the catalog, this one is
folded where both exist — Relay for a managed period, the local service for This Mac — and travels
on `UsagePeriod.cache_saved` and the local period summary.

**A local period bounded by two local midnights carries its own days and its own clock.** The
private IPC period summary gains `days[]` (one entry per local date, with the same totals and cost
a period carries) and `hours_of_day[24]` (tokens and an amount per hour of the local clock, every
hour named). `all` carries neither: it is every retained day, and the per-day shape of two years is
what the activity chart answers. An hour nothing reached states no amount, because there is no
priced row behind it to state one.

## Why

Cache efficiency is the number a person checks first, and it was the one number Quota collected and
never showed. Stating it in four places would have produced four answers: the obvious formula,
`cache_read / (input + cache_read)`, double-counts under this schema, where the cache counts are
already inside `input_tokens`. A fixture the four runtimes answer makes that a test failure rather
than a support question.

Pricing a saving needs the row and the catalog, which only two runtimes hold, so it is folded
rather than derived — and folded from the rows a period already priced, which adds no query and no
D1 read. The rate is derived rather than folded for the same reason in reverse: everyone has the
counts, and a stored rate would be a second thing to keep true.

## What was given up

The rhythm is local only. Relay stores hours on UTC keys and resolves a caller's zone at the four
period edges (ADR 0024), so answering `hours_of_day` for a managed account would mean folding every
retained hour per timezone — the read the fold in ADR 0031 exists to avoid. The website and the iOS
app therefore show Daily and Models but no Rhythm, and their Daily table is UTC, as the activity
chart already is.

A saving is clamped at zero per row. A catalog that priced a cache read above uncached input saved
nothing on that row, which is what "saved" means; the cost outcome beside it already carries what
it actually cost.

## When to revisit

If a managed rhythm is wanted, the thing to change is what Relay stores, not what it folds on read:
an `usage_hourly` rollup keyed by local hour for the zones an account actually asks in.
