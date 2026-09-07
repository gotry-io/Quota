# ADR 0042: Quota history is local samples

- Status: Accepted
- Date: 2026-09-07
- Extends [ADR 0035](0035-quota-pace-is-derived-from-the-reading.md), and follows
  [ADR 0017](0017-derived-observation-freshness.md),
  [ADR 0021](0021-identity-store-and-disposable-cache.md), and
  [ADR 0039](0039-project-attribution-stays-local.md)

## Context

[ADR 0035](0035-quota-pace-is-derived-from-the-reading.md) answers a window from one reading, and
that is enough to say whether the current rate lasts. It is not enough to draw the thing every
comparable product draws beside its meter — CUStats Go, CodexBar's Usage Monitor and
WhereMyTokens all plot the window's cumulative burn from its start to now, extended to its reset,
and name what each of the day's earlier windows cost. A line needs samples, and one reading is
one point.

The device already takes those readings. What it did not do was remember them.

## Decision

**A sample is one reading of one window, kept by the device that took it, and it never leaves.**

QuotaBar's service writes one row per window per collection into `cache.sqlite`'s `quota_samples`
(`provider`, `window_id`, `resets_at`, `observed_at`, `used_percent`, `remaining`, `limit`,
`value_unit`), keyed on the reading itself. Quota iOS keeps the same journal as a file in its own
Application Support container, beside the last local collection. Neither is uploaded: no
`UsageRow`, no quota envelope, and no managed contract names a sample, and Relay gains no route.
A projection a producer stamped is a projection its readers cannot check
([ADR 0035](0035-quota-pace-is-derived-from-the-reading.md)); a *history* a producer stamped is
worse, because it also asserts what some other device saw. The website and the Account show no
history at all — the cloud daily bucket stays a separate, later decision.

**A refresh that reads the same numbers twice writes one row.** Within one `resets_at`, a reading
identical to the last stored one adds nothing to the curve and is dropped.

**Samples are kept for thirty days.** A month is longer than every window cadence a provider
states — the longest is a week — so it always covers the running window and the ones before it,
and it is long enough to answer "what did last Tuesday look like". Beyond that the rows answer
nothing any surface asks and are only a store to keep intact, so the write that follows the
horizon deletes them. The cache is disposable either way
([ADR 0021](0021-identity-store-and-disposable-cache.md)): a rebuilt image starts the curve again.

**One fold, judged by one file.** `packages/protocol/fixtures/quota-history-conformance.json`
states the rule; `history` in `packages/service` and `QuotaHistory` in `packages/apple-shared`
each answer it, and no third runtime implements it. The fold takes a window, its samples, the
reader's clock, and the reader's offset from UTC, and gives:

- **points** — the samples of the window on screen, as `(elapsed_fraction, used_percent)`, where
  `elapsed_fraction` places the reading between the window's start and its reset. Inside a window
  a provider only spends, so a reading that came back lower keeps the running peak rather than
  dipping the curve. **At most one point per five minutes**: a refresh interval can be one minute
  ([`QUOTA_REFRESH_INTERVALS_SECONDS`](../../packages/service/src/protocol.rs)), and five readings
  a five-hour window's worth of pixels apart say the same thing while costing five times the
  payload. The first sample and the last are always kept, because the last is the point the reader
  is standing on.
- **projection** — ADR 0035's `projected_at_reset` over the last sample, stated at
  `elapsed_fraction` 1. It is the same number the pace phrase prints, so a reader is never shown
  a line and a sentence that disagree, and a window ADR 0035 refuses to project takes no dashed
  line either.
- **windows_today** — the samples grouped by `resets_at`, each with its `started_at`, its peak
  used percent, and whether it is the one running. A group belongs to today when its `resets_at`
  falls on the reader's local date, or when it has not happened yet — a five-hour window opened at
  23:00 is part of the reader's evening whichever date it refills on.

**The holder of the samples folds them.** QuotaBar's service states `history` on the windows of a
reading this Mac collected, in the IPC state it publishes, and states none on a reading Relay
resolved from another device — that reading has no samples here and inventing a curve for it would
draw a line no device ever saw. `ipc_version` becomes 3. Quota iOS folds its own samples the same
way and draws a line only for the reading it took itself.

**What the surfaces show.** QuotaBar's Overview draws a sparkline under each window meter — solid
for the samples, dashed to the reset, 0–100 percent vertically and window start to reset
horizontally — and closes each provider group with `Today: 3 windows · 82% / 40% / 12%`, which
opens into the list. **Settings › Menu Bar › Show pace lines** turns both off and is on by default.
Quota iOS draws the same line in each SubscriptionDetail window block and lists the same day under
a **Today** section.

## Consequences

- A device that has just been installed, or whose cache was rebuilt, shows meters and pace and no
  line until it has collected twice. That is the honest answer: it has one reading.
- Two devices reading one subscription draw different lines, because each drew what it saw. The
  Overview row still names one reading; the history belongs to the source, not to the account.
- Adding a case to the conformance fixture is how the fold changes, and a runtime that cannot
  answer the new case fails in its own test run.
- The upload path, the wire schemas, and Relay are untouched, so this decision cannot regress what
  leaves the machine.
