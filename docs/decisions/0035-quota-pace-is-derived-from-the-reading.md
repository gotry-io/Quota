# ADR 0035: Quota pace is derived from the reading

- Status: Accepted
- Date: 2026-09-05
- Follows [ADR 0017](0017-derived-observation-freshness.md) and
  [ADR 0019](0019-one-statement-per-contract.md)

## Context

Every surface showed how much quota is left and when the window refills, and left the reader to do
the arithmetic that actually decides their afternoon: at this rate, does it last? Comparable
products answer it beside the meter — CodexBar's *Pace: Behind (-42%) · Lasts to reset*, CUStats'
*Pace 46.4% · Healthy*, CodexBar Monitor's *Projected to stay under limit*.

The arithmetic needs no history. A window's `resets_at` and its cadence place the window in time,
and `used_percent` says how much of it is gone; how much of the window is behind the reader turns
that into a rate. Every input is already part of one reading, which is the same property
[ADR 0017](0017-derived-observation-freshness.md) relied on for freshness.

## Decision

**Pace is a pure function of one window and the reader's clock, stated once per runtime and judged
by one fixture.**

The window starts one cadence before it resets. `elapsed` is the fraction of it behind the reader,
clamped to `0…1`. A window with no `resets_at`, no `duration_seconds`, or a balance with no limit to
spend against has no pace at all, and neither does one with less than 5% of itself elapsed or less
than 2% used — a sample that small is noise, not a rate.

Otherwise `projected_at_reset` is `used / elapsed`, capped at 999. That single number decides both
halves of the answer: at or under 100 the window **lasts** to its reset, over 100 it **runs out**
first, and stated as a difference from the even rate it is the tempo — **ahead** above 1.1×,
**behind** below 0.9×, **on track** between. A window that runs out also names the instant it is
spent, `exhausts_at`, stated to the whole second so every runtime names the same one.

The cap is on the projection, and the tempo delta is that same capped projection restated, so a
reader is never shown two different sizes of the same overrun.

**One phrase, three surfaces.** `On track · lasts to reset`, `Ahead +42% · runs out ~2h before
reset`, `Behind −30% · lasts to reset`, where the duration is the shared compact format over
`resets_at − exhausts_at`. The words live in `apps/menubar/DESIGN.md` Shared product vocabulary.

**Each runtime owns one implementation, and `packages/protocol/fixtures/quota-pace-conformance.json`
is the judge all of them answer** — `quotaPace` in `packages/quota-model`, `pace` in
`packages/service`, `QuotaPace` in `packages/apple-shared`, and the copy in
`apps/web/src/lib/format.ts` and `QuotaPaceCopy`.

**Whoever holds the reading derives it, once.** QuotaBar's service states a `pace` object on every
window of the IPC state it publishes, because Rust is the runtime QuotaBar's rules are answered in;
the app prints what it is handed rather than keeping a second rule beside it. Quota iOS and the
website derive their own, because there is no Rust on either. Relay is unchanged: pace is not
stored, not uploaded, and not a wire field of a managed contract — a projection a producer stamped
is a projection its readers cannot check, and it would be wrong the moment the clock moved.

**A window that stops lasting warns once.** `QuotaAlerts` gains a `pace` rule beside thresholds and
reset reminders, on by default, with a switch on both Settings pages. It fires at most once per
window per reset cycle — the dedup key carries the rule that made it — and a reset clears it along
with that window's other keys.

## Consequences

- Pace moves as the clock does, so what a surface shows is as fresh as the state behind it. QuotaBar
  restates every window's pace each time its service publishes state; iOS and the website compute it
  at render.
- `used_percent` is the only meter pace reads, so a balance-only wallet and a window whose provider
  reports no refill instant simply take no line rather than being given an invented one.
- Adding a case to the fixture is how the rule changes. A runtime that cannot answer the new case
  fails in its own test run.
- The alert dedup key gained a rule discriminator, so a stored key names which of the three rules
  fired it rather than inferring it from whether a threshold is present.
