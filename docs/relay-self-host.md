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
  to `quota-relay:8787` on the shared `web` network. Relay honours `CF-Connecting-IP`
  and `X-Forwarded-For` only from peers in `RELAY_TRUSTED_PROXIES` (unset: loopback,
  RFC1918, unique-local IPv6 — Caddy on the Docker `web` network is inside that
  default). Caddy is the first trusted boundary, so it must not forward a
  client-supplied chain:

  **Cloudflare-proxied zone** (production: proxied A record). Set
  `RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`. Cloudflare sets
  `CF-Connecting-IP` and clients cannot forge it there. Pass that header through
  and *overwrite* `X-Forwarded-For` with it, rather than appending whatever the
  client sent:

  ```caddyfile
  quota.gotry.io {
  	import edge
  	log {
  		output stdout
  		format json
  	}
  	reverse_proxy http://quota-relay:8787 {
  		header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
  	}
  }
  ```

  **Not Cloudflare-proxied** (direct origin, or a leaked origin IP). Leave
  `RELAY_CLIENT_ADDRESS_HEADER` unset (`x-forwarded-for`). Clients can send
  `CF-Connecting-IP` themselves. Strip it and overwrite `X-Forwarded-For` with
  the socket client Caddy actually accepted:

  ```caddyfile
  quota.gotry.io {
  	import edge
  	reverse_proxy http://quota-relay:8787 {
  		header_up -CF-Connecting-IP
  		header_up X-Forwarded-For {remote_host}
  	}
  }
  ```

  The `deploy/relay/docker-compose.yml` Tunnel layout has no Caddy: `cloudflared`
  is a Docker-network peer (trusted by the default) and sets `CF-Connecting-IP`.
  Set `RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`. An untrusted peer that can
  reach `:8787` has its forwarding headers discarded; the rate-limit identity is
  the socket address.

- **DNS** `quota.gotry.io` is a proxied A record to the dmit address. `wrangler.jsonc`
  declares no route, so nothing can re-bind the name to a Worker by accident.

The `deploy/relay/docker-compose.yml` file is the alternative layout for a host
without a public address (Relay + `cloudflared` Tunnel + backup, `env_file`).
It is not what production runs.

## Secrets

**Upgrade note (owner actions).** A Cloudflare-fronted deployment MUST set
`RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip` when it takes this version, or
every client collapses into the Cloudflare edge addresses Caddy reports as
`X-Forwarded-For`. The origin must only accept Cloudflare's ranges (Caddy
`remote_ip` matcher or a host firewall): a request that reaches Caddy without
going through Cloudflare can send `CF-Connecting-IP` itself. Both are owner
actions; the process will not infer either from DNS. Unset
`RELAY_CLIENT_ADDRESS_HEADER` is `x-forwarded-for` (Caddy overwrites that
header; inbound `CF-Connecting-IP` is ignored).

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
