# ADR 0056: A period export is the period on screen

- Status: Accepted
- Date: 2026-09-20
- Extends [ADR 0055](0055-an-account-period-is-a-local-date-range.md)

## Context

[ADR 0055](0055-an-account-period-is-a-local-date-range.md) made a Usage period a range of inclusive
local dates in a required IANA timezone. The website and QuotaBar already draw that period: the same
days, the same zone, the same API-equivalent cost. There was no way to take that body off the
screen. A file someone opens in a spreadsheet or a script should not be a second fold, and it must
not carry what stays local by policy — prompts, paths, projects, sessions, or provider secrets.

## Decision

**Exporting a period writes the period the page already shows.** The website builds the file in the
browser from the Account period body it loaded. QuotaBar builds it from the Usage detail already on
the Usage page (This Mac or Account). Neither asks Relay or the helper for a second shape. iOS is
out of this change.

**CSV is one row per local date** in the asked `[from, to]`, oldest first. Columns: date, total
tokens, input, output, cache read, cache write, reasoning, messages, API-equivalent cost, cost
status. **JSON is the same days plus a header**: scope (`Account` / `This Mac`), from, to, timezone,
bounds, cost basis (`API-equivalent`), coverage (`partial`, `truncated_by_retention`), revision,
`exported_at`, `app_version`.

**Missing ≠ zero.** A local date with no stored hour is an empty CSV row marked `no usage recorded`
in the cost-status cell, and is absent from JSON `days`. Unpriced cost is an empty CSV cell and JSON
`null` with status `unpriced`, never `0`. Partial cost keeps the priced amount and status `partial`.
Cost amounts are dollars (`amount_microusd / 1_000_000`), exact, not rounded to cents.

**Formula-safe CSV.** Any text cell that starts with `=`, `+`, `-`, `@`, tab, or CR is prefixed with
a single quote; numbers stay plain; fields follow RFC 4180 quoting. The filename is
`quota-usage-<from>-<to>.csv` or `.json`.

**All is exportable only when it has `days[]`.** The website's All is the summary's 730 UTC-day
window and has no daily table, so Export is off there. QuotaBar All is the same. A period whose
detail omitted `days` (not an empty list — the All shape) is not a daily export.

**Nothing local by policy leaves the device.** The file is totals and daily aggregates already on
screen. Projects, sessions, paths, and prompts stay on This Mac.

The shared statement is `packages/protocol/fixtures/usage-export-conformance.json`. The website and
QuotaBar each answer it.

## Consequences

The website grows an Export menu on Usage. QuotaBar grows File › Export Usage… and an Export button
on the Usage toolbar, both an `NSSavePanel` for CSV / JSON. The helper's `usage_period` detail
already carries `days` and Account `coverage`; it also passes through `timezone`, `bounds`, and
`revision` when it has them so the JSON header can name the same bounds and revision the period
read used. A cached four-period snapshot that never carried those fields still exports: the app
fills timezone from this Mac's IANA zone and leaves bounds and revision empty. Quota iOS does not
export yet.
