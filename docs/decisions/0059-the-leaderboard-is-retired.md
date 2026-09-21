# ADR 0059: The leaderboard is retired

- Status: Accepted
- Date: 2026-09-21
- Supersedes [ADR 0045](0045-the-leaderboard-is-a-page-you-opt-into.md)
- Updates [ADR 0037](0037-a-public-profile-shows-usage-not-quota.md), whose public page remains
- Updates [ADR 0051](0051-the-panel-glances-and-the-windows-explain.md), whose website no longer
  keeps a board

## Context

[ADR 0045](0045-the-leaderboard-is-a-page-you-opt-into.md) put an opt-in board at
`quota.gotry.io/leaderboard`, ranked by tokens over the last 30 UTC days. It already named the
reason [ADR 0037](0037-a-public-profile-shows-usage-not-quota.md) had refused a board: ranking
turns Usage into a score, and a score is a reason to inflate what is uploaded. Opt-in did not
remove that reason. It only applied it to people who asked. Nothing in the product can resist
inflated uploads: Usage is what a device says it saw.

The board also rewards burning the resource the product exists to conserve.

## Decision

**The leaderboard is cut.** There is no page, no API, no opt-in, and no rank.

- **Public profiles stay.** `quota.gotry.io/u/<handle>` is unchanged
  ([ADR 0037](0037-a-public-profile-shows-usage-not-quota.md)). Frozen: no new work, no promotion.
- **`/leaderboard` is an unknown route.** Unknown documents already answer 404 with the site's
  ordinary not-found page, so the retired path does the same. `GET /api/v6/public/leaderboard`
  is gone and answers 404 like any other missing API path.
- **The store drops what only the board used.** `public_profiles.on_leaderboard` and
  `public_profiles_on_leaderboard` are removed. A person who had opted in simply stops appearing
  anywhere; their public page setting is untouched.
- **`leaderboard` stays a reserved handle.** The path is still a route of the site's own, even
  as a 404, so it is not a name a published page may take.

## Consequences

- Ranking is no longer a product surface, so it is no longer a reason to inflate an upload for
  a place on a board.
- The website's anonymous account data is one cacheable answer again:
  `GET /api/v6/public/<handle>/usage`.
- Clients that never decoded a board field are unaffected. The public-profile write drops
  `on_leaderboard` in the same change as the website form that sent it.

## What was given up

A board nobody is on until they ask, which is what ADR 0045 bought. Discovery of published pages
is a shared link again, not an order.
