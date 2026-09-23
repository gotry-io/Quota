# ADR 0062: Quota history may follow the Account, when the Account says so

- Status: Accepted
- Date: 2026-09-21
- Amended: 2026-09-22: a window's history is as long as its chart, not thirty days for
  everything. Span is `min(30 d, max(48 h, 4 × duration_seconds))`. Expiry is a stored
  `expires_at`. One duration per window. 50 000-row ceiling. Future points refused.
- Amended: 2026-09-23: the upload answer names each series' `oldest_bucket_start`, and a
  device that uploaded an older bucket in the current on-period backfills that series again.
- Supersedes the "never leaves" sentence of
  [ADR 0042](0042-quota-history-is-local-samples.md)
- Amends [ADR 0035](0035-quota-pace-is-derived-from-the-reading.md),
  [ADR 0051](0051-the-panel-glances-and-the-windows-explain.md),
  [ADR 0052](0052-quotabar-is-the-app-and-the-menu-bar-is-part-of-it.md), and
  [ADR 0061](0061-alert-policy-and-the-budget-follow-the-account.md)

## Context

[ADR 0042](0042-quota-history-is-local-samples.md) kept every remaining-quota sample on the
device that took it. Two devices of one Account drew different lines, and a reading that arrived
from another device carried no history. The owner decision is an Account-level switch, off by
default: turning it on backfills this device's 30 days; turning it off deletes what Relay holds.
Samples upload downsampled into buckets and are kept as long as the chart for that window
shows, stored per device, merged on the read. The website draws nothing this cycle.

## Decision

**Quota history may follow the Account, when the Account says so.**

The Account settings document ([ADR 0061](0061-alert-policy-and-the-budget-follow-the-account.md))
gains `"history": { "sync": false }`. Default is false. Absent in a `PUT` means **unchanged**,
not false: the website and any client that predates this field send only `alerts` and `budget`.
`alerts` and `budget` stay required. The stored and response documents always carry `history`.
The switch is never seeded from a device; a device has no local value for it.

`true → false` deletes every uploaded sample of the Account in the same transaction as the
settings write. Devices read the switch from the document they already sync. A device uploads
only while it reads `true`; Relay refuses an upload while it is `false`
(`409 history_sync_off`).

A local sample is `(subscription, window_id, resets_at, observed_at, used_percent)`. The producer
buckets:

- size **900 s** when the window's `duration_seconds ≤ 86 400`, else **3 600 s**;
- `bucket_start = floor(observed_at_epoch / size) × size`, UTC;
- the value of a bucket is the **maximum** `used_percent` observed in it for that `resets_at`;
- a bucket whose value equals the previous uploaded bucket of the same `(window, resets_at)` is
  not sent;
- the span of a window is **`min(30 d, max(48 h, 4 × duration_seconds))`** — 48 h rather than
  24 h so a chart's left edge is never the retention edge. Five-hour → 48 h; weekly → 28 d;
  monthly → 30 d. A producer drops points older than that; a series with no
  `duration_seconds` is refused.

Only **global-scope** subscriptions sync. The wire names a subscription by
`(provider, fingerprint)` with `fingerprint_scope` implicitly global — never by the local
12-hex selector.

`PUT /api/v6/device/quota-history` (`device:write`, current generation): at most 2 000 points
and 256 KiB; `bucket_start` must be aligned; a point older than the series' span plus one
bucket of clock slack, or more than one bucket ahead of now, is `400 invalid_request`; upsert
on `(device_id, provider, fingerprint, window_id, resets_at, bucket_start)` keeping the larger
`used_percent` and writing `duration_seconds` / `expires_at` even when the percent is not
larger (`updated_at` stays when nothing changed). The answer is the newest `bucket_start`
Relay now holds per series, and (amendment 2026-09-23) the oldest, `oldest_bucket_start`. An Account that already holds 50 000 rows is `413
quota_history_full`.

