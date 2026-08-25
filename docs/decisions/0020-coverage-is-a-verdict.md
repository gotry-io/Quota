# ADR 0020: A read states how completely it was scanned

- Status: accepted
- Date: 2026-08-25

## Decision

A managed read carries one word for coverage — `none`, `complete`, or `partial` — decided in the
database over every window the range spans. It no longer carries the windows themselves, and
`coverage_truncated` no longer exists. Managed data advances to v5 on `/api/v5/*`.

The windows stay in D1 exactly as they are written; only the read changed.

## Why

Every reader in every runtime folded the list to the same question — was anything missed:

- the Rust service to `incomplete`, in `account_usage_detail`
- QuotaBar to `usage.coverage.contains { $0.status == .partial }`
- Quota Web to the word "Complete" or "Partial"

None of them had ever read a window's device, agent, or bounds. This account's summary returned
977 coverage rows — 158KB of the 373KB it sent every five minutes to every device — so that three
clients could each compute one boolean, and the Worker had begun to exceed its CPU limit
(Cloudflare 1102) building them.

Counting the answer in D1 also makes it exact. The row list was paged and could be truncated, so a
partial window past the page boundary was invisible and the read claimed completeness it did not
have.

## Consequences

`fallback_models` goes with it. It rebuilt a model list from display breakdowns when a read
arrived without its per-agent summary, which stopped happening once the service asked for
`usage_agents=all` unconditionally; it has been empty since, and QuotaBar carried a branch to
render it. A field with no reader is the thing [ADR 0019](0019-one-statement-per-contract.md)
forbids.

Local state migration v10 promotes staged uploads to v5 in place and discards the period caches
built from the retired shapes; both are rebuilt by the next refresh.

Coverage may not begin before `EARLIEST_USAGE_INSTANT`, because no agent this Account accepts
existed then. Six windows had reached production this way — 31-day chunks marching forward from
the Unix epoch, claiming a range no device had read, produced by a client computing a span from a
missing lower bound. The bound belongs to the contract rather than to whichever client wrote them,
so every client is held to it. D1 migration 0014 deletes what is already stored.

## Alternatives

**Bound the summary's date range.** It would shrink the response, but the dashboard's activity
chart is a year of daily totals, so the range is what it asks for. That is a real reader; the
coverage rows were not.

**Report a gap in the range as `partial`.** The verdict describes the scanning, not the
calendar, and every consumer read it that way before this change too. A device that was asleep
has no usage to miss, so treating every hour it did not run as incomplete would leave the flag
on for every account forever; a scan that was attempted and came up short already records a
`partial` window, which is what `partial` reports.

**Merge adjacent windows.** The stored windows are never coalesced, so they grow with every
upload — 971 rows over eleven months here. With the read no longer scanning them this is
storage, not latency.

Merging them was designed and rejected. On the upload path it would have to widen the inserted
range inside the same batch that deletes what it absorbs, and that path carries the sequence and
idempotency guarantees the whole outbox rests on. In maintenance it can be written as one
statement, but SQLite does not define the order in which an `UPDATE` sees its own subqueries, so
a chain of touching windows can widen out of order and leave two rows overlapping — coverage
corrupted to save space nothing is short of. Constraining the update to run heads is provably
safe and merges one pair per pass, which converges on a thousand rows in a thousand passes.

Neither is worth its risk against a cost that is now bounded storage, so the windows stay as
they are written.

## Addendum: what a reader is told to do

Three conditions reached the reader as something they could not act on, and are now named:

**A retired contract.** Relay answers anything unmatched under `/api` with
`client_upgrade_required`, which it already defined and never sent. A cutover used to reach an
older build as a resource that was merely missing, so it retried a route that will never return.
The code maps to `ErrorCode::ClientUpgradeRequired` and the recovery `Upgrade`, which QuotaBar
already renders as an update prompt.

**A refused credential store.** A Keychain entry whose secret is withheld is an access decision,
not an expired sign-in, and telling the reader to sign in again rewrites a secret this device
still would not be handed. It reads as `unavailable` to every other device — none of them can
see or change this one's access — and the local collection result carries `access_denied` so the
diagnostic on the device that can act says `check_access`. That marker advances the local
collection contract to v3; managed data is untouched, because there is nothing here for a remote
reader to do.

**An account with nothing to report.** A read that answers `null` for a window it knows is a
successful read of an account with no such window. Only a read that answers for no known window
is a shape this build cannot understand, and only that is a collection failure.

`/api/v5/account/usage/hourly` is deleted. It had no client in any runtime and no test, and its
schema and Swift models went with it.
