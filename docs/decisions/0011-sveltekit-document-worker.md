# ADR 0011: Quota Web document SSR via SvelteKit on the existing Relay Worker

- Status: Accepted
- Date: 2026-08-14
- Related: [ADR 0006](./0006-managed-account-device-usage.md), [`docs/architecture.md`](../architecture.md), [`docs/security.md`](../security.md), [`apps/web/DESIGN.md`](../../apps/web/DESIGN.md)

## Context

Quota Web shares `https://quota.gotry.io` with QuotaRelay. Browser sessions use HttpOnly, Secure
cookies. A static HTML document cannot read that cookie,
so a signed-out first paint is inevitable if HTML is a build artifact. The rejected alternatives
were a JS-readable session cookie, a second client session store, and HTMLRewriter on Static Assets.

Quota Web is also the long-term browser product surface. New account pages need route-local
loading, layouts, and components rather than one imperative SPA controller. The document process
must be the process that can already read the session cookie: the existing Relay Worker.

## Decision

Render Quota Web documents with SvelteKit on the existing `quota` Worker. Keep Hono, browser
sessions, D1, OAuth, Usage aggregation, and domain policy in Relay.

> Updated 2026-08-26: Better Auth is gone. `getViewer` reads the `quota_session` cookie against
> `account_sessions` directly; the pairing below is unchanged in shape. See
> [ADR 0025](0025-one-session-system.md).

- `apps/relay/wrangler.jsonc` `main` remains `src/cloudflare.ts`. Cron stays on that export.
  Official `@sveltejs/adapter-cloudflare` `main` is generated `_worker.js`, which does not support
  custom `scheduled` handlers (sveltejs/kit#13692). The unofficial wrap is `Server.respond`.
- `/api`, `/api/*`, `/oauth`, `/oauth/*`, `/healthz`, and `/readyz` stay on Hono. Every other
  Worker-first request is a SvelteKit document. Hashed `/_app/immutable/*`, `/schema/*`, and the
  listed static images stay asset-first.
- `apps/web` owns the `WebDocumentPort` type. Relay implements it. SvelteKit `Platform` has no
  `env`, `DB`, or secrets. Document loads may call `getViewer` only.
- `getViewer` is the same pairing as `authorizeAccount`: a cookie of the right shape, then the
  session row, then `getAccount`. It returns `{ displayLabel }` only.
- `/my` Usage, login, logout, and mutations stay on existing HTTP APIs. Document SSR must not run
  Usage aggregation.
- There is no dual SPA + SvelteKit runtime. Rollback is revert on `main` and let
  `deploy-cloudflare.yml` republish.

## Consequences

- First HTML byte of `/`, `/my`, and `/activate` already has the correct header.
  Unsigned `/my` is a server redirect to `/`. `/app` is a server redirect to `/my`.
- `pnpm dev:web` is HMR. `QUOTA_DEV_VIEWER` is a `dev === true` server stub for header QA, not a
  session. Browser GitHub login on localhost remains unavailable because the origin and Secure
  cookies are production-only.
- `apps/web` `check` is `svelte-kit sync && svelte-check` against a tsconfig that extends
  `tsconfig.base.json` then the generated SvelteKit config. The checked-in file does not copy
  root strict flags.
- Default Relay `vitest run` must not import the production Server loader. Integration tests run
  after `build:web`.
- New files under `apps/web/static/` besides `logo.svg`, `logo-monochrome.svg`, `og.png`, and
  `schema/` need a matching Wrangler `!` negation.

## Verified implementation

Pinned toolchain:

- `svelte` `5.56.9`
- `@sveltejs/kit` `2.70.2`
- `@sveltejs/adapter-cloudflare` `7.2.9`
- `@sveltejs/vite-plugin-svelte` `7.3.0`
- `svelte-check` `4.7.6`
- workspace TypeScript `6.0.3` (not installed under `apps/web`)
- `vite` `8.2.0`

Generated output on that toolchain:

- `Server` comes from `apps/web/.svelte-kit/output/server/index.js`.
- `manifest` comes from `apps/web/.svelte-kit/output/server/manifest.js`.
- Wrangler specifier `quota-sveltekit-server` aliases to
  `../web/.svelte-kit/output/server/quota-sveltekit-server.js`, a build-emitted re-export of those
  two symbols.
- `Server.init({ env, read })` is required. `read` returns `ASSETS.fetch(...).body`.
  `Server.respond` does not take `read`. Pass `env: {}` so SvelteKit never sees Worker bindings.
- Client assets stage from `.svelte-kit/cloudflare/` into `apps/web/dist` as `/_app/**` plus copied
  `static/` files. `_worker.js`, `_worker.js.map`, and `_routes.json` are excluded.
- `@cloudflare/vitest-pool-workers` `0.20.3` does not apply Wrangler `alias` to the test import
  graph. Integration tests set `resolve.alias` to the same generated re-export. Unit tests alias
  the specifier to `apps/relay/src/quota-sveltekit-server-stub.ts`.
- Biome 2.5.6 formats `*.svelte`. Svelte lint is off because it treats markup-used bindings as
  unused. TypeScript remains the Svelte typecheck.
- Wrangler dry-run (2026-08-14): `Total Upload: 3006.81 KiB / gzip: 527.85 KiB`, under the 3 MiB
  gzip stop-line used until the `quota` account is confirmed Paid.

## Security boundary

Session cookies stay HttpOnly. JavaScript never reads them. Display labels are text, never
`{@html}`. Every `Server.respond` result, including `__data.json`, is `Cache-Control: private,
no-store` with `ETag` stripped. `document_ssr` / `document_ssr_failed` logs may contain only
`path`, `status`, and `has_viewer`. They must not contain cookies, account ids, display labels, or
secrets. `getViewer` is memoized once per document request. A thrown render returns generic 500
HTML with the same cache headers.

## Alternatives considered

- Thin Hono HTML templates: smallest wrap, but not the chosen document layer.
- Generated `_worker.js` as Wrangler `main`: official adapter layout, but loses `scheduled` and
  inverts the web/Relay source boundary.
- HTMLRewriter on static HTML: rejected as architecture; cannot own `/my` redirects or grow pages.
- `adapter-static`: same first-paint session bug.
- Second Worker: forbidden by the single-hostname deploy topology.
- JS-readable session cookie or `localStorage` session: forbidden by the security baseline.

## Remaining risks

- The `Server.respond` wrap is unofficial. A future adapter that supports `scheduled` can replace
  the wrap without changing `WebDocumentPort`.
- `/*` Worker-first spends SvelteKit CPU on unknown paths that Static Assets previously served.
  Those paths must not touch D1 when no session cookie is present.
- Local Wrangler is not a browser GitHub login. Header QA uses `QUOTA_DEV_VIEWER` under `vite dev`.
