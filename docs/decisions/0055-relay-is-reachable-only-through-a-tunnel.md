# ADR 0055: Relay is reachable only through a Cloudflare Tunnel

- Status: Accepted
- Date: 2026-09-19
- Related: [ADR 0049](./0049-one-relay-two-runtimes.md),
  [ADR 0050](./0050-the-worker-and-d1-are-retired.md)

## Context

Relay rate-limits sign-in, email links and anonymous reads per caller address. In production
that address exists only as `CF-Connecting-IP`, the header Cloudflare's edge adds: the path was
Cloudflare (proxied A record) → Caddy on `dmit:443` → `quota-relay:8787`, so the socket peer
Relay sees is Caddy and the peer Caddy sees is a Cloudflare edge.

A header is text. Caddy on dmit publishes 80/443 for about ten other sites, Docker-published
ports bypass the host firewall, and the runbook's own origin health check reaches `:443`
directly. Anyone who reaches that port with `Host: quota.gotry.io` can write `CF-Connecting-IP`
and Caddy forwards it. Making Relay's trust explicit (`RELAY_TRUSTED_PROXIES`,
`RELAY_CLIENT_ADDRESS_HEADER`) chooses *which* peer and header to believe; it cannot make the
header true while the origin is public. Relay also shared Caddy's `web` network with every
container Caddy fronts.

The consequence of forging is rate-limit evasion — sign-in emails, OAuth completion, public reads
— not authentication bypass. It is still the one control between those routes and abuse.

Three ways to make the header trustworthy:

1. **Accept only Cloudflare's address ranges at the origin** (Caddy `remote_ip` or a
   `DOCKER-USER` rule). The list must follow Cloudflare's published ranges, the rule sits in a
   place UFW does not show, and the origin stays reachable on the internet.
2. **Authenticated Origin Pulls.** The zone-level certificate is shared by every Cloudflare
   customer, so it needs a per-hostname certificate, its rotation, and client authentication in
   Caddy for one site among many. The origin stays reachable.
3. **A Cloudflare Tunnel.** A connector on the host dials out to Cloudflare; Relay needs no
   public address at all.

## Decision

Relay is reachable only through the remotely managed Cloudflare Tunnel `quota-relay`.

- The stack runs `relay`, `tunnel` (`cloudflare/cloudflared`, version pinned) and `backup` on
  its own bridge network `quota-relay`, on no other network, with no published port. Relay can
  still dial out (OAuth providers, Resend, status pages); nothing outside the stack can reach it.
- The tunnel's one public hostname is `quota.gotry.io` → `http://quota-relay:8787`. The rule
  lives in Cloudflare and is restated in the runbook; DNS is the proxied CNAME the tunnel owns.
  Caddy no longer serves `quota.gotry.io`.
- The stack file fixes `RELAY_CLIENT_ADDRESS_HEADER=cf-connecting-ip`. `RELAY_TRUSTED_PROXIES`
  keeps its private-range default: membership of the network is the boundary, and pinning a
  subnet would add a collision risk without excluding anyone who is not already on the host.
- The connector token is a stack secret like the HMAC keys.

## Consequences

- A request to the dmit address cannot reach Relay, so the rate-limit subject is the address
  Cloudflare saw. The Node trust code stays general for other topologies.
- There is no health path around Cloudflare: checks run through `docker exec` on the host or
  the public URL. The tunnel reports its own health in Cloudflare.
- One more container on a 958 MiB host (64 MiB limit).
- Cloudflare was already the only way users reached Relay; it is now also the only way the
  operator does. Losing Cloudflare loses the site either way.
- Rollback is the previous layout: proxied A record, the Caddy block, and the `web` network.
  The runbook's cutover lists it per step.
- The Workers runtime of ADR 0049 is unaffected; this decides how the Node deployment is
  exposed, not which runtime runs.
