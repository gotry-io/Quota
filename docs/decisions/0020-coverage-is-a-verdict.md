# ADR 0020: A read states how completely it was scanned

- Status: Superseded by [ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md) on 2026-08-26
- Date: 2026-08-25

A managed read carried one word for coverage — `none`, `complete`, or `partial` — decided in D1 over
every window the range spanned, instead of the windows themselves; `coverage_truncated` and
`fallback_models` went with them, and managed data advanced to v5. The windows stayed in D1 exactly
as written. Every reader in every runtime had been folding the list to that same boolean without ever
looking at a window's device, agent, or bounds, and one account's summary returned 977 coverage rows
— 158 KB of the 373 KB it sent every five minutes to every device — until the Worker began exceeding
its CPU limit building them. Counting in D1 also made the answer exact, because a paged row list
could truncate a partial window out of sight. Coverage was forbidden to begin before
`EARLIEST_USAGE_INSTANT`, since no agent the Account accepts existed then. Merging adjacent windows
was designed and rejected: on the upload path it would have to widen a range inside the batch that
deletes what it absorbs, and in maintenance SQLite leaves the order of an `UPDATE`'s own subqueries
undefined, so a chain of touching windows can widen out of order and overlap.

Three rules from its addendum survive it. A path naming an API version this deployment does not serve
answers `client_upgrade_required`, and the rule is the version rather than the prefix, so a routing
mistake of our own cannot hide behind an upgrade prompt. A credential store that withholds a secret
is an access decision, not an expired sign-in: it reads as `unavailable` to every other device and
carries `access_denied` locally so the diagnostic on the device that can act says `check_access`. And
a read that answers `null` for a window it knows is a successful read of an account with nothing in
that window; only an answer for no known window is a shape the build cannot understand.

It was replaced because an hour carrying the version of the scan behind it says the same thing
without a window: [ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md) moves `partial` onto
the hour it describes and deletes coverage storage entirely.
