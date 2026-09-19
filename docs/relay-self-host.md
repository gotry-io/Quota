# Self-hosting QuotaRelay

QuotaRelay is one process. It can run as a Cloudflare Worker over D1, or as a Node
server over a local SQLite file ([ADR 0049](decisions/0049-one-relay-two-runtimes.md)).
Switching between the two is an operations action, not a product migration: the
origin, OAuth callbacks, and data contract stay `https://quota.gotry.io`.

Since 2026-09-14 production is the Node runtime on the `dmit` VPS. The production
Worker and its D1 database were deleted the same day
([ADR 0050](decisions/0050-the-worker-and-d1-are-retired.md)); the Workers runtime
remains for local development and tests. This runbook is the host-side procedure
for the dmit deployment; the Node entry, migration runner, and `build:node` output
live with the Relay package and are not restated here.

## Topology

```
client ── Cloudflare edge ── Tunnel ◄── cloudflared (dials out from dmit)
                                          │  private network `quota-relay`
                                          ├─ quota-relay:8787
                                          └─ quota-relay-backup (nightly .backup)
```

Relay has no public address. The only way in is Cloudflare's edge, through a tunnel
the host dials out to; nothing is published on dmit for it and Caddy does not serve
`quota.gotry.io` ([ADR 0055](decisions/0055-relay-is-reachable-only-through-a-tunnel.md)).

- **Image** `ghcr.io/gotry-io/quota-relay:<version>`, built by
  `.github/workflows/release-relay-image.yml` on a `relay-v*` tag
  (linux/amd64 + linux/arm64).
- **Stack** Portainer stack `quota-relay` on the dmit endpoint, file
  [`deploy/relay/portainer-stack.yml`](../deploy/relay/portainer-stack.yml):
  `relay` (192 MiB limit, `NODE_OPTIONS=--max-old-space-size=64`, volume
  `relay-data`), `tunnel` (`cloudflare/cloudflared`, pinned, 64 MiB limit) and
  `backup` (alpine + sqlite, volume `relay-backups`, bind-mounts
  `/opt/quota-relay/relay-sqlite-backup.sh`, a copy of
  [`scripts/relay-sqlite-backup.sh`](../scripts/relay-sqlite-backup.sh)), all on the
  stack's own bridge network `quota-relay` and on no other.
  [`deploy/relay/docker-compose.yml`](../deploy/relay/docker-compose.yml) is the same
  topology for `docker compose` with an `env_file`.
- **Edge** the remotely managed Cloudflare Tunnel `quota-relay`. Its one public
  hostname is `quota.gotry.io` → `http://quota-relay:8787`; the rule lives in
  Cloudflare (Zero Trust › Networks › Tunnels › `quota-relay` › Public hostnames),
  and Cloudflare terminates TLS. **DNS** `quota.gotry.io` is the proxied CNAME
  `<tunnel-id>.cfargotunnel.com` the tunnel owns. `wrangler.jsonc` declares no
  route, so nothing can re-bind the name to a Worker by accident.
- **Client address** Relay rate-limits per caller address. The stack fixes
  `RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`: Cloudflare's edge sets
  `CF-Connecting-IP`, cloudflared forwards it, and cloudflared is the only process
  that can reach Relay, so the header is Cloudflare's statement rather than a
  client's. `RELAY_TRUSTED_PROXIES` stays at its default (loopback, RFC1918,
  unique-local IPv6): the boundary is membership of the `quota-relay` network, which
  only the three services have. A different topology — a reverse proxy that
  overwrites `X-Forwarded-For` — leaves the header unset (`x-forwarded-for`) and must
  not be reachable from the internet without that proxy.

## Secrets

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

- `TUNNEL_TOKEN` is the `quota-relay` tunnel's connector token (Zero Trust ›
  Networks › Tunnels › `quota-relay` › Configure). Anyone holding it can run a
  connector for the tunnel, so it is a secret like the HMAC keys. To rotate it,
  refresh the token in Cloudflare, update the stack Env, and redeploy `tunnel`;
  the old token stops working at once.
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
   `relay_client_address_trust` (`cf-connecting-ip`), and
   `https://quota.gotry.io/api/v2/info` for the new version.

