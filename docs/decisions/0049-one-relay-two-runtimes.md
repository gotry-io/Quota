# ADR 0049: One Relay, two runtimes

- Status: Accepted
- Date: 2026-09-09
- Extends [ADR 0001](0001-persistent-relay-storage.md) and
  [ADR 0011](0011-sveltekit-document-worker.md)

## Context

[ADR 0001](0001-persistent-relay-storage.md) put Relay's storage in D1, and
[ADR 0011](0011-sveltekit-document-worker.md) put the website's documents through the same Worker.
Both decisions were made against Cloudflare's free tier, and the free tier has since become the
binding constraint rather than the background: D1 allows five million rows read per day, and daily
usage has been above it — around 6.7 million rows a day — since 2026-08-28. The two hot queries
behind that were already narrowed once ([ADR 0031](0031-the-usage-fold-is-stored.md) and the
read-budget fixes of 2026-09-02), and the remaining reads are the product working as designed.

So the choice is to pay Cloudflare for reads that a spare Mac mini already has, or to stop being
unable to run Relay anywhere else. Relay is a Hono app over SQL, a SvelteKit `Server.respond`, and
a cron sweep; nothing in it needs a Cloudflare data centre. What made it Cloudflare-only was that
`D1Database`, `ASSETS`, `caches.default`, and `CF-Connecting-IP` were reached for directly from
business code.

## Decision

**Relay runs on Cloudflare Workers and on Node in Docker, from one source tree, and CI proves
both.** This is not a migration: the Cloudflare path stays deployable, and switching is an
operations decision, not a code change.

- **Five interfaces carry every platform difference**, in `apps/relay/src/platform/`:
  `RelayDatabase` (with `RelayStatement` and `RelayResult`), `StaticFiles`, `LastReadingCache`,
  the migration runner, and `clientAddress()`. Each has a Workers implementation and a Node one.
- **`RelayDatabase` is D1's own shape**, not a neutral abstraction over it:
  `prepare(sql).bind(…).first(column?)/all()/run()`, `batch(statements)`, `exec(sql)`, and a result
  carrying `results`, `success`, `meta.changes`, and `meta.last_row_id`. Cloudflare's `D1Database`
  satisfies it structurally with no adapter. `D1AccountState` and `D1UsageState` take it instead of
  `D1Database`; not one line of their SQL changed, and they keep their names, because what they are
  is the D1 data model, wherever it is stored.
- **The business code only uses the intersection.** A statement that runs on one runtime and not the
  other is a bug in `platform/`, not a case for a branch. `SqliteDatabase` runs a batch inside one
  SQLite transaction so a failure rolls the whole batch back, keeps SQLite's own error text so
  `UNIQUE constraint failed` still means a taken identity, and returns integers as numbers.
- **Both entry points only assemble.** `src/cloudflare.ts` builds the Workers implementations from
  its bindings; `src/node.ts` builds the Node ones from environment variables with the same names,
  applies migrations before it listens, serves the built website's files ahead of the renderer the
  way Cloudflare's Static Assets do, and closes the database on `SIGTERM`. Request handling itself
  lives in `src/deployment.ts` and is shared.
- **The migration ledger is wrangler's.** The Node runner writes the `d1_migrations` table wrangler
  writes, byte for byte, so a database taken out of D1 with `wrangler d1 export` is already migrated
  when it is imported rather than replayed from `0001`.
- **CI runs both.** The Workers tests run in `workerd` against Miniflare's D1; the same state code
  is exercised under Node against an in-memory `SqliteDatabase` applied from the real migration
  ladder.

## Why

The alternative was a paid D1 plan for reads a machine already sitting on a desk can serve. But the
reason to write it down as an architecture decision rather than a cost decision is that the
Cloudflare coupling was never load-bearing and was never examined: four platform globals reached
from four files decided where a whole service could run. Naming them as interfaces costs one
indirection and buys the ability to answer a pricing change, an outage, or a jurisdiction question
by moving, rather than by rewriting.

Keeping D1's shape as the interface — rather than inventing a neutral query API — is what makes the
change small. The SQL is the asset; the runtime is not.

## What was given up

- **A self-hosted Relay is a single point of failure.** The Mac mini is one machine on one home
  connection with one disk. Cloudflare's version has none of those limits, which is why it stays
  deployable rather than being deleted.
- **`caches.default` becomes a process-local Map.** On Workers the last-good provider status
  reading is shared across a colo; on Node it is shared by nothing, so a restart re-polls the four
  status pages. That cache exists to survive a failed poll, not to save requests, so this costs a
  handful of upstream reads.
- **`request.cf` and `waitUntil` are gone on Node.** `App.Platform` now types `ctx`, `caches`, and
  `cf` as possibly absent, so any future use of them has to answer for the runtime that has none.
- **SQLite is one writer.** D1 batches and SQLite transactions both serialize, but a single Node
  process is also the only process; the deployment is one container, not a pool.

## When to revisit

If the self-hosted deployment becomes the only one — then the Workers entry point and its
implementations should be deleted rather than kept warm. Or if a route needs something one runtime
cannot express at all: that is the point at which the intersection stops being the right contract,
and it should be answered by moving the route, not by branching inside it.
