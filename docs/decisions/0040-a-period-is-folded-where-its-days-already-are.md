# ADR 0040: A period is folded where its days already are, and a budget never leaves the device

- Status: Accepted
- Date: 2026-09-06
- Extends [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md) and
  [ADR 0031](0031-the-usage-fold-is-stored.md)
- Updated 2026-09-19 by [ADR 0055](0055-an-account-period-is-a-local-date-range.md): Relay now
  answers an additive local-date period read. The website reads that route for every Usage
  selection except `all`, and for the budget month. Quota iOS still folds UTC activity days until
  it switches.
- Updated 2026-09-20 (Quota iOS Account): Quota iOS reads that route for every Usage selection
  except `all`, and for the budget month. The UTC-day fold is gone.
- Updated 2026-09-19 (QuotaBar Account): QuotaBar no longer refuses a non-summary period on
  Account. `usage_period` now names `source` (`local` | `account`) and, for Account, the caller's
  IANA timezone; Account answers from Relay's period read. The monthly budget stays this Mac's
  fold. There is no alias for a request that omitted `source`.

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

**A period outside the four is answered by whoever already holds its days, and no new period is
folded for anyone who did not ask.** The website and Quota iOS read Relay's local-date period
route for every Usage selection except `all`, and for the budget month. QuotaBar asks the service
for one range at a time over the IPC operation
`usage_period { from, to, source, timezone }` — two inclusive local dates, at most 366 days.
This Mac folds stored hours and the catalogs the device already holds, collecting nothing and
reaching no network. Account is the Relay period read in
[ADR 0055](0055-an-account-period-is-a-local-date-range.md). `ipc_version` is 3. Relay's period
route is that later amendment; this decision's original "Relay gains no route" sentence does not
describe today's Account path.

The UTC-day fold that used to add activity days in the client is gone. On Account, a period the
summary does not carry is the same Relay local-date read the website and Quota iOS already use;
QuotaBar does not fold UTC activity days. The sentence that QuotaBar refuses the question on
Account is superseded by [ADR 0055](0055-an-account-period-is-a-local-date-range.md) as of
2026-09-19. The sentence that Quota iOS folds UTC activity days is superseded as of 2026-09-20.

**The monthly budget is a device preference and is never uploaded.** One amount in whole US dollars
and one alert switch, in `UserDefaults` on Apple and `localStorage` on the website. Crossing 80%
and then 100% of it fires once each per calendar month, evaluated by `QuotaAlerts` under the same
dedup keys the quota thresholds use with `budget` as the selector and the month as the window, and
stated in `budget_cases` of `packages/protocol/fixtures/alert-transition-conformance.json`.

## Consequences

A period the website or Quota iOS asks is one Relay period read, and a period QuotaBar
folds costs one SQL pass over hours that are already indexed; neither costs D1 a row. A state
change invalidates the folds QuotaBar asked for, because the hours behind them moved.

The 366-day bound on `usage_period` is the local mirror of the 400-day bound the activity read
already carries; a range wider than a year and a leap day is refused rather than answered slowly.

Because no managed store names a budget, a budget does not follow someone to a second device, and
signing out does not clear it. That is the cost of not turning a preference into an account fact.
