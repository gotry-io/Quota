# ADR 0045: The leaderboard is a page you opt into

- Status: Accepted
- Date: 2026-09-07
- Amends [ADR 0037](./0037-a-public-profile-shows-usage-not-quota.md), which ruled a leaderboard out

## Context

[ADR 0037](./0037-a-public-profile-shows-usage-not-quota.md) built the public page and then said
what it would not become: "A leaderboard is the obvious next thing and is deliberately absent: it
would make the page's numbers into a score, and a score is a reason to inflate what is uploaded."

That reason has not gone away, and neither has the thing it was weighed against: people publish
these pages to be read, and a board is how a page is found by someone who was not sent a link.
What the earlier record actually refused was a board every published page is on. The two are not
the same decision, and this one revisits only the second.

## Decision

An Account may put its published page on one board at `quota.gotry.io/leaderboard`, ranked by
tokens over the last 30 UTC days.

- **Nobody is on it until they say so.** `public_profiles` gains `on_leaderboard`, default `0`.
  Publishing a page does not list it, and the two switches are asked separately in Settings
  because they are separate questions: one is "may this be read", the other is "may this be
  compared". A page that is not published cannot be listed at all — the contract refuses the
  combination and the read gates on `enabled` as well, so taking a page down takes it off the
  board without a second action, and switching only the listing off leaves the page reachable by
  its handle while it appears nowhere.
- **A place carries less than a page does.** `LeaderboardResponseSchema` is a handle, tokens,
  messages, and a rank. There is no cost, no model, no provider, no agent, and no device in the
  shape — not because those are secret on a page that already shows them, but because a board is
  read by people who followed no link and asked for nobody in particular, and each of them is one
  click from the page that does show them. The 30-day totals are the same fold `/u/<handle>`
  prints, so a handle's place and its own page cannot disagree.
- **The board is one query, not a hundred.** `GET /api/v6/public/leaderboard` groups
  `usage_daily` over every listed profile in a single statement and takes the top hundred. Folding
  it profile by profile would be a hundred rollup scans for one answer that is the same bytes for
  every reader (see [ADR 0031](./0031-the-usage-fold-is-stored.md) for the same concern on the
  signed-in read).
- **It is the second cacheable answer, for the same reason as the first.** `public, max-age=300`
  with an `ETag` computed before the rollup is read, from the listed set and the summed upload
  revision of the devices behind it. A page joining, leaving, or renaming moves it; so does any
  listed Account's next upload; so does the UTC day. ADR 0037 made a public page cacheable because
  its answer does not differ per viewer, and this one does not either.
- **`period` names the only window there is.** `30d`. A board with periods is a board that invites
  a person to find the one they lead.
- **The page is server-rendered, and the one thing that differs per reader is which row is theirs.**
  `WebDocumentPort` gains `readLeaderboard(headers)`, which answers the board plus the reader's own
  handle. A signed-out reader gets the board and no handle. The document still carries
  `private, no-store` as [ADR 0011](./0011-sveltekit-document-worker.md) requires, so the cacheable
  artifact is the API answer rather than the HTML — exactly as it is for `/u/<handle>`.

## Consequences

- Ranking creates a reason to inflate what is uploaded. Nothing here defends against that, and
  nothing can: Usage is what a device says it saw. What the opt-in buys is that the reason applies
  only to people who asked for it, and that the board can be left without taking a page down.
- `leaderboard` becomes a reserved handle, because it is now a route of the site's own.
- The board holds a hundred places. There is no page two: a rank nobody is scrolling to is a number
  without a reader, and paging it would turn one cacheable answer into a hundred.

## What was given up

Ranking by cost, or by any figure a person can choose to publish or not, would make the board's
order depend on a switch rather than on what was run. A board of everyone published, which is what
ADR 0037 refused, is still refused. A per-viewer board — your friends, your team — needs a graph
this product does not have and would end the one property that makes the answer cheap.
