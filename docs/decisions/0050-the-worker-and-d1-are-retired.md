# ADR 0050: The production Worker and D1 are retired

> Amended by [ADR 0058](0058-relay-runs-on-node-only.md): the Workers runtime is no longer a
> test or build target. Production retirement on 2026-09-14 still stands.

- Status: Accepted
- Date: 2026-09-14
- Amended: 2026-09-21 by [ADR 0058](0058-relay-runs-on-node-only.md): the Workers runtime,
  Wrangler, and D1 test pool are removed from the source.
- Extends [ADR 0049](0049-one-relay-two-runtimes.md)

## Context

[ADR 0049](0049-one-relay-two-runtimes.md) gave Relay a second runtime, Node over
SQLite, so that production could leave Cloudflare's free D1 tier without a product
migration. Production moved to that runtime on the dmit VPS on 2026-09-14
([self-host runbook](../relay-self-host.md)). For a few hours the Worker and its
D1 database stayed deployed as a rollback: `wrangler deploy` would re-create the
`quota.gotry.io` custom domain, which takes precedence over the A record at the
edge, and D1 held the data as of the freeze.

That rollback was also a hazard. A push to `main` used to run the deploy
workflow, so an unrelated Relay change could have moved production back to an
older Worker and a stale database without anyone deciding to. Every write the
Node process accepted after cutover would be lost on such a rollback, and there
is no incremental feed from SQLite back into D1. The rollback's value fell with
every hour the new runtime kept working; its risk did not.

## Decision

The production Worker `quota` and the D1 database `quota` are deleted. The
deploy workflow, its repository environment and secrets, and the custom-domain
route in `wrangler.jsonc` go with them.

The Workers runtime stays in the source: `src/cloudflare.ts`, the D1-shaped
`RelayDatabase` contract, the `workers` test project, and `wrangler dev` with a
local D1 are how Relay is developed and tested on that side of the seam. Nothing
in the repository deploys it.

The owner keeps one final export of the D1 database outside the repository. The
durable production store is the SQLite file on dmit with its nightly `.backup`
files; restore is the runbook's procedure.

## Consequences

- Rolling production back to Cloudflare is no longer a switch. It would be a new
  deployment from a SQLite dump, planned as such.
- `pnpm deploy:cloudflare` and `pnpm d1:migrate:remote` remain as scripts for
  whoever deploys the Workers runtime somewhere deliberately; no automation calls
  them.
- Client releases are unaffected: origin, OAuth callbacks, cookies, and the data
  contract did not change at cutover and do not change here.
