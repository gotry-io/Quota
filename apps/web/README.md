# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a SvelteKit app kept separate from the Relay source boundary. The managed `quota`
Worker renders documents through SvelteKit `Server.respond` and publishes hashed `/_app` assets
from `dist/` through Cloudflare Workers Static Assets. Production builds also publish canonical
protocol files from `packages/protocol/schema` under `/schema/`; the website does not keep a
duplicate source copy.

SvelteKit owns documents, routes, components, and the document-scoped viewer. Relay owns sessions,
OAuth, APIs, D1, Usage aggregation, and domain policy. The only join is `WebDocumentPort`.
See [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).

Managed production publishes through the Relay deploy path (`pnpm deploy:cloudflare` / CI workflow
`deploy-cloudflare.yml`). There is no separate website-only Cloudflare project: website and Relay
API ship together on `quota.gotry.io`.

## Development

```bash
pnpm dev:web
QUOTA_DEV_VIEWER=octocat pnpm dev:web   # signed-in header QA only; Usage APIs still 401
pnpm --filter @gotry-io/quota-web check
pnpm --filter @gotry-io/quota-web test          # existing node:test files, then Vitest
pnpm --filter @gotry-io/quota-web test:unit     # Vitest component tests (src/**/*.test.ts)
pnpm --filter @gotry-io/quota-web test:e2e      # Playwright smoke and axe against vite dev
pnpm --filter @gotry-io/quota-web build
```

`pnpm dev:web` is fast HMR and is not a real GitHub login. `pnpm dev:relay` is the composed
Worker. Browser GitHub login on localhost is not available.

`test` keeps the existing `node --test` files and then runs Vitest. `test:unit` is Vitest
alone. `test:e2e` starts `vite dev` with `QUOTA_DEV_VIEWER=octocat` so `/my` is a signed-in shell;
Usage APIs still 401, so the smoke fulfills `/api/v6` in the browser rather than through a service
worker. Install Chromium with
`pnpm --filter @gotry-io/quota-web exec playwright install chromium`.

`/my` is the GitHub-backed account dashboard. It is a signed-in shell with four routes: `/my`
(overview), `/my/usage`, `/my/devices`, and `/my/settings`. Unsigned visits to any of them are a
server redirect home. Every page requires a session; Quota Web publishes no account data
anonymously. `/app` shipped in 0.0.4, so it and anything under it stay a redirect to `/my`; new
links and OAuth callbacks name `/my` directly. Subscription cards on overview link to
`/my/subscriptions/<sel>`; that detail page is not in this package yet.
Sign-in is a plain navigation to Relay's `/api/auth/github/start`, not a fetch: the header button is
a link, and a signed-out visitor returns to the page they asked for. Sign-out posts to
`/api/auth/logout` and Delete Account is `DELETE /api/v2/account`. Those routes and Device deletion
all require an exact same-origin request, and the destructive ones a session authenticated within
ten minutes.

The document for `/my` is a signed-in shell and carries no Account data. The read that fills it is
bounded by the caller's calendar — a local day begins at local midnight, which is what decides where
the trailing windows start and end — and a document request has no clock, so rendering one on the
server would answer in UTC and be thrown away by every browser keeping another calendar. The client
makes it once, sending its own IANA timezone as `tz`.

It then renders what Relay resolved: `subscriptions[]` as one card per subscription, whichever of
Today, the last 7 days, the last 30 days, or all time is selected, and a year of daily totals from
`GET /api/v6/account/usage/activity`, on UTC dates. All time is the last 730 days. Each Device shows
its platform, when it was last seen, and when its newest reading was taken, labelled Active, Idle,
or Not reporting from the newer of the two. It is read-only, and a quiet Device is asleep or closed
rather than broken.

New files under `static/` other than `logo.svg`, `logo-monochrome.svg`, `og.png`, and `schema/`
need a matching `!/filename` negation in `apps/relay/wrangler.jsonc`.

The site follows [`DESIGN.md`](./DESIGN.md) in this package. QuotaBar has a separate design system at
[`apps/menubar/DESIGN.md`](../menubar/DESIGN.md).
