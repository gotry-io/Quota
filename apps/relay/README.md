# QuotaRelay

QuotaRelay has two supported persistent runtime targets:

- A Cloudflare Worker with Static Assets + D1 for the planned managed service at
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

For a manual production deployment, apply the remote migration before deploying the Worker and its
website together:

```bash
pnpm d1:migrate:remote
pnpm deploy:cloudflare
```

CI deploys the same pair automatically from `main` when Relay, website, protocol, or relay-core
inputs change (workflow `deploy-cloudflare.yml`), and on manual `workflow_dispatch`. The job applies
remote D1 migrations, then runs `deploy:cloudflare`, which builds `apps/web` and publishes the
Worker plus Static Assets in one step. Configure repository secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`, and approve the `production` GitHub Environment if protection rules are
enabled.

The `quota.gotry.io` Custom Domain is declared in `wrangler.jsonc`; Cloudflare manages its DNS
record and certificate during deployment.

## Self-hosted development

```bash
pnpm dev:relay:self-hosted
```

The SQLite database defaults to `./data/quota-relay.db`. Set `QUOTA_RELAY_DATABASE_PATH` to move
it. No bootstrap owner token is required: each QuotaBar registers an isolated anonymous owner
capability when pairing. Provider credentials must never be stored in this database.

For the container deployment, copy `deploy/.env.example` to the ignored `deploy/.env` if you need
to set `QUOTA_RELAY_INSTANCE_ID`, then run from the repository root:

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up --build
```

Operators who need a private service should restrict network access at the reverse proxy, firewall,
VPN, or identity-aware gateway.

## HTTP API v1

The shared Hono server core implements these routes under `/api/v1`:

- `POST /api/v1/pairings` and `POST /api/v1/pairings/token` create and poll a device-code pairing.
- `POST /api/v1/owners` anonymously creates an owner capability on any Relay and returns its
  bearer once. `DELETE /api/v1/owners/self` deletes that owner group and its data.
- `POST /api/v1/pairings/approve` and `POST /api/v1/pairings/deny` require an owner bearer with
  `device:manage`.
- `POST /api/v1/snapshots` requires the paired device bearer and accepts snapshots only for that
  device.
- `GET /api/v1/snapshots` requires an owner bearer with `quota:read`.
- `GET /api/v1/devices` and `DELETE /api/v1/devices/:device_id` require an owner bearer with
  `device:manage`.
- `DELETE /api/v1/devices/self` lets a device revoke its own bearer.

Payloads are validated by `@gotry-io/quota-protocol`; pairing behavior and credential ownership are
defined in [ADR 0002](../../docs/decisions/0002-relay-device-code-pairing.md) and
[ADR 0005](../../docs/decisions/0005-url-only-relay-enrollment.md), and security rules are defined in
the [security baseline](../../docs/security.md). D1 and SQLite implement the same persistent server
behavior.

Both runtimes advertise bearer authentication, persistent snapshots, instant device revocation, and
isolated multi-owner groups. Devices that have not uploaded for 30 days are revoked. Hourly
maintenance deletes inactive owner groups with no device activity in the same 30-day window
and pairing sessions 24 hours after expiry. Snapshot envelopes accept at most 32 observations.
QuotaCLI uses the device pairing, snapshot-write, and self-revocation routes. QuotaBar uses the
hidden owner bearer for pairing decisions, snapshot reads, device listing, and revocation. Realtime
WebSocket routing and Durable Objects are not part of v1.
