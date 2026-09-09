# Self-hosting QuotaRelay

QuotaRelay is one process. Cloudflare Workers plus D1 is the managed path at
`https://quota.gotry.io`. The same process can run as a Node server with local SQLite
behind a Cloudflare Tunnel. Switching between the two is an operations action, not a
product migration: the origin, OAuth callbacks, and data contract stay
`https://quota.gotry.io`.

This runbook is the host-side procedure. The Node entry, migration runner, and
`build:node` output live with the Relay package; this file does not restate them.

## Prerequisites

- A Mac mini (or any always-on host) with Docker Desktop installed and running.
- A clone of this repository. Compose bind-mounts
  `scripts/relay-sqlite-backup.sh` from the clone.
- Cloudflare access that can create a Tunnel and edit DNS for `gotry.io`.
- The production Worker secrets listed in [`apps/relay/README.md`](../apps/relay/README.md).
  The Node process reads the same names, plus `RELAY_SQLITE_PATH`, `RELAY_STATIC_DIR`,
  and `PORT`. `IDENTITY_SUBJECT_KEY`, `QUOTA_INSTALLATION_KEY`, and
  `QUOTA_SESSION_HASH_KEY` must each be at least 32 characters (`openssl rand -hex 24`);
  a shorter value refuses to start.
- `sqlite3` and `pnpm` on the host for export, import, and a manual backup. The
  Compose backup service installs `sqlite` itself.

### Cloudflare Tunnel and DNS

1. In Zero Trust → Networks → Tunnels, create a tunnel and copy its token. That
   token is `TUNNEL_TOKEN`.
2. Add a public hostname on the tunnel:
   - Subdomain / domain: `quota.gotry.io`
   - Type: HTTP
   - URL: `http://relay:8787` (the Compose service name and the container port)
3. Create the DNS record `quota.gotry.io` as a CNAME to
   `<tunnel-id>.cfargotunnel.com`, proxied. Do not point production at the tunnel
   until the cutover step below; the Worker custom domain owns that name today.

### Mac mini power and Docker Desktop

Docker Desktop on macOS runs only while a user session is logged in. Set the mini
so it does not sleep, and so Docker starts when that user logs in:

```bash
sudo pmset -a sleep 0 disksleep 0
```

In Docker Desktop → Settings → General, enable **Start Docker Desktop when you log
in**. Give the mini an automatic login for the user that runs Docker Desktop, or
the Compose stack will stay down until someone signs in at the console.

## First deploy (no production traffic)

Work from the repository root.

```bash
cp deploy/relay/relay.env.example deploy/relay/relay.env
ln -sf relay.env deploy/relay/.env
```

Fill every secret in `deploy/relay/relay.env`. The example already has sample
values for `IDENTITY_SUBJECT_KEY`, `QUOTA_INSTALLATION_KEY`, and
`QUOTA_SESSION_HASH_KEY`; replace them with new `openssl rand -hex 24` output for
this host (or copy the production Worker secrets — they must stay 32 characters
or longer). `relay.env` and `deploy/relay/.env` are gitignored. Compose reads
`.env` to substitute `${TUNNEL_TOKEN}` into the `cloudflared` command, and
injects `relay.env` into the `relay` container.

Leave `RELAY_SQLITE_PATH`, `RELAY_STATIC_DIR`, and `PORT` blank in `relay.env`;
Compose sets them to `/data/relay.sqlite`,
`apps/web/.svelte-kit/output/client`, and `8787` so they match `VOLUME /data` and
`EXPOSE 8787`. The image copies the SvelteKit client build to that same relative
path. `TZ` is for the backup container's clock (default `UTC`); set
`TZ=Asia/Shanghai` in `.env` if 03:00 should be that local time.

`APPLE_SIGNIN_PRIVATE_KEY` is the PKCS#8 PEM Apple issues once. Docker `env_file`
does not keep real newlines; put the PEM on one line with the two-character
sequence `\n` between PEM lines, matching however the Node entry decodes it.

Pull the published image, or build it locally before a `relay-v*` tag exists:

```bash
docker compose -f deploy/relay/docker-compose.yml pull
# or:
docker build -f apps/relay/Dockerfile -t ghcr.io/gotry-io/quota-relay:latest .
```

Start only Relay first if the tunnel hostname is not ready:

```bash
docker compose -f deploy/relay/docker-compose.yml up -d relay
curl -sS http://127.0.0.1:8787/healthz
curl -sS http://127.0.0.1:8787/api/v2/info
```

`__Host-` session cookies require HTTPS on `quota.gotry.io`. Sign-in and Usage
upload are verified on that hostname after cutover, not on loopback HTTP.

## Cutover (Worker → Docker)

