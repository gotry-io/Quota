# ADR 0022: Minimal diagnostics

- Status: Accepted
- Date: 2026-08-25

## Context

[ADR 0008](0008-data-integrity-and-diagnostics.md) gave the diagnostic report four surfaces, 128
checks, 256 findings, three summary axes, and a bounded metric map on nearly every row.
[ADR 0015](0015-diagnostic-attempts-and-device-health.md) added a refresh tree of recent attempts on
top of it, and a Device Health signal each device uploaded about itself.

One failed Claude collection was therefore reported seven times: as a check, as a finding, as an
impact, as a severity, as an occurrence count, as a recovery verb, and again inside the refresh
tree. None of those carried the sentence a person reads. That sentence lived in QuotaBar, in a
switch over finding codes, so QuotaCLI printed `auth_required` where QuotaBar printed English and a
new code meant editing two clients.

## Decision

`diagnose` returns `schema_version: 3`: `generated_at`, `client`, `summary{operation, attention}`,
four fixed `surfaces[]`, `sources[]`, and up to 100 `recent[]` attempts.

A surface says `status`, `data`, `last_success_at`, one `message`, and one `recovery`. A source is
one place a surface's data comes from — a provider on this Mac, a Usage agent, the account, the
upload path, the pricing catalog, this device's own local state — and says the same, plus `subject`,
`source_id`, and one `code`.

The service writes every message. Clients render it. `checks`, `findings`, `impact`, `mode`,
`occurrences`, `history_truncated`, the refresh tree, and `data = unknown` are gone; `generated_at`
is now when the evaluation happened, which is the only thing a recheck ever needed.

The attempt journal is evidence about collection, not a permit to collect. A journal write that
fails is counted on stderr; the scan, upload, or sync it was recording runs anyway. Retention runs at
open and hourly rather than inside every insert, at 5,000 rows and seven days.

Device Health is deleted end to end: the local publisher, the `PUT /api/v5/device/health` route, the
D1 table, and every client type. Relay already witnesses when a device last called and when the
newest reading it sent was taken, so an Account device list says **Active** under 30 minutes,
**Idle** up to a day, and **Not reporting** beyond that. No device asserts anything about another.

QuotaBar's Diagnostics page becomes Support: the surfaces, the sources, Copy report, and Reset local
data.

## What was given up

Metrics are gone from the wire. "128 records across 4 files, 0 partial hours" is now one sentence
the service writes rather than a map the client formats, so a client cannot compose a count the
service did not intend.

Recent attempts are no longer a tree and no longer shown on screen. They stay in the copied report,
flat and newest-last, which is what a support conversation actually reads.

A device can no longer tell the account it is unhealthy. A sleeping Mac was never distinguishable
from a broken one anyway, and the freshness window that pretended otherwise cost a table, a route, a
schema, and four client renderings.
