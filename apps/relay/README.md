# QuotaRelay

QuotaRelay has two supported persistent runtimes:

- A Cloudflare Worker with Static Assets + D1 for the managed service at
  [quota.gotry.io](https://quota.gotry.io).
- Bun + SQLite for user self-hosting.

There is intentionally no stateless production mode. Both runtimes implement the same
`@gotry-io/relay-core` state contract and expose the same discovery document.

## Cloudflare development

The managed Worker and its D1 database are both named `quota`. The Worker serves the public site
from `apps/web/dist`, routes Relay endpoints through the Hono application, and binds the database
as `DB`.

Create the D1 database and replace the placeholder `database_id` in `wrangler.jsonc`:

```bash
pnpm exec wrangler d1 create quota
```

For local Cloudflare development, apply the local migration and start the Worker. The development
command builds the website before starting Wrangler:

```bash
pnpm d1:migrate:local
pnpm dev
```

For the first production deployment, apply the remote migration before deploying the Worker and
its website together:

```bash
pnpm d1:migrate:remote
pnpm deploy:cloudflare
```

The `quota.gotry.io` Custom Domain is declared in `wrangler.jsonc`; Cloudflare manages its DNS
record and certificate during deployment.

## Self-hosted development

```bash
pnpm dev:self-hosted
```

The SQLite database defaults to `./data/quota-relay.db`. Set `QUOTA_RELAY_DATABASE_PATH` to move
it. Provider credentials must never be stored in this database.

The current Relay exposes health, readiness, and discovery only, so discovery intentionally
advertises no authentication or snapshot capabilities. Those flags are enabled only with their
authenticated HTTP endpoints. Realtime WebSocket routing and Durable Objects are not part of v1.
