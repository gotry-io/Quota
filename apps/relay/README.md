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

## HTTP API v1

The shared Hono server core implements these routes under `/api/v1`:

- `POST /api/v1/pairings` and `POST /api/v1/pairings/token` create and poll a device-code pairing.
- `POST /api/v1/pairings/approve` and `POST /api/v1/pairings/deny` require an owner bearer with
  `device:manage`.
- `POST /api/v1/snapshots` requires the paired device bearer and accepts snapshots only for that
  device.
- `GET /api/v1/snapshots` requires an owner bearer with `quota:read`.
- `GET /api/v1/devices` and `DELETE /api/v1/devices/:device_id` require an owner bearer with
  `device:manage`.

Payloads are validated by `@gotry-io/quota-protocol`; pairing behavior and credential ownership are
defined in [ADR 0002](../../docs/decisions/0002-relay-device-code-pairing.md), and security rules are
defined in the [security baseline](../../docs/security.md). D1 and SQLite implement the same
persistent server behavior.

Owner-authentication bootstrap and its runtime UI are not implemented yet, and QuotaCLI and QuotaBar
do not call these routes yet. Discovery therefore continues to advertise no authentication or
snapshot capabilities until that runtime wiring is complete. Realtime WebSocket routing and Durable
Objects are not part of v1.
