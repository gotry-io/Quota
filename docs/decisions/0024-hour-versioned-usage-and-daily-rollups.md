# ADR 0024: Replace an hour by version, fold days once, resolve subscriptions in Relay

- Status: Accepted
- Date: 2026-08-26
- Supersedes [ADR 0020](0020-coverage-is-a-verdict.md)

## Decision

Managed data advances to **v6** on `/api/v6/*`.

**An hour is the unit, and its version decides.** `PUT /api/v6/device/usage` carries
`{protocol_version, generation, agent, hours: [{bucket_start_utc, scan_version, partial, rows}]}`:
at most 256 hours, 512 rows in an hour, 1 MiB of body. A scan whose `scan_version` is strictly newer
than the one stored replaces every row of that hour; anything else is `ignored`, and every named hour
lands in exactly one list. There is no submission id, sequence, receipt, coverage window, multipart
batch, or write mode: a retry is a comparison, so crash-after-commit needs nothing remembered.
`partial` moves onto the hour it describes, and `UsageRow` drops `usage_date`, `usage_hour`, and
`aggregation_timezone`, which made one measurement look like two rows whenever a device moved.

**A day is folded once, at upload; a local day begins at local midnight.** The batch that replaces
an hour rewrites `usage_daily` for the UTC dates it touched. `all` and the activity read are that
rollup, on UTC dates. `today`, `last_7_days`, and `last_30_days` are exact in the caller's `tz`: each
is a range of instants whose whole UTC days come from the rollup, while the day an edge cuts is
folded from a run of `bucket_start_utc` — four such days, because the three end together, and an
edge falling inside an hour rounds up, because an hour is the finest fact stored.

**A subscription is resolved once, in Relay.** `GET /api/v6/account/summary?tz=` answers
`subscriptions[]` — one row per subscription key, carrying the chosen reading and every
`{device_id, observed_at}` behind it — plus devices, the four periods, and the pricing and
model-catalog revisions; `GET /api/v6/account/usage/activity?from&to` answers up to 400 daily totals.
Every earlier managed route is deleted, and a path naming a version this deployment does not serve
answers `client_upgrade_required`. D1 migration 0018 rebuilds `usage_hourly` on the new key with
`scan_version = 0`, backfills `usage_daily`, and drops `usage_coverage`, `usage_submissions`,
`usage_submission_parts`, and the sequence columns they were checked against; 0020 indexes
`usage_hourly` by `(device_id, bucket_start_utc)`, which is the run a period's edge walks.

**The device keeps the same unit.** `cache.sqlite` holds hourly facts on the same key; a scan
recomputes only the hours whose records moved and folds the four periods from that table in SQL,
against the same local midnights, so This Mac and Account agree. The scan revision lives in
`identity.sqlite`, because the cache is disposable and the revision has to keep climbing across a
rebuild. A log that only grew is read from the byte its last parse stopped on, confirmed by a digest
of the four kibibytes before it. The outbox is keyed by `(agent, hour)`, so staging is a copy and
accepted and ignored are the same answer.

## Why

Coverage windows, receipts, sequences, and multipart staging existed to make a stream of appends
idempotent and ordered. An hour carrying the version of the scan behind it is idempotent on its own,
which removes three tables, a sequence per device, and every conflict they could produce. Reads were
also folding every retained hour on each poll — the work that made a Worker exceed its CPU limit —
when what they report is days. Resolving subscriptions was one rule with five implementations, and a
property of the observations rather than of who is looking: one account collected on three Macs
reaching a dashboard as three cards was a defect no client test could catch.

## What was given up

The activity chart stays on UTC dates: 400 local days would cut 400 UTC days, which is the hourly
history the rollup exists to keep closed. `ignored` folds two answers into one — an hour a newer scan
replaced, and one before this device's deletion watermark — because the next move is the same. Rust
keeps a two-way merge against its own reading: local collection is the authority for the Mac at hand.
