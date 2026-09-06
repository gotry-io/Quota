# ADR 0032: A period is folded where its days already are, and a budget never leaves the device

- Status: Accepted
- Date: 2026-09-06
- Extends [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md) and
  [ADR 0031](0031-the-usage-fold-is-stored.md)

## Context

Every Usage surface offered exactly four periods — Today, 7 Days, 30 Days, and All — because those
are the four an Account summary folds and the four the local service precomputes on each refresh.
People want the ones a calendar has: this week, last month, the range around an incident. Adding
each as a fifth, sixth, and seventh named period would fold it on every refresh and store it in
every summary, for a question most reads never ask; [ADR 0031](0031-the-usage-fold-is-stored.md)
already had to stop the four from being recomputed per read.

The days behind those periods are, however, already where the question is asked.
`GET /api/v6/account/usage/activity?from&to` answers up to 400 daily totals in one read, and both
the website and Quota iOS hold a year of them the moment their Usage page opens. QuotaBar holds
something better: the hourly facts themselves, in local SQLite.

Separately, an API-equivalent monthly budget is the thing people asked for alongside the periods.
A budget is a number someone chooses to be warned by. It is not an observation, not a reading, and
not something another device of theirs needs to agree about.

## Decision

**A period outside the four is folded by whoever already holds its days, and no new period is
folded for anyone who did not ask.** The website and Quota iOS add the activity days up in the
client. QuotaBar asks the service for one range at a time over the new IPC operation
`usage_period { from, to }` — two inclusive local dates, at most 366 days, folded against stored
hours and the catalogs the device already holds, collecting nothing and reaching no network.
`ipc_version` becomes 2. Relay gains no route and no named period.

The fold is one rule with one statement, `packages/protocol/fixtures/usage-day-fold-conformance.json`:
totals add, cost outcomes add and then reach the verdict one row reaches, two days priced against
different catalog revisions name no revision, and a period is partial exactly when one of its days
is. A day carries no agent tree unless it was asked for on its own, so a folded period carries
totals and cost and says so rather than showing an empty breakdown. On Account, a period the
summary does not carry is answered on This Mac, because the Account read hands a device four folds
and not the days behind them.

**The monthly budget is a device preference and is never uploaded.** One amount in whole US dollars
and one alert switch, in `UserDefaults` on Apple and `localStorage` on the website. Crossing 80%
and then 100% of it fires once each per calendar month, evaluated by `QuotaAlerts` under the same
dedup keys the quota thresholds use with `budget` as the selector and the month as the window, and
stated in `budget_cases` of `packages/protocol/fixtures/alert-transition-conformance.json`.

## Consequences

A period the client folds costs one activity read that had already happened, and a period QuotaBar
folds costs one SQL pass over hours that are already indexed; neither costs D1 a row. A state
change invalidates the folds QuotaBar asked for, because the hours behind them moved.

Client-side folding is a second implementation of an addition Relay also performs, which is why the
conformance fixture exists: three runtimes answer it, so one of them drifting is a test failure
rather than a discrepancy someone notices in a number. The 366-day bound on `usage_period` is the
local mirror of the 400-day bound the activity read already carries; a range wider than a year and
a leap day is refused rather than answered slowly.

Because no managed store names a budget, a budget does not follow someone to a second device, and
signing out does not clear it. That is the cost of not turning a preference into an account fact.