## Moving production onto the Tunnel

Production was Cloudflare → `dmit:443` Caddy → `quota-relay` on the shared `web`
network until the Tunnel cutover. The move keeps the site up: Caddy serves until
DNS moves, and each step has its own way back.

1. **Tunnel.** Create the remotely managed tunnel `quota-relay` (Zero Trust ›
   Networks › Tunnels › Create › Cloudflared). Copy its token into the stack Env as
   `TUNNEL_TOKEN`. Add no public hostname yet.
2. **Image.** Tag `relay-v<version>` on `main` (it carries the trusted-proxy code
   and the stack's `RELAY_CLIENT_ADDRESS_HEADER`); pull it on dmit.
3. **Both paths.** Deploy the stack file with one temporary addition — `relay` also
   joins the external `web` network so Caddy keeps serving:

   ```yaml
       networks:
         - quota
         - web          # cutover only
   # …
   networks:
     quota:
       name: quota-relay
     web:               # cutover only
       external: true
   ```

   Check `docker logs quota-relay-tunnel` for four `Registered tunnel connection`
   lines and the tunnel's status **Healthy** in Cloudflare.
   *Back:* redeploy the previous stack file.
4. **Move the name.** Delete the proxied A record for `quota.gotry.io`, then add the
   tunnel's public hostname `quota.gotry.io` → `http://quota-relay:8787`, which
   creates the proxied CNAME. Check `curl -sI https://quota.gotry.io/healthz` answers
   200 without `via: 1.1 Caddy`, sign in on the website, and let a Mac and a phone
   sync. *Back:* remove the public hostname and restore the proxied A record; Caddy
   still has the route.
5. **Close the old path.** Deploy the stack file as checked in (no `web`), delete the
   `quota.gotry.io` block from `/opt/caddy/Caddyfile` and reload Caddy
   (`docker exec caddy caddy reload --config /etc/caddy/Caddyfile`). A request to the
   dmit address with `Host: quota.gotry.io` must no longer reach Relay:
   `curl -sk --resolve quota.gotry.io:443:<dmit address> https://quota.gotry.io/healthz`
   fails. *Back:* restore the Caddyfile block and the `web` network (step 3's file).

## How production got here (2026-09-14)

The Worker → Node cutover ran once and is recorded for the history, not for
re-use: stop `relay`, delete the Worker custom domain (freeze), `wrangler d1 export`,
`scripts/relay-sqlite-import.sh` (refuses to overwrite; exits 1 unless
`d1_migrations` has one row per migration file), place the file on the volume with
the container stopped, start it, add the proxied A record, verify `via: 1.1 Caddy`
and a real device sync. The window was about 40 seconds. A final D1 export was
taken before the database was deleted and is kept by the owner off the repository.

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
the snapshot (a dated file on the `relay-backups` volume, or the owner's off-host copy) (same `docker run --rm -v ... alpine cp` pattern as the cutover, then
`chown 1000:1000`), start `relay`. SQLite `-wal` / `-shm` files beside a snapshot
are not used; `.backup` writes a single consistent file.

## Logs and health

```bash
docker logs -f quota-relay
docker logs -f quota-relay-tunnel     # connection registrations and edge errors
docker logs -f quota-relay-backup
```

Relay has no address outside its network, so there is no origin check around
Cloudflare. From the host:
`docker exec quota-relay node -e "fetch('http://127.0.0.1:8787/healthz').then((r)=>process.exit(r.ok?0:1))"`.
From anywhere: `https://quota.gotry.io/healthz`. The tunnel's own health is on its
page in Cloudflare (Healthy / Degraded / Down, connector version and edge locations).

## Host sizing

dmit is 1 vCPU / 958 MiB shared with other services. Measured after the Node
cutover: relay 85 MiB RSS, Caddy 31 MiB, about 210 MiB available. The tunnel
connector is capped at 64 MiB; record its measured RSS here after the Tunnel cutover. The 192 MiB container
limit plus the 64 MiB V8 old-space cap keep the process from taking the page cache
with it; if the limit is hit the container restarts and the SQLite file is
unaffected.
