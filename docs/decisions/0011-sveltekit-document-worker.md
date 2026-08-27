# ADR 0011: Quota Web document SSR via SvelteKit on the existing Relay Worker

- Status: Accepted
- Date: 2026-08-14
- Updated 2026-08-26 by [ADR 0025](./0025-one-session-system.md)

## Context

Quota Web shares `https://quota.gotry.io` with QuotaRelay, and a browser session is an HttpOnly,
Secure cookie no static document can read — so a signed-out first paint is inevitable if HTML is a
build artifact. The process that renders the document has to be the one that can already read that
cookie: the existing Relay Worker.

## Decision

Render Quota Web documents with SvelteKit on the existing `quota` Worker, and keep Hono, sessions,
D1, OAuth, Usage aggregation, and domain policy in Relay.

- `apps/relay/wrangler.jsonc` `main` stays `src/cloudflare.ts`, so cron keeps its export. The
  official `@sveltejs/adapter-cloudflare` generates `_worker.js` as `main`, which cannot carry a
  custom `scheduled` handler (sveltejs/kit#13692); the unofficial wrap is `Server.respond`, whose
  generated `Server` and `manifest` are re-exported through the `quota-sveltekit-server` specifier.
- `/api`, `/oauth`, `/healthz`, and `/readyz` stay on Hono. Every other Worker-first request is a
  SvelteKit document. Hashed `/_app/immutable/*`, `/schema/*`, and the listed static images stay
  asset-first, so a new file under `apps/web/static/` needs a matching Wrangler `!` negation.
- `apps/web` owns the `WebDocumentPort` type and Relay implements it. SvelteKit's `Platform` carries
  no `env`, `DB`, or secrets, and a document load may call `getViewer` only.
- `getViewer` is the same pairing as `authorizeAccount` — a cookie of the right shape, then the
  `account_sessions` row, then `getAccount` ([ADR 0025](./0025-one-session-system.md)) — and returns
  `{ displayLabel }` and nothing else. It is memoized once per document request.
- `/my` Usage, sign-in, sign-out, and every mutation stay on the HTTP APIs; document SSR never runs
  Usage aggregation. There is no dual SPA + SvelteKit runtime, and rollback is a revert on `main`.

Session cookies stay HttpOnly, display labels are text rather than `{@html}`, and every
`Server.respond` result including `__data.json` is `Cache-Control: private, no-store` with `ETag`
stripped — a thrown render included. `document_ssr` logs carry `path`, `status`, `has_viewer`.

## Consequences

- The first HTML byte of `/`, `/my`, and `/activate` already carries the right header. Unsigned `/my`
  is a server redirect to `/`, and `/app` redirects to `/my`.
- `pnpm dev:web` is HMR, and `QUOTA_DEV_VIEWER` is a `dev === true` header stub rather than a
  session; browser GitHub sign-in on localhost stays unavailable because the origin and the Secure
  cookie are production-only.
- Default Relay `vitest run` must not import the production `Server` loader — integration tests run
  after `build:web` and alias the generated re-export, unit tests alias a stub — because
  `@cloudflare/vitest-pool-workers` does not apply Wrangler `alias` to the test import graph.
- `/*` Worker-first spends SvelteKit CPU on unknown paths Static Assets used to serve; those must not
  touch D1 with no session cookie present.
- The `Server.respond` wrap is unofficial; an adapter supporting `scheduled` replaces it without
  changing `WebDocumentPort`.

## What was given up

Thin Hono HTML templates would have been the smallest wrap but not a document layer that can grow
account pages. The generated `_worker.js` as Wrangler `main` is the official layout, but it loses
`scheduled` and inverts the web/Relay source boundary. HTMLRewriter over static HTML cannot own
`/my`'s redirect, and `adapter-static` reproduces the first-paint bug. A second Worker is forbidden
by the single-hostname deploy topology; a JS-readable cookie, by
[`docs/security.md`](../security.md).
