# Self-hosting QuotaRelay

Production is the Node + SQLite process on the `dmit` VPS. The same source still runs as a
Cloudflare Worker over D1 for local development and tests
([ADR 0049](decisions/0049-one-relay-two-runtimes.md)). Switching runtimes is an operations
action, not a product migration: the origin, OAuth callbacks, and data contract stay
`https://quota.gotry.io`. The 2026-09-14 Worker → Node cutover is recorded in
[ADR 0050](decisions/0050-the-worker-and-d1-are-retired.md); do not re-run it.

This runbook is the host-side procedure for the dmit deployment: current topology, update,
rollback, backup, and restore. The Node entry, migration runner, and `build:node` output live
with the Relay package and are not restated here.

## Topology

```
client ── Cloudflare (proxied A record) ── dmit:443 Caddy ── quota-relay:8787
                                                          └─ quota-relay-backup (nightly .backup)
```

- **Image** `ghcr.io/gotry-io/quota-relay:<version>`, built by
  `.github/workflows/release-relay-image.yml` on a `relay-v*` tag
  (linux/amd64 + linux/arm64).
- **Stack** Portainer stack `quota-relay` on the dmit endpoint, file
  [`deploy/relay/portainer-stack.yml`](../deploy/relay/portainer-stack.yml):
  `relay` (192 MiB limit, `NODE_OPTIONS=--max-old-space-size=64`, volume
  `relay-data`) and `backup` (alpine + sqlite, volume `relay-backups`,
  bind-mounts `/opt/quota-relay/relay-sqlite-backup.sh`, a copy of
  [`scripts/relay-sqlite-backup.sh`](../scripts/relay-sqlite-backup.sh)).
- **Edge** Caddy (Portainer stack `caddy`, `/opt/caddy/Caddyfile`) terminates TLS
  with a Let's Encrypt certificate obtained through Cloudflare DNS-01 and proxies
  to `quota-relay:8787` on the shared `web` network, passing request headers
  through unchanged (its default).
- **Client address** Relay rate-limits per caller address, and behind Cloudflare
  that address exists only as `CF-Connecting-IP`. The stack file fixes
  `RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`; Relay reads it only from a peer in
  `RELAY_TRUSTED_PROXIES` (unset: loopback, RFC1918, unique-local IPv6 — Caddy on
  the `web` network is inside that) and ignores `X-Forwarded-For`.
  **Accepted risk (owner, 2026-09-19):** `dmit:443` also answers requests that did not
  come through Cloudflare, and such a request can write `CF-Connecting-IP` itself.
  The header keys only per-address rate limits — never authentication, sessions or
  stored data — so the origin is left open rather than restricted to Cloudflare's
  ranges or moved behind a Tunnel.
  A deployment that is not behind Cloudflare leaves the header unset
  (`x-forwarded-for`) and has its proxy overwrite `X-Forwarded-For` with the socket
  client (`header_up -CF-Connecting-IP` and `header_up X-Forwarded-For {remote_host}`
  in Caddy).

- **DNS** `quota.gotry.io` is a proxied A record to the dmit address. `wrangler.jsonc`
  declares no route, so nothing can re-bind the name to a Worker by accident.

The `deploy/relay/docker-compose.yml` file is the alternative layout for a host
without a public address (Relay + `cloudflared` Tunnel + backup, `env_file`).
It is not what production runs.

## Secrets

**Client-address header.** The stack file sets
`RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`. An image from 0.0.5 on without it
reads `X-Forwarded-For`, which Caddy fills with the Cloudflare edge it saw, so every
client would share a handful of rate-limit buckets.

The Node process reads the same names as the Worker, plus `RELAY_SQLITE_PATH`,
`RELAY_STATIC_DIR`, `PORT` (the stack file sets those three),
`RELAY_TRUSTED_PROXIES`, and `RELAY_CLIENT_ADDRESS_HEADER`. Unset or empty
`RELAY_TRUSTED_PROXIES` is loopback, RFC1918, and unique-local IPv6
(`127.0.0.0/8, ::1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7`); a
token that is not a CIDR or address refuses to start.
`RELAY_CLIENT_ADDRESS_HEADER` is `x-forwarded-for` or `cf-connecting-ip`; any
other value refuses to start. `IDENTITY_SUBJECT_KEY`, `QUOTA_INSTALLATION_KEY`,
and `QUOTA_SESSION_HASH_KEY` must each be at least 32 characters; a shorter
value refuses to start.

- The canonical copy is `deploy/relay/relay.env` on the operator's machine
  (mode 600, gitignored; `relay.env.example` lists the names).
- In Portainer the values are stack **Env** variables, interpolated into
  `environment:` by the stack file. Portainer resolves `env_file:` inside its own
  container, so an `env_file` path on the host does not work there.
- `APPLE_SIGNIN_PRIVATE_KEY` is the PKCS#8 PEM on one line with the two-character
  sequence `\n` between PEM lines; the Node entry restores the line breaks.
