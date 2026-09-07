# ADR 0044: Relay publishes official provider status

- Status: Accepted
- Date: 2026-09-07
- Extends the Service status section of [`provider-collection.md`](../provider-collection.md)

## Context

QuotaBar and Quota iOS poll Atlassian Statuspage v2 feeds themselves. The website has no local
helper and no phone, so Overview could not draw the same incident mark. Catalog
`status_page.kind = statuspage_v2` already names the URLs; the missing piece was a public read
that does not name an Account.

## Decision

**Relay answers `GET /api/v2/providers/status` with no principal and no cookie.** The body is
`{ providers: [{ id, indicator, description, checked_at }] }`, one row per catalog provider that
declares `statuspage_v2`, in catalog order. `indicator` is Statuspage's `none` / `minor` /
`major` / `critical`, or `unknown` when a poll failed and Relay has no last reading.

The Worker fetches those URLs with a five-second timeout and a 64 KiB body cap, stores a last-good
reading in `caches.default` for ten minutes, and on failure keeps that reading rather than
guessing. The request carries `User-Agent: QuotaRelay` and no credential. A parse that is not
exactly `status.indicator` plus `status.description` is a failed poll.

Website Overview draws the same 6 pt circle QuotaBar does — minor and above, `title` set to the
description. A public profile page does not: it publishes Usage, not quota, and not whether a
vendor is having a bad day.

## Why

Status pages are public JSON about the vendor, not about an Account. Putting them on a sessioned
read would make the website pretend an incident is private data. Polling from each browser would
amplify four vendor endpoints by every open Overview tab. One Worker cache is the same last-good
rule the helper already uses, at the one place a website can keep it.

## Consequences

- Adding a catalog `statuspage_v2` row is what adds a provider to this read. There is no second
  URL table.
- A failed poll is silent: the last reading, or `unknown`. The route does not 5xx because a
  vendor's status page is down.
- QuotaBar and iOS keep polling on the device. This read is for surfaces that cannot.
