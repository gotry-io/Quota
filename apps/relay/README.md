# QuotaRelay

QuotaRelay has two supported persistent runtimes:

- Cloudflare Workers + D1 for the managed service at
  [quota.gotry.io](https://quota.gotry.io).
- Bun + SQLite for user self-hosting.

There is intentionally no stateless production mode. Both runtimes implement the same
`@gotry-io/relay-core` state contract and expose the same discovery document.

## Cloudflare development

Create a D1 database, replace the placeholder `database_id` in `wrangler.jsonc`, then run:

```bash
pnpm d1:migrate:local
pnpm dev
```

## Self-hosted development

```bash
pnpm dev:self-hosted
```

The SQLite database defaults to `./data/quota-relay.db`. Set `QUOTA_RELAY_DATABASE_PATH` to move
it. Provider credentials must never be stored in this database.

The current Relay exposes health, readiness, and discovery only, so discovery intentionally
advertises no authentication or snapshot capabilities. Those flags are enabled only with their
authenticated HTTP endpoints. Realtime WebSocket routing and Durable Objects are not part of v1.