- The three HMAC keys must be the same on every runtime that shares a database.
  Cloudflare does not read secrets back, so the operator's `relay.env` is the only
  place to recover them from. `IDENTITY_SUBJECT_KEY` was rotated at cutover; the
  identity rows in both SQLite and D1 were recomputed with the new key.

## Deploy an update

1. Tag `relay-v<version>` on `main`; the workflow pushes the image.
2. The GHCR package is public; pull it on the host:

   ```bash
   ssh dmit.vps docker pull ghcr.io/gotry-io/quota-relay:<version>
   ```

3. Change the image tag in the Portainer stack and redeploy (Portainer UI, or
   `PUT /api/stacks/<id>?endpointId=<dmit>` with `pullImage: false`). The process
   applies any new `apps/relay/migrations` files on start into the same
   `d1_migrations` table Wrangler uses.
4. Check `docker logs quota-relay` for `relay_migrations_applied` and
   `https://quota.gotry.io/api/v2/info` for the new version.

## Rollback

Roll back by deploying a previous `ghcr.io/gotry-io/quota-relay:<version>` image the same way
as an update (pull, set the Portainer stack tag, redeploy). Do not restore the retired Worker
or D1 ([ADR 0050](decisions/0050-the-worker-and-d1-are-retired.md)).

An older image can boot only if it understands every `d1_migrations` row already on the SQLite
file. Applied migrations are never rewritten. If the previous image predates a migration this
database has applied, restore a snapshot taken before that migration (Backup and restore
below), then start that older image.

## Backup and restore

The `backup` container runs `relay-sqlite-backup.sh --loop`: at 03:00 in its `TZ`
(`Asia/Shanghai`) it writes `sqlite3 /data/relay.sqlite ".backup /backups/relay-YYYYMMDD.sqlite"`
and keeps 14 dated files. A second run on the same calendar day overwrites that
day's file. SQLite `-wal` / `-shm` files beside a snapshot are not used; `.backup`
writes a single consistent file.

Manual snapshot from the host:

```bash
docker exec quota-relay-backup /usr/local/bin/relay-sqlite-backup.sh
```

Restore uses [`scripts/relay-sqlite-restore.sh`](../scripts/relay-sqlite-restore.sh)
from a checkout of the Relay version you will boot. The script has no docker in
it: it refuses a snapshot that fails `PRAGMA integrity_check` or that names a
`d1_migrations` row the checkout does not have (fewer rows are fine — the
process applies the rest on start), refuses to overwrite a non-empty target
unless `--force`, and writes via a temp file + rename.

On the host, against files already on disk:

```bash
scripts/relay-sqlite-restore.sh /backups/relay-YYYYMMDD.sqlite /data/relay.sqlite
```

On dmit, stop `relay` first, then wrap the stack volumes (the Portainer project
prefixes them; `docker volume ls` names `quota-relay_relay-data` and
`quota-relay_relay-backups`) and the checkout's migrations:

```bash
docker stop quota-relay
docker run --rm \
  -v quota-relay_relay-data:/data \
  -v quota-relay_relay-backups:/backups \
  -v /path/to/quota/scripts/relay-sqlite-restore.sh:/usr/local/bin/relay-sqlite-restore.sh:ro \
  -v /path/to/quota/apps/relay/migrations:/migrations:ro \
  -e RELAY_MIGRATIONS_DIR=/migrations \
  alpine:3.21 \
  sh -c 'apk add --no-cache sqlite &&
    /usr/local/bin/relay-sqlite-restore.sh --force /backups/relay-YYYYMMDD.sqlite /data/relay.sqlite &&
    chown 1000:1000 /data/relay.sqlite'
docker start quota-relay
```

The script drops leftover `-wal` / `-shm` beside the target so an old WAL cannot
replay onto the restored file. Check `docker logs quota-relay` for
`relay_migrations_applied` after start.

The recovery drill is `restore-drill` in the Node integration suite
(`pnpm --filter @gotry-io/quota-relay test:node:integration`, or
`pnpm --filter @gotry-io/quota-relay test:restore-drill`). It builds the Node
bundle, starts Relay on a temp SQLite and a random port, creates an Account and
a session and uploads Usage through the HTTP API, snapshots with
`relay-sqlite-backup.sh`, restores with `relay-sqlite-restore.sh` into a fresh
file, starts a second process on that file, and checks that the Account summary
for that session is identical. It also refuses a tampered snapshot. The website
must already be built (`build:node` aliases the SvelteKit server output).

Off-host copies of these snapshots are deferred (K8).

## Logs and health

```bash
docker logs -f quota-relay
docker logs -f quota-relay-backup
docker logs -f caddy | grep '"host":"quota.gotry.io"'
```

Origin health without Cloudflare: `curl --resolve quota.gotry.io:443:<dmit address> https://quota.gotry.io/healthz`.
The relay container publishes no host port; only Caddy reaches it.

## Host sizing

dmit is 1 vCPU / 958 MiB shared with other services. Measured after cutover:
relay 85 MiB RSS, Caddy 31 MiB, about 210 MiB available. The 192 MiB container
limit plus the 64 MiB V8 old-space cap keep the process from taking the page cache
with it; if the limit is hit the container restarts and the SQLite file is
unaffected.