The span of a window is computed from the `duration_seconds` the uploading device declares.
Relay does not know a provider's windows. The latest declaration for
`(account, provider, fingerprint, window_id)` rewrites `duration_seconds` and `expires_at` of
every stored row of that key, so a read has one duration per window by construction.

`GET /api/v6/account/quota-history?provider=&fingerprint=&since=` (`account:read`): per window,
the union of every device's buckets, one point per `(resets_at, bucket_start)` taking
`MAX(used_percent)` in SQL, oldest first, `since` clamped **per window** to that window's
span; `ETag` from `(count, max(updated_at))` of the matching rows plus the switch; `304`
before the rows are read. With the switch off it answers `{ "sync": false, "windows": {} }`.
One subscription per request.

A row carries `expires_at` = `bucket_start` + span(`duration_seconds`) (canonical RFC 3339
UTC), swept hourly `WHERE expires_at < now` with its own batch of 5 000 rows. Delete Device
removes that device's rows. Delete Account names the table.

The language-neutral contract is
`packages/protocol/fixtures/quota-history-sync-conformance.json` (`bucket`, `merge`).
`QuotaRemainingHistory.fold` is unchanged: it folds whatever series it is handed.

## Consequences

- Two devices of one Account can draw the same line, when the Account says so.
- The default is still local: nothing is uploaded until someone turns the switch on.
- Turning the switch off is the deletion of what Relay holds, not a hide.
- The website's privacy page and the App Store labels change with this PR.
- On the 192 MiB / 1 vCPU / 64 MiB-heap shape, against 259 200 rows of the pre-span seed
  (measure phase in a fresh `node:24-bookworm-slim` process): read p50 15.07 ms / p95 33.64 ms
  (8 640 points), upload p50 26.03 / p95 34.26 ms, peak RSS 99.8 MiB.

## Amendment 2026-09-22

The span of a window is `min(30 d, max(48 h, 4 × duration_seconds))`, matching the chart
(`QuotaRemainingHistory` draws `min(30 d, max(24 h, 4 × duration))`; 48 h rather than 24 h so
the left edge is never the retention edge). Five-hour history is two days, not thirty. Upload,
read, and the sweep all use that span. `quotaHistorySpanSeconds` in `packages/quota-model` is
the one statement; the fixture judges it.

The span is taken from the duration the uploading device declares; Relay does not know a
provider's windows. The latest declaration for a window rewrites every row of that window.
Expiry is stored as `expires_at` and swept on that column. A point more than one bucket ahead
of now is refused. An Account at 50 000 rows is `413 quota_history_full`.

## Amendment 2026-09-23

A device only sees the switch as `true → true` when it goes off and on on the website between
two of its refreshes. Relay deleted every row at "off"; the device kept its watermark and would
upload only newer points, and the Account would miss the span for good. So:

- The upload answer names, per series the upload sent, `oldest_bucket_start` beside
  `bucket_start`: the oldest bucket Relay holds **from this device** (`MIN(bucket_start)` in
  the same query as the newest, a search of the primary key on `device_id`). A client reads
  it as optional (ADR 0023): an older Relay does not send it, and then nothing below applies.
- A device records, per series, the oldest bucket it has uploaded in the current on-period.
  Off, sign-out, and `409 history_sync_off` clear it with the watermark.
- **Relay lost rows** when that record is still live and the answer to an upload that sent
  the series names a later `oldest_bucket_start`, or leaves the series out. The device then
  clears that series' watermark and its last uploaded buckets, backfills its span once in the
  same pass, and continues. The rest of the pass is planned again from the cleared record.
- *Live* is: the recorded bucket plus its window's span is more than one hour after now. Relay
  sweeps expired rows hourly on its own clock, so a bucket in its last hour may be gone
  without anything having been lost. A record that is no longer live is re-seeded from the
  next accepted upload's oldest bucket; detection resumes from that point.

`quota_history_rows_lost` in `packages/service` and `QuotaHistorySync.rowsLost` in
`packages/apple-shared` state the rule; QuotaBar's helper and the iOS coordinator apply it.
