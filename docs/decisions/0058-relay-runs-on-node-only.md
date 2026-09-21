# ADR 0058: Relay runs on Node only

- Status: Accepted
- Date: 2026-09-21
- Completes [ADR 0050](0050-the-worker-and-d1-are-retired.md)
- Supersedes [ADR 0049](0049-one-relay-two-runtimes.md) where that record required both
  runtimes in source and in CI

## Context

[ADR 0049](0049-one-relay-two-runtimes.md) gave Relay a Node + SQLite runtime beside Cloudflare
Workers + D1 so production could leave the free D1 tier. Production moved to that Node runtime
on the dmit VPS on 2026-09-14, and [ADR 0050](0050-the-worker-and-d1-are-retired.md) deleted the
deployed Worker and its D1 database the same day.

The Workers path stayed in the source as a test and build target: `test:workers`,
`test:workers:integration`, and a Wrangler dry-run on every `verify-web` run. Nothing deploys
it. That pool costs CI time and stability — a workerd timeout failed a release pull request on
2026-09-20 — and corresponds to no deployment. [ADR 0049](0049-one-relay-two-runtimes.md)
already named this revisit: once the self-hosted deployment is the only one, delete the Workers
entry rather than keep it warm.

## Decision

**QuotaRelay runs on Node over SQLite only.** The Workers runtime is removed from the source:
`src/cloudflare.ts`, `wrangler.jsonc`, the Workers Vitest pool, Wrangler, `@cloudflare/workers-types`,
and `@cloudflare/vitest-pool-workers`. CI builds the website and the Node bundle and runs the
Node suites, including `test:node:integration` after that build. There is no Wrangler dry-run
and no workerd job.

The database interface stays D1's shape. `RelayDatabase`, `D1AccountState`, `D1UsageState`, and
the `d1_migrations` ledger table keep their names; `SqliteDatabase` is what implements them.
`apps/relay/migrations/` stays; Node applies it on start. Cloudflare remains the CDN and DNS
proxy in front of the origin: production still reads `CF-Connecting-IP` from a trusted peer.

Document SSR is unchanged in kind: SvelteKit `Server.respond` still runs inside Relay, now
only the Node process ([ADR 0011](0011-sveltekit-document-worker.md)). The website build still
uses `@sveltejs/adapter-cloudflare` to produce that `Server` and the client assets Node serves
from disk; that adapter is a SvelteKit build step, not a Relay runtime.

## Consequences

- A contract that only the Workers pool used to prove is either already on the Node suite or
  is deleted with the runtime it described (Workers forwarded-trust, Miniflare bindings,
  `waitUntil`).
- Rolling production back to Cloudflare is still a new deployment from a SQLite dump, as
  [ADR 0050](0050-the-worker-and-d1-are-retired.md) said; this change removes the leftover
  source that could have made that look like a switch.
- Client releases are unaffected: origin, OAuth callbacks, cookies, and the data contract do
  not change.