Do this at a low-traffic time. The D1 export is a point-in-time copy. Any write
the Worker accepts after the export is not in the SQLite file, and there is no
incremental replay.

1. **Freeze writes.** In the Cloudflare dashboard, either:
   - replace the `quota.gotry.io` Worker route with a response that is 503
     maintenance, or
   - cut DNS immediately to the tunnel (shorter freeze, no maintenance page).
   The first option is the one that leaves D1 still while you export.
2. **Export D1** from a machine that has `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID`:

   ```bash
   ./scripts/relay-d1-export.sh /tmp/quota-d1.sql
   ```

   That is `wrangler d1 export quota --remote --output <file>` against
   `apps/relay/wrangler.jsonc`.
3. **Import** into a new file (the script refuses to overwrite):

   ```bash
   ./scripts/relay-sqlite-import.sh /tmp/quota-d1.sql /tmp/relay.sqlite
   ```

   The import creates the database, `.read`s the dump, and exits 1 unless
   `d1_migrations` exists and its row count equals the number of
   `apps/relay/migrations/*.sql` files. Wrangler records applied migrations in
   that table, so an export that already ran the ladder is treated as migrated
   and the Node process will not re-apply those files.
4. **Place the file on the volume and start the stack.** With the `relay`
   service stopped:

   ```bash
   docker compose -f deploy/relay/docker-compose.yml up -d
   docker compose -f deploy/relay/docker-compose.yml cp /tmp/relay.sqlite relay:/data/relay.sqlite
   docker compose -f deploy/relay/docker-compose.yml restart relay
   ```

   If the named volume is empty on first start, copying after `up` and restarting
   is enough. The process applies any *new* migration files on start.
5. **Verify on loopback, then through the tunnel hostname:**

   ```bash
   curl -sS http://127.0.0.1:8787/healthz
   curl -sS http://127.0.0.1:8787/api/v2/info
   ```

   Then, with DNS or the tunnel already serving `https://quota.gotry.io`: sign in
   in a browser, and from a signed-in QuotaBar or Quota iOS device confirm a
   snapshot/Usage upload.
6. **Cut DNS / Tunnel** if you froze with a 503 instead of moving DNS in step 1:
   remove the Worker custom domain (or the 503 route) and leave `quota.gotry.io`
   as the CNAME to `<tunnel-id>.cfargotunnel.com`.
7. **Watch for 30 minutes.** `docker compose -f deploy/relay/docker-compose.yml logs -f relay`
   should stay free of unhandled `relay_request_failed` lines; `/healthz` should
   keep answering; a Device should still upload.

## Rollback (Docker → Worker)

Point `quota.gotry.io` back at the Worker custom domain (or restore the Worker
route you removed). D1 still holds whatever it held when you froze or last
wrote through the Worker.

**Rollback discards every write the Docker process accepted after cutover.**
`sqlite3 .dump` is not an incremental feed back into D1: hour-versioned Usage,
session rotation, and identity rows do not replay on top of the live Worker
database. If you must return to the Worker, you accept that loss. That is why
cutover happens at a low-traffic time.

## Upgrade

```bash
docker compose -f deploy/relay/docker-compose.yml pull
docker compose -f deploy/relay/docker-compose.yml up -d
```

The Node process applies `apps/relay/migrations` on start, in filename order,
into the same `d1_migrations` table Wrangler uses. A new image that only adds
migration files does not need a manual SQLite step.

## Backup and restore

The `backup` service runs `scripts/relay-sqlite-backup.sh` at 03:00 in the
container's `TZ`. That script is:

```bash
sqlite3 /data/relay.sqlite ".backup /backups/relay-YYYYMMDD.sqlite"
```

and then deletes dated files so that 14 remain. A second run on the same calendar
day overwrites that day's file.

Manual run on the host (the database file copied off the volume):

```bash
./scripts/relay-sqlite-backup.sh /path/to/relay.sqlite /path/to/backups
```

Restore: stop `relay`, replace `/data/relay.sqlite` with the snapshot, start
`relay`. SQLite `-wal` / `-shm` files beside a snapshot are not used; `.backup`
writes a single consistent file.

```bash
docker compose -f deploy/relay/docker-compose.yml stop relay
docker compose -f deploy/relay/docker-compose.yml cp /path/to/relay-YYYYMMDD.sqlite relay:/data/relay.sqlite
docker compose -f deploy/relay/docker-compose.yml start relay
```

## Logs

```bash
docker compose -f deploy/relay/docker-compose.yml logs -f relay
docker compose -f deploy/relay/docker-compose.yml logs -f cloudflared
docker compose -f deploy/relay/docker-compose.yml logs -f backup
```

Loopback health is `http://127.0.0.1:8787/healthz`. Compose publishes 8787 only
on localhost; public traffic arrives through the tunnel.
