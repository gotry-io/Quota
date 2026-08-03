# QuotaCLI

QuotaCLI is the local provider collector and remote edge agent. One TypeScript entry point produces
a Node ESM npm package and a standalone Bun executable.

Provider credentials are read locally and never sent to QuotaRelay. Edge mode sends only validated,
normalized quota snapshots from `@gotry-io/quota-protocol`.

```bash
pnpm --filter @gotry-io/quotacli dev -- providers
pnpm --filter @gotry-io/quotacli dev -- doctor
pnpm --filter @gotry-io/quotacli dev -- quota --format json --pretty
pnpm --filter @gotry-io/quotacli dev -- edge --help
pnpm --filter @gotry-io/quotacli build
```

## Commands

```text
quotacli version
quotacli providers
quotacli doctor
quotacli quota [--provider codex|claude|grok|all] [--format text|json] [--pretty]
quotacli edge pair [--relay <url>]
quotacli edge report
quotacli edge unpair
quotacli edge --help
quotacli help
```

`quota` defaults:

- `--provider all`
- `--format text` when attached to a terminal
- `--format json` otherwise

Exit codes for `quota`:

- `0`: every requested provider returned at least one fresh snapshot
- `1`: collection completed with one or more provider failures
- `2`: invalid CLI arguments

Edge commands return `0` on complete success, `1` for pairing, reporting, credential-store, or
partial provider-collection outcomes, and `2` for invalid commands or arguments.

JSON output is one versioned `QuotaCollectionReport`. Provider failures stay inside the report.
QuotaCLI never prints credentials, authorization headers, cookies, raw JWTs, or unredacted response
bodies.

## Distribution artifacts

`build:npm` creates the Node-based `dist/npm/quotacli.js` published as
`@gotry-io/quotacli`. `build:standalone` creates `dist/standalone/quotacli` for the QuotaBar app
bundle and direct release downloads. The npm package installs the same `quotacli` command and does
not require Bun at runtime. A `v*` Git tag publishes the package from `release-cli.yml` through npm
Trusted Publishing; the release workflow stores no long-lived npm credential.

## Edge pairing

Pair an edge machine with the managed Relay origin or a selected self-hosted Relay:

```text
quotacli edge pair                         # defaults to https://quota.gotry.io
quotacli edge pair --relay https://relay.example.com
quotacli edge report
quotacli edge unpair
```

`pair` discovers and validates Relay capabilities, displays a Relay-generated user code for
approval in QuotaBar, and stores the issued Relay-bound device credential. It does not accept a
manually created token and does not start recurring reporting. The managed Relay currently keeps
owner authentication disabled, so managed pairing fails safely until that identity path is
available; a bootstrapped self-hosted Relay advertises the required capabilities.

`unpair` removes only the local credential. It cannot prove possession of owner authorization, so
the remote device must still be revoked through QuotaBar or Relay device management. Pairing and
credential ownership are defined in
[`ADR 0002`](../../docs/decisions/0002-relay-device-code-pairing.md); storage requirements are in the
[`security baseline`](../../docs/security.md).

`report` verifies the saved Relay instance through unauthenticated discovery, performs one local
all-provider collection, and uploads the normalized successful snapshots. An empty snapshot list is
sent when every provider fails so the Relay can record a device heartbeat without deleting retained
observations. The local sequence advances only after the Relay returns `204`. A partial collection
is uploaded but returns exit code `1` with an explicit notice.

Recurring `start`, `status`, and `stop` service commands remain a subsequent milestone.
