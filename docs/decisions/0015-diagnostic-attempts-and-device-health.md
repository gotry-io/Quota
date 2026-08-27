# ADR 0015: Diagnostic attempts, support reports, and Device Health

- Status: Superseded by [ADR 0022](./0022-minimal-diagnostics.md) on 2026-08-25
- Date: 2026-08-15

The diagnostics evaluator of [ADR 0008](./0008-data-integrity-and-diagnostics.md) needed durable
evidence about completed work, so an owner-only structured attempt journal recorded every refresh and
its `quota_collection`, `usage_scan`, `usage_upload`, `account_sync`, and `pricing_refresh` children
with a typed trigger, source, safe subject, mode, timings, outcome, code, recovery, bounded metrics,
state revision, and parent. A row was inserted before work began — a failed insert cancelled the work
— and finalized afterwards; completing a parent, or reopening the database, marked a still-running
child `interrupted`. `partial` was kept distinct from `success`, subjects were catalog-owned
`provider:<id>`/`agent:<id>` values or null, and paths, models, excerpts, identifiers, and credentials
were forbidden. Retention was seven days and 50,000 rows, pruned inside write transactions, with a
permanent `history_truncated` marker; the evaluator read the whole journal for latest-attempt and
latest-success facts and published a `recent_activity` tree of up to 512 attempts. Alongside it,
every authenticated device uploaded a sanitized **Device Health** signal on change or as a 15-minute
heartbeat — schema, client, platform, revision, the three summary axes, one code, consecutive failure
count, and whether Usage upload was enabled — which Relay stored as one replace-in-place row per
device and clients rendered as Healthy, Needs attention, or Not recently active inside a 20-minute
freshness window.

It was replaced because a device asleep is indistinguishable from a device broken, so the health
signal cost a table, a route, a schema, and four renderings to assert something no device could know
— [ADR 0022](./0022-minimal-diagnostics.md) deletes it end to end, keeps the journal as best-effort
evidence at 5,000 rows and seven days, and drops the refresh tree and its truncation marker.
