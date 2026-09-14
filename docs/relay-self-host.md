# Self-hosting QuotaRelay

QuotaRelay is one process. It can run as a Cloudflare Worker over D1, or as a Node
server over a local SQLite file ([ADR 0049](decisions/0049-one-relay-two-runtimes.md)).
Switching between the two is an operations action, not a product migration: the
origin, OAuth callbacks, and data contract stay `https://quota.gotry.io`.

Since 2026-09-14 production is the Node runtime on the `dmit` VPS. The Worker and
its D1 database are kept deployed as the rollback path. This runbook is the
host-side procedure for that deployment; the Node entry, migration runner, and
`build:node` output live with the Relay package and are not restated here.

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
  to `quota-relay:8787` on the shared `web` network:

  ```caddyfile
  quota.gotry.io {
  	import edge
  	log {
  		output stdout
  		format json
  	}
  	reverse_proxy http://quota-relay:8787
  }
  ```

- **DNS** `quota.gotry.io` is a proxied A record to the dmit address. The Worker
  custom domain for that name was removed at cutover; `wrangler.jsonc` still
  declares it, so `wrangler deploy` would re-bind the Worker (see Rollback).

The `deploy/relay/docker-compose.yml` file is the alternative layout for a host
without a public address (Relay + `cloudflared` Tunnel + backup, `env_file`).
It is not what production runs.

## Secrets

The Node process reads the same names as the Worker, plus `RELAY_SQLITE_PATH`,
`RELAY_STATIC_DIR`, and `PORT` (the stack file sets those three).
`IDENTITY_SUBJECT_KEY`, `QUOTA_INSTALLATION_KEY`, and `QUOTA_SESSION_HASH_KEY`
must each be at least 32 characters; a shorter value refuses to start.

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

## Cutover procedure (Worker → Node), as run on 2026-09-14

The D1 export is a point-in-time copy; a write the Worker accepts after the export
is not in the SQLite file and there is no incremental replay. Do it at a low-traffic
time. The whole window was about 40 seconds.

1. Stop the `relay` container so the hostname answers 502 instead of serving an
   empty database.
2. Freeze writes: delete the Worker custom domain
   (`DELETE /accounts/<id>/workers/domains/<domain-id>`). This also removes the
   placeholder AAAA record Cloudflare keeps for it.
3. Export and import:

   ```bash
   ./scripts/relay-d1-export.sh /tmp/quota-d1.sql          # wrangler d1 export --remote
   ./scripts/relay-sqlite-import.sh /tmp/quota-d1.sql /tmp/relay.sqlite
   ```

   The import refuses to overwrite, and exits 1 unless `d1_migrations` has one row
   per file in `apps/relay/migrations`.
4. Place the file on the volume with the container stopped, then start it:

   ```bash
   scp /tmp/relay.sqlite dmit.vps:/opt/quota-relay/relay-prod.sqlite
   ssh dmit.vps 'docker run --rm -v quota-relay_relay-data:/data -v /opt/quota-relay:/src:ro alpine sh -c "cp /src/relay-prod.sqlite /data/relay.sqlite && chown 1000:1000 /data/relay.sqlite" && rm /opt/quota-relay/relay-prod.sqlite && docker start quota-relay'
   ```

5. Add the proxied A record `quota.gotry.io → <dmit address>`.
6. Verify: `curl -sD - https://quota.gotry.io/healthz` shows `via: 1.1 Caddy`; a
   signed-in QuotaBar or Quota iOS device completes an account sync and a
   snapshot upload (QuotaBar's `diagnostic_attempts` journal shows `success`);
   the Caddy access log shows authenticated `/api/v6/...` requests answering 200.
7. Watch for 30 minutes: `docker logs -f quota-relay` free of
   `relay_request_failed`, `/healthz` answering, memory within the limit.

## Rollback (Node → Worker)

```bash
cd apps/relay && pnpm exec wrangler deploy
```

re-creates the custom domain from `wrangler.jsonc`, which takes precedence over
the A record at the Cloudflare edge. D1 holds what it held at the freeze.

**Rollback discards every write the Node process accepted after cutover.**
`sqlite3 .dump` is not an incremental feed back into D1: hour-versioned Usage,
session rotation, and identity rows do not replay on top of the live Worker
database. If you must return to the Worker, you accept that loss.

## Backup and restore

The `backup` container runs `relay-sqlite-backup.sh --loop`: at 03:00 in its `TZ`
(`Asia/Shanghai`) it writes `sqlite3 /data/relay.sqlite ".backup /backups/relay-YYYYMMDD.sqlite"`
and keeps 14 dated files. A second run on the same calendar day overwrites that
day's file.

Manual snapshot from the host:

```bash
docker exec quota-relay-backup /usr/local/bin/relay-sqlite-backup.sh
```

Restore: stop `relay`, replace `/data/relay.sqlite` on the `relay-data` volume with
the snapshot (same `docker run --rm -v ... alpine cp` pattern as the cutover, then
`chown 1000:1000`), start `relay`. SQLite `-wal` / `-shm` files beside a snapshot
are not used; `.backup` writes a single consistent file.

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
