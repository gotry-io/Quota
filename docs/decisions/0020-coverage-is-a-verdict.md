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

**Merge adjacent windows on write.** The stored windows are never coalesced, so they grow with
every upload — 971 rows over eleven months here. With the read no longer scanning them this is
storage, not latency, and the upload path carries the sequence and idempotency guarantees that
make a rewrite there expensive to get right. Left as it is, deliberately.
