# ADR 0037: A public profile shows Usage, not quota

- Status: Accepted
- Date: 2026-09-06
- Amends [ADR 0011](./0011-sveltekit-document-worker.md) for one route

## Context

People want to show what they run their coding agents on. Every number Quota holds that is worth
showing is also next to numbers that are nobody's business: how much of a plan is left, which
providers a person is signed in to, how many Macs they have, and the label on the account.

Relay used to carry a public profile as two columns on `accounts` — `public_profile_enabled` and
`public_profile_slug` — and
[`0015_drop_public_profiles.sql`](../../apps/relay/migrations/0015_drop_public_profiles.sql)
removed them, because they were the only account data Relay would publish without authentication
and nothing read them. The lesson in that migration is not that a public page is wrong; it is that
"what is public" cannot be a pair of columns on the table everything else lives on, where the next
field added is public by proximity.

## Decision

An Account may publish one read-only page of Usage totals at `quota.gotry.io/u/<handle>`. There is
no ranking, no leaderboard, and no comparison between accounts.

- **What is public is a table, not a field list.** `public_profiles` holds `account_id`, `handle`,
  `enabled`, `show_models`, `show_cost`, and the two instants. Nothing is published because it
  happens to sit beside something that is.
- **What the page carries is its own contract.** `PublicUsageResponseSchema` states it exactly:
  tokens, messages, an optional cost, provider and model shares, and a year of heatmap intensity.
  It is a separate statement rather than a narrowing of `UsagePeriodSchema`, because a narrowing is
  a field list somebody widens later. There is no agent name, device, account label, subscription,
  or remaining quota anywhere in the shape, so a public page cannot grow one by accident.
- **The heatmap carries a band, not a count.** A public cell is 0–4 against the busiest day of the
  same year. The shape of a year is the point; a day-by-day token series is not.
- **The handle is the whole address.** `^[a-z0-9][a-z0-9-]{2,29}$`, lowercase because a URL that
  differs only in case is the same page to a reader, unique without regard to case in the store,
  and refused when reserved. Turning a page off keeps the handle: releasing it would hand every
  link already shared to whoever claimed it next. Deleting the Account deletes the row.
- **A malformed, unclaimed, and disabled handle are one 404.** Telling them apart would make the
  route a way to ask whether a person has a Quota Account.
- **This answer is cacheable, and it is the only one that is.** `GET /api/v6/public/<handle>/usage`
  is `public, max-age=300` with an `ETag` over the same aggregates the signed-in reads validate
  from. [ADR 0011](./0011-sveltekit-document-worker.md) makes every *document* and every
  session-bearing read `private, no-store`, and that stands: those answers differ per viewer.
  This one does not — it is the same bytes for everyone who asks — which is exactly what `public`
  means. Rendering the document still carries the account's own `private, no-store`, so the
  cacheable artifact is the API answer rather than the HTML.
- **A document load may now ask the port for one more thing.** `WebDocumentPort` gains
  `readPublicProfile(handle)`, and `/u/<handle>` is server-rendered from it. ADR 0011 restricted a
  document load to `getViewer`; that restriction existed so a document could not reach account
  data belonging to whoever was reading it, and a page addressed entirely by its handle is not
  that. SvelteKit still receives no `env`, no `DB`, and no secret.
- **Writing it is a browser mutation.** `PUT /api/v2/account/profile` needs `account:manage` and
  the same exact same-origin check every other web mutation takes, and is rate limited per
  Account. It is not a destructive action, so it does not require a recently authenticated
  session. A handle another Account holds is `409 conflict`, because nothing about the request was
  wrong.
- **The share card is drawn in the page.** One 1200×630 canvas, one style, saved from the reader's
  own browser. A server-side renderer would be a second place the same numbers are laid out and a
  new thing to keep in step with the page.

## Consequences

- A published page costs one `usage_daily` read per uncached request, bounded to 730 days and
  answered 304 from a validator computed before that read runs, so a shared link that is followed
  repeatedly does not repeat the scan (see
  [ADR 0031](./0031-the-usage-fold-is-stored.md) for the same concern on the signed-in read).
- Both periods and the heatmap are UTC. `tz` is a question only a session's own client can be
  asked, and an anonymous reader names no calendar.
- `show_models` and `show_cost` are additive switches over a page that always carries totals and
  the provider split. Cost defaults off: it is the one figure a person may not want beside their
  name.

## What was given up

A leaderboard is the obvious next thing and is deliberately absent: it would make the page's
numbers into a score, and a score is a reason to inflate what is uploaded. Publishing remaining
quota was never on the table — it says what a person is paying for and how close they are to
running out. Reusing `AccountUsageSchema` with fields stripped at the route would have been less
code and would have made every future field on that schema public until someone remembered to
strip it. A server-rendered share image would give link previews a picture, at the cost of a
second renderer; the page's Open Graph tags carry the summary sentence instead.
