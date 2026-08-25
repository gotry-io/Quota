# ADR 0024: Replace an hour by version, fold days once, resolve subscriptions in Relay

- Status: Accepted
- Date: 2026-08-26
- Supersedes [ADR 0020](0020-coverage-is-a-verdict.md)

## Decision

Managed data advances to **v6** on `/api/v6/*`.

**An hour is the unit, and its version decides.** `PUT /api/v6/device/usage` carries
`{protocol_version, generation, agent, hours: [{bucket_start_utc, scan_version, partial, rows}]}`:
at most 256 hours, 512 rows in an hour, 1 MiB of body. A scan whose `scan_version` is strictly
newer than the one stored replaces every row of that hour; anything else is `ignored`. The response
is `{accepted, ignored}` and every named hour is in exactly one list.

There is no submission id, sequence, receipt, coverage window, multipart batch, or write mode: a
retry is a comparison, so crash-after-commit needs nothing remembered. `partial` moves from a
window to the hour it describes, and a read reports it per period. `UsageRow` drops `usage_date`,
`usage_hour`, and `aggregation_timezone`, which made one measurement look like two rows whenever a
device moved.

**A day is folded once, at upload.** The same D1 batch that replaces an hour rewrites `usage_daily`
for the UTC dates it touched. Every managed read folds days from that rollup and never opens
`usage_hourly`. A day is a UTC day; the `tz` a caller names decides which calendar days `today`,
`last_7_days`, and `last_30_days` cover, not where a day begins.

**A subscription is resolved once, in Relay.** `GET /api/v6/account/summary?tz=` answers
`subscriptions[]` — one row per subscription key, carrying the chosen reading and every
`{device_id, observed_at}` behind it — plus devices, the four periods, and the pricing and
model-catalog revisions. `GET /api/v6/account/usage/activity?from&to` answers up to 400 daily
totals. Every `/api/v5/*` route is deleted, and a path naming a version this deployment does not
serve still answers `client_upgrade_required`.

D1 migration 0018 rebuilds `usage_hourly` on the new key with `scan_version = 0`, backfills
`usage_daily`, drops `usage_coverage`, `usage_submissions`, and `usage_submission_parts`, and drops
the sequence columns and snapshot digest those tables were checked against.

## Why

Coverage windows, receipts, sequences, and multipart staging existed to make a stream of appends
idempotent and ordered. An hour carrying the version of the scan behind it is idempotent on its
own, which removes three tables, a sequence per device, and every conflict they could produce.
Reads were also folding every retained hour on each poll — the work that made a Worker exceed its
CPU limit — when what they report is days.

Resolving subscriptions was one rule with five implementations. It is a property of the stored
observations, not of who is looking, so one account collected on three Macs reaching a dashboard as
three cards was a defect no client-side test could catch.

## What was given up

A local day is no longer exact for a caller whose clock is not UTC: a period names UTC days by the
caller's calendar. Answering otherwise would need model-level detail per hour on every read, which
is the cost this rollup exists to remove.

`ignored` folds two answers into one — an hour a newer scan already replaced, and an hour before
this device's deletion watermark. The device's next move is the same for both: stop sending it.
Rust keeps a two-way merge of the resolved row against its own local reading, because local
collection is the only authority for the machine in front of you.
