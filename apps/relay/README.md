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
export QUOTA_RELAY_CONTROLLER_TOKEN="$(openssl rand -hex 32)"
pnpm dev:relay:self-hosted
```

The SQLite database defaults to `./data/quota-relay.db`. Set `QUOTA_RELAY_DATABASE_PATH` to move
it. `QUOTA_RELAY_CONTROLLER_TOKEN` is required, must contain at least 32 characters, and must not
have leading or trailing whitespace. It authenticates the fixed self-hosted controller with
`quota:read` and `device:manage`; restarting with a different value immediately replaces the old
controller bearer.
QuotaRelay persists only its SHA-256 hash. Provider credentials must never be stored in this
database.

For the container deployment, copy `deploy/.env.example` to the ignored `deploy/.env`, generate and
set `QUOTA_RELAY_CONTROLLER_TOKEN`, then run from the repository root:

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up --build
```

Compose refuses to render the service when the required token is unset or empty; the example file
does not contain a default secret.

## HTTP API v1

The shared Hono server core implements these routes under `/api/v1`:

- `POST /api/v1/pairings` and `POST /api/v1/pairings/token` create and poll a device-code pairing.
- `POST /api/v1/controllers` anonymously creates a controller on the managed Relay and returns its
  bearer once. `DELETE /api/v1/controllers/self` deletes that controller and its data.
- `POST /api/v1/pairings/approve` and `POST /api/v1/pairings/deny` require a controller bearer with
  `device:manage`.
- `POST /api/v1/snapshots` requires the paired device bearer and accepts snapshots only for that
  device.
- `GET /api/v1/snapshots` requires a controller bearer with `quota:read`.
- `GET /api/v1/devices` and `DELETE /api/v1/devices/:device_id` require a controller bearer with
  `device:manage`.
- `DELETE /api/v1/devices/self` lets a device revoke its own bearer.

Payloads are validated by `@gotry-io/quota-protocol`; pairing behavior and credential ownership are
defined in [ADR 0002](../../docs/decisions/0002-relay-device-code-pairing.md), and security rules are
defined in the [security baseline](../../docs/security.md). D1 and SQLite implement the same
persistent server behavior.

The self-hosted runtime bootstraps its controller from `QUOTA_RELAY_CONTROLLER_TOKEN`. Both runtimes
advertise bearer authentication, persistent snapshots, and instant device revocation; managed Relay
also advertises multi-controller support. Devices that have not uploaded for 30 days are revoked.
Hourly maintenance deletes managed controllers with no device activity in the same 30-day window
and pairing sessions 24 hours after expiry; it never deletes the permanent self-hosted controller.
Snapshot envelopes accept at most 32 observations.
QuotaCLI uses the device pairing, snapshot-write, and self-revocation routes. QuotaBar uses the
controller bearer for pairing decisions, snapshot reads, device listing, and revocation. Realtime
WebSocket routing and Durable Objects are not part of v1.
